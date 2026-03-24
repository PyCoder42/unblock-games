/**
 * Google Apps Script — Unblock Games Remote Config Server
 *
 * Deploy as: Web app -> "Anyone" can access
 *
 * Setup:
 *   1. Create a new Google Apps Script project at script.google.com
 *   2. Replace the default Code.gs content with this file
 *   3. Go to Project Settings -> Script Properties and add:
 *      - secretKey = <your chosen passphrase>
 *      - config = {}
 *      - githubRepo = <owner/repo for config.json>
 *      - githubPat = <fine-grained PAT with Contents read/write>
 *   4. Deploy -> New deployment -> Web app -> "Anyone" -> Deploy
 *   5. Copy the deployment URL (https://script.google.com/macros/s/.../exec)
 *
 * Reads are public (no key needed). Writes require the secret key (or a valid fake key).
 * All writes persist to GAS first, then mirror to GitHub so jsDelivr serves
 * the same config without any direct GitHub access from browser clients.
 *
 * Multi-key auth:
 *   - The real secretKey has full access (config + fake key management)
 *   - Fake keys (stored in 'fakeKeys' Script Property) can do normal config operations
 *     but cannot manage other keys. Fake keys can be individually revoked.
 *
 * Endpoints (all via GET, JSONP):
 *   ?action=read&callback=cb
 *   ?action=readKeys&key=SECRET&callback=cb                        (real key only)
 *   ?action=write&key=SECRET&writeAction=updatePassword&password=NEW&callback=cb
 *   ?action=write&key=SECRET&writeAction=block&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=unblock&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=timeblock&game=GAME_ID&until=ISO_DATE&callback=cb
 *   ?action=write&key=SECRET&writeAction=addGame&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=removeGame&game=GAME_ID&callback=cb
 *   ?action=write&key=SECRET&writeAction=setAllowedIp&ip=IP&label=LABEL&callback=cb
 *   ?action=write&key=SECRET&writeAction=removeAllowedIp&ip=IP&callback=cb
 *   ?action=write&key=SECRET&writeAction=fullSync&config=JSON_STRING&callback=cb
 *   ?action=write&key=SECRET&writeAction=addFakeKey&label=LABEL&callback=cb   (real key only)
 *   ?action=write&key=SECRET&writeAction=revokeFakeKey&fakeKey=KEY_OR_ID&callback=cb  (real key only)
 *   ?action=write&key=SECRET&writeAction=unrevokeFakeKey&fakeKey=KEY_OR_ID&callback=cb (real key only)
 *   ?action=write&key=SECRET&writeAction=removeFakeKey&fakeKey=KEY_OR_ID&callback=cb  (real key only)
 */

function trimString(value) {
  return String(value == null ? '' : value).replace(/^\s+|\s+$/g, '');
}

function isPlaceholderIp(value) {
  var normalized = trimString(value).toLowerCase();
  return normalized === '0.0.0.0' ||
    normalized === '::' ||
    normalized === '0:0:0:0:0:0:0:0' ||
    normalized === '::ffff:0.0.0.0';
}

function isLoopbackIp(value) {
  var normalized = trimString(value).toLowerCase();
  return /^127\./.test(normalized) ||
    normalized === '::1' ||
    normalized === '0:0:0:0:0:0:0:1' ||
    normalized === 'localhost';
}

function isValidIpv4(value) {
  var normalized = trimString(value);
  if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(normalized)) return false;

  return normalized.split('.').every(function(part) {
    var numeric = Number(part);
    return numeric >= 0 && numeric <= 255;
  });
}

function isLikelyIpv6(value) {
  var normalized = trimString(value).toLowerCase();
  var parts;
  var nonEmpty = 0;
  var i;

  if (normalized.indexOf(':') === -1) return false;
  if (!/^[0-9a-f:]+$/.test(normalized)) return false;
  if (normalized.indexOf(':::') !== -1) return false;

  parts = normalized.split(':');
  for (i = 0; i < parts.length; i++) {
    if (!parts[i]) continue;
    if (parts[i].length > 4) return false;
    nonEmpty++;
  }

  if (normalized.indexOf('::') === -1) {
    return parts.length === 8 && nonEmpty === 8;
  }
  return parts.length <= 8 && nonEmpty > 0;
}

function isUsableAllowedIp(value) {
  var normalized = trimString(value);
  if (!normalized) return false;
  if (isPlaceholderIp(normalized) || isLoopbackIp(normalized)) return false;
  return isValidIpv4(normalized) || isLikelyIpv6(normalized);
}

