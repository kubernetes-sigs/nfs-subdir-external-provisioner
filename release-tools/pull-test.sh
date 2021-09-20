#! /bin/sh

# Copyright 2021 The Kubernetes Authors.
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

# This script is called by pull Prow jobs for the csi-release-tools
# repo to ensure that the changes in the PR work when imported into
# some other repo.

set -ex

# It must be called inside the updated csi-release-tools repo.
CSI_RELEASE_TOOLS_DIR="$(pwd)"

# Update the other repo.
cd "$PULL_TEST_REPO_DIR"
git subtree pull --squash --prefix=release-tools "$CSI_RELEASE_TOOLS_DIR" master
git log -n2

# Now fall through to testing.
exec ./.prow.sh
