// The server's own checks: screenshot files stay inside their folder, and tool
// arguments become exactly one target.
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { buildStep, readScreenshot, resolveTarget } from '../src/server.mjs';

test('a screenshot is read once and then deleted', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'turbo-shots-'));
  const file = join(dir, 'a.png');
  await writeFile(file, 'png bytes');
  const image = await readScreenshot({ path: file }, dir);
  assert.equal(Buffer.from(image.data, 'base64').toString(), 'png bytes');
  assert.equal(image.mimeType, 'image/png');
  await assert.rejects(access(file));
  await rm(dir, { recursive: true });
});

test('a screenshot path outside the folder is refused and left alone', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'turbo-shots-'));
  const other = await mkdtemp(join(tmpdir(), 'turbo-other-'));
  const file = join(other, 'secret.png');
  await writeFile(file, 'not yours');
  await assert.rejects(readScreenshot({ path: file }, dir), /outside/);
  await assert.rejects(readScreenshot({ path: join(dir, '..', 'x.png') }, dir));
  await access(file); // still there
  await rm(dir, { recursive: true });
  await rm(other, { recursive: true });
});

test('only image files are read', async () => {
  await assert.rejects(readScreenshot({ path: '/etc/passwd' }, tmpdir()), /file type/);
});

test('a target is an element or a point, never both or half', () => {
  assert.deepEqual(resolveTarget({ element: 3 }), { elementNumber: 3 });
  assert.deepEqual(resolveTarget({ x: 1, y: 2 }), { x: 1, y: 2 });
  assert.throws(() => resolveTarget({ element: 3, x: 1, y: 2 }), /exactly one/);
  assert.throws(() => resolveTarget({ x: 1 }), /together/);
  assert.throws(() => resolveTarget({}), /exactly one/);
});

test('a step leaves out arguments that were not given', () => {
  assert.deepEqual(buildStep('click_at', { element: 4 }), { type: 'clickAt', elementNumber: 4 });
  assert.throws(() => buildStep('observe_app', {}), /not an action tool/);
});
