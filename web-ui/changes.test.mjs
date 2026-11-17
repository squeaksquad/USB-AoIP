import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig } from './model.mjs';
import { countChanges, changeBar } from './changes.mjs';

test('the same preset has no changes', () => {
  assert.equal(countChanges(createConfig(), createConfig()), 0);
});

test('each thing touched counts once', () => {
  const base = createConfig(), draft = createConfig();
  draft.outputs[0].gainDb = -3;                 // one output field
  draft.outputs[0].bands[2].gainDb = 4;         // one band, two numbers in it
  draft.outputs[0].bands[2].q = 2;
  draft.sends[0][3] = -6;                       // one send
  draft.lfe.trimDb = 3;
  draft.inputs[1].highpassHz = 100;
  draft.buses[0].label = 'Mains';
  draft.name = 'Other';
  assert.equal(countChanges(base, draft), 7);
});

test('an added headphones counts once', () => {
  const base = createConfig(), draft = createConfig();
  draft.buses.push({id: 'headphones', kind: 'headphones', label: 'Headphones', outputIds: [14, 15]});
  assert.equal(countChanges(base, draft), 1);
});

const live = {state: 'live', previewing: false, profile: 'dante-room'};

test('not connected: changes stay in the page', () => {
  assert.equal(changeBar({connected: false, live: null, changes: 0}).kind, 'none');
  const bar = changeBar({connected: false, live: null, changes: 2});
  assert.equal(bar.kind, 'offline');
  assert.equal(bar.text, '2 changes');
  assert.deepEqual(bar.buttons, ['discard', 'save']);
});

test('live edits are playing and can be kept', () => {
  assert.equal(changeBar({connected: true, live, changes: 0}).kind, 'none');
  const bar = changeBar({connected: true, live, changes: 1});
  assert.equal(bar.kind, 'live');
  assert.equal(bar.text, '1 change');
  assert.deepEqual(bar.buttons, ['discard', 'keep', 'save-as']);
  const foreign = changeBar({connected: true, live: {...live, previewing: true}, changes: 0});
  assert.equal(foreign.kind, 'live');
  assert.deepEqual(foreign.buttons, ['discard', 'keep']);
});

test('a change of shape needs a restart', () => {
  const bar = changeBar({connected: true, live: {...live, state: 'needs-apply'}, changes: 3, outage: 'audio stops briefly'});
  assert.equal(bar.kind, 'restart');
  assert.match(bar.detail, /needs a restart, audio stops briefly/);
  assert.deepEqual(bar.buttons, ['discard', 'apply', 'save-as']);
});

test('a preset that is not the running one offers to apply it', () => {
  const direct = {state: 'not-previewable', reason: 'direct is live', profile: 'direct'};
  const bar = changeBar({connected: true, live: direct, changes: 0, running: 'Direct (no DSP)'});
  assert.equal(bar.kind, 'not-running');
  assert.match(bar.detail, /Direct \(no DSP\)/);
  assert.deepEqual(bar.buttons, ['apply']);
  assert.equal(changeBar({connected: true, live: {...live, state: 'needs-apply'}, changes: 0}).kind, 'not-running');
});

test('a device that cannot apply offers only to save or discard', () => {
  const no = {state: 'not-previewable', reason: 'Apply is not installed on this Pi.', profile: null};
  assert.equal(changeBar({connected: true, applyAvailable: false, live: no, changes: 0}).kind, 'none');
  const bar = changeBar({connected: true, applyAvailable: false, live: no, changes: 1});
  assert.deepEqual(bar.buttons, ['discard', 'save']);
  assert.match(bar.detail, /Apply is not installed/);
});

test('a new preset that was never saved can be saved before anything else changes', () => {
  const bar = changeBar({connected: false, live: null, changes: 0, fresh: true});
  assert.equal(bar.text, 'New preset');
  assert.deepEqual(bar.buttons, ['save']);
  const no = {state: 'not-previewable', reason: 'Apply is not installed on this Pi.', profile: null};
  assert.deepEqual(changeBar({connected: true, applyAvailable: false, live: no, changes: 0, fresh: true}).buttons, ['save']);
});
