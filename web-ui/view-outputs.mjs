// Processor > Outputs: one row per output (name, level, delay, polarity, EQ,
// on or off), grouped by speaker set and headphones, with align by distance
// and the EQ editor beside the rows. Saved in the preset.
import { eqResponse } from './model.mjs';
import { MAX_DELAY_MS } from './align.mjs';
import { esc, pad, pressed, numField, segmented, dbText, msText, disabledAttr } from './ui.mjs';

export const BAND_COLORS = ['#f39364', '#e6b35c', '#d9d464', '#add875', '#6bdaa3', '#65d5c8', '#68b8eb', '#849af3', '#aa92ec', '#cd8ee0', '#e486b9', '#ed8694', '#c6ac83', '#95b9aa', '#a6add5', '#b6c878'];

/** The EQ curve of one output as points for a 56 x 22 thumbnail, +-12 dB. */
export function thumbPoints(output, bypassAll) {
  return Array.from({length: 29}, (_, n) => {
    const f = 20 * 1000 ** (n / 28), db = Math.max(-12, Math.min(12, eqResponse(output, f, bypassAll)));
    return `${(n * 2).toFixed(0)},${(11 - db * 11 / 12).toFixed(1)}`;
  }).join(' ');
}

function row(S, i) {
  const o = S.config.outputs[i], name = `output ${i + 1}, ${o.label}`;
  const shaped = !S.config.eqBypass && o.eqEnabled && o.bands.some(b => b.enabled && b.gainDb !== 0);
  return `<div class="out-row ${o.mute ? 'is-off' : ''} ${S.eqOpen === i ? 'is-open' : ''}" data-row="${i}">
    <span class="num">${pad(i)}</span>
    <input type="text" class="name" data-f="out.label" data-i="${i}" data-k="out.label:${i}" value="${esc(o.label)}" maxlength="64" aria-label="Name of output ${i + 1}">
    <span class="mini-meter" id="om-${i}" aria-hidden="true"><i></i><b></b></span>
    ${numField({f: 'out.gainDb', i, value: dbText(o.gainDb), label: `Level of ${name}, in dB`, unit: 'dB'})}
    ${numField({f: 'out.delayMs', i, value: msText(o.delayMs), label: `Delay of ${name}, in milliseconds`, unit: 'ms'})}
    <button type="button" class="toggle pol" data-act="pol" data-i="${i}" ${pressed(o.invert)} aria-label="Reverse the polarity of ${esc(name)}" title="Polarity">Ø</button>
    <button type="button" class="eq-thumb ${shaped ? 'shaped' : ''}" data-act="eq-open" data-i="${i}" ${pressed(S.eqOpen === i)} aria-label="EQ of ${esc(name)}${shaped ? '' : ', flat'}">
      <svg aria-hidden="true" width="56" height="22" viewBox="0 0 56 22" preserveAspectRatio="none"><line x1="0" y1="11" x2="56" y2="11"></line><polyline points="${thumbPoints(o, Boolean(S.config.eqBypass))}"></polyline></svg></button>
    <button type="button" class="toggle onoff" data-act="onoff" data-i="${i}" ${pressed(!o.mute)} aria-label="${esc(name)} is ${o.mute ? 'off' : 'on'}">${o.mute ? 'Off' : 'On'}</button>
  </div>`;
}

function panel(S, tag, title, note, ids) {
  return `<section class="panel out-panel" aria-label="${esc(title)}">
    <div class="row-head"><span><span class="tag">${esc(tag)}</span> <strong>${esc(title)}</strong></span><span class="muted">${esc(note)}</span></div>
    <div class="out-rows"><div class="out-row out-head" aria-hidden="true"><span>Out</span><span>Name</span><span></span><span>Level</span><span>Delay</span><span>Ø</span><span>EQ</span><span></span></div>
    ${ids.map(i => row(S, i)).join('')}</div></section>`;
}

