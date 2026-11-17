import test from 'node:test';
import assert from 'node:assert/strict';
import { presetSlug, storeName, nameProblem, presetRows } from './presets.mjs';

test('slug and store name', () => {
  assert.equal(presetSlug('Immersive · stereo subs'), 'immersive-stereo-subs');
  assert.equal(presetSlug('···'), '');
  assert.equal(presetSlug('A'.repeat(40)).length, 24);
  assert.equal(storeName('Immersive · stereo  subs'), 'Immersive - stereo subs');
});

test('nameProblem', () => {
  assert.equal(nameProblem('Room A', ['Room B']), '');
  assert.match(nameProblem('  '), /Give it a name/);
  assert.match(nameProblem('Room/A'), /letters, digits/);
  assert.match(nameProblem('room a', ['Room A']), /already/);
  assert.equal(nameProblem('Room A', ['Room A'], 'Room A'), '', 'renaming to itself is not a clash');
  assert.match(nameProblem('---'), /at least one letter/);
});

test('rows join what is saved with what is installed', () => {
  const {fixed, presets} = presetRows({
    stored: {'Room A': {}, 'Draft only': {}},
    installed: [{name: 'dante-room-a', slug: 'room-a', live: true}, {name: 'dante-old', slug: 'old', live: false}],
    profiles: [{name: 'direct', description: 'x', live: false}],
    canApply: true,
  });
  assert.deepEqual(fixed, [{name: 'direct', title: 'Direct', note: 'No processing: audio passes through unchanged', running: false, canRun: true}]);
  assert.deepEqual(presets.map(p => p.name), ['Room A', 'Draft only', 'old']);
  const [room, draft, old] = presets;
  assert.deepEqual([room.running, room.canRun, room.canEdit, room.canRename, room.canRemove], [true, false, true, false, false]);
  assert.deepEqual([draft.installed, draft.canRun, draft.canRename, draft.canRemove], [false, true, true, true]);
  assert.deepEqual([old.stored, old.canRun, old.canEdit, old.canRemove], [false, true, false, true]);
  assert.match(old.note, /not saved with it/);
});

test('not connected: nothing can run', () => {
  const {fixed, presets} = presetRows({stored: {'Room A': {}}});
  assert.deepEqual(fixed, []);
  assert.equal(presets[0].canRun, false);
  assert.equal(presets[0].note, 'Saved');
});
