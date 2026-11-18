// Control Room (phase 3): a card per speaker set and per headphones (or one
// Main volume card and the set switch when there are several speaker sets),
// and the overview of each playing speaker set. Pure: C is controlRoom(...)
// from monitor.mjs, out comes HTML text. Nothing here is part of a preset.
//
// Three numbers are set from script after a redraw, as custom properties, as
// the meters are: the knob's angle (data-rot), a tile's place in the room
// (data-x, data-y) and every meter level (by id). No inline styles.
import { esc, pressed, disabledAttr } from './ui.mjs';
import { dbWords } from './monitor.mjs';

const cr = (...parts) => `data-cr="${esc(parts.join(';'))}"`;

function bank(c) {
  if (c.vertical) {
    return `<div class="cr-bank" aria-hidden="true">${c.outputs.map((o, i) => `<div class="cr-bar-cell${c.outputs.length > 8 && i % 2 ? ' low' : ''}">
      <span class="clip-light" id="cro-${esc(c.key)}-${o.n}"></span><span class="bar cr-bar" id="crm-${esc(c.key)}-${o.n}"><i></i><b></b></span>
      <span class="cr-tag${o.sub ? ' sub' : ''}">${esc(o.tag)}</span></div>`).join('')}</div>`;
  }
  return `<div class="cr-hbank" aria-hidden="true">${c.outputs.map(o => `<div class="cr-hrow"><span class="cr-tag${o.sub ? ' sub' : ''}">${esc(o.tag)}</span>
    <span class="mini-meter" id="crm-${esc(c.key)}-${o.n}"><i></i><b></b></span><span class="clip-light" id="cro-${esc(c.key)}-${o.n}"></span></div>`).join('')}</div>`;
}

function card(c) {
  const k = c.key, t = c.title;
  const trims = !c.trims ? '' : `<div class="cr-trims" role="group" aria-label="Speaker sets and their trims">${c.trims.map(s => `<div class="cr-trim${s.playing ? ' playing' : ''}">
      <span class="cr-trim-name"><i class="dot${s.playing ? ' on' : ''}" aria-hidden="true"></i><strong>${esc(s.label)}</strong><span class="muted">plays at ${esc(s.plays)}</span></span>
      <span class="muted">Trim</span>
      <button type="button" class="step" ${cr('trim-step', s.id, -1)} aria-label="Lower the ${esc(s.label)} trim by 0.5 dB">−</button>
      <input type="text" inputmode="decimal" class="cr-num" data-m="trim" data-v="${esc(s.id)}" value="${esc(dbWords(s.trim))}" aria-label="${esc(s.label)} trim in dB, from −12 to +12">
      <button type="button" class="step" ${cr('trim-step', s.id, 1)} aria-label="Raise the ${esc(s.label)} trim by 0.5 dB">+</button></div>`).join('')}</div>`;
  const folds = !c.showFolds ? '' : `<div class="cr-folds" role="group" aria-label="Listen as"><span class="muted">Listen as</span>${c.folds.map(f => `<button type="button" ${cr('fold', k, f.fold)} ${pressed(f.on)} aria-label="Listen as ${esc(f.label)}">${esc(f.label)}</button>`).join('')}</div>`;
  const subs = !c.subs ? '' : `<button type="button" class="cr-subs${c.subs.on ? '' : ' off'}" ${cr('subs')} ${pressed(c.subs.on)}
      title="${c.subs.on ? 'The subwoofers are playing. Click to mute them; their bass is not sent to the main speakers.' : 'The subwoofers are muted, and their bass is not sent to the main speakers. Click to turn them on.'}"
      aria-label="${c.subs.on ? 'Subwoofers on. Mute the subwoofers; their bass is not sent to the main speakers.' : 'Subwoofers off: muted, their bass is not sent to the main speakers. Turn them on.'}">${c.subs.on ? 'Subwoofers on' : 'Subwoofers off'}</button>`;
  const refFields = !c.refOpen ? '' : c.locked
    ? `<span class="muted">Reference ${esc(dbWords(c.ref))}${c.note ? ` · ${esc(c.note)}` : ''}. The reference is locked on the System tab.</span>`
    : `<span class="muted">Reference</span><input type="text" inputmode="decimal" class="cr-num cr-ref" data-m="ref" data-v="${esc(k)}" value="${esc(dbWords(c.ref))}" aria-label="${esc(t)} reference level in dB" ${disabledAttr(c.busy)}>
      <input type="text" class="cr-note" data-m="note" data-v="${esc(k)}" value="${esc(c.note)}" maxlength="64" placeholder="What it measures, e.g. 79 dB SPL" aria-label="What the ${esc(t)} reference measures" ${disabledAttr(c.busy)}>`;
  const refRow = c.refOpen || subs ? `<div class="cr-refrow">${subs}${refFields}</div>` : '';
  return `<section class="cr-card kind-${esc(c.kind)}${c.wide ? ' wide' : ''}" id="cr-card-${esc(k)}" aria-label="${esc(t)} level">
    <div class="cr-knob-box">
      <div class="cr-ring" aria-hidden="true">${c.leds.map(cls => `<i class="led${cls ? ` ${cls}` : ''}"></i>`).join('')}</div>
      <button type="button" class="cr-knob" role="slider" data-knob="${esc(k)}" data-rot="${c.angle}" aria-label="${esc(t)} level. Drag up or down, or use the arrow keys."
        aria-valuemin="-60" aria-valuemax="${c.maxDb}" aria-valuenow="${c.level}" aria-valuetext="${esc(dbWords(c.level))}"><span class="cr-pointer${c.mute ? ' muted' : ''}" aria-hidden="true"></span></button>
    </div>
    <div class="cr-controls dense">
      <div class="cr-head"><strong class="cr-title">${esc(t)}</strong>
        <button type="button" class="cr-state${c.tone ? ` tone-${c.tone}` : ''}" ${cr('ref-toggle', k)} aria-expanded="${c.refOpen}" aria-label="Reference settings for ${esc(t)}: ${esc(c.state)}" title="Reference settings">${esc(c.state)}</button></div>
      <input type="text" inputmode="decimal" class="cr-level" data-m="level" data-v="${esc(k)}" value="${esc(dbWords(c.level))}" aria-label="${esc(t)} level in dB, from −60 to ${esc(dbWords(c.maxDb))}">
      <div class="cr-buttons">
        <button type="button" ${cr('step', k, -1)} aria-label="Lower ${esc(t)} by 1 dB">−</button>
        <button type="button" ${cr('step', k, 1)} aria-label="Raise ${esc(t)} by 1 dB">+</button>
        <button type="button" class="cr-dim" ${cr('dim', k)} ${pressed(c.dim)}>Dim</button>
        <button type="button" class="cr-mute" ${cr('mute', k)} ${pressed(c.mute)}>Mute</button>
        <button type="button" ${cr('to-ref', k)} aria-label="Go to the reference level, ${esc(dbWords(c.ref))}" title="Go to the reference level, ${esc(dbWords(c.ref))}">Ref</button>
        ${c.locked ? '' : `<button type="button" class="cr-set" ${cr('set-ref', k)} aria-label="Store ${esc(dbWords(c.level))} as the reference for ${esc(t)}" title="Store ${esc(dbWords(c.level))} as the reference for ${esc(t)}" ${disabledAttr(c.busy)}>Set</button>`}
      </div>
    </div>
    <div class="cr-side">
      <span class="cr-peak" role="status"><span>Hearing the computer</span><span id="crp-${esc(k)}">${esc(c.peakText)}</span></span>
      ${bank(c)}
    </div>
    ${trims}${folds}${refRow}
  </section>`;
}

