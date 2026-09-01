#!/usr/bin/env python3
"""Detect whether an IGMP querier exists on the AoIP segment, without root.

The SAP discovery finding argues that the fixed 263-267 s time-to-audio is the
IGMP group membership interval expiring on a segment with no querier. That
premise was inferred, not measured. This measures it.

Method: join a multicast group we do not otherwise use, then poll
/proc/net/igmp. When a General Query arrives, the kernel arms a per-group
report delay timer. An armed timer after the initial join settles therefore
means a querier is present, and the gaps between arming events are its query
interval. No timer for longer than one standard query interval (125 s) means
no querier.

Passive with respect to the system under test: it touches no config, no daemon
and no sink, and it deliberately joins an unused group so the SAP group's own
snooping state is not warmed.
"""
import argparse, ipaddress, socket, struct, sys, time

IGMP = '/proc/net/igmp'

def proc_key(group: str) -> str:
    packed = ipaddress.IPv4Address(group).packed
    return ''.join(f'{b:02X}' for b in reversed(packed)) if sys.byteorder == 'little' \
        else ''.join(f'{b:02X}' for b in packed)

def read_timer(device: str, key: str):
    """Return (armed, raw) for the group on the device, or None if absent."""
    current = None
    for line in open(IGMP):
        if not line.startswith(('\t', ' ')) and ':' in line:
            current = line.split(':')[0].split()[-1]
            continue
        parts = line.split()
        if current == device and parts and parts[0] == key:
            raw = parts[2] if len(parts) > 2 else '0:00000000'
            flag, _, value = raw.partition(':')
            return (flag not in ('', '0') or int(value or '0', 16) != 0), raw
    return None

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--interface-ip', default='169.254.92.97')
    ap.add_argument('--device', default='eth0')
    ap.add_argument('--group', default='239.255.42.99')
    ap.add_argument('--settle', type=float, default=20.0)
    ap.add_argument('--duration', type=float, default=150.0)
    ap.add_argument('--poll', type=float, default=0.2)
    args = ap.parse_args()

    key = proc_key(args.group)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', 0))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                    socket.inet_aton(args.group) + socket.inet_aton(args.interface_ip))
    print(f'# joined {args.group} on {args.device} ({args.interface_ip}), key {key}')
    print(f'# settling {args.settle:.0f}s, then watching {args.duration:.0f}s '
          f'(standard query interval is 125s)')

    if read_timer(args.device, key) is None:
        print(f'ERROR: {args.group} not visible in {IGMP} for {args.device}', file=sys.stderr)
        return 2

    started = time.monotonic()
    while time.monotonic() - started < args.settle:
        time.sleep(args.poll)

    print('# offset  event')
    watch_start = time.monotonic()
    previous, events = False, []
    while True:
        now = time.monotonic()
        if now - watch_start >= args.duration:
            break
        armed, raw = read_timer(args.device, key)
        if armed and not previous:
            offset = now - watch_start
            events.append(offset)
            print(f'+{offset:8.2f}  report timer armed ({raw}) -> a query reached this host')
        previous = armed
        time.sleep(args.poll)

    print('# --- summary ---')
    print(f'# watched {args.duration:.0f}s after a {args.settle:.0f}s settle')
    print(f'# timer arming events: {len(events)}')
    if len(events) > 1:
        gaps = [b - a for a, b in zip(events, events[1:])]
        print('# gaps: ' + ', '.join(f'{g:.1f}s' for g in gaps))
    if events:
        print('# VERDICT: a querier IS present on this segment.')
    else:
        print('# VERDICT: NO querier reached this host in a full query interval.')
        print('#          Consistent with the finding: snooping with no querier.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
