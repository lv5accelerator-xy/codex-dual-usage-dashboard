'use strict';

// Local-only manual browser fixture. It never contacts ntfy or Codex.
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const root = path.resolve(__dirname, '..', 'mobile');
const port = Number(process.env.MOBILE_FIXTURE_PORT || 8766);
const keys = {
  two: 'test-pair-key-123456789',
  one: 'one-account-key-123456',
  stale: 'stale-pair-key-123456789',
  failure: 'failure-pair-key-1234567'
};

function topic(pairKey) {
  return `codex-usage-${crypto.createHash('sha256').update(`codex-mobile-usage-topic-v1|${pairKey}`).digest('hex').slice(0, 48)}`;
}

function encrypt(value, pairKey) {
  const enc = crypto.createHash('sha256').update(`codex-remote-enc-v1|${pairKey}`).digest();
  const mac = crypto.createHash('sha256').update(`codex-remote-mac-v1|${pairKey}`).digest();
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-cbc', enc, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  const body = Buffer.concat([iv, ciphertext]);
  return Buffer.concat([body, crypto.createHmac('sha256', mac).update(body).digest()]).toString('base64');
}

function snapshot(mode) {
  const now = Date.now();
  if (mode === 'failure') return {
    version: 1, type: 'usage_snapshot', deviceId: 'fixture-device', deviceName: 'Fixture PC', publishedAt: new Date(now).toISOString(),
    profiles: [{ id: 'personal', label: 'Personal', ok: false, status: 'error', fetchedAt: new Date(now - 60000).toISOString(), fiveHour: null, longTerm: null }]
  };
  const profiles = [{
    id: 'personal', label: 'Personal', ok: true, status: 'ok', fetchedAt: new Date(now - 15000).toISOString(),
    fiveHour: { kind: '5h', label: '5 Hours', remainingPercent: 0, resetsAt: new Date(now - 60000).toISOString() },
    longTerm: { kind: 'weekly', label: 'Weekly', remainingPercent: 100, resetsAt: null }
  }];
  if (mode === 'two') profiles.push({
    id: 'work', label: 'Work · International Workspace Name', ok: true, status: 'ok', fetchedAt: new Date(now - 10000).toISOString(),
    fiveHour: { kind: '5h', label: '5 Hours', remainingPercent: 41, resetsAt: new Date(now + 4 * 3600000 + 8 * 60000).toISOString() },
    longTerm: { kind: 'workspace', label: 'Workspace / Monthly', remainingPercent: 27, resetsAt: new Date(now + 3 * 86400000 + 12 * 3600000).toISOString() }
  });
  const publishedAt = mode === 'stale' ? now - 11 * 60000 : now;
  return { version: 1, type: 'usage_snapshot', deviceId: 'fixture-device', deviceName: 'Fixture PC', publishedAt: new Date(publishedAt).toISOString(), profiles };
}

const topics = new Map(Object.entries(keys).map(([mode, key]) => [topic(key), mode]));
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };

http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const segments = url.pathname.split('/').filter(Boolean);
  if (segments.length >= 2 && segments[0].startsWith('codex-usage-')) {
    const mode = topics.get(segments[0]) || 'two';
    const cipher = encrypt(snapshot(mode), keys[mode]);
    if (segments[1] === 'json') {
      response.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' });
      response.end(`${JSON.stringify({ id: 'fixture', event: 'message', message: cipher })}\n`);
      return;
    }
    if (segments[1] === 'sse') {
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive', 'Access-Control-Allow-Origin': '*' });
      response.end(`event: message\ndata: ${JSON.stringify({ id: 'fixture-live', event: 'message', message: cipher })}\n\n`);
      return;
    }
  }

  let relative = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.resolve(root, relative);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    response.writeHead(404); response.end('Not found'); return;
  }
  response.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
  fs.createReadStream(file).pipe(response);
}).listen(port, '127.0.0.1', () => process.stdout.write(`Mobile fixture server: http://127.0.0.1:${port}/\n`));
