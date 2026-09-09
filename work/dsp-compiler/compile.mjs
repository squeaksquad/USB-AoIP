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

import { CHANNELS, validateConfig } from '../web-ui/model.mjs';

export const SAMPLE_RATE = 48000;

// Linkwitz-Riley order is twice the Butterworth order: 12 dB/oct is order 2.
const SLOPE_ORDER = {12: 2, 24: 4, 48: 8};
const BIQUAD_TYPE = {bell: 'Peaking', lowShelf: 'Lowshelf', highShelf: 'Highshelf'};

const round = (value, places = 6) => Number(value.toFixed(places));
const dbToLinear = db => 10 ** (db / 20);

/** A band that changes nothing is not worth a biquad. */
function bandIsFlat(band) {
  return !band.enabled || band.gainDb === 0;
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
export function planChannels(config) {
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
    if (!config.bassEnabled && !isLfe) continue;
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
function expandMixer(config, plan) {
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

/** Crossover filters, one set per branch channel that needs them. */
function branchFilters(config, plan, filters) {
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
function assignMixer(config, plan) {
  const mapping = [];
  for (let output = 0; output < CHANNELS; output += 1) {
    const spec = config.outputs[output];
    const bus = busOf(config, output);
    const busGain = bus?.gainDb ?? 0;
    const entry = {dest: output, mute: Boolean(bus?.mute), sources: []};
    if (spec.role === 'unused' || !bus) {
      // No sources: CamillaDSP writes silence. Kept in the mapping so the
      // channel is explicitly accounted for rather than absent.
      mapping.push(entry);
      continue;
    }
    if (bus.kind === 'headphones') {
      const channel = plan.phonesOf.get(`${bus.id}:${bus.outputIds.indexOf(output)}`);
      entry.sources.push(source(channel, busGain));
    } else if (spec.role === 'speaker') {
      entry.sources.push(source(plan.mainOf.get(spec.source), busGain));
    } else if (spec.role === 'sub') {
      config.sends.forEach((row, input) => {
        const gain = row[output];
        if (gain === null) return;
        const channel = plan.bassOf.get(input);
        // Bass redirection off leaves only the LFE branch feeding the subs.
        if (channel === undefined) return;
        entry.sources.push(source(channel, busGain + gain));
      });
    }
    mapping.push(entry);
  }
  return {channels: {in: plan.channels.length, out: CHANNELS}, mapping};
}

/** Per-output PEQ, alignment delay, gain, polarity and mute. */
function outputFilters(config, filters) {
  const steps = [];
  for (let output = 0; output < CHANNELS; output += 1) {
    const spec = config.outputs[output];
    const names = [];
    if (spec.eqEnabled && !config.eqBypass) {
      spec.bands.forEach((band, index) => {
        if (bandIsFlat(band)) return;
        const name = `eq_out${output + 1}_b${index + 1}`;
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
  const slopes = new Set();
  config.inputs.forEach((input, index) => {
    if (config.bassEnabled && input.crossover) slopes.add(input.slope);
    if (plan.bassOf.has(index)) slopes.add(input.slope);
  });
  if (plan.bassOf.has(config.lfe.input)) slopes.add(config.lfe.slope);
  if (slopes.has(12)) {
    warnings.push(
      'A 12 dB/oct Linkwitz-Riley crossover puts its two branches 180 degrees ' +
      'apart at the crossover frequency, so main and sub usually need opposite ' +
      'polarity to sum. No polarity has been inverted for you: set it per output ' +
      'and verify acoustically.');
  }
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
export function compile(preset, devices) {
  const config = validateConfig(structuredClone(preset));
  if (config.mode !== 'dsp') {
    throw new Error('Direct mode has no DSP path to compile. Switch the preset to DSP mode.');
  }
  if (!devices) throw new Error('Supply a devices section (fileDevices or alsaDevices)');

  const plan = planChannels(config);
  if (!plan.channels.length) {
    throw new Error('This preset routes nothing: every output is unused or unassigned.');
  }
  const filters = {};
  const mixers = {expand: expandMixer(config, plan), assign: assignMixer(config, plan)};
  const pipeline = [
    {type: 'Mixer', name: 'expand'},
    ...branchFilters(config, plan, filters),
    {type: 'Mixer', name: 'assign'},
    ...outputFilters(config, filters),
  ];
  const levels = worstCase(config, plan);

  const camilla = {
    title: config.name,
    description:
      `Compiled from USB 16x16 preset "${config.name}" (version ${config.version}). ` +
      `Headroom ${config.headroomDb} dB applied once in the expand mixer.`,
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
      internalChannels: plan.channels.length,
      channelMap: plan.channels.map((channel, index) => ({index, ...channel})),
      filterCount: Object.keys(filters).length,
      biquadCount: Object.values(filters).filter(f => f.type === 'Biquad').length,
      crossoverCount: Object.values(filters).filter(f => f.type === 'BiquadCombo').length,
      headroomDb: config.headroomDb,
      worstCaseDbfs: levels,
      warnings: collectWarnings(config, plan, levels),
    },
  };
}
