import test from 'node:test';
import assert from 'node:assert/strict';
import { reduceMonitor, Overlay, monitorValues, MonitorSender, setPatch, patchKey, patchKeys, soloPress, mutePress, setLabels, ledRing, knobAngle,
  stateLine, roomLayout, groupChips, bankTag, controlRoom, safetyNotes, clampLevel, clampTrim, roundHalf, dbWords, peakText, referenceOf,
  readGroups, saveGroups, addGroup, removeGroup, monitorOffered, monitorKind, keyList } from './monitor.mjs';

const ZEROS = Array(16).fill(false);
const out = (n, label, role = 'speaker') => ({n, role, label});

/** A GET /api/monitor answer: 7.1.4 speakers on 0-11 with a sub on 3, and headphones on 14-15. */
function body714(extra = {}) {
  const labels = ['L', 'R', 'C', 'Sub', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr'];
  return {ok: true, available: true, seq: 4,
    state: {}, limits: {maxDb: 0, start: 'last', startDb: -30, lock: false, refs: {}, file: 'absent'},
    topology: {sets: [{id: 'speakers', kind: 'speakers', folds: ['full', '5.1', 'stereo', 'mono'], outputs: labels.map((l, n) => out(n, l, n === 3 ? 'sub' : 'speaker'))},
      {id: 'headphones', kind: 'headphones', folds: ['full'], outputs: [out(15, 'Phones R'), out(14, 'Phones L')]}]},
    effective: {seq: 4, state: 'applied', reason: '', active: 'speakers', dimDb: -20, subs: true,
      sets: {speakers: {kind: 'speakers', levelDb: -18.5, trimDb: 0, dim: false, mute: false, fold: 'full', gainDb: -18.5},
        headphones: {kind: 'headphones', levelDb: -30, trimDb: 0, dim: false, mute: false, fold: 'full', gainDb: -30}},
      solo: ZEROS, outMute: ZEROS},
    ...extra};
}

/** Two speaker sets sharing the sub on output 3, and no headphones. */
function bodyTwoSets() {
  return {ok: true, available: true, seq: 1, limits: {maxDb: -6, start: 'reference', startDb: -30, lock: true, refs: {mains: {levelDb: -18, note: '79 dB SPL C'}}},
    topology: {sets: [{id: 'mains', kind: 'speakers', folds: ['full', 'stereo', 'mono'], outputs: [out(0, 'L'), out(1, 'R'), out(2, 'C'), out(3, 'Sub', 'sub')]},
      {id: 'nearfield', kind: 'speakers', folds: ['full', 'mono'], outputs: [out(4, 'L 2'), out(5, 'R 2'), out(3, 'Sub', 'sub')]}]},
    effective: {seq: 1, state: 'applied', reason: '', active: 'mains', dimDb: -20, subs: true,
      sets: {mains: {levelDb: -18, trimDb: 0, dim: false, mute: false, fold: 'full'}, nearfield: {levelDb: -18, trimDb: -1.5, dim: false, mute: false, fold: 'full'}},
      solo: ZEROS, outMute: ZEROS}};
}

test('levels: 0.5 dB steps, -60 to the limit; trims -12 to +12; words with a typographic minus', () => {
  assert.equal(clampLevel(-18.3), -18.5);
  assert.equal(clampLevel(-18.2), -18);
  assert.equal(clampLevel(3), 0);
  assert.equal(clampLevel(-3, -6), -6);
  assert.equal(clampLevel(-80), -60);
  assert.equal(clampTrim(13), 12);
  assert.equal(clampTrim(-12.3), -12);
  assert.ok(Object.is(roundHalf(-0.1), 0), 'never -0');
  assert.equal(dbWords(-18.5), '−18.5 dB');
  assert.equal(dbWords(1), '+1.0 dB');
  assert.equal(dbWords(-0.01), '0.0 dB');
  assert.equal(peakText(-12.34), 'Peak −12.3 dB');
  assert.equal(peakText(-60), 'No signal');
  assert.equal(peakText(null), 'No signal');
});

test('reduceMonitor: unavailable keeps the limits; available sorts outputs and fills defaults', () => {
  assert.equal(reduceMonitor(null), null);
  assert.equal(reduceMonitor({ok: false}), null);
  const off = reduceMonitor({ok: true, available: false, reason: 'The Dante service is inactive.', limits: {maxDb: -6, lock: true}});
  assert.deepEqual([off.available, off.reason, off.limits.maxDb, off.limits.lock, off.limits.start], [false, 'The Dante service is inactive.', -6, true, 'last']);
  const m = reduceMonitor(body714());
  assert.equal(m.available, true);
  assert.deepEqual(m.sets.map(s => s.id), ['speakers', 'headphones']);
  assert.deepEqual(m.sets[1].outputs.map(o => o.n), [14, 15], 'by output number');
  assert.equal(m.effective.seq, 4);
  assert.equal(m.effective.sets.speakers.levelDb, -18.5);
  const start = reduceMonitor(body714({effective: {...body714().effective, seq: null, state: 'start', active: 'gone'}}));
  assert.equal(start.effective.seq, null);
  assert.equal(start.effective.active, 'all', 'an active set the topology lacks reads as all');
});

test('references: the ref line, else -10 dB, both at most the limit', () => {
  assert.deepEqual(referenceOf({maxDb: 0, refs: {}}, 'x'), {levelDb: -10, note: ''});
  assert.deepEqual(referenceOf({maxDb: -12, refs: {}}, 'x'), {levelDb: -12, note: ''});
  assert.deepEqual(reduceMonitor(bodyTwoSets()).limits.refs.mains, {levelDb: -18, note: '79 dB SPL C'});
});

test('Overlay: a local value shows until the owner reports its seq, or the grace runs out', () => {
  const m = reduceMonitor(body714()), overlay = new Overlay();
  overlay.set('set.speakers.levelDb', -10);
  assert.equal(monitorValues(m, overlay).sets.speakers.levelDb, -10);
  overlay.settle(99, 0);
  assert.equal(monitorValues(m, overlay).sets.speakers.levelDb, -10, 'not yet answered: a poll of any age does not snap it back');
  overlay.sent({set: 'speakers', levelDb: -10}, 7, 1000);
  overlay.settle(6, 1500);
  assert.equal(monitorValues(m, overlay).sets.speakers.levelDb, -10, 'the owner is still on seq 6');
  overlay.settle(7, 1600);
  assert.equal(monitorValues(m, overlay).sets.speakers.levelDb, -18.5, 'seq 7 in force: the owner\'s value');
  overlay.set('dimDb', -30);
  overlay.sent({dimDb: -30}, 8, 2000);
  overlay.settle(7, 5001);
  assert.equal(monitorValues(m, overlay).dimDb, -20, 'refused or lost: after the grace the owner\'s value shows');
  overlay.set('subs', false);
  overlay.sent({subs: true}, 9, 6000);
  assert.equal(overlay.get('subs').seq, null, 'an answer for an older value does not release a newer one');
  overlay.failed({subs: false});
  assert.equal(overlay.get('subs'), undefined);
});

test('patchKeys covers set, sets and clearSolo', () => {
  assert.deepEqual(patchKeys({sets: ['a', 'b'], levelDb: -3}), {'set.a.levelDb': -3, 'set.b.levelDb': -3});
  assert.deepEqual(patchKeys({clearSolo: true}), {solo: ZEROS});
  assert.deepEqual(setPatch(['a'], {mute: true}), {set: 'a', mute: true});
  assert.deepEqual(setPatch(['a', 'b'], {mute: true}), {sets: ['a', 'b'], mute: true});
  assert.equal(patchKey({set: 'a', levelDb: -1}), 'a:levelDb');
  assert.notEqual(patchKey({set: 'a', levelDb: -1}), patchKey({set: 'b', levelDb: -1}));
  assert.notEqual(patchKey({set: 'a', levelDb: -1}), patchKey({set: 'a', trimDb: -1}));
  assert.equal(patchKey({clearSolo: true}), patchKey({solo: ZEROS}), 'clear solo replaces a waiting solo');
});

/** A sender on a fake clock: timers run only when the test says. */
function rig() {
  let now = 0;
  const timers = [], posts = [], sent = [], errors = [];
  const answers = [];
  const sender = new MonitorSender({
    now: () => now,
    setTimer: (fn, ms) => { const t = {fn, at: now + ms, done: false}; timers.push(t); return t; },
    clearTimer: t => { t.done = true; },
    post: body => new Promise((resolve, reject) => { posts.push(body); answers.push({resolve, reject}); }),
    onSent: (body, result) => sent.push([body, result.seq]),
    onError: (body, error) => errors.push([body, error.message]),
  });
  const flush = () => new Promise(r => setImmediate(r));
  return {sender, posts, sent, errors, answers, flush,
    advance: async ms => { now += ms; for (const t of timers) if (!t.done && t.at <= now) { t.done = true; t.fn(); } await flush(); }};
}

test('MonitorSender: one in flight, at most every 30 ms while dragging, latest wins, final value sent', async () => {
  const r = rig();
  r.sender.submit('a:levelDb', {set: 'a', levelDb: -20});
  await r.flush();
  assert.equal(r.posts.length, 1);
  for (const v of [-19.5, -19, -18.5]) r.sender.submit('a:levelDb', {set: 'a', levelDb: v});
  await r.flush();
  assert.equal(r.posts.length, 1, 'one in flight at most');
  r.answers[0].resolve({seq: 1});
  await r.flush();
  assert.equal(r.posts.length, 1, 'the next waits out the 30 ms since the first started');
  await r.advance(30);
  assert.deepEqual(r.posts[1], {set: 'a', levelDb: -18.5}, 'latest value wins');
  r.sender.submit('a:levelDb', {set: 'a', levelDb: -18});
  r.answers[1].resolve({seq: 2});
  await r.flush();
  // The release: immediate, no wait.
  r.sender.submit('a:levelDb', {set: 'a', levelDb: -17.5}, {immediate: true});
  await r.flush();
  assert.deepEqual(r.posts[2], {set: 'a', levelDb: -17.5});
  r.answers[2].resolve({seq: 3});
  await r.flush();
  r.sender.submit('a:levelDb', {set: 'a', levelDb: -17.5}, {immediate: true});
  await r.flush();
  assert.equal(r.posts.length, 3, 'a release with nothing new sends nothing');
  assert.deepEqual(r.sent.map(s => s[1]), [1, 2, 3]);
  assert.equal(r.sender.busy, false);
});

test('MonitorSender: different keys keep their order and are all sent; a failure is reported', async () => {
  const r = rig();
  r.sender.submit('a:dim', {set: 'a', dim: true}, {immediate: true});
  r.sender.submit('a:mute', {set: 'a', mute: true}, {immediate: true});
  r.sender.submit('active', {active: 'all'}, {immediate: true});
  await r.flush();
  assert.equal(r.posts.length, 1);
  r.answers[0].reject(new Error('409 no such set'));
  await r.flush();
  assert.deepEqual(r.errors, [[{set: 'a', dim: true}, '409 no such set']]);
  assert.deepEqual(r.posts[1], {set: 'a', mute: true});
  r.answers[1].resolve({seq: 5});
  await r.flush();
  assert.deepEqual(r.posts[2], {active: 'all'});
  r.answers[2].resolve({seq: 6});
  await r.flush();
  assert.equal(r.posts.length, 3);
  // A replaced change goes behind the others: solo, clear solo, solo again ends on the last solo.
  r.sender.submit(':solo', {solo: [true, ...ZEROS.slice(1)]}, {immediate: true});
  r.sender.submit(':x', {subs: false}, {immediate: true});
  await r.flush();
  r.sender.submit(':y', {dimDb: -30}, {immediate: true});
  r.sender.submit(':z', {subs: true}, {immediate: true});
  r.sender.submit(':y', {dimDb: -31}, {immediate: true});
  for (const [i, expected] of [[3, {subs: false}], [4, {subs: true}], [5, {dimDb: -31}]]) {
    r.answers[i].resolve({seq: 7 + i});
    await r.flush();
    assert.deepEqual(r.posts[i + 1], expected);
  }
  r.answers[6].resolve({seq: 13});
  await r.flush();
  // After a failure the same value can be sent again.
  assert.equal(r.sender.submit('a:dim', {set: 'a', dim: true}, {immediate: true}), true);
  await r.flush();
  assert.equal(r.posts.length, 8);
});

test('solo: exclusive within the set, again clears, Command or Control adds; mute toggles a group', () => {
  const setOuts = [0, 1, 2, 3];
  let solo = soloPress(ZEROS, setOuts, [0]);
  assert.deepEqual(solo.slice(0, 4), [true, false, false, false]);
  solo = soloPress(solo, setOuts, [1]);
  assert.deepEqual(solo.slice(0, 4), [false, true, false, false], 'exclusive');
  solo = soloPress(solo, setOuts, [0], true);
  assert.deepEqual(solo.slice(0, 4), [true, true, false, false], 'added');
  solo = soloPress(solo, setOuts, [0, 1]);
  assert.deepEqual(solo.slice(0, 4), [false, false, false, false], 'the group alone soloed: pressing it again clears');
  const other = [...ZEROS]; other[9] = true;
  assert.equal(soloPress(other, setOuts, [2])[9], true, 'another set\'s solo is left alone');
  let mute = mutePress(ZEROS, [0, 1]);
  assert.deepEqual(mute.slice(0, 2), [true, true]);
  mute = mutePress(mute, [0, 2]);
  assert.deepEqual(mute.slice(0, 3), [true, true, true], 'not all muted: all are muted');
  mute = mutePress(mute, [0, 2]);
  assert.deepEqual(mute.slice(0, 3), [false, true, false]);
});

test('set labels: the running preset\'s own when every set matches, otherwise by kind and order', () => {
  const sets = [{id: 'speakers', kind: 'speakers'}, {id: 'near', kind: 'speakers'}, {id: 'hp', kind: 'headphones'}, {id: 'hp2', kind: 'headphones'}];
  assert.deepEqual(setLabels(sets), {speakers: 'Speakers', near: 'Speakers 2', hp: 'Headphones', hp2: 'Headphones 2'});
  const doc = {buses: [{id: 'speakers', kind: 'speakers', label: 'Main room'}, {id: 'near', kind: 'speakers', label: 'Nearfield'}, {id: 'hp', kind: 'headphones', label: 'Cans'}, {id: 'hp2', kind: 'headphones', label: 'Guest'}]};
  assert.deepEqual(setLabels(sets, doc), {speakers: 'Main room', near: 'Nearfield', hp: 'Cans', hp2: 'Guest'});
  assert.deepEqual(setLabels(sets, {buses: doc.buses.slice(0, 3)}), setLabels(sets), 'one set missing: none of its labels are trusted');
  assert.deepEqual(setLabels(sets.slice(0, 1), {buses: [{id: 'speakers', kind: 'headphones', label: 'X'}]}), {speakers: 'Speakers'}, 'a kind that differs');
});

test('the LED ring: 31 lights, the blocked part above the limit, the reference marker, dim and hot', () => {
  const ring = ledRing(-10, {maxDb: -6, ref: -20});
  assert.equal(ring.length, 31);
  assert.equal(ring[0], 'lit');
  assert.equal(ring[20], 'lit', '-20 dB: lit, at the reference');
  assert.equal(ring[21], 'lit over', '-18 dB: above the reference');
  assert.equal(ring[25], 'lit over', '-10 dB');
  assert.equal(ring[26], '', '-8 dB: unlit');
  assert.ok(ring.slice(28).every(c => c === 'blocked'), 'above -6 dB');
  assert.equal(ledRing(-30, {ref: -20})[20], 'ref', 'an unlit light at the reference');
  assert.equal(ledRing(0)[30], 'lit hot');
  assert.equal(ledRing(-30, {dim: true, ref: -10})[10], 'lit dim');
  assert.ok(ledRing(-10, {mute: true}).every(c => c !== 'lit' && !c.startsWith('lit')), 'muted: dark');
  assert.ok(ledRing(-60).slice(1).every(c => !c.startsWith('lit')) && ledRing(-60)[0] === 'lit');
  assert.equal(knobAngle(-60), -135);
  assert.equal(knobAngle(0), 135);
  assert.equal(knobAngle(-30), 0);
});

test('the state line', () => {
  assert.equal(stateLine({playing: false, level: -10}).text, 'Not playing');
  assert.equal(stateLine({mute: true, dim: true, level: -10}).text, 'Muted');
  assert.equal(stateLine({dim: true, level: -10, dimDb: -20}).text, 'Dimmed to −30.0 dB');
  assert.equal(stateLine({level: -10, ref: -10, note: '79 dB SPL'}).text, 'At reference · 79 dB SPL');
  assert.equal(stateLine({level: -10, ref: -10}).text, 'At reference');
  assert.equal(stateLine({level: -8.5, ref: -10}).text, '+1.5 dB from ref');
  assert.equal(stateLine({level: -12, ref: -10}).text, '−2.0 dB from ref');
});

test('the room: placed by the label\'s first word, subs across the front, the rest listed', () => {
  const {placed, unplaced} = roomLayout([out(0, 'L'), out(1, 'R 2'), out(2, 'Out 3'), out(3, 'Sub L', 'sub'), out(4, 'Sub R', 'sub')]);
  assert.deepEqual(placed.map(p => [p.n, p.x, p.y]), [[0, 24, 10], [1, 76, 10], [3, 41.5, 27], [4, 58.5, 27]]);
  assert.deepEqual(unplaced.map(o => o.label), ['Out 3']);
});

test('group chips: the standard groups the labels make, Subs, then custom; none equal to the whole set', () => {
  const outs = ['L', 'R', 'C', 'Sub', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr'].map((l, n) => out(n, l, n === 3 ? 'sub' : 'speaker'));
  const chips = groupChips(outs, [{id: 'g1', name: 'Tops', outs: [8, 9, 99]}]);
  assert.deepEqual(chips.map(c => c.name), ['Fronts', 'Centre', 'Surrounds', 'Rears', 'Heights', 'Left', 'Right', 'Subs', 'Tops']);
  assert.deepEqual(chips.find(c => c.name === 'Fronts').outs, [0, 1, 2]);
  assert.deepEqual(chips.find(c => c.name === 'Left').outs, [0, 4, 6, 8, 10]);
  assert.deepEqual(chips.at(-1), {name: 'Tops', outs: [8, 9], custom: 'g1'});
  assert.deepEqual(groupChips([out(0, 'L'), out(1, 'R')]).map(c => c.name), ['Left', 'Right'], 'Fronts would be the whole set');
  assert.equal(bankTag(out(3, 'Sub 2', 'sub'), 'speakers', 0), 'S2');
  assert.equal(bankTag(out(3, 'Sub', 'sub'), 'speakers', 0), 'S');
  assert.equal(bankTag(out(14, 'Phones L'), 'headphones', 0), 'L');
  assert.equal(bankTag(out(5, 'Ls'), 'speakers', 4), 'Ls');
});

test('controlRoom, one speaker set and headphones: a card each, folds, subs, one room, no set switch', () => {
  const model = reduceMonitor(body714()), values = monitorValues(model);
  const C = controlRoom({model, values, labels: setLabels(model.sets)});
  assert.deepEqual(C.cards.map(c => [c.key, c.title]), [['speakers', 'Speakers'], ['headphones', 'Headphones']]);
  const [spk, hp] = C.cards;
  assert.equal(spk.state, '−8.5 dB from ref');
  assert.deepEqual(spk.folds.map(f => f.label), ['Full', '5.1', 'Stereo', 'Mono']);
  assert.equal(spk.showFolds, true);
  assert.equal(hp.showFolds, false, 'one fold: no Listen as');
  assert.deepEqual(spk.subs, {on: true});
  assert.equal(hp.subs, null);
  assert.equal(spk.vertical, true);
  assert.equal(hp.vertical, false);
  assert.deepEqual(hp.outputs.map(o => o.tag), ['L', 'R']);
  assert.equal(C.several, false);
  assert.deepEqual(C.setSwitch, []);
  assert.equal(C.rooms.length, 1);
  assert.equal(C.rooms[0].unplaced.length, 0);
  assert.equal(C.rooms[0].tiles.length, 12);
  assert.equal(spk.trims, null);
  assert.equal(C.keys.some(([k]) => k === '1 – 9'), false, 'no set keys with one set');
  assert.equal(C.keys.some(([k]) => k === 'T'), false, 'no talkback key');
  const muted = controlRoom({model, values: {...values, sets: {...values.sets, speakers: {...values.sets.speakers, mute: true}}}, labels: setLabels(model.sets)});
  assert.equal(muted.cards[0].state, 'Muted');
});

test('controlRoom, two speaker sets: Main volume, trims, the set switch, and the playing set\'s room', () => {
  const model = reduceMonitor(bodyTwoSets()), values = monitorValues(model);
  const C = controlRoom({model, values, labels: setLabels(model.sets)});
  assert.equal(C.several, true);
  assert.deepEqual(C.cards.map(c => c.key), ['main']);
  const main = C.cards[0];
  assert.equal(main.title, 'Main volume');
  assert.deepEqual(main.ids, ['mains', 'nearfield']);
  assert.equal(main.locked, true);
  assert.equal(main.maxDb, -6);
  assert.equal(main.state, 'At reference · 79 dB SPL C');
  assert.deepEqual(main.trims.map(t => [t.label, t.trim, t.plays, t.playing]), [['Speakers', 0, '−18.0 dB', true], ['Speakers 2', -1.5, '−19.5 dB', false]]);
  assert.deepEqual(C.setSwitch.map(s => [s.id, s.on, s.sub]), [['mains', true, 'Playing'], ['nearfield', false, 'Click to switch'], ['all', false, 'Play every set']]);
  assert.deepEqual(C.rooms.map(r => r.id), ['mains']);
  const all = controlRoom({model, values: {...values, active: 'all'}, labels: setLabels(model.sets)});
  assert.deepEqual(all.rooms.map(r => r.id), ['mains', 'nearfield']);
  assert.deepEqual(all.setSwitch.map(s => s.sub), ['Playing · click to solo', 'Playing · click to solo', 'Every set is playing']);
  assert.deepEqual(all.rooms[1].chips.map(c => c.name), ['Left', 'Right', 'Subs'], 'the shared sub is in the second set too');
  assert.ok(C.keys.some(([k]) => k === '1 – 9'));
  assert.equal(C.keys[0][1], 'Main volume up or down 1 dB');
});

test('controlRoom: a refused state file is said; no sets is empty', () => {
  const refused = reduceMonitor(body714({effective: {...body714().effective, state: 'refused', reason: 'level_db out of range'}}));
  assert.equal(controlRoom({model: refused, values: monitorValues(refused), labels: {}}).refused, 'level_db out of range');
  const none = reduceMonitor({...body714(), topology: {sets: []}});
  assert.equal(controlRoom({model: none, values: monitorValues(none), labels: {}}).empty, true);
});

test('controlRoom: the peak line and clip state come from the to-network bank', () => {
  const model = reduceMonitor(body714()), values = monitorValues(model);
  const meters = Array.from({length: 16}, (_, i) => ({peak: i === 2 ? -6.2 : -70, hold: -60, clip: i === 14}));
  const C = controlRoom({model, values, labels: setLabels(model.sets), meters});
  assert.equal(C.cards[0].peakText, 'Peak −6.2 dB');
  assert.equal(C.cards[1].peakText, 'No signal');
  assert.equal(C.anyClip, true);
});

test('Level safety words: power-up only, a restart keeps the level', () => {
  assert.equal(safetyNotes({maxDb: 0}).maxNote, 'No limit: the knobs reach 0 dB.');
  assert.match(safetyNotes({maxDb: -6}).maxNote, /stop at −6\.0 dB/);
  assert.match(safetyNotes({start: 'last'}).startNote, /^After power-up/);
  assert.match(safetyNotes({start: 'fixed', startDb: -24, maxDb: 0}).startNote, /every knob starts at −24\.0 dB/);
  assert.match(safetyNotes({start: 'reference'}).startNote, /restart of audio keeps/);
  assert.match(safetyNotes({lock: true}).lockNote, /^Locked/);
});

test('health: the Control Room and the limits kinds', () => {
  assert.equal(monitorOffered(null), false);
  assert.equal(monitorOffered({control: {monitor: {available: true}}}), true);
  assert.equal(monitorKind({control: {monitor: {kinds: ['monitor-limits']}}}, 'monitor-limits'), true);
  assert.equal(monitorKind({control: {monitor: {kinds: []}}}, 'monitor-limits'), false);
});

test('custom groups: kept in browser storage, unreadable storage reads as none', () => {
  const store = new Map();
  const storage = {getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v)};
  assert.deepEqual(readGroups(storage), {});
  let groups = addGroup({}, 'speakers', '  ', [9, 8]);
  assert.equal(groups.speakers[0].name, 'Group 1');
  assert.deepEqual(groups.speakers[0].outs, [8, 9]);
  groups = addGroup(groups, 'speakers', 'Tops', [8]);
  assert.equal(saveGroups(groups, storage), true);
  assert.deepEqual(readGroups(storage), groups);
  groups = removeGroup(groups, 'speakers', groups.speakers[0].id);
  assert.deepEqual(groups.speakers.map(g => g.name), ['Tops']);
  const broken = {getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); }};
  assert.deepEqual(readGroups(broken), {});
  assert.equal(saveGroups(groups, broken), false);
  store.set('usb-aoip-monitor-groups-v1', '{"speakers": [{"id": 1}], "x": 3}');
  assert.deepEqual(readGroups(storage), {speakers: []});
});

test('the keyboard list follows what the first card is', () => {
  assert.equal(keyList({several: false, first: 'headphones'})[1][1], 'Mute the headphones');
});
