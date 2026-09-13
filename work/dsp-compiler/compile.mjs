// Preset -> CamillaDSP configuration.
//
// The UI preset is the source of truth and stays independent of CamillaDSP's
// schema; this module is the only place the two meet. It is pure: it takes a
// validated preset and returns a configuration object plus a report. It never
// reads a file, touches a device, or decides to apply anything.
//
// Signal flow, matching work/web-ui/README.md:
//
//   16 capture channels
//     -> expand mixer: headroom trim, one internal channel per needed branch
//        main branch  = input i, later high-passed
//        bass branch  = input i, later low-passed (LFE uses its own LP + trim)
//        phones branch= input pair member, or a downmix sum, full range
//     -> branch filters: the crossover. These are separate from the user's
//        output PEQ, so a crossover never consumes one of the 16 bands.
//     -> assign mixer: internal channels -> the 16 physical outputs, applying
//        sub send gains and bus level/mute
//     -> output filters: 16 PEQ bands, alignment delay, gain/polarity/mute
//     -> 16 playback channels
//
// Headroom policy: config.headroomDb is applied exactly once, in the expand
// mixer, to every branch of every input. Nothing downstream re-applies it. Sub
// sends, bus gain and output gain are all applied after it, so a preset can
// still be driven into clipping; worstCaseDbfs in the report says by how much,
// for coherent full-scale inputs.
//
// Two emission shapes (LIVE_COEFFICIENTS_DESIGN.md). `minimal`, the default,
// emits only what changes the audio: a flat band, a bypassed high-pass, a muted
// bus and an empty downmix cell are absent. `fixed` emits the same audio in a
// shape that depends on the routing alone, so that a value edit changes only
// numbers in the artifact: every band of every output is present (a unity
// section when it does nothing), a switched-off high-pass is a unity chain of
// its slope's length, a muted bus or output keeps its rows at gain zero, and
// every send a branch can make to a sub is a row, muted when the preset has
// none. Bass redirection off is, in the fixed shape, the same pipeline with
// every main high-pass at unity and every non-LFE sub send muted, so the
// toggle is a live edit. What the fixed shape does *not* pad, because it would
// cost sections the soak never licensed: which branches exist (an input's
// first send, or its last one removed, is still a shape change) and crossover
// order at 48 dB/oct. Both shapes run the same audio; the harnesses verify the
// minimal one and the artifact test proves the fixed one says the same thing.

import { CHANNELS, validateConfig } from '../web-ui/model.mjs';
import { polarityWarningText } from '../web-ui/crossover-notes.mjs';

export const SAMPLE_RATE = 48000;

// Linkwitz-Riley order is twice the Butterworth order: 12 dB/oct is order 2.
const SLOPE_ORDER = {12: 2, 24: 4, 48: 8};
// Sections the artifact emits per crossover of each slope (coefficients.mjs:
// a Butterworth of order N/2 applied twice, one section per pole pair or pole).
const SLOPE_SECTIONS = {12: 2, 24: 2, 48: 4};
const BIQUAD_TYPE = {bell: 'Peaking', lowShelf: 'Lowshelf', highShelf: 'Highshelf'};

const round = (value, places = 6) => Number(value.toFixed(places));
const dbToLinear = db => 10 ** (db / 20);

/** A band that changes nothing is not worth a biquad. */
function bandIsFlat(band) {
  return !band.enabled || band.gainDb === 0;
}

export const SHAPES = ['minimal', 'fixed'];

/** The unity section the fixed shape holds a slot with. CamillaDSP's `Free`
 *  biquad takes explicit coefficients, so both serialisations agree exactly. */
function unityBiquad() {
  return {type: 'Biquad', parameters: {type: 'Free', b0: 1, b1: 0, b2: 0, a1: 0, a2: 0}};
}

function busOf(config, outputIndex) {
  return config.buses.find(bus => bus.outputIds.includes(outputIndex)) ?? null;
}

/**
 * Decide which internal channels the pipeline needs.
 *
 * Only branches something downstream actually consumes are allocated, so a
 * preset using four inputs does not pay for sixteen main branches and sixteen
 * bass branches. The returned plan is stable and is emitted into the config as
 * comments, so the channel map is auditable against the YAML.
 */
