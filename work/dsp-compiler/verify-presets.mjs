// Presets for the end-to-end engine verifications.
//
// The earlier verification runs used ad-hoc presets that were not kept, so the
// figures in the README cannot be reproduced without rebuilding them by hand.
// These are built here instead, validated against the same model the UI uses,
// so a run can be repeated exactly.
//
// Offline: this writes JSON and exits. It compiles nothing and applies nothing.

import { CHANNELS, FREQUENCIES, createConfig, validateConfig } from '../web-ui/model.mjs';

const flatBands = () => FREQUENCIES.map(frequency =>
  ({enabled: true, type: 'bell', frequency, gainDb: 0, q: 1}));

/** An output nothing drives. Kept explicit so every preset lists all 16. */
const unused = index => ({
  label: `Spare ${index + 1}`, role: 'unused', source: 0, gainDb: 0, delayMs: 0,
  mute: false, invert: false, eqEnabled: true, bands: flatBands(), busId: null,
});

function output(label, role, source, busId, extra = {}) {
  return {
    label, role, source, gainDb: 0, delayMs: 0, mute: false, invert: false,
    eqEnabled: true, bands: flatBands(), busId, ...extra,
  };
}

function base(name, {headroomDb = 0, bassEnabled = true} = {}) {
  return {
    version: 2, name, mode: 'dsp', source: 'usb', sampleRate: 48000,
    headroomDb, bassEnabled, eqBypass: false,
    // Input 16 drives nothing anywhere in these presets, so parking the LFE
    // there keeps the LFE trim and the LFE low-pass out of every measurement.
    // Both are already verified by verify-tone.py; here they would only be a
    // second explanation for a level that disagrees.
    lfe: {input: 15, lowpassHz: 120, slope: 24, trimDb: 0},
    inputs: Array.from({length: CHANNELS}, (_, i) => ({
      label: `In ${i + 1}`, crossover: true, highpassHz: 80, lowpassHz: 80, slope: 24,
    })),
    outputs: Array.from({length: CHANNELS}, (_, i) => unused(i)),
    sends: Array.from({length: CHANNELS}, () => Array(CHANNELS).fill(null)),
    buses: [],
  };
}

/**
 * Crossover magnitude, phase and branch summation.
 *
 * Four independent crossover pairs, each fed by its own input and landing on
 * its own speaker/sub output pair, so one run measures every case:
 *
 *   outputs 1,2  LR4  @ 80 Hz              expect a flat electrical sum
 *   outputs 3,4  LR2  @ 80 Hz              expect a null at the crossover
 *   outputs 5,6  LR2  @ 80 Hz, sub inverted  expect a flat sum
 *   outputs 7,8  LR8  @ 200 Hz             expect a flat sum
 *
 * Pairs 2 and 3 differ only in the sub's polarity, which is exactly the
 * decision the compiler refuses to make for the user. Headroom is 0 dB so a
 * measured magnitude reads as the filter response and nothing else.
 */
export function crossoverPreset() {
  const preset = base('verify-crossover');
  const pairs = [
    {input: 0, freq: 80, slope: 24, invertSub: false},
    {input: 1, freq: 80, slope: 12, invertSub: false},
    {input: 2, freq: 80, slope: 12, invertSub: true},
    {input: 3, freq: 200, slope: 48, invertSub: false},
  ];
  const outputIds = [];
  pairs.forEach(({input, freq, slope, invertSub}, pair) => {
    Object.assign(preset.inputs[input],
      {highpassHz: freq, lowpassHz: freq, slope, crossover: true});
    const main = pair * 2;
    const sub = main + 1;
    preset.outputs[main] = output(`Main ${pair + 1}`, 'speaker', input, 'speakers');
    preset.outputs[sub] = output(`Sub ${pair + 1}`, 'sub', input, 'speakers',
                                 {invert: invertSub});
    preset.sends[input][sub] = 0;
    outputIds.push(main, sub);
  });
  preset.buses = [{
    id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds,
    layoutId: 'custom', gainDb: 0, mute: false,
  }];
  return validateConfig(preset);
}

/**
 * Behaviour at and past full scale.
 *
 * Output 1 is a unity path: whatever the engine does at exactly +/- full scale
 * shows up there as a departure from bit transparency. Outputs 2 and 3 are
 * driven past 0 dBFS by output gain, output 4 by coherent summing instead, and
 * output 5 is a unity path with the polarity inverted, which is where an
 * asymmetric integer range bites.
 *
 * Crossovers are off on the gain paths so nothing but the gain is in the way.
 * The summing path keeps its low-pass -- a bass branch always has one -- but at
 * 250 Hz it costs 0.0001 dB at the 20 Hz test tone, far below what is measured.
 */
export function clipPreset() {
  const preset = base('verify-clip');
  preset.inputs.forEach(input => { input.crossover = false; });
  const summed = [3, 4, 5, 6];
  for (const input of summed) {
    Object.assign(preset.inputs[input], {lowpassHz: 250, slope: 24});
  }
  preset.outputs[0] = output('Unity', 'speaker', 0, 'speakers');
  preset.outputs[1] = output('Plus 6', 'speaker', 1, 'speakers', {gainDb: 6});
  preset.outputs[2] = output('Plus 12', 'speaker', 2, 'speakers', {gainDb: 12});
  preset.outputs[3] = output('Sum of 4', 'sub', 3, 'speakers');
  preset.outputs[4] = output('Unity inverted', 'speaker', 7, 'speakers', {invert: true});
  for (const input of summed) preset.sends[input][3] = 0;
  preset.buses = [{
    id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds: [0, 1, 2, 3, 4],
    layoutId: 'custom', gainDb: 0, mute: false,
  }];
  return validateConfig(preset);
}

