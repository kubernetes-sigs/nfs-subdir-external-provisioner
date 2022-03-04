/*
Copyright 2019 The Kubernetes Authors.

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
	"fmt"
	"sync"
	"time"

	v1 "k8s.io/api/core/v1"
	apierrs "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/workqueue"
	"k8s.io/klog"
)

// VolumeStore is an interface that's used to save PersistentVolumes to API server.
// Implementation of the interface add custom error recovery policy.
// A volume is added via StoreVolume(). It's enough to store the volume only once.
// It is not possible to remove a volume, even when corresponding PVC is deleted
// and PV is not necessary any longer. PV will be always created.
// If corresponding PVC is deleted, the PV will be deleted by Kubernetes using
// standard deletion procedure. It saves us some code here.
type VolumeStore interface {
	// StoreVolume makes sure a volume is saved to Kubernetes API server.
	// If no error is returned, caller can assume that PV was saved or
	// is being saved in background.
	// In error is returned, no PV was saved and corresponding PVC needs
	// to be re-queued (so whole provisioning needs to be done again).
	StoreVolume(claim *v1.PersistentVolumeClaim, volume *v1.PersistentVolume) error

	// Runs any background goroutines for implementation of the interface.
	Run(ctx context.Context, threadiness int)
}

// queueStore is implementation of VolumeStore that re-tries saving
// PVs to API server using a workqueue running in its own goroutine(s).
// After failed save, volume is re-qeueued with exponential backoff.
type queueStore struct {
	client        kubernetes.Interface
	queue         workqueue.RateLimitingInterface
	eventRecorder record.EventRecorder
	claimsIndexer cache.Indexer

	volumes sync.Map
}

var _ VolumeStore = &queueStore{}

// NewVolumeStoreQueue returns VolumeStore that uses asynchronous workqueue to save PVs.
func NewVolumeStoreQueue(
	client kubernetes.Interface,
	limiter workqueue.RateLimiter,
	claimsIndexer cache.Indexer,
	eventRecorder record.EventRecorder,
) VolumeStore {

	return &queueStore{
		client:        client,
		queue:         workqueue.NewNamedRateLimitingQueue(limiter, "unsavedpvs"),
		claimsIndexer: claimsIndexer,
		eventRecorder: eventRecorder,
	}
}

func (q *queueStore) StoreVolume(_ *v1.PersistentVolumeClaim, volume *v1.PersistentVolume) error {
	if err := q.doSaveVolume(volume); err != nil {
		q.volumes.Store(volume.Name, volume)
		q.queue.Add(volume.Name)
		klog.Errorf("Failed to save volume %s: %s", volume.Name, err)
	}
	// Consume any error, this Store will retry in background.
	return nil
}

func (q *queueStore) Run(ctx context.Context, threadiness int) {
	klog.Infof("Starting save volume queue")
	defer q.queue.ShutDown()

	for i := 0; i < threadiness; i++ {
		go wait.Until(q.saveVolumeWorker, time.Second, ctx.Done())
	}
	<-ctx.Done()
	klog.Infof("Stopped save volume queue")
}

func (q *queueStore) saveVolumeWorker() {
	for q.processNextWorkItem() {
	}
}

func (q *queueStore) processNextWorkItem() bool {
	obj, shutdown := q.queue.Get()
	defer q.queue.Done(obj)

	if shutdown {
		return false
	}

	var volumeName string
	var ok bool
	if volumeName, ok = obj.(string); !ok {
		q.queue.Forget(obj)
		utilruntime.HandleError(fmt.Errorf("expected string in save workqueue but got %#v", obj))
		return true
	}

	volumeObj, found := q.volumes.Load(volumeName)
	if !found {
		q.queue.Forget(volumeName)
		utilruntime.HandleError(fmt.Errorf("did not find saved volume %s", volumeName))
		return true
	}

	volume, ok := volumeObj.(*v1.PersistentVolume)
	if !ok {
		q.queue.Forget(volumeName)
		utilruntime.HandleError(fmt.Errorf("saved object is not volume: %+v", volumeObj))
		return true
	}

	if err := q.doSaveVolume(volume); err != nil {
		q.queue.AddRateLimited(volumeName)
		utilruntime.HandleError(err)
		klog.V(5).Infof("Volume %s enqueued", volume.Name)
		return true
	}
	q.volumes.Delete(volumeName)
	q.queue.Forget(volumeName)
	return true
}

func (q *queueStore) doSaveVolume(volume *v1.PersistentVolume) error {
	klog.V(5).Infof("Saving volume %s", volume.Name)
	_, err := q.client.CoreV1().PersistentVolumes().Create(context.Background(), volume, metav1.CreateOptions{})
	if err == nil || apierrs.IsAlreadyExists(err) {
		klog.V(5).Infof("Volume %s saved", volume.Name)
		q.sendSuccessEvent(volume)
		return nil
	}
	return fmt.Errorf("error saving volume %s: %s", volume.Name, err)
}

func (q *queueStore) sendSuccessEvent(volume *v1.PersistentVolume) {
	claimObjs, err := q.claimsIndexer.ByIndex(uidIndex, string(volume.Spec.ClaimRef.UID))
	if err != nil {
		klog.V(2).Infof("Error sending event to claim %s: %s", volume.Spec.ClaimRef.UID, err)
		return
	}
	if len(claimObjs) != 1 {
		return
	}
	claim, ok := claimObjs[0].(*v1.PersistentVolumeClaim)
	if !ok {
		return
	}
	msg := fmt.Sprintf("Successfully provisioned volume %s", volume.Name)
	q.eventRecorder.Event(claim, v1.EventTypeNormal, "ProvisioningSucceeded", msg)
}

// backoffStore is implementation of VolumeStore that blocks and tries to save
// a volume to API server with configurable backoff. If saving fails,
// StoreVolume() deletes the storage asset in the end and returns appropriate
// error code.
type backoffStore struct {
	client        kubernetes.Interface
	eventRecorder record.EventRecorder
	backoff       *wait.Backoff
	ctrl          *ProvisionController
}

var _ VolumeStore = &backoffStore{}

// NewBackoffStore returns VolumeStore that uses blocking exponential backoff to save PVs.
func NewBackoffStore(client kubernetes.Interface,
	eventRecorder record.EventRecorder,
	backoff *wait.Backoff,
	ctrl *ProvisionController,
) VolumeStore {
	return &backoffStore{
		client:        client,
		eventRecorder: eventRecorder,
		backoff:       backoff,
		ctrl:          ctrl,
	}
}

func (b *backoffStore) StoreVolume(claim *v1.PersistentVolumeClaim, volume *v1.PersistentVolume) error {
	// Try to create the PV object several times
	var lastSaveError error
	err := wait.ExponentialBackoff(*b.backoff, func() (bool, error) {
		klog.Infof("Trying to save persistentvolume %q", volume.Name)
		var err error
		if _, err = b.client.CoreV1().PersistentVolumes().Create(context.Background(), volume, metav1.CreateOptions{}); err == nil || apierrs.IsAlreadyExists(err) {
			// Save succeeded.
			if err != nil {
				klog.Infof("persistentvolume %q already exists, reusing", volume.Name)
			} else {
				klog.Infof("persistentvolume %q saved", volume.Name)
			}
			return true, nil
		}
		// Save failed, try again after a while.
		klog.Infof("Failed to save persistentvolume %q: %v", volume.Name, err)
		lastSaveError = err
		return false, nil
	})

	if err == nil {
		// Save succeeded
		msg := fmt.Sprintf("Successfully provisioned volume %s", volume.Name)
		b.eventRecorder.Event(claim, v1.EventTypeNormal, "ProvisioningSucceeded", msg)
		return nil
	}

	// Save failed. Now we have a storage asset outside of Kubernetes,
	// but we don't have appropriate PV object for it.
	// Emit some event here and try to delete the storage asset several
	// times.
	strerr := fmt.Sprintf("Error creating provisioned PV object for claim %s: %v. Deleting the volume.", claimToClaimKey(claim), lastSaveError)
	klog.Error(strerr)
	b.eventRecorder.Event(claim, v1.EventTypeWarning, "ProvisioningFailed", strerr)

	var lastDeleteError error
	err = wait.ExponentialBackoff(*b.backoff, func() (bool, error) {
		if err = b.ctrl.provisioner.Delete(context.Background(), volume); err == nil {
			// Delete succeeded
			klog.Infof("Cleaning volume %q succeeded", volume.Name)
			return true, nil
		}
		// Delete failed, try again after a while.
		klog.Infof("Failed to clean volume %q: %v", volume.Name, err)
		lastDeleteError = err
		return false, nil
	})
	if err != nil {
		// Delete failed several times. There is an orphaned volume and there
		// is nothing we can do about it.
		strerr := fmt.Sprintf("Error cleaning provisioned volume for claim %s: %v. Please delete manually.", claimToClaimKey(claim), lastDeleteError)
		klog.Error(strerr)
		b.eventRecorder.Event(claim, v1.EventTypeWarning, "ProvisioningCleanupFailed", strerr)
	}

	return lastSaveError
}

func (b *backoffStore) Run(ctx context.Context, threadiness int) {
	// There is not background processing
}
