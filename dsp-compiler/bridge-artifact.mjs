// The compiled pipeline as something the bridge can load.
//
// The bridge is a real-time C++ process. Handing it YAML would mean a parser
// and a dependency on the audio host for no benefit, so it gets a flat,
// line-oriented artifact instead: counts, then rows, then coefficients.
//
// This is emitted from the *compiled CamillaDSP configuration object*, not from
// the preset a second time. The two outputs are therefore one pipeline
// serialised twice rather than two compilations that have to be kept in step,
// which is what lets the bridge's filtering be checked against CamillaDSP
// sample for sample on the same preset and mean something.
//
// Everything the engine expresses as a dB gain and a polarity flag becomes one
// signed linear gain here, and a mute becomes a gain of zero: the bridge should
// multiply, not branch, on the audio path.

import { bandBiquad, crossoverBiquads } from './coefficients.mjs';

export const ARTIFACT_VERSION = 1;
// 10 ms at 48 kHz, the alignment delay ceiling model.mjs validates against.
export const MAX_DELAY_SAMPLES = 480;
/** The same 10 ms at any rate; DspStage::max_delay_samples in the bridge. */
export const maxDelaySamples = rate => rate / 100;

const CAMILLA_BAND_TYPE = {Peaking: 'bell', Lowshelf: 'lowShelf', Highshelf: 'highShelf'};
const ORDER_SLOPE = {2: 12, 4: 24, 8: 48};

/** JavaScript's default number formatting round-trips exactly; keep it. */
const number = value => String(value);
const linear = source =>
  source.mute ? 0 : 10 ** (source.gain / 20) * (source.inverted ? -1 : 1);

function sectionsFor(filter, rate) {
  if (filter.type === 'Biquad') {
    const {type, freq, q, gain} = filter.parameters;
    if (type === 'Free') {
      // Explicit coefficients: the fixed shape's unity placeholder. Taken as
      // written so the two serialisations cannot disagree on a slot.
      const {b0, b1, b2, a1, a2} = filter.parameters;
      return [{b0, b1, b2, a1, a2}];
    }
    const band = CAMILLA_BAND_TYPE[type];
    if (band === undefined) throw new Error(`Unknown biquad type ${type}`);
    return [bandBiquad({type: band, frequency: freq, q, gainDb: gain}, rate)];
  }
  if (filter.type === 'BiquadCombo') {
    const {type, freq, order} = filter.parameters;
    const slope = ORDER_SLOPE[order];
    if (slope === undefined) throw new Error(`Unsupported crossover order ${order}`);
    if (type === 'LinkwitzRileyHighpass') return crossoverBiquads('highpass', freq, slope, rate);
    if (type === 'LinkwitzRileyLowpass') return crossoverBiquads('lowpass', freq, slope, rate);
    throw new Error(`Unknown combo type ${type}`);
  }
  throw new Error(`Filter type ${filter.type} has no biquad form`);
}

/** The pipeline's filter steps, split by the assign mixer that separates the
 *  two channel numberings. Before it the indices are internal channels; after
 *  it they are physical outputs. */
function filterSteps(config) {
  const assignAt = config.pipeline.findIndex(
    step => step.type === 'Mixer' && step.name === 'assign');
  const collect = steps => {
    const byChannel = new Map();
    for (const step of steps) {
      if (step.type !== 'Filter') continue;
      for (const channel of step.channels) {
        const existing = byChannel.get(channel) ?? [];
        byChannel.set(channel, [...existing, ...step.names]);
      }
    }
    return byChannel;
  };
  return {
    branch: collect(config.pipeline.slice(0, assignAt)),
    output: collect(config.pipeline.slice(assignAt + 1)),
  };
}

