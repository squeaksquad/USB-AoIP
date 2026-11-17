// Small helpers the views share. Views are pure: state in, HTML text out.
// Nothing here touches the document, so the views run under node's test runner.

export const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
export const pad = i => String(i + 1).padStart(2, '0');
export const pressed = on => `aria-pressed="${on ? 'true' : 'false'}"`;
export const disabledAttr = off => off ? 'disabled' : '';
export const options = (items, value) => items.map(([v, label]) => `<option value="${esc(v)}"${String(v) === String(value) ? ' selected' : ''}>${esc(label)}</option>`).join('');

/** A level as it is shown and typed: one decimal, or "off" for no send. */
export const dbText = value => value === null || value === undefined ? 'off' : (Math.round(value * 10) / 10).toFixed(1);
export const msText = value => (Math.round(value * 100) / 100).toFixed(2);

/**
 * A number as a person types it: a comma or a point, a typographic minus,
 * an optional unit after it. NaN when it is not a number.
 */
export function parseNumber(text) {
  const cleaned = String(text ?? '').trim().replace(/[−–]/g, '-').replace(',', '.').replace(/\s*(db|ms|hz|khz)$/i, '');
  return /^[+-]?(\d+(\.\d*)?|\.\d+)$/.test(cleaned) ? Number(cleaned) : NaN;
}

/** A send's level as typed: "off" (or blank) is no send, otherwise a number. */
export function parseSend(text) {
  const trimmed = String(text ?? '').trim().toLowerCase();
  if (!trimmed || trimmed === 'off' || trimmed === '-' || trimmed === '—') return null;
  return parseNumber(trimmed);
}

/** A text field holding one number of the draft. `f` names the field, `i` its index or id. */
/** `unitSpace` keeps the unit's place when there is no unit, so a column of fields lines up. */
export function numField({f, i = '', value, label, unit = '', off = false, cls = '', unitSpace = false}) {
  return `<label class="unit-field ${cls}"><input type="text" inputmode="decimal" data-f="${esc(f)}" data-i="${esc(i)}" data-k="${esc(f)}:${esc(i)}" value="${esc(value)}" aria-label="${esc(label)}" ${disabledAttr(off)}>${unit || unitSpace ? `<span aria-hidden="true">${esc(unit)}</span>` : ''}</label>`;
}

/** A group of buttons of which one is on. */
export function segmented({act, label, items, value, off = false}) {
  return `<div class="segmented" role="group" aria-label="${esc(label)}">${items.map(([v, text]) => `<button type="button" data-act="${esc(act)}" data-v="${esc(v)}" ${pressed(String(v) === String(value))} ${disabledAttr(off)}>${esc(text)}</button>`).join('')}</div>`;
}
