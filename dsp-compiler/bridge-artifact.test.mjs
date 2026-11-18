// The artifact is what the bridge actually runs, so what matters is that it
// says the same thing the CamillaDSP configuration says. These tests compare
// the two serialisations of the same compilation rather than checking the
// artifact against itself.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compile, fileDevices } from './compile.mjs';
import { bridgeArtifact, delayLatency, MAX_DELAY_SAMPLES, parseMonitorSection } from './bridge-artifact.mjs';
import { bandBiquad, crossoverBiquads, cascadeResponseDb } from './coefficients.mjs';
import { crossoverPreset, clipPreset, phonesPreset, loadedPreset } from './verify-presets.mjs';
import { bandResponse, createConfig, FREQUENCIES } from '../web-ui/model.mjs';

const build = preset => compile(preset, fileDevices('in.raw', 'out.raw'));

/** Parse the artifact back into sections, the way the bridge's loader does.
 *  The monitor section (on by default since phase 3) is read by
 *  parseMonitorSection and returned as `monitor`; the rest is parsed as the
 *  artifact without it. */
function parse(text) {
  const monitor = parseMonitorSection(text);
  if (monitor) text = `${text.slice(0, text.indexOf('\nmonitor ') + 1)}end\n`;
  const words = text.split(/\s+/).filter(Boolean);
  let at = 0;
  const take = () => words[at++];
  const expect = word => assert.equal(take(), word, `expected ${word}`);
  expect('usb16x16-dsp');
  assert.equal(take(), '1');
  expect('preset');
  // The preset name runs to the end of its line and is not tokenised further.
  const nameEnd = text.indexOf('\n', text.indexOf('preset '));
  at = text.slice(0, nameEnd).split(/\s+/).filter(Boolean).length;
  expect('rate'); const rate = Number(take());
  expect('channels'); const channels = Number(take());
  expect('internal'); const internal = Number(take());
  expect('maxdelay'); const maxdelay = Number(take());
  const mix = keyword => {
    expect(keyword);
    const rows = Number(take());
    return Array.from({length: rows}, () => (
      {dest: Number(take()), source: Number(take()), gain: Number(take())}));
  };
  const sections = count => Array.from({length: count}, () => (
    {b0: Number(take()), b1: Number(take()), b2: Number(take()),
     a1: Number(take()), a2: Number(take())}));
  const expand = mix('expand');
  expect('branch');
  const branchRows = Number(take());
  const branch = Array.from({length: branchRows}, () => {
    const channel = Number(take());
    return {channel, sections: sections(Number(take()))};
  });
  const assign = mix('assign');
  expect('output');
  const outputRows = Number(take());
  const outputs = Array.from({length: outputRows}, () => {
    const index = Number(take());
    const delay = Number(take());
    const gain = Number(take());
    return {index, delay, gain, sections: sections(Number(take()))};
  });
  expect('end');
  assert.equal(at, words.length, 'the artifact has no trailing content');
  return {rate, channels, internal, maxdelay, expand, branch, assign, outputs, monitor};
}

test('the artifact carries the same mix as the compiled configuration', () => {
  const result = build(loadedPreset());
  const artifact = parse(bridgeArtifact(result));
  assert.equal(artifact.rate, 48000);
  assert.equal(artifact.channels, 16);
  assert.equal(artifact.internal, result.plan.channels.length);
  assert.equal(artifact.maxdelay, MAX_DELAY_SAMPLES);

  const expected = [];
  for (const entry of result.config.mixers.expand.mapping) {
    for (const source of entry.sources) {
      expected.push({dest: entry.dest, source: source.channel,
                     gain: 10 ** (source.gain / 20) * (source.inverted ? -1 : 1)});
    }
  }
  assert.equal(artifact.expand.length, expected.length);
  artifact.expand.forEach((row, index) => {
    assert.equal(row.dest, expected[index].dest);
    assert.equal(row.source, expected[index].source);
    // Exact: the emitter writes the round-trip form of the same double.
    assert.equal(row.gain, expected[index].gain);
  });
});

test('a dB gain and a polarity flag become one signed linear gain', () => {
  const preset = createConfig();
  preset.outputs[0].gainDb = -6;
  preset.outputs[0].invert = true;
  preset.outputs[1].mute = true;
  const artifact = parse(bridgeArtifact(build(preset)));
  const first = artifact.outputs.find(entry => entry.index === 0);
  assert.ok(Math.abs(first.gain + 10 ** (-6 / 20)) < 1e-12,
            'invert shows up as the sign of the gain');
  const second = artifact.outputs.find(entry => entry.index === 1);
  assert.equal(second.gain, 0, 'mute shows up as a gain of zero');
});

