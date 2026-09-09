import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, validateConfig, eqResponse } from './model.mjs';
import { resetEq, setEqBypass, linkedEqOutputs, mirrorLinkedEq } from './eq-tools.mjs';
import { createHeadphoneBus, setBusEqLink } from './buses.mjs';

const edited = () => {
  const config = createConfig();
  config.outputs[0].bands[2] = { enabled: true, type: 'highShelf', frequency: 5000, gainDb: 6, q: 2 };
  config.outputs[0].bands[3].enabled = false;
  config.outputs[1].bands[0].gainDb = -4;
  return config;
};

test('resetting one output restores defaults and leaves other outputs alone', () => {
  const next = resetEq(edited(), 0);
  assert.deepEqual(next.outputs[0].bands[2], { enabled: true, type: 'bell', frequency: 63, gainDb: 0, q: 1 });
  assert.equal(next.outputs[0].bands[3].enabled, false, 'band on/off state is retained');
  assert.equal(next.outputs[1].bands[0].gainDb, -4);
});

test('resetting all outputs clears every band but keeps gain, delay and routing', () => {
  const config = edited();
  config.outputs[1].delayMs = 2.5; config.outputs[1].gainDb = -3;
  const next = resetEq(config, null);
  assert.ok(next.outputs.every(o => o.bands.every(b => b.gainDb === 0 && b.q === 1 && b.type === 'bell')));
  assert.equal(next.outputs[1].delayMs, 2.5);
  assert.equal(next.outputs[1].gainDb, -3);
  assert.deepEqual(next.sends, config.sends);
});

test('resetEq rejects an out-of-range output', () => {
  assert.throws(() => resetEq(createConfig(), 16), /1 to 16/);
});

test('global bypass zeroes the calculated response and restores it unchanged', () => {
  const config = edited();
  const before = eqResponse(config.outputs[0], 5000);
  assert.ok(Math.abs(before) > 1);
  const bypassed = setEqBypass(config, true);
  assert.equal(eqResponse(bypassed.outputs[0], 5000, bypassed.eqBypass), 0);
  assert.ok(bypassed.outputs[0].eqEnabled, 'per-output enables are retained');
  const restored = setEqBypass(bypassed, false);
  assert.equal(eqResponse(restored.outputs[0], 5000, restored.eqBypass), before);
});

test('bypass rejects a non-boolean and survives validation', () => {
  assert.throws(() => setEqBypass(createConfig(), 'on'), /on or off/);
  assert.doesNotThrow(() => validateConfig(setEqBypass(createConfig(), true)));
});

test('headphone EQ links both ears only when enabled', () => {
  let config = createHeadphoneBus(createConfig());
  const [left, right] = config.buses.at(-1).outputIds;
  assert.deepEqual(linkedEqOutputs(config, left), []);
  config.outputs[left].bands[1].gainDb = 3;
  config = setBusEqLink(config, 'headphones', true);
  assert.deepEqual(linkedEqOutputs(config, left), [right]);
  assert.equal(config.outputs[right].bands[1].gainDb, 3, 'enabling the link copies the first ear');
  config.outputs[right].bands[4].gainDb = -5;
  const mirrored = mirrorLinkedEq(config, right);
  assert.equal(mirrored.outputs[left].bands[4].gainDb, -5, 'either ear drives the other');
  assert.equal(mirrored.outputs[left].delayMs, config.outputs[left].delayMs, 'alignment is not linked');
});

test('unlinking stops mirroring and leaves both ears editable', () => {
  let config = setBusEqLink(createHeadphoneBus(createConfig()), 'headphones', true);
  config = setBusEqLink(config, 'headphones', false);
  const [left, right] = config.buses.at(-1).outputIds;
  config.outputs[right].bands[0].gainDb = 2;
  assert.deepEqual(mirrorLinkedEq(config, right), config);
  assert.equal(config.outputs[left].bands[0].gainDb, 0);
});

test('EQ linking is rejected on a speaker bus', () => {
  assert.throws(() => setBusEqLink(createConfig(), 'speakers', true), /headphones/);
});

test('headphone outputs move to any chosen physical pair, carrying their processing', async () => {
  const { setBusOutputs } = await import('./buses.mjs');
  let config = createHeadphoneBus(createConfig());
  config.outputs[14].gainDb = -4; config.outputs[14].delayMs = 1.5; config.outputs[15].label = 'Cans R';
  config = setBusOutputs(config, 'headphones', [13, 15]);
  assert.deepEqual(config.buses.at(-1).outputIds, [13, 15]);
  assert.equal(config.outputs[13].gainDb, -4);
  assert.equal(config.outputs[13].delayMs, 1.5);
  assert.equal(config.outputs[15].label, 'Cans R');
  assert.equal(config.outputs[14].busId, null, 'the vacated output is free again');
  assert.equal(config.outputs[14].role, 'unused');
});

test('swapping the two ears keeps both in the bus', async () => {
  const { setBusOutputs } = await import('./buses.mjs');
  let config = createHeadphoneBus(createConfig());
  config.outputs[14].label = 'Ear L'; config.outputs[15].label = 'Ear R';
  config = setBusOutputs(config, 'headphones', [15, 14]);
  assert.deepEqual(config.buses.at(-1).outputIds, [15, 14]);
  assert.equal(config.outputs[15].label, 'Ear L');
  assert.equal(config.outputs[14].label, 'Ear R');
});

test('moving onto an occupied output exchanges it with the speaker bus, never doubling ownership', async () => {
  const { setBusOutputs } = await import('./buses.mjs');
  let config = createHeadphoneBus(createConfig());
  const speakerLabel = config.outputs[0].label;
  config = setBusOutputs(config, 'headphones', [0, 15]);
  assert.deepEqual(config.buses.at(-1).outputIds, [0, 15]);
  assert.equal(config.outputs[14].label, speakerLabel, 'the displaced speaker took the freed output');
  assert.equal(config.outputs[14].busId, 'speakers');
  assert.equal(config.outputs[0].busId, 'headphones');
});

test('bus output moves reject a duplicate or out-of-range choice', async () => {
  const { setBusOutputs } = await import('./buses.mjs');
  const config = createHeadphoneBus(createConfig());
  assert.throws(() => setBusOutputs(config, 'headphones', [3, 3]), /distinct/);
  assert.throws(() => setBusOutputs(config, 'headphones', [3, 16]), /1 to 16/);
});

test('outputs in a headphones bus read as headphones, not speakers', async () => {
  const { outputRoleLabel, createHeadphoneBus: makeBus } = await import('./buses.mjs');
  const config = makeBus(createConfig());
  const [left, right] = config.buses.at(-1).outputIds;
  assert.deepEqual(outputRoleLabel(config, left), { short: 'PHONES L', long: 'Headphone', kind: 'headphone' });
  assert.equal(outputRoleLabel(config, right).short, 'PHONES R');
  assert.equal(outputRoleLabel(config, 0).short, 'SPEAKER');
  assert.equal(outputRoleLabel(config, 3).short, 'SUB');
  assert.equal(outputRoleLabel(createConfig(), 15).short, 'SPARE');
  assert.throws(() => outputRoleLabel(config, 16), /1 to 16/);
});
