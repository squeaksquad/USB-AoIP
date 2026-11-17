// New preset, and Change speaker layout. Both pick from the layouts the
// compiler knows (workflows.mjs LAYOUTS): the outputs are named and ordered
// for the layout, bass sends are made for its subwoofers.
import { esc, pressed, disabledAttr } from './ui.mjs';

/** S.chooser: {mode: 'new' | 'layout', layoutId, name, error}. S.layouts: [{id, label, outputs, fits}]. */
export function chooserView(S) {
  const ch = S.chooser, fresh = ch.mode === 'new';
  const picks = S.layouts.map(l => `<button type="button" class="layout-pick" data-act="chooser-layout" data-v="${esc(l.id)}" ${pressed(ch.layoutId === l.id)} ${disabledAttr(!l.fits)} title="${l.fits ? `${l.outputs} outputs` : `Needs ${l.outputs} outputs; not enough are spare`}"><strong>${esc(l.label)}</strong><span class="muted">${l.outputs} outputs</span></button>`).join('');
  return `<section class="panel chooser" aria-label="${fresh ? 'Start a new preset' : 'Change speaker layout'}">
    <div class="row-head"><div><strong class="title">${fresh ? 'New preset' : 'Change speaker layout'}</strong>
      <span class="muted">${fresh ? 'Starts a new draft. Nothing changes on the device until you apply it.' : 'Keeps this preset, its name and its headphones. The speaker set\'s outputs are named and ordered for the new layout, and their level, delay, EQ and bass sends start again. Undo brings the old layout back.'}</span></div>
      <button type="button" data-act="chooser-close">Cancel</button></div>
    ${fresh && S.changes ? `<p class="banner warn" role="status">The preset you are editing has ${S.changes} unsaved change${S.changes === 1 ? '' : 's'}. Starting a new one leaves them behind.</p>` : ''}
    ${fresh ? `<label class="stack">Name<input type="text" id="chooser-name" data-k="chooser-name" value="${esc(ch.name)}" maxlength="64" aria-label="Name of the new preset"></label>
      <div class="chooser-card"><strong>Blank</strong><span class="muted">Sixteen outputs passed straight through, named Out 1 to Out 16. Add the processing yourself.</span>
        <button type="button" data-act="chooser-blank">Start blank</button></div>` : ''}
    <div class="chooser-card"><strong>Speaker layout</strong><span class="muted">Say what is in the room. The outputs are named and ordered for you; the number after the first dot is subwoofers, after the second, height speakers.</span>
      <div class="layout-picks" role="group" aria-label="Speaker layout">${picks}</div>
      <span class="warn-text" role="alert">${esc(ch.error || '')}</span>
      <button type="button" class="primary" data-act="chooser-go" ${disabledAttr(!ch.layoutId)}>${fresh ? 'Create preset' : 'Change layout'}</button></div></section>`;
}