/**
 * Serialise a `compile()` result as the bridge's coefficient artifact.
 *
 * Layout, one record per line, counts before rows so the loader can size every
 * allocation once and never grow anything afterwards:
 *
 *     usb16x16-dsp 1
 *     rate R / channels 16 / internal N / maxdelay R/100   (48000 and 480 at 48 kHz)
 *     expand N        then N rows of  DEST SRC GAIN
 *     branch N        then N of       CHANNEL SECTIONS  + SECTIONS coefficient rows
 *     assign N        then N rows of  DEST SRC GAIN
 *     output 16       then 16 of      OUT DELAY GAIN SECTIONS + coefficient rows
 *     end
 */
export function bridgeArtifact(result, {presetName} = {}) {
  const {config, plan} = result;
  // Coefficients for the rate the pipeline was compiled at, which the artifact
  // names and the bridge checks against the rate it runs at.
  const rate = config.devices.samplerate;
  const maxDelay = maxDelaySamples(rate);
  const steps = filterSteps(config);
  const lines = [];

  const expand = [];
  for (const entry of config.mixers.expand.mapping) {
    for (const source of entry.sources) {
      expand.push(`${entry.dest} ${source.channel} ${number(linear(source))}`);
    }
  }
  const assign = [];
  for (const entry of config.mixers.assign.mapping) {
    if (entry.mute) continue;                 // a muted bus contributes nothing
    for (const source of entry.sources) {
      assign.push(`${entry.dest} ${source.channel} ${number(linear(source))}`);
    }
  }

  const branch = [];
  let branchCount = 0;
  for (const [channel, names] of [...steps.branch.entries()].sort((a, b) => a[0] - b[0])) {
    const sections = names.flatMap(name => sectionsFor(config.filters[name], rate));
    if (!sections.length) continue;
    branchCount += 1;
    branch.push(`${channel} ${sections.length}`);
    for (const s of sections) {
      branch.push([s.b0, s.b1, s.b2, s.a1, s.a2].map(number).join(' '));
    }
  }

  const outputs = [];
  for (let output = 0; output < config.mixers.assign.channels.out; output += 1) {
    const names = steps.output.get(output) ?? [];
    const sections = [];
    let delay = 0;
    let gain = 1;
    for (const name of names) {
      const filter = config.filters[name];
      if (filter.type === 'Delay') {
        if (filter.parameters.unit !== 'samples') {
          throw new Error('The bridge takes whole-sample delays only');
        }
        delay += filter.parameters.delay;
      } else if (filter.type === 'Gain') {
        gain *= filter.parameters.mute ? 0 : linear(filter.parameters);
      } else {
        sections.push(...sectionsFor(filter, rate));
      }
    }
    if (delay > maxDelay) {
      throw new Error(`Output ${output + 1} asks for ${delay} samples of delay, over the ${maxDelay} ceiling`);
    }
    outputs.push({output, delay, gain, sections});
  }

  lines.push(`usb16x16-dsp ${ARTIFACT_VERSION}`);
  lines.push(`preset ${presetName ?? config.title}`);
  lines.push(`rate ${rate}`);
  lines.push(`channels ${config.mixers.expand.channels.in}`);
  lines.push(`internal ${plan.channels.length}`);
  lines.push(`maxdelay ${maxDelay}`);
  lines.push(`expand ${expand.length}`, ...expand);
  lines.push(`branch ${branchCount}`, ...branch);
  lines.push(`assign ${assign.length}`, ...assign);
  lines.push(`output ${outputs.length}`);
  for (const entry of outputs) {
    lines.push(`${entry.output} ${entry.delay} ${number(entry.gain)} ${entry.sections.length}`);
    for (const s of entry.sections) {
      lines.push([s.b0, s.b1, s.b2, s.a1, s.a2].map(number).join(' '));
    }
  }
  if (result.monitor) {
    const tags = config.mixers.expand.mapping.flatMap(entry =>
      entry.sources.map(() => result.monitor.channelSet[entry.dest]));
    lines.push(...monitorSection(result.monitor, tags));
  }
  lines.push('end');
  return `${lines.join('\n')}\n`;
}

