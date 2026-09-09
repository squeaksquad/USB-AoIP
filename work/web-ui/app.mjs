import { createConfig, validateConfig, parsePreset, setOutputRole, bandResponse, eqResponse, subSumBoundDb } from './model.mjs';
import { LAYOUTS, currentLayout, applyLayout, swapOutputs, applyCrossover, copyChannel, pasteChannel, parseRew, dragEqBand, EQ_RANGE_DB, SERVICE_COMMANDS, journalCommand } from './workflows.mjs';
import { resetBand } from './reset-band.mjs';
import { getBus, applyBusLayout, setBusGainMute, setHeadphoneMode, setHeadphonePair, setHeadphoneMatrix, createHeadphoneBus, createSpeakerBus, removeBus } from './buses.mjs';

let config = createConfig(), selected = 0, tab = 'outputs', metersRunning = true, dirty = true;
let channelClipboard = null, pasteScope = 'processing', layoutUndo = null, rewParsed = null;
let crossoverScope = 'all', crossoverHz = '80', busUndo = null;
const crossoverSelection = new Set();
let selectedBand = 0, eqDrag = null, eqObserver;
let logService = 'all', logQuery = '';
const logSnapshots = {all:'',aes67:'',usb:''};
const bandColors = ['#f39364','#e6b35c','#d9d464','#add875','#6bdaa3','#65d5c8','#68b8eb','#849af3','#aa92ec','#cd8ee0','#e486b9','#ed8694','#c6ac83','#95b9aa','#a6add5','#b6c878'];
const storageKey = 'usb16x16-design-presets-v1';
const $ = selector => document.querySelector(selector);
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pad = i => String(i + 1).padStart(2, '0');
const checked = v => v ? 'checked' : '';
const disabled = v => v ? 'disabled' : '';
const options = (items, value) => items.map(([v, label]) => `<option value="${esc(v)}" ${String(v) === String(value) ? 'selected' : ''}>${esc(label)}</option>`).join('');
const number = (attrs, value, min, max, step = 1) => `<input type="number" ${attrs} value="${value}" min="${min}" max="${max}" step="${step}"${attrs.includes('data-downmix')?'':' required'}>`;
const field = (label, content) => `<label class="field"><span>${label}</span>${content}</label>`;
const inputOptions = () => config.inputs.map((v, i) => [i, `${pad(i)} · ${v.label}`]);
let toastTimer;
function toast(message) { $('#toast').textContent = message; $('#toast').classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('#toast').classList.remove('show'), 4500); }
function presets() {
  try { const stored = JSON.parse(localStorage.getItem(storageKey) || '{}'); return stored && typeof stored === 'object' && !Array.isArray(stored) ? stored : {}; }
  catch { return {}; }
}
function markDraft() { dirty = true; $('#draft-status').textContent = 'Draft · unsaved'; }

function render() {
  const isDirect = config.mode === 'direct';
  for (const button of document.querySelectorAll('[data-tab]')) { const active = button.dataset.tab === tab; button.classList.toggle('active', active); button.setAttribute('aria-current', active ? 'page' : 'false'); }
  for (const name of ['outputs', 'bass', 'settings']) $(`#${name}-page`).hidden = name !== tab;
  for (const button of document.querySelectorAll('[data-mode]')) { const active = button.dataset.mode === config.mode; button.classList.toggle('active', active); button.setAttribute('aria-pressed', active); }
  for (const button of document.querySelectorAll('[data-source]')) { const active = button.dataset.source === config.source; button.classList.toggle('active', active); button.setAttribute('aria-pressed', active); button.disabled = isDirect; }
  $('#flow-middle').textContent = isDirect ? 'USB ↔ AoIP transport' : 'Bass management + output DSP';
  $('#flow-detail').textContent = isDirect ? 'Existing duplex bridge · DSP bypassed' : '16-band PEQ · alignment · level';
  $('#flow-output').textContent = isDirect ? '16 × 16 duplex' : '16 AoIP outputs';
  $('#mode-note').textContent = isDirect ? 'Previewing direct mode. DSP edits are disabled; the DSP draft is retained. No device has been switched.' : 'Previewing DSP mode. Switching source or mode on hardware will require a controlled audio interruption.';
  $('#draft-status').textContent = dirty ? 'Draft · unsaved' : 'Preset saved locally';
  renderBuses(); renderLayout(); renderBank(); renderInspector(); renderBass(); renderSettings(); updateMeters();
}

function renderBuses() {
  const buses = config.buses || [];
  const off = config.mode === 'direct';
  const freeCount = config.outputs.filter(o=>o.busId===null).length;
  const busOptions = buses.map(b => [b.id, `${b.label} · ${b.outputIds.map(i => pad(i)).join(', ')}`]);
  $('#bus-controls').innerHTML = `<section class="panel bus-panel"><div class="section-heading"><div><h2>Output buses <span>shared 16-output budget</span></h2><p>Each physical output belongs to one bus. Formats apply only to the selected bus; unrelated buses keep their routing.</p></div><div class="toolbar"><button data-action="bus-add-speakers" ${disabled(off||freeCount<2)}>Add speaker bus</button><button data-action="bus-add-headphones" ${disabled(off||freeCount<2)}>Add headphones</button></div></div><fieldset ${disabled(off)} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bus-list">${buses.map(bus => { const headphone=bus.kind==='headphones'; const layoutOptions=[['custom','Custom mapping'],...LAYOUTS.filter(l=>!headphone||l.routing.length===2).map(l=>[l.id,l.label])]; return `<article class="bus-card ${headphone?'headphone-bus':''}" data-bus-card="${esc(bus.id)}">
      <div class="bus-card-head"><div><strong>${esc(bus.label)}</strong><small>${headphone?'Headphone stereo · raw pre-crossover tap':'Speaker bus'} · outputs ${bus.outputIds.map(i=>pad(i)).join(', ')}</small></div><div class="toolbar">${field('Bus name',`<input data-bus="${esc(bus.id)}" data-bus-param="label" value="${esc(bus.label)}" maxlength="64" aria-label="${esc(bus.label)} bus name">`)}${field('Format',`<select data-bus="${esc(bus.id)}" data-bus-param="layout">${options(layoutOptions,bus.layoutId||'custom')}</select>`)}<button data-action="bus-apply" data-bus-id="${esc(bus.id)}">Apply format</button><button class="quiet" data-action="bus-remove" data-bus-id="${esc(bus.id)}">Remove</button></div></div>
      <div class="bus-controls">${field('Bus gain · dB',number(`data-bus="${esc(bus.id)}" data-bus-param="gainDb" aria-label="${esc(bus.label)} bus gain"`,bus.gainDb,-60,12,.1))}<label class="checkbox-label"><input type="checkbox" data-bus="${esc(bus.id)}" data-bus-param="mute" ${checked(bus.mute)} aria-label="Mute ${esc(bus.label)} bus">Mute bus</label>${headphone?`<span class="raw-tap">RAW TAP · before speaker crossovers</span>`:''}</div>
      ${headphone ? renderHeadphoneControls(bus) : ''}</article>`; }).join('')}</div>
    <div class="bus-budget"><strong>${config.outputs.filter(o=>o.busId!==null).length}/16 outputs allocated</strong><span>${config.outputs.filter(o=>o.busId===null).length} available · apply/undo is scoped per bus</span><button class="quiet" data-action="bus-undo" ${disabled(!busUndo)}>Undo last bus format</button></div></fieldset></section>`;
}

