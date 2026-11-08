/*
 * PG-AUTO-PURGE-WEB-01: exercise per-tombstone owner consent and bounded
 * PostgreSQL Maintenance from two isolated Web devices. Pytest gates the
 * restore-deadline transition so the UI first records consent against future
 * deadlines, then only the selected opted-in tombstone becomes due.
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const crypto = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_AUTO_PURGE_BASE_URL;
const NODE_A_URL = process.env.ATERMIUS_PG_AUTO_PURGE_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_AUTO_PURGE_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_AUTO_PURGE_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_AUTO_PURGE_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_AUTO_PURGE_BOOTSTRAP_TOKEN;
const CONTROL_DIR = process.env.ATERMIUS_PG_AUTO_PURGE_CONTROL_DIR;
const RUN_ID = process.env.ATERMIUS_PG_AUTO_PURGE_RUN_ID;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const HOST_MARKERS = {
  eligible: `PG purge eligible ${RUN_ID.slice(0, 8)}`,
  future: `PG purge future ${RUN_ID.slice(0, 8)}`,
  disabled: `PG purge disabled ${RUN_ID.slice(0, 8)}`,
};
const HOST_ADDRESS = '192.0.2.65';
const SSH_USERNAME = `pg-purge-${RUN_ID.slice(0, 8)}`;
const PRIVACY_MARKERS = [USERNAME, PASSWORD, BOOTSTRAP_TOKEN, SSH_USERNAME,
  HOST_ADDRESS, ...Object.values(HOST_MARKERS)];
const API_EVENTS = [];
const PROXY_SOCKETS = new Set();
let stripRedactionMarkersProfile = null;
const BROWSER_ERRORS = {
  page: 0,
  apiRequestFailure: 0,
  expectedPresenceAbort: 0,
  pageErrorDetails: [],
  apiRequestFailureDetails: [],
};

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  console.log(`stage: ${value}`);
}

function safeErrorMessage(error) {
  let message = String(error?.message || error || 'unknown failure');
  for (const marker of [...PRIVACY_MARKERS].sort((left, right) => right.length - left.length)) {
    if (marker) message = message.split(marker).join('[redacted]');
  }
  return message.slice(0, 1200);
}

function safeEqualKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function verifyRedactionProof(proof) {
  try {
    if (!proof || typeof proof !== 'object' || typeof proof.signature !== 'string' ||
        typeof proof.signing_public_key !== 'string') return false;
    const { signature, ...unsigned } = proof;
    const publicKeyBytes = Buffer.from(proof.signing_public_key, 'base64url');
    const signatureBytes = Buffer.from(signature, 'base64url');
    if (publicKeyBytes.length !== 32 || signatureBytes.length !== 64) return false;
    const publicKey = crypto.createPublicKey({
      key: Buffer.concat([
        Buffer.from('302a300506032b6570032100', 'hex'),
        publicKeyBytes,
      ]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(null, Buffer.from(canonicalJson(unsigned), 'utf8'), publicKey,
      signatureBytes);
  } catch (_) {
    return false;
  }
}

function markerFree(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? null);
  return !PRIVACY_MARKERS.some((marker) => marker && serialized.includes(marker));
}

function upstreamFor(value) {
  const url = new URL(value || '');
  assertThat(url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
    Number(url.port) > 0, 'PG auto-purge requires loopback node URLs');
  return { hostname: url.hostname, port: Number(url.port) };
}

const upstreamA = upstreamFor(NODE_A_URL);
const upstreamB = upstreamFor(NODE_B_URL);

function profileFrom(headers) {
  return headers['x-pg-acceptance-profile'] === 'B' ? 'B' : 'A';
}

function isApiPath(pathname) {
  return pathname.startsWith('/api/v1/');
}

function jsonOrNull(buffer) {
  if (!buffer?.length) return null;
  try { return JSON.parse(buffer.toString('utf8')); } catch (_) { return null; }
}

function proxyTarget(profile) {
  return profile === 'B' ? upstreamB : upstreamA;
}

function makeProxy() {
  const server = http.createServer((request, response) => {
    let url;
    try { url = new URL(request.url || '/', BASE_URL); } catch (_) {
      response.writeHead(400);
      response.end();
      return;
    }
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'no-store' });
      response.end();
      return;
    }
    const profile = profileFrom(request.headers);
    const target = proxyTarget(profile);
    const api = isApiPath(url.pathname);
    const event = api ? {
      method: request.method || 'GET',
      path: url.pathname,
      profile,
      node: profile === 'B' ? 'B' : 'A',
      atMs: Date.now(),
      status: null,
      requestBody: null,
      responseBody: null,
      requestMarkerFree: true,
      responseMarkerFree: true,
      redactionMarkerPresent: request.headers['x-atermius-redaction-marker'] === 'v1',
      redactionMarkerStripped: false,
    } : null;
    if (event) API_EVENTS.push(event);

    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    delete headers['x-pg-acceptance-profile'];
    if (profile === stripRedactionMarkersProfile &&
        headers['x-atermius-redaction-marker'] === 'v1') {
      delete headers['x-atermius-redaction-marker'];
      if (event) event.redactionMarkerStripped = true;
    }
    const upstreamRequest = http.request({
      hostname: target.hostname,
      port: target.port,
      method: request.method,
      path: `${url.pathname}${url.search}`,
      headers,
    }, (upstreamResponse) => {
      if (!event) {
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        upstreamResponse.pipe(response);
        return;
      }
      const chunks = [];
      upstreamResponse.on('data', (chunk) => chunks.push(chunk));
      upstreamResponse.on('end', () => {
        const body = Buffer.concat(chunks);
        event.status = upstreamResponse.statusCode || null;
        event.responseAtMs = Date.now();
        event.responseBody = jsonOrNull(body);
        event.responseMarkerFree = markerFree(body.toString('utf8'));
        response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
        response.end(body);
      });
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });

    if (!event) {
      request.pipe(upstreamRequest);
      return;
    }
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const body = Buffer.concat(chunks);
      event.requestBody = jsonOrNull(body);
      event.requestMarkerFree = markerFree(body.toString('utf8'));
      upstreamRequest.end(body);
    });
  });

  server.on('upgrade', (request, clientSocket, clientHead) => {
    let url;
    try { url = new URL(request.url || '/', BASE_URL); } catch (_) {
      clientSocket.destroy();
      return;
    }
    const profile = profileFrom(request.headers);
    const target = proxyTarget(profile);
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
      PROXY_SOCKETS.add(clientSocket);
      PROXY_SOCKETS.add(upstreamSocket);
      clientSocket.on('close', () => PROXY_SOCKETS.delete(clientSocket));
      upstreamSocket.on('close', () => PROXY_SOCKETS.delete(upstreamSocket));
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      clientSocket.write(`HTTP/1.1 ${upstreamResponse.statusCode || 502} ${upstreamResponse.statusMessage || 'Bad Gateway'}\r\n\r\n`);
      upstreamResponse.pipe(clientSocket);
    });
    upstreamRequest.on('error', () => clientSocket.destroy());
    upstreamRequest.end();
  });
  return server;
}

const proxy = makeProxy();

async function waitFor(predicate, description, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  await locator.scrollIntoViewIfNeeded();
  return locator;
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.pressSequentially(value, { delay: 15 });
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `Web field did not retain ${label}`);
  await locator.press('Tab');
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 25000 });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  const matches = (actual) => actual === value || (() => {
    try { return isDeepStrictEqual(JSON.parse(actual), JSON.parse(value)); } catch (_) { return false; }
  })();
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(300);
    if (matches(await locator.inputValue())) {
      await locator.press('Tab');
      await page.waitForTimeout(80);
      if (matches(await locator.inputValue())) return;
    }
  }
  await locator.fill(value);
  await page.waitForTimeout(100);
  if (matches(await locator.inputValue())) {
    await locator.press('Tab');
    await page.waitForTimeout(80);
    if (matches(await locator.inputValue())) return;
  }
  const actual = await locator.inputValue();
  assertThat(matches(actual), `enrollment text did not paste into Web field (expected length ${value.length}, actual length ${actual.length})`);
}

async function enterFlutter(page) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web crypto module');
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics tree');
  await click(page, 'Connect securely');
}

async function enableFlutterSemanticsAfterReload(page) {
  await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'),
    'Web crypto module after reload');
  await page.evaluate(async () => { await window.sodium.ready; });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 30000 });
  await placeholder.evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics tree after reload');
}

async function connect(page) {
  await fill(page, 'Server URL', BASE_URL);
  await click(page, 'Connect securely');
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function recoverWorkspaceAfterReload(page) {
  const addHost = page.getByRole('button', { name: 'Add host', exact: true });
  await selectServerModeIfChooser(page, addHost);
  const serverUrl = page.locator('input[aria-label*="Server URL"],textarea[aria-label*="Server URL"]').first();
  const email = page.locator('input[aria-label*="Email or username"],textarea[aria-label*="Email or username"]').first();
  const masterPassword = page.locator('input[aria-label*="Master password"],textarea[aria-label*="Master password"]').first();
  const hostsNavigation = page.getByRole('button', { name: 'Hosts', exact: true }).first();
  const visible = (locator) => locator.isVisible().catch(() => false);
  const connectButton = page.getByRole('button', { name: 'Connect securely', exact: true });
  let state = 'unknown';
  const observeState = async () => {
    if (await visible(addHost)) return 'workspace';
    if (await visible(email)) return 'login';
    if (await visible(masterPassword)) return 'unlock';
    if (await visible(serverUrl) && await visible(connectButton)) return 'server';
    return 'unknown';
  };
  let hostsNavigationClicked = false;
  await waitFor(async () => {
    state = await observeState();
    if (state === 'unknown' && !hostsNavigationClicked && await visible(hostsNavigation)) {
      hostsNavigationClicked = true;
      await hostsNavigation.click();
    }
    return state !== 'unknown';
  }, 'recognized workspace state after reload', 45000);

  if (state === 'workspace') return;
  if (state === 'server') {
    for (let attempt = 0; attempt < 2 && state === 'server'; attempt += 1) {
      try {
        await fill(page, 'Server URL', BASE_URL);
        await click(page, 'Connect securely');
      } catch (_) {
        // The workspace-mode chooser can replace its form during Flutter's
        // first frame after a document reload. Re-observe the route below.
      }
      try {
        await waitFor(async () => {
          const observed = await observeState();
          if (observed !== 'unknown') state = observed;
          return state !== 'server' && state !== 'unknown';
        }, 'server connection or sign-in screen after reload', 30000);
      } catch (_) {
        state = await observeState();
      }
    }
  }

  if (state === 'login') {
    await fill(page, 'Email or username', USERNAME);
    await fill(page, 'Master password', PASSWORD);
    await click(page, 'Sign in and unlock');
  } else if (state === 'unlock') {
    await fill(page, 'Master password', PASSWORD);
    const unlock = page.getByRole('button', { name: 'Unlock', exact: true });
    if (await visible(unlock)) await unlock.click();
    else await click(page, 'Sign in and unlock');
  }

  try {
    await waitWorkspace(page);
  } catch (_) {
    const diagnostic = await page.evaluate(() => {
      const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      };
      const text = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
        .join(' ');
      const fields = [...document.querySelectorAll('input,textarea')].filter(visible)
        .map((element) => element.getAttribute('aria-label') || '');
      return {
        addHost: text.includes('Add host'),
        hostsNavigation: text.includes('Hosts'),
        serverUrl: fields.some((label) => label.includes('Server URL')),
        account: fields.some((label) => label.includes('Email or username')),
        masterPassword: fields.some((label) => label.includes('Master password')),
        continue: text.includes('Continue'),
        chooser: text.includes('Choose a workspace'),
        authenticationError: /incorrect|invalid|failed|temporarily|too many|unable to sign/i.test(text),
      };
    }).catch(() => ({ documentUnavailable: true }));
    const authTrace = API_EVENTS.filter((event) => /auth|login|session/i.test(event.path))
      .slice(-8).map((event) => ({
        method: event.method,
        path: event.path.split('/').slice(3).join('/'),
        status: event.status,
        errorCode: event.responseBody?.error?.code || event.responseBody?.code || null,
      }));
    throw new Error(`workspace did not recover after reload; recognizedState=${state}; diagnostic=${JSON.stringify(diagnostic)}; authTrace=${JSON.stringify(authTrace)}`);
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hostCard(page, name) {
  return page.getByRole('group', { name: new RegExp(`^Host: ${escapeRegExp(name)};`) }).first();
}

async function waitHost(page, name, expected, description = 'Host row') {
  await waitFor(async () => {
    const card = hostCard(page, name);
    const visible = await card.count().catch(() => 0) > 0 &&
      await card.isVisible().catch(() => false);
    return visible === expected;
  }, `${description} ${expected ? 'visible' : 'removed'}`, 45000);
}

function successfulPushes(profile, operation, recordId = null) {
  return API_EVENTS.filter((event) => event.method === 'POST' &&
    /\/sync\/push$/i.test(event.path) && event.profile === profile && event.status === 200 &&
    Array.isArray(event.requestBody?.operations) &&
    event.requestBody.operations.some((item) => {
      const header = item?.header || {};
      return header.operation === operation && (!recordId || header.record_id === recordId);
    }));
}

function refsFromEvent(event) {
  const operations = event.requestBody?.operations || [];
  const results = event.responseBody?.results || [];
  return operations.map((item, index) => {
    const header = item?.header || {};
    const result = results.find((candidate) => candidate?.op_id === header.op_id) || results[index] || {};
    return {
      recordId: header.record_id || null,
      revisionId: header.revision_id || null,
      operationId: header.op_id || null,
      baseRevisionId: header.base_revision_id || null,
      deviceId: header.device_id || null,
      operation: header.operation || null,
      commitSeq: result.commit_seq || null,
    };
  });
}

async function addHost(page, name) {
  const pushStart = API_EVENTS.length;
  await click(page, 'Add host');
  await fill(page, 'Display name', name);
  await fill(page, 'Hostname or IP', HOST_ADDRESS);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', SSH_USERNAME);
  await click(page, 'Save encrypted host');
  await waitHost(page, name, true, 'owner local Host after save');
  await waitFor(() => successfulPushes('A', 'create').some((event) =>
    API_EVENTS.indexOf(event) >= pushStart &&
    refsFromEvent(event).some((ref) => ref.operation === 'create' && ref.recordId)),
  'signed Host create receipt');
  const event = successfulPushes('A', 'create').find((item) =>
    API_EVENTS.indexOf(item) >= pushStart &&
    refsFromEvent(item).some((ref) => ref.operation === 'create' && ref.recordId));
  const ref = event && refsFromEvent(event).find((item) => item.operation === 'create');
  assertThat(event && ref?.recordId && ref.revisionId && ref.operationId && event.requestBody.vault_id,
    'owner Host create did not produce an exact signed receipt');
  return {
    ...ref,
    createRevisionId: ref.revisionId,
    createSeq: ref.commitSeq,
    vaultId: event.requestBody.vault_id,
  };
}

async function deleteHost(page, name) {
  const card = hostCard(page, name);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  const moreActions = card.getByRole('button', { name: 'More actions', exact: true });
  await moreActions.click();
  const deleteItem = page.getByRole('menuitem', { name: 'Delete', exact: true });
  const alertDialog = page.getByRole('alertdialog').filter({ hasText: 'Delete this item?' }).first();
  const dialog = page.getByRole('dialog').filter({ hasText: 'Delete this item?' }).first();
  let opened = false;
  for (let attempt = 0; attempt < 2 && !opened; attempt += 1) {
    if (attempt > 0) {
      await moreActions.click();
      await page.waitForTimeout(120);
    }
    await deleteItem.waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(120);
    if (attempt === 0) {
      await deleteItem.click();
    } else {
      await deleteItem.focus();
      await page.keyboard.press('Enter');
    }
    try {
      await waitFor(async () =>
        await alertDialog.isVisible().catch(() => false) ||
        await dialog.isVisible().catch(() => false),
      'Host deletion confirmation dialog', 6000);
      opened = true;
    } catch (_) {}
  }
  if (!opened) {
    const titleVisible = await page.getByText('Delete this item?', { exact: true })
      .isVisible().catch(() => false);
    throw new Error(`Host deletion confirmation did not appear; hostStillVisible=${await card.isVisible().catch(() => false)}; deleteMenuVisible=${await deleteItem.isVisible().catch(() => false)}; deleteTitleVisible=${titleVisible}; alertDialogCount=${await alertDialog.count().catch(() => 0)}; dialogCount=${await dialog.count().catch(() => 0)}`);
  }
  const confirmation = await alertDialog.isVisible().catch(() => false) ? alertDialog : dialog;
  await confirmation.getByRole('button', { name: 'Delete', exact: true }).click();
  await waitHost(page, name, false, 'owner local Host after delete');
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) return false;
      const values = [element.textContent || '', ...[...element.attributes].map((item) => item.value)];
      return values.some((value) => value.includes(expected));
    });
  }, needle);
}

async function recycleSemanticText(page) {
  const dialog = page.getByRole('alertdialog').filter({ hasText: 'Recycle bin' }).first();
  const [label, text] = await Promise.all([
    dialog.getAttribute('aria-label').catch(() => ''),
    dialog.innerText(),
  ]);
  return `${label || ''}\n${text}`;
}

function recycleRow(page, record, consent, deadline = null) {
  const status = consent ? 'Enabled' : 'Off';
  const deadlinePart = deadline === null
    ? '(?:Future|Passed(?: according to this device clock; the server makes the final decision)?)'
    : deadline === 'Passed'
      ? 'Passed(?: according to this device clock; the server makes the final decision)?'
      : 'Future(?:, .*)?';
  const name = new RegExp(`^Recycle bin record: ${escapeRegExp(record.displayName)}, ID ` +
    `${record.recordId.slice(0, 8)}, Automatic purge consent: ${status}, ` +
    `Restore deadline status: ${deadlinePart}`);
  return page.getByRole('group', { name });
}

async function openRecycleBin(page) {
  await click(page, 'Recycle bin');
  await page.getByRole('alertdialog').filter({ hasText: 'Recycle bin' }).waitFor({ state: 'visible' });
}

async function closeRecycleBin(page) {
  const dialog = page.getByRole('alertdialog').filter({ hasText: 'Recycle bin' }).first();
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
}

async function assertRecycleBinState(page, records, expectedEnabled, expectedOff,
  expectedVisibleKeys, expectedHiddenKeys = [], requireFutureDeadlines = true) {
  const consentedKeys = expectedEnabled === 0 ? [] : ['eligible', 'future'];
  const enabledKeys = expectedVisibleKeys.filter((key) =>
    consentedKeys.includes(key) && !expectedHiddenKeys.includes(key));
  const enabledRecordIds = new Set(enabledKeys.map((key) => records[key].recordId));
  try {
    await waitFor(async () => {
      const expectedRows = expectedVisibleKeys.map((key) => {
        const record = { ...records[key], displayName: HOST_MARKERS[key] };
        const enabled = enabledRecordIds.has(record.recordId);
        const deadline = requireFutureDeadlines || key === 'future' ? 'Future' : 'Passed';
        return recycleRow(page, record, enabled, deadline);
      });
      const visible = await Promise.all(expectedRows.map(async (row) =>
        await row.count().catch(() => 0) === 1 && await row.isVisible().catch(() => false)));
      if (!visible.every(Boolean)) return false;
      const hidden = await Promise.all(expectedHiddenKeys.map(async (key) => {
        const row = recycleRow(page, { ...records[key], displayName: HOST_MARKERS[key] }, false);
        return await row.count().catch(() => 0) === 0;
      }));
      if (!hidden.every(Boolean)) return false;
      const allRows = page.getByRole('group', { name: /^Recycle bin record:/ });
      return await allRows.count() === expectedVisibleKeys.length;
    }, 'Recycle Bin snapshot to load the expected tombstones', 60000);
  } catch (_) {
    const dialogText = await recycleSemanticText(page).catch(() => '');
    const snapshotTrace = API_EVENTS.filter((event) => event.profile === 'A' &&
      /\/(snapshots?|revisions)(?:\/|$)/i.test(event.path)).slice(-8).map((event) => ({
      method: event.method,
      endpoint: event.path.split('/').slice(-1)[0].split('?')[0],
      status: event.status,
      markerFree: event.requestMarkerFree && event.responseMarkerFree,
      errorCode: event.responseBody?.error?.code || event.responseBody?.code || null,
      responseKeys: event.responseBody && typeof event.responseBody === 'object'
        ? Object.keys(event.responseBody).sort() : [],
      itemCount: Number.isInteger(event.responseBody?.item_count) ? event.responseBody.item_count : null,
      entryCount: Array.isArray(event.responseBody?.entries) ? event.responseBody.entries.length : null,
      manifestCount: Array.isArray(event.responseBody?.manifest) ? event.responseBody.manifest.length : null,
      manifestTombstoneCount: Array.isArray(event.responseBody?.manifest)
        ? event.responseBody.manifest.filter((item) => item?.deleted === true).length : null,
    }));
    throw new Error(`Recycle Bin snapshot did not expose expected tombstones; dialog=${dialogText.slice(0, 600)}; api=${JSON.stringify(snapshotTrace)}`);
  }
  for (const key of expectedVisibleKeys) {
    const record = { ...records[key], displayName: HOST_MARKERS[key] };
    const deadline = requireFutureDeadlines || key === 'future' ? 'Future' : 'Passed';
    const row = recycleRow(page, record, enabledRecordIds.has(record.recordId),
      deadline);
    const expectedControl = enabledRecordIds.has(record.recordId)
      ? 'Withdraw consent' : 'Allow future purge';
    assertThat(await row.getByRole('button', { name: expectedControl, exact: true }).count() === 1 &&
      await row.getByRole('button', { name: 'Restore', exact: true }).count() === 1,
    `Recycle Bin row actions were missing for ${key}`);
    const manualPurgeCount = await row.getByRole('button', {
      name: 'Permanently purge', exact: true,
    }).count();
    assertThat(manualPurgeCount === (deadline === 'Passed' ? 1 : 0),
      `Recycle Bin exposed the wrong manual-purge availability for ${key}`);
  }
  assertThat(enabledKeys.length === expectedEnabled &&
    expectedVisibleKeys.length - enabledKeys.length === expectedOff,
  'Recycle Bin displayed the wrong persisted consent-state counts');
  if (requireFutureDeadlines) {
    const purgeButtons = await Promise.all(expectedVisibleKeys.map((key) =>
      recycleRow(page, { ...records[key], displayName: HOST_MARKERS[key] },
        enabledRecordIds.has(records[key].recordId), 'Future')
        .getByRole('button', { name: 'Permanently purge', exact: true }).count()));
    assertThat(purgeButtons.every((count) => count === 0),
      'Recycle Bin must show future restore deadlines with no manual purge action before aging');
  }
}

async function consentForExactTombstone(page, recordId, displayName) {
  const requestStart = API_EVENTS.length;
  const targetRow = recycleRow(page, { recordId, displayName }, false, 'Future');
  await targetRow.waitFor({ state: 'visible', timeout: 20000 });
  await targetRow.getByRole('button', { name: 'Allow future purge', exact: true }).click();
  const dialog = page.getByRole('alertdialog').filter({ hasText: 'Allow future automatic purge?' }).first();
  await dialog.waitFor({ state: 'visible', timeout: 20000 });
  assertThat((await dialog.innerText()).includes(displayName),
    'Recycle Bin consent dialog did not identify the exact selected tombstone');
  const checkbox = dialog.getByRole('checkbox');
  await checkbox.focus();
  await page.keyboard.press('Space');
  await waitFor(async () => (await checkbox.getAttribute('aria-checked')) === 'true',
    'owner acknowledgement checkbox to become selected');
  await dialog.locator('input[aria-label*="Type ENABLE AUTOMATIC PURGE"]').fill('ENABLE AUTOMATIC PURGE');
  await dialog.getByRole('button', { name: 'Record consent', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  await waitFor(() => API_EVENTS.slice(requestStart).some((event) =>
    event.profile === 'A' && event.method === 'PUT' &&
    event.path.endsWith(`/records/${recordId}/automatic-purge`) &&
    Number.isInteger(event.status)),
  'the completed exact tombstone consent response');
  const event = API_EVENTS.slice(requestStart).filter((candidate) =>
    candidate.profile === 'A' && candidate.method === 'PUT' &&
    candidate.path.endsWith(`/records/${recordId}/automatic-purge`) &&
    Number.isInteger(candidate.status)).at(-1);
  const requestChecks = {
    observed: Boolean(event),
    status: event?.status,
    errorCode: event?.responseBody?.error?.code || event?.responseBody?.code || null,
    policyRevisionIsZero: event?.requestBody?.expected_policy_revision === '0',
    enabled: event?.requestBody?.enabled === true,
    requestMarkerFree: event?.requestMarkerFree,
    responseMarkerFree: event?.responseMarkerFree,
  };
  assertThat(event?.status === 200 && event.requestBody?.expected_policy_revision === '0' &&
    event.requestBody?.enabled === true && event.requestMarkerFree && event.responseMarkerFree,
  `the exact tombstone consent request did not complete with the expected safe state; checks=${JSON.stringify(requestChecks)}`);
  await waitFor(() => recycleRow(page,
    { recordId, displayName }, true, 'Future').count().then((value) => value === 1),
  'the exact tombstone consent state to refresh');
}

async function waitForApiEvent(predicate, description, timeoutMs = 30000) {
  await waitFor(() => API_EVENTS.some(predicate), description, timeoutMs);
  return API_EVENTS.find(predicate);
}

async function waitForGateFile(name, timeoutMs = 180000) {
  const filePath = path.join(CONTROL_DIR, `release_${name}`);
  await waitFor(() => fs.existsSync(filePath), `pytest release gate ${name}`, timeoutMs);
  fs.unlinkSync(filePath);
}

function publishGate(name, value) {
  const filePath = path.join(CONTROL_DIR, `${name}.json`);
  const temporary = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(temporary, filePath);
}

async function readinessStatusCounts(page) {
  const rows = page.getByRole('group', { name: /^Vault device / });
  const labels = await rows.evaluateAll((elements) => elements.map((element) =>
    element.getAttribute('aria-label') || element.innerText || element.textContent || ''));
  const statusLabels = [
    'Ready',
    'Report expired or invalidated',
    'Report not received',
    'Report could not be verified',
    'Client version unsupported',
  ];
  if (labels.length === 0) {
    const snapshot = await page.locator('body').ariaSnapshot().catch(() => '');
    const rowStatuses = [...snapshot.matchAll(
      /Vault device [^,\n]+, (Ready|Report expired or invalidated|Report not received|Report could not be verified|Client version unsupported)/g,
    )].map((match) => match[1]);
    if (rowStatuses.length > 0) {
      return statusLabels.map((status) =>
        rowStatuses.filter((rowStatus) => rowStatus === status).length);
    }
    labels.push(...snapshot.split('\n').filter((line) => line.includes('Vault device ')));
  }
  return statusLabels.map((status) =>
    labels.filter((label) => label.includes(`, ${status}`)).length);
}

function capabilityEvents(profile) {
  return API_EVENTS.filter((event) => event.profile === profile && event.method === 'PUT' &&
    event.path === '/api/v1/devices/redaction-capabilities' && event.status === 200);
}

async function waitForReadiness(page, expected, description, apiEventStart = 0, profile = 'A') {
  const refresh = page.getByRole('button', { name: 'Refresh readiness', exact: true });
  try {
    // Flutter Web exposes this action consistently through semantics, while
    // the adjacent heading is rendered visually but is not always available
    // to Playwright's exact-text locator.
    await refresh.waitFor({ state: 'visible', timeout: 60000 });
  } catch (error) {
    await page.screenshot({
      path: path.join(CONTROL_DIR, 'readiness-panel-not-visible.png'),
      fullPage: true,
    }).catch(() => {});
    const labels = [
      'Trusted devices', 'Account devices', 'Devices', 'Vault setup', 'Hosts',
      'Redaction readiness', 'Add host', 'No Vault', 'Choose vault',
    ];
    const visibleLabels = {};
    for (const label of labels) {
      visibleLabels[label] = await page.getByText(label, { exact: true }).count();
    }
    const rosterReads = API_EVENTS.slice(apiEventStart).filter((event) => event.profile === profile &&
      event.method === 'GET' && /\/api\/v1\/vaults\/[^/]+\/devices$/.test(event.path))
      .map((event) => ({
        status: event.status,
        node: event.node,
        deviceCount: Array.isArray(event.responseBody?.devices)
          ? event.responseBody.devices.length : null,
        devices: (event.responseBody?.devices || []).map((device) => ({
          status: device.status,
          membershipStatus: device.membership_status,
          hasRedactionReport: device.redaction_capability_report != null,
          reportRevision: device.redaction_capability_report?.revision ?? null,
          reportInvalidated: Boolean(device.redaction_capability_report?.invalidated_at),
        })),
      })).slice(-8);
    const runtime = await page.evaluate(() => ({
      buildId: window.atermiusWebBuildId || null,
      serviceWorkerController: navigator.serviceWorker?.controller?.scriptURL || null,
    })).catch(() => ({ unavailable: true }));
    throw new Error(`${error.message}; readiness_page_diagnostic=${JSON.stringify({
      visibleLabels,
      refreshButtonCount: await refresh.count(),
      runtime,
      ownerVaultRosterReads: rosterReads,
    })}`);
  }
  const refreshRequestStart = API_EVENTS.length;
  await refresh.click();
  const refreshRosterRead = await waitForApiEvent((event) =>
    API_EVENTS.indexOf(event) >= refreshRequestStart && event.profile === profile &&
    event.method === 'GET' && /\/api\/v1\/vaults\/[^/]+\/devices$/.test(event.path) &&
    event.status === 200,
  'explicit readiness refresh to complete its Vault roster GET');
  try {
    await waitFor(async () => {
      const counts = await readinessStatusCounts(page);
      return JSON.stringify(counts) === JSON.stringify(expected);
    }, description, 60000);
  } catch (error) {
    await page.screenshot({
      path: path.join(CONTROL_DIR, 'readiness-result-mismatch.png'),
      fullPage: true,
    }).catch(() => {});
    const rosterReads = API_EVENTS.slice(apiEventStart).filter((event) => event.profile === profile &&
      event.method === 'GET' && /\/api\/v1\/vaults\/[^/]+\/devices$/.test(event.path))
      .map((event) => ({
        status: event.status,
        node: event.node,
        devices: (event.responseBody?.devices || []).map((device) => ({
          status: device.status,
          membershipStatus: device.membership_status,
          hasRedactionReport: device.redaction_capability_report != null,
          reportRevision: device.redaction_capability_report?.revision ?? null,
          reportInvalidated: Boolean(device.redaction_capability_report?.invalidated_at),
        })),
      })).slice(-8);
    const readinessCounts = await readinessStatusCounts(page);
    const accessibilitySnapshot = await page.locator('body').ariaSnapshot()
      .catch(() => '');
    const readinessAccessibilityRows = accessibilitySnapshot.split('\n')
      .filter((line) => line.includes('Vault device ')).slice(0, 8);
    throw new Error(`${error.message}; readiness_result_diagnostic=${JSON.stringify({
      expected,
      readinessCounts,
      readinessAccessibilityRows,
      explicitRefreshRoster: {
        status: refreshRosterRead.status,
        deviceCount: Array.isArray(refreshRosterRead.responseBody?.devices)
          ? refreshRosterRead.responseBody.devices.length : null,
        devices: (refreshRosterRead.responseBody?.devices || []).map((device) => ({
          status: device.status,
          membershipStatus: device.membership_status,
          hasRedactionReport: device.redaction_capability_report != null,
          reportRevision: device.redaction_capability_report?.revision ?? null,
          reportInvalidated: Boolean(device.redaction_capability_report?.invalidated_at),
        })),
      },
      ownerVaultRosterReads: rosterReads,
    })}`);
  }
}

async function submitMaintenanceFromSettings(page, sequence) {
  if (!await hasVisibleSemanticText(page, 'Instance jobs')) {
    await click(page, 'Settings');
  }
  await waitFor(() => hasVisibleSemanticText(page, 'Instance jobs'), 'Settings maintenance panel');
  const loadButton = page.getByRole('button', { name: 'Load instance jobs', exact: true });
  if (await loadButton.count() > 0 && await loadButton.first().isVisible()) await loadButton.first().click();
  const before = API_EVENTS.length;
  await click(page, 'Run maintenance now');
  const post = await waitForApiEvent((event) => event.profile === 'A' &&
    API_EVENTS.indexOf(event) >= before && event.method === 'POST' &&
    event.path === '/api/v1/admin/jobs' && Number.isInteger(event.status),
  'Settings maintenance POST');
  const contractChecks = {
    acceptedStatus: post.status === 202,
    exactRequestKeys: safeEqualKeys(post.requestBody, ['request_id', 'action']),
    maintenanceAction: post.requestBody?.action === 'maintenance',
    requestIdFormat: /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(post.requestBody?.request_id || ''),
    exactResponseKeys: safeEqualKeys(post.responseBody, ['job']),
    responseAction: post.responseBody?.job?.action === 'maintenance',
    requestIdMatches: post.responseBody?.job?.request_id === post.requestBody?.request_id,
  };
  assertThat(Object.values(contractChecks).every(Boolean),
    `Settings did not submit the exact accepted Maintenance job contract; checks=${JSON.stringify(contractChecks)}`);
  const accepted = post.responseBody.job;
  assertThat(typeof accepted.job_id === 'string' &&
    ['queued', 'running', 'succeeded'].includes(accepted.status),
  'Settings Maintenance response omitted the durable accepted job');

  let latest = null;
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const getEvent = [...API_EVENTS].reverse().find((event) =>
      event.profile === 'A' && event.method === 'GET' && event.path === '/api/v1/admin/jobs' &&
      event.responseBody?.jobs?.some((job) => job.job_id === accepted.job_id));
    latest = getEvent?.responseBody?.jobs?.find((job) => job.job_id === accepted.job_id) || latest;
    if (latest && ['succeeded', 'failed', 'interrupted'].includes(latest.status)) break;
    const refresh = page.getByRole('button', { name: 'Refresh instance jobs', exact: true });
    if (await refresh.count() > 0 && await refresh.first().isVisible()) await refresh.first().click();
    else await page.waitForTimeout(250);
  }
  assertThat(latest?.status === 'succeeded' && latest?.result_code === 'completed',
    'Settings Maintenance job did not reach its successful terminal state');
  await waitFor(() => hasVisibleSemanticText(page, 'Maintenance · succeeded'),
    'successful Maintenance status to render');
  return {
    sequence,
    requestId: post.requestBody.request_id,
    jobId: accepted.job_id,
    acceptedAtMs: post.atMs,
    finishedAtMs: Date.now(),
  };
}

async function manualSync(page) {
  await click(page, 'Sync & conflicts');
  const sync = page.getByRole('button', { name: 'Sync now', exact: true });
  await sync.waitFor({ state: 'visible', timeout: 60000 });
  await waitFor(() => sync.isEnabled().catch(() => false), 'enabled Sync now action');
  await sync.click();
  await click(page, 'Hosts');
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web release bundle is missing');
  assertThat(BASE_URL && NODE_A_URL && NODE_B_URL && USERNAME && PASSWORD &&
    BOOTSTRAP_TOKEN && CONTROL_DIR && RUN_ID, 'PG auto-purge browser inputs are incomplete');
  const base = new URL(BASE_URL);
  assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' &&
    Number(base.port) > 0 && !base.pathname.slice(1), 'PG auto-purge proxy origin is invalid');
  fs.mkdirSync(CONTROL_DIR, { recursive: true, mode: 0o700 });

  let browser;
  let contextA;
  let contextB;
  let pageA;
  let pageB;
  let proxyStarted = false;
  let cleaned = false;
  try {
    await new Promise((resolve, reject) => {
      proxy.once('error', reject);
      proxy.listen(Number(base.port), '127.0.0.1', resolve);
    });
    proxyStarted = true;
    browser = await chromium.launch({
      headless: true,
      ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
    const contextOptions = { locale: 'en-US', viewport: { width: 1440, height: 1000 } };
    contextA = await browser.newContext(contextOptions);
    contextB = await browser.newContext(contextOptions);
    await Promise.all([
      contextA.setExtraHTTPHeaders({ 'x-pg-acceptance-profile': 'A' }),
      contextB.setExtraHTTPHeaders({ 'x-pg-acceptance-profile': 'B' }),
      contextA.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL }),
      contextB.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL }),
    ]);
    pageA = await contextA.newPage();
    pageB = await contextB.newPage();
    for (const page of [pageA, pageB]) {
      page.on('pageerror', (error) => {
        BROWSER_ERRORS.page += 1;
        if (BROWSER_ERRORS.pageErrorDetails.length < 5) {
          BROWSER_ERRORS.pageErrorDetails.push(safeErrorMessage(error));
        }
      });
      page.on('requestfailed', (request) => {
        const failedUrl = new URL(request.url());
        if (failedUrl.pathname.startsWith('/api/v1/')) {
          const failure = request.failure()?.errorText || 'unknown request failure';
          const endpoint = failedUrl.pathname.split('/').filter(Boolean)
            .map((part) => /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(part) ? ':id' : part)
            .slice(-2).join('/');
          // Flutter cancels an in-flight presence heartbeat as its document
          // unloads. This is expected on the explicit reload/close steps and
          // is not an HTTP/API failure; all other failed requests stay fatal.
          if (endpoint.endsWith('/presence') && failure === 'net::ERR_ABORTED') {
            BROWSER_ERRORS.expectedPresenceAbort += 1;
            return;
          }
          BROWSER_ERRORS.apiRequestFailure += 1;
          if (BROWSER_ERRORS.apiRequestFailureDetails.length < 5) {
            BROWSER_ERRORS.apiRequestFailureDetails.push({
              method: request.method(),
              endpoint,
              failure: safeErrorMessage(failure),
            });
          }
        }
      });
    }

    setStage('load two independent Web devices');
    await Promise.all([enterFlutter(pageA), enterFlutter(pageB)]);
    assertThat(await pageA.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null &&
      await pageB.evaluate(() => localStorage.getItem('x-pg-acceptance-profile')) === null,
    'proxy profile routing metadata leaked into Web storage');

    setStage('register allowlisted owner and create the target Vault');
    await connect(pageA);
    await field(pageA, 'Owner email');
    await fill(pageA, 'Owner email', USERNAME);
    await fill(pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(pageA, 'Confirm master password', PASSWORD);
    await fill(pageA, 'One-time bootstrap token', BOOTSTRAP_TOKEN);
    await fill(pageA, 'Device name', 'PG auto-purge owner device');
    await fill(pageA, 'First Vault', 'PG auto-purge acceptance Vault');
    await click(pageA, 'Create owner account');
    await waitWorkspace(pageA);

    setStage('enroll and approve independent Web device B');
    await connect(pageB);
    await field(pageB, 'Email or username');
    await click(pageB, 'Add this device');
    await fill(pageB, 'Account email', USERNAME);
    await fill(pageB, 'Device name', 'PG auto-purge second device');
    await click(pageB, 'Generate request');
    await field(pageB, 'Copy this enrollment JSON');
    await click(pageB, 'Copy');
    const enrollment = await pageB.evaluate(() => navigator.clipboard.readText());
    assertThat(JSON.parse(enrollment)?.format === 'atermius-device-enrollment-v1',
      'B enrollment JSON format was invalid');
    await click(pageB, 'Close');
    await click(pageA, 'Devices');
    await click(pageA, 'Approve enrollment');
    await paste(pageA, 'Enrollment JSON', enrollment);
    await click(pageA, 'Review keys');
    await click(pageA, 'Approve & seal keys');
    await click(pageA, 'Copy');
    const approval = await pageA.evaluate(() => navigator.clipboard.readText());
    assertThat(approval.includes('atermius-device-approval-v1'), 'A approval payload was invalid');
    await click(pageA, 'Done');
    await click(pageA, 'Hosts');
    await click(pageB, 'Import approval');
    await paste(pageB, 'Paste approval JSON', approval);
    await click(pageB, 'Import device keys');
    await fill(pageB, 'Email or username', USERNAME);
    await fill(pageB, 'Master password', PASSWORD);
    await click(pageB, 'Sign in and unlock');
    await waitWorkspace(pageB);
    await click(pageB, 'Hosts');

    setStage('create three encrypted Hosts and verify both devices sync them');
    const records = {};
    for (const [index, key] of ['eligible', 'future', 'disabled'].entries()) {
      setStage(`create Host ${index + 1} of 3 on owner device`);
      records[key] = await addHost(pageA, HOST_MARKERS[key]);
    }
    const vaultId = records.eligible.vaultId;
    assertThat(Object.values(records).every((item) => item.vaultId === vaultId),
      'test Hosts were not created in one Vault');
    setStage('synchronize three created Hosts to device B');
    await manualSync(pageB);
    for (const [index, name] of Object.values(HOST_MARKERS).entries()) {
      setStage(`verify created Host ${index + 1} of 3 on device B`);
      await waitHost(pageB, name, true, 'device B Host after create sync');
    }

    setStage('delete exact Hosts on owner device');
    for (const [index, key] of ['eligible', 'future', 'disabled'].entries()) {
      setStage(`delete Host ${index + 1} of 3`);
      await deleteHost(pageA, HOST_MARKERS[key]);
      setStage(`synchronize Host tombstone ${index + 1} of 3`);
      await manualSync(pageA);
      try {
        await waitFor(() => successfulPushes('A', 'delete', records[key].recordId).some((event) =>
          refsFromEvent(event).some((ref) => ref.operation === 'delete' &&
            ref.recordId === records[key].recordId && ref.revisionId && ref.commitSeq)),
        'exact signed Host tombstone receipt', 60000);
      } catch (_) {
        const observedPushes = API_EVENTS.filter((event) => event.profile === 'A' &&
          event.method === 'POST' && /\/sync\/push$/i.test(event.path)).map((event) => ({
          status: event.status,
          markerFree: event.requestMarkerFree && event.responseMarkerFree,
          operations: (event.requestBody?.operations || []).map((item) => ({
            type: item?.header?.operation || null,
            recordPrefix: String(item?.header?.record_id || '').slice(0, 8),
          })),
          resultCodes: (event.responseBody?.results || []).map((item) => item?.code || item?.error_code || null),
          errorCode: event.responseBody?.error?.code || event.responseBody?.code || null,
        }));
        throw new Error(`signed Host tombstone receipt was not observed; pushes=${JSON.stringify(observedPushes)}`);
      }
      const ref = successfulPushes('A', 'delete', records[key].recordId)
        .flatMap(refsFromEvent).find((item) =>
          item.operation === 'delete' && item.recordId === records[key].recordId &&
          item.revisionId && item.commitSeq);
      assertThat(ref, 'owner Host delete did not produce an exact tombstone receipt');
      records[key] = { ...records[key], ...ref };
    }
    setStage('synchronize three tombstones to device B');
    await manualSync(pageB);
    for (const [index, name] of Object.values(HOST_MARKERS).entries()) {
      setStage(`verify deleted Host ${index + 1} of 3 on device B`);
      await waitHost(pageB, name, false, 'device B Host after delete sync');
    }

    setStage('record owner consent for two exact future tombstones');
    await openRecycleBin(pageA);
    await assertRecycleBinState(pageA, records, 0, 3, ['eligible', 'future', 'disabled']);
    await consentForExactTombstone(pageA, records.eligible.recordId, HOST_MARKERS.eligible);
    await consentForExactTombstone(pageA, records.future.recordId, HOST_MARKERS.future);
    const consentEvents = API_EVENTS.filter((event) => event.method === 'PUT' &&
      /\/automatic-purge$/i.test(event.path) && event.profile === 'A');
    const expectedConsents = new Map([
      [records.eligible.recordId, records.eligible],
      [records.future.recordId, records.future],
    ]);
    const consentChecks = consentEvents.map((event) => {
      const recordId = event.path.split('/').at(-2);
      const target = expectedConsents.get(recordId);
      return {
        targetKnown: Boolean(target),
        status: event.status,
        exactKeys: safeEqualKeys(event.requestBody, [
        'expected_deleted_revision_id', 'expected_deleted_seq', 'expected_policy_revision', 'enabled',
        ]),
        revisionMatches: Boolean(target) && event.requestBody?.expected_deleted_revision_id === target.revisionId,
        sequenceMatches: Boolean(target) && event.requestBody?.expected_deleted_seq === target.commitSeq,
        policyRevisionIsZero: event.requestBody?.expected_policy_revision === '0',
        enabled: event.requestBody?.enabled === true,
        markerFree: event.requestMarkerFree && event.responseMarkerFree,
      };
    });
    assertThat(consentEvents.length === 2 && consentChecks.every((check) =>
      check.targetKnown && check.status === 200 && check.exactKeys && check.revisionMatches &&
      check.sequenceMatches && check.policyRevisionIsZero && check.enabled && check.markerFree),
    `UI did not record exact-tombstone consent with the expected compare-and-swap fields; checks=${JSON.stringify(consentChecks)}`);
    await assertRecycleBinState(pageA, records, 2, 1, ['eligible', 'future', 'disabled']);
    await closeRecycleBin(pageA);

    setStage('reload and verify persisted per-tombstone consent');
    await pageA.reload({ waitUntil: 'domcontentloaded' });
    await enableFlutterSemanticsAfterReload(pageA);
    await recoverWorkspaceAfterReload(pageA);
    await click(pageA, 'Hosts');
    await openRecycleBin(pageA);
    await assertRecycleBinState(pageA, records, 2, 1, ['eligible', 'future', 'disabled']);
    await closeRecycleBin(pageA);

    setStage('wait for both active devices to publish redaction-v1 capability');
    await waitFor(() => capabilityEvents('A').length > 0 && capabilityEvents('B').length > 0,
      'both signed redaction capability reports', 60000);
    const meA = API_EVENTS.find((event) => event.profile === 'A' && event.method === 'GET' &&
      event.path === '/api/v1/me' && event.status === 200)?.responseBody;
    const meB = API_EVENTS.find((event) => event.profile === 'B' && event.method === 'GET' &&
      event.path === '/api/v1/me' && event.status === 200)?.responseBody;
    const ownerDeviceId = capabilityEvents('A')[0].requestBody?.device_id;
    const secondDeviceId = capabilityEvents('B')[0].requestBody?.device_id;
    const ownerAccountId = capabilityEvents('A')[0].requestBody?.account_id;
    assertThat(ownerDeviceId && secondDeviceId && ownerDeviceId !== secondDeviceId &&
      ownerAccountId && ownerAccountId === capabilityEvents('B')[0].requestBody?.account_id &&
      meA?.device_id === ownerDeviceId && meB?.device_id === secondDeviceId,
    'redaction capability reports did not belong to the two active Web devices in one account');
    const consentByRecord = Object.fromEntries(consentEvents.map((event) => [
      event.path.split('/').at(-2), event.requestBody,
    ]));
    publishGate('consent_ready', {
      vault_id: vaultId,
      account_id: ownerAccountId,
      owner_device_id: ownerDeviceId,
      second_device_id: secondDeviceId,
      records: Object.fromEntries(Object.entries(records).map(([key, item]) => [key, {
        record_id: item.recordId,
        create_revision_id: item.createRevisionId,
        create_seq: item.createSeq,
        deleted_revision_id: item.revisionId,
        deleted_seq: item.commitSeq,
        auto_purge_enabled: Boolean(consentByRecord[item.recordId]?.enabled),
      }])),
      capability_reports_observed: { A: true, B: true },
    });

    await waitForGateFile('invalidate');
    setStage('verify the initial Vault-scoped readiness snapshot');
    await pageA.getByText('PG auto-purge acceptance Vault', { exact: true })
      .waitFor({ state: 'visible', timeout: 30000 });
    const readinessNavigationApiStart = API_EVENTS.length;
    await click(pageA, 'Devices');
    await waitForApiEvent((event) => API_EVENTS.indexOf(event) >= readinessNavigationApiStart &&
      event.profile === 'A' && event.method === 'GET' &&
      event.path === `/api/v1/vaults/${vaultId}/devices` && event.status === 200,
    'fresh readiness roster for the target Vault after navigation');
    await waitForReadiness(pageA, [2, 0, 0, 0, 0],
      'both active Vault devices to show verified redaction readiness',
      readinessNavigationApiStart);

    setStage('invalidate device B readiness with an authenticated markerless sync request');
    const initialSecondDeviceRevision = capabilityEvents('B').at(-1)?.requestBody?.revision;
    assertThat(Number.isSafeInteger(initialSecondDeviceRevision),
      'device B must have an observed signed report revision before invalidation');
    stripRedactionMarkersProfile = 'B';
    const invalidationStart = API_EVENTS.length;
    await manualSync(pageB);
    const invalidationRequest = await waitForApiEvent((event) =>
      API_EVENTS.indexOf(event) >= invalidationStart && event.profile === 'B' &&
      event.method === 'GET' && event.path.endsWith('/changes') &&
      event.redactionMarkerPresent && event.redactionMarkerStripped && event.status === 200,
    'successful authenticated markerless sync changes request');
    assertThat(invalidationRequest.node === 'B',
      'the markerless sync request did not reach PostgreSQL node B');
    await waitForReadiness(pageA, [1, 1, 0, 0, 0],
      'device B report invalidation to appear in the Vault readiness view');
    await click(pageA, 'Hosts');
    await openRecycleBin(pageA);
    await waitFor(() => hasVisibleSemanticText(pageA, 'Report expired or invalidated'),
      'Recycle Bin to show the invalidated Vault device report');
    publishGate('report_invalidated', {
      account_id: ownerAccountId,
      owner_device_id: ownerDeviceId,
      second_device_id: secondDeviceId,
      report_revision_before: initialSecondDeviceRevision,
      markerless_sync_observed: true,
      readiness: 'invalidated',
    });
    await waitForGateFile('blocked');

    setStage('run Maintenance while one active Vault device report is invalidated');
    await closeRecycleBin(pageA);
    const blockedMaintenance = await submitMaintenanceFromSettings(pageA, 0);
    publishGate('blocked_purge', {
      job_id: blockedMaintenance.jobId,
      request_id: blockedMaintenance.requestId,
    });
    await waitForGateFile('recovery');

    setStage('republish a higher redaction report revision and refresh readiness');
    stripRedactionMarkersProfile = null;
    const recoveryStart = API_EVENTS.length;
    await manualSync(pageB);
    await click(pageB, 'Devices');
    await waitForReadiness(pageB, [2, 0, 0, 0, 0],
      'device B to repair and verify its own invalidated report on explicit refresh', 0, 'B');
    const recoveredReport = await waitForApiEvent((event) =>
      API_EVENTS.indexOf(event) >= recoveryStart && event.profile === 'B' && event.method === 'PUT' &&
      event.path === '/api/v1/devices/redaction-capabilities' && event.status === 200 &&
      Number.isSafeInteger(event.requestBody?.revision) &&
      event.requestBody.revision > initialSecondDeviceRevision,
    'device B to republish a higher redaction report revision', 60000);
    await click(pageA, 'Devices');
    await waitForReadiness(pageA, [2, 0, 0, 0, 0],
      'both active Vault devices to return to verified readiness');
    await click(pageA, 'Hosts');
    await openRecycleBin(pageA);
    await waitFor(() => hasVisibleSemanticText(pageA,
      'All active Vault devices report support for redaction v1.'),
    'Recycle Bin to show that all active Vault devices are ready for redaction v1');
    publishGate('report_recovered', {
      account_id: ownerAccountId,
      second_device_id: secondDeviceId,
      report_revision: recoveredReport.requestBody.revision,
      readiness: 'ready',
    });
    await closeRecycleBin(pageA);
    await waitForGateFile('purge');

    setStage('submit the first Maintenance job from Web Settings');
    await click(pageA, 'Settings');
    await waitFor(() => hasVisibleSemanticText(pageA, 'Instance jobs'), 'Settings instance jobs');
    const firstMaintenance = await submitMaintenanceFromSettings(pageA, 1);
    publishGate('first_purge', {
      vault_id: vaultId,
      target_record_id: records.eligible.recordId,
      job_id: firstMaintenance.jobId,
      request_id: firstMaintenance.requestId,
    });
    await waitForGateFile('repeat');

    setStage('submit a second Settings Maintenance job and verify idempotent state');
    const secondMaintenance = await submitMaintenanceFromSettings(pageA, 2);
    assertThat(secondMaintenance.jobId !== firstMaintenance.jobId &&
      secondMaintenance.requestId !== firstMaintenance.requestId,
    'repeat Maintenance did not use a distinct UI submission');

    setStage('verify B receives and applies record_redacted through node B');
    await click(pageB, 'Hosts');
    await manualSync(pageB);
    await waitFor(() => API_EVENTS.some((event) => event.profile === 'B' && event.node === 'B' &&
      event.method === 'GET' && /\/changes$/i.test(event.path) && event.status === 200 &&
      event.responseMarkerFree && Array.isArray(event.responseBody?.events) &&
      event.responseBody.events.some((item) => item?.record_id === records.eligible.recordId &&
        item?.event_type === 'record_redacted')),
    'B node-B feed to include the exact record_redacted marker', 60000);
    const redactionFeed = API_EVENTS.find((event) => event.profile === 'B' && event.node === 'B' &&
      event.method === 'GET' && /\/changes$/i.test(event.path) && event.status === 200 &&
      event.responseBody?.events?.some((item) => item?.record_id === records.eligible.recordId &&
        item?.event_type === 'record_redacted'));
    const redactionEvent = redactionFeed.responseBody.events.find((item) =>
      item?.record_id === records.eligible.recordId && item?.event_type === 'record_redacted');
    const proof = redactionEvent.redaction;
    const proofChecks = {
      eventKeys: safeEqualKeys(redactionEvent, ['commit_seq', 'event_type', 'record_id', 'redaction']),
      proofKeys: safeEqualKeys(proof, [
        'format', 'redaction_id', 'instance_id', 'server_space_id', 'vault_id', 'record_id',
        'deleted_revision_id', 'deleted_seq', 'redaction_seq', 'signing_public_key', 'signature',
      ]),
      format: proof.format === 'atermius-record-redaction-proof-v1',
      identityMatches: proof.vault_id === vaultId && proof.record_id === records.eligible.recordId &&
        proof.deleted_revision_id === records.eligible.revisionId &&
        proof.deleted_seq === records.eligible.commitSeq,
      redactionSequenceMatches: proof.redaction_seq === '7' && redactionEvent.commit_seq === '7',
      signaturePresent: typeof proof.signature === 'string' && proof.signature.length >= 80,
      signatureValid: verifyRedactionProof(proof),
      feedAfterMaintenanceAccepted: redactionFeed.atMs >= firstMaintenance.acceptedAtMs,
      markerFree: redactionFeed.requestMarkerFree && redactionFeed.responseMarkerFree,
      routedThroughNodeB: redactionFeed.node === 'B' && redactionFeed.profile === 'B',
    };
    assertThat(Object.values(proofChecks).every(Boolean),
      `B did not receive the expected marker-free redaction proof; checks=${JSON.stringify(proofChecks)}`);
    await openRecycleBin(pageB);
    await assertRecycleBinState(pageB, records, 1, 1, ['future', 'disabled'], ['eligible'], false);
    const secondDeviceAppliedRedaction = await recycleRow(pageB,
      { ...records.eligible, displayName: HOST_MARKERS.eligible }, false).count() === 0;
    await closeRecycleBin(pageB);

    const selectedPrivacyEvents = API_EVENTS.filter((event) =>
      (/\/sync\/push$/i.test(event.path) || /\/changes$/i.test(event.path) ||
       /\/automatic-purge$/i.test(event.path) || event.path === '/api/v1/admin/jobs') &&
      (event.profile === 'A' || event.profile === 'B'));
    const privacyValid = selectedPrivacyEvents.every((event) =>
      event.requestMarkerFree && event.responseMarkerFree);
    assertThat(privacyValid, 'synthetic Host plaintext appeared in a sync, consent, feed, or maintenance API body');
    const manualPurgeRequests = API_EVENTS.filter((event) =>
      /^\/api\/v1\/vaults\/[^/]+\/records\/[^/]+\/purge$/i.test(event.path));
    assertThat(manualPurgeRequests.length === 0,
      'browser journey must purge only through the bounded Settings Maintenance job');
    assertThat(BROWSER_ERRORS.page === 0 && BROWSER_ERRORS.apiRequestFailure === 0,
      `Chromium observed a page exception or failed API request; counts=${JSON.stringify({
        page: BROWSER_ERRORS.page,
        apiRequestFailure: BROWSER_ERRORS.apiRequestFailure,
        pageErrorDetails: BROWSER_ERRORS.pageErrorDetails,
        apiRequestFailureDetails: BROWSER_ERRORS.apiRequestFailureDetails,
      })}`);
    const expectedRedactionReports = ['A', 'B'].every((profile) =>
      capabilityEvents(profile).every((event) => event.requestBody?.sync_redaction_version === 1 &&
        event.responseMarkerFree));
    assertThat(expectedRedactionReports, 'Web redaction capability reports were not successful and marker-free');

    const result = {
      vaultId,
      accountId: ownerAccountId,
      ownerDeviceId,
      secondDeviceId,
      records,
      consentRequests: consentEvents.map((event) => ({
        recordId: event.path.split('/').at(-2),
        status: event.status,
        enabled: event.requestBody?.enabled,
        policyRevision: event.requestBody?.expected_policy_revision,
        deletedRevisionId: event.requestBody?.expected_deleted_revision_id,
        deletedSeq: event.requestBody?.expected_deleted_seq,
      })),
      firstMaintenance,
      secondMaintenance,
      capabilityReportsObserved: expectedRedactionReports,
      crossNodeFeed: {
        node: redactionFeed.node,
        eventType: redactionEvent.event_type,
        recordId: redactionEvent.record_id,
        commitSeq: redactionEvent.commit_seq,
        markerFree: redactionFeed.responseMarkerFree,
        proof: {
          format: proof.format,
          redactionId: proof.redaction_id,
          instanceId: proof.instance_id,
          serverSpaceId: proof.server_space_id,
          vaultId: proof.vault_id,
          recordId: proof.record_id,
          deletedRevisionId: proof.deleted_revision_id,
          deletedSeq: proof.deleted_seq,
          redactionSeq: proof.redaction_seq,
          // Public keys are Base64URL strings long enough to match pytest's
          // long-token scrubber. Emit a stable digest so the outer acceptance
          // process can compare trust anchors without parsing a scrubbed key.
          signingPublicKeyFingerprint: crypto.createHash('sha256')
            .update(proof.signing_public_key, 'utf8').digest('hex').slice(0, 12),
          signaturePresent: typeof proof.signature === 'string' && proof.signature.length >= 80,
          signatureValid: proofChecks.signatureValid,
        },
      },
      manualPurgeRequests: manualPurgeRequests.length,
      secondDeviceAppliedRedaction,
      privacyMarkersAbsent: privacyValid,
      pageErrors: BROWSER_ERRORS.page,
      apiRequestFailures: BROWSER_ERRORS.apiRequestFailure,
    };

    const closed = await Promise.allSettled([contextA.close(), contextB.close()]);
    await browser.close();
    for (const socket of PROXY_SOCKETS) socket.destroy();
    await new Promise((resolve) => proxy.close(resolve));
    proxyStarted = false;
    cleaned = closed.every((item) => item.status === 'fulfilled') && !browser.isConnected() && !proxy.listening;
    assertThat(cleaned, 'browser contexts or same-origin proxy did not clean up');
    result.browserCleanupComplete = cleaned;
    console.log(`PG_AUTO_PURGE_RESULT:${JSON.stringify(result)}`);
    console.log('assert: pg_web_auto_purge_sync=true');
  } catch (error) {
    console.error(`stage: failed; error type=${error?.name || 'unknown'}; detail=${safeErrorMessage(error)}`);
    throw error;
  } finally {
    if (!cleaned) {
      await Promise.allSettled([contextA, contextB].filter(Boolean).map((context) => context.close()));
      if (browser) await browser.close().catch(() => {});
      for (const socket of PROXY_SOCKETS) socket.destroy();
      if (proxyStarted) await new Promise((resolve) => proxy.close(resolve));
    }
  }
}

main().catch((error) => {
  console.error(`PG_AUTO_PURGE_FAILED:${error?.name || 'Error'}`);
  process.exitCode = 1;
});
