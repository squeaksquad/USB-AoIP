// A deterministic YAML writer for the subset the compiler emits: nested maps,
// lists, strings, finite numbers, booleans and null. Not a general serializer —
// it exists so the generated configuration is readable and diffable without
// adding a dependency to a repo that has no build step.

const PLAIN = /^[A-Za-z_][A-Za-z0-9_-]*$/;
// Words YAML 1.1 readers coerce to something other than a string.
const RESERVED = /^(y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF|null|Null|NULL|~)$/;

function scalar(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`Cannot emit non-finite number: ${value}`);
    // Keep the value exact but avoid exponent forms that read badly in a config.
    return Object.is(value, -0) ? '0.0' : String(value);
  }
  if (typeof value !== 'string') throw new Error(`Cannot emit ${typeof value}`);
  if (value === '') return "''";
  if (PLAIN.test(value) && !RESERVED.test(value)) return value;
  return `'${value.replace(/'/g, "''")}'`;
}

const isMap = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function emit(value, indent, lines) {
  const pad = '  '.repeat(indent);
  if (Array.isArray(value)) {
    if (!value.length) { lines[lines.length - 1] += ' []'; return; }
    for (const item of value) {
      if (isMap(item) || Array.isArray(item)) {
        lines.push(`${pad}-`);
        const start = lines.length;
        emit(item, indent + 1, lines);
        // Pull the first child onto the dash line: "- key: value".
        if (lines.length > start) {
          lines[start - 1] = `${pad}- ${lines[start].trimStart()}`;
          lines.splice(start, 1);
        }
      } else {
        lines.push(`${pad}- ${scalar(item)}`);
      }
    }
    return;
  }
  if (isMap(value)) {
    const keys = Object.keys(value);
    if (!keys.length) { lines[lines.length - 1] += ' {}'; return; }
    for (const key of keys) {
      const child = value[key];
      if ((isMap(child) && Object.keys(child).length) || (Array.isArray(child) && child.length)) {
        lines.push(`${pad}${scalar(key)}:`);
        emit(child, indent + 1, lines);
      } else if (isMap(child) || Array.isArray(child)) {
        lines.push(`${pad}${scalar(key)}:`);
        emit(child, indent + 1, lines);
      } else {
        lines.push(`${pad}${scalar(key)}: ${scalar(child)}`);
      }
    }
    return;
  }
  lines[lines.length - 1] += ` ${scalar(value)}`;
}

export function toYaml(document, header = []) {
  const lines = [];
  emit(document, 0, lines);
  const comments = header.map(line => (line ? `# ${line}` : '#'));
  return [...comments, ...lines, ''].join('\n');
}
