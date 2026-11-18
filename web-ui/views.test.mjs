// The views are pure (state in, HTML text out), so they run here with no
// browser. These tests pin what phase 1 of docs/web/REDESIGN-2026-11.md
// promises about them: no inline styles, and no control for a feature the
// engine does not have.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig } from './model.mjs';
import { createHeadphoneBus } from './buses.mjs';
import { LAYOUTS, blankConfig } from './workflows.mjs';
import { statusCards, meterRows, systemFacts } from './backend.mjs';
import { presetRows } from './presets.mjs';
import { statusView } from './view-status.mjs';
import { outputsView, eqView, thumbPoints } from './view-outputs.mjs';
import { routingView, crosspoint } from './view-routing.mjs';
import { setsView } from './view-sets.mjs';
import { bassView } from './view-bass.mjs';
import { chooserView } from './view-chooser.mjs';
import { systemView, actionsPanel, safetyPanel } from './view-system.mjs';
import { ACTION_KINDS } from './actions.mjs';
import { reduceMonitor, monitorValues, controlRoom, setLabels, safetyNotes } from './monitor.mjs';
import { controlRoomView } from './view-control.mjs';

function state(config = createConfig(), extra = {}) {
  return {
    config, connected: false, dante: false, changes: 0,
    cards: statusCards(null), rows: meterRows(null), meterNote: 'Not connected: no levels to show.', meterCaption: 'Peak level',
    eqOpen: null, band: 0, eqClipboard: null, eqImport: null, confirmResetAll: false,
    align: {open: false, unit: 'm', text: [], preview: null, error: '', note: ''},
    headphoneIds: config.buses.filter(b => b.kind === 'headphones').flatMap(b => b.outputIds),
    route: {row: null, col: null}, setDetail: null, polarity: null,
    chooser: null, layouts: LAYOUTS.map(l => ({id: l.id, label: l.label, outputs: l.routing.length, fits: true})),
    facts: systemFacts(null), big: false, busy: false, shutdownRequested: false, rebootRequested: false, actions: [], actionNote: null, canApply: false, applyReason: '', outage: 'audio stops',
    presetRows: presetRows({stored: {'Room A': {}}}), editing: null, applyLine: '', applySteps: [],
    logServices: [['all', 'All']], logService: 'all', logQuery: '', logBusy: false, logText: '', logShown: '', logCount: '',
    ...extra,
  };
}
const phones = () => createHeadphoneBus(createConfig());
const everyView = () => {
  const withPhones = phones();
  return [
    statusView(state()),
    outputsView(state()), outputsView(state(withPhones, {eqOpen: 14, eqImport: {text: '', error: '', note: '', ready: false}, align: {open: true, unit: 'ft', text: ['3'], preview: {delays: [0], limited: [], farthest: 3}, error: '', note: ''}, confirmResetAll: true})),
    eqView(state(withPhones, {eqOpen: 14, eqImport: {text: '', error: '', note: '', ready: false}})), eqView(state(createConfig(), {eqOpen: 0, band: 3})),
    routingView(state()), routingView(state(withPhones, {route: {row: 3, col: 0}})), routingView(state(withPhones, {route: {row: 14, col: null}})), routingView(state(createConfig(), {route: {row: null, col: 2}})),
    setsView(state()), setsView(state(withPhones, {setDetail: 'headphones'})),
    bassView(state()), bassView(state(blankConfig())),
    chooserView(state(createConfig(), {chooser: {mode: 'new', layoutId: '5.1', name: 'New', error: ''}, changes: 2})),
    chooserView(state(createConfig(), {chooser: {mode: 'layout', layoutId: null, name: '', error: ''}})),
    systemView(state()), systemView(state(createConfig(), {connected: true, canApply: true})),
  ];
};
const actionViews = () => {
  const online = extra => systemView(state(createConfig(), {connected: true, canApply: true, actions: [...ACTION_KINDS], ...extra}));
  return [online(), online({busy: true, actionNote: {text: 'Restarting audio…', tone: 'busy'}}), online({actionNote: {text: 'Restart audio failed: <x>', tone: 'bad'}}), online({rebootRequested: true}), online({shutdownRequested: true})];
};

test('no view writes an inline style or an inline handler', () => {
  for (const html of [...everyView(), ...actionViews()]) {
    assert.doesNotMatch(html, /\sstyle\s*=/i);
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  }
});

