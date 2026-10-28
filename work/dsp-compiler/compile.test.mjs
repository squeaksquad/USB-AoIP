import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, CHANNELS } from '../web-ui/model.mjs';
import { createHeadphoneBus, setBusGainMute } from '../web-ui/buses.mjs';
import { compile, planChannels, fileDevices, alsaDevices, SAMPLE_RATE } from './compile.mjs';
import { toYaml } from './yaml.mjs';

const devices = fileDevices('in.raw', 'out.raw');
const build = preset => compile(preset, devices);
const mixer = (result, name) => result.config.mixers[name];
const destOf = (result, name, dest) => mixer(result, name).mapping.find(m => m.dest === dest);
// Filter steps before the assign mixer index internal channels; steps after it
// index physical outputs. The two spaces overlap numerically, so a helper that
// ignores position would match the wrong side.
const splitAt = result => result.config.pipeline.findIndex(s => s.type === 'Mixer' && s.name === 'assign');
const branchNames = (result, channel) => result.config.pipeline
  .slice(0, splitAt(result))
  .filter(s => s.type === 'Filter' && s.channels.includes(channel))
  .flatMap(s => s.names);
const namesFor = (result, output) => result.config.pipeline
  .slice(splitAt(result) + 1)
  .filter(s => s.type === 'Filter' && s.channels.includes(output))
  .flatMap(s => s.names);

test('the default preset compiles to a well-formed pipeline', () => {
  const result = build(createConfig());
  const {pipeline} = result.config;
  assert.equal(pipeline[0].type, 'Mixer');
  assert.equal(pipeline[0].name, 'expand');
  const assignAt = pipeline.findIndex(s => s.type === 'Mixer' && s.name === 'assign');
  assert.ok(assignAt > 0, 'assign mixer follows expand');
  // Every branch filter runs before the assign mixer; every output filter after.
  pipeline.slice(1, assignAt).forEach(step => {
    assert.ok(step.channels[0] < result.plan.channels.length, 'branch step is in internal space');
  });
  pipeline.slice(assignAt + 1).forEach(step => {
    assert.ok(step.channels[0] < CHANNELS, 'output step is in output space');
  });
  assert.equal(mixer(result, 'expand').channels.in, CHANNELS);
  assert.equal(mixer(result, 'expand').channels.out, result.plan.channels.length);
  assert.equal(mixer(result, 'assign').channels.out, CHANNELS);
});

test('only branches something consumes are allocated', () => {
  const plan = planChannels(createConfig());
  // 7.2.4: 11 speaker outputs and 12 inputs carrying bass, no headphones.
  assert.equal(plan.channels.filter(c => c.kind === 'main').length, 11);
  assert.equal(plan.channels.filter(c => c.kind === 'bass').length, 12);
  assert.equal(plan.channels.filter(c => c.kind === 'phones').length, 0);
  // Inputs 13-16 drive nothing in this layout and cost no channel.
  assert.ok(![12, 13, 14, 15].some(i => plan.mainOf.has(i) || plan.bassOf.has(i)));
});

test('two outputs sharing a source share one main branch', () => {
  const preset = createConfig();
  preset.outputs[1].source = 0;                 // R now also fed from input 1
  const plan = planChannels(preset);
  assert.equal(plan.channels.filter(c => c.kind === 'main').length, 10);
  const result = build(preset);
  assert.equal(destOf(result, 'assign', 0).sources[0].channel,
               destOf(result, 'assign', 1).sources[0].channel);
});

test('headroom is applied exactly once, in the expand mixer', () => {
  const preset = createConfig();
  const result = build(preset);
  for (const entry of mixer(result, 'expand').mapping) {
    for (const source of entry.sources) {
      assert.ok(source.gain <= preset.headroomDb + 1e-9,
                'every expand source carries the headroom trim');
    }
  }
  // A speaker output's own path adds nothing beyond bus and output gain.
  assert.deepEqual(destOf(result, 'assign', 0).sources.map(s => s.gain), [0]);
});

