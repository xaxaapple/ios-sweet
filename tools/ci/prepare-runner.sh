#!/bin/bash
# Prepare a GitHub-hosted Ubuntu runner for the image builds:
#  - frees disk space only when it is really needed,
#  - picks the volume (/ or /mnt) with the most free space as the work directory,
#  - exports WORK=<dir> to the following steps (GITHUB_ENV).
#
#   tools/ci/prepare-runner.sh [NEED_GB]     (default 60)
set -euo pipefail
need_gb=${1:-60}
avail_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
mnt_ok=0; if [ -d /mnt ] && mountpoint -q /mnt; then mnt_ok=1; fi

echo "::group::disk before"; df -h / $([ "$mnt_ok" = 1 ] && echo /mnt); echo "::endgroup::"

best_free() {
	local a b
	a=$(avail_gb /); b=0
	[ "$mnt_ok" = 1 ] && b=$(avail_gb /mnt)
	[ "$a" -ge "$b" ] && echo "$a" || echo "$b"
}

if [ "$(best_free)" -lt "$need_gb" ]; then
	echo "Less than ${need_gb} GB free: removing preinstalled toolchains this job does not use"
	sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
		/opt/hostedtoolcache/CodeQL /usr/local/share/boost || true
	sudo apt-get clean || true
fi

root_free=$(avail_gb /); mnt_free=0
[ "$mnt_ok" = 1 ] && mnt_free=$(avail_gb /mnt)
if [ "$mnt_free" -gt "$root_free" ]; then work=/mnt/work-images; free=$mnt_free
else work=/home/runner/work-images; free=$root_free; fi

echo "::group::disk after"; df -h / $([ "$mnt_ok" = 1 ] && echo /mnt); echo "::endgroup::"
if [ "$free" -lt "$need_gb" ]; then
	echo "::error::Only ${free} GB free on the best volume, ${need_gb} GB needed. Use a larger runner (runner input)."
	exit 1
fi
sudo mkdir -p "$work"
sudo chown "$(id -u):$(id -g)" "$work"
echo "WORK=$work" >> "${GITHUB_ENV:-/dev/null}"
echo "Work directory: $work (${free} GB free)"
