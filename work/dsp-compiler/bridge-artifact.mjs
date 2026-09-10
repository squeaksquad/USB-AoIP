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

const CAMILLA_BAND_TYPE = {Peaking: 'bell', Lowshelf: 'lowShelf', Highshelf: 'highShelf'};
const ORDER_SLOPE = {2: 12, 4: 24, 8: 48};

/** JavaScript's default number formatting round-trips exactly; keep it. */
const number = value => String(value);
const linear = source =>
  10 ** (source.gain / 20) * (source.inverted ? -1 : 1);

function sectionsFor(filter) {
  if (filter.type === 'Biquad') {
    const {type, freq, q, gain} = filter.parameters;
    const band = CAMILLA_BAND_TYPE[type];
    if (band === undefined) throw new Error(`Unknown biquad type ${type}`);
    return [bandBiquad({type: band, frequency: freq, q, gainDb: gain})];
  }
  if (filter.type === 'BiquadCombo') {
    const {type, freq, order} = filter.parameters;
    const slope = ORDER_SLOPE[order];
    if (slope === undefined) throw new Error(`Unsupported crossover order ${order}`);
    if (type === 'LinkwitzRileyHighpass') return crossoverBiquads('highpass', freq, slope);
    if (type === 'LinkwitzRileyLowpass') return crossoverBiquads('lowpass', freq, slope);
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
 *     rate 48000 / channels 16 / internal N / maxdelay 480
 *     expand N        then N rows of  DEST SRC GAIN
 *     branch N        then N of       CHANNEL SECTIONS  + SECTIONS coefficient rows
 *     assign N        then N rows of  DEST SRC GAIN
 *     output 16       then 16 of      OUT DELAY GAIN SECTIONS + coefficient rows
 *     end
 */
export function bridgeArtifact(result, {presetName} = {}) {
  const {config, plan} = result;
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
    const sections = names.flatMap(name => sectionsFor(config.filters[name]));
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
        sections.push(...sectionsFor(filter));
      }
    }
    if (delay > MAX_DELAY_SAMPLES) {
      throw new Error(`Output ${output + 1} asks for ${delay} samples of delay, over the ${MAX_DELAY_SAMPLES} ceiling`);
    }
    outputs.push({output, delay, gain, sections});
  }

  lines.push(`usb16x16-dsp ${ARTIFACT_VERSION}`);
  lines.push(`preset ${presetName ?? config.title}`);
  lines.push(`rate ${config.devices.samplerate}`);
  lines.push(`channels ${config.mixers.expand.channels.in}`);
  lines.push(`internal ${plan.channels.length}`);
  lines.push(`maxdelay ${MAX_DELAY_SAMPLES}`);
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
 * The latency the alignment delays add, and what to tell the user about it.
 *
 * Per-output delays are relative to each other, but the transport has to carry
 * the largest of them: the system's output is not complete until its most
 * delayed channel has been produced. So the cost is the maximum, not the sum
 * and not the average, and it is paid as soon as any delay is non-zero.
 */
export function delayLatency(config) {
  const samples = Math.max(0, ...config.outputs.map(
    output => Math.round(output.delayMs / 1000 * 48000)));
  return {
    samples,
    ms: Number((samples / 48).toFixed(3)),
    text: samples === 0 ? null
      : `Alignment delay adds ${(samples / 48).toFixed(2)} ms of latency to every `
        + 'output, not just the delayed ones: the largest delay you have set is '
        + 'what the transport has to carry. Set it to zero everywhere to get '
        + 'that back.',
  };
}
