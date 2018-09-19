# Kubernetes NFS-Client Provisioner

[![Docker Repository on Quay](https://quay.io/repository/external_storage/nfs-client-provisioner/status "Docker Repository on Quay")](https://quay.io/repository/external_storage/nfs-client-provisioner)

**nfs-client** is an automatic provisioner that use your *existing and already configured* NFS server to support dynamic provisioning of Kubernetes Persistent Volumes via Persistent Volume Claims. Persistent volumes are provisioned as ``${namespace}-${pvcName}-${pvName}``.

# How to deploy nfs-client to your cluster.

To note again, you must *already* have an NFS Server.

## With Helm

Follow the instructions for the stable helm chart maintained at https://github.com/helm/charts/tree/master/stable/nfs-client-provisioner

The tl;dr is

```bash
$ helm install stable/nfs-client-provisioner --set nfs.server=x.x.x.x --set nfs.path=/exported/path
```

## Without Helm

**Step 1: Get connection information for your NFS server**. Make sure your NFS server is accessible from your Kubernetes cluster and get the information you need to connect to it. At a minimum you will need its hostname.

**Step 2: Get the NFS-Client Provisioner files**. To setup the provisioner you will download a set of YAML files, edit them to add your NFS server's connection information and then apply each with the ``kubectl`` / ``oc`` command. 

Get all of the files in the [deploy](https://github.com/kubernetes-incubator/external-storage/tree/master/nfs-client/deploy) directory of this repository. These instructions assume that you have cloned the [external-storage](https://github.com/kubernetes-incubator/external-storage) repository and have a bash-shell open in the ``nfs-client`` directory.

**Step 3: Setup authorization**. If your cluster has RBAC enabled or you are running OpenShift you must authorize the provisioner. If you are in a namespace/project other than "default" edit `deploy/rbac.yaml`.

Kubernetes:

```sh
# Set the subject of the RBAC objects to the current namespace where the provisioner is being deployed
$ NS=$(kubectl config get-contexts|grep -e "^\*" |awk '{print $5}')
$ NAMESPACE=${NS:-default}
$ sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml
$ kubectl create -f deploy/rbac.yaml
```

OpenShift:

On some installations of OpenShift the default admin user does not have cluster-admin permissions. If these commands fail refer to the OpenShift documentation for **User and Role Management** or contact your OpenShift provider to help you grant the right permissions to your admin user. 

```sh
# Set the subject of the RBAC objects to the current namespace where the provisioner is being deployed
$ NAMESPACE=`oc project -q`
$ sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml
$ oc create -f deploy/rbac.yaml
$ oadm policy add-scc-to-user hostmount-anyuid system:serviceaccount:$NAMESPACE:nfs-client-provisioner
```

**Step 4: Configure the NFS-Client provisioner**

Note: To deploy to an ARM-based environment, use: `deploy/deployment-arm.yaml` instead, otherwise use `deploy/deployment.yaml`.

Next you must edit the provisioner's deployment file to add connection information for your NFS server. Edit `deploy/deployment.yaml` and replace the two occurences of <YOUR NFS SERVER HOSTNAME> with your server's hostname.

```yaml
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  name: nfs-client-provisioner
spec:
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: quay.io/external_storage/nfs-client-provisioner:latest
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: fuseim.pri/ifs
            - name: NFS_SERVER
              value: <YOUR NFS SERVER HOSTNAME>
            - name: NFS_PATH
              value: /var/nfs
      volumes:
        - name: nfs-client-root
          nfs:
            server: <YOUR NFS SERVER HOSTNAME>
            path: /var/nfs
```

You may also want to change the PROVISIONER_NAME above from ``fuseim.pri/ifs`` to something more descriptive like ``nfs-storage``, but if you do remember to also change the PROVISIONER_NAME in the storage class definition below:

This is `deploy/class.yaml` which defines the NFS-Client's Kubernetes Storage Class:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-nfs-storage
provisioner: fuseim.pri/ifs # or choose another name, must match deployment's env PROVISIONER_NAME'
parameters:
  archiveOnDelete: "false" # When set to "false" your PVs will not be archived
                           # by the provisioner upon deletion of the PVC.
```

**Step 5: Finally, test your environment!**

Now we'll test your NFS provisioner.

Deploy:

```sh
$ kubectl create -f deploy/test-claim.yaml -f deploy/test-pod.yaml
```

Now check your NFS Server for the file `SUCCESS`.

```sh
kubectl delete -f deploy/test-pod.yaml -f deploy/test-claim.yaml
```

Now check the folder has been deleted.

**Step 6: Deploying your own PersistentVolumeClaims**. To deploy your own PVC, make sure that you have the correct `storage-class` as indicated by your `deploy/class.yaml` file.

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
