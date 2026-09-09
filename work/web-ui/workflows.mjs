import { createConfig, validateConfig, FREQUENCIES } from './model.mjs';

export const EQ_RANGE_DB = 12;

// Deltas are fractions of the plotted frequency/gain area, independent of viewport size.
export function dragEqBand(band, dx, dy, adjustQ = false) {
  if (![dx,dy].every(Number.isFinite)) throw new Error('Invalid EQ movement');
  const clamp = (value,min,max) => Math.max(min,Math.min(max,value));
  const round = (value,places) => Number(value.toFixed(places));
  if (adjustQ) return {...band,q:dy===0?band.q:round(clamp(band.q * 2 ** (dy * 8),0.1,18),3)};
  return {...band,frequency:dx===0?band.frequency:round(clamp(band.frequency * 1000 ** dx,20,20000),1),gainDb:dy===0?band.gainDb:round(clamp(band.gainDb - dy * (EQ_RANGE_DB * 2),-18,18),2)};
}

export const SERVICE_COMMANDS = [
  {id:'aes67-status',label:'AES67 status',command:'usb16x16-aes67-supervisor status',detail:'Show transport, clock and bridge status.'},
  {id:'usb-status',label:'USB status',command:'systemctl --no-pager status usb-16x16.service',detail:'Show USB service state.'},
  {id:'aes67-restart',label:'Restart AES67',command:'sudo systemctl restart usb16x16-aes67',detail:'Interrupts network audio while the AES67 stack restarts.'},
  {id:'usb-restart',label:'Restart USB + AES67',command:'sudo systemctl stop usb16x16-aes67 && sudo systemctl restart usb-16x16.service && sudo systemctl start usb16x16-aes67',detail:'Disconnects USB audio, restarts the gadget, then starts AES67. Stops on failure.'}
];

export function journalCommand(service) {
  const units = {all:['usb16x16-aes67.service','usb-16x16.service'],aes67:['usb16x16-aes67.service'],usb:['usb-16x16.service']};
  if (!Object.hasOwn(units,service)) throw new Error('Choose a known log service');
  return `sudo journalctl ${units[service].map(unit=>`-u ${unit}`).join(' ')} -n 200 --no-pager -o short-iso`;
}

const beds = {2:[0,1],5:[0,1,2,4,5],7:[0,1,2,4,5,6,7],9:[0,1,2,4,5,6,7,12,13]};
const heights = {0:[],2:[8,9],4:[8,9,10,11],6:[8,9,14,15,10,11]};
const names = ['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Ltf','Rtf','Ltr','Rtr','Lw','Rw','Ltm','Rtm'];
export const LAYOUTS = [
  ['stereo',2,0,0],['2.1',2,1,0],['2.2',2,2,0],['5.1',5,1,0],['5.2',5,2,0],
  ['5.1.2',5,1,2],['5.1.4',5,1,4],['5.2.4',5,2,4],
  ['7.1',7,1,0],['7.2',7,2,0],['7.1.2',7,1,2],['7.1.4',7,1,4],['7.2.4',7,2,4],['9.1.4',9,1,4],['9.1.6',9,1,6],['9.2.4',9,2,4]
].map(([id,bed,subs,height])=>{
  const sources=[...beds[bed],...heights[height]], routing=[...sources];
  // Dolby surround order: L, R, C, LFE, surrounds, wides, heights.
  // A second physical sub follows the standard single-LFE channel path.
  if(subs) routing.splice(Math.min(3,bed),0,null);
  if(subs===2) routing.push(null);
  return {id,label:id==='stereo'?'Stereo (2.0)':id,bed,sources,subs,routing,
    subOutputs:routing.flatMap((source,i)=>source===null?[i]:[])};
});

export function currentLayout(config) {
  return LAYOUTS.find(layout => config.outputs.every((o,i)=>{
    if(i>=layout.routing.length) return o.role==='unused';
    const source=layout.routing[i];
    return source===null ? o.role==='sub' : o.role==='speaker' && o.source===source;
  }))?.id ?? 'custom';
}

export function applyLayout(config,id) {
  const layout=LAYOUTS.find(v=>v.id===id);
  if(!layout) throw new Error('Choose an output format');
  const result=structuredClone(config), flat=createConfig();
  result.outputs=flat.outputs.map((o,i)=>({...o,label:`Spare ${i+1}`,role:'unused',source:0}));
  result.sends=Array.from({length:16},()=>Array(16).fill(null));
  layout.routing.forEach((source,i)=>{
    if(source!==null) Object.assign(result.outputs[i],{label:names[source],role:'speaker',source});
  });
  const [firstSub,secondSub]=layout.subOutputs;
  layout.subOutputs.forEach((output,n)=>Object.assign(result.outputs[output],{
    label:layout.bed>=5 ? (n===0?'LFE':'Sub 2') : layout.subs===1?'Sub':n===0?'Sub L':'Sub R',
    role:'sub',source:result.lfe.input
  }));
  // Split only active main sources; LFE remains one explicitly designated input.
  for(const source of layout.sources) {
    if(source===result.lfe.input) continue;
    const label=names[source];
    if(layout.subs===1) result.sends[source][firstSub]=0;
    else if(layout.subs===2) {
      if(label.startsWith('L')) result.sends[source][firstSub]=0;
      else if(label.startsWith('R')) result.sends[source][secondSub]=0;
      else {result.sends[source][firstSub]=-6;result.sends[source][secondSub]=-6;}
    }
  }
  for(const output of layout.subOutputs) result.sends[result.lfe.input][output]=layout.subs===1?0:-6;
  result.bassEnabled=layout.subs>0;
  if (Array.isArray(result.buses)) {
    const active = Array.from({length: layout.routing.length}, (_, i) => i);
    result.buses = [{ id: 'speakers', kind: 'speakers', label: 'Speakers', outputIds: active, layoutId: id, gainDb: 0, mute: false }];
    result.outputs.forEach((output, i) => { output.busId = active.includes(i) ? 'speakers' : null; });
  }
  // Stereo has full-range mains. Input labels/order and crossover values stay intact.
  return validateConfig(result);
}

