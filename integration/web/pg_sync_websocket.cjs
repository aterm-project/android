/*
 * PG-Web-01: two isolated Flutter Web contexts use PostgreSQL-backed
 * notification tickets and a metadata-only cross-node sync hint.
 *
 * The fixture supplies two PG nodes. A same-origin HTTP proxy serves the
 * release bundle from node A, sends notification ticket requests and the Host
 * write to A, and sends the notification WebSocket plus all /changes pulls to
 * B. This runner deliberately prints only safe IDs, counts, and booleans.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_SYNC_WS_BASE_URL;
const NODE_A_URL = process.env.ATERMIUS_PG_SYNC_WS_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_SYNC_WS_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_SYNC_WS_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_SYNC_WS_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_SYNC_WS_BOOTSTRAP_TOKEN;
const HOST_NAME = process.env.ATERMIUS_PG_SYNC_WS_HOST_NAME;
const HOST_ADDRESS = process.env.ATERMIUS_PG_SYNC_WS_HOST_ADDRESS;
const SSH_USERNAME = process.env.ATERMIUS_PG_SYNC_WS_SSH_USERNAME;
const HOST_NAME_2 = process.env.ATERMIUS_PG_SYNC_WS_HOST_NAME_2;
const HOST_ADDRESS_2 = process.env.ATERMIUS_PG_SYNC_WS_HOST_ADDRESS_2;
const SSH_USERNAME_2 = process.env.ATERMIUS_PG_SYNC_WS_SSH_USERNAME_2;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const API_ROUTES = [];
const HTTP_PROXY_DIAGNOSTICS = [];
const SOCKET_ROUTES = [];
const SOCKET_FRAMES = [];
const BROWSER_ERRORS = {
  page: 0,
  console: 0,
  failedRequests: 0,
  failedRequestDiagnostics: [],
};
const SENSITIVE_VALUES = [USERNAME, PASSWORD, BOOTSTRAP_TOKEN, HOST_NAME,
  HOST_ADDRESS, SSH_USERNAME, HOST_NAME_2, HOST_ADDRESS_2, SSH_USERNAME_2]
  .filter(Boolean);
const ACCEPTANCE_TRACE_HEADER = 'x-atermius-acceptance-id';
let acceptanceTraceSequence = 0;
const ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID = new Map();

function safeAcceptanceTraceId(value) {
  return typeof value === 'string' && /^[AB]-[0-9a-z]{1,10}$/.test(value)
    ? value : null;
}

function redactRunnerMessage(message) {
  let safe = String(message || '');
  for (const value of SENSITIVE_VALUES) safe = safe.split(value).join('[redacted]');
  return safe.slice(0, 400);
}

class SafeAcceptanceAssertionError extends Error {}

function assertThat(condition, message) {
  if (!condition) throw new SafeAcceptanceAssertionError(message);
}

class SafeAcceptanceWaitError extends Error {}

function upstreamFor(nodeUrl) {
  const url = new URL(nodeUrl);
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1',
    'PG Web acceptance requires loopback HTTP upstreams');
  return { hostname: url.hostname, port: Number(url.port), origin: url.origin };
}

const upstreamA = upstreamFor(NODE_A_URL || '');
const upstreamB = upstreamFor(NODE_B_URL || '');

function routeFor(method, pathname, upgrade) {
  if (upgrade && pathname === '/api/v1/notifications') return 'B';
  if (!upgrade && method === 'GET' &&
      /^\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(pathname)) return 'B';
  return 'A';
}

function recordApi(method, url, node) {
  const item = { method, path: url.pathname, node, status: null, atMs: Date.now() };
  if (url.pathname.startsWith('/api/v1/')) API_ROUTES.push(item);
  return item;
}

function httpProxyDiagnostic(correlationId) {
  if (!correlationId) return { correlationId: null, exactMatchCount: 0 };
  const matching = HTTP_PROXY_DIAGNOSTICS.filter((item) =>
    item.correlationId === correlationId);
  const item = matching.length === 1 ? matching[0] : null;
  return {
    correlationId,
    exactMatchCount: matching.length,
    ...(item ? {
      method: item.method,
      route: item.route,
      upstreamStatus: item.upstreamStatus,
      upstreamContentLength: item.upstreamContentLength,
      upstreamEndAtMs: item.upstreamEndAtMs,
      upstreamCloseAtMs: item.upstreamCloseAtMs,
      upstreamComplete: item.upstreamComplete,
      upstreamBytes: item.upstreamBytes,
      upstreamErrorCode: item.upstreamErrorCode,
      downstreamFinishAtMs: item.downstreamFinishAtMs,
      downstreamCloseAtMs: item.downstreamCloseAtMs,
      downstreamFinished: item.downstreamFinished,
      clientRequestAbortedAtMs: item.clientRequestAbortedAtMs,
    } : {}),
  };
}

function cdpRequestDiagnostic(capture, profile, correlationId) {
  if (!correlationId) return { correlationId: null, exactMatchCount: 0 };
  const matching = (capture.cdpNetworkRequests || []).filter((item) =>
    item.profile === profile && item.correlationId === correlationId);
  const item = matching.length === 1 ? matching[0] : null;
  return {
    correlationId,
    exactMatchCount: matching.length,
    ...(item ? {
      requestIdSha256Prefix: item.requestIdSha256Prefix,
      initiatorType: item.initiatorType,
      initiatorFrames: item.initiatorFrames,
      responseStatus: item.responseStatus,
      responseAtMs: item.responseAtMs,
      loadingFinishedAtMs: item.loadingFinishedAtMs,
      encodedDataLength: item.encodedDataLength,
      loadingFailedAtMs: item.loadingFailedAtMs,
      loadingFailedReason: item.loadingFailedReason,
      canceled: item.canceled,
      blockedReason: item.blockedReason,
    } : {}),
  };
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url || '/', BASE_URL);
    // Chromium probes this conventional path even though the Flutter Web
    // bundle has no favicon. Keep that optional request out of the PG node
    // route audit and browser error count.
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const node = routeFor(request.method || 'GET', url.pathname, false);
    const target = node === 'B' ? upstreamB : upstreamA;
    const correlationId = safeAcceptanceTraceId(
      request.headers[ACCEPTANCE_TRACE_HEADER]);
    const record = recordApi(request.method || 'GET', url, node);
    const lifecycle = {
      correlationId,
      method: request.method || 'GET',
      route: url.pathname.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}/ig, '/:id'),
      atMs: Date.now(),
      upstreamStatus: null,
      upstreamContentLength: null,
      upstreamEndAtMs: null,
      upstreamCloseAtMs: null,
      upstreamComplete: null,
      upstreamBytes: 0,
      upstreamErrorCode: null,
      downstreamFinishAtMs: null,
      downstreamCloseAtMs: null,
      downstreamFinished: false,
      clientRequestAbortedAtMs: null,
    };
    if (url.pathname.startsWith('/api/v1/')) {
      HTTP_PROXY_DIAGNOSTICS.push(lifecycle);
      if (HTTP_PROXY_DIAGNOSTICS.length > 160) {
        HTTP_PROXY_DIAGNOSTICS.splice(0, HTTP_PROXY_DIAGNOSTICS.length - 160);
      }
    }
    request.on('aborted', () => { lifecycle.clientRequestAbortedAtMs = Date.now(); });
    response.on('finish', () => {
      lifecycle.downstreamFinishAtMs = Date.now();
      lifecycle.downstreamFinished = true;
    });
    response.on('close', () => { lifecycle.downstreamCloseAtMs = Date.now(); });
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers[ACCEPTANCE_TRACE_HEADER];
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      record.status = upstreamResponse.statusCode || null;
      lifecycle.upstreamStatus = upstreamResponse.statusCode || null;
      const contentLength = Number(upstreamResponse.headers['content-length']);
      lifecycle.upstreamContentLength = Number.isSafeInteger(contentLength) &&
          contentLength >= 0 ? contentLength : null;
      upstreamResponse.on('data', (chunk) => { lifecycle.upstreamBytes += chunk.length; });
      upstreamResponse.on('end', () => {
        lifecycle.upstreamEndAtMs = Date.now();
        lifecycle.upstreamComplete = upstreamResponse.complete;
      });
      upstreamResponse.on('aborted', () => { lifecycle.upstreamComplete = false; });
      upstreamResponse.on('close', () => {
        lifecycle.upstreamCloseAtMs = Date.now();
        lifecycle.upstreamComplete = upstreamResponse.complete;
      });
      const responseHeaders = { ...upstreamResponse.headers };
      if (correlationId) responseHeaders[ACCEPTANCE_TRACE_HEADER] = correlationId;
      response.writeHead(upstreamResponse.statusCode || 502, responseHeaders);
      upstreamResponse.pipe(response);
    });
    upstreamRequest.on('error', (error) => {
      lifecycle.upstreamErrorCode = /^[A-Z0-9_]{2,32}$/.test(error?.code || '')
        ? error.code : 'OTHER';
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    request.pipe(upstreamRequest);
  });

  const upgradeSockets = new Set();
  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', BASE_URL);
    const node = routeFor('GET', url.pathname, true);
    const target = node === 'B' ? upstreamB : upstreamA;
    const record = {
      path: url.pathname,
      node,
      status: null,
      hasQuery: url.search.length > 0,
      atMs: Date.now(),
    };
    SOCKET_ROUTES.push(record);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: 'GET',
      path: `${url.pathname}${url.search}`,
      headers,
    });
    upstreamRequest.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      record.status = upstreamResponse.statusCode || null;
      const rawHeaders = upstreamResponse.rawHeaders;
      let responseHead = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
      for (let index = 0; index < rawHeaders.length; index += 2) {
        responseHead += `${rawHeaders[index]}: ${rawHeaders[index + 1]}\r\n`;
      }
      clientSocket.write(`${responseHead}\r\n`);
      if (clientHead?.length) upstreamSocket.write(clientHead);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      upgradeSockets.add(clientSocket);
      upgradeSockets.add(upstreamSocket);
      clientSocket.on('close', () => upgradeSockets.delete(clientSocket));
      upstreamSocket.on('close', () => upgradeSockets.delete(upstreamSocket));
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      record.status = upstreamResponse.statusCode || null;
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
  server._upgradeSockets = upgradeSockets;
  return server;
}

async function installHttpRequestCorrelationProbe(context, profile) {
  await context.route('**/api/v1/**', async (route) => {
    const request = route.request();
    const headers = await request.allHeaders();
    const correlationId = `${profile}-${(++acceptanceTraceSequence).toString(36)}`;
    ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID.set(request._guid, correlationId);
    headers[ACCEPTANCE_TRACE_HEADER] = correlationId;
    await route.continue({ headers });
  });
}

const proxy = makeProxy();

function textOf(message) {
  return Buffer.isBuffer(message) ? message.toString('utf8') : String(message);
}

function objectFromFrame(message) {
  try {
    const value = JSON.parse(textOf(message));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_) {
    return null;
  }
}

function sortedKeys(value) {
  return Object.keys(value || {}).sort();
}

function hasSensitiveValue(serialized) {
  return SENSITIVE_VALUES.some((value) => value && serialized.includes(value));
}

async function installCdpNetworkProbe(page, profile, capture) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Network.enable');
  capture.cdpNetworkRequests ||= [];
  const byRequestId = new Map();
  const extraInfoByRequestId = new Map();
  cdp.on('Network.requestWillBeSent', (event) => {
    const url = new URL(event.request.url);
    if (!url.pathname.startsWith('/api/v1/')) return;
    const frames = event.initiator?.stack?.callFrames || [];
    const initiatorFrames = frames.slice(0, 4).map((frame) => {
      let file = 'unknown';
      try {
        file = new URL(frame.url || BASE_URL, BASE_URL).pathname.split('/').pop() || '/';
      } catch (_) {}
      const functionName = /^[A-Za-z0-9_.$<>-]{1,96}$/.test(frame.functionName || '')
        ? frame.functionName : 'anonymous';
      return {
        functionName,
        file,
        lineNumber: Number.isSafeInteger(frame.lineNumber) ? frame.lineNumber : null,
      };
    });
    const extraInfo = extraInfoByRequestId.get(event.requestId);
    const request = {
      profile,
      correlationId: safeAcceptanceTraceId(
        event.request.headers?.[ACCEPTANCE_TRACE_HEADER]) ||
        safeAcceptanceTraceId(extraInfo?.[ACCEPTANCE_TRACE_HEADER]),
      requestIdSha256Prefix: crypto.createHash('sha256').update(event.requestId)
        .digest('hex').slice(0, 12),
      method: event.request.method,
      route: url.pathname.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}/ig, '/:id'),
      atMs: Math.round((event.wallTime || Date.now() / 1000) * 1000),
      initiatorType: event.initiator?.type || 'unknown',
      initiatorFrames,
      responseStatus: null,
      responseAtMs: null,
      loadingFinishedAtMs: null,
      encodedDataLength: null,
      loadingFailedAtMs: null,
      loadingFailedReason: null,
      canceled: null,
      blockedReason: null,
    };
    capture.cdpNetworkRequests.push(request);
    if (capture.cdpNetworkRequests.length > 160) {
      capture.cdpNetworkRequests.splice(0, capture.cdpNetworkRequests.length - 160);
    }
    byRequestId.set(event.requestId, request);
    extraInfoByRequestId.delete(event.requestId);
  });
  cdp.on('Network.requestWillBeSentExtraInfo', (event) => {
    const request = byRequestId.get(event.requestId);
    if (!request) {
      extraInfoByRequestId.set(event.requestId, event.headers || {});
      return;
    }
    request.correlationId = safeAcceptanceTraceId(
      event.headers?.[ACCEPTANCE_TRACE_HEADER]) || request.correlationId;
  });
  cdp.on('Network.responseReceived', (event) => {
    const request = byRequestId.get(event.requestId);
    if (!request) return;
    request.responseStatus = event.response.status;
    request.responseAtMs = Date.now();
  });
  cdp.on('Network.loadingFinished', (event) => {
    const request = byRequestId.get(event.requestId);
    if (!request) return;
    request.loadingFinishedAtMs = Date.now();
    request.encodedDataLength = Number.isSafeInteger(event.encodedDataLength)
      ? event.encodedDataLength : null;
  });
  cdp.on('Network.loadingFailed', (event) => {
    const request = byRequestId.get(event.requestId);
    if (!request) return;
    request.loadingFailedAtMs = Date.now();
    request.loadingFailedReason = /^net::ERR_[A-Z_]+$/.test(event.errorText || '')
      ? event.errorText : 'OTHER';
    request.canceled = event.canceled === true;
    request.blockedReason = /^[A-Za-z_]{1,48}$/.test(event.blockedReason || '')
      ? event.blockedReason : null;
  });
  return cdp;
}

async function installNotificationProbe(context, profile, capture) {
  await context.routeWebSocket('**/api/v1/notifications', (webSocket) => {
    const url = new URL(webSocket.url());
    const socket = {
      profile,
      path: url.pathname,
      hasQuery: url.search.length > 0,
      hasFragment: url.hash.length > 0,
      hasCredential: Boolean(url.username || url.password),
      atMs: Date.now(),
    };
    SOCKET_FRAMES.push({ profile, direction: 'url', ...socket });
    SOCKET_ROUTES.push({ ...socket, node: 'browser-route', status: 101 });
    const serverSocket = webSocket.connectToServer();
    webSocket.onMessage((message) => {
      const frame = objectFromFrame(message);
      const serialized = textOf(message);
      const validAuth = frame?.type === 'authenticate' &&
        JSON.stringify(sortedKeys(frame)) === JSON.stringify(['ticket', 'type']) &&
        typeof frame.ticket === 'string' && /^[A-Za-z0-9_-]{43}$/.test(frame.ticket);
      SOCKET_FRAMES.push({
        profile,
        direction: 'sent',
        type: typeof frame?.type === 'string' ? frame.type : 'unknown',
        keys: sortedKeys(frame),
        validAuthFrame: validAuth,
        ticketFingerprint: validAuth
          ? crypto.createHash('sha256').update(frame.ticket).digest('hex')
          : null,
        sensitiveValuesAbsent: !hasSensitiveValue(serialized),
      });
      serverSocket.send(message);
    });
    serverSocket.onMessage((message) => {
      const frame = objectFromFrame(message);
      const serialized = textOf(message);
      let metadataOnly = false;
      let safeSummary = { type: 'unknown', keys: sortedKeys(frame) };
      if (frame?.type === 'ready') {
        metadataOnly = JSON.stringify(sortedKeys(frame)) === JSON.stringify([
          'heartbeat_seconds', 'poll_interval_seconds', 'server_generation',
          'sync_required', 'type',
        ]) && typeof frame.server_generation === 'string' &&
          frame.sync_required === true && Number.isInteger(frame.heartbeat_seconds) &&
          Number.isInteger(frame.poll_interval_seconds);
        safeSummary = {
          type: 'ready', keys: sortedKeys(frame), atMs: Date.now(),
          monotonicAtMs: performance.now(),
        };
      } else if (frame?.type === 'sync_required') {
        const commitShape = JSON.stringify(sortedKeys(frame)) ===
          JSON.stringify(['commit_seq', 'type', 'vault_id']);
        const conflictShape = JSON.stringify(sortedKeys(frame)) ===
          JSON.stringify(['conflict_seq', 'type', 'vault_id']);
        const sequence = commitShape ? frame.commit_seq : frame.conflict_seq;
        metadataOnly = (commitShape || conflictShape) &&
          ((frame.vault_id === null && sequence === null) ||
            (typeof frame.vault_id === 'string' && typeof sequence === 'string'));
        safeSummary = {
          type: 'sync_required',
          keys: sortedKeys(frame),
          vaultId: typeof frame.vault_id === 'string' ? frame.vault_id : null,
          commitSeq: commitShape ? frame.commit_seq : null,
          conflictSeq: conflictShape ? frame.conflict_seq : null,
          atMs: Date.now(),
          monotonicAtMs: performance.now(),
        };
      }
      SOCKET_FRAMES.push({
        profile,
        direction: 'received',
        type: safeSummary.type,
        keys: safeSummary.keys,
        metadataOnly,
        sensitiveValuesAbsent: !hasSensitiveValue(serialized),
      });
      if (safeSummary.type === 'ready' || safeSummary.type === 'sync_required') {
        SOCKET_FRAMES.push({ profile, direction: 'safe-summary', ...safeSummary, metadataOnly });
      }
      if (profile === 'B' && (safeSummary.type === 'ready' ||
          safeSummary.type === 'sync_required')) {
        const category = safeSummary.type === 'ready' ? 'ready' :
          frame?.vault_id === null ? 'membership' :
          safeSummary.vaultId === capture.vaultId
            ? typeof safeSummary.commitSeq === 'string' ? 'target_commit' :
              typeof safeSummary.conflictSeq === 'string' ? 'target_conflict' :
              'target_other_shape'
            : typeof frame?.vault_id === 'string' ? 'other_vault' : 'unscoped';
        const suppressTargetHint = capture.dropSyncHintsForB &&
          safeSummary.type === 'sync_required' &&
          frame?.vault_id === capture.vaultId;
        capture.syncHintFrameDiagnosticsForB ||= [];
        capture.syncHintFrameDiagnosticsForB.push({
          category,
          atMs: safeSummary.atMs || Date.now(),
          monotonicAtMs: safeSummary.monotonicAtMs || performance.now(),
          suppressed: suppressTargetHint,
        });
        if (suppressTargetHint) {
          if (category === 'target_commit') {
            capture.droppedSyncHintsForB.push({
              vaultId: safeSummary.vaultId,
              commitSeq: safeSummary.commitSeq,
              atMs: safeSummary.atMs,
              monotonicAtMs: safeSummary.monotonicAtMs,
            });
          }
          return;
        }
      }
      webSocket.send(message);
    });
  });
}