/**
 * Both headphone source modes, through the engine.
 *
 * Outputs 1,2 are a pair bus: ear n takes input pair member n, untouched.
 * Outputs 3,4 are a downmix bus with deliberately asymmetric per-ear gains and
 * a bus gain of -3 dB, so an ear that quietly used the wrong column or dropped
 * the bus gain cannot read as correct.
 *
 * Crossovers stay switched on at the inputs even though the phones buses are
 * pre-crossover. A phones branch carries no filter, so each impulse must come
 * back as a single unrung sample; if the crossover ever leaked into this path
 * the impulse would ring instead.
 *
 * Output 2 carries a 2.5 ms delay and output 4 a polarity invert, so the
 * per-output stage is exercised on a phones path rather than assumed to behave
 * as it does on a speaker path.
 */
export function phonesPreset() {
  // Headroom keeps the downmix ceiling under 0 dBFS. The staggered impulses
  // never sum, so this does not change what is measured; it keeps the
  // compiler from reporting a clipping ceiling that this run cannot reach.
  const preset = base('verify-phones', {headroomDb: -9});
  const matrix = Array.from({length: CHANNELS}, () => [null, null]);
  matrix[0] = [0, null];
  matrix[1] = [null, 0];
  matrix[2] = [-3, -3];
  matrix[3] = [-6, -6];
  matrix[4] = [-1.5, null];
  matrix[5] = [null, -1.5];
  matrix[6] = [-9, -12];
  preset.outputs[0] = output('Pair L', 'speaker', 0, 'hp-pair');
  preset.outputs[1] = output('Pair R', 'speaker', 1, 'hp-pair', {delayMs: 2.5});
  preset.outputs[2] = output('Downmix L', 'speaker', 0, 'hp-downmix');
  preset.outputs[3] = output('Downmix R', 'speaker', 1, 'hp-downmix', {invert: true});
  preset.buses = [
    {
      id: 'hp-pair', kind: 'headphones', label: 'Phones pair', outputIds: [0, 1],
      layoutId: 'custom', gainDb: 0, mute: false, inputMode: 'pair',
      inputPair: [0, 1], downmixMatrix: Array.from({length: CHANNELS}, () => [null, null]),
      sourcePreCrossover: true,
    },
    {
      id: 'hp-downmix', kind: 'headphones', label: 'Phones downmix', outputIds: [2, 3],
      layoutId: 'custom', gainDb: -3, mute: false, inputMode: 'downmix',
      inputPair: [0, 1], downmixMatrix: matrix, sourcePreCrossover: true,
    },
  ];
  return validateConfig(preset);
}

/**
 * The shipped 7.2.4 layout, exactly as the UI creates it.
 *
 * Every band is flat, so no PEQ biquad is emitted at all: this is the cost of
 * the routing and the crossovers alone. It is the floor a real preset builds on
 * rather than a realistic load.
 */
export function defaultPreset() {
  return validateConfig(createConfig());
}

/**
 * The acceptance criterion in `work/web-ui/README.md` as a preset: all 16
 * outputs active, all 256 bands shaped, crossovers and multiple sub sums.
 *
 * Bands are varied in type, Q and sign rather than set to one value, so no
 * arithmetic shortcut a uniform filter might allow can flatter the result.
 */
export function loadedPreset() {
  const preset = createConfig();
  // The shipped layout leaves 14-16 unused; the acceptance case does not.
  const speakers = preset.buses.find(bus => bus.kind === 'speakers');
  // Sourced from inputs 13-15, which drive nothing in the shipped layout, so
  // each one allocates its own main branch instead of sharing an existing one.
  for (const index of [13, 14, 15]) {
    preset.outputs[index].role = 'speaker';
    preset.outputs[index].source = index - 1;
    preset.outputs[index].busId = speakers.id;
    speakers.outputIds.push(index);
  }
  speakers.layoutId = 'custom';
  const types = ['bell', 'lowShelf', 'highShelf'];
  preset.outputs.forEach((output, index) => {
    output.eqEnabled = true;
    output.bands.forEach((band, position) => {
      band.enabled = true;
      band.type = position === 0 ? 'lowShelf'
        : position === FREQUENCIES.length - 1 ? 'highShelf'
        : types[(index + position) % types.length];
      band.gainDb = ((index + position) % 2 ? 1 : -1) * (1.5 + ((index + position) % 5));
      band.q = 0.5 + ((index * 3 + position) % 7) * 0.35;
    });
  });
  return validateConfig(preset);
}

export const PRESETS = {
  crossover: crossoverPreset,
  clip: clipPreset,
  phones: phonesPreset,
  default: defaultPreset,
  loaded: loadedPreset,
};

function main(argv) {
  const name = argv[0];
  if (!name || !PRESETS[name]) {
    process.stderr.write(
      `usage: verify-presets.mjs ${Object.keys(PRESETS).join('|')} > preset.json\n`);
    return 2;
  }
  process.stdout.write(`${JSON.stringify(PRESETS[name](), null, 2)}\n`);
  return 0;
}

if (import.meta.filename === process.argv[1]) process.exit(main(process.argv.slice(2)));
