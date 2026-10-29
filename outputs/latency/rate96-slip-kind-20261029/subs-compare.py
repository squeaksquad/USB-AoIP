#!/usr/bin/env python3
# subs-compare.py REFERENCE.json CURRENT.json: the Dante subscriptions (netaudio -j subscription list)
# as (rx device, rx channel, tx device, tx channel, state); prints what differs, exits 1 if anything does.
import json, sys
def key(path):
    return {(s["rx_device"], s["rx_channel"], s.get("tx_device"), s.get("tx_channel"), s["status"]["state"])
            for s in json.load(open(path))}
a, b = key(sys.argv[1]), key(sys.argv[2])
for row in sorted(a - b, key=str): print("only in reference:", row)
for row in sorted(b - a, key=str): print("only now:", row)
print(f"{len(b)} subscriptions, {len(a & b)} as in the reference")
sys.exit(1 if a != b else 0)
