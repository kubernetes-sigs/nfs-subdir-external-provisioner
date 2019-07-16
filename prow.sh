#! /bin/bash
#
# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# This script runs inside a Prow job. It can run unit tests ("make test")
# and E2E testing. This E2E testing covers different scenarios (see
# https://github.com/kubernetes/enhancements/pull/807):
# - running the stable hostpath example against a Kubernetes release
# - running the canary hostpath example against a Kubernetes release
# - building the component in the current repo and running the
#   stable hostpath example with that one component replaced against
#   a Kubernetes release
#
# The intended usage of this script is that individual repos import
# csi-release-tools, then link their top-level prow.sh to this or
# include it in that file. When including it, several of the variables
# can be overridden in the top-level prow.sh to customize the script
# for the repo.
#
# The expected environment is:
# - $GOPATH/src/<import path> for the repository that is to be tested,
#   with PR branch merged (when testing a PR)
# - running on linux-amd64
# - bazel installed (when testing against Kubernetes master), must be recent
#   enough for Kubernetes master
# - kind (https://github.com/kubernetes-sigs/kind) installed
# - optional: Go already installed

RELEASE_TOOLS_ROOT="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
REPO_DIR="$(pwd)"

# Sets the default value for a variable if not set already and logs the value.
# Any variable set this way is usually something that a repo's .prow.sh
# or the job can set.
configvar () {
    # Ignore: Word is of the form "A"B"C" (B indicated). Did you mean "ABC" or "A\"B\"C"?
    # shellcheck disable=SC2140
    eval : \$\{"$1":="\$2"\}
    eval echo "\$3:" "$1=\${$1}"
}

# Takes the minor version of $CSI_PROW_KUBERNETES_VERSION and overrides it to
# $1 if they are equal minor versions. Ignores versions that begin with
# "release-".
override_k8s_version () {
    local current_minor_version
    local override_minor_version

    # Ignore: See if you can use ${variable//search/replace} instead.
    # shellcheck disable=SC2001
    current_minor_version="$(echo "${CSI_PROW_KUBERNETES_VERSION}" | sed -e 's/\([0-9]*\)\.\([0-9]*\).*/\1\.\2/')"

    # Ignore: See if you can use ${variable//search/replace} instead.
    # shellcheck disable=SC2001
    override_minor_version="$(echo "${1}" | sed -e 's/\([0-9]*\)\.\([0-9]*\).*/\1\.\2/')"
    if [ "${current_minor_version}" == "${override_minor_version}" ]; then
      CSI_PROW_KUBERNETES_VERSION="$1"
      echo "Overriding CSI_PROW_KUBERNETES_VERSION with $1: $CSI_PROW_KUBERNETES_VERSION"
    fi
}

# Prints the value of a variable + version suffix, falling back to variable + "LATEST".
get_versioned_variable () {
    local var="$1"
    local version="$2"
    local value

    eval value="\${${var}_${version}}"
    if ! [ "$value" ]; then
        eval value="\${${var}_LATEST}"
    fi
    echo "$value"
}

# Go versions can be specified seperately for different tasks
# If the pre-installed Go is missing or a different
# version, the required version here will get installed
# from https://golang.org/dl/.
go_from_travis_yml () {
    grep "^ *- go:" "${RELEASE_TOOLS_ROOT}/travis.yml" | sed -e 's/.*go: *//'
}
configvar CSI_PROW_GO_VERSION_BUILD "$(go_from_travis_yml)" "Go version for building the component" # depends on component's source code
configvar CSI_PROW_GO_VERSION_E2E "" "override Go version for building the Kubernetes E2E test suite" # normally doesn't need to be set, see install_e2e
configvar CSI_PROW_GO_VERSION_SANITY "${CSI_PROW_GO_VERSION_BUILD}" "Go version for building the csi-sanity test suite" # depends on CSI_PROW_SANITY settings below
configvar CSI_PROW_GO_VERSION_KIND "${CSI_PROW_GO_VERSION_BUILD}" "Go version for building 'kind'" # depends on CSI_PROW_KIND_VERSION below
configvar CSI_PROW_GO_VERSION_GINKGO "${CSI_PROW_GO_VERSION_BUILD}" "Go version for building ginkgo" # depends on CSI_PROW_GINKGO_VERSION below

# kind version to use. If the pre-installed version is different,
# the desired version is downloaded from https://github.com/kubernetes-sigs/kind/releases/download/
# (if available), otherwise it is built from source.
configvar CSI_PROW_KIND_VERSION v0.4.0 "kind"

# ginkgo test runner version to use. If the pre-installed version is
# different, the desired version is built from source.
configvar CSI_PROW_GINKGO_VERSION v1.7.0 "Ginkgo"

# Ginkgo runs the E2E test in parallel. The default is based on the number
# of CPUs, but typically this can be set to something higher in the job.
configvar CSI_PROW_GINKO_PARALLEL "-p" "Ginko parallelism parameter(s)"

# Enables building the code in the repository. On by default, can be
# disabled in jobs which only use pre-built components.
configvar CSI_PROW_BUILD_JOB true "building code in repo enabled"

# Kubernetes version to test against. This must be a version number
# (like 1.13.3) for which there is a pre-built kind image (see
# https://hub.docker.com/r/kindest/node/tags), "latest" (builds
# Kubernetes from the master branch) or "release-x.yy" (builds
# Kubernetes from a release branch).
#
# This can also be a version that was not released yet at the time
# that the settings below were chose. The script will then
# use the same settings as for "latest" Kubernetes. This works
# as long as there are no breaking changes in Kubernetes, like
# deprecating or changing the implementation of an alpha feature.
configvar CSI_PROW_KUBERNETES_VERSION 1.13.3 "Kubernetes"

# This is a hack to workaround the issue that each version
# of kind currently only supports specific patch versions of
# Kubernetes. We need to override CSI_PROW_KUBERNETES_VERSION
# passed in by our CI/pull jobs to the versions that
# kind v0.4.0 supports.
#
# If the version is prefixed with "release-", then nothing
# is overridden.
override_k8s_version "1.13.7"
override_k8s_version "1.14.3"
override_k8s_version "1.15.0"

