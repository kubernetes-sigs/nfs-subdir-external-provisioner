# Comments are provided throughout this file to help you get started.
# If you need more help, visit the Dockerfile reference guide at
# https://docs.docker.com/go/dockerfile-reference/
# Want to help us make this template better? Share your feedback here: https://forms.gle/ybq9Krt8jtBL3iCk7
################################################################################
# Create a stage for building the application.
ARG GO_VERSION=1.26.3-alpine3.23
FROM golang:${GO_VERSION} AS builder

WORKDIR /workspace
# Copy the project
COPY . .

# This is the architecture you're building for, which is passed in by the builder.
# Placing it here allows the previous steps to be cached across architectures.
ARG TARGETOS
ARG VERSION
ARG GITCOMMIT
ARG BUILDDATE
ARG TARGETARCH
ARG GOPROXY="https://goproxy.cn,direct"

# Build
# the GOARCH has not a default value to allow the binary be built according to the host where the command
# was called. For example, if we call make docker-build in a local env which has the Apple Silicon M1 SO
# the docker BUILDPLATFORM arg will be linux/arm64 when for Apple x86 it will be linux/amd64. Therefore,
# by leaving it empty we can ensure that the container and binary shipped on it will have the same platform.
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build \
    -ldflags "-X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.Version=${VERSION} \
              -X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.GitCommit=${GITCOMMIT} \
              -X github.com/kubernetes-sigs/nfs-subdir-external-provisioner/version.BuildDate=${BUILDDATE}" -a -o nfs-subdir-external-provisioner cmd/nfs-subdir-external-provisioner/provisioner.go



# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static-debian13:latest

LABEL maintainers="Kubernetes Authors"
LABEL description="NFS subdir external provisioner"

COPY --from=builder /workspace/nfs-subdir-external-provisioner /nfs-subdir-external-provisioner
ENTRYPOINT ["/nfs-subdir-external-provisioner"]
