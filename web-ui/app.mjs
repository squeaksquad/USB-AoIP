// The page: Status, Control Room, Processor, System (docs/web/REDESIGN-2026-11.md,
// phases 1 to 3).
// This file owns the state, the events and everything that talks to the
// device. The tabs are drawn by the view-*.mjs modules, which are pure
// (state in, HTML out); the testable logic is in the modules beside them.
import { CHANNELS, createConfig, validateConfig, parsePreset, setOutputRole, bandResponse, eqResponse } from './model.mjs';
import { LAYOUTS, applyLayout, swapOutputs, applyCrossover, dragEqBand, EQ_RANGE_DB, blankConfig } from './workflows.mjs';
import { resetBand } from './reset-band.mjs';
import { getBus, applyBusLayout, setBusGainMute, setHeadphoneMode, setHeadphonePair, setHeadphoneMatrix, createHeadphoneBus, removeBus, setBusEqLink, setBusOutputs, speakerGroupSourceIds } from './buses.mjs';
import { resetEq, setEqBypass, mirrorLinkedEq, exportEq, importEq } from './eq-tools.mjs';
import { polarityNote } from './crossover-notes.mjs';
import { readHealth, onAccessProblem, pageNotices, pillState, meterAbsence, deviceModeLabel, formatRate, deviceName, fetchLogs, systemFacts, browserStore, piStore, POLL_MS, requestProfile, fetchApplyStatus, applyFinished, applyLine, applyStepLabel, profileChoices, APPLY_POLL_MS, compileDraft, compileOtherRates, runningRate, presetSummary, requestPreset, removePreset, userPresets, fetchMeters, METER_POLL_MS, liveState, requestLive, requestCommit, awaitReceipt, requestShutdown, requestReboot, requestRestartAudio, requestRestartClock, requestBundle, requestPassword, fetchSupportBundle, stackTerms, statusCards, meterRows, fetchMonitor, postMonitor, requestMonitorLimits, requestMonitorReference } from './backend.mjs';
import { confirmDialog, passwordProblem, actionNote, bundlePath, BUNDLE_FILE } from './actions.mjs';
import { reduceMonitor, Overlay, patchKeys, monitorValues, MonitorSender, setPatch, patchKey, soloPress, mutePress, setLabels, controlRoom, safetyNotes, clampLevel, clampTrim, clampMax,
  monitorOffered, monitorKind, readGroups, saveGroups, addGroup, removeGroup, peakText, dbWords, MONITOR_POLL_MS, DRAG_DB_PER_PX, KEY_STEP_DB, BUTTON_STEP_DB, TRIM_STEP_DB } from './monitor.mjs';
import { controlRoomView } from './view-control.mjs';
import { LiveQueue } from './live.mjs';
import { History } from './history.mjs';
import { delaysFromDistances, parseDistance } from './align.mjs';
import { MeterHold, levelPercent, FLOOR_DB } from './meter-hold.mjs';
import { countChanges, changeBar } from './changes.mjs';
import { readPrefs, savePrefs } from './prefs.mjs';
import { presetSlug, storeName, nameProblem, presetRows } from './presets.mjs';
import { esc, parseNumber, parseSend, msText } from './ui.mjs';
import { statusView } from './view-status.mjs';
import { outputsView, eqView, BAND_COLORS } from './view-outputs.mjs';
import { routingView, crosspoint } from './view-routing.mjs';
import { setsView } from './view-sets.mjs';
import { bassView } from './view-bass.mjs';
import { chooserView } from './view-chooser.mjs';
import { systemView, devicePanel, actionsPanel, presetsPanel, lastChangePanel, safetyPanel } from './view-system.mjs';

// ------------------------------------------------------------------ state

/** Phase 1 runs on today's engine: the processing is on what the computer
 *  sends, and a preset is always a processing preset. Older presets may say
 *  otherwise; the page has no control for either field any more. */
const normalise = doc => {
  doc.mode = 'dsp'; doc.source = 'usb';
  // One spelling of a preset's name everywhere: the one the preset store keeps.
  doc.name = storeName(doc.name) || 'Preset';
  return doc;
};

let config = normalise(createConfig());
// What the draft is compared with: the preset as last loaded, saved, applied or kept.
let baseline = structuredClone(config);
// A new preset that was never saved or applied.
let fresh = false;
// The saved preset the draft was opened from or last saved as; null for the built-in example and a new one.
let draftStoreName = null;
const history = new History();
let tab = 'status', ptab = 'outputs';
let eqOpen = null, band = 0, eqDrag = null, eqObserver = null, eqClipboard = null, eqImport = null, nudgeKey = null;
let align = {open: false, unit: 'm', text: [], preview: null, error: '', note: ''};
let confirmResetAll = false, setDetail = null, chooser = null, exportState = null;
let route = {row: null, col: null};
let prefs = readPrefs();
let logService = 'all', logQuery = '', logBusy = false;
const logLive = {all: '', stack: '', usb: ''};
// Live state from the device's control service; null whenever none answers.
let health = null;
// A sign-in problem (401, 403, 429) seen on the last health read or request; null otherwise.
let access = null;
// The engine's meter taps: the last window, when it was read, and a hold per row.
let meterBody = null, meterAt = 0, meterBusy = false, meterShown = null;
const holds = {computer: new MeterHold(), 'to-network': new MeterHold(), 'from-network': new MeterHold()};
// A change to the device in progress: the last status seen and the poll that follows it.
let applyStatus = null, applyBusy = false, applyPoll = null, shutdownRequested = false;
// A reboot asked for from here: the page says so until the device answers again.
let rebootRequested = false;
// What the Actions panel says when the page knows more than the receipt (the
// bundle downloaded, the password taken); null to read the receipt.
let actionLocal = null;
// Callers waiting for the receipt the apply polling is following.
let applyWaiters = [];
// Live edits: the draft's shape key from its last compile, what the engine
// last took from this page, and the debounced one-in-flight queue.
let draftShapeKey = null, liveLastSent = null, liveLine = '';
// Foreign numbers the page has already answered once: another author (a
// second tab) may keep the engine on something else, and the page re-sends
// its draft once per such state, never in a loop.
let liveAnsweredForeign = null;
// The self-heal must not act on one stale health poll: a disagreement has to
// be seen on two polls running with the same hash, and never within a few
// seconds of the page's own last receipt (health lags the engine by a poll).
let liveForeignSeen = {sha: null, polls: 0}, liveLastReceiptAt = 0, liveRetryTimer = null;
// Whether the user has touched the draft since the page loaded: an untouched
// draft follows the running preset's saved settings.
let editedSinceLoad = false;

// The Control Room (phase 3): the device's monitor as last read, the page's
// own values ahead of the owner's, the sender for knob moves, and what is
// open on the tab. None of it is part of the draft, a preset or undo.
let monitor = null, monitorReading = false, crModel = null;
const overlay = new Overlay();
let crKeys = false, crRefOpen = {}, crGroups = readGroups(), crGroupEdit = null, knobDrag = null;
// What the Level safety panel says after its last request; null for nothing.
let safetyNote = null;
const sender = new MonitorSender({
  post: postMonitor,
  onSent: (body, result) => overlay.sent(body, result.seq, Date.now()),
  onError: (body, error) => { overlay.failed(body); toast(`The change did not reach the device: ${error.message}`); renderControl(); },
});

const storageKey = 'usb16x16-design-presets-v1';
let presetStore = browserStore(storageKey);
const $ = selector => document.querySelector(selector);
const terms = () => stackTerms(health);
const clone = value => structuredClone(value);
const changes = () => countChanges(baseline, config);
/** Where presets are kept right now, in words. */
const where = () => presetStore.kind === 'pi' ? 'on the device' : 'in this browser';

let toastTimer;
function toast(message) { const node = $('#toast'); node.textContent = message; node.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => node.classList.remove('show'), 5000); }

const liveQueue = new LiveQueue({
  send: async ({artifact, sha256, expectedProfile, expectedLiveSha256}) => {
    const result = await requestLive(artifact, expectedProfile, expectedLiveSha256);
    liveLastSent = sha256;
    // The applier is one process per request and the service refuses a new
    // one while the previous is pending: wait for this receipt first.
    await awaitReceipt(result.id, undefined, {timeoutMs: 15000});
    liveLastReceiptAt = Date.now();
    return result;
  },
  onSettled: outcome => {
    liveLine = outcome.ok ? '' : `The last change did not reach the device: ${outcome.error.message}`;
    if (!outcome.ok) {
      toast(liveLine);
      // A stale expectation (the engine moved under us): forget what we last
      // sent so the next edit, or the self-heal, carries the engine's hash.
      if (/expected live coefficients/.test(outcome.error.message)) {
        liveLastSent = null;
        clearTimeout(liveRetryTimer);
        liveRetryTimer = setTimeout(() => { liveRetryTimer = null; if (!liveQueue.busy) scheduleLive(); }, 1300);
      }
    }
    renderBar();
    if (outcome.ok) startApplyPolling();
  },
});

// ------------------------------------------------------- draft and device

/** liveState's answer, narrowed: live edits go only to the running preset
 *  that this draft is. A draft under another name is a different preset,
 *  and editing it must not change what the device plays. */
function gate(state) {
  if (!state || !['live', 'needs-apply'].includes(state.state) || !state.profile) return state;
  if (presetSlug(config.name) === state.profile.replace(/^(user|dante)-/, '')) return state;
  return {...state, state: 'not-previewable', previewing: false, reason: `The device runs ${state.profile}; this preset is ${config.name}.`};
}
const effectiveLive = () => health ? gate(liveState(health, draftShapeKey)) : null;

/** Every edit: compile in the fixed shape and, when the running preset has
 *  the same shape, hand the numbers to the engine through the queue. */
async function scheduleLive() {
  if (!health) return;
  if (gate(liveState(health, null)).state !== 'live') { liveQueue.cancel(); return; }
  let compiled;
  // At the rate the engine runs: an artifact for another rate is refused by it.
  try { validateConfig(config); compiled = await compileDraft(config, undefined, {rate: runningRate(health)}); }
  catch (e) { liveLine = `Not sent to the device: ${e.message}`; renderBar(); return; }
  draftShapeKey = compiled.shapeKey;
  const state = effectiveLive();
  renderBar();
  if (state.state !== 'live') { liveQueue.cancel(); return; }
  const sha256 = compiled.sha256;
  if (sha256 === (liveLastSent || state.liveSha256)) return;
  liveQueue.submit({artifact: compiled.artifact, sha256, expectedProfile: state.profile, expectedLiveSha256: liveLastSent || state.liveSha256});
}

function markDraft() { editedSinceLoad = true; liveAnsweredForeign = null; scheduleLive(); }

/**
 * One change to the draft. `change` edits the draft in place or returns a new
 * one. A draft the model refuses is put back and the reason shown; a change
 * that changed nothing is not a step. Returns whether the draft changed.
 */
function edit(change) {
  const before = clone(config);
  try { const next = change(config); if (next) config = next; normalise(config); validateConfig(config); }
  catch (e) { config = before; toast(e.message); requestRender(); return false; }
  if (JSON.stringify(before) === JSON.stringify(config)) { requestRender(); return false; }
  history.record(before); nudgeKey = null;
  markDraft(); requestRender();
  return true;
}

/** Put a whole preset in the editor: loaded, new, or discarded back to. */
function adopt(document, {asBaseline = true, isFresh = false, from = null} = {}) {
  config = normalise(document);
  draftStoreName = from;
  if (asBaseline) baseline = clone(config);
  fresh = isFresh; history.clear(); draftShapeKey = null; liveQueue.cancel();
  eqOpen = null; band = 0; eqImport = null; chooser = null; setDetail = null; route = {row: null, col: null};
  align = {...align, open: false, text: [], preview: null, error: '', note: ''};
}

