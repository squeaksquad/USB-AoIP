import test from 'node:test';
import assert from 'node:assert/strict';
import {createConfig,validateConfig,parsePreset,bandResponse} from './model.mjs';
import {LAYOUTS,currentLayout,applyLayout,swapOutputs,applyCrossover,copyChannel,pasteChannel,parseRew,dragEqBand,SERVICE_COMMANDS,journalCommand} from './workflows.mjs';

test('EQ drag uses logarithmic frequency and independent gain/Q without mutating its source',()=>{
  const band={enabled:true,type:'bell',frequency:1000,gainDb:-3,q:1.25},original=structuredClone(band);
  const moved=dragEqBand(band,Math.log10(2)/3,-1/8);
  assert.equal(moved.frequency,2000);assert.equal(moved.gainDb,0);assert.equal(moved.q,1.25);
  const q=dragEqBand(band,.4,-1/8,true);
  assert.equal(q.q,.625);assert.equal(q.frequency,1000);assert.equal(q.gainDb,-3);
  assert.equal(dragEqBand(band,0,1/8,true).q,2.5);
  assert.deepEqual(band,original);
  // The modifier may be engaged mid-gesture without resetting frequency/gain.
  const toggled=dragEqBand(moved,.2,-1/8,true);
  assert.equal(toggled.frequency,moved.frequency);assert.equal(toggled.gainDb,moved.gainDb);
  const resumed=dragEqBand(toggled,0,1/8);
  assert.equal(resumed.q,toggled.q);assert.equal(resumed.gainDb,-3);
});
test('EQ drag clamps extreme movements, preserves untouched precision and stays preset compatible',()=>{
  const config=createConfig(),band={...config.outputs[0].bands[0],frequency:101.12345,gainDb:-1.23456,q:1.234567};
  assert.deepEqual(dragEqBand(band,0,0),band);
  assert.deepEqual(dragEqBand(band,1,0,true),band);
  for(const type of ['bell','lowShelf','highShelf'])for(const sign of [-1,1]){
    const moved=dragEqBand({...band,type},sign*100,sign*100);
    assert.equal(moved.frequency,sign<0?20:20000);assert.equal(moved.gainDb,sign<0?18:-18);
    const q=dragEqBand(moved,100,sign*100,true);assert.equal(q.q,sign<0?.1:18);
    config.outputs[0].bands[0]=q;assert.deepEqual(parsePreset(JSON.stringify(config)),config);
  }
  assert.throws(()=>dragEqBand(band,NaN,0));assert.throws(()=>dragEqBand(band,0,Infinity));
});
test('maintenance commands restrict logs to known units and stop AES67 before restarting USB',()=>{
  assert.equal(journalCommand('aes67'),'sudo journalctl -u usb16x16-aes67.service -n 200 --no-pager -o short-iso');
  assert.equal(journalCommand('usb'),'sudo journalctl -u usb-16x16.service -n 200 --no-pager -o short-iso');
  assert.ok(journalCommand('all').includes('-u usb16x16-aes67.service -u usb-16x16.service'));
  for(const key of ['bad','__proto__','constructor','usb; reboot'])assert.throws(()=>journalCommand(key));
  const restart=SERVICE_COMMANDS.find(c=>c.id==='usb-restart').command.split(' && ');
  assert.deepEqual(restart,['sudo systemctl stop usb16x16-aes67','sudo systemctl restart usb-16x16.service','sudo systemctl start usb16x16-aes67']);
});

