/*
 * WEB-ADMIN-RELAY-GROUPS-01: exercise instance-admin server-managed access
 * groups in the current Flutter Web bundle against a disposable instance.
 * These groups are Relay authorization metadata, separate from encrypted
 * Workspace groups and Vault contents.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const GROUPS_PATH = '/api/v1/admin/relay-groups';
const USER_POLICY_PATH = '/api/v1/admin/relay-policy/users/';
const ADMIN_ACCOUNTS_PATH = '/api/v1/admin/accounts';
const ADMIN_AUDIT_PATH = '/api/v1/admin/audit';
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
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
let adminAccessToken;
let adminAccountId;
let adminDeviceId;
let memberUsername;
let memberPassword;
let memberAccessToken;
let memberAccountId;
let memberDeviceId;
let cleanupPromise;
let cleanupFailed = false;
let runFailed = false;
let serverStopConfirmed = true;
let browserStopConfirmed = true;
let pageErrors = 0;
let localCanvasKitBootstrapCount = 0;
let cspHeader = '';
const leakSentinels = [];
const externalRequestOrigins = [];
const adminEvents = [];
const memberEvents = [];
const apiDiagnostics = [];
const pageErrorDiagnostics = [];

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

function reportStatus(name, status) {
  console.log(`assert: ${name}_http_status=${status}`);
}

function reportBoolean(name, value) {
  console.log(`assert: ${name}=${value}`);
}

function safeFailureSummary(error) {
  let summary = typeof error?.safeAssertion === 'string'
    ? error.safeAssertion
    : typeof error?.message === 'string'
      ? error.message.split(/\r?\n/, 1)[0]
      : '';
  for (const secret of [
    ...leakSentinels,
    bootstrapToken,
    invitationToken,
    adminPassword,
    adminAccessToken,
    memberPassword,
    memberAccessToken,
  ]) {
    if (typeof secret === 'string' && secret.length > 0) {
      summary = summary.replaceAll(secret, '[redacted]');
    }
  }
  return summary
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, '[account]')
    .slice(0, 700);
}

function safeDiagnosticText(value) {
  let safe = String(value ?? '');
  for (const secret of [
    ...leakSentinels,
    bootstrapToken,
    invitationToken,
    adminUsername,
    adminPassword,
    adminAccessToken,
    memberUsername,
    memberPassword,
    memberAccessToken,
  ]) {
    if (typeof secret === 'string' && secret.length > 0) {
      safe = safe.replaceAll(secret, '[redacted]');
    }
  }
  return safe
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, '[account]')
    .replace(/\s+/g, ' ')
    .slice(0, 1000);
}

async function logPageDiagnostics(page, label) {
  const diagnostic = await page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
      .filter((text) => text.trim().length > 0)
      .join(' | ');
    const inputs = [...document.querySelectorAll('input,textarea')].map((element) => ({
      type: element.getAttribute('type'),
      ariaLabel: element.getAttribute('aria-label'),
      placeholder: element.getAttribute('placeholder'),
      title: element.getAttribute('title'),
      role: element.getAttribute('role'),
      visible: visible(element),
      labels: [...(element.labels || [])].map((label) => label.innerText || ''),
    }));
    return { semantics, inputs };
  }).catch(() => 'unavailable');
  console.error(`diagnostic ${label}_url=${new URL(page.url()).pathname}`);
  console.error(`diagnostic ${label}_semantics=${safeDiagnosticText(diagnostic?.semantics ?? diagnostic)}`);
  if (diagnostic && typeof diagnostic === 'object') {
    console.error(`diagnostic ${label}_inputs=${safeDiagnosticText(JSON.stringify(diagnostic.inputs))}`);
  }
  console.error(`diagnostic ${label}_api_responses=${JSON.stringify(apiDiagnostics.slice(-20))}`);
  console.error(`diagnostic ${label}_page_errors=${JSON.stringify(pageErrorDiagnostics.slice(-5))}`);
}

function buildServer() {
  const buildTmpDir = path.join(ROOT, 'server/target/tmp');
  fs.mkdirSync(buildTmpDir, { recursive: true });
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT,
    env: { ...process.env, TMPDIR: buildTmpDir },
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
      // Keep waiting while the disposable server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    invitationToken = undefined;
    adminUsername = undefined;
    adminPassword = undefined;
    adminAccessToken = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    memberAccessToken = undefined;
    try {
      if (adminContext) await adminContext.close().catch(() => { cleanupFailed = true; });
      if (memberContext) await memberContext.close().catch(() => { cleanupFailed = true; });
      if (browser) {
        await browser.close();
        browserStopConfirmed = true;
      }
    } catch (_) {
      browserStopConfirmed = false;
      cleanupFailed = true;
    }
    try {
      await stopServerGroup(serverProcess);
      serverStopConfirmed = !serverProcess || !processGroupHasLiveMembers(serverProcess.pid);
    } catch (_) {
      serverStopConfirmed = false;
      cleanupFailed = true;
    }
    if (tempRoot) {
      if (!serverStopConfirmed || !browserStopConfirmed) {
        cleanupFailed = true;
        console.error('cleanup: preserved fixture data because an owned process may still be live');
      } else {
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

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 30000 });
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
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(150);
    if (await locator.inputValue().catch(() => '') !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue().catch(() => '') === value) return;
  }
  const observedValue = await locator.inputValue().catch(() => null);
  const error = new Error('a visible form field did not retain its input');
  error.safeAssertion = `form field input did not persist; expectedLength=${value.length}; ` +
    `observedNonempty=${Boolean(observedValue)}; visible=${await locator.isVisible().catch(() => false)}; ` +
    `enabled=${await locator.isEnabled().catch(() => false)}`;
  throw error;
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
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

async function scrollUntilVisibleSemanticText(page, needle, maxSteps = 30) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(page, needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(1100, 850);
    await page.mouse.wheel(0, 800);
    await page.waitForTimeout(50);
  }
  throw new Error('expected Settings control did not enter the visible area');
}

async function configurePage(page, baseUrl, events) {
  const expectedOrigin = new URL(baseUrl).origin;
  page.on('request', (request) => {
    try {
      const origin = new URL(request.url()).origin;
      if (origin !== expectedOrigin) externalRequestOrigins.push(origin);
    } catch (_) {}
  });
  await page.route('**/*', async (route) => {
    try {
      const origin = new URL(route.request().url()).origin;
      if (origin !== expectedOrigin) {
        externalRequestOrigins.push(origin);
        await route.abort('blockedbyclient');
        return;
      }
    } catch (_) {}
    await route.continue();
  });
  await page.route('**/flutter_bootstrap.js', async (route) => {
    const response = await route.fetch();
    const source = await response.text();
    let localized = source;
    if (!source.includes('"useLocalCanvasKit":true')) {
      localized = source.replace(
        /_flutter\.buildConfig\s*=\s*\{/,
        (match) => `${match}"useLocalCanvasKit":true,`,
      );
    }
    assertThat(localized !== source || source.includes('"useLocalCanvasKit":true'),
      'current Flutter bundle did not expose local CanvasKit assets');
    localCanvasKitBootstrapCount += 1;
    await route.fulfill({ response, body: localized });
  });
  page.on('response', (response) => {
    try {
      const url = new URL(response.url());
      if (url.origin === expectedOrigin && url.pathname.startsWith('/api/v1/')) {
        apiDiagnostics.push({
          method: response.request().method(),
          path: url.pathname,
          status: response.status(),
        });
      }
      if (url.origin === expectedOrigin && url.pathname === '/') {
        cspHeader ||= response.headers()['content-security-policy'] || '';
      }
    } catch (_) {}
  });
  page.on('pageerror', (error) => {
    pageErrors += 1;
    pageErrorDiagnostics.push(safeDiagnosticText(error?.message || error));
  });
  trackApi(page, events);
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  const csp = await page.locator('meta[http-equiv="Content-Security-Policy"]')
    .getAttribute('content').catch(() => null);
  assertThat(typeof csp === 'string' && csp.includes("script-src 'self'") &&
    !csp.includes('www.gstatic.com'),
  'test-only CanvasKit routing changed the strict page CSP');
  setStage('wait for Flutter Web readiness');
  const ready = await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000)
    .then(() => true).catch(() => false);
  if (!ready) {
    const diagnostic = await page.evaluate(() => ({
      sodiumObject: typeof window.sodium,
      sodiumReady: typeof window.sodium?.ready,
      semanticsPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      semanticsNodes: document.querySelectorAll('flt-semantics').length,
      canvasCount: document.querySelectorAll('canvas').length,
      flutterView: Boolean(document.querySelector('flutter-view')),
      title: document.title,
    }));
    throw new Error(`Flutter Web did not become ready (${JSON.stringify(diagnostic)})`);
  }
  setStage('wait for client cryptography');
  await page.evaluate(async () => { await window.sodium.ready; });
  setStage('enable Flutter Web semantics');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  setStage('wait for accessible server configuration controls');
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  setStage('set disposable server address');
  await fill(page, 'Server URL', baseUrl);
  setStage('connect client to disposable server');
  await click(page, 'Connect securely');
}

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === GROUPS_PATH || pathname.startsWith(`${GROUPS_PATH}/`)) return 'relay-groups';
    if (pathname.startsWith(USER_POLICY_PATH)) return 'relay-user-policy';
    if (pathname === ADMIN_ACCOUNTS_PATH) return 'admin-accounts';
    if (pathname === ADMIN_AUDIT_PATH) return 'admin-audit';
  } catch (_) {}
  return null;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    let body = null;
    if (['POST', 'PUT', 'DELETE'].includes(request.method())) {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    byRequest.set(request, {
      route,
      pathname: new URL(request.url()).pathname,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      body,
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    events.push({
      ...metadata,
      status: response.status(),
      sequence: events.length,
      payloadPromise: response.json().catch(() => null),
    });
  });
}