function normalizeGameId(value) {
  var normalized = trimString(value).toLowerCase();
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

function normalizeBlockedMap(rawBlocked) {
  var output = {};
  var blocked = rawBlocked && typeof rawBlocked === 'object' ? rawBlocked : {};
  var keys = Object.keys(blocked);

  for (var i = 0; i < keys.length; i++) {
    var normalizedKey = normalizeGameId(keys[i]);
    var value = blocked[keys[i]];
    if (!normalizedKey) continue;
    if (value === true) {
      output[normalizedKey] = true;
    } else if (typeof value === 'string' && trimString(value)) {
      output[normalizedKey] = trimString(value);
    }
  }

  return output;
}

function setAllowedIpEntry(target, ip, label) {
  var normalizedLabel = trimString(label);

  String(ip == null ? '' : ip).split(',').forEach(function(candidate) {
    var normalizedIp = trimString(candidate);
    if (!isUsableAllowedIp(normalizedIp)) return;

    target[normalizedIp] = {
      label: normalizedLabel,
    };
  });
}

function normalizeAllowedIps(rawAllowedIps) {
  var output = {};
  var i;

  if (!rawAllowedIps) return output;

  if (Array.isArray(rawAllowedIps)) {
    for (i = 0; i < rawAllowedIps.length; i++) {
      var entry = rawAllowedIps[i];
      if (typeof entry === 'string') {
        setAllowedIpEntry(output, entry, '');
      } else if (entry && typeof entry === 'object') {
        setAllowedIpEntry(output, entry.ip || entry.address, entry.label);
      }
    }
  } else if (typeof rawAllowedIps === 'object') {
    var keys = Object.keys(rawAllowedIps);
    for (i = 0; i < keys.length; i++) {
      var key = keys[i];
      var item = rawAllowedIps[key];
      if (item && typeof item === 'object' && !Array.isArray(item)) {
        setAllowedIpEntry(output, key, item.label);
      } else {
        setAllowedIpEntry(output, key, item);
      }
    }
  }

  var sorted = {};
  var sortedKeys = Object.keys(output).sort();
  for (i = 0; i < sortedKeys.length; i++) {
    sorted[sortedKeys[i]] = output[sortedKeys[i]];
  }
  return sorted;
}

function normalizeGames(rawGames, blockedMap) {
  var unique = {};
  var list = Array.isArray(rawGames) ? rawGames : [];
  var i;

  for (i = 0; i < list.length; i++) {
    var normalized = normalizeGameId(list[i]);
    if (normalized) unique[normalized] = true;
  }

  var blockedKeys = Object.keys(blockedMap || {});
  for (i = 0; i < blockedKeys.length; i++) {
    unique[blockedKeys[i]] = true;
  }

  return Object.keys(unique).sort();
}

function normalizeConfig(rawConfig) {
  var input = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  var blocked = normalizeBlockedMap(input.blocked);
  var passwords = [];

  function addPassword(value) {
    var normalized = trimString(value);
    if (!normalized || passwords.indexOf(normalized) !== -1) return;
    passwords.push(normalized);
  }

  addPassword(input.password);
  if (Array.isArray(input.passwords)) {
    input.passwords.forEach(addPassword);
  }

  return {
    password: passwords[0] || '',
    passwords: passwords,
    blocked: blocked,
    games: normalizeGames(input.games, blocked),
    allowedIps: normalizeAllowedIps(input.allowedIps || input.allowedIPs || input.allowedIpAddresses),
  };
}

function parseJson(text, fallbackValue) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return fallbackValue;
  }
}

function keyIdentifier(key) {
  var hash = 5381;
  for (var i = 0; i < key.length; i++) {
    hash = ((hash << 5) + hash + key.charCodeAt(i)) & 0x7fffffff;
  }
  return hash.toString(36).slice(0, 6);
}