test('what the engine lacks is left out, not shown disabled', () => {
  const all = everyView().join('\n');
  for (const absent of [/solo/i, /\bdim\b/i, /talkback/i, /calibration noise/i, /\bgate\b/i, /control room/i, /add speaker set/i, /restart (audio|clock)\b(?! on)/i, /support bundle/i, /change password/i, /reboot/i, /sample rate.*<select/i]) {
    assert.doesNotMatch(all, absent);
  }
  assert.doesNotMatch(all, /data-act="(solo|dim|mute)"/);
  assert.doesNotMatch(all, /\bbus(es)?\b/i, '"bus" is not used in labels');
});

test('Outputs: one row per output in use, each with level, delay, polarity, EQ and on or off', () => {
  const html = outputsView(state());
  assert.equal((html.match(/class="out-row [^"]*" data-row=/g) || []).length, 13);
  for (const field of ['out.label', 'out.gainDb', 'out.delayMs']) assert.equal((html.match(new RegExp(`data-f="${field}"`, 'g')) || []).length, 13);
  for (const act of ['pol', 'eq-open', 'onoff']) assert.equal((html.match(new RegExp(`data-act="${act}"`, 'g')) || []).length, 13);
  assert.match(html, /Not in use/);
  const off = createConfig(); off.outputs[0].mute = true;
  assert.match(outputsView(state(off)), /data-act="onoff" data-i="0" aria-pressed="false"[^>]*>Off</);
  assert.equal(thumbPoints(createConfig().outputs[0], false).split(' ').length, 29);
});

test('Routing: the three kinds of crosspoint come from the preset model', () => {
  const config = phones();
  assert.deepEqual(crosspoint(config, 0, 0), {kind: 'feed', on: true, text: '●'});
  assert.equal(crosspoint(config, 0, 1).on, false);
  assert.deepEqual(crosspoint(config, 3, 0), {kind: 'bass', on: true, level: 0, text: '0.0'});
  assert.equal(crosspoint(config, 13, 0).kind, 'none');
  const pair = crosspoint(config, 14, 0);
  assert.equal(pair.kind, 'pair'); assert.equal(pair.on, true); assert.equal(pair.ear, 0);
  config.buses.at(-1).inputMode = 'downmix';
  assert.equal(crosspoint(config, 15, 2).text, '-3.0');
  const html = routingView(state(config));
  assert.equal((html.match(/data-act="route-cell"/g) || []).length, 256);
  assert.doesNotMatch(html, /Dante outputs|To the computer/, 'the network patches wait for the engine');
});

test('Bass management: no subwoofer, nothing to manage; with one, a row per source', () => {
  assert.match(bassView(state(blankConfig())), /no subwoofer/);
  const html = bassView(state());
  assert.equal((html.match(/class="bass-row /g) || []).length, 13, 'eleven speakers, LFE, and the header');
  assert.match(html, /cols-2/);
});

test('System: only what the device can do today', () => {
  const offline = systemView(state(createConfig(), {actions: [...ACTION_KINDS]}));
  assert.doesNotMatch(offline, /data-act="sys-action"|id="actions-panel"/, 'not connected: no Actions panel, whatever the last list said');
  assert.match(offline, /Presets in this browser/);
  const online = systemView(state(createConfig(), {connected: true, canApply: true, actions: ['shutdown']}));
  assert.match(online, /data-act="sys-action" data-v="shutdown"/);
  assert.match(online, /Larger controls/);
  assert.match(online, /Last change to the device/);
  assert.doesNotMatch(systemView(state(createConfig(), {connected: true, canApply: true})), /id="actions-panel"/, 'an empty list: no panel');
});

test('Actions: each action the device lists, in order, and nothing it does not', () => {
  const kinds = html => [...html.matchAll(/data-act="sys-action" data-v="([^"]+)"/g)].map(m => m[1]);
  const subsets = [[], ...ACTION_KINDS.map(kind => [kind]), ['shutdown', 'bundle'], ['reboot', 'restart-audio', 'password'], [...ACTION_KINDS].reverse()];
  for (const subset of subsets) {
    const html = actionsPanel(state(createConfig(), {connected: true, actions: subset}));
    assert.deepEqual(kinds(html), ACTION_KINDS.filter(kind => subset.includes(kind)), subset.join());
    if (!subset.length) assert.equal(html, '');
  }
  const all = actionsPanel(state(createConfig(), {connected: true, actions: [...ACTION_KINDS, 'format-disk']}));
  assert.doesNotMatch(all, /format-disk/);
  assert.match(all, /<span role="status" class="action-note">/);
  for (const label of ['Restart audio', 'Restart clock service', 'Download support bundle', 'Change page password', 'Reboot the Pi', 'Shut down the Pi']) assert.match(all, new RegExp(`>${label}</button>`));
  assert.match(all, /class="caution" data-act="sys-action" data-v="reboot"/);
  assert.match(all, /class="danger" data-act="sys-action" data-v="shutdown"/);
  assert.match(all, /audio stops/, 'the stack\'s outage words');
  assert.doesNotMatch(all, /disabled/);
  assert.doesNotMatch(actionsPanel(state(createConfig(), {connected: true, actions: ['bundle']})), /reboot|shut down|password|restart/i, 'what is not listed is left out, not disabled');
});

test('Actions: busy disables every button; the note is the receipt\'s, escaped', () => {
  const busy = actionsPanel(state(createConfig(), {connected: true, busy: true, actions: [...ACTION_KINDS], actionNote: {text: 'Restarting audio…', tone: 'busy'}}));
  assert.equal((busy.match(/data-act="sys-action"[^>]*disabled>/g) || []).length, 6);
  assert.match(busy, /class="action-note tone-busy">Restarting audio…</);
  const failed = actionsPanel(state(createConfig(), {connected: true, actions: ['restart-audio'], actionNote: {text: 'Restart audio failed: <b>', tone: 'bad'}}));
  assert.match(failed, /tone-bad">Restart audio failed: &lt;b&gt;</);
  assert.match(actionsPanel(state(createConfig(), {connected: true, actions: ['reboot'], rebootRequested: true})), /disabled>Rebooting…</);
  assert.match(actionsPanel(state(createConfig(), {connected: true, actions: ['shutdown'], shutdownRequested: true})), /disabled>Shutting down…</);
});

test('EQ editor: sixteen handles and chips, three numbers for the band, and the ear link only on headphones', () => {
  const html = eqView(state(createConfig(), {eqOpen: 0, band: 3}));
  assert.equal((html.match(/data-eq-node=/g) || []).length, 16);
  assert.equal((html.match(/data-act="band-pick"/g) || []).length, 16);
  for (const f of ['band.frequency', 'band.gainDb', 'band.q']) assert.match(html, new RegExp(`data-f="${f}" data-i="3"`));
  assert.equal((html.match(/class="stepper"[\s\S]*?<\/label>/g) || []).filter(row => /<span aria-hidden="true">/.test(row)).length, 3, 'every row keeps the place of a unit, Q included');
  assert.doesNotMatch(html, /data-act="eq-link"/);
  assert.match(eqView(state(phones(), {eqOpen: 14})), /data-act="eq-link"/);
  assert.doesNotMatch(outputsView(state(createConfig(), {eqOpen: 0})), /data-eq-node=/, 'the editor is not drawn among the rows');
});

// ---- Phase 3: the Control Room and the Level safety panel

const ZEROS16 = Array(16).fill(false);
const mout = (n, label, role = 'speaker') => ({n, role, label});
function monitor714() {
  const labels = ['L', 'R', 'C', 'Sub', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', 'Ltr', 'Rtr'];
  return {ok: true, available: true, seq: 4, state: {}, limits: {maxDb: 0, start: 'last', startDb: -30, lock: false, refs: {}, file: 'absent'},
    topology: {sets: [{id: 'speakers', kind: 'speakers', folds: ['full', '5.1', 'stereo', 'mono'], outputs: labels.map((l, n) => mout(n, l, n === 3 ? 'sub' : 'speaker'))},
      {id: 'headphones', kind: 'headphones', folds: ['full'], outputs: [mout(14, 'Phones L'), mout(15, 'Phones R')]}]},
    effective: {seq: 4, state: 'applied', reason: '', active: 'speakers', dimDb: -20, subs: true,
      sets: {speakers: {levelDb: -18.5, trimDb: 0, dim: false, mute: false, fold: 'full'}, headphones: {levelDb: -30, trimDb: 0, dim: false, mute: false, fold: 'full'}},
      solo: ZEROS16, outMute: ZEROS16}};
}
function monitorTwoSets(lock = true) {
  return {ok: true, available: true, seq: 1, limits: {maxDb: -6, start: 'reference', startDb: -30, lock, refs: {mains: {levelDb: -18, note: '79 dB SPL C'}}},
    topology: {sets: [{id: 'mains', kind: 'speakers', folds: ['full', 'stereo', 'mono'], outputs: [mout(0, 'L'), mout(1, 'R'), mout(2, 'C'), mout(3, 'Sub', 'sub')]},
      {id: 'nearfield', kind: 'speakers', folds: ['full', 'mono'], outputs: [mout(4, 'L 2'), mout(5, 'R 2'), mout(3, 'Sub', 'sub')]}]},
    effective: {seq: 1, state: 'applied', reason: '', active: 'mains', dimDb: -20, subs: true,
      sets: {mains: {levelDb: -18, trimDb: 0, dim: false, mute: false, fold: 'full'}, nearfield: {levelDb: -18, trimDb: -1.5, dim: false, mute: false, fold: 'full'}},
      solo: ZEROS16, outMute: ZEROS16}};
}
function crHtml(body, extra = {}) {
  const model = reduceMonitor(body);
  return controlRoomView(controlRoom({model, values: monitorValues(model), labels: setLabels(model.sets), ...extra}));
}
function noInline(html, what) {
  assert.doesNotMatch(html, /\sstyle=/, `${what}: no inline style`);
  assert.doesNotMatch(html, /\son[a-z]+=/, `${what}: no inline handler`);
}
const LEFT_OUT = [/Pre\b|Post\b/, /Calibrat/i, /talkback/i, /\bSum\b/, /Follow/, /Edit sources/i, /\bcue\b/i];

test('Control Room, 7.1.4 and headphones: two cards, Listen as on the speakers only, Subwoofers, a room, nothing left out drawn', () => {
  const html = crHtml(monitor714());
  noInline(html, 'control room');
  for (const re of LEFT_OUT) assert.doesNotMatch(html, re, `left out: ${re}`);
  assert.doesNotMatch(html, /<kbd>T<\/kbd>/, 'no T key');
  assert.match(html.replace(/<[^>]+>/g, ''), /Everything here is instant, is not part of a preset, and is kept on the device across restarts\./);
  assert.match(html, /role="slider"/);
  assert.equal((html.match(/class="cr-card /g) || []).length, 2);
  assert.match(html, /Listen as/);
  assert.equal((html.match(/data-cr="fold;/g) || []).length, 4, 'Full, 5.1, Stereo, Mono on the speakers; none on one-fold headphones');
  assert.match(html, /data-cr="subs"/);
  assert.match(html, /after the level knob/);
  assert.match(html, /data-cr="set-ref;/, 'Set is drawn when not locked');
  assert.doesNotMatch(html, /Main volume/);
  assert.doesNotMatch(html, /data-cr="active;/, 'no set switch with one speaker set');
});

test('Control Room, two speaker sets: Main volume with trims and the set switch; locked reference has no Set', () => {
  const html = crHtml(monitorTwoSets(true));
  noInline(html, 'two sets');
  assert.match(html, /Main volume/);
  assert.match(html, /data-cr="active;all"/);
  assert.match(html, /data-m="trim"/);
  assert.doesNotMatch(html, /data-cr="set-ref;/);
  assert.match(crHtml(monitorTwoSets(true), {refOpen: {main: true}}), /The reference is locked on the System tab/);
  assert.match(html, /bass is not/i, 'the Subwoofers switch says bass is not redirected');
  const open = crHtml(monitorTwoSets(false));
  assert.match(open, /data-cr="set-ref;/);
});

test('Level safety panel: drawn only with its limits, no inline styles, the start rule is after power-up', () => {
  const limits = monitor714().limits;
  const S = {connected: true, safety: {limits, notes: safetyNotes(limits), note: null, busy: false}};
  const html = safetyPanel(S);
  noInline(html, 'safety');
  assert.match(html, /id="safety-panel"/);
  assert.match(html, /power/i);
  assert.match(html, /data-act="sf-lock"/);
  assert.equal(safetyPanel({connected: true, safety: null}), '', 'not drawn without the kind');
  assert.equal(safetyPanel({...S, connected: false}), '');
  assert.match(safetyPanel({...S, safety: {...S.safety, limits: {...limits, start: 'fixed'}}}), /data-m="sf-start-db"/);
});
