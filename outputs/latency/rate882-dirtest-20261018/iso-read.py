# iso-read.py TRACE: per window, per endpoint: packet lengths, actuals, status, content, timing.
import re, sys, collections
win = None; data = collections.defaultdict(list)
pat = re.compile(r" (\d+\.\d+): iso: .*ep=0x([0-9a-f]+) len=(\d+) act=(\d+) st=(-?\d+) fn=(\d+) d0=0x([0-9a-f]+) d5=0x([0-9a-f]+)")
for line in open(sys.argv[1]):
    if "WINDOW start" in line: win = line.split("WINDOW start ")[1].split()[0]; continue
    if "WINDOW end" in line: win = None; continue
    m = pat.search(line)
    if m and win: data[(win, m.group(2))].append((float(m.group(1)), int(m.group(3)), int(m.group(4)), int(m.group(5)), int(m.group(6)), m.group(7), m.group(8)))
for (w, ep), rows in sorted(data.items()):
    t = [r[0] for r in rows]; n = len(rows); span = t[-1] - t[0]
    lens = collections.Counter(r[1] for r in rows); acts = collections.Counter(r[2] for r in rows); st = collections.Counter(r[3] for r in rows)
    zero0 = sum(1 for r in rows if int(r[5], 16) == 0); zero5 = sum(1 for r in rows if int(r[6], 16) == 0)
    gaps = [b - a for a, b in zip(t, t[1:])]
    fns = [r[4] for r in rows]; dfn = collections.Counter((b - a) & 0x3fff for a, b in zip(fns, fns[1:]))
    print(f"{w} ep {ep[-6:]}: {n} completions in {span:.3f} s ({n / span:.0f}/s), bytes/s by act {sum(r[2] for r in rows) / span:.0f}")
    print(f"   len {dict(lens.most_common(4))}  act {dict(acts.most_common(4))}  status {dict(st)}")
    print(f"   content zero at +3: {zero0}/{n}, at +243: {zero5}/{n}; gap max {max(gaps) * 1e3:.2f} ms; frame-number steps {dict(dfn.most_common(4))}")
