#!/bin/bash

# Copyright 2023 The Kubernetes Authors.
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


# Usage: go-modules-targeted-update.sh
#
# Batch update specific dependencies for sidecars.
#
# Required environment variables
# CSI_RELEASE_TOKEN: Github token needed for generating release notes
# GITHUB_USER: Github username to create PRs with
#
# Instructions:
# 1. Login with "gh auth login"
# 2. Copy this script to the Github org directory (one directory above the
# repos)
# 3. Change $modules, $releases and $org if needed.
# 4. Set environment variables
# 5. Run script from the Github org directory
#
# Caveats:
# - This script doesn't handle interface incompatibility of updates.
#   You need to resolve interface incompatibility case by case. The
#   most frequent case is to update the interface(new parameters,  
#   name change of the method, etc.)in the sidecar repo and make sure
#   the build and test pass.


set -e
set -x

org="kubernetes-csi"

modules=(
"github.com/kubernetes-csi/csi-lib-utils@v0.15.1"
)

releases=(
#"external-attacher release-4.4"
#"external-provisioner release-3.6"
#"external-resizer release-1.9"
#"external-snapshotter release-6.3"
#"node-driver-registrar release-2.9"
)

for rel in "${releases[@]}"; do

    read -r repo branch <<< "$rel"
    if [ "$repo" != "#" ]; then
    (
        cd "$repo"
        git fetch upstream

        if [ "$(git rev-parse --verify "module-update-$branch" 2>/dev/null)" ]; then
            git checkout master && git branch -D "module-update-$branch"
        fi
        git checkout -B "module-update-$branch" "upstream/$branch"

        for mod in "${modules[@]}"; do
          go get "$mod"
        done
        go mod tidy
        go mod vendor

        git add --all
        git commit -m "Update go modules"
        git push origin "module-update-$branch" --force

            # Create PR
prbody=$(cat <<EOF
Updated the following go modules:

${modules[@]}

\`\`\`release-note
NONE
\`\`\`
EOF
)
        gh pr create --title="[$branch] Update go modules" --body "$prbody"  --head "$GITHUB_USER:module-update-$branch" --base "$branch" --repo="$org/$repo"
    )
    fi
done
