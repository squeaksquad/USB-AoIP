import test from 'node:test';
import assert from 'node:assert/strict';
import { MeterHold, levelPercent } from './meter-hold.mjs';

const bank = (peak, clipped = 0) => [{peak, clipped}];

test('the hold keeps the highest peak, then falls after the hold time', () => {
  const m = new MeterHold(1, 1000);
  assert.equal(m.update(bank(-20), 0)[0].hold, -20);
  assert.equal(m.update(bank(-30), 500)[0].hold, -20);
  assert.equal(m.update(bank(-12), 600)[0].hold, -12);
  assert.equal(m.update(bank(-30), 1500)[0].hold, -12);
  assert.equal(m.update(bank(-30), 1700)[0].hold, -30);
});

test('a clip latches from a rising count and stays until cleared', () => {
  const m = new MeterHold(1);
  assert.equal(m.update(bank(-3, 7), 0)[0].clip, false, 'the first count seen is not a new clip');
  assert.equal(m.update(bank(-3, 7), 100)[0].clip, false);
  assert.equal(m.update(bank(0, 8), 200)[0].clip, true);
  assert.equal(m.update(bank(-40, 8), 60000)[0].clip, true);
  assert.equal(m.anyClip, true);
  m.clearClips();
  assert.equal(m.update(bank(-40, 8), 60100)[0].clip, false);
});

test('a count that went down (engine restarted) does not latch', () => {
  const m = new MeterHold(1);
  m.update(bank(-3, 9), 0);
  assert.equal(m.update(bank(-3, 0), 100)[0].clip, false);
  assert.equal(m.update(bank(-3, 1), 200)[0].clip, true);
});

test('a missing channel reads as silence', () => {
  const m = new MeterHold(2);
  const out = m.update([{peak: -6, clipped: 0}], 0);
  assert.deepEqual(out[1], {peak: -60, hold: -60, clip: false});
});

test('bar height', () => {
  assert.equal(levelPercent(0), 100);
  assert.equal(levelPercent(-30), 50);
  assert.equal(levelPercent(-90), 0);
  assert.equal(levelPercent(null), 0);
  assert.equal(levelPercent(6), 100);
});
