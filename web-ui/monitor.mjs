// The Control Room and the System tab's Level safety (docs/web/REDESIGN-2026-11.md,
// phase 3): GET /api/monitor reduced to what the page draws, the levels and
// their rounding, the state line, the LED ring, references, speaker groups,
// solo, which cards and panels exist, the patches POST /api/monitor takes,
// and the sender that carries knob moves. Pure apart from MonitorSender's
// injected clock and post, so it runs under node's test runner.
//
// Nothing here is part of a preset or of undo: the monitor's state is the
// device's (docs/web/MONITOR-FILES.md), and the draft never sees it.

export const LEVEL_MIN = -60;
export const TRIM_MIN = -12, TRIM_MAX = 12;
export const MAX_DB_RANGE = [-30, 0];
export const DIM_DEFAULT = -20;
export const REF_DEFAULT = -10;
export const DRAG_DB_PER_PX = 0.25;
export const KEY_STEP_DB = 0.5;
export const BUTTON_STEP_DB = 1;
export const TRIM_STEP_DB = 0.5;
export const MONITOR_POLL_MS = 500;
export const SEND_INTERVAL_MS = 30;
// How long an optimistic value waits for the owner to report it before the
// page shows what the owner reports instead (a refused or lost write).
export const OVERLAY_GRACE_MS = 3000;
export const LED_COUNT = 31;

export const FOLD_LABELS = {full: 'Full', '5.1': '5.1', stereo: 'Stereo', mono: 'Mono'};
export const START_RULES = [['last', 'Where it was'], ['reference', 'The reference'], ['fixed', 'A fixed level']];

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const flags16 = value => Array.isArray(value) && value.length === 16 ? value.map(Boolean) : Array(16).fill(false);
const finite = (value, fallback) => Number.isFinite(value) ? value : fallback;

/** To the 0.5 dB step the knobs move in. */
export const roundHalf = value => Math.round(value * 2) / 2 + 0;
/** A level as the knob may hold it: -60 to the limit, in 0.5 dB steps. */
export const clampLevel = (value, maxDb = 0) => Math.max(LEVEL_MIN, Math.min(maxDb, roundHalf(value)));
export const clampTrim = value => Math.max(TRIM_MIN, Math.min(TRIM_MAX, roundHalf(value)));
export const clampMax = value => Math.max(MAX_DB_RANGE[0], Math.min(MAX_DB_RANGE[1], roundHalf(value)));

/** A level in words: "−18.5 dB", "+1.0 dB", "0.0 dB" (a typographic minus). */
export function dbWords(value) {
  const r = Math.round(value * 10) / 10 + 0;
  return `${r > 0 ? '+' : r < 0 ? '−' : ''}${Math.abs(r).toFixed(1)} dB`;
}

/** A meter's peak as the card's peak line says it. */
export const peakText = peak => Number.isFinite(peak) && peak > LEVEL_MIN ? `Peak ${dbWords(peak)}` : 'No signal';

// ------------------------------------------------------------- the answer

function normaliseLimits(limits) {
  const l = isObject(limits) ? limits : {};
  const maxDb = finite(l.maxDb, 0);
  const refs = {};
  if (isObject(l.refs)) for (const [id, ref] of Object.entries(l.refs)) if (isObject(ref)) refs[id] = {levelDb: Math.min(finite(ref.levelDb, REF_DEFAULT), maxDb), note: String(ref.note ?? '')};
  return {maxDb, start: ['last', 'reference', 'fixed'].includes(l.start) ? l.start : 'last', startDb: Math.min(finite(l.startDb, -30), maxDb), lock: l.lock === true, refs};
}

/**
 * GET /api/monitor's answer as the page uses it, or null when it is not one.
 * {available, reason, limits} always; with available, also {sets, effective}:
 * sets in the running preset's order, each {id, kind, folds, outputs} with
 * outputs [{n, role, label}] by output number; effective is what the owner
 * has in force ({seq, state, reason, active, dimDb, subs, sets, solo, outMute}).
 */