function renderHeadphoneControls(bus) {
  const pairOptions = inputOptions();
  const matrix = bus.downmixMatrix || Array.from({length:16},()=>[null,null]);
  return `<div class="headphone-controls"><div class="field-row"><span class="overline">Headphone source</span><label class="checkbox-label"><input type="radio" name="headphone-mode-${esc(bus.id)}" value="pair" data-headphone-mode="${esc(bus.id)}" ${bus.inputMode==='pair'?'checked':''}>Independent stereo pair</label><label class="checkbox-label"><input type="radio" name="headphone-mode-${esc(bus.id)}" value="downmix" data-headphone-mode="${esc(bus.id)}" ${bus.inputMode==='downmix'?'checked':''}>Surround stereo downmix</label></div>
    <div class="field-row">${field('Left input',`<select data-headphone-pair="${esc(bus.id)}" data-ear="0" ${disabled(bus.inputMode!=='pair')}>${options(pairOptions,bus.inputPair?.[0]??0)}</select>`)}${field('Right input',`<select data-headphone-pair="${esc(bus.id)}" data-ear="1" ${disabled(bus.inputMode!=='pair')}>${options(pairOptions,bus.inputPair?.[1]??1)}</select>`)}</div>
    <details class="downmix-editor" ${bus.inputMode==='downmix'?'open':''}><summary>Advanced downmix levels · pre-crossover input to each ear</summary><div class="table-scroll"><table><thead><tr><th>Input</th><th>Left · dB</th><th>Right · dB</th></tr></thead><tbody>${matrix.map((row,i)=>`<tr><td>${pad(i)} · ${esc(config.inputs[i].label)}${i===config.lfe.input?' · LFE':''}</td><td>${number(`data-downmix="${esc(bus.id)}" data-input-index="${i}" data-ear="0" aria-label="${esc(bus.label)} ${pad(i)} left downmix"`,row?.[0]??'',-60,12,.1)}</td><td>${number(`data-downmix="${esc(bus.id)}" data-input-index="${i}" data-ear="1" aria-label="${esc(bus.label)} ${pad(i)} right downmix"`,row?.[1]??'',-60,12,.1)}</td></tr>`).join('')}</tbody></table></div><small>Blank means this input is excluded. Levels are routing coefficients for the UI draft; no binaural processing is implied.</small></details></div>`;
}

function renderLayout() {
  const current=currentLayout(config);
  $('#layout-controls').innerHTML='';
}

function renderBank() {
  $('#input-bank').innerHTML = config.inputs.map((o,i)=>`<div class="strip"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="meter" aria-hidden="true" style="display:block"><i id="input-meter-${i}"></i></span><span id="input-level-${i}" class="meter-value">—</span></div>`).join('');
  $('#channel-bank').innerHTML = config.outputs.map((o, i) => `<div class="strip ${o.role} ${i === selected ? 'selected' : ''}">
    <button class="strip-select" data-select="${i}" aria-label="Edit output ${i + 1}: ${esc(o.label)}" aria-pressed="${i === selected}"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="role-label">${o.role === 'unused' ? 'SPARE' : o.role.toUpperCase()}</span><span class="meter" aria-hidden="true" style="display:block"><i id="meter-${i}"></i></span><span id="level-${i}" class="meter-value">—</span></button>
    <button class="mute" data-mute="${i}" aria-label="Mute output ${i + 1}" aria-pressed="${o.mute}" ${disabled(config.mode === 'direct' || o.role === 'unused')}>M</button></div>`).join('');
}

function renderInspector() {
  endEqDrag(true);
  eqObserver?.disconnect();
  const o = config.outputs[selected], off = config.mode === 'direct', owner = config.buses?.find(b=>b.id===o.busId), headphone = owner?.kind === 'headphones', ear = owner ? owner.outputIds.indexOf(selected) : -1;
  $('#inspector').innerHTML = `<div class="inspector-head"><div><h2><span class="badge">${pad(selected)}</span>${esc(o.label)}</h2><p>AoIP output ${selected + 1} · ${o.role === 'sub' ? 'Independent subwoofer correction' : o.role === 'unused' ? 'Assign a role to use this output' : 'Independent speaker correction'}</p></div>${field('AoIP output', `<select id="out-destination" title="Swap output assignments, including processing and bass sends" ${disabled(off)}>${options(config.outputs.map((v,i)=>[i,`${pad(i)} · ${v.label}${i===selected?'':' (swap)'}`]),selected)}</select>`)}</div>
    <fieldset ${disabled(off)} style="border:0;padding:0;margin:0;min-width:0">
    <div class="channel-tools"><button data-action="channel-copy">Copy channel</button><label class="field"><span>Paste scope</span><select id="paste-scope">${options([['processing','All output processing'],['eq','EQ only']],pasteScope)}</select></label><button data-action="channel-paste" ${disabled(!channelClipboard)}>Paste${channelClipboard?` from ${esc(channelClipboard.label)}`:''}</button><button data-action="rew-open">Import REW EQ</button><small>Copies EQ, gain, delay, mute and polarity. Destination label and routing stay unchanged.</small></div>
    <div class="output-controls">
      ${field('Output label', `<input id="out-label" data-out="label" value="${esc(o.label)}" maxlength="64" required>`)}
      ${headphone ? field('Bus route', `<input value="${ear===0?'Left ear':ear===1?'Right ear':'Headphone'} · ${owner.inputMode==='pair'?'pair':'downmix'}" disabled aria-label="Headphone bus route">`) : field('Output role', `<select id="out-role" data-out="role">${options([['speaker','Speaker'],['sub','Subwoofer'],['unused','Unused']],o.role)}</select>`)}
      ${headphone ? field('Speaker source', `<input value="Raw pre-crossover headphone bus" disabled aria-label="Headphone raw source">`) : field('Speaker source', `<select id="out-source" data-out="source" ${disabled(o.role !== 'speaker')}>${options(inputOptions(),o.source)}</select>`)}
      ${field('Gain · dB', number('id="out-gain" data-out="gainDb"',o.gainDb,-60,12,.1))}
      ${field('Alignment · ms', number('id="out-delay" data-out="delayMs"',o.delayMs,0,10,.01))}
      <div class="toolbar"><button data-action="polarity" aria-pressed="${o.invert}" title="Invert output polarity">Ø Invert</button><button data-mute="${selected}" aria-pressed="${o.mute}">Mute</button></div>
    </div>
    <div class="eq-title"><div><h3>Parametric EQ <span class="muted">/ 16 bands</span></h3><p>Calculated PEQ response only · excludes crossovers, output gain and room response</p></div><button class="quiet" data-action="eq-toggle" aria-pressed="${o.eqEnabled}">${o.eqEnabled ? 'EQ enabled' : 'EQ bypassed'}</button></div>
    <div class="eq-workspace">
      <div class="eq-display" id="eq-display">
        <svg id="eq-chart" class="eq-chart" role="img" aria-label="Calculated output PEQ magnitude response, 20 Hz to 20 kHz"></svg>
        <div class="eq-nodes">${o.bands.map((b,i)=>`<button type="button" class="eq-node" data-eq-node="${i}" style="--band-color:${bandColors[i]}" aria-describedby="eq-help">${i+1}</button>`).join('')}</div>
        <span class="eq-plot-caption">OUTPUT PEQ <span>±${EQ_RANGE_DB} dB</span></span>
      </div>
      <div id="selected-eq-band" class="selected-eq-band"></div>
      <p id="eq-help" class="eq-help">Drag a band: frequency / gain · <kbd>⌘ Cmd</kbd> + drag up/down: Q · Arrow keys: fine adjust · Esc: cancel drag</p>
    </div>
    <div class="eq-bands">${[0,8].map(start=>`<div class="table-scroll"><table class="band-table" aria-label="EQ bands ${start+1}–${start+8}"><thead><tr><th>Band</th><th>On</th><th>Filter</th><th>Frequency · Hz</th><th>Gain · dB</th><th>Q</th><th>Reset</th></tr></thead><tbody>${o.bands.slice(start,start+8).map((b,n) => { const i=start+n; return `<tr class="${b.enabled ? '' : 'band-disabled'}"><td>${pad(i)}</td><td><input type="checkbox" data-band="${i}" data-param="enabled" aria-label="Band ${i+1} enabled" ${checked(b.enabled)}></td><td><select data-band="${i}" data-param="type" aria-label="Band ${i+1} filter">${options([['bell','Bell'],['lowShelf','Low shelf'],['highShelf','High shelf']],b.type)}</select></td><td>${number(`data-band="${i}" data-param="frequency" aria-label="Band ${i+1} frequency"`,b.frequency,20,20000,'any')}</td><td>${number(`data-band="${i}" data-param="gainDb" aria-label="Band ${i+1} gain"`,b.gainDb,-18,18,'any')}</td><td>${number(`data-band="${i}" data-param="q" aria-label="Band ${i+1} Q"`,b.q,.1,18,'any')}</td><td><button type="button" class="quiet band-reset" data-band-reset="${i}" aria-label="Reset band ${i+1}" title="Reset band ${i+1} to its default frequency, gain, Q and bell filter">Reset</button></td></tr>`; }).join('')}</tbody></table></div>`).join('')}</div>
    </fieldset>`;
  renderSelectedBand(); drawEq();
  eqObserver = new ResizeObserver(drawEq);
  eqObserver.observe($('#eq-display'));
}

