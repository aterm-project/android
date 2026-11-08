/*
 * Chromium acceptance for a PostgreSQL restore-generation cutover.
 *
 * The Python PG fixture owns both server processes and the isolated restore
 * target. This runner owns real Flutter Web profiles, a same-origin proxy,
 * and the READY/CONTINUE hand-off around the operator's node restart.
 *
 * Environment:
 *   ATERMIUS_PG_RESTORE_RECOVERY_NODE_A_URL
 *   ATERMIUS_PG_RESTORE_RECOVERY_NODE_B_URL
 *   ATERMIUS_PG_RESTORE_RECOVERY_USERNAME
 *   ATERMIUS_PG_RESTORE_RECOVERY_PASSWORD
 *   ATERMIUS_PG_RESTORE_RECOVERY_BOOTSTRAP_TOKEN
 *   ATERMIUS_PG_RESTORE_RECOVERY_HOST_NAME
 *   ATERMIUS_PG_RESTORE_RECOVERY_HOST_ADDRESS
 *   ATERMIUS_PG_RESTORE_RECOVERY_SSH_USERNAME
 *   ATERMIUS_PG_RESTORE_RECOVERY_READY_FILE
 *   ATERMIUS_PG_RESTORE_RECOVERY_CONTINUE_FILE
 *   PLAYWRIGHT_CHROMIUM_EXECUTABLE (optional)
 *
 * The ready file contains only random server-side IDs and digests. No account,
 * Host, credential, bearer, signed envelope, or database content is written
 * to stdout or to either hand-off file.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const PREFIX = 'ATERMIUS_PG_RESTORE_RECOVERY_';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const chromiumExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

const config = {
  nodeAUrl: process.env[`${PREFIX}NODE_A_URL`],
  nodeBUrl: process.env[`${PREFIX}NODE_B_URL`],
  baseUrl: process.env[`${PREFIX}BASE_URL`],
  username: process.env[`${PREFIX}USERNAME`],
  password: process.env[`${PREFIX}PASSWORD`],
  bootstrapToken: process.env[`${PREFIX}BOOTSTRAP_TOKEN`],
  hostName: process.env[`${PREFIX}HOST_NAME`],
  hostAddress: process.env[`${PREFIX}HOST_ADDRESS`],
  sshUsername: process.env[`${PREFIX}SSH_USERNAME`],
  readyFile: process.env[`${PREFIX}READY_FILE`],
  continueFile: process.env[`${PREFIX}CONTINUE_FILE`],
  workRoot: process.env[`${PREFIX}WORK_ROOT`],
};

const state = {
  stage: 'preflight',
  nodeA: null,
  nodeB: null,
  coordinatorGeneration: null,
  baseUrl: null,
  baseOrigin: null,
  proxy: null,
  proxyStarted: false,
  browser: null,
  contextA: null,
  contextB: null,
  pageA: null,
  pageB: null,
  tempRoot: null,
  profileBPath: null,
  readyWritten: false,
  continueObserved: false,
  operatorCutoverWindow: false,
  intentionalOfflinePushAborts: new WeakSet(),
  cleaned: false,
  blockBPush: true,
  allowReplayPush: false,
  recoverySnapshotStart: false,
  recoverySnapshotFetched: false,
  recoverySnapshotFetchedAtMs: null,
  recoverySnapshotId: null,
  snapshotVerifiedAtMs: null,
  serverGenerationBefore: null,
  serverGenerationAfter: null,
  instanceId: null,
  serverSpaceId: null,
  ownerToken: null,
  bToken: null,
  bDeviceId: null,
  vaultId: null,
  recordId: null,
  baselineRevisionId: null,
  oldSnapshotId: null,
  archivedRevisionId: null,
  laterRevisionId: null,
  laterCommitSeq: null,
  profileRestarted: false,
  baselineSeq: null,
  archivedSeq: null,
  backupJobId: null,
  restoreJobId: null,
  oldCursor: null,
  pendingBeforeRestart: null,
  pendingAfterProfileRestart: null,
  pendingAfterRestart: null,
  pendingAfterStaleCursor: null,
  pendingAfterStaleSnapshot: null,
  pendingAfter410: null,
  pendingEnvelope: null,
  pendingBatchId: null,
  pushEvents: [],
  apiEvents: [],
  adminPosts: [],
  adminGets: [],
  changesEvents: [],
  snapshotEvents: [],
  browserErrors: {
    page: { A: 0, B: 0 },
    failedApi: { A: 0, B: 0 },
    expectedOfflineApi: { A: 0, B: 0 },
    expectedOfflinePushAborts: 0,
  },
  recentFailures: [],
  generationGateVisible: false,
  staleCursorRejected: false,
  staleSnapshotRejected: false,
  noPreSnapshotPush: false,
  snapshotVerified: false,
  snapshotAppliedBeforeReplay: false,
  pendingOutboxCleared: false,
  pushAfterSnapshotVerified: false,
  replayStatus: null,
  replayCommitSeq: null,
  crossNodeRetryPassed: false,
  replayPushPaused: false,
  replayPushPausedAtMs: null,
  replayPushReleasePromise: null,
  releaseReplayPush: null,
  oldSnapshotGeneration: null,
};

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
    throw new Error(`${label} URL was invalid`);
  }
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
    Number(url.port) > 0 && url.pathname === '/' && !url.search && !url.hash &&
    !url.username && !url.password,
  `${label} must be an exact loopback HTTP origin`);
  return { origin: url.origin, hostname: url.hostname, port: Number(url.port) };
}

function assertConfig() {
  assertThat(Object.values(config).every((value) => typeof value === 'string' && value.length > 0),
    'PG restore-generation Chromium environment is incomplete');
  assertThat(config.password.length >= 12 && config.bootstrapToken.length >= 40,
    'PG restore-generation credentials do not meet the acceptance contract');
  assertThat(path.isAbsolute(config.readyFile) && path.isAbsolute(config.continueFile) &&
    config.readyFile !== config.continueFile,
  'PG restore-generation hand-off paths must be distinct absolute paths');
  const workRootStat = fs.lstatSync(config.workRoot);
  assertThat(workRootStat.isDirectory() && !workRootStat.isSymbolicLink() &&
    (workRootStat.mode & 0o077) === 0,
  'PG restore-generation work root must be a private nonsymlink directory');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web Release bundle is missing');
  assertThat(!fs.existsSync(config.readyFile) && !fs.existsSync(config.continueFile),
    'PG restore-generation hand-off paths must be fresh');
  state.nodeA = safeOrigin(config.nodeAUrl, 'Node A');
  state.nodeB = safeOrigin(config.nodeBUrl, 'Node B');
  const base = safeOrigin(config.baseUrl, 'Proxy bind');
  state.baseUrl = `${base.origin}/`;
  state.baseOrigin = base.origin;
}

function proxyTarget(profile) {
  return profile === 'B' ? state.nodeB : state.nodeA;
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url || '/', state.baseOrigin);
    if (request.method === 'GET' && url.pathname === '/__pg_restore_idb_probe__') {
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end('<!doctype html><title>Local storage probe</title>');
      return;
    }
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const profile = request.headers['x-atermius-e2e-profile'] === 'B' ? 'B' : 'A';
    const target = proxyTarget(profile);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-atermius-e2e-profile'];
    delete headers['x-atermius-e2e-stale-push'];
    const event = {
      profile,
      method: request.method || 'GET',
      path: url.pathname,
      node: profile,
      status: null,
      cursorPresent: url.searchParams.has('cursor'),
      cursorNonempty: Boolean(url.searchParams.get('cursor')),
      atMs: Date.now(),
      batchId: null,
      operationIds: [],
    };
    if (url.pathname.startsWith('/api/v1/')) state.apiEvents.push(event);
    let requestBodyBytes = 0;
    const requestBodyChunks = [];
    const isPushRequest = request.method === 'POST' && /\/sync\/push$/i.test(url.pathname);
    if (isPushRequest) {
      request.on('data', (chunk) => {
        requestBodyBytes += chunk.length;
        if (requestBodyBytes <= 2 * 1024 * 1024) requestBodyChunks.push(chunk);
      });
      request.on('end', () => {
        if (requestBodyBytes > 2 * 1024 * 1024) return;
        try {
          const payload = JSON.parse(Buffer.concat(requestBodyChunks).toString('utf8'));
          event.batchId = typeof payload?.batch_id === 'string' ? payload.batch_id : null;
          event.operationIds = Array.isArray(payload?.operations)
            ? payload.operations.map((item) => item?.header?.op_id)
              .filter((id) => typeof id === 'string')
            : [];
        } catch (_) { /* The proxy records only safe correlation fields. */ }
      });
    }
    const upstream = http.request({
      hostname: target.hostname,
      port: target.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      event.status = upstreamResponse.statusCode || null;
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
    upstream.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    request.pipe(upstream);
  });

  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', state.baseOrigin);
    const profile = request.headers['x-atermius-e2e-profile'] === 'B' ? 'B' : 'A';
    const target = proxyTarget(profile);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-atermius-e2e-profile'];
    const upstream = http.request({
      hostname: target.hostname,
      port: target.port,
      method: 'GET',
      path: `${url.pathname}${url.search}`,
      headers,
    });
    upstream.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      let head = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        head += `${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`;
      }
      clientSocket.write(`${head}\r\n`);
      if (clientHead?.length) upstreamSocket.write(clientHead);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstream.on('response', (upstreamResponse) => {
      clientSocket.write(`HTTP/1.1 ${upstreamResponse.statusCode || 502} ${upstreamResponse.statusMessage || 'Bad Gateway'}\r\n`);
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        clientSocket.write(`${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`);
      }
      clientSocket.write('\r\n');
      upstreamResponse.pipe(clientSocket);
    });
    upstream.on('error', () => clientSocket.destroy());
    clientSocket.on('close', () => upstream.destroy());
    upstream.end();
  });
  return server;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function envelopeIdentity(envelope) {
  const header = envelope?.header || {};
  return {
    opId: typeof header.op_id === 'string' ? header.op_id : null,
    vaultId: typeof header.vault_id === 'string' ? header.vault_id : null,
    recordId: typeof header.record_id === 'string' ? header.record_id : null,
    revisionId: typeof header.revision_id === 'string' ? header.revision_id : null,
    baseRevisionId: typeof header.base_revision_id === 'string' ? header.base_revision_id : null,
    deviceId: typeof header.device_id === 'string' ? header.device_id : null,
    operation: typeof header.operation === 'string' ? header.operation : null,
    envelopeSha256: digest(stableJson(envelope)),
  };
}

