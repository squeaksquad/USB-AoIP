import { CHANNELS, createConfig, validateConfig, parsePreset, setOutputRole, bandResponse, eqResponse, subSumBoundDb } from './model.mjs';
import { LAYOUTS, currentLayout, applyLayout, swapOutputs, applyCrossover, copyChannel, pasteChannel, parseRew, dragEqBand, EQ_RANGE_DB, serviceCommands, journalCommand } from './workflows.mjs';
import { resetBand } from './reset-band.mjs';
import { getBus, applyBusLayout, setBusGainMute, setHeadphoneMode, setHeadphonePair, setHeadphoneMatrix, createHeadphoneBus, createSpeakerBus, removeBus, setBusEqLink, setBusOutputs, outputRoleLabel, speakerGroupSourceIds } from './buses.mjs';
import { resetEq, setEqBypass, linkedEqOutputs, mirrorLinkedEq } from './eq-tools.mjs';
import { createSlots, switchSlot, copySlot, slotSummary, SLOTS } from './profiles.mjs';
import { polarityNote } from './crossover-notes.mjs';
import { probeHealth, fetchLogs, connectionLine, systemFacts, dspNote, browserStore, piStore, POLL_MS, requestProfile, fetchApplyStatus, applyFinished, applyLine, applyStepLabel, profileChoices, APPLY_POLL_MS, compileDraft, presetSummary, requestPreset, removePreset, userPresets, fetchMeters, meterLevels, METER_POLL_MS, liveState, requestLive, requestCommit, awaitReceipt, requestShutdown, stackTerms } from './backend.mjs';
import { LiveQueue } from './live.mjs';

let config = createConfig(), selected = 0, tab = 'outputs', metersRunning = true, dirty = true;
let channelClipboard = null, pasteScope = 'processing', layoutUndo = null, rewParsed = null;
let crossoverScope = 'all', crossoverHz = '80', busUndo = null, bassBoxOpen = false;
const crossoverSelection = new Set();
let selectedBand = 0, eqDrag = null, eqObserver;
let logService = 'all', logQuery = '';
// Live state from the Pi control service; null whenever no backend answers.
let health = null, logBusy = false;
// The bridge's meter tap: the last window read, when, and a clip hold per strip.
let liveMeters = null, liveMetersAt = 0, meterBusy = false;
const clipHold = {inputs: new Array(16).fill(0), outputs: new Array(16).fill(0)};
const clipSeen = {inputs: new Array(16).fill(null), outputs: new Array(16).fill(null)};
// Staged Apply (Settings): the chosen target, the last status seen, and the poll that follows an operation.
let applyChoice = '', applyStatus = null, applyBusy = false, applyPoll = null, shutdownRequested = false;
// Live coefficient updates (LIVE_COEFFICIENTS_DESIGN.md step 5): the draft's
// shape key from its last compile, what the bridge last took from this page,
// and the debounced one-in-flight queue that carries edits to the Pi.
let draftShapeKey = null, liveLastSent = null, liveLine = '';
// Foreign coefficients the page has already answered once: another author
// (a second tab, a test pusher) may keep the bridge on something else, and
// the page re-sends its draft once per such state, never in a loop.
let liveAnsweredForeign = null;
// The self-heal must not act on one stale health poll: a disagreement has to
// be seen on two consecutive polls with the same hash, and never within a
// few seconds of the page's own last receipt (health lags the bridge by up
// to one poll, and that lag looked like a foreign author on 2026-09-13).
let liveForeignSeen = {sha: null, polls: 0}, liveLastReceiptAt = 0, liveRetryTimer = null;
// Whether the user has touched the draft since the page loaded: a draft the
// user has not edited follows the live user preset's saved UI configuration.
let editedSinceLoad = false;
const liveQueue = new LiveQueue({
  send: async ({artifact, sha256, expectedProfile, expectedLiveSha256}) => {
    const result = await requestLive(artifact, expectedProfile, expectedLiveSha256);
    liveLastSent = sha256;
    // The applier is one process per request and the service refuses a new
    // one while the previous is pending: wait for this receipt before the
    // queue may send the next edit.
    await awaitReceipt(result.id, undefined, {timeoutMs: 15000});
    liveLastReceiptAt = Date.now();
    return result;
  },
  onSettled: outcome => {
    liveLine = outcome.ok ? `Applied (${outcome.draft.sha256.slice(0, 8)}).` : `Live update refused: ${outcome.error.message}`;
    if (!outcome.ok) {
      toast(liveLine);
      // A stale expectation (the bridge moved under us): forget what we
      // last sent so the next edit, or the self-heal, carries the bridge's
      // current hash instead of ours.
      if (/expected live coefficients/.test(outcome.error.message)) {
        liveLastSent = null;
        // One automatic retry after the next health poll, which then carries
        // the bridge's current hash; the draft is unchanged, so this is the
        // same edit sent with the right expectation.
        clearTimeout(liveRetryTimer);
        liveRetryTimer = setTimeout(() => { liveRetryTimer = null; if (!liveQueue.busy) scheduleLive(); }, 1300);
      }
    }
    renderLiveState();
    if (outcome.ok) startApplyPolling();
  },
});
const logLive = {all:'',stack:'',usb:''};
/** The words for the stack this Pi runs (AES67 or Dante); see stackTerms. */
const terms = () => stackTerms(health);
let profileState = null;
// Each slot remembers whether its draft was saved, so recalling one does not read as edited.
const slotDirty = { A: true, B: true };
// Collapsible page sections: open on desktop, collapsed on narrow screens, then user-controlled.
const sectionOpen = { buses: true, bass: true };
const sectionAttr = name => sectionOpen[name] ? 'open' : '';
const logSnapshots = {all:'',stack:'',usb:''};
const bandColors = ['#f39364','#e6b35c','#d9d464','#add875','#6bdaa3','#65d5c8','#68b8eb','#849af3','#aa92ec','#cd8ee0','#e486b9','#ed8694','#c6ac83','#95b9aa','#a6add5','#b6c878'];
const storageKey = 'usb16x16-design-presets-v1';
const $ = selector => document.querySelector(selector);
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pad = i => String(i + 1).padStart(2, '0');
const checked = v => v ? 'checked' : '';
const disabled = v => v ? 'disabled' : '';
const options = (items, value) => items.map(([v, label]) => `<option value="${esc(v)}" ${String(v) === String(value) ? 'selected' : ''}>${esc(label)}</option>`).join('');
const number = (attrs, value, min, max, step = 1) => `<input type="number" ${attrs} value="${value}" min="${min}" max="${max}" step="${step}"${attrs.includes('data-downmix')?'':' required'}>`;
const field = (label, content) => `<label class="field"><span>${label}</span>${content}</label>`;
const inputOptions = () => config.inputs.map((v, i) => [i, `${pad(i)} · ${v.label}`]);
let toastTimer;
function toast(message) { $('#toast').textContent = message; $('#toast').classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('#toast').classList.remove('show'), 4500); }
// Presets come from the Pi when its control service answers and from browser
// storage otherwise. The store keeps a synchronous cache so render stays sync.
let presetStore = browserStore(storageKey);
function presets() { return presetStore.cache; }
async function savePreset() {
  try {
    validateConfig(config);
    await presetStore.save(config.name, structuredClone(config));
    dirty = false; render();
    toast(`Preset "${config.name}" saved on ${presetStore.label}.`);
  } catch (e) { toast(`Could not save: ${e.message}`); }
}
async function deletePreset(name) {
  try { await presetStore.remove(name); render(); toast(`Deleted "${name}" from ${presetStore.label}.`); }
  catch (e) { toast(`Could not delete: ${e.message}`); }
}
function markDraft() { dirty = true; editedSinceLoad = true; $('#draft-status').textContent = 'Draft · unsaved'; liveAnsweredForeign = null; scheduleLive(); }

/** The saved UI preset that belongs to the live user profile, if any: the
 *  Pi store entry whose name slugs to the profile's slug. */
function presetForLiveProfile(next) {
  const live = profileChoices(next).live;
  if (!live?.user) return null;
  const slug = live.name.replace(/^(user|dante)-/, '');
  const entry = Object.entries(presetStore.cache || {}).find(([name]) => presetSlug(name) === slug);
  return entry ? {name: entry[0], document: entry[1]} : null;
}

/** On connecting to a live user preset, an untouched draft becomes its saved
 *  configuration, so the page shows what the bridge runs. */
function followLivePreset(next) {
  if (editedSinceLoad) return;
  const found = presetForLiveProfile(next);
  if (!found) return;
  try {
    const document = validateConfig(structuredClone(found.document));
    config = document; selected = Math.min(selected, CHANNELS - 1); dirty = false; draftShapeKey = null;
    render();
    toast(`Showing "${found.name}", the configuration saved with the live preset.`);
  } catch (e) { toast(`The saved configuration for ${found.name} could not be loaded: ${e.message}`); }
}

/** Keep the UI configuration on the Pi in step with what was committed or
 *  applied, under the draft's name, so a reload can find it. */
async function saveDraftWithPreset(reason) {
  // The Pi store's name rule is letters, digits, spaces, dots and dashes;
  // the shipped draft's middle dot is not among them, and the store name
  // only has to slug to the profile's slug to be found again.
  const name = String(config.name).replace(/[^A-Za-z0-9 ._-]/g, '-').replace(/\s+/g, ' ').trim() || 'preset';
  try { validateConfig(config); await presetStore.save(name, structuredClone(config)); dirty = false; render(); toast(`Configuration saved on the Pi as "${name}" with the ${reason}.`); }
  catch (e) { toast(`Could not save the configuration with the ${reason}: ${e.message}`); }
}

/** Every edit: compile in the fixed shape and, when the running preset has the
 *  same shape, hand the numbers to the bridge through the debounced queue. */
async function scheduleLive() {
  if (!health || config.mode === 'direct') return;
  const before = liveState(health, null);
  if (before.state !== 'live') return;
  let compiled;
  try { validateConfig(config); compiled = await compileDraft(config); }
  catch (e) { liveLine = `Not sent: ${e.message}`; renderLiveState(); return; }
  draftShapeKey = compiled.shapeKey;
  const state = liveState(health, draftShapeKey);
  renderLiveState();
  if (state.state !== 'live') { liveQueue.cancel(); return; }
  const sha256 = compiled.sha256;
  if (sha256 === (liveLastSent || state.liveSha256)) return;
  liveQueue.submit({artifact: compiled.artifact, sha256, expectedProfile: state.profile,
                    expectedLiveSha256: liveLastSent || state.liveSha256});
}

/** The three-state line in the EQ editor and the Settings panel. */
function liveStateHtml() {
  const state = liveState(health, draftShapeKey);
  const label = state.state === 'live' ? 'Live' : state.state === 'needs-apply' ? 'Needs apply' : 'Not previewable';
  const cls = state.state === 'live' ? 'banner-note' : state.state === 'needs-apply' ? 'banner-warn' : 'muted';
  const preview = state.previewing ? ' A preview is running that is not the installed preset: commit it to keep it, or discard it.' : '';
  return `<p id="live-state" class="${cls}" data-live-state="${state.state}"><strong>${label}.</strong> ${esc(state.reason)}${preview}${liveLine ? ` <span class="muted">${esc(liveLine)}</span>` : ''}</p>`;
}
let lastLiveStateHtml = '';
function renderLiveState() {
  const html = liveStateHtml();
  if (html === lastLiveStateHtml) return;
  lastLiveStateHtml = html;
  const node = $('#live-state');
  if (node) node.outerHTML = html;
  refreshSettingsLive();
}

function render() {
  const isDirect = config.mode === 'direct';
  for (const button of document.querySelectorAll('[data-tab]')) { const active = button.dataset.tab === tab; button.classList.toggle('active', active); button.setAttribute('aria-current', active ? 'page' : 'false'); }
  for (const name of ['outputs', 'settings']) $(`#${name}-page`).hidden = name !== tab;
  for (const button of document.querySelectorAll('[data-mode]')) { const active = button.dataset.mode === config.mode; button.classList.toggle('active', active); button.setAttribute('aria-pressed', active); }
  for (const button of document.querySelectorAll('[data-source]')) { const active = button.dataset.source === config.source; button.classList.toggle('active', active); button.setAttribute('aria-pressed', active); button.disabled = isDirect; }
  const words = terms();
  // The static page says "Direct bridge" and offers an AoIP source; a Dante Pi has no bridge, and its
  // endpoint filters only what the USB host sends.
  const directButton = document.querySelector('[data-mode="direct"]'); if (directButton) directButton.textContent = words.directButton;
  const aoipButton = document.querySelector('[data-source="aoip"]');
  if (aoipButton) { aoipButton.disabled = isDirect || !words.aoipSource; aoipButton.title = words.aoipSource ? '' : 'The Dante endpoint filters the USB source only'; }
  $('#flow-middle').textContent = isDirect ? `USB ↔ ${words.stack === 'dante' ? 'Dante' : 'AoIP'} transport` : 'Bass management + output DSP';
  $('#flow-detail').textContent = isDirect ? words.flowDetail : '16-band PEQ · alignment · level';
  $('#flow-output').textContent = isDirect ? '16 × 16 duplex' : `16 ${words.stack === 'dante' ? 'Dante' : 'AoIP'} outputs`;
  $('#mode-note').textContent = modeNote(isDirect);
  renderConnection();
  $('#draft-status').textContent = dirty ? 'Draft · unsaved' : `Saved on ${presetStore.label}`;
  renderSlots(); renderBuses(); renderLayout(); renderBank(); renderOverview(); renderInspector(); renderBass(); renderSettings(); updateMeters();
}

