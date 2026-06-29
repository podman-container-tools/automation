#!/usr/bin/env bash

set -eo pipefail

SOURCE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )


RAWHIDE_RELEASE=rawhide
FEDORA_CURRENT_RELEASE=44
PRIOR_FEDORA_RELEASE=43

CURL="curl --location --fail --show-error --retry 5"

function verify_fedora() {
    # verify the image download according to fedora docs here: https://fedoraproject.org/cloud/download/
    (
        cd "$SOURCE_DIR/download"
        if [[ "$FEDORA_RELEASE_VERSION" == "$RAWHIDE_RELEASE" ]]; then
            # Rawhide images ar not signed, just check checksums
            sha256sum -c --ignore-missing "$DOWNLOAD_CHECKSUM_FILE"
        else
            sq verify --cleartext --signer-file ../fedora.pgp "$DOWNLOAD_CHECKSUM_FILE"  | \
            sha256sum -c --ignore-missing
        fi
    )
}

function verify_debian() {
    # https://cloud.debian.org/images/cloud/
    # These are not signed so we can only match checksums.
    (
        cd "$SOURCE_DIR/download"
        sha512sum -c --ignore-missing "$DOWNLOAD_CHECKSUM_FILE"
    )
}

VM_CORES=${VM_CORES:-2}
VM_MEMORY=${VM_MEMORY:-2560}

BUILD_NAME="$1"
FEDORA_RELEASE_VERSION=""
ARCH="$(arch)"

case "$BUILD_NAME" in
    "fedora-current")
        FEDORA_RELEASE_VERSION="$FEDORA_CURRENT_RELEASE"
        ;;

    "fedora-prior")
        FEDORA_RELEASE_VERSION="$PRIOR_FEDORA_RELEASE"
        ;;

    "fedora-rawhide")
        FEDORA_RELEASE_VERSION="$RAWHIDE_RELEASE"
        ;;
    "debian-sid")
        ;;
    *)
        echo "Invalid image build name '$BUILD_NAME'" >&2;
        exit 1;
        ;;
esac


verify_function=""
install_script=""

# partition on the qemu disk images which we need to resize
ROOTFS_DISK_PARTITION=""

if [[ "$BUILD_NAME" =~ fedora ]]; then
    IMAGE_CHECKSUM_URL=$($SOURCE_DIR/get_fedora_url.sh checksum $ARCH $FEDORA_RELEASE_VERSION)
    IMAGE_URL=$($SOURCE_DIR/get_fedora_url.sh image $ARCH $FEDORA_RELEASE_VERSION)

    ROOTFS_DISK_PARTITION=/dev/sda3
    # FIXME remove this once upgrading stable to f45
    if [[ "$BUILD_NAME" =~ prior ]]; then
        ROOTFS_DISK_PARTITION=/dev/sda4
    fi

    verify_function=verify_fedora
    install_script=fedora_packaging.sh

elif [[ "$BUILD_NAME" == debian-sid ]]; then
    IMAGE_CHECKSUM_URL="https://cloud.debian.org/images/cloud/sid/daily/latest/SHA512SUMS"
    # debian uses amd64/arm64 instead of x86_64/aarch64
    deb_arch=""
    case "$ARCH" in
        "x86_64")
            deb_arch="amd64"
            ;;
        "aarch64")
            deb_arch="arm64"
            ;;
    esac
    IMAGE_URL=https://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-generic-${deb_arch}-daily.qcow2

    ROOTFS_DISK_PARTITION=/dev/sda1

    verify_function=verify_debian
    install_script=debian_packaging.sh
fi


DOWNLOAD_CHECKSUM_FILE=$(basename "$IMAGE_CHECKSUM_URL")
DOWNLOAD_IMAGE_NAME=$(basename "$IMAGE_URL")

mkdir -p "$SOURCE_DIR/download" "$SOURCE_DIR/output"

# Download the image and checksum files
$CURL --output-dir "$SOURCE_DIR/download" -O "$IMAGE_CHECKSUM_URL"
$CURL --output-dir "$SOURCE_DIR/download" -O "$IMAGE_URL"

image_name="$BUILD_NAME.$ARCH.qcow2"
image_path="$SOURCE_DIR/output/$image_name"

# verify our downloads
$verify_function

cp "$SOURCE_DIR/download/$DOWNLOAD_IMAGE_NAME" "$image_path"

# By default the partition is to small to install all packages, so we need to resize it.
resize_image_path="$SOURCE_DIR/output/$BUILD_NAME-resize.qcow2"
# Create new image file with 100GB, the default images are to small.
qemu-img create -f qcow2 "$resize_image_path" 100G

# Check the partition table with this command if the resize command errors
# virt-filesystems --long -h --all -a "$image_path"
virt-resize --expand "$ROOTFS_DISK_PARTITION" "$image_path" "$resize_image_path"

# Move the resized copy over the old name to not have two images around.
mv "$resize_image_path" "$image_path"

## TEMP workaround build netavark v2 until that land in the real images.
nv_checkout=$(mktemp -d --tmpdir=/var/tmp netavark.XXXXXX)
trap "rm -rf $nv_checkout" EXIT
git clone https://github.com/containers/netavark/ "$nv_checkout"

(
    cd "$nv_checkout"
    make build
)

# Upload and run our install script in the guest.
virt-customize --smp ${VM_CORES} --memsize ${VM_MEMORY} \
    --upload "$SOURCE_DIR/$install_script:/tmp/install.sh" \
    --mkdir /var/cache/local-registry \
    --upload "$SOURCE_DIR/local-cache-registry:/var/cache/local-registry/local-cache-registry" \
    --mkdir /usr/local/libexec/podman \
    --upload "$nv_checkout/bin/netavark:/usr/local/libexec/podman/netavark" \
    --run-command "chmod +x /usr/local/libexec/podman/netavark" \
    --run-command "chmod +x /tmp/install.sh && /tmp/install.sh $BUILD_NAME" \
    --run-command "mount -t cgroup2 none /sys/fs/cgroup && chmod +x /var/cache/local-registry/local-cache-registry && /var/cache/local-registry/local-cache-registry initialize" \
    -a "$image_path"

# virt-customize logs all output to /tmp/builder.log
echo "Build logs:"
virt-cat -a "$image_path" /tmp/builder.log

echo "Compressing the image with zstd"
# zst compress to safe space
zstd -19 -T0 $image_path $image_path.zst

echo "Successful build $image_name.zst"
