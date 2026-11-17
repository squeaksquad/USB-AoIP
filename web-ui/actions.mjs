// The System tab's Actions (docs/web/REDESIGN-2026-11.md, phase 2): what each
// action is called and says, what its question asks, the password check, and
// what the applier's receipt for one means in words. Pure: no document, no
// fetch, so it runs under node's test runner.
//
// Which actions are drawn is the device's answer (health.control.apply.actions);
// an action it does not list is left out, never shown disabled.

/** The order the cards are drawn in, and every kind the page knows. */
export const ACTION_KINDS = ['restart-audio', 'restart-clock', 'bundle', 'password', 'reboot', 'shutdown'];

const sentence = text => text.charAt(0).toUpperCase() + text.slice(1);

// tone: plain | caution | danger (the card's button).
const CARDS = {
  'restart-audio': {label: 'Restart audio', tone: 'plain', text: outage => `Stops and restarts the audio service on the same preset: ${outage}.`},
  'restart-clock': {label: 'Restart clock service', tone: 'plain', text: outage => `Use after a clock leader appears on the network and the device has not locked to it. Audio restarts with it: ${outage}.`},
  bundle: {label: 'Download support bundle', tone: 'plain', text: () => 'One file with the logs, versions, start check result and the running preset.'},
  password: {label: 'Change page password', tone: 'plain', text: () => 'Sets a new password for this page.'},
  reboot: {label: 'Reboot the Pi', tone: 'caution', text: () => 'Audio stops and this page disconnects until the Pi is back; it reconnects by itself.'},
  shutdown: {label: 'Shut down the Pi', tone: 'danger', text: () => 'Audio stops and the computer loses the device. It needs a power-cycle to start again.'},
};

/**
 * The cards to draw, in the page's order, for the kinds the device lists.
 * Unknown kinds and repeats are dropped. `outage` is the stack's outage words
 * (stackTerms(health).outage), the only duration the page states.
 */
export function actionCards(actions, {outage = 'audio stops'} = {}) {
  const listed = new Set(Array.isArray(actions) ? actions : []);
  return ACTION_KINDS.filter(kind => listed.has(kind)).map(kind => ({kind, label: CARDS[kind].label, text: CARDS[kind].text(outage), tone: CARDS[kind].tone}));
}

/**
 * The question asked before an action: {title, text, ok, tone}, tone 'plain'
 * or 'danger'. Null for the bundle, which changes nothing and is not asked.
 * `unkept` is true when live changes are playing that are not kept: a
 * restart drops them.
 */
export function confirmDialog(kind, {outage = 'audio stops', unkept = false} = {}) {
  const drop = unkept ? ' Changes you have not kept will be dropped.' : '';
  switch (kind) {
    case 'restart-audio': return {title: 'Restart audio?', text: `Audio restarts on the same preset: ${outage}.${drop}`, ok: 'Restart audio', tone: 'plain'};
    case 'restart-clock': return {title: 'Restart the clock service?', text: `The audio service restarts with the clock service, and the device finds the clock leader again: ${outage}.${drop}`, ok: 'Restart clock service', tone: 'plain'};
    case 'reboot': return {title: 'Reboot the Pi?', text: `Audio stops and this page disconnects until the Pi has started again; it reconnects by itself. The computer loses the device until it is back.${drop}`, ok: 'Reboot', tone: 'danger'};
    case 'shutdown': return {title: 'Shut down the Pi?', text: `Audio stops and the computer loses the device. It cannot be started again from this page: it needs a power-cycle. Stop playback first.${drop}\n\nWhen its lights stop, unplug the USB cable first, then the network cable; plugging the network cable back in starts it again.`, ok: 'Shut down', tone: 'danger'};
    case 'password': return {title: 'Change page password', text: 'You will be asked to sign in again with the new password.', ok: 'Change password', tone: 'plain'};
    default: return null;
  }
}

/** The service's bounds on a new password (8 to 256 characters). */
export const PASSWORD_MIN = 8, PASSWORD_MAX = 256;

/** What is wrong with the two typed entries, or '' when they will do. */
export function passwordProblem(first, second) {
  const a = String(first ?? ''), b = String(second ?? '');
  if (a.length < PASSWORD_MIN) return 'Use at least 8 characters.';
  if (a.length > PASSWORD_MAX) return `Use at most ${PASSWORD_MAX} characters.`;
  if (a !== b) return 'The two entries do not match.';
  return '';
}

const RUNNING = {
  'restart-audio': 'Restarting audio…', 'restart-clock': 'Restarting the clock service…', bundle: 'Making the support bundle…',
  password: 'Changing the page password…', reboot: 'Rebooting…', shutdown: 'Shutting down…',
};
const DONE = {
  'restart-audio': at => `Audio restarted at ${at}.`,
  'restart-clock': at => `Clock service restarted at ${at}.`,
  bundle: (at, current) => `Support bundle made at ${at}${Number.isInteger(current.bundle?.bytes) ? ` (${current.bundle.bytes} bytes)` : ''}.`,
  password: (at, current) => `Page password changed${current.user ? ` for ${current.user}` : ''} at ${at}.`,
  reboot: at => `Reboot issued at ${at}: the Pi is restarting.`,
  shutdown: at => `Shutdown issued at ${at}: the Pi is powering off.`,
};
const FINISHED = new Set(['done', 'failed', 'refused', 'rolled-back']);

/** Whether a receipt is one of the Actions'. */
export const isActionReceipt = current => Boolean(current) && ACTION_KINDS.includes(current.kind);

/**
 * The Actions panel's status note for the applier's receipt: {text, tone},
 * tone 'busy' | 'ok' | 'bad'. Null for no receipt or another kind's.
 */
export function actionNote(current) {
  if (!isActionReceipt(current)) return null;
  const kind = current.kind, at = current.finishedAt || 'an unknown time';
  if (!FINISHED.has(current.state)) return {text: RUNNING[kind], tone: 'busy'};
  if (current.state === 'done') return {text: DONE[kind](at, current), tone: 'ok'};
  const why = current.error || 'no detail';
  if (current.state === 'refused') return {text: `${CARDS[kind].label}: refused. ${sentence(why)}`, tone: 'bad'};
  return {text: `${CARDS[kind].label} failed: ${why}`, tone: 'bad'};
}

/** The id the applier gave a bundle, from its receipt's file name; null when it has none. */
export function bundleId(current) {
  const match = /^([a-f0-9]{8,32})\.json$/.exec(String(current?.bundle?.file ?? ''));
  return match ? match[1] : null;
}

/** Where the page downloads a bundle from, from its receipt; null when it has none. */
export function bundlePath(current) {
  const id = bundleId(current);
  return id ? `/api/support/${id}` : null;
}

/** The name the bundle is saved under. */
export const BUNDLE_FILE = 'usb-aoip-support.json';
