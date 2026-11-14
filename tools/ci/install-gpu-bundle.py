#!/usr/bin/env python3
"""Install the native-legacy SweetMetal2.bundle into a MOUNTED iOS root (offline, as root).

  sudo install-gpu-bundle.py MOUNTED_ROOT ARTIFACT_DIR

ARTIFACT_DIR is the `sweet-native-metal-ios16` artifact (native-legacy/SweetMetal2.bundle +
native-legacy/build.json). Every file is checked against build.json's SHA-256 list, the
executable must be an arm64 Mach-O, and an existing bundle is moved to
/private/var/db/sweet-metal2-orig.bundle first (rollback). Same target as
tools/sweet-install-metal2.sh: /System/Library/Extensions/SweetMetal2.bundle.
Kernel side: boot-args sweetmtl=2 sweetgles=0 (build.json: required_boot_args).
"""
import hashlib, json, os, shutil, struct, sys

root, art = os.path.realpath(sys.argv[1]), sys.argv[2]
src = os.path.join(art, 'native-legacy', 'SweetMetal2.bundle')
meta = json.load(open(os.path.join(art, 'native-legacy', 'build.json')))
if root == '/' or not os.path.isdir(os.path.join(root, 'System/Library/Extensions')):
    sys.exit('not a mounted iOS root: ' + root)
if meta.get('kernel_plugin') != 'SweetMetal2' or meta.get('kernel_class') != 'SweetMTL2Device':
    sys.exit('build.json is not the SweetMetal2 compatibility bundle')

sha = lambda p: hashlib.sha256(open(p, 'rb').read()).hexdigest()
files = []
for d, dirs, names in os.walk(src):
    for n in names:
        p = os.path.join(d, n)
        if os.path.islink(p):
            sys.exit('symlink in bundle: ' + p)
        files.append(os.path.relpath(p, src))
want = meta['files']
if set(files) != set(want):
    sys.exit(f'file list differs from build.json: {sorted(set(files) ^ set(want))}')
for rel in files:
    if sha(os.path.join(src, rel)) != want[rel]:
        sys.exit('SHA-256 mismatch: ' + rel)
head = open(os.path.join(src, 'SweetMetal2'), 'rb').read(8)
if struct.unpack('<II', head) != (0xfeedfacf, 0x0100000c):
    sys.exit('SweetMetal2 is not an arm64 Mach-O')

dst = os.path.join(root, 'System/Library/Extensions/SweetMetal2.bundle')
bak = os.path.join(root, 'private/var/db/sweet-metal2-orig.bundle')
for p in (dst, bak):
    if os.path.islink(p):
        sys.exit('refusing symlink: ' + p)
if os.path.exists(dst):
    if os.path.exists(bak):
        shutil.rmtree(bak)
    shutil.move(dst, bak)
    print('previous bundle saved to /private/var/db/sweet-metal2-orig.bundle')

def own(p, mode):
    os.chown(p, 0, 0); os.chmod(p, mode)

for d, dirs, names in os.walk(src):
    rel = os.path.relpath(d, src)
    out = dst if rel == '.' else os.path.join(dst, rel)
    os.makedirs(out, exist_ok=True); own(out, 0o755)
    for n in names:
        o = os.path.join(out, n)
        shutil.copyfile(os.path.join(d, n), o)
        exe = n == 'SweetMetal2' or n.endswith('.dylib')
        own(o, 0o755 if exe else 0o644)
for rel in files:  # read back
    assert sha(os.path.join(dst, rel)) == want[rel], 'readback mismatch ' + rel
print(f'installed {len(files)} files into /System/Library/Extensions/SweetMetal2.bundle '
      f'(source commit {meta.get("source_commit", "?")[:12]}); boot-args: {meta.get("required_boot_args")}')
