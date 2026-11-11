#!/usr/bin/env python3
"""Measure the crossover through CamillaDSP: magnitude, phase, and the sum.

verify-tone.py measures the sub path at one frequency deep inside the passband,
which says nothing about the shape of the filter or about phase. The question
that matters for a crossover is not what either branch does alone but whether
the two sum back to flat, because that is what decides the polarity the
compiler refuses to choose.

So this feeds one impulse, takes the complex DFT of each output's impulse
response, and reports magnitude and phase per output plus, for each declared
main/sub pair, the complex sum of the two branches. A Linkwitz-Riley crossover
of the right order and polarity sums to an allpass: flat magnitude at every
frequency. The wrong polarity on an even-order-Butterworth (12 dB/oct) pair
puts a null at the crossover instead, and that null is the measurement.

What this is not: an acoustic measurement. It sums the two outputs
electrically, at equal level and with no path difference between them, so it
proves the filters and polarity are right and says nothing about what a real
room does to them.

Offline: no ALSA device is opened. It reads and writes files.
"""

import argparse
import array
import cmath
import json
import math
import subprocess
import sys
from pathlib import Path

CHANNELS = 16

# Butterworth pole Qs by order. A Linkwitz-Riley of order N is a Butterworth of
# order N/2 applied twice, so these are indexed by the Butterworth order.
BUTTERWORTH_Q = {
    1: [],              # a single real pole, handled as a first-order section
    2: [0.70710678118654752],
    4: [0.54119610014619698, 1.30656296487637652],
}


def write_impulse(path, frames, amplitude, lead):
    """One impulse on every channel; routing keeps the outputs apart."""
    block = array.array("d", [0.0] * (frames * CHANNELS))
    for channel in range(CHANNELS):
        block[lead * CHANNELS + channel] = amplitude
    with open(path, "wb") as out:
        block.tofile(out)


def read_f64(path):
    values = array.array("d")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def decay_point(samples, channel, frames, lead, floor):
    """Where this channel's impulse response has died, so the DFT can stop.

    Summing past the point where nothing is left costs time and adds nothing;
    stopping before it biases the result. Same rule as verify-response.py.
    """
    for n in range(frames - 1, lead - 1, -1):
        if abs(samples[n * CHANNELS + channel]) > floor:
            return min(frames, n + 64)
    return lead


def response_at(samples, channel, last, rate, freqs, lead):
    """Complex H(f) for one channel, phase referenced to the impulse."""
    out = []
    for freq in freqs:
        step = cmath.exp(complex(0.0, -2.0 * math.pi * freq / rate))
        phasor = complex(1.0, 0.0)
        total = complex(0.0, 0.0)
        for n in range(lead, last):
            total += samples[n * CHANNELS + channel] * phasor
            phasor *= step
        out.append(total)
    return out


def biquad_response(b0, b1, b2, a1, a2, w):
    num = b0 + b1 * cmath.exp(-1j * w) + b2 * cmath.exp(-2j * w)
    den = 1.0 + a1 * cmath.exp(-1j * w) + a2 * cmath.exp(-2j * w)
    return num / den


def butterworth_section(kind, freq, q, rate, w):
    """One RBJ cookbook biquad, the parameterization CamillaDSP uses."""
    w0 = 2 * math.pi * freq / rate
    cos0, sin0 = math.cos(w0), math.sin(w0)
    alpha = sin0 / (2 * q)
    if kind == "lowpass":
        b0, b1, b2 = (1 - cos0) / 2, 1 - cos0, (1 - cos0) / 2
    else:
        b0, b1, b2 = (1 + cos0) / 2, -(1 + cos0), (1 + cos0) / 2
    a0, a1, a2 = 1 + alpha, -2 * cos0, 1 - alpha
    return biquad_response(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0, w)


def first_order_section(kind, freq, rate, w):
    """The bilinear-transformed one-pole an odd Butterworth order needs."""
    k = math.tan(math.pi * freq / rate)
    if kind == "lowpass":
        b0, b1 = k / (1 + k), k / (1 + k)
    else:
        b0, b1 = 1 / (1 + k), -1 / (1 + k)
    a1 = (k - 1) / (k + 1)
    return biquad_response(b0, b1, 0.0, a1, 0.0, w)


def linkwitz_riley(kind, freq, order, rate, freqs):
    """Analytic |H| for a Linkwitz-Riley of `order`, as a Butterworth squared.

    A secondary check only. It agrees with the engine when the engine builds
    its combo the same way; a disagreement here is a difference of convention
    to investigate, not by itself an engine fault. The order and polarity
    checks below stand on the filter's defining properties instead, and do not
    depend on this model.
    """
    butter = order // 2
    if butter not in BUTTERWORTH_Q:
        return None
    out = []
    for freq_hz in freqs:
        w = 2 * math.pi * freq_hz / rate
        response = complex(1.0, 0.0)
        if butter % 2:
            response *= first_order_section(kind, freq, rate, w)
        for q in BUTTERWORTH_Q[butter]:
            response *= butterworth_section(kind, freq, q, rate, w)
        out.append(response ** 2)          # applied twice: that is the LR
    return out


