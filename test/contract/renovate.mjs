// Run with RENOVATE_ENTRY pointing at an installed, pinned Renovate CLI.
// Exercises real regex extraction, datasource HTTP lookup and update selection.
import {mkdtempSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';

const directory = mkdtempSync(join(tmpdir(), 'release-mirror-renovate-'));
const root = resolve(import.meta.dirname, '../..');
try {
  const config = JSON.parse(readFileSync(join(root, 'examples/renovate/renovate.json')));
  config.customDatasources['release-mirror'].defaultRegistryUrlTemplate = `${process.env.CONTRACT_URL || 'http://localhost:9292'}/api/v1/services/{{packageName}}/renovate`;
  writeFileSync(join(directory, 'renovate.json'), JSON.stringify(config));
  writeFileSync(join(directory, 'images.yaml'), readFileSync(join(root, 'examples/renovate/images.yaml')));
  spawnSync('git', ['init', '--quiet'], {cwd: directory});
  spawnSync('git', ['add', 'renovate.json', 'images.yaml'], {cwd: directory});
  const result = spawnSync(process.execPath, [process.env.RENOVATE_ENTRY, '--platform=local', '--onboarding=false', '--require-config=required', '--dry-run=lookup'], {
    cwd: directory, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    env: {...process.env, LOG_LEVEL: 'debug', LOG_FORMAT: 'json', RENOVATE_X_ALLOW_LOCAL_HTTP: 'true', RENOVATE_INTERNAL_HOST_ACCESS: 'block', RENOVATE_HOST_RULES: JSON.stringify([{matchHost: 'localhost', allowInternal: true}]), RENOVATE_GIT_AUTHOR: 'Fixture <fixture@example.test>'}
  });
  const output = result.stdout + result.stderr;
  if (process.env.RENOVATE_LOG_FILE) writeFileSync(process.env.RENOVATE_LOG_FILE, output);
  assert.equal(result.status, 0, 'Renovate process must succeed (see local log file)');
  const events = output.split('\n').flatMap(line => { try {return [JSON.parse(line)];} catch {return [];} });
  const resultEvent = events.find(event => event.msg === 'packageFiles with updates');
  assert(resultEvent, 'Renovate must report package files with updates');
  const files = resultEvent.config;
  const deps = Object.values(files).flat().flatMap(file => file.deps || []);
  assert.equal(deps.length, 2, 'Only the two custom-manager dependencies should be extracted');
  const version = deps.find(dep => dep.currentValue === 'v1.0.0');
  const moving = deps.find(dep => dep.currentValue === 'latest');
  assert(version.updates.some(update => update.newValue === 'v1.1.0' && update.newDigest === `sha256:${'b'.repeat(64)}`), 'Version update must carry the new image digest');
  assert(moving.updates.some(update => update.updateType === 'digest' && update.newValue === 'latest' && update.newDigest === `sha256:${'c'.repeat(64)}`), 'Moving tag must receive a digest-only update');
  assert(deps.every(dep => dep.datasource === 'custom.release-mirror'), 'No Docker datasource dependency may be extracted');
  assert(!events.some(event => event.host === 'registry.example.test'), 'Private registry must never be contacted');
  console.log('Renovate contract passed: real extraction and lookup produce version+digest and digest-only updates; no Docker datasource.');
} finally {
  rmSync(directory, {recursive: true, force: true});
}
