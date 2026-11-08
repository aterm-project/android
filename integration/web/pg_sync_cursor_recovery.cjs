/*
 * PG-Web cursor recovery: persistent second-device Web profile, offline Host
 * branch, real PostgreSQL cursor expiry, and verified snapshot recovery.
 *
 * Environment contract (all values are disposable fixture data):
 *   ATERMIUS_PG_CURSOR_RECOVERY_BASE_URL
 *   ATERMIUS_PG_CURSOR_RECOVERY_NODE_A_URL
 *   ATERMIUS_PG_CURSOR_RECOVERY_NODE_B_URL
 *   ATERMIUS_PG_CURSOR_RECOVERY_USERNAME
 *   ATERMIUS_PG_CURSOR_RECOVERY_PASSWORD
 *   ATERMIUS_PG_CURSOR_RECOVERY_BOOTSTRAP_TOKEN
 *   ATERMIUS_PG_CURSOR_RECOVERY_HOST_NAME
 *   ATERMIUS_PG_CURSOR_RECOVERY_HOST_ADDRESS
 *   ATERMIUS_PG_CURSOR_RECOVERY_SSH_USERNAME
 *   ATERMIUS_PG_CURSOR_RECOVERY_READY_FILE
 *   ATERMIUS_PG_CURSOR_RECOVERY_CONTINUE_FILE
 *   PLAYWRIGHT_CHROMIUM_EXECUTABLE (optional)
 *
 * After B's offline edit is durable, this runner closes and relaunches B with
 * the same Chromium user-data directory. It writes READY_FILE containing only
 * safe Vault/record/sequence IDs and waits for the Python PG fixture to age
 * this Vault's event history and run maintenance. The fixture then creates
 * CONTINUE_FILE; only then does B reconnect. The PG fixture, not this runner,
 * owns history aging and maintenance.
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
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const PREFIX = 'ATERMIUS_PG_CURSOR_RECOVERY_';
const config = {
  baseUrl: process.env[`${PREFIX}BASE_URL`],
  nodeAUrl: process.env[`${PREFIX}NODE_A_URL`],
  nodeBUrl: process.env[`${PREFIX}NODE_B_URL`],
  username: process.env[`${PREFIX}USERNAME`],
  password: process.env[`${PREFIX}PASSWORD`],
  bootstrapToken: process.env[`${PREFIX}BOOTSTRAP_TOKEN`],
  hostName: process.env[`${PREFIX}HOST_NAME`],
  hostAddress: process.env[`${PREFIX}HOST_ADDRESS`],
  sshUsername: process.env[`${PREFIX}SSH_USERNAME`],
  readyFile: process.env[`${PREFIX}READY_FILE`],
  continueFile: process.env[`${PREFIX}CONTINUE_FILE`],
};
const chromiumExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const sensitiveValues = [config.username, config.password, config.bootstrapToken,
  config.hostName, config.hostAddress, config.sshUsername].filter(Boolean);
const API_ROUTES = [];
const SOCKET_ROUTES = [];
const SOCKETS = new Set();
const browserErrors = {
  page: 0,
  console: 0,
  consoleErrorClasses: {
    networkOffline: 0,
    unexpectedNetwork: 0,
    resourceLoad: 0,
    renderer: 0,
    other: 0,
  },
  resourceLoadClasses: { bundleAsset: 0, otherResource: 0 },
  resourceLoadPaths: [],
  resourceHttpFailures: [],
  expectedOfflineConsoleErrors: 0,
  expectedCursorExpiryConsoleErrors: 0,
  failedRequests: 0,
  cursorExpiryRequestFailures: [],
  expectedOfflineFailures: 0,
};
const state = {
  phase: 'preflight',
  browserA: null,
  contextA: null,
  pageA: null,
  contextB: null,
  pageB: null,
  proxy: null,
  proxyStarted: false,
  tempRoot: null,
  userDataDir: null,
  readyFileWritten: false,
  continueFileObserved: false,
  bOffline: false,
  profileRestarted: false,
  cleaned: false,
  blockBPush: false,
  captureOwnerPushStage: null,
  ownerPushes: [],
  ownerReceipts: [],
  target: {
    vaultId: null,
    recordId: null,
    baselineSeq: null,
    baselineRevisionId: null,
    ownerHeadRevisionId: null,
    branch: null,
    conflictId: null,
  },
  baselineBChanges: [],
  cursorExpiryChanges: [],
  bSnapshotCreates: [],
  bSnapshotFetches: [],
  bBranchPushes: [],
  bConflictUploads: [],
  outboxBeforeRestart: null,
  outboxAfterRestart: null,
  outboxAfter410: null,
  outboxSameAcrossRestart: false,
  outboxSameThrough410: false,
  pendingBeforeRestart: null,
  pendingAfterRestart: null,
  pendingAfter410: null,
  ownerHeadVisibleOnB: false,
  branchVisibleInConflictInbox: false,
  noPendingBranchPushBeforeSnapshot: false,
  recoveryStartedAt: null,
  requestStartAt: null,
  expectedOfflineFailures: 0,
};

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function upstreamFor(value) {
  const url = new URL(value || '');
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
    Number(url.port) > 0 && !url.pathname.slice(1) && !url.search && !url.hash,
  'PG Web cursor recovery requires exact loopback HTTP upstreams');
  return { hostname: url.hostname, port: Number(url.port), origin: url.origin };
}

let upstreamA;
let upstreamB;
let baseOrigin;
let basePort;

function routeFor(method, pathname, upgrade = false) {
  if (upgrade && pathname === '/api/v1/notifications') return 'B';
  if (method === 'POST' && /\/sync\/push$/i.test(pathname)) return 'A';
  if (method === 'GET' && /\/changes$/i.test(pathname)) return 'B';
  if (/\/api\/v1\/vaults\/[0-9a-f-]+\/(?:snapshots|conflicts|conflict-changes)(?:\/|$)/i.test(pathname) ||
      /^\/api\/v1\/snapshots\/[0-9a-f-]+$/i.test(pathname) ||
      /\/conflicts\/[0-9a-f-]+\/resolve$/i.test(pathname)) return 'B';
  return 'A';
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url || '/', baseOrigin);
    if (request.method === 'GET' && url.pathname === '/__pg_cursor_idb_probe__') {
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end('<!doctype html><title>Local storage probe</title>');
      return;
    }
    // Chromium probes this conventional path even though the Flutter Web
    // bundle has no favicon. Treat that optional browser request as empty so
    // it cannot obscure failures while loading application resources.
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const profile = request.headers['x-atermius-e2e-profile'] === 'B' ? 'B' : 'A';
    const node = routeFor(request.method || 'GET', url.pathname);
    const target = node === 'B' ? upstreamB : upstreamA;
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-atermius-e2e-profile'];
    const entry = {
      profile,
      method: request.method || 'GET',
      path: url.pathname,
      node,
      status: null,
      atMs: Date.now(),
      cursorPresent: url.searchParams.has('cursor'),
      cursorNonempty: Boolean(url.searchParams.get('cursor')),
    };
    if (url.pathname.startsWith('/api/v1/')) API_ROUTES.push(entry);
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      entry.status = upstreamResponse.statusCode || null;
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    request.pipe(upstreamRequest);
  });

  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', baseOrigin);
    const profile = request.headers['x-atermius-e2e-profile'] === 'B' ? 'B' : 'A';
    const node = routeFor('GET', url.pathname, true);
    const target = node === 'B' ? upstreamB : upstreamA;
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-atermius-e2e-profile'];
    const entry = {
      profile,
      path: url.pathname,
      node,
      status: null,
      hasQuery: url.search.length > 0,
    };
    SOCKET_ROUTES.push(entry);
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: 'GET',
      path: `${url.pathname}${url.search}`,
      headers,
    });
    upstreamRequest.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      entry.status = upstreamResponse.statusCode || null;
      let head = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
      for (let i = 0; i < upstreamResponse.rawHeaders.length; i += 2) {
        head += `${upstreamResponse.rawHeaders[i]}: ${upstreamResponse.rawHeaders[i + 1]}\r\n`;
      }
      clientSocket.write(`${head}\r\n`);
      if (clientHead?.length) upstreamSocket.write(clientHead);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      SOCKETS.add(clientSocket);
      SOCKETS.add(upstreamSocket);
      clientSocket.on('close', () => SOCKETS.delete(clientSocket));
      upstreamSocket.on('close', () => SOCKETS.delete(upstreamSocket));
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      entry.status = upstreamResponse.statusCode || null;
      clientSocket.write(`HTTP/1.1 ${upstreamResponse.statusCode || 502} ${upstreamResponse.statusMessage || 'Bad Gateway'}\r\n`);
      for (let i = 0; i < upstreamResponse.rawHeaders.length; i += 2) {
        clientSocket.write(`${upstreamResponse.rawHeaders[i]}: ${upstreamResponse.rawHeaders[i + 1]}\r\n`);
      }
      clientSocket.write('\r\n');
      upstreamResponse.pipe(clientSocket);
    });
    upstreamRequest.on('error', () => clientSocket.destroy());
    clientSocket.on('close', () => upstreamRequest.destroy());
    upstreamRequest.end();
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

function envelopeSummary(envelope) {
  const header = envelope?.header || {};
  return {
    opId: typeof header.op_id === 'string' ? header.op_id : null,
    revisionId: typeof header.revision_id === 'string' ? header.revision_id : null,
    recordId: typeof header.record_id === 'string' ? header.record_id : null,
    baseRevisionId: typeof header.base_revision_id === 'string'
      ? header.base_revision_id : null,
    envelopeSha256: crypto.createHash('sha256').update(stableJson(envelope)).digest('hex'),
  };
}

function apiNode(method, pathname) {
  return routeFor(method, pathname);
}

function classifyConsoleError(text) {
  const message = typeof text === 'string' ? text : '';
  if (/ERR_INTERNET_DISCONNECTED|ERR_NETWORK_CHANGED|ERR_CONNECTION_(?:REFUSED|RESET|TIMED_OUT)|\bNetworkError\b|failed to fetch|load failed/i.test(message)) {
    return 'networkOffline';
  }
  if (/failed to load resource|loading chunk|script error|resource.*(?:failed|error)|404 \(not found\)/i.test(message)) {
    return 'resourceLoad';
  }
  if (/flutter|canvas|webgl|render|semantics/i.test(message)) return 'renderer';
  return 'other';
}

function classifyResourceLoad(text) {
  const message = typeof text === 'string' ? text : '';
  return /(?:^|\/)(?:index\.html|main\.dart\.js|flutter(?:_bootstrap)?\.js|drift_worker\.js|sqlite3\.wasm|canvaskit(?:\.js|\.wasm)?|assets\/|icons\/)/i.test(message)
    ? 'bundleAsset' : 'otherResource';
}

function attachPageObservers(page, profile) {
  const requestEntries = new WeakMap();
  page.on('pageerror', () => { browserErrors.page++; });
  page.on('console', (message) => {
    if (message.type() === 'error') {
      browserErrors.console++;
      let category = 'other';
      let safeText = '';
      try {
        safeText = message.text();
        category = classifyConsoleError(safeText);
      } catch (_) {}
      if (category === 'networkOffline') {
        browserErrors.consoleErrorClasses.networkOffline++;
        const expectedOffline = profile === 'B' && (state.bOffline ||
          (state.blockBPush && /\/sync\/push(?:[?\s]|$)/i.test(safeText)));
        if (expectedOffline) browserErrors.expectedOfflineConsoleErrors++;
        else browserErrors.consoleErrorClasses.unexpectedNetwork++;
      } else if (category !== 'resourceLoad') {
        browserErrors.consoleErrorClasses[category]++;
      }
      if (category === 'resourceLoad') {
        const expectedCursorExpiry = isExpectedCursorExpiryResourceError(message);
        if (expectedCursorExpiry) browserErrors.expectedCursorExpiryConsoleErrors++;
        else browserErrors.resourceLoadClasses[classifyResourceLoad(safeText)]++;
        try {
          const location = message.location();
          const resourceUrl = new URL(location.url);
          browserErrors.resourceLoadPaths.push({
            profile,
            origin: resourceUrl.origin === baseOrigin ? 'local' : resourceUrl.origin.slice(0, 160),
            path: resourceUrl.origin === baseOrigin
              ? resourceUrl.pathname.slice(0, 160) : 'non-local-resource',
            expectedCursorExpiry,
            line: Number.isInteger(location.lineNumber) ? location.lineNumber : 0,
          });
        } catch (_) {
          browserErrors.resourceLoadPaths.push({ profile, path: 'location-unavailable', line: 0 });
        }
      }
    }
  });
  page.on('request', (request) => {
    const url = new URL(request.url());
    const entry = {
      profile,
      method: request.method(),
      path: url.pathname,
      node: apiNode(request.method(), url.pathname),
      status: null,
      cursorPresent: url.searchParams.has('cursor'),
      cursorNonempty: Boolean(url.searchParams.get('cursor')),
      atMs: Date.now(),
      errorCode: null,
      pushSummaries: [],
    };
    requestEntries.set(request, entry);
    if (url.pathname.startsWith('/api/v1/')) API_ROUTES.push(entry);
    if (request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname)) {
      try {
        const body = request.postDataJSON();
        const pathVaultId = url.pathname.match(/\/vaults\/([0-9a-f-]+)\/sync\/push$/i)?.[1] || null;
        for (const envelope of body?.operations || []) {
          const summary = envelopeSummary(envelope);
          if (profile === 'B' && summary.recordId === state.target.recordId) {
            if (!state.bBranchPushes.some((item) => item.opId === summary.opId)) {
              state.bBranchPushes.push({ ...summary, atMs: entry.atMs, status: null });
            }
            entry.pushSummaries.push({ profile, ...summary });
          } else if (profile === 'A' && state.captureOwnerPushStage) {
            const isTargetOperation = state.captureOwnerPushStage === 'baseline'
              ? envelope?.header?.operation === 'create'
              : summary.recordId === state.target.recordId;
            if (!isTargetOperation) continue;
            const captured = {
              profile,
              stage: state.captureOwnerPushStage,
              vaultId: typeof body?.vault_id === 'string' ? body.vault_id : pathVaultId,
              ...summary,
              atMs: entry.atMs,
              status: null,
            };
            state.ownerPushes.push(captured);
            entry.pushSummaries.push(captured);
          }
        }
      } catch (_) {}
    }
    if (request.method() === 'POST' && /\/conflicts$/i.test(url.pathname) && profile === 'B') {
      try {
        const envelope = request.postDataJSON()?.envelope;
        if (envelopeSummary(envelope).recordId === state.target.recordId) {
          state.bConflictUploads.push({
            ...envelopeSummary(envelope),
            atMs: entry.atMs,
            status: null,
            conflictId: null,
          });
        }
      } catch (_) {}
    }
    if (request.method() === 'POST' && /\/api\/v1\/vaults\/[0-9a-f-]+\/snapshots$/i.test(url.pathname) && profile === 'B') {
      state.bSnapshotCreates.push({ atMs: entry.atMs, status: null, node: entry.node });
    }
  });
  page.on('response', (response) => {
    const request = response.request();
    const url = new URL(response.url());
    if (response.status() >= 400 && !url.pathname.startsWith('/api/')) {
      browserErrors.resourceHttpFailures.push({
        profile,
        phase: state.phase,
        method: request.method(),
        resourceType: request.resourceType(),
        status: response.status(),
        path: url.origin === baseOrigin ? url.pathname.slice(0, 160) : 'non-local-resource',
      });
    }
    const entry = requestEntries.get(request);
    if (entry) entry.status = response.status();
    if (profile === 'B' && request.method() === 'GET' && /\/changes$/i.test(url.pathname)) {
      const summary = entry || {
        profile,
        method: 'GET',
        path: url.pathname,
        node: 'B',
        status: response.status(),
        cursorPresent: url.searchParams.has('cursor'),
        cursorNonempty: Boolean(url.searchParams.get('cursor')),
        atMs: Date.now(),
        errorCode: null,
      };
      summary.status = response.status();
      const target = state.requestStartAt !== null && summary.atMs >= state.requestStartAt
        ? state.cursorExpiryChanges : state.baselineBChanges;
      target.push(summary);
      void response.json().then((body) => {
        const error = body?.error;
        const code = typeof error?.code === 'string' ? error.code :
          (typeof body?.code === 'string' ? body.code : null);
        if (code === 'CURSOR_EXPIRED') summary.errorCode = code;
      }).catch(() => {});
    }
    if (profile === 'B' && request.method() === 'POST' &&
        /\/api\/v1\/vaults\/[0-9a-f-]+\/snapshots$/i.test(url.pathname)) {
      const item = state.bSnapshotCreates.slice().reverse()
        .find((candidate) => candidate.status === null);
      if (item) item.status = response.status();
    }
    if (profile === 'B' && request.method() === 'GET' &&
        /^\/api\/v1\/snapshots\/[0-9a-f-]+$/i.test(url.pathname)) {
      state.bSnapshotFetches.push({ atMs: Date.now(), status: response.status(), node: 'B' });
    }
    if (profile === 'B' && request.method() === 'POST' && /\/conflicts$/i.test(url.pathname)) {
      const item = state.bConflictUploads.slice().reverse()
        .find((candidate) => candidate.status === null);
      if (item) {
        item.status = response.status();
        void response.json().then((body) => {
          item.conflictId = typeof body?.conflict_id === 'string' ? body.conflict_id : null;
        }).catch(() => {});
      }
    }
    if (profile === 'B' && request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname)) {
      for (const pushed of entry?.pushSummaries || []) {
        const captured = state.bBranchPushes.find((candidate) => candidate.opId === pushed.opId);
        if (captured) captured.status = response.status();
      }
    }
    if (profile === 'A' && request.method() === 'POST' && /\/sync\/push$/i.test(url.pathname)) {
      void response.json().then((body) => {
        const results = Array.isArray(body?.results) ? body.results : [];
        for (const pushed of entry?.pushSummaries || []) {
          const captured = state.ownerPushes.find((candidate) => candidate.opId === pushed.opId &&
            candidate.stage === pushed.stage);
          if (captured) captured.status = response.status();
          const receipt = results.find((candidate) => candidate?.op_id === pushed.opId);
          if (receipt) {
            state.ownerReceipts.push({
              opId: typeof receipt.op_id === 'string' ? receipt.op_id : null,
              revisionId: typeof receipt.revision_id === 'string' ? receipt.revision_id : null,
              commitSeq: typeof receipt.commit_seq === 'string' ? receipt.commit_seq : null,
              status: response.status(),
              stage: pushed.stage,
            });
          }
        }
      }).catch(() => {});
    }
  });
  page.on('requestfailed', (request) => {
    const url = new URL(request.url());
    const intentionalPushBlock = state.blockBPush && request.method() === 'POST' &&
      /\/sync\/push$/i.test(url.pathname);
    if (profile === 'B' && (state.bOffline || intentionalPushBlock)) {
      browserErrors.expectedOfflineFailures++;
      return;
    }
    const entry = requestEntries.get(request);
    const expectedChangesPath = state.target.vaultId
      ? `/api/v1/vaults/${state.target.vaultId}/changes` : null;
    if (profile === 'B' && request.method() === 'GET' && expectedChangesPath &&
        url.origin === baseOrigin && url.pathname === expectedChangesPath &&
        url.searchParams.has('cursor') && Boolean(url.searchParams.get('cursor'))) {
      // Chromium may report an HTTP 410 response as requestfailed even though
      // the API response is the expected CURSOR_EXPIRED recovery signal. Defer
      // classification until the proxy's matching response status is recorded;
      // URL shape alone must never suppress a genuine transport failure.
      browserErrors.cursorExpiryRequestFailures.push({
        profile,
        method: request.method(),
        path: url.pathname,
        cursorPresent: true,
        cursorNonempty: true,
        atMs: entry?.atMs ?? Date.now(),
        status: entry?.status ?? null,
      });
      return;
    }
    browserErrors.failedRequests++;
  });
}

function assertConfig() {
  assertThat(Object.values(config).every((value) => typeof value === 'string' && value.length > 0),
    'PG cursor recovery fixture environment is incomplete');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web Release bundle is missing');
  upstreamA = upstreamFor(config.nodeAUrl);
  upstreamB = upstreamFor(config.nodeBUrl);
  const base = new URL(config.baseUrl);
  assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' &&
    Number(base.port) > 0 && !base.pathname.slice(1) && !base.search && !base.hash,
  'PG cursor recovery requires an exact loopback same-origin proxy URL');
  baseOrigin = base.origin;
  basePort = Number(base.port);
  assertThat(!fs.existsSync(config.readyFile) && !fs.existsSync(config.continueFile),
    'PG cursor recovery handshake paths must be fresh for this run');
}

function isExpectedCursorExpiryResourceError(message) {
  if (!state.target.vaultId) return false;
  try {
    const url = new URL(message.location().url);
    const expectedPath = `/api/v1/vaults/${state.target.vaultId}/changes`;
    return url.origin === baseOrigin && url.pathname === expectedPath &&
      API_ROUTES.some((entry) => entry.method === 'GET' && entry.path === expectedPath &&
        entry.status === 410 && entry.cursorPresent && entry.cursorNonempty);
  } catch (_) {
    return false;
  }
}

function expectedCursorExpiryRequestFailureCount() {
  if (!state.target.vaultId) return 0;
  const expectedPath = `/api/v1/vaults/${state.target.vaultId}/changes`;
  const provenResponses = state.cursorExpiryChanges.filter((entry) =>
    entry.profile === 'B' && entry.method === 'GET' && entry.path === expectedPath &&
    entry.node === 'B' && entry.status === 410 && entry.errorCode === 'CURSOR_EXPIRED' &&
    entry.cursorPresent && entry.cursorNonempty).map((entry) => ({ atMs: entry.atMs, used: false }));
  let matched = 0;
  const candidates = [...browserErrors.cursorExpiryRequestFailures]
    .filter((entry) => entry.profile === 'B' && entry.method === 'GET' &&
      entry.path === expectedPath && entry.cursorPresent && entry.cursorNonempty)
    .sort((left, right) => left.atMs - right.atMs);
  for (const candidate of candidates) {
    // The response observer stores the same browser request timestamp. Require
    // its parsed CURSOR_EXPIRED body as well as HTTP 410, and consume each
    // response once so an unrelated or duplicate failure remains unexpected.
    const response = provenResponses.find((item) => !item.used && item.atMs === candidate.atMs);
    if (response) {
      response.used = true;
      matched++;
    }
  }
  return matched;
}

function unexpectedRequestFailureCount() {
  return browserErrors.failedRequests + browserErrors.cursorExpiryRequestFailures.length -
    expectedCursorExpiryRequestFailureCount();
}

function input(page, label) {
  return page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`);
}

async function field(page, label) {
  const locator = input(page, label);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = [];
    for (let i = 0; i < await locator.count(); i++) {
      if (await locator.nth(i).isVisible().catch(() => false)) visible.push(locator.nth(i));
    }
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error('required Web form field did not become visible');
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.pressSequentially(value, { delay: 18 });
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, 'Web form input did not retain its value');
  await locator.press('Tab');
}

async function stableVisibleInput(page, label, durationMs = 400, maxWaitMs = 15000) {
  const locator = input(page, label);
  const deadline = Date.now() + maxWaitMs;
  let candidate = null;
  let stableSince = 0;
  while (Date.now() < deadline) {
    let visibleCandidate = null;
    for (let index = 0; index < await locator.count(); index += 1) {
      const current = locator.nth(index);
      if (await current.isVisible().catch(() => false)) {
        visibleCandidate = current;
        break;
      }
    }
    if (visibleCandidate) {
      if (candidate && await candidate.isVisible().catch(() => false)) {
        if (Date.now() - stableSince >= durationMs) return candidate;
      } else {
        candidate = visibleCandidate;
        stableSince = Date.now();
      }
    } else {
      candidate = null;
      stableSince = 0;
    }
    await page.waitForTimeout(100);
  }
  return null;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  try {
    await locator.first().waitFor({ state: 'visible', timeout: 20000 });
  } catch (_) {
    throw new Error(`required Web action ${JSON.stringify(label)} was not visible; ` +
      `safeUiState=${JSON.stringify(await safeUiState(page))}`);
  }
  return locator.first();
}

async function safeUiState(page) {
  const labels = [
    'Hosts', 'Sync & conflicts', 'Add host', 'Sync health', 'Rebuild snapshot',
    '跨设备冲突收件箱', '快照恢复完成', 'Choose a workspace',
    'Server account and sync', 'Sign in and unlock', 'Master password',
  ];
  const textPresence = await page.evaluate((expectedLabels) => {
    const parts = [document.body?.innerText || ''];
    for (const node of document.querySelectorAll('flt-semantics')) {
      const style = getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      if (style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0) {
        parts.push(node.innerText || '', node.getAttribute('aria-label') || '');
      }
    }
    const visibleText = parts.join('\n');
    return Object.fromEntries(expectedLabels.map((label) => [label, visibleText.includes(label)]));
  }, labels).catch(() => ({}));
  const buttonPresence = {};
  for (const label of ['Hosts', 'Sync & conflicts', 'Add host', 'Sync now', 'Rebuild snapshot']) {
    buttonPresence[label] = await page.getByRole('button', { name: label, exact: true })
      .isVisible().catch(() => false);
  }
  return { pathname: await page.evaluate(() => location.pathname).catch(() => 'unavailable'),
    textPresence, buttonPresence };
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function clickWorkspaceNavigation(page, label) {
  const name = label === 'Sync & conflicts'
    ? /^Sync & conflicts(?:\s+\d+)?$/ : label;
  const semanticButton = page.getByRole('button', { name, exact: typeof name === 'string' });
  if (await semanticButton.isVisible().catch(() => false)) {
    await semanticButton.click();
    return;
  }
  const navText = typeof name === 'string'
    ? page.getByText(name, { exact: true }).last()
    : page.getByText(name).last();
  await navText.waitFor({ state: 'visible', timeout: 15000 });
  await navText.scrollIntoViewIfNeeded();
  await navText.click();
}

async function waitFor(predicate, description, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function waitForSemanticText(page, text, timeoutMs = 30000) {
  await waitFor(() => page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    return (document.body?.innerText || '').includes(expected) || nodes.some((node) =>
      `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`.includes(expected));
  }, text).catch(() => false), `visible semantic text ${text}`, timeoutMs);
}

async function enableFlutter(page) {
  await page.goto(config.baseUrl, { waitUntil: 'domcontentloaded' });
  await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function')
    .catch(() => false), 'Web crypto module', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() =>
    document.querySelectorAll('flt-semantics').length > 0).catch(() => false),
  'Flutter semantics tree', 15000);
}

async function connectToServer(page) {
  await fill(page, 'Server URL', config.baseUrl);
  await click(page, 'Connect securely');
}

async function connectToServerAfterModeSelection(page) {
  // The restart flow has already clicked the workspace chooser's Continue.
  // Avoid the generic field helper here: it can observe the old chooser during
  // Flutter's transition and click Continue a second time.
  const serverUrl = await stableVisibleInput(page, 'Server URL');
  assertThat(serverUrl, `B server URL form was not stable; ` +
    `safeStartupState=${JSON.stringify(await safeStartupState(page))}`);
  await serverUrl.click();
  await page.keyboard.press('Control+A');
  await page.keyboard.type(config.baseUrl, { delay: 18 });
  await page.waitForTimeout(100);
  if (await serverUrl.inputValue().catch(() => '') !== config.baseUrl) {
    await serverUrl.fill(config.baseUrl);
  }
  assertThat(await serverUrl.inputValue().catch(() => '') === config.baseUrl,
    `B server URL field did not retain the configured loopback origin; ` +
    `safeStartupState=${JSON.stringify(await safeStartupState(page))}`);
  const connect = page.getByRole('button', { name: 'Connect securely', exact: true });
  await connect.waitFor({ state: 'visible', timeout: 10000 });
  await connect.click();
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function waitHostVisible(page, name, endpoint) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const group = page.getByRole('group', { name: new RegExp(`^Host: ${escaped}; `) }).first();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const label = await group.getAttribute('aria-label').catch(() => '');
    if (label?.startsWith(`Host: ${name}; `) && label.includes(`@${endpoint}`)) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function pendingCount(page) {
  return page.evaluate(() => {
    for (const node of document.querySelectorAll('flt-semantics')) {
      const text = [node.getAttribute('aria-label') || '', node.innerText || '',
        node.parentElement?.innerText || ''].join('\n');
      if (/Pending sync/i.test(text)) {
        const match = text.match(/Pending sync\D{0,40}(\d+)/i);
        if (match) return Number(match[1]);
      }
    }
    return null;
  }).catch(() => null);
}

async function waitPending(page, minimum) {
  return waitFor(async () => {
    const count = await pendingCount(page);
    return count !== null && count >= minimum ? count : false;
  }, `pending outbox count >= ${minimum}`, 20000);
}

async function readClientDatabaseFromIndexedDb(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') {
      return { available: false, reason: 'database-list-unavailable' };
    }
    const databases = await indexedDB.databases();
    if (!databases.some((database) => database.name === 'atermius_vault')) {
      return { available: false, reason: 'drift-indexeddb-database-missing' };
    }
    const connection = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
      request.onblocked = () => reject(new Error('IDB open blocked'));
    });
    try {
      if (!connection.objectStoreNames.contains('files') ||
          !connection.objectStoreNames.contains('blocks')) {
        return { available: false, reason: 'drift-file-stores-missing' };
      }
      const filesTx = connection.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('IDB files read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('IDB files read aborted'));
      });
      const filesStore = filesTx.objectStore('files');
      const [values, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesStore.getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = filesStore.getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file key read failed'));
        }),
        filesComplete,
      ]);
      const files = values.map((value, index) => ({
        fileId: Number(keys[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal');
      const databaseFile = files.find((file) => file.name === '/database');
      if (!databaseFile || files.some((file) => !Number.isSafeInteger(file.fileId) ||
          !Number.isSafeInteger(file.length) || file.length < 0 ||
          file.length > 64 * 1024 * 1024)) {
        return { available: false, reason: 'drift-sqlite-file-metadata-invalid' };
      }
      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('IDB blocks read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('IDB blocks read aborted'));
      });
      const store = blocksTx.objectStore('blocks');
      const sqliteFiles = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0],
          [file.fileId, Number.MAX_SAFE_INTEGER]);
        const [blockKeys, blockValues] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = store.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block keys read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = store.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block values read failed'));
          }),
        ]);
        return {
          ...file,
          blocks: blockKeys.map((key, index) => {
            const value = blockValues[index];
            let bytes;
            if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
            else if (ArrayBuffer.isView(value)) {
              bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            } else throw new Error('unsupported IndexedDB block value');
            let binary = '';
            for (let at = 0; at < bytes.length; at += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
            }
            return { offset: Number(key?.[1]), base64: btoa(binary) };
          }),
        };
      }));
      await blocksComplete;
      return { available: true, sqliteFiles };
    } finally {
      connection.close();
    }
  });
}

function inspectClientPendingOperation(sqliteFiles, vaultId, recordId) {
  const snapshotPath = path.join(state.tempRoot, 'b-outbox-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'B IndexedDB snapshot had no database or an active journal');
  const bytes = reconstructSqliteFile({
    fileId: databaseFile.fileId,
    name: databaseFile.name,
    length: databaseFile.length,
    blocks: databaseFile.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id=sys.argv[2:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute(\"SELECT op_id,vault_id,record_id,envelope_json,status FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    "pending=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    'def digest(text):',
    '    value=json.loads(text)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest(),value',
    'operations=[]',
    'for row in rows:',
    '    envelope_hash,envelope=digest(row[3])',
    '    header=envelope.get("header",{})',
    '    operations.append({"opId":row[0],"vaultId":row[1],"recordId":row[2],"revisionId":header.get("revision_id"),"baseRevisionId":header.get("base_revision_id"),"operation":header.get("operation"),"keyEpoch":header.get("key_epoch"),"membershipVersion":header.get("membership_version"),"envelopeSha256":envelope_hash,"status":row[4]})',
    'print(json.dumps({"integrityCheck":integrity,"operations":operations,"activePendingCount":pending},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId, recordId], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only B outbox snapshot query failed');
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function samePendingOperation(left, right) {
  return Boolean(left && right && left.opId === right.opId &&
    left.revisionId === right.revisionId && left.baseRevisionId === right.baseRevisionId &&
    left.envelopeSha256 === right.envelopeSha256);
}

async function snapshotBPendingOperation(label) {
  const snapshot = await readClientDatabaseFromIndexedDb(state.pageB);
  assertThat(snapshot.available && Array.isArray(snapshot.sqliteFiles),
    `B IndexedDB snapshot was unavailable ${label}`);
  const inspection = inspectClientPendingOperation(snapshot.sqliteFiles,
    state.target.vaultId, state.target.recordId);
  assertThat(inspection.integrityCheck === 'ok' && inspection.activePendingCount === 1 &&
    inspection.operations.length === 1,
  `B did not retain exactly one active operation ${label}`);
  const operation = inspection.operations[0];
  const allowedStatuses = label === 'before profile restart' ? ['queued'] : ['queued', 'sent'];
  assertThat(operation.vaultId === state.target.vaultId &&
    operation.recordId === state.target.recordId && operation.operation === 'update' &&
    operation.opId && operation.revisionId &&
    operation.baseRevisionId && operation.envelopeSha256 &&
    allowedStatuses.includes(operation.status),
  `B pending Host operation metadata was invalid ${label}`);
  return operation;
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
  await waitFor(() => waitHostVisible(page, newName, `${config.hostAddress}:22`),
    'updated Host card');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(300);
    if (await locator.inputValue() === value) return;
  }
  await locator.fill(value);
  await page.waitForTimeout(100);
  assertThat(await locator.inputValue() === value, 'clipboard input did not match enrollment data');
}

function newBrowserOptions() {
  return {
    headless: true,
    ...(chromiumExecutable ? { executablePath: chromiumExecutable } : {}),
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  };
}

async function createOwnerAndEnrollSecondDevice() {
  state.phase = 'start isolated Chromium and same-origin proxy';
  state.proxy = makeProxy();
  await new Promise((resolve, reject) => {
    state.proxy.once('error', reject);
    state.proxy.listen(basePort, '127.0.0.1', resolve);
  });
  state.proxyStarted = true;
  state.tempRoot = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(),
    'atermius-pg-cursor-recovery-'));
  state.userDataDir = path.join(state.tempRoot, 'profile-b');
  state.browserA = await chromium.launch(newBrowserOptions());
  state.contextA = await state.browserA.newContext({
    locale: 'en-US', viewport: { width: 1440, height: 1000 },
  });
  await state.contextA.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseOrigin });
  await state.contextA.setExtraHTTPHeaders({ 'x-atermius-e2e-profile': 'A' });
  state.pageA = await state.contextA.newPage();
  attachPageObservers(state.pageA, 'A');
  await state.contextA.routeWebSocket('**/api/v1/notifications', (socket) => socket.connectToServer());

  state.contextB = await chromium.launchPersistentContext(state.userDataDir, {
    ...newBrowserOptions(),
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  });
  await state.contextB.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseOrigin });
  await state.contextB.setExtraHTTPHeaders({ 'x-atermius-e2e-profile': 'B' });
  await installBOfflinePushGate(state.contextB);
  await state.contextB.routeWebSocket('**/api/v1/notifications', (socket) => socket.connectToServer());
  state.pageB = state.contextB.pages()[0] || await state.contextB.newPage();
  attachPageObservers(state.pageB, 'B');

  state.phase = 'register first Web owner on PG node A';
  await enableFlutter(state.pageA);
  await connectToServer(state.pageA);
  await field(state.pageA, 'Owner email');
  await fill(state.pageA, 'Owner email', config.username);
  await fill(state.pageA, 'Master password · 12+ characters', config.password);
  await fill(state.pageA, 'Confirm master password', config.password);
  await fill(state.pageA, 'One-time bootstrap token', config.bootstrapToken);
  await fill(state.pageA, 'Device name', 'PG cursor recovery owner');
  await fill(state.pageA, 'First Vault', 'PG cursor recovery Vault');
  await click(state.pageA, 'Create owner account');
  await waitWorkspace(state.pageA);

  state.phase = 'create and approve B device enrollment';
  await enableFlutter(state.pageB);
  await connectToServer(state.pageB);
  await field(state.pageB, 'Email or username');
  await click(state.pageB, 'Add this device');
  await fill(state.pageB, 'Account email', config.username);
  await fill(state.pageB, 'Device name', 'PG cursor recovery B');
  await click(state.pageB, 'Generate request');
  await field(state.pageB, 'Copy this enrollment JSON');
  await click(state.pageB, 'Copy');
  const enrollmentJson = await readClipboard(state.pageB);
  assertThat(JSON.parse(enrollmentJson)?.format === 'atermius-device-enrollment-v1',
    'B did not produce a supported device enrollment request');
  await click(state.pageB, 'Close');

  await click(state.pageA, 'Devices');
  await click(state.pageA, 'Approve enrollment');
  await paste(state.pageA, 'Enrollment JSON', enrollmentJson);
  await click(state.pageA, 'Review keys');
  await click(state.pageA, 'Approve & seal keys');
  await click(state.pageA, 'Copy');
  const approvalJson = await readClipboard(state.pageA);
  assertThat(approvalJson.includes('atermius-device-approval-v1'),
    'A did not produce a supported device approval');
  await click(state.pageA, 'Done');
  await click(state.pageA, 'Hosts');

  await click(state.pageB, 'Import approval');
  await paste(state.pageB, 'Paste approval JSON', approvalJson);
  await click(state.pageB, 'Import device keys');
  await fill(state.pageB, 'Email or username', config.username);
  await fill(state.pageB, 'Master password', config.password);
  await click(state.pageB, 'Sign in and unlock');
  await waitWorkspace(state.pageB);
}