export function reduceMonitor(body) {
  if (!isObject(body) || body.ok !== true) return null;
  const limits = normaliseLimits(body.limits);
  if (body.available !== true) return {available: false, reason: String(body.reason || ''), limits};
  const eff = isObject(body.effective) ? body.effective : {};
  const sets = (Array.isArray(body.topology?.sets) ? body.topology.sets : []).filter(s => isObject(s) && typeof s.id === 'string')
    .map(s => ({id: s.id, kind: s.kind === 'headphones' ? 'headphones' : 'speakers',
      folds: Array.isArray(s.folds) && s.folds.length ? s.folds.map(String) : ['full'],
      outputs: (Array.isArray(s.outputs) ? s.outputs : []).filter(o => Number.isInteger(o?.n) && o.n >= 0 && o.n < 16)
        .map(o => ({n: o.n, role: o.role === 'sub' ? 'sub' : 'speaker', label: String(o.label || `Out ${o.n + 1}`)})).sort((a, b) => a.n - b.n)}));
  const effSets = {};
  for (const s of sets) {
    const row = isObject(eff.sets?.[s.id]) ? eff.sets[s.id] : {};
    effSets[s.id] = {levelDb: finite(row.levelDb, -30), trimDb: finite(row.trimDb, 0), dim: row.dim === true, mute: row.mute === true,
      fold: typeof row.fold === 'string' ? row.fold : 'full'};
  }
  const ids = sets.map(s => s.id);
  return {available: true, reason: '', limits, sets,
    effective: {seq: Number.isInteger(eff.seq) ? eff.seq : null, state: String(eff.state || ''), reason: String(eff.reason || ''),
      active: eff.active === 'all' || ids.includes(eff.active) ? eff.active : 'all', dimDb: finite(eff.dimDb, DIM_DEFAULT), subs: eff.subs !== false,
      sets: effSets, solo: flags16(eff.solo), outMute: flags16(eff.outMute)}};
}

/** What the reference of a set is: its ref line, else -10 dB; both at most the limit. */
export function referenceOf(limits, id) {
  const ref = limits?.refs?.[id];
  const max = finite(limits?.maxDb, 0);
  return {levelDb: Math.min(ref ? ref.levelDb : REF_DEFAULT, max), note: ref ? ref.note : ''};
}

// ------------------------------------------------- optimistic values

/**
 * The page's own values, ahead of the owner's. A key is "set.<id>.<field>",
 * "active", "dimDb", "subs", "solo" or "outMute". An entry is {value, seq,
 * at}: seq null until the POST that carries it has answered, then the seq it
 * was written under; the entry goes when the owner reports that seq (or a
 * later one), or OVERLAY_GRACE_MS after the answer if it never does.
 */
export class Overlay {
  constructor() { this.entries = new Map(); }

  /** A local change, shown at once. */
  set(key, value) { this.entries.set(key, {value: structuredClone(value), seq: null, at: 0}); }

  get(key) { return this.entries.get(key); }

  /** The POST for `keys` answered with `seq`: each entry still holding the value sent waits for the owner now. */
  sent(body, seq, now) {
    for (const [key, value] of Object.entries(patchKeys(body))) {
      const entry = this.entries.get(key);
      if (entry && entry.seq === null && JSON.stringify(entry.value) === JSON.stringify(value)) Object.assign(entry, {seq, at: now});
    }
  }

  /** The POST for `body` failed: what it carried goes, and the owner's values show again. */
  failed(body) {
    for (const [key, value] of Object.entries(patchKeys(body))) {
      const entry = this.entries.get(key);
      if (entry && JSON.stringify(entry.value) === JSON.stringify(value)) this.entries.delete(key);
    }
  }

  /** A poll answered: drop what the owner has caught up with, or has had long enough to. */
  settle(effectiveSeq, now, graceMs = OVERLAY_GRACE_MS) {
    for (const [key, entry] of this.entries) {
      if (entry.seq === null) continue;
      if ((effectiveSeq ?? 0) >= entry.seq || now - entry.at > graceMs) this.entries.delete(key);
    }
  }

  clear() { this.entries.clear(); }
}

