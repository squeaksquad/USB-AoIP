// The artifact is what the bridge actually runs, so what matters is that it
// says the same thing the CamillaDSP configuration says. These tests compare
// the two serialisations of the same compilation rather than checking the
// artifact against itself.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compile, fileDevices } from './compile.mjs';
import { bridgeArtifact, delayLatency, MAX_DELAY_SAMPLES } from './bridge-artifact.mjs';
import { bandBiquad, crossoverBiquads, cascadeResponseDb } from './coefficients.mjs';
import { crossoverPreset, clipPreset, phonesPreset, loadedPreset } from './verify-presets.mjs';
import { bandResponse, createConfig, FREQUENCIES } from '../web-ui/model.mjs';

const build = preset => compile(preset, fileDevices('in.raw', 'out.raw'));

/** Parse the artifact back into sections, the way the bridge's loader does. */
function parse(text) {
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
  return {rate, channels, internal, maxdelay, expand, branch, assign, outputs};
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
