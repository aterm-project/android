/*
 * PG-NATIVE-WEB-SYNC-01: prove that one signed native outbox survives a hard
 * process death, a separately enrolled Web device can update the same Host,
 * and both Snippet create/update revisions sync back to native. The Python fixture owns PostgreSQL,
 * Xvfb, D-Bus, the private HOME/XDG roots, and the result file.
 *
 * Runner output intentionally contains only UUIDs, operation metadata, and
 * booleans. Credentials, enrollment JSON, envelopes, OCR text, and host values
 * never enter logs or the result file.
 */
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { startPublicKeySshFixture } = require('./ssh_fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const ENV = 'ATERMIUS_NATIVE_WEB_SYNC_';
const NODE_A_URL = process.env[`${ENV}NODE_A_URL`];
const NODE_B_URL = process.env[`${ENV}NODE_B_URL`];
const USERNAME = process.env[`${ENV}USERNAME`];
const PASSWORD = process.env[`${ENV}PASSWORD`];
const BOOTSTRAP_TOKEN = process.env[`${ENV}BOOTSTRAP_TOKEN`];
const NATIVE_HOST = process.env[`${ENV}NATIVE_HOST`];
const WEB_HOST = process.env[`${ENV}WEB_HOST`];
const HOST_ADDRESS = process.env[`${ENV}HOST_ADDRESS`];
const SSH_USERNAME = process.env[`${ENV}SSH_USERNAME`];
const SSH_CREDENTIAL_NAME = process.env[`${ENV}CREDENTIAL_NAME`];
const SNIPPET_TITLE = process.env[`${ENV}SNIPPET_TITLE`];
const SNIPPET_BODY_MARKER = process.env[`${ENV}SNIPPET_BODY_MARKER`];
const SNIPPET_TAG = process.env[`${ENV}SNIPPET_TAG`];
const SNIPPET_UPDATED_TITLE = process.env[`${ENV}SNIPPET_UPDATED_TITLE`];
const SNIPPET_UPDATED_BODY_MARKER = process.env[`${ENV}SNIPPET_UPDATED_BODY_MARKER`];
const SNIPPET_UPDATED_TAG = process.env[`${ENV}SNIPPET_UPDATED_TAG`];
const SNIPPET_NATIVE_UPDATED_TITLE = process.env[`${ENV}SNIPPET_NATIVE_UPDATED_TITLE`];
const SNIPPET_NATIVE_UPDATED_BODY_MARKER = process.env[`${ENV}SNIPPET_NATIVE_UPDATED_BODY_MARKER`];
const SNIPPET_NATIVE_UPDATED_TAG = process.env[`${ENV}SNIPPET_NATIVE_UPDATED_TAG`];
const SFTP_BINARY_UPLOAD_PATH = process.env[`${ENV}SFTP_BINARY_UPLOAD_PATH`];
const SFTP_BINARY_COLLISION_PATH = process.env[`${ENV}SFTP_BINARY_COLLISION_PATH`];
const SFTP_TEXT_UPLOAD_PATH = process.env[`${ENV}SFTP_TEXT_UPLOAD_PATH`];
const SFTP_BINARY_DOWNLOAD_PATH = process.env[`${ENV}SFTP_BINARY_DOWNLOAD_PATH`];
const SFTP_TEXT_DOWNLOAD_PATH = process.env[`${ENV}SFTP_TEXT_DOWNLOAD_PATH`];
const SFTP_BINARY_MARKER = process.env[`${ENV}SFTP_BINARY_MARKER`];
const SFTP_TEXT_MARKER = process.env[`${ENV}SFTP_TEXT_MARKER`];
const SFTP_TEXT_EDITED_MARKER = process.env[`${ENV}SFTP_TEXT_EDITED_MARKER`];
const HOME = process.env[`${ENV}HOME`] || process.env.HOME;
const NATIVE_APP = process.env[`${ENV}NATIVE_APP`];
const WEB_ROOT = process.env[`${ENV}WEB_ROOT`] || path.join(ROOT, 'apps/client/build/web');
const RESULT_FILE = process.env[`${ENV}RESULT_FILE`];
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined;
const PG_URL = process.env.ATERMIUS_SYNC_PG_URL;
const PG_SCHEMA = process.env.ATERMIUS_SYNC_PG_SCHEMA || 'public';
const MARKERS = [USERNAME, PASSWORD, BOOTSTRAP_TOKEN, NATIVE_HOST, WEB_HOST,
  HOST_ADDRESS, SSH_USERNAME, SSH_CREDENTIAL_NAME, SFTP_BINARY_MARKER,
  SFTP_TEXT_MARKER, SFTP_TEXT_EDITED_MARKER].filter((value) => typeof value === 'string' && value);
const EXTRA_PERSISTENCE_MARKERS = [];

const API_EVENTS = [];
const PAGE_COUNTS = { pageErrors: 0, consoleErrors: 0, unexpectedRequestErrors: 0 };
const WEB_PUSHES = [];
const NATIVE_PUSHES = [];
const NATIVE_HELD_PUSHES = [];
const PROXY_SOCKETS = new Set();
const CHILDREN = new Set();
let nativeServer = null;
let webServer = null;
let browser = null;
let browserContext = null;
let webPage = null;
let nativeProcess = null;
let nativePushReleased = false;
let nativeHeldPushCount = 0;
let nativeHeldOperationIds = [];
let nativeDurableOutboxMatchedAtHeldPush = false;
let webOrigin = null;
let keyringStarted = false;
let nativeWindowId = null;
let nativeSyncDatabasePathCache = null;
let sshFixture = null;
let sshPrivateKeyPem = null;
let sshPrivateKeyMarkers = [];

function persistenceMarkers() {
  return [...new Set([NATIVE_HOST, WEB_HOST, HOST_ADDRESS, SSH_USERNAME,
    SSH_CREDENTIAL_NAME, ...(sshFixture?.username ? [sshFixture.username] : []),
    ...sshPrivateKeyMarkers, ...EXTRA_PERSISTENCE_MARKERS]
    .filter((value) => typeof value === 'string' && value.length > 0))];
}

function pemPrivacyMarkers(pem) {
  const normalized = String(pem || '').replace(/\r\n?/g, '\n');
  const body = normalized.replace(/^-----BEGIN [^-]+-----|-----END [^-]+-----$/gm, '')
    .replace(/\s/g, '');
  assertThat(body.length >= 128, 'generated SSH private key was too short for a privacy marker');
  return [normalized, body.slice(0, 64), body.slice(-64)];
}

function sshString(value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(bytes.length, 0);
  return Buffer.concat([length, bytes]);
}

function makeClientSshIdentity() {
  const pair = crypto.generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'sec1', format: 'pem' },
  });
  const publicJwk = crypto.createPublicKey(pair.publicKey).export({ format: 'jwk' });
  assertThat(publicJwk.crv === 'P-256' && publicJwk.x && publicJwk.y,
    'generated SSH public key was not P-256');
  const point = Buffer.concat([Buffer.from([4]), Buffer.from(publicJwk.x, 'base64url'),
    Buffer.from(publicJwk.y, 'base64url')]);
  const wire = Buffer.concat([sshString('ecdsa-sha2-nistp256'), sshString('nistp256'), sshString(point)]);
  return {
    privateKeyPem: pair.privateKey.trimEnd(),
    authorizedKeyLine: `ecdsa-sha2-nistp256 ${wire.toString('base64')} aterm-acceptance`,
    publicKeyDer: crypto.createPublicKey(pair.publicKey).export({ type: 'spki', format: 'der' }),
  };
}

function privateNativeRoots() {
  return [HOME, process.env.XDG_DATA_HOME, process.env.XDG_CONFIG_HOME,
    process.env.XDG_CACHE_HOME, process.env.XDG_STATE_HOME]
    .filter((value) => typeof value === 'string' && value);
}

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function stage(message) {
  process.stdout.write(`stage: ${message}\n`);
}

function validUuid(value) {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function sanitizeError(error) {
  let message = String(error?.message || error || 'unknown runner error');
  for (const marker of [...MARKERS].sort((a, b) => b.length - a.length)) {
    if (marker) message = message.split(marker).join('[redacted]');
  }
  return message.replace(/https?:\/\/[^\s]+/g, '[url]').slice(0, 500);
}

function loopbackTarget(value, label) {
  let url;
  try { url = new URL(value || ''); } catch (_) { throw new Error(`${label} URL is invalid`); }
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
    Number(url.port) > 0 && !url.username && !url.password,
  `${label} must be a loopback HTTP server`);
  return { hostname: url.hostname, port: Number(url.port) };
}

const upstreamA = loopbackTarget(NODE_A_URL, 'PostgreSQL node A');
const upstreamB = loopbackTarget(NODE_B_URL, 'PostgreSQL node B');

function markerFree(value) {
  if (Buffer.isBuffer(value)) {
    return !MARKERS.some((marker) => marker && value.includes(Buffer.from(marker, 'utf8')));
  }
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? null);
  return !MARKERS.some((marker) => marker && serialized.includes(marker));
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function operationRefs(body) {
  if (!body || !Array.isArray(body.operations)) return [];
  return body.operations.map((item) => {
    const header = item?.header || item?.envelope?.header || {};
    return {
      operationId: header.op_id || item?.op_id || null,
      recordId: header.record_id || null,
      revisionId: header.revision_id || null,
      baseRevisionId: header.base_revision_id || null,
      deviceId: header.device_id || null,
      deviceSeq: header.device_seq == null ? null : String(header.device_seq),
      operation: header.operation || null,
      vaultId: header.vault_id || body.vault_id || null,
      envelopeSha256: crypto.createHash('sha256').update(canonicalJson(item)).digest('hex'),
    };
  });
}

function changeEventRefs(body) {
  if (!body || !Array.isArray(body.events)) return [];
  return body.events.map((event) => {
    const envelope = event?.envelope || {};
    const header = envelope.header || {};
    return {
      recordId: event?.record_id || header.record_id || null,
      revisionId: event?.revision_id || header.revision_id || null,
      commitSeq: event?.commit_seq == null ? null : String(event.commit_seq),
      operation: event?.event_type || header.operation || null,
      envelopeSha256: crypto.createHash('sha256').update(canonicalJson(envelope)).digest('hex'),
    };
  });
}

function parseJson(buffer) {
  try { return buffer?.length ? JSON.parse(buffer.toString('utf8')) : null; } catch (_) { return null; }
}

function captureResponseIds(event, value) {
  if (!value || typeof value !== 'object') return;
  if (event.path === '/api/v1/auth/register' && event.method === 'POST') {
    event.authSummary = {
      accountId: value.account_id || null,
      deviceId: value.device_id || null,
      vaultId: Array.isArray(value.vaults) ? value.vaults[0]?.vault_id || null : null,
    };
  }
}

function recordApiEvent(event) {
  if (event.path.startsWith('/api/v1/')) API_EVENTS.push(event);
}

function routeApiRequest(request, response, target, node, holdNativePush) {
  let url;
  try { url = new URL(request.url || '/', 'http://127.0.0.1'); } catch (_) {
    response.writeHead(400); response.end(); return;
  }
  const isPush = request.method === 'POST' && /\/sync\/push$/.test(url.pathname);
  const observeNativeInstance = node === 'A' && request.method === 'GET' &&
    url.pathname === '/api/v1/instance';
  const observeNativeAuth = node === 'A' && request.method === 'POST' &&
    ['/api/v1/auth/prelogin', '/api/v1/auth/login', '/api/v1/auth/login/mfa'].includes(url.pathname);
  const observeChanges = request.method === 'GET' && /\/api\/v1\/vaults\/[^/]+\/changes$/.test(url.pathname);
  const capture = isPush || observeChanges ||
    (request.method === 'POST' && url.pathname === '/api/v1/auth/register');
  const event = capture || observeNativeInstance || observeNativeAuth ? {
    node, method: request.method || 'GET', path: url.pathname,
    status: null, atMs: Date.now(), refs: [], batchId: null, vaultId: null,
    responseSummary: null, markerFree: true,
  } : null;
  if (event) recordApiEvent(event);
  function forward(body) {
    const headers = { ...request.headers, host: `${target.hostname}:${target.port}` };
    delete headers.connection;
    delete headers['proxy-connection'];
    const upstream = http.request({
      hostname: target.hostname, port: target.port, method: request.method,
      path: `${url.pathname}${url.search}`, headers,
    }, (upstreamResponse) => {
      if (!capture) {
        if (event) event.status = upstreamResponse.statusCode || 502;
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        upstreamResponse.pipe(response);
        return;
      }
      const responseChunks = [];
      let responseBytes = 0;
      upstreamResponse.on('data', (chunk) => {
        responseBytes += chunk.length;
        if (responseBytes <= 8 * 1024 * 1024) responseChunks.push(chunk);
      });
      upstreamResponse.on('end', () => {
        const responseBody = responseBytes <= 8 * 1024 * 1024
          ? Buffer.concat(responseChunks) : Buffer.alloc(0);
        const parsedResponse = parseJson(responseBody);
        event.status = upstreamResponse.statusCode || 502;
        event.markerFree = event.markerFree && markerFree(responseBody);
        if (isPush) {
          const results = Array.isArray(parsedResponse?.results) ? parsedResponse.results : [];
          event.responseSummary = results.map((item) => ({
            operationId: item?.op_id || null,
            commitSeq: item?.commit_seq == null ? null : String(item.commit_seq),
            status: item?.status || null,
            errorCode: item?.error?.code || item?.code || null,
          }));
          (node === 'A' ? NATIVE_PUSHES : WEB_PUSHES).push(event);
        } else if (observeChanges) {
          event.refs = changeEventRefs(parsedResponse);
          event.markerFree = event.markerFree && markerFree(responseBody);
        } else {
          captureResponseIds(event, parsedResponse);
        }
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        response.end(responseBody);
      });
    });
    upstream.on('error', () => {
      if (event) event.status = 502;
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'application/json' });
      response.end('{"error":{"code":"UPSTREAM_UNAVAILABLE"}}');
    });
    if (capture) upstream.end(body);
    else request.pipe(upstream);
  }

  if (!capture) {
    forward(null);
    return;
  }
  const chunks = [];
  let requestBytes = 0;
  request.on('data', (chunk) => {
    requestBytes += chunk.length;
    if (requestBytes <= 8 * 1024 * 1024) chunks.push(chunk);
  });
  request.on('end', () => {
    if (requestBytes > 8 * 1024 * 1024) {
      response.writeHead(413); response.end(); return;
    }
    const body = Buffer.concat(chunks);
    const parsedBody = parseJson(body);
    if (event && isPush) {
      event.refs = operationRefs(parsedBody);
      event.vaultId = parsedBody?.vault_id || event.refs[0]?.vaultId || null;
      event.batchId = parsedBody?.batch_id || null;
      event.markerFree = markerFree(body);
      if (node === 'A' && holdNativePush && !nativePushReleased) {
        const durableSnapshotPath = nativeDatabasePath();
        let durableSnapshot = null;
        try { if (durableSnapshotPath) durableSnapshot = inspectNativeDatabase(durableSnapshotPath); } catch (_) {}
        const matchingPending = event.refs.length > 0 && event.refs.every((ref) =>
          durableSnapshot?.pending?.some((item) => item.opId === ref.operationId &&
            item.canonicalEnvelopeSha256 === ref.envelopeSha256));
        event.durableOutboxMatchedAtHeldPush = matchingPending;
        if (matchingPending) nativeDurableOutboxMatchedAtHeldPush = true;
        nativeHeldPushCount += 1;
        nativeHeldOperationIds.push(...event.refs.map((ref) => ref.operationId).filter(Boolean));
        event.status = 503;
        event.responseSummary = 'acceptance_outbox_hold';
        NATIVE_HELD_PUSHES.push(event);
        response.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        response.end('{"error":{"code":"ACCEPTANCE_OUTBOX_HOLD"}}');
        return;
      }
    }
    forward(body);
  });
}

function makeNativeProxy() {
  const server = http.createServer((request, response) => {
    routeApiRequest(request, response, upstreamA, 'A', true);
  });
  server.on('upgrade', (request, client, head) => proxyUpgrade(request, client, head, upstreamA));
  return server;
}

function proxyUpgrade(request, client, head, target) {
  const headers = { ...request.headers, host: `${target.hostname}:${target.port}` };
  delete headers['proxy-connection'];
  const upstream = http.request({
    hostname: target.hostname, port: target.port, method: 'GET',
    path: request.url || '/', headers,
  });
  upstream.on('upgrade', (upstreamResponse, socket, upstreamHead) => {
    let header = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
    for (let i = 0; i < upstreamResponse.rawHeaders.length; i += 2) {
      header += `${upstreamResponse.rawHeaders[i]}: ${upstreamResponse.rawHeaders[i + 1]}\r\n`;
    }
    client.write(`${header}\r\n`);
    if (head?.length) socket.write(head);
    if (upstreamHead?.length) client.write(upstreamHead);
    PROXY_SOCKETS.add(client); PROXY_SOCKETS.add(socket);
    client.on('close', () => PROXY_SOCKETS.delete(client));
    socket.on('close', () => PROXY_SOCKETS.delete(socket));
    client.pipe(socket); socket.pipe(client);
  });
  upstream.on('response', (response) => {
    client.write(`HTTP/1.1 ${response.statusCode || 502} ${response.statusMessage || 'Bad Gateway'}\r\n\r\n`);
    response.pipe(client);
  });
  upstream.on('error', () => client.destroy());
  upstream.end();
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon',
  '.ttf': 'font/ttf', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

function makeWebServer() {
  const root = path.resolve(WEB_ROOT);
  const server = http.createServer((request, response) => {
    let url;
    try { url = new URL(request.url || '/', 'http://127.0.0.1'); } catch (_) {
      response.writeHead(400); response.end(); return;
    }
    if (url.pathname.startsWith('/api/v1/')) {
      routeApiRequest(request, response, upstreamB, 'B', false);
      return;
    }
    if (url.pathname === '/favicon.ico') { response.writeHead(204); response.end(); return; }
    let filePath = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    if (!filePath.startsWith(`${root}${path.sep}`) && filePath !== root) {
      response.writeHead(403); response.end(); return;
    }
    try {
      if (url.pathname === '/' || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
        filePath = path.join(root, 'index.html');
      }
      const body = fs.readFileSync(filePath);
      response.writeHead(200, {
        'content-type': MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
        'cache-control': 'no-store', 'content-length': body.length,
      });
      response.end(request.method === 'HEAD' ? undefined : body);
    } catch (_) {
      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('not found');
    }
  });
  server.on('upgrade', (request, client, head) => proxyUpgrade(request, client, head, upstreamB));
  return server;
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve(`http://127.0.0.1:${server.address().port}`);
    });
  });
}

function wait(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function waitFor(predicate, description, timeoutMs = 30000, intervalMs = 150) {
  const deadline = Date.now() + timeoutMs;
  const timeoutResult = Symbol("wait-timeout");
  const controller = new AbortController();
  while (Date.now() < deadline) {
    const remainingMs = Math.max(1, deadline - Date.now());
    let timeoutId;
    let value;
    try {
      value = await Promise.race([
        Promise.resolve().then(() => predicate(controller.signal)),
        new Promise((resolve) => {
          timeoutId = setTimeout(() => resolve(timeoutResult), remainingMs);
        }),
      ]);
    } catch (error) {
      controller.abort();
      throw error;
    } finally {
      clearTimeout(timeoutId);
    }
    if (value === timeoutResult) {
      controller.abort();
      throw new Error(`timed out waiting for ${description}`);
    }
    if (value) return value;
    await wait(Math.min(intervalMs, Math.max(0, deadline - Date.now())));
  }
  controller.abort();
  throw new Error(`timed out waiting for ${description}`);
}

async function visibleText(page, text, timeout = 25000) {
  const locator = page.getByText(text, { exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout });
  return locator;
}

async function waitForSemanticText(page, text, timeoutMs = 20000) {
  await waitFor(() => page.evaluate((expected) => {
    if ((document.body.innerText || '').includes(expected)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`.includes(expected));
  }, text).catch(() => false), `Web semantic text ${text.length} characters`, timeoutMs, 100);
}

async function button(page, name, timeout = 25000) {
  const locator = page.getByRole('button', { name, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout });
  return locator;
}

async function click(page, name, timeout = 25000) {
  await (await button(page, name, timeout)).click();
}

function inputSelector(label) {
  return `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
}

async function field(page, label, timeout = 25000) {
  const locator = page.locator(inputSelector(label)).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout });
  return locator;
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  let retained = false;
  for (let attempt = 0; attempt < 2 && !retained; attempt += 1) {
    try {
      await locator.click();
      await locator.press('Control+A');
      await locator.fill(value);
      await waitFor(async () => (await locator.inputValue().catch(() => null)) === value,
        `Web ${label} input value`, 2500, 100);
      retained = true;
    } catch (_) { /* retry once after Flutter updates the controlled field */ }
  }
  if (!retained) {
    const candidates = await page.locator(inputSelector(label)).evaluateAll((elements, expected) =>
      elements.slice(0, 8).map((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return {
          tag: element.tagName.toLowerCase(),
          type: element.getAttribute('type') || '',
          visible: rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden',
          focused: document.activeElement === element,
          disabled: Boolean(element.disabled),
          readOnly: Boolean(element.readOnly),
          valueLength: String(element.value || '').length,
          exactMatch: element.value === expected,
        };
      }), value).catch(() => []);
    stage(`Web ${label} input safe diagnostic candidates=${JSON.stringify(candidates)}`);
    throw new Error(`timed out waiting for Web ${label} input value`);
  }
  assertThat((await locator.inputValue()) === value, `Web ${label} input did not retain its value`);
  await locator.press('Tab');
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  try {
    await waitFor(async () => (await locator.inputValue().catch(() => '')) === value,
      `Web ${label} clipboard paste`, 2500, 100);
  } catch (_) {
    await locator.fill(value);
    await waitFor(async () => (await locator.inputValue().catch(() => '')) === value,
      `Web ${label} fallback value`, 2500, 100);
  }
  assertThat((await locator.inputValue()) === value, `Web ${label} field did not retain its value`);
  await locator.press('Tab');
}

async function waitWorkspace(page) {
  await button(page, 'Add host', 60000);
}

async function enterWeb() {
  const page = webPage;
  await page.goto(webOrigin, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web sodium crypto module', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Web Flutter semantics tree', 30000);
  const target = page.locator(inputSelector('Server URL')).first();
  await selectServerModeIfChooser(page, target);
  await fill(page, 'Server URL', webOrigin);
  await click(page, 'Connect securely');
}

function browserObservers(page) {
  page.on('pageerror', () => { PAGE_COUNTS.pageErrors += 1; });
  page.on('console', (message) => {
    if (message.type() === 'error') PAGE_COUNTS.consoleErrors += 1;
  });
  page.on('requestfailed', (request) => {
    const failure = request.failure()?.errorText || '';
    if (!/ERR_ABORTED|net::ERR_ABORTED/.test(failure)) PAGE_COUNTS.unexpectedRequestErrors += 1;
  });
}

function nativeExec(args, options = {}) {
  const result = spawnSync('xdotool', args, {
    encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'], ...options,
  });
  assertThat(!result.error && result.status === 0, 'native UI input action failed');
  return (result.stdout || '').trim();
}

function activeWindowId() {
  const result = spawnSync('xdotool', ['getactivewindow'], {
    encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) return null;
  const id = (result.stdout || '').trim();
  return /^\d+$/.test(id) ? id : null;
}

async function selectNativeFilePickerPath(filePath, description) {
  assertThat(typeof filePath === 'string' && path.isAbsolute(filePath),
    `${description} file picker path must be absolute`);
  const applicationWindow = nativeWindow();
  assertThat(applicationWindow, 'native application window was not visible before file selection');
  await waitFor(() => {
    const active = activeWindowId();
    return active && active !== applicationWindow ? active : null;
  }, `native ${description} file picker`, 15000, 100);
  nativeExec(['key', 'ctrl+l']);
  await wait(100);
  try {
    setClipboard(filePath);
    nativeExec(['key', 'ctrl+a']);
    nativeExec(['key', 'ctrl+v']);
    await wait(120);
  } finally {
    setClipboard('');
  }
  nativeExec(['key', 'Return']);
  let pickerClosed = false;
  try {
    await waitFor(() => activeWindowId() === applicationWindow,
      `native ${description} file picker submit`, 7000, 100);
    pickerClosed = true;
  } catch (_) {}
  if (!pickerClosed) {
    // GTK save dialogs can first resolve the absolute location and then need
    // a second Return to activate Save. Keep the retry bounded and content-free.
    nativeExec(['key', 'Return']);
    await waitFor(() => activeWindowId() === applicationWindow,
      `native ${description} file picker completion`, 7000, 100);
  }
  activateNative();
}

function nativeWindow() {
  if (nativeWindowId) {
    const still = spawnSync('xdotool', ['getwindowname', nativeWindowId], { encoding: 'utf8', timeout: 3000 });
    if (!still.error && still.status === 0 && /aterm_client/i.test(still.stdout || '')) return nativeWindowId;
  }
  const result = spawnSync('xdotool', ['search', '--onlyvisible', '--name', 'aterm_client'], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0 || !result.stdout.trim()) return null;
  nativeWindowId = result.stdout.trim().split(/\s+/).at(-1);
  return nativeWindowId;
}

function activateNative() {
  const windowId = nativeWindow();
  assertThat(windowId, 'native application window was not visible');
  spawnSync('xdotool', ['windowraise', windowId], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'ignore', 'ignore'],
  });
  const focus = spawnSync('xdotool', ['windowfocus', '--sync', windowId], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'ignore', 'ignore'],
  });
  assertThat(!focus.error && focus.status === 0, 'native application could not receive focus');
  return windowId;
}

