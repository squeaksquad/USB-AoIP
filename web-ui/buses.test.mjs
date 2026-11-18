import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, parsePreset, setOutputRole, validateConfig } from './model.mjs';
import { addSpeakerSet, applyBusLayout, busForOutput, createHeadphoneBus, removeBus, setHeadphoneMode, setHeadphonePair, setHeadphoneMatrix, speakerGroupSourceIds, speakerSetSize, subShareChoices } from './buses.mjs';
import { applyLayout } from './workflows.mjs';
import { swapOutputs } from './workflows.mjs';

test('default owns only the speaker bus and leaves spare outputs reusable', () => {
  const c = createConfig();
  assert.deepEqual(c.buses[0].outputIds, Array.from({length: 13}, (_, i) => i));
  assert.equal(busForOutput(c, 13), null); assert.equal(c.buses.length, 1); validateConfig(c);
});

test('bass routing sources contain only channels assigned to speaker groups', () => {
  const c = createConfig();
  assert.deepEqual(speakerGroupSourceIds(c), Array.from({length: 12}, (_, i) => i));
  const headphones = createHeadphoneBus(c);
  assert.deepEqual(speakerGroupSourceIds(headphones), Array.from({length: 12}, (_, i) => i));
  const stereo = applyBusLayout(headphones, 'speakers', '2.1', [0, 1, 2]);
  assert.deepEqual(speakerGroupSourceIds(stereo), [0, 1, stereo.lfe.input]);
});

test('scoped speaker layout preserves bus settings and unrelated headphone bus', () => {
  const original = createHeadphoneBus(createConfig());
  original.buses[0].label = 'Mains'; original.outputs[15].mute = true; original.outputs[14].delayMs = 4;
  const next = applyBusLayout(original, 'speakers', '5.1.4', [0,1,2,3,4,5,6,7,8,9]);
  assert.equal(next.buses.find(b => b.id === 'speakers').label, 'Mains');
  assert.equal(next.outputs[15].mute, true);
  assert.equal(next.outputs[14].delayMs, 4); assert.equal(next.outputs[14].busId, 'headphones');
  assert.equal(next.buses.find(b => b.id === 'speakers').outputIds.length, 10);
});

test('headphone pair and downmix settings are explicit and retained', () => {
  let c = createHeadphoneBus(createConfig());
  c = setHeadphonePair(c, 'headphones', [4, 5]); c = setHeadphoneMode(c, 'headphones', 'downmix');
  const matrix = Array.from({length: 16}, () => [null, null]); matrix[0][0] = -3; matrix[2][1] = -6;
  c = setHeadphoneMatrix(c, 'headphones', matrix); assert.deepEqual(c.buses[1].inputPair, [4,5]); assert.equal(c.buses[1].downmixMatrix[2][1], -6);
  assert.deepEqual(parsePreset(JSON.stringify(c)), c);
});

test('invalid overlap, matrix values, and reassignment are rejected', () => {
  const c = createHeadphoneBus(createConfig());
  assert.throws(() => applyBusLayout(c, 'headphones', '5.1'));
  assert.throws(() => createHeadphoneBus(c, 'second', [0, 13]));
  const bad = structuredClone(c); bad.buses[1].downmixMatrix[0][0] = 13; assert.throws(() => validateConfig(bad));
  const level = structuredClone(c); level.buses[0].gainDb = 0; assert.throws(() => validateConfig(level), /no level or mute/);
  const muted = structuredClone(c); muted.buses[1].mute = false; assert.throws(() => validateConfig(muted), /no level or mute/);
});

test('legacy version 1 import keeps custom outputs without reserving headphones', () => {
  const legacy = createConfig(); legacy.version = 1; delete legacy.buses;
  legacy.outputs[0].label = 'Custom'; legacy.outputs[13].role = 'unused';
  const migrated = parsePreset(JSON.stringify(legacy));
  assert.equal(migrated.version, 3); assert.equal(migrated.outputs[0].label, 'Custom'); assert.ok(!('gainDb' in migrated.buses[0]));
  assert.equal(migrated.buses.length, 1); assert.equal(migrated.outputs[14].busId, null); validateConfig(migrated);
});

test('swapping outputs moves bus membership with the physical processing', () => {
  const c = createHeadphoneBus(createConfig()), moved = swapOutputs(c, 14, 13);
  assert.deepEqual(moved.buses.find(b => b.kind === 'headphones').outputIds, [13, 15]);
  assert.equal(moved.outputs[13].busId, 'headphones'); assert.equal(moved.outputs[14].busId, null); validateConfig(moved);
});

test('speaker bus creation and removal preserve unrelated buses', () => {
  let c = removeBus(createConfig(), 'speakers');
  c = addSpeakerSet(c, {layoutId: 'stereo', outputIds: [0, 1], subShare: 'none', label: 'Nearfield'});
  assert.equal(c.outputs[0].busId, 'speakers-2');
  c = createHeadphoneBus(c, 'phones', [14, 15]);
  c = removeBus(c, 'speakers-2');
  assert.equal(c.outputs[14].busId, 'phones'); assert.equal(c.buses.filter(b => b.kind === 'speakers').length, 1); validateConfig(c);
});