function observePage(page, profile) {
  const pendingRequests = new WeakMap();
  page.on('pageerror', () => { state.browserErrors.page[profile] += 1; });
  page.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (url.origin !== state.baseOrigin || !url.pathname.startsWith('/api/v1/')) return;
    const headersPromise = request.allHeaders().catch(() => ({}));
    const event = {
      profile,
      method: request.method(),
      path: url.pathname,
      node: profile,
      status: null,
      atMs: Date.now(),
      hasBearer: false,
      directStalePush: false,
      operatorCutoverWindow: state.operatorCutoverWindow,
      body: null,
    };
    pendingRequests.set(request, event);
    const requestHeaders = request.headers();
    event.hasBearer = /^Bearer\s+\S+/i.test(requestHeaders.authorization || '');
    event.directStalePush = requestHeaders['x-atermius-e2e-stale-push'] === '1';
    event.directStaleCursor = requestHeaders['x-atermius-e2e-stale-cursor'] === '1';
    event.directStaleSnapshot = requestHeaders['x-atermius-e2e-stale-snapshot'] === '1';
    void headersPromise.then((headers) => {
      event.hasBearer = /^Bearer\s+\S+/i.test(headers.authorization || '');
      event.directStalePush = headers['x-atermius-e2e-stale-push'] === '1';
      event.directStaleCursor = headers['x-atermius-e2e-stale-cursor'] === '1';
      event.directStaleSnapshot = headers['x-atermius-e2e-stale-snapshot'] === '1';
    });
    if (request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname)) {
      try {
        event.body = request.postDataJSON();
        event.operations = (event.body?.operations || []).map(envelopeIdentity);
        event.pushResult = null;
        state.pushEvents.push(event);
      } catch (_) {
        state.recentFailures.push({ profile, path: 'sync-push-body', atMs: Date.now() });
      }
    }
    if (request.method() === 'GET' && /\/changes$/i.test(url.pathname) && profile === 'B') {
      const vaultMatch = url.pathname.match(/\/api\/v1\/vaults\/([^/]+)\/changes$/i);
      state.changesEvents.push({
        atMs: event.atMs,
        node: profile,
        vaultId: vaultMatch?.[1] || null,
        cursorPresent: url.searchParams.has('cursor'),
        cursorNonempty: Boolean(url.searchParams.get('cursor')),
        status: null,
        nextCursor: null,
        events: [],
      });
      event.changeEvent = state.changesEvents[state.changesEvents.length - 1];
    }
    if (profile === 'B' && request.method() === 'POST' && /\/snapshots$/i.test(url.pathname)) {
      event.snapshotEvent = { atMs: event.atMs, node: profile, method: 'POST', status: null };
      state.snapshotEvents.push(event.snapshotEvent);
    }
    if (profile === 'B' && request.method() === 'GET' && /\/snapshots\/[0-9a-f-]+$/i.test(url.pathname)) {
      event.snapshotEvent = {
        atMs: event.atMs,
        node: profile,
        method: 'GET',
        status: null,
        requestedSnapshotId: url.pathname.split('/').at(-1),
      };
      state.snapshotEvents.push(event.snapshotEvent);
    }
    if (url.pathname === '/api/v1/admin/jobs' && profile === 'A' &&
        request.method() === 'POST') {
      const adminPost = { atMs: event.atMs, hasBearer: false, status: null, action: null, jobId: null };
      try { adminPost.action = request.postDataJSON()?.action || null; } catch (_) {}
      state.adminPosts.push(adminPost);
      event.adminPost = adminPost;
      void headersPromise.then((headers) => { adminPost.hasBearer = /^Bearer\s+\S+/i.test(headers.authorization || ''); });
    }
    if (url.pathname === '/api/v1/admin/jobs' && profile === 'A' && request.method() === 'GET') {
      state.adminGets.push({ atMs: event.atMs, hasBearer: false, status: null });
      event.adminGet = state.adminGets[state.adminGets.length - 1];
      void headersPromise.then((headers) => { event.adminGet.hasBearer = /^Bearer\s+\S+/i.test(headers.authorization || ''); });
    }
  });
  page.on('response', (response) => {
    const request = response.request();
    let url;
    try { url = new URL(response.url()); } catch (_) { return; }
    if (url.origin !== state.baseOrigin || !url.pathname.startsWith('/api/v1/')) return;
    const event = pendingRequests.get(request);
    if (event) event.status = response.status();
    const expectedStaleRead = profile === 'B' &&
      ((response.status() === 410 && request.method() === 'GET' &&
          /\/changes$/i.test(url.pathname) &&
          (event?.directStaleCursor ||
            url.searchParams.get('cursor') === state.oldCursor)) ||
        ((response.status() === 410 || response.status() === 404) &&
          request.method() === 'GET' && /\/snapshots\/[0-9a-f-]+$/i.test(url.pathname) &&
          event?.directStaleSnapshot));
    const expectedStalePush = profile === 'B' && request.method() === 'POST' &&
      /\/sync\/push$/i.test(url.pathname) && event?.directStalePush &&
      response.status() === 410;
    if (response.status() >= 400 && !expectedStaleRead && !expectedStalePush) {
      if (profile === 'A' && event?.operatorCutoverWindow &&
          [502, 503, 504].includes(response.status())) {
        state.browserErrors.expectedOfflineApi[profile] += 1;
      } else {
        state.browserErrors.failedApi[profile] += 1;
      }
    }
    if (event?.adminPost) event.adminPost.status = response.status();
    if (event?.adminGet) event.adminGet.status = response.status();
    if (event?.changeEvent) {
      event.changeEvent.status = response.status();
      void response.json().then((payload) => {
        event.changeEvent.nextCursor = typeof payload?.next_cursor === 'string'
          ? payload.next_cursor : null;
        event.changeEvent.events = Array.isArray(payload?.events)
          ? payload.events.map((item) => ({
            commitSeq: String(item?.commit_seq ?? ''),
            recordId: item?.record_id || null,
            revisionId: item?.revision_id || null,
          })) : [];
      }).catch(() => {});
    }
    if (event?.snapshotEvent) {
      event.snapshotEvent.status = response.status();
      void response.json().then((payload) => {
        event.snapshotEvent.snapshotId = payload?.snapshot_id ||
          event.snapshotEvent.requestedSnapshotId || null;
        event.snapshotEvent.highWatermark = String(payload?.high_watermark ?? '');
        event.snapshotEvent.nextCursor = payload?.next_cursor || null;
        event.snapshotEvent.serverGeneration = payload?.server_generation || null;
        event.snapshotEvent.errorCode = payload?.error?.code || payload?.code || null;
      }).catch(() => {});
    }
    if (event && request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname)) {
      event.status = response.status();
      void response.json().then((payload) => {
        event.pushResult = (Array.isArray(payload?.results) ? payload.results : []).map((item) => ({
          opId: item?.op_id || null,
          revisionId: item?.revision_id || null,
          commitSeq: String(item?.commit_seq ?? ''),
          alreadyCommitted: item?.already_committed === true,
        }));
      }).catch(() => { event.pushResult = []; });
    }
  });
  page.on('requestfailed', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (url.origin !== state.baseOrigin || !url.pathname.startsWith('/api/v1/')) return;
    const event = pendingRequests.get(request);
    if (profile === 'B' && request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname) &&
        state.intentionalOfflinePushAborts.has(request)) {
      state.browserErrors.expectedOfflinePushAborts += 1;
      return;
    }
    if (profile === 'A' && event?.operatorCutoverWindow) {
      state.browserErrors.expectedOfflineApi[profile] += 1;
    } else {
      state.browserErrors.failedApi[profile] += 1;
      state.recentFailures.push({ profile, path: url.pathname.slice(-80), atMs: Date.now() });
    }
  });
}

function newBrowserOptions() {
  return {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    serviceWorkers: 'block',
    ...(chromiumExecutable ? { executablePath: chromiumExecutable } : {}),
  };
}

function installBRoutes(context) {
  context.route('**/api/v1/vaults/*/sync/push', async (route) => {
    const headers = await route.request().allHeaders().catch(() => ({}));
  if (headers['x-atermius-e2e-stale-push'] === '1') {
      await route.continue();
      return;
    }
    if (state.blockBPush && !state.allowReplayPush) {
      state.intentionalOfflinePushAborts.add(route.request());
      await route.abort('internetdisconnected').catch(() => {});
      return;
    }
    if (state.recoverySnapshotStart && state.pendingBeforeRestart?.opId) {
      let operations = [];
      try { operations = route.request().postDataJSON()?.operations || []; } catch (_) {}
      if (operations.some((operation) =>
        operation?.header?.op_id === state.pendingBeforeRestart.opId)) {
        if (!state.replayPushReleasePromise) {
          state.replayPushPaused = true;
          state.replayPushPausedAtMs = Date.now();
          state.replayPushReleasePromise = new Promise((resolve) => {
            state.releaseReplayPush = resolve;
          });
        }
        await state.replayPushReleasePromise;
      }
    }
    await route.continue();
  });
  context.route('**/api/v1/vaults/*/snapshots', async (route) => {
    const response = await route.fetch();
    const responseBody = await response.body();
    if (state.recoverySnapshotStart && route.request().method() === 'POST' &&
        response.status() === 200) {
      try {
        const payload = JSON.parse(responseBody.toString('utf8'));
        state.recoverySnapshotId = typeof payload?.snapshot_id === 'string'
          ? payload.snapshot_id : null;
      } catch (_) { state.recoverySnapshotId = null; }
    }
    await route.fulfill({ response, body: responseBody });
  });
  context.route('**/api/v1/snapshots/*', async (route) => {
    const response = await route.fetch();
    const responseBody = await response.body();
    const requestedSnapshotId = new URL(route.request().url()).pathname.split('/').at(-1);
    if (state.recoverySnapshotStart && route.request().method() === 'GET' &&
        response.status() === 200 && state.recoverySnapshotId &&
        requestedSnapshotId === state.recoverySnapshotId) {
      state.recoverySnapshotFetched = true;
      state.recoverySnapshotFetchedAtMs = Date.now();
      state.allowReplayPush = true;
    }
    await route.fulfill({ response, body: responseBody });
  });
}

