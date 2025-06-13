# Kubernetes NFS Subdir External Provisioner

**NFS subdir external provisioner** is an automatic provisioner that use your _existing and already configured_ NFS server to support dynamic provisioning of Kubernetes Persistent Volumes via Persistent Volume Claims. Persistent volumes are provisioned as `${namespace}-${pvcName}-${pvName}`.

Note: This repository is migrated from https://github.com/kubernetes-incubator/external-storage/tree/master/nfs-client. As part of the migration:
- The container image name and repository has changed to `registry.k8s.io/sig-storage` and `nfs-subdir-external-provisioner` respectively.
- To maintain backward compatibility with earlier deployment files, the naming of NFS Client Provisioner is retained as `nfs-client-provisioner` in the deployment YAMLs.
- One of the pending areas for development on this repository is to add automated e2e tests. If you would like to contribute, please raise an issue or reach us on the Kubernetes slack #sig-storage channel.

## How to deploy NFS Subdir External Provisioner to your cluster

To note again, you must _already_ have an NFS Server.

### With Helm

Follow the instructions from the helm chart [README](charts/nfs-subdir-external-provisioner/README.md).

The tl;dr is

```console
$ helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
$ helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=x.x.x.x \
    --set nfs.path=/exported/path
```

### With Kustomize

**Step 1: Get connection information for your NFS server**

Make sure your NFS server is accessible from your Kubernetes cluster and get the information you need to connect to it. At a minimum you will need its hostname and exported share path.

**Step 2: Add the base resource**

Create a `kustomization.yaml` file in a directory of your choice, and add the [deploy](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/tree/master/deploy) directory as a base. This will use the kustomization file within that directory as our base.

```yaml
namespace: nfs-provisioner
bases:
  - github.com/kubernetes-sigs/nfs-subdir-external-provisioner//deploy
```

**Step 3: Create namespace resource**

Create a file with your namespace resource. The name can be anything as it will get overwritten by the namespace in your kustomization file.

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner
```

**Step 4: Configure deployment**

To configure the deployment, you will need to patch it's container variables with the connection information for your NFS Server.

```yaml
# patch_nfs_details.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: nfs-client-provisioner
  name: nfs-client-provisioner
spec:
  template:
    spec:
      containers:
        - name: nfs-client-provisioner
          env:
            - name: NFS_SERVER
              value: <YOUR_NFS_SERVER_IP>
            - name: NFS_PATH
              value: <YOUR_NFS_SERVER_SHARE>
      volumes:
        - name: nfs-client-root
          nfs:
            server: <YOUR_NFS_SERVER_IP>
            path: <YOUR_NFS_SERVER_SHARE>
```

Replace occurrences of `<YOUR_NFS_SERVER_IP>` and `<YOUR_NFS_SERVER_SHARE>` with your connection information.

**Step 5: Add resources and deploy**

Add the namespace resource and patch you created in earlier steps.

```yaml
namespace: nfs-provisioner
bases:
  - github.com/kubernetes-sigs/nfs-subdir-external-provisioner//deploy
resources:
  - namespace.yaml
patchesStrategicMerge:
  - patch_nfs_details.yaml
```

Deploy (run inside directory with your kustomization file):

```sh
kubectl apply -k .
```

**Step 6: Finally, test your environment!**

Now we'll test your NFS subdir external provisioner by creating a persistent volume claim and a pod that writes a test file to the volume. This will make sure that the provisioner is provisioning and that the NFS server is reachable and writable.

Deploy the test resources:

```sh
$ kubectl create -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/test-claim.yaml -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/test-pod.yaml
```

Now check your NFS Server for the `SUCCESS` inside the PVC's directory.

Delete the test resources:

```sh
$ kubectl delete -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/test-claim.yaml -f https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/master/deploy/test-pod.yaml
```

Now check the PVC's directory has been deleted.

**Step 7: Deploying your own PersistentVolumeClaims**

To deploy your own PVC, make sure that you have the correct `storageClassName` (by default `nfs-client`). You can also patch the StorageClass resource to change it, like so:

```yaml
# kustomization.yaml
namespace: nfs-provisioner
resources:
  - github.com/kubernetes-sigs/nfs-subdir-external-provisioner//deploy
  - namespace.yaml
