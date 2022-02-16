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

# force the usage of /bin/bash instead of /bin/sh
SHELL := /bin/bash

.PHONY: build-% build container-% container push-% push clean test

# A space-separated list of all commands in the repository, must be
# set in main Makefile of a repository.
# CMDS=

# Normally, commands are expected in "cmd". That can be changed for a
# repository to something else by setting CMDS_DIR before including build.make.
CMDS_DIR ?= cmd

# This is the default. It can be overridden in the main Makefile after
# including build.make.
REGISTRY_NAME?=quay.io/k8scsi

# Can be set to -mod=vendor to ensure that the "vendor" directory is used.
GOFLAGS_VENDOR=

# Revision that gets built into each binary via the main.version
# string. Uses the `git describe` output based on the most recent
# version tag with a short revision suffix or, if nothing has been
# tagged yet, just the revision.
#
# Beware that tags may also be missing in shallow clones as done by
# some CI systems (like TravisCI, which pulls only 50 commits).
REV=$(shell git describe --long --tags --match='v*' --dirty 2>/dev/null || git rev-list -n1 HEAD)

# A space-separated list of image tags under which the current build is to be pushed.
# Determined dynamically.
IMAGE_TAGS=

# A "canary" image gets built if the current commit is the head of the remote "master" branch.
# That branch does not exist when building some other branch in TravisCI.
IMAGE_TAGS+=$(shell if [ "$$(git rev-list -n1 HEAD)" = "$$(git rev-list -n1 origin/master 2>/dev/null)" ]; then echo "canary"; fi)

# A "X.Y.Z-canary" image gets built if the current commit is the head of a "origin/release-X.Y.Z" branch.
# The actual suffix does not matter, only the "release-" prefix is checked.
IMAGE_TAGS+=$(shell git branch -r --points-at=HEAD | grep 'origin/release-' | grep -v -e ' -> ' | sed -e 's;.*/release-\(.*\);\1-canary;')

# A release image "vX.Y.Z" gets built if there is a tag of that format for the current commit.
# --abbrev=0 suppresses long format, only showing the closest tag.
IMAGE_TAGS+=$(shell tagged="$$(git describe --tags --match='v*' --abbrev=0)"; if [ "$$tagged" ] && [ "$$(git rev-list -n1 HEAD)" = "$$(git rev-list -n1 $$tagged)" ]; then echo $$tagged; fi)

# Images are named after the command contained in them.
IMAGE_NAME=$(REGISTRY_NAME)/$*

ifdef V
# Adding "-alsologtostderr" assumes that all test binaries contain glog. This is not guaranteed.
TESTARGS = -v -args -alsologtostderr -v 5
else
TESTARGS =
endif

# Specific packages can be excluded from each of the tests below by setting the *_FILTER_CMD variables
# to something like "| grep -v 'github.com/kubernetes-csi/project/pkg/foobar'". See usage below.

# BUILD_PLATFORMS contains a set of tuples [os arch buildx_platform suffix base_image addon_image]
# separated by semicolon. An empty variable or empty entry (= just a
# semicolon) builds for the default platform of the current Go
# toolchain.
BUILD_PLATFORMS =