test('activating an unowned spare attaches it to speakers and protects headphones', () => {
  const c = createConfig();
  setOutputRole(c, 13, 'speaker');
  assert.equal(c.outputs[13].busId, 'speakers'); assert.ok(c.buses[0].outputIds.includes(13));
  validateConfig(c);
  const h = createHeadphoneBus(createConfig());
  assert.throws(() => setOutputRole(h, 14, 'sub'));
});

test('an added speaker set: layout on chosen spares, labelled by its number, with its subwoofer choice', () => {
  const base = applyLayout(createConfig(), '5.1');
  assert.deepEqual(subShareChoices(base, 'stereo'), ['main', 'none']);
  assert.deepEqual(subShareChoices(base, '2.1'), ['main', 'none', 'own']);
  assert.deepEqual(subShareChoices(applyLayout(createConfig(), 'stereo'), 'stereo'), ['none']);
  assert.equal(speakerSetSize('2.1', 'own'), 3); assert.equal(speakerSetSize('2.1', 'main'), 2); assert.equal(speakerSetSize('5.1', 'none'), 5);
  const shared = addSpeakerSet(base, {layoutId: 'stereo', outputIds: [7, 6], subShare: 'main'});
  const set = shared.buses[1];
  assert.deepEqual([set.id, set.label, set.subShare, set.outputIds], ['speakers-2', 'Speakers 2', 'main', [6, 7]]);
  assert.deepEqual([6, 7].map(i => [shared.outputs[i].label, shared.outputs[i].role, shared.outputs[i].source]), [['L 2', 'speaker', 0], ['R 2', 'speaker', 1]]);
  assert.ok(shared.sends.every(row => row[6] === null && row[7] === null), 'speakers take no sends');
  assert.deepEqual(shared.sends.map(row => row[3]), base.sends.map(row => row[3]), 'the main sub keeps its sends');
  const own = addSpeakerSet(base, {layoutId: '2.1', outputIds: [6, 7, 8], subShare: 'own', label: 'Near'});
  assert.equal(own.buses[1].label, 'Near'); assert.equal(own.outputs[8].role, 'sub'); assert.equal(own.outputs[8].label, 'Sub 2');
  assert.equal(own.sends[0][8], 0); assert.equal(own.sends[1][8], 0); assert.equal(own.sends[own.lfe.input][8], 0);
  const none = addSpeakerSet(base, {layoutId: '2.1', outputIds: [6, 7], subShare: 'none'});
  assert.deepEqual(none.buses[1].outputIds.map(i => none.outputs[i].role), ['speaker', 'speaker']);
  assert.throws(() => addSpeakerSet(base, {layoutId: 'stereo', outputIds: [6], subShare: 'main'}), /Choose 2 spare outputs/);
  assert.throws(() => addSpeakerSet(base, {layoutId: 'stereo', outputIds: [5, 6], subShare: 'main'}), /spare outputs only/);
  assert.throws(() => addSpeakerSet(base, {layoutId: 'stereo', outputIds: [6, 7], subShare: 'own'}), /no subwoofer of its own/);
  assert.throws(() => addSpeakerSet(applyLayout(createConfig(), 'stereo'), {layoutId: 'stereo', outputIds: [6, 7], subShare: 'main'}), /no subwoofer to share/);
  // A third set is numbered after the speaker sets there are.
  const third = addSpeakerSet(shared, {layoutId: 'stereo', outputIds: [8, 9], subShare: 'none'});
  assert.deepEqual([third.buses[2].id, third.outputs[8].label], ['speakers-3', 'L 3']);
});

test('subwoofer choices stay possible through role changes, layout changes and removal', () => {
  const base = applyLayout(createConfig(), '5.1');
  let c = addSpeakerSet(base, {layoutId: 'stereo', outputIds: [6, 7], subShare: 'main'});
  setOutputRole(c, 7, 'sub');
  assert.equal(c.buses[1].subShare, 'own', 'a sub of its own: its own'); validateConfig(c);
  setOutputRole(c, 7, 'speaker');
  assert.equal(c.buses[1].subShare, 'main', 'its last sub gone: shares the main sub again'); validateConfig(c);
  // The mains lose their sub: a sharing set has none to share.
  const stereo = applyBusLayout(c, 'speakers', 'stereo', [0, 1, 2, 3, 4, 5]);
  assert.equal(stereo.buses[1].subShare, 'none'); assert.equal(stereo.buses[1].outputIds.length, 2);
  // 'none' is the operator's: a main sub coming back does not undo it.
  assert.equal(applyBusLayout(stereo, 'speakers', '5.1', [0, 1, 2, 3, 4, 5]).buses[1].subShare, 'none');
  const bad = structuredClone(c); bad.buses[1].subShare = 'own'; assert.throws(() => validateConfig(bad), /needs a subwoofer output/);
  const first = structuredClone(c); first.buses[0].subShare = 'main'; assert.throws(() => validateConfig(first), /only an added speaker set/);
  const removed = removeBus(c, 'speakers-2');
  assert.equal(removed.buses.length, 1); assert.ok([6, 7].every(i => removed.outputs[i].role === 'unused' && removed.outputs[i].busId === null));
});