patches:
- target:
    kind: StorageClass
    name: nfs-client
  patch: |-
    - op: replace
      path: /metadata/name
      value: <YOUR-STORAGECLASS-NAME>
```

### Manually

**Step 1: Get connection information for your NFS server**

Make sure your NFS server is accessible from your Kubernetes cluster and get the information you need to connect to it. At a minimum you will need its hostname.

**Step 2: Get the NFS Subdir External Provisioner files**

To setup the provisioner you will download a set of YAML files, edit them to add your NFS server's connection information and then apply each with the `kubectl` / `oc` command.

Get all of the files in the [deploy](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/tree/master/deploy) directory of this repository. These instructions assume that you have cloned the [kubernetes-sigs/nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/) repository and have a bash-shell open in the root directory.

**Step 3: Setup authorization**

If your cluster has RBAC enabled or you are running OpenShift you must authorize the provisioner. If you are in a namespace/project other than "default" edit `deploy/rbac.yaml`.

**Kubernetes:**

```sh
# Set the subject of the RBAC objects to the current namespace where the provisioner is being deployed
$ NS=$(kubectl config get-contexts|grep -e "^\*" |awk '{print $5}')
$ NAMESPACE=${NS:-default}
$ sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml ./deploy/deployment.yaml
$ kubectl create -f deploy/rbac.yaml
```

**OpenShift:**

On some installations of OpenShift the default admin user does not have cluster-admin permissions. If these commands fail refer to the OpenShift documentation for **User and Role Management** or contact your OpenShift provider to help you grant the right permissions to your admin user.
On OpenShift the service account used to bind volumes does not have the necessary permissions required to use the `hostmount-anyuid` SCC. See also [Role based access to SCC](https://docs.openshift.com/container-platform/4.4/authentication/managing-security-context-constraints.html#role-based-access-to-ssc_configuring-internal-oauth) for more information. If these commands fail refer to the OpenShift documentation for **User and Role Management** or contact your OpenShift provider to help you grant the right permissions to your admin user.

```sh
# Set the subject of the RBAC objects to the current namespace where the provisioner is being deployed
$ NAMESPACE=`oc project -q`
$ sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml ./deploy/deployment.yaml
$ oc create -f deploy/rbac.yaml
$ oc adm policy add-scc-to-user hostmount-anyuid system:serviceaccount:$NAMESPACE:nfs-client-provisioner
```

**Step 4: Configure the NFS subdir external provisioner**

If you would like to use a custom built nfs-subdir-external-provisioner image, you must edit the provisioner's deployment file to specify the correct location of your `nfs-client-provisioner` container image.

Next you must edit the provisioner's deployment file to add connection information for your NFS server. Edit `deploy/deployment.yaml` and replace the two occurences of <YOUR NFS SERVER HOSTNAME> with your server's hostname.

```yaml
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nfs-client-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-client-provisioner
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
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
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

Note: If you want to change the PROVISIONER_NAME above from `k8s-sigs.io/nfs-subdir-external-provisioner` to something else like `myorg/nfs-storage`, remember to also change the PROVISIONER_NAME in the storage class definition below.

To disable leader election, define an env variable named ENABLE_LEADER_ELECTION and set its value to false.

**Step 5: Deploying your storage class**

**_Parameters:_**

| Name            | Description                                                                                                                                                                  |                             Default                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------: |
| onDelete        | If it exists and has a delete value, delete the directory, if it exists and has a retain value, save the directory.                                                          | will be archived with name on the share: `archived-<volume.Name>` |
| archiveOnDelete | If it exists and has a false value, delete the directory. if `onDelete` exists, `archiveOnDelete` will be ignored.                                                           | will be archived with name on the share: `archived-<volume.Name>` |
| pathPattern     | Specifies a template for creating a directory path via PVC metadata's such as labels, annotations, name or namespace. To specify metadata use `${.PVC.<metadata>}`. Example: If folder should be named like `<pvc-namespace>-<pvc-name>`, use `${.PVC.namespace}-${.PVC.name}` as pathPattern. |                               n/a                                |

This is `deploy/class.yaml` which defines the NFS subdir external provisioner's Kubernetes Storage Class:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner # or choose another name, must match deployment's env PROVISIONER_NAME'
parameters:
  pathPattern: "${.PVC.namespace}/${.PVC.annotations.nfs.io/storage-path}" # waits for nfs.io/storage-path annotation, if not specified will accept as empty string.
  onDelete: delete