function xwdToBmp(xwd) {
  assertThat(Buffer.isBuffer(xwd) && xwd.length >= 100, 'native screen capture had an invalid XWD header');
  const header = Array.from({ length: 25 }, (_, index) => xwd.readUInt32BE(index * 4));
  const [headerSize, version, format, depth, width, height, , byteOrder, , , , bitsPerPixel,
    bytesPerLine, , redMask, greenMask, blueMask, , , colorCount] = header;
  assertThat(version === 7 && headerSize >= 100 && headerSize <= xwd.length,
    'native screen capture used an unsupported XWD header');
  assertThat(format === 2 && width > 0 && height > 0 && width <= 8192 && height <= 8192,
    'native screen capture used an unsupported XWD image format');
  assertThat([8, 16, 24, 32].includes(bitsPerPixel) && (byteOrder === 0 || byteOrder === 1),
    'native screen capture used an unsupported XWD pixel layout');
  const pixelBytes = bitsPerPixel / 8;
  assertThat(bytesPerLine >= width * pixelBytes && bytesPerLine * height <= 64 * 1024 * 1024,
    'native screen capture had invalid XWD row dimensions');
  const dataOffset = headerSize + colorCount * 12;
  assertThat(Number.isSafeInteger(dataOffset) && dataOffset + bytesPerLine * height <= xwd.length,
    'native screen capture had truncated XWD pixel data');

  const palette = new Map();
  for (let index = 0; index < colorCount; index += 1) {
    const offset = headerSize + index * 12;
    if (offset + 12 > xwd.length) break;
    palette.set(xwd.readUInt32BE(offset), [
      Math.round(xwd.readUInt16BE(offset + 4) / 257),
      Math.round(xwd.readUInt16BE(offset + 6) / 257),
      Math.round(xwd.readUInt16BE(offset + 8) / 257),
    ]);
  }

  function channel(pixel, mask) {
    if (!mask) return 0;
    let normalizedMask = mask >>> 0;
    let shift = 0;
    while (shift < 32 && (normalizedMask & 1) === 0) {
      normalizedMask >>>= 1;
      shift += 1;
    }
    const raw = ((pixel & (mask >>> 0)) >>> shift) >>> 0;
    return Math.round(raw * 255 / normalizedMask);
  }

  const rowBytes = Math.ceil(width * 3 / 4) * 4;
  const imageBytes = rowBytes * height;
  assertThat(imageBytes <= 64 * 1024 * 1024, 'native screen capture exceeded the OCR image size limit');
  const bmp = Buffer.alloc(54 + imageBytes);
  bmp.write('BM', 0, 'ascii');
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(24, 28);
  bmp.writeUInt32LE(imageBytes, 34);
  bmp.writeInt32LE(2835, 38);
  bmp.writeInt32LE(2835, 42);

  for (let y = 0; y < height; y += 1) {
    const sourceRow = dataOffset + y * bytesPerLine;
    const targetRow = 54 + (height - 1 - y) * rowBytes;
    for (let x = 0; x < width; x += 1) {
      const source = sourceRow + x * pixelBytes;
      const pixel = pixelBytes === 1 ? xwd[source]
        : byteOrder === 0 ? xwd.readUIntLE(source, pixelBytes) : xwd.readUIntBE(source, pixelBytes);
      const rgb = redMask && greenMask && blueMask
        ? [channel(pixel, redMask), channel(pixel, greenMask), channel(pixel, blueMask)]
        : palette.get(pixel);
      assertThat(rgb, 'native screen capture used an unsupported XWD color map');
      const target = targetRow + x * 3;
      bmp[target] = rgb[2];
      bmp[target + 1] = rgb[1];
      bmp[target + 2] = rgb[0];
    }
  }
  return bmp;
}

