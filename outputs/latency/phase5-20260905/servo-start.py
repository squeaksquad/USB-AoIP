#!/usr/bin/env python3
"""Stage A of Phase 5: price the clock-related terms in bridge telemetry.

Reads one or more bridge logs (the full-rate tmpfs log, a candidate
bridge.log, or a journalctl export, which is split into sessions by PID)
and reports, per session:

  warm-up drift   depth moved between the first BRIDGE line and the
                  PITCHSERVO engaged line (frames per direction, and the
                  differential), while pitch sits at nominal
  settle          seconds from engagement until pitch stays within +-1 of
                  its steady value, and the pitch overshoot on the way
  wander          post-settle band of tx/rx per-second depth means and of
                  the bias term (the 1 ppm quantisation residual)
  ring            tx_occ / rx_occ min and max against the target
  floors          tx_qfloor / rx_qfloor at engagement and at the end

Frames per direction: 48 frames = 1 ms at 48 kHz.
"""
import re
import statistics
import sys
from collections import defaultdict

KV = re.compile(r'(\w+)=(-?[\d.]+)')


def parse_bridge(line):
    body = line[line.index('BRIDGE '):]
    out = {}
    for k, v in KV.findall(body):
        try:
            out[k] = float(v)
        except ValueError:
            pass
    return out


def sessions_from(path):
    """Yield (name, lines) per session. Journal exports split on PID."""
    with open(path, errors='replace') as fh:
        lines = fh.read().splitlines()
    journal = any(re.match(r'\d{4}-\d\d-\d\dT', l) for l in lines[:50])
    if not journal:
        yield path, lines
        return
    by_pid = defaultdict(list)
    order = []
    for l in lines:
        m = re.search(r'usb16x16-aes67\[(\d+)\]: (.*)', l)
        if not m:
            continue
        pid, rest = m.group(1), m.group(2)
        if pid not in by_pid:
            order.append((pid, l[:19]))
        by_pid[pid].append(rest)
    for pid, stamp in order:
        yield f'{path.split("/")[-1]} pid {pid} {stamp}', by_pid[pid]


