#!/usr/bin/env bash
# Prepare a GitHub-hosted Ubuntu runner for rootless podman testing.
set -ex
podman --version
# restricted mode needs netavark + aardvark-dns (container-name DNS on internal networks)
if [ "$(podman info --format '{{.Host.NetworkBackend}}')" != "netavark" ]; then
  sudo apt-get update -q
  sudo apt-get install -y -q netavark aardvark-dns
  podman system reset -f
fi
podman info --format 'rootless={{.Host.Security.Rootless}} backend={{.Host.NetworkBackend}} cgroups={{.Host.CgroupsVersion}} controllers={{.Host.CgroupControllers}}'
grep "^$(id -un):" /etc/subuid /etc/subgid
podman run --rm docker.io/library/busybox:latest id