# CSI_PROW_KUBERNETES_VERSION reduced to first two version numbers and
# with underscore (1_13 instead of 1.13.3) and in uppercase (LATEST
# instead of latest).
#
# This is used to derive the right defaults for the variables below
# when a Prow job just defines the Kubernetes version.
csi_prow_kubernetes_version_suffix="$(echo "${CSI_PROW_KUBERNETES_VERSION}" | tr . _ | tr '[:lower:]' '[:upper:]' | sed -e 's/^RELEASE-//' -e 's/\([0-9]*\)_\([0-9]*\).*/\1_\2/')"

# Work directory. It has to allow running executables, therefore /tmp
# is avoided. Cleaning up after the script is intentionally left to
# the caller.
configvar CSI_PROW_WORK "$(mkdir -p "$GOPATH/pkg" && mktemp -d "$GOPATH/pkg/csiprow.XXXXXXXXXX")" "work directory"

# The hostpath deployment script is searched for in several places.
#
# - The "deploy" directory in the current repository: this is useful
#   for the situation that a component becomes incompatible with the
#   shared deployment, because then it can (temporarily!) provide its
#   own example until the shared one can be updated; it's also how
#   csi-driver-host-path itself provides the example.
#
# - CSI_PROW_HOSTPATH_VERSION of the CSI_PROW_HOSTPATH_REPO is checked
#   out: this allows other repos to reference a version of the example
#   that is known to be compatible.
#
# - The csi-driver-host-path/deploy directory has multiple sub-directories,
#   each with different deployments (stable set of images for Kubernetes 1.13,
#   stable set of images for Kubernetes 1.14, canary for latest Kubernetes, etc.).
#   This is necessary because there may be incompatible changes in the
#   "API" of a component (for example, its command line options or RBAC rules)
#   or in its support for different Kubernetes versions (CSIDriverInfo as
#   CRD in Kubernetes 1.13 vs builtin API in Kubernetes 1.14).
#
#   When testing an update for a component in a PR job, the
#   CSI_PROW_DEPLOYMENT variable can be set in the
#   .prow.sh of each component when there are breaking changes
#   that require using a non-default deployment. The default
#   is a deployment named "kubernetes-x.yy" (if available),
#   otherwise "kubernetes-latest".
#   "none" disables the deployment of the hostpath driver.
#
# When no deploy script is found (nothing in `deploy` directory,
# CSI_PROW_HOSTPATH_REPO=none), nothing gets deployed.
configvar CSI_PROW_HOSTPATH_VERSION "v1.2.0-rc2" "hostpath driver"
configvar CSI_PROW_HOSTPATH_REPO https://github.com/kubernetes-csi/csi-driver-host-path "hostpath repo"
configvar CSI_PROW_DEPLOYMENT "" "deployment"
configvar CSI_PROW_HOSTPATH_DRIVER_NAME "hostpath.csi.k8s.io" "the hostpath driver name"

# If CSI_PROW_HOSTPATH_CANARY is set (typically to "canary", but also
# "1.0-canary"), then all image versions are replaced with that
# version tag.
configvar CSI_PROW_HOSTPATH_CANARY "" "hostpath image"

# The E2E testing can come from an arbitrary repo. The expectation is that
# the repo supports "go test ./test/e2e -args --storage.testdriver" (https://github.com/kubernetes/kubernetes/pull/72836)
# after setting KUBECONFIG. As a special case, if the repository is Kubernetes,
# then `make WHAT=test/e2e/e2e.test` is called first to ensure that
# all generated files are present.
#
# CSI_PROW_E2E_REPO=none disables E2E testing.
configvar CSI_PROW_E2E_VERSION_1_13 v1.14.0 "E2E version for Kubernetes 1.13.x" # we can't use the one from 1.13.x because it didn't have --storage.testdriver
configvar CSI_PROW_E2E_VERSION_1_14 v1.14.0 "E2E version for Kubernetes 1.14.x"
configvar CSI_PROW_E2E_VERSION_1_15 v1.15.0 "E2E version for Kubernetes 1.15.x"
# TODO: add new CSI_PROW_E2E_VERSION entry for future Kubernetes releases
configvar CSI_PROW_E2E_VERSION_LATEST master "E2E version for Kubernetes master" # testing against Kubernetes master is already tracking a moving target, so we might as well use a moving E2E version
configvar CSI_PROW_E2E_REPO_LATEST https://github.com/kubernetes/kubernetes "E2E repo for Kubernetes >= 1.13.x" # currently the same for all versions
configvar CSI_PROW_E2E_IMPORT_PATH_LATEST k8s.io/kubernetes "E2E package for Kubernetes >= 1.13.x" # currently the same for all versions
configvar CSI_PROW_E2E_VERSION "$(get_versioned_variable CSI_PROW_E2E_VERSION "${csi_prow_kubernetes_version_suffix}")"  "E2E version"
configvar CSI_PROW_E2E_REPO "$(get_versioned_variable CSI_PROW_E2E_REPO "${csi_prow_kubernetes_version_suffix}")" "E2E repo"
configvar CSI_PROW_E2E_IMPORT_PATH "$(get_versioned_variable CSI_PROW_E2E_IMPORT_PATH "${csi_prow_kubernetes_version_suffix}")" "E2E package"

# csi-sanity testing from the csi-test repo can be run against the installed
# CSI driver. For this to work, deploying the driver must expose the Unix domain
# csi.sock as a TCP service for use by the csi-sanity command, which runs outside
# of the cluster. The alternative would have been to (cross-)compile csi-sanity
# and install it inside the cluster, which is not necessarily easier.
configvar CSI_PROW_SANITY_REPO https://github.com/kubernetes-csi/csi-test "csi-test repo"
configvar CSI_PROW_SANITY_VERSION 5421d9f3c37be3b95b241b44a094a3db11bee789 "csi-test version" # latest master
configvar CSI_PROW_SANITY_IMPORT_PATH github.com/kubernetes-csi/csi-test "csi-test package"
configvar CSI_PROW_SANITY_SERVICE "hostpath-service" "Kubernetes TCP service name that exposes csi.sock"
configvar CSI_PROW_SANITY_POD "csi-hostpathplugin-0" "Kubernetes pod with CSI driver"
configvar CSI_PROW_SANITY_CONTAINER "hostpath" "Kubernetes container with CSI driver"

