// System: what the device is and how it is doing, the display setting, the
// actions (restarts, support bundle, password, reboot, shut down), the presets
// on the device, the last change made to it, and its logs.
import { esc, pressed, disabledAttr, options } from './ui.mjs';
import { actionCards } from './actions.mjs';

/** The live facts. Rebuilt on each health poll; holds no input. */
export function devicePanel(S) {
  return `<section class="panel" id="device-panel" aria-label="Device"><div class="row-head"><strong class="title">Device</strong><span class="muted">${S.connected ? `Read from the device at ${esc(S.generated || 'an unknown time')}` : 'Not connected'}</span></div>
    <dl class="facts">${S.facts.map(row => `<div><dt>${esc(row.label)}</dt><dd class="fact-${row.state || 'plain'}"${row.title ? ` title="${esc(row.title)}"` : ''}>${esc(row.value)}</dd></div>`).join('')}</dl></section>`;
}

export function presetsPanel(S) {
  const {fixed, presets} = S.presetRows, busy = S.busy;
  const run = (kind, name, can) => can ? `<button type="button" data-act="preset-run" data-v="${kind};${esc(name)}" ${disabledAttr(busy)}>Run it</button>` : '';
  const fixedRows = fixed.map(p => `<div class="preset-row ${p.running ? 'is-running' : ''}"><span><strong>${esc(p.title)}</strong> ${p.running ? '<span class="tag on">Running</span>' : ''} <span class="muted">${esc(p.note)}</span></span>
    <div class="toolbar">${run('profile', p.name, p.canRun)}</div></div>`).join('');
  const rows = presets.map(p => `<div class="preset-row ${p.running ? 'is-running' : ''}"><span><strong>${esc(p.name)}</strong> ${p.running ? '<span class="tag on">Running</span>' : ''} ${p.name === S.editing ? '<span class="tag">Open in Processor</span>' : ''} <span class="muted">${esc(p.running ? '' : p.note)}</span></span>
    <div class="toolbar">${run('preset', p.name, p.canRun)}
      ${p.canEdit ? `<button type="button" data-act="preset-open" data-v="${esc(p.name)}" aria-label="Open ${esc(p.name)} in the Processor">Open</button>` : ''}
      ${p.canEdit || p.canRemove ? `<details class="menu" data-menu="${esc(p.name)}"><summary aria-label="More for ${esc(p.name)}">More</summary><div class="menu-items">
        ${p.canRename ? `<button type="button" data-act="preset-rename" data-v="${esc(p.name)}" ${disabledAttr(busy)}>Rename</button>` : ''}
        ${p.canEdit ? `<button type="button" data-act="preset-duplicate" data-v="${esc(p.name)}">Duplicate</button>
        <button type="button" data-act="preset-export" data-v="${esc(p.name)}">Export</button>` : ''}
        ${p.canRemove ? `<button type="button" data-act="preset-remove" data-v="${esc(p.name)}" ${disabledAttr(busy)}>Remove</button>` : ''}</div></details>` : ''}</div></div>`).join('');
  return `<section class="panel" id="presets-panel" aria-label="Presets on the device">
    <div class="row-head"><div><strong class="title">${S.connected ? 'Presets on the device' : 'Presets in this browser'}</strong> <span class="muted">${S.connected ? `Running a preset restarts audio: ${esc(S.outage)}.` : 'Not connected: these are kept in this browser and cannot run.'}</span></div>
      <label class="file-pick">Import a preset file…<input type="file" id="preset-import" accept=".json,application/json"></label></div>
    ${S.applyReason ? `<p class="banner note">${esc(S.applyReason)}</p>` : ''}
    ${fixedRows}${rows || '<p class="muted">No presets yet. Make one in the Processor and apply or save it.</p>'}</section>`;
}

/** The last thing the device was asked to do, from the applier's own receipt. */
export function lastChangePanel(S) {
  const steps = S.applySteps || [];
  return `<section class="panel" id="change-panel" aria-label="Last change"><div class="row-head"><strong class="title">Last change to the device</strong></div>
    <p role="status">${esc(S.applyLine)}</p>
    ${steps.length ? `<ol class="steps">${steps.map(step => `<li class="${step.ok ? '' : 'warn-text'}"><strong>${esc(step.label)}</strong>${step.detail ? ` <span class="muted">${esc(step.detail)}</span>` : ''}</li>`).join('')}</ol>` : ''}</section>`;
}

/**
 * Restart audio or the clock, the support bundle, the page password, reboot,
 * shut down: the ones the device lists (S.actions), in that order. Not
 * connected, or nothing listed: no panel.
 */
export function actionsPanel(S) {
  const cards = S.connected ? actionCards(S.actions, {outage: S.outage}) : [];
  if (!cards.length) return '';
  const note = S.actionNote;
  const off = S.busy || S.shutdownRequested || S.rebootRequested;
  const label = card => card.kind === 'shutdown' && S.shutdownRequested ? 'Shutting down…' : card.kind === 'reboot' && S.rebootRequested ? 'Rebooting…' : card.label;
  return `<section class="panel" id="actions-panel" aria-label="Actions"><div class="row-head"><strong class="title">Actions</strong><span role="status" class="action-note${note ? ` tone-${esc(note.tone)}` : ''}">${esc(note?.text || '')}</span></div>
    <div class="action-cards">${cards.map(card => `<div class="action-card"><span class="muted">${esc(card.text)}</span>
      <button type="button" class="${card.tone === 'danger' ? 'danger' : card.tone === 'caution' ? 'caution' : ''}" data-act="sys-action" data-v="${esc(card.kind)}" ${disabledAttr(off)}>${esc(label(card))}</button></div>`).join('')}</div></section>`;
}

export function systemView(S) {
  return `${devicePanel(S)}
    <section class="panel" aria-label="Display"><div class="row-head split"><div><strong class="title">Display</strong> <span class="muted">Larger controls suit a tablet or touch screen; the page gets taller. This is remembered in this browser only.</span></div>
      <button type="button" class="toggle" data-act="big-toggle" ${pressed(S.big)}>${S.big ? 'Larger controls: on' : 'Larger controls: off'}</button></div></section>
    ${actionsPanel(S)}
    ${presetsPanel(S)}
    ${S.connected ? lastChangePanel(S) : ''}
    <section class="panel" aria-label="Logs"><div class="row-head"><strong class="title">Service logs</strong>
      <div class="toolbar"><label class="inline">Service <select id="log-service">${options(S.logServices, S.logService)}</select></label>
        <label class="inline">Find <input type="search" id="log-filter" data-k="log-filter" value="${esc(S.logQuery)}" placeholder="Text to find"></label>
        <button type="button" data-act="log-refresh" ${disabledAttr(!S.connected || S.logBusy)}>${S.logBusy ? 'Reading…' : 'Read the last 200 lines'}</button>
        <button type="button" data-act="log-copy" ${disabledAttr(!S.logText)}>Copy</button></div></div>
      <div class="log-view" tabindex="0" role="region" aria-label="Service log"><pre id="log-output">${esc(S.logShown)}</pre></div>
      <p class="muted" id="log-count" role="status">${esc(S.logCount)}</p></section>`;
}
