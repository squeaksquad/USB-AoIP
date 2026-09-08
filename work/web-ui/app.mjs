import { createConfig, validateConfig, parsePreset, setOutputRole, eqResponse, subSumBoundDb } from './model.mjs';
import { LAYOUTS, currentLayout, applyLayout, copyChannel, pasteChannel, parseRew } from './workflows.mjs';

let config = createConfig(), selected = 0, tab = 'outputs', metersRunning = true, dirty = true;
let channelClipboard = null, pasteScope = 'processing', layoutUndo = null, rewParsed = null;
const storageKey = 'usb16x16-design-presets-v1';
const $ = selector => document.querySelector(selector);
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pad = i => String(i + 1).padStart(2, '0');
const checked = v => v ? 'checked' : '';
const disabled = v => v ? 'disabled' : '';
const options = (items, value) => items.map(([v, label]) => `<option value="${esc(v)}" ${String(v) === String(value) ? 'selected' : ''}>${esc(label)}</option>`).join('');
const number = (attrs, value, min, max, step = 1) => `<input type="number" ${attrs} value="${value}" min="${min}" max="${max}" step="${step}" required>`;
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
  renderLayout(); renderBank(); renderInspector(); renderBass(); renderSettings(); updateMeters();
}

function renderLayout() {
  const current=currentLayout(config);
  $('#layout-controls').innerHTML=`<div class="layout-row">${field('Output format',`<select id="output-format" ${disabled(config.mode==='direct')}>${options([['custom','Custom'],...LAYOUTS.map(v=>[v.id,v.label])],current)}</select>`)}<button data-action="layout-apply" ${disabled(config.mode==='direct'||current==='custom')}>Apply format</button><button class="quiet" data-action="layout-undo" ${disabled(!layoutUndo||config.mode==='direct')}>Undo format</button><small>Sets output labels, assignments and bass sends; resets output processing. Input order stays unchanged. Use output roles for a custom layout.</small></div>`;
}

function renderBank() {
  $('#input-bank').innerHTML = config.inputs.map((o,i)=>`<div class="strip"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="meter" aria-hidden="true" style="display:block"><i id="input-meter-${i}"></i></span><span id="input-level-${i}" class="meter-value">—</span></div>`).join('');
  $('#channel-bank').innerHTML = config.outputs.map((o, i) => `<div class="strip ${o.role} ${i === selected ? 'selected' : ''}">
    <button class="strip-select" data-select="${i}" aria-label="Edit output ${i + 1}: ${esc(o.label)}" aria-pressed="${i === selected}"><span class="channel-number">${pad(i)}</span><strong class="channel-name">${esc(o.label)}</strong><span class="role-label">${o.role === 'unused' ? 'SPARE' : o.role.toUpperCase()}</span><span class="meter" aria-hidden="true" style="display:block"><i id="meter-${i}"></i></span><span id="level-${i}" class="meter-value">—</span></button>
    <button class="mute" data-mute="${i}" aria-label="Mute output ${i + 1}" aria-pressed="${o.mute}" ${disabled(config.mode === 'direct' || o.role === 'unused')}>M</button></div>`).join('');
}

