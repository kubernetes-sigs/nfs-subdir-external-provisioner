# v4.0.3

## Breaking Changes

- **Go version**: Upgraded to Go 1.26.3, Kubernetes client libraries upgraded to v0.36.1
- **Leader election**: Added RBAC permissions for `coordination.k8s.io` leases to support the updated leader election mechanism in newer Kubernetes versions

## New Features

### Configurable Directory Mode, UID, and GID (PR #373)

Per-PVC annotations and provider-wide defaults for controlling directory ownership and permissions:

- **New PVC annotations**:
  - `k8s-sigs.io/nfs-directory-mode` — octal file mode (e.g. `0755`)
  - `k8s-sigs.io/nfs-directory-uid` — numeric UID for directory ownership
  - `k8s-sigs.io/nfs-directory-gid` — numeric GID for directory ownership

- **New environment variables** (defaults when annotations are absent):
  - `NFS_DEFAULT_MODE` — default `0777`
  - `NFS_DEFAULT_UID` — default `0` (root)
  - `NFS_DEFAULT_GID` — default `0` (root)

- **Precedence**: PVC annotations > environment variables > `root:root 0777`

### Version Information Display

- Added version package (`version/version.go`) with build-time version injection via ldflags
- Startup banner displays version, git commit, build date, Go version, compiler, and platform info

### Helm Chart Namespace Support (PR #368)

- Added `.Release.Namespace` to all Helm chart template resources for explicit namespace scoping

## Improvements

- **Build system overhaul**: Multi-stage Docker build with distroless base image, multi-arch support (linux/amd64, linux/arm64) via `make docker-buildx`, enhanced Makefile with help target
- **Legacy cleanup**: Removed legacy architecture-specific Dockerfiles (`docker/arm/`, `docker/x86_64/`, `Dockerfile.multiarch`), consolidated into `build/Dockerfile`
- **Code quality**: Replaced `v1` import alias with `corev1` for clarity, added newline consistency

## Bug Fixes

- Prevent mounting of root directory when `pathPattern` resolves to empty customPath (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/83)
- Add error handling to `os.Chmod` on volume creation (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/176)
- Fix `onDelete` parameter handling for subdirectories (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/221)
- Import `GetPersistentVolumeClass` from `k8s.io/component-helpers` instead of vendored helper (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/189)
- Replace deprecated `::set-output` GitHub Actions commands with environment files (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/289)
- Fix boilerplate header warnings (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/301)

## Security

- Resolve all Trivy vulnerabilities up to 2026-05-15, including CVE-2022-27191 (golang.org/x/crypto), CVE-2023-44487 (HTTP/2), and multiple dependency CVEs (https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/327, https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/287, https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/pull/371)
- Resolve Go standard library vulnerability GO-2026-4971 (net: panic when handling NUL byte on Windows) by upgrading to Go 1.26.3
- Resolve `golang.org/x/net` vulnerabilities GO-2026-4918 (HTTP/2 infinite loop) and GO-2026-4559 (HTTP/2 server panic) by upgrading to v0.53.0

## Dependency Updates

- k8s.io/client-go: v0.23.4 → v0.36.1
- k8s.io/api, k8s.io/apimachinery: → v0.36.1
- k8s.io/component-helpers: → v0.36.1
- sigs.k8s.io/sig-storage-lib-external-provisioner: v6.3.0
- golang.org/x/net: v0.50.0 → v0.53.0
- Various transitive dependencies updated to latest secure versions
