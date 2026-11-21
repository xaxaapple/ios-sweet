#!/bin/bash
# Pack a directory into a split 7z archive and upload every part to Gofile.
#
#   pack-and-upload.sh NAME INPUT_DIR PART_SIZE
#
#   NAME       archive name without extension (parts: NAME.7z.001, NAME.7z.002, ...)
#   INPUT_DIR  everything in this directory goes into the archive
#   PART_SIZE  size of one part in 7-Zip syntax: 500m, 1g, 1900m (suffix b, k, m or g)
#
# Gofile API (docs: https://gofile.io/api, checked 2026-11): POST https://upload.gofile.io/uploadfile,
# multipart field "file". The first upload without a token creates a guest account and a public folder
# and returns data.guestToken, data.parentFolder and data.downloadPage; the next parts are sent with
# "Authorization: Bearer <token>" and folderId=<parentFolder> so that all parts land in one folder.
# Set the optional repository secret GOFILE_TOKEN to upload into your own Gofile account instead.
#
# Output: $RUNNER_TEMP/gofile-out/NAME/ keeps the archive parts (a workflow can use them as a
# fallback when the upload fails); the download page is written to the step summary and to
# $GITHUB_OUTPUT as "page".
set -euo pipefail

NAME=${1:?archive name}
SRC=${2:?input directory}
PART=${3:?part size}
UPLOAD_URL=${GOFILE_UPLOAD_URL:-https://upload.gofile.io/uploadfile}
TOKEN=${GOFILE_TOKEN:-}
FOLDER=""
PAGE=""

[[ "$PART" =~ ^[0-9]+[bBkKmMgG]$ ]] || {
	echo "::error::part_size '$PART' is not valid: use a number and b, k, m or g (for example 500m or 1g)"
	exit 1
}
[ -d "$SRC" ] && [ -n "$(ls -A "$SRC")" ] || { echo "::error::$SRC is missing or empty"; exit 1; }
[ -z "$TOKEN" ] || echo "::add-mask::$TOKEN"

if ! command -v 7z >/dev/null; then
	sudo apt-get update -qq
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends p7zip-full
fi
command -v jq >/dev/null || sudo apt-get install -y -qq --no-install-recommends jq

TMP=${RUNNER_TEMP:-/tmp}
OUT="$TMP/gofile-out/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "::group::7z a -v$PART $NAME"
(cd "$SRC" && 7z a -t7z -mx=1 -mmt=on -v"$PART" -bso0 -bsp0 "$OUT/$NAME.7z" ./*)
(cd "$OUT" && sha256sum "$NAME".7z* > "$NAME.parts.sha256")
ls -l "$OUT"
echo "::endgroup::"

upload_file() { # upload_file PATH
	local f=$1 want got try resp status
	resp=$(mktemp)
	want=$(md5sum "$f" | cut -d' ' -f1)
	for try in 1 2 3 4 5; do
		local args=(-sS --connect-timeout 30 -X POST "$UPLOAD_URL" -F "file=@$f" -o "$resp")
		[ -z "$TOKEN" ] || args+=(-H "Authorization: Bearer $TOKEN")
		[ -z "$FOLDER" ] || args+=(-F "folderId=$FOLDER")
		curl "${args[@]}" || true
		status=$(jq -r '.status // "none"' "$resp" 2>/dev/null || echo none)
		if [ "$status" = ok ]; then
			got=$(jq -r '.data.md5 // empty' "$resp")
			if [ -z "$got" ] || [ "$got" = "$want" ]; then
				if [ -z "$TOKEN" ]; then
					TOKEN=$(jq -r '.data.guestToken // empty' "$resp")
					[ -z "$TOKEN" ] || echo "::add-mask::$TOKEN"
				fi
				[ -n "$FOLDER" ] || FOLDER=$(jq -r '.data.parentFolder // empty' "$resp")
				[ -n "$PAGE" ] || PAGE=$(jq -r '.data.downloadPage // empty' "$resp")
				rm -f "$resp"
				return 0
			fi
			echo "md5 mismatch for $(basename "$f") (local $want, Gofile $got), attempt $try"
		else
			echo "upload of $(basename "$f") failed (status: $status), attempt $try: $(head -c 300 "$resp" 2>/dev/null)"
		fi
		sleep $((try * 20))
	done
	rm -f "$resp"
	return 1
}

echo "::group::upload to Gofile"
n=0
for f in "$OUT"/*; do
	echo "uploading $(basename "$f") ($(du -h "$f" | cut -f1))"
	upload_file "$f" || { echo "::error::Gofile upload failed for $(basename "$f")"; exit 1; }
	n=$((n + 1))
done
echo "::endgroup::"

[ -n "$PAGE" ] || { echo "::error::Gofile did not return a download page"; exit 1; }
echo "Uploaded $n files: $PAGE"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "page=$PAGE" >> "$GITHUB_OUTPUT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### $NAME on Gofile"
		echo
		echo "**Download page: $PAGE**"
		echo
		echo "$n files (archive parts $NAME.7z.001, .002, ... and checksums). Download ALL parts into one folder,"
		echo "then open the .001 file with 7-Zip (ZArchiver on Android): it joins the parts itself."
		echo
		echo '```'
		(cd "$OUT" && cat "$NAME.parts.sha256")
		echo '```'
	} >> "$GITHUB_STEP_SUMMARY"
fi