function renderInspector() {
  const o = config.outputs[selected], off = config.mode === 'direct';
  $('#inspector').innerHTML = `<div class="inspector-head"><div><h2><span class="badge">${pad(selected)}</span>${esc(o.label)}</h2><p>AoIP output ${selected + 1} · ${o.role === 'sub' ? 'Independent subwoofer correction' : o.role === 'unused' ? 'Assign a role to use this output' : 'Independent speaker correction'}</p></div><span class="overline">OUTPUT PROCESSING</span></div>
    <fieldset ${disabled(off)} style="border:0;padding:0;margin:0;min-width:0">
    <div class="channel-tools"><button data-action="channel-copy">Copy channel</button><label class="field"><span>Paste scope</span><select id="paste-scope">${options([['processing','All output processing'],['eq','EQ only']],pasteScope)}</select></label><button data-action="channel-paste" ${disabled(!channelClipboard)}>Paste${channelClipboard?` from ${esc(channelClipboard.label)}`:''}</button><button data-action="rew-open">Import REW EQ</button><small>Copies EQ, gain, delay, mute and polarity. Destination label and routing stay unchanged.</small></div>
    <div class="output-controls">
      ${field('Output label', `<input id="out-label" data-out="label" value="${esc(o.label)}" maxlength="64" required>`)}
      ${field('Output role', `<select id="out-role" data-out="role">${options([['speaker','Speaker'],['sub','Subwoofer'],['unused','Unused']],o.role)}</select>`)}
      ${field('Speaker source', `<select id="out-source" data-out="source" ${disabled(o.role !== 'speaker')}>${options(inputOptions(),o.source)}</select>`)}
      ${field('Gain · dB', number('id="out-gain" data-out="gainDb"',o.gainDb,-60,12,.1))}
      ${field('Alignment · ms', number('id="out-delay" data-out="delayMs"',o.delayMs,0,10,.01))}
      <div class="toolbar"><button data-action="polarity" aria-pressed="${o.invert}" title="Invert output polarity">Ø Invert</button><button data-mute="${selected}" aria-pressed="${o.mute}">Mute</button></div>
    </div>
    <div class="eq-title"><div><h3>Parametric EQ <span class="muted">/ 16 bands</span></h3><p>Calculated PEQ response only · excludes crossovers, output gain and room response</p></div><button class="quiet" data-action="eq-toggle" aria-pressed="${o.eqEnabled}">${o.eqEnabled ? 'EQ enabled' : 'EQ bypassed'}</button></div>
    <svg id="eq-chart" class="eq-chart" viewBox="0 0 1000 190" role="img" aria-label="Calculated output PEQ magnitude response, 20 Hz to 20 kHz"></svg>
    <div class="table-scroll"><table class="band-table"><thead><tr><th>Band</th><th>On</th><th>Filter</th><th>Frequency · Hz</th><th>Gain · dB</th><th>Q</th></tr></thead><tbody>${o.bands.map((b,i) => `<tr class="${b.enabled ? '' : 'band-disabled'}"><td>${pad(i)}</td><td><input type="checkbox" data-band="${i}" data-param="enabled" aria-label="Band ${i+1} enabled" ${checked(b.enabled)}></td><td><select data-band="${i}" data-param="type" aria-label="Band ${i+1} filter">${options([['bell','Bell'],['lowShelf','Low shelf'],['highShelf','High shelf']],b.type)}</select></td><td>${number(`data-band="${i}" data-param="frequency" aria-label="Band ${i+1} frequency"`,b.frequency,20,20000,'any')}</td><td>${number(`data-band="${i}" data-param="gainDb" aria-label="Band ${i+1} gain"`,b.gainDb,-18,18,'any')}</td><td>${number(`data-band="${i}" data-param="q" aria-label="Band ${i+1} Q"`,b.q,.1,18,'any')}</td></tr>`).join('')}</tbody></table></div>
    </fieldset>`;
  drawEq();
}

function drawEq() {
  const o = config.outputs[selected], x = f => 43 + Math.log10(f/20)/3 * 935, y = g => 85 - Math.max(-24,Math.min(24,g))*2.7;
  const frequencies = [20,50,100,200,500,1000,2000,5000,10000,20000];
  const grid = [-24,-12,0,12,24].map(g => `<line x1="43" y1="${y(g)}" x2="978" y2="${y(g)}" class="${g === 0 ? 'eq-zero' : 'eq-grid'}"/><text x="4" y="${y(g)+4}" class="eq-label">${g > 0 ? '+' : ''}${g}</text>`).join('') + frequencies.map(f => `<line x1="${x(f)}" y1="20" x2="${x(f)}" y2="150" class="eq-grid"/><text x="${x(f)}" y="177" text-anchor="middle" class="eq-label">${f>=1000 ? `${f/1000}k` : f}</text>`).join('');
  const points = Array.from({length:401},(_,i) => { const f = 20*1000**(i/400); return `${x(f).toFixed(2)},${y(eqResponse(o,f)).toFixed(2)}`; });
  $('#eq-chart').innerHTML = `<defs><linearGradient id="eq-shade" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#8bdeca" stop-opacity=".12"/><stop offset="1" stop-color="#8bdeca" stop-opacity="0"/></linearGradient></defs>${grid}<path d="M43,150 L${points.join(' L')} L978,150 Z" class="eq-fill"/><path d="M${points.join(' L')}" class="eq-curve"/>${o.eqEnabled ? o.bands.filter(b=>b.enabled).map(b=>`<circle cx="${x(b.frequency)}" cy="${y(eqResponse(o,b.frequency))}" r="3.5" class="eq-dot"/>`).join('') : ''}`;
}