async function installReaderCancelProbe(context) {
  await context.addInitScript(() => {
    try {
      const acceptanceTraceHeader = 'x-atermius-acceptance-id';
      const validCorrelationId = (value) =>
        typeof value === 'string' && /^[AB]-[0-9a-z]{1,10}$/.test(value);
      const responseBodyCorrelationIds = new WeakMap();
      const readerCorrelationIds = new WeakMap();
      const terminalReaders = new WeakSet();
      const recordReaderEvent = (correlationId, type, error, callsite) => {
        if (!validCorrelationId(correlationId)) return;
        const events = globalThis.__atermiusRequestBodyReaderEvents ||= [];
        const sequence = (globalThis.__atermiusRequestBodyReaderEventSequence || 0) + 1;
        globalThis.__atermiusRequestBodyReaderEventSequence = sequence;
        const event = {
          sequence,
          correlationId,
          type,
          wallAtMs: Date.now(),
          monotonicAtMs: performance.now(),
        };
        if (Array.isArray(callsite) && callsite.length > 0) {
          event.callsite = callsite.slice(0, 3);
        }
        const errorName = /^[A-Za-z][A-Za-z0-9]{0,47}$/.test(error?.name || '')
          ? error.name : null;
        if (errorName) event.errorName = errorName;
        events.push(event);
        if (events.length > 512) events.splice(0, events.length - 512);
        globalThis.__atermiusRequestBodyReaderEventTotal =
          (globalThis.__atermiusRequestBodyReaderEventTotal || 0) + 1;
        const ids = globalThis.__atermiusRequestBodyReaderObservedIds ||= [];
        if (!ids.includes(correlationId)) {
          ids.push(correlationId);
          if (ids.length > 256) ids.splice(0, ids.length - 256);
        }
      };

      const originalFetch = globalThis.fetch;
      if (typeof originalFetch === 'function') {
        globalThis.fetch = function (...args) {
          const result = Reflect.apply(originalFetch, this, args);
          try {
            result.then((response) => {
              try {
                const correlationId = response.headers.get(acceptanceTraceHeader);
                if (validCorrelationId(correlationId) && response.body) {
                  responseBodyCorrelationIds.set(response.body, correlationId);
                  recordReaderEvent(correlationId, 'response_body');
                }
              } catch (_) {}
            }, () => {});
          } catch (_) {}
          return result;
        };
      }

      const streamPrototype = ReadableStream.prototype;
      const getReaderDescriptor = Object.getOwnPropertyDescriptor(
        streamPrototype, 'getReader');
      if (getReaderDescriptor && typeof getReaderDescriptor.value === 'function') {
        Object.defineProperty(streamPrototype, 'getReader', {
          ...getReaderDescriptor,
          value: function (...args) {
            const reader = Reflect.apply(getReaderDescriptor.value, this, args);
            try {
              const correlationId = responseBodyCorrelationIds.get(this);
              if (validCorrelationId(correlationId)) {
                readerCorrelationIds.set(reader, correlationId);
                recordReaderEvent(correlationId, 'reader_attached');
              }
            } catch (_) {}
            return reader;
          },
        });
      }

      const appendEvent = (name) => {
        const events = globalThis[name] ||= [];
        events.push({ wallAtMs: Date.now(), monotonicAtMs: performance.now() });
        if (events.length > 512) events.splice(0, events.length - 512);
        globalThis[`${name}Total`] = (globalThis[`${name}Total`] || 0) + 1;
      };
      const readerPrototype = Object.getPrototypeOf(
        new ReadableStream().getReader());
      const descriptor = Object.getOwnPropertyDescriptor(readerPrototype, 'cancel');
      if (descriptor && typeof descriptor.value === 'function') {
        Object.defineProperty(readerPrototype, 'cancel', {
          ...descriptor,
          value: function (...args) {
            const correlationId = readerCorrelationIds.get(this);
            let callsite = [];
            try {
              const stack = String(new Error().stack || '').split('\n');
              callsite = stack.map((line) => {
                if (!line.includes('main.dart.js:')) return null;
                const match = line.match(/\bat\s+(.+?)\s+\([^()]*main\.dart\.js:(\d+):(\d+)\)$/) ||
                  line.match(/\bmain\.dart\.js:(\d+):(\d+)$/);
                if (!match) return null;
                const withFunction = match.length === 4;
                const functionName = withFunction &&
                    /^[A-Za-z0-9_.$<>-]{1,96}$/.test(match[1])
                  ? match[1] : 'anonymous';
                return {
                  functionName,
                  lineNumber: Number(withFunction ? match[2] : match[1]),
                  columnNumber: Number(withFunction ? match[3] : match[2]),
                };
              }).filter(Boolean).slice(0, 3);
              recordReaderEvent(correlationId, 'reader_cancel', null, callsite);
              const events = globalThis.__atermiusReaderCancelEvents ||= [];
              events.push({ wallAtMs: Date.now(), monotonicAtMs: performance.now(), callsite });
              if (events.length > 512) events.splice(0, events.length - 512);
              globalThis.__atermiusReaderCancelEventsTotal =
                (globalThis.__atermiusReaderCancelEventsTotal || 0) + 1;
            } catch (_) {}
            const cancelResult = Reflect.apply(descriptor.value, this, args);
            try {
              if (cancelResult && typeof cancelResult.then === 'function') {
                cancelResult.then(
                  () => {
                    try { recordReaderEvent(correlationId, 'reader_cancel_done'); } catch (_) {}
                  },
                  (error) => {
                    try { recordReaderEvent(correlationId, 'reader_cancel_error', error); } catch (_) {}
                  },
                );
              }
            } catch (_) {}
            return cancelResult;
          },
        });
      }
      const readDescriptor = Object.getOwnPropertyDescriptor(readerPrototype, 'read');
      if (readDescriptor && typeof readDescriptor.value === 'function') {
        Object.defineProperty(readerPrototype, 'read', {
          ...readDescriptor,
          value: function (...args) {
            const result = Reflect.apply(readDescriptor.value, this, args);
            try {
              const correlationId = readerCorrelationIds.get(this);
              result.then((value) => {
                try {
                  if (value?.done === true && !terminalReaders.has(this)) {
                    terminalReaders.add(this);
                    recordReaderEvent(correlationId, 'reader_read_done');
                  }
                } catch (_) {}
              }, (error) => {
                try {
                  if (!terminalReaders.has(this)) {
                    terminalReaders.add(this);
                    recordReaderEvent(correlationId, 'reader_read_error', error);
                  }
                  const events = globalThis.__atermiusReaderReadErrorEvents ||= [];
                  const errorName = /^[A-Za-z][A-Za-z0-9]{0,47}$/.test(error?.name || '')
                    ? error.name : 'Other';
                  events.push({ wallAtMs: Date.now(), monotonicAtMs: performance.now(), errorName });
                  if (events.length > 512) events.splice(0, events.length - 512);
                  globalThis.__atermiusReaderReadErrorEventsTotal =
                    (globalThis.__atermiusReaderReadErrorEventsTotal || 0) + 1;
                } catch (_) {}
              });
            } catch (_) {}
            return result;
          },
        });
      }
      const abortPrototype = AbortController.prototype;
      const abortDescriptor = Object.getOwnPropertyDescriptor(abortPrototype, 'abort');
      if (abortDescriptor && typeof abortDescriptor.value === 'function') {
        Object.defineProperty(abortPrototype, 'abort', {
          ...abortDescriptor,
          value: function (...args) {
            try { appendEvent('__atermiusAbortEvents'); } catch (_) {}
            return Reflect.apply(abortDescriptor.value, this, args);
          },
        });
      }
    } catch (_) {
      // This is a best-effort test diagnostic. It must never change browser behavior.
    }
  });
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
  await page.waitForTimeout(100);
  await locator.press('Control+A');
  await locator.pressSequentially(value, { delay: 25 });
  await page.waitForTimeout(150);
  if (await locator.inputValue() !== value) {
    await locator.fill(value);
    await page.waitForTimeout(100);
  }
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

async function clickUnlockWorkspace(page) {
  const byRole = page.getByRole('button', { name: /Unlock workspace/ });
  if (await byRole.count()) {
    await byRole.first().waitFor({ state: 'visible', timeout: 20000 });
    await byRole.first().click();
    return;
  }
  const byText = page.getByText('Unlock workspace', { exact: true });
  await byText.first().waitFor({ state: 'visible', timeout: 20000 });
  await byText.first().click();
}

async function waitFor(condition, description, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = condition();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new SafeAcceptanceWaitError(`timed out waiting for ${description}`);
}

async function enterFlutter(page, profile) {
  let step = 'navigation';
  try {
    console.log(`profile ${profile}: opening Web release`);
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    console.log(`profile ${profile}: document loaded`);
    step = 'crypto global';
    const cryptoDeadline = Date.now() + 30000;
    let hasCrypto = false;
    while (Date.now() < cryptoDeadline) {
      hasCrypto = await page.evaluate(() =>
        typeof window.sodium?.ready?.then === 'function').catch(() => false);
      if (hasCrypto) break;
      await page.waitForTimeout(100);
    }
    assertThat(hasCrypto, 'Web client crypto module did not load');
    console.log(`profile ${profile}: crypto module loaded`);
    step = 'crypto initialization';
    await page.evaluate(async () => { await window.sodium.ready; });
    step = 'Flutter semantics placeholder';
    const placeholder = page.locator('flt-semantics-placeholder');
    await placeholder.waitFor({ state: 'visible', timeout: 30000 });
    console.log(`profile ${profile}: Flutter semantics ready`);
    step = 'enable accessibility';
    await placeholder.evaluate((element) => element.click());
    console.log(`profile ${profile}: accessibility enabled`);
    step = 'semantics tree';
    const semanticsDeadline = Date.now() + 15000;
    let hasSemantics = false;
    while (Date.now() < semanticsDeadline) {
      hasSemantics = await page.evaluate(() =>
        document.querySelectorAll('flt-semantics').length > 0).catch(() => false);
      if (hasSemantics) break;
      await page.waitForTimeout(100);
    }
    assertThat(hasSemantics, 'Flutter semantics tree did not appear after enabling accessibility');
    console.log(`profile ${profile}: semantics tree visible`);
    step = 'Connect securely control';
    await (await button(page, 'Connect securely'));
    console.log(`profile ${profile}: Flutter Web release loaded`);
  } catch (error) {
    const diagnostics = await page.evaluate(() => ({
      readyState: document.readyState,
      hasSodium: typeof window.sodium?.ready?.then === 'function',
      hasPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      semanticsCount: document.querySelectorAll('flt-semantics').length,
      mainScript: [...document.scripts].some((script) => script.src.includes('main.dart.js')),
      bodyLength: document.body?.innerText?.length || 0,
    })).catch(() => null);
    console.log(`profile ${profile}: load stopped at ${step}; error type=${error?.name || 'unknown'}; diagnostics=${JSON.stringify(diagnostics)}`);
    throw error;
  }
}

async function connect(page) {
  await fill(page, 'Server URL', BASE_URL);
  await click(page, 'Connect securely');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(250);
  if (await locator.inputValue() !== value) {
    await locator.fill(value);
    await page.waitForTimeout(100);
  }
  assertThat(await locator.inputValue() === value, `clipboard field did not retain value: ${label}`);
}

async function waitWorkspace(page, profile) {
  await button(page, 'Add host');
  console.log(`profile ${profile}: workspace unlocked`);
}

async function waitHostVisible(page, name, endpoint) {
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    if (await hostVisible(page, name, endpoint)) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function semanticTextVisible(page, expected) {
  return page.evaluate((value) => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    return nodes.some((node) => {
      const text = [node.getAttribute('aria-label') || '', node.innerText || '',
        node.parentElement?.innerText || ''].join('\n');
      return text.includes(value);
    });
  }, expected).catch(() => false);
}

async function waitSemanticText(page, expected, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await semanticTextVisible(page, expected)) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function waitForLockedWorkspace(page, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const visible = await page.evaluate(() => {
      const text = [...document.querySelectorAll('flt-semantics')]
        .map((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
          node.parentElement?.innerText || ''].join(' ')).join('\n') + '\n' +
        (document.body?.innerText || '');
      return text.includes('Unlock workspace') &&
        text.includes('Receive encrypted changes now');
    }).catch(() => false);
    if (visible) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function workspaceScreenState(page) {
  return page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    const text = nodes.map((node) => [node.getAttribute('aria-label') || '',
      node.innerText || '', node.parentElement?.innerText || ''].join(' ')).join('\n');
    const body = document.body?.innerText || '';
    const combined = `${text}\n${body}`;
    const unlockControlVisible = combined.includes('Unlock workspace');
    const receiveControlVisible = combined.includes('Receive encrypted changes now');
    const lockedScreenVisible = combined.includes('Workspace locked') ||
      (unlockControlVisible && receiveControlVisible);
    const workspaceVisible = combined.includes('Add host');
    return {
      screenState: lockedScreenVisible ? 'locked' :
        workspaceVisible ? 'workspace' : 'transitioning_or_unknown',
      lockedScreenVisible,
      workspaceVisible,
      unlockControlVisible,
      receiveControlVisible,
    };
  }).catch(() => ({
    screenState: 'unavailable',
    lockedScreenVisible: false,
    workspaceVisible: false,
    unlockControlVisible: false,
    receiveControlVisible: false,
  }));
}

