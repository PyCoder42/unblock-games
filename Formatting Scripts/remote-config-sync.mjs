import { promises as fs } from 'node:fs';
import path from 'node:path';

export function trimString(value) {
  return String(value == null ? '' : value).replace(/^\s+|\s+$/g, '');
}

export function isPlaceholderIp(value) {
  const normalized = trimString(value).toLowerCase();
  return normalized === '0.0.0.0'
    || normalized === '::'
    || normalized === '0:0:0:0:0:0:0:0'
    || normalized === '::ffff:0.0.0.0';
}

export function isLoopbackIp(value) {
  const normalized = trimString(value).toLowerCase();
  return /^127\./.test(normalized)
    || normalized === '::1'
    || normalized === '0:0:0:0:0:0:0:1'
    || normalized === 'localhost';
}

export function isValidIpv4(value) {
  const normalized = trimString(value);
  if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(normalized)) return false;
  return normalized.split('.').every((part) => Number(part) >= 0 && Number(part) <= 255);
}

export function isLikelyIpv6(value) {
  const normalized = trimString(value).toLowerCase();
  let nonEmpty = 0;

  if (normalized.indexOf(':') === -1) return false;
  if (!/^[0-9a-f:]+$/.test(normalized)) return false;
  if (normalized.indexOf(':::') !== -1) return false;

  const parts = normalized.split(':');
  for (const part of parts) {
    if (!part) continue;
    if (part.length > 4) return false;
    nonEmpty += 1;
  }

  if (normalized.indexOf('::') === -1) {
    return parts.length === 8 && nonEmpty === 8;
  }
  return parts.length <= 8 && nonEmpty > 0;
}

export function isUsableAllowedIp(value) {
  const normalized = trimString(value);
  if (!normalized) return false;
  if (isPlaceholderIp(normalized) || isLoopbackIp(normalized)) return false;
  return isValidIpv4(normalized) || isLikelyIpv6(normalized);
}

export function normalizeGameId(value) {
  let normalized = trimString(value).toLowerCase();
  if (!normalized) return '';

  normalized = normalized.replace(/\.html$/i, '');
  normalized = normalized.replace(/eaglrcraft/g, 'eaglercraft');
  normalized = normalized.replace(/open[-\s]*in[-\s]*new[-\s]*tab/g, ' ');
  normalized = normalized.replace(/locked[-\s]*b64/g, ' ');
  normalized = normalized.replace(/\b(secure|regular|locked)\b/g, ' ');
  normalized = normalized.replace(/[._]+/g, ' ');
  normalized = normalized.replace(/[^a-z0-9]+/g, '-');
  normalized = normalized.replace(/-+/g, '-').replace(/^-+|-+$/g, '');
  return normalized;
}

export function normalizePasswordList(rawConfig) {
  const source = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  const output = [];

  function addPassword(value) {
    const normalized = trimString(value);
    if (!normalized || output.includes(normalized)) return;
    output.push(normalized);
  }

  addPassword(source.password);
  if (Array.isArray(source.passwords)) {
    source.passwords.forEach(addPassword);
  }

  return output;
}

export function normalizeBlockedMap(rawBlocked) {
  const output = {};
  const blocked = rawBlocked && typeof rawBlocked === 'object' ? rawBlocked : {};

  Object.keys(blocked).forEach((key) => {
    const normalizedKey = normalizeGameId(key);
    const value = blocked[key];
    if (!normalizedKey) return;
    if (value === true) {
      output[normalizedKey] = true;
    } else if (typeof value === 'string' && trimString(value)) {
      output[normalizedKey] = trimString(value);
    }
  });

  return output;
}

function setAllowedIpEntry(target, ipValue, labelValue) {
  String(ipValue == null ? '' : ipValue).split(',').forEach((candidate) => {
    const normalizedIp = trimString(candidate);
    if (!isUsableAllowedIp(normalizedIp)) return;
    target[normalizedIp] = { label: trimString(labelValue) };
  });
}

export function normalizeAllowedIps(rawAllowedIps) {
  const output = {};

  if (!rawAllowedIps) return output;

  if (Array.isArray(rawAllowedIps)) {
    rawAllowedIps.forEach((entry) => {
      if (typeof entry === 'string') {
        setAllowedIpEntry(output, entry, '');
        return;
      }
      if (entry && typeof entry === 'object') {
        setAllowedIpEntry(output, entry.ip || entry.address, entry.label);
      }
    });
  } else {
    Object.keys(rawAllowedIps).forEach((ip) => {
      const value = rawAllowedIps[ip];
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        setAllowedIpEntry(output, ip, value.label);
        return;
      }
      setAllowedIpEntry(output, ip, value);
    });
  }

  const sorted = {};
  Object.keys(output).sort().forEach((ip) => {
    sorted[ip] = output[ip];
  });
  return sorted;
}