function configurePageObservers() {
  observePage(state.pageA, 'A');
  observePage(state.pageB, 'B');
}

async function waitFor(predicate, description, timeoutMs = 30000, page = state.pageA) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const result = await predicate();
      if (result) return result;
    } catch (_) { /* A transient Flutter frame can invalidate a locator. */ }
    if (page) await page.waitForTimeout(100).catch(() => {});
    else await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${description}`);
}

function fieldLocator(page, label) {
  return page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`);
}

async function field(page, label, timeoutMs = 20000) {
  const locator = fieldLocator(page, label);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      const item = locator.nth(index);
      if (await item.isVisible().catch(() => false)) return item;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`Web form field did not become visible: ${label}`);
}

async function button(page, label, timeoutMs = 20000) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`Web action did not become visible: ${label}`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function clickWorkspaceNavigation(page, label) {
  const name = label === 'Sync & conflicts'
    ? /^Sync & conflicts(?:\s+\d+)?$/ : label;
  const semanticButton = page.getByRole('button', {
    name,
    exact: typeof name === 'string',
  });
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    for (let index = 0; index < await semanticButton.count(); index += 1) {
      const candidate = semanticButton.nth(index);
      if (await candidate.isVisible().catch(() => false)) {
        await candidate.click();
        return;
      }
    }
    await page.waitForTimeout(100);
  }
  const visibleText = typeof name === 'string'
    ? page.getByText(name, { exact: true }).last()
    : page.getByText(name).last();
  await visibleText.waitFor({ state: 'visible', timeout: 15000 })
    .catch(() => { throw new Error(`workspace navigation item did not become visible: ${label}`); });
  await visibleText.scrollIntoViewIfNeeded();
  await visibleText.click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 18 });
    if (await locator.inputValue().catch(() => '') === value) {
      await locator.press('Tab');
      await page.waitForTimeout(80);
      if (await locator.inputValue().catch(() => '') === value) return;
    }
  }
  await locator.fill(value).catch(() => {});
  if (await locator.inputValue().catch(() => '') === value) return;
  throw new Error(`Web form field did not retain input: ${label}`);
}

async function initializeFlutter(page) {
  await page.goto(state.baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  'Flutter Web startup', 30000, page);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics tree', 15000, page);
}

async function connectToServer(page) {
  await fill(page, 'Server URL', state.baseUrl);
  await click(page, 'Connect securely');
}

async function waitWorkspace(page, timeoutMs = 45000) {
  await button(page, 'Add host', timeoutMs);
}

async function waitText(page, expected, timeoutMs = 30000) {
  await waitFor(() => page.evaluate((text) => {
    const body = document.body?.innerText || '';
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .map((node) => `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`).join('\n');
    return body.includes(text) || semantics.includes(text);
  }, expected).catch(() => false), `visible text ${expected}`, timeoutMs, page);
}

async function hostVisible(page, name, endpoint) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = page.getByRole('group', { name: new RegExp(`^Host: ${escaped}; `) }).first();
  return waitFor(async () => {
    const label = await card.getAttribute('aria-label').catch(() => '');
    return label?.startsWith(`Host: ${name}; `) && label.includes(`@${endpoint}`);
  }, 'Host card', 45000, page).then(() => true).catch(() => false);
}

async function waitPendingHostRow(page) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const row = await snapshotPendingRow(page, 'while waiting for the durable IndexedDB outbox');
      return row;
    } catch (_) { /* The local encrypted save may still be committing. */ }
    await page.waitForTimeout(250).catch(() => {});
  }
  throw new Error('timed out waiting for a durable IndexedDB Host operation');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function paste(page, label, value) {
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(180);
  if (await locator.inputValue().catch(() => '') !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `clipboard transfer failed for ${label}`);
}

function captureAuthResponse(page, endpoint, targetKey) {
  page.on('response', (response) => {
    let url;
    try { url = new URL(response.url()); } catch (_) { return; }
    if (url.origin !== state.baseOrigin || url.pathname !== endpoint ||
        response.status() < 200 || response.status() >= 300) return;
    void response.json().then((payload) => {
      if (typeof payload?.access_token === 'string' && payload.access_token.length > 20) {
        state[targetKey] = payload.access_token;
        if (targetKey === 'bToken' && UUID_RE.test(payload?.device_id || '')) {
          state.bDeviceId = payload.device_id;
        }
      }
    }).catch(() => {});
  });
}