/** What the mode buttons mean, given what the Pi is actually running. */
function modeNote(isDirect) {
  const draft = isDirect
    ? 'Previewing direct mode. DSP edits are disabled; the DSP draft is retained.'
    : 'Previewing DSP mode.';
  if (!health) return `${draft} No device has been switched.`;
  const profile = health.profile?.selected ? ` on profile ${health.profile.selected}` : '';
  const running = health.mode?.running ? `The Pi is running the ${terms().transport}${profile}.` : `The Pi stack is not running: ${health.mode?.detail || 'state unknown'}.`;
  const dsp = isDirect ? '' : ` ${dspNote(health)}`;
  return `${draft} ${running} Browser edits change nothing on the Pi; profile switches go through Apply on the Settings page.${dsp}`;
}

function renderConnection() {
  $('#connection-line').textContent = connectionLine(health);
  const pill = $('#preview-pill');
  pill.lastChild.textContent = health ? ' LIVE · READ-ONLY' : ' DESIGN PREVIEW';
  pill.classList.toggle('live', Boolean(health));
  pill.title = health ? 'Connected to the Pi control service. Status and logs are live; no control endpoint exists.' : 'No Pi control service is answering.';
  const rate = health?.audio?.sampleRate;
  $('#format-line').textContent = `${(rate ?? 48000) / 1000} kHz · ${health?.audio?.inputs ?? 16} × ${health?.audio?.outputs ?? 16}`;
}

function renderSlots() {
  const summary = slotSummary(profileState, config), other = SLOTS.find(name => name !== profileState.active);
  const names = Object.keys(presets());
  const saved = names.includes(config.name) && !dirty;
  const choices = [...(saved ? [] : [['', dirty ? 'Unsaved draft' : config.name]]), ...names.map(name => [name, name])];
  $('#profile-slots').innerHTML = `<span class="overline">PROFILE</span>${summary.map(slot => `<button class="slot ${slot.active ? 'active' : ''}" data-action="slot-switch" data-slot="${slot.name}" aria-pressed="${slot.active}" title="${slot.filled ? esc(slot.label) : 'Empty · seeded from the current draft'}">${slot.name}</button>`).join('')}<button class="quiet" data-action="slot-copy" title="Overwrite slot ${other} with the current draft">Copy ${profileState.active} → ${other}</button>
    <label class="field slot-preset"><span>Preset</span><select id="slot-preset" title="${esc(saved ? config.name : dirty ? `Unsaved draft · ${config.name}` : config.name)}" aria-label="Preset loaded into slot ${profileState.active}" ${disabled(!names.length && saved)}>${options(choices, saved ? config.name : '')}</select></label>
    <small>${names.length ? `Loads a saved preset into slot ${profileState.active}` : 'Save a preset to load it into a slot'}</small>`;
}

function renderOverview() {
  const off = config.mode === 'direct';
  const roleOptions = [['speaker','Speaker'],['sub','Subwoofer'],['unused','Unused']];
  $('#channel-overview').innerHTML = `<div class="section-heading"><div><h2>Channel overview <span>level · alignment · bass · EQ</span></h2><p>Edit every output in place. Open <strong>Bass routing</strong> for per-channel crossovers and sub sends; EQ opens in its own editor.</p></div><div class="toolbar"><button class="quiet" data-action="bass-toggle" aria-expanded="${bassBoxOpen}" aria-controls="bass-matrix-box" ${disabled(off)}>${bassBoxOpen ? '▾' : '▸'} Bass routing</button><button class="quiet" data-action="eq-bypass-all" aria-pressed="${Boolean(config.eqBypass)}" ${disabled(off)}>${config.eqBypass ? 'All EQ bypassed' : 'Bypass all EQ'}</button><button class="quiet" data-action="eq-reset-all" ${disabled(off)}>Reset all EQ</button></div></div>
    <div id="bass-matrix-box" class="bass-box" ${bassBoxOpen ? '' : 'hidden'}></div>
    <fieldset ${disabled(off)} style="border:0;padding:0;margin:0;min-width:0"><div class="table-scroll"><table class="overview-table"><thead><tr><th>Out</th><th>Label</th><th>Bus</th><th>Role</th><th>Source</th><th>Gain · dB</th><th>Alignment · ms</th><th>Ø</th><th>Mute</th><th>EQ</th></tr></thead><tbody>${config.outputs.map((o, i) => {
      const owner = config.buses?.find(bus => bus.id === o.busId), headphone = owner?.kind === 'headphones';
      const active = o.bands.filter(b => b.enabled && b.gainDb !== 0).length;
      const state = config.eqBypass ? 'all off' : !o.eqEnabled ? 'off' : active ? `${active} band${active === 1 ? '' : 's'}` : 'flat';
      const stateTitle = config.eqBypass ? 'Global EQ bypass is on' : !o.eqEnabled ? 'EQ bypassed for this output' : active ? `${active} band${active === 1 ? '' : 's'} away from flat` : 'All bands flat';
      return `<tr class="${i === selected ? 'row-selected' : ''} ${o.role === 'unused' ? 'row-unused' : ''}">
        <td><button class="quiet row-select" data-select="${i}" aria-label="Select output ${i + 1}" aria-pressed="${i === selected}">${pad(i)}</button></td>
        <td><input data-out="label" data-out-index="${i}" value="${esc(o.label)}" maxlength="64" aria-label="Output ${i + 1} label" required></td>
        <td class="muted">${owner ? esc(owner.label) : '—'}</td>
        <td>${headphone ? '<span class="muted">Headphone</span>' : `<select data-out="role" data-out-index="${i}" aria-label="Output ${i + 1} role">${options(roleOptions, o.role)}</select>`}</td>
        <td>${headphone ? '<span class="muted">Bus tap</span>' : `<select data-out="source" data-out-index="${i}" aria-label="Output ${i + 1} source" ${disabled(o.role !== 'speaker')}>${options(inputOptions(), o.source)}</select>`}</td>
        <td>${number(`data-out="gainDb" data-out-index="${i}" aria-label="Output ${i + 1} gain"`, o.gainDb, -60, 12, .1)}</td>
        <td>${number(`data-out="delayMs" data-out-index="${i}" aria-label="Output ${i + 1} alignment delay"`, o.delayMs, 0, 10, .01)}</td>
        <td><button class="quiet cell-toggle" data-action="polarity" data-out-index="${i}" aria-pressed="${o.invert}" aria-label="Invert output ${i + 1} polarity">Ø</button></td>
        <td><button class="quiet cell-toggle" data-mute="${i}" aria-pressed="${o.mute}" aria-label="Mute output ${i + 1}" ${disabled(o.role === 'unused')}>M</button></td>
        <td><button class="eq-open" data-eq-open="${i}" aria-label="Open EQ for output ${i + 1}: ${stateTitle}" title="${stateTitle}">EQ<small>${state}</small></button></td></tr>`;
    }).join('')}</tbody></table></div><p class="route-note">Alignment is user-chosen speaker delay, not a processing-latency figure. Gain, alignment and mute apply to the physical output; bus level sits above them.</p></fieldset>`;
  renderBassMatrix();
}

function renderBuses() {
  const buses = config.buses || [];
  const off = config.mode === 'direct';
  const freeCount = config.outputs.filter(o=>o.busId===null).length;
  const allocated = config.outputs.filter(o=>o.busId!==null).length;
  const action = (label, content) => `<div class="field"><span class="field-spacer" aria-hidden="true">${label}</span>${content}</div>`;
  $('#bus-controls').innerHTML = `<details class="panel bus-panel page-section" data-section="buses" ${sectionAttr('buses')}><summary class="section-summary">Output buses <small>${allocated}/16 outputs allocated · ${buses.length} bus${buses.length===1?'':'es'}</small></summary>
    <div class="section-heading"><div><p>Each physical output belongs to one bus. Formats apply only to the selected bus; unrelated buses keep their routing. Bus level sits above each output's own gain.${health && !off ? ' A format change edits this draft; it runs on the Pi only after <strong>Compile &amp; apply this draft</strong> on System &amp; presets, which restarts the ' + esc(terms().service) + '.' : ''}</p></div><div class="toolbar"><button data-action="bus-add-speakers" ${disabled(off||freeCount<2)}>Add speaker bus</button><button data-action="bus-add-headphones" ${disabled(off||freeCount<2)}>Add headphones</button></div></div>
    <fieldset ${disabled(off)} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bus-list">${buses.map(bus => {
      const headphone = bus.kind === 'headphones';
      const layoutOptions = [['custom','Custom mapping'],...LAYOUTS.filter(l=>!headphone||l.routing.length===2).map(l=>[l.id,l.label])];
      return `<article class="bus-card ${headphone?'headphone-bus':''}" data-bus-card="${esc(bus.id)}">
      <header class="bus-card-title"><div><strong>${esc(bus.label)}</strong><small>${headphone?'Headphone stereo · raw tap before speaker crossovers':'Speaker bus'} · outputs ${bus.outputIds.map(i=>pad(i)).join(', ')}</small></div><button class="quiet" data-action="bus-remove" data-bus-id="${esc(bus.id)}">Remove bus</button></header>
      <div class="bus-grid">
        ${field('Bus name',`<input data-bus="${esc(bus.id)}" data-bus-param="label" value="${esc(bus.label)}" maxlength="64" aria-label="${esc(bus.label)} bus name">`)}
        ${field('Output format',`<select data-bus="${esc(bus.id)}" data-bus-param="layout" aria-label="${esc(bus.label)} output format">${options(layoutOptions,bus.layoutId||'custom')}</select>`)}
        ${action('Apply', `<button data-action="bus-apply" data-bus-id="${esc(bus.id)}" title="Changes this draft only. A bus format changes the pipeline's shape, so it reaches the Pi through Compile &amp; apply on System &amp; presets.">Apply format to draft</button>`)}
        ${field('Bus gain · dB',number(`data-bus="${esc(bus.id)}" data-bus-param="gainDb" aria-label="${esc(bus.label)} bus gain"`,bus.gainDb,-60,12,.1))}
        ${action('Mute', `<label class="checkbox-label"><input type="checkbox" data-bus="${esc(bus.id)}" data-bus-param="mute" ${checked(bus.mute)} aria-label="Mute ${esc(bus.label)} bus">Mute bus</label>`)}
      </div>
      ${headphone ? renderHeadphoneControls(bus) : ''}</article>`;
    }).join('')}</div>
    <div class="bus-budget"><strong>${allocated}/16 outputs allocated</strong><span>${freeCount} available · apply/undo is scoped per bus</span><button class="quiet" data-action="bus-undo" ${disabled(!busUndo)}>Undo last bus format</button></div></fieldset></details>`;
}

/** Every physical output, annotated with what currently owns it. */
function outputSlotOptions(busId) {
  return config.outputs.map((output, i) => {
    const owner = config.buses?.find(bus => bus.outputIds.includes(i));
    const note = !owner ? 'free' : owner.id === busId ? 'this bus' : `${owner.label} · swaps`;
    return [i, `${pad(i)} · ${output.label} (${note})`];
  });
}

function renderHeadphoneControls(bus) {
  const pairOptions = inputOptions();
  const matrix = bus.downmixMatrix || Array.from({length:16},()=>[null,null]);
  const pairOff = bus.inputMode !== 'pair';
  return `<fieldset class="bus-sub"><legend>Headphone outputs</legend>
    <div class="bus-grid">
      ${field('Left output',`<select data-bus-output="${esc(bus.id)}" data-ear="0" aria-label="${esc(bus.label)} left physical output">${options(outputSlotOptions(bus.id),bus.outputIds[0])}</select>`)}
      ${field('Right output',`<select data-bus-output="${esc(bus.id)}" data-ear="1" aria-label="${esc(bus.label)} right physical output">${options(outputSlotOptions(bus.id),bus.outputIds[1])}</select>`)}
    </div>
    <p class="hint">Defaults to the last free pair. Choosing an output held by another bus exchanges the two channels, with all processing following each one.</p></fieldset>
  <fieldset class="bus-sub"><legend>Headphone source</legend>
    <div class="bus-grid">
      <div class="field"><span>Source mode</span><div class="radio-row"><label class="checkbox-label"><input type="radio" name="headphone-mode-${esc(bus.id)}" value="pair" data-headphone-mode="${esc(bus.id)}" ${bus.inputMode==='pair'?'checked':''}>Stereo pair</label><label class="checkbox-label"><input type="radio" name="headphone-mode-${esc(bus.id)}" value="downmix" data-headphone-mode="${esc(bus.id)}" ${bus.inputMode==='downmix'?'checked':''}>Surround downmix</label></div></div>
      ${field('Left input',`<select data-headphone-pair="${esc(bus.id)}" data-ear="0" ${disabled(pairOff)}>${options(pairOptions,bus.inputPair?.[0]??0)}</select>`)}
      ${field('Right input',`<select data-headphone-pair="${esc(bus.id)}" data-ear="1" ${disabled(pairOff)}>${options(pairOptions,bus.inputPair?.[1]??1)}</select>`)}
    </div>
    <details class="downmix-editor" ${bus.inputMode==='downmix'?'open':''}><summary>Advanced downmix levels · pre-crossover input to each ear</summary><div class="table-scroll"><table><thead><tr><th>Input</th><th>Left · dB</th><th>Right · dB</th></tr></thead><tbody>${matrix.map((row,i)=>`<tr><td>${pad(i)} · ${esc(config.inputs[i].label)}${i===config.lfe.input?' · LFE':''}</td><td>${number(`data-downmix="${esc(bus.id)}" data-input-index="${i}" data-ear="0" aria-label="${esc(bus.label)} ${pad(i)} left downmix"`,row?.[0]??'',-60,12,.1)}</td><td>${number(`data-downmix="${esc(bus.id)}" data-input-index="${i}" data-ear="1" aria-label="${esc(bus.label)} ${pad(i)} right downmix"`,row?.[1]??'',-60,12,.1)}</td></tr>`).join('')}</tbody></table></div><small>Blank means this input is excluded. Levels are routing coefficients for the UI draft; no binaural processing is implied.</small></details></fieldset>`;
}

function renderLayout() {
  const current=currentLayout(config);
  $('#layout-controls').innerHTML='';
}

