import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const repoRoot = '/Users/saahir/Desktop/Unblock Games';
const gasServerPath = path.join(repoRoot, 'Formatting Scripts', 'gas-server.js');
const adminTemplatePath = path.join(repoRoot, 'Formatting Scripts', 'admin-panel-template.html');
const lockGamePath = path.join(repoRoot, 'Formatting Scripts', 'lock-game.sh');
const remoteConfigSyncModulePath = path.join(repoRoot, 'Formatting Scripts', 'remote-config-sync.mjs');

function loadGasServer(initialProps = {}) {
  const props = new Map(Object.entries(initialProps));
  const fetchCalls = [];
  const context = {
    Buffer,
    console,
    ContentService: {
      MimeType: { JAVASCRIPT: 'application/javascript' },
      createTextOutput(text) {
        return {
          text,
          mimeType: null,
          setMimeType(type) {
            this.mimeType = type;
            return this;
          },
        };
      },
    },
    JSON,
    Math,
    PropertiesService: {
      getScriptProperties() {
        return {
          getProperty(key) {
            return props.has(key) ? props.get(key) : null;
          },
          setProperty(key, value) {
            props.set(key, value);
          },
        };
      },
    },
    UrlFetchApp: {
      fetch(url, options = {}) {
        fetchCalls.push({ url, options });
        if (/api\.github\.com\/repos\/.*\/contents\/config\.json$/.test(url) && !options.method) {
          return {
            getContentText() {
              return JSON.stringify({ sha: 'abc123' });
            },
            getResponseCode() {
              return 200;
            },
          };
        }

        if (/api\.github\.com\/repos\/.*\/contents\/config\.json$/.test(url) && String(options.method).toUpperCase() === 'PUT') {
          return {
            getContentText() {
              return JSON.stringify({ content: { sha: 'def456' }, commit: { sha: 'commit789' } });
            },
            getResponseCode() {
              return 200;
            },
          };
        }

        if (/api\.github\.com\/repos\/.*\/git\/refs$/.test(url) && String(options.method).toUpperCase() === 'POST') {
          return {
            getContentText() {
              return JSON.stringify({ ref: 'refs/tags/0.0.123' });
            },
            getResponseCode() {
              return 201;
            },
          };
        }

        if (/purge\.jsdelivr\.net/.test(url)) {
          return {
            getContentText() {
              return 'ok';
            },
            getResponseCode() {
              return 200;
            },
          };
        }

        throw new Error(`Unexpected fetch: ${url}`);
      },
    },
    Utilities: {
      base64Encode(value) {
        return Buffer.from(String(value), 'utf8').toString('base64');
      },
    },
  };

  vm.createContext(context);
  vm.runInContext(readFileSync(gasServerPath, 'utf8'), context, { filename: gasServerPath });
  return { context, fetchCalls, props };
}

function readStoredConfig(env) {
  return JSON.parse(env.props.get('config') || '{}');
}

function callGas(context, params) {
  const response = context.doGet({ parameter: params });
  const jsonpText = response.text;
  const match = jsonpText.match(/^\w+\(([\s\S]*)\)$/);
  return JSON.parse(match[1]);
}

function extractFunction(source, name) {
  const marker = `function ${name}(`;
  const start = source.indexOf(marker);
  if (start === -1) {
    throw new Error(`Could not find function ${name}`);
  }

  const braceStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = braceStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === '{') depth += 1;
    if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(start, index + 1);
      }
    }
  }

  throw new Error(`Could not parse function ${name}`);
}

test('GAS fullSync normalizes config data and mirrors updates to GitHub/jsDelivr', () => {
  const env = loadGasServer({
    config: '{}',
    githubPat: 'secret-pat',
    githubRepo: 'PyCoder42/unblock-games',
    secretKey: 'top-secret',
  });

  const response = env.context.doGet({
    parameter: {
      action: 'write',
      callback: 'cb',
      key: 'top-secret',
      writeAction: 'fullSync',
      config: JSON.stringify({
        password: 'pw',
        passwords: ['pw', 'pw-older'],
        blocked: {
          'Drive Mad Secure.html': true,
          'Eaglercraft 1.12': '2099-01-01T00:00:00.000Z',
        },
        games: ['Drive Mad Secure.html', 'Eaglercraft 1.12'],
        allowedIps: [{ ip: ' 192.168.1.8 ', label: ' Me ' }],
      }),
    },
  });

  const stored = readStoredConfig(env);

  assert.match(response.text, /"success":true/);
  assert.deepEqual(stored.passwords, ['pw', 'pw-older']);
  assert.equal(stored.password, 'pw');
  assert.deepEqual(stored.games, ['drive-mad', 'eaglercraft-1-12']);
  assert.equal(stored.blocked['drive-mad'], true);
  assert.equal(stored.blocked['eaglercraft-1-12'], '2099-01-01T00:00:00.000Z');
  assert.deepEqual(stored.allowedIps, {
    '192.168.1.8': { label: 'Me' },
  });
  assert.ok(env.fetchCalls.some((call) => call.url.includes('api.github.com/repos/PyCoder42/unblock-games/contents/config.json')));
  assert.ok(env.fetchCalls.some((call) => call.url.includes('api.github.com/repos/PyCoder42/unblock-games/git/refs')));
  assert.ok(env.fetchCalls.some((call) => call.url.includes('purge.jsdelivr.net/gh/PyCoder42/unblock-games@latest/config.json')));
});

test('remote config sync module merges passwords, blocked games, games, and allowed IPs across sources', async () => {
  const mod = await import(remoteConfigSyncModulePath);
  const merged = mod.mergeRemoteConfigs(
    {
      password: 'gas-password',
      passwords: ['gas-password', 'gas-fallback'],
      blocked: {
        'drive-mad': true,
      },
      games: ['drive-mad'],
      allowedIps: {
        '192.168.1.5, 192.168.1.6': { label: 'Me' },
      },
    },
    {
      password: 'cdn-password',
      blocked: {
        'smash-karts': '2099-01-01T00:00:00.000Z',
      },
      games: ['smash-karts'],
      allowedIps: {
        '10.0.0.9': { label: 'Friend' },
      },
    },
  );

  assert.equal(merged.password, 'gas-password');
  assert.deepEqual(merged.passwords, ['gas-password', 'gas-fallback', 'cdn-password']);
  assert.deepEqual(merged.games, ['drive-mad', 'smash-karts']);
  assert.deepEqual(merged.blocked, {
    'drive-mad': true,
    'smash-karts': '2099-01-01T00:00:00.000Z',
  });
  assert.deepEqual(merged.allowedIps, {
    '10.0.0.9': { label: 'Friend' },
    '192.168.1.5': { label: 'Me' },
    '192.168.1.6': { label: 'Me' },
  });
});

