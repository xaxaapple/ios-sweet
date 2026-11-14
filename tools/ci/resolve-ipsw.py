#!/usr/bin/env python3
"""Find the iPhone X IPSW the root image is built from.

The iOS build/version come from tools/sweet-root-tweaks.py (BUILD, VERSION), so the
root image and its tweaks can never disagree. The URL and checksum come from the
ipsw.me API (https://api.ipsw.me/v4/device/iPhone10,3?type=ipsw), which lists Apple's CDN
URL, SHA-256 and size of every build. If the API is unreachable, the pinned values for
20H392 below are used (taken from ipsw.me, 2026-11).

  resolve-ipsw.py [--url URL --sha256 HEX]     prints key=value lines (and appends to $GITHUB_OUTPUT)
"""
import argparse, json, os, re, sys, urllib.request

DEVICE = 'iPhone10,3'
PINNED = {  # build -> (file name, sha256); same file serves iPhone10,3 and iPhone10,6
    '20H392': ('iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw',
               'ece1194f7e233e9109c5790a8d23a4564a10a254e15ec5b09978a343265568fb'),
}


def wanted_build():
    here = os.path.dirname(os.path.abspath(__file__))
    text = open(os.path.join(here, '..', 'sweet-root-tweaks.py')).read()
    m = re.search(r"^BUILD, VERSION = '([0-9A-Z]+)', '([0-9.]+)'", text, re.M)
    if not m:
        sys.exit('cannot find BUILD, VERSION in tools/sweet-root-tweaks.py')
    return m.group(1), m.group(2)


def from_api(build):
    req = urllib.request.Request(f'https://api.ipsw.me/v4/device/{DEVICE}?type=ipsw',
                                 headers={'User-Agent': 'ios-sweet-ci'})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    for fw in data.get('firmwares', []):
        if fw.get('buildid') == build:
            return fw
    sys.exit(f'ipsw.me has no {DEVICE} firmware with build {build}')


def pick(firmwares, build):
    """Pure helper (unit-testable): the entry for BUILD from a firmwares list."""
    for fw in firmwares:
        if fw.get('buildid') == build:
            return fw
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url'); ap.add_argument('--sha256')
    a = ap.parse_args()
    build, version = wanted_build()
    url, sha, size, signed = a.url, (a.sha256 or '').lower(), '', ''
    if not url:
        try:
            fw = from_api(build)
            url = fw['url']; sha = (fw.get('sha256sum') or '').lower()
            size = fw.get('filesize', ''); signed = fw.get('signed', '')
        except Exception as e:  # network or API shape problem: fall back to the pin
            print(f'warning: ipsw.me API failed ({e}); using pinned values', file=sys.stderr)
            if build not in PINNED:
                sys.exit(f'no pinned IPSW for build {build}; pass --url and --sha256')
            url = f'https://api.ipsw.me/v4/ipsw/download/{DEVICE}/{build}'
    if not sha and build in PINNED:
        sha = PINNED[build][1]
    if not re.fullmatch(r'[0-9a-f]{64}', sha):
        sys.exit('no SHA-256 for the IPSW: refusing to build from an unverified download')
    if build in PINNED and sha != PINNED[build][1]:
        print(f'warning: API checksum differs from the pinned one for {build}', file=sys.stderr)
    out = {'url': url, 'sha256': sha, 'build': build, 'version': version,
           'size': size, 'signed': signed}
    for k, v in out.items():
        print(f'{k}={v}')
    gh = os.environ.get('GITHUB_OUTPUT')
    if gh:
        with open(gh, 'a') as f:
            for k, v in out.items():
                f.write(f'{k}={v}\n')


if __name__ == '__main__':
    main()
