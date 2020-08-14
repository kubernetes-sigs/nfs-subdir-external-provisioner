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

configvar CSI_PROW_BUILD_PLATFORMS "linux amd64; windows amd64 .exe; linux ppc64le -ppc64le; linux s390x -s390x; linux arm64 -arm64" "Go target platforms (= GOOS + GOARCH) and file suffix of the resulting binaries"

# If we have a vendor directory, then use it. We must be careful to only
# use this for "make" invocations inside the project's repo itself because
# setting it globally can break other go usages (like "go get <some command>"
# which is disabled with GOFLAGS=-mod=vendor).
configvar GOFLAGS_VENDOR "$( [ -d vendor ] && echo '-mod=vendor' )" "Go flags for using the vendor directory"

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
configvar CSI_PROW_KIND_VERSION "v0.6.0" "kind"

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
configvar CSI_PROW_KUBERNETES_VERSION 1.17.0 "Kubernetes"

# This is a hack to workaround the issue that each version
# of kind currently only supports specific patch versions of
# Kubernetes. We need to override CSI_PROW_KUBERNETES_VERSION
# passed in by our CI/pull jobs to the versions that
# kind v0.5.0 supports.
#
# If the version is prefixed with "release-", then nothing
# is overridden.
override_k8s_version "1.15.3"

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

# By default, this script tests sidecars with the CSI hostpath driver,
# using the install_csi_driver function. That function depends on
# a deployment script that it searches for in several places:
#
# - The "deploy" directory in the current repository: this is useful
#   for the situation that a component becomes incompatible with the
#   shared deployment, because then it can (temporarily!) provide its
#   own example until the shared one can be updated; it's also how
#   csi-driver-host-path itself provides the example.
#
# - CSI_PROW_DRIVER_VERSION of the CSI_PROW_DRIVER_REPO is checked
#   out: this allows other repos to reference a version of the example
#   that is known to be compatible.
#
# - The <driver repo>/deploy directory can have multiple sub-directories,
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
# CSI_PROW_DRIVER_REPO=none), nothing gets deployed.
#
# If the deployment script is called with CSI_PROW_TEST_DRIVER=<file name> as
# environment variable, then it must write a suitable test driver configuration
# into that file in addition to installing the driver.
configvar CSI_PROW_DRIVER_VERSION "v1.3.0" "CSI driver version"
configvar CSI_PROW_DRIVER_REPO https://github.com/kubernetes-csi/csi-driver-host-path "CSI driver repo"
configvar CSI_PROW_DEPLOYMENT "" "deployment"

# The install_csi_driver function may work also for other CSI drivers,
# as long as they follow the conventions of the CSI hostpath driver.
# If they don't, then a different install function can be provided in
# a .prow.sh file and this config variable can be overridden.
configvar CSI_PROW_DRIVER_INSTALL "install_csi_driver" "name of the shell function which installs the CSI driver"

# If CSI_PROW_DRIVER_CANARY is set (typically to "canary", but also
# version tag. Usually empty. CSI_PROW_HOSTPATH_CANARY is
# accepted as alternative name because some test-infra jobs
# still use that name.
configvar CSI_PROW_DRIVER_CANARY "${CSI_PROW_HOSTPATH_CANARY}" "driver image override for canary images"

# The E2E testing can come from an arbitrary repo. The expectation is that
# the repo supports "go test ./test/e2e -args --storage.testdriver" (https://github.com/kubernetes/kubernetes/pull/72836)
# after setting KUBECONFIG. As a special case, if the repository is Kubernetes,
# then `make WHAT=test/e2e/e2e.test` is called first to ensure that
# all generated files are present.
#
# CSI_PROW_E2E_REPO=none disables E2E testing.
tag_from_version () {
    version="$1"
    shift
    case "$version" in
        latest) echo "master";;
        release-*) echo "$version";;
        *) echo "v$version";;
    esac
}
configvar CSI_PROW_E2E_VERSION "$(tag_from_version "${CSI_PROW_KUBERNETES_VERSION}")"  "E2E version"
configvar CSI_PROW_E2E_REPO "https://github.com/kubernetes/kubernetes" "E2E repo"
configvar CSI_PROW_E2E_IMPORT_PATH "k8s.io/kubernetes" "E2E package"

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