export function planChannels(config, fixed = false) {
  const channels = [];
  const mainOf = new Map();     // input index -> internal channel
  const bassOf = new Map();     // input index -> internal channel
  const phonesOf = new Map();   // `${busId}:${ear}` -> internal channel

  const allocate = entry => { channels.push(entry); return channels.length - 1; };

  for (let output = 0; output < CHANNELS; output += 1) {
    const spec = config.outputs[output];
    if (spec.role === 'unused') continue;
    const bus = busOf(config, output);
    if (bus?.kind === 'headphones') {
      const ear = bus.outputIds.indexOf(output);
      const key = `${bus.id}:${ear}`;
      if (!phonesOf.has(key)) phonesOf.set(key, allocate({kind: 'phones', busId: bus.id, ear}));
      continue;
    }
    if (spec.role === 'speaker' && !mainOf.has(spec.source)) {
      mainOf.set(spec.source, allocate({kind: 'main', input: spec.source}));
    }
  }

  // A bass branch exists for an input only if some enabled send carries it.
  for (let input = 0; input < CHANNELS; input += 1) {
    const isLfe = input === config.lfe.input;
    // Fixed shape: the branch stays when bass redirection is off (its sends
    // are muted), so the toggle changes numbers only.
    if (!config.bassEnabled && !isLfe && !fixed) continue;
    const sends = config.sends[input];
    const used = sends.some((gain, output) =>
      gain !== null && config.outputs[output].role === 'sub');
    if (used && !bassOf.has(input)) {
      bassOf.set(input, allocate({kind: 'bass', input, lfe: isLfe}));
    }
  }
  return {channels, mainOf, bassOf, phonesOf};
}

/** The expand mixer: capture channels into branch channels, with headroom. */
function expandMixer(config, plan, fixed) {
  const mapping = plan.channels.map((channel, dest) => {
    if (channel.kind === 'phones') {
      const bus = config.buses.find(value => value.id === channel.busId);
      if (bus.inputMode === 'pair') {
        return {dest, sources: [source(bus.inputPair[channel.ear], config.headroomDb)]};
      }
      const sources = [];
      bus.downmixMatrix.forEach((row, input) => {
        const gain = row[channel.ear];
        if (gain !== null) sources.push(source(input, config.headroomDb + gain));
        else if (fixed) sources.push(muted(input));
      });
      // An ear with no contributions is silent, not an error: the UI allows it.
      return {dest, sources};
    }
    // The LFE trim belongs to the LFE branch and is applied once, here.
    const trim = channel.kind === 'bass' && channel.lfe ? config.lfe.trimDb : 0;
    return {dest, sources: [source(channel.input, config.headroomDb + trim)]};
  });
  return {channels: {in: CHANNELS, out: plan.channels.length}, mapping};
}

function source(channel, gainDb, inverted = false) {
  return {channel, gain: round(gainDb, 4), inverted, scale: 'dB'};
}

/** A row that exists so the shape does, contributing nothing. */
function muted(channel) {
  return {channel, gain: 0, inverted: false, mute: true, scale: 'dB'};
}

/** Crossover filters, one set per branch channel that needs them. */
function branchFilters(config, plan, filters, fixed) {
  const steps = [];
  for (const [index, channel] of plan.channels.entries()) {
    const names = [];
    if (channel.kind === 'main') {
      const input = config.inputs[channel.input];
      // Bass redirection off bypasses every main high-pass, retaining the draft.
      if (config.bassEnabled && input.crossover) {
        const name = `hp_in${channel.input + 1}`;
        filters[name] = {
          type: 'BiquadCombo',
          parameters: {type: 'LinkwitzRileyHighpass', freq: input.highpassHz, order: SLOPE_ORDER[input.slope]},
        };
        names.push(name);
      } else if (fixed) {
        // The high-pass is off, or bass redirection is: hold its slots with
        // unity sections, as many as the slope would take, so switching it
        // on is a coefficient change.
        for (let section = 0; section < SLOPE_SECTIONS[input.slope]; section += 1) {
          const name = `hp_in${channel.input + 1}_off${section + 1}`;
          filters[name] = unityBiquad();
          names.push(name);
        }
      }
    } else if (channel.kind === 'bass') {
      const name = `lp_in${channel.input + 1}`;
      const {lowpassHz, slope} = channel.lfe
        ? {lowpassHz: config.lfe.lowpassHz, slope: config.lfe.slope}
        : config.inputs[channel.input];
      filters[name] = {
        type: 'BiquadCombo',
        parameters: {type: 'LinkwitzRileyLowpass', freq: lowpassHz, order: SLOPE_ORDER[slope]},
      };
      names.push(name);
    }
    if (names.length) steps.push({type: 'Filter', channels: [index], names});
  }
  return steps;
}

