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

# Ubuntu's mkbootimg is broken: it imports the python module "gki", which the package does not
# ship (Debian #1050300, Launchpad #2058228). Only GKI certificate signing uses it: a stub is enough.
stub=/usr/local/lib/mkbootimg-gki-stub
sudo install -d "$stub/gki"
sudo touch "$stub/gki/__init__.py"
printf 'def generate_gki_certificate(*args, **kwargs):\n    raise SystemExit("GKI certificates are not supported by this stub")\n' |
	sudo tee "$stub/gki/generate_gki_certificate.py" >/dev/null
printf '#!/bin/sh\nPYTHONPATH=%s${PYTHONPATH:+:$PYTHONPATH} exec /usr/bin/mkbootimg "$@"\n' "$stub" |
	sudo tee /usr/local/bin/mkbootimg >/dev/null
sudo chmod 0755 /usr/local/bin/mkbootimg
hash -r
mkbootimg --help >/dev/null || { echo "::error::mkbootimg still does not start"; exit 1; }

# shim/build.sh uses strtonum() (gawk only; mawk is not enough)
awk 'BEGIN{ if (strtonum("0x10") != 16) exit 1 }' || { echo "::error::awk without strtonum"; exit 1; }