function normalizeGames(rawGames, blockedMap) {
  const unique = {};
  const list = Array.isArray(rawGames) ? rawGames : [];

  list.forEach((gameId) => {
    const normalized = normalizeGameId(gameId);
    if (normalized) unique[normalized] = true;
  });

  Object.keys(blockedMap || {}).forEach((gameId) => {
    unique[gameId] = true;
  });

  return Object.keys(unique).sort();
}

export function normalizeConfig(rawConfig) {
  const source = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  const blocked = normalizeBlockedMap(source.blocked);
  const passwords = normalizePasswordList(source);

  return {
    password: passwords[0] || '',
    passwords,
    blocked,
    games: normalizeGames(source.games, blocked),
    allowedIps: normalizeAllowedIps(source.allowedIps || source.allowedIPs || source.allowedIpAddresses),
  };
}

export function mergeBlockedValue(primaryValue, secondaryValue) {
  if (primaryValue === true || secondaryValue === true) return true;
  if (typeof primaryValue === 'string' && trimString(primaryValue)) {
    if (typeof secondaryValue === 'string' && trimString(secondaryValue)) {
      return new Date(primaryValue) >= new Date(secondaryValue)
        ? trimString(primaryValue)
        : trimString(secondaryValue);
    }
    return trimString(primaryValue);
  }
  if (typeof secondaryValue === 'string' && trimString(secondaryValue)) {
    return trimString(secondaryValue);
  }
  return undefined;
}

export function mergeAllowedIpMaps(primaryIps, secondaryIps) {
  const output = {};
  [normalizeAllowedIps(primaryIps), normalizeAllowedIps(secondaryIps)].forEach((map) => {
    Object.keys(map).sort().forEach((ip) => {
      if (!output[ip]) {
        output[ip] = { label: trimString(map[ip].label) };
        return;
      }
      if (!output[ip].label && trimString(map[ip].label)) {
        output[ip].label = trimString(map[ip].label);
      }
    });
  });
  return output;
}

export function mergeRemoteConfigs(primaryConfig, secondaryConfig) {
  const primary = normalizeConfig(primaryConfig);
  const secondary = normalizeConfig(secondaryConfig);
  const mergedPasswords = [];
  const mergedGames = {};
  const mergedBlocked = {};
  const blockedKeys = {};

  function addPassword(value) {
    const normalized = trimString(value);
    if (!normalized || mergedPasswords.includes(normalized)) return;
    mergedPasswords.push(normalized);
  }

  primary.passwords.forEach(addPassword);
  secondary.passwords.forEach(addPassword);

  primary.games.concat(secondary.games).forEach((gameId) => {
    mergedGames[gameId] = true;
  });

  Object.keys(primary.blocked).forEach((gameId) => {
    blockedKeys[gameId] = true;
  });
  Object.keys(secondary.blocked).forEach((gameId) => {
    blockedKeys[gameId] = true;
  });

  Object.keys(blockedKeys).forEach((gameId) => {
    const mergedValue = mergeBlockedValue(primary.blocked[gameId], secondary.blocked[gameId]);
    if (typeof mergedValue === 'undefined') return;
    mergedBlocked[gameId] = mergedValue;
    mergedGames[gameId] = true;
  });

  return {
    password: mergedPasswords[0] || '',
    passwords: mergedPasswords,
    blocked: mergedBlocked,
    games: Object.keys(mergedGames).sort(),
    allowedIps: mergeAllowedIpMaps(primary.allowedIps, secondary.allowedIps),
  };
}

export function serializeConfig(config) {
  const normalized = normalizeConfig(config);
  return {
    password: normalized.password,
    passwords: normalized.passwords,
    blocked: normalized.blocked,
    games: normalized.games,
    allowedIps: normalized.allowedIps,
  };
}