/** The assign mixer: branch channels into the 16 physical outputs. */
function assignMixer(config, plan, fixed) {
  const mapping = [];
  for (let output = 0; output < CHANNELS; output += 1) {
    const spec = config.outputs[output];
    const bus = busOf(config, output);
    const busGain = bus?.gainDb ?? 0;
    // The fixed shape keeps a muted bus's rows and mutes each source instead,
    // which CamillaDSP treats the same and the artifact can hold at zero.
    const busMute = Boolean(bus?.mute);
    const entry = {dest: output, mute: busMute && !fixed, sources: []};
    const push = row => entry.sources.push(fixed && busMute ? {...row, mute: true} : row);
    if (spec.role === 'unused' || !bus) {
      // No sources: CamillaDSP writes silence. Kept in the mapping so the
      // channel is explicitly accounted for rather than absent.
      mapping.push(entry);
      continue;
    }
    if (bus.kind === 'headphones') {
      const channel = plan.phonesOf.get(`${bus.id}:${bus.outputIds.indexOf(output)}`);
      push(source(channel, busGain));
    } else if (spec.role === 'speaker') {
      push(source(plan.mainOf.get(spec.source), busGain));
    } else if (spec.role === 'sub') {
      config.sends.forEach((row, input) => {
        const gain = row[output];
        const channel = plan.bassOf.get(input);
        // Bass redirection off leaves only the LFE branch feeding the subs.
        if (channel === undefined) return;
        const carried = gain !== null && (config.bassEnabled || input === config.lfe.input);
        if (carried) push(source(channel, busGain + gain));
        // A branch that exists can reach every sub: hold the row, muted.
        else if (fixed) push(muted(channel));
      });
    }
    mapping.push(entry);
  }
  return {channels: {in: plan.channels.length, out: CHANNELS}, mapping};
}

/** Per-output PEQ, alignment delay, gain, polarity and mute. */
function outputFilters(config, filters, fixed) {
  const steps = [];
  for (let output = 0; output < CHANNELS; output += 1) {
    const spec = config.outputs[output];
    const names = [];
    const eqActive = spec.eqEnabled && !config.eqBypass;
    if (eqActive || fixed) {
      spec.bands.forEach((band, index) => {
        const name = `eq_out${output + 1}_b${index + 1}`;
        if (!eqActive || bandIsFlat(band)) {
          // Fixed shape: the slot stays, at unity, so enabling the band or
          // moving its gain off zero changes coefficients and nothing else.
          if (fixed) { filters[name] = unityBiquad(); names.push(name); }
          return;
        }
        filters[name] = {
          type: 'Biquad',
          parameters: {
            type: BIQUAD_TYPE[band.type],
            freq: band.frequency,
            q: band.q,
            gain: band.gainDb,
          },
        };
        names.push(name);
      });
    }
    // Whole-sample delay is the first engine implementation, per the README.
    const samples = Math.round(spec.delayMs / 1000 * SAMPLE_RATE);
    if (samples > 0) {
      const name = `delay_out${output + 1}`;
      filters[name] = {
        type: 'Delay',
        parameters: {delay: samples, unit: 'samples', subsample: false},
      };
      names.push(name);
    }
    if (spec.gainDb !== 0 || spec.invert || spec.mute) {
      const name = `gain_out${output + 1}`;
      filters[name] = {
        type: 'Gain',
        parameters: {gain: spec.gainDb, inverted: spec.invert, mute: spec.mute, scale: 'dB'},
      };
      names.push(name);
    }
    if (names.length) steps.push({type: 'Filter', channels: [output], names});
  }
  return steps;
}

/**
 * Coherent worst-case level at each output, in dBFS, for full-scale inputs.
 *
 * A sum of magnitudes, not a measured or true-peak figure: it ignores filter
 * response, phase and the fact that real content is not coherent. It is a
 * ceiling, so an output it calls safe cannot clip from summing alone.
 */
function worstCase(config, plan) {
  return config.outputs.map((spec, output) => {
    const bus = busOf(config, output);
    if (spec.role === 'unused' || !bus || spec.mute || bus.mute) return null;
    let linear = 0;
    if (bus.kind === 'headphones') {
      const ear = bus.outputIds.indexOf(output);
      if (bus.inputMode === 'pair') linear = dbToLinear(config.headroomDb);
      else {
        bus.downmixMatrix.forEach(row => {
          if (row[ear] !== null) linear += dbToLinear(config.headroomDb + row[ear]);
        });
      }
    } else if (spec.role === 'speaker') {
      linear = dbToLinear(config.headroomDb);
    } else {
      config.sends.forEach((row, input) => {
        if (row[output] === null || !plan.bassOf.has(input)) return;
        const trim = input === config.lfe.input ? config.lfe.trimDb : 0;
        linear += dbToLinear(config.headroomDb + trim + row[output]);
      });
    }
    if (linear === 0) return null;
    return round(20 * Math.log10(linear) + (bus.gainDb ?? 0) + spec.gainDb, 2);
  });
}