function generateFakeKey() {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  var key = '';
  for (var i = 0; i < 20; i++) {
    key += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return key;
}

function readFakeKeys(props) {
  return parseJson(props.getProperty('fakeKeys') || '{}', {});
}

function saveFakeKeys(props, fakeKeys) {
  props.setProperty('fakeKeys', JSON.stringify(fakeKeys));
}

function findFakeKeyByKeyOrId(fakeKeys, keyOrId) {
  keyOrId = trimString(keyOrId);
  if (!keyOrId) return null;

  // Direct key match
  if (fakeKeys[keyOrId]) return keyOrId;

  // Match by identifier
  var keys = Object.keys(fakeKeys);
  for (var i = 0; i < keys.length; i++) {
    if (keyIdentifier(keys[i]) === keyOrId) return keys[i];
  }

  return null;
}

function authenticateKey(params, props) {
  var key = trimString(params.key);
  if (!key) return null;

  var realKey = props.getProperty('secretKey') || '';
  if (key === realKey) return { type: 'real' };

  var fakeKeys = readFakeKeys(props);
  if (fakeKeys[key] && !fakeKeys[key].revoked) {
    // Update last-seen metadata
    fakeKeys[key].lastIp = trimString(params.ip || '');
    fakeKeys[key].lastSeen = new Date().toISOString();
    saveFakeKeys(props, fakeKeys);
    return { type: 'fake', key: key };
  }

  return null; // unauthorized
}

function buildJsonp(callback, payload) {
  return ContentService.createTextOutput(callback + '(' + JSON.stringify(payload) + ')')
    .setMimeType(ContentService.MimeType.JAVASCRIPT);
}

function readStoredConfig(props) {
  return normalizeConfig(parseJson(props.getProperty('config') || '{}', {}));
}

function saveConfig(props, config) {
  var normalized = normalizeConfig(config);
  props.setProperty('config', JSON.stringify(normalized));
  return normalized;
}

function syncMirrorToGitHub(props, config) {
  var githubRepo = trimString(props.getProperty('githubRepo') || props.getProperty('GITHUB_REPO'));
  var githubPat = trimString(props.getProperty('githubPat') || props.getProperty('GITHUB_PAT'));
  var result = {
    attempted: false,
    github: false,
    jsdelivr: false,
  };

  if (!githubRepo || !githubPat) {
    return result;
  }

  result.attempted = true;

  var apiUrl = 'https://api.github.com/repos/' + githubRepo + '/contents/config.json';
  var headers = {
    Authorization: 'token ' + githubPat,
    Accept: 'application/vnd.github+json',
  };
  var sha = '';

  try {
    var readResponse = UrlFetchApp.fetch(apiUrl, {
      headers: headers,
      muteHttpExceptions: true,
    });
    if (readResponse.getResponseCode() === 200) {
      sha = parseJson(readResponse.getContentText(), {}).sha || '';
    }
  } catch (error) {}

  try {
    var body = {
      message: 'Sync config from GAS',
      content: Utilities.base64Encode(JSON.stringify(config)),
    };
    if (sha) body.sha = sha;

    var writeResponse = UrlFetchApp.fetch(apiUrl, {
      method: 'put',
      headers: headers,
      contentType: 'application/json',
      muteHttpExceptions: true,
      payload: JSON.stringify(body),
    });

    result.github = writeResponse.getResponseCode() === 200 || writeResponse.getResponseCode() === 201;
    if (result.github) {
      var writeBody = parseJson(writeResponse.getContentText(), {});
      var commitSha = trimString(writeBody && writeBody.commit && writeBody.commit.sha);

      if (!commitSha) {
        result.github = false;
      } else {
        var tagHeaders = {
          Authorization: 'token ' + githubPat,
          Accept: 'application/vnd.github+json',
          'Content-Type': 'application/json',
        };
        var tagged = false;
        var attempt = 0;

        while (!tagged && attempt < 3) {
          attempt += 1;
          var versionTag = '0.0.' + String(new Date().getTime()) + String(Math.floor(Math.random() * 1000));
          var tagResponse = UrlFetchApp.fetch('https://api.github.com/repos/' + githubRepo + '/git/refs', {
            method: 'post',
            headers: tagHeaders,
            contentType: 'application/json',
            muteHttpExceptions: true,
            payload: JSON.stringify({
              ref: 'refs/tags/' + versionTag,
              sha: commitSha,
            }),
          });

          if (tagResponse.getResponseCode() === 201) {
            tagged = true;
          } else if (tagResponse.getResponseCode() !== 422) {
            result.github = false;
            break;
          }
        }

        if (!tagged) {
          result.github = false;
        }
      }
    }
  } catch (error) {
    result.github = false;
  }

  if (!result.github) return result;

  try {
    var purgeUrl = 'https://purge.jsdelivr.net/gh/' + githubRepo + '@latest/config.json';
    var purgeResponse = UrlFetchApp.fetch(purgeUrl, {
      muteHttpExceptions: true,
    });
    result.jsdelivr = purgeResponse.getResponseCode() >= 200 && purgeResponse.getResponseCode() < 400;
  } catch (error) {
    result.jsdelivr = false;
  }

  return result;
}

function applyWriteAction(config, params) {
  var writeAction = params.writeAction || '';
  var gameId = normalizeGameId(params.game);
  var allowedIp = trimString(params.ip);

  if (writeAction === 'updatePassword') {
    config.password = trimString(params.password);
  } else if (writeAction === 'block') {
    if (gameId) config.blocked[gameId] = true;
  } else if (writeAction === 'unblock') {
    if (gameId && config.blocked) delete config.blocked[gameId];
  } else if (writeAction === 'timeblock') {
    if (gameId) config.blocked[gameId] = trimString(params.until);
  } else if (writeAction === 'addGame') {
    if (gameId) config.games.push(gameId);
  } else if (writeAction === 'removeGame') {
    if (gameId) {
      config.games = config.games.filter(function(existingId) { return existingId !== gameId; });
      delete config.blocked[gameId];
    }
  } else if (writeAction === 'setAllowedIp') {
    setAllowedIpEntry(config.allowedIps, allowedIp, params.label);
  } else if (writeAction === 'removeAllowedIp') {
    if (allowedIp) delete config.allowedIps[allowedIp];
  } else if (writeAction === 'fullSync') {
    return normalizeConfig(parseJson(params.config || '{}', {}));
  } else {
    throw new Error('unknown writeAction');
  }

  return normalizeConfig(config);
}

function serializeFakeKeysForResponse(fakeKeys) {
  var result = [];
  var keys = Object.keys(fakeKeys);
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    var entry = fakeKeys[k];
    result.push({
      key: k,
      identifier: keyIdentifier(k),
      label: entry.label || '',
      revoked: !!entry.revoked,
      lastIp: entry.lastIp || '',
      lastSeen: entry.lastSeen || '',
      created: entry.created || '',
    });
  }
  return result;
}

