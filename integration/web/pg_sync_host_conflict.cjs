/*
 * PG-SYNC-HOST-CONFLICT-01: two approved Web devices make conflicting offline
 * Host connection edits. B uploads stale signed branches through PostgreSQL
 * node B; A reviews and resolves both in the Web UI. For the adopted branch,
 * node A commits /resolve while its response is held; a same-profile sibling
 * tab applies that exact resolved feed event before the response is released.
 * The keep-current resolution still exercises a lost-ack replay through node
 * B. The pytest parent verifies the PG ledger. This runner emits identifiers
 * and sanitized evidence only.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const {
  reconstructSqliteFile,
  SQLITE_BLOCK_SIZE,
} = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.resolve(process.env.ATERMIUS_PG_CONFLICT_WEB_ROOT ||
  path.join(ROOT, 'apps/client/build/web'));
const DATABASE_NAME = 'atermius_vault';
const BASE_URL = process.env.ATERMIUS_PG_CONFLICT_BASE_URL;
const NODE_A_URL = process.env.ATERMIUS_PG_CONFLICT_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_CONFLICT_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_CONFLICT_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_CONFLICT_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_CONFLICT_BOOTSTRAP_TOKEN;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = require('node:crypto').randomBytes(10).toString('hex');
const BASE_NAME = process.env.ATERMIUS_PG_CONFLICT_BASE_NAME || `pg-conflict-${RUN_ID}`;
const BASE_TAG = process.env.ATERMIUS_PG_CONFLICT_BASE_TAG || `tag-${RUN_ID}`;
const HOST_ADDRESS = process.env.ATERMIUS_PG_CONFLICT_HOST_ADDRESS || `base-${RUN_ID}.pg-conflict.example.test`;
const OWNER_HOSTNAME = process.env.ATERMIUS_PG_CONFLICT_OWNER_HOSTNAME || `owner-${RUN_ID}.pg-conflict.example.test`;
const BRANCH_HOSTNAME = process.env.ATERMIUS_PG_CONFLICT_BRANCH_HOSTNAME || `branch-${RUN_ID}.pg-conflict.example.test`;
const KEEP_OWNER_HOSTNAME = process.env.ATERMIUS_PG_CONFLICT_KEEP_OWNER_HOSTNAME || `keep-owner-${RUN_ID}.pg-conflict.example.test`;
const KEEP_BRANCH_HOSTNAME = process.env.ATERMIUS_PG_CONFLICT_KEEP_BRANCH_HOSTNAME || `keep-branch-${RUN_ID}.pg-conflict.example.test`;
const BRANCH_PORT = '22';
const MAX_EXPECTED_OFFLINE_FAILURES = 24;
const MAX_EXPECTED_OFFLINE_FAILURES_PER_PROFILE_ROUTE = 6;
const OFFLINE_API_ROUTE_CATEGORIES = new Set([
  'account-devices', 'vault-devices', 'vault-changes', 'conflict-changes',
  'vault-presence', 'sync-push', 'conflict-create', 'conflict-resolve', 'notifications',
]);
const SSH_USERNAME = process.env.ATERMIUS_PG_CONFLICT_SSH_USERNAME || `synthetic-${RUN_ID}`;
const BASE_ENDPOINT = `${HOST_ADDRESS}:22`;
const OWNER_ENDPOINT = `${OWNER_HOSTNAME}:22`;
const BRANCH_ENDPOINT = `${BRANCH_HOSTNAME}:${BRANCH_PORT}`;
const KEEP_OWNER_ENDPOINT = `${KEEP_OWNER_HOSTNAME}:${BRANCH_PORT}`;
const KEEP_BRANCH_ENDPOINT = `${KEEP_BRANCH_HOSTNAME}:${BRANCH_PORT}`;
const MARKERS = [BASE_NAME, BASE_TAG, HOST_ADDRESS, OWNER_HOSTNAME,
  BRANCH_HOSTNAME, KEEP_OWNER_HOSTNAME, KEEP_BRANCH_HOSTNAME, SSH_USERNAME];
const API_ROUTES = [];
const PUSHES = [];
const CHANGES = [];
const CONFLICT_FEEDS = [];
const RESOLUTION_ATTEMPTS = new Map();
const BROWSER_DIAGNOSTICS = [];
let lostAckConflictId = null;
let lostAckInjectedConflictId = null;
let delayedAckConflictId = null;
let heldResolutionAck = null;
let tempRoot = null;
const DRIFT_BACKEND_MARKERS = { A: 0, 'A-sibling': 0, B: 0 };
const EXPECTED_DEVICE_REQUEST_ABORTS = [];
const EXPECTED_OFFLINE_FAILURES = [];
const EXPECTED_OFFLINE_CONSOLE_ERRORS = [];
const expectedDeviceAbortWindows = new Map();
const ERRORS = {
  page: 0,
  console: 0,
  unexpectedRequest: 0,
  unexpectedOfflineRequest: 0,
  expectedOfflineFailure: 0,
  expectedLostAckFailure: 0,
};
const intentionallyOfflineProfiles = new Set();

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function upstreamFor(value) {
  const url = new URL(value || '');
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1',
    'PG merge acceptance requires loopback node URLs');
  return { hostname: url.hostname, port: Number(url.port) };
}

const upstreamA = upstreamFor(NODE_A_URL);
const upstreamB = upstreamFor(NODE_B_URL);

function profileFrom(headers) {
  return headers['x-pg-acceptance-profile'] === 'B' ? 'B' : 'A';
}

function nodeFor(method, pathname, profile, upgrade = false) {
  const resolutionMatch = method === 'POST'
    ? pathname.match(/^\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts\/([0-9a-f-]+)\/resolve$/i)
    : null;
  if (resolutionMatch && resolutionMatch[1] === delayedAckConflictId) return 'A';
  if (resolutionMatch && resolutionMatch[1] === lostAckConflictId) {
    const attempts = RESOLUTION_ATTEMPTS.get(pathname) || 0;
    RESOLUTION_ATTEMPTS.set(pathname, attempts + 1);
    return attempts === 0 ? 'A' : 'B';
  }
  if (upgrade && pathname === '/api/v1/notifications') return profile === 'B' ? 'B' : 'A';
  if (method === 'GET' && /^\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(pathname)) {
    return profile === 'B' ? 'B' : 'A';
  }
  if (method === 'POST' && /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(pathname)) {
    return profile === 'B' ? 'B' : 'A';
  }
  return profile === 'B' ? 'B' : 'A';
}

function markerFree(serialized) {
  return !MARKERS.some((marker) => marker && serialized.includes(marker));
}

function feedTabMatchesScope(feedProfile, requestedProfile) {
  return requestedProfile === 'A'
    ? feedProfile === 'A' || feedProfile === 'A-sibling'
    : feedProfile === requestedProfile;
}

function deviceRequestRoute(pathname) {
  if (pathname === '/api/v1/devices') return 'account-devices';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/devices$/i.test(pathname)) {
    return 'vault-devices';
  }
  return null;
}

function offlineApiPathCategory(pathname) {
  if (pathname === '/api/v1/devices') return 'account-devices';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/devices$/i.test(pathname)) return 'vault-devices';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(pathname)) return 'vault-changes';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/conflict-changes$/i.test(pathname)) return 'conflict-changes';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/presence$/i.test(pathname)) return 'vault-presence';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(pathname)) return 'sync-push';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts$/i.test(pathname)) return 'conflict-create';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts\/[0-9a-f-]+\/resolve$/i.test(pathname)) {
    return 'conflict-resolve';
  }
  if (pathname === '/api/v1/notifications') return 'notifications';
  return null;
}

function offlineRequestCategory(method, pathname) {
  const category = offlineApiPathCategory(pathname);
  if (!category) return null;
  if (category === 'sync-push' || category === 'conflict-create' ||
      category === 'conflict-resolve') return method === 'POST' ? category : null;
  if (category === 'vault-presence') {
    return method === 'GET' || method === 'POST' ? category : null;
  }
  return method === 'GET' ? category : null;
}

function summarizeOfflineCounts(entries) {
  const counts = new Map();
  for (const item of entries) {
    const key = `${item.profile}/${item.route}`;
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts.entries()].map(([key, count]) => {
    const slash = key.indexOf('/');
    return { profile: key.slice(0, slash), route: key.slice(slash + 1), count };
  }).sort((left, right) => left.profile.localeCompare(right.profile) ||
    left.route.localeCompare(right.route));
}

function redactSyntheticValues(value) {
  const values = [USERNAME, PASSWORD, BOOTSTRAP_TOKEN, ...MARKERS]
    .filter((item) => typeof item === 'string' && item.length > 0)
    .sort((left, right) => right.length - left.length);
  return values.reduce((text, item) => text.split(item).join('[redacted]'), String(value));
}

function releaseHeldResolutionAck() {
  const held = heldResolutionAck;
  if (!held) return false;
  heldResolutionAck = null;
  try {
    held.response.writeHead(held.statusCode, held.headers);
    held.response.end(held.body);
    held.record.status = held.statusCode;
    held.record.clientStatus = held.statusCode;
    held.record.delayedAckReleased = true;
    return true;
  } catch (_) {
    held.record.delayedAckReleaseFailed = true;
    held.response.destroy();
    return false;
  }
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url || '/', BASE_URL);
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const profile = profileFrom(request.headers);
    const node = nodeFor(request.method || 'GET', url.pathname, profile);
    const upstream = node === 'B' ? upstreamB : upstreamA;
    const record = {
      method: request.method || 'GET', path: url.pathname, profile, node,
      tab: request.headers['x-pg-acceptance-tab'] || 'primary',
      status: null, atMs: Date.now(),
    };
    const isPush = record.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(record.path);
    const isPresenceHeartbeat = record.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/presence$/i
        .test(record.path);
    const isConflictUpload = record.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts$/i.test(record.path);
    const isConflictResolution = record.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts\/[0-9a-f-]+\/resolve$/i.test(record.path);
    if (isPush || isConflictUpload || isConflictResolution) {
      const bodyChunks = [];
      request.on('data', (chunk) => bodyChunks.push(chunk));
      request.on('end', () => {
        try {
          const body = JSON.parse(Buffer.concat(bodyChunks).toString('utf8'));
          if (isPush) {
            record.operations = Array.isArray(body?.operations)
              ? body.operations.map((item) => ({
                recordId: item?.header?.record_id || null,
                operationId: item?.header?.op_id || null,
                revisionId: item?.header?.revision_id || null,
                baseRevisionId: item?.header?.base_revision_id || null,
                deviceId: item?.header?.device_id || null,
                operation: item?.header?.operation || null,
              })) : [];
            record.operationIds = record.operations.map((item) => item.operationId)
              .filter((value) => typeof value === 'string');
            record.markerFree = markerFree(JSON.stringify(body));
          } else if (isConflictUpload) {
            const header = body?.envelope?.header || {};
            record.operation = {
              recordId: header.record_id || null,
              operationId: header.op_id || null,
              revisionId: header.revision_id || null,
              baseRevisionId: header.base_revision_id || null,
              deviceId: header.device_id || null,
              operation: header.operation || null,
            };
            record.markerFree = markerFree(JSON.stringify(body));
          } else {
            record.operationId = typeof body?.op_id === 'string' ? body.op_id : null;
            record.requestOpIdAbsent = !Object.hasOwn(body || {}, 'op_id');
            record.requestedResolvedRevisionId = typeof body?.resolved_revision_id === 'string'
              ? body.resolved_revision_id : null;
            record.resolvedRevisionId = record.requestedResolvedRevisionId;
            record.markerFree = markerFree(JSON.stringify(body));
          }
        } catch (_) {
          record.parseFailed = true;
        }
      });
    }
    if (url.pathname.startsWith('/api/v1/')) API_ROUTES.push(record);
    const headers = { ...request.headers, host: `127.0.0.1:${upstream.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    delete headers['x-pg-acceptance-tab'];
    delete headers['x-pg-acceptance-tab'];
    const upstreamRequest = http.request({
      hostname: upstream.hostname,
      port: upstream.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      record.upstreamStatus = upstreamResponse.statusCode || null;
      record.status = record.upstreamStatus;
      const inspectPresenceRateLimit = isPresenceHeartbeat && record.status === 429;
      const inspectBody = /\/conflicts(?:\/[^/]+\/resolve)?$|\/conflict-changes$/i
        .test(record.path) || inspectPresenceRateLimit;
      const delayedAckTarget = delayedAckConflictId &&
        record.path.endsWith(`/conflicts/${delayedAckConflictId}/resolve`);
      const keepCurrentAckTarget = lostAckConflictId &&
        record.path.endsWith(`/conflicts/${lostAckConflictId}/resolve`);
      const bufferResolutionAck = isConflictResolution &&
        (delayedAckTarget || keepCurrentAckTarget);
      const responseChunks = [];
      if (inspectBody) upstreamResponse.on('data', (chunk) => responseChunks.push(chunk));
      if (inspectBody) upstreamResponse.on('end', () => {
        let body = null;
        try {
          body = JSON.parse(Buffer.concat(responseChunks).toString('utf8'));
          record.responseMarkerFree = markerFree(JSON.stringify(body));
          if (inspectPresenceRateLimit) {
            if (body?.error?.code === 'PRESENCE_HEARTBEAT_RATE_LIMITED') {
              record.expectedHttpErrorCategory = 'presence_heartbeat_rate_limited';
            }
          } else if (/\/conflicts$/i.test(record.path)) {
            record.conflictId = typeof body?.conflict_id === 'string' ? body.conflict_id : null;
            record.recordId = typeof body?.record_id === 'string' ? body.record_id : null;
            record.revisionId = typeof body?.revision_id === 'string' ? body.revision_id : null;
          } else if (/\/conflict-changes$/i.test(record.path)) {
            record.conflictEvents = Array.isArray(body?.events) ? body.events.map((event) => ({
              seq: event?.seq || null,
              type: event?.type || null,
              conflictId: event?.conflict_id || null,
              recordId: event?.record_id || null,
              resolvedRevisionId: event?.resolved_revision_id || null,
              hasEnvelope: Object.hasOwn(event || {}, 'envelope'),
            })) : [];
          } else if (/\/resolve$/i.test(record.path)) {
            record.resolvedRevisionId = typeof body?.resolved_revision_id === 'string'
              ? body.resolved_revision_id : record.resolvedRevisionId || null;
            record.resolutionStatus = typeof body?.status === 'string' ? body.status : null;
            record.resolutionSeq = typeof body?.resolution_seq === 'string'
              ? body.resolution_seq : null;
            record.alreadyResolved = typeof body?.already_resolved === 'boolean'
              ? body.already_resolved : null;
          }
        } catch (_) {
          record.responseParseFailed = true;
        }
        if (!bufferResolutionAck) {
          record.clientStatus = record.upstreamStatus;
          return;
        }
        const shouldDelayResolutionAck = delayedAckTarget &&
          record.upstreamStatus === 200 && body?.status === 'resolved' &&
          body?.already_resolved === false &&
          record.requestOpIdAbsent === true && record.operationId === null &&
          record.requestedResolvedRevisionId === body?.resolved_revision_id;
        if (shouldDelayResolutionAck) {
          assertThat(heldResolutionAck === null,
            'a second resolution response reached the active delayed-ack barrier');
          record.simulatedDelayedAck = true;
          record.delayedAckHeld = true;
          record.status = null;
          record.clientStatus = null;
          heldResolutionAck = {
            response,
            statusCode: upstreamResponse.statusCode || 502,
            headers: upstreamResponse.headers,
            body: Buffer.concat(responseChunks),
            record,
          };
          return;
        }
        const shouldLoseResolutionAck =
          record.upstreamStatus === 200 && body?.status === 'resolved' &&
          body?.already_resolved === false &&
          keepCurrentAckTarget && lostAckInjectedConflictId !== lostAckConflictId;
        if (shouldLoseResolutionAck) {
          lostAckInjectedConflictId = lostAckConflictId;
          record.simulatedLostAck = true;
          record.status = null;
          record.clientStatus = null;
          response.destroy();
          return;
        }
        record.clientStatus = record.status;
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        response.end(Buffer.concat(responseChunks));
      });
      if (!bufferResolutionAck) {
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      }
      if (bufferResolutionAck) return;
      upstreamResponse.pipe(response);
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    request.pipe(upstreamRequest);
  });

  const sockets = new Set();
  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', BASE_URL);
    const profile = profileFrom(request.headers);
    const node = nodeFor('GET', url.pathname, profile, true);
    const upstream = node === 'B' ? upstreamB : upstreamA;
    const headers = { ...request.headers, host: `127.0.0.1:${upstream.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    const upstreamRequest = http.request({
      hostname: upstream.hostname,
      port: upstream.port,
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
      sockets.add(clientSocket);
      sockets.add(upstreamSocket);
      clientSocket.on('close', () => sockets.delete(clientSocket));
      upstreamSocket.on('close', () => sockets.delete(upstreamSocket));
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
  server._sockets = sockets;
  return server;
}

const proxy = makeProxy();

function input(page, label) {
  return page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`);
}

async function field(page, label) {
  const locator = input(page, label);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = [];
    for (let index = 0; index < await locator.count(); index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) visible.push(locator.nth(index));
    }
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`field unavailable: ${label}`);
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.pressSequentially(value, { delay: 15 });
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `field did not retain value: ${label}`);
  await locator.press('Tab');
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  await locator.first().waitFor({ state: 'visible', timeout: 20000 });
  return locator.first();
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function waitUntil(predicate, description, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function enterFlutterSemantics(page, { navigate = true } = {}) {
  if (navigate) await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
  await waitUntil(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web crypto module');
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitUntil(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics tree');
}

async function enterFlutter(page) {
  await enterFlutterSemantics(page);
  await click(page, 'Connect securely');
}

async function readIndexedDbSqliteImage(page) {
  return page.evaluate(async (databaseName) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
    });
    try {
      if (!db.objectStoreNames.contains('files') ||
          !db.objectStoreNames.contains('blocks')) {
        throw new Error('IDB VFS stores are missing');
      }
      const filesTx = db.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('file read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('file read aborted'));
      });
      const [rows, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file rows unavailable'));
        }),
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file keys unavailable'));
        }),
      ]);
      await filesComplete;
      const mainIndex = rows.findIndex((row) => row?.name === '/database' ||
        row?.name === `/${databaseName}/database` || row?.name?.endsWith('/database'));
      if (mainIndex < 0) throw new Error('main SQLite VFS file is missing');
      const fileId = Number(keys[mainIndex]);
      const blockTx = db.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blockTx.oncomplete = resolve;
        blockTx.onerror = () => reject(blockTx.error || new Error('block read failed'));
        blockTx.onabort = () => reject(blockTx.error || new Error('block read aborted'));
      });
      const range = IDBKeyRange.bound([fileId, 0], [fileId, Number.MAX_SAFE_INTEGER]);
      const [blockKeys, values] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = blockTx.objectStore('blocks').getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('block keys unavailable'));
        }),
        new Promise((resolve, reject) => {
          const request = blockTx.objectStore('blocks').getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('block bytes unavailable'));
        }),
      ]);
      await blocksComplete;
      const blocks = blockKeys.map((key, index) => {
        const value = values[index];
        const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
          ArrayBuffer.isView(value)
            ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
            : null;
        if (!bytes) throw new Error('unsupported SQLite VFS block');
        let binary = '';
        for (let offset = 0; offset < bytes.length; offset += 8192) {
          binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
        }
        return { offset: Number(key?.[1]), base64: btoa(binary) };
      });
      return { fileId, name: String(rows[mainIndex].name),
        length: Number(rows[mainIndex].length), blocks };
    } finally {
      db.close();
    }
  }, DATABASE_NAME);
}

function inspectFeedResolutionSqlite(snapshotPath, conflictId, recordId) {
  const script = String.raw`
import json,sqlite3,sys
path,conflict_id,record_id=sys.argv[1:4]
db=sqlite3.connect('file:'+path+'?mode=ro',uri=True,timeout=8)
db.row_factory=sqlite3.Row
targets=[dict(row) for row in db.execute(
 'SELECT conflict_id,record_id,op_id,resolution_revision_id,state '
 'FROM feed_conflict_resolutions WHERE conflict_id=?',(conflict_id,))]
pending=[dict(row) for row in db.execute(
 'SELECT op_id,record_id,status FROM pending_operations WHERE record_id=? ORDER BY created_at,op_id',(record_id,))]
events=[]
for row in db.execute(
 'SELECT i.seq,i.event_json,c.after_seq FROM conflict_feed_inbox i '
 'JOIN conflict_feed_states s ON s.vault_id=i.vault_id '
 'AND s.server_generation=i.server_generation AND s.partition_id=i.partition_id '
 'JOIN conflict_feed_checkpoints c ON c.vault_id=i.vault_id '
 'AND c.server_generation=i.server_generation AND c.partition_id=i.partition_id '
 'WHERE i.conflict_id=? AND i.event_type=\'resolved\' ORDER BY i.seq',(conflict_id,)):
 try: event=json.loads(row['event_json'])
 except Exception: event={}
 events.append({'seq':row['seq'],'afterSeq':row['after_seq'],
  'type':event.get('type'),'conflictId':event.get('conflict_id'),
  'recordId':event.get('record_id'),'resolvedRevisionId':event.get('resolved_revision_id'),
  'hasEnvelope':'envelope' in event})
print(json.dumps({'targets':targets,'pending':pending,'events':events},separators=(',',':')))
db.close()
`;
  const result = spawnSync('python3', ['-c', script, snapshotPath, conflictId, recordId], {
    cwd: ROOT, encoding: 'utf8', timeout: 15000, maxBuffer: 256 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'same-profile feed-resolution SQLite query failed');
  return JSON.parse(result.stdout);
}

async function snapshotFeedResolution(page, suffix, conflictId, recordId) {
  const snapshotPath = path.join(tempRoot, `feed-resolution-${suffix}.sqlite`);
  try {
    const image = await readIndexedDbSqliteImage(page);
    assertThat(image.length > 0 && image.length <= 64 * 1024 * 1024 &&
      image.length % SQLITE_BLOCK_SIZE === 0,
    'same-profile client SQLite VFS image was not aligned');
    const bytes = reconstructSqliteFile({
      fileId: image.fileId,
      name: image.name,
      length: image.length,
      blocks: image.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
    fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'w' });
    return inspectFeedResolutionSqlite(snapshotPath, conflictId, recordId);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function resolvedLocalEvidence(snapshot, conflictId, revisionId, seq) {
  const target = snapshot?.targets?.find((item) => item.conflict_id === conflictId);
  const event = snapshot?.events?.find((item) => item.conflictId === conflictId);
  return Boolean(target && target.state === 'resolved' &&
    target.resolution_revision_id === revisionId && target.op_id &&
    event && event.type === 'resolved' && event.resolvedRevisionId === revisionId &&
    event.seq === seq && Number(event.afterSeq) >= Number(seq) &&
    event.hasEnvelope === false && snapshot.pending?.length === 0);
}

async function connect(page) {
  await fill(page, 'Server URL', BASE_URL);
  await click(page, 'Connect securely');
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `clipboard field did not retain ${label}`);
}

function setupObservers(page, profile) {
  const pushesByRequest = new WeakMap();
  const offlineRequests = new WeakSet();
  const lostAckResolutionRequests = new WeakSet();
  page.on('pageerror', () => { ERRORS.page += 1; });
  page.on('console', (message) => {
    const messageText = message.text();
    const backendMatch = messageText.match(/^ATERMIUS_DRIFT_WEB_IMPLEMENTATION=(\w+)$/);
    if (backendMatch?.[1] === 'sharedIndexedDb' &&
        Object.hasOwn(DRIFT_BACKEND_MARKERS, profile)) {
      DRIFT_BACKEND_MARKERS[profile] += 1;
    }
    if (message.type() !== 'error') return;
    const locationUrl = message.location()?.url || '';
    let consolePath = null;
    try { consolePath = new URL(locationUrl).pathname; } catch (_) {}
    const offlineConsoleRoute = consolePath ? offlineApiPathCategory(consolePath) : null;
    if (intentionallyOfflineProfiles.has(profile) && offlineConsoleRoute &&
        /^Failed to load resource: net::ERR_INTERNET_DISCONNECTED\.?$/.test(messageText)) {
      EXPECTED_OFFLINE_CONSOLE_ERRORS.push({ profile, route: offlineConsoleRoute });
      return;
    }
    ERRORS.console += 1;
    if (BROWSER_DIAGNOSTICS.length < 8) {
      const location = message.location();
      BROWSER_DIAGNOSTICS.push({
        profile,
        kind: 'console',
        detail: redactSyntheticValues(message.text())
          .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
          .replace(/\s+/g, ' ').slice(0, 240),
        url: redactSyntheticValues(locationUrl)
          .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
          .slice(0, 180),
      });
    }
  });
  page.on('requestfailed', (request) => {
    const failureText = request.failure()?.errorText || '';
    const pathname = new URL(request.url()).pathname;
    const abortWindow = expectedDeviceAbortWindows.get(profile);
    const abortedDeviceRoute = deviceRequestRoute(pathname);
    if (abortWindow && request.method() === 'GET' && abortedDeviceRoute &&
        failureText === 'net::ERR_ABORTED') {
      EXPECTED_DEVICE_REQUEST_ABORTS.push({
        profile,
        route: abortedDeviceRoute,
        lifecycle: abortWindow,
      });
      return;
    }
    if (lostAckResolutionRequests.has(request)) {
      ERRORS.expectedLostAckFailure += 1;
      return;
    }
    if (offlineRequests.has(request)) {
      const offlineRoute = offlineRequestCategory(request.method(), pathname);
      if (failureText === 'net::ERR_INTERNET_DISCONNECTED' && offlineRoute) {
        ERRORS.expectedOfflineFailure += 1;
        EXPECTED_OFFLINE_FAILURES.push({ profile, route: offlineRoute });
      } else {
        ERRORS.unexpectedOfflineRequest += 1;
        if (BROWSER_DIAGNOSTICS.length < 8) {
          BROWSER_DIAGNOSTICS.push({
            profile,
            kind: 'unexpected-offline-request',
            detail: redactSyntheticValues(
              `${request.method()} ${pathname} ${failureText || 'unknown network failure'}`)
              .replace(/\s+/g, ' ').slice(0, 240),
          });
        }
      }
    } else {
      ERRORS.unexpectedRequest += 1;
      if (BROWSER_DIAGNOSTICS.length < 8) {
        BROWSER_DIAGNOSTICS.push({
          profile,
          kind: 'requestfailed',
          detail: redactSyntheticValues(`${request.method()} ${request.url()} ${request.failure()?.errorText || ''}`)
            .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
          .replace(/\s+/g, ' ').slice(0, 240),
      });
      }
    }
  });
  page.on('request', (request) => {
    if (intentionallyOfflineProfiles.has(profile)) offlineRequests.add(request);
    const url = new URL(request.url());
    if (profile === 'A' && request.method() === 'POST' &&
        lostAckConflictId && url.pathname.endsWith(`/conflicts/${lostAckConflictId}/resolve`)) {
      lostAckResolutionRequests.add(request);
    }
    if (request.method() !== 'POST' ||
        !/^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(url.pathname)) return;
    try {
      const body = request.postDataJSON();
      const operations = Array.isArray(body?.operations) ? body.operations : [];
      const refs = operations.map((item) => {
        const header = item?.header || {};
        return {
          recordId: header.record_id || null,
          operationId: header.op_id || null,
          revisionId: header.revision_id || null,
          baseRevisionId: header.base_revision_id || null,
          deviceId: header.device_id || null,
          operation: header.operation || null,
        };
      });
      const record = {
        profile,
        node: profile === 'B' ? 'B' : 'A',
        vaultId: body?.vault_id || null,
        refs,
        markerFree: markerFree(JSON.stringify(body)),
        atMs: Date.now(),
        status: null,
        commitSeqs: [],
      };
      PUSHES.push(record);
      pushesByRequest.set(request, record);
    } catch (_) {
      PUSHES.push({ profile, node: profile === 'B' ? 'B' : 'A', refs: [], markerFree: false, status: null });
    }
  });
  page.on('response', (response) => {
    const record = pushesByRequest.get(response.request());
    if (!record) return;
    record.status = response.status();
    void response.json().then((body) => {
      record.commitSeqs = Array.isArray(body?.results)
        ? body.results.map((item) => item?.commit_seq).filter((value) => typeof value === 'string')
        : [];
    }).catch(() => {});
  });
  page.on('response', (response) => {
    const request = response.request();
    const url = new URL(response.url());
    if (request.method() !== 'GET' || !url.pathname.endsWith('/changes')) return;
    void response.json().then((body) => {
      const serialized = JSON.stringify(body);
      const events = Array.isArray(body?.events) ? body.events : [];
      CHANGES.push({
        profile,
        node: profile === 'B' ? 'B' : 'A',
        status: response.status(),
        markerFree: markerFree(serialized),
        revisions: events.map((event) => ({
          recordId: event?.envelope?.header?.record_id,
          revisionId: event?.envelope?.header?.revision_id,
        })).filter((item) => typeof item.recordId === 'string' && typeof item.revisionId === 'string'),
      });
    }).catch(() => {});
  });
  page.on('response', (response) => {
    const request = response.request();
    const url = new URL(response.url());
    if (request.method() !== 'GET' || !url.pathname.endsWith('/conflict-changes')) return;
    void response.json().then((body) => {
      const serialized = JSON.stringify(body);
      const events = Array.isArray(body?.events) ? body.events : [];
      CONFLICT_FEEDS.push({
        profile,
        node: profile === 'B' ? 'B' : 'A',
        status: response.status(),
        markerFree: markerFree(serialized),
        events: events.map((event) => ({
          seq: typeof event?.seq === 'string' ? event.seq : null,
          type: event?.type || null,
          conflictId: event?.conflict_id || null,
          recordId: event?.record_id || null,
          resolvedRevisionId: event?.resolved_revision_id || null,
          hasEnvelope: Object.hasOwn(event || {}, 'envelope'),
        })),
      });
    }).catch(() => {});
  });
}

function routeForPush(push, recordId) {
  const operationIds = push.refs.filter((ref) => ref.recordId === recordId)
    .map((ref) => ref.operationId).filter((value) => typeof value === 'string');
  const matches = API_ROUTES.filter((route) => route.method === 'POST' &&
    route.profile === push.profile &&
    /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(route.path) &&
    Array.isArray(route.operationIds) &&
    route.operationIds.some((operationId) => operationIds.includes(operationId)));
  return matches.find((route) => route.status === push.status) || matches[0] || null;
}

function routeForConflictUpload(profile, operationId) {
  return API_ROUTES.find((route) => route.method === 'POST' &&
    route.profile === profile && /\/conflicts$/i.test(route.path) &&
    route.operation?.operationId === operationId &&
    route.status >= 200 && route.status < 300) || null;
}

function routeForResolution(profile, conflictId, resolvedRevisionId) {
  return API_ROUTES.find((route) => route.method === 'POST' &&
    route.profile === profile &&
    route.path.endsWith(`/conflicts/${conflictId}/resolve`) &&
    route.status === 200 && route.resolvedRevisionId === resolvedRevisionId) || null;
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function recoverSameProfileWorkspace(page) {
  await selectServerModeIfChooser(page);
  const deadline = Date.now() + 45000;
  let connected = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Settings', exact: true })
      .isVisible().catch(() => false)) {
      await waitWorkspace(page);
      return;
    }
    if (!connected && await input(page, 'Server URL').isVisible().catch(() => false)) {
      await page.waitForTimeout(350);
      if (await input(page, 'Email or username').isVisible().catch(() => false)) continue;
      if (!await input(page, 'Server URL').isVisible().catch(() => false)) continue;
      try {
        await fill(page, 'Server URL', BASE_URL);
        await click(page, 'Connect securely');
        connected = true;
      } catch (error) {
        if (error?.name !== 'TimeoutError') throw error;
      }
    } else if (!loginSubmitted && await input(page, 'Email or username')
      .isVisible().catch(() => false)) {
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', PASSWORD);
      await click(page, 'Sign in and unlock');
      loginSubmitted = true;
    }
    await page.waitForTimeout(120);
  }
  const visibleText = await page.locator('body').innerText().catch(() => '');
  throw new Error(`same-profile tab could not restore the Owner workspace: ${
    redactSyntheticValues(visibleText).replace(/\s+/g, ' ').slice(0, 320)}`);
}

function hostCard(page, recordId) {
  return page.locator(`flt-semantics[flt-semantics-identifier="ssh-host-${recordId}"]`);
}

async function hostValuesVisible(page, recordId, { name, tag, endpoint }) {
  try {
    return await hostCard(page, recordId).evaluate((root, expected) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
      };
      const text = [root, ...root.querySelectorAll('flt-semantics, [aria-label]')]
        .filter(visible)
        .map((element) => (element.getAttribute('aria-label') || element.innerText || '').trim())
        .join('\n');
      return text.startsWith(`Host: ${expected.name};`) && text.includes(expected.tag) &&
        text.includes(`@${expected.endpoint}`);
    }, { name, tag, endpoint });
  } catch (_) {
    return false;
  }
}

async function waitHost(page, recordId, values, description) {
  await waitUntil(() => hostValuesVisible(page, recordId, values), description, 45000);
}

async function scrollLastVisibleSemanticNodeContaining(page, text) {
  const matches = page.locator('flt-semantics').filter({ hasText: text });
  const evidence = {
    locatorCount: await matches.count().catch(() => 0),
    visibleLocatorCount: 0,
    scrollAttempted: false,
    scrollSucceeded: false,
  };
  for (let index = evidence.locatorCount - 1; index >= 0; index -= 1) {
    const candidate = matches.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    evidence.visibleLocatorCount += 1;
    if (evidence.scrollAttempted) continue;
    evidence.scrollAttempted = true;
    await candidate.scrollIntoViewIfNeeded();
    evidence.scrollSucceeded = true;
  }
  return evidence;
}

async function editHost(page, recordId, changes) {
  const card = hostCard(page, recordId);
  await card.waitFor({ state: 'visible', timeout: 25000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  for (const [label, value] of Object.entries(changes)) await fill(page, label, value);
  await click(page, 'Save encrypted host');
}

async function triggerSync(page) {
  const status = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only)$/,
  }).first();
  await status.waitFor({ state: 'visible', timeout: 20000 });
  const label = (await status.getAttribute('aria-label').catch(() => null) ||
    (await status.innerText().catch(() => '')).trim());
  if (label !== 'Syncing' && await status.isEnabled().catch(() => false)) await status.click();
}

async function main() {
  const result = {
    success: false,
    recordId: null,
    vaultId: null,
    ownerDeviceId: null,
    secondDeviceId: null,
    baseRevisionId: null,
    ownerRevisionId: null,
    branchRevisionId: null,
    branchOperationId: null,
    conflictId: null,
    resolvedRevisionId: null,
    resolvedOperationId: null,
    retainedWinnerRevisionId: null,
    retainedWinnerOperationId: null,
    retainedConflictId: null,
    retainedBranchRevisionId: null,
    retainedBranchOperationId: null,
    retainedResolutionAttemptCount: 0,
    conflictSeq: null,
    resolutionSeq: null,
    retainedConflictSeq: null,
    retainedResolutionSeq: null,
    ownerWinnerNode: null,
    secondDeviceConflictNode: null,
    ownerResolutionNode: null,
    ownerResolutionInitialRequestNode: null,
    ownerResolutionAckHeldAfterCommit: false,
    ownerResolutionAckReleasedAfterFeed: false,
    ownerResolutionAttemptCount: 0,
    ownerResolutionInitialRevisionId: null,
    ownerResolutionLinkedOperationId: null,
    ownerResolutionLinkedPushRevisionId: null,
    ownerResolutionInitialRequestOpIdAbsent: false,
    ownerResolutionLinkedPushMatchesRequest: false,
    ownerResolutionOperationPushAttemptCount: 0,
    sameProfileSharedIndexedDb: false,
    sameProfileFeedAppliedBeforeAck: false,
    sameProfileTabsConvergedBeforeAck: false,
    sameProfileTabsConvergedAfterAck: false,
    sameProfilePrimaryReloadReopenedDriftBackend: false,
    sameProfileReloadedCacheConverged: false,
    expectedDeviceRequestAbortCount: 0,
    sameProfilePreAckResolutionFeedEventCount: null,
    sameProfilePendingOperationCount: null,
    sameProfileResolutionFeedEventCount: null,
    ownerRetainResolutionNode: null,
    ownerRetainReplayNode: null,
    ownerWinnerRoutedToA: false,
    secondDeviceConflictRoutedToB: false,
    ownerResolutionRoutedToA: false,
    ownerRetainResolutionRoutedToA: false,
    ownerRetainLostAckRecoveredThroughB: false,
    ownerRetainReplayAlreadyResolved: false,
    ownerRetainReplaySameSequence: false,
    ownerRetainReplaySameTarget: false,
    ownerRetainInitialAckLostAfterCommit: false,
    resolutionPushDiagnosticsBeforeManualSync: null,
    resolutionPushDiagnosticsAfterManualSync: null,
    exactCreateCount: 0,
    autoMergeBeforeResolutionAbsent: false,
    uiEvidence: {
      conflictDeliveredToOwner: false,
      reviewOpened: false,
      baseCurrentBranchObserved: false,
      explicitWholeTupleChoices: false,
      choiceSelectedBeforeSave: false,
      saveClicked: false,
      resolutionAfterSave: false,
      sameProfileFeedAppliedBeforeAck: false,
      sameProfilePrimaryReloadAfterSiblingFeedFirst: false,
      keepCurrentConflictDeliveredToBoth: false,
      keepCurrentConfirmed: false,
      keepCurrentResolutionAfterConfirm: false,
      keepCurrentAddedNoUpdatePush: false,
      keepCurrentLostAckRecovered: false,
    },
    reviewSaveDiagnostics: null,
    reviewSaveRetryCount: 0,
    bothProfilesDecryptedResolvedHost: false,
    bothProfilesDecryptedRetainedHost: false,
    privacyMarkersAbsent: false,
    pageErrors: 0,
    consoleErrors: 0,
    unexpectedRequestErrors: 0,
    offlineRequestErrors: 0,
    expectedPresenceHeartbeatRateLimitCount: 0,
    unexpectedApiHttpErrorCount: 0,
    apiHttpErrorClassificationPassed: false,
    expectedOfflineFailureCount: 0,
    expectedOfflineFailureCountsByProfileRoute: [],
    expectedOfflineConsoleErrorCount: 0,
    expectedOfflineConsoleErrorCountsByProfileRoute: [],
    offlineRetryBudgetPassed: false,
    expectedLostAckFailureCount: 0,
    allOfflineFailuresWereApiRequests: true,
    browserCleanupComplete: false,
    proxyCleanupComplete: false,
    tempSnapshotCleanupComplete: false,
    failure: null,
  };
  const state = {
    phase: 'validate inputs',
    browser: null,
    contextA: null,
    contextB: null,
    pageA: null,
    pageASibling: null,
    pageB: null,
    proxyStarted: false,
  };

  try {
    assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
      fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
      fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
      fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
    'compiled Flutter Web release bundle is missing');
    assertThat(BASE_URL && NODE_A_URL && NODE_B_URL && USERNAME && PASSWORD &&
      BOOTSTRAP_TOKEN && BASE_NAME && BASE_TAG && HOST_ADDRESS && SSH_USERNAME &&
      OWNER_HOSTNAME && BRANCH_HOSTNAME && KEEP_OWNER_HOSTNAME && KEEP_BRANCH_HOSTNAME,
    'PG Host conflict browser inputs are incomplete');
    assertThat([HOST_ADDRESS, OWNER_HOSTNAME, BRANCH_HOSTNAME,
      KEEP_OWNER_HOSTNAME, KEEP_BRANCH_HOSTNAME].every((value) =>
      value.endsWith('.example.test')) &&
      new Set([HOST_ADDRESS, OWNER_HOSTNAME, BRANCH_HOSTNAME,
        KEEP_OWNER_HOSTNAME, KEEP_BRANCH_HOSTNAME]).size === 5 &&
      BASE_NAME.startsWith('pg-conflict-') && BASE_TAG.startsWith('tag-') &&
      SSH_USERNAME.startsWith('synthetic-') && BRANCH_PORT === '22',
    'Host conflict acceptance requires distinct synthetic .example.test values');
    const base = new URL(BASE_URL);
    assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' &&
      !base.pathname.slice(1) && Number(base.port) > 0,
    'PG conflict proxy must use its exact loopback origin');
    assertThat(upstreamA.port !== upstreamB.port,
      'PG conflict acceptance requires two distinct PostgreSQL node endpoints');
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-pg-host-conflict-'));
    fs.chmodSync(tempRoot, 0o700);

    state.phase = 'bind isolated two-node proxy';
    await new Promise((resolve, reject) => {
      proxy.once('error', reject);
      proxy.listen(Number(base.port), '127.0.0.1', resolve);
    });
    state.proxyStarted = true;
    const launchOptions = {
      headless: true,
      ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
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
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL })));
    state.pageA = await state.contextA.newPage();
    state.pageB = await state.contextB.newPage();
    setupObservers(state.pageA, 'A');
    setupObservers(state.pageB, 'B');

    state.phase = 'load isolated Web profiles';
    await Promise.all([enterFlutter(state.pageA), enterFlutter(state.pageB)]);
    assertThat(await state.pageA.evaluate(() =>
      localStorage.getItem('x-pg-acceptance-profile')) === null &&
      await state.pageB.evaluate(() =>
        localStorage.getItem('x-pg-acceptance-profile')) === null,
    'profile routing header leaked into Web local storage');

    state.phase = 'register owner and create Vault';
    await connect(state.pageA);
    await field(state.pageA, 'Owner email');
    await fill(state.pageA, 'Owner email', USERNAME);
    await fill(state.pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(state.pageA, 'Confirm master password', PASSWORD);
    await fill(state.pageA, 'One-time bootstrap token', BOOTSTRAP_TOKEN);
    await fill(state.pageA, 'Device name', 'PG conflict owner device');
    await fill(state.pageA, 'First Vault', 'PG approved-device conflict Vault');
    await click(state.pageA, 'Create owner account');
    await waitWorkspace(state.pageA);

    state.phase = 'enroll and approve independent device B';
    await connect(state.pageB);
    await field(state.pageB, 'Email or username');
    await click(state.pageB, 'Add this device');
    await fill(state.pageB, 'Account email', USERNAME);
    await fill(state.pageB, 'Device name', 'PG conflict second device');
    await click(state.pageB, 'Generate request');
    await field(state.pageB, 'Copy this enrollment JSON');
    await click(state.pageB, 'Copy');
    const enrollment = await state.pageB.evaluate(() => navigator.clipboard.readText());
    assertThat(JSON.parse(enrollment)?.format === 'atermius-device-enrollment-v1',
      'device B enrollment payload had an unsupported format');
    await click(state.pageB, 'Close');
    await click(state.pageA, 'Devices');
    await click(state.pageA, 'Approve enrollment');
    await paste(state.pageA, 'Enrollment JSON', enrollment);
    await click(state.pageA, 'Review keys');
    await click(state.pageA, 'Approve & seal keys');
    await click(state.pageA, 'Copy');
    const approval = await state.pageA.evaluate(() => navigator.clipboard.readText());
    assertThat(approval.includes('atermius-device-approval-v1'),
      'owner approval payload had an unsupported format');
    await click(state.pageA, 'Done');
    await click(state.pageA, 'Hosts');
    await click(state.pageB, 'Import approval');
    await paste(state.pageB, 'Paste approval JSON', approval);
    await click(state.pageB, 'Import device keys');
    await fill(state.pageB, 'Email or username', USERNAME);
    await fill(state.pageB, 'Master password', PASSWORD);
    await click(state.pageB, 'Sign in and unlock');
    await waitWorkspace(state.pageB);
    await click(state.pageB, 'Hosts');

    state.phase = 'create baseline Host and verify B pull through node B';
    await click(state.pageA, 'Add host');
    await fill(state.pageA, 'Display name', BASE_NAME);
    await fill(state.pageA, 'Hostname or IP', HOST_ADDRESS);
    await fill(state.pageA, 'Port', '22');
    await fill(state.pageA, 'SSH username', SSH_USERNAME);
    await fill(state.pageA, 'Tags', BASE_TAG);
    await click(state.pageA, 'Save encrypted host');
    await waitUntil(() => PUSHES.some((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.operation === 'create' && ref.recordId && ref.revisionId)),
    'owner baseline Host create receipt');
    const createPush = PUSHES.find((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 &&
      push.refs.some((ref) => ref.operation === 'create'));
    const createRef = createPush.refs.find((ref) => ref.operation === 'create');
    const recordId = createRef.recordId;
    const baseRevisionId = createRef.revisionId;
    const ownerDeviceId = createRef.deviceId;
    result.recordId = recordId;
    result.vaultId = createPush.vaultId;
    result.ownerDeviceId = ownerDeviceId;
    result.baseRevisionId = baseRevisionId;
    assertThat(recordId && baseRevisionId && ownerDeviceId && createRef.operationId &&
      createPush.node === 'A' && createRef.baseRevisionId === null,
    'baseline create did not expose one signed owner revision through node A');
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BASE_ENDPOINT,
    }, 'owner baseline Host card');
    await waitUntil(() => CHANGES.some((entry) => entry.profile === 'B' &&
      entry.status === 200 && entry.revisions.some((item) =>
        item.recordId === recordId && item.revisionId === baseRevisionId)),
    'device B pulled the exact baseline revision through node B');
    await waitHost(state.pageB, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BASE_ENDPOINT,
    }, 'device B decrypted baseline Host');

    state.phase = 'stage same Hostname edits while both profiles are offline';
    intentionallyOfflineProfiles.add('A');
    intentionallyOfflineProfiles.add('B');
    await Promise.all([state.contextA.setOffline(true), state.contextB.setOffline(true)]);
    await editHost(state.pageB, recordId, { 'Hostname or IP': BRANCH_HOSTNAME });
    await waitHost(state.pageB, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: `${BRANCH_HOSTNAME}:22`,
    }, 'device B local offline Hostname edit');
    await editHost(state.pageA, recordId, { 'Hostname or IP': OWNER_HOSTNAME });
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: OWNER_ENDPOINT,
    }, 'owner local offline Hostname edit');
    const bPushRoutesBeforeOfflineSave = API_ROUTES.filter((route) =>
      route.profile === 'B' && route.method === 'POST' &&
      /\/sync\/push$/i.test(route.path)).length;
    assertThat(bPushRoutesBeforeOfflineSave === 0,
      'device B reached PostgreSQL with a push while it was intentionally offline');

    state.phase = 'commit A winner through node A';
    await state.contextA.setOffline(false);
    intentionallyOfflineProfiles.delete('A');
    const ownerWinnerPredicate = () => PUSHES.some((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === baseRevisionId));
    await waitUntil(ownerWinnerPredicate, 'owner signed update based on baseline', 15000)
      .catch(async () => {
        await triggerSync(state.pageA);
        await waitUntil(ownerWinnerPredicate, 'owner signed update based on baseline', 45000);
      });
    const winnerPush = PUSHES.find((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === baseRevisionId));
    const winnerRef = winnerPush.refs.find((ref) => ref.recordId === recordId &&
      ref.operation === 'update' && ref.baseRevisionId === baseRevisionId);
    const winnerRoute = routeForPush(winnerPush, recordId);
    result.ownerRevisionId = winnerRef.revisionId;
    result.ownerWinnerNode = winnerRoute?.node || null;
    result.ownerWinnerRoutedToA = winnerRoute?.node === 'A' &&
      winnerRoute.profile === 'A' && winnerRoute.status === winnerPush.status;
    assertThat(winnerRef.revisionId && winnerRef.revisionId !== baseRevisionId &&
      winnerRef.deviceId === ownerDeviceId && result.ownerWinnerRoutedToA,
    'owner Hostname winner did not commit once through PostgreSQL node A');
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: OWNER_ENDPOINT,
    }, 'owner committed Hostname winner');

    state.phase = 'publish B stale signed branch through node B';
    await state.contextB.setOffline(false);
    intentionallyOfflineProfiles.delete('B');
    const branchRoutePredicate = () => API_ROUTES.some((route) =>
      route.method === 'POST' && route.profile === 'B' &&
      /\/conflicts$/i.test(route.path) && route.operation?.recordId === recordId &&
      route.status >= 200 && route.status < 300 && route.conflictId);
    await waitUntil(branchRoutePredicate, 'B stale branch conflict upload on node B', 15000)
      .catch(async () => {
        await triggerSync(state.pageB);
        await waitUntil(branchRoutePredicate, 'B stale branch conflict upload on node B', 45000);
      });
    const branchRouteCandidate = API_ROUTES.find((route) => route.method === 'POST' &&
      route.profile === 'B' && /\/conflicts$/i.test(route.path) &&
      route.operation?.recordId === recordId && route.status >= 200 &&
      route.status < 300 && route.conflictId);
    const branchRoute = routeForConflictUpload('B', branchRouteCandidate?.operation?.operationId);
    const branchOperation = branchRoute?.operation;
    const conflictId = branchRoute?.conflictId;
    result.secondDeviceId = branchOperation?.deviceId || null;
    result.branchRevisionId = branchOperation?.revisionId || null;
    result.branchOperationId = branchOperation?.operationId || null;
    result.conflictId = conflictId || null;
    result.secondDeviceConflictNode = branchRoute?.node || null;
    result.secondDeviceConflictRoutedToB = branchRoute?.node === 'B' &&
      branchRoute.profile === 'B' && branchRoute.status >= 200 && branchRoute.status < 300;
    assertThat(branchOperation?.operation === 'update' &&
      branchOperation?.baseRevisionId === baseRevisionId &&
      branchOperation?.revisionId && branchOperation.revisionId !== baseRevisionId &&
      branchOperation?.operationId && branchOperation?.deviceId !== ownerDeviceId &&
      conflictId && result.secondDeviceConflictRoutedToB &&
      branchRoute.markerFree && branchRoute.responseMarkerFree,
    'B did not upload one opaque signed stale Host branch through node B');
    const autoMergeBeforeResolution = PUSHES.some((push) => push.profile === 'B' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === winnerRef.revisionId));
    result.autoMergeBeforeResolutionAbsent = !autoMergeBeforeResolution;
    assertThat(!autoMergeBeforeResolution,
      'same-field Hostname conflict was automatically merged before explicit review');

    state.phase = 'verify conflict delivery to both approved profiles';
    await waitUntil(() => CONFLICT_FEEDS
      .flatMap((feed) => feed.profile === 'B' ? feed.events.map((event) => ({ feed, event })) : [])
      .find(({ feed, event }) => feed.status === 200 && event.type === 'created' &&
        event.conflictId === conflictId && event.recordId === recordId && event.hasEnvelope),
    'B conflict-feed delivery', 45000);
    const createdOnB = CONFLICT_FEEDS.flatMap((feed) => feed.profile === 'B'
      ? feed.events.map((event) => ({ feed, event })) : [])
      .find(({ feed, event }) => feed.status === 200 && event.type === 'created' &&
        event.conflictId === conflictId && event.recordId === recordId && event.hasEnvelope);
    await waitUntil(() => CONFLICT_FEEDS.some((feed) => feed.profile === 'A' &&
      feed.status === 200 && feed.events.some((event) => event.type === 'created' &&
        event.conflictId === conflictId && event.recordId === recordId && event.hasEnvelope)),
    'owner A conflict-feed delivery', 15000).catch(async () => {
      await triggerSync(state.pageA);
      await waitUntil(() => CONFLICT_FEEDS.some((feed) => feed.profile === 'A' &&
        feed.status === 200 && feed.events.some((event) => event.type === 'created' &&
          event.conflictId === conflictId && event.recordId === recordId && event.hasEnvelope)),
      'owner A conflict-feed delivery after manual sync', 45000);
    });
    const createdOnA = CONFLICT_FEEDS.flatMap((feed) => feed.profile === 'A'
      ? feed.events.map((event) => ({ feed, event })) : [])
      .find(({ feed, event }) => feed.status === 200 && event.type === 'created' &&
        event.conflictId === conflictId && event.recordId === recordId && event.hasEnvelope);
    result.conflictSeq = createdOnA?.event.seq || createdOnB?.event.seq || null;
    result.uiEvidence.conflictDeliveredToOwner = Boolean(createdOnA &&
      createdOnA.feed.markerFree && createdOnA.event.seq);
    assertThat(createdOnA && createdOnB && createdOnA.event.seq === createdOnB.event.seq &&
      createdOnA.feed.markerFree && createdOnB.feed.markerFree,
    'both profiles did not receive the same opaque created-conflict feed event');

    state.phase = 'owner opens Sync & conflicts inbox';
    const inboxNav = state.pageA.getByRole('button', { name: /Sync & conflicts/ }).first();
    await inboxNav.waitFor({ state: 'visible', timeout: 20000 });
    await inboxNav.click();
    state.phase = 'owner waits for conflict inbox heading';
    await state.pageA.getByText('跨设备冲突收件箱', { exact: false })
      .first().waitFor({ state: 'visible', timeout: 20000 });
    state.phase = 'owner scrolls Conflict branches section into view';
    const conflictSectionScroll = await scrollLastVisibleSemanticNodeContaining(
      state.pageA,
      'Conflict branches',
    );
    assertThat(conflictSectionScroll.visibleLocatorCount > 0 &&
      conflictSectionScroll.scrollSucceeded,
    'owner conflict inbox did not expose a visible Conflict branches semantics node');
    state.phase = 'owner waits for Host review action';
    const reviewButton = state.pageA.getByRole('button', {
      name: 'Review Host connection settings', exact: true,
    }).first();
    await reviewButton.waitFor({ state: 'visible', timeout: 30000 });
    assertThat(await reviewButton.isEnabled(),
      'owner A could not review its verified Host conflict branch');
    state.phase = 'owner clicks Host review action';
    await reviewButton.click();
    const conflictTupleChoice = state.pageA.getByRole('radio', {
      name: /^Use the conflict branch tuple\b/,
    });
    const currentTupleChoice = state.pageA.getByRole('radio', {
      name: /^Use the current Vault tuple\b/,
    });
    state.phase = 'owner waits for Host review tuple choices';
    await conflictTupleChoice.waitFor({ state: 'visible', timeout: 20000 });
    await currentTupleChoice.waitFor({ state: 'visible', timeout: 20000 });
    result.uiEvidence.reviewOpened = true;
    const baseVisible = await state.pageA.getByText(HOST_ADDRESS, { exact: false })
      .first().isVisible().catch(() => false);
    const currentVisible = await state.pageA.getByText(OWNER_HOSTNAME, { exact: false })
      .first().isVisible().catch(() => false);
    const branchVisible = await state.pageA.getByText(BRANCH_HOSTNAME, { exact: false })
      .first().isVisible().catch(() => false);
    result.uiEvidence.baseCurrentBranchObserved = baseVisible && currentVisible && branchVisible;
    assertThat(result.uiEvidence.baseCurrentBranchObserved,
      'Host conflict review did not display the base, current, and branch endpoint values');
    assertThat(await conflictTupleChoice.count() === 1 &&
      await currentTupleChoice.count() === 1 &&
      await conflictTupleChoice.isEnabled() && await currentTupleChoice.isEnabled(),
    'review dialog did not offer exactly two enabled whole-tuple choices');
    result.uiEvidence.explicitWholeTupleChoices = true;
    state.phase = 'owner selects the complete conflict tuple';
    const resolutionRoutesBeforeChoice = API_ROUTES.filter((route) =>
      route.method === 'POST' && route.path.endsWith(`/conflicts/${conflictId}/resolve`)).length;
    const pushesBeforeChoice = PUSHES.length;
    await conflictTupleChoice.click();
    await waitUntil(async () => await conflictTupleChoice.isChecked().catch(() => false),
      'complete conflict tuple radio selection state', 10000);
    result.uiEvidence.choiceSelectedBeforeSave = await conflictTupleChoice.isChecked() &&
      resolutionRoutesBeforeChoice === 0;
    assertThat(result.uiEvidence.choiceSelectedBeforeSave,
      'branch tuple was not explicitly selected before any resolution request');
    const saveButton = state.pageA.getByRole('button', {
      name: 'Save reviewed tuple', exact: true,
    });
    assertThat(await saveButton.isEnabled(), 'review save remained disabled after a tuple choice');
    const apiRouteCountBeforeSave = API_ROUTES.length;
    delayedAckConflictId = conflictId;
    state.phase = 'owner saves the explicitly reviewed tuple';
    await saveButton.click();
    result.uiEvidence.saveClicked = true;
    state.phase = 'wait for reviewed tuple to stage and close its dialog';
    const reviewDialogTitle = state.pageA.getByText(
      'Review Host connection settings', { exact: true },
    );
    const reviewSaveError = state.pageA.getByText(
      /^Could not save the reviewed tuple:/,
    );
    const captureReviewSaveDiagnostics = async () => {
      const savingButton = state.pageA.getByRole('button', {
        name: 'Saving…', exact: true,
      });
      return {
        dialogVisible: await reviewDialogTitle.isVisible().catch(() => false),
        saveButtonVisible: await saveButton.isVisible().catch(() => false),
        savingButtonVisible: await savingButton.isVisible().catch(() => false),
        reviewError: redactSyntheticValues(await reviewSaveError.innerText().catch(() => '')),
        syncPushRouteCount: API_ROUTES.filter((route, index) =>
          index >= apiRouteCountBeforeSave && route.method === 'POST' &&
          /\/sync\/push$/i.test(route.path)).length,
        resolutionRouteCount: API_ROUTES.filter((route, index) =>
          index >= apiRouteCountBeforeSave && route.method === 'POST' &&
          route.path.endsWith(`/conflicts/${conflictId}/resolve`)).length,
        successfulOwnerPushCount: PUSHES.filter((push, index) =>
          index >= pushesBeforeChoice && push.profile === 'A' &&
          push.status >= 200 && push.status < 300).length,
        requestFailures: ERRORS.unexpectedRequest,
        offlineApiFailures: ERRORS.expectedOfflineFailure,
        ownerSyncPushStatuses: API_ROUTES.filter((route) => route.method === 'POST' &&
          route.profile === 'A' && /\/sync\/push$/i.test(route.path))
          .map((route) => route.status),
      };
    };
    const waitForReviewedSaveOutcome = () => waitUntil(async () =>
      !await reviewDialogTitle.isVisible().catch(() => false) ||
      await reviewSaveError.isVisible().catch(() => false),
    'reviewed Host tuple save completion or an actionable UI error', 30000);
    for (let attempt = 0; attempt <= 3; attempt += 1) {
      try {
        await waitForReviewedSaveOutcome();
      } catch (error) {
        result.reviewSaveDiagnostics = await captureReviewSaveDiagnostics();
        throw error;
      }
      if (!await reviewDialogTitle.isVisible().catch(() => false)) break;
      const errorText = await reviewSaveError.innerText().catch(() => '');
      if (!errorText.includes('正在刷新 Vault 成员状态，请稍后再修改。') || attempt === 3) {
        result.reviewSaveDiagnostics = await captureReviewSaveDiagnostics();
        throw new Error('reviewed Host tuple save returned a non-retryable error');
      }
      result.reviewSaveRetryCount += 1;
      await state.pageA.waitForTimeout(750 * (attempt + 1));
      await waitUntil(async () => await saveButton.isVisible().catch(() => false) &&
        await saveButton.isEnabled().catch(() => false),
      'reviewed Host tuple save becomes enabled after membership refresh', 10000);
      await saveButton.click();
    }

    const resolutionPushPredicate = () => PUSHES.some((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === winnerRef.revisionId && ref.revisionId &&
        ref.revisionId !== winnerRef.revisionId));
    const resolutionPushDiagnostics = async () => {
      const ownerPushRoutes = API_ROUTES.filter((route) => route.method === 'POST' &&
        route.profile === 'A' && /\/sync\/push$/i.test(route.path));
      const ownerPushRefs = ownerPushRoutes.flatMap((route) => route.operations || []);
      const ownerObservedPushes = PUSHES.filter((push) => push.profile === 'A');
      const statusButton = state.pageA.getByRole('button', {
        name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only)$/,
      }).first();
      const statusVisible = await statusButton.isVisible().catch(() => false);
      const statusText = statusVisible
        ? ((await statusButton.getAttribute('aria-label').catch(() => null)) ||
          (await statusButton.innerText().catch(() => '')).trim())
        : null;
      return {
        ownerSyncPushRouteCount: ownerPushRoutes.length,
        ownerSyncPushRouteStatuses: ownerPushRoutes.map((route) => route.status),
        ownerRecordUpdateRouteCount: ownerPushRefs.filter((ref) =>
          ref.recordId === recordId && ref.operation === 'update').length,
        ownerWinnerBasedUpdateRouteCount: ownerPushRefs.filter((ref) =>
          ref.recordId === recordId && ref.operation === 'update' &&
          ref.baseRevisionId === winnerRef.revisionId).length,
        ownerPushObserverCount: ownerObservedPushes.length,
        ownerObservedRecordUpdateCount: ownerObservedPushes.flatMap((push) => push.refs || [])
          .filter((ref) => ref.recordId === recordId && ref.operation === 'update').length,
        resolutionRequestCount: API_ROUTES.filter((route) => route.method === 'POST' &&
          route.profile === 'A' && route.path.endsWith(`/conflicts/${conflictId}/resolve`)).length,
        reviewChoicesStillVisible: await conflictTupleChoice.isVisible().catch(() => false) &&
          await currentTupleChoice.isVisible().catch(() => false),
        saveStillRunning: await state.pageA.getByRole('button', {
          name: 'Saving…', exact: true,
        }).isVisible().catch(() => false),
        branchTupleVisibleInHostList: await hostValuesVisible(state.pageA, recordId, {
          name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
        }),
        syncStatus: statusText && /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only)$/.test(statusText)
          ? statusText : statusVisible ? 'other' : null,
      };
    };
    state.phase = 'wait for A-signed reviewed tuple push';
    await waitUntil(resolutionPushPredicate, 'A-signed reviewed tuple revision', 15000)
      .catch(async () => {
        result.resolutionPushDiagnosticsBeforeManualSync = await resolutionPushDiagnostics();
        if (!resolutionPushPredicate()) await triggerSync(state.pageA);
        try {
          await waitUntil(resolutionPushPredicate,
            'A-signed reviewed tuple revision after manual sync', 45000);
        } catch (error) {
          result.resolutionPushDiagnosticsAfterManualSync = await resolutionPushDiagnostics();
          throw error;
        }
      });
    const resolutionPush = PUSHES.find((push, index) => index >= pushesBeforeChoice &&
      push.profile === 'A' && push.status >= 200 && push.status < 300 &&
      push.refs.some((ref) => ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === winnerRef.revisionId && ref.revisionId &&
        ref.revisionId !== winnerRef.revisionId));
    const resolutionRef = resolutionPush.refs.find((ref) => ref.recordId === recordId &&
      ref.operation === 'update' && ref.baseRevisionId === winnerRef.revisionId);
    const resolutionPushRoute = routeForPush(resolutionPush, recordId);
    result.resolvedRevisionId = resolutionRef.revisionId;
    result.resolvedOperationId = resolutionRef.operationId;
    result.ownerResolutionNode = resolutionPushRoute?.node || null;
    result.ownerResolutionRoutedToA = resolutionPushRoute?.node === 'A' &&
      resolutionPushRoute.profile === 'A' && resolutionPushRoute.status === resolutionPush.status &&
      resolutionRef.deviceId === ownerDeviceId;
    state.phase = 'verify A-signed resolution push route and privacy';
    assertThat(result.resolvedOperationId && result.ownerResolutionRoutedToA &&
      resolutionPush.markerFree,
    'reviewed Host tuple was not committed as one marker-free owner-signed update through node A');
    state.phase = 'wait for node A to commit and hold the adopted-branch resolution acknowledgement';
    const ownerResolutionRoutes = () => API_ROUTES.filter((route) =>
      route.method === 'POST' && route.profile === 'A' &&
      route.path.endsWith(`/conflicts/${conflictId}/resolve`));
    const ownerInitialAckHeld = () => ownerResolutionRoutes().some((route) =>
      route.node === 'A' && route.upstreamStatus === 200 && route.status === null &&
      route.clientStatus === null && route.simulatedDelayedAck === true &&
      route.delayedAckHeld === true &&
      route.resolutionStatus === 'resolved' && route.alreadyResolved === false &&
      route.resolvedRevisionId === result.resolvedRevisionId &&
      route.requestedResolvedRevisionId === result.resolvedRevisionId &&
      route.requestOpIdAbsent === true && route.operationId === null && route.resolutionSeq);
    await waitUntil(ownerInitialAckHeld,
      'node A commits the Owner-signed adopted-branch resolution before its response is held',
      60000);
    const ownerInitialResolutionRoute = ownerResolutionRoutes().find((route) =>
      route.simulatedDelayedAck === true);
    result.resolutionSeq = ownerInitialResolutionRoute?.resolutionSeq || null;
    result.ownerResolutionInitialRequestNode = ownerInitialResolutionRoute?.node || null;
    result.ownerResolutionAckHeldAfterCommit = Boolean(ownerInitialResolutionRoute &&
      ownerInitialResolutionRoute.node === 'A' && ownerInitialResolutionRoute.upstreamStatus === 200 &&
      ownerInitialResolutionRoute.status === null && ownerInitialResolutionRoute.clientStatus === null &&
      ownerInitialResolutionRoute.simulatedDelayedAck === true &&
      ownerInitialResolutionRoute.delayedAckHeld === true &&
      ownerInitialResolutionRoute.resolutionStatus === 'resolved' &&
      ownerInitialResolutionRoute.alreadyResolved === false &&
      ownerInitialResolutionRoute.resolvedRevisionId === result.resolvedRevisionId &&
      ownerInitialResolutionRoute.requestedResolvedRevisionId === result.resolvedRevisionId &&
      ownerInitialResolutionRoute.requestOpIdAbsent === true &&
      ownerInitialResolutionRoute.operationId === null &&
      ownerInitialResolutionRoute.resolutionSeq && ownerInitialResolutionRoute.markerFree &&
      API_ROUTES.indexOf(ownerInitialResolutionRoute) >= apiRouteCountBeforeSave);
    result.ownerResolutionInitialRevisionId =
      ownerInitialResolutionRoute?.requestedResolvedRevisionId || null;
    result.ownerResolutionInitialRequestOpIdAbsent =
      ownerInitialResolutionRoute?.requestOpIdAbsent === true;
    result.ownerResolutionLinkedOperationId = resolutionRef.operationId;
    result.ownerResolutionLinkedPushRevisionId = resolutionRef.revisionId;
    result.ownerResolutionLinkedPushMatchesRequest = Boolean(
      resolutionPush.status >= 200 && resolutionPush.status < 300 &&
      resolutionPush.markerFree && resolutionRef.operationId === result.resolvedOperationId &&
      resolutionRef.revisionId === result.resolvedRevisionId &&
      result.ownerResolutionInitialRevisionId === resolutionRef.revisionId &&
      result.ownerResolutionInitialRequestOpIdAbsent);
    result.ownerResolutionAckHeldAfterCommit = result.ownerResolutionAckHeldAfterCommit &&
      result.ownerResolutionLinkedPushMatchesRequest;
    result.ownerResolutionRoutedToA = result.ownerResolutionAckHeldAfterCommit &&
      result.ownerResolutionRoutedToA &&
      result.ownerResolutionInitialRequestNode === 'A' &&
      ownerInitialResolutionRoute?.profile === 'A' && ownerInitialResolutionRoute?.tab === 'primary';
    result.uiEvidence.resolutionAfterSave = Boolean(result.ownerResolutionAckHeldAfterCommit);
    assertThat(result.ownerResolutionAckHeldAfterCommit && result.ownerResolutionRoutedToA &&
      result.uiEvidence.resolutionAfterSave,
    'node A did not commit and hold the acknowledgement for the exact Owner-signed resolution');
    result.ownerResolutionAttemptCount = ownerResolutionRoutes().length;
    assertThat(result.ownerResolutionAttemptCount === 1 && heldResolutionAck !== null,
      'adopted-branch resolution was duplicated before its held response reached the client');

    state.phase = 'open a same-profile sibling tab while the committed resolution response is held';
    state.pageASibling = await state.contextA.newPage();
    await state.pageASibling.setExtraHTTPHeaders({
      'x-pg-acceptance-profile': 'A',
      'x-pg-acceptance-tab': 'A-sibling',
    });
    setupObservers(state.pageASibling, 'A-sibling');
    state.phase = 'initialize Flutter on the same-profile sibling tab';
    await enterFlutterSemantics(state.pageASibling);
    state.phase = 'restore the same-profile Owner workspace in the sibling tab';
    await recoverSameProfileWorkspace(state.pageASibling);
    state.phase = 'open Hosts in the same-profile sibling tab';
    await click(state.pageASibling, 'Hosts');
    state.phase = 'wait for sibling tab to read the adopted Host tuple';
    await waitHost(state.pageASibling, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    }, 'same-profile sibling sees the adopted Host tuple');
    state.phase = 'verify both Owner tabs selected the sharedIndexedDb backend';
    await waitUntil(() => DRIFT_BACKEND_MARKERS.A > 0 &&
      DRIFT_BACKEND_MARKERS['A-sibling'] > 0,
    'both Owner tabs select the Drift sharedIndexedDb backend', 30000);
    result.sameProfileSharedIndexedDb = true;

    const siblingResolvedFeed = () => CONFLICT_FEEDS
      .filter((feed) => feed.profile === 'A-sibling' && feed.status === 200)
      .flatMap((feed) => feed.events)
      .find((event) => event.type === 'resolved' && event.conflictId === conflictId &&
        event.recordId === recordId && event.resolvedRevisionId === result.resolvedRevisionId &&
        event.seq === result.resolutionSeq && !event.hasEnvelope);
    await waitUntil(() => Boolean(siblingResolvedFeed()),
      'same-profile sibling receives the exact metadata-only resolved feed event before the held acknowledgement',
      60000).catch(async () => {
      await triggerSync(state.pageASibling);
      await waitUntil(() => Boolean(siblingResolvedFeed()),
        'same-profile sibling receives the exact resolved feed event after manual sync', 45000);
    });

    let siblingBeforeAck = null;
    await waitUntil(async () => {
      if (!heldResolutionAck) return false;
      siblingBeforeAck = await snapshotFeedResolution(
        state.pageASibling, 'sibling-before-ack', conflictId, recordId);
      return resolvedLocalEvidence(
        siblingBeforeAck, conflictId, result.resolvedRevisionId, result.resolutionSeq);
    }, 'sibling persists the resolved event and retires the matching resolution before ACK', 45000);
    const ownerBeforeAck = await snapshotFeedResolution(
      state.pageA, 'owner-before-ack', conflictId, recordId);
    result.sameProfileFeedAppliedBeforeAck = resolvedLocalEvidence(
      siblingBeforeAck, conflictId, result.resolvedRevisionId, result.resolutionSeq);
    result.sameProfilePreAckResolutionFeedEventCount = siblingBeforeAck.events.length;
    result.sameProfileTabsConvergedBeforeAck = result.sameProfileFeedAppliedBeforeAck &&
      siblingBeforeAck.events.length === 1 && ownerBeforeAck.events.length === 1 &&
      resolvedLocalEvidence(ownerBeforeAck, conflictId, result.resolvedRevisionId,
        result.resolutionSeq) &&
      JSON.stringify(ownerBeforeAck) === JSON.stringify(siblingBeforeAck);
    result.sameProfilePendingOperationCount = siblingBeforeAck.pending.length;
    result.sameProfileResolutionFeedEventCount = siblingBeforeAck.events.length;
    result.uiEvidence.sameProfileFeedAppliedBeforeAck = result.sameProfileTabsConvergedBeforeAck;
    assertThat(result.sameProfileSharedIndexedDb && result.sameProfileTabsConvergedBeforeAck &&
      result.sameProfilePreAckResolutionFeedEventCount === 1 &&
      siblingResolvedFeed() && heldResolutionAck !== null &&
      ownerResolutionRoutes().length === 1,
    'sibling did not apply the exact committed resolved event in shared IndexedDB before the original ACK');

    state.phase = 'release original resolve response after sibling applied its resolved feed event';
    assertThat(releaseHeldResolutionAck(), 'the original committed resolution response was not held');
    await waitUntil(() => ownerResolutionRoutes().length === 1 &&
      ownerResolutionRoutes()[0].delayedAckReleased === true &&
      ownerResolutionRoutes()[0].status === 200 &&
      ownerResolutionRoutes()[0].clientStatus === 200,
    'the original /resolve response is released exactly once after sibling feed application', 30000);
    result.ownerResolutionAckReleasedAfterFeed = ownerResolutionRoutes().length === 1 &&
      ownerResolutionRoutes()[0].alreadyResolved === false &&
      ownerResolutionRoutes()[0].resolvedRevisionId === result.resolvedRevisionId &&
      ownerResolutionRoutes()[0].resolutionSeq === result.resolutionSeq &&
      ownerResolutionRoutes()[0].delayedAckReleased === true;

    const primaryAfterAck = await snapshotFeedResolution(
      state.pageA, 'owner-after-ack', conflictId, recordId);
    const siblingAfterAck = await snapshotFeedResolution(
      state.pageASibling, 'sibling-after-ack', conflictId, recordId);
    result.sameProfileTabsConvergedAfterAck =
      resolvedLocalEvidence(primaryAfterAck, conflictId, result.resolvedRevisionId,
        result.resolutionSeq) &&
      resolvedLocalEvidence(siblingAfterAck, conflictId, result.resolvedRevisionId,
        result.resolutionSeq) &&
      JSON.stringify(primaryAfterAck) === JSON.stringify(siblingAfterAck);
    result.sameProfilePendingOperationCount = primaryAfterAck.pending.length;
    result.sameProfileResolutionFeedEventCount = primaryAfterAck.events.length;

    state.phase = 'close the sibling after primary and sibling ACK snapshots converge';
    expectedDeviceAbortWindows.set('A-sibling', 'fixture-teardown');
    try {
      await state.pageASibling.close();
    } finally {
      expectedDeviceAbortWindows.delete('A-sibling');
    }
    state.phase = 'reload Owner primary A after sibling applied the resolved feed';
    const primaryMarkerCountBeforeReload = DRIFT_BACKEND_MARKERS.A;
    expectedDeviceAbortWindows.set('A', 'reload');
    try {
      await state.pageA.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
      state.phase = 'reinitialize Flutter after Owner primary A reload';
      await enterFlutterSemantics(state.pageA, { navigate: false });
    } finally {
      expectedDeviceAbortWindows.delete('A');
    }
    state.phase = 'restore same-profile Owner workspace after primary A reload';
    await recoverSameProfileWorkspace(state.pageA);
    state.phase = 'open Hosts after Owner primary A reload';
    await click(state.pageA, 'Hosts');
    state.phase = 'wait for reloaded Owner primary A to decrypt the adopted Host tuple';
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    }, 'reloaded Owner primary A decrypts the adopted Host tuple');
    await waitUntil(() => DRIFT_BACKEND_MARKERS.A > primaryMarkerCountBeforeReload,
      'reloaded Owner primary A reopens the Drift sharedIndexedDb backend', 30000);
    result.sameProfilePrimaryReloadReopenedDriftBackend =
      DRIFT_BACKEND_MARKERS.A > primaryMarkerCountBeforeReload;
    const reloadedPrimary = await snapshotFeedResolution(
      state.pageA, 'owner-primary-reloaded-after-sibling-feed-first', conflictId, recordId);
    result.sameProfileReloadedCacheConverged =
      resolvedLocalEvidence(reloadedPrimary, conflictId, result.resolvedRevisionId,
        result.resolutionSeq) &&
      JSON.stringify(reloadedPrimary) === JSON.stringify(primaryAfterAck);
    result.uiEvidence.sameProfilePrimaryReloadAfterSiblingFeedFirst =
      result.sameProfilePrimaryReloadReopenedDriftBackend &&
      result.sameProfileReloadedCacheConverged &&
      await hostValuesVisible(state.pageA, recordId, {
        name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
      });
    assertThat(result.ownerResolutionAckReleasedAfterFeed &&
      result.sameProfileTabsConvergedAfterAck && result.sameProfileReloadedCacheConverged &&
      result.sameProfilePrimaryReloadReopenedDriftBackend &&
      result.uiEvidence.sameProfilePrimaryReloadAfterSiblingFeedFirst &&
      result.sameProfilePendingOperationCount === 0 &&
      result.sameProfileResolutionFeedEventCount === 1 &&
      ownerResolutionRoutes().length === 1,
    'tabs, primary-reloaded cache, UI, Drift backend, or resolution ledger diverged after the delayed response completed');

    result.ownerResolutionAttemptCount = ownerResolutionRoutes().length;
    assertThat(result.ownerResolutionAttemptCount === 1,
      'the adopted-branch /resolve was retried or duplicated after the delayed response');

    state.phase = 'sync resolution and verify both profiles decrypt the same Host';
    await click(state.pageA, 'Hosts');
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    }, 'owner A decrypted selected branch tuple');
    await state.pageB.waitForTimeout(500);
    const bFinalPredicate = () => hostValuesVisible(state.pageB, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    });
    await waitUntil(bFinalPredicate, 'B pulls the resolved Host revision', 15000)
      .catch(async () => {
        await triggerSync(state.pageB);
        await waitUntil(bFinalPredicate, 'B pulls the resolved Host revision after manual sync', 45000);
      });
    result.bothProfilesDecryptedResolvedHost = await hostValuesVisible(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    }) && await hostValuesVisible(state.pageB, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: BRANCH_ENDPOINT,
    });
    assertThat(result.bothProfilesDecryptedResolvedHost,
      'A and B did not decrypt the same explicitly resolved Host');
    const resolvedFeedFor = (profile) => CONFLICT_FEEDS
      .filter((feed) => feedTabMatchesScope(feed.profile, profile) && feed.status === 200)
      .flatMap((feed) => feed.events)
      .find((event) => event.type === 'resolved' &&
        event.conflictId === conflictId && event.resolvedRevisionId === result.resolvedRevisionId);
    const bothResolvedFeedsObserved = () => Boolean(resolvedFeedFor('A') && resolvedFeedFor('B'));
    await waitUntil(bothResolvedFeedsObserved,
      'both profiles receive metadata-only conflict resolution feed event', 12000)
      .catch(async () => {
        // The UI can finish applying the Host revision before its periodic
        // conflict-feed poll runs. Request a normal sync on each profile so
        // the assertion proves feed delivery rather than relying on timing.
        if (!resolvedFeedFor('A')) await triggerSync(state.pageA);
        if (!resolvedFeedFor('B')) await triggerSync(state.pageB);
        await waitUntil(bothResolvedFeedsObserved,
          'both profiles receive metadata-only conflict resolution feed event after sync', 45000);
      });
    const resolvedFeedA = resolvedFeedFor('A');
    const resolvedFeedB = resolvedFeedFor('B');
    assertThat(resolvedFeedA && resolvedFeedB && !resolvedFeedA.hasEnvelope &&
      !resolvedFeedB.hasEnvelope && resolvedFeedA.seq === resolvedFeedB.seq &&
      resolvedFeedA.seq === result.resolutionSeq,
    'profiles did not observe one matching metadata-only resolution sequence');

    state.phase = 'stage second same-field conflict for keep-current resolution';
    const bPushRoutesBeforeRetainScenario = API_ROUTES.filter((route) =>
      route.method === 'POST' && route.profile === 'B' && /\/sync\/push$/i.test(route.path)).length;
    intentionallyOfflineProfiles.add('A');
    intentionallyOfflineProfiles.add('B');
    await Promise.all([state.contextA.setOffline(true), state.contextB.setOffline(true)]);
    await editHost(state.pageB, recordId, { 'Hostname or IP': KEEP_BRANCH_HOSTNAME });
    await waitHost(state.pageB, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: KEEP_BRANCH_ENDPOINT,
    }, 'device B local second offline Hostname edit');
    await editHost(state.pageA, recordId, { 'Hostname or IP': KEEP_OWNER_HOSTNAME });
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: KEEP_OWNER_ENDPOINT,
    }, 'owner local second offline Hostname edit');
    assertThat(API_ROUTES.filter((route) => route.method === 'POST' &&
      route.profile === 'B' && /\/sync\/push$/i.test(route.path)).length ===
      bPushRoutesBeforeRetainScenario,
    'device B reached PostgreSQL with a push during the second offline edit');

    state.phase = 'commit second Owner winner through node A';
    const pushesBeforeRetainWinner = PUSHES.length;
    await state.contextA.setOffline(false);
    intentionallyOfflineProfiles.delete('A');
    const retainWinnerPredicate = () => PUSHES.slice(pushesBeforeRetainWinner).some((push) =>
      push.profile === 'A' && push.status >= 200 && push.status < 300 &&
      push.refs.some((ref) => ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === result.resolvedRevisionId));
    await waitUntil(retainWinnerPredicate, 'second Owner update based on adopted branch', 15000)
      .catch(async () => {
        await triggerSync(state.pageA);
        await waitUntil(retainWinnerPredicate,
          'second Owner update after manual sync', 45000);
      });
    const retainWinnerPush = PUSHES.slice(pushesBeforeRetainWinner).find((push) =>
      push.profile === 'A' && push.status >= 200 && push.status < 300 &&
      push.refs.some((ref) => ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === result.resolvedRevisionId));
    const retainWinnerRef = retainWinnerPush.refs.find((ref) =>
      ref.recordId === recordId && ref.operation === 'update' &&
      ref.baseRevisionId === result.resolvedRevisionId);
    const retainWinnerRoute = routeForPush(retainWinnerPush, recordId);
    result.retainedWinnerRevisionId = retainWinnerRef.revisionId;
    result.retainedWinnerOperationId = retainWinnerRef.operationId;
    assertThat(result.retainedWinnerRevisionId &&
      result.retainedWinnerRevisionId !== result.resolvedRevisionId &&
      retainWinnerRef.deviceId === ownerDeviceId && retainWinnerRoute?.node === 'A' &&
      retainWinnerRoute.profile === 'A' && retainWinnerRoute.status === retainWinnerPush.status &&
      retainWinnerPush.markerFree,
    'second Owner Host update did not commit marker-free through PostgreSQL node A');
    await waitHost(state.pageA, recordId, {
      name: BASE_NAME, tag: BASE_TAG, endpoint: KEEP_OWNER_ENDPOINT,
    }, 'owner second committed Host winner');

    state.phase = 'publish second B branch as a conflict through node B';
    const conflictsBeforeRetainBranch = API_ROUTES.filter((route) =>
      route.method === 'POST' && route.profile === 'B' && /\/conflicts$/i.test(route.path)).length;
    await state.contextB.setOffline(false);
    intentionallyOfflineProfiles.delete('B');
    const retainedBranchRoutePredicate = () => API_ROUTES.some((route) =>
      route.method === 'POST' && route.profile === 'B' && /\/conflicts$/i.test(route.path) &&
      route.status >= 200 && route.status < 300 && route.conflictId &&
      route.operation?.recordId === recordId &&
      route.operation?.baseRevisionId === result.resolvedRevisionId);
    await waitUntil(retainedBranchRoutePredicate,
      'second B losing branch upload through node B', 15000).catch(async () => {
        await triggerSync(state.pageB);
        await waitUntil(retainedBranchRoutePredicate,
          'second B losing branch upload after manual sync', 45000);
      });
    const retainedBranchRoute = API_ROUTES.slice().reverse().find((route) =>
      route.method === 'POST' && route.profile === 'B' && /\/conflicts$/i.test(route.path) &&
      route.status >= 200 && route.status < 300 && route.conflictId &&
      route.operation?.recordId === recordId &&
      route.operation?.baseRevisionId === result.resolvedRevisionId);
    const retainedBranchOperation = routeForConflictUpload(
      'B', retainedBranchRoute?.operation?.operationId,
    );
    assertThat(API_ROUTES.filter((route) => route.method === 'POST' &&
      route.profile === 'B' && /\/conflicts$/i.test(route.path)).length >
      conflictsBeforeRetainBranch && retainedBranchOperation?.node === 'B' &&
      retainedBranchOperation.responseMarkerFree && retainedBranchOperation.markerFree,
    'second B branch was not retained as opaque conflict ciphertext through node B');
    result.retainedConflictId = retainedBranchOperation.conflictId;
    result.retainedBranchRevisionId = retainedBranchOperation.operation.revisionId;
    result.retainedBranchOperationId = retainedBranchOperation.operation.operationId;
    result.ownerRetainResolutionNode = null;

    const createdRetainFeedFor = (profile) => CONFLICT_FEEDS
      .filter((feed) => feedTabMatchesScope(feed.profile, profile) && feed.status === 200)
      .flatMap((feed) => feed.events)
      .find((event) => event.type === 'created' &&
        event.conflictId === result.retainedConflictId && event.recordId === recordId &&
        event.hasEnvelope);
    const bothRetainCreatedFeedsObserved = () =>
      Boolean(createdRetainFeedFor('A') && createdRetainFeedFor('B'));
    await waitUntil(bothRetainCreatedFeedsObserved,
      'both profiles observe the second created-conflict event', 12000)
      .catch(async () => {
        if (!createdRetainFeedFor('A')) await triggerSync(state.pageA);
        if (!createdRetainFeedFor('B')) await triggerSync(state.pageB);
        await waitUntil(bothRetainCreatedFeedsObserved,
          'both profiles observe the second conflict after sync', 45000);
      });
    const createdRetainFeedA = createdRetainFeedFor('A');
    const createdRetainFeedB = createdRetainFeedFor('B');
    result.retainedConflictSeq = createdRetainFeedA?.seq || null;
    result.uiEvidence.keepCurrentConflictDeliveredToBoth = Boolean(
      createdRetainFeedA && createdRetainFeedB && createdRetainFeedA.seq &&
      createdRetainFeedA.seq === createdRetainFeedB.seq &&
      createdRetainFeedA.hasEnvelope && createdRetainFeedB.hasEnvelope &&
      CONFLICT_FEEDS.filter((feed) => feedTabMatchesScope(feed.profile, 'A') ||
        feed.profile === 'B')
        .filter((feed) => feed.events.some((event) =>
          event.conflictId === result.retainedConflictId))
        .every((feed) => feed.markerFree));
    assertThat(result.uiEvidence.keepCurrentConflictDeliveredToBoth,
      'both profiles did not receive the second matching conflict event');

    state.phase = 'owner opens conflict inbox for retain-current review';
    const retainInboxNav = state.pageA.getByRole('button', {
      name: /Sync & conflicts/,
    }).first();
    await retainInboxNav.waitFor({ state: 'visible', timeout: 20000 });
    await retainInboxNav.click();
    state.phase = 'wait for conflict inbox and retain-current controls';
    await state.pageA.getByText('跨设备冲突收件箱', { exact: false })
      .first().waitFor({ state: 'visible', timeout: 20000 });
    state.phase = 'scroll unresolved conflict section into view';
    const retainConflictSection = await scrollLastVisibleSemanticNodeContaining(
      state.pageA, 'Conflict branches',
    );
    assertThat(retainConflictSection.visibleLocatorCount > 0 &&
      retainConflictSection.scrollSucceeded,
    'owner conflict inbox did not expose the second Conflict branches section');
    const retainCurrentButtons = state.pageA.getByRole('button', {
      name: '保留当前版本', exact: true,
    });
    let retainCurrentButton = null;
    state.phase = 'wait for one enabled retain-current action';
    await waitUntil(async () => {
      const matches = [];
      for (let index = 0; index < await retainCurrentButtons.count(); index += 1) {
        const candidate = retainCurrentButtons.nth(index);
        if (await candidate.isVisible().catch(() => false) &&
            await candidate.isEnabled().catch(() => false)) matches.push(candidate);
      }
      if (matches.length !== 1) return false;
      retainCurrentButton = matches[0];
      return true;
    }, 'one enabled retain-current action for the unresolved Host branch', 20000);
    const routeCountBeforeRetainConfirm = API_ROUTES.length;
    lostAckConflictId = result.retainedConflictId;
    state.phase = 'owner opens retain-current confirmation';
    await retainCurrentButton.click();
    const confirmRetainButton = state.pageA.getByRole('button', {
      name: '确认保留版本', exact: true,
    });
    state.phase = 'wait for retain-current confirmation action';
    await confirmRetainButton.waitFor({ state: 'visible', timeout: 15000 });
    const successfulRecordUpdatesBeforeRetain = PUSHES.filter((push) =>
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update')).length;
    state.phase = 'owner confirms retention of current committed version';
    await confirmRetainButton.click();
    result.uiEvidence.keepCurrentConfirmed = true;
    const retainedResolutionRoutes = () => API_ROUTES.filter((route) =>
      route.method === 'POST' && route.profile === 'A' && route.path.endsWith(
        `/conflicts/${result.retainedConflictId}/resolve`));
    const committedAckDropped = () => retainedResolutionRoutes().some((route) =>
      route.node === 'A' && route.simulatedLostAck === true && route.upstreamStatus === 200 &&
      route.status === null && route.resolutionStatus === 'resolved' &&
      route.alreadyResolved === false &&
      route.resolvedRevisionId === result.retainedWinnerRevisionId && route.resolutionSeq);
    await waitUntil(committedAckDropped,
      'node A commits keep-current resolution before the browser acknowledgement is dropped',
      45000);
    const retainedInitialRoute = retainedResolutionRoutes().find((route) =>
      route.simulatedLostAck === true);
    result.retainedResolutionSeq = retainedInitialRoute?.resolutionSeq || null;
    result.ownerRetainResolutionNode = retainedInitialRoute?.node || null;
    result.ownerRetainInitialAckLostAfterCommit = Boolean(retainedInitialRoute &&
      retainedInitialRoute.node === 'A' && retainedInitialRoute.upstreamStatus === 200 &&
      retainedInitialRoute.status === null && retainedInitialRoute.simulatedLostAck === true &&
      retainedInitialRoute.alreadyResolved === false &&
      retainedInitialRoute.resolvedRevisionId === result.retainedWinnerRevisionId &&
      retainedInitialRoute.operationId === null && retainedInitialRoute.markerFree &&
      API_ROUTES.indexOf(retainedInitialRoute) >= routeCountBeforeRetainConfirm);
    result.ownerRetainResolutionRoutedToA = result.ownerRetainInitialAckLostAfterCommit;
    await waitUntil(() => retainedResolutionRoutes().some((route) =>
      route.node === 'B' && route.status === 200 && route.upstreamStatus === 200 &&
      route.alreadyResolved === true &&
      route.resolvedRevisionId === result.retainedWinnerRevisionId &&
      route.resolutionSeq === result.retainedResolutionSeq),
    'node B replays the same committed keep-current resolution after the lost acknowledgement',
    15000).catch(async () => {
      state.phase = 'retry keep-current resolution after simulated lost acknowledgement';
      await triggerSync(state.pageA);
      await waitUntil(() => retainedResolutionRoutes().some((route) =>
        route.node === 'B' && route.status === 200 && route.upstreamStatus === 200 &&
        route.alreadyResolved === true &&
        route.resolvedRevisionId === result.retainedWinnerRevisionId &&
        route.resolutionSeq === result.retainedResolutionSeq),
      'node B replays the same committed keep-current resolution after manual sync', 45000);
    });
    const retainedReplayRoutes = retainedResolutionRoutes().filter((route) =>
      route.node === 'B' && route.status === 200 && route.upstreamStatus === 200);
    const retainedResolutionRoute = routeForResolution(
      'A', result.retainedConflictId, result.retainedWinnerRevisionId,
    );
    result.retainedResolutionAttemptCount = retainedResolutionRoutes().length;
    result.ownerRetainReplayNode = retainedResolutionRoute?.node || null;
    result.ownerRetainLostAckRecoveredThroughB = retainedReplayRoutes.length > 0 &&
      retainedReplayRoutes.every((route) => route.alreadyResolved === true &&
        route.resolvedRevisionId === result.retainedWinnerRevisionId &&
        route.resolutionSeq === result.retainedResolutionSeq);
    result.ownerRetainReplayAlreadyResolved = retainedReplayRoutes.length > 0 &&
      retainedReplayRoutes.every((route) => route.alreadyResolved === true);
    result.ownerRetainReplaySameSequence = retainedReplayRoutes.length > 0 &&
      retainedReplayRoutes.every((route) => route.resolutionSeq === result.retainedResolutionSeq);
    result.ownerRetainReplaySameTarget = retainedReplayRoutes.length > 0 &&
      retainedReplayRoutes.every((route) =>
        route.resolvedRevisionId === result.retainedWinnerRevisionId &&
        route.operationId === null);
    result.ownerRetainResolutionRoutedToA = Boolean(result.ownerRetainInitialAckLostAfterCommit &&
      result.ownerRetainResolutionNode === 'A' && retainedReplayRoutes.length > 0 &&
      retainedResolutionRoute &&
      retainedResolutionRoute.resolvedRevisionId === result.retainedWinnerRevisionId &&
      retainedResolutionRoute.resolutionStatus === 'resolved' &&
      retainedResolutionRoute.operationId === null && retainedResolutionRoute.markerFree);
    result.uiEvidence.keepCurrentLostAckRecovered = result.ownerRetainLostAckRecoveredThroughB &&
      result.ownerRetainReplayAlreadyResolved && result.ownerRetainReplaySameSequence &&
      result.ownerRetainReplaySameTarget;
    result.uiEvidence.keepCurrentResolutionAfterConfirm =
      result.uiEvidence.keepCurrentLostAckRecovered;
    await state.pageA.waitForTimeout(1000);
    result.uiEvidence.keepCurrentAddedNoUpdatePush = PUSHES.filter((push) =>
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update')).length ===
      successfulRecordUpdatesBeforeRetain;
    assertThat(result.ownerRetainInitialAckLostAfterCommit &&
      result.ownerRetainResolutionNode === 'A' && result.ownerRetainReplayNode === 'B' &&
      result.ownerRetainLostAckRecoveredThroughB && result.ownerRetainReplayAlreadyResolved &&
      result.ownerRetainReplaySameSequence && result.ownerRetainReplaySameTarget &&
      result.ownerRetainResolutionRoutedToA && result.retainedResolutionSeq &&
      result.uiEvidence.keepCurrentResolutionAfterConfirm &&
      result.uiEvidence.keepCurrentAddedNoUpdatePush,
    'keep-current resolution lost-ack replay changed its target, sequence, route, or commit ledger');

    const retainedResolvedFeedFor = (profile) => CONFLICT_FEEDS
      .filter((feed) => feedTabMatchesScope(feed.profile, profile) && feed.status === 200)
      .flatMap((feed) => feed.events)
      .find((event) => event.type === 'resolved' &&
        event.conflictId === result.retainedConflictId &&
        event.resolvedRevisionId === result.retainedWinnerRevisionId);
    const bothRetainedResolvedFeedsObserved = () =>
      Boolean(retainedResolvedFeedFor('A') && retainedResolvedFeedFor('B'));
    await waitUntil(bothRetainedResolvedFeedsObserved,
      'both profiles observe metadata-only retain-current resolution', 12000)
      .catch(async () => {
        if (!retainedResolvedFeedFor('A')) await triggerSync(state.pageA);
        if (!retainedResolvedFeedFor('B')) await triggerSync(state.pageB);
        await waitUntil(bothRetainedResolvedFeedsObserved,
          'both profiles observe retain-current resolution after sync', 45000);
      });
    const retainedResolvedFeedA = retainedResolvedFeedFor('A');
    const retainedResolvedFeedB = retainedResolvedFeedFor('B');
    assertThat(retainedResolvedFeedA && retainedResolvedFeedB &&
      !retainedResolvedFeedA.hasEnvelope && !retainedResolvedFeedB.hasEnvelope &&
      retainedResolvedFeedA.seq === retainedResolvedFeedB.seq &&
      retainedResolvedFeedA.seq === result.retainedResolutionSeq,
    'profiles did not observe the same metadata-only retain-current resolution');
    await click(state.pageA, 'Hosts');
    const retainedHostValues = {
      name: BASE_NAME, tag: BASE_TAG, endpoint: KEEP_OWNER_ENDPOINT,
    };
    await waitHost(state.pageA, recordId, retainedHostValues,
      'owner decrypts the retained current Host tuple');
    await waitUntil(() => hostValuesVisible(state.pageB, recordId, retainedHostValues),
      'device B decrypts retained current Host tuple', 15000).catch(async () => {
        await triggerSync(state.pageB);
        await waitUntil(() => hostValuesVisible(state.pageB, recordId, retainedHostValues),
          'device B decrypts retained current tuple after manual sync', 45000);
      });
    result.bothProfilesDecryptedRetainedHost =
      await hostValuesVisible(state.pageA, recordId, retainedHostValues) &&
      await hostValuesVisible(state.pageB, recordId, retainedHostValues);
    assertThat(result.bothProfilesDecryptedRetainedHost,
      'A and B did not decrypt the Host head retained by explicit user choice');

    state.phase = 'validate ledger-facing evidence, privacy and browser health';
    const successfulCreateOperations = new Set(PUSHES.flatMap((push) =>
      push.status >= 200 && push.status < 300
        ? push.refs.filter((ref) => ref.recordId === recordId && ref.operation === 'create')
          .map((ref) => `${ref.deviceId}/${ref.operationId}/${ref.revisionId}`)
        : []));
    result.exactCreateCount = successfulCreateOperations.size;
    result.ownerResolutionOperationPushAttemptCount = PUSHES.filter((push) =>
      push.refs.some((ref) => ref.operationId === result.resolvedOperationId)).length;
    const monitoredRoutes = API_ROUTES.filter((route) =>
      route.profile === 'A' || route.profile === 'A-sibling' || route.profile === 'B')
      .filter((route) =>
      /\/sync\/push$|\/conflicts(?:\/[^/]+\/resolve)?$|\/conflict-changes$|\/changes$/i
        .test(route.path));
    result.privacyMarkersAbsent = MARKERS.every(Boolean) &&
      PUSHES.filter((push) => push.refs.some((ref) => ref.recordId === recordId))
        .every((push) => push.markerFree) &&
      CHANGES.every((entry) => entry.markerFree) &&
      CONFLICT_FEEDS.every((entry) => entry.markerFree) &&
      monitoredRoutes.every((route) => !route.parseFailed && !route.responseParseFailed &&
        route.markerFree !== false && route.responseMarkerFree !== false);
    result.pageErrors = ERRORS.page;
    result.consoleErrors = ERRORS.console;
    result.unexpectedRequestErrors = ERRORS.unexpectedRequest;
    result.offlineRequestErrors = ERRORS.unexpectedOfflineRequest;
    result.expectedOfflineFailureCount = ERRORS.expectedOfflineFailure;
    result.expectedLostAckFailureCount = ERRORS.expectedLostAckFailure;
    result.allOfflineFailuresWereApiRequests = ERRORS.unexpectedOfflineRequest === 0;
    assertThat(result.exactCreateCount === 1,
      'Host acceptance created more or fewer than exactly one committed baseline record');
    assertThat(result.ownerResolutionOperationPushAttemptCount === 1,
      'operation-backed resolution replay retried the signed sync push instead of only replaying /resolve');
    assertThat(result.privacyMarkersAbsent,
      'a synthetic Host marker appeared in monitored sync or conflict API traffic');
    assertThat(result.pageErrors === 0 && result.consoleErrors === 0 &&
      result.unexpectedRequestErrors === 0 && result.offlineRequestErrors === 0,
    'Chromium observed unexpected page, console, or request failures');
    assertThat(result.conflictSeq && result.resolutionSeq &&
      result.conflictId && result.branchOperationId && result.resolvedOperationId,
    'conflict or resolution sequence/operation identifiers are incomplete');
    result.success = true;
  } catch (error) {
    result.failure = {
      stage: state.phase,
      errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
      diagnostic: redactSyntheticValues(error?.message || error || '')
        .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
        .replace(/\s+/g, ' ').slice(0, 360),
      browserDiagnostics: BROWSER_DIAGNOSTICS.slice(0, 6),
      conflictFeedObservations: CONFLICT_FEEDS.slice(-20).map((feed) => ({
        profile: feed.profile,
        status: feed.status,
        events: feed.events.map((event) => ({
          seq: event.seq,
          type: event.type,
          conflictId: event.conflictId,
          resolvedRevisionId: event.resolvedRevisionId,
          hasEnvelope: event.hasEnvelope,
        })),
      })),
      apiErrors: API_ROUTES.filter((route) => route.status >= 400 ||
        route.upstreamStatus >= 400).slice(-10).map((route) => ({
        method: route.method,
        path: route.path,
        status: route.status,
        upstreamStatus: route.upstreamStatus,
        profile: route.profile,
        tab: route.tab,
        node: route.node,
      })),
    };
  } finally {
    if (heldResolutionAck) releaseHeldResolutionAck();
    const contexts = [state.contextA, state.contextB].filter(Boolean);
    for (const profile of ['A', 'A-sibling', 'B']) {
      expectedDeviceAbortWindows.set(profile, 'fixture-teardown');
    }
    let closeResults;
    try {
      closeResults = await Promise.allSettled(contexts.map((context) => context.close()));
    } finally {
      for (const profile of ['A', 'A-sibling', 'B']) {
        expectedDeviceAbortWindows.delete(profile);
      }
    }
    if (state.browser) await state.browser.close().catch(() => {});
    for (const socket of proxy._sockets) socket.destroy();
    if (state.proxyStarted && proxy.listening) {
      await new Promise((resolve) => proxy.close(resolve));
    }
    state.proxyStarted = false;
    if (tempRoot) {
      fs.rmSync(tempRoot, { recursive: true, force: true });
      result.tempSnapshotCleanupComplete = !fs.existsSync(tempRoot);
      tempRoot = null;
    }
    result.browserCleanupComplete = closeResults.every((item) => item.status === 'fulfilled') &&
        (!state.browser || !state.browser.isConnected());
    result.expectedDeviceRequestAbortCount = EXPECTED_DEVICE_REQUEST_ABORTS.length;
    result.proxyCleanupComplete = !proxy.listening && proxy._sockets.size === 0;
    result.pageErrors = ERRORS.page;
    result.consoleErrors = ERRORS.console;
    result.unexpectedRequestErrors = ERRORS.unexpectedRequest;
    result.offlineRequestErrors = ERRORS.unexpectedOfflineRequest;
    result.expectedOfflineFailureCount = ERRORS.expectedOfflineFailure;
    result.expectedLostAckFailureCount = ERRORS.expectedLostAckFailure;
    result.allOfflineFailuresWereApiRequests = ERRORS.unexpectedOfflineRequest === 0;
    if (!result.browserCleanupComplete || !result.proxyCleanupComplete ||
        !result.tempSnapshotCleanupComplete) {
      result.success = false;
      result.failure ||= { stage: state.phase, errorClass: 'CleanupError' };
    }
  }
  const expectedAbortKeys = EXPECTED_DEVICE_REQUEST_ABORTS.map((item) =>
    `${item.lifecycle}/${item.profile}/${item.route}`);
  const expectedAbortWindowKeys = new Set(expectedAbortKeys);
  if (EXPECTED_DEVICE_REQUEST_ABORTS.length > 6 ||
      expectedAbortWindowKeys.size !== EXPECTED_DEVICE_REQUEST_ABORTS.length) {
    result.success = false;
    result.failure ||= {
      stage: 'validate explicit reload and fixture cleanup request cancellations',
      errorClass: 'CleanupError',
    };
  }
  result.expectedOfflineFailureCountsByProfileRoute =
    summarizeOfflineCounts(EXPECTED_OFFLINE_FAILURES);
  result.expectedOfflineConsoleErrorCountsByProfileRoute =
    summarizeOfflineCounts(EXPECTED_OFFLINE_CONSOLE_ERRORS);
  result.expectedOfflineConsoleErrorCount = EXPECTED_OFFLINE_CONSOLE_ERRORS.length;
  const offlineFailureCountsByKey = new Map(
    result.expectedOfflineFailureCountsByProfileRoute.map((item) =>
      [`${item.profile}/${item.route}`, item.count]));
  const offlineProfiles = new Set(EXPECTED_OFFLINE_FAILURES.map((item) => item.profile));
  const offlineRetryBudgetPassed =
    ERRORS.unexpectedOfflineRequest === 0 &&
    EXPECTED_OFFLINE_FAILURES.length === ERRORS.expectedOfflineFailure &&
    EXPECTED_OFFLINE_FAILURES.length > 0 &&
    EXPECTED_OFFLINE_FAILURES.length <= MAX_EXPECTED_OFFLINE_FAILURES &&
    ['A', 'B'].every((profile) => offlineProfiles.has(profile)) &&
    result.expectedOfflineFailureCountsByProfileRoute.every((item) =>
      ['A', 'B'].includes(item.profile) &&
      OFFLINE_API_ROUTE_CATEGORIES.has(item.route) &&
      item.count > 0 && item.count <= MAX_EXPECTED_OFFLINE_FAILURES_PER_PROFILE_ROUTE) &&
    EXPECTED_OFFLINE_CONSOLE_ERRORS.length <= EXPECTED_OFFLINE_FAILURES.length &&
    result.expectedOfflineConsoleErrorCountsByProfileRoute.every((item) =>
      ['A', 'B'].includes(item.profile) &&
      offlineFailureCountsByKey.get(`${item.profile}/${item.route}`) >= item.count);
  result.offlineRetryBudgetPassed = offlineRetryBudgetPassed;
  result.allOfflineFailuresWereApiRequests = offlineRetryBudgetPassed;
  if (!offlineRetryBudgetPassed) {
    result.success = false;
    result.failure ||= {
      stage: 'validate allowlisted offline API failures and bounded retries',
      errorClass: 'Error',
    };
  }
  const expectedPresenceRateLimits = API_ROUTES.filter((route) =>
    route.expectedHttpErrorCategory === 'presence_heartbeat_rate_limited');
  const unexpectedApiHttpErrors = API_ROUTES.filter((route) => {
    const status = route.status ?? route.upstreamStatus;
    return Number.isInteger(status) && status >= 400 &&
      route.expectedHttpErrorCategory !== 'presence_heartbeat_rate_limited';
  });
  result.expectedPresenceHeartbeatRateLimitCount = expectedPresenceRateLimits.length;
  result.unexpectedApiHttpErrorCount = unexpectedApiHttpErrors.length;
  result.apiHttpErrorClassificationPassed = unexpectedApiHttpErrors.length === 0;
  if (!result.apiHttpErrorClassificationPassed) {
    result.success = false;
    result.failure ||= {
      stage: 'validate API HTTP error classifications',
      errorClass: 'Error',
    };
  }
  console.log(`PG_SYNC_HOST_CONFLICT_RESULT:${JSON.stringify(result)}`);
  if (!result.success) {
    console.error(`PG_SYNC_HOST_CONFLICT_FAILED:${result.failure?.stage || 'unknown'}:${result.failure?.errorClass || 'Error'}`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`PG_SYNC_HOST_CONFLICT_FAILED:Unhandled:${error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error'}`);
  process.exitCode = 1;
});