async function installBOfflinePushGate(context) {
  await context.route('**/api/v1/vaults/*/sync/push', async (route) => {
    if (!state.blockBPush) {
      await route.continue();
      return;
    }
    await route.abort('internetdisconnected').catch(() => {});
  });
}

async function createBaselineAndSyncB() {
  state.phase = 'commit baseline Host on A and sync its encrypted revision to B';
  const hostEndpoint = `${config.hostAddress}:22`;
  await click(state.pageA, 'Hosts');
  await click(state.pageA, 'Add host');
  await fill(state.pageA, 'Display name', config.hostName);
  await fill(state.pageA, 'Hostname or IP', config.hostAddress);
  await fill(state.pageA, 'Port', '22');
  await fill(state.pageA, 'SSH username', config.sshUsername);
  const baselineCapture = capturePushAndReceipt(state.pageA, 'A', 'baseline');
  await click(state.pageA, 'Save encrypted host');
  assertThat(await waitHostVisible(state.pageA, config.hostName, hostEndpoint),
    'A did not render the encrypted baseline Host');
  const baseline = await baselineCapture;
  const op = baseline.request;
  const receipt = baseline.receipt;
  assertThat(op?.recordId && op?.revisionId && op?.opId &&
    receipt?.status >= 200 && receipt.status < 300,
  'A baseline Host push did not receive a successful operation receipt');
  assertThat(op?.recordId && op?.revisionId && op?.opId,
    'baseline Host operation IDs were not captured');
  state.target.vaultId = op.vaultId;
  state.target.recordId = op.recordId;
  state.target.baselineRevisionId = op.revisionId;
  assertThat(receipt.commitSeq, 'baseline push receipt did not expose commit sequence');
  state.target.baselineSeq = receipt.commitSeq;

  const bChangesStart = state.baselineBChanges.length;
  await waitFor(async () => await waitHostVisible(state.pageB, config.hostName, hostEndpoint),
    'B render of baseline Host', 60000);
  await click(state.pageB, 'Sync & conflicts');
  await waitForSemanticText(state.pageB, 'Sync health');
  await click(state.pageB, 'Sync now');
  await waitFor(() => state.baselineBChanges.slice(bChangesStart).some((entry) =>
    entry.status === 200 && entry.node === 'B' && entry.cursorPresent && entry.cursorNonempty),
  'B persisted nonempty baseline cursor via node B', 30000);
  assertThat(state.baselineBChanges.some((entry) => entry.status === 200 &&
    entry.cursorPresent && entry.cursorNonempty), 'B never sent a nonempty persisted cursor');
  await click(state.pageB, 'Hosts');
  await waitHostVisible(state.pageB, config.hostName, hostEndpoint);
}