# Each job can run one or more of the following tests, identified by
# a single word:
# - unit testing
# - parallel excluding alpha features
# - serial excluding alpha features
# - parallel, only alpha feature
# - serial, only alpha features
# - sanity
#
# Unknown or unsupported entries are ignored.
#
# Sanity testing with csi-sanity only covers the CSI driver itself and
# thus only makes sense in repos which provide their own CSI
# driver. Repos can enable sanity testing by setting
# CSI_PROW_TESTS_SANITY=sanity.
configvar CSI_PROW_TESTS "unit parallel serial parallel-alpha serial-alpha sanity" "tests to run"
tests_enabled () {
    local t1 t2
    # We want word-splitting here, so ignore: Quote to prevent word splitting, or split robustly with mapfile or read -a.
    # shellcheck disable=SC2206
    local tests=(${CSI_PROW_TESTS})
    for t1 in "$@"; do
        for t2 in "${tests[@]}"; do
            if [ "$t1" = "$t2" ]; then
                return
            fi
        done
    done
    return 1
}
sanity_enabled () {
    [ "${CSI_PROW_TESTS_SANITY}" = "sanity" ] && tests_enabled "sanity"
}
tests_need_kind () {
    tests_enabled "parallel" "serial" "serial-alpha" "parallel-alpha" ||
        sanity_enabled
}
tests_need_non_alpha_cluster () {
    tests_enabled "parallel" "serial" ||
        sanity_enabled
}
tests_need_alpha_cluster () {
    tests_enabled "parallel-alpha" "serial-alpha"
}


# Serial vs. parallel is always determined by these regular expressions.
# Individual regular expressions are seperated by spaces for readability
# and expected to not contain spaces. Use dots instead. The complete
# regex for Ginkgo will be created by joining the individual terms.
configvar CSI_PROW_E2E_SERIAL '\[Serial\] \[Disruptive\]' "tags for serial E2E tests"
regex_join () {
    echo "$@" | sed -e 's/  */|/g' -e 's/^|*//' -e 's/|*$//' -e 's/^$/this-matches-nothing/g'
}

# Which tests are alpha depends on the Kubernetes version. We could
# use the same E2E test for all Kubernetes version. This would have
# the advantage that new tests can be applied to older versions
# without having to backport tests.
#
# But the feature tag gets removed from E2E tests when the corresponding
# feature becomes beta, so we would have to track which tests were
# alpha in previous Kubernetes releases. This was considered too
# error prone. Therefore we use E2E tests that match the Kubernetes
# version that is getting tested.
#
# However, for 1.13.x testing we have to use the E2E tests from 1.14
# because 1.13 didn't have --storage.testdriver yet, so for that (and only
# that version) we have to define alpha tests differently.
configvar CSI_PROW_E2E_ALPHA_1_13 '\[Feature: \[Testpattern:.Dynamic.PV..block.volmode.\] should.create.and.delete.block.persistent.volumes' "alpha tests for Kubernetes 1.13" # Raw block was an alpha feature in 1.13.
configvar CSI_PROW_E2E_ALPHA_LATEST '\[Feature:' "alpha tests for Kubernetes >= 1.14" # there's no need to update this, adding a new case for CSI_PROW_E2E for a new Kubernetes is enough
configvar CSI_PROW_E2E_ALPHA "$(get_versioned_variable CSI_PROW_E2E_ALPHA "${csi_prow_kubernetes_version_suffix}")" "alpha tests"

# After the parallel E2E test without alpha features, a test cluster
# with alpha features is brought up and tests that were previously
# disabled are run. The alpha gates in each release have to be listed
# explicitly. If none are set (= variable empty), alpha testing
# is skipped.
#
# Testing against "latest" Kubernetes is problematic because some alpha
# feature which used to work might stop working or change their behavior
# such that the current tests no longer pass. If that happens,
# kubernetes-csi components must be updated, either by disabling
# the failing test for "latest" or by updating the test and not running
# it anymore for older releases.
configvar CSI_PROW_E2E_ALPHA_GATES_1_13 'VolumeSnapshotDataSource=true,BlockVolume=true,CSIBlockVolume=true' "alpha feature gates for Kubernetes 1.13"
configvar CSI_PROW_E2E_ALPHA_GATES_1_14 'VolumeSnapshotDataSource=true,ExpandCSIVolumes=true' "alpha feature gates for Kubernetes 1.14"
configvar CSI_PROW_E2E_ALPHA_GATES_1_15 'VolumeSnapshotDataSource=true,ExpandCSIVolumes=true' "alpha feature gates for Kubernetes 1.15"
# TODO: add new CSI_PROW_ALPHA_GATES_xxx entry for future Kubernetes releases and
# add new gates to CSI_PROW_E2E_ALPHA_GATES_LATEST.
configvar CSI_PROW_E2E_ALPHA_GATES_LATEST 'VolumeSnapshotDataSource=true,ExpandCSIVolumes=true' "alpha feature gates for latest Kubernetes"
configvar CSI_PROW_E2E_ALPHA_GATES "$(get_versioned_variable CSI_PROW_E2E_ALPHA_GATES "${csi_prow_kubernetes_version_suffix}")" "alpha E2E feature gates"

# Some tests are known to be unusable in a KinD cluster. For example,
# stopping kubelet with "ssh <node IP> systemctl stop kubelet" simply
# doesn't work. Such tests should be written in a way that they verify
# whether they can run with the current cluster provider, but until
# they are, we filter them out by name. Like the other test selection
# variables, this is again a space separated list of regular expressions.
configvar CSI_PROW_E2E_SKIP 'while.kubelet.is.down.*Disruptive' "tests that need to be skipped"

# This is the directory for additional result files. Usually set by Prow, but
# if not (for example, when invoking manually) it defaults to the work directory.
configvar ARTIFACTS "${CSI_PROW_WORK}/artifacts" "artifacts"
mkdir -p "${ARTIFACTS}"

run () {
    echo "$(date) $(go version | sed -e 's/.*version \(go[^ ]*\).*/\1/') $(if [ "$(pwd)" != "${REPO_DIR}" ]; then pwd; fi)\$" "$@" >&2
    "$@"
}

info () {
    echo >&2 INFO: "$@"
}

warn () {
    echo >&2 WARNING: "$@"
}

die () {
    echo >&2 ERROR: "$@"
    exit 1
}

# For additional tools.
CSI_PROW_BIN="${CSI_PROW_WORK}/bin"
mkdir -p "${CSI_PROW_BIN}"
PATH="${CSI_PROW_BIN}:$PATH"