function renderBank() {
  $('#input-bank').innerHTML = config.inputs.map((o,i)=>`<div class="strip"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="meter" aria-hidden="true" style="display:block"><i id="input-meter-${i}"></i></span><span id="input-level-${i}" class="meter-value">—</span></div>`).join('');
  $('#channel-bank').innerHTML = config.outputs.map((o, i) => { const role = outputRoleLabel(config, i); return `<div class="strip ${o.role} ${role.kind} ${i === selected ? 'selected' : ''}">
    <button class="strip-select" data-select="${i}" aria-label="Edit output ${i + 1}: ${esc(o.label)}, ${role.long}" aria-pressed="${i === selected}"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="role-label">${role.short}</span><span class="meter" aria-hidden="true" style="display:block"><i id="meter-${i}"></i></span><span id="level-${i}" class="meter-value">—</span></button>
    <button class="mute" data-mute="${i}" aria-label="Mute output ${i + 1}" aria-pressed="${o.mute}" ${disabled(config.mode === 'direct' || o.role === 'unused')}>M</button></div>`; }).join('');
}

function renderInspector() {
  endEqDrag(true);
  eqObserver?.disconnect();
  const o = config.outputs[selected], off = config.mode === 'direct', owner = config.buses?.find(b=>b.id===o.busId), headphone = owner?.kind === 'headphones', ear = owner ? owner.outputIds.indexOf(selected) : -1;
  const bypassed = Boolean(config.eqBypass);
  const linked = headphone && Boolean(owner.linkEq);
  $('#inspector').innerHTML = `<div class="inspector-head"><div><h2 id="eq-dialog-title"><span class="badge">${pad(selected)}</span>${esc(o.label)}</h2><p>AoIP output ${selected + 1} · ${headphone ? `${ear===0?'Left ear':ear===1?'Right ear':'Headphone'} · ${esc(owner.label)}` : o.role === 'sub' ? 'Independent subwoofer correction' : o.role === 'unused' ? 'Assign a role to use this output' : 'Independent speaker correction'}</p></div>
    <div class="channel-nav" role="group" aria-label="Go to another output"><button data-action="channel-prev" aria-label="Edit the previous output" title="Previous output (Alt + ←)">◀</button><select id="channel-jump" aria-label="Edit another output" title="Open another output in this editor">${options(config.outputs.map((v,i)=>[i,`${pad(i)} · ${v.label}`]),selected)}</select><button data-action="channel-next" aria-label="Edit the next output" title="Next output (Alt + →)">▶</button></div>
    <button class="quiet" data-action="eq-close" aria-label="Close EQ editor">Close</button></div>
    ${off ? '' : liveStateHtml()}
    <fieldset class="eq-body" ${disabled(off)}>
    <div class="channel-tools"><button data-action="channel-copy">Copy channel</button><label class="field"><span>Paste scope</span><select id="paste-scope">${options([['processing','All output processing'],['eq','EQ only']],pasteScope)}</select></label><button data-action="channel-paste" ${disabled(!channelClipboard)}>Paste${channelClipboard?` from ${esc(channelClipboard.label)}`:''}</button><button data-action="rew-open">Import REW EQ</button>${field('Swap with output', `<select id="out-destination" title="Exchange this channel with another physical output, including processing and bass sends">${options(config.outputs.map((v,i)=>[i,`${pad(i)} · ${v.label}${i===selected?' (this one)':''}`]),selected)}</select>`)}<small>Copy/paste moves EQ, gain, delay, mute and polarity. Swapping exchanges two physical outputs, routing included.</small></div>
    <div class="eq-title"><div><h3>Parametric EQ <span class="muted">/ 16 bands</span></h3><p>Calculated PEQ response only · excludes crossovers, output gain and room response</p></div>
      <div class="toolbar eq-scope"><button class="quiet" data-action="eq-toggle" aria-pressed="${o.eqEnabled}">${o.eqEnabled ? 'EQ enabled' : 'EQ bypassed'}</button><button class="quiet" data-action="eq-bypass-all" aria-pressed="${bypassed}" title="Bypass every output PEQ; per-output enables are retained">${bypassed ? 'All EQ bypassed' : 'Bypass all EQ'}</button><button class="quiet" data-action="eq-reset-output" title="Reset all 16 bands of this output">Reset EQ</button><button class="quiet" data-action="eq-reset-all" title="Reset every band of all 16 outputs">Reset all</button>${headphone ? `<button class="quiet" data-action="eq-link" data-bus-id="${esc(owner.id)}" aria-pressed="${linked}" title="Apply headphone EQ edits to both ears">${linked ? 'Ears linked' : 'Link ears'}</button>` : ''}</div></div>
    ${bypassed ? '<p class="banner-warn">Global EQ bypass is on. Bands stay editable and return exactly as set when it is switched off.</p>' : ''}
    ${linked ? '<p class="banner-note">Headphone ears are linked: every band edit, reset and EQ enable applies to both outputs. Gain, alignment, mute and polarity stay independent.</p>' : ''}
    <div class="eq-workspace">
      <div class="eq-display" id="eq-display">
        <svg id="eq-chart" class="eq-chart" role="img" aria-label="Calculated output PEQ magnitude response, 20 Hz to 20 kHz"></svg>
        <div class="eq-nodes">${o.bands.map((b,i)=>`<button type="button" class="eq-node" data-eq-node="${i}" style="--band-color:${bandColors[i]}" aria-describedby="eq-help">${i+1}</button>`).join('')}</div>
        <span class="eq-plot-caption">OUTPUT PEQ <span>±${EQ_RANGE_DB} dB</span></span>
      </div>
      <div class="band-bar-wrap"><span class="band-bar-label">Bands</span><div id="band-bar" class="band-bar" role="group" aria-label="Select an EQ band"></div></div>
      <div id="selected-eq-band" class="selected-eq-band"></div>
      <p id="eq-help" class="eq-help">Drag a band: frequency / gain · <kbd>⌘ Cmd</kbd> + drag up/down: Q · Double-click a band: reset · Arrow keys: fine adjust · Esc: cancel drag</p>
    </div>
    <div class="eq-bands">${[0,8].map(start=>`<div class="table-scroll"><table class="band-table" aria-label="EQ bands ${start+1}–${start+8}"><thead><tr><th>Band</th><th>On</th><th>Filter</th><th>Frequency · Hz</th><th>Gain · dB</th><th>Q</th><th>Reset</th></tr></thead><tbody>${o.bands.slice(start,start+8).map((b,n) => { const i=start+n; return `<tr class="${b.enabled ? '' : 'band-disabled'}"><td>${pad(i)}</td><td><input type="checkbox" data-band="${i}" data-param="enabled" aria-label="Band ${i+1} enabled" ${checked(b.enabled)}></td><td><select data-band="${i}" data-param="type" aria-label="Band ${i+1} filter">${options([['bell','Bell'],['lowShelf','Low shelf'],['highShelf','High shelf']],b.type)}</select></td><td>${number(`data-band="${i}" data-param="frequency" aria-label="Band ${i+1} frequency"`,b.frequency,20,20000,'any')}</td><td>${number(`data-band="${i}" data-param="gainDb" aria-label="Band ${i+1} gain"`,b.gainDb,-18,18,'any')}</td><td>${number(`data-band="${i}" data-param="q" aria-label="Band ${i+1} Q"`,b.q,.1,18,'any')}</td><td><button type="button" class="quiet band-reset" data-band-reset="${i}" aria-label="Reset band ${i+1}" title="Reset band ${i+1} to its default frequency, gain, Q and bell filter">Reset</button></td></tr>`; }).join('')}</tbody></table></div>`).join('')}</div>
    </fieldset>`;
  renderBandBar(); renderSelectedBand(); drawEq();
  eqObserver = new ResizeObserver(drawEq);
  eqObserver.observe($('#eq-display'));
}

function eqGeometry() {
  const rect = $('#eq-display').getBoundingClientRect();
  const width = rect.width || 1000, height = rect.height || 420;
  return {rect,width,height,left:42,top:30,plotWidth:width-66,plotHeight:height-60};
}

/** One chip per band: jump straight to any band without hunting for its handle. */
function renderBandBar() {
  const bar = $('#band-bar');
  if (!bar) return;
  bar.innerHTML = config.outputs[selected].bands.map((b, i) => `<button type="button" class="band-chip" data-band-select="${i}" style="--band-color:${bandColors[i]}">${i + 1}</button>`).join('');
  refreshBandBar();
}

function refreshBandBar() {
  const o = config.outputs[selected];
  document.querySelectorAll('[data-band-select]').forEach(chip => {
    const i = Number(chip.dataset.bandSelect), b = o.bands[i];
    chip.classList.toggle('selected', i === selectedBand);
    chip.classList.toggle('band-off', !b.enabled);
    chip.classList.toggle('band-shaped', b.enabled && b.gainDb !== 0);
    chip.setAttribute('aria-pressed', i === selectedBand);
    chip.title = `Band ${i + 1} · ${b.frequency.toFixed(1)} Hz · ${b.gainDb.toFixed(1)} dB · Q ${b.q.toFixed(2)}${b.enabled ? '' : ' · off'}`;
    chip.setAttribute('aria-label', `Band ${i + 1}, ${b.frequency.toFixed(1)} hertz, ${b.gainDb.toFixed(1)} decibels${b.enabled ? '' : ', off'}`);
  });
}

function renderSelectedBand() {
  const b = config.outputs[selected].bands[selectedBand];
  $('#selected-eq-band').style.setProperty('--band-color',bandColors[selectedBand]);
  $('#selected-eq-band').innerHTML = `${field('Selected band',`<select id="eq-band-select">${options(config.outputs[selected].bands.map((v,i)=>[i,`Band ${i+1}${v.enabled?'':' · off'}`]),selectedBand)}</select>`)}
    <label class="checkbox-label"><input type="checkbox" data-band="${selectedBand}" data-param="enabled" aria-label="Selected band enabled" ${checked(b.enabled)}>On</label>
    ${field('Filter',`<select data-band="${selectedBand}" data-param="type" aria-label="Selected band filter">${options([['bell','Bell'],['lowShelf','Low shelf'],['highShelf','High shelf']],b.type)}</select>`)}
    ${field('Frequency · Hz',number(`data-band="${selectedBand}" data-param="frequency" aria-label="Selected band frequency"`,b.frequency,20,20000,'any'))}
    ${field('Gain · dB',number(`data-band="${selectedBand}" data-param="gainDb" aria-label="Selected band gain"`,b.gainDb,-18,18,'any'))}
    ${field('Q',number(`data-band="${selectedBand}" data-param="q" aria-label="Selected band Q"`,b.q,.1,18,'any'))}
    <button type="button" class="quiet band-reset selected-band-reset" data-band-reset="${selectedBand}" aria-label="Reset selected band ${selectedBand+1}" title="Reset selected band to its default frequency, gain, Q and bell filter">Reset band</button>`;
}

function syncEqEditors() {
  document.querySelectorAll('[data-band][data-param]').forEach(el=>{
    const b = config.outputs[selected].bands[Number(el.dataset.band)], value = b[el.dataset.param];
    if(el !== document.activeElement) {
      if(el.type==='checkbox') el.checked=value;
      else el.value=value;
    }
    el.closest('tr')?.classList.toggle('band-disabled',!b.enabled);
    el.closest('tr')?.classList.toggle('band-selected',Number(el.dataset.band)===selectedBand);
  });
  [...$('#eq-band-select').options].forEach((option,i)=>{option.textContent=`Band ${i+1}${config.outputs[selected].bands[i].enabled?'':' · off'}`;});
  refreshBandBar();
}

function drawEq() {
  const o = config.outputs[selected], {width,height,left,top,plotWidth,plotHeight} = eqGeometry();
  const x = f => left + Math.log10(f/20)/3 * plotWidth, y = g => top + plotHeight/2 - Math.max(-EQ_RANGE_DB,Math.min(EQ_RANGE_DB,g))*plotHeight/(EQ_RANGE_DB*2);
  const bypassAll = Boolean(config.eqBypass);
  const editable = config.mode!=='direct' && o.eqEnabled && !bypassAll;
  const frequencies = [20,50,100,200,500,1000,2000,5000,10000,20000];
  const grid = [-EQ_RANGE_DB,-EQ_RANGE_DB/2,0,EQ_RANGE_DB/2,EQ_RANGE_DB].map(g => `<line x1="${left}" y1="${y(g)}" x2="${x(20000)}" y2="${y(g)}" class="${g===0?'eq-zero':'eq-grid'}"/><text x="6" y="${y(g)+4}" class="eq-label">${g>0?'+':''}${g}</text>`).join('') + frequencies.filter((f,i)=>width>600||i%2===0||f===20000).map(f => `<line x1="${x(f)}" y1="${top}" x2="${x(f)}" y2="${y(-EQ_RANGE_DB)}" class="eq-grid"/><text x="${x(f)}" y="${height-9}" text-anchor="middle" class="eq-label">${f>=1000?`${f/1000}k`:f}</text>`).join('');
  const path = response => 'M'+Array.from({length:401},(_,i)=>{const f=20*1000**(i/400);return `${x(f).toFixed(2)},${y(response(f)).toFixed(2)}`;}).join(' L');
  const curves = o.eqEnabled && !bypassAll ? o.bands.map((b,i)=>!b.enabled?'':`<path d="${path(f=>bandResponse(b,f))} L${x(20000)},${y(0)} L${left},${y(0)} Z" fill="${bandColors[i]}" fill-opacity="${i===selectedBand?'.17':'.025'}"/><path d="${path(f=>bandResponse(b,f))}" fill="none" stroke="${bandColors[i]}" stroke-width="${i===selectedBand?2:1}" opacity="${i===selectedBand?'.95':'.4'}"/>`).join('') : '';
  $('#eq-chart').setAttribute('viewBox',`0 0 ${width} ${height}`);
  $('#eq-chart').innerHTML = `${grid}${curves}<path d="${path(f=>eqResponse(o,f,bypassAll))}" class="eq-curve"/>`;
  $('#eq-display').classList.toggle('eq-bypassed',!editable);
  document.querySelectorAll('[data-eq-node]').forEach(node=>{
    const i=Number(node.dataset.eqNode),b=o.bands[i];
    node.style.left=`${x(b.frequency)/width*100}%`;node.style.top=`${y(b.gainDb)/height*100}%`;
    node.classList.toggle('selected',i===selectedBand);node.classList.toggle('band-off',!b.enabled);
    node.disabled=!editable;node.setAttribute('aria-pressed',i===selectedBand);
    node.setAttribute('aria-label',`Band ${i+1}: ${b.frequency.toFixed(1)} Hz, ${b.gainDb.toFixed(1)} dB, Q ${b.q.toFixed(2)}${b.enabled?'':', off'}`);
    node.title=`Band ${i+1} · ${b.frequency.toFixed(1)} Hz · ${b.gainDb.toFixed(1)} dB · Q ${b.q.toFixed(2)}${b.enabled?'':' · Enable On to drag'}`;
  });
  syncEqEditors();
}