async function waitForUnlockedHost(page, name, endpoint, capture, unlockStartedAtMs,
    timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await hostVisible(page, name, endpoint)) return true;
    const screen = await workspaceScreenState(page);
    const devicesUnauthorized = (capture.profileApiRequests || []).find((request) =>
      request.profile === 'B' && request.atMs >= unlockStartedAtMs &&
      request.method === 'GET' && request.path === '/api/v1/devices' &&
      request.status === 401);
    if (screen.lockedScreenVisible && devicesUnauthorized) {
      // Let the response observer finish parsing only the bounded, public error
      // code. Never log response bodies, request headers, or session material.
      await page.waitForTimeout(50);
      const code = /^[A-Z0-9_]{2,64}$/.test(devicesUnauthorized.errorCode || '')
        ? ` (${devicesUnauthorized.errorCode})` : '';
      throw new SafeAcceptanceAssertionError(
        `profile B remained locked after GET /api/v1/devices returned 401${code}`);
    }
    await page.waitForTimeout(100);
  }
  const screen = await workspaceScreenState(page);
  throw new SafeAcceptanceWaitError(
    `profile B did not render the unlocked Host; screen=${screen.screenState}`);
}

async function hostVisible(page, name, endpoint) {
  return page.evaluate(({ name, expectedEndpoint }) =>
    [...document.querySelectorAll('flt-semantics')].some((node) => {
      const group = node.closest('flt-semantics[role="group"]');
      const visibleText = [
        node.getAttribute('aria-label') || '', node.innerText || '',
        node.parentElement?.innerText || '', group?.getAttribute('aria-label') || '',
      ].join('\n');
      return (visibleText.includes(`Host: ${name}; `) || visibleText.includes(name)) &&
        visibleText.includes(`@${expectedEndpoint}`);
    }),
  { name, expectedEndpoint: endpoint }).catch(() => false);
}

function setupPageObservers(page, profile, capture) {
  const pushBodies = new WeakMap();
  const requestTimes = new WeakMap();
  const apiRequests = new WeakMap();
  const requestLifecycles = new WeakMap();
  const changesRequests = new WeakMap();
  page.on('pageerror', () => { BROWSER_ERRORS.page++; });
  page.on('console', (message) => {
    if (message.type() === 'error') BROWSER_ERRORS.console++;
    const text = message.text();
    const prefix = 'ATERMIUS_HTTP_BODY_TRACE:';
    if (!text.startsWith(prefix)) return;
    try {
      const item = JSON.parse(text.slice(prefix.length));
      const allowedRoutes = new Set([
        '/api/v1/devices',
        '/api/v1/vaults/:id/devices',
        '/api/v1/vaults/:id/presence',
        '/api/v1/vaults/:id/changes',
        '/api/v1/vaults/:id/conflict-changes',
        '/api/v1/notifications/tickets',
        '/api/v1/auth/recovery/contexts',
      ]);
      if (!item || !Number.isSafeInteger(item.request) || item.request < 1 ||
          (item.correlationId != null &&
            safeAcceptanceTraceId(item.correlationId) == null) ||
          !Number.isSafeInteger(item.atMs) || !['GET', 'POST', 'PUT', 'DELETE'].includes(item.method) ||
          !allowedRoutes.has(item.route) ||
          !['headers', 'body_complete', 'body_error'].includes(item.stage) ||
          (item.status != null && (!Number.isSafeInteger(item.status) || item.status < 100 || item.status > 599)) ||
          (item.bodyBytes != null && (!Number.isSafeInteger(item.bodyBytes) || item.bodyBytes < 0)) ||
          (item.errorType != null && !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(item.errorType))) return;
      capture.httpBodyDiagnostics ||= [];
      capture.httpBodyDiagnostics.push({ profile, ...item });
      if (capture.httpBodyDiagnostics.length > 200) {
        capture.httpBodyDiagnostics.splice(0, capture.httpBodyDiagnostics.length - 200);
      }
    } catch (_) {}
  });
  page.on('close', () => {
    capture.pageCloseAtMs = Date.now();
    capture.pageClosePhase = capture.phase || 'unknown';
  });
  page.on('framenavigated', (frame) => {
    if (frame === page.mainFrame()) {
      capture.mainFrameNavigations ||= [];
      capture.mainFrameNavigations.push({ atMs: Date.now(), phase: capture.phase || 'unknown' });
    }
  });
  page.on('requestfailed', async (request) => {
    BROWSER_ERRORS.failedRequests++;
    const failedAtMs = Date.now();
    const failedUrl = new URL(request.url());
    const failureText = request.failure()?.errorText || '';
    const failureCode = failureText.match(/\b(ERR_[A-Z_]+)\b/)?.[1] || 'OTHER';
    const apiRequest = apiRequests.get(request);
    const correlationId = apiRequest?.correlationId ||
      ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID.get(request._guid) || null;
    const recentNavigation = (capture.mainFrameNavigations || []).at(-1) || null;
    const diagnostic = {
      profile,
      method: request.method(),
      route: apiRequest?.path || (failedUrl.pathname.startsWith('/api/v1/') ? 'api' : 'non_api'),
      correlationId,
      resourceType: request.resourceType(),
      failureCode,
      phase: apiRequest?.phase || capture.phase || 'unknown',
      requestAtMs: apiRequest?.atMs ?? null,
      failedAtMs,
      elapsedMs: apiRequest?.monotonicAtMs == null ? null :
        Math.max(0, Math.round(performance.now() - apiRequest.monotonicAtMs)),
      navigationRequest: request.isNavigationRequest(),
      pageAlreadyClosed: capture.pageCloseAtMs != null,
      mainFrameNavigationCount: (capture.mainFrameNavigations || []).length,
      lastMainFrameNavigationAtMs: recentNavigation?.atMs ?? null,
      msSinceLastMainFrameNavigation: recentNavigation == null ? null :
        failedAtMs - recentNavigation.atMs,
      cdpNetwork: null,
      httpProxy: null,
    };
    const lifecycle = requestLifecycles.get(request);
    diagnostic.responseAtMs = lifecycle?.responseAtMs ?? null;
    diagnostic.responseStatus = lifecycle?.responseStatus ?? null;
    diagnostic.finishedAtMs = lifecycle?.finishedAtMs ?? null;
    BROWSER_ERRORS.failedRequestDiagnostics.push(diagnostic);
    let completeDiagnostic;
    const diagnosticCompletion = new Promise((resolve) => {
      completeDiagnostic = resolve;
    });
    capture.requestFailureDiagnosticTasks ||= [];
    capture.requestFailureDiagnosticTasks.push(diagnosticCompletion);
    const changesRequest = changesRequests.get(request);
    if (changesRequest) {
      changesRequest.status = 'request_failed';
      changesRequest.bodyProcessed = true;
    }
    try {
      await page.waitForTimeout(25);
      if (apiRequest) {
        diagnostic.httpProxy = httpProxyDiagnostic(correlationId);
        diagnostic.cdpNetwork = cdpRequestDiagnostic(capture, profile, correlationId);
      }
      const bodyProbe = await page.evaluate(() => ({
        readerCancelEvents: globalThis.__atermiusReaderCancelEvents || [],
        abortEvents: globalThis.__atermiusAbortEvents || [],
        readerReadErrorEvents: globalThis.__atermiusReaderReadErrorEvents || [],
        requestBodyReaderEvents: globalThis.__atermiusRequestBodyReaderEvents || [],
      }));
      diagnostic.readerLifecycleEvents = bodyProbe.requestBodyReaderEvents
        .filter((event) => correlationId != null &&
          event.correlationId === correlationId)
        .map((event) => ({
          sequence: event.sequence,
          correlationId: event.correlationId,
          type: event.type,
          offsetFromFailureMs: event.wallAtMs - failedAtMs,
          ...(event.errorName ? { errorName: event.errorName } : {}),
          ...(event.callsite ? { callsite: event.callsite } : {}),
        }))
        .slice(-12);
      const relevant = (events) => events
        .filter((event) => event.wallAtMs >= (diagnostic.requestAtMs || failedAtMs) - 50 &&
          event.wallAtMs <= failedAtMs + 200)
        .map((event) => ({
          offsetMs: event.wallAtMs - (diagnostic.requestAtMs || failedAtMs),
          ...(event.errorName ? { errorName: event.errorName } : {}),
          ...(event.callsite ? { callsite: event.callsite } : {}),
        }))
        .slice(-4);
      diagnostic.readerCancelEventsNearFailure = relevant(bodyProbe.readerCancelEvents);
      diagnostic.abortEventsNearFailure = relevant(bodyProbe.abortEvents);
      diagnostic.readerReadErrorsNearFailure = relevant(bodyProbe.readerReadErrorEvents);
      diagnostic.httpBodyTrace = (capture.httpBodyDiagnostics || [])
        .filter((event) => correlationId != null && event.profile === profile &&
          event.correlationId === correlationId)
        .map((event) => ({
          request: event.request,
          stage: event.stage,
          status: event.status ?? null,
          bodyBytes: event.bodyBytes ?? null,
          errorType: event.errorType ?? null,
        }))
        .slice(-8);
    } catch (_) {
      // The extra trace is optional and cannot affect the failure gate.
    } finally {
      ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID.delete(request._guid);
      completeDiagnostic();
    }
  });
  page.on('requestfinished', (request) => {
    const apiRequest = apiRequests.get(request);
    if (apiRequest) {
      apiRequest.correlationId = ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID.get(request._guid) ||
        apiRequest.correlationId;
    }
    ACCEPTANCE_TRACE_IDS_BY_REQUEST_GUID.delete(request._guid);
  });
  page.on('request', (request) => {
    const url = new URL(request.url());
    requestTimes.set(request, Date.now());
    requestLifecycles.set(request, {
      requestAtMs: Date.now(),
      responseAtMs: null,
      responseStatus: null,
      finishedAtMs: null,
    });
    if (url.pathname.startsWith('/api/v1/')) {
      capture.profileApiRequests ||= [];
      const correlationId = safeAcceptanceTraceId(
        request.headers()[ACCEPTANCE_TRACE_HEADER]);
      const apiRequest = {
        profile,
        correlationId,
        method: request.method(),
        path: url.pathname.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}/ig, '/:id'),
        atMs: Date.now(),
        monotonicAtMs: performance.now(),
        phase: capture.phase || 'unknown',
        status: null,
      };
      capture.profileApiRequests.push(apiRequest);
      apiRequests.set(request, apiRequest);
    }
    if (profile === 'B' && request.method() === 'GET' &&
        /^\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(url.pathname)) {
      const match = url.pathname.match(/\/api\/v1\/vaults\/([0-9a-f-]+)\/changes$/i);
      const changesRequest = {
        vaultId: match?.[1] || null,
        requestAtMs: Date.now(),
        monotonicAtMs: performance.now(),
        status: null,
        bodyProcessed: false,
        hintSuppressionActive: Boolean(capture.dropSyncHintsForB),
      };
      capture.bChangeRequests ||= [];
      capture.bChangeRequests.push(changesRequest);
      changesRequests.set(request, changesRequest);
    }
    if (/\/api\/v1\/(?:relay|.*ssh|.*terminal-sessions)/i.test(url.pathname)) {
      capture.relayAndSshRequests++;
    }
    if (profile === 'B' && request.method() === 'POST' &&
        /\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(url.pathname)) {
      capture.bPushRequests.push({ atMs: Date.now() });
    }
    if (profile === 'A' && request.method() === 'POST' &&
        /\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(url.pathname)) {
      try {
        const body = request.postDataJSON();
        const operations = body?.operations || [];
        const operation = operations.find((item) =>
          typeof item?.header?.record_id === 'string' &&
          typeof item?.header?.revision_id === 'string');
        if (operation) {
          const serialized = JSON.stringify(body);
          pushBodies.set(request, {
            vaultId: body.vault_id,
            recordId: operation.header.record_id,
            revisionId: operation.header.revision_id,
            operationCount: operations.length,
            privacyMarkersAbsent: !hasSensitiveValue(serialized),
          });
          capture.pushRequests.push({
            ...pushBodies.get(request),
            atMs: Date.now(),
            monotonicAtMs: performance.now(),
          });
        }
      } catch (_) {}
    }
  });
  page.on('response', (response) => {
    const request = response.request();
    const url = new URL(response.url());
    const lifecycle = requestLifecycles.get(request);
    if (lifecycle) {
      lifecycle.responseAtMs = Date.now();
      lifecycle.responseStatus = response.status();
    }
    const changesRequest = changesRequests.get(request);
    if (changesRequest) changesRequest.status = response.status();
    const apiRequest = apiRequests.get(request);
    if (apiRequest) {
      apiRequest.status = response.status();
      if (response.status() >= 400) {
        void response.json().then((body) => {
          const code = body?.error?.code;
          if (typeof code === 'string' && /^[A-Z0-9_]{2,64}$/.test(code)) {
            apiRequest.errorCode = code;
          }
        }).catch(() => {});
      }
    }
    if (profile === 'A' && pushBodies.has(request)) {
      void (async () => {
        try {
          const body = await response.json();
          const receipt = Array.isArray(body?.results) ? body.results[0] : null;
          const push = pushBodies.get(request);
          capture.pushReceipts.push({
            ...push,
            status: response.status(),
            commitSeq: typeof receipt?.commit_seq === 'string' ? receipt.commit_seq : null,
            atMs: Date.now(),
          });
        } catch (_) {
          capture.pushReceipts.push({ status: response.status(), commitSeq: null });
        }
      })();
    }
    if (request.method() === 'POST' && url.pathname === '/api/v1/notifications/tickets') {
      void (async () => {
        try {
          const body = await response.json();
          if (typeof body?.ticket === 'string' && /^[A-Za-z0-9_-]{43}$/.test(body.ticket)) {
            capture.ticketHashes.push({
              profile,
              hash: crypto.createHash('sha256').update(body.ticket).digest('hex'),
              status: response.status(),
            });
          }
        } catch (_) {}
      })();
    }
    if (profile === 'B' && request.method() === 'GET' && url.pathname.endsWith('/changes')) {
      const requestAtMs = requestTimes.get(request) || Date.now();
      void (async () => {
        try {
          const body = await response.json();
          const events = Array.isArray(body?.events) ? body.events : [];
          const vaultMatch = url.pathname.match(/\/api\/v1\/vaults\/([0-9a-f-]+)\/changes$/i);
          const eventRevisions = events.map((event) => ({
            commitSeq: typeof event?.commit_seq === 'string' ? event.commit_seq : null,
            recordId: event?.envelope?.header?.record_id,
            revisionId: event?.envelope?.header?.revision_id,
          })).filter((event) => typeof event.recordId === 'string' &&
            typeof event.revisionId === 'string');
          capture.bChanges.push({
            status: response.status(),
            requestAtMs,
            monotonicAtMs: changesRequests.get(request)?.monotonicAtMs ?? null,
            responseAtMs: Date.now(),
            vaultId: vaultMatch?.[1] || null,
            eventCount: events.length,
            privacyMarkersAbsent: !hasSensitiveValue(JSON.stringify(events)),
            eventRevisions,
          });
          if (changesRequests.has(request)) {
            changesRequests.get(request).bodyProcessed = true;
          }
        } catch (_) {
          capture.bChanges.push({
            status: response.status(), requestAtMs,
            monotonicAtMs: changesRequests.get(request)?.monotonicAtMs ?? null,
            responseAtMs: Date.now(),
            vaultId: url.pathname.match(/\/api\/v1\/vaults\/([0-9a-f-]+)\/changes$/i)?.[1] || null,
            eventCount: null,
            privacyMarkersAbsent: false, eventRevisions: [],
          });
          if (changesRequests.has(request)) {
            changesRequests.get(request).bodyProcessed = true;
          }
        }
      })();
    }
  });
  page.on('requestfinished', (request) => {
    const lifecycle = requestLifecycles.get(request);
    if (lifecycle) lifecycle.finishedAtMs = Date.now();
  });
}