# Ensure that PATH has the desired version of the Go tools, then run command given as argument.
# Empty parameter uses the already installed Go. In Prow, that version is kept up-to-date by
# bumping the container image regularly.
run_with_go () {
    local version
    version="$1"
    shift

    if ! [ "$version" ] || go version 2>/dev/null | grep -q "go$version"; then
        run "$@"
    else
        if ! [ -d "${CSI_PROW_WORK}/go-$version" ];  then
            run curl --fail --location "https://dl.google.com/go/go$version.linux-amd64.tar.gz" | tar -C "${CSI_PROW_WORK}" -zxf - || die "installation of Go $version failed"
            mv "${CSI_PROW_WORK}/go" "${CSI_PROW_WORK}/go-$version"
        fi
        PATH="${CSI_PROW_WORK}/go-$version/bin:$PATH" run "$@"
    fi
}

# Ensure that we have the desired version of kind.
install_kind () {
    if kind --version 2>/dev/null | grep -q " ${CSI_PROW_KIND_VERSION}$"; then
        return
    fi
    if run curl --fail --location -o "${CSI_PROW_WORK}/bin/kind" "https://github.com/kubernetes-sigs/kind/releases/download/${CSI_PROW_KIND_VERSION}/kind-linux-amd64"; then
        chmod u+x "${CSI_PROW_WORK}/bin/kind"
    else
        git_checkout https://github.com/kubernetes-sigs/kind "$GOPATH/src/sigs.k8s.io/kind" "${CSI_PROW_KIND_VERSION}" --depth=1 &&
        run_with_go "${CSI_PROW_GO_VERSION_KIND}" go build -o "${CSI_PROW_WORK}/bin/kind" sigs.k8s.io/kind
    fi
}

# Ensure that we have the desired version of the ginkgo test runner.
install_ginkgo () {
    # CSI_PROW_GINKGO_VERSION contains the tag with v prefix, the command line output does not.
    if [ "v$(ginkgo version 2>/dev/null | sed -e 's/.* //')" = "${CSI_PROW_GINKGO_VERSION}" ]; then
        return
    fi
    git_checkout https://github.com/onsi/ginkgo "$GOPATH/src/github.com/onsi/ginkgo" "${CSI_PROW_GINKGO_VERSION}" --depth=1 &&
    # We have to get dependencies and hence can't call just "go build".
    run_with_go "${CSI_PROW_GO_VERSION_GINKGO}" go get github.com/onsi/ginkgo/ginkgo || die "building ginkgo failed" &&
    mv "$GOPATH/bin/ginkgo" "${CSI_PROW_BIN}"
}

# This checks out a repo ("https://github.com/kubernetes/kubernetes")
# in a certain location ("$GOPATH/src/k8s.io/kubernetes") at
# a certain revision (a hex commit hash, v1.13.1, master). It's okay
# for that directory to exist already.
git_checkout () {
    local repo path revision
    repo="$1"
    shift
    path="$1"
    shift
    revision="$1"
    shift

    mkdir -p "$path"
    if ! [ -d "$path/.git" ]; then
        run git init "$path"
    fi
    if (cd "$path" && run git fetch "$@" "$repo" "$revision"); then
        (cd "$path" && run git checkout FETCH_HEAD) || die "checking out $repo $revision failed"
    else
        # Might have been because fetching by revision is not
        # supported by GitHub (https://github.com/isaacs/github/issues/436).
        # Fall back to fetching everything.
        (cd "$path" && run git fetch "$repo" '+refs/heads/*:refs/remotes/csiprow/heads/*' '+refs/tags/*:refs/tags/*') || die "fetching $repo failed"
        (cd "$path" && run git checkout "$revision") || die "checking out $repo $revision failed"
    fi
    # This is useful for local testing or when switching between different revisions in the same
    # repo.
    (cd "$path" && run git clean -fdx) || die "failed to clean $path"
}

list_gates () (
    set -f; IFS=','
    # Ignore: Double quote to prevent globbing and word splitting.
    # shellcheck disable=SC2086
    set -- $1
    while [ "$1" ]; do
        # Ignore: See if you can use ${variable//search/replace} instead.
        # shellcheck disable=SC2001
        echo "$1" | sed -e 's/ *\([^ =]*\) *= *\([^ ]*\) */      \1: \2/'
        shift
    done
)

go_version_for_kubernetes () (
    local path="$1"
    local version="$2"
    local go_version

    # We use the minimal Go version specified for each K8S release (= minimum_go_version in hack/lib/golang.sh).
    # More recent versions might also work, but we don't want to count on that.
    go_version="$(grep minimum_go_version= "$path/hack/lib/golang.sh" | sed -e 's/.*=go//')"
    if ! [ "$go_version" ]; then
        die "Unable to determine Go version for Kubernetes $version from hack/lib/golang.sh."
    fi
    echo "$go_version"
)

csi_prow_kind_have_kubernetes=false
# Brings up a Kubernetes cluster and sets KUBECONFIG.
# Accepts additional feature gates in the form gate1=true|false,gate2=...
start_cluster () {
    local image gates
    gates="$1"

    if kind get clusters | grep -q csi-prow; then
        run kind delete cluster --name=csi-prow || die "kind delete failed"
    fi

    # Build from source?
    if [[ "${CSI_PROW_KUBERNETES_VERSION}" =~ ^release-|^latest$ ]]; then
        if ! ${csi_prow_kind_have_kubernetes}; then
            local version="${CSI_PROW_KUBERNETES_VERSION}"
            if [ "$version" = "latest" ]; then
                version=master
            fi
            git_checkout https://github.com/kubernetes/kubernetes "$GOPATH/src/k8s.io/kubernetes" "$version" --depth=1 || die "checking out Kubernetes $version failed"

            # "kind build" and/or the Kubernetes build rules need at least one tag, which we don't have
            # when doing a shallow fetch. Therefore we fake one:
            # release-1.12 -> v1.12.0-release.<rev>.csiprow
            # latest or <revision> -> v1.14.0-<rev>.csiprow
            case "${CSI_PROW_KUBERNETES_VERSION}" in
                release-*)
                    # Ignore: See if you can use ${variable//search/replace} instead.
                    # shellcheck disable=SC2001
                    tag="$(echo "${CSI_PROW_KUBERNETES_VERSION}" | sed -e 's/release-\(.*\)/v\1.0-release./')";;
                *)
                    # We have to make something up. v1.0.0 did not work for some reasons.
                    tag="v999.999.999-";;
            esac
            tag="$tag$(cd "$GOPATH/src/k8s.io/kubernetes" && git rev-list --abbrev-commit HEAD).csiprow"
            (cd "$GOPATH/src/k8s.io/kubernetes" && run git tag -f "$tag") || die "git tag failed"
            go_version="$(go_version_for_kubernetes "$GOPATH/src/k8s.io/kubernetes" "$version")" || die "cannot proceed without knowing Go version for Kubernetes"
            run_with_go "$go_version" kind build node-image --type bazel --image csiprow/node:latest --kube-root "$GOPATH/src/k8s.io/kubernetes" || die "'kind build node-image' failed"
            csi_prow_kind_have_kubernetes=true
        fi
        image="csiprow/node:latest"
    else
        image="kindest/node:v${CSI_PROW_KUBERNETES_VERSION}"
    fi
    cat >"${CSI_PROW_WORK}/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.sigs.k8s.io/v1alpha3
