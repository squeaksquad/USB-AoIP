// Several speaker sets (preset model v3, phase 3 step 6): what a second set
// compiles to, and the pin that a preset with one speaker set compiles to the
// bytes it compiled to before v3.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { compile, fileDevices } from './compile.mjs';
import { bridgeArtifact, artifactShape, parseMonitorSection } from './bridge-artifact.mjs';
import { PRESETS, setsPreset, liveTogglePreset } from './verify-presets.mjs';
import { createConfig } from '../web-ui/model.mjs';
import { LAYOUTS, applyLayout, blankConfig } from '../web-ui/workflows.mjs';
import { addSpeakerSet, createHeadphoneBus } from '../web-ui/buses.mjs';

const sha = text => createHash('sha256').update(text).digest('hex').slice(0, 16);
const build = (preset, options = {}, rate = 48000) =>
  compile(preset, fileDevices('in.raw', 'out.raw', 'S32_LE', 1024, rate), options);
const artifact = (preset, options = {}) => bridgeArtifact(build(preset, options), {presetName: preset.name});

test('one speaker set compiles to the bytes it did before model v3', () => {
  const pins = JSON.parse(readFileSync(new URL('./fixtures/single-set-pins.json', import.meta.url), 'utf8'));
  delete pins.about;
  const presets = {
    default: () => createConfig(),
    'default+phones': () => createHeadphoneBus(createConfig()),
    blank: () => blankConfig('Blank'),
  };
  for (const layout of LAYOUTS) presets[`layout-${layout.id}`] = () => applyLayout(createConfig(), layout.id);
  presets['layout-5.1+phones'] = () => createHeadphoneBus(applyLayout(createConfig(), '5.1'), 'headphones', [14, 15]);
  for (const name of ['crossover', 'clip', 'default', 'loaded', 'transparent', 'fold', 'fold-flat']) presets[`verify-${name}`] = PRESETS[name];
  presets['verify-live-toggle'] = liveTogglePreset;
  presets['default-nobass'] = () => { const p = createConfig(); p.bassEnabled = false; return p; };
  let checked = 0;
  for (const [name, make] of Object.entries(presets)) {
    for (const rate of [48000, 96000]) for (const shape of ['minimal', 'fixed']) for (const monitor of [false, true]) {
      const key = `${name} ${rate} ${shape} ${monitor ? 'monitor' : 'plain'}`;
      const preset = make();
      const result = build(preset, {shape, monitor}, rate);
      const text = bridgeArtifact(result, {presetName: preset.name});
      const camilla = structuredClone(result.config);
      delete camilla.description;   // names the model version, 2 then 3
      assert.deepEqual([sha(text), sha(artifactShape(text)), sha(JSON.stringify(camilla))], pins[key], key);
      checked += 1;
    }
  }
  assert.equal(checked, Object.keys(pins).length, 'every pin was checked');
});

const kinds = result => result.plan.channels.map(c => `${c.kind}${c.kind === 'phones' ? '' : `${c.input + 1}@${c.set}`}`);
const assignOf = (result, output) => result.config.mixers.assign.mapping.find(m => m.dest === output).sources;
const branchOf = (result, channel) => result.config.pipeline
  .slice(0, result.config.pipeline.findIndex(s => s.name === 'assign'))
  .filter(s => s.type === 'Filter' && s.channels.includes(channel)).flatMap(s => s.names);

test('a set sharing the main sub: its own main and bass branches, and the main sub carries both', () => {
  const preset = setsPreset('main');
  const result = build(preset);
  assert.deepEqual(kinds(result), ['main1@0', 'main2@0', 'main3@0', 'main5@0', 'main6@0', 'main1@1', 'main2@1', 'phones', 'phones',
    'bass1@0', 'bass2@0', 'bass3@0', 'bass4@0', 'bass5@0', 'bass6@0', 'bass1@1', 'bass2@1', 'bass4@1']);
  const nearMain = result.plan.sets[1].mainOf.get(0);
  assert.deepEqual(branchOf(result, nearMain), ['hp_set2_in1'], 'the nearfield is high-passed under its own name');
  assert.deepEqual(branchOf(result, result.plan.sets[1].bassOf.get(3)), ['lp_set2_in4']);
  assert.equal(assignOf(result, 6)[0].channel, nearMain);
  // The sub: the mains' bass then the nearfield's, each with the sends its inputs have to it.
  const sub = assignOf(result, 3).map(s => [kinds(result)[s.channel], s.gain]);
  assert.deepEqual(sub, [['bass1@0', 0], ['bass2@0', 0], ['bass3@0', 0], ['bass4@0', 0], ['bass5@0', 0], ['bass6@0', 0],
    ['bass1@1', 0], ['bass2@1', 0], ['bass4@1', 0]]);
  const monitor = parseMonitorSection(artifact(preset));
  assert.deepEqual(monitor.sets.map(s => [s.id, s.kind, s.folds]), [['speakers', 'speakers', ['full', 'stereo', 'mono', 'off']],
    ['speakers-2', 'speakers', ['full', 'mono', 'off']], ['phones', 'headphones', ['full']]]);
  assert.deepEqual(monitor.outs.find(o => o.index === 3), {index: 3, role: 'sub', sets: [0, 1]});
  assert.deepEqual(monitor.outs.find(o => o.index === 6), {index: 6, role: 'speaker', sets: [1]});
  const expandKinds = result.config.mixers.expand.mapping.flatMap(entry => entry.sources.map(() => kinds(result)[entry.dest]));
  assert.deepEqual(monitor.expandSets, expandKinds.map(k => (k === 'phones' ? null : Number(k.split('@')[1]))));
  for (const set of [0, 1]) assert.deepEqual(monitor.folds.filter(f => f.set === set).at(-1), {set, name: 'off', rows: [[0, 0, 0]]});
  // Under All sets both sets' bass reach the sub: the ceiling says so.
  const single = build(setsPreset('single'));
  assert.ok(result.report.worstCaseDbfs[3] > single.report.worstCaseDbfs[3]);
});