function applyFakeKeyAction(params, props) {
  var writeAction = params.writeAction || '';
  var fakeKeys = readFakeKeys(props);

  if (writeAction === 'addFakeKey') {
    var newKey = generateFakeKey();
    var label = trimString(params.label || '');
    fakeKeys[newKey] = {
      label: label,
      revoked: false,
      lastIp: '',
      lastSeen: '',
      created: new Date().toISOString(),
    };
    saveFakeKeys(props, fakeKeys);
    return {
      success: true,
      fakeKey: newKey,
      identifier: keyIdentifier(newKey),
      label: label,
    };
  }

  var targetKey = findFakeKeyByKeyOrId(fakeKeys, params.fakeKey);
  if (!targetKey) {
    throw new Error('fake key not found');
  }

  if (writeAction === 'revokeFakeKey') {
    fakeKeys[targetKey].revoked = true;
    saveFakeKeys(props, fakeKeys);
    return { success: true, identifier: keyIdentifier(targetKey), revoked: true };
  }

  if (writeAction === 'unrevokeFakeKey') {
    fakeKeys[targetKey].revoked = false;
    saveFakeKeys(props, fakeKeys);
    return { success: true, identifier: keyIdentifier(targetKey), revoked: false };
  }

  if (writeAction === 'removeFakeKey') {
    delete fakeKeys[targetKey];
    saveFakeKeys(props, fakeKeys);
    return { success: true, removed: true };
  }

  throw new Error('unknown writeAction');
}

var FAKE_KEY_ACTIONS = {
  addFakeKey: true,
  revokeFakeKey: true,
  unrevokeFakeKey: true,
  removeFakeKey: true,
};

function doGet(e) {
  var params = e && e.parameter ? e.parameter : {};
  var action = params.action || 'read';
  var callback = params.callback || 'callback';
  var props = PropertiesService.getScriptProperties();
  var config = readStoredConfig(props);

  if (action === 'read') {
    props.setProperty('config', JSON.stringify(config));
    return buildJsonp(callback, config);
  }

  if (action === 'readKeys') {
    // Only the real key can read fake key data
    var realKey = props.getProperty('secretKey') || '';
    if (trimString(params.key) !== realKey) {
      return buildJsonp(callback, { error: 'unauthorized' });
    }
    var fakeKeys = readFakeKeys(props);
    return buildJsonp(callback, {
      success: true,
      keys: serializeFakeKeysForResponse(fakeKeys),
    });
  }

  if (action !== 'write') {
    return buildJsonp(callback, { error: 'unknown action' });
  }

  var auth = authenticateKey(params, props);
  if (!auth) {
    return buildJsonp(callback, { error: 'unauthorized' });
  }

  var writeAction = params.writeAction || '';

  // Fake key management actions — real key only
  if (FAKE_KEY_ACTIONS[writeAction]) {
    if (auth.type !== 'real') {
      return buildJsonp(callback, { error: 'unauthorized' });
    }
    try {
      return buildJsonp(callback, applyFakeKeyAction(params, props));
    } catch (error) {
      return buildJsonp(callback, {
        error: error && error.message ? error.message : 'fake key action failed',
      });
    }
  }

  // Normal config write actions — both real and fake keys
  try {
    var updatedConfig = applyWriteAction(config, params);
    updatedConfig = saveConfig(props, updatedConfig);

    return buildJsonp(callback, {
      success: true,
      config: updatedConfig,
      mirror: syncMirrorToGitHub(props, updatedConfig),
    });
  } catch (error) {
    return buildJsonp(callback, {
      error: error && error.message ? error.message : 'write failed',
    });
  }
}