async function waitForEvent(events, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected authenticated API response did not arrive');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const secret of leakSentinels) {
    if (secret && secret.length >= 8) {
      assertThat(!serialized.includes(secret), 'a response or rendered view exposed a credential or private path');
    }
  }
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'a response exposed the fixture data path');
  assertThat(!/(?:SQLite|sqlx|tokio::|panic at|stack trace|backtrace|no such table)/i.test(serialized),
    'a response exposed internal server details');
}

async function directApi(baseUrl, method, pathname, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertNoLeaks(payload);
  return { status: response.status, payload };
}

function validateDetail(payload, expectedId) {
  assertThat(exactKeys(payload, ['group', 'members', 'policy']),
    'group detail response fields changed');
  assertThat(exactKeys(payload.group, [
    'group_id', 'name', 'revision', 'created_at', 'updated_at',
  ]) && UUID_PATTERN.test(payload.group.group_id) &&
    payload.group.group_id === expectedId && typeof payload.group.name === 'string' &&
    Number.isSafeInteger(payload.group.revision) && payload.group.revision >= 1,
  'group identity DTO was invalid');
  assertThat(exactKeys(payload.members, ['revision', 'items']) &&
    Number.isSafeInteger(payload.members.revision) && payload.members.revision >= 0 &&
    Array.isArray(payload.members.items) && payload.members.items.every((member) =>
      exactKeys(member, ['user_id', 'username']) && UUID_PATTERN.test(member.user_id) &&
      typeof member.username === 'string'),
  'group membership DTO was invalid');
  assertThat(exactKeys(payload.policy, [
    'inherited', 'revision', 'updated_at', 'instance_policy_revision',
    'policy', 'effective_policy',
  ]) && typeof payload.policy.inherited === 'boolean' &&
    Number.isSafeInteger(payload.policy.revision) && payload.policy.revision >= 0 &&
    Number.isSafeInteger(payload.policy.instance_policy_revision) &&
    exactKeys(payload.policy.policy, ['enabled', 'allow_cidrs', 'allow_ports']) &&
    exactKeys(payload.policy.effective_policy, ['enabled', 'allow_cidrs', 'allow_ports']),
  'group Relay policy DTO was invalid');
  assertNoLeaks(payload);
  return payload;
}