function exactKeys(value, keys) {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value)) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function adminRequest(page, method, route, token, body) {
  return page.evaluate(async ({ method, route, token, body }) => {
    const response = await fetch(route, {
      method,
      headers: {
        accept: 'application/json',
        authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, payload: await response.json().catch(() => null) };
  }, { method, route, token, body });
}

async function waitAdminJob(page, token, jobId, timeoutMs = 120000) {
  return waitFor(async () => {
    const result = await adminRequest(page, 'GET', '/api/v1/admin/jobs?limit=100&offset=0', token);
    assertThat(result.status === 200 && Array.isArray(result.payload?.jobs),
      'authenticated PG administrator job listing failed');
    const job = result.payload.jobs.find((item) => item?.job_id === jobId);
    return job && ['succeeded', 'failed', 'interrupted'].includes(job.status) ? job : false;
  }, 'terminal PG administrator job', timeoutMs, page);
}

function validateJob(job, action, archiveId = null) {
  assertThat(exactKeys(job, [
    'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status',
    'requested_at', 'started_at', 'finished_at', 'result_code', 'restore_stage_status',
  ]) && UUID_RE.test(job.job_id) && UUID_RE.test(job.request_id) &&
    job.action === action && (archiveId === null || job.archive_id === archiveId),
  `PG ${action} job receipt was invalid`);
}

async function signInAndEnroll() {
  setStage('register Web owner and obtain its authenticated admin session');
  await initializeFlutter(state.pageA);
  await connectToServer(state.pageA);
  await fill(state.pageA, 'Owner email', config.username);
  await fill(state.pageA, 'Master password · 12+ characters', config.password);
  await fill(state.pageA, 'Confirm master password', config.password);
  await fill(state.pageA, 'One-time bootstrap token', config.bootstrapToken);
  await fill(state.pageA, 'Device name', 'PG restore recovery owner');
  await fill(state.pageA, 'First Vault', 'PG restore recovery Vault');
  captureAuthResponse(state.pageA, '/api/v1/auth/register', 'ownerToken');
  await click(state.pageA, 'Create owner account');
  config.bootstrapToken = '';
  await waitWorkspace(state.pageA);
  await waitFor(() => state.ownerToken, 'captured owner bearer from Web registration', 30000,
    state.pageA);

  setStage('enroll a real second Web device profile');
  await initializeFlutter(state.pageB);
  await connectToServer(state.pageB);
  await field(state.pageB, 'Email or username');
  await click(state.pageB, 'Add this device');
  await fill(state.pageB, 'Account email', config.username);
  await fill(state.pageB, 'Device name', 'PG restore recovery second device');
  await click(state.pageB, 'Generate request');
  await field(state.pageB, 'Copy this enrollment JSON');
  await click(state.pageB, 'Copy');
  const enrollmentJson = await readClipboard(state.pageB);
  assertThat(JSON.parse(enrollmentJson)?.format === 'atermius-device-enrollment-v1',
    'second Web profile did not create a valid device enrollment request');
  await state.pageB.evaluate(() => navigator.clipboard.writeText(''));
  await click(state.pageB, 'Close');

  await click(state.pageA, 'Devices');
  await click(state.pageA, 'Approve enrollment');
  await paste(state.pageA, 'Enrollment JSON', enrollmentJson);
  await click(state.pageA, 'Review keys');
  await click(state.pageA, 'Approve & seal keys');
  await click(state.pageA, 'Copy');
  const approvalJson = await readClipboard(state.pageA);
  assertThat(JSON.parse(approvalJson)?.format === 'atermius-device-approval-v1',
    'owner Web profile did not create a valid second-device approval');
  await state.pageA.evaluate(() => navigator.clipboard.writeText(''));
  await click(state.pageA, 'Done');
  await click(state.pageA, 'Hosts');

  await click(state.pageB, 'Import approval');
  await paste(state.pageB, 'Paste approval JSON', approvalJson);
  await click(state.pageB, 'Import device keys');
  captureAuthResponse(state.pageB, '/api/v1/auth/login', 'bToken');
  await fill(state.pageB, 'Email or username', config.username);
  await fill(state.pageB, 'Master password', config.password);
  await click(state.pageB, 'Sign in and unlock');
  await waitWorkspace(state.pageB);
  await waitFor(() => state.bToken && state.bDeviceId,
    'captured second-device Web login session', 30000, state.pageB);
  assertThat(state.ownerToken && state.bToken && UUID_RE.test(state.bDeviceId),
    'Web registration or second-device login omitted an authenticated device identity');
}

function currentPushEvents(profile, since, opId) {
  return state.pushEvents.slice(since).filter((event) => event.profile === profile &&
    event.operations?.some((operation) => operation.opId === opId));
}

async function waitPush(page, start, profile, opId, expectedStatus, description) {
  return waitFor(() => currentPushEvents(profile, start, opId)
    .find((event) => event.status === expectedStatus && event.pushResult),
  description, 45000, page);
}

async function addBaselineHost() {
  setStage('commit baseline Host on Node A and synchronize it to Node B');
  const endpoint = `${config.hostAddress}:22`;
  const beforeInstance = await adminRequest(state.pageA, 'GET', '/api/v1/instance', '');
  assertThat(beforeInstance.status === 200 &&
    UUID_RE.test(beforeInstance.payload?.generation || '') &&
    UUID_RE.test(beforeInstance.payload?.instance_id || '') &&
    UUID_RE.test(beforeInstance.payload?.server_space_id || ''),
  'initial PostgreSQL instance generation was unavailable');
  state.serverGenerationBefore = beforeInstance.payload.generation;
  state.instanceId = beforeInstance.payload.instance_id;
  state.serverSpaceId = beforeInstance.payload.server_space_id;

  await click(state.pageA, 'Add host');
  await fill(state.pageA, 'Display name', config.hostName);
  await fill(state.pageA, 'Hostname or IP', config.hostAddress);
  await fill(state.pageA, 'Port', '22');
  await fill(state.pageA, 'SSH username', config.sshUsername);
  const beforeCreate = state.pushEvents.length;
  await click(state.pageA, 'Save encrypted host');
  assertThat(await hostVisible(state.pageA, config.hostName, endpoint),
    'Node A did not render the encrypted baseline Host');
  const createRequest = await waitFor(() => state.pushEvents.slice(beforeCreate)
    .find((event) => event.profile === 'A' && event.operations?.some((operation) =>
      operation.operation === 'create')),
  'owner baseline sync push', 45000, state.pageA);
  const createOp = createRequest.operations.find((item) => item.operation === 'create');
  const createReceipt = await waitFor(() => createRequest.pushResult?.find((item) =>
    item.opId === createOp.opId), 'baseline Host commit receipt', 45000, state.pageA);
  assertThat(createRequest.node === 'A' && createRequest.status === 200 &&
    createReceipt?.commitSeq === '1' && createReceipt.alreadyCommitted === false &&
    UUID_RE.test(createOp.vaultId || '') && UUID_RE.test(createOp.recordId || '') &&
    UUID_RE.test(createOp.revisionId || ''),
  'baseline Host was not committed as sequence 1 through Node A');
  state.vaultId = createOp.vaultId;
  state.recordId = createOp.recordId;
  state.baselineRevisionId = createOp.revisionId;
  state.baselineSeq = createReceipt.commitSeq;

  await waitFor(() => hostVisible(state.pageB, config.hostName, endpoint),
    'Node B rendering the baseline Host', 60000, state.pageB);
  await clickWorkspaceNavigation(state.pageB, 'Sync & conflicts');
  await waitText(state.pageB, 'Sync health');
  await click(state.pageB, 'Sync now');
  await waitFor(() => state.changesEvents.some((event) => event.node === 'B' &&
    event.status === 200 && event.cursorPresent && event.cursorNonempty && event.nextCursor),
  'Node B persisted a cursor after the baseline pull', 30000, state.pageB);
  const baselineChanges = state.changesEvents.filter((event) => event.node === 'B' &&
    event.vaultId === state.vaultId && event.status === 200);
  state.oldCursor = baselineChanges.at(-1)?.nextCursor || null;
  assertThat(state.oldCursor, 'second Web device did not persist a nonempty baseline cursor');
  assertThat(baselineChanges.some((event) => event.nextCursor === state.oldCursor),
    'old changes cursor was not observed for the target Vault');
  const oldSnapshot = await uiApi(state.pageB, 'POST',
    `/api/v1/vaults/${state.vaultId}/snapshots`, { token: state.bToken });
  assertThat(oldSnapshot.status === 200 &&
    UUID_RE.test(oldSnapshot.payload?.snapshot_id || '') &&
    oldSnapshot.payload?.high_watermark === state.baselineSeq &&
    typeof oldSnapshot.payload?.next_cursor === 'string' &&
    oldSnapshot.payload.next_cursor.length > 0,
  'second Web device did not create an old-generation baseline snapshot');
  state.oldSnapshotId = oldSnapshot.payload.snapshot_id;
  const oldSnapshotManifest = await uiApi(state.pageB, 'GET',
    `/api/v1/snapshots/${state.oldSnapshotId}`, { token: state.bToken });
  assertThat(oldSnapshotManifest.status === 200 &&
    oldSnapshotManifest.payload?.snapshot_id === state.oldSnapshotId &&
    oldSnapshotManifest.payload?.server_generation === state.serverGenerationBefore &&
    oldSnapshotManifest.payload?.high_watermark === state.baselineSeq,
  'old snapshot handle was not readable at the original generation before backup');
  state.oldSnapshotGeneration = oldSnapshotManifest.payload.server_generation;
  await click(state.pageB, 'Hosts');

  state.archivedRevisionId = state.baselineRevisionId;
  state.archivedSeq = state.baselineSeq;
}

function hostGroup(page, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('group', { name: new RegExp(`^Host: ${escaped}; `) }).first();
}

async function editHostName(page, oldName, newName) {
  const card = hostGroup(page, oldName);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await field(page, 'Display name');
  await fill(page, 'Display name', newName);
  await click(page, 'Save encrypted host');
  assertThat(await hostVisible(page, newName, `${config.hostAddress}:22`),
    'updated Host card was not rendered');
}

async function readClientSqliteFiles(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') return { available: false };
    const databases = await indexedDB.databases();
    if (!databases.some((item) => item.name === 'atermius_vault')) return { available: false };
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('IndexedDB open failed'));
      request.onblocked = () => reject(new Error('IndexedDB open blocked'));
    });
    try {
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        return { available: false };
      }
      const tx = db.transaction('files', 'readonly');
      const rowsPromise = new Promise((resolve, reject) => {
        const request = tx.objectStore('files').getAll();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(new Error('SQLite file metadata read failed'));
      });
      const keysPromise = new Promise((resolve, reject) => {
        const request = tx.objectStore('files').getAllKeys();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(new Error('SQLite file keys read failed'));
      });
      const [rows, keys] = await Promise.all([rowsPromise, keysPromise]);
      const selected = rows.map((row, index) => ({
        id: Number(keys[index]), name: String(row?.name || ''), length: Number(row?.length),
      })).filter((row) => row.name === '/database' || row.name === '/database-journal');
      const database = selected.find((row) => row.name === '/database');
      if (!database || selected.some((row) => !Number.isSafeInteger(row.id) ||
          !Number.isSafeInteger(row.length) || row.length < 0 || row.length > 64 * 1024 * 1024)) {
        return { available: false };
      }
      const files = [];
      for (const file of selected) {
        const range = IDBKeyRange.bound([file.id, 0], [file.id, Number.MAX_SAFE_INTEGER]);
        const blocksTx = db.transaction('blocks', 'readonly');
        const blockKeysPromise = new Promise((resolve, reject) => {
          const request = blocksTx.objectStore('blocks').getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite block keys read failed'));
        });
        const valuesPromise = new Promise((resolve, reject) => {
          const request = blocksTx.objectStore('blocks').getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite block read failed'));
        });
        const [blockKeys, values] = await Promise.all([blockKeysPromise, valuesPromise]);
        const blocks = blockKeys.map((key, index) => {
          const value = values[index];
          let bytes;
          if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
          else if (ArrayBuffer.isView(value)) bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          else if (value instanceof Blob) return value.arrayBuffer().then((array) => {
            const data = new Uint8Array(array);
            let binary = '';
            for (let offset = 0; offset < data.length; offset += 0x8000) {
              binary += String.fromCharCode(...data.subarray(offset, offset + 0x8000));
            }
            return { offset: Number(key?.[1]), base64: btoa(binary) };
          });
          else throw new Error('unsupported IndexedDB block value');
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 0x8000) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
          }
          return { offset: Number(key?.[1]), base64: btoa(binary) };
        });
        files.push({ ...file, blocks: await Promise.all(blocks) });
      }
      return { available: true, files };
    } finally { db.close(); }
  });
}

function inspectPendingRow(files, allowEmpty = false) {
  const database = files.files?.find((file) => file.name === '/database');
  const journal = files.files?.find((file) => file.name === '/database-journal');
  assertThat(files.available && database && (!journal || journal.length === 0),
    'second-device IndexedDB SQLite snapshot was unavailable or had an active journal');
  const bytes = reconstructSqliteFile({
    fileId: database.id,
    name: database.name,
    length: database.length,
    blocks: database.blocks.map((block) => ({ offset: block.offset, bytes: Buffer.from(block.base64, 'base64') })),
  });
  for (const marker of [config.hostName, config.hostAddress, config.sshUsername]) {
    assertThat(!bytes.includes(Buffer.from(marker)),
      'second-device SQLite snapshot contained plaintext Host fields');
  }
  const filename = path.join(state.tempRoot, 'b-pending-outbox.sqlite');
  fs.writeFileSync(filename, bytes, { flag: 'w', mode: 0o600 });
  fs.chmodSync(filename, 0o600);
  const script = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "db.execute('PRAGMA query_only=ON')",
    'vault_id,record_id,instance_id,server_space_id=sys.argv[2:]',
    "rows=db.execute(\"SELECT op_id,vault_id,record_id,base_revision_id,base_envelope_json,envelope_json,status,attempt_count,created_at,last_attempt_at FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    'def h(value): return hashlib.sha256(value.encode()).hexdigest() if value is not None else None',
    'ops=[]',
    'for row in rows:',
    ' envelope=json.loads(row[5]); header=envelope.get("header",{})',
    ' ops.append({"opId":row[0],"vaultId":row[1],"recordId":row[2],"baseRevisionId":row[3],"baseEnvelopeSha256":h(row[4]),"envelopeJson":row[5],"envelopeSha256":h(row[5]),"revisionId":header.get("revision_id"),"operation":header.get("operation"),"deviceId":header.get("device_id"),"status":row[6],"attemptCount":row[7],"createdAt":row[8],"lastAttemptAt":row[9]})',
    'checkpoint=db.execute("SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=? AND instance_id=? AND server_space_id=?",(vault_id,instance_id,server_space_id)).fetchone()',
    'head=db.execute("SELECT revision_id,commit_seq,envelope_json FROM encrypted_records WHERE vault_id=? AND record_id=? AND instance_id=? AND server_space_id=?",(vault_id,record_id,instance_id,server_space_id)).fetchone()',
    'print(json.dumps({"integrity":db.execute("PRAGMA integrity_check").fetchone()[0],"operations":ops,"checkpoint":{"cursor":checkpoint[0],"serverGeneration":checkpoint[1]} if checkpoint else None,"head":{"revisionId":head[0],"commitSeq":head[1],"envelopeSha256":h(head[2])} if head else None},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', script, filename, state.vaultId,
      state.recordId, state.instanceId, state.serverSpaceId], {
      encoding: 'utf8', timeout: 15000, maxBuffer: 2 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only second-device outbox database inspection failed');
    const inspected = JSON.parse(result.stdout);
    assertThat(inspected.integrity === 'ok' &&
      (inspected.operations.length === 1 || (allowEmpty && inspected.operations.length === 0)),
    'second-device IndexedDB did not contain the expected active Host outbox row count');
    if (inspected.operations.length === 0) return null;
    const operation = inspected.operations[0];
    operation.recoveryCheckpoint = inspected.checkpoint;
    operation.cachedHead = inspected.head;
    operation.envelope = JSON.parse(operation.envelopeJson);
    operation.canonicalEnvelopeSha256 = digest(stableJson(operation.envelope));
    return operation;
  } finally { fs.rmSync(filename, { force: true }); }
}

