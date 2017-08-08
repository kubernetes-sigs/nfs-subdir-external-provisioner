# kubernetes nfs-client-provisioner

[![Docker Repository on Quay](https://quay.io/repository/external_storage/nfs-client-provisioner/status "Docker Repository on Quay")](https://quay.io/repository/external_storage/nfs-client-provisioner)

- pv provisioned as ${namespace}-${pvcName}-${pvName}
- pv recycled as archieved-${namespace}-${pvcName}-${pvName}

# deploy
- modify and deploy `deploy/deployment.yaml`
- modify and deploy `deploy/class.yaml`

## ARM based
To deploy on ARM based (Raspberry PI) use `deploy/deployment-arm.yaml` instead of `deploy/deployment.yaml`

# authorization

If your cluster has RBAC enabled or you are running OpenShift you must
authorize the provisioner. If you are in a namespace/project other than
"default" either edit `deploy/auth/clusterrolebinding.yaml` or edit the `oadm
policy` command accordingly.

## RBAC
```console
$ kubectl create -f deploy/auth/serviceaccount.yaml
serviceaccount "nfs-client-provisioner" created
$ kubectl create -f deploy/auth/clusterrole.yaml
clusterrole "nfs-client-provisioner-runner" created
$ kubectl create -f deploy/auth/clusterrolebinding.yaml
clusterrolebinding "run-nfs-client-provisioner" created
$ kubectl patch deployment nfs-client-provisioner -p '{"spec":{"template":{"spec":{"serviceAccount":"nfs-client-provisioner"}}}}'
```

## OpenShift
```console
$ oc create -f deploy/auth/serviceaccount.yaml
serviceaccount "nfs-client-provisioner" created
$ oc create -f deploy/auth/openshift-clusterrole.yaml
clusterrole "nfs-client-provisioner-runner" created
$ oadm policy add-scc-to-user hostmount-anyuid system:serviceaccount:default:nfs-client-provisioner
$ oadm policy add-cluster-role-to-user nfs-client-provisioner-runner system:serviceaccount:default:nfs-client-provisioner
$ oc patch deployment nfs-client-provisioner -p '{"spec":{"template":{"spec":{"serviceAccount":"nfs-client-provisioner"}}}}'
```

# test
- `kubectl create -f deploy/test-claim.yaml`
- `kubectl create -f deploy/test-pod.yaml`
- check the folder and file "SUCCESS" created
- `kubectl delete -f deploy/test-pod.yaml`
- `kubectl delete -f deploy/test-claim.yaml`
- check the folder renamed to `archived-???`
