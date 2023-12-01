#!/bin/bash

# Copyright 2014 The Kubernetes Authors.
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

set -o errexit
set -o nounset
set -o pipefail

echo "Verifying boilerplate"

if [[ -z "$(command -v python)" ]]; then
  echo "Cannot find python. Make link to python3..."
  update-alternatives --install /usr/bin/python python /usr/bin/python3 1
fi

# The csi-release-tools directory (absolute path).
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Directory to check. Default is the parent of the tools themselves.
ROOT="${1:-${TOOLS}/..}"

boiler="${TOOLS}/boilerplate/boilerplate.py"

mapfile -t files_need_boilerplate < <("${boiler}" --rootdir="${ROOT}" --verbose)

# Run boilerplate.py unit tests
unitTestOut="$(mktemp)"
trap cleanup EXIT
cleanup() {
	rm "${unitTestOut}"
}

# Run boilerplate check
if [[ ${#files_need_boilerplate[@]} -gt 0 ]]; then
  for file in "${files_need_boilerplate[@]}"; do
    echo "Boilerplate header is wrong for: ${file}"
  done

  exit 1
fi

echo "Done"
