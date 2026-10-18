# measure-candidate.sh's soak criteria (work/dsp-service/validate.py), with the
# sample count taken from the report's own sampleRate instead of 48000.
import json, sys
d = json.load(open(sys.argv[1])); bad = []; rate = d["sampleRate"]
for key in ("inputDiscontinuities", "outputDiscontinuities", "invalidBuffers", "invalidTimestamps"):
    if d.get(key): bad.append(f"{key}={d[key]}")
for i, c in enumerate(d["channels"], 1):
    why = []
    if c["samples"] < (d["seconds"] - 3) * rate: why.append("short")
    if c["peak"] < 1e-8: why.append("silent")
    if c["longestZeroRun"] >= 4: why.append(f"zero run {c['longestZeroRun']}")
    if c.get("nonFinite"): why.append("non-finite")
    if c.get("fullScaleSamples"): why.append("full scale")
    if why: bad.append(f"ch{i}: " + ", ".join(why))
runs = [c["longestZeroRun"] for c in d["channels"]]; peaks = [c["peak"] for c in d["channels"]]
print(f"rate={rate} channels={len(d['channels'])} seconds={d['seconds']} samples/ch={min(c['samples'] for c in d['channels'])}")
print(f"longest zero run max={max(runs)} peak min={min(peaks):.4f} max={max(peaks):.4f}")
print(f"discontinuities in={d['inputDiscontinuities']} out={d['outputDiscontinuities']} invalid buffers={d['invalidBuffers']} timestamps={d['invalidTimestamps']} events={d['eventCapture']['triggeredEvents']}")
print("soak: FAIL " + "; ".join(bad) if bad else "soak: PASS"); raise SystemExit(1 if bad else 0)
