import { createConfig, validateConfig, FREQUENCIES } from './model.mjs';

const beds = {2:[0,1],5:[0,1,2,4,5],7:[0,1,2,4,5,6,7],9:[0,1,2,4,5,6,7,12,13]};
const heights = {0:[],2:[8,9],4:[8,9,10,11]};
const names = ['L','R','C','LFE','Ls','Rs','Lrs','Rrs','Ltf','Rtf','Ltr','Rtr','Lw','Rw'];
export const LAYOUTS = [
  ['stereo',2,0,0],['2.1',2,1,0],['2.2',2,2,0],['5.1',5,1,0],['5.2',5,2,0],
  ['5.1.2',5,1,2],['5.1.4',5,1,4],['5.2.4',5,2,4],
  ['7.1',7,1,0],['7.2',7,2,0],['7.1.2',7,1,2],['7.1.4',7,1,4],['7.2.4',7,2,4],['9.1.4',9,1,4]
].map(([id,bed,subs,height])=>({id,label:id==='stereo'?'Stereo (2.0)':id,sources:[...beds[bed],...heights[height]],subs}));

export function currentLayout(config) {
  return LAYOUTS.find(layout => config.outputs.every((o,i)=>{
    if(i<layout.sources.length) return o.role==='speaker' && o.source===layout.sources[i];
    return o.role===(i<layout.sources.length+layout.subs?'sub':'unused');
  }))?.id ?? 'custom';
}

export function applyLayout(config,id) {
  const layout=LAYOUTS.find(v=>v.id===id);
  if(!layout) throw new Error('Choose an output format');
  const result=structuredClone(config), flat=createConfig();
  result.outputs=flat.outputs.map((o,i)=>({...o,label:`Spare ${i+1}`,role:'unused',source:0}));
  result.sends=Array.from({length:16},()=>Array(16).fill(null));
  layout.sources.forEach((source,i)=>Object.assign(result.outputs[i],{label:names[source],role:'speaker',source}));
  const start=layout.sources.length;
  for(let n=0;n<layout.subs;n++) Object.assign(result.outputs[start+n],{label:layout.subs===1?'Sub':n===0?'Sub L':'Sub R',role:'sub'});
  // Split only active main sources; LFE remains one explicitly designated input.
  for(const source of layout.sources) {
    if(source===result.lfe.input) continue;
    const label=names[source];
    if(layout.subs===1) result.sends[source][start]=0;
    else if(layout.subs===2) {
      if(label.startsWith('L')) result.sends[source][start]=0;
      else if(label.startsWith('R')) result.sends[source][start+1]=0;
      else {result.sends[source][start]=-6;result.sends[source][start+1]=-6;}
    }
  }
  for(let n=0;n<layout.subs;n++) result.sends[result.lfe.input][start+n]=layout.subs===1?0:-6;
  result.bassEnabled=layout.subs>0;
  // Stereo has full-range mains. Input labels/order and crossover values stay intact.
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
