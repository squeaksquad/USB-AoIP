// build-request.mjs OUT.json: the transparent verify preset "Rate check" compiled the page's way
// (backend.mjs compileDraft + compileOtherRates), as the body api_apply_preset receives.
import { writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { compileDraft, compileOtherRates } from '../../../work/web-ui/backend.mjs';
import { transparentPreset } from '../../../work/dsp-compiler/verify-presets.mjs';
const importImpl = path => import(path.replace('./compiler/', '../../../work/dsp-compiler/'));
const preset = transparentPreset();
preset.name = 'Rate check';
const compiled = await compileDraft(preset, importImpl);
const rateArtifacts = await compileOtherRates(preset, importImpl);
const sha = createHash('sha256').update(compiled.artifact).digest('hex');
writeFileSync(process.argv[2], JSON.stringify({ name: 'Rate check', artifact: compiled.artifact, artifactSha256: sha, rateArtifacts }));
console.log(`sections ${compiled.sections}; 48 kHz ${sha.slice(0, 8)}; rates ${Object.keys(rateArtifacts).join(',')}; 88.2 kHz ${createHash('sha256').update(rateArtifacts["88200"]).digest('hex').slice(0, 8)}`);