function eqGeometry() {
  const rect = $('#eq-display').getBoundingClientRect();
  const width = rect.width || 1000, height = rect.height || 420;
  return {rect,width,height,left:42,top:30,plotWidth:width-66,plotHeight:height-60};
}

function renderSelectedBand() {
  const b = config.outputs[selected].bands[selectedBand];
  $('#selected-eq-band').style.setProperty('--band-color',bandColors[selectedBand]);
  $('#selected-eq-band').innerHTML = `${field('Selected band',`<select id="eq-band-select">${options(config.outputs[selected].bands.map((v,i)=>[i,`Band ${i+1}${v.enabled?'':' · off'}`]),selectedBand)}</select>`)}
    <label class="checkbox-label"><input type="checkbox" data-band="${selectedBand}" data-param="enabled" aria-label="Selected band enabled" ${checked(b.enabled)}>On</label>
    ${field('Filter',`<select data-band="${selectedBand}" data-param="type" aria-label="Selected band filter">${options([['bell','Bell'],['lowShelf','Low shelf'],['highShelf','High shelf']],b.type)}</select>`)}
    ${field('Frequency · Hz',number(`data-band="${selectedBand}" data-param="frequency" aria-label="Selected band frequency"`,b.frequency,20,20000,'any'))}
    ${field('Gain · dB',number(`data-band="${selectedBand}" data-param="gainDb" aria-label="Selected band gain"`,b.gainDb,-18,18,'any'))}
    ${field('Q',number(`data-band="${selectedBand}" data-param="q" aria-label="Selected band Q"`,b.q,.1,18,'any'))}
    <button type="button" class="quiet band-reset selected-band-reset" data-band-reset="${selectedBand}" aria-label="Reset selected band ${selectedBand+1}" title="Reset selected band to its default frequency, gain, Q and bell filter">Reset band</button>`;
}

function syncEqEditors() {
  document.querySelectorAll('[data-band][data-param]').forEach(el=>{
    const b = config.outputs[selected].bands[Number(el.dataset.band)], value = b[el.dataset.param];
    if(el !== document.activeElement) {
      if(el.type==='checkbox') el.checked=value;
      else el.value=value;
    }
    el.closest('tr')?.classList.toggle('band-disabled',!b.enabled);
    el.closest('tr')?.classList.toggle('band-selected',Number(el.dataset.band)===selectedBand);
  });
  [...$('#eq-band-select').options].forEach((option,i)=>{option.textContent=`Band ${i+1}${config.outputs[selected].bands[i].enabled?'':' · off'}`;});
}

function drawEq() {
  const o = config.outputs[selected], {width,height,left,top,plotWidth,plotHeight} = eqGeometry();
  const x = f => left + Math.log10(f/20)/3 * plotWidth, y = g => top + plotHeight/2 - Math.max(-EQ_RANGE_DB,Math.min(EQ_RANGE_DB,g))*plotHeight/(EQ_RANGE_DB*2);
  const editable = config.mode!=='direct' && o.eqEnabled;
  const frequencies = [20,50,100,200,500,1000,2000,5000,10000,20000];
  const grid = [-EQ_RANGE_DB,-EQ_RANGE_DB/2,0,EQ_RANGE_DB/2,EQ_RANGE_DB].map(g => `<line x1="${left}" y1="${y(g)}" x2="${x(20000)}" y2="${y(g)}" class="${g===0?'eq-zero':'eq-grid'}"/><text x="6" y="${y(g)+4}" class="eq-label">${g>0?'+':''}${g}</text>`).join('') + frequencies.filter((f,i)=>width>600||i%2===0||f===20000).map(f => `<line x1="${x(f)}" y1="${top}" x2="${x(f)}" y2="${y(-EQ_RANGE_DB)}" class="eq-grid"/><text x="${x(f)}" y="${height-9}" text-anchor="middle" class="eq-label">${f>=1000?`${f/1000}k`:f}</text>`).join('');
  const path = response => 'M'+Array.from({length:401},(_,i)=>{const f=20*1000**(i/400);return `${x(f).toFixed(2)},${y(response(f)).toFixed(2)}`;}).join(' L');
  const curves = o.eqEnabled ? o.bands.map((b,i)=>!b.enabled?'':`<path d="${path(f=>bandResponse(b,f))} L${x(20000)},${y(0)} L${left},${y(0)} Z" fill="${bandColors[i]}" fill-opacity="${i===selectedBand?'.17':'.025'}"/><path d="${path(f=>bandResponse(b,f))}" fill="none" stroke="${bandColors[i]}" stroke-width="${i===selectedBand?2:1}" opacity="${i===selectedBand?'.95':'.4'}"/>`).join('') : '';
  $('#eq-chart').setAttribute('viewBox',`0 0 ${width} ${height}`);
  $('#eq-chart').innerHTML = `${grid}${curves}<path d="${path(f=>eqResponse(o,f))}" class="eq-curve"/>`;
  $('#eq-display').classList.toggle('eq-bypassed',!editable);
  document.querySelectorAll('[data-eq-node]').forEach(node=>{
    const i=Number(node.dataset.eqNode),b=o.bands[i];
    node.style.left=`${x(b.frequency)/width*100}%`;node.style.top=`${y(b.gainDb)/height*100}%`;
    node.classList.toggle('selected',i===selectedBand);node.classList.toggle('band-off',!b.enabled);
    node.disabled=!editable;node.setAttribute('aria-pressed',i===selectedBand);
    node.setAttribute('aria-label',`Band ${i+1}: ${b.frequency.toFixed(1)} Hz, ${b.gainDb.toFixed(1)} dB, Q ${b.q.toFixed(2)}${b.enabled?'':', off'}`);
    node.title=`Band ${i+1} · ${b.frequency.toFixed(1)} Hz · ${b.gainDb.toFixed(1)} dB · Q ${b.q.toFixed(2)}${b.enabled?'':' · Enable On to drag'}`;
  });
  syncEqEditors();
}

