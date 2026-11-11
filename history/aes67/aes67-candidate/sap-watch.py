#!/usr/bin/env python3
"""Timestamps SAP announcements on the AoIP segment.

Purpose: split the documented ~3.5 minute post-restart delay into its two
independent parts. SAP discovery (the Pi announcing its sessions) and Ferrofish
subscription resolution (the Ferrofish acting on them) are currently conflated
in one number. This records the first half; the harness settle.log records the
second, and the two share a wall clock.

Passive. It joins 239.255.255.255:9875 and reads. It transmits nothing but the
IGMP join itself and never touches the daemon, the sinks, or the sources.

The field that matters is the SDP origin version (the `o=` line). A receiver
re-resolves a subscription when a session's version changes, so a version bump
here is the event that starts the Ferrofish clock.
"""

import argparse
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time

SAP_GROUP = "239.255.255.255"
SAP_PORT = 9875

# RFC 2974 section 4: the third bit of the flags byte is the message type,
# 0 for an announcement and 1 for a session deletion.
SAP_MESSAGE_TYPE_DELETION = 0x04
SAP_FLAG_ENCRYPTED = 0x02
SAP_FLAG_COMPRESSED = 0x01
SAP_ADDRESS_TYPE_IPV6 = 0x10


def interface_address(interface_name):
    """The IPv4 address currently on an interface.

    Read live rather than configured because the AoIP segment is link-local and
    the handoff is explicit that the address must never be assumed stable.
    """
    try:
        output = subprocess.run(
            ["ifconfig", interface_name],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except (subprocess.SubprocessError, FileNotFoundError) as error:
        raise SystemExit(f"cannot read {interface_name}: {error}")
    match = re.search(r"^\s*inet (\d+\.\d+\.\d+\.\d+)", output, re.MULTILINE)
    if not match:
        raise SystemExit(f"{interface_name} has no IPv4 address")
    return match.group(1)


def parse_sap(datagram):
    """Returns (is_deletion, sdp_text) or None if this is not plain SDP."""
    if len(datagram) < 8:
        return None
    flags = datagram[0]
    if flags >> 5 != 1:  # version field, always 1
        return None
    if flags & (SAP_FLAG_ENCRYPTED | SAP_FLAG_COMPRESSED):
        return None  # nothing on this segment does either; do not guess
    is_deletion = bool(flags & SAP_MESSAGE_TYPE_DELETION)
    authentication_length = datagram[1]
    origin_length = 16 if flags & SAP_ADDRESS_TYPE_IPV6 else 4
    offset = 4 + origin_length + authentication_length * 4
    if offset >= len(datagram):
        return None
    payload = datagram[offset:]
    # An optional null-terminated payload type may precede the SDP.
    start = payload.find(b"v=0")
    if start < 0:
        return None
    return is_deletion, payload[start:].decode("utf-8", "replace")


def sdp_field(sdp_text, prefix):
    for line in sdp_text.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", default=os.environ.get("USB16X16_AOIP_INTERFACE", "en12"))
    parser.add_argument("--duration", type=float, default=1800.0,
                        help="safety cap in seconds; the watcher also exits on SIGTERM")
    parser.add_argument("--output", default="-", help="log file, or - for stdout")
    arguments = parser.parse_args()

    local_address = interface_address(arguments.interface)
    sink = sys.stdout if arguments.output == "-" else open(arguments.output, "w", buffering=1)

    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("", SAP_PORT))
    listener.setsockopt(
        socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
        struct.pack("4s4s", socket.inet_aton(SAP_GROUP), socket.inet_aton(local_address)),
    )
    listener.settimeout(1.0)

    running = {"value": True}
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__("value", False))
    signal.signal(signal.SIGINT, lambda *_: running.__setitem__("value", False))

    started = time.time()
    versions = {}       # (source, session name) -> last origin version
    first_seen = {}     # source -> offset of its first announcement
    counts = {}

    def emit(text):
        print(text, file=sink, flush=True)

    emit(f"# sap-watch on {arguments.interface} ({local_address}) joined {SAP_GROUP}:{SAP_PORT}")
    emit(f"# start {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started))} "
         f"({started:.3f} epoch); duration cap {arguments.duration:.0f}s")
    emit("# offset   wall-clock    source           event   session")

    while running["value"] and time.time() - started < arguments.duration:
        try:
            datagram, sender = listener.recvfrom(8192)
        except socket.timeout:
            continue
        except OSError as error:
            emit(f"# socket error: {error}")
            break

        parsed = parse_sap(datagram)
        if parsed is None:
            continue
        is_deletion, sdp_text = parsed
        source = sender[0]
        session = sdp_field(sdp_text, "s=") or "?"
        origin = sdp_field(sdp_text, "o=")
        version = origin.split()[2] if len(origin.split()) > 2 else "?"
        connection = sdp_field(sdp_text, "c=").replace("IN IP4 ", "")

        offset = time.time() - started
        wall = time.strftime("%H:%M:%S", time.localtime())
        counts[source] = counts.get(source, 0) + 1
        if source not in first_seen:
            first_seen[source] = offset

        key = (source, session)
        if is_deletion:
            event = "DELETE"
            versions.pop(key, None)
        elif key not in versions:
            event = "NEW   "
        elif versions[key] != version:
            event = "CHANGE"
        else:
            event = "repeat"
        if not is_deletion:
            versions[key] = version

        emit(f"+{offset:8.2f}  {wall}  {source:<15}  {event}  "
             f"{session}  addr={connection}  o-version={version}")

    emit("# --- summary ---")
    for source in sorted(first_seen):
        emit(f"# {source:<15} first announcement +{first_seen[source]:.2f}s, "
             f"{counts[source]} packet(s)")
    if not first_seen:
        emit("# no SAP announcements seen")
    emit(f"# stopped after {time.time() - started:.1f}s")
    if sink is not sys.stdout:
        sink.close()


if __name__ == "__main__":
    main()
