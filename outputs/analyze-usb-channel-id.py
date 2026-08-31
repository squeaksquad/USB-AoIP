#!/usr/bin/env python3
"""Verify a 16-channel PCM WAV recorded from the CamillaDSP USB loopback."""

import argparse
import math
import wave
from pathlib import Path

RATE = 48_000
CHANNELS = 16
BLOCK_FRAMES = 480
SEGMENT_BLOCKS = 50
INTERIOR_START = 5
INTERIOR_END = 45


def decode_sample(data: bytes, width: int) -> int:
    return int.from_bytes(data, "little", signed=True)


def block_powers(raw: bytes, width: int) -> list[float]:
    frame_bytes = CHANNELS * width
    frames = len(raw) // frame_bytes
    powers = [0.0] * CHANNELS
    if not frames:
        return powers
    offset = 0
    for _ in range(frames):
        for channel in range(CHANNELS):
            sample = decode_sample(raw[offset : offset + width], width)
            powers[channel] += float(sample * sample)
            offset += width
    return [value / frames for value in powers]


def db_ratio(signal: float, leakage: float) -> float:
    if signal <= 0.0:
        return float("-inf")
    if leakage <= 0.0:
        return float("inf")
    return 10.0 * math.log10(signal / leakage)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording", type=Path)
    parser.add_argument("--minimum-separation-db", type=float, default=40.0)
    args = parser.parse_args()

    with wave.open(str(args.recording), "rb") as wav:
        if wav.getframerate() != RATE or wav.getnchannels() != CHANNELS:
            raise SystemExit(
                f"Expected 16 channels at 48000 Hz; got {wav.getnchannels()} at {wav.getframerate()} Hz"
            )
        width = wav.getsampwidth()
        if width not in (2, 3, 4):
            raise SystemExit(f"Unsupported integer PCM sample width: {width} bytes")
        blocks = []
        while True:
            raw = wav.readframes(BLOCK_FRAMES)
            if not raw:
                break
            blocks.append(block_powers(raw, width))

    peak = max((max(block) for block in blocks), default=0.0)
    if peak <= 0.0:
        raise SystemExit("Recording contains no signal")
    onset_threshold = peak * (10.0 ** (-20.0 / 10.0))
    try:
        onset = next(index for index, block in enumerate(blocks) if max(block) >= onset_threshold)
    except StopIteration:
        raise SystemExit("Unable to locate channel-ID onset")

    passed = True
    print("expected observed separation_db result")
    for expected in range(CHANNELS):
        start = onset + expected * SEGMENT_BLOCKS + INTERIOR_START
        end = onset + expected * SEGMENT_BLOCKS + INTERIOR_END
        if end > len(blocks):
            print(f"{expected + 1:8d} {'missing':>8} {'n/a':>13} FAIL")
            passed = False
            continue
        powers = [sum(block[ch] for block in blocks[start:end]) for ch in range(CHANNELS)]
        observed = max(range(CHANNELS), key=powers.__getitem__)
        leakage = max((powers[ch] for ch in range(CHANNELS) if ch != observed), default=0.0)
        separation = db_ratio(powers[observed], leakage)
        segment_pass = observed == expected and separation >= args.minimum_separation_db
        passed = passed and segment_pass
        separation_text = "inf" if math.isinf(separation) else f"{separation:.1f}"
        print(
            f"{expected + 1:8d} {observed + 1:8d} {separation_text:>13} "
            f"{'PASS' if segment_pass else 'FAIL'}"
        )

    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