function endEqDrag(cancel=false) {
  if(!eqDrag) return;
  const drag=eqDrag;eqDrag=null;
  if(cancel) {config.outputs[drag.output].bands[drag.band]=drag.original;dirty=drag.dirty;$('#draft-status').textContent=dirty?'Draft · unsaved':`Saved on ${presetStore.label}`;}
  drag.node.classList.remove('dragging');
  if(drag.node.hasPointerCapture(drag.pointerId)) drag.node.releasePointerCapture(drag.pointerId);
  if(!cancel) syncLinkedEq(drag.output);
  drawEq();
}

document.addEventListener('pointerdown',event=>{
  const node=event.target.closest('[data-eq-node]');
  if(!node||event.button!==0||eqDrag||config.mode==='direct'||config.eqBypass||!config.outputs[selected].eqEnabled)return;
  event.preventDefault();selectedBand=Number(node.dataset.eqNode);node.focus({preventScroll:true});renderSelectedBand();drawEq();
  const band=config.outputs[selected].bands[selectedBand];
  if(!band.enabled)return;
  eqDrag={node,pointerId:event.pointerId,output:selected,band:selectedBand,original:{...band},dirty,x:event.clientX,y:event.clientY};
  node.setPointerCapture(event.pointerId);node.classList.add('dragging');
});
document.addEventListener('pointermove',event=>{
  if(!eqDrag||event.pointerId!==eqDrag.pointerId)return;
  const {plotWidth,plotHeight}=eqGeometry(),dx=(event.clientX-eqDrag.x)/plotWidth,dy=(event.clientY-eqDrag.y)/plotHeight;
  eqDrag.x=event.clientX;eqDrag.y=event.clientY;
  if(!dx&&!dy)return;
  const o=config.outputs[eqDrag.output];
  o.bands[eqDrag.band]=dragEqBand(o.bands[eqDrag.band],dx,dy,event.metaKey||event.ctrlKey);
  markDraft();drawEq();
});
document.addEventListener('pointerup',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag();});
document.addEventListener('pointercancel',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag(true);});
document.addEventListener('lostpointercapture',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag(true);});
window.addEventListener('blur',()=>endEqDrag(true));
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&eqDrag){event.preventDefault();endEqDrag(true);return;}
  if(event.altKey&&['ArrowLeft','ArrowRight'].includes(event.key)&&$('#eq-dialog').open) {
    event.preventDefault();gotoOutput(selected+(event.key==='ArrowRight'?1:-1));return;
  }
  const chip=event.target.closest('[data-band-select]');
  if(chip&&['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) {
    event.preventDefault();
    const step=event.key==='ArrowRight'?1:event.key==='ArrowLeft'?-1:0;
    selectedBand=event.key==='Home'?0:event.key==='End'?15:Math.max(0,Math.min(15,Number(chip.dataset.bandSelect)+step));
    renderSelectedBand();drawEq();
    document.querySelector(`[data-band-select="${selectedBand}"]`)?.focus({preventScroll:true});
    return;
  }
  const node=event.target.closest('[data-eq-node]');
  if(!node||node.disabled||config.mode==='direct'||config.eqBypass||!config.outputs[selected].eqEnabled)return;
  if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;
  event.preventDefault();selectedBand=Number(node.dataset.eqNode);
  const o=config.outputs[selected],b=o.bands[selectedBand];
  if(!b.enabled)return;
  const dx=event.key==='ArrowRight'?1/600:event.key==='ArrowLeft'?-1/600:0;
  const dy=event.key==='ArrowUp'?-1/480:event.key==='ArrowDown'?1/480:0;
  o.bands[selectedBand]=dragEqBand(b,dx,dy,event.metaKey||event.ctrlKey);
  renderSelectedBand();markDraft();drawEq();
});

/** Open another output in the editor. Navigation only: nothing about the draft changes. */
function gotoOutput(index) {
  const next = (index + CHANNELS) % CHANNELS;
  if (next === selected) return;
  selected = next;
  renderBank(); renderOverview(); renderInspector();
  document.querySelector('#channel-jump')?.focus({preventScroll:true});
}

/** Mirror this output's EQ onto a linked headphone ear, if the bus has grouping on. */
function syncLinkedEq(index = selected) {
  if(!linkedEqOutputs(config,index).length) return;
  config = mirrorLinkedEq(config,index);
  renderOverview();
}

// Double-click a graph handle to reset that band, matching the per-row Reset buttons.
document.addEventListener('dblclick',event=>{
  const node=event.target.closest('[data-eq-node]');
  if(!node||node.disabled||config.mode==='direct'||config.eqBypass)return;
  event.preventDefault();endEqDrag(true);
  const index=Number(node.dataset.eqNode);
  config.outputs[selected].bands[index]=resetBand(config.outputs[selected].bands[index],index);
  selectedBand=index;syncLinkedEq();markDraft();renderSelectedBand();drawEq();
  toast(`Band ${index+1} reset to its default frequency, 0 dB and Q 1.`);
});

function crossoverTargets() {
  return speakerGroupSourceIds(config).filter(i=>i!==config.lfe.input && (crossoverScope==='all'||crossoverSelection.has(i)));
}

function refreshCrossoverControls() {
  const groupChannels=speakerGroupSourceIds(config).filter(i=>i!==config.lfe.input);
  for(const i of crossoverSelection) if(!groupChannels.includes(i)) crossoverSelection.delete(i);
  const targets=crossoverTargets(), selectionCount=crossoverSelection.size;
  $('#crossover-scope').value=crossoverScope;
  $('#crossover-apply').textContent=`Apply to ${targets.length} channel${targets.length===1?'':'s'}`;
  $('#crossover-apply').disabled=!targets.length||!config.bassEnabled||config.mode==='direct';
  $('#crossover-count').textContent=`${selectionCount} selected`;
  const all=$('#crossover-select-all');
  all.checked=groupChannels.length>0&&selectionCount===groupChannels.length;
  all.indeterminate=selectionCount>0&&!all.checked;
}

function renderBass() {
  crossoverSelection.delete(config.lfe.input);
  const slopeOptions = value => options([[12,'LR · 12 dB/oct'],[24,'LR · 24 dB/oct'],[48,'LR · 48 dB/oct']],value);
  $('#bass-page').innerHTML = `<details class="page-section" data-section="bass" ${sectionAttr('bass')}><summary class="section-summary">Bass management <small>crossovers · LFE · headroom</small></summary><fieldset ${disabled(config.mode==='direct')} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bass-top"><section class="panel"><h2>Speaker bass redirection</h2><p>High-pass each main speaker and send its low frequencies to your chosen subs. Output EQ and alignment follow the split.</p><div class="field-row"><label class="checkbox-label"><input type="checkbox" id="bass-enabled" ${checked(config.bassEnabled)}>Bass redirection enabled</label>${field('Common input trim · dB',number('id="headroom"',config.headroomDb,-36,0,.1))}</div><p>Turning redirection off restores full-range mains and silences their sub sends. LFE remains independently routed. Per-channel crossovers and sub sends are in <strong>Bass routing</strong>, above the channel overview.</p></section>
    <section class="panel"><h2>LFE is its own source</h2><p>Control the effects channel separately from redirected speaker bass. LFE gain is explicit; no automatic +10 dB boost.</p><div class="field-row">${field('LFE input',`<select data-lfe="input">${options(inputOptions(),config.lfe.input)}</select>`)}${field('Low-pass · Hz',number('data-lfe="lowpassHz"',config.lfe.lowpassHz,20,250))}${field('Slope',`<select data-lfe="slope">${slopeOptions(config.lfe.slope)}</select>`)}${field('LFE trim · dB',number('data-lfe="trimDb"',config.lfe.trimDb,-24,12,.1))}</div><p class="route-note">Changing the LFE input clears all sub sends from the old and new LFE rows, so those routes must be deliberately reassigned.</p></section></div>
    <div id="polarity-note"></div>
    </fieldset></details>`;
  renderBassMatrix();
  refreshPolarityNote();
}

/**
 * Update the crossover polarity note in place.
 *
 * It lives in its own container holding no focusable control, so it can be
 * refreshed after any edit without re-rendering the bass panel and unmounting
 * the select the user is still using.
 */
function refreshPolarityNote() {
  const box = $('#polarity-note');
  if (box) box.innerHTML = polarityBanner();
}

/**
 * A 12 dB/oct Linkwitz-Riley leaves its two branches 180 degrees apart at the
 * crossover, so main and sub usually need opposite polarity to sum. This says
 * so and changes nothing: the right answer depends on drivers, positions and
 * the room, and only a measurement settles it. The same text goes into the
 * compiler's report, from the same module.
 */
function polarityBanner() {
  const note = polarityNote(config);
  if (!note) return '';
  const names = note.labels.map((label, i) => `${pad(note.inputs[i])} ${label}`).join(', ');
  const branches = [
    note.highpassCount ? `${note.highpassCount} speaker high-pass${note.highpassCount === 1 ? '' : 'es'}` : null,
    note.lowpassCount ? `${note.lowpassCount} bass low-pass${note.lowpassCount === 1 ? '' : 'es'}` : null,
  ].filter(Boolean).join(' and ');
  return `<p class="banner-note polarity-note" role="note"><strong>${esc(note.headline)}.</strong>
    ${esc(note.detail)} Affects ${esc(branches)} on ${esc(names)}.
    <span class="muted">Advisory only — no polarity has been changed.</span></p>`;
}

/** The per-channel crossover and sub-send matrix, expanded from the channel overview. */
function renderBassMatrix() {
  const box = $('#bass-matrix-box');
  if (!box) return;
  const routingInputs = speakerGroupSourceIds(config);
  for(const i of crossoverSelection) if(i===config.lfe.input||!routingInputs.includes(i)) crossoverSelection.delete(i);
  const subs = config.outputs.map((o,i)=>({...o,index:i})).filter(o=>o.role==='sub');
  const slopeOptions = value => options([[12,'LR · 12 dB/oct'],[24,'LR · 24 dB/oct'],[48,'LR · 48 dB/oct']],value);
  box.innerHTML = `<fieldset ${disabled(config.mode==='direct')} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bass-box-head"><h3>Bass routing matrix</h3><p>${subs.length} subwoofer output${subs.length===1?'':'s'} within the 16-channel output bank. Enable a send, then set its gain. Redirection on/off, headroom and LFE live in Bass management below.</p></div>
    ${subs.length ? `<div class="crossover-tools"><strong>Set crossover</strong>${field('Crossover · Hz',`<input type="number" id="crossover-hz" value="${esc(crossoverHz)}" min="20" max="250" step="1" required ${disabled(!config.bassEnabled)}>`)}${field('Apply to',`<select id="crossover-scope" ${disabled(!config.bassEnabled)}>${options([['all','All speaker-group channels'],['selected','Selected channels']],crossoverScope)}</select>`)}<button id="crossover-apply" data-action="crossover-apply">Apply crossover</button><span id="crossover-count" class="muted"></span><p>Sets speaker HP and bass LP together. Select rows for a group, or edit any channel individually. LFE, slopes and HP on/off stay as set.</p></div>
    <div class="table-scroll"><table class="matrix"><thead><tr><th><label class="checkbox-label"><input type="checkbox" id="crossover-select-all" aria-label="Select all speaker-group channels for crossover" ${disabled(!config.bassEnabled)}>Source</label></th><th>HP on</th><th>Speaker HP · Hz</th><th>Bass LP · Hz</th><th>Slope</th>${subs.map(o=>`<th class="matrix-head">${pad(o.index)} · ${esc(o.label)}<small class="sub-sum">Sum bound: ${Number.isFinite(subSumBoundDb(config,o.index)) ? `${subSumBoundDb(config,o.index).toFixed(1)} dBFS` : 'silent'}</small></th>`).join('')}</tr></thead><tbody>${routingInputs.map(i=>{
      const v=config.inputs[i];
      const lfe = i === config.lfe.input;
      return `<tr class="${lfe?'lfe-row':''}"><td>${lfe?`<strong>${pad(i)} · ${esc(v.label)}</strong> <small>LFE</small>`:`<label class="checkbox-label"><input type="checkbox" data-crossover-select="${i}" aria-label="Select channel ${i+1}: ${esc(v.label)} for crossover" ${checked(crossoverSelection.has(i))} ${disabled(!config.bassEnabled)}><strong>${pad(i)} · ${esc(v.label)}</strong></label>`}</td><td>${lfe?'—':`<input type="checkbox" data-input="${i}" data-param="crossover" aria-label="${esc(v.label)} high-pass enabled" ${checked(v.crossover)} ${disabled(!config.bassEnabled)}>`}</td><td>${lfe?'—':number(`data-input="${i}" data-param="highpassHz" aria-label="${esc(v.label)} high-pass frequency" ${disabled(!config.bassEnabled||!v.crossover)}`,v.highpassHz,20,250)}</td><td>${lfe?`${config.lfe.lowpassHz} Hz`:number(`data-input="${i}" data-param="lowpassHz" aria-label="${esc(v.label)} bass low-pass frequency" ${disabled(!config.bassEnabled)}`,v.lowpassHz,20,250)}</td><td>${lfe?`${config.lfe.slope} dB/oct`:`<select data-input="${i}" data-param="slope" aria-label="${esc(v.label)} crossover slope" ${disabled(!config.bassEnabled)}>${slopeOptions(v.slope)}</select>`}</td>${subs.map(o=>{
        const gain = config.sends[i][o.index], inactive = !lfe && !config.bassEnabled;
        const name = `${v.label} to ${o.label}`;
        return `<td><div class="send-cell"><input type="checkbox" data-send="${i},${o.index}" aria-label="Enable ${esc(name)}" ${checked(gain!==null)} ${disabled(inactive)}>${number(`data-send-gain="${i},${o.index}" aria-label="${esc(name)} gain" ${disabled(gain===null||inactive)}`,gain??0,-60,12,.1)}<small>dB</small></div></td>`;
      }).join('')}</tr>`;
    }).join('')}</tbody></table></div>
    <p class="route-note">HP off keeps a main full-range while retaining its bass send. New sub outputs start with all sends off. Sum bounds assume coherent full-scale inputs and include input trim, send gain, LFE trim, and output gain; they exclude filters and EQ, and are not measured peaks.</p>` : '<div class="empty"><h3>No subwoofer outputs assigned</h3><p>Set any output\'s role to Subwoofer in the overview below.</p></div>'}
    </fieldset>`;
  if(subs.length) refreshCrossoverControls();
}

