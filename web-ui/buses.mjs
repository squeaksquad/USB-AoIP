import { validateConfig, createConfig, settleSubShares, SUB_SHARES } from './model.mjs';
import { LAYOUTS, swapOutputs } from './workflows.mjs';

export function getBus(config, id) {
  const bus = config.buses?.find(value => value.id === id);
  if (!bus) throw new Error(`Unknown output bus: ${id}`);
  return bus;
}

export function busForOutput(config, outputId) {
  if (!Number.isInteger(outputId) || outputId < 0 || outputId >= 16) throw new Error('Choose an output from 1 to 16');
  return config.buses?.find(bus => bus.outputIds.includes(outputId)) ?? null;
}

/** Input channels that actually feed a speaker bus, in channel order. */
export function speakerGroupSourceIds(config) {
  const speakerOutputs = new Set((config.buses || [])
    .filter(bus => bus.kind === 'speakers')
    .flatMap(bus => bus.outputIds));
  const sources = new Set();
  let hasSub = false;
  for (const outputId of speakerOutputs) {
    const output = config.outputs[outputId];
    if (output?.role === 'speaker') sources.add(output.source);
    else if (output?.role === 'sub') hasSub = true;
  }
  if (hasSub) sources.add(config.lfe.input);
  return config.inputs.map((_, i) => i).filter(i => sources.has(i));
}

/** A layout's output order: its subwoofer positions dropped when `subs` is false. */
function layoutRouting(layout, subs) {
  return subs ? layout.routing : layout.routing.filter(source => source !== null);
}

export function applyBusLayout(config, busId, layoutId, outputIds = null, {subs = true} = {}) {
  const sourceBus = getBus(config, busId);
  const found = LAYOUTS.find(value => value.id === layoutId);
  if (!found) throw new Error('Choose an output format');
  const layout = subs ? found : {...found, routing: layoutRouting(found, false), subs: 0};
  const ids = outputIds ?? sourceBus.outputIds;
  if (sourceBus.kind === 'headphones' && layout.routing.length !== 2) throw new Error('Headphones bus supports stereo layouts only');
  if (!Array.isArray(ids) || ids.length < layout.routing.length || ids.some(i => !Number.isInteger(i) || i < 0 || i >= 16) || new Set(ids).size !== ids.length) throw new Error('Bus layout needs distinct physical outputs');
  const result = structuredClone(config);
  const bus = getBus(result, busId);
  const old = new Set(bus.outputIds);
  const target = ids.slice(0, layout.routing.length);
  for (const i of target) {
    const owner = busForOutput(result, i);
    if (owner && owner.id !== busId) throw new Error(`Output ${i + 1} belongs to bus ${owner.label}`);
  }
  for (const i of old) { result.outputs[i].busId = null; if (!target.includes(i)) result.outputs[i].role = 'unused'; }
  for (const i of new Set([...old, ...target])) result.sends.forEach(row => { row[i] = null; });
  const defaults = createConfig().outputs;
  for (const physical of target) {
    const busRef = result.outputs[physical].busId;
    result.outputs[physical] = { ...structuredClone(defaults[physical]), busId: busRef };
  }
  bus.outputIds = target;
  bus.layoutId = layoutId;
  target.forEach((physical, i) => {
    const source = layout.routing[i];
    result.outputs[physical].busId = busId;
    if (source === null) Object.assign(result.outputs[physical], { label: layout.bed >= 5 ? (i === 3 ? 'LFE' : 'Sub 2') : 'Sub', role: 'sub', source: result.lfe.input });
    else Object.assign(result.outputs[physical], { label: ['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Ltf','Rtf','Ltr','Rtr','Lw','Rw','Ltm','Rtm'][source], role: 'speaker', source });
  });
  if (sourceBus.kind === 'speakers') {
    const subOutputs = layout.routing.flatMap((source, i) => source === null ? [target[i]] : []);
    for (const source of layout.sources) {
      if (source === result.lfe.input) continue;
      const label = ['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Ltf','Rtf','Ltr','Rtr','Lw','Rw','Ltm','Rtm'][source];
      if (layout.subs === 1) result.sends[source][subOutputs[0]] = 0;
      else if (layout.subs === 2) { if (label.startsWith('L')) result.sends[source][subOutputs[0]] = 0; else if (label.startsWith('R')) result.sends[source][subOutputs[1]] = 0; else { result.sends[source][subOutputs[0]] = -6; result.sends[source][subOutputs[1]] = -6; } }
    }
    for (const output of subOutputs) result.sends[result.lfe.input][output] = layout.subs === 1 ? 0 : -6;
  }
  settleSubShares(result);
  return validateConfig(result);
}

