// The change bar: what is pending in the draft, and whether the device plays
// it already or needs a restart to take it. The split is not decided here: it
// is liveState's answer (backend.mjs), which compares the draft's compiled
// shape with the running preset's. This module counts and words it.

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/**
 * How many things differ between two drafts, counted the way a person would:
 * one per output field, one per EQ band, one per send, one per speaker set or
 * headphones touched. Zero means the drafts are the same preset.
 */
export function countChanges(base, draft) {
  if (!base || !draft) return base === draft ? 0 : 1;
  let n = 0;
  for (const key of ['name', 'headroomDb', 'bassEnabled', 'eqBypass', 'mode', 'source', 'sampleRate']) {
    if (!same(base[key] ?? null, draft[key] ?? null)) n += 1;
  }
  const fields = (a, b) => {
    const keys = new Set([...Object.keys(a || {}), ...Object.keys(b || {})]);
    for (const key of keys) if (key !== 'bands' && !same(a?.[key], b?.[key])) n += 1;
  };
  fields(base.lfe, draft.lfe);
  const rows = (a = [], b = [], each) => { for (let i = 0; i < Math.max(a.length, b.length); i += 1) each(a[i], b[i]); };
  rows(base.inputs, draft.inputs, fields);
  rows(base.outputs, draft.outputs, (a, b) => {
    fields(a, b);
    rows(a?.bands, b?.bands, (x, y) => { if (!same(x, y)) n += 1; });
  });
  rows(base.sends, draft.sends, (a, b) => rows(a, b, (x, y) => { if (!same(x ?? null, y ?? null)) n += 1; }));
  const ids = new Set([...(base.buses || []), ...(draft.buses || [])].map(bus => bus.id));
  for (const id of ids) {
    if (!same((base.buses || []).find(bus => bus.id === id), (draft.buses || []).find(bus => bus.id === id))) n += 1;
  }
  return n;
}

const plural = n => `${n} change${n === 1 ? '' : 's'}`;

/**
 * What the bar says and offers.
 *   connected  a device answers
 *   applyAvailable  the device can install and run a preset
 *   live       liveState(health, draftShapeKey), or null when not connected
 *   changes    countChanges(baseline, draft)
 *   fresh      a new preset that was never saved or applied
 *   outage     the stack's words for what a restart costs
 *   running    what the device runs, for the "not running" line
 * Returns {kind, text, detail, buttons}; kind 'none' means nothing to show.
 * Buttons are ids the page maps to actions: discard, keep, save-as, apply, save.
 */
export function changeBar({connected, applyAvailable = true, live, changes, fresh = false, outage = 'audio stops for a few seconds', running = null}) {
  const none = {kind: 'none', text: '', detail: '', buttons: []};
  if (!connected) {
    if (changes) return {kind: 'offline', text: plural(changes), detail: 'in this page only: not connected to a device', buttons: ['discard', 'save']};
    return fresh ? {kind: 'offline', text: 'New preset', detail: 'not saved yet: not connected to a device', buttons: ['save']} : none;
  }
  if (live?.state === 'live') {
    if (changes) return {kind: 'live', text: plural(changes), detail: 'playing now, not saved yet', buttons: ['discard', 'keep', 'save-as']};
    // Nothing differs from what this page last loaded, yet the device plays
    // numbers that are not its saved preset: another page's edits, or this
    // page reloaded mid-edit.
    if (live.previewing) return {kind: 'live', text: 'Unsaved changes', detail: 'are playing on the device, not saved yet', buttons: ['discard', 'keep']};
    return none;
  }
  if (live?.state === 'needs-apply') {
    return changes
      ? {kind: 'restart', text: plural(changes), detail: `not applied: needs a restart, ${outage}`, buttons: ['discard', 'apply', 'save-as']}
      : {kind: 'not-running', text: 'This preset is not running.', detail: `The device runs ${running || 'another one'}. Applying restarts audio: ${outage}`, buttons: ['apply']};
  }
  // Connected, but the device takes no live edits now: it runs without a
  // preset of yours, or cannot apply at all. liveState's reason says which.
  const canApply = Boolean(applyAvailable);
  if (changes) {
    return {kind: 'restart', text: plural(changes), detail: canApply ? `not applied: needs a restart, ${outage}` : `not applied. ${live?.reason || ''}`.trim(),
      buttons: canApply ? ['discard', 'apply', 'save-as'] : ['discard', 'save']};
  }
  if (canApply) return {kind: 'not-running', text: 'This preset is not running.', detail: `The device runs ${running || 'without one'}. Applying restarts audio: ${outage}`, buttons: ['apply']};
  return fresh ? {kind: 'offline', text: 'New preset', detail: `not saved yet. ${live?.reason || ''}`.trim(), buttons: ['save']} : none;
}