async function snapshotPendingRow(page, label) {
  const snapshot = await readClientSqliteFiles(page);
  assertThat(snapshot.available && Array.isArray(snapshot.files),
    `second-device IndexedDB was unavailable ${label}`);
  const row = inspectPendingRow(snapshot);
  assertThat(row.opId && row.revisionId && row.baseRevisionId && row.envelopeSha256 &&
    row.operation === 'update' && row.vaultId === state.vaultId &&
    row.recordId === state.recordId && row.deviceId === state.bDeviceId,
  `pending encrypted Host operation metadata was invalid ${label}`);
  const envelope = row.envelope;
  assertThat(envelopeIdentity(envelope).opId === row.opId &&
    envelopeIdentity(envelope).revisionId === row.revisionId &&
    envelopeIdentity(envelope).baseRevisionId === row.baseRevisionId &&
    envelopeIdentity(envelope).envelopeSha256 === row.canonicalEnvelopeSha256,
  `pending signed envelope did not match its IndexedDB row ${label}`);
  assertThat(row.status === 'queued' || row.status === 'sent',
    `pending signed envelope was not replayable from its IndexedDB state ${label}`);
  for (const marker of [config.hostName, config.hostAddress, config.sshUsername]) {
    assertThat(!row.envelopeJson.includes(marker),
      `pending signed envelope exposed private Host data ${label}`);
  }
  return row;
}

async function waitForPendingOutboxClear(page) {
  return waitFor(async () => {
    const snapshot = await readClientSqliteFiles(page);
    if (!snapshot.available || !Array.isArray(snapshot.files)) return false;
    return inspectPendingRow(snapshot, true) === null;
  }, 'B IndexedDB Host outbox row to clear after replay', 45000, page);
}

function sameSignedOutboxEnvelope(left, right) {
  return Boolean(left && right) && [
    'opId', 'vaultId', 'recordId', 'baseRevisionId', 'baseEnvelopeSha256',
    'envelopeSha256', 'canonicalEnvelopeSha256', 'revisionId', 'operation',
    'deviceId', 'createdAt',
  ].every((key) => left[key] === right[key]);
}

function sameImmutableOutboxRow(left, right) {
  return sameSignedOutboxEnvelope(left, right) &&
    ['status', 'attemptCount', 'lastAttemptAt'].every((key) => left[key] === right[key]);
}

async function uiApi(page, method, route, { token, body, headers = {} } = {}) {
  return page.evaluate(async ({ method, route, token, body, headers }) => {
    const response = await fetch(route, {
      method,
      headers: {
        accept: 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
        ...headers,
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, payload: await response.json().catch(() => null) };
  }, { method, route, token: token || '', body, headers });
}

async function captureSecondDevicePush() {
  setStage('queue one encrypted B Host update with its push blocked');
  const before = state.pushEvents.length;
  const branchName = `${config.hostName} B pending`;
  await editHostName(state.pageB, config.hostName, branchName);
  await waitPendingHostRow(state.pageB);
  await waitFor(() => state.pushEvents.slice(before).some((event) =>
    event.profile === 'B' && !event.directStalePush &&
    event.operations?.some((op) => op.recordId === state.recordId)),
  'blocked B sync attempt for its encrypted Host edit', 30000, state.pageB);
  state.pendingBeforeRestart = await snapshotPendingRow(state.pageB, 'before profile restart');
  assertThat(state.pendingBeforeRestart.baseRevisionId === state.archivedRevisionId,
    'B pending Host operation did not branch from the baseline Host revision');
  state.pendingEnvelope = state.pendingBeforeRestart.envelope;
}

async function queueBackupAndRestoreStage() {
  setStage('enqueue and await a PostgreSQL backup through the captured Web administrator session');
  const capabilities = await adminRequest(state.pageA, 'GET',
    '/api/v1/admin/jobs?limit=10&offset=0', state.ownerToken);
  assertThat(capabilities.status === 200 &&
    Array.isArray(capabilities.payload?.supported_actions) &&
    capabilities.payload.supported_actions.includes('backup') &&
    capabilities.payload.supported_actions.includes('restore'),
  'authenticated Web administrator did not see configured PG backup and restore actions');
  const backupRequestId = crypto.randomUUID();
  const backupResponse = await adminRequest(state.pageA, 'POST', '/api/v1/admin/jobs',
    state.ownerToken, { request_id: backupRequestId, action: 'backup' });
  assertThat(backupResponse.status === 202 && backupResponse.payload?.job?.action === 'backup',
    'authenticated Web administrator backup request was not accepted');
  validateJob(backupResponse.payload.job, 'backup');
  state.backupJobId = backupResponse.payload.job.job_id;
  assertThat(backupResponse.payload.job.archive_id === state.backupJobId,
    'backup API did not bind its generated archive ID to the job ID');
  await waitFor(() => state.adminPosts.some((event) => event.action === 'backup' &&
    event.hasBearer && event.status === 202),
  'browser network capture did not observe the authenticated backup enqueue request');
  const backupTerminal = await waitAdminJob(state.pageA, state.ownerToken, state.backupJobId, 180000);
  validateJob(backupTerminal, 'backup');
  assertThat(backupTerminal.status === 'succeeded' &&
    backupTerminal.archive_id === state.backupJobId &&
    backupTerminal.result_code === 'completed',
  'PG backup job did not finish with its server-generated archive');

  setStage('commit a post-backup Node A edit that the restore stage will remove');
  const laterName = `${config.hostName} A later`;
  const laterStart = state.pushEvents.length;
  await editHostName(state.pageA, config.hostName, laterName);
  const laterPush = await waitFor(() => state.pushEvents.slice(laterStart)
    .find((event) => event.profile === 'A' && event.operations?.some((op) =>
      op.recordId === state.recordId)),
  'post-backup Node A edit push', 45000, state.pageA);
  const laterOp = laterPush.operations.find((op) => op.recordId === state.recordId);
  const laterReceipt = await waitFor(() => laterPush.pushResult?.find((item) =>
    item.opId === laterOp.opId), 'post-backup Node A edit receipt', 45000, state.pageA);
  assertThat(laterPush.status === 200 && laterPush.node === 'A' &&
    laterReceipt?.commitSeq === '2' && laterReceipt.alreadyCommitted === false,
  'post-backup Node A edit was not committed as sequence 2');
  state.laterRevisionId = laterOp.revisionId;
  state.laterCommitSeq = laterReceipt.commitSeq;

  setStage('enqueue and await isolated PostgreSQL restore staging');
  const restoreRequestId = crypto.randomUUID();
  const restoreResponse = await adminRequest(state.pageA, 'POST', '/api/v1/admin/jobs',
    state.ownerToken, {
      request_id: restoreRequestId,
      action: 'restore',
      archive_id: state.backupJobId,
      archive_source: 'local',
    });
  assertThat(restoreResponse.status === 202 && restoreResponse.payload?.job?.action === 'restore',
    'authenticated Web administrator restore-stage request was not accepted');
  validateJob(restoreResponse.payload.job, 'restore', state.backupJobId);
  state.restoreJobId = restoreResponse.payload.job.job_id;
  await waitFor(() => state.adminPosts.some((event) => event.action === 'restore' &&
    event.hasBearer && event.status === 202),
  'browser network capture did not observe the authenticated restore-stage request');
  const restoreTerminal = await waitAdminJob(state.pageA, state.ownerToken, state.restoreJobId, 240000);
  validateJob(restoreTerminal, 'restore', state.backupJobId);
  assertThat(restoreTerminal.status === 'succeeded' &&
    restoreTerminal.result_code === 'completed' &&
    restoreTerminal.restore_stage_status === 'ready',
  'PG restore worker did not publish a verified isolated ready stage');
}

function writeReadyAndWait() {
  assertThat(state.vaultId && state.recordId && state.backupJobId && state.restoreJobId &&
    state.pendingBeforeRestart?.opId && state.pendingBeforeRestart?.envelopeSha256 &&
    state.profileRestarted && state.baselineRevisionId && state.laterRevisionId &&
    state.laterCommitSeq && state.serverGenerationBefore,
  'restore-generation restart barrier metadata is incomplete');
  const document = {
    vaultId: state.vaultId,
    recordId: state.recordId,
    baselineRevisionId: state.baselineRevisionId,
    baselineCommitSeq: state.baselineSeq,
    laterRevisionId: state.laterRevisionId,
    laterCommitSeq: state.laterCommitSeq,
    oldGeneration: state.serverGenerationBefore,
    oldSnapshotId: state.oldSnapshotId,
    oldSnapshotGeneration: state.oldSnapshotGeneration,
    backupJobId: state.backupJobId,
    restoreJobId: state.restoreJobId,
    restoreStageGeneration: null,
    branchOpId: state.pendingBeforeRestart.opId,
    branchRevisionId: state.pendingBeforeRestart.revisionId,
    branchBaseRevisionId: state.pendingBeforeRestart.baseRevisionId,
    branchEnvelopeSha256: state.pendingBeforeRestart.envelopeSha256,
    profileRestarted: state.profileRestarted,
  };
  state.operatorCutoverWindow = true;
  const descriptor = fs.openSync(config.readyFile, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(document)}\n`);
    fs.fsyncSync(descriptor);
  } finally { fs.closeSync(descriptor); }
  fs.chmodSync(config.readyFile, 0o600);
  state.readyWritten = true;
  return waitFor(() => {
    try {
      const info = fs.lstatSync(config.continueFile);
      if (!info.isFile() || info.isSymbolicLink()) return false;
      const continuation = JSON.parse(fs.readFileSync(config.continueFile, 'utf8'));
      if (!exactKeys(continuation, ['nodeAUrl', 'nodeBUrl', 'generation']) ||
          !continuation.nodeAUrl || !continuation.nodeBUrl ||
          !UUID_RE.test(continuation.generation || '')) return false;
      return continuation;
    } catch (_) { return false; }
  }, 'coordinator to restart both PG nodes on the isolated target and signal continuation',
  300000, null).then((continuation) => {
    state.nodeA = safeOrigin(continuation.nodeAUrl, 'Continued Node A');
    state.nodeB = safeOrigin(continuation.nodeBUrl, 'Continued Node B');
    state.coordinatorGeneration = continuation.generation;
    assertThat(state.nodeA.origin !== state.baseOrigin && state.nodeB.origin !== state.baseOrigin,
      'continued PostgreSQL upstreams must remain separate from the Web proxy origin');
    state.continueObserved = true;
    state.operatorCutoverWindow = false;
  });
}

async function launchPersistentB() {
  state.contextB = await chromium.launchPersistentContext(state.profileBPath, {
    ...newBrowserOptions(),
  });
  await state.contextB.grantPermissions(['clipboard-read', 'clipboard-write'], {
    origin: state.baseOrigin,
  });
  await state.contextB.setExtraHTTPHeaders({ 'x-atermius-e2e-profile': 'B' });
  installBRoutes(state.contextB);
  state.pageB = state.contextB.pages()[0] || await state.contextB.newPage();
  observePage(state.pageB, 'B');
}

async function startupState(page) {
  const visible = async (locator) => locator.isVisible().catch(() => false);
  const [serverUrl, email, password, connect, signIn, unlock, addHost, continueVisible] =
    await Promise.all([
      visible(fieldLocator(page, 'Server URL')),
      visible(fieldLocator(page, 'Email or username')),
      visible(fieldLocator(page, 'Master password')),
      visible(page.getByRole('button', { name: 'Connect securely', exact: true })),
      visible(page.getByRole('button', { name: 'Sign in and unlock', exact: true })),
      visible(page.getByRole('button', { name: 'Unlock', exact: true })),
      visible(page.getByRole('button', { name: 'Add host', exact: true })),
      visible(page.getByRole('button', { name: 'Continue', exact: true })),
    ]);
  return { serverUrl, email, password, connect, signIn, unlock, addHost, continueVisible };
}

async function reconnectAndLoginB() {
  setStage('reopen persistent B profile and reauthenticate to restored PostgreSQL generation');
  await initializeFlutter(state.pageB);
  let loginSubmitted = false;
  let continueClicked = false;
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    if (await pageVisibleTextHas(state.pageB, 'Choose a workspace') &&
        await pageVisibleTextHas(state.pageB, 'Server account and sync')) {
      const next = state.pageB.getByRole('button', { name: 'Continue', exact: true });
      if (!continueClicked && await next.isVisible().catch(() => false)) {
        continueClicked = true;
        await next.click().catch(() => {});
      }
      await state.pageB.waitForTimeout(100);
      continue;
    }
    if (await button(state.pageB, 'Add host', 400).then(() => true).catch(() => false)) return;
    if (await fieldLocator(state.pageB, 'Server URL').first().isVisible().catch(() => false)) {
      await connectToServer(state.pageB);
      continue;
    }
    if (await fieldLocator(state.pageB, 'Email or username').first().isVisible().catch(() => false)) {
      if (loginSubmitted) {
        await state.pageB.waitForTimeout(150);
        continue;
      }
      captureAuthResponse(state.pageB, '/api/v1/auth/login', 'bToken');
      await fill(state.pageB, 'Email or username', config.username);
      await fill(state.pageB, 'Master password', config.password);
      await click(state.pageB, 'Sign in and unlock');
      loginSubmitted = true;
      continue;
    }
    if (await fieldLocator(state.pageB, 'Master password').first().isVisible().catch(() => false)) {
      if (!loginSubmitted) {
        await fill(state.pageB, 'Master password', config.password);
        const unlock = state.pageB.getByRole('button', { name: 'Unlock', exact: true });
        if (await unlock.isVisible().catch(() => false)) await unlock.click();
        else await click(state.pageB, 'Sign in and unlock');
        loginSubmitted = true;
      }
      await state.pageB.waitForTimeout(100);
      continue;
    }
    if (!continueClicked && await state.pageB.getByRole('button', {
      name: 'Continue', exact: true,
    }).isVisible().catch(() => false)) {
      continueClicked = true;
      await state.pageB.getByRole('button', { name: 'Continue', exact: true }).click().catch(() => {});
    }
    await state.pageB.waitForTimeout(100);
  }
  const visible = await startupState(state.pageB);
  throw new Error(`second-device restored-generation login timed out (${JSON.stringify(visible)})`);
}

async function pageVisibleTextHas(page, expected) {
  return page.evaluate((needle) => {
    const visible = [...document.querySelectorAll('flt-semantics')].filter((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    }).map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`).join('\n');
    return `${document.body?.innerText || ''}\n${visible}`.includes(needle);
  }, expected).catch(() => false);
}

