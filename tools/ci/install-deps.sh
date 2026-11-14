#!/bin/bash
# Ubuntu 24.04 (noble) packages for the image builds. hfsprogs, mkbootimg and
# android-sdk-libsparse-utils (img2simg) are in noble/universe.
set -euo pipefail
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
	hfsprogs mkbootimg android-sdk-libsparse-utils \
	gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gcc \
	gawk cpio gzip zstd rsync curl ca-certificates python3 jq xxd \
	fuse3 libfuse3-dev libbz2-dev libattr1-dev zlib1g-dev cmake g++ git make
# shim/build.sh uses strtonum() (gawk only; mawk is not enough)
awk 'BEGIN{ if (strtonum("0x10") != 16) exit 1 }' || { echo "::error::awk without strtonum"; exit 1; }
