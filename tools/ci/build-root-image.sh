#!/bin/bash
# Build the iOS root image for `fastboot flash userdata` (README step 2) on an Ubuntu runner.
#
#   env: WORK        work directory with plenty of free space
#        IPSW_URL, IPSW_SHA256
#        ROOT_SIZE   size of the HFS+ volume (default 16G)
#        OUT         output directory (default $WORK/out-root)
#        GPU_BUNDLE_DIR  optional: sweet-native-metal-ios16 artifact dir -> SweetMetal2.bundle goes into the root
#
# Result: $OUT/ios16-root.simg.zst.part-NN (+ SHA256SUMS, RESTORE.txt). The sparse image
# is compressed and cut into 1900 MB parts so it fits GitHub's artifact limits.
set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD
: "${WORK:?}" "${IPSW_URL:?}" "${IPSW_SHA256:?}"
ROOT_SIZE=${ROOT_SIZE:-16G}
OUT=${OUT:-$WORK/out-root}
mkdir -p "$OUT" "$WORK/ipsw"

echo "::group::download IPSW"
ipsw="$WORK/ipsw/restore.ipsw"
curl -fL --retry 8 --retry-delay 15 --retry-all-errors -C - -o "$ipsw" "$IPSW_URL"
echo "$IPSW_SHA256  $ipsw" | sha256sum -c -
echo "::endgroup::"

echo "::group::extract OS / SystemOS / AppOS"
python3 tools/ci/ipsw-images.py "$ipsw" "$WORK/ipsw" | tee "$WORK/ipsw/paths.env"
rm -f "$ipsw"   # the 5.7 GB zip is not needed any more
echo "::endgroup::"

echo "::group::APFS reader with LZBITMAP support (apfs-fuse, pinned revision)"
JOBS=$(nproc) bash tools/build-apfs-reader.sh
echo "::endgroup::"
export APFS_FUSE="$repo/research/apfs-fuse-current/build/apfs-fuse"
test -x "$APFS_FUSE"

img="$WORK/ios16-root.img"
echo "::group::mkiosroot.sh (OS + cryptexes -> one HFS+ volume)"
bash tools/mkiosroot.sh "$WORK/ipsw/os.dmg" "$WORK/ipsw/sysos.dmg" "$WORK/ipsw/appos.dmg" "$img" "$ROOT_SIZE"
rm -f "$WORK"/ipsw/*.dmg
echo "::endgroup::"

echo "::group::sweet-root-tweaks.py"
sudo fsck.hfsplus -f -y "$img"
mnt="$WORK/iosroot"; mkdir -p "$mnt"
sudo mount -t hfsplus -o loop,force "$img" "$mnt"
trap 'sudo umount "$mnt" 2>/dev/null || true' EXIT
sudo python3 tools/sweet-root-tweaks.py "$mnt"
if [ -n "${GPU_BUNDLE_DIR:-}" ]; then
	echo "installing the native Metal bundle from $GPU_BUNDLE_DIR"
	sudo python3 tools/ci/install-gpu-bundle.py "$mnt" "$GPU_BUNDLE_DIR"
	sudo bash tools/prepare-sweet-metal2-cache.sh "$mnt" || echo "warning: BackBoard cache dir not provisioned (not needed by the native frontend)"
fi
# sanity checks on the result before it is packaged
sudo python3 - "$mnt" <<'PY'
import os, plistlib, sys
root = sys.argv[1]
v = plistlib.load(open(os.path.join(root, 'System/Library/CoreServices/SystemVersion.plist'), 'rb'))
print('SystemVersion:', v['ProductVersion'], v['ProductBuildVersion'])
assert (v['ProductVersion'], v['ProductBuildVersion']) == ('16.7.16', '20H392'), 'unexpected iOS build'
for rel in ('System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64',
            'private/var/keybags/systembag.kb', 'sbin/launchd'):
    assert os.path.exists(os.path.join(root, rel)), 'missing in image: ' + rel
print('root sanity checks passed')
PY
df -h "$mnt"
sudo umount "$mnt"; trap - EXIT
echo "::endgroup::"

echo "::group::sparse image + compression"
img2simg "$img" "$WORK/ios16-root.simg"
rm -f "$img"
ls -l "$WORK/ios16-root.simg"
(cd "$OUT" && sha256sum "$WORK/ios16-root.simg" | sed "s#$WORK/##" > ios16-root.simg.sha256)
zstd -T0 -5 -q --rm "$WORK/ios16-root.simg" -o "$WORK/ios16-root.simg.zst"
split -b 1900M -d -a 2 "$WORK/ios16-root.simg.zst" "$OUT/ios16-root.simg.zst.part-"
rm -f "$WORK/ios16-root.simg.zst"
(cd "$OUT" && sha256sum ios16-root.simg.zst.part-* > SHA256SUMS)
cat > "$OUT/RESTORE.txt" <<'TXT'
cat ios16-root.simg.zst.part-* | zstd -d > ios16-root.simg
sha256sum -c ios16-root.simg.sha256          # compare with the file in this folder
fastboot -S 512M flash userdata ios16-root.simg      # ~7 min, do not unplug; ERASES Android userdata
TXT
ls -lh "$OUT"
echo "::endgroup::"