function validateGroupList(payload) {
  assertThat(exactKeys(payload, ['groups']) && Array.isArray(payload.groups),
    'server-managed group list DTO was invalid');
  for (const group of payload.groups) {
    assertThat(exactKeys(group, [
      'group_id', 'name', 'revision', 'membership_revision', 'policy_revision',
      'member_count', 'policy_inherited', 'updated_at',
    ]) && UUID_PATTERN.test(group.group_id) && typeof group.name === 'string' &&
      Number.isSafeInteger(group.revision) && Number.isSafeInteger(group.membership_revision) &&
      Number.isSafeInteger(group.policy_revision) && Number.isSafeInteger(group.member_count) &&
      typeof group.policy_inherited === 'boolean',
    'server-managed group list entry was invalid');
  }
  assertNoLeaks(payload);
  return payload.groups;
}

async function chooseDropdownOption(page, fieldLabel, optionLabel) {
  const opened = await page.evaluate((label) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const candidates = [...document.querySelectorAll('flt-semantics')].filter((element) =>
      visible(element) && ['button', 'combobox', 'textbox'].includes(element.getAttribute('role')) &&
      `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
        .toLowerCase().includes(label.toLowerCase()));
    const target = candidates.at(-1);
    if (!target) return false;
    target.click();
    return true;
  }, fieldLabel).catch(() => false);
  if (!opened) {
    const control = page.getByRole('combobox', { name: new RegExp(fieldLabel, 'i') }).last();
    await control.waitFor({ state: 'visible', timeout: 10000 });
    await control.click();
  }
  await waitFor(async () => page.evaluate((expected) =>
    [...document.querySelectorAll('flt-semantics[role="option"], flt-semantics[role="menuitem"]')]
      .some((element) => {
        const rect = element.getBoundingClientRect();
        const value = `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`;
        return rect.width > 0 && rect.height > 0 && value.includes(expected);
      }), optionLabel), 10000);
  const clicked = await page.evaluate((expected) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const candidates = [...document.querySelectorAll(
      'flt-semantics[role="option"], flt-semantics[role="menuitem"]',
    )].filter((element) => visible(element) &&
      `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
        .includes(expected));
    const target = candidates.at(-1);
    if (!target) return false;
    target.click();
    return true;
  }, optionLabel).catch(() => false);
  if (!clicked) {
    const option = page.getByText(optionLabel, { exact: true }).last();
    await option.waitFor({ state: 'visible', timeout: 10000 });
    await option.click();
  }
}

async function createAdminProfile(page, baseUrl, events) {
  setStage('configure administrator registration page');
  await configurePage(page, baseUrl, events);
  const fillRegistrationField = async (label, value) => {
    setStage(`fill administrator ${label}`);
    try {
      await fill(page, label, value);
    } catch (error) {
      await logPageDiagnostics(page, `administrator_field_${label.toLowerCase().replace(/[^a-z]+/g, '_')}`);
      throw error;
    }
  };
  await fillRegistrationField('Owner email', adminUsername);
  await fillRegistrationField('Master password · 12+ characters', adminPassword);
  await fillRegistrationField('Confirm master password', adminPassword);
  await fillRegistrationField('One-time bootstrap token', bootstrapToken);
  await fillRegistrationField('Device name', 'Relay groups acceptance admin');
  await fillRegistrationField('First Vault', 'Relay groups acceptance admin');
  const start = events.length;
  setStage('locate administrator registration button');
  let submit;
  try {
    submit = await button(page, 'Create owner account');
  } catch (error) {
    await logPageDiagnostics(page, 'administrator_registration_form');
    throw error;
  }
  setStage('submit administrator registration');
  await submit.click();
  bootstrapToken = undefined;
  setStage('wait for administrator registration response');
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  reportStatus('administrator_registration', registration.status);
  if (typeof payload?.code === 'string') {
    console.log(`diagnostic administrator_registration_code=${payload.code}`);
  }
  assertThat(registration.status >= 200 && registration.status < 300 &&
    typeof payload?.access_token === 'string' && UUID_PATTERN.test(payload.account_id) &&
    UUID_PATTERN.test(payload.device_id),
  `administrator registration failed with ${registration.status} ${payload?.code || ''}`.trim());
  try {
    setStage('wait for administrator landing page');
    await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  } catch (error) {
    await logPageDiagnostics(page, 'administrator_landing');
    throw error;
  }
  adminAccessToken = payload.access_token;
  adminAccountId = payload.account_id;
  adminDeviceId = payload.device_id;
  leakSentinels.push(adminPassword, payload.access_token, payload.refresh_token);
}