function jump(state) {
  if (!state) return;
  config = state;
  if (eqOpen !== null && config.outputs[eqOpen].busId === null) eqOpen = null;
  if (setDetail && !config.buses.some(bus => bus.id === setDetail)) setDetail = null;
  nudgeKey = null; markDraft(); render();
}
const undo = () => jump(history.undo(clone(config)));
const redo = () => jump(history.redo(clone(config)));

/** The saved settings that belong to the running preset, if the store has them. */
function presetForLiveProfile(next) {
  const live = profileChoices(next).live;
  if (!live?.user) return null;
  const slug = live.name.replace(/^(user|dante)-/, '');
  const entry = Object.entries(presetStore.cache || {}).find(([name]) => presetSlug(name) === slug);
  return entry ? {name: entry[0], document: entry[1]} : null;
}

/** On connecting, an untouched draft becomes the running preset's saved
 *  settings, so the page shows what the device runs. */
function followLivePreset(next) {
  if (editedSinceLoad) return;
  const found = presetForLiveProfile(next);
  if (!found) return;
  try { adopt(validateConfig(parsePreset(JSON.stringify(found.document))), {from: found.name}); render(); }
  catch (e) { toast(`The saved settings of ${found.name} could not be opened: ${e.message}`); }
}

/** Keep the settings in the store in step with what was applied or kept,
 *  under the draft's name, so a reload finds them. */
async function saveDraft() {
  const name = storeName(config.name) || 'preset';
  try { validateConfig(config); await presetStore.save(name, clone(config)); baseline = clone(config); fresh = false; draftStoreName = name; return true; }
  catch (e) { toast(`Could not save the preset's settings: ${e.message}`); return false; }
}

// ------------------------------------------------------------- questions

/** One dialog for every question the page asks. Resolves to the typed text
 *  (or true) on yes, null on no. */
function ask({title, text = '', input = null, ok = 'OK', danger = false, validate = null}) {
  return new Promise(resolve => {
    const dialog = $('#ask');
    dialog.innerHTML = `<form method="dialog" class="ask"><strong class="title">${esc(title)}</strong><p class="ask-text">${esc(text)}</p>
      ${input === null ? '' : `<input type="text" id="ask-input" value="${esc(input)}" maxlength="64" aria-label="${esc(title)}">`}
      <span class="warn-text" role="alert" id="ask-error"></span>
      <div class="toolbar"><button type="submit" value="ok" class="${danger ? 'danger' : 'primary'}">${esc(ok)}</button><button type="submit" value="cancel" formnovalidate>Cancel</button></div></form>`;
    const field = dialog.querySelector('#ask-input'), error = dialog.querySelector('#ask-error');
    // Answered in the submit itself, not on the dialog's close event: a
    // browser delivers that with the next frame, and a page that is not being
    // drawn (a background tab) would wait for it forever.
    let answered = false;
    const answer = value => { if (answered) return; answered = true; if (dialog.open) dialog.close(); resolve(value); };
    dialog.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      if (event.submitter?.value !== 'ok') { answer(null); return; }
      const problem = validate ? validate(field ? field.value : '') : '';
      if (problem) { error.textContent = problem; field?.focus(); return; }
      answer(field ? field.value.trim() : true);
    });
    dialog.addEventListener('cancel', () => answer(null), {once: true});
    dialog.showModal();
    if (field) { field.focus(); field.select(); }
  });
}

/** The new page password, typed twice. Resolves to it, or null on cancel.
 *  The fields are emptied whatever the answer, and the dialog with them. */
function askPassword({title, text, ok}) {
  return new Promise(resolve => {
    const dialog = $('#ask');
    dialog.innerHTML = `<form method="dialog" class="ask"><strong class="title">${esc(title)}</strong><p class="ask-text">${esc(text)}</p>
      <div class="pw-fields"><label class="stack">New password, at least 8 characters<input type="password" id="pw-1" autocomplete="new-password" maxlength="256"></label>
      <label class="stack">New password again<input type="password" id="pw-2" autocomplete="new-password" maxlength="256"></label></div>
      <span class="warn-text" role="alert" id="ask-error"></span>
      <div class="toolbar"><button type="submit" value="ok" class="primary">${esc(ok)}</button><button type="submit" value="cancel" formnovalidate>Cancel</button></div></form>`;
    const first = dialog.querySelector('#pw-1'), second = dialog.querySelector('#pw-2'), error = dialog.querySelector('#ask-error');
    // Answered in the submit itself, never on the dialog's close event (see ask).
    let answered = false;
    const answer = value => {
      if (answered) return; answered = true;
      first.value = ''; second.value = '';
      if (dialog.open) dialog.close();
      dialog.innerHTML = '';
      resolve(value);
    };
    dialog.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      if (event.submitter?.value !== 'ok') { answer(null); return; }
      const problem = passwordProblem(first.value, second.value);
      if (problem) { error.textContent = problem; (problem.includes('match') ? second : first).focus(); return; }
      answer(first.value);
    });
    dialog.addEventListener('cancel', () => answer(null), {once: true});
    dialog.showModal();
    first.focus();
  });
}

