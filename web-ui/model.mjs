// Browser-only design model. No hardware commands or CamillaDSP configuration output.
export const CHANNELS = 16;
export const FREQUENCIES = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 14000, 18000];
export function createConfig() {
  const labels = ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', 'Input 13', 'Input 14', 'Input 15', 'Input 16'];
  const sources = [0, 1, 2, null, 4, 5, 6, 7, 8, 9, 10, 11, null, null, null, null];
  const config = {
    version: 3, name: 'Immersive · stereo subs', mode: 'dsp', source: 'usb', sampleRate: 48000,
    headroomDb: -18, bassEnabled: true, eqBypass: false,
    lfe: { input: 3, lowpassHz: 120, slope: 24, trimDb: 0 },
    inputs: labels.map(label => ({ label, crossover: true, highpassHz: 80, lowpassHz: 80, slope: 24 })),
    outputs: sources.map((source, i) => ({
      label: i === 3 ? 'LFE' : i === 12 ? 'Sub 2' : i < 12 ? labels[source] : `Spare ${i + 1}`,
      role: i === 3 || i === 12 ? 'sub' : i < 12 ? 'speaker' : 'unused', source: source ?? (i === 3 || i === 12 ? 3 : 0),
      gainDb: 0, delayMs: 0, mute: false, invert: false, eqEnabled: true,
      bands: FREQUENCIES.map(frequency => ({ enabled: true, type: 'bell', frequency, gainDb: 0, q: 1 }))
    })),
    sends: Array.from({ length: CHANNELS }, () => Array(CHANNELS).fill(null)),
    buses: [
      { id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds: Array.from({ length: 13 }, (_, i) => i), layoutId: '7.2.4' }
    ]
  };
  config.outputs.forEach((output, i) => { output.busId = i < 13 ? 'speakers' : null; });
  for (const i of [0, 4, 6, 8, 10]) config.sends[i][3] = 0;
  for (const i of [1, 5, 7, 9, 11]) config.sends[i][12] = 0;
  for (const i of [2, 3]) { config.sends[i][3] = -6; config.sends[i][12] = -6; }
  return config;
}

export function setOutputRole(config, index, role) {
  if (!['speaker', 'sub', 'unused'].includes(role)) throw new Error('Unknown output role');
  if (!Number.isInteger(index) || index < 0 || index >= CHANNELS) throw new Error('Choose an output from 1 to 16');
  const outputBus = config.buses?.find(bus => bus.outputIds.includes(index));
  if (outputBus?.kind === 'headphones' && role !== 'speaker') throw new Error('Headphones outputs must remain speaker roles');
  if (config.outputs[index].role !== role) {
    if (role === 'unused' && outputBus) {
      outputBus.outputIds = outputBus.outputIds.filter(i => i !== index);
      config.outputs[index].busId = null;
    } else if (role !== 'unused' && !outputBus) {
      const speakerBus = config.buses?.find(bus => bus.kind === 'speakers');
      if (!speakerBus) throw new Error('Allocate this output to a speaker bus first');
      speakerBus.outputIds.push(index); speakerBus.layoutId = 'custom'; config.outputs[index].busId = speakerBus.id;
    } else if (role !== 'unused' && outputBus.kind === 'speakers') outputBus.layoutId = 'custom';
    config.outputs[index].role = role;
    // A newly assigned sub starts silent; never resurrect hidden routes.
    config.sends.forEach(row => { row[index] = null; });
    settleSubShares(config);
  }
}

/**
 * Keep every added speaker set's subwoofer choice possible after an edit, in
 * place: a set with sub outputs of its own uses them; one that lost its last
 * one shares the main subwoofer, or has none when there is none to share, as
 * does a set sharing a main subwoofer that is gone. The first speakers set
 * carries no choice. Returns one sentence per set changed, for the caller.
 */
