/*
 * PG-SYNC-HOST-MERGE-01: an approved second Web device saves an offline,
 * allowlisted Host edit while the owner commits a disjoint edit through node
 * A. The second device reconnects through node B and commits a newly signed
 * merge based on the remote winner. The pytest parent verifies the PostgreSQL
 * ledger and cleanup. This runner prints only identifiers and safe counts.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const RUN_BATCH_REVISION_CONFLICT = process.argv.includes('--revision-conflict-batch');
const RUN_SINGLE_REVISION_CONFLICT = process.argv.includes('--revision-conflict-single');
const BASE_URL = process.env.ATERMIUS_PG_MERGE_BASE_URL;
const NODE_A_URL = process.env.ATERMIUS_PG_MERGE_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_MERGE_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_MERGE_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_MERGE_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_MERGE_BOOTSTRAP_TOKEN;
const BASE_NAME = process.env.ATERMIUS_PG_MERGE_BASE_NAME;
const REMOTE_NAME = process.env.ATERMIUS_PG_MERGE_REMOTE_NAME;
const BASE_TAG = process.env.ATERMIUS_PG_MERGE_BASE_TAG;
const LOCAL_TAG = process.env.ATERMIUS_PG_MERGE_LOCAL_TAG;
const INDEPENDENT_TAG = process.env.ATERMIUS_PG_MERGE_INDEPENDENT_TAG || `${LOCAL_TAG}-independent`;
const HOST_ADDRESS = process.env.ATERMIUS_PG_MERGE_HOST_ADDRESS;
const INDEPENDENT_ADDRESS = process.env.ATERMIUS_PG_MERGE_INDEPENDENT_ADDRESS || HOST_ADDRESS;
const INDEPENDENT_NAME = `${BASE_NAME} independent`;
const SSH_USERNAME = process.env.ATERMIUS_PG_MERGE_SSH_USERNAME;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const MARKERS = [USERNAME, PASSWORD, BASE_NAME, REMOTE_NAME, BASE_TAG,
  INDEPENDENT_NAME, LOCAL_TAG, INDEPENDENT_TAG, HOST_ADDRESS,
  INDEPENDENT_ADDRESS, SSH_USERNAME];
const API_ROUTES = [];
const PUSHES = [];
const CHANGES = [];
const RESPONSE_EVENTS = [];
const PUSH_RESPONSE_READS = [];
const pendingProtocolConsoleErrors = [];
const ERRORS = {
  page: 0,
  console: 0,
  expectedOfflineConsole: 0,
  expectedProtocolConsole: 0,
  unexpectedRequest: 0,
  offlineRequest: 0,
};
const OFFLINE_CONSOLE_CORRELATION_WINDOW_MS = 2000;
const PROTOCOL_CONSOLE_RESPONSE_WINDOW_MS = 2000;
const PROTOCOL_CONSOLE_DIRECT_MATCH_WINDOW_MS = 500;
const offlineRequestFailureTimes = [];
const pendingOfflineTransportConsoleErrors = [];
let intentionallyOfflineB = false;
let editorPushGate = null;

function armEditorPushGate() {
  assertThat(editorPushGate === null, 'an Editor push gate is already armed');
  let captured;
  let release;
  const gate = {
    captured: new Promise((resolve) => { captured = resolve; }),
    releasePromise: new Promise((resolve) => { release = resolve; }),
    release,
    markCaptured: captured,
    record: null,
    released: false,
  };
  editorPushGate = gate;
  return gate;
}

function releaseEditorPushGate(gate) {
  if (!gate || !gate.record || gate.released) return false;
  gate.released = true;
  gate.release();
  return true;
}

function parsedPushBody(record, bodyBuffer) {
  try {
    const body = JSON.parse(bodyBuffer.toString('utf8'));
    record.batchId = typeof body?.batch_id === 'string' ? body.batch_id : null;
    record.operationRefs = Array.isArray(body?.operations)
      ? body.operations.map((item) => {
        const header = item?.header || {};
        return {
          recordId: header.record_id || null,
          operationId: header.op_id || null,
          revisionId: header.revision_id || null,
          baseRevisionId: header.base_revision_id || null,
          deviceId: header.device_id || null,
          operation: header.operation || null,
        };
      }) : [];
    record.operationIds = record.operationRefs.map((item) => item.operationId)
      .filter((value) => typeof value === 'string');
    record.markerFree = markerFree(JSON.stringify(body));
  } catch (_) {
    record.parseFailed = true;
    record.operationRefs = [];
    record.operationIds = [];
    record.markerFree = false;
  }
}

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

function responseRouteClass(pathname) {
  if (/\/sync\/push$/i.test(pathname)) return 'sync-push';
  if (/\/changes$/i.test(pathname)) return 'changes';
  if (pathname.startsWith('/api/')) return 'api-other';
  return 'static';
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
      status: null, atMs: Date.now(),
    };
    const isPush = record.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(record.path);
    if (url.pathname.startsWith('/api/v1/')) API_ROUTES.push(record);
    const headers = { ...request.headers, host: `127.0.0.1:${upstream.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    const upstreamRequest = http.request({
      hostname: upstream.hostname,
      port: upstream.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      record.status = upstreamResponse.statusCode || null;
      record.responseAtMs = Date.now();
      if (!isPush) {
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        upstreamResponse.pipe(response);
        return;
      }
      const responseChunks = [];
      upstreamResponse.on('data', (chunk) => responseChunks.push(chunk));
      upstreamResponse.on('end', () => {
        const bodyBuffer = Buffer.concat(responseChunks);
        try {
          const body = JSON.parse(bodyBuffer.toString('utf8'));
          record.errorCode = body?.error?.code || body?.code || null;
          record.responseMarkerFree = markerFree(JSON.stringify(body));
          record.resultRefs = Array.isArray(body?.results)
            ? body.results.map((item) => ({
              operationId: item?.op_id || null,
              revisionId: item?.revision_id || null,
              commitSeq: item?.commit_seq || null,
              alreadyCommitted: item?.already_committed === true,
            })) : [];
        } catch (_) {
          record.responseParseFailed = true;
          record.responseMarkerFree = false;
        }
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        response.end(bodyBuffer);
      });
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    if (isPush) {
      const gate = profile === 'B' ? editorPushGate : null;
      if (gate && editorPushGate === gate) editorPushGate = null;
      const bodyChunks = [];
      request.on('data', (chunk) => bodyChunks.push(chunk));
      request.on('end', () => {
        const bodyBuffer = Buffer.concat(bodyChunks);
        parsedPushBody(record, bodyBuffer);
        if (!gate) return;
        gate.record = record;
        gate.markCaptured(record);
        gate.releasePromise.then(() => upstreamRequest.end(bodyBuffer));
      });
      if (gate) return;
    }
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

async function enterFlutter(page) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
  await waitUntil(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web crypto module');
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitUntil(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics tree');
  await click(page, 'Connect securely');
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

function consoleErrorCategory(message) {
  const text = message.text().toLowerCase();
  if (/websocket|\bws:|\bwss:/.test(text)) return 'websocket';
  if (/failed to load resource|net::err_|failed to fetch|fetch failed|loading chunk|network error/.test(text)) {
    return 'resource-load';
  }
  return 'application';
}

function logConsoleDiagnostic({ profile, offlineFlag, category, matchedOfflineFailure,
  deferredForCorrelation, offlineFailureAgeMs, responseStatus = null,
  responseRouteClass = null, requestToResponseMs = null, consoleToResponseMs = null,
  responseCandidateCount = 0, matchedRevisionConflictResponse = false }) {
  console.error(`PG_SYNC_HOST_CONSOLE_DIAGNOSTIC:${JSON.stringify({
    profile,
    offlineFlag,
    messageType: 'error',
    category,
    matchedOfflineFailure,
    deferredForCorrelation,
    offlineFailureAgeMs,
    responseStatus,
    responseRouteClass,
    requestToResponseMs,
    consoleToResponseMs,
    responseCandidateCount,
    matchedRevisionConflictResponse,
  })}`);
}

function flushUnmatchedOfflineConsoleErrors() {
  for (const pending of pendingOfflineTransportConsoleErrors.splice(0)) {
    ERRORS.console += 1;
    logConsoleDiagnostic({
      profile: pending.profile,
      offlineFlag: pending.offlineFlag,
      category: pending.category,
      matchedOfflineFailure: false,
      deferredForCorrelation: false,
      offlineFailureAgeMs: null,
    });
  }
}

async function resolveProtocolConsoleErrors(expectedRejectedBatchId) {
  await Promise.all(PUSH_RESPONSE_READS);
  for (const pending of pendingProtocolConsoleErrors.splice(0)) {
    const candidates = RESPONSE_EVENTS.filter((response) =>
      response.profile === pending.profile &&
      Math.abs(pending.atMs - response.responseAtMs) <= PROTOCOL_CONSOLE_RESPONSE_WINDOW_MS)
      .map((response) => ({
        response,
        absoluteDeltaMs: Math.abs(pending.atMs - response.responseAtMs),
      }))
      .sort((left, right) => left.absoluteDeltaMs - right.absoluteDeltaMs);
    const nearest = candidates[0] || null;
    const next = candidates[1] || null;
    const uniqueNearest = nearest &&
      (!next || next.absoluteDeltaMs - nearest.absoluteDeltaMs > 25);
    const response = nearest?.response || null;
    const matchedRevisionConflictResponse = Boolean(response && uniqueNearest &&
      nearest.absoluteDeltaMs <= PROTOCOL_CONSOLE_DIRECT_MATCH_WINDOW_MS &&
      pending.profile === 'B' && response.routeClass === 'sync-push' &&
      response.status === 409 && response.pushRecord?.batchId === expectedRejectedBatchId &&
      response.pushRecord?.errorCode === 'REVISION_CONFLICT');
    if (matchedRevisionConflictResponse) {
      ERRORS.expectedProtocolConsole += 1;
    } else {
      ERRORS.console += 1;
    }
    logConsoleDiagnostic({
      profile: pending.profile,
      offlineFlag: pending.offlineFlag,
      category: pending.category,
      matchedOfflineFailure: false,
      deferredForCorrelation: false,
      offlineFailureAgeMs: null,
      responseStatus: response?.status ?? null,
      responseRouteClass: response?.routeClass ?? null,
      requestToResponseMs: response?.requestDurationMs ?? null,
      consoleToResponseMs: response ? pending.atMs - response.responseAtMs : null,
      responseCandidateCount: candidates.length,
      matchedRevisionConflictResponse,
    });
  }
}

function setupObservers(page, profile) {
  const pushesByRequest = new WeakMap();
  const changesByRequest = new WeakMap();
  const requestTimings = new WeakMap();
  const offlineRequests = new WeakSet();
  page.on('pageerror', () => { ERRORS.page += 1; });
  page.on('console', (message) => {
    if (message.type() !== 'error') return;
    const now = Date.now();
    const category = consoleErrorCategory(message);
    const offlineFlag = profile === 'B' && intentionallyOfflineB;
    const transportCategory = category === 'resource-load' || category === 'websocket';
    let recentFailureIndex = -1;
    for (let index = offlineRequestFailureTimes.length - 1; index >= 0; index -= 1) {
      const failure = offlineRequestFailureTimes[index];
      if (!failure.matchedConsole && now - failure.atMs <= OFFLINE_CONSOLE_CORRELATION_WINDOW_MS) {
        recentFailureIndex = index;
        break;
      }
    }
    const recentFailure = recentFailureIndex >= 0
      ? offlineRequestFailureTimes[recentFailureIndex] : null;
    const offlineFailureAgeMs = recentFailure ? now - recentFailure.atMs : null;
    if (profile === 'B' && transportCategory && recentFailure) {
      recentFailure.matchedConsole = true;
      ERRORS.expectedOfflineConsole += 1;
      logConsoleDiagnostic({
        profile, offlineFlag, category, matchedOfflineFailure: true,
        deferredForCorrelation: false, offlineFailureAgeMs,
      });
      return;
    }
    if (offlineFlag && transportCategory) {
      pendingOfflineTransportConsoleErrors.push({ atMs: now, profile, offlineFlag, category });
      logConsoleDiagnostic({
        profile, offlineFlag, category, matchedOfflineFailure: false,
        deferredForCorrelation: true, offlineFailureAgeMs: null,
      });
      return;
    }
    if (profile === 'B' && category === 'resource-load') {
      pendingProtocolConsoleErrors.push({ atMs: now, profile, offlineFlag, category });
      return;
    }
    ERRORS.console += 1;
    logConsoleDiagnostic({
      profile, offlineFlag, category, matchedOfflineFailure: false,
      deferredForCorrelation: false, offlineFailureAgeMs,
    });
  });
  page.on('requestfailed', (request) => {
    if (profile === 'B' && offlineRequests.has(request)) {
      ERRORS.offlineRequest += 1;
      const now = Date.now();
      const failure = { atMs: now, matchedConsole: false };
      offlineRequestFailureTimes.push(failure);
      let pendingIndex = -1;
      for (let index = pendingOfflineTransportConsoleErrors.length - 1; index >= 0; index -= 1) {
        if (now - pendingOfflineTransportConsoleErrors[index].atMs <=
            OFFLINE_CONSOLE_CORRELATION_WINDOW_MS) {
          pendingIndex = index;
          break;
        }
      }
      if (pendingIndex >= 0) {
        const [pending] = pendingOfflineTransportConsoleErrors.splice(pendingIndex, 1);
        const offlineFailureAgeMs = now - pending.atMs;
        failure.matchedConsole = true;
        ERRORS.expectedOfflineConsole += 1;
        logConsoleDiagnostic({
          profile: pending.profile, offlineFlag: pending.offlineFlag, category: pending.category,
          matchedOfflineFailure: true, deferredForCorrelation: false, offlineFailureAgeMs,
        });
      }
    } else {
      ERRORS.unexpectedRequest += 1;
    }
  });
  page.on('request', (request) => {
    if (profile === 'B' && intentionallyOfflineB) offlineRequests.add(request);
    const url = new URL(request.url());
    requestTimings.set(request, {
      atMs: Date.now(),
      routeClass: responseRouteClass(url.pathname),
    });
    if (request.method() === 'GET' && url.pathname.endsWith('/changes')) {
      changesByRequest.set(request, Date.now());
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
        batchId: body?.batch_id || null,
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
    const request = response.request();
    const requestTiming = requestTimings.get(request);
    const url = new URL(response.url());
    const responseAtMs = Date.now();
    RESPONSE_EVENTS.push({
      profile,
      status: response.status(),
      routeClass: requestTiming?.routeClass || responseRouteClass(url.pathname),
      requestAtMs: requestTiming?.atMs ?? null,
      responseAtMs,
      requestDurationMs: requestTiming ? responseAtMs - requestTiming.atMs : null,
      pushRecord: pushesByRequest.get(request) || null,
    });
  });
  page.on('response', (response) => {
    const record = pushesByRequest.get(response.request());
    if (!record) return;
    record.status = response.status();
    const read = response.json().then((body) => {
      record.errorCode = body?.error?.code || body?.code || null;
      record.commitSeqs = Array.isArray(body?.results)
        ? body.results.map((item) => item?.commit_seq).filter((value) => typeof value === 'string')
        : [];
    }).catch(() => {});
    PUSH_RESPONSE_READS.push(read);
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
        atMs: Date.now(),
        requestAtMs: changesByRequest.get(request) || null,
        markerFree: markerFree(serialized),
        revisions: events.map((event) => ({
          recordId: event?.envelope?.header?.record_id,
          revisionId: event?.envelope?.header?.revision_id,
        })).filter((item) => typeof item.recordId === 'string' && typeof item.revisionId === 'string'),
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

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

function hostCard(page, recordId) {
  return page.locator(`flt-semantics[flt-semantics-identifier="ssh-host-${recordId}"]`);
}

async function hostValuesVisible(page, recordId, { name, tag, address = HOST_ADDRESS }) {
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
        text.includes(`@${expected.address}:22`);
    }, { name, tag, address });
  } catch (_) {
    return false;
  }
}

async function waitHost(page, recordId, values, description) {
  await waitUntil(() => hostValuesVisible(page, recordId, values), description, 45000);
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

async function createOwnerHost(page, { name, address, tag }) {
  const pushStart = PUSHES.length;
  await click(page, 'Add host');
  await fill(page, 'Display name', name);
  await fill(page, 'Hostname or IP', address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', SSH_USERNAME);
  await fill(page, 'Tags', tag);
  await click(page, 'Save encrypted host');
  await waitUntil(() => PUSHES.slice(pushStart).some((push) =>
    push.profile === 'A' && push.status >= 200 && push.status < 300 &&
    push.refs.some((ref) => ref.operation === 'create' && ref.recordId && ref.revisionId)),
  `owner Host create receipt for ${name}`);
  const push = PUSHES.slice(pushStart).find((entry) => entry.profile === 'A' &&
    entry.status >= 200 && entry.status < 300 &&
    entry.refs.some((ref) => ref.operation === 'create'));
  const ref = push?.refs.find((item) => item.operation === 'create');
  assertThat(push && ref?.recordId && ref.revisionId && ref.operationId &&
    ref.baseRevisionId === null && push.node === 'A',
  'owner baseline Host create did not produce a signed node-A revision');
  await waitHost(page, ref.recordId, { name, tag, address }, `owner Host ${name}`);
  return { ...ref, vaultId: push.vaultId, ownerDeviceId: ref.deviceId };
}

async function runSingleRevisionConflictAcceptance(state) {
  const result = { runnerTriggeredManualSync: false, browserCleanupComplete: false };
  let gate = null;
  let syncStatusInterval = null;
  let syncErrorObserved = false;
  try {
    state.phase = 'create one baseline Host and let B pull its signed revision';
    const baseline = await createOwnerHost(state.pageA, {
      name: BASE_NAME, address: HOST_ADDRESS, tag: BASE_TAG,
    });
    const ownerDeviceId = baseline.ownerDeviceId;
    await waitUntil(() => CHANGES.some((entry) => entry.profile === 'B' &&
      entry.node === 'B' && entry.status === 200 && entry.revisions.some((item) =>
        item.recordId === baseline.recordId && item.revisionId === baseline.revisionId)),
    'B signed-feed pull of the exact baseline revision');
    const baselineFeed = CHANGES.find((entry) => entry.profile === 'B' &&
      entry.node === 'B' && entry.status === 200 && entry.revisions.some((item) =>
        item.recordId === baseline.recordId && item.revisionId === baseline.revisionId));
    await waitHost(state.pageB, baseline.recordId,
      { name: BASE_NAME, tag: BASE_TAG, address: HOST_ADDRESS }, 'B baseline Host');

    state.phase = 'persist one pending B Host edit while its browser is offline';
    const bPushRoutesBeforeOffline = API_ROUTES.filter((route) => route.profile === 'B' &&
      route.method === 'POST' && /\/sync\/push$/i.test(route.path)).length;
    intentionallyOfflineB = true;
    await state.contextB.setOffline(true);
    await editHost(state.pageB, baseline.recordId, { Tags: LOCAL_TAG });
    await waitHost(state.pageB, baseline.recordId,
      { name: BASE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS }, 'B offline Host edit');
    const bPushRoutesAfterOffline = API_ROUTES.filter((route) => route.profile === 'B' &&
      route.method === 'POST' && /\/sync\/push$/i.test(route.path)).length;
    assertThat(bPushRoutesAfterOffline === bPushRoutesBeforeOffline,
      'B reached PostgreSQL with a Host push while intentionally offline');

    state.phase = 'hold B exact one-operation push after its signed baseline pull';
    gate = armEditorPushGate();
    await state.contextB.setOffline(false);
    intentionallyOfflineB = false;
    await waitUntil(() => gate.record !== null,
      'B one-operation sync push captured before forwarding', 60000);
    const rejectedBatch = gate.record;
    const rejectedRefs = rejectedBatch.operationRefs || [];
    const rejectedRef = rejectedRefs.find((ref) => ref.recordId === baseline.recordId);
    result.vaultId = baseline.vaultId;
    result.primaryRecordId = baseline.recordId;
    result.primaryCreateOperationId = baseline.operationId;
    result.ownerDeviceId = ownerDeviceId;
    result.baseRevisionId = baseline.revisionId;
    result.baselineFeedRequestAtMs = baselineFeed?.requestAtMs || null;
    result.rejectedBatchId = rejectedBatch.batchId;
    result.rejectedOperationIds = rejectedRefs.map((ref) => ref.operationId);
    result.originalStaleOperationId = rejectedRef?.operationId || null;
    result.originalStaleRevisionId = rejectedRef?.revisionId || null;
    result.secondDeviceId = rejectedRef?.deviceId || null;
    result.singleOperationBatchCaptured = rejectedRefs.length === 1 &&
      rejectedRefs[0]?.recordId === baseline.recordId && rejectedRef?.operation === 'update' &&
      rejectedRef.baseRevisionId === baseline.revisionId && rejectedBatch.node === 'B' &&
      rejectedBatch.markerFree === true && rejectedBatch.parseFailed !== true;
    assertThat(result.singleOperationBatchCaptured && result.secondDeviceId !== ownerDeviceId &&
      rejectedBatch.batchId && rejectedRef?.operationId && rejectedRef.revisionId &&
      result.baselineFeedRequestAtMs && result.baselineFeedRequestAtMs <= rejectedBatch.atMs,
    'B did not send one marker-free update based on the signed baseline through node B');

    state.phase = 'commit owner competing safe-field update through node A while B is held';
    const ownerPushStart = PUSHES.length;
    await editHost(state.pageA, baseline.recordId, { 'Display name': REMOTE_NAME });
    await waitUntil(() => PUSHES.slice(ownerPushStart).some((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === baseline.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === baseline.revisionId)), 'owner competing update receipt via node A');
    const ownerPush = PUSHES.slice(ownerPushStart).find((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === baseline.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === baseline.revisionId));
    const ownerRef = ownerPush?.refs.find((ref) => ref.recordId === baseline.recordId &&
      ref.operation === 'update' && ref.baseRevisionId === baseline.revisionId);
    const ownerRoute = ownerPush && routeForPush(ownerPush, baseline.recordId);
    result.ownerRevisionId = ownerRef?.revisionId || null;
    result.ownerOperationId = ownerRef?.operationId || null;
    assertThat(ownerRef?.revisionId && ownerRef.revisionId !== baseline.revisionId &&
      ownerRef.deviceId === ownerDeviceId && ownerRoute?.node === 'A' &&
      ownerRoute.status === ownerPush.status,
    'owner did not commit the competing Host revision through node A');
    await waitHost(state.pageA, baseline.recordId,
      { name: REMOTE_NAME, tag: BASE_TAG, address: HOST_ADDRESS }, 'owner competing Host head');

    state.phase = 'release the original B operation and verify exact revision conflict';
    assertThat(releaseEditorPushGate(gate), 'held B push was not released exactly once');
    syncStatusInterval = setInterval(() => {
      void state.pageB.getByRole('button', { name: 'Sync error', exact: true })
        .isVisible().then((visible) => { syncErrorObserved ||= visible; }).catch(() => {});
    }, 100);
    await waitUntil(() => API_ROUTES.some((route) => route.batchId === rejectedBatch.batchId &&
      route.profile === 'B' && route.node === 'B' && route.status === 409),
    'B original one-operation push receives HTTP 409 through node B');
    const rejectedRoute = API_ROUTES.find((route) => route.batchId === rejectedBatch.batchId &&
      route.profile === 'B' && route.node === 'B' && route.status === 409);
    result.revisionConflictCode = rejectedRoute?.errorCode || null;
    result.rejectedBatchStatus = rejectedRoute?.status || null;
    result.rejectedBatchResponseAtMs = rejectedRoute?.responseAtMs || null;
    result.rejectedBatchHasExactOps = rejectedRoute?.operationIds?.length === 1 &&
      rejectedRoute.operationIds[0] === result.originalStaleOperationId;
    assertThat(result.revisionConflictCode === 'REVISION_CONFLICT' &&
      result.rejectedBatchHasExactOps && rejectedRoute.responseMarkerFree === true &&
      rejectedRoute.responseParseFailed !== true,
    'the held one-operation push did not receive a marker-free REVISION_CONFLICT response');

    state.phase = 'wait for B signed-feed request after the 409';
    await waitUntil(() => CHANGES.some((entry) => entry.profile === 'B' && entry.node === 'B' &&
      entry.status === 200 && entry.markerFree &&
      entry.requestAtMs >= rejectedRoute.responseAtMs && entry.revisions.some((item) =>
        item.recordId === baseline.recordId && item.revisionId === ownerRef.revisionId)),
    'B signed feed refresh after one-operation 409');
    const recoveryFeed = CHANGES.find((entry) => entry.profile === 'B' && entry.node === 'B' &&
      entry.status === 200 && entry.markerFree && entry.requestAtMs >= rejectedRoute.responseAtMs &&
      entry.revisions.some((item) => item.recordId === baseline.recordId &&
        item.revisionId === ownerRef.revisionId));
    await waitUntil(() => PUSHES.some((push) => push.profile === 'B' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === baseline.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === ownerRef.revisionId &&
        ref.operationId !== result.originalStaleOperationId)),
    'B same-pass merge based on owner revision');
    await Promise.all(PUSH_RESPONSE_READS);

    const mergePushes = PUSHES.filter((push) => push.profile === 'B' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === baseline.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === ownerRef.revisionId &&
        ref.operationId !== result.originalStaleOperationId));
    const mergeRefs = mergePushes.flatMap((push) => push.refs.filter((ref) =>
      ref.recordId === baseline.recordId && ref.operation === 'update' &&
      ref.baseRevisionId === ownerRef.revisionId &&
      ref.operationId !== result.originalStaleOperationId));
    const uniqueMerges = new Map(mergeRefs.map((ref) => [`${ref.operationId}/${ref.revisionId}`, ref]));
    const mergedRef = [...uniqueMerges.values()][0] || null;
    const mergeRoute = mergePushes.length === 1 && mergePushes[0].batchId
      ? API_ROUTES.find((route) => route.batchId === mergePushes[0].batchId) : null;
    const mergeReceipts = (mergeRoute?.resultRefs || []).filter((receipt) =>
      receipt.operationId === mergedRef?.operationId && receipt.revisionId === mergedRef?.revisionId);
    result.originalStaleOperationAttemptCount = PUSHES.filter((push) => push.profile === 'B')
      .flatMap((push) => push.refs).filter((ref) =>
        ref.operationId === result.originalStaleOperationId).length;
    result.mergedOperationId = mergedRef?.operationId || null;
    result.mergedRevisionId = mergedRef?.revisionId || null;
    result.mergedBaseRevisionId = mergedRef?.baseRevisionId || null;
    result.recoveryFeedRequestAtMs = recoveryFeed?.requestAtMs || null;
    result.samePassFeedAfter409 = Boolean(recoveryFeed &&
      recoveryFeed.requestAtMs >= rejectedRoute.responseAtMs);
    result.samePassAutoMerge = uniqueMerges.size === 1 && mergePushes.length === 1 &&
      result.mergedBaseRevisionId === ownerRef.revisionId &&
      result.mergedOperationId !== result.originalStaleOperationId &&
      result.secondDeviceId === mergedRef?.deviceId;
    result.mergeCommittedExactlyOnce = mergeRoute?.profile === 'B' && mergeRoute.node === 'B' &&
      mergeRoute.status >= 200 && mergeRoute.status < 300 &&
      mergeRoute.operationRefs?.length === 1 && mergeReceipts.length === 1 &&
      mergeReceipts[0].alreadyCommitted !== true;
    result.recoveryPushAfterFeed = Boolean(mergeRoute &&
      mergeRoute.atMs >= recoveryFeed.requestAtMs);
    result.syncErrorShownDuringRecovery = syncErrorObserved;
    const recoveryChecks = {
      samePassFeedAfter409: result.samePassFeedAfter409,
      samePassAutoMerge: result.samePassAutoMerge,
      mergeCommittedExactlyOnce: result.mergeCommittedExactlyOnce,
      recoveryPushAfterFeed: result.recoveryPushAfterFeed,
      originalStaleOperationAttemptedOnce: result.originalStaleOperationAttemptCount === 1,
      syncErrorNotShownDuringRecovery: !result.syncErrorShownDuringRecovery,
    };
    if (!Object.values(recoveryChecks).every(Boolean)) {
      console.error(`PG_SYNC_HOST_SINGLE_RECOVERY_CHECKS:${JSON.stringify({
        checks: recoveryChecks,
        uniqueMergeCount: uniqueMerges.size,
        mergePushCount: mergePushes.length,
        staleOperationAttemptCount: result.originalStaleOperationAttemptCount,
        feedRequestAtMs: recoveryFeed?.requestAtMs || null,
        rejectedResponseAtMs: rejectedRoute.responseAtMs,
        mergeRouteFound: Boolean(mergeRoute),
        mergeReceiptCount: mergeReceipts.length,
        syncErrorShownDuringRecovery: result.syncErrorShownDuringRecovery,
      })}`);
    }
    state.phase = 'validate signed-feed recovery and same-pass merge assertions';
    assertThat(Object.values(recoveryChecks).every(Boolean),
      'B did not recover the single-operation revision conflict in the same sync pass');

    state.phase = 'wait for both profiles to decrypt the final merged Host';
    const finalValues = { name: REMOTE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS };
    await Promise.all([
      waitHost(state.pageA, baseline.recordId, finalValues, 'A final merged Host'),
      waitHost(state.pageB, baseline.recordId, finalValues, 'B final merged Host'),
    ]);
    result.bothProfilesDecryptedFinalHost =
      await hostValuesVisible(state.pageA, baseline.recordId, finalValues) &&
      await hostValuesVisible(state.pageB, baseline.recordId, finalValues);
    assertThat(result.bothProfilesDecryptedFinalHost,
      'both profiles did not decrypt the final merged Host fields');

    state.phase = 'assert single-host API privacy and absence of conflict branches';
    const monitoredRoutes = API_ROUTES.filter((route) => route.profile === 'A' || route.profile === 'B')
      .filter((route) => /\/sync\/push$|\/changes$/i.test(route.path));
    const conflictCreateRoutes = API_ROUTES.filter((route) => route.method === 'POST' &&
      /\/conflicts$/i.test(route.path));
    result.noConflictsRequested = conflictCreateRoutes.length === 0;
    result.privacyMarkersAbsent = MARKERS.every(Boolean) &&
      PUSHES.filter((push) => push.refs.some((ref) => ref.recordId === baseline.recordId))
        .every((push) => push.markerFree) && CHANGES.every((entry) => entry.markerFree) &&
      monitoredRoutes.filter((route) => /\/sync\/push$/i.test(route.path))
        .every((route) => route.markerFree !== false && route.responseMarkerFree !== false &&
          route.parseFailed !== true && route.responseParseFailed !== true);
    assertThat(result.noConflictsRequested && result.privacyMarkersAbsent,
      'single-host sync created a conflict branch or exposed a synthetic marker');

    state.phase = 'assert Chromium runtime and request health';
    await resolveProtocolConsoleErrors(rejectedBatch.batchId);
    flushUnmatchedOfflineConsoleErrors();
    result.pageErrors = ERRORS.page;
    result.consoleErrors = ERRORS.console;
    result.expectedOfflineConsoleErrors = ERRORS.expectedOfflineConsole;
    result.expectedProtocolConsoleErrors = ERRORS.expectedProtocolConsole;
    result.unexpectedRequestErrors = ERRORS.unexpectedRequest;
    result.expectedOfflineRequestFailures = ERRORS.offlineRequest;
    if (result.pageErrors !== 0 || result.consoleErrors !== 0 ||
        result.unexpectedRequestErrors !== 0) {
      console.error(`PG_SYNC_HOST_SINGLE_BROWSER_HEALTH_COUNTS:${JSON.stringify({
        pageErrors: result.pageErrors,
        consoleErrors: result.consoleErrors,
        expectedOfflineConsoleErrors: result.expectedOfflineConsoleErrors,
        expectedProtocolConsoleErrors: result.expectedProtocolConsoleErrors,
        unexpectedRequestErrors: result.unexpectedRequestErrors,
        expectedOfflineRequestFailures: result.expectedOfflineRequestFailures,
      })}`);
    }
    assertThat(result.pageErrors === 0 && result.consoleErrors === 0 &&
      result.unexpectedRequestErrors === 0 && result.expectedProtocolConsoleErrors === 1,
    'Chromium observed an unexpected page, console, or request error');
    result.success = true;

    const closeResults = await Promise.allSettled([state.contextA.close(), state.contextB.close()]);
    await state.browser.close();
    for (const socket of proxy._sockets) socket.destroy();
    await new Promise((resolve) => proxy.close(resolve));
    state.cleaned = closeResults.every((item) => item.status === 'fulfilled') &&
      !state.browser.isConnected() && !proxy.listening;
    result.browserCleanupComplete = state.cleaned;
    assertThat(state.cleaned, 'Chromium contexts/browser or PG proxy did not clean up');
    console.log(`PG_SYNC_HOST_SINGLE_REVISION_CONFLICT_RESULT:${JSON.stringify(result)}`);
    console.log('assert: pg_two_node_single_record_revision_conflict_recovery=true');
  } finally {
    if (syncStatusInterval) clearInterval(syncStatusInterval);
    if (gate && !gate.released) releaseEditorPushGate(gate);
  }
}

async function runBatchRevisionConflictAcceptance(state) {
  assertThat(INDEPENDENT_TAG && INDEPENDENT_ADDRESS && INDEPENDENT_NAME,
    'two-Host revision-conflict inputs are incomplete');
  const result = { runnerTriggeredManualSync: false, browserCleanupComplete: false };
  let gate = null;
  let syncStatusInterval = null;
  let syncErrorObserved = false;
  try {
    state.phase = 'create two baseline Hosts and let B pull both signed revisions';
    const primary = await createOwnerHost(state.pageA, {
      name: BASE_NAME, address: HOST_ADDRESS, tag: BASE_TAG,
    });
    const independent = await createOwnerHost(state.pageA, {
      name: INDEPENDENT_NAME, address: INDEPENDENT_ADDRESS, tag: BASE_TAG,
    });
    assertThat(primary.vaultId === independent.vaultId &&
      primary.recordId !== independent.recordId && primary.ownerDeviceId === independent.ownerDeviceId,
    'baseline Host records did not share one Vault and owner device');
    const ownerDeviceId = primary.ownerDeviceId;
    const baselineRefs = [primary, independent];
    await waitUntil(() => baselineRefs.every((ref) => CHANGES.some((entry) =>
      entry.profile === 'B' && entry.node === 'B' && entry.status === 200 &&
      entry.revisions.some((item) => item.recordId === ref.recordId &&
        item.revisionId === ref.revisionId))),
    'B signed-feed pull of both exact baseline revisions');
    await Promise.all([
      waitHost(state.pageB, primary.recordId,
        { name: BASE_NAME, tag: BASE_TAG, address: HOST_ADDRESS }, 'B baseline primary Host'),
      waitHost(state.pageB, independent.recordId,
        { name: INDEPENDENT_NAME, tag: BASE_TAG, address: INDEPENDENT_ADDRESS },
        'B baseline independent Host'),
    ]);

    state.phase = 'persist two pending B edits while its browser is offline';
    const bRoutesBeforeOffline = API_ROUTES.filter((route) => route.profile === 'B' &&
      route.method === 'POST' && /\/sync\/push$/i.test(route.path)).length;
    intentionallyOfflineB = true;
    await state.contextB.setOffline(true);
    await editHost(state.pageB, primary.recordId, { Tags: LOCAL_TAG });
    await waitHost(state.pageB, primary.recordId,
      { name: BASE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS }, 'B offline primary edit');
    await editHost(state.pageB, independent.recordId, { Tags: INDEPENDENT_TAG });
    await waitHost(state.pageB, independent.recordId,
      { name: INDEPENDENT_NAME, tag: INDEPENDENT_TAG, address: INDEPENDENT_ADDRESS },
    'B offline independent edit');
    const bRoutesAfterOffline = API_ROUTES.filter((route) => route.profile === 'B' &&
      route.method === 'POST' && /\/sync\/push$/i.test(route.path)).length;
    assertThat(bRoutesAfterOffline === bRoutesBeforeOffline,
      'B reached PostgreSQL with a Host push while intentionally offline');

    state.phase = 'hold B two-record batch after its initial signed pull';
    gate = armEditorPushGate();
    await state.contextB.setOffline(false);
    intentionallyOfflineB = false;
    await waitUntil(() => gate.record !== null,
      'B two-record sync push captured before forwarding', 60000);
    const rejectedBatch = gate.record;
    const rejectedRefs = rejectedBatch.operationRefs || [];
    const rejectedPrimary = rejectedRefs.find((ref) => ref.recordId === primary.recordId);
    const rejectedIndependent = rejectedRefs.find((ref) => ref.recordId === independent.recordId);
    result.vaultId = primary.vaultId;
    result.primaryRecordId = primary.recordId;
    result.independentRecordId = independent.recordId;
    result.primaryCreateOperationId = primary.operationId;
    result.independentCreateOperationId = independent.operationId;
    result.ownerDeviceId = ownerDeviceId;
    result.baseRevisionId = primary.revisionId;
    result.independentBaseRevisionId = independent.revisionId;
    result.rejectedBatchId = rejectedBatch.batchId;
    result.rejectedOperationIds = rejectedRefs.map((ref) => ref.operationId);
    result.originalStaleOperationId = rejectedPrimary?.operationId || null;
    result.originalStaleRevisionId = rejectedPrimary?.revisionId || null;
    result.originalIndependentOperationId = rejectedIndependent?.operationId || null;
    result.originalIndependentRevisionId = rejectedIndependent?.revisionId || null;
    result.secondDeviceId = rejectedPrimary?.deviceId || null;
    result.twoRecordBatchCaptured = rejectedRefs.length === 2 &&
      new Set(rejectedRefs.map((ref) => ref.recordId)).size === 2 &&
      rejectedPrimary?.operation === 'update' && rejectedIndependent?.operation === 'update' &&
      rejectedPrimary.baseRevisionId === primary.revisionId &&
      rejectedIndependent.baseRevisionId === independent.revisionId &&
      rejectedPrimary.deviceId === rejectedIndependent.deviceId &&
      rejectedBatch.node === 'B' && rejectedBatch.markerFree === true &&
      rejectedBatch.parseFailed !== true;
    assertThat(result.twoRecordBatchCaptured && result.secondDeviceId !== ownerDeviceId &&
      rejectedBatch.batchId && rejectedPrimary.operationId && rejectedPrimary.revisionId &&
      rejectedIndependent.operationId && rejectedIndependent.revisionId,
    'B did not send one marker-free, signed two-record update batch through node B');

    state.phase = 'commit owner competing update through node A while B batch is held';
    const ownerPushStart = PUSHES.length;
    await editHost(state.pageA, primary.recordId, { 'Display name': REMOTE_NAME });
    await waitUntil(() => PUSHES.slice(ownerPushStart).some((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === primary.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === primary.revisionId)),
    'owner competing update receipt via node A');
    const ownerPush = PUSHES.slice(ownerPushStart).find((push) => push.profile === 'A' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === primary.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === primary.revisionId));
    const ownerRef = ownerPush?.refs.find((ref) => ref.recordId === primary.recordId &&
      ref.operation === 'update' && ref.baseRevisionId === primary.revisionId);
    const ownerRoute = ownerPush && routeForPush(ownerPush, primary.recordId);
    result.ownerRevisionId = ownerRef?.revisionId || null;
    result.ownerOperationId = ownerRef?.operationId || null;
    result.ownerUpdateNode = ownerRoute?.node || null;
    assertThat(ownerRef?.revisionId && ownerRef.revisionId !== primary.revisionId &&
      ownerRef.deviceId === ownerDeviceId && ownerRoute?.node === 'A' &&
      ownerRoute.status === ownerPush.status,
    'owner did not commit the competing Host revision through PostgreSQL node A');
    await waitHost(state.pageA, primary.recordId,
      { name: REMOTE_NAME, tag: BASE_TAG, address: HOST_ADDRESS },
      'owner competing Host head');

    state.phase = 'release original B batch and verify atomic revision conflict';
    assertThat(releaseEditorPushGate(gate), 'held B push was not released exactly once');
    syncStatusInterval = setInterval(() => {
      void state.pageB.getByRole('button', { name: 'Sync error', exact: true })
        .isVisible().then((visible) => { syncErrorObserved ||= visible; }).catch(() => {});
    }, 100);
    await waitUntil(() => API_ROUTES.some((route) => route.batchId === rejectedBatch.batchId &&
      route.profile === 'B' && route.node === 'B' && route.status === 409),
    'B original two-record batch receives HTTP 409 through node B', 45000);
    const rejectedRoute = API_ROUTES.find((route) => route.batchId === rejectedBatch.batchId &&
      route.profile === 'B' && route.node === 'B' && route.status === 409);
    result.revisionConflictCode = rejectedRoute?.errorCode || null;
    result.rejectedBatchStatus = rejectedRoute?.status || null;
    result.rejectedBatchResponseAtMs = rejectedRoute?.responseAtMs || null;
    result.rejectedBatchHasExactOps = rejectedRoute?.operationIds?.length === 2 &&
      rejectedRoute.operationIds.includes(result.originalStaleOperationId) &&
      rejectedRoute.operationIds.includes(result.originalIndependentOperationId);
    assertThat(result.revisionConflictCode === 'REVISION_CONFLICT' &&
      result.rejectedBatchHasExactOps && rejectedRoute.responseMarkerFree === true &&
      rejectedRoute.responseParseFailed !== true,
    'the held two-record batch did not receive a marker-free REVISION_CONFLICT response');

    state.phase = 'wait for B signed-feed request after atomic 409';
    await waitUntil(() => CHANGES.some((entry) => entry.profile === 'B' && entry.node === 'B' &&
      entry.status === 200 && entry.markerFree && entry.requestAtMs >= rejectedRoute.responseAtMs &&
      entry.revisions.some((item) => item.recordId === primary.recordId &&
        item.revisionId === ownerRef.revisionId)),
    'B signed feed refresh after atomic 409 includes owner revision', 60000);
    const recoveryFeed = CHANGES.find((entry) => entry.profile === 'B' && entry.node === 'B' &&
      entry.status === 200 && entry.requestAtMs >= rejectedRoute.responseAtMs &&
      entry.revisions.some((item) => item.recordId === primary.recordId &&
        item.revisionId === ownerRef.revisionId));

    state.phase = 'wait for B same-pass merge and independent-record commits';
    const recoveredPushes = () => PUSHES.filter((push) => push.profile === 'B' &&
      push.node === 'B' && push.status >= 200 && push.status < 300);
    const hasRecoveredWork = () => {
      const refs = recoveredPushes().flatMap((push) => push.refs);
      const primaryMerges = refs.filter((ref) => ref.recordId === primary.recordId &&
        ref.operation === 'update' && ref.baseRevisionId === ownerRef.revisionId &&
        ref.deviceId === result.secondDeviceId && ref.operationId !== result.originalStaleOperationId);
      const independentCommits = refs.filter((ref) => ref.recordId === independent.recordId &&
        ref.operationId === result.originalIndependentOperationId &&
        ref.revisionId === result.originalIndependentRevisionId &&
        ref.baseRevisionId === independent.revisionId);
      return primaryMerges.length >= 1 && independentCommits.length >= 1;
    };
    await waitUntil(hasRecoveredWork,
      'B same-pass merged Host and original independent Host operation receipts', 60000)
      .catch((error) => {
        const relevantRoutes = API_ROUTES.filter((route) => route.profile === 'B' &&
          route.method === 'POST' && /\/sync\/push$/i.test(route.path));
        const recoveryDiagnostics = {
          postFeedPushCount: relevantRoutes.filter((route) =>
            route.atMs >= recoveryFeed.atMs).length,
          changes: CHANGES.filter((entry) => entry.profile === 'B').map((entry) => ({
            status: entry.status,
            requestedAfter409: entry.requestAtMs >= rejectedRoute.responseAtMs,
            includesOwnerRevision: entry.revisions.some((item) =>
              item.recordId === primary.recordId && item.revisionId === ownerRef.revisionId),
            revisionCount: entry.revisions.length,
          })),
          pushes: relevantRoutes.map((route) => ({
            status: route.status,
            afterFeed: route.atMs >= recoveryFeed.atMs,
            errorCode: route.errorCode || null,
            operationCount: (route.operationRefs || []).length,
            operations: (route.operationRefs || []).map((ref) => ({
              operationId: ref.operationId,
              recordId: ref.recordId,
              revisionId: ref.revisionId,
              baseRevisionId: ref.baseRevisionId,
              deviceId: ref.deviceId,
              operation: ref.operation,
            })),
            receipts: route.resultRefs || [],
            expectedPrimaryMergeReceipt: (route.resultRefs || []).some((receipt) =>
              (route.operationRefs || []).some((ref) =>
                ref.operationId === receipt.operationId &&
                ref.recordId === primary.recordId && ref.operation === 'update' &&
                ref.baseRevisionId === ownerRef.revisionId &&
                ref.deviceId === result.secondDeviceId &&
                ref.operationId !== result.originalStaleOperationId)),
            expectedIndependentReceipt: (route.resultRefs || []).some((receipt) =>
              (route.operationRefs || []).some((ref) =>
                ref.operationId === receipt.operationId &&
                ref.operationId === result.originalIndependentOperationId &&
                ref.recordId === independent.recordId &&
                ref.revisionId === result.originalIndependentRevisionId &&
                ref.baseRevisionId === independent.revisionId)),
            markerFree: route.markerFree === true && route.responseMarkerFree === true,
          })),
        };
        console.error(`PG_SYNC_HOST_BATCH_RECOVERY_DIAGNOSTICS:${JSON.stringify(recoveryDiagnostics)}`);
        throw error;
      });
    clearInterval(syncStatusInterval);
    syncStatusInterval = null;
    result.syncErrorShownDuringRecovery = syncErrorObserved;
    const successfulBPushes = recoveredPushes();
    const primaryMergeRefs = successfulBPushes.flatMap((push) => push.refs)
      .filter((ref) => ref.recordId === primary.recordId && ref.operation === 'update' &&
        ref.baseRevisionId === ownerRef.revisionId && ref.deviceId === result.secondDeviceId &&
        ref.operationId !== result.originalStaleOperationId);
    const independentSuccessRefs = successfulBPushes.flatMap((push) => push.refs)
      .filter((ref) => ref.recordId === independent.recordId &&
        ref.operationId === result.originalIndependentOperationId &&
        ref.revisionId === result.originalIndependentRevisionId &&
        ref.baseRevisionId === independent.revisionId);
    result.originalStaleOperationAttemptCount = PUSHES.filter((push) => push.profile === 'B')
      .flatMap((push) => push.refs)
      .filter((ref) => ref.operationId === result.originalStaleOperationId).length;
    const uniquePrimaryMerges = new Map(primaryMergeRefs.map((ref) =>
      [`${ref.operationId}/${ref.revisionId}`, ref]));
    const uniqueIndependentCommits = new Map(independentSuccessRefs.map((ref) =>
      [`${ref.operationId}/${ref.revisionId}`, ref]));
    result.mergedRevisionId = [...uniquePrimaryMerges.values()][0]?.revisionId || null;
    result.mergedOperationId = [...uniquePrimaryMerges.values()][0]?.operationId || null;
    result.mergedBaseRevisionId = [...uniquePrimaryMerges.values()][0]?.baseRevisionId || null;
    result.independentOperationId = [...uniqueIndependentCommits.values()][0]?.operationId || null;
    result.independentRevisionId = [...uniqueIndependentCommits.values()][0]?.revisionId || null;
    result.recoveryFeedRequestAtMs = recoveryFeed?.requestAtMs || null;
    result.samePassFeedAfter409 = Boolean(recoveryFeed &&
      recoveryFeed.requestAtMs >= rejectedRoute.responseAtMs);
    result.samePassAutoMerge = uniquePrimaryMerges.size === 1 &&
      result.mergedBaseRevisionId === ownerRef.revisionId &&
      result.mergedOperationId !== result.originalStaleOperationId;
    result.independentOriginalOperationCommittedOnce = uniqueIndependentCommits.size === 1;
    const recoveryRoutedPushes = successfulBPushes.filter((push) =>
      push.refs.some((ref) => ref.recordId === primary.recordId ||
        ref.recordId === independent.recordId));
    const recoveryRouteEvidence = recoveryRoutedPushes.map((push) => {
      const route = API_ROUTES.find((item) => item.batchId === push.batchId);
      return {
        routeFound: Boolean(route),
        profileB: route?.profile === 'B',
        nodeB: route?.node === 'B',
        successful: route?.status >= 200 && route?.status < 300,
        operationCount: (route?.operationRefs || []).length,
        receiptCount: (route?.resultRefs || []).length,
        primaryMergeReceipt: (route?.resultRefs || []).some((receipt) =>
          (route?.operationRefs || []).some((ref) =>
            ref.operationId === receipt.operationId && ref.recordId === primary.recordId &&
            ref.operation === 'update' && ref.baseRevisionId === ownerRef.revisionId &&
            ref.deviceId === result.secondDeviceId &&
            ref.operationId !== result.originalStaleOperationId)),
        independentReceipt: (route?.resultRefs || []).some((receipt) =>
          (route?.operationRefs || []).some((ref) =>
            ref.operationId === receipt.operationId &&
            ref.operationId === result.originalIndependentOperationId &&
            ref.recordId === independent.recordId &&
            ref.revisionId === result.originalIndependentRevisionId &&
            ref.baseRevisionId === independent.revisionId)),
      };
    });
    result.recoveryPushesRouteToB = recoveryRouteEvidence.length > 0 &&
      recoveryRouteEvidence.every((route) => route.profileB && route.nodeB && route.successful);
    result.recoveryPushAfterFeed = successfulBPushes.some((push) => {
      const route = API_ROUTES.find((item) => item.batchId === push.batchId);
      return route && route.atMs >= recoveryFeed.atMs &&
        push.refs.some((ref) => ref.recordId === primary.recordId ||
          ref.recordId === independent.recordId);
    });
    const recoveryChecks = {
      samePassFeedAfter409: result.samePassFeedAfter409,
      samePassAutoMerge: result.samePassAutoMerge,
      independentOriginalOperationCommittedOnce: result.independentOriginalOperationCommittedOnce,
      recoveryPushesRouteToB: result.recoveryPushesRouteToB,
      recoveryPushAfterFeed: result.recoveryPushAfterFeed,
      originalStaleOperationAttemptedOnce: result.originalStaleOperationAttemptCount === 1,
      syncErrorNotShownDuringRecovery: !result.syncErrorShownDuringRecovery,
    };
    if (!Object.values(recoveryChecks).every(Boolean)) {
      console.error(`PG_SYNC_HOST_BATCH_RECOVERY_CHECKS:${JSON.stringify({
        checks: recoveryChecks,
        uniquePrimaryMergeCount: uniquePrimaryMerges.size,
        uniqueIndependentCommitCount: uniqueIndependentCommits.size,
        rawPrimaryMergeReferenceCount: primaryMergeRefs.length,
        rawIndependentCommitReferenceCount: independentSuccessRefs.length,
        originalStaleOperationAttemptCount: result.originalStaleOperationAttemptCount,
        feed: {
          conflictResponseAtMs: rejectedRoute.responseAtMs,
          feedRequestAtMs: recoveryFeed?.requestAtMs || null,
          feedObservedAtMs: recoveryFeed?.atMs || null,
        },
        recoveryRouteCount: recoveryRouteEvidence.length,
        recoveryRoutes: recoveryRouteEvidence,
        postFeedPushCount: successfulBPushes.filter((push) => {
          const route = API_ROUTES.find((item) => item.batchId === push.batchId);
          return route?.atMs >= recoveryFeed.atMs;
        }).length,
        syncErrorShownDuringRecovery: result.syncErrorShownDuringRecovery,
      })}`);
    }
    state.phase = 'validate merge, independent receipt, route, and status assertions';
    assertThat(Object.values(recoveryChecks).every(Boolean),
    'B did not reconcile the signed feed and commit the merge plus independent op without user retry');

    state.phase = 'wait for both profiles to decrypt final Hosts';
    const finalHostTargets = [
      {
        label: 'profile B primary Host', page: state.pageB, recordId: primary.recordId,
        values: { name: REMOTE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS },
      },
      {
        label: 'profile B independent Host', page: state.pageB, recordId: independent.recordId,
        values: { name: INDEPENDENT_NAME, tag: INDEPENDENT_TAG, address: INDEPENDENT_ADDRESS },
      },
      {
        label: 'profile A primary Host', page: state.pageA, recordId: primary.recordId,
        values: { name: REMOTE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS },
      },
      {
        label: 'profile A independent Host', page: state.pageA, recordId: independent.recordId,
        values: { name: INDEPENDENT_NAME, tag: INDEPENDENT_TAG, address: INDEPENDENT_ADDRESS },
      },
    ];
    const finalHostWaits = await Promise.all(finalHostTargets.map(async (target) => {
      try {
        await waitHost(target.page, target.recordId, target.values,
          `${target.label} decrypts final committed values`);
        return { label: target.label, passed: true };
      } catch (_) {
        return { label: target.label, passed: false };
      }
    }));
    const failedHostWaits = finalHostWaits.filter((item) => !item.passed).map((item) => item.label);
    if (failedHostWaits.length > 0) {
      state.phase = `final decrypted Host waits failed: ${failedHostWaits.join(', ')}`;
      throw new Error('one or more profile Host cards did not converge');
    }

    state.phase = 'verify accessible final values for both Host records';
    result.bothProfilesDecryptedFinalHosts =
      await hostValuesVisible(state.pageA, primary.recordId,
        { name: REMOTE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS }) &&
      await hostValuesVisible(state.pageB, primary.recordId,
        { name: REMOTE_NAME, tag: LOCAL_TAG, address: HOST_ADDRESS }) &&
      await hostValuesVisible(state.pageA, independent.recordId,
        { name: INDEPENDENT_NAME, tag: INDEPENDENT_TAG, address: INDEPENDENT_ADDRESS }) &&
      await hostValuesVisible(state.pageB, independent.recordId,
        { name: INDEPENDENT_NAME, tag: INDEPENDENT_TAG, address: INDEPENDENT_ADDRESS });
    assertThat(result.bothProfilesDecryptedFinalHosts,
      'the four final Host cards did not expose their expected decrypted fields');

    state.phase = 'assert sync request and response privacy';
    const monitoredRoutes = API_ROUTES.filter((route) => route.profile === 'A' ||
      route.profile === 'B').filter((route) =>
      /\/sync\/push$|\/changes$/i.test(route.path));
    result.privacyMarkersAbsent = MARKERS.every(Boolean) &&
      PUSHES.filter((push) => push.refs.some((ref) =>
        ref.recordId === primary.recordId || ref.recordId === independent.recordId))
        .every((push) => push.markerFree) && CHANGES.every((entry) => entry.markerFree) &&
      monitoredRoutes.filter((route) => /\/sync\/push$/i.test(route.path))
        .every((route) => route.markerFree !== false && route.responseMarkerFree !== false &&
          route.parseFailed !== true && route.responseParseFailed !== true);
    assertThat(result.privacyMarkersAbsent,
      'a synthetic Host marker appeared in sync API traffic');

    state.phase = 'assert browser page, console, and request health';
    await resolveProtocolConsoleErrors(rejectedBatch.batchId);
    flushUnmatchedOfflineConsoleErrors();
    result.pageErrors = ERRORS.page;
    result.consoleErrors = ERRORS.console;
    result.expectedOfflineConsoleErrors = ERRORS.expectedOfflineConsole;
    result.expectedProtocolConsoleErrors = ERRORS.expectedProtocolConsole;
    result.unexpectedRequestErrors = ERRORS.unexpectedRequest;
    result.expectedOfflineRequestFailures = ERRORS.offlineRequest;
    result.browserCleanupComplete = false;
    if (result.pageErrors !== 0 || result.consoleErrors !== 0 ||
        result.unexpectedRequestErrors !== 0) {
      console.error(`PG_SYNC_HOST_BATCH_BROWSER_HEALTH_COUNTS:${JSON.stringify({
        pageErrors: result.pageErrors,
        consoleErrors: result.consoleErrors,
        expectedOfflineConsoleErrors: result.expectedOfflineConsoleErrors,
        expectedProtocolConsoleErrors: result.expectedProtocolConsoleErrors,
        unexpectedRequestErrors: result.unexpectedRequestErrors,
        expectedOfflineRequestFailures: result.expectedOfflineRequestFailures,
      })}`);
    }
    assertThat(result.pageErrors === 0 && result.consoleErrors === 0 &&
      result.unexpectedRequestErrors === 0,
    'browser observed a page, console, or unexpected request error');
    result.success = true;

    const closeResults = await Promise.allSettled([state.contextA.close(), state.contextB.close()]);
    await state.browser.close();
    for (const socket of proxy._sockets) socket.destroy();
    await new Promise((resolve) => proxy.close(resolve));
    state.cleaned = closeResults.every((item) => item.status === 'fulfilled') &&
      !state.browser.isConnected() && !proxy.listening;
    result.browserCleanupComplete = state.cleaned;
    assertThat(state.cleaned, 'Chromium contexts/browser or PG proxy did not clean up');
    console.log(`PG_SYNC_HOST_BATCH_REVISION_CONFLICT_RESULT:${JSON.stringify(result)}`);
    console.log('assert: pg_two_node_multi_record_revision_conflict_recovery=true');
  } finally {
    if (syncStatusInterval) clearInterval(syncStatusInterval);
    if (gate && !gate.released) releaseEditorPushGate(gate);
  }
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web release bundle is missing');
  assertThat(BASE_URL && NODE_A_URL && NODE_B_URL && USERNAME && PASSWORD &&
    BOOTSTRAP_TOKEN && BASE_NAME && REMOTE_NAME && BASE_TAG && LOCAL_TAG &&
    HOST_ADDRESS && SSH_USERNAME, 'PG Host merge browser inputs are incomplete');
  assertThat(!(RUN_BATCH_REVISION_CONFLICT && RUN_SINGLE_REVISION_CONFLICT),
    'PG Host merge runner accepts only one revision-conflict mode');
  if (RUN_BATCH_REVISION_CONFLICT) {
    assertThat(INDEPENDENT_TAG && INDEPENDENT_ADDRESS &&
      INDEPENDENT_ADDRESS !== HOST_ADDRESS,
    'PG batch revision-conflict acceptance needs a distinct second Host marker');
  }
  const base = new URL(BASE_URL);
  assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' &&
    !base.pathname.slice(1) && Number(base.port) > 0,
  'PG merge proxy must use its exact loopback origin');

  const state = { phase: 'bind proxy', browser: null, contextA: null, contextB: null,
    pageA: null, pageB: null, cleaned: false };
  let proxyStarted = false;
  try {
    await new Promise((resolve, reject) => {
      proxy.once('error', reject);
      proxy.listen(Number(base.port), '127.0.0.1', resolve);
    });
    proxyStarted = true;
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

    state.phase = 'load Web client contexts';
    await Promise.all([enterFlutter(state.pageA), enterFlutter(state.pageB)]);
    assertThat(await state.pageA.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null &&
      await state.pageB.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null,
    'profile routing header leaked into Web local storage');

    state.phase = 'register owner and create Vault';
    await connect(state.pageA);
    await field(state.pageA, 'Owner email');
    await fill(state.pageA, 'Owner email', USERNAME);
    await fill(state.pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(state.pageA, 'Confirm master password', PASSWORD);
    await fill(state.pageA, 'One-time bootstrap token', BOOTSTRAP_TOKEN);
    await fill(state.pageA, 'Device name', 'PG merge owner device');
    await fill(state.pageA, 'First Vault', 'PG approved-device merge Vault');
    await click(state.pageA, 'Create owner account');
    await waitWorkspace(state.pageA);

    state.phase = 'enroll and approve independent device B';
    await connect(state.pageB);
    await field(state.pageB, 'Email or username');
    await click(state.pageB, 'Add this device');
    await fill(state.pageB, 'Account email', USERNAME);
    await fill(state.pageB, 'Device name', 'PG merge second device');
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

    if (RUN_SINGLE_REVISION_CONFLICT) {
      state.phase = 'run single-record revision-conflict recovery';
      await runSingleRevisionConflictAcceptance(state);
      return;
    }

    if (RUN_BATCH_REVISION_CONFLICT) {
      state.phase = 'run two-record revision-conflict recovery';
      await runBatchRevisionConflictAcceptance(state);
      return;
    }

    state.phase = 'owner creates baseline Host and B pulls through node B';
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
      push.status >= 200 && push.status < 300 && push.refs.some((ref) => ref.operation === 'create'));
    const createRef = createPush.refs.find((ref) => ref.operation === 'create');
    const recordId = createRef.recordId;
    const baseRevisionId = createRef.revisionId;
    const ownerDeviceId = createRef.deviceId;
    assertThat(recordId && baseRevisionId && ownerDeviceId && createRef.operationId &&
      createPush.node === 'A' && createRef.baseRevisionId === null,
    'baseline create did not expose a signed owner revision on node A');
    await waitHost(state.pageA, recordId, { name: BASE_NAME, tag: BASE_TAG }, 'owner baseline Host card');
    await waitUntil(() => CHANGES.some((entry) => entry.profile === 'B' && entry.status === 200 &&
      entry.revisions.some((item) => item.recordId === recordId && item.revisionId === baseRevisionId)),
    'device B pulled the exact baseline revision through node B');
    await waitHost(state.pageB, recordId, { name: BASE_NAME, tag: BASE_TAG }, 'device B decrypted baseline');

    state.phase = 'device B saves Tags while offline';
    const bPushCountBeforeOffline = PUSHES.filter((push) => push.profile === 'B').length;
    const bPushRouteCountBeforeOffline = API_ROUTES.filter((route) =>
      route.profile === 'B' && route.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(route.path)).length;
    intentionallyOfflineB = true;
    await state.contextB.setOffline(true);
    await editHost(state.pageB, recordId, { Tags: LOCAL_TAG });
    await waitHost(state.pageB, recordId, { name: BASE_NAME, tag: LOCAL_TAG }, 'device B local offline edit');
    const bPushRouteCountAfterOffline = API_ROUTES.filter((route) =>
      route.profile === 'B' && route.method === 'POST' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(route.path)).length;
    assertThat(bPushRouteCountAfterOffline === bPushRouteCountBeforeOffline,
      'device B reached the PostgreSQL node with a push while the browser context was offline');

    state.phase = 'owner commits disjoint Name edit through node A';
    await editHost(state.pageA, recordId, { 'Display name': REMOTE_NAME });
    await waitUntil(() => PUSHES.some((push) => push.profile === 'A' && push.status >= 200 &&
      push.status < 300 && push.refs.some((ref) => ref.recordId === recordId &&
        ref.operation === 'update' && ref.baseRevisionId === baseRevisionId)),
    'owner remote update receipt on node A');
    const remotePush = PUSHES.find((push) => push.profile === 'A' && push.status >= 200 &&
      push.status < 300 && push.refs.some((ref) => ref.recordId === recordId &&
        ref.operation === 'update' && ref.baseRevisionId === baseRevisionId));
    const remoteRef = remotePush.refs.find((ref) => ref.recordId === recordId &&
      ref.operation === 'update' && ref.baseRevisionId === baseRevisionId);
    const remoteRoute = routeForPush(remotePush, recordId);
    assertThat(remoteRef.revisionId !== baseRevisionId && remoteRef.deviceId === ownerDeviceId &&
      remoteRoute?.node === 'A' && remoteRoute.status === remotePush.status,
    'owner update did not establish a distinct head through node A');
    await waitHost(state.pageA, recordId, { name: REMOTE_NAME, tag: BASE_TAG }, 'owner remote Host edit');

    state.phase = 'device B reconnects and submits signed merge through node B';
    await state.contextB.setOffline(false);
    intentionallyOfflineB = false;
    const mergedPredicate = () => PUSHES.some((push) => push.profile === 'B' &&
      push.node === 'B' && push.status >= 200 && push.status < 300 &&
      push.refs.some((ref) => ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === remoteRef.revisionId && ref.revisionId !== remoteRef.revisionId));
    await waitUntil(mergedPredicate, 'B signed merge revision based on the remote winner', 60000)
      .catch(async () => {
        await triggerSync(state.pageB);
        await waitUntil(mergedPredicate, 'B signed merge revision based on the remote winner', 60000);
      });
    const mergedPush = PUSHES.find((push) => push.profile === 'B' && push.node === 'B' &&
      push.status >= 200 && push.status < 300 && push.refs.some((ref) =>
        ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === remoteRef.revisionId && ref.revisionId !== remoteRef.revisionId));
    const mergedRef = mergedPush.refs.find((ref) => ref.recordId === recordId &&
      ref.operation === 'update' && ref.baseRevisionId === remoteRef.revisionId);
    const mergedRoute = routeForPush(mergedPush, recordId);
    assertThat(mergedPush.markerFree && mergedRef.operationId && mergedRef.deviceId &&
      mergedRef.deviceId !== ownerDeviceId && mergedRef.revisionId !== baseRevisionId &&
      mergedRef.revisionId !== remoteRef.revisionId && mergedRoute?.node === 'B' &&
      mergedRoute.status === mergedPush.status,
    'B merge was not a fresh, marker-free signed operation based on the remote revision through node B');
    await waitHost(state.pageB, recordId, { name: REMOTE_NAME, tag: LOCAL_TAG },
      'device B decrypted merged Host');
    await waitUntil(() => hostValuesVisible(state.pageA, recordId,
      { name: REMOTE_NAME, tag: LOCAL_TAG }), 'owner pulled merged Host', 60000)
      .catch(async () => {
        await triggerSync(state.pageA);
        await waitHost(state.pageA, recordId, { name: REMOTE_NAME, tag: LOCAL_TAG },
          'owner pulled merged Host after manual sync');
      });

    state.phase = 'validate cross-node routes, privacy and browser health';
    const ownerWrites = PUSHES.filter((push) => push.profile === 'A' &&
      push.refs.some((ref) => ref.recordId === recordId));
    const secondDeviceWrites = PUSHES.filter((push) => push.profile === 'B' &&
      push.refs.some((ref) => ref.recordId === recordId));
    const ownerRoutes = ownerWrites.map((push) => routeForPush(push, recordId));
    const secondDeviceRoutes = secondDeviceWrites.map((push) => routeForPush(push, recordId));
    const successfulMergedRefs = secondDeviceWrites
      .filter((push) => push.status >= 200 && push.status < 300)
      .flatMap((push) => push.refs)
      .filter((ref) => ref.recordId === recordId && ref.operation === 'update' &&
        ref.baseRevisionId === remoteRef.revisionId && ref.operationId && ref.revisionId);
    const successfulMergedOperations = new Set(successfulMergedRefs.map((ref) =>
      `${ref.operationId}/${ref.revisionId}`));
    const bChanges = CHANGES.filter((entry) => entry.profile === 'B');
    const routingValid = ownerWrites.length >= 2 && ownerRoutes.every((route) => route?.node === 'A') &&
      secondDeviceWrites.length >= 1 && secondDeviceRoutes.every((route) => route?.node === 'B') &&
      successfulMergedOperations.size === 1 &&
      bChanges.length > 0 && bChanges.every((entry) => entry.node === 'B' && entry.status === 200);
    const privacyValid = [...ownerWrites, ...secondDeviceWrites].every((push) => push.markerFree) &&
      CHANGES.every((entry) => entry.markerFree);
    const conflictCreateRoutes = API_ROUTES.filter((route) => route.method === 'POST' &&
      /\/conflicts$/i.test(route.path));
    const finalA = await hostValuesVisible(state.pageA, recordId,
      { name: REMOTE_NAME, tag: LOCAL_TAG });
    const finalB = await hostValuesVisible(state.pageB, recordId,
      { name: REMOTE_NAME, tag: LOCAL_TAG });
    await resolveProtocolConsoleErrors(null);
    flushUnmatchedOfflineConsoleErrors();
    const noUnexpectedBrowserErrors = ERRORS.page === 0 && ERRORS.console === 0 &&
      ERRORS.unexpectedRequest === 0;
    assertThat(routingValid, 'owner and approved device did not use their assigned PostgreSQL nodes');
    assertThat(privacyValid, 'sync API request/response exposed a synthetic Host marker');
    assertThat(conflictCreateRoutes.length === 0,
      'disjoint allowlisted Host edits unexpectedly created a conflict branch');
    assertThat(finalA && finalB, 'both Web profiles did not decrypt the same merged Host');
    assertThat(noUnexpectedBrowserErrors, 'Chromium observed an unexpected page, console, or request error');

    const result = {
      recordId,
      vaultId: createPush.vaultId,
      ownerDeviceId,
      secondDeviceId: mergedRef.deviceId,
      baseRevisionId,
      ownerRevisionId: remoteRef.revisionId,
      mergedRevisionId: mergedRef.revisionId,
      mergedOperationId: mergedRef.operationId,
      mergedBaseRevisionId: mergedRef.baseRevisionId,
      ownerUpdateNode: remoteRoute.node,
      mergedUpdateNode: mergedRoute.node,
      ownerCreateAndUpdateCount: ownerWrites.length,
      approvedDevicePushCount: secondDeviceWrites.length,
      approvedDeviceUniqueSuccessfulMergedOperationCount: successfulMergedOperations.size,
      bChangesCount: bChanges.length,
      noConflictsRequested: conflictCreateRoutes.length === 0,
      bothProfilesDecryptedMergedHost: finalA && finalB,
      privacyMarkersAbsent: privacyValid,
      pageErrors: ERRORS.page,
      consoleErrors: ERRORS.console,
      expectedOfflineConsoleErrors: ERRORS.expectedOfflineConsole,
      expectedProtocolConsoleErrors: ERRORS.expectedProtocolConsole,
      unexpectedRequestErrors: ERRORS.unexpectedRequest,
      expectedOfflineRequestFailures: ERRORS.offlineRequest,
      browserCleanupComplete: false,
    };

    const closeResults = await Promise.allSettled([state.contextA.close(), state.contextB.close()]);
    await state.browser.close();
    for (const socket of proxy._sockets) socket.destroy();
    await new Promise((resolve) => proxy.close(resolve));
    proxyStarted = false;
    state.cleaned = closeResults.every((item) => item.status === 'fulfilled') &&
      !state.browser.isConnected() && !proxy.listening;
    result.browserCleanupComplete = state.cleaned;
    assertThat(state.cleaned, 'Chromium contexts/browser or proxy did not clean up');
    console.log(`PG_SYNC_HOST_MERGE_RESULT:${JSON.stringify(result)}`);
    console.log('assert: pg_two_node_approved_device_host_merge=true');
  } catch (error) {
    console.error(`stage: failed (${state.phase}); error type=${error?.name || 'unknown'}`);
    throw error;
  } finally {
    if (!state.cleaned) {
      await Promise.allSettled([state.contextA, state.contextB]
        .filter(Boolean).map((context) => context.close()));
      if (state.browser) await state.browser.close().catch(() => {});
      for (const socket of proxy._sockets) socket.destroy();
      if (proxyStarted) await new Promise((resolve) => proxy.close(resolve));
    }
  }
}

main().catch((error) => {
  console.error(`PG_SYNC_HOST_MERGE_FAILED:${error?.name || 'Error'}`);
  process.exitCode = 1;
});
