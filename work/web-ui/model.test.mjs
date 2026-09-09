import test from 'node:test';
import assert from 'node:assert/strict';
import { createConfig, validateConfig, parsePreset, setOutputRole, bandResponse, eqResponse, subSumBoundDb } from './model.mjs';

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
