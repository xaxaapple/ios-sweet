#!/usr/bin/env python3
"""Name the frames of the kernel sampler's "SMP" lines (sweetsample, patch 0054).

    smp-symbolicate.py CACHE-DIR TEXT [--bin NAME=MACHO ...] [--disasm DISASM-TOOL]

CACHE-DIR  holds dyld_shared_cache_arm64 (image table) and dyld_shared_cache_arm64.symbols (local
           symbols), both from the IPSW's SystemOS cryptex.
TEXT       the sampler lines pasted together, lines joined with ';' (a workflow input is one line),
           for example:  SMP backboardd[56] slide 0x18100000 mh 0x104b54000;SMP backboardd t8 pc ... bt ...
--bin      a process's main executable from the IPSW root (NAME as printed by the sampler), so that
           frames inside it get a disassembly window around the call (llvm-objdump).

Shared-cache frames become  Image`symbol + delta; frames in the process's own executable stay
"NAME+0xOFFSET" and, with --bin, are followed by the disassembly around the call site.
"""
import bisect
import importlib.util
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('dscsym', os.path.join(HERE, '..', 'dsc-symbolicate.py'))
dscsym = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dscsym)

HEX = re.compile(r'0x[0-9a-fA-F]+')


def parse(text):
    """[(process name, pid, slide, mh, [(thread, [addresses])])] in input order.

    The log may glue several "SMP ..." records into one physical line (and cut the address at the
    seam), so the text is split at every "SMP " and an address with no space before the next
    record is dropped as possibly cut off."""
    procs, cur = [], None
    text = text.replace(';', ' ').replace('\n', ' ')
    for rec in re.split(r'(?=SMP )', text):
        glued = bool(rec) and not rec.endswith(' ')
        rec = rec.strip()
        m = re.match(r'SMP (\S+?)\[(\d+)\] slide (0x[0-9a-fA-F]+) mh (0x[0-9a-fA-F]+)', rec)
        if m:
            cur = (m.group(1), int(m.group(2)), int(m.group(3), 16), int(m.group(4), 16), [])
            procs.append(cur)
            continue
        m = re.match(r'SMP (\S+) (t\d+) pc (.*)$', rec)
        if m and cur is not None:
            head, _, bt = m.group(3).partition(' bt ')
            frames = [int(h, 16) for h in HEX.findall(head)][:2]       # pc, lr (sp dropped)
            tail = [int(h, 16) for h in HEX.findall(bt)]
            if glued and tail:
                tail = tail[:-1]
            frames = [a for a in frames + tail if a]
            cur[4].append((m.group(2), frames))
    return procs


def text_vmaddr(path):
    b = open(path, 'rb').read(4096 * 16)
    if b[:4] in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        raise SystemExit('fat binary: pass a thin arm64 file')
    ncmds = struct.unpack_from('<I', b, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd == 0x19 and b[off + 8:off + 14] == b'__TEXT':
            return struct.unpack_from('<Q', b, off + 24)[0]
        off += size
    return 0x100000000


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    cache_dir, text_arg = args[0], args[1]
    bins, disasm = {}, 'llvm-objdump'
    i = 2
    while i < len(args):
        if args[i] == '--bin':
            name, path = args[i + 1].split('=', 1)
            bins[name] = path
            i += 2
        elif args[i] == '--disasm':
            disasm = args[i + 1]
            i += 2
        else:
            raise SystemExit('unknown argument ' + args[i])
    text = open(text_arg[1:]).read() if text_arg.startswith('@') else text_arg
    procs = parse(text)
    if not procs:
        raise SystemExit('no "SMP name[pid] slide .. mh .." header found in the text')

    main_cache = os.path.join(cache_dir, 'dyld_shared_cache_arm64')
    sym_file = main_cache + '.symbols'
    shared_start, images = dscsym.read_images(main_cache)
    bases = sorted((v[0], k) for k, v in images.items())
    base_addrs = [b for b, _ in bases]
    have_syms = os.path.exists(sym_file)
    print('cache images: %d, local symbols file: %s' % (len(images), 'yes' if have_syms else 'MISSING'))

    # first pass: which images are hit
    used = set()
    for name, pid, slide, mh, threads in procs:
        for _, frames in threads:
            for a in frames:
                if mh <= a < mh + 0x4000000:
                    continue
                j = bisect.bisect_right(base_addrs, a - slide) - 1
                if j >= 0 and a - slide >= shared_start:
                    used.add(bases[j][1])
    tables = dscsym.read_symbols(sym_file, shared_start, {n: images[n][0] for n in used}) if have_syms else {}

    def name_frame(a, slide, mh, pname):
        if mh <= a < mh + 0x4000000:
            return '%s+0x%x' % (pname, a - mh)
        u = a - slide
        j = bisect.bisect_right(base_addrs, u) - 1
        if j < 0 or u < shared_start:
            return '0x%x (outside cache)' % a
        img = bases[j][1]
        t = tables.get(img)
        if t:
            k = bisect.bisect_right(t[0], u) - 1
            if k >= 0:
                return '%s`%s + %d' % (img, t[1][k], u - t[0][k])
        return '%s+0x%x' % (img, u - base_addrs[j])

    exe_hits = {}
    for name, pid, slide, mh, threads in procs:
        print('\n=== %s[%d] slide 0x%x mh 0x%x' % (name, pid, slide, mh))
        for tname, frames in threads:
            print('%s:' % tname)
            for n, a in enumerate(frames):
                label = name_frame(a, slide, mh, name)
                print('   %2d  0x%x  %s' % (n, a, label))
                if mh <= a < mh + 0x4000000:
                    exe_hits.setdefault(name, set()).add(a - mh)

    for pname, offs in exe_hits.items():
        path = next((p for k, p in bins.items() if pname.startswith(k) or k.startswith(pname)), None)
        if not path or not os.path.exists(path):
            continue
        base = text_vmaddr(path)
        print('\n##### disassembly around call sites in %s (%s)' % (pname, path))
        for off in sorted(offs):
            site = base + off
            lo, hi = site - 0x70, site + 0x10
            print('\n--- %s+0x%x (return address; the call is the instruction before it)' % (pname, off))
            r = subprocess.run([disasm, '-d', '--macho', '--no-show-raw-insn',
                                '--start-address=0x%x' % lo, '--stop-address=0x%x' % hi, path],
                               capture_output=True, text=True)
            print((r.stdout or r.stderr)[-3500:])


if __name__ == '__main__':
    main()