/** The overlay keys a POST body sets, with their values. */
export function patchKeys(body) {
  const out = {};
  const ids = body.sets || (body.set ? [body.set] : []);
  for (const id of ids) for (const field of ['levelDb', 'trimDb', 'dim', 'mute', 'fold']) if (field in body) out[`set.${id}.${field}`] = body[field];
  for (const key of ['active', 'dimDb', 'subs', 'solo', 'outMute']) if (key in body) out[key] = body[key];
  if (body.clearSolo) out.solo = Array(16).fill(false);
  return out;
}

/** What the page shows: the owner's values with the page's own on top. */
export function monitorValues(model, overlay = new Overlay()) {
  const eff = model.effective;
  const pick = (key, fallback) => { const entry = overlay.get(key); return entry ? structuredClone(entry.value) : fallback; };
  const sets = {};
  for (const s of model.sets) {
    const row = eff.sets[s.id];
    sets[s.id] = Object.fromEntries(['levelDb', 'trimDb', 'dim', 'mute', 'fold'].map(f => [f, pick(`set.${s.id}.${f}`, row[f])]));
  }
  return {active: pick('active', eff.active), dimDb: pick('dimDb', eff.dimDb), subs: pick('subs', eff.subs),
    solo: pick('solo', eff.solo), outMute: pick('outMute', eff.outMute), sets};
}

// ------------------------------------------------------------- the sender

/**
 * Carries the Control Room's changes to POST /api/monitor: one request in
 * flight at most; a change waiting for its turn is replaced by a newer one
 * with the same key (latest wins); and, unless it is `immediate` (a button,
 * a typed value, the end of a drag), a request starts no sooner than
 * `intervalMs` after the previous one started. Every change waiting is sent;
 * none is dropped but by a newer one. No debounce and no receipt: the
 * answer is the new state's seq.
 *
 * post(body) resolves with {seq, state} or throws. onSent(body, result) and
 * onError(body, error) are told how each went.
 */
export class MonitorSender {
  constructor({post, now = () => Date.now(), setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = id => clearTimeout(id),
    intervalMs = SEND_INTERVAL_MS, onSent = () => {}, onError = () => {}} = {}) {
    Object.assign(this, {post, now, setTimer, clearTimer, intervalMs, onSent, onError});
    this.queue = new Map();      // key -> {body, immediate}
    this.inFlight = null;        // {key, body}
    this.lastStart = -Infinity;
    this.timer = null;
    this.lastSent = new Map();   // key -> JSON of the body last sent
  }

  get busy() { return Boolean(this.inFlight) || this.queue.size > 0; }

  /** Whether a change with this key is waiting or on its way. */
  pending(key) { return this.queue.has(key) || this.inFlight?.key === key; }

  /** Queue a change; false when there was nothing new to send. */
  submit(key, body, {immediate = false} = {}) {
    const text = JSON.stringify(body);
    // The final value of a drag that already went: nothing new to say.
    if (immediate && !this.pending(key) && this.lastSent.get(key) === text) return false;
    const waiting = this.queue.get(key);
    // A replaced change moves to the back: the changes go in the order of their latest values.
    this.queue.delete(key);
    this.queue.set(key, {body: structuredClone(body), immediate: immediate || Boolean(waiting?.immediate)});
    this.pump();
    return true;
  }

  pump() {
    if (this.inFlight || !this.queue.size) return;
    const [key, entry] = this.queue.entries().next().value;
    const wait = entry.immediate ? 0 : this.lastStart + this.intervalMs - this.now();
    if (wait > 0) {
      if (this.timer === null) this.timer = this.setTimer(() => { this.timer = null; this.pump(); }, wait);
      return;
    }
    if (this.timer !== null) { this.clearTimer(this.timer); this.timer = null; }
    this.queue.delete(key);
    this.inFlight = {key, body: entry.body};
    this.lastStart = this.now();
    this.lastSent.set(key, JSON.stringify(entry.body));
    Promise.resolve().then(() => this.post(entry.body))
      .then(result => this.onSent(entry.body, result), error => { this.lastSent.delete(key); this.onError(entry.body, error); })
      .finally(() => { this.inFlight = null; this.pump(); });
  }

