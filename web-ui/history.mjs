// Undo and redo for the draft preset. Page state only: nothing here reaches
// the device. A state is whatever the caller hands in (the draft, cloned by
// the caller); the history never looks inside it.

export const HISTORY_LIMIT = 100;

export class History {
  constructor(limit = HISTORY_LIMIT) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error('History limit must be a whole number above zero');
    this.limit = limit;
    this.past = [];
    this.future = [];
  }

  get canUndo() { return this.past.length > 0; }
  get canRedo() { return this.future.length > 0; }

  /** Call with the state as it was BEFORE an edit. A new edit ends any redo. */
  record(before) {
    this.past.push(before);
    if (this.past.length > this.limit) this.past.shift();
    this.future = [];
  }

  /** Give the current state, get the one before it; null when there is none. */
  undo(current) {
    if (!this.past.length) return null;
    this.future.push(current);
    return this.past.pop();
  }

  /** Give the current state, get back the one that was undone; null when there is none. */
  redo(current) {
    if (!this.future.length) return null;
    this.past.push(current);
    return this.future.pop();
  }

  /** A new preset, a loaded one, a discard: the old steps no longer apply. */
  clear() { this.past = []; this.future = []; }
}
