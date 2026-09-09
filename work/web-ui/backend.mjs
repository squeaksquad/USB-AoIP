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
  parts.push('Simulated meters');
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