export function setHeadphoneMode(config, busId, mode) {
  const result = structuredClone(config), bus = getBus(result, busId);
  if (!bus) throw new Error('Add a headphones bus first');
  if (bus.kind !== 'headphones') throw new Error('Selected bus is not a headphones bus');
  if (!['pair', 'downmix'].includes(mode)) throw new Error('Headphones input mode must be pair or downmix');
  bus.inputMode = mode;
  return validateConfig(result);
}

export function setHeadphonePair(config, busId, pair) {
  const result = structuredClone(config), bus = getBus(result, busId);
  if (!bus) throw new Error('Add a headphones bus first');
  if (bus.kind !== 'headphones') throw new Error('Selected bus is not a headphones bus');
  if (!Array.isArray(pair) || pair.length !== 2 || pair.some(i => !Number.isInteger(i) || i < 0 || i >= 16)) throw new Error('Headphones input pair must contain two inputs');
  bus.inputPair = [...pair];
  return validateConfig(result);
}

export function setHeadphoneMatrix(config, busId, matrix) {
  const result = structuredClone(config), bus = getBus(result, busId);
  if (!bus) throw new Error('Add a headphones bus first');
  if (bus.kind !== 'headphones') throw new Error('Selected bus is not a headphones bus');
  if (!Array.isArray(matrix) || matrix.length !== 16 || matrix.some(row => !Array.isArray(row) || row.length !== 2)) throw new Error('Headphones downmix matrix must be 16 by 2');
  bus.downmixMatrix = structuredClone(matrix);
  return validateConfig(result);
}

/** What an output is, for display: a headphones-bus member reads as a headphone, not a speaker. */
export function outputRoleLabel(config, index) {
  if (!Number.isInteger(index) || index < 0 || index >= 16) throw new Error('Choose an output from 1 to 16');
  const output = config.outputs[index];
  const bus = config.buses?.find(value => value.outputIds.includes(index));
  if (bus?.kind === 'headphones') {
    const ear = bus.outputIds.indexOf(index);
    return { short: ear === 0 ? 'PHONES L' : ear === 1 ? 'PHONES R' : 'PHONES', long: 'Headphone', kind: 'headphone' };
  }
  if (output.role === 'unused') return { short: 'SPARE', long: 'Unused', kind: 'unused' };
  if (output.role === 'sub') return { short: 'SUB', long: 'Subwoofer', kind: 'sub' };
  return { short: 'SPEAKER', long: 'Speaker', kind: 'speaker' };
}

/** Move a bus onto chosen physical outputs. Processing, labels and routes travel with each channel. */
export function setBusOutputs(config, busId, outputIds) {
  const bus = getBus(config, busId);
  if (!Array.isArray(outputIds) || outputIds.length !== bus.outputIds.length || new Set(outputIds).size !== outputIds.length) throw new Error(`Choose ${bus.outputIds.length} distinct physical outputs`);
  if (outputIds.some(i => !Number.isInteger(i) || i < 0 || i >= 16)) throw new Error('Choose an output from 1 to 16');
  let result = structuredClone(config);
  outputIds.forEach((target, n) => {
    const current = getBus(result, busId).outputIds[n];
    if (current !== target) result = swapOutputs(result, current, target);
  });
  const moved = getBus(result, busId);
  moved.outputIds = [...outputIds];
  result.outputs.forEach((output, i) => { if (output.busId === busId && !outputIds.includes(i)) output.busId = null; });
  return validateConfig(result);
}

/** Group the two headphone ears so one EQ edit applies to both. Turning it on copies the left ear. */
export function setBusEqLink(config, busId, linked) {
  if (typeof linked !== 'boolean') throw new Error('EQ link must be on or off');
  const result = structuredClone(config), bus = getBus(result, busId);
  if (bus.kind !== 'headphones') throw new Error('EQ linking applies to headphones buses');
  bus.linkEq = linked;
  if (linked) {
    const [first, ...rest] = bus.outputIds;
    for (const i of rest) {
      result.outputs[i].bands = structuredClone(result.outputs[first].bands);
      result.outputs[i].eqEnabled = result.outputs[first].eqEnabled;
    }
  }
  return validateConfig(result);
}

