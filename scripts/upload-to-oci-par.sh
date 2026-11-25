#!/usr/bin/env bash

set -euo pipefail

: "${OCI_PAR_URL:?OCI_PAR_URL is required}"
: "${VERSION:?VERSION is required}"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <file> [<file>...]" >&2
    exit 1
fi

for f in "$@"; do
    base="$(basename "$f")"
    target="${OCI_PAR_URL%/}/releases/${VERSION}/${base}"
    echo "PUT $f -> releases/${VERSION}/${base}"
    curl --fail -sS --retry 5 --retry-all-errors \
        -H 'Content-Type: application/octet-stream' \
        --upload-file "$f" \
        "$target"
done

echo "Uploaded $# artifact(s) to releases/${VERSION}/"