  cancel() {
    this.queue.clear();
    if (this.timer !== null) { this.clearTimer(this.timer); this.timer = null; }
  }
}

// -------------------------------------------------------------- patches

/** A change to one set's fields, or to several sets' (the Main volume). */
export function setPatch(ids, fields) {
  return ids.length === 1 ? {set: ids[0], ...fields} : {sets: [...ids], ...fields};
}

/** The sender's key for a patch: one per set (or sets) and field, so a drag coalesces with itself only. */
export function patchKey(body) {
  const target = body.sets ? body.sets.join(',') : body.set || '';
  // Clear solo and a solo are one field: the later of the two wins.
  return Object.keys(body).filter(k => k !== 'set' && k !== 'sets').map(k => k === 'clearSolo' ? 'solo' : k).sort().map(k => `${target}:${k}`).join('|');
}

/**
 * Solo pressed on some outputs of a set. Solo is exclusive within the set:
 * the set's other outputs lose theirs, and pressing what alone is soloed
 * again clears it. With Command or Control (`additive`) the outputs are
 * added to, or taken out of, the solo instead.
 */
export function soloPress(solo, setOutputs, outs, additive = false) {
  const next = flags16(solo);
  const all = outs.every(i => next[i]);
  if (additive) { outs.forEach(i => { next[i] = !all; }); return next; }
  const alone = all && setOutputs.every(i => next[i] === outs.includes(i));
  setOutputs.forEach(i => { next[i] = false; });
  if (!alone) outs.forEach(i => { next[i] = true; });
  return next;
}

/** Mute pressed on some outputs: all muted unmutes them, otherwise all are muted. */
export function mutePress(outMute, outs) {
  const next = flags16(outMute);
  const all = outs.every(i => next[i]);
  outs.forEach(i => { next[i] = !all; });
  return next;
}

// ----------------------------------------------------------- what is drawn

/**
 * Set labels: the running preset's own, when the page holds its saved
 * settings (`document`, the preset model) and every set of the topology is a
 * set of it with the same kind; otherwise by kind and order: Speakers,
 * Speakers 2, Headphones, Headphones 2.
 */
export function setLabels(sets, document = null) {
  const buses = Array.isArray(document?.buses) ? document.buses : [];
  const own = sets.length > 0 && sets.every(s => buses.some(b => b.id === s.id && b.kind === s.kind && typeof b.label === 'string' && b.label.trim()));
  const counts = {speakers: 0, headphones: 0};
  return Object.fromEntries(sets.map(s => {
    counts[s.kind] += 1;
    const generic = `${s.kind === 'headphones' ? 'Headphones' : 'Speakers'}${counts[s.kind] > 1 ? ` ${counts[s.kind]}` : ''}`;
    return [s.id, own ? buses.find(b => b.id === s.id).label.trim() : generic];
  }));
}

/** The 31 lights of the ring, each a list of classes: 2 dB apart from -60 to 0. */
export function ledRing(level, {maxDb = 0, ref = REF_DEFAULT, dim = false, mute = false} = {}) {
  return Array.from({length: LED_COUNT}, (_, k) => {
    const db = LEVEL_MIN + k * 2;
    const lit = !mute && level >= db && (level > LEVEL_MIN || k === 0);
    if (db > maxDb) return 'blocked';
    if (!lit) return Math.abs(db - ref) < 1 ? 'ref' : '';
    return db > -4 ? 'lit hot' : db > ref ? 'lit over' : dim ? 'lit dim' : 'lit';
  });
}

/** The knob's pointer, in degrees: -135 at -60 dB to +135 at 0 dB. */
export const knobAngle = level => Math.round((-135 + (level - LEVEL_MIN) / -LEVEL_MIN * 270) * 10) / 10;

