// Processor > Speakers & headphones: the speaker sets and the headphones this
// preset has, which outputs they use, what an added speaker set does for a
// subwoofer, and what the headphones are fed from.
import { esc, pad, pressed, options, disabledAttr, segmented, dbText } from './ui.mjs';

/** The words for a subwoofer choice; `subs` is how many the main speakers have. */
export function subShareText(share, subs = 1) {
  return share === 'main' ? (subs === 1 ? 'Shares the main sub' : 'Shares the main subs')
    : share === 'none' ? 'None, full range' : 'Own sub';
}

/** S.addSet: {label, layoutId, subShare, outputIds, error}; S.addSetLayouts: [{id, label, size, fits, choices}]. */
function addSetForm(S) {
  const a = S.addSet, c = S.config, layout = S.addSetLayouts.find(l => l.id === a.layoutId);
  const spare = c.outputs.map((o, i) => ({o, i})).filter(({o}) => o.busId === null);
  const size = layout?.size ?? 0, chosen = a.outputIds.length;
  const picks = S.addSetLayouts.map(l => `<button type="button" class="layout-pick" data-act="addset-layout" data-v="${esc(l.id)}" ${pressed(a.layoutId === l.id)} ${disabledAttr(!l.fits)} title="${l.fits ? `${l.size} outputs` : `Needs ${l.size} outputs; not enough are spare`}"><strong>${esc(l.label)}</strong><span class="muted">${l.size} output${l.size === 1 ? '' : 's'}</span></button>`).join('');
  const subs = layout ? segmented({act: 'addset-sub', label: 'Subwoofer for the new speaker set', items: layout.choices.map(share => [share, share === 'own' ? `Own sub${layout.subs > 1 ? `s · ${layout.subs}` : ''}` : subShareText(share, S.mainSubs)]), value: a.subShare}) : '';
  const outs = spare.map(({o, i}) => `<button type="button" class="toggle" data-act="addset-out" data-v="${i}" ${pressed(a.outputIds.includes(i))} aria-label="Output ${i + 1}${a.outputIds.includes(i) ? ', chosen' : ''}">${pad(i)}</button>`).join('');
  return `<div class="set-detail" aria-label="Add a speaker set">
    <div class="field-row"><label class="stack">Name<input type="text" data-k="addset-label" id="addset-label" value="${esc(a.label)}" maxlength="24" aria-label="Name of the new speaker set"></label></div>
    <div class="field-row"><span>Layout</span></div>
    <div class="layout-picks" role="group" aria-label="Layout of the new speaker set">${picks}</div>
    ${layout ? `<div class="field-row"><span>Subwoofer</span>${subs}</div>
    <span class="muted">${a.subShare === 'main' ? 'Its bass plays through the main subwoofer, with the sends its channels already have to it. Only the speaker set that is playing feeds it.' : a.subShare === 'none' ? 'No bass management: its speakers play full range.' : 'Its subwoofer outputs are its own; their sends are on the Bass management tab.'}</span>
    <div class="field-row"><span>Outputs</span><span class="muted">Choose ${size} of the spare outputs: ${chosen} chosen. They take the layout's channels in output order.</span></div>
    <div class="toolbar" role="group" aria-label="Spare outputs for the new speaker set">${outs}</div>` : ''}
    <span class="warn-text" role="alert">${esc(a.error || '')}</span>
    <div class="toolbar"><button type="button" class="primary" data-act="addset-go" ${disabledAttr(!layout || chosen !== size)}>Add speaker set</button><button type="button" data-act="addset-close">Cancel</button></div>
    <span class="muted">A speaker set added here shares the main subwoofer unless you choose otherwise, and each speaker starts on the matching computer channel (Routing tab). One speaker set plays at a time, or all of them together.</span>
  </div>`;
}

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
  const mainSubs = S.mainSubs ?? 0;
  const rows = c.buses.map(bus => {
    const phones = bus.kind === 'headphones', ids = bus.outputIds, extra = !phones && bus.id !== mainId;
    const subs = ids.filter(i => c.outputs[i].role === 'sub').length, speakers = ids.length - subs;
    const subCell = phones ? '—'
      : !extra ? `${subs} subwoofer${subs === 1 ? '' : 's'}`
      : bus.subShare === 'own' ? `${subShareText('own')}${subs > 1 ? `s · ${subs}` : ''}`
      : `<select data-f="set.subShare" data-i="${esc(bus.id)}" aria-label="Subwoofer for ${esc(bus.label)}">${options([...(mainSubs ? [['main', subShareText('main', mainSubs)]] : []), ['none', subShareText('none')]], bus.subShare)}</select>`;
    return `<div class="set-row" data-set="${esc(bus.id)}">
      <input type="text" data-f="set.label" data-i="${esc(bus.id)}" data-k="set.label:${esc(bus.id)}" value="${esc(bus.label)}" maxlength="24" aria-label="Name of ${esc(bus.label)}" title="Rename">
      <div><span>${phones ? 'Headphones' : extra ? 'Speaker set' : 'Main speakers'}</span><span class="muted">${ids.length ? `Outputs ${ids.map(i => pad(i)).join(', ')}` : 'No outputs'}</span></div>
      <span>${phones ? 'Stereo' : `${speakers} speaker${speakers === 1 ? '' : 's'}`}</span>
      <span>${subCell}</span>
      <div class="toolbar">
        ${phones ? `<button type="button" data-act="set-detail" data-v="${esc(bus.id)}" aria-expanded="${S.setDetail === bus.id ? 'true' : 'false'}">${S.setDetail === bus.id ? 'Hide settings' : 'Settings'}</button>` : ''}
        ${bus.id === mainId ? '<button type="button" data-act="layout-open">Change layout</button>' : ''}
        ${bus.id === mainId ? '' : `<button type="button" data-act="set-remove" data-v="${esc(bus.id)}" aria-label="Remove ${esc(bus.label)}">Remove</button>`}
      </div></div>
      ${phones && S.setDetail === bus.id ? headphoneDetail(S, bus) : ''}`;
  }).join('');
  const sets = c.buses.filter(b => b.kind === 'speakers').length;
  const canAdd = S.setsSwitchable !== false;
  return `<section class="panel" aria-label="Speakers and headphones">
    <div class="row-head"><div><strong class="title">Speaker sets and headphones</strong> <span class="muted">${c.outputs.length - free} of 16 outputs in use, ${free} spare. Names change as you type; adding or removing a speaker set or headphones needs a restart.</span></div>
      <div class="toolbar">${canAdd ? `<button type="button" data-act="addset-open" ${disabledAttr(free < 2 || Boolean(S.addSet))} title="${free < 2 ? 'Needs two spare outputs' : 'Another set of speakers, played instead of the main ones or with them'}">Add speaker set</button>` : ''}
        <button type="button" data-act="set-add-phones" ${disabledAttr(free < 2)} title="${free < 2 ? 'Needs two spare outputs' : 'Uses the last two spare outputs'}">Add headphones</button></div></div>
    ${S.addSet ? addSetForm(S) : ''}
    ${!canAdd && sets > 1 ? '<p class="banner note set-note">This device\'s engine cannot switch between speaker sets: with this preset every speaker set plays at once.</p>' : ''}
    <div class="set-table"><div class="set-row set-head" aria-hidden="true"><span>Name</span><span>Kind and outputs</span><span>Speakers</span><span>Subwoofers</span><span></span></div>${rows}</div>
    <p class="muted">Each output belongs to one of these or is spare. An output's own job (speaker, subwoofer, not in use) and its channel are set under Routing; giving an added speaker set's output the job Subwoofer gives that set its own sub.</p></section>`;
}
