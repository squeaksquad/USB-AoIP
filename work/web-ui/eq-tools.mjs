// Global EQ scope helpers: bypass, multi-band reset and linked headphone EQ.
// Pure draft edits; nothing here talks to hardware or CamillaDSP.
import { validateConfig } from './model.mjs';
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