# Add go ldflags using LDFLAGS at the time of compilation.
IMPORTPATH_LDFLAGS = -X main.version=$(REV)
EXT_LDFLAGS = -extldflags "-static"
LDFLAGS =
FULL_LDFLAGS = $(LDFLAGS) $(IMPORTPATH_LDFLAGS) $(EXT_LDFLAGS)
# This builds each command (= the sub-directories of ./cmd) for the target platform(s)
# defined by BUILD_PLATFORMS.
$(CMDS:%=build-%): build-%: check-go-version-go
	mkdir -p bin
	# os_arch_seen captures all of the $$os-$$arch-$$buildx_platform seen for the current binary
	# that we want to build, if we've seen an $$os-$$arch-$$buildx_platform before it means that
	# we don't need to build it again, this is done to avoid building
	# the windows binary multiple times (see the default value of $$BUILD_PLATFORMS)
	export os_arch_seen="" && echo '$(BUILD_PLATFORMS)' | tr ';' '\n' | while read -r os arch buildx_platform suffix base_image addon_image; do \
		os_arch_seen_pre=$${os_arch_seen%%$$os-$$arch-$$buildx_platform*}; \
		if ! [ $${#os_arch_seen_pre} = $${#os_arch_seen} ]; then \
			continue; \
		fi; \
		if ! (set -x; cd ./$(CMDS_DIR)/$* && CGO_ENABLED=0 GOOS="$$os" GOARCH="$$arch" go build $(GOFLAGS_VENDOR) -a -ldflags '$(FULL_LDFLAGS)' -o "$(abspath ./bin)/$*$$suffix" .); then \
			echo "Building $* for GOOS=$$os GOARCH=$$arch failed, see error(s) above."; \
			exit 1; \
		fi; \
		os_arch_seen+=";$$os-$$arch-$$buildx_platform"; \
	done

$(CMDS:%=container-%): container-%: build-%
	docker build -t $*:latest -f $(shell if [ -e ./$(CMDS_DIR)/$*/Dockerfile ]; then echo ./$(CMDS_DIR)/$*/Dockerfile; else echo Dockerfile; fi) --label revision=$(REV) .

$(CMDS:%=push-%): push-%: container-%
	set -ex; \
	push_image () { \
		docker tag $*:latest $(IMAGE_NAME):$$tag; \
		docker push $(IMAGE_NAME):$$tag; \
	}; \
	for tag in $(IMAGE_TAGS); do \
		if [ "$$tag" = "canary" ] || echo "$$tag" | grep -q -e '-canary$$'; then \
			: "creating or overwriting canary image"; \
			push_image; \
		elif docker pull $(IMAGE_NAME):$$tag 2>&1 | tee /dev/stderr | grep -q "manifest for $(IMAGE_NAME):$$tag not found"; then \
			: "creating release image"; \
			push_image; \
		else \
			: "release image $(IMAGE_NAME):$$tag already exists, skipping push"; \
		fi; \
	done

build: $(CMDS:%=build-%)
container: $(CMDS:%=container-%)
push: $(CMDS:%=push-%)

# Additional parameters are needed when pushing to a local registry,
# see https://github.com/docker/buildx/issues/94.
# However, that then runs into https://github.com/docker/cli/issues/2396.
#
# What works for local testing is:
# make push-multiarch PULL_BASE_REF=master REGISTRY_NAME=<your account on dockerhub.io> BUILD_PLATFORMS="linux amd64; windows amd64 .exe; linux ppc64le -ppc64le; linux s390x -s390x"
DOCKER_BUILDX_CREATE_ARGS ?=

# This target builds a multiarch image for one command using Moby BuildKit builder toolkit.
# Docker Buildx is included in Docker 19.03.
#
# ./$(CMDS_DIR)/<command>/Dockerfile[.Windows] is used if found, otherwise Dockerfile[.Windows].
# It is currently optional: if no such file exists, Windows images are not included,
# even when Windows is listed in BUILD_PLATFORMS. That way, projects can test that
# Windows binaries can be built before adding a Dockerfile for it.
#
# BUILD_PLATFORMS determines which individual images are included in the multiarch image.
# PULL_BASE_REF must be set to 'master', 'release-x.y', or a tag name, and determines
# the tag for the resulting multiarch image.
$(CMDS:%=push-multiarch-%): push-multiarch-%: check-pull-base-ref build-%
	set -ex; \
	export DOCKER_CLI_EXPERIMENTAL=enabled; \
	docker buildx create $(DOCKER_BUILDX_CREATE_ARGS) --use --name multiarchimage-buildertest; \
	trap "docker buildx rm multiarchimage-buildertest" EXIT; \
	dockerfile_linux=$$(if [ -e ./$(CMDS_DIR)/$*/Dockerfile ]; then echo ./$(CMDS_DIR)/$*/Dockerfile; else echo Dockerfile; fi); \
	dockerfile_windows=$$(if [ -e ./$(CMDS_DIR)/$*/Dockerfile.Windows ]; then echo ./$(CMDS_DIR)/$*/Dockerfile.Windows; else echo Dockerfile.Windows; fi); \
	if [ '$(BUILD_PLATFORMS)' ]; then build_platforms='$(BUILD_PLATFORMS)'; else build_platforms="linux amd64"; fi; \
	if ! [ -f "$$dockerfile_windows" ]; then \
		build_platforms="$$(echo "$$build_platforms" | sed -e 's/windows *[^ ]* *[^ ]* *.exe *[^ ]* *[^ ]*//g' -e 's/; *;/;/g' -e 's/;[ ]*$$//')"; \
	fi; \
	pushMultiArch () { \
		tag=$$1; \
		echo "$$build_platforms" | tr ';' '\n' | while read -r os arch buildx_platform suffix base_image addon_image; do \
			escaped_base_image=$${base_image/:/-}; \
			escaped_buildx_platform=$${buildx_platform//\//-}; \
			if ! [ -z $$escaped_base_image ]; then escaped_base_image+="-"; fi; \
			docker buildx build --push \
				--tag $(IMAGE_NAME):$$escaped_buildx_platform-$$os-$$escaped_base_image$$tag \
				--platform=$$os/$$buildx_platform \
				--file $$(eval echo \$${dockerfile_$$os}) \
				--build-arg binary=./bin/$*$$suffix \
				--build-arg ARCH=$$arch \
				--build-arg BASE_IMAGE=$$base_image \
				--build-arg ADDON_IMAGE=$$addon_image \
				--label revision=$(REV) \
				.; \
		done; \
		images=$$(echo "$$build_platforms" | tr ';' '\n' | while read -r os arch buildx_platform suffix base_image addon_image; do \
			escaped_base_image=$${base_image/:/-}; \
			escaped_buildx_platform=$${buildx_platform//\//-}; \
			if ! [ -z $$escaped_base_image ]; then escaped_base_image+="-"; fi; \
			echo $(IMAGE_NAME):$$escaped_buildx_platform-$$os-$$escaped_base_image$$tag; \
		done); \
		docker manifest create --amend $(IMAGE_NAME):$$tag $$images; \
		echo "$$build_platforms" | tr ';' '\n' | while read -r os arch buildx_platform suffix base_image addon_image; do \
			if [ $$os = "windows" ]; then \
				escaped_base_image=$${base_image/:/-}; \
				if ! [ -z $$escaped_base_image ]; then escaped_base_image+="-"; fi; \
				image=$(IMAGE_NAME):$$arch-$$os-$$escaped_base_image$$tag; \
				os_version=$$(docker manifest inspect mcr.microsoft.com/windows/$${base_image} | grep "os.version" | head -n 1 | awk '{print $$2}' | sed -e 's/"//g') || true; \
				docker manifest annotate --os-version $$os_version $(IMAGE_NAME):$$tag $$image; \
			fi; \
		done; \
		docker manifest push -p $(IMAGE_NAME):$$tag; \
	}; \
	if [ $(PULL_BASE_REF) = "master" ]; then \
			: "creating or overwriting canary image"; \
			pushMultiArch canary; \
	elif echo $(PULL_BASE_REF) | grep -q -e 'release-*' ; then \
			: "creating or overwriting canary image for release branch"; \
			release_canary_tag=$$(echo $(PULL_BASE_REF) | cut -f2 -d '-')-canary; \
			pushMultiArch $$release_canary_tag; \
	elif docker pull $(IMAGE_NAME):$(PULL_BASE_REF) 2>&1 | tee /dev/stderr | grep -q "manifest for $(IMAGE_NAME):$(PULL_BASE_REF) not found"; then \
			: "creating release image"; \
			pushMultiArch $(PULL_BASE_REF); \
	else \
			: "ERROR: release image $(IMAGE_NAME):$(PULL_BASE_REF) already exists: a new tag is required!"; \
			exit 1; \
	fi

.PHONY: check-pull-base-ref
check-pull-base-ref:
	if ! [ "$(PULL_BASE_REF)" ]; then \
		echo >&2 "ERROR: PULL_BASE_REF must be set to 'master', 'release-x.y', or a tag name."; \
		exit 1; \
	fi

.PHONY: push-multiarch
push-multiarch: $(CMDS:%=push-multiarch-%)

clean:
	-rm -rf bin

test: check-go-version-go

.PHONY: test-go
test: test-go
test-go:
	@ echo; echo "### $@:"
	go test $(GOFLAGS_VENDOR) `go list $(GOFLAGS_VENDOR) ./... | grep -v -e 'vendor' -e '/test/e2e$$' $(TEST_GO_FILTER_CMD)` $(TESTARGS)

.PHONY: test-vet
test: test-vet
test-vet:
	@ echo; echo "### $@:"
	go vet $(GOFLAGS_VENDOR) `go list $(GOFLAGS_VENDOR) ./... | grep -v vendor $(TEST_VET_FILTER_CMD)`

.PHONY: test-fmt
test: test-fmt
test-fmt:
	@ echo; echo "### $@:"
	files=$$(find . -name '*.go' | grep -v './vendor' $(TEST_FMT_FILTER_CMD)); \
	if [ $$(gofmt -d $$files | wc -l) -ne 0 ]; then \
		echo "formatting errors:"; \
		gofmt -d $$files; \
		false; \
	fi

# This test only runs when dep >= 0.5 is installed, which is the case for the CI setup.
# When using 'go mod', we allow the test to be skipped in the Prow CI under some special
# circumstances, because it depends on accessing all remote repos and thus
# running it all the time would defeat the purpose of vendoring:
# - not handling a PR or
# - the fabricated merge commit leaves go.mod, go.sum and vendor dir unchanged
# - release-tools also didn't change (changing rules or Go version might lead to
#   a different result and thus must be tested)
# - import statements not changed (because if they change, go.mod might have to be updated)
#
# "git diff" is intelligent enough to annotate changes inside the "import" block in
# the start of the diff hunk:
#
# diff --git a/rpc/common.go b/rpc/common.go
# index bb4a5c4..5fa4271 100644
# --- a/rpc/common.go
# +++ b/rpc/common.go
# @@ -21,7 +21,6 @@ import (
#         "fmt"
#         "time"
#
# -       "google.golang.org/grpc"
#         "google.golang.org/grpc/codes"
#         "google.golang.org/grpc/status"
#
# We rely on that to find such changes.
#
# Vendoring is optional when using go.mod.
.PHONY: test-vendor
test: test-vendor
test-vendor:
	@ echo; echo "### $@:"
	@ ./release-tools/verify-vendor.sh

.PHONY: test-subtree
test: test-subtree
test-subtree:
	@ echo; echo "### $@:"
	./release-tools/verify-subtree.sh release-tools

# Components can extend the set of directories which must pass shellcheck.
# The default is to check only the release-tools directory itself.
TEST_SHELLCHECK_DIRS=release-tools
.PHONY: test-shellcheck
test: test-shellcheck
test-shellcheck:
	@ echo; echo "### $@:"
	@ ret=0; \
	if ! command -v docker; then \
		echo "skipped, no Docker"; \
		exit 0; \
        fi; \
	for dir in $(abspath $(TEST_SHELLCHECK_DIRS)); do \
		echo; \
		echo "$$dir:"; \
		./release-tools/verify-shellcheck.sh "$$dir" || ret=1; \
	done; \
	exit $$ret

# Targets in the makefile can depend on check-go-version-<path to go binary>
# to trigger a warning if the x.y version of that binary does not match
# what the project uses. Make ensures that this is only checked once per
# invocation.
.PHONY: check-go-version-%
check-go-version-%:
	./release-tools/verify-go-version.sh "$*"

# Test for spelling errors.
.PHONY: test-spelling
test-spelling:
	@ echo; echo "### $@:"
	@ ./release-tools/verify-spelling.sh "$(pwd)"

# Test the boilerplates of the files.
.PHONY: test-boilerplate
test-boilerplate:
	@ echo; echo "### $@:"
	@ ./release-tools/verify-boilerplate.sh "$(pwd)"