nodes:
- role: control-plane
EOF

    # kubeadm has API dependencies between apiVersion and Kubernetes version
    # 1.15+ requires kubeadm.k8s.io/v1beta2
    # We only run alpha tests against master so we don't need to maintain
    # different patches for different Kubernetes releases.
    if [[ -n "$gates" ]]; then
        cat >>"${CSI_PROW_WORK}/kind-config.yaml" <<EOF
kubeadmConfigPatches:
- |
  apiVersion: kubeadm.k8s.io/v1beta2
  kind: ClusterConfiguration
  metadata:
    name: config
  apiServer:
    extraArgs:
      "feature-gates": "$gates"
  controllerManager:
    extraArgs:
      "feature-gates": "$gates"
  scheduler:
    extraArgs:
      "feature-gates": "$gates"
- |
  apiVersion: kubeadm.k8s.io/v1beta2
  kind: InitConfiguration
  metadata:
    name: config
  nodeRegistration:
    kubeletExtraArgs:
      "feature-gates": "$gates"
- |
  apiVersion: kubeproxy.config.k8s.io/v1alpha1
  kind: KubeProxyConfiguration
  metadata:
    name: config
  featureGates:
$(list_gates "$gates")
EOF
    fi

    info "kind-config.yaml:"
    cat "${CSI_PROW_WORK}/kind-config.yaml"
    if ! run kind create cluster --name csi-prow --config "${CSI_PROW_WORK}/kind-config.yaml" --wait 5m --image "$image"; then
        warn "Cluster creation failed. Will try again with higher verbosity."
        info "Available Docker images:"
        docker image ls
        if ! run kind --loglevel debug create cluster --retain --name csi-prow --config "${CSI_PROW_WORK}/kind-config.yaml" --wait 5m --image "$image"; then
            run kind export logs --name csi-prow "$ARTIFACTS/kind-cluster"
            die "Cluster creation failed again, giving up. See the 'kind-cluster' artifact directory for additional logs."
        fi
    fi
    KUBECONFIG="$(kind get kubeconfig-path --name=csi-prow)"
    export KUBECONFIG
}

# Looks for the deployment as specified by CSI_PROW_DEPLOYMENT and CSI_PROW_KUBERNETES_VERSION
# in the given directory.
find_deployment () {
    local dir file
    dir="$1"

    # Fixed deployment name? Use it if it exists, otherwise fail.
    if [ "${CSI_PROW_DEPLOYMENT}" ]; then
        file="$dir/${CSI_PROW_DEPLOYMENT}/deploy-hostpath.sh"
        if ! [ -e "$file" ]; then
            return 1
        fi
        echo "$file"
        return 0
    fi

    # Ignore: See if you can use ${variable//search/replace} instead.
    # shellcheck disable=SC2001
    file="$dir/kubernetes-$(echo "${CSI_PROW_KUBERNETES_VERSION}" | sed -e 's/\([0-9]*\)\.\([0-9]*\).*/\1.\2/')/deploy-hostpath.sh"
    if ! [ -e "$file" ]; then
        file="$dir/kubernetes-latest/deploy-hostpath.sh"
        if ! [ -e "$file" ]; then
            return 1
        fi
    fi
    echo "$file"
}

# This installs the hostpath driver example. CSI_PROW_HOSTPATH_CANARY overrides all
# image versions with that canary version. The parameters of install_hostpath can be
# used to override registry and/or tag of individual images (CSI_PROVISIONER_REGISTRY=localhost:9000
# CSI_PROVISIONER_TAG=latest).
install_hostpath () {
    local images deploy_hostpath
    images="$*"

    if [ "${CSI_PROW_DEPLOYMENT}" = "none" ]; then
        return 1
    fi

    if ${CSI_PROW_BUILD_JOB}; then
        # Ignore: Double quote to prevent globbing and word splitting.
        # Ignore: To read lines rather than words, pipe/redirect to a 'while read' loop.
        # shellcheck disable=SC2086 disable=SC2013
        for i in $(grep '^\s*CMDS\s*=' Makefile | sed -e 's/\s*CMDS\s*=//'); do
            kind load docker-image --name csi-prow $i:csiprow || die "could not load the $i:latest image into the kind cluster"
        done
    fi

    if deploy_hostpath="$(find_deployment "$(pwd)/deploy")"; then
        :
    elif [ "${CSI_PROW_HOSTPATH_REPO}" = "none" ]; then
        return 1
    else
        git_checkout "${CSI_PROW_HOSTPATH_REPO}" "${CSI_PROW_WORK}/hostpath" "${CSI_PROW_HOSTPATH_VERSION}" --depth=1 || die "checking out hostpath repo failed"
        if deploy_hostpath="$(find_deployment "${CSI_PROW_WORK}/hostpath/deploy")"; then
            :
        else
            die "deploy-hostpath.sh not found in ${CSI_PROW_HOSTPATH_REPO} ${CSI_PROW_HOSTPATH_VERSION}. To disable E2E testing, set CSI_PROW_HOSTPATH_REPO=none"
        fi
    fi

    if [ "${CSI_PROW_HOSTPATH_CANARY}" != "stable" ]; then
        images="$images IMAGE_TAG=${CSI_PROW_HOSTPATH_CANARY}"
    fi
    # Ignore: Double quote to prevent globbing and word splitting.
    # It's intentional here for $images.
    # shellcheck disable=SC2086
    if ! run env $images "${deploy_hostpath}"; then
        # Collect information about failed deployment before failing.
        collect_cluster_info
        (start_loggers >/dev/null; wait)
        info "For container output see job artifacts."
        die "deploying the hostpath driver with ${deploy_hostpath} failed"
    fi
}

