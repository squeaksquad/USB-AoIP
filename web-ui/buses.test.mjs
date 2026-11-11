import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, parsePreset, setOutputRole, validateConfig } from './model.mjs';
import { applyBusLayout, busForOutput, createHeadphoneBus, createSpeakerBus, removeBus, setBusGainMute, setHeadphoneMode, setHeadphonePair, setHeadphoneMatrix, speakerGroupSourceIds } from './buses.mjs';
import { swapOutputs } from './workflows.mjs';

test('default owns only the speaker bus and leaves spare outputs reusable', () => {
  const c = createConfig();
  assert.deepEqual(c.buses[0].outputIds, Array.from({length: 13}, (_, i) => i));
  assert.equal(busForOutput(c, 13), null); assert.equal(c.buses.length, 1); validateConfig(c);
});

test('bass routing sources contain only channels assigned to speaker groups', () => {
  const c = createConfig();
  assert.deepEqual(speakerGroupSourceIds(c), Array.from({length: 12}, (_, i) => i));
  const headphones = createHeadphoneBus(c);
  assert.deepEqual(speakerGroupSourceIds(headphones), Array.from({length: 12}, (_, i) => i));
  const stereo = applyBusLayout(headphones, 'speakers', '2.1', [0, 1, 2]);
  assert.deepEqual(speakerGroupSourceIds(stereo), [0, 1, stereo.lfe.input]);
});

test('scoped speaker layout preserves bus settings and unrelated headphone bus', () => {
  const original = createHeadphoneBus(createConfig());
  original.buses[0].gainDb = -3; original.buses[1].mute = true; original.outputs[14].delayMs = 4;
  const next = applyBusLayout(original, 'speakers', '5.1.4', [0,1,2,3,4,5,6,7,8,9]);
  assert.equal(next.buses.find(b => b.id === 'speakers').gainDb, -3);
  assert.equal(next.buses.find(b => b.id === 'headphones').mute, true);
  assert.equal(next.outputs[14].delayMs, 4); assert.equal(next.outputs[14].busId, 'headphones');
  assert.equal(next.buses.find(b => b.id === 'speakers').outputIds.length, 10);
});

test('headphone pair and downmix settings are explicit and retained', () => {
  let c = createHeadphoneBus(createConfig());
  c = setHeadphonePair(c, 'headphones', [4, 5]); c = setHeadphoneMode(c, 'headphones', 'downmix');
  const matrix = Array.from({length: 16}, () => [null, null]); matrix[0][0] = -3; matrix[2][1] = -6;
  c = setHeadphoneMatrix(c, 'headphones', matrix); assert.deepEqual(c.buses[1].inputPair, [4,5]); assert.equal(c.buses[1].downmixMatrix[2][1], -6);
  assert.deepEqual(parsePreset(JSON.stringify(c)), c);
});

test('invalid overlap, matrix values, and reassignment are rejected', () => {
  const c = createHeadphoneBus(createConfig());
  assert.throws(() => applyBusLayout(c, 'headphones', '5.1'));
  assert.throws(() => createHeadphoneBus(c, 'second', [0, 13]));
  const bad = structuredClone(c); bad.buses[1].downmixMatrix[0][0] = 13; assert.throws(() => validateConfig(bad));
  assert.throws(() => setBusGainMute(c, 'speakers', -61, false));
});

test('legacy version 1 import keeps custom outputs without reserving headphones', () => {
  const legacy = createConfig(); legacy.version = 1; delete legacy.buses;
  legacy.outputs[0].label = 'Custom'; legacy.outputs[13].role = 'unused';
  const migrated = parsePreset(JSON.stringify(legacy));
  assert.equal(migrated.version, 2); assert.equal(migrated.outputs[0].label, 'Custom');
  assert.equal(migrated.buses.length, 1); assert.equal(migrated.outputs[14].busId, null); validateConfig(migrated);
});

test('swapping outputs moves bus membership with the physical processing', () => {
  const c = createHeadphoneBus(createConfig()), moved = swapOutputs(c, 14, 13);
  assert.deepEqual(moved.buses.find(b => b.kind === 'headphones').outputIds, [13, 15]);
  assert.equal(moved.outputs[13].busId, 'headphones'); assert.equal(moved.outputs[14].busId, null); validateConfig(moved);
});

test('speaker bus creation and removal preserve unrelated buses', () => {
  let c = removeBus(createConfig(), 'speakers');
  c = createSpeakerBus(c, 'nearfield', [0, 1], 'stereo');
  assert.equal(c.outputs[0].busId, 'nearfield');
  c = createHeadphoneBus(c, 'phones', [14, 15]);
  c = removeBus(c, 'nearfield');
  assert.equal(c.outputs[14].busId, 'phones'); assert.equal(c.buses.filter(b => b.kind === 'speakers').length, 1); validateConfig(c);
});

test('activating an unowned spare attaches it to speakers and protects headphones', () => {
  const c = createConfig();
  setOutputRole(c, 13, 'speaker');
  assert.equal(c.outputs[13].busId, 'speakers'); assert.ok(c.buses[0].outputIds.includes(13));
  validateConfig(c);
  const h = createHeadphoneBus(createConfig());
  assert.throws(() => setOutputRole(h, 14, 'sub'));
});
