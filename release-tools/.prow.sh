#! /bin/bash -e
#
# This is for testing csi-release-tools itself in Prow. All other
# repos use prow.sh for that, but as csi-release-tools isn't a normal
# repo with some Go code in it, it has a custom Prow test script.

./verify-shellcheck.sh "$(pwd)"