async function capturePushAndReceipt(page, profile, stage) {
  assertThat(profile === 'A', 'owner push capture only supports profile A');
  state.captureOwnerPushStage = stage;
  const firstPushIndex = state.ownerPushes.length;
  const request = await waitFor(() => state.ownerPushes.slice(firstPushIndex)
    .find((item) => item.stage === stage && item.profile === profile),
  `${stage} owner sync push`, 45000);
  state.captureOwnerPushStage = null;
  const receipt = await waitFor(() => state.ownerReceipts.slice().reverse()
    .find((item) => item.opId === request.opId && item.stage === stage),
  `${stage} owner push receipt`, 45000);
  return { request, receipt };
}

async function waitForBWorkspaceAfterRestart() {
  await enableFlutter(state.pageB);
  const deadline = Date.now() + 20000;
  let loginSubmitted = false;
  let workspaceModeContinueClicked = false;
  while (Date.now() < deadline) {
    if (await workspaceModeChooserVisible(state.pageB)) {
      const continueButton = state.pageB.getByRole('button', { name: 'Continue', exact: true });
      if (!workspaceModeContinueClicked &&
          await continueButton.isVisible().catch(() => false) &&
          await continueButton.isEnabled().catch(() => false)) {
        // The chooser semantics can remain visible briefly after its route
        // transition starts. Click once, then wait for the Server URL form
        // instead of interpreting that stale chooser as another prompt.
        workspaceModeContinueClicked = true;
        await continueButton.click({ timeout: 1200 }).catch(() => {});
      }
      await state.pageB.waitForTimeout(100);
      continue;
    }
    if (await state.pageB.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) return;
    if (await stableVisibleInput(state.pageB, 'Server URL', 200, 600)) {
      await connectToServerAfterModeSelection(state.pageB);
      continue;
    }
    if (await state.pageB.locator('input[aria-label*="Email or username"]')
      .isVisible().catch(() => false)) {
      if (loginSubmitted) {
        await state.pageB.waitForTimeout(150);
        continue;
      }
      await fill(state.pageB, 'Email or username', config.username);
      await fill(state.pageB, 'Master password', config.password);
      await click(state.pageB, 'Sign in and unlock');
      loginSubmitted = true;
      continue;
    }
    if (await state.pageB.locator('input[aria-label*="Master password"]')
      .isVisible().catch(() => false)) {
      await fill(state.pageB, 'Master password', config.password);
      const unlock = state.pageB.getByRole('button', { name: 'Unlock', exact: true });
      if (await unlock.isVisible().catch(() => false)) await unlock.click();
      else await click(state.pageB, 'Sign in and unlock');
      continue;
    }
    const continueButton = state.pageB.getByRole('button', { name: 'Continue', exact: true });
    if (!workspaceModeContinueClicked &&
        await continueButton.isVisible().catch(() => false)) {
      await continueButton.click({ timeout: 1200 }).catch(() => {});
      await state.pageB.waitForTimeout(100);
      continue;
    }
    if (await state.pageB.getByRole('button', { name: 'Connect securely', exact: true })
      .isVisible().catch(() => false)) {
      await connectToServerAfterModeSelection(state.pageB);
      continue;
    }
    await state.pageB.waitForTimeout(100);
  }
  const startupState = await safeStartupState(state.pageB);
  throw new Error(`B restart did not reach a recognized reconnect or workspace state; ` +
    `safeStartupState=${JSON.stringify({ ...startupState, workspaceModeContinueClicked })}`);
}

