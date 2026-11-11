// Biquad coefficients for the bridge's own filter stage.
//
// The bridge runs difference equations; it does not derive filters. Every
// coefficient is computed here, by the same formulas that were checked against
// CamillaDSP 4.1.3 in run dsp-verify-20260910T164810Z, so the bridge's
// correctness reduces to "does it run a biquad", which is trivial to test.
//
// Two sources, both already verified:
//
//   * The PEQ biquads use the W3C Audio EQ Cookbook forms in
//     `work/web-ui/model.mjs` -- the same expressions `bandResponse` evaluates
//     to draw the curve. The engine agreed with that curve to 5e-5 dB over 800
//     comparison points, so emitting its coefficients is emitting a filter
//     three implementations already agree on.
//   * The crossovers use a Butterworth cascade applied twice, which is what a
//     Linkwitz-Riley is. The engine agreed with that model to 0.0 dB on all
//     eight branches of the crossover run.
//
// Coefficients are normalised so a0 is 1 and are returned as
// {b0, b1, b2, a1, a2} for the difference equation
//
//     y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]
//
// which is the sign convention the bridge implements. A first-order section
// sets b2 and a2 to zero rather than being a special case downstream.

export const SAMPLE_RATE = 48000;

// Butterworth pole Qs by order; a Linkwitz-Riley of order N is the Butterworth
// of order N/2 applied twice. Order 1 is the lone real pole and carries no Q.
const BUTTERWORTH_Q = {
  1: [],
  2: [0.70710678118654752],
  4: [0.54119610014619698, 1.30656296487637652],
};

const LINKWITZ_RILEY_BUTTERWORTH = {12: 1, 24: 2, 48: 4};

/** Normalise by a0 into the bridge's difference-equation convention. */
function normalise(b0, b1, b2, a0, a1, a2) {
  return {
    b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
    a1: a1 / a0, a2: a2 / a0,
  };
}

/**
 * One PEQ band, in the cookbook forms `bandResponse` in model.mjs evaluates.
 *
 * The expressions are deliberately written the same way they are there. The
 * shelves are the risk in this family -- the cookbook also defines them by
 * slope S, and a mismatch would make the UI's plot quietly wrong -- so keeping
 * the two textually parallel is worth more than factoring them.
 */
export function bandBiquad(band, rate = SAMPLE_RATE) {
  const A = 10 ** (band.gainDb / 40);
  const w = 2 * Math.PI * band.frequency / rate;
  const c = Math.cos(w);
  const alpha = Math.sin(w) / (2 * band.q);
  const t = 2 * Math.sqrt(A) * alpha;
  if (band.type === 'lowShelf') {
    return normalise(
      A * ((A + 1) - (A - 1) * c + t),
      2 * A * ((A - 1) - (A + 1) * c),
      A * ((A + 1) - (A - 1) * c - t),
      (A + 1) + (A - 1) * c + t,
      -2 * ((A - 1) + (A + 1) * c),
      (A + 1) + (A - 1) * c - t);
  }
  if (band.type === 'highShelf') {
    return normalise(
      A * ((A + 1) + (A - 1) * c + t),
      -2 * A * ((A - 1) + (A + 1) * c),
      A * ((A + 1) + (A - 1) * c - t),
      (A + 1) - (A - 1) * c + t,
      2 * ((A - 1) - (A + 1) * c),
      (A + 1) - (A - 1) * c - t);
  }
  if (band.type !== 'bell') throw new Error(`Unknown band type ${band.type}`);
  return normalise(
    1 + alpha * A, -2 * c, 1 - alpha * A,
    1 + alpha / A, -2 * c, 1 - alpha / A);
}

/** A second-order Butterworth section at `q`. */
function butterworthSection(kind, freq, q, rate) {
  const w0 = 2 * Math.PI * freq / rate;
  const c = Math.cos(w0);
  const alpha = Math.sin(w0) / (2 * q);
  const [b0, b1, b2] = kind === 'lowpass'
    ? [(1 - c) / 2, 1 - c, (1 - c) / 2]
    : [(1 + c) / 2, -(1 + c), (1 + c) / 2];
  return normalise(b0, b1, b2, 1 + alpha, -2 * c, 1 - alpha);
}

/** The bilinear-transformed one-pole an odd Butterworth order needs. */
function firstOrderSection(kind, freq, rate) {
  const k = Math.tan(Math.PI * freq / rate);
  const [b0, b1] = kind === 'lowpass'
    ? [k / (1 + k), k / (1 + k)]
    : [1 / (1 + k), -1 / (1 + k)];
  return {b0, b1, b2: 0, a1: (k - 1) / (k + 1), a2: 0};
}

/**
 * A Linkwitz-Riley crossover branch, as a cascade of biquads.
 *
 * `slope` is the user-facing 12/24/48 dB per octave. The cascade is the
 * Butterworth of half that order, listed twice -- that repetition is the
 * Linkwitz-Riley, and it is why the branches are -6 dB at the corner rather
 * than -3 and why two of them sum flat.
 */
export function crossoverBiquads(kind, freq, slope, rate = SAMPLE_RATE) {
  const order = LINKWITZ_RILEY_BUTTERWORTH[slope];
  if (order === undefined) throw new Error(`Unsupported slope ${slope}`);
  const once = [];
  if (order % 2) once.push(firstOrderSection(kind, freq, rate));
  for (const q of BUTTERWORTH_Q[order]) once.push(butterworthSection(kind, freq, q, rate));
  return [...once, ...once.map(section => ({...section}))];
}

/** |H(f)| in dB for a cascade, so a test can check it against the UI's curve. */
export function cascadeResponseDb(sections, frequency, rate = SAMPLE_RATE) {
  const w = 2 * Math.PI * frequency / rate;
  const cos1 = Math.cos(w), sin1 = Math.sin(w);
  const cos2 = Math.cos(2 * w), sin2 = Math.sin(2 * w);
  let total = 0;
  for (const {b0, b1, b2, a1, a2} of sections) {
    const numerator = (b0 + b1 * cos1 + b2 * cos2) ** 2 + (b1 * sin1 + b2 * sin2) ** 2;
    const denominator = (1 + a1 * cos1 + a2 * cos2) ** 2 + (a1 * sin1 + a2 * sin2) ** 2;
    total += 10 * Math.log10(numerator / denominator);
  }
  return total;
}
