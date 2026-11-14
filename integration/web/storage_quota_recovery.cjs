/*
 * WEB-STORAGE-QUOTA-01: exercise real Chromium origin quota enforcement
 * against the Web client's persistent Drift/IndexedDB SQLite database.
 *
 * The runner first verifies that the CDP quota override is active and that a
 * native IndexedDB transaction receives QuotaExceededError. It then applies
 * the same origin limit to a real encrypted Host save, checks the durable
 * IndexedDB SQLite image and server commit tables, removes the limit, restarts
 * the same private browser profile, and retries the save exactly once.
 * Diagnostics contain fixed stages, status codes, table counts, hashes and
 * error classes only; account values, Host fields, tokens and envelopes are
 * never printed.
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
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `storage-quota-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `QuotaRecovery${crypto.randomBytes(24).toString('hex')}9`;
const DEVICE_NAME = `Quota recovery ${RUN_ID.slice(0, 8)}`;
const VAULT_NAME = `Quota recovery Vault ${RUN_ID.slice(0, 8)}`;
const HOST_NAME = `quota-recovery-host-${RUN_ID}`;
const HOST_ADDRESS = '192.0.2.77';
const HOST_USERNAME = 'quota-recovery-user';
const HOST_MARKERS = [HOST_NAME, HOST_ADDRESS, HOST_USERNAME];
const QUOTA_LIMIT_BYTES = 8 * 1024 * 1024;

let activeStage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let profileDir;
let serverLogFd;
let serverProcess;
let context;
let page;
let bootstrapToken;
let cdp;
let quotaOrigin;
let driftImplementation;
let pageErrorCount = 0;
let cleanupFailed = false;
let quotaDiagnostic = null;
let nativeQuotaProbeDiagnostic = null;
let cdpDiagnostic = null;
const pushRequests = [];
const staticAssetResponses = [];
const staticAssetFailures = [];
let browserConsoleErrorCount = 0;
let initialDocumentStatus = null;
const authLoginResponseStatuses = [];
const STATIC_ASSET_NAMES = new Set([
  'index.html', 'flutter.js', 'flutter_bootstrap.js', 'main.dart.js',
  'sodium.js', 'canvaskit.js', 'canvaskit.wasm', 'skwasm.js', 'skwasm.wasm',
  'drift_worker.js', 'sqlite3.wasm', 'favicon.png',
]);

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  activeStage = value;
  console.log(`stage: ${value}`);
}

function safeErrorClass(error) {
  return ['TimeoutError', 'TypeError', 'ReferenceError', 'SecurityError', 'Error']
    .includes(error?.name) ? error.name : 'OtherError';
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function runQuietly(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 8 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error(options.failureMessage || 'acceptance prerequisite failed');
  }
  return result.stdout || '';
}

async function unusedPort() {
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

async function waitForProcessExit(child, timeoutMs) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      child.removeListener('exit', finish);
      resolve(true);
    };
    const timer = setTimeout(() => {
      child.removeListener('exit', finish);
      resolve(child.exitCode !== null || child.signalCode !== null);
    }, timeoutMs);
    child.once('exit', finish);
  });
}

async function stopServer(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  if (await waitForProcessExit(child, 5000)) return;
  child.kill('SIGKILL');
  if (!await waitForProcessExit(child, 5000)) {
    throw new Error('isolated server did not stop');
  }
}

async function waitReady(baseUrl, child) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error('isolated server exited before readiness');
    }
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1500),
      });
      if (response.status === 200) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

function startServer(port, baseUrl) {
  const databaseUrl = `sqlite://${databasePath}?mode=rwc`;
  const env = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: databaseUrl,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };
  return spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env,
    detached: true,
    stdio: ['ignore', serverLogFd, serverLogFd],
  });
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (error) {
    if (error.code !== 'ESRCH') throw new Error('could not stop isolated server');
  }
  if (await waitForProcessExit(child, 3000)) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch (error) {
    if (error.code !== 'ESRCH') throw new Error('could not force-stop isolated server');
  }
  if (!await waitForProcessExit(child, 3000)) {
    throw new Error('isolated server process did not exit');
  }
}

async function visible(locator) {
  const count = await locator.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) return locator.nth(index);
  }
  return null;
}

async function button(label, timeoutMs = 15000) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await visible(matches);
    if (found) return found;
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button unavailable: ${label}`);
}

async function field(label, timeoutMs = 15000) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  );
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await visible(locator);
    if (found) return found;
    await page.waitForTimeout(100);
  }
  throw new Error(`visible form field unavailable: ${label}`);
}

async function fill(label, value) {
  const locator = await field(label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(120);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(120);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`form field did not retain input: ${label}`);
}

async function click(label) {
  await (await button(label)).click();
}

async function hasSemanticText(expected) {
  return page.evaluate((text) => {
    if ((document.body.innerText || '').includes(text)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
        .includes(text));
  }, expected).catch(() => false);
}

async function waitForText(expected, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await hasSemanticText(expected)) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`expected UI state unavailable: ${expected}`);
}

async function activateAccessibilitySemantics(targetPage) {
  const placeholder = targetPage.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 15000 });
  await placeholder.evaluate((element) => element.click());
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const hasSemantics = await targetPage.evaluate(() =>
      document.querySelectorAll('flt-semantics').length > 0,
    ).catch(() => false);
    if (hasSemantics) return;
    await targetPage.waitForTimeout(100);
  }
  throw new Error('Flutter semantics tree did not appear after accessibility activation');
}

async function waitForWorkspace(timeoutMs = 30000) {
  await button('Add host', timeoutMs);
}

async function startPageInstrumentation(targetContext, targetPage) {
  targetPage.on('pageerror', () => { pageErrorCount += 1; });
  targetPage.on('console', (message) => {
    if (message.type() === 'error') browserConsoleErrorCount += 1;
  });
  targetPage.on('console', (message) => {
    const match = message.text().match(/ATERMIUS_DRIFT_WEB_IMPLEMENTATION=(\w+)/);
    if (match) driftImplementation = match[1];
  });
  targetPage.on('response', (response) => {
    let name;
    let pathname;
    try {
      pathname = new URL(response.url()).pathname;
      name = path.basename(pathname);
    } catch (_) { return; }
    if (pathname === '/api/v1/auth/login') authLoginResponseStatuses.push(response.status());
    if (!STATIC_ASSET_NAMES.has(name)) return;
    const headers = response.headers();
    staticAssetResponses.push({
      asset: name,
      status: response.status(),
      contentType: headers['content-type'] || null,
    });
  });
  targetPage.on('requestfailed', (request) => {
    let name;
    try { name = path.basename(new URL(request.url()).pathname); } catch (_) { return; }
    if (!STATIC_ASSET_NAMES.has(name)) return;
    const failure = String(request.failure()?.errorText || '').toLowerCase();
    staticAssetFailures.push({
      asset: name,
      category: failure.includes('aborted') ? 'aborted' :
        failure.includes('timed out') ? 'timeout' : 'network-failure',
    });
  });
  await targetContext.route('**/api/v1/vaults/*/sync/push', async (route) => {
    const safeRequest = {
      opIds: [],
      operations: [],
      markerAbsent: true,
      status: null,
      results: [],
    };
    try {
      const requestBody = route.request().postDataJSON();
      const envelopes = Array.isArray(requestBody?.operations)
        ? requestBody.operations : [];
      safeRequest.opIds = envelopes.map((item) => item?.header?.op_id)
        .filter((value) => typeof value === 'string');
      safeRequest.operations = envelopes.map((item) => ({
        operation: item?.header?.operation,
        recordId: item?.header?.record_id,
        revisionId: item?.header?.revision_id,
        opId: item?.header?.op_id,
        vaultId: item?.header?.vault_id,
        envelopeSha256: crypto.createHash('sha256')
          .update(stableJson(item)).digest('hex'),
      }));
      const serialized = JSON.stringify(requestBody);
      safeRequest.markerAbsent = HOST_MARKERS.every((marker) =>
        !serialized.includes(marker));
    } catch (_) {}
    const upstream = await route.fetch();
    safeRequest.status = upstream.status();
    let body;
    try {
      body = await upstream.json();
      safeRequest.results = Array.isArray(body?.results) ? body.results.map((result) => ({
        opId: result?.op_id,
        revisionId: result?.revision_id,
        commitSeq: String(result?.commit_seq ?? ''),
        alreadyCommitted: result?.already_committed === true,
      })) : [];
      await route.fulfill({ response: upstream, body: JSON.stringify(body) });
    } catch (_) {
      const responseBody = await upstream.body().catch(() => Buffer.alloc(0));
      await route.fulfill({ response: upstream, body: responseBody });
    }
    pushRequests.push(safeRequest);
  });
}

async function seedSharedIndexedDb(targetContext, baseUrl) {
  const seedPage = await targetContext.newPage();
  try {
    await seedPage.goto(`${baseUrl}/health/ready`, {
      waitUntil: 'domcontentloaded', timeout: 10000,
    });
    const result = await seedPage.evaluate(async () => {
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open('atermius_vault', 1);
        request.onupgradeneeded = () => {
          const files = request.result.createObjectStore('files', { autoIncrement: true });
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
    });
    assertThat(result, 'failed to seed safe shared IndexedDB schema');
  } finally {
    await seedPage.close().catch(() => {});
  }
}

async function launchPersistentProfile() {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  context = await chromium.launchPersistentContext(profileDir, options);
  page = context.pages()[0] || await context.newPage();
  await startPageInstrumentation(context, page);
  return page;
}

async function waitForRestartedWorkspace(baseUrl) {
  setStage('restart same profile load Web application');
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  setStage('restart same profile activate Flutter controls');
  await activateAccessibilitySemantics(page);
  setStage('restart same profile wait for Flutter application render');
  const renderDeadline = Date.now() + 30000;
  while (Date.now() < renderDeadline) {
    const rendered = await page.evaluate(() => {
      const loading = document.querySelector('#loading');
      const style = loading ? getComputedStyle(loading) : null;
      const loadingVisible = Boolean(loading && style &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && loading.getBoundingClientRect().width > 0 &&
        loading.getBoundingClientRect().height > 0);
      return !loadingVisible && document.querySelectorAll('canvas').length > 0;
    }).catch(() => false);
    if (rendered) break;
    await page.waitForTimeout(100);
  }
  const renderState = await page.evaluate(() => {
    const loading = document.querySelector('#loading');
    const style = loading ? getComputedStyle(loading) : null;
    const rect = loading?.getBoundingClientRect();
    const signIn = [...document.querySelectorAll('flt-semantics[role="button"],button')]
      .find((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
        .replace(/\s+/g, ' ').trim() === 'Sign in and unlock');
    return {
      canvasCount: document.querySelectorAll('canvas').length,
      loadingVisible: Boolean(loading && style && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0 && rect?.width > 0 &&
        rect?.height > 0),
      signInVisible: Boolean(signIn),
      signInDisabled: signIn?.getAttribute('aria-disabled') === 'true' ||
        signIn?.getAttribute('disabled') !== null,
      signInHasDisabledAttribute: signIn?.hasAttribute('disabled') ?? null,
      signInAriaDisabled: signIn?.getAttribute('aria-disabled') ?? null,
      loginValuePresent: [...document.querySelectorAll('input')]
        .some((element) => (element.getAttribute('aria-label') || '')
          .includes('Email or username') && element.value.length > 0),
      passwordValuePresent: [...document.querySelectorAll('input')]
        .some((element) => (element.getAttribute('aria-label') || '')
          .includes('Master password') && element.value.length > 0),
      flutterCanvasKitState: window.__atermiusCanvasKitProbe?.state || 'unobserved',
    };
  }).catch(() => ({ documentUnavailable: true }));
  if (renderState.canvasCount === 0 || renderState.loadingVisible) {
    console.error('WEB-STORAGE-QUOTA-01 restart Flutter render state', JSON.stringify({
      ...renderState,
      staticAssetResponses,
      staticAssetFailures,
      consoleErrorCount: browserConsoleErrorCount,
    }));
  }
  setStage('restart same profile select server account');
  await selectServerModeIfChooser(page);
  setStage('restart same profile restore account and Vault');
  const deadline = Date.now() + 30000;
  let connected = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await visible(page.getByRole('button', { name: 'Add host', exact: true }))) return;
    if (!connected && await visible(page.locator('input[aria-label*="Server URL"]'))) {
      await fill('Server URL', baseUrl);
      await click('Connect securely');
      connected = true;
    } else if (!loginSubmitted && await visible(page.locator('input[aria-label*="Email or username"]'))) {
      setStage('restart same profile fill account email');
      await fill('Email or username', USERNAME);
      setStage('restart same profile fill master password');
      await fill('Master password', MASTER_PASSWORD);
      const signIn = page.getByRole('button', { name: 'Sign in and unlock', exact: true });
      const enabled = await signIn.isEnabled().catch(() => false);
      console.log('WEB-STORAGE-QUOTA-01 restart sign-in readiness', JSON.stringify({
        enabled,
        ...renderState,
      }));
      setStage('restart same profile submit login');
      await click('Sign in and unlock');
      loginSubmitted = true;
      setStage('restart same profile wait for authenticated workspace');
    }
    await page.waitForTimeout(100);
  }
  console.error('WEB-STORAGE-QUOTA-01 restart recovery state', JSON.stringify({
    connected,
    loginSubmitted,
    signInButtonAccessible: Boolean(await visible(page.getByRole(
      'button', { name: 'Sign in and unlock', exact: true },
    ))),
    addHostButtonAccessible: Boolean(await visible(page.getByRole(
      'button', { name: 'Add host', exact: true },
    ))),
    loginResponseStatuses: authLoginResponseStatuses.slice(-3),
  }));
  throw new Error('same-profile relaunch did not restore the workspace');
}

async function registerOwner(baseUrl, token) {
  setStage('owner registration open server page');
  const response = await page.goto(baseUrl, {
    waitUntil: 'domcontentloaded', timeout: 30000,
  });
  initialDocumentStatus = response?.status() ?? null;
  setStage('owner registration activate Flutter controls');
  await activateAccessibilitySemantics(page);
  setStage('owner registration select server sync workspace');
  await selectServerModeIfChooser(page);
  setStage('owner registration locate server URL field');
  await field('Server URL');
  setStage('owner registration fill server URL');
  await fill('Server URL', baseUrl);
  setStage('owner registration click secure connect');
  await click('Connect securely');
  setStage('owner registration wait for account form');
  await field('Owner email');
  setStage('owner registration fill account fields');
  await fill('Owner email', USERNAME);
  await fill('Master password · 12+ characters', MASTER_PASSWORD);
  await fill('Confirm master password', MASTER_PASSWORD);
  await fill('One-time bootstrap token', token);
  await fill('Device name', DEVICE_NAME);
  await fill('First Vault', VAULT_NAME);
  setStage('owner registration submit account form');
  await click('Create owner account');
  setStage('owner registration wait for unlocked workspace');
  await waitForWorkspace();
  setStage('owner registration verify shared IndexedDB selection');
  const implementationDeadline = Date.now() + 10000;
  while (!driftImplementation && Date.now() < implementationDeadline) {
    await page.waitForTimeout(100);
  }
  assertThat(driftImplementation === 'sharedIndexedDb',
    'Web did not select the seeded sharedIndexedDb backend');
}

async function waitForCondition(check, reason, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await page.waitForTimeout(100);
  }
  throw new Error(reason);
}

async function sendStorageCdp(cdpSession, method, params = {}) {
  try {
    return await cdpSession.send(method, params);
  } catch (error) {
    const message = String(error?.message || '').toLowerCase();
    const failureCategory = /method not found|unknown method|wasn't found|not supported|unsupported/.test(message)
      ? 'unsupported-command'
      : /invalid param|invalid argument|parameter/.test(message)
        ? 'command-parameters-rejected'
        : /target closed|session closed|detached/.test(message)
          ? 'cdp-session-closed'
          : 'cdp-command-failed';
    cdpDiagnostic = { method, failureCategory };
    throw new Error(`Chromium CDP ${method} failed`);
  }
}

async function fillOriginToQuota(targetPage) {
  return targetPage.evaluate(async () => {
    let db;
    try {
      db = await new Promise((resolve, reject) => {
        const request = indexedDB.open('atermius_quota_probe', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('payload');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('probe open failed'));
        request.onblocked = () => reject(new Error('probe open blocked'));
      });
      let successfulChunkCount = 0;
      let filledBytes = 0;
      let quotaErrorName = null;
      let key = 0;
      const writeChunk = async (size) => {
        const bytes = new Uint8Array(size);
        for (let offset = 0; offset < size; offset += 65536) {
          crypto.getRandomValues(bytes.subarray(offset, Math.min(offset + 65536, size)));
        }
        return new Promise((resolve) => {
          const transaction = db.transaction('payload', 'readwrite');
          const request = transaction.objectStore('payload').put(bytes, key++);
          let requestErrorName = null;
          request.onerror = () => { requestErrorName = request.error?.name || null; };
          transaction.oncomplete = () => resolve(null);
          transaction.onabort = () => resolve(
            transaction.error?.name || requestErrorName || 'AbortError',
          );
          transaction.onerror = () => {};
        });
      };
      for (const chunkSize of [65536, 4096, 256]) {
        for (let attempt = 0; attempt < 1024; attempt += 1) {
          const errorName = await writeChunk(chunkSize);
          if (errorName) {
            quotaErrorName ||= errorName;
            break;
          }
          successfulChunkCount += 1;
          filledBytes += chunkSize;
        }
        if (chunkSize === 256 && quotaErrorName) break;
      }
      const estimate = await navigator.storage.estimate();
      return {
        openErrorName: null,
        quotaErrorName,
        successfulChunkCount,
        filledBytes,
        quotaBytes: Number.isSafeInteger(estimate.quota) ? estimate.quota : null,
        usageBytes: Number.isSafeInteger(estimate.usage) ? estimate.usage : null,
      };
    } catch (error) {
      return {
        openErrorName: error?.name || 'Error',
        quotaErrorName: null,
        successfulChunkCount: 0,
        filledBytes: 0,
        quotaBytes: null,
        usageBytes: null,
      };
    } finally {
      db?.close();
    }
  });
}

async function deleteQuotaProbeDatabase(targetPage) {
  await targetPage.evaluate(async () => {
    await new Promise((resolve) => {
      const request = indexedDB.deleteDatabase('atermius_quota_probe');
      request.onsuccess = request.onerror = request.onblocked = resolve;
    });
  });
}

async function readClientSqliteFiles(targetPage) {
  return targetPage.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') {
      return { available: false, reason: 'database-list-unavailable' };
    }
    const databases = await indexedDB.databases();
    if (!databases.some((item) => item.name === 'atermius_vault')) {
      return { available: false, reason: 'vault-database-missing' };
    }
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
      request.onblocked = () => reject(new Error('IDB read blocked'));
    });
    try {
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        return { available: false, reason: 'drift-stores-missing' };
      }
      const filesTx = db.transaction('files', 'readonly');
      const fileRowsPromise = new Promise((resolve, reject) => {
        const request = filesTx.objectStore('files').getAll();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error || new Error('file read failed'));
      });
      const fileKeysPromise = new Promise((resolve, reject) => {
        const request = filesTx.objectStore('files').getAllKeys();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error || new Error('file keys read failed'));
      });
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('files transaction failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('files transaction aborted'));
      });
      const [fileRows, fileKeys] = await Promise.all([
        fileRowsPromise, fileKeysPromise, filesComplete,
      ]);
      const files = fileRows.map((row, index) => ({
        fileId: Number(fileKeys[index]),
        name: String(row?.name || ''),
        length: Number(row?.length),
      })).filter((row) => row.name === '/database' || row.name === '/database-journal');
      if (!files.some((row) => row.name === '/database')) {
        return { available: false, reason: 'sqlite-main-file-missing' };
      }
      if (files.some((row) => !Number.isSafeInteger(row.fileId) ||
          !Number.isSafeInteger(row.length) || row.length < 0 || row.length > 64 * 1024 * 1024)) {
        return { available: false, reason: 'sqlite-file-size-invalid' };
      }
      const blocksTx = db.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('blocks transaction failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('blocks transaction aborted'));
      });
      const filesWithBlocks = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0], [file.fileId, 9007199254740992]);
        const store = blocksTx.objectStore('blocks');
        const [keys, values] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = store.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('block key read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = store.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('block read failed'));
          }),
        ]);
        return {
          ...file,
          blocks: keys.map((key, index) => {
            const value = values[index];
            const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
              ArrayBuffer.isView(value)
                ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
            if (!bytes) throw new Error('unsupported block value');
            let binary = '';
            for (let offset = 0; offset < bytes.length; offset += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
            }
            return { offset: Number(key?.[1]), base64: btoa(binary) };
          }),
        };
      }));
      await blocksComplete;
      return { available: true, sqliteFiles: filesWithBlocks };
    } finally {
      db.close();
    }
  });
}

function inspectClientSnapshot(sqliteFiles, snapshotPath) {
  const databaseFile = sqliteFiles.find((item) => item.name === '/database');
  const journalFile = sqliteFiles.find((item) => item.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    throw new Error(journalFile ? 'client SQLite journal is not empty' : 'client SQLite image missing');
  }
  const bytes = reconstructSqliteFile({
    fileId: databaseFile.fileId,
    name: databaseFile.name,
    length: databaseFile.length,
    blocks: databaseFile.blocks.map((item) => ({
      offset: item.offset,
      bytes: Buffer.from(item.base64, 'base64'),
    })),
  });
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  const python = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    "tables={row[0] for row in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
    "result={'integrityCheck':db.execute('PRAGMA integrity_check').fetchone()[0]}",
    "result['tableCounts']={name:db.execute('SELECT count(*) FROM '+name).fetchone()[0] for name in ('encrypted_records','pending_operations') if name in tables}",
    'print(json.dumps(result,separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 2048,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) throw new Error('client SQLite read-only query failed');
    const summary = JSON.parse(result.stdout);
    const markerFound = HOST_MARKERS.some((marker) => bytes.includes(Buffer.from(marker)));
    return {
      ...summary,
      markerFound,
      databaseLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function clientSnapshot(targetPage, label) {
  const files = await readClientSqliteFiles(targetPage);
  assertThat(files.available === true,
    `client IndexedDB snapshot unavailable (${files.reason || 'unknown'})`);
  return inspectClientSnapshot(files.sqliteFiles,
    path.join(tempRoot, `${label}-client.sqlite`));
}

function serverSnapshot(operation = null) {
  const python = [
    'import hashlib',
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'db.execute("PRAGMA query_only=ON")',
    'username=sys.argv[2]',
    'expected=json.loads(sys.stdin.read())',
    "user=db.execute('SELECT user_id FROM users WHERE username=?',(username,)).fetchone()",
    'assert user, "fixture account missing"',
    "vaults=db.execute(\"SELECT v.vault_id,COALESCE(vc.last_committed_seq,0) FROM vaults v JOIN vault_members m ON m.vault_id=v.vault_id LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE m.user_id=? AND m.state='active' AND v.state='active' ORDER BY v.vault_id\",(user[0],)).fetchall()",
    'assert len(vaults)==1, "fixture Vault count mismatch"',
    'vault=vaults[0][0]',
    "counts={name:db.execute('SELECT count(*) FROM '+name+' WHERE vault_id=?',(vault,)).fetchone()[0] for name in ('record_heads','record_versions','change_events','op_receipts')}",
    'target=None',
    'if expected:',
    '    record=expected["recordId"]',
    '    revision=expected["revisionId"]',
    '    op_id=expected["opId"]',
    '    op=db.execute("SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq",(vault,record)).fetchall()',
    '    events=db.execute("SELECT revision_id,event_type,envelope,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq",(vault,record)).fetchall()',
    '    head=db.execute("SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?",(vault,record)).fetchone()',
    '    receipts=db.execute("SELECT record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?",(vault,op_id)).fetchall()',
    '    def digest(text):',
    '        if text is None: return None',
    '        value=json.loads(text)',
    '        return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()',
    '    envelope=json.loads(op[0][2]) if len(op)==1 else {}',
    '    header=envelope.get("header",{}) if isinstance(envelope,dict) else {}',
    '    allowed={"wire_version","server_space_id","vault_id","record_id","revision_id","base_revision_id","op_id","device_id","device_seq","key_epoch","membership_version","record_schema","operation","crypto_suite","kdf_salt","object_refs"}',
    '    opaque=(set(envelope)=={"header","nonce","ciphertext","signature"} and isinstance(header,dict) and set(header).issubset(allowed) and all(isinstance(envelope.get(key),str) and envelope[key] for key in ("nonce","ciphertext","signature")))',
    '    target={"versionCount":len(op),"versionMatches":len(op)==1 and op[0][0]==revision and op[0][1]=="create" and str(op[0][3])==expected["commitSeq"],"versionEnvelopeHash":digest(op[0][2]) if len(op)==1 else None,"eventCount":len(events),"eventMatches":len(events)==1 and events[0][0]==revision and events[0][1]=="create" and str(events[0][3])==expected["commitSeq"],"eventEnvelopeHash":digest(events[0][2]) if len(events)==1 else None,"headMatches":bool(head and head[0]==revision and not head[1] and str(head[2])==expected["commitSeq"]),"receiptCount":len(receipts),"receiptMatches":len(receipts)==1 and receipts[0][0]==record and receipts[0][1]==revision and str(receipts[0][2])==expected["commitSeq"],"opaqueEnvelope":opaque,"requestEnvelopeHashMatches":len(op)==1 and digest(op[0][2])==expected["envelopeSha256"]}',
    'print(json.dumps({"vaultId":vault,"commitSeq":str(vaults[0][1]),"counts":counts,"target":target},separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', python, databasePath, USERNAME], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 2048,
    input: operation ? JSON.stringify(operation) : 'null',
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) throw new Error('server read-only snapshot failed');
  const summary = JSON.parse(result.stdout);
  const rawFindings = [];
  for (const suffix of ['', '-wal', '-shm']) {
    const candidate = `${databasePath}${suffix}`;
    if (!fs.existsSync(candidate)) continue;
    const bytes = fs.readFileSync(candidate);
    if (HOST_MARKERS.some((marker) => bytes.includes(Buffer.from(marker)))) {
      rawFindings.push(suffix || 'database');
    }
  }
  return { ...summary, plaintextMarkerFiles: rawFindings };
}

async function saveHost() {
  await click('Add host');
  await waitForText('Add a host');
  await fill('Display name', HOST_NAME);
  await fill('Hostname or IP', HOST_ADDRESS);
  await fill('Port', '22');
  await fill('SSH username', HOST_USERNAME);
  await click('Save encrypted host');
}

async function visibleSaveFailure() {
  return page.evaluate((hostName) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const nodes = [...document.querySelectorAll('flt-semantics,[role="alert"],[aria-live]')]
      .filter(visible);
    const text = nodes.map((element) =>
      `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
      .join(' ').replace(/\s+/g, ' ').trim();
    const pageText = (document.body.innerText || '').replace(/\s+/g, ' ');
    const successNoticeVisible = pageText.includes('主机已在本地加密保存，等待同步。');
    const matchingHostCardVisible = [...document.querySelectorAll('flt-semantics[role="group"]')]
      .some((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
        .includes(hostName));
    const errorNoticeVisible = /error|failed|abort|storage|database|quota|transaction|异常|失败/i.test(text);
    const recoveryRequiredVisible = pageText.includes('本地存储状态需要恢复');
    return {
      errorNoticeVisible,
      recoveryRequiredVisible,
      successNoticeVisible,
      matchingHostCardVisible,
    };
  }, HOST_NAME).catch(() => ({
    errorNoticeVisible: false,
    recoveryRequiredVisible: false,
    successNoticeVisible: false,
    matchingHostCardVisible: false,
  }));
}

async function safeRegistrationUiState() {
  if (!page || page.isClosed()) return { pageAvailable: false };
  const state = await page.evaluate(() => {
    const canvasKitPromise = window.flutterCanvasKitLoaded;
    if (canvasKitPromise && !window.__atermiusCanvasKitProbe) {
      window.__atermiusCanvasKitProbe = { state: 'pending' };
      canvasKitPromise.then(() => {
        window.__atermiusCanvasKitProbe.state = 'resolved';
      }, () => {
        window.__atermiusCanvasKitProbe.state = 'rejected';
      });
    }
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const semanticText = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`);
    const text = [document.body?.innerText || '', ...semanticText]
      .join(' ').replace(/\s+/g, ' ').toLowerCase();
    const inputs = [...document.querySelectorAll('input')].filter(visible);
    const hasButton = (label) => [...document.querySelectorAll(
      'flt-semantics[role="button"],button',
    )].some((element) => visible(element) &&
      `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
        .replace(/\s+/g, ' ').trim().toLowerCase() === label.toLowerCase());
    return {
      pathIsRoot: location.pathname === '/',
      titleMentionsAtermius: document.title.toLowerCase().includes('atermius'),
      documentReady: document.readyState === 'complete' || document.readyState === 'interactive',
      chooseWorkspaceVisible: text.includes('choose a workspace'),
      serverModeVisible: text.includes('server account and sync'),
      serverUrlFieldVisible: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('server url')),
      ownerEmailFieldVisible: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('owner email')),
      loginFieldVisible: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('email or username')),
      passwordFieldVisible: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('master password')),
      createOwnerButtonVisible: hasButton('Create owner account'),
      connectSecurelyButtonVisible: hasButton('Connect securely'),
      signInButtonVisible: hasButton('Sign in and unlock'),
      signInButtonDisabled: (() => {
        const node = [...document.querySelectorAll('flt-semantics[role="button"],button')]
          .find((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
            .replace(/\s+/g, ' ').trim().toLowerCase() === 'sign in and unlock');
        return node ? node.getAttribute('aria-disabled') === 'true' ||
          node.hasAttribute('disabled') : null;
      })(),
      loginValuePresent: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('email or username') &&
        element.value.length > 0),
      passwordValuePresent: inputs.some((element) =>
        (element.getAttribute('aria-label') || '').toLowerCase().includes('master password') &&
        element.value.length > 0),
      consoleErrorCount: browserConsoleErrorCount,
      assetFailures: staticAssetFailures,
      authenticationErrorVisible: /invalid credentials|incorrect password|password is incorrect|用户名或密码|密码不正确/i
        .test(text),
      addHostButtonVisible: hasButton('Add host'),
      continueButtonVisible: hasButton('Continue'),
      visibleInputCount: inputs.length,
      semanticNodeCount: document.querySelectorAll('flt-semantics').length,
      canvasCount: document.querySelectorAll('canvas').length,
      staticHtmlLoadingNodePresent: (() => {
        const loading = document.querySelector('#loading');
        return Boolean(loading && visible(loading));
      })(),
      flutterLoaderPresent: Boolean(window._flutter?.loader),
      flutterCanvasKitLoadedPresent: 'flutterCanvasKitLoaded' in window,
      flutterCanvasKitState: window.__atermiusCanvasKitProbe?.state || 'unobserved',
      flutterCanvasKitObjectPresent: Boolean(window.flutterCanvasKit),
      flutterEngineEntrypointPresent: typeof window._flutter?.loader?.didCreateEngineInitializer === 'function',
      sodiumGlobalPresent: Boolean(window.sodium),
      flutterRootNodeCounts: Object.fromEntries([
        'flutter-view', 'flt-glass-pane', 'flt-scene-host', 'flt-semantics-host',
        'flt-semantics', 'canvas',
      ].map((tag) => [tag, document.querySelectorAll(tag).length])),
      scriptAssetNames: [...document.scripts]
        .map((script) => {
          try { return new URL(script.src).pathname.split('/').pop(); } catch (_) { return ''; }
        })
        .filter((name) => ['flutter_bootstrap.js', 'main.dart.js', 'sodium.js'].includes(name)),
      resourceEntries: performance.getEntriesByType('resource')
        .map((entry) => {
          try { return new URL(entry.name).pathname.split('/').pop(); } catch (_) { return ''; }
        })
        .filter((name) => [
          'flutter.js', 'flutter_bootstrap.js', 'main.dart.js', 'sodium.js',
          'canvaskit.js', 'canvaskit.wasm', 'skwasm.js', 'skwasm.wasm',
        ].includes(name)),
      bodyTextLength: (document.body?.innerText || '').length,
    };
  }).catch(() => ({ pageAvailable: false }));
  return {
    ...state,
    accessibleContinueButtonVisible: Boolean(await visible(
      page.getByRole('button', { name: 'Continue', exact: true }),
    )),
    accessibleServerUrlFieldVisible: Boolean(await visible(
      page.locator('input[aria-label*="Server URL"]'),
    )),
  };
}

async function pendingCount() {
  return page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    for (const element of document.querySelectorAll('flt-semantics[role="button"]')) {
      if (!visible(element)) continue;
      const label = `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
        .replace(/\s+/g, ' ').trim();
      const match = label.match(/pending\s+(\d+)/i);
      if (match) return Number(match[1]);
      if (/^(Idle|Read-only)$/.test(label)) return 0;
    }
    return null;
  }).catch(() => null);
}

async function waitPendingCount(expected, timeoutMs = 45000) {
  await waitForCondition(async () => await pendingCount() === expected,
    `sync pending count did not settle to ${expected}`, timeoutMs);
}

async function waitForReceiptPush(afterIndex, timeoutMs = 45000) {
  await waitForCondition(() => pushRequests.slice(afterIndex).some((request) =>
    request.status === 200 && request.results.some((result) =>
      result.alreadyCommitted === false && result.commitSeq)),
  'Host retry did not receive a successful new-operation receipt', timeoutMs);
  const accepted = [];
  for (const request of pushRequests.slice(afterIndex)) {
    for (const result of request.results) {
      if (result.alreadyCommitted !== false || !result.commitSeq) continue;
      const operation = request.operations.find((item) => item.opId === result.opId &&
        item.revisionId === result.revisionId);
      if (operation) accepted.push({ ...result, operation, request });
    }
  }
  return accepted;
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Web release is incomplete; build apps/client for Web first');
  setStage('build current isolated server binary');
  runQuietly('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    failureMessage: 'current server build failed',
  });
  assertThat(fs.existsSync(SERVER_BINARY), 'server binary is missing after build');

  let successSummary;
  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-storage-quota-'));
    fs.chmodSync(tempRoot, 0o700);
    dataDir = path.join(tempRoot, 'data');
    profileDir = path.join(tempRoot, 'profile');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.mkdirSync(profileDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    fs.chmodSync(profileDir, 0o700);
    databasePath = path.join(dataDir, 'atermius.db');
    serverLogFd = fs.openSync(path.join(tempRoot, 'server.log'), 'a', 0o600);
    const port = await unusedPort();
    const baseUrl = `http://127.0.0.1:${port}`;

    setStage('isolated server startup');
    serverProcess = startServer(port, baseUrl);
    await waitReady(baseUrl, serverProcess);
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      RUST_LOG: process.env.RUST_LOG || 'warn',
    };
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
      maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrap.error && bootstrap.status === 0,
      'isolated bootstrap command failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    bootstrap.stdout = '';
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
      'isolated bootstrap token unavailable');

    setStage('launch persistent Chromium and seed shared IndexedDB backend');
    await launchPersistentProfile();
    await seedSharedIndexedDb(context, baseUrl);
    setStage('set origin quota before opening the encrypted client database');
    await page.goto(`${baseUrl}/health/ready`, {
      waitUntil: 'domcontentloaded', timeout: 10000,
    });
    cdp = await context.newCDPSession(page);
    quotaOrigin = new URL(baseUrl).origin;
    const quotaBefore = await sendStorageCdp(cdp, 'Storage.getUsageAndQuota', {
      origin: quotaOrigin,
    });
    await sendStorageCdp(cdp, 'Storage.overrideQuotaForOrigin', {
      origin: quotaOrigin,
      quotaSize: QUOTA_LIMIT_BYTES,
    });
    const initialQuota = await sendStorageCdp(cdp, 'Storage.getUsageAndQuota', {
      origin: quotaOrigin,
    });
    const cdpQuotaOverrideEffective = initialQuota.overrideActive === true &&
      initialQuota.quota === QUOTA_LIMIT_BYTES &&
      initialQuota.usage < initialQuota.quota;
    quotaDiagnostic = {
      overrideActive: initialQuota.overrideActive === true,
      requestedQuotaBytes: QUOTA_LIMIT_BYTES,
      reportedQuotaBytes: Number.isSafeInteger(initialQuota.quota)
        ? initialQuota.quota : null,
      reportedUsageBytes: Number.isSafeInteger(initialQuota.usage)
        ? initialQuota.usage : null,
      previousQuotaBytes: Number.isSafeInteger(quotaBefore.quota)
        ? quotaBefore.quota : null,
    };
    assertThat(cdpQuotaOverrideEffective,
    'Chromium did not activate the per-origin quota before client database writes');
    setStage('register one Web device and wait for an idle baseline');
    await registerOwner(baseUrl, bootstrapToken);
    bootstrapToken = undefined;
    await waitForCondition(async () => await pendingCount() === 0,
      'initial Vault sync did not reach pending=0', 45000);
    await page.waitForTimeout(500);
    const baselineServer = serverSnapshot();
    const baselineClient = await clientSnapshot(page, 'baseline');
    assertThat(baselineClient.integrityCheck === 'ok' &&
      baselineClient.tableCounts && !baselineClient.markerFound,
    'client baseline SQLite snapshot failed integrity/privacy checks');
    assertThat(baselineServer.plaintextMarkerFiles.length === 0,
      'server baseline contained a plaintext Host marker');
    const pushBaseline = pushRequests.length;

    setStage('verify quota remains active after encrypted client setup');
    const constrainedQuota = await sendStorageCdp(cdp, 'Storage.getUsageAndQuota', {
      origin: quotaOrigin,
    });
    const quotaOverrideEffective = constrainedQuota.overrideActive === true &&
      constrainedQuota.quota === QUOTA_LIMIT_BYTES &&
      constrainedQuota.usage < constrainedQuota.quota;
    if (!quotaOverrideEffective) {
      console.error('CDP quota override safe diagnostic', JSON.stringify({
        overrideActive: constrainedQuota.overrideActive === true,
        reportedQuotaBytes: Number.isSafeInteger(constrainedQuota.quota)
          ? constrainedQuota.quota : null,
        requestedQuotaBytes: QUOTA_LIMIT_BYTES,
        reportedUsageBytes: Number.isSafeInteger(constrainedQuota.usage)
          ? constrainedQuota.usage : null,
      }));
      throw new Error('Chromium CDP did not apply a measurable origin quota override');
    }
    setStage('fill origin and observe native IndexedDB QuotaExceededError');
    const quotaProbe = await fillOriginToQuota(page);
    nativeQuotaProbeDiagnostic = {
      openErrorName: quotaProbe.openErrorName || null,
      transactionErrorName: quotaProbe.quotaErrorName || null,
      successfulChunkCount: quotaProbe.successfulChunkCount,
      filledBytes: quotaProbe.filledBytes,
      quotaBytes: quotaProbe.quotaBytes,
      usageBytes: quotaProbe.usageBytes,
    };
    assertThat(quotaProbe.quotaErrorName === 'QuotaExceededError' &&
      quotaProbe.successfulChunkCount > 0 &&
      quotaProbe.filledBytes > 0,
      'native IndexedDB probe did not fail with QuotaExceededError under the CDP limit');

    setStage('attempt real encrypted Host save under exhausted origin quota');
    await saveHost();
    await waitForCondition(async () => {
      const evidence = await visibleSaveFailure();
      return evidence.errorNoticeVisible || evidence.recoveryRequiredVisible ||
        evidence.successNoticeVisible || evidence.matchingHostCardVisible;
    }, 'Host save produced no observable success or failure state', 20000);
    await page.waitForTimeout(750);
    const failedSaveUi = await visibleSaveFailure();
    const failedPushes = pushRequests.length - pushBaseline;
    assertThat(failedSaveUi.errorNoticeVisible || failedSaveUi.recoveryRequiredVisible,
      'Web UI did not surface a recoverable persistence failure');
    assertThat(!failedSaveUi.successNoticeVisible && !failedSaveUi.matchingHostCardVisible,
      'Web UI reported a successful Host save after the quota failure');
    assertThat(failedPushes === 0,
      'Web sent a sync push for the uncommitted Host after the quota failure');

    const quotaDuringFailure = await sendStorageCdp(
      cdp, 'Storage.getUsageAndQuota', { origin: quotaOrigin },
    );
    quotaDiagnostic = {
      ...quotaDiagnostic,
      overrideActiveDuringSave: quotaDuringFailure.overrideActive === true,
      quotaDuringSaveBytes: Number.isSafeInteger(quotaDuringFailure.quota)
        ? quotaDuringFailure.quota : null,
      usageDuringSaveBytes: Number.isSafeInteger(quotaDuringFailure.usage)
        ? quotaDuringFailure.usage : null,
    };
    assertThat(quotaDuringFailure.overrideActive === true &&
      quotaDuringFailure.quota === QUOTA_LIMIT_BYTES &&
      quotaDuringFailure.usage > quotaDuringFailure.quota,
    'origin quota was not still exceeded while the Web Host save failed');

    setStage('remove quota override and inspect durable rollback');
    await sendStorageCdp(cdp, 'Storage.overrideQuotaForOrigin', { origin: quotaOrigin });
    const restoredQuota = await sendStorageCdp(cdp, 'Storage.getUsageAndQuota', {
      origin: quotaOrigin,
    });
    await deleteQuotaProbeDatabase(page);
    quotaDiagnostic = {
      ...quotaDiagnostic,
      overrideActiveAfterReset: restoredQuota.overrideActive === true,
      restoredQuotaBytes: Number.isSafeInteger(restoredQuota.quota)
        ? restoredQuota.quota : null,
    };
    assertThat(restoredQuota.overrideActive === false,
      'Chromium did not remove the origin quota override');
    const failedServer = serverSnapshot();
    const failedClient = await clientSnapshot(page, 'after-quota-failure');
    assertThat(JSON.stringify(failedServer.counts) === JSON.stringify(baselineServer.counts) &&
      failedServer.commitSeq === baselineServer.commitSeq &&
      failedServer.plaintextMarkerFiles.length === 0,
    'server record/version/event/receipt/head or commit sequence changed after failed local save');
    assertThat(failedClient.integrityCheck === 'ok' &&
      JSON.stringify(failedClient.tableCounts) === JSON.stringify(baselineClient.tableCounts) &&
      !failedClient.markerFound,
    'actual IndexedDB SQLite image contains a partial Host or pending outbox after quota failure');

    setStage('restart same profile after quota recovery');
    await cdp.detach().catch(() => {});
    cdp = null;
    await context.close();
    context = null;
    await launchPersistentProfile();
    await waitForRestartedWorkspace(baseUrl);
    assertThat(pageErrorCount === 0,
      'Web reported an uncaught page error while reopening the same profile');
    const restartClient = await clientSnapshot(page, 'after-profile-restart');
    assertThat(restartClient.integrityCheck === 'ok' &&
      JSON.stringify(restartClient.tableCounts) === JSON.stringify(baselineClient.tableCounts),
    'restarted profile did not retain the last durable client SQLite snapshot');

    setStage('retry Host save once with the origin quota restored');
    const retryPushBaseline = pushRequests.length;
    await saveHost();
    await waitForText(HOST_NAME, 30000);
    const successfulResults = await waitForReceiptPush(retryPushBaseline);
    assertThat(successfulResults.length === 1,
      'retry did not produce exactly one fresh successful push receipt');
    const accepted = successfulResults[0];
    const success = { ...accepted, ...accepted.operation };
    const matchingRequests = pushRequests.slice(retryPushBaseline).filter((request) =>
      request.operations.some((operation) => operation.opId === success.opId));
    assertThat(success.commitSeq === (BigInt(baselineServer.commitSeq) + 1n).toString() &&
      matchingRequests.length >= 1 &&
      matchingRequests.every((request) => request.markerAbsent) &&
      new Set(matchingRequests.flatMap((request) => request.opIds)).size === 1,
    'retry push did not use one opaque Host operation and exactly one new commit sequence');
    await waitPendingCount(0, 45000);
    const finalServer = serverSnapshot({
      recordId: success.recordId,
      revisionId: success.revisionId,
      opId: success.opId,
      commitSeq: success.commitSeq,
      envelopeSha256: success.envelopeSha256,
    });
    const finalClient = await clientSnapshot(page, 'after-quota-retry');
    assertThat(finalServer.commitSeq === success.commitSeq &&
      BigInt(finalServer.commitSeq) === BigInt(baselineServer.commitSeq) + 1n &&
      finalServer.counts.record_heads === baselineServer.counts.record_heads + 1 &&
      finalServer.counts.record_versions === baselineServer.counts.record_versions + 1 &&
      finalServer.counts.change_events === baselineServer.counts.change_events + 1 &&
      finalServer.counts.op_receipts === baselineServer.counts.op_receipts + 1 &&
      finalServer.target?.versionCount === 1 && finalServer.target.versionMatches &&
      finalServer.target.eventCount === 1 && finalServer.target.eventMatches &&
      finalServer.target.headMatches && finalServer.target.receiptCount === 1 &&
      finalServer.target.receiptMatches && finalServer.target.opaqueEnvelope &&
      finalServer.target.requestEnvelopeHashMatches &&
      finalServer.target.versionEnvelopeHash === success.envelopeSha256 &&
      finalServer.target.eventEnvelopeHash === success.envelopeSha256 &&
      finalServer.plaintextMarkerFiles.length === 0,
    'successful retry did not produce exactly one encrypted server commit');
    assertThat(finalClient.integrityCheck === 'ok' &&
      finalClient.tableCounts.encrypted_records === baselineClient.tableCounts.encrypted_records + 1 &&
      finalClient.tableCounts.pending_operations === 0 && !finalClient.markerFound,
    'successful retry did not leave one local encrypted Host and an empty outbox');
    assertThat(pushRequests.slice(retryPushBaseline).every((request) => request.markerAbsent),
      'retry push request contained a plaintext Host marker');
    assertThat(pageErrorCount === 0,
      'Web reported an uncaught page error during the successful retry');

    successSummary = {
      cdpQuotaOverrideEffective,
      quotaOverrideActiveDuringFailure: true,
      quotaLimitBytes: QUOTA_LIMIT_BYTES,
      originUsageExceededLimit: true,
      nativeIndexedDbQuotaError: quotaProbe.transactionErrorName,
      driftImplementation,
      uiFailureSurfaced: true,
      uiReportedSuccessDuringFailure: false,
      pushCountDuringFailure: failedPushes,
      clientIntegrityBeforeFailure: baselineClient.integrityCheck,
      clientIntegrityAfterFailure: failedClient.integrityCheck,
      clientCountsUnchangedAfterFailure: true,
      serverCountsUnchangedAfterFailure: true,
      quotaOverrideRemoved: restoredQuota.overrideActive === false,
      sameProfileRestarted: true,
      retryCommitSeq: success.commitSeq,
      serverCommitDelta: 1,
      receiptVersionEventHeadDelta: 1,
      localPendingAfterRetry: 0,
      plaintextMarkersFound: false,
      uncaughtPageErrors: pageErrorCount,
    };
  } catch (error) {
    console.error(`WEB-STORAGE-QUOTA-01 failed at ${activeStage} (${safeErrorClass(error)})`);
    if (activeStage.startsWith('restart same profile') && page && !page.isClosed()) {
      console.error('WEB-STORAGE-QUOTA-01 restart UI diagnostic',
        JSON.stringify(await safeRegistrationUiState()));
    }
    if (activeStage.startsWith('owner registration')) {
      console.error('WEB-STORAGE-QUOTA-01 registration UI diagnostic',
        JSON.stringify(await safeRegistrationUiState()));
      console.error('WEB-STORAGE-QUOTA-01 static resource diagnostic', JSON.stringify({
        initialDocumentStatus,
        consoleErrorCount: browserConsoleErrorCount,
        assetResponses: staticAssetResponses,
        assetFailures: staticAssetFailures,
        registrationUi: await safeRegistrationUiState(),
      }));
    }
    if (page && !page.isClosed()) {
      const ui = await visibleSaveFailure().catch(() => null);
      console.error('WEB-STORAGE-QUOTA-01 safe diagnostic', JSON.stringify({
        quota: quotaDiagnostic,
        cdp: cdpDiagnostic,
        nativeIndexedDbProbe: nativeQuotaProbeDiagnostic,
        driftImplementation,
        pushRequestCount: pushRequests.length,
        visibleUiState: ui,
        pageErrorCount,
      }));
    }
    process.exitCode = 1;
  } finally {
    if (cdp) {
      try {
        if (quotaOrigin) await cdp.send('Storage.overrideQuotaForOrigin', {
          origin: quotaOrigin,
        });
      } catch (_) {
        // Closing the isolated browser context below also discards its quota override.
      }
      try { await cdp.detach(); } catch (_) {}
    }
    if (context) await context.close().catch(() => { cleanupFailed = true; });
    await stopServerGroup(serverProcess).catch(() => { cleanupFailed = true; });
    if (serverLogFd !== undefined) {
      try { fs.closeSync(serverLogFd); } catch (_) { cleanupFailed = true; }
    }
    if (tempRoot) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
      catch (_) { cleanupFailed = true; }
      if (fs.existsSync(tempRoot)) cleanupFailed = true;
    }
    if (cleanupFailed) {
      console.error('WEB-STORAGE-QUOTA-01 cleanup incomplete');
      process.exitCode = 1;
    }
  }
  if (successSummary && !cleanupFailed && process.exitCode !== 1) {
    console.log('WEB-STORAGE-QUOTA-01 passed', JSON.stringify({
      ...successSummary,
      cleanup: 'passed',
    }));
  }
}

main().catch((error) => {
  console.error(`WEB-STORAGE-QUOTA-01 harness failed during ${activeStage} (${safeErrorClass(error)})`);
  process.exitCode = 1;
});