function setSwitch(C) {
  if (!C.several) return '';
  return `<div class="cr-sets" role="group" aria-label="Which speakers are playing">${C.setSwitch.map(s => `<button type="button" class="cr-set-pick${s.id === 'all' ? ' all' : ''}" ${cr('active', s.id)} ${pressed(s.on)} aria-label="${esc(s.aria)}">
    <i class="dot${s.lit ? ' on' : ''}" aria-hidden="true"></i><span class="cr-set-text"><strong>${esc(s.label)}</strong><span class="cr-set-sub">${esc(s.sub)}</span></span>
    ${s.meter ? `<span class="mini-meter" id="crs-${esc(s.id)}" aria-hidden="true"><i></i><b></b></span>` : ''}</button>`).join('')}</div>`;
}

function tile(r, t, placed) {
  const what = r.editing ? (t.picked ? `Take ${t.name} out of the new group` : `Add ${t.name} to the new group`) : `${t.soloed ? 'Stop soloing' : 'Solo'} ${t.name}`;
  return `<div class="cr-tile${t.soloed ? ' soloed' : ''}${t.muted ? ' muted' : ''}${t.picked ? ' picked' : ''}"${placed ? ` data-x="${t.x}" data-y="${t.y}"` : ''}>
    <button type="button" class="cr-tile-name" ${cr(r.editing ? 'pick' : 'solo', r.id, t.n)} ${pressed(r.editing ? t.picked : t.soloed)} aria-label="${esc(what)}"><strong>${esc(t.name)}</strong><span class="mini-meter" id="crt-${esc(r.id)}-${t.n}" aria-hidden="true"><i></i><b></b></span></button>
    <button type="button" class="cr-s" ${cr('solo', r.id, t.n)} ${pressed(t.soloed)} aria-label="${t.soloed ? 'Stop soloing' : 'Solo'} ${esc(t.name)}">S</button>
    <button type="button" class="cr-m" ${cr('out-mute', r.id, t.n)} ${pressed(t.muted)} aria-label="${t.muted ? 'Unmute' : 'Mute'} ${esc(t.name)}">M</button></div>`;
}

