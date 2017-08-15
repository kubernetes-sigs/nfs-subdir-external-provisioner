# Copyright 2016 The Kubernetes Authors.
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

ifeq ($(REGISTRY),)
        REGISTRY = quay.io/external_storage/
endif
ifeq ($(VERSION),)
        VERSION = latest
endif
IMAGE = $(REGISTRY)nfs-client-provisioner:$(VERSION)
IMAGE_ARM = $(REGISTRY)nfs-client-provisioner-arm:$(VERSION) 
MUTABLE_IMAGE = $(REGISTRY)nfs-client-provisioner:latest
MUTABLE_IMAGE_ARM = $(REGISTRY)nfs-client-provisioner-arm:latest

all: build image build_arm image_arm 

container: build image build_arm image_arm

build:
	CGO_ENABLED=0 go build -o docker/x86_64/nfs-client-provisioner ./cmd/nfs-client-provisioner

build_arm:
	CGO_ENABLED=0 GOARCH=arm GOARM=7 go build -o docker/arm/nfs-client-provisioner ./cmd/nfs-client-provisioner 
	
image:
	sudo docker build -t $(MUTABLE_IMAGE) docker/x86_64
	sudo docker tag $(MUTABLE_IMAGE) $(IMAGE)

image_arm:
	sudo docker run --rm --privileged multiarch/qemu-user-static:register --reset
	sudo docker build -t $(MUTABLE_IMAGE_ARM) docker/arm
	sudo docker tag $(MUTABLE_IMAGE_ARM) $(IMAGE_ARM)

push:
	docker push $(IMAGE)
	docker push $(MUTABLE_IMAGE)
	docker push $(IMAGE_ARM)
	docker push $(MUTABLE_IMAGE_ARM)