export function settleSubShares(config) {
  const said = [];
  const speakerSets = (config.buses || []).filter(bus => bus.kind === 'speakers');
  const hasSub = bus => bus.outputIds.some(i => config.outputs[i]?.role === 'sub');
  speakerSets.forEach((bus, n) => {
    if (n === 0) { delete bus.subShare; return; }
    const before = bus.subShare;
    if (hasSub(bus)) bus.subShare = 'own';
    else if (bus.subShare === 'own' || bus.subShare === undefined) bus.subShare = hasSub(speakerSets[0]) ? 'main' : 'none';
    else if (bus.subShare === 'main' && !hasSub(speakerSets[0])) bus.subShare = 'none';
    if (before !== undefined && before !== bus.subShare) {
      said.push(bus.subShare === 'own' ? `${bus.label} now uses its own subwoofer.`
        : bus.subShare === 'main' ? `${bus.label} now shares the main subwoofer.`
        : `${bus.label} has no subwoofer now: its speakers play full range.`);
    }
  });
  return said;
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
  if (!c || c.version !== 3 || c.sampleRate !== 48000) fail('Expected a version 3, 48 kHz UI preset');
  label(c.name);
  if (!['dsp', 'direct'].includes(c.mode) || !['usb', 'aoip'].includes(c.source)) fail('Invalid mode or source');
  num(c.headroomDb, -36, 0, 'Headroom trim'); bool(c.bassEnabled, 'Bass management');
  if (c.eqBypass !== undefined) bool(c.eqBypass, 'Global EQ bypass');
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
    if (v.busId !== null && typeof v.busId !== 'string') fail('Output bus ID must be a string or null');
  });
  if (!Array.isArray(c.buses) || !c.buses.length) fail('At least one output bus is required');
  const busIds = new Set(), memberships = new Map();
  c.buses.forEach((bus, n) => {
    if (!bus || typeof bus.id !== 'string' || !/^[a-z][a-z0-9-]{0,31}$/.test(bus.id) || busIds.has(bus.id)) fail(`Invalid or duplicate bus ID at ${n}`);
    busIds.add(bus.id); label(bus.label);
    if (!['speakers', 'headphones'].includes(bus.kind)) fail(`Bus ${bus.id}: invalid kind`);
    if (!Array.isArray(bus.outputIds) || bus.outputIds.some(i => !Number.isInteger(i) || i < 0 || i >= 16)) fail(`Bus ${bus.id}: invalid output membership`);
    for (const i of bus.outputIds) { if (memberships.has(i)) fail(`Output ${i + 1} belongs to multiple buses`); memberships.set(i, bus.id); }
    // Level and mute belong to the Control Room since v3; a saved one would be a second, hidden level.
    if ('gainDb' in bus || 'mute' in bus) fail(`${bus.label}: a speaker set or headphones carries no level or mute of its own`);
    if (bus.layoutId !== undefined) label(bus.layoutId);
    if (bus.kind === 'headphones') {
      if (bus.outputIds.length !== 2) fail('Headphones bus must have exactly two outputs');
      bus.outputIds.forEach(i => { if (c.outputs[i].role !== 'speaker') fail('Headphones outputs must be speaker roles'); if (c.sends.some(row => row[i] !== null)) fail('Headphones outputs cannot receive bass sends'); });
      if (!['pair', 'downmix'].includes(bus.inputMode)) fail('Headphones input mode must be pair or downmix');
      if (!Array.isArray(bus.inputPair) || bus.inputPair.length !== 2 || bus.inputPair.some(i => !Number.isInteger(i) || i < 0 || i >= 16)) fail('Headphones input pair must contain two inputs');
      if (!Array.isArray(bus.downmixMatrix) || bus.downmixMatrix.length !== 16 || bus.downmixMatrix.some(row => !Array.isArray(row) || row.length !== 2)) fail('Headphones downmix matrix must be 16 by 2');
      bus.downmixMatrix.flat().forEach((v, i) => { if (v !== null) num(v, -60, 12, `Headphones matrix ${i}`); });
      bool(bus.sourcePreCrossover, 'Headphones pre-crossover source');
      if (bus.linkEq !== undefined) bool(bus.linkEq, 'Headphones EQ link');
      if (!bus.sourcePreCrossover) fail('Headphones source must be pre-crossover');
    }
  });
  const speakerSets = c.buses.filter(bus => bus.kind === 'speakers');
  const subsOf = bus => bus.outputIds.filter(i => c.outputs[i].role === 'sub');
  c.buses.forEach(bus => {
    if (bus.kind !== 'speakers' || bus === speakerSets[0]) {
      if (bus.subShare !== undefined) fail(`${bus.label}: only an added speaker set chooses its subwoofer`);
      return;
    }
    if (!SUB_SHARES.includes(bus.subShare)) fail(`${bus.label}: choose whether it shares the main subwoofer, has none, or its own`);
    const own = subsOf(bus).length;
    if (bus.subShare === 'own' && !own) fail(`${bus.label}: its own subwoofer needs a subwoofer output in the set`);
    if (bus.subShare !== 'own' && own) fail(`${bus.label}: a set with subwoofer outputs of its own uses its own subwoofer`);
    if (bus.subShare === 'main' && !subsOf(speakerSets[0]).length) fail(`${bus.label}: ${speakerSets[0].label} has no subwoofer to share`);
  });
  c.outputs.forEach((output, i) => { if (output.busId !== null && !busIds.has(output.busId)) fail(`Output ${i + 1} references an unknown bus`); if (output.busId !== (memberships.get(i) ?? null)) fail(`Output ${i + 1} bus membership mismatch`); if (output.role !== 'unused' && output.busId === null) fail(`Active output ${i + 1} must belong to a bus`); });
  if (!Array.isArray(c.sends) || c.sends.length !== 16) fail('Expected 16 send rows');
  c.sends.forEach(row => {
    if (!Array.isArray(row) || row.length !== 16) fail('Expected 16 send destinations');
    row.forEach((v, i) => {
      if (v !== null) { num(v, -60, 12, 'Sub send gain'); if (c.outputs[i].role !== 'sub') fail('Bass sends must target a sub output'); }
    });
  });
  return c;
}

