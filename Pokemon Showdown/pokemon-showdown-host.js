#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const tls = require('tls');
const path = require('path');
const os = require('os');

const PORT = Number(process.env.SHOWDOWN_HOST_PORT || 8787);
const BIND = process.env.SHOWDOWN_HOST_BIND || '0.0.0.0';
const PLAY_HOST = 'play.pokemonshowdown.com';
const SIM_HOST = 'sim3.psim.us';

const BASE_DIR = __dirname;
const REGULAR_FILE = path.join(BASE_DIR, 'pokemon-showdown-regular.html');
const LOCKED_B64_FILE = path.join(BASE_DIR, 'pokemon-showdown-locked-b64.html');

function copyHeaders(headers, host) {
  const out = { ...headers };
  delete out['proxy-connection'];
  out.host = host;
  return out;
}

function proxyHttp(req, res, opts) {
  const upstream = https.request(
    {
      hostname: opts.host,
      port: 443,
      method: req.method,
      path: opts.path,
      headers: copyHeaders(req.headers, opts.host),
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    }
  );

  upstream.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`Upstream proxy error: ${err.message}\n`);
  });

  req.pipe(upstream);
}

function serveFile(filePath, res) {
  fs.readFile(filePath, 'utf8', (err, content) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(`Failed to read file: ${filePath}\n`);
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(content);
  });
}

function routeRequest(req, res) {
  const rawUrl = req.url || '/';

  if (rawUrl === '/' || rawUrl === '/index.html' || rawUrl === '/pokemon-showdown') {
    serveFile(REGULAR_FILE, res);
    return;
  }
  if (rawUrl === '/locked' || rawUrl === '/pokemon-showdown-locked-b64.html') {
    serveFile(LOCKED_B64_FILE, res);
    return;
  }
  if (rawUrl.startsWith('/ps/')) {
    proxyHttp(req, res, { host: PLAY_HOST, path: rawUrl.slice(3) });
    return;
  }
  if (rawUrl.startsWith('/showdown/')) {
    proxyHttp(req, res, { host: SIM_HOST, path: rawUrl });
    return;
  }
  if (rawUrl.startsWith('/~~')) {
    proxyHttp(req, res, { host: PLAY_HOST, path: rawUrl });
    return;
  }
  if (rawUrl.startsWith('/config/')) {
    proxyHttp(req, res, { host: PLAY_HOST, path: rawUrl });
    return;
  }
  if (rawUrl.startsWith('/customcss.php')) {
    proxyHttp(req, res, { host: PLAY_HOST, path: rawUrl });
    return;
  }
  if (rawUrl === '/favicon.ico') {
    proxyHttp(req, res, { host: PLAY_HOST, path: '/favicon.ico' });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found\n');
}

function routeUpgrade(req, socket, head) {
  const rawUrl = req.url || '';
  if (!rawUrl.startsWith('/showdown/')) {
    socket.destroy();
    return;
  }

  const upstream = tls.connect(
    443,
    SIM_HOST,
    { servername: SIM_HOST },
    () => {
      let requestHead = `${req.method} ${rawUrl} HTTP/${req.httpVersion}\r\n`;
      for (const [name, value] of Object.entries(req.headers)) {
        if (name.toLowerCase() === 'host') {
          requestHead += `Host: ${SIM_HOST}\r\n`;
        } else {
          requestHead += `${name}: ${value}\r\n`;
        }
      }
      requestHead += '\r\n';
      upstream.write(requestHead);
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    }
  );

  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
}

const server = http.createServer(routeRequest);
server.on('upgrade', routeUpgrade);

server.listen(PORT, BIND, () => {
  const hostNameRaw = os.hostname();
  const hostName = hostNameRaw.endsWith('.local') ? hostNameRaw : `${hostNameRaw}.local`;
  console.log(`Pokemon Showdown host proxy listening on ${BIND}:${PORT}`);
  console.log(`Open on this Mac: http://localhost:${PORT}/pokemon-showdown`);
  console.log(`Open on Chromebook (same Wi-Fi): http://${hostName}:${PORT}/pokemon-showdown`);
  console.log(`Locked version: http://${hostName}:${PORT}/locked`);
});
