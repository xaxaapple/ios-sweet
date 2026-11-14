#!/bin/bash
# Fast self-test (a few minutes) of everything the long builds need: tools,
# FUSE, loop-mounting a case-sensitive HFS+ image, the mkbootimg flags used by
# shim/build.sh. Fails early with a readable message instead of after an hour.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }

for t in aarch64-linux-gnu-gcc aarch64-linux-gnu-objcopy mkbootimg img2simg mkfs.hfsplus \
         fsck.hfsplus zstd rsync cmake g++ git jq curl; do
	command -v "$t" >/dev/null || fail "missing tool: $t"
done
[ -e /dev/fuse ] || fail "/dev/fuse is missing: apfs-fuse cannot run on this runner"

# hfsplus kernel module (Azure kernels may keep it in the -extra package)
if ! grep -qw hfsplus /proc/filesystems; then sudo modprobe hfsplus 2>/dev/null || true; fi
if ! grep -qw hfsplus /proc/filesystems; then
	sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)" || true
	sudo modprobe hfsplus || true
fi
grep -qw hfsplus /proc/filesystems || fail "this runner kernel ($(uname -r)) has no hfsplus module"

t=$(mktemp -d)
trap 'sudo umount "$t/m" 2>/dev/null || true; rm -rf "$t"' EXIT
truncate -s 64M "$t/t.img"
mkfs.hfsplus -s -J -v preflight "$t/t.img" >/dev/null
mkdir "$t/m"
sudo mount -t hfsplus -o loop,force "$t/t.img" "$t/m"
echo ok | sudo tee "$t/m/probe" >/dev/null
sudo ln "$t/m/probe" "$t/m/probe-link"
sudo umount "$t/m"
fsck.hfsplus -f -y "$t/t.img" >/dev/null
echo "HFS+ loop mount, hard link and fsck: OK"

# same flags as shim/build.sh
head -c 4096 /dev/urandom > "$t/k"; head -c 4096 /dev/urandom > "$t/r"; head -c 4096 /dev/urandom > "$t/d"
mkbootimg --header_version 2 --kernel "$t/k" --ramdisk "$t/r" --dtb "$t/d" --base 0 \
	--kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 --dtb_offset 0x1f00000 \
	--pagesize 4096 --os_version 17.0.0 --os_patch_level 2035-06 --cmdline "console=null" -o "$t/b.img"
echo "mkbootimg flags: OK"
truncate -s 8M "$t/raw.img"; img2simg "$t/raw.img" "$t/raw.simg"; echo "img2simg: OK"
echo "Preflight passed on kernel $(uname -r)"
