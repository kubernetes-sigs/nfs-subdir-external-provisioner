/*
Copyright 2016 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"errors"
	"fmt"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/time/rate"
	v1 "k8s.io/api/core/v1"
	storage "k8s.io/api/storage/v1"
	storagebeta "k8s.io/api/storage/v1beta1"
	apierrs "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apimachinery/pkg/util/uuid"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	corev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	corelistersv1 "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	"k8s.io/client-go/tools/record"
	ref "k8s.io/client-go/tools/reference"
	"k8s.io/client-go/util/workqueue"
	klog "k8s.io/klog/v2"
	"sigs.k8s.io/sig-storage-lib-external-provisioner/v9/controller/metrics"
	"sigs.k8s.io/sig-storage-lib-external-provisioner/v9/util"
)

// This annotation is added to a PV that has been dynamically provisioned by
// Kubernetes. Its value is name of volume plugin that created the volume.
// It serves both user (to show where a PV comes from) and Kubernetes (to
// recognize dynamically provisioned PVs in its decisions).
const annDynamicallyProvisioned = "pv.kubernetes.io/provisioned-by"

// AnnMigratedTo annotation is added to a PVC that is supposed to be
// dynamically provisioned/deleted by by its corresponding CSI driver
// through the CSIMigration feature flags. It allows external provisioners
// to determine which PVs are considered migrated and safe to operate on for
// Deletion.
const annMigratedTo = "pv.kubernetes.io/migrated-to"

const annBetaStorageProvisioner = "volume.beta.kubernetes.io/storage-provisioner"
const annStorageProvisioner = "volume.kubernetes.io/storage-provisioner"

// This annotation is added to a PVC that has been triggered by scheduler to
// be dynamically provisioned. Its value is the name of the selected node.
const annSelectedNode = "volume.kubernetes.io/selected-node"

// This annotation is present on K8s 1.11 release.
const annAlphaSelectedNode = "volume.alpha.kubernetes.io/selected-node"

// Finalizer for PVs so we know to clean them up
const finalizerPV = "external-provisioner.volume.kubernetes.io/finalizer"

const uidIndex = "uid"

var (
	errStopProvision = errors.New("stop provisioning")
)

// ProvisionController is a controller that provisions PersistentVolumes for
// PersistentVolumeClaims.
type ProvisionController struct {
	client kubernetes.Interface

	// The name of the provisioner for which this controller dynamically
	// provisions volumes. The value of annDynamicallyProvisioned and
	// annStorageProvisioner to set & watch for, respectively
	provisionerName string

	// additional provisioner names (beyond provisionerName) that the
	// provisioner should watch for and handle in annStorageProvisioner
	additionalProvisionerNames []string

	// The provisioner the controller will use to provision and delete volumes.
	// Presumably this implementer of Provisioner carries its own
	// volume-specific options and such that it needs in order to provision
	// volumes.
	provisioner Provisioner

	claimInformer  cache.SharedIndexInformer
	claimsIndexer  cache.Indexer
	volumeInformer cache.SharedInformer
	volumes        cache.Store
	classInformer  cache.SharedInformer
	nodeLister     corelistersv1.NodeLister
	classes        cache.Store

	// To determine if the informer is internal or external
	customClaimInformer, customVolumeInformer, customClassInformer bool

	claimQueue  workqueue.RateLimitingInterface
	volumeQueue workqueue.RateLimitingInterface

	// Identity of this controller, generated at creation time and not persisted
	// across restarts. Useful only for debugging, for seeing the source of
	// events. controller.provisioner may have its own, different notion of
	// identity which may/may not persist across restarts
	id            string
	component     string
	eventRecorder record.EventRecorder

	resyncPeriod     time.Duration
	provisionTimeout time.Duration
	deletionTimeout  time.Duration

	rateLimiter               workqueue.RateLimiter
	exponentialBackOffOnError bool
	threadiness               int

	createProvisionedPVBackoff    *wait.Backoff
	createProvisionedPVRetryCount int
	createProvisionedPVInterval   time.Duration
	createProvisionerPVLimiter    workqueue.RateLimiter

	failedProvisionThreshold, failedDeleteThreshold int

	// The metrics collection used by this controller.
	metrics metrics.Metrics
	// The port for metrics server to serve on.
	metricsPort int32
	// The IP address for metrics server to serve on.
	metricsAddress string
	// The path of metrics endpoint path.
	metricsPath string

	// Whether to add a finalizer marking the provisioner as the owner of the PV
	// with clean up duty.
	// TODO: upstream and we may have a race b/w applying reclaim policy and not if pv has protection finalizer
	addFinalizer bool

	// Whether to do kubernetes leader election at all. It should basically
	// always be done when possible to avoid duplicate Provision attempts.
	leaderElection          bool
	leaderElectionNamespace string
	// Parameters of leaderelection.LeaderElectionConfig.
	leaseDuration, renewDeadline, retryPeriod time.Duration

	hasRun     bool
	hasRunLock *sync.Mutex

	// Map UID -> *PVC with all claims that may be provisioned in the background.
	claimsInProgress sync.Map

	volumeStore VolumeStore
}

const (
	// DefaultResyncPeriod is used when option function ResyncPeriod is omitted
	DefaultResyncPeriod = 15 * time.Minute
	// DefaultThreadiness is used when option function Threadiness is omitted
	DefaultThreadiness = 4
	// DefaultExponentialBackOffOnError is used when option function ExponentialBackOffOnError is omitted
	DefaultExponentialBackOffOnError = true
	// DefaultCreateProvisionedPVRetryCount is used when option function CreateProvisionedPVRetryCount is omitted
	DefaultCreateProvisionedPVRetryCount = 5
	// DefaultCreateProvisionedPVInterval is used when option function CreateProvisionedPVInterval is omitted
	DefaultCreateProvisionedPVInterval = 10 * time.Second
	// DefaultFailedProvisionThreshold is used when option function FailedProvisionThreshold is omitted
	DefaultFailedProvisionThreshold = 15
	// DefaultFailedDeleteThreshold is used when option function FailedDeleteThreshold is omitted
	DefaultFailedDeleteThreshold = 15
	// DefaultLeaderElection is used when option function LeaderElection is omitted
	DefaultLeaderElection = true
	// DefaultLeaseDuration is used when option function LeaseDuration is omitted
	DefaultLeaseDuration = 15 * time.Second
	// DefaultRenewDeadline is used when option function RenewDeadline is omitted
	DefaultRenewDeadline = 10 * time.Second
	// DefaultRetryPeriod is used when option function RetryPeriod is omitted
	DefaultRetryPeriod = 2 * time.Second
	// DefaultMetricsPort is used when option function MetricsPort is omitted
	DefaultMetricsPort = 0
	// DefaultMetricsAddress is used when option function MetricsAddress is omitted
	DefaultMetricsAddress = "0.0.0.0"
	// DefaultMetricsPath is used when option function MetricsPath is omitted
	DefaultMetricsPath = "/metrics"
	// DefaultAddFinalizer is used when option function AddFinalizer is omitted
	DefaultAddFinalizer = false
)

var errRuntime = fmt.Errorf("cannot call option functions after controller has Run")

// ResyncPeriod is how often the controller relists PVCs, PVs, & storage
// classes. OnUpdate will be called even if nothing has changed, meaning failed
// operations may be retried on a PVC/PV every resyncPeriod regardless of
// whether it changed. Defaults to 15 minutes.
func ResyncPeriod(resyncPeriod time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.resyncPeriod = resyncPeriod
		return nil
	}
}

// Threadiness is the number of claim and volume workers each to launch.
// Defaults to 4.
func Threadiness(threadiness int) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.threadiness = threadiness
		return nil
	}
}

// RateLimiter is the workqueue.RateLimiter to use for the provisioning and
// deleting work queues. If set, ExponentialBackOffOnError is ignored.
func RateLimiter(rateLimiter workqueue.RateLimiter) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.rateLimiter = rateLimiter
		return nil
	}
}

// ExponentialBackOffOnError determines whether to exponentially back off from
// failures of Provision and Delete. Defaults to true.
func ExponentialBackOffOnError(exponentialBackOffOnError bool) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.exponentialBackOffOnError = exponentialBackOffOnError
		return nil
	}
}

// CreateProvisionedPVRetryCount is the number of retries when we create a PV
// object for a provisioned volume. Defaults to 5.
// If PV is not saved after given number of retries, corresponding storage asset (volume) is deleted!
// Only one of CreateProvisionedPVInterval+CreateProvisionedPVRetryCount or CreateProvisionedPVBackoff or
// CreateProvisionedPVLimiter can be used.
// Deprecated: Use CreateProvisionedPVLimiter instead, it tries indefinitely.
func CreateProvisionedPVRetryCount(createProvisionedPVRetryCount int) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		if c.createProvisionedPVBackoff != nil {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVRetryCount")
		}
		if c.createProvisionerPVLimiter != nil {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVLimiter")
		}
		c.createProvisionedPVRetryCount = createProvisionedPVRetryCount
		return nil
	}
}

// CreateProvisionedPVInterval is the interval between retries when we create a
// PV object for a provisioned volume. Defaults to 10 seconds.
// If PV is not saved after given number of retries, corresponding storage asset (volume) is deleted!
// Only one of CreateProvisionedPVInterval+CreateProvisionedPVRetryCount or CreateProvisionedPVBackoff or
// CreateProvisionedPVLimiter can be used.
// Deprecated: Use CreateProvisionedPVLimiter instead, it tries indefinitely.
func CreateProvisionedPVInterval(createProvisionedPVInterval time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		if c.createProvisionedPVBackoff != nil {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVInterval")
		}
		if c.createProvisionerPVLimiter != nil {
			return fmt.Errorf("CreateProvisionedPVInterval cannot be used together with CreateProvisionedPVLimiter")
		}
		c.createProvisionedPVInterval = createProvisionedPVInterval
		return nil
	}
}

// CreateProvisionedPVBackoff is the configuration of exponential backoff between retries when we create a
// PV object for a provisioned volume. Defaults to linear backoff, 10 seconds 5 times.
// If PV is not saved after given number of retries, corresponding storage asset (volume) is deleted!
// Only one of CreateProvisionedPVInterval+CreateProvisionedPVRetryCount or CreateProvisionedPVBackoff or
// CreateProvisionedPVLimiter can be used.
// Deprecated: Use CreateProvisionedPVLimiter instead, it tries indefinitely.
func CreateProvisionedPVBackoff(backoff wait.Backoff) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		if c.createProvisionedPVRetryCount != 0 {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVRetryCount")
		}
		if c.createProvisionedPVInterval != 0 {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVInterval")
		}
		if c.createProvisionerPVLimiter != nil {
			return fmt.Errorf("CreateProvisionedPVBackoff cannot be used together with CreateProvisionedPVLimiter")
		}
		c.createProvisionedPVBackoff = &backoff
		return nil
	}
}

// CreateProvisionedPVLimiter is the configuration of rate limiter for queue of unsaved PersistentVolumes.
// If set, PVs that fail to be saved to Kubernetes API server will be re-enqueued to a separate workqueue
// with this limiter and re-tried until they are saved to API server. There is no limit of retries.
// The main difference to other CreateProvisionedPV* option is that the storage asset is never deleted
// and the controller continues saving PV to API server indefinitely.
// This option cannot be used with CreateProvisionedPVBackoff or CreateProvisionedPVInterval
// or CreateProvisionedPVRetryCount.
func CreateProvisionedPVLimiter(limiter workqueue.RateLimiter) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		if c.createProvisionedPVRetryCount != 0 {
			return fmt.Errorf("CreateProvisionedPVLimiter cannot be used together with CreateProvisionedPVRetryCount")
		}
		if c.createProvisionedPVInterval != 0 {
			return fmt.Errorf("CreateProvisionedPVLimiter cannot be used together with CreateProvisionedPVInterval")
		}
		if c.createProvisionedPVBackoff != nil {
			return fmt.Errorf("CreateProvisionedPVLimiter cannot be used together with CreateProvisionedPVBackoff")
		}
		c.createProvisionerPVLimiter = limiter
		return nil
	}
}

// FailedProvisionThreshold is the threshold for max number of retries on
// failures of Provision. Set to 0 to retry indefinitely. Defaults to 15.
func FailedProvisionThreshold(failedProvisionThreshold int) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.failedProvisionThreshold = failedProvisionThreshold
		return nil
	}
}

// FailedDeleteThreshold is the threshold for max number of retries on failures
// of Delete. Set to 0 to retry indefinitely. Defaults to 15.
func FailedDeleteThreshold(failedDeleteThreshold int) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.failedDeleteThreshold = failedDeleteThreshold
		return nil
	}
}

// LeaderElection determines whether to enable leader election or not. Defaults
// to true.
func LeaderElection(leaderElection bool) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.leaderElection = leaderElection
		return nil
	}
}

// LeaderElectionNamespace is the kubernetes namespace in which to create the
// leader election object. Defaults to the same namespace in which the
// the controller runs.
func LeaderElectionNamespace(leaderElectionNamespace string) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.leaderElectionNamespace = leaderElectionNamespace
		return nil
	}
}

// LeaseDuration is the duration that non-leader candidates will
// wait to force acquire leadership. This is measured against time of
// last observed ack. Defaults to 15 seconds.
func LeaseDuration(leaseDuration time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.leaseDuration = leaseDuration
		return nil
	}
}

// RenewDeadline is the duration that the acting master will retry
// refreshing leadership before giving up. Defaults to 10 seconds.
func RenewDeadline(renewDeadline time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.renewDeadline = renewDeadline
		return nil
	}
}

// RetryPeriod is the duration the LeaderElector clients should wait
// between tries of actions. Defaults to 2 seconds.
func RetryPeriod(retryPeriod time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.retryPeriod = retryPeriod
		return nil
	}
}

// ClaimsInformer sets the informer to use for accessing PersistentVolumeClaims.
// Defaults to using a internal informer.
func ClaimsInformer(informer cache.SharedIndexInformer) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.claimInformer = informer
		c.customClaimInformer = true
		return nil
	}
}

// VolumesInformer sets the informer to use for accessing PersistentVolumes.
// Defaults to using a internal informer.
func VolumesInformer(informer cache.SharedInformer) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.volumeInformer = informer
		c.customVolumeInformer = true
		return nil
	}
}

// ClassesInformer sets the informer to use for accessing StorageClasses.
// The informer must use the versioned resource appropriate for the Kubernetes cluster version
// (that is, v1.StorageClass for >= 1.6, and v1beta1.StorageClass for < 1.6).
// Defaults to using a internal informer.
func ClassesInformer(informer cache.SharedInformer) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.classInformer = informer
		c.customClassInformer = true
		return nil
	}
}

// NodesLister sets the informer to use for accessing Nodes.
// This is needed only for PVCs which have a selected node.
// Defaults to using a GET instead of an informer.
//
// Which approach is better depends on factors like cluster size and
// ratio of PVCs with a selected node.
func NodesLister(nodeLister corelistersv1.NodeLister) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.nodeLister = nodeLister
		return nil
	}
}

// MetricsInstance defines which metrics collection to update. Default: metrics.Metrics.
func MetricsInstance(m metrics.Metrics) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.metrics = m
		return nil
	}
}

// MetricsPort sets the port that metrics server serves on. Default: 0, set to non-zero to enable.
func MetricsPort(metricsPort int32) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.metricsPort = metricsPort
		return nil
	}
}

// MetricsAddress sets the ip address that metrics serve serves on.
func MetricsAddress(metricsAddress string) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.metricsAddress = metricsAddress
		return nil
	}
}

// MetricsPath sets the endpoint path of metrics server.
func MetricsPath(metricsPath string) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.metricsPath = metricsPath
		return nil
	}
}

// AdditionalProvisionerNames sets additional names for the provisioner
func AdditionalProvisionerNames(additionalProvisionerNames []string) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.additionalProvisionerNames = additionalProvisionerNames
		return nil
	}
}

// AddFinalizer determines whether to add a finalizer marking the provisioner
// as the owner of the PV with clean up duty. A PV having the finalizer means
// the provisioner wants to keep it around so that it can reclaim it.
func AddFinalizer(addFinalizer bool) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.addFinalizer = addFinalizer
		return nil
	}
}

// ProvisionTimeout sets the amount of time that provisioning a volume may take.
// The default is unlimited.
func ProvisionTimeout(timeout time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.provisionTimeout = timeout
		return nil
	}
}

// DeletionTimeout sets the amount of time that deleting a volume may take.
// The default is unlimited.
func DeletionTimeout(timeout time.Duration) func(*ProvisionController) error {
	return func(c *ProvisionController) error {
		if c.HasRun() {
			return errRuntime
		}
		c.deletionTimeout = timeout
		return nil
	}
}

// HasRun returns whether the controller has Run
func (ctrl *ProvisionController) HasRun() bool {
	ctrl.hasRunLock.Lock()
	defer ctrl.hasRunLock.Unlock()
	return ctrl.hasRun
}

// NewProvisionController creates a new provision controller using
// the given configuration parameters and with private (non-shared) informers.
func NewProvisionController(
	client kubernetes.Interface,
	provisionerName string,
	provisioner Provisioner,
	options ...func(*ProvisionController) error,
) *ProvisionController {
	id, err := os.Hostname()
	if err != nil {
		klog.Fatalf("Error getting hostname: %v", err)
	}
	// add a uniquifier so that two processes on the same host don't accidentally both become active
	id = id + "_" + string(uuid.NewUUID())
	component := provisionerName + "_" + id

	v1.AddToScheme(scheme.Scheme)
	broadcaster := record.NewBroadcaster()
	broadcaster.StartLogging(klog.Infof)
	broadcaster.StartRecordingToSink(&corev1.EventSinkImpl{Interface: client.CoreV1().Events(v1.NamespaceAll)})
	eventRecorder := broadcaster.NewRecorder(scheme.Scheme, v1.EventSource{Component: component})

	controller := &ProvisionController{
		client:                    client,
		provisionerName:           provisionerName,
		provisioner:               provisioner,
		id:                        id,
		component:                 component,
		eventRecorder:             eventRecorder,
		resyncPeriod:              DefaultResyncPeriod,
		exponentialBackOffOnError: DefaultExponentialBackOffOnError,
		threadiness:               DefaultThreadiness,
		failedProvisionThreshold:  DefaultFailedProvisionThreshold,
		failedDeleteThreshold:     DefaultFailedDeleteThreshold,
		leaderElection:            DefaultLeaderElection,
		leaderElectionNamespace:   getInClusterNamespace(),
		leaseDuration:             DefaultLeaseDuration,
		renewDeadline:             DefaultRenewDeadline,
		retryPeriod:               DefaultRetryPeriod,
		metrics:                   metrics.M,
		metricsPort:               DefaultMetricsPort,
		metricsAddress:            DefaultMetricsAddress,
		metricsPath:               DefaultMetricsPath,
		addFinalizer:              DefaultAddFinalizer,
		hasRun:                    false,
		hasRunLock:                &sync.Mutex{},
	}

	for _, option := range options {
		err := option(controller)
		if err != nil {
			klog.Fatalf("Error processing controller options: %s", err)
		}
	}

	var rateLimiter workqueue.RateLimiter
	if controller.rateLimiter != nil {
		// rateLimiter set via parameter takes precedence
		rateLimiter = controller.rateLimiter
	} else if controller.exponentialBackOffOnError {
		rateLimiter = workqueue.NewMaxOfRateLimiter(
			workqueue.NewItemExponentialFailureRateLimiter(15*time.Second, 1000*time.Second),
			&workqueue.BucketRateLimiter{Limiter: rate.NewLimiter(rate.Limit(10), 100)},
		)
	} else {
		rateLimiter = workqueue.NewMaxOfRateLimiter(
			workqueue.NewItemExponentialFailureRateLimiter(15*time.Second, 15*time.Second),
			&workqueue.BucketRateLimiter{Limiter: rate.NewLimiter(rate.Limit(10), 100)},
		)
	}
	controller.claimQueue = workqueue.NewNamedRateLimitingQueue(rateLimiter, "claims")
	controller.volumeQueue = workqueue.NewNamedRateLimitingQueue(rateLimiter, "volumes")

	informer := informers.NewSharedInformerFactory(client, controller.resyncPeriod)

	// ----------------------
	// PersistentVolumeClaims

	claimHandler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj interface{}) { controller.enqueueClaim(obj) },
		UpdateFunc: func(oldObj, newObj interface{}) { controller.enqueueClaim(newObj) },
		DeleteFunc: func(obj interface{}) {
			// NOOP. The claim is either in claimsInProgress and in the queue, so it will be processed as usual
			// or it's not in claimsInProgress and then we don't care
		},
	}

	if controller.claimInformer != nil {
		controller.claimInformer.AddEventHandlerWithResyncPeriod(claimHandler, controller.resyncPeriod)
	} else {
		controller.claimInformer = informer.Core().V1().PersistentVolumeClaims().Informer()
		controller.claimInformer.AddEventHandler(claimHandler)
	}
	err = controller.claimInformer.AddIndexers(cache.Indexers{uidIndex: func(obj interface{}) ([]string, error) {
		uid, err := getObjectUID(obj)
		if err != nil {
			return nil, err
		}
		return []string{uid}, nil
	}})
	if err != nil {
		klog.Fatalf("Error setting indexer %s for pvc informer: %v", uidIndex, err)
	}
	controller.claimsIndexer = controller.claimInformer.GetIndexer()

	// -----------------
	// PersistentVolumes

	volumeHandler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj interface{}) { controller.enqueueVolume(obj) },
		UpdateFunc: func(oldObj, newObj interface{}) { controller.enqueueVolume(newObj) },
		DeleteFunc: func(obj interface{}) { controller.forgetVolume(obj) },
	}

	if controller.volumeInformer != nil {
		controller.volumeInformer.AddEventHandlerWithResyncPeriod(volumeHandler, controller.resyncPeriod)
	} else {
		controller.volumeInformer = informer.Core().V1().PersistentVolumes().Informer()
		controller.volumeInformer.AddEventHandler(volumeHandler)
	}
	controller.volumes = controller.volumeInformer.GetStore()

	// --------------
	// StorageClasses

	// no resource event handler needed for StorageClasses
	if controller.classInformer == nil {
		controller.classInformer = informer.Storage().V1().StorageClasses().Informer()
	}
	controller.classes = controller.classInformer.GetStore()

	if controller.createProvisionerPVLimiter != nil {
		klog.V(2).Infof("Using saving PVs to API server in background")
		controller.volumeStore = NewVolumeStoreQueue(client, controller.createProvisionerPVLimiter, controller.claimsIndexer, controller.eventRecorder)
	} else {
		if controller.createProvisionedPVBackoff == nil {
			// Use linear backoff with createProvisionedPVInterval and createProvisionedPVRetryCount by default.
			if controller.createProvisionedPVInterval == 0 {
				controller.createProvisionedPVInterval = DefaultCreateProvisionedPVInterval
			}
			if controller.createProvisionedPVRetryCount == 0 {
				controller.createProvisionedPVRetryCount = DefaultCreateProvisionedPVRetryCount
			}
			controller.createProvisionedPVBackoff = &wait.Backoff{
				Duration: controller.createProvisionedPVInterval,
				Factor:   1, // linear backoff
				Steps:    controller.createProvisionedPVRetryCount,
				//Cap:      controller.createProvisionedPVInterval,
			}
		}
		klog.V(2).Infof("Using blocking saving PVs to API server")
		controller.volumeStore = NewBackoffStore(client, controller.eventRecorder, controller.createProvisionedPVBackoff, controller)
	}

	return controller
}

func getObjectUID(obj interface{}) (string, error) {
	var object metav1.Object
	var ok bool
	if object, ok = obj.(metav1.Object); !ok {
		tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
		if !ok {
			return "", fmt.Errorf("error decoding object, invalid type")
		}
		object, ok = tombstone.Obj.(metav1.Object)
		if !ok {
			return "", fmt.Errorf("error decoding object tombstone, invalid type")
		}
	}
	return string(object.GetUID()), nil
}

// enqueueClaim takes an obj and converts it into UID that is then put onto claim work queue.
func (ctrl *ProvisionController) enqueueClaim(obj interface{}) {
	uid, err := getObjectUID(obj)
	if err != nil {
		utilruntime.HandleError(err)
		return
	}
	ctrl.claimQueue.Add(uid)
}

// enqueueVolume takes an obj and converts it into a namespace/name string which
// is then put onto the given work queue.
func (ctrl *ProvisionController) enqueueVolume(obj interface{}) {
	var key string
	var err error
	if key, err = cache.DeletionHandlingMetaNamespaceKeyFunc(obj); err != nil {
		utilruntime.HandleError(err)
		return
	}
	ctrl.volumeQueue.Add(key)
}

// forgetVolume Forgets an obj from the given work queue, telling the queue to
// stop tracking its retries because e.g. the obj was deleted
func (ctrl *ProvisionController) forgetVolume(obj interface{}) {
	var key string
	var err error
	if key, err = cache.DeletionHandlingMetaNamespaceKeyFunc(obj); err != nil {
		utilruntime.HandleError(err)
		return
	}
	ctrl.volumeQueue.Forget(key)
	ctrl.volumeQueue.Done(key)
}

// Run starts all of this controller's control loops
func (ctrl *ProvisionController) Run(ctx context.Context) {
	run := func(ctx context.Context) {
		klog.Infof("Starting provisioner controller %s!", ctrl.component)
		defer utilruntime.HandleCrash()
		defer ctrl.claimQueue.ShutDown()
		defer ctrl.volumeQueue.ShutDown()

		ctrl.hasRunLock.Lock()
		ctrl.hasRun = true
		ctrl.hasRunLock.Unlock()
		if ctrl.metricsPort > 0 {
			prometheus.MustRegister([]prometheus.Collector{
				metrics.PersistentVolumeClaimProvisionTotal,
				metrics.PersistentVolumeClaimProvisionFailedTotal,
				metrics.PersistentVolumeClaimProvisionDurationSeconds,
				metrics.PersistentVolumeDeleteTotal,
				metrics.PersistentVolumeDeleteFailedTotal,
				metrics.PersistentVolumeDeleteDurationSeconds,
			}...)
			http.Handle(ctrl.metricsPath, promhttp.Handler())
			address := net.JoinHostPort(ctrl.metricsAddress, strconv.FormatInt(int64(ctrl.metricsPort), 10))
			klog.Infof("Starting metrics server at %s\n", address)
			go wait.Forever(func() {
				err := http.ListenAndServe(address, nil)
				if err != nil {
					klog.Errorf("Failed to listen on %s: %v", address, err)
				}
			}, 5*time.Second)
		}

		// If a external SharedInformer has been passed in, this controller
		// should not call Run again
		if !ctrl.customClaimInformer {
			go ctrl.claimInformer.Run(ctx.Done())
		}
		if !ctrl.customVolumeInformer {
			go ctrl.volumeInformer.Run(ctx.Done())
		}
		if !ctrl.customClassInformer {
			go ctrl.classInformer.Run(ctx.Done())
		}

		if !cache.WaitForCacheSync(ctx.Done(), ctrl.claimInformer.HasSynced, ctrl.volumeInformer.HasSynced, ctrl.classInformer.HasSynced) {
			return
		}

		for i := 0; i < ctrl.threadiness; i++ {
			go wait.Until(func() { ctrl.runClaimWorker(ctx) }, time.Second, ctx.Done())
			go wait.Until(func() { ctrl.runVolumeWorker(ctx) }, time.Second, ctx.Done())
		}

		klog.Infof("Started provisioner controller %s!", ctrl.component)

		select {}
	}

	go ctrl.volumeStore.Run(ctx, DefaultThreadiness)

	if ctrl.leaderElection {
		rl, err := resourcelock.New(resourcelock.EndpointsLeasesResourceLock,
			ctrl.leaderElectionNamespace,
			strings.Replace(ctrl.provisionerName, "/", "-", -1),
			ctrl.client.CoreV1(),
			ctrl.client.CoordinationV1(),
			resourcelock.ResourceLockConfig{
				Identity:      ctrl.id,
				EventRecorder: ctrl.eventRecorder,
			})
		if err != nil {
			klog.Fatalf("Error creating lock: %v", err)
		}

		leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
			Lock:          rl,
			LeaseDuration: ctrl.leaseDuration,
			RenewDeadline: ctrl.renewDeadline,
			RetryPeriod:   ctrl.retryPeriod,
			Callbacks: leaderelection.LeaderCallbacks{
				OnStartedLeading: run,
				OnStoppedLeading: func() {
					klog.Fatalf("leaderelection lost")
				},
			},
		})
		panic("unreachable")
	} else {
		run(ctx)
	}
}

func (ctrl *ProvisionController) runClaimWorker(ctx context.Context) {
	for ctrl.processNextClaimWorkItem(ctx) {
	}
}

func (ctrl *ProvisionController) runVolumeWorker(ctx context.Context) {
	for ctrl.processNextVolumeWorkItem(ctx) {
	}
}

// processNextClaimWorkItem processes items from claimQueue
func (ctrl *ProvisionController) processNextClaimWorkItem(ctx context.Context) bool {
	obj, shutdown := ctrl.claimQueue.Get()

	if shutdown {
		return false
	}

	err := func() error {
		// Apply per-operation timeout.
		if ctrl.provisionTimeout != 0 {
			timeout, cancel := context.WithTimeout(ctx, ctrl.provisionTimeout)
			defer cancel()
			ctx = timeout
		}
		defer ctrl.claimQueue.Done(obj)
		var key string
		var ok bool
		if key, ok = obj.(string); !ok {
			ctrl.claimQueue.Forget(obj)
			return fmt.Errorf("expected string in workqueue but got %#v", obj)
		}

		if err := ctrl.syncClaimHandler(ctx, key); err != nil {
			if ctrl.failedProvisionThreshold == 0 {
				klog.Warningf("Retrying syncing claim %q, failure %v", key, ctrl.claimQueue.NumRequeues(obj))
				ctrl.claimQueue.AddRateLimited(obj)
			} else if ctrl.claimQueue.NumRequeues(obj) < ctrl.failedProvisionThreshold {
				klog.Warningf("Retrying syncing claim %q because failures %v < threshold %v", key, ctrl.claimQueue.NumRequeues(obj), ctrl.failedProvisionThreshold)
				ctrl.claimQueue.AddRateLimited(obj)
			} else {
				klog.Errorf("Giving up syncing claim %q because failures %v >= threshold %v", key, ctrl.claimQueue.NumRequeues(obj), ctrl.failedProvisionThreshold)
				klog.V(2).Infof("Removing PVC %s from claims in progress", key)
				ctrl.claimsInProgress.Delete(key) // This can leak a volume that's being provisioned in the background!
				// Done but do not Forget: it will not be in the queue but NumRequeues
				// will be saved until the obj is deleted from kubernetes
			}
			return fmt.Errorf("error syncing claim %q: %s", key, err.Error())
		}

		ctrl.claimQueue.Forget(obj)
		// Silently remove the PVC from list of volumes in progress. The provisioning either succeeded
		// or the PVC was ignored by this provisioner.
		ctrl.claimsInProgress.Delete(key)
		return nil
	}()

	if err != nil {
		utilruntime.HandleError(err)
		return true
	}

	return true
}

// processNextVolumeWorkItem processes items from volumeQueue
func (ctrl *ProvisionController) processNextVolumeWorkItem(ctx context.Context) bool {
	obj, shutdown := ctrl.volumeQueue.Get()

	if shutdown {
		return false
	}

	err := func() error {
		// Apply per-operation timeout.
		if ctrl.deletionTimeout != 0 {
			timeout, cancel := context.WithTimeout(ctx, ctrl.deletionTimeout)
			defer cancel()
			ctx = timeout
		}
		defer ctrl.volumeQueue.Done(obj)
		var key string
		var ok bool
		if key, ok = obj.(string); !ok {
			ctrl.volumeQueue.Forget(obj)
			return fmt.Errorf("expected string in workqueue but got %#v", obj)
		}

		if err := ctrl.syncVolumeHandler(ctx, key); err != nil {
			if ctrl.failedDeleteThreshold == 0 {
				klog.Warningf("Retrying syncing volume %q, failure %v", key, ctrl.volumeQueue.NumRequeues(obj))
				ctrl.volumeQueue.AddRateLimited(obj)
			} else if ctrl.volumeQueue.NumRequeues(obj) < ctrl.failedDeleteThreshold {
				klog.Warningf("Retrying syncing volume %q because failures %v < threshold %v", key, ctrl.volumeQueue.NumRequeues(obj), ctrl.failedDeleteThreshold)
				ctrl.volumeQueue.AddRateLimited(obj)
			} else {
				klog.Errorf("Giving up syncing volume %q because failures %v >= threshold %v", key, ctrl.volumeQueue.NumRequeues(obj), ctrl.failedDeleteThreshold)
				// Done but do not Forget: it will not be in the queue but NumRequeues
				// will be saved until the obj is deleted from kubernetes
			}
			return fmt.Errorf("error syncing volume %q: %s", key, err.Error())
		}

		ctrl.volumeQueue.Forget(obj)
		return nil
	}()

	if err != nil {
		utilruntime.HandleError(err)
		return true
	}

	return true
}

// syncClaimHandler gets the claim from informer's cache then calls syncClaim. A non-nil error triggers requeuing of the claim.
func (ctrl *ProvisionController) syncClaimHandler(ctx context.Context, key string) error {
	objs, err := ctrl.claimsIndexer.ByIndex(uidIndex, key)
	if err != nil {
		return err
	}
	var claimObj interface{}
	if len(objs) > 0 {
		claimObj = objs[0]
	} else {
		obj, found := ctrl.claimsInProgress.Load(key)
		if !found {
			utilruntime.HandleError(fmt.Errorf("claim %q in work queue no longer exists", key))
			return nil
		}
		claimObj = obj
	}
	return ctrl.syncClaim(ctx, claimObj)
}

// syncVolumeHandler gets the volume from informer's cache then calls syncVolume
func (ctrl *ProvisionController) syncVolumeHandler(ctx context.Context, key string) error {
	volumeObj, exists, err := ctrl.volumes.GetByKey(key)
	if err != nil {
		return err
	}
	if !exists {
		// Already deleted, nothing to do anymore.
		return nil
	}

	return ctrl.syncVolume(ctx, volumeObj)
}

// syncClaim checks if the claim should have a volume provisioned for it and
// provisions one if so. Returns an error if the claim is to be requeued.
func (ctrl *ProvisionController) syncClaim(ctx context.Context, obj interface{}) error {
	claim, ok := obj.(*v1.PersistentVolumeClaim)
	if !ok {
		return fmt.Errorf("expected claim but got %+v", obj)
	}

	should, err := ctrl.shouldProvision(ctx, claim)
	if err != nil {
		ctrl.updateProvisionStats(claim, err, time.Time{})
		return err
	} else if should {
		startTime := time.Now()

		status, err := ctrl.provisionClaimOperation(ctx, claim)
		ctrl.updateProvisionStats(claim, err, startTime)
		if err == nil || status == ProvisioningFinished {
			// Provisioning is 100% finished / not in progress.
			switch err {
			case nil:
				klog.V(5).Infof("Claim processing succeeded, removing PVC %s from claims in progress", claim.UID)
			case errStopProvision:
				klog.V(5).Infof("Stop provisioning, removing PVC %s from claims in progress", claim.UID)
				// Our caller would requeue if we pass on this special error; return nil instead.
				err = nil
			default:
				klog.V(2).Infof("Final error received, removing PVC %s from claims in progress", claim.UID)
			}
			ctrl.claimsInProgress.Delete(string(claim.UID))
			return err
		}
		if status == ProvisioningInBackground {
			// Provisioning is in progress in background.
			klog.V(2).Infof("Temporary error received, adding PVC %s to claims in progress", claim.UID)
			ctrl.claimsInProgress.Store(string(claim.UID), claim)
		} else {
			// status == ProvisioningNoChange.
			// Don't change claimsInProgress:
			// - the claim is already there if previous status was ProvisioningInBackground.
			// - the claim is not there if if previous status was ProvisioningFinished.
		}
		return err
	}
	return nil
}

// syncVolume checks if the volume should be deleted and deletes if so
func (ctrl *ProvisionController) syncVolume(ctx context.Context, obj interface{}) error {
	volume, ok := obj.(*v1.PersistentVolume)
	if !ok {
		return fmt.Errorf("expected volume but got %+v", obj)
	}

	if !ctrl.isProvisionerForVolume(ctx, volume) {
		// Current provisioner is not responsible for the volume
		return nil
	}

	volume, err := ctrl.handleProtectionFinalizer(ctx, volume)
	if err != nil {
		return err
	}

	if ctrl.shouldDelete(ctx, volume) {
		startTime := time.Now()
		err = ctrl.deleteVolumeOperation(ctx, volume)
		ctrl.updateDeleteStats(volume, err, startTime)
		return err
	}
	return nil
}

func (ctrl *ProvisionController) isProvisionerForVolume(ctx context.Context, volume *v1.PersistentVolume) bool {
	if metav1.HasAnnotation(volume.ObjectMeta, annDynamicallyProvisioned) {
		provisionPluginName := volume.Annotations[annDynamicallyProvisioned]
		migratedAnn := volume.Annotations[annMigratedTo]
		// Determine if the PV is owned by the current provisioner.
		if !ctrl.knownProvisioner(provisionPluginName) && !ctrl.knownProvisioner(migratedAnn) {
			// The current provisioner is not responsible for adding the finalizer
			return false
		}
	} else {
		// Statically provisioned volume. Check if the volume type is CSI.
		if volume.Spec.PersistentVolumeSource.CSI != nil {
			volumeProvisioner := volume.Spec.CSI.Driver
			if !ctrl.knownProvisioner(volumeProvisioner) {
				return false
			}
		} else {
			// Check if the volume is being migrated
			migratedAnn := volume.Annotations[annMigratedTo]
			if !ctrl.knownProvisioner(migratedAnn) {
				// The current provisioner is not responsible for adding the finalizer
				return false
			}
		}
	}
	return true
}

func (ctrl *ProvisionController) handleProtectionFinalizer(ctx context.Context, volume *v1.PersistentVolume) (*v1.PersistentVolume, error) {
	var modified bool
	klog.V(4).Infof("handleProtectionFinalizer Volume : %+v", volume)
	reclaimPolicy := volume.Spec.PersistentVolumeReclaimPolicy
	volumeFinalizers := volume.ObjectMeta.Finalizers

	// Add the finalizer only if `addFinalizer` config option is enabled, finalizer doesn't exist and PV is not already
	// under deletion.
	if ctrl.addFinalizer && reclaimPolicy == v1.PersistentVolumeReclaimDelete && volume.DeletionTimestamp == nil && volume.Status.Phase == v1.VolumeBound {
		volumeFinalizers, modified = addFinalizer(volumeFinalizers, finalizerPV)
	}

	// Check if the `addFinalizer` config option is disabled, i.e, rollback scenario, or the reclaim policy is changed
	// to `Retain` or `Recycle`
	if !ctrl.addFinalizer || reclaimPolicy == v1.PersistentVolumeReclaimRetain || reclaimPolicy == v1.PersistentVolumeReclaimRecycle {
		volumeFinalizers, modified = removeFinalizer(volumeFinalizers, finalizerPV)
	}

	if modified {
		volume.ObjectMeta.Finalizers = volumeFinalizers
		newVolume, err := ctrl.updatePersistentVolume(ctx, volume)
		if err != nil {
			return volume, fmt.Errorf("failed to modify finalizers to %+v on volume %s err: %+v", volumeFinalizers, volume.Name, err)
		}
		volume = newVolume
	}
	return volume, nil
}

// knownProvisioner checks if provisioner name has been
// configured to provision volumes for
func (ctrl *ProvisionController) knownProvisioner(provisioner string) bool {
	if provisioner == ctrl.provisionerName {
		return true
	}
	for _, p := range ctrl.additionalProvisionerNames {
		if p == provisioner {
			return true
		}
	}
	return false
}

// shouldProvision returns whether a claim should have a volume provisioned for
// it, i.e. whether a Provision is "desired"
func (ctrl *ProvisionController) shouldProvision(ctx context.Context, claim *v1.PersistentVolumeClaim) (bool, error) {
	if claim.Spec.VolumeName != "" {
		return false, nil
	}

	if qualifier, ok := ctrl.provisioner.(Qualifier); ok {
		if !qualifier.ShouldProvision(ctx, claim) {
			return false, nil
		}
	}

	provisioner, found := claim.Annotations[annStorageProvisioner]
	if !found {
		provisioner, found = claim.Annotations[annBetaStorageProvisioner]
	}

	if found {
		if ctrl.knownProvisioner(provisioner) {
			claimClass := util.GetPersistentVolumeClaimClass(claim)
			class, err := ctrl.getStorageClass(claimClass)
			if err != nil {
				return false, err
			}
			if class.VolumeBindingMode != nil && *class.VolumeBindingMode == storage.VolumeBindingWaitForFirstConsumer {
				// When claim is in delay binding mode, annSelectedNode is
				// required to provision volume.
				// Though PV controller set annStorageProvisioner only when
				// annSelectedNode is set, but provisioner may remove
				// annSelectedNode to notify scheduler to reschedule again.
				if selectedNode, ok := claim.Annotations[annSelectedNode]; ok && selectedNode != "" {
					return true, nil
				}
				return false, nil
			}
			return true, nil
		}
	}

	return false, nil
}

// shouldDelete returns whether a volume should have its backing volume
// deleted, i.e. whether a Delete is "desired"
func (ctrl *ProvisionController) shouldDelete(ctx context.Context, volume *v1.PersistentVolume) bool {
	if deletionGuard, ok := ctrl.provisioner.(DeletionGuard); ok {
		if !deletionGuard.ShouldDelete(ctx, volume) {
			return false
		}
	}

	if ctrl.addFinalizer {
		if !ctrl.checkFinalizer(volume, finalizerPV) && volume.ObjectMeta.DeletionTimestamp != nil {
			// The finalizer was removed, i.e. the volume has been already deleted.
			return false
		}
	} else {
		if volume.ObjectMeta.DeletionTimestamp != nil {
			return false
		}
	}

	if volume.Status.Phase != v1.VolumeReleased {
		return false
	}

	if volume.Spec.PersistentVolumeReclaimPolicy != v1.PersistentVolumeReclaimDelete {
		return false
	}

	return true
}

// canProvision returns error if provisioner can't provision claim.
func (ctrl *ProvisionController) canProvision(ctx context.Context, claim *v1.PersistentVolumeClaim) error {
	// Check if this provisioner supports Block volume
	if util.CheckPersistentVolumeClaimModeBlock(claim) && !ctrl.supportsBlock(ctx) {
		return fmt.Errorf("%s does not support block volume provisioning", ctrl.provisionerName)
	}

	return nil
}

func (ctrl *ProvisionController) checkFinalizer(volume *v1.PersistentVolume, finalizer string) bool {
	for _, f := range volume.ObjectMeta.Finalizers {
		if f == finalizer {
			return true
		}
	}
	return false
}

func (ctrl *ProvisionController) updateProvisionStats(claim *v1.PersistentVolumeClaim, err error, startTime time.Time) {
	class := ""
	source := ""
	if claim.Spec.StorageClassName != nil {
		class = *claim.Spec.StorageClassName
	}
	if claim.Spec.DataSource != nil {
		source = claim.Spec.DataSource.Kind
	}
	if err != nil {
		ctrl.metrics.PersistentVolumeClaimProvisionFailedTotal.WithLabelValues(class, source).Inc()
	} else {
		ctrl.metrics.PersistentVolumeClaimProvisionDurationSeconds.WithLabelValues(class, source).Observe(time.Since(startTime).Seconds())
		ctrl.metrics.PersistentVolumeClaimProvisionTotal.WithLabelValues(class, source).Inc()
	}
}

func (ctrl *ProvisionController) updateDeleteStats(volume *v1.PersistentVolume, err error, startTime time.Time) {
	class := volume.Spec.StorageClassName
	if err != nil {
		ctrl.metrics.PersistentVolumeDeleteFailedTotal.WithLabelValues(class).Inc()
	} else {
		ctrl.metrics.PersistentVolumeDeleteDurationSeconds.WithLabelValues(class).Observe(time.Since(startTime).Seconds())
		ctrl.metrics.PersistentVolumeDeleteTotal.WithLabelValues(class).Inc()
	}
}

func (ctrl *ProvisionController) updatePersistentVolume(ctx context.Context, volume *v1.PersistentVolume) (*v1.PersistentVolume, error) {
	newVolume, err := ctrl.client.CoreV1().PersistentVolumes().Update(ctx, volume, metav1.UpdateOptions{})
	if err != nil {
		return volume, err
	}
	return newVolume, nil
}

// rescheduleProvisioning signal back to the scheduler to retry dynamic provisioning
// by removing the annSelectedNode annotation
func (ctrl *ProvisionController) rescheduleProvisioning(ctx context.Context, claim *v1.PersistentVolumeClaim) error {
	if _, ok := claim.Annotations[annSelectedNode]; !ok {
		// Provisioning not triggered by the scheduler, skip
		return nil
	}

	// The claim from method args can be pointing to watcher cache. We must not
	// modify these, therefore create a copy.
	newClaim := claim.DeepCopy()
	delete(newClaim.Annotations, annSelectedNode)
	// Try to update the PVC object
	if _, err := ctrl.client.CoreV1().PersistentVolumeClaims(newClaim.Namespace).Update(ctx, newClaim, metav1.UpdateOptions{}); err != nil {
		return fmt.Errorf("delete annotation 'annSelectedNode' for PersistentVolumeClaim %q: %v", claimToClaimKey(newClaim), err)
	}

	// Save updated claim into informer cache to avoid operations on old claim.
	if err := ctrl.claimInformer.GetStore().Update(newClaim); err != nil {
		// This shouldn't happen because it is a local
		// operation. The only situation in which Update fails
		// is when the object is invalid, which isn't the case
		// here
		// (https://github.com/kubernetes/client-go/blob/eb0bad8167df60e402297b26e2cee1bddffde108/tools/cache/store.go#L154-L162).
		// Log the error and hope that a regular cache update will resolve it.
		klog.Warningf("update claim informer cache for PersistentVolumeClaim %q: %v", claimToClaimKey(newClaim), err)
	}

	return nil
}

// provisionClaimOperation attempts to provision a volume for the given claim.
// Returns nil error only when the volume was provisioned (in which case it also returns ProvisioningFinished),
// a normal error when the volume was not provisioned and provisioning should be retried (requeue the claim),
// or the special errStopProvision when provisioning was impossible and no further attempts to provision should be tried.
func (ctrl *ProvisionController) provisionClaimOperation(ctx context.Context, claim *v1.PersistentVolumeClaim) (ProvisioningState, error) {
	// Most code here is identical to that found in controller.go of kube's PV controller...
	claimClass := util.GetPersistentVolumeClaimClass(claim)
	operation := fmt.Sprintf("provision %q class %q", claimToClaimKey(claim), claimClass)
	klog.Info(logOperation(operation, "started"))

	//  A previous doProvisionClaim may just have finished while we were waiting for
	//  the locks. Check that PV (with deterministic name) hasn't been provisioned
	//  yet.
	pvName := ctrl.getProvisionedVolumeNameForClaim(claim)
	_, exists, err := ctrl.volumes.GetByKey(pvName)
	if err == nil && exists {
		// Volume has been already provisioned, nothing to do.
		klog.Info(logOperation(operation, "persistentvolume %q already exists, skipping", pvName))
		return ProvisioningFinished, errStopProvision
	}

	// Prepare a claimRef to the claim early (to fail before a volume is
	// provisioned)
	claimRef, err := ref.GetReference(scheme.Scheme, claim)
	if err != nil {
		klog.Error(logOperation(operation, "unexpected error getting claim reference: %v", err))
		return ProvisioningNoChange, err
	}

	// Check if this provisioner can provision this claim.
	if err = ctrl.canProvision(ctx, claim); err != nil {
		ctrl.eventRecorder.Event(claim, v1.EventTypeWarning, "ProvisioningFailed", err.Error())
		klog.Error(logOperation(operation, "failed to provision volume: %v", err))
		return ProvisioningFinished, errStopProvision
	}

	// For any issues getting fields from StorageClass (including reclaimPolicy & mountOptions),
	// retry the claim because the storageClass can be fixed/(re)created independently of the claim
	class, err := ctrl.getStorageClass(claimClass)
	if err != nil {
		klog.Error(logOperation(operation, "error getting claim's StorageClass's fields: %v", err))
		return ProvisioningFinished, err
	}
	if !ctrl.knownProvisioner(class.Provisioner) {
		// class.Provisioner has either changed since shouldProvision() or
		// annDynamicallyProvisioned contains different provisioner than
		// class.Provisioner.
		klog.Error(logOperation(operation, "unknown provisioner %q requested in claim's StorageClass", class.Provisioner))
		return ProvisioningFinished, errStopProvision
	}

	var selectedNode *v1.Node
	// Get SelectedNode
	if nodeName, ok := getString(claim.Annotations, annSelectedNode, annAlphaSelectedNode); ok {
		if ctrl.nodeLister != nil {
			selectedNode, err = ctrl.nodeLister.Get(nodeName)
		} else {
			selectedNode, err = ctrl.client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{}) // TODO (verult) cache Nodes
		}
		if err != nil {
			// if node does not exist, reschedule and remove volume.kubernetes.io/selected-node annotation
			if apierrs.IsNotFound(err) {
				return ctrl.provisionVolumeErrorHandling(ctx, ProvisioningReschedule, err, claim, operation)
			}
			err = fmt.Errorf("failed to get target node: %v", err)
			ctrl.eventRecorder.Event(claim, v1.EventTypeWarning, "ProvisioningFailed", err.Error())
			return ProvisioningNoChange, err
		}
	}

	options := ProvisionOptions{
		StorageClass: class,
		PVName:       pvName,
		PVC:          claim,
		SelectedNode: selectedNode,
	}

	ctrl.eventRecorder.Event(claim, v1.EventTypeNormal, "Provisioning", fmt.Sprintf("External provisioner is provisioning volume for claim %q", claimToClaimKey(claim)))

	volume, result, err := ctrl.provisioner.Provision(ctx, options)
	if err != nil {
		if ierr, ok := err.(*IgnoredError); ok {
			// Provision ignored, do nothing and hope another provisioner will provision it.
			klog.Info(logOperation(operation, "volume provision ignored: %v", ierr))
			return ProvisioningFinished, errStopProvision
		}

		err = fmt.Errorf("failed to provision volume with StorageClass %q: %v", claimClass, err)
		return ctrl.provisionVolumeErrorHandling(ctx, result, err, claim, operation)
	}

	klog.Info(logOperation(operation, "volume %q provisioned", volume.Name))

	// Set ClaimRef and the PV controller will bind and set annBoundByController for us
	volume.Spec.ClaimRef = claimRef

	// Add external provisioner finalizer if it doesn't already have it
	if ctrl.addFinalizer && !ctrl.checkFinalizer(volume, finalizerPV) {
		volume.ObjectMeta.Finalizers = append(volume.ObjectMeta.Finalizers, finalizerPV)
	}

	metav1.SetMetaDataAnnotation(&volume.ObjectMeta, annDynamicallyProvisioned, class.Provisioner)
	volume.Spec.StorageClassName = claimClass

	klog.Info(logOperation(operation, "succeeded"))

	if err := ctrl.volumeStore.StoreVolume(claim, volume); err != nil {
		return ProvisioningFinished, err
	}
	if err = ctrl.volumes.Add(volume); err != nil {
		utilruntime.HandleError(err)
	}
	return ProvisioningFinished, nil
}

func (ctrl *ProvisionController) provisionVolumeErrorHandling(ctx context.Context, result ProvisioningState, err error, claim *v1.PersistentVolumeClaim, operation string) (ProvisioningState, error) {
	ctrl.eventRecorder.Event(claim, v1.EventTypeWarning, "ProvisioningFailed", err.Error())
	if _, ok := claim.Annotations[annSelectedNode]; ok && result == ProvisioningReschedule {
		// For dynamic PV provisioning with delayed binding, the provisioner may fail
		// because the node is wrong (permanent error) or currently unusable (not enough
		// capacity). If the provisioner wants to give up scheduling with the currently
		// selected node, then it can ask for that by returning ProvisioningReschedule
		// as state.
		//
		// `selectedNode` must be removed to notify scheduler to schedule again.
		if errLabel := ctrl.rescheduleProvisioning(ctx, claim); errLabel != nil {
			klog.Info(logOperation(operation, "volume rescheduling failed: %v", errLabel))
			// If unsetting that label fails in ctrl.rescheduleProvisioning, we
			// keep the volume in the work queue as if the provisioner had
			// returned ProvisioningFinished and simply try again later.
			return ProvisioningFinished, err
		}
		// Label was removed, stop working on the volume.
		klog.Info(logOperation(operation, "volume rescheduled because: %v", err))
		return ProvisioningFinished, errStopProvision
	}

	// ProvisioningReschedule shouldn't have been returned for volumes without selected node,
	// but if we get it anyway, then treat it like ProvisioningFinished because we cannot
	// reschedule.
	if result == ProvisioningReschedule {
		result = ProvisioningFinished
	}
	return result, err
}

// deleteVolumeOperation attempts to delete the volume backing the given
// volume. Returns error, which indicates whether deletion should be retried
// (requeue the volume) or not
func (ctrl *ProvisionController) deleteVolumeOperation(ctx context.Context, volume *v1.PersistentVolume) error {
	operation := fmt.Sprintf("delete %q", volume.Name)
	klog.Info(logOperation(operation, "started"))

	err := ctrl.provisioner.Delete(ctx, volume)
	if err != nil {
		if ierr, ok := err.(*IgnoredError); ok {
			// Delete ignored, do nothing and hope another provisioner will delete it.
			klog.Info(logOperation(operation, "volume deletion ignored: %v", ierr))
			return nil
		}
		// Delete failed, emit an event.
		klog.Error(logOperation(operation, "volume deletion failed: %v", err))
		ctrl.eventRecorder.Event(volume, v1.EventTypeWarning, "VolumeFailedDelete", err.Error())
		return err
	}

	klog.Info(logOperation(operation, "volume deleted"))

	// Delete the volume
	if err = ctrl.client.CoreV1().PersistentVolumes().Delete(ctx, volume.Name, metav1.DeleteOptions{}); err != nil {
		// Oops, could not delete the volume and therefore the controller will
		// try to delete the volume again on next update.
		klog.Info(logOperation(operation, "failed to delete persistentvolume: %v", err))
		return err
	}

	if ctrl.addFinalizer {
		if len(volume.ObjectMeta.Finalizers) > 0 {
			// Remove external-provisioner finalizer

			// need to get the pv again because the delete has updated the object with a deletion timestamp
			volumeObj, exists, err := ctrl.volumes.GetByKey(volume.Name)
			if err != nil {
				klog.Info(logOperation(operation, "failed to get persistentvolume to update finalizer: %v", err))
				return err
			}
			if !exists {
				// If the volume is not found return
				return nil
			}
			newVolume, ok := volumeObj.(*v1.PersistentVolume)
			if !ok {
				return fmt.Errorf("expected volume but got %+v", volumeObj)
			}
			finalizers, modified := removeFinalizer(newVolume.ObjectMeta.Finalizers, finalizerPV)

			// Only update the finalizers if we actually removed something
			if modified {
				newVolume.ObjectMeta.Finalizers = finalizers
				if _, err = ctrl.client.CoreV1().PersistentVolumes().Update(ctx, newVolume, metav1.UpdateOptions{}); err != nil {
					if !apierrs.IsNotFound(err) {
						// Couldn't remove finalizer and the object still exists, the controller may
						// try to remove the finalizer again on the next update
						klog.Info(logOperation(operation, "failed to remove finalizer for persistentvolume: %v", err))
						return err
					}
				}
			}
		}
	}

	klog.Info(logOperation(operation, "persistentvolume deleted succeeded"))
	return nil
}

func removeFinalizer(finalizers []string, finalizerToRemove string) ([]string, bool) {
	modified := false
	modifiedFinalizers := make([]string, 0)
	for _, finalizer := range finalizers {
		if finalizer != finalizerToRemove {
			modifiedFinalizers = append(modifiedFinalizers, finalizer)
		}
	}
	if len(modifiedFinalizers) == 0 {
		modifiedFinalizers = nil
	}
	if len(modifiedFinalizers) != len(finalizers) {
		modified = true
	}
	return modifiedFinalizers, modified
}

func addFinalizer(finalizers []string, finalizerToAdd string) ([]string, bool) {
	modifiedFinalizers := make([]string, 0)
	for _, finalizer := range finalizers {
		if finalizer == finalizerToAdd {
			// finalizer already exists
			return finalizers, false
		}
	}
	modifiedFinalizers = append(modifiedFinalizers, finalizers...)
	modifiedFinalizers = append(modifiedFinalizers, finalizerToAdd)
	return modifiedFinalizers, true
}

func logOperation(operation, format string, a ...interface{}) string {
	return fmt.Sprintf(fmt.Sprintf("%s: %s", operation, format), a...)
}

// getInClusterNamespace returns the namespace in which the controller runs.
func getInClusterNamespace() string {
	if ns := os.Getenv("POD_NAMESPACE"); ns != "" {
		return ns
	}

	// Fall back to the namespace associated with the service account token, if available
	if data, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace"); err == nil {
		if ns := strings.TrimSpace(string(data)); len(ns) > 0 {
			return ns
		}
	}

	return "default"
}

// getProvisionedVolumeNameForClaim returns PV.Name for the provisioned volume.
// The name must be unique.
func (ctrl *ProvisionController) getProvisionedVolumeNameForClaim(claim *v1.PersistentVolumeClaim) string {
	return "pvc-" + string(claim.UID)
}

// getStorageClass retrives storage class object by name.
func (ctrl *ProvisionController) getStorageClass(name string) (*storage.StorageClass, error) {
	classObj, found, err := ctrl.classes.GetByKey(name)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, fmt.Errorf("storageClass %q not found", name)
	}
	switch class := classObj.(type) {
	case *storage.StorageClass:
		return class, nil
	case *storagebeta.StorageClass:
		// convert storagebeta.StorageClass to storage.StorageClass
		return &storage.StorageClass{
			ObjectMeta:           class.ObjectMeta,
			Provisioner:          class.Provisioner,
			Parameters:           class.Parameters,
			ReclaimPolicy:        class.ReclaimPolicy,
			MountOptions:         class.MountOptions,
			AllowVolumeExpansion: class.AllowVolumeExpansion,
			VolumeBindingMode:    (*storage.VolumeBindingMode)(class.VolumeBindingMode),
			AllowedTopologies:    class.AllowedTopologies,
		}, nil
	}
	return nil, fmt.Errorf("cannot convert object to StorageClass: %+v", classObj)
}

func claimToClaimKey(claim *v1.PersistentVolumeClaim) string {
	return fmt.Sprintf("%s/%s", claim.Namespace, claim.Name)
}

// supportsBlock returns whether a provisioner supports block volume.
// Provisioners that implement BlockProvisioner interface and return true to SupportsBlock
// will be regarded as supported for block volume.
func (ctrl *ProvisionController) supportsBlock(ctx context.Context) bool {
	if blockProvisioner, ok := ctrl.provisioner.(BlockProvisioner); ok {
		return blockProvisioner.SupportsBlock(ctx)
	}
	return false
}

func getString(m map[string]string, key string, alts ...string) (string, bool) {
	if m == nil {
		return "", false
	}
	keys := append([]string{key}, alts...)
	for _, k := range keys {
		if v, ok := m[k]; ok {
			return v, true
		}
	}
	return "", false
}
