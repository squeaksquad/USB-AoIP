// Processor > Speakers & headphones: the speaker set and the headphones this
// preset has, which outputs they use, and what the headphones are fed from.
import { esc, pad, pressed, options, disabledAttr, segmented, dbText } from './ui.mjs';

function headphoneDetail(S, bus) {
  const c = S.config, inputs = c.inputs.map((v, i) => [i, `${pad(i)} · ${v.label}`]);
  const outs = c.outputs.map((o, i) => { const owner = c.buses.find(b => b.outputIds.includes(i)); return [i, `${pad(i)} · ${o.label}${!owner ? ' (spare)' : owner.id === bus.id ? '' : ' (trades places)'}`]; });
  const pair = bus.inputMode === 'pair';
  return `<div class="set-detail">
    <div class="field-row"><label class="stack">Left ear on output<select data-f="set.out" data-i="${esc(bus.id)},0">${options(outs, bus.outputIds[0])}</select></label>
      <label class="stack">Right ear on output<select data-f="set.out" data-i="${esc(bus.id)},1">${options(outs, bus.outputIds[1])}</select></label>
      <button type="button" class="toggle" data-act="set-link" data-v="${esc(bus.id)}" ${pressed(Boolean(bus.linkEq))}>${bus.linkEq ? 'EQ: both ears together' : 'EQ: each ear on its own'}</button></div>
    <div class="field-row"><span>Fed from</span>${segmented({act: `set-mode:${bus.id}`, label: 'What the headphones are fed from', items: [['pair', 'Two channels'], ['downmix', 'A mix of channels']], value: bus.inputMode})}
      ${pair ? `<label class="stack">Left<select data-f="set.pair" data-i="${esc(bus.id)},0">${options(inputs, bus.inputPair?.[0] ?? 0)}</select></label>
        <label class="stack">Right<select data-f="set.pair" data-i="${esc(bus.id)},1">${options(inputs, bus.inputPair?.[1] ?? 1)}</select></label>` : ''}</div>
    <span class="muted">${pair ? 'Each ear takes one computer channel, before any bass management.' : 'Each computer channel can go to the left ear, the right ear, or both, before any bass management. Type a level in dB, or off.'}</span>
    ${pair ? '' : `<div class="mix-grid dense">${c.inputs.map((v, i) => `<div class="mix-row"><strong>${pad(i)} ${esc(v.label)}</strong>${[0, 1].map(ear => `<span class="ear" aria-hidden="true">${ear ? 'R' : 'L'}</span><input type="text" inputmode="decimal" data-f="mix" data-i="${esc(bus.id)},${i},${ear}" data-k="mix:${esc(bus.id)},${i},${ear}" value="${dbText(bus.downmixMatrix?.[i]?.[ear] ?? null)}" aria-label="${esc(v.label)} to the ${ear ? 'right' : 'left'} ear, in dB, or off">`).join('')}</div>`).join('')}</div>`}
  </div>`;
}

export function setsView(S) {
  const c = S.config, free = c.outputs.filter(o => o.busId === null).length;
  const mainId = c.buses.find(b => b.kind === 'speakers')?.id;
  const rows = c.buses.map(bus => {
    const phones = bus.kind === 'headphones', ids = bus.outputIds;
    const subs = ids.filter(i => c.outputs[i].role === 'sub').length, speakers = ids.length - subs;
    const level = bus.gainDb !== 0 || bus.mute;
    return `<div class="set-row" data-set="${esc(bus.id)}">
      <input type="text" data-f="set.label" data-i="${esc(bus.id)}" data-k="set.label:${esc(bus.id)}" value="${esc(bus.label)}" maxlength="24" aria-label="Name of ${esc(bus.label)}" title="Rename">
      <div><span>${phones ? 'Headphones' : 'Speaker set'}</span><span class="muted">${ids.length ? `Outputs ${ids.map(i => pad(i)).join(', ')}` : 'No outputs'}</span></div>
      <span>${phones ? 'Stereo' : `${speakers} speaker${speakers === 1 ? '' : 's'}`}</span>
      <span>${phones ? '—' : `${subs} subwoofer${subs === 1 ? '' : 's'}`}</span>
      <div class="toolbar">
        ${phones ? `<button type="button" data-act="set-detail" data-v="${esc(bus.id)}" aria-expanded="${S.setDetail === bus.id ? 'true' : 'false'}">${S.setDetail === bus.id ? 'Hide settings' : 'Settings'}</button>` : ''}
        ${bus.id === mainId ? '<button type="button" data-act="layout-open">Change layout</button>' : ''}
        ${bus.id === mainId ? '' : `<button type="button" data-act="set-remove" data-v="${esc(bus.id)}" aria-label="Remove ${esc(bus.label)}">Remove</button>`}
      </div></div>
      ${level ? `<p class="banner note set-note">${esc(bus.label)} carries a saved level${bus.mute ? ' and is switched off' : ` of ${dbText(bus.gainDb)} dB`} from an earlier version of this page, on top of each output's own level. <button type="button" data-act="set-clear-level" data-v="${esc(bus.id)}">Clear it</button></p>` : ''}
      ${phones && S.setDetail === bus.id ? headphoneDetail(S, bus) : ''}`;
  }).join('');
  return `<section class="panel" aria-label="Speakers and headphones">
    <div class="row-head"><div><strong class="title">Speakers and headphones</strong> <span class="muted">${c.outputs.length - free} of 16 outputs in use, ${free} spare.</span></div>
      <div class="toolbar"><button type="button" data-act="set-add-phones" ${disabledAttr(free < 2)} title="${free < 2 ? 'Needs two spare outputs' : 'Uses the last two spare outputs'}">Add headphones</button></div></div>
    <div class="set-table"><div class="set-row set-head" aria-hidden="true"><span>Name</span><span>Kind and outputs</span><span>Speakers</span><span>Subwoofers</span><span></span></div>${rows}</div>
    <p class="muted">Each output belongs to one of these or is spare. An output's own job (speaker, subwoofer, not in use) and its channel are set under Routing.</p></section>`;
}
