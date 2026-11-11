# Loaded event reference criterion v1

Status: implemented and verified locally and in one new 60-second preflight
and 600-second loaded soak. All three soak events matched (112 retained frames,
maximum error 1.5625 LSB). See
`outputs/dsp-service/reference-v1-live-20260911/RESULTS.md` for the separate TX
reserve decline and acceptance limits. Deliberately inserted silence and
missing/repeated frames in the earlier saved window are rejected. The service
test defaults to its legacy gate; the new criterion must be selected explicitly.

## Rule and scope

The criterion is limited to the pinned loaded preset (`2b6baa04`), bridge
(`406699bd`) and corresponding DSP core sources. It requires 48 kHz, all 16
returns, amplitude 0.1 and the declared deterministic generator/seed. Reference
generation runs locally after audio closes, using the actual DSP core, nearest
S24 input conversion, S32 output conversion and high-three-byte L24 conversion.
It regenerates the full candidate search interval, not a hand-selected event.

Each complete event window is aligned using its 16 preceding samples on an
independent channel, selected in channel order with at least 256 LSB of signal
range. Exactly one match must exist within the fixed 9,600-frame search bound.
One integer source/input offset must explain every channel and every event in
the run. There is no gain, polarity, per-channel delay or local time fitting.

All samples in all 16 retained channels must be within **2 L24 LSB** of the
reference. More strictly, the triggering zero run must have exactly the predicted
zero codes and nonzero boundaries; an unexpected zero cannot hide inside the
two-LSB comparison allowance. Missing/unfinished/truncated windows, omitted
events, ambiguous alignment, inconsistent metadata or unsupported inputs cannot
clear the gate. Exact Float32 bits are authoritative for sample comparison.

The two-LSB limit is a fixed diagnostic setting, informed by the saved window's
1.5625-LSB maximum difference and the conversion model. It is not a proven
worst-case bound for host conversion and filter error across arbitrary signals.
Do not fit it to each capture or enlarge it automatically on failure. A future
failure can indicate either a signal problem or insufficient reference accuracy;
retain its evidence for review.

This remains an **activity/stability criterion**, not whole-stream sample
verification. Every reported qualifying zero-run event must be explained, but
samples outside the retained windows are not compared. A run with no qualifying
events can satisfy the activity gate using the existing continuous statistics;
the reference checker reports zero waveform coverage. Missing/repeated samples
outside retained windows may escape detection unless another integrity check
catches them. Replacing samples with identical expected zeros is unobservable.
Full-stream integrity proof would require continuous capture or equivalent
continuous comparison; it is not claimed by this implementation.

Transport identities, binary/configuration checks, timestamp validity, frame
counts, sustained activity, nonfinite/full-scale checks, recovery/drop/clip/
low-queue/pitch counters and packet-lead checks remain in force. Queue-reserve
review, latency interpretation and final acceptance remain separate.

## Local replay and verification

```sh
python3 -m unittest discover -s work/dsp-service -p 'test_*.py' -v
python3 work/dsp-service/reference_check.py \
  --run outputs/dsp-service/event-capture-20260911/capture \
  --bundle outputs/dsp-service/review-20260911 \
  --output /private/tmp/usb16x16-reference-new-review
```

The output directory must be new. This builds the small C++ exporter and retains
the queried ranges, bounded reference data, source/binary/reference hashes and
`result.json`. No audio or network access occurs. `matched-events` means the
retained windows matched; `wholeRunValidated` remains false. Historical capture
and acceptance reports are never rewritten.

26 tests pass, including the saved live window, randomized multichannel fixtures,
silence insertion, missing/repeated frames, channel swaps, gain changes, strict
predicted-zero matching, alignment shifts, ambiguity, incomplete evidence,
source pins, stale criterion receipts and the validator's opt-in gate behavior.
Missing/repeated-frame tests update event length and timestamps consistently,
so they test signal comparison rather than merely malformed metadata.

Evidence: `outputs/dsp-service/reference-check-20260911/verified/result.json`,
`fault-verification.json` in the parent directory, and its final verification
record. The saved live case matches 39 frames with offset 989 and maximum raw
all-channel difference 1.5625 LSB. This does not retroactively pass the old run.

## Prospective service use

The first prospective campaign is complete; the following commands document
the procedure and are not an instruction to repeat it.

After playback coordination and selecting the loaded profile, obtain a **new**
60-second preflight with `--signal-criterion reference-events-v1`. Then select
that same option for one 600-second loaded soak. Example plans, without audio:

```sh
python3 work/dsp-service/validate.py \
  --bundle outputs/dsp-service/review-20260911 --arm loaded --phase preflight \
  --signal-criterion reference-events-v1 \
  --required-inputs 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 \
  --output outputs/dsp-service/reference-v1-live/preflight
python3 work/dsp-service/validate.py \
  --bundle outputs/dsp-service/review-20260911 --arm loaded --phase soak \
  --signal-criterion reference-events-v1 \
  --required-inputs 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 \
  --preflight outputs/dsp-service/reference-v1-live/preflight/summary.json \
  --output outputs/dsp-service/reference-v1-live/soak
```

`--execute` opens audio. Use fresh directories and the existing controlled
stop/switch/start/verify/restore procedure. Restore direct mode after the run,
including on failure. Do not rerun the historical capture wrapper: its old
source hashes intentionally no longer match the modified validator.

The preflight receipt binds the criterion definition, checker/exporter/validator
source hashes, bundle, harness, returns and service/bridge process. A legacy or
different-criterion receipt is refused. New summaries retain the selected
criterion, original zero-gate objections, reference verdict and explicit sample
coverage. No global relaxation of the zero threshold is introduced.
