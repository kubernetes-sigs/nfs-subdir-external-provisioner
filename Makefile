# Copyright 2026 The Kubernetes Authors.
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

# Image URL to use all building/pushing image targets
VERSION ?= v4.0.3-rc01
IMG ?= registry.k8s.io/sig-storage/nfs-subdir-external-provisioner

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

GIT_COMMIT ?= $(shell git rev-parse HEAD)
BUILDDATE = $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

LDFLAG_OPTIONS = -ldflags "-X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.Version=$(VERSION) \
                      -X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.GitCommit=$(GIT_COMMIT) \
                      -X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.BuildDate=$(BUILDDATE)"


.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

GOVULNCHECK = $(shell pwd)/bin/govulncheck
.PHONY: govulncheck
govulncheck: $(GOVULNCHECK) ## Run govulncheck against code.
	- $(GOVULNCHECK) ./...

$(GOVULNCHECK): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install golang.org/x/vuln/cmd/govulncheck@latest

##@ Build

.PHONY: build
build: fmt vet ## Build nfs-subdir-external-provisioner binary.
	go build $(LDFLAG_OPTIONS) -o bin/nfs-subdir-external-provisioner cmd/nfs-subdir-external-provisioner/provisioner.go

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the nfs-subdir-external-provisioner.
	$(CONTAINER_TOOL) build -t ${IMG}:${VERSION} -f build/Dockerfile \
				--build-arg VERSION=$(VERSION) --build-arg GITCOMMIT=$(GIT_COMMIT) --build-arg BUILDDATE=$(BUILDDATE) .

.PHONY: docker-push
docker-push: ## Push docker image with the nfs-subdir-external-provisioner.
	$(CONTAINER_TOOL) push ${IMG}:${VERSION}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.

PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the nfs-subdir-external-provisioner for cross-platform support.
	- $(CONTAINER_TOOL) buildx create --name nfs-subdir-external-provisioner
	$(CONTAINER_TOOL) buildx use nfs-subdir-external-provisioner
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${IMG}:${VERSION} -f build/Dockerfile \
  						--build-arg VERSION=$(VERSION) --build-arg GITCOMMIT=$(GIT_COMMIT) --build-arg BUILDDATE=$(BUILDDATE) .
	- $(CONTAINER_TOOL) buildx rm nfs-subdir-external-provisioner

ifndef ignore-not-found
  ignore-not-found = false
endif

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif
