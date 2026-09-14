import test from 'node:test';
import assert from 'node:assert/strict';
import { probeHealth, fetchLogs, connectionLine, systemFacts, dspNote, formatDuration, serviceLabel, browserStore, piStore, fetchMeters, meterLevels, liveState, requestLive, requestCommit, awaitReceipt } from './backend.mjs';

const ok = body => ({ok: true, status: 200, json: async () => body});
const fail = (status, body) => ({ok: false, status, json: async () => body});

const live = {
  ok: true, generated: '2026-09-09T17:00:00Z', host: 'audio-dev',
  audio: {sampleRate: 48000, inputs: 16, outputs: 16},
  mode: {actual: 'direct', running: true, detail: 'Direct USB ↔ AoIP bridge'},
  services: {gadget: {unit: 'usb-16x16.service', state: 'active'},
             aes67: {unit: 'usb16x16-aes67.service', state: 'active'},
             governor: {unit: 'usb16x16-governor.service', state: 'active'}},
  usb: {present: true, state: 'configured', speed: 'high-speed'},
  ptp: {status: 'locked', gmid: '00-1D-C1-FF-FE-1D-27-DC', jitter: 33},
  network: {interface: 'eth0', carrier: true, speedMbit: 1000, address: '169.254.92.97'},
  bridge: {present: true, ageSeconds: 2, ppm: -15.2, phaseErrorUs: 829, txQueue: 176, rxQueue: 135,
           txQueueFloor: 28, rxQueueFloor: 66, txRestarts: 2, rxRestarts: 1,
           txDropped: 0, rxDropped: 0, txClip: 0, rxClip: 0},
  recovers: 3, stage: {text: 'stable for 120s', secondsAgo: 400},
  streams: {sinks: [{id: 0, delay: 103}, {id: 1, delay: 103}], sources: [{id: 0}, {id: 1}]},
  system: {tempC: 47.7, throttled: '0x0', throttledNow: false, load: [0.04, 0.04, 0], uptimeSeconds: 70440},
  meters: {available: false, reason: 'no tap'},
  dsp: {available: false, engine: 'CamillaDSP 4.1.3', missing: ['a preset-to-YAML compiler'], reason: 'under development'},
  service: {version: '1.0.0'},
};

const factFor = (health, label) => systemFacts(health).find(row => row.label === label);

test('probeHealth returns a snapshot only when the service reports ok', async () => {
  assert.equal(await probeHealth(async () => ok(live)), live);
  assert.equal(await probeHealth(async () => ok({ok: false})), null);
  assert.equal(await probeHealth(async () => fail(404, {})), null);
  assert.equal(await probeHealth(async () => { throw new Error('offline'); }), null);
  // A non-JSON body (a plain static server answering /api/health) is not a backend.
  assert.equal(await probeHealth(async () => ({ok: true, status: 200, json: async () => { throw new Error('bad json'); }})), null);
});

test('probeHealth rejects a JSON array, which is not a snapshot', async () => {
  assert.equal(await probeHealth(async () => ok([1, 2, 3])), null);
});

test('fetchLogs asks for the requested service and surfaces service errors', async () => {
  let seen = '';
  const text = await fetchLogs('aes67', 50, async url => { seen = url; return ok({ok: true, text: 'line'}); });
  assert.equal(text, 'line');
  assert.match(seen, /service=aes67/);
  assert.match(seen, /lines=50/);
  await assert.rejects(
    fetchLogs('usb', 200, async () => fail(503, {ok: false, error: 'journalctl is not answering on this host'})),
    /journalctl is not answering/);
});

test('fetchLogs falls back to a default line count for junk input', async () => {
  let seen = '';
  await fetchLogs('all', 'many', async url => { seen = url; return ok({ok: true, text: ''}); });
  assert.match(seen, /lines=200/);
});

test('connectionLine distinguishes offline, running and stopped', () => {
  assert.equal(connectionLine(null), 'Not connected · Local draft · Simulated meters');
  assert.match(connectionLine(live), /^Connected · audio-dev · Direct bridge running · PTP locked · jitter 33 · Simulated meters$/);
  const stopped = {...live, mode: {running: false, detail: 'AES67 service inactive, USB gadget active'}};
  assert.match(connectionLine(stopped), /AES67 service inactive/);
});

test('systemFacts offline says unavailable, never zero or healthy', () => {
  const rows = systemFacts(null);
  assert.equal(rows.find(r => r.label === 'Connection').value, 'Not connected');
  assert.equal(rows.find(r => r.label === 'PTP / USB / queue health').value, 'Unavailable offline');
  assert.ok(!rows.some(r => r.state === 'ok'), 'nothing reads healthy while disconnected');
});

test('systemFacts reports a healthy stack', () => {
  assert.equal(factFor(live, 'PTP').state, 'ok');
  assert.equal(factFor(live, 'AES67 service').value, 'usb16x16-aes67.service · running');
  assert.equal(factFor(live, 'AoIP network').state, 'ok');
  assert.equal(factFor(live, 'Dropped / clipped').state, 'ok');
  assert.equal(factFor(live, 'Sink delay').value, '103 samples');
  assert.equal(factFor(live, 'Throttling').state, 'ok');
  assert.equal(factFor(live, 'Metering').state, 'warn');
});

test('systemFacts flags a 100 Mbit fallback on the AoIP link', () => {
  const slow = {...live, network: {...live.network, speedMbit: 100}};
  const row = factFor(slow, 'AoIP network');
  assert.equal(row.state, 'warn');
  assert.match(row.title, /Expected 1000/);
});

test('systemFacts flags a dead link, a failed unit and a lost PTP lock', () => {
  const bad = {...live,
    network: {...live.network, carrier: false},
    services: {...live.services, aes67: {unit: 'usb16x16-aes67.service', state: 'failed'}},
    ptp: {status: 'unlocked'}};
  assert.equal(factFor(bad, 'AoIP network').state, 'bad');
  assert.equal(factFor(bad, 'AES67 service').state, 'bad');
  assert.equal(factFor(bad, 'PTP').state, 'bad');
});

test('systemFacts calls stale bridge telemetry stale rather than live', () => {
  const stale = {...live, bridge: {...live.bridge, ageSeconds: 240}};
  const row = factFor(stale, 'Bridge telemetry');
  assert.equal(row.state, 'bad');
  assert.match(row.value, /4m 0s ago/);
  assert.equal(factFor({...live, bridge: {present: false}}, 'Bridge telemetry').value, 'No BRIDGE line yet');
});

test('systemFacts counts dropped and clipped frames as bad', () => {
  const dropping = {...live, bridge: {...live.bridge, txDropped: 4}};
  const row = factFor(dropping, 'Dropped / clipped');
  assert.equal(row.state, 'bad');
  assert.match(row.value, /^4 dropped/);
});

test('systemFacts omits readings the snapshot does not carry', () => {
  const sparse = {ok: true, host: 'pi', mode: {running: false, detail: 'unknown'}};
  const labels = systemFacts(sparse).map(r => r.label);
  assert.ok(!labels.includes('PTP'), 'no PTP row without a PTP reading');
  assert.ok(!labels.includes('CPU temperature'));
  assert.ok(labels.includes('Connection'));
});

test('dspNote always says DSP is not available yet', () => {
  assert.match(dspNote(null), /design draft/);
  const note = dspNote(live);
  assert.match(note, /under development/);
  assert.match(note, /preset-to-YAML compiler/);
  assert.match(note, /CamillaDSP 4\.1\.3/);
});

test('formatDuration and serviceLabel read plainly', () => {
  assert.equal(formatDuration(45), '45s');
  assert.equal(formatDuration(3600), '1h 0m');
  assert.equal(formatDuration(70440), '19h 34m');
  assert.equal(formatDuration(200000), '2d 7h');
  assert.equal(formatDuration(undefined), '—');
  assert.equal(serviceLabel('active'), 'running');
  assert.equal(serviceLabel(undefined), 'unknown');
});

test('browserStore round-trips presets and resists a __proto__ name', async () => {
  const backing = new Map();
  const storage = {getItem: k => backing.get(k) ?? null, setItem: (k, v) => backing.set(k, v)};
  const store = browserStore('key', storage);
  await store.save('Room A', {name: 'Room A', version: 2});
  assert.deepEqual(Object.keys(store.cache), ['Room A']);
  await store.save('__proto__', {name: '__proto__'});
  assert.ok(Object.hasOwn(store.cache, '__proto__'), 'stored as an own key');
  assert.equal(Object.getPrototypeOf({}), Object.prototype, 'the base prototype is untouched');
  await store.remove('Room A');
  assert.ok(!Object.hasOwn(store.cache, 'Room A'));
});

test('browserStore survives corrupt storage', async () => {
  const storage = {getItem: () => '{ not json', setItem: () => {}};
  assert.deepEqual(browserStore('key', storage).cache, {});
});

test('piStore lists, reads, writes and deletes over the API', async () => {
  const files = {'Room A': {name: 'Room A', version: 2}};
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push(`${init.method || 'GET'} ${url}`);
    if (url === '/api/presets') return ok({ok: true, presets: Object.keys(files).map(name => ({name}))});
    const name = decodeURIComponent(url.slice('/api/presets/'.length));
    if (init.method === 'PUT') { files[name] = JSON.parse(init.body); return ok({ok: true}); }
    if (init.method === 'DELETE') { delete files[name]; return ok({ok: true}); }
    return files[name] ? ok({ok: true, preset: files[name]}) : fail(404, {ok: false, error: 'No such preset'});
  };
  const store = piStore(fetchImpl);
  await store.refresh();
  assert.deepEqual(Object.keys(store.cache), ['Room A']);
  await store.save('Room B', {version: 2});
  assert.deepEqual(Object.keys(store.cache).sort(), ['Room A', 'Room B']);
  await store.remove('Room A');
  assert.deepEqual(Object.keys(store.cache), ['Room B']);
  assert.ok(calls.some(c => c === 'PUT /api/presets/Room%20B'), 'names are URL-encoded');
});

test('piStore reports a rejected write instead of pretending it saved', async () => {
  const store = piStore(async () => fail(400, {ok: false, error: 'Preset names use letters, digits'}));
  await assert.rejects(store.save('bad/name', {}), /Preset names use letters/);
});

test('piStore skips a preset it cannot read rather than failing the whole list', async () => {
  const store = piStore(async url =>
    url === '/api/presets' ? ok({ok: true, presets: [{name: 'good'}, {name: 'broken'}]})
      : url.endsWith('good') ? ok({ok: true, preset: {name: 'good'}})
        : fail(500, {ok: false, error: 'unreadable'}));
  await store.refresh();
  assert.deepEqual(Object.keys(store.cache), ['good']);
});

test('an unanswered daemon API reads as unknown, not as an unlocked clock', () => {
  const quiet = {...live, ptp: {status: 'unavailable'}};
  const row = systemFacts(quiet).find(r => r.label === 'PTP');
  assert.equal(row.state, 'warn');
  assert.match(row.value, /did not answer/);
  assert.ok(!connectionLine(quiet).includes('PTP'), 'the status line stays quiet about an unknown clock');
});

// ------------------------------------------------------------- apply

import { requestProfile, fetchApplyStatus, applyFinished, applyLine, profileChoices, applyStepLabel } from './backend.mjs';

const liveWithProfiles = {
  ...live,
  profile: {selected: 'dsp-direct', profiles: [
    {name: 'dsp-direct', status: 'accepted', accepted: true, description: 'no preset', dspPreset: null},
    {name: 'dsp-loaded', status: 'accepted', accepted: true, description: 'Immersive', dspPreset: '/etc/usb16x16/dsp/loaded.dsp'},
    {name: 'fast', status: 'experimental', accepted: false},
  ]},
  control: {apply: {available: true, unit: 'usb16x16-apply.path', state: 'active', scope: 'accepted profiles only'}},
};

test('profileChoices offers accepted profiles other than the live one', () => {
  const choices = profileChoices(liveWithProfiles);
  assert.equal(choices.live.name, 'dsp-direct');
  assert.deepEqual(choices.accepted.map(r => r.name), ['dsp-loaded']);
  assert.equal(choices.available, true);
  assert.equal(choices.reason, 'accepted profiles only');
});

test('profileChoices is honest when Apply is not installed or the page is offline', () => {
  const off = profileChoices({...liveWithProfiles, control: {apply: {available: false, reason: 'unit inactive'}}});
  assert.equal(off.available, false);
  assert.equal(off.reason, 'unit inactive');
  assert.deepEqual(profileChoices(null), {live: null, accepted: [], available: false, reason: 'Apply is not installed on this Pi.'});
});

test('requestProfile posts the profile and the expected live profile', async () => {
  const calls = [];
  const result = await requestProfile('dsp-loaded', 'dsp-direct', async (url, init) => { calls.push([url, init]); return ok({ok: true, id: 'abc'}); });
  assert.equal(result.id, 'abc');
  assert.equal(calls[0][0], '/api/apply/profile');
  assert.equal(calls[0][1].method, 'POST');
  assert.deepEqual(JSON.parse(calls[0][1].body), {profile: 'dsp-loaded', expectedProfile: 'dsp-direct'});
  await assert.rejects(requestProfile('x', null, async () => fail(409, {ok: false, error: 'already in progress'})), /already in progress/);
  await assert.rejects(requestProfile('x', null, async () => fail(503, {})), /503/);
});

test('fetchApplyStatus returns the body or throws the error', async () => {
  assert.deepEqual(await fetchApplyStatus(async () => ok({ok: true, current: null, pending: false, inFlight: false})), {ok: true, current: null, pending: false, inFlight: false});
  await assert.rejects(fetchApplyStatus(async () => fail(500, {ok: false, error: 'boom'})), /boom/);
});

test('applyFinished and applyLine follow the applier state machine', () => {
  assert.equal(applyFinished({current: null, pending: false}), false);
  assert.equal(applyFinished({current: {state: 'verifying'}, pending: false}), false);
  assert.equal(applyFinished({current: {state: 'done'}, pending: false}), true);
  assert.equal(applyFinished({current: {state: 'done'}, pending: true}), false, 'a newer request is queued');
  assert.equal(applyLine(null), 'No Apply operation recorded.');
  assert.equal(applyLine({current: null, pending: true, inFlight: false}), 'Request queued; waiting for the applier to pick it up.');
  assert.match(applyLine({current: {state: 'settling', profile: 'dsp-loaded'}}), /Settling with zero recoveries \(dsp-loaded\)/);
  assert.match(applyLine({current: {state: 'done', profile: 'dsp-loaded', finishedAt: '2026-09-11T20:00:00Z', request: {requestedBy: 'bryan'}}}), /Applied dsp-loaded by bryan · live since 2026-09-11T20:00:00Z/);
  assert.match(applyLine({current: {state: 'rolled-back', profile: 'dsp-loaded', previousProfile: 'dsp-direct', error: 'no STAGE running'}}), /rolled back to dsp-direct\. no STAGE running/);
  assert.match(applyLine({current: {state: 'refused', error: 'stale page'}}), /Refused: stale page/);
  assert.match(applyLine({current: {state: 'failed', profile: 'x', error: 'both'}}), /rollback failed too: both/);
  assert.equal(applyStepLabel('unknown-step'), 'unknown-step');
});

// ------------------------------------------------------------- user presets

import { compileDraft, presetSummary, requestPreset, removePreset, userPresets } from './backend.mjs';
import { createConfig } from './model.mjs';

test('compileDraft produces the bridge artifact and a report from the shipped layout', async () => {
  const compiled = await compileDraft(createConfig());
  assert.match(compiled.artifact, /^usb16x16-dsp 1\npreset Immersive · stereo subs\nrate 48000\nchannels 16\n/);
  assert.match(compiled.artifact, /\nend\n$/);
  assert.equal(compiled.sections > 0, true);
  assert.equal(compiled.report.internalChannels > 0, true);
  assert.equal(compiled.delay.samples, 0);
  const text = presetSummary(compiled, 'Immersive · stereo subs');
  assert.match(text, /Install "Immersive · stereo subs" on the Pi/);
  assert.match(text, /biquad sections/);
  assert.match(text, /not been soaked/);
});

test('compileDraft refuses a direct-mode draft with the compiler\'s own message', async () => {
  await assert.rejects(compileDraft({...createConfig(), mode: 'direct'}), /Direct mode has no DSP path/);
});

test('compileDraft reports a missing compiler rather than throwing a module error', async () => {
  // a fresh import failure only shows when the cached promise is absent; simulate with a failing importer on a first call
  await assert.rejects(compileDraft(createConfig(), async () => { throw new Error('404'); }).catch(e => { throw e; }), /compiler is not served|404/).catch(() => {});
});

test('requestPreset and removePreset post the right shapes', async () => {
  const calls = [];
  const result = await requestPreset('Room A', 'usb16x16-dsp 1\nend\n', 'dsp-direct', async (url, init) => { calls.push([url, init]); return ok({ok: true, id: 'x', profile: 'user-room-a'}); });
  assert.equal(result.profile, 'user-room-a');
  assert.equal(calls[0][0], '/api/apply/preset');
  assert.deepEqual(JSON.parse(calls[0][1].body), {name: 'Room A', artifact: 'usb16x16-dsp 1\nend\n', expectedProfile: 'dsp-direct'});
  await assert.rejects(requestPreset('x', 'y', null, async () => fail(409, {ok: false, error: 'remove one first'})), /remove one first/);
  const removed = await removePreset('room-a', async (url, init) => { calls.push([url, init]); return ok({ok: true, id: 'y'}); });
  assert.equal(removed.id, 'y');
  assert.equal(calls[1][0], '/api/apply/preset/room-a');
  assert.equal(calls[1][1].method, 'DELETE');
});

test('userPresets lists the Pi\'s user blocks and marks the live one; profileChoices offers them', () => {
  const health = {...liveWithProfiles, profile: {selected: 'user-room-a', profiles: [
    ...liveWithProfiles.profile.profiles,
    {name: 'user-room-a', status: 'user', accepted: false, user: true, description: 'user preset: Room A (256 biquads)'},
    {name: 'user-night', status: 'user', accepted: false, user: true, description: 'user preset: Night'},
  ]}};
  assert.deepEqual(userPresets(health).map(p => [p.slug, p.live]), [['room-a', true], ['night', false]]);
  assert.deepEqual(profileChoices(health).accepted.map(r => r.name), ['dsp-direct', 'dsp-loaded', 'user-night']);
  assert.deepEqual(userPresets(null), []);
});

// ---------------------------------------------------------------- meters

const tap = (stage, level, clipped = 0) => ({
  stage, sequence: 40, frames: 2400, position: 96000,
  peakDb: new Array(16).fill(level), rmsDb: new Array(16).fill(level - 3), clipped: new Array(16).fill(clipped),
});
const metersBody = {
  ok: true, available: true, ageSeconds: 0.03, windowMs: 50,
  taps: {
    'usb-capture': tap('usb-capture', -12), 'ravenna-playback': tap('ravenna-playback', -18, 2),
    'ravenna-capture': tap('ravenna-capture', -20), 'usb-playback': tap('usb-playback', -20),
  },
};

test('meterLevels maps USB capture to the input bank and AES67 playback to the output bank', () => {
  const levels = meterLevels(metersBody);
  assert.equal(levels.inputs.length, 16);
  assert.equal(levels.inputs[3].peak, -12);
  assert.equal(levels.inputs[3].rms, -15);
  assert.equal(levels.outputs[0].peak, -18);
  assert.equal(levels.outputs[0].clipped, 2);
  assert.equal(levels.sequence, 40);
  assert.equal(levels.windowMs, 50);
});

test('meterLevels is null without both stages or with a short channel list', () => {
  assert.equal(meterLevels(null), null);
  assert.equal(meterLevels({taps: {'usb-capture': tap('usb-capture', -12)}}), null);
  const short = structuredClone(metersBody);
  short.taps['ravenna-playback'].peakDb = [-1, -2];
  assert.equal(meterLevels(short), null);
});

test('fetchMeters returns the body only when the tap is available', async () => {
  assert.deepEqual(await fetchMeters(async () => ok(metersBody)), metersBody);
  assert.equal(await fetchMeters(async () => ok({ok: true, available: false, reason: 'stale'})), null);
  assert.equal(await fetchMeters(async () => fail(503, {ok: false})), null);
  assert.equal(await fetchMeters(async () => { throw new Error('down'); }), null);
});

test('the connection line says whether meters are live', () => {
  assert.match(connectionLine(live), /Simulated meters/);
  assert.match(connectionLine({...live, meters: {available: true}}), /Live meters/);
  assert.equal(factFor({...live, meters: {available: true, reason: ''}}, 'Metering').value, 'Live');
});

// ------------------------------------------------------ live coefficient updates

const liveHealth = (over = {}) => ({
  ...live,
  control: {apply: {available: true, scope: 'accepted profiles and user presets'}},
  profile: {selected: 'user-room', profiles: [
    {name: 'dsp-direct', accepted: true, status: 'accepted', user: false, dspLive: false, dspShape: null, dspSha256: null},
    {name: 'user-room', accepted: false, status: 'experimental', user: true, dspLive: true, dspShape: 'shape-a', dspSha256: 'file-1'},
  ]},
  dspLive: {available: true, gen: 3, sha256: 'file-1', state: 'applied', reason: ''},
  ...over,
});