async function assertRestoreGenerationAndRejectStalePush() {
  await waitWorkspace(state.pageB);
  await waitFor(() => state.bToken && state.bDeviceId,
    'fresh second-device authentication token after restore', 30000, state.pageB);
  const instanceA = await uiApi(state.pageA, 'GET', '/api/v1/instance');
  const instanceB = await uiApi(state.pageB, 'GET', '/api/v1/instance');
  assertThat(instanceA.status === 200 && instanceB.status === 200 &&
    UUID_RE.test(instanceA.payload?.generation || '') &&
    instanceA.payload.generation === instanceB.payload.generation &&
    instanceA.payload.generation !== state.serverGenerationBefore,
  'both live proxied PG nodes did not report the same restored generation');
  state.serverGenerationAfter = instanceA.payload.generation;
  assertThat(state.serverGenerationAfter === state.coordinatorGeneration,
    'observed server generation did not match the coordinator-provided restore-stage generation');

  const staleCursor = await uiApi(state.pageB, 'GET',
    `/api/v1/vaults/${state.vaultId}/changes?cursor=${encodeURIComponent(state.oldCursor)}&limit=10`, {
      token: state.bToken,
      headers: { 'x-atermius-e2e-stale-cursor': '1' },
    });
  state.staleCursorRejected = staleCursor.status === 410 &&
    (staleCursor.payload?.error?.code || staleCursor.payload?.code) === 'CURSOR_EXPIRED';
  assertThat(state.staleCursorRejected,
    'Node B did not reject the old-generation changes cursor with CURSOR_EXPIRED');
  state.pendingAfterStaleCursor = await snapshotPendingRow(state.pageB,
    'after stale cursor rejection');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart, state.pendingAfterStaleCursor),
    'stale cursor rejection changed the signed IndexedDB outbox envelope');

  const staleSnapshot = await uiApi(state.pageB, 'GET',
    `/api/v1/snapshots/${state.oldSnapshotId}`, {
      token: state.bToken,
      headers: { 'x-atermius-e2e-stale-snapshot': '1' },
    });
  const staleSnapshotCode = staleSnapshot.payload?.error?.code || staleSnapshot.payload?.code || null;
  state.staleSnapshotRejected = state.oldSnapshotGeneration === state.serverGenerationBefore &&
    Boolean(state.oldSnapshotId) &&
    (staleSnapshot.status === 404 && staleSnapshotCode === 'NOT_FOUND' ||
    (staleSnapshot.status === 410 &&
      staleSnapshotCode === 'SNAPSHOT_EXPIRED'));
  assertThat(state.staleSnapshotRejected,
    'Node B accepted a snapshot handle created before restore-generation cutover');
  state.pendingAfterStaleSnapshot = await snapshotPendingRow(state.pageB,
    'after stale snapshot rejection');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart, state.pendingAfterStaleSnapshot),
    'stale snapshot rejection changed the signed IndexedDB outbox envelope');

  const appPushesBeforeGate = state.pushEvents.filter((event) => event.profile === 'B' &&
    !event.directStalePush).length;
  await clickWorkspaceNavigation(state.pageB, 'Sync & conflicts');
  await waitText(state.pageB, 'Sync health');
  await click(state.pageB, 'Sync now');
  await waitFor(async () => await button(state.pageB, 'Rebuild snapshot', 500).then((item) =>
    item.isEnabled().catch(() => false)).catch(() => false),
  'B generation-mismatch recovery gate', 60000, state.pageB);
  const mismatchVisible = await pageVisibleTextHas(state.pageB, 'Generation mismatch') ||
    await pageVisibleTextHas(state.pageB, 'Snapshot needed');
  assertThat(mismatchVisible, 'B Web Sync Health did not explain the restored generation mismatch');
  const noAppPushBeforeSnapshot = state.pushEvents.filter((event) => event.profile === 'B' &&
    !event.directStalePush).length === appPushesBeforeGate;
  assertThat(noAppPushBeforeSnapshot,
    'B Web attempted to push its old-generation pending envelope before snapshot recovery');
  state.generationGateVisible = mismatchVisible;
  state.noPreSnapshotPush = noAppPushBeforeSnapshot;

  state.pendingAfterRestart = await snapshotPendingRow(state.pageB, 'after profile restart and login');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart, state.pendingAfterRestart),
    'the exact signed pending outbox row changed across persistent B profile restart');

  setStage('prove the restored server rejects the unchanged old-generation signed outbox');
  const body = {
    protocol_version: 1,
    server_generation: state.serverGenerationBefore,
    vault_id: state.vaultId,
    device_id: state.bDeviceId,
    batch_id: crypto.randomUUID(),
    operations: [state.pendingAfterRestart.envelope],
  };
  state.pendingBatchId = body.batch_id;
  const rejected = await uiApi(state.pageB, 'POST',
    `/api/v1/vaults/${state.vaultId}/sync/push`, {
      token: state.bToken,
      body,
      headers: { 'x-atermius-e2e-stale-push': '1' },
    });
  const rejectionCode = rejected.payload?.error?.code || rejected.payload?.code || null;
  assertThat(rejected.status === 410 && rejectionCode === 'SERVER_GENERATION_CHANGED',
    'Node B did not reject the signed stale-generation push with SERVER_GENERATION_CHANGED');
  const staleEvent = state.pushEvents.find((event) => event.profile === 'B' &&
    event.directStalePush && event.operations?.some((operation) =>
      operation.opId === state.pendingBeforeRestart.opId));
  assertThat(staleEvent?.node === 'B' && staleEvent.status === 410 && staleEvent.hasBearer,
    'browser capture did not observe an authenticated stale push rejection from Node B');
  state.pendingAfter410 = await snapshotPendingRow(state.pageB, 'after HTTP 410 rejection');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart, state.pendingAfter410),
    'SERVER_GENERATION_CHANGED mutated the signed IndexedDB outbox row');
}

