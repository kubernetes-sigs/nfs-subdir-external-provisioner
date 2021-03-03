# NFS Subdirectory External Provisioner Helm Chart

The [NFS subdir external provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) is an automatic provisioner for Kubernetes that uses your *already configured* NFS server, automatically creating Persistent Volumes.

## TL;DR;

```console
$ helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
$ helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=x.x.x.x \
    --set nfs.path=/exported/path
```

## Introduction

This charts installs custom [storage class](https://kubernetes.io/docs/concepts/storage/storage-classes/) into a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager. It also installs a [NFS client provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) into the cluster which dynamically creates persistent volumes from single NFS share.

## Prerequisites

- Kubernetes >=1.9
- Existing NFS Share

## Installing the Chart

To install the chart with the release name `my-release`:

```console
$ helm install my-release nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=x.x.x.x \
    --set nfs.path=/exported/path
```

The command deploys the given storage class in the default configuration. It can be used afterswards to provision persistent volumes. The [configuration](#configuration) section lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm list`

## Uninstalling the Chart

To uninstall/delete the `my-release` deployment:

```console
$ helm delete my-release
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

The following tables lists the configurable parameters of this chart and their default values.

| Parameter                           | Description                                                 | Default                                           |
| ----------------------------------- | ----------------------------------------------------------- | ------------------------------------------------- |
| `replicaCount`                      | Number of provisioner instances to deployed                 | `1`                                               |
| `strategyType`                      | Specifies the strategy used to replace old Pods by new ones | `Recreate`                                        |
| `image.repository`                  | Provisioner image                                           | `gcr.io/k8s-staging-sig-storage/nfs-subdir-external-provisioner` |
| `image.tag`                         | Version of provisioner image                                | `v4.0.0`                                  |
| `image.pullPolicy`                  | Image pull policy                                           | `IfNotPresent`                                    |
| `storageClass.name`                 | Name of the storageClass                                    | `nfs-client`                                      |
| `storageClass.defaultClass`         | Set as the default StorageClass                             | `false`                                           |
| `storageClass.allowVolumeExpansion` | Allow expanding the volume                                  | `true`                                            |
| `storageClass.reclaimPolicy`        | Method used to reclaim an obsoleted volume                  | `Delete`                                          |
| `storageClass.provisionerName`      | Name of the provisionerName                                 | null                                              |
| `storageClass.archiveOnDelete`      | Archive pvc when deleting                                   | `true`                                            |
| `storageClass.pathPattern`          | Specifies a template for the directory name                 | null                                              |
| `storageClass.accessModes`          | Set access mode for PV                                      | `ReadWriteOnce`                                   |
| `leaderElection.enabled`            | Enables or disables leader election                         | `true`                                            |
| `nfs.server`                        | Hostname of the NFS server (required)                       | null (ip or hostname)                             |
| `nfs.path`                          | Basepath of the mount point to be used                      | `/nfs-storage`                                 |
| `nfs.mountOptions`                  | Mount options (e.g. 'nfsvers=3')                            | null                                              |
| `resources`                         | Resources required (e.g. CPU, memory)                       | `{}`                                              |
| `rbac.create`                       | Use Role-based Access Control                               | `true`                                            |
| `podSecurityPolicy.enabled`         | Create & use Pod Security Policy resources                  | `false`                                           |
| `priorityClassName`                 | Set pod priorityClassName                                   | null                                              |
| `serviceAccount.create`             | Should we create a ServiceAccount                           | `true`                                            |
| `serviceAccount.name`               | Name of the ServiceAccount to use                           | null                                              |
| `nodeSelector`                      | Node labels for pod assignment                              | `{}`                                              |
| `affinity`                          | Affinity settings                                           | `{}`                                              |
| `tolerations`                       | List of node taints to tolerate                             | `[]`                                              |