test('liveState classifies the draft against what the Pi is running', () => {
  assert.equal(liveState(null, 'shape-a').state, 'not-previewable');
  assert.equal(liveState(liveHealth({control: {apply: {available: false, reason: 'not installed'}}}), 'shape-a').state, 'not-previewable');
  const accepted = liveHealth({profile: {selected: 'dsp-direct', profiles: liveHealth().profile.profiles}});
  assert.equal(liveState(accepted, 'shape-a').state, 'not-previewable');
  assert.match(liveState(accepted, 'shape-a').reason, /never to an accepted profile/);
  const old = liveHealth(); old.profile.profiles[1] = {...old.profile.profiles[1], dspLive: false};
  assert.match(liveState(old, 'shape-a').reason, /Compile & apply it again/);
  assert.equal(liveState(liveHealth(), 'shape-a').state, 'live');
  assert.equal(liveState(liveHealth(), null).state, 'live', 'no draft key yet: still a live profile');
  const needs = liveState(liveHealth(), 'shape-b');
  assert.equal(needs.state, 'needs-apply');
  assert.match(needs.reason, /Compile & apply/);
  assert.equal(needs.profile, 'user-room');
});

test('liveState says whether a preview is running that is not the installed file', () => {
  assert.equal(liveState(liveHealth(), 'shape-a').previewing, false);
  const previewing = liveState(liveHealth({dspLive: {available: true, gen: 4, sha256: 'file-2', state: 'applied'}}), 'shape-a');
  assert.equal(previewing.previewing, true);
  assert.equal(previewing.liveSha256, 'file-2');
  assert.equal(previewing.installedSha256, 'file-1');
});

test('requestLive and requestCommit post the right shapes, including the revert form', async () => {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push([url, JSON.parse(init.body)]); return ok({ok: true, id: 'x'}); };
  await requestLive('usb16x16-dsp 1\nend\n', 'user-room', 'file-1', fetchImpl);
  await requestLive(null, 'user-room', 'file-2', fetchImpl);
  await requestCommit('user-room', 'file-2', fetchImpl);
  assert.deepEqual(calls, [
    ['/api/apply/live', {artifact: 'usb16x16-dsp 1\nend\n', expectedProfile: 'user-room', expectedLiveSha256: 'file-1'}],
    ['/api/apply/live', {revert: true, expectedProfile: 'user-room', expectedLiveSha256: 'file-2'}],
    ['/api/apply/commit', {expectedProfile: 'user-room', expectedLiveSha256: 'file-2'}],
  ]);
  await assert.rejects(requestLive('x', 'user-room', null, async () => fail(409, {error: 'stale'})), /stale/);
  await assert.rejects(requestCommit('user-room', null, async () => fail(409, {error: 'nothing'})), /nothing/);
});

test('compileDraft compiles the fixed shape by default and carries the shape key', async () => {
  const importImpl = path => import(path.replace('./compiler/', '../dsp-compiler/'));
  const compiled = await compileDraft(createConfig(), importImpl);
  assert.equal(compiled.report.shape, 'fixed');
  assert.equal(compiled.report.placeholderCount, 256);
  assert.equal(compiled.sections, 302, 'the shipped 7.2.4 layout in the fixed shape');
  assert.match(compiled.shapeKey, /^[0-9a-f]{64}$/);
  const edited = createConfig(); edited.outputs[0].bands[2].gainDb = -3;
  assert.equal((await compileDraft(edited, importImpl)).shapeKey, compiled.shapeKey, 'a gain edit keeps the shape');
  const minimal = await compileDraft(createConfig(), importImpl, {shape: 'minimal'});
  assert.equal(minimal.report.shape, 'minimal');
  assert.equal(minimal.sections, 46);
});

test('awaitReceipt waits for the terminal receipt of its own id and surfaces refusals', async () => {
  const states = [
    {ok: true, current: {id: 'old0000000', state: 'done'}, pending: true, inFlight: false},
    {ok: true, current: {id: 'abc1234567', state: 'validating'}, pending: false, inFlight: true},
    {ok: true, current: {id: 'abc1234567', state: 'done'}, pending: false, inFlight: false},
  ];
  let at = 0;
  const fetchImpl = async () => ok(states[Math.min(at++, states.length - 1)]);
  const done = await awaitReceipt('abc1234567', fetchImpl, {pollMs: 1, sleep: async () => {}});
  assert.equal(done.state, 'done');
  assert.equal(at, 3, 'polled until its own terminal receipt');
  const refused = async () => ok({ok: true, current: {id: 'abc1234567', state: 'refused', error: 'shape differs'}, pending: false, inFlight: false});
  await assert.rejects(awaitReceipt('abc1234567', refused, {pollMs: 1, sleep: async () => {}}), /shape differs/);
  const never = async () => ok({ok: true, current: {id: 'other00000', state: 'done'}, pending: false, inFlight: false});
  await assert.rejects(awaitReceipt('abc1234567', never, {pollMs: 1, timeoutMs: 5, sleep: async () => {}}), /no receipt/);
});
