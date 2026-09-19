'use strict';

const assert = require('node:assert/strict');

const baseURL = process.env.TEST_BASE_URL || 'http://127.0.0.1:43123';
const originURL = process.env.TEST_ORIGIN || baseURL.replace(/^http:/, 'https:');
const password = process.env.TEST_ADMIN_PASSWORD || 'test-only-password';

async function request(path, options = {}, cookie = '') {
  const headers = new Headers(options.headers || {});
  headers.set('Origin', originURL);
  if (cookie) headers.set('Cookie', cookie);
  return fetch(baseURL + path, { ...options, headers, redirect: 'manual' });
}

async function run() {
  const health = await fetch(baseURL + '/health').then((response) => response.json());
  assert.equal(health.ok, true);

  const loginBody = new URLSearchParams({ password });
  const login = await request('/admin/login', { method: 'POST', body: loginBody });
  assert.equal(login.status, 302);
  const cookie = login.headers.get('set-cookie').split(';', 1)[0];

  const form = new FormData();
  form.set('name', 'Parche de prueba');
  form.set('version', '1.0.0');
  form.set('description', 'Prueba automática temporal');
  form.set('file', new Blob([Buffer.from('3105PATCH\0smoke', 'utf8')]), 'smoke.3105');
  const createdResponse = await request('/api/admin/patches', { method: 'POST', body: form }, cookie);
  assert.equal(createdResponse.status, 201);
  const created = (await createdResponse.json()).patch;
  assert.equal(created.name, 'Parche de prueba');

  const publicCatalog = await fetch(baseURL + '/api/patches').then((response) => response.json());
  assert.equal(publicCatalog.patches.length, 1);
  assert.equal(publicCatalog.patches[0].sha256, created.sha256);

  const update = await request('/api/admin/patches/' + created.id, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Parche renombrado', version: '1.0.1', description: 'Actualizado' })
  }, cookie);
  assert.equal(update.status, 200);

  const replacement = new FormData();
  replacement.set('file', new Blob([Buffer.from('3105PATCH\0replacement', 'utf8')]), 'replacement.3105');
  const replaced = await request('/api/admin/patches/' + created.id + '/file', {
    method: 'PUT', body: replacement
  }, cookie);
  assert.equal(replaced.status, 200);

  const removed = await request('/api/admin/patches/' + created.id, { method: 'DELETE' }, cookie);
  assert.equal(removed.status, 200);
  const finalCatalog = await fetch(baseURL + '/api/patches').then((response) => response.json());
  assert.equal(finalCatalog.patches.length, 0);
  console.log('INJECT IOS server smoke test passed');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