test('all formats fit 16 outputs and round-trip their topology',()=>{
  for(const layout of LAYOUTS){const c=applyLayout(createConfig(),layout.id);validateConfig(c);assert.equal(c.outputs.length,16);assert.equal(c.outputs.filter(o=>o.role==='sub').length,layout.subs);assert.equal(currentLayout(c),layout.id);}
  assert.equal(currentLayout(createConfig()),'7.2.4');assert.throws(()=>applyLayout(createConfig(),'20.4'));
});
test('surround defaults reserve output 4 for LFE and 7.1.4 follows Dolby order',()=>{
  for(const layout of LAYOUTS.filter(v=>v.bed>=5)) {
    const c=applyLayout(createConfig(),layout.id);
    assert.equal(c.outputs[3].role,'sub');assert.equal(c.outputs[3].label,'LFE');
    assert.notEqual(c.sends[c.lfe.input][3],null);
  }
  const c=applyLayout(createConfig(),'7.1.4');
  assert.deepEqual(c.outputs.slice(0,12).map(o=>o.label),['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Ltf','Rtf','Ltr','Rtr']);
  assert.deepEqual(c.outputs.slice(0,12).map(o=>o.source),Array.from({length:12},(_,i)=>i));
  assert.ok(c.outputs.slice(12).every(o=>o.role==='unused'));
  assert.ok(c.sends.every(row=>row[3]===0||row.every(v=>v===null)));
  assert.equal(createConfig().outputs[3].label,'LFE');
  assert.equal(createConfig().outputs[12].label,'Sub 2');
  assert.deepEqual(applyLayout(createConfig(),'7.2.4'),createConfig());
});
test('output swaps preserve full processing and bass routes, and reverse without loss',()=>{
  const c=createConfig();c.outputs[3].delayMs=7;c.outputs[3].invert=true;c.outputs[3].bands[2].gainDb=-4;
  const snapshot=structuredClone(c), moved=swapOutputs(c,3,0);
  assert.deepEqual(moved.outputs[0],c.outputs[3]);assert.deepEqual(moved.outputs[3],c.outputs[0]);
  c.sends.forEach((row,i)=>{
    assert.equal(moved.sends[i][0],row[3]);assert.equal(moved.sends[i][3],row[0]);
    row.forEach((gain,j)=>{if(j!==0&&j!==3)assert.equal(moved.sends[i][j],gain);});
  });
  assert.deepEqual(c,snapshot);assert.deepEqual(swapOutputs(moved,0,3),c);
  assert.equal(currentLayout(moved),'custom');
  assert.deepEqual(parsePreset(JSON.stringify(moved)),moved);
});
test('routing to a spare and individual source overrides survive preset import',()=>{
  const c=applyLayout(createConfig(),'7.1.4'), moved=swapOutputs(c,3,15);
  assert.equal(moved.outputs[15].label,'LFE');assert.equal(moved.outputs[3].role,'unused');
  assert.equal(moved.sends[3][15],0);assert.ok(moved.sends.every(row=>row[3]===null));
  moved.outputs[0].source=1;
  assert.deepEqual(parsePreset(JSON.stringify(moved)),moved);
  assert.deepEqual(swapOutputs(c,3,3),c);
  for(const i of [-1,16,.5,NaN,'4']) assert.throws(()=>swapOutputs(c,3,i));
});
test('stereo bypasses redirection; 2.2 splits sides and sends LFE to both',()=>{
  const original=createConfig();original.outputs[0].bands[0].gainDb=6;
  const stereo=applyLayout(original,'stereo');assert.equal(stereo.bassEnabled,false);assert.ok(stereo.sends.flat().every(v=>v===null));assert.equal(stereo.outputs[0].bands[0].gainDb,0);assert.equal(original.outputs[0].bands[0].gainDb,6);
  const c=applyLayout(original,'2.2');assert.equal(c.sends[0][2],0);assert.equal(c.sends[0][3],null);assert.equal(c.sends[1][3],0);assert.equal(c.sends[2][2],null);assert.equal(c.sends[c.lfe.input][2],-6);assert.equal(c.sends[c.lfe.input][3],-6);
  assert.deepEqual(c.inputs,original.inputs);
});
test('9.1.6 uses Dolby order with all bass and LFE routed to output 4',()=>{
  const original=createConfig(), c=applyLayout(original,'9.1.6');
  assert.deepEqual(c.outputs.map(o=>o.label),['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Lw','Rw','Ltf','Rtf','Ltm','Rtm','Ltr','Rtr']);
  assert.deepEqual(c.outputs.filter(o=>o.role==='speaker').map(o=>o.source),[0,1,2,4,5,6,7,12,13,8,9,14,15,10,11]);
  assert.equal(c.outputs[3].role,'sub');
  assert.ok(c.sends.every(row=>row[3]===0 && row.every((v,i)=>i===3||v===null)));
  assert.deepEqual(c.inputs,original.inputs);
  assert.deepEqual(parsePreset(JSON.stringify(c)),c);
  assert.equal(currentLayout(parsePreset(JSON.stringify(c))),'9.1.6');
});
test('9.2.4 routes wide speakers to stereo subs and retains one spare output',()=>{
  const c=applyLayout(createConfig(),'9.2.4');
  assert.deepEqual(c.outputs.filter(o=>o.role==='speaker').map(o=>o.source),[0,1,2,4,5,6,7,12,13,8,9,10,11]);
  assert.equal(c.outputs[3].label,'LFE');assert.equal(c.outputs[3].role,'sub');
  assert.deepEqual(c.outputs.slice(14).map(o=>[o.label,o.role]),[['Sub 2','sub'],['Spare 16','unused']]);
  for(const source of [0,4,6,8,10,12]) assert.deepEqual([c.sends[source][3],c.sends[source][14],c.sends[source][15]],[0,null,null]);
  for(const source of [1,5,7,9,11,13]) assert.deepEqual([c.sends[source][3],c.sends[source][14],c.sends[source][15]],[null,0,null]);
  for(const source of [2,3]) assert.deepEqual([c.sends[source][3],c.sends[source][14],c.sends[source][15]],[-6,-6,null]);
  assert.ok(c.sends.slice(14).flat().every(v=>v===null));
  assert.equal(currentLayout(parsePreset(JSON.stringify(c))),'9.2.4');
});
test('channel copy is a snapshot; paste preserves destination identity and routing',()=>{
  const c=createConfig();c.outputs[0].delayMs=8;c.outputs[0].gainDb=-3;c.outputs[0].mute=true;c.outputs[0].bands[2].gainDb=-7;
  const clipboard=copyChannel(c.outputs[0]);c.outputs[0].bands[2].gainDb=1;
  const pasted=pasteChannel(c,3,clipboard);assert.equal(pasted.outputs[3].label,'LFE');assert.equal(pasted.outputs[3].role,'sub');assert.equal(pasted.outputs[3].delayMs,8);assert.equal(pasted.outputs[3].mute,true);assert.equal(pasted.outputs[3].bands[2].gainDb,-7);assert.deepEqual(pasted.sends,c.sends);
  const eq=pasteChannel(c,12,clipboard,'eq');assert.equal(eq.outputs[12].gainDb,0);assert.equal(eq.outputs[12].delayMs,0);assert.equal(eq.outputs[12].mute,false);assert.equal(eq.outputs[12].bands[2].gainDb,-7);
});
test('global crossover sets HP and LP while preserving LFE, slopes, bypass and routing',()=>{
  const original=applyLayout(createConfig(),'9.1.6');
  original.inputs[0].slope=48;original.inputs[1].crossover=false;
  original.inputs[2].highpassHz=60;original.inputs[2].lowpassHz=90;
  const snapshot=structuredClone(original);
  const targets=original.inputs.map((_,i)=>i).filter(i=>i!==original.lfe.input);
  const c=applyCrossover(original,targets,100);
  for(const i of targets) assert.deepEqual(c.inputs[i],{...original.inputs[i],highpassHz:100,lowpassHz:100});
  assert.deepEqual(c.inputs[c.lfe.input],original.inputs[original.lfe.input]);
  assert.deepEqual({...c,inputs:original.inputs},original);
  assert.deepEqual(original,snapshot);
  assert.deepEqual(parsePreset(JSON.stringify(c)),c);
});
test('group crossover changes only selected inputs and remains individually editable',()=>{
  const original=createConfig(), c=applyCrossover(original,[0,1],90);
  assert.equal(c.inputs[0].highpassHz,90);assert.equal(c.inputs[1].lowpassHz,90);
  assert.deepEqual(c.inputs.slice(2),original.inputs.slice(2));
  c.inputs[0].highpassHz=70;c.inputs[0].lowpassHz=75;validateConfig(c);
  assert.equal(c.inputs[1].highpassHz,90);assert.equal(c.inputs[1].lowpassHz,90);
  c.lfe.input=1;
  assert.throws(()=>applyCrossover(c,[0,1],80));
  assert.equal(applyCrossover(c,[3],110).inputs[3].highpassHz,110);
});
test('invalid bulk crossover edits fail without changing the original',()=>{
  const c=createConfig(), snapshot=structuredClone(c);
  for(const frequency of [0,19,251,NaN,Infinity,'80']) assert.throws(()=>applyCrossover(c,[0,1],frequency));
  for(const indices of [[],null,[0,16],[0,-1],[0,.5],[0,3]]) assert.throws(()=>applyCrossover(c,indices,80));
  assert.deepEqual(c,snapshot);
  for(const frequency of [20,250]) assert.equal(applyCrossover(c,[0],frequency).inputs[0].lowpassHz,frequency);
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
