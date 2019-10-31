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

if [ -f Gopkg.toml ]; then
    echo "Repo uses 'dep' for vendoring."
    (set -x; dep ensure)
elif [ -f go.mod ]; then
    release-tools/verify-go-version.sh "go"
    (set -x; env GO111MODULE=on go mod tidy && env GO111MODULE=on go mod vendor)
fi
