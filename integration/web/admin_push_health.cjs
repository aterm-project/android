/*
 * WEB-ADMIN-PUSH-HEALTH-01: exercise the admin-only aggregate push snapshot
 * and read-only Settings card in Flutter Web against a disposable instance.
 * Output is restricted to fixed stages, HTTP statuses and booleans.
 */

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
const PUSH_HEALTH_PATH = '/api/v1/admin/push-health';
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let adminContext;
let memberContext;
let bootstrapToken;
let invitationToken;
let adminUsername;
let adminPassword;
let memberUsername;
let memberPassword;
let adminAccessToken;
let memberAccessToken;
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = 0;
const leakSentinels = [];

function assertThat(condition, message) {
  if (!condition) {
    const error = new Error(message);
    error.safeAssertion = message;
    throw error;
  }
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function reportStatus(assertion, status) {
  console.log(`assert: ${assertion}_http_status=${status}`);
}

function reportBoolean(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
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
      // Continue while the disposable loopback server starts.
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
    invitationToken = undefined;
    adminUsername = undefined;
    adminPassword = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    adminAccessToken = undefined;
    memberAccessToken = undefined;
    leakSentinels.length = 0;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      adminContext = undefined;
      if (memberContext) await memberContext.close().catch(() => {});
      memberContext = undefined;
      if (browser) await browser.close().catch(() => {});
      browser = undefined;
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
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
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
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 35 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const error = new Error('expected UI or API state did not appear');
  error.safeAssertion = 'UI or API state wait timed out';
  throw error;
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    const visibleText = nodes.filter((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    }).map((element) => {
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`;
    }).join('\n');
    return visibleText.includes(expected);
  }, needle);
}

async function configurePage(page, baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

function cliToken(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `isolated ${description} failed`);
  const token = (result.stdout || '').trim().split(/\s+/).at(-1);
  result.stdout = '';
  assertThat(typeof token === 'string' && token.length >= 40,
    `isolated ${description} credential is unavailable`);
  leakSentinels.push(token);
  return token;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const pathname = new URL(request.url()).pathname;
    if (pathname !== PUSH_HEALTH_PATH && pathname !== '/api/v1/auth/register') return;
    byRequest.set(request, {
      route: pathname === PUSH_HEALTH_PATH ? 'push_health' : 'register',
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    const event = { ...metadata, status: response.status() };
    if (metadata.route === 'register' || metadata.route === 'push_health') {
      event.payloadPromise = response.body().then((body) => {
        try { return JSON.parse(body.toString('utf8')); } catch (_) { return null; }
      });
    }
    events.push(event);
  });
}

function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function validatePushHealth(value) {
  assertThat(exactKeys(value, ['generated_at', 'delivery_window', 'providers']),
    'push health top-level shape was not exact');
  assertThat(typeof value.generated_at === 'string' &&
      Number.isFinite(Date.parse(value.generated_at)),
    'push health timestamp was invalid');
  assertThat(exactKeys(value.delivery_window, ['days', 'start_date_utc', 'end_date_utc']) &&
      value.delivery_window.days === 7 &&
      /^\d{4}-\d{2}-\d{2}$/.test(value.delivery_window.start_date_utc) &&
      /^\d{4}-\d{2}-\d{2}$/.test(value.delivery_window.end_date_utc) &&
      Date.parse(`${value.delivery_window.end_date_utc}T00:00:00Z`) -
        Date.parse(`${value.delivery_window.start_date_utc}T00:00:00Z`) === 6 * 86400000,
    'push delivery result window was invalid');
  assertThat(Array.isArray(value.providers) && value.providers.length === 2,
    'push health must contain both provider snapshots');
  const expectedProviderKeys = [
    'provider', 'configured', 'registered_endpoints', 'due', 'retry_waiting', 'leased', 'dead_lettered',
    'delivery_results',
  ];
  const names = new Set();
  for (const provider of value.providers) {
    assertThat(exactKeys(provider, expectedProviderKeys),
      'push provider snapshot shape was not exact');
    assertThat(provider.provider === 'apns' || provider.provider === 'fcm_v1',
      'push health contained an unsupported provider');
    assertThat(!names.has(provider.provider), 'push provider snapshot was duplicated');
    names.add(provider.provider);
    assertThat(typeof provider.configured === 'boolean',
      'push provider configuration flag was invalid');
    for (const fieldName of expectedProviderKeys.slice(2, 7)) {
      assertThat(Number.isSafeInteger(provider[fieldName]) && provider[fieldName] >= 0,
        'push provider aggregate count was invalid');
    }
    assertThat(exactKeys(provider.delivery_results, ['accepted', 'invalid_token', 'retryable_failure']) &&
        Object.values(provider.delivery_results).every((count) => Number.isSafeInteger(count) && count >= 0),
      'push delivery outcome counts were invalid');
  }
  assertThat(value.providers[0].provider === 'apns' &&
      value.providers[1].provider === 'fcm_v1',
    'push provider snapshots were not in the documented order');
  const payloadText = JSON.stringify(value).toLowerCase();
  assertThat(!/(user_id|account_id|device_id|endpoint_id|token_hash|token_envelope|token_value|email)/.test(payloadText),
    'push health contained a user or endpoint identifier field');
}

async function directApi(baseUrl, token) {
  const response = await fetch(`${baseUrl}${PUSH_HEALTH_PATH}`, {
    headers: { accept: 'application/json', authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  return { status: response.status, payload };
}

async function createAdmin(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Push health acceptance admin');
  await fill(page, 'First Vault', 'Push health acceptance admin');
  const start = events.length;
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = events.find((event, index) =>
    index >= start && event.route === 'register');
  assertThat(registration && registration.status >= 200 && registration.status < 300,
    'admin registration response was unsuccessful');
  const payload = await registration.payloadPromise;
  assertThat(typeof payload?.access_token === 'string',
    'admin registration did not return an access token');
  adminAccessToken = payload.access_token;
  leakSentinels.push(adminAccessToken);
}

async function createMember(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Push health acceptance member');
  await fill(page, 'First Vault', 'Push health acceptance member');
  const start = events.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = events.find((event, index) =>
    index >= start && event.route === 'register');
  assertThat(registration && registration.status >= 200 && registration.status < 300,
    'member registration response was unsuccessful');
  const payload = await registration.payloadPromise;
  assertThat(typeof payload?.access_token === 'string',
    'member registration did not return an access token');
  memberAccessToken = payload.access_token;
  leakSentinels.push(memberAccessToken);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();
  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-push-health-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const runId = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-push-admin-${runId}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-push-member-${runId}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakSentinels.push(tempRoot, dataDir, databasePath, adminUsername, adminPassword, memberUsername, memberPassword);
    const cleanEnv = Object.fromEntries(
      Object.entries(process.env).filter(([key]) => !key.startsWith('ATERMIUS_')),
    );
    const serverEnv = {
      ...cleanEnv,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };

    setStage('start disposable allowlisted instance');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated Chromium profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const adminPage = await adminContext.newPage();
    const memberPage = await memberContext.newPage();
    adminPage.on('pageerror', () => { pageErrors += 1; });
    memberPage.on('pageerror', () => { pageErrors += 1; });
    const adminEvents = [];
    const memberEvents = [];
    trackApi(adminPage, adminEvents);
    trackApi(memberPage, memberEvents);

    setStage('register allowlisted administrator');
    await createAdmin(adminPage, baseUrl, adminEvents);
    reportBoolean('admin_registration_completed', true);

    setStage('create separately invited non-admin');
    invitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'account invitation');
    await createMember(memberPage, baseUrl, memberEvents);
    reportBoolean('member_registration_completed', true);

    setStage('verify non-admin card and endpoint are denied');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberCardVisible = await hasVisibleSemanticText(memberPage, 'Push provider health');
    assertThat(!memberCardVisible, 'non-admin profile rendered the push health card');
    const memberRead = await directApi(baseUrl, memberAccessToken);
    reportStatus('member_push_health', memberRead.status);
    assertThat(memberRead.status === 403, 'non-admin push health request was not denied');
    reportBoolean('non_admin_card_hidden_and_api_denied', true);

    setStage('verify admin loading error and retry flow');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Push provider health'));
    const loadButton = await button(adminPage, 'Load push health');
    let injectedFailure = false;
    await adminPage.route(`**${PUSH_HEALTH_PATH}`, async (route) => {
      if (!injectedFailure && route.request().method() === 'GET') {
        injectedFailure = true;
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'PUSH_HEALTH_UNAVAILABLE', message: 'Temporary failure.' } }),
        });
      } else {
        await route.continue();
      }
    });
    await loadButton.click();
    await waitFor(() => hasVisibleSemanticText(adminPage, '无法加载推送服务状态'));
    reportBoolean('admin_error_state_rendered', true);
    await adminPage.unroute(`**${PUSH_HEALTH_PATH}`);
    setStage('retry actual push health endpoint');
    await click(adminPage, 'Load push health');
    await waitFor(() => adminEvents.some((event) =>
      event.route === 'push_health' && event.status === 200));
    setStage('render provider snapshot');
    const refreshButton = await button(adminPage, 'Refresh push health');
    await refreshButton.scrollIntoViewIfNeeded();
    await waitFor(() => hasVisibleSemanticText(adminPage, 'APNs'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'FCM HTTP v1'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Accepted by adapter (7 UTC days)'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Invalid token (7 UTC days)'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Retryable failure (7 UTC days)'));
    const successfulRead = adminEvents.find((event) =>
      event.route === 'push_health' && event.status === 200);
    assertThat(successfulRead && successfulRead.method === 'GET' && successfulRead.hasBearer,
      'admin push health request was not an authenticated GET');
    validatePushHealth(await successfulRead.payloadPromise);
    reportStatus('admin_push_health', successfulRead.status);
    reportBoolean('admin_error_retry_and_provider_status_rendered', true);
    setStage('verify best-effort push explanation');
    await adminPage.mouse.wheel(0, -1400);
    const hintVisible = await hasVisibleSemanticText(adminPage, 'best-effort wake-up hint');
    assertThat(hintVisible, 'best-effort wake-up explanation was missing');
    reportBoolean('push_delivery_not_claimed', true);

    setStage('validate aggregate-only response and privacy');
    const directAdmin = await directApi(baseUrl, adminAccessToken);
    reportStatus('admin_direct_push_health', directAdmin.status);
    assertThat(directAdmin.status === 200, 'admin direct push health request failed');
    validatePushHealth(directAdmin.payload);
    assertThat(!JSON.stringify(directAdmin.payload).includes(memberUsername),
      'push health response exposed an account identifier');
    reportBoolean('exact_two_provider_aggregate_shape', true);
    reportBoolean('no_user_or_endpoint_rows', true);
    reportBoolean('browser_page_errors_absent', pageErrors === 0);
    assertThat(pageErrors === 0, 'Flutter Web reported a page error');
  } finally {
    await cleanup();
    reportBoolean('temp_root_removed', !tempRoot || !fs.existsSync(tempRoot));
    reportBoolean('server_process_group_stopped', !serverProcess || !processGroupHasLiveMembers(serverProcess.pid));
    reportBoolean('browser_profiles_closed', !adminContext && !memberContext);
    reportBoolean('cleanup_succeeded', !cleanupFailed);
    if (cleanupFailed) throw new Error('isolated acceptance cleanup failed');
  }
}

main().catch((error) => {
  console.error(`failed stage: ${stage}`);
  console.error(`failure category: ${error.safeAssertion || 'unexpected acceptance failure'}`);
  process.exitCode = 1;
});