/** What the card says under its title. tone: '' | 'muted' | 'dim' | 'idle'. */
export function stateLine({playing = true, mute = false, dim = false, level, dimDb = DIM_DEFAULT, ref = REF_DEFAULT, note = ''}) {
  if (!playing) return {text: 'Not playing', tone: 'idle'};
  if (mute) return {text: 'Muted', tone: 'muted'};
  if (dim) return {text: `Dimmed to ${dbWords(level + dimDb)}`, tone: 'dim'};
  const d = Math.round((level - ref) * 10) / 10 + 0;
  if (d === 0) return {text: `At reference${note ? ` · ${note}` : ''}`, tone: ''};
  return {text: `${d > 0 ? '+' : '−'}${Math.abs(d).toFixed(1)} dB from ref`, tone: ''};
}

// Where a speaker sits in the room seen from above, by its label's first word.
export const ROOM = {L: [24, 10], C: [50, 9], R: [76, 10], Lw: [9, 30], Rw: [91, 30], Ls: [9, 60.5], Rs: [91, 60.5], Lrs: [22, 92], Rrs: [78, 92], Cs: [50, 92],
  Ltf: [35, 45], Rtf: [65, 45], Ltm: [35, 60.5], Rtm: [65, 60.5], Ltr: [35, 76], Rtr: [65, 76]};
// The speaker groups the Control Room offers, by the label's first word.
export const GROUPS = [['Fronts', /^(L|R|C)$/], ['Centre', /^C$/], ['Wides', /^[LR]w$/], ['Surrounds', /^[LR]s$/], ['Rears', /^([LR]rs|Cs)$/],
  ['Heights', /^[LR]t[fmr]$/], ['Left', /^L/], ['Right', /^R/]];
const token = label => String(label).trim().split(/\s+/)[0];

/** A set's speakers placed in the room, its subwoofers across the front, and the speakers with no place. */
export function roomLayout(outputs) {
  const speakers = outputs.filter(o => o.role !== 'sub'), subs = outputs.filter(o => o.role === 'sub');
  const placed = [], unplaced = [];
  for (const o of speakers) { const p = ROOM[token(o.label)]; if (p) placed.push({...o, x: p[0], y: p[1]}); else unplaced.push(o); }
  subs.forEach((o, k) => placed.push({...o, x: Math.round((50 + (k - (subs.length - 1) / 2) * 17) * 10) / 10, y: 27}));
  return {placed, unplaced};
}

/** The group chips of a set: the standard groups its labels make, Subs, then the custom ones. */
export function groupChips(outputs, custom = []) {
  const speakers = outputs.filter(o => o.role !== 'sub'), subs = outputs.filter(o => o.role === 'sub');
  const chips = [], seen = new Set();
  for (const [name, pattern] of GROUPS) {
    const outs = speakers.filter(o => pattern.test(token(o.label))).map(o => o.n), key = outs.join(',');
    if (!outs.length || outs.length === speakers.length || seen.has(key)) continue;
    seen.add(key); chips.push({name, outs, custom: null});
  }
  if (subs.length) chips.push({name: 'Subs', outs: subs.map(o => o.n), custom: null});
  const inSet = new Set(outputs.map(o => o.n));
  for (const g of custom) { const outs = g.outs.filter(n => inSet.has(n)); if (outs.length) chips.push({name: g.name, outs, custom: g.id}); }
  return chips;
}

/** A bank's tag under each meter: L and R for headphones, S1.. for subs, the label's first word otherwise. */
export function bankTag(output, kind, index) {
  if (kind === 'headphones') return index === 0 ? 'L' : index === 1 ? 'R' : String(index + 1);
  if (output.role === 'sub') { const rest = String(output.label).trim().split(/\s+/)[1]; return `S${rest || ''}`; }
  return token(output.label);
}

export function keyList({several, first}) {
  const what = first === 'headphones' ? 'the headphones' : 'the speakers';
  return [['↑ ↓', `${first === 'main' ? 'Main volume' : 'Volume'} up or down 1 dB`], ['M', `Mute ${what}`], ['D', `Dim ${what}`], ['R', 'Go to the reference level'],
    ...(several ? [['1 – 9', 'Switch speaker set'], ['0', 'Play every speaker set']] : []), ['Esc', 'Clear solo'], ['?', 'Show or hide this list']];
}

/**
 * Everything the Control Room tab draws, from the reduced answer, the values
 * shown, the set labels, and the page's own view state. `meters` is a bank of
 * 16 {peak, hold, clip} (the to-network tap with its hold) or null.
 */
