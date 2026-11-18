'use strict';

const PEEK_DURATION_MS = 2500;
const RETRACT_DELAY_MS = 500;

/**
 * Coordinates temporary non-activating shelf reveals ("peeks").
 * Automatically expires after the peek window unless held by pointer hover
 * or promoted/canceled by user interaction.
 */
class PeekController {
  #onExpire;
  #setTimeout;
  #clearTimeout;
  #now;
  #active = false;
  #held = false;
  #generation = null;
  #deadline = 0;
  #timer = null;

  constructor({
    onExpire,
    setTimeout = globalThis.setTimeout,
    clearTimeout = globalThis.clearTimeout,
    now = () => Date.now()
  } = {}) {
    if (typeof onExpire !== 'function') throw new TypeError('PeekController requires an onExpire callback');
    this.#onExpire = onExpire;
    this.#setTimeout = setTimeout;
    this.#clearTimeout = clearTimeout;
    this.#now = now;
  }

  get active() {
    return this.#active;
  }

  get held() {
    return this.#held;
  }

  get generation() {
    return this.#generation;
  }

  /**
   * Starts or renews a timed peek for a given visibility generation.
   * Preserves an active pointer hover hold when renewing the same peek.
   */
  start(generation, durationMs = PEEK_DURATION_MS) {
    if (!Number.isFinite(durationMs) || durationMs <= 0) {
      this.cancel();
      return false;
    }
    const preservingHold = this.#active && this.#held && this.#generation === generation;
    this.#active = true;
    this.#generation = generation;
    const nextDeadline = this.#now() + durationMs;
    this.#deadline = preservingHold ? Math.max(this.#deadline, nextDeadline) : nextDeadline;
    if (!preservingHold) {
      this.#held = false;
      this.#schedule(durationMs);
    }
    return true;
  }

  /** Pauses automatic retraction while the pointer rests over shelf controls or cards. */
  hold() {
    if (!this.#active) return false;
    this.#held = true;
    this.#clearTimer();
    return true;
  }

  /** Resumes automatic retraction after leaving shelf controls, waiting at least delayMs. */
  release(delayMs = RETRACT_DELAY_MS) {
    if (!this.#active) return false;
    this.#held = false;
    const retractDelay = Number.isFinite(delayMs) && delayMs >= 0 ? delayMs : RETRACT_DELAY_MS;
    const remaining = Math.max(0, this.#deadline - this.#now());
    this.#schedule(Math.max(retractDelay, remaining));
    return true;
  }

  /** Cancels any active peek timer and clears peek state; returns whether one was active. */
  cancel() {
    const wasActive = this.#active;
    this.#clearTimer();
    this.#active = false;
    this.#held = false;
    this.#generation = null;
    this.#deadline = 0;
    return wasActive;
  }

  #clearTimer() {
    if (this.#timer !== null) {
      this.#clearTimeout(this.#timer);
      this.#timer = null;
    }
  }

  #schedule(delayMs) {
    this.#clearTimer();
    const generation = this.#generation;
    this.#timer = this.#setTimeout(() => {
      if (!this.#active || this.#held || this.#generation !== generation) return;
      this.cancel();
      this.#onExpire(generation);
    }, Math.max(0, delayMs));
    this.#timer?.unref?.();
  }
}

module.exports = {
  PeekController,
  PEEK_DURATION_MS,
  RETRACT_DELAY_MS
};