```

**Step 6: Finally, test your environment!**

Now we'll test your NFS subdir external provisioner.

Deploy:

```sh
$ kubectl create -f deploy/test-claim.yaml -f deploy/test-pod.yaml
```

Now check your NFS Server for the file `SUCCESS`.

```sh
kubectl delete -f deploy/test-pod.yaml -f deploy/test-claim.yaml
```

Now check the folder has been deleted.

**Step 7: Deploying your own PersistentVolumeClaims**

To deploy your own PVC, make sure that you have the correct `storageClassName` as indicated by your `deploy/class.yaml` file.

For example:

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-claim
  annotations:
    nfs.io/storage-path: "test-path" # not required, depending on whether this annotation was shown in the storage class description
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
```

**Step 8: Controlling the permissions and ownership of subdirs**

By default new directories will be created with `root:root` ownership, and `0777` permissions in most environments. If you have a need to control this, you can do so by providing the `NFS_DEFAULT_MODE`, `NFS_DEFAULT_UID` and `NFS_DEFAULT_GID` environment variables (or the appropriate configuration in the Helm chart values). The mode must be an octal representation of a file mode, for example `777`, `0755` etc. The uid and gid must be the numeric ids of your desired user and group, so `1000` not `my_user`. 

If your usecase requires per-PVC ownership and/or mode, this can be done via annotations on your PVC:

- `k8s-sigs.io/nfs-directory-mode`
- `k8s-sigs.io/nfs-directory-uid`
- `k8s-sigs.io/nfs-directory-gid`

The order of precedence is PVC annotations, ENV vars, then root:root 0777 if nothing else has been specified. 

# Build and publish your own container image

To build your own custom container image from this repository, you will have to build and push the nfs-subdir-external-provisioner image using the following instructions.

```sh
make build
make container
# `nfs-subdir-external-provisioner:latest` will be created.
# Note: This will build a single-arch image that matches the machine on which container is built.
# To upload this to your custom registry, say `quay.io/myorg` and arch as amd64, you can use
# docker tag nfs-subdir-external-provisioner:latest quay.io/myorg/nfs-subdir-external-provisioner-amd64:latest
# docker push quay.io/myorg/nfs-subdir-external-provisioner-amd64:latest
```

# Build and publish with GitHub Actions

In a forked repository you can use GitHub Actions pipeline defined in [.github/workflows/release.yml](.github/workflows/release.yml). The pipeline builds Docker images for `linux/amd64`, `linux/arm64`, and `linux/arm/v7` platforms and publishes them using a multi-arch manifest. The pipeline is triggered when you add a tag like `gh-v{major}.{minor}.{patch}` to your commit and push it to GitHub. The tag is used for generating Docker image tags: `latest`, `{major}`, `{major}:{minor}`, `{major}:{minor}:{patch}`.

The pipeline adds several labels:
* `org.opencontainers.image.title=${{ github.event.repository.name }}`
* `org.opencontainers.image.description=${{ github.event.repository.description }}`
* `org.opencontainers.image.url=${{ github.event.repository.html_url }}`
* `org.opencontainers.image.source=${{ github.event.repository.clone_url }}`
* `org.opencontainers.image.created=${{ steps.prep.outputs.created }}`
* `org.opencontainers.image.revision=${{ github.sha }}`
* `org.opencontainers.image.licenses=${{ github.event.repository.license.spdx_id }}`

**Important:**
* The pipeline performs the docker login command using `REGISTRY_USERNAME` and `REGISTRY_TOKEN` secrets, which have to be provided.
* You also need to provide the `DOCKER_IMAGE` secret specifying your Docker image name, e.g., `quay.io/[username]/nfs-subdir-external-provisioner`.


## NFS provisioner limitations/pitfalls
* The provisioned storage is not guaranteed. You may allocate more than the NFS share's total size. The share may also not have enough storage space left to actually accommodate the request.
* The provisioned storage limit is not enforced. The application can expand to use all the available storage regardless of the provisioned size.
* Storage resize/expansion operations are not presently supported in any form. You will end up in an error state: `Ignoring the PVC: didn't find a plugin capable of expanding the volume; waiting for an external controller to process this PVC.`
