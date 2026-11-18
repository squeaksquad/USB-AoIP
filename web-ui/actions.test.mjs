import test from 'node:test';
import assert from 'node:assert/strict';
import { ACTION_KINDS, actionCards, confirmDialog, passwordProblem, actionNote, isActionReceipt, bundleId, bundlePath, BUNDLE_FILE } from './actions.mjs';

const outage = 'audio stops for a few seconds';

test('actionCards: the page\'s order, only what the device lists, with each card\'s tone', () => {
  const all = actionCards([...ACTION_KINDS].reverse(), {outage});
  assert.deepEqual(all.map(card => card.kind), ['restart-audio', 'restart-clock', 'bundle', 'password', 'reboot', 'shutdown']);
  assert.deepEqual(all.map(card => card.label), ['Restart audio', 'Restart clock service', 'Download support bundle', 'Change page password', 'Reboot the Pi', 'Shut down the Pi']);
  assert.deepEqual(all.map(card => card.tone), ['plain', 'plain', 'plain', 'plain', 'caution', 'danger']);
  assert.equal(all[0].text, 'Stops and restarts the audio service on the same preset: audio stops for a few seconds.');
  assert.match(all[1].text, /Audio restarts with it: audio stops for a few seconds\./, 'the endpoint restarts with the clock');
  assert.equal(all[2].text, 'One file with the logs, versions, start check result and the running preset.');
  assert.deepEqual(actionCards(['bundle', 'reboot', 'bundle', 'format-disk']).map(card => card.kind), ['bundle', 'reboot']);
  assert.deepEqual(actionCards([]), []);
  assert.deepEqual(actionCards(undefined), []);
  assert.deepEqual(actionCards('reboot'), [], 'not a list');
});

test('no card or question states a duration the page does not know', () => {
  const texts = [...actionCards(ACTION_KINDS, {outage}).map(card => card.text), ...ACTION_KINDS.map(kind => confirmDialog(kind, {outage})).filter(Boolean).map(d => d.text)];
  for (const text of texts) assert.doesNotMatch(text, /about (3 seconds|a minute)|\d+ seconds/);
});

test('confirmDialog: title, text, button and tone per kind; none for the bundle', () => {
  assert.deepEqual(confirmDialog('restart-audio', {outage}), {title: 'Restart audio?', text: 'Audio restarts on the same preset: audio stops for a few seconds.', ok: 'Restart audio', tone: 'plain'});
  const clock = confirmDialog('restart-clock', {outage});
  assert.equal(clock.title, 'Restart the clock service?'); assert.equal(clock.ok, 'Restart clock service');
  assert.match(clock.text, /audio service restarts with the clock service/); assert.doesNotMatch(clock.text, /may drop/);
  const reboot = confirmDialog('reboot');
  assert.equal(reboot.title, 'Reboot the Pi?'); assert.equal(reboot.ok, 'Reboot'); assert.equal(reboot.tone, 'danger');
  assert.match(reboot.text, /reconnects by itself/);
  const off = confirmDialog('shutdown');
  assert.equal(off.title, 'Shut down the Pi?'); assert.equal(off.ok, 'Shut down'); assert.equal(off.tone, 'danger');
  assert.match(off.text, /unplug the USB cable first, then the network cable/);
  assert.deepEqual(confirmDialog('password'), {title: 'Change page password', text: 'You will be asked to sign in again with the new password.', ok: 'Change password', tone: 'plain'});
  assert.equal(confirmDialog('bundle'), null);
  assert.equal(confirmDialog('nope'), null);
  assert.match(confirmDialog('restart-audio', {outage, unkept: true}).text, /Changes you have not kept will be dropped\.$/);
  assert.match(confirmDialog('shutdown', {unkept: true}).text, /dropped\.\n\n/);
  assert.doesNotMatch(confirmDialog('restart-audio', {outage}).text, /dropped/);
});