export function parseJsonp(text) {
  const body = trimString(text);
  const match = body.match(/^[^(]+\(([\s\S]*)\)\s*;?$/);
  if (!match) {
    throw new Error('invalid JSONP response');
  }
  return JSON.parse(match[1]);
}

export async function loadEnvFile(filePath) {
  const values = {};
  let text = '';

  try {
    text = await fs.readFile(filePath, 'utf8');
  } catch (error) {
    return values;
  }

  text.split(/\r?\n/).forEach((line) => {
    const trimmed = trimString(line);
    if (!trimmed || trimmed.startsWith('#')) return;
    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) return;
    const key = trimString(trimmed.slice(0, eqIndex));
    const value = trimmed.slice(eqIndex + 1);
    if (!key) return;
    values[key] = value;
  });

  return values;
}

export function deriveGitHubRepo(jsdelivrUrl) {
  const match = trimString(jsdelivrUrl).match(/\/gh\/([^@/]+\/[^@/]+)@/i);
  return match ? match[1] : '';
}

export function compareJsdelivrVersions(left, right) {
  const leftParts = trimString(left).split('.');
  const rightParts = trimString(right).split('.');
  const length = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < length; index += 1) {
    const leftValue = Number(leftParts[index] || 0);
    const rightValue = Number(rightParts[index] || 0);
    if (leftValue !== rightValue) return leftValue - rightValue;
  }

  return trimString(left).localeCompare(trimString(right));
}

