#!/usr/bin/env python3
"""Extract the disk images tools/mkiosroot.sh needs from a local IPSW.

  ipsw-images.py IPSW OUTDIR       -> OUTDIR/{os.dmg,sysos.dmg,appos.dmg}, prints their paths

The member names are not fixed: they are looked up in BuildManifest.plist for the
D22AP (iPhone X) erase-install identity: Manifest "OS", "Cryptex1,SystemOS" and
"Cryptex1,AppOS". Reading is streamed (zipfile), nothing is held in RAM.
"""
import os, plistlib, shutil, sys, zipfile

WANT = {'os': ('OS',), 'sysos': ('Cryptex1,SystemOS',), 'appos': ('Cryptex1,AppOS',)}


def pick_identity(manifest, device_class='d22ap'):
    ids = [i for i in manifest['BuildIdentities']
           if i.get('Info', {}).get('DeviceClass', '').lower() == device_class]
    if not ids:
        raise SystemExit(f'BuildManifest has no {device_class} identity')
    for i in ids:  # prefer the full erase install
        if 'erase' in i.get('Info', {}).get('Variant', '').lower():
            return i
    return ids[0]


def member_paths(identity):
    man = identity['Manifest']
    out = {}
    for key, names in WANT.items():
        entry = next((man[n] for n in names if n in man), None)
        if entry is None:  # tolerate renamed cryptex keys
            frag = 'SystemOS' if key == 'sysos' else 'AppOS'
            entry = next((v for k, v in man.items() if k.startswith('Cryptex1,') and frag in k), None)
        if entry is None:
            raise SystemExit(f'no manifest entry for {key}; keys: {sorted(man)}')
        path = entry['Info']['Path']
        if path.endswith('.aea'):
            raise SystemExit(f'{path} is AEA-encrypted: this IPSW generation is not supported')
        out[key] = path
    return out


def main():
    ipsw, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    with zipfile.ZipFile(ipsw) as z:
        manifest = plistlib.loads(z.read('BuildManifest.plist'))
        paths = member_paths(pick_identity(manifest))
        for key, member in paths.items():
            dst = os.path.join(outdir, key + '.dmg')
            print(f'extracting {member} -> {dst}', file=sys.stderr, flush=True)
            with z.open(member) as src, open(dst, 'wb') as f:
                shutil.copyfileobj(src, f, 1 << 24)
            print(f'{key}={dst}')


if __name__ == '__main__':
    main()
