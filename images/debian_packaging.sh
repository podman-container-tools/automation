#!/bin/bash

# This script is called from debian_setup.sh and various Dockerfiles.
# It's not intended to be used outside of those contexts.  It assumes the lib.sh
# library has already been sourced, and that all "ground-up" package-related activity
# needs to be done, including repository setup and initial update.

set -e

OS_RELEASE_VER="$(source /etc/os-release; echo $VERSION_ID | tr -d '.')"
OS_RELEASE_ID="$(source /etc/os-release; echo $ID)"
OS_REL_VER="$OS_RELEASE_ID-$OS_RELEASE_VER"

BUILD_NAME="${1:?Build name is not defined, must be given as first arg}"

# ensure we get no prompts
export DEBIAN_FRONTEND=noninteractive

# This location is checked by automation in buildah, please do not change.
PACKAGE_DOWNLOAD_DIR=/var/cache/download

echo "Updating/Installing repos and packages for $OS_REL_VER"
apt-get -q -y update
apt-get -q -y upgrade

INSTALL_PACKAGES=(\
    apache2-utils
    apparmor
    apt-transport-https
    autoconf
    automake
    bash-completion
    bats
    bison
    btrfs-progs
    build-essential
    buildah
    bzip2
    ca-certificates
    catatonit
    conmon
    containernetworking-plugins
    criu
    crun
    dnsmasq
    e2fslibs-dev
    file
    fuse3
    fuse-overlayfs
    gcc
    gettext
    git
    gnupg2
    go-md2man
    golang
    iproute2
    iptables
    jq
    libaio-dev
    libapparmor-dev
    libbtrfs-dev
    libcap-dev
    libcap2
    libdevmapper-dev
    libdevmapper1.02.1
    libfuse-dev
    libfuse3-dev
    libglib2.0-dev
    libgpgme11-dev
    liblzma-dev
    libnl-3-dev
    libostree-dev
    libprotobuf-c-dev
    libprotobuf-dev
    libseccomp-dev
    libseccomp2
    libselinux-dev
    libsystemd-dev
    libtool
    libudev-dev
    lsb-release
    lsof
    make
    ncat
    openssl
    parallel
    passt
    patch
    pkg-config
    podman
    protobuf-c-compiler
    protobuf-compiler
    protoc-gen-go
    protoc-gen-go-grpc
    python-is-python3
    python3-dateutil
    python3-dateutil
    python3-docker
    python3-pip
    python3-protobuf
    python3-psutil
    python3-toml
    python3-tomli
    python3-requests
    python3-setuptools
    rsync
    runc
    scons
    sq
    skopeo
    slirp4netns
    socat
    libsqlite3-0
    libsqlite3-dev
    systemd-container
    sudo
    time
    unzip
    util-linux-extra
    vim
    wget
    xfsprogs
    xz-utils
    zip
    zlib1g-dev
    zstd
)

# bpftrace is only needed on the host as containers cannot run ebpf
# programs anyway and it is very big so we should not bloat the container
# images unnecessarily.
if ! ((CONTAINER)); then
    INSTALL_PACKAGES+=( \
        bpftrace
    )
fi

echo "Installing general build/testing dependencies"
apt-get -q -y install "${INSTALL_PACKAGES[@]}"

# The nc installed by default is missing many required options
update-alternatives --set nc /usr/bin/ncat

# Buildah conformance testing needs to install packages from docker.io
# at runtime.  Setup the repo here, so it only affects downloaded
# (cached) packages and not updates/installs (above).  Installing packages
# cached in the image is preferable to reaching out to the repository
# at runtime.  It also has the desirable effect of preventing the
# possibility of package changes from one CI run to the next (or from
# one branch to the next).
DOWNLOAD_PACKAGES=(\
    containerd.io
    docker-ce
    docker-ce-cli
)

curl --fail --silent --location \
    --url  https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor | \
    tee /etc/apt/trusted.gpg.d/docker_com.gpg &> /dev/null

# Buildah CI does conformance testing vs the most recent Docker version.
#  As of 05-2026, there is no 'forky' dist for docker. Fix the next lines once that changes.
#docker_debian_release=$(source /etc/os-release; echo "$VERSION_CODENAME")
docker_debian_release="trixie"

echo "deb https://download.docker.com/linux/debian $docker_debian_release stable" | \
    tee /etc/apt/sources.list.d/docker.list &> /dev/null

if ((CONTAINER==0)) && [[ ${#DOWNLOAD_PACKAGES[@]} -gt 0 ]]; then
    apt-get clean  # no reason to keep previous downloads around
    # Needed to install .deb files + resolve dependencies
    apt-get -q -y update
    echo "Downloading packages for optional installation at runtime."
    ln -s /var/cache/apt/archives "$PACKAGE_DOWNLOAD_DIR"
    apt-get -q -y install --download-only "${DOWNLOAD_PACKAGES[@]}"
fi

# Generate en_US.UTF-8 locale as this is required for a podman test (https://github.com/containers/podman/pull/19635).
sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
locale-gen

# Debian doesn't mount tmpfs on /tmp as default but we want this to speed tests up so
# they don't have to write to persistent disk.
# https://github.com/containers/podman/pull/22533
mkdir -p /etc/systemd/system/local-fs.target.wants/
cat <<EOF | tee /etc/systemd/system/tmp.mount
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=size=75%%,mode=1777
EOF
# enable the unit by default
ln -s ../tmp.mount /etc/systemd/system/local-fs.target.wants/tmp.mount


# dnsmasq is set to bind 0.0.0.0:53, that will conflict with our dns tests.
# We don't need a local resolver.
systemctl disable dnsmasq.service
systemctl mask dnsmasq.service
