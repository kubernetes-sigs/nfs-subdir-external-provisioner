#!/bin/sh
CGO_ENABLED=0 go build ./cmd/nfs-client-provisioner #&& docker build -t quay.io/jackieli/nfs-client-provisioner .