export function parseJsdelivrUrlInfo(jsdelivrUrl) {
  const cleaned = trimString(jsdelivrUrl).replace(/[?#].*$/, '');
  const match = cleaned.match(/^https:\/\/cdn\.jsdelivr\.net\/gh\/([^@/]+\/[^@/]+)@([^/]+)\/(.+)$/i);

  if (!match) {
    return {
      repo: deriveGitHubRepo(jsdelivrUrl),
      version: '',
      filePath: '',
      url: cleaned,
    };
  }

  return {
    repo: trimString(match[1]),
    version: trimString(match[2]),
    filePath: trimString(match[3]),
    url: cleaned,
  };
}

export function buildJsdelivrVersionUrl(infoOrUrl, version) {
  const info = typeof infoOrUrl === 'string' ? parseJsdelivrUrlInfo(infoOrUrl) : (infoOrUrl || {});
  const repo = trimString(info.repo);
  const filePath = trimString(info.filePath);
  const normalizedVersion = trimString(version);

  if (!repo || !filePath || !normalizedVersion) return '';
  return `https://cdn.jsdelivr.net/gh/${repo}@${normalizedVersion}/${filePath}`;
}

export async function resolveJsdelivrReadUrls(jsdelivrUrl, fetchImpl = fetch) {
  const candidates = [];
  const normalizedUrl = trimString(jsdelivrUrl);
  const info = parseJsdelivrUrlInfo(normalizedUrl);

  if (normalizedUrl) candidates.push(normalizedUrl);
  if (!info.repo || !info.filePath) return candidates;

  try {
    const response = await fetchImpl(withCacheBust(`https://data.jsdelivr.com/v1/package/gh/${info.repo}`), {
      headers: { Accept: 'application/json' },
    });
    if (response.ok) {
      const payload = await response.json();
      const versions = Array.isArray(payload && payload.versions) ? payload.versions.slice().sort(compareJsdelivrVersions) : [];
      const latestVersion = versions.length ? trimString(versions[versions.length - 1]) : '';
      const versionUrl = buildJsdelivrVersionUrl(info, latestVersion);
      if (versionUrl) candidates.unshift(versionUrl);
    }
  } catch (error) {
    // Fall back to the configured URL when the metadata endpoint is unavailable.
  }

  return candidates.filter((value, index) => value && candidates.indexOf(value) === index);
}

function withCacheBust(url) {
  const separator = url.includes('?') ? '&' : '?';
  return `${url}${separator}t=${Date.now()}`;
}

export async function readJsdelivrConfig(jsdelivrUrl, fetchImpl = fetch) {
  if (!trimString(jsdelivrUrl)) {
    return { ok: false, source: 'jsdelivr', reason: 'missing url' };
  }

  const readUrls = await resolveJsdelivrReadUrls(jsdelivrUrl, fetchImpl);
  let lastFailure = { ok: false, source: 'jsdelivr', reason: 'missing url' };

  for (const readUrl of readUrls) {
    try {
      const response = await fetchImpl(withCacheBust(readUrl), {
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) {
        lastFailure = { ok: false, source: 'jsdelivr', status: response.status, url: readUrl };
        continue;
      }
      const config = normalizeConfig(await response.json());
      return { ok: true, source: 'jsdelivr', config, url: readUrl };
    } catch (error) {
      lastFailure = { ok: false, source: 'jsdelivr', reason: error.message, url: readUrl };
    }
  }

  return lastFailure;
}

export async function readGasConfig(gasUrl, fetchImpl = fetch) {
  if (!trimString(gasUrl)) {
    return { ok: false, source: 'gas', reason: 'missing url' };
  }

  try {
    const url = new URL(gasUrl);
    url.searchParams.set('action', 'read');
    url.searchParams.set('callback', 'syncRemoteConfigRead');
    url.searchParams.set('t', String(Date.now()));

    const response = await fetchImpl(url, {
      headers: { Accept: 'application/javascript,text/plain,*/*' },
    });
    if (!response.ok) {
      return { ok: false, source: 'gas', status: response.status };
    }
    const payload = parseJsonp(await response.text());
    if (payload && payload.error) {
      return { ok: false, source: 'gas', reason: payload.error };
    }
    return { ok: true, source: 'gas', config: normalizeConfig(payload) };
  } catch (error) {
    return { ok: false, source: 'gas', reason: error.message };
  }
}

export async function writeGasConfig({ gasUrl, gasSecret, config, fetchImpl = fetch }) {
  if (!trimString(gasUrl) || !trimString(gasSecret)) {
    return { attempted: false, ok: false, reason: 'missing GAS credentials' };
  }

  const url = new URL(gasUrl);
  url.searchParams.set('action', 'write');
  url.searchParams.set('key', gasSecret);
  url.searchParams.set('writeAction', 'fullSync');
  url.searchParams.set('config', JSON.stringify(serializeConfig(config)));
  url.searchParams.set('callback', 'syncRemoteConfigWrite');

  const response = await fetchImpl(url, {
    headers: { Accept: 'application/javascript,text/plain,*/*' },
  });
  const payload = parseJsonp(await response.text());

  if (!response.ok || !payload || payload.error) {
    throw new Error(payload && payload.error ? payload.error : `GAS write failed (${response.status})`);
  }

  return {
    attempted: true,
    ok: true,
    response: payload,
  };
}

export async function writeGitHubConfig({ githubRepo, githubPat, config, fetchImpl = fetch }) {
  const repo = trimString(githubRepo);
  const pat = trimString(githubPat);
  if (!repo || !pat) {
    return { attempted: false, ok: false, reason: 'missing GitHub credentials' };
  }

  const apiUrl = `https://api.github.com/repos/${repo}/contents/config.json`;
  const headers = {
    Authorization: `token ${pat}`,
    Accept: 'application/vnd.github+json',
    'Content-Type': 'application/json',
  };
  let sha = '';

  const readResponse = await fetchImpl(apiUrl, {
    headers: {
      Authorization: `token ${pat}`,
      Accept: 'application/vnd.github+json',
    },
  });

  if (readResponse.ok) {
    const body = await readResponse.json();
    sha = trimString(body.sha);
  } else if (readResponse.status !== 404) {
    throw new Error(`GitHub read failed (${readResponse.status})`);
  }

  const normalized = serializeConfig(config);
  const payload = {
    message: 'Sync config between GAS and jsDelivr',
    content: Buffer.from(`${JSON.stringify(normalized, null, 2)}\n`, 'utf8').toString('base64'),
  };
  if (sha) payload.sha = sha;

  const writeResponse = await fetchImpl(apiUrl, {
    method: 'PUT',
    headers,
    body: JSON.stringify(payload),
  });

  if (!writeResponse.ok) {
    throw new Error(`GitHub write failed (${writeResponse.status})`);
  }

  const writeBody = await writeResponse.json();
  const commitSha = trimString(writeBody && writeBody.commit && writeBody.commit.sha);
  if (!commitSha) {
    throw new Error('GitHub write missing commit sha');
  }

  let versionTag = '';
  for (let attempt = 0; attempt < 3 && !versionTag; attempt += 1) {
    const candidate = `0.0.${Date.now().toString()}${Math.floor(Math.random() * 1000).toString()}`;
    const tagResponse = await fetchImpl(`https://api.github.com/repos/${repo}/git/refs`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        ref: `refs/tags/${candidate}`,
        sha: commitSha,
      }),
    });

    if (tagResponse.ok) {
      versionTag = candidate;
      break;
    }

    if (tagResponse.status !== 422) {
      throw new Error(`GitHub tag failed (${tagResponse.status})`);
    }
  }

  if (!versionTag) {
    throw new Error('GitHub tag failed (duplicate tag collisions)');
  }

  return {
    attempted: true,
    ok: true,
    status: writeResponse.status,
    versionTag,
  };
}

