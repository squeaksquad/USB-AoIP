// Status: five cards and three rows of sixteen meters. The bars are drawn
// here once, empty; the page fills them from the engine's taps ten times a
// second (app.mjs, drawMeters). Nothing on this tab changes the device.
import { esc, pad } from './ui.mjs';

export const SCALE_MARKS = [0, -6, -12, -24, -36, -48, -60];

/** S.cards: statusCards(health). S.rows: meterRows(...) with their titles. S.meterNote: why there are no levels, or ''. */
export function statusView(S) {
  const cards = S.cards.map(c => `<div class="card state-${c.state || 'plain'}" data-card="${esc(c.id)}">
    <span class="overline">${esc(c.label)}</span><strong class="card-value">${esc(c.value)}</strong>
    <span class="muted">${esc(c.detail)}</span>${c.stateText ? `<span class="card-state">${esc(c.stateText)}</span>` : ''}</div>`).join('');
  const scale = `<div class="meter-scale" aria-hidden="true">${SCALE_MARKS.map(m => `<span data-mark="${m}">${m}</span>`).join('')}</div>`;
  const rows = S.rows.map(row => `<div class="panel meter-row" data-meter-row="${esc(row.id)}">
    <div class="row-head"><strong>${esc(row.title)}</strong><span class="muted">${esc(row.note)}</span></div>
    <div class="meter-bank" id="sm-${esc(row.id)}-bars" hidden>${scale}<div class="bars">${Array.from({length: 16}, (_, i) => `<div class="bar-cell">
      <span class="clip-light" id="sm-${esc(row.id)}-c${i}"></span>
      <span class="bar" id="sm-${esc(row.id)}-${i}"><i></i><b></b></span>
      <span class="bar-num">${pad(i)}</span></div>`).join('')}</div></div>
    <p class="muted meter-none" id="sm-${esc(row.id)}-none">${esc(S.meterNote || 'No level data.')}</p></div>`).join('');
  return `<section class="cards" aria-label="Device state">${cards}</section>
    <section class="meter-rows" aria-label="Meters">
      <div class="row-head"><span class="muted" id="meter-caption">${esc(S.meterCaption)}</span>
        <button type="button" class="quiet" data-act="clear-clips" id="clear-clips" hidden>Clear clip lights</button></div>
      ${rows}</section>`;
}