async function rebuildSnapshotAndReplayOnce() {
  setStage('rebuild a fresh-generation snapshot and replay the preserved operation');
  state.recoverySnapshotStart = true;
  state.recoverySnapshotFetched = false;
  state.recoverySnapshotFetchedAtMs = null;
  state.recoverySnapshotId = null;
  state.allowReplayPush = false;
  const pushStart = state.pushEvents.length;
  const snapshotStart = state.snapshotEvents.length;
  await waitFor(() => button(state.pageB, 'Rebuild snapshot', 500)
    .then((item) => item.isEnabled().catch(() => false)).catch(() => false),
  'B snapshot recovery action to become available after its generation gate', 60000, state.pageB);
  const rebuild = await button(state.pageB, 'Rebuild snapshot');
  assertThat(await rebuild.isEnabled(), 'B snapshot recovery action remained disabled');
  await rebuild.click();
  await waitFor(() => {
    const events = state.snapshotEvents.slice(snapshotStart);
    const created = events.find((event) => event.node === 'B' &&
      event.method === 'POST' && event.status === 200);
    const fetched = events.find((event) => event.node === 'B' &&
      event.method === 'GET' && event.status === 200 &&
      event.requestedSnapshotId === created?.snapshotId);
    return Boolean(created && created.snapshotId === state.recoverySnapshotId &&
      created.highWatermark === state.archivedSeq && created.nextCursor &&
      fetched && fetched.snapshotId === created.snapshotId &&
      fetched.highWatermark === state.archivedSeq &&
      fetched.serverGeneration === state.serverGenerationAfter);
  },
  'Node B created the archived-head snapshot and verified its restored-generation manifest',
  60000, state.pageB);
  await waitFor(() => state.recoverySnapshotFetched,
    'Node B fetched and verified the restored snapshot manifest', 60000, state.pageB);
  await waitFor(() => state.replayPushPaused,
    'B to finish local snapshot activation before the replay request reaches PostgreSQL',
    60000, state.pageB);
  const createdSnapshot = state.snapshotEvents.slice(snapshotStart).find((event) =>
    event.node === 'B' && event.method === 'POST' && event.status === 200);
  const fetchedSnapshot = state.snapshotEvents.slice(snapshotStart).find((event) =>
    event.node === 'B' && event.method === 'GET' && event.status === 200 &&
    event.requestedSnapshotId === createdSnapshot?.snapshotId);
  assertThat(createdSnapshot?.snapshotId && fetchedSnapshot?.nextCursor,
    'matched recovery snapshot manifest was not available at the replay barrier');
  const localRecoveryState = await snapshotPendingRow(state.pageB,
    'while the post-snapshot replay is held before the server');
  const checkpointGenerationMatches =
    localRecoveryState.recoveryCheckpoint?.serverGeneration === state.serverGenerationAfter;
  const checkpointCursorMatches =
    localRecoveryState.recoveryCheckpoint?.cursor === fetchedSnapshot.nextCursor;
  const pendingHeadMatches =
    localRecoveryState.cachedHead?.revisionId === state.pendingBeforeRestart.revisionId &&
    localRecoveryState.cachedHead?.commitSeq == null &&
    localRecoveryState.cachedHead?.envelopeSha256 === state.pendingBeforeRestart.envelopeSha256;
  const pendingAttemptMetadataMonotonic =
    Number.isInteger(localRecoveryState.attemptCount) &&
    localRecoveryState.attemptCount >= state.pendingBeforeRestart.attemptCount;
  assertThat(sameSignedOutboxEnvelope(state.pendingBeforeRestart, localRecoveryState) &&
    pendingAttemptMetadataMonotonic &&
    checkpointGenerationMatches && checkpointCursorMatches && pendingHeadMatches,
  `durable IndexedDB snapshot/outbox state mismatch before replay ` +
    `(generation=${checkpointGenerationMatches}, cursor=${checkpointCursorMatches}, ` +
    `pendingHead=${pendingHeadMatches}, envelope=${sameSignedOutboxEnvelope(state.pendingBeforeRestart, localRecoveryState)}, ` +
    `attemptMetadataMonotonic=${pendingAttemptMetadataMonotonic})`);
  state.snapshotAppliedBeforeReplay = true;
  state.snapshotVerified = true;
  state.snapshotVerifiedAtMs = state.recoverySnapshotFetchedAtMs;
  const prematureReplay = state.pushEvents.slice(pushStart).some((event) =>
    event.profile === 'B' && !event.directStalePush &&
    event.operations?.some((operation) => operation.opId === state.pendingBeforeRestart.opId) &&
    event.atMs <= state.snapshotVerifiedAtMs);
  assertThat(!prematureReplay,
    'B attempted to replay the preserved operation before receiving its verified snapshot manifest');
  state.recoverySnapshotStart = false;
  state.allowReplayPush = true;
  state.releaseReplayPush();
  state.releaseReplayPush = null;
  state.replayPushReleasePromise = null;
  await waitText(state.pageB, '快照恢复完成', 90000).catch(async () => {
    await waitText(state.pageB, 'Snapshot recovery complete', 15000);
  });
  await waitFor(() => state.pushEvents.slice(pushStart).some((event) =>
    event.profile === 'B' && !event.directStalePush && event.status === 200 &&
    event.operations?.some((operation) => operation.opId === state.pendingBeforeRestart.opId)),
  'B post-snapshot replay push', 60000, state.pageB);
  const replayEvents = state.pushEvents.slice(pushStart).filter((event) =>
    event.profile === 'B' && !event.directStalePush &&
    event.operations?.some((operation) => operation.opId === state.pendingBeforeRestart.opId));
  assertThat(replayEvents.length === 1 && replayEvents[0].status === 200,
    'B did not make exactly one successful post-snapshot push attempt for the preserved operation');
  const replay = replayEvents[0];
  const replayOp = replay.operations.find((operation) =>
    operation.opId === state.pendingBeforeRestart.opId);
  const receipt = await waitFor(() => replay.pushResult?.find((item) =>
    item.opId === replayOp.opId), 'B replay commit receipt', 30000, state.pageB);
  const expectedSeq = (BigInt(state.baselineSeq) + 1n).toString();
  const replayProof = {
    nodeB: replay.node === 'B',
    status200: replay.status === 200,
    authenticated: replay.hasBearer === true,
    sameCanonicalEnvelope: replayOp.envelopeSha256 ===
      state.pendingBeforeRestart.canonicalEnvelopeSha256,
    sameRevision: replayOp.revisionId === state.pendingBeforeRestart.revisionId,
    receiptRevision: receipt?.revisionId === state.pendingBeforeRestart.revisionId,
    commitSeq2: receipt?.commitSeq === expectedSeq,
    firstCommit: receipt?.alreadyCommitted === false,
  };
  assertThat(Object.values(replayProof).every(Boolean),
    `unchanged B operation did not commit exactly once at initial baseline + 1 ` +
    `(${JSON.stringify(replayProof)})`);
  state.replayStatus = replay.status;
  state.replayCommitSeq = receipt.commitSeq;
  state.pushAfterSnapshotVerified = replay.atMs > state.snapshotVerifiedAtMs;
  assertThat(state.pushAfterSnapshotVerified && state.snapshotAppliedBeforeReplay,
    'B replay push did not follow durable local snapshot activation');

  state.pendingOutboxCleared = await waitForPendingOutboxClear(state.pageB);
  assertThat(state.pendingOutboxCleared, 'B pending outbox did not drain after replay');

  const crossNodeRetry = await uiApi(state.pageA, 'POST',
    `/api/v1/vaults/${state.vaultId}/sync/push`, {
      token: state.bToken,
      body: replay.body,
    });
  const retryReceipt = crossNodeRetry.payload?.results?.find((item) =>
    item?.op_id === state.pendingBeforeRestart.opId);
  const retryEvent = state.apiEvents.find((event) => event.profile === 'A' &&
    event.method === 'POST' && event.path.endsWith('/sync/push') &&
    event.status === 200 && event.node === 'A' && event.atMs >= replay.atMs &&
    event.batchId === replay.body?.batch_id &&
    event.operationIds.includes(state.pendingBeforeRestart.opId));
  assertThat(crossNodeRetry.status === 200 && retryEvent &&
    retryReceipt?.revision_id === state.pendingBeforeRestart.revisionId &&
    String(retryReceipt.commit_seq) === expectedSeq && retryReceipt.already_committed === true,
  'Node A retry did not converge on Node B’s one committed operation receipt');
  state.crossNodeRetryPassed = true;

  const snapshot = state.snapshotEvents.slice(snapshotStart).find((event) =>
    event.status === 200 && event.snapshotId);
  assertThat(snapshot?.nextCursor, 'recovery snapshot omitted its next cursor');
  const changes = await uiApi(state.pageA, 'GET',
    `/api/v1/vaults/${state.vaultId}/changes?cursor=${encodeURIComponent(snapshot.nextCursor)}&limit=10`,
    { token: state.bToken });
  const changesEvent = state.apiEvents.slice().reverse().find((event) =>
    event.profile === 'A' && event.method === 'GET' &&
    event.path.endsWith('/changes') && event.status === 200 && event.node === 'A');
  const committedEvents = changes.payload?.events || [];
  assertThat(changes.status === 200 && changesEvent && committedEvents.length === 1 &&
    String(committedEvents[0]?.commit_seq) === expectedSeq &&
    committedEvents[0]?.revision_id === state.pendingBeforeRestart.revisionId,
  'Node A did not read exactly one post-snapshot replay event committed through Node B');
  state.recoverySnapshotStart = false;
}

