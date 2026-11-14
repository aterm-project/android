/*
 * Web session refresh acceptance: two same-origin tabs share one Owner
 * device/session snapshot, both tabs receive an HTTP 401 for a gated fresh
 * notification ticket, and the browser lock coordinates one single-use refresh
 * rotation.
 *
 * Diagnostics intentionally retain only route, status, page label, and
 * SHA-256 hashes of bearer values in memory for equality checks. Tokens and
 * request/response bodies are never printed or persisted.
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
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `refresh-it-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `RefreshIT-${crypto.randomBytes(20).toString('hex')}9`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
let activeStage = 'startup';

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} failed with status ${result.status}`);
  }
  return result.stdout;
}

async function unusedPort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitReady(baseUrl, child) {
  const deadline = Date.now() + 30000;
  let lastStatus = 'no response';
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('server exited before readiness');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      lastStatus = String(response.status);
      if (response.status === 200) return;
    } catch (error) {
      lastStatus = error?.name === 'TimeoutError' ? 'timeout' : 'connection-error';
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`server readiness timed out (${lastStatus})`);
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  );
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const visible = [];
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) visible.push(candidate);
    }
    assertThat(visible.length <= 1, `field '${label}' was not unique`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`visible field was unavailable: ${label}`);
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 50 });
    await page.waitForTimeout(200);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`visible field did not retain input: ${label}`);
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button was unavailable: ${label}`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function requestManualSync(page) {
  const locator = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await locator.isVisible().catch(() => false) &&
        await locator.isEnabled().catch(() => false)) {
      const label = await locator.getAttribute('aria-label') ||
        (await locator.innerText()).trim();
      if (label !== 'Syncing') {
        await locator.click();
        return;
      }
    }
    await page.waitForTimeout(100);
  }
  throw new Error('authenticated sync control did not become available');
}

async function waitForInputOrWorkspace(page) {
  const login = page.locator('input[aria-label*="Email or username"]');
  const addHost = page.getByRole('button', { name: 'Add host', exact: true });
  const serverUrl = page.locator('input[aria-label*="Server URL"]');
  await selectServerModeIfChooser(page, login);
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    if (await login.isVisible().catch(() => false)) return 'login';
    if (await addHost.isVisible().catch(() => false)) return 'workspace';
    if (await serverUrl.isVisible().catch(() => false)) return 'server';
    await page.waitForTimeout(100);
  }
  throw new Error('second tab did not reach server selection, login, or workspace');
}

async function safeSecondTabControls(page) {
  return page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        rect.width > 0 && rect.height > 0;
    };
    const visibleInput = (label) => [...document.querySelectorAll('input,textarea')]
      .some((element) => visible(element) &&
        (element.getAttribute('aria-label') || '').includes(label));
    const visibleButton = (label) => [...document.querySelectorAll('flt-semantics[role="button"]')]
      .some((element) => visible(element) &&
        `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
          .replace(/\s+/g, ' ').trim() === label);
    return {
      continueVisible: visibleButton('Continue'),
      serverUrlVisible: visibleInput('Server URL'),
      connectVisible: visibleButton('Connect securely'),
      emailVisible: visibleInput('Email or username'),
      passwordVisible: visibleInput('Master password'),
      ownerEmailVisible: visibleInput('Owner email'),
      signInVisible: visibleButton('Sign in and unlock'),
      createOwnerVisible: visibleButton('Create owner account'),
      addHostVisible: visibleButton('Add host'),
    };
  }).catch(() => ({
    continueVisible: false,
    serverUrlVisible: false,
    connectVisible: false,
    emailVisible: false,
    passwordVisible: false,
    ownerEmailVisible: false,
    signInVisible: false,
    createOwnerVisible: false,
    addHostVisible: false,
  }));
}

async function enableFlutterSemantics(page) {
  const deadline = Date.now() + 30000;
  let startupReady = false;
  while (Date.now() < deadline) {
    startupReady = await page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      window.__e2eFlutterProbe?.runAppCompleted === true &&
      Boolean(document.querySelector('flt-semantics-placeholder')),
    ).catch(() => false);
    if (startupReady) break;
    await page.waitForTimeout(100);
  }
  assertThat(startupReady, 'current Flutter Web bundle did not initialize');
  const sodiumReady = await page.evaluate(async () => Promise.race([
    window.sodium.ready.then(() => 'ready', () => 'failed'),
    new Promise((resolve) => setTimeout(() => resolve('timeout'), 10000)),
  ]));
  assertThat(sodiumReady === 'ready', 'Web crypto runtime was not ready');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 15000 });
}

async function installBrowserProbes(context) {
  await context.addInitScript(() => {
    window.__e2eFlutterProbe = {
      initializerCalled: false,
      engineInitialized: false,
      runAppCompleted: false,
    };
    window.__e2eSessionSignalKinds = [];
    let storageWriteFailureCount = 0;
    const storageSetItem = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      try {
        return storageSetItem.call(this, key, value);
      } catch (error) {
        storageWriteFailureCount += 1;
        throw error;
      }
    };
    window.__e2eStorageWriteFailureCount = () => storageWriteFailureCount;
    let refreshLockRequestCount = 0;
    try {
      const lockManager = window.navigator.locks;
      const originalLockRequest = lockManager.request.bind(lockManager);
      Object.defineProperty(lockManager, 'request', {
        configurable: true,
        value: (...args) => {
          if (args[0] === 'atermius.auth-refresh.v1') refreshLockRequestCount += 1;
          return originalLockRequest(...args);
        },
      });
    } catch (_) {}
    window.__e2eRefreshLockRequestCount = () => refreshLockRequestCount;
    window.addEventListener('storage', (event) => {
      if (event.key !== 'atermius.session.event.v1' || typeof event.newValue !== 'string') return;
      try {
        const kind = JSON.parse(event.newValue)?.kind;
        if (['rotationPending', 'updated', 'removed', 'refreshUnrecoverable'].includes(kind)) {
          window.__e2eSessionSignalKinds.push(kind);
        }
      } catch (_) {}
    });
    const flutter = {};
    let loader;
    Object.defineProperty(window, '_flutter', {
      configurable: true,
      get: () => flutter,
      set: (value) => { if (value && typeof value === 'object') Object.assign(flutter, value); },
    });
    Object.defineProperty(flutter, 'loader', {
      configurable: true,
      get: () => loader,
      set: (value) => {
        loader = value;
        let original;
        Object.defineProperty(loader, 'didCreateEngineInitializer', {
          configurable: true,
          get: () => original,
          set: (callback) => {
            original = function (engineInitializer) {
              window.__e2eFlutterProbe.initializerCalled = true;
              if (typeof engineInitializer?.initializeEngine === 'function') {
                const initializeEngine = engineInitializer.initializeEngine.bind(engineInitializer);
                engineInitializer.initializeEngine = (...args) => initializeEngine(...args).then((runner) => {
                  window.__e2eFlutterProbe.engineInitialized = true;
                  const runApp = runner.runApp.bind(runner);
                  runner.runApp = (...runArgs) => Promise.resolve(runApp(...runArgs)).then((result) => {
                    window.__e2eFlutterProbe.runAppCompleted = true;
                    return result;
                  });
                  return runner;
                });
              }
              return callback(engineInitializer);
            };
          },
        });
      },
    });

    // Track only notification WebSocket object references after the app sends
    // its auth frame. Neither that frame nor any ticket value is retained.
    const notificationSockets = new Set();
    const readyNotificationSockets = new WeakSet();
    const instrumentedNotificationSockets = new WeakSet();
    let expiredSessionCloseCount = 0;
    const originalSend = WebSocket.prototype.send;
    WebSocket.prototype.send = function (data) {
      try {
        const url = new URL(this.url);
        if (url.pathname === '/api/v1/notifications' &&
            typeof data === 'string' && JSON.parse(data)?.type === 'authenticate') {
          notificationSockets.add(this);
          if (!instrumentedNotificationSockets.has(this)) {
            instrumentedNotificationSockets.add(this);
            this.addEventListener('message', (event) => {
              try {
                if (typeof event.data === 'string' &&
                    JSON.parse(event.data)?.type === 'ready') {
                  readyNotificationSockets.add(this);
                }
              } catch (_) {}
            });
            this.addEventListener('close', (event) => {
              if (event.code === 4001) expiredSessionCloseCount += 1;
            });
          }
        }
      } catch (_) {}
      return originalSend.apply(this, arguments);
    };
    window.__e2eNotificationSocketState = () => ({
      tracked: notificationSockets.size,
      open: [...notificationSockets].filter((socket) => socket.readyState === WebSocket.OPEN).length,
      readyOpen: [...notificationSockets].filter((socket) =>
        socket.readyState === WebSocket.OPEN && readyNotificationSockets.has(socket)).length,
      expiredSessionCloseCount,
    });
    window.__e2eCloseNotificationSockets = () => {
      let closed = 0;
      for (const socket of notificationSockets) {
        if (socket.readyState === WebSocket.OPEN) {
          socket.close(3000, 'acceptance reconnect');
          closed += 1;
        }
      }
      return {
        tracked: notificationSockets.size,
        open: [...notificationSockets].filter((socket) => socket.readyState === WebSocket.OPEN).length,
        closed,
      };
    };
  });
}

async function waitFor(predicate, timeoutMs, page, failureMessage) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await page.waitForTimeout(100);
  }
  throw new Error(failureMessage);
}

async function waitForAsync(predicate, timeoutMs, page, failureMessage) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await page.waitForTimeout(100);
  }
  throw new Error(failureMessage);
}

async function closeNotificationSocketWhenOpen(page, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await page.evaluate(() => window.__e2eCloseNotificationSockets());
    if (result.closed >= 1) return result;
    await page.waitForTimeout(100);
  }
  throw new Error('authenticated notification socket did not become closable');
}

function databaseSession(databasePath, accessHash) {
  const script = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'token_hash=json.loads(sys.stdin.read())',
    "row=db.execute('SELECT s.session_id,s.user_id,s.device_id,s.family_id,s.access_hash,s.access_expires_at,s.revoked_at,d.status FROM sessions s JOIN devices d ON d.device_id=s.device_id WHERE s.access_hash=?',(token_hash,)).fetchone()",
    'if row is None: print(json.dumps({\'found\':False}))',
    'else:',
    "    history=db.execute('SELECT COUNT(*) FROM refresh_history WHERE family_id=?',(row[3],)).fetchone()[0]",
    "    active=db.execute('SELECT COUNT(*) FROM sessions WHERE family_id=? AND revoked_at IS NULL',(row[3],)).fetchone()[0]",
    "    print(json.dumps({'found':True,'sessionId':row[0],'userId':row[1],'deviceId':row[2],'familyId':row[3],'accessHash':row[4],'accessExpiresAt':row[5],'revoked':row[6] is not None,'deviceStatus':row[7],'refreshHistoryCount':history,'activeFamilySessionCount':active}))",
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath], {
    encoding: 'utf8', timeout: 8000, input: JSON.stringify(accessHash),
  });
  assertThat(result.status === 0, 'server session state could not be inspected');
  try { return JSON.parse(result.stdout); } catch (_) {
    throw new Error('server session inspection returned invalid data');
  }
}

function expireSessionAccess(databasePath, accessHash) {
  const script = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect(sys.argv[1],timeout=5)",
    'token_hash=json.loads(sys.stdin.read())',
    "cursor=db.execute(\"UPDATE sessions SET access_expires_at='2000-01-01T00:00:00Z' WHERE access_hash=? AND revoked_at IS NULL\",(token_hash,))",
    'db.commit()',
    "print(json.dumps({'updatedRows':cursor.rowcount}))",
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath], {
    encoding: 'utf8', timeout: 8000, input: JSON.stringify(accessHash),
  });
  assertThat(result.status === 0, 'server-side access expiry mutation failed');
  try { return JSON.parse(result.stdout); } catch (_) {
    throw new Error('server expiry mutation returned invalid data');
  }
}

function finalFamilySnapshot(databasePath, familyId) {
  const script = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'family=sys.argv[2]',
    "rows=db.execute('SELECT s.session_id,s.user_id,s.device_id,s.access_hash,s.revoked_at,d.status FROM sessions s JOIN devices d ON d.device_id=s.device_id WHERE s.family_id=?',(family,)).fetchall()",
    "history=db.execute('SELECT COUNT(*) FROM refresh_history WHERE family_id=?',(family,)).fetchone()[0]",
    "print(json.dumps({'sessionCount':len(rows),'activeSessionCount':sum(1 for row in rows if row[4] is None),'activeDeviceCount':sum(1 for row in rows if row[4] is None and row[5]=='active'),'accessHashes':[row[3] for row in rows if row[4] is None],'refreshHistoryCount':history,'userIds':[row[1] for row in rows],'deviceIds':[row[2] for row in rows]}))",
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, familyId], {
    encoding: 'utf8', timeout: 8000,
  });
  assertThat(result.status === 0, 'server refresh-family state could not be inspected');
  try { return JSON.parse(result.stdout); } catch (_) {
    throw new Error('server refresh-family inspection returned invalid data');
  }
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
  'compiled current Web bundle is missing');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST]);
  assertThat(fs.existsSync(SERVER_BINARY), 'server binary is missing after build');

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-session-refresh-'));
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const serverLog = fs.openSync(path.join(tempRoot, 'server.log'), 'a');
  const port = await unusedPort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const databasePath = path.join(dataDir, 'atermius.db');
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
  let serverProcess;
  let browser;
  let context;
  const pages = {};
  const apiEvents = [];
  const authDeviceIds = new Map();
  const requestMeta = new WeakMap();
  let bootstrapToken;

  try {
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      stdio: ['ignore', serverLog, serverLog],
    });
    await waitReady(baseUrl, serverProcess);
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
    });
    assertThat(bootstrap.status === 0, 'temporary server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(bootstrapToken && bootstrapToken.length >= 40,
      'temporary server did not issue a bootstrap token');

    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
    });
    await installBrowserProbes(context);
    const profileByPage = new Map();
    for (const profile of ['A', 'B']) {
      const page = await context.newPage();
      pages[profile] = page;
      profileByPage.set(page, profile);
      page.on('request', (request) => {
        const url = new URL(request.url());
        if (!url.pathname.startsWith('/api/')) return;
        let accessHash = null;
        const authorization = request.headers().authorization || '';
        if (authorization.startsWith('Bearer ')) {
          accessHash = crypto.createHash('sha256')
            .update(authorization.slice('Bearer '.length)).digest('hex');
        }
        requestMeta.set(request, { profile, method: request.method(), path: url.pathname, accessHash });
        if (url.pathname === '/api/v1/auth/register' ||
            url.pathname === '/api/v1/auth/login') {
          try {
            const body = request.postDataJSON();
            const deviceId = body?.device_id || body?.device?.device_id;
            if (typeof deviceId === 'string' && UUID.test(deviceId)) {
              authDeviceIds.set(profile, deviceId);
            }
          } catch (_) {}
        }
      });
      page.on('response', (response) => {
        const meta = requestMeta.get(response.request());
        if (!meta) return;
        apiEvents.push({ ...meta, status: response.status() });
      });
    }

    activeStage = 'first tab current bundle startup';
    const pageAResponse = await pages.A.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    assertThat(pageAResponse?.status() === 200,
      'first same-origin application page did not load');
    await enableFlutterSemantics(pages.A);
    await button(pages.A, 'Connect securely');

    activeStage = 'Owner registration in first tab';
    await fill(pages.A, 'Server URL', baseUrl);
    await click(pages.A, 'Connect securely');
    await field(pages.A, 'Owner email');
    await fill(pages.A, 'Owner email', USERNAME);
    await fill(pages.A, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(pages.A, 'Confirm master password', MASTER_PASSWORD);
    await fill(pages.A, 'One-time bootstrap token', bootstrapToken);
    await fill(pages.A, 'Device name', 'Session refresh browser');
    await fill(pages.A, 'First Vault', 'Refresh acceptance Vault');
    await click(pages.A, 'Create owner account');
    bootstrapToken = undefined;
    await waitWorkspace(pages.A);

    try {
      activeStage = 'second tab load after Owner registration';
      const pageBResponse = await pages.B.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      assertThat(pageBResponse?.status() === 200,
        'second same-origin application page did not load');
      activeStage = 'second tab Flutter startup';
      await enableFlutterSemantics(pages.B);
      activeStage = 'second tab settle last-server restoration';
      await pages.B.waitForTimeout(400);

      activeStage = 'second tab detect initial auth state';
      let stateB = await waitForInputOrWorkspace(pages.B);
      // A freshly-created page reads the same-origin last-server record during
      // asynchronous Flutter startup. If its transient server form is visible,
      // give restoration a bounded interval, then detect the state again before
      // manually submitting the server URL.
      for (let attempt = 0; stateB === 'server' && attempt < 3; attempt += 1) {
        activeStage = `second tab settle server restore ${attempt + 1}`;
        await pages.B.waitForTimeout(400);
        activeStage = `second tab redetect auth state ${attempt + 1}`;
        stateB = await waitForInputOrWorkspace(pages.B);
      }

      if (stateB === 'server') {
        activeStage = 'second tab fill server URL';
        await fill(pages.B, 'Server URL', baseUrl);
        activeStage = 'second tab connect server';
        await click(pages.B, 'Connect securely');
        activeStage = 'second tab detect state after connect';
        stateB = await waitForInputOrWorkspace(pages.B);
      }
      if (stateB === 'login') {
        activeStage = 'second tab fill account name';
        await fill(pages.B, 'Email or username', USERNAME);
        activeStage = 'second tab fill master password';
        await fill(pages.B, 'Master password', MASTER_PASSWORD);
        activeStage = 'second tab submit sign-in';
        await click(pages.B, 'Sign in and unlock');
      }
      activeStage = 'second tab wait for workspace';
      await waitWorkspace(pages.B);
    } catch (_) {
      const safeApi = apiEvents.filter((entry) => entry.profile === 'B').slice(-12)
        .map(({ method, path: apiPath, status }) => ({
          method,
          path: apiPath.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi, '/{id}'),
          status,
        }));
      console.log('second tab safe failure evidence', JSON.stringify({
        controls: await safeSecondTabControls(pages.B),
        api: safeApi,
      }));
      throw new Error('second-tab setup failed');
    }

    const deviceIdA = authDeviceIds.get('A');
    const deviceIdB = authDeviceIds.get('B') || deviceIdA;
    assertThat(typeof deviceIdA === 'string' && UUID.test(deviceIdA) &&
      deviceIdA === deviceIdB,
    'two tabs did not resolve to the same registered device UUID');
    const storageCatalogs = await Promise.all(['A', 'B'].map((profile) =>
      pages[profile].evaluate(async () => ({
        origin: location.origin,
        localStorageKeys: Object.keys(localStorage).sort(),
        indexedDbNames: (await indexedDB.databases()).map((item) => item.name)
          .filter(Boolean).sort(),
      }))));
    assertThat(storageCatalogs.every((item) => item.origin === baseUrl) &&
      JSON.stringify(storageCatalogs[0].localStorageKeys) ===
        JSON.stringify(storageCatalogs[1].localStorageKeys) &&
      JSON.stringify(storageCatalogs[0].indexedDbNames) ===
        JSON.stringify(storageCatalogs[1].indexedDbNames),
    'same BrowserContext tabs did not share the same origin storage catalog');

    activeStage = 'wait for successful ticket in each tab after login';
    let firstTicketSuccesses;
    try {
      firstTicketSuccesses = await waitFor(() => {
        const found = {};
        for (const profile of ['A', 'B']) {
          found[profile] = apiEvents.find((entry) => entry.profile === profile &&
            entry.method === 'POST' && entry.path === '/api/v1/notifications/tickets' &&
            entry.status === 200 && entry.accessHash);
        }
        return found.A && found.B ? found : null;
      }, 30000, pages.B, 'both tabs did not issue authenticated sync-hint tickets');
    } catch (_) {
      const safeAuthEvents = apiEvents.filter((entry) =>
        entry.path === '/api/v1/auth/register' || entry.path === '/api/v1/auth/login' ||
        entry.path === '/api/v1/auth/refresh' ||
        entry.path === '/api/v1/notifications/tickets').map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method, route: apiPath, status, hasAccessCredential: Boolean(accessHash),
        }));
      console.log('initial ticket safe failure evidence', JSON.stringify({
        authAndTicketEvents: safeAuthEvents,
        sameDeviceId: Boolean(authDeviceIds.get('A') &&
          authDeviceIds.get('A') === (authDeviceIds.get('B') || authDeviceIds.get('A'))),
        controlsA: await safeSecondTabControls(pages.A),
        controlsB: await safeSecondTabControls(pages.B),
      }));
      throw new Error('both tabs did not issue authenticated sync-hint tickets');
    }

    activeStage = 'close initial notification sockets to observe shared snapshot adoption';
    const snapshotCloseResults = await Promise.all(['A', 'B'].map((profile) =>
      closeNotificationSocketWhenOpen(pages[profile])));
    console.log('shared snapshot socket close counts', JSON.stringify(
      snapshotCloseResults.map(({ tracked, open, closed }) => ({ tracked, open, closed }))));
    assertThat(snapshotCloseResults.every((result) => result.closed >= 1),
      'test browser could not trigger a session-snapshot reconnect in both tabs');
    const snapshotTicketStart = apiEvents.length;
    let sharedTicketSuccesses;
    try {
      sharedTicketSuccesses = await waitFor(() => {
        const latest = {};
        for (const profile of ['A', 'B']) {
          latest[profile] = apiEvents.slice(snapshotTicketStart).filter((entry) =>
            entry.profile === profile && entry.method === 'POST' &&
            entry.path === '/api/v1/notifications/tickets' && entry.status === 200 &&
            entry.accessHash).at(-1);
        }
        return latest.A && latest.B && latest.A.accessHash === latest.B.accessHash
          ? latest : null;
      }, 30000, pages.B,
      'both tabs did not request fresh tickets with the shared session snapshot');
    } catch (_) {
      const safeTicketEvents = apiEvents.slice(snapshotTicketStart).filter((entry) =>
        entry.path === '/api/v1/notifications/tickets' ||
        entry.path === '/api/v1/auth/refresh').map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method, route: apiPath, status, hasAccessCredential: Boolean(accessHash),
        }));
      const latest = {};
      for (const profile of ['A', 'B']) {
        latest[profile] = apiEvents.slice(snapshotTicketStart).filter((entry) =>
          entry.profile === profile && entry.method === 'POST' &&
          entry.path === '/api/v1/notifications/tickets' && entry.status === 200 &&
          entry.accessHash).at(-1);
      }
      console.log('shared snapshot safe failure evidence', JSON.stringify({
        events: safeTicketEvents,
        bothTabsReceivedFreshTicket: Boolean(latest.A && latest.B),
        latestTicketCredentialsMatch: Boolean(latest.A && latest.B &&
          latest.A.accessHash === latest.B.accessHash),
      }));
      throw new Error('both tabs did not converge on the shared session snapshot');
    }
    const activeSession = databaseSession(databasePath, sharedTicketSuccesses.A.accessHash);
    assertThat(activeSession.found && activeSession.deviceId === deviceIdA &&
      !activeSession.revoked && activeSession.deviceStatus === 'active',
    'shared browser ticket did not map to an active Owner device session');

    activeStage = 'wait for authenticated notification sockets';
    await waitWorkspace(pages.A);
    await waitWorkspace(pages.B);
    const socketStatesBeforeExpiry = {};
    for (const profile of ['A', 'B']) {
      socketStatesBeforeExpiry[profile] = await waitForAsync(async () => {
        const state = await pages[profile].evaluate(() =>
          window.__e2eNotificationSocketState());
        return state.readyOpen > 0 ? state : null;
      }, 20000, pages[profile],
      `tab ${profile} did not open an authenticated notification socket`);
    }

    const apiEventStart = apiEvents.length;
    const refreshLockRequestsBefore = Object.fromEntries(await Promise.all(
      ['A', 'B'].map(async (profile) => [profile,
        await pages[profile].evaluate(() => window.__e2eRefreshLockRequestCount()),
      ])));
    activeStage = 'gate one fresh notification ticket request in each tab';
    const ticketRoutePattern = '**/api/v1/notifications/tickets';
    const refreshRoutePattern = '**/api/v1/auth/refresh';
    const heldTicketRoutes = { A: [], B: [] };
    const ticketRouteArmed = { A: true, B: true };
    const heldRefreshRoutes = { A: [], B: [] };
    const refreshRouteArmed = { A: true, B: true };
    for (const profile of ['A', 'B']) {
      await pages[profile].route(ticketRoutePattern, async (route) => {
        if (!ticketRouteArmed[profile]) {
          await route.continue();
          return;
        }
        ticketRouteArmed[profile] = false;
        const authorization = route.request().headers().authorization || '';
        const accessHash = authorization.startsWith('Bearer ')
          ? crypto.createHash('sha256')
            .update(authorization.slice('Bearer '.length)).digest('hex')
          : null;
        let release;
        let finished;
        const gate = new Promise((resolve) => { release = resolve; });
        const done = new Promise((resolve) => { finished = resolve; });
        heldTicketRoutes[profile].push({ route, accessHash, release, done });
        await gate;
        try {
          await route.continue();
        } finally {
          finished();
        }
      });
      await pages[profile].route(refreshRoutePattern, async (route) => {
        if (!refreshRouteArmed[profile]) {
          await route.continue();
          return;
        }
        refreshRouteArmed[profile] = false;
        let release;
        let finished;
        const gate = new Promise((resolve) => { release = resolve; });
        const done = new Promise((resolve) => { finished = resolve; });
        heldRefreshRoutes[profile].push({ route, release, done });
        await gate;
        try {
          await route.continue();
        } finally {
          finished();
        }
      });
    }
    const closeResults = await Promise.all(['A', 'B'].map((profile) =>
      closeNotificationSocketWhenOpen(pages[profile])));
    assertThat(closeResults.every((result) => result.closed >= 1),
      'test browser could not trigger a fresh ticket request from both tabs');
    try {
      await waitFor(() => heldTicketRoutes.A.length > 0 && heldTicketRoutes.B.length > 0,
        30000, pages.A,
        'both tabs did not reach the gated fresh-ticket request');
    } catch (_) {
      const safeEvents = apiEvents.slice(apiEventStart).filter((entry) =>
        entry.path === '/api/v1/notifications/tickets' ||
        entry.path === '/api/v1/auth/refresh' ||
        entry.path.startsWith('/api/v1/vaults')).map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method, route: apiPath, status, hasAccessCredential: Boolean(accessHash),
        }));
      console.log('ticket gate safe failure evidence', JSON.stringify({
        events: safeEvents,
        gatedProfiles: Object.fromEntries(['A', 'B'].map((profile) => [profile,
          heldTicketRoutes[profile].length,
        ])),
        socketStates: await Promise.all(['A', 'B'].map(async (profile) => ({
          profile,
          ...(await pages[profile].evaluate(() => window.__e2eNotificationSocketState())),
        }))),
        controls: {
          A: await safeSecondTabControls(pages.A),
          B: await safeSecondTabControls(pages.B),
        },
      }));
      throw new Error('both tabs did not reach the gated fresh-ticket request');
    }

    const gatedTicketHashes = {
      A: heldTicketRoutes.A[0].accessHash,
      B: heldTicketRoutes.B[0].accessHash,
    };
    assertThat(gatedTicketHashes.A === activeSession.accessHash &&
      gatedTicketHashes.B === activeSession.accessHash,
    'gated ticket requests did not use the shared active session credential');

    activeStage = 'settle in-flight authenticated requests before expiry';
    await pages.A.waitForTimeout(1200);

    activeStage = 'server-side access expiry';
    const expired = expireSessionAccess(databasePath, activeSession.accessHash);
    assertThat(expired.updatedRows === 1, 'server did not expire exactly one session access credential');

    activeStage = 'release both ticket requests and observe their 401 responses';
    await Promise.all(['A', 'B'].map((profile) =>
      pages[profile].unroute(ticketRoutePattern)));
    const pendingTicketRoutes = ['A', 'B'].flatMap((profile) => heldTicketRoutes[profile]);
    pendingTicketRoutes.forEach((entry) => entry.release());
    await Promise.all(pendingTicketRoutes.map((entry) => entry.done));
    try {
      await waitFor(() => ['A', 'B'].every((profile) =>
        apiEvents.slice(apiEventStart).some((entry) => entry.profile === profile &&
          entry.method === 'POST' && entry.path === '/api/v1/notifications/tickets' &&
          entry.status === 401)), 20000, pages.A,
      'both gated ticket requests did not receive HTTP 401');
    } catch (_) {
      const safeEvents = apiEvents.slice(apiEventStart).filter((entry) =>
        entry.path === '/api/v1/notifications/tickets' ||
        entry.path === '/api/v1/auth/refresh' ||
        entry.path.startsWith('/api/v1/vaults')).map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method, route: apiPath, status,
          hasAccessCredential: Boolean(accessHash),
          usesExpiredCredential: accessHash === activeSession.accessHash,
        }));
      console.log('expired ticket safe failure evidence', JSON.stringify({
        events: safeEvents,
        gatedTicketStatuses: Object.fromEntries(['A', 'B'].map((profile) => [profile,
          heldTicketRoutes[profile].length,
        ])),
        refreshRequestCount: safeEvents.filter((entry) =>
          entry.route === '/api/v1/auth/refresh').length,
        controls: {
          A: await safeSecondTabControls(pages.A),
          B: await safeSecondTabControls(pages.B),
        },
      }));
      throw new Error('both tabs did not receive the expected expired-ticket 401');
    }
    const expiredTicketResponses = apiEvents.slice(apiEventStart).filter((entry) =>
      entry.method === 'POST' && entry.path === '/api/v1/notifications/tickets' &&
      entry.status === 401);
    assertThat(expiredTicketResponses.length === 2 &&
      ['A', 'B'].every((profile) =>
        expiredTicketResponses.filter((entry) => entry.profile === profile).length === 1),
    'expected exactly one expired-ticket rejection from each tab');

    activeStage = 'wait for both tabs to enter the shared refresh lock';
    let refreshLockRequestsAfter401;
    try {
      refreshLockRequestsAfter401 = await waitForAsync(async () => {
        const counts = {};
        for (const profile of ['A', 'B']) {
          counts[profile] = await pages[profile].evaluate(() =>
            window.__e2eRefreshLockRequestCount());
        }
        return ['A', 'B'].every((profile) =>
          counts[profile] > refreshLockRequestsBefore[profile]) ? counts : null;
      }, 20000, pages.A,
      'both tabs did not request the shared Web Lock after ticket rejection');
      await waitFor(() => Object.values(heldRefreshRoutes).some((routes) =>
        routes.length > 0), 20000, pages.A,
      'no refresh request reached the held HTTP route');
    } catch (_) {
      console.log('refresh lock contention safe failure evidence', JSON.stringify({
        ticket401ByTab: Object.fromEntries(['A', 'B'].map((profile) => [profile,
          apiEvents.slice(apiEventStart).filter((entry) =>
            entry.profile === profile && entry.path === '/api/v1/notifications/tickets' &&
            entry.status === 401).length,
        ])),
        refreshLockRequestsBefore,
        refreshLockRequestsAfter: await Promise.all(['A', 'B'].map(async (profile) => ({
          profile,
          count: await pages[profile].evaluate(() =>
            window.__e2eRefreshLockRequestCount()),
        }))),
        refreshRoutesCaptured: Object.fromEntries(['A', 'B'].map((profile) => [profile,
          heldRefreshRoutes[profile].length,
        ])),
        controls: {
          A: await safeSecondTabControls(pages.A),
          B: await safeSecondTabControls(pages.B),
        },
      }));
      throw new Error('both tabs did not contend for the shared refresh lock');
    }
    const capturedRefreshRoutes = ['A', 'B'].flatMap((profile) =>
      heldRefreshRoutes[profile]);
    assertThat(capturedRefreshRoutes.length === 1,
      'more than one HTTP refresh reached the route while the first request was held');
    await Promise.all(['A', 'B'].map((profile) =>
      pages[profile].unroute(refreshRoutePattern)));
    capturedRefreshRoutes.forEach((entry) => entry.release());
    await Promise.all(capturedRefreshRoutes.map((entry) => entry.done));

    activeStage = 'observe one successful refresh rotation';
    await waitFor(() => apiEvents.slice(apiEventStart).some((entry) =>
      entry.method === 'POST' && entry.path === '/api/v1/auth/refresh' &&
      entry.status === 200), 30000, pages.A,
    'neither tab completed the expired-session refresh');
    await pages.A.waitForTimeout(1000);
    const refreshResponses = apiEvents.slice(apiEventStart).filter((entry) =>
      entry.method === 'POST' && entry.path === '/api/v1/auth/refresh');
    assertThat(refreshResponses.length === 1 && refreshResponses[0].status === 200,
      'concurrent browser refresh did not make exactly one successful rotation request');

    activeStage = 'verify session-family and device state';
    const finalSessionState = finalFamilySnapshot(databasePath, activeSession.familyId);
    assertThat(finalSessionState.sessionCount === 1 &&
      finalSessionState.activeSessionCount === 1 &&
      finalSessionState.activeDeviceCount === 1 &&
      finalSessionState.refreshHistoryCount === 1 &&
      finalSessionState.accessHashes.length === 1 &&
      finalSessionState.userIds.every((id) => id === activeSession.userId) &&
      finalSessionState.deviceIds.every((id) => id === deviceIdA),
    'session family or device did not remain active on the single rotated credential');

    activeStage = 'verify both tabs adopt the rotated session through sync tickets';
    const rotatedAccessHash = finalSessionState.accessHashes[0];
    let adoptedTicketRequests;
    try {
      adoptedTicketRequests = await waitFor(() => {
        const found = {};
        for (const profile of ['A', 'B']) {
          found[profile] = apiEvents.slice(apiEventStart).filter((entry) =>
            entry.profile === profile && entry.method === 'POST' &&
            entry.path === '/api/v1/notifications/tickets' &&
            entry.status === 200 && entry.accessHash === rotatedAccessHash).at(-1);
        }
        return found.A && found.B ? found : null;
      }, 30000, pages.A,
      'both tabs did not request tickets with the rotated session snapshot');
    } catch (_) {
      const safeEvents = apiEvents.slice(apiEventStart).filter((entry) =>
        entry.path === '/api/v1/notifications/tickets' ||
        entry.path === '/api/v1/auth/refresh').map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method, route: apiPath, status,
          hasAccessCredential: Boolean(accessHash),
          usesCurrentCredential: accessHash === rotatedAccessHash,
        }));
      console.log('rotated ticket adoption safe failure evidence', JSON.stringify({
        events: safeEvents,
        socketStates: await Promise.all(['A', 'B'].map(async (profile) => ({
          profile,
          ...(await pages[profile].evaluate(() => window.__e2eNotificationSocketState())),
        }))),
        controls: {
          A: await safeSecondTabControls(pages.A),
          B: await safeSecondTabControls(pages.B),
        },
        sessionSignalKinds: await Promise.all(['A', 'B'].map(async (profile) => ({
          profile,
          kinds: await pages[profile].evaluate(() => window.__e2eSessionSignalKinds.slice()),
          storageWriteFailures: await pages[profile].evaluate(() =>
            window.__e2eStorageWriteFailureCount()),
        }))),
      }));
      throw new Error('both tabs did not adopt the rotated session snapshot');
    }

    activeStage = 'verify both tabs can read the Vault with the rotated credential';
    const authenticatedFollowupStart = apiEvents.length;
    await Promise.all(['A', 'B'].map((profile) => requestManualSync(pages[profile])));
    let authenticatedFollowups;
    try {
      authenticatedFollowups = await waitFor(() => {
        const found = {};
        for (const profile of ['A', 'B']) {
          found[profile] = apiEvents.slice(authenticatedFollowupStart).find((entry) =>
            entry.profile === profile && entry.method === 'GET' &&
            entry.path.startsWith('/api/v1/vaults') && entry.status === 200 &&
            entry.accessHash);
        }
        return found.A && found.B ? found : null;
      }, 30000, pages.A,
      'one or both tabs could not make an authenticated Vault request after refresh');
    } catch (_) {
      const safeEvents = apiEvents.slice(authenticatedFollowupStart).filter((entry) =>
        entry.path.startsWith('/api/v1/vaults') ||
        entry.path === '/api/v1/notifications/tickets' ||
        entry.path === '/api/v1/auth/refresh').map(({ profile, method, path: apiPath, status, accessHash }) => ({
          profile, method,
          route: apiPath.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi, '/{id}'),
          status,
          hasAccessCredential: Boolean(accessHash),
          usesCurrentCredential: accessHash === rotatedAccessHash,
        }));
      console.log('rotated Vault follow-up safe failure evidence', JSON.stringify({
        events: safeEvents,
        controls: {
          A: await safeSecondTabControls(pages.A),
          B: await safeSecondTabControls(pages.B),
        },
      }));
      throw new Error('one or both tabs did not complete an authenticated Vault request');
    }
    const rotatedCredentialEvidence = {
      statuses: {
        A: authenticatedFollowups.A.status,
        B: authenticatedFollowups.B.status,
      },
      tabCredentialsMatch: authenticatedFollowups.A.accessHash ===
        authenticatedFollowups.B.accessHash,
      tabACurrent: authenticatedFollowups.A.accessHash === finalSessionState.accessHashes[0],
      tabBCurrent: authenticatedFollowups.B.accessHash === finalSessionState.accessHashes[0],
    };
    console.log('rotated credential adoption safe evidence', JSON.stringify(rotatedCredentialEvidence));
    assertThat(rotatedCredentialEvidence.tabACurrent && rotatedCredentialEvidence.tabBCurrent,
    'one or both tabs did not adopt the current server session credential');

    console.log('WEB-SESSION-REFRESH-MULTITAB passed', JSON.stringify({
      sameOriginTabs: 2,
      sameDeviceUuid: deviceIdA === deviceIdB,
      sharedStorageCatalog: true,
      initialTicketStatuses: ['A', 'B'].map((profile) => firstTicketSuccesses[profile].status),
      sharedSnapshotReconnectClosures: snapshotCloseResults.map((result) => result.closed),
      authenticatedSocketsBeforeExpiry: ['A', 'B'].map((profile) =>
        socketStatesBeforeExpiry[profile].readyOpen),
      expiredTicket401ResponsesByTab: ['A', 'B'].map((profile) =>
        expiredTicketResponses.filter((entry) => entry.profile === profile).length),
      authenticatedVaultFollowupStatuses: ['A', 'B'].map((profile) =>
        authenticatedFollowups[profile].status),
      bothTabsUseCurrentAccessCredential: rotatedCredentialEvidence.tabCredentialsMatch &&
        rotatedCredentialEvidence.tabACurrent && rotatedCredentialEvidence.tabBCurrent,
      successfulTicketRetryCount: apiEvents.slice(apiEventStart).filter((entry) =>
        entry.path === '/api/v1/notifications/tickets' && entry.status === 200).length,
      refreshRotationRequests: refreshResponses.length,
      refreshLockRequestsByTab: ['A', 'B'].map((profile) =>
        refreshLockRequestsAfter401[profile] - refreshLockRequestsBefore[profile]),
      refreshHttpStatus: refreshResponses[0].status,
      refreshHistoryCount: finalSessionState.refreshHistoryCount,
      activeFamilySessions: finalSessionState.activeSessionCount,
      activeDeviceSessions: finalSessionState.activeDeviceCount,
    }));
  } finally {
    bootstrapToken = undefined;
    if (context) await context.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
    if (serverProcess && serverProcess.exitCode === null) {
      serverProcess.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => serverProcess.once('exit', resolve)),
        new Promise((resolve) => setTimeout(resolve, 5000)),
      ]);
      if (serverProcess.exitCode === null) serverProcess.kill('SIGKILL');
    }
    fs.closeSync(serverLog);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

main().catch((error) => {
  const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  console.error(`WEB-SESSION-REFRESH-MULTITAB failed at ${activeStage} (${errorClass}); diagnostic text omitted`);
  process.exitCode = 1;
});