test('the LFE trim is applied once, on the LFE bass branch only', () => {
  const preset = createConfig();
  preset.lfe.trimDb = -4;
  const result = build(preset);
  const plan = result.plan;
  const lfeChannel = plan.bassOf.get(preset.lfe.input);
  const entry = mixer(result, 'expand').mapping.find(m => m.dest === lfeChannel);
  assert.equal(entry.sources[0].gain, preset.headroomDb - 4);
  // Another bass branch keeps plain headroom.
  const other = mixer(result, 'expand').mapping.find(m => m.dest === plan.bassOf.get(0));
  assert.equal(other.sources[0].gain, preset.headroomDb);
});

test('sub sends become mixer sources with their own gains', () => {
  const preset = createConfig();
  const result = build(preset);
  const lfeOut = destOf(result, 'assign', 3);
  const gains = lfeOut.sources.map(s => s.gain).sort((a, b) => a - b);
  // Inputs 1,5,7,9,11 at 0 dB; inputs 3 and 4 at -6 dB.
  assert.deepEqual(gains, [-6, -6, 0, 0, 0, 0, 0]);
  assert.ok(lfeOut.sources.every(s => result.plan.channels[s.channel].kind === 'bass'),
            'a sub is fed only by bass branches');
});

test('crossovers are separate filters and never consume a PEQ band', () => {
  const preset = createConfig();
  preset.outputs[0].bands[0] = {enabled: true, type: 'bell', frequency: 100, gainDb: 4, q: 2};
  const result = build(preset);
  const mainChannel = result.plan.mainOf.get(0);
  assert.deepEqual(branchNames(result, mainChannel), ['hp_in1']);
  assert.equal(result.config.filters.hp_in1.type, 'BiquadCombo');
  // The band lands on the physical output, downstream of the assign mixer.
  assert.ok(namesFor(result, 0).includes('eq_out1_b1'));
  assert.equal(result.config.filters.eq_out1_b1.parameters.gain, 4);
  assert.equal(result.report.biquadCount, 1);
});

test('slope maps to Linkwitz-Riley order and 12 dB/oct is flagged', () => {
  const preset = createConfig();
  preset.inputs.forEach(input => { input.slope = 48; });
  preset.lfe.slope = 48;
  let result = build(preset);
  assert.equal(result.config.filters.hp_in1.parameters.order, 8);
  assert.equal(result.config.filters.lp_in1.parameters.order, 8);
  assert.ok(!result.report.warnings.some(w => w.includes('180 degrees')));

  preset.inputs[0].slope = 12;
  result = build(preset);
  assert.equal(result.config.filters.hp_in1.parameters.order, 2);
  const warning = result.report.warnings.find(w => w.includes('180 degrees'));
  assert.ok(warning, 'a 12 dB/oct crossover is called out');
  assert.match(warning, /Nothing has been inverted for you/);
  assert.match(warning, /Affected inputs: 1 L/);
  assert.equal(result.config.filters.gain_out1, undefined, 'and nothing was inverted');
});

test('flat and disabled bands emit no biquad', () => {
  const preset = createConfig();
  const result = build(preset);
  assert.equal(result.report.biquadCount, 0, 'the default preset is flat everywhere');
  preset.outputs[0].bands[0].gainDb = 3;
  preset.outputs[0].bands[1] = {enabled: false, type: 'bell', frequency: 200, gainDb: 9, q: 1};
  const shaped = build(preset);
  assert.equal(shaped.report.biquadCount, 1, 'a disabled band stays out even at 9 dB');
});

test('shelf types map to CamillaDSP names', () => {
  const preset = createConfig();
  preset.outputs[0].bands[0] = {enabled: true, type: 'lowShelf', frequency: 80, gainDb: -3, q: 0.7};
  preset.outputs[0].bands[1] = {enabled: true, type: 'highShelf', frequency: 8000, gainDb: 2, q: 0.7};
  const result = build(preset);
  assert.equal(result.config.filters.eq_out1_b1.parameters.type, 'Lowshelf');
  assert.equal(result.config.filters.eq_out1_b2.parameters.type, 'Highshelf');
});

test('global EQ bypass emits no band but keeps everything else', () => {
  const preset = createConfig();
  preset.outputs[0].bands[0].gainDb = 6;
  preset.eqBypass = true;
  const result = build(preset);
  assert.equal(result.report.biquadCount, 0);
  assert.ok(result.report.warnings.some(w => w.includes('Global EQ bypass')));
  assert.ok(result.report.crossoverCount > 0, 'crossovers are unaffected');
});

