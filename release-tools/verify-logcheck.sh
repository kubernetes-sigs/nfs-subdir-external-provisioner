#!/usr/bin/env bash

# Copyright 2024 The Kubernetes Authors.
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

# This script uses the logcheck tool to analyze the source code
# for proper usage of klog contextual logging.

set -o errexit
set -o nounset
set -o pipefail

LOGCHECK_VERSION=${1:-0.10.0}

# This will canonicalize the path
CSI_LIB_UTIL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)

# Create a temporary directory for installing logcheck and
# set up a trap command to remove it when the script exits.
CSI_LIB_UTIL_TEMP=$(mktemp -d 2>/dev/null || mktemp -d -t csi-lib-utils.XXXXXX)
trap 'rm -rf "${CSI_LIB_UTIL_TEMP}"' EXIT

echo "Installing logcheck to temp dir: sigs.k8s.io/logtools/logcheck@v${LOGCHECK_VERSION}"
GOBIN="${CSI_LIB_UTIL_TEMP}" go install "sigs.k8s.io/logtools/logcheck@v${LOGCHECK_VERSION}"
echo "Verifying logcheck: ${CSI_LIB_UTIL_TEMP}/logcheck -check-contextual ${CSI_LIB_UTIL_ROOT}/..."
"${CSI_LIB_UTIL_TEMP}/logcheck" -check-contextual -check-with-helpers "${CSI_LIB_UTIL_ROOT}/..."