test('remote config sync drops placeholder, loopback, and malformed allowed IP entries', async () => {
  const mod = await import(remoteConfigSyncModulePath);

  assert.deepEqual(mod.normalizeAllowedIps({
    '0.0.0.0': { label: 'Placeholder' },
    '127.0.0.1': { label: 'Loopback' },
    '5D:A6:90:E2:CB:0E:30:34:52:70:51:50:89:72:5F:92:6C:53:18:E7:46:05:34:7B:D0:89:45:90:C6:D5:01:67': { label: 'Bogus' },
    '192.168.1.42': { label: 'Device' },
  }), {
    '192.168.1.42': { label: 'Device' },
  });
});

test('remote config sync prefers jsdelivr as the primary ordering when both sources are readable', async () => {
  const mod = await import(remoteConfigSyncModulePath);
  const fetchImpl = async (url, options = {}) => {
    const href = String(url);

    if (href.startsWith('https://gas.example/read') || (href.startsWith('https://gas.example/') && href.includes('action=read'))) {
      return new Response('syncRemoteConfigRead({"password":"gas-password","passwords":["gas-password"],"blocked":{},"games":["drive-mad"],"allowedIps":{}})', {
        status: 200,
        headers: { 'content-type': 'application/javascript' },
      });
    }

    if (href.startsWith('https://cdn.example/config.json')) {
      return new Response(JSON.stringify({
        password: 'cdn-password',
        passwords: ['cdn-password', 'gas-password'],
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {},
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }

    if (href.startsWith('https://api.github.com/repos/test/repo/contents/config.json')) {
      if (String(options.method || 'GET').toUpperCase() === 'PUT') {
        return new Response(JSON.stringify({ content: { sha: 'newsha' } }), { status: 200 });
      }
      return new Response(JSON.stringify({ sha: 'oldsha' }), { status: 200 });
    }

    if (href.startsWith('https://purge.jsdelivr.net/gh/test/repo@latest/config.json')) {
      return new Response('ok', { status: 200 });
    }

    throw new Error(`Unexpected URL: ${href}`);
  };

  const result = await mod.syncRemoteConfig({
    gasUrl: 'https://gas.example/read',
    gasSecret: 'secret',
    jsdelivrUrl: 'https://cdn.example/config.json',
    githubRepo: 'test/repo',
    githubPat: 'token',
    dryRun: true,
    fetchImpl,
  });

  assert.equal(result.mergedConfig.password, 'cdn-password');
  assert.deepEqual(result.mergedConfig.passwords, ['cdn-password', 'gas-password']);
});

test('remote config sync reads the newest jsdelivr tagged version when @latest is stale', async () => {
  const mod = await import(remoteConfigSyncModulePath);
  const result = await mod.readJsdelivrConfig('https://cdn.jsdelivr.net/gh/test/repo@latest/config.json', async (url) => {
    const href = String(url);

    if (href.startsWith('https://data.jsdelivr.com/v1/package/gh/test/repo')) {
      return new Response(JSON.stringify({
        versions: ['0.0.100', '0.0.200'],
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }

    if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.200/config.json')) {
      return new Response(JSON.stringify({
        password: 'fresh-password',
        passwords: ['fresh-password'],
        blocked: { 'drive-mad': true },
        games: ['drive-mad'],
        allowedIps: { '198.51.100.42': { label: 'Fresh' } },
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }

    if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@latest/config.json')) {
      return new Response(JSON.stringify({
        password: 'stale-password',
        passwords: ['stale-password'],
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {},
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }

    throw new Error(`Unexpected URL: ${href}`);
  });

  assert.equal(result.ok, true);
  assert.equal(result.config.password, 'fresh-password');
  assert.deepEqual(result.config.allowedIps, {
    '198.51.100.42': { label: 'Fresh' },
  });
});

test('GAS write actions support removing games and managing labeled allowed IPs', () => {
  const env = loadGasServer({
    config: JSON.stringify({
      password: 'pw',
      blocked: { 'drive-mad': true },
      games: ['drive-mad', 'smash-karts'],
      allowedIps: {},
    }),
    githubPat: 'secret-pat',
    githubRepo: 'PyCoder42/unblock-games',
    secretKey: 'top-secret',
  });

  env.context.doGet({
    parameter: {
      action: 'write',
      callback: 'cb',
      ip: '10.0.0.4',
      key: 'top-secret',
      label: 'Saahir',
      writeAction: 'setAllowedIp',
    },
  });

  let stored = readStoredConfig(env);
  assert.deepEqual(stored.allowedIps, {
    '10.0.0.4': { label: 'Saahir' },
  });

  env.context.doGet({
    parameter: {
      action: 'write',
      callback: 'cb',
      game: 'drive-mad',
      key: 'top-secret',
      writeAction: 'removeGame',
    },
  });

  stored = readStoredConfig(env);
  assert.deepEqual(stored.games, ['smash-karts']);
  assert.equal(stored.blocked['drive-mad'], undefined);

  env.context.doGet({
    parameter: {
      action: 'write',
      callback: 'cb',
      ip: '10.0.0.4',
      key: 'top-secret',
      writeAction: 'removeAllowedIp',
    },
  });

  stored = readStoredConfig(env);
  assert.deepEqual(stored.allowedIps, {});
});

test('GAS fullSync drops placeholder and malformed allowed IP entries while splitting legacy lists', () => {
  const env = loadGasServer({
    config: '{}',
    githubPat: 'secret-pat',
    githubRepo: 'PyCoder42/unblock-games',
    secretKey: 'top-secret',
  });

  env.context.doGet({
    parameter: {
      action: 'write',
      callback: 'cb',
      key: 'top-secret',
      writeAction: 'fullSync',
      config: JSON.stringify({
        password: 'pw',
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {
          '0.0.0.0, 127.0.0.1, 192.168.1.42, 5D:A6:90:E2:CB:0E:30:34:52:70:51:50:89:72:5F:92:6C:53:18:E7:46:05:34:7B:D0:89:45:90:C6:D5:01:67': { label: 'Me' },
        },
      }),
    },
  });

  assert.deepEqual(readStoredConfig(env).allowedIps, {
    '192.168.1.42': { label: 'Me' },
  });
});

test('secure generation has no ADMIN PANEL INFO comment and includes a copyable IP block screen', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'ug-secure-test-'));
  const inputFile = path.join(tempDir, 'eaglercraft-regular-1-12.html');
  const outputFile = path.join(tempDir, 'eaglercraft-secure-1-12.html');

  try {
    writeFileSync(inputFile, '<!DOCTYPE html><html><body><h1>Test</h1></body></html>');
    execFileSync(lockGamePath, [inputFile, '', 'secure'], {
      cwd: repoRoot,
      stdio: 'pipe',
    });

    const outerHtml = readFileSync(outputFile, 'utf8');
    const innerMatch = outerHtml.match(/var SECURE_INNER_B64 = "([A-Za-z0-9+/=]+)";/);
    assert.ok(innerMatch, 'expected secure output to contain SECURE_INNER_B64');

    const innerHtml = Buffer.from(innerMatch[1], 'base64').toString('utf8');

    assert.doesNotMatch(outerHtml, /ADMIN PANEL INFO/, 'outer HTML must not contain ADMIN PANEL INFO comment');
    assert.match(outerHtml, /^<!DOCTYPE html>/, 'outer HTML should start with DOCTYPE');
    assert.match(innerHtml, /Network Diagnostics/);
    assert.doesNotMatch(innerHtml, /Windows Network Diagnostics/);
    assert.match(innerHtml, /Current IP/i);
    assert.match(innerHtml, /Copy IP/i);
    assert.match(innerHtml, /'<\/scr'\s*\+\s*'ipt>'/);
    assert.doesNotMatch(innerHtml, /Add this IP to the admin panel allowed list/i);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test('secure primaryCurrentIp prefers a real device or network address over placeholders', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'ug-secure-ip-test-'));
  const inputFile = path.join(tempDir, 'drive-mad-regular.html');
  const outputFile = path.join(tempDir, 'drive-mad-secure.html');

  try {
    writeFileSync(inputFile, '<!DOCTYPE html><html><body><h1>Test</h1></body></html>');
    execFileSync(lockGamePath, [inputFile, '', 'secure'], {
      cwd: repoRoot,
      stdio: 'pipe',
    });

    const outerHtml = readFileSync(outputFile, 'utf8');
    const innerMatch = outerHtml.match(/var SECURE_INNER_B64 = "([A-Za-z0-9+/=]+)";/);
    assert.ok(innerMatch, 'expected secure output to contain SECURE_INNER_B64');

    const innerHtml = Buffer.from(innerMatch[1], 'base64').toString('utf8');
    const snippetStart = innerHtml.indexOf('function trimString');
    const snippetEnd = innerHtml.indexOf('function normalizePasswordList');
    assert.ok(snippetStart !== -1 && snippetEnd !== -1, 'expected secure output to contain IP selection helpers');

    const context = {
      clientIps: [],
      Promise,
      setTimeout() {},
      window: {},
    };

    vm.runInNewContext(`var clientIps = [];\n${innerHtml.slice(snippetStart, snippetEnd)}`, context);

    context.clientIps = ['0.0.0.0', '127.0.0.1', '70.112.139.216'];
    assert.equal(context.primaryCurrentIp(), '70.112.139.216');

    context.clientIps = ['0.0.0.0', '127.0.0.1', '192.168.1.42', '70.112.139.216'];
    assert.equal(context.primaryCurrentIp(), '192.168.1.42');
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test('admin template includes a GitHub/jsdelivr mirror fallback and does not reference ADMIN PANEL INFO', () => {
  const html = readFileSync(adminTemplatePath, 'utf8');

  assert.match(html, /api\.github\.com\/repos\//);
  assert.match(html, /purge\.jsdelivr\.net/);
  assert.match(html, /Allowed IP/i);
  assert.match(html, /removeGame\(/);
  assert.match(html, /exact game id/i);
  assert.doesNotMatch(html, /ADMIN PANEL INFO/i, 'template must not reference ADMIN PANEL INFO');
  assert.doesNotMatch(html, /top comment/i, 'template must not reference top comment');
  assert.doesNotMatch(html, /You can type a normal name like/i);
  assert.match(html, /jsdelivr/i);
  assert.match(html, /PANEL_MODE/);
  assert.match(html, /adminKeysSection/);
});

test('admin normalizeConfig normalizes passwords, blocked, and allowed IPs', () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = { result: null };
  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'isPlaceholderIp'),
      extractFunction(html, 'isLoopbackIp'),
      extractFunction(html, 'isValidIpv4'),
      extractFunction(html, 'isLikelyIpv6'),
      extractFunction(html, 'isUsableAllowedIp'),
      extractFunction(html, 'normalizeGameIdInput'),
      extractFunction(html, 'normalizeAllowedIps'),
      extractFunction(html, 'normalizePasswordList'),
      extractFunction(html, 'normalizeConfig'),
      `result = normalizeConfig(
        {
          password: 'test-password',
          passwords: ['test-password', 'alt-password'],
          blocked: { 'drive-mad': true },
          games: ['drive-mad'],
          allowedIps: { '192.168.1.5': { label: 'Me' } }
        }
      );`,
    ].join('\n'),
    context,
  );

  const normalized = JSON.parse(JSON.stringify(context.result));

  assert.deepEqual(normalized.passwords, ['test-password', 'alt-password']);
  assert.equal(normalized.password, 'test-password');
  assert.equal(normalized.blocked['drive-mad'], true);
  assert.deepEqual(normalized.games, ['drive-mad']);
  assert.deepEqual(normalized.allowedIps, {
    '192.168.1.5': { label: 'Me' },
  });
});

test('admin normalizeAllowedIps drops placeholder, loopback, and malformed values', () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = { result: null };
  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'isPlaceholderIp'),
      extractFunction(html, 'isLoopbackIp'),
      extractFunction(html, 'isValidIpv4'),
      extractFunction(html, 'isLikelyIpv6'),
      extractFunction(html, 'isUsableAllowedIp'),
      extractFunction(html, 'normalizeAllowedIps'),
      `result = normalizeAllowedIps({
        '0.0.0.0': { label: 'Placeholder' },
        '127.0.0.1': { label: 'Loopback' },
        '5D:A6:90:E2:CB:0E:30:34:52:70:51:50:89:72:5F:92:6C:53:18:E7:46:05:34:7B:D0:89:45:90:C6:D5:01:67': { label: 'Bogus' },
        '192.168.1.42': { label: 'Device' }
      });`,
    ].join('\n'),
    context,
  );

  assert.deepEqual(JSON.parse(JSON.stringify(context.result)), {
    '192.168.1.42': { label: 'Device' },
  });
});

test('admin updatePassword replaces alternative passwords with the entered password', () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const input = { value: '  new-password  ' };
  const context = {
    config: {
      password: 'old-password',
      passwords: ['old-password', 'older-password'],
      blocked: {},
      games: [],
      allowedIps: {},
    },
    document: {
      getElementById(id) {
        assert.equal(id, 'pwInput');
        return input;
      },
    },
    showToast() {
      throw new Error('showToast should not be called for a valid password update');
    },
    writeConfig(callback) {
      if (callback) callback();
    },
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'updatePassword'),
    ].join('\n'),
    context,
  );

  context.updatePassword();

  assert.equal(context.config.password, 'new-password');
  assert.deepEqual(JSON.parse(JSON.stringify(context.config.passwords)), ['new-password']);
  assert.equal(input.value, '');
});

test('admin writeGitHubMirror keeps jsdelivr pending until the CDN serves the new config', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const calls = [];
  const context = {
    Buffer,
    Date,
    GITHUB_PAT: 'token',
    GITHUB_REPO: 'test/repo',
    JSDELIVR_URL: 'https://cdn.example/config.json',
    Promise,
    Response,
    btoa(value) {
      return Buffer.from(String(value), 'binary').toString('base64');
    },
    fetch(url, options = {}) {
      const href = String(url);
      calls.push({ url: href, options });

      if (href === 'https://api.github.com/repos/test/repo/contents/config.json' && !options.method) {
        return Promise.resolve(new Response(JSON.stringify({ sha: 'oldsha' }), { status: 200 }));
      }

      if (href === 'https://api.github.com/repos/test/repo/contents/config.json' && String(options.method).toUpperCase() === 'PUT') {
        return Promise.resolve(new Response(JSON.stringify({
          content: { sha: 'newblob' },
          commit: { sha: 'commitsha' },
        }), { status: 200 }));
      }

      if (href === 'https://api.github.com/repos/test/repo/git/refs' && String(options.method).toUpperCase() === 'POST') {
        return Promise.resolve(new Response(JSON.stringify({ ref: 'refs/tags/0.0.123' }), { status: 201 }));
      }

      if (href === 'https://purge.jsdelivr.net/gh/test/repo@latest/config.json') {
        return Promise.resolve(new Response('ok', { status: 200 }));
      }

      if (href.startsWith('https://cdn.example/config.json?t=')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'old-password',
          passwords: ['old-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      throw new Error(`Unexpected URL: ${href}`);
    },
    setTimeout(fn) {
      fn();
      return 0;
    },
    unescape,
    window: { fetch: true },
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'normalizeGameIdInput'),
      extractFunction(html, 'normalizeAllowedIps'),
      extractFunction(html, 'normalizePasswordList'),
      extractFunction(html, 'normalizeConfig'),
      extractFunction(html, 'configsMatch'),
      extractFunction(html, 'compareJsdelivrVersions'),
      extractFunction(html, 'parseJsdelivrUrlInfo'),
      extractFunction(html, 'buildJsdelivrVersionUrl'),
      extractFunction(html, 'getJsdelivrStorage'),
      extractFunction(html, 'getCachedJsdelivrVersion'),
      extractFunction(html, 'rememberJsdelivrVersion'),
      extractFunction(html, 'clearCachedJsdelivrVersion'),
      extractFunction(html, 'fetchJsdelivrConfig'),
      extractFunction(html, 'resolveJsdelivrReadUrls'),
      extractFunction(html, 'readJsdelivrConfigFromUrl'),
      extractFunction(html, 'readJsdelivrConfig'),
      extractFunction(html, 'encodeGitHubContent'),
      extractFunction(html, 'nextConfigVersionTag'),
      extractFunction(html, 'createGitHubVersionTag'),
      extractFunction(html, 'waitForJsdelivrSync'),
      extractFunction(html, 'writeGitHubMirror'),
      `resultPromise = writeGitHubMirror({
        password: 'new-password',
        passwords: ['new-password'],
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {}
      });`,
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));

  assert.equal(result.ok, true);
  assert.equal(result.jsdelivr, false);
  assert.ok(calls.some((call) => call.url.startsWith('https://cdn.example/config.json?t=')));
});