def analyse(name, lines, target=128):
    bridge = [parse_bridge(l) for l in lines if 'BRIDGE ppm=' in l]
    if len(bridge) < 3 or 'pitch' not in bridge[-1]:
        return None
    engaged = next((l for l in lines if 'PITCHSERVO engaged' in l), None)
    primed = {}
    for l in lines:
        if 'PRIMED direction=' in l:
            d = dict(KV.findall(l))
            key = 'tx' if 'usb-to-ravenna' in l else 'rx'
            primed[key] = d
    # Engagement index: first BRIDGE line where ppm != 0 (steering began).
    eng = next((i for i, b in enumerate(bridge) if b.get('ppm', 0) != 0), None)
    if eng is None:
        return None
    first, at_eng = bridge[0], bridge[eng]
    dtx = at_eng['tx_dmean'] - first['tx_dmean']
    drx = at_eng['rx_dmean'] - first['rx_dmean']
    # Settle: pitch within +-1 of the median of the last third, and stays.
    pitches = [b['pitch'] for b in bridge[eng:]]
    tail = pitches[len(pitches) * 2 // 3:]
    steady = statistics.median(tail) if tail else pitches[-1]
    settle = None
    for i in range(len(pitches)):
        if all(abs(p - steady) <= 1 for p in pitches[i:i + 30]):
            settle = i
            break
    over = max(pitches) - steady
    post = bridge[eng + (settle or 0):]
    tx_dm = [b['tx_dmean'] for b in post]
    rx_dm = [b['rx_dmean'] for b in post]
    diff = [b['tx_dmean'] - b['rx_dmean'] for b in post]
    at_settle = bridge[eng + (settle or 0)]
    bias = [b.get('bias_ppm', 0) for b in post]
    occ_tx = [b['tx_occ'] for b in bridge]
    occ_rx = [b['rx_occ'] for b in bridge]
    last = bridge[-1]
    return {
        'name': name, 'seconds': len(bridge), 'engaged_at_s': eng,
        'tx_prime': primed.get('tx', {}).get('queue_prime'),
        'rx_prime': primed.get('rx', {}).get('queue_prime'),
        'tx_drift': dtx, 'rx_drift': drx, 'diff_drift': dtx - drx,
        'steady_pitch': steady, 'settle_s': settle, 'overshoot_ppm': over,
        'tx_level': (first['tx_dmean'], at_eng['tx_dmean'], at_settle['tx_dmean'], last['tx_dmean']),
        'diff_wander': (min(diff), max(diff)) if diff else None,
        'tx_wander': (min(tx_dm), max(tx_dm)) if tx_dm else None,
        'rx_wander': (min(rx_dm), max(rx_dm)) if rx_dm else None,
        'bias': (min(bias), max(bias)) if bias else None,
        'ring_tx': (min(occ_tx), max(occ_tx)), 'ring_rx': (min(occ_rx), max(occ_rx)),
        'qfloor_eng': (at_eng['tx_qfloor'], at_eng['rx_qfloor']),
        'qfloor_end': (last['tx_qfloor'], last['rx_qfloor']),
        'pullmax': (last.get('tx_pullmax'), last.get('rx_pullmax')),
    }


def fmt_pair(p, w=0):
    return '-' if p is None else f'{p[0]:.0f}/{p[1]:.0f}'


def main(paths):
    rows = []
    for p in paths:
        for name, lines in sessions_from(p):
            r = analyse(name, lines)
            if r:
                rows.append(r)
    hdr = ('session', 's', 'eng', 'primes', 'tx_drift', 'rx_drift', 'pitch', 'settle', 'over',
           'tx_dmean first/eng/settle/end', 'diff_wander', 'bias', 'ring_tx', 'ring_rx', 'qfloor@eng', 'qfloor@end')
    print('| ' + ' | '.join(hdr) + ' |')
    print('|' + '---|' * len(hdr))
    for r in rows:
        print('| ' + ' | '.join([
            r['name'][-40:], str(r['seconds']), str(r['engaged_at_s']),
            f"{r['tx_prime'] or '-'}/{r['rx_prime'] or '-'}",
            f"{r['tx_drift']:+.0f}", f"{r['rx_drift']:+.0f}",
            f"{r['steady_pitch']:.0f}", str(r['settle_s']), f"{r['overshoot_ppm']:.0f}",
            '/'.join(f'{v:.0f}' for v in r['tx_level']),
            '-' if r['diff_wander'] is None else f"{r['diff_wander'][0]:.0f}..{r['diff_wander'][1]:.0f} ({r['diff_wander'][1]-r['diff_wander'][0]:.0f})",
            '-' if r['bias'] is None else f"{r['bias'][0]:+.1f}/{r['bias'][1]:+.1f}",
            fmt_pair(r['ring_tx']), fmt_pair(r['ring_rx']),
            fmt_pair(r['qfloor_eng']), fmt_pair(r['qfloor_end']),
        ]) + ' |')
    if len(rows) > 1:
        txd = [r['tx_drift'] for r in rows]
        rxd = [r['rx_drift'] for r in rows]
        st = [r['settle_s'] for r in rows if r['settle_s'] is not None]
        print()
        print(f'sessions {len(rows)}: tx warm-up drift median {statistics.median(txd):+.0f} '
              f'(range {min(txd):+.0f}..{max(txd):+.0f}), rx {statistics.median(rxd):+.0f} '
              f'({min(rxd):+.0f}..{max(rxd):+.0f}); settle median {statistics.median(st) if st else "-"} s; '
              f'steady pitch {sorted(set(int(r["steady_pitch"]) for r in rows))}')


if __name__ == '__main__':
    main(sys.argv[1:])