test('a muted bus contributes no assign rows at all', () => {
  const preset = createConfig();
  preset.buses.find(bus => bus.kind === 'speakers').mute = true;
  const artifact = parse(bridgeArtifact(build(preset)));
  assert.equal(artifact.assign.length, 0,
               'a muted bus is absent rather than present at zero');
});

test('the emitted band coefficients reproduce the curve the UI draws', () => {
  // The strongest available check on the coefficients: the response they give
  // must match `bandResponse`, which is what the engine was measured against.
  const cases = [
    {type: 'bell', frequency: 1000, gainDb: 6, q: 1},
    {type: 'bell', frequency: 40, gainDb: 18, q: 6},
    {type: 'bell', frequency: 12000, gainDb: -18, q: 0.5},
    {type: 'lowShelf', frequency: 100, gainDb: 6, q: 0.707},
    {type: 'lowShelf', frequency: 200, gainDb: -6, q: 1},
    {type: 'highShelf', frequency: 5000, gainDb: 6, q: 0.707},
    {type: 'highShelf', frequency: 3000, gainDb: -6, q: 1.5},
  ];
  let worst = 0;
  for (const band of cases) {
    const sections = [bandBiquad(band)];
    for (let freq = 20; freq <= 20000; freq *= 1.05) {
      worst = Math.max(worst, Math.abs(
        cascadeResponseDb(sections, freq) - bandResponse({enabled: true, ...band}, freq)));
    }
  }
  assert.ok(worst < 1e-9, `worst deviation from the UI curve was ${worst} dB`);
});

test('a Linkwitz-Riley branch is -6 dB at its corner and sums flat', () => {
  for (const slope of [12, 24, 48]) {
    const high = crossoverBiquads('highpass', 80, slope);
    const low = crossoverBiquads('lowpass', 80, slope);
    assert.equal(high.length, low.length);
    assert.equal(high.length, slope === 48 ? 4 : 2);
    for (const branch of [high, low]) {
      assert.ok(Math.abs(cascadeResponseDb(branch, 80) + 6.0206) < 0.001,
                `LR${slope} is -6.02 dB at its corner`);
    }
  }
});

test('the artifact refuses a delay past the ceiling', () => {
  const preset = createConfig();
  preset.outputs[0].delayMs = 10;                      // exactly the ceiling
  assert.doesNotThrow(() => bridgeArtifact(build(preset)));
  const artifact = parse(bridgeArtifact(build(preset)));
  assert.equal(artifact.outputs.find(entry => entry.index === 0).delay, MAX_DELAY_SAMPLES);
});

test('the delay latency reported is the largest, not the sum', () => {
  const preset = createConfig();
  assert.equal(delayLatency(preset).samples, 0);
  assert.equal(delayLatency(preset).text, null, 'no delay, nothing to warn about');
  preset.outputs[0].delayMs = 2;
  preset.outputs[1].delayMs = 5;
  preset.outputs[2].delayMs = 1;
  const latency = delayLatency(preset);
  assert.equal(latency.samples, 240, '5 ms, not the 8 ms total');
  assert.equal(latency.ms, 5);
  assert.match(latency.text, /5\.00 ms/);
  assert.match(latency.text, /every output, not just the delayed ones/);
});

test('every verification preset compiles to an artifact', () => {
  for (const preset of [crossoverPreset(), clipPreset(), phonesPreset(), loadedPreset()]) {
    const result = build(preset);
    const artifact = parse(bridgeArtifact(result));
    assert.equal(artifact.outputs.length, 16, 'all 16 outputs are always listed');
    const biquads = artifact.branch.reduce((sum, entry) => sum + entry.sections.length, 0)
      + artifact.outputs.reduce((sum, entry) => sum + entry.sections.length, 0);
    // Each PEQ band is one biquad; each crossover combo is 2 or 4 sections.
    assert.ok(biquads >= result.report.biquadCount,
              'no emitted PEQ band goes missing in the artifact');
  }
});

test('the loaded preset emits all 256 bands', () => {
  const result = build(loadedPreset());
  const artifact = parse(bridgeArtifact(result));
  const bandSections = artifact.outputs.reduce((sum, entry) => sum + entry.sections.length, 0);
  assert.equal(bandSections, 16 * FREQUENCIES.length);
  assert.equal(result.report.biquadCount, 256);
});

// ---------------------------------------------------------------- fixed shape
// LIVE_COEFFICIENTS_DESIGN.md: the fixed shape exists so that a value edit
// changes only numbers. These tests hold the compiler to that, and pin the
// shape key the applier (Python) and the bridge (C++) must reproduce.

import { artifactShape, artifactShapeKey, sha256HexSync, sha256Hex } from './bridge-artifact.mjs';
import { setOutputRole } from '../web-ui/model.mjs';