// ------------------------------------------------------------- monitor section
//
// Phase 3, the monitor block: the preset's speaker sets and headphones, which
// outputs belong to which, their labels, and each speaker set's fold-downs, as
// an optional section just before `end`. The bridge applies a fold at its
// input (DspStage, bridge_core.hpp): each expand row is tagged with the set
// whose view of the 16 inputs it reads, so folded content is bass-managed and
// gets the EQ of the speaker that plays it; headphone rows read the inputs.
//
//     monitor 1
//     sets S                 1..8
//     set ID KIND            S lines; KIND speakers|headphones; index = order
//     outs N                 0..16
//     out INDEX ROLE SET...  INDEX ascending; ROLE speaker|sub; sets ascending
//     label INDEX TEXT       zero or more, INDEX ascending, outputs in outs only
//     expandsets N           N = the expand row count
//     SET|-                  N lines: the set an expand row reads, '-' the inputs
//     folds F                up to 4 per set
//     fold SET NAME ROWS     SET a speakers set; NAME not 'full'; ROWS 1..256
//     DEST SRC GAIN          view[DEST] += GAIN * in[SRC]; a DEST with no row is silent
//
// Everything but the label lines is shape (artifactShape), fold gains
// included, so a live edit never changes the section.

export const MONITOR_VERSION = 1;
export const MONITOR_LIMITS = Object.freeze({sets: 8, foldsPerSet: 4, foldRows: 256, label: 32});
const SET_ID = /^[a-z][a-z0-9-]{0,31}$/;
const FOLD_NAME = /^[a-z0-9.]{1,16}$/;

/** Programme channels by input index, the fixed order the fold table uses. */
export const PROGRAMME = Object.freeze(['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs',
  'Ltf', 'Rtf', 'Ltr', 'Rtr', 'Lw', 'Rw', 'Ltm', 'Rtm']);
const P = Object.fromEntries(PROGRAMME.map((name, index) => [name, index]));

/** A sparse matrix as [dest, [[src, gain]...]] rows, composed outer after inner:
 *  result[d][s] = sum over k of outer[d][k] * inner[k][s], summed in the
 *  outer row's order, so the arithmetic (and so every emitted gain) is fixed. */
function compose(outer, inner) {
  const innerRows = new Map(inner);
  return outer.map(([dest, terms]) => {
    const acc = new Map();
    for (const [k, g] of terms) {
      for (const [source, h] of innerRows.get(k) ?? []) acc.set(source, (acc.get(source) ?? 0) + g * h);
    }
    return [dest, [...acc]];
  }).filter(([, terms]) => terms.length);
}

/**
 * The fold-downs a speaker set offers, from the inputs its speakers play.
 *
 * Programme channel = input index (PROGRAMME). With a = Math.SQRT1_2, h = 0.5,
 * and only the terms whose source the set uses (the LFE always passes):
 *
 *   5.1     L' = L + a Lw + a Ltf + h Ltm     R' likewise (Rw, Rtf, Rtm)
 *           C' = C    Ls' = Ls + a Lrs + a Ltr + h Ltm    Rs' likewise    LFE' = LFE
 *           offered when the set uses L, R, C, Ls, Rs and any input above Rs
 *   stereo  L'' = L' + a C' + a Ls'    R'' = R' + a C' + a Rs'    LFE passes
 *           offered when the set uses L, R and any other non-LFE input
 *   mono    L''' = R''' = 0.5 (L'' + R'')    LFE passes
 *           offered when the set uses L and R
 *
 * Not normalised: a hot mix can exceed full scale and saturates at the
 * converter, the engine's measured behaviour. Duplicate (DEST, SRC) terms are
 * summed by matrix composition (compose). `lfe` is the input that passes as
 * the LFE (the preset's LFE input; 3 in the programme order).
 *
 * Returns [{name, rows: [[dest, src, gain]...]}], rows sorted by dest then src.
 */