# collect logs and cluster status (like the version of all components, Kubernetes version, test version)
collect_cluster_info () {
    cat <<EOF
=========================================================
Kubernetes:
$(kubectl version)

Driver installation in default namespace:
$(kubectl get all)

Images in cluster:
REPOSITORY TAG REVISION
$(
# Here we iterate over all images that are in use and print some information about them.
# The "revision" label is where our build process puts the version number and revision,
# which is always unique, in contrast to the tag (think "canary"...).
docker exec csi-prow-control-plane docker image ls --format='{{.Repository}} {{.Tag}} {{.ID}}' | grep -e csi -e hostpath | while read -r repo tag id; do
    echo "$repo" "$tag" "$(docker exec csi-prow-control-plane docker image inspect --format='{{ index .Config.Labels "revision"}}' "$id")"
done
)

=========================================================
EOF

}

# Gets logs of all containers in the default namespace. When passed -f, kubectl will
# keep running and capture new output. Prints the pid of all background processes.
# The caller must kill (when using -f) and/or wait for them.
#
# May be called multiple times and thus appends.
start_loggers () {
    kubectl get pods -o go-template --template='{{range .items}}{{.metadata.name}} {{range .spec.containers}}{{.name}} {{end}}{{"\n"}}{{end}}' | while read -r pod containers; do
        for container in $containers; do
            mkdir -p "${ARTIFACTS}/$pod"
            kubectl logs "$@" "$pod" "$container" >>"${ARTIFACTS}/$pod/$container.log" &
            echo "$!"
        done
    done
}

# Makes the E2E test suite binary available as "${CSI_PROW_WORK}/e2e.test".
install_e2e () {
    if [ -e "${CSI_PROW_WORK}/e2e.test" ]; then
        return
    fi

    git_checkout "${CSI_PROW_E2E_REPO}" "${GOPATH}/src/${CSI_PROW_E2E_IMPORT_PATH}" "${CSI_PROW_E2E_VERSION}" --depth=1 &&
    if [ "${CSI_PROW_E2E_IMPORT_PATH}" = "k8s.io/kubernetes" ]; then
        go_version="${CSI_PROW_GO_VERSION_E2E:-$(go_version_for_kubernetes "${GOPATH}/src/${CSI_PROW_E2E_IMPORT_PATH}" "${CSI_PROW_E2E_VERSION}")}" &&
        run_with_go "$go_version" make WHAT=test/e2e/e2e.test "-C${GOPATH}/src/${CSI_PROW_E2E_IMPORT_PATH}" &&
        ln -s "${GOPATH}/src/${CSI_PROW_E2E_IMPORT_PATH}/_output/bin/e2e.test" "${CSI_PROW_WORK}"
    else
        run_with_go "${CSI_PROW_GO_VERSION_E2E}" go test -c -o "${CSI_PROW_WORK}/e2e.test" "${CSI_PROW_E2E_IMPORT_PATH}/test/e2e"
    fi
}

# Makes the csi-sanity test suite binary available as
# "${CSI_PROW_WORK}/csi-sanity".
install_sanity () (
    if [ -e "${CSI_PROW_WORK}/csi-sanity" ]; then
        return
    fi

    git_checkout "${CSI_PROW_SANITY_REPO}" "${GOPATH}/src/${CSI_PROW_SANITY_IMPORT_PATH}" "${CSI_PROW_SANITY_VERSION}" --depth=1 || die "checking out csi-sanity failed"
    run_with_go "${CSI_PROW_GO_VERSION_SANITY}" go test -c -o "${CSI_PROW_WORK}/csi-sanity" "${CSI_PROW_SANITY_IMPORT_PATH}/cmd/csi-sanity" || die "building csi-sanity failed"
)

# Whether the hostpath driver supports raw block devices depends on which version
# we are testing. It would be much nicer if we could determine that by querying the
# installed driver's capabilities instead of having to do a version check.
hostpath_supports_block () {
    local result
    result="$(docker exec csi-prow-control-plane docker image ls --format='{{.Repository}} {{.Tag}} {{.ID}}' | grep hostpath | while read -r repo tag id; do
        if [ "$tag" == "v1.0.1" ]; then
            # Old version because the revision label is missing: didn't have support yet.
            echo "false"
            return
        fi
    done)"
    # If not set, then it must be a newer driver with support.
    echo "${result:-true}"
}

# The default implementation of this function generates a external
# driver test configuration for the hostpath driver.
#
# The content depends on both what the E2E suite expects and what the
# installed hostpath driver supports. Generating it here seems prone
# to breakage, but it is uncertain where a better place might be.
generate_test_driver () {
    cat <<EOF
ShortName: csiprow
StorageClass:
  FromName: true
SnapshotClass:
  FromName: true
DriverInfo:
  Name: ${CSI_PROW_HOSTPATH_DRIVER_NAME}
  Capabilities:
    block: $(hostpath_supports_block)
    persistence: true
    dataSource: true
    multipods: true
EOF
}

# Captures pod output while running some other command.
run_with_loggers () (
    loggers=$(start_loggers -f)
    trap 'kill $loggers' EXIT

    run "$@"
)

# Invokes the filter-junit.go tool.
run_filter_junit () {
    run_with_go "${CSI_PROW_GO_VERSION_BUILD}" go run "${RELEASE_TOOLS_ROOT}/filter-junit.go" "$@"
}

