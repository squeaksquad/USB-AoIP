// Client half of the Pi control service (work/web-control/usb16x16-web).
//
// The page runs unchanged with no backend: every probe failure leaves the UI in
// its prototype state rather than showing a blank or an invented value. When the
// service answers, live facts replace the "Not connected" placeholders and
// presets move from browser storage to the Pi.
//
// Formatting is pure and exported so it can be tested without a browser.

export const HEALTH_PATH = '/api/health';
export const POLL_MS = 2000;
// The bridge's meter tap (2026-09-11): one window every 50 ms on the Pi, read
// at up to 10 Hz while the Outputs page is visible. Absent or stale, the page
// draws its synthetic display activity, labelled as such.
export const METERS_PATH = '/api/meters';
export const METER_POLL_MS = 100;

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);

/** Read a health snapshot, or null when no backend is reachable. */
export async function probeHealth(fetchImpl = globalThis.fetch, signal) {
  try {
    const response = await fetchImpl(HEALTH_PATH, { signal, headers: { accept: 'application/json' } });
    if (!response.ok) return null;
    const body = await response.json();
    return isObject(body) && body.ok === true ? body : null;
  } catch { return null; }
}

/** The bridge's latest meter window, or null when no tap is available. */
export async function fetchMeters(fetchImpl = globalThis.fetch, signal) {
  try {
    const response = await fetchImpl(METERS_PATH, { signal, headers: { accept: 'application/json' } });
    if (!response.ok) return null;
    const body = await response.json();
    return isObject(body) && body.ok === true && body.available === true ? body : null;
  } catch { return null; }
}

/**
 * The two banks the Outputs page draws, from the four stage taps: inputs are
 * what the host sends over USB, before the DSP stage; outputs are what leaves
 * on AES67, after it. Null unless both stages are present with 16 channels.
 */
export function meterLevels(meters) {
  const taps = meters?.taps;
  const inputs = taps?.['usb-capture'], outputs = taps?.['ravenna-playback'];
  const bank = tap => Array.isArray(tap?.peakDb) && tap.peakDb.length === 16
    ? tap.peakDb.map((peak, i) => ({peak, rms: tap.rmsDb?.[i] ?? null, clipped: tap.clipped?.[i] ?? 0}))
    : null;
  const ins = bank(inputs), outs = bank(outputs);
  if (!ins || !outs) return null;
  return {inputs: ins, outputs: outs, sequence: outputs.sequence ?? null,
          windowMs: meters.windowMs ?? null, ageSeconds: meters.ageSeconds ?? null};
}

export async function fetchLogs(service, lines = 200, fetchImpl = globalThis.fetch) {
  const response = await fetchImpl(`/api/logs?service=${encodeURIComponent(service)}&lines=${Number(lines) || 200}`);
  const body = await response.json().catch(() => null);
  if (!response.ok || !isObject(body) || body.ok !== true) {
    throw new Error(isObject(body) && body.error ? body.error : `Log request failed (${response.status})`);
  }
  return body.text;
}