export function monitorFolds(usedInputs, {lfe = P.LFE} = {}) {
  const used = new Set(usedInputs);
  const a = Math.SQRT1_2, h = 0.5;
  const terms = list => list.filter(([source]) => used.has(source));
  const lfeRow = [lfe, [[lfe, 1]]];
  const five = [
    [P.L, terms([[P.L, 1], [P.Lw, a], [P.Ltf, a], [P.Ltm, h]])],
    [P.R, terms([[P.R, 1], [P.Rw, a], [P.Rtf, a], [P.Rtm, h]])],
    [P.C, terms([[P.C, 1]])],
    [P.Ls, terms([[P.Ls, 1], [P.Lrs, a], [P.Ltr, a], [P.Ltm, h]])],
    [P.Rs, terms([[P.Rs, 1], [P.Rrs, a], [P.Rtr, a], [P.Rtm, h]])],
    lfeRow,
  ].filter(([, list]) => list.length);
  const stereo = compose([
    [P.L, [[P.L, 1], [P.C, a], [P.Ls, a]]],
    [P.R, [[P.R, 1], [P.C, a], [P.Rs, a]]],
    lfeRow,
  ], five);
  const mono = compose([
    [P.L, [[P.L, 0.5], [P.R, 0.5]]],
    [P.R, [[P.L, 0.5], [P.R, 0.5]]],
    lfeRow,
  ], stereo);
  const has = (...names) => names.every(name => used.has(P[name]));
  const others = [...used].some(input => input !== P.L && input !== P.R && input !== P.LFE && input !== lfe);
  const folds = [];
  const rows = matrix => matrix.flatMap(([dest, list]) => list.map(([source, gain]) => [dest, source, gain]))
    .sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  if (has('L', 'R', 'C', 'Ls', 'Rs') && [...used].some(input => input > P.Rs)) folds.push({name: '5.1', rows: rows(five)});
  if (has('L', 'R') && others) folds.push({name: 'stereo', rows: rows(stereo)});
  if (has('L', 'R')) folds.push({name: 'mono', rows: rows(mono)});
  return folds;
}

/** An output label as the section carries it: printable ASCII, '?' for
 *  anything else, runs of spaces collapsed, trimmed, at most 32 characters.
 *  Empty means no label line. */
export function monitorLabel(text) {
  const ascii = [...String(text)].map(ch => (ch >= ' ' && ch <= '~' ? ch : '?')).join('');
  return ascii.replace(/ +/g, ' ').trim().slice(0, MONITOR_LIMITS.label).trim();
}

/**
 * The monitor topology of a validated preset and its channel plan: what
 * `compile()` keeps as `result.monitor` and bridgeArtifact writes.
 *
 * One set per bus, in bus order. Every output in a bus and not unused is
 * listed, with its role. Each plan channel is tagged with the set whose view
 * it reads: `phones` channels read the inputs (null); a `main` channel the set
 * of the speaker outputs that play its input, a `bass` channel the set of the
 * subs it feeds, each when that is one set, else the first speakers set. Per-set
 * main and bass channels, and subs shared between sets, come with preset model
 * v3; the format already carries both.
 */
export function monitorTopology(model, plan) {
  const sets = model.buses.map(bus => ({id: bus.id, kind: bus.kind}));
  const busOfOutput = output => model.buses.findIndex(bus => bus.outputIds.includes(output));
  const outs = [];
  const labels = Array(16).fill(null);
  model.outputs.forEach((spec, index) => {
    const set = busOfOutput(index);
    if (set < 0 || spec.role === 'unused') return;
    outs.push({index, role: spec.role, sets: [set]});
    const label = monitorLabel(spec.label);
    labels[index] = label || null;
  });
  const firstSpeakers = model.buses.findIndex(bus => bus.kind === 'speakers');
  const only = candidates => {
    const distinct = [...new Set(candidates)];
    return distinct.length === 1 ? distinct[0] : firstSpeakers;
  };
  const channelSet = plan.channels.map(channel => {
    if (channel.kind === 'phones') return null;
    if (channel.kind === 'main') {
      return only(outs.filter(out => out.role === 'speaker' && model.outputs[out.index].source === channel.input
        && sets[out.sets[0]].kind === 'speakers').map(out => out.sets[0]));
    }
    return only(outs.filter(out => out.role === 'sub' && model.sends[channel.input][out.index] !== null)
      .map(out => out.sets[0]));
  });
  const folds = [];
  model.buses.forEach((bus, set) => {
    if (bus.kind !== 'speakers') return;
    const used = outs.filter(out => out.role === 'speaker' && out.sets.includes(set))
      .map(out => model.outputs[out.index].source);
    for (const fold of monitorFolds(used, {lfe: model.lfe.input})) folds.push({set, ...fold});
  });
  // A set ID is the bus ID, which model.mjs validates against the same rule.
  return {sets, outs, labels, channelSet, folds};
}

