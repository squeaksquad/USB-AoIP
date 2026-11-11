// Which crossovers a preset actually applies, and what that implies.
//
// Shared by the UI and work/dsp-compiler so the two can never disagree about
// what a preset does. It reports; it never edits. In particular it will not
// flip a polarity for you: whether two branches sum depends on the drivers,
// their positions and the room, and only a measurement settles it.

/** Inputs used as the speaker source of a non-headphone output. */
function speakerSources(config) {
  const used = new Set();
  config.outputs.forEach((output, index) => {
    if (output.role !== 'speaker') return;
    const bus = config.buses.find(value => value.outputIds.includes(index));
    if (!bus || bus.kind === 'headphones') return;
    used.add(output.source);
  });
  return used;
}

const feedsASub = (config, input) =>
  config.sends[input].some((gain, output) => gain !== null && config.outputs[output].role === 'sub');

/**
 * Every crossover filter the preset will actually emit, in compile order.
 *
 * Mirrors work/dsp-compiler/compile.mjs exactly: a high-pass only where a main
 * branch exists and redirection is on, a low-pass only where a bass branch
 * exists, and the LFE branch carrying the LFE low-pass rather than its input's.
 */
export function activeCrossovers(config) {
  const list = [];
  const sources = speakerSources(config);
  config.inputs.forEach((input, index) => {
    if (config.bassEnabled && input.crossover && sources.has(index)) {
      list.push({kind: 'highpass', input: index, label: input.label,
                 hz: input.highpassHz, slope: input.slope});
    }
  });
  config.inputs.forEach((input, index) => {
    const isLfe = index === config.lfe.input;
    if (!config.bassEnabled && !isLfe) return;
    if (!feedsASub(config, index)) return;
    list.push(isLfe
      ? {kind: 'lowpass', input: index, label: input.label,
         hz: config.lfe.lowpassHz, slope: config.lfe.slope, lfe: true}
      : {kind: 'lowpass', input: index, label: input.label,
         hz: input.lowpassHz, slope: input.slope});
  });
  return list;
}

export const POLARITY_HEADLINE =
  'A 12 dB/oct Linkwitz-Riley crossover needs a polarity decision';

export const POLARITY_DETAIL =
  'Its two branches sit 180 degrees apart at the crossover frequency, so the ' +
  'main and the sub usually need opposite polarity to sum. Nothing has been ' +
  'inverted for you: set Polarity on the output you choose and verify the ' +
  'result acoustically. 24 and 48 dB/oct do not have this property.';

/**
 * A polarity note, or null when no active crossover is 12 dB/oct.
 *
 * Lists the affected inputs so the user can see which branches it concerns
 * rather than being told something vague about the whole preset.
 */
export function polarityNote(config) {
  const affected = activeCrossovers(config).filter(entry => entry.slope === 12);
  if (!affected.length) return null;
  const inputs = [...new Set(affected.map(entry => entry.input))].sort((a, b) => a - b);
  return {
    inputs,
    labels: inputs.map(index => config.inputs[index].label),
    highpassCount: affected.filter(entry => entry.kind === 'highpass').length,
    lowpassCount: affected.filter(entry => entry.kind === 'lowpass').length,
    headline: POLARITY_HEADLINE,
    detail: POLARITY_DETAIL,
  };
}

/** One line for a log or a compiler report. */
export function polarityWarningText(config) {
  const note = polarityNote(config);
  if (!note) return null;
  const names = note.labels.map((label, i) => `${note.inputs[i] + 1} ${label}`).join(', ');
  return `${note.headline}. ${note.detail} Affected inputs: ${names}.`;
}