async function readClientSqliteFiles(page) {
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
      const requestValue = (request) => new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error || new Error('IDB read failed'));
      });
      const transactionComplete = (transaction) => new Promise((resolve, reject) => {
        transaction.oncomplete = resolve;
        transaction.onerror = () => reject(transaction.error || new Error('IDB transaction failed'));
        transaction.onabort = () => reject(transaction.error || new Error('IDB transaction aborted'));
      });
      const filesTx = connection.transaction('files', 'readonly');
      const filesDone = transactionComplete(filesTx);
      const valuesPromise = requestValue(filesTx.objectStore('files').getAll());
      const keysPromise = requestValue(filesTx.objectStore('files').getAllKeys());
      const [values, keys] = await Promise.all([valuesPromise, keysPromise, filesDone]);
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
      const blocksDone = transactionComplete(blocksTx);
      const store = blocksTx.objectStore('blocks');
      const sqliteFiles = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0],
          [file.fileId, Number.MAX_SAFE_INTEGER]);
        const keysPromise = requestValue(store.getAllKeys(range));
        const valuesPromise = requestValue(store.getAll(range));
        const [blockKeys, blockValues] = await Promise.all([keysPromise, valuesPromise]);
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
      await blocksDone;
      return { available: true, sqliteFiles };
    } finally {
      connection.close();
    }
  });
}

function inspectLockedSyncState(sqliteFiles, { vaultId, recordId, revisionId, markers }) {
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'B IndexedDB snapshot had no database or an active SQLite journal');
  const bytes = reconstructSqliteFile({
    fileId: databaseFile.fileId,
    name: databaseFile.name,
    length: databaseFile.length,
    blocks: databaseFile.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  const databasePath = path.join(os.tmpdir(),
    `atermius-pg-locked-sync-${crypto.randomUUID()}.sqlite`);
  fs.writeFileSync(databasePath, bytes, { mode: 0o600 });
  fs.chmodSync(databasePath, 0o600);
  bytes.fill(0);
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id,revision_id=sys.argv[2:5]',
    'markers=sys.argv[5:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    'def digest(value):',
    '    return hashlib.sha256(value.encode()).hexdigest() if value is not None else None',
    'def canonical_digest(value):',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest()',
    "main=db.execute('SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=? ORDER BY instance_id,server_space_id LIMIT 1',(vault_id,)).fetchone()",
    "locked=db.execute('SELECT cursor,server_generation,next_page_index FROM locked_sync_checkpoints WHERE vault_id=? ORDER BY instance_id,server_space_id LIMIT 1',(vault_id,)).fetchone()",
    "pages=db.execute('SELECT page_index,start_cursor,next_cursor,events_json FROM locked_sync_inbox_pages WHERE vault_id=? ORDER BY page_index',(vault_id,)).fetchall()",
    "cache=db.execute('SELECT revision_id,envelope_json FROM encrypted_records WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchall()",
    "pending=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    'target_pages=[]',
    'for page_index,start_cursor,next_cursor,events_json in pages:',
    '    events=json.loads(events_json)',
    '    found=[]',
    '    for event in events:',
    '        if event.get("record_id")==record_id and event.get("revision_id")==revision_id:',
    '            envelope=event.get("envelope")',
    '            serialized=json.dumps(event,separators=(",",":"),ensure_ascii=False)',
    '            found.append({"commitSeq":event.get("commit_seq"),"eventType":event.get("event_type"),"envelopeSha256":canonical_digest(envelope) if isinstance(envelope,dict) else None,"plaintextMarkersAbsent":all(marker not in serialized for marker in markers)})',
    '    if found:',
    '        target_pages.append({"pageIndex":page_index,"startCursorSha256":digest(start_cursor),"nextCursorSha256":digest(next_cursor),"hasTargetNextCursor":next_cursor is not None,"events":found})',
    'cache_targets=[]',
    'for row_revision,envelope_json in cache:',
    '    if row_revision==revision_id:',
    '        serialized=envelope_json or ""',
    '        cache_targets.append({"revisionId":row_revision,"envelopeSha256":hashlib.sha256(serialized.encode()).hexdigest(),"plaintextMarkersAbsent":all(marker not in serialized for marker in markers)})',
    'out={"integrityCheck":integrity,"mainCursorSha256":digest(main[0]) if main else None,"mainGeneration":main[1] if main else None,"lockedCursorSha256":digest(locked[0]) if locked else None,"lockedGeneration":locked[1] if locked else None,"lockedNextPageIndex":locked[2] if locked else None,"lockedPageCount":len(pages),"targetInboxPages":target_pages,"cachedTargetRows":cache_targets,"activePendingOperationCount":pending}',
    'print(json.dumps(out,separators=(",",":")))',
    'db.close()',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, databasePath, vaultId,
      recordId || '', revisionId || '', ...markers], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 16384,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only B locked-sync SQLite snapshot query failed');
    const summary = JSON.parse(result.stdout);
    assertThat(summary.integrityCheck === 'ok',
      'B IndexedDB SQLite snapshot failed its integrity check');
    return summary;
  } finally {
    try { fs.unlinkSync(databasePath); } catch (_) {}
  }
}

async function lockedSyncSnapshot(page, target) {
  const raw = await readClientSqliteFiles(page);
  assertThat(raw.available === true && Array.isArray(raw.sqliteFiles),
    'B locked-sync IndexedDB database snapshot was unavailable');
  return inspectLockedSyncState(raw.sqliteFiles, target);
}

async function createHostOnA(state, { name, address, sshUsername }) {
  const pushStart = state.pushReceipts.length;
  await click(state.pageA, 'Add host');
  await fill(state.pageA, 'Display name', name);
  await fill(state.pageA, 'Hostname or IP', address);
  await fill(state.pageA, 'Port', '22');
  await fill(state.pageA, 'SSH username', sshUsername);
  const expectedPush = state.pageA.waitForResponse((response) =>
    response.request().method() === 'POST' &&
    new URL(response.url()).pathname.endsWith('/sync/push'), { timeout: 60000 })
    .then((response) => response.status());
  await click(state.pageA, 'Save encrypted host');
  const visible = await waitHostVisible(state.pageA, name, `${address}:22`);
  assertThat(visible, 'profile A did not render the newly saved Host');
  let pushStatus = await Promise.race([
    expectedPush,
    new Promise((resolve) => setTimeout(() => resolve(null), 12000)),
  ]);
  if (pushStatus === null) {
    const syncButton = state.pageA.getByRole('button', {
      name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/,
    }).first();
    await syncButton.waitFor({ state: 'visible', timeout: 15000 });
    if ((await syncButton.getAttribute('aria-label') || await syncButton.innerText()).trim() !== 'Syncing') {
      await syncButton.click();
    }
    pushStatus = await expectedPush;
  }
  assertThat(pushStatus >= 200 && pushStatus < 300, 'profile A Host push did not succeed');
  const receipt = await waitFor(() => state.pushReceipts.slice(pushStart).find((item) =>
    item.status >= 200 && item.status < 300 && item.commitSeq &&
    item.operationCount === 1 && item.recordId && item.revisionId),
  'one committed Host revision on node A');
  return receipt;
}

function exactChangeResponse(responses, target) {
  return responses.find((item) => item.status === 200 && item.vaultId === target.vaultId &&
    item.eventRevisions.some((event) => event.recordId === target.recordId &&
      event.revisionId === target.revisionId && event.commitSeq === target.commitSeq));
}

function changeRequestCount(node) {
  return API_ROUTES.filter((route) => route.method === 'GET' &&
    route.node === node && route.path.endsWith('/changes')).length;
}