/** The section's lines for a topology and one set tag per expand row. */
export function monitorSection(topology, expandTags) {
  const lines = [`monitor ${MONITOR_VERSION}`, `sets ${topology.sets.length}`];
  for (const set of topology.sets) lines.push(`set ${set.id} ${set.kind}`);
  lines.push(`outs ${topology.outs.length}`);
  for (const out of topology.outs) lines.push(`out ${out.index} ${out.role} ${out.sets.join(' ')}`);
  topology.labels.forEach((label, index) => { if (label) lines.push(`label ${index} ${label}`); });
  lines.push(`expandsets ${expandTags.length}`, ...expandTags.map(tag => (tag === null ? '-' : String(tag))));
  lines.push(`folds ${topology.folds.length}`);
  for (const fold of topology.folds) {
    lines.push(`fold ${fold.set} ${fold.name} ${fold.rows.length}`);
    for (const [dest, source, gain] of fold.rows) lines.push(`${dest} ${source} ${number(gain)}`);
  }
  return lines;
}

/**
 * Read a monitor section from `lines` (trimmed, non-empty) starting at `at`,
 * the line `monitor 1`, through the `end` that closes the artifact. As strict
 * as the bridge's loader, refusing what it refuses. `expandRows`, when given,
 * is the artifact's expand row count, which expandsets must equal.
 *
 * Returns {section, shape, at}: the parsed section, its shape lines (every
 * line but the labels, words joined by single spaces), and the index of the
 * `end` line.
 */
