/*
 * WEB-DELETE-CRASH-01: A deletes a Host offline, then Chromium is killed before
 * its durable tombstone/outbox is acknowledged. Restart the same profile and
 * device, replay the exact signed operation once, then verify B removes it.
 * Both on-disk profiles, the server, database, and logs are disposable.
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
const { MAX_SQLITE_FILE_BYTES, reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-delete-crash-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `DeleteCrash-${crypto.randomBytes(24).toString('base64url')}9`;
const HOST_ORIGINAL = `delete-crash-host-${RUN_ID.slice(0, 8)}`;
const HOST_USER = `delete-crash-user-${RUN_ID.slice(0, 8)}`;
const HOST_ADDRESS = '192.0.2.45';
const HOST_MARKERS = [HOST_ORIGINAL, HOST_USER, HOST_ADDRESS];
const WEB_STORAGE_IMPLEMENTATIONS = new Set([
  'opfsShared', 'opfsLocks', 'sharedIndexedDb', 'unsafeIndexedDb', 'inMemory',
]);

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let serverLogPath;
let serverProcess;
let serverLogFd;
let ownerContext;
let secondContext;
let ownerProfileDir;
let secondProfileDir;
let ownerPushGate;
let bootstrapToken;
let cleanupPromise;
let cleanupFailed = false;
let ownerOfflineWindow = false;
const apiEvents = [];
const apiStatusEvents = [];
const pageErrors = { A: 0, B: 0 };
const unexpectedRequestFailures = { A: 0, B: 0 };
const expectedOfflineOwnerRequestFailures = {
  push: 0,
  changes: 0,
  conflictChanges: 0,
  auth: 0,
  otherApi: 0,
  nonApi: 0,
};
const apiBodyMarkerMatches = [];
const traceByRequest = new WeakMap();
const driftStorageImplementations = { A: [], B: [] };
const clientSnapshotDiagnostics = [];
let apiResponseReadsInFlight = 0;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function createOwnerPushGate() {
  let release;
  let reached;
  const released = new Promise((resolve) => { release = resolve; });
  const firstReached = new Promise((resolve) => { reached = resolve; });
  return {
    released,
    firstReached,
    markReached: reached,
    release() { release(); },
  };
}

async function waitForOwnerPushGate(gate, timeoutMs = 15000) {
  let timer;
  const reached = await Promise.race([
    gate.firstReached.then(() => true),
    new Promise((resolve) => { timer = setTimeout(() => resolve(false), timeoutMs); }),
  ]);
  clearTimeout(timer);
  assertThat(reached, 'A recovery push did not reach the held network gate within the bounded wait');
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

function safeStorageImplementationSummary() {
  return Object.fromEntries(Object.entries(driftStorageImplementations).map(
    ([profile, values]) => [profile, [...new Set(values)]],
  ));
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

function chromiumProfileHasLiveProcesses(directory) {
  if (!directory || !fs.existsSync('/proc')) return false;
  const expectedArg = `--user-data-dir=${directory}`;
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8').split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (fields[0] !== 'Z' && fields[0] !== 'X') return true;
    } catch (_) {
      // Chromium may exit while /proc is being inspected.
    }
  }
  return false;
}

function chromiumProfileProcessIdentity(directory) {
  assertThat(fs.existsSync('/proc'), 'Chromium crash acceptance requires Linux /proc');
  const expectedArg = `--user-data-dir=${directory}`;
  const matches = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8').split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      matches.push({
        pid: Number(entry),
        processGroup: Number(fields[2]),
        startTimeTicks: fields[19],
      });
    } catch (_) {
      // Ignore Chromium that exits during the /proc scan.
    }
  }
  assertThat(matches.length === 1 && matches[0].processGroup === matches[0].pid,
    'isolated Chromium process group was not uniquely identified');
  return matches[0];
}

async function forceKillChromiumProfile(directory) {
  const identity = chromiumProfileProcessIdentity(directory);
  signalProcessGroup(identity.processGroup, 'SIGKILL');
  assertThat(await waitForProcessGroupExit(identity.processGroup, 5000) &&
    !chromiumProfileHasLiveProcesses(directory),
  'isolated Chromium process group survived SIGKILL');
  return identity;
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    ownerPushGate?.release();
    if (ownerContext) await ownerContext.close().catch(() => {});
    ownerContext = undefined;
    if (secondContext) await secondContext.close().catch(() => {});
    secondContext = undefined;
    for (const directory of [ownerProfileDir, secondProfileDir]) {
      try {
        if (directory && chromiumProfileHasLiveProcesses(directory)) {
          await forceKillChromiumProfile(directory);
        }
      } catch (_) {
        cleanupFailed = true;
      }
    }
    try { await stopServerGroup(serverProcess); } catch (_) { cleanupFailed = true; }
    if (serverLogFd !== undefined) {
      try { fs.closeSync(serverLogFd); } catch (_) { cleanupFailed = true; }
      serverLogFd = undefined;
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupFailed = true;
        else tempRoot = undefined;
      } catch (_) {
        cleanupFailed = true;
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
    envelopeHash: value && typeof value === 'object'
      ? crypto.createHash('sha256').update(stableJson(value)).digest('hex') : null,
  };
}

function attachApiObservation(page, profile) {
  page.on('console', (message) => {
    const match = message.text().match(/^ATERMIUS_DRIFT_WEB_IMPLEMENTATION=(\w+)$/);
    if (!match) return;
    driftStorageImplementations[profile].push(
      WEB_STORAGE_IMPLEMENTATIONS.has(match[1]) ? match[1] : 'unknown',
    );
  });
  page.on('pageerror', () => { pageErrors[profile] += 1; });
  page.on('requestfailed', (request) => {
    let pathname = '';
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    const route = routeFor(pathname);
    const offlineCategory = route === 'push' ? 'push' :
      route === 'changes' ? 'changes' :
        route === 'conflict-changes' ? 'conflictChanges' :
          /^\/api\/v1\/auth\//.test(pathname) ? 'auth' :
            /^\/api\/v1\//.test(pathname) ? 'otherApi' : 'nonApi';
    if (profile === 'A' && ownerOfflineWindow) {
      expectedOfflineOwnerRequestFailures[offlineCategory] += 1;
    } else unexpectedRequestFailures[profile] += 1;
  });
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
  await context.route(/\/api\/v1\/vaults\/[^/]+\/sync\/push$/, async (route) => {
    if (profile === 'A' && ownerPushGate) {
      ownerPushGate.markReached();
      await ownerPushGate.released;
    }
    await route.continue();
  });
  const page = context.pages()[0] || await context.newPage();
  attachApiObservation(page, profile);
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await enableSemantics(page);
  return { context, page };
}

async function safeBrowserStorageDiagnostic(page) {
  return page.evaluate((expectedOrigin) => {
    const kinds = (storage) => {
      const found = new Set();
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key === 'FlutterSecureStorage') found.add('secure-store-key');
        else if (key.endsWith('.device')) found.add('device');
        else if (key.includes('.session.')) found.add('session');
        else if (key.includes('.refresh.')) found.add('refresh');
        else if (key.endsWith('.last-server')) found.add('last-server');
        else if (key.startsWith('FlutterSecureStorage.')) found.add('other-secure-store');
        else found.add('other');
      }
      return [...found].sort();
    };
    const localStorageKinds = kinds(window.localStorage);
    const sessionStorageKinds = kinds(window.sessionStorage);
    return {
      expectedOrigin: window.location.origin === expectedOrigin,
      localStorageKinds,
      sessionStorageKinds,
      deviceRecordPresent: localStorageKinds.includes('device') ||
        sessionStorageKinds.includes('device'),
    };
  }, new URL(baseUrl).origin).catch(() => ({ diagnosticUnavailable: true }));
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
  await fill(page, 'Device name', 'Delete crash A');
  setStage('Owner registration: fill first Vault name');
  await fill(page, 'First Vault', 'Delete crash Vault');
  bootstrapToken = undefined;
  setStage('Owner registration: submit account creation');
  await click(page, 'Create owner account');
  setStage('Owner registration: wait for the workspace');
  await waitWorkspace(page);
}

async function recoverOwnerWorkspace(page) {
  if (await page.getByRole('button', { name: 'Add host', exact: true })
    .isVisible().catch(() => false)) {
    await waitWorkspace(page);
    return;
  }
  const serverUrlField = page.locator(
    `input[aria-label*=${JSON.stringify('Server URL')}],textarea[aria-label*=${JSON.stringify('Server URL')}]`,
  ).first();
  if (await serverUrlField.isVisible().catch(() => false)) {
    await connect(page);
  }
  await field(page, 'Email or username');
  await fill(page, 'Email or username', USERNAME);
  await fill(page, 'Master password', MASTER_PASSWORD);
  await click(page, 'Sign in and unlock');
  await waitWorkspace(page);
}

async function enrollSecondDevice(ownerPage, secondPage) {
  await connect(secondPage);
  await field(secondPage, 'Email or username');
  await click(secondPage, 'Add this device');
  await waitForSemanticText(secondPage, 'Request this device');
  await fill(secondPage, 'Account email', USERNAME);
  await fill(secondPage, 'Device name', 'Delete crash B');
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
import hashlib,json,sqlite3,sys
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
  canonical=json.dumps(env,sort_keys=True,separators=(',',':'),ensure_ascii=False)
  return {'operation':header.get('operation'),'recordId':header.get('record_id'),'revisionId':header.get('revision_id'),'baseRevisionId':header.get('base_revision_id'),'opId':header.get('op_id'),'deviceId':header.get('device_id'),'envelopeSha256':hashlib.sha256(canonical.encode()).hexdigest(),'markerFree':not any(m in raw for m in markers),'shapeValid':isinstance(env,dict) and set(env)=={'header','nonce','ciphertext','signature'} and isinstance(env.get('header'),dict) and isinstance(env.get('nonce'),str) and isinstance(env.get('ciphertext'),str) and isinstance(env.get('signature'),str)}
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

async function readClientDatabaseFiles(page) {
  return page.evaluate(async (maxBytes) => {
    if (typeof indexedDB.databases !== 'function') {
      return { available: false, reason: 'database-list-unavailable' };
    }
    const databases = await indexedDB.databases();
    if (!databases.some((database) => database.name === 'atermius_vault')) {
      return { available: false, reason: 'vault-database-missing' };
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
        return { available: false, reason: 'sqlite-file-stores-missing' };
      }
      const filesTx = connection.transaction('files', 'readonly');
      const filesDone = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('IDB files read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('IDB files read aborted'));
      });
      const metadataStore = filesTx.objectStore('files');
      const [values, ids] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = metadataStore.getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB metadata read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = metadataStore.getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB metadata keys read failed'));
        }),
        filesDone,
      ]);
      const selected = values.map((value, index) => ({
        fileId: Number(ids[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal');
      if (!selected.some((file) => file.name === '/database')) {
        return { available: false, reason: 'sqlite-database-file-missing' };
      }
      if (selected.some((file) => !Number.isSafeInteger(file.fileId) ||
          !Number.isSafeInteger(file.length) || file.length < 0 || file.length > maxBytes)) {
        return { available: false, reason: 'sqlite-file-size-out-of-range' };
      }

      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksDone = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('IDB blocks read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('IDB blocks read aborted'));
      });
      const blocksStore = blocksTx.objectStore('blocks');
      const filesWithBlocks = await Promise.all([
        ...selected.map(async (file) => {
          const range = IDBKeyRange.bound([file.fileId, 0], [file.fileId, 9007199254740992]);
          const [keys, blockValues] = await Promise.all([
            new Promise((resolve, reject) => {
              const request = blocksStore.getAllKeys(range);
              request.onsuccess = () => resolve(request.result || []);
              request.onerror = () => reject(request.error || new Error('IDB block keys read failed'));
            }),
            new Promise((resolve, reject) => {
              const request = blocksStore.getAll(range);
              request.onsuccess = () => resolve(request.result || []);
              request.onerror = () => reject(request.error || new Error('IDB blocks read failed'));
            }),
          ]);
          const blocks = [];
          for (let index = 0; index < keys.length; index += 1) {
            const value = blockValues[index];
            let bytes;
            if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
            else if (ArrayBuffer.isView(value)) {
              bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            } else if (value instanceof Blob) bytes = new Uint8Array(await value.arrayBuffer());
            else throw new Error('unsupported SQLite block value');
            let binary = '';
            for (let offset = 0; offset < bytes.length; offset += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
            }
            blocks.push({ offset: Number(keys[index]?.[1]), base64: btoa(binary) });
          }
          return { ...file, blocks };
        }),
        blocksDone,
      ]);
      return {
        available: true,
        databaseName: 'atermius_vault',
        sqliteFiles: filesWithBlocks.filter((file) => file && file.name),
      };
    } finally {
      connection.close();
    }
  }, MAX_SQLITE_FILE_BYTES);
}

function inspectClientDeleteSnapshot(sqliteFiles, vaultId, recordId) {
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { available: false, reason: journalFile
      ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  const snapshotPath = path.join(tempRoot, `client-delete-snapshot-${crypto.randomUUID()}.sqlite`);
  let bytes;
  try {
    bytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { available: false, reason: 'sqlite-block-reconstruction-failed' };
  }
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'wx' });
  fs.chmodSync(snapshotPath, 0o600);
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id=sys.argv[2:4]',
    'markers=json.loads(sys.stdin.read())',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "record=db.execute('SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    "rows=db.execute(\"SELECT op_id,vault_id,record_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    "vault_count=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    "all_records=db.execute('SELECT vault_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE record_id=? ORDER BY vault_id',(record_id,)).fetchall()",
    "all_pending=db.execute('SELECT vault_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE record_id=? ORDER BY created_at,op_id',(record_id,)).fetchall()",
    'def describe(raw):',
    '    value=json.loads(raw)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    header=value.get("header",{})',
    '    return {"envelopeSha256":hashlib.sha256(canonical.encode()).hexdigest(),"operation":header.get("operation"),"recordId":header.get("record_id"),"revisionId":header.get("revision_id"),"baseRevisionId":header.get("base_revision_id"),"opId":header.get("op_id"),"deviceId":header.get("device_id"),"markerFree":not any(marker in raw for marker in markers),"shapeValid":isinstance(value,dict) and set(value)=={"header","nonce","ciphertext","signature"}}',
    'pending=[]',
    'for row in rows:',
    '    operation=describe(row[5])',
    '    pending.append({"opId":row[0],"vaultKeyMatchesExpected":row[1]==vault_id,"recordId":row[2],"baseRevisionId":row[3],"baseEnvelopePresent":row[4] is not None,"status":row[6],**operation})',
    'record_summary=None',
    'if record:',
    '    detail=describe(record[1])',
    '    record_summary={"vaultKeyMatchesExpected":True,"revisionId":record[0],"commitSeq":str(record[2]) if record[2] is not None else None,"isDeleted":bool(record[3]),**detail}',
    'record_rows=[]',
    'for row in all_records:',
    '    detail=describe(row[1])',
    '    record_rows.append({"vaultKeyMatchesExpected":row[0]==vault_id,"operation":detail["operation"],"isDeleted":bool(row[3]),"commitSeqPresent":row[2] is not None,"envelopeSha256":detail["envelopeSha256"]})',
    'pending_rows=[]',
    'for row in all_pending:',
    '    detail=describe(row[2])',
    '    pending_rows.append({"vaultKeyMatchesExpected":row[0]==vault_id,"operation":detail["operation"],"baseEnvelopePresent":row[1] is not None,"envelopeSha256":detail["envelopeSha256"]})',
    'print(json.dumps({"integrityCheck":integrity,"record":record_summary,"pending":pending,"pendingCount":len(rows),"vaultPendingCount":vault_count,"recordRowCountAcrossVaults":len(record_rows),"recordRowsAcrossVaults":record_rows,"pendingRowCountAcrossVaults":len(pending_rows),"pendingRowsAcrossVaults":pending_rows},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId, recordId], {
      encoding: 'utf8', timeout: 12000, maxBuffer: 8192,
      stdio: ['pipe', 'pipe', 'ignore'], input: JSON.stringify(HOST_MARKERS),
    });
    if (result.error || result.status !== 0) {
      return { available: false, reason: 'sqlite-query-failed' };
    }
    return {
      ...JSON.parse(result.stdout),
      available: true,
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function snapshotClientDelete(page, vaultId, recordId) {
  const stored = await readClientDatabaseFiles(page);
  assertThat(stored?.available === true,
    `actual IndexedDB SQLite snapshot unavailable: ${stored?.reason || 'unknown'}`);
  const snapshot = inspectClientDeleteSnapshot(stored.sqliteFiles, vaultId, recordId);
  assertThat(snapshot?.available === true && snapshot.integrityCheck === 'ok',
    `actual IndexedDB delete snapshot invalid: ${snapshot?.reason || snapshot?.integrityCheck || 'unknown'}`);
  return snapshot;
}

async function waitForDurableDeleteSnapshot(page, vaultId, recordId, timeoutMs = 15000) {
  let latestSnapshot;
  await waitFor(async () => {
    try {
      latestSnapshot = await snapshotClientDelete(page, vaultId, recordId);
      return latestSnapshot.record?.isDeleted === true &&
        latestSnapshot.pendingCount === 1 &&
        latestSnapshot.pending?.[0]?.operation === 'delete';
    } catch (_) {
      return false;
    }
  }, 'durable encrypted Host tombstone in IndexedDB', timeoutMs);
  return latestSnapshot;
}

function deleteSnapshotStructure(snapshot, expected) {
  const record = snapshot?.record || null;
  const pendingRows = Array.isArray(snapshot?.pending) ? snapshot.pending : [];
  const recordRowsAcrossVaults = Array.isArray(snapshot?.recordRowsAcrossVaults)
    ? snapshot.recordRowsAcrossVaults : [];
  const pendingRowsAcrossVaults = Array.isArray(snapshot?.pendingRowsAcrossVaults)
    ? snapshot.pendingRowsAcrossVaults : [];
  const pending = pendingRows[0] || null;
  const enumValue = (value, allowed) =>
    typeof value === 'string' && allowed.includes(value) ? value :
      value == null ? 'missing' : 'other';
  const safeHash = (value) =>
    typeof value === 'string' && /^[0-9a-f]{64}$/.test(value) ? value : null;
  const comparison = (actual, wanted) => wanted == null ? 'not-checked' :
    actual === wanted ? 'matched' : 'mismatch';
  return {
    available: snapshot?.available === true,
    integrity: enumValue(snapshot?.integrityCheck, ['ok']),
    recordPresent: record !== null,
    recordVaultKeyMatchesExpected: record?.vaultKeyMatchesExpected === true,
    recordDeleted: typeof record?.isDeleted === 'boolean' ? record.isDeleted : null,
    recordCommitSeq: record ? (record.commitSeq === null ? 'null' : 'set') : 'missing',
    recordOperation: enumValue(record?.operation, ['delete', 'create', 'update']),
    recordEnvelopeShapeValid: record?.shapeValid === true,
    recordMarkerFree: record?.markerFree === true,
    pendingRowCount: pendingRows.length,
    pendingCount: Number.isSafeInteger(snapshot?.pendingCount) ? snapshot.pendingCount : null,
    vaultPendingCount: Number.isSafeInteger(snapshot?.vaultPendingCount)
      ? snapshot.vaultPendingCount : null,
    recordRowCountAcrossVaults: Number.isSafeInteger(snapshot?.recordRowCountAcrossVaults)
      ? snapshot.recordRowCountAcrossVaults : null,
    recordRowsAcrossVaults: recordRowsAcrossVaults.map((row) => ({
      vaultKeyMatchesExpected: row?.vaultKeyMatchesExpected === true,
      operation: enumValue(row?.operation, ['delete', 'create', 'update']),
      isDeleted: typeof row?.isDeleted === 'boolean' ? row.isDeleted : null,
      commitSeqPresent: typeof row?.commitSeqPresent === 'boolean'
        ? row.commitSeqPresent : null,
      envelopeSha256: safeHash(row?.envelopeSha256),
    })),
    pendingRowCountAcrossVaults: Number.isSafeInteger(snapshot?.pendingRowCountAcrossVaults)
      ? snapshot.pendingRowCountAcrossVaults : null,
    pendingRowsAcrossVaults: pendingRowsAcrossVaults.map((row) => ({
      vaultKeyMatchesExpected: row?.vaultKeyMatchesExpected === true,
      operation: enumValue(row?.operation, ['delete', 'create', 'update']),
      baseEnvelopePresent: row?.baseEnvelopePresent === true,
      envelopeSha256: safeHash(row?.envelopeSha256),
    })),
    pendingOperation: enumValue(pending?.operation, ['delete', 'create', 'update']),
    pendingStatus: enumValue(pending?.status, ['queued', 'sent', 'cas_wait', 'conflict']),
    pendingBaseEnvelopePresent: pending?.baseEnvelopePresent === true,
    pendingEnvelopeShapeValid: pending?.shapeValid === true,
    pendingMarkerFree: pending?.markerFree === true,
    recordRevisionMatchesPending: Boolean(record && pending &&
      record.revisionId === pending.revisionId),
    recordEnvelopeMatchesPending: Boolean(record && pending &&
      record.envelopeSha256 === pending.envelopeSha256),
    pendingMatchesExpectedOperation: comparison(pending?.opId, expected?.opId),
    pendingMatchesExpectedRevision: comparison(pending?.revisionId, expected?.revisionId),
    pendingMatchesExpectedEnvelope: comparison(pending?.envelopeSha256, expected?.envelopeSha256),
    pendingBaseRevisionMatchesExpected: comparison(
      pending?.baseRevisionId, expected?.baseRevisionId,
    ),
    pendingDeviceMatchesExpected: comparison(pending?.deviceId, expected?.deviceId),
  };
}

async function main() {
  assertThat(fs.existsSync('/proc'), 'Chromium process isolation requires Linux /proc');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'build the current Flutter Web release before this acceptance');
  setStage('isolated Rust server build');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], { timeout: 240000 });
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated Rust server binary was not built');

  setStage('private fixture directories and server bootstrap');
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-delete-crash-web-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  serverLogPath = path.join(tempRoot, 'server.log');
  serverLogFd = fs.openSync(serverLogPath, 'a', 0o600);
  const port = await unusedLoopbackPort();
  baseUrl = 'http://127.0.0.1:' + port;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: '127.0.0.1:' + port,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: 'sqlite://' + databasePath + '?mode=rwc',
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: 'off',
  };
  bootstrapToken = cliToken(serverEnv);
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT, env: serverEnv, detached: true,
    stdio: ['ignore', serverLogFd, serverLogFd],
  });
  await waitForServer(baseUrl, serverProcess);
  fs.closeSync(serverLogFd);
  serverLogFd = undefined;

  setStage('launch persistent Profile A and register the owner device');
  ownerProfileDir = path.join(tempRoot, 'chromium-profile-a');
  fs.mkdirSync(ownerProfileDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(ownerProfileDir, 0o700);
  const owner = await launchProfile(ownerProfileDir, 'A');
  ownerContext = owner.context;
  await registerOwner(owner.page);
  const emptyVault = readServerSnapshot();
  assertThat(emptyVault.totalRecordVersionCount === 0,
    'new Owner Vault unexpectedly contained committed records');

  setStage('A creates and commits the Host baseline');
  await addHost(owner.page);
  const createEvent = await waitTrace((event) =>
    event.profile === 'A' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) => item.operation === 'create'),
  'A Host create receipt');
  const createOp = createEvent.operations.find((item) => item.operation === 'create');
  const createReceipt = createEvent.receipts.find((item) => item.opId === createOp?.opId);
  assertThat(createOp?.recordId && createOp.revisionId && createOp.opId &&
    createOp.deviceId && createReceipt?.revisionId === createOp.revisionId &&
    createReceipt?.alreadyCommitted === false,
  'initial Host create did not return its first-commit receipt');
  const ownerDeviceId = createOp.deviceId;
  assertThat(createEvent.deviceId === ownerDeviceId,
    'Owner create request did not identify its signed device');
  const afterCreate = readServerSnapshot(createOp.recordId);
  assertThat(afterCreate.versions.length === 1 &&
    afterCreate.versions[0].operation === 'create' &&
    afterCreate.versions[0].revisionId === createOp.revisionId &&
    afterCreate.versions[0].envelope.envelopeSha256 === createOp.envelopeHash &&
    afterCreate.head?.deleted === false && afterCreate.graveyard === null &&
    afterCreate.conflicts.length === 0,
  'server did not commit exactly one encrypted Host create');

  setStage('B enrolls and pulls A’s committed Host');
  secondProfileDir = path.join(tempRoot, 'chromium-profile-b');
  fs.mkdirSync(secondProfileDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(secondProfileDir, 0o700);
  const second = await launchProfile(secondProfileDir, 'B');
  secondContext = second.context;
  await enrollSecondDevice(owner.page, second.page);
  await click(second.page, 'Hosts');
  await waitHost(second.page, HOST_ORIGINAL, true);
  await waitTrace((event) =>
    event.profile === 'B' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === createOp.recordId && item.revisionId === createOp.revisionId &&
      item.operation === 'create'),
  'B pull of the committed Host create');
  await waitFor(() => apiResponseReadsInFlight === 0 && apiEvents
    .filter((event) => event.profile === 'A' && event.route === 'push')
    .every((event) => event.bodyRead), 'initial push responses to settle', 20000);
  const ledgerBeforeDelete = readServerSnapshot(createOp.recordId);
  assertThat(BigInt(ledgerBeforeDelete.commitSeq) === BigInt(emptyVault.commitSeq) + 1n &&
    ledgerBeforeDelete.totalRecordVersionCount === emptyVault.totalRecordVersionCount + 1 &&
    ledgerBeforeDelete.versions.length === 1 && ledgerBeforeDelete.receipts.length === 1,
  'Host baseline did not add exactly one server commit');

  setStage('verify A client cache contains the committed create head before deletion');
  const localCreateHead = await snapshotClientDelete(
    owner.page, ledgerBeforeDelete.vaultId, createOp.recordId,
  );
  clientSnapshotDiagnostics.push({
    checkpoint: 'before-delete',
    ...deleteSnapshotStructure(localCreateHead, {
      revisionId: createOp.revisionId,
      envelopeSha256: createOp.envelopeHash,
    }),
  });
  assertThat(localCreateHead.record?.vaultKeyMatchesExpected === true &&
    localCreateHead.record?.operation === 'create' &&
    localCreateHead.record?.revisionId === createOp.revisionId &&
    localCreateHead.record?.envelopeSha256 === createOp.envelopeHash &&
    localCreateHead.record?.commitSeq === createReceipt.commitSeq &&
    localCreateHead.record?.isDeleted === false &&
    localCreateHead.pendingCount === 0 && localCreateHead.vaultPendingCount === 0 &&
    localCreateHead.recordRowCountAcrossVaults === 1 &&
    localCreateHead.recordRowsAcrossVaults[0]?.vaultKeyMatchesExpected === true &&
    localCreateHead.recordRowsAcrossVaults[0]?.operation === 'create' &&
    localCreateHead.recordRowsAcrossVaults[0]?.isDeleted === false &&
    localCreateHead.recordRowsAcrossVaults[0]?.commitSeqPresent === true &&
    localCreateHead.recordRowsAcrossVaults[0]?.envelopeSha256 === createOp.envelopeHash,
  `A client cache did not contain the exact committed create head before delete: ${JSON.stringify({
    snapshot: deleteSnapshotStructure(localCreateHead, {
      revisionId: createOp.revisionId,
      envelopeSha256: createOp.envelopeHash,
    }),
    storageImplementation: safeStorageImplementationSummary().A,
  })}`);

  setStage('A goes offline and durably deletes the Host locally');
  ownerOfflineWindow = true;
  await ownerContext.setOffline(true);
  await deleteHost(owner.page, HOST_ORIGINAL);
  await waitHost(owner.page, HOST_ORIGINAL, false);
  const localBeforeCrash = await waitForDurableDeleteSnapshot(
    owner.page, ledgerBeforeDelete.vaultId, createOp.recordId,
  );
  clientSnapshotDiagnostics.push({
    checkpoint: 'after-offline-delete',
    ...deleteSnapshotStructure(localBeforeCrash, {
      baseRevisionId: createOp.revisionId,
      deviceId: ownerDeviceId,
    }),
  });
  assertThat(localBeforeCrash.record?.isDeleted === true &&
    localBeforeCrash.record.revisionId === localBeforeCrash.pending?.[0]?.revisionId &&
    localBeforeCrash.record.envelopeSha256 === localBeforeCrash.pending?.[0]?.envelopeSha256 &&
    localBeforeCrash.record.commitSeq === null &&
    localBeforeCrash.pendingCount === 1 && localBeforeCrash.vaultPendingCount === 1 &&
    localBeforeCrash.pending[0].operation === 'delete' &&
    localBeforeCrash.pending[0].recordId === createOp.recordId &&
    localBeforeCrash.pending[0].vaultKeyMatchesExpected === true &&
    localBeforeCrash.pending[0].baseRevisionId === createOp.revisionId &&
    localBeforeCrash.pending[0].baseEnvelopePresent &&
    localBeforeCrash.pending[0].deviceId === ownerDeviceId &&
    ['queued', 'sent'].includes(localBeforeCrash.pending[0].status) &&
    localBeforeCrash.pending[0].markerFree && localBeforeCrash.pending[0].shapeValid &&
    localBeforeCrash.record.markerFree && localBeforeCrash.record.shapeValid,
  `durable SQLite snapshot did not contain the exact pending Host tombstone: ${JSON.stringify(
    deleteSnapshotStructure(localBeforeCrash, {
      baseRevisionId: createOp.revisionId,
      deviceId: ownerDeviceId,
    }),
  )}`);
  const deleteOperation = localBeforeCrash.pending[0];
  assertThat(!apiEvents.some((event) => event.profile === 'A' && event.route === 'push' &&
    event.status === 200 && event.operations.some((item) => item.opId === deleteOperation.opId)),
  'offline Host deletion was acknowledged before the crash boundary');
  assertThat(JSON.stringify(readServerSnapshot(createOp.recordId)) ===
    JSON.stringify(ledgerBeforeDelete),
  'offline Host deletion changed the server ledger before crash recovery');
  assertThat(pageErrors.A === 0 && pageErrors.B === 0 &&
    unexpectedRequestFailures.A === 0 && unexpectedRequestFailures.B === 0,
  'browser reported a page or request error before the crash boundary');

  setStage('confirm A device key is durably stored before hard termination');
  const storageBeforeKill = await safeBrowserStorageDiagnostic(owner.page);
  assertThat(storageBeforeKill.expectedOrigin === true &&
    storageBeforeKill.deviceRecordPresent === true,
  'A trusted Web device key was not visible in persistent browser storage before SIGKILL');
  await owner.page.waitForTimeout(15000);
  const storageAfterSettle = await safeBrowserStorageDiagnostic(owner.page);
  assertThat(storageAfterSettle.expectedOrigin === true &&
    storageAfterSettle.deviceRecordPresent === true,
  'A trusted Web device key disappeared before SIGKILL');
  const localImmediatelyBeforeKill = await snapshotClientDelete(
    owner.page, ledgerBeforeDelete.vaultId, createOp.recordId,
  );
  assertThat(localImmediatelyBeforeKill.record?.isDeleted === true &&
    localImmediatelyBeforeKill.record?.revisionId === deleteOperation.revisionId &&
    localImmediatelyBeforeKill.record?.envelopeSha256 === deleteOperation.envelopeSha256 &&
    localImmediatelyBeforeKill.record?.commitSeq === null &&
    localImmediatelyBeforeKill.pendingCount === 1 &&
    localImmediatelyBeforeKill.pending?.[0]?.opId === deleteOperation.opId &&
    localImmediatelyBeforeKill.pending?.[0]?.revisionId === deleteOperation.revisionId &&
    localImmediatelyBeforeKill.pending?.[0]?.envelopeSha256 === deleteOperation.envelopeSha256,
  'durable tombstone changed while A device storage settled before SIGKILL');

  setStage('SIGKILL only A Chromium process group');
  const aIdentityBeforeKill = chromiumProfileProcessIdentity(ownerProfileDir);
  const bIdentityBeforeKill = chromiumProfileProcessIdentity(secondProfileDir);
  assertThat(aIdentityBeforeKill.processGroup !== bIdentityBeforeKill.processGroup &&
    aIdentityBeforeKill.pid !== bIdentityBeforeKill.pid,
  'A and B Chromium profiles did not have separate process groups');
  assertThat(processGroupHasLiveMembers(serverProcess.pid) &&
    processGroupHasLiveMembers(bIdentityBeforeKill.processGroup),
  'server or Profile B was not alive immediately before A termination');
  signalProcessGroup(aIdentityBeforeKill.processGroup, 'SIGKILL');
  assertThat(await waitForProcessGroupExit(aIdentityBeforeKill.processGroup, 5000) &&
    !chromiumProfileHasLiveProcesses(ownerProfileDir),
  'A Chromium process group survived SIGKILL');
  ownerOfflineWindow = false;
  ownerContext = undefined;
  assertThat(processGroupHasLiveMembers(bIdentityBeforeKill.processGroup) &&
    processGroupHasLiveMembers(serverProcess.pid),
  'A-only SIGKILL also stopped Profile B or the isolated server');
  const bIdentityAfterKill = chromiumProfileProcessIdentity(secondProfileDir);
  assertThat(bIdentityAfterKill.processGroup === bIdentityBeforeKill.processGroup &&
    bIdentityAfterKill.startTimeTicks === bIdentityBeforeKill.startTimeTicks,
  'Profile B Chromium identity changed during A-only termination');
  assertThat(JSON.stringify(readServerSnapshot(createOp.recordId)) ===
    JSON.stringify(ledgerBeforeDelete),
  'server ledger changed while A Chromium was terminated');

  setStage('restart the same A profile with its push held for local recovery inspection');
  ownerPushGate = createOwnerPushGate();
  const restartedOwner = await launchProfile(ownerProfileDir, 'A');
  ownerContext = restartedOwner.context;
  const storageAfterCrash = await safeBrowserStorageDiagnostic(restartedOwner.page);
  assertThat(storageAfterCrash.expectedOrigin === true &&
    storageAfterCrash.deviceRecordPresent === true,
  'A trusted Web device key was not present after the same-profile SIGKILL restart');
  await recoverOwnerWorkspace(restartedOwner.page);
  await click(restartedOwner.page, 'Hosts');
  await waitHost(restartedOwner.page, HOST_ORIGINAL, false);
  await waitForOwnerPushGate(ownerPushGate);
  assertThat(JSON.stringify(readServerSnapshot(createOp.recordId)) ===
    JSON.stringify(ledgerBeforeDelete),
  'server ledger changed while the restarted A push was held at the recovery gate');
  const localAfterRestart = await snapshotClientDelete(
    restartedOwner.page, ledgerBeforeDelete.vaultId, createOp.recordId,
  );
  clientSnapshotDiagnostics.push({
    checkpoint: 'after-restart-before-push',
    ...deleteSnapshotStructure(localAfterRestart, deleteOperation),
  });
  assertThat(localAfterRestart.record?.isDeleted === true &&
    localAfterRestart.record.revisionId === deleteOperation.revisionId &&
    localAfterRestart.record.envelopeSha256 === deleteOperation.envelopeSha256 &&
    localAfterRestart.record.commitSeq === null &&
    localAfterRestart.pendingCount === 1 && localAfterRestart.vaultPendingCount === 1 &&
    localAfterRestart.pending.length === 1 &&
    localAfterRestart.pending[0].opId === deleteOperation.opId &&
    localAfterRestart.pending[0].revisionId === deleteOperation.revisionId &&
    localAfterRestart.pending[0].envelopeSha256 === deleteOperation.envelopeSha256 &&
    localAfterRestart.pending[0].baseRevisionId === createOp.revisionId &&
    localAfterRestart.pending[0].deviceId === ownerDeviceId &&
    ['queued', 'sent'].includes(localAfterRestart.pending[0].status) &&
    localAfterRestart.pending[0].markerFree && localAfterRestart.pending[0].shapeValid,
  `same-profile restart did not recover the identical tombstone and outbox envelope: ${JSON.stringify(
    deleteSnapshotStructure(localAfterRestart, deleteOperation),
  )}`);
  assertThat(JSON.stringify(readServerSnapshot(createOp.recordId)) ===
    JSON.stringify(ledgerBeforeDelete),
  'A startup replay committed before the durable recovery snapshot was verified');
  assertThat(await hostCard(second.page, HOST_ORIGINAL).isVisible().catch(() => false),
    'B lost its Host before pulling the recovered delete');

  setStage('restore A network and replay the exact pending tombstone');
  await ownerContext.setOffline(false);
  ownerPushGate.release();
  ownerPushGate = null;
  await syncNow(restartedOwner.page,
    () => successfulPush('A', 'delete', createOp.recordId) !== undefined,
    'A recovered delete receipt');
  const recoveredPush = await waitTrace((event) =>
    event.profile === 'A' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) =>
      item.opId === deleteOperation.opId && item.operation === 'delete'),
  'A recovered tombstone push');
  const recoveredOperation = recoveredPush.operations.find((item) =>
    item.opId === deleteOperation.opId);
  const recoveredReceipt = recoveredPush.receipts.find((item) =>
    item.opId === deleteOperation.opId);
  assertThat(recoveredOperation?.recordId === createOp.recordId &&
    recoveredOperation.revisionId === deleteOperation.revisionId &&
    recoveredOperation.baseRevisionId === createOp.revisionId &&
    recoveredOperation.deviceId === ownerDeviceId &&
    recoveredOperation.envelopeHash === deleteOperation.envelopeSha256 &&
    recoveredReceipt?.revisionId === deleteOperation.revisionId &&
    recoveredReceipt?.alreadyCommitted === false,
  'replayed push changed its operation identity or envelope hash');

  const afterDeleteCommit = readServerSnapshot(createOp.recordId);
  assertTargetHistory(afterDeleteCommit, ['create', 'delete'], [ownerDeviceId, ownerDeviceId]);
  const committedDeleteVersion = afterDeleteCommit.versions[1];
  assertThat(afterDeleteCommit.versions.length === 2 &&
    afterDeleteCommit.events.length === 2 && afterDeleteCommit.receipts.length === 2 &&
    afterDeleteCommit.totalRecordVersionCount === emptyVault.totalRecordVersionCount + 2 &&
    BigInt(afterDeleteCommit.commitSeq) === BigInt(emptyVault.commitSeq) + 2n &&
    committedDeleteVersion.revisionId === deleteOperation.revisionId &&
    committedDeleteVersion.baseRevisionId === createOp.revisionId &&
    committedDeleteVersion.envelope.opId === deleteOperation.opId &&
    committedDeleteVersion.envelope.envelopeSha256 === deleteOperation.envelopeSha256 &&
    committedDeleteVersion.envelope.deviceId === ownerDeviceId &&
    afterDeleteCommit.head?.revision_id === deleteOperation.revisionId &&
    afterDeleteCommit.head.deleted === true &&
    afterDeleteCommit.graveyard?.revisionId === deleteOperation.revisionId &&
    afterDeleteCommit.graveyard.commitSeq === afterDeleteCommit.head.commit_seq &&
    afterDeleteCommit.conflictSeq === emptyVault.conflictSeq &&
    afterDeleteCommit.conflicts.length === 0 &&
    recoveredReceipt?.commitSeq === committedDeleteVersion.commitSeq,
  'server did not persist exactly one commit for the recovered signed tombstone');
  const localAfterAck = await snapshotClientDelete(
    restartedOwner.page, ledgerBeforeDelete.vaultId, createOp.recordId,
  );
  assertThat(localAfterAck.record?.isDeleted === true &&
    localAfterAck.record.revisionId === deleteOperation.revisionId &&
    localAfterAck.record.envelopeSha256 === deleteOperation.envelopeSha256 &&
    localAfterAck.record.commitSeq === recoveredReceipt.commitSeq &&
    localAfterAck.pendingCount === 0 && localAfterAck.vaultPendingCount === 0,
  'A did not durably acknowledge the same tombstone after its single server commit');

  setStage('B pulls the recovered tombstone and removes its Host');
  await syncNow(second.page,
    () => apiEvents.some((event) => event.profile === 'B' && event.route === 'changes' &&
      event.status === 200 && event.bodyRead && event.changeEvents.some((item) =>
        item.recordId === createOp.recordId &&
        item.revisionId === deleteOperation.revisionId && item.operation === 'delete')),
    'B pull of the committed Host tombstone');
  await click(second.page, 'Hosts');
  await waitHost(second.page, HOST_ORIGINAL, false);
  await waitHost(restartedOwner.page, HOST_ORIGINAL, false);
  const afterBPull = readServerSnapshot(createOp.recordId);
  assertThat(JSON.stringify(afterBPull) === JSON.stringify(afterDeleteCommit),
    'B pull changed the server ledger or created a duplicate delete commit');

  setStage('verify safe storage, zero runtime/unexpected request errors, and cleanup');
  await restartedOwner.context.close();
  ownerContext = undefined;
  await secondContext.close();
  secondContext = undefined;
  await waitFor(() => apiResponseReadsInFlight === 0,
    'Vault API response privacy scans to settle', 10000);
  assertNoServerPlaintext();
  assertThat(pageErrors.A === 0 && pageErrors.B === 0,
    'a browser profile raised an uncaught runtime error');
  assertThat(unexpectedRequestFailures.A === 0 && unexpectedRequestFailures.B === 0,
    'a browser profile reported an unexpected failed request outside A offline mode');
  assertThat(!chromiumProfileHasLiveProcesses(ownerProfileDir) &&
    !chromiumProfileHasLiveProcesses(secondProfileDir),
  'a Chromium process remained alive after its profile was closed');
  await cleanup();
  assertThat(!cleanupFailed && !tempRoot && !processGroupHasLiveMembers(serverProcess.pid),
    'isolated server, browser profiles, or temporary files were not cleaned up');
  console.log('WEB-DELETE-CRASH-01 passed', JSON.stringify({
    twoIndependentDeviceProfiles: true,
    BObservedAHostBeforeDeletion: true,
    ADeletedOfflineAndPersistedSQLiteTombstone: true,
    indexedDbReconstructedFromSqliteBlocks: true,
    onlyAChromiumProcessGroupWasSigkilled: true,
    sameProfileDeviceRecoveredStableOperationRevisionAndEnvelopeHash: true,
    oneDeleteCommitAndReceipt: true,
    BRemovedHostAfterPull: true,
    serverAndVaultApiPlaintextMarkersAbsent: true,
    pageErrors: 0,
    unexpectedRequestFailures,
    expectedOfflineOwnerRequestFailures,
    driftStorageImplementations: safeStorageImplementationSummary(),
    fixtureCleanupComplete: true,
    operationId: deleteOperation.opId,
    revisionId: deleteOperation.revisionId,
    envelopeSha256: deleteOperation.envelopeSha256,
    commitSeq: recoveredReceipt.commitSeq,
  }));
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
  console.error(`WEB-DELETE-CRASH-01 failed at ${stage}; safe diagnostics=${JSON.stringify({
    cleanupFailed,
    ...safeFailure,
    pageErrors,
    unexpectedRequestFailures,
    syncApiStatuses: apiEvents.slice(-18).map((event) => ({
      profile: event.profile,
      route: event.route,
      method: event.method,
      status: event.status,
    })),
    markerMatchCount: apiBodyMarkerMatches.length,
    expectedOfflineOwnerRequestFailures,
    driftStorageImplementations: safeStorageImplementationSummary(),
    clientSnapshotDiagnostics,
  })}`);
  process.exitCode = 1;
});