export function controlRoom({model, values, labels, meters = null, keysOpen = false, refOpen = {}, groups = {}, groupEdit = null, busy = false}) {
  const limits = model.limits, maxDb = limits.maxDb, sets = model.sets;
  const speakers = sets.filter(s => s.kind === 'speakers'), phones = sets.filter(s => s.kind === 'headphones');
  const several = speakers.length > 1;
  const active = values.active;
  const plays = id => active === 'all' || active === id;
  const anchor = several ? (speakers.find(s => s.id === active) || speakers[0]) : null;

  const card = (key, title, set, ids, isMain) => {
    const v = values.sets[set.id];
    const level = v.levelDb;
    const dim = ids.every(id => values.sets[id].dim), mute = ids.every(id => values.sets[id].mute);
    const ref = referenceOf(limits, set.id);
    const playing = set.kind === 'headphones' || isMain || plays(set.id);
    const st = stateLine({playing, mute, dim, level, dimDb: values.dimDb, ref: ref.levelDb, note: ref.note});
    const folds = set.folds.map(f => ({fold: f, label: FOLD_LABELS[f] || f, on: v.fold === f}));
    const hasSub = set.kind === 'speakers' && (isMain ? speakers : [set]).some(s => s.outputs.some(o => o.role === 'sub'));
    const outputs = set.outputs.map((o, i) => ({n: o.n, tag: bankTag(o, set.kind, i), sub: o.role === 'sub', label: o.label}));
    const peak = meters ? outputs.reduce((best, o) => Math.max(best, meters[o.n]?.peak ?? -Infinity), -Infinity) : null;
    return {key, title, kind: set.kind, isMain, refSet: set.id, ids, level, maxDb, dim, mute, dimDb: values.dimDb,
      ref: ref.levelDb, note: ref.note, locked: limits.lock, refOpen: Boolean(refOpen[key]), playing, state: st.text, tone: st.tone,
      leds: ledRing(level, {maxDb, ref: ref.levelDb, dim, mute}), angle: knobAngle(level),
      folds, showFolds: folds.length > 1, subs: hasSub ? {on: values.subs} : null, outputs, vertical: outputs.length > 2,
      peakText: peakText(peak), busy,
      trims: isMain ? speakers.map(s => ({id: s.id, label: labels[s.id], trim: values.sets[s.id].trimDb, plays: dbWords(level + values.sets[s.id].trimDb), playing: plays(s.id)})) : null,
      wide: isMain || (sets.length > 2 && outputs.length > 6)};
  };
  const cards = several
    ? [card('main', 'Main volume', anchor, speakers.map(s => s.id), true), ...phones.map(s => card(s.id, labels[s.id], s, [s.id], false))]
    : sets.map(s => card(s.id, labels[s.id], s, [s.id], false));

  const loudest = set => meters ? set.outputs.reduce((best, o) => Math.max(best, meters[o.n]?.peak ?? -Infinity), -Infinity) : -Infinity;
  const setSwitch = several ? [...speakers.map(s => ({id: s.id, label: labels[s.id], meter: true, loudest: loudest(s)})), {id: 'all', label: 'All sets', meter: false}].map(o => {
    const on = active === o.id, isAll = o.id === 'all';
    return {...o, on, lit: on || (active === 'all' && !isAll),
      sub: on ? (isAll ? 'Every set is playing' : 'Playing') : isAll ? 'Play every set' : active === 'all' ? 'Playing · click to solo' : 'Click to switch',
      aria: on ? `${o.label}, playing` : isAll ? 'Play every speaker set' : `Switch to ${o.label}`};
  }) : [];

  const solo = values.solo, outMute = values.outMute;
  const rooms = speakers.filter(s => plays(s.id)).map(s => {
    const custom = Array.isArray(groups[s.id]) ? groups[s.id] : [];
    const editing = groupEdit?.set === s.id;
    const setOuts = s.outputs.map(o => o.n);
    const chips = groupChips(s.outputs, custom).map(c => ({...c, soloOn: c.outs.every(i => solo[i]), muteOn: c.outs.every(i => outMute[i])}));
    const {placed, unplaced} = roomLayout(s.outputs);
    const tile = o => ({n: o.n, name: o.label, x: o.x, y: o.y, sub: o.role === 'sub', soloed: solo[o.n], muted: outMute[o.n], picked: editing && groupEdit.outs.includes(o.n)});
    return {id: s.id, title: labels[s.id], setOuts, chips, tiles: placed.map(tile), loose: unplaced.map(tile), unplaced: unplaced.map(o => o.label),
      editing, groupName: editing ? groupEdit.name : '', picked: editing ? groupEdit.outs.length : 0, idle: !groupEdit};
  });

  const first = cards[0];
  return {
    empty: sets.length === 0, cards, several, setSwitch, rooms, keysOpen,
    keys: keyList({several, first: !first ? 'speakers' : first.isMain ? 'main' : first.kind}),
    anySolo: solo.some(Boolean), anyClip: Boolean(meters?.some(m => m?.clip)),
    refused: model.effective.state === 'refused' ? (model.effective.reason || 'no reason given') : '',
  };
}