# The version of dep to use for 'make test-vendor'. Ignored if the project doesn't
# use dep. Only binary releases of dep are supported (https://github.com/golang/dep/releases).
configvar CSI_PROW_DEP_VERSION v0.5.1 "golang dep version to be used for vendor checking"

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

# Regex for non-alpha, feature-tagged tests that should be run.
#
# Starting with 1.17, snapshots is beta, but the E2E tests still have the
# [Feature:] tag. They need to be explicitly enabled.
configvar CSI_PROW_E2E_FOCUS_1_15 '^' "non-alpha, feature-tagged tests for Kubernetes = 1.15" # no tests to run, match nothing
configvar CSI_PROW_E2E_FOCUS_1_16 '^' "non-alpha, feature-tagged tests for Kubernetes = 1.16" # no tests to run, match nothing
configvar CSI_PROW_E2E_FOCUS_LATEST '\[Feature:VolumeSnapshotDataSource\]' "non-alpha, feature-tagged tests for Kubernetes >= 1.17"
configvar CSI_PROW_E2E_FOCUS "$(get_versioned_variable CSI_PROW_E2E_FOCUS "${csi_prow_kubernetes_version_suffix}")" "non-alpha, feature-tagged tests"

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
configvar CSI_PROW_E2E_ALPHA_GATES_1_15 'VolumeSnapshotDataSource=true,ExpandCSIVolumes=true' "alpha feature gates for Kubernetes 1.15"
configvar CSI_PROW_E2E_ALPHA_GATES_1_16 'VolumeSnapshotDataSource=true' "alpha feature gates for Kubernetes 1.16"
# TODO: add new CSI_PROW_ALPHA_GATES_xxx entry for future Kubernetes releases and
# add new gates to CSI_PROW_E2E_ALPHA_GATES_LATEST.
configvar CSI_PROW_E2E_ALPHA_GATES_LATEST '' "alpha feature gates for latest Kubernetes"
configvar CSI_PROW_E2E_ALPHA_GATES "$(get_versioned_variable CSI_PROW_E2E_ALPHA_GATES "${csi_prow_kubernetes_version_suffix}")" "alpha E2E feature gates"

# Which external-snapshotter tag to use for the snapshotter CRD and snapshot-controller deployment
configvar CSI_SNAPSHOTTER_VERSION 'v2.0.1' "external-snapshotter version tag"

# Some tests are known to be unusable in a KinD cluster. For example,
# stopping kubelet with "ssh <node IP> systemctl stop kubelet" simply
# doesn't work. Such tests should be written in a way that they verify
# whether they can run with the current cluster provider, but until
# they are, we filter them out by name. Like the other test selection
# variables, this is again a space separated list of regular expressions.
#
# "different node" test skips can be removed once
# https://github.com/kubernetes/kubernetes/pull/82678 has been backported
# to all the K8s versions we test against
configvar CSI_PROW_E2E_SKIP 'Disruptive|different\s+node' "tests that need to be skipped"

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
        git_checkout https://github.com/kubernetes-sigs/kind "${GOPATH}/src/sigs.k8s.io/kind" "${CSI_PROW_KIND_VERSION}" --depth=1 &&
        (cd "${GOPATH}/src/sigs.k8s.io/kind" && make install INSTALL_DIR="${CSI_PROW_WORK}/bin")
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

