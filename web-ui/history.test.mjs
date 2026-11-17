import test from 'node:test';
import assert from 'node:assert/strict';
import { History } from './history.mjs';

test('undo and redo walk the recorded states', () => {
  const h = new History();
  assert.equal(h.canUndo, false);
  assert.equal(h.undo('a'), null);
  h.record('a'); h.record('b');            // edits a -> b -> c
  assert.equal(h.undo('c'), 'b');
  assert.equal(h.undo('b'), 'a');
  assert.equal(h.canUndo, false);
  assert.equal(h.redo('a'), 'b');
  assert.equal(h.redo('b'), 'c');
  assert.equal(h.redo('c'), null);
});

test('a new edit ends redo', () => {
  const h = new History();
  h.record('a');
  assert.equal(h.undo('b'), 'a');
  assert.equal(h.canRedo, true);
  h.record('a');
  assert.equal(h.canRedo, false);
});

test('the oldest step is dropped at the limit', () => {
  const h = new History(2);
  h.record(1); h.record(2); h.record(3);
  assert.equal(h.undo(4), 3);
  assert.equal(h.undo(3), 2);
  assert.equal(h.undo(2), null);
});

test('clear forgets both directions', () => {
  const h = new History();
  h.record('a'); h.undo('b'); h.record('a');
  h.clear();
  assert.equal(h.canUndo, false);
  assert.equal(h.canRedo, false);
  assert.throws(() => new History(0));
});
