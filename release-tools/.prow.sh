#! /bin/bash -e

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

# This is for testing csi-release-tools itself in Prow. All other
# repos use prow.sh for that, but as csi-release-tools isn't a normal
# repo with some Go code in it, it has a custom Prow test script.

./verify-shellcheck.sh "$(pwd)"
./verify-spelling.sh "$(pwd)"
./verify-boilerplate.sh "$(pwd)"
