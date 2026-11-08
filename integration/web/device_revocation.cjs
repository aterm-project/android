/*
 * WEB-DEVICE-REVOKE-01: revoke one enrolled Web device from the Owner UI,
 * prove a fresh device-list response reflects revocation, then prove the
 * revoked profile's encrypted local outbox survives its next denied sync.
 *
 * This runner uses a disposable loopback server, Chromium profiles, account,
 * and Web bundle state. Logs contain stage names and boolean/status evidence
 * only; device IDs, credentials, tokens, and API response bodies are not
 * written to stdout.
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
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const EXPECTED_BUNDLE_SHA256 =
  '9156745a70fb84e17ec75ae1762dac01eef70511bc76fecf04572977a85a374c';
const RUN_ID = crypto.randomUUID();
const USERNAME = `device-revoke-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `Device-${crypto.randomBytes(24).toString('base64url')}`;
const DEVICE_A_NAME = 'Web revoke Owner';
const DEVICE_B_NAME = 'Web revoke target';
const HOST_NAME = `offline-revoke-${RUN_ID.slice(0, 8)}`;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let ownerContext;
let targetContext;
let ownerPage;
let targetPage;
let bootstrapToken;
let ownerDeviceId;
let targetDeviceId;
let cleanupPromise;
let cleanupFailed = false;
const ownerDeviceSnapshots = [];
const protectedResponses = [];
const protectedRequests = [];
const requestStartedAt = new WeakMap();
const requestMetadata = new WeakMap();

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function buildServer() {
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 180000,
  });
  assertThat(!result.error && result.status === 0 && fs.existsSync(SERVER_BINARY),
    'isolated server build failed');
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
      // Continue polling while the disposable service starts.
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
    if (error.code !== 'ESRCH') throw new Error('server process cleanup failed');
  }
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline && processGroupHasLiveMembers(groupId)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  const killDeadline = Date.now() + 2500;
  while (Date.now() < killDeadline && processGroupHasLiveMembers(groupId)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (processGroupHasLiveMembers(groupId)) throw new Error('server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    ownerDeviceId = undefined;
    targetDeviceId = undefined;
    for (const context of [ownerContext, targetContext]) {
      if (context) await context.close().catch(() => {});
    }
    if (browser) await browser.close().catch(() => {});
    try {
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupFailed = true;
      } catch (_) {
        cleanupFailed = true;
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function waitFor(predicate, timeoutMs = 20000, message = 'expected browser state did not appear') {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = [];
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible()) visible.push(candidate);
    }
    assertThat(visible.length <= 1, `field '${label}' was ambiguous`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`field '${label}' was not visible`);
}

async function button(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible()) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button '${label}' was not found`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 35 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      return;
    }
  }
  throw new Error(`field '${label}' did not retain its value`);
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(200);
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `field '${label}' rejected fixture data`);
}

async function enableSemantics(page) {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  30000, 'Flutter Web semantics did not start');
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.locator('flt-semantics').count().then((count) => count > 0),
    15000, 'Flutter Web semantics tree did not appear');
}

async function waitForText(page, expected, timeoutMs = 20000) {
  await waitFor(() => page.evaluate((text) => {
    const values = [document.body.innerText, ...[...document.querySelectorAll('flt-semantics')]
      .flatMap((node) => [node.innerText || '', node.getAttribute('aria-label') || ''])];
    return values.some((value) => value.includes(text));
  }, expected), timeoutMs, 'expected UI state was not visible');
}

async function waitWorkspace(page) {
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
}

async function connect(page, baseUrl) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

function issueCliToken(args, environment, label) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: environment,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `${label} issuance failed`);
  const token = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(typeof token === 'string', `${label} was unavailable`);
  return token;
}

async function waitForPendingAtLeast(page, minimum) {
  let last = null;
  await waitFor(async () => {
    last = await pendingCount(page);
    return last !== null && last >= minimum;
  }, 20000, 'offline operation did not remain queued');
  return last;
}

async function pendingCount(page) {
  return page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    for (const node of nodes) {
      const value = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      const match = value.match(/Pending sync\D{0,60}(\d+)/i);
      if (match) return Number(match[1]);
    }
    for (const node of nodes.filter((item) => item.getAttribute('role') === 'button')) {
      const value = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
      const match = value.match(/(?:pending\s*(\d+)|(\d+)\s*pending)/i);
      if (match) return Number(match[1] || match[2]);
      if (/\bIdle\b/.test(value)) return 0;
    }
    return null;
  }).catch(() => null);
}

async function addOfflineHost(page) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitForText(page, 'Add a host');
  await fill(page, 'Display name', HOST_NAME);
  await fill(page, 'Hostname or IP', '192.0.2.68');
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'offline-revoke-fixture');
  await click(page, 'Save encrypted host');
  await waitFor(() => page.locator('flt-semantics[role="group"]').evaluateAll((nodes, prefix) =>
    nodes.some((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 &&
        (node.getAttribute('aria-label') || '').startsWith(prefix);
    }), `Host: ${HOST_NAME};`), 20000, 'offline Host was not visible in the target profile');
}

async function readClientDatabaseFromIndexedDb(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') return { available: false };
    const databases = await indexedDB.databases();
    if (!databases.some((database) => database.name === 'atermius_vault')) {
      return { available: false };
    }
    const connection = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IndexedDB open failed'));
      request.onblocked = () => reject(new Error('IndexedDB open blocked'));
    });
    try {
      if (!connection.objectStoreNames.contains('files') ||
          !connection.objectStoreNames.contains('blocks')) return { available: false };
      const filesTx = connection.transaction('files', 'readonly');
      const filesStore = filesTx.objectStore('files');
      const [values, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesStore.getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file rows unavailable'));
        }),
        new Promise((resolve, reject) => {
          const request = filesStore.getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file keys unavailable'));
        }),
        new Promise((resolve, reject) => {
          filesTx.oncomplete = resolve;
          filesTx.onerror = () => reject(filesTx.error || new Error('file transaction failed'));
          filesTx.onabort = () => reject(filesTx.error || new Error('file transaction aborted'));
        }),
      ]);
      const files = values.map((value, index) => ({
        fileId: Number(keys[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal');
      const databaseFile = files.find((file) => file.name === '/database');
      if (!databaseFile || files.some((file) => !Number.isSafeInteger(file.fileId) ||
          !Number.isSafeInteger(file.length) || file.length < 0 ||
          file.length > 64 * 1024 * 1024)) return { available: false };
      const blocksTx = connection.transaction('blocks', 'readonly');
      const store = blocksTx.objectStore('blocks');
      const sqliteFiles = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0],
          [file.fileId, Number.MAX_SAFE_INTEGER]);
        const [blockKeys, blockValues] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = store.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('block keys unavailable'));
          }),
          new Promise((resolve, reject) => {
            const request = store.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('blocks unavailable'));
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
            } else throw new Error('unsupported SQLite block value');
            let binary = '';
            for (let offset = 0; offset < bytes.length; offset += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
            }
            return { offset: Number(key?.[1]), base64: btoa(binary) };
          }),
        };
      }));
      await new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('block transaction failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('block transaction aborted'));
      });
      return { available: true, sqliteFiles };
    } finally {
      connection.close();
    }
  });
}

function inspectPendingOutbox(sqliteFiles, snapshotPath) {
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'client SQLite snapshot was incomplete');
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
  const script = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute(\"SELECT op_id,record_id,envelope_json,status FROM pending_operations WHERE status!='superseded' ORDER BY created_at,op_id\").fetchall()",
    'def canonical(value): return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    'operations=[]',
    'for op_id,record_id,envelope_json,status in rows:',
    '    envelope=json.loads(envelope_json)',
    '    header=envelope.get("header",{})',
    '    operations.append({"opId":op_id,"recordId":record_id,"revisionId":header.get("revision_id"),"operation":header.get("operation"),"hash":hashlib.sha256(canonical(envelope).encode()).hexdigest(),"status":status})',
    'print(json.dumps({"integrity":integrity,"operations":operations},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', script, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only client outbox inspection failed');
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function installApiEvidence(page, profile) {
  page.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (!url.pathname.startsWith('/api/')) return;
    requestStartedAt.set(request, Date.now());
    const authorization = request.headers().authorization || '';
    const routeTag = url.pathname === '/api/v1/devices'
      ? 'account-devices'
      : /^\/api\/v1\/vaults\/[^/]+\/devices$/.test(url.pathname)
      ? 'vault-devices'
      : /^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(url.pathname)
      ? 'sync-push'
      : /^\/api\/v1\/vaults\/[^/]+\/changes$/.test(url.pathname)
      ? 'sync-changes'
      : url.pathname.startsWith('/api/')
      ? 'other-api'
      : null;
    requestMetadata.set(request, {
      profile,
      method: request.method(),
      routeTag,
      authorizationPresent: authorization.startsWith('Bearer '),
      path: url.pathname,
    });
    if (profile === 'target' &&
        ['vault-devices', 'sync-push', 'sync-changes'].includes(routeTag)) {
      protectedRequests.push({
        requestAtMs: Date.now(),
        method: request.method(),
        routeTag,
        authorizationPresent: authorization.startsWith('Bearer '),
      });
    }
  });
  page.on('response', async (response) => {
    let url;
    try { url = new URL(response.url()); } catch (_) { return; }
    const request = response.request();
    const requestAtMs = requestStartedAt.get(request) ?? 0;
    const meta = requestMetadata.get(request) || {};
    if (profile === 'owner' && request.method() === 'GET' &&
        url.pathname === '/api/v1/devices') {
      try {
        const body = await response.json();
        const devices = Array.isArray(body?.devices) ? body.devices : [];
        ownerDeviceSnapshots.push({
          requestAtMs,
          responseAtMs: Date.now(),
          status: response.status(),
          devices: devices.filter((device) =>
            typeof device?.device_id === 'string' &&
            typeof device?.name === 'string' &&
            typeof device?.status === 'string').map((device) => ({
            deviceId: device.device_id,
            name: device.name,
            status: device.status,
          })),
        });
      } catch (_) {
        ownerDeviceSnapshots.push({ requestAtMs, responseAtMs: Date.now(), status: response.status(), devices: [] });
      }
    }
    if (profile === 'target' && meta.routeTag) {
      let errorCode = null;
      if (response.status() >= 400) {
        try {
          const body = await response.json();
          errorCode = typeof body?.error?.code === 'string' ? body.error.code : null;
        } catch (_) {}
      }
      protectedResponses.push({
        requestAtMs,
        responseAtMs: Date.now(),
        method: meta.method,
        routeTag: meta.routeTag,
        status: response.status(),
        errorCode,
        authorizationPresent: meta.authorizationPresent,
      });
    }
  });
}

async function waitForDeviceSnapshot(predicate, timeoutMs = 20000) {
  await waitFor(() => ownerDeviceSnapshots.some(predicate), timeoutMs,
    'expected trusted-device snapshot was not received');
  return ownerDeviceSnapshots.slice().reverse().find(predicate);
}

function latestDevice(devices, name) {
  return devices.find((device) => device.name === name);
}

async function pendingSyncButton(page) {
  const labels = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only|Sign in needed|Device revoked)$/;
  return page.getByRole('button', { name: labels }).first();
}

async function triggerSync(page) {
  const sync = await pendingSyncButton(page);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (await sync.isVisible().catch(() => false) &&
        await sync.isEnabled().catch(() => false)) {
      const label = await sync.getAttribute('aria-label') ||
        (await sync.innerText()).trim();
      if (label !== 'Syncing') {
        await sync.click();
        return true;
      }
    }
    await page.waitForTimeout(100);
  }
  return false;
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
      'compiled Flutter Web release is incomplete');
  }
  const bundleHash = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');
  assertThat(bundleHash === EXPECTED_BUNDLE_SHA256,
    'compiled Web release does not match the current v2.181 bundle');
  console.log(`bundle sha256: ${bundleHash}`);

  setStage('build isolated local server');
  buildServer();
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-device-revoke-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const port = await unusedLoopbackPort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: 'off',
  };

  try {
    setStage('start disposable loopback server');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = issueCliToken(['bootstrap'], serverEnv, 'disposable bootstrap token');

    setStage('launch two isolated Chromium device profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    const contextOptions = {
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    };
    ownerContext = await browser.newContext(contextOptions);
    targetContext = await browser.newContext(contextOptions);
    ownerPage = await ownerContext.newPage();
    targetPage = await targetContext.newPage();
    installApiEvidence(ownerPage, 'owner');
    installApiEvidence(targetPage, 'target');
    await Promise.all([ownerPage, targetPage].map((page) =>
      page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 })));
    await Promise.all([ownerPage, targetPage].map(enableSemantics));
    await Promise.all([
      button(ownerPage, 'Connect securely'),
      button(targetPage, 'Connect securely'),
    ]);

    setStage('register the disposable Owner device');
    await connect(ownerPage, baseUrl);
    await field(ownerPage, 'Owner email');
    await fill(ownerPage, 'Owner email', USERNAME);
    await fill(ownerPage, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(ownerPage, 'Confirm master password', MASTER_PASSWORD);
    await fill(ownerPage, 'One-time bootstrap token', bootstrapToken);
    await fill(ownerPage, 'Device name', DEVICE_A_NAME);
    await fill(ownerPage, 'First Vault', 'Device revocation acceptance');
    await click(ownerPage, 'Create owner account');
    bootstrapToken = undefined;
    await waitWorkspace(ownerPage);
    const initialOwnerSnapshot = await waitForDeviceSnapshot((snapshot) =>
      snapshot.status === 200 && latestDevice(snapshot.devices, DEVICE_A_NAME)?.status === 'active');
    ownerDeviceId = latestDevice(initialOwnerSnapshot.devices, DEVICE_A_NAME).deviceId;

    setStage('request and approve the second device enrollment');
    await connect(targetPage, baseUrl);
    await field(targetPage, 'Email or username');
    await click(targetPage, 'Add this device');
    await waitForText(targetPage, 'Request this device');
    await fill(targetPage, 'Account email', USERNAME);
    await fill(targetPage, 'Device name', DEVICE_B_NAME);
    await click(targetPage, 'Generate request');
    await field(targetPage, 'Copy this enrollment JSON');
    await click(targetPage, 'Copy');
    const enrollmentJson = await targetPage.evaluate(async () => navigator.clipboard.readText());
    let enrollmentFormat = null;
    try { enrollmentFormat = JSON.parse(enrollmentJson).format || null; } catch (_) {}
    assertThat(enrollmentFormat === 'atermius-device-enrollment-v1',
      'second device enrollment request was invalid');
    await click(targetPage, 'Close');

    await click(ownerPage, 'Devices');
    await click(ownerPage, 'Approve enrollment');
    await paste(ownerPage, 'Enrollment JSON', enrollmentJson);
    await click(ownerPage, 'Review keys');
    await (await button(ownerPage, 'Approve & seal keys')).click();
    await button(ownerPage, 'Copy');
    await click(ownerPage, 'Copy');
    const approvalJson = await ownerPage.evaluate(async () => navigator.clipboard.readText());
    assertThat(approvalJson.includes('atermius-device-approval-v1'),
      'Owner did not create a device approval');
    await click(ownerPage, 'Done');
    await click(ownerPage, 'Hosts');

    await click(targetPage, 'Import approval');
    await paste(targetPage, 'Paste approval JSON', approvalJson);
    await click(targetPage, 'Import device keys');
    await fill(targetPage, 'Email or username', USERNAME);
    await fill(targetPage, 'Master password', MASTER_PASSWORD);
    await click(targetPage, 'Sign in and unlock');
    await waitWorkspace(targetPage);
    await click(ownerPage, 'Devices');
    const activeTargetSnapshot = await waitForDeviceSnapshot((snapshot) =>
      snapshot.status === 200 && latestDevice(snapshot.devices, DEVICE_B_NAME)?.status === 'active');
    targetDeviceId = latestDevice(activeTargetSnapshot.devices, DEVICE_B_NAME).deviceId;
    assertThat(targetDeviceId !== ownerDeviceId, 'enrollment reused the Owner device identity');
    console.log('assert: second_device_enrolled=true');

    setStage('queue one encrypted Host operation while the target is offline');
    await targetContext.setOffline(true);
    await waitFor(() => targetPage.evaluate(() => navigator.onLine === false),
      5000, 'Chromium did not switch the target profile offline');
    await addOfflineHost(targetPage);
    const pendingBefore = await waitForPendingAtLeast(targetPage, 1);
    const clientSnapshotBefore = await readClientDatabaseFromIndexedDb(targetPage);
    assertThat(clientSnapshotBefore.available && Array.isArray(clientSnapshotBefore.sqliteFiles),
      'target IndexedDB outbox snapshot was unavailable before revocation');
    const databasePath = path.join(tempRoot, 'target-outbox-before.sqlite');
    const outboxBefore = inspectPendingOutbox(clientSnapshotBefore.sqliteFiles, databasePath);
    assertThat(outboxBefore.integrity === 'ok' && outboxBefore.operations.length === 1 &&
      outboxBefore.operations[0].operation === 'create',
    'target profile did not hold exactly one valid queued encrypted operation');

    setStage('revoke the target through the Owner Devices UI');
    await click(ownerPage, 'Devices');
    await waitForDeviceSnapshot((snapshot) =>
      snapshot.status === 200 && latestDevice(snapshot.devices, DEVICE_B_NAME)?.status === 'active');
    const revokeButton = ownerPage.getByRole('button', { name: 'Revoke device', exact: true });
    assertThat(await revokeButton.count() === 1 && await revokeButton.isVisible(),
      'Owner UI did not expose one revocation action for the enrolled target');
    await revokeButton.click();
    await waitForText(ownerPage, 'Revoke device?');
    const confirmationButtons = ownerPage.getByRole('button', {
      name: 'Revoke device', exact: true,
    });
    assertThat(await confirmationButtons.count() >= 1,
      'device revocation confirmation action was not exposed');
    const revokePath = `/api/v1/devices/${targetDeviceId}/revoke`;
    const revokeResponsePromise = ownerPage.waitForResponse((response) =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === revokePath,
    { timeout: 20000 });
    await confirmationButtons.last().click();
    const revokeResponse = await revokeResponsePromise;
    assertThat(revokeResponse.status() === 200,
      `Owner UI device-revocation request returned HTTP ${revokeResponse.status()}`);
    const revokeResponseAtMs = Date.now();
    console.log('assert: owner_ui_revoke_http_200=true');

    setStage('read a fresh post-response trusted-device snapshot');
    // Route change forces the Devices screen to load again, so this snapshot
    // is from a new GET initiated after the successful revoke response.
    await click(ownerPage, 'Hosts');
    await click(ownerPage, 'Devices');
    const revokedSnapshot = await waitForDeviceSnapshot((snapshot) => {
      const target = latestDevice(snapshot.devices, DEVICE_B_NAME);
      return snapshot.status === 200 && snapshot.requestAtMs >= revokeResponseAtMs &&
        target?.deviceId === targetDeviceId && target.status === 'revoked';
    });
    assertThat(revokedSnapshot.requestAtMs >= revokeResponseAtMs,
      'trusted-device snapshot was not fetched after the revoke response');
    await waitForText(ownerPage, 'Revoked');
    console.log('assert: fresh_post_revoke_device_snapshot_revoked=true');

    setStage('deny the target profile next authenticated sync');
    const reconnectAtMs = Date.now();
    await targetContext.setOffline(false);
    await waitFor(() => targetPage.evaluate(() => navigator.onLine === true),
      5000, 'Chromium did not restore the target profile network');
    // A browser reconnect normally schedules synchronization automatically.
    // If it has not started, trigger it through the visible sync control.
    const denialDeadline = Date.now() + 12000;
    while (Date.now() < denialDeadline && !protectedResponses.some((entry) =>
      entry.requestAtMs >= reconnectAtMs && entry.status === 401)) {
      await targetPage.waitForTimeout(100);
    }
    if (!protectedResponses.some((entry) =>
      entry.requestAtMs >= reconnectAtMs && entry.status === 401)) {
      assertThat(await triggerSync(targetPage),
        'target profile did not expose a sync action after reconnection');
    }
    try {
      await waitFor(() => protectedResponses.some((entry) =>
      entry.requestAtMs >= reconnectAtMs && entry.status === 401 &&
        entry.errorCode === 'AUTH_REQUIRED'), 25000,
      'revoked target profile did not receive an authenticated sync denial');
    } catch (error) {
      const recent = protectedResponses.filter((entry) => entry.requestAtMs >= reconnectAtMs)
        .slice(-12).map((entry) => ({
          method: entry.method,
          route: entry.routeTag,
          status: entry.status,
          authenticated: entry.authorizationPresent,
          errorCode: entry.errorCode,
        }));
      const visibleSyncLabels = await targetPage.evaluate(() =>
        [...document.querySelectorAll('flt-semantics[role="button"]')]
          .map((node) => node.getAttribute('aria-label') || node.innerText || '')
          .filter((label) => /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Sign in needed|Device revoked)$/i.test(label))
          .slice(0, 8)).catch(() => []);
      throw new Error(`${error.message}; observed=${JSON.stringify(recent)}; syncLabels=${JSON.stringify(visibleSyncLabels)}`);
    }
    const deniedSync = protectedResponses.slice().reverse().find((entry) =>
      entry.requestAtMs >= reconnectAtMs && entry.status === 401 &&
      entry.errorCode === 'AUTH_REQUIRED');
    assertThat(deniedSync.authorizationPresent &&
      deniedSync.routeTag === 'account-devices',
    `revocation denial was not an authenticated sync request: ${JSON.stringify({
      method: deniedSync.method,
      route: deniedSync.routeTag,
      status: deniedSync.status,
      authenticated: deniedSync.authorizationPresent,
      errorCode: deniedSync.errorCode,
    })}`);
    await waitForText(targetPage, 'Sign in needed', 10000);
    assertThat(!protectedRequests.some((entry) =>
      entry.requestAtMs >= deniedSync.responseAtMs),
    'target attempted Vault data-plane sync after the denied account control-plane refresh');

    setStage('verify local encrypted outbox survives the denied sync');
    const clientSnapshotAfter = await readClientDatabaseFromIndexedDb(targetPage);
    assertThat(clientSnapshotAfter.available && Array.isArray(clientSnapshotAfter.sqliteFiles),
      'target IndexedDB outbox snapshot was unavailable after denied sync');
    const outboxAfter = inspectPendingOutbox(clientSnapshotAfter.sqliteFiles,
      path.join(tempRoot, 'target-outbox-after.sqlite'));
    const original = outboxBefore.operations[0];
    const retained = outboxAfter.operations.find((operation) =>
      operation.opId === original.opId);
    assertThat(outboxAfter.integrity === 'ok' && outboxAfter.operations.length === 1 &&
      outboxAfter.operations[0].recordId === original.recordId && retained &&
      retained.revisionId === original.revisionId && retained.hash === original.hash &&
      retained.operation === original.operation && ['queued', 'sent'].includes(retained.status),
    'revoked target did not retain the original immutable encrypted pending operation');
    const pendingAfter = await pendingCount(targetPage);
    assertThat(pendingAfter !== null && pendingAfter >= pendingBefore,
      'visible pending count decreased after denied sync');

    console.log('assert: authenticated_sync_control_plane_denied=true');
    console.log('assert: vault_sync_stopped_after_denial=true');
    console.log('assert: pending_encrypted_operation_retained=true');
    console.log('assert: pending_badge_not_decreased=true');
    console.log('WEB-DEVICE-REVOKE-01 passed');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'isolated browser/server cleanup failed');
}

main().catch(async (error) => {
  const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' :
    error?.name === 'TypeError' ? 'TypeError' : 'Error';
  console.error(`WEB-DEVICE-REVOKE-01 failed at ${stage}: ${errorClass}`);
  await cleanup();
  process.exitCode = 1;
});
