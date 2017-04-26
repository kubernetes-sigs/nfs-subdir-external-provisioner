FROM alpine:3.5
RUN apk update --no-cache && apk add ca-certificates
COPY nfs-client-provisioner /nfs-client-provisioner
ENTRYPOINT ["/nfs-client-provisioner"]