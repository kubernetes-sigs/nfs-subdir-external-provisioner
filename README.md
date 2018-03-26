# Kubernetes NFS-Client Provisioner

[![Docker Repository on Quay](https://quay.io/repository/external_storage/nfs-client-provisioner/status "Docker Repository on Quay")](https://quay.io/repository/external_storage/nfs-client-provisioner)


`nfs-client` is an automatic provisioner that used your *already configured* NFS server, automatically creating Persistent Volumes.

- Persistent volumes are provisioned as ${namespace}-${pvcName}-${pvName}
- Persistent volumes which are recycled as archieved-${namespace}-${pvcName}-${pvName}

# How to deploy nfs-client to your cluster.

To note, you must *already* have an NFS Server.

1. Editing:

Note: To deploy to an ARM-based environment, use: `deploy/deployment-arm.yaml` instead, otherwise use `deploy/deployment.yaml`.
Modify `deploy/deployment.yaml` and change the values to your own NFS server:


```yaml
          env:
            - name: PROVISIONER_NAME
              value: fuseim.pri/ifs
            - name: NFS_SERVER
              value: 10.10.10.60
            - name: NFS_PATH
              value: /ifs/kubernetes
      volumes:
        - name: nfs-client-root
          nfs:
            server: 10.10.10.60
            path: /ifs/kubernetes
```

Modify `deploy/class.yaml` to match the same value indicated by `PROVISIONER_NAME`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-nfs-storage
provisioner: fuseim.pri/ifs # or choose another name, must match deployment's env PROVISIONER_NAME'
```

2. Authorization

If your cluster has RBAC enabled or you are running OpenShift you must authorize the provisioner. If you are in a namespace/project other than "default" either edit `deploy/auth/clusterrolebinding.yaml` or edit the `oadm policy` command accordingly.

Kubernetes:

```sh
$ kubectl create -f deploy/auth/serviceaccount.yaml -f deploy/auth/clusterrole.yaml -f deploy/auth/clusterrolebinding.yaml
serviceaccount "nfs-client-provisioner" created
clusterrole "nfs-client-provisioner-runner" created
clusterrolebinding "run-nfs-client-provisioner" created
```

OpenShift:

```sh
$ oc create -f deploy/auth/openshift-clusterrole.yaml -f deploy/auth/serviceaccount.yaml
serviceaccount "nfs-client-provisioner" created
clusterrole "nfs-client-provisioner-runner" created
$ oadm policy add-scc-to-user hostmount-anyuid system:serviceaccount:default:nfs-client-provisioner
$ oadm policy add-cluster-role-to-user nfs-client-provisioner-runner system:serviceaccount:default:nfs-client-provisioner
```

3. Finally, test your environment!

Now we'll test your NFS provisioner.

Deploy:

```sh
$ kubectl create -f deploy/test-claim.yaml -f deploy/test-pod.yaml
```

Now check your NFS Server for the file `SUCCESS`.

```sh
kubectl delete -f deploy/test-pod.yaml -f deploy/test-claim.yaml
```

Now check the folder renamed to `archived-???`.

4. Deploying your own PersistentVolumeClaim

To deploy your own PVC, make sure that you have the correct `storage-class` as indicated by your `deploy/class.yaml` file.

For example:

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-claim
  annotations:
    volume.beta.kubernetes.io/storage-class: "managed-nfs-storage"
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
```
