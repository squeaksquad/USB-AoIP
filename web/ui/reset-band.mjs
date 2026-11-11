import { FREQUENCIES } from './model.mjs';

export function resetBand(band, index) {
  if (!band || !Number.isInteger(index) || index < 0 || index >= FREQUENCIES.length) {
    throw new Error('Expected an EQ band index from 1–16');
  }
  return { ...band, type: 'bell', frequency: FREQUENCIES[index], gainDb: 0, q: 1 };
}
