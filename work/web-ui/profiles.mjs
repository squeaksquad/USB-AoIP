// A/B profile slots: two complete drafts held in the page for quick comparison.
// Slots live for the session only; named presets remain the durable store.
import { validateConfig } from './model.mjs';

export const SLOTS = ['A', 'B'];

export function createSlots(config) {
  return { active: 'A', slots: { A: structuredClone(validateConfig(config)), B: null } };
}

function assertSlot(name) {
  if (!SLOTS.includes(name)) throw new Error('Choose slot A or B');
}

/** Store the live draft in the active slot, then make `target` live. An empty target is seeded from it. */
export function switchSlot(state, target, config) {
  assertSlot(target);
  assertSlot(state.active);
  const slots = { ...state.slots, [state.active]: structuredClone(validateConfig(config)) };
  const seeded = slots[target] ?? structuredClone(slots[state.active]);
  slots[target] = seeded;
  return { state: { active: target, slots }, config: structuredClone(validateConfig(seeded)), seeded: state.slots[target] === null || state.slots[target] === undefined };
}

/** Copy one slot over the other, e.g. A -> B before trying a variation. */
export function copySlot(state, from, to, config) {
  assertSlot(from); assertSlot(to);
  if (from === to) throw new Error('Choose two different slots');
  const slots = { ...state.slots, [state.active]: structuredClone(validateConfig(config)) };
  if (!slots[from]) throw new Error(`Slot ${from} is empty`);
  slots[to] = structuredClone(slots[from]);
  return { active: state.active, slots };
}

export function slotSummary(state, config) {
  return SLOTS.map(name => {
    const stored = name === state.active ? config : state.slots[name];
    return { name, active: name === state.active, filled: Boolean(stored), label: stored?.name ?? 'Empty' };
  });
}