function alignPanel(S) {
  const a = S.align, rows = S.config.outputs.map((o, i) => ({o, i})).filter(({o, i}) => o.role !== 'unused' && !S.headphoneIds.includes(i));
  return `<div class="panel inline-panel" role="group" aria-label="Align by distance">
    <div class="row-head"><span><strong>Align by distance</strong> <span class="muted">Enter how far each speaker is from the listening position. The farthest gets no delay; nearer ones are delayed to match. Leave one blank to leave its delay alone.</span></span>
      ${segmented({act: 'align-unit', label: 'Unit', items: [['m', 'Metres'], ['ft', 'Feet']], value: a.unit})}</div>
    <div class="align-grid">${rows.map(({o, i}) => `<label class="align-cell"><strong>${esc(o.label)}</strong>
      <input type="text" inputmode="decimal" data-align="${i}" data-k="align:${i}" value="${esc(a.text[i] ?? '')}" placeholder="${a.unit}" aria-label="Distance to ${esc(o.label)} in ${a.unit === 'm' ? 'metres' : 'feet'}">
      <span class="muted" id="align-ms-${i}">${a.preview?.delays?.[i] === null || a.preview?.delays?.[i] === undefined ? '' : `${msText(a.preview.delays[i])} ms`}</span></label>`).join('')}</div>
    <div class="toolbar"><button type="button" class="primary" data-act="align-apply" ${disabledAttr(!a.preview || a.preview.farthest === null || Boolean(a.error))}>Set these delays</button>
      <button type="button" data-act="align-close">Close</button>
      <span class="${a.error ? 'warn-text' : 'muted'}" role="status" id="align-note">${esc(a.error || a.note || `A delay is at most ${MAX_DELAY_MS} ms, about 3.4 m (11 ft) of difference.`)}</span></div></div>`;
}

function eqAside(S) {
  const i = S.eqOpen, o = S.config.outputs[i], b = o.bands[S.band], bypassed = Boolean(S.config.eqBypass);
  const linkBus = S.config.buses.find(bus => bus.kind === 'headphones' && bus.outputIds.includes(i));
  const types = [['bell', 'Bell'], ['lowShelf', 'Low shelf'], ['highShelf', 'High shelf']];
  const stepper = (label, f, value, unit) => `<div class="stepper"><span>${label}</span>
    <button type="button" data-act="band-step" data-v="${f},-1" aria-label="${label} down">−</button>
    ${numField({f: `band.${f}`, i: S.band, value, label: `${label} of band ${S.band + 1}`, unit})}
    <button type="button" data-act="band-step" data-v="${f},1" aria-label="${label} up">+</button></div>`;
  const imp = S.eqImport;
  return `<aside class="panel eq-aside" aria-label="Equaliser" id="eq-aside">
    <div class="row-head"><div><span class="overline">EQ · output ${i + 1}</span><strong class="eq-name">${esc(o.label)}</strong></div>
      <div class="toolbar"><button type="button" data-act="eq-prev" aria-label="Previous output">‹</button><button type="button" data-act="eq-next" aria-label="Next output">›</button><button type="button" data-act="eq-close">Close</button></div></div>
    <div class="toolbar">
      <button type="button" data-act="eq-toggle" ${pressed(o.eqEnabled)}>${o.eqEnabled ? 'EQ on' : 'EQ off'}</button>
      <button type="button" data-act="eq-import" aria-expanded="${imp ? 'true' : 'false'}">Import EQ</button>
      <button type="button" data-act="eq-export">Export EQ</button>
      <button type="button" data-act="eq-copy">Copy</button>
      <button type="button" data-act="eq-paste" ${disabledAttr(!S.eqClipboard)}>Paste${S.eqClipboard ? ` from ${esc(S.eqClipboard.label)}` : ''}</button>
      ${linkBus ? `<button type="button" data-act="eq-link" data-v="${esc(linkBus.id)}" ${pressed(Boolean(linkBus.linkEq))}>${linkBus.linkEq ? 'Both ears together' : 'Each ear on its own'}</button>` : ''}
    </div>
    ${imp ? `<div class="inline-panel"><strong>Import EQ for ${esc(o.label)}</strong>
      <span class="muted">An EQ file exported from this page, or REW's filter text (in REW: Generic or CamillaDSP equaliser, then Export filter settings as text).</span>
      <label class="file-pick">Choose a file<input type="file" id="eq-import-file" accept=".txt,.json,text/plain,application/json"></label>
      <label class="stack">Or paste it here<textarea id="eq-import-text" rows="6" spellcheck="false" placeholder="Filter 1: ON PK Fc 80.0 Hz Gain -3.0 dB Q 2.0">${esc(imp.text)}</textarea></label>
      <span class="muted">Replaces all sixteen bands on this output. Level, delay and on or off stay as they are.</span>
      <span class="${imp.error ? 'warn-text' : 'muted'}" role="status" id="eq-import-note">${esc(imp.error || imp.note || '')}</span>
      <div class="toolbar"><button type="button" class="primary" data-act="eq-import-run" id="eq-import-run" ${disabledAttr(!imp.ready)}>Import</button><button type="button" data-act="eq-import">Cancel</button></div></div>` : ''}
    ${bypassed ? '<p class="banner note" role="status">All EQ is bypassed. Your bands are kept and return when bypass is switched off.</p>' : ''}
    ${!bypassed && !o.eqEnabled ? '<p class="banner note" role="status">The EQ on this output is off. Its bands are kept.</p>' : ''}
    <div class="eq-display dense" id="eq-display"><svg id="eq-chart" class="eq-chart" role="img" aria-label="EQ response of ${esc(o.label)}, 20 Hz to 20 kHz"></svg>
      <div class="eq-nodes">${o.bands.map((_, n) => `<button type="button" class="eq-node band-${n}" data-eq-node="${n}">${n + 1}</button>`).join('')}</div></div>
    <span class="muted">Drag a point: frequency and gain. Cmd or Ctrl + drag up or down: Q. Arrow keys: fine adjust, with Cmd or Ctrl for Q. Double-click: reset the band.</span>
    <div class="band-chips dense" role="group" aria-label="Bands">${o.bands.map((band, n) => `<button type="button" class="band-chip band-${n} ${band.enabled ? '' : 'band-off'}" data-act="band-pick" data-v="${n}" ${pressed(n === S.band)} aria-label="Band ${n + 1}${band.enabled ? '' : ', off'}">${n + 1}</button>`).join('')}</div>
    <div class="band-editor" id="band-editor">
      <div class="row-head"><strong>Band ${S.band + 1}</strong>
        <div class="toolbar"><button type="button" data-act="band-toggle" ${pressed(b.enabled)} aria-label="Band on">${b.enabled ? 'On' : 'Off'}</button>
        ${segmented({act: 'band-type', label: 'Filter type', items: types, value: b.type})}</div></div>
      ${stepper('Frequency', 'frequency', b.frequency >= 1000 ? b.frequency.toFixed(0) : b.frequency.toFixed(1), 'Hz')}
      ${stepper('Gain', 'gainDb', dbText(b.gainDb), 'dB')}
      ${stepper('Q', 'q', b.q.toFixed(2), '')}
      <div class="toolbar"><button type="button" data-act="band-reset">Reset band</button><button type="button" data-act="eq-reset">Reset EQ on ${esc(o.label)}</button></div>
    </div></aside>`;
}

