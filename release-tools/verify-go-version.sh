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

GO="$1"

if [ ! "$GO" ]; then
    echo >&2 "usage: $0 <path to go binary>"
    exit 1
fi

die () {
    echo "ERROR: $*"
    exit 1
}

version=$("$GO" version) || die "determining version of $GO failed"
# shellcheck disable=SC2001
majorminor=$(echo "$version" | sed -e 's/.*go\([0-9]*\)\.\([0-9]*\).*/\1.\2/')
# SC1091: Not following: release-tools/prow.sh was not specified as input (see shellcheck -x).
# shellcheck disable=SC1091
expected=$(. release-tools/prow.sh >/dev/null && echo "$CSI_PROW_GO_VERSION_BUILD")

if [ "$majorminor" != "$expected" ]; then
    cat >&2 <<EOF

======================================================
                  WARNING

  This projects is tested with Go v$expected.
  Your current Go version is v$majorminor.
  This may or may not be close enough.

  In particular test-gofmt and test-vendor
  are known to be sensitive to the version of
  Go.
======================================================

EOF
fi
