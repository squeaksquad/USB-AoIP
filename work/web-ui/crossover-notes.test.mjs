import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig } from './model.mjs';
import { createHeadphoneBus } from './buses.mjs';
import { activeCrossovers, polarityNote, polarityWarningText } from './crossover-notes.mjs';

const kinds = config => activeCrossovers(config).map(c => `${c.kind}:${c.input}`);

test('the default preset applies a high-pass per main and a low-pass per sending input', () => {
  const config = createConfig();
  const list = activeCrossovers(config);
  assert.equal(list.filter(c => c.kind === 'highpass').length, 11);
  assert.equal(list.filter(c => c.kind === 'lowpass').length, 12);
  // Inputs 13-16 neither feed a speaker nor send bass.
  assert.ok(![12, 13, 14, 15].some(i => kinds(config).includes(`highpass:${i}`)));
});

test('the LFE branch carries the LFE low-pass, not its input row', () => {
  const config = createConfig();
  config.lfe.lowpassHz = 120;
  config.lfe.slope = 48;
  config.inputs[config.lfe.input].lowpassHz = 60;
  config.inputs[config.lfe.input].slope = 12;
  const lfe = activeCrossovers(config).find(c => c.kind === 'lowpass' && c.input === config.lfe.input);
  assert.equal(lfe.hz, 120);
  assert.equal(lfe.slope, 48);
  assert.equal(lfe.lfe, true);
  // The input row's own 12 dB/oct is not in play, so nothing is flagged.
  assert.equal(polarityNote(config), null);
});

test('bass redirection off leaves only the LFE low-pass', () => {
  const config = createConfig();
  config.bassEnabled = false;
  const list = activeCrossovers(config);
  assert.equal(list.length, 1);
  assert.equal(list[0].kind, 'lowpass');
  assert.equal(list[0].input, config.lfe.input);
});

test('an input with its crossover switched off gets no high-pass but keeps its low-pass', () => {
  const config = createConfig();
  config.inputs[0].crossover = false;
  assert.ok(!kinds(config).includes('highpass:0'));
  assert.ok(kinds(config).includes('lowpass:0'));
});

test('a headphone output does not create a crossover', () => {
  let config = createConfig();
  config.outputs[14].role = 'unused';
  config.outputs[15].role = 'unused';
  config = createHeadphoneBus(config, 'headphones', [14, 15]);
  const bus = config.buses.find(b => b.id === 'headphones');
  bus.inputMode = 'pair';
  bus.inputPair = [13, 14];
  // Input 14 is only a headphone source, so it gets no high-pass.
  assert.ok(!kinds(config).includes('highpass:13'));
});

test('no note when every active crossover is 24 or 48 dB/oct', () => {
  const config = createConfig();
  assert.equal(polarityNote(config), null);
  config.inputs.forEach(input => { input.slope = 48; });
  assert.equal(polarityNote(config), null);
  assert.equal(polarityWarningText(config), null);
});

test('a 12 dB/oct crossover produces a note naming the affected inputs', () => {
  const config = createConfig();
  config.inputs[0].slope = 12;
  const note = polarityNote(config);
  assert.deepEqual(note.inputs, [0]);
  assert.deepEqual(note.labels, ['L']);
  assert.equal(note.highpassCount, 1);
  assert.equal(note.lowpassCount, 1);
  assert.match(note.detail, /Nothing has been inverted for you/);
  assert.match(polarityWarningText(config), /Affected inputs: 1 L\./);
});

test('a 12 dB/oct slope on an inactive crossover is not flagged', () => {
  const config = createConfig();
  // Input 13 drives nothing in this layout.
  config.inputs[12].slope = 12;
  assert.equal(polarityNote(config), null);
  // Switching redirection off retires every main high-pass with it.
  config.inputs[0].slope = 12;
  config.bassEnabled = false;
  assert.equal(polarityNote(config), null, 'input 1 no longer has an active crossover');
});

test('a 12 dB/oct LFE low-pass is flagged on the LFE slope alone', () => {
  const config = createConfig();
  config.inputs.forEach(input => { input.slope = 24; });
  config.lfe.slope = 12;
  const note = polarityNote(config);
  assert.deepEqual(note.inputs, [config.lfe.input]);
  assert.equal(note.highpassCount, 0);
  assert.equal(note.lowpassCount, 1);
});

test('the note reports and never edits the preset', () => {
  const config = createConfig();
  config.inputs[0].slope = 12;
  const before = JSON.stringify(config);
  polarityNote(config);
  polarityWarningText(config);
  activeCrossovers(config);
  assert.equal(JSON.stringify(config), before);
  assert.ok(config.outputs.every(output => output.invert === false),
            'no polarity was flipped');
});