export function outputsView(S) {
  const c = S.config;
  const panels = c.buses.filter(bus => bus.outputIds.length).map(bus => {
    const ids = [...bus.outputIds].sort((a, b) => bus.kind === 'headphones' ? 0 : a - b);
    const subs = ids.filter(i => c.outputs[i].role === 'sub').length;
    return panel(S, bus.kind === 'headphones' ? 'Headphones' : 'Speaker set', bus.label,
      bus.kind === 'headphones' ? 'Left and right' : `${ids.length - subs} speaker${ids.length - subs === 1 ? '' : 's'}${subs ? `, ${subs} subwoofer${subs === 1 ? '' : 's'}` : ''}`, ids);
  }).join('');
  const spare = c.outputs.map((o, i) => ({o, i})).filter(({o}) => o.busId === null);
  const sparePanel = spare.length ? `<section class="panel out-panel" aria-label="Outputs not in use">
    <div class="row-head"><span><span class="tag">Spare</span> <strong>Not in use</strong></span><span class="muted">Silent. Give one a job under Routing: click its name there.</span></div>
    <p class="spare-list">${spare.map(({o, i}) => `<span>${pad(i)} ${esc(o.label)}</span>`).join('')}</p></section>` : '';
  return `<div class="outputs-layout ${S.eqOpen === null ? '' : 'with-eq'}"><section class="outputs-main" aria-label="Outputs">
    <div class="row-head"><div><strong class="title">Outputs</strong> <span class="muted">Level, delay, polarity, EQ, and on or off. Saved in the preset.</span></div>
      <div class="toolbar">
        <button type="button" data-act="eq-bypass" ${pressed(Boolean(c.eqBypass))}>${c.eqBypass ? 'All EQ bypassed' : 'Bypass all EQ'}</button>
        <button type="button" data-act="eq-reset-all">Reset all EQ</button>
        <button type="button" data-act="eq-export">Export EQ</button>
        <button type="button" data-act="align-open" aria-expanded="${S.align.open ? 'true' : 'false'}">Align by distance</button></div></div>
    ${S.confirmResetAll ? `<div class="banner warn" role="alertdialog" aria-label="Reset all EQ"><span>Reset the EQ on all 16 outputs? Bands that are off stay off. Undo brings it back.</span>
      <button type="button" class="primary" data-act="eq-reset-all-go">Reset all</button><button type="button" data-act="eq-reset-all-cancel">Cancel</button></div>` : ''}
    ${S.align.open ? alignPanel(S) : ''}
    ${panels}${sparePanel}</section>
    ${S.eqOpen === null ? '' : eqAside(S)}</div>`;
}
