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
import { systemView } from './view-system.mjs';

function state(config = createConfig(), extra = {}) {
  return {
    config, connected: false, dante: false, changes: 0,
    cards: statusCards(null), rows: meterRows(null), meterNote: 'Not connected: no levels to show.', meterCaption: 'Peak level',
    eqOpen: null, band: 0, eqClipboard: null, eqImport: null, confirmResetAll: false,
    align: {open: false, unit: 'm', text: [], preview: null, error: '', note: ''},
    headphoneIds: config.buses.filter(b => b.kind === 'headphones').flatMap(b => b.outputIds),
    route: {row: null, col: null}, setDetail: null, polarity: null,
    chooser: null, layouts: LAYOUTS.map(l => ({id: l.id, label: l.label, outputs: l.routing.length, fits: true})),
    facts: systemFacts(null), big: false, busy: false, shutdownRequested: false, canApply: false, applyReason: '', outage: 'audio stops',
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

test('no view writes an inline style or an inline handler', () => {
  for (const html of everyView()) {
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
  const offline = systemView(state());
  assert.doesNotMatch(offline, /data-act="shutdown"/);
  assert.match(offline, /Presets in this browser/);
  const online = systemView(state(createConfig(), {connected: true, canApply: true}));
  assert.match(online, /data-act="shutdown"/);
  assert.match(online, /Larger controls/);
  assert.match(online, /Last change to the device/);
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