test('alignment delay is whole samples at 48 kHz', () => {
  const preset = createConfig();
  preset.outputs[0].delayMs = 10;
  preset.outputs[1].delayMs = 0;
  preset.outputs[2].delayMs = 2.5;
  const result = build(preset);
  assert.equal(result.config.filters.delay_out1.parameters.delay, 480);
  assert.equal(result.config.filters.delay_out1.parameters.unit, 'samples');
  assert.equal(result.config.filters.delay_out1.parameters.subsample, false);
  assert.equal(result.config.filters.delay_out3.parameters.delay, 120);
  assert.ok(!('delay_out2' in result.config.filters), 'zero delay emits no filter');
  assert.equal(Math.round(2.5 / 1000 * SAMPLE_RATE), 120);
});

test('gain, polarity and mute ride on one output filter', () => {
  const preset = createConfig();
  preset.outputs[0].gainDb = -3;
  preset.outputs[0].invert = true;
  preset.outputs[1].mute = true;
  const result = build(preset);
  assert.deepEqual(result.config.filters.gain_out1.parameters,
                   {gain: -3, inverted: true, mute: false, scale: 'dB'});
  assert.equal(result.config.filters.gain_out2.parameters.mute, true);
  assert.ok(!('gain_out3' in result.config.filters), 'an untouched output emits no gain filter');
  assert.ok(result.report.warnings.some(w => w.startsWith('Muted outputs: 2')));
});

test('an unused output is explicitly silent, not merely absent', () => {
  const result = build(createConfig());
  const spare = destOf(result, 'assign', 15);
  assert.ok(spare, 'the spare output appears in the mapping');
  assert.deepEqual(spare.sources, []);
  assert.equal(namesFor(result, 15).length, 0);
});

test('bus gain reaches the assign mixer and bus mute mutes the destination', () => {
  let preset = createConfig();
  preset = setBusGainMute(preset, 'speakers', -6, false);
  let result = build(preset);
  assert.equal(destOf(result, 'assign', 0).sources[0].gain, -6);
  assert.equal(destOf(result, 'assign', 3).sources[0].gain, -6, 'sub sends carry bus gain too');
  preset = setBusGainMute(preset, 'speakers', -6, true);
  result = build(preset);
  assert.equal(destOf(result, 'assign', 0).mute, true);
});

test('bass redirection off bypasses main high-passes and keeps only LFE in the subs', () => {
  const preset = createConfig();
  preset.bassEnabled = false;
  const result = build(preset);
  assert.equal(branchNames(result, result.plan.mainOf.get(0)).length, 0, 'no high-pass');
  assert.equal(result.plan.bassOf.size, 1, 'only the LFE branch survives');
  assert.ok(result.plan.bassOf.has(preset.lfe.input));
  const lfeOut = destOf(result, 'assign', 3);
  assert.equal(lfeOut.sources.length, 1);
  assert.equal(result.plan.channels[lfeOut.sources[0].channel].lfe, true);
  assert.ok(result.report.warnings.some(w => w.includes('Bass redirection is off')));
});

test('a full-range main keeps its bass send when its high-pass is off', () => {
  const preset = createConfig();
  preset.inputs[0].crossover = false;
  const result = build(preset);
  assert.equal(branchNames(result, result.plan.mainOf.get(0)).length, 0, 'input 1 runs full range');
  assert.ok(result.plan.bassOf.has(0), 'and still feeds the sub');
});

test('headphone ears take a full-range branch, pair mode', () => {
  let preset = createConfig();
  preset = createHeadphoneBus(preset, 'headphones', [14, 15]);
  const bus = preset.buses.find(b => b.id === 'headphones');
  bus.inputMode = 'pair';
  bus.inputPair = [0, 1];
  const result = build(preset);
  const left = result.plan.phonesOf.get('headphones:0');
  assert.equal(result.plan.channels[left].kind, 'phones');
  assert.equal(branchNames(result, left).length, 0, 'no crossover on a headphone branch');
  const entry = mixer(result, 'expand').mapping.find(m => m.dest === left);
  assert.deepEqual(entry.sources.map(s => s.channel), [0]);
  assert.equal(destOf(result, 'assign', 14).sources[0].channel, left);
});

