'use strict';

/*
 * WEB-SYNC-GENERATION-01: exercise a real server-generation rollover with two
 * independent persistent Chromium profiles and the encrypted Web sync UI.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const RUN_ID = crypto.randomUUID();
const USERNAME = `sync-generation-${RUN_ID.slice(0, 8)}@example.test`;
const PASSWORD = `Generation-${crypto.randomBytes(24).toString('base64url')}-9`;
const OWNER_DEVICE = `Generation owner ${RUN_ID.slice(0, 8)}`;
const SECOND_DEVICE = `Generation second ${RUN_ID.slice(0, 8)}`;
const VAULT_NAME = `Generation Vault ${RUN_ID.slice(0, 8)}`;
const HOSTS = {
  A: {
    name: `generation-pending-${RUN_ID}`,
    address: '192.0.2.191',
    username: `pending-${RUN_ID.slice(0, 8)}`,
  },
  B: {
    name: `generation-committed-${RUN_ID}`,
    address: '198.51.100.192',
    username: `committed-${RUN_ID.slice(0, 8)}`,
  },
};
const PLAINTEXT_MARKERS = Object.values(HOSTS).flatMap((host) =>
  [host.name, host.address, host.username]);
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let profileAPath;
let profileBPath;
let serverEnv;
let baseUrl;
let serverProcess;
let contextA;
let contextB;
let pageA;
let pageB;
let bootstrapToken;
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = { A: 0, B: 0 };
const startupHttpErrors = { A: [], B: [] };
const startupRequestFailures = { A: [], B: [] };
const apiEvents = { A: [], B: [] };
const pushEvents = { A: [], B: [] };
const authRequests = { A: [], B: [] };
const syncRequestCounts = {
  A: { changes: 0, snapshots: 0, pushes: 0 },
  B: { changes: 0, snapshots: 0, pushes: 0 },
};
let snapshotGate;
let allowAChanges = true;
let allowBChanges = true;
let allowAPushes = true;
let backupKey;
let backupArchivePath;
let backupKeyPath;
let restoredDataDir;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function unusedLoopbackPort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close((error) =>
    error ? reject(error) : resolve()));
  return port;
}

function processGroupHasLiveMembers(groupId) {
  try {
    for (const entry of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(entry)) continue;
      let stat;
      try { stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8'); }
      catch (error) {
        if (error.code === 'EACCES' || error.code === 'EPERM') return true;
        continue;
      }
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') {
        return true;
      }
    }
  } catch (_) { return true; }
  return false;
}

function signalProcessGroup(groupId, signal) {
  try { process.kill(-groupId, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw new Error('server stop failed'); }
}

async function waitForProcessGroupExit(groupId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processGroupHasLiveMembers(groupId)) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return !processGroupHasLiveMembers(groupId);
}

async function stopServer() {
  if (!serverProcess || !Number.isInteger(serverProcess.pid)) return;
  const group = serverProcess.pid;
  if (processGroupHasLiveMembers(group)) {
    signalProcessGroup(group, 'SIGTERM');
    if (!await waitForProcessGroupExit(group, 2500)) {
      signalProcessGroup(group, 'SIGKILL');
      if (!await waitForProcessGroupExit(group, 2500)) {
        throw new Error('server process group did not stop');
      }
    }
  }
  serverProcess = undefined;
}

async function waitForServer(timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (serverProcess?.exitCode !== null) {
      throw new Error('isolated server exited before readiness');
    }
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1500),
      });
      if (response.status === 200) return;
    } catch (_) { /* Keep polling the isolated listener. */ }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error('isolated server readiness timed out');
}

function startServer() {
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT, env: serverEnv, detached: true, stdio: 'ignore',
  });
  return waitForServer();
}

async function waitFor(predicate, description, timeoutMs = 30000, page = pageA) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`${description} timed out`);
}

function visibleFieldSelector(label) {
  return `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
}

async function field(page, label, timeoutMs = 15000) {
  const locator = page.locator(visibleFieldSelector(label));
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let i = 0; i < await locator.count(); i += 1) {
      const item = locator.nth(i);
      if (await item.isVisible().catch(() => false)) return item;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible field unavailable: ${label}`);
}