/**
 * A speakers set other than the first chooses where its bass goes (v3):
 *   main  no subwoofer outputs of its own; its bass plays through the first
 *         speakers set's subwoofers, with the sends its inputs have to them
 *   none  no bass management: its speakers run full range
 *   own   subwoofer outputs of its own, fed by the sends to them
 */
export const SUB_SHARES = ['main', 'none', 'own'];

/** The preset as stored, at any model version, read into the current one.
 *  Returns {config, notes}: `notes` says what the migration could not carry
 *  over exactly, for the caller to show. The stored copy is not rewritten. */
export function readPreset(text) {
  if (text.length > 200000) throw new Error('Preset is too large');
  let parsed = JSON.parse(text);
  const notes = [];
  if (parsed?.version === 1) parsed = migrateV1Preset(parsed);
  if (parsed?.version === 2) {
    const migrated = migrateV2Preset(parsed);
    parsed = migrated.config; notes.push(...migrated.notes);
  }
  return {config: validateConfig(parsed), notes};
}

export function parsePreset(text) {
  return readPreset(text).config;
}

/**
 * v2 to v3. A bus's saved level moves onto each of its outputs (clamped to
 * the outputs' range, with a note when that changed anything) and a muted bus
 * switches each of its outputs off; the Control Room owns level and mute now.
 * An added speakers set gets a subwoofer choice: its own when it has sub
 * outputs, else the main subwoofer when the first set has one, else none.
 */
