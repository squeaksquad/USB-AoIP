// The compiled pipeline as something the bridge can load.
//
// The bridge is a real-time C++ process. Handing it YAML would mean a parser
// and a dependency on the audio host for no benefit, so it gets a flat,
// line-oriented artifact instead: counts, then rows, then coefficients.
//
// This is emitted from the *compiled CamillaDSP configuration object*, not from
// the preset a second time. The two outputs are therefore one pipeline
// serialised twice rather than two compilations that have to be kept in step,
// which is what lets the bridge's filtering be checked against CamillaDSP
// sample for sample on the same preset and mean something.
//
// Everything the engine expresses as a dB gain and a polarity flag becomes one
// signed linear gain here, and a mute becomes a gain of zero: the bridge should
// multiply, not branch, on the audio path.

import { bandBiquad, crossoverBiquads } from './coefficients.mjs';

export const ARTIFACT_VERSION = 1;
// 10 ms at 48 kHz, the alignment delay ceiling model.mjs validates against.
export const MAX_DELAY_SAMPLES = 480;
/** The same 10 ms at any rate; DspStage::max_delay_samples in the bridge. */
export const maxDelaySamples = rate => rate / 100;

const CAMILLA_BAND_TYPE = {Peaking: 'bell', Lowshelf: 'lowShelf', Highshelf: 'highShelf'};
const ORDER_SLOPE = {2: 12, 4: 24, 8: 48};

/** JavaScript's default number formatting round-trips exactly; keep it. */
const number = value => String(value);
const linear = source =>
  source.mute ? 0 : 10 ** (source.gain / 20) * (source.inverted ? -1 : 1);

function sectionsFor(filter, rate) {
  if (filter.type === 'Biquad') {
    const {type, freq, q, gain} = filter.parameters;
    if (type === 'Free') {
      // Explicit coefficients: the fixed shape's unity placeholder. Taken as
      // written so the two serialisations cannot disagree on a slot.
      const {b0, b1, b2, a1, a2} = filter.parameters;
      return [{b0, b1, b2, a1, a2}];
    }
    const band = CAMILLA_BAND_TYPE[type];
    if (band === undefined) throw new Error(`Unknown biquad type ${type}`);
    return [bandBiquad({type: band, frequency: freq, q, gainDb: gain}, rate)];
  }
  if (filter.type === 'BiquadCombo') {
    const {type, freq, order} = filter.parameters;
    const slope = ORDER_SLOPE[order];
    if (slope === undefined) throw new Error(`Unsupported crossover order ${order}`);
    if (type === 'LinkwitzRileyHighpass') return crossoverBiquads('highpass', freq, slope, rate);
    if (type === 'LinkwitzRileyLowpass') return crossoverBiquads('lowpass', freq, slope, rate);
    throw new Error(`Unknown combo type ${type}`);
  }
  throw new Error(`Filter type ${filter.type} has no biquad form`);
}

/** The pipeline's filter steps, split by the assign mixer that separates the
 *  two channel numberings. Before it the indices are internal channels; after
 *  it they are physical outputs. */
function filterSteps(config) {
  const assignAt = config.pipeline.findIndex(
    step => step.type === 'Mixer' && step.name === 'assign');
  const collect = steps => {
    const byChannel = new Map();
    for (const step of steps) {
      if (step.type !== 'Filter') continue;
      for (const channel of step.channels) {
        const existing = byChannel.get(channel) ?? [];
        byChannel.set(channel, [...existing, ...step.names]);
      }
    }
    return byChannel;
  };
  return {
    branch: collect(config.pipeline.slice(0, assignAt)),
    output: collect(config.pipeline.slice(assignAt + 1)),
  };
}

/**
 * Serialise a `compile()` result as the bridge's coefficient artifact.
 *
 * Layout, one record per line, counts before rows so the loader can size every
 * allocation once and never grow anything afterwards:
 *
 *     usb16x16-dsp 1
 *     rate R / channels 16 / internal N / maxdelay R/100   (48000 and 480 at 48 kHz)
 *     expand N        then N rows of  DEST SRC GAIN
 *     branch N        then N of       CHANNEL SECTIONS  + SECTIONS coefficient rows
 *     assign N        then N rows of  DEST SRC GAIN
 *     output 16       then 16 of      OUT DELAY GAIN SECTIONS + coefficient rows
 *     end
 */