# Ensure that we have the desired version of dep.
install_dep () {
    if dep version 2>/dev/null | grep -q "version:.*${CSI_PROW_DEP_VERSION}$"; then
        return
    fi
    run curl --fail --location -o "${CSI_PROW_WORK}/bin/dep" "https://github.com/golang/dep/releases/download/v0.5.4/dep-linux-amd64" &&
        chmod u+x "${CSI_PROW_WORK}/bin/dep"
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

# This clones a repo ("https://github.com/kubernetes/kubernetes")
# in a certain location ("$GOPATH/src/k8s.io/kubernetes") at
# a the head of a specific branch (i.e., release-1.13, master).
# The directory cannot exist.
git_clone_branch () {
    local repo path branch parent
    repo="$1"
    shift
    path="$1"
    shift
    branch="$1"
    shift

    parent="$(dirname "$path")"
    mkdir -p "$parent"
    (cd "$parent" && run git clone --single-branch --branch "$branch" "$repo" "$path") || die "cloning $repo" failed
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
    # Strip the trailing .0. Kubernetes includes it, Go itself doesn't.
    # Ignore: See if you can use ${variable//search/replace} instead.
    # shellcheck disable=SC2001
    go_version="$(echo "$go_version" | sed -e 's/\.0$//')"
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
            git_clone_branch https://github.com/kubernetes/kubernetes "${CSI_PROW_WORK}/src/kubernetes" "$version" || die "checking out Kubernetes $version failed"

            go_version="$(go_version_for_kubernetes "${CSI_PROW_WORK}/src/kubernetes" "$version")" || die "cannot proceed without knowing Go version for Kubernetes"
            run_with_go "$go_version" kind build node-image --type bazel --image csiprow/node:latest --kube-root "${CSI_PROW_WORK}/src/kubernetes" || die "'kind build node-image' failed"
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
- role: worker
- role: worker
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
  apiVersion: kubelet.config.k8s.io/v1beta1
  kind: KubeletConfiguration
  metadata:
    name: config
  featureGates:
$(list_gates "$gates")
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
    export KUBECONFIG="${HOME}/.kube/config"
}

# Deletes kind cluster inside a prow job
delete_cluster_inside_prow_job() {
    # Inside a real Prow job it is better to clean up at runtime
    # instead of leaving that to the Prow job cleanup code
    # because the later sometimes times out (https://github.com/kubernetes-csi/csi-release-tools/issues/24#issuecomment-554765872).
    if [ "$JOB_NAME" ]; then
        if kind get clusters | grep -q csi-prow; then
            run kind delete cluster --name=csi-prow || die "kind delete failed"
        fi
        unset KUBECONFIG
    fi
}

# Looks for the deployment as specified by CSI_PROW_DEPLOYMENT and CSI_PROW_KUBERNETES_VERSION
# in the given directory.
find_deployment () {
    local dir file
    dir="$1"

    # Fixed deployment name? Use it if it exists, otherwise fail.
    if [ "${CSI_PROW_DEPLOYMENT}" ]; then
        file="$dir/${CSI_PROW_DEPLOYMENT}/deploy.sh"
        if ! [ -e "$file" ]; then
            return 1
        fi
        echo "$file"
        return 0
    fi

    # Ignore: See if you can use ${variable//search/replace} instead.
    # shellcheck disable=SC2001
    file="$dir/kubernetes-$(echo "${CSI_PROW_KUBERNETES_VERSION}" | sed -e 's/\([0-9]*\)\.\([0-9]*\).*/\1.\2/')/deploy.sh"
    if ! [ -e "$file" ]; then
        file="$dir/kubernetes-latest/deploy.sh"
        if ! [ -e "$file" ]; then
            return 1
        fi
    fi
    echo "$file"
}

# This installs the CSI driver. It's called with a list of env variables
# that override the default images. CSI_PROW_DRIVER_CANARY overrides all
# image versions with that canary version.
install_csi_driver () {
    local images deploy_driver
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

    if deploy_driver="$(find_deployment "$(pwd)/deploy")"; then
        :
    elif [ "${CSI_PROW_DRIVER_REPO}" = "none" ]; then
        return 1
    else
        git_checkout "${CSI_PROW_DRIVER_REPO}" "${CSI_PROW_WORK}/csi-driver" "${CSI_PROW_DRIVER_VERSION}" --depth=1 || die "checking out CSI driver repo failed"
        if deploy_driver="$(find_deployment "${CSI_PROW_WORK}/csi-driver/deploy")"; then
            :
        else
            die "deploy.sh not found in ${CSI_PROW_DRIVER_REPO} ${CSI_PROW_DRIVER_VERSION}. To disable E2E testing, set CSI_PROW_DRIVER_REPO=none"
        fi
    fi

    if [ "${CSI_PROW_DRIVER_CANARY}" != "stable" ]; then
        images="$images IMAGE_TAG=${CSI_PROW_DRIVER_CANARY}"
    fi
    # Ignore: Double quote to prevent globbing and word splitting.
    # It's intentional here for $images.
    # shellcheck disable=SC2086
    if ! run env "CSI_PROW_TEST_DRIVER=${CSI_PROW_WORK}/test-driver.yaml" $images "${deploy_driver}"; then
        # Collect information about failed deployment before failing.
        collect_cluster_info
        (start_loggers >/dev/null; wait)
        info "For container output see job artifacts."
        die "deploying the CSI driver with ${deploy_driver} failed"
    fi
}

# Installs all nessesary snapshotter CRDs  
install_snapshot_crds() {
  # Wait until volumesnapshot CRDs are in place.
  CRD_BASE_DIR="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${CSI_SNAPSHOTTER_VERSION}/config/crd"
  kubectl apply -f "${CRD_BASE_DIR}/snapshot.storage.k8s.io_volumesnapshotclasses.yaml" --validate=false
  kubectl apply -f "${CRD_BASE_DIR}/snapshot.storage.k8s.io_volumesnapshots.yaml" --validate=false
  kubectl apply -f "${CRD_BASE_DIR}/snapshot.storage.k8s.io_volumesnapshotcontents.yaml" --validate=false
  cnt=0
  until kubectl get volumesnapshotclasses.snapshot.storage.k8s.io \
    && kubectl get volumesnapshots.snapshot.storage.k8s.io \
    && kubectl get volumesnapshotcontents.snapshot.storage.k8s.io; do
    if [ $cnt -gt 30 ]; then
        echo >&2 "ERROR: snapshot CRDs not ready after over 1 min"
        exit 1
    fi
    echo "$(date +%H:%M:%S)" "waiting for snapshot CRDs, attempt #$cnt"
	cnt=$((cnt + 1))
    sleep 2
  done
}

# Install snapshot controller and associated RBAC, retrying until the pod is running.
install_snapshot_controller() {
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${CSI_SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
  cnt=0
  until kubectl get clusterrolebinding snapshot-controller-role; do
     if [ $cnt -gt 30 ]; then
        echo "Cluster role bindings:"
        kubectl describe clusterrolebinding
        echo >&2 "ERROR: snapshot controller RBAC not ready after over 5 min"
        exit 1
    fi
    echo "$(date +%H:%M:%S)" "waiting for snapshot RBAC setup complete, attempt #$cnt"
	cnt=$((cnt + 1))
    sleep 10   
  done


  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${CSI_SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
  cnt=0
  expected_running_pods=$(curl https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/"${CSI_SNAPSHOTTER_VERSION}"/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml | grep replicas | cut -d ':' -f 2-)
  while [ "$(kubectl get pods -l app=snapshot-controller | grep 'Running' -c)" -lt "$expected_running_pods" ]; do
    if [ $cnt -gt 30 ]; then
        echo "snapshot-controller pod status:"
        kubectl describe pods -l app=snapshot-controller
        echo >&2 "ERROR: snapshot controller not ready after over 5 min"
        exit 1
    fi
    echo "$(date +%H:%M:%S)" "waiting for snapshot controller deployment to complete, attempt #$cnt"
	cnt=$((cnt + 1))
    sleep 10   
  done
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

# Gets logs of all containers in all namespaces. When passed -f, kubectl will
# keep running and capture new output. Prints the pid of all background processes.
# The caller must kill (when using -f) and/or wait for them.
#
# May be called multiple times and thus appends.
start_loggers () {
    kubectl get pods --all-namespaces -o go-template --template='{{range .items}}{{.metadata.namespace}} {{.metadata.name}} {{range .spec.containers}}{{.name}} {{end}}{{"\n"}}{{end}}' | while read -r namespace pod containers; do
        for container in $containers; do
            mkdir -p "${ARTIFACTS}/$namespace/$pod"
            kubectl logs -n "$namespace" "$@" "$pod" "$container" >>"${ARTIFACTS}/$namespace/$pod/$container.log" &
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

# version_gt returns true if arg1 is greater than arg2.
#
# This function expects versions to be one of the following formats:
#   X.Y.Z, release-X.Y.Z, vX.Y.Z
#
#   where X,Y, and Z are any number.
#
# Partial versions (1.2, release-1.2) work as well.
# The follow substrings are stripped before version comparison:
#   - "v"
#   - "release-"
#   - "kubernetes-"
#
# Usage:
# version_gt release-1.3 v1.2.0  (returns true)
# version_gt v1.1.1 v1.2.0  (returns false)
# version_gt 1.1.1 v1.2.0  (returns false)
# version_gt 1.3.1 v1.2.0  (returns true)
# version_gt 1.1.1 release-1.2.0  (returns false)
# version_gt 1.2.0 1.2.2  (returns false)
function version_gt() { 
    versions=$(for ver in "$@"; do ver=${ver#release-}; ver=${ver#kubernetes-}; echo "${ver#v}"; done)
    greaterVersion=${1#"release-"};
    greaterVersion=${greaterVersion#"kubernetes-"};
    greaterVersion=${greaterVersion#"v"};
    test "$(printf '%s' "$versions" | sort -V | head -n 1)" != "$greaterVersion"
}

main () {
    local images ret
    ret=0

    images=
    if ${CSI_PROW_BUILD_JOB}; then
        # A successful build is required for testing.
        run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make all "GOFLAGS_VENDOR=${GOFLAGS_VENDOR}" "BUILD_PLATFORMS=${CSI_PROW_BUILD_PLATFORMS}" || die "'make all' failed"
        # We don't want test failures to prevent E2E testing below, because the failure
        # might have been minor or unavoidable, for example when experimenting with
        # changes in "release-tools" in a PR (that fails the "is release-tools unmodified"
        # test).
        if tests_enabled "unit"; then
            if [ -f Gopkg.toml ] && ! install_dep; then
                warn "installing 'dep' failed, cannot test vendoring"
                ret=1
            fi
            if ! run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make -k test "GOFLAGS_VENDOR=${GOFLAGS_VENDOR}" 2>&1 | make_test_to_junit; then
                warn "'make test' failed, proceeding anyway"
                ret=1
            fi
        fi
        # Required for E2E testing.
        run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make container "GOFLAGS_VENDOR=${GOFLAGS_VENDOR}" || die "'make container' failed"
    fi

    if tests_need_kind; then
        install_kind || die "installing kind failed"

        if ${CSI_PROW_BUILD_JOB}; then
            cmds="$(grep '^\s*CMDS\s*=' Makefile | sed -e 's/\s*CMDS\s*=//')"
            # Get the image that was just built (if any) from the
            # top-level Makefile CMDS variable and set the
            # deploy.sh env variables for it. We also need to
            # side-load those images into the cluster.
            for i in $cmds; do
                e=$(echo "$i" | tr '[:lower:]' '[:upper:]' | tr - _)
                images="$images ${e}_REGISTRY=none ${e}_TAG=csiprow"

                # We must avoid the tag "latest" because that implies
                # always pulling the image
                # (https://github.com/kubernetes-sigs/kind/issues/328).
                docker tag "$i:latest" "$i:csiprow" || die "tagging the locally built container image for $i failed"

                # For components with multiple cmds, the RBAC file should be in the following format:
                #   rbac-$cmd.yaml
                # If this file cannot be found, we can default to the standard location:
                #   deploy/kubernetes/rbac.yaml
                rbac_file_path=$(find . -type f -name "rbac-$i.yaml")
                if [ "$rbac_file_path" == "" ]; then
                    rbac_file_path="$(pwd)/deploy/kubernetes/rbac.yaml"
                fi
                
                if [ -e "$rbac_file_path" ]; then
                    # This is one of those components which has its own RBAC rules (like external-provisioner).
                    # We are testing a locally built image and also want to test with the the current,
                    # potentially modified RBAC rules.
                    e=$(echo "$i" | tr '[:lower:]' '[:upper:]' | tr - _)
                    images="$images ${e}_RBAC=$rbac_file_path"
                fi
            done
        fi

        if tests_need_non_alpha_cluster; then
            start_cluster || die "starting the non-alpha cluster failed"

            # Install necessary snapshot CRDs and snapshot controller
            # For Kubernetes 1.17+, we will install the CRDs and snapshot controller.
            if version_gt "${CSI_PROW_KUBERNETES_VERSION}" "1.16.255" || "${CSI_PROW_KUBERNETES_VERSION}" == "latest"; then
                info "Version ${CSI_PROW_KUBERNETES_VERSION}, installing CRDs and snapshot controller"
                install_snapshot_crds
                install_snapshot_controller
            else
                info "Version ${CSI_PROW_KUBERNETES_VERSION}, skipping CRDs and snapshot controller"
            fi

            # Installing the driver might be disabled.
            if ${CSI_PROW_DRIVER_INSTALL} "$images"; then
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

                    # Run tests that are feature tagged, but non-alpha
                    # Ignore: Double quote to prevent globbing and word splitting.
                    # shellcheck disable=SC2086
                    if ! run_e2e parallel-features ${CSI_PROW_GINKO_PARALLEL} \
                         -focus="External.Storage.*($(regex_join "${CSI_PROW_E2E_FOCUS}"))" \
                         -skip="$(regex_join "${CSI_PROW_E2E_SERIAL}")"; then
                        warn "E2E parallel features failed"
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
            delete_cluster_inside_prow_job
        fi

        if tests_need_alpha_cluster && [ "${CSI_PROW_E2E_ALPHA_GATES}" ]; then
            # Need to (re)create the cluster.
            start_cluster "${CSI_PROW_E2E_ALPHA_GATES}" || die "starting alpha cluster failed"

            # Install necessary snapshot CRDs and snapshot controller
            # For Kubernetes 1.17+, we will install the CRDs and snapshot controller.
            if version_gt "${CSI_PROW_KUBERNETES_VERSION}" "1.16.255" || "${CSI_PROW_KUBERNETES_VERSION}" == "latest"; then
                info "Version ${CSI_PROW_KUBERNETES_VERSION}, installing CRDs and snapshot controller"
                install_snapshot_crds
                install_snapshot_controller
            else
                info "Version ${CSI_PROW_KUBERNETES_VERSION}, skipping CRDs and snapshot controller"
            fi

            # Installing the driver might be disabled.
            if ${CSI_PROW_DRIVER_INSTALL} "$images"; then
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
            delete_cluster_inside_prow_job
        fi
    fi

    # Merge all junit files into one. This gets rid of duplicated "skipped" tests.
    if ls "${ARTIFACTS}"/junit_*.xml 2>/dev/null >&2; then
        run_filter_junit -o "${CSI_PROW_WORK}/junit_final.xml" "${ARTIFACTS}"/junit_*.xml && rm "${ARTIFACTS}"/junit_*.xml && mv "${CSI_PROW_WORK}/junit_final.xml" "${ARTIFACTS}"
    fi

    return "$ret"
}

# This function can be called by a repo's top-level cloudbuild.sh:
# it handles environment set up in the GCR cloud build and then
# invokes "make push-multiarch" to do the actual image building.
gcr_cloud_build () {
    # Register gcloud as a Docker credential helper.
    # Required for "docker buildx build --push".
    gcloud auth configure-docker

    if find . -name Dockerfile | grep -v ^./vendor | xargs --no-run-if-empty cat | grep -q ^RUN; then
        # Needed for "RUN" steps on non-linux/amd64 platforms.
        # See https://github.com/multiarch/qemu-user-static#getting-started
        (set -x; docker run --rm --privileged multiarch/qemu-user-static --reset -p yes)
    fi

    # Extract tag-n-hash value from GIT_TAG (form vYYYYMMDD-tag-n-hash) for REV value.
    REV=v$(echo "$GIT_TAG" | cut -f3- -d 'v')

    run_with_go "${CSI_PROW_GO_VERSION_BUILD}" make push-multiarch REV="${REV}" REGISTRY_NAME="${REGISTRY_NAME}" BUILD_PLATFORMS="${CSI_PROW_BUILD_PLATFORMS}"
}