test('headphone downmix becomes one mixer source per contributing input', () => {
  let preset = createConfig();
  preset = createHeadphoneBus(preset, 'headphones', [14, 15]);
  const bus = preset.buses.find(b => b.id === 'headphones');
  bus.inputMode = 'downmix';
  bus.downmixMatrix = Array.from({length: 16}, () => [null, null]);
  bus.downmixMatrix[0] = [0, null];
  bus.downmixMatrix[1] = [null, 0];
  bus.downmixMatrix[2] = [-3, -3];
  const result = build(preset);
  const left = result.plan.phonesOf.get('headphones:0');
  const entry = mixer(result, 'expand').mapping.find(m => m.dest === left);
  assert.deepEqual(entry.sources.map(s => [s.channel, s.gain]),
                   [[0, preset.headroomDb], [2, preset.headroomDb - 3]]);
});

test('worst case is a coherent sum and clipping is reported', () => {
  const preset = createConfig();
  let result = build(preset);
  // Five 0 dB sends and two -6 dB sends at -18 dB headroom.
  assert.equal(result.report.worstCaseDbfs[3], -2.43);
  assert.equal(result.report.worstCaseDbfs[0], -18, 'a speaker output is just the trim');
  assert.equal(result.report.worstCaseDbfs[15], null, 'a spare output has no level');
  assert.deepEqual(result.report.warnings, []);

  preset.headroomDb = 0;
  result = build(preset);
  assert.ok(result.report.worstCaseDbfs[3] > 0);
  const warning = result.report.warnings.find(w => w.startsWith('Output 4'));
  assert.ok(warning, 'the clipping output is named');
  assert.match(warning, /dBFS from coherent full-scale inputs/);
});

test('a muted output reports no worst-case level', () => {
  const preset = createConfig();
  preset.outputs[3].mute = true;
  assert.equal(build(preset).report.worstCaseDbfs[3], null);
});

test('direct mode refuses to compile', () => {
  const preset = createConfig();
  preset.mode = 'direct';
  assert.throws(() => build(preset), /Direct mode has no DSP path/);
});

test('an invalid preset is rejected by the shared validator', () => {
  const preset = createConfig();
  preset.outputs[0].delayMs = 11;
  assert.throws(() => build(preset), /Alignment delay/);
});

test('devices must be supplied; the compiler does not choose them', () => {
  assert.throws(() => compile(createConfig()), /Supply a devices section/);
  const alsa = alsaDevices('hw:0', 'hw:1');
  assert.equal(alsa.capture.type, 'Alsa');
  assert.equal(alsa.capture.device, 'hw:0');
  assert.equal(alsa.samplerate, SAMPLE_RATE);
});

test('a preset that routes nothing is rejected rather than emitted empty', () => {
  const preset = createConfig();
  preset.outputs.forEach((output, i) => { output.role = 'unused'; output.busId = null; });
  preset.buses = [{id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds: [],
                   layoutId: 'custom', gainDb: 0, mute: false}];
  preset.sends = Array.from({length: 16}, () => Array(16).fill(null));
  assert.throws(() => build(preset), /routes nothing/);
});

test('compiling is deterministic and does not mutate the preset', () => {
  const preset = createConfig();
  const before = JSON.stringify(preset);
  const first = toYaml(build(preset).config);
  const second = toYaml(build(preset).config);
  assert.equal(first, second);
  assert.equal(JSON.stringify(preset), before, 'the caller keeps its preset unchanged');
});

test('every mixer source names a channel that exists', () => {
  const preset = createConfig();
  const result = build(preset);
  const internal = result.plan.channels.length;
  for (const entry of mixer(result, 'expand').mapping) {
    assert.ok(entry.dest < internal);
    entry.sources.forEach(s => assert.ok(s.channel >= 0 && s.channel < CHANNELS));
  }
  for (const entry of mixer(result, 'assign').mapping) {
    assert.ok(entry.dest < CHANNELS);
    entry.sources.forEach(s => assert.ok(s.channel >= 0 && s.channel < internal));
  }
});

test('every pipeline filter name is defined', () => {
  const result = build(createConfig());
  const defined = new Set(Object.keys(result.config.filters));
  for (const step of result.config.pipeline) {
    if (step.type !== 'Filter') continue;
    step.names.forEach(name => assert.ok(defined.has(name), `${name} is defined`));
  }
});

