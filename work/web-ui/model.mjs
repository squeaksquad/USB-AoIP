// Browser-only design model. No hardware commands or CamillaDSP configuration output.
export const CHANNELS = 16;
export const FREQUENCIES = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 14000, 18000];
export function createConfig() {
  const labels = ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', 'Input 13', 'Input 14', 'Input 15', 'Input 16'];
  const sources = [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, null, null, null, null, null];
  const config = {
    version: 1, name: 'Immersive · stereo subs', mode: 'dsp', source: 'usb', sampleRate: 48000,
    headroomDb: -18, bassEnabled: true,
    lfe: { input: 3, lowpassHz: 120, slope: 24, trimDb: 0 },
    inputs: labels.map(label => ({ label, crossover: true, highpassHz: 80, lowpassHz: 80, slope: 24 })),
    outputs: sources.map((source, i) => ({
      label: i < 11 ? labels[source] : i === 11 ? 'Sub L' : i === 12 ? 'Sub R' : `Spare ${i + 1}`,
      role: i < 11 ? 'speaker' : i < 13 ? 'sub' : 'unused', source: source ?? 0,
      gainDb: 0, delayMs: 0, mute: false, invert: false, eqEnabled: true,
      bands: FREQUENCIES.map(frequency => ({ enabled: true, type: 'bell', frequency, gainDb: 0, q: 1 }))
    })),
    sends: Array.from({ length: CHANNELS }, () => Array(CHANNELS).fill(null))
  };
  for (const i of [0, 4, 6, 8, 10]) config.sends[i][11] = 0;
  for (const i of [1, 5, 7, 9, 11]) config.sends[i][12] = 0;
  for (const i of [2, 3]) { config.sends[i][11] = -6; config.sends[i][12] = -6; }
  return config;
}

export function setOutputRole(config, index, role) {
  if (!['speaker', 'sub', 'unused'].includes(role)) throw new Error('Unknown output role');
  if (config.outputs[index].role !== role) {
    config.outputs[index].role = role;
    // A newly assigned sub starts silent; never resurrect hidden routes.
    config.sends.forEach(row => { row[index] = null; });
  }
}

export function validateConfig(c) {
  const fail = message => { throw new Error(message); };
  const num = (v, min, max, label) => {
    if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max) fail(`${label}: expected ${min}–${max}`);
  };
  const index = (v, label) => { num(v, 0, 15, label); if (!Number.isInteger(v)) fail(`${label}: expected whole channel`); };
  const bool = (v, label) => { if (typeof v !== 'boolean') fail(`${label}: expected on/off`); };
  const label = v => { if (typeof v !== 'string' || !v.trim() || v.length > 64) fail('Labels must contain 1–64 characters'); };
  const slope = v => { if (![12, 24, 48].includes(v)) fail('Crossover slope must be 12, 24 or 48 dB/oct'); };
  if (!c || c.version !== 1 || c.sampleRate !== 48000) fail('Expected a version 1, 48 kHz UI preset');
  label(c.name);
  if (!['dsp', 'direct'].includes(c.mode) || !['usb', 'aoip'].includes(c.source)) fail('Invalid mode or source');
  num(c.headroomDb, -36, 0, 'Headroom trim'); bool(c.bassEnabled, 'Bass management');
  if (!Array.isArray(c.inputs) || c.inputs.length !== 16 || !Array.isArray(c.outputs) || c.outputs.length !== 16) fail('Exactly 16 inputs and 16 outputs required');
  if (!c.lfe) fail('Missing LFE settings');
  index(c.lfe.input, 'LFE input'); num(c.lfe.lowpassHz, 20, 250, 'LFE low-pass'); slope(c.lfe.slope); num(c.lfe.trimDb, -24, 12, 'LFE trim');
  c.inputs.forEach(v => {
    label(v.label); bool(v.crossover, 'Crossover'); num(v.highpassHz, 20, 250, 'High-pass'); num(v.lowpassHz, 20, 250, 'Low-pass'); slope(v.slope);
  });
  c.outputs.forEach(v => {
    label(v.label);
    if (!['speaker', 'sub', 'unused'].includes(v.role)) fail('Invalid output role');
    index(v.source, 'Speaker source'); num(v.gainDb, -60, 12, 'Output gain'); num(v.delayMs, 0, 10, 'Alignment delay');
    bool(v.mute, 'Mute'); bool(v.invert, 'Polarity'); bool(v.eqEnabled, 'EQ');
    if (!Array.isArray(v.bands) || v.bands.length !== 16) fail('Exactly 16 EQ bands required');
    v.bands.forEach(b => {
      bool(b.enabled, 'Band enable'); if (!['bell', 'lowShelf', 'highShelf'].includes(b.type)) fail('Unknown EQ type');
      num(b.frequency, 20, 20000, 'EQ frequency'); num(b.gainDb, -18, 18, 'EQ gain'); num(b.q, 0.1, 18, 'EQ Q');
    });
  });
  if (!Array.isArray(c.sends) || c.sends.length !== 16) fail('Expected 16 send rows');
  c.sends.forEach(row => {
    if (!Array.isArray(row) || row.length !== 16) fail('Expected 16 send destinations');
    row.forEach((v, i) => {
      if (v !== null) { num(v, -60, 12, 'Sub send gain'); if (c.outputs[i].role !== 'sub') fail('Bass sends must target a sub output'); }
    });
  });
  return c;
}