export function bridgeArtifact(result, {presetName} = {}) {
  const {config, plan} = result;
  // Coefficients for the rate the pipeline was compiled at, which the artifact
  // names and the bridge checks against the rate it runs at.
  const rate = config.devices.samplerate;
  const maxDelay = maxDelaySamples(rate);
  const steps = filterSteps(config);
  const lines = [];

  const expand = [];
  for (const entry of config.mixers.expand.mapping) {
    for (const source of entry.sources) {
      expand.push(`${entry.dest} ${source.channel} ${number(linear(source))}`);
    }
  }
  const assign = [];
  for (const entry of config.mixers.assign.mapping) {
    if (entry.mute) continue;                 // a muted bus contributes nothing
    for (const source of entry.sources) {
      assign.push(`${entry.dest} ${source.channel} ${number(linear(source))}`);
    }
  }

  const branch = [];
  let branchCount = 0;
  for (const [channel, names] of [...steps.branch.entries()].sort((a, b) => a[0] - b[0])) {
    const sections = names.flatMap(name => sectionsFor(config.filters[name], rate));
    if (!sections.length) continue;
    branchCount += 1;
    branch.push(`${channel} ${sections.length}`);
    for (const s of sections) {
      branch.push([s.b0, s.b1, s.b2, s.a1, s.a2].map(number).join(' '));
    }
  }

  const outputs = [];
  for (let output = 0; output < config.mixers.assign.channels.out; output += 1) {
    const names = steps.output.get(output) ?? [];
    const sections = [];
    let delay = 0;
    let gain = 1;
    for (const name of names) {
      const filter = config.filters[name];
      if (filter.type === 'Delay') {
        if (filter.parameters.unit !== 'samples') {
          throw new Error('The bridge takes whole-sample delays only');
        }
        delay += filter.parameters.delay;
      } else if (filter.type === 'Gain') {
        gain *= filter.parameters.mute ? 0 : linear(filter.parameters);
      } else {
        sections.push(...sectionsFor(filter, rate));
      }
    }
    if (delay > maxDelay) {
      throw new Error(`Output ${output + 1} asks for ${delay} samples of delay, over the ${maxDelay} ceiling`);
    }
    outputs.push({output, delay, gain, sections});
  }

  lines.push(`usb16x16-dsp ${ARTIFACT_VERSION}`);
  lines.push(`preset ${presetName ?? config.title}`);
  lines.push(`rate ${rate}`);
  lines.push(`channels ${config.mixers.expand.channels.in}`);
  lines.push(`internal ${plan.channels.length}`);
  lines.push(`maxdelay ${maxDelay}`);
  lines.push(`expand ${expand.length}`, ...expand);
  lines.push(`branch ${branchCount}`, ...branch);
  lines.push(`assign ${assign.length}`, ...assign);
  lines.push(`output ${outputs.length}`);
  for (const entry of outputs) {
    lines.push(`${entry.output} ${entry.delay} ${number(entry.gain)} ${entry.sections.length}`);
    for (const s of entry.sections) {
      lines.push([s.b0, s.b1, s.b2, s.a1, s.a2].map(number).join(' '));
    }
  }
  lines.push('end');
  return `${lines.join('\n')}\n`;
}

/**
 * The shape of an artifact: everything in it that is a count or an index, with
 * every gain, delay and coefficient blanked. Two artifacts with the same shape
 * describe the same allocation in the bridge and differ only in numbers, which
 * is exactly what a running `DspStage` can take without a restart
 * (LIVE_COEFFICIENTS_DESIGN.md). Delay is a value here, not shape: the delay
 * lines are sized at the ceiling regardless.
 *
 * Returns the canonical shape text. The same text is what the applier hashes
 * in Python and the bridge derives in C++; `artifactShapeKey` is its SHA-256,
 * and the test pins one vector so all three implementations must agree.
 */