function readMonitor(lines, at, expandRows) {
  let text = '';
  let words = [];
  const refuse = why => new Error(`monitor: ${why} in '${text}'`);
  const next = what => {
    if (at >= lines.length) throw new Error(`monitor: unexpected end, expected ${what}`);
    text = lines[at++];
    words = text.split(/\s+/);
  };
  const shape = [];
  const keep = () => shape.push(words.join(' '));
  const whole = (index, limit, what) => {
    const value = words[index];
    if (value === undefined || !/^\d{1,9}$/.test(value) || Number(value) > limit) {
      throw refuse(`${what} must be a whole number no larger than ${limit}`);
    }
    return Number(value);
  };
  const header = (keyword, limit) => {
    next(keyword);
    if (words.length !== 2 || words[0] !== keyword) throw refuse(`expected '${keyword} N'`);
    const value = whole(1, limit, keyword);
    keep();
    return value;
  };
  next('monitor');
  if (words.length !== 2 || words[0] !== 'monitor' || words[1] !== String(MONITOR_VERSION)) {
    throw refuse('unsupported monitor version');
  }
  keep();
  const section = {sets: [], outs: [], labels: Array(16).fill(null), expandSets: [], folds: []};
  const setCount = header('sets', MONITOR_LIMITS.sets);
  if (setCount === 0) throw refuse('a monitor section needs at least one set');
  for (let index = 0; index < setCount; index += 1) {
    next('set');
    if (words.length !== 3 || words[0] !== 'set') throw refuse("expected 'set ID KIND'");
    if (!SET_ID.test(words[1])) throw refuse('set ID must match [a-z][a-z0-9-]{0,31}');
    if (section.sets.some(set => set.id === words[1])) throw refuse('duplicate set ID');
    if (words[2] !== 'speakers' && words[2] !== 'headphones') throw refuse('set kind must be speakers or headphones');
    section.sets.push({id: words[1], kind: words[2], folds: ['full']});
    keep();
  }
  const speakers = set => section.sets[set].kind === 'speakers';
  const outCount = header('outs', 16);
  for (let row = 0; row < outCount; row += 1) {
    next('out');
    if (words.length < 4 || words[0] !== 'out') throw refuse("expected 'out INDEX ROLE SET...'");
    const index = whole(1, 15, 'output index');
    if (section.outs.length && index <= section.outs.at(-1).index) throw refuse('output indices must ascend');
    const role = words[2];
    if (role !== 'speaker' && role !== 'sub') throw refuse('output role must be speaker or sub');
    const sets = [];
    for (let i = 3; i < words.length; i += 1) {
      const set = whole(i, setCount - 1, 'set index');
      if (sets.length && set <= sets.at(-1)) throw refuse("an output's sets must ascend");
      sets.push(set);
    }
    if (role === 'sub' && !sets.every(speakers)) throw refuse('a sub belongs to speaker sets only');
    if (sets.length > 1 && role !== 'sub') throw refuse('only a sub may belong to more than one set');
    section.outs.push({index, role, sets});
    keep();
  }
  next('label or expandsets');
  let lastLabel = -1;
  while (words[0] === 'label') {
    if (words.length < 3) throw refuse("expected 'label INDEX TEXT'");
    const index = whole(1, 15, 'label index');
    if (index <= lastLabel) throw refuse('label indices must ascend');
    if (!section.outs.some(out => out.index === index)) throw refuse('a label for an output in no set');
    const label = text.replace(/^label\s+\S+\s+/, '');
    if (!label.length || label.length > MONITOR_LIMITS.label || !/^[\x20-\x7e]+$/.test(label)) {
      throw refuse('a label is 1 to 32 printable ASCII characters');
    }
    section.labels[index] = label;
    lastLabel = index;
    next('label or expandsets');
  }
  if (words.length !== 2 || words[0] !== 'expandsets') throw refuse("expected 'expandsets N'");
  const tagged = whole(1, 16 * 48 + 1, 'expandsets');
  if (expandRows !== undefined && tagged !== expandRows) {
    throw refuse(`expandsets must give one set per expand row (${expandRows})`);
  }
  keep();
  for (let row = 0; row < tagged; row += 1) {
    next('an expandsets row');
    if (words.length !== 1) throw refuse("expected a set index or '-'");
    section.expandSets.push(words[0] === '-' ? null : whole(0, setCount - 1, 'set index'));
    keep();
  }
  const foldCount = header('folds', MONITOR_LIMITS.foldsPerSet * setCount);
  for (let index = 0; index < foldCount; index += 1) {
    next('fold');
    if (words.length !== 4 || words[0] !== 'fold') throw refuse("expected 'fold SET NAME ROWS'");
    const set = whole(1, setCount - 1, 'set index');
    if (!speakers(set)) throw refuse('only a speakers set has fold-downs');
    const name = words[2];
    if (!FOLD_NAME.test(name) || name === 'full') throw refuse("fold name must match [a-z0-9.]{1,16} and not be 'full'");
    if (section.sets[set].folds.includes(name)) throw refuse('duplicate fold name in a set');
    if (section.sets[set].folds.length > MONITOR_LIMITS.foldsPerSet) throw refuse('more than 4 fold-downs in one set');
    section.sets[set].folds.push(name);
    const count = whole(3, MONITOR_LIMITS.foldRows, 'fold rows');
    if (count === 0) throw refuse('a fold-down has at least one row');
    keep();
    const rows = [];
    const seen = new Set();
    for (let row = 0; row < count; row += 1) {
      next('a fold row');
      if (words.length !== 3) throw refuse("expected 'DEST SRC GAIN'");
      const dest = whole(0, 15, 'fold destination');
      const source = whole(1, 15, 'fold source');
      if (seen.has(dest * 16 + source)) throw refuse('a (DEST, SRC) pair twice in one fold');
      seen.add(dest * 16 + source);
      const gain = Number(words[2]);
      if (!/^[-+0-9.eE]+$/.test(words[2]) || !Number.isFinite(gain)) throw refuse('fold gain must be a finite number');
      rows.push([dest, source, gain]);
      keep();
    }
    section.folds.push({set, name, rows});
  }
  next('end');
  if (words.length !== 1 || words[0] !== 'end') throw refuse("expected 'end'");
  return {section, shape, at: at - 1};
}