function room(C, r) {
  const chips = r.chips.map(g => `<div class="cr-chip${g.soloOn ? ' solo' : g.muteOn ? ' mute' : ''}${g.custom ? ' custom' : ''}"><span>${esc(g.name)}</span>
      <button type="button" class="cr-s" ${cr('group-solo', r.id, g.outs.join(','))} ${pressed(g.soloOn)} aria-label="Solo ${esc(g.name)}. Hold Command or Control to add to the current solo.">S</button>
      <button type="button" class="cr-m" ${cr('group-mute', r.id, g.outs.join(','))} ${pressed(g.muteOn)} aria-label="${g.muteOn ? 'Unmute' : 'Mute'} ${esc(g.name)}">M</button>
      ${g.custom ? `<button type="button" class="cr-x" ${cr('group-remove', r.id, g.custom)} aria-label="Remove the group ${esc(g.name)}">×</button>` : ''}</div>`).join('');
  const editor = !r.editing ? '' : `<div class="cr-group-edit" role="group" aria-label="New group">
      <input type="text" data-m="group-name" value="${esc(r.groupName)}" maxlength="40" placeholder="Group name" aria-label="Group name">
      <span class="muted" id="cr-group-hint">${r.picked ? `${r.picked} picked.` : 'Pick speakers in the room below.'}</span>
      <button type="button" class="primary" ${cr('group-save', r.id)} ${disabledAttr(!r.picked)}>Save group</button><button type="button" ${cr('group-cancel')}>Cancel</button></div>`;
  return `<section class="cr-room-panel" id="cr-room-${esc(r.id)}" aria-label="${esc(r.title)}">
    <div class="row-head"><div class="cr-room-title"><strong>${esc(r.title)}</strong><span class="muted">solo and mute · meters after the level knob</span></div>
      <div class="toolbar">${C.anySolo ? `<button type="button" class="cr-clear-solo" ${cr('clear-solo')}>Clear solo</button>` : ''}
        <button type="button" class="cr-clear-clips" ${cr('clear-clips')} data-clips ${C.anyClip ? '' : 'hidden'}>Clear clips</button>
        ${r.idle ? `<button type="button" class="cr-new-group" ${cr('group-new', r.id)}>New group</button>` : ''}</div></div>
    ${chips ? `<div class="cr-chips dense" role="group" aria-label="Solo and mute groups">${chips}</div>` : ''}
    ${editor}
    ${r.tiles.length ? `<div class="cr-room" role="group" aria-label="${esc(r.title)}, seen from above. Click a speaker to solo it. Solo and mute here are not saved.">
      <span class="cr-front" aria-hidden="true">FRONT</span><i class="cr-listener" aria-hidden="true"></i>${r.tiles.map(t => tile(r, t, true)).join('')}</div>` : ''}
    ${r.unplaced.length ? `<span class="muted">Not shown in the room: ${esc(r.unplaced.join(', '))}.</span><div class="cr-loose">${r.loose.map(t => tile(r, t, false)).join('')}</div>` : ''}
  </section>`;
}

export function controlRoomView(C) {
  const head = `<section class="cr-header" aria-label="Control Room">
    <div class="row-head"><div class="toolbar"><strong class="title">Control Room</strong>
      <button type="button" class="quiet cr-keys-btn" ${cr('keys')} aria-expanded="${C.keysOpen}">Keyboard shortcuts</button></div>
      <span class="muted">Everything here is <strong class="cr-instant">instant</strong>, is not part of a preset, and is kept on the device across restarts.</span></div>
    ${C.keysOpen ? `<div class="cr-keys" role="group" aria-label="Keyboard shortcuts">${C.keys.map(([k, text]) => `<span><kbd>${esc(k)}</kbd><span class="muted">${esc(text)}</span></span>`).join('')}
      <span class="muted cr-keys-note">They work while the Control Room has the keyboard focus (click anywhere on it first) and not while you are typing in a field.</span></div>` : ''}
    ${C.refused ? `<p class="banner warn" role="status"><strong>Warning:</strong> The device refused the last change and kept what it had: ${esc(C.refused)}</p>` : ''}
  </section>`;
  if (C.empty) return `${head}<p class="muted">This preset has no speaker sets or headphones, so there is nothing to control. Add one on Processor.</p>`;
  return `${head}
    <div class="cr-cards${C.several || C.cards.length > 2 ? ' grid' : ''}">${C.cards.map(card).join('')}</div>
    ${setSwitch(C)}
    ${C.rooms.map(r => room(C, r)).join('')}`;
}
