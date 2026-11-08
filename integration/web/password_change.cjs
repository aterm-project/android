/*
 * WEB-PASSWORD-01: change the account master password through the Flutter Web
 * UI, verify the active session survives, then lock and verify only the new
 * password can establish a session. All resources are temporary and local.
 * Output is limited to stage names, HTTP status codes, and boolean assertions.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let browserContext;
let bootstrapToken;
let username;
let oldPassword;
let newPassword;
let registeredAccountId;
let registeredDeviceId;
let cleanupPromise;
let cleanupFailed = false;
const safeApiStatuses = [];
const safeLoginErrorCodes = [];
const safeLoginControlStates = [];
const safeFillDiagnostics = [];
const pendingLoginCodeReads = [];
let newPasswordFieldLengthMatchesExpected = null;

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
  assertThat(!result.error && result.status === 0, 'isolated server build failed');
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated server binary is unavailable');
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
      // Continue polling while the loopback service starts.
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
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') {
        return true;
      }
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
  throw new Error('server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    username = undefined;
    oldPassword = undefined;
    newPassword = undefined;
    registeredAccountId = undefined;
    registeredDeviceId = undefined;
    try {
      if (browserContext) await browserContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
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

process.once('SIGINT', () => {
  void cleanup().finally(() => process.exit(130));
});
process.once('SIGTERM', () => {
  void cleanup().finally(() => process.exit(143));
});

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 60 });
    await page.waitForTimeout(200);
    const beforeBlur = await waitForStableFieldValue(locator, value);
    safeFillDiagnostics.push({
      stage,
      attempt,
      phase: 'before_blur',
      attempts: beforeBlur.attempts,
      matched: beforeBlur.matched,
    });
    if (!beforeBlur.matched) continue;

    await locator.press('Tab');
    await page.waitForTimeout(100);
    const afterBlur = await waitForStableFieldValue(locator, value);
    safeFillDiagnostics.push({
      stage,
      attempt,
      phase: 'after_blur',
      attempts: afterBlur.attempts,
      matched: afterBlur.matched,
    });
    if (afterBlur.matched) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitForStableFieldValue(locator, value, timeoutMs = 1200) {
  const deadline = Date.now() + timeoutMs;
  let attempts = 0;
  let stableMatches = 0;
  while (Date.now() < deadline) {
    attempts += 1;
    if ((await locator.inputValue()) === value) {
      stableMatches += 1;
      if (stableMatches >= 3) return { matched: true, attempts };
    } else {
      stableMatches = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { matched: false, attempts };
}

async function waitForText(page, text, timeoutMs = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible',
    timeout: timeoutMs,
  });
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
}

function apiRoute(request) {
  let pathname;
  try {
    pathname = new URL(request.url()).pathname;
  } catch (_) {
    return null;
  }
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/auth/login') return 'login';
  if (pathname === '/api/v1/auth/password-change') return 'password-change';
  if (pathname === '/api/v1/me') return 'profile';
  if (pathname === '/api/v1/audit') return 'audit';
  return null;
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-password-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const databasePath = path.join(dataDir, 'atermius.db');
  const port = await unusedLoopbackPort();
  const baseUrl = `http://127.0.0.1:${port}`;
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

  username = `web-password-${crypto.randomUUID().slice(0, 8)}@example.test`;
  oldPassword = `Current-${crypto.randomBytes(32).toString('base64url')}`;
  newPassword = `Changed-${crypto.randomBytes(32).toString('base64url')}`;

  const eventByRequest = new WeakMap();
  const apiEvents = [];
  let pageErrorCount = 0;

  try {
    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);

    setStage('isolated instance bootstrap');
    const bootstrapResult = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrapResult.error && bootstrapResult.status === 0, 'isolated bootstrap failed');
    bootstrapToken = (bootstrapResult.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap credential is unavailable');
    bootstrapResult.stdout = '';

    setStage('isolated Chromium context');
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    browserContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    const page = await browserContext.newPage();
    page.on('pageerror', () => { pageErrorCount += 1; });
    page.on('request', (request) => {
      const route = apiRoute(request);
      if (!route) return;
      const authorization = request.headers().authorization || '';
      eventByRequest.set(request, {
        route,
        method: request.method(),
        hasBearer: authorization.startsWith('Bearer ') && authorization.length > 7,
      });
    });
    page.on('response', (response) => {
      const metadata = eventByRequest.get(response.request());
      if (!metadata) return;
      const event = { ...metadata, status: response.status(), sequence: apiEvents.length };
      if (metadata.route === 'register') {
        event.payloadPromise = response.json().then((body) => ({
          accountId: typeof body?.account_id === 'string' ? body.account_id : null,
          deviceId: typeof body?.device_id === 'string' ? body.device_id : null,
        })).catch(() => ({ accountId: null, deviceId: null }));
      } else if (metadata.route === 'audit') {
        event.payloadPromise = response.json().then((body) => ({
          hasMore: body?.has_more === true,
          events: Array.isArray(body?.events) ? body.events.map((item) => ({
            fieldNames: item && typeof item === 'object' && !Array.isArray(item)
              ? Object.keys(item).sort()
              : [],
            eventId: typeof item?.event_id === 'string' ? item.event_id : null,
            scope: item?.scope,
            vaultId: item?.vault_id,
            actorUserId: item?.actor_user_id,
            actorDeviceId: item?.actor_device_id,
            action: item?.action,
            resourceType: item?.resource_type,
            resourceId: item?.resource_id,
            result: item?.result,
            source: item?.source,
          })) : [],
        })).catch(() => ({ hasMore: false, events: [] }));
      }
      apiEvents.push(event);
      safeApiStatuses.push({ route: metadata.route, status: response.status() });
      if (safeApiStatuses.length > 12) safeApiStatuses.shift();
      if (metadata.route === 'login' && [401, 403].includes(response.status())) {
        const status = response.status();
        const phase = stage.startsWith('old password rejection')
          ? 'old_password_rejection'
          : stage.startsWith('new password login') ? 'new_password_login' : 'other_login';
        pendingLoginCodeReads.push(response.json().then((body) => {
          const code = body?.error?.code;
          const allowed = ['AUTH_REQUIRED', 'DEVICE_REVOKED', 'RATE_LIMITED'];
          safeLoginErrorCodes.push({
            phase,
            status,
            code: allowed.includes(code) ? code : 'OTHER_OR_UNAVAILABLE',
          });
        }).catch(() => {
          safeLoginErrorCodes.push({ phase, status, code: 'OTHER_OR_UNAVAILABLE' });
        }));
      }
    });

    setStage('load Flutter client');
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    setStage('wait for Flutter assets and semantics placeholder');
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    setStage('wait for sodium initialization');
    await page.evaluate(async () => { await window.sodium.ready; });
    setStage('activate Flutter semantics');
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    setStage('wait for accessible Flutter controls');
    await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
    setStage('configure server endpoint');
    await fill(page, 'Server URL', baseUrl);
    setStage('connect server endpoint');
    await click(page, 'Connect securely');
    setStage('wait for owner registration form');
    await field(page, 'Owner email');

    setStage('owner account registration');
    setStage('owner registration field: email');
    await fill(page, 'Owner email', username);
    setStage('owner registration field: master password');
    await fill(page, 'Master password · 12+ characters', oldPassword);
    setStage('owner registration field: password confirmation');
    await fill(page, 'Confirm master password', oldPassword);
    setStage('owner registration field: bootstrap token');
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    setStage('owner registration field: device name');
    await fill(page, 'Device name', 'Password rotation browser');
    setStage('owner registration field: first Vault');
    await fill(page, 'First Vault', 'Password rotation test');
    const registerStart = apiEvents.length;
    setStage('owner registration submit');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 30000 });
    const registerEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'register' && event.sequence >= registerStart,
    );
    assertThat(registerEvent.status >= 200 && registerEvent.status < 300, 'owner registration was rejected');
    const registration = await registerEvent.payloadPromise;
    assertThat(typeof registration?.accountId === 'string' &&
      typeof registration?.deviceId === 'string', 'owner identity was not returned after registration');
    registeredAccountId = registration.accountId;
    registeredDeviceId = registration.deviceId;
    reportStatus('registration', registerEvent.status);

    setStage('open password settings');
    await click(page, 'Settings');
    setStage('wait for current password field');
    await field(page, 'Current master password');
    setStage('password settings field: current password');
    await fill(page, 'Current master password', oldPassword);
    setStage('password settings field: new password');
    await fill(page, 'New master password', newPassword);
    setStage('password settings field: confirmation');
    await fill(page, 'Confirm new master password', newPassword);

    setStage('password change submission');
    const changeStart = apiEvents.length;
    await click(page, 'Change master password');
    setStage('wait for password change response');
    const changeEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'password-change' && event.sequence >= changeStart,
    );
    assertThat(changeEvent.status === 200 && changeEvent.hasBearer, 'password change did not use the active session');
    reportStatus('password_change', changeEvent.status);

    const profileEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'profile' && event.sequence > changeEvent.sequence,
    );
    assertThat(profileEvent.status === 200 && profileEvent.hasBearer, 'the current session did not survive password change');
    reportBoolean('current_session_survived', true);

    setStage('lock current session');
    await click(page, 'Lock and sign out');
    await field(page, 'Email or username');

    setStage('old password rejection: username input');
    await fill(page, 'Email or username', username);
    setStage('old password rejection: password input');
    await fill(page, 'Master password', oldPassword);
    const oldLoginStart = apiEvents.length;
    setStage('old password rejection: prepare response wait');
    const oldLoginResponse = waitForEvent(
      apiEvents,
      (event) => event.route === 'login' && event.sequence >= oldLoginStart,
    );
    const oldUsernameField = await field(page, 'Email or username');
    const oldPasswordField = await field(page, 'Master password');
    const oldLoginButton = await button(page, 'Sign in and unlock');
    const oldLoginButtonEnabled = await oldLoginButton.isEnabled();
    safeLoginControlStates.push({
      phase: 'old_password_rejection',
      usernameMatchesExpected: (await oldUsernameField.inputValue()) === username,
      passwordMatchesExpected: (await oldPasswordField.inputValue()) === oldPassword,
      buttonEnabled: oldLoginButtonEnabled,
    });
    assertThat(oldLoginButtonEnabled, 'sign-in control unavailable');
    setStage('old password rejection: submit');
    await oldLoginButton.click();
    setStage('old password rejection: await response');
    const oldLoginEvent = await oldLoginResponse;
    assertThat(oldLoginEvent.status === 401, 'old password was not rejected');
    reportBoolean('old_password_rejected', true);
    await waitFor(async () => (await button(page, 'Sign in and unlock')).isEnabled());

    setStage('new password login: password input');
    await fill(page, 'Master password', newPassword);
    const newLoginStart = apiEvents.length;
    setStage('new password login: prepare response wait');
    const newLoginResponse = waitForEvent(
      apiEvents,
      (event) => event.route === 'login' && event.sequence >= newLoginStart,
    );
    const newUsernameField = await field(page, 'Email or username');
    const newPasswordField = await field(page, 'Master password');
    const newLoginButton = await button(page, 'Sign in and unlock');
    const newLoginButtonEnabled = await newLoginButton.isEnabled();
    const newPasswordValue = await newPasswordField.inputValue();
    newPasswordFieldLengthMatchesExpected = newPasswordValue.length === newPassword.length;
    safeLoginControlStates.push({
      phase: 'new_password_login',
      usernameMatchesExpected: (await newUsernameField.inputValue()) === username,
      passwordMatchesExpected: newPasswordValue === newPassword,
      buttonEnabled: newLoginButtonEnabled,
    });
    assertThat(newLoginButtonEnabled, 'sign-in control unavailable');
    setStage('new password login: submit');
    await newLoginButton.click();
    setStage('new password login: await response');
    const newLoginEvent = await newLoginResponse;
    assertThat(newLoginEvent.status >= 200 && newLoginEvent.status < 300, 'new password login failed');
    reportStatus('new_password_login', newLoginEvent.status);
    await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 30000 });
    reportBoolean('workspace_unlocked_with_new_password', true);

    setStage('open account audit after new password sign-in');
    const auditStart = apiEvents.length;
    await click(page, 'Audit log');
    const auditEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= auditStart,
    );
    assertThat(auditEvent.status === 200 && auditEvent.hasBearer,
      'account audit request did not use the authenticated session');
    const auditPage = await auditEvent.payloadPromise;
    assertThat(!auditPage.hasMore, 'password-change audit event was not on the complete first page');
    const passwordChangedEvents = auditPage.events.filter(
      (event) => event.action === 'auth.password_changed',
    );
    assertThat(passwordChangedEvents.length === 1,
      'account audit did not return exactly one successful password-change event');
    const passwordChanged = passwordChangedEvents[0];
    assertThat(passwordChanged.scope === 'account' &&
      passwordChanged.vaultId === null &&
      passwordChanged.actorUserId === registeredAccountId &&
      passwordChanged.actorDeviceId === registeredDeviceId &&
      passwordChanged.resourceType === 'account' &&
      passwordChanged.resourceId === registeredAccountId &&
      passwordChanged.result === 'success' &&
      passwordChanged.source === 'api',
    'password-change audit event actor, resource, or result did not match the registered account');
    const allowedAuditFields = [
      'action', 'actor_device_id', 'actor_user_id', 'event_id', 'occurred_at',
      'resource_id', 'resource_type', 'result', 'scope', 'source', 'vault_id',
    ];
    assertThat(passwordChanged.fieldNames.join(',') === allowedAuditFields.join(','),
      'password-change audit event contained unexpected fields');
    reportStatus('authenticated_account_audit', auditEvent.status);
    reportBoolean('password_change_audit_actor_resource_result_verified', true);
    reportBoolean('password_change_audit_secret_fields_absent', true);

    setStage('verify password-change audit UI label');
    await page.getByText('账户', { exact: true }).click();
    await page.mouse.move(900, 800);
    await page.mouse.wheel(0, 10000);
    await waitFor(async () => await visibleFlutterSemanticsCount(page, '主密码已更改') > 0);
    const passwordChangedLabelCount = await visibleFlutterSemanticsCount(page, '主密码已更改');
    assertThat(passwordChangedLabelCount > 0,
      'account audit UI did not show the password-change event label');
    reportBoolean('password_change_audit_label_visible', true);
    assertThat(pageErrorCount === 0, 'Flutter reported a page runtime error');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

async function waitForEvent(events, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected API response did not arrive');
}

async function visibleFlutterSemanticsCount(page, text) {
  return page.locator('flt-semantics').evaluateAll((nodes, expected) =>
    nodes.filter((node) => {
      const label = `${node.getAttribute('aria-label') || ''} ${node.textContent || ''}`;
      const bounds = node.getBoundingClientRect();
      return label.includes(expected) && bounds.width > 0 && bounds.height > 0 &&
        getComputedStyle(node).visibility !== 'hidden';
    }).length,
  text);
}

function reportStatus(assertion, status) {
  console.log(`assert: ${assertion}_http_status=${status}`);
}

function reportBoolean(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
}

main().catch(async (error) => {
  await Promise.allSettled(pendingLoginCodeReads);
  const rawErrorClass = error?.constructor?.name;
  const safeErrorClass = ['Error', 'TimeoutError', 'AssertionError'].includes(rawErrorClass)
    ? rawErrorClass
    : 'OtherError';
  console.error(`stage: failed (${stage}); error class=${safeErrorClass}; safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  console.error(`safe fill diagnostics=${JSON.stringify(safeFillDiagnostics.slice(-8))}`);
  console.error(`safe login control states=${JSON.stringify(safeLoginControlStates)}`);
  console.error(`safe login error codes=${JSON.stringify(safeLoginErrorCodes)}; new password field length matches expected=${newPasswordFieldLengthMatchesExpected}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