test('admin readJsdelivrConfig resolves the newest tagged jsdelivr version when @latest is stale', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = {
    JSDELIVR_URL: 'https://cdn.jsdelivr.net/gh/test/repo@latest/config.json',
    Promise,
    Response,
    window: { fetch: true },
    fetch(url) {
      const href = String(url);

      if (href.startsWith('https://data.jsdelivr.com/v1/package/gh/test/repo')) {
        return Promise.resolve(new Response(JSON.stringify({
          versions: ['0.0.10', '0.0.20'],
        }), { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.20/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'fresh-password',
          passwords: ['fresh-password'],
          blocked: { 'drive-mad': true },
          games: ['drive-mad'],
          allowedIps: { '198.51.100.42': { label: 'Fresh' } },
        }), { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@latest/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'stale-password',
          passwords: ['stale-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      throw new Error(`Unexpected URL: ${href}`);
    },
    resultPromise: null,
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'normalizeGameIdInput'),
      extractFunction(html, 'normalizeAllowedIps'),
      extractFunction(html, 'normalizePasswordList'),
      extractFunction(html, 'normalizeConfig'),
      extractFunction(html, 'compareJsdelivrVersions'),
      extractFunction(html, 'parseJsdelivrUrlInfo'),
      extractFunction(html, 'buildJsdelivrVersionUrl'),
      extractFunction(html, 'getJsdelivrStorage'),
      extractFunction(html, 'getCachedJsdelivrVersion'),
      extractFunction(html, 'rememberJsdelivrVersion'),
      extractFunction(html, 'clearCachedJsdelivrVersion'),
      extractFunction(html, 'fetchJsdelivrConfig'),
      extractFunction(html, 'resolveJsdelivrReadUrls'),
      extractFunction(html, 'readJsdelivrConfigFromUrl'),
      extractFunction(html, 'readJsdelivrConfig'),
      'resultPromise = readJsdelivrConfig();',
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));
  assert.equal(result.ok, true);
  assert.equal(result.config.password, 'fresh-password');
  assert.deepEqual(result.config.allowedIps, {
    '198.51.100.42': { label: 'Fresh' },
  });
});

test('admin readJsdelivrConfig prefers a cached newer jsdelivr version over stale metadata', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = {
    JSDELIVR_URL: 'https://cdn.jsdelivr.net/gh/test/repo@latest/config.json',
    Promise,
    Response,
    window: { fetch: true },
    localStorage: {
      getItem(key) {
        assert.equal(key, 'unblockGamesJsdelivrVersion');
        return '0.0.30';
      },
      setItem() {},
      removeItem() {},
    },
    fetch(url) {
      const href = String(url);

      if (href.startsWith('https://data.jsdelivr.com/v1/package/gh/test/repo')) {
        return Promise.resolve(new Response(JSON.stringify({
          versions: ['0.0.10', '0.0.20'],
        }), { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.30/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'cached-password',
          passwords: ['cached-password'],
          blocked: { 'drive-mad': true },
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.20/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'metadata-password',
          passwords: ['metadata-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      throw new Error(`Unexpected URL: ${href}`);
    },
    resultPromise: null,
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'compareJsdelivrVersions'),
      extractFunction(html, 'parseJsdelivrUrlInfo'),
      extractFunction(html, 'buildJsdelivrVersionUrl'),
      extractFunction(html, 'getJsdelivrStorage'),
      extractFunction(html, 'getCachedJsdelivrVersion'),
      extractFunction(html, 'rememberJsdelivrVersion'),
      extractFunction(html, 'clearCachedJsdelivrVersion'),
      extractFunction(html, 'fetchJsdelivrConfig'),
      extractFunction(html, 'resolveJsdelivrReadUrls'),
      extractFunction(html, 'readJsdelivrConfigFromUrl'),
      extractFunction(html, 'readJsdelivrConfig'),
      'resultPromise = readJsdelivrConfig();',
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));
  assert.equal(result.ok, true);
  assert.equal(result.config.password, 'cached-password');
});

test('admin readGitHubRawConfig returns ok:false when GITHUB_RAW_URL is empty', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = {
    GITHUB_RAW_URL: '',
    Promise,
    resultPromise: null,
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'readGitHubRawConfig'),
      'resultPromise = readGitHubRawConfig();',
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));
  assert.equal(result.ok, false);
  assert.equal(result.source, 'github-raw');
});