/**
 * The monitor section of an artifact, or null when it has none. Throws on a
 * malformed section, as the bridge would refuse it. The page reads the sets,
 * outputs, labels and fold names from this.
 */
export function parseMonitorSection(text) {
  const lines = text.split('\n').map(line => line.trim()).filter(Boolean);
  const start = lines.findIndex(line => /^monitor(\s|$)/.test(line));
  if (start < 0) return null;
  const expand = lines.find(line => /^expand\s+\d+$/.test(line));
  const expandRows = expand === undefined ? undefined : Number(expand.split(/\s+/)[1]);
  return readMonitor(lines, start, expandRows).section;
}

/**
 * The shape of an artifact: everything in it that is a count or an index, with
 * every gain, delay and coefficient blanked. Two artifacts with the same shape
 * describe the same allocation in the bridge and differ only in numbers, which
 * is exactly what a running `DspStage` can take without a restart
 * (LIVE_COEFFICIENTS_DESIGN.md). Delay is a value here, not shape: the delay
 * lines are sized at the ceiling regardless.
 *
 * Returns the canonical shape text. The same text is what the applier hashes
 * in Python and the bridge derives in C++; `artifactShapeKey` is its SHA-256,
 * and the test pins one vector so all three implementations must agree.
 */
export function artifactShape(text) {
  const lines = text.split('\n').map(line => line.trim()).filter(Boolean);
  let at = 0;
  const next = () => {
    if (at >= lines.length) throw new Error('artifact shape: unexpected end');
    return lines[at++];
  };
  const words = line => line.split(/\s+/);
  const header = (keyword, arity = 1) => {
    const parts = words(next());
    if (parts[0] !== keyword || parts.length !== arity + 1) {
      throw new Error(`artifact shape: expected '${keyword}', found '${parts.join(' ')}'`);
    }
    return parts.slice(1);
  };
  const counted = keyword => {
    const [count] = header(keyword);
    if (!/^\d+$/.test(count)) throw new Error(`artifact shape: ${keyword} count '${count}'`);
    return Number(count);
  };
  const out = [];
  const [version] = header('usb16x16-dsp');
  if (version !== String(ARTIFACT_VERSION)) throw new Error(`artifact shape: version ${version}`);
  out.push(`usb16x16-dsp-shape ${ARTIFACT_VERSION}`);
  // The preset name is not shape.
  if (!next().startsWith('preset')) throw new Error("artifact shape: expected 'preset'");
  out.push(`rate ${header('rate')[0]}`);
  out.push(`channels ${header('channels')[0]}`);
  out.push(`internal ${header('internal')[0]}`);
  out.push(`maxdelay ${header('maxdelay')[0]}`);
  const mix = keyword => {
    const rows = counted(keyword);
    out.push(`${keyword} ${rows}`);
    for (let row = 0; row < rows; row += 1) {
      const [dest, source, gain, ...extra] = words(next());
      if (gain === undefined || extra.length) throw new Error(`artifact shape: ${keyword} row ${row + 1}`);
      out.push(`${dest} ${source}`);
    }
    return rows;
  };
  const skipSections = count => { for (let i = 0; i < count; i += 1) next(); };
  const expandRows = mix('expand');
  const branches = counted('branch');
  out.push(`branch ${branches}`);
  for (let row = 0; row < branches; row += 1) {
    const [channel, sections, ...extra] = words(next());
    if (sections === undefined || extra.length) throw new Error(`artifact shape: branch row ${row + 1}`);
    out.push(`${channel} ${sections}`);
    skipSections(Number(sections));
  }
  mix('assign');
  // Always all 16 outputs in index order, whatever the artifact listed: the
  // bridge keeps one spec per output, and its shape text is written from
  // those (bridge_core.cpp, shape_text), so the two agree on every artifact.
  const outputs = counted('output');
  const perOutput = new Array(16).fill(0);
  for (let row = 0; row < outputs; row += 1) {
    const [index, delay, gain, sections, ...extra] = words(next());
    if (sections === undefined || extra.length || !(Number(index) < 16)) throw new Error(`artifact shape: output row ${row + 1}`);
    perOutput[Number(index)] = Number(sections);
    skipSections(Number(sections));
  }
  out.push('output 16');
  perOutput.forEach((sections, index) => out.push(`${index} ${sections}`));
  // The monitor section, when there is one: every line of it but the labels,
  // as written (fold gains are shape). Without it the shape is unchanged.
  if (at < lines.length && /^monitor(\s|$)/.test(lines[at])) {
    let monitor;
    try { monitor = readMonitor(lines, at, expandRows); }
    catch (error) { throw new Error(`artifact shape: ${error.message}`); }
    out.push(...monitor.shape);
    at = monitor.at;
  }
  if (next() !== 'end' || at !== lines.length) throw new Error("artifact shape: expected 'end'");
  out.push('end');
  return `${out.join('\n')}\n`;
}

