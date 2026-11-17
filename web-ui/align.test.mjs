import test from 'node:test';
import assert from 'node:assert/strict';
import { delaysFromDistances, parseDistance } from './align.mjs';

test('the farthest speaker gets no delay and nearer ones wait for it', () => {
  const {delays, limited, farthest} = delaysFromDistances([3, 2, null, 3]);
  assert.deepEqual(delays, [0, 2.92, null, 0]);       // 1 m at 343 m/s = 2.915 ms
  assert.deepEqual(limited, []);
  assert.equal(farthest, 3);
});

test('feet give the same delays as the same path in metres', () => {
  const metres = delaysFromDistances([3.048, 1.524]).delays;
  assert.deepEqual(delaysFromDistances([10, 5], 'ft').delays, metres);
});

test('a difference past 10 ms is held at the limit and reported', () => {
  const {delays, limited} = delaysFromDistances([6, 1, 5]);
  assert.equal(delays[1], 10);
  assert.deepEqual(limited, [1]);
  assert.equal(delays[2], 2.92);
});

test('no distances changes nothing; bad ones are refused', () => {
  assert.deepEqual(delaysFromDistances([null, null]), {delays: [null, null], limited: [], farthest: null});
  assert.throws(() => delaysFromDistances([-1]));
  assert.throws(() => delaysFromDistances([NaN]));
  assert.throws(() => delaysFromDistances([1], 'yd'));
});

test('typed distances', () => {
  assert.equal(parseDistance(' 2,5 '), 2.5);
  assert.equal(parseDistance(''), null);
  assert.ok(Number.isNaN(parseDistance('two')));
  assert.ok(Number.isNaN(parseDistance('-1')));
});
