// Global EQ scope helpers: bypass, multi-band reset and linked headphone EQ.
// Pure draft edits; nothing here talks to hardware or CamillaDSP.
import { validateConfig, createConfig } from './model.mjs';
import { parseRew } from './workflows.mjs';
import { resetBand } from './reset-band.mjs';

/** Reset every band of one output. Band on/off states, gain, delay and routing are retained. */
export function resetOutputBands(output) {
  if (!output || !Array.isArray(output.bands) || output.bands.length !== 16) throw new Error('Expected an output with 16 EQ bands');
  return { ...output, bands: output.bands.map((band, i) => resetBand(band, i)) };
}

/** Reset the PEQ of one output, or of every output when index is null. */
export function resetEq(config, index = null) {
  const result = structuredClone(config);
  if (index === null) result.outputs = result.outputs.map(resetOutputBands);
  else {
    if (!Number.isInteger(index) || index < 0 || index >= result.outputs.length) throw new Error('Choose an output from 1 to 16');
    result.outputs[index] = resetOutputBands(result.outputs[index]);
  }
  return validateConfig(result);
}

/** Global bypass. Per-output EQ enables are retained so the previous state returns unchanged. */
export function setEqBypass(config, bypass) {
  if (typeof bypass !== 'boolean') throw new Error('Global EQ bypass must be on or off');
  const result = structuredClone(config);
  result.eqBypass = bypass;
  return validateConfig(result);
}

/** Outputs whose EQ follows this one: the other ear of a headphones bus with EQ linking on. */
export function linkedEqOutputs(config, index) {
  const bus = config.buses?.find(value => value.outputIds.includes(index));
  if (!bus || bus.kind !== 'headphones' || !bus.linkEq) return [];
  return bus.outputIds.filter(i => i !== index);
}

/** Copy one output's EQ onto every linked output. Labels, gain, delay and routing stay put. */
export function mirrorLinkedEq(config, index) {
  const targets = linkedEqOutputs(config, index);
  if (!targets.length) return config;
  const result = structuredClone(config);
  for (const target of targets) {
    result.outputs[target].bands = structuredClone(result.outputs[index].bands);
    result.outputs[target].eqEnabled = result.outputs[index].eqEnabled;
  }
  return validateConfig(result);
}

export const EQ_FILE_FORMAT = 'usb-aoip-eq';

/** The EQ of the given outputs (all sixteen when none are named) as the object an EQ file holds. */
export function exportEq(config, indices = null) {
  const chosen = indices ?? config.outputs.map((_, i) => i);
  if (!Array.isArray(chosen) || !chosen.length || chosen.some(i => !Number.isInteger(i) || i < 0 || i >= config.outputs.length)) throw new Error('Choose an output from 1 to 16');
  return { format: EQ_FILE_FORMAT, version: 1, outputs: chosen.map(i => ({
    output: i + 1, label: config.outputs[i].label, eqEnabled: config.outputs[i].eqEnabled, bands: structuredClone(config.outputs[i].bands) })) };
}

/**
 * Sixteen bands for one output from what was pasted or chosen: an EQ file
 * made by exportEq (its first output), or REW's filter text. Returns
 * {bands, count, source}; throws with a reason a person can act on.
 */
export function importEq(text) {
  const trimmed = String(text ?? '').trim();
  if (!trimmed) throw new Error('Nothing to import: choose a file or paste its contents');
  if (trimmed.length > 200000) throw new Error('The file is too large to be an EQ');
  if (!trimmed.startsWith('{')) { const rew = parseRew(trimmed); return { bands: rew.bands, count: rew.count, source: 'REW' }; }
  let parsed;
  try { parsed = JSON.parse(trimmed); } catch { throw new Error('This is not an EQ file: it could not be read as JSON'); }
  const bands = parsed?.format === EQ_FILE_FORMAT ? parsed.outputs?.[0]?.bands : parsed?.bands;
  if (!Array.isArray(bands) || bands.length !== 16) throw new Error('This is not an EQ file: it needs sixteen bands');
  const probe = createConfig();
  probe.outputs[0].bands = structuredClone(bands).map(b => ({ enabled: b?.enabled, type: b?.type, frequency: b?.frequency, gainDb: b?.gainDb, q: b?.q }));
  validateConfig(probe);
  return { bands: probe.outputs[0].bands, count: probe.outputs[0].bands.filter(b => b.enabled && b.gainDb !== 0).length, source: 'EQ file' };
}
