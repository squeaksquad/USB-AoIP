#!/usr/bin/env python3
"""set-rate-one.py IP RATE: send one Dante sample-rate set (opcode 0x0081, the
packet Dante Switcher and Dante Controller send) to one device's settings port
8700 from en12, so a set can reach the Pi alone. Same bytes as
DantePackets.setSampleRate in ~/Development/Dante Switcher. Made 2026-10-28."""
import socket, struct, sys

ip, rate = sys.argv[1], int(sys.argv[2])
mac = bytes.fromhex("4cea4163338f")      # en12, the controller address Dante Switcher uses
source = "169.254.253.98"                 # en12
record = bytes([0x07, 0x3E, 0x00, 0x81]) + struct.pack(">III", 100, 1, rate)
packet = b"\xff\xff" + struct.pack(">HH", 24 + len(record), 0x4242) + b"\0\0" + mac + b"\0\0" + b"Audinate" + record
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((source, 0))
s.sendto(packet, (ip, 8700))
print(f"sent set {rate} to {ip}:8700 ({len(packet)} bytes)")
