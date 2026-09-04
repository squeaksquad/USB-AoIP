import array, sys, struct, collections
cap = array.array("f")
with open(sys.argv[1], "rb") as fh: cap.frombytes(fh.read())
B = int(sys.argv[2])
first = next((i for i, v in enumerate(cap) if v != 0.0), None)
if first is None: print("   all zero"); sys.exit()
last = max(i for i, v in enumerate(cap) if v != 0.0)
seg = cap[first:last+1]
zeros = sum(1 for v in seg if v == 0.0)
# zero runs
runs = []; z = 0
for v in seg:
    if v == 0.0: z += 1
    else:
        if z: runs.append(z)
        z = 0
if z: runs.append(z)
runs_big = [r for r in runs if r >= 4]
hist = collections.Counter(runs_big)
print("   nonzero span %d..%d (%d samples), zeros inside span %.1f%%, zero runs>=4: %d, mean run %.1f, run-length histogram (top 8): %s" % (
    first, last, last - first + 1, 100.0 * zeros / len(seg), len(runs_big), (sum(runs_big) / len(runs_big)) if runs_big else 0, hist.most_common(8)))
# zero-run start positions modulo B
starts = []; z = 0
for i, v in enumerate(seg):
    if v == 0.0:
        if z == 0: s0 = i
        z += 1
    else:
        if z >= 4: starts.append((first + s0) % B)
        z = 0
print("   zero-run start offsets mod %d (top 6): %s" % (B, collections.Counter(starts).most_common(6)))