const fixed = preset => bridgeArtifact(compile(preset, fileDevices('in.raw', 'out.raw'), {shape: 'fixed'}));
const shapeOf = preset => artifactShape(fixed(preset));
const unity = s => s.b0 === 1 && s.b1 === 0 && s.b2 === 0 && s.a1 === 0 && s.a2 === 0;

test('the fixed shape holds every band of every output, unity where flat', () => {
  const artifact = parse(fixed(createConfig()));
  for (const entry of artifact.outputs) {
    assert.equal(entry.sections.length, FREQUENCIES.length, `output ${entry.index + 1} carries all bands`);
    assert.ok(entry.sections.every(unity), 'a flat default band is the unity section');
  }
  const minimal = parse(bridgeArtifact(build(createConfig())));
  assert.ok(minimal.outputs.every(entry => entry.sections.length === 0),
            'the minimal shape still emits nothing for flat bands');
});

test('the fixed shape says the same audio as the minimal one', () => {
  // Every non-unity section and every non-zero row of the fixed artifact is
  // the minimal artifact's, in order; the fixed one only adds unity and zero.
  for (const preset of [createConfig(), loadedPreset(), crossoverPreset(), clipPreset(), phonesPreset()]) {
    const a = parse(bridgeArtifact(build(preset)));
    const b = parse(fixed(preset));
    assert.equal(a.internal, b.internal, 'the fixed shape allocates no extra branch');
    const live = rows => rows.filter(row => row.gain !== 0);
    assert.deepEqual(live(b.expand), live(a.expand));
    assert.deepEqual(live(b.assign), live(a.assign));
    // Chains that shape the audio, with unity sections and empty chains dropped
    // (the minimal shape omits an empty branch; the fixed one holds it at unity).
    const shaping = entries => entries
      .map(entry => entry.sections.filter(s => !unity(s)))
      .filter(chain => chain.length);
    assert.deepEqual(shaping(b.branch), shaping(a.branch));
    assert.deepEqual(shaping(b.outputs), shaping(a.outputs));
    b.outputs.forEach((entry, index) => {
      assert.equal(entry.delay, a.outputs[index].delay);
      assert.equal(entry.gain, a.outputs[index].gain);
    });
  }
});

test('value edits leave the fixed shape unchanged', () => {
  const base = shapeOf(createConfig());
  const edits = {
    'band gain through zero': p => { p.outputs[0].bands[3].gainDb = 4.5; },
    'band disabled': p => { p.outputs[0].bands[3].enabled = false; },
    'band type and Q': p => { p.outputs[5].bands[0].type = 'lowShelf'; p.outputs[5].bands[0].q = 0.6; p.outputs[5].bands[0].gainDb = -3; },
    'output EQ off': p => { p.outputs[2].eqEnabled = false; },
    'global EQ bypass': p => { p.eqBypass = true; },
    'crossover frequency': p => { p.inputs[0].highpassHz = 100; p.inputs[0].lowpassHz = 100; },
    'high-pass off': p => { p.inputs[4].crossover = false; },
    'LFE low-pass and trim': p => { p.lfe.lowpassHz = 90; p.lfe.trimDb = 10; },
    'existing send gain': p => { p.sends[0][3] = -12; },
    'send muted (null) on a branch that stays': p => { p.sends[2][12] = null; },
    'send added on a branch that exists': p => { p.sends[1][3] = -6; },
    'bus gain and mute': p => { p.buses[0].gainDb = -4; p.buses[0].mute = true; },
    'output gain, polarity, mute': p => { p.outputs[1].gainDb = -2; p.outputs[1].invert = true; p.outputs[6].mute = true; },
    'alignment delay': p => { p.outputs[7].delayMs = 3.5; },
    'headroom': p => { p.headroomDb = -12; },
    // LR12 and LR24 are both two sections (coefficients.mjs), so this pair is
    // a coefficient change; only 48 dB/oct changes the count.
    'slope 24 to 12': p => { p.inputs[0].slope = 12; },
    // Off = unity high-passes and muted non-LFE sends in the same pipeline.
    'bass redirection off': p => { p.bassEnabled = false; },
  };
  for (const [name, edit] of Object.entries(edits)) {
    const preset = createConfig();
    edit(preset);
    assert.equal(shapeOf(preset), base, `${name} is a live edit`);
  }
});

test('shape edits change the fixed shape', () => {
  const base = shapeOf(createConfig());
  const edits = {
    'crossover slope': p => { p.inputs[0].slope = 48; },
    'LFE slope to 48': p => { p.lfe.slope = 48; },
    'first send from an input with none': p => { p.sends[12][3] = 0; },
    'last send removed from an input': p => { p.sends[0][3] = null; },
    'output role': p => { setOutputRole(p, 13, 'speaker'); },
    'output source': p => { p.outputs[0].source = 1; },
  };
  for (const [name, edit] of Object.entries(edits)) {
    const preset = createConfig();
    edit(preset);
    assert.notEqual(shapeOf(preset), base, `${name} needs a restart`);
  }
});