function renderSettings() {
  const saved = presets(), names = Object.keys(saved), count = role => config.outputs.filter(o=>o.role===role).length;
  $('#settings-page').innerHTML = `<div class="settings-grid"><section class="panel"><h2>Presets</h2><p>Save complete layouts, source selection, crossovers, sub sends and all 256 EQ bands on <strong>${esc(presetStore.label)}</strong>. Export a JSON copy to keep or share the design.</p>
    ${field('Draft name',`<input id="preset-name" value="${esc(config.name)}" maxlength="64" required>`)}
    <div class="toolbar"><button class="primary" data-action="save">Save preset locally</button><button data-action="export">Export JSON</button><label class="import-label">Import JSON<input type="file" id="import-preset" accept=".json,application/json" aria-label="Import preset JSON"></label></div>
    ${field('Saved presets',`<select id="saved-preset" ${disabled(!names.length)}>${names.length?options(names.map(n=>[n,n]),config.name):'<option>No saved presets</option>'}</select>`)}
    <div class="toolbar"><button data-action="load" ${disabled(!names.length)}>Load selected preset</button><button class="quiet" data-action="delete-preset" ${disabled(!names.length)}>Delete selected</button><button class="quiet" data-action="reset">Reset to example layout</button></div>
    <div class="note-box">${esc(presetStore.note)}</div>
    </section>
    ${applyPanel()}
    <section class="panel maintenance-panel"><div class="section-heading"><h2>Logs</h2><span class="offline-badge ${health?'live-badge':''}">${health?'Live journal':'Not connected'}</span></div>
    <p>${health?'Read the journal through the Pi control service, or paste a snapshot below. Reading logs does not touch the audio path.':'Live service logs require the Pi connection. Copy a journal command to run on the Pi, then paste its output to inspect a snapshot here.'}</p>
    <div class="log-controls">${field('Service',`<select id="log-service">${options(terms().logs,logService)}</select>`)}${field('Filter snapshot',`<input id="log-filter" type="search" placeholder="Search log text…" value="${esc(logQuery)}">`)}<button data-action="refresh-logs" ${disabled(!health||logBusy)} title="${health?'Read the last 200 journal lines from the Pi':'Requires a Pi control backend'}">${logBusy?'Reading…':'Refresh live logs'}</button></div>
    <div class="command-line"><code id="journal-command">${esc(journalCommand(logService, terms().stack))}</code><button data-action="copy-journal">Copy command</button></div>
    <details class="log-paste"><summary>Paste a log snapshot</summary><label class="field"><span>Journal output · local to this page</span><textarea id="log-paste" rows="4" maxlength="200000" spellcheck="false" placeholder="Paste command output from the Pi here">${esc(logSnapshots[logService])}</textarea></label></details>
    <div class="log-view" tabindex="0" role="region" aria-label="Service log snapshot"><pre id="log-output"></pre></div><p id="log-count" role="status"></p></section>
    ${systemPanel()}
    <section class="panel maintenance-panel"><div class="section-heading"><h2>Common commands</h2><span class="offline-badge">Run on the Pi</span></div>
    <p>Copy a command for a Pi terminal. ${health?'The control service is read-only apart from Apply and the Shut down button above: it cannot restart a service, because owning a PCM device belongs to the privileged applier, which takes only those requests.':'Run buttons become available when device control is connected.'} Restart commands interrupt audio.</p>
    <div class="service-commands">${serviceCommands(terms().stack).map(c=>`<article class="service-command"><h3>${esc(c.label)}</h3><p>${esc(c.detail)}</p><code>${esc(c.command)}</code><div class="toolbar"><button data-copy-command="${c.id}" aria-label="Copy ${esc(c.label)} command">Copy command</button><button disabled title="${health?'The control service is read-only; run this in a Pi terminal':'Requires a Pi control backend'}" aria-label="Run ${esc(c.label)} on Pi">Run on Pi</button></div></article>`).join('')}</div></section>
    <section class="panel"><h2>Input labels</h2><p>Labels belong to this preset. Computer-facing USB channel names remain 1–16.</p><div class="table-scroll"><table><thead><tr><th>Input</th><th>Label</th></tr></thead><tbody>${config.inputs.map((v,i)=>`<tr><td>${pad(i)}</td><td><input data-input="${i}" data-param="label" aria-label="Input ${i+1} label" maxlength="64" value="${esc(v.label)}" required></td></tr>`).join('')}</tbody></table></div></section>
    <section class="panel"><h2>Operating modes</h2><p><strong>${esc(terms().directHeading)}</strong> ${terms().stack === 'dante' ? 'passes sixteen channels each way between USB and Dante unchanged, sample for sample.' : 'retains the existing bidirectional USB ↔ AoIP path. Its timing profile stays independent of DSP presets.'}</p><p><strong>DSP processor</strong> takes one 16-channel source bank, redirects bass, applies output correction, and sends 16 channels to ${terms().stack === 'dante' ? 'Dante. What Dante returns goes to the host unchanged.' : 'AoIP.'}</p>${terms().aoipSource ? '<p>In AoIP source mode, USB is not part of the signal path. The eventual processor must be able to run without a connected USB host.</p>' : '<p>The source is the USB host. An AoIP source is not available on the Dante endpoint.</p>'}<p>${esc(terms().routing)}</p></section></div>`;
  renderLogView();
}

/** Settings: the live facts. Rebuilt on every health poll by refreshSettingsLive, so it must not hold input state. */
function systemPanel() {
  const count = role => config.outputs.filter(o=>o.role===role).length;
  return `<section class="panel" id="system-panel"><div class="section-heading"><h2>System overview</h2><span class="offline-badge ${health?'live-badge':''}">${health?'Live · '+esc(health.generated):'Not connected'}</span></div>
    <p>${health?'Read live from the Pi control service. Values the service cannot read say so; none is defaulted to zero.':'No control service answered on this origin. Serve the UI from the Pi to see live state.'}</p>
    <dl class="fact-list">${systemFacts(health).map(row=>`<div><dt>${esc(row.label)}</dt><dd class="fact-${row.state||'plain'}"${row.title?` title="${esc(row.title)}"`:''}>${esc(row.value)}</dd></div>`).join('')}
      <div><dt>Output allocation</dt><dd class="fact-plain">${count('speaker')} speakers · ${count('sub')} subs · ${count('unused')} spare</dd></div><div><dt>DSP source draft</dt><dd class="fact-plain">${config.source==='usb'?'USB':esc(terms().sourceLabel)}</dd></div><div><dt>Alignment range</dt><dd class="fact-plain">0–10 ms per output</dd></div></dl>
    <div class="note-box">${esc(dspNote(health))}</div>
    ${health ? `<div class="apply-draft power-box"><strong>Power</strong><p class="muted">Stops the ${esc(terms().service)} in order, then powers the Pi off through the same privileged applier as Apply. This page loses its connection. Once activity stops, unplug the USB data cable first, then PoE; reconnecting PoE starts it again.</p><button class="danger" data-action="shutdown-pi" ${disabled(applyBusy || shutdownRequested || !(health.control?.apply?.available))} title="${health.control?.apply?.available ? `Stop the ${esc(terms().service)} and power the Pi off` : esc(health.control?.apply?.reason || 'Apply is not installed')}">${shutdownRequested ? 'Shutting down…' : 'Shut down the Pi'}</button></div>` : ''}</section>`;
}

/** Replace only the live panels on a poll, and not while the user is inside a control on this page:
 *  rebuilding the whole page every 2 s closed an open dropdown as soon as the mouse moved. */
function refreshSettingsLive() {
  if (tab !== 'settings') return;
  const page = $('#settings-page');
  if (!page) return;
  const active = document.activeElement;
  if (active && page.contains(active) && active.matches('select, input, textarea, button')) return;
  // Text the user has selected in the page survives: no rebuild while a
  // selection is open, and no rebuild at all when nothing changed.
  const selection = document.getSelection();
  if (selection && !selection.isCollapsed && selection.anchorNode && page.contains(selection.anchorNode)) return;
  const nextHtml = {'#system-panel': systemPanel(), '#apply-panel': applyPanel()};
  if (Object.entries(nextHtml).every(([id, html]) => page.querySelector(id)?.outerHTML === html)) return;
  // A disclosure the user opened stays open across the 1 Hz re-render.
  const openDetails = [...page.querySelectorAll('details[open]')].map(node => node.className);
  for (const [id, html] of Object.entries(nextHtml)) {
    const node = page.querySelector(id);
    if (node) node.outerHTML = html; else { renderSettings(); return; }
  }
  for (const className of openDetails) {
    const node = className ? page.querySelector(`details.${className.split(' ')[0]}`) : null;
    if (node) node.open = true;
  }
}

/** Settings: what the service runs now, the user presets it can switch between,
 *  this draft's place among them, and the accepted profiles behind a disclosure. */