function nativeWindowGeometry(windowId = nativeWindow()) {
  assertThat(windowId && /^\d+$/.test(windowId), 'native window geometry is unavailable');
  const result = spawnSync('xdotool', ['getwindowgeometry', '--shell', windowId], {
    encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'native window geometry could not be read');
  const values = {};
  for (const key of ['X', 'Y', 'WIDTH', 'HEIGHT']) {
    const line = String(result.stdout || '').split(/\r?\n/)
      .find((candidate) => candidate.startsWith(`${key}=`));
    const raw = line?.slice(key.length + 1);
    if (raw && /^-?\d+$/.test(raw)) values[key.toLowerCase()] = Number(raw);
  }
  assertThat(Number.isSafeInteger(values.x) && Number.isSafeInteger(values.y) &&
    Number.isSafeInteger(values.width) && Number.isSafeInteger(values.height) &&
    values.width > 0 && values.height > 0,
  'native window geometry had invalid dimensions');
  return values;
}

function cropBmpToWindow(bmp, rect) {
  assertThat(Buffer.isBuffer(bmp) && bmp.length >= 54 && bmp.toString('ascii', 0, 2) === 'BM',
    'native screen capture had an invalid BMP header');
  const pixelOffset = bmp.readUInt32LE(10);
  const dibSize = bmp.readUInt32LE(14);
  const width = bmp.readInt32LE(18);
  const height = bmp.readInt32LE(22);
  assertThat(dibSize >= 40 && pixelOffset >= 54 && pixelOffset <= bmp.length &&
    bmp.readUInt16LE(26) === 1 && bmp.readUInt16LE(28) === 24 && bmp.readUInt32LE(30) === 0 &&
    width > 0 && height > 0,
  'native screen capture BMP must be uncompressed 24-bit bottom-up RGB');
  const sourceStride = Math.ceil(width * 3 / 4) * 4;
  assertThat(sourceStride * height <= bmp.length - pixelOffset,
    'native screen capture BMP pixel data was truncated');
  assertThat(Number.isSafeInteger(rect.x) && Number.isSafeInteger(rect.y) &&
    Number.isSafeInteger(rect.width) && Number.isSafeInteger(rect.height) &&
    rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
    rect.x + rect.width <= width && rect.y + rect.height <= height,
  'native window crop falls outside the captured desktop');

  const targetStride = Math.ceil(rect.width * 3 / 4) * 4;
  const imageBytes = targetStride * rect.height;
  assertThat(imageBytes <= 64 * 1024 * 1024, 'native window crop exceeded the OCR image size limit');
  const cropped = Buffer.alloc(54 + imageBytes);
  cropped.write('BM', 0, 'ascii');
  cropped.writeUInt32LE(cropped.length, 2);
  cropped.writeUInt32LE(54, 10);
  cropped.writeUInt32LE(40, 14);
  cropped.writeInt32LE(rect.width, 18);
  cropped.writeInt32LE(rect.height, 22);
  cropped.writeUInt16LE(1, 26);
  cropped.writeUInt16LE(24, 28);
  cropped.writeUInt32LE(imageBytes, 34);
  cropped.writeInt32LE(bmp.readInt32LE(38), 38);
  cropped.writeInt32LE(bmp.readInt32LE(42), 42);

  for (let y = 0; y < rect.height; y += 1) {
    const sourceTopY = rect.y + y;
    const sourceRow = pixelOffset + (height - 1 - sourceTopY) * sourceStride + rect.x * 3;
    const targetRow = 54 + (rect.height - 1 - y) * targetStride;
    bmp.copy(cropped, targetRow, sourceRow, sourceRow + rect.width * 3);
  }
  return cropped;
}

function captureNativeWindowBmp() {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  const image = spawnSync('xwd', ['-silent', '-root'], {
    encoding: null, timeout: 10000, maxBuffer: 32 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!image.error && image.status === 0 && image.stdout?.length > 1000,
    'native screen capture failed');
  return { bmp: cropBmpToWindow(xwdToBmp(image.stdout), geometry), geometry };
}

function nativeHostKeyAccessibility(expectedFingerprint, activateTrust = false) {
  const script = String.raw`import json, sys
result = {
  'available': False,
  'verify_dialog': False,
  'fingerprint_node': False,
  'fingerprint_matches': False,
  'trust_action': False,
  'trust_clicked': False,
}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected = payload['expected_fingerprint']
  expected_pid = int(payload['native_pid'])
  activate_trust = payload.get('activate_trust') is True
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  prefix = 'SSH host key fingerprint: '
  def inspect_application(application):
    try:
      if application.get_process_id() != expected_pid:
        return
    except Exception:
      return
    titles = []
    fingerprints = []
    trust_nodes = []
    def is_showing(node):
      try:
        states = node.getState()
        return states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
      except Exception:
        return False
    def descendants(node, depth=0):
      global visited
      if depth > 40 or visited >= 12000:
        return
      visited += 1
      try:
        name = node.name or ''
      except Exception:
        name = ''
      if name == 'Verify SSH host key':
        titles.append(is_showing(node))
      elif name.startswith(prefix):
        fingerprints.append((name[len(prefix):], is_showing(node)))
      elif name == 'Trust after verification':
        try:
          role_is_button = node.getRole() == pyatspi.ROLE_PUSH_BUTTON
          states = node.getState()
          enabled = states.contains(pyatspi.STATE_ENABLED) and states.contains(pyatspi.STATE_SENSITIVE)
        except Exception:
          role_is_button = False
          enabled = False
        if role_is_button and enabled and is_showing(node):
          trust_nodes.append(node)
      try:
        count = node.childCount
      except Exception:
        count = 0
      for index in range(min(count, 500)):
        try:
          descendants(node.getChildAtIndex(index), depth + 1)
        except Exception:
          continue
    descendants(application)
    state = {
      'verify_dialog': len(titles) == 1 and titles[0],
      'fingerprint_node': len(fingerprints) == 1 and fingerprints[0][1],
      'fingerprint_matches': len(fingerprints) == 1 and fingerprints[0][1] and
          fingerprints[0][0] == expected,
      'trust_action': len(trust_nodes) == 1,
    }
    for key in ('verify_dialog', 'fingerprint_node', 'trust_action'):
      result[key] = result[key] or state[key]
    authorized = all(state[key] for key in (
      'verify_dialog', 'fingerprint_node', 'fingerprint_matches', 'trust_action'))
    result['fingerprint_matches'] = result['fingerprint_matches'] or authorized
    if activate_trust and authorized:
      try:
        result['trust_clicked'] = bool(trust_nodes[0].queryAction().doAction(0))
      except Exception:
        result['trust_clicked'] = False
  try:
    app_count = desktop.childCount
  except Exception:
    app_count = 0
  for index in range(min(app_count, 500)):
    try:
      inspect_application(desktop.getChildAtIndex(index))
    except Exception:
      continue
except Exception:
  result = {
    'available': False,
    'verify_dialog': False,
    'fingerprint_node': False,
    'fingerprint_matches': False,
    'trust_action': False,
    'trust_clicked': False,
  }
print(json.dumps(result, separators=(',', ':')))
`;
  const result = spawnSync('/usr/bin/python3', ['-c', script], {
    input: JSON.stringify({
      expected_fingerprint: expectedFingerprint,
      native_pid: nativeProcess?.pid,
      activate_trust: activateTrust,
    }),
    encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'native Linux accessibility query failed while checking the SSH host key');
  let state;
  const outputLines = String(result.stdout || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  try { state = JSON.parse(outputLines.at(-1) || ''); }
  catch (_) { throw new Error('native Linux accessibility query returned invalid status'); }
  assertThat(state && typeof state === 'object' &&
    ['available', 'verify_dialog', 'fingerprint_node', 'fingerprint_matches', 'trust_action', 'trust_clicked']
      .every((key) => typeof state[key] === 'boolean'),
  'native Linux accessibility query returned incomplete status');
  assertThat(state.available,
    'native Linux accessibility support requires system Python pyatspi');
  return state;
}

function nativeTerminalInputAccessibility() {
  const script = String.raw`import json, sys
result = {
  'available': False,
  'input_visible': False,
  'input_focused': False,
}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected_pid = int(payload['native_pid'])
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  matching = []
  def descendants(node, depth=0):
    global visited
    if depth > 40 or visited >= 12000:
      return
    visited += 1
    try:
      name = node.name or ''
    except Exception:
      name = ''
    if name == 'SSH terminal input':
      try:
        states = node.getState()
        matching.append((
          states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING),
          states.contains(pyatspi.STATE_FOCUSED),
          states.contains(pyatspi.STATE_FOCUSABLE),
        ))
      except Exception:
        matching.append((False, False, False))
    try:
      count = node.childCount
    except Exception:
      count = 0
    for index in range(min(count, 500)):
      try:
        descendants(node.getChildAtIndex(index), depth + 1)
      except Exception:
        continue
  try:
    app_count = desktop.childCount
  except Exception:
    app_count = 0
  for index in range(min(app_count, 500)):
    try:
      application = desktop.getChildAtIndex(index)
      if application.get_process_id() == expected_pid:
        descendants(application)
    except Exception:
      continue
  visible = [node for node in matching if node[0]]
  result['input_visible'] = len(visible) == 1 and visible[0][2]
  result['input_focused'] = len(visible) == 1 and visible[0][1] and visible[0][2]
except Exception:
  result = {
    'available': False,
    'input_visible': False,
    'input_focused': False,
  }
print(json.dumps(result, separators=(',', ':')))
`;
  const result = spawnSync('/usr/bin/python3', ['-c', script], {
    input: JSON.stringify({ native_pid: nativeProcess?.pid }),
    encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'native Linux accessibility query failed while checking terminal input focus');
  let state;
  const outputLines = String(result.stdout || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  try { state = JSON.parse(outputLines.at(-1) || ''); }
  catch (_) { throw new Error('native Linux terminal focus query returned invalid status'); }
  assertThat(state && typeof state === 'object' &&
    ['available', 'input_visible', 'input_focused'].every((key) => typeof state[key] === 'boolean'),
  'native Linux terminal focus query returned incomplete status');
  assertThat(state.available,
    'native Linux accessibility support requires system Python pyatspi');
  return state;
}

function nativeNamedButtonAccessibility(label, activate = false, signal = null, exactMatch = false) {
  const script = String.raw`import json, sys
result = {
  'available': False,
  'button_named': False,
  'button_role': False,
  'button_visible': False,
  'button_enabled': False,
  'button_activated': False,
}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected_pid = int(payload['native_pid'])
  expected_name = payload['expected_name']
  exact_match = payload.get('exact_match') is True
  activate = payload.get('activate') is True
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  matching = []
  def descendants(node, depth=0):
    global visited
    if depth > 40 or visited >= 12000:
      return
    visited += 1
    try:
      name = node.name or ''
    except Exception:
      name = ''
    if ((expected_name.lower() == name.lower()) if exact_match else
        (expected_name.lower() in name.lower())):
      try:
        is_button = node.getRole() == pyatspi.ROLE_PUSH_BUTTON
        states = node.getState()
        visible = states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
        enabled = states.contains(pyatspi.STATE_ENABLED) and states.contains(pyatspi.STATE_SENSITIVE)
        matching.append((node, is_button, visible, enabled))
      except Exception:
        matching.append((node, False, False, False))
    try:
      count = node.childCount
    except Exception:
      count = 0
    for index in range(min(count, 500)):
      try:
        descendants(node.getChildAtIndex(index), depth + 1)
      except Exception:
        continue
  try:
    app_count = desktop.childCount
  except Exception:
    app_count = 0
  for index in range(min(app_count, 500)):
    try:
      application = desktop.getChildAtIndex(index)
      if application.get_process_id() == expected_pid:
        descendants(application)
    except Exception:
      continue
  buttons = [item for item in matching if item[1] and item[2] and item[3]]
  result['button_named'] = bool(matching)
  result['button_role'] = any(item[1] for item in matching)
  result['button_visible'] = len(buttons) == 1
  result['button_enabled'] = len(buttons) == 1 and buttons[0][3]
  if activate and len(buttons) == 1:
    try:
      result['button_activated'] = bool(buttons[0][0].queryAction().doAction(0))
    except Exception:
      result['button_activated'] = False
except Exception:
  result = {
    'available': False,
    'button_named': False,
    'button_role': False,
    'button_visible': False,
    'button_enabled': False,
    'button_activated': False,
  }
print(json.dumps(result, separators=(',', ':')))
`;
  return new Promise((resolve, reject) => {
    const probe = spawn('/usr/bin/python3', ['-c', script], {
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    CHILDREN.add(probe);
    const chunks = [];
    let outputLength = 0;
    let settled = false;
    let timeoutId;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      signal?.removeEventListener('abort', abortProbe);
      if (error) reject(error);
      else resolve(value);
    };
    const stopWithError = (error) => {
      if (settled) return;
      finish(error);
      try { probe.kill('SIGKILL'); } catch (_) {}
    };
    const abortProbe = () => stopWithError(new Error('native Linux accessibility probe was aborted'));

    probe.stdout.on('data', (chunk) => {
      outputLength += chunk.length;
      if (outputLength > 1024 * 1024) {
        stopWithError(new Error('native Linux accessibility probe output exceeded its limit'));
        return;
      }
      chunks.push(chunk);
    });
    probe.once('error', () => stopWithError(new Error('native Linux accessibility probe could not start')));
    probe.once('close', (status) => {
      CHILDREN.delete(probe);
      if (settled) return;
      if (status !== 0) {
        finish(new Error('native Linux accessibility query failed while checking an accessible button'));
        return;
      }
      try {
        const outputLines = Buffer.concat(chunks).toString('utf8')
          .split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
        const state = JSON.parse(outputLines.at(-1) || '');
        assertThat(state && typeof state === 'object' &&
          ['available', 'button_named', 'button_role', 'button_visible', 'button_enabled', 'button_activated']
            .every((key) => typeof state[key] === 'boolean'),
        'native Linux button query returned incomplete status');
        assertThat(state.available,
          'native Linux accessibility support requires system Python pyatspi');
        finish(null, state);
      } catch (error) {
        finish(error);
      }
    });
    probe.stdin.once('error', () => stopWithError(new Error('native Linux accessibility probe input failed')));
    signal?.addEventListener('abort', abortProbe, { once: true });
    if (signal?.aborted) {
      abortProbe();
      return;
    }
    timeoutId = setTimeout(() => stopWithError(new Error('native Linux accessibility probe timed out')), 1500);
    try {
      probe.stdin.end(JSON.stringify({ native_pid: nativeProcess?.pid, expected_name: label, activate, exact_match: exactMatch }));
    } catch (_) {
      stopWithError(new Error('native Linux accessibility probe input failed'));
    }
  });
}

function nativeVisibleTextContains(expectedText) {
  const script = String.raw`import json, sys
result = {'available': False, 'visible_text_found': False}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected = payload['expected_text']
  expected_pid = int(payload['native_pid'])
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  def descendants(node, depth=0):
    global visited
    if depth > 40 or visited >= 12000 or result['visible_text_found']:
      return
    visited += 1
    try:
      states = node.getState()
      visible = states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
    except Exception:
      visible = False
    if visible:
      values = []
      try:
        values.append(node.name or '')
      except Exception:
        pass
      for interface_name in ('queryText', 'queryEditableText'):
        try:
          value = getattr(node, interface_name)().getText(0, -1)
          if isinstance(value, str): values.append(value)
        except Exception:
          pass
      result['visible_text_found'] = any(expected in value for value in values)
    try:
      count = node.childCount
    except Exception:
      count = 0
    for index in range(min(count, 500)):
      try:
        descendants(node.getChildAtIndex(index), depth + 1)
      except Exception:
        continue
  for index in range(min(desktop.childCount, 500)):
    try:
      application = desktop.getChildAtIndex(index)
      if application.get_process_id() == expected_pid:
        descendants(application)
    except Exception:
      continue
except Exception:
  result = {'available': False, 'visible_text_found': False}
print(json.dumps(result, separators=(',', ':')))
`;
  const result = spawnSync('/usr/bin/python3', ['-c', script], {
    input: JSON.stringify({ native_pid: nativeProcess?.pid, expected_text: expectedText }),
    encoding: 'utf8', timeout: 2500, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'native Linux accessibility text query failed');
  let state;
  try { state = JSON.parse(String(result.stdout || '').trim().split(/\r?\n/).at(-1)); }
  catch (_) { throw new Error('native Linux accessibility text query returned invalid status'); }
  assertThat(state?.available === true && typeof state.visible_text_found === 'boolean',
    'native Linux accessibility text query returned incomplete status');
  return state.visible_text_found;
}

function nativeTextFieldAccessibility(label, expectedValue) {
  const script = String.raw`import json, sys
result = {'available': False, 'field_visible': False, 'value_matches': False}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected_pid = int(payload['native_pid'])
  expected_label = payload['expected_label']
  expected_value = payload['expected_value']
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  fields = []
  def descendants(node, depth=0):
    global visited
    if depth > 40 or visited >= 12000:
      return
    visited += 1
    try:
      name = node.name or ''
    except Exception:
      name = ''
    try:
      role = node.getRole()
      states = node.getState()
      visible = states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
    except Exception:
      role = None
      visible = False
    text_roles = {
      getattr(pyatspi, 'ROLE_TEXT', None),
      getattr(pyatspi, 'ROLE_ENTRY', None),
    }
    if expected_label in name and role in text_roles and visible:
      values = []
      for interface_name in ('queryEditableText', 'queryText'):
        try:
          interface = getattr(node, interface_name)()
          value = interface.getText(0, -1)
          if isinstance(value, str):
            values.append(value)
        except Exception:
          pass
      fields.append(values[-1] if values else None)
    try:
      count = node.childCount
    except Exception:
      count = 0
    for index in range(min(count, 500)):
      try:
        descendants(node.getChildAtIndex(index), depth + 1)
      except Exception:
        continue
  try:
    app_count = desktop.childCount
  except Exception:
    app_count = 0
  for index in range(min(app_count, 500)):
    try:
      application = desktop.getChildAtIndex(index)
      if application.get_process_id() == expected_pid:
        descendants(application)
    except Exception:
      continue
  result['field_visible'] = len(fields) == 1
  result['value_matches'] = len(fields) == 1 and fields[0] == expected_value
except Exception:
  result = {'available': False, 'field_visible': False, 'value_matches': False}
print(json.dumps(result, separators=(',', ':')))
`;
  const result = spawnSync('/usr/bin/python3', ['-c', script], {
    input: JSON.stringify({
      native_pid: nativeProcess?.pid,
      expected_label: label,
      expected_value: expectedValue,
    }),
    encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'native Linux accessibility query failed while checking an encrypted Snippet field');
  let state;
  const outputLines = String(result.stdout || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  try { state = JSON.parse(outputLines.at(-1) || ''); }
  catch (_) { throw new Error('native Linux Snippet field query returned invalid status'); }
  assertThat(state && typeof state === 'object' &&
    ['available', 'field_visible', 'value_matches'].every((key) => typeof state[key] === 'boolean'),
  'native Linux Snippet field query returned incomplete status');
  assertThat(state.available,
    'native Linux accessibility support requires system Python pyatspi');
  return state;
}

function nativeSnippetEditAccessibility(snippetTitle, activate = false) {
  const script = String.raw`import json, sys
result = {
  'available': False,
  'snippet_card_visible': False,
  'edit_button_visible': False,
  'edit_button_activated': False,
  'card_action_count': 0,
}
try:
  import pyatspi
  payload = json.load(sys.stdin)
  expected_pid = int(payload['native_pid'])
  expected_name = payload['expected_name']
  activate = payload.get('activate') is True
  desktop = pyatspi.Registry.getDesktop(0)
  result['available'] = True
  visited = 0
  cards = []
  def descendants(node, depth=0, root=False):
    global visited
    if depth > 40 or visited >= 12000:
      return
    visited += 1
    try:
      name = node.name or ''
    except Exception:
      name = ''
    if not root and name == expected_name:
      try:
        states = node.getState()
        visible = states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
        if visible:
          cards.append(node)
      except Exception:
        pass
    try:
      count = node.childCount
    except Exception:
      count = 0
    for index in range(min(count, 500)):
      try:
        descendants(node.getChildAtIndex(index), depth + 1)
      except Exception:
        continue
  try:
    app_count = desktop.childCount
  except Exception:
    app_count = 0
  for index in range(min(app_count, 500)):
    try:
      application = desktop.getChildAtIndex(index)
      if application.get_process_id() == expected_pid:
        descendants(application, root=True)
    except Exception:
      continue
  result['snippet_card_visible'] = len(cards) == 1
  buttons = []
  if len(cards) == 1:
    def card_buttons(node, depth=0):
      if depth > 40:
        return
      try:
        if node.getRole() == pyatspi.ROLE_PUSH_BUTTON:
          states = node.getState()
          visible = states.contains(pyatspi.STATE_VISIBLE) and states.contains(pyatspi.STATE_SHOWING)
          enabled = states.contains(pyatspi.STATE_ENABLED) and states.contains(pyatspi.STATE_SENSITIVE)
          if visible and enabled:
            buttons.append(node)
      except Exception:
        pass
      try:
        count = node.childCount
      except Exception:
        count = 0
      for index in range(min(count, 500)):
        try:
          card_buttons(node.getChildAtIndex(index), depth + 1)
        except Exception:
          continue
    card_buttons(cards[0])
  result['card_action_count'] = len(buttons)
  result['edit_button_visible'] = len(buttons) >= 2
  if activate and len(buttons) >= 2:
    try:
      result['edit_button_activated'] = bool(buttons[0].queryAction().doAction(0))
    except Exception:
      result['edit_button_activated'] = False
except Exception:
  result = {
    'available': False,
    'snippet_card_visible': False,
    'edit_button_visible': False,
    'edit_button_activated': False,
    'card_action_count': 0,
  }
print(json.dumps(result, separators=(',', ':')))
`;
  const result = spawnSync('/usr/bin/python3', ['-c', script], {
    input: JSON.stringify({
      native_pid: nativeProcess?.pid,
      expected_name: `Snippet: ${snippetTitle}`,
      activate,
    }),
    encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'native Linux accessibility query failed while checking the received Snippet card');
  let state;
  const outputLines = String(result.stdout || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  try { state = JSON.parse(outputLines.at(-1) || ''); }
  catch (_) { throw new Error('native Linux Snippet card query returned invalid status'); }
  assertThat(state && typeof state === 'object' &&
    ['available', 'snippet_card_visible', 'edit_button_visible', 'edit_button_activated', 'card_action_count']
      .every((key) => typeof state[key] === (key === 'card_action_count' ? 'number' : 'boolean')),
  'native Linux Snippet card query returned incomplete status');
  assertThat(state.available,
    'native Linux accessibility support requires system Python pyatspi');
  return state;
}

function safeToolStderr(stderr) {
  let value = String(stderr || '').replace(/[\r\n\t\x00-\x1f]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
  for (const marker of [...MARKERS].sort((a, b) => b.length - a.length)) {
    if (marker) value = value.split(marker).join('[redacted]');
  }
  for (const root of privateNativeRoots().sort((a, b) => b.length - a.length)) {
    if (root) value = value.split(root).join('[private-path]');
  }
  value = value.replace(/https?:\/\/[^\s]+/g, '[url]');
  return value.slice(0, 240) || '[empty]';
}

function captureNativeOcr() {
  const { bmp, geometry } = captureNativeWindowBmp();
  const lines = new Map();
  for (const psm of ['11', '6']) {
    const ocr = spawnSync('tesseract', ['stdin', 'stdout', '--psm', psm, 'tsv'], {
      input: bmp, encoding: 'utf8', timeout: 15000, maxBuffer: 8 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const ocrFailure = `psm=${psm} spawn_code=${ocr.error?.code || 'none'} status=${ocr.status ?? 'null'} stderr=${safeToolStderr(ocr.stderr)}`;
    assertThat(!ocr.error && ocr.status === 0, `native OCR could not inspect the current screen (${ocrFailure})`);
    for (const row of (ocr.stdout || '').split(/\r?\n/).slice(1)) {
      const parts = row.split('\t');
      if (parts.length < 12 || !parts[11]) continue;
      const key = `${psm}:${parts.slice(1, 5).join(':')}`;
      const word = parts[11].trim();
      if (!word) continue;
      const left = Number(parts[6]) + geometry.x;
      const top = Number(parts[7]) + geometry.y;
      const right = left + Number(parts[8]);
      const bottom = top + Number(parts[9]);
      const line = lines.get(key) || { words: [], tokens: [], left, top, right, bottom };
      line.words.push(word);
      line.tokens.push({ text: word, left, top, right, bottom });
      line.left = Math.min(line.left, left);
      line.top = Math.min(line.top, top);
      line.right = Math.max(line.right, right);
      line.bottom = Math.max(line.bottom, bottom);
      lines.set(key, line);
    }
  }
  return [...lines.values()].map((line) => ({ ...line, text: line.words.join(' ') }));
}

function saveNativeWindowDiagnosticBmp(label) {
  assertThat(/^[a-z-]+$/.test(label), 'native diagnostic image label is invalid');
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  const image = spawnSync('xwd', ['-silent', '-root'], {
    encoding: null, timeout: 10000, maxBuffer: 32 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!image.error && image.status === 0 && image.stdout?.length > 1000,
    'native diagnostic screen capture failed');
  const bmp = cropBmpToWindow(xwdToBmp(image.stdout), geometry);
  const filename = path.join('/tmp', `atermius-native-${label}-${process.pid}.bmp`);
  const descriptor = fs.openSync(filename, 'wx', 0o600);
  try { fs.writeFileSync(descriptor, bmp); fs.fchmodSync(descriptor, 0o600); }
  finally { fs.closeSync(descriptor); }
  return filename;
}

function saveInitialChooserDiagnosticBmp() {
  return saveNativeWindowDiagnosticBmp('initial-chooser');
}

function normalizeOcr(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function findOcrAnchor(lines, anchor) {
  const wanted = normalizeOcr(anchor);
  if (!wanted) return null;
  const wantedWords = wanted.split(/\s+/);
  for (const line of lines) {
    if (!normalizeOcr(line.text).includes(wanted)) continue;
    const tokens = (line.tokens || []).flatMap((token) =>
      normalizeOcr(token.text).split(/\s+/).filter(Boolean).map((text) => ({ ...token, normalized: text })));
    for (let start = 0; start <= tokens.length - wantedWords.length; start += 1) {
      if (!wantedWords.every((word, offset) => tokens[start + offset].normalized === word)) continue;
      const matched = tokens.slice(start, start + wantedWords.length);
      return { ...line, matchBounds: {
        left: Math.min(...matched.map((token) => token.left)),
        top: Math.min(...matched.map((token) => token.top)),
        right: Math.max(...matched.map((token) => token.right)),
        bottom: Math.max(...matched.map((token) => token.bottom)),
      } };
    }
  }
  return null;
}

async function waitNativeText(anchor, description = anchor, timeoutMs = 30000) {
  await waitFor(() => findOcrAnchor(captureNativeOcr(), anchor) !== null,
    `native ${description}`, timeoutMs, 300);
}

async function ensureNativeEnrollmentDialogClosed() {
  const enrollmentDialogOpen = () =>
    findOcrAnchor(captureNativeOcr(), 'Request this device') !== null;
  try {
    await waitFor(() => !enrollmentDialogOpen(), 'native enrollment dialog to close', 5000, 250);
  } catch (_) {
    stage('native enrollment: send Escape to dismiss the remaining dialog');
    nativeExec(['key', 'Escape']);
    await waitFor(() => !enrollmentDialogOpen(), 'native enrollment dialog dismissal', 5000, 250);
  }
}

async function nativeTryClick(anchor, timeoutMs = 3000, offsetY = 0) {
  const deadline = Date.now() + timeoutMs;
  let line = null;
  while (Date.now() < deadline && !line) {
    line = findOcrAnchor(captureNativeOcr(), anchor);
    if (!line) await wait(300);
  }
  if (!line) return false;
  await nativeClickObservedLine(line, anchor, offsetY);
  return true;
}

async function nativeClickObservedLine(line, description, offsetY = 0) {
  const bounds = line?.matchBounds || line;
  assertThat(bounds && [bounds.left, bounds.top, bounds.right, bounds.bottom]
    .every(Number.isFinite) && bounds.right > bounds.left && bounds.bottom > bounds.top,
  `native ${description} OCR bounds were invalid`);
  activateNative();
  const x = Math.round((bounds.left + bounds.right) / 2);
  const y = Math.round((bounds.top + bounds.bottom) / 2 + offsetY);
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  await wait(350);
}

async function nativeClick(anchor, description = anchor, timeoutMs = 30000, offsetY = 0) {
  const clicked = await nativeTryClick(anchor, timeoutMs, offsetY);
  assertThat(clicked, `native ${description} control was not visible`);
}

function setClipboard(text) {
  const result = spawnSync('xclip', ['-selection', 'clipboard', '-in'], {
    input: Buffer.from(String(text), 'utf8'), encoding: null, timeout: 5000,
    stdio: ['pipe', 'ignore', 'ignore'],
  });
  assertThat(!result.error && (result.status === 0 || result.status === null),
    'system clipboard write failed');
}

function readClipboard() {
  const result = spawnSync('xclip', ['-selection', 'clipboard', '-out'], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'system clipboard read failed');
  return result.stdout;
}

async function nativeFill(label, value) {
  await nativeClick(label, `${label} field`, 30000, 14);
  nativeExec(['key', 'ctrl+a']);
  setClipboard(value);
  nativeExec(['key', 'ctrl+v']);
  await wait(100);
  setClipboard('');
  nativeExec(['key', 'Tab']);
  await wait(180);
}

async function nativeFillFocused(value) {
  nativeExec(['key', 'ctrl+a']);
  setClipboard(value);
  nativeExec(['key', 'ctrl+v']);
  await wait(100);
  setClipboard('');
  nativeExec(['key', 'Tab']);
  await wait(180);
}

async function nativePaste(label, value) {
  await nativeClick(label, `${label} field`, 30000, 20);
  nativeExec(['key', 'ctrl+a']);
  setClipboard(value);
  nativeExec(['key', 'ctrl+v']);
  nativeExec(['key', 'Tab']);
  await wait(250);
}

async function nativePasteDialogFieldCentered(value) {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width >= 1000 && geometry.height >= 650,
    'native approval dialog viewport is smaller than the tested layout');
  const x = geometry.x + Math.floor(geometry.width / 2);
  const y = geometry.y + Math.floor(geometry.height / 2);
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  nativeExec(['key', 'ctrl+a']);
  setClipboard(value);
  nativeExec(['key', 'ctrl+v']);
  setClipboard('');
  nativeExec(['key', 'Tab']);
  await wait(250);
}

async function nativeClickSignInButton() {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width >= 1000 && geometry.height >= 650,
    'native sign-in viewport is smaller than the tested layout');
  // Linux acceptance pins this app window at 1280x720. This point is inside
  // the green submit button and stays clear of the password visibility toggle.
  const x = geometry.x + Math.round(geometry.width * 0.743);
  const y = geometry.y + Math.round(geometry.height * 0.425);
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  await wait(350);
}

async function nativeClickHostCreateButton() {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width === 1280 && geometry.height === 720,
    'native Hosts acceptance requires its pinned 1280x720 window');
  // At the pinned viewport the toolbar Add host control is centered here.
  const x = geometry.x + Math.round(geometry.width * 0.937);
  const y = geometry.y + Math.round(geometry.height * 0.256);
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  await wait(350);
}

async function nativeOpenHostsPage(description) {
  let state = await nativeScreenState();
  if (state.hostPage) return state;
  try {
    await nativeClick('Hosts', `${description} Hosts navigation`, 10000);
    state = await waitFor(async () => {
      const observed = await nativeScreenState();
      return observed.hostPage ? observed : null;
    }, `${description} Hosts page`, 5000, 250);
    return state;
  } catch (_) {}

  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width === 1280 && geometry.height === 720,
    'native Hosts navigation requires its pinned 1280x720 window');
  // The wide-layout Hosts navigation item is the first row below the
  // workspace header in the fixed Linux acceptance viewport.
  const x = geometry.x + 105;
  const y = geometry.y + 125;
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  return waitFor(async () => {
    const observed = await nativeScreenState();
    return observed.hostPage ? observed : null;
  }, `${description} Hosts page after pinned navigation`, 10000, 250);
}

async function nativeScrollHostsIntoView() {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width === 1280 && geometry.height === 720,
    'native Host list scrolling requires its pinned 1280x720 window');
  const x = geometry.x + Math.round(geometry.width * 0.78);
  const y = geometry.y + Math.round(geometry.height * 0.78);
  nativeExec(['mousemove', String(x), String(y), 'click', '--repeat', '5', '--delay', '35', '5']);
  await wait(350);
}

async function nativeOpenCredentialsPage() {
  const windowId = activateNative();
  const geometry = nativeWindowGeometry(windowId);
  assertThat(geometry.width === 1280 && geometry.height === 720,
    'native Credentials navigation requires its pinned 1280x720 window');
  // The fixed workspace sidebar keeps Credentials at this position even when
  // the Hosts page itself has scrolled its main content.
  const x = geometry.x + 100;
  const y = geometry.y + 220;
  nativeExec(['mousemove', String(x), String(y), 'click', '1']);
  await waitNativeText('SSH credentials', 'native SSH Credentials page', 12000);
}

async function nativeOpenSnippetsPage() {
  const clicked = await nativeTryClick('Snippets', 12000);
  if (!clicked) {
    const windowId = activateNative();
    const geometry = nativeWindowGeometry(windowId);
    assertThat(geometry.width === 1280 && geometry.height === 720,
      'native Snippets navigation requires its pinned 1280x720 window');
    // In the fixed Linux workspace sidebar, Snippets is the third record view.
    nativeExec(['mousemove', String(geometry.x + 100), String(geometry.y + 270), 'click', '1']);
  }
  await waitNativeText('Command snippets', 'native Command snippets page', 12000);
}

function sha256Hex(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function readRegularFileBytes(filePath, description) {
  const stat = fs.lstatSync(filePath);
  assertThat(stat.isFile() && !stat.isSymbolicLink(),
    `${description} was not a regular file`);
  return fs.readFileSync(filePath);
}

async function nativeSftpEntryActions(name) {
  const action = await nativeNamedButtonAccessibility(`Actions for ${name}`, true);
  assertThat(action.button_visible && action.button_activated,
    'native SFTP entry actions were not available');
  await wait(200);
}

async function confirmNativeSftpDelete(name) {
  await nativeSftpEntryActions(name);
  await nativeClick('Delete', 'native SFTP entry Delete action', 8000);
  await waitNativeText('Delete this item?', 'native SFTP delete confirmation', 8000);
  assertThat(nativeVisibleTextContains(`${name} will be removed from the remote host.`),
    'SFTP delete confirmation described a local Vault tombstone instead of remote deletion');
  await nativeClick('Delete', 'native SFTP remote delete confirmation', 8000);
  await waitNativeText('SFTP file browser', 'native SFTP page after deletion', 10000);
}

async function runNativeSftpAcceptance(vaultId) {
  const requiredInputs = [SFTP_BINARY_UPLOAD_PATH, SFTP_BINARY_COLLISION_PATH,
    SFTP_TEXT_UPLOAD_PATH, SFTP_BINARY_DOWNLOAD_PATH, SFTP_TEXT_DOWNLOAD_PATH,
    SFTP_BINARY_MARKER, SFTP_TEXT_MARKER, SFTP_TEXT_EDITED_MARKER];
  assertThat(requiredInputs.every((value) => typeof value === 'string' && value.length > 0),
    'native SFTP acceptance fixture inputs were incomplete');
  const binarySource = readRegularFileBytes(SFTP_BINARY_UPLOAD_PATH, 'SFTP binary upload fixture');
  const collisionSource = readRegularFileBytes(SFTP_BINARY_COLLISION_PATH, 'SFTP collision upload fixture');
  const textSource = readRegularFileBytes(SFTP_TEXT_UPLOAD_PATH, 'SFTP UTF-8 upload fixture');
  assertThat(Buffer.from(binarySource).includes(Buffer.from(SFTP_BINARY_MARKER, 'utf8')) &&
    Buffer.from(collisionSource).includes(Buffer.from(SFTP_BINARY_MARKER, 'utf8')) &&
    Buffer.from(textSource).includes(Buffer.from(SFTP_TEXT_MARKER, 'utf8')),
  'SFTP fixture content did not include its configured privacy markers');
  const binaryName = path.basename(SFTP_BINARY_UPLOAD_PATH);
  const collisionName = path.basename(SFTP_BINARY_COLLISION_PATH);
  const textName = path.basename(SFTP_TEXT_UPLOAD_PATH);
  assertThat(binaryName === collisionName &&
    [binaryName, textName].every((name) => /^[A-Za-z0-9._-]{1,200}$/.test(name)),
  'SFTP fixture names were unsafe or the collision source basename differed');
  assertThat(!Buffer.from(binarySource).equals(Buffer.from(collisionSource)),
    'SFTP collision source must contain different bytes under the same basename');
  assertThat(path.isAbsolute(SFTP_BINARY_DOWNLOAD_PATH) && path.isAbsolute(SFTP_TEXT_DOWNLOAD_PATH) &&
    !fs.existsSync(SFTP_BINARY_DOWNLOAD_PATH) && !fs.existsSync(SFTP_TEXT_DOWNLOAD_PATH),
  'SFTP download fixtures must be fresh absolute destinations');

  const initialText = textSource.toString('utf8');
  assertThat(Buffer.from(initialText, 'utf8').equals(textSource) &&
    initialText.includes(SFTP_TEXT_MARKER) && !initialText.includes(SFTP_TEXT_EDITED_MARKER),
  'SFTP text fixture was not canonical UTF-8 or had invalid marker state');
  const editedText = `${initialText}edited-marker=${SFTP_TEXT_EDITED_MARKER}\n`;
  const editedTextBytes = Buffer.from(editedText, 'utf8');
  EXTRA_PERSISTENCE_MARKERS.push(SFTP_BINARY_MARKER, SFTP_TEXT_MARKER, SFTP_TEXT_EDITED_MARKER);

  const ledgerBefore = readServerVaultLedgerSummary(vaultId);
  assertThat(ledgerBefore.commit_seq === 5,
    'SFTP acceptance did not begin immediately after the exact KnownHost commit 5');
  const sshBefore = sshFixture.summary();
  const sftpRequestsBefore = sshBefore.sftpRequests;
  const sftpSessionsBefore = sshBefore.sftpSessions;
  const remoteDirectoryName = `atermius-sftp-${crypto.randomBytes(8).toString('hex')}`;
  const remoteDirectoryPath = path.join(sshFixture.homePath, remoteDirectoryName);
  const remoteBinaryPath = path.join(remoteDirectoryPath, binaryName);
  const remoteTextPath = path.join(remoteDirectoryPath, textName);
  MARKERS.push(remoteDirectoryName, binaryName, textName);
  EXTRA_PERSISTENCE_MARKERS.push(remoteDirectoryName, binaryName, textName);

  stage('native account SFTP: open the verified Host file browser and select the fixture account home');
  await nativeClick('SFTP', 'native SFTP workspace navigation', 12000);
  await waitNativeText('SFTP file browser', 'native account SFTP file browser', 12000);
  await waitFor(() => nativeVisibleTextContains('Remote files ·') ? true : null,
    'active SSH session in the native SFTP browser', 10000, 250);
  try {
    await waitFor(async () => {
      const state = await nativeNamedButtonAccessibility('Go to path');
      return state.button_visible && state.button_enabled ? state : null;
    }, 'available native SFTP Go to path action', 10000, 250);
  } catch (error) {
    const state = await nativeNamedButtonAccessibility('Go to path');
    stage(`native SFTP Go to path accessibility available=${state.available} ` +
      `named=${state.button_named} role=${state.button_role} ` +
      `visible=${state.button_visible} enabled=${state.button_enabled}`);
    throw error;
  }
  const goToPath = await nativeNamedButtonAccessibility('Go to path', true);
  assertThat(goToPath.button_visible && goToPath.button_activated,
    'native SFTP Go to path action was not available');
  await waitNativeText('Go to remote path', 'native SFTP remote path dialog', 8000);
  await nativeFill('Remote path', sshFixture.homePath);
  const remotePathField = nativeTextFieldAccessibility('Remote path', sshFixture.homePath);
  assertThat(remotePathField.field_visible && remotePathField.value_matches,
    'native SFTP account home path field did not retain its exact value');
  await nativeClick('Go', 'native SFTP account home path navigation', 8000);
  await waitFor(() => nativeVisibleTextContains(sshFixture.homePath) ? true : null,
    'native SFTP account home listing', 10000, 500);

  stage('native account SFTP: create a unique remote directory through the UI');
  await nativeClick('New folder', 'native SFTP new folder action', 10000);
  await waitNativeText('Create remote folder', 'native SFTP create folder dialog', 8000);
  await nativeFill('Folder name', remoteDirectoryName);
  const folderNameField = nativeTextFieldAccessibility('Folder name', remoteDirectoryName);
  assertThat(folderNameField.field_visible && folderNameField.value_matches,
    'native SFTP folder name field did not retain the unique name');
  await nativeClick('Create', 'native SFTP create folder submit', 8000);
  await waitFor(() => {
    try { return fs.lstatSync(remoteDirectoryPath).isDirectory() ? true : null; }
    catch (_) { return null; }
  }, 'remote SFTP directory creation', 10000, 100);
  await waitNativeText(remoteDirectoryName, 'native SFTP created directory listing', 10000);
  await nativeClick(remoteDirectoryName, 'native SFTP enter created directory', 8000);
  await waitFor(() => nativeVisibleTextContains(remoteDirectoryName) ? true : null,
    'native SFTP current directory path', 10000, 500);

  stage('native account SFTP: upload exact binary bytes using the native file chooser');
  await nativeClick('Upload', 'native SFTP binary upload action', 10000);
  await selectNativeFilePickerPath(SFTP_BINARY_UPLOAD_PATH, 'binary upload');
  await waitNativeText(binaryName, 'native SFTP uploaded binary listing', 12000);
  await waitFor(() => {
    try { return readRegularFileBytes(remoteBinaryPath, 'remote SFTP binary').equals(binarySource) ? true : null; }
    catch (_) { return null; }
  }, 'remote SFTP binary byte-for-byte upload', 12000, 100);
  const binaryUploadSha256 = sha256Hex(binarySource);

  stage('native account SFTP: reject a same-name upload with different bytes');
  await nativeClick('Upload', 'native SFTP collision upload action', 10000);
  await selectNativeFilePickerPath(SFTP_BINARY_COLLISION_PATH, 'collision upload');
  await waitFor(() => nativeVisibleTextContains('无法安全创建远端文件') ? true : null,
    'native SFTP exclusive-create collision error', 12000, 500);
  const collisionOriginalUnchanged =
    sha256Hex(readRegularFileBytes(remoteBinaryPath, 'remote SFTP collision target')) === binaryUploadSha256 &&
    readRegularFileBytes(remoteBinaryPath, 'remote SFTP collision target').equals(binarySource);
  assertThat(collisionOriginalUnchanged,
    'a same-name SFTP upload changed the existing remote file bytes');

  stage('native account SFTP: upload and securely edit a UTF-8 text file');
  await nativeClick('Upload', 'native SFTP text upload action', 10000);
  await selectNativeFilePickerPath(SFTP_TEXT_UPLOAD_PATH, 'UTF-8 text upload');
  await waitNativeText(textName, 'native SFTP uploaded text listing', 12000);
  await waitFor(() => {
    try { return readRegularFileBytes(remoteTextPath, 'remote SFTP text').equals(textSource) ? true : null; }
    catch (_) { return null; }
  }, 'remote SFTP UTF-8 initial upload', 12000, 100);
  await nativeSftpEntryActions(textName);
  await nativeClick('Edit text', 'native SFTP text editor action', 8000);
  await waitNativeText('Edit remote text file', 'native SFTP UTF-8 text editor', 10000);
  await nativeFill('Remote file contents', editedText);
  const editedTextField = nativeTextFieldAccessibility('Remote file contents', editedText);
  assertThat(editedTextField.field_visible && editedTextField.value_matches,
    'native SFTP text editor did not retain the exact UTF-8 draft');
  const saveButton = await nativeNamedButtonAccessibility('Save', true, null, true);
  assertThat(saveButton.button_visible && saveButton.button_activated,
    'native SFTP text editor Save action was not available');
  await waitNativeText('SFTP file browser', 'native SFTP page after text save', 15000);
  await waitFor(() => {
    try { return readRegularFileBytes(remoteTextPath, 'remote SFTP edited text').equals(editedTextBytes) ? true : null; }
    catch (_) { return null; }
  }, 'remote SFTP atomic UTF-8 text save', 15000, 100);

  stage('native account SFTP: download binary and edited text to isolated local paths');
  await nativeSftpEntryActions(binaryName);
  await nativeClick('Download', 'native SFTP binary download action', 8000);
  await selectNativeFilePickerPath(SFTP_BINARY_DOWNLOAD_PATH, 'binary download save');
  await waitFor(() => {
    try { return readRegularFileBytes(SFTP_BINARY_DOWNLOAD_PATH, 'downloaded SFTP binary').equals(binarySource) ? true : null; }
    catch (_) { return null; }
  }, 'native SFTP binary download bytes', 15000, 100);
  const binaryDownloadSha256 = sha256Hex(readRegularFileBytes(SFTP_BINARY_DOWNLOAD_PATH, 'downloaded SFTP binary'));

  await nativeSftpEntryActions(textName);
  await nativeClick('Download', 'native SFTP edited text download action', 8000);
  await selectNativeFilePickerPath(SFTP_TEXT_DOWNLOAD_PATH, 'UTF-8 text download save');
  await waitFor(() => {
    try { return readRegularFileBytes(SFTP_TEXT_DOWNLOAD_PATH, 'downloaded SFTP text').equals(editedTextBytes) ? true : null; }
    catch (_) { return null; }
  }, 'native SFTP edited text download bytes', 15000, 100);
  const textDownloadSha256 = sha256Hex(readRegularFileBytes(SFTP_TEXT_DOWNLOAD_PATH, 'downloaded SFTP text'));

  stage('native account SFTP: delete the remote files and directory through the UI');
  await confirmNativeSftpDelete(binaryName);
  await waitFor(() => !fs.existsSync(remoteBinaryPath) ? true : null,
    'remote SFTP binary deletion', 10000, 100);
  await confirmNativeSftpDelete(textName);
  await waitFor(() => !fs.existsSync(remoteTextPath) ? true : null,
    'remote SFTP text deletion', 10000, 100);
  const upButton = await nativeNamedButtonAccessibility('Up one directory', true);
  assertThat(upButton.button_visible && upButton.button_activated,
    'native SFTP Up one directory action was not available');
  await waitNativeText(remoteDirectoryName, 'native SFTP parent directory listing', 10000);
  await confirmNativeSftpDelete(remoteDirectoryName);
  await waitFor(() => !fs.existsSync(remoteDirectoryPath) ? true : null,
    'remote SFTP directory deletion', 10000, 100);

  const sshAfter = sshFixture.summary();
  assertThat(sshAfter.sftpSessions > sftpSessionsBefore &&
    sshAfter.sftpRequests > sftpRequestsBefore &&
    sshAfter.publicKeyAccepted >= 1 && sshAfter.passwordAccepted === 0 &&
    sshAfter.passwordRejected === 0,
  'isolated SSH fixture did not record a public-key authenticated SFTP session');
  const ledgerAfter = readServerVaultLedgerSummary(vaultId);
  const ledgerUnchanged = JSON.stringify(ledgerAfter) === JSON.stringify(ledgerBefore);
  assertThat(ledgerUnchanged && ledgerAfter.commit_seq === 5,
    'account SFTP activity changed the Vault record ledger');
  const filesDeleted = !fs.existsSync(remoteBinaryPath) && !fs.existsSync(remoteTextPath);
  const directoryDeleted = !fs.existsSync(remoteDirectoryPath);
  assertThat(filesDeleted && directoryDeleted,
    'account SFTP did not remove its remote test files and directory');

  return {
    sftp_binary_upload_sha256: binaryUploadSha256,
    sftp_binary_remote_sha256: binaryUploadSha256,
    sftp_binary_download_sha256: binaryDownloadSha256,
    sftp_collision_upload_rejected: true,
    sftp_collision_original_unchanged: collisionOriginalUnchanged,
    sftp_text_upload_sha256: sha256Hex(textSource),
    sftp_text_edited_sha256: sha256Hex(editedTextBytes),
    sftp_text_remote_sha256: sha256Hex(editedTextBytes),
    sftp_text_download_sha256: textDownloadSha256,
    sftp_text_editor_saved: true,
    sftp_remote_files_deleted: filesDeleted,
    sftp_remote_directory_deleted: directoryDeleted,
    ssh_sftp_session_count: sshAfter.sftpSessions,
    sftp_vault_ledger_unchanged: ledgerUnchanged,
  };
}

function startNative() {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (key.startsWith(ENV)) delete environment[key];
  }
  for (const key of ['ATERMIUS_SYNC_PG_URL', 'ATERMIUS_SYNC_PG_SCHEMA',
    'ATERMIUS_DATABASE_URL', 'PGPASSWORD', 'PGHOST', 'PGPORT', 'PGUSER', 'PGDATABASE']) {
    delete environment[key];
  }
  nativeProcess = spawn(NATIVE_APP, [], {
    cwd: path.dirname(NATIVE_APP), env: environment, detached: true,
    stdio: 'ignore',
  });
  CHILDREN.add(nativeProcess);
  nativeProcess.once('exit', () => CHILDREN.delete(nativeProcess));
  return nativeProcess;
}

function browserEnvironment() {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (key.startsWith(ENV)) delete environment[key];
  }
  for (const key of ['ATERMIUS_SYNC_PG_URL', 'ATERMIUS_SYNC_PG_SCHEMA',
    'ATERMIUS_DATABASE_URL', 'PGPASSWORD', 'PGHOST', 'PGPORT', 'PGUSER', 'PGDATABASE']) {
    delete environment[key];
  }
  return environment;
}

function ensurePrivateKeyring() {
  const result = spawnSync('gnome-keyring-daemon', ['--unlock', '--daemonize', '--components=secrets'], {
    input: '\n', encoding: 'utf8', timeout: 10000, stdio: ['pipe', 'pipe', 'ignore'],
  });
  if (!result.error && result.status === 0) {
    for (const line of (result.stdout || '').split(/\r?\n/)) {
      const match = line.match(/^([A-Z0-9_]+)=(.*?); export \1;$/);
      if (match) process.env[match[1]] = match[2];
    }
    keyringStarted = true;
  }
}

function walkFiles(directory, depth = 0) {
  if (depth > 8) return [];
  let entries;
  try { entries = fs.readdirSync(directory, { withFileTypes: true }); } catch (_) { return []; }
  const found = [];
  for (const entry of entries) {
    const full = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) continue;
    if (entry.isDirectory()) found.push(...walkFiles(full, depth + 1));
    else if (entry.isFile()) found.push(full);
  }
  return found;
}

function nativeDatabasePath() {
  if (nativeSyncDatabasePathCache && fs.existsSync(nativeSyncDatabasePathCache)) {
    return nativeSyncDatabasePathCache;
  }
  const candidates = privateNativeRoots().flatMap((root) => walkFiles(root));
  for (const file of candidates) {
    try {
      const descriptor = fs.openSync(file, 'r');
      const prefix = Buffer.alloc(16);
      const read = fs.readSync(descriptor, prefix, 0, prefix.length, 0);
      fs.closeSync(descriptor);
      if (read !== 16 || prefix.toString('binary') !== 'SQLite format 3\0') continue;
      const check = spawnSync('python3', ['-c', String.raw`
import sqlite3,sys
try:
 d=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=2)
 names={r[0] for r in d.execute("SELECT name FROM sqlite_master WHERE type='table'")}
 print('yes' if {'pending_operations','encrypted_records'} <= names else 'no')
 d.close()
except Exception:
 print('no')
`, file], {
        encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024,
        stdio: ['ignore', 'pipe', 'ignore'],
        env: { PATH: process.env.PATH || '/usr/bin:/bin', HOME: HOME || '/tmp',
          XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || '', XDG_DATA_HOME: process.env.XDG_DATA_HOME || '',
          XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || '', XDG_STATE_HOME: process.env.XDG_STATE_HOME || '' },
      });
      if (!check.error && check.status === 0 && check.stdout.trim() === 'yes') {
        nativeSyncDatabasePathCache = file;
        return file;
      }
    } catch (_) {}
  }
  return null;
}

const SQLITE_INSPECT = String.raw`
import sys,sqlite3,json,hashlib
p=sys.argv[1]; raw_targets=sys.argv[2] if len(sys.argv)>2 else ''
try:
 targets=json.loads(raw_targets) if raw_targets.startswith('[') else ([raw_targets] if raw_targets else [])
except Exception:
 targets=[]
db=sqlite3.connect('file:'+p+'?mode=ro',uri=True,timeout=3)
db.row_factory=sqlite3.Row
tables={r['name'] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
if 'pending_operations' not in tables:
 print(json.dumps({'integrity':'missing','pending':[]})); raise SystemExit(0)
rows=db.execute('SELECT op_id,vault_id,record_id,envelope_json,status FROM pending_operations').fetchall()
out=[]
for r in rows:
 try: env=json.loads(r['envelope_json'])
 except Exception: env={}
 h=env.get('header') or {}
 canonical=json.dumps(env,sort_keys=True,separators=(',',':'),ensure_ascii=False)
 out.append({'opId':r['op_id'],'vaultId':r['vault_id'],'recordId':r['record_id'],
  'status':r['status'],'envelopeSha256':hashlib.sha256(r['envelope_json'].encode()).hexdigest(),
  'canonicalEnvelopeSha256':hashlib.sha256(canonical.encode()).hexdigest(),
  'header':{k:h.get(k) for k in ('op_id','record_id','revision_id','vault_id','device_id','device_seq','operation')}})
integrity=db.execute('PRAGMA integrity_check').fetchone()[0]
records=[]
if targets and 'encrypted_records' in tables:
 placeholders=','.join('?' for _ in targets)
 for r in db.execute('SELECT vault_id,record_id,revision_id,commit_seq,envelope_json FROM encrypted_records WHERE record_id IN ('+placeholders+')',tuple(targets)):
  try: h=(json.loads(r['envelope_json']).get('header') or {})
  except Exception: h={}
  try: canonical=hashlib.sha256(json.dumps(json.loads(r['envelope_json']),sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')).hexdigest()
  except Exception: canonical=None
  records.append({'vaultId':r['vault_id'],'recordId':r['record_id'],'revisionId':r['revision_id'],
   'commitSeq':r['commit_seq'],'envelopeSha256':hashlib.sha256(r['envelope_json'].encode()).hexdigest(),
   'canonicalEnvelopeSha256':canonical,
   'header':{k:h.get(k) for k in ('op_id','record_id','revision_id','vault_id','device_id','device_seq','operation')}})
print(json.dumps({'integrity':integrity,'pending':out,'records':records},separators=(',',':')))
db.close()
`;

function inspectNativeDatabase(dbPath, targetRecordId = '') {
  assertThat(dbPath, 'native SQLite database was not created in the private HOME');
  const result = spawnSync('python3', ['-c', SQLITE_INSPECT, dbPath, targetRecordId], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'read-only native outbox inspection failed');
  let summary;
  try { summary = JSON.parse(result.stdout); } catch (_) { throw new Error('native SQLite summary was invalid'); }
  assertThat(summary.integrity === 'ok' && Array.isArray(summary.pending),
    'native SQLite integrity or pending outbox table was invalid');
  return summary;
}

function inspectNativeDatabaseRecords(dbPath, recordIds) {
  assertThat(Array.isArray(recordIds) && recordIds.length > 0 && recordIds.every(validUuid),
    'native encrypted record inspection identifiers were invalid');
  return inspectNativeDatabase(dbPath, JSON.stringify(recordIds)).records || [];
}

function processAlive(child) {
  try { process.kill(child.pid, 0); return true; } catch (_) { return false; }
}

async function killNativeHard() {
  if (!nativeProcess) return false;
  const pid = nativeProcess.pid;
  try { process.kill(-pid, 'SIGKILL'); } catch (_) { try { process.kill(pid, 'SIGKILL'); } catch (_) {} }
  await waitFor(() => !processAlive(nativeProcess), 'native SIGKILL exit', 10000, 100);
  nativeProcess = null;
  return true;
}

async function nativeScreenState() {
  const lines = captureNativeOcr();
  const text = normalizeOcr(lines.map((line) => line.text).join(' '));
  const hostsNav = text.includes('hosts');
  const loginHeading = text.includes('unlock your workspace');
  const loginField = findOcrAnchor(lines, 'Email or username') !== null;
  const loginSubmit = findOcrAnchor(lines, 'Sign in and unlock') !== null;
  const serverHeading = text.includes('connect to your server');
  const serverField = findOcrAnchor(lines, 'Server URL') !== null;
  const serverSubmit = findOcrAnchor(lines, 'Connect securely') !== null;
  const registerHeading = text.includes('set up your private vault');
  const registerSubmit = findOcrAnchor(lines, 'Create owner account') !== null ||
    findOcrAnchor(lines, 'Create invited account') !== null;
  const registerFields = findOcrAnchor(lines, 'Owner email') !== null ||
    findOcrAnchor(lines, 'One-time bootstrap token') !== null;
  const register = registerHeading || registerSubmit || registerFields;
  const hostPage = findOcrAnchor(lines, 'Your server fleet') !== null;
  const noAccessibleVault = findOcrAnchor(lines, 'No accessible Vaults') !== null;
  return {
    lines,
    workspace: hostPage || noAccessibleVault || text.includes('sync conflicts') || hostsNav,
    hostPage,
    noAccessibleVault,
    login: loginHeading || (loginField && loginSubmit),
    loginHeading,
    loginField,
    loginSubmit,
    register,
    registerHeading,
    registerSubmit,
    registerFields,
    unlock: text.includes('master password') && /unlock/.test(text),
    server: serverHeading || serverField,
    serverHeading,
    serverField,
    serverSubmit,
    chooser: text.includes('choose a workspace'),
    serverModeOption: findOcrAnchor(lines, 'Server account and sync') !== null,
    continue: findOcrAnchor(lines, 'Continue') !== null,
    hostsNav,
  };
}

function nativeStateSummary(state) {
  return `chooser=${Boolean(state.chooser)} serverModeOption=${Boolean(state.serverModeOption)} ` +
    `continue=${Boolean(state.continue)} server=${Boolean(state.server)} login=${Boolean(state.login)} ` +
    `serverHeading=${Boolean(state.serverHeading)} serverField=${Boolean(state.serverField)} ` +
    `serverSubmit=${Boolean(state.serverSubmit)} ` +
    `loginHeading=${Boolean(state.loginHeading)} loginField=${Boolean(state.loginField)} ` +
    `loginSubmit=${Boolean(state.loginSubmit)} register=${Boolean(state.register)} ` +
    `registerHeading=${Boolean(state.registerHeading)} registerSubmit=${Boolean(state.registerSubmit)} ` +
    `registerFields=${Boolean(state.registerFields)} unlock=${Boolean(state.unlock)} ` +
    `workspace=${Boolean(state.workspace)} hostPage=${Boolean(state.hostPage)} ` +
    `noAccessibleVault=${Boolean(state.noAccessibleVault)} ` +
    `recognizedTokens=${Array.isArray(state.lines) ? state.lines.reduce((total, line) =>
      total + (Array.isArray(line.tokens) ? line.tokens.length : 0), 0) : 0}`;
}

function nativeChildDiagnostics() {
  const alive = Boolean(nativeProcess && processAlive(nativeProcess));
  const id = nativeWindow();
  if (!id || !/^\d+$/.test(id)) return `processAlive=${alive} windowId=none windowName=none geometry=none`;
  const nameResult = spawnSync('xdotool', ['getwindowname', id], {
    encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  const name = !nameResult.error && nameResult.status === 0 && /aterm_client/i.test(nameResult.stdout || '')
    ? 'aterm_client' : 'other';
  const geometryResult = spawnSync('xdotool', ['getwindowgeometry', '--shell', id], {
    encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  const geometry = {};
  if (!geometryResult.error && geometryResult.status === 0) {
    for (const key of ['X', 'Y', 'WIDTH', 'HEIGHT']) {
      const line = String(geometryResult.stdout || '').split(/\r?\n/)
        .find((candidate) => candidate.startsWith(`${key}=`));
      const raw = line?.slice(key.length + 1);
      if (raw && /^-?\d+$/.test(raw)) geometry[key.toLowerCase()] = Number(raw);
    }
  }
  const shape = ['x', 'y', 'width', 'height'].every((key) => Number.isSafeInteger(geometry[key]))
    ? `x=${geometry.x},y=${geometry.y},width=${geometry.width},height=${geometry.height}` : 'unavailable';
  return `processAlive=${alive} windowId=${id} windowName=${name} geometry=${shape}`;
}

function nativeInstanceStatusSummary() {
  const events = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'GET' &&
    event.path === '/api/v1/instance');
  const counts = new Map();
  for (const event of events) {
    const status = Number.isInteger(event.status) ? String(event.status) : 'pending';
    counts.set(status, (counts.get(status) || 0) + 1);
  }
  const statuses = [...counts.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([status, count]) => `${status}:${count}`).join(',') || 'none';
  return `instanceGetCount=${events.length} instanceGetStatusCounts=${statuses}`;
}

function nativeAuthStatusSummary() {
  const paths = [
    ['/api/v1/auth/prelogin', 'prelogin'],
    ['/api/v1/auth/login', 'login'],
    ['/api/v1/auth/login/mfa', 'login-mfa'],
  ];
  const summaries = paths.map(([path, label]) => {
    const events = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'POST' &&
      event.path === path);
    const counts = new Map();
    for (const event of events) {
      const status = Number.isInteger(event.status) ? String(event.status) : 'pending';
      counts.set(status, (counts.get(status) || 0) + 1);
    }
    const statuses = [...counts.entries()].sort(([left], [right]) => left.localeCompare(right))
      .map(([status, count]) => `${status}:${count}`).join(',') || 'none';
    return `${label}=${events.length}[${statuses}]`;
  });
  return summaries.join(' ');
}

function nativeVaultStatusSummary() {
  const events = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'GET' &&
    event.path === '/api/v1/vaults');
  const counts = new Map();
  for (const event of events) {
    const status = Number.isInteger(event.status) ? String(event.status) : 'pending';
    counts.set(status, (counts.get(status) || 0) + 1);
  }
  const statuses = [...counts.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([status, count]) => `${status}:${count}`).join(',') || 'none';
  return `vaultList=${events.length}[${statuses}]`;
}

function nativeSyncRequestSummary() {
  const changes = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'GET' &&
    /\/api\/v1\/vaults\/[^/]+\/changes$/.test(event.path));
  const pushes = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'POST' &&
    /\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(event.path));
  const statuses = (events) => {
    const counts = new Map();
    for (const event of events) {
      const status = Number.isInteger(event.status) ? String(event.status) : 'pending';
      counts.set(status, (counts.get(status) || 0) + 1);
    }
    return [...counts.entries()].sort(([left], [right]) => left.localeCompare(right))
      .map(([status, count]) => `${status}:${count}`).join(',') || 'none';
  };
  return `changes=${changes.length}[${statuses(changes)}] syncPush=${pushes.length}[${statuses(pushes)}]`;
}

async function waitForNativeLogin(description, timeoutMs = 45000) {
  let lastState = null;
  try {
    return await waitFor(async () => {
      lastState = await nativeScreenState();
      if (lastState.register) throw new Error('registration flow detected');
      return lastState.login ? lastState : null;
    }, description, timeoutMs, 300);
  } catch (_) {
    const reason = lastState?.register ? 'stopped on registration flow' : 'timed out waiting for login';
    throw new Error(`${description} ${reason} (${nativeStateSummary(lastState || {})}; ` +
      `${nativeChildDiagnostics()}; ${nativeInstanceStatusSummary()})`);
  }
}

async function waitForNativeWorkspace(description, timeoutMs = 60000) {
  let lastState = null;
  try {
    return await waitFor(async () => {
      lastState = await nativeScreenState();
      if (lastState.noAccessibleVault) throw new Error('native account has no accessible Vaults');
      return lastState.hostPage ? lastState : null;
    }, description, timeoutMs, 300);
  } catch (_) {
    const reason = lastState?.noAccessibleVault ? 'has no accessible Vaults' : 'timed out';
    throw new Error(`${description} ${reason} (${nativeStateSummary(lastState || {})}; ` +
      `${nativeChildDiagnostics()}; ${nativeAuthStatusSummary()})`);
  }
}

async function nativeChooseServerMode(description = 'server mode selection') {
  let state = await nativeScreenState();
  if (state.server || state.login || (state.workspace && !state.chooser && !state.serverModeOption)) return state;
  if (!state.chooser && !state.serverModeOption) return state;

  if (state.serverModeOption) {
    stage(`native ${description}: select server account and sync`);
    await nativeClick('Server account and sync', `${description} server account and sync choice`);
    state = await waitFor(async () => {
      const observed = await nativeScreenState();
      return observed.server || observed.login || observed.workspace || observed.continue ? observed : null;
    }, `native ${description} selection transition`, 20000, 300);
  }

  if (state.continue && !state.server && !state.login) {
    stage(`native ${description}: continue to Server URL`);
    await nativeClick('Continue', `${description} Continue action`);
    let lastState = null;
    try {
      state = await waitFor(async () => {
        lastState = await nativeScreenState();
        return lastState.server || lastState.login || lastState.workspace ? lastState : null;
      }, `native ${description} next screen`, 30000, 300);
    } catch (_) {
      let screenshot = 'not-captured';
      if (description === 'initial setup') {
        try { screenshot = saveInitialChooserDiagnosticBmp(); } catch (_) { screenshot = 'capture-failed'; }
      }
      const processWindow = nativeChildDiagnostics();
      if (screenshot.startsWith('/tmp/')) stage(`native initial chooser diagnostic image saved mode=0600 path=${screenshot}`);
      throw new Error(`native ${description} next-screen timeout (${nativeStateSummary(lastState || {})}; ` +
        `${processWindow}; diagnosticBmp=${screenshot})`);
    }
  }
  stage(`native ${description}: screen after selection ${nativeStateSummary(state)}`);
  return state;
}

async function nativeSyncNow() {
  await nativeClick('Sync & conflicts', 'Sync & conflicts navigation');
  const syncButtonState = async (activate = false, signal = null) => {
    try { return await nativeNamedButtonAccessibility('Sync now', activate, signal); }
    catch (_) { return { button_visible: false, button_activated: false }; }
  };
  let actionState;
  try {
    actionState = await waitFor(async (signal) => {
      const lines = captureNativeOcr();
      if (findOcrAnchor(lines, 'Sync now')) return 'idle';
      if (findOcrAnchor(lines, 'Syncing')) return 'syncing';
      if ((await syncButtonState(false, signal)).button_visible) return 'idle';
      if (findOcrAnchor(lines, 'Snapshot limit reached') ||
          findOcrAnchor(lines, 'Recovery required')) return 'unavailable';
      return null;
    }, 'native sync action state', 30000, 300);
  } catch (_) {
    const lines = captureNativeOcr();
    const state = await nativeScreenState();
    const syncDiagnostics = {
      syncNow: findOcrAnchor(lines, 'Sync now') !== null,
      syncing: findOcrAnchor(lines, 'Syncing') !== null,
      snapshotLimit: findOcrAnchor(lines, 'Snapshot limit reached') !== null,
      recoveryRequired: findOcrAnchor(lines, 'Recovery required') !== null,
      syncTitle: findOcrAnchor(lines, 'Sync') !== null,
    };
    const screenshot = saveNativeWindowDiagnosticBmp('sync-action-timeout');
    stage(`native sync action diagnostic ${nativeStateSummary(state)} ` +
      `${Object.entries(syncDiagnostics).map(([key, value]) => `${key}=${value}`).join(' ')} ` +
      `image=${screenshot}`);
    throw new Error('timed out waiting for native sync action state');
  }
  // Logging in with a durable outbox can start synchronization before the
  // explicit Sync page action is reached. In that case, let the in-flight
  // attempt finish and let its signed receipt be the acceptance evidence.
  if (actionState === 'idle') {
    const accessibleAction = await syncButtonState(true);
    if (!accessibleAction.button_activated) {
      let refreshedState = null;
      try {
        refreshedState = await waitFor(async (signal) => {
          const lines = captureNativeOcr();
          if (findOcrAnchor(lines, 'Syncing')) return 'syncing';
          if (findOcrAnchor(lines, 'Sync now') || (await syncButtonState(false, signal)).button_visible) return 'idle';
          return null;
        }, 'native sync action refresh', 5000, 250);
      } catch (_) { /* try the newly observed action below */ }
      if (refreshedState !== 'syncing') {
        const clicked = await nativeTryClick('Sync now', 10000);
        if (!clicked) {
          const retriedAction = await syncButtonState(true);
          assertThat(retriedAction.button_activated,
            'native Sync now action disappeared before synchronization started');
        }
      }
    }
  }
  else assertThat(actionState === 'syncing', 'native Sync now action is unavailable');
  await waitNativeText('Sync', 'sync view', 15000);
  await nativeOpenHostsPage('native sync');
}

async function connectNativeProxy(nativeBaseUrl) {
  stage('native start: wait for application window');
  await waitFor(() => nativeWindow() !== null, 'native application window', 45000, 300);
  stage('native connect: inspect startup screen and select server mode');
  const state = await nativeChooseServerMode('initial setup');
  assertThat(state.server || state.login,
    `native server mode selection did not reach the Server URL or account screen (${nativeStateSummary(state)})`);
  if (state.server) {
    stage('native connect: wait for Server URL screen');
    await waitNativeText('Server URL', 'Server URL screen');
    stage('native connect: enter loopback server and connect');
    await nativeFill('Server URL', nativeBaseUrl);
    stage('native connect: submit the focused Connect action');
    nativeExec(['key', 'Return']);
  }
  stage('native connect: wait for account sign-in');
  await waitForNativeLogin('native account sign-in', 45000);
}

async function requestNativeEnrollment() {
  stage('native enrollment: open Add this device');
  await nativeClick('Add this device', 'Add this device action');
  await waitNativeText('Request this device', 'device enrollment dialog');
  stage('native enrollment: enter account and device details');
  await nativeFill('Account email', USERNAME);
  await nativeFillFocused('PG native sync device');
  stage('native enrollment: generate and copy public request');
  const generatedByOcr = await nativeTryClick('Generate request', 3500);
  if (!generatedByOcr) {
    stage('native enrollment: advance from Close to Generate request and submit');
    nativeExec(['key', 'Tab']);
    nativeExec(['key', 'Return']);
    await wait(350);
  }
  await waitNativeText('Copy this enrollment JSON', 'native enrollment request');
  stage('native enrollment: focus request JSON and activate the Copy action');
  await nativeClick('Copy this enrollment JSON', 'enrollment request JSON field', 10000, 18);
  nativeExec(['key', 'Tab']);
  nativeExec(['key', 'Return']);
  await wait(350);
  const text = readClipboard();
  let request;
  try { request = JSON.parse(text); } catch (_) { throw new Error('native enrollment clipboard JSON was invalid'); }
  const deviceId = request?.device?.device_id || request?.device_id;
  assertThat(request?.format === 'atermius-device-enrollment-v1' && validUuid(deviceId),
    'native enrollment request did not identify a valid device');
  await nativeClick('Close', 'close enrollment dialog');
  await ensureNativeEnrollmentDialogClosed();
  return { json: text, deviceId };
}

async function approveNativeEnrollment(enrollmentJson) {
  stage('Web enrollment approval: open Devices and submit native request');
  await click(webPage, 'Devices');
  await click(webPage, 'Approve enrollment');
  await paste(webPage, 'Enrollment JSON', enrollmentJson);
  await click(webPage, 'Review keys');
  stage('Web enrollment approval: review and seal device keys');
  await button(webPage, 'Approve & seal keys');
  await click(webPage, 'Approve & seal keys');
  stage('Web enrollment approval: copy sealed device approval');
  await button(webPage, 'Copy');
  await click(webPage, 'Copy');
  const approvalJson = await webPage.evaluate(() => navigator.clipboard.readText());
  let approval;
  try { approval = JSON.parse(approvalJson); } catch (_) { throw new Error('Web approval clipboard JSON was invalid'); }
  const approvedId = approval?.device?.device_id || approval?.device_id ||
    approval?.recipient_device_id;
  assertThat(approval?.format === 'atermius-device-approval-v1' &&
    (!approvedId || approvedId === JSON.parse(enrollmentJson)?.device?.device_id),
  'Web did not seal the matching native enrollment keys');
  await click(webPage, 'Done');
  return approvalJson;
}

async function importNativeApprovalAndLogin(approvalJson) {
  stage('native approval import: open import dialog and paste sealed approval');
  await nativeClick('Import approval', 'Import approval action');
  await wait(400);
  await nativePasteDialogFieldCentered(approvalJson);
  stage('native approval import: import device keys');
  stage('native approval import: advance from Cancel to Import device keys and submit');
  nativeExec(['key', 'Tab']);
  nativeExec(['key', 'Return']);
  await wait(350);
  await waitForNativeLogin('native login after key import', 30000);
  stage('native enrollment: sign in with imported device keys');
  await nativeFill('Email or username', USERNAME);
  await nativeFill('Master password', PASSWORD);
  stage('native sign-in: click the submit button body');
  await nativeClickSignInButton();
  await waitFor(() => API_EVENTS.some((event) => event.node === 'A' && event.method === 'POST' &&
    event.path === '/api/v1/auth/login' && Number.isInteger(event.status)),
  'native account login response', 20000, 100);
  const loginResponse = API_EVENTS.filter((event) => event.node === 'A' && event.method === 'POST' &&
    event.path === '/api/v1/auth/login').at(-1);
  assertThat(loginResponse?.status === 200 || loginResponse?.status === 202,
    `native account login returned HTTP ${loginResponse?.status ?? 'pending'}`);
  await waitForNativeWorkspace('native unlocked workspace', 60000);
}

async function createNativeHost() {
  let pageState = null;
  try {
    pageState = await waitFor(async () => {
      const state = await nativeScreenState();
      return state.hostPage || state.noAccessibleVault ? state : null;
    }, 'native Hosts page', 15000, 300);
  } catch (_) {
    const state = await nativeScreenState();
    throw new Error(`native Hosts page unavailable (${nativeStateSummary(state)}; ` +
      `${nativeAuthStatusSummary()}; ${nativeVaultStatusSummary()})`);
  }
  assertThat(!pageState.noAccessibleVault,
    'native login completed, but this device has no accessible Vaults');
  const addHost = findOcrAnchor(pageState.lines, 'Add host');
  const addFirstHost = findOcrAnchor(pageState.lines, 'Add your first host');
  if (addHost) await nativeClickObservedLine(addHost, 'Add host');
  else if (addFirstHost) await nativeClickObservedLine(addFirstHost, 'Add your first host');
  else await nativeClickHostCreateButton();
  await waitNativeText('Display name', 'native Host editor');
  await nativeFill('Display name', NATIVE_HOST);
  await nativeFill('Hostname or IP', HOST_ADDRESS);
  const lines = captureNativeOcr();
  if (findOcrAnchor(lines, 'Port')) await nativeFill('Port', '22');
  await nativeFill('SSH username', SSH_USERNAME);
  let savedByOcr = await nativeTryClick('Save encrypted host', 2000);
  if (!savedByOcr) savedByOcr = await nativeTryClick('Save', 1000);
  if (!savedByOcr) {
    const hasGroupField = findOcrAnchor(captureNativeOcr(), 'No group') !== null;
    const tabCount = hasGroupField ? 5 : 4;
    stage(`native Host save: advance through Tags and ${tabCount} controls to Save`);
    for (let index = 0; index < tabCount; index += 1) {
      nativeExec(['key', 'Tab']);
      // Flutter must process each focus transition before the next key event;
      // rapid xdotool invocations can otherwise leave the dialog on Cancel.
      await wait(120);
    }
    nativeExec(['key', 'Return']);
    await wait(700);
  }
  // Do not treat the Host name still visible in the editor's Display name
  // field as evidence that Save succeeded. The caller verifies the encrypted
  // create in the durable outbox and at the held server push.
}

async function editWebHost(recordId, expectedName) {
  const card = webPage.getByRole('group', {
    name: new RegExp(`^Host: ${expectedName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')};`),
  }).first();
  await card.waitFor({ state: 'visible', timeout: 45000 });
  const edit = card.getByRole('button', { name: 'Edit host', exact: true });
  await edit.click();
  const nameField = await field(webPage, 'Display name');
  await nameField.click(); await nameField.press('Control+A'); await nameField.fill(WEB_HOST);
  await click(webPage, 'Save encrypted host');
  const changedCard = webPage.getByRole('group', {
    name: new RegExp(`^Host: ${WEB_HOST.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')};`),
  }).first();
  await changedCard.waitFor({ state: 'visible', timeout: 45000 });
  assertThat(validUuid(recordId), 'Web edit was not bound to the native record');
}

async function createWebPrivateKeyCredential(credentialName, username, privateKeyPem) {
  await click(webPage, 'Credentials');
  await click(webPage, 'Add credential');
  await fill(webPage, 'Credential name', credentialName);
  await fill(webPage, 'SSH username', username);
  await click(webPage, 'Private key');
  const keyField = await field(webPage, 'PEM private key');
  await keyField.click();
  await keyField.press('Control+A');
  await pageClipboardWrite(privateKeyPem);
  await keyField.press('Control+V');
  await waitFor(async () => (await keyField.inputValue().catch(() => '')) === privateKeyPem,
    'Web PEM private-key field round-trip', 15000, 100);
  await pageClipboardWrite('');
  await keyField.press('Tab');
  const actualPublic = crypto.createPublicKey(crypto.createPrivateKey(await keyField.inputValue()))
    .export({ type: 'spki', format: 'der' });
  const expectedPublic = crypto.createPublicKey(crypto.createPrivateKey(privateKeyPem))
    .export({ type: 'spki', format: 'der' });
  assertThat(actualPublic.equals(expectedPublic), 'Web Credential form changed the SSH private key');
  await click(webPage, 'Save encrypted credential');
  const escapedName = credentialName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = webPage.getByRole('group', {
    name: new RegExp(`^Credential: ${escapedName}; ${username}; Private key$`),
  }).first();
  await card.waitFor({ state: 'visible', timeout: 30000 });
  const identifier = await card.getAttribute('flt-semantics-identifier');
  const prefix = 'ssh-credential-';
  assertThat(identifier?.startsWith(prefix) && validUuid(identifier.slice(prefix.length)),
    'Web private-key Credential did not expose its encrypted record identity');
  return identifier.slice(prefix.length);
}

async function pageClipboardWrite(value) {
  await webPage.evaluate(async (text) => navigator.clipboard.writeText(text), value);
}

async function selectWebHostCredentialOverride(credentialId, identityLabel) {
  const expectedIdentifier = `ssh-host-credential-override-${credentialId}`;
  const saveHost = webPage.getByRole('button', { name: 'Save encrypted host', exact: true }).last();
  const saveBox = await saveHost.boundingBox();
  assertThat(saveBox, 'Web Host editor Save button was unavailable');
  const control = await webPage.evaluate(({ fieldName, saveRect }) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
    };
    const matches = [...document.querySelectorAll('flt-semantics[role="button"], flt-semantics[role="combobox"]')]
      .filter((element) => {
        if (!visible(element)) return false;
        const label = normalize([element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title')].join(' ')).toLowerCase();
        const rect = element.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        return label.includes(fieldName.toLowerCase()) && rect.bottom <= saveRect.y &&
          centerX >= saveRect.x - 500 && centerX <= saveRect.x + saveRect.width + 500;
      });
    if (matches.length !== 1) return { count: matches.length, point: null };
    const element = matches[0];
    const rect = element.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    const hit = document.elementFromPoint(x, y);
    return { count: 1, point: hit && (hit === element || element.contains(hit)) ? { x, y } : null };
  }, { fieldName: 'SSH credential override', saveRect: saveBox });
  assertThat(control?.count === 1 && control.point,
    'Web Host editor Credential override control was not uniquely hit-testable');
  await webPage.mouse.click(control.point.x, control.point.y);
  const option = webPage.locator(`flt-semantics[flt-semantics-identifier="${expectedIdentifier}"]`);
  await option.waitFor({ state: 'visible', timeout: 15000 });
  const optionText = await option.evaluate((element) =>
    [element.getAttribute('aria-label'), element.innerText, element.textContent].filter(Boolean).join(' '));
  assertThat(optionText.replace(/\s+/g, ' ').includes(identityLabel),
    'Web Host override option did not match the exact Credential identity');
  await option.click();
  await webPage.getByText(`Host override: ${identityLabel}`, { exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
}

async function editWebHostForSshCredential(recordId, credentialId, credentialIdentity, sshPort) {
  const escapedName = WEB_HOST.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = webPage.getByRole('group', { name: new RegExp(`^Host: ${escapedName};`) }).first();
  await card.waitFor({ state: 'visible', timeout: 30000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  const nameField = await field(webPage, 'Display name');
  await nameField.click(); await nameField.press('Control+A'); await nameField.fill(WEB_HOST);
  await fill(webPage, 'Hostname or IP', '127.0.0.1');
  await fill(webPage, 'Port', String(sshPort));
  await selectWebHostCredentialOverride(credentialId, credentialIdentity);
  await click(webPage, 'Save encrypted host');
  const changedCard = webPage.getByRole('group', {
    name: new RegExp(`^Host: ${escapedName};.*127\\.0\\.0\\.1:${sshPort}`),
  }).first();
  await changedCard.waitFor({ state: 'visible', timeout: 30000 });
  assertThat(validUuid(recordId), 'Web SSH Host update was not bound to the existing Host');
}

async function ensureWebHasHost(recordId) {
  const escapedName = NATIVE_HOST.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = webPage.getByRole('group', { name: new RegExp(`^Host: ${escapedName};`) }).first();
  try {
    await card.waitFor({ state: 'visible', timeout: 12000 });
  } catch (_) {
    await click(webPage, 'Sync & conflicts');
    const sync = webPage.getByRole('button', { name: 'Sync now', exact: true });
    await sync.waitFor({ state: 'visible', timeout: 20000 });
    await sync.click();
    await click(webPage, 'Hosts');
    await card.waitFor({ state: 'visible', timeout: 45000 });
  }
  assertThat(validUuid(recordId), 'Web Host pull was not associated with the signed native record');
  return card;
}

async function setUpWebOwner() {
  await enterWeb();
  await field(webPage, 'Owner email');
  await fill(webPage, 'Owner email', USERNAME);
  await fill(webPage, 'Master password · 12+ characters', PASSWORD);
  await fill(webPage, 'Confirm master password', PASSWORD);
  await fill(webPage, 'One-time bootstrap token', BOOTSTRAP_TOKEN);
  await fill(webPage, 'Device name', 'PG Web owner device');
  await fill(webPage, 'First Vault', 'PG native and Web sync Vault');
  await click(webPage, 'Create owner account');
  await waitWorkspace(webPage);
  const registerEvent = await waitFor(() => API_EVENTS.find((event) =>
    event.path === '/api/v1/auth/register' && event.status === 200 && event.authSummary),
  'Web owner registration response', 45000);
  const summary = registerEvent.authSummary;
  assertThat(validUuid(summary.accountId) && validUuid(summary.deviceId) && validUuid(summary.vaultId),
    'Web owner registration omitted account/device/Vault identifiers');
  return summary;
}

function outboxForRecord(snapshot, recordId) {
  return snapshot.pending.filter((item) => item.recordId === recordId);
}

function nativePushesFor(operationId) {
  return NATIVE_PUSHES.filter((event) => event.status === 200 &&
    event.refs.some((ref) => ref.operationId === operationId) &&
    event.responseSummary?.some((receipt) => receipt.operationId === operationId && receipt.commitSeq));
}

function webPushesFor(operationId) {
  return WEB_PUSHES.filter((event) => event.status === 200 &&
    event.refs.some((ref) => ref.operationId === operationId) &&
    event.responseSummary?.some((receipt) => receipt.operationId === operationId && receipt.commitSeq));
}

async function waitForWebOperation(recordId, operation, fromIndex, description) {
  return waitFor(() => {
    const event = WEB_PUSHES.slice(fromIndex).find((candidate) =>
      candidate.status === 200 && candidate.markerFree === true &&
      candidate.refs.some((ref) => ref.recordId === recordId && ref.operation === operation) &&
      candidate.responseSummary?.some((receipt) => receipt.commitSeq &&
        candidate.refs.some((ref) => ref.operationId === receipt.operationId &&
          ref.recordId === recordId && ref.operation === operation)));
    if (!event) return null;
    const ref = event.refs.find((candidate) => candidate.recordId === recordId && candidate.operation === operation);
    const receipt = event.responseSummary.find((candidate) => candidate.operationId === ref?.operationId);
    return ref && receipt ? { event, ref, receipt } : null;
  }, description, 60000, 200);
}

async function waitForNativePending(dbPath) {
  let current = null;
  try {
    await waitFor(() => {
      current = inspectNativeDatabase(dbPath);
      const create = current.pending.find((item) => item.header?.operation === 'create');
      const held = NATIVE_HELD_PUSHES.find((event) => event.refs.some((ref) =>
        ref.operationId === create?.opId && event.durableOutboxMatchedAtHeldPush === true));
      return Boolean(create && held && nativeHeldOperationIds.includes(create.opId));
    }, 'native signed create durable and matched at precommit push hold', 45000, 250);
  } catch (_) {
    let pendingCount = -1;
    let createCount = -1;
    let inspectionError = 'none';
    try {
      current = inspectNativeDatabase(dbPath);
      pendingCount = current.pending.length;
      createCount = current.pending.filter((item) => item.header?.operation === 'create').length;
    } catch (error) {
      inspectionError = typeof error?.message === 'string' && error.message.length <= 100
        ? error.message : (error?.name || 'unknown');
    }
    const lines = captureNativeOcr();
    const editorOpen = findOcrAnchor(lines, 'Save encrypted host') !== null ||
      findOcrAnchor(lines, 'Display name') !== null;
    const databaseExists = fs.existsSync(dbPath);
    let databaseBytes = 0;
    try { databaseBytes = fs.statSync(dbPath).size; } catch (_) {}
    throw new Error(`native Host save did not produce the held durable create ` +
      `(editorOpen=${editorOpen}; pendingCount=${pendingCount}; createCount=${createCount}; ` +
      `databaseExists=${databaseExists}; databaseBytes=${databaseBytes}; inspectionError=${inspectionError}; ` +
      `${nativeChildDiagnostics()}; ${nativeAuthStatusSummary()})`);
  }
  const item = current.pending.find((row) => row.header?.operation === 'create');
  assertThat(item && validUuid(item.opId) && validUuid(item.recordId) && validUuid(item.vaultId) &&
    validUuid(item.header?.revision_id) && validUuid(item.header?.device_id) &&
    String(item.header?.device_seq) === '1',
  'native outbox did not retain the first signed operation identity');
  assertThat(nativeHeldPushCount > 0 && nativeHeldOperationIds.filter((id) => id === item.opId).length > 0,
    'native pending operation did not encounter the held pre-commit push');
  const heldPush = NATIVE_HELD_PUSHES.find((event) =>
    event.refs.some((ref) => ref.operationId === item.opId));
  const heldRef = heldPush?.refs.find((ref) => ref.operationId === item.opId);
  assertThat(heldRef?.envelopeSha256 === item.canonicalEnvelopeSha256,
    'held push did not contain the exact durable signed native envelope');
  return { item, snapshot: current, heldPush };
}

function findSuccessfulPush(events, operationId) {
  return events.find((event) => event.status === 200 && event.markerFree &&
    event.refs.some((ref) => ref.operationId === operationId) &&
    Array.isArray(event.responseSummary) && event.responseSummary.some((receipt) =>
      receipt.operationId === operationId && receipt.commitSeq));
}

async function relaunchNativeAndCommit(dbPath, pending) {
  await killNativeHard();
  const afterKill = inspectNativeDatabase(dbPath);
  const retained = outboxForRecord(afterKill, pending.item.recordId);
  assertThat(retained.length === 1 && retained[0].opId === pending.item.opId &&
    retained[0].envelopeSha256 === pending.item.envelopeSha256 &&
    retained[0].canonicalEnvelopeSha256 === pending.item.canonicalEnvelopeSha256 &&
    retained[0].header?.revision_id === pending.item.header.revision_id,
  'native signed outbox identity changed across SIGKILL');
  nativeProcess = startNative();
  await waitFor(() => nativeWindow() !== null, 'native window after process relaunch', 45000, 300);
  stage('native relaunch: inspect startup screen and select server mode if needed');
  let state = await nativeChooseServerMode('relaunch setup');
  if (state.server) {
    stage('native relaunch: configure loopback Server URL');
    await nativeFill('Server URL', `http://127.0.0.1:${nativeServer.address().port}`);
    stage('native relaunch: submit the focused Connect action');
    nativeExec(['key', 'Return']);
    state = await waitFor(async () => {
      const observed = await nativeScreenState();
      return observed.login || observed.unlock || observed.workspace ? observed : null;
    }, 'native account screen after reconnect', 45000, 300);
  }
  if (!(await nativeScreenState()).workspace) {
    const afterConnect = await nativeScreenState();
    if (afterConnect.login) {
      stage('native relaunch: sign in to resume synchronization');
      await nativeFill('Email or username', USERNAME);
      await nativeFill('Master password', PASSWORD);
      const previousLoginCount = API_EVENTS.filter((event) => event.node === 'A' &&
        event.method === 'POST' && event.path === '/api/v1/auth/login').length;
      stage('native relaunch: tab from password visibility control to sign-in and submit');
      // Filling the password leaves focus on its visibility toggle. Advance to
      // the adjacent Sign in button before pressing Return.
      nativeExec(['key', 'Tab']);
      nativeExec(['key', 'Return']);
      try {
        await waitFor(() => API_EVENTS.filter((event) => event.node === 'A' && event.method === 'POST' &&
          event.path === '/api/v1/auth/login' && Number.isInteger(event.status)).length > previousLoginCount,
        'native relaunch login response', 20000, 100);
      } catch (_) {
        throw new Error(`native relaunch login response missing (${nativeAuthStatusSummary()})`);
      }
      const loginResponse = API_EVENTS.filter((event) => event.node === 'A' &&
        event.method === 'POST' && event.path === '/api/v1/auth/login').at(-1);
      assertThat(loginResponse?.status === 200 || loginResponse?.status === 202,
        `native relaunch login returned HTTP ${loginResponse?.status ?? 'pending'}`);
    } else if (afterConnect.unlock) {
      stage('native relaunch: unlock the existing local session');
      await nativeFill('Master password', PASSWORD);
      await nativeClick('Unlock', 'relaunch unlock action');
    }
  }
  await waitForNativeWorkspace('relaunch unlocked workspace', 60000);
  stage('native relaunch: release held push and sync the durable operation');
  nativePushReleased = true;
  await nativeSyncNow();
  await waitFor(() => Boolean(findSuccessfulPush(NATIVE_PUSHES, pending.item.opId)),
    'single successful native push receipt after relaunch', 60000, 200);
  const matchingPush = findSuccessfulPush(NATIVE_PUSHES, pending.item.opId);
  const receipt = matchingPush.responseSummary.find((item) => item.operationId === pending.item.opId);
  const retriedRef = matchingPush.refs.find((ref) => ref.operationId === pending.item.opId);
  assertThat(matchingPush.refs.filter((ref) => ref.operationId === pending.item.opId).length === 1 &&
    validUuid(matchingPush.batchId) && matchingPush.vaultId === pending.item.vaultId,
  'native retry response did not identify one exact signed batch');
  assertThat(retriedRef?.envelopeSha256 === pending.item.canonicalEnvelopeSha256,
    'native retry changed the signed envelope across SIGKILL');
  await waitFor(() => {
    const latest = inspectNativeDatabase(dbPath);
    return outboxForRecord(latest, pending.item.recordId).length === 0;
  }, 'native outbox acknowledgement after server commit', 30000, 250);
  return {
    push: matchingPush, receipt,
    identityStable: true,
    processKilledAndRelaunched: true,
    committedOnce: true,
  };
}

async function pullNativeAfterWebUpdate(recordId, expectedRevisionId, expectedCommitSeq) {
  await nativeSyncNow();
  const dbPath = nativeDatabasePath();
  let snapshot = null;
  try {
    await waitFor(() => {
      snapshot = inspectNativeDatabase(dbPath, recordId);
      const cached = snapshot.records?.filter((item) => item.recordId === recordId) || [];
      return cached.length === 1 && cached[0].revisionId === expectedRevisionId &&
        String(cached[0].commitSeq) === String(expectedCommitSeq);
    }, 'native encrypted cache to receive Web revision', 60000, 250);
  } catch (_) {
    const state = await nativeScreenState();
    const cached = snapshot?.records?.filter((item) => item.recordId === recordId) || [];
    throw new Error(`native cache did not receive the Web revision ` +
      `(matchingRevision=${cached.some((item) => item.revisionId === expectedRevisionId &&
        String(item.commitSeq) === String(expectedCommitSeq))}; hostPage=${state.hostPage}; ` +
      `${nativeSyncRequestSummary()})`);
  }
  await nativeOpenHostsPage('native Web pull');
  try {
    await waitNativeText('WebHost', 'native decrypted Web Host update', 30000);
  } catch (_) {
    const state = await nativeScreenState();
    const prefixVisible = findOcrAnchor(state.lines, 'WebHost') !== null;
    throw new Error(`native cached Web revision is not visible in the Hosts view ` +
      `(hostPage=${state.hostPage}; prefixVisible=${prefixVisible}; ` +
      `recognizedTokens=${state.lines.reduce((total, line) =>
        total + (Array.isArray(line.tokens) ? line.tokens.length : 0), 0)}; ` +
      `${nativeSyncRequestSummary()})`);
  }
  const cached = snapshot.records?.filter((item) => item.recordId === recordId) || [];
  assertThat(cached.length === 1 && cached[0].revisionId === expectedRevisionId &&
    String(cached[0].commitSeq) === String(expectedCommitSeq),
  'native encrypted cache did not converge to the exact Web revision and commit sequence');
  const duplicatePush = NATIVE_PUSHES.some((event) =>
    event.refs.some((ref) => ref.recordId === recordId && ref.operation === 'update'));
  assertThat(!duplicatePush, 'native pulled Web revision but attempted to republish it');
  return { snapshot, dbPath, duplicatePush, cached: cached[0] };
}

function scanNativePlaintext(dbPath) {
  const files = new Set([dbPath, `${dbPath}-wal`, `${dbPath}-shm`,
    ...privateNativeRoots().flatMap((root) => walkFiles(root))]);
  for (const file of files) {
    let bytes;
    try { bytes = fs.readFileSync(file); } catch (_) { continue; }
    for (const marker of persistenceMarkers()) {
      if (marker && bytes.includes(Buffer.from(marker, 'utf8'))) return false;
    }
  }
  return true;
}

async function scanWebPersistentStorage() {
  const summary = await webPage.evaluate(async (markers) => {
    const markerFreeText = (text) => markers.every((marker) => !String(text).includes(marker));
    const seen = new WeakSet();
    let visited = 0;
    let markerFree = true;
    let indexedDbMarkerFree = true;
    let localStorageMarkerFree = true;
    let cacheMarkerFree = true;
    const inspect = (value, category) => {
      visited += 1;
      if (visited > 2000000) throw new Error('storage scan bound exceeded');
      const note = (text) => {
        const clear = markerFreeText(text);
        markerFree = markerFree && clear;
        if (category === 'indexeddb') indexedDbMarkerFree = indexedDbMarkerFree && clear;
        if (category === 'local') localStorageMarkerFree = localStorageMarkerFree && clear;
        if (category === 'cache') cacheMarkerFree = cacheMarkerFree && clear;
      };
      if (typeof value === 'string') {
        note(value);
        return;
      }
      if (value == null || typeof value !== 'object') return;
      if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
        const bytes = value instanceof ArrayBuffer
          ? new Uint8Array(value)
          : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        note(new TextDecoder().decode(bytes));
        return;
      }
      if (typeof Blob !== 'undefined' && value instanceof Blob) {
        throw new Error('Blob value requires asynchronous inspection');
      }
      if (seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) {
        for (const item of value) inspect(item, category);
      } else {
        for (const [key, item] of Object.entries(value)) { inspect(key, category); inspect(item, category); }
      }
    };
    const storage = (store, category) => {
      const values = [];
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        inspect(key, category);
        const value = store.getItem(key);
        inspect(value, category);
        values.push(1);
      }
      return values.length;
    };
    if (typeof indexedDB.databases !== 'function') throw new Error('IndexedDB enumeration unavailable');
    const databaseInfos = await indexedDB.databases();
    if (!Array.isArray(databaseInfos)) throw new Error('IndexedDB listing invalid');
    const databases = databaseInfos.map((entry) => entry.name).filter(Boolean);
    let storeCount = 0;
    let rowCount = 0;
    for (const name of databases) {
      const database = await new Promise((resolve, reject) => {
        const request = indexedDB.open(name);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(new Error('IndexedDB open failed'));
        request.onblocked = () => reject(new Error('IndexedDB open blocked'));
      });
      try {
        for (const storeName of [...database.objectStoreNames]) {
          storeCount += 1;
          const transaction = database.transaction([storeName], 'readonly');
          const complete = new Promise((resolve, reject) => {
            transaction.oncomplete = resolve;
            transaction.onerror = () => reject(new Error('IndexedDB read failed'));
            transaction.onabort = () => reject(new Error('IndexedDB read aborted'));
          });
          const store = transaction.objectStore(storeName);
          const valuesPromise = new Promise((resolve, reject) => {
            const request = store.getAll();
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(new Error('IndexedDB value enumeration failed'));
          });
          const keysPromise = new Promise((resolve, reject) => {
            const request = store.getAllKeys();
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(new Error('IndexedDB key enumeration failed'));
          });
          const [values, keys] = await Promise.all([valuesPromise, keysPromise, complete]);
          if (values.length !== keys.length) throw new Error('IndexedDB key/value count mismatch');
          rowCount += values.length;
          for (const key of keys) inspect(key, 'indexeddb');
          for (const value of values) {
            if (typeof Blob !== 'undefined' && value instanceof Blob) {
              const bytes = new Uint8Array(await value.arrayBuffer());
              inspect(bytes, 'indexeddb');
            } else inspect(value, 'indexeddb');
          }
        }
      } finally { database.close(); }
    }
    const localStorageCount = storage(window.localStorage, 'local');
    const sessionStorageCount = storage(window.sessionStorage, 'local');
    if (!('caches' in window)) throw new Error('Cache API unavailable');
    const cacheNames = await caches.keys();
    let cacheEntryCount = 0;
    for (const cacheName of cacheNames) {
      inspect(cacheName, 'cache');
      const cache = await caches.open(cacheName);
      const requests = await cache.keys();
      for (const request of requests) {
        inspect(request.url, 'cache');
        const response = await cache.match(request);
        if (!response) throw new Error('Cache entry disappeared during scan');
        if (response.type === 'opaque') throw new Error('opaque cache response cannot be inspected');
        for (const [key, value] of response.headers.entries()) { inspect(key, 'cache'); inspect(value, 'cache'); }
        const bytes = new Uint8Array(await response.arrayBuffer());
        inspect(bytes, 'cache');
        cacheEntryCount += 1;
      }
    }
    return {
      markerFree,
      indexedDbMarkerFree,
      localStorageMarkerFree,
      cacheMarkerFree,
      databaseCount: databases.length,
      storeCount,
      rowCount,
      localStorageCount,
      sessionStorageCount,
      cacheCount: cacheNames.length,
      cacheEntryCount,
      visited,
    };
  }, persistenceMarkers());
  assertThat(summary.markerFree === true && summary.indexedDbMarkerFree === true &&
    summary.localStorageMarkerFree === true && summary.cacheMarkerFree === true && summary.databaseCount > 0 &&
    summary.storeCount > 0 && Number.isSafeInteger(summary.visited),
  'read-only Chromium persistence scan found plaintext or an uninspected store');
  return summary;
}

const PG_SCAN = String.raw`
import os,sys,json,re
url=os.environ.get('ATERMIUS_SYNC_PG_URL',''); schema=sys.argv[1]; vault=sys.argv[2]; markers=json.loads(sys.stdin.read())
if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',schema): raise SystemExit(4)
import psycopg
from psycopg import sql
conn=psycopg.connect(url,connect_timeout=5)
tables=['record_versions','record_heads','change_events','record_graveyard','op_receipts','batch_receipts','audit_events','blob_objects','object_references']
documents=[]
with conn.cursor() as cur:
 for table in tables:
  if table=='audit_events':
   q=sql.SQL('SELECT to_jsonb(row_data)::text FROM {}.{} AS row_data WHERE scope_type=%s AND scope_id=%s').format(sql.Identifier(schema),sql.Identifier(table))
   cur.execute(q,('vault',vault))
  else:
   q=sql.SQL('SELECT to_jsonb(row_data)::text FROM {}.{} AS row_data WHERE vault_id=%s').format(sql.Identifier(schema),sql.Identifier(table))
   cur.execute(q,(vault,))
  documents.extend(row[0] for row in cur.fetchall())
out={'markerFree':all(marker not in '\n'.join(documents) for marker in markers),'rowsScanned':len(documents)}
print(json.dumps(out,separators=(',',':')))
conn.close()
`;

function scanServerPlaintext(vaultId) {
  assertThat(typeof PG_URL === 'string' && PG_URL && validUuid(vaultId),
    'PostgreSQL privacy scan configuration was unavailable');
  const result = spawnSync('python3', ['-c', PG_SCAN, PG_SCHEMA, vaultId], {
    input: JSON.stringify(persistenceMarkers()),
    encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'read-only PostgreSQL Vault privacy scan failed');
  let summary;
  try { summary = JSON.parse(result.stdout); } catch (_) { throw new Error('PostgreSQL privacy scan summary was invalid'); }
  assertThat(summary.markerFree === true && summary.rowsScanned > 0,
    'PostgreSQL Vault ledger contained a synthetic plaintext marker');
  return true;
}

const PG_LEDGER_SUMMARY = String.raw`
import os,sys,json,re
url=os.environ.get('ATERMIUS_SYNC_PG_URL',''); schema=sys.argv[1]; vault=sys.argv[2]
if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',schema): raise SystemExit(4)
import psycopg
from psycopg import sql
tables=['record_versions','record_heads','change_events','record_graveyard','op_receipts','batch_receipts','blob_objects','object_references']
conn=psycopg.connect(url,connect_timeout=5)
summary={}
with conn.cursor() as cur:
 for table in tables:
  q=sql.SQL('SELECT count(*) FROM {}.{} WHERE vault_id=%s').format(sql.Identifier(schema),sql.Identifier(table))
  cur.execute(q,(vault,)); summary[table]=int(cur.fetchone()[0])
 q=sql.SQL('SELECT count(*) FROM {}.{} WHERE scope_type=%s AND scope_id=%s').format(sql.Identifier(schema),sql.Identifier('audit_events'))
 cur.execute(q,('vault',vault)); summary['audit_events']=int(cur.fetchone()[0])
 q=sql.SQL('SELECT COALESCE(max(commit_seq),0) FROM {}.{} WHERE vault_id=%s').format(sql.Identifier(schema),sql.Identifier('change_events'))
 cur.execute(q,(vault,)); summary['commit_seq']=int(cur.fetchone()[0])
print(json.dumps(summary,separators=(',',':')))
conn.close()
`;

function readServerVaultLedgerSummary(vaultId) {
  assertThat(typeof PG_URL === 'string' && PG_URL && validUuid(vaultId),
    'PostgreSQL Vault ledger summary configuration was unavailable');
  const result = spawnSync('python3', ['-c', PG_LEDGER_SUMMARY, PG_SCHEMA, vaultId], {
    encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only PostgreSQL Vault ledger summary failed');
  let summary;
  try { summary = JSON.parse(result.stdout); }
  catch (_) { throw new Error('PostgreSQL Vault ledger summary was invalid'); }
  assertThat(summary && typeof summary === 'object' &&
    ['record_versions', 'record_heads', 'change_events', 'record_graveyard',
      'op_receipts', 'batch_receipts', 'blob_objects', 'object_references',
      'audit_events', 'commit_seq'].every((key) => Number.isSafeInteger(summary[key])),
  'PostgreSQL Vault ledger summary omitted a required count');
  return summary;
}

function makeResult(values) {
  const nativeReceipts = nativePushesFor(values.native_op_id);
  const nativeCommitSeqs = new Set(nativeReceipts.map((event) =>
    event.responseSummary.find((receipt) => receipt.operationId === values.native_op_id)?.commitSeq).filter(Boolean));
  return {
    schema: 5,
    durable_outbox_matched_at_held_push: nativeDurableOutboxMatchedAtHeldPush,
    native_process_killed_and_relaunched: true,
    pending_operation_identity_stable: true,
    native_retry_committed_once: nativeCommitSeqs.size === 1,
    native_record_decrypted_in_web: true,
    web_record_pulled_and_decrypted_by_native: true,
    pulled_web_record_not_republished: true,
    native_db_plaintext_scan_clear: true,
    server_plaintext_scan_clear: true,
    privacy_marker_ocr_match: true,
    linux_only_scope: true,
    android_ios_windows_verified: false,
    pageErrors: PAGE_COUNTS.pageErrors,
    consoleErrors: PAGE_COUNTS.consoleErrors,
    unexpectedRequestErrors: PAGE_COUNTS.unexpectedRequestErrors,
    heldNativePushAttempts: nativeHeldPushCount,
    nativeSuccessfulPushAttempts: nativePushesFor(values.native_op_id).length,
    webSuccessfulPushAttempts: webPushesFor(values.web_op_id).length,
    pendingNativeBeforeKill: 1,
    pendingNativeAfterCommit: 0,
    ...values,
  };
}

async function cleanup() {
  nativePushReleased = true;
  try { if (nativeProcess) await killNativeHard(); } catch (_) {}
  for (const child of CHILDREN) {
    if (child === nativeProcess) continue;
    try { child.kill('SIGKILL'); } catch (_) {}
  }
  try { if (sshFixture) await sshFixture.cleanup(); } catch (_) {}
  try { setClipboard(''); } catch (_) {}
  try { if (browserContext) await browserContext.close(); } catch (_) {}
  try { if (browser) await browser.close(); } catch (_) {}
  for (const socket of PROXY_SOCKETS) { try { socket.destroy(); } catch (_) {} }
  for (const server of [nativeServer, webServer]) {
    if (!server) continue;
    await new Promise((resolve) => server.close(() => resolve()));
  }
  for (const root of privateNativeRoots()) {
    if (root && fs.existsSync(root)) {
      try { fs.rmSync(root, { recursive: true, force: true }); } catch (_) {}
    }
  }
}

async function main() {
  assertThat(process.platform === 'linux', 'runner scope must be Linux');
  for (const [name, value] of Object.entries({
    username: USERNAME, password: PASSWORD, bootstrap: BOOTSTRAP_TOKEN,
    nativeHost: NATIVE_HOST, webHost: WEB_HOST, address: HOST_ADDRESS,
    sshUsername: SSH_USERNAME, sshCredentialName: SSH_CREDENTIAL_NAME,
    home: HOME, nativeApp: NATIVE_APP, resultFile: RESULT_FILE,
  })) assertThat(typeof value === 'string' && value.length > 0, `fixture ${name} input was missing`);
  assertThat(fs.existsSync(NATIVE_APP) && fs.existsSync(path.join(WEB_ROOT, 'index.html')),
    'Linux or Web release bundle was unavailable');
  assertThat(fs.statSync(HOME).isDirectory(), 'fixture private HOME was unavailable');
  assertThat(/^[A-Za-z_][A-Za-z0-9_]*$/.test(PG_SCHEMA), 'PostgreSQL schema name was invalid');

  stage('start private keyring, same-origin Web proxy, and native node A proxy');
  ensurePrivateKeyring();
  nativeServer = http.createServer((request, response) => {
    routeApiRequest(request, response, upstreamA, 'A', true);
  });
  nativeServer.on('upgrade', (request, client, head) => proxyUpgrade(request, client, head, upstreamA));
  webServer = makeWebServer();
  const [nativeOrigin] = await Promise.all([listen(nativeServer), listen(webServer).then((origin) => {
    webOrigin = origin; return origin;
  })]);

  stage('bootstrap the sole Owner and Vault in Chromium on node B');
  browser = await chromium.launch({
    headless: false,
    ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
    env: browserEnvironment(),
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-background-networking'],
  });
  browserContext = await browser.newContext({ viewport: { width: 1600, height: 900 } });
  await browserContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: webOrigin });
  webPage = await browserContext.newPage();
  browserObservers(webPage);
  const webAccount = await setUpWebOwner();
  assertThat(API_EVENTS.filter((event) => event.path === '/api/v1/auth/register' && event.status === 200).length === 1,
    'Web Owner bootstrap registration was not a single success');

  stage('native start: launch native app for enrollment');
  startNative();
  await connectNativeProxy(nativeOrigin);
  const enrollment = await requestNativeEnrollment();
  const approvalJson = await approveNativeEnrollment(enrollment.json);
  setClipboard(approvalJson);
  await importNativeApprovalAndLogin(approvalJson);
  setClipboard('');

  stage('create native encrypted Host and hold its first push with precommit HTTP 503');
  await createNativeHost();
  const databasePath = await waitFor(() => nativeDatabasePath(), 'native SQLite database path', 30000, 200);
  const pending = await waitForNativePending(databasePath);
  const heldPush = pending.heldPush;
  assertThat(heldPush && validUuid(heldPush.batchId) && heldPush.status === 503,
    'native pending operation did not retain its exact held signed batch metadata');
  assertThat(pending.item.vaultId === webAccount.vaultId &&
    pending.item.header.device_id === enrollment.deviceId,
  'native signed outbox was not bound to the enrolled device and first Vault');
  await nativeOpenHostsPage('native initial create');
  await waitNativeText('NativeHost', 'native decrypted Host after local save', 15000);
  const nativeMarkerVisible = findOcrAnchor(captureNativeOcr(), 'NativeHost') !== null;

  stage('SIGKILL native process, prove outbox identity persists, then release held retry and verify its receipt');
  const nativeRetry = await relaunchNativeAndCommit(databasePath, pending);
  const nativeRecordId = pending.item.recordId;
  const nativeOpId = pending.item.opId;
  const nativeDeviceId = pending.item.header.device_id;
  const nativeRevisionId = pending.item.header.revision_id;
  const nativeBatchId = nativeRetry.push.batchId;
  const nativeReceipt = nativeRetry.receipt;
  assertThat(nativeRetry.push.refs[0].deviceId === nativeDeviceId &&
    nativeRetry.push.refs[0].deviceSeq === '1', 'native push did not use device sequence one');
  assertThat(nativeBatchId !== heldPush.batchId,
    'native retry did not mint a new batch identity after process restart');

  stage('Web pulls and decrypts the native Host from node B');
  const nativeCard = await ensureWebHasHost(nativeRecordId);

  stage('edit the same Host in Web and capture its signed node B batch');
  await editWebHost(nativeRecordId, NATIVE_HOST);
  await waitFor(() => webPushesForId(nativeRecordId).length > 0,
    'Web signed Host update push', 60000, 200);
  const webUpdatePush = webPushesForId(nativeRecordId).find((event) => event.status === 200 &&
    event.markerFree && event.refs.some((ref) => ref.operation === 'update' && ref.recordId === nativeRecordId) &&
    event.responseSummary?.some((receipt) => receipt.commitSeq));
  assertThat(webUpdatePush, 'Web update did not receive a successful signed sync receipt');
  const webRef = webUpdatePush.refs.find((ref) => ref.operation === 'update' && ref.recordId === nativeRecordId);
  const webReceipt = webUpdatePush.responseSummary.find((receipt) => receipt.operationId === webRef.operationId);
  assertThat(validUuid(webRef.operationId) && validUuid(webRef.revisionId) &&
    validUuid(webRef.deviceId) && webRef.deviceSeq === '1' && validUuid(webUpdatePush.batchId),
  'Web signed update omitted the expected per-device operation and batch identifiers');
  assertThat(webRef.deviceId === webAccount.deviceId && webRef.deviceId !== nativeDeviceId &&
    webUpdatePush.vaultId === webAccount.vaultId,
  'Web update was not committed by the distinct Owner Web device in the same Vault');
  assertThat(nativeReceipt.commitSeq === '1' && webReceipt.commitSeq === '2',
    'native create and Web update did not occupy the exact first two Vault commit sequences');

  stage('native pulls and decrypts the Web update without republishing it');
  const nativePull = await pullNativeAfterWebUpdate(nativeRecordId, webRef.revisionId,
    webReceipt.commitSeq);
  assertThat(nativePull.snapshot.integrity === 'ok' && nativePull.snapshot.pending.length === 0,
    'native local database was not healthy after the Web update pull');
  const webMarkerVisibleInNative = findOcrAnchor(captureNativeOcr(), 'WebHost') !== null;
  assertThat(nativeMarkerVisible && webMarkerVisibleInNative,
    `native OCR did not confirm both Host prefixes ` +
    `(nativeHostPrefix=${nativeMarkerVisible}; webHostPrefix=${webMarkerVisibleInNative})`);

  stage('start loopback public-key-only sshd and generate an in-memory P-256 client key');
  const clientIdentity = makeClientSshIdentity();
  sshPrivateKeyPem = clientIdentity.privateKeyPem;
  sshPrivateKeyMarkers = pemPrivacyMarkers(sshPrivateKeyPem);
  sshFixture = await startPublicKeySshFixture({
    bindAddress: '127.0.0.1',
    authorizedKeyLine: clientIdentity.authorizedKeyLine,
  });
  assertThat(sshFixture.authMode === 'publickey' && sshFixture.bindAddress === '127.0.0.1' &&
    Number.isInteger(sshFixture.port) && sshFixture.port > 0 &&
    /^SHA256:[A-Za-z0-9+/]+={0,2}$/.test(sshFixture.hostFingerprint) &&
    /^atermius-ws-[a-f0-9]{16}$/.test(sshFixture.username) &&
    /^atermius-key-marker-[a-f0-9]{32}$/.test(sshFixture.markerToken),
  'isolated SSH fixture did not expose its expected loopback public-key mode');
  MARKERS.push(...sshPrivateKeyMarkers, sshFixture.username, sshFixture.markerToken);
  MARKERS.push(sshFixture.hostFingerprint);

  stage('Web creates a client-side encrypted private-key Credential');
  const credentialPushStart = WEB_PUSHES.length;
  const credentialId = await createWebPrivateKeyCredential(
    SSH_CREDENTIAL_NAME, sshFixture.username, sshPrivateKeyPem);
  const credentialPush = await waitForWebOperation(
    credentialId, 'create', credentialPushStart, 'Web signed private-key Credential create');
  const credentialRef = credentialPush.ref;
  const credentialReceipt = credentialPush.receipt;
  assertThat(credentialRef.recordId === credentialId && credentialRef.deviceId === webAccount.deviceId &&
    credentialRef.deviceSeq === '2' && validUuid(credentialRef.operationId) &&
    validUuid(credentialRef.revisionId) && validUuid(credentialPush.event.batchId) &&
    credentialReceipt.commitSeq === '3',
  'Web private-key Credential create did not commit as the third Vault operation');
  clientIdentity.privateKeyPem = '';
  sshPrivateKeyPem = null;

  stage('Web links the encrypted Credential to the same Host and changes it to loopback sshd');
  const sshHostPushStart = WEB_PUSHES.length;
  const credentialIdentity = `${SSH_CREDENTIAL_NAME} · ${sshFixture.username}`;
  await click(webPage, 'Hosts');
  await editWebHostForSshCredential(
    nativeRecordId, credentialId, credentialIdentity, sshFixture.port);
  const sshHostPush = await waitForWebOperation(
    nativeRecordId, 'update', sshHostPushStart, 'Web signed SSH Host update');
  const sshHostRef = sshHostPush.ref;
  const sshHostReceipt = sshHostPush.receipt;
  assertThat(sshHostRef.deviceId === webAccount.deviceId && sshHostRef.deviceSeq === '3' &&
    validUuid(sshHostRef.operationId) && validUuid(sshHostRef.revisionId) &&
    validUuid(sshHostPush.event.batchId) && sshHostReceipt.commitSeq === '4',
  'Web SSH Host update did not bind the Credential at the fourth Vault commit');

  stage('Linux pulls exact Credential and Host heads and confirms decrypted Credential metadata');
  await nativeSyncNow();
  const nativeSshPull = await waitFor(() => {
    const snapshot = inspectNativeDatabase(databasePath,
      JSON.stringify([credentialId, nativeRecordId]));
    const records = snapshot.records || [];
    const cachedCredential = records.find((item) => item.recordId === credentialId);
    const cachedHost = records.find((item) => item.recordId === nativeRecordId);
    if (!cachedCredential || !cachedHost) return null;
    return { snapshot, cachedCredential, cachedHost };
  }, 'native encrypted Credential and SSH Host cache', 60000, 300);
  assertThat(nativeSshPull.snapshot.integrity === 'ok' && nativeSshPull.snapshot.pending.length === 0 &&
    nativeSshPull.cachedCredential.revisionId === credentialRef.revisionId &&
    String(nativeSshPull.cachedCredential.commitSeq) === credentialReceipt.commitSeq &&
    nativeSshPull.cachedHost.revisionId === sshHostRef.revisionId &&
    String(nativeSshPull.cachedHost.commitSeq) === sshHostReceipt.commitSeq,
  'native cache did not retain the exact Web Credential and Host revisions without republishing');
  await nativeOpenCredentialsPage();
  await waitNativeText('Private key stored encrypted', 'native private-key Credential metadata', 12000);
  await nativeOpenHostsPage('native Credential readback');
  await waitNativeText('WebHost', 'native decrypted SSH Host before connect', 15000);
  await nativeScrollHostsIntoView();

  stage('Linux direct SSH verifies the fixture host fingerprint and public-key authentication');
  const connectClicked = await nativeTryClick('Connect', 2500);
  if (!connectClicked) {
    const lines = captureNativeOcr();
    const hostCardVisible = findOcrAnchor(lines, 'WebHost') !== null;
    if (!hostCardVisible) {
      const state = await nativeScreenState();
      const screenshot = saveNativeWindowDiagnosticBmp('ssh-connect-timeout');
      stage(`native SSH Connect diagnostic ${nativeStateSummary(state)} ` +
        `hostMarker=false connect=false image=${screenshot}`);
      throw new Error('native SSH Host connection control was not visible');
    }
    const windowId = activateNative();
    const geometry = nativeWindowGeometry(windowId);
    assertThat(geometry.width === 1280 && geometry.height === 720,
      'native SSH Connect fallback requires its pinned 1280x720 window');
    // Tesseract misses the small Connect label even though the verified Host
    // card is fully visible. At this pinned viewport the button center is in
    // the card's rightmost action slot.
    const x = geometry.x + Math.round(geometry.width * 0.916);
    const y = geometry.y + Math.round(geometry.height * 0.887);
    nativeExec(['mousemove', String(x), String(y), 'click', '1']);
    await wait(350);
  }
  let verifiedHostKeyState;
  try {
    verifiedHostKeyState = await waitFor(() => {
      const state = nativeHostKeyAccessibility(sshFixture.hostFingerprint);
      return state.verify_dialog && state.fingerprint_node && state.fingerprint_matches && state.trust_action
        ? state : null;
    }, 'native host-key dialog with the exact fixture fingerprint in Linux accessibility', 30000, 300);
  } catch (_) {
    const lines = captureNativeOcr();
    let state = {
      verify_dialog: false,
      fingerprint_node: false,
      fingerprint_matches: false,
      trust_action: false,
      trust_clicked: false,
    };
    try { state = nativeHostKeyAccessibility(sshFixture.hostFingerprint); } catch (_) { /* keep safe diagnostics */ }
    const sshSummary = sshFixture.summary();
    const screenshot = saveNativeWindowDiagnosticBmp('host-key-timeout');
    stage(`native SSH host-key diagnostic verifyDialog=${state.verify_dialog} ` +
      `fingerprintNode=${state.fingerprint_node} fingerprint=${state.fingerprint_matches} ` +
      `trustAction=${state.trust_action} ocrDialog=${findOcrAnchor(lines, 'Verify SSH host key') !== null} ` +
      `tcp=${sshSummary.tcpConnectionsAccepted} ` +
      `serverBanner=${sshSummary.serverBannerEmitted} clientBanner=${sshSummary.clientBannerReceived} ` +
      `kex=${sshSummary.keyExchangeStarted} image=${screenshot}`);
    throw new Error('native host-key dialog with the exact fixture fingerprint was not visible');
  }
  assertThat(verifiedHostKeyState.verify_dialog && verifiedHostKeyState.fingerprint_node &&
    verifiedHostKeyState.fingerprint_matches && verifiedHostKeyState.trust_action,
  'native Linux accessibility did not verify the exact SSH host-key fingerprint and trust action');
  const trustClickState = nativeHostKeyAccessibility(sshFixture.hostFingerprint, true);
  stage(`native SSH trust gate dialog=${trustClickState.verify_dialog} ` +
    `fingerprintNode=${trustClickState.fingerprint_node} exact=${trustClickState.fingerprint_matches} ` +
    `trustAction=${trustClickState.trust_action} clicked=${trustClickState.trust_clicked}`);
  assertThat(trustClickState.verify_dialog && trustClickState.fingerprint_node &&
    trustClickState.fingerprint_matches && trustClickState.trust_action && trustClickState.trust_clicked,
  'native Linux accessibility could not safely activate the verified SSH trust action');
  stage('native SSH host key: exact fingerprint verified and accessible Trust action activated');
  await waitFor(() => {
    const summary = sshFixture.summary();
    return summary.publicKeyAccepted >= 1 && summary.shellSessions >= 1 ? summary : null;
  }, 'sshd public-key authentication and interactive shell', 60000, 250);
  const terminalGeometry = nativeWindowGeometry(activateNative());
  let terminalFocusState = nativeTerminalInputAccessibility();
  if (!terminalFocusState.input_focused) {
    nativeExec(['mousemove',
      String(terminalGeometry.x + Math.round(terminalGeometry.width * 0.64)),
      String(terminalGeometry.y + Math.round(terminalGeometry.height * 0.58)),
      'click', '1']);
    terminalFocusState = await waitFor(() => {
      const state = nativeTerminalInputAccessibility();
      return state.input_focused ? state : null;
    }, 'native terminal input to acquire keyboard focus', 5000, 200);
  }
  assertThat(terminalFocusState.input_visible && terminalFocusState.input_focused,
    'native SSH terminal input did not acquire keyboard focus');
  stage('native SSH terminal input focus verified through Linux accessibility');
  nativeExec(['mousemove',
    String(terminalGeometry.x + Math.round(terminalGeometry.width * 0.64)),
    String(terminalGeometry.y + Math.round(terminalGeometry.height * 0.58)),
    'click', '1']);
  await wait(250);
  const terminalFocusedForMarker = nativeTerminalInputAccessibility();
  assertThat(terminalFocusedForMarker.input_visible && terminalFocusedForMarker.input_focused,
    'native SSH terminal input lost focus before marker command');
  const markerPath = path.join(sshFixture.homePath, 'm');
  const markerBytes = Buffer.from(`${sshFixture.markerToken}\n`, 'utf8');
  assertThat(/^[A-Za-z0-9_./-]+$/.test(markerPath) && !fs.existsSync(markerPath),
    'SSH fixture marker path was not a fresh safe path');
  const markerCommand = `printf '%s\\n' '${sshFixture.markerToken}' > m; ` +
    `printf '%s\\n' '${sshFixture.markerToken}'`;
  setClipboard(markerCommand);
  nativeExec(['key', 'ctrl+v']);
  await wait(150);
  setClipboard('');
  stage('native SSH marker command pasted with terminal input focus confirmed');
  nativeExec(['key', 'Return']);
  try {
    await waitFor(() => {
      try { return fs.readFileSync(markerPath).equals(markerBytes); }
      catch (_) { return false; }
    }, 'unique shell marker written through native terminal', 10000, 250);
  } catch (error) {
    const markerExists = fs.existsSync(markerPath);
    const markerExact = markerExists && fs.readFileSync(markerPath).equals(markerBytes);
    const markerVisible = findOcrAnchor(captureNativeOcr(), 'atermius-key-marker') !== null;
    const focus = nativeTerminalInputAccessibility();
    const summary = sshFixture.summary();
    const screenshot = saveNativeWindowDiagnosticBmp('terminal-marker-timeout');
    stage(`native SSH marker diagnostic exists=${markerExists} exact=${markerExact} ` +
      `visible=${markerVisible} inputVisible=${focus.input_visible} ` +
      `inputFocused=${focus.input_focused} shells=${summary.shellSessions} ` +
      `screenshot=${screenshot}`);
    throw error;
  }
  await waitFor(() => findOcrAnchor(captureNativeOcr(), 'atermius-key-marker') !== null,
    'native terminal output for the unique shell marker', 10000, 300);
  const sshFixtureEvidence = sshFixture.summary();
  assertThat(sshFixtureEvidence.publicKeyAccepted >= 1 && sshFixtureEvidence.shellSessions >= 1 &&
    sshFixtureEvidence.passwordAccepted === 0 && sshFixtureEvidence.passwordRejected === 0,
  'isolated sshd did not record public-key-only terminal authentication');

  stage('verify encrypted native KnownHost trust commit from SSH acceptance');
  const knownHostPush = await waitFor(() => {
    for (const event of NATIVE_PUSHES) {
      if (event.status !== 200 || event.markerFree !== true || !Array.isArray(event.responseSummary)) continue;
      const ref = event.refs.find((item) => item.operation === 'create' &&
        item.deviceId === nativeDeviceId && item.deviceSeq === '2');
      const receipt = event.responseSummary.find((item) => item.operationId === ref?.operationId &&
        item.commitSeq === '5');
      if (ref && receipt) return { event, ref, receipt };
    }
    return null;
  }, 'native encrypted KnownHost trust create at commit sequence five', 30000, 200);
  const knownHostRef = knownHostPush.ref;
  const knownHostReceipt = knownHostPush.receipt;
  assertThat(validUuid(knownHostRef.recordId) && validUuid(knownHostRef.operationId) &&
    validUuid(knownHostRef.revisionId) && validUuid(knownHostPush.event.batchId) &&
    knownHostRef.operation === 'create' && knownHostRef.deviceSeq === '2' &&
    nativePushesFor(knownHostRef.operationId).length === 1,
  'SSH trust did not commit exactly one native-signed KnownHost create');
  EXTRA_PERSISTENCE_MARKERS.push(sshFixture.hostFingerprint);

  const sftpAcceptance = await runNativeSftpAcceptance(webAccount.vaultId);

  stage('Web creates a client-encrypted free-form Snippet without running it');
  assertThat(typeof SNIPPET_TITLE === 'string' && SNIPPET_TITLE &&
    typeof SNIPPET_BODY_MARKER === 'string' && SNIPPET_BODY_MARKER &&
    typeof SNIPPET_TAG === 'string' && SNIPPET_TAG &&
    typeof SNIPPET_UPDATED_TITLE === 'string' && SNIPPET_UPDATED_TITLE &&
    typeof SNIPPET_UPDATED_BODY_MARKER === 'string' && SNIPPET_UPDATED_BODY_MARKER &&
    typeof SNIPPET_UPDATED_TAG === 'string' && SNIPPET_UPDATED_TAG,
  'Snippet privacy markers were not configured');
  const snippetBody = `printf '%s\\n' '${SNIPPET_BODY_MARKER}'`;
  const updatedSnippetBody = `printf '%s\\n' '${SNIPPET_UPDATED_BODY_MARKER}'`;
  MARKERS.push(SNIPPET_TITLE, SNIPPET_BODY_MARKER, SNIPPET_TAG,
    SNIPPET_UPDATED_TITLE, SNIPPET_UPDATED_BODY_MARKER, SNIPPET_UPDATED_TAG);
  EXTRA_PERSISTENCE_MARKERS.push(SNIPPET_TITLE, SNIPPET_BODY_MARKER, SNIPPET_TAG,
    SNIPPET_UPDATED_TITLE, SNIPPET_UPDATED_BODY_MARKER, SNIPPET_UPDATED_TAG);
  stage('Web opens the Snippets workspace');
  await click(webPage, 'Snippets');
  await visibleText(webPage, 'Command snippets');
  stage('Web opens the new Snippet editor');
  await click(webPage, 'New snippet');
  await visibleText(webPage, 'New command snippet');
  stage('Web fills the Snippet title');
  await fill(webPage, 'Title', SNIPPET_TITLE);
  stage('Web fills the inert free-form Snippet body');
  await fill(webPage, 'Script body', snippetBody);
  stage('Web fills the Snippet tag');
  await fill(webPage, 'Tags, separated by commas', SNIPPET_TAG);
  const snippetPushStart = WEB_PUSHES.length;
  stage('Web saves the encrypted Snippet');
  await click(webPage, 'Save snippet');
  stage('Web verifies the saved Snippet title');
  await waitForSemanticText(webPage, SNIPPET_TITLE, 30000);
  const committedSnippetPush = await waitFor(() => {
    const candidate = WEB_PUSHES.slice(snippetPushStart).find((event) =>
      event.status === 200 && event.markerFree === true &&
      event.refs.some((ref) => ref.operation === 'create' && ref.recordId &&
        event.responseSummary?.some((receipt) => receipt.commitSeq &&
          event.refs.some((item) => item.operationId === receipt.operationId &&
            item.operation === 'create' && item.recordId === ref.recordId))));
    if (!candidate) return null;
    const ref = candidate.refs.find((item) => item.operation === 'create');
    const receipt = candidate.responseSummary.find((item) => item.operationId === ref?.operationId);
    return ref && receipt ? { event: candidate, ref, receipt } : null;
  }, 'Web signed encrypted Snippet create', 60000, 200);
  const snippetRef = committedSnippetPush.ref;
  const snippetReceipt = committedSnippetPush.receipt;
  stage(`Web Snippet receipt identity validRecord=${validUuid(snippetRef.recordId)} ` +
    `validOperation=${validUuid(snippetRef.operationId)} validRevision=${validUuid(snippetRef.revisionId)} ` +
    `validDevice=${validUuid(snippetRef.deviceId)} deviceMatchesOwner=${snippetRef.deviceId === webAccount.deviceId} ` +
    `deviceSeq=${snippetRef.deviceSeq} validBatch=${validUuid(committedSnippetPush.event.batchId)} ` +
    `vaultMatches=${committedSnippetPush.event.vaultId === webAccount.vaultId} ` +
    `commitSeq=${snippetReceipt.commitSeq}`);
  assertThat(validUuid(snippetRef.recordId) && validUuid(snippetRef.operationId) &&
    validUuid(snippetRef.revisionId) && validUuid(snippetRef.deviceId) &&
    validUuid(committedSnippetPush.event.batchId) && snippetRef.deviceSeq === '4' &&
    snippetRef.deviceId === webAccount.deviceId &&
    committedSnippetPush.event.vaultId === webAccount.vaultId &&
    snippetReceipt.commitSeq === '6',
  'Web Snippet create did not commit at the exact Web device and Vault sequence');
  const snippetPushEvents = webPushesFor(snippetRef.operationId);
  assertThat(snippetPushEvents.length === 1 &&
    snippetPushEvents[0].refs.filter((ref) => ref.operationId === snippetRef.operationId).length === 1 &&
    snippetPushEvents[0].refs.find((ref) => ref.operationId === snippetRef.operationId)
      ?.envelopeSha256 === snippetRef.envelopeSha256,
  'Web Snippet operation was not submitted exactly once with a stable encrypted envelope');

  stage('Linux pulls the exact Web Snippet envelope and decrypts its title and body');
  await nativeSyncNow();
  const nativeSnippetPull = await waitFor(() => {
    const snapshot = inspectNativeDatabase(databasePath, JSON.stringify([snippetRef.recordId]));
    const cached = snapshot.records?.find((item) => item.recordId === snippetRef.recordId);
    if (!cached || cached.revisionId !== snippetRef.revisionId ||
        String(cached.commitSeq) !== snippetReceipt.commitSeq) return null;
    return { snapshot, cached };
  }, 'native encrypted Snippet cache revision', 60000, 300);
  assertThat(nativeSnippetPull.snapshot.integrity === 'ok' &&
    nativeSnippetPull.snapshot.pending.length === 0 &&
    nativeSnippetPull.cached.canonicalEnvelopeSha256 === snippetRef.envelopeSha256,
  'native cache did not retain the exact Web-signed Snippet envelope');
  await nativeOpenSnippetsPage();
  stage('Linux opens the received Snippet editor without saving or executing it');
  const snippetEditButton = await nativeSnippetEditAccessibility(SNIPPET_TITLE, true);
  stage(`Linux Snippet Edit accessibility available=${snippetEditButton.available} ` +
    `card=${snippetEditButton.snippet_card_visible} actions=${snippetEditButton.card_action_count} ` +
    `edit=${snippetEditButton.edit_button_visible} activated=${snippetEditButton.edit_button_activated}`);
  assertThat(snippetEditButton.snippet_card_visible && snippetEditButton.edit_button_visible &&
    snippetEditButton.edit_button_activated,
  'native Snippet card did not expose its scoped Edit action');
  await waitNativeText('Edit command snippet', 'native received Snippet editor', 15000);
  const nativeSnippetTitleField = nativeTextFieldAccessibility('Title', SNIPPET_TITLE);
  const nativeSnippetBodyField = nativeTextFieldAccessibility('Script body', snippetBody);
  const nativeSnippetTagField = nativeTextFieldAccessibility('Tags, separated by commas', SNIPPET_TAG);
  stage(`Linux Snippet decrypted fields title=${nativeSnippetTitleField.value_matches} ` +
    `body=${nativeSnippetBodyField.value_matches} tag=${nativeSnippetTagField.value_matches}`);
  assertThat(nativeSnippetTitleField.field_visible && nativeSnippetTitleField.value_matches &&
    nativeSnippetBodyField.field_visible && nativeSnippetBodyField.value_matches &&
    nativeSnippetTagField.field_visible && nativeSnippetTagField.value_matches,
  'native Snippet editor did not decrypt the exact title, body, and tag');
  nativeExec(['key', 'Escape']);
  await waitFor(async () => (await nativeScreenState()).hostPage ||
    findOcrAnchor(captureNativeOcr(), 'Command snippets') !== null,
  'native Snippet editor close', 10000, 250);

  stage('Web updates the same Snippet through its editor');
  await waitForSemanticText(webPage, 'Command snippets', 15000);
  const webSnippetCard = webPage.getByRole('group', {
    name: `Snippet: ${SNIPPET_TITLE}`,
    exact: true,
  });
  await webSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
  const webSnippetEditButton = webSnippetCard.getByRole('button', { name: 'Edit', exact: true });
  await webSnippetEditButton.waitFor({ state: 'visible', timeout: 10000 });
  assertThat(await webSnippetCard.count() === 1 && await webSnippetEditButton.count() === 1,
    'Web did not expose exactly one Edit action for the synced Snippet');
  await webSnippetEditButton.click();
  await waitForSemanticText(webPage, 'Edit command snippet', 15000);
  stage('Web changes Snippet title, inert script body, and tag');
  await fill(webPage, 'Title', SNIPPET_UPDATED_TITLE);
  await fill(webPage, 'Script body', updatedSnippetBody);
  await fill(webPage, 'Tags, separated by commas', SNIPPET_UPDATED_TAG);
  const snippetUpdatePushStart = WEB_PUSHES.length;
  stage('Web saves the updated encrypted Snippet revision');
  await click(webPage, 'Save snippet');
  await waitForSemanticText(webPage, SNIPPET_UPDATED_TITLE, 30000);
  const committedSnippetUpdate = await waitForWebOperation(
    snippetRef.recordId, 'update', snippetUpdatePushStart, 'Web signed Snippet update');
  const snippetUpdateRef = committedSnippetUpdate.ref;
  const snippetUpdateReceipt = committedSnippetUpdate.receipt;
  stage(`Web Snippet update receipt validRecord=${validUuid(snippetUpdateRef.recordId)} ` +
    `validOperation=${validUuid(snippetUpdateRef.operationId)} ` +
    `validRevision=${validUuid(snippetUpdateRef.revisionId)} ` +
    `deviceMatchesOwner=${snippetUpdateRef.deviceId === webAccount.deviceId} ` +
    `deviceSeq=${snippetUpdateRef.deviceSeq} commitSeq=${snippetUpdateReceipt.commitSeq}`);
  assertThat(snippetUpdateRef.operation === 'update' &&
    snippetUpdateRef.recordId === snippetRef.recordId &&
    snippetUpdateRef.operationId !== snippetRef.operationId &&
    snippetUpdateRef.revisionId !== snippetRef.revisionId &&
    snippetUpdateRef.deviceId === webAccount.deviceId &&
    snippetUpdateRef.deviceSeq === '5' &&
    validUuid(committedSnippetUpdate.event.batchId) &&
    committedSnippetUpdate.event.vaultId === webAccount.vaultId &&
    snippetUpdateReceipt.commitSeq === '7',
  'Web Snippet update did not commit the exact next revision at Web sequence 5 / Vault sequence 7');
  const snippetUpdatePushEvents = webPushesFor(snippetUpdateRef.operationId);
  assertThat(snippetUpdatePushEvents.length === 1 &&
    snippetUpdatePushEvents[0].refs.filter((ref) => ref.operationId === snippetUpdateRef.operationId).length === 1 &&
    snippetUpdatePushEvents[0].refs.find((ref) => ref.operationId === snippetUpdateRef.operationId)
      ?.envelopeSha256 === snippetUpdateRef.envelopeSha256 &&
    nativePushesFor(snippetUpdateRef.operationId).length === 0,
  'Web Snippet update was not pushed exactly once or was republished by native Linux');

  stage('Linux pulls the exact Web Snippet update without republishing it');
  await nativeSyncNow();
  const nativeSnippetUpdatePull = await waitFor(() => {
    const snapshot = inspectNativeDatabase(databasePath, JSON.stringify([snippetRef.recordId]));
    const cached = snapshot.records?.find((item) => item.recordId === snippetRef.recordId);
    if (!cached || cached.revisionId !== snippetUpdateRef.revisionId ||
        String(cached.commitSeq) !== snippetUpdateReceipt.commitSeq) return null;
    return { snapshot, cached };
  }, 'native encrypted Snippet update cache revision', 60000, 300);
  assertThat(nativeSnippetUpdatePull.snapshot.integrity === 'ok' &&
    nativeSnippetUpdatePull.snapshot.pending.length === 0 &&
    nativeSnippetUpdatePull.cached.canonicalEnvelopeSha256 === snippetUpdateRef.envelopeSha256,
  'native cache did not retain the exact updated Web-signed Snippet envelope');
  await nativeOpenSnippetsPage();
  stage('Linux opens and verifies the updated Snippet fields');
  const updatedSnippetEditButton = await nativeSnippetEditAccessibility(SNIPPET_UPDATED_TITLE, true);
  assertThat(updatedSnippetEditButton.snippet_card_visible &&
    updatedSnippetEditButton.edit_button_visible && updatedSnippetEditButton.edit_button_activated,
  'native updated Snippet card did not expose its scoped Edit action');
  await waitNativeText('Edit command snippet', 'native updated Snippet editor', 15000);
  const nativeUpdatedSnippetTitleField = nativeTextFieldAccessibility('Title', SNIPPET_UPDATED_TITLE);
  const nativeUpdatedSnippetBodyField = nativeTextFieldAccessibility('Script body', updatedSnippetBody);
  const nativeUpdatedSnippetTagField = nativeTextFieldAccessibility(
    'Tags, separated by commas', SNIPPET_UPDATED_TAG);
  stage(`Linux updated Snippet decrypted fields title=${nativeUpdatedSnippetTitleField.value_matches} ` +
    `body=${nativeUpdatedSnippetBodyField.value_matches} tag=${nativeUpdatedSnippetTagField.value_matches}`);
  assertThat(nativeUpdatedSnippetTitleField.field_visible && nativeUpdatedSnippetTitleField.value_matches &&
    nativeUpdatedSnippetBodyField.field_visible && nativeUpdatedSnippetBodyField.value_matches &&
    nativeUpdatedSnippetTagField.field_visible && nativeUpdatedSnippetTagField.value_matches,
  'native Snippet editor did not decrypt the exact updated title, body, and tag');
  nativeExec(['key', 'Escape']);
  await waitFor(async () => (await nativeScreenState()).hostPage ||
    findOcrAnchor(captureNativeOcr(), 'Command snippets') !== null,
  'native updated Snippet editor close', 10000, 250);

  assertThat(typeof SNIPPET_NATIVE_UPDATED_TITLE === 'string' && SNIPPET_NATIVE_UPDATED_TITLE &&
    typeof SNIPPET_NATIVE_UPDATED_BODY_MARKER === 'string' && SNIPPET_NATIVE_UPDATED_BODY_MARKER &&
    typeof SNIPPET_NATIVE_UPDATED_TAG === 'string' && SNIPPET_NATIVE_UPDATED_TAG,
  'native Snippet update privacy markers were not configured');
  const nativeUpdatedSnippetBody = `printf '%s\\n' '${SNIPPET_NATIVE_UPDATED_BODY_MARKER}'`;
  MARKERS.push(SNIPPET_NATIVE_UPDATED_TITLE, SNIPPET_NATIVE_UPDATED_BODY_MARKER,
    SNIPPET_NATIVE_UPDATED_TAG);
  EXTRA_PERSISTENCE_MARKERS.push(SNIPPET_NATIVE_UPDATED_TITLE, SNIPPET_NATIVE_UPDATED_BODY_MARKER,
    SNIPPET_NATIVE_UPDATED_TAG);

  stage('Linux edits the synced Snippet into a third signed revision');
  const nativeEditButton = await nativeSnippetEditAccessibility(SNIPPET_UPDATED_TITLE, true);
  assertThat(nativeEditButton.snippet_card_visible && nativeEditButton.edit_button_visible &&
    nativeEditButton.edit_button_activated,
  'native updated Snippet card did not expose its scoped Edit action for a second edit');
  await waitNativeText('Edit command snippet', 'native Snippet second editor', 15000);
  await nativeFill('Title', SNIPPET_NATIVE_UPDATED_TITLE);
  await nativeFill('Script body', nativeUpdatedSnippetBody);
  await nativeFill('Tags, separated by commas', SNIPPET_NATIVE_UPDATED_TAG);
  const nativeSnippetSecondTitleField = nativeTextFieldAccessibility('Title', SNIPPET_NATIVE_UPDATED_TITLE);
  const nativeSnippetSecondBodyField = nativeTextFieldAccessibility('Script body', nativeUpdatedSnippetBody);
  const nativeSnippetSecondTagField = nativeTextFieldAccessibility(
    'Tags, separated by commas', SNIPPET_NATIVE_UPDATED_TAG);
  stage(`Linux edited Snippet fields title=${nativeSnippetSecondTitleField.value_matches} ` +
    `body=${nativeSnippetSecondBodyField.value_matches} tag=${nativeSnippetSecondTagField.value_matches}`);
  assertThat(nativeSnippetSecondTitleField.field_visible && nativeSnippetSecondTitleField.value_matches &&
    nativeSnippetSecondBodyField.field_visible && nativeSnippetSecondBodyField.value_matches &&
    nativeSnippetSecondTagField.field_visible && nativeSnippetSecondTagField.value_matches,
  'native Snippet second edit did not retain the exact title, body, and tag values');
  const nativeSnippetUpdatePushStart = NATIVE_PUSHES.length;
  let savedNativeSnippetByOcr = await nativeTryClick('Save snippet', 2500);
  if (!savedNativeSnippetByOcr) {
    // nativeFill leaves focus on Cancel; the following Tab selects Save.
    nativeExec(['key', 'Tab']);
    nativeExec(['key', 'Return']);
  }
  await waitFor(async () => (await nativeScreenState()).hostPage ||
    findOcrAnchor(captureNativeOcr(), 'Command snippets') !== null,
  'native Snippet second edit save', 15000, 250);
  stage(`Linux saved third Snippet revision via OCR=${savedNativeSnippetByOcr}`);
  await nativeSyncNow();
  const committedNativeSnippetUpdate = await waitFor(() => {
    for (const event of NATIVE_PUSHES.slice(nativeSnippetUpdatePushStart)) {
      if (event.status !== 200 || event.markerFree !== true || !Array.isArray(event.responseSummary)) continue;
      const ref = event.refs.find((item) => item.operation === 'update' &&
        item.recordId === snippetRef.recordId && item.deviceId === nativeDeviceId && item.deviceSeq === '3');
      const receipt = event.responseSummary.find((item) => item.operationId === ref?.operationId &&
        item.commitSeq === '8');
      if (ref && receipt) return { event, ref, receipt };
    }
    return null;
  }, 'native signed Snippet update at device sequence three / Vault commit eight', 60000, 200);
  const nativeSnippetUpdateRef = committedNativeSnippetUpdate.ref;
  const nativeSnippetUpdateReceipt = committedNativeSnippetUpdate.receipt;
  assertThat(validUuid(nativeSnippetUpdateRef.operationId) &&
    validUuid(nativeSnippetUpdateRef.revisionId) &&
    nativeSnippetUpdateRef.baseRevisionId === snippetUpdateRef.revisionId &&
    nativeSnippetUpdateRef.deviceSeq === '3' &&
    validUuid(committedNativeSnippetUpdate.event.batchId) &&
    committedNativeSnippetUpdate.event.vaultId === webAccount.vaultId &&
    nativeSnippetUpdateReceipt.commitSeq === '8' &&
    nativePushesFor(nativeSnippetUpdateRef.operationId).length === 1,
  'native Snippet update did not commit exactly once against the Web revision at Vault commit eight');
  const nativeSnippetLatestPull = await waitFor(() => {
    const snapshot = inspectNativeDatabase(databasePath, JSON.stringify([snippetRef.recordId]));
    const cached = snapshot.records?.find((item) => item.recordId === snippetRef.recordId);
    if (!cached || cached.revisionId !== nativeSnippetUpdateRef.revisionId ||
        String(cached.commitSeq) !== nativeSnippetUpdateReceipt.commitSeq) return null;
    return { snapshot, cached };
  }, 'native encrypted Snippet third-revision cache', 30000, 250);
  assertThat(nativeSnippetLatestPull.snapshot.integrity === 'ok' &&
    nativeSnippetLatestPull.snapshot.pending.length === 0 &&
    nativeSnippetLatestPull.cached.canonicalEnvelopeSha256 === nativeSnippetUpdateRef.envelopeSha256,
  'native cache did not retain the exact signed Snippet update envelope after commit');

  stage('Web pulls and decrypts the Linux-edited Snippet revision');
  const webNativeUpdatePullStart = API_EVENTS.length;
  const webNativeUpdatePushStart = WEB_PUSHES.length;
  await click(webPage, 'Sync & conflicts');
  await click(webPage, 'Sync now');
  const webNativeUpdateChange = await waitFor(() => API_EVENTS.slice(webNativeUpdatePullStart).find((event) =>
    event.node === 'B' && event.method === 'GET' && /\/changes$/.test(event.path) &&
    event.status === 200 && event.markerFree === true &&
    event.refs.some((ref) => ref.recordId === snippetRef.recordId &&
      ref.revisionId === nativeSnippetUpdateRef.revisionId && ref.commitSeq === '8' &&
      ref.envelopeSha256 === nativeSnippetUpdateRef.envelopeSha256)),
  'Web sync response carried the exact native Snippet revision and envelope', 60000, 200);
  assertThat(webNativeUpdateChange.refs.filter((ref) => ref.recordId === snippetRef.recordId &&
    ref.revisionId === nativeSnippetUpdateRef.revisionId && ref.commitSeq === '8').length === 1,
  'Web changes response did not carry exactly one copy of the native Snippet revision');
  await click(webPage, 'Snippets');
  await waitForSemanticText(webPage, SNIPPET_NATIVE_UPDATED_TITLE, 30000);
  const webNativeUpdatedSnippetCard = webPage.getByRole('group', {
    name: `Snippet: ${SNIPPET_NATIVE_UPDATED_TITLE}`,
    exact: true,
  });
  await webNativeUpdatedSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
  const webNativeSnippetCardText = await webNativeUpdatedSnippetCard.evaluate((element) =>
    element.innerText || element.textContent || '');
  const webNativeSnippetCardBodyVerified = webNativeSnippetCardText.includes(nativeUpdatedSnippetBody);
  const webNativeSnippetCardTagVerified = webNativeSnippetCardText.includes(SNIPPET_NATIVE_UPDATED_TAG);
  stage(`Web native Snippet card fields body=${webNativeSnippetCardBodyVerified} ` +
    `tag=${webNativeSnippetCardTagVerified}`);
  const webNativeUpdatedSnippetEdit = webNativeUpdatedSnippetCard.getByRole('button', {
    name: 'Edit', exact: true,
  });
  await webNativeUpdatedSnippetEdit.click();
  await waitForSemanticText(webPage, 'Edit command snippet', 15000);
  const webNativeTitleInput = await field(webPage, 'Title');
  const webNativeBodyInput = await field(webPage, 'Script body');
  const webNativeTagInput = await field(webPage, 'Tags, separated by commas');
  // Flutter Web attaches its live input overlay on focus. Focus each field
  // before reading so this check observes the active decrypted editor value.
  await webNativeTitleInput.click();
  const webNativeSnippetFieldChecks = {
    title: (await webNativeTitleInput.inputValue()) === SNIPPET_NATIVE_UPDATED_TITLE,
    body: false,
    tag: false,
  };
  await webNativeBodyInput.click();
  webNativeSnippetFieldChecks.body =
    (await webNativeBodyInput.inputValue()) === nativeUpdatedSnippetBody;
  await webNativeTagInput.click();
  webNativeSnippetFieldChecks.tag =
    (await webNativeTagInput.inputValue()) === SNIPPET_NATIVE_UPDATED_TAG;
  const webNativeDomFieldMatrix = await webPage.evaluate((checks) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
    };
    const inspect = (selector, expected, previous) => {
      const candidates = [...document.querySelectorAll(selector)];
      const onScreen = candidates.filter(visible);
      return {
        count: candidates.length,
        visible: onScreen.length,
        expectedVisible: onScreen.filter((element) => element.value === expected).length,
        trimmedExpectedVisible: onScreen.filter((element) => element.value.trim() === expected).length,
        previousVisible: onScreen.filter((element) => element.value === previous).length,
      };
    };
    return {
      title: inspect('input[aria-label*="Title"],textarea[aria-label*="Title"]',
        checks.titleExpected, checks.titlePrevious),
      body: inspect('input[aria-label*="Script body"],textarea[aria-label*="Script body"]',
        checks.bodyExpected, checks.bodyPrevious),
      tag: inspect('input[aria-label*="Tags, separated by commas"],textarea[aria-label*="Tags, separated by commas"]',
        checks.tagExpected, checks.tagPrevious),
    };
  }, {
    titleExpected: SNIPPET_NATIVE_UPDATED_TITLE,
    titlePrevious: SNIPPET_UPDATED_TITLE,
    bodyExpected: nativeUpdatedSnippetBody,
    bodyPrevious: updatedSnippetBody,
    tagExpected: SNIPPET_NATIVE_UPDATED_TAG,
    tagPrevious: SNIPPET_UPDATED_TAG,
  });
  stage(`Web native Snippet decrypted fields title=${webNativeSnippetFieldChecks.title} ` +
    `body=${webNativeSnippetFieldChecks.body} tag=${webNativeSnippetFieldChecks.tag} ` +
    `domTitle=${webNativeDomFieldMatrix.title.count}/${webNativeDomFieldMatrix.title.visible}/` +
    `${webNativeDomFieldMatrix.title.expectedVisible}/${webNativeDomFieldMatrix.title.trimmedExpectedVisible}/` +
    `${webNativeDomFieldMatrix.title.previousVisible} ` +
    `domBody=${webNativeDomFieldMatrix.body.count}/${webNativeDomFieldMatrix.body.visible}/` +
    `${webNativeDomFieldMatrix.body.expectedVisible}/${webNativeDomFieldMatrix.body.trimmedExpectedVisible}/` +
    `${webNativeDomFieldMatrix.body.previousVisible} ` +
    `domTag=${webNativeDomFieldMatrix.tag.count}/${webNativeDomFieldMatrix.tag.visible}/` +
    `${webNativeDomFieldMatrix.tag.expectedVisible}/${webNativeDomFieldMatrix.tag.trimmedExpectedVisible}/` +
    `${webNativeDomFieldMatrix.tag.previousVisible}`);
  const waitForExactWebInput = async (locator, expected, description) => {
    await locator.click();
    try {
      await waitFor(async () => (await locator.inputValue()) === expected ? true : null,
        description, 3000, 100);
      return true;
    } catch (_) { return false; }
  };
  const webNativeSettledFieldChecks = {
    title: await waitForExactWebInput(webNativeTitleInput, SNIPPET_NATIVE_UPDATED_TITLE,
      'settled Web native Snippet title input'),
    body: await waitForExactWebInput(webNativeBodyInput, nativeUpdatedSnippetBody,
      'settled Web native Snippet body input'),
    tag: await waitForExactWebInput(webNativeTagInput, SNIPPET_NATIVE_UPDATED_TAG,
      'settled Web native Snippet tag input'),
  };
  stage(`Web native Snippet settled fields title=${webNativeSettledFieldChecks.title} ` +
    `body=${webNativeSettledFieldChecks.body} tag=${webNativeSettledFieldChecks.tag}`);
  const webNativeSnippetFieldsVerified = Object.values(webNativeSettledFieldChecks).every(Boolean);
  assertThat(webNativeSnippetFieldsVerified,
    'Web did not decrypt the exact native-edited Snippet title, body, and tag');
  await click(webPage, 'Cancel');
  await waitForSemanticText(webPage, SNIPPET_NATIVE_UPDATED_TITLE, 15000);
  await wait(1200);
  const webRepublishedNativeSnippet = WEB_PUSHES.slice(webNativeUpdatePushStart).some((event) =>
    event.refs.some((ref) => ref.recordId === snippetRef.recordId && ref.operation === 'update'));
  assertThat(!webRepublishedNativeSnippet,
    'Web created or republished a Snippet update after pulling the native-signed revision');

  await killNativeHard();
  const finalNativeSnapshot = inspectNativeDatabase(databasePath, nativeRecordId);
  assertThat(finalNativeSnapshot.pending.length === 0 && finalNativeSnapshot.records?.length === 1 &&
    finalNativeSnapshot.records[0].revisionId === sshHostRef.revisionId &&
    String(finalNativeSnapshot.records[0].commitSeq) === String(sshHostReceipt.commitSeq),
  'native durable cache changed or retained pending work after the SSH Credential and Host pull');
  const finalSshRecords = inspectNativeDatabaseRecords(databasePath,
    [credentialId, nativeRecordId, knownHostRef.recordId, snippetRef.recordId]);
  assertThat(finalSshRecords.length === 4 &&
    finalSshRecords.some((item) => item.recordId === credentialId &&
      item.revisionId === credentialRef.revisionId && String(item.commitSeq) === credentialReceipt.commitSeq) &&
    finalSshRecords.some((item) => item.recordId === nativeRecordId &&
      item.revisionId === sshHostRef.revisionId && String(item.commitSeq) === sshHostReceipt.commitSeq) &&
    finalSshRecords.some((item) => item.recordId === knownHostRef.recordId &&
      item.revisionId === knownHostRef.revisionId && String(item.commitSeq) === knownHostReceipt.commitSeq &&
      item.canonicalEnvelopeSha256 === knownHostRef.envelopeSha256) &&
    finalSshRecords.some((item) => item.recordId === snippetRef.recordId &&
      item.revisionId === nativeSnippetUpdateRef.revisionId &&
      String(item.commitSeq) === nativeSnippetUpdateReceipt.commitSeq &&
      item.canonicalEnvelopeSha256 === nativeSnippetUpdateRef.envelopeSha256),
  'native durable SQLite cache did not retain the exact Credential, Host, KnownHost, and Snippet heads');

  stage('scan native files, Chromium persistence, and PostgreSQL Vault ledger for plaintext');
  const webStorageScan = await scanWebPersistentStorage();
  const localPrivacyClear = scanNativePlaintext(databasePath);
  const serverPrivacyClear = scanServerPlaintext(webAccount.vaultId);
  assertThat(localPrivacyClear && serverPrivacyClear && API_EVENTS.filter((event) =>
    /\/sync\/(?:push|changes)$/.test(event.path)).every((event) => event.markerFree === true),
    'encrypted Host/Credential/Snippet storage or sync push/pull envelopes exposed a plaintext marker');
  assertThat(PAGE_COUNTS.pageErrors === 0 && PAGE_COUNTS.consoleErrors === 0 &&
    PAGE_COUNTS.unexpectedRequestErrors === 0,
  'Chromium observed a page, console, or unexpected network error');

  stage('verify SSH fixture account, home, and sshd cleanup before writing acceptance evidence');
  await sshFixture.cleanup();
  const sshFixtureStatus = sshFixture.status();
  const sshFixtureStoppedSummary = sshFixture.summary();
  const sshFixtureCleanupVerified = sshFixtureStatus.closed === true &&
    sshFixtureStatus.cleaned === true && !fs.existsSync(sshFixture.homePath) &&
    !fs.existsSync(sshFixture.tempRoot) && sshFixtureStoppedSummary.running === false &&
    sshFixtureStoppedSummary.stopped === true && sshFixtureStoppedSummary.tcpConnectionsOpen === 0;
  assertThat(sshFixtureCleanupVerified,
    'isolated SSH fixture account, home, host keys, or listener remained after teardown');

  const result = makeResult({
    account_id: webAccount.accountId,
    vault_id: webAccount.vaultId,
    record_id: nativeRecordId,
    native_device_id: nativeDeviceId,
    web_device_id: webRef.deviceId,
    native_op_id: nativeOpId,
    web_op_id: webRef.operationId,
    credential_record_id: credentialId,
    credential_op_id: credentialRef.operationId,
    credential_batch_id: credentialPush.event.batchId,
    credential_revision_id: credentialRef.revisionId,
    credential_commit_seq: credentialReceipt.commitSeq,
    ssh_host_op_id: sshHostRef.operationId,
    ssh_host_batch_id: sshHostPush.event.batchId,
    ssh_host_revision_id: sshHostRef.revisionId,
    ssh_host_commit_seq: sshHostReceipt.commitSeq,
    known_host_record_id: knownHostRef.recordId,
    known_host_op_id: knownHostRef.operationId,
    known_host_batch_id: knownHostPush.event.batchId,
    known_host_revision_id: knownHostRef.revisionId,
    known_host_commit_seq: knownHostReceipt.commitSeq,
    known_host_device_seq: knownHostRef.deviceSeq,
    known_host_envelope_sha256: knownHostRef.envelopeSha256,
    snippet_record_id: snippetRef.recordId,
    snippet_op_id: snippetRef.operationId,
    snippet_batch_id: committedSnippetPush.event.batchId,
    snippet_revision_id: snippetRef.revisionId,
    snippet_commit_seq: snippetReceipt.commitSeq,
    snippet_device_seq: snippetRef.deviceSeq,
    snippet_envelope_sha256: snippetRef.envelopeSha256,
    snippet_successful_push_attempts: snippetPushEvents.length,
    native_cached_snippet_revision_id: nativeSnippetPull.cached.revisionId,
    native_cached_snippet_commit_seq: String(nativeSnippetPull.cached.commitSeq),
    native_cached_snippet_canonical_envelope_sha256: nativeSnippetPull.cached.canonicalEnvelopeSha256,
    snippet_update_op_id: snippetUpdateRef.operationId,
    snippet_update_batch_id: committedSnippetUpdate.event.batchId,
    snippet_update_revision_id: snippetUpdateRef.revisionId,
    snippet_update_commit_seq: snippetUpdateReceipt.commitSeq,
    snippet_update_device_seq: snippetUpdateRef.deviceSeq,
    snippet_update_envelope_sha256: snippetUpdateRef.envelopeSha256,
    snippet_update_successful_push_attempts: snippetUpdatePushEvents.length,
    native_cached_snippet_update_revision_id: nativeSnippetUpdatePull.cached.revisionId,
    native_cached_snippet_update_commit_seq: String(nativeSnippetUpdatePull.cached.commitSeq),
    native_cached_snippet_update_canonical_envelope_sha256:
      nativeSnippetUpdatePull.cached.canonicalEnvelopeSha256,
    native_snippet_update_op_id: nativeSnippetUpdateRef.operationId,
    native_snippet_update_batch_id: committedNativeSnippetUpdate.event.batchId,
    native_snippet_update_revision_id: nativeSnippetUpdateRef.revisionId,
    native_snippet_update_commit_seq: nativeSnippetUpdateReceipt.commitSeq,
    native_snippet_update_device_seq: nativeSnippetUpdateRef.deviceSeq,
    native_snippet_update_envelope_sha256: nativeSnippetUpdateRef.envelopeSha256,
    native_snippet_update_successful_push_attempts: nativePushesFor(nativeSnippetUpdateRef.operationId).length,
    native_cached_snippet_native_update_revision_id: nativeSnippetLatestPull.cached.revisionId,
    native_cached_snippet_native_update_commit_seq: String(nativeSnippetLatestPull.cached.commitSeq),
    native_cached_snippet_native_update_canonical_envelope_sha256:
      nativeSnippetLatestPull.cached.canonicalEnvelopeSha256,
    web_pulled_native_snippet_revision_id: nativeSnippetUpdateRef.revisionId,
    web_pulled_native_snippet_commit_seq: webNativeUpdateChange.refs.find((ref) =>
      ref.recordId === snippetRef.recordId && ref.revisionId === nativeSnippetUpdateRef.revisionId)?.commitSeq,
    web_pulled_native_snippet_envelope_sha256: webNativeUpdateChange.refs.find((ref) =>
      ref.recordId === snippetRef.recordId && ref.revisionId === nativeSnippetUpdateRef.revisionId)?.envelopeSha256,
    web_native_snippet_update_fields_verified: webNativeSnippetFieldsVerified,
    web_native_snippet_card_body_verified: webNativeSnippetCardBodyVerified,
    web_native_snippet_card_tag_verified: webNativeSnippetCardTagVerified,
    web_republished_native_snippet_update: webRepublishedNativeSnippet,
    snippet_created_and_decrypted_in_web: true,
    native_cached_snippet_display_decrypted: true,
    native_snippet_title_field_verified: nativeSnippetTitleField.value_matches,
    native_snippet_body_field_verified: nativeSnippetBodyField.value_matches,
    native_snippet_tag_field_verified: nativeSnippetTagField.value_matches,
    native_updated_snippet_title_field_verified: nativeUpdatedSnippetTitleField.value_matches,
    native_updated_snippet_body_field_verified: nativeUpdatedSnippetBodyField.value_matches,
    native_updated_snippet_tag_field_verified: nativeUpdatedSnippetTagField.value_matches,
    native_snippet_second_update_title_field_verified: nativeSnippetSecondTitleField.value_matches,
    native_snippet_second_update_body_field_verified: nativeSnippetSecondBodyField.value_matches,
    native_snippet_second_update_tag_field_verified: nativeSnippetSecondTagField.value_matches,
    web_pulled_native_snippet_verified: webNativeUpdateChange.status === 200,
    snippet_execution_requested: false,
    native_batch_id: nativeBatchId,
    web_batch_id: webUpdatePush.batchId,
    native_revision_id: nativeRevisionId,
    web_revision_id: webRef.revisionId,
    native_commit_seq: nativeReceipt.commitSeq,
    web_commit_seq: webReceipt.commitSeq,
    native_held_batch_id: heldPush.batchId,
    native_operation_envelope_sha256: pending.item.canonicalEnvelopeSha256,
    native_held_push_http_status: heldPush.status,
    native_successful_push_http_status: nativeRetry.push.status,
    web_successful_push_http_status: webUpdatePush.status,
    native_cached_web_revision_id: nativePull.cached.revisionId,
    native_cached_web_commit_seq: nativePull.cached.commitSeq,
    native_cached_web_envelope_sha256: nativePull.cached.envelopeSha256,
    native_cached_credential_revision_id: nativeSshPull.cachedCredential.revisionId,
    native_cached_credential_commit_seq: String(nativeSshPull.cachedCredential.commitSeq),
    native_cached_credential_envelope_sha256: nativeSshPull.cachedCredential.envelopeSha256,
    native_cached_ssh_host_revision_id: nativeSshPull.cachedHost.revisionId,
    native_cached_ssh_host_commit_seq: String(nativeSshPull.cachedHost.commitSeq),
    native_cached_ssh_host_envelope_sha256: nativeSshPull.cachedHost.envelopeSha256,
    native_cached_known_host_revision_id: finalSshRecords.find((item) =>
      item.recordId === knownHostRef.recordId)?.revisionId,
    native_cached_known_host_commit_seq: String(finalSshRecords.find((item) =>
      item.recordId === knownHostRef.recordId)?.commitSeq),
    native_cached_known_host_canonical_envelope_sha256: finalSshRecords.find((item) =>
      item.recordId === knownHostRef.recordId)?.canonicalEnvelopeSha256,
    private_key_form_roundtrip_verified: true,
    private_key_decrypted_and_used_by_native_ssh: true,
    ssh_host_key_fingerprint_verified: true,
    ssh_publickey_accepted_count: sshFixtureEvidence.publicKeyAccepted,
    ssh_interactive_shell_count: sshFixtureEvidence.shellSessions,
    ...sftpAcceptance,
    ssh_fixture_cleanup_verified: sshFixtureCleanupVerified,
    ssh_marker_file_verified: true,
    private_key_persistence_marker_count: sshPrivateKeyMarkers.length,
    web_private_key_persistence_scan_clear: webStorageScan.markerFree,
    native_private_key_persistence_scan_clear: localPrivacyClear,
    server_private_key_persistence_scan_clear: serverPrivacyClear,
    web_indexeddb_plaintext_scan_clear: webStorageScan.indexedDbMarkerFree,
    web_local_storage_plaintext_scan_clear: webStorageScan.localStorageMarkerFree,
    web_cache_plaintext_scan_clear: webStorageScan.cacheMarkerFree,
    web_persistent_storage_plaintext_scan_clear: webStorageScan.markerFree,
    web_persistent_database_count: webStorageScan.databaseCount,
    web_persistent_store_count: webStorageScan.storeCount,
    web_persistent_row_count: webStorageScan.rowCount,
  });
  assertThat(result.native_device_id !== result.web_device_id && result.native_op_id !== result.web_op_id,
    'native and Web sync identities were not independent');
  assertThat(Object.values(result).every((value) => typeof value !== 'string' || markerFree(value)),
    'runner result contained a synthetic plaintext marker');
  fs.mkdirSync(path.dirname(RESULT_FILE), { recursive: true, mode: 0o700 });
  fs.writeFileSync(RESULT_FILE, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  try { fs.chmodSync(RESULT_FILE, 0o600); } catch (_) {}
  stage(`complete result fields=${Object.keys(result).length} native_pushes=${result.nativeSuccessfulPushAttempts} web_pushes=${result.webSuccessfulPushAttempts}`);
}

function webPushesForId(recordId) {
  return WEB_PUSHES.filter((event) => event.refs.some((ref) => ref.recordId === recordId));
}

main().catch(async (error) => {
  stage(`failed safely: ${sanitizeError(error)}`);
  process.exitCode = 1;
}).finally(async () => {
  await cleanup();
});