function endEqDrag(cancel=false) {
  if(!eqDrag) return;
  const drag=eqDrag;eqDrag=null;
  if(cancel) {config.outputs[drag.output].bands[drag.band]=drag.original;dirty=drag.dirty;$('#draft-status').textContent=dirty?'Draft · unsaved':'Preset saved locally';}
  drag.node.classList.remove('dragging');
  if(drag.node.hasPointerCapture(drag.pointerId)) drag.node.releasePointerCapture(drag.pointerId);
  drawEq();
}

document.addEventListener('pointerdown',event=>{
  const node=event.target.closest('[data-eq-node]');
  if(!node||event.button!==0||eqDrag||config.mode==='direct'||!config.outputs[selected].eqEnabled)return;
  event.preventDefault();selectedBand=Number(node.dataset.eqNode);node.focus({preventScroll:true});renderSelectedBand();drawEq();
  const band=config.outputs[selected].bands[selectedBand];
  if(!band.enabled)return;
  eqDrag={node,pointerId:event.pointerId,output:selected,band:selectedBand,original:{...band},dirty,x:event.clientX,y:event.clientY};
  node.setPointerCapture(event.pointerId);node.classList.add('dragging');
});
document.addEventListener('pointermove',event=>{
  if(!eqDrag||event.pointerId!==eqDrag.pointerId)return;
  const {plotWidth,plotHeight}=eqGeometry(),dx=(event.clientX-eqDrag.x)/plotWidth,dy=(event.clientY-eqDrag.y)/plotHeight;
  eqDrag.x=event.clientX;eqDrag.y=event.clientY;
  if(!dx&&!dy)return;
  const o=config.outputs[eqDrag.output];
  o.bands[eqDrag.band]=dragEqBand(o.bands[eqDrag.band],dx,dy,event.metaKey||event.ctrlKey);
  markDraft();drawEq();
});
document.addEventListener('pointerup',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag();});
document.addEventListener('pointercancel',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag(true);});
document.addEventListener('lostpointercapture',event=>{if(eqDrag?.pointerId===event.pointerId)endEqDrag(true);});
window.addEventListener('blur',()=>endEqDrag(true));
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&eqDrag){event.preventDefault();endEqDrag(true);return;}
  const node=event.target.closest('[data-eq-node]');
  if(!node||node.disabled||config.mode==='direct'||!config.outputs[selected].eqEnabled)return;
  if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;
  event.preventDefault();selectedBand=Number(node.dataset.eqNode);
  const o=config.outputs[selected],b=o.bands[selectedBand];
  if(!b.enabled)return;
  const dx=event.key==='ArrowRight'?1/600:event.key==='ArrowLeft'?-1/600:0;
  const dy=event.key==='ArrowUp'?-1/480:event.key==='ArrowDown'?1/480:0;
  o.bands[selectedBand]=dragEqBand(b,dx,dy,event.metaKey||event.ctrlKey);
  renderSelectedBand();markDraft();drawEq();
});

function crossoverTargets() {
  return config.inputs.map((_,i)=>i).filter(i=>i!==config.lfe.input && (crossoverScope==='all'||crossoverSelection.has(i)));
}

function refreshCrossoverControls() {
  const targets=crossoverTargets(), selectionCount=crossoverSelection.size;
  $('#crossover-scope').value=crossoverScope;
  $('#crossover-apply').textContent=`Apply to ${targets.length} channel${targets.length===1?'':'s'}`;
  $('#crossover-apply').disabled=!targets.length||!config.bassEnabled||config.mode==='direct';
  $('#crossover-count').textContent=`${selectionCount} selected`;
  const all=$('#crossover-select-all');
  all.checked=selectionCount===config.inputs.length-1;
  all.indeterminate=selectionCount>0&&!all.checked;
}