/** Things the compiler will not silently decide for the user. */
function collectWarnings(config, plan, levels) {
  const warnings = [];
  // Shared with the UI so the two cannot drift, and so the LFE branch is scored
  // on the LFE low-pass slope rather than its input's.
  const polarity = polarityWarningText(config);
  if (polarity) warnings.push(polarity);
  levels.forEach((level, output) => {
    if (level !== null && level > 0) {
      warnings.push(
        `Output ${output + 1} (${config.outputs[output].label}) can reach ` +
        `${level.toFixed(2)} dBFS from coherent full-scale inputs. Lower the ` +
        'send gains, the output gain, or the headroom trim.');
    }
  });
  if (!config.bassEnabled) {
    warnings.push('Bass redirection is off: main high-passes are bypassed and only ' +
                  'the LFE branch feeds the subwoofer outputs.');
  }
  if (config.eqBypass) {
    warnings.push('Global EQ bypass is on: no output PEQ band was emitted. Band ' +
                  'values are retained in the preset.');
  }
  const muted = config.outputs
    .map((spec, index) => (spec.mute ? index + 1 : null))
    .filter(index => index !== null);
  if (muted.length) warnings.push(`Muted outputs: ${muted.join(', ')}.`);
  return warnings;
}

export function fileDevices(inputPath, outputPath, format = 'S32_LE', chunksize = 1024) {
  return {
    samplerate: SAMPLE_RATE,
    chunksize,
    capture: {type: 'RawFile', filename: inputPath, channels: CHANNELS, format},
    playback: {type: 'File', filename: outputPath, channels: CHANNELS, format},
  };
}

export function alsaDevices(captureDevice, playbackDevice, format = 'S24_3_LE', chunksize = 1024) {
  return {
    samplerate: SAMPLE_RATE,
    chunksize,
    capture: {type: 'Alsa', device: captureDevice, channels: CHANNELS, format},
    playback: {type: 'Alsa', device: playbackDevice, channels: CHANNELS, format},
  };
}

/**
 * Compile a validated preset into a CamillaDSP configuration.
 *
 * Returns {config, plan, report}. `devices` must be supplied by the caller:
 * choosing capture and playback devices is an integration decision this
 * compiler has no basis to make.
 */
export function compile(preset, devices, {shape = 'minimal'} = {}) {
  if (!SHAPES.includes(shape)) throw new Error(`Unknown shape ${shape}; use ${SHAPES.join(' or ')}`);
  const fixed = shape === 'fixed';
  const config = validateConfig(structuredClone(preset));
  if (config.mode !== 'dsp') {
    throw new Error('Direct mode has no DSP path to compile. Switch the preset to DSP mode.');
  }
  if (!devices) throw new Error('Supply a devices section (fileDevices or alsaDevices)');

  const plan = planChannels(config, fixed);
  if (!plan.channels.length) {
    throw new Error('This preset routes nothing: every output is unused or unassigned.');
  }
  const filters = {};
  const mixers = {expand: expandMixer(config, plan, fixed), assign: assignMixer(config, plan, fixed)};
  const pipeline = [
    {type: 'Mixer', name: 'expand'},
    ...branchFilters(config, plan, filters, fixed),
    {type: 'Mixer', name: 'assign'},
    ...outputFilters(config, filters, fixed),
  ];
  const levels = worstCase(config, plan);

  const camilla = {
    title: config.name,
    description:
      `Compiled from USB 16x16 preset "${config.name}" (version ${config.version}). ` +
      `Headroom ${config.headroomDb} dB applied once in the expand mixer.` +
      (fixed ? ' Fixed shape: unity sections and muted rows hold slots for live coefficient updates.' : ''),
    devices,
    filters,
    mixers,
    pipeline,
  };

  return {
    config: camilla,
    plan,
    report: {
      preset: config.name,
      shape,
      internalChannels: plan.channels.length,
      channelMap: plan.channels.map((channel, index) => ({index, ...channel})),
      filterCount: Object.keys(filters).length,
      // Bands that shape the audio; the fixed shape's unity placeholders are
      // counted apart so a summary can say "N of 256 active".
      biquadCount: Object.values(filters).filter(f => f.type === 'Biquad' && f.parameters.type !== 'Free').length,
      placeholderCount: Object.values(filters).filter(f => f.type === 'Biquad' && f.parameters.type === 'Free').length,
      crossoverCount: Object.values(filters).filter(f => f.type === 'BiquadCombo').length,
      headroomDb: config.headroomDb,
      worstCaseDbfs: levels,
      warnings: collectWarnings(config, plan, levels),
    },
  };
}
