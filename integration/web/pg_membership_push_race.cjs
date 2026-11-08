/*
 * PG-MEMBERSHIP-PUSH-RACE-01: exercise the two serialized outcomes for a real
 * signed Editor Host push and an Owner role downgrade with independent Web
 * accounts. The Python PostgreSQL fixture runs this once for each RACE_ORDER
 * and asserts the exact receipt/version/event/head/counter deltas.
 *
 * This runner emits only random database identifiers, signed-envelope hashes,
 * statuses, and small counts. It never logs credentials, invitation tokens,
 * encrypted envelopes, Host fields, or request/response bodies.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { reconstructSqliteFile, SQLITE_BLOCK_SIZE } =
  require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const PREFIX = 'ATERMIUS_PG_MEMBERSHIP_PUSH_RACE_';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const config = {
  baseUrl: process.env[`${PREFIX}BASE_URL`],
  nodeAUrl: process.env[`${PREFIX}NODE_A_URL`],
  nodeBUrl: process.env[`${PREFIX}NODE_B_URL`],
  webRoot: process.env[`${PREFIX}WEB_ROOT`] || path.join(ROOT, 'apps/client/build/web'),
  ownerUsername: process.env[`${PREFIX}OWNER_USERNAME`],
  ownerPassword: process.env[`${PREFIX}OWNER_PASSWORD`],
  editorUsername: process.env[`${PREFIX}EDITOR_USERNAME`],
  editorPassword: process.env[`${PREFIX}EDITOR_PASSWORD`],
  bootstrapToken: process.env[`${PREFIX}BOOTSTRAP_TOKEN`],
  raceOrder: process.env[`${PREFIX}ORDER`],
  serverBin: process.env[`${PREFIX}SERVER_BIN`] || path.join(ROOT, 'server/target/debug/atermius-server'),
  hostName: process.env[`${PREFIX}HOST_NAME`],
  editedHostName: process.env[`${PREFIX}EDITED_HOST_NAME`],
  hostAddress: process.env[`${PREFIX}HOST_ADDRESS`],
  sshUsername: process.env[`${PREFIX}SSH_USERNAME`],
  dataDir: process.env.ATERMIUS_DATA_DIR,
  databaseUrl: process.env.ATERMIUS_DATABASE_URL,
};
if (!config.editedHostName && config.hostName) config.editedHostName = `${config.hostName}-edited`;

const RUN_ID = crypto.randomBytes(8).toString('hex');
const SSH_PORT = '22';
const MARKERS = [config.ownerUsername, config.ownerPassword, config.editorUsername,
  config.editorPassword, config.bootstrapToken, config.hostName, config.editedHostName,
  config.hostAddress, config.sshUsername].filter((value) => typeof value === 'string' && value);
const HOST_MARKERS = [config.hostName, config.editedHostName, config.hostAddress,
  config.sshUsername].filter((value) => typeof value === 'string' && value);
const UUID = (value) => typeof value === 'string' && UUID_RE.test(value);
const state = {
  stage: 'preflight',
  browser: null,
  contextA: null,
  contextB: null,
  pageA: null,
  pageB: null,
  proxy: null,
  proxySockets: new Set(),
  proxyStarted: false,
  tempRoot: null,
  cleaned: false,
  ownerVaultId: null,
  editorPushGate: null,
};
const PUSHES = [];
const ROTATIONS = [];
const API_FAILURES = [];
const EXPECTED_API_FAILURES = [];
const REQUEST_FAILURES = [];
const EXPECTED_REQUEST_FAILURES = [];
const PAGE_ERRORS = [];
const CONSOLE_ERRORS = [];
const EXPECTED_CONSOLE_ERRORS = [];
const PROXY_EVENTS = [];
const OFFLINE_PROFILES = new Set();
const OFFLINE_REQUESTS = new WeakSet();
const EXPECTED_PRESENCE_429_CONSOLE_BUDGET = new Map();
const EXPECTED_PUSH_403_CONSOLE_BUDGET = new Map();
let SQLITE_SNAPSHOTS = 0;
let clipboardSecrets = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  state.stage = value;
  console.log(`stage: ${value}`);
}

function safeOrigin(value, label) {
  let url;
  try { url = new URL(value || ''); } catch (_) {
    throw new Error(`${label} URL is invalid`);
  }
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
    Number(url.port) > 0 && url.pathname === '/' && !url.search && !url.hash &&
    !url.username && !url.password,
  `${label} must be an exact loopback HTTP origin`);
  return { origin: url.origin, hostname: url.hostname, port: Number(url.port) };
}

function assertConfig() {
  assertThat(['push_first', 'downgrade_first'].includes(config.raceOrder),
    'RACE_ORDER must be push_first or downgrade_first');
  assertThat(config.baseUrl && config.nodeAUrl && config.nodeBUrl &&
    config.ownerUsername && config.ownerPassword && config.editorUsername &&
    config.editorPassword && config.bootstrapToken && config.hostName &&
    config.hostAddress && config.sshUsername && config.dataDir && config.databaseUrl,
  'PG membership-push race environment is incomplete');
  assertThat(config.ownerPassword.length >= 12 && config.editorPassword.length >= 12 &&
    config.bootstrapToken.length >= 40,
  'PG membership-push race credentials do not meet the acceptance contract');
  assertThat(config.ownerUsername !== config.editorUsername,
    'Owner and Editor must be separate accounts');
  assertThat(config.hostName !== config.editedHostName &&
    !/^https?:\/\//i.test(config.hostAddress) &&
    !/^(localhost|127\.0\.0\.1)(?::|$)/i.test(config.hostAddress),
  'Host inputs must be unique and must not target this runner');
  const webAssets = ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm'];
  assertThat(webAssets.every((name) => fs.existsSync(path.join(config.webRoot, name))),
    'compiled Flutter Web release bundle is incomplete');
  const dataStat = fs.lstatSync(config.dataDir);
  assertThat(dataStat.isDirectory() && !dataStat.isSymbolicLink() &&
    (dataStat.mode & 0o077) === 0,
  'runner data directory must be a private nonsymlink directory');
  assertThat(config.databaseUrl.startsWith('sqlite:') &&
    process.env.ATERMIUS_SYNC_PG_URL && process.env.ATERMIUS_SYNC_PG_SCHEMA,
  'CLI environment is not connected to the isolated PostgreSQL fixture');
  assertThat(fs.existsSync(config.serverBin) && fs.statSync(config.serverBin).isFile(),
    'fixture server binary is unavailable');
  state.base = safeOrigin(config.baseUrl, 'proxy bind');
  state.nodeA = safeOrigin(config.nodeAUrl, 'Node A');
  state.nodeB = safeOrigin(config.nodeBUrl, 'Node B');
}

function profileFrom(headers) {
  return headers['x-pg-acceptance-profile'] === 'B' ? 'B' : 'A';
}

function routeTo(profile) {
  return profile === 'B' ? state.nodeB : state.nodeA;
}

function proxySafeRefs(body) {
  const operations = Array.isArray(body?.operations) ? body.operations : [];
  return operations.map((item) => {
    const header = item?.header || {};
    return {
      opId: header.op_id || null,
      recordId: header.record_id || null,
      revisionId: header.revision_id || null,
      operation: header.operation || null,
      deviceId: header.device_id || null,
    };
  });
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url || '/', state.base.origin);
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const profile = profileFrom(request.headers);
    const target = routeTo(profile);
    const pathName = url.pathname;
    const isPush = request.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(pathName);
    const isRotation = request.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/keys\/rotate$/i.test(pathName);
    const proxyEvent = {
      profile,
      sourceNode: profile === 'B' ? 'B' : 'A',
      method: request.method || 'GET',
      path: pathName,
      status: null,
      operationRefs: [],
      batchId: null,
      atMs: Date.now(),
    };
    if (pathName.startsWith('/api/v1/')) PROXY_EVENTS.push(proxyEvent);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      proxyEvent.status = upstreamResponse.statusCode || null;
      if (!isPush && !isRotation) {
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        upstreamResponse.pipe(response);
        return;
      }
      const chunks = [];
      let size = 0;
      upstreamResponse.on('data', (chunk) => {
        size += chunk.length;
        if (size <= 2 * 1024 * 1024) chunks.push(chunk);
      });
      upstreamResponse.on('end', () => {
        const body = size <= 2 * 1024 * 1024 ? Buffer.concat(chunks) : Buffer.alloc(0);
        if (isPush && body.length > 0) {
          try {
            const parsed = JSON.parse(body.toString('utf8'));
            proxyEvent.errorCode = parsed?.error?.code || parsed?.code || null;
            proxyEvent.resultRefs = Array.isArray(parsed?.results) ? parsed.results.map((item) => ({
              opId: item?.op_id || null,
              revisionId: item?.revision_id || null,
              commitSeq: String(item?.commit_seq ?? ''),
              alreadyCommitted: item?.already_committed === true,
            })) : [];
          } catch (_) { proxyEvent.responseParseFailed = true; }
        } else if (isRotation && body.length > 0) {
          try {
            const parsed = JSON.parse(body.toString('utf8'));
            proxyEvent.vaultId = parsed?.vault_id || null;
            proxyEvent.membershipVersion = String(parsed?.membership_version ?? '');
            proxyEvent.keyEpoch = String(parsed?.active_key_epoch ?? '');
            proxyEvent.errorCode = parsed?.error?.code || parsed?.code || null;
          } catch (_) { proxyEvent.responseParseFailed = true; }
        }
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        response.end(body.length > 0 ? body : size === 0 ? Buffer.alloc(0) : Buffer.concat(chunks));
      });
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    if (isPush) {
      const chunks = [];
      let size = 0;
      request.on('data', (chunk) => {
        size += chunk.length;
        if (size <= 2 * 1024 * 1024) chunks.push(chunk);
      });
      request.on('end', () => {
        if (size <= 2 * 1024 * 1024) {
          try {
            const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            proxyEvent.batchId = typeof parsed?.batch_id === 'string' ? parsed.batch_id : null;
            proxyEvent.operationRefs = proxySafeRefs(parsed);
          } catch (_) { proxyEvent.requestParseFailed = true; }
        } else proxyEvent.requestOversized = true;
      });
    }
    request.pipe(upstreamRequest);
  });

  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', state.base.origin);
    const profile = profileFrom(request.headers);
    const target = routeTo(profile);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: 'GET',
      path: `${url.pathname}${url.search}`,
      headers,
    });
    upstreamRequest.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      let responseHead = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        responseHead += `${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`;
      }
      clientSocket.write(`${responseHead}\r\n`);
      if (clientHead?.length) upstreamSocket.write(clientHead);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      state.proxySockets.add(clientSocket);
      state.proxySockets.add(upstreamSocket);
      clientSocket.on('close', () => state.proxySockets.delete(clientSocket));
      upstreamSocket.on('close', () => state.proxySockets.delete(upstreamSocket));
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      clientSocket.write(`HTTP/1.1 ${upstreamResponse.statusCode || 502} ${upstreamResponse.statusMessage || 'Bad Gateway'}\r\n`);
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        clientSocket.write(`${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`);
      }
      clientSocket.write('\r\n');
      upstreamResponse.pipe(clientSocket);
    });
    upstreamRequest.on('error', () => clientSocket.destroy());
    clientSocket.on('close', () => upstreamRequest.destroy());
    upstreamRequest.end();
  });
  server._sockets = state.proxySockets;
  return server;
}

function input(page, label) {
  return page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`);
}

async function field(page, label) {
  const locator = input(page, label);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    const visible = [];
    for (let index = 0; index < await locator.count(); index += 1) {
      const item = locator.nth(index);
      if (await item.isVisible().catch(() => false)) visible.push(item);
    }
    assertThat(visible.length <= 1, `form field '${label}' was ambiguous`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`form field '${label}' was not visible`);
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  let actual = '';
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.fill(value);
    actual = await locator.inputValue().catch(() => '');
    if (actual === value) break;
    await page.waitForTimeout(75 * (attempt + 1));
  }
  assertThat(actual === value,
    `form field '${label}' rejected test data (expected length ${value.length}, observed ${actual.length})`);
  await locator.press('Tab');
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) return locator.nth(index);
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button '${label}' was not found`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function waitFor(predicate, description, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function openFlutter(page) {
  await page.goto(config.baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web crypto module', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitFor(() => page.locator('flt-semantics').count().then((count) => count > 0),
    'Flutter semantics tree');
}

async function connectToInstance(page) {
  await fill(page, 'Server URL', config.baseUrl);
  await click(page, 'Connect securely');
}

async function waitWorkspace(page) {
  await (await button(page, 'Settings')).waitFor({ state: 'visible', timeout: 45000 });
}

function accountInvitation(username) {
  const cliEnv = { ...process.env, RUST_LOG: 'off' };
  delete cliEnv[`${PREFIX}BOOTSTRAP_TOKEN`];
  const result = spawnSync(config.serverBin,
    ['create-account-invite', '--username', username], {
      cwd: ROOT,
      env: cliEnv,
      encoding: 'utf8',
      timeout: 45000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  let stdout = result.stdout || '';
  const match = stdout.match(/Atermius account invitation \(one-time; username=[^\n]+\):\s*([A-Za-z0-9_-]{43})/);
  const invitation = match?.[1];
  result.stdout = '';
  stdout = '';
  assertThat(!result.error && result.status === 0 && invitation,
    'Editor account invitation issuance failed');
  return invitation;
}

async function registerOwner(page) {
  await connectToInstance(page);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', config.ownerUsername);
  await fill(page, 'Master password · 12+ characters', config.ownerPassword);
  await fill(page, 'Confirm master password', config.ownerPassword);
  await fill(page, 'One-time bootstrap token', config.bootstrapToken);
  await fill(page, 'Device name', 'PG race Owner Web');
  await fill(page, 'First Vault', `PG membership race ${RUN_ID}`);
  await click(page, 'Create owner account');
  config.bootstrapToken = undefined;
  await waitWorkspace(page);
}

async function registerEditor(page) {
  await connectToInstance(page);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  let token = accountInvitation(config.editorUsername);
  clipboardSecrets.push(token);
  try {
    await fill(page, 'Email on the invitation', config.editorUsername);
    await fill(page, 'Master password · 12+ characters', config.editorPassword);
    await fill(page, 'Confirm master password', config.editorPassword);
    await fill(page, 'Instance invitation token', token);
    token = undefined;
    await fill(page, 'Device name', 'PG race Editor Web');
    await fill(page, 'First Vault', `PG race Editor personal ${RUN_ID}`);
    await click(page, 'Create invited account');
    await waitWorkspace(page);
  } finally { token = undefined; clipboardSecrets = []; }
}

async function clearClipboard(page) {
  await page.evaluate(async () => navigator.clipboard.writeText('')).catch(() => {});
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `clipboard field '${label}' rejected test data`);
}

async function copyDeviceCard(page) {
  await click(page, 'Settings');
  await (await button(page, 'Copy signed share request')).scrollIntoViewIfNeeded();
  await click(page, 'Copy signed share request');
  await click(page, 'Copy');
  let value = await page.evaluate(async () => navigator.clipboard.readText());
  try {
    let parsed;
    try { parsed = JSON.parse(value); } catch (_) { throw new Error('device share request was not JSON'); }
    assertThat(parsed?.format === 'atermius-vault-share-request-v1' &&
      UUID(parsed?.account_id) && UUID(parsed?.device?.device_id),
    'Editor signed share request omitted its device identity');
    return value;
  } finally {
    value = undefined;
    await clearClipboard(page);
  }
}

function apiEventFor(page, method, pathRegex, collection) {
  const requests = new WeakMap();
  page.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (url.origin !== state.base.origin || request.method() !== method || !pathRegex.test(url.pathname)) return;
    const event = {
      profile: page === state.pageB ? 'B' : 'A',
      sourceNode: page === state.pageB ? 'B' : 'A',
      path: url.pathname,
      atMs: Date.now(),
      status: null,
      responseProcessed: false,
    };
    if (collection === PUSHES) {
      try {
        const body = request.postDataJSON() || {};
        event.batchId = typeof body.batch_id === 'string' ? body.batch_id : null;
        event.operations = (Array.isArray(body.operations) ? body.operations : []).map((envelope) => {
          const header = envelope?.header || {};
          return {
            operationId: header.op_id || null,
            recordId: header.record_id || null,
            revisionId: header.revision_id || null,
            baseRevisionId: header.base_revision_id || null,
            deviceId: header.device_id || null,
            operation: header.operation || null,
            keyEpoch: String(header.key_epoch ?? ''),
            membershipVersion: String(header.membership_version ?? ''),
            envelopeSha256: crypto.createHash('sha256')
              .update(JSON.stringify(envelope)).digest('hex'),
            envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
              'ciphertext,header,nonce,signature',
            ciphertextFieldsPresent: ['ciphertext', 'nonce', 'signature'].every((key) =>
              typeof envelope?.[key] === 'string' && envelope[key].length > 0),
          };
        });
        event.markerFree = !MARKERS.some((marker) => JSON.stringify(body).includes(marker));
      } catch (_) {
        event.requestParseFailed = true;
        event.operations = [];
        event.markerFree = false;
      }
      collection.push(event);
      requests.set(request, event);
      return;
    }
    collection.push(event);
    requests.set(request, event);
  });
  page.on('response', (response) => {
    const request = response.request();
    let url;
    try { url = new URL(response.url()); } catch (_) { return; }
    if (url.origin !== state.base.origin || request.method() !== method || !pathRegex.test(url.pathname)) return;
    const event = requests.get(request);
    if (!event) return;
    event.status = response.status();
    void response.json().then((body) => {
      if (collection === PUSHES) {
        event.errorCode = body?.error?.code || body?.code || null;
        event.results = Array.isArray(body?.results) ? body.results.map((item) => ({
          operationId: item?.op_id || null,
          revisionId: item?.revision_id || null,
          commitSeq: String(item?.commit_seq ?? ''),
          alreadyCommitted: item?.already_committed === true,
        })) : [];
      } else {
        event.vaultId = body?.vault_id || null;
        event.membershipVersion = String(body?.membership_version ?? '');
        event.keyEpoch = String(body?.active_key_epoch ?? '');
        event.errorCode = body?.error?.code || body?.code || null;
      }
      event.responseProcessed = true;
    }).catch(() => {
      event.responseParseFailed = true;
      event.responseProcessed = true;
    });
  });
}

function observePage(page, profile) {
  page.on('pageerror', () => PAGE_ERRORS.push(profile));
  page.on('console', (message) => {
    if (message.type() !== 'error') return;
    const text = message.text();
    const expectedOffline = text.includes('net::ERR_INTERNET_DISCONNECTED');
    if (expectedOffline) return;
    const remaining429 = EXPECTED_PRESENCE_429_CONSOLE_BUDGET.get(profile) || 0;
    if (/status of 429\b/.test(text) && remaining429 > 0) {
      EXPECTED_PRESENCE_429_CONSOLE_BUDGET.set(profile, remaining429 - 1);
      EXPECTED_CONSOLE_ERRORS.push(profile);
      return;
    }
    const remaining403 = EXPECTED_PUSH_403_CONSOLE_BUDGET.get(profile) || 0;
    if (/status of 403\b/.test(text) && remaining403 > 0) {
      EXPECTED_PUSH_403_CONSOLE_BUDGET.set(profile, remaining403 - 1);
      EXPECTED_CONSOLE_ERRORS.push(profile);
      return;
    }
    let safeText = text;
    for (const marker of MARKERS) safeText = safeText.split(marker).join('[REDACTED]');
    safeText = safeText
      .replace(/[A-Za-z0-9_-]{40,}/g, '[REDACTED_OPAQUE]')
      .replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[REDACTED_ACCOUNT]')
      .slice(0, 240);
    CONSOLE_ERRORS.push({
      profile,
      category: text.includes('Failed to load resource') ? 'resource-load-failed' : 'console-error',
      detail: safeText,
    });
  });
  page.on('request', (request) => {
    if (OFFLINE_PROFILES.has(profile)) OFFLINE_REQUESTS.add(request);
  });
  page.on('requestfailed', (request) => {
    const errorText = request.failure()?.errorText || '';
    let pathname = '';
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    const expectedOffline = errorText === 'net::ERR_INTERNET_DISCONNECTED' &&
      (OFFLINE_REQUESTS.has(request) || profile === 'B');
    if (request.method() === 'GET' && /\/membership$/i.test(pathname) &&
        errorText === 'net::ERR_ABORTED') {
      EXPECTED_REQUEST_FAILURES.push({ profile, method: 'GET', pathname,
        category: 'membership-view-cancelled' });
      return;
    }
    REQUEST_FAILURES.push({ profile, method: request.method(), pathname, errorText,
      expectedOffline, atMs: Date.now() });
  });
  page.on('response', (response) => {
    if (response.status() < 400) return;
    let pathname = '';
    try { pathname = new URL(response.url()).pathname; } catch (_) { return; }
    if (!pathname.startsWith('/api/v1/')) return;
    if (response.status() === 429 && /\/presence$/i.test(pathname)) {
      EXPECTED_PRESENCE_429_CONSOLE_BUDGET.set(profile,
        (EXPECTED_PRESENCE_429_CONSOLE_BUDGET.get(profile) || 0) + 1);
    }
    if (profile === 'B' && response.status() === 403 && /\/sync\/push$/i.test(pathname)) {
      EXPECTED_PUSH_403_CONSOLE_BUDGET.set(profile,
        (EXPECTED_PUSH_403_CONSOLE_BUDGET.get(profile) || 0) + 1);
    }
    const expectedPush = profile === 'B' && response.status() === 403 && /\/sync\/push$/i.test(pathname);
    void response.json().then((body) => {
      const code = body?.error?.code || body?.code || null;
      if (expectedPush && code === 'VAULT_READ_ONLY') return;
      const failure = { profile, status: response.status(), pathname,
        routeClass: /\/sync\/push$/i.test(pathname) ? 'sync-push' : 'api', code };
      if (response.status() === 429 && code === 'PRESENCE_HEARTBEAT_RATE_LIMITED') {
        EXPECTED_API_FAILURES.push(failure);
        return;
      }
      API_FAILURES.push(failure);
    }).catch(() => API_FAILURES.push({
      profile, status: response.status(), pathname, routeClass: 'api', code: null,
    }));
  });
}

async function waitApiEvent(events, predicate, description, timeoutMs = 45000) {
  await waitFor(() => events.some((item) => predicate(item) && item.responseProcessed), description, timeoutMs);
  return events.find((item) => predicate(item) && item.responseProcessed);
}

function hostCard(page, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('group', { name: new RegExp(`^Host: ${escaped}; `) }).first();
}

async function waitHostByName(page, name, expected = true, timeoutMs = 45000) {
  const card = hostCard(page, name);
  await waitFor(() => card.isVisible().catch(() => false).then((visible) => visible === expected),
    `Host ${expected ? 'to appear' : 'to disappear'}`, timeoutMs);
}

async function waitSemantic(page, pattern, description, timeoutMs = 30000) {
  const expression = { source: pattern.source, flags: pattern.flags };
  await waitFor(() => page.locator('flt-semantics').evaluateAll((nodes, spec) => {
    const regex = new RegExp(spec.source, spec.flags);
    return nodes.some((node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      const visible = rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden';
      const text = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      return visible && regex.test(text);
    });
  }, expression), description, timeoutMs);
}

async function waitPendingCount(page, expected, description, timeoutMs = 30000) {
  await waitFor(async () => (await pendingCount(page)) === expected, description, timeoutMs);
}

async function pendingCount(page) {
  return page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    for (const node of nodes) {
      const value = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      const match = value.match(/Pending sync[^0-9]{0,60}(\d+)/i);
      if (match) return Number(match[1]);
    }
    for (const node of nodes.filter((item) => item.getAttribute('role') === 'button')) {
      const value = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
      const match = value.match(/(?:pending\s*(\d+)|(\d+)\s*pending)/i);
      if (match) return Number(match[1] || match[2]);
      if (/\bIdle\b/.test(value)) return 0;
    }
    return null;
  }).catch(() => null);
}

async function pendingSyncState(page) {
  return page.evaluate(() => {
    const values = [...document.querySelectorAll('flt-semantics')].map((node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`.trim());
    if (values.some((value) => /\bRead-only\b/i.test(value))) return 'read-only';
    if (values.some((value) => /\bSync error\b/i.test(value))) return 'error';
    if (values.some((value) => /\bPending\b|\d+ pending/i.test(value))) return 'pending';
    if (values.some((value) => /\bIdle\b/.test(value))) return 'idle';
    return 'unknown';
  }).catch(() => 'unknown');
}

async function copyAndInviteEditor(editorPage, ownerPage) {
  let shareRequest = await copyDeviceCard(editorPage);
  let token;
  const start = ROTATIONS.length;
  try {
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Invite member');
    await paste(ownerPage, 'Public Device Card JSON', shareRequest);
    await click(ownerPage, 'Verify and review');
    await waitSemantic(ownerPage, /Confirm target:/, 'Owner invite target confirmation');
    const inviteStart = PROXY_EVENTS.filter((event) => event.method === 'POST' &&
      /\/invitations$/i.test(event.path)).length;
    await click(ownerPage, 'Sign and create invitation');
    await waitFor(() => PROXY_EVENTS.filter((event) => event.method === 'POST' &&
      /\/invitations$/i.test(event.path)).length > inviteStart,
    'Vault invitation request');
    await waitFor(() => PROXY_EVENTS.some((event) => event.method === 'POST' &&
      /\/invitations$/i.test(event.path) && event.status === 200),
    'Vault invitation response');
    await click(ownerPage, 'Copy token');
    token = await ownerPage.evaluate(async () => navigator.clipboard.readText());
    assertThat(typeof token === 'string' && token.length >= 40,
      'one-time Vault invitation token was not copied');
    await clearClipboard(ownerPage);
  } finally {
    shareRequest = undefined;
    clipboardSecrets = [];
  }
  try {
    await click(editorPage, 'Settings');
    await click(editorPage, 'Accept invitation');
    await fill(editorPage, 'Invitation token', token);
    token = undefined;
    await click(editorPage, 'Accept and unlock Vault');
    await waitWorkspace(editorPage);
    await click(editorPage, 'Settings');
    await waitSemantic(editorPage, /EDITOR\s*[·|•]\s*key epoch/i,
      'accepted Editor membership', 45000);
    await click(editorPage, 'Hosts');
  } finally {
    token = undefined;
    await clearClipboard(editorPage);
    await clearClipboard(ownerPage);
  }
  assertThat(ROTATIONS.length === start, 'unexpected key rotation was recorded during invitation');
}

async function createOwnerHost(page) {
  const start = PUSHES.length;
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await fill(page, 'Display name', config.hostName);
  await fill(page, 'Hostname or IP', config.hostAddress);
  await fill(page, 'Port', SSH_PORT);
  await fill(page, 'SSH username', config.sshUsername);
  await click(page, 'Save encrypted host');
  const push = await waitApiEvent(PUSHES, (event) => event.profile === 'A' &&
    event.operations?.some((item) => item.operation === 'create'),
  'Owner baseline signed push', 60000);
  const baseline = push.operations.find((item) => item.operation === 'create');
  assertThat(push.status === 200 && push.sourceNode === 'A' && push.batchId &&
    push.operations.length === 1 &&
    baseline?.recordId && baseline.operationId && baseline.revisionId &&
    baseline.baseRevisionId === null && baseline.envelopeShapeValid &&
    baseline.ciphertextFieldsPresent && push.markerFree &&
    push.results?.length === 1 && push.results[0].operationId === baseline.operationId &&
    push.results[0].alreadyCommitted === false && /^\d+$/.test(push.results[0].commitSeq),
  'baseline Host create did not produce one marker-free signed node-A receipt');
  await waitHostByName(page, config.hostName, true);
  assertThat(PUSHES.length >= start + 1, 'baseline push was not observed');
  return { ...baseline, vaultId: (push.path.match(/\/vaults\/([0-9a-f-]+)\//i) || [])[1],
    batchId: push.batchId, commitSeq: push.results[0].commitSeq, sourceNode: push.sourceNode,
    pushAttempt: safePushSummary(push, baseline.operationId) };
}

async function addEditorEditOffline(page, context, baseline) {
  await click(page, 'Hosts');
  await waitHostByName(page, config.hostName, true);
  await context.setOffline(true);
  OFFLINE_PROFILES.add('B');
  await waitFor(() => page.evaluate(() => navigator.onLine === false),
    'Editor profile network to go offline', 5000);
  const card = hostCard(page, config.hostName);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await fill(page, 'Display name', config.editedHostName);
  await click(page, 'Save encrypted host');
  await waitHostByName(page, config.editedHostName, true);
  await waitHostByName(page, config.hostName, false);
  await waitPendingCount(page, 1, 'Editor offline operation to remain queued');
  const before = await snapshotOutbox(page, baseline.vaultId, baseline.recordId, 'before reconnect');
  assertThat(before.operations.length === 1 && before.operations[0].operation === 'update' &&
    before.operations[0].baseRevisionId === baseline.revisionId &&
    UUID(before.operations[0].deviceId) && before.operations[0].deviceId !== baseline.deviceId &&
    before.operations[0].membershipVersion === baseline.membershipVersion &&
    before.operations[0].keyEpoch === baseline.keyEpoch,
  'Editor offline edit was not one signed update against the baseline epoch and version');
  assertThat(before.integrity === 'ok', 'Editor outbox SQLite database integrity check failed');
  return before;
}

async function readIndexedDbSqlite(page) {
  return page.evaluate(async (databaseName) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('IndexedDB open failed'));
      request.onblocked = () => reject(new Error('IndexedDB open blocked'));
    });
    try {
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        throw new Error('SQLite VFS IndexedDB stores are missing');
      }
      const tx = db.transaction('files', 'readonly');
      const [rows, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = tx.objectStore('files').getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite VFS file read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = tx.objectStore('files').getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite VFS file key read failed'));
        }),
      ]);
      const selected = rows.map((row, index) => ({
        id: Number(keys[index]), name: String(row?.name || ''), length: Number(row?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal' ||
        file.name === `/${databaseName}/database` || file.name.endsWith('/database') ||
        file.name.endsWith('/database-journal'));
      const database = selected.find((file) => file.name.endsWith('/database'));
      const journal = selected.find((file) => file.name.endsWith('/database-journal'));
      if (!database || (journal && journal.length !== 0)) {
        throw new Error('SQLite VFS database or journal state was invalid');
      }
      const files = [];
      for (const file of selected) {
        if (!Number.isSafeInteger(file.id) || !Number.isSafeInteger(file.length) ||
            file.length < 0 || file.length > 64 * 1024 * 1024) {
          throw new Error('SQLite VFS file metadata was invalid');
        }
        const range = IDBKeyRange.bound([file.id, 0], [file.id, Number.MAX_SAFE_INTEGER]);
        const blocksTx = db.transaction('blocks', 'readonly');
        const [blockKeys, values] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = blocksTx.objectStore('blocks').getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(new Error('SQLite VFS block key read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = blocksTx.objectStore('blocks').getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(new Error('SQLite VFS block read failed'));
          }),
        ]);
        const blocks = await Promise.all(blockKeys.map(async (key, index) => {
          const value = values[index];
          let bytes;
          if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
          else if (ArrayBuffer.isView(value)) {
            bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          } else if (value instanceof Blob) bytes = new Uint8Array(await value.arrayBuffer());
          else throw new Error('unsupported SQLite VFS block representation');
          let binary = '';
          for (let position = 0; position < bytes.length; position += 0x8000) {
            binary += String.fromCharCode(...bytes.subarray(position, position + 0x8000));
          }
          return { offset: Number(key?.[1]), base64: btoa(binary) };
        }));
        files.push({ ...file, blocks });
      }
      return { files };
    } finally { db.close(); }
  }, 'atermius_vault');
}

async function snapshotOutbox(page, vaultId, recordId, label) {
  const image = await readIndexedDbSqlite(page);
  const database = image.files?.find((file) => file.name.endsWith('/database'));
  const journal = image.files?.find((file) => file.name.endsWith('/database-journal'));
  assertThat(database && database.length % SQLITE_BLOCK_SIZE === 0 && Array.isArray(database.blocks) &&
    (!journal || journal.length === 0),
    `IndexedDB SQLite image was not block-aligned ${label}`);
  const bytes = reconstructSqliteFile({
    fileId: database.id,
    name: database.name,
    length: database.length,
    blocks: database.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  assertThat(!HOST_MARKERS.some((marker) => bytes.includes(Buffer.from(marker))),
    `IndexedDB SQLite image contained a plaintext test marker ${label}`);
  const filename = path.join(state.tempRoot, `editor-outbox-${RUN_ID}.sqlite`);
  fs.writeFileSync(filename, bytes, { flag: 'w', mode: 0o600 });
  fs.chmodSync(filename, 0o600);
  const script = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    "db.execute('PRAGMA query_only=ON')",
    'vault_id,record_id=sys.argv[2:4]',
    "rows=db.execute(\"SELECT op_id,vault_id,record_id,base_revision_id,envelope_json,status,attempt_count,created_at,last_attempt_at FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    'def h(value): return hashlib.sha256(value.encode()).hexdigest() if value is not None else None',
    'ops=[]',
    'for row in rows:',
    ' env=json.loads(row[4]); header=env.get("header",{})',
    ' ops.append({"operationId":row[0],"vaultId":row[1],"recordId":row[2],"baseRevisionId":row[3],"revisionId":header.get("revision_id"),"operation":header.get("operation"),"deviceId":header.get("device_id"),"keyEpoch":str(header.get("key_epoch","")),"membershipVersion":str(header.get("membership_version","")),"envelopeSha256":h(row[4]),"status":row[5],"attemptCount":row[6],"createdAt":row[7],"lastAttemptAt":row[8]})',
    'print(json.dumps({"integrity":db.execute("PRAGMA integrity_check").fetchone()[0],"operations":ops},separators=(",",":")))',
    'db.close()',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', script, filename, vaultId, recordId], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 20000,
      maxBuffer: 512 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      `read-only IndexedDB outbox inspection failed ${label}`);
    const inspected = JSON.parse(result.stdout);
    assertThat(inspected.integrity === 'ok' && Array.isArray(inspected.operations),
      `IndexedDB outbox integrity check failed ${label}`);
    for (const operation of inspected.operations) {
      assertThat(operation.vaultId === vaultId && operation.recordId === recordId &&
        UUID(operation.operationId) && UUID(operation.revisionId) &&
        ['queued', 'sent'].includes(operation.status) && operation.envelopeSha256,
      `IndexedDB outbox row was incomplete ${label}`);
    }
    SQLITE_SNAPSHOTS += 1;
    return inspected;
  } finally {
    if (fs.existsSync(filename)) fs.unlinkSync(filename);
  }
}

function samePendingRow(left, right) {
  return Boolean(left && right) &&
    ['operationId', 'vaultId', 'recordId', 'baseRevisionId', 'revisionId',
      'deviceId', 'keyEpoch', 'membershipVersion', 'envelopeSha256'].every((key) =>
      left[key] === right[key]);
}

async function syncNow(page) {
  const locator = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  if (await locator.isEnabled().catch(() => false)) await locator.click();
}

function holdEditorPush(operationId) {
  let resolveCaptured;
  let resolveReleased;
  const gate = {
    operationId,
    captured: false,
    batchId: null,
    envelopeSha256: null,
    capturedPromise: new Promise((resolve) => { resolveCaptured = resolve; }),
    releasedPromise: new Promise((resolve) => { resolveReleased = resolve; }),
    capture() { this.captured = true; resolveCaptured(); },
    release() {
      resolveReleased();
      if (state.editorPushGate === this) state.editorPushGate = null;
    },
  };
  state.editorPushGate = gate;
  return gate;
}

async function installEditorPushGate(page) {
  await page.route('**/api/v1/vaults/*/sync/push', async (route) => {
    const gate = state.editorPushGate;
    if (!gate || gate.captured) {
      await route.continue();
      return;
    }
    let body;
    try { body = route.request().postDataJSON() || {}; } catch (_) { body = {}; }
    const envelope = (Array.isArray(body?.operations) ? body.operations : [])
      .find((item) => item?.header?.op_id === gate.operationId);
    if (!envelope) {
      await route.continue();
      return;
    }
    gate.batchId = typeof body.batch_id === 'string' ? body.batch_id : null;
    gate.envelopeSha256 = crypto.createHash('sha256')
      .update(JSON.stringify(envelope)).digest('hex');
    gate.capture();
    await gate.releasedPromise;
    try { await route.continue(); } catch (_) { await route.abort().catch(() => {}); }
  });
}

async function rotateEditorToViewer(page) {
  await click(page, 'Settings');
  await click(page, 'Manage Vault members');
  await waitSemantic(page, new RegExp(config.editorUsername.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
    'Editor member row', 30000);
  const rotateStart = ROTATIONS.length;
  await click(page, 'Make viewer');
  await page.getByRole('alertdialog').filter({ hasText: 'Rotate key and change role?' })
    .waitFor({ state: 'visible', timeout: 15000 });
  await click(page, 'Change to viewer');
  const rotation = await waitApiEvent(ROTATIONS, (event) => event.profile === 'A',
    'signed Owner role rotation response', 90000);
  assertThat(rotation.status === 200 && rotation.vaultId === state.ownerVaultId &&
    /^\d+$/.test(rotation.membershipVersion) && /^\d+$/.test(rotation.keyEpoch),
  'Owner role downgrade did not return the committed Vault epoch and membership version');
  await waitSemantic(page, /VIEWER\s*[·|•]\s*Active/i,
    'Editor member row to show Viewer role', 45000);
  assertThat(ROTATIONS.length === rotateStart + 1,
    'Owner role change emitted an unexpected number of rotation requests');
  await click(page, 'Close');
  return rotation;
}

async function waitForRoleOnEditor(page) {
  await click(page, 'Settings');
  await waitSemantic(page, /VIEWER\s*[·|•]\s*key epoch/i,
    'Editor profile to observe Viewer role');
}

function safePushSummary(event, focusedOperationId = null) {
  return {
    sourceProfile: event.profile,
    sourceNode: event.sourceNode,
    status: event.status,
    errorCode: event.errorCode || null,
    batchId: event.batchId || null,
    operationId: focusedOperationId || event.focusedOperationId ||
      (event.operations || [])[0]?.operationId || null,
    operationIds: (event.operations || []).map((item) => item.operationId).filter(Boolean),
    operations: (event.operations || []).map((item) => ({
      operationId: item.operationId,
      recordId: item.recordId,
      revisionId: item.revisionId,
      operation: item.operation,
      deviceId: item.deviceId,
      keyEpoch: item.keyEpoch,
      membershipVersion: item.membershipVersion,
      envelopeSha256: item.envelopeSha256,
      envelopeShapeValid: item.envelopeShapeValid,
      ciphertextFieldsPresent: item.ciphertextFieldsPresent,
    })),
    results: event.results || [],
    markerFree: event.markerFree === true,
    responseProcessed: event.responseProcessed === true,
  };
}

function safeDiagnosticMessage(error) {
  let message = typeof error?.message === 'string' ? error.message : '';
  for (const value of [...MARKERS, ...clipboardSecrets]) {
    if (typeof value === 'string' && value) message = message.split(value).join('[REDACTED]');
  }
  return message
    .replace(/[A-Za-z0-9_-]{40,}/g, '[REDACTED_OPAQUE]')
    .replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[REDACTED_ACCOUNT]')
    .split('\n')[0]
    .slice(0, 320);
}

async function runScenario() {
  const result = {
    raceOrder: config.raceOrder,
    sourceNodes: { baseline: 'A', editor: 'B' },
    pageErrors: 0,
    consoleErrors: 0,
    unexpectedRequestErrors: 0,
  };
  setStage('register separate Owner and Editor accounts');
  await registerOwner(state.pageA);
  await registerEditor(state.pageB);
  setStage('activate Editor membership on the Owner Vault');
  await copyAndInviteEditor(state.pageB, state.pageA);
  setStage('create and sync the encrypted baseline Host');
  const baseline = await createOwnerHost(state.pageA);
  state.ownerVaultId = baseline.vaultId;
  result.vaultId = baseline.vaultId;
  result.recordId = baseline.recordId;
  result.baselineRevisionId = baseline.revisionId;
  result.baselineOperationId = baseline.operationId;
  result.baselineBatchId = baseline.batchId;
  result.baselinePushAttempt = baseline.pushAttempt;
  result.ownerDeviceId = baseline.deviceId;
  result.baselineCommitSeq = baseline.commitSeq;
  result.membershipVersionBefore = baseline.membershipVersion;
  result.keyEpochBefore = baseline.keyEpoch;
  await click(state.pageB, 'Hosts');
  await waitHostByName(state.pageB, config.hostName, true);
  setStage('persist one real encrypted Editor outbox update offline');
  const outboxBefore = await addEditorEditOffline(state.pageB, state.contextB, baseline);
  assertThat(outboxBefore.operations.length === 1,
    'Editor did not persist exactly one operation in its IndexedDB outbox');
  const pending = outboxBefore.operations[0];
  result.editorDeviceId = pending.deviceId;
  result.operationId = pending.operationId;
  result.revisionId = pending.revisionId;
  result.pendingBefore = {
    count: outboxBefore.operations.length,
    status: pending.status,
    attemptCount: pending.attemptCount,
    envelopeSha256: pending.envelopeSha256,
  };
  result.pendingCountBefore = outboxBefore.operations.length;
  result.pendingStatusBefore = pending.status;
  result.pendingNotReportedAsSynced = false;

  if (config.raceOrder === 'push_first') {
    setStage('commit the Editor outbox update through PostgreSQL node B');
    await state.contextB.setOffline(false);
    OFFLINE_PROFILES.delete('B');
    await waitFor(() => state.pageB.evaluate(() => navigator.onLine === true),
      'Editor profile to reconnect', 5000);
    const pushStart = PUSHES.length;
    await syncNow(state.pageB);
    const committed = await waitApiEvent(PUSHES, (event) => event.profile === 'B' &&
      event.operations?.some((item) => item.operationId === pending.operationId),
    'Editor push receipt', 90000);
    const attempts = PUSHES.slice(pushStart).filter((event) =>
      event.operations?.some((item) => item.operationId === pending.operationId));
    const operation = committed.operations.find((item) => item.operationId === pending.operationId);
    const receipt = committed.results?.find((item) => item.operationId === pending.operationId);
    assertThat(committed.sourceNode === 'B' && committed.status === 200 &&
      committed.errorCode == null && committed.markerFree && operation?.envelopeShapeValid &&
      operation.ciphertextFieldsPresent && operation.envelopeSha256 === pending.envelopeSha256 &&
      committed.operations.length === 1 &&
      receipt?.revisionId === pending.revisionId && receipt.alreadyCommitted === false &&
      /^\d+$/.test(receipt.commitSeq) && attempts.length === 1,
    'Editor push did not commit its exact pending signed envelope once through node B');
    await waitPendingCount(state.pageB, 0, 'Editor outbox to clear after its commit');
    const outboxAfterCommit = await snapshotOutbox(state.pageB, baseline.vaultId,
      baseline.recordId, 'after successful push');
    assertThat(outboxAfterCommit.operations.length === 0,
      'Editor outbox retained an operation after the successful receipt');
    result.pendingAfterPush = { count: 0, status: null };
    result.editorPushCommitSeq = receipt.commitSeq;
    result.pushAttempts = attempts.map((event) => safePushSummary(event, pending.operationId));
    await click(state.pageA, 'Hosts');
    await waitHostByName(state.pageA, config.editedHostName, true, 60000);
    await waitHostByName(state.pageA, config.hostName, false, 10000);
    result.ownerObservedHost = true;
    setStage('downgrade Editor to Viewer after the push receipt');
    const rotation = await rotateEditorToViewer(state.pageA);
    result.downgradeStatus = rotation.status;
    result.membershipVersionAfter = rotation.membershipVersion;
    result.keyEpochAfter = rotation.keyEpoch;
    result.editorRoleAfter = 'viewer';
    await waitForRoleOnEditor(state.pageB);
    result.pendingAfterFinal = { count: 0, status: null };
    result.pendingCountAfter = 0;
    result.pendingStatusAfter = null;
    result.pushCommittedBeforeDowngrade = true;
    result.outboxRetainedAfterRejected = false;
    result.editorSyncStateAfterRejected = null;
    result.pendingNotReportedAsSynced = false;
  } else {
    setStage('hold the Editor signed push in Chromium before PostgreSQL');
    const pushStart = PUSHES.length;
    const pushGate = holdEditorPush(pending.operationId);
    await state.contextB.setOffline(false);
    OFFLINE_PROFILES.delete('B');
    await waitFor(() => state.pageB.evaluate(() => navigator.onLine === true),
      'Editor profile to reconnect', 5000);
    await syncNow(state.pageB);
    await waitFor(() => pushGate.captured,
      'signed Editor push to be held while still in flight', 45000);
    const heldPush = PUSHES.slice(pushStart).find((event) =>
      event.profile === 'B' && event.operations?.some((item) =>
        item.operationId === pending.operationId));
    const heldOperation = heldPush?.operations?.find((item) =>
      item.operationId === pending.operationId);
    assertThat(heldPush && heldPush.status === null && heldPush.markerFree &&
      heldPush.batchId === pushGate.batchId &&
      heldOperation?.envelopeSha256 === pending.envelopeSha256,
    'Chromium did not hold the exact pending signed envelope before it reached PostgreSQL');
    setStage('commit Owner downgrade while Editor push remains in flight');
    const rotation = await rotateEditorToViewer(state.pageA);
    result.downgradeStatus = rotation.status;
    result.membershipVersionAfter = rotation.membershipVersion;
    result.keyEpochAfter = rotation.keyEpoch;
    result.editorRoleAfter = 'viewer';
    const outboxAfterDowngrade = await snapshotOutbox(state.pageB, baseline.vaultId,
      baseline.recordId, 'after offline downgrade');
    assertThat(outboxAfterDowngrade.operations.length === 1 &&
      samePendingRow(pending, outboxAfterDowngrade.operations[0]),
    'Owner role downgrade changed or removed the Editor outbox while it was offline');
    result.pendingAfterDowngrade = {
      count: outboxAfterDowngrade.operations.length,
      status: outboxAfterDowngrade.operations[0].status,
      attemptCount: outboxAfterDowngrade.operations[0].attemptCount,
      envelopeSha256: outboxAfterDowngrade.operations[0].envelopeSha256,
    };
    setStage('deliver the held Editor push after Owner downgrade commits');
    pushGate.release();
    const rejected = await waitApiEvent(PUSHES, (event) => event.profile === 'B' &&
      event.operations?.some((item) => item.operationId === pending.operationId),
    'Editor push rejection', 90000);
    const attempts = PUSHES.slice(pushStart).filter((event) =>
      event.operations?.some((item) => item.operationId === pending.operationId));
    const operation = rejected.operations.find((item) => item.operationId === pending.operationId);
    assertThat(rejected.sourceNode === 'B' && rejected.status === 403 &&
      rejected.errorCode === 'VAULT_READ_ONLY' && rejected.markerFree &&
      operation?.envelopeShapeValid && operation.ciphertextFieldsPresent &&
      operation.envelopeSha256 === pending.envelopeSha256 && rejected.operations.length === 1 &&
      attempts.length === 1 &&
      attempts.every((event) => event.status !== 200),
    'downgraded Editor push did not return the expected 403 VAULT_READ_ONLY failure');
    const outboxAfterReject = await snapshotOutbox(state.pageB, baseline.vaultId,
      baseline.recordId, 'after 403 VAULT_READ_ONLY');
    assertThat(outboxAfterReject.operations.length === 1 &&
      samePendingRow(pending, outboxAfterReject.operations[0]),
    'failed Editor push was removed, rewritten, or falsely acknowledged in IndexedDB');
    const statusCount = await pendingCount(state.pageB);
    const syncState = await pendingSyncState(state.pageB);
    assertThat(statusCount > 0 && ['read-only', 'error', 'pending'].includes(syncState),
      'Editor UI reported a synchronized state while the rejected operation remained pending');
    result.pendingAfterFinal = {
      count: outboxAfterReject.operations.length,
      status: outboxAfterReject.operations[0].status,
      attemptCount: outboxAfterReject.operations[0].attemptCount,
      envelopeSha256: outboxAfterReject.operations[0].envelopeSha256,
      uiPendingCount: statusCount,
    };
    result.pendingCountAfter = outboxAfterReject.operations.length;
    result.pendingStatusAfter = outboxAfterReject.operations[0].status;
    result.pushAttempts = attempts.map((event) => safePushSummary(event, pending.operationId));
    result.pushCommittedBeforeDowngrade = false;
    result.outboxRetainedAfterRejected = true;
    result.editorSyncStateAfterRejected = syncState;
    await click(state.pageA, 'Hosts');
    await waitHostByName(state.pageA, config.hostName, true);
    result.ownerObservedHost = !(await hostCard(state.pageA, config.editedHostName)
      .isVisible().catch(() => false));
    assertThat(result.ownerObservedHost,
      'Owner displayed the Editor update even though the push was rejected before commit');
    result.pendingNotReportedAsSynced = statusCount > 0 && syncState !== 'idle';
  }

  assertThat(Number(result.membershipVersionAfter) === Number(result.membershipVersionBefore) + 1 &&
    Number(result.keyEpochAfter) === Number(result.keyEpochBefore) + 1,
  'signed role downgrade did not increment membership version and key epoch exactly once');
  await new Promise((resolve) => setTimeout(resolve, 100));
  result.pageErrors = PAGE_ERRORS.length;
  result.consoleErrors = CONSOLE_ERRORS.length;
  result.expectedConsoleErrors = EXPECTED_CONSOLE_ERRORS.length;
  result.unexpectedRequestErrors = API_FAILURES.length +
    REQUEST_FAILURES.filter((failure) => !failure.expectedOffline).length;
  result.expectedRequestFailureCount = EXPECTED_REQUEST_FAILURES.length;
  result.offlineRequestErrors = REQUEST_FAILURES.filter((failure) => failure.expectedOffline).length;
  result.expectedPresenceRateLimits = EXPECTED_API_FAILURES.length;
  result.privacyMarkersAbsent = PUSHES.length >= 2 && PUSHES.every((event) => event.markerFree) &&
    SQLITE_SNAPSHOTS >= 2;
  result.sqliteSnapshotsChecked = SQLITE_SNAPSHOTS;
  assertThat(result.pageErrors === 0 && result.consoleErrors === 0 &&
    result.unexpectedRequestErrors === 0 && result.offlineRequestErrors <= 50 &&
    result.privacyMarkersAbsent,
  'Chromium observed a page/console error, unexpected request failure, or plaintext marker');
  result.browserCleanupComplete = false;
  return result;
}

async function cleanup() {
  if (state.cleaned) return;
  if (state.editorPushGate) state.editorPushGate.release();
  for (const context of [state.contextA, state.contextB]) {
    if (context) await context.close().catch(() => {});
  }
  if (state.browser) await state.browser.close().catch(() => {});
  for (const socket of state.proxySockets) socket.destroy();
  if (state.proxy && state.proxy.listening) {
    state.proxy.closeAllConnections?.();
    await new Promise((resolve) => state.proxy.close(resolve));
  }
  if (state.tempRoot && fs.existsSync(state.tempRoot)) {
    fs.rmSync(state.tempRoot, { recursive: true, force: true });
  }
  state.cleaned = true;
}

async function main() {
  assertConfig();
  state.tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-pg-membership-race-'));
  fs.chmodSync(state.tempRoot, 0o700);
  assertThat((fs.statSync(state.tempRoot).mode & 0o077) === 0,
    'runner scratch directory must be private');
  state.proxy = makeProxy();
  setStage('bind two-node routing proxy and launch Chromium');
  await new Promise((resolve, reject) => {
    state.proxy.once('error', reject);
    state.proxy.listen(state.base.port, '127.0.0.1', resolve);
  });
  state.proxyStarted = true;
  const launchOptions = {
    headless: true,
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  };
  state.browser = await chromium.launch(launchOptions);
  const contextOptions = { locale: 'en-US', viewport: { width: 1440, height: 1000 } };
  state.contextA = await state.browser.newContext(contextOptions);
  state.contextB = await state.browser.newContext(contextOptions);
  await Promise.all([
    state.contextA.setExtraHTTPHeaders({ 'x-pg-acceptance-profile': 'A' }),
    state.contextB.setExtraHTTPHeaders({ 'x-pg-acceptance-profile': 'B' }),
  ]);
  await Promise.all([state.contextA, state.contextB].map((context) =>
    context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: config.baseUrl })));
  state.pageA = await state.contextA.newPage();
  state.pageB = await state.contextB.newPage();
  await installEditorPushGate(state.pageB);
  observePage(state.pageA, 'A');
  observePage(state.pageB, 'B');
  apiEventFor(state.pageA, 'POST', /\/sync\/push$/i, PUSHES);
  apiEventFor(state.pageB, 'POST', /\/sync\/push$/i, PUSHES);
  apiEventFor(state.pageA, 'POST', /\/keys\/rotate$/i, ROTATIONS);
  setStage('load independent Chromium Web profiles');
  await Promise.all([openFlutter(state.pageA), openFlutter(state.pageB)]);
  assertThat(await state.pageA.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null &&
    await state.pageB.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null,
  'PostgreSQL profile-routing metadata leaked into Web local storage');
  const result = await runScenario();
  await cleanup();
  assertThat(state.cleaned && !state.proxy.listening && !state.browser.isConnected() &&
    !fs.existsSync(state.tempRoot), 'runner browser/proxy/scratch resources did not clean up');
  result.browserCleanupComplete = true;
  result.proxyCleanupComplete = !state.proxy.listening;
  result.tempSnapshotCleanupComplete = !fs.existsSync(state.tempRoot);
  console.log(`PG_MEMBERSHIP_PUSH_RACE_RESULT:${JSON.stringify(result)}`);
}

main().catch(async (error) => {
  const safeErrorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  const diagnostics = {
    raceOrder: config.raceOrder || null,
    stage: state.stage,
    failure: safeDiagnosticMessage(error),
    pushes: PUSHES.slice(-10).map((event) => safePushSummary(event)),
    rotations: ROTATIONS.slice(-4).map((item) => ({
      profile: item.profile, status: item.status, membershipVersion: item.membershipVersion,
      keyEpoch: item.keyEpoch, errorCode: item.errorCode || null,
    })),
    apiFailureCount: API_FAILURES.length,
    apiFailures: API_FAILURES.slice(-8),
    expectedPresenceRateLimits: EXPECTED_API_FAILURES.slice(-8),
    consoleErrorCount: CONSOLE_ERRORS.length,
    consoleErrorCategories: CONSOLE_ERRORS.slice(-8),
    expectedConsoleErrors: EXPECTED_CONSOLE_ERRORS.length,
    sqliteSnapshotsChecked: SQLITE_SNAPSHOTS,
    privacyMarkersAbsent: PUSHES.length >= 2 && PUSHES.every((event) => event.markerFree) &&
      SQLITE_SNAPSHOTS >= 2,
    requestFailureCount: REQUEST_FAILURES.length,
    expectedRequestFailures: EXPECTED_REQUEST_FAILURES.slice(-8),
    requestFailures: REQUEST_FAILURES.slice(-8).map((failure) => ({
      profile: failure.profile,
      method: failure.method,
      pathname: failure.pathname,
      errorClass: failure.errorText,
      expectedOffline: failure.expectedOffline,
    })),
    pageErrorCount: PAGE_ERRORS.length,
  };
  await cleanup();
  console.error(`PG_MEMBERSHIP_PUSH_RACE failed at ${state.stage} (${safeErrorClass}); fixture values omitted`);
  console.error(`safe diagnostics: ${JSON.stringify(diagnostics)}`);
  process.exitCode = 1;
});