test('the YAML emitter quotes strings YAML would otherwise coerce', () => {
  assert.match(toYaml({a: 'yes', b: 'no', c: 'null', d: 'on'}), /a: 'yes'/);
  assert.match(toYaml({a: 'plain'}), /a: plain\n/);
  assert.match(toYaml({a: "it's"}), /a: 'it''s'/);
  assert.throws(() => toYaml({a: Infinity}), /non-finite/);
});

test('the two channel spaces are separated by the assign mixer', () => {
  const result = build(createConfig());
  const at = splitAt(result);
  const internal = result.plan.channels.length;
  assert.ok(internal > CHANNELS, 'this preset really does use more internal channels');
  // Internal channel 15 is a bass branch; physical output 15 is a spare. Both
  // are written "channels: [15]" and are told apart only by pipeline position.
  assert.deepEqual(branchNames(result, 15), ['lp_in5']);
  assert.deepEqual(namesFor(result, 15), []);
  result.config.pipeline.slice(0, at).forEach(step => {
    if (step.type === 'Filter') assert.ok(step.channels.every(c => c < internal));
  });
  result.config.pipeline.slice(at + 1).forEach(step => {
    if (step.type === 'Filter') assert.ok(step.channels.every(c => c < CHANNELS));
  });
});

test('the LFE branch is scored on the LFE slope, not its input\'s', () => {
  const preset = createConfig();
  preset.inputs.forEach(input => { input.slope = 24; });
  preset.lfe.slope = 12;
  const result = build(preset);
  assert.equal(result.config.filters[`lp_in${preset.lfe.input + 1}`].parameters.order, 2);
  const warning = result.report.warnings.find(w => w.includes('180 degrees'));
  assert.ok(warning, 'a 12 dB/oct LFE low-pass is called out');
  assert.match(warning, new RegExp(`Affected inputs: ${preset.lfe.input + 1} `));
});

// ---------------------------------------------------------------- sample rate
// SAMPLE_RATE_DESIGN.md, step 3: a preset compiles at any Dante rate, and
// 48 kHz, the default, is unchanged.

import { DANTE_RATES, OFFERED_RATES } from './compile.mjs';

test('48 kHz is the default rate; 44.1 and 48 kHz are offered today', () => {
  assert.equal(SAMPLE_RATE, 48000);
  assert.deepEqual(OFFERED_RATES, [44100, 48000]);
  assert.ok(OFFERED_RATES.every(rate => DANTE_RATES.includes(rate)), 'every offered rate is a Dante rate');
  assert.equal(fileDevices('in.raw', 'out.raw').samplerate, 48000);
  const preset = createConfig();
  preset.outputs[0].delayMs = 2.5;
  assert.deepEqual(build(preset).config, compile(preset, fileDevices('in.raw', 'out.raw', 'S32_LE', 1024, 48000)).config,
    'naming 48 kHz compiles exactly what the default compiles');
  assert.equal(build(preset).report.rate, 48000);
});

test('the devices section carries the rate and delays are whole samples at it', () => {
  const preset = createConfig();
  preset.outputs[0].delayMs = 10;
  preset.outputs[2].delayMs = 2.5;
  for (const [rate, ten, twoAndAHalf] of [[44100, 441, 110], [96000, 960, 240], [192000, 1920, 480]]) {
    const result = compile(preset, fileDevices('in.raw', 'out.raw', 'S32_LE', 1024, rate));
    assert.equal(result.config.devices.samplerate, rate);
    assert.equal(result.report.rate, rate);
    assert.equal(result.config.filters.delay_out1.parameters.delay, ten, `10 ms at ${rate}`);
    assert.equal(result.config.filters.delay_out3.parameters.delay, twoAndAHalf, `2.5 ms at ${rate}`);
  }
  assert.equal(alsaDevices('hw:0', 'hw:1', 'S24_3_LE', 1024, 96000).samplerate, 96000);
});

test('a rate Dante does not have is refused', () => {
  for (const rate of [32000, 47999, 0, undefined]) {
    assert.throws(() => compile(createConfig(), {...devices, samplerate: rate}), /not a Dante rate/);
  }
});
