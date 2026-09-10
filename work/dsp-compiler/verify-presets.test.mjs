// The verification presets are only useful if they compile to the shape the
// harness command lines assume. run-verifications.sh names output pairs and
// gain paths by number; if a preset drifts, the run would still complete and
// would silently be measuring something else. These tests pin the shape.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compile, fileDevices } from './compile.mjs';
import { crossoverPreset, clipPreset, phonesPreset } from './verify-presets.mjs';

const build = preset => compile(preset, fileDevices('in.raw', 'out.raw'));
/** The filters applied to one physical output, in pipeline order. */
const outputFilters = (result, output) => result.config.pipeline
  .slice(result.config.pipeline.findIndex(step => step.name === 'assign'))
  .filter(step => step.type === 'Filter' && step.channels.includes(output))
  .flatMap(step => step.names);
/** The filters applied to one internal branch channel. */
const branchFilters = (result, channel) => result.config.pipeline
  .slice(0, result.config.pipeline.findIndex(step => step.name === 'assign'))
  .filter(step => step.type === 'Filter' && step.channels.includes(channel))
  .flatMap(step => step.names);
const sourcesOf = (result, mixer, dest) =>
  result.config.mixers[mixer].mapping.find(entry => entry.dest === dest).sources;

test('the crossover preset gives each pair its own outputs and order', () => {
  const result = build(crossoverPreset());
  const expected = [
    {main: 0, sub: 1, freq: 80, order: 4, invert: false},
    {main: 2, sub: 3, freq: 80, order: 2, invert: false},
    {main: 4, sub: 5, freq: 80, order: 2, invert: true},
    {main: 6, sub: 7, freq: 200, order: 8, invert: false},
  ];
  for (const {main, sub, freq, order, invert} of expected) {
    const mainChannel = sourcesOf(result, 'assign', main)[0].channel;
    const subChannel = sourcesOf(result, 'assign', sub)[0].channel;
    const highpass = result.config.filters[branchFilters(result, mainChannel)[0]];
    const lowpass = result.config.filters[branchFilters(result, subChannel)[0]];
    assert.deepEqual(highpass.parameters,
      {type: 'LinkwitzRileyHighpass', freq, order});
    assert.deepEqual(lowpass.parameters,
      {type: 'LinkwitzRileyLowpass', freq, order});
    // Exactly one branch feeds each output: two inputs on a sub would make the
    // measured sum something other than one crossover's two halves.
    assert.equal(sourcesOf(result, 'assign', sub).length, 1);
    const gain = outputFilters(result, sub).map(name => result.config.filters[name])
      .find(filter => filter.type === 'Gain');
    assert.equal(Boolean(gain?.parameters.inverted), invert);
  }
});

test('the crossover preset flags only its two 12 dB/oct pairs', () => {
  const {report} = build(crossoverPreset());
  const polarity = report.warnings.filter(text => text.includes('12 dB/oct'));
  assert.equal(polarity.length, 1);
  assert.match(polarity[0], /Affected inputs: 2 In 2, 3 In 3\.$/);
  // Nothing in this preset should be able to clip; a clipping warning here
  // would mean the measurement was being taken through a limiter.
  assert.equal(report.warnings.filter(text => text.includes('dBFS')).length, 0);
  assert.ok(report.worstCaseDbfs.every(level => level === null || level <= 0));
});

test('the crossover preset puts nothing but the crossover in the path', () => {
  const result = build(crossoverPreset());
  assert.equal(result.report.biquadCount, 0, 'no PEQ band should be emitted');
  assert.equal(result.report.crossoverCount, 8);
  assert.equal(result.report.headroomDb, 0, 'a headroom trim would offset every level');
  for (const output of [0, 1, 2, 3, 4, 6, 7]) {
    assert.deepEqual(outputFilters(result, output), []);
  }
});