// ----------------------------------------------------------- level safety

/** The Level safety panel's words for the limits. */
export function safetyNotes(limits) {
  const l = normaliseLimits(limits);
  return {
    maxNote: l.maxDb >= 0 ? 'No limit: the knobs reach 0 dB.' : `The knobs stop at ${dbWords(l.maxDb)}. The ring shows the blocked part in dark red.`,
    startNote: l.start === 'last' ? 'After power-up, each knob starts where it was left. A restart of audio keeps the level it had.'
      : l.start === 'reference' ? 'After power-up, each knob starts at its reference level. A restart of audio keeps the level it had.'
        : `After power-up, every knob starts at ${dbWords(l.startDb)}. A restart of audio keeps the level it had.`,
    lockNote: l.lock ? 'Locked: the reference levels cannot be changed, and the Control Room leaves out Set and the Reference field.'
      : 'Not locked: Set and the Reference field in the Control Room store a reference level.',
  };
}

/** Whether the device offers the Control Room now (health's control.monitor). */
export const monitorOffered = health => health?.control?.monitor?.available === true;
/** Whether the device takes a limits kind now. */
export const monitorKind = (health, kind) => Array.isArray(health?.control?.monitor?.kinds) && health.control.monitor.kinds.includes(kind);

// --------------------------------------------------------- custom groups

// Kept in this browser only: a display convenience, not the device's state.
export const GROUPS_KEY = 'usb-aoip-monitor-groups-v1';

/** {setId: [{id, name, outs}]} from browser storage; empty when it is missing or unreadable. */
export function readGroups(storage = globalThis.localStorage) {
  try {
    const stored = JSON.parse(storage.getItem(GROUPS_KEY) || '{}');
    if (!isObject(stored)) return {};
    const out = {};
    for (const [set, list] of Object.entries(stored)) {
      if (!Array.isArray(list)) continue;
      out[set] = list.filter(g => isObject(g) && typeof g.id === 'string' && typeof g.name === 'string' && Array.isArray(g.outs))
        .map(g => ({id: g.id, name: g.name.slice(0, 40), outs: g.outs.filter(n => Number.isInteger(n) && n >= 0 && n < 16)}));
    }
    return out;
  } catch { return {}; }
}

/** Returns whether it was remembered. */
export function saveGroups(groups, storage = globalThis.localStorage) {
  try { storage.setItem(GROUPS_KEY, JSON.stringify(groups)); return true; }
  catch { return false; }
}

/** A new group added to a set's list; the name defaults to "Group N". */
export function addGroup(groups, set, name, outs) {
  const list = Array.isArray(groups[set]) ? groups[set] : [];
  const id = `g${Date.now().toString(36)}${list.length}`;
  return {...groups, [set]: [...list, {id, name: String(name || '').trim().slice(0, 40) || `Group ${list.length + 1}`, outs: [...outs].sort((a, b) => a - b)}]};
}

export function removeGroup(groups, set, id) {
  return {...groups, [set]: (groups[set] || []).filter(g => g.id !== id)};
}