export function createHeadphoneBus(config, id = 'headphones', outputIds = [14, 15]) {
  const result = structuredClone(config);
  if (!/^[a-z][a-z0-9-]{0,31}$/.test(id) || result.buses.some(bus => bus.id === id)) throw new Error('Choose a unique bus ID');
  if (!Array.isArray(outputIds) || outputIds.length !== 2 || outputIds.some(i => !Number.isInteger(i) || i < 0 || i >= 16) || new Set(outputIds).size !== 2) throw new Error('Headphones bus needs two distinct outputs');
  if (outputIds.some(i => busForOutput(result, i))) throw new Error('Headphones outputs must be unallocated or reassigned first');
  const matrix = Array.from({ length: 16 }, () => [null, null]);
  matrix[0] = [0, null]; matrix[1] = [null, 0]; matrix[2] = [-3, -3];
  for (const i of [4, 6, 8, 10]) matrix[i] = [-3, null];
  for (const i of [5, 7, 9, 11]) matrix[i] = [null, -3];
  for (const i of [8, 10]) matrix[i] = [-6, null];
  for (const i of [9, 11]) matrix[i] = [null, -6];
  matrix[config.lfe.input] = [null, null];
  result.buses.push({ id, kind: 'headphones', label: 'Headphones', outputIds: [...outputIds], layoutId: 'stereo', inputMode: 'pair', inputPair: [0, 1], downmixMatrix: matrix, sourcePreCrossover: true, linkEq: false });
  outputIds.forEach((i, ear) => { result.outputs[i].busId = id; result.outputs[i].role = 'speaker'; result.outputs[i].source = ear; result.outputs[i].label = `Headphone ${ear ? 'R' : 'L'}`; });
  return validateConfig(result);
}

/** The outputs a new speaker set of this layout takes: its speakers, plus its
 *  subwoofers when it has its own. */
export function speakerSetSize(layoutId, subShare) {
  const layout = LAYOUTS.find(value => value.id === layoutId);
  if (!layout) throw new Error('Choose an output format');
  return layoutRouting(layout, subShare === 'own').length;
}

/** Which subwoofer choices a new speaker set of this layout can have, in the order the page offers them. */
export function subShareChoices(config, layoutId) {
  const layout = LAYOUTS.find(value => value.id === layoutId);
  const first = config.buses.find(bus => bus.kind === 'speakers');
  const mainSub = Boolean(first?.outputIds.some(i => config.outputs[i].role === 'sub'));
  return SUB_SHARES.filter(share => share === 'main' ? mainSub : share === 'own' ? Boolean(layout?.subs) : true);
}

/**
 * Add a speaker set: a layout on chosen spare outputs, in output order, with
 * the subwoofer choice. `own` keeps the layout's subwoofers and makes their
 * sends; `main` and `none` drop them. Speakers are named after their channel
 * and the set's number (L 2, R 2), as the Routing tab shows them.
 */
export function addSpeakerSet(config, {layoutId, outputIds, subShare, label = null}) {
  if (!config.buses.some(bus => bus.kind === 'speakers')) throw new Error('Add the main speakers first');
  if (!SUB_SHARES.includes(subShare)) throw new Error('Choose what the speaker set does for a subwoofer');
  if (!subShareChoices(config, layoutId).includes(subShare)) {
    throw new Error(subShare === 'main' ? 'The main speakers have no subwoofer to share' : 'This layout has no subwoofer of its own');
  }
  const size = speakerSetSize(layoutId, subShare);
  const ids = [...(outputIds || [])].sort((a, b) => a - b);
  if (ids.length !== size || new Set(ids).size !== size || ids.some(i => !Number.isInteger(i) || i < 0 || i >= 16)) throw new Error(`Choose ${size} spare outputs`);
  if (ids.some(i => busForOutput(config, i))) throw new Error('Choose spare outputs only');
  const number = config.buses.filter(bus => bus.kind === 'speakers').length + 1;
  let n = number, id = `speakers-${n}`;
  while (config.buses.some(bus => bus.id === id)) { n += 1; id = `speakers-${n}`; }
  const result = structuredClone(config);
  const name = (label ?? `Speakers ${number}`).trim().slice(0, 24) || `Speakers ${number}`;
  result.buses.push({ id, kind: 'speakers', label: name, outputIds: [...ids], layoutId, subShare });
  ids.forEach(i => { result.outputs[i].busId = id; });
  const made = applyBusLayout(result, id, layoutId, ids, {subs: subShare === 'own'});
  const bus = getBus(made, id), subs = bus.outputIds.filter(i => made.outputs[i].role === 'sub');
  for (const i of bus.outputIds) {
    const output = made.outputs[i];
    output.label = output.role === 'sub'
      ? (subs.length === 1 ? `Sub ${number}` : `Sub ${number} ${subs.indexOf(i) ? 'R' : 'L'}`)
      : `${output.label} ${number}`;
  }
  return validateConfig(made);
}

export function removeBus(config, id) {
  const result = structuredClone(config), bus = getBus(result, id);
  if (bus.kind === 'speakers' && result.buses.filter(value => value.kind === 'speakers').length <= 1) {
    bus.outputIds.forEach(i => { result.outputs[i].busId = null; result.outputs[i].role = 'unused'; result.sends.forEach(row => { row[i] = null; }); });
    bus.outputIds = []; bus.layoutId = 'custom';
    return validateConfig(result);
  }
  bus.outputIds.forEach(i => { result.outputs[i].busId = null; result.outputs[i].role = 'unused'; result.sends.forEach(row => { row[i] = null; }); });
  result.buses = result.buses.filter(value => value.id !== id);
  settleSubShares(result);
  return validateConfig(result);
}