# Runs the E2E test suite in a sub-shell.
run_e2e () (
    name="$1"
    shift

    install_e2e || die "building e2e.test failed"
    install_ginkgo || die "installing ginkgo failed"

    # TODO (?): multi-node cluster (depends on https://github.com/kubernetes-csi/csi-driver-host-path/pull/14).
    # When running on a multi-node cluster, we need to figure out where the
    # hostpath driver was deployed and set ClientNodeName accordingly.

    generate_test_driver >"${CSI_PROW_WORK}/test-driver.yaml" || die "generating test-driver.yaml failed"

    # Rename, merge and filter JUnit files. Necessary in case that we run the E2E suite again
    # and to avoid the large number of "skipped" tests that we get from using
    # the full Kubernetes E2E testsuite while only running a few tests.
    move_junit () {
        if ls "${ARTIFACTS}"/junit_[0-9]*.xml 2>/dev/null >/dev/null; then
            run_filter_junit -t="External Storage" -o "${ARTIFACTS}/junit_${name}.xml" "${ARTIFACTS}"/junit_[0-9]*.xml && rm -f "${ARTIFACTS}"/junit_[0-9]*.xml
        fi
    }
    trap move_junit EXIT

    cd "${GOPATH}/src/${CSI_PROW_E2E_IMPORT_PATH}" &&
    run_with_loggers ginkgo -v "$@" "${CSI_PROW_WORK}/e2e.test" -- -report-dir "${ARTIFACTS}" -storage.testdriver="${CSI_PROW_WORK}/test-driver.yaml"
)