export function artifactShape(text) {
  const lines = text.split('\n').map(line => line.trim()).filter(Boolean);
  let at = 0;
  const next = () => {
    if (at >= lines.length) throw new Error('artifact shape: unexpected end');
    return lines[at++];
  };
  const words = line => line.split(/\s+/);
  const header = (keyword, arity = 1) => {
    const parts = words(next());
    if (parts[0] !== keyword || parts.length !== arity + 1) {
      throw new Error(`artifact shape: expected '${keyword}', found '${parts.join(' ')}'`);
    }
    return parts.slice(1);
  };
  const counted = keyword => {
    const [count] = header(keyword);
    if (!/^\d+$/.test(count)) throw new Error(`artifact shape: ${keyword} count '${count}'`);
    return Number(count);
  };
  const out = [];
  const [version] = header('usb16x16-dsp');
  if (version !== String(ARTIFACT_VERSION)) throw new Error(`artifact shape: version ${version}`);
  out.push(`usb16x16-dsp-shape ${ARTIFACT_VERSION}`);
  // The preset name is not shape.
  if (!next().startsWith('preset')) throw new Error("artifact shape: expected 'preset'");
  out.push(`rate ${header('rate')[0]}`);
  out.push(`channels ${header('channels')[0]}`);
  out.push(`internal ${header('internal')[0]}`);
  out.push(`maxdelay ${header('maxdelay')[0]}`);
  const mix = keyword => {
    const rows = counted(keyword);
    out.push(`${keyword} ${rows}`);
    for (let row = 0; row < rows; row += 1) {
      const [dest, source, gain, ...extra] = words(next());
      if (gain === undefined || extra.length) throw new Error(`artifact shape: ${keyword} row ${row + 1}`);
      out.push(`${dest} ${source}`);
    }
  };
  const skipSections = count => { for (let i = 0; i < count; i += 1) next(); };
  mix('expand');
  const branches = counted('branch');
  out.push(`branch ${branches}`);
  for (let row = 0; row < branches; row += 1) {
    const [channel, sections, ...extra] = words(next());
    if (sections === undefined || extra.length) throw new Error(`artifact shape: branch row ${row + 1}`);
    out.push(`${channel} ${sections}`);
    skipSections(Number(sections));
  }
  mix('assign');
  // Always all 16 outputs in index order, whatever the artifact listed: the
  // bridge keeps one spec per output, and its shape text is written from
  // those (bridge_core.cpp, shape_text), so the two agree on every artifact.
  const outputs = counted('output');
  const perOutput = new Array(16).fill(0);
  for (let row = 0; row < outputs; row += 1) {
    const [index, delay, gain, sections, ...extra] = words(next());
    if (sections === undefined || extra.length || !(Number(index) < 16)) throw new Error(`artifact shape: output row ${row + 1}`);
    perOutput[Number(index)] = Number(sections);
    skipSections(Number(sections));
  }
  out.push('output 16');
  perOutput.forEach((sections, index) => out.push(`${index} ${sections}`));
  if (next() !== 'end' || at !== lines.length) throw new Error("artifact shape: expected 'end'");
  out.push('end');
  return `${out.join('\n')}\n`;
}

/**
 * SHA-256 as lower-case hex. WebCrypto when the page has it; otherwise a plain
 * implementation (FIPS 180-4), because the appliance page is served over
 * plain HTTP from the Pi's address, which browsers treat as an insecure
 * context where `crypto.subtle` does not exist.
 */
export async function sha256Hex(text) {
  const bytes = new TextEncoder().encode(text);
  const subtle = globalThis.crypto?.subtle;
  if (subtle) {
    const digest = await subtle.digest('SHA-256', bytes);
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }
  return sha256HexSync(bytes);
}

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);

/** Synchronous SHA-256 over bytes (Uint8Array), lower-case hex. */
export function sha256HexSync(bytes) {
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  const length = bytes.length;
  const padded = new Uint8Array(((length + 9 + 63) >> 6) << 6);
  padded.set(bytes);
  padded[length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor((length * 8) / 0x100000000), false);
  view.setUint32(padded.length - 4, (length * 8) >>> 0, false);
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const w = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i += 1) w[i] = view.getUint32(offset + i * 4, false);
    for (let i = 16; i < 64; i += 1) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i += 1) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + s1 + ch + K[i] + w[i]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (s0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }
  return [...h].map(word => word.toString(16).padStart(8, '0')).join('');
}

/** SHA-256 of the canonical shape text, lower-case hex. */
export async function artifactShapeKey(text) {
  return sha256Hex(artifactShape(text));
}

/**
 * The latency the alignment delays add, and what to tell the user about it.
 *
 * Per-output delays are relative to each other, but the transport has to carry
 * the largest of them: the system's output is not complete until its most
 * delayed channel has been produced. So the cost is the maximum, not the sum
 * and not the average, and it is paid as soon as any delay is non-zero.
 */
export function delayLatency(config, rate = 48000) {
  const samples = Math.max(0, ...config.outputs.map(
    output => Math.round(output.delayMs / 1000 * rate)));
  const perMs = rate / 1000;
  return {
    samples,
    ms: Number((samples / perMs).toFixed(3)),
    text: samples === 0 ? null
      : `Alignment delay adds ${(samples / perMs).toFixed(2)} ms of latency to every `
        + 'output, not just the delayed ones: the largest delay you have set is '
        + 'what the transport has to carry. Set it to zero everywhere to get '
        + 'that back.',
  };
}