// ------------------------------------------------------------- formatting

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '—';
  const total = Math.floor(seconds);
  const days = Math.floor(total / 86400), hours = Math.floor(total % 86400 / 3600);
  const minutes = Math.floor(total % 3600 / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m ${total % 60}s`;
  return `${total}s`;
}

const serviceWords = {active: 'running', inactive: 'stopped', failed: 'failed', activating: 'starting', deactivating: 'stopping'};
export const serviceLabel = state => serviceWords[state] || state || 'unknown';

/** The one-line connection status shown above the signal path. */
export function connectionLine(health) {
  if (!health) return 'Not connected · Local draft · Simulated meters';
  const parts = [`Connected · ${health.host || 'Pi'}`];
  parts.push(health.mode?.running ? 'Direct bridge running' : (health.mode?.detail || 'Stack state unknown'));
  const ptp = health.ptp?.status;
  if (ptp && ptp !== 'unavailable') parts.push(`PTP ${ptp}${Number.isFinite(health.ptp?.jitter) ? ` · jitter ${health.ptp.jitter}` : ''}`);
  parts.push(health.meters?.available ? 'Live meters' : 'Simulated meters');
  return parts.join(' · ');
}

/** Severity for a fact row: 'ok', 'warn', 'bad' or '' when it is neutral. */
function grade(value, good, bad) {
  if (value === undefined || value === null) return '';
  if (bad(value)) return 'bad';
  return good(value) ? 'ok' : 'warn';
}

/**
 * Rows for the System overview panel, built only from what the snapshot
 * actually carries. A missing reading reads "Unavailable", never zero.
 */
export function systemFacts(health) {
  if (!health) {
    return [
      {label: 'Connection', value: 'Not connected', state: 'warn'},
      {label: 'Control service', value: 'No backend answering on this origin'},
      {label: 'PTP / USB / queue health', value: 'Unavailable offline'},
      {label: 'Added DSP latency / CPU load', value: 'Not measured'},
    ];
  }
  const rows = [];
  const push = (label, value, state = '', title = '') => rows.push({label, value, state, title});

  push('Connection', `${health.host || 'Pi'} · service ${health.service?.version || '?'} · up ${formatDuration(health.system?.uptimeSeconds)}`, 'ok');
  push('Running mode', health.mode?.detail || 'Unknown', health.mode?.running ? 'ok' : 'warn');

  for (const [key, label] of [['gadget', 'USB gadget service'], ['aes67', 'AES67 service'], ['governor', 'Governor service']]) {
    const entry = health.services?.[key];
    if (!entry) continue;
    push(label, `${entry.unit} · ${serviceLabel(entry.state)}`, entry.state === 'active' ? 'ok' : entry.state === 'unknown' ? '' : 'bad');
  }

  const usb = health.usb;
  if (usb?.present) push('USB gadget link', `${usb.state || 'unknown'} · ${usb.speed || 'unknown'}`, usb.state === 'configured' ? 'ok' : 'warn');
  else if (usb) push('USB gadget link', 'No UDC present', 'bad');

  const ptp = health.ptp;
  if (ptp?.status === 'locked') {
    push('PTP', `locked · jitter ${ptp.jitter ?? '—'} · grandmaster ${ptp.gmid || 'unknown'}`, 'ok', ptp.gmid || '');
  } else if (ptp?.status === 'unavailable') {
    // Not the same as an unlocked clock: the daemon API did not answer, so the
    // clock state is unknown rather than known-bad.
    push('PTP', 'Unknown · the AES67 daemon API did not answer', 'warn');
  } else if (ptp?.status) {
    push('PTP', ptp.status, 'bad', ptp.gmid || '');
  }

  const net = health.network;
  if (net) {
    // A 100 Mbit fallback on this link has previously shown up as audio trouble,
    // so the expected speed is called out rather than merely displayed.
    const speed = Number.isFinite(net.speedMbit) ? `${net.speedMbit} Mbit/s` : 'unknown speed';
    push('AoIP network', net.carrier ? `${net.interface} up · ${speed}${net.address ? ` · ${net.address}` : ''}` : `${net.interface} link down`,
      !net.carrier ? 'bad' : net.speedMbit === 1000 ? 'ok' : 'warn',
      net.speedMbit !== 1000 && net.carrier ? 'Expected 1000 Mbit/s on this link' : '');
  }

  const bridge = health.bridge;
  if (bridge?.present) {
    const stale = Number.isFinite(bridge.ageSeconds) && bridge.ageSeconds > 15;
    push('Bridge telemetry', stale ? `Last line ${formatDuration(bridge.ageSeconds)} ago` : `Live · ${formatDuration(bridge.ageSeconds)} old`, stale ? 'bad' : 'ok');
    push('Clock servo', `${bridge.ppm ?? '—'} ppm · phase ${bridge.phaseErrorUs ?? '—'} µs`, '');
    push('Queue depth', `TX ${bridge.txQueue ?? '—'} / RX ${bridge.rxQueue ?? '—'} frames`, '');
    push('Queue floor', `TX ${bridge.txQueueFloor ?? '—'} / RX ${bridge.rxQueueFloor ?? '—'} frames`,
      grade(bridge.txQueueFloor, v => v > 8, v => v <= 0));
    push('PCM restarts', `TX ${bridge.txRestarts ?? '—'} / RX ${bridge.rxRestarts ?? '—'}`, '');
    push('Dropped / clipped', `${(bridge.txDropped ?? 0) + (bridge.rxDropped ?? 0)} dropped · ${(bridge.txClip ?? 0) + (bridge.rxClip ?? 0)} clipped`,
      ((bridge.txDropped ?? 0) + (bridge.rxDropped ?? 0) + (bridge.txClip ?? 0) + (bridge.rxClip ?? 0)) ? 'bad' : 'ok');
  } else {
    push('Bridge telemetry', 'No BRIDGE line yet', 'warn');
  }

  if (Number.isFinite(health.recovers)) push('Recoveries this session', String(health.recovers), health.recovers ? 'warn' : 'ok');
  if (health.stage?.text) push('Supervisor stage', `${health.stage.text}${Number.isFinite(health.stage.secondsAgo) ? ` · ${formatDuration(health.stage.secondsAgo)} ago` : ''}`, '');

  const sinks = health.streams?.sinks || [], sources = health.streams?.sources || [];
  if (sinks.length || sources.length) {
    push('AoIP streams', `${sources.length} transmit · ${sinks.length} receive`, 'ok');
    const delays = [...new Set(sinks.map(s => s.delay).filter(Number.isFinite))];
    if (delays.length) push('Sink delay', `${delays.join(' / ')} samples`, '');
  }

  const system = health.system;
  if (system) {
    if (Number.isFinite(system.tempC)) push('CPU temperature', `${system.tempC.toFixed(1)} °C`, system.tempC < 70 ? 'ok' : 'warn');
    if (system.throttled !== undefined) push('Throttling', system.throttledNow ? `Throttled now (${system.throttled})` : `None (${system.throttled})`, system.throttledNow ? 'bad' : 'ok');
    if (Array.isArray(system.load)) push('Load average', system.load.map(v => v.toFixed(2)).join(' · '), '');
  }

  push('Audio format', `${(health.audio?.sampleRate ?? 48000) / 1000} kHz · ${health.audio?.inputs ?? 16} in / ${health.audio?.outputs ?? 16} out`, '');
  push('Metering', health.meters?.available ? 'Live' : 'Simulated display activity', health.meters?.available ? 'ok' : 'warn', health.meters?.reason || '');
  push('DSP processor', health.dsp?.available ? 'Available' : 'Under development', health.dsp?.available ? 'ok' : 'warn', health.dsp?.reason || '');
  push('Added DSP latency / CPU load', 'Not measured', '');
  return rows;
}

/** What to say about DSP mode, connected or not. */
export function dspNote(health) {
  if (!health) return 'DSP processor mode is a design draft. No engine is connected.';
  const dsp = health.dsp || {};
  if (dsp.available) return 'DSP engine connected.';
  const missing = Array.isArray(dsp.missing) && dsp.missing.length ? ` Still missing: ${dsp.missing.join(', ')}.` : '';
  return `${dsp.reason || 'DSP processor mode is under development.'}${missing}${dsp.engine ? ` Engine staged on the Pi: ${dsp.engine}.` : ''}`;
}

// ---------------------------------------------------------- preset stores

/**
 * Presets live on the Pi when the backend answers and in browser storage
 * otherwise. Both stores expose the same shape, and a synchronous `cache` so
 * the existing render path can stay synchronous.
 */
export function browserStore(storageKey, storage = globalThis.localStorage) {
  const readAll = () => {
    try {
      const stored = JSON.parse(storage.getItem(storageKey) || '{}');
      return isObject(stored) ? stored : {};
    } catch { return {}; }
  };
  return {
    kind: 'browser',
    label: 'this browser',
    note: 'Local design only. Presets are stored in this browser and are not sent to the Pi.',
    cache: readAll(),
    async refresh() { this.cache = readAll(); return this.cache; },
    async save(name, document) {
      const all = readAll();
      // defineProperty rather than assignment: a preset named __proto__ must
      // become an own key, not a prototype write.
      Object.defineProperty(all, name, {value: document, enumerable: true, configurable: true, writable: true});
      storage.setItem(storageKey, JSON.stringify(all));
      this.cache = all;
    },
    async remove(name) {
      const all = readAll();
      delete all[name];
      storage.setItem(storageKey, JSON.stringify(all));
      this.cache = all;
    },
  };
}

export function piStore(fetchImpl = globalThis.fetch) {
  const check = async (response) => {
    const body = await response.json().catch(() => null);
    if (!response.ok || !isObject(body) || body.ok !== true) {
      throw new Error(isObject(body) && body.error ? body.error : `Request failed (${response.status})`);
    }
    return body;
  };
  return {
    kind: 'pi',
    label: 'the Pi',
    note: 'Presets are saved on the Pi and are available to any browser on this appliance. They are UI configuration; nothing is applied to audio.',
    cache: {},
    async refresh() {
      const listing = await check(await fetchImpl('/api/presets'));
      const entries = await Promise.all((listing.presets || []).map(async item => {
        try {
          const one = await check(await fetchImpl(`/api/presets/${encodeURIComponent(item.name)}`));
          return [item.name, one.preset];
        } catch { return null; }
      }));
      this.cache = Object.fromEntries(entries.filter(Boolean));
      return this.cache;
    },
    async save(name, document) {
      await check(await fetchImpl(`/api/presets/${encodeURIComponent(name)}`, {
        method: 'PUT',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify(document),
      }));
      await this.refresh();
    },
    async remove(name) {
      await check(await fetchImpl(`/api/presets/${encodeURIComponent(name)}`, {method: 'DELETE'}));
      await this.refresh();
    },
  };
}

// ------------------------------------------------------------- apply

// Step 5 of the README's sequence: a staged profile switch. The browser asks
// (POST /api/apply/profile), the unprivileged service writes one request file,
// a root path unit on the Pi runs usb16x16-apply, and the browser polls
// /api/apply/status for the receipt. Nothing here changes device state; the
// applier does, and it verifies and rolls back on its own.

export const APPLY_STATUS_PATH = '/api/apply/status';
export const APPLY_POLL_MS = 2000;
const APPLY_TERMINAL = new Set(['done', 'rolled-back', 'failed', 'refused']);

export async function requestProfile(profile, expectedProfile, fetchImpl = globalThis.fetch) {
  const response = await fetchImpl('/api/apply/profile', {
    method: 'POST',
    headers: {'content-type': 'application/json', accept: 'application/json'},
    body: JSON.stringify({profile, expectedProfile}),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !isObject(body) || body.ok !== true) {
    throw new Error(isObject(body) && body.error ? body.error : `Apply request failed (${response.status})`);
  }
  return body;
}

export async function fetchApplyStatus(fetchImpl = globalThis.fetch) {
  const response = await fetchImpl(APPLY_STATUS_PATH, {headers: {accept: 'application/json'}});
  const body = await response.json().catch(() => null);
  if (!response.ok || !isObject(body) || body.ok !== true) {
    throw new Error(isObject(body) && body.error ? body.error : `Status request failed (${response.status})`);
  }
  return body;
}

export const applyFinished = status => Boolean(status?.current) && APPLY_TERMINAL.has(status.current.state) && !status.pending;

const stepWords = {
  validating: 'Validating the request', stopping: 'Stopping the AES67 service', switching: 'Switching the profile',
  starting: 'Starting the AES67 service', verifying: 'Waiting for the stack to run', settling: 'Settling with zero recoveries',
  'rolling-back': 'Rolling back to the previous profile',
  done: 'Applied', 'rolled-back': 'Rolled back', failed: 'Failed', refused: 'Refused',
};
export const applyStepLabel = name => stepWords[name] || name;

/** One line describing an Apply status for the panel and the toast. */
export function applyLine(status) {
  if (!status) return 'No Apply operation recorded.';
  const current = status.current;
  if (status.pending && !status.inFlight) return 'Request queued; waiting for the applier to pick it up.';
  if (!current) return 'No Apply operation recorded.';
  const who = current.request?.requestedBy ? ` by ${current.request.requestedBy}` : '';
  const target = current.profile || current.request?.profile || '?';
  switch (current.state) {
    case 'done': return `Applied ${target}${who} · live since ${current.finishedAt || '?'}.`;
    case 'rolled-back': return `Could not run ${target}; rolled back to ${current.previousProfile || '?'}. ${current.error || ''}`.trim();
    case 'failed': return `Apply of ${target} failed and the rollback failed too: ${current.error || 'no detail'}. Check the Pi.`;
    case 'refused': return `Refused: ${current.error || 'no detail'}`;
    default: return `${applyStepLabel(current.state)} (${target})…`;
  }
}

/** The profile facts the Settings panel shows: what is live, what can be chosen. */
export function profileChoices(health) {
  const profile = health?.profile || {};
  const control = health?.control?.apply || {};
  const rows = Array.isArray(profile.profiles) ? profile.profiles : [];
  const live = rows.find(row => row.name === profile.selected) || (profile.selected ? {name: profile.selected} : null);
  return {
    live,
    accepted: rows.filter(row => (row.accepted || row.user) && row.name !== profile.selected),
    available: Boolean(control.available),
    reason: control.available ? (control.scope || '') : (control.reason || 'Apply is not installed on this Pi.'),
  };
}

// ------------------------------------------------------------- user presets

// The page compiles its own draft with the verified compiler (work/dsp-compiler,
// served under ./compiler/ as the same ES modules) and posts the bridge
// artifact; the Pi validates it by loading it and never trusts anything the
// browser says about it. The compiler is imported on demand so the page loads
// without it and reports a missing copy honestly.

let compilerPromise = null;
function loadCompiler(importImpl = path => import(path)) {
  if (!compilerPromise) {
    compilerPromise = Promise.all([importImpl('./compiler/compile.mjs'), importImpl('./compiler/bridge-artifact.mjs')])
      .then(([compileModule, artifactModule]) => ({...compileModule, ...artifactModule}))
      .catch(error => { compilerPromise = null; throw new Error(`The compiler is not served with this page: ${error.message}`); });
  }
  return compilerPromise;
}

/** Compile a UI draft to the bridge artifact plus the report the confirm shows. */
export async function compileDraft(config, importImpl) {
  const compiler = await loadCompiler(importImpl);
  const result = compiler.compile(config, compiler.fileDevices('in.raw', 'out.raw'));
  const artifact = compiler.bridgeArtifact(result, {presetName: config.name});
  const delay = compiler.delayLatency(config);
  const sections = (artifact.match(/^\S+ \S+ \S+ \S+ \S+$/gm) || []).length;
  return {artifact, report: result.report, delay, sections};
}

/** The confirm text for a compiled draft: what will run and what the compiler warns about. */
export function presetSummary(compiled, name) {
  const r = compiled.report;
  const lines = [
    `Install "${name}" on the Pi and restart the AES67 service on it?`,
    '',
    `${compiled.sections} biquad sections (${r.biquadCount} EQ bands, ${r.crossoverCount} crossover filters) across ${r.internalChannels} internal channels; headroom ${r.headroomDb} dB.`,
    compiled.delay.samples ? `Alignment delay adds ${compiled.delay.ms} ms (${compiled.delay.samples} samples) of latency.` : 'No alignment delay.',
  ];
  if (r.warnings?.length) lines.push('', ...r.warnings.map(w => `• ${w}`));
  lines.push('', 'The preset has not been soaked: the Pi loads it through the bridge\'s own loader, checks every section is stable, and rolls back if the stack does not come up clean. Audio stops for about a minute. Stop playback first.');
  return lines.join('\n');
}

export async function requestPreset(name, artifact, expectedProfile, fetchImpl = globalThis.fetch) {
  const response = await fetchImpl('/api/apply/preset', {
    method: 'POST',
    headers: {'content-type': 'application/json', accept: 'application/json'},
    body: JSON.stringify({name, artifact, expectedProfile}),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !isObject(body) || body.ok !== true) {
    throw new Error(isObject(body) && body.error ? body.error : `Preset request failed (${response.status})`);
  }
  return body;
}

export async function removePreset(slug, fetchImpl = globalThis.fetch) {
  const response = await fetchImpl(`/api/apply/preset/${encodeURIComponent(slug)}`, {method: 'DELETE', headers: {accept: 'application/json'}});
  const body = await response.json().catch(() => null);
  if (!response.ok || !isObject(body) || body.ok !== true) {
    throw new Error(isObject(body) && body.error ? body.error : `Remove failed (${response.status})`);
  }
  return body;
}

/** The user presets the Pi holds, from the health snapshot. */
export function userPresets(health) {
  const rows = Array.isArray(health?.profile?.profiles) ? health.profile.profiles : [];
  return rows.filter(row => row.user).map(row => ({
    name: row.name, slug: row.name.replace(/^user-/, ''), description: row.description || '',
    live: row.name === health?.profile?.selected,
  }));
}
