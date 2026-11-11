import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig } from './model.mjs';
import { createSlots, switchSlot, copySlot, slotSummary } from './profiles.mjs';

test('slot B is seeded from the live draft the first time it is selected', () => {
  const config = createConfig(); config.name = 'Room A';
  const state = createSlots(config);
  const result = switchSlot(state, 'B', config);
  assert.equal(result.state.active, 'B');
  assert.equal(result.seeded, true);
  assert.equal(result.config.name, 'Room A');
  assert.notEqual(result.config, config, 'slots hold independent copies');
});

test('switching back returns the stored draft of the other slot', () => {
  const a = createConfig(); a.name = 'Room A';
  let state = createSlots(a);
  let moved = switchSlot(state, 'B', a);
  const b = moved.config; b.name = 'Room B'; b.outputs[0].gainDb = -6;
  moved = switchSlot(moved.state, 'A', b);
  assert.equal(moved.config.name, 'Room A');
  assert.equal(moved.config.outputs[0].gainDb, 0);
  const back = switchSlot(moved.state, 'B', moved.config);
  assert.equal(back.config.name, 'Room B');
  assert.equal(back.config.outputs[0].gainDb, -6);
  assert.equal(back.seeded, false);
});

test('copy overwrites the target slot without changing the live draft', () => {
  const a = createConfig(); a.name = 'Room A';
  let state = createSlots(a);
  const moved = switchSlot(state, 'B', a);
  const b = moved.config; b.name = 'Room B';
  state = copySlot(moved.state, 'B', 'A', b);
  assert.equal(state.slots.A.name, 'Room B');
  assert.equal(state.active, 'B');
  assert.equal(b.name, 'Room B');
});

test('slot arguments are checked', () => {
  const config = createConfig();
  const state = createSlots(config);
  assert.throws(() => switchSlot(state, 'C', config), /slot A or B/);
  assert.throws(() => copySlot(state, 'A', 'A', config), /different slots/);
  assert.throws(() => copySlot(state, 'B', 'A', config), /empty/);
});

test('the summary reports the live draft for the active slot', () => {
  const config = createConfig(); config.name = 'Room A';
  const state = createSlots(config);
  config.name = 'Room A edited';
  assert.deepEqual(slotSummary(state, config), [
    { name: 'A', active: true, filled: true, label: 'Room A edited' },
    { name: 'B', active: false, filled: false, label: 'Empty' }
  ]);
});