async function button(page, label, timeoutMs = 15000) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let i = 0; i < await locator.count(); i += 1) {
      const item = locator.nth(i);
      if (await item.isVisible().catch(() => false)) return item;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button unavailable: ${label}`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 20 });
    if (await locator.inputValue().catch(() => '') === value) {
      await locator.press('Tab');
      await page.waitForTimeout(75);
      if (await locator.inputValue().catch(() => '') === value) return;
    }
  }
  throw new Error(`visible field did not retain input: ${label}`);
}

async function fillSemanticField(page, label, value) {
  const locator = await field(page, label);
  await locator.focus();
  await locator.press('Control+A');
  await locator.pressSequentially(value, { delay: 20 });
  if (await locator.inputValue().catch(() => '') !== value) {
    throw new Error(`semantic field did not retain input: ${label}`);
  }
  await locator.press('Tab');
  await page.waitForTimeout(75);
  if (await locator.inputValue().catch(() => '') !== value) {
    throw new Error(`semantic field lost input after blur: ${label}`);
  }
}

async function waitForText(page, expected, timeoutMs = 20000) {
  await waitFor(async () => page.evaluate((text) =>
    (document.body.innerText || '').includes(text) ||
    [...document.querySelectorAll('flt-semantics')].some((item) =>
      `${item.innerText || ''} ${item.getAttribute('aria-label') || ''}`.includes(text)),
  expected).catch(() => false), `text ${expected}`, timeoutMs, page);
}

async function waitForNoText(page, unexpected, timeoutMs = 20000) {
  await waitFor(async () =>
    !(await page.getByText(unexpected, { exact: true }).isVisible().catch(() => false)),
  `text ${unexpected} to disappear`, timeoutMs, page);
}

async function safeVisiblePageState(page) {
  return page.evaluate(() => ({
    pathname: window.location.pathname,
    title: document.title,
    visibleText: (document.body.innerText || '').slice(0, 1200),
    visibleSemantics: [...document.querySelectorAll('flt-semantics')]
      .filter((element) => element.getClientRects().length > 0)
      .map((element) => ({
        text: (element.innerText || '').slice(0, 240),
        label: (element.getAttribute('aria-label') || '').slice(0, 240),
        role: element.getAttribute('role') || '',
      })).slice(0, 40),
    fields: [...document.querySelectorAll('input,textarea')]
      .filter((element) => element.getClientRects().length > 0)
      .map((element) => ({
        tag: element.tagName.toLowerCase(),
        label: element.getAttribute('aria-label') ||
          element.getAttribute('placeholder') || '',
      })).slice(0, 20),
  }));
}

async function waitForWorkspace(page) {
  await waitFor(async () => page.getByRole('button', {
    name: 'Add host', exact: true,
  }).isVisible().catch(() => false), 'workspace', 30000, page);
}

function protectedTrafficSnapshot(profile) {
  return {
    auth: authRequests[profile].length,
    ...syncRequestCounts[profile],
  };
}

function assertProtectedTrafficUnchanged(profile, before, phase) {
  assertThat(
    JSON.stringify(protectedTrafficSnapshot(profile)) === JSON.stringify(before),
    `${phase} sent authentication, changes, snapshot, or push traffic before identity confirmation`,
  );
}

async function initializeFlutter(page) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  'Flutter startup', 30000, page);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((node) => node.click());
  await waitFor(() => page.evaluate(() =>
    document.querySelectorAll('flt-semantics').length > 0),
  'Flutter semantics', 15000, page);
  await selectServerModeIfChooser(page, null);
}

async function seedIndexedDb(context) {
  const seedPage = await context.newPage();
  try {
    await seedPage.goto(`${baseUrl}/health/ready`, { waitUntil: 'domcontentloaded' });
    const result = await seedPage.evaluate(async () => {
      const connection = await new Promise((resolve, reject) => {
        const request = indexedDB.open('atermius_vault', 1);
        request.onupgradeneeded = () => {
          const db = request.result;
          const files = db.createObjectStore('files', { autoIncrement: true });
          files.createIndex('fileName', 'name', { unique: true });
          db.createObjectStore('blocks');
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(new Error('IndexedDB seed failed'));
        request.onblocked = () => reject(new Error('IndexedDB seed blocked'));
      });
      const names = [...connection.objectStoreNames].sort();
      connection.close();
      return names.join(',') === 'blocks,files';
    });
    assertThat(result, 'could not seed safe Drift IndexedDB files/blocks backend');
  } finally { await seedPage.close().catch(() => {}); }
}

async function setupPersistentContext(profilePath, profile) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profilePath, options);
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
  const page = context.pages()[0] || await context.newPage();
  page.on('pageerror', () => { pageErrors[profile] += 1; });
  page.on('response', (response) => {
    const url = new URL(response.url());
    if (url.origin === baseUrl && url.pathname.startsWith('/api/') &&
        response.status() >= 400) {
      startupHttpErrors[profile].push({
        method: response.request().method(), path: url.pathname,
        status: response.status(),
      });
    }
  });
  page.on('requestfailed', (request) => {
    const url = new URL(request.url());
    if (url.origin === baseUrl && url.pathname.startsWith('/api/')) {
      startupRequestFailures[profile].push({
        method: request.method(), path: url.pathname, category: 'request-failed',
      });
    }
  });
  page.on('request', (request) => {
    const url = new URL(request.url());
    if (url.origin !== baseUrl) return;
    if (url.pathname.startsWith('/api/v1/auth/')) {
      authRequests[profile].push({ method: request.method(), path: url.pathname });
    }
  });
  await context.route('**/api/v1/vaults/*/changes*', async (route) => {
    syncRequestCounts[profile].changes += 1;
    if (profile === 'B' && !allowBChanges) {
      await route.abort('failed').catch(() => {});
      return;
    }
    if (profile === 'A' && !allowAChanges) {
      await route.abort('failed').catch(() => {});
      return;
    }
    try {
      const response = await route.fetch();
      let details = {};
      let responseBodyText = '';
      if (response.status() === 410) {
        try {
          const body = await response.json();
          responseBodyText = JSON.stringify(body);
          details = {
            errorCode: body?.error?.code || null,
            errorMessage: body?.error?.message || null,
            preserveLocalOutbox: body?.error?.details?.preserve_local_outbox === true,
            recovery: body?.error?.details?.recovery || null,
          };
          await route.fulfill({ response, body: JSON.stringify(body) });
        } catch (_) {
          await route.fulfill({ response });
        }
      } else {
        const body = await response.body();
        responseBodyText = body.toString('utf8');
        try {
          const payload = JSON.parse(responseBodyText);
          details = { responseServerGeneration: payload?.server_generation || null };
        } catch (_) { /* Preserve the opaque response body for its caller. */ }
        await route.fulfill({ response, body });
      }
      const hasCursor = new URL(route.request().url()).searchParams.has('cursor');
      apiEvents[profile].push({
        method: 'GET', path: 'changes', status: response.status(), hasCursor,
        markersAbsent: PLAINTEXT_MARKERS.every((marker) => !responseBodyText.includes(marker)),
        ...details,
      });
    } catch (_) { await route.abort('failed').catch(() => {}); }
  });
  await context.route('**/api/v1/snapshots/*', async (route) => {
    syncRequestCounts[profile].snapshots += 1;
    const pathName = new URL(route.request().url()).pathname;
    if (profile === 'A' && route.request().method() === 'GET' && snapshotGate) {
      snapshotGate.seen.resolve();
      await snapshotGate.release.promise;
    }
    const response = await route.fetch();
    const responseBody = await response.body();
    apiEvents[profile].push({
      method: route.request().method(),
      path: route.request().method() === 'GET' ? 'snapshot-get' : 'snapshot-create',
      status: response.status(),
      snapshotIdPresent: /\/snapshots\/[^/]+$/.test(pathName),
      markersAbsent: PLAINTEXT_MARKERS.every((marker) =>
        !responseBody.toString('utf8').includes(marker)),
    });
    await route.fulfill({ response, body: responseBody });
  });
  await context.route('**/api/v1/vaults/*/sync/push', async (route) => {
    syncRequestCounts[profile].pushes += 1;
    const body = route.request().postDataJSON();
    const operations = Array.isArray(body?.operations) ? body.operations : [];
    const summaries = operations.map((envelope) => {
      const header = envelope?.header || {};
      return {
        opId: header.op_id || null,
        revisionId: header.revision_id || null,
        recordId: header.record_id || null,
        vaultId: header.vault_id || body?.vault_id || null,
        operation: header.operation || null,
        envelopeSha256: crypto.createHash('sha256')
          .update(JSON.stringify(envelope)).digest('hex'),
        markersAbsent: PLAINTEXT_MARKERS.every((marker) =>
          !JSON.stringify(envelope).includes(marker)),
      };
    });
    if (profile === 'A' && !allowAPushes) {
      await route.abort('failed').catch(() => {});
      return;
    }
    const upstream = await route.fetch();
    let receipts = [];
    try {
      const responseBody = await upstream.json();
      receipts = Array.isArray(responseBody?.results) ? responseBody.results.map((receipt) => ({
        opId: receipt?.op_id,
        revisionId: receipt?.revision_id,
        commitSeq: String(receipt?.commit_seq ?? ''),
        alreadyCommitted: receipt?.already_committed === true,
      })) : [];
      await route.fulfill({ response: upstream, body: JSON.stringify(responseBody) });
    } catch (_) { await route.fulfill({ response: upstream }); }
    pushEvents[profile].push({ status: upstream.status(), operations: summaries, receipts });
  });
  return { context, page };
}

async function readClipboard(page) { return page.evaluate(() => navigator.clipboard.readText()); }

async function paste(page, label, value) {
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
  const input = await field(page, label);
  await input.click();
  await input.press('Control+A');
  await input.press('Control+V');
  await page.waitForTimeout(150);
  if (await input.inputValue().catch(() => '') !== value) await fill(page, label, value);
  assertThat(await input.inputValue() === value, `paste failed for ${label}`);
}

async function requestDevice(page) {
  await field(page, 'Email or username');
  await click(page, 'Add this device');
  await waitForText(page, 'Request this device');
  await fill(page, 'Account email', USERNAME);
  await fill(page, 'Device name', SECOND_DEVICE);
  await click(page, 'Generate request');
  await field(page, 'Copy this enrollment JSON');
  await click(page, 'Copy');
  const json = await readClipboard(page);
  assertThat(JSON.parse(json).format === 'atermius-device-enrollment-v1',
    'second profile did not create a valid device request');
  await page.evaluate(() => navigator.clipboard.writeText(''));
  await click(page, 'Close');
  return json;
}

async function approveDevice(page, enrollmentJson) {
  await click(page, 'Devices');
  await click(page, 'Approve enrollment');
  await paste(page, 'Enrollment JSON', enrollmentJson);
  await click(page, 'Review keys');
  await click(page, 'Approve & seal keys');
  await button(page, 'Copy');
  await click(page, 'Copy');
  const approvalJson = await readClipboard(page);
  assertThat(JSON.parse(approvalJson).format === 'atermius-device-approval-v1',
    'owner profile did not create a valid device approval');
  await page.evaluate(() => navigator.clipboard.writeText(''));
  await click(page, 'Done');
  await click(page, 'Hosts');
  return approvalJson;
}

async function importApprovalAndSignIn(page, approvalJson) {
  await click(page, 'Import approval');
  const input = await field(page, 'Paste approval JSON');
  await input.fill(approvalJson);
  assertThat(await input.inputValue() === approvalJson,
    'second profile approval did not populate import field');
  await click(page, 'Import device keys');
  await fill(page, 'Email or username', USERNAME);
  await fill(page, 'Master password', PASSWORD);
  await click(page, 'Sign in and unlock');
  await waitForWorkspace(page);
}

async function addHost(page, host) {
  await click(page, 'Add host');
  await waitForText(page, 'Add a host');
  await fill(page, 'Display name', host.name);
  await fill(page, 'Hostname or IP', host.address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', host.username);
  await click(page, 'Save encrypted host');
  await waitForText(page, host.name, 20000);
}

async function visiblePendingCount(page) {
  return page.evaluate(() => {
    for (const item of document.querySelectorAll('flt-semantics')) {
      const rect = item.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const label = `${item.getAttribute('aria-label') || ''} ${item.innerText || ''}`
        .replace(/\s+/g, ' ');
      const match = label.match(/pending\s+(\d+)\s*[·,].*conflicts\s+\d+/i);
      if (match) return Number(match[1]);
    }
    return null;
  }).catch(() => null);
}

async function waitForPending(page, expected) {
  await waitFor(async () => await visiblePendingCount(page) === expected,
    `visible pending count ${expected}`, 30000, page);
}

async function readClientSqliteFiles(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') return { available: false };
    const databases = await indexedDB.databases();
    if (!databases.some((item) => item.name === 'atermius_vault')) {
      return { available: false };
    }
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('IndexedDB read failed'));
      request.onblocked = () => reject(new Error('IndexedDB read blocked'));
    });
    try {
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        return { available: false };
      }
      const filesTx = db.transaction('files', 'readonly');
      const fileRowsPromise = new Promise((resolve, reject) => {
        const request = filesTx.objectStore('files').getAll();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(new Error('SQLite file metadata read failed'));
      });
      const fileKeysPromise = new Promise((resolve, reject) => {
        const request = filesTx.objectStore('files').getAllKeys();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(new Error('SQLite file keys read failed'));
      });
      const [fileRows, fileKeys] = await Promise.all([fileRowsPromise, fileKeysPromise]);
      const selected = fileRows.map((row, index) => ({
        id: Number(fileKeys[index]), name: String(row?.name || ''), length: Number(row?.length),
      })).filter((row) => row.name === '/database' || row.name === '/database-journal');
      if (!selected.some((row) => row.name === '/database') || selected.some((row) =>
        !Number.isSafeInteger(row.id) || !Number.isSafeInteger(row.length) ||
        row.length < 0 || row.length > 64 * 1024 * 1024)) return { available: false };
      const files = [];
      for (const file of selected) {
        const range = IDBKeyRange.bound([file.id, 0], [file.id, 9007199254740992]);
        const perFileTx = db.transaction('blocks', 'readonly');
        const keysPromise = new Promise((resolve, reject) => {
          const request = perFileTx.objectStore('blocks').getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite block key read failed'));
        });
        const valuesPromise = new Promise((resolve, reject) => {
          const request = perFileTx.objectStore('blocks').getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(new Error('SQLite block read failed'));
        });
        const [keys, values] = await Promise.all([keysPromise, valuesPromise]);
        const blocks = [];
        for (let i = 0; i < keys.length; i += 1) {
          let bytes;
          const value = values[i];
          if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
          else if (ArrayBuffer.isView(value)) {
            bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          } else if (value instanceof Blob) bytes = new Uint8Array(await value.arrayBuffer());
          else throw new Error('unsupported SQLite block value');
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 0x8000) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
          }
          blocks.push({ offset: Number(keys[i]?.[1]), base64: btoa(binary) });
        }
        files.push({ ...file, blocks });
      }
      return { available: true, files };
    } finally { db.close(); }
  });
}

function inspectPendingOperation(sqliteFiles, expectedVaultId) {
  const dbFile = sqliteFiles.files?.find((file) => file.name === '/database');
  const journal = sqliteFiles.files?.find((file) => file.name === '/database-journal');
  if (!sqliteFiles.available || !dbFile || (journal && journal.length !== 0)) {
    return { available: false };
  }
  const snapshotPath = path.join(tempRoot, 'client-pending-snapshot.sqlite');
  const bytes = reconstructSqliteFile({
    fileId: dbFile.id, name: dbFile.name, length: dbFile.length,
    blocks: dbFile.blocks.map((block) => ({
      offset: block.offset, bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try {
    const script = [
      'import hashlib,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)",
      "db.execute('PRAGMA query_only=ON')",
      'vault=sys.argv[2]',
      "rows=db.execute(\"SELECT op_id,vault_id,record_id,base_revision_id,base_envelope_json,envelope_json,status,attempt_count,created_at,last_attempt_at FROM pending_operations WHERE vault_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault,)).fetchall()",
      'def digest(value): return hashlib.sha256(value.encode()).hexdigest() if value is not None else None',
      'result=[]',
      'for row in rows:',
      ' envelope=json.loads(row[5])',
      ' header=envelope.get("header",{}) if isinstance(envelope,dict) else {}',
      ' result.append({"opId":row[0],"vaultId":row[1],"recordId":row[2],"baseRevisionId":row[3],"revisionId":header.get("revision_id"),"operation":header.get("operation"),"baseEnvelopeSha256":digest(row[4]),"envelopeSha256":digest(row[5]),"status":row[6],"attemptCount":row[7],"createdAt":row[8],"lastAttemptAt":row[9]})',
      "checkpoint=db.execute('SELECT cursor,server_generation,sync_status FROM sync_checkpoints WHERE vault_id=?',(vault,)).fetchone()",
      'print(json.dumps({"integrity":db.execute("PRAGMA integrity_check").fetchone()[0],"pending":result,"checkpoint":{"cursorPresent":bool(checkpoint and checkpoint[0]),"cursorSha256":hashlib.sha256(checkpoint[0].encode()).hexdigest() if checkpoint and checkpoint[0] else None,"generation":checkpoint[1] if checkpoint else None,"status":checkpoint[2] if checkpoint else None}},separators=(",",":")))',
    ].join('\n');
    const result = spawnSync('python3', ['-c', script, snapshotPath, expectedVaultId], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) return { available: false };
    return {
      available: true,
      plaintextMarkerFound: PLAINTEXT_MARKERS.some((marker) =>
        bytes.includes(Buffer.from(marker))),
      ...JSON.parse(result.stdout),
    };
  } finally { fs.rmSync(snapshotPath, { force: true }); }
}

async function clientSyncSnapshot(page, vaultId) {
  const idb = await readClientSqliteFiles(page);
  return inspectPendingOperation(idb, vaultId);
}

function samePendingOperationIdentityAndPayload(actual, expected) {
  const immutableFields = [
    'opId', 'vaultId', 'recordId', 'baseRevisionId', 'revisionId', 'operation',
    'baseEnvelopeSha256', 'envelopeSha256', 'createdAt',
  ];
  return Boolean(actual && expected) && immutableFields.every((field) =>
    actual[field] === expected[field]);
}

function serverSnapshot() {
  const script = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)",
    'user=sys.argv[2]',
    "vault=db.execute(\"SELECT v.vault_id,COALESCE(c.last_committed_seq,0) FROM users u JOIN vault_members m ON m.user_id=u.user_id AND m.state='active' JOIN vaults v ON v.vault_id=m.vault_id LEFT JOIN vault_counters c ON c.vault_id=v.vault_id WHERE u.username=? AND v.state='active'\",(user,)).fetchall()",
    "identity=db.execute('SELECT instance_id,server_space_id,generation,signing_public_key,signing_key_transitions_json FROM instance_meta WHERE id=1').fetchone()",
    'print(json.dumps({"vaults":[{"vaultId":r[0],"commitSeq":str(r[1])} for r in vault],"instanceId":identity[0],"serverSpaceId":identity[1],"generation":identity[2],"signingPublicKey":identity[3],"transitionCount":len(json.loads(identity[4] or "[]"))}))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, USERNAME], {
    encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'server metadata query failed');
  const snapshot = JSON.parse(result.stdout);
  assertThat(snapshot.vaults.length === 1, 'account did not have exactly one active Vault');
  return { ...snapshot, ...snapshot.vaults[0] };
}

function readServerLedger(vaultId, operationIds) {
  const script = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)",
    'vault=sys.argv[2]; op_ids=json.loads(sys.argv[3]); markers=json.loads(sys.stdin.read())',
    "heads=db.execute('SELECT record_id,revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? ORDER BY commit_seq',(vault,)).fetchall()",
    "versions=db.execute('SELECT record_id,revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? ORDER BY commit_seq',(vault,)).fetchall()",
    "events=db.execute('SELECT record_id,revision_id,envelope,commit_seq FROM change_events WHERE vault_id=? ORDER BY commit_seq',(vault,)).fetchall()",
    "receipts=db.execute('SELECT op_id,record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id IN (%s)' % ','.join('?' for _ in op_ids),(vault,*op_ids)).fetchall() if op_ids else []",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    'raw= b"".join(open(path,"rb").read() for path in [sys.argv[1],sys.argv[1]+"-wal",sys.argv[1]+"-shm"] if __import__("os").path.exists(path))',
    'def opaque(text):',
    ' try: value=json.loads(text)',
    ' except Exception: return False',
    ' header=value.get("header",{}) if isinstance(value,dict) else {}',
    ' allowed={"wire_version","server_space_id","vault_id","record_id","revision_id","base_revision_id","op_id","device_id","device_seq","key_epoch","membership_version","record_schema","operation","crypto_suite","kdf_salt","object_refs"}',
    ' return set(value)=={"header","nonce","ciphertext","signature"} and isinstance(header,dict) and set(header).issubset(allowed) and all(isinstance(value.get(k),str) and value[k] for k in ("nonce","ciphertext","signature"))',
    'result={"heads":[{"recordId":r[0],"revisionId":r[1],"deleted":bool(r[2]),"commitSeq":str(r[3])} for r in heads],"versionCount":len(versions),"versionOperations":[r[2] for r in versions],"versionsOpaque":len(versions)==2 and all(opaque(r[3]) for r in versions),"eventCount":len(events),"eventsOpaque":len(events)==2 and all(opaque(r[2]) for r in events),"receipts":[{"opId":r[0],"recordId":r[1],"revisionId":r[2],"commitSeq":str(r[3])} for r in receipts],"commitSeq":str(counter[0] if counter else 0),"serverMarkerFound":any(marker.encode() in raw for marker in markers)}',
    'print(json.dumps(result,separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, vaultId,
    JSON.stringify(operationIds)], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    input: JSON.stringify(PLAINTEXT_MARKERS), stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'server ledger query failed');
  return JSON.parse(result.stdout);
}

function serverFingerprint(signingPublicKey) {
  const publicKeyBytes = Buffer.from(signingPublicKey, 'base64url');
  assertThat(publicKeyBytes.length === 32, 'server public signing key was malformed');
  const digest = crypto.createHash('sha256').update(publicKeyBytes).digest('base64')
    .replace(/=+$/g, '');
  return `SHA256:${digest}`;
}

function createRollbackBackup() {
  backupArchivePath = path.join(tempRoot, 'rollback-before-key-rotation.atermius-backup');
  backupKeyPath = path.join(tempRoot, 'rollback-backup.key');
  backupKey = crypto.randomBytes(32);
  fs.writeFileSync(backupKeyPath, backupKey, { flag: 'wx', mode: 0o600 });
  fs.chmodSync(backupKeyPath, 0o600);
  const result = spawnSync(SERVER_BINARY, ['backup', '--archive', backupArchivePath,
    '--key-file', backupKeyPath], {
    cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 60000,
    maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0 && fs.existsSync(backupArchivePath),
    'offline encrypted rollback backup failed');
  assertThat(fs.statSync(backupArchivePath).size > 0 &&
    PLAINTEXT_MARKERS.every((marker) =>
      !fs.readFileSync(backupArchivePath).includes(Buffer.from(marker))),
  'rollback backup archive was empty or contained a plaintext Host marker');
  if (process.platform !== 'win32') {
    assertThat((fs.statSync(backupKeyPath).mode & 0o777) === 0o600,
      'rollback backup key permissions were not private');
  }
}

function rotateServerIdentityKey() {
  const result = spawnSync(SERVER_BINARY, ['rotate-instance-key', '--server-stopped'], {
    cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
    maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0 &&
    (result.stdout || '').includes('old-key transition recorded'),
  'offline instance signing-key rotation failed');
}

function restoreRollbackBackup() {
  restoredDataDir = path.join(tempRoot, 'restored-data');
  const result = spawnSync(SERVER_BINARY, ['restore', '--archive', backupArchivePath,
    '--key-file', backupKeyPath, '--target-data-dir', restoredDataDir,
    '--server-stopped'], {
    cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 90000,
    maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0 && fs.existsSync(restoredDataDir),
    'isolated older SQLite/key restore failed');
  dataDir = restoredDataDir;
  databasePath = path.join(dataDir, 'atermius.db');
  serverEnv = {
    ...serverEnv,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
  };
}

async function openSyncHealth(page) {
  await click(page, 'Sync & conflicts');
  await waitForText(page, 'Sync health');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    if (backupKey) backupKey.fill(0);
    backupKey = undefined;
    snapshotGate?.release.resolve();
    try {
      if (contextB) await contextB.close().catch(() => {});
      if (contextA) await contextA.close().catch(() => {});
      await stopServer();
    } catch (_) { cleanupFailed = true; }
    finally {
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

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Web Release bundle is incomplete');
  }
  const build = spawnSync('cargo', ['build', '--locked', '--manifest-path',
    path.join(ROOT, 'server/Cargo.toml')], {
    cwd: ROOT, timeout: 180000, stdio: 'ignore',
  });
  assertThat(!build.error && build.status === 0, 'server debug build failed');
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-generation-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'data');
  profileAPath = path.join(tempRoot, 'profile-a');
  profileBPath = path.join(tempRoot, 'profile-b');
  for (const directory of [dataDir, profileAPath, profileBPath]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    fs.chmodSync(directory, 0o700);
  }
  databasePath = path.join(dataDir, 'atermius.db');
  const port = await unusedLoopbackPort();
  baseUrl = `http://127.0.0.1:${port}`;
  serverEnv = {
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

  try {
    setStage('isolated server bootstrap');
    await startServer();
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
      maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrap.error && bootstrap.status === 0, 'isolated bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(bootstrapToken && bootstrapToken.length >= 40, 'bootstrap token unavailable');

    setStage('two isolated persistent Chromium profiles');
    const a = await setupPersistentContext(profileAPath, 'A');
    contextA = a.context;
    pageA = a.page;
    const b = await setupPersistentContext(profileBPath, 'B');
    contextB = b.context;
    pageB = b.page;
    await seedIndexedDb(contextA);
    await seedIndexedDb(contextB);

    setStage('profile A owner registration and initial sync checkpoint');
    await initializeFlutter(pageA);
    await fill(pageA, 'Server URL', baseUrl);
    await click(pageA, 'Connect securely');
    await field(pageA, 'Owner email');
    await fill(pageA, 'Owner email', USERNAME);
    await fill(pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(pageA, 'Confirm master password', PASSWORD);
    await fill(pageA, 'One-time bootstrap token', bootstrapToken);
    await fill(pageA, 'Device name', OWNER_DEVICE);
    await fill(pageA, 'First Vault', VAULT_NAME);
    await click(pageA, 'Create owner account');
    bootstrapToken = undefined;
    await waitForWorkspace(pageA);

    let currentServer = serverSnapshot();
    const vaultId = currentServer.vaultId;
    const originalGeneration = currentServer.generation;
    const originalInstanceId = currentServer.instanceId;
    const originalServerSpaceId = currentServer.serverSpaceId;
    const originalSigningPublicKey = currentServer.signingPublicKey;
    const originalFingerprint = serverFingerprint(originalSigningPublicKey);
    const baselineSeq = currentServer.commitSeq;
    assertThat(originalGeneration && /^\d+$/.test(baselineSeq),
      'initial server generation or Vault commit sequence unavailable');
    await waitFor(async () => {
      const local = await clientSyncSnapshot(pageA, vaultId);
      return local.available && local.integrity === 'ok' &&
        local.checkpoint?.cursorPresent &&
        local.checkpoint?.generation === originalGeneration;
    }, 'profile A old-generation cursor checkpoint', 30000, pageA);
    const checkpointA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(checkpointA.pending.length === 0,
      'profile A had an unexpected pending operation before offline edit');

    setStage('profile B trusted-device enrollment and initial checkpoint');
    await initializeFlutter(pageB);
    await fill(pageB, 'Server URL', baseUrl);
    await click(pageB, 'Connect securely');
    const enrollment = await requestDevice(pageB);
    const approval = await approveDevice(pageA, enrollment);
    await importApprovalAndSignIn(pageB, approval);
    await openSyncHealth(pageB);
    const syncBInitial = await button(pageB, 'Sync now');
    if (await syncBInitial.isEnabled()) await syncBInitial.click();
    await waitFor(() => apiEvents.B.some((event) => event.path === 'changes' &&
      event.status === 200), 'profile B initial changes pull', 20000, pageB);
    await waitFor(async () => {
      const local = await clientSyncSnapshot(pageB, vaultId);
      return local.available && local.checkpoint?.cursorPresent &&
        local.checkpoint?.generation === originalGeneration;
    }, 'profile B old-generation cursor checkpoint', 30000, pageB);
    await waitForText(pageB, 'Generation matches', 15000);
    const checkpointB = await clientSyncSnapshot(pageB, vaultId);
    assertThat(checkpointB.available && checkpointB.checkpoint?.cursorPresent &&
      checkpointB.checkpoint?.generation === originalGeneration,
    `profile B did not cache the original server generation and cursor (${JSON.stringify(checkpointB.checkpoint)})`);
    await click(pageB, 'Hosts');

    setStage('profile A durable offline outbox');
    await contextA.setOffline(true);
    await addHost(pageA, HOSTS.A);
    const beforeRotateA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(beforeRotateA.available && beforeRotateA.integrity === 'ok' &&
      beforeRotateA.pending.length === 1 &&
      beforeRotateA.pending[0].status === 'queued' &&
      beforeRotateA.pending[0].vaultId === vaultId &&
      beforeRotateA.checkpoint?.cursorPresent &&
      beforeRotateA.checkpoint?.generation === originalGeneration &&
      !beforeRotateA.plaintextMarkerFound,
    'profile A did not retain exactly one queued Host outbox row offline');
    const pendingBefore = beforeRotateA.pending[0];
    await waitForPending(pageA, 1);

    setStage('profile B independent Host commit');
    await addHost(pageB, HOSTS.B);
    await waitFor(async () => pushEvents.B.some((event) =>
      event.status === 200 && event.operations.some((op) => op.operation === 'create')),
    'profile B Host push commit', 30000, pageB);
    const bPush = pushEvents.B.flatMap((event) => event.operations.map((op, index) => ({
      ...op, status: event.status, receipt: event.receipts[index],
    }))).find((op) => op.status === 200 && op.operation === 'create');
    assertThat(bPush?.opId && bPush.receipt?.opId === bPush.opId &&
      bPush.receipt?.alreadyCommitted === false && bPush.markersAbsent,
    'profile B Host operation did not commit once as an opaque envelope');
    currentServer = serverSnapshot();
    assertThat(currentServer.commitSeq === (BigInt(baselineSeq) + 1n).toString(),
      'profile B did not create exactly one server commit before generation recovery');

    setStage('encrypted backup after B commit, then signed instance-key rotation');
    await stopServer();
    createRollbackBackup();
    rotateServerIdentityKey();
    await startServer();
    currentServer = serverSnapshot();
    assertThat(currentServer.generation !== originalGeneration &&
      currentServer.instanceId === originalInstanceId &&
      currentServer.serverSpaceId === originalServerSpaceId &&
      currentServer.signingPublicKey !== originalSigningPublicKey &&
      currentServer.transitionCount === 1 &&
      currentServer.commitSeq === (BigInt(baselineSeq) + 1n).toString(),
    'signed key rotation changed instance/Vault identity or lost the committed backup state');
    const rotatedFingerprint = serverFingerprint(currentServer.signingPublicKey);
    assertThat(rotatedFingerprint !== originalFingerprint,
      'instance key rotation did not produce a distinct fingerprint');
    const rotatedSigningPublicKey = currentServer.signingPublicKey;
    const rotatedGeneration = currentServer.generation;

    setStage('profile A stores the newer signed-transition pin without syncing its pending row');
    allowAChanges = false;
    allowAPushes = false;
    const beforeNewPinReview = protectedTrafficSnapshot('A');
    await contextA.setOffline(false);
    await initializeFlutter(pageA);
    try {
      await waitForText(pageA, 'Unlock your workspace');
    } catch (error) {
      const state = await safeVisiblePageState(pageA).catch(() => ({ unavailable: true }));
      console.log('profile A signed-transition startup diagnostic', JSON.stringify({
        state,
        apiErrors: startupHttpErrors.A,
        apiRequestFailures: startupRequestFailures.A,
      }));
      throw error;
    }
    await waitFor(async () => pageA.getByRole('button', {
      name: 'Sign in and unlock', exact: true,
    }).isVisible().catch(() => false), 'profile A locked after key rotation', 20000, pageA);
    await waitForNoText(pageA, 'Restored server identity needs confirmation', 20000);
    const profileAAcceptedRotatedIdentity = true;
    assertProtectedTrafficUnchanged('A', beforeNewPinReview,
      'profile A key-transition pin update');
    const afterNewPinA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(afterNewPinA.available && afterNewPinA.integrity === 'ok' &&
      JSON.stringify(afterNewPinA.pending) === JSON.stringify([pendingBefore]) &&
      afterNewPinA.checkpoint?.cursorSha256 === beforeRotateA.checkpoint?.cursorSha256 &&
      afterNewPinA.checkpoint?.generation === originalGeneration &&
      !afterNewPinA.plaintextMarkerFound,
    'profile A transition acceptance changed or exposed the durable pending operation');

    setStage('profile A snapshot recovery after the signed key transition');
    await fill(pageA, 'Email or username', USERNAME);
    await fill(pageA, 'Master password', PASSWORD);
    await click(pageA, 'Sign in and unlock');
    await waitForWorkspace(pageA);
    await openSyncHealth(pageA);
    const beforeRotatedSnapshotA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(beforeRotatedSnapshotA.available &&
      beforeRotatedSnapshotA.integrity === 'ok' &&
      JSON.stringify(beforeRotatedSnapshotA.pending) === JSON.stringify([pendingBefore]) &&
      beforeRotatedSnapshotA.checkpoint?.generation === originalGeneration &&
      beforeRotatedSnapshotA.checkpoint?.cursorPresent &&
      !beforeRotatedSnapshotA.plaintextMarkerFound,
    'profile A did not retain its exact pending row and old cursor behind the rotated-generation local gate');
    const rotatedSnapshotPushCount = pushEvents.A.flatMap((event) => event.operations)
      .filter((operation) => operation.opId === pendingBefore.opId).length;
    const rotatedSnapshotGetCount = apiEvents.A.filter((event) =>
      event.path === 'snapshot-get' && event.status === 200).length;
    const rotatedSnapshotServer = serverSnapshot();
    const rotatedGateChangeCount = syncRequestCounts.A.changes;
    const rotatedSnapshotAction = pageA.getByRole('button', {
      name: 'Rebuild snapshot', exact: true,
    });
    const rotatedGateSync = await button(pageA, 'Sync now');
    assertThat(await rotatedGateSync.isEnabled(),
      'profile A rotated-generation Sync now action is disabled');
    await rotatedGateSync.click();
    await waitForText(pageA, 'Snapshot needed', 20000);
    assertThat(syncRequestCounts.A.changes === rotatedGateChangeCount,
      'profile A sent a changes request despite the local rotated-generation checkpoint gate');
    try {
      await waitFor(async () => rotatedSnapshotAction.isVisible().catch(() => false) &&
        rotatedSnapshotAction.isEnabled().catch(() => false),
      'profile A enabled signed-transition generation snapshot rebuild', 20000, pageA);
    } catch (error) {
      const state = await safeVisiblePageState(pageA).catch(() => ({ unavailable: true }));
      console.log('profile A signed-transition snapshot-action diagnostic', JSON.stringify({
        state,
        actionCount: await rotatedSnapshotAction.count().catch(() => -1),
        actionVisible: await rotatedSnapshotAction.isVisible().catch(() => false),
        actionEnabled: await rotatedSnapshotAction.isEnabled().catch(() => false),
        changesRequests: syncRequestCounts.A.changes,
      }));
      throw error;
    }
    await rotatedSnapshotAction.click();
    await waitForText(pageA, 'Retry queued', 45000);
    await waitForText(pageA, 'Generation matches', 15000);
    await waitForPending(pageA, 1);
    allowAChanges = false;
    const afterRotatedSnapshotA = await clientSyncSnapshot(pageA, vaultId);
    const rotatedSnapshotEvidence = {
      databaseIntegrityOk: afterRotatedSnapshotA.available &&
        afterRotatedSnapshotA.integrity === 'ok',
      pendingOperationIdentityAndPayloadUnchanged:
        afterRotatedSnapshotA.pending.length === 1 &&
        samePendingOperationIdentityAndPayload(afterRotatedSnapshotA.pending[0],
          pendingBefore),
      checkpointGenerationG1: afterRotatedSnapshotA.checkpoint?.generation ===
        rotatedGeneration,
      retryQueuedAfterBlockedPush:
        afterRotatedSnapshotA.checkpoint?.status === 'retry_wait',
      cursorPresent: afterRotatedSnapshotA.checkpoint?.cursorPresent === true,
      cursorAdvancedFromOld: afterRotatedSnapshotA.checkpoint?.cursorSha256 !==
        beforeRotatedSnapshotA.checkpoint?.cursorSha256 &&
        afterRotatedSnapshotA.checkpoint?.cursorSha256 !==
          beforeRotateA.checkpoint?.cursorSha256,
      noSuccessfulPendingPush: pushEvents.A.flatMap((event) => event.operations)
        .filter((operation) => operation.opId === pendingBefore.opId).length ===
          rotatedSnapshotPushCount,
      oneSnapshotGet: apiEvents.A.filter((event) => event.path === 'snapshot-get' &&
        event.status === 200).length === rotatedSnapshotGetCount + 1,
      serverCommitSeqUnchanged: serverSnapshot().commitSeq ===
        rotatedSnapshotServer.commitSeq,
      noPlaintextMarker: !afterRotatedSnapshotA.plaintextMarkerFound,
    };
    const rotatedSnapshotPendingBaseline = afterRotatedSnapshotA.pending;
    console.log('rotated snapshot safe assertions', JSON.stringify({
      ...rotatedSnapshotEvidence,
      retryMetadata: afterRotatedSnapshotA.pending[0] ? {
        status: afterRotatedSnapshotA.pending[0].status,
        attemptCount: afterRotatedSnapshotA.pending[0].attemptCount,
        lastAttemptAtChanged: afterRotatedSnapshotA.pending[0].lastAttemptAt !==
          pendingBefore.lastAttemptAt,
      } : null,
    }));
    assertThat(Object.values(rotatedSnapshotEvidence).every(Boolean),
      'profile A rotated-key snapshot did not retain the exact outbox or create a rotated-generation cursor without pushing');
    const beforePhysicalRollback = protectedTrafficSnapshot('A');

    setStage('restore the older encrypted SQLite and instance-key snapshot');
    allowBChanges = false;
    await stopServer();
    restoreRollbackBackup();
    await startServer();
    currentServer = serverSnapshot();
    assertThat(currentServer.instanceId === originalInstanceId &&
      currentServer.serverSpaceId === originalServerSpaceId &&
      currentServer.signingPublicKey === originalSigningPublicKey &&
      currentServer.transitionCount === 0 &&
      currentServer.generation !== originalGeneration &&
      currentServer.commitSeq === (BigInt(baselineSeq) + 1n).toString(),
    'restored server did not return to the older key/database with a fresh generation');

    setStage('profile A requires exact independent-channel rollback fingerprint confirmation');
    await initializeFlutter(pageA);
    const rollbackSemantics = pageA.locator('flt-semantics');
    const rollbackFingerprintField = pageA.locator(
      'input[aria-label*="Type the candidate fingerprint exactly"]');
    const rollbackExpectedSemantics = [
      `Previously trusted fingerprint · SHA-256: ${rotatedFingerprint}`,
      `Fingerprint returned by this server · SHA-256: ${originalFingerprint}`,
      `Instance ID: ${originalInstanceId}`,
      `Server-space ID: ${originalServerSpaceId}`,
    ];
    try {
      await waitFor(() => rollbackFingerprintField.isVisible().catch(() => false),
        'visible exact candidate fingerprint entry field', 20000, pageA);
      await waitFor(async () => {
        const content = await rollbackSemantics.evaluateAll((nodes) =>
          nodes.filter((node) => node.getClientRects().length > 0)
            .map((node) => `${node.innerText || ''} ${node.getAttribute('aria-label') || ''}`));
        return rollbackExpectedSemantics.every((expected) =>
          content.some((item) => item.includes(expected)));
      }, 'exact rollback fingerprints and instance identifiers in visible semantics', 20000,
      pageA);
    } catch (error) {
      const state = await safeVisiblePageState(pageA).catch(() => ({ unavailable: true }));
      const diagnostic = {
        state,
        fingerprintFieldVisible: await rollbackFingerprintField.isVisible()
          .catch(() => false),
        visibleSemantics: await rollbackSemantics.evaluateAll(
          (nodes) => nodes.filter((node) => node.getClientRects().length > 0)
            .map((node) => ({
              text: (node.innerText || '').slice(0, 500),
              label: (node.getAttribute('aria-label') || '').slice(0, 500),
            }))).catch(() => []),
      };
      await pageA.screenshot({ path: '/tmp/atermius-rollback-review.png', fullPage: false })
        .catch(() => {});
      console.log('rollback fingerprint review visible-state diagnostic',
        JSON.stringify(diagnostic));
      throw error;
    }
    await waitForText(pageA, originalInstanceId, 20000);
    await waitForText(pageA, originalServerSpaceId, 20000);
    const candidateReviewA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(candidateReviewA.available && candidateReviewA.integrity === 'ok' &&
      JSON.stringify(candidateReviewA.pending) ===
        JSON.stringify(rotatedSnapshotPendingBaseline) &&
      candidateReviewA.checkpoint?.cursorSha256 ===
        afterRotatedSnapshotA.checkpoint?.cursorSha256 &&
      candidateReviewA.checkpoint?.generation === rotatedGeneration &&
      !candidateReviewA.plaintextMarkerFound,
    'rollback identity review changed the encrypted pending outbox or old checkpoint');
    assertProtectedTrafficUnchanged('A', beforePhysicalRollback,
      'profile A rollback identity review');

    await fillSemanticField(pageA, 'Type the candidate fingerprint exactly',
      rotatedFingerprint);
    const confirmRecoveryA = await button(pageA, 'Confirm fingerprint and continue');
    assertThat(!(await confirmRecoveryA.isEnabled()),
      'profile A enabled confirmation for the old pinned fingerprint instead of the candidate');
    assertProtectedTrafficUnchanged('A', beforePhysicalRollback,
      'profile A wrong fingerprint entry');
    await fillSemanticField(pageA, 'Type the candidate fingerprint exactly',
      originalFingerprint);
    assertThat(await confirmRecoveryA.isEnabled(),
      'profile A did not enable exact candidate fingerprint confirmation');
    assertProtectedTrafficUnchanged('A', beforePhysicalRollback,
      'profile A exact fingerprint entry before confirmation');
    await confirmRecoveryA.click();
    await waitForText(pageA, 'Unlock your workspace', 20000);
    await field(pageA, 'Email or username');
    await waitForNoText(pageA, 'Restored server identity needs confirmation', 10000);
    assertProtectedTrafficUnchanged('A', beforePhysicalRollback,
      'profile A identity confirmation before sign-in');
    const afterConfirmedIdentityA = await clientSyncSnapshot(pageA, vaultId);
    assertThat(afterConfirmedIdentityA.available &&
      JSON.stringify(afterConfirmedIdentityA.pending) ===
        JSON.stringify(rotatedSnapshotPendingBaseline) &&
      afterConfirmedIdentityA.checkpoint?.cursorSha256 ===
        afterRotatedSnapshotA.checkpoint?.cursorSha256 &&
      afterConfirmedIdentityA.checkpoint?.generation === rotatedGeneration,
    'profile A identity confirmation changed the pending operation or cursor');

    setStage('profile A signs in only after explicit rollback confirmation');
    const aChangesBeforeRestoreLogin = syncRequestCounts.A.changes;
    await fill(pageA, 'Email or username', USERNAME);
    await fill(pageA, 'Master password', PASSWORD);
    await click(pageA, 'Sign in and unlock');
    await waitForWorkspace(pageA);
    assertThat(authRequests.A.slice(beforePhysicalRollback.auth)
      .some((request) => request.path.endsWith('/prelogin')) &&
      authRequests.A.slice(beforePhysicalRollback.auth)
        .some((request) => request.path.endsWith('/login')),
    'profile A sign-in after confirmation did not complete prelogin and login');
    await openSyncHealth(pageA);
    assertThat(syncRequestCounts.A.changes === aChangesBeforeRestoreLogin,
      'profile A sent a changes request before the explicit post-restore sync action');
    setStage('profile B re-authenticates to the restored instance');
    allowBChanges = false;
    await initializeFlutter(pageB);
    await waitForText(pageB, 'Unlock your workspace');
    const bChangesBeforeRestoreLogin = syncRequestCounts.B.changes;
    await fill(pageB, 'Email or username', USERNAME);
    await fill(pageB, 'Master password', PASSWORD);
    await click(pageB, 'Sign in and unlock');
    await waitForWorkspace(pageB);
    assertThat(!(await pageB.getByText('Restored server identity needs confirmation', {
      exact: true,
    }).isVisible().catch(() => false)),
    'profile B matching older identity unexpectedly required a re-pin');
    await openSyncHealth(pageB);
    const restoreGateSyncB = await button(pageB, 'Sync now');
    assertThat(await restoreGateSyncB.isEnabled(),
      'profile B restore-generation Sync now action is disabled');
    await restoreGateSyncB.click();
    await waitFor(async () => {
      const action = await button(pageB, 'Rebuild snapshot').catch(() => null);
      return action ? action.isEnabled() : false;
    }, 'profile B restore-generation snapshot gate', 20000, pageB);
    await waitForText(pageB, 'Generation mismatch', 15000);
    const afterRestoreLoginB = await clientSyncSnapshot(pageB, vaultId);
    assertThat(afterRestoreLoginB.available && afterRestoreLoginB.pending.length === 0 &&
      afterRestoreLoginB.checkpoint?.generation === originalGeneration &&
      afterRestoreLoginB.checkpoint?.generation !== currentServer.generation &&
      afterRestoreLoginB.checkpoint?.status === 'resnapshot_required' &&
      syncRequestCounts.B.changes === bChangesBeforeRestoreLogin,
    'profile B did not expose the local generation-mismatch recovery without an unnecessary changes request');

    setStage('anonymous Sync Health diagnostics download and privacy audit');
    const diagnosticsPath = path.join(tempRoot, 'sync-health-diagnostics.json');
    const diagnosticApiRequests = [];
    const diagnosticRequestListener = (request) => {
      const url = new URL(request.url());
      if (url.origin === baseUrl && url.pathname.startsWith('/api/')) {
        diagnosticApiRequests.push(request.method());
      }
    };
    const syncRequestsBeforeDiagnostic = { ...syncRequestCounts.B };
    pageB.on('request', diagnosticRequestListener);
    let diagnosticDownload;
    try {
      const downloadPromise = pageB.waitForEvent('download', { timeout: 30000 });
      await (await button(pageB, 'Export diagnostics')).click();
      diagnosticDownload = await downloadPromise;
      assertThat(diagnosticDownload.suggestedFilename() ===
        'atermius-sync-diagnostics.json',
      'diagnostics download used an identifying filename');
      await diagnosticDownload.saveAs(diagnosticsPath);
    } finally {
      pageB.off('request', diagnosticRequestListener);
    }
    assertThat(diagnosticApiRequests.length === 0 &&
      syncRequestCounts.B.changes === syncRequestsBeforeDiagnostic.changes &&
      syncRequestCounts.B.snapshots === syncRequestsBeforeDiagnostic.snapshots &&
      syncRequestCounts.B.pushes === syncRequestsBeforeDiagnostic.pushes,
    'explicit diagnostics export caused an API or sync request');
    const diagnosticsBytes = fs.readFileSync(diagnosticsPath);
    assertThat(diagnosticsBytes.length > 0 && diagnosticsBytes.length <= 2048,
      'diagnostics download was empty or exceeded the 2 KiB bound');
    const diagnosticsText = diagnosticsBytes.toString('utf8');
    const diagnostics = JSON.parse(diagnosticsText);
    assertThat(JSON.stringify(Object.keys(diagnostics).sort()) === JSON.stringify([
      'client_version', 'counts', 'diagnostic_id', 'error_code', 'times',
    ]), 'diagnostics JSON did not match its top-level allowlist');
    assertThat(diagnostics.error_code === 'GENERATION_MISMATCH' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
        diagnostics.diagnostic_id) &&
      /^\d+\.\d+\.\d+\+\d+$/.test(diagnostics.client_version),
    'diagnostics did not contain the fixed mismatch code, random UUIDv4 and app version');
    assertThat(JSON.stringify(Object.keys(diagnostics.counts).sort()) === JSON.stringify([
      'conflicts', 'pending', 'received', 'unavailable_cached_records',
    ]) && Object.values(diagnostics.counts).every((count) =>
      Number.isSafeInteger(count) && count >= 0 && count <= 1000000),
    'diagnostics counts were not a bounded aggregate allowlist');
    assertThat(JSON.stringify(Object.keys(diagnostics.times).sort()) === JSON.stringify([
      'exported_day_utc', 'last_success_day_utc',
    ]) && /^\d{4}-\d{2}-\d{2}$/.test(diagnostics.times.exported_day_utc) &&
      (diagnostics.times.last_success_day_utc === null ||
        /^\d{4}-\d{2}-\d{2}$/.test(diagnostics.times.last_success_day_utc)),
    'diagnostics timestamps were not redacted to UTC days');
    for (const marker of [USERNAME, PASSWORD, OWNER_DEVICE, SECOND_DEVICE, VAULT_NAME,
      vaultId, originalInstanceId, originalServerSpaceId, originalGeneration,
      currentServer.generation, ...PLAINTEXT_MARKERS]) {
      assertThat(!diagnosticsText.includes(marker),
        'diagnostics export contained an account, Vault, server, generation or Host marker');
    }

    setStage('profile A snapshot recovery after restore generation mismatch');
    snapshotGate = { seen: deferred(), release: deferred() };
    const pushCountBeforeSnapshot = syncRequestCounts.A.pushes;
    const snapshotCountBeforeRestoreGate = syncRequestCounts.A.snapshots;
    const snapshotGetCountBeforeRestoreGate = apiEvents.A.filter((event) =>
      event.path === 'snapshot-get' && event.status === 200).length;
    const serverBeforeSnapshot = serverSnapshot();
    const restoreGateChangeCount = syncRequestCounts.A.changes;
    const restoreGateSyncA = await button(pageA, 'Sync now');
    assertThat(await restoreGateSyncA.isEnabled(),
      'profile A restore-generation Sync now action is disabled');
    await restoreGateSyncA.click();
    await waitForText(pageA, 'Snapshot needed', 20000);
    assertThat(syncRequestCounts.A.changes === restoreGateChangeCount,
      'profile A sent a changes request despite the local restore-generation checkpoint gate');
    const rebuildA = pageA.getByRole('button', {
      name: 'Rebuild snapshot', exact: true,
    });
    await waitFor(async () => rebuildA.isVisible().catch(() => false) &&
      rebuildA.isEnabled().catch(() => false),
    'profile A restore-generation snapshot gate', 20000, pageA);
    await rebuildA.click();
    await Promise.race([
      snapshotGate.seen.promise,
      new Promise((_, reject) => setTimeout(() =>
        reject(new Error('profile A snapshot fetch did not reach the gate')), 30000)),
    ]);
    assertThat(syncRequestCounts.A.snapshots === snapshotCountBeforeRestoreGate + 1,
      'profile A did not start exactly one snapshot request after the local restore-generation gate');
    await waitForText(pageA,
      'Snapshot verification is in progress. Local edits are paused; the existing cache and outbox remain intact until the full manifest verifies.',
      15000);
    const duringSnapshotA = await clientSyncSnapshot(pageA, vaultId);
    const serverWhileSnapshotHeld = serverSnapshot();
    const snapshotGateEvidence = {
      clientDatabaseOk: duringSnapshotA.available && duringSnapshotA.integrity === 'ok',
      pendingRowExactlyUnchanged: JSON.stringify(duringSnapshotA.pending) ===
        JSON.stringify(rotatedSnapshotPendingBaseline) &&
        duringSnapshotA.pending.length === 1 &&
        samePendingOperationIdentityAndPayload(duringSnapshotA.pending[0], pendingBefore),
      preRecoveryCursorRetained: duringSnapshotA.checkpoint?.cursorPresent === true &&
        duringSnapshotA.checkpoint?.cursorSha256 ===
          afterRotatedSnapshotA.checkpoint?.cursorSha256 &&
        duringSnapshotA.checkpoint?.generation === rotatedGeneration,
      checkpointStatusSnapshotRecovering:
        afterRotatedSnapshotA.checkpoint?.status !== 'snapshot_recovering' &&
        duringSnapshotA.checkpoint?.status === 'snapshot_recovering',
      localPlaintextMarkerAbsent: !duringSnapshotA.plaintextMarkerFound,
      noPushWhileHeld: syncRequestCounts.A.pushes === pushCountBeforeSnapshot,
      noChangesRequestForLocalGenerationMismatch:
        syncRequestCounts.A.changes === restoreGateChangeCount,
      onePendingSnapshotGet: apiEvents.A.filter((event) => event.path === 'snapshot-get' &&
        event.status === 200).length === snapshotGetCountBeforeRestoreGate,
      serverCommitSeqUnchanged: serverWhileSnapshotHeld.commitSeq ===
        serverBeforeSnapshot.commitSeq,
    };
    console.log('snapshot gate safe assertions', JSON.stringify(snapshotGateEvidence));
    assertThat(Object.values(snapshotGateEvidence).every(Boolean),
    'snapshot verification changed the exact pending row or pushed before snapshot completion');
    allowAPushes = true;
    snapshotGate.release.resolve();
    await waitForText(pageA, '快照恢复完成', 45000);
    await waitForPending(pageA, 0);
    await waitFor(async () => pushEvents.A.some((event) => event.status === 200 &&
      event.operations.some((op) => op.opId === pendingBefore.opId)),
    'profile A post-snapshot pending operation push', 30000, pageA);
    const aOperationPushes = pushEvents.A.flatMap((event) => event.operations
      .filter((operation) => operation.opId === pendingBefore.opId)
      .map((operation) => ({ ...operation, status: event.status,
        receipt: event.receipts.find((item) => item.opId === operation.opId) })));
    assertThat(aOperationPushes.length === 1 && aOperationPushes[0].status === 200 &&
      aOperationPushes[0].receipt?.revisionId === pendingBefore.revisionId &&
      aOperationPushes[0].receipt?.commitSeq === (BigInt(baselineSeq) + 2n).toString() &&
      aOperationPushes[0].receipt?.alreadyCommitted === false &&
      aOperationPushes[0].markersAbsent,
      'profile A pending outbox was not pushed exactly once after verified snapshot recovery');
    snapshotGate = null;

    setStage('profile B snapshot recovery after restore generation mismatch');
    const rebuildB = await button(pageB, 'Rebuild snapshot');
    assertThat(await rebuildB.isEnabled(),
      'profile B restore-generation mismatch did not expose Rebuild snapshot');
    await rebuildB.click();
    await waitForText(pageB, '快照恢复完成', 45000);
    await waitForPending(pageB, 0);
    await click(pageA, 'Hosts');
    await click(pageB, 'Hosts');
    await waitForText(pageA, HOSTS.A.name, 20000);
    await waitForText(pageA, HOSTS.B.name, 20000);
    await waitForText(pageB, HOSTS.A.name, 20000);
    await waitForText(pageB, HOSTS.B.name, 20000);

    setStage('receipt, head, event, plaintext and browser-error audit');
    const finalServer = serverSnapshot();
    const ledger = readServerLedger(vaultId, [bPush.opId, pendingBefore.opId]);
    const finalLocalA = await clientSyncSnapshot(pageA, vaultId);
    const finalLocalB = await clientSyncSnapshot(pageB, vaultId);
    assertThat(finalServer.generation !== originalGeneration &&
      finalServer.commitSeq === (BigInt(baselineSeq) + 2n).toString() &&
      ledger.commitSeq === finalServer.commitSeq && ledger.versionCount === 2 &&
      ledger.eventCount === 2 && ledger.receipts.length === 2 &&
      ledger.heads.length === 2 && ledger.versionsOpaque && ledger.eventsOpaque &&
      ledger.versionOperations.every((operation) => operation === 'create') &&
      !ledger.serverMarkerFound && finalServer.instanceId === originalInstanceId &&
      finalServer.serverSpaceId === originalServerSpaceId &&
      finalServer.signingPublicKey === originalSigningPublicKey &&
      finalServer.transitionCount === 0 &&
      finalServer.generation !== originalGeneration &&
      bPush.receipt?.commitSeq === (BigInt(baselineSeq) + 1n).toString() &&
      ledger.receipts.some((receipt) => receipt.opId === bPush.opId &&
        receipt.commitSeq === (BigInt(baselineSeq) + 1n).toString()) &&
      ledger.receipts.some((receipt) => receipt.opId === pendingBefore.opId &&
        receipt.commitSeq === (BigInt(baselineSeq) + 2n).toString()) &&
      finalLocalA.available && finalLocalA.integrity === 'ok' &&
      finalLocalA.pending.length === 0 && !finalLocalA.plaintextMarkerFound &&
      finalLocalA.checkpoint?.generation === finalServer.generation &&
      finalLocalB.available && finalLocalB.integrity === 'ok' &&
      finalLocalB.pending.length === 0 && !finalLocalB.plaintextMarkerFound &&
      finalLocalB.checkpoint?.generation === finalServer.generation,
    'rotated generation did not retain exactly two opaque, unique Host commits');
    for (const expected of [bPush, pendingBefore]) {
      assertThat(ledger.receipts.some((receipt) => receipt.opId === expected.opId &&
        receipt.recordId === expected.recordId && receipt.revisionId === expected.revisionId),
      'a browser operation did not have exactly one matching durable receipt');
      assertThat(ledger.heads.some((head) => head.recordId === expected.recordId &&
        head.revisionId === expected.revisionId && !head.deleted),
      'a browser operation is not the current server record head');
    }
    assertThat(pageErrors.A === 0 && pageErrors.B === 0,
      'one or more Chromium profiles raised a page error');
    assertThat([...apiEvents.A, ...apiEvents.B].every((event) =>
      event.markersAbsent !== false) &&
      [...pushEvents.A, ...pushEvents.B].every((event) =>
        event.operations.every((operation) => operation.markersAbsent)),
    'sync API traffic contained a Host plaintext marker');
    assertThat(apiEvents.A.filter((event) => event.path === 'snapshot-get' &&
      event.status === 200).length === 2 &&
      apiEvents.B.filter((event) => event.path === 'snapshot-get' &&
        event.status === 200).length === 1,
    'profile A did not fetch exactly two successful snapshots (rotated-key cursor preparation and rollback recovery) or B fetched an unexpected count');

    console.log('WEB-SYNC-GENERATION-01 passed', JSON.stringify({
      originalGenerationChanged: finalServer.generation !== originalGeneration,
      pendingOutboxPreservedDuringSnapshot: true,
      pendingOperationPushCount: aOperationPushes.length,
      changes410ObservedInBrowser: {
        A: apiEvents.A.filter((event) => event.path === 'changes' && event.status === 410).length,
        B: apiEvents.B.filter((event) => event.path === 'changes' && event.status === 410).length,
      },
      restoreGenerationRecovery: {
        ARebuildOfferedByLocalGenerationGate: true,
        BRebuildOfferedByLocalGenerationGate: true,
        noChangesRequestBeforeSnapshot: true,
      },
      commits: { baseline: baselineSeq, final: finalServer.commitSeq, versions: ledger.versionCount },
      serverIdentityPreserved: finalServer.instanceId === originalInstanceId &&
        finalServer.serverSpaceId === originalServerSpaceId,
      bothProfilesDecryptedBothHosts: true,
      plaintextMarkersFound: ledger.serverMarkerFound,
      browserPageErrors: pageErrors,
      identityRollback: {
        newerKeyWasAcceptedThroughSignedTransition:
          profileAAcceptedRotatedIdentity &&
          rotatedSigningPublicKey !== originalSigningPublicKey,
        olderDbAndKeyRestored: finalServer.signingPublicKey === originalSigningPublicKey &&
          finalServer.transitionCount === 0,
        exactOutOfBandFingerprintRequired: true,
        noAuthOrSyncBeforeConfirmation: true,
      },
    }));
  } finally {
    await cleanup();
    assertThat(!cleanupFailed, 'fixture cleanup failed');
    console.log('fixture cleanup: completed');
  }
}

main().catch(async (error) => {
  console.error(`WEB-SYNC-GENERATION-01 failed at ${stage}: ${error?.name || 'Error'}: ${error?.message || 'unknown failure'}`);
  await cleanup().catch(() => {});
  process.exitCode = 1;
});