test('a switched-off high-pass holds its slope\'s slots at unity', () => {
  const preset = createConfig();
  preset.inputs[0].crossover = false;
  preset.inputs[0].slope = 48;
  const on = createConfig();
  on.inputs[0].slope = 48;
  const off = parse(fixed(preset));
  const live = parse(fixed(on));
  const main = live.branch.findIndex(entry => entry.sections.length === 4);
  assert.ok(main >= 0, 'the 48 dB/oct high-pass is four sections');
  assert.equal(off.branch[main].sections.length, 4);
  assert.ok(off.branch[main].sections.every(unity));
  assert.equal(artifactShape(fixed(preset)), artifactShape(fixed(on)));
});

test('the fixed shape of the acceptance layouts stays within the soak count', () => {
  const sections = text => parse(text).outputs.reduce((n, e) => n + e.sections.length, 0)
    + parse(text).branch.reduce((n, e) => n + e.sections.length, 0);
  assert.equal(sections(fixed(loadedPreset())), 308, 'the loaded preset is already full: fixed adds nothing');
  assert.ok(sections(fixed(createConfig())) <= 308, 'the shipped 7.2.4 layout fits');
});

test('the muted bus keeps its rows at zero in the fixed shape', () => {
  const preset = createConfig();
  preset.buses.find(bus => bus.kind === 'speakers').mute = true;
  const artifact = parse(fixed(preset));
  assert.ok(artifact.assign.length > 0, 'rows are present');
  assert.ok(artifact.assign.every(row => row.gain === 0), 'and all at zero');
});

test('the shape key is pinned: the applier and the bridge must reproduce it', async () => {
  // A small artifact written by hand; its canonical shape and SHA-256 are the
  // cross-implementation vector. Change either only with all three.
  const artifact = [
    'usb16x16-dsp 1',
    'preset pinned shape vector',
    'rate 48000', 'channels 16', 'internal 2', 'maxdelay 480',
    'expand 2', '0 0 0.125', '1 1 -0.5',
    'branch 1', '1 2', '1 0 0 0 0', '0.5 0.25 0 -0.1 0.01',
    'assign 2', '0 0 1', '3 1 0',
    'output 16',
    ...Array.from({length: 16}, (_, i) => (i === 0 ? '0 48 0.5 1\n1 0 0 0 0' : `${i} 0 1 0`)),
    'end',
  ].join('\n') + '\n';
  const shape = artifactShape(artifact);
  assert.equal(shape, [
    'usb16x16-dsp-shape 1', 'rate 48000', 'channels 16', 'internal 2', 'maxdelay 480',
    'expand 2', '0 0', '1 1', 'branch 1', '1 2', 'assign 2', '0 0', '3 1',
    'output 16', ...Array.from({length: 16}, (_, i) => `${i} ${i === 0 ? 1 : 0}`), 'end',
  ].join('\n') + '\n');
  assert.equal(await artifactShapeKey(artifact),
               '7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0');
  // Values do not move the key; a count does.
  const renumbered = artifact.replace('0 48 0.5 1', '0 96 0.25 1').replace('0.5 0.25 0 -0.1 0.01', '0.6 0.2 0 -0.2 0.02');
  assert.equal(await artifactShapeKey(renumbered), await artifactShapeKey(artifact));
  assert.notEqual(await artifactShapeKey(artifact.replace('assign 2\n0 0 1\n3 1 0', 'assign 1\n0 0 1')),
                  await artifactShapeKey(artifact));
  assert.throws(() => artifactShape(artifact.replace('end\n', '')), /unexpected end/);
  assert.throws(() => artifactShape(artifact.replace('assign 2', 'assign 3')), /assign row|expected 'output'/);
});