export function swapOutputs(config,from,to) {
  if([from,to].some(i=>!Number.isInteger(i)||i<0||i>=config.outputs.length)) throw new Error('Choose an output from 1 to 16');
  const result=structuredClone(config);
  [result.outputs[from],result.outputs[to]]=[result.outputs[to],result.outputs[from]];
  // Bass send columns follow their sub; processing and source assignments travel too.
  for(const row of result.sends) [row[from],row[to]]=[row[to],row[from]];
  // Bus ownership follows the physical output processing moved by the swap.
  if (Array.isArray(result.buses)) {
    for (const bus of result.buses) {
      bus.outputIds = bus.outputIds.map(i => i === from ? to : i === to ? from : i);
    }
    const ownership = new Map(result.buses.flatMap(bus => bus.outputIds.map(i => [i, bus.id])));
    result.outputs.forEach((output, i) => { output.busId = ownership.get(i) ?? null; });
  }
  return validateConfig(result);
}

export function applyCrossover(config,indices,frequency) {
  if(!Array.isArray(indices)||!indices.length) throw new Error('Select at least one channel');
  if(indices.some(i=>!Number.isInteger(i)||i<0||i>=config.inputs.length||i===config.lfe.input)) throw new Error('Select non-LFE input channels only');
  if(typeof frequency!=='number'||!Number.isFinite(frequency)||frequency<20||frequency>250) throw new Error('Crossover must be between 20 and 250 Hz');
  const result=structuredClone(config);
  for(const i of new Set(indices)) {
    result.inputs[i].highpassHz=frequency;
    result.inputs[i].lowpassHz=frequency;
  }
  return validateConfig(result);
}

const processingKeys=['gainDb','delayMs','mute','invert','eqEnabled','bands'];
export function copyChannel(output) {
  return {label:output.label,processing:structuredClone(Object.fromEntries(processingKeys.map(key=>[key,output[key]])))};
}
export function pasteChannel(config,index,clipboard,scope='processing') {
  if(!clipboard?.processing || !['processing','eq'].includes(scope)) throw new Error('Copy a channel first');
  const result=structuredClone(config);
  const keys=scope==='eq'?['eqEnabled','bands']:processingKeys;
  for(const key of keys) result.outputs[index][key]=structuredClone(clipboard.processing[key]);
  return validateConfig(result);
}

export function parseRew(text) {
  if(typeof text!=='string'||text.length>200000) throw new Error('REW text must be under 200 KB');
  const equaliser=text.match(/^\s*Equali[sz]er\s*:\s*(.+)$/im);
  if(equaliser&&!/^(Generic|CamillaDSP)\b/i.test(equaliser[1].trim())) throw new Error('Re-export using the Generic or CamillaDSP equaliser to preserve filter definitions.');
  const rows=text.replace(/^\uFEFF/,'').split(/\r?\n/).filter(line=>/^\s*Filter(?:\s+(?!Settings\b)|\s*:)/i.test(line));
  if(!rows.length) throw new Error('No REW filters found. Use “Export filter settings as text” (.txt).');
  const bands=[],seen=new Set();let skipped=0;
  const numeric='([+-]?(?:\\d+(?:[.,]\\d*)?|[.,]\\d+)(?:e[+-]?\\d+)?)';
  const parameters=new RegExp(`^Fc\\s+${numeric}\\s+Hz\\s+Gain\\s+${numeric}\\s+dB\\s+Q\\s+${numeric}\\s*$`,'i');
  const types={PK:'bell',PEQ:'bell',LSQ:'lowShelf',HSQ:'highShelf',LS:'lowShelf',HS:'highShelf'};
  for(const line of rows) {
    const match=line.match(/^\s*Filter\s+(\d+)\s*:\s*(ON|OFF)\s+(\S+)(?:\s+(.*?))?\s*$/i);
    if(!match) throw new Error(`Malformed filter line: ${line.trim().slice(0,90)}`);
    const [,index,state,rawType,params='']=match, type=rawType.toUpperCase();
    if(seen.has(Number(index))) throw new Error(`Duplicate filter ${index}`);
    seen.add(Number(index));
    if(state.toUpperCase()==='OFF'||type==='NONE') {skipped++;continue;}
    if(!Object.hasOwn(types,type)) throw new Error(`Filter ${index}: ${type} is unsupported. Use PK or Q-based shelves (LSQ/HSQ).`);
    const values=params.match(parameters);
    if(!values) throw new Error(`Filter ${index}: expected Fc, Gain and Q. Shelf exports must include Q.`);
    const [frequency,gainDb,q]=values.slice(1).map(v=>Number(v.replace(',','.')));
    bands.push({enabled:true,type:types[type],frequency,gainDb,q});
  }
  if(!bands.length) throw new Error('No enabled EQ filters to import');
  if(bands.length>16) throw new Error(`${bands.length} enabled filters exceed the 16-band limit. No filters were imported.`);
  const count=bands.length;
  while(bands.length<16) bands.push({enabled:false,type:'bell',frequency:FREQUENCIES[bands.length],gainDb:0,q:1});
  const check=createConfig();check.outputs[0].bands=bands;
  try {validateConfig(check);} catch(error) {throw new Error(`REW import: ${error.message}. No values were clamped.`);}
  return {bands,count,skipped};
}