function applyPanel() {
  const choices = profileChoices(health);
  const status = applyStatus || health?.apply || null;
  const inFlight = Boolean(status && (status.inFlight || status.pending));
  const busy = applyBusy || inFlight;
  const live = choices.live;
  const presetsOnPi = userPresets(health);
  const research = choices.accepted.filter(row => !row.user && /^servo-aligned/.test(row.name));
  const standard = choices.accepted.filter(row => !row.user && !/^servo-aligned/.test(row.name));
  if (!research.some(row => row.name === applyChoice)) applyChoice = research[0]?.name || '';
  const current = status?.current;
  const since = current?.state === 'done' && current.kind !== 'shutdown' && current.profile === live?.name ? current.finishedAt : null;
  const describe = text => String(text || '').replace(/^user preset: /, '');
  const switchButton = name => `<button class="quiet" data-action="switch-profile" data-name="${esc(name)}" ${disabled(!choices.available || busy)} title="${choices.available ? `Restart the ${esc(terms().service)} on ${esc(name)}` : esc(choices.reason)}">Switch</button>`;
  const badge = `<span class="offline-badge ${health ? 'live-badge' : ''}">${health ? (choices.available ? 'Apply available' : 'Apply not installed') : 'Not connected'}</span>`;
  if (!health) return `<section class="panel maintenance-panel" id="apply-panel"><div class="section-heading"><h2>Service profile</h2>${badge}</div><p class="fact-plain">Requires the Pi connection.</p><div class="note-box" role="status">${esc(applyLine(status))}</div></section>`;

  const running = live
    ? `<div class="running-now"><span class="overline">Running now</span><div class="running-name"><strong>${esc(live.name)}</strong><span class="muted">${live.user ? 'your preset' : esc(live.status || 'profile')}${live.measured ? ` · ${esc(live.measured)}` : ''}${since ? ` · since ${esc(since)}` : ''}</span></div>${live.description ? `<p class="muted">${esc(describe(live.description))}</p>` : ''}</div>`
    : `<p class="fact-plain">Profile unknown (configuration unreadable).</p>`;

  const preview = (() => { const state = liveState(health, draftShapeKey); return state.previewing ? `<div class="apply-draft"><strong>Live preview running</strong><p class="muted">The ${esc(terms().engine)} is running coefficients (${esc((state.liveSha256 || '').slice(0, 8))}) that are not the installed <code>${esc(state.profile)}</code> (${esc((state.installedSha256 || '').slice(0, 8))}). A restart returns to the installed file.</p><button data-action="live-commit" ${disabled(busy)}>Commit preview</button> <button class="quiet" data-action="live-discard" ${disabled(busy)}>Discard preview</button></div>` : ''; })();

  const draftSlug = presetSlug(config.name);
  const draftTarget = draftSlug ? `${terms().presetPrefix}${draftSlug}` : '';
  const draftReplaces = presetsOnPi.some(p => p.name === draftTarget);
  const draftBlocked = config.mode === 'direct' ? 'Switch the draft to DSP mode to install it.' : !draftSlug ? 'Give the draft a name first.'
    : config.source === 'aoip' && !terms().aoipSource ? 'Set the DSP source to USB: the Dante endpoint filters what the USB host sends.' : '';
  const presetRows = presetsOnPi.map(p => `<li class="profile-row ${p.live ? 'is-live' : ''}"><div class="profile-text"><code>${esc(p.name)}</code>${p.live ? ' <span class="badge">live</span>' : ''}<span class="muted" title="${esc(p.description)}">${esc(describe(p.description))}</span></div><div class="profile-actions">${p.live ? '' : switchButton(p.name)}<button class="quiet" data-action="remove-preset" data-slug="${esc(p.slug)}" ${disabled(p.live || busy)} title="${p.live ? 'Switch away before removing the live preset' : 'Remove this preset from the Pi'}">Remove</button></div></li>`).join('');
  const draftRow = `<li class="profile-row draft-row"><div class="profile-text"><span>This draft · <em>${esc(config.name)}</em></span><span class="muted">${draftBlocked || (draftReplaces ? `Compiles here and replaces <code>${esc(draftTarget)}</code>, then restarts on it.` : `Compiles here and installs as <code>${esc(draftTarget)}</code>, then restarts on it.`)}</span></div><div class="profile-actions"><button class="primary" data-action="apply-draft" ${disabled(!choices.available || busy || Boolean(draftBlocked))} title="${choices.available ? `Compile this draft in the browser, install it on the Pi and restart the ${esc(terms().service)} on it` : esc(choices.reason)}">Compile &amp; apply</button></div></li>`;
  const presets = `<div class="apply-presets"><strong>Your presets on the Pi</strong><span class="muted"> · ${presetsOnPi.length} of 8 · never soaked, loaded through ${esc(terms().loader)}, every section checked stable</span><ul>${presetRows}${draftRow}</ul></div>`;

  const standardRows = standard.map(row => `<li class="profile-row"><div class="profile-text"><code>${esc(row.name)}</code><span class="muted">${esc(row.description || (row.dspPreset ? 'preset' : 'no preset'))}</span></div><div class="profile-actions">${switchButton(row.name)}</div></li>`).join('');
  const researchBlock = research.length ? `<div class="log-controls research-lineage">${field(`Research lineage · ${research.length} servo-aligned profiles`, `<select id="apply-profile-choice" ${disabled(busy)}>${options(research.map(row => [row.name, row.name.replace(/^servo-aligned-?/, '') || 'servo-aligned']), applyChoice)}</select>`)}<button data-action="apply-profile" ${disabled(!choices.available || busy || !applyChoice)} title="${choices.available ? `Restart the ${esc(terms().service)} on the chosen profile` : esc(choices.reason)}">${applyBusy ? 'Queueing…' : inFlight ? 'Applying…' : 'Switch'}</button></div>` : '';
  const accepted = choices.accepted.some(row => !row.user) ? `<details class="apply-more"><summary>${esc(terms().acceptedSummary(standard.length + research.length))}</summary>${standardRows ? `<ul>${standardRows}</ul>` : ''}${researchBlock}</details>` : '';

  const steps = current?.steps?.length ? `<details class="apply-steps-details" ${inFlight ? 'open' : ''}><summary>${current.steps.length} step${current.steps.length === 1 ? '' : 's'}${current.finishedAt ? ` · finished ${esc(current.finishedAt)}` : ' · in progress'}</summary><ol class="apply-steps">${current.steps.map(step => `<li class="${step.ok ? '' : 'warn'}"><strong>${esc(applyStepLabel(step.name, current.stack || terms().stack))}</strong>${step.detail ? ` <span class="muted">${esc(step.detail)}</span>` : ''}</li>`).join('')}</ol></details>` : '';
  return `<section class="panel maintenance-panel" id="apply-panel"><div class="section-heading"><h2>Service profile</h2>${badge}</div>
    ${running}${preview}${presets}${accepted}
    <p class="muted apply-rule">${choices.available ? `Every switch or install restarts the ${esc(terms().service)}: ${esc(terms().outage)}. A new latency level is drawn, and the applier returns to the previous profile on its own if the stack does not come up clean. Stop playback first.` : esc(choices.reason.replace(/[.\s]*$/, '.'))}</p>
    <div class="note-box" role="status">${esc(applyLine(status))}</div>${steps}</section>`;
}

/** The same rule the service and the applier use for user-<slug> (dante-<slug> on a Dante Pi). */
function presetSlug(name) {
  const slug = String(name || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24).replace(/-+$/, '');
  return /^[a-z0-9][a-z0-9-]{0,23}$/.test(slug) ? slug : '';
}

