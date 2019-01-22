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