test('passwordProblem: the mockup\'s two errors, and the service\'s upper bound', () => {
  assert.equal(passwordProblem('', ''), 'Use at least 8 characters.');
  assert.equal(passwordProblem('1234567', '1234567'), 'Use at least 8 characters.');
  assert.equal(passwordProblem('12345678', '12345679'), 'The two entries do not match.');
  assert.equal(passwordProblem('12345678', '12345678'), '');
  assert.equal(passwordProblem(' spaced pass ', ' spaced pass '), '', 'spaces are part of a password');
  assert.equal(passwordProblem('x'.repeat(256), 'x'.repeat(256)), '');
  assert.equal(passwordProblem('x'.repeat(257), 'x'.repeat(257)), 'Use at most 256 characters.');
  assert.equal(passwordProblem(null, undefined), 'Use at least 8 characters.');
});

test('actionNote: in progress, done, refused and failed, from the receipt', () => {
  assert.equal(actionNote(null), null);
  assert.equal(actionNote({kind: 'profile', state: 'done'}), null, 'another kind\'s receipt is the Last change panel\'s');
  assert.equal(isActionReceipt({kind: 'live'}), false);
  assert.equal(isActionReceipt({kind: 'bundle'}), true);
  assert.deepEqual(actionNote({kind: 'restart-audio', state: 'stopping'}), {text: 'Restarting audio…', tone: 'busy'});
  assert.deepEqual(actionNote({kind: 'restart-clock', state: 'restarting-clock'}), {text: 'Restarting the clock service…', tone: 'busy'});
  assert.deepEqual(actionNote({kind: 'reboot', state: 'validating'}), {text: 'Rebooting…', tone: 'busy'});
  assert.deepEqual(actionNote({kind: 'restart-audio', state: 'done', finishedAt: '2026-11-16T10:00:00Z'}), {text: 'Audio restarted at 2026-11-16T10:00:00Z.', tone: 'ok'});
  assert.equal(actionNote({kind: 'restart-clock', state: 'done', finishedAt: 'T'}).text, 'Clock service restarted at T.');
  assert.equal(actionNote({kind: 'bundle', state: 'done', finishedAt: 'T', bundle: {file: 'abcdef12.json', bytes: 2048}}).text, 'Support bundle made at T (2048 bytes).');
  assert.equal(actionNote({kind: 'bundle', state: 'done', finishedAt: 'T'}).text, 'Support bundle made at T.');
  assert.equal(actionNote({kind: 'password', state: 'done', finishedAt: 'T', user: 'bryan'}).text, 'Page password changed for bryan at T.');
  assert.equal(actionNote({kind: 'password', state: 'done'}).text, 'Page password changed at an unknown time.');
  assert.equal(actionNote({kind: 'reboot', state: 'done', finishedAt: 'T'}).text, 'Reboot issued at T: the Pi is restarting.');
  assert.equal(actionNote({kind: 'shutdown', state: 'done', finishedAt: 'T'}).text, 'Shutdown issued at T: the Pi is powering off.');
  assert.deepEqual(actionNote({kind: 'restart-clock', state: 'refused', error: 'this stack has no separate clock service'}), {text: 'Restart clock service: refused. This stack has no separate clock service', tone: 'bad'});
  assert.deepEqual(actionNote({kind: 'restart-audio', state: 'failed', error: 'the endpoint did not start'}), {text: 'Restart audio failed: the endpoint did not start', tone: 'bad'});
  assert.equal(actionNote({kind: 'password', state: 'failed'}).text, 'Change page password failed: no detail');
  assert.equal(actionNote({kind: 'reboot', state: 'rolled-back', error: 'x'}).tone, 'bad');
});

test('bundleId and bundlePath: only a file name the service would serve', () => {
  assert.equal(bundleId({bundle: {file: '0123456789abcdef.json', bytes: 10}}), '0123456789abcdef');
  assert.equal(bundlePath({bundle: {file: '0123456789abcdef.json'}}), '/api/support/0123456789abcdef');
  for (const file of ['../etc.json', 'ABCDEF12.json', 'abc.json', 'abcdef12', 'abcdef12.json/x', `${'a'.repeat(33)}.json`, '']) assert.equal(bundlePath({bundle: {file}}), null, file);
  assert.equal(bundlePath({}), null);
  assert.equal(bundlePath(null), null);
  assert.equal(BUNDLE_FILE, 'usb-aoip-support.json');
});