export function parsePreset(text) {
  if (text.length > 200000) throw new Error('Preset is too large');
  return validateConfig(JSON.parse(text));
}

// W3C Audio EQ Cookbook: peaking and shelving biquads with Q parameterization.
export function bandResponse(b, frequency) {
  if (!b.enabled) return 0;
  const A = 10 ** (b.gainDb / 40), w = 2 * Math.PI * b.frequency / 48000;
  const c = Math.cos(w), alpha = Math.sin(w) / (2 * b.q), t = 2 * Math.sqrt(A) * alpha;
  let B, D;
  if (b.type === 'lowShelf') {
    B = [A*((A+1)-(A-1)*c+t), 2*A*((A-1)-(A+1)*c), A*((A+1)-(A-1)*c-t)];
    D = [(A+1)+(A-1)*c+t, -2*((A-1)+(A+1)*c), (A+1)+(A-1)*c-t];
  } else if (b.type === 'highShelf') {
    B = [A*((A+1)+(A-1)*c+t), -2*A*((A-1)+(A+1)*c), A*((A+1)+(A-1)*c-t)];
    D = [(A+1)-(A-1)*c+t, 2*((A-1)-(A+1)*c), (A+1)-(A-1)*c-t];
  } else {
    B = [1+alpha*A, -2*c, 1-alpha*A]; D = [1+alpha/A, -2*c, 1-alpha/A];
  }
  const x = 2 * Math.PI * frequency / 48000;
  const power = a => (a[0]+a[1]*Math.cos(x)+a[2]*Math.cos(2*x))**2 + (a[1]*Math.sin(x)+a[2]*Math.sin(2*x))**2;
  return 10 * Math.log10(power(B) / power(D));
}

export function eqResponse(output, frequency) {
  return output.eqEnabled ? output.bands.reduce((sum, b) => sum + bandResponse(b, frequency), 0) : 0;
}

export function subSumBoundDb(config, destination) {
  // Conservative coherent full-scale sum before crossover/EQ; not a true-peak prediction.
  let sum = 0;
  config.sends.forEach((row, i) => {
    if (row[destination] !== null && (i === config.lfe.input || config.bassEnabled))
      sum += 10 ** ((row[destination] + (i === config.lfe.input ? config.lfe.trimDb : 0)) / 20);
  });
  return sum ? 20 * Math.log10(sum) + config.headroomDb + config.outputs[destination].gainDb : -Infinity;
}
