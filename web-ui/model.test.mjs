import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, validateConfig, parsePreset, readPreset, setOutputRole, bandResponse, eqResponse, subSumBoundDb, speakerSetBass } from './model.mjs';

test('example has 16 outputs including two independent subs, and 256 PEQ bands',()=>{
  const c = validateConfig(createConfig());
  assert.equal(c.outputs.length,16); assert.equal(c.outputs.flatMap(o=>o.bands).length,256);
  assert.equal(c.outputs.filter(o=>o.role==='sub').length,2);
  for(const i of [0,4,6,8,10]) { assert.equal(c.sends[i][3],0); assert.equal(c.sends[i][12],null); }
  for(const i of [1,5,7,9,11]) { assert.equal(c.sends[i][12],0); assert.equal(c.sends[i][3],null); }
  for(const i of [2,3]) { assert.equal(c.sends[i][3],-6); assert.equal(c.sends[i][12],-6); }
});
test('preset round-trip retains independent filters, sub trims, source and delay',()=>{
  const c=createConfig(); c.source='aoip'; c.outputs[3].delayMs=10; c.outputs[12].bands[4].gainDb=-7; c.lfe.trimDb=10;
  assert.deepEqual(parsePreset(JSON.stringify(c)),c);
  assert.equal(c.outputs[3].bands[4].gainDb,0);
});
test('rejects malformed or out-of-budget configurations before replacing a draft',()=>{
  const changes=[c=>c.outputs.push(c.outputs[0]),c=>c.outputs[0].delayMs=10.01,c=>c.outputs[0].delayMs=-1,c=>c.outputs[0].bands.pop(),c=>c.outputs[0].bands[0].q=0,c=>c.outputs[0].bands[0].frequency=24000,c=>c.sends[0][0]=0,c=>c.source='both',c=>c.outputs[0].source=.5,c=>c.lfe.input=16,c=>c.inputs[0].slope=18,c=>c.outputs[0].gainDb=Infinity,c=>c.outputs[0].mute='false',c=>c.sends[0][3]='0',c=>c.inputs[0].label=''];
  for(const change of changes){const c=createConfig();change(c);assert.throws(()=>validateConfig(c));}
  assert.throws(()=>parsePreset('{bad JSON'));assert.throws(()=>parsePreset(' '.repeat(200001)));
});
test('role reassignment clears sub sends and never restores an old hidden route',()=>{
  const c=createConfig();setOutputRole(c,3,'speaker');assert.ok(c.sends.every(row=>row[3]===null));
  setOutputRole(c,3,'sub');assert.ok(c.sends.every(row=>row[3]===null));validateConfig(c);
  for(let i=0;i<16;i++)setOutputRole(c,i,'sub');assert.equal(c.outputs.filter(o=>o.role==='sub').length,16);validateConfig(c);
});
test('PEQ magnitude agrees with analytic bell gain and inverse-filter cancellation',()=>{
  const b={enabled:true,type:'bell',frequency:1000,gainDb:9,q:2};
  assert.ok(Math.abs(bandResponse(b,1000)-9)<1e-8);
  for(const type of ['bell','lowShelf','highShelf'])for(const f of [20,100,1000,10000,20000]){
    const boost=bandResponse({...b,type},f),cut=bandResponse({...b,type,gainDb:-9},f);
    assert.ok(Number.isFinite(boost));assert.ok(Math.abs(boost+cut)<1e-7);
  }
  assert.ok(Math.abs(bandResponse({...b,type:'lowShelf'},.1)-9)<.001);
  assert.ok(Math.abs(bandResponse({...b,type:'highShelf'},23999)-9)<.001);
  const o=createConfig().outputs[0];for(const f of [20,1000,20000])assert.equal(eqResponse(o,f),0);
  o.bands[0]=b;o.eqEnabled=false;assert.equal(eqResponse(o,1000),0);
});
test('sub summing accounts for coherent gain, LFE trim, and bass bypass',()=>{
  const c=createConfig();c.sends.forEach(row=>row.fill(null));c.headroomDb=0;c.sends[0][3]=0;c.sends[1][3]=0;
  assert.ok(Math.abs(subSumBoundDb(c,3)-6.0206)<.0001);
  c.bassEnabled=false;assert.equal(subSumBoundDb(c,3),-Infinity);
  c.sends[c.lfe.input][3]=-6;c.lfe.trimDb=10;c.outputs[3].gainDb=-2;
  assert.ok(Math.abs(subSumBoundDb(c,3)-2)<1e-8);
});