test('admin readUnpkgConfig returns ok:false when UNPKG_URL is empty', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = {
    UNPKG_URL: '',
    Promise,
    resultPromise: null,
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'readUnpkgConfig'),
      'resultPromise = readUnpkgConfig();',
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));
  assert.equal(result.ok, false);
  assert.equal(result.source, 'unpkg');
});

test('admin loadConfig falls back to unpkg after jsdelivr and GitHub raw failures', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const calls = [];
  const applied = [];
  const statuses = [];
  const context = {
    Promise,
    lastReadSource: '',
    applyLoadedConfig(rawConfig, source) {
      applied.push({ rawConfig, source });
    },
    readJsdelivrConfig() {
      calls.push('jsdelivr');
      return Promise.resolve({ ok: false, source: 'jsdelivr' });
    },
    readGitHubRawConfig() {
      calls.push('github-raw');
      return Promise.resolve({ ok: false, source: 'github-raw' });
    },
    readUnpkgConfig() {
      calls.push('unpkg');
      return Promise.resolve({
        ok: true,
        source: 'unpkg',
        config: {
          password: 'unpkg-password',
          passwords: ['unpkg-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        },
      });
    },
    setStatus(text, cls) {
      statuses.push({ text, cls });
    },
    resultPromise: null,
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'loadConfig'),
      'resultPromise = loadConfig();',
    ].join('\n'),
    context,
  );

  await context.resultPromise;
  assert.deepEqual(calls, ['jsdelivr', 'github-raw', 'unpkg']);
  assert.deepEqual(applied, [{
    rawConfig: {
      password: 'unpkg-password',
      passwords: ['unpkg-password'],
      blocked: {},
      games: ['drive-mad'],
      allowedIps: {},
    },
    source: 'unpkg',
  }]);
  assert.equal(context.lastReadSource, 'unpkg');
  assert.deepEqual(statuses, [{ text: 'Connecting...', cls: 'ok' }]);
});

