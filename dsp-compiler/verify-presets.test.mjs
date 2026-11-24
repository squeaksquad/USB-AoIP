// The verification presets are only useful if they compile to the shape the
// harness command lines assume. run-verifications.sh names output pairs and
// gain paths by number; if a preset drifts, the run would still complete and
// would silently be measuring something else. These tests pin the shape.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compile, fileDevices } from './compile.mjs';
import { crossoverPreset, clipPreset, phonesPreset, transparentPreset, loopMeasurePreset, liveBasePreset, liveTogglePreset } from './verify-presets.mjs';
import { bridgeArtifact, artifactShape } from './bridge-artifact.mjs';

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
  // Total for one ear = headroom + matrix entry (expand) + assign (unity) +
  // the output's own gain (the downmix pair's -3 dB, a bus level before v3).
  const total = (output, input) => {
    const assign = sourcesOf(result, 'assign', output)[0];
    const source = sourcesOf(result, 'expand', assign.channel)
      .find(entry => entry.channel === input);
    const gain = outputFilters(result, output).map(name => result.config.filters[name])
      .find(filter => filter.type === 'Gain')?.parameters.gain ?? 0;
    return source === undefined ? null : Number((source.gain + assign.gain + gain).toFixed(3));
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

test('the loop-measure preset is transparent at -40 dB on every output', () => {
  const result = build(loopMeasurePreset());
  const reference = build(transparentPreset());
  // The same stage cost as transparent: every band emitted, no crossover,
  // no delay, so the only difference the loop sees is the output gain.
  assert.equal(result.report.biquadCount, reference.report.biquadCount);
  assert.equal(result.report.biquadCount, 256);
  assert.equal(result.report.crossoverCount, 0);
  assert.equal(result.report.headroomDb, 0);
  for (let output = 0; output < 16; output++) {
    const gains = outputFilters(result, output)
      .map(name => result.config.filters[name])
      .filter(filter => filter.type === 'Gain');
    assert.equal(gains.length, 1, `output ${output + 1} carries exactly one gain`);
    assert.equal(gains[0].parameters.gain, -40);
    assert.equal(Boolean(gains[0].parameters.inverted), false);
    assert.equal(Boolean(gains[0].parameters.mute), false);
    assert.equal(gains[0].parameters.scale, 'dB');
  }
  // The loop must decay: a preset whose worst case reached 0 dBFS would not.
  assert.ok(result.report.worstCaseDbfs.every(level => level === null || level <= -39));
  assert.equal(result.report.warnings.filter(text => text.includes('dBFS')).length, 0);
});

test('the live pair shares one fixed shape and differs only on outputs 3-16', () => {
  const fixed = preset => bridgeArtifact(compile(preset, fileDevices('in.raw', 'out.raw'), {shape: 'fixed'}));
  const base = fixed(liveBasePreset());
  const toggle = fixed(liveTogglePreset());
  assert.equal(artifactShape(base), artifactShape(toggle), 'same shape key');
  assert.notEqual(base, toggle, 'different numbers');
  // Outputs 1 and 2 are byte-identical between the two artifacts: the
  // harness channels see no change from the toggle.
  const outputRows = text => text.split('\n').slice(text.split('\n').findIndex(l => l.startsWith('output ')));
  const rowsFor = (text, index) => {
    const rows = outputRows(text);
    const at = rows.findIndex(r => r.startsWith(`${index} `));
    const sections = Number(rows[at].split(' ')[3]);
    return rows.slice(at, at + 1 + sections).join('\n');
  };
  for (const index of [0, 1]) assert.equal(rowsFor(base, index), rowsFor(toggle, index));
  assert.notEqual(rowsFor(base, 2), rowsFor(toggle, 2));
});

test('the fold presets are 7.2.4 with the paths verify-fold.py models', async () => {
  const { foldPreset, foldFlatPreset } = await import('./verify-presets.mjs');
  const { parseMonitorSection } = await import('./bridge-artifact.mjs');
  const fold = build(foldPreset());
  // Bass management on: 11 main branches, high-passed, and 12 bass branches.
  const kinds = fold.plan.channels.map(channel => channel.kind);
  assert.deepEqual([kinds.filter(k => k === 'main').length, kinds.filter(k => k === 'bass').length,
                    kinds.filter(k => k === 'phones').length], [11, 12, 2]);
  assert.equal(fold.report.crossoverCount, 23);
  assert.equal(fold.report.biquadCount, 22, 'two shaped bands on each of the 11 speakers');
  assert.deepEqual(outputFilters(fold, 2).filter(name => name.startsWith('delay')), ['delay_out3']);
  const monitor = parseMonitorSection(bridgeArtifact(fold));
  assert.deepEqual(monitor.sets.map(set => [set.id, set.kind, set.folds]),
    [['speakers', 'speakers', ['full', '5.1', 'stereo', 'mono']], ['phones', 'headphones', ['full']]]);
  const tagOf = new Map();
  fold.config.mixers.expand.mapping.flatMap(entry => entry.sources.map(() => entry.dest))
    .forEach((dest, row) => tagOf.set(dest, monitor.expandSets[row]));
  fold.plan.channels.forEach((channel, index) =>
    assert.equal(tagOf.get(index), channel.kind === 'phones' ? null : 0, `channel ${index} ${channel.kind}`));
  assert.deepEqual(sourcesOf(fold, 'assign', 13).length, 1);
  assert.equal(fold.report.warnings.filter(text => text.includes('dBFS')).length, 0);

  const flat = build(foldFlatPreset());
  assert.equal(flat.report.headroomDb, 0);
  assert.equal(flat.report.biquadCount, 0);
  // Only the LFE's own low-pass: every speaker is its input view times one.
  assert.equal(flat.report.crossoverCount, 1);
  for (const output of [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11]) {
    assert.deepEqual(outputFilters(flat, output), []);
    const [assign] = sourcesOf(flat, 'assign', output);
    assert.deepEqual(branchFilters(flat, assign.channel), []);
    assert.deepEqual(sourcesOf(flat, 'expand', assign.channel).map(s => [s.channel, s.gain]), [[output, 0]]);
  }
  assert.deepEqual(parseMonitorSection(bridgeArtifact(flat)).sets[0].folds, ['full', '5.1', 'stereo', 'mono']);
});

test('the sets presets put the outputs where verify-sets.py reads them', async () => {
  const { setsPreset } = await import('./verify-presets.mjs');
  const roles = preset => preset.outputs.map((o, i) => [i, o.role, o.busId]).filter(([, role]) => role !== 'unused');
  const mains = [[0, 'speaker', 'speakers'], [1, 'speaker', 'speakers'], [2, 'speaker', 'speakers'], [3, 'sub', 'speakers'],
    [4, 'speaker', 'speakers'], [5, 'speaker', 'speakers']];
  const phones = [[14, 'speaker', 'phones'], [15, 'speaker', 'phones']];
  const near = [[6, 'speaker', 'speakers-2'], [7, 'speaker', 'speakers-2']];
  assert.deepEqual(roles(setsPreset('single')), [...mains, ...phones]);
  for (const share of ['main', 'none']) {
    const preset = setsPreset(share);
    assert.deepEqual(roles(preset), [...mains, ...near, ...phones]);
    assert.equal(preset.buses[1].subShare, share);
    assert.deepEqual([6, 7].map(i => preset.outputs[i].source), [0, 1]);
  }
  assert.deepEqual(roles(setsPreset('own')), [...mains, ...near, [8, 'sub', 'speakers-2'], ...phones]);
  // The mains are the single preset's, output for output, so (b) can compare them byte for byte.
  const single = setsPreset('single'), two = setsPreset('main');
  for (const i of [0, 1, 2, 3, 4, 5, 14, 15]) assert.deepEqual(two.outputs[i], single.outputs[i]);
  assert.deepEqual(two.sends.map(row => row[3]), single.sends.map(row => row[3]));
  assert.equal(single.headroomDb, -18);
});
