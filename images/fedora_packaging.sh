#!/bin/bash

# This script is called from fedora_setup.sh and various Dockerfiles.
# It's not intended to be used outside of those contexts.  It assumes the lib.sh
# library has already been sourced, and that all "ground-up" package-related activity
# needs to be done, including repository setup and initial update.

set -e

OS_RELEASE_VER="$(source /etc/os-release; echo $VERSION_ID | tr -d '.')"
OS_RELEASE_ID="$(source /etc/os-release; echo $ID)"
OS_REL_VER="$OS_RELEASE_ID-$OS_RELEASE_VER"

BUILD_NAME="${1:?Build name is not defined, must be given as first arg}"


# Only enable updates-testing on all 'current stable Fedora, i.e. not
# rawhide  or N-1. Historically there have been many
# problems with non-uniform behavior when both supported Fedora releases
# receive container-related dependency updates at the same time.  Since
# the 'prior' release has the shortest support lifetime, keep it's behavior
# stable by only using released updates.
# shellcheck disable=SC2154
if [[ "$BUILD_NAME" == "fedora-current" ]]; then
    echo "Enabling updates-testing repository for $BUILD_NAME"
    dnf install -y 'dnf-command(config-manager)'
    dnf config-manager setopt updates-testing.enabled=1
else
    echo "NOT enabling updates-testing repository for $BUILD_NAME"
fi

echo "Updating/Installing repos and packages for $OS_REL_VER"

dnf update -y

INSTALL_PACKAGES=(\
    autoconf
    automake
    bash-completion
    bats
    btrfs-progs-devel
    buildah
    bzip2
    catatonit
    conmon
    containers-common
    criu
    crun
    crun-wasm
    curl
    device-mapper-devel
    dnsmasq
    docker-distribution
    e2fsprogs-devel
    emacs-nox
    fakeroot
    file
    findutils
    fuse3
    fuse3-devel
    gcc
    gh
    git
    git-daemon
    glib2-devel
    glibc-devel
    glibc-langpack-en
    glibc-static
    gnupg
    go-md2man
    golang
    golang-google-protobuf
    gpgme
    gpgme-devel
    hostname
    httpd-tools
    iproute
    jq
    koji
    krb5-workstation
    libassuan
    libassuan-devel
    libblkid-devel
    libcap-devel
    libffi-devel
    libgpg-error-devel
    libkrunfw
    libkrunfw-sev
    libmsi1
    libnet
    libnet-devel
    libnl3-devel
    libseccomp
    libseccomp-devel
    libselinux-devel
    libtool
    libxml2-devel
    libxslt-devel
    lsof
    make
    man-db
    msitools
    nfs-utils
    nmap-ncat
    openssl
    openssl-devel
    ostree-devel
    pandoc
    parallel
    passt
    patch
    perl-Clone
    perl-FindBin
    pigz
    pkgconfig
    podman
    podman-remote
    podman-sequoia
    pre-commit
    procps-ng
    protobuf
    protobuf-c
    python3-fedora-distro-aliases
    python3-koji-cli-plugins
    redhat-rpm-config
    rpcbind
    rsync
    runc
    sed
    sequoia-sq
    ShellCheck
    skopeo
    socat
    sqlite-libs
    sqlite-devel
    squashfs-tools
    tar
    time
    unzip
    vim
    wget
    which
    xz
    zip
    zlib-devel
    zstd
)

# Rawhide images don't need these packages
if [[ "$BUILD_NAME" != "fedora-rawhide" ]]; then
    INSTALL_PACKAGES+=( \
        python-pip-wheel
        python-setuptools-wheel
        python3-wheel
        python3-PyYAML
        python3-coverage
        python3-dateutil
        python3-devel
        python3-docker
        python3-fixtures
        python3-libselinux
        python3-libsemanage
        python3-libvirt
        python3-pip
        python3-psutil
        python3-pylint
        python3-pyxdg
        python3-requests
        python3-requests-mock
    )

    if ! ((CONTAINER)); then
        # Extra packages needed by podman-machine-os
        INSTALL_PACKAGES+=( \
            podman-machine
            osbuild
            osbuild-tools
            osbuild-ostree
            xfsprogs
            e2fsprogs
        )
    fi
fi

# When installing during a container-build, having this present
# will seriously screw up future dnf operations in very non-obvious ways.
# bpftrace is only needed on the host as containers cannot run ebpf
# programs anyway and it is very big so we should not bloat the container
# images unnecessarily.
if ! ((CONTAINER)); then
    INSTALL_PACKAGES+=( \
        bpftrace
        composefs
        container-selinux
        fuse-overlayfs
        libguestfs-tools
        selinux-policy-devel
        policycoreutils
    )
fi


echo "Installing general build/test dependencies"
dnf install -y "${INSTALL_PACKAGES[@]}"

# Occasionally following an install, there are more updates available.
# This may be due to activation of suggested/recommended dependency resolution.
dnf update -y

if ! ((CONTAINER)); then
    # Make /tmp tmpfs bigger, by default we only get 50%. Bump it to 75% so the tests have more storage.
    # Do not use 100% so we do not run out of memory for the process itself if tests start leaking big
    # files on /tmp.
    mkdir -p /etc/systemd/system/tmp.mount.d
    echo -e "[Mount]\nOptions=size=75%%,mode=1777\n" | $SUDO tee /etc/systemd/system/tmp.mount.d/override.conf

    # "Enabling cgroup management from containers"
    setsebool -P container_manage_cgroup true
fi
