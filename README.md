# [csi-release-tools](https://github.com/kubernetes-csi/csi-release-tools)

These build and test rules can be shared between different Go projects
without modifications. Customization for the different projects happen
in the top-level Makefile.

The rules include support for building and pushing Docker images, with
the following features:
 - one or more command and image per project
 - push canary and/or tagged release images
 - automatically derive the image tag(s) from repo tags
 - the source code revision is stored in a "revision" image label
 - never overwrites an existing release image

Usage
-----

The expected repository layout is:
 - `cmd/*/*.go` - source code for each command
 - `cmd/*/Dockerfile` - docker file for each command or
   Dockerfile in the root when only building a single command
 - `Makefile` - includes `release-tools/build.make` and sets
   configuration variables
 - `.travis.yml` - a symlink to `release-tools/.travis.yml`

To create a release, tag a certain revision with a name that
starts with `v`, for example `v1.0.0`, then `make push`
while that commit is checked out.

It does not matter on which branch that revision exists, i.e. it is
possible to create releases directly from master. A release branch can
still be created for maintenance releases later if needed.

Release branches are expected to be named `release-x.y` for releases
`x.y.z`. Building from such a branch creates `x.y-canary`
images. Building from master creates the main `canary` image.

Sharing and updating
--------------------

[`git subtree`](https://github.com/git/git/blob/master/contrib/subtree/git-subtree.txt)
is the recommended way of maintaining a copy of the rules inside the
`release-tools` directory of a project. This way, it is possible to make
changes also locally, test them and then push them back to the shared
repository at a later time.

Cheat sheet:

- `git subtree add --prefix=release-tools https://github.com/kubernetes-csi/csi-release-tools.git master` - add release tools to a repo which does not have them yet (only once)
- `git subtree pull --prefix=release-tools https://github.com/kubernetes-csi/csi-release-tools.git master` - update local copy to latest upstream (whenever upstream changes)
- edit, `git commit`, `git subtree push --prefix=release-tools git@github.com:<user>/csi-release-tools.git <my-new-or-existing-branch>` - push to a new branch before submitting a PR

verify-shellcheck.sh
--------------------

The [verify-shellcheck.sh](./verify-shellcheck.sh) script in this repo
is a stripped down copy of the [corresponding
script](https://github.com/kubernetes/kubernetes/blob/release-1.14/hack/verify-shellcheck.sh)
in the Kubernetes repository. It can be used to check for certain
errors shell scripts, like missing quotation marks. The default
`test-shellcheck` target in [build.make](./build.make) only checks the
scripts in this directory. Components can add more directories to
`TEST_SHELLCHECK_DIRS` to check also other scripts.

End-to-end testing
------------------

A repo that wants to opt into testing via Prow must set up a top-level
`.prow.sh`. Typically that will source `prow.sh` and then transfer
control to it:

``` bash
#! /bin/bash -e

. release-tools/prow.sh
main
```

All Kubernetes-CSI repos are expected to switch to Prow. For details
on what is enabled in Prow, see
https://github.com/kubernetes/test-infra/tree/master/config/jobs/kubernetes-csi

Test results for periodic jobs are visible in
https://testgrid.k8s.io/sig-storage-csi

It is possible to reproduce the Prow testing locally on a suitable machine:
- Linux host
- Docker installed
- code to be tested checkout out in `$GOPATH/src/<import path>`
- `cd $GOPATH/src/<import path> && ./.prow.sh`

Beware that the script intentionally doesn't clean up after itself and
modifies the content of `$GOPATH`, in particular the `kubernetes` and
`kind` repositories there. Better run it in an empty, disposable
`$GOPATH`.

When it terminates, the following command can be used to get access to
the Kubernetes cluster that was brought up for testing (assuming that
this step succeeded):

    export KUBECONFIG="$(kind get kubeconfig-path --name="csi-prow")"

It is possible to control the execution via environment variables. See
`prow.sh` for details. Particularly useful is testing against different
Kubernetes releases:

    CSI_PROW_KUBERNETES_VERSION=1.13.3 ./.prow.sh
    CSI_PROW_KUBERNETES_VERSION=latest ./.prow.sh
