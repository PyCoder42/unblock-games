import test from 'node:test';
import assert from 'node:assert/strict';

const workerModule = await import('../Proxy/worker.js');
const worker = workerModule.default;

test('landing page shows categorized cards and proxy form', async () => {
  const response = await worker.fetch(new Request('https://proxy.example/'));
  const text = await response.text();

  assert.equal(response.status, 200);
  assert.match(text, /Game Proxy/i);
  assert.match(text, /Games/i);
  assert.match(text, /External Sites/i);
  assert.match(text, /name="url"/i);
});

test('extractTargetUrl supports query and browse routes', () => {
  assert.equal(
    workerModule.extractTargetUrl('/browse/https://example.com/docs', ''),
    'https://example.com/docs'
  );
  assert.equal(
    workerModule.extractTargetUrl('/browse', '?url=https%3A%2F%2Fexample.com%2Fform'),
    'https://example.com/form'
  );
  assert.equal(
    workerModule.extractTargetUrl('/ws/wss://sim3.psim.us/showdown/websocket', ''),
    'wss://sim3.psim.us/showdown/websocket'
  );
  assert.equal(workerModule.extractTargetUrl('/not-a-url', ''), null);
});

test('POST requests forward method, body, and content type to the upstream target', async () => {
  let fetchRequest;
  const fetchImpl = async (request) => {
    fetchRequest = request;
    return new Response('<html><body>ok</body></html>', {
      status: 200,
      headers: { 'content-type': 'text/html; charset=utf-8' },
    });
  };

  const response = await worker.fetch(
    new Request('https://proxy.example/browse?url=https%3A%2F%2Fexample.com%2Fsubmit', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: 'q=showdown',
    }),
    { fetch: fetchImpl }
  );

  assert.equal(response.status, 200);
  assert.ok(fetchRequest instanceof Request);
  assert.equal(fetchRequest.method, 'POST');
  assert.equal(fetchRequest.headers.get('content-type'), 'application/x-www-form-urlencoded');
  assert.equal(await fetchRequest.text(), 'q=showdown');
  assert.equal(fetchRequest.url, 'https://example.com/submit');
});

test('websocket upgrade requests are proxied with the upstream socket response', async () => {
  let fetchRequest;
  const upstreamSocket = { kind: 'upstream-socket' };
  const fetchImpl = async (request) => {
    fetchRequest = request;
    const response = new Response(null, { status: 101 });
    Object.defineProperty(response, 'webSocket', {
      value: upstreamSocket,
      configurable: true,
      enumerable: true,
    });
    return response;
  };

  const response = await worker.fetch(
    new Request('https://proxy.example/ws/wss://sim3.psim.us/showdown/websocket', {
      headers: { Upgrade: 'websocket' },
    }),
    { fetch: fetchImpl }
  );

  assert.equal(fetchRequest.url, 'wss://sim3.psim.us/showdown/websocket');
  assert.equal(fetchRequest.headers.get('upgrade'), 'websocket');
  assert.equal(response.status, 101);
  assert.equal(response.webSocket, upstreamSocket);
});

test('rewriteHtml injects proxy runtime helpers for fetch, xhr, and websocket', () => {
  const html = '<!doctype html><html><head><title>Demo</title></head><body><form action="/submit"></form></body></html>';
  const rewritten = workerModule.rewriteHtml(
    html,
    'https://play.pokemonshowdown.com/',
    'https://proxy.example'
  );

  assert.match(rewritten, /__UNBLOCK_PROXY_ORIGIN__/);
  assert.match(rewritten, /window\.fetch = function/);
  assert.match(rewritten, /XMLHttpRequest\.prototype\.open/);
  assert.match(rewritten, /window\.WebSocket = function/);
  assert.match(rewritten, /https:\/\/proxy\.example\/https:\/\/play\.pokemonshowdown\.com\/submit/);
});
