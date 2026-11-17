// The list under "Presets on the device": what the device can run without
// processing, and every preset, whether it is saved for editing, installed to
// run, or both. Pure: the page hands in what the device reported.

/** The rule the web service and the applier use for a preset's name on the device. */
export function presetSlug(name) {
  const slug = String(name || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24).replace(/-+$/, '');
  return /^[a-z0-9][a-z0-9-]{0,23}$/.test(slug) ? slug : '';
}

/** A name the preset store accepts: letters, digits, spaces, dots, dashes and underscores. */
export function storeName(name) {
  return String(name ?? '').replace(/[^A-Za-z0-9 ._-]/g, '-').replace(/\s+/g, ' ').trim().slice(0, 64);
}

/** Why a typed preset name cannot be used, or '' when it can. `taken` are the names in use. */
export function nameProblem(name, taken = [], except = null) {
  const trimmed = String(name ?? '').trim();
  if (!trimmed) return 'Give it a name.';
  if (trimmed.length > 64) return 'Names are at most 64 characters.';
  if (storeName(trimmed) !== trimmed) return 'Use letters, digits, spaces, dots, dashes and underscores.';
  const slug = presetSlug(trimmed);
  if (!slug) return 'The name needs at least one letter or digit.';
  if (taken.some(other => other !== except && presetSlug(other) === slug)) return 'Another preset already has this name.';
  return '';
}

/**
 * stored     the preset store's {name: document}
 * installed  userPresets(health): [{name, slug, description, live}]
 * profiles   the device's other profiles (no processing of yours): [{name, description, live}]
 * canApply   the device can switch and install
 * Returns {fixed, presets}. Each preset row: {name, slug, stored, installed,
 * running, canRun, canEdit, canRename, canRemove, note}.
 */
export function presetRows({stored = {}, installed = [], profiles = [], canApply = false}) {
  const fixed = profiles.map(row => ({
    name: row.name, title: row.name === 'direct' ? 'Direct' : row.name,
    note: row.name === 'direct' ? 'No processing: audio passes through unchanged' : (row.description || ''),
    running: Boolean(row.live), canRun: canApply && !row.live,
  }));
  const bySlug = new Map();
  for (const name of Object.keys(stored)) {
    const slug = presetSlug(name);
    // Two saved names with one slug cannot both be installed; the first keeps the slug.
    const key = slug && !bySlug.has(slug) ? slug : `:${name}`;
    bySlug.set(key, {name, slug, stored: true, installed: false, running: false});
  }
  for (const row of installed) {
    const found = bySlug.get(row.slug);
    if (found) Object.assign(found, {installed: true, running: Boolean(row.live)});
    else bySlug.set(row.slug, {name: row.slug, slug: row.slug, stored: false, installed: true, running: Boolean(row.live)});
  }
  const presets = [...bySlug.values()].map(row => ({
    ...row,
    canRun: canApply && !row.running && (row.installed || (row.stored && Boolean(row.slug))),
    canEdit: row.stored,
    canRename: row.stored && !row.running,
    canRemove: !row.running,
    note: row.running ? 'Running now'
      : row.installed && row.stored ? 'On the device, ready to run'
      : row.installed ? 'On the device. Its settings were not saved with it, so it can run but not be opened here'
      : canApply ? 'Saved. Running it installs it first' : 'Saved',
  })).sort((a, b) => Number(b.running) - Number(a.running) || a.name.localeCompare(b.name));
  return {fixed, presets};
}
