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
	"fmt"

	"k8s.io/api/core/v1"
	storageapis "k8s.io/api/storage/v1"
)

// Provisioner is an interface that creates templates for PersistentVolumes
// and can create the volume as a new resource in the infrastructure provider.
// It can also remove the volume it created from the underlying storage
// provider.
type Provisioner interface {
	// Provision creates a volume i.e. the storage asset and returns a PV object
	// for the volume. The provisioner can return an error (e.g. timeout) and state
	// ProvisioningInBackground to tell the controller that provisioning may be in
	// progress after Provision() finishes. The controller will call Provision()
	// again with the same parameters, assuming that the provisioner continues
	// provisioning the volume. The provisioner must return either final error (with
	// ProvisioningFinished) or success eventually, otherwise the controller will try
	// forever (unless FailedProvisionThreshold is set).
	Provision(context.Context, ProvisionOptions) (*v1.PersistentVolume, ProvisioningState, error)
	// Delete removes the storage asset that was created by Provision backing the
	// given PV. Does not delete the PV object itself.
	//
	// May return IgnoredError to indicate that the call has been ignored and no
	// action taken.
	Delete(context.Context, *v1.PersistentVolume) error
}

// Qualifier is an optional interface implemented by provisioners to determine
// whether a claim should be provisioned as early as possible (e.g. prior to
// leader election).
type Qualifier interface {
	// ShouldProvision returns whether provisioning for the claim should
	// be attempted.
	ShouldProvision(context.Context, *v1.PersistentVolumeClaim) bool
}

// DeletionGuard is an optional interface implemented by provisioners to determine
// whether a PV should be deleted.
type DeletionGuard interface {
	// ShouldDelete returns whether deleting the PV should be attempted.
	ShouldDelete(context.Context, *v1.PersistentVolume) bool
}

// BlockProvisioner is an optional interface implemented by provisioners to determine
// whether it supports block volume.
type BlockProvisioner interface {
	Provisioner
	// SupportsBlock returns whether provisioner supports block volume.
	SupportsBlock(context.Context) bool
}

// ProvisioningState is state of volume provisioning. It tells the controller if
// provisioning could be in progress in the background after Provision() call
// returns or the provisioning is 100% finished (either with success or error).
type ProvisioningState string

const (
	// ProvisioningInBackground tells the controller that provisioning may be in
	// progress in background after Provision call finished.
	ProvisioningInBackground ProvisioningState = "Background"
	// ProvisioningFinished tells the controller that provisioning for sure does
	// not continue in background, error code of Provision() is final.
	ProvisioningFinished ProvisioningState = "Finished"
	// ProvisioningNoChange tells the controller that provisioning state is the same as
	// before the call - either ProvisioningInBackground or ProvisioningFinished from
	// the previous Provision(). This state is typically returned by a provisioner
	// before it could reach storage backend - the provisioner could not check status
	// of provisioning and previous state applies. If this state is returned from the
	// first Provision call, ProvisioningFinished is assumed (the provisioning
	// could not even start).
	ProvisioningNoChange ProvisioningState = "NoChange"
	// ProvisioningReschedule tells the controller that it shall stop all further
	// attempts to provision the volume and instead ask the Kubernetes scheduler
	// to pick a different node. This only makes sense for volumes with a selected
	// node, i.e. those with late binding, and must only be returned when it is certain
	// that provisioning does not continue in the background. The error returned together
	// with this state contains further information why rescheduling is needed.
	ProvisioningReschedule ProvisioningState = "Reschedule"
)

// IgnoredError is the value for Delete to return to indicate that the call has
// been ignored and no action taken. In case multiple provisioners are serving
// the same storage class, provisioners may ignore PVs they are not responsible
// for (e.g. ones they didn't create). The controller will act accordingly,
// i.e. it won't emit a misleading VolumeFailedDelete event.
type IgnoredError struct {
	Reason string
}

func (e *IgnoredError) Error() string {
	return fmt.Sprintf("ignored because %s", e.Reason)
}

// ProvisionOptions contains all information required to provision a volume
type ProvisionOptions struct {
	// StorageClass is a reference to the storage class that is used for
	// provisioning for this volume
	StorageClass *storageapis.StorageClass

	// PV.Name of the appropriate PersistentVolume. Used to generate cloud
	// volume name.
	PVName string

	// PVC is reference to the claim that lead to provisioning of a new PV.
	// Provisioners *must* create a PV that would be matched by this PVC,
	// i.e. with required capacity, accessMode, labels matching PVC.Selector and
	// so on.
	PVC *v1.PersistentVolumeClaim

	// Node selected by the scheduler for the volume.
	SelectedNode *v1.Node
}