function renderBass() {
  crossoverSelection.delete(config.lfe.input);
  const subs = config.outputs.map((o,i)=>({...o,index:i})).filter(o=>o.role==='sub');
  const slopeOptions = value => options([[12,'LR · 12 dB/oct'],[24,'LR · 24 dB/oct'],[48,'LR · 48 dB/oct']],value);
  $('#bass-page').innerHTML = `<fieldset ${disabled(config.mode==='direct')} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bass-top"><section class="panel"><h2>Speaker bass redirection</h2><p>High-pass each main speaker and send its low frequencies to your chosen subs. Output EQ and alignment follow the split.</p><div class="field-row"><label class="checkbox-label"><input type="checkbox" id="bass-enabled" ${checked(config.bassEnabled)}>Bass redirection enabled</label>${field('Common input trim · dB',number('id="headroom"',config.headroomDb,-36,0,.1))}</div><p>Turning redirection off restores full-range mains and silences their sub sends. LFE remains independently routed.</p></section>
    <section class="panel"><h2>LFE is its own source</h2><p>Control the effects channel separately from redirected speaker bass. LFE gain is explicit; no automatic +10 dB boost.</p><div class="field-row">${field('LFE input',`<select data-lfe="input">${options(inputOptions(),config.lfe.input)}</select>`)}${field('Low-pass · Hz',number('data-lfe="lowpassHz"',config.lfe.lowpassHz,20,250))}${field('Slope',`<select data-lfe="slope">${slopeOptions(config.lfe.slope)}</select>`)}${field('LFE trim · dB',number('data-lfe="trimDb"',config.lfe.trimDb,-24,12,.1))}</div></section></div>
    <section class="panel"><div class="section-heading"><div><h2>Bass routing matrix</h2><p>${subs.length} subwoofer output${subs.length===1?'':'s'} within the 16-channel output bank. Enable a send, then set its gain.</p></div></div>
    ${subs.length ? `<div class="crossover-tools"><strong>Set crossover</strong>${field('Crossover · Hz',`<input type="number" id="crossover-hz" value="${esc(crossoverHz)}" min="20" max="250" step="1" required ${disabled(!config.bassEnabled)}>`)}${field('Apply to',`<select id="crossover-scope" ${disabled(!config.bassEnabled)}>${options([['all','All non-LFE channels'],['selected','Selected channels']],crossoverScope)}</select>`)}<button id="crossover-apply" data-action="crossover-apply">Apply crossover</button><span id="crossover-count" class="muted"></span><p>Sets speaker HP and bass LP together. Select rows for a group, or edit any channel individually. LFE, slopes and HP on/off stay as set.</p></div>
    <div class="table-scroll"><table class="matrix"><thead><tr><th><label class="checkbox-label"><input type="checkbox" id="crossover-select-all" aria-label="Select all non-LFE channels for crossover" ${disabled(!config.bassEnabled)}>Source</label></th><th>HP on</th><th>Speaker HP · Hz</th><th>Bass LP · Hz</th><th>Slope</th>${subs.map(o=>`<th class="matrix-head">${pad(o.index)} · ${esc(o.label)}<small class="sub-sum">Sum bound: ${Number.isFinite(subSumBoundDb(config,o.index)) ? `${subSumBoundDb(config,o.index).toFixed(1)} dBFS` : 'silent'}</small></th>`).join('')}</tr></thead><tbody>${config.inputs.map((v,i)=>{
      const lfe = i === config.lfe.input;
      return `<tr class="${lfe?'lfe-row':''}"><td>${lfe?`<strong>${pad(i)} · ${esc(v.label)}</strong> <small>LFE</small>`:`<label class="checkbox-label"><input type="checkbox" data-crossover-select="${i}" aria-label="Select channel ${i+1}: ${esc(v.label)} for crossover" ${checked(crossoverSelection.has(i))} ${disabled(!config.bassEnabled)}><strong>${pad(i)} · ${esc(v.label)}</strong></label>`}</td><td>${lfe?'—':`<input type="checkbox" data-input="${i}" data-param="crossover" aria-label="${esc(v.label)} high-pass enabled" ${checked(v.crossover)} ${disabled(!config.bassEnabled)}>`}</td><td>${lfe?'—':number(`data-input="${i}" data-param="highpassHz" aria-label="${esc(v.label)} high-pass frequency" ${disabled(!config.bassEnabled||!v.crossover)}`,v.highpassHz,20,250)}</td><td>${lfe?`${config.lfe.lowpassHz} Hz`:number(`data-input="${i}" data-param="lowpassHz" aria-label="${esc(v.label)} bass low-pass frequency" ${disabled(!config.bassEnabled)}`,v.lowpassHz,20,250)}</td><td>${lfe?`${config.lfe.slope} dB/oct`:`<select data-input="${i}" data-param="slope" aria-label="${esc(v.label)} crossover slope" ${disabled(!config.bassEnabled)}>${slopeOptions(v.slope)}</select>`}</td>${subs.map(o=>{
        const gain = config.sends[i][o.index], inactive = !lfe && !config.bassEnabled;
        const name = `${v.label} to ${o.label}`;
        return `<td><div class="send-cell"><input type="checkbox" data-send="${i},${o.index}" aria-label="Enable ${esc(name)}" ${checked(gain!==null)} ${disabled(inactive)}>${number(`data-send-gain="${i},${o.index}" aria-label="${esc(name)} gain" ${disabled(gain===null||inactive)}`,gain??0,-60,12,.1)}<small>dB</small></div></td>`;
      }).join('')}</tr>`;
    }).join('')}</tbody></table></div>` : '<div class="empty"><h3>No subwoofer outputs assigned</h3><p>In Outputs, select any channel and change its role to Subwoofer.</p></div>'}
    <p class="route-note">HP off keeps a main full-range while retaining its bass send. New sub outputs start with all sends off. Sum bounds assume coherent full-scale inputs and include input trim, send gain, LFE trim, and output gain; they exclude filters and EQ, and are not measured peaks.</p>
    <p class="route-note">Changing the LFE input clears all sub sends from the old and new LFE rows, so those routes must be deliberately reassigned.</p></section></fieldset>`;
  if(subs.length) refreshCrossoverControls();
}

function renderSettings() {
  const saved = presets(), names = Object.keys(saved), count = role => config.outputs.filter(o=>o.role===role).length;
  $('#settings-page').innerHTML = `<div class="settings-grid"><section class="panel"><h2>Presets</h2><p>Save complete layouts, source selection, crossovers, sub sends and all 256 EQ bands in this browser. Export a JSON copy to keep or share the design.</p>
    ${field('Draft name',`<input id="preset-name" value="${esc(config.name)}" maxlength="64" required>`)}
    <div class="toolbar"><button class="primary" data-action="save">Save preset locally</button><button data-action="export">Export JSON</button><label class="import-label">Import JSON<input type="file" id="import-preset" accept=".json,application/json" aria-label="Import preset JSON"></label></div>
    ${field('Saved presets',`<select id="saved-preset" ${disabled(!names.length)}>${names.length?options(names.map(n=>[n,n]),config.name):'<option>No saved presets</option>'}</select>`)}
    <div class="toolbar"><button data-action="load" ${disabled(!names.length)}>Load selected preset</button><button class="quiet" data-action="reset">Reset to example layout</button></div>
    <div class="note-box">Local design only. Saving or importing a preset does not process audio or configure a device.</div>
    </section><section class="panel"><h2>System overview</h2><p>The hardware connection will appear here when a control backend is implemented.</p><dl class="fact-list">
      <div><dt>Connection</dt><dd>Not connected</dd></div><div><dt>Audio format</dt><dd>48 kHz · 16 input / 16 output</dd></div><div><dt>Output allocation</dt><dd>${count('speaker')} speakers · ${count('sub')} subs · ${count('unused')} spare</dd></div><div><dt>DSP source draft</dt><dd>${config.source==='usb'?'USB':'AoIP / AES67'}</dd></div><div><dt>DSP destination</dt><dd>AoIP / AES67</dd></div><div><dt>Alignment range</dt><dd>0–10 ms per output</dd></div><div><dt>Added DSP latency / CPU load</dt><dd>Not measured</dd></div><div><dt>PTP / USB / queue health</dt><dd>Unavailable offline</dd></div></dl></section>
    <section class="panel maintenance-panel"><div class="section-heading"><h2>Logs</h2><span class="offline-badge">Not connected</span></div>
    <p>Live service logs require the Pi connection. Copy a journal command to run on the Pi, then paste its output to inspect a snapshot here.</p>
    <div class="log-controls">${field('Service',`<select id="log-service">${options([['all','AES67 + USB'],['aes67','AES67'],['usb','USB']],logService)}</select>`)}${field('Filter snapshot',`<input id="log-filter" type="search" placeholder="Search log text…" value="${esc(logQuery)}">`)}<button disabled title="Requires a Pi control backend">Refresh live logs</button></div>
    <div class="command-line"><code id="journal-command">${esc(journalCommand(logService))}</code><button data-action="copy-journal">Copy command</button></div>
    <details class="log-paste"><summary>Paste a log snapshot</summary><label class="field"><span>Journal output · local to this page</span><textarea id="log-paste" rows="4" maxlength="200000" spellcheck="false" placeholder="Paste command output from the Pi here">${esc(logSnapshots[logService])}</textarea></label></details>
    <div class="log-view" tabindex="0" role="region" aria-label="Service log snapshot"><pre id="log-output"></pre></div><p id="log-count" role="status"></p></section>
    <section class="panel maintenance-panel"><div class="section-heading"><h2>Common commands</h2><span class="offline-badge">Run on the Pi</span></div>
    <p>Copy a command for a Pi terminal. Run buttons become available when device control is connected. Restart commands interrupt audio.</p>
    <div class="service-commands">${SERVICE_COMMANDS.map(c=>`<article class="service-command"><h3>${esc(c.label)}</h3><p>${esc(c.detail)}</p><code>${esc(c.command)}</code><div class="toolbar"><button data-copy-command="${c.id}" aria-label="Copy ${esc(c.label)} command">Copy command</button><button disabled title="Requires a Pi control backend" aria-label="Run ${esc(c.label)} on Pi">Run on Pi</button></div></article>`).join('')}</div></section>
    <section class="panel"><h2>Input labels</h2><p>Labels belong to this preset. Computer-facing USB channel names remain 1–16.</p><div class="table-scroll"><table><thead><tr><th>Input</th><th>Label</th></tr></thead><tbody>${config.inputs.map((v,i)=>`<tr><td>${pad(i)}</td><td><input data-input="${i}" data-param="label" aria-label="Input ${i+1} label" maxlength="64" value="${esc(v.label)}" required></td></tr>`).join('')}</tbody></table></div></section>
    <section class="panel"><h2>Operating modes</h2><p><strong>Direct bridge</strong> retains the existing bidirectional USB ↔ AoIP path. Its timing profile stays independent of DSP presets.</p><p><strong>DSP processor</strong> takes one 16-channel source bank, redirects bass, applies output correction, and sends 16 channels to AoIP.</p><p>In AoIP source mode, USB is not part of the signal path. The eventual processor must be able to run without a connected USB host.</p><p>Network stream subscriptions and device settings require the future backend. Native Dante control is outside this UI; the current transport uses AES67 interoperability.</p></section></div>`;
  renderLogView();
}

