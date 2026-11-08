/*
 * WEB-DELETE-EDIT-01: A edits a Host offline while independently approved B
 * deletes the same committed Host. A must preserve its encrypted branch and
 * the remote tombstone until the user explicitly chooses to keep A's version.
 * The choice creates a new A-signed restore revision against B's tombstone.
 * Two on-disk Chromium profiles, the server, database, and logs are disposable.
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-delete-edit-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `DeleteEdit-${crypto.randomBytes(24).toString('base64url')}9`;
const HOST_ORIGINAL = `delete-edit-original-${RUN_ID.slice(0, 8)}`;
const HOST_EDITED = `delete-edit-kept-${RUN_ID.slice(0, 8)}`;
const HOST_USER = `delete-edit-user-${RUN_ID.slice(0, 8)}`;
const HOST_ADDRESS = '192.0.2.45';
const HOST_MARKERS = [HOST_ORIGINAL, HOST_EDITED, HOST_USER, HOST_ADDRESS];

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let serverLogPath;
let serverProcess;
let ownerContext;
let secondContext;
let bootstrapToken;
let cleanupPromise;
let cleanupFailed = false;
const apiEvents = [];
const apiStatusEvents = [];
const pageErrors = { A: 0, B: 0 };
const requestFailures = { A: 0, B: 0 };
const apiBodyMarkerMatches = [];
const traceByRequest = new WeakMap();
let apiResponseReadsInFlight = 0;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function safeDiagnosticText(value) {
  let message = String(value ?? '');
  const secrets = [USERNAME, MASTER_PASSWORD, bootstrapToken, baseUrl, ...HOST_MARKERS]
    .filter((item) => typeof item === 'string' && item.length > 0)
    .sort((left, right) => right.length - left.length);
  for (const secret of secrets) message = message.split(secret).join('[redacted]');
  return message
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[redacted-email]')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[redacted-address]')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '[redacted-token]')
    .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
    .replace(/\s+/g, ' ')
    .slice(0, 360);
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 8 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `${command} failed in the isolated fixture`);
  return result.stdout || '';
}

async function unusedLoopbackPort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => {
    listener.close((error) => error ? reject(error) : resolve());
  });
  return port;
}

async function waitForServer(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // The isolated listener has not finished starting yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

function processGroupHasLiveMembers(groupId) {
  try {
    for (const entry of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(entry)) continue;
      let stat;
      try {
        stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      } catch (error) {
        if (error.code === 'EACCES' || error.code === 'EPERM') return true;
        continue;
      }
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') return true;
    }
    return false;
  } catch (_) {
    try {
      process.kill(-groupId, 0);
      return true;
    } catch (error) {
      return error.code !== 'ESRCH';
    }
  }
}

function signalProcessGroup(groupId, signal) {
  try {
    process.kill(-groupId, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw new Error('isolated process cleanup failed');
  }
}

async function waitForProcessGroupExit(groupId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processGroupHasLiveMembers(groupId)) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return !processGroupHasLiveMembers(groupId);
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  throw new Error('isolated server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    try {
      if (ownerContext) await ownerContext.close().catch(() => {});
      if (secondContext) await secondContext.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    } finally {
      if (tempRoot) {
        try {
          fs.rmSync(tempRoot, { recursive: true, force: true });
          if (fs.existsSync(tempRoot)) cleanupFailed = true;
        } catch (_) {
          cleanupFailed = true;
        }
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

function cliToken(environment) {
  const output = runChecked(SERVER_BINARY, ['bootstrap'], {
    env: environment,
    timeout: 30000,
  });
  const token = output.trim().split(/\s+/).at(-1);
  assertThat(typeof token === 'string' && token.length >= 40,
    'isolated bootstrap credential was unavailable');
  return token;
}

async function waitFor(predicate, label, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} did not appear`);
}

async function waitForSemanticText(page, expected, timeoutMs = 20000) {
  await waitFor(() => page.evaluate((label) => {
    if ((document.body.innerText || '').includes(label)) return true;
    if ([...document.querySelectorAll('flt-semantics')].some((node) =>
      `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`.includes(label))) {
      return true;
    }
    const intersectsViewport = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 &&
        rect.top < window.innerHeight && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    return [...document.querySelectorAll('input[aria-label], textarea[aria-label]')]
      .some((element) => intersectsViewport(element) &&
        (element.getAttribute('aria-label') || '').includes(label));
  }, expected).catch(() => false), `visible semantic text: ${expected}`, timeoutMs);
}

async function semanticTextIntersectsViewport(page, expected) {
  return page.evaluate((label) => {
    const intersectsViewport = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 &&
        rect.top < window.innerHeight && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const semanticMatch = [...document.querySelectorAll('flt-semantics')]
      .some((node) => intersectsViewport(node) &&
        `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`
          .includes(label));
    const selectableTextMatch = [
      ...document.querySelectorAll('input[aria-label], textarea[aria-label]'),
    ].some((element) => intersectsViewport(element) &&
      (element.getAttribute('aria-label') || '').includes(label));
    return semanticMatch || selectableTextMatch;
  }, expected).catch(() => false);
}

async function visibleConflictProjectionFlags(page) {
  return page.evaluate(() => {
    const visibleText = [...document.querySelectorAll('flt-semantics')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && rect.bottom > 0 &&
          rect.top < window.innerHeight && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity) !== 0;
      })
      .map((node) => `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`)
      .join('\n');
    const visibleInputLabels = [
      ...document.querySelectorAll('input[aria-label], textarea[aria-label]'),
    ]
      .filter((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && rect.bottom > 0 &&
          rect.top < window.innerHeight && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity) !== 0;
      })
      .map((element) => element.getAttribute('aria-label') || '');
    const has = (label) => visibleText.includes(label) ||
      visibleInputLabels.some((value) => value.includes(label));
    return {
      conflictBranchOperationLabelVisible: has('分支操作'),
      conflictEditOperationVisible: has('修改'),
      currentServerVersionLabelVisible: has('当前服务端版本'),
      conflictDeletedHeadVisible: has('已删除'),
      noPendingCrossDeviceBranchVisible: has('没有待处理的跨设备分支'),
      unverifiedCrossDeviceBranchVisible: has('分支尚未通过验证'),
    };
  }).catch(() => null);
}

async function scrollMainContentUntilSemanticText(page, expected, maxScrolls = 8) {
  const viewport = page.viewportSize() || { width: 1440, height: 1000 };
  await page.mouse.move(
    Math.max(300, Math.round(viewport.width * 0.72)),
    Math.round(viewport.height * 0.82),
  );
  for (let attempt = 0; attempt <= maxScrolls; attempt += 1) {
    if (await semanticTextIntersectsViewport(page, expected)) return;
    if (attempt === maxScrolls) break;
    await page.mouse.wheel(0, Math.round(viewport.height * 0.7));
    await page.waitForTimeout(120);
  }
  throw new Error(`main content did not expose the expected conflict text: ${expected}`);
}

async function visibleButton(page, label, timeoutMs = 20000) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const count = await matches.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button was not available: ${label}`);
}

async function click(page, label) {
  await (await visibleButton(page, label)).click();
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(100);
    if (await locator.inputValue().catch(() => null) !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue().catch(() => null) === value) return;
  }
  throw new Error(`visible field did not retain its value: ${label}`);
}

async function paste(page, label, value) {
  const locator = await field(page, label);
  await page.evaluate(async (clipboardValue) => navigator.clipboard.writeText(clipboardValue), value);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(150);
  if (await locator.inputValue().catch(() => '') !== value) await locator.fill(value);
  assertThat(await locator.inputValue().catch(() => null) === value,
    `clipboard input was not retained: ${label}`);
  await locator.press('Tab');
}

async function enableSemantics(page) {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  'Flutter Web semantics initialization', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter Web semantic controls', 15000);
}

async function waitWorkspace(page) {
  await (await visibleButton(page, 'Settings', 40000)).waitFor({ state: 'visible' });
}

async function safeContextUiState(context) {
  if (!context) return { contextAvailable: false };
  let page;
  try { page = context.pages()[0]; } catch (_) {}
  if (!page || page.isClosed()) return { contextAvailable: true, pageAvailable: false };
  const state = await page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const labels = (selector) => [...document.querySelectorAll(selector)]
      .filter(visible)
      .map((element) => (element.getAttribute('aria-label') || element.innerText || '')
        .replace(/\s+/g, ' ').trim())
      .filter(Boolean)
      .slice(0, 24);
    const inputs = labels('input[aria-label], textarea[aria-label]');
    const buttons = labels('flt-semantics[role="button"], button');
    const text = (document.body?.innerText || '').toLowerCase();
    const viewportInputLabels = [
      ...document.querySelectorAll('input[aria-label], textarea[aria-label]'),
    ]
      .filter((element) => {
        const rect = element.getBoundingClientRect();
        return visible(element) && rect.bottom > 0 && rect.top < window.innerHeight;
      })
      .map((element) => element.getAttribute('aria-label') || '');
    const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => {
        const rect = element.getBoundingClientRect();
        return visible(element) && rect.bottom > 0 && rect.top < window.innerHeight;
      })
      .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const hasVisibleSemanticText = (needle) =>
      visibleSemanticText.includes(needle) ||
      viewportInputLabels.some((label) => label.includes(needle));
    return {
      path: location.pathname,
      readyState: document.readyState,
      semanticNodeCount: document.querySelectorAll('flt-semantics').length,
      visibleInputLabels: inputs,
      visibleButtonLabels: buttons,
      visibleDialogCount: [...document.querySelectorAll('[role="dialog"], [role="alertdialog"]')]
        .filter(visible).length,
      visibleErrorNotice: /registration failed|sign.?in failed|invalid credentials|注册失败|连接失败/
        .test(text),
      conflictBranchOperationLabelVisible: hasVisibleSemanticText('分支操作'),
      conflictEditOperationVisible: hasVisibleSemanticText('修改'),
      currentServerVersionLabelVisible: hasVisibleSemanticText('当前服务端版本'),
      conflictDeletedHeadVisible: hasVisibleSemanticText('已删除'),
      noPendingCrossDeviceBranchVisible: hasVisibleSemanticText('没有待处理的跨设备分支'),
      unverifiedCrossDeviceBranchVisible: hasVisibleSemanticText('分支尚未通过验证'),
      visibleSettingsAction: buttons.some((label) => label === 'Settings'),
      visibleCreateOwnerAction: buttons.some((label) => label === 'Create owner account'),
      visibleAddHostAction: buttons.some((label) => label === 'Add host'),
      visibleContinueAction: buttons.some((label) => label === 'Continue'),
    };
  }).catch(() => null);
  if (!state) return { contextAvailable: true, pageAvailable: true, stateReadable: false };
  state.visibleInputLabels = state.visibleInputLabels.map(safeDiagnosticText);
  state.visibleButtonLabels = state.visibleButtonLabels.map(safeDiagnosticText);
  return { contextAvailable: true, pageAvailable: true, ...state };
}

function routeFor(pathname) {
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) return 'changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts$/.test(pathname)) return 'conflict-create';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts\/[^/]+\/resolve$/.test(pathname)) return 'conflict-resolve';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflict-changes$/.test(pathname)) return 'conflict-changes';
  return null;
}

function safeOperation(value) {
  const header = value?.header && typeof value.header === 'object' ? value.header : {};
  return {
    operation: typeof header.operation === 'string' ? header.operation : null,
    recordId: typeof header.record_id === 'string' ? header.record_id : null,
    revisionId: typeof header.revision_id === 'string' ? header.revision_id : null,
    baseRevisionId: typeof header.base_revision_id === 'string'
      ? header.base_revision_id : null,
    opId: typeof header.op_id === 'string' ? header.op_id : null,
    deviceId: typeof header.device_id === 'string' ? header.device_id : null,
    envelopeHash: typeof value?.ciphertext === 'string'
      ? crypto.createHash('sha256').update(value.ciphertext).digest('hex') : null,
  };
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function envelopeFingerprint(value) {
  return crypto.createHash('sha256').update(canonicalJson(value)).digest('hex');
}

function attachApiObservation(page, profile) {
  page.on('pageerror', () => { pageErrors[profile] += 1; });
  page.on('requestfailed', () => { requestFailures[profile] += 1; });
  page.on('request', (request) => {
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (!pathname.startsWith('/api/v1/')) return;
    const route = routeFor(pathname);
    const safeRoute = route || (/^\/api\/v1\/auth\//.test(pathname) ? 'auth' : 'other-api');
    const statusEvent = {
      profile,
      route: safeRoute,
      method: request.method(),
      status: null,
    };
    apiStatusEvents.push(statusEvent);
    let body = '';
    try { body = request.postData() || ''; } catch (_) {}
    const markerMatch = HOST_MARKERS.some((marker) => body.includes(marker));
    if (markerMatch) apiBodyMarkerMatches.push({ profile, route: route || 'other-api', direction: 'request' });
    if (!route) {
      traceByRequest.set(request, { statusEvent, event: null });
      return;
    }
    const event = {
      profile,
      route,
      method: request.method(),
      status: null,
      bodyRead: false,
      markerMatch,
      operations: [],
      receipts: [],
      conflictId: null,
      resolution: null,
      changeEvents: [],
    };
    if (route === 'push') {
      try {
        const payload = JSON.parse(body);
        event.deviceId = payload.device_id || null;
        event.operations = Array.isArray(payload.operations)
          ? payload.operations.map(safeOperation) : [];
      } catch (_) {}
    } else if (route === 'conflict-create') {
      try {
        const payload = JSON.parse(body);
        event.operations = payload.envelope ? [safeOperation(payload.envelope)] : [];
      } catch (_) {}
    }
    apiEvents.push(event);
    traceByRequest.set(request, { statusEvent, event });
  });
  page.on('response', (response) => {
    void (async () => {
      let observingApiResponse = false;
      try {
        const observed = traceByRequest.get(response.request());
        const event = observed?.event || null;
        let pathname;
        try { pathname = new URL(response.url()).pathname; } catch (_) { return; }
        if (!pathname.startsWith('/api/v1/')) return;
        apiResponseReadsInFlight += 1;
        observingApiResponse = true;
        if (observed?.statusEvent) observed.statusEvent.status = response.status();
        if (event) event.status = response.status();
        let body = '';
        try { body = await response.text(); } catch (_) {}
        const markerMatch = HOST_MARKERS.some((marker) => body.includes(marker));
        if (markerMatch) apiBodyMarkerMatches.push({
          profile,
          route: event?.route || routeFor(pathname) || 'other-api',
          direction: 'response',
        });
        if (!event) return;
        event.bodyRead = true;
        event.markerMatch ||= markerMatch;
        let payload;
        try { payload = JSON.parse(body); } catch (_) { payload = null; }
        if (!payload) return;
        if (event.route === 'push') {
          event.receipts = Array.isArray(payload.results) ? payload.results.map((receipt) => ({
            opId: receipt.op_id,
            revisionId: receipt.revision_id,
            commitSeq: receipt.commit_seq,
            alreadyCommitted: receipt.already_committed,
          })) : [];
        } else if (event.route === 'conflict-create') {
          event.conflictId = typeof payload.conflict_id === 'string' ? payload.conflict_id : null;
        } else if (event.route === 'conflict-resolve') {
          event.resolution = {
            status: payload.status,
            resolvedRevisionId: payload.resolved_revision_id,
            resolutionSeq: payload.resolution_seq,
            alreadyResolved: payload.already_resolved,
          };
        } else if (event.route === 'changes' && Array.isArray(payload.events)) {
          event.changeEvents = payload.events.map((item) => ({
            commitSeq: item.commit_seq,
            eventType: item.event_type,
            recordId: item.record_id,
            revisionId: item.revision_id,
            operation: item.envelope?.header?.operation || null,
            opId: item.envelope?.header?.op_id || null,
          }));
        } else if (event.route === 'conflict-changes' && Array.isArray(payload.events)) {
          event.changeEvents = payload.events.map((item) => ({
            seq: item.seq,
            type: item.type,
            conflictId: item.conflict_id,
            resolvedRevisionId: item.resolved_revision_id,
            branchOperation: item.envelope?.header?.operation || null,
          }));
        }
      } finally {
        if (observingApiResponse) apiResponseReadsInFlight -= 1;
      }
    })().catch(() => {});
  });
}

async function launchProfile(profileDir, profile) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    acceptDownloads: true,
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profileDir, options);
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  const page = context.pages()[0] || await context.newPage();
  attachApiObservation(page, profile);
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await enableSemantics(page);
  return { context, page };
}

let baseUrl;

async function connect(page) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function registerOwner(page) {
  setStage('Owner registration: connect to the isolated server');
  await connect(page);
  setStage('Owner registration: wait for the bootstrap form');
  await field(page, 'Owner email');
  setStage('Owner registration: fill Owner email');
  await fill(page, 'Owner email', USERNAME);
  setStage('Owner registration: fill master password');
  await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
  setStage('Owner registration: fill password confirmation');
  await fill(page, 'Confirm master password', MASTER_PASSWORD);
  setStage('Owner registration: fill bootstrap token');
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  setStage('Owner registration: fill device name');
  await fill(page, 'Device name', 'Delete edit A');
  setStage('Owner registration: fill first Vault name');
  await fill(page, 'First Vault', 'Delete edit Vault');
  bootstrapToken = undefined;
  setStage('Owner registration: submit account creation');
  await click(page, 'Create owner account');
  setStage('Owner registration: wait for the workspace');
  await waitWorkspace(page);
}

async function enrollSecondDevice(ownerPage, secondPage) {
  await connect(secondPage);
  await field(secondPage, 'Email or username');
  await click(secondPage, 'Add this device');
  await waitForSemanticText(secondPage, 'Request this device');
  await fill(secondPage, 'Account email', USERNAME);
  await fill(secondPage, 'Device name', 'Delete edit B');
  await click(secondPage, 'Generate request');
  await field(secondPage, 'Copy this enrollment JSON');
  await click(secondPage, 'Copy');
  const enrollment = await secondPage.evaluate(() => navigator.clipboard.readText());
  let enrollmentFormat;
  try { enrollmentFormat = JSON.parse(enrollment).format; } catch (_) {}
  assertThat(enrollmentFormat === 'atermius-device-enrollment-v1',
    'B device enrollment payload had an unsupported format');
  await click(secondPage, 'Close');

  await click(ownerPage, 'Devices');
  await click(ownerPage, 'Approve enrollment');
  await paste(ownerPage, 'Enrollment JSON', enrollment);
  await click(ownerPage, 'Review keys');
  await click(ownerPage, 'Approve & seal keys');
  await click(ownerPage, 'Copy');
  const approval = await ownerPage.evaluate(() => navigator.clipboard.readText());
  assertThat(approval.includes('atermius-device-approval-v1'),
    'A device approval payload had an unsupported format');
  await click(ownerPage, 'Done');
  await click(ownerPage, 'Hosts');
  await waitWorkspace(ownerPage);

  await click(secondPage, 'Import approval');
  await paste(secondPage, 'Paste approval JSON', approval);
  await click(secondPage, 'Import device keys');
  await fill(secondPage, 'Email or username', USERNAME);
  await fill(secondPage, 'Master password', MASTER_PASSWORD);
  await click(secondPage, 'Sign in and unlock');
  await waitWorkspace(secondPage);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hostCard(page, name) {
  return page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)};`),
  }).first();
}

async function waitHost(page, name, expected) {
  await waitFor(async () => {
    const card = hostCard(page, name);
    const count = await card.count().catch(() => 0);
    const visible = count > 0 && await card.isVisible().catch(() => false);
    return visible === expected;
  }, `Host visibility ${expected ? 'true' : 'false'}`, 20000);
}

async function addHost(page) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitForSemanticText(page, 'Add a host');
  await fill(page, 'Display name', HOST_ORIGINAL);
  await fill(page, 'Hostname or IP', HOST_ADDRESS);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', HOST_USER);
  await click(page, 'Save encrypted host');
  await waitHost(page, HOST_ORIGINAL, true);
}

async function editHostName(page, oldName, newName) {
  const card = hostCard(page, oldName);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await fill(page, 'Display name', newName);
  await click(page, 'Save encrypted host');
  await waitHost(page, newName, true);
}

async function deleteHost(page, name) {
  const card = hostCard(page, name);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'More actions', exact: true }).click();
  await page.getByRole('menuitem', { name: 'Delete', exact: true }).click();
  await waitForSemanticText(page, 'Delete this item?');
  const dialog = page.getByRole('alertdialog').filter({ hasText: 'Delete this item?' }).first();
  await dialog.getByRole('button', { name: 'Delete', exact: true }).click();
  await waitHost(page, name, false);
}

async function syncNow(page, completeWhen, label) {
  const patterns = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only)$/;
  const syncButton = page.getByRole('button', { name: patterns }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 20000 });
  await waitFor(() => syncButton.isEnabled().catch(() => false), 'enabled sync action', 30000);
  const current = (await syncButton.getAttribute('aria-label').catch(() => null)) ||
    (await syncButton.innerText().catch(() => '')).trim();
  if (current !== 'Syncing') await syncButton.click();
  await waitFor(completeWhen, label, 45000);
}

async function waitTrace(predicate, label, timeoutMs = 30000) {
  await waitFor(() => apiEvents.some(predicate), label, timeoutMs);
  return apiEvents.find(predicate);
}

function successfulPush(profile, operation, recordId = null, after = 0) {
  return apiEvents.slice(after).find((event) =>
    event.profile === profile && event.route === 'push' && event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.operation === operation &&
      (!recordId || item.recordId === recordId)));
}

function readServerSnapshot(recordId = '') {
  const script = String.raw`
import json,sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)
db.row_factory=sqlite3.Row
username,record=sys.argv[2:4]
markers=json.loads(sys.stdin.read())
user=db.execute('SELECT user_id FROM users WHERE username=?',(username,)).fetchone()
assert user
vault=db.execute("SELECT v.vault_id,COALESCE(c.last_committed_seq,0) AS commit_seq,COALESCE(c.last_conflict_seq,0) AS conflict_seq FROM vaults v JOIN vault_members m ON m.vault_id=v.vault_id LEFT JOIN vault_counters c ON c.vault_id=v.vault_id WHERE v.owner_user_id=? AND m.user_id=? AND m.state='active' AND v.state='active' ORDER BY v.created_at LIMIT 1",(user['user_id'],user['user_id'])).fetchone()
assert vault
out={'vaultId':vault['vault_id'],'commitSeq':str(vault['commit_seq']),'conflictSeq':str(vault['conflict_seq'])}
if record:
 out['recordId']=record
 versions=db.execute('SELECT revision_id,base_revision_id,commit_seq,device_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault['vault_id'],record)).fetchall()
 receipts=db.execute('SELECT op_id,device_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault['vault_id'],record)).fetchall()
 events=db.execute('SELECT commit_seq,event_type,revision_id,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault['vault_id'],record)).fetchall()
 head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault['vault_id'],record)).fetchone()
 grave=db.execute('SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?',(vault['vault_id'],record)).fetchone()
 conflicts=db.execute('SELECT conflict_id,base_revision_id,resolved_revision_id,conflict_seq,resolution_seq,device_id,envelope FROM conflicts WHERE vault_id=? AND record_id=? ORDER BY conflict_seq',(vault['vault_id'],record)).fetchall()
 def describe(raw):
  try: env=json.loads(raw)
  except Exception: env={}
  header=env.get('header',{}) if isinstance(env,dict) else {}
  return {'operation':header.get('operation'),'recordId':header.get('record_id'),'revisionId':header.get('revision_id'),'baseRevisionId':header.get('base_revision_id'),'opId':header.get('op_id'),'deviceId':header.get('device_id'),'markerFree':not any(m in raw for m in markers),'shapeValid':isinstance(env,dict) and set(env)=={'header','nonce','ciphertext','signature'} and isinstance(env.get('header'),dict) and isinstance(env.get('nonce'),str) and isinstance(env.get('ciphertext'),str) and isinstance(env.get('signature'),str)}
 out['versions']=[{'revisionId':r['revision_id'],'baseRevisionId':r['base_revision_id'],'commitSeq':str(r['commit_seq']),'deviceId':r['device_id'],'operation':r['operation'],'envelope':describe(r['envelope'])} for r in versions]
 out['receipts']=[{'opId':r['op_id'],'deviceId':r['device_id'],'revisionId':r['revision_id'],'commitSeq':str(r['commit_seq'])} for r in receipts]
 out['events']=[{'commitSeq':str(r['commit_seq']),'eventType':r['event_type'],'revisionId':r['revision_id'],'envelope':describe(r['envelope'])} for r in events]
 out['head']=dict(head) if head else None
 if out['head']: out['head']['commit_seq']=str(out['head']['commit_seq']); out['head']['deleted']=bool(out['head']['deleted'])
 out['graveyard']={'revisionId':grave['deleted_revision'],'commitSeq':str(grave['deleted_seq'])} if grave else None
 out['conflicts']=[]
 for r in conflicts:
  item=describe(r['envelope'])
  out['conflicts'].append({'conflictId':r['conflict_id'],'baseRevisionId':r['base_revision_id'],'resolvedRevisionId':r['resolved_revision_id'],'conflictSeq':str(r['conflict_seq']),'resolutionSeq':str(r['resolution_seq']) if r['resolution_seq'] is not None else None,'deviceId':r['device_id'],'branch':item})
out['totalRecordVersionCount']=db.execute('SELECT COUNT(*) FROM record_versions WHERE vault_id=?',(vault['vault_id'],)).fetchone()[0]
print(json.dumps(out,separators=(',',':')))
`;
  const result = spawnSync('python3', ['-c', script, databasePath, USERNAME, recordId], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 12000,
    stdio: ['pipe', 'pipe', 'ignore'],
    input: JSON.stringify(HOST_MARKERS),
  });
  assertThat(!result.error && result.status === 0, 'isolated sync snapshot query failed');
  try { return JSON.parse(result.stdout); } catch (_) {
    throw new Error('isolated sync snapshot response was invalid');
  }
}

function assertTargetHistory(snapshot, expectedOperations, expectedDeviceIds) {
  const versions = snapshot.versions;
  const events = snapshot.events;
  const receipts = snapshot.receipts;
  assertThat(JSON.stringify(versions.map((item) => item.operation)) ===
    JSON.stringify(expectedOperations), 'record version operation order was incorrect');
  assertThat(JSON.stringify(events.map((item) => item.eventType)) ===
    JSON.stringify(expectedOperations), 'record change-event operation order was incorrect');
  assertThat(versions.length === expectedOperations.length &&
    events.length === expectedOperations.length && receipts.length === expectedOperations.length,
  'record versions, change events and receipts did not have exact matching counts');
  assertThat(versions.every((item, index) => item.deviceId === expectedDeviceIds[index]),
    'record revisions were not authored by the expected devices');
  assertThat(events.every((item, index) => item.commitSeq === versions[index].commitSeq &&
    item.envelope.operation === expectedOperations[index] &&
    item.envelope.recordId === snapshot.recordId &&
    item.envelope.revisionId === versions[index].revisionId && item.envelope.markerFree &&
    item.envelope.shapeValid), 'change event envelopes were invalid or not ciphertext-only');
  assertThat(versions.every((item) => item.envelope.markerFree && item.envelope.shapeValid),
    'server record versions were malformed or contained a plaintext marker');
  assertThat(receipts.every((receipt, index) => receipt.opId === versions[index].envelope.opId &&
    receipt.revisionId === versions[index].revisionId &&
    receipt.deviceId === expectedDeviceIds[index] &&
    receipt.commitSeq === versions[index].commitSeq),
  'operation receipts did not bind exactly to the committed revisions');
  for (let index = 1; index < versions.length; index += 1) {
    assertThat(BigInt(versions[index].commitSeq) === BigInt(versions[index - 1].commitSeq) + 1n,
      'target record commit sequence was not consecutive');
  }
}

function assertNoServerPlaintext() {
  const paths = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`, serverLogPath]
    .filter((filePath) => filePath && fs.existsSync(filePath));
  const matches = [];
  for (const filePath of paths) {
    const bytes = fs.readFileSync(filePath);
    for (const marker of HOST_MARKERS) {
      if (bytes.includes(Buffer.from(marker))) matches.push({ file: path.basename(filePath) });
    }
  }
  assertThat(matches.length === 0 && apiBodyMarkerMatches.length === 0,
    'synthetic Host plaintext marker appeared in server persistence, logs or Vault API bodies');
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'build the current Flutter Web release before this acceptance');
  setStage('isolated Rust server build');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    timeout: 240000,
  });
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated Rust server binary was not built');

  setStage('private fixture directories and server bootstrap');
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-delete-edit-web-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  serverLogPath = path.join(tempRoot, 'server.log');
  const serverLogFd = fs.openSync(serverLogPath, 'a', 0o600);
  const port = await unusedLoopbackPort();
  baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: 'off',
  };
  bootstrapToken = cliToken(serverEnv);
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env: serverEnv,
    detached: true,
    stdio: ['ignore', serverLogFd, serverLogFd],
  });
  await waitForServer(baseUrl, serverProcess);
  fs.closeSync(serverLogFd);

  try {
    setStage('launch persistent Profile A');
    const ownerProfileDir = path.join(tempRoot, 'chromium-profile-a');
    fs.mkdirSync(ownerProfileDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(ownerProfileDir, 0o700);
    const owner = await launchProfile(ownerProfileDir, 'A');
    ownerContext = owner.context;
    await registerOwner(owner.page);
    setStage('Owner registration: verify initialized Vault state');
    const emptyVaultBaseline = readServerSnapshot();
    assertThat(emptyVaultBaseline.totalRecordVersionCount === 0,
      'new Owner Vault unexpectedly contained committed records');

    setStage('create and commit the shared Host baseline');
    await addHost(owner.page);
    const createEvent = await waitTrace((event) =>
      event.profile === 'A' && event.route === 'push' && event.status === 200 && event.bodyRead &&
      event.operations.some((item) => item.operation === 'create'),
    'A Host create receipt');
    const createOp = createEvent.operations.find((item) => item.operation === 'create');
    const createReceipt = createEvent.receipts.find((item) => item.opId === createOp.opId);
    assertThat(createOp?.recordId && createOp.revisionId && createOp.opId &&
      createReceipt?.revisionId === createOp.revisionId &&
      createReceipt?.alreadyCommitted === false,
    'initial Host create did not return its first-commit receipt');

    setStage('launch persistent Profile B and approve its device keys');
    const secondProfileDir = path.join(tempRoot, 'chromium-profile-b');
    fs.mkdirSync(secondProfileDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(secondProfileDir, 0o700);
    const second = await launchProfile(secondProfileDir, 'B');
    secondContext = second.context;
    await enrollSecondDevice(owner.page, second.page);
    await click(second.page, 'Hosts');
    await waitHost(second.page, HOST_ORIGINAL, true);

    setStage('settle both devices and capture exact baseline counters');
    await syncNow(owner.page,
      () => pageErrors.A === 0, 'Owner sync pass');
    await syncNow(second.page,
      () => pageErrors.B === 0, 'Profile B sync pass');
    const baseline = readServerSnapshot();
    assertThat(BigInt(baseline.commitSeq) === BigInt(emptyVaultBaseline.commitSeq) + 1n &&
      baseline.totalRecordVersionCount === emptyVaultBaseline.totalRecordVersionCount + 1 &&
      baseline.conflictSeq === emptyVaultBaseline.conflictSeq,
    'Owner Host creation did not add exactly one Vault revision before the race');
    const ownerCreateVersion = readServerSnapshot(createOp.recordId);
    assertThat(ownerCreateVersion.versions.length === 1 &&
      ownerCreateVersion.versions[0].revisionId === createOp.revisionId &&
      ownerCreateVersion.head.deleted === false && ownerCreateVersion.graveyard === null,
    'committed Host baseline did not contain exactly one live head');
    const ownerDeviceId = createOp.deviceId;
    assertThat(ownerDeviceId && createEvent.deviceId === ownerDeviceId,
      'Owner create request did not identify its signed device');

    setStage('A edits the Host offline while retaining its encrypted outbox');
    const beforeOffline = readServerSnapshot(createOp.recordId);
    await waitFor(() => apiEvents.filter((event) =>
      event.profile === 'A' && event.route === 'push').every((event) => event.bodyRead),
    'earlier Owner push responses to settle', 20000);
    const aPushStart = apiEvents.length;
    await ownerContext.setOffline(true);
    await editHostName(owner.page, HOST_ORIGINAL, HOST_EDITED);
    await owner.page.waitForTimeout(500);
    assertThat(!apiEvents.slice(aPushStart).some((event) =>
      event.profile === 'A' && event.route === 'push' && event.status === 200),
    'offline edit unexpectedly completed a successful sync push');
    const afterOffline = readServerSnapshot(createOp.recordId);
    assertThat(JSON.stringify(afterOffline) === JSON.stringify(beforeOffline),
      'A offline Host edit changed server versions, head, counters or receipts');
    setStage('B deletes its committed copy and commits the tombstone');
    await click(second.page, 'Hosts');
    await deleteHost(second.page, HOST_ORIGINAL);
    await syncNow(second.page, () => successfulPush('B', 'delete', createOp.recordId) !== undefined,
      'B Host tombstone commit');
    const deleteEvent = successfulPush('B', 'delete', createOp.recordId);
    const deleteOp = deleteEvent?.operations.find((item) =>
      item.operation === 'delete' && item.recordId === createOp.recordId);
    const deleteReceipt = deleteEvent?.receipts.find((item) => item.opId === deleteOp?.opId);
    assertThat(deleteOp?.baseRevisionId === createOp.revisionId &&
      deleteOp.deviceId === deleteEvent.deviceId && deleteOp.deviceId !== ownerDeviceId &&
      deleteReceipt?.revisionId === deleteOp.revisionId &&
      deleteReceipt?.alreadyCommitted === false,
    'B delete was not based on the committed Host revision');
    const tombstone = readServerSnapshot(createOp.recordId);
    assertThat(tombstone.versions.length === 2 &&
      tombstone.versions.map((item) => item.operation).join(',') === 'create,delete' &&
      tombstone.head?.revision_id === deleteOp.revisionId &&
      tombstone.head.deleted === true &&
      tombstone.graveyard?.revisionId === deleteOp.revisionId &&
      tombstone.graveyard.commitSeq === tombstone.head.commit_seq,
    'server tombstone/head/graveyard did not match B’s single delete commit');
    const committedBeforeAReconnect = tombstone.commitSeq;
    const conflictSeqBeforeAReconnect = tombstone.conflictSeq;
    await secondContext.setOffline(true);

    setStage('A reconnects; server commits the conflict branch but loses its acknowledgement');
    const conflictRetry = {
      droppedAcknowledgement: false,
      attempts: [],
    };
    const conflictRoutePattern = '**/api/v1/vaults/*/conflicts';
    const dropFirstConflictAcknowledgement = async (route) => {
      const request = route.request();
      if (request.method() !== 'POST') return route.continue();
      let payload;
      try { payload = JSON.parse(request.postData() || ''); } catch (_) {
        return route.continue();
      }
      const operation = safeOperation(payload?.envelope);
      if (operation.recordId !== createOp.recordId || operation.operation !== 'update') {
        return route.continue();
      }

      const response = await route.fetch();
      const successfulCommit = response.status() >= 200 && response.status() < 300;
      const dropAcknowledgement = !conflictRetry.droppedAcknowledgement && successfulCommit;
      conflictRetry.attempts.push({
        operation,
        envelopeFingerprint: envelopeFingerprint(payload.envelope),
        serverStatus: response.status(),
        droppedAcknowledgement: dropAcknowledgement,
      });
      if (dropAcknowledgement) {
        conflictRetry.droppedAcknowledgement = true;
        await route.abort('failed');
      } else {
        await route.fulfill({ response });
      }
    };
    await ownerContext.route(conflictRoutePattern, dropFirstConflictAcknowledgement);
    const conflictUploadStart = apiEvents.length;
    await ownerContext.setOffline(false);
    await waitFor(() => conflictRetry.droppedAcknowledgement,
      'server commit followed by dropped conflict-upload acknowledgement');
    const conflictRetrySucceeded = () => apiEvents.slice(conflictUploadStart).some((event) =>
      event.profile === 'A' && event.route === 'conflict-create' &&
      event.status === 200 && event.bodyRead &&
      event.operations.some((item) => item.operation === 'update' &&
        item.recordId === createOp.recordId));
    // Let a scheduled sync retry run first. If this app build only retries on
    // an explicit Sync action, drive that same client path after the lost ACK.
    await waitFor(conflictRetrySucceeded, 'automatic retry after lost conflict acknowledgement', 5000)
      .catch(() => false);
    if (!conflictRetrySucceeded()) {
      setStage('A retries the unresolved conflict upload after the lost acknowledgement');
      await syncNow(owner.page, conflictRetrySucceeded, 'A conflict-upload retry');
    }
    const conflictUpload = apiEvents.slice(conflictUploadStart).find((event) =>
      event.profile === 'A' && event.route === 'conflict-create' &&
      event.status === 200 && event.bodyRead &&
      event.operations.some((item) => item.operation === 'update' &&
        item.recordId === createOp.recordId));
    await ownerContext.unroute(conflictRoutePattern, dropFirstConflictAcknowledgement);
    const retryFingerprints = new Set(conflictRetry.attempts.map((attempt) =>
      attempt.envelopeFingerprint));
    assertThat(conflictRetry.droppedAcknowledgement && conflictRetry.attempts.length >= 2 &&
      conflictRetry.attempts.filter((attempt) => attempt.droppedAcknowledgement).length === 1 &&
      conflictRetry.attempts[0].serverStatus >= 200 && conflictRetry.attempts[0].serverStatus < 300 &&
      retryFingerprints.size === 1 &&
      conflictRetry.attempts.every((attempt) => attempt.operation.opId === conflictRetry.attempts[0].operation.opId &&
        attempt.operation.revisionId === conflictRetry.attempts[0].operation.revisionId &&
        attempt.operation.deviceId === conflictRetry.attempts[0].operation.deviceId),
    'client did not retry the exact signed conflict envelope after the server committed it and lost the acknowledgement');
    const conflictBranch = conflictUpload.operations.find((item) =>
      item.recordId === createOp.recordId);
    assertThat(conflictBranch?.baseRevisionId === createOp.revisionId &&
      conflictBranch.revisionId !== deleteOp.revisionId &&
      conflictUpload.conflictId,
    'A conflict upload did not preserve its original signed update branch');
    await syncNow(owner.page,
      () => apiEvents.some((event) => event.profile === 'A' &&
        event.route === 'conflict-changes' && event.status === 200 && event.bodyRead &&
        event.changeEvents.some((item) => item.type === 'created' &&
          item.conflictId === conflictUpload.conflictId)),
      'A conflict inbox feed pull');
    await click(owner.page, /^Sync & conflicts(?:\s+\d+)?$/);
    await waitForSemanticText(owner.page, 'Conflict branches');
    await waitForSemanticText(owner.page, 'delete edit');
    await waitForSemanticText(owner.page, 'Local revision');
    await waitForSemanticText(owner.page, 'Remote revision');
    await scrollMainContentUntilSemanticText(owner.page, '分支操作');
    await waitForSemanticText(owner.page, '修改');
    const localOperationState = await visibleConflictProjectionFlags(owner.page);
    assertThat(localOperationState?.conflictBranchOperationLabelVisible === true &&
      localOperationState.conflictEditOperationVisible === true,
    'verified local conflict card did not show its update operation');
    await scrollMainContentUntilSemanticText(owner.page, '已删除');
    await waitForSemanticText(owner.page, '已删除');
    const localHeadState = await visibleConflictProjectionFlags(owner.page);
    assertThat(localHeadState?.currentServerVersionLabelVisible === true &&
      localHeadState.conflictDeletedHeadVisible === true,
    'verified local conflict card did not show the deleted server head');
    // The local CAS conflict card is the one visible representation of this
    // same-record branch. Its verified operation/head metadata appears on the
    // local card above; the cross-device inbox should omit the duplicate.
    await scrollMainContentUntilSemanticText(owner.page, '没有待处理的跨设备分支');
    await waitForSemanticText(owner.page, '没有待处理的跨设备分支');
    const conflictProjection = await visibleConflictProjectionFlags(owner.page);
    assertThat(conflictProjection?.noPendingCrossDeviceBranchVisible === true,
    'the same-record feed branch was not deduplicated behind its local delete-edit conflict card');

    const preResolution = readServerSnapshot(createOp.recordId);
    assertThat(preResolution.commitSeq === committedBeforeAReconnect &&
      BigInt(preResolution.conflictSeq) === BigInt(conflictSeqBeforeAReconnect) + 1n &&
      preResolution.versions.length === 2 && preResolution.events.length === 2 &&
      preResolution.receipts.length === 2 && preResolution.head.deleted === true &&
      preResolution.graveyard?.revisionId === deleteOp.revisionId &&
      preResolution.conflicts.length === 1 &&
      preResolution.conflicts[0].resolvedRevisionId === null &&
      preResolution.conflicts[0].branch.operation === 'update' &&
      preResolution.conflicts[0].branch.revisionId === conflictBranch.revisionId &&
      preResolution.conflicts[0].branch.baseRevisionId === createOp.revisionId &&
      preResolution.conflicts[0].deviceId === ownerDeviceId &&
      preResolution.conflicts[0].branch.deviceId === ownerDeviceId &&
      preResolution.conflicts[0].branch.markerFree &&
      preResolution.conflicts[0].branch.shapeValid,
    'before user choice, server lost the branch, advanced the Host, or cleared its tombstone');
    await click(owner.page, 'Hosts');
    await waitHost(owner.page, HOST_ORIGINAL, false);
    await waitHost(owner.page, HOST_EDITED, false);
    await waitHost(second.page, HOST_ORIGINAL, false);
    assertThat(apiEvents.filter((event) => event.profile === 'A' && event.route === 'push')
      .flatMap((event) => event.operations)
      .filter((operation) => operation.recordId === createOp.recordId &&
        operation.operation === 'restore').length === 0,
    'client silently restored the deleted Host before a user decision');

    setStage('A explicitly keeps its offline version and confirms a new restore revision');
    await click(owner.page, /^Sync & conflicts(?:\s+\d+)?$/);
    const keepLocal = owner.page.getByRole('button', {
      name: 'Keep this device version', exact: true,
    }).first();
    const useSynced = owner.page.getByRole('button', {
      name: 'Use synced version', exact: true,
    }).first();
    await keepLocal.waitFor({ state: 'visible', timeout: 20000 });
    await useSynced.waitFor({ state: 'visible', timeout: 20000 });
    assertThat(await keepLocal.isEnabled() && await useSynced.isEnabled(),
      'both local update and remote delete choices were not available for explicit review');
    await keepLocal.click();
    await waitForSemanticText(owner.page, 'Keep this device version?');
    await click(owner.page, 'Create resolution');
    const restorePush = await waitTrace((event) =>
      event.profile === 'A' && event.route === 'push' && event.status === 200 && event.bodyRead &&
      event.operations.some((item) => item.recordId === createOp.recordId &&
        item.operation === 'restore'),
    'A re-signed restore commit', 45000);
    const restoreOp = restorePush.operations.find((item) =>
      item.recordId === createOp.recordId && item.operation === 'restore');
    const restoreReceipt = restorePush.receipts.find((item) => item.opId === restoreOp?.opId);
    assertThat(restoreOp?.deviceId === ownerDeviceId &&
      restoreOp?.baseRevisionId === deleteOp.revisionId &&
      restoreOp.revisionId !== conflictBranch.revisionId &&
      restoreReceipt?.revisionId === restoreOp.revisionId &&
      restoreReceipt?.alreadyCommitted === false,
    'A resolution did not produce a new A-signed restore based on B’s tombstone');
    const resolvedResponse = await waitTrace((event) =>
      event.profile === 'A' && event.route === 'conflict-resolve' && event.status === 200 && event.bodyRead &&
      event.resolution?.resolvedRevisionId === restoreOp.revisionId,
    'server conflict-resolution receipt', 30000);
    assertThat(resolvedResponse.resolution?.alreadyResolved === false &&
      /^[1-9][0-9]*$/.test(resolvedResponse.resolution?.resolutionSeq || ''),
    'server did not record the explicit resolution against A’s new revision');
    await click(owner.page, 'Hosts');
    await waitHost(owner.page, HOST_EDITED, true);
    await waitHost(owner.page, HOST_ORIGINAL, false);

    setStage('verify exact server commit, tombstone removal and conflict resolution');
    const finalServer = readServerSnapshot(createOp.recordId);
    assertTargetHistory(finalServer, ['create', 'delete', 'restore'], [
      ownerDeviceId,
      deleteOp.deviceId,
      ownerDeviceId,
    ]);
    assertThat(finalServer.versions[0].revisionId === createOp.revisionId &&
      finalServer.versions[1].revisionId === deleteOp.revisionId &&
      finalServer.versions[2].revisionId === restoreOp.revisionId &&
      finalServer.versions[2].baseRevisionId === deleteOp.revisionId &&
      finalServer.versions[2].envelope.opId === restoreOp.opId &&
      finalServer.head?.revision_id === restoreOp.revisionId &&
      finalServer.head?.commit_seq === finalServer.versions[2].commitSeq &&
      finalServer.head.deleted === false && finalServer.graveyard === null,
    'restored Host head did not replace the tombstone with the new resolution revision');
    assertThat(BigInt(finalServer.commitSeq) === BigInt(emptyVaultBaseline.commitSeq) + 3n &&
      finalServer.totalRecordVersionCount === emptyVaultBaseline.totalRecordVersionCount + 3 &&
      BigInt(finalServer.conflictSeq) === BigInt(baseline.conflictSeq) + 2n,
    'Vault commit/conflict sequence deltas were not exactly create+delete+restore and create+resolve');
    assertThat(finalServer.conflicts.length === 1 &&
      finalServer.conflicts[0].conflictId === conflictUpload.conflictId &&
      finalServer.conflicts[0].conflictSeq === String(BigInt(baseline.conflictSeq) + 1n) &&
      finalServer.conflicts[0].resolvedRevisionId === restoreOp.revisionId &&
      finalServer.conflicts[0].resolutionSeq === String(BigInt(baseline.conflictSeq) + 2n) &&
      finalServer.conflicts[0].resolutionSeq === resolvedResponse.resolution.resolutionSeq &&
      finalServer.conflicts[0].branch.operation === 'update' &&
      finalServer.conflicts[0].branch.revisionId === conflictBranch.revisionId &&
      !finalServer.receipts.some((receipt) => receipt.opId === conflictBranch.opId),
    'server did not retain one unresolved-then-resolved signed branch without committing it as a head');
    assertThat(finalServer.versions[0].commitSeq === String(BigInt(emptyVaultBaseline.commitSeq) + 1n) &&
      finalServer.versions[1].commitSeq === String(BigInt(emptyVaultBaseline.commitSeq) + 2n) &&
      finalServer.versions[2].commitSeq === String(BigInt(emptyVaultBaseline.commitSeq) + 3n),
    'record commit sequences did not align with the exact global Vault counter delta');

    setStage('B reconnects and decrypts A’s explicit resolution');
    await secondContext.setOffline(false);
    await syncNow(second.page,
      () => apiEvents.some((event) => event.profile === 'B' && event.route === 'changes' &&
        event.status === 200 && event.bodyRead && event.changeEvents.some((item) =>
          item.recordId === createOp.recordId && item.revisionId === restoreOp.revisionId &&
          item.operation === 'restore')),
      'B pull of A restore revision');
    await click(second.page, 'Hosts');
    await waitHost(second.page, HOST_EDITED, true);
    await waitHost(second.page, HOST_ORIGINAL, false);
    await click(owner.page, 'Hosts');
    await waitHost(owner.page, HOST_EDITED, true);
    assertThat(await hostCard(owner.page, HOST_EDITED).count() === 1 &&
      await hostCard(second.page, HOST_EDITED).count() === 1,
    'A and B did not converge on exactly one edited Host card');
    const afterBPull = readServerSnapshot(createOp.recordId);
    assertThat(JSON.stringify(afterBPull) === JSON.stringify(finalServer),
      'Profile B pull changed the server record history or committed a duplicate');

    setStage('verify ciphertext-only server/API storage and clean both profiles');
    await ownerContext.close();
    ownerContext = undefined;
    await secondContext.close();
    secondContext = undefined;
    await waitFor(() => apiResponseReadsInFlight === 0,
      'Vault API response privacy scans to settle', 10000);
    assertNoServerPlaintext();
    assertThat(pageErrors.A === 0 && pageErrors.B === 0,
      'a browser profile raised an uncaught runtime error');
    await cleanup();
    assertThat(!cleanupFailed, 'fixture cleanup failed');
    console.log('WEB-DELETE-EDIT-01 passed', JSON.stringify({
      persistentIndependentProfiles: true,
      approvedSecondDevice: true,
      offlineUpdateRetained: true,
      tombstoneRemainedUntilExplicitChoice: true,
      deleteEditConflictResolvedByNewSignedRestore: true,
      serverHeadGraveyardEventsReceiptsAndSequencesAligned: true,
      bothProfilesConvergedOnEditedHost: true,
      lostConflictAcknowledgementRetriedSameEnvelope: true,
      conflictUploadAttempts: conflictRetry.attempts.length,
      serverAndVaultApiPlaintextMarkersAbsent: true,
      pageErrors: 0,
      fixtureCleanupComplete: true,
    }));
  } catch (error) {
    const safeFailure = {
      errorName: safeDiagnosticText(error?.name || 'Error'),
      errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure'),
      ownerUi: await safeContextUiState(ownerContext),
      secondUi: await safeContextUiState(secondContext),
      apiStatuses: apiStatusEvents.slice(-18),
    };
    await cleanup();
    console.error(`WEB-DELETE-EDIT-01 failed at ${stage}; safe diagnostics=${JSON.stringify({
      cleanupFailed,
      ...safeFailure,
      pageErrors,
      requestFailures,
      syncApiStatuses: apiEvents.slice(-18).map((event) => ({
        profile: event.profile,
        route: event.route,
        method: event.method,
        status: event.status,
      })),
      markerMatchCount: apiBodyMarkerMatches.length,
    })}`);
    process.exitCode = 1;
  }
}

main().catch(async (error) => {
  const safeFailure = {
    errorName: safeDiagnosticText(error?.name || 'Error'),
    errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure'),
    ownerUi: await safeContextUiState(ownerContext),
    secondUi: await safeContextUiState(secondContext),
    apiStatuses: apiStatusEvents.slice(-18),
  };
  await cleanup();
  console.error(`WEB-DELETE-EDIT-01 failed at ${stage}; safe diagnostics=${JSON.stringify({
    cleanupFailed,
    ...safeFailure,
    pageErrors,
    requestFailures,
    syncApiStatuses: apiEvents.slice(-18).map((event) => ({
      profile: event.profile,
      route: event.route,
      method: event.method,
      status: event.status,
    })),
    markerMatchCount: apiBodyMarkerMatches.length,
  })}`);
  process.exitCode = 1;
});
