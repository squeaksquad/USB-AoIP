import test from 'node:test';
import assert from 'node:assert/strict';
import {createConfig,validateConfig,bandResponse} from './model.mjs';
import {LAYOUTS,currentLayout,applyLayout,copyChannel,pasteChannel,parseRew} from './workflows.mjs';

test('all formats fit 16 outputs and round-trip their topology',()=>{
  for(const layout of LAYOUTS){const c=applyLayout(createConfig(),layout.id);validateConfig(c);assert.equal(c.outputs.length,16);assert.equal(c.outputs.filter(o=>o.role==='sub').length,layout.subs);assert.equal(currentLayout(c),layout.id);}
  assert.equal(currentLayout(createConfig()),'7.2.4');assert.throws(()=>applyLayout(createConfig(),'20.4'));
});
test('stereo bypasses redirection; 2.2 splits sides and sends LFE to both',()=>{
  const original=createConfig();original.outputs[0].bands[0].gainDb=6;
  const stereo=applyLayout(original,'stereo');assert.equal(stereo.bassEnabled,false);assert.ok(stereo.sends.flat().every(v=>v===null));assert.equal(stereo.outputs[0].bands[0].gainDb,0);assert.equal(original.outputs[0].bands[0].gainDb,6);
  const c=applyLayout(original,'2.2');assert.equal(c.sends[0][2],0);assert.equal(c.sends[0][3],null);assert.equal(c.sends[1][3],0);assert.equal(c.sends[2][2],null);assert.equal(c.sends[c.lfe.input][2],-6);assert.equal(c.sends[c.lfe.input][3],-6);
  assert.deepEqual(c.inputs,original.inputs);
});
test('channel copy is a snapshot; paste preserves destination identity and routing',()=>{
  const c=createConfig();c.outputs[0].delayMs=8;c.outputs[0].gainDb=-3;c.outputs[0].mute=true;c.outputs[0].bands[2].gainDb=-7;
  const clipboard=copyChannel(c.outputs[0]);c.outputs[0].bands[2].gainDb=1;
  const pasted=pasteChannel(c,11,clipboard);assert.equal(pasted.outputs[11].label,'Sub L');assert.equal(pasted.outputs[11].role,'sub');assert.equal(pasted.outputs[11].delayMs,8);assert.equal(pasted.outputs[11].mute,true);assert.equal(pasted.outputs[11].bands[2].gainDb,-7);assert.deepEqual(pasted.sends,c.sends);
  const eq=pasteChannel(c,12,clipboard,'eq');assert.equal(eq.outputs[12].gainDb,0);assert.equal(eq.outputs[12].delayMs,0);assert.equal(eq.outputs[12].mute,false);assert.equal(eq.outputs[12].bands[2].gainDb,-7);
});
test('REW export supports decimal precision, Q shelves, and off/None placeholders',()=>{
  const imported=parseRew('Filter Settings file\r\nEqualiser: Generic\r\nFilter 1: ON PK Fc 83.25 Hz Gain -3.4 dB Q 2.345\r\nFilter 2: ON LSQ Fc 120 Hz Gain 2 dB Q 0.707\r\nFilter 3: ON HSQ Fc 8000 Hz Gain -1.5 dB Q 0.71\r\nFilter 4: OFF PK Fc 200 Hz Gain -2 dB Q 1\r\nFilter 20: ON None');
  assert.equal(imported.count,3);assert.equal(imported.skipped,2);assert.equal(imported.bands.length,16);assert.equal(imported.bands[0].frequency,83.25);assert.equal(imported.bands[0].q,2.345);assert.equal(imported.bands[1].type,'lowShelf');assert.ok(imported.bands.slice(3).every(b=>!b.enabled));
  assert.ok(Math.abs(bandResponse(imported.bands[0],83.25)+3.4)<1e-7);
  assert.equal(parseRew('Filter 1: ON PK Fc 83,9 Hz Gain -1,6 dB Q 10,00').bands[0].frequency,83.9);
});
test('REW import fails rather than dropping active filters or changing values',()=>{
  const row='Filter 1: ON PK Fc 80 Hz Gain -3 dB Q 2';
  for(const text of ['not filters',row+'\n'+row,row.replace('PK','HP'),row.replace('Q 2','Q 0'),row.replace('Q 2',''),row.replace('PK','LS').replace(' Q 2',''),row.replace('80 Hz','8 Hz'),row.replace('-3 dB','-99 dB'),Array.from({length:17},(_,i)=>row.replace('Filter 1:',`Filter ${i+1}:`)).join('\n')])assert.throws(()=>parseRew(text));
  assert.throws(()=>parseRew('Equaliser: Behringer FBQ2496\n'+row));
  assert.throws(()=>parseRew(row+'\nFilter two: ON HP Fc 500 Hz Q 1'));
  assert.equal(parseRew('Equalizer: CamillaDSP\n'+row).count,1);
});
