#! /bin/sh -e

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

# This script verifies that the content of a directory managed
# by "git subtree" has not been modified locally. It does that
# by looking for commits that modify the files with the
# subtree prefix (aka directory) while ignoring merge
# commits. Merge commits are where "git subtree" pulls the
# upstream files into the directory.
#
# Theoretically a developer can subvert this check by modifying files
# in a merge commit, but in practice that shouldn't happen.

DIR="$1"
if [ ! "$DIR" ]; then
    echo "usage: $0 <directory>" >&2
    exit 1
fi

REV=$(git log -n1 --remove-empty --format=format:%H --no-merges -- "$DIR")
if [ "$REV" ]; then
    echo "Directory '$DIR' contains non-upstream changes:"
    echo
    git log --no-merges -- "$DIR"
    exit 1
else
    echo "$DIR is a clean copy of upstream."
fi