async function createMemberProfile(page, baseUrl, events) {
  await configurePage(page, baseUrl, events);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Relay groups acceptance member');
  await fill(page, 'First Vault', 'Relay groups acceptance member');
  const start = events.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
    typeof payload?.access_token === 'string' && UUID_PATTERN.test(payload.account_id) &&
    UUID_PATTERN.test(payload.device_id), 'invited member registration failed');
  memberAccessToken = payload.access_token;
  memberAccountId = payload.account_id;
  memberDeviceId = payload.device_id;
  leakSentinels.push(memberPassword, payload.access_token, payload.refresh_token);
}

async function openGroups(page, events) {
  await click(page, 'Settings');
  await scrollUntilVisibleSemanticText(page, 'Server-managed access groups');
  const start = events.length;
  const load = page.getByRole('button', { name: /Load server-managed groups|Refresh server-managed groups/ }).first();
  await load.click();
  const response = await waitForEvent(events,
    (event) => event.route === 'relay-groups' && event.method === 'GET' &&
      event.pathname === GROUPS_PATH && event.sequence >= start);
  assertThat(response.hasBearer && response.status === 200,
    'administrator could not load server-managed groups');
  const payload = await response.payloadPromise;
  return validateGroupList(payload);
}

async function createGroupFromSettings(page, events, name) {
  await fill(page, 'New server group name', name);
  const start = events.length;
  await click(page, 'Create group');
  const createdEvent = await waitForEvent(events,
    (event) => event.route === 'relay-groups' && event.method === 'POST' &&
      event.pathname === GROUPS_PATH && event.sequence >= start);
  assertThat(createdEvent.hasBearer && createdEvent.status === 201,
    'server-managed group create was not an authenticated 201');
  const createdPayloadValue = await createdEvent.payloadPromise;
  const createdPayload = validateDetail(createdPayloadValue,
    createdPayloadValue?.group?.group_id);
  await waitFor(() => hasVisibleSemanticText(page, 'Selected server-managed group'));
  return createdPayload;
}

