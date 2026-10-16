#!/usr/bin/env python3
"""Tests for dante-pcap-zeros.py against synthetic captures (SAMPLE_RATE_DESIGN.md,
step 3): the rate read from the timestamps, 48 kHz unchanged, a contradicting
--rate refused. Pure standard library; touches only a temporary directory.

  python3 -I test_dante_pcap_zeros.py
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "dante-pcap-zeros.py")
PI = "169.254.92.97"
FAR = "169.254.10.20"


def frame(src, dst, payload):
    ip = lambda a: bytes(int(x) for x in a.split("."))
    udp = struct.pack(">HHHH", 4321, 4322, 8 + len(payload), 0) + payload
    header = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0, ip(src), ip(dst))
    return b"\x02" * 6 + b"\x04" * 6 + b"\x08\x00" + header + udp


def write_capture(path, rate, start_samples, packets, frames=16, channels=2, hole_every=0):
    """One flow from the far device to the Pi, `frames` a packet, starting
    `start_samples` into second 1000; every `hole_every`-th packet has two zeroed frames."""
    rng = random.Random(rate)
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        position = 1000 * rate + start_samples
        for index in range(packets):
            seconds, samples = divmod(position, rate)
            audio = bytearray(rng.randrange(1, 256) for _ in range(frames * channels * 3))
            if hole_every and index % hole_every == 0:
                audio[0:2 * channels * 3] = bytes(2 * channels * 3)
            data = frame(FAR, PI, b"\x02" + struct.pack(">II", seconds, samples) + bytes(audio))
            when = position / rate
            f.write(struct.pack("<IIII", int(when), int((when % 1) * 1e6), len(data), len(data)))
            f.write(data)
            position += frames


def run(path, *extra):
    return subprocess.run([sys.executable, "-I", TOOL, path, "--pi", PI, *extra], capture_output=True, text=True)


class RateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, "x.pcap")

    def tearDown(self):
        self.directory.cleanup()

    def test_48k_read_from_the_capture(self):
        write_capture(self.path, 48000, 48000 - 800, 200, hole_every=10)
        result = run(self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rate 48000 (from the timestamps)", result.stdout)
        self.assertIn("timestamp steps {16: 199}", result.stdout)
        self.assertIn("so 16 frames a packet, 2 channels", result.stdout)
        self.assertIn("packets with a zero run of 9+ bytes: 20 (10.0 %)", result.stdout)

    def test_96k_read_from_the_capture(self):
        write_capture(self.path, 96000, 96000 - 800, 200)
        result = run(self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rate 96000 (from the timestamps)", result.stdout)
        self.assertIn("timestamp steps {16: 199}", result.stdout, "a second boundary is one ordinary step")

    def test_44k1_read_from_the_capture(self):
        write_capture(self.path, 44100, 44100 - 800, 200)
        result = run(self.path)
        self.assertIn("rate 44100 (from the timestamps)", result.stdout)
        self.assertIn("timestamp steps {16: 199}", result.stdout)

    def test_a_contradicting_rate_is_refused(self):
        write_capture(self.path, 96000, 96000 - 800, 200)
        result = run(self.path, "--rate", "48000")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("count to 96000 a second, not the --rate 48000", result.stderr)
        self.assertEqual(run(self.path, "--rate", "96000").returncode, 0)

    def test_a_rate_dante_does_not_have_is_refused(self):
        write_capture(self.path, 48000, 0, 10)
        self.assertNotEqual(run(self.path, "--rate", "32000").returncode, 0)

    def test_no_second_crossed_falls_back(self):
        write_capture(self.path, 96000, 1000, 100)
        self.assertIn("rate 48000 (assumed: no flow crossed a second)", run(self.path).stdout)
        self.assertIn("rate 96000 (given)", run(self.path, "--rate", "96000").stdout)


if __name__ == "__main__":
    unittest.main()
