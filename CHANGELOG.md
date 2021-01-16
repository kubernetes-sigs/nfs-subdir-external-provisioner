# v4.0.0
- Remove redundant field in the rbac.yaml (https://github.com/kubernetes-retired/external-storage/pull/970)
- Fixing documentation to be correct for both `kubectl` and `oc` (https://github.com/kubernetes-retired/external-storage/pull/969)
- Point nfs-client users to Helm and split up yamls (https://github.com/kubernetes-retired/external-storage/pull/995)
- Use `kubernetes-sigs/sig-storage-lib-external-provisioner` instaed of `incubator/external-storage/lib` (https://github.com/kubernetes-retired/external-storage/pull/1026)
- Fill in rbac.yaml with ServiceAccount manifest (https://github.com/kubernetes-retired/external-storage/pull/1060, https://github.com/kubernetes-retired/external-storage/pull/1179)
- Fix some typos in README (https://github.com/kubernetes-retired/external-storage/pull/1054)
- Make nfs-client ARM deployment consistent with regular deployment (https://github.com/kubernetes-retired/external-storage/pull/1090)
- Update Deployment apiVersion (from `extensions/v1beta1` to `apps/v1`) and added selector field (https://github.com/kubernetes-retired/external-storage/pull/1230/, https://github.com/kubernetes-retired/external-storage/pull/1231/, https://github.com/kubernetes-retired/external-storage/pull/1283/, https://github.com/kubernetes-retired/external-storage/pull/1294/)
- Fix namespace in deployments (https://github.com/kubernetes-retired/external-storage/pull/1087, https://github.com/kubernetes-retired/external-storage/pull/1279)

# v3.1.0
- README Clarifications and minor formatting improvements (https://github.com/kubernetes-retired/external-storage/pull/938/)
- Make leader-election configurable: default endpoints object namespace to controller's instead of kube-system (https://github.com/kubernetes-retired/external-storage/pull/957)

# v3.0.1
- Fix archiveOnDelete parsing (https://github.com/kubernetes-retired/external-storage/pull/929)

# v3.0.0
- Adds archiveOnDelete parameter to provisioner (https://github.com/kubernetes-retired/external-storage/pull/905)
- Change all clusterroles to have endpoints permissions and reduced events permissions, consolidate where possible (https://github.com/kubernetes-retired/external-storage/pull/892)

# v2.1.2
- Propagate StorageClass MountOptions to PVs (https://github.com/kubernetes-retired/external-storage/pull/835)
- Skip deletion if the corresponding directory is not found (https://github.com/kubernetes-retired/external-storage/pull/859)

# v2.1.1
- Revert "Add namespace extended attributes to directory" (https://github.com/kubernetes-retired/external-storage/pull/816)

# v2.1.0
- Change the storage apiVersion from `storage.k8s.io/v1beta1` to `storage.k8s.io/v1` (https://github.com/kubernetes-retired/external-storage/pull/599)
- Fix Makefile to build on OSX (https://github.com/kubernetes-retired/external-storage/pull/661)
- Change the RBAC apiVersion from `rbac.authorization.k8s.io/v1alpha1` to `rbac.authorization.k8s.io/v1` (https://github.com/kubernetes-retired/external-storage/pull/656)
- Add serviceAccount to deployment (https://github.com/kubernetes-retired/external-storage/pull/653)
- README Improvements (https://github.com/kubernetes-retired/external-storage/pull/687)
- Add namespace extended attributes to directory (https://github.com/kubernetes-retired/external-storage/pull/672)

# v2.0.1
- Add support for ARM (Raspberry PI). Image at `quay.io/external_storage/nfs-client-provisioner-arm`. (https://github.com/kubernetes-incubator/external-storage/pull/275)

# v2.0.0
- Fix issue 149 - nfs-client-provisioner create folder with 755, not 777 (https://github.com/kubernetes-incubator/external-storage/pull/150)

# v1
- Initial release