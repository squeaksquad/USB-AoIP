// Processor > Bass management: redirection on or off, the crossovers, LFE,
// and what each source sends to each subwoofer. The preset model keeps a
// crossover per computer channel (the source of a speaker), so the table has
// one row per source that feeds the speaker set.
import { subSumBoundDb } from './model.mjs';
import { speakerGroupSourceIds } from './buses.mjs';
import { esc, pad, pressed, numField, segmented, options, dbText } from './ui.mjs';

export function bassView(S) {
  const c = S.config, on = c.bassEnabled;
  const subs = c.outputs.map((o, i) => ({o, i})).filter(({o}) => o.role === 'sub');
  const sources = speakerGroupSourceIds(c), mains = sources.filter(i => i !== c.lfe.input);
  const slopes = [[12, '12 dB/oct'], [24, '24 dB/oct'], [48, '48 dB/oct']];
  const common = values => values.length && values.every(v => v === values[0]) ? values[0] : null;
  const xover = common(mains.flatMap(i => [c.inputs[i].highpassHz, c.inputs[i].lowpassHz]));
  const slope = common(mains.map(i => c.inputs[i].slope));
  const stepper = (label, f, value, unit) => `<div class="stepper"><span>${label}</span>
    <button type="button" data-act="bass-step" data-v="${f},-1" aria-label="${label} down">−</button>
    ${numField({f, value, label, unit, unitSpace: true})}
    <button type="button" data-act="bass-step" data-v="${f},1" aria-label="${label} up">+</button></div>`;
  if (!subs.length) {
    return `<section class="panel" aria-label="Bass management"><strong class="title">Bass management</strong>
      <p class="muted">This preset has no subwoofer, so there is nowhere to send bass. Choose a layout with a subwoofer under Speakers &amp; headphones, or set an output's job to Subwoofer under Routing.</p></section>`;
  }
  const rows = sources.map(i => {
    const v = c.inputs[i], lfe = i === c.lfe.input;
    return `<div class="bass-row ${lfe ? 'is-lfe' : ''}" role="row"><strong role="rowheader">${pad(i)} ${esc(v.label)}${lfe ? ' <span class="tag">LFE</span>' : ''}</strong>
      ${lfe ? `<span class="muted span-2">Low-pass ${c.lfe.lowpassHz} Hz, ${c.lfe.slope} dB/oct</span>` : `
      <span class="hp-cell"><button type="button" class="toggle" data-act="bass-hp" data-v="${i}" ${pressed(v.crossover)} ${on ? '' : 'disabled'} aria-label="High-pass on ${esc(v.label)}">${v.crossover ? 'On' : 'Off'}</button>
        ${numField({f: 'in.highpassHz', i, value: v.highpassHz, label: `High-pass of ${v.label}, in Hz`, unit: 'Hz', off: !on || !v.crossover})}</span>
      ${numField({f: 'in.lowpassHz', i, value: v.lowpassHz, label: `Bass low-pass of ${v.label}, in Hz`, unit: 'Hz', off: !on})}`}
      ${subs.map(({o, i: j}) => `<input type="text" inputmode="decimal" class="send" data-f="send" data-i="${i},${j}" data-k="send:${i},${j}" value="${dbText(c.sends[i][j])}" ${!lfe && !on ? 'disabled' : ''} aria-label="${esc(v.label)} to ${esc(o.label)}, in dB, or off">`).join('')}</div>`;
  }).join('');
  const note = S.polarity;
  return `<section class="panel" aria-label="Bass management">
    <div class="row-head"><div><strong class="title">Bass management</strong> <span class="muted">${on ? 'Each speaker\'s low frequencies go to the subwoofers.' : 'Off: speakers play full range and send no bass. LFE is still routed.'}</span></div>
      <button type="button" class="toggle" data-act="bass-toggle" ${pressed(on)}>${on ? 'On' : 'Off'}</button></div>
    <div class="bass-fields">
      ${stepper('Crossover, all speakers', 'bass.xover', xover ?? '', 'Hz')}
      ${stepper('LFE low-pass', 'lfe.lowpassHz', c.lfe.lowpassHz, 'Hz')}
      ${stepper('LFE level', 'lfe.trimDb', dbText(c.lfe.trimDb), 'dB')}
      ${stepper('Level into the processing', 'headroom', dbText(c.headroomDb), 'dB')}
    </div>
    <div class="field-row"><span>Crossover slope</span>${segmented({act: 'bass-slope', label: 'Crossover slope', items: slopes, value: slope ?? ''})}
      <span>LFE slope</span>${segmented({act: 'lfe-slope', label: 'LFE slope', items: slopes, value: c.lfe.slope})}
      <label class="inline">LFE is computer channel <select data-f="lfe.input" aria-label="Which computer channel is LFE">${options(c.inputs.map((v, i) => [i, `${pad(i)} · ${v.label}`]), c.lfe.input)}</select></label></div>
    ${xover === null && mains.length ? '<p class="muted">The speakers have different crossovers. Typing one here sets them all.</p>' : ''}
    ${note ? `<p class="banner note" role="note"><strong>${esc(note.headline)}.</strong> ${esc(note.detail)} <span class="muted">Advice only: no polarity has been changed.</span></p>` : ''}
    <div class="row-head"><div><strong>Speakers and sub feeds</strong> <span class="muted">One row per computer channel that feeds a speaker. With the high-pass off a speaker plays full range and still sends its bass. Type a level into a send, or off.</span></div></div>
    <div class="table-scroll"><div class="bass-table cols-${subs.length}" role="table" aria-label="Speakers and sub feeds">
      <div class="bass-row bass-head" role="row"><span role="columnheader">Source</span><span role="columnheader">High-pass</span><span role="columnheader">Bass low-pass</span>
        ${subs.map(({o, i}) => { const bound = subSumBoundDb(c, i); return `<span role="columnheader">${pad(i)} ${esc(o.label)}<small class="muted" title="If every source that feeds it were at full scale at once, before filters and EQ. Not a measured level.">worst case ${Number.isFinite(bound) ? `${bound.toFixed(1)} dBFS` : 'silent'}</small></span>`; }).join('')}</div>
      ${rows}</div></div>
    <p class="muted">Changing which channel is LFE clears the sends of the old and the new one, so they are set again on purpose.</p></section>`;
}