test('a set with no subwoofer runs full range and feeds no sub', () => {
  const result = build(setsPreset('none'));
  assert.equal(result.plan.sets[1].bassOf.size, 0);
  assert.deepEqual(branchOf(result, result.plan.sets[1].mainOf.get(0)), [], 'no high-pass on the nearfield');
  assert.ok(assignOf(result, 3).every(s => result.plan.channels[s.channel].set === 0));
  const fixed = build(setsPreset('none'), {shape: 'fixed'});
  const names = branchOf(fixed, fixed.plan.sets[1].mainOf.get(0));
  assert.deepEqual(names, ['hp_set2_in1_off1', 'hp_set2_in1_off2'], 'the fixed shape holds unity slots, as a crossover switched off');
  assert.ok(names.every(name => fixed.config.filters[name].parameters.type === 'Free'));
  assert.deepEqual(parseMonitorSection(artifact(setsPreset('none'))).outs.find(o => o.index === 3).sets, [0]);
});

test('a set with its own sub feeds it alone', () => {
  const result = build(setsPreset('own'));
  assert.deepEqual([...result.plan.sets[1].bassOf.keys()], [0, 1, 3]);
  assert.ok(assignOf(result, 8).every(s => result.plan.channels[s.channel].set === 1));
  assert.ok(assignOf(result, 3).every(s => result.plan.channels[s.channel].set === 0));
  const monitor = parseMonitorSection(artifact(setsPreset('own')));
  assert.deepEqual(monitor.outs.filter(o => o.role === 'sub'), [{index: 3, role: 'sub', sets: [0]}, {index: 8, role: 'sub', sets: [1]}]);
});

test('with one speaker set there is no off fold; a 7.2.4 main set with a second set stays within four folds', () => {
  assert.ok(!parseMonitorSection(artifact(setsPreset('single'))).folds.some(f => f.name === 'off'));
  const big = addSpeakerSet(createConfig(), {layoutId: 'stereo', outputIds: [13, 14], subShare: 'main'});
  const monitor = parseMonitorSection(artifact(big));
  assert.deepEqual(monitor.sets[0].folds, ['full', '5.1', 'stereo', 'mono', 'off']);
});

test('two sets: value edits are live, the set structure is not', () => {
  const shapeOf = preset => artifactShape(artifact(preset, {shape: 'fixed'}));
  const base = shapeOf(setsPreset('main'));
  const live = {
    'a send to the shared sub': p => { p.sends[0][3] = -4; },
    'a nearfield band': p => { p.outputs[6].bands[2].gainDb = 6; },
    'a crossover': p => { p.inputs[0].highpassHz = 90; },
    'the nearfield renamed': p => { p.buses[1].label = 'Desk'; },
    'bass redirection off': p => { p.bassEnabled = false; },
  };
  for (const [name, edit] of Object.entries(live)) { const p = setsPreset('main'); edit(p); assert.equal(shapeOf(p), base, name); }
  assert.notEqual(shapeOf(setsPreset('none')), base, 'shares the sub -> no sub');
  assert.notEqual(shapeOf(setsPreset('single')), base, 'adding the set');
});

test('the Python readers\' two-set fixtures are this compiler\'s', async () => {
  const preset = JSON.parse(readFileSync(new URL('../web-control/fixtures/preset-sets-v3.json', import.meta.url), 'utf8'));
  assert.deepEqual(preset, setsPreset('main'), 'web-control/fixtures/preset-sets-v3.json');
  const text = readFileSync(new URL('../web-control/fixtures/monitor-sets.dsp', import.meta.url), 'utf8');
  assert.equal(text, artifact(preset, {shape: 'fixed'}), 'web-control/fixtures/monitor-sets.dsp');
});
