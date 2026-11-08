/*
 * WEB-HOST-AUTO-MERGE-01: two isolated Chromium devices edit disjoint Host
 * fields while offline. Both commit orders must produce one merged revision
 * based on the winner; edits to the same sensitive Host field must remain a
 * recoverable conflict branch. The server, database and profiles are private
 * disposable fixtures.
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
const {
  reconstructSqliteFile,
  SQLITE_BLOCK_SIZE,
} = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const CLIENT_DATABASE_NAME = 'atermius_vault';
const RECEIPT_RETENTION_MS = 24 * 60 * 60 * 1000;
const RUN_ID = crypto.randomUUID();
const USERNAME = `host-merge-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `HostMerge-${crypto.randomBytes(24).toString('base64url')}9`;
const HOSTS = {
  aWins: {
    initialName: `merge-a-base-${RUN_ID.slice(0, 8)}`,
    winnerName: `merge-a-name-${RUN_ID.slice(0, 8)}`,
    address: '192.0.2.51',
    baseTags: `merge-a-base-tag-${RUN_ID.slice(0, 8)}`,
    mergedTags: `merge-a-b-tag-${RUN_ID.slice(0, 8)}`,
  },
  bWins: {
    initialName: `merge-b-base-${RUN_ID.slice(0, 8)}`,
    winnerName: `merge-b-name-${RUN_ID.slice(0, 8)}`,
    address: '192.0.2.52',
    baseTags: `merge-b-base-tag-${RUN_ID.slice(0, 8)}`,
    mergedTags: `merge-b-a-tag-${RUN_ID.slice(0, 8)}`,
  },
  sameField: {
    initialName: `merge-sensitive-${RUN_ID.slice(0, 8)}`,
    aAddress: '192.0.2.61',
    bAddress: '192.0.2.62',
    baseTags: `merge-sensitive-tag-${RUN_ID.slice(0, 8)}`,
  },
};
const HOST_USER = `merge-user-${RUN_ID.slice(0, 8)}`;
const HOST_MARKERS = [HOST_USER, ...Object.values(HOSTS).flatMap((item) => Object.values(item))];

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let serverLogPath;
let serverProcess;
let ownerContext;
let secondContext;
let bootstrapToken;
let baseUrl;
let cleanupPromise;
let cleanupFailed = false;
const apiEvents = [];
const apiStatusEvents = [];
const apiBodyMarkerMatches = [];
const pageErrors = { A: 0, B: 0 };
const driftImplementations = {};
const traceByRequest = new WeakMap();

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
  assertThat(!result.error && result.status === 0,
    `${command} failed in the isolated Host merge fixture`);
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

async function waitForServer(child, timeoutMs = 30000) {
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
      try { stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8'); } catch (error) {
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
    try { process.kill(-groupId, 0); return true; } catch (error) {
      return error.code !== 'ESRCH';
    }
  }
}

function signalProcessGroup(groupId, signal) {
  try { process.kill(-groupId, signal); } catch (error) {
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
        } catch (_) { cleanupFailed = true; }
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

async function currentVisibleDialog(page) {
  const dialogs = page.locator('[role="dialog"], [role="alertdialog"]');
  const count = await dialogs.count().catch(() => 0);
  for (let index = count - 1; index >= 0; index -= 1) {
    const candidate = dialogs.nth(index);
    if (await candidate.isVisible().catch(() => false)) return candidate;
  }
  return null;
}

async function click(page, label) {
  await (await visibleButton(page, label)).click();
}

async function field(page, label, scope = null, timeoutMs = 20000) {
  const selector =
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const form = scope || await currentVisibleDialog(page);
  let matches = form?.locator(selector);
  if (!matches || await matches.count().catch(() => 0) === 0) {
    matches = page.locator(selector);
  }
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
  throw new Error(`visible field was not available: ${label}`);
}

async function fill(page, label, value, timeoutMs = 30000) {
  const locator = await field(page, label, null, Math.min(timeoutMs, 20000));
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click({ timeout: timeoutMs });
    await page.waitForTimeout(80);
    await locator.press('Control+A', { timeout: timeoutMs });
    await locator.pressSequentially(value, { delay: 12, timeout: timeoutMs });
    await page.waitForTimeout(80);
    if (await locator.inputValue().catch(() => null) !== value) continue;
    await locator.press('Tab', { timeout: timeoutMs });
    await page.waitForTimeout(80);
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
  await page.waitForTimeout(120);
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

function routeFor(pathname) {
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) return 'changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts$/.test(pathname)) return 'conflict-create';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflict-changes$/.test(pathname)) return 'conflict-changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts\/[^/]+\/resolve$/.test(pathname)) {
    return 'conflict-resolve';
  }
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
  };
}

function attachApiObservation(page, profile) {
  page.on('pageerror', () => { pageErrors[profile] += 1; });
  page.on('request', (request) => {
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (!pathname.startsWith('/api/v1/')) return;
    const route = routeFor(pathname);
    const statusEvent = {
      profile,
      route: route || (/^\/api\/v1\/auth\//.test(pathname) ? 'auth' : 'other-api'),
      method: request.method(),
      status: null,
    };
    apiStatusEvents.push(statusEvent);
    const body = request.postData() || '';
    if (HOST_MARKERS.some((marker) => body.includes(marker))) {
      apiBodyMarkerMatches.push({ profile, route: route || 'other-api', direction: 'request' });
    }
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
      operations: [],
      receipts: [],
      changeEvents: [],
      conflictId: null,
    };
    try {
      const payload = JSON.parse(body);
      if (route === 'push') {
        event.deviceId = payload.device_id || null;
        event.operations = Array.isArray(payload.operations)
          ? payload.operations.map(safeOperation) : [];
      } else if (route === 'conflict-create' && payload.envelope) {
        event.operations = [safeOperation(payload.envelope)];
      }
    } catch (_) {}
    apiEvents.push(event);
    traceByRequest.set(request, { statusEvent, event });
  });
  page.on('response', (response) => {
    void (async () => {
      const observed = traceByRequest.get(response.request());
      let pathname;
      try { pathname = new URL(response.url()).pathname; } catch (_) { return; }
      if (!pathname.startsWith('/api/v1/')) return;
      if (observed?.statusEvent) observed.statusEvent.status = response.status();
      const event = observed?.event || null;
      if (event) event.status = response.status();
      let body = '';
      try { body = await response.text(); } catch (_) {}
      if (HOST_MARKERS.some((marker) => body.includes(marker))) {
        apiBodyMarkerMatches.push({
          profile,
          route: event?.route || routeFor(pathname) || 'other-api',
          direction: 'response',
        });
      }
      if (!event) return;
      event.bodyRead = true;
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
      } else if (event.route === 'changes' && Array.isArray(payload.events)) {
        event.changeEvents = payload.events.map((item) => ({
          commitSeq: item.commit_seq,
          eventType: item.event_type,
          recordId: item.record_id,
          revisionId: item.revision_id,
          operation: item.envelope?.header?.operation || null,
        }));
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
  page.on('console', (message) => {
    const prefix = 'ATERMIUS_DRIFT_WEB_IMPLEMENTATION=';
    if (message.text().startsWith(prefix)) {
      driftImplementations[profile] = message.text().slice(prefix.length).trim();
    }
  });
  attachApiObservation(page, profile);
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await enableSemantics(page);
  return { context, page };
}

async function seedSharedIndexedDb(profileDir) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    serviceWorkers: 'block',
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profileDir, options);
  try {
    await context.route(`${baseUrl}/__receipt_migration_fixture__`, (route) =>
      route.fulfill({
        status: 200,
        contentType: 'text/html; charset=utf-8',
        body: '<!doctype html><title>isolated browser fixture</title>',
      }));
    const page = context.pages()[0] || await context.newPage();
    await page.goto(`${baseUrl}/__receipt_migration_fixture__`, {
      waitUntil: 'domcontentloaded',
      timeout: 10000,
    });
    const seeded = await page.evaluate(async (databaseName) => {
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName, 1);
        request.onupgradeneeded = () => {
          const files = request.result.createObjectStore('files', {
            autoIncrement: true,
          });
          files.createIndex('fileName', 'name', { unique: true });
          request.result.createObjectStore('blocks');
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('IDB seed failed'));
        request.onblocked = () => reject(new Error('IDB seed blocked'));
      });
      const stores = [...db.objectStoreNames].sort();
      db.close();
      return JSON.stringify(stores) === JSON.stringify(['blocks', 'files']);
    }, CLIENT_DATABASE_NAME);
    assertThat(seeded, 'failed to seed isolated shared IndexedDB backend');
  } finally {
    await context.close().catch(() => {});
  }
}

async function openRawIndexedDbProfile(profileDir) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    serviceWorkers: 'block',
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profileDir, options);
  try {
    await context.route(`${baseUrl}/__receipt_migration_fixture__`, (route) =>
      route.fulfill({
        status: 200,
        contentType: 'text/html; charset=utf-8',
        body: '<!doctype html><title>isolated browser fixture</title>',
      }));
    const page = context.pages()[0] || await context.newPage();
    await page.goto(`${baseUrl}/__receipt_migration_fixture__`, {
      waitUntil: 'domcontentloaded',
      timeout: 10000,
    });
    return { context, page };
  } catch (error) {
    await context.close().catch(() => {});
    throw error;
  }
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
        row?.name === `/${databaseName}/database` ||
        row?.name?.endsWith('/database'));
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
      const sidecarNames = rows
        .filter((row, index) => index !== mainIndex)
        .map((row) => String(row?.name || ''));
      return {
        fileId,
        name: String(rows[mainIndex].name),
        length: Number(rows[mainIndex].length),
        sidecarNames,
        blocks,
      };
    } finally {
      db.close();
    }
  }, CLIENT_DATABASE_NAME);
}

async function replaceIndexedDbSqliteImage(page, fileId, fileName, bytes) {
  assertThat(bytes.length > 0 && bytes.length % SQLITE_BLOCK_SIZE === 0,
    'SQLite rewrite did not produce aligned VFS blocks');
  await page.evaluate(async ({ databaseName, fileId, fileName, base64, length }) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
    });
    try {
      const binary = atob(base64);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) {
        bytes[index] = binary.charCodeAt(index);
      }
      const transaction = db.transaction(['files', 'blocks'], 'readwrite');
      const files = transaction.objectStore('files');
      const blocks = transaction.objectStore('blocks');
      const getFile = files.get(fileId);
      getFile.onsuccess = () => {
        const row = getFile.result;
        if (!row || row.name !== fileName) {
          transaction.abort();
          return;
        }
        const getKeys = blocks.getAllKeys(
          IDBKeyRange.bound([fileId, 0], [fileId, Number.MAX_SAFE_INTEGER]),
        );
        getKeys.onsuccess = () => {
          for (const key of getKeys.result || []) blocks.delete(key);
          for (let offset = 0; offset < bytes.length; offset += 4096) {
            const block = bytes.slice(offset, offset + 4096);
            blocks.put(block.buffer, [fileId, offset]);
          }
          files.put({ ...row, length }, fileId);
        };
      };
      await new Promise((resolve, reject) => {
        transaction.oncomplete = resolve;
        transaction.onerror = () => reject(transaction.error || new Error('IDB rewrite failed'));
        transaction.onabort = () => reject(transaction.error || new Error('IDB rewrite aborted'));
      });
    } finally {
      db.close();
    }
  }, {
    databaseName: CLIENT_DATABASE_NAME,
    fileId,
    fileName,
    base64: bytes.toString('base64'),
    length: bytes.length,
  });
}

function runClientDatabaseSqliteProbe(snapshotPath, mode, argument) {
  const script = String.raw`
import hashlib,json,sqlite3,sys,time
path,mode,arg=sys.argv[1:4]
arg=json.loads(arg)
db=sqlite3.connect(path)
db.row_factory=sqlite3.Row
assert db.execute('PRAGMA journal_mode=DELETE').fetchone()[0].lower()=='delete'
def state(record_ids):
 result={'integrity':db.execute('PRAGMA integrity_check').fetchone()[0],
         'schemaVersion':db.execute('PRAGMA user_version').fetchone()[0]}
 result['proofs']=[{'opId':r['op_id'],'vaultId':r['vault_id'],'recordId':r['record_id'],
   'revisionId':r['revision_id'],'commitSeq':r['commit_seq'],
   'createdAt':r['created_at'] if 'created_at' in r.keys() else None,
   'envelopeSha256':hashlib.sha256(r['envelope_json'].encode()).hexdigest()}
   for r in db.execute('SELECT * FROM authenticated_push_receipts ORDER BY op_id')]
 result['cache']={}
 for record_id in record_ids:
  r=db.execute('SELECT revision_id,commit_seq,envelope_json FROM encrypted_records WHERE record_id=?',(record_id,)).fetchone()
  if r:
   result['cache'][record_id]={'revisionId':r['revision_id'],'commitSeq':r['commit_seq'],
     'envelopeSha256':hashlib.sha256(r['envelope_json'].encode()).hexdigest()}
 return result
record_ids=arg.get('recordIds',[])
if mode=='seed-v9':
 for record_id in record_ids:
  row=db.execute('SELECT vault_id,record_id,revision_id,envelope_json,commit_seq FROM encrypted_records WHERE record_id=? AND commit_seq IS NOT NULL ORDER BY updated_at DESC LIMIT 1',(record_id,)).fetchone()
  assert row is not None
  envelope=json.loads(row['envelope_json'])
  header=envelope.get('header',{}) if isinstance(envelope,dict) else {}
  op_id=header.get('op_id')
  assert isinstance(op_id,str) and header.get('record_id')==row['record_id'] and header.get('revision_id')==row['revision_id']
  db.execute('INSERT OR REPLACE INTO authenticated_push_receipts (op_id,vault_id,record_id,revision_id,envelope_json,commit_seq,created_at) VALUES (?,?,?,?,?,?,?)',
    (op_id,row['vault_id'],row['record_id'],row['revision_id'],row['envelope_json'],str(row['commit_seq']),int(time.time()*1000)))
 db.commit()
 assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
 db.execute('ALTER TABLE authenticated_push_receipts DROP COLUMN created_at')
 db.execute('PRAGMA user_version=9')
 db.commit()
 db.execute('VACUUM')
elif mode=='age-proof':
 db.execute('UPDATE authenticated_push_receipts SET created_at=? WHERE op_id=?',
   (arg['createdAt'],arg['opId']))
 db.commit()
 db.execute('VACUUM')
elif mode!='inspect':
 raise ValueError('unsupported migration fixture mode')
result=state(record_ids)
db.close()
print(json.dumps(result,separators=(',',':')))
`;
  const execution = spawnSync('python3', [
    '-c', script,
    snapshotPath,
    mode,
    JSON.stringify(argument),
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 15000,
    maxBuffer: 256 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!execution.error && execution.status === 0,
    'isolated client SQLite migration probe failed');
  return JSON.parse(execution.stdout);
}

async function rewriteClientDatabase(profileDir, mode, argument) {
  const { context, page } = await openRawIndexedDbProfile(profileDir);
  const snapshotPath = path.join(tempRoot, 'client-vault-migration.sqlite');
  try {
    const image = await readIndexedDbSqliteImage(page);
    assertThat(image.sidecarNames.length === 0,
      'client SQLite VFS had unsettled sidecar files');
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
    const result = runClientDatabaseSqliteProbe(snapshotPath, mode, argument);
    const rewritten = fs.readFileSync(snapshotPath);
    await replaceIndexedDbSqliteImage(page, image.fileId, image.name, rewritten);
    return result;
  } finally {
    fs.rmSync(snapshotPath, { force: true });
    await context.close().catch(() => {});
  }
}

async function connect(page) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function registerOwner(page) {
  setStage('register isolated owner');
  await connect(page);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', USERNAME);
  await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
  await fill(page, 'Confirm master password', MASTER_PASSWORD);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Auto merge A');
  await fill(page, 'First Vault', 'Host Auto Merge Vault');
  bootstrapToken = undefined;
  await click(page, 'Create owner account');
  await waitWorkspace(page);
  await waitFor(() => driftImplementations.A === 'sharedIndexedDb',
    'owner profile opened its seeded shared IndexedDB');
}

async function enrollSecondDevice(ownerPage, secondPage) {
  setStage('approve isolated second device');
  await connect(secondPage);
  await field(secondPage, 'Email or username');
  await click(secondPage, 'Add this device');
  await waitFor(() => secondPage.evaluate(() =>
    (document.body.innerText || '').includes('Request this device')),
  'second-device request form');
  await fill(secondPage, 'Account email', USERNAME);
  await fill(secondPage, 'Device name', 'Auto merge B');
  await click(secondPage, 'Generate request');
  await field(secondPage, 'Copy this enrollment JSON');
  await click(secondPage, 'Copy');
  const enrollment = await secondPage.evaluate(() => navigator.clipboard.readText());
  let enrollmentFormat;
  try { enrollmentFormat = JSON.parse(enrollment).format; } catch (_) {}
  assertThat(enrollmentFormat === 'atermius-device-enrollment-v1',
    'second device enrollment payload had an unsupported format');
  await click(secondPage, 'Close');
  await click(ownerPage, 'Devices');
  await click(ownerPage, 'Approve enrollment');
  await paste(ownerPage, 'Enrollment JSON', enrollment);
  await click(ownerPage, 'Review keys');
  await click(ownerPage, 'Approve & seal keys');
  await click(ownerPage, 'Copy');
  const approval = await ownerPage.evaluate(() => navigator.clipboard.readText());
  assertThat(approval.includes('atermius-device-approval-v1'),
    'device approval payload had an unsupported format');
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
  await waitFor(() => driftImplementations.B === 'sharedIndexedDb',
    'second profile opened its seeded shared IndexedDB');
  await click(secondPage, 'Hosts');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hostCard(page, name, recordId = null) {
  if (recordId) {
    return page.locator(
      `flt-semantics[flt-semantics-identifier="ssh-host-${recordId}"]`,
    );
  }
  return page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)};`),
  }).first();
}

async function waitHost(page, name, expected = true, recordId = null) {
  await waitFor(async () => {
    const card = hostCard(page, name, recordId);
    const count = await card.count().catch(() => 0);
    const visible = count > 0 && await card.isVisible().catch(() => false);
    return visible === expected;
  }, `Host ${expected ? 'appears' : 'disappears'}`, 20000);
}

async function createHost(page, values) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitFor(() => page.evaluate(() =>
    (document.body.innerText || '').includes('Add a host')),
  'Add Host editor');
  await fill(page, 'Display name', values.name);
  await fill(page, 'Hostname or IP', values.address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', HOST_USER);
  await fill(page, 'Tags', values.tags);
  await click(page, 'Save encrypted host');
  await waitHost(page, values.name, true);
}

async function editHost(page, oldName, changes, recordId = null) {
  const card = hostCard(page, oldName, recordId);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  for (const [label, value] of Object.entries(changes)) await fill(page, label, value);
  await click(page, 'Save encrypted host');
  if (changes['Display name']) {
    if (recordId) {
      await waitFor(async () => {
        const label = await card.getAttribute('aria-label').catch(() => '') ||
          await card.innerText().catch(() => '');
        return label.startsWith(`Host: ${changes['Display name']};`);
      }, 'Host card reflects the saved display name');
    } else {
      await waitHost(page, oldName, false);
      await waitHost(page, changes['Display name'], true);
    }
  }
}

async function hostCardMatches(page, recordId, expected) {
  const card = hostCard(page, expected.name, recordId);
  if (!await card.isVisible().catch(() => false)) return false;
  const label = await card.getAttribute('aria-label').catch(() => '') ||
    await card.innerText().catch(() => '');
  if (!label.startsWith(`Host: ${expected.name};`) ||
      !label.includes(`@${expected.address}:22`)) {
    return false;
  }
  return visibleSemanticText(card, expected.tag);
}

async function recoverExistingOwnerWorkspace(page) {
  await selectServerModeIfChooser(page);
  const deadline = Date.now() + 30000;
  let connected = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) {
      await waitWorkspace(page);
      return;
    }
    if (!connected && await page.locator('input[aria-label*="Server URL"]')
      .isVisible().catch(() => false)) {
      // A persistent profile can restore its saved server session while the
      // first Flutter frame briefly exposes the connection form. Let the
      // automatic transition settle before interacting with that form.
      await page.waitForTimeout(350);
      if (await page.locator('input[aria-label*="Email or username"]')
        .isVisible().catch(() => false)) continue;
      if (!await page.locator('input[aria-label*="Server URL"]')
        .isVisible().catch(() => false)) continue;
      try {
        await fill(page, 'Server URL', baseUrl, 2500);
        await click(page, 'Connect securely');
        connected = true;
      } catch (error) {
        if (error?.name !== 'TimeoutError') throw error;
      }
    } else if (!loginSubmitted && await page.locator('input[aria-label*="Email or username"]')
      .isVisible().catch(() => false)) {
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', MASTER_PASSWORD);
      await click(page, 'Sign in and unlock');
      loginSubmitted = true;
    }
    await page.waitForTimeout(100);
  }
  throw new Error('migrated owner profile did not restore its Web workspace');
}

async function runReceiptMigrationAcceptance(profileDir, recordIds, expectedHost) {
  setStage('seed two encrypted receipt proofs into a v9 IndexedDB database');
  const legacy = await rewriteClientDatabase(profileDir, 'seed-v9', { recordIds });
  assertThat(legacy.integrity === 'ok' && legacy.schemaVersion === 9 &&
    legacy.proofs.length === 2 && legacy.proofs.every((proof) =>
      proof.createdAt === null && proof.envelopeSha256 && proof.commitSeq),
  'v9 IndexedDB fixture did not contain the expected ciphertext proof rows');

  setStage('open the current bundle and migrate the persistent v9 profile');
  driftImplementations.A = undefined;
  const migratedOwner = await launchProfile(profileDir, 'A');
  ownerContext = migratedOwner.context;
  await recoverExistingOwnerWorkspace(migratedOwner.page);
  await click(migratedOwner.page, 'Hosts');
  await waitForHostCardValues(migratedOwner.page, expectedHost.recordId, {
    name: expectedHost.name,
    address: expectedHost.address,
    tag: expectedHost.tag,
  });
  assertThat(driftImplementations.A === 'sharedIndexedDb',
    'current bundle did not reopen the migrated shared IndexedDB profile');
  await ownerContext.close();
  ownerContext = undefined;

  setStage('verify v9 migration preserved ciphertext, cache and new retention');
  const migrated = await rewriteClientDatabase(profileDir, 'inspect', { recordIds });
  assertThat(migrated.integrity === 'ok' && migrated.schemaVersion === 10 &&
    migrated.proofs.length === legacy.proofs.length &&
    JSON.stringify(migrated.cache) === JSON.stringify(legacy.cache),
  'v9 migration changed client cache or lost receipt rows');
  const oldProofsById = new Map(legacy.proofs.map((proof) => [proof.opId, proof]));
  const migratedProofsById = new Map(migrated.proofs.map((proof) => [proof.opId, proof]));
  for (const [opId, oldProof] of oldProofsById) {
    const proof = migratedProofsById.get(opId);
    assertThat(proof && proof.createdAt > 0 &&
      Math.abs(Date.now() - proof.createdAt) < 120000 &&
      proof.vaultId === oldProof.vaultId && proof.recordId === oldProof.recordId &&
      proof.revisionId === oldProof.revisionId && proof.commitSeq === oldProof.commitSeq &&
      proof.envelopeSha256 === oldProof.envelopeSha256,
    'v9 receipt proof was not preserved with a fresh migration timestamp');
  }

  const expiredProof = legacy.proofs[0];
  const retainedProof = legacy.proofs[1];
  setStage('age one receipt proof, then reopen the profile for startup cleanup');
  await rewriteClientDatabase(profileDir, 'age-proof', {
    recordIds,
    opId: expiredProof.opId,
    createdAt: Date.now() - RECEIPT_RETENTION_MS - 1,
  });
  driftImplementations.A = undefined;
  const reopenedOwner = await launchProfile(profileDir, 'A');
  ownerContext = reopenedOwner.context;
  await recoverExistingOwnerWorkspace(reopenedOwner.page);
  await click(reopenedOwner.page, 'Hosts');
  await waitForHostCardValues(reopenedOwner.page, expectedHost.recordId, {
    name: expectedHost.name,
    address: expectedHost.address,
    tag: expectedHost.tag,
  });
  await ownerContext.close();
  ownerContext = undefined;

  setStage('verify expired proof removal and newer evidence retention');
  const cleaned = await rewriteClientDatabase(profileDir, 'inspect', { recordIds });
  assertThat(cleaned.integrity === 'ok' && cleaned.schemaVersion === 10 &&
    cleaned.proofs.length === 1 && cleaned.proofs[0].opId === retainedProof.opId &&
    cleaned.cache[expectedHost.recordId]?.revisionId ===
      migrated.cache[expectedHost.recordId]?.revisionId &&
    cleaned.cache[expectedHost.recordId]?.envelopeSha256 ===
      migrated.cache[expectedHost.recordId]?.envelopeSha256,
  'startup cleanup removed fresh proof evidence or changed the encrypted Host cache');
}

async function visibleSemanticText(container, expectedText) {
  return container.evaluate((root, value) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden';
    };
    return [root, ...root.querySelectorAll('flt-semantics, [aria-label]')]
      .some((element) => visible(element) &&
        (element.getAttribute('aria-label') || element.innerText || '')
          .trim().includes(value));
  }, expectedText).catch(() => false);
}

async function waitForHostCardValues(page, recordId, expected) {
  try {
    await waitFor(() => hostCardMatches(page, recordId, expected),
      'Host card reflects the expected decrypted fields', 25000);
  } catch (_) {
    const card = hostCard(page, expected.name, recordId);
    const label = await card.getAttribute('aria-label').catch(() => '') || '';
    const tagVisible = await visibleSemanticText(card, expected.tag);
    throw new Error(`Host card field check failed ` +
      `(card=${await card.isVisible().catch(() => false)}, ` +
      `name=${label.startsWith(`Host: ${expected.name};`)}, ` +
      `address=${label.includes(`@${expected.address}:22`)}, tag=${tagVisible})`);
  }
}

function successfulPush(profile, operation, recordId = null, after = 0) {
  return apiEvents.slice(after).find((event) =>
    event.profile === profile && event.route === 'push' && event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.operation === operation &&
      (!recordId || item.recordId === recordId)));
}

async function requestSync(context, page, completeWhen, label, failWhen = null,
  waitForIdleAfterRequest = true) {
  const waitForIdle = async () => {
    if (!waitForIdleAfterRequest) return;
    await page.getByRole('button', { name: /^(Idle|Read-only)$/ }).first().waitFor({
      state: 'visible',
      timeout: 45000,
    });
  };
  await context.setOffline(false);
  if (await completeWhen()) {
    await waitForIdle();
    return;
  }
  if (failWhen && await failWhen()) throw new Error(`${label} reached its failure condition`);
  const guardedComplete = async () => {
    if (failWhen && await failWhen()) throw new Error(`${label} reached its failure condition`);
    return completeWhen();
  };
  const alreadyDone = await waitFor(guardedComplete, label, 8000)
    .then(() => true).catch(() => false);
  if (alreadyDone) {
    await waitForIdle();
    return;
  }
  if (failWhen && await failWhen()) throw new Error(`${label} reached its failure condition`);
  const patterns = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only)$/;
  const syncButton = page.getByRole('button', { name: patterns }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 20000 });
  const current = (await syncButton.getAttribute('aria-label').catch(() => null)) ||
    (await syncButton.innerText().catch(() => '')).trim();
  if (current !== 'Syncing' && await syncButton.isEnabled().catch(() => false)) {
    await syncButton.click();
  }
  await waitFor(guardedComplete, label, 60000);
  await waitForIdle();
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
 conflicts=db.execute('SELECT conflict_id,base_revision_id,resolved_revision_id,conflict_seq,device_id,envelope FROM conflicts WHERE vault_id=? AND record_id=? ORDER BY conflict_seq',(vault['vault_id'],record)).fetchall()
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
 out['conflicts']=[]
 for r in conflicts:
  item=describe(r['envelope'])
  out['conflicts'].append({'conflictId':r['conflict_id'],'baseRevisionId':r['base_revision_id'],'resolvedRevisionId':r['resolved_revision_id'],'conflictSeq':str(r['conflict_seq']),'deviceId':r['device_id'],'branch':item})
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

function assertCommittedHistory(snapshot, expectedDevices, expectedBaseRevisions) {
  const operations = snapshot.versions.map((item) => item.operation);
  assertThat(operations.join(',') === 'create,update,update' &&
    snapshot.events.map((item) => item.eventType).join(',') === 'create,update,update' &&
    snapshot.receipts.length === 3,
  'auto-merged Host did not produce exactly one create and two committed updates');
  assertThat(snapshot.versions.every((item, index) =>
    item.deviceId === expectedDevices[index] &&
    item.baseRevisionId === expectedBaseRevisions[index]),
  'winner and merged Host revisions were not signed by the expected devices/bases');
  assertThat(snapshot.versions.every((item, index) =>
    item.envelope.markerFree && item.envelope.shapeValid &&
    item.envelope.revisionId === item.revisionId &&
    item.envelope.recordId === snapshot.recordId &&
    item.envelope.operation === item.operation),
  'committed Host envelopes were malformed or contained synthetic plaintext markers');
  assertThat(snapshot.receipts.every((receipt, index) =>
    receipt.opId === snapshot.versions[index].envelope.opId &&
    receipt.revisionId === snapshot.versions[index].revisionId &&
    receipt.deviceId === expectedDevices[index] &&
    receipt.commitSeq === snapshot.versions[index].commitSeq),
  'Host operation receipts did not bind to the committed revisions');
  assertThat(snapshot.head?.revision_id === snapshot.versions.at(-1).revisionId &&
    snapshot.head.deleted === false && snapshot.conflicts.length === 0,
  'Host auto-merge did not leave one live head without a conflict branch');
}

function assertNoServerPlaintext() {
  const paths = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`, serverLogPath]
    .filter((filePath) => filePath && fs.existsSync(filePath));
  for (const filePath of paths) {
    const bytes = fs.readFileSync(filePath);
    assertThat(!HOST_MARKERS.some((marker) => bytes.includes(Buffer.from(marker))),
      'synthetic Host plaintext marker appeared in server persistence or logs');
  }
  assertThat(apiBodyMarkerMatches.length === 0,
    'synthetic Host plaintext marker appeared in a Vault API request or response');
}

async function runDistinctFieldRace({ contextA, contextB, pageA, pageB,
  ownerDeviceId, secondDeviceId, winnerProfile, recordId, initialName, expectedName,
  expectedAddress, expectedTags, winnerChanges, staleChanges }) {
  const baseline = readServerSnapshot(recordId);
  assertThat(baseline.versions.length === 1 && baseline.conflicts.length === 0,
    'race did not start from one shared Host revision');
  const baseRevisionId = baseline.versions[0].revisionId;
  setStage(`${winnerProfile} and the other profile edit distinct Host fields offline`);
  await Promise.all([contextA.setOffline(true), contextB.setOffline(true)]);
  await editHost(pageA, initialName, winnerChanges, recordId);
  await editHost(pageB, initialName, staleChanges, recordId);
  const baseTags = winnerProfile === 'A'
    ? HOSTS.aWins.baseTags
    : HOSTS.bWins.baseTags;
  await waitForHostCardValues(pageA, recordId, {
    name: winnerChanges['Display name'] || initialName,
    address: expectedAddress,
    tag: winnerChanges.Tags || baseTags,
  });
  await waitForHostCardValues(pageB, recordId, {
    name: staleChanges['Display name'] || initialName,
    address: expectedAddress,
    tag: staleChanges.Tags || baseTags,
  });
  assertThat(JSON.stringify(readServerSnapshot(recordId)) === JSON.stringify(baseline),
    'offline edits changed the committed server record before reconnection');

  const winnerContext = winnerProfile === 'A' ? contextA : contextB;
  const winnerPage = winnerProfile === 'A' ? pageA : pageB;
  const staleContext = winnerProfile === 'A' ? contextB : contextA;
  const stalePage = winnerProfile === 'A' ? pageB : pageA;
  const winnerPushStart = apiEvents.length;
  await requestSync(winnerContext, winnerPage,
    () => successfulPush(winnerProfile, 'update', recordId, winnerPushStart) !== undefined,
    `${winnerProfile} update commit`);
  const firstPush = successfulPush(winnerProfile, 'update', recordId, winnerPushStart);
  const firstOperation = firstPush?.operations.find((item) =>
    item.operation === 'update' && item.recordId === recordId);
  const winnerDeviceId = firstOperation?.deviceId;
  assertThat(firstOperation?.baseRevisionId === baseRevisionId && winnerDeviceId &&
    (winnerProfile !== 'A' || winnerDeviceId === ownerDeviceId),
  'first offline editor did not commit its update from the shared base');

  const winnerSnapshot = readServerSnapshot(recordId);
  const winnerRevisionId = firstOperation.revisionId;
  assertThat(winnerSnapshot.versions.length === 2 &&
    winnerSnapshot.head?.revision_id === winnerRevisionId &&
    winnerSnapshot.conflicts.length === 0,
  'first editor did not establish the uncontested new head');

  setStage(`${winnerProfile} is the first commit; stale ${winnerProfile === 'A' ? 'B' : 'A'} auto-merges`);
  const stalePushStart = apiEvents.length;
  const staleProfile = winnerProfile === 'A' ? 'B' : 'A';
  await requestSync(staleContext, stalePage,
    () => apiEvents.slice(stalePushStart).some((event) =>
      event.profile === staleProfile && event.route === 'push' && event.status === 200 &&
      event.bodyRead && event.operations.some((item) => item.operation === 'update' &&
        item.recordId === recordId && item.baseRevisionId === winnerRevisionId)),
    'stale profile signed merged update',
    () => apiEvents.slice(stalePushStart).some((event) =>
      event.profile === staleProfile && event.route === 'conflict-create' &&
      event.status === 200 && event.bodyRead &&
      event.operations.some((item) => item.recordId === recordId)));
  const mergedPush = successfulPush(staleProfile, 'update', recordId, stalePushStart);
  const mergedOperation = mergedPush?.operations.find((item) =>
    item.operation === 'update' && item.recordId === recordId &&
    item.baseRevisionId === winnerRevisionId);
  const staleDeviceId = mergedOperation?.deviceId;
  assertThat(staleDeviceId && staleDeviceId !== winnerDeviceId &&
    (staleProfile !== 'A' || staleDeviceId === ownerDeviceId) &&
    mergedOperation.revisionId !== firstOperation.revisionId &&
    mergedOperation.revisionId !== baseRevisionId,
  'stale profile did not re-sign a fresh merged update from the new head');
  assertThat(!apiEvents.slice(stalePushStart).some((event) =>
    event.profile === staleProfile && event.route === 'conflict-create' &&
    event.status === 200 && event.operations.some((item) => item.recordId === recordId)),
  'a non-overlapping Host update was uploaded as a conflict branch');

  const afterMerge = readServerSnapshot(recordId);
  assertCommittedHistory(afterMerge,
    [ownerDeviceId, winnerDeviceId, staleDeviceId],
    [null, baseRevisionId, winnerRevisionId]);
  assertThat(afterMerge.versions[2].revisionId === mergedOperation.revisionId &&
    afterMerge.versions[2].envelope.opId === mergedOperation.opId,
  'server merged revision did not match the stale client signed request');

  await requestSync(winnerContext, winnerPage,
    () => apiEvents.some((event) =>
      event.profile === winnerProfile && event.route === 'changes' && event.status === 200 &&
      event.bodyRead && event.changeEvents.some((item) =>
        item.recordId === recordId && item.revisionId === mergedOperation.revisionId)),
    'first committer pulled merged revision');

  const finalName = expectedName;
  const expected = {
    'Display name': finalName,
    'Hostname or IP': expectedAddress,
    Tags: expectedTags,
  };
  for (const [profile, page] of [['A', pageA], ['B', pageB]]) {
    await waitForHostCardValues(page, recordId, {
      name: expected['Display name'],
      address: expected['Hostname or IP'],
      tag: expected.Tags,
    }).catch(() => {
      throw new Error(`Profile ${profile} did not decrypt the merged Host card ` +
        `(name/address/tag match unavailable)`);
    });
  }
  return {
    recordId,
    baseRevisionId,
    winnerRevisionId,
    mergedRevisionId: mergedOperation.revisionId,
    ownerDeviceId,
    secondDeviceId: winnerProfile === 'B'
      ? winnerDeviceId
      : (staleProfile === 'B' ? staleDeviceId : secondDeviceId),
  };
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
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-host-auto-merge-'));
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
  await waitForServer(serverProcess);
  fs.closeSync(serverLogFd);

  try {
    setStage('launch persistent Profile A');
    const profileAPath = path.join(tempRoot, 'chromium-profile-a');
    fs.mkdirSync(profileAPath, { recursive: true, mode: 0o700 });
    fs.chmodSync(profileAPath, 0o700);
    await seedSharedIndexedDb(profileAPath);
    const owner = await launchProfile(profileAPath, 'A');
    ownerContext = owner.context;
    await registerOwner(owner.page);

    const records = {};
    const created = {};
    const createValues = [
      ['aWins', HOSTS.aWins],
      ['bWins', HOSTS.bWins],
      ['sameField', HOSTS.sameField],
    ];
    for (const [key, spec] of createValues) {
      setStage(`create shared baseline Host ${key}`);
      const start = apiEvents.length;
      await createHost(owner.page, {
        name: spec.initialName,
        address: spec.address || '192.0.2.63',
        tags: spec.baseTags,
      });
      await requestSync(ownerContext, owner.page,
        () => successfulPush('A', 'create', null, start) !== undefined,
        `A creates baseline Host ${key}`);
      const event = successfulPush('A', 'create', null, start);
      const operation = event?.operations.find((item) => item.operation === 'create');
      const receipt = event?.receipts.find((item) => item.opId === operation?.opId);
      assertThat(operation?.recordId && operation.revisionId && operation.deviceId &&
        receipt?.revisionId === operation.revisionId && receipt.alreadyCommitted === false,
      `baseline Host ${key} did not receive its first-commit receipt`);
      records[key] = operation.recordId;
      created[key] = operation;
    }

    const profileBPath = path.join(tempRoot, 'chromium-profile-b');
    fs.mkdirSync(profileBPath, { recursive: true, mode: 0o700 });
    fs.chmodSync(profileBPath, 0o700);
    await seedSharedIndexedDb(profileBPath);
    const second = await launchProfile(profileBPath, 'B');
    secondContext = second.context;
    const secondSyncStart = apiEvents.length;
    await enrollSecondDevice(owner.page, second.page);
    await click(second.page, 'Hosts');
    for (const spec of Object.values(HOSTS)) await waitHost(second.page, spec.initialName, true);
    await requestSync(secondContext, second.page,
      () => apiEvents.slice(secondSyncStart).some((event) =>
        event.profile === 'B' && event.route === 'changes' && event.status === 200 && event.bodyRead),
      'Profile B initial pull');
    const ownerDeviceId = created.aWins.deviceId;
    assertThat(ownerDeviceId, 'Profile A did not use a signed device identity');

    const results = [];
    const mergeFailures = [];
    try {
      results.push(await runDistinctFieldRace({
        contextA: ownerContext,
        contextB: secondContext,
        pageA: owner.page,
        pageB: second.page,
        ownerDeviceId,
        secondDeviceId: undefined,
        winnerProfile: 'A',
        recordId: records.aWins,
        initialName: HOSTS.aWins.initialName,
        expectedName: HOSTS.aWins.winnerName,
        expectedAddress: HOSTS.aWins.address,
        expectedTags: HOSTS.aWins.mergedTags,
        winnerChanges: { 'Display name': HOSTS.aWins.winnerName },
        staleChanges: { Tags: HOSTS.aWins.mergedTags },
      }));
    } catch (error) {
      mergeFailures.push('A-then-B');
      console.log(`A-then-B non-overlap acceptance failed: ${safeDiagnosticText(error?.message)}`);
    }
    let secondDeviceId = results[0]?.secondDeviceId || apiEvents
      .filter((event) => event.profile === 'B')
      .flatMap((event) => event.operations)
      .map((item) => item.deviceId)
      .find((value) => value && value !== ownerDeviceId);

    // Let both profiles settle on the first case before starting the reverse
    // order race, so each case starts from the same one-revision Host base.
    try {
      results.push(await runDistinctFieldRace({
        contextA: ownerContext,
        contextB: secondContext,
        pageA: owner.page,
        pageB: second.page,
        ownerDeviceId,
        secondDeviceId,
        winnerProfile: 'B',
        recordId: records.bWins,
        initialName: HOSTS.bWins.initialName,
        expectedName: HOSTS.bWins.winnerName,
        expectedAddress: HOSTS.bWins.address,
        expectedTags: HOSTS.bWins.mergedTags,
        winnerChanges: { Tags: HOSTS.bWins.mergedTags },
        staleChanges: { 'Display name': HOSTS.bWins.winnerName },
      }));
    } catch (error) {
      mergeFailures.push('B-then-A');
      console.log(`B-then-A non-overlap acceptance failed: ${safeDiagnosticText(error?.message)}`);
    }
    secondDeviceId ||= results[1]?.secondDeviceId;

    setStage('same sensitive Host field remains an explicit conflict branch');
    const sensitiveBase = readServerSnapshot(records.sameField);
    assertThat(sensitiveBase.versions.length === 1 && sensitiveBase.conflicts.length === 0,
      'sensitive-field control did not start from one clean Host revision');
    const sensitiveBaseRevision = sensitiveBase.versions[0].revisionId;
    await Promise.all([ownerContext.setOffline(true), secondContext.setOffline(true)]);
    await editHost(owner.page, HOSTS.sameField.initialName,
      { 'Hostname or IP': HOSTS.sameField.aAddress }, records.sameField);
    await editHost(second.page, HOSTS.sameField.initialName,
      { 'Hostname or IP': HOSTS.sameField.bAddress }, records.sameField);
    assertThat(JSON.stringify(readServerSnapshot(records.sameField)) ===
      JSON.stringify(sensitiveBase), 'offline sensitive-field edits changed the server head');

    const firstSensitiveStart = apiEvents.length;
    await requestSync(ownerContext, owner.page,
      () => successfulPush('A', 'update', records.sameField, firstSensitiveStart) !== undefined,
      'Profile A sensitive-field update commit');
    const firstSensitive = successfulPush('A', 'update', records.sameField, firstSensitiveStart);
    const firstSensitiveOperation = firstSensitive?.operations.find((item) =>
      item.operation === 'update' && item.recordId === records.sameField);
    assertThat(firstSensitiveOperation?.baseRevisionId === sensitiveBaseRevision &&
      firstSensitiveOperation.deviceId === ownerDeviceId,
    'first sensitive-field editor did not commit from the shared base');

    const conflictStart = apiEvents.length;
    await requestSync(secondContext, second.page,
      () => apiEvents.slice(conflictStart).some((event) =>
        event.profile === 'B' && event.route === 'conflict-create' && event.status === 200 &&
        event.bodyRead && event.operations.some((item) => item.recordId === records.sameField)),
      'Profile B same-field conflict branch upload', null, false);
    const conflictEvent = apiEvents.slice(conflictStart).find((event) =>
      event.profile === 'B' && event.route === 'conflict-create' && event.status === 200 &&
      event.bodyRead && event.operations.some((item) => item.recordId === records.sameField));
    const branch = conflictEvent?.operations.find((item) => item.recordId === records.sameField);
    const sensitiveResult = readServerSnapshot(records.sameField);
    assertThat(branch?.operation === 'update' && branch.baseRevisionId === sensitiveBaseRevision &&
      branch.deviceId && branch.deviceId !== ownerDeviceId &&
      (!secondDeviceId || branch.deviceId === secondDeviceId) && conflictEvent.conflictId,
    'same-field conflict did not retain B’s signed branch against the shared base');
    assertThat(sensitiveResult.versions.length === 2 &&
      sensitiveResult.versions.map((item) => item.operation).join(',') === 'create,update' &&
      sensitiveResult.head?.revision_id === firstSensitiveOperation.revisionId &&
      sensitiveResult.conflicts.length === 1 &&
      sensitiveResult.conflicts[0].conflictId === conflictEvent.conflictId &&
      sensitiveResult.conflicts[0].resolvedRevisionId === null &&
      sensitiveResult.conflicts[0].branch.revisionId === branch.revisionId &&
      sensitiveResult.conflicts[0].branch.baseRevisionId === sensitiveBaseRevision &&
      sensitiveResult.conflicts[0].branch.deviceId === branch.deviceId &&
      sensitiveResult.conflicts[0].branch.markerFree &&
      sensitiveResult.conflicts[0].branch.shapeValid,
    'same-sensitive-field edit was auto-merged or its encrypted branch was not recoverable');
    setStage('verify ciphertext-only persistence and cleanup');
    await ownerContext.close();
    ownerContext = undefined;
    await secondContext.close();
    secondContext = undefined;
    await runReceiptMigrationAcceptance(profileAPath, [records.aWins, records.bWins], {
      recordId: records.aWins,
      name: HOSTS.aWins.winnerName,
      address: HOSTS.aWins.address,
      tag: HOSTS.aWins.mergedTags,
    });
    assertNoServerPlaintext();
    assertThat(pageErrors.A === 0 && pageErrors.B === 0,
      'a browser profile raised an uncaught runtime error');
    await cleanup();
    assertThat(!cleanupFailed, 'fixture cleanup failed');
    assertThat(mergeFailures.length === 0,
      `non-overlapping Host fields failed automatic merge: ${mergeFailures.join(', ')}`);
    console.log('WEB-HOST-AUTO-MERGE-01 passed', JSON.stringify({
      independentPersistentProfiles: true,
      distinctFieldCommitOrders: ['A-then-B', 'B-then-A'],
      mergedHistoryCount: results.length,
      distinctFieldConflicts: 0,
      sameSensitiveFieldConflictRetained: true,
      sameFieldVersionCount: sensitiveResult.versions.length,
      sameFieldConflictCount: sensitiveResult.conflicts.length,
      v9IndexedDbMigrationPreservedCiphertextAndCache: true,
      expiredProofCleanupPreservedFreshEvidence: true,
      ciphertextOnlyPersistence: true,
      pageErrors: 0,
      fixtureCleanupComplete: true,
    }));
  } catch (error) {
    const safeFailure = {
      errorName: safeDiagnosticText(error?.name || 'Error'),
      errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure'),
      apiStatuses: apiStatusEvents.slice(-24),
    };
    await cleanup();
    console.error(`WEB-HOST-AUTO-MERGE-01 failed at ${stage}; safe diagnostics=${JSON.stringify({
      cleanupFailed,
      ...safeFailure,
      pageErrors,
      syncApiStatuses: apiEvents.slice(-24).map((event) => ({
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
  await cleanup();
  console.error(`WEB-HOST-AUTO-MERGE-01 failed at ${stage}; safe diagnostics=${JSON.stringify({
    cleanupFailed,
    errorName: safeDiagnosticText(error?.name || 'Error'),
    errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure'),
    apiStatuses: apiStatusEvents.slice(-24),
    pageErrors,
  })}`);
  process.exitCode = 1;
});