export function migrateV2Preset(legacy) {
  if (!legacy || legacy.version !== 2) throw new Error('Expected a version 2 UI preset');
  const result = structuredClone(legacy); result.version = 3;
  const notes = [];
  if (!Array.isArray(result.buses) || !Array.isArray(result.outputs)) return {config: result, notes};
  for (const bus of result.buses) {
    if (!bus || !Array.isArray(bus.outputIds)) continue;
    const gain = bus.gainDb, label = typeof bus.label === 'string' ? bus.label : bus.id;
    if (typeof gain === 'number' && Number.isFinite(gain) && gain !== 0) {
      const clamped = [];
      for (const i of bus.outputIds) {
        const output = result.outputs[i];
        if (!output || typeof output.gainDb !== 'number') continue;
        const wanted = output.gainDb + gain, kept = Math.min(12, Math.max(-60, wanted));
        if (kept !== wanted) clamped.push(`${output.label ?? `Output ${i + 1}`} (${kept} dB, not ${Number(wanted.toFixed(2))} dB)`);
        output.gainDb = Number(kept.toFixed(6));
      }
      if (clamped.length) notes.push(`${label}'s saved level of ${gain} dB moved onto its outputs, which stop at -60 and +12 dB: ${clamped.join(', ')}.`);
    }
    if (bus.mute === true) for (const i of bus.outputIds) if (result.outputs[i]) result.outputs[i].mute = true;
    delete bus.gainDb; delete bus.mute;
  }
  const speakerSets = result.buses.filter(bus => bus?.kind === 'speakers');
  const hasSub = bus => (bus.outputIds || []).some(i => result.outputs[i]?.role === 'sub');
  speakerSets.forEach((bus, n) => {
    if (n === 0) { delete bus.subShare; return; }
    bus.subShare = hasSub(bus) ? 'own' : hasSub(speakerSets[0]) ? 'main' : 'none';
  });
  return {config: result, notes};
}

/** Upgrade legacy presets while retaining every existing output/input edit and ordering. */
export function migrateV1Preset(legacy) {
  if (!legacy || legacy.version !== 1) throw new Error('Expected a version 1 UI preset');
  const result = structuredClone(legacy); result.version = 2;
  if (result.eqBypass === undefined) result.eqBypass = false;
  const active = result.outputs.map((output, i) => output.role === 'unused' ? null : i).filter(i => i !== null);
  result.buses = [
    { id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds: active, layoutId: 'custom', gainDb: 0, mute: false }
  ];
  result.outputs.forEach((output, i) => { output.busId = active.includes(i) ? 'speakers' : null; });
  return result;
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

export function eqResponse(output, frequency, bypassAll = false) {
  return output.eqEnabled && !bypassAll ? output.bands.reduce((sum, b) => sum + bandResponse(b, frequency), 0) : 0;
}

/**
 * Where each speakers set's bass goes, in bus order: {busId, set (the bus
 * index), share ('first' for the first speakers set, else its subShare), subs
 * (the sub outputs its bass branches feed), inputs (the inputs that may have a
 * bass branch in it, null for any)}. The first set and a set with its own subs
 * take every input with a send to their subs, as one set always has; a set
 * sharing the main subs redirects what its own speakers play and the LFE, with
 * the sends those inputs have to the main subs; a set with none has no bass.
 * The compiler's channel plan and the page's worst-case figure read this.
 */
export function speakerSetBass(config) {
  const subsOf = bus => bus.outputIds.filter(i => config.outputs[i]?.role === 'sub').sort((a, b) => a - b);
  const sets = [];
  config.buses.forEach((bus, set) => {
    if (bus.kind !== 'speakers') return;
    const share = sets.length ? bus.subShare : 'first';
    const first = sets[0];
    let subs = [], inputs = null;
    if (share === 'first' || share === 'own') subs = subsOf(bus);
    else if (share === 'main') {
      subs = first.subs;
      const played = new Set(bus.outputIds.filter(i => config.outputs[i].role === 'speaker').map(i => config.outputs[i].source));
      played.add(config.lfe.input);
      inputs = [...played].sort((a, b) => a - b);
    } else inputs = [];
    sets.push({busId: bus.id, set, share, subs, inputs});
  });
  return sets;
}

export function subSumBoundDb(config, destination) {
  // Conservative coherent full-scale sum before crossover/EQ; not a true-peak
  // prediction. A sub that several speaker sets share sums each set's bass:
  // under All sets they all play.
  let sum = 0;
  for (const feed of speakerSetBass(config)) {
    if (!feed.subs.includes(destination)) continue;
    config.sends.forEach((row, i) => {
      if (feed.inputs && !feed.inputs.includes(i)) return;
      if (row[destination] !== null && (i === config.lfe.input || config.bassEnabled))
        sum += 10 ** ((row[destination] + (i === config.lfe.input ? config.lfe.trimDb : 0)) / 20);
    });
  }
  return sum ? 20 * Math.log10(sum) + config.headroomDb + config.outputs[destination].gainDb : -Infinity;
}