test('the clip preset drives each output past full scale a different way', () => {
  const result = build(clipPreset());
  assert.equal(result.report.headroomDb, 0);
  // Output 1 is the bit-transparency path: input 1, no gain, no filter.
  assert.deepEqual(sourcesOf(result, 'assign', 0).map(s => s.gain), [0]);
  assert.deepEqual(outputFilters(result, 0), []);
  assert.deepEqual(branchFilters(result, sourcesOf(result, 'assign', 0)[0].channel), []);
  for (const [output, gainDb] of [[1, 6], [2, 12]]) {
    const gain = result.config.filters[outputFilters(result, output)[0]];
    assert.equal(gain.parameters.gain, gainDb);
    assert.equal(gain.parameters.inverted, false);
  }
  // Output 4 is driven past full scale by summing four inputs, not by gain.
  assert.equal(sourcesOf(result, 'assign', 3).length, 4);
  assert.deepEqual(sourcesOf(result, 'assign', 3).map(s => s.gain), [0, 0, 0, 0]);
  // Output 5 is the inverted unity path, where the asymmetric integer range bites.
  const inverted = result.config.filters[outputFilters(result, 4)[0]];
  assert.equal(inverted.parameters.inverted, true);
  assert.equal(inverted.parameters.gain, 0);
  assert.equal(sourcesOf(result, 'expand', sourcesOf(result, 'assign', 4)[0].channel)[0].channel, 7);
  const overs = result.report.worstCaseDbfs
    .map((level, index) => (level !== null && level > 0 ? index + 1 : null))
    .filter(index => index !== null);
  assert.deepEqual(overs, [2, 3, 4]);
});

test('the clip preset keeps its summing path inside a low-pass it can pass', () => {
  const result = build(clipPreset());
  for (const source of sourcesOf(result, 'assign', 3)) {
    const filters = branchFilters(result, source.channel);
    assert.equal(filters.length, 1);
    assert.deepEqual(result.config.filters[filters[0]].parameters,
      {type: 'LinkwitzRileyLowpass', freq: 250, order: 4});
  }
});

test('the phones preset carries both source modes, full range', () => {
  const result = build(phonesPreset());
  assert.equal(result.report.internalChannels, 4);
  assert.ok(result.report.channelMap.every(entry => entry.kind === 'phones'),
            'a phones bus must not allocate a main or bass branch');
  assert.equal(result.report.crossoverCount, 0,
               'the phones path is pre-crossover even with crossovers switched on');
  for (const channel of [0, 1, 2, 3]) {
    assert.deepEqual(branchFilters(result, channel), []);
  }
});

test('the phones preset lands the gains the impulse table expects', () => {
  const result = build(phonesPreset());
  // Total for one ear = headroom + matrix entry (expand) + bus gain (assign).
  const total = (output, input) => {
    const assign = sourcesOf(result, 'assign', output)[0];
    const source = sourcesOf(result, 'expand', assign.channel)
      .find(entry => entry.channel === input);
    return source === undefined ? null : Number((source.gain + assign.gain).toFixed(3));
  };
  assert.equal(total(0, 0), -9);                      // pair, ear 1 <- input 1
  assert.equal(total(1, 1), -9);                      // pair, ear 2 <- input 2
  assert.deepEqual([0, 2, 3, 4, 6].map(input => total(2, input)),
                   [-12, -15, -18, -13.5, -21]);      // downmix L
  assert.deepEqual([1, 2, 3, 5, 6].map(input => total(3, input)),
                   [-12, -15, -18, -13.5, -24]);      // downmix R
  assert.equal(total(2, 1), null, 'input 2 must not reach the left ear');
  assert.equal(total(3, 0), null, 'input 1 must not reach the right ear');
  const delay = result.config.filters[outputFilters(result, 1)[0]];
  assert.deepEqual(delay.parameters, {delay: 120, unit: 'samples', subsample: false});
  assert.equal(result.config.filters[outputFilters(result, 3)[0]].parameters.inverted, true);
});
