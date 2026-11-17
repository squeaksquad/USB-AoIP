// Processor > Routing: which computer channel feeds which output. Columns are
// the sixteen channels from the computer, rows the device's sixteen outputs.
// Three kinds of crosspoint, as the preset model has them: a speaker's feed
// (one per speaker), bass sent to a subwoofer (a level), and a headphone mix.
import { esc, pad, pressed, numField, options, dbText } from './ui.mjs';

/** What sits at (output row, computer column): {kind, on, text, level}. */
export function crosspoint(config, row, col) {
  const o = config.outputs[row], bus = config.buses.find(b => b.outputIds.includes(row));
  if (!bus || o.role === 'unused') return {kind: 'none', on: false, text: ''};
  if (bus.kind === 'headphones') {
    const ear = bus.outputIds.indexOf(row);
    if (bus.inputMode === 'downmix') {
      const level = bus.downmixMatrix?.[col]?.[ear] ?? null;
      return {kind: 'mix', on: level !== null, level, ear, busId: bus.id, text: level === null ? '' : dbText(level)};
    }
    return {kind: 'pair', on: bus.inputPair?.[ear] === col, ear, busId: bus.id, text: bus.inputPair?.[ear] === col ? '●' : ''};
  }
  if (o.role === 'sub') {
    const level = config.sends[col][row];
    return {kind: 'bass', on: level !== null, level, text: level === null ? '' : dbText(level)};
  }
  return {kind: 'feed', on: o.source === col, text: o.source === col ? '●' : ''};
}

function detail(S) {
  const c = S.config, {row, col} = S.route;
  if (row === null && col === null) return '<span class="muted">Click a crosspoint to change it, an output\'s name to move it or change its job, or a computer channel to name it.</span>';
  if (row === null) {
    return `<strong>Computer channel ${col + 1}</strong><label class="inline">Name <input type="text" data-f="in.label" data-i="${col}" data-k="in.label:${col}" value="${esc(c.inputs[col].label)}" maxlength="64" aria-label="Name of computer channel ${col + 1}"></label>
      <span class="muted">Names belong to this preset. The computer still sees channels 1 to 16.</span>`;
  }
  const o = c.outputs[row], bus = c.buses.find(b => b.outputIds.includes(row));
  if (col === null) {
    const roles = [['speaker', 'Speaker'], ['sub', 'Subwoofer'], ['unused', 'Not in use']];
    return `<strong>Output ${row + 1} · ${esc(o.label)}</strong>
      <label class="inline">Move to channel <select data-f="route.move" data-i="${row}" aria-label="Move this output to channel">${options(c.outputs.map((v, i) => [i, `${pad(i)} · ${i === row ? 'here' : v.label}`]), row)}</select></label>
      ${bus?.kind === 'headphones' ? '<span class="muted">Part of the headphones.</span>' : `<label class="inline">Use as <select data-f="route.role" data-i="${row}" aria-label="What this output is used as">${options(roles, o.role)}</select></label>`}
      <span class="muted">Moving trades places with the output on that channel; level, delay and EQ go with each.</span>`;
  }
  const x = crosspoint(c, row, col), name = `${c.inputs[col].label} to ${o.label}`;
  if (x.kind === 'none') return `<strong>${esc(o.label)}</strong><span class="muted">This output is not in use. Click its name to give it a job.</span>`;
  if (x.kind === 'feed') return `<strong>${esc(name)}</strong>${x.on ? '<span class="muted">This is the speaker\'s feed. A speaker has one.</span>'
    : `<button type="button" class="primary" data-act="route-feed" data-v="${row},${col}">Feed ${esc(o.label)} from ${esc(c.inputs[col].label)}</button>`}`;
  if (x.kind === 'pair') return `<strong>${esc(name)}</strong>${x.on ? '<span class="muted">This ear is fed from this channel.</span>'
    : `<button type="button" class="primary" data-act="route-pair" data-v="${esc(x.busId)},${x.ear},${col}">Feed this ear from ${esc(c.inputs[col].label)}</button>`}`;
  const f = x.kind === 'bass' ? 'send' : 'mix', i = x.kind === 'bass' ? `${col},${row}` : `${x.busId},${col},${x.ear}`;
  const blocked = x.kind === 'bass' && col !== c.lfe.input && !c.bassEnabled;
  return `<strong>${esc(name)}</strong>
    <button type="button" class="toggle" data-act="route-toggle" data-v="${f};${esc(i)}" ${pressed(x.on)}>${x.on ? 'On' : 'Off'}</button>
    ${numField({f, i, value: dbText(x.level), label: `Send level of ${name}, in dB, or off`, unit: 'dB'})}
    <span class="muted">${blocked ? 'Bass management is off, so this send is silent until it is switched on.' : 'Type a level, or off.'}</span>`;
}

export function routingView(S) {
  const c = S.config, {row: selRow, col: selCol} = S.route;
  const head = `<tr><th scope="col" class="corner">Output ↓ · Computer →</th>${c.inputs.map((v, i) => `<th scope="col"><button type="button" class="col-head" data-act="route-col" data-v="${i}" ${pressed(selRow === null && selCol === i)} aria-label="Computer channel ${i + 1}, ${esc(v.label)}"><span>${i + 1}</span><strong>${esc(v.label)}</strong></button></th>`).join('')}</tr>`;
  const body = c.outputs.map((o, row) => `<tr class="${o.role === 'unused' ? 'row-spare' : ''}"><th scope="row"><button type="button" class="row-head-btn" data-act="route-row" data-v="${row}" ${pressed(selRow === row && selCol === null)} aria-label="Output ${row + 1}, ${esc(o.label)}">${pad(row)} ${esc(o.label)}</button></th>${c.inputs.map((v, col) => {
    const x = crosspoint(c, row, col);
    return `<td><button type="button" class="x x-${x.kind} ${x.on ? 'on' : ''}" data-act="route-cell" data-v="${row},${col}" ${pressed(selRow === row && selCol === col)} aria-label="${esc(v.label)} to ${esc(o.label)}${x.on ? `, ${x.kind === 'feed' || x.kind === 'pair' ? 'connected' : `${x.text} dB`}` : ', off'}">${esc(x.text)}</button></td>`;
  }).join('')}</tr>`).join('');
  return `<section class="panel" aria-label="Routing">
    <div class="row-head"><div><strong class="title">Routing</strong> <span class="muted">Columns are the channels from the computer, rows are the device's outputs.
      <span class="key x-feed">Speaker feed</span> <span class="key x-bass">bass to a subwoofer</span> <span class="key x-mix">headphone mix</span>. A number is that send's level in dB.</span></div></div>
    <div class="route-detail" id="route-detail">${detail(S)}</div>
    <div class="table-scroll dense"><table class="route-grid"><thead>${head}</thead><tbody>${body}</tbody></table></div>
    <p class="muted">Where the outputs go on the network, and what the computer receives from it, is set in ${S.dante ? 'Dante Controller' : 'the network\'s own controller'}: what comes from the network reaches the computer unchanged.</p></section>`;
}