function renderLogView() {
  const snapshot=logSnapshots[logService],lines=snapshot?snapshot.split(/\r?\n/):[];
  const visible=lines.filter(line=>line.toLowerCase().includes(logQuery.toLowerCase()));
  $('#log-output').textContent=!snapshot?'No live logs available.\nConnect the Pi backend or paste a journal snapshot above.':visible.length?visible.join('\n'):'No lines match this filter.';
  $('#log-count').textContent=snapshot?`Pasted snapshot · ${visible.length} of ${lines.length} lines · Not live`:'No snapshot loaded';
}

async function copyCommand(command) {
  try {await navigator.clipboard.writeText(command);toast('Command copied. Run it in a terminal on the Pi.');}
  catch {toast('Clipboard unavailable. Select and copy the displayed command.');}
}

function refreshSumBounds() {
  const subs = config.outputs.map((o,i)=>({o,i})).filter(({o})=>o.role==='sub');
  document.querySelectorAll('.sub-sum').forEach((label,n)=>{
    const value = subSumBoundDb(config,subs[n].i);
    label.textContent = `Sum bound: ${Number.isFinite(value) ? `${value.toFixed(1)} dBFS` : 'silent'}`;
  });
}

document.addEventListener('click', event => {
  const b = event.target.closest('button'); if (!b || b.disabled || b.closest('fieldset:disabled')) return;
  if (b.dataset.bandReset !== undefined) {
    if (config.mode === 'direct') return;
    const index = Number(b.dataset.bandReset);
    config.outputs[selected].bands[index] = resetBand(config.outputs[selected].bands[index], index);
    selectedBand = index;
    markDraft();
    renderSelectedBand();
    drawEq();
    return;
  }
  if (b.dataset.eqNode!==undefined) {selectedBand=Number(b.dataset.eqNode);renderSelectedBand();drawEq();return;}
  if (b.dataset.copyCommand) {const command=SERVICE_COMMANDS.find(c=>c.id===b.dataset.copyCommand);if(command)copyCommand(command.command);return;}
  if (b.dataset.action==='copy-journal') {copyCommand(journalCommand(logService));return;}
  if (b.dataset.tab) { tab = b.dataset.tab; render(); return; }
  if (b.dataset.select !== undefined) { selected = Number(b.dataset.select); renderBank(); renderInspector(); updateMeters(); return; }
  if (b.id === 'meter-toggle') { metersRunning = !metersRunning; b.textContent = metersRunning ? 'Pause demo meters' : 'Resume demo meters'; updateMeters(); return; }
  if (b.dataset.mode) { config.mode = b.dataset.mode; markDraft(); render(); return; }
  if (b.dataset.source) { config.source = b.dataset.source; markDraft(); render(); return; }
  if (b.dataset.mute !== undefined) { const o = config.outputs[Number(b.dataset.mute)]; o.mute = !o.mute; markDraft(); render(); return; }
  const action = b.dataset.action;
  if (action === 'bus-add-headphones') { try { const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null); let n=0,id='headphones'; while(config.buses.some(v=>v.id===id)){n++;id=`headphones-${n+1}`;} config=createHeadphoneBus(config,id,free.slice(-2)); markDraft(); render(); toast('Headphones bus added on two free outputs.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-add-speakers') { try { const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null); if(free.length<2) throw new Error('At least two free outputs are required'); let n=1,id='speakers-2'; while(config.buses.some(v=>v.id===id)){n++;id=`speakers-${n}`;} config=createSpeakerBus(config,id,free.slice(0,2),'stereo'); markDraft(); render(); toast('Speaker bus added on two free outputs.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-remove') { try { config=removeBus(config,b.dataset.busId); busUndo=null; markDraft(); render(); toast('Bus removed; its outputs are available.'); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-apply') { try { const bus=getBus(config,b.dataset.busId), layoutId=document.querySelector(`[data-bus="${CSS.escape(bus.id)}"][data-bus-param="layout"]`).value, layout=LAYOUTS.find(v=>v.id===layoutId); if(!layout) throw new Error('Choose an output format'); const free=config.outputs.map((o,i)=>o.busId===null?i:null).filter(i=>i!==null), need=Math.max(0,layout.routing.length-bus.outputIds.length), ids=[...bus.outputIds,...free.slice(0,need)], touched=[...new Set([...bus.outputIds,...ids])], snapshot={busId:bus.id,bus:structuredClone(bus),outputs:Object.fromEntries(touched.map(i=>[i,structuredClone(config.outputs[i])])),sendColumns:Object.fromEntries(touched.map(i=>[i,config.sends.map(row=>row[i])]))}, next=applyBusLayout(config,bus.id,layoutId,ids); busUndo=snapshot; config=next; markDraft(); render(); toast(`${bus.label} format applied to its bus.`); } catch(e) { toast(e.message); } return; }
  if (action === 'bus-undo' && busUndo) { try { const saved=busUndo,result=structuredClone(config),bus=getBus(result,saved.busId); for(const i of Object.keys(saved.outputs)){const owner=result.outputs[i].busId;if(owner!==saved.busId && owner!==null) throw new Error(`Output ${Number(i)+1} was claimed by another bus; undo skipped`);} Object.assign(bus,saved.bus); Object.keys(saved.outputs).forEach(i=>{result.outputs[i]=saved.outputs[i]; saved.sendColumns[i].forEach((v,row)=>{result.sends[row][i]=v;});}); validateConfig(result); config=result; busUndo=null; markDraft(); render(); toast('Last bus format undone; unrelated buses preserved.'); } catch(e) { toast(e.message); } return; }
  if (action === 'crossover-apply') {
    const input=$('#crossover-hz');
    if(!input.reportValidity()) return;
    try {
      const targets=crossoverTargets();
      config=applyCrossover(config,targets,Number(input.value));
      crossoverHz=input.value; markDraft(); renderBass();
      toast(`Crossover set to ${crossoverHz} Hz for ${targets.length} channels. Individual edits remain available.`);
    } catch(e) {toast(e.message);}
    return;
  }
  if (action === 'layout-apply') {
    try {
      const next=applyLayout(config,$('#output-format').value);
      layoutUndo=structuredClone({outputs:config.outputs,sends:config.sends,bassEnabled:config.bassEnabled});
      config=next; selected=0; toast('Output format applied to draft. Undo format restores the previous outputs.');
    } catch(e) {toast(e.message);return;}
  } else if (action === 'layout-undo') {
    if(!layoutUndo)return; Object.assign(config,structuredClone(layoutUndo)); layoutUndo=null;selected=0;
  } else if (action === 'channel-copy') {
    channelClipboard=copyChannel(config.outputs[selected]);renderInspector();toast(`Copied ${channelClipboard.label}.`);return;
  } else if (action === 'channel-paste') {
    try {config=pasteChannel(config,selected,channelClipboard,pasteScope);toast(`Pasted ${pasteScope==='eq'?'EQ':'output processing'} into ${config.outputs[selected].label}.`);} catch(e){toast(e.message);return;}
  } else if (action === 'rew-open') {
    rewParsed=null;$('#rew-text').value='';$('#rew-file').value='';$('#rew-result').textContent='';$('#rew-apply').disabled=true;
    $('#rew-target').textContent=`Output ${selected+1} · ${config.outputs[selected].label}`;$('#rew-dialog').showModal();return;
  } else if (action === 'rew-close') {$('#rew-dialog').close();return;}
  else if (action === 'rew-apply') {
    if(!rewParsed)return;
    config.outputs[selected].bands=structuredClone(rewParsed.bands);config.outputs[selected].eqEnabled=true;
    $('#rew-dialog').close();toast(`Imported ${rewParsed.count} REW filters into ${config.outputs[selected].label}.`);
  } else if (action === 'polarity') config.outputs[selected].invert = !config.outputs[selected].invert;
  else if (action === 'eq-toggle') config.outputs[selected].eqEnabled = !config.outputs[selected].eqEnabled;
  else if (action === 'save') {
    try { validateConfig(config); const saved = presets(); Object.defineProperty(saved,config.name,{value:structuredClone(config),enumerable:true,configurable:true,writable:true}); localStorage.setItem(storageKey,JSON.stringify(saved)); dirty = false; render(); toast('Preset saved in this browser.'); } catch(e) { toast(`Could not save: ${e.message}`); } return;
  } else if (action === 'load') {
    try { config = parsePreset(JSON.stringify(presets()[$('#saved-preset').value])); layoutUndo=null; busUndo=null; dirty = false; render(); toast('Local preset loaded. No device changes.'); } catch(e) { toast(`Could not load: ${e.message}`); } return;
  } else if (action === 'reset') { config = createConfig(); selected = 0; layoutUndo=null; busUndo=null; }
  else if (action === 'export') {
    const url = URL.createObjectURL(new Blob([JSON.stringify(config,null,2)],{type:'application/json'}));
    const a = document.createElement('a'); a.href = url; a.download = 'usb16x16-ui-preset.json'; a.click(); setTimeout(()=>URL.revokeObjectURL(url),1000); toast('Exported a UI preset, not a device configuration.'); return;
  } else return;
  markDraft(); render();
});

function previewRew() {
  try {
    rewParsed=parseRew($('#rew-text').value);$('#rew-apply').disabled=false;
    $('#rew-result').textContent=`${rewParsed.count} filters ready. ${rewParsed.skipped} off/unused rows skipped. Remaining bands will be disabled.`;
  } catch(e) {rewParsed=null;$('#rew-apply').disabled=true;$('#rew-result').textContent=e.message;}
}
document.addEventListener('input',event=>{
  if(event.target.id==='rew-text')previewRew();
  if(event.target.id==='crossover-hz')crossoverHz=event.target.value;
  if(event.target.id==='log-filter'){logQuery=event.target.value;renderLogView();}
  if(event.target.id==='log-paste'){logSnapshots[logService]=event.target.value.slice(0,200000);renderLogView();}
});
let rewFileRead=0;

document.addEventListener('change', async event => {
  const el = event.target;
  if(el.id==='log-service'){logService=el.value;$('#journal-command').textContent=journalCommand(logService);$('#log-paste').value=logSnapshots[logService];renderLogView();return;}
  if(el.id==='log-filter'||el.id==='log-paste')return;
  if (el.id === 'saved-preset'||el.id==='rew-text') return;
  if (el.id==='output-format') {document.querySelector('[data-action="layout-apply"]').disabled=el.value==='custom'||config.mode==='direct';return;}
  if (el.id==='paste-scope') {pasteScope=el.value;return;}
  if (el.id==='rew-file') {
    const read=++rewFileRead;
    try {
      const file=el.files[0];if(!file)return;if(file.size>200000)throw new Error('REW text must be under 200 KB');
      const content=await file.text();if(read!==rewFileRead)return;
      $('#rew-text').value=content;previewRew();
    }catch(e){rewParsed=null;$('#rew-apply').disabled=true;$('#rew-result').textContent=e.message;}
    return;
  }
  if (el.id === 'import-preset') {
    try { const file = el.files[0]; if (!file) return; if (file.size>200000) throw new Error('Preset is too large'); const imported = parsePreset(await file.text()); config = imported; selected = 0; layoutUndo=null; busUndo=null; markDraft(); render(); toast('UI preset imported into the local draft.'); } catch(e) { toast(`Import rejected: ${e.message}`); el.value = ''; } return;
  }
  if (el.disabled || el.closest('fieldset:disabled')) return;
  if(el.id==='eq-band-select'){selectedBand=Number(el.value);renderSelectedBand();$('#eq-band-select').focus({preventScroll:true});drawEq();return;}
  if(el.id==='out-destination') {
    try {
      const destination=Number(el.value), previous=selected;
      config=swapOutputs(config,previous,destination);selected=destination;markDraft();render();
      toast(`Outputs ${previous+1} and ${destination+1} swapped, including processing and bass routes.`);
    } catch(e) {toast(e.message);renderInspector();}
    return;
  }
  if(el.id==='crossover-hz') return;
  if (el.dataset.headphoneMode) { try { config=setHeadphoneMode(config,el.dataset.headphoneMode,el.value); markDraft(); render(); } catch(e) { toast(e.message); render(); } return; }
  if (el.dataset.headphonePair) { try { const bus=getBus(config,el.dataset.headphonePair), pair=[...bus.inputPair]; pair[Number(el.dataset.ear)]=Number(el.value); config=setHeadphonePair(config,bus.id,pair); markDraft(); } catch(e) { toast(e.message); } return; }
  if (el.dataset.downmix) { const bus=getBus(config,el.dataset.downmix), i=Number(el.dataset.inputIndex), ear=Number(el.dataset.ear); try { if(el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.'); const matrix=structuredClone(bus.downmixMatrix); matrix[i][ear]=el.value===''?null:Number(el.value); config=setHeadphoneMatrix(config,bus.id,matrix); markDraft(); } catch(e) { el.value=bus.downmixMatrix[i][ear]??''; toast(e.message); } return; }
  if (el.dataset.bus) { const bus=getBus(config,el.dataset.bus), key=el.dataset.busParam; try { if(el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.'); const value=el.type==='checkbox'?el.checked:el.type==='number'?Number(el.value):el.value; if(key==='label'){const next=structuredClone(config);getBus(next,bus.id).label=value;validateConfig(next);config=next;markDraft();renderBuses();} else if(key==='gainDb'||key==='mute'){config=setBusGainMute(config,bus.id,key==='gainDb'?value:bus.gainDb,key==='mute'?value:bus.mute);markDraft();if(key==='gainDb')refreshSumBounds();} } catch(e) { if(key==='gainDb') el.value=bus.gainDb; else if(key==='mute') el.checked=bus.mute; else if(key==='label') el.value=bus.label; toast(e.message); } return; }
  if(el.id==='crossover-scope') {crossoverScope=el.value;refreshCrossoverControls();return;}
  if(el.dataset.crossoverSelect!==undefined||el.id==='crossover-select-all') {
    if(el.id==='crossover-select-all') {
      crossoverSelection.clear();
      if(el.checked) config.inputs.forEach((_,i)=>{if(i!==config.lfe.input)crossoverSelection.add(i);});
      document.querySelectorAll('[data-crossover-select]').forEach(input=>{input.checked=el.checked;});
    } else {
      const i=Number(el.dataset.crossoverSelect);
      if(el.checked)crossoverSelection.add(i);else crossoverSelection.delete(i);
    }
    crossoverScope='selected';refreshCrossoverControls();return;
  }
  const before = structuredClone(config), id = el.id;
  try {
    if (el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.');
    const value = el.type==='checkbox' ? el.checked : el.type==='number' ? Number(el.value) : el.value;
    if (el.dataset.out) {
      const key = el.dataset.out;
      if (key==='role') setOutputRole(config,selected,value);
      else { config.outputs[selected][key] = key==='source' ? Number(value) : value; if(key==='source' && config.outputs[selected].busId) { const owner=config.buses.find(b=>b.id===config.outputs[selected].busId); if(owner) owner.layoutId='custom'; } }
    } else if (el.dataset.band !== undefined) config.outputs[selected].bands[Number(el.dataset.band)][el.dataset.param] = value;
    else if (el.dataset.input !== undefined) config.inputs[Number(el.dataset.input)][el.dataset.param] = el.dataset.param==='slope' ? Number(value) : value;
    else if (el.dataset.lfe) {
      if (el.dataset.lfe==='input') { config.sends[config.lfe.input].fill(null); config.sends[Number(value)].fill(null); }
      config.lfe[el.dataset.lfe] = Number(value);
    } else if (el.dataset.send) { const [i,j] = el.dataset.send.split(',').map(Number); config.sends[i][j] = value ? 0 : null; }
    else if (el.dataset.sendGain) { const [i,j] = el.dataset.sendGain.split(',').map(Number); config.sends[i][j] = value; }
    else if (id==='headroom') config.headroomDb = value;
    else if (id==='bass-enabled') config.bassEnabled = value;
    else if (id==='preset-name') config.name = value;
    else return;
    validateConfig(config); markDraft();
  } catch(e) {
    config = before; toast(e.message);
    const aria = el.getAttribute('aria-label'); render();
    const focus = id ? document.getElementById(id) : aria ? [...document.querySelectorAll('[aria-label]')].find(e=>e.getAttribute('aria-label')===aria) : null;
    if (focus && !focus.disabled) focus.focus({preventScroll:true});
    return;
  }
  // Keep the form being edited mounted: replacing it on blur can swallow the
  // next click or send keyboard focus back to the field the user just left.
  if (el.dataset.out) {
    renderLayout(); renderBank(); renderBass(); renderSettings();
    if (el.dataset.out==='role') { renderInspector(); renderBuses(); }
    else {
      $('#inspector h2').innerHTML = `<span class="badge">${pad(selected)}</span>${esc(config.outputs[selected].label)}`;
      $('#out-destination').options[selected].textContent=`${pad(selected)} · ${config.outputs[selected].label}`;
      if (el.dataset.out==='source') renderBuses();
    }
  } else if (el.dataset.band !== undefined) {
    if(selectedBand!==Number(el.dataset.band)){selectedBand=Number(el.dataset.band);renderSelectedBand();}
    drawEq();
  } else if (el.dataset.input !== undefined) {
    if (el.dataset.param==='label') { renderBank(); renderInspector(); renderBass(); renderBuses(); }
    else if (el.dataset.param==='crossover') renderBass();
  } else if (el.dataset.lfe) {
    if (el.dataset.lfe==='input') renderBass();
    else {
      const row = document.querySelector('.lfe-row');
      if (row) { row.cells[3].textContent=`${config.lfe.lowpassHz} Hz`; row.cells[4].textContent=`${config.lfe.slope} dB/oct`; }
      refreshSumBounds();
    }
  } else if (el.dataset.send || id==='bass-enabled') renderBass();
  else if (el.dataset.sendGain || id==='headroom') refreshSumBounds();
});

function updateMeters() {
  if (document.hidden || tab!=='outputs') return;
  const t = performance.now()/1000;
  config.outputs.forEach((o,i)=>{
    const bus = config.buses?.find(b=>b.id===o.busId);
    const quiet = !metersRunning || (config.mode==='dsp' && (o.role==='unused'||o.mute||bus?.mute));
    // Deliberately synthetic display activity, never represented as a DSP/audio simulation.
    const db = quiet ? -60 : -25 + 8*Math.sin(t*1.4+i*.67) + 3*Math.sin(t*3.1+i);
    const bar = $(`#meter-${i}`), label = $(`#level-${i}`);
    if (bar) bar.style.setProperty('--level',`${Math.max(0,(db+60)/60*100)}%`);
    if (label) label.textContent = quiet ? '—' : db.toFixed(1);
  });
  if ($('#input-meters').open) config.inputs.forEach((o,i)=>{
    const db = metersRunning ? -29+9*Math.sin(t*1.2+i*.6) : -60;
    $(`#input-meter-${i}`).style.setProperty('--level',`${Math.max(0,(db+60)/60*100)}%`);
    $(`#input-level-${i}`).textContent = metersRunning ? db.toFixed(1) : '—';
  });
}
$('.brand').addEventListener('click',event=>{event.preventDefault(); tab='outputs';render();});
render();
setInterval(updateMeters,100);