function missedHintDiagnosticSnapshot(state) {
  const startAtMs = state.missedHintWindowStartAtMs;
  const droppedAtMs = state.missedHintDroppedAtMs;
  const resumeAtMs = state.lifecycleResumeAtMs;
  const target = state.missedHintTarget;
  const requests = (state.bChangeRequests || []).filter((request) =>
    startAtMs !== null && request.requestAtMs >= startAtMs).slice(-32).map((request) => {
    const response = (state.bChanges || []).find((item) =>
      item.monotonicAtMs === request.monotonicAtMs);
    const lastForwardedHint = (state.syncHintFrameDiagnosticsForB || [])
      .filter((frame) => !frame.suppressed && frame.atMs <= request.requestAtMs)
      .sort((left, right) => right.atMs - left.atMs)[0];
    const msSinceLastForwardedHint = lastForwardedHint
      ? Math.round(request.requestAtMs - lastForwardedHint.atMs) : null;
    const exactTargetEventReturned = Boolean(target && response?.eventRevisions?.some((event) =>
      event.recordId === target.recordId && event.revisionId === target.revisionId &&
      event.commitSeq === target.commitSeq));
    return {
      offsetFromWindowStartMs: Math.round(request.requestAtMs - startAtMs),
      offsetFromDroppedHintMs: droppedAtMs === null ? null :
        Math.round(request.requestAtMs - droppedAtMs),
      responseOffsetFromDroppedHintMs: droppedAtMs === null || response?.responseAtMs == null
        ? null : Math.round(response.responseAtMs - droppedAtMs),
      phase: droppedAtMs !== null && request.requestAtMs < droppedAtMs
        ? 'before-dropped-hint'
        : resumeAtMs !== null && request.requestAtMs >= resumeAtMs
          ? 'at-or-after-lifecycle-resume'
          : 'between-dropped-hint-and-resume',
      status: request.status,
      bodyProcessed: request.bodyProcessed,
      eventCount: response?.eventCount ?? null,
      exactTargetEventReturned,
      hintSuppressionActive: request.hintSuppressionActive,
      lastForwardedHintCategory: lastForwardedHint?.category ?? null,
      msSinceLastForwardedHint,
      forwardedHintWithin1500Ms: msSinceLastForwardedHint !== null &&
        msSinceLastForwardedHint <= 1500,
    };
  });
  const frames = (state.syncHintFrameDiagnosticsForB || []).filter((frame) =>
    startAtMs !== null && frame.atMs >= startAtMs).slice(-32).map((frame) => ({
    category: frame.category,
    offsetFromWindowStartMs: Math.round(frame.atMs - startAtMs),
    suppressed: frame.suppressed,
  }));
  const frameCategoryCounts = frames.reduce((counts, frame) => {
    const key = `${frame.category}:${frame.suppressed ? 'suppressed' : 'forwarded'}`;
    counts[key] = (counts[key] || 0) + 1;
    return counts;
  }, {});
  const targetScopedFrames = frames.filter((frame) =>
    ['target_commit', 'target_conflict', 'target_other_shape'].includes(frame.category));
  return {
    droppedTargetCommitHintCount: (state.droppedSyncHintsForB || []).filter((hint) =>
      target && hint.vaultId === target.vaultId && hint.commitSeq === target.commitSeq).length,
    lifecycleResumeObserved: resumeAtMs !== null,
    lifecycleResumeOffsetFromWindowStartMs: startAtMs === null || resumeAtMs === null
      ? null : Math.round(resumeAtMs - startAtMs),
    lifecycleResumeOffsetFromDroppedHintMs: droppedAtMs === null || resumeAtMs === null
      ? null : Math.round(resumeAtMs - droppedAtMs),
    bChangesRequestCountInWindow: (state.bChangeRequests || []).filter((request) =>
      startAtMs !== null && request.requestAtMs >= startAtMs).length,
    targetScopedHintFrameCount: targetScopedFrames.length,
    targetScopedHintsAllSuppressed: targetScopedFrames.length > 0 &&
      targetScopedFrames.every((frame) => frame.suppressed),
    frameCategoryCounts,
    recentBChangesRequests: requests,
    recentBHintFrames: frames,
  };
}