function renderBass() {
  const subs = config.outputs.map((o,i)=>({...o,index:i})).filter(o=>o.role==='sub');
  const slopeOptions = value => options([[12,'LR · 12 dB/oct'],[24,'LR · 24 dB/oct'],[48,'LR · 48 dB/oct']],value);
  $('#bass-page').innerHTML = `<fieldset ${disabled(config.mode==='direct')} style="border:0;padding:0;margin:0;min-width:0">
    <div class="bass-top"><section class="panel"><h2>Speaker bass redirection</h2><p>High-pass each main speaker and send its low frequencies to your chosen subs. Output EQ and alignment follow the split.</p><div class="field-row"><label class="checkbox-label"><input type="checkbox" id="bass-enabled" ${checked(config.bassEnabled)}>Bass redirection enabled</label>${field('Common input trim · dB',number('id="headroom"',config.headroomDb,-36,0,.1))}</div><p>Turning redirection off restores full-range mains and silences their sub sends. LFE remains independently routed.</p></section>
    <section class="panel"><h2>LFE is its own source</h2><p>Control the effects channel separately from redirected speaker bass. LFE gain is explicit; no automatic +10 dB boost.</p><div class="field-row">${field('LFE input',`<select data-lfe="input">${options(inputOptions(),config.lfe.input)}</select>`)}${field('Low-pass · Hz',number('data-lfe="lowpassHz"',config.lfe.lowpassHz,20,250))}${field('Slope',`<select data-lfe="slope">${slopeOptions(config.lfe.slope)}</select>`)}${field('LFE trim · dB',number('data-lfe="trimDb"',config.lfe.trimDb,-24,12,.1))}</div></section></div>
    <section class="panel"><div class="section-heading"><div><h2>Bass routing matrix</h2><p>${subs.length} subwoofer output${subs.length===1?'':'s'} within the 16-channel output bank. Enable a send, then set its gain.</p></div></div>
    ${subs.length ? `<div class="table-scroll"><table class="matrix"><thead><tr><th>Source</th><th>HP on</th><th>Speaker HP · Hz</th><th>Bass LP · Hz</th><th>Slope</th>${subs.map(o=>`<th class="matrix-head">${pad(o.index)} · ${esc(o.label)}<small class="sub-sum">Sum bound: ${Number.isFinite(subSumBoundDb(config,o.index)) ? `${subSumBoundDb(config,o.index).toFixed(1)} dBFS` : 'silent'}</small></th>`).join('')}</tr></thead><tbody>${config.inputs.map((v,i)=>{
      const lfe = i === config.lfe.input;
      return `<tr class="${lfe?'lfe-row':''}"><td><strong>${pad(i)} · ${esc(v.label)}</strong>${lfe?' <small>LFE</small>':''}</td><td>${lfe?'—':`<input type="checkbox" data-input="${i}" data-param="crossover" aria-label="${esc(v.label)} high-pass enabled" ${checked(v.crossover)} ${disabled(!config.bassEnabled)}>`}</td><td>${lfe?'—':number(`data-input="${i}" data-param="highpassHz" aria-label="${esc(v.label)} high-pass frequency" ${disabled(!config.bassEnabled||!v.crossover)}`,v.highpassHz,20,250)}</td><td>${lfe?`${config.lfe.lowpassHz} Hz`:number(`data-input="${i}" data-param="lowpassHz" aria-label="${esc(v.label)} bass low-pass frequency" ${disabled(!config.bassEnabled)}`,v.lowpassHz,20,250)}</td><td>${lfe?`${config.lfe.slope} dB/oct`:`<select data-input="${i}" data-param="slope" aria-label="${esc(v.label)} crossover slope" ${disabled(!config.bassEnabled)}>${slopeOptions(v.slope)}</select>`}</td>${subs.map(o=>{
        const gain = config.sends[i][o.index], inactive = !lfe && !config.bassEnabled;
        const name = `${v.label} to ${o.label}`;
        return `<td><div class="send-cell"><input type="checkbox" data-send="${i},${o.index}" aria-label="Enable ${esc(name)}" ${checked(gain!==null)} ${disabled(inactive)}>${number(`data-send-gain="${i},${o.index}" aria-label="${esc(name)} gain" ${disabled(gain===null||inactive)}`,gain??0,-60,12,.1)}<small>dB</small></div></td>`;
      }).join('')}</tr>`;
    }).join('')}</tbody></table></div>` : '<div class="empty"><h3>No subwoofer outputs assigned</h3><p>In Outputs, select any channel and change its role to Subwoofer.</p></div>'}
    <p class="route-note">HP off keeps a main full-range while retaining its bass send. New sub outputs start with all sends off. Sum bounds assume coherent full-scale inputs and include input trim, send gain, LFE trim, and output gain; they exclude filters and EQ, and are not measured peaks.</p>
    <p class="route-note">Changing the LFE input clears all sub sends from the old and new LFE rows, so those routes must be deliberately reassigned.</p></section></fieldset>`;
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
    <section class="panel"><h2>Input labels</h2><p>Labels belong to this preset. Computer-facing USB channel names remain 1–16.</p><div class="table-scroll"><table><thead><tr><th>Input</th><th>Label</th></tr></thead><tbody>${config.inputs.map((v,i)=>`<tr><td>${pad(i)}</td><td><input data-input="${i}" data-param="label" aria-label="Input ${i+1} label" maxlength="64" value="${esc(v.label)}" required></td></tr>`).join('')}</tbody></table></div></section>
    <section class="panel"><h2>Operating modes</h2><p><strong>Direct bridge</strong> retains the existing bidirectional USB ↔ AoIP path. Its timing profile stays independent of DSP presets.</p><p><strong>DSP processor</strong> takes one 16-channel source bank, redirects bass, applies output correction, and sends 16 channels to AoIP.</p><p>In AoIP source mode, USB is not part of the signal path. The eventual processor must be able to run without a connected USB host.</p><p>Network stream subscriptions and device settings require the future backend. Native Dante control is outside this UI; the current transport uses AES67 interoperability.</p></section></div>`;
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
  if (b.dataset.tab) { tab = b.dataset.tab; render(); return; }
  if (b.dataset.select !== undefined) { selected = Number(b.dataset.select); renderBank(); renderInspector(); updateMeters(); return; }
  if (b.id === 'meter-toggle') { metersRunning = !metersRunning; b.textContent = metersRunning ? 'Pause demo meters' : 'Resume demo meters'; updateMeters(); return; }
  if (b.dataset.mode) { config.mode = b.dataset.mode; markDraft(); render(); return; }
  if (b.dataset.source) { config.source = b.dataset.source; markDraft(); render(); return; }
  if (b.dataset.mute !== undefined) { const o = config.outputs[Number(b.dataset.mute)]; o.mute = !o.mute; markDraft(); render(); return; }
  const action = b.dataset.action;
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
    try { config = parsePreset(JSON.stringify(presets()[$('#saved-preset').value])); layoutUndo=null; dirty = false; render(); toast('Local preset loaded. No device changes.'); } catch(e) { toast(`Could not load: ${e.message}`); } return;
  } else if (action === 'reset') { config = createConfig(); selected = 0; layoutUndo=null; }
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
document.addEventListener('input',event=>{if(event.target.id==='rew-text')previewRew();});
let rewFileRead=0;

document.addEventListener('change', async event => {
  const el = event.target;
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
    try { const file = el.files[0]; if (!file) return; if (file.size>200000) throw new Error('Preset is too large'); const imported = parsePreset(await file.text()); config = imported; selected = 0; layoutUndo=null; markDraft(); render(); toast('UI preset imported into the local draft.'); } catch(e) { toast(`Import rejected: ${e.message}`); el.value = ''; } return;
  }
  if (el.disabled || el.closest('fieldset:disabled')) return;
  const before = structuredClone(config), id = el.id;
  try {
    if (el.checkValidity && !el.checkValidity()) throw new Error('Enter a value within the displayed limits.');
    const value = el.type==='checkbox' ? el.checked : el.type==='number' ? Number(el.value) : el.value;
    if (el.dataset.out) {
      const key = el.dataset.out;
      if (key==='role') setOutputRole(config,selected,value);
      else config.outputs[selected][key] = key==='source' ? Number(value) : value;
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
    if (el.dataset.out==='role') renderInspector();
    else $('#inspector h2').innerHTML = `<span class="badge">${pad(selected)}</span>${esc(config.outputs[selected].label)}`;
  } else if (el.dataset.band !== undefined) {
    el.closest('tr').classList.toggle('band-disabled',!config.outputs[selected].bands[Number(el.dataset.band)].enabled); drawEq();
  } else if (el.dataset.input !== undefined) {
    if (el.dataset.param==='label') { renderBank(); renderInspector(); renderBass(); }
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
    const quiet = !metersRunning || (config.mode==='dsp' && (o.role==='unused'||o.mute));
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