/**
 * SHA-256 as lower-case hex. WebCrypto when the page has it; otherwise a plain
 * implementation (FIPS 180-4), because the appliance page is served over
 * plain HTTP from the Pi's address, which browsers treat as an insecure
 * context where `crypto.subtle` does not exist.
 */
export async function sha256Hex(text) {
  const bytes = new TextEncoder().encode(text);
  const subtle = globalThis.crypto?.subtle;
  if (subtle) {
    const digest = await subtle.digest('SHA-256', bytes);
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }
  return sha256HexSync(bytes);
}

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);

/** Synchronous SHA-256 over bytes (Uint8Array), lower-case hex. */
export function sha256HexSync(bytes) {
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  const length = bytes.length;
  const padded = new Uint8Array(((length + 9 + 63) >> 6) << 6);
  padded.set(bytes);
  padded[length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor((length * 8) / 0x100000000), false);
  view.setUint32(padded.length - 4, (length * 8) >>> 0, false);
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const w = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i += 1) w[i] = view.getUint32(offset + i * 4, false);
    for (let i = 16; i < 64; i += 1) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i += 1) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + s1 + ch + K[i] + w[i]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (s0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }
  return [...h].map(word => word.toString(16).padStart(8, '0')).join('');
}

/** SHA-256 of the canonical shape text, lower-case hex. */
export async function artifactShapeKey(text) {
  return sha256Hex(artifactShape(text));
}

/**
 * The latency the alignment delays add, and what to tell the user about it.
 *
 * Per-output delays are relative to each other, but the transport has to carry
 * the largest of them: the system's output is not complete until its most
 * delayed channel has been produced. So the cost is the maximum, not the sum
 * and not the average, and it is paid as soon as any delay is non-zero.
 */
export function delayLatency(config, rate = 48000) {
  const samples = Math.max(0, ...config.outputs.map(
    output => Math.round(output.delayMs / 1000 * rate)));
  const perMs = rate / 1000;
  return {
    samples,
    ms: Number((samples / perMs).toFixed(3)),
    text: samples === 0 ? null
      : `Alignment delay adds ${(samples / perMs).toFixed(2)} ms of latency to every `
        + 'output, not just the delayed ones: the largest delay you have set is '
        + 'what the transport has to carry. Set it to zero everywhere to get '
        + 'that back.',
  };
}