# Run csi-sanity against installed CSI driver.
run_sanity () (
    install_sanity || die "installing csi-sanity failed"

    cat >"${CSI_PROW_WORK}/mkdir_in_pod.sh" <<EOF
#!/bin/sh
kubectl exec "${CSI_PROW_SANITY_POD}" -c "${CSI_PROW_SANITY_CONTAINER}" -- mkdir "\$@" && echo "\$@"
EOF
    # Using "rm -rf" as fallback for "rmdir" is a workaround for:
    # Node Service 
    #     should work
    # /nvme/gopath.tmp/src/github.com/kubernetes-csi/csi-test/pkg/sanity/node.go:624
    # STEP: reusing connection to CSI driver at dns:///172.17.0.2:30896
    # STEP: creating mount and staging directories
    # STEP: creating a single node writer volume
    # STEP: getting a node id
    # STEP: node staging volume
    # STEP: publishing the volume on a node
    # STEP: cleaning up calling nodeunpublish
    # STEP: cleaning up calling nodeunstage
    # STEP: cleaning up deleting the volume
    # cleanup: deleting sanity-node-full-35A55673-604D59E1 = 5211b280-4fad-11e9-8127-0242dfe2bdaf
    # cleanup: warning: NodeUnpublishVolume: rpc error: code = NotFound desc = volume id 5211b280-4fad-11e9-8127-0242dfe2bdaf does not exit in the volumes list
    # rmdir: '/tmp/mount': Directory not empty
    # command terminated with exit code 1
    #
    # Somehow the mount directory was not empty. All tests after that
    # failed in "mkdir".  This only occurred once, so its uncertain
    # why it happened.
    cat >"${CSI_PROW_WORK}/rmdir_in_pod.sh" <<EOF
#!/bin/sh
if ! kubectl exec "${CSI_PROW_SANITY_POD}" -c "${CSI_PROW_SANITY_CONTAINER}" -- rmdir "\$@"; then
    kubectl exec "${CSI_PROW_SANITY_POD}" -c "${CSI_PROW_SANITY_CONTAINER}" -- rm -rf "\$@"
    exit 1
fi
EOF
    chmod u+x "${CSI_PROW_WORK}"/*dir_in_pod.sh

    # This cannot run in parallel, because -csi.junitfile output
    # from different Ginkgo nodes would go to the same file. Also the
    # staging and target directories are the same.
    run_with_loggers "${CSI_PROW_WORK}/csi-sanity" \
                     -ginkgo.v \
                     -csi.junitfile "${ARTIFACTS}/junit_sanity.xml" \
                     -csi.endpoint "dns:///$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' csi-prow-control-plane):$(kubectl get "services/${CSI_PROW_SANITY_SERVICE}" -o "jsonpath={..nodePort}")" \
                     -csi.stagingdir "/tmp/staging" \
                     -csi.mountdir "/tmp/mount" \
                     -csi.createstagingpathcmd "${CSI_PROW_WORK}/mkdir_in_pod.sh" \
                     -csi.createmountpathcmd "${CSI_PROW_WORK}/mkdir_in_pod.sh" \
                     -csi.removestagingpathcmd "${CSI_PROW_WORK}/rmdir_in_pod.sh" \
                     -csi.removemountpathcmd "${CSI_PROW_WORK}/rmdir_in_pod.sh" \
)

ascii_to_xml () {
    # We must escape special characters and remove escape sequences
    # (no good representation in the simple XML that we generate
    # here). filter_junit.go would choke on them during decoding, even
    # when disabling strict parsing.
    sed -e 's/&/&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/\x1B...//g'
}

# The "make test" output starts each test with "### <test-target>:"
# and then ends when the next test starts or with "make: ***
# [<test-target>] Error 1" when there was a failure. Here we read each
# line of that output, split it up into individual tests and generate
# a make-test.xml file in JUnit format.
make_test_to_junit () {
    local ret out testname testoutput
    ret=0
    # Plain make-test.xml was not delivered as text/xml by the web
    # server and ignored by spyglass. It seems that the name has to
    # match junit*.xml.
    out="${ARTIFACTS}/junit_make_test.xml"
    testname=
    echo "<testsuite>" >>"$out"

    while IFS= read -r line; do
        echo "$line" # pass through
        if echo "$line" | grep -q "^### [^ ]*:$"; then
            if [ "$testname" ]; then
                # previous test succesful
                echo "    </system-out>" >>"$out"
                echo "  </testcase>" >>"$out"
            fi
            # Ignore: See if you can use ${variable//search/replace} instead.
            # shellcheck disable=SC2001
            #
            # start new test
            testname="$(echo "$line" | sed -e 's/^### \([^ ]*\):$/\1/')"
            testoutput=
            echo "  <testcase name=\"$testname\">" >>"$out"
            echo "    <system-out>" >>"$out"
        elif echo "$line" | grep -q '^make: .*Error [0-9]*$'; then
            if [ "$testname" ]; then
                # Ignore: Consider using { cmd1; cmd2; } >> file instead of individual redirects.
                # shellcheck disable=SC2129
                #
                # end test with failure
                echo "    </system-out>" >>"$out"
                # Include the same text as in <system-out> also in <failure>,
                # because then it is easier to view in spyglass (shown directly
                # instead of having to click through to stdout).
                echo "    <failure>" >>"$out"
                echo -n "$testoutput" | ascii_to_xml >>"$out"
                echo "    </failure>" >>"$out"
                echo "  </testcase>" >>"$out"
            fi
            # remember failure for exit code
            ret=1
            # not currently inside a test
            testname=
        else
            if [ "$testname" ]; then
                # Test output.
                echo "$line" | ascii_to_xml >>"$out"
                testoutput="$testoutput$line
"
            fi
        fi
    done
    # if still in a test, close it now
    if [ "$testname" ]; then
        echo "    </system-out>" >>"$out"
        echo "  </testcase>" >>"$out"
    fi
    echo "</testsuite>" >>"$out"

    # this makes the error more visible in spyglass
    if [ "$ret" -ne 0 ]; then
        echo "ERROR: 'make test' failed"
        return 1
    fi
}

main () {
    local images ret
    ret=0

    images=
    if ${CSI_PROW_BUILD_JOB}; then
        # A successful build is required for testing.
        run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make all || die "'make all' failed"
        # We don't want test failures to prevent E2E testing below, because the failure
        # might have been minor or unavoidable, for example when experimenting with
        # changes in "release-tools" in a PR (that fails the "is release-tools unmodified"
        # test).
        if tests_enabled "unit"; then
            if ! run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make -k test 2>&1 | make_test_to_junit; then
                warn "'make test' failed, proceeding anyway"
                ret=1
            fi
        fi
        # Required for E2E testing.
        run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make container || die "'make container' failed"
    fi

    if tests_need_kind; then
        install_kind || die "installing kind failed"

        if ${CSI_PROW_BUILD_JOB}; then
            cmds="$(grep '^\s*CMDS\s*=' Makefile | sed -e 's/\s*CMDS\s*=//')"
            # Get the image that was just built (if any) from the
            # top-level Makefile CMDS variable and set the
            # deploy-hostpath.sh env variables for it. We also need to
            # side-load those images into the cluster.
            for i in $cmds; do
                e=$(echo "$i" | tr '[:lower:]' '[:upper:]' | tr - _)
                images="$images ${e}_REGISTRY=none ${e}_TAG=csiprow"

                # We must avoid the tag "latest" because that implies
                # always pulling the image
                # (https://github.com/kubernetes-sigs/kind/issues/328).
                docker tag "$i:latest" "$i:csiprow" || die "tagging the locally built container image for $i failed"
            done

            if [ -e deploy/kubernetes/rbac.yaml ]; then
                # This is one of those components which has its own RBAC rules (like external-provisioner).
                # We are testing a locally built image and also want to test with the the current,
                # potentially modified RBAC rules.
                if [ "$(echo "$cmds" | wc -w)" != 1 ]; then
                    die "ambiguous deploy/kubernetes/rbac.yaml: need exactly one command, got: $cmds"
                fi
                e=$(echo "$cmds" | tr '[:lower:]' '[:upper:]' | tr - _)
                images="$images ${e}_RBAC=$(pwd)/deploy/kubernetes/rbac.yaml"
            fi
        fi

        if tests_need_non_alpha_cluster; then
            start_cluster || die "starting the non-alpha cluster failed"

            # Installing the driver might be disabled.
            if install_hostpath "$images"; then
                collect_cluster_info

                if sanity_enabled; then
                    if ! run_sanity; then
                        ret=1
                    fi
                fi

                if tests_enabled "parallel"; then
                    # Ignore: Double quote to prevent globbing and word splitting.
                    # shellcheck disable=SC2086
                    if ! run_e2e parallel ${CSI_PROW_GINKO_PARALLEL} \
                         -focus="External.Storage" \
                         -skip="$(regex_join "${CSI_PROW_E2E_SERIAL}" "${CSI_PROW_E2E_ALPHA}" "${CSI_PROW_E2E_SKIP}")"; then
                        warn "E2E parallel failed"
                        ret=1
                    fi
                fi

                if tests_enabled "serial"; then
                    if ! run_e2e serial \
                         -focus="External.Storage.*($(regex_join "${CSI_PROW_E2E_SERIAL}"))" \
                         -skip="$(regex_join "${CSI_PROW_E2E_ALPHA}" "${CSI_PROW_E2E_SKIP}")"; then
                        warn "E2E serial failed"
                        ret=1
                    fi
                fi
            fi
        fi

        if tests_need_alpha_cluster && [ "${CSI_PROW_E2E_ALPHA_GATES}" ]; then
            # Need to (re)create the cluster.
            start_cluster "${CSI_PROW_E2E_ALPHA_GATES}" || die "starting alpha cluster failed"

            # Installing the driver might be disabled.
            if install_hostpath "$images"; then
                collect_cluster_info

                if tests_enabled "parallel-alpha"; then
                    # Ignore: Double quote to prevent globbing and word splitting.
                    # shellcheck disable=SC2086
                    if ! run_e2e parallel-alpha ${CSI_PROW_GINKO_PARALLEL} \
                         -focus="External.Storage.*($(regex_join "${CSI_PROW_E2E_ALPHA}"))" \
                         -skip="$(regex_join "${CSI_PROW_E2E_SERIAL}" "${CSI_PROW_E2E_SKIP}")"; then
                        warn "E2E parallel alpha failed"
                        ret=1
                    fi
                fi

                if tests_enabled "serial-alpha"; then
                    if ! run_e2e serial-alpha \
                         -focus="External.Storage.*(($(regex_join "${CSI_PROW_E2E_SERIAL}")).*($(regex_join "${CSI_PROW_E2E_ALPHA}"))|($(regex_join "${CSI_PROW_E2E_ALPHA}")).*($(regex_join "${CSI_PROW_E2E_SERIAL}")))" \
                         -skip="$(regex_join "${CSI_PROW_E2E_SKIP}")"; then
                        warn "E2E serial alpha failed"
                        ret=1
                    fi
                fi
            fi
        fi
    fi

    # Merge all junit files into one. This gets rid of duplicated "skipped" tests.
    if ls "${ARTIFACTS}"/junit_*.xml 2>/dev/null >&2; then
        run_filter_junit -o "${CSI_PROW_WORK}/junit_final.xml" "${ARTIFACTS}"/junit_*.xml && rm "${ARTIFACTS}"/junit_*.xml && mv "${CSI_PROW_WORK}/junit_final.xml" "${ARTIFACTS}"
    fi

    return "$ret"
}