async function workspaceModeChooserVisible(page) {
  return page.evaluate(() => {
    const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      })
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const visibleText = `${document.body?.innerText || ''}\n${visibleSemanticText}`;
    return visibleText.includes('Choose a workspace') &&
      visibleText.includes('Server account and sync');
  }).catch(() => false);
}

async function safeStartupState(page) {
  const visible = async (locator) => locator.isVisible().catch(() => false);
  const [chooser, serverUrl, email, password, connect, signIn, continueButton, addHost] =
    await Promise.all([
      workspaceModeChooserVisible(page),
      visible(page.locator('input[aria-label*="Server URL"]')),
      visible(page.locator('input[aria-label*="Email or username"]')),
      visible(page.locator('input[aria-label*="Master password"]')),
      visible(page.getByRole('button', { name: 'Connect securely', exact: true })),
      visible(page.getByRole('button', { name: 'Sign in and unlock', exact: true })),
      visible(page.getByRole('button', { name: 'Continue', exact: true })),
      visible(page.getByRole('button', { name: 'Add host', exact: true })),
    ]);
  return { chooser, serverUrl, email, password, connect, signIn, continue: continueButton, addHost };
}

function unexpectedConsoleErrorCount() {
  const classes = browserErrors.consoleErrorClasses;
  return classes.unexpectedNetwork + classes.resourceLoad + classes.renderer + classes.other;
}