def to_db(magnitude, reference):
    return round(20 * math.log10(magnitude / reference), 4) if magnitude > 0 else None


def wrap_deg(degrees):
    return round((degrees + 180.0) % 360.0 - 180.0, 3)


# Octaves either side of a crossover, for the slope search. They run further
# out than the audio band because that is where a high-order filter reaches its
# asymptote; they are frequencies to evaluate a DFT at, not frequencies anyone
# listens to. The upper end stops short of Nyquist, where the bilinear
# transform's warping would be the thing being measured.
SLOPE_OCTAVES = [2.0 ** n for n in range(-6, 7)]
SLOPE_MIN_HZ, SLOPE_MAX_HZ = 1.0, 20000.0


def build_freqs(points, pairs):
    """A log sweep, plus the octave points each pair is judged at."""
    freqs = {round(20.0 * (1000.0 ** (i / (points - 1))), 6) for i in range(points)}
    for pair in pairs:
        for factor in SLOPE_OCTAVES:
            value = pair["fcHz"] * factor
            if SLOPE_MIN_HZ <= value <= SLOPE_MAX_HZ:
                freqs.add(round(value, 6))
    return sorted(freqs)


def nearest(freqs, target):
    return min(range(len(freqs)), key=lambda i: abs(freqs[i] - target))


def asymptotic_slope(freqs, magnitudes, fc, kind, max_hz,
                     entry_db=-18.0, floor_db=-100.0):
    """Attenuation in dB per octave, measured where the slope is actually the
    asymptote.

    A fixed octave pair cannot serve every order. Close to the corner a low
    order has not reached its asymptote yet -- a 12 dB/oct low-pass still reads
    11.7 dB/oct an octave out -- while far from it a high order has fallen
    below anything a measurement can resolve, and the number that comes back is
    arithmetic noise rather than a filter. So this searches for the deepest
    octave whose shallower end is already past the knee and whose deeper end is
    still above the floor, and reports which octave it used.

    The search also stops well short of Nyquist. A digital low-pass falls to
    nothing at Nyquist whatever its order, so an octave taken up against it
    measures the bilinear transform rather than the filter: a 12 dB/oct
    low-pass reads 15.9 dB/oct at 6.4-12.8 kHz on a 48 kHz system.

    Returned positive: dB of attenuation gained per octave into the stopband.
    """
    best = None
    for index, freq in enumerate(freqs):
        partner = freq * 2 if kind == "lowpass" else freq / 2
        if kind == "lowpass" and freq <= fc:
            continue
        if kind == "highpass" and freq >= fc:
            continue
        if freq > max_hz or partner > max_hz:
            continue
        other = nearest(freqs, partner)
        if other == index or abs(freqs[other] - partner) > partner * 1e-6:
            continue
        shallow, deep = magnitudes[index], magnitudes[other]
        if shallow is None or deep is None:
            continue
        if shallow > entry_db or deep < floor_db:
            continue
        candidate = {
            "dbPerOct": round(shallow - deep, 3),
            "fromHz": freqs[index], "toHz": freqs[other],
        }
        # Deeper is better: the asymptote is what is wanted, not the knee.
        candidate["_deep"] = deep
        if best is None or deep < best["_deep"]:
            best = candidate
    if best is None:
        return None
    best.pop("_deep")
    return best