test('the plain SHA-256 matches the known vectors and WebCrypto', async () => {
  const encode = text => new TextEncoder().encode(text);
  assert.equal(sha256HexSync(encode('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(sha256HexSync(encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.equal(sha256HexSync(encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
               '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  // Exactly one block of padding boundary cases: 55, 56 and 64 bytes.
  for (const length of [55, 56, 64, 119, 120, 1000]) {
    const text = 'x'.repeat(length);
    assert.equal(sha256HexSync(encode(text)), await sha256Hex(text), `length ${length} agrees with WebCrypto`);
  }
  const artifact = bridgeArtifact(build(loadedPreset()));
  assert.equal(sha256HexSync(encode(artifactShape(artifact))), await artifactShapeKey(artifact));
});

test('bass redirection off is muted sends and unity high-passes, same shape', () => {
  const off = createConfig(); off.bassEnabled = false;
  const a = parse(fixed(createConfig()));
  const b = parse(fixed(off));
  assert.equal(a.internal, b.internal);
  assert.equal(a.assign.length, b.assign.length, 'the same rows');
  // Subs (outputs 4 and 13) keep only the LFE input's sends when off.
  const subRows = rows => rows.filter(r => r.dest === 3 || r.dest === 12);
  assert.ok(subRows(a.assign).filter(r => r.gain !== 0).length > subRows(b.assign).filter(r => r.gain !== 0).length);
  assert.ok(subRows(b.assign).some(r => r.gain !== 0), 'the LFE branch still feeds the subs');
  assert.ok(b.branch.filter(e => e.sections.every(unity)).length >= 11, 'every main high-pass is at unity');
  const minimalOff = parse(bridgeArtifact(build(off)));
  assert.notEqual(minimalOff.internal, b.internal, 'the minimal shape drops the branches; the fixed one keeps them');
});

// ---------------------------------------------------------------- sample rate
// SAMPLE_RATE_DESIGN.md, step 3: the artifact names its rate, its coefficients
// are computed at it, and 48 kHz is unchanged. The bridge refuses an artifact
// whose rate is not the one it runs at (bridge_tests.cpp,
// test_dsp_refuses_an_artifact_for_another_rate).

import { maxDelaySamples } from './bridge-artifact.mjs';

const at = (preset, rate, shape = 'minimal') =>
  bridgeArtifact(compile(preset, fileDevices('in.raw', 'out.raw', 'S32_LE', 1024, rate), {shape}));

test('a 48 kHz artifact is the one compiled without naming a rate', () => {
  for (const preset of [crossoverPreset(), clipPreset(), phonesPreset(), loadedPreset()]) {
    assert.equal(at(preset, 48000), bridgeArtifact(build(preset)));
    assert.equal(at(preset, 48000, 'fixed'), fixed(preset));
  }
  assert.equal(maxDelaySamples(48000), MAX_DELAY_SAMPLES);
});

test('an artifact at another rate names it and is computed at it', () => {
  const preset = crossoverPreset();
  for (const rate of [44100, 88200, 96000, 176400, 192000]) {
    const artifact = parse(at(preset, rate));
    assert.equal(artifact.rate, rate);
    assert.equal(artifact.maxdelay, maxDelaySamples(rate), '10 ms at that rate');
    // The first crossover branch, measured at its own rate: -6 dB at the corner,
    // whichever rate it was compiled for.
    const result = compile(preset, fileDevices('in.raw', 'out.raw', 'S32_LE', 1024, rate));
    const [index, names] = [...result.config.pipeline.entries()]
      .filter(([, step]) => step.type === 'Filter')
      .map(([, step]) => [step.channels[0], step.names])
      .find(([, stepNames]) => result.config.filters[stepNames[0]].type === 'BiquadCombo');
    const {freq} = result.config.filters[names[0]].parameters;
    const branch = artifact.branch.find(entry => entry.channel === index);
    assert.ok(Math.abs(cascadeResponseDb(branch.sections, freq, rate) + 6.0206) < 1e-3,
      `the ${rate} Hz crossover is -6 dB at its corner when evaluated at ${rate}`);
  }
  const at48 = parse(at(preset, 48000)), at96 = parse(at(preset, 96000));
  assert.notDeepEqual(at48.branch, at96.branch, 'the same preset has different coefficients at another rate');
  assert.deepEqual(at48.expand, at96.expand, 'and the same mix');
});

test('the delay ceiling is 10 ms at every rate', () => {
  const preset = createConfig();
  preset.outputs[0].delayMs = 10;
  assert.equal(parse(at(preset, 96000)).outputs[0].delay, 960);
  assert.equal(parse(at(preset, 44100)).outputs[0].delay, 441);
  assert.equal(delayLatency(preset, 96000).samples, 960);
  assert.equal(delayLatency(preset, 96000).ms, 10);
  assert.equal(delayLatency(preset).samples, 480, 'the default is 48 kHz');
});

test('the shape names the rate, so a live update at another rate is a shape change', async () => {
  const preset = createConfig();
  assert.match(artifactShape(at(preset, 96000, 'fixed')), /^rate 96000\nchannels 16\ninternal \d+\nmaxdelay 960$/m);
  assert.notEqual(await artifactShapeKey(at(preset, 96000, 'fixed')), await artifactShapeKey(fixed(preset)));
});

// ------------------------------------------------------------- monitor section
// Phase 3, step 2: the optional `monitor` section. The fold table is pinned to
// exact coefficients; the C++ loader (bridge_tests.cpp) and the applier's
// Python pin the same monitor shape vector.

import { readFileSync } from 'node:fs';
import { monitorFolds, monitorLabel, monitorTopology } from './bridge-artifact.mjs';
import { transparentPreset } from './verify-presets.mjs';

const A = 0.7071067811865476;          // Math.SQRT1_2
const AA = 0.5000000000000001;         // A * A
const HA = 0.3535533905932738;         // 0.5 * A
const HAA = 0.25000000000000006;       // 0.5 * A * A
const foldsOf = used => Object.fromEntries(monitorFolds(used).map(fold => [fold.name, fold.rows]));

test('the fold table of a 7.1.4 set, coefficient for coefficient', () => {
  const folds = foldsOf([0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11]);
  assert.deepEqual(Object.keys(folds), ['5.1', 'stereo', 'mono']);
  assert.deepEqual(folds['5.1'], [
    [0, 0, 1], [0, 8, A], [1, 1, 1], [1, 9, A], [2, 2, 1], [3, 3, 1],
    [4, 4, 1], [4, 6, A], [4, 10, A], [5, 5, 1], [5, 7, A], [5, 11, A]]);
  assert.deepEqual(folds.stereo, [
    [0, 0, 1], [0, 2, A], [0, 4, A], [0, 6, AA], [0, 8, A], [0, 10, AA],
    [1, 1, 1], [1, 2, A], [1, 5, A], [1, 7, AA], [1, 9, A], [1, 11, AA], [3, 3, 1]]);
  const half = [[0, 0.5], [1, 0.5], [2, A], [4, HA], [5, HA], [6, HAA], [7, HAA],
                [8, HA], [9, HA], [10, HAA], [11, HAA]];
  assert.deepEqual(folds.mono, [...half.map(([s, g]) => [0, s, g]), ...half.map(([s, g]) => [1, s, g]), [3, 3, 1]]);
  // The wides and tops, which the 7.1.4 layout does not use.
  const wide = foldsOf([0, 1, 2, 4, 5, 12, 13, 14, 15]);
  assert.deepEqual(wide['5.1'], [
    [0, 0, 1], [0, 12, A], [0, 14, 0.5], [1, 1, 1], [1, 13, A], [1, 15, 0.5], [2, 2, 1], [3, 3, 1],
    [4, 4, 1], [4, 14, 0.5], [5, 5, 1], [5, 15, 0.5]]);
  // Ltm reaches L'' twice (via L' and via Ls'): the terms are summed.
  assert.deepEqual(wide.stereo.find(([d, s]) => d === 0 && s === 14), [0, 14, 0.5 + A * 0.5]);
  assert.equal(0.5 + A * 0.5, 0.8535533905932737);
});

test('the fold table of a 5.1, a stereo and a set without a centre', () => {
  const five = foldsOf([0, 1, 2, 4, 5]);
  assert.deepEqual(Object.keys(five), ['stereo', 'mono'], '5.1 has nothing above Rs to fold');
  assert.deepEqual(five.stereo, [[0, 0, 1], [0, 2, A], [0, 4, A], [1, 1, 1], [1, 2, A], [1, 5, A], [3, 3, 1]]);
  assert.deepEqual(five.mono, [[0, 0, 0.5], [0, 1, 0.5], [0, 2, A], [0, 4, HA], [0, 5, HA],
                               [1, 0, 0.5], [1, 1, 0.5], [1, 2, A], [1, 4, HA], [1, 5, HA], [3, 3, 1]]);
  const stereo = foldsOf([0, 1]);
  assert.deepEqual(Object.keys(stereo), ['mono'], 'a stereo set offers mono only');
  assert.deepEqual(stereo.mono, [[0, 0, 0.5], [0, 1, 0.5], [1, 0, 0.5], [1, 1, 0.5], [3, 3, 1]]);
  const noCentre = foldsOf([0, 1, 4, 5]);
  assert.deepEqual(Object.keys(noCentre), ['stereo', 'mono'], 'no C: no 5.1');
  assert.deepEqual(noCentre.stereo, [[0, 0, 1], [0, 4, A], [1, 1, 1], [1, 5, A], [3, 3, 1]]);
  assert.deepEqual(noCentre.mono, [[0, 0, 0.5], [0, 1, 0.5], [0, 4, HA], [0, 5, HA],
                                   [1, 0, 0.5], [1, 1, 0.5], [1, 4, HA], [1, 5, HA], [3, 3, 1]]);
  assert.deepEqual(foldsOf([0, 2]), {}, 'no R: nothing');
  assert.deepEqual(foldsOf([0, 1, 3]), {mono: [[0, 0, 0.5], [0, 1, 0.5], [1, 0, 0.5], [1, 1, 0.5], [3, 3, 1]]},
                   'the LFE is not an "other" input for stereo');
  assert.deepEqual(monitorFolds([0, 1], {lfe: 15}).at(-1).rows.at(-1), [15, 15, 1], 'the preset LFE input passes');
});

test('labels are sanitised to what the section can carry', () => {
  assert.equal(monitorLabel('  Left   wide  '), 'Left wide');
  assert.equal(monitorLabel('Süb\tL'), 'S?b?L');
  assert.equal(monitorLabel('x'.repeat(40)), 'x'.repeat(32));
  assert.equal(monitorLabel(`${'y'.repeat(31)} z`), 'y'.repeat(31), 'trimmed again after the cut');
  assert.equal(monitorLabel('   '), '');
});

test('the default preset emits one set, its outputs, labels and folds', () => {
  const text = bridgeArtifact(build(createConfig()));
  const artifact = parse(text);
  const monitor = artifact.monitor;
  assert.deepEqual(monitor.sets, [{id: 'speakers', kind: 'speakers', folds: ['full', '5.1', 'stereo', 'mono']}]);
  assert.deepEqual(monitor.outs.map(out => [out.index, out.role]),
    [[0, 'speaker'], [1, 'speaker'], [2, 'speaker'], [3, 'sub'], ...[4, 5, 6, 7, 8, 9, 10, 11].map(i => [i, 'speaker']),
     [12, 'sub']]);
  assert.ok(monitor.outs.every(out => out.sets.length === 1 && out.sets[0] === 0));
  assert.deepEqual(monitor.labels.slice(0, 13), ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', 'Sub 2']);
  assert.deepEqual(monitor.labels.slice(13), [null, null, null], 'unused outputs have no label line');
  assert.equal(monitor.expandSets.length, artifact.expand.length, 'one tag per expand row');
  assert.ok(monitor.expandSets.every(tag => tag === 0), 'main and bass rows read the speakers set');
  assert.deepEqual(monitor.folds.map(fold => fold.rows), Object.values(foldsOf([0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])));
  assert.match(text, /\nfolds 3\nfold 0 5\.1 12\n0 0 1\n0 8 0\.7071067811865476\n/);
});

test('headphone rows read the inputs and a headphones set has no folds', () => {
  const result = build(phonesPreset());
  const monitor = parse(bridgeArtifact(result)).monitor;
  assert.deepEqual(monitor.sets.map(set => [set.id, set.kind, set.folds]),
    [['hp-pair', 'headphones', ['full']], ['hp-downmix', 'headphones', ['full']]]);
  assert.ok(monitor.expandSets.every(tag => tag === null));
  assert.deepEqual(monitor.outs, [{index: 0, role: 'speaker', sets: [0]}, {index: 1, role: 'speaker', sets: [0]},
                                  {index: 2, role: 'speaker', sets: [1]}, {index: 3, role: 'speaker', sets: [1]}]);
  assert.equal(monitor.folds.length, 0);
  // Speakers and headphones together: each row is tagged by its own branch.
  const both = createConfig();
  const phones = phonesPreset().buses[0];
  for (const index of [13, 14]) {
    both.outputs[index].role = 'speaker';
    both.outputs[index].busId = phones.id;
  }
  both.buses.push({...phones, outputIds: [13, 14]});
  const mixed = build(both);
  const tags = parse(bridgeArtifact(mixed)).monitor.expandSets;
  const kinds = mixed.config.mixers.expand.mapping.flatMap(entry => entry.sources.map(() => mixed.plan.channels[entry.dest].kind));
  assert.deepEqual(tags, kinds.map(kind => (kind === 'phones' ? null : 0)));
});

test('the section parses back to the topology it was written from', () => {
  for (const preset of [createConfig(), loadedPreset(), crossoverPreset(), clipPreset(), phonesPreset(), transparentPreset()]) {
    for (const shape of ['minimal', 'fixed']) {
      const result = compile(preset, fileDevices('in.raw', 'out.raw'), {shape});
      const parsed = parseMonitorSection(bridgeArtifact(result));
      const written = result.monitor;
      assert.deepEqual(parsed.sets.map(({id, kind}) => ({id, kind})), written.sets);
      assert.deepEqual(parsed.outs, written.outs);
      assert.deepEqual(parsed.labels, written.labels);
      assert.deepEqual(parsed.folds, written.folds);
      assert.deepEqual(parsed.sets.map(set => set.folds.slice(1)),
        written.sets.map((_, index) => written.folds.filter(fold => fold.set === index).map(fold => fold.name)));
    }
  }
});

test('monitor off writes the artifact as it was before the section', () => {
  // dante/config/dsp-loaded@48000.dsp is an installed artifact, compiled
  // before the section existed: monitor off must reproduce it byte for byte.
  const installed = readFileSync(new URL('../dante/config/dsp-loaded@48000.dsp', import.meta.url), 'utf8');
  const off = bridgeArtifact(compile(loadedPreset(), fileDevices('in.raw', 'out.raw'), {monitor: false}));
  assert.equal(off, installed);
  const on = bridgeArtifact(build(loadedPreset()));
  assert.equal(on.slice(0, on.indexOf('monitor 1\n')), off.slice(0, -'end\n'.length),
               'monitor on only adds the section before end');
  assert.equal(parseMonitorSection(off), null);
  assert.notEqual(artifactShape(on), artifactShape(off), 'the section is shape');
  assert.equal(build(loadedPreset()).config.pipeline.length,
               compile(loadedPreset(), fileDevices('in.raw', 'out.raw'), {monitor: false}).config.pipeline.length,
               'the CamillaDSP configuration does not depend on it');
});

test('the monitor shape key is pinned: the applier and the bridge must reproduce it', async () => {
  const base = [
    'usb16x16-dsp 1', 'preset pinned monitor vector',
    'rate 48000', 'channels 16', 'internal 2', 'maxdelay 480',
    'expand 2', '0 0 0.125', '1 1 -0.5',
    'branch 1', '1 2', '1 0 0 0 0', '0.5 0.25 0 -0.1 0.01',
    'assign 2', '0 0 1', '3 1 0',
    'output 16',
    ...Array.from({length: 16}, (_, i) => (i === 0 ? '0 48 0.5 1\n1 0 0 0 0' : `${i} 0 1 0`)),
  ];
  const section = [
    'monitor 1', 'sets 2', 'set front speakers', 'set cans headphones',
    'outs 3', 'out 0 speaker 0', 'out 3 sub 0', 'out 5 speaker 1',
    'label 0 Left  main', 'label 3 Sub',
    'expandsets 2', '0', '-',
    'folds 2', 'fold 0 stereo 2', '0 0 1', '0 2 0.7071067811865476',
    'fold 0 mono 3', '0 0 0.5', '0 1 0.5', '3 3 1',
  ];
  const artifact = [...base, ...section, 'end'].join('\n') + '\n';
  const plain = [...base, 'end'].join('\n') + '\n';
  const shape = artifactShape(artifact);
  assert.equal(shape, artifactShape(plain).replace(/end\n$/, '')
    + section.filter(line => !line.startsWith('label ')).join('\n') + '\nend\n');
  assert.equal(await artifactShapeKey(artifact), 'e119252efe5c29dceede375386fe80d48bb1596b6f206894408520f6c2e29694');
  assert.equal(await artifactShapeKey(plain), '7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0',
               'without it, the old vector');
  assert.equal(await artifactShapeKey(artifact.replace('label 3 Sub', 'label 3 Subwoofer')), await artifactShapeKey(artifact),
               'a label is not shape');
  assert.equal(await artifactShapeKey(artifact.replace('out 3 sub 0', 'out   3 sub  0')), await artifactShapeKey(artifact),
               'words, not spacing');
  assert.notEqual(await artifactShapeKey(artifact.replace('0 2 0.7071067811865476', '0 2 0.5')), await artifactShapeKey(artifact),
                  'a fold gain is shape');
  const parsed = parseMonitorSection(artifact);
  assert.equal(parsed.labels[0], 'Left  main');
  assert.deepEqual(parsed.expandSets, [0, null]);
  assert.deepEqual(parsed.sets[0].folds, ['full', 'stereo', 'mono']);
});

test('a malformed monitor section is refused, as the bridge refuses it', () => {
  const good = bridgeArtifact(build(createConfig()));
  assert.doesNotThrow(() => artifactShape(good));
  const bad = {
    'version': ['monitor 1\n', 'monitor 2\n'],
    'no sets': ['sets 1\nset speakers speakers\n', 'sets 0\n'],
    'set id': ['set speakers speakers', 'set Speakers speakers'],
    'set kind': ['set speakers speakers', 'set speakers monitors'],
    'outs order': ['out 1 speaker 0\n', 'out 0 speaker 0\n'],
    'role': ['out 3 sub 0', 'out 3 woofer 0'],
    'set range': ['out 3 sub 0', 'out 3 sub 1'],
    'speaker in two sets': ['out 0 speaker 0', 'out 0 speaker 0 0'],
    'label of nothing': ['label 12 Sub 2', 'label 14 Sub 2'],
    'label character': ['label 12 Sub 2', 'label 12 Subé'],
    'expandsets count': ['expandsets 23', 'expandsets 22'],
    'fold name': ['fold 0 mono', 'fold 0 full'],
    'fold gain': ['0 8 0.7071067811865476', '0 8 0x1'],
    'duplicate pair': ['0 8 0.7071067811865476', '0 0 0.7071067811865476'],
    'trailing': ['3 3 1\nend\n', '3 3 1\nend\nend\n'],
  };
  for (const [name, [from, to]] of Object.entries(bad)) {
    const at = good.lastIndexOf(from);
    assert.ok(at >= 0, `${name}: the target is in the artifact`);
    const text = good.slice(0, at) + to + good.slice(at + from.length);
    assert.throws(() => artifactShape(text), /monitor|expected 'end'/, name);
  }
});