// Model v3 (phase 3, step 6): the bus level and mute leave the model, an added speaker set chooses its subwoofer.
const v2Of = config => {
  const legacy = structuredClone(config); legacy.version = 2;
  legacy.buses.forEach(bus => { bus.gainDb = 0; bus.mute = false; delete bus.subShare; });
  return legacy;
};
test('v2 migrates to v3: a bus level onto its outputs, a muted bus switches its outputs off', () => {
  const legacy = v2Of(createConfig());
  legacy.buses[0].gainDb = -4.5; legacy.outputs[0].gainDb = 2; legacy.outputs[1].mute = true;
  const {config, notes} = readPreset(JSON.stringify(legacy));
  assert.equal(config.version, 3); assert.deepEqual(notes, []);
  assert.ok(!('gainDb' in config.buses[0]) && !('mute' in config.buses[0]));
  assert.equal(config.outputs[0].gainDb, -2.5); assert.equal(config.outputs[2].gainDb, -4.5);
  assert.equal(config.outputs[13].gainDb, 0, 'a spare output is in no bus and keeps its level');
  const muted = v2Of(createConfig()); muted.buses[0].mute = true;
  const off = parsePreset(JSON.stringify(muted));
  assert.ok(off.buses[0].outputIds.every(i => off.outputs[i].mute === true)); assert.equal(off.outputs[13].mute, false);
  // Unchanged settings migrate to exactly the v3 preset.
  assert.deepEqual(parsePreset(JSON.stringify(v2Of(createConfig()))), createConfig());
});
test('v2 migration clamps a level the outputs cannot carry and says so', () => {
  const legacy = v2Of(createConfig());
  legacy.buses[0].gainDb = 10; legacy.outputs[0].gainDb = 6; legacy.outputs[1].gainDb = -60;
  const {config, notes} = readPreset(JSON.stringify(legacy));
  assert.equal(config.outputs[0].gainDb, 12); assert.equal(config.outputs[1].gainDb, -50); assert.equal(config.outputs[2].gainDb, 10);
  assert.equal(notes.length, 1); assert.match(notes[0], /Speakers's saved level of 10 dB/); assert.match(notes[0], /L \(12 dB, not 16 dB\)/);
  const low = v2Of(createConfig()); low.buses[0].gainDb = -60; low.outputs[0].gainDb = -12;
  assert.match(readPreset(JSON.stringify(low)).notes[0], /L \(-60 dB, not -72 dB\)/);
});
test('v2 migration gives an added speaker set its subwoofer choice', () => {
  const extra = (mainsLayoutHasSub, ownSub) => {
    const legacy = v2Of(createConfig());
    if (!mainsLayoutHasSub) { for (const i of [3, 12]) { legacy.outputs[i].role = 'speaker'; legacy.outputs[i].source = i === 3 ? 3 : 12; } legacy.sends.forEach(row => row.fill(null)); }
    legacy.buses.push({id: 'near', kind: 'speakers', label: 'Near', outputIds: ownSub ? [13, 14] : [13], layoutId: 'custom', gainDb: -3, mute: false});
    legacy.outputs[13] = {...legacy.outputs[13], role: 'speaker', source: 0, busId: 'near'};
    if (ownSub) legacy.outputs[14] = {...legacy.outputs[14], role: 'sub', source: 3, busId: 'near'};
    return parsePreset(JSON.stringify(legacy));
  };
  assert.equal(extra(true, true).buses[1].subShare, 'own');
  assert.equal(extra(true, false).buses[1].subShare, 'main');
  assert.equal(extra(false, false).buses[1].subShare, 'none');
  assert.equal(extra(true, false).outputs[13].gainDb, -3);
  assert.ok(!('subShare' in extra(true, false).buses[0]));
});
test('v1 still migrates, through v2', () => {
  const legacy = createConfig(); legacy.version = 1; delete legacy.buses;
  const migrated = parsePreset(JSON.stringify(legacy));
  assert.equal(migrated.version, 3); assert.ok(!('gainDb' in migrated.buses[0])); validateConfig(migrated);
  assert.throws(() => validateConfig({...createConfig(), version: 2}), /version 3/);
});
test('v3 validation: the subwoofer choice is the added sets\', and must be possible', () => {
  const two = createConfig();
  for (const i of [13, 14]) Object.assign(two.outputs[i], {role: 'speaker', source: i - 13, busId: 'near'});
  two.buses.push({id: 'near', kind: 'speakers', label: 'Near', outputIds: [13, 14], layoutId: 'stereo', subShare: 'main'});
  validateConfig(two);
  for (const [change, why] of [
    [c => { delete c.buses[1].subShare; }, /choose whether it shares/],
    [c => { c.buses[1].subShare = 'shared'; }, /choose whether it shares/],
    [c => { c.buses[1].subShare = 'own'; }, /needs a subwoofer output/],
    [c => { c.outputs[14].role = 'sub'; }, /uses its own subwoofer/],
    [c => { c.buses[0].subShare = 'none'; }, /only an added speaker set/],
    [c => { for (const i of [3, 12]) c.outputs[i].role = 'speaker'; c.sends.forEach(row => row.fill(null)); }, /has no subwoofer to share/],
  ]) { const c = structuredClone(two); change(c); assert.throws(() => validateConfig(c), why); }
});
test('a sub shared by two speaker sets bounds the sum of both sets\' bass', () => {
  const c = createConfig(); c.sends.forEach(row => row.fill(null)); c.headroomDb = 0; c.sends[0][3] = 0;
  for (const i of [13, 14]) Object.assign(c.outputs[i], {role: 'speaker', source: i - 13, busId: 'near'});
  c.buses.push({id: 'near', kind: 'speakers', label: 'Near', outputIds: [13, 14], layoutId: 'stereo', subShare: 'main'});
  assert.ok(Math.abs(subSumBoundDb(c, 3) - 6.0206) < 1e-4, 'input 1 reaches the sub from the mains and from Near');
  c.buses[1].subShare = 'none'; assert.ok(Math.abs(subSumBoundDb(c, 3)) < 1e-9);
  const feeds = speakerSetBass({...c, buses: [c.buses[0], {...c.buses[1], subShare: 'main'}]});
  assert.deepEqual(feeds.map(f => [f.busId, f.share, f.subs, f.inputs]), [['speakers', 'first', [3, 12], null], ['near', 'main', [3, 12], [0, 1, 3]]]);
});
