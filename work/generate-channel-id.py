#!/usr/bin/env python3
"""Generate a deterministic 16-channel, packed-24-bit channel-ID WAV."""

import math
import wave
from pathlib import Path

RATE = 48_000
CHANNELS = 16
SAMPLE_BYTES = 3
LEAD_SECONDS = 0.5
SEGMENT_SECONDS = 0.5
TAIL_SECONDS = 0.5
FADE_SECONDS = 0.02
AMPLITUDE = 0.25 * ((1 << 23) - 1)


def int24le(value: int) -> bytes:
    return int(value).to_bytes(3, "little", signed=True)


def silence(frames: int) -> bytes:
    return bytes(frames * CHANNELS * SAMPLE_BYTES)


def segment(active_channel: int) -> bytes:
    frames = int(SEGMENT_SECONDS * RATE)
    fade_frames = int(FADE_SECONDS * RATE)
    frequency = 400.0 + 25.0 * active_channel
    frame = bytearray(CHANNELS * SAMPLE_BYTES)
    result = bytearray(frames * CHANNELS * SAMPLE_BYTES)
    output_offset = 0

    for index in range(frames):
        edge = min(index, frames - 1 - index)
        envelope = min(1.0, edge / fade_frames)
        sample = round(
            AMPLITUDE
            * envelope
            * math.sin(2.0 * math.pi * frequency * index / RATE)
        )
        frame[:] = bytes(len(frame))
        sample_offset = active_channel * SAMPLE_BYTES
        frame[sample_offset : sample_offset + SAMPLE_BYTES] = int24le(sample)
        result[output_offset : output_offset + len(frame)] = frame
        output_offset += len(frame)
    return bytes(result)


def main() -> None:
    output = Path(__file__).resolve().parents[1] / "outputs" / "usb-channel-id-16ch.wav"
    output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output), "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(SAMPLE_BYTES)
        wav.setframerate(RATE)
        wav.writeframes(silence(int(LEAD_SECONDS * RATE)))
        for channel in range(CHANNELS):
            wav.writeframes(segment(channel))
        wav.writeframes(silence(int(TAIL_SECONDS * RATE)))
    print(output)


if __name__ == "__main__":
    main()
