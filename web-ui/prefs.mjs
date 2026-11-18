// What this browser remembers about how the page is shown. Never anything
// about the device or a preset. Storage can be missing or refuse (a private
// window): the page then simply does not remember.

export const PREFS_KEY = 'usb-aoip-display-v1';
const DEFAULTS = {big: false};

export function readPrefs(storage = globalThis.localStorage) {
  try {
    const stored = JSON.parse(storage.getItem(PREFS_KEY) || '{}');
    return {big: stored?.big === true};
  } catch { return {...DEFAULTS}; }
}

/** Returns whether it was remembered. */
export function savePrefs(prefs, storage = globalThis.localStorage) {
  try { storage.setItem(PREFS_KEY, JSON.stringify({big: prefs.big === true})); return true; }
  catch { return false; }
}