async function addMemberFromUi(page, events, username) {
  if (await hasVisibleSemanticText(page, 'Load accounts to add members')) {
    const startAccounts = events.length;
    await click(page, 'Load accounts to add members');
    const accounts = await waitForEvent(events,
      (event) => event.route === 'admin-accounts' && event.method === 'GET' &&
        event.sequence >= startAccounts);
    assertThat(accounts.hasBearer && accounts.status === 200,
      'group member picker could not load account metadata');
  }
  await chooseDropdownOption(page, 'Active account on current page', username);
  await click(page, 'Add');
  const start = events.length;
  await click(page, 'Save membership');
  const result = await waitForEvent(events,
    (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
      event.pathname.endsWith('/members') && event.sequence >= start);
  assertThat(result.hasBearer && result.status === 200,
    'administrator group membership save failed');
  return result;
}

async function saveGroupPolicyFromUi(page, events, cidrs, ports) {
  await fill(page, 'Allowed CIDR networks', cidrs);
  await fill(page, 'Allowed ports', ports);
  const start = events.length;
  await click(page, 'Save group override');
  return waitForEvent(events,
    (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
      event.pathname.endsWith('/relay-policy') && event.sequence >= start);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web bundle is incomplete');
  }
  setStage('build isolated service binary');
  buildServer();
  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-relay-groups-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const suffix = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-relay-groups-admin-${suffix}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-relay-groups-member-${suffix}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakSentinels.push(adminPassword, memberPassword, tempRoot, databasePath);
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
      ATERMIUS_RELAY_ENABLED: 'true',
      ATERMIUS_RELAY_ALLOW_CIDRS: '10.0.0.0/8',
      ATERMIUS_RELAY_ALLOW_PORTS: '22,2222',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };
    setStage('start isolated instance with constrained Relay deployment policy');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    serverStopConfirmed = false;
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated Chromium administrator and member profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const adminPage = await adminContext.newPage();
    const memberPage = await memberContext.newPage();
    setStage('register allowlisted administrator');
    await createAdminProfile(adminPage, baseUrl, adminEvents);
    invitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername],
      serverEnv,
      'member invitation',
    );
    setStage('register invited non-admin member');
    await createMemberProfile(memberPage, baseUrl, memberEvents);
    assertThat(memberAccountId !== adminAccountId,
      'administrator and member unexpectedly share an identity');
    reportBoolean('two_distinct_browser_profiles_registered', true);

    setStage('verify non-admin UI and API gates');
    await click(memberPage, 'Settings');
    await scrollUntilVisibleSemanticText(memberPage, 'Workspace settings');
    assertThat(!await hasVisibleSemanticText(memberPage, 'Server-managed access groups'),
      'non-admin Settings exposed the server-managed group controls');
    const unauthenticated = await directApi(baseUrl, 'GET', GROUPS_PATH);
    reportStatus('unauthenticated_group_list', unauthenticated.status);
    assertThat(unauthenticated.status === 401, 'unauthenticated group listing was not denied');
    const memberRead = await directApi(baseUrl, 'GET', GROUPS_PATH, { token: memberAccessToken });
    reportStatus('member_group_list', memberRead.status);
    assertThat(memberRead.status === 403 && memberRead.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin group API read was not denied');
    const memberCreate = await directApi(baseUrl, 'POST', GROUPS_PATH, {
      token: memberAccessToken,
      body: { name: 'member-forbidden-group' },
    });
    reportStatus('member_group_create', memberCreate.status);
    assertThat(memberCreate.status === 403 && memberCreate.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin group API mutation was not denied');
    reportBoolean('member_controls_hidden_and_api_denied', true);

    setStage('load empty server-managed group list from administrator Settings');
    const initialGroups = await openGroups(adminPage, adminEvents);
    assertThat(initialGroups.length === 0 &&
      await hasVisibleSemanticText(adminPage, 'No server-managed groups yet.'),
    'new instance did not render the empty server-managed group state');
    reportBoolean('separate_empty_server_group_state_visible', true);

    setStage('create a Unicode group and verify normalized duplicate rejection');
    const firstGroup = await createGroupFromSettings(adminPage, adminEvents, 'Ａ组');
    const firstGroupId = firstGroup.group.group_id;
    assertThat(firstGroup.group.name === 'A组',
      'server did not return the NFKC-normalized Unicode group name');
    reportStatus('unicode_group_create', 201);
    const duplicate = await directApi(baseUrl, 'POST', GROUPS_PATH, {
      token: adminAccessToken,
      body: { name: 'a组' },
    });
    reportStatus('normalized_duplicate_group_create', duplicate.status);
    assertThat(duplicate.status === 409 &&
      duplicate.payload?.error?.code === 'RELAY_GROUP_NAME_TAKEN',
    'case-folded NFKC-equivalent group name was not rejected');
    reportBoolean('unicode_normalized_duplicate_rejected', true);

    setStage('rename the group to a Chinese name through Web Settings');
    await fill(adminPage, 'Group name', '运维团队');
    let mutationStart = adminEvents.length;
    await click(adminPage, 'Rename');
    let renameEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
        event.pathname === `${GROUPS_PATH}/${firstGroupId}` && event.sequence >= mutationStart);
    assertThat(renameEvent.hasBearer && renameEvent.status === 200 &&
      renameEvent.body?.expected_revision === firstGroup.group.revision &&
      renameEvent.body?.name === '运维团队', 'Chinese group rename did not use revision CAS');
    const renamedGroup = validateDetail(await renameEvent.payloadPromise, firstGroupId);
    assertThat(renamedGroup.group.name === '运维团队', 'Chinese group name was not persisted');
    reportBoolean('chinese_group_rename_via_web_ui', true);

    setStage('add the invited member through the Web member picker');
    const firstMembershipEvent = await addMemberFromUi(adminPage, adminEvents, memberUsername);
    assertThat(firstMembershipEvent.body?.expected_revision === firstGroup.members.revision &&
      Array.isArray(firstMembershipEvent.body?.user_ids) &&
      firstMembershipEvent.body.user_ids.length === 1 &&
      firstMembershipEvent.body.user_ids[0] === memberAccountId,
    'Web member picker did not submit the complete member set at its revision');
    reportBoolean('web_member_picker_submits_full_revisioned_set', true);

    setStage('set the first group Relay override from Settings');
    const firstPolicyEvent = await saveGroupPolicyFromUi(
      adminPage, adminEvents, '10.1.0.0/16', '22, 2222',
    );
    reportStatus('first_group_policy_override', firstPolicyEvent.status);
    assertThat(firstPolicyEvent.hasBearer && firstPolicyEvent.status === 200 &&
      firstPolicyEvent.body?.expected_revision === firstGroup.policy.revision &&
      firstPolicyEvent.body?.expected_instance_policy_revision ===
        firstGroup.policy.instance_policy_revision,
    `first group Relay override did not submit both current CAS revisions ` +
      `(group=${firstPolicyEvent.body?.expected_revision}, instance=${firstPolicyEvent.body?.expected_instance_policy_revision})`);
    const firstPolicyDetail = validateDetail(await firstPolicyEvent.payloadPromise, firstGroupId);
    assertThat(firstPolicyDetail.policy.inherited === false &&
      firstPolicyDetail.policy.effective_policy.allow_cidrs.includes('10.1.0.0/16'),
    'first group override/effective state did not match');

    setStage('create a second group and apply a narrower overlapping policy');
    const secondGroup = await createGroupFromSettings(adminPage, adminEvents, '网络组');
    const secondGroupId = secondGroup.group.group_id;
    const secondMembershipEvent = await addMemberFromUi(adminPage, adminEvents, memberUsername);
    assertThat(secondMembershipEvent.body?.user_ids?.includes(memberAccountId),
      'second server group did not include the invited member');
    const secondPolicyEvent = await saveGroupPolicyFromUi(
      adminPage, adminEvents, '10.1.2.0/24', '2222',
    );
    assertThat(secondPolicyEvent.status === 200 &&
      secondPolicyEvent.body?.expected_revision === secondGroup.policy.revision &&
      secondPolicyEvent.body?.expected_instance_policy_revision ===
        secondGroup.policy.instance_policy_revision,
    'second group Relay override did not submit expected CAS revisions');
    const secondPolicyDetail = validateDetail(await secondPolicyEvent.payloadPromise, secondGroupId);
    assertThat(secondPolicyDetail.policy.effective_policy.allow_cidrs.includes('10.1.2.0/24') &&
      secondPolicyDetail.policy.effective_policy.allow_ports.length === 1 &&
      secondPolicyDetail.policy.effective_policy.allow_ports[0] === 2222,
    'second group did not expose its narrower effective group policy');

    setStage('show the selected member effective policy across both groups');
    await scrollUntilVisibleSemanticText(adminPage, 'Preview member effective Relay access', 50);
    try {
      await chooseDropdownOption(adminPage, 'Preview member effective Relay access', memberUsername);
    } catch (error) {
      await logPageDiagnostics(adminPage, 'member_effective_preview_picker');
      throw error;
    }
    const memberEffectiveResponse = await directApi(
      baseUrl, 'GET', `${USER_POLICY_PATH}${memberAccountId}`, { token: adminAccessToken },
    );
    await waitFor(() => hasVisibleSemanticText(
      adminPage, 'Member effective Relay access:',
    ));
    const memberEffectivePolicy = memberEffectiveResponse.payload?.effective_policy;
    assertThat(memberEffectiveResponse.status === 200 &&
      memberEffectivePolicy?.enabled === true &&
      JSON.stringify(memberEffectivePolicy?.allow_cidrs) === JSON.stringify(['10.1.2.0/24']) &&
      JSON.stringify(memberEffectivePolicy?.allow_ports) === JSON.stringify([2222]),
    'server effective member policy was not the expected two-group intersection');
    assertThat(await hasVisibleSemanticText(
      adminPage, 'Member effective Relay access: enabled',
    ) && await hasVisibleSemanticText(adminPage, '10.1.2.0/24') &&
      await hasVisibleSemanticText(adminPage, 'ports: 2222'),
      'member effective preview did not show the intersection of both assigned groups');
    reportBoolean('member_effective_preview_reflects_two_group_intersection', true);

    setStage('create a policy CAS conflict and preserve Web draft');
    const beforePolicyConflict = validateDetail(
      (await directApi(baseUrl, 'GET', `${GROUPS_PATH}/${secondGroupId}`, {
        token: adminAccessToken,
      })).payload,
      secondGroupId,
    );
    const externalPolicy = await directApi(baseUrl, 'PUT',
      `${GROUPS_PATH}/${secondGroupId}/relay-policy`, {
        token: adminAccessToken,
        body: {
          expected_revision: beforePolicyConflict.policy.revision,
          expected_instance_policy_revision: beforePolicyConflict.policy.instance_policy_revision,
          enabled: true,
          allow_cidrs: ['10.1.3.0/24'],
          allow_ports: [2222],
        },
      });
    assertThat(externalPolicy.status === 200, 'concurrent group policy update fixture failed');
    await fill(adminPage, 'Allowed CIDR networks', '10.1.2.0/24');
    await fill(adminPage, 'Allowed ports', '2222');
    mutationStart = adminEvents.length;
    await click(adminPage, 'Save group override');
    const stalePolicyEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
        event.pathname.endsWith('/relay-policy') && event.sequence >= mutationStart);
    assertThat(stalePolicyEvent.hasBearer && stalePolicyEvent.status === 409,
      'stale group policy write was not rejected with CAS conflict');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Reload latest group, keep drafts'));
    assertThat(await (await field(adminPage, 'Allowed CIDR networks')).inputValue() === '10.1.2.0/24',
      'stale policy draft was not retained');
    await click(adminPage, 'Reload latest group, keep drafts');
    await waitFor(() => hasVisibleSemanticText(
      adminPage, `policy revision ${externalPolicy.payload.policy.revision}`,
    ));
    assertThat(await (await field(adminPage, 'Allowed CIDR networks')).inputValue() === '10.1.2.0/24',
      'policy reload replaced the stale draft');
    mutationStart = adminEvents.length;
    await click(adminPage, 'Save group override');
    const policyRetry = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
        event.pathname.endsWith('/relay-policy') && event.sequence >= mutationStart &&
        event.status === 200);
    assertThat(policyRetry.body?.expected_revision === externalPolicy.payload.policy.revision &&
      policyRetry.body?.expected_instance_policy_revision ===
        externalPolicy.payload.policy.instance_policy_revision,
      'policy retry did not use the reloaded revision');
    const policyRetryDetail = validateDetail(await policyRetry.payloadPromise, secondGroupId);
    reportBoolean('group_policy_cas_conflict_kept_draft_and_retried', true);

    setStage('create a membership CAS conflict and preserve Web draft');
    const staleMembers = validateDetail(
      (await directApi(baseUrl, 'GET', `${GROUPS_PATH}/${secondGroupId}`, {
        token: adminAccessToken,
      })).payload,
      secondGroupId,
    );
    const memberRemoveButton = adminPage.getByRole('button', {
      name: `Remove ${memberUsername} from group draft`, exact: true,
    }).last();
    await memberRemoveButton.click();
    const concurrentMembership = await directApi(baseUrl, 'PUT',
      `${GROUPS_PATH}/${secondGroupId}/members`, {
        token: adminAccessToken,
        body: {
          expected_revision: staleMembers.members.revision,
          user_ids: [memberAccountId, adminAccountId].sort(),
        },
      });
    assertThat(concurrentMembership.status === 200,
      'concurrent membership update fixture failed');
    mutationStart = adminEvents.length;
    await click(adminPage, 'Save membership');
    const staleMembershipEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
        event.pathname.endsWith('/members') && event.sequence >= mutationStart);
    assertThat(staleMembershipEvent.status === 409,
      'stale membership write was not rejected with CAS conflict');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Reload latest group, keep drafts'));
    assertThat(await hasVisibleSemanticText(adminPage,
      `Restore ${memberUsername} in group draft`),
    'membership draft did not remain removed after conflict');
    await click(adminPage, 'Reload latest group, keep drafts');
    await waitFor(() => hasVisibleSemanticText(
      adminPage, `membership revision ${concurrentMembership.payload.members.revision}`,
    ));
    assertThat(await hasVisibleSemanticText(adminPage,
      `Restore ${memberUsername} in group draft`),
    'membership reload replaced the stale member draft');
    await chooseDropdownOption(adminPage, 'Active account on current page', memberUsername);
    await click(adminPage, 'Add');
    mutationStart = adminEvents.length;
    await click(adminPage, 'Save membership');
    const membershipRetry = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'PUT' &&
        event.pathname.endsWith('/members') && event.sequence >= mutationStart &&
        event.status === 200);
    assertThat(membershipRetry.body?.expected_revision === concurrentMembership.payload.members.revision &&
      membershipRetry.body?.user_ids?.length === 1 &&
      membershipRetry.body?.user_ids?.[0] === memberAccountId,
    'membership retry did not use the latest revision and preserved full draft');
    reportBoolean('group_membership_cas_conflict_kept_draft_and_retried', true);

    setStage('verify effective access expands when one group inherits policy');
    mutationStart = adminEvents.length;
    await click(adminPage, 'Reset to inherit');
    const resetEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'DELETE' &&
        event.pathname.endsWith('/relay-policy') && event.sequence >= mutationStart);
    assertThat(resetEvent.status === 200, 'group policy reset failed');
    const resetDetail = validateDetail(await resetEvent.payloadPromise, secondGroupId);
    assertThat(resetDetail.policy.inherited === true &&
      resetDetail.policy.revision === policyRetryDetail.policy.revision + 1,
      'policy reset did not retain the group policy revision watermark');
    await scrollUntilVisibleSemanticText(adminPage, 'Preview member effective Relay access', 50);
    await chooseDropdownOption(adminPage, 'Preview member effective Relay access', memberUsername);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Member effective Relay access: enabled'));
    assertThat(await hasVisibleSemanticText(adminPage, '10.1.0.0/16'),
      'member effective access did not widen to the remaining group after inheritance reset');
    reportBoolean('policy_reset_recomputed_cross_group_effective_state', true);

    setStage('restore narrow group policy then delete with three revision CAS');
    await saveGroupPolicyFromUi(adminPage, adminEvents, '10.1.2.0/24', '2222');
    const preDelete = validateDetail(
      (await directApi(baseUrl, 'GET', `${GROUPS_PATH}/${secondGroupId}`, {
        token: adminAccessToken,
      })).payload,
      secondGroupId,
    );
    const deleteButton = adminPage.getByRole('button', {
      name: 'Delete server-managed group', exact: true,
    }).last();
    await deleteButton.click();
    mutationStart = adminEvents.length;
    await click(adminPage, 'Delete group');
    const deleteEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-groups' && event.method === 'DELETE' &&
        event.pathname === `${GROUPS_PATH}/${secondGroupId}` && event.sequence >= mutationStart);
    assertThat(deleteEvent.hasBearer && deleteEvent.status === 204 &&
      deleteEvent.body?.expected_revision === preDelete.group.revision &&
      deleteEvent.body?.expected_membership_revision === preDelete.members.revision &&
      deleteEvent.body?.expected_policy_revision === preDelete.policy.revision,
    'group deletion did not include all three current revisions');
    reportStatus('group_delete', deleteEvent.status);
    const groupsAfterDelete = await directApi(baseUrl, 'GET', GROUPS_PATH, {
      token: adminAccessToken,
    });
    assertThat(groupsAfterDelete.status === 200 &&
      !groupsAfterDelete.payload.groups.some((group) => group.group_id === secondGroupId),
    'authoritative server group list retained the deleted group');
    await waitFor(async () => !(await hasVisibleSemanticText(adminPage, '网络组')));
    reportBoolean('group_deletion_cas_removed_group_and_revoked_group_scope', true);

    setStage('verify the remaining group supplies the member Relay policy');
    await adminPage.getByRole('button', { name: /运维团队/ }).last().click();
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Selected server-managed group'));
    await scrollUntilVisibleSemanticText(adminPage, 'Preview member effective Relay access', 50);
    await chooseDropdownOption(adminPage, 'Preview member effective Relay access', memberUsername);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Member effective Relay access: enabled'));
    assertThat(await hasVisibleSemanticText(adminPage, '10.1.0.0/16') &&
      !await hasVisibleSemanticText(adminPage, '10.1.2.0/24'),
      'deleting a group did not remove its restriction from member effective access');
    const afterDeletePolicy = await directApi(baseUrl, 'GET', `${USER_POLICY_PATH}${memberAccountId}`, {
      token: adminAccessToken,
    });
    assertThat(afterDeletePolicy.status === 200 &&
      afterDeletePolicy.payload?.effective_policy?.allow_cidrs?.includes('10.1.0.0/16') &&
      !afterDeletePolicy.payload?.effective_policy?.allow_cidrs?.includes('10.1.2.0/24'),
    'server effective policy did not revoke deleted group restriction');
    reportBoolean('deleted_group_removed_from_authoritative_member_policy', true);

    setStage('validate anonymous audit resources and fixed localized action labels');
    const auditResponse = await directApi(baseUrl, 'GET', `${ADMIN_AUDIT_PATH}?limit=200`, {
      token: adminAccessToken,
    });
    assertThat(auditResponse.status === 200 &&
      exactKeys(auditResponse.payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(auditResponse.payload.events),
    'instance audit feed response shape was invalid');
    const groupActions = new Set([
      'admin.relay_group_created',
      'admin.relay_group_renamed',
      'admin.relay_group_deleted',
      'admin.relay_group_membership_updated',
      'admin.relay_group_policy_updated',
      'admin.relay_group_policy_reset',
    ]);
    const groupAudit = auditResponse.payload.events.filter((event) => groupActions.has(event.action));
    const actions = new Set(groupAudit.map((event) => event.action));
    for (const action of groupActions) {
      assertThat(actions.has(action), `instance audit omitted expected group action ${action}`);
    }
    const expectedAuditFields = [
      'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
      'resource_id', 'result', 'occurred_at', 'source',
    ];
    assertThat(groupAudit.every((event) => exactKeys(event, expectedAuditFields) &&
      /^\d+$/.test(event.event_id) && event.scope === 'instance' &&
      event.resource_type === 'relay_access_group' &&
      typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id) &&
      event.actor_user_id === adminAccountId && event.actor_device_id === adminDeviceId &&
      event.result === 'success' && event.source === 'api' &&
      !Number.isNaN(Date.parse(event.occurred_at))),
    'group audit event exposed direct group identity or incorrect actor fields');
    const serializedAudit = JSON.stringify(groupAudit);
    assertThat(!serializedAudit.includes('运维团队') && !serializedAudit.includes('网络组') &&
      !serializedAudit.includes(memberUsername) && !serializedAudit.includes(memberAccountId),
    'group audit events exposed group names or member identity');

    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const auditRefresh = adminPage.getByRole('button', {
      name: /Load admin audit|Refresh admin audit/,
    }).first();
    mutationStart = adminEvents.length;
    await auditRefresh.click();
    const auditUiEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= mutationStart);
    assertThat(auditUiEvent.hasBearer && auditUiEvent.status === 200,
      'Settings instance audit refresh was not authorized');
    for (const label of [
      '管理员已创建 SSH Relay 访问组',
      '管理员已重命名 SSH Relay 访问组',
      '管理员已更改 SSH Relay 访问组成员',
      '管理员已更改 SSH Relay 访问组策略',
      '管理员已重置 SSH Relay 访问组策略',
      '管理员已删除 SSH Relay 访问组',
    ]) {
      await scrollUntilVisibleSemanticText(adminPage, label, 40);
    }
    assertThat(!await hasVisibleSemanticText(adminPage, 'admin.relay_group_'),
      'Settings audit card displayed a raw group audit action');
    reportBoolean('group_audit_metadata_private_and_actions_localized', true);

    setStage('verify browser CSP, same-origin requests and fixture cleanup readiness');
    assertThat(cspHeader.includes("default-src 'none'") &&
      cspHeader.includes("script-src 'self'") && !cspHeader.includes('www.gstatic.com'),
    'Web document did not include the expected strict self-hosted CSP');
    assertThat(externalRequestOrigins.length === 0,
      'browser attempted an external network request');
    assertThat(pageErrors === 0, 'administrator or member page raised a browser exception');
    assertThat(localCanvasKitBootstrapCount >= 2,
      'isolated browser profiles did not use local CanvasKit assets');
    reportBoolean('csp_same_origin_external_request_privacy_checks_passed', true);
    reportBoolean('browser_page_errors_absent', true);
  } catch (error) {
    console.error(`failure stage: ${stage}`);
    console.error(`failure: ${safeFailureSummary(error)}`);
    runFailed = true;
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'Web group acceptance fixture cleanup failed');
  assertThat(!tempRoot || !fs.existsSync(tempRoot), 'temporary group fixture data remained after cleanup');
  if (runFailed) {
    process.exitCode = 1;
    return;
  }
  console.log('WEB-ADMIN-RELAY-GROUPS-01 passed');
}

main().catch(async (error) => {
  console.error(`failure stage: ${stage}`);
  console.error(`failure: ${safeFailureSummary(error)}`);
  await cleanup();
  process.exitCode = 1;
});
