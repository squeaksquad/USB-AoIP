import array, sys, struct, collections
cap = array.array("f")
with open(sys.argv[1], "rb") as fh: cap.frombytes(fh.read())
amp = 0.1
def f32(x): return struct.unpack("f", struct.pack("f", x))[0]
state = 0x9e3779b9; gen = []
for i in range(15 * (len(cap) + 20000)):
    state ^= (state << 13) & 0xffffffff; state ^= state >> 17; state ^= (state << 5) & 0xffffffff
    if i % 15 == 0:
        v = state if state < 0x80000000 else state - 0x100000000
        gen.append(f32(f32(max(-1.0, min(1.0, f32(v) / f32(2147483647.0)))) * f32(amp)))
tol = 1.5e-6; B = 8
def match(ci, gi):
    if gi < 0 or gi + B > len(gen) or ci + B > len(cap): return False
    return all(abs(cap[ci+k] - gen[gi+k]) <= tol for k in range(B))
first = next(i for i, v in enumerate(cap) if v != 0.0)
last = max(i for i, v in enumerate(cap) if v != 0.0)
# initial delta: gen index = cap index + delta
delta = None
for d in range(-3000, 3000):
    if match(first, first + d): delta = d; break
if delta is None: print("   no initial alignment"); sys.exit()
print("   first nonzero cap %d = gen %d (delta %d, i.e. lag %d frames after out/in offset)" % (first, first + delta, delta, -delta))
events = []; zeros_runs = []; i = first; unmatched = 0
while i + B <= last:
    if match(i, i + delta): i += B; continue
    # zeros?
    z = 0
    while i + z <= last and cap[i + z] == 0.0: z += 1
    if z >= B:
        # find realignment after the zero run
        j = i + z; nd = None
        for d in range(delta - 4800, delta + 4800):
            if match(j, j + d): nd = d; break
        if nd is None: events.append(("zeros-unrecovered", i, z, 0)); break
        events.append(("zeros", i, z, nd - delta)); delta = nd; i = j; continue
    nd = None
    for d in list(range(delta - 200, delta + 200)):
        if match(i, i + d): nd = d; break
    if nd is None:
        unmatched += 1; i += 1; continue
    events.append(("shift", i, 0, nd - delta)); delta = nd
kinds = collections.Counter(e[0] for e in events)
shifts = collections.Counter(e[3] for e in events if e[0] == "shift")
print("   events: %s, unmatched samples %d; final delta %d" % (dict(kinds), unmatched, delta))
print("   shift sizes (delta change: count): %s" % dict(sorted(shifts.items())))
for e in events[:40]:
    print("     %-8s cap %6d zeros %5d delta change %+d" % e)