test('admin writeGitHubMirror verifies the returned jsdelivr version tag directly when metadata is stale', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  const context = {
    Buffer,
    Date,
    GITHUB_PAT: 'token',
    GITHUB_REPO: 'test/repo',
    JSDELIVR_URL: 'https://cdn.jsdelivr.net/gh/test/repo@latest/config.json',
    Promise,
    Response,
    localStorage: {
      getItem() { return ''; },
      setItem(key, value) {
        context.cachedVersion = { key, value };
      },
      removeItem() {},
    },
    btoa(value) {
      return Buffer.from(String(value), 'binary').toString('base64');
    },
    fetch(url, options = {}) {
      const href = String(url);

      if (href === 'https://api.github.com/repos/test/repo/contents/config.json' && !options.method) {
        return Promise.resolve(new Response(JSON.stringify({ sha: 'oldsha' }), { status: 200 }));
      }

      if (href === 'https://api.github.com/repos/test/repo/contents/config.json' && String(options.method).toUpperCase() === 'PUT') {
        return Promise.resolve(new Response(JSON.stringify({
          content: { sha: 'newblob' },
          commit: { sha: 'commitsha' },
        }), { status: 200 }));
      }

      if (href === 'https://api.github.com/repos/test/repo/git/refs' && String(options.method).toUpperCase() === 'POST') {
        return Promise.resolve(new Response(JSON.stringify({ ref: 'refs/tags/0.0.30' }), { status: 201 }));
      }

      if (href === 'https://purge.jsdelivr.net/gh/test/repo@latest/config.json') {
        return Promise.resolve(new Response('ok', { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.30/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'new-password',
          passwords: ['new-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      if (href.startsWith('https://data.jsdelivr.com/v1/package/gh/test/repo')) {
        return Promise.resolve(new Response(JSON.stringify({
          versions: ['0.0.20'],
        }), { status: 200 }));
      }

      if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.20/config.json')) {
        return Promise.resolve(new Response(JSON.stringify({
          password: 'old-password',
          passwords: ['old-password'],
          blocked: {},
          games: ['drive-mad'],
          allowedIps: {},
        }), { status: 200 }));
      }

      throw new Error(`Unexpected URL: ${href}`);
    },
    setTimeout(fn) {
      fn();
      return 0;
    },
    unescape,
    window: { fetch: true },
  };

  vm.createContext(context);
  vm.runInContext(
    [
      extractFunction(html, 'trimString'),
      extractFunction(html, 'normalizeGameIdInput'),
      extractFunction(html, 'normalizeAllowedIps'),
      extractFunction(html, 'normalizePasswordList'),
      extractFunction(html, 'normalizeConfig'),
      extractFunction(html, 'configsMatch'),
      extractFunction(html, 'compareJsdelivrVersions'),
      extractFunction(html, 'parseJsdelivrUrlInfo'),
      extractFunction(html, 'buildJsdelivrVersionUrl'),
      extractFunction(html, 'getJsdelivrStorage'),
      extractFunction(html, 'getCachedJsdelivrVersion'),
      extractFunction(html, 'rememberJsdelivrVersion'),
      extractFunction(html, 'clearCachedJsdelivrVersion'),
      extractFunction(html, 'fetchJsdelivrConfig'),
      extractFunction(html, 'resolveJsdelivrReadUrls'),
      extractFunction(html, 'readJsdelivrConfigFromUrl'),
      extractFunction(html, 'readJsdelivrConfig'),
      extractFunction(html, 'encodeGitHubContent'),
      extractFunction(html, 'nextConfigVersionTag'),
      extractFunction(html, 'createGitHubVersionTag'),
      extractFunction(html, 'waitForJsdelivrSync'),
      extractFunction(html, 'writeGitHubMirror'),
      `resultPromise = writeGitHubMirror({
        password: 'new-password',
        passwords: ['new-password'],
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {}
      });`,
    ].join('\n'),
    context,
  );

  const result = JSON.parse(JSON.stringify(await context.resultPromise));
  assert.equal(result.ok, true);
  assert.equal(result.jsdelivr, true);
  assert.deepEqual(context.cachedVersion, {
    key: 'unblockGamesJsdelivrVersion',
    value: '0.0.30',
  });
});

test('secure runtime resolves the newest tagged jsdelivr version when @latest is stale', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'ug-secure-jsd-test-'));
  const inputFile = path.join(tempDir, 'drive-mad-regular.html');
  const outputFile = path.join(tempDir, 'drive-mad-secure.html');

  try {
    writeFileSync(inputFile, '<!DOCTYPE html><html><body><h1>Test</h1></body></html>');
    execFileSync(lockGamePath, [inputFile, '', 'secure'], {
      cwd: repoRoot,
      stdio: 'pipe',
    });

    const outerHtml = readFileSync(outputFile, 'utf8');
    const innerMatch = outerHtml.match(/var SECURE_INNER_B64 = "([A-Za-z0-9+/=]+)";/);
    assert.ok(innerMatch, 'expected secure output to contain SECURE_INNER_B64');

    const innerHtml = Buffer.from(innerMatch[1], 'base64').toString('utf8');
    const context = {
      JSDELIVR_URL: 'https://cdn.jsdelivr.net/gh/test/repo@latest/config.json',
      Promise,
      Response,
      window: { fetch: true },
      fetch(url) {
        const href = String(url);

        if (href.startsWith('https://data.jsdelivr.com/v1/package/gh/test/repo')) {
          return Promise.resolve(new Response(JSON.stringify({
            versions: ['0.0.10', '0.0.20'],
          }), { status: 200 }));
        }

        if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@0.0.20/config.json')) {
          return Promise.resolve(new Response(JSON.stringify({
            password: 'fresh-password',
            passwords: ['fresh-password'],
            blocked: { 'drive-mad': true },
            games: ['drive-mad'],
            allowedIps: { '198.51.100.42': { label: 'Fresh' } },
          }), { status: 200 }));
        }

        if (href.startsWith('https://cdn.jsdelivr.net/gh/test/repo@latest/config.json')) {
          return Promise.resolve(new Response(JSON.stringify({
            password: 'stale-password',
            passwords: ['stale-password'],
            blocked: {},
            games: ['drive-mad'],
            allowedIps: {},
          }), { status: 200 }));
        }

        throw new Error(`Unexpected URL: ${href}`);
      },
      resultPromise: null,
    };

    vm.createContext(context);
    vm.runInContext(
      [
        extractFunction(innerHtml, 'trimString'),
        extractFunction(innerHtml, 'compareJsdelivrVersions'),
        extractFunction(innerHtml, 'parseJsdelivrUrlInfo'),
        extractFunction(innerHtml, 'buildJsdelivrVersionUrl'),
        extractFunction(innerHtml, 'getJsdelivrStorage'),
        extractFunction(innerHtml, 'getCachedJsdelivrVersion'),
        extractFunction(innerHtml, 'rememberJsdelivrVersion'),
        extractFunction(innerHtml, 'fetchJsdelivrConfig'),
        extractFunction(innerHtml, 'resolveJsdelivrReadUrls'),
        extractFunction(innerHtml, 'readJsdelivrConfigFromUrl'),
        extractFunction(innerHtml, 'readJsdelivrConfig'),
        'resultPromise = readJsdelivrConfig();',
      ].join('\n'),
      context,
    );

    return context.resultPromise.then((result) => {
      const normalized = JSON.parse(JSON.stringify(result));
      assert.equal(normalized.ok, true);
      assert.equal(normalized.config.password, 'fresh-password');
      assert.deepEqual(normalized.config.allowedIps, {
        '198.51.100.42': { label: 'Fresh' },
      });
    });
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test('secure runtime embeds UNPKG_URL support and falls back to unpkg after GitHub raw', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'ug-secure-unpkg-test-'));
  const inputFile = path.join(tempDir, 'drive-mad-regular.html');
  const outputFile = path.join(tempDir, 'drive-mad-secure.html');

  try {
    writeFileSync(inputFile, '<!DOCTYPE html><html><body><h1>Test</h1></body></html>');
    execFileSync(lockGamePath, [inputFile, '', 'secure'], {
      cwd: repoRoot,
      stdio: 'pipe',
    });

    const outerHtml = readFileSync(outputFile, 'utf8');
    const innerMatch = outerHtml.match(/var SECURE_INNER_B64 = "([A-Za-z0-9+/=]+)";/);
    assert.ok(innerMatch, 'expected secure output to contain SECURE_INNER_B64');

    const innerHtml = Buffer.from(innerMatch[1], 'base64').toString('utf8');
    assert.match(innerHtml, /var UNPKG_URL = "/);
    assert.match(innerHtml, /function readUnpkgConfig\(/);
    assert.match(
      innerHtml,
      /return readGitHubRawConfig\(\)\.then\(function\(rawResult\) \{[\s\S]*?return readUnpkgConfig\(\)\.then\(function\(unpkgResult\)/,
    );
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test('admin writeConfig updates the UI immediately and does not merge removed items back from stale local state', async () => {
  const html = readFileSync(adminTemplatePath, 'utf8');
  let resolveGithub;
  const renders = [];
  const context = {
    Promise,
    callbackResult: null,
    config: {
      password: 'pw',
      passwords: ['pw'],
      blocked: { 'drive-mad': true },
      games: ['drive-mad'],
      allowedIps: { '146.75.164.216': { label: 'Me' } },
    },
    githubResult: null,
    jsdelivrResult: null,
    lastReadSource: 'jsdelivr',
    normalizeConfig(value) {
      return JSON.parse(JSON.stringify(value));
    },
    serializeConfigForWrite() {
      return {
        password: 'pw',
        passwords: ['pw'],
        blocked: {},
        games: ['drive-mad'],
        allowedIps: {},
      };
    },
    writeGitHubMirror() {
      return new Promise((resolve) => {
        resolveGithub = resolve;
      });
    },
    renderConfig() {
      renders.push(JSON.parse(JSON.stringify(context.config)));
    },
    setStatus() {},
    showToast() {},
  };

  vm.createContext(context);
  vm.runInContext(extractFunction(html, 'writeConfig'), context);

  context.writeConfig(function(result) {
    context.callbackResult = JSON.parse(JSON.stringify(result));
  });

  assert.deepEqual(JSON.parse(JSON.stringify(context.config)), {
    password: 'pw',
    passwords: ['pw'],
    blocked: {},
    games: ['drive-mad'],
    allowedIps: {},
  });
  assert.equal(renders.length, 1);

  resolveGithub({ ok: true, jsdelivr: true });
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(JSON.parse(JSON.stringify(context.config)), {
    password: 'pw',
    passwords: ['pw'],
    blocked: {},
    games: ['drive-mad'],
    allowedIps: {},
  });
  assert.equal(renders.length, 2);
  assert.deepEqual(context.callbackResult, {
    github: { ok: true, jsdelivr: true },
    jsdelivr: { ok: true },
  });
});

test('secure allowlist matching ignores placeholder, loopback, and malformed client IP entries', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'ug-secure-allow-ip-test-'));
  const inputFile = path.join(tempDir, 'drive-mad-regular.html');
  const outputFile = path.join(tempDir, 'drive-mad-secure.html');

  try {
    writeFileSync(inputFile, '<!DOCTYPE html><html><body><h1>Test</h1></body></html>');
    execFileSync(lockGamePath, [inputFile, '', 'secure'], {
      cwd: repoRoot,
      stdio: 'pipe',
    });

    const outerHtml = readFileSync(outputFile, 'utf8');
    const innerMatch = outerHtml.match(/var SECURE_INNER_B64 = "([A-Za-z0-9+/=]+)";/);
    assert.ok(innerMatch, 'expected secure output to contain SECURE_INNER_B64');

    const innerHtml = Buffer.from(innerMatch[1], 'base64').toString('utf8');
    const context = {
      clientIps: [
        '0.0.0.0',
        '127.0.0.1',
        '5D:A6:90:E2:CB:0E:30:34:52:70:51:50:89:72:5F:92:6C:53:18:E7:46:05:34:7B:D0:89:45:90:C6:D5:01:67',
        '192.168.1.42',
      ],
      result: null,
    };

    vm.createContext(context);
    vm.runInContext(
      [
        extractFunction(innerHtml, 'trimString'),
        extractFunction(innerHtml, 'isPlaceholderIp'),
        extractFunction(innerHtml, 'isLoopbackIp'),
        extractFunction(innerHtml, 'isPrivateIpv4'),
        extractFunction(innerHtml, 'isValidIpv4'),
        extractFunction(innerHtml, 'isPublicIpv4'),
        extractFunction(innerHtml, 'isLikelyIpv6'),
        extractFunction(innerHtml, 'isUsableAllowedIp'),
        extractFunction(innerHtml, 'scoreIp'),
        extractFunction(innerHtml, 'sortIps'),
        extractFunction(innerHtml, 'normalizeAllowedIps'),
        extractFunction(innerHtml, 'normalizeAllowedIpMap'),
        extractFunction(innerHtml, 'isAllowedIp'),
        `result = {
          placeholderOnly: isAllowedIp({ allowedIps: {
            '0.0.0.0': { label: 'Placeholder' },
            '127.0.0.1': { label: 'Loopback' },
            '5D:A6:90:E2:CB:0E:30:34:52:70:51:50:89:72:5F:92:6C:53:18:E7:46:05:34:7B:D0:89:45:90:C6:D5:01:67': { label: 'Bogus' }
          } }),
          privateMatch: isAllowedIp({ allowedIps: { '192.168.1.42': { label: 'Device' } } })
        };`,
      ].join('\n'),
      context,
    );

    assert.equal(context.result.placeholderOnly, false);
    assert.equal(context.result.privateMatch, true);
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

// ═══ Fake Key System Tests ═══

test('GAS keyIdentifier produces consistent 6-char base36 identifiers', () => {
  const { context } = loadGasServer({ secretKey: 'realkey', config: '{}' });
  const id1 = context.keyIdentifier('testkey123');
  const id2 = context.keyIdentifier('testkey123');
  const id3 = context.keyIdentifier('differentkey');

  assert.equal(id1, id2, 'same key should produce same identifier');
  assert.notEqual(id1, id3, 'different keys should produce different identifiers');
  assert.ok(id1.length <= 6, 'identifier should be at most 6 chars');
  assert.match(id1, /^[0-9a-z]+$/, 'identifier should be base36');
});

test('GAS multi-key auth: real key works, unrevoked fake key works, revoked fake key fails, unknown key fails', () => {
  const fakeKeys = {
    'fakekey1': { label: 'Test', revoked: false, lastIp: '', lastSeen: '', created: '2025-01-01T00:00:00.000Z' },
    'fakekey2': { label: 'Revoked', revoked: true, lastIp: '', lastSeen: '', created: '2025-01-01T00:00:00.000Z' },
  };
  const { context } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
    fakeKeys: JSON.stringify(fakeKeys),
  });

  // Real key — write succeeds
  const realResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'updatePassword', password: 'newpw', callback: 'cb' });
  assert.ok(realResult.success, 'real key should work');

  // Unrevoked fake key — write succeeds
  const fakeResult = callGas(context, { action: 'write', key: 'fakekey1', writeAction: 'updatePassword', password: 'newpw2', callback: 'cb' });
  assert.ok(fakeResult.success, 'unrevoked fake key should work');

  // Revoked fake key — write fails
  const revokedResult = callGas(context, { action: 'write', key: 'fakekey2', writeAction: 'updatePassword', password: 'nope', callback: 'cb' });
  assert.equal(revokedResult.error, 'unauthorized', 'revoked fake key should fail');

  // Unknown key — write fails
  const unknownResult = callGas(context, { action: 'write', key: 'unknownkey', writeAction: 'updatePassword', password: 'nope', callback: 'cb' });
  assert.equal(unknownResult.error, 'unauthorized', 'unknown key should fail');
});

test('GAS addFakeKey creates a new key and readKeys returns it', () => {
  const { context, props } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
  });

  // Add a fake key
  const addResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'addFakeKey', label: 'Friend', callback: 'cb' });
  assert.ok(addResult.success, 'addFakeKey should succeed');
  assert.ok(addResult.fakeKey, 'should return the new key');
  assert.equal(addResult.fakeKey.length, 20, 'fake key should be 20 chars');
  assert.ok(addResult.identifier, 'should return an identifier');
  assert.equal(addResult.label, 'Friend');

  // Read keys
  const readResult = callGas(context, { action: 'readKeys', key: 'realkey', callback: 'cb' });
  assert.ok(readResult.success);
  assert.equal(readResult.keys.length, 1);
  assert.equal(readResult.keys[0].label, 'Friend');
  assert.equal(readResult.keys[0].revoked, false);
  assert.equal(readResult.keys[0].key, addResult.fakeKey);

  // The new key should work for normal writes
  const writeResult = callGas(context, { action: 'write', key: addResult.fakeKey, writeAction: 'updatePassword', password: 'changed', callback: 'cb' });
  assert.ok(writeResult.success, 'new fake key should work for config writes');
});

