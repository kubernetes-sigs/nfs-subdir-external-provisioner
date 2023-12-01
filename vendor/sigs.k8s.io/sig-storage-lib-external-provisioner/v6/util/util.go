/*
Copyright 2017 The Kubernetes Authors.

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

package util

import (
	"context"
	"net"

	"github.com/miekg/dns"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	glog "k8s.io/klog"
)

// Common allocation units
const (
	KiB int64 = 1024
	MiB int64 = 1024 * KiB
	GiB int64 = 1024 * MiB
	TiB int64 = 1024 * GiB
)

// RoundUpSize calculates how many allocation units are needed to accommodate
// a volume of given size. E.g. when user wants 1500MiB volume, while AWS EBS
// allocates volumes in gibibyte-sized chunks,
// RoundUpSize(1500 * 1024*1024, 1024*1024*1024) returns '2'
// (2 GiB is the smallest allocatable volume that can hold 1500MiB)
func RoundUpSize(volumeSizeBytes int64, allocationUnitBytes int64) int64 {
	return (volumeSizeBytes + allocationUnitBytes - 1) / allocationUnitBytes
}

// RoundUpToGiB rounds up given quantity upto chunks of GiB
func RoundUpToGiB(sizeBytes int64) int64 {
	return RoundUpSize(sizeBytes, GiB)
}

// AccessModesContains returns whether the requested mode is contained by modes
func AccessModesContains(modes []v1.PersistentVolumeAccessMode, mode v1.PersistentVolumeAccessMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}
	return false
}

// AccessModesContainedInAll returns whether all of the requested modes are contained by modes
func AccessModesContainedInAll(indexedModes []v1.PersistentVolumeAccessMode, requestedModes []v1.PersistentVolumeAccessMode) bool {
	for _, mode := range requestedModes {
		if !AccessModesContains(indexedModes, mode) {
			return false
		}
	}
	return true
}

// GetPersistentVolumeClass returns StorageClassName.
func GetPersistentVolumeClass(volume *v1.PersistentVolume) string {
	// Use beta annotation first
	if class, found := volume.Annotations[v1.BetaStorageClassAnnotation]; found {
		return class
	}

	return volume.Spec.StorageClassName
}

// GetPersistentVolumeClaimClass returns StorageClassName. If no storage class was
// requested, it returns "".
func GetPersistentVolumeClaimClass(claim *v1.PersistentVolumeClaim) string {
	// Use beta annotation first
	if class, found := claim.Annotations[v1.BetaStorageClassAnnotation]; found {
		return class
	}

	if claim.Spec.StorageClassName != nil {
		return *claim.Spec.StorageClassName
	}

	return ""
}

// CheckPersistentVolumeClaimModeBlock checks VolumeMode.
// If the mode is Block, return true otherwise return false.
func CheckPersistentVolumeClaimModeBlock(pvc *v1.PersistentVolumeClaim) bool {
	return pvc.Spec.VolumeMode != nil && *pvc.Spec.VolumeMode == v1.PersistentVolumeBlock
}

// FindDNSIP looks up the cluster DNS service by label "coredns", falling back to "kube-dns" if not found
func FindDNSIP(ctx context.Context, client kubernetes.Interface) (dnsip string) {
	// find DNS server address through client API
	// cache result in rbdProvisioner
	var dnssvc *v1.Service
	coredns, err := client.CoreV1().Services(metav1.NamespaceSystem).Get(ctx, "coredns", metav1.GetOptions{})
	if err != nil {
		glog.Warningf("error getting coredns service: %v. Falling back to kube-dns\n", err)
		kubedns, err := client.CoreV1().Services(metav1.NamespaceSystem).Get(ctx, "kube-dns", metav1.GetOptions{})
		if err != nil {
			glog.Errorf("error getting kube-dns service: %v\n", err)
			return ""
		}
		dnssvc = kubedns
	} else {
		dnssvc = coredns
	}
	if len(dnssvc.Spec.ClusterIP) == 0 {
		glog.Errorf("DNS service ClusterIP bad\n")
		return ""
	}
	return dnssvc.Spec.ClusterIP
}

// LookupHost looks up IP addresses of hostname on specified DNS server
func LookupHost(hostname string, serverip string) (iplist []string, err error) {
	glog.V(4).Infof("lookuphost %q on %q\n", hostname, serverip)
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(hostname), dns.TypeA)
	in, err := dns.Exchange(m, JoinHostPort(serverip, "53"))
	if err != nil {
		glog.Errorf("dns lookup of %q failed: err %v", hostname, err)
		return nil, err
	}
	for _, a := range in.Answer {
		glog.V(4).Infof("lookuphost answer: %v\n", a)
		if t, ok := a.(*dns.A); ok {
			iplist = append(iplist, t.A.String())
		}
	}
	return iplist, nil
}

// SplitHostPort split a string into host and port (port is optional)
func SplitHostPort(hostport string) (host, port string) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		host, port = hostport, ""
	}
	return host, port
}

// JoinHostPort joins a hostname and an optional port
func JoinHostPort(host, port string) (hostport string) {
	if port != "" {
		return net.JoinHostPort(host, port)
	}
	return host
}