/** Hand the browser a file to save: an object URL on a temporary link, revoked after. */
function saveBlob(name, blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a'); a.href = url; a.download = name; a.hidden = true;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const download = (name, text, type = 'application/json') => saveBlob(name, new Blob([text], {type}));

// ------------------------------------------------------- changes to the device

const liveProfile = () => profileChoices(health).live?.name || null;
const outageWords = () => { const text = terms().outage; return text.charAt(0).toUpperCase() + text.slice(1); };
function began() { applyStatus = {current: null, pending: true, inFlight: false}; startApplyPolling(); }

/** Install the draft on the device under a name and restart audio on it. */
async function applyDraft({saveAs = false} = {}) {
  const taken = Object.keys(presetStore.cache || {});
  const own = !saveAs && !fresh ? storeName(config.name) : null;
  const name = await ask({title: saveAs ? 'Save as a new preset' : 'Apply and restart audio',
    text: `The preset is installed on the device under this name and audio restarts on it: ${terms().outage}. Stop playback first.`,
    input: saveAs ? `${storeName(config.name)} copy`.slice(0, 64) : storeName(config.name), ok: 'Continue',
    validate: value => nameProblem(value, taken, own)});
  if (name === null) return;
  const previous = config.name;
  config.name = name;
  let compiled;
  try { validateConfig(config); compiled = await compileDraft(config); }
  catch (e) { config.name = previous; toast(`This preset cannot be built: ${e.message}`); return; }
  if (!await ask({title: 'Ready to apply', text: presetSummary(compiled, name, health), ok: 'Apply and restart audio'})) { config.name = previous; render(); return; }
  applyBusy = true; renderLive();
  try {
    // The Dante engine keeps one file per sample rate; the AES67 bridge runs 48 kHz only.
    const others = health?.stack === 'dante' ? await compileOtherRates(config) : null;
    const result = await requestPreset(config.name, compiled.artifact, liveProfile(), undefined, others);
    toast(`${result.replacing ? 'Replacing' : 'Installing'} ${name}. ${result.note || ''}`);
    await saveDraft();
    began();
  } catch (e) { config.name = previous; toast(`The device refused the preset: ${e.message}`); }
  applyBusy = false;
  render();
}

/** Keep changes: what the engine is playing becomes the saved preset. No restart. */
async function keepLive() {
  const state = effectiveLive();
  if (!state?.previewing) {
    // Nothing is playing that is not saved (the edits cancelled out, or never
    // left the page): the draft is the preset again.
    await saveDraft(); render(); return;
  }
  // On Dante the other rates' files are rewritten from this draft, so the
  // draft must be what the engine applied.
  let others = null;
  if (health?.stack === 'dante') {
    try {
      validateConfig(config);
      const rate = runningRate(health);
      if ((await compileDraft(config, undefined, {rate})).sha256 !== state.liveSha256) { toast('The last change is still on its way to the device. Try again in a moment.'); return; }
      others = await compileOtherRates(config, undefined, {except: rate});
    } catch (e) { toast(`This preset cannot be built at the other sample rates: ${e.message}`); return; }
  }
  applyBusy = true; renderLive();
  try {
    const result = await requestCommit(state.profile, state.liveSha256, undefined, others);
    applyStatus = {current: null, pending: true, inFlight: false};
    await awaitReceipt(result.id);
    await saveDraft();
    toast('Changes kept: they are now part of the preset.');
    pollHealth();
  } catch (e) { toast(`The changes could not be kept: ${e.message}`); }
  applyBusy = false;
  render();
}

/** Discard: the draft goes back to the preset, and so does the engine. */
async function discardChanges() {
  const state = effectiveLive();
  const before = clone(config);
  config = clone(baseline);
  if (JSON.stringify(before) !== JSON.stringify(config)) history.record(before);
  draftShapeKey = null; liveQueue.cancel();
  if (state?.previewing) {
    applyBusy = true; render();
    try { await requestLive(null, state.profile, state.liveSha256); liveLastSent = state.installedSha256; began(); }
    catch (e) { toast(`The device did not go back to the saved preset: ${e.message}`); }
    applyBusy = false;
  }
  render();
}

async function saveOnly() {
  const taken = Object.keys(presetStore.cache || {});
  if (nameProblem(storeName(config.name), taken, fresh ? null : storeName(config.name))) {
    const name = await ask({title: 'Save preset', text: `Saved ${where()}.`, input: storeName(config.name), ok: 'Save', validate: value => nameProblem(value, taken)});
    if (name === null) return;
    config.name = name;
  }
  if (await saveDraft()) toast(`Saved ${where()}.`);
  render();
}

async function runPreset(kind, name) {
  const prefix = terms().presetPrefix;
  const row = kind === 'preset' ? rowsNow().presets.find(p => p.name === name) : null;
  const target = kind === 'profile' ? name : `${prefix}${row?.slug}`;
  if (kind === 'preset' && !row) return;
  const title = kind === 'profile' && name === 'direct' ? 'Run without processing?' : `Run ${name}`;
  let compiled = null, document = null;
  if (row && !row.installed) {
    try { document = normalise(parsePreset(JSON.stringify(presetStore.cache[name]))); compiled = await compileDraft(document); }
    catch (e) { toast(`${name} cannot be built: ${e.message}`); return; }
  }
  const text = compiled ? presetSummary(compiled, name, health)
    : `${outageWords()}. If the device does not come up clean it goes back to ${liveProfile() || 'what it ran before'} by itself. Stop playback first.`;
  if (!await ask({title, text, ok: 'Run it and restart audio'})) return;
  applyBusy = true; renderLive();
  try {
    if (compiled) {
      const others = health?.stack === 'dante' ? await compileOtherRates(document) : null;
      await requestPreset(name, compiled.artifact, liveProfile(), undefined, others);
    } else await requestProfile(target, liveProfile());
    // With nothing unsaved in the editor, show what is about to run.
    if (row?.stored && !changes() && !fresh) { try { adopt(validateConfig(parsePreset(JSON.stringify(presetStore.cache[name]))), {from: name}); } catch { /* the list still runs it */ } }
    began();
  } catch (e) { toast(`The device refused: ${e.message}`); }
  applyBusy = false;
  render();
}

async function openPreset(name) {
  if ((changes() || fresh) && !await ask({title: `Open ${name}?`, text: 'The preset you are editing has unsaved changes. Opening another leaves them behind.', ok: 'Open'})) return;
  try { adopt(validateConfig(parsePreset(JSON.stringify(presetStore.cache[name]))), {from: name}); editedSinceLoad = true; tab = 'processor'; ptab = 'outputs'; render(); }
  catch (e) { toast(`${name} could not be opened: ${e.message}`); }
}

/** Wait for the applier to finish one request, so the next is not refused as busy. */
async function removeInstalled(slug) {
  const result = await removePreset(slug);
  if (result?.id) await awaitReceipt(result.id, undefined, {timeoutMs: 15000}).catch(() => {});
}

async function renamePreset(name) {
  const taken = Object.keys(presetStore.cache || {});
  const next = await ask({title: `Rename ${name}`, text: 'On the device the preset is installed again under the new name the next time it is run.', input: name, ok: 'Rename', validate: value => value.trim() === name ? '' : nameProblem(value, taken, name)});
  if (next === null || next === name) return;
  const row = rowsNow().presets.find(p => p.name === name);
  applyBusy = true; renderLive();
  try {
    const document = clone(presetStore.cache[name]); document.name = next;
    await presetStore.save(next, document);
    await presetStore.remove(name);
    if (row?.installed && presetSlug(next) !== row.slug) await removeInstalled(row.slug);
    if (draftStoreName === name) { config.name = next; baseline.name = next; draftStoreName = next; }
    toast(`Renamed to ${next}.`);
  } catch (e) { toast(`Could not rename: ${e.message}`); }
  applyBusy = false;
  pollHealth(); render();
}

async function duplicatePreset(name) {
  const taken = Object.keys(presetStore.cache || {});
  const next = await ask({title: `Duplicate ${name}`, text: 'The copy is saved; it is installed on the device when it is first run.', input: `${name} copy`.slice(0, 64), ok: 'Duplicate', validate: value => nameProblem(value, taken)});
  if (next === null) return;
  try { const document = clone(presetStore.cache[name]); document.name = next; await presetStore.save(next, document); toast(`${next} saved.`); }
  catch (e) { toast(`Could not duplicate: ${e.message}`); }
  render();
}

async function removeListed(name) {
  const row = rowsNow().presets.find(p => p.name === name);
  if (!row || !await ask({title: `Remove ${name}?`, text: `It is removed from ${presetStore.kind === 'pi' ? 'the device' : 'this browser'}${row.installed ? ' and can no longer be run' : ''}. This cannot be undone; export it first to keep a copy.`, ok: 'Remove', danger: true})) return;
  applyBusy = true; renderLive();
  try {
    if (row.stored) { await presetStore.remove(name); if (draftStoreName === name) draftStoreName = null; }
    if (row.installed) await removeInstalled(row.slug);
    toast(`${name} removed.`);
  } catch (e) { toast(`Could not remove: ${e.message}`); }
  applyBusy = false;
  pollHealth(); render();
}

async function importPresetFile(file) {
  try {
    if (file.size > 200000) throw new Error('the file is too large to be a preset');
    const document = normalise(parsePreset(await file.text()));
    const taken = Object.keys(presetStore.cache || {});
    let name = storeName(document.name);
    if (nameProblem(name, taken)) {
      name = await ask({title: 'Name the imported preset', text: nameProblem(name, taken), input: name, ok: 'Import', validate: value => nameProblem(value, taken)});
      if (name === null) return;
    }
    document.name = name;
    await presetStore.save(name, document);
    toast(`${name} imported. Open it to edit it, or run it.`);
  } catch (e) { toast(`This file was not imported: ${e.message}`); }
  render();
}

// ---------------------------------------------------------------- actions

/** The question for an action, in the words actions.mjs gives it. */
function askAction(kind) {
  const d = confirmDialog(kind, {outage: terms().outage, unkept: Boolean(effectiveLive()?.previewing)});
  return ask({title: d.title, text: d.text, ok: d.ok, danger: d.tone === 'danger'});
}

async function shutdown() {
  if (!await askAction('shutdown')) return;
  applyBusy = true; actionLocal = null; renderLive();
  try { const result = await requestShutdown(liveProfile()); shutdownRequested = true; toast(result.note || 'Shutting down.'); began(); }
  catch (e) { toast(`The device refused to shut down: ${e.message}`); }
  applyBusy = false;
  renderLive();
}

async function reboot() {
  if (!await askAction('reboot')) return;
  applyBusy = true; actionLocal = null; renderLive();
  try { const result = await requestReboot(); rebootRequested = true; toast(result.note || 'Rebooting.'); began(); }
  catch (e) { toast(`The device refused to reboot: ${e.message}`); }
  applyBusy = false;
  renderLive();
}

/** Restart audio, or the clock service (the endpoint restarts with it). */
async function restart(kind) {
  if (!await askAction(kind)) return;
  applyBusy = true; actionLocal = null; renderLive();
  try { const result = await (kind === 'restart-clock' ? requestRestartClock() : requestRestartAudio()); if (result.note) toast(result.note); began(); }
  catch (e) { toast(`The device refused: ${e.message}`); }
  applyBusy = false;
  renderLive();
}

/** Follow one request with the apply polling; resolves with its receipt, throws on a bad one. */
function followApply(id) {
  return new Promise((resolve, reject) => {
    applyWaiters.push(({current, error}) => {
      if (error) reject(error);
      else if (current?.id !== id) reject(new Error('another change to the device finished first'));
      else if (current.state !== 'done') reject(new Error(current.error || current.state));
      else resolve(current);
    });
    began();
  });
}

/** The support bundle: made on the device, then saved by the browser. */
async function supportBundle() {
  applyBusy = true; actionLocal = {text: 'Making the support bundle…', tone: 'busy'}; renderLive();
  try {
    const result = await requestBundle();
    const current = await followApply(result.id);
    const path = bundlePath(current);
    if (!path) throw new Error('the device did not say where the bundle is');
    saveBlob(BUNDLE_FILE, await fetchSupportBundle(path));
    actionLocal = {text: `Support bundle downloaded as ${BUNDLE_FILE}.`, tone: 'ok'};
  } catch (e) { actionLocal = {text: `The support bundle was not downloaded: ${e.message}`, tone: 'bad'}; }
  applyBusy = false;
  render();
}

async function changePassword() {
  const d = confirmDialog('password');
  const password = await askPassword({title: d.title, text: d.text, ok: d.ok});
  if (password === null) return;
  applyBusy = true; actionLocal = {text: 'Changing the page password…', tone: 'busy'}; renderLive();
  try {
    const result = await requestPassword(password);
    try {
      await followApply(result.id);
      actionLocal = {text: 'Page password changed. The browser asks for the new one on its next request.', tone: 'ok'};
    } catch (e) {
      // The service stops taking the old password once the file changes, so
      // following the receipt with it can meet a sign-in refusal: the change
      // was made.
      if (!/401|authenticat|sign.?in/i.test(e.message)) throw e;
      actionLocal = {text: 'Page password changed: the device no longer takes the old one. Sign in with the new password when the browser asks.', tone: 'ok'};
    }
    toast(actionLocal.text);
  } catch (e) { actionLocal = {text: `The password was not changed: ${e.message}`, tone: 'bad'}; toast(actionLocal.text); }
  applyBusy = false;
  render();
}

function runAction(kind) {
  if (kind === 'shutdown') shutdown();
  else if (kind === 'reboot') reboot();
  else if (kind === 'restart-audio' || kind === 'restart-clock') restart(kind);
  else if (kind === 'bundle') supportBundle();
  else if (kind === 'password') changePassword();
}

function startApplyPolling() {
  if (applyPoll) return;
  const tick = async () => {
    try { applyStatus = await fetchApplyStatus(); }
    catch (e) {
      stopApplyPolling();
      if (settleWaiters({error: e})) return;
      toast(shutdownRequested ? 'The device is powering off; this page has lost its connection.' : rebootRequested ? 'The Pi is rebooting; this page reconnects by itself when it is back.' : `Lost track of the change in progress: ${e.message}`);
      return;
    }
    renderLive();
    if (applyFinished(applyStatus)) {
      stopApplyPolling();
      const current = applyStatus.current;
      if (current?.kind === 'reboot' && current.state !== 'done') rebootRequested = false;
      if (current?.kind === 'shutdown' && current.state !== 'done') shutdownRequested = false;
      if (!settleWaiters({current}) && current?.kind !== 'live') toast(applyLine(applyStatus));
      pollHealth();
    }
  };
  applyPoll = setInterval(tick, APPLY_POLL_MS);
  tick();
}
function stopApplyPolling() { clearInterval(applyPoll); applyPoll = null; }
/** Hand the outcome to whoever waits on it; whether anyone did. */
function settleWaiters(outcome) { const waiting = applyWaiters; applyWaiters = []; waiting.forEach(done => done(outcome)); return waiting.length > 0; }

async function loadLogs() {
  if (!health || logBusy) return;
  logBusy = true; render();
  const service = logService;
  try { logLive[service] = await fetchLogs(service, 200); }
  catch (e) { toast(`Could not read the logs: ${e.message}`); }
  finally { logBusy = false; render(); }
}

// -------------------------------------------------------------- rendering

const busyNow = () => { const status = applyStatus || health?.apply || null; return applyBusy || Boolean(status && (status.inFlight || status.pending)); };
const headphoneIds = () => config.buses.filter(bus => bus.kind === 'headphones').flatMap(bus => bus.outputIds);
function rowsNow() {
  const choices = profileChoices(health);
  const profiles = (health?.profile?.profiles || []).filter(row => !row.user && (row.accepted || row.name === health.profile.selected))
    .map(row => ({name: row.name, description: row.description, live: row.name === health.profile.selected}));
  return presetRows({stored: presetStore.cache || {}, installed: userPresets(health), profiles, canApply: Boolean(health) && choices.available});
}

function meterNote() { return health ? (meterAbsence(health) || 'No level data.') : 'Not connected: no levels to show.'; }

function viewState() {
  const choices = profileChoices(health), status = applyStatus || health?.apply || null, current = status?.current;
  const lines = (logLive[logService] || '').split(/\r?\n/).filter(Boolean), shown = lines.filter(line => line.toLowerCase().includes(logQuery.toLowerCase()));
  const main = config.buses.find(bus => bus.kind === 'speakers'), free = config.outputs.filter(o => o.busId === null).length;
  return {
    config, health, connected: Boolean(health), dante: health?.stack === 'dante', changes: changes(),
    cards: statusCards(health), rows: meterRows(meterBody), meterNote: meterNote(),
    meterCaption: 'Peak level over the last 50 ms, with a peak hold. A clip light stays on until it is cleared.',
    eqOpen, band, eqClipboard, eqImport, align, confirmResetAll, headphoneIds: headphoneIds(),
    route, setDetail, polarity: polarityNote(config),
    chooser, layouts: LAYOUTS.map(l => ({id: l.id, label: l.label, outputs: l.routing.length, fits: chooser?.mode === 'new' || l.routing.length <= (main?.outputIds.length || 0) + free})),
    facts: systemFacts(health), generated: health?.generated, big: prefs.big, busy: busyNow(), shutdownRequested, rebootRequested,
    actions: Array.isArray(health?.control?.apply?.actions) ? health.control.apply.actions : [], actionNote: actionLocal || actionNote(current),
    safety: monitorKind(health, 'monitor-limits') && monitor ? {limits: monitor.limits, notes: safetyNotes(monitor.limits), note: safetyNote, busy: busyNow()} : null,
    canApply: Boolean(health) && choices.available, applyReason: health && !choices.available ? (choices.reason || 'This device cannot switch presets.') : '',
    outage: terms().outage, presetRows: rowsNow(), editing: draftStoreName,
    applyLine: applyLine(status), applySteps: (current?.steps || []).map(step => ({ok: step.ok, detail: step.detail, label: applyStepLabel(step.name, current.stack || terms().stack)})),
    logServices: terms().logs, logService, logQuery, logBusy, logText: logLive[logService],
    logShown: !health ? 'Not connected: the logs are read from the device.' : !lines.length ? 'Nothing read yet.' : shown.length ? shown.join('\n') : 'No line contains that text.',
    logCount: lines.length ? `${shown.length} of ${lines.length} lines` : '',
  };
}

function processorView(S) {
  const n = S.changes;
  const head = `<section class="panel draft-head"><div><span class="overline">Running on the device</span><strong id="running-name">${esc(health ? deviceModeLabel(health) : 'Not connected')}</strong></div>
    <div><span class="overline">Editing</span><strong>${esc(config.name)}</strong><span class="muted">${fresh ? 'New, not saved yet' : n ? `${n} unsaved change${n === 1 ? '' : 's'}` : 'No unsaved changes'}</span></div>
    <div class="toolbar"><button type="button" data-act="undo" ${history.canUndo ? '' : 'disabled'} title="Undo (Cmd or Ctrl + Z)" aria-label="Undo the last preset change">Undo</button>
      <button type="button" data-act="redo" ${history.canRedo ? '' : 'disabled'} title="Redo (Shift + Cmd or Ctrl + Z)" aria-label="Redo the change you undid">Redo</button>
      <button type="button" data-act="layout-open">Change speaker layout</button><button type="button" data-act="new-open">New preset</button></div></section>`;
  if (chooser) return head + chooserView(S);
  const tabs = [['outputs', 'Outputs'], ['routing', 'Routing'], ['sets', 'Speakers & headphones'], ['bass', 'Bass management']];
  const nav = `<nav class="subtabs" aria-label="Processor sections">${tabs.map(([id, label]) => `<button type="button" data-ptab="${id}" ${id === ptab ? 'aria-current="page"' : ''}>${label}</button>`).join('')}</nav>`;
  const view = ptab === 'routing' ? routingView(S) : ptab === 'sets' ? setsView(S) : ptab === 'bass' ? bassView(S) : outputsView(S);
  return head + nav + view;
}

/** Which control has the keyboard, so a redraw can hand it back. */
function focusKey(el) {
  if (!el || el === document.body) return null;
  const d = el.dataset || {};
  if (d.k) return {k: d.k, start: el.selectionStart ?? null, end: el.selectionEnd ?? null};
  if (d.act) return {act: d.act, v: d.v ?? '', i: d.i ?? ''};
  if (d.eqNode !== undefined) return {node: d.eqNode};
  return el.id ? {id: el.id} : null;
}
function refocus(key) {
  if (!key) return;
  // The EQ editor is a pop-up outside the view; a control in either can hold the keyboard.
  const view = $('#eq-dialog').open ? $('#eq-dialog') : $('#view');
  const el = key.k ? [...view.querySelectorAll('[data-k]')].find(node => node.dataset.k === key.k)
    : key.act ? [...view.querySelectorAll('[data-act]')].find(node => node.dataset.act === key.act && (node.dataset.v ?? '') === key.v && (node.dataset.i ?? '') === key.i)
    : key.node !== undefined ? view.querySelector(`[data-eq-node="${key.node}"]`) : document.getElementById(key.id);
  if (!el || el.disabled) return;
  el.focus({preventScroll: true});
  if (key.start !== null && key.start !== undefined && el.setSelectionRange) { try { el.setSelectionRange(key.start, key.end); } catch { /* not a text field */ } }
}

function render() {
  renderQueued = false;
  endEqDrag(true);
  eqObserver?.disconnect();
  const key = $('#view').contains(document.activeElement) || $('#eq-dialog').contains(document.activeElement) ? focusKey(document.activeElement) : null;
  const S = viewState();
  document.body.classList.toggle('big', prefs.big);
  for (const button of document.querySelectorAll('[data-tab]')) { if (button.dataset.tab === tab) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current'); }
  const view = $('#view');
  if (tab === 'control') renderControl();
  else { view.dataset.tab = tab; view.innerHTML = tab === 'status' ? statusView(S) : tab === 'system' ? systemView(S) : processorView(S); }
  // The EQ editor opens over the page, large, as a pop-up.
  const eqDialog = $('#eq-dialog');
  if (tab === 'processor' && !chooser && ptab === 'outputs' && eqOpen !== null) {
    eqDialog.innerHTML = eqView(S);
    if (!eqDialog.open) eqDialog.showModal();
    drawEq();
    eqObserver = new ResizeObserver(drawEq);
    eqObserver.observe($('#eq-display'));
  } else {
    eqOpen = null;
    if (eqDialog.open) eqDialog.close();
    eqDialog.innerHTML = '';
  }
  refocus(key);
  renderChrome();
  drawMeters(true);
}

// A redraw replaces the controls. Done in the middle of a click it would
// swallow the click (the button under the pointer is gone before it is
// released), and done before the keyboard focus has moved it would lose the
// Tab. So a redraw asked for by an edit waits: for the pointer to be let go,
// and for the event that asked for it to finish.
let renderQueued = false, pointerDown = false, afterPointer = false;
function requestRender() {
  if (renderQueued) return;
  renderQueued = true;
  if (pointerDown) afterPointer = true; else setTimeout(render, 0);
}
document.addEventListener('pointerdown', () => { pointerDown = true; }, true);
for (const type of ['pointerup', 'pointercancel']) document.addEventListener(type, () => { pointerDown = false; if (afterPointer) { afterPointer = false; setTimeout(render, 0); } }, true);

/** Everything outside the tab's own view: header, notices, the change bar. */
let lastNoticesHtml = null;
function renderChrome() {
  const crTab = document.querySelector('[data-tab="control"]');
  if (crTab) crTab.hidden = !monitorOffered(health);
  const pill = $('#pill'), state = pillState(health, access);
  $('#pill-text').textContent = state.text;
  pill.dataset.state = state.state; pill.title = state.title;
  const rate = health ? formatRate(health.audio?.sampleRate) : null;
  $('#format-line').textContent = `${rate ? `${rate} · ` : ''}16 in, 16 out`;
  const name = deviceName(health);
  document.title = name || 'USB-AoIP';
  const brand = $('#brand-device');
  brand.textContent = name && name !== 'USB-AoIP' ? name : ''; brand.hidden = !brand.textContent;
  // A reboot asked for from here is said until the device answers again.
  const notices = [...pageNotices(health, access), ...(rebootRequested && !health ? [{id: 'reboot', severity: 'info', text: 'The Pi is rebooting. This page reconnects by itself when it answers again.'}] : [])];
  const html = notices.map(n => n.severity === 'info' ? `<p class="banner note" data-notice="${esc(n.id)}">${esc(n.text)}</p>`
    : `<p class="banner ${n.severity === 'bad' ? 'bad' : 'warn'}" data-notice="${esc(n.id)}"><strong>${n.severity === 'bad' ? 'Problem' : 'Warning'}:</strong> ${esc(n.text.replace('System & presets', 'System'))}</p>`).join('');
  if (html !== lastNoticesHtml) { lastNoticesHtml = html; const box = $('#page-notices'); box.innerHTML = html; box.hidden = !html; }
  renderBar();
}

const BAR_BUTTONS = {discard: ['Discard', ''], keep: ['Keep changes', 'primary'], 'save-as': ['Save as…', ''], apply: ['Apply and restart audio', 'primary'], save: ['Save', 'primary']};
let lastBarHtml = null;
function renderBar() {
  const bar = $('#change-bar');
  const state = changeBar({connected: Boolean(health), applyAvailable: profileChoices(health).available, live: effectiveLive(), changes: changes(), fresh,
    outage: terms().outage, running: health ? deviceModeLabel(health) : null});
  // A preset that is simply not the running one is said where presets are edited, not on every tab.
  const open = state.kind !== 'none' && !(state.kind === 'not-running' && tab !== 'processor');
  const status = applyStatus || health?.apply || null, working = busyNow();
  const html = !open ? '' : `<div class="bar-inner kind-${state.kind}"><div role="status"><span><strong>${esc(state.text)}</strong> ${esc(state.detail)}</span>
      ${working ? `<span class="muted">${esc(applyLine(status))}</span>` : liveLine ? `<span class="warn-text">${esc(liveLine)}</span>` : ''}</div>
    <div class="toolbar">${state.buttons.map(id => `<button type="button" class="${BAR_BUTTONS[id][1]}" data-bar="${id}" ${working ? 'disabled' : ''}>${BAR_BUTTONS[id][0]}</button>`).join('')}</div></div>`;
  if (html === lastBarHtml) return;
  lastBarHtml = html;
  bar.innerHTML = html; bar.hidden = !open;
  document.body.classList.toggle('has-bar', open);
}

/** After a health poll: redraw what the device's state shows, and nothing a person may be typing in. */
function renderLive() {
  renderChrome();
  if (tab === 'status') {
    const S = viewState();
    S.cards.forEach(card => {
      const node = document.querySelector(`[data-card="${card.id}"]`);
      if (!node) return;
      const [, value, detail] = node.children;
      if (value.textContent !== card.value) value.textContent = card.value;
      if (detail.textContent !== card.detail) detail.textContent = card.detail;
      node.className = `card state-${card.state || 'plain'}`;
      const stateNode = node.querySelector('.card-state');
      if (Boolean(stateNode) !== Boolean(card.stateText)) render(); else if (stateNode && stateNode.textContent !== card.stateText) stateNode.textContent = card.stateText;
    });
    drawMeters(true);
  } else if (tab === 'processor') {
    const node = $('#running-name');
    if (node) node.textContent = health ? deviceModeLabel(health) : 'Not connected';
  } else if (tab === 'control') {
    // The Control Room follows its own poll (refreshMonitor); a receipt may change what Set can do.
    renderControl();
  } else {
    const S = viewState(), view = $('#view');
    const selection = document.getSelection();
    if (selection && !selection.isCollapsed && view.contains(selection.anchorNode)) return;
    const actions = actionsPanel(S), safety = safetyPanel(S);
    // The Actions and Level safety panels come and go with the device's lists: a redraw puts them in or takes them out.
    if (Boolean(actions) !== Boolean(view.querySelector('#actions-panel')) || Boolean(safety) !== Boolean(view.querySelector('#safety-panel'))) { if (!view.contains(document.activeElement)) render(); return; }
    const panels = [['#device-panel', devicePanel(S)], ...(safety ? [['#safety-panel', safety]] : []), ...(actions ? [['#actions-panel', actions]] : []), ['#presets-panel', presetsPanel(S)], ...(health ? [['#change-panel', lastChangePanel(S)]] : [])];
    for (const [id, html] of panels) {
      const node = view.querySelector(id);
      if (!node) { if (!view.contains(document.activeElement)) render(); return; }
      // Compared as the browser writes it back, so an unchanged panel is not replaced on every poll.
      if (node.outerHTML === serialised(html)) continue;
      if (!node.contains(document.activeElement)) { node.outerHTML = html; continue; }
      // The button just pressed keeps the keyboard; its note and its buttons' states still follow the device.
      if (id === '#actions-panel') patchActions(node, html);
    }
  }
}

function serialised(html) { const t = document.createElement('template'); t.innerHTML = html; return t.innerHTML; }

/** The Actions panel brought up to date without replacing its controls. */
function patchActions(node, html) {
  const fresh = document.createElement('template'); fresh.innerHTML = html;
  const next = fresh.content.firstElementChild, note = node.querySelector('.action-note'), nextNote = next.querySelector('.action-note');
  note.className = nextNote.className; if (note.textContent !== nextNote.textContent) note.textContent = nextNote.textContent;
  const buttons = [...node.querySelectorAll('button[data-v]')], nextButtons = [...next.querySelectorAll('button[data-v]')];
  if (buttons.map(b => b.dataset.v).join() !== nextButtons.map(b => b.dataset.v).join()) return;
  buttons.forEach((button, i) => { button.disabled = nextButtons[i].disabled; if (button.textContent !== nextButtons[i].textContent) button.textContent = nextButtons[i].textContent; });
}

// ----------------------------------------------------------- Control Room
//
// A knob move is POST /api/monitor through the sender (one in flight, at most
// every 30 ms while dragging, the final value on release). The page shows its
// own value at once (overlay) and the owner's once the owner reports the seq
// it was written under. The tab is redrawn in place (morph), so a knob being
// dragged or a field being typed in keeps its element and its focus.

async function refreshMonitor() {
  if (!health || monitorReading) return;
  monitorReading = true;
  try {
    const next = reduceMonitor(await fetchMonitor());
    if (next) {
      monitor = next;
      if (next.available) overlay.settle(next.effective.seq, Date.now());
    }
  } finally { monitorReading = false; }
  if (tab === 'control') {
    if (monitor && !monitor.available) { toast(`The Control Room is not available: ${monitor.reason || 'the device did not say why'}`); tab = 'status'; render(); }
    else renderControl();
  } else if (tab === 'system') renderLive();
}
setInterval(() => { if (tab === 'control' && health && !document.hidden) refreshMonitor(); }, MONITOR_POLL_MS);

function controlHtml() {
  if (!monitor?.available) { crModel = null; return '<p class="muted">Reading the Control Room from the device…</p>'; }
  crModel = controlRoom({model: monitor, values: monitorValues(monitor, overlay), labels: setLabels(monitor.sets, presetForLiveProfile(health)?.document),
    meters: freshMeters()?.['to-network'] || null, keysOpen: crKeys, refOpen: crRefOpen, groups: crGroups, groupEdit: crGroupEdit, busy: busyNow()});
  return controlRoomView(crModel);
}

function renderControl() {
  if (tab !== 'control') return;
  const view = $('#view'), html = controlHtml();
  if (view.dataset.tab !== 'control') { view.dataset.tab = 'control'; view.innerHTML = html; }
  else { const t = document.createElement('template'); t.innerHTML = html; morphChildren(view, t.content); }
  applyVars(view);
  drawMeters(true);
}

/** Bring `node` to `next` without replacing it: attributes, text, an unfocused field's value, then the children. */
function morph(node, next) {
  if (node.nodeType !== 1) { if (node.nodeValue !== next.nodeValue) node.nodeValue = next.nodeValue; return; }
  // The style attribute holds what script set (meter levels, angles, places): it is not the view's.
  for (const {name} of [...node.attributes]) if (name !== 'style' && !next.hasAttribute(name)) node.removeAttribute(name);
  for (const {name, value} of [...next.attributes]) if (node.getAttribute(name) !== value) node.setAttribute(name, value);
  if (node.tagName === 'INPUT' && node !== document.activeElement) { const value = next.getAttribute('value') ?? ''; if (node.value !== value) node.value = value; }
  morphChildren(node, next);
}
function morphChildren(parent, next) {
  const have = [...parent.childNodes], want = [...next.childNodes];
  want.forEach((w, i) => {
    const h = have[i];
    if (!h) parent.append(w.cloneNode(true));
    else if (h.nodeType !== w.nodeType || h.nodeName !== w.nodeName || (h.id || '') !== (w.id || '')) parent.replaceChild(w.cloneNode(true), h);
    else morph(h, w);
  });
  have.slice(want.length).forEach(h => h.remove());
}

/** The numbers the Control Room's view leaves to script: the knob's angle, a tile's place. */
function applyVars(root) {
  for (const el of root.querySelectorAll('[data-rot]')) el.style.setProperty('--rot', `${el.dataset.rot}deg`);
  for (const el of root.querySelectorAll('[data-x]')) { el.style.setProperty('--x', `${el.dataset.x}%`); el.style.setProperty('--y', `${el.dataset.y}%`); }
}

function drawControlMeters(bank) {
  const paint = (el, ch) => {
    if (!el) return;
    el.style.setProperty('--level', `${ch ? levelPercent(ch.peak) : 0}%`);
    el.style.setProperty('--hold', `${ch ? levelPercent(ch.hold) : 0}%`);
    el.classList.toggle('held', Boolean(ch) && ch.hold > FLOOR_DB);
    el.classList.toggle('no-data', !bank);
  };
  for (const c of crModel.cards) {
    let peak = -Infinity;
    for (const o of c.outputs) {
      const ch = bank?.[o.n];
      paint(document.getElementById(`crm-${c.key}-${o.n}`), ch);
      document.getElementById(`cro-${c.key}-${o.n}`)?.classList.toggle('on', Boolean(ch?.clip));
      if (ch) peak = Math.max(peak, ch.peak);
    }
    const line = document.getElementById(`crp-${c.key}`), text = peakText(bank ? peak : null);
    if (line && line.textContent !== text) line.textContent = text;
  }
  for (const r of crModel.rooms) for (const t of [...r.tiles, ...r.loose]) paint(document.getElementById(`crt-${r.id}-${t.n}`), bank?.[t.n]);
  for (const s of crModel.setSwitch) {
    if (!s.meter) continue;
    const outs = monitor.sets.find(set => set.id === s.id)?.outputs || [];
    const loud = bank ? Math.max(FLOOR_DB, ...outs.map(o => bank[o.n]?.peak ?? FLOOR_DB)) : null;
    paint(document.getElementById(`crs-${s.id}`), loud === null ? null : {peak: loud, hold: FLOOR_DB});
  }
  const anyClip = holds['to-network'].anyClip;
  for (const button of document.querySelectorAll('[data-clips]')) button.hidden = !anyClip;
}

const cardOf = key => crModel?.cards.find(c => c.key === key) || null;
const roomOf = id => crModel?.rooms.find(r => r.id === id) || null;

/** One change to the monitor: shown at once, sent by the sender. */
function change(body, {immediate = true} = {}) {
  if (!monitor?.available) return;
  if (sender.submit(patchKey(body), body, {immediate})) for (const [key, value] of Object.entries(patchKeys(body))) overlay.set(key, value);
  renderControl();
}
function setLevel(c, value, options) {
  if (!c) return;
  const level = clampLevel(value, c.maxDb);
  if (level === c.level && options?.immediate === false) return;
  change(setPatch(c.ids, {levelDb: level}), options);
}

/** A reference level and note, root's: a request to the applier, followed to its receipt. */
async function storeReference(c, levelDb, note) {
  if (!c || monitor?.limits.lock) return;
  if (/[^\x20-\x7E]|["\\]/.test(note) || note.length > 64) { toast('A note is at most 64 plain characters, without quotes or backslashes.'); renderControl(); return; }
  applyBusy = true; renderControl();
  try {
    const result = await requestMonitorReference(c.refSet, levelDb, note);
    await followApply(result.id);
    toast(`Reference for ${c.title} stored: ${dbWords(levelDb)}${note ? ` · ${note}` : ''}.`);
  } catch (e) { toast(`The reference was not stored: ${e.message}`); }
  applyBusy = false;
  await refreshMonitor();
}

/** Level safety, root's: a request to the applier, followed to its receipt. */
async function changeLimits(fields) {
  applyBusy = true; safetyNote = {text: 'Asking the device…', tone: 'busy'}; render();
  try {
    const result = await requestMonitorLimits(fields);
    await followApply(result.id);
    safetyNote = {text: 'Level safety changed on the device.', tone: 'ok'};
  } catch (e) { safetyNote = {text: `Not changed: ${e.message}`, tone: 'bad'}; }
  applyBusy = false;
  await refreshMonitor();
  render();
}

function controlClick(spec, event) {
  const [op, a, b] = spec.split(';');
  if (!monitor?.available || !crModel) return;
  const values = monitorValues(monitor, overlay), c = cardOf(a), additive = event.metaKey || event.ctrlKey;
  const outs = text => String(text).split(',').map(Number).filter(Number.isInteger);
  switch (op) {
    case 'keys': crKeys = !crKeys; break;
    case 'ref-toggle': crRefOpen = {...crRefOpen, [a]: !crRefOpen[a]}; break;
    case 'step': setLevel(c, c.level + Number(b) * BUTTON_STEP_DB); return;
    case 'to-ref': setLevel(c, c.ref); return;
    case 'dim': change(setPatch(c.ids, {dim: !c.dim})); return;
    case 'mute': change(setPatch(c.ids, {mute: !c.mute})); return;
    case 'set-ref': storeReference(c, c.level, c.note); return;
    case 'fold': change({set: c.refSet, fold: b}); return;
    case 'subs': change({subs: !values.subs}); return;
    case 'trim-step': change({set: a, trimDb: clampTrim(values.sets[a].trimDb + Number(b) * TRIM_STEP_DB)}); return;
    case 'active': change({active: a}); return;
    case 'solo': case 'group-solo': { const r = roomOf(a); if (r) change({solo: soloPress(values.solo, r.setOuts, outs(b), additive)}); return; }
    case 'out-mute': case 'group-mute': change({outMute: mutePress(values.outMute, outs(b))}); return;
    case 'clear-solo': change({clearSolo: true}); return;
    case 'clear-clips': holds['to-network'].clearClips(); meterShown?.['to-network']?.forEach(channel => { channel.clip = false; }); break;
    case 'group-new': crGroupEdit = {set: a, name: '', outs: []}; break;
    case 'group-cancel': crGroupEdit = null; break;
    case 'pick': if (crGroupEdit) { const n = Number(b); crGroupEdit.outs = crGroupEdit.outs.includes(n) ? crGroupEdit.outs.filter(x => x !== n) : [...crGroupEdit.outs, n]; } break;
    case 'group-save':
      if (crGroupEdit?.outs.length) { crGroups = addGroup(crGroups, a, crGroupEdit.name, crGroupEdit.outs); if (!saveGroups(crGroups)) toast('This browser will not remember the group.'); crGroupEdit = null; }
      break;
    case 'group-remove': crGroups = removeGroup(crGroups, a, b); saveGroups(crGroups); break;
    default: return;
  }
  renderControl();
}

/** A typed value in the Control Room or the Level safety panel. */
function controlField(m, v, text) {
  if (m === 'group-name') return;
  const value = m === 'note' ? null : parseNumber(text);
  if (value !== null && Number.isNaN(value)) { toast('Type a level in dB, like -18.5.'); if (tab === 'control') renderControl(); else render(); return; }
  const c = cardOf(v);
  switch (m) {
    case 'level': setLevel(c, value); return;
    case 'trim': change({set: v, trimDb: clampTrim(value)}); return;
    case 'ref': if (c) storeReference(c, clampLevel(value, c.maxDb), c.note); return;
    case 'note': if (c) storeReference(c, c.ref, text.trim()); return;
    case 'sf-max': if (monitor) changeLimits({maxDb: clampMax(value)}); return;
    case 'sf-start-db': if (monitor) changeLimits({startDb: clampLevel(value, monitor.limits.maxDb)}); return;
    default:
  }
}

/** The Control Room's keys. True when the key was the Control Room's. */
function controlKey(event, typing) {
  if (!crModel || document.querySelector('dialog[open]')) return false;
  const arrow = {ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1}[event.key];
  const knob = event.target.closest?.('[data-knob]');
  if (knob && arrow) { event.preventDefault(); const c = cardOf(knob.dataset.knob); setLevel(c, c.level + arrow * KEY_STEP_DB); return true; }
  const focus = document.activeElement;
  if (typing || event.metaKey || event.ctrlKey || event.altKey || !(focus === document.body || $('#view').contains(focus))) return false;
  const first = crModel.cards[0], k = event.key;
  let hit = true;
  if (k === '?') { crKeys = !crKeys; renderControl(); }
  else if (k === 'Escape') { if (crModel.anySolo) change({clearSolo: true}); else hit = false; }
  else if (!first) hit = false;
  else if (k === 'ArrowUp' || k === 'ArrowDown') setLevel(first, first.level + (k === 'ArrowUp' ? 1 : -1) * BUTTON_STEP_DB);
  else if (k === 'm' || k === 'M') change(setPatch(first.ids, {mute: !first.mute}));
  else if (k === 'd' || k === 'D') change(setPatch(first.ids, {dim: !first.dim}));
  else if (k === 'r' || k === 'R') setLevel(first, first.ref);
  else if (/^[0-9]$/.test(k) && crModel.several) {
    const n = Number(k), sets = crModel.setSwitch;
    if (n === 0) change({active: 'all'}); else if (n < sets.length) change({active: sets[n - 1].id}); else hit = false;
  } else hit = false;
  if (hit) event.preventDefault();
  return hit;
}

// The knob: 0.25 dB a pixel while dragged, the last value sent on release.
document.addEventListener('pointerdown', event => {
  const node = event.target.closest?.('[data-knob]');
  if (!node || event.button !== 0 || tab !== 'control') return;
  const c = cardOf(node.dataset.knob);
  if (!c) return;
  event.preventDefault();
  node.focus({preventScroll: true});
  knobDrag = {key: c.key, y0: event.clientY, v0: c.level, pointerId: event.pointerId, node};
  node.setPointerCapture(event.pointerId);
});
document.addEventListener('pointermove', event => {
  if (!knobDrag || event.pointerId !== knobDrag.pointerId) return;
  setLevel(cardOf(knobDrag.key), knobDrag.v0 + (knobDrag.y0 - event.clientY) * DRAG_DB_PER_PX, {immediate: false});
});
function endKnob(event) {
  if (!knobDrag || (event && event.pointerId !== knobDrag.pointerId)) return;
  const drag = knobDrag; knobDrag = null;
  if (drag.node.hasPointerCapture?.(drag.pointerId)) drag.node.releasePointerCapture(drag.pointerId);
  const c = cardOf(drag.key);
  if (c) change(setPatch(c.ids, {levelDb: c.level}), {immediate: true});
}
document.addEventListener('pointerup', endKnob);
document.addEventListener('pointercancel', endKnob);
window.addEventListener('blur', () => endKnob());

// ----------------------------------------------------------------- meters

/** The last window if the taps answered within 1.5 s, else nothing. */
function freshMeters() { return meterShown && performance.now() - meterAt < 1500 ? meterShown : null; }

function drawMeters(force = false) {
  if (document.hidden) return;
  const live = freshMeters();
  if (tab === 'status') {
    let anyClip = false;
    for (const id of Object.keys(holds)) {
      const bars = document.getElementById(`sm-${id}-bars`), none = document.getElementById(`sm-${id}-none`);
      if (!bars) return;
      const bank = live?.[id];
      bars.hidden = !bank; none.hidden = Boolean(bank);
      if (!bank) { if (force) none.textContent = live ? 'No level data for this direction.' : meterNote(); continue; }
      bank.forEach((channel, i) => {
        const bar = document.getElementById(`sm-${id}-${i}`);
        bar.style.setProperty('--level', `${levelPercent(channel.peak)}%`);
        bar.style.setProperty('--hold', `${levelPercent(channel.hold)}%`);
        bar.classList.toggle('held', channel.hold > FLOOR_DB);
        document.getElementById(`sm-${id}-c${i}`).classList.toggle('on', channel.clip);
        anyClip ||= channel.clip;
      });
    }
    const clear = $('#clear-clips'); if (clear) clear.hidden = !anyClip;
  } else if (tab === 'control' && crModel) {
    drawControlMeters(live?.['to-network'] || null);
  } else if (tab === 'processor' && ptab === 'outputs' && !chooser) {
    const bank = live?.['to-network'];
    for (let i = 0; i < CHANNELS; i += 1) {
      const meter = document.getElementById(`om-${i}`);
      if (!meter) continue;
      meter.style.setProperty('--level', `${bank ? levelPercent(bank[i].peak) : 0}%`);
      meter.style.setProperty('--hold', `${bank ? levelPercent(bank[i].hold) : 0}%`);
      meter.classList.toggle('held', Boolean(bank) && bank[i].hold > FLOOR_DB);
      meter.classList.toggle('clip', Boolean(bank?.[i].clip));
      meter.classList.toggle('no-data', !bank);
    }
  }
}

// Read the taps at up to 10 Hz, only while meters are on screen and the
// service says a tap exists; one request in flight at a time, so a slow
// answer thins the rate rather than queueing.
const metersOnScreen = () => tab === 'status' || tab === 'control' || (tab === 'processor' && ptab === 'outputs' && !chooser);
async function pollMeters() {
  if (meterBusy || document.hidden || !metersOnScreen() || !health?.meters?.available) return;
  meterBusy = true;
  try {
    const body = await fetchMeters();
    if (body) {
      const now = performance.now();
      meterBody = body; meterAt = now;
      meterShown = Object.fromEntries(meterRows(body).map(row => [row.id, row.bank ? holds[row.id].update(row.bank, now) : null]));
    }
  } finally { meterBusy = false; }
}
setInterval(() => { pollMeters(); const had = Boolean(meterShown); if (had && !freshMeters()) meterShown = null; drawMeters(had && !meterShown); }, METER_POLL_MS);

// --------------------------------------------------------------- EQ editor

function eqGeometry() {
  const rect = $('#eq-display').getBoundingClientRect();
  const width = rect.width || 600, height = rect.height || 300;
  return {width, height, left: 34, top: 14, plotWidth: width - 48, plotHeight: height - 40};
}
const eqEditable = () => eqOpen !== null && !config.eqBypass && config.outputs[eqOpen].eqEnabled;

function drawEq() {
  if (eqOpen === null || !$('#eq-display')) return;
  const o = config.outputs[eqOpen], {width, height, left, top, plotWidth, plotHeight} = eqGeometry();
  const x = f => left + Math.log10(f / 20) / 3 * plotWidth, y = g => top + plotHeight / 2 - Math.max(-EQ_RANGE_DB, Math.min(EQ_RANGE_DB, g)) * plotHeight / (EQ_RANGE_DB * 2);
  const bypassAll = Boolean(config.eqBypass), editable = eqEditable();
  const grid = [-EQ_RANGE_DB, -EQ_RANGE_DB / 2, 0, EQ_RANGE_DB / 2, EQ_RANGE_DB].map(g => `<line x1="${left}" y1="${y(g)}" x2="${x(20000)}" y2="${y(g)}" class="${g === 0 ? 'eq-zero' : 'eq-grid'}"/><text x="4" y="${y(g) + 4}" class="eq-label">${g > 0 ? '+' : ''}${g}</text>`).join('')
    + [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].filter((f, i) => width > 520 || i % 3 === 0).map(f => `<line x1="${x(f)}" y1="${top}" x2="${x(f)}" y2="${y(-EQ_RANGE_DB)}" class="eq-grid"/><text x="${x(f)}" y="${height - 8}" text-anchor="middle" class="eq-label">${f >= 1000 ? `${f / 1000}k` : f}</text>`).join('');
  const path = response => 'M' + Array.from({length: 201}, (_, i) => { const f = 20 * 1000 ** (i / 200); return `${x(f).toFixed(1)},${y(response(f)).toFixed(1)}`; }).join(' L');
  const curves = o.eqEnabled && !bypassAll ? o.bands.map((b, i) => !b.enabled ? '' : `<path d="${path(f => bandResponse(b, f))} L${x(20000)},${y(0)} L${left},${y(0)} Z" fill="${BAND_COLORS[i]}" fill-opacity="${i === band ? '.2' : '.03'}"/><path d="${path(f => bandResponse(b, f))}" fill="none" stroke="${BAND_COLORS[i]}" stroke-width="${i === band ? 2 : 1}" opacity="${i === band ? '.95' : '.4'}"/>`).join('') : '';
  const chart = $('#eq-chart');
  chart.setAttribute('viewBox', `0 0 ${width} ${height}`);
  chart.innerHTML = `${grid}${curves}<path d="${path(f => eqResponse(o, f, bypassAll))}" class="eq-curve"/>`;
  $('#eq-display').classList.toggle('eq-off', !editable);
  document.querySelectorAll('[data-eq-node]').forEach(node => {
    const i = Number(node.dataset.eqNode), b = o.bands[i];
    node.style.left = `${x(b.frequency) / width * 100}%`; node.style.top = `${y(b.gainDb) / height * 100}%`;
    node.classList.toggle('selected', i === band); node.classList.toggle('band-off', !b.enabled);
    node.disabled = !editable; node.setAttribute('aria-pressed', i === band);
    node.setAttribute('aria-label', `Band ${i + 1}: ${b.frequency.toFixed(1)} Hz, ${b.gainDb.toFixed(1)} dB, Q ${b.q.toFixed(2)}${b.enabled ? '' : ', off'}`);
  });
}

/** One band changed on the open output; a headphone ear set to follow the other follows. */
const linkEq = () => { config = mirrorLinkedEq(config, eqOpen); };

function endEqDrag(cancel = false) {
  if (!eqDrag) return;
  const drag = eqDrag; eqDrag = null;
  drag.node.classList.remove('dragging');
  if (drag.node.hasPointerCapture?.(drag.pointerId)) drag.node.releasePointerCapture(drag.pointerId);
  if (cancel) { config = drag.before; markDraft(); return; }
  linkEq();
  if (JSON.stringify(drag.before) !== JSON.stringify(config)) { history.record(drag.before); markDraft(); }
  requestRender();
}

document.addEventListener('pointerdown', event => {
  const node = event.target.closest?.('[data-eq-node]');
  if (!node || event.button !== 0 || eqDrag || !eqEditable()) return;
  event.preventDefault();
  const picked = Number(node.dataset.eqNode);
  // Nothing is redrawn while the drag runs: the handle being held must stay.
  // The band's own controls catch up when the pointer is let go.
  if (picked !== band) { band = picked; drawEq(); }
  node.focus({preventScroll: true});
  if (!config.outputs[eqOpen].bands[band].enabled) { requestRender(); return; }
  eqDrag = {node, pointerId: event.pointerId, before: clone(config), x: event.clientX, y: event.clientY};
  node.setPointerCapture(event.pointerId); node.classList.add('dragging');
});
document.addEventListener('pointermove', event => {
  if (!eqDrag || event.pointerId !== eqDrag.pointerId) return;
  const {plotWidth, plotHeight} = eqGeometry(), dx = (event.clientX - eqDrag.x) / plotWidth, dy = (event.clientY - eqDrag.y) / plotHeight;
  eqDrag.x = event.clientX; eqDrag.y = event.clientY;
  if (!dx && !dy) return;
  const o = config.outputs[eqOpen];
  o.bands[band] = dragEqBand(o.bands[band], dx, dy, event.metaKey || event.ctrlKey);
  markDraft(); drawEq();
});
document.addEventListener('pointerup', event => { if (eqDrag?.pointerId === event.pointerId) endEqDrag(); });
document.addEventListener('pointercancel', event => { if (eqDrag?.pointerId === event.pointerId) endEqDrag(true); });
window.addEventListener('blur', () => endEqDrag(true));
document.addEventListener('dblclick', event => {
  const node = event.target.closest?.('[data-eq-node]');
  if (!node || node.disabled) return;
  event.preventDefault(); endEqDrag(true);
  const index = Number(node.dataset.eqNode); band = index;
  edit(c => { c.outputs[eqOpen].bands[index] = resetBand(c.outputs[eqOpen].bands[index], index); return mirrorLinkedEq(c, eqOpen); });
});

$('#eq-dialog').addEventListener('cancel', event => { event.preventDefault(); if (eqDrag) return; eqOpen = null; eqImport = null; render(); });
$('#eq-dialog').addEventListener('pointerdown', event => { if (event.target === event.currentTarget) { eqOpen = null; eqImport = null; requestRender(); } });

/** The EQ of the next output in use, in either direction. */
function gotoEq(direction) {
  for (let n = 1; n <= CHANNELS; n += 1) {
    const candidate = (eqOpen + direction * n + CHANNELS * n) % CHANNELS;
    if (config.outputs[candidate].busId !== null) { eqOpen = candidate; break; }
  }
  band = 0; eqImport = null; render();
}

// ------------------------------------------------------------------ fields

const number = (text, what) => { const value = parseNumber(text); if (Number.isNaN(value)) throw new Error(`${what}: type a number`); return value; };
const level = (text, what) => { const value = parseSend(text); if (Number.isNaN(value)) throw new Error(`${what}: type a level in dB, or off`); return value; };
const mains = c => speakerGroupSourceIds(c).filter(i => i !== c.lfe.input);

/** A typed or chosen value going into the draft. `f` names the field, `i` its index or id. */
function setField(f, i, text) {
  edit(c => {
    switch (f) {
      case 'out.label': c.outputs[Number(i)].label = text.trim(); return null;
      case 'out.gainDb': c.outputs[Number(i)].gainDb = number(text, 'Level'); return null;
      case 'out.delayMs': c.outputs[Number(i)].delayMs = number(text, 'Delay'); return null;
      case 'in.label': c.inputs[Number(i)].label = text.trim(); return null;
      case 'in.highpassHz': c.inputs[Number(i)].highpassHz = number(text, 'High-pass'); return null;
      case 'in.lowpassHz': c.inputs[Number(i)].lowpassHz = number(text, 'Bass low-pass'); return null;
      case 'send': { const [from, to] = i.split(',').map(Number); c.sends[from][to] = level(text, 'Send'); return null; }
      case 'mix': { const [id, input, ear] = i.split(','); const matrix = clone(getBus(c, id).downmixMatrix); matrix[Number(input)][Number(ear)] = level(text, 'Send'); return setHeadphoneMatrix(c, id, matrix); }
      case 'set.label': getBus(c, i).label = text.trim(); return null;
      case 'set.out': { const [id, ear] = i.split(','); const ids = [...getBus(c, id).outputIds]; ids[Number(ear)] = Number(text); return setBusOutputs(c, id, ids); }
      case 'set.pair': { const [id, ear] = i.split(','); const pair = [...getBus(c, id).inputPair]; pair[Number(ear)] = Number(text); return setHeadphonePair(c, id, pair); }
      case 'band.frequency': case 'band.gainDb': case 'band.q': c.outputs[eqOpen].bands[Number(i)][f.slice(5)] = number(text, 'Band'); return mirrorLinkedEq(c, eqOpen);
      case 'bass.xover': return applyCrossover(c, mains(c), number(text, 'Crossover'));
      case 'lfe.lowpassHz': c.lfe.lowpassHz = number(text, 'LFE low-pass'); return null;
      case 'lfe.trimDb': c.lfe.trimDb = number(text, 'LFE level'); return null;
      case 'lfe.input': c.sends[c.lfe.input].fill(null); c.sends[Number(text)].fill(null); c.lfe.input = Number(text); return null;
      case 'headroom': c.headroomDb = number(text, 'Level into the processing'); return null;
      case 'route.role': setOutputRole(c, Number(i), text); return null;
      case 'route.move': { const to = Number(text), from = Number(i); if (to === from) return null; route = {row: to, col: null}; if (eqOpen === from) eqOpen = to; else if (eqOpen === to) eqOpen = from; return swapOutputs(c, from, to); }
      default: return null;
    }
  });
}

const STEPS = {'bass.xover': 5, 'lfe.lowpassHz': 5, 'lfe.trimDb': 0.5, headroom: 0.5};
function bassStep(f, direction) {
  const c = config, m = mains(c);
  const current = f === 'bass.xover' ? (m.length ? c.inputs[m[0]].highpassHz : 80) : f === 'lfe.lowpassHz' ? c.lfe.lowpassHz : f === 'lfe.trimDb' ? c.lfe.trimDb : c.headroomDb;
  setField(f, '', String(Math.round((current + direction * STEPS[f]) * 10) / 10));
}
function bandStep(key, direction) {
  const b = config.outputs[eqOpen].bands[band];
  const next = key === 'frequency' ? Math.max(20, Math.min(20000, b.frequency * 2 ** (direction / 12)))
    : key === 'gainDb' ? Math.max(-18, Math.min(18, b.gainDb + direction * 0.5)) : Math.max(0.1, Math.min(18, b.q * 1.1 ** direction));
  setField(`band.${key}`, String(band), String(Math.round(next * 100) / 100));
}

function previewAlign() {
  const distances = config.outputs.map((_, i) => parseDistance(align.text[i]));
  if (distances.some(Number.isNaN)) { align.preview = null; align.error = 'A distance is a number, like 2.5.'; return; }
  try { align.preview = delaysFromDistances(distances, align.unit); align.error = ''; }
  catch (e) { align.preview = null; align.error = e.message; return; }
  const held = align.preview.limited.map(i => config.outputs[i].label);
  align.note = held.length ? `${held.join(', ')}: more than 10 ms would be needed, so ${held.length === 1 ? 'it is' : 'they are'} held at 10 ms and will arrive early.` : '';
}

function openExport() {
  exportState = {scope: eqOpen === null ? 'all' : 'one', name: ''};
  renderExport();
  $('#export-dialog').showModal();
}
function renderExport() {
  const one = exportState.scope === 'one' && eqOpen !== null;
  const file = exportEq(config, one ? [eqOpen] : null), text = JSON.stringify(file, null, 2);
  const name = exportState.name || `${presetSlug(config.name) || 'preset'}-eq${one ? `-out${eqOpen + 1}` : ''}`;
  exportState.text = text; exportState.file = `${name.replace(/[^A-Za-z0-9 ._-]/g, '-')}.json`;
  $('#export-dialog').innerHTML = `<div class="ask"><div class="row-head"><strong class="title">Export EQ</strong><button type="button" data-export="close">Close</button></div>
    ${eqOpen === null ? '' : `<div class="segmented" role="group" aria-label="What to export"><button type="button" data-export="one" aria-pressed="${one}">${esc(config.outputs[eqOpen].label)} only</button><button type="button" data-export="all" aria-pressed="${!one}">All 16 outputs</button></div>`}
    <span class="muted">${one ? `The sixteen bands of ${esc(config.outputs[eqOpen].label)}.` : 'The sixteen bands of every output.'} Import EQ reads this file back, one output at a time.</span>
    <label class="stack">What goes in the file<textarea rows="9" readonly>${esc(text)}</textarea></label>
    <label class="stack">File name<input type="text" id="export-name" value="${esc(name)}"></label>
    <div class="toolbar"><button type="button" class="primary" data-export="download">Download</button><span class="muted">Saves as ${esc(exportState.file)}</span></div></div>`;
}

// ------------------------------------------------------------------ events

function act(name, v, i) {
  const c = config;
  switch (name) {
    case 'undo': undo(); return;
    case 'redo': redo(); return;
    case 'clear-clips': Object.values(holds).forEach(hold => hold.clearClips()); if (meterShown) for (const bank of Object.values(meterShown)) bank?.forEach(channel => { channel.clip = false; }); drawMeters(); return;
    // Outputs
    case 'pol': edit(d => { d.outputs[i].invert = !d.outputs[i].invert; }); return;
    case 'onoff': edit(d => { d.outputs[i].mute = !d.outputs[i].mute; }); return;
    case 'eq-open': eqOpen = eqOpen === i ? null : i; band = 0; eqImport = null; render(); return;
    case 'eq-close': eqOpen = null; eqImport = null; render(); return;
    case 'eq-prev': gotoEq(-1); return;
    case 'eq-next': gotoEq(1); return;
    case 'eq-toggle': edit(d => { d.outputs[eqOpen].eqEnabled = !d.outputs[eqOpen].eqEnabled; return mirrorLinkedEq(d, eqOpen); }); return;
    case 'eq-bypass': edit(d => setEqBypass(d, !d.eqBypass)); return;
    case 'eq-reset-all': confirmResetAll = true; render(); return;
    case 'eq-reset-all-cancel': confirmResetAll = false; render(); return;
    case 'eq-reset-all-go': confirmResetAll = false; edit(d => resetEq(d, null)); return;
    case 'eq-reset': edit(d => mirrorLinkedEq(resetEq(d, eqOpen), eqOpen)); return;
    case 'eq-copy': eqClipboard = {label: c.outputs[eqOpen].label, eqEnabled: c.outputs[eqOpen].eqEnabled, bands: clone(c.outputs[eqOpen].bands)}; render(); return;
    case 'eq-paste': if (eqClipboard) edit(d => { d.outputs[eqOpen].bands = clone(eqClipboard.bands); d.outputs[eqOpen].eqEnabled = eqClipboard.eqEnabled; return mirrorLinkedEq(d, eqOpen); }); return;
    case 'eq-link': edit(d => setBusEqLink(d, v, !getBus(d, v).linkEq)); return;
    case 'eq-export': openExport(); return;
    case 'eq-import': eqImport = eqImport ? null : {text: '', error: '', note: '', ready: false, bands: null}; render(); return;
    case 'eq-import-run': if (eqImport?.bands) { const bands = eqImport.bands; eqImport = null; edit(d => { d.outputs[eqOpen].bands = clone(bands); d.outputs[eqOpen].eqEnabled = true; return mirrorLinkedEq(d, eqOpen); }); } return;
    case 'band-pick': band = Number(v); render(); return;
    case 'band-toggle': edit(d => { const b = d.outputs[eqOpen].bands[band]; b.enabled = !b.enabled; return mirrorLinkedEq(d, eqOpen); }); return;
    case 'band-type': edit(d => { d.outputs[eqOpen].bands[band].type = v; return mirrorLinkedEq(d, eqOpen); }); return;
    case 'band-reset': edit(d => { d.outputs[eqOpen].bands[band] = resetBand(d.outputs[eqOpen].bands[band], band); return mirrorLinkedEq(d, eqOpen); }); return;
    case 'band-step': { const [key, direction] = v.split(','); bandStep(key, Number(direction)); return; }
    case 'align-open': align.open = !align.open; if (align.open) previewAlign(); render(); return;
    case 'align-close': align.open = false; render(); return;
    case 'align-unit': align.unit = v; previewAlign(); render(); return;
    case 'align-apply': if (align.preview) { const delays = align.preview.delays; edit(d => { delays.forEach((ms, n) => { if (ms !== null) d.outputs[n].delayMs = ms; }); }); } return;
    // Routing
    case 'route-cell': { const [row, col] = v.split(',').map(Number); route = {row, col}; render(); return; }
    case 'route-row': route = route.row === Number(v) && route.col === null ? {row: null, col: null} : {row: Number(v), col: null}; render(); return;
    case 'route-col': route = route.row === null && route.col === Number(v) ? {row: null, col: null} : {row: null, col: Number(v)}; render(); return;
    case 'route-feed': { const [row, col] = v.split(',').map(Number); edit(d => { d.outputs[row].source = col; const owner = d.buses.find(bus => bus.outputIds.includes(row)); if (owner) owner.layoutId = 'custom'; }); return; }
    case 'route-pair': { const [id, ear, col] = v.split(','); edit(d => { const pair = [...getBus(d, id).inputPair]; pair[Number(ear)] = Number(col); return setHeadphonePair(d, id, pair); }); return; }
    case 'route-toggle': { const [f, key] = v.split(';'); const x = crosspoint(c, route.row, route.col); setField(f, key, x.on ? 'off' : '0'); return; }
    // Speakers & headphones
    case 'set-detail': setDetail = setDetail === v ? null : v; render(); return;
    case 'set-add-phones': { const freeIds = c.outputs.map((o, n) => o.busId === null ? n : null).filter(n => n !== null); let n = 1, id = 'headphones'; while (c.buses.some(bus => bus.id === id)) { n += 1; id = `headphones-${n}`; } if (edit(d => createHeadphoneBus(d, id, freeIds.slice(-2)))) setDetail = id; return; }
    case 'set-remove': edit(d => removeBus(d, v)); return;
    case 'set-link': edit(d => setBusEqLink(d, v, !getBus(d, v).linkEq)); return;
    case 'set-clear-level': edit(d => setBusGainMute(d, v, 0, false)); return;
    // Bass management
    case 'bass-toggle': edit(d => { d.bassEnabled = !d.bassEnabled; }); return;
    case 'bass-hp': edit(d => { d.inputs[Number(v)].crossover = !d.inputs[Number(v)].crossover; }); return;
    case 'bass-slope': edit(d => { for (const n of mains(d)) d.inputs[n].slope = Number(v); }); return;
    case 'lfe-slope': edit(d => { d.lfe.slope = Number(v); }); return;
    case 'bass-step': { const [f, direction] = v.split(','); bassStep(f, Number(direction)); return; }
    // New preset and layout
    case 'new-open': chooser = {mode: 'new', layoutId: null, name: 'New preset', error: ''}; ptab = 'outputs'; tab = 'processor'; render(); return;
    case 'layout-open': chooser = {mode: 'layout', layoutId: null, name: '', error: ''}; render(); return;
    case 'chooser-close': chooser = null; render(); return;
    case 'chooser-layout': chooser.layoutId = v; chooser.error = ''; render(); return;
    case 'chooser-blank': case 'chooser-go': {
      if (chooser.mode === 'layout') {
        const main = c.buses.find(bus => bus.kind === 'speakers'), layout = LAYOUTS.find(l => l.id === chooser.layoutId);
        const freeIds = c.outputs.map((o, n) => o.busId === null ? n : null).filter(n => n !== null);
        const ids = [...main.outputIds, ...freeIds].slice(0, Math.max(main.outputIds.length, layout.routing.length));
        if (edit(d => { const next = applyBusLayout(d, main.id, layout.id, ids); next.bassEnabled = layout.subs > 0 && next.bassEnabled; return next; })) { chooser = null; eqOpen = null; }
        return;
      }
      const taken = Object.keys(presetStore.cache || {}), title = chooser.name.trim();
      const problem = nameProblem(title, taken);
      if (problem) { chooser.error = problem; render(); return; }
      try {
        const made = name === 'chooser-blank' ? blankConfig(title) : (() => { const d = applyLayout(createConfig(), chooser.layoutId); d.name = title; return validateConfig(d); })();
        adopt(made, {isFresh: true}); editedSinceLoad = true; render();
      } catch (e) { chooser.error = e.message; render(); }
      return;
    }
    // System
    case 'big-toggle': prefs = {...prefs, big: !prefs.big}; if (!savePrefs(prefs)) toast('This browser will not remember the setting.'); render(); return;
    case 'sys-action': runAction(v); return;
    case 'sf-start': if (monitor && monitor.limits.start !== v) changeLimits({start: v}); return;
    case 'sf-lock': if (monitor) changeLimits({lock: !monitor.limits.lock}); return;
    case 'preset-run': { const [kind, target] = v.split(';'); runPreset(kind, target); return; }
    case 'preset-open': openPreset(v); return;
    case 'preset-rename': renamePreset(v); return;
    case 'preset-duplicate': duplicatePreset(v); return;
    case 'preset-export': download(`${presetSlug(v) || 'preset'}.json`, JSON.stringify(presetStore.cache[v], null, 2)); return;
    case 'preset-remove': removeListed(v); return;
    case 'log-refresh': loadLogs(); return;
    case 'log-copy': navigator.clipboard?.writeText(logLive[logService] || '').then(() => toast('Log copied.'), () => toast('This browser did not allow copying. Select the text instead.')); return;
    default:
  }
}

document.addEventListener('click', event => {
  for (const menu of document.querySelectorAll('details.menu[open]')) if (!menu.contains(event.target) || event.target.closest('.menu-items button')) menu.open = false;
  const b = event.target.closest('button');
  if (!b || b.disabled) return;
  if (b.dataset.tab) { tab = b.dataset.tab; if (tab === 'control' || tab === 'system') refreshMonitor(); render(); return; }
  if (b.dataset.cr) { controlClick(b.dataset.cr, event); return; }
  if (b.dataset.ptab) { ptab = b.dataset.ptab; render(); return; }
  if (b.dataset.bar) { ({discard: discardChanges, keep: keepLive, apply: () => applyDraft(), 'save-as': () => applyDraft({saveAs: true}), save: saveOnly})[b.dataset.bar](); return; }
  if (b.dataset.export) {
    if (b.dataset.export === 'close') $('#export-dialog').close();
    else if (b.dataset.export === 'download') { download(exportState.file, exportState.text); $('#export-dialog').close(); }
    else { exportState.scope = b.dataset.export; renderExport(); }
    return;
  }
  if (b.dataset.act) {
    const d = b.dataset;
    // A segmented group names its target in the action: "set-mode:<id>".
    if (d.act.startsWith('set-mode:')) { const id = d.act.slice(9); edit(c => setHeadphoneMode(c, id, d.v)); return; }
    act(d.act, d.v, d.i === undefined || d.i === '' ? undefined : Number(d.i));
  }
});

document.addEventListener('change', async event => {
  const el = event.target;
  if (el.id === 'log-service') { logService = el.value; render(); return; }
  if (el.id === 'preset-import') { const file = el.files[0]; el.value = ''; if (file) importPresetFile(file); return; }
  if (el.id === 'eq-import-file') {
    const file = el.files[0]; if (!file || !eqImport) return;
    try { if (file.size > 200000) throw new Error('The file is too large to be an EQ'); eqImport.text = await file.text(); }
    catch (e) { eqImport.error = e.message; }
    checkImport(); render(); return;
  }
  if (el.dataset.f) setField(el.dataset.f, el.dataset.i ?? '', el.value);
  if (el.dataset.m) controlField(el.dataset.m, el.dataset.v ?? '', el.value);
});

function checkImport() {
  if (!eqImport) return;
  try { const result = importEq(eqImport.text); Object.assign(eqImport, {bands: result.bands, ready: true, error: '', note: `${result.count} band${result.count === 1 ? '' : 's'} from ${result.source === 'REW' ? 'REW' : 'an EQ file'}, ready to import. The other bands are switched off or flat.`}); }
  catch (e) { Object.assign(eqImport, {bands: null, ready: false, error: eqImport.text.trim() ? e.message : '', note: ''}); }
}

document.addEventListener('input', event => {
  const el = event.target;
  if (el.id === 'log-filter') { logQuery = el.value; requestRender(); return; }
  if (el.id === 'chooser-name' && chooser) { chooser.name = el.value; return; }
  if (el.dataset.m === 'group-name' && crGroupEdit) { crGroupEdit.name = el.value; return; }
  if (el.id === 'export-name' && exportState) { exportState.name = el.value.trim(); const pos = el.selectionStart; renderExport(); const again = $('#export-name'); again.focus(); again.setSelectionRange(pos, pos); return; }
  if (el.id === 'eq-import-text' && eqImport) {
    eqImport.text = el.value; checkImport();
    const note = $('#eq-import-note'); note.textContent = eqImport.error || eqImport.note; note.className = eqImport.error ? 'warn-text' : 'muted';
    $('#eq-import-run').disabled = !eqImport.ready; return;
  }
  if (el.dataset.align !== undefined) {
    align.text[Number(el.dataset.align)] = el.value; previewAlign();
    config.outputs.forEach((_, i) => { const node = document.getElementById(`align-ms-${i}`); if (node) { const ms = align.preview?.delays?.[i]; node.textContent = ms === null || ms === undefined ? '' : `${msText(ms)} ms`; } });
    const note = $('#align-note'); note.textContent = align.error || align.note || 'A delay is at most 10 ms, about 3.4 m (11 ft) of difference.'; note.className = align.error ? 'warn-text' : 'muted';
    document.querySelector('[data-act="align-apply"]').disabled = !align.preview || align.preview.farthest === null || Boolean(align.error);
  }
});

document.addEventListener('keydown', event => {
  const typing = event.target.matches?.('input, textarea, select');
  if (event.key === 'Escape' && eqDrag) { event.preventDefault(); endEqDrag(true); render(); return; }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z' && !typing && tab === 'processor' && !document.querySelector('dialog[open]')) {
    event.preventDefault(); if (event.shiftKey) redo(); else undo(); return;
  }
  // Enter in a field takes the value, as leaving the field does.
  if (event.key === 'Enter' && event.target.matches?.('input[data-f], input[data-m]')) { event.target.blur(); return; }
  if (tab === 'control' && controlKey(event, typing)) return;
  const node = event.target.closest?.('[data-eq-node]');
  if (!node || node.disabled || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
  event.preventDefault();
  const index = Number(node.dataset.eqNode), b = config.outputs[eqOpen].bands[index];
  if (index !== band) { band = index; render(); return; }
  if (!b.enabled) return;
  // A run of nudges on one band is one step to undo.
  const key = `${eqOpen}:${index}`;
  if (nudgeKey !== key) { history.record(clone(config)); nudgeKey = key; }
  const dx = event.key === 'ArrowRight' ? 1 / 600 : event.key === 'ArrowLeft' ? -1 / 600 : 0, dy = event.key === 'ArrowUp' ? -1 / 480 : event.key === 'ArrowDown' ? 1 / 480 : 0;
  config.outputs[eqOpen].bands[index] = dragEqBand(b, dx, dy, event.metaKey || event.ctrlKey);
  linkEq(); markDraft(); render();
});

// --------------------------------------------------- the control service
//
// The page is fully usable with no device. One slow poll keeps the state
// current; the service publishes a cached snapshot, so the poll costs the
// device the same for one browser or ten.

let pollTimer = null;
onAccessProblem(problem => { access = problem; renderChrome(); });

async function pollHealth() {
  const read = await readHealth();
  if (read.access) {
    // Signed out, refused or rate-limited: the service is there, so the page
    // stays connected on its last snapshot. A later good read clears it.
    access = read.access; renderChrome(); return;
  }
  access = null;
  const next = read.health, wasConnected = Boolean(health), before = JSON.stringify(health?.profile);
  health = next;
  if (!wasConnected && next) {
    if (rebootRequested) { rebootRequested = false; actionLocal = null; toast('The Pi is back.'); }
    await adoptStore(piStore());
    followLivePreset(next);
  } else if (wasConnected && !next) {
    toast(shutdownRequested ? 'The device has powered off. When its lights stop, unplug the USB cable, then the network cable.'
      : rebootRequested ? 'The Pi is rebooting. This page reconnects by itself when it answers again; your draft is still here.'
      : 'Lost the device. Your draft is still here; presets are back in this browser.');
    shutdownRequested = false; meterShown = null;
    await adoptStore(browserStore(storageKey));
  } else if (next && before !== JSON.stringify(next.profile)) {
    // The running preset changed (from here or elsewhere): the list of presets may have too.
    try { await presetStore.refresh(); } catch { /* the next poll tries again */ }
    followLivePreset(next);
  }
  if (next?.apply && !applyPoll) {
    applyStatus = null; // the snapshot is the truth while nothing of ours is running
    if (next.apply.inFlight || next.apply.pending) startApplyPolling();
  }
  if (!next) { liveQueue.cancel(); liveLastSent = null; sender.cancel(); overlay.clear(); monitor = null; }
  // The Control Room is drawn only while the device offers it.
  if (tab === 'control' && !monitorOffered(next)) { tab = 'status'; render(); }
  if (tab === 'system' && monitorKind(next, 'monitor-limits')) refreshMonitor();
  // Self-heal: the engine runs something other than what this page last
  // sent, and nothing is pending or in flight: send the draft again.
  const foreign = next?.dspLive?.state === 'applied' && liveLastSent && next.dspLive.sha256 !== liveLastSent ? next.dspLive.sha256 : null;
  liveForeignSeen = foreign && foreign === liveForeignSeen.sha ? {sha: foreign, polls: liveForeignSeen.polls + 1} : {sha: foreign, polls: foreign ? 1 : 0};
  if (foreign && liveForeignSeen.polls >= 2 && Date.now() - liveLastReceiptAt > 3000 && foreign !== liveAnsweredForeign
      && !liveQueue.busy && !next.apply?.pending && !next.apply?.inFlight && effectiveLive().state === 'live') {
    liveAnsweredForeign = foreign; liveLastSent = null;
    scheduleLive();
  }
  renderLive();
}

/** Swap the preset store, keeping the page usable if the new one cannot be read. */
async function adoptStore(store) {
  try { await store.refresh(); presetStore = store; }
  catch (e) { toast(`Could not read the presets from ${store.label}: ${e.message}`); return; }
  render();
}

function startPolling() {
  if (pollTimer) return;
  pollHealth();
  // Pause while the tab is hidden: an idle page should not keep the device busy.
  pollTimer = setInterval(() => { if (!document.hidden) pollHealth(); }, POLL_MS);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) pollHealth(); });

render();
startPolling();
