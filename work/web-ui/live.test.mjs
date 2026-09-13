import test from 'node:test';
import assert from 'node:assert/strict';
import { LiveQueue } from './live.mjs';

/** Manual timers: nothing fires until the test says so. */
function timers() {
  const queue = [];
  let handles = 0;
  return {
    setTimeout: (fn, ms) => { const handle = ++handles; queue.push({handle, fn, ms}); return handle; },
    clearTimeout: handle => { const at = queue.findIndex(entry => entry.handle === handle); if (at >= 0) queue.splice(at, 1); },
    fire: () => { const entry = queue.shift(); if (entry) entry.fn(); },
    get armed() { return queue.length; },
  };
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test('a burst of edits becomes one request carrying the newest draft', async () => {
  const t = timers();
  const sent = [];
  const queue = new LiveQueue({send: async draft => { sent.push(draft); return 'ok'; }, setTimeout: t.setTimeout, clearTimeout: t.clearTimeout});
  for (let i = 1; i <= 25; i += 1) queue.submit(`draft ${i}`);
  assert.equal(t.armed, 1, 'one debounce timer stands');
  assert.equal(sent.length, 0, 'nothing sent before the debounce');
  t.fire();
  await settle();
  assert.deepEqual(sent, ['draft 25']);
  assert.equal(queue.coalesced, 24);
  assert.equal(queue.sent, 1);
});

test('edits during a request wait for it and then go as one, without another debounce', async () => {
  const t = timers();
  const sent = [];
  let release;
  const first = new Promise(resolve => { release = resolve; });
  const queue = new LiveQueue({send: async draft => { sent.push(draft); if (sent.length === 1) await first; return 'ok'; },
                               setTimeout: t.setTimeout, clearTimeout: t.clearTimeout});
  queue.submit('a');
  t.fire();
  await settle();
  assert.deepEqual(sent, ['a']);
  assert.ok(queue.busy);
  queue.submit('b'); queue.submit('c');
  t.fire();           // the debounce for b/c fires while a is in flight
  await settle();
  assert.deepEqual(sent, ['a'], 'c waits: one in flight at a time');
  release('done');
  await settle(); await settle();
  assert.deepEqual(sent, ['a', 'c'], 'the newest waiting draft follows at once');
  assert.equal(t.armed, 0);
  assert.ok(!queue.busy);
});

test('outcomes are reported and a failure does not stop the next draft', async () => {
  const t = timers();
  const outcomes = [];
  const queue = new LiveQueue({send: async draft => { if (draft === 'bad') throw new Error('refused'); return draft; },
                               setTimeout: t.setTimeout, clearTimeout: t.clearTimeout, onSettled: o => outcomes.push(o)});
  queue.submit('bad'); t.fire(); await settle(); await settle();
  queue.submit('good'); t.fire(); await settle(); await settle();
  assert.deepEqual(outcomes.map(o => [o.ok, o.draft, o.error?.message ?? o.result]), [[false, 'bad', 'refused'], [true, 'good', 'good']]);
});

test('cancel drops what is waiting but not what is in flight', async () => {
  const t = timers();
  const sent = [];
  const queue = new LiveQueue({send: async draft => { sent.push(draft); return 'ok'; }, setTimeout: t.setTimeout, clearTimeout: t.clearTimeout});
  queue.submit('x');
  queue.cancel();
  assert.equal(t.armed, 0);
  t.fire();
  await settle();
  assert.deepEqual(sent, [], 'cancelled before sending');
  queue.submit('y'); t.fire(); await settle();
  assert.deepEqual(sent, ['y']);
});

test('the default timers are called free of the queue as receiver (browser Illegal invocation)', async () => {
  // A stand-in for a browser: a timer that throws when its receiver is not the global.
  const real = globalThis.setTimeout, realClear = globalThis.clearTimeout;
  globalThis.setTimeout = function (fn, ms) { if (this !== globalThis && this !== undefined) throw new TypeError('Illegal invocation'); return real(fn, ms); };
  globalThis.clearTimeout = function (h) { if (this !== globalThis && this !== undefined) throw new TypeError('Illegal invocation'); return realClear(h); };
  try {
    const sent = [];
    const queue = new LiveQueue({send: async d => { sent.push(d); }, delayMs: 1});
    queue.submit('a'); queue.submit('b');
    await new Promise(resolve => real(resolve, 20));
    assert.deepEqual(sent, ['b']);
  } finally {
    globalThis.setTimeout = real; globalThis.clearTimeout = realClear;
  }
});