function assertLockedSnapshot(snapshot, target, baselineMainCursorSha256) {
  const targetPages = snapshot.targetInboxPages.filter((page) =>
    page.events.some((event) => event.commitSeq === target.commitSeq &&
      event.eventType === 'create' && event.plaintextMarkersAbsent));
  assertThat(targetPages.length === 1 &&
    targetPages[0].events.length === 1 &&
    targetPages[0].events[0].envelopeSha256 !== null &&
    targetPages[0].nextCursorSha256 === snapshot.lockedCursorSha256,
  'locked receiver did not persist exactly one opaque event with its committed cursor');
  assertThat(snapshot.cachedTargetRows.length === 0,
    'locked receiver materialized the target event into encrypted_records');
  assertThat(snapshot.mainCursorSha256 === baselineMainCursorSha256,
    'locked receiver advanced the ordinary sync cursor before unlock replay');
  assertThat(snapshot.activePendingOperationCount === 0,
    'locked receiver created a pending operation');
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web release bundle is missing');
  assertThat(BASE_URL && NODE_A_URL && NODE_B_URL && USERNAME && PASSWORD && BOOTSTRAP_TOKEN &&
    HOST_NAME && HOST_ADDRESS && SSH_USERNAME && HOST_NAME_2 && HOST_ADDRESS_2 && SSH_USERNAME_2,
    'PG Web notification acceptance environment is incomplete');
  const base = new URL(BASE_URL);
  assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' && !base.pathname.slice(1),
    'PG Web notification acceptance must use its exact loopback origin');
  const port = Number(base.port);
  assertThat(Number.isInteger(port) && port > 0, 'proxy origin must specify an explicit port');

  const state = {
    phase: 'start same-origin route proxy',
    browser: null,
    contextA: null,
    contextB: null,
    pageA: null,
    pageB: null,
    target: null,
    vaultId: null,
    pushRequests: [],
    pushReceipts: [],
    bChanges: [],
    bChangeRequests: [],
    bPushRequests: [],
    dropSyncHintsForB: false,
    droppedSyncHintsForB: [],
    syncHintFrameDiagnosticsForB: [],
    missedHintWindowStartAtMs: null,
    missedHintDroppedAtMs: null,
    lifecycleResumeAtMs: null,
    missedHintTarget: null,
    missedHintWindowSummary: null,
    lockedScenarios: [],
    manualRefreshScenario: null,
    ticketHashes: [],
    relayAndSshRequests: 0,
    cleaned: false,
  };
  let proxyStarted = false;
  try {
    await new Promise((resolve, reject) => {
      proxy.once('error', reject);
      proxy.listen(port, '127.0.0.1', resolve);
    });
    proxyStarted = true;
    const launchOptions = {
      headless: true,
      ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    const contextOptions = {
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    };
    state.browser = await chromium.launch(launchOptions);
    state.contextA = await state.browser.newContext(contextOptions);
    state.contextB = await state.browser.newContext(contextOptions);
    await Promise.all([state.contextA, state.contextB].map((context) =>
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL })));
    await Promise.all([
      installNotificationProbe(state.contextA, 'A', state),
      installNotificationProbe(state.contextB, 'B', state),
      installReaderCancelProbe(state.contextA),
      installReaderCancelProbe(state.contextB),
      installHttpRequestCorrelationProbe(state.contextA, 'A'),
      installHttpRequestCorrelationProbe(state.contextB, 'B'),
    ]);
    state.pageA = await state.contextA.newPage();
    state.pageB = await state.contextB.newPage();
    setupPageObservers(state.pageA, 'A', state);
    setupPageObservers(state.pageB, 'B', state);
    await Promise.all([
      installCdpNetworkProbe(state.pageA, 'A', state),
      installCdpNetworkProbe(state.pageB, 'B', state),
    ]);

    state.phase = 'load isolated Web contexts';
    await enterFlutter(state.pageA, 'A');
    await enterFlutter(state.pageB, 'B');
    await state.pageA.evaluate(() => localStorage.setItem('pg-sync-web-profile', 'A'));
    assertThat(await state.pageB.evaluate(() => localStorage.getItem('pg-sync-web-profile')) === null,
      'isolated Web contexts unexpectedly share local storage');

    state.phase = 'register profile A and create its first encrypted Vault';
    await connect(state.pageA);
    await field(state.pageA, 'Owner email');
    await fill(state.pageA, 'Owner email', USERNAME);
    await fill(state.pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(state.pageA, 'Confirm master password', PASSWORD);
    await fill(state.pageA, 'One-time bootstrap token', BOOTSTRAP_TOKEN);
    await fill(state.pageA, 'Device name', 'PG Web profile A');
    await fill(state.pageA, 'First Vault', 'PG Web notification Vault');
    await click(state.pageA, 'Create owner account');
    await waitWorkspace(state.pageA, 'A');

    state.phase = 'enroll independent profile B';
    await connect(state.pageB);
    await field(state.pageB, 'Email or username');
    await click(state.pageB, 'Add this device');
    await fill(state.pageB, 'Account email', USERNAME);
    await fill(state.pageB, 'Device name', 'PG Web profile B');
    await click(state.pageB, 'Generate request');
    await field(state.pageB, 'Copy this enrollment JSON');
    await click(state.pageB, 'Copy');
    const enrollmentJson = await readClipboard(state.pageB);
    assertThat(JSON.parse(enrollmentJson)?.format === 'atermius-device-enrollment-v1',
      'profile B did not create a supported enrollment request');
    await click(state.pageB, 'Close');

    state.phase = 'approve profile B device in profile A';
    await click(state.pageA, 'Devices');
    await click(state.pageA, 'Approve enrollment');
    await paste(state.pageA, 'Enrollment JSON', enrollmentJson);
    await click(state.pageA, 'Review keys');
    await click(state.pageA, 'Approve & seal keys');
    await click(state.pageA, 'Copy');
    const approvalJson = await readClipboard(state.pageA);
    assertThat(approvalJson.includes('atermius-device-approval-v1'),
      'profile A did not generate a supported device approval');
    await click(state.pageA, 'Done');
    await click(state.pageA, 'Hosts');
    await button(state.pageA, 'Add host');

    state.phase = 'import profile B device approval';
    await click(state.pageB, 'Import approval');
    await paste(state.pageB, 'Paste approval JSON', approvalJson);
    await click(state.pageB, 'Import device keys');
    await fill(state.pageB, 'Email or username', USERNAME);
    await fill(state.pageB, 'Master password', PASSWORD);
    await click(state.pageB, 'Sign in and unlock');
    await waitWorkspace(state.pageB, 'B');
    await waitFor(() => SOCKET_FRAMES.some((frame) => frame.profile === 'B' &&
      frame.direction === 'safe-summary' && frame.type === 'ready'),
    'profile B notification ready frame');
    const baselineChangesResponse = await waitFor(() => state.bChanges.find((item) =>
      item.status === 200 && item.eventCount === 0 && item.vaultId),
    'profile B empty baseline changes page');
    state.vaultId = baselineChangesResponse.vaultId;
    const baselineSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId, recordId: '', revisionId: '', markers: [],
    });
    const baselineBChanges = state.bChanges.length;

    state.phase = 'lock authenticated B and commit a Host on node A';
    const bReadyBeforeLock = SOCKET_FRAMES.filter((frame) => frame.profile === 'B' &&
      frame.direction === 'safe-summary' && frame.type === 'ready').length;
    const bChangesBeforeLock = state.bChanges.length;
    await click(state.pageB, 'Lock workspace');
    assertThat(await waitForLockedWorkspace(state.pageB),
      'profile B did not enter its locked workspace screen');
    assertThat(await waitSemanticText(state.pageB, 'Encrypted changes are up to date'),
      'locked workspace did not expose its encrypted sync status');
    await waitFor(() => SOCKET_FRAMES.filter((frame) => frame.profile === 'B' &&
      frame.direction === 'safe-summary' && frame.type === 'ready').length > bReadyBeforeLock,
    'profile B authenticated notification channel after lock');
    await waitFor(() => state.bChanges.slice(bChangesBeforeLock).some((item) =>
      item.status === 200 && item.eventCount === 0),
    'authenticated profile B pull while locked');
    const lockedBaselineSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId, recordId: '', revisionId: '', markers: [],
    });
    assertThat(lockedBaselineSnapshot.mainCursorSha256 === baselineSnapshot.mainCursorSha256,
      'locking B changed the ordinary sync checkpoint');

    const firstReceipt = await createHostOnA(state, {
      name: HOST_NAME, address: HOST_ADDRESS, sshUsername: SSH_USERNAME,
    });
    state.target = { ...firstReceipt };
    assertThat(state.target.vaultId === state.vaultId,
      'profile A committed the Host to a different Vault than B baseline-synced');
    state.phase = 'receive and persist the delivered-hint event while B is locked';
    const exactHint = await waitFor(() => SOCKET_FRAMES.find((frame) =>
      frame.profile === 'B' && frame.direction === 'safe-summary' &&
      frame.type === 'sync_required' && frame.vaultId === state.target.vaultId &&
      frame.commitSeq === state.target.commitSeq), 'matching commit metadata hint from node B');
    const matchingPushRequest = state.pushRequests.find((item) =>
      item.recordId === state.target.recordId &&
      item.revisionId === state.target.revisionId);
    assertThat(matchingPushRequest && Number.isFinite(exactHint.monotonicAtMs) &&
      Number.isFinite(matchingPushRequest.monotonicAtMs),
    'matching Host push and notification wake timestamps were not captured');
    const notificationLatencyMs = exactHint.monotonicAtMs - matchingPushRequest.monotonicAtMs;
    assertThat(notificationLatencyMs >= 0 && notificationLatencyMs <= 1500,
      `cross-node PostgreSQL wake took ${notificationLatencyMs.toFixed(1)}ms; expected at most 1500ms`);
    const firstEventResponse = await waitFor(() => exactChangeResponse(state.bChanges, state.target),
      'locked B exact event pull from node B');
    assertThat(firstEventResponse.privacyMarkersAbsent,
      'locked B changes response contained an application plaintext marker');
    const firstLockedSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId,
      recordId: state.target.recordId,
      revisionId: state.target.revisionId,
      markers: [HOST_NAME, HOST_ADDRESS, SSH_USERNAME],
    });
    assertLockedSnapshot(firstLockedSnapshot, state.target, baselineSnapshot.mainCursorSha256);
    assertThat(!(await hostVisible(state.pageB, HOST_NAME, `${HOST_ADDRESS}:22`)),
      'profile B rendered the Host while its workspace was locked');
    assertThat(await waitSemanticText(state.pageB, 'Encrypted changes are up to date', 7000),
      'locked B did not reach its encrypted-ready state after receiving the event');
    assertThat(state.bPushRequests.length === 0,
      'locked profile B attempted a sync push');

    state.phase = 'verify the locked manual receive control separately';
    const manualChangesBefore = state.bChanges.length;
    const manualRequestsBefore = changeRequestCount('B');
    const manualRefreshClickedAtMs = Date.now();
    await click(state.pageB, 'Receive encrypted changes now');
    const manualEmptyResponse = await waitFor(() => state.bChanges.slice(manualChangesBefore)
      .find((item) => item.status === 200 && item.eventCount === 0 &&
        item.requestAtMs >= manualRefreshClickedAtMs),
    'separate manual locked receive empty changes page');
    const manualRequestsAfter = changeRequestCount('B');
    const manualRequestRoutedToB = manualRequestsAfter > manualRequestsBefore &&
      API_ROUTES.some((route) => route.method === 'GET' && route.node === 'B' &&
        route.path.endsWith('/changes') && route.atMs >= manualRefreshClickedAtMs);
    assertThat(manualRequestRoutedToB,
      'locked manual receive control did not issue a B changes request');
    assertThat(manualEmptyResponse.privacyMarkersAbsent &&
      await waitSemanticText(state.pageB, 'Encrypted changes are up to date'),
    'separate locked manual receive did not complete with an encrypted-ready state');
    const firstManualRefreshSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId,
      recordId: state.target.recordId,
      revisionId: state.target.revisionId,
      markers: [HOST_NAME, HOST_ADDRESS, SSH_USERNAME],
    });
    assertLockedSnapshot(firstManualRefreshSnapshot, state.target,
      baselineSnapshot.mainCursorSha256);
    assertThat(state.bPushRequests.length === 0,
      'separate locked manual receive caused a B sync push');
    state.manualRefreshScenario = {
      controlClicked: true,
      requestRoutedToB: manualRequestRoutedToB,
      emptyPageReturned: manualEmptyResponse.eventCount === 0,
      durableInboxRetained: firstManualRefreshSnapshot.targetInboxPages.length === 1,
      noMaterialization: firstManualRefreshSnapshot.cachedTargetRows.length === 0,
      mainCursorUnchanged:
        firstManualRefreshSnapshot.mainCursorSha256 === baselineSnapshot.mainCursorSha256,
      noPush: state.bPushRequests.length === 0,
    };

    state.phase = 'unlock B and replay its durable locked inbox page';
    await fill(state.pageB, 'Account password', PASSWORD);
    state.phase = 'activate B locked workspace unlock control';
    state.unlockStartAtMs = Date.now();
    await clickUnlockWorkspace(state.pageB);
    state.phase = 'wait for B to decrypt and render the replayed Host';
    const decryptedOnB = await waitForUnlockedHost(state.pageB, HOST_NAME,
      `${HOST_ADDRESS}:22`, state, state.unlockStartAtMs);
    assertThat(decryptedOnB, 'profile B did not render the Host after unlocking');
    const firstUnlockedSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId,
      recordId: state.target.recordId,
      revisionId: state.target.revisionId,
      markers: [HOST_NAME, HOST_ADDRESS, SSH_USERNAME],
    });
    assertThat(firstUnlockedSnapshot.cachedTargetRows.length === 1 &&
      firstUnlockedSnapshot.cachedTargetRows[0].plaintextMarkersAbsent &&
      firstUnlockedSnapshot.targetInboxPages.length === 0 &&
      firstUnlockedSnapshot.mainCursorSha256 === firstLockedSnapshot.lockedCursorSha256,
    'unlock did not atomically replay the durable inbox and advance its checkpoint');
    assertThat(state.bPushRequests.length === 0,
      'profile B created an operation while replaying a locked inbox page');
    state.lockedScenarios.push({
      vaultId: state.vaultId,
      recordId: state.target.recordId,
      revisionId: state.target.revisionId,
      commitSeq: state.target.commitSeq,
      baselineSync: true,
      authenticatedWhileLocked: true,
      deliveredHintObserved: true,
      lockedInboxDurable: firstLockedSnapshot.targetInboxPages.length === 1,
      lockedEventNotMaterialized: firstLockedSnapshot.cachedTargetRows.length === 0,
      lockedMainCursorUnchanged:
        firstLockedSnapshot.mainCursorSha256 === baselineSnapshot.mainCursorSha256,
      plaintextMarkersAbsent: firstLockedSnapshot.targetInboxPages[0].events[0].plaintextMarkersAbsent,
      noLockedPush: state.bPushRequests.length === 0,
      unlockReplayVisible: decryptedOnB,
      replayCheckpointAdvanced:
        firstUnlockedSnapshot.mainCursorSha256 === firstLockedSnapshot.lockedCursorSha256,
      inboxConsumedAfterReplay: firstUnlockedSnapshot.targetInboxPages.length === 0,
    });

    state.phase = 'lock B again and baseline its second locked receiver';
    const secondBaselineSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId, recordId: '', revisionId: '', markers: [],
    });
    const bReadyBeforeRelock = SOCKET_FRAMES.filter((frame) => frame.profile === 'B' &&
      frame.direction === 'safe-summary' && frame.type === 'ready').length;
    const bChangesBeforeRelock = state.bChanges.length;
    await click(state.pageB, 'Lock workspace');
    assertThat(await waitForLockedWorkspace(state.pageB),
      'profile B did not return to its locked workspace screen');
    await waitFor(() => SOCKET_FRAMES.filter((frame) => frame.profile === 'B' &&
      frame.direction === 'safe-summary' && frame.type === 'ready').length > bReadyBeforeRelock,
    'profile B notification channel after its second lock');
    await waitFor(() => state.bChanges.slice(bChangesBeforeRelock).some((item) =>
      item.status === 200 && item.eventCount === 0),
    'second locked receiver baseline pull');
    const secondLockedBaseline = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId, recordId: '', revisionId: '', markers: [],
    });
    assertThat(secondLockedBaseline.mainCursorSha256 === secondBaselineSnapshot.mainCursorSha256,
      'second lock changed the ordinary sync checkpoint');

    state.phase = 'set locked B inactive before suppressing its target Vault hint';
    await state.pageB.evaluate(() => {
      window.__pgSyncWindowLifecycleTransitions = [];
      for (const type of ['blur', 'focus']) {
        window.addEventListener(type, () => {
          window.__pgSyncWindowLifecycleTransitions.push({ type, atMs: Date.now() });
        });
      }
    });
    // Chromium's headless mode keeps every tab visible in this CI container.
    // Dispatch the same window lifecycle events consumed by Flutter's Web
    // lifecycle adapter so this bounded test exercises onForegroundResumed.
    await state.pageB.evaluate(() => window.dispatchEvent(new Event('blur')));
    const inactiveTransition = await state.pageB.evaluate(() =>
      window.__pgSyncWindowLifecycleTransitions?.findLast((item) => item.type === 'blur') || null);
    assertThat(inactiveTransition,
      'locked B did not enter the instrumented inactive window-lifecycle state');
    await waitFor(() => state.bChangeRequests.every((request) =>
      request.status !== null && request.bodyProcessed),
    'in-flight B changes requests to settle before the missed-hint commit', 5000);

    state.phase = 'suppress every target-Vault B hint and commit a second Host on node A';
    state.dropSyncHintsForB = true;
    state.missedHintWindowStartAtMs = Date.now();
    const bChangesBeforeMissedHintCommit = state.bChanges.length;
    const bChangeRequestsBeforeMissedHintCommit = state.bChangeRequests.length;
    const secondReceipt = await createHostOnA(state, {
      name: HOST_NAME_2, address: HOST_ADDRESS_2, sshUsername: SSH_USERNAME_2,
    });
    const secondTarget = { ...secondReceipt };
    state.missedHintTarget = secondTarget;
    assertThat(secondTarget.vaultId === state.vaultId,
      'second profile A Host was committed to a different Vault');
    const droppedHint = await waitFor(() => state.droppedSyncHintsForB.find((frame) =>
      frame.vaultId === secondTarget.vaultId && frame.commitSeq === secondTarget.commitSeq),
    'deliberately dropped matching B sync hint');
    state.missedHintDroppedAtMs = droppedHint.atMs;
    const targetScopedHintsDuringWindow = state.syncHintFrameDiagnosticsForB.filter((frame) =>
      frame.atMs >= state.missedHintWindowStartAtMs &&
      ['target_commit', 'target_conflict', 'target_other_shape'].includes(frame.category));
    const targetScopedHintsAllSuppressed = targetScopedHintsDuringWindow.length > 0 &&
      targetScopedHintsDuringWindow.every((frame) => frame.suppressed);
    assertThat(targetScopedHintsAllSuppressed,
      'a target-Vault sync hint escaped suppression during the missed-hint window');
    const bChangesRequestsBeforeResume = state.bChangeRequests.length;
    assertThat(!(await hostVisible(state.pageB, HOST_NAME_2, `${HOST_ADDRESS_2}:22`)),
      'profile B rendered the second Host before the missed-hint recovery trigger');
    assertThat(state.bPushRequests.length === 0,
      'locked profile B attempted a sync push before the missed-hint recovery trigger');
    state.phase = 'resume locked B with its Web window focus lifecycle event';
    await state.pageB.evaluate(() => window.dispatchEvent(new Event('focus')));
    const lifecycleTransitions = await state.pageB.evaluate(() =>
      window.__pgSyncWindowLifecycleTransitions || []);
    const resumeTransition = lifecycleTransitions.find((item) =>
      item.type === 'focus' && item.atMs >= inactiveTransition.atMs) || null;
    const resumedLifecycle = Boolean(resumeTransition);
    state.lifecycleResumeAtMs = resumeTransition?.atMs ?? null;
    assertThat(!(await hostVisible(state.pageB, HOST_NAME_2, `${HOST_ADDRESS_2}:22`)),
      'profile B rendered the second Host while still locked before missed-hint recovery');
    assertThat(state.bPushRequests.length === 0,
      'locked profile B attempted a sync push before the foreground recovery trigger');
    const requestAfterDroppedHintBeforeResume = state.bChangeRequests.some((request) =>
      request.vaultId === secondTarget.vaultId && request.requestAtMs >= droppedHint.atMs &&
      resumeTransition && request.requestAtMs < resumeTransition.atMs);
    const exactTargetResponseBeforeResume = exactChangeResponse(state.bChanges.filter((item) =>
      item.vaultId === secondTarget.vaultId && resumeTransition &&
      item.requestAtMs < resumeTransition.atMs), secondTarget);
    const noBChangesRequestBeforeLifecycleResume = !requestAfterDroppedHintBeforeResume &&
      !exactTargetResponseBeforeResume;
    state.missedHintWindowSummary = missedHintDiagnosticSnapshot(state);
    state.safeValidationSummary = {
      manualLockedRefresh: state.manualRefreshScenario,
      droppedHintObserved: Boolean(droppedHint),
      bChangeRequestsExistingAtWindowStart: bChangeRequestsBeforeMissedHintCommit,
      bChangesExistingAtWindowStart: bChangesBeforeMissedHintCommit,
      bChangeRequestsBeforeLifecycleResume: state.bChangeRequests.length -
        bChangesRequestsBeforeResume,
      requestAfterDroppedHintBeforeResume,
      exactTargetResponseBeforeResume: Boolean(exactTargetResponseBeforeResume),
      noBChangesRequestUntilLifecycleResume: resumedLifecycle &&
        noBChangesRequestBeforeLifecycleResume,
      targetScopedHintsAllSuppressed,
      targetScopedHintFrameCount: targetScopedHintsDuringWindow.length,
      missedHintWindow: state.missedHintWindowSummary,
      lifecycleTransitions: lifecycleTransitions.map((item) => ({
        type: item.type,
        offsetFromInactiveMs: Math.round(item.atMs - inactiveTransition.atMs),
      })),
    };
    assertThat(resumedLifecycle,
      'locked B did not receive the resumed window-lifecycle event');
    const noBChangesRequestUntilLifecycleResume =
      state.safeValidationSummary.noBChangesRequestUntilLifecycleResume;
    assertThat(noBChangesRequestUntilLifecycleResume,
      'profile B issued a /changes request after the dropped hint but before the lifecycle resume event');
    await waitFor(() => state.bChangeRequests.some((request) =>
      request.vaultId === secondTarget.vaultId &&
      request.requestAtMs >= resumeTransition.atMs),
    'automatic B changes request after the Web lifecycle resume event');
    const secondEventResponse = await waitFor(() => exactChangeResponse(
      state.bChanges.filter((item) => item.vaultId === secondTarget.vaultId &&
        item.requestAtMs >= resumeTransition.atMs), secondTarget),
    'automatic B exact event pull after the Web lifecycle resume event');
    const changeRequestAfterResume = state.bChangeRequests.some((request) =>
      request.vaultId === secondTarget.vaultId &&
      request.requestAtMs >= resumeTransition.atMs);
    state.missedHintWindowSummary = missedHintDiagnosticSnapshot(state);
    state.safeValidationSummary.missedHintWindow = state.missedHintWindowSummary;
    assertThat(changeRequestAfterResume,
      'Web lifecycle resume did not cause a subsequent automatic B changes request');
    state.dropSyncHintsForB = false;
    assertThat(secondEventResponse && secondEventResponse.privacyMarkersAbsent,
      'missed-hint recovery response was missing or exposed an application plaintext marker');
    assertThat(await waitSemanticText(state.pageB, 'Encrypted changes are up to date'),
      'missed-hint locked receiver did not return to its encrypted-ready state');
    assertThat(!(await hostVisible(state.pageB, HOST_NAME_2, `${HOST_ADDRESS_2}:22`)),
      'profile B rendered the second Host while still locked after missed-hint recovery');
    const secondLockedSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId,
      recordId: secondTarget.recordId,
      revisionId: secondTarget.revisionId,
      markers: [HOST_NAME_2, HOST_ADDRESS_2, SSH_USERNAME_2],
    });
    assertLockedSnapshot(secondLockedSnapshot, secondTarget,
      secondBaselineSnapshot.mainCursorSha256);
    assertThat(state.bPushRequests.length === 0,
      'locked profile B attempted a sync push after missed-hint recovery');

    state.phase = 'unlock B and replay the missed-hint inbox event';
    await fill(state.pageB, 'Account password', PASSWORD);
    state.phase = 'activate B locked workspace unlock control after resume';
    state.unlockStartAtMs = Date.now();
    await clickUnlockWorkspace(state.pageB);
    state.phase = 'wait for B to decrypt and render the foreground-recovered Host';
    const secondDecryptedOnB = await waitForUnlockedHost(state.pageB, HOST_NAME_2,
      `${HOST_ADDRESS_2}:22`, state, state.unlockStartAtMs);
    assertThat(secondDecryptedOnB,
      'profile B did not render the second Host after unlocking');
    const secondUnlockedSnapshot = await lockedSyncSnapshot(state.pageB, {
      vaultId: state.vaultId,
      recordId: secondTarget.recordId,
      revisionId: secondTarget.revisionId,
      markers: [HOST_NAME_2, HOST_ADDRESS_2, SSH_USERNAME_2],
    });
    assertThat(secondUnlockedSnapshot.cachedTargetRows.length === 1 &&
      secondUnlockedSnapshot.cachedTargetRows[0].plaintextMarkersAbsent &&
      secondUnlockedSnapshot.targetInboxPages.length === 0 &&
      secondUnlockedSnapshot.mainCursorSha256 === secondLockedSnapshot.lockedCursorSha256,
    'unlock did not replay the missed-hint inbox event and advance the ordinary checkpoint');
    assertThat(state.bPushRequests.length === 0,
      'profile B created an operation while replaying the missed-hint page');
    state.lockedScenarios.push({
      vaultId: state.vaultId,
      recordId: secondTarget.recordId,
      revisionId: secondTarget.revisionId,
      commitSeq: secondTarget.commitSeq,
      baselineSync: true,
      authenticatedWhileLocked: true,
      droppedHintObserved: Boolean(droppedHint),
      noPullBeforeLifecycleResume: noBChangesRequestUntilLifecycleResume &&
        noBChangesRequestBeforeLifecycleResume,
      lifecycleResumeObserved: resumedLifecycle,
      changeRequestAfterResume,
      recoveredByLifecycleResume: resumedLifecycle && changeRequestAfterResume &&
        Boolean(secondEventResponse),
      recoveredByExplicitRefresh: false,
      lockedInboxDurable: secondLockedSnapshot.targetInboxPages.length === 1,
      lockedEventNotMaterialized: secondLockedSnapshot.cachedTargetRows.length === 0,
      lockedMainCursorUnchanged:
        secondLockedSnapshot.mainCursorSha256 === secondBaselineSnapshot.mainCursorSha256,
      plaintextMarkersAbsent: secondLockedSnapshot.targetInboxPages[0].events[0].plaintextMarkersAbsent,
      noLockedPush: state.bPushRequests.length === 0,
      unlockReplayVisible: secondDecryptedOnB,
      replayCheckpointAdvanced:
        secondUnlockedSnapshot.mainCursorSha256 === secondLockedSnapshot.lockedCursorSha256,
      inboxConsumedAfterReplay: secondUnlockedSnapshot.targetInboxPages.length === 0,
    });

    state.phase = 'validate exact routing, secret boundaries, and browser health';
    await waitFor(() => SOCKET_FRAMES.some((frame) => frame.profile === 'A' &&
      frame.direction === 'url'), 'profile A WebSocket route');
    const apiRouteMatrixValid = API_ROUTES.filter((route) => route.path.startsWith('/api/v1/'))
      .every((route) => route.node === routeFor(route.method, route.path, false));
    const ticketRoutes = API_ROUTES.filter((route) =>
      route.method === 'POST' && route.path === '/api/v1/notifications/tickets');
    const pushRoutes = API_ROUTES.filter((route) =>
      route.method === 'POST' && /\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(route.path));
    const changeRoutes = API_ROUTES.filter((route) =>
      route.method === 'GET' && /\/changes$/i.test(route.path));
    const socketRoutes = SOCKET_ROUTES.filter((route) =>
      route.path === '/api/v1/notifications' && route.node === 'B');
    const clientSocketUrls = SOCKET_FRAMES.filter((frame) => frame.direction === 'url');
    let stableTicketCounts = null;
    let matchingTicketsStableSince = null;
    await waitFor(() => {
      const currentAuthFrames = SOCKET_FRAMES.filter((frame) =>
        frame.direction === 'sent' && frame.type === 'authenticate');
      const matching = currentAuthFrames.length > 0 && currentAuthFrames.every((frame) =>
        state.ticketHashes.some((ticket) => ticket.profile === frame.profile &&
          ticket.status === 200 && ticket.hash === frame.ticketFingerprint));
      if (!matching) {
        stableTicketCounts = null;
        matchingTicketsStableSince = null;
        return false;
      }
      const counts = `${currentAuthFrames.length}:${state.ticketHashes.length}`;
      if (counts !== stableTicketCounts) {
        stableTicketCounts = counts;
        matchingTicketsStableSince = Date.now();
        return false;
      }
      return matchingTicketsStableSince !== null &&
        Date.now() - matchingTicketsStableSince >= 300;
    }, 'authenticated notification frames to match parsed one-use HTTP ticket responses', 5000);
    const authFrames = SOCKET_FRAMES.filter((frame) =>
      frame.direction === 'sent' && frame.type === 'authenticate');
    const authFrameDiagnostics = authFrames.map((frame) => ({
      profile: frame.profile,
      validShape: frame.validAuthFrame,
      sensitiveValuesAbsent: frame.sensitiveValuesAbsent,
      ticketResponseMatched: state.ticketHashes.some((ticket) =>
        ticket.profile === frame.profile && ticket.status === 200 &&
        ticket.hash === frame.ticketFingerprint),
    }));
    const serverFrames = SOCKET_FRAMES.filter((frame) =>
      frame.direction === 'received');
    const exactRevisionInChanges = (item) => item.status === 200 &&
      item.vaultId === state.target.vaultId &&
      item.eventRevisions.some((event) => event.recordId === state.target.recordId &&
        event.revisionId === state.target.revisionId &&
        event.commitSeq === state.target.commitSeq);
    const lockedScenariosComplete = state.lockedScenarios.length === 2 &&
      state.lockedScenarios.every((scenario) => scenario.baselineSync &&
        scenario.authenticatedWhileLocked && scenario.lockedInboxDurable &&
        scenario.lockedEventNotMaterialized && scenario.lockedMainCursorUnchanged &&
        scenario.plaintextMarkersAbsent && scenario.noLockedPush &&
        scenario.unlockReplayVisible && scenario.replayCheckpointAdvanced &&
        scenario.inboxConsumedAfterReplay) &&
      state.lockedScenarios[0].deliveredHintObserved &&
      state.lockedScenarios[1].droppedHintObserved &&
      state.lockedScenarios[1].noPullBeforeLifecycleResume &&
      state.lockedScenarios[1].lifecycleResumeObserved &&
      state.lockedScenarios[1].changeRequestAfterResume &&
      state.lockedScenarios[1].recoveredByLifecycleResume &&
      !state.lockedScenarios[1].recoveredByExplicitRefresh;
    const urlSafe = clientSocketUrls.length > 0 && clientSocketUrls.every((frame) =>
      frame.path === '/api/v1/notifications' && !frame.hasQuery &&
      !frame.hasFragment && !frame.hasCredential);
    const authSafe = authFrames.length > 0 && authFrames.every((frame) =>
      frame.validAuthFrame && frame.sensitiveValuesAbsent &&
      state.ticketHashes.some((ticket) => ticket.profile === frame.profile &&
        ticket.status === 200 && ticket.hash === frame.ticketFingerprint));
    const serverFramesSafe = serverFrames.some((frame) => frame.type === 'ready') &&
      serverFrames.some((frame) => frame.type === 'sync_required') &&
      serverFrames.every((frame) => frame.metadataOnly && frame.sensitiveValuesAbsent);
    const secretSafe = SOCKET_FRAMES.filter((frame) => frame.direction !== 'safe-summary')
      .every((frame) => frame.sensitiveValuesAbsent !== false);
    const forbiddenPathRequests = API_ROUTES.filter((route) =>
      /\/api\/v1\/(?:relay|.*ssh|.*terminal-sessions)/i.test(route.path));
    const allContextsDistinct = state.contextA !== state.contextB &&
      await state.pageA.evaluate(() => localStorage.getItem('pg-sync-web-profile') === 'A') &&
      await state.pageB.evaluate(() => localStorage.getItem('pg-sync-web-profile') === null);
    await Promise.all(state.requestFailureDiagnosticTasks || []);
    const bodyCancellationProbes = Object.fromEntries(await Promise.all([
      ['A', state.pageA], ['B', state.pageB],
    ].map(async ([profile, page]) => [profile, await page.evaluate(() => ({
      readerCancelTotal: globalThis.__atermiusReaderCancelEventsTotal || 0,
      abortTotal: globalThis.__atermiusAbortEventsTotal || 0,
      readerReadErrorTotal: globalThis.__atermiusReaderReadErrorEventsTotal || 0,
      requestBodyReaderEventTotal: globalThis.__atermiusRequestBodyReaderEventTotal || 0,
      requestBodyReaderObservedIds: Array.isArray(
        globalThis.__atermiusRequestBodyReaderObservedIds)
        ? globalThis.__atermiusRequestBodyReaderObservedIds.slice(-256) : [],
      requestBodyReaderEvents: Array.isArray(
        globalThis.__atermiusRequestBodyReaderEvents)
        ? globalThis.__atermiusRequestBodyReaderEvents.slice(-512) : [],
      readerCancelEvents: Array.isArray(globalThis.__atermiusReaderCancelEvents)
        ? globalThis.__atermiusReaderCancelEvents.slice(-512) : [],
      abortEvents: Array.isArray(globalThis.__atermiusAbortEvents)
        ? globalThis.__atermiusAbortEvents.slice(-512) : [],
      readerReadErrorEvents: Array.isArray(globalThis.__atermiusReaderReadErrorEvents)
        ? globalThis.__atermiusReaderReadErrorEvents.slice(-512) : [],
    }))])));
    const requestBodyReaderProbeSummary = Object.fromEntries(['A', 'B'].map((profile) => {
      const probe = bodyCancellationProbes[profile];
      const events = probe.requestBodyReaderEvents;
      const count = (type) => events.filter((event) => event.type === type).length;
      return [profile, {
        totalEventCount: probe.requestBodyReaderEventTotal,
        retainedEventCount: events.length,
        responseBodyCount: count('response_body'),
        readerAttachedCount: count('reader_attached'),
        readerCancelCallCount: count('reader_cancel'),
        readerCancelSettledCount: count('reader_cancel_done') +
          count('reader_cancel_error'),
        readerReadDoneCount: count('reader_read_done'),
        readerReadErrorCount: count('reader_read_error'),
        observedCorrelationIds: probe.requestBodyReaderObservedIds,
      }];
    }));
    const failedRequestCancelCorrelations = BROWSER_ERRORS.failedRequestDiagnostics
      .filter((diagnostic) => diagnostic.requestAtMs != null &&
        diagnostic.failedAtMs != null)
      .map((diagnostic) => ({
        method: diagnostic.method,
        route: diagnostic.route,
        profile: diagnostic.profile,
        correlationId: diagnostic.correlationId,
        failureCode: diagnostic.failureCode,
        bodyCompleteTrace: (diagnostic.httpBodyTrace || [])
          .filter((event) => event.stage === 'body_complete')
          .map((event) => ({ request: event.request, status: event.status,
            bodyBytes: event.bodyBytes })),
        readerLifecycleEvents: diagnostic.readerLifecycleEvents || [],
        cdpTerminal: diagnostic.cdpNetwork ? {
          loadingFinishedAtMs: diagnostic.cdpNetwork.loadingFinishedAtMs,
          loadingFailedAtMs: diagnostic.cdpNetwork.loadingFailedAtMs,
          loadingFailedReason: diagnostic.cdpNetwork.loadingFailedReason,
          canceled: diagnostic.cdpNetwork.canceled,
        } : null,
        abortOffsetsFromRequestMs: bodyCancellationProbes[diagnostic.profile].abortEvents
          .filter((event) => event.wallAtMs >= diagnostic.requestAtMs - 50 &&
            event.wallAtMs <= diagnostic.failedAtMs + 100)
          .map((event) => event.wallAtMs - diagnostic.requestAtMs)
          .slice(-4),
        readerReadErrorsNearFailure: bodyCancellationProbes[diagnostic.profile]
          .readerReadErrorEvents
          .filter((event) => event.wallAtMs >= diagnostic.requestAtMs - 50 &&
            event.wallAtMs <= diagnostic.failedAtMs + 100)
          .map((event) => ({
            offsetMs: event.wallAtMs - diagnostic.requestAtMs,
            errorName: event.errorName,
          }))
          .slice(-4),
      }));
    const noBrowserErrors = BROWSER_ERRORS.page === 0 && BROWSER_ERRORS.console === 0 &&
      BROWSER_ERRORS.failedRequests === 0;
    state.safeValidationSummary = {
      allContextsDistinct,
      apiRouteMatrixValid,
      ticketsRoutedToNodeA: ticketRoutes.length >= 2 && ticketRoutes.every((route) =>
        route.node === 'A' && route.status === 200),
      hostPushRoutedToNodeA: state.pushRequests.length === 2 &&
        pushRoutes.filter((route) => route.node === 'A' &&
          route.status >= 200 && route.status < 300).length >= 2,
      changesRoutedToNodeB: changeRoutes.some((route) => route.node === 'B' &&
        route.status === 200),
      socketsRoutedToNodeB: socketRoutes.length >= 2 && socketRoutes.every((route) =>
        route.status === 101 && !route.hasQuery),
      urlSafe,
      authSafe,
      authFrameDiagnostics,
      serverFramesSafe,
      secretSafe,
      noForbiddenPathRequests: forbiddenPathRequests.length === 0 &&
        state.relayAndSshRequests === 0,
      noBrowserErrors,
      decryptedOnB,
      lockedScenariosComplete,
      bPushRequests: state.bPushRequests.length,
      droppedSyncHintsForB: state.droppedSyncHintsForB.length,
      missedHintWindow: state.missedHintWindowSummary,
      pageErrorCount: BROWSER_ERRORS.page,
      consoleErrorCount: BROWSER_ERRORS.console,
      failedRequestCount: BROWSER_ERRORS.failedRequests,
      failedRequestDiagnostics: BROWSER_ERRORS.failedRequestDiagnostics.slice(0, 8),
      aReaderCancelEventCount: bodyCancellationProbes.A.readerCancelTotal,
      bReaderCancelEventCount: bodyCancellationProbes.B.readerCancelTotal,
      aAbortEventCount: bodyCancellationProbes.A.abortTotal,
      bAbortEventCount: bodyCancellationProbes.B.abortTotal,
      aReaderReadErrorEventCount: bodyCancellationProbes.A.readerReadErrorTotal,
      bReaderReadErrorEventCount: bodyCancellationProbes.B.readerReadErrorTotal,
      failedRequestCancelCorrelations,
      requestBodyReaderProbe: requestBodyReaderProbeSummary,
      mainFrameNavigationCount: state.mainFrameNavigations?.length || 0,
      pageClosedBeforeValidation: state.pageCloseAtMs != null,
      pageClosePhase: state.pageClosePhase || null,
    };
    console.log(`assert: safe_validation_summary=${JSON.stringify(state.safeValidationSummary)}`);

    assertThat(allContextsDistinct, 'Chromium profiles shared browser storage');
    assertThat(apiRouteMatrixValid, 'same-origin proxy route matrix was violated');
    assertThat(ticketRoutes.length >= 2 && ticketRoutes.every((route) =>
      route.node === 'A' && route.status === 200), 'notification tickets did not route to node A');
    assertThat(state.pushRequests.length === 2 && pushRoutes.filter((route) =>
      route.node === 'A' && route.status >= 200 && route.status < 300).length >= 2,
    'both encrypted Host pushes did not route to node A');
    assertThat(changeRoutes.some((route) => route.node === 'B' && route.status === 200),
      'authorized changes reads did not route to node B');
    assertThat(socketRoutes.length >= 2 && socketRoutes.every((route) =>
      route.status === 101 && !route.hasQuery), 'notification WebSockets did not route to node B');
    assertThat(urlSafe && authSafe && serverFramesSafe && secretSafe,
      'notification URL or frames violated the ticket/metadata-only protocol');
    assertThat(forbiddenPathRequests.length === 0 && state.relayAndSshRequests === 0,
      'browser acceptance unexpectedly used Relay or SSH routes');
    assertThat(noBrowserErrors, 'Chromium observed a page, console, or request error');
    assertThat(decryptedOnB, 'profile B did not render the decrypted Host from the exact revision');
    assertThat(lockedScenariosComplete,
      'authenticated locked receive, durable inbox, no-push, unlock replay, or missed-hint recovery evidence was incomplete');
    assertThat(state.bPushRequests.length === 0,
      'profile B issued a sync push during locked receive or unlock replay');

    const cleanup = async () => {
      const contextCloseResults = await Promise.allSettled(
        [state.contextA, state.contextB].filter(Boolean).map((context) => context.close()),
      );
      const browserCloseResult = state.browser
        ? await state.browser.close().then(() => true, () => false)
        : true;
      for (const socket of proxy._upgradeSockets) socket.destroy();
      if (proxyStarted) {
        await new Promise((resolve) => proxy.close(resolve));
        proxyStarted = false;
      }
      state.cleaned = contextCloseResults.every((result) => result.status === 'fulfilled') &&
        browserCloseResult && !state.browser?.isConnected() && !proxy.listening;
      assertThat(state.cleaned,
        'Chromium browser process or Node proxy server did not clean up');
    };
    await cleanup();

    const result = {
      twoIndependentContexts: allContextsDistinct,
      ticketRequestsRoutedToA: ticketRoutes.length >= 2 && ticketRoutes.every((route) => route.node === 'A' && route.status === 200),
      notificationWebSocketRoutedToB: socketRoutes.length >= 2 && socketRoutes.every((route) => route.node === 'B' && route.status === 101),
      hostPushRoutedToA: pushRoutes.some((route) => route.node === 'A' && route.status >= 200 && route.status < 300),
      encryptedHostPushContainsNoApplicationSecret: state.pushRequests.length === 2 &&
        state.pushRequests.every((item) => item.operationCount === 1 && item.privacyMarkersAbsent),
      commitWakeWithin1500ms: notificationLatencyMs <= 1500,
      hintTriggeredChangesRoutedToB: changeRoutes.some((route) => route.node === 'B' && route.status === 200 && route.atMs >= exactHint.atMs),
      metadataHintMatchedCommittedRevision: Boolean(exactHint),
      exactRevisionReturnedByChanges: state.bChanges.slice(baselineBChanges).some(exactRevisionInChanges),
      profileBDecryptedHostVisible: decryptedOnB,
      lockedSyncScenarios: state.lockedScenarios,
      lockedSessionAuthenticated: state.lockedScenarios.every((scenario) => scenario.authenticatedWhileLocked),
      lockedInboxOpaqueAndDurable: state.lockedScenarios.every((scenario) => scenario.lockedInboxDurable && scenario.plaintextMarkersAbsent),
      lockedMainCursorHeldUntilReplay: state.lockedScenarios.every((scenario) => scenario.lockedMainCursorUnchanged && scenario.replayCheckpointAdvanced),
      noBPushWhileLockedOrReplaying: state.bPushRequests.length === 0,
      manualLockedRefreshObserved: Boolean(state.manualRefreshScenario &&
        state.manualRefreshScenario.controlClicked &&
        state.manualRefreshScenario.requestRoutedToB &&
        state.manualRefreshScenario.emptyPageReturned &&
        state.manualRefreshScenario.durableInboxRetained &&
        state.manualRefreshScenario.noMaterialization &&
        state.manualRefreshScenario.mainCursorUnchanged &&
        state.manualRefreshScenario.noPush),
      droppedHintObserved: state.lockedScenarios[1].droppedHintObserved,
      droppedHintRecovered: state.lockedScenarios[1].unlockReplayVisible,
      droppedHintRecoveredByLifecycleResume: state.lockedScenarios[1].recoveredByLifecycleResume,
      droppedHintRecoveredByExplicitRefresh: state.lockedScenarios[1].recoveredByExplicitRefresh,
      notificationUrlContainsNoTicketOrQuery: urlSafe,
      authFrameContainsOnlyOneUseTicket: authSafe,
      serverFramesMetadataOnly: serverFramesSafe,
      webSocketContainsNoApplicationSecret: secretSafe,
      relayAndSshRequests: state.relayAndSshRequests + forbiddenPathRequests.length,
      pageErrors: BROWSER_ERRORS.page,
      consoleErrors: BROWSER_ERRORS.console,
      failedRequests: BROWSER_ERRORS.failedRequests,
      browserCleanupComplete: state.cleaned,
      vaultId: state.target.vaultId,
      recordId: state.target.recordId,
      revisionId: state.target.revisionId,
      commitSeq: state.target.commitSeq,
      notificationLatencyMs: Number(notificationLatencyMs.toFixed(1)),
      manualRefreshScenario: state.manualRefreshScenario,
      missedHintWindow: state.missedHintWindowSummary,
      ticketRequestCount: ticketRoutes.length,
      webSocketCount: socketRoutes.length,
      changesRequestCount: changeRoutes.length,
      exactRevisionChangesResponseCount: state.bChanges.filter(exactRevisionInChanges).length,
      bSyncPushRequestCount: state.bPushRequests.length,
      droppedSyncHintCount: state.droppedSyncHintsForB.length,
      aReaderCancelEventCount: bodyCancellationProbes.A.readerCancelTotal,
      bReaderCancelEventCount: bodyCancellationProbes.B.readerCancelTotal,
      aAbortEventCount: bodyCancellationProbes.A.abortTotal,
      bAbortEventCount: bodyCancellationProbes.B.abortTotal,
      aReaderReadErrorEventCount: bodyCancellationProbes.A.readerReadErrorTotal,
      bReaderReadErrorEventCount: bodyCancellationProbes.B.readerReadErrorTotal,
      requestBodyReaderProbe: requestBodyReaderProbeSummary,
    };
    console.log(`PG_SYNC_WS_RESULT:${JSON.stringify(result)}`);
    console.log('assert: pg_web_release_notification_cross_node_sync=true');
  } catch (error) {
    console.error(`stage: failed (${state.phase}); error type=${error?.name || 'unknown'}`);
    if (error instanceof SafeAcceptanceAssertionError ||
        error instanceof SafeAcceptanceWaitError) {
      console.error(`safe reason: ${redactRunnerMessage(error.message)}`);
    }
    if (error instanceof SafeAcceptanceWaitError) {
      console.error('safe failure kind: expectation timeout');
    }
    const safeChangeRequests = API_ROUTES.filter((route) =>
      route.method === 'GET' && route.node === 'B' && route.path.endsWith('/changes'));
    const safeUnlockRequests = API_ROUTES.filter((route) =>
      route.atMs >= (state.unlockStartAtMs || Number.MAX_SAFE_INTEGER) &&
      route.path.startsWith('/api/v1/')).map((route) => ({ method: route.method,
        node: route.node,
        path: route.path.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}/ig, '/:id'),
        status: route.status })).slice(-16);
    const safeProfileUnlockRequests = (state.profileApiRequests || []).filter((route) =>
      route.profile === 'B' && route.atMs >=
        (state.unlockStartAtMs || Number.MAX_SAFE_INTEGER)).slice(-16);
    const safeMissedHintDiagnostics = missedHintDiagnosticSnapshot(state);
    const safeLockedStatus = state.pageB ? await state.pageB.evaluate(() => {
      const labels = [
        'Receiving signed encrypted changes',
        'Encrypted changes are up to date',
        'No Vault is currently available',
        'Unlock to verify the latest Vault state',
        'Account session expired; sign in again',
        'This device or Vault access was revoked',
        'Encrypted sync will retry when the connection returns',
      ];
      const text = [...document.querySelectorAll('flt-semantics')]
        .map((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
          node.parentElement?.innerText || ''].join(' ')).join('\n');
      const body = document.body?.innerText || '';
      const combined = `${text}\n${body}`;
      const lockedScreenVisible = combined.includes('Workspace locked') ||
        (combined.includes('Unlock workspace') &&
          combined.includes('Receive encrypted changes now'));
      const workspaceVisible = combined.includes('Add host');
      return {
        screenState: lockedScreenVisible ? 'locked' :
          workspaceVisible ? 'workspace' : 'transitioning_or_unknown',
        status: labels.find((label) => text.includes(label) || body.includes(label)) ||
          ['locked_receiving', 'locked_ready', 'retry_wait', 'auth_required',
            'unlock_required', 'revoked', 'idle', 'syncing']
            .find((label) => text.includes(label) || body.includes(label)) || 'unknown',
        semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
        lockedScreenVisible,
        workspaceVisible,
        unlockControlVisible: combined.includes('Unlock workspace'),
        receiveControlVisible: combined.includes('Receive encrypted changes now'),
        safeErrorVisible: ['password', 'failed', 'error', '密钥', '密码', '错误']
          .some((marker) => combined.toLowerCase().includes(marker.toLowerCase())),
      };
    }).catch(() => ({ status: 'unavailable' })) : { status: 'page-unavailable' };
    if (state.pageB) {
      await state.pageB.screenshot({ path: '/home/atermius_locked_sync_failure.png' })
        .catch(() => {});
    }
    console.error(`safe receive progress: ${JSON.stringify({
      lockedStatus: safeLockedStatus,
      bChangesRequests: safeChangeRequests.length,
      bChangeStatuses: safeChangeRequests.slice(-16).map((route) => route.status),
      bChangeResponses: state.bChanges.slice(-12).map((item) => ({
        status: item.status,
        eventCount: item.eventCount,
        privacyMarkersAbsent: item.privacyMarkersAbsent,
      })),
      bNotificationFrames: SOCKET_FRAMES.filter((frame) => frame.profile === 'B').length,
      bPushRequests: state.bPushRequests.length,
      unlockRequests: safeUnlockRequests,
      profileBUnlockRequests: safeProfileUnlockRequests,
      profileBDevicesUnlockResponses: safeProfileUnlockRequests.filter((route) =>
        route.method === 'GET' && route.path === '/api/v1/devices').map((route) => ({
        status: route.status,
        errorCode: /^[A-Z0-9_]{2,64}$/.test(route.errorCode || '')
          ? route.errorCode : null,
      })),
      droppedSyncHints: state.droppedSyncHintsForB.length,
      missedHintDiagnostics: safeMissedHintDiagnostics,
      failedRequestDiagnostics: BROWSER_ERRORS.failedRequestDiagnostics.slice(0, 8),
      httpBodyDiagnosticCount: (state.httpBodyDiagnostics || []).length,
      failedRequestCount: BROWSER_ERRORS.failedRequests,
      pageErrorCount: BROWSER_ERRORS.page,
      consoleErrorCount: BROWSER_ERRORS.console,
      mainFrameNavigationCount: state.mainFrameNavigations?.length || 0,
      pageClosedBeforeFailure: state.pageCloseAtMs != null,
    })}`);
    if (state.safeValidationSummary) {
      console.error(`assert: safe_validation_summary=${JSON.stringify(state.safeValidationSummary)}`);
    }
    throw error;
  } finally {
    if (!state.cleaned) {
      const contextCloseResults = await Promise.allSettled(
        [state.contextA, state.contextB].filter(Boolean).map((context) => context.close()),
      );
      const browserCloseResult = state.browser
        ? await state.browser.close().then(() => true, () => false)
        : true;
      for (const socket of proxy._upgradeSockets) socket.destroy();
      if (proxyStarted) await new Promise((resolve) => proxy.close(resolve));
      state.cleaned = contextCloseResults.every((result) => result.status === 'fulfilled') &&
        browserCloseResult && !state.browser?.isConnected() && !proxy.listening;
      if (!state.cleaned) {
        console.error('stage: temporary browser/proxy cleanup did not complete');
        process.exitCode = 1;
      }
    }
  }
}

main().catch((error) => {
  console.error(`PG Web notification acceptance failed safely (${error?.name || 'Error'})`);
  process.exitCode = 1;
});