test('GAS fake key management actions are restricted to real key only', () => {
  const fakeKeys = {
    'fakekey1': { label: 'Test', revoked: false, lastIp: '', lastSeen: '', created: '2025-01-01T00:00:00.000Z' },
  };
  const { context } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
    fakeKeys: JSON.stringify(fakeKeys),
  });

  // Fake key trying to add another key — should fail
  const addResult = callGas(context, { action: 'write', key: 'fakekey1', writeAction: 'addFakeKey', label: 'Sneaky', callback: 'cb' });
  assert.equal(addResult.error, 'unauthorized', 'fake key should not be able to add keys');

  // Fake key trying to read keys — should fail
  const readResult = callGas(context, { action: 'readKeys', key: 'fakekey1', callback: 'cb' });
  assert.equal(readResult.error, 'unauthorized', 'fake key should not be able to read keys');

  // Fake key trying to revoke — should fail
  const revokeResult = callGas(context, { action: 'write', key: 'fakekey1', writeAction: 'revokeFakeKey', fakeKey: 'fakekey1', callback: 'cb' });
  assert.equal(revokeResult.error, 'unauthorized', 'fake key should not be able to revoke keys');
});

test('GAS revokeFakeKey and unrevokeFakeKey toggle revoked state by identifier', () => {
  const { context } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
  });

  // Add a key first
  const addResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'addFakeKey', label: 'Victim', callback: 'cb' });
  const identifier = addResult.identifier;
  const fakeKey = addResult.fakeKey;

  // Key works initially
  const write1 = callGas(context, { action: 'write', key: fakeKey, writeAction: 'updatePassword', password: 'a', callback: 'cb' });
  assert.ok(write1.success);

  // Revoke by identifier
  const revokeResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'revokeFakeKey', fakeKey: identifier, callback: 'cb' });
  assert.ok(revokeResult.success);
  assert.equal(revokeResult.revoked, true);

  // Key no longer works
  const write2 = callGas(context, { action: 'write', key: fakeKey, writeAction: 'updatePassword', password: 'b', callback: 'cb' });
  assert.equal(write2.error, 'unauthorized');

  // Unrerevoke by identifier
  const unrevokeResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'unrevokeFakeKey', fakeKey: identifier, callback: 'cb' });
  assert.ok(unrevokeResult.success);
  assert.equal(unrevokeResult.revoked, false);

  // Key works again
  const write3 = callGas(context, { action: 'write', key: fakeKey, writeAction: 'updatePassword', password: 'c', callback: 'cb' });
  assert.ok(write3.success);
});

