#!/bin/bash
# Build shim-boot.img (README step 3) from a CI kernel and the phone's stock DTB.
#
#   env: KERNEL          path to kernel.development.sweet (xnu workflow artifact)
#        IPSW_URL        Apple CDN URL (only DeviceTree.d22ap.im4p is fetched, via HTTP ranges)
#        OUT             output directory
#        CMDLINE_EXTRA   extra boot-args appended to the base command line
#        GPU_FIRMWARE    "true" = embed GMU/SQE/ZAP from device/firmware/gpu into the ADT and add GPU_BOOT_ARGS
#        GPU_BOOT_ARGS   boot-args for GPU rendering (default: sweetgpu=9 sweetmtl=2 sweetgles=0)
#        DEVICE_DIR      phone-specific files (default: device)
#
# Phone-specific input (see device/README.md): device/dtb  (or device/boot.img).
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${KERNEL:?}" "${IPSW_URL:?}"
OUT=${OUT:-out-boot}; DEVICE_DIR=${DEVICE_DIR:-device}; GPU_FIRMWARE=${GPU_FIRMWARE:-false}
CMDLINE_EXTRA=${CMDLINE_EXTRA:-}
mkdir -p "$OUT" shim/out research/ipsw-x/dt dtb/boot_unpacked

# Base command line = the one in README step 3 (the path that reaches the home screen).
BASE_CMDLINE='debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
GPU_BOOT_ARGS=${GPU_BOOT_ARGS:-sweetgpu=9 sweetmtl=2 sweetgles=0}
CMDLINE="$BASE_CMDLINE"
[ "$GPU_FIRMWARE" = true ] && CMDLINE="$CMDLINE $GPU_BOOT_ARGS"
CMDLINE="$CMDLINE${CMDLINE_EXTRA:+ $CMDLINE_EXTRA}"
# mkpayload silently truncates beyond 607 bytes (NOTES.md): fail instead
[ ${#CMDLINE} -le 600 ] || { echo "::error::boot-args are ${#CMDLINE} bytes, the payload holds 607"; exit 1; }

echo "::group::phone DTB"
if [ -f "$DEVICE_DIR/dtb" ]; then
	cp "$DEVICE_DIR/dtb" dtb/boot_unpacked/dtb
elif [ -f "$DEVICE_DIR/boot.img" ]; then
	python3 tools/unpack_bootv2.py "$DEVICE_DIR/boot.img" dtb/boot_unpacked
else
	echo "::error::No phone DTB. Upload device/dtb (or device/boot.img): see device/README.md"; exit 1
fi
magic=$(head -c4 dtb/boot_unpacked/dtb | xxd -p)
[ "$magic" = d00dfeed ] || { echo "::error::dtb does not start with the FDT magic (got $magic)"; exit 1; }
ls -l dtb/boot_unpacked/dtb
echo "::endgroup::"

echo "::group::iPhone X (D22AP) device tree from the IPSW (ranged download, a few MB)"
python3 tools/remotezip.py "$IPSW_URL" DeviceTree.d22ap.im4p research/ipsw-x/dt
im4p=$(find research/ipsw-x/dt -name 'DeviceTree.d22ap.im4p' | head -1)
[ -n "$im4p" ] || { echo "::error::DeviceTree.d22ap.im4p was not extracted"; exit 1; }
ipsw img4 im4p extract "$im4p" -o research/ipsw-x/d22ap.adt
ls -l research/ipsw-x/d22ap.adt
echo "::endgroup::"

echo "::group::ADT"
python3 tools/mkadt.py shim/out/sweet.adt --highmem
adt=shim/out/sweet.adt
fw_note="none"
if [ "$GPU_FIRMWARE" = true ]; then
	g="$DEVICE_DIR/firmware/gpu"
	for f in a618_gmu.bin a630_sqe.fw a615_zap.mdt; do
		[ -f "$g/$f" ] || { echo "::error::$g/$f is missing (collect it with tools/pull-sweet-firmware.py)"; exit 1; }
	done
	# ZAP code = the a615_zap.bNN file of exactly 0x7c0 bytes (sweet-adreno-firmware.py checks the size again)
	zap=$(find "$g" -name 'a615_zap.b[0-9][0-9]' -size -1985c -size +1983c | head -1)
	[ -n "$zap" ] || { echo "::error::no a615_zap.bNN of 1984 bytes in $g"; exit 1; }
	sha() { sha256sum "$1" | cut -d' ' -f1; }
	python3 tools/sweet-adreno-firmware.py shim/out/sweet.adt shim/out/sweet-fw.adt \
		"$g/a618_gmu.bin" --sha256 "$(sha "$g/a618_gmu.bin")" \
		--sqe-firmware "$g/a630_sqe.fw" --sqe-sha256 "$(sha "$g/a630_sqe.fw")" \
		--zap-metadata "$g/a615_zap.mdt" --zap-metadata-sha256 "$(sha "$g/a615_zap.mdt")" \
		--zap-code "$zap" --zap-code-sha256 "$(sha "$zap")"
	adt=shim/out/sweet-fw.adt
	fw_note="gpu(gmu,sqe,zap) -> $(basename "$zap")"
fi
echo "::endgroup::"

echo "::group::payload + shim + boot.img"
python3 tools/mkpayload.py "$KERNEL" "$adt" shim/out/payload.bin --cmdline "$CMDLINE"
bash shim/build.sh "$PWD/shim/out/payload.bin"
cp shim/out/shim-boot.img "$OUT/shim-boot.img"
echo "::endgroup::"

(cd "$OUT" && sha256sum shim-boot.img > SHA256SUMS)
python3 - "$OUT" "$KERNEL" "$CMDLINE" "$fw_note" <<'PY'
import hashlib, json, os, sys
out, kernel, cmdline, fw = sys.argv[1:5]
sha = lambda p: hashlib.sha256(open(p, 'rb').read()).hexdigest()
json.dump({'kernel_file': os.path.basename(kernel), 'kernel_sha256': sha(kernel),
           'boot_img_sha256': sha(os.path.join(out, 'shim-boot.img')),
           'cmdline': cmdline, 'firmware_in_adt': fw,
           'repo_commit': os.environ.get('GITHUB_SHA', ''),
           'kernel_run_id': os.environ.get('KERNEL_RUN_ID', '')},
          open(os.path.join(out, 'manifest.json'), 'w'), indent=2)
print(open(os.path.join(out, 'manifest.json')).read())
PY
ls -lh "$OUT"
