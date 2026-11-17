// Peak hold and clip latch for one bank of meters, from the engine's taps.
// Each tap window carries a peak in dBFS and a cumulative clip count per
// channel. The hold shows the highest recent peak for a moment; the latch
// stays lit from the first new clip until someone clears it.

export const PEAK_HOLD_MS = 1500;
export const FLOOR_DB = -60;

export class MeterHold {
  constructor(channels = 16, holdMs = PEAK_HOLD_MS) {
    this.holdMs = holdMs;
    this.hold = new Array(channels).fill(FLOOR_DB);
    this.heldAt = new Array(channels).fill(0);
    this.seen = new Array(channels).fill(null);
    this.latched = new Array(channels).fill(false);
  }

  /** One window: bank[i] = {peak, clipped}. Returns [{peak, hold, clip}] per channel. */
  update(bank, now) {
    return this.hold.map((_, i) => {
      const peak = Number.isFinite(bank?.[i]?.peak) ? bank[i].peak : FLOOR_DB;
      if (peak >= this.hold[i] || now - this.heldAt[i] > this.holdMs) { this.hold[i] = peak; this.heldAt[i] = now; }
      const count = bank?.[i]?.clipped;
      if (Number.isFinite(count)) {
        // The first count seen is where the engine already was, not a new clip.
        // A count that went down is a restarted engine: start again from it.
        if (this.seen[i] !== null && count > this.seen[i]) this.latched[i] = true;
        this.seen[i] = count;
      }
      return {peak, hold: this.hold[i], clip: this.latched[i]};
    });
  }

  get anyClip() { return this.latched.some(Boolean); }

  clearClips() { this.latched.fill(false); }
}

/** A level in dBFS as a 0-100 bar height over the meter's 60 dB range. */
export function levelPercent(db) {
  if (!Number.isFinite(db)) return 0;
  return Math.max(0, Math.min(100, (db - FLOOR_DB) / -FLOOR_DB * 100));
}
