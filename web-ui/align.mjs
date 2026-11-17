// Align by distance: arithmetic on the per-output delay fields. The farthest
// speaker gets no delay and each nearer one is delayed by the time sound takes
// to cover the difference. The engine holds at most 10 ms per output (the
// model's limit), which is about 3.4 m of path difference; a nearer speaker
// that would need more is held at the limit and reported.

export const SPEED_OF_SOUND_M_S = 343;
export const MAX_DELAY_MS = 10;
export const METRES_PER_FOOT = 0.3048;

/** "2.5", "2,5" or "" as typed; null for blank, NaN for anything else. */
export function parseDistance(text) {
  const trimmed = String(text ?? '').trim().replace(',', '.');
  if (!trimmed) return null;
  return /^\d+(\.\d*)?$|^\.\d+$/.test(trimmed) ? Number(trimmed) : NaN;
}

/**
 * distances: one per output, a number in `unit` or null to leave that output
 * alone. Returns {delays, limited, farthest}: delays[i] in ms rounded to
 * 0.01 (null where no distance was given), limited the indices held at the
 * limit, farthest the largest distance in `unit` (null when none was given).
 */
export function delaysFromDistances(distances, unit = 'm', maxMs = MAX_DELAY_MS) {
  if (!['m', 'ft'].includes(unit)) throw new Error('Distances are in metres or feet');
  const metres = distances.map(d => {
    if (d === null || d === undefined) return null;
    if (typeof d !== 'number' || !Number.isFinite(d) || d < 0) throw new Error('Each distance must be a number, zero or more');
    return unit === 'ft' ? d * METRES_PER_FOOT : d;
  });
  const given = metres.filter(d => d !== null);
  if (!given.length) return {delays: metres.map(() => null), limited: [], farthest: null};
  const far = Math.max(...given), limited = [];
  const delays = metres.map((d, i) => {
    if (d === null) return null;
    const ms = (far - d) / SPEED_OF_SOUND_M_S * 1000;
    if (ms > maxMs) { limited.push(i); return maxMs; }
    return Math.round(ms * 100) / 100;
  });
  return {delays, limited, farthest: unit === 'ft' ? far / METRES_PER_FOOT : far};
}