export async function purgeJsdelivr({ githubRepo, fetchImpl = fetch }) {
  const repo = trimString(githubRepo);
  if (!repo) {
    return { attempted: false, ok: false, reason: 'missing GitHub repo' };
  }

  const purgeUrl = `https://purge.jsdelivr.net/gh/${repo}@latest/config.json`;
  const response = await fetchImpl(purgeUrl);
  return {
    attempted: true,
    ok: response.ok,
    status: response.status,
  };
}

export async function writeLocalConfig(localConfigPath, config) {
  if (!trimString(localConfigPath)) {
    return { attempted: false, ok: false, reason: 'missing local path' };
  }

  await fs.writeFile(localConfigPath, `${JSON.stringify(serializeConfig(config), null, 2)}\n`, 'utf8');
  return { attempted: true, ok: true, path: localConfigPath };
}

export function summarizeReadResult(result) {
  if (!result.attempted && result.ok === false) return `${result.source}: skipped`;
  if (result.ok) return `${result.source}: ok`;
  if (typeof result.status !== 'undefined') return `${result.source}: HTTP ${result.status}`;
  return `${result.source}: ${result.reason || 'failed'}`;
}

export async function syncRemoteConfig(options = {}) {
  const gasResult = await readGasConfig(options.gasUrl, options.fetchImpl);
  const jsdelivrResult = await readJsdelivrConfig(options.jsdelivrUrl, options.fetchImpl);
  let mergedConfig;

  if (gasResult.ok && jsdelivrResult.ok) {
    mergedConfig = mergeRemoteConfigs(jsdelivrResult.config, gasResult.config);
  } else if (gasResult.ok) {
    mergedConfig = normalizeConfig(gasResult.config);
  } else if (jsdelivrResult.ok) {
    mergedConfig = normalizeConfig(jsdelivrResult.config);
  } else {
    throw new Error(`No readable remote config source (${summarizeReadResult(gasResult)}; ${summarizeReadResult(jsdelivrResult)})`);
  }

  const githubRepo = trimString(options.githubRepo) || deriveGitHubRepo(options.jsdelivrUrl);
  const result = {
    mergedConfig: serializeConfig(mergedConfig),
    reads: {
      gas: gasResult,
      jsdelivr: jsdelivrResult,
    },
    writes: {
      gas: { attempted: false, ok: false, reason: 'dry run' },
      github: { attempted: false, ok: false, reason: 'dry run' },
      jsdelivr: { attempted: false, ok: false, reason: 'dry run' },
      local: { attempted: false, ok: false, reason: 'dry run' },
    },
  };

  if (options.dryRun) {
    return result;
  }

  result.writes.gas = await writeGasConfig({
    gasUrl: options.gasUrl,
    gasSecret: options.gasSecret,
    config: result.mergedConfig,
    fetchImpl: options.fetchImpl,
  });

  result.writes.github = await writeGitHubConfig({
    githubRepo,
    githubPat: options.githubPat,
    config: result.mergedConfig,
    fetchImpl: options.fetchImpl,
  });

  if (result.writes.github.ok) {
    result.writes.jsdelivr = await purgeJsdelivr({
      githubRepo,
      fetchImpl: options.fetchImpl,
    });
  } else {
    result.writes.jsdelivr = {
      attempted: false,
      ok: false,
      reason: 'GitHub write skipped',
    };
  }

  if (trimString(options.localConfigPath)) {
    result.writes.local = await writeLocalConfig(options.localConfigPath, result.mergedConfig);
  }

  return result;
}

export async function loadSyncSettings({
  cwd = process.cwd(),
  env = process.env,
  secureConfigPath,
} = {}) {
  const rootDir = cwd;
  const configPath = secureConfigPath || path.join(rootDir, '.secure-config');
  const fileValues = await loadEnvFile(configPath);

  return {
    rootDir,
    secureConfigPath: configPath,
    jsdelivrUrl: trimString(env.JSDELIVR_URL || fileValues.JSDELIVR_URL),
    gasUrl: trimString(env.GAS_URL || fileValues.GAS_URL),
    gasSecret: trimString(env.GAS_SECRET || fileValues.GAS_SECRET),
    githubRepo: trimString(env.GITHUB_REPO || fileValues.GITHUB_REPO),
    githubPat: trimString(env.GITHUB_PAT || fileValues.GITHUB_PAT),
    localConfigPath: path.join(rootDir, 'config.json'),
  };
}