async function cleanup() {
  if (state.releaseReplayPush) {
    state.releaseReplayPush();
    state.releaseReplayPush = null;
  }
  const contexts = [state.contextA, state.contextB].filter(Boolean);
  const contextResults = await Promise.allSettled(contexts.map((context) => context.close()));
  let browserClosed = true;
  if (state.browser) browserClosed = await state.browser.close().then(() => true, () => false);
  let proxyClosed = true;
  if (state.proxyStarted) {
    proxyClosed = await new Promise((resolve) => {
      state.proxy.close(() => resolve(true));
      setTimeout(() => resolve(false), 5000).unref();
    });
    state.proxyStarted = false;
  }
  let tempRemoved = true;
  if (state.tempRoot) {
    try { fs.rmSync(state.tempRoot, { recursive: true, force: true }); }
    catch (_) { tempRemoved = false; }
  }
  let handoffFilesRemoved = true;
  for (const filename of [config.readyFile, config.continueFile]) {
    try {
      if (!fs.existsSync(filename)) continue;
      const stat = fs.lstatSync(filename);
      if (!stat.isFile() || stat.isSymbolicLink()) {
        handoffFilesRemoved = false;
        continue;
      }
      fs.unlinkSync(filename);
    } catch (_) { handoffFilesRemoved = false; }
  }
  state.cleaned = contextResults.every((item) => item.status === 'fulfilled') &&
    browserClosed && proxyClosed && tempRemoved && handoffFilesRemoved &&
    !state.proxy?.listening;
  return state.cleaned;
}

function resultDocument() {
  const pending = state.pendingBeforeRestart;
  const stale = state.pushEvents.find((event) => event.profile === 'B' &&
    event.directStalePush && event.status === 410 &&
    event.operations?.some((operation) => operation.opId === pending?.opId));
  const replay = state.pushEvents.filter((event) => event.profile === 'B' &&
    !event.directStalePush && event.status === 200 &&
    event.operations?.some((operation) => operation.opId === pending?.opId));
  const retry = state.crossNodeRetryPassed;
  const outboxIdentical = sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfterProfileRestart) && sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfterRestart) && sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfterStaleCursor) && sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfterStaleSnapshot) && sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfter410);
  const replayReceipt = replay[0]?.pushResult?.find((item) => item.opId === pending?.opId);
  return {
    passed: Boolean(state.continueObserved && state.serverGenerationBefore &&
      state.serverGenerationAfter && state.serverGenerationBefore !== state.serverGenerationAfter &&
      state.serverGenerationAfter === state.coordinatorGeneration &&
      state.generationGateVisible && state.staleCursorRejected &&
      state.oldSnapshotGeneration === state.serverGenerationBefore &&
      state.staleSnapshotRejected && state.noPreSnapshotPush && outboxIdentical &&
      state.snapshotVerified && state.snapshotAppliedBeforeReplay &&
      state.pendingOutboxCleared && stale &&
      state.pushAfterSnapshotVerified && replay.length === 1 && retry),
    generationGateShown: state.generationGateVisible,
    noPushBeforeSnapshot: state.noPreSnapshotPush,
    snapshotCreatedAndVerified: state.snapshotVerified,
    snapshotAppliedBeforeReplay: state.snapshotAppliedBeforeReplay,
    pendingOutboxCleared: state.pendingOutboxCleared,
    pushAfterSnapshotVerified: state.pushAfterSnapshotVerified,
    staleGenerationGateVisible: state.generationGateVisible,
    staleCursorRejected: state.staleCursorRejected,
    staleSnapshotRejected: state.staleSnapshotRejected,
    staleSnapshotCreatedBeforeCutover: Boolean(state.oldSnapshotId &&
      state.oldSnapshotGeneration === state.serverGenerationBefore),
    noPreSnapshotPush: state.noPreSnapshotPush,
    outboxIdenticalAcrossRestartAndRejection: Boolean(outboxIdentical),
    snapshotVerified: state.snapshotVerified,
    pendingReplayCountExactlyOne: replay.length === 1,
    replayStatus: state.replayStatus,
    replayCommitSeq: state.replayCommitSeq,
    idempotentCrossNodeRetryPassed: Boolean(retry),
    nodeAAndBShareRestoredGeneration: Boolean(state.serverGenerationAfter &&
      state.serverGenerationAfter === state.coordinatorGeneration),
    generationChanged: Boolean(state.serverGenerationBefore && state.serverGenerationAfter &&
      state.serverGenerationBefore !== state.serverGenerationAfter),
    baselineCommitSeq: state.baselineSeq,
    laterCommitSeq: state.laterCommitSeq,
    archivedHeadSeq: state.archivedSeq,
    expectedReplaySeq: state.baselineSeq && (BigInt(state.baselineSeq) + 1n).toString(),
    staleGenerationRejected: Boolean(stale),
    profileRestarted: state.profileRestarted,
    restoreStageGeneration: state.serverGenerationAfter,
    backupJobId: state.backupJobId,
    restoreJobId: state.restoreJobId,
    readyBarrierUsed: state.readyWritten && state.continueObserved,
    browserPageErrors: state.browserErrors.page,
    browserApiFailures: state.browserErrors.failedApi,
    expectedOfflineApiFailures: state.browserErrors.expectedOfflineApi,
    expectedOfflinePushAborts: state.browserErrors.expectedOfflinePushAborts,
    cleanupPassed: state.cleaned,
    vaultId: state.vaultId,
    recordId: state.recordId,
    pendingOperationId: pending?.opId || null,
    pendingEnvelopeSha256: pending?.envelopeSha256 || null,
    replayOperationId: replay[0]?.operations?.find((item) => item.opId === pending?.opId)?.opId || null,
    replayReceiptStatus: replay[0]?.status || null,
    replayReceiptCommitSeq: replayReceipt?.commitSeq || null,
  };
}

async function main() {
  assertConfig();
  const health = await Promise.all([state.nodeA, state.nodeB].map(async (node) => {
    const response = await fetch(`${node.origin}/health/ready`, { signal: AbortSignal.timeout(3000) });
    return response.status === 200;
  }));
  assertThat(health.every(Boolean), 'one or both PostgreSQL HTTP nodes were not ready');

  state.tempRoot = fs.mkdtempSync(path.join(config.workRoot, 'chromium-profile-'));
  fs.chmodSync(state.tempRoot, 0o700);
  state.profileBPath = path.join(state.tempRoot, 'profile-b');
  fs.mkdirSync(state.profileBPath, { mode: 0o700 });
  const port = Number(new URL(state.baseUrl).port);
  assertThat(Number.isInteger(port) && port > 0,
    'PG restore-generation proxy bind origin omitted its loopback port');
  state.proxy = makeProxy();
  await new Promise((resolve, reject) => {
    state.proxy.once('error', reject);
    state.proxy.listen(port, '127.0.0.1', resolve);
  });
  state.proxyStarted = true;

  state.browser = await chromium.launch(newBrowserOptions());
  state.contextA = await state.browser.newContext({
    locale: 'en-US', viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block',
  });
  await state.contextA.grantPermissions(['clipboard-read', 'clipboard-write'], {
    origin: state.baseOrigin,
  });
  await state.contextA.setExtraHTTPHeaders({ 'x-atermius-e2e-profile': 'A' });
  state.pageA = await state.contextA.newPage();
  observePage(state.pageA, 'A');
  await launchPersistentB();

  await signInAndEnroll();
  await addBaselineHost();
  await captureSecondDevicePush();
  setStage('close B profile so its durable outbox stays offline during backup and restore staging');
  await state.contextB.close();
  state.contextB = null;
  state.pageB = null;
  await queueBackupAndRestoreStage();

  setStage('restart B Chromium profile and verify the exact local outbox row');
  await launchPersistentB();
  await state.pageB.goto(`${state.baseOrigin}/__pg_restore_idb_probe__`, {
    waitUntil: 'domcontentloaded', timeout: 15000,
  });
  state.pendingAfterProfileRestart = await snapshotPendingRow(state.pageB,
    'after B Chromium profile restart before PG cutover');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart,
    state.pendingAfterProfileRestart),
  'persistent B IndexedDB changed its exact signed row across Chromium restart');
  await state.contextB.close();
  state.contextB = null;
  state.pageB = null;
  state.profileRestarted = true;
  await state.pageA.goto(`${state.baseOrigin}/__pg_restore_idb_probe__`, {
    waitUntil: 'domcontentloaded', timeout: 15000,
  });

  setStage('publish the operator cutover barrier with B closed');
  await writeReadyAndWait();

  setStage('reopen B profile and verify outbox across PG node restart');
  await launchPersistentB();
  await state.pageB.goto(`${state.baseOrigin}/__pg_restore_idb_probe__`, {
    waitUntil: 'domcontentloaded', timeout: 15000,
  });
  state.pendingAfterRestart = await snapshotPendingRow(state.pageB, 'after browser profile restart');
  assertThat(sameImmutableOutboxRow(state.pendingBeforeRestart, state.pendingAfterRestart),
    'persistent B IndexedDB changed its exact signed row across Chromium restart');
  await reconnectAndLoginB();
  await assertRestoreGenerationAndRejectStalePush();
  await rebuildSnapshotAndReplayOnce();

  assertThat(state.browserErrors.page.A === 0 && state.browserErrors.page.B === 0,
    'one or more Web profiles raised a JavaScript page error');
  assertThat(state.browserErrors.failedApi.A === 0 && state.browserErrors.failedApi.B === 0,
    'one or more unexpected Web API failures occurred');
  assertThat(state.adminPosts.every((event) => event.hasBearer && event.status === 202),
    'one or more PG administrator mutations lacked browser-captured bearer authentication');
}

main().catch((error) => {
  console.error(`PG restore-generation Chromium acceptance failed at ${state.stage}; ` +
    `error=${error?.name || 'Error'}; message=${String(error?.message || 'unknown').slice(0, 500)}; ` +
    `recentSafeRoutes=${JSON.stringify(state.apiEvents.slice(-12).map((event) => ({
      profile: event.profile, method: event.method, path: event.path, node: event.node,
      status: event.status,
    })))}; snapshotEvents=${JSON.stringify(state.snapshotEvents.slice(-8))}; ` +
    `snapshotRoutes=${JSON.stringify(state.apiEvents.filter((event) =>
      event.path.includes('/snapshots')).slice(-8).map((event) => ({
      profile: event.profile, method: event.method, path: event.path,
      status: event.status, atMs: event.atMs,
    })))}; recentFailures=${JSON.stringify(state.recentFailures.slice(-8))}; ` +
    `browserErrors=${JSON.stringify(state.browserErrors)}`);
  process.exitCode = 1;
}).finally(async () => {
  await cleanup();
  const result = resultDocument();
  console.log(`PG-RESTORE-GENERATION-RECOVERY-RESULT ${JSON.stringify(result)}`);
  if (!state.cleaned || !result.passed) process.exitCode = 1;
});