async function writeReadyAndWait() {
  assertThat(state.target.vaultId && state.target.recordId && state.target.baselineSeq &&
    state.target.ownerHeadRevisionId && state.profileRestarted,
  'restart barrier metadata is incomplete');
  const ready = {
    vaultId: state.target.vaultId,
    recordId: state.target.recordId,
    baselineSeq: state.target.baselineSeq,
    ownerHeadRevisionId: state.target.ownerHeadRevisionId,
    profileRestarted: true,
  };
  const fd = fs.openSync(config.readyFile, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(ready)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  state.readyFileWritten = true;
  await waitFor(() => {
    try {
      const info = fs.lstatSync(config.continueFile);
      return info.isFile() && !info.isSymbolicLink();
    } catch (_) {
      return false;
    }
  }, 'PG fixture continuation after history aging', 300000);
  state.continueFileObserved = true;
}

async function triggerSync(page) {
  await waitForSemanticText(page, 'Sync health');
  const manual = page.getByRole('button', { name: 'Sync now', exact: true });
  await manual.waitFor({ state: 'visible', timeout: 15000 });
  await manual.click();
}

async function cleanup() {
  const results = await Promise.allSettled(
    [state.contextA, state.contextB].filter(Boolean).map((context) => context.close()),
  );
  const browserAClosed = state.browserA
    ? await state.browserA.close().then(() => true, () => false)
    : true;
  for (const socket of SOCKETS) socket.destroy();
  let proxyClosed = true;
  if (state.proxyStarted) {
    proxyClosed = await new Promise((resolve) => {
      state.proxy.close(() => resolve(true));
      setTimeout(() => resolve(false), 5000).unref();
    });
    state.proxyStarted = false;
  }
  let tempRemoved = true;
  if (state.tempRoot && fs.existsSync(state.tempRoot)) {
    try { fs.rmSync(state.tempRoot, { recursive: true, force: true }); }
    catch (_) { tempRemoved = false; }
  }
  for (const filename of [config.readyFile, config.continueFile]) {
    try {
      if (fs.existsSync(filename) && fs.lstatSync(filename).isFile()) fs.unlinkSync(filename);
    } catch (_) {}
  }
  let noOpenPages = true;
  for (const context of [state.contextA, state.contextB].filter(Boolean)) {
    try { noOpenPages = noOpenPages && context.pages().length === 0; }
    catch (_) { noOpenPages = false; }
  }
  let browserDisconnected = true;
  try { browserDisconnected = !state.browserA?.isConnected(); }
  catch (_) { browserDisconnected = false; }
  state.cleaned = results.every((result) => result.status === 'fulfilled') &&
    browserAClosed && proxyClosed && tempRemoved && !state.proxy?.listening &&
    browserDisconnected && noOpenPages;
  return state.cleaned;
}

function finalResult() {
  const branch = state.target.branch || {};
  const exactUpload = state.bConflictUploads.filter((item) =>
    item.recordId === state.target.recordId && item.opId === branch.opId &&
    item.revisionId === branch.revisionId && item.baseRevisionId === branch.baseRevisionId &&
    item.envelopeSha256 === branch.envelopeSha256 && item.status >= 200 &&
    item.status < 300 && item.conflictId);
  const cursor410 = state.cursorExpiryChanges.find((item) => item.status === 410 &&
    item.errorCode === 'CURSOR_EXPIRED' && item.node === 'B');
  return {
    persistentBProfileRestarted: state.profileRestarted,
    cursorPresentBefore410: Boolean(cursor410?.cursorPresent && cursor410?.cursorNonempty),
    cursorExpired410Observed: Boolean(cursor410),
    outboxSameAcrossRestart: Boolean(state.outboxSameAcrossRestart &&
      state.pendingBeforeRestart > 0 && state.pendingAfterRestart > 0),
    outboxSameThrough410: Boolean(state.outboxSameThrough410 &&
      state.outboxAfter410?.opId === state.outboxBeforeRestart?.opId),
    noPendingBranchPushBeforeSnapshot: state.noPendingBranchPushBeforeSnapshot,
    snapshotCreatedOnB: state.bSnapshotCreates.some((item) => item.node === 'B' &&
      item.status >= 200 && item.status < 300),
    snapshotFetchedOnB: state.bSnapshotFetches.some((item) => item.node === 'B' &&
      item.status === 200),
    branchUploadedOnceAsConflict: exactUpload.length === 1,
    ownerHeadVisibleOnB: state.ownerHeadVisibleOnB,
    branchVisibleInConflictInbox: state.branchVisibleInConflictInbox,
    pageErrors: browserErrors.page,
    consoleErrors: unexpectedConsoleErrorCount(),
    totalConsoleErrors: browserErrors.console,
    expectedOfflineConsoleErrors: browserErrors.expectedOfflineConsoleErrors,
    expectedCursorExpiryConsoleErrors: browserErrors.expectedCursorExpiryConsoleErrors,
    expectedCursorExpiryHttpCount: API_ROUTES.filter((entry) =>
      entry.method === 'GET' && entry.path === `/api/v1/vaults/${state.target.vaultId}/changes` &&
      entry.status === 410 && entry.cursorPresent && entry.cursorNonempty).length,
    consoleErrorClasses: { ...browserErrors.consoleErrorClasses },
    resourceLoadClasses: { ...browserErrors.resourceLoadClasses },
    resourceLoadPaths: browserErrors.resourceLoadPaths.slice(0, 20),
    resourceHttpFailures: browserErrors.resourceHttpFailures.slice(0, 20),
    browserConsoleAcceptancePasses: browserErrors.page === 0 &&
      unexpectedConsoleErrorCount() === 0 && browserErrors.expectedOfflineConsoleErrors <= 5 &&
      unexpectedRequestFailureCount() === 0 &&
      browserErrors.expectedCursorExpiryConsoleErrors <= API_ROUTES.filter((entry) =>
        entry.method === 'GET' && entry.path === `/api/v1/vaults/${state.target.vaultId}/changes` &&
        entry.status === 410 && entry.cursorPresent && entry.cursorNonempty).length,
    failedRequests: unexpectedRequestFailureCount(),
    expectedCursorExpiryRequestFailures: expectedCursorExpiryRequestFailureCount(),
    expectedOfflineRequestFailures: browserErrors.expectedOfflineFailures,
    browserCleanupComplete: state.cleaned,
    vaultId: state.target.vaultId,
    recordId: state.target.recordId,
    baselineSeq: state.target.baselineSeq,
    ownerHeadRevisionId: state.target.ownerHeadRevisionId,
    branchOpId: branch.opId || null,
    branchRevisionId: branch.revisionId || null,
    branchBaseRevisionId: branch.baseRevisionId || null,
    branchEnvelopeSha256: branch.envelopeSha256 || null,
    conflictId: state.target.conflictId || null,
    bChangesRequestCount: API_ROUTES.filter((entry) => entry.profile === 'B' &&
      entry.method === 'GET' && /\/changes$/i.test(entry.path)).length,
    bCursor410Count: state.cursorExpiryChanges.filter((item) => item.status === 410 &&
      item.errorCode === 'CURSOR_EXPIRED').length,
    pendingUiAfterRestart: state.pendingAfterRestart,
    pendingUiAfter410: state.pendingAfter410,
    branchConflictUploadCount: exactUpload.length,
  };
}

async function main() {
  assertConfig();
  try {
    await createOwnerAndEnrollSecondDevice();
    await createBaselineAndSyncB();
    await runRecoveryAfterBaseline();
  } catch (error) {
    let safeMessage = typeof error?.message === 'string' ? error.message : '';
    for (const secret of sensitiveValues) safeMessage = safeMessage.split(secret).join('[redacted]');
    const recentRoutes = API_ROUTES.slice(-12).map((entry) => ({
      profile: entry.profile,
      method: entry.method,
      path: entry.path,
      node: entry.node,
      status: entry.status,
    }));
    console.error(`PG cursor recovery stopped at ${state.phase}; error type=${error?.name || 'Error'}; ` +
      `safe message=${JSON.stringify(safeMessage.slice(0, 1200))}; ` +
      `consoleErrorClasses=${JSON.stringify(browserErrors.consoleErrorClasses)}; ` +
      `resourceLoadClasses=${JSON.stringify(browserErrors.resourceLoadClasses)}; ` +
      `expectedOfflineConsoleErrors=${browserErrors.expectedOfflineConsoleErrors}; ` +
      `pendingBeforeRestart=${state.pendingBeforeRestart}; ` +
      `capturedBBranches=${state.bBranchPushes.length}; recentRoutes=${JSON.stringify(recentRoutes)}`);
    process.exitCode = 1;
  } finally {
    await cleanup();
    const result = finalResult();
    console.log(`PG-CURSOR-RECOVERY-RESULT ${JSON.stringify(result)}`);
    if (!result.browserConsoleAcceptancePasses) process.exitCode = 1;
    if (!state.cleaned) process.exitCode = 1;
  }
}

async function runRecoveryAfterBaseline() {
  state.phase = 'take B offline and queue same-Host branch';
  const originalName = config.hostName;
  const branchName = `${config.hostName} offline branch`;
  const ownerHeadName = `${config.hostName} owner head`;
  state.bOffline = true;
  state.blockBPush = true;
  await state.contextB.setOffline(true);
  await editHostName(state.pageB, originalName, branchName);
  state.pendingBeforeRestart = await waitPending(state.pageB, 1);
  state.outboxBeforeRestart = await snapshotBPendingOperation('before profile restart');
  state.target.branch = state.outboxBeforeRestart;
  assertThat(state.target.branch.baseRevisionId === state.target.baselineRevisionId,
    'offline branch did not retain the baseline revision');

  state.phase = 'commit competing A owner head';
  const ownerHeadPushPromise = capturePushAndReceipt(state.pageA, 'A', 'owner-head');
  await editHostName(state.pageA, originalName, ownerHeadName);
  const ownerHead = await ownerHeadPushPromise;
  assertThat(ownerHead.request?.recordId === state.target.recordId &&
    ownerHead.request?.baseRevisionId === state.target.baselineRevisionId &&
    ownerHead.request?.revisionId && ownerHead.receipt?.status >= 200 &&
    ownerHead.receipt?.status < 300 && ownerHead.receipt?.commitSeq,
  'A competing revision was not committed from the common baseline');
  state.target.ownerHeadRevisionId = ownerHead.request.revisionId;

  state.phase = 'restart B persistent browser profile';
  await state.contextB.close();
  state.contextB = null;
  state.pageB = null;
  state.bOffline = false;
  state.contextB = await chromium.launchPersistentContext(state.userDataDir, {
    ...newBrowserOptions(),
    locale: 'en-US', viewport: { width: 1440, height: 1000 },
  });
  state.profileRestarted = true;
  await state.contextB.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseOrigin });
  await state.contextB.setExtraHTTPHeaders({ 'x-atermius-e2e-profile': 'B' });
  await installBOfflinePushGate(state.contextB);
  await state.contextB.routeWebSocket('**/api/v1/notifications', (socket) => socket.connectToServer());
  state.pageB = state.contextB.pages()[0] || await state.contextB.newPage();
  attachPageObservers(state.pageB, 'B');

  state.phase = 'inspect persistent B IndexedDB after profile relaunch';
  await state.pageB.goto(`${baseOrigin}/__pg_cursor_idb_probe__`, { waitUntil: 'domcontentloaded' });
  state.outboxAfterRestart = await snapshotBPendingOperation('after profile relaunch');
  state.outboxSameAcrossRestart = samePendingOperation(
    state.outboxBeforeRestart, state.outboxAfterRestart);
  assertThat(state.outboxSameAcrossRestart,
    'B persistent IndexedDB changed the queued Host operation across profile restart');

  state.phase = 'READY barrier before B reconnect';
  await writeReadyAndWait();

  state.phase = 'reconnect B and observe cursor-expired 410';
  state.requestStartAt = Date.now();
  await waitForBWorkspaceAfterRestart();
  await waitWorkspace(state.pageB);
  state.pendingAfterRestart = await waitPending(state.pageB, 1);
  await waitFor(() => state.cursorExpiryChanges.some((item) => item.status === 410 &&
    item.errorCode === 'CURSOR_EXPIRED' && item.cursorPresent && item.cursorNonempty &&
    item.node === 'B'), 'PG node B GET /changes 410 CURSOR_EXPIRED with a cursor', 60000);
  state.pendingAfter410 = await pendingCount(state.pageB);
  state.outboxAfter410 = await snapshotBPendingOperation('after CURSOR_EXPIRED 410');
  state.outboxSameThrough410 = samePendingOperation(
    state.outboxBeforeRestart, state.outboxAfter410);
  assertThat(state.outboxSameThrough410,
    'B persistent IndexedDB changed the queued Host operation through HTTP 410');

  state.phase = 'show Rebuild snapshot action with branch still queued';
  await click(state.pageB, 'Sync & conflicts');
  await waitForSemanticText(state.pageB,
    'The sync cursor expired or the server generation changed.');
  const pendingBeforeSnapshot = await pendingCount(state.pageB);
  const preSnapshotBranchPushes = state.bBranchPushes.filter((item) =>
    item.atMs >= state.requestStartAt && item.recordId === state.target.recordId);
  state.noPendingBranchPushBeforeSnapshot = preSnapshotBranchPushes.length === 0;
  assertThat(state.pendingAfterRestart > 0 && state.outboxSameThrough410 &&
    state.noPendingBranchPushBeforeSnapshot,
  'B outbox was not retained through 410 or was pushed before explicit recovery');
  const rebuild = await button(state.pageB, 'Rebuild snapshot');
  await waitFor(() => rebuild.isEnabled().catch(() => false),
    'Rebuild snapshot to become enabled after the expired pull settles', 30000);
  assertThat(await rebuild.isEnabled(), 'Rebuild snapshot was not enabled after cursor expiry');

  state.phase = 'create/fetch verified snapshot and upload exact branch as conflict';
  state.recoveryStartedAt = Date.now();
  await rebuild.click();
  await waitFor(() => state.bSnapshotCreates.some((item) => item.atMs >= state.recoveryStartedAt &&
    item.node === 'B' && item.status >= 200 && item.status < 300),
  'snapshot creation through node B', 60000);
  await waitFor(() => state.bSnapshotFetches.some((item) => item.atMs >= state.recoveryStartedAt &&
    item.node === 'B' && item.status === 200), 'snapshot fetch through node B', 60000);
  await waitFor(() => state.bConflictUploads.some((item) => item.atMs >= state.recoveryStartedAt &&
    item.status >= 200 && item.status < 300 && item.conflictId),
  'conflict upload response from node B', 60000);
  await waitForSemanticText(state.pageB, '快照恢复完成', 60000);
  const exactUploads = state.bConflictUploads.filter((item) =>
    item.atMs >= state.recoveryStartedAt && item.recordId === state.target.recordId &&
    item.status >= 200 && item.status < 300 && item.conflictId &&
    item.opId === state.target.branch.opId &&
    item.revisionId === state.target.branch.revisionId &&
    item.baseRevisionId === state.target.branch.baseRevisionId &&
    item.envelopeSha256 === state.target.branch.envelopeSha256);
  assertThat(exactUploads.length === 1,
    'snapshot recovery did not upload the exact pre-restart branch exactly once');
  state.target.conflictId = exactUploads[0].conflictId;
  state.blockBPush = false;

  state.phase = 'verify remote owner head and conflict inbox in B UI';
  await click(state.pageB, 'Hosts');
  state.ownerHeadVisibleOnB = await waitHostVisible(state.pageB,
    `${config.hostName} owner head`, `${config.hostAddress}:22`);
  assertThat(state.ownerHeadVisibleOnB, 'B did not render A owner head after snapshot');
  await clickWorkspaceNavigation(state.pageB, 'Sync & conflicts');
  await waitForSemanticText(state.pageB, '跨设备冲突收件箱');
  await triggerSync(state.pageB);
  state.branchVisibleInConflictInbox = await waitFor(() => state.pageB.evaluate((expected) => {
    const visible = [...document.querySelectorAll('flt-semantics')].filter((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    return visible.some((node) => `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`
      .includes(expected));
  }, `${config.hostName} owner head`).catch(() => false),
  'branch conflict visible in B conflict inbox', 30000);
  assertThat(state.branchVisibleInConflictInbox,
    'B conflict inbox did not render the owner head for its preserved branch');

  const changes410 = state.cursorExpiryChanges.find((item) => item.status === 410 &&
    item.errorCode === 'CURSOR_EXPIRED' && item.node === 'B');
  assertThat(changes410?.cursorPresent && changes410?.cursorNonempty,
    'actual B GET /changes request omitted its persisted nonempty cursor');
  const bHistoryRoutes = API_ROUTES.filter((entry) => entry.profile === 'B' &&
    entry.method === 'GET' && /\/changes$/i.test(entry.path));
  const bSnapshotRoutes = API_ROUTES.filter((entry) => entry.profile === 'B' &&
    (entry.path.endsWith('/snapshots') || /^\/api\/v1\/snapshots\//.test(entry.path)));
  const bConflictRoutes = API_ROUTES.filter((entry) => entry.profile === 'B' &&
    /\/conflicts(?:\/|$)/i.test(entry.path));
  assertThat(bHistoryRoutes.some((entry) => entry.node === 'B' && entry.status === 410),
    '410 /changes did not route to PG node B');
  assertThat(bSnapshotRoutes.length >= 2 && bSnapshotRoutes.every((entry) => entry.node === 'B'),
    'snapshot operations did not route to PG node B');
  assertThat(bConflictRoutes.some((entry) => entry.node === 'B' && entry.status >= 200 &&
    entry.status < 300), 'conflict upload did not route to PG node B');
}

main().catch((error) => {
  console.error(`PG cursor recovery failed safely (${error?.name || 'Error'})`);
  process.exitCode = 1;
});
