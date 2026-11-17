import test from 'node:test';
import assert from 'node:assert/strict';
import { readPrefs, savePrefs, PREFS_KEY } from './prefs.mjs';

const fake = () => { const m = new Map(); return {getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v)}; };

test('larger controls are remembered', () => {
  const storage = fake();
  assert.deepEqual(readPrefs(storage), {big: false});
  assert.equal(savePrefs({big: true}, storage), true);
  assert.deepEqual(readPrefs(storage), {big: true});
});

test('bad or missing storage reads as the defaults', () => {
  const storage = fake();
  storage.setItem(PREFS_KEY, '{not json');
  assert.deepEqual(readPrefs(storage), {big: false});
  const refusing = {getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); }};
  assert.deepEqual(readPrefs(refusing), {big: false});
  assert.equal(savePrefs({big: true}, refusing), false);
});