async function applyDraft() {
  const choices = profileChoices(health);
  const live = choices.live?.name || null;
  // The preset's name on the Pi is the draft's name; ask for it here so the
  // step that installs it is also where it gets named.
  const entered = prompt(`Name for this preset on the Pi.\n\nIt installs as ${terms().presetPrefix}<slug> and replaces a preset with the same slug; a new name adds a preset (at most 8).`, config.name);
  if (entered === null) return;
  const name = entered.trim();
  if (!name || name.length > 64) { toast('Preset names are 1 to 64 characters.'); return; }
  if (!presetSlug(name)) { toast('The name needs at least one letter or digit.'); return; }
  if (name !== config.name) { config.name = name; markDraft(); renderSettings(); }
  let compiled;
  try { validateConfig(config); compiled = await compileDraft(config); }
  catch (e) { toast(`Cannot compile this draft: ${e.message}`); return; }
  if (!confirm(presetSummary(compiled, config.name, health))) return;
  applyBusy = true; refreshSettingsLive();
  try {
    const result = await requestPreset(config.name, compiled.artifact, live);
    toast(`${result.replacing ? 'Replacing' : 'Installing'} ${result.profile} (artifact ${result.artifactSha256.slice(0, 8)}). ${result.note || ''}`);
    await saveDraftWithPreset('preset');
    applyStatus = {current: null, pending: true, inFlight: false};
    startApplyPolling();
  } catch (e) { toast(`Preset refused: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
}

async function commitLive() {
  const state = liveState(health, draftShapeKey);
  if (!state.previewing) { toast(`Nothing to commit: the ${terms().engine} is running the installed preset.`); return; }
  if (!confirm(`Make the coefficients the ${terms().engine} is running the installed ${state.profile}? No restart.`)) return;
  applyBusy = true; refreshSettingsLive();
  try {
    const result = await requestCommit(state.profile, state.liveSha256);
    applyStatus = {current: null, pending: true, inFlight: false};
    refreshSettingsLive();
    const receipt = await awaitReceipt(result.id);
    const sha = receipt.committed?.sha256 || state.liveSha256 || '';
    liveLine = `Committed (${sha.slice(0, 8)}): the installed preset now carries these coefficients.`;
    toast(liveLine);
    await saveDraftWithPreset('commit');
    pollHealth();
  } catch (e) { toast(`Commit failed: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
  renderLiveState();
}

async function discardLive() {
  const state = liveState(health, draftShapeKey);
  if (!state.previewing) { toast('Nothing to discard.'); return; }
  liveQueue.cancel();
  applyBusy = true; refreshSettingsLive();
  try {
    const result = await requestLive(null, state.profile, state.liveSha256);
    liveLastSent = state.installedSha256;
    toast(result.note || 'Discard queued.');
    applyStatus = {current: null, pending: true, inFlight: false};
    startApplyPolling();
  } catch (e) { toast(`Discard refused: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
}

async function removeUserPreset(slug) {
  if (!confirm(`Remove ${terms().presetPrefix}${slug} and its artifact from the Pi? No restart; the live profile is untouched.`)) return;
  applyBusy = true; refreshSettingsLive();
  try {
    await removePreset(slug);
    applyStatus = {current: null, pending: true, inFlight: false};
    startApplyPolling();
  } catch (e) { toast(`Remove refused: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
}

async function applyProfile() {
  const choices = profileChoices(health);
  const target = choices.accepted.find(row => row.name === applyChoice);
  if (!target) { toast('Choose a profile first.'); return; }
  const live = choices.live?.name || null;
  const outage = terms().outage.charAt(0).toUpperCase() + terms().outage.slice(1);
  if (!confirm(`Switch the ${terms().service} from ${live || '?'} to ${target.name}?\n\n${outage}. The latency level is drawn afresh. If the stack does not come up clean the applier returns to ${live || 'the previous profile'} on its own. Stop playback before continuing.`)) return;
  applyBusy = true; refreshSettingsLive();
  try {
    const result = await requestProfile(target.name, live);
    toast(result.note || `Queued a switch to ${target.name}.`);
    applyStatus = {current: null, pending: true, inFlight: false};
    startApplyPolling();
  } catch (e) { toast(`Apply refused: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
}

async function shutdownPi() {
  const live = profileChoices(health).live?.name || null;
  if (!confirm(`Shut down the Pi?\n\nThe ${terms().service} stops, then the Pi powers off and this page loses its connection. Audio stops for good until it is powered on again. Stop playback first.\n\nOnce activity stops, unplug the USB data cable, then PoE.`)) return;
  applyBusy = true; refreshSettingsLive();
  try {
    const result = await requestShutdown(live);
    shutdownRequested = true;
    toast(result.note || 'Shutdown queued.');
    applyStatus = {current: null, pending: true, inFlight: false};
    startApplyPolling();
  } catch (e) { toast(`Shutdown refused: ${e.message}`); }
  applyBusy = false;
  refreshSettingsLive();
}

function startApplyPolling() {
  if (applyPoll) return;
  const tick = async () => {
    try { applyStatus = await fetchApplyStatus(); }
    catch (e) { toast(shutdownRequested ? 'The Pi is powering off; this page has lost its connection.' : `Lost the Apply status: ${e.message}`); stopApplyPolling(); return; }
    refreshSettingsLive();
    if (applyFinished(applyStatus)) { stopApplyPolling(); toast(applyLine(applyStatus)); pollHealth(); }
  };
  applyPoll = setInterval(tick, APPLY_POLL_MS);
  tick();
}
function stopApplyPolling() { clearInterval(applyPoll); applyPoll = null; }

function renderLogView() {
  // A live read wins over a pasted snapshot; the count line always says which.
  const live=logLive[logService], pasted=logSnapshots[logService], snapshot=live||pasted;
  const lines=snapshot?snapshot.split(/\r?\n/).filter(line=>line.length):[];
  const visible=lines.filter(line=>line.toLowerCase().includes(logQuery.toLowerCase()));
  $('#log-output').textContent=!snapshot
    ?(health?'No log read yet.\nUse Refresh live logs, or paste a journal snapshot above.':'No live logs available.\nConnect the Pi backend or paste a journal snapshot above.')
    :visible.length?visible.join('\n'):'No lines match this filter.';
  $('#log-count').textContent=snapshot
    ?`${live?'Live journal read':'Pasted snapshot'} · ${visible.length} of ${lines.length} lines`
    :'No snapshot loaded';
  const view=$('.log-view'); if(view&&live) view.scrollTop=view.scrollHeight;
}

async function loadLiveLogs() {
  if (!health || logBusy) return;
  logBusy = true; renderSettings();
  const service = logService;
  try {
    logLive[service] = await fetchLogs(service, 200);
    toast(`Read the last 200 journal lines for ${(terms().logs.find(([key]) => key === service) || [service, service])[1]}.`);
  } catch (e) { toast(`Could not read logs: ${e.message}`); }
  finally { logBusy = false; renderSettings(); }
}

async function copyCommand(command) {
  try {await navigator.clipboard.writeText(command);toast('Command copied. Run it in a terminal on the Pi.');}
  catch {toast('Clipboard unavailable. Select and copy the displayed command.');}
}

function refreshSumBounds() {
  const subs = config.outputs.map((o,i)=>({o,i})).filter(({o})=>o.role==='sub');
  document.querySelectorAll('.sub-sum').forEach((label,n)=>{
    const value = subSumBoundDb(config,subs[n].i);
    label.textContent = `Sum bound: ${Number.isFinite(value) ? `${value.toFixed(1)} dBFS` : 'silent'}`;
  });
}

document.addEventListener('click', event => {
  const b = event.target.closest('button'); if (!b || b.disabled || b.closest('fieldset:disabled')) return;
  if (b.dataset.bandReset !== undefined) {
    if (config.mode === 'direct') return;
    const index = Number(b.dataset.bandReset);
    config.outputs[selected].bands[index] = resetBand(config.outputs[selected].bands[index], index);
    selectedBand = index;
    syncLinkedEq();
    markDraft();
    renderSelectedBand();
    drawEq();
    return;
  }
  if (b.dataset.eqNode!==undefined) {selectedBand=Number(b.dataset.eqNode);renderSelectedBand();drawEq();return;}
  if (b.dataset.bandSelect!==undefined) {selectedBand=Number(b.dataset.bandSelect);renderSelectedBand();drawEq();return;}
  if (b.dataset.copyCommand) {const command=serviceCommands(terms().stack).find(c=>c.id===b.dataset.copyCommand);if(command)copyCommand(command.command);return;}
  if (b.dataset.action==='copy-journal') {copyCommand(journalCommand(logService, terms().stack));return;}
  if (b.dataset.action==='live-commit') {commitLive();return;}
  if (b.dataset.action==='live-discard') {discardLive();return;}
  if (b.dataset.tab) { tab = b.dataset.tab; render(); return; }
  if (b.dataset.select !== undefined) { selected = Number(b.dataset.select); selectedBand = 0; renderBank(); renderOverview(); renderInspector(); updateMeters(); return; }
  if (b.id === 'meter-toggle') { metersRunning = !metersRunning; syncMeterLabels(); updateMeters(); return; }
  if (b.dataset.mode) { config.mode = b.dataset.mode; markDraft(); render(); return; }
  if (b.dataset.source) { config.source = b.dataset.source; markDraft(); render(); return; }
  if (b.dataset.mute !== undefined) { const o = config.outputs[Number(b.dataset.mute)]; o.mute = !o.mute; markDraft(); render(); return; }
  if (b.dataset.eqOpen !== undefined) { selected = Number(b.dataset.eqOpen); renderBank(); renderOverview(); renderInspector(); $('#eq-dialog').showModal(); return; }
  const action = b.dataset.action;
  if (action === 'eq-close') { $('#eq-dialog').close(); return; }
  if (action === 'channel-prev' || action === 'channel-next') { gotoOutput(selected + (action === 'channel-next' ? 1 : -1)); return; }
  if (action === 'bass-toggle') { bassBoxOpen = !bassBoxOpen; renderOverview(); if (bassBoxOpen) $('#bass-matrix-box').scrollIntoView({block:'nearest'}); document.querySelector('[data-action="bass-toggle"]')?.focus({preventScroll:true}); return; }
  if (action === 'slot-switch') {
    if (b.dataset.slot === profileState.active) return;
    try {
      const from = profileState.active;
      const result = switchSlot(profileState, b.dataset.slot, config);
      slotDirty[from] = dirty;
      profileState = result.state; config = result.config;
      dirty = result.seeded ? dirty : (slotDirty[result.state.active] ?? true);
      selected = 0; selectedBand = 0; layoutUndo = null; busUndo = null;
      render(); toast(`Slot ${result.state.active} is live${result.seeded ? ', seeded from the previous slot' : ''}. Slots are held in this page only.`);
    }
    catch(e) { toast(e.message); }
    return;
  }
  if (action === 'slot-copy') {
    try { const other = SLOTS.find(name => name !== profileState.active); profileState = copySlot(profileState, profileState.active, other, config); renderSlots(); toast(`Slot ${other} now holds a copy of slot ${profileState.active}.`); }
    catch(e) { toast(e.message); }
    return;
  }
  if (action === 'eq-bypass-all') { try { config = setEqBypass(config, !config.eqBypass); markDraft(); render(); toast(config.eqBypass ? 'All output EQ bypassed. Bands are retained.' : 'Output EQ restored exactly as set.'); } catch(e) { toast(e.message); } return; }
  if (action === 'eq-reset-output') {
    try { config = resetEq(config, selected); config = mirrorLinkedEq(config, selected); markDraft(); render(); toast(`Reset all 16 bands of ${config.outputs[selected].label}. Gain, alignment and routing are unchanged.`); } catch(e) { toast(e.message); }
    return;
  }
  if (action === 'eq-reset-all') {
    if (!confirm('Reset all 16 bands on all 16 outputs? Gain, alignment, routing and presets are unchanged.')) return;
    try { config = resetEq(config, null); markDraft(); render(); toast('All 256 bands reset to defaults.'); } catch(e) { toast(e.message); }
    return;
  }
  if (action === 'eq-link') {
    try { const bus = getBus(config, b.dataset.busId); config = setBusEqLink(config, bus.id, !bus.linkEq); markDraft(); render(); toast(bus.linkEq ? 'Headphone ears unlinked; each keeps its current EQ.' : 'Headphone ears linked; the first ear\'s EQ was copied to the other.'); } catch(e) { toast(e.message); }
    return;
  }
  if (action === 'bus-add-headphones') { try { const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null); let n=0,id='headphones'; while(config.buses.some(v=>v.id===id)){n++;id=`headphones-${n+1}`;} config=createHeadphoneBus(config,id,free.slice(-2)); markDraft(); render(); toast('Headphones bus added on the last two free outputs. Set Left/Right output on its card to move it.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-add-speakers') { try { const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null); if(free.length<2) throw new Error('At least two free outputs are required'); let n=1,id='speakers-2'; while(config.buses.some(v=>v.id===id)){n++;id=`speakers-${n}`;} config=createSpeakerBus(config,id,free.slice(0,2),'stereo'); markDraft(); render(); toast('Speaker bus added on two free outputs.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-remove') { try { config=removeBus(config,b.dataset.busId); busUndo=null; markDraft(); render(); toast('Bus removed; its outputs are available.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-apply') { try { const bus=getBus(config,b.dataset.busId), layoutId=document.querySelector(`[data-bus="${CSS.escape(bus.id)}"][data-bus-param="layout"]`).value, layout=LAYOUTS.find(v=>v.id===layoutId); if(!layout) throw new Error('Choose an output format'); const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null), need=Math.max(0,layout.routing.length-bus.outputIds.length), ids=[...bus.outputIds,...free.slice(0,need)], touched=[...new Set([...bus.outputIds,...ids])], snapshot={busId:bus.id,bus:structuredClone(bus),outputs:Object.fromEntries(touched.map(i=>[i,structuredClone(config.outputs[i])])),sendColumns:Object.fromEntries(touched.map(i=>[i,config.sends.map(row=>row[i])]))}, next=applyBusLayout(config,bus.id,layoutId,ids); busUndo=snapshot; config=next; markDraft(); render(); toast(health && config.mode !== 'direct' ? `${bus.label} is ${layout.label} in this draft. The Pi still runs the installed preset: use Compile & apply this draft on System & presets to run it.` : `${bus.label} format applied to its bus.`); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-undo' && busUndo) { try { const saved=busUndo,result=structuredClone(config),bus=getBus(result,saved.busId); for(const i of Object.keys(saved.outputs)){const owner=result.outputs[i].busId;if(owner!==saved.busId && owner!==null) throw new Error(`Output ${Number(i)+1} was claimed by another bus; undo skipped`);} Object.assign(bus,saved.bus); Object.keys(saved.outputs).forEach(i=>{result.outputs[i]=saved.outputs[i]; saved.sendColumns[i].forEach((v,row)=>{result.sends[row][i]=v;});}); validateConfig(result); config=result; busUndo=null; markDraft(); render(); toast('Last bus format undone; unrelated buses preserved.'); } catch(e) { toast(e.message); } return; }
  if (action === 'crossover-apply') {
    const input=$('#crossover-hz');
    if(!input.reportValidity()) return;
    try {
      const targets=crossoverTargets();
      config=applyCrossover(config,targets,Number(input.value));
      crossoverHz=input.value; markDraft(); renderBass();
      toast(`Crossover set to ${crossoverHz} Hz for ${targets.length} channels. Individual edits remain available.`);
    } catch(e) {toast(e.message);}
    return;
  }
  if (action === 'layout-apply') {
    try {
      const next=applyLayout(config,$('#output-format').value);
      layoutUndo=structuredClone({outputs:config.outputs,sends:config.sends,bassEnabled:config.bassEnabled});
      config=next; selected=0; toast('Output format applied to draft. Undo format restores the previous outputs.');
    } catch(e) {toast(e.message);return;}
  } else if (action === 'layout-undo') {
    if(!layoutUndo)return; Object.assign(config,structuredClone(layoutUndo)); layoutUndo=null;selected=0;
  } else if (action === 'channel-copy') {
    channelClipboard=copyChannel(config.outputs[selected]);renderInspector();toast(`Copied ${channelClipboard.label}.`);return;
  } else if (action === 'channel-paste') {
    try {config=pasteChannel(config,selected,channelClipboard,pasteScope);config=mirrorLinkedEq(config,selected);toast(`Pasted ${pasteScope==='eq'?'EQ':'output processing'} into ${config.outputs[selected].label}.`);} catch(e){toast(e.message);return;}
  } else if (action === 'rew-open') {
    rewParsed=null;$('#rew-text').value='';$('#rew-file').value='';$('#rew-result').textContent='';$('#rew-apply').disabled=true;
    $('#rew-target').textContent=`Output ${selected+1} · ${config.outputs[selected].label}`;$('#rew-dialog').showModal();return;
  } else if (action === 'rew-close') {$('#rew-dialog').close();return;}
  else if (action === 'rew-apply') {
    if(!rewParsed)return;
    config.outputs[selected].bands=structuredClone(rewParsed.bands);config.outputs[selected].eqEnabled=true;syncLinkedEq();
    $('#rew-dialog').close();toast(`Imported ${rewParsed.count} REW filters into ${config.outputs[selected].label}.`);
  } else if (action === 'polarity') { const i = b.dataset.outIndex !== undefined ? Number(b.dataset.outIndex) : selected; config.outputs[i].invert = !config.outputs[i].invert; }
  else if (action === 'eq-toggle') { config.outputs[selected].eqEnabled = !config.outputs[selected].eqEnabled; syncLinkedEq(); }
  else if (action === 'save') { savePreset(); return; }
  else if (action === 'delete-preset') {
    const name = $('#saved-preset').value;
    if (name && confirm(`Delete preset "${name}" from ${presetStore.label}? The current draft is unaffected.`)) deletePreset(name);
    return;
  }
  else if (action === 'refresh-logs') { loadLiveLogs(); return; }
  else if (action === 'apply-profile') { applyProfile(); return; }
  else if (action === 'switch-profile') { applyChoice = b.dataset.name; applyProfile(); return; }
  else if (action === 'shutdown-pi') { shutdownPi(); return; }
  else if (action === 'apply-draft') { applyDraft(); return; }
  else if (action === 'remove-preset') { removeUserPreset(b.dataset.slug); return; }
  else if (action === 'load') {
    try { config = parsePreset(JSON.stringify(presets()[$('#saved-preset').value])); layoutUndo=null; busUndo=null; dirty = false; render(); toast(`Preset loaded from ${presetStore.label}. No device changes.`); } catch(e) { toast(`Could not load: ${e.message}`); } return;
  } else if (action === 'reset') { config = createConfig(); selected = 0; layoutUndo=null; busUndo=null; }
  else if (action === 'export') {
    const url = URL.createObjectURL(new Blob([JSON.stringify(config,null,2)],{type:'application/json'}));
    const a = document.createElement('a'); a.href = url; a.download = 'usb16x16-ui-preset.json'; a.click(); setTimeout(()=>URL.revokeObjectURL(url),1000); toast('Exported a UI preset, not a device configuration.'); return;
  } else return;
  markDraft(); render();
});

function previewRew() {
  try {
    rewParsed=parseRew($('#rew-text').value);$('#rew-apply').disabled=false;
    $('#rew-result').textContent=`${rewParsed.count} filters ready. ${rewParsed.skipped} off/unused rows skipped. Remaining bands will be disabled.`;
  } catch(e) {rewParsed=null;$('#rew-apply').disabled=true;$('#rew-result').textContent=e.message;}
}
document.addEventListener('input',event=>{
  if(event.target.id==='rew-text')previewRew();
  if(event.target.id==='crossover-hz')crossoverHz=event.target.value;
  if(event.target.id==='log-filter'){logQuery=event.target.value;renderLogView();}
  if(event.target.id==='log-paste'){logSnapshots[logService]=event.target.value.slice(0,200000);renderLogView();}
});
let rewFileRead=0;

document.addEventListener('change', async event => {
  const el = event.target;
  if(el.id==='log-service'){logService=el.value;$('#journal-command').textContent=journalCommand(logService, terms().stack);$('#log-paste').value=logSnapshots[logService];renderLogView();return;}
  if(el.id==='apply-profile-choice'){applyChoice=el.value;return;}
  if(el.id==='log-filter'||el.id==='log-paste')return;
  if (el.id === 'saved-preset'||el.id==='rew-text') return;
  if (el.id==='output-format') {document.querySelector('[data-action="layout-apply"]').disabled=el.value==='custom'||config.mode==='direct';return;}
  if (el.id==='paste-scope') {pasteScope=el.value;return;}
  if (el.id==='rew-file') {
    const read=++rewFileRead;
    try {
      const file=el.files[0];if(!file)return;if(file.size>200000)throw new Error('REW text must be under 200 KB');
      const content=await file.text();if(read!==rewFileRead)return;
      $('#rew-text').value=content;previewRew();
    }catch(e){rewParsed=null;$('#rew-apply').disabled=true;$('#rew-result').textContent=e.message;}
    return;
  }
  if (el.id === 'import-preset') {
    try { const file = el.files[0]; if (!file) return; if (file.size>200000) throw new Error('Preset is too large'); const imported = parsePreset(await file.text()); config = imported; selected = 0; layoutUndo=null; busUndo=null; markDraft(); render(); toast('UI preset imported into the local draft.'); } catch(e) { toast(`Import rejected: ${e.message}`); el.value = ''; } return;
  }
  if (el.disabled || el.closest('fieldset:disabled')) return;
  if(el.id==='eq-band-select'){selectedBand=Number(el.value);renderSelectedBand();$('#eq-band-select').focus({preventScroll:true});drawEq();return;}
  if(el.id==='channel-jump'){gotoOutput(Number(el.value));return;}
  if(el.id==='out-destination') {
    try {
      const destination=Number(el.value), previous=selected;
      config=swapOutputs(config,previous,destination);selected=destination;markDraft();render();
      toast(`Outputs ${previous+1} and ${destination+1} swapped, including processing and bass routes.`);
    } catch(e) {toast(e.message);renderInspector();}
    return;
  }
  if(el.id==='slot-preset') {
    if (!el.value) return;
    try {
      const stored = presets()[el.value];
      if (!stored) throw new Error('That preset is no longer saved in this browser');
      config = parsePreset(JSON.stringify(stored)); selected = 0; selectedBand = 0; layoutUndo = null; busUndo = null;
      dirty = false; slotDirty[profileState.active] = false;
      render(); toast(`Loaded “${el.value}” into slot ${profileState.active}. No device changes.`);
    } catch(e) { toast(`Could not load: ${e.message}`); renderSlots(); }
    return;
  }
  if(el.id==='crossover-hz') return;
  if (el.dataset.busOutput) {
    const bus = getBus(config, el.dataset.busOutput), ear = Number(el.dataset.ear);
    try {
      const targets = [...bus.outputIds]; targets[ear] = Number(el.value);
      const previous = bus.outputIds[ear];
      config = setBusOutputs(config, bus.id, targets);
      if (selected === previous) selected = Number(el.value);
      markDraft(); render();
      toast(`${bus.label} ${ear ? 'right' : 'left'} ear moved to output ${Number(el.value) + 1}.`);
    } catch(e) { toast(e.message); render(); }
    return;
  }
  if (el.dataset.headphoneMode) { try { config=setHeadphoneMode(config,el.dataset.headphoneMode,el.value); markDraft(); render(); } catch(e) { toast(e.message); render(); } return; }
  if (el.dataset.headphonePair) { try { const bus=getBus(config,el.dataset.headphonePair), pair=[...bus.inputPair]; pair[Number(el.dataset.ear)]=Number(el.value); config=setHeadphonePair(config,bus.id,pair); markDraft(); } catch(e) { toast(e.message); } return; }
  if (el.dataset.downmix) { const bus=getBus(config,el.dataset.downmix), i=Number(el.dataset.inputIndex), ear=Number(el.dataset.ear); try { if(el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.'); const matrix=structuredClone(bus.downmixMatrix); matrix[i][ear]=el.value===''?null:Number(el.value); config=setHeadphoneMatrix(config,bus.id,matrix); markDraft(); } catch(e) { el.value=bus.downmixMatrix[i][ear]??''; toast(e.message); } return; }
  if (el.dataset.bus) { const bus=getBus(config,el.dataset.bus), key=el.dataset.busParam; try { if(el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.'); const value=el.type==='checkbox'?el.checked:el.type==='number'?Number(el.value):el.value; if(key==='label'){const next=structuredClone(config);getBus(next,bus.id).label=value;validateConfig(next);config=next;markDraft();renderBuses();} else if(key==='gainDb'||key==='mute'){config=setBusGainMute(config,bus.id,key==='gainDb'?value:bus.gainDb,key==='mute'?value:bus.mute);markDraft();if(key==='gainDb')refreshSumBounds();} } catch(e) { if(key==='gainDb') el.value=bus.gainDb; else if(key==='mute') el.checked=bus.mute; else if(key==='label') el.value=bus.label; toast(e.message); } return; }
  if(el.id==='crossover-scope') {crossoverScope=el.value;refreshCrossoverControls();return;}
  if(el.dataset.crossoverSelect!==undefined||el.id==='crossover-select-all') {
    if(el.id==='crossover-select-all') {
      crossoverSelection.clear();
      if(el.checked) speakerGroupSourceIds(config).forEach(i=>{if(i!==config.lfe.input)crossoverSelection.add(i);});
      document.querySelectorAll('[data-crossover-select]').forEach(input=>{input.checked=el.checked;});
    } else {
      const i=Number(el.dataset.crossoverSelect);
      if(el.checked)crossoverSelection.add(i);else crossoverSelection.delete(i);
    }
    crossoverScope='selected';refreshCrossoverControls();return;
  }
  const before = structuredClone(config), id = el.id;
  try {
    if (el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.');
    const value = el.type==='checkbox' ? el.checked : el.type==='number' ? Number(el.value) : el.value;
    if (el.dataset.out) {
      const key = el.dataset.out, index = el.dataset.outIndex !== undefined ? Number(el.dataset.outIndex) : selected;
      if (key==='role') setOutputRole(config,index,value);
      else { config.outputs[index][key] = key==='source' ? Number(value) : value; if(key==='source' && config.outputs[index].busId) { const owner=config.buses.find(b=>b.id===config.outputs[index].busId); if(owner) owner.layoutId='custom'; } }
    } else if (el.dataset.band !== undefined) config.outputs[selected].bands[Number(el.dataset.band)][el.dataset.param] = value;
    else if (el.dataset.input !== undefined) config.inputs[Number(el.dataset.input)][el.dataset.param] = el.dataset.param==='slope' ? Number(value) : value;
    else if (el.dataset.lfe) {
      if (el.dataset.lfe==='input') { config.sends[config.lfe.input].fill(null); config.sends[Number(value)].fill(null); }
      config.lfe[el.dataset.lfe] = Number(value);
    } else if (el.dataset.send) { const [i,j] = el.dataset.send.split(',').map(Number); config.sends[i][j] = value ? 0 : null; }
    else if (el.dataset.sendGain) { const [i,j] = el.dataset.sendGain.split(',').map(Number); config.sends[i][j] = value; }
    else if (id==='headroom') config.headroomDb = value;
    else if (id==='bass-enabled') config.bassEnabled = value;
    else if (id==='preset-name') config.name = value;
    else return;
    validateConfig(config); markDraft();
  } catch(e) {
    config = before; toast(e.message);
    const aria = el.getAttribute('aria-label'); render();
    const focus = id ? document.getElementById(id) : aria ? [...document.querySelectorAll('[aria-label]')].find(e=>e.getAttribute('aria-label')===aria) : null;
    if (focus && !focus.disabled) focus.focus({preventScroll:true});
    return;
  }
  // Any successful edit can change which crossovers are active, and the note
  // is refreshed in place so this stays independent of the surgical re-renders
  // below.
  refreshPolarityNote();
  // Keep the form being edited mounted: replacing it on blur can swallow the
  // next click or send keyboard focus back to the field the user just left.
  if (el.dataset.out) {
    const index = el.dataset.outIndex !== undefined ? Number(el.dataset.outIndex) : selected;
    renderLayout(); renderBank(); renderBass(); renderSettings();
    if (el.dataset.out==='role') { renderOverview(); renderInspector(); renderBuses(); }
    else {
      // Keep the edited row mounted: only the derived labels are refreshed.
      if (index===selected) {
        $('#inspector h2').innerHTML = `<span class="badge">${pad(selected)}</span>${esc(config.outputs[selected].label)}`;
        $('#out-destination').options[selected].textContent=`${pad(selected)} · ${config.outputs[selected].label}`;
      } else if (el.dataset.out==='label') $('#out-destination').options[index].textContent=`${pad(index)} · ${config.outputs[index].label}${index===selected?'':' (swap)'}`;
      if (el.dataset.out==='source') renderBuses();
    }
  } else if (el.dataset.band !== undefined) {
    if(selectedBand!==Number(el.dataset.band)){selectedBand=Number(el.dataset.band);renderSelectedBand();}
    syncLinkedEq(); drawEq();
  } else if (el.dataset.input !== undefined) {
    if (el.dataset.param==='label') { renderBank(); renderInspector(); renderBass(); renderBuses(); }
    else if (el.dataset.param==='crossover') renderBass();
  } else if (el.dataset.lfe) {
    if (el.dataset.lfe==='input') renderBass();
    else {
      const row = document.querySelector('.lfe-row');
      if (row) { row.cells[3].textContent=`${config.lfe.lowpassHz} Hz`; row.cells[4].textContent=`${config.lfe.slope} dB/oct`; }
      refreshSumBounds();
    }
  } else if (el.dataset.send || id==='bass-enabled') renderBass();
  else if (el.dataset.sendGain || id==='headroom') refreshSumBounds();
});

/** The live window if the tap answered within the last 1.5 s, else null. */
function currentLiveMeters() {
  return liveMeters && performance.now() - liveMetersAt < 1500 ? liveMeters : null;
}

function syncMeterLabels() {
  const live = Boolean(currentLiveMeters());
  const toggle = $('#meter-toggle');
  if (toggle) toggle.textContent = live ? (metersRunning ? 'Pause meters' : 'Resume meters') : (metersRunning ? 'Pause demo meters' : 'Resume demo meters');
  const summary = $('#input-meters summary');
  if (summary) summary.textContent = live ? 'Input meters · USB from the host · live, before the DSP stage' : 'Input meters · selected source · simulated';
}

// One strip from a live channel: the window's peak in dBFS, a clip hold of
// 1.5 s whenever the cumulative clip count moved since the last window.
function drawLiveStrip(bank, i, channel, bar, label, now) {
  const db = metersRunning ? channel.peak : -60;
  if (bar) bar.style.setProperty('--level',`${Math.max(0,Math.min(100,(db+60)/60*100))}%`);
  const seen = clipSeen[bank][i];
  if (seen !== null && channel.clipped > seen) clipHold[bank][i] = now + 1500;
  clipSeen[bank][i] = channel.clipped;
  if (label) {
    label.textContent = !metersRunning || db <= -60 ? '—' : db.toFixed(1);
    label.classList.toggle('clip', clipHold[bank][i] > now);
  }
}

function updateMeters() {
  if (document.hidden || tab!=='outputs') return;
  const now = performance.now(), t = now/1000;
  const live = currentLiveMeters();
  config.outputs.forEach((o,i)=>{
    const bar = $(`#meter-${i}`), label = $(`#level-${i}`);
    if (live) { drawLiveStrip('outputs', i, live.outputs[i], bar, label, now); return; }
    const bus = config.buses?.find(b=>b.id===o.busId);
    const quiet = !metersRunning || (config.mode==='dsp' && (o.role==='unused'||o.mute||bus?.mute));
    // Deliberately synthetic display activity, never represented as a DSP/audio simulation.
    const db = quiet ? -60 : -25 + 8*Math.sin(t*1.4+i*.67) + 3*Math.sin(t*3.1+i);
    if (bar) bar.style.setProperty('--level',`${Math.max(0,(db+60)/60*100)}%`);
    if (label) { label.textContent = quiet ? '—' : db.toFixed(1); label.classList.remove('clip'); }
  });
  if ($('#input-meters').open) config.inputs.forEach((o,i)=>{
    const bar = $(`#input-meter-${i}`), label = $(`#input-level-${i}`);
    if (live) { drawLiveStrip('inputs', i, live.inputs[i], bar, label, now); return; }
    const db = metersRunning ? -29+9*Math.sin(t*1.2+i*.6) : -60;
    bar.style.setProperty('--level',`${Math.max(0,(db+60)/60*100)}%`);
    label.textContent = metersRunning ? db.toFixed(1) : '—';
    label.classList.remove('clip');
  });
}

// Read the tap at up to 10 Hz, only while the Outputs page is on screen and
// the service says a tap exists; one request in flight at a time, so a slow
// answer thins the rate rather than queueing.
async function pollMeters() {
  if (meterBusy || document.hidden || tab!=='outputs' || !health?.meters?.available) return;
  meterBusy = true;
  try {
    const levels = meterLevels(await fetchMeters());
    const wasLive = Boolean(currentLiveMeters());
    if (levels) { liveMeters = levels; liveMetersAt = performance.now(); }
    if (wasLive !== Boolean(currentLiveMeters())) syncMeterLabels();
  } finally { meterBusy = false; }
}
setInterval(() => { pollMeters(); if (liveMeters && !currentLiveMeters()) { liveMeters = null; syncMeterLabels(); } }, METER_POLL_MS);
$('.brand').addEventListener('click',event=>{event.preventDefault(); tab='outputs';render();});
$('#eq-dialog').addEventListener('close',()=>{endEqDrag(true);renderOverview();});
// Narrow screens open with the meter bank collapsed: less scrolling before the controls.
if (window.matchMedia('(max-width: 900px)').matches) {
  $('#input-meters').open = false;
  sectionOpen.buses = false; sectionOpen.bass = false;
}
document.addEventListener('toggle', event => {
  const section = event.target.closest?.('[data-section]');
  if (section) sectionOpen[section.dataset.section] = section.open;
}, true);
profileState = createSlots(config);
render();
setInterval(updateMeters,100);

// ------------------------------------------------------- Pi control service
//
// The page is fully usable with no backend. One probe decides which world we
// are in; after that a single slow poll keeps the status panel current. The
// service publishes a cached snapshot, so this poll costs the Pi the same
// whether one browser or ten are open. Nothing here can change device state:
// the service has no control endpoint to call.

let pollTimer = null;

async function pollHealth() {
  const next = await probeHealth();
  const wasConnected = Boolean(health);
  health = next;
  if (!wasConnected && next) {
    toast(`Connected to ${next.host || 'the Pi'}. Status and logs are live; profile switches go through Apply in Settings.`);
    await adoptStore(piStore());
    followLivePreset(next);
  } else if (wasConnected && !next) {
    toast(shutdownRequested ? 'The Pi has powered off. Once activity stops, unplug the USB data cable, then PoE.' : 'Lost the Pi control service. Showing the local draft; presets are back in this browser.');
    shutdownRequested = false;
    await adoptStore(browserStore(storageKey));
  }
  if (next?.apply && !applyPoll) {
    applyStatus = null; // the 1 Hz snapshot is the source of truth while nothing of ours is running
    if (next.apply.inFlight || next.apply.pending) startApplyPolling();
  }
  // The bridge's answer to the last live update arrives through health.
  if (next?.dspLive?.sha256 && next.dspLive.state === 'applied' && liveLastSent === next.dspLive.sha256) liveLine = `Applied (${next.dspLive.sha256.slice(0, 8)}).`;
  if (!next) { liveQueue.cancel(); liveLastSent = null; }
  // Self-heal: the bridge runs something other than what this page last
  // sent (a request the applier never took, a watcher that was down) and
  // nothing is pending or in flight: send the current draft again.
  const foreign = next?.dspLive?.state === 'applied' && liveLastSent && next.dspLive.sha256 !== liveLastSent ? next.dspLive.sha256 : null;
  liveForeignSeen = foreign && foreign === liveForeignSeen.sha ? {sha: foreign, polls: liveForeignSeen.polls + 1} : {sha: foreign, polls: foreign ? 1 : 0};
  if (foreign && liveForeignSeen.polls >= 2 && Date.now() - liveLastReceiptAt > 3000
      && foreign !== liveAnsweredForeign
      && !liveQueue.busy && !next.apply?.pending && !next.apply?.inFlight && liveState(next, draftShapeKey).state === 'live') {
    liveAnsweredForeign = foreign;
    liveLastSent = null;
    liveLine = `The ${terms().engine} is not on this page's last edit; sending it again…`;
    scheduleLive();
  }
  refreshSettingsLive();
  renderConnection();
  renderLiveState();
  $('#mode-note').textContent = modeNote(config.mode === 'direct');
}

/** Swap the preset store, keeping the page usable if the new one cannot be read. */
async function adoptStore(store) {
  try { await store.refresh(); presetStore = store; }
  catch (e) { toast(`Could not read presets from ${store.label}: ${e.message}`); return; }
  render();
}

function startPolling() {
  if (pollTimer) return;
  pollHealth();
  // Pause while the tab is hidden: an idle client should not keep the Pi busy.
  pollTimer = setInterval(() => { if (!document.hidden) pollHealth(); }, POLL_MS);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) pollHealth(); });
startPolling();
