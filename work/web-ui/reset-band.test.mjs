import test from 'node:test';
import assert from 'node:assert/strict';
import { resetBand } from './reset-band.mjs';

test('resetBand restores indexed defaults while preserving enabled and other band fields', () => {
  const band = { enabled: false, type: 'lowShelf', frequency: 777, gainDb: -8, q: 4, extra: 'keep' };
  assert.deepEqual(resetBand(band, 4), { enabled: false, type: 'bell', frequency: 160, gainDb: 0, q: 1, extra: 'keep' });
  assert.deepEqual(band, { enabled: false, type: 'lowShelf', frequency: 777, gainDb: -8, q: 4, extra: 'keep' });
  assert.throws(() => resetBand(band, -1));
  assert.throws(() => resetBand(band, 16));
});