def parse_pair(text):
    parts = text.split(",")
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("a pair is MAIN,SUB,FC (1-based outputs)")
    return {"main": int(parts[0]) - 1, "sub": int(parts[1]) - 1, "fcHz": float(parts[2])}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--in", dest="input_path", required=True)
    parser.add_argument("--out", dest="output_path", required=True)
    parser.add_argument("--frames", type=int, default=16384)
    parser.add_argument("--lead", type=int, default=64)
    parser.add_argument("--amplitude", type=float, default=0.25)
    parser.add_argument("--rate", type=float, default=48000.0)
    parser.add_argument("--points", type=int, default=61)
    parser.add_argument("--pair", type=parse_pair, action="append", required=True,
                        help="MAIN,SUB,FC — 1-based output numbers and the crossover in Hz")
    parser.add_argument("--order", type=int, action="append", default=None,
                        help="Linkwitz-Riley order per --pair, for the analytic check")
    parser.add_argument("--model-floor", type=float, default=-80.0,
                        help="ignore the analytic comparison below this level (dB)")
    parser.add_argument("--slope-max-hz", type=float, default=None,
                        help="highest frequency the slope search may use (default rate/8)")
    arguments = parser.parse_args()

    pairs = arguments.pair
    orders = arguments.order or []
    slope_max_hz = arguments.slope_max_hz or arguments.rate / 8.0
    freqs = build_freqs(arguments.points, pairs)

    write_impulse(arguments.input_path, arguments.frames, arguments.amplitude, arguments.lead)
    Path(arguments.output_path).unlink(missing_ok=True)
    done = subprocess.run([arguments.camilladsp, arguments.config],
                          capture_output=True, text=True, timeout=900)
    if not Path(arguments.output_path).exists():
        print(done.stderr[-2000:], file=sys.stderr)
        return 1

    samples = read_f64(arguments.output_path)
    frames = min(arguments.frames, len(samples) // CHANNELS)
    floor = arguments.amplitude * 1e-12
    responses, result = [], {
        "freqs": freqs, "frames": frames, "channels": [],
        "usedFrames": [], "truncated": [],
    }
    for channel in range(CHANNELS):
        last = decay_point(samples, channel, frames, arguments.lead, floor)
        response = response_at(samples, channel, last, arguments.rate, freqs, arguments.lead)
        responses.append(response)
        result["usedFrames"].append(last - arguments.lead)
        # A response still ringing when the capture ends biases its own
        # magnitude low, worst at the frequencies that ring longest.
        tail = sum(abs(samples[n * CHANNELS + channel])
                   for n in range(max(arguments.lead, frames - 256), frames))
        result["truncated"].append(bool(tail / arguments.amplitude > 1e-9))
        result["channels"].append({
            "magDb": [to_db(abs(v), arguments.amplitude) for v in response],
            "phaseDeg": [wrap_deg(math.degrees(cmath.phase(v))) if abs(v) > 0 else None
                         for v in response],
        })
    if any(result["truncated"]):
        short = [i + 1 for i, v in enumerate(result["truncated"]) if v]
        result["warning"] = (f"Outputs {short} were still ringing at the end of the "
                             f"capture; re-run with more --frames.")
        print(result["warning"], file=sys.stderr)

    result["pairs"] = []
    for index, pair in enumerate(pairs):
        main_response = responses[pair["main"]]
        sub_response = responses[pair["sub"]]
        at_fc = nearest(freqs, pair["fcHz"])
        summed = [m + s for m, s in zip(main_response, sub_response)]
        sum_db = [to_db(abs(v), arguments.amplitude) for v in summed]
        # Judged over the audio band. The octaves outside it exist to give the
        # slope search somewhere to stand, not to be reported as the worst
        # place the two branches failed to sum.
        finite = [(f, v) for f, v in zip(freqs, sum_db)
                  if v is not None and 20.0 <= f <= 20000.0]
        # An allpass sum is the property being tested: deviation from 0 dB is
        # the whole result, and its worst value is the headline.
        worst = max(finite, key=lambda item: abs(item[1])) if finite else (None, None)
        lowest = min(finite, key=lambda item: item[1]) if finite else (None, None)
        entry = {
            "main": pair["main"] + 1, "sub": pair["sub"] + 1, "fcHz": pair["fcHz"],
            "mainAtFcDb": result["channels"][pair["main"]]["magDb"][at_fc],
            "subAtFcDb": result["channels"][pair["sub"]]["magDb"][at_fc],
            "phaseDiffAtFcDeg": wrap_deg(
                math.degrees(cmath.phase(main_response[at_fc]))
                - math.degrees(cmath.phase(sub_response[at_fc]))),
            "sumDb": sum_db,
            "sumWorstDevDb": worst[1], "sumWorstDevAtHz": worst[0],
            "sumMinDb": lowest[1], "sumMinAtHz": lowest[0],
            "mainSlope": asymptotic_slope(
                freqs, result["channels"][pair["main"]]["magDb"],
                pair["fcHz"], "highpass", slope_max_hz),
            "subSlope": asymptotic_slope(
                freqs, result["channels"][pair["sub"]]["magDb"],
                pair["fcHz"], "lowpass", slope_max_hz),
        }
        if index < len(orders):
            order = orders[index]
            entry["order"] = order
            for kind, which in (("highpass", "main"), ("lowpass", "sub")):
                model = linkwitz_riley(kind, pair["fcHz"], order, arguments.rate, freqs)
                if model is None:
                    continue
                measured = result["channels"][pair[which]]["magDb"]
                # Only where the model says there is something to compare.
                # Two implementations of the same filter agree on its passband
                # and its knee; 140 dB down they differ by whatever rounding
                # each accumulated, and comparing there measures arithmetic.
                deviations, compared = [], []
                for freq_hz, magnitude, value in zip(freqs, measured, model):
                    model_db = to_db(abs(value), 1.0)
                    if magnitude is None or model_db is None or model_db < arguments.model_floor:
                        continue
                    deviations.append(abs(magnitude - model_db))
                    compared.append(freq_hz)
                entry[f"{which}ModelMaxDevDb"] = round(max(deviations), 4) if deviations else None
                entry[f"{which}ModelPoints"] = len(compared)
        result["pairs"].append(entry)

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