test('GAS removeFakeKey deletes a key entirely', () => {
  const { context } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
  });

  const addResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'addFakeKey', label: 'ToDelete', callback: 'cb' });
  const fakeKey = addResult.fakeKey;
  const identifier = addResult.identifier;

  // Remove it
  const removeResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'removeFakeKey', fakeKey: identifier, callback: 'cb' });
  assert.ok(removeResult.success);
  assert.ok(removeResult.removed);

  // Key no longer works
  const writeResult = callGas(context, { action: 'write', key: fakeKey, writeAction: 'updatePassword', password: 'nope', callback: 'cb' });
  assert.equal(writeResult.error, 'unauthorized');

  // Key no longer appears in readKeys
  const readResult = callGas(context, { action: 'readKeys', key: 'realkey', callback: 'cb' });
  assert.equal(readResult.keys.length, 0);
});

test('GAS fake key IP tracking updates lastIp and lastSeen on write', () => {
  const { context } = loadGasServer({
    secretKey: 'realkey',
    config: '{"password":"pw","passwords":["pw"],"blocked":{},"games":[],"allowedIps":{}}',
  });

  const addResult = callGas(context, { action: 'write', key: 'realkey', writeAction: 'addFakeKey', label: 'Tracked', callback: 'cb' });
  const fakeKey = addResult.fakeKey;

  // Write with IP
  callGas(context, { action: 'write', key: fakeKey, writeAction: 'updatePassword', password: 'x', ip: '1.2.3.4', callback: 'cb' });

  // Check metadata
  const readResult = callGas(context, { action: 'readKeys', key: 'realkey', callback: 'cb' });
  const keyEntry = readResult.keys[0];
  assert.equal(keyEntry.lastIp, '1.2.3.4');
  assert.ok(keyEntry.lastSeen, 'lastSeen should be set');
});

test('admin template contains PANEL_MODE conditional and key management UI for real mode', () => {
  const html = readFileSync(adminTemplatePath, 'utf8');

  // PANEL_MODE placeholder
  assert.match(html, /PANEL_MODE.*=.*'\{\{PANEL_MODE\}\}'/);

  // Keys section exists but hidden by default
  assert.match(html, /adminKeysSection/);
  assert.match(html, /style="display:none;"/);

  // Real mode shows keys section
  assert.match(html, /PANEL_MODE === 'real'/);

  // GitHub PAT-based key management note
  assert.match(html, /github\.com\/settings\/tokens/);
});
