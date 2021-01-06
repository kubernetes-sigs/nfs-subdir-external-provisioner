#!/usr/bin/env bash

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
#
# This script can be used while converting a repo from "dep" to "go mod"
# by calling it after "go mod init" or to update the Kubernetes packages
# in a repo that has already been converted. Only packages that are
# part of kubernetes/kubernetes and thus part of a Kubernetes release
# are modified. Other k8.io packages (like k8s.io/klog, k8s.io/utils)
# need to be updated separately.

set -o pipefail

cmd=$0

function help () {
    echo "$cmd <kubernetes version = x.y.z> - update all components from kubernetes/kubernetes to that version"
}

if [ $# -ne 1 ]; then
    help
    exit 1
fi
case "$1" in -h|--help|help) help; exit 0;; esac

die () {
    echo >&2 "$@"
    exit 1
}

k8s="$1"

# If the repo imports k8s.io/kubernetes (directly or indirectly), then
# "go mod" will try to find "v0.0.0" versions because
# k8s.io/kubernetes has those in it's go.mod file
# (https://github.com/kubernetes/kubernetes/blob/2bd9643cee5b3b3a5ecbd3af49d09018f0773c77/go.mod#L146-L157).
# (https://github.com/kubernetes/kubernetes/issues/79384).
#
# We need to replicate the replace statements to override those fake
# versions also in our go.mod file (idea and some code from
# https://github.com/kubernetes/kubernetes/issues/79384#issuecomment-521493597).
mods=$( (set -x; curl --silent --show-error --fail "https://raw.githubusercontent.com/kubernetes/kubernetes/v${k8s}/go.mod") |
          sed -n 's|.*k8s.io/\(.*\) => ./staging/src/k8s.io/.*|k8s.io/\1|p'
   ) || die "failed to determine Kubernetes staging modules"
for mod in $mods; do
    # The presence of a potentially incomplete go.mod file affects this command,
    # so move elsewhere.
    modinfo=$(set -x; cd /; env GO111MODULE=on go mod download -json "$mod@kubernetes-${k8s}") ||
        die "failed to determine version of $mod: $modinfo"
    v=$(echo "$modinfo" | sed -n 's|.*"Version": "\(.*\)".*|\1|p')
    (set -x; env GO111MODULE=on go mod edit "-replace=$mod=$mod@$v") || die "'go mod edit' failed"
done

packages=

# Beware that we have to work with packages, not modules (i.e. no -m
# flag), because some modules trigger a "no Go code except tests"
# error.  Getting their packages works.
if ! packages=$( (set -x; env GO111MODULE=on go list all) | grep ^k8s.io/ | sed -e 's; *;;'); then
    cat >&2 <<EOF

Warning: "GO111MODULE=on go list all" failed, trying individual packages instead.

EOF
    if ! packages=$( (set -x; env GO111MODULE=on go list -f '{{ join .Deps "\n" }}' ./...) | grep ^k8s.io/); then
        cat >&2 <<EOF

ERROR: could not obtain package list, both of these commands failed:
       GO111MODULE=on go list all
       GO111MODULE=on go list -f '{{ join .Deps "\n" }}' ./pkg/...
EOF
        exit 1
    fi
fi

deps=
for package in $packages; do
    # Some k8s.io packages do not come from Kubernetes staging and
    # thus have different versioning (or none at all...). We need to
    # skip those.  We know what packages are from staging because we
    # now have "replace" statements for them in go.mod.
    #
    # shellcheck disable=SC2001
    module=$(echo "$package" | sed -e 's;k8s.io/\([^/]*\)/.*;k8s.io/\1;')
    if grep -q -w "$module *=>" go.mod; then
        deps="$deps $(echo "$package" | sed -e "s;\$;@kubernetes-$k8s;" -e 's;^k8s.io/kubernetes\(/.*\)@kubernetes-;k8s.io/kubernetes\1@v;')"
    fi
done

# shellcheck disable=SC2086
(set -x; env GO111MODULE=on go get $deps 2>&1) || die "go get failed"
echo "SUCCESS"
