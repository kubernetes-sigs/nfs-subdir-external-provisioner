# Sidecar Release Process

This page describes the process for releasing a kubernetes-csi sidecar.

## Prerequisites

The release manager must:

* Be a member of the kubernetes-csi organization. Open an
  [issue](https://github.com/kubernetes/org/issues/new?assignees=&labels=area%2Fgithub-membership&template=membership.md&title=REQUEST%3A+New+membership+for+%3Cyour-GH-handle%3E) in
  kubernetes/org to request membership
* Be part of the maintainers group for the repository.
  Membership can be requested by submitting a PR to kubernetes/org.
  [Example](https://github.com/kubernetes/org/pull/1467)

## Updating CI Jobs
Whenever a new Kubernetes minor version is released, our kubernetes-csi CI jobs
must be updated.

[Our CI jobs](https://k8s-testgrid.appspot.com/sig-storage-csi-ci) have the
naming convention `<hostpath-deployment-version>-on-<kubernetes-version>`.

1. Jobs should be actively monitored to find and fix failures in sidecars and
   infrastructure changes early in the development cycle. Test failures are sent
   to kubernetes-sig-storage-test-failures@googlegroups.com.
1. "-on-master" jobs are the closest reflection to the new Kubernetes version.
1. Fixes to our prow.sh CI script can be tested in the [CSI hostpath
   repo](https://github.com/kubernetes-csi/csi-driver-host-path) by modifying
   [prow.sh](https://github.com/kubernetes-csi/csi-driver-host-path/blob/HEAD/release-tools/prow.sh)
   along with any overrides in
   [.prow.sh](https://github.com/kubernetes-csi/csi-driver-host-path/blob/HEAD/.prow.sh)
   to mirror the failing environment. Once e2e tests are passing (verify-unit tests
   will fail), then the prow.sh changes can be submitted to [csi-release-tools](https://github.com/kubernetes-csi/csi-release-tools).
1. Changes can then be updated in all the sidecar repos and hostpath driver repo
   by following the [update
   instructions](https://github.com/kubernetes-csi/csi-release-tools/blob/HEAD/README.md#sharing-and-updating).
1. New pull and CI jobs are configured by adding new K8s versions to the top of
   [gen-jobs.sh](https://github.com/kubernetes/test-infra/blob/HEAD/config/jobs/kubernetes-csi/gen-jobs.sh).
   New pull jobs that have been unverified should be initially made optional by
   setting the new K8s version as
   [experimental](https://github.com/kubernetes/test-infra/blob/a1858f46d6014480b130789df58b230a49203a64/config/jobs/kubernetes-csi/gen-jobs.sh#L40).
1. Once new pull and CI jobs have been verified, and the new Kubernetes version
   is released, we can make the optional jobs required, and also remove the
   Kubernetes versions that are no longer supported.

## Release Process
1. Identify all issues and ongoing PRs that should go into the release, and
  drive them to resolution.
1. Download the latest version of the
   [K8s release notes generator](https://github.com/kubernetes/release/tree/HEAD/cmd/release-notes)
1. Create a
   [Github personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
   with `repo:public_repo` access
1. Generate release notes for the release. Replace arguments with the relevant
   information.
    * Clean up old cached information (also needed if you are generating release
      notes for multiple repos)
      ```bash
      rm -rf /tmp/k8s-repo
      ```
    * For new minor releases on master:
        ```bash
        GITHUB_TOKEN=<token> release-notes \
          --discover=mergebase-to-latest \
          --org=kubernetes-csi \
          --repo=external-provisioner \
          --required-author="" \
          --markdown-links \
          --output out.md
        ```
    * For new patch releases on a release branch:
        ```bash
        GITHUB_TOKEN=<token> release-notes \
          --discover=patch-to-latest \
          --branch=release-1.1 \
          --org=kubernetes-csi \
          --repo=external-provisioner \
          --required-author="" \
          --markdown-links \
          --output out.md
        ```
1. Compare the generated output to the new commits for the release to check if
   any notable change missed a release note.
1. Reword release notes as needed. Make sure to check notes for breaking
   changes and deprecations.
1. If release is a new major/minor version, create a new `CHANGELOG-<major>.<minor>.md`
   file. Otherwise, add the release notes to the top of the existing CHANGELOG
   file for that minor version.
1. Submit a PR for the CHANGELOG changes.
1. Submit a PR for README changes, in particular, Compatibility, Feature status,
   and any other sections that may need updating.
1. Check that all [canary CI
  jobs](https://k8s-testgrid.appspot.com/sig-storage-csi-ci) are passing,
  and that test coverage is adequate for the changes that are going into the release.
1. Make sure that no new PRs have merged in the meantime, and no PRs are in
   flight and soon to be merged.
1. Create a new release following a previous release as a template. Be sure to select the correct
   branch. This requires Github release permissions as required by the prerequisites.
   [external-provisioner example](https://github.com/kubernetes-csi/external-provisioner/releases/new)
1. If release was a new major/minor version, create a new `release-<minor>`
   branch at that commit.
1. Check [image build status](https://k8s-testgrid.appspot.com/sig-storage-image-build).
1. Promote images from k8s-staging-sig-storage to k8s.gcr.io/sig-storage. From
   the [k8s image
   repo](https://github.com/kubernetes/k8s.io/tree/HEAD/k8s.gcr.io/images/k8s-staging-sig-storage),
   run `./generate.sh > images.yaml`, and send a PR with the updated images.
   Once merged, the image promoter will copy the images from staging to prod.
1. Update [kubernetes-csi/docs](https://github.com/kubernetes-csi/docs) sidecar
   and feature pages with the new released version.
1. After all the sidecars have been released, update
   CSI hostpath driver with the new sidecars in the [CSI repo](https://github.com/kubernetes-csi/csi-driver-host-path/tree/HEAD/deploy)
   and [k/k
   in-tree](https://github.com/kubernetes/kubernetes/tree/HEAD/test/e2e/testing-manifests/storage-csi/hostpath/hostpath)

### Troubleshooting

#### Image build jobs

The following jobs are triggered after tagging to produce the corresponding
image(s):
https://k8s-testgrid.appspot.com/sig-storage-image-build

Clicking on a failed build job opens that job in https://prow.k8s.io. Next to
the job title is a rerun icon (circle with arrow). Clicking it opens a popup
with a "rerun" button that maintainers with enough permissions can use. If in
doubt, ask someone on #sig-release to rerun the job.

Another way to rerun a job is to search for it in https://prow.k8s.io and click
the rerun icon in the resulting job list:
https://prow.k8s.io/?job=canary-csi-test-push-images

#### Verify images

Canary and staged images can be viewed at https://console.cloud.google.com/gcr/images/k8s-staging-sig-storage

Promoted images can be viewed at https://console.cloud.google.com/gcr/images/k8s-artifacts-prod/us/sig-storage

## Adding support for a new Kubernetes release

1. Add the new release to `k8s_versions` in
   https://github.com/kubernetes/test-infra/blob/090dec5dd535d5f61b7ba52e671a810f5fc13dfd/config/jobs/kubernetes-csi/gen-jobs.sh#L25
   to enable generating a job for it. Set `experimental_k8s_version`
   in
   https://github.com/kubernetes/test-infra/blob/090dec5dd535d5f61b7ba52e671a810f5fc13dfd/config/jobs/kubernetes-csi/gen-jobs.sh#L40
   to ensure that the new jobs aren't run for PRs unless explicitly
   requested. Generate and submit the new jobs.
1. Create a test PR to try out the new job in some repo with `/test
   pull-kubernetes-csi-<repo>-<x.y>-on-kubernetes-<x.y>` where x.y
   matches the Kubernetes release. Alternatively, run .prow.sh in that
   repo locally with `CSI_PROW_KUBERNETES_VERSION=x.y.z`.
1. Optional: update to a [new
   release](https://github.com/kubernetes-sigs/kind/tags) of kind with
   pre-built images for the new Kubernetes release. This is optional
   if the current version of kind is able to build images for the new
   Kubernetes release. However, jobs require less resources when they
   don't need to build those images from the Kubernetes source code.
   This change needs to be tried out in a PR against a component
   first, then get submitted against csi-release-tools.
1. Optional: propagate the updated csi-release-tools to all components
   with the script from
   https://github.com/kubernetes-csi/csi-release-tools/issues/7#issuecomment-707025402
1. Once it is likely to work in all components, unset
   `experimental_k8s_version` and submit the updated jobs.
1. Once all sidecars for the new Kubernetes release are released,
   either bump the version number of the images in the existing
   [csi-driver-host-path
   deployments](https://github.com/kubernetes-csi/csi-driver-host-path/tree/HEAD/deploy)
   and/or create a new deployment, depending on what Kubernetes
   release an updated sidecar is compatible with. If no new deployment
   is needed, then add a symlink to document that there intentionally
   isn't a separate deployment. This symlink is not needed for Prow
   testing because that will use "kubernetes-latest" as fallback.
   Update that link when creating a new deployment.
1. Create a new csi-driver-host-path release.
1. Bump `CSI_PROW_DRIVER_VERSION` in prow.sh to that new release and
   (eventually) roll that change out to all repos by updating
   `release-tools` in them. This is used when testing manually. The
   Prow jobs override that value, so also update
   `hostpath_driver_version` in
   https://github.com/kubernetes/test-infra/blob/91b04e6af3a40a9bcff25aa030850a4721e2dd2b/config/jobs/kubernetes-csi/gen-jobs.sh#L46-L47
