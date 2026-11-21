'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { PeekController, PEEK_DURATION_MS, RETRACT_DELAY_MS } = require('../lib/peek-controller.cjs');

function createClock() {
  let time = 1000;
  let nextId = 1;
  const timers = new Map();

  const setTimeout = (fn, delay) => {
    const id = nextId++;
    const handle = { id, unref() {} };
    timers.set(id, { at: time + delay, fn });
    return handle;
  };

  const clearTimeout = (handle) => {
    if (handle && timers.has(handle.id)) timers.delete(handle.id);
  };

  const advance = (ms) => {
    const target = time + ms;
    while (true) {
      let earliest = null;
      for (const [id, entry] of timers.entries()) {
        if (entry.at <= target && (!earliest || entry.at < earliest.at || (entry.at === earliest.at && id < earliest.id))) {
          earliest = { id, ...entry };
        }
      }
      if (!earliest) break;
      timers.delete(earliest.id);
      time = earliest.at;
      earliest.fn();
    }
    time = target;
  };

  return { setTimeout, clearTimeout, now: () => time, advance, pending: () => timers.size };
}

test('PeekController requires an onExpire callback', () => {
  assert.throws(() => new PeekController(), TypeError);
});

test('timed peek expires after 2500ms unless canceled', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  assert.equal(peek.start(7, PEEK_DURATION_MS), true);
  assert.equal(peek.active, true);
  assert.equal(peek.held, false);
  assert.equal(peek.generation, 7);

  clock.advance(2499);
  assert.deepEqual(expired, []);
  assert.equal(peek.active, true);

  clock.advance(1);
  assert.deepEqual(expired, [7]);
  assert.equal(peek.active, false);
  assert.equal(peek.generation, null);
  assert.equal(clock.pending(), 0);
});

test('cancel stops scheduled expiration and is idempotent', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  peek.start(3);
  clock.advance(500);
  assert.equal(peek.cancel(), true);
  assert.equal(peek.cancel(), false);
  assert.equal(peek.active, false);
  assert.equal(clock.pending(), 0);

  clock.advance(5000);
  assert.deepEqual(expired, []);
});

test('hold pauses expiration indefinitely and release retracts after 500ms once initial deadline passes', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  peek.start(4);
  clock.advance(600);
  assert.equal(peek.hold(), true);
  assert.equal(peek.held, true);
  assert.equal(clock.pending(), 0);

  clock.advance(10000);
  assert.deepEqual(expired, []);
  assert.equal(peek.active, true);

  assert.equal(peek.release(), true);
  assert.equal(peek.held, false);
  clock.advance(RETRACT_DELAY_MS - 1);
  assert.deepEqual(expired, []);
  clock.advance(1);
  assert.deepEqual(expired, [4]);
  assert.equal(peek.active, false);
});

test('brief hover and early release still respects the remainder of the 2500ms peek window', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  peek.start(5);
  clock.advance(200);
  peek.hold();
  clock.advance(200);
  peek.release();

  clock.advance(2099);
  assert.deepEqual(expired, []);
  clock.advance(1);
  assert.deepEqual(expired, [5]);
});

test('second capture renews deadline and preserves active hover hold until released', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  peek.start(9);
  clock.advance(500);
  peek.hold();
  clock.advance(1000);

  // Renew while pointer remains hovered on shelf controls/cards.
  assert.equal(peek.start(9, PEEK_DURATION_MS), true);
  assert.equal(peek.held, true);
  assert.equal(clock.pending(), 0);

  clock.advance(500);
  assert.deepEqual(expired, []);

  // Releasing 500ms after renewal still waits the remaining 2000ms of the renewed peek.
  assert.equal(peek.release(), true);
  clock.advance(1999);
  assert.deepEqual(expired, []);
  clock.advance(1);
  assert.deepEqual(expired, [9]);
});

test('non-hovered renewal extends expiration and new generation supersedes old generation', () => {
  const clock = createClock();
  const expired = [];
  const peek = new PeekController({
    onExpire: (generation) => expired.push(generation),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    now: clock.now
  });

  peek.start(1);
  clock.advance(2000);
  peek.start(1, PEEK_DURATION_MS);
  clock.advance(600);
  assert.deepEqual(expired, []);

  // Supersede with a newer window generation.
  peek.start(2, 100);
  clock.advance(100);
  assert.deepEqual(expired, [2]);

  assert.equal(peek.start(3, 0), false);
  assert.equal(peek.active, false);
});
