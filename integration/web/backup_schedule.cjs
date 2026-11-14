/*
 * WEB-BACKUP-SCHEDULE-01: verify durable scheduled encrypted backups from the
 * real Flutter Web Settings UI against a disposable allowlisted server. The
 * test exercises admin/member authorization, the strict schedule API, UI
 * enable/disable, and an actual due run after changing only the disposable
 * SQLite due timestamp and restarting the server. Diagnostics contain fixed
 * stages, HTTP statuses, and booleans only.
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
const SERVER_BINARY = process.env.ATERMIUS_PG_HTTP_SERVER_BIN ||
  path.join(ROOT, 'server/target/debug/atermius-server');
const SCHEDULE_PATH = '/api/v1/admin/backup-schedule';
const ADMIN_AUDIT_PATH = '/api/v1/admin/audit';
const PG_SETTINGS_ONLY = process.argv.includes('--pg-settings-only');
const ROOT_KEYS = [
  'operation', 'backup_configured', 'interval_hours', 'next_run_at', 'last_run',
];
const RUN_KEYS = [
  'run_id', 'scheduled_for', 'started_at', 'finished_at', 'status', 'result_code',
  'archive_bytes', 'migration_version',
];
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
let memberUsername;
let memberPassword;
let adminAccessToken;
let adminAccountId;
let adminDeviceId;
let memberAccessToken;
let backupKey;
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = 0;
let apiRequestFailures = 0;
let relayRequests = 0;
const events = { admin: [], member: [] };
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

function reportStatus(name, status) {
  console.log(`assert: ${name}_http_status=${status}`);
}

function reportBoolean(name, value) {
  console.log(`assert: ${name}=${value}`);
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
      // The server is still starting or restarting.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

async function waitForExternalServer(baseUrl, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Keep waiting for the already-managed PG fixture.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('external PostgreSQL server readiness timed out');
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
    adminAccountId = undefined;
    adminDeviceId = undefined;
    memberAccessToken = undefined;
    if (backupKey) backupKey.fill(0);
    backupKey = undefined;
    leakSentinels.length = 0;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
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

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

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
    await page.waitForTimeout(80);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(100);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    if (await locator.inputValue() === value) return;
  }
  throw new Error('visible interval field did not retain input');
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected browser or API state did not appear');
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) return false;
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`.includes(expected);
    });
  }, needle);
}

async function scrollUntilVisibleSemanticText(page, needle, maxSteps = 24) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(page, needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(900, 850);
    await page.mouse.wheel(0, 750);
    await page.waitForTimeout(60);
  }
  throw new Error('expected Settings audit content did not enter the visible area');
}

async function pageVisibleText(page) {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => {
        const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
        return `${element.textContent || ''}\n${attributes}`;
      }).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
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
    `isolated ${description} credential unavailable`);
  leakSentinels.push(token);
  return token;
}

function trackApi(page, log) {
  const pending = new WeakMap();
  page.on('request', (request) => {
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (pathname !== '/api/v1/auth/register' && pathname !== SCHEDULE_PATH &&
        pathname !== ADMIN_AUDIT_PATH) return;
    let body = null;
    if (pathname === SCHEDULE_PATH && request.method() === 'PUT') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    pending.set(request, {
      route: pathname === SCHEDULE_PATH
        ? 'schedule'
        : pathname === ADMIN_AUDIT_PATH ? 'admin-audit' : 'register',
      method: request.method(),
      pathname,
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      body,
    });
  });
  page.on('response', (response) => {
    const metadata = pending.get(response.request());
    if (!metadata) return;
    const payloadPromise = response.json().catch(() => null);
    log.push({ ...metadata, status: response.status(), sequence: log.length, payloadPromise });
  });
}

function trackBrowserDiagnostics(page) {
  page.on('request', (request) => {
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (/\/api\/v1\/(relay|terminal-relay)(\/|$)/.test(pathname)) relayRequests += 1;
  });
  page.on('requestfailed', (request) => {
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (pathname.startsWith('/api/')) apiRequestFailures += 1;
  });
}

async function waitForEvent(log, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = log.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected scheduled backup API response did not arrive');
}

async function createAdminProfile(page, baseUrl, log) {
  await configurePage(page, baseUrl);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Backup schedule acceptance admin');
  await fill(page, 'First Vault', 'Backup schedule acceptance admin');
  const start = log.length;
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const response = await waitForEvent(log,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await response.payloadPromise;
  assertThat(response.status >= 200 && response.status < 300 &&
      typeof payload?.access_token === 'string' &&
      typeof payload?.account_id === 'string' && typeof payload?.device_id === 'string',
    'allowlisted admin registration failed');
  leakSentinels.push(adminPassword, payload.access_token);
  return {
    accessToken: payload.access_token,
    accountId: payload.account_id,
    deviceId: payload.device_id,
  };
}

async function createMemberProfile(page, baseUrl, log) {
  await configurePage(page, baseUrl);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Backup schedule acceptance member');
  await fill(page, 'First Vault', 'Backup schedule acceptance member');
  const start = log.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const response = await waitForEvent(log,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await response.payloadPromise;
  assertThat(response.status >= 200 && response.status < 300 &&
      typeof payload?.access_token === 'string', 'invited member registration failed');
  leakSentinels.push(memberPassword, payload.access_token);
  return payload.access_token;
}

function exactKeys(value, expected) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function validTimestamp(value) {
  return typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function assertSafe(value) {
  const forbidden = /(hash|ip|address|password|secret|verifier|envelope|ciphertext|token|filesystem|path|key_file|archive_file)/i;
  const visit = (item) => {
    if (Array.isArray(item)) return item.forEach(visit);
    if (!item || typeof item !== 'object') return;
    for (const [key, child] of Object.entries(item)) {
      assertThat(!forbidden.test(key), 'schedule API exposed a private field');
      visit(child);
    }
  };
  visit(value);
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const sentinel of leakSentinels) {
    if (sentinel && sentinel.length >= 8) {
      assertThat(!serialized.includes(sentinel), 'schedule API or UI exposed a secret');
    }
  }
  assertThat(!/\/(?:root|tmp|var|home|opt|usr|workspace)\//i.test(serialized),
    'schedule API or UI exposed a filesystem path');
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'schedule API or UI exposed the data path');
}

function validateSchedule(payload, { interval, lastRun } = {}) {
  assertThat(exactKeys(payload, ROOT_KEYS) && payload.operation === 'backup_schedule' &&
      typeof payload.backup_configured === 'boolean', 'schedule response shape was invalid');
  assertThat(payload.interval_hours === null ||
      Number.isInteger(payload.interval_hours) && payload.interval_hours >= 1 &&
      payload.interval_hours <= 720, 'schedule interval was invalid');
  assertThat(payload.next_run_at === null || validTimestamp(payload.next_run_at),
    'schedule next run timestamp was invalid');
  assertThat((payload.interval_hours === null) === (payload.next_run_at === null),
    'schedule enabled state and next run timestamp disagreed');
  if (interval !== undefined) {
    assertThat(payload.interval_hours === interval, 'schedule interval did not match the requested value');
  }
  if (lastRun !== undefined) {
    assertThat((payload.last_run?.run_id ?? null) === (lastRun?.run_id ?? null),
      'schedule last-run identity changed unexpectedly');
  }
  if (payload.last_run !== null) {
    const run = payload.last_run;
    assertThat(exactKeys(run, RUN_KEYS) && UUID_PATTERN.test(run.run_id) &&
        validTimestamp(run.scheduled_for) && validTimestamp(run.started_at) &&
        (run.finished_at === null || validTimestamp(run.finished_at)) &&
        ['running', 'succeeded', 'failed', 'interrupted'].includes(run.status) &&
        ['completed', 'backup_failed', 'interrupted', null].includes(run.result_code) &&
        (run.archive_bytes === null || Number.isInteger(run.archive_bytes) && run.archive_bytes > 0) &&
        (run.migration_version === null || Number.isInteger(run.migration_version) && run.migration_version >= 0),
      'schedule last-run metadata was invalid');
    if (run.status === 'running') {
      assertThat(run.finished_at === null && run.result_code === null,
        'running schedule result had terminal metadata');
    } else if (run.status === 'succeeded') {
      assertThat(run.finished_at !== null && run.result_code === 'completed' &&
          run.archive_bytes > 0 && run.migration_version !== null,
        'successful schedule result was incomplete');
    } else if (run.status === 'failed') {
      assertThat(run.finished_at !== null && run.result_code === 'backup_failed' &&
          run.archive_bytes === null && run.migration_version === null,
        'failed schedule result exposed success-only metadata');
    } else {
      assertThat(run.finished_at !== null && run.result_code === 'interrupted',
        'interrupted schedule result was inconsistent');
    }
  }
  assertSafe(payload);
  return payload;
}

async function directApi(baseUrl, method, token, body) {
  const response = await fetch(`${baseUrl}${SCHEDULE_PATH}`, {
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
  return { status: response.status, payload, code: payload?.error?.code ?? null };
}

async function directAdminAuditApi(baseUrl, token) {
  const response = await fetch(`${baseUrl}${ADMIN_AUDIT_PATH}`, {
    method: 'GET',
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${token}`,
    },
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertSafe(payload);
  return { status: response.status, payload };
}

function validateAdminAuditPage(payload) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'instance audit page shape was invalid');
  assertSafe(payload);
  const eventFields = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
    'resource_id', 'result', 'occurred_at', 'source',
  ];
  for (const event of payload.events) {
    assertThat(exactKeys(event, eventFields) && /^\d+$/.test(event.event_id) &&
        event.scope === 'instance' &&
        (event.actor_user_id === null || typeof event.actor_user_id === 'string') &&
        (event.actor_device_id === null || typeof event.actor_device_id === 'string') &&
        (event.resource_id === null || /^[0-9a-f]{64}$/.test(event.resource_id)) &&
        ['success', 'failure'].includes(event.result) &&
        ['api', 'maintenance'].includes(event.source) && validTimestamp(event.occurred_at),
      'instance audit event DTO or privacy metadata was invalid');
  }
  return payload.events;
}

function validateScheduleAuditEvent(payload, admin) {
  const matching = validateAdminAuditPage(payload).filter(
    (event) => event.action === 'admin.backup_schedule_updated');
  assertThat(matching.length === 1,
    'admin audit feed did not contain exactly one schedule-enable write');
  const event = matching[0];
  assertThat(event.scope === 'instance' &&
      event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
      event.resource_type === 'backup_schedule' && event.resource_id === null &&
      event.source === 'api' && event.result === 'success',
    'schedule audit event actor, resource, source or result was invalid');
  const serialized = JSON.stringify(event);
  assertThat(!serialized.includes(adminUsername) && !serialized.includes(adminPassword),
    'schedule audit event exposed account or credential data');
  return event;
}

async function setScheduleSwitch(page, enabled) {
  const locator = page.getByRole('switch', { name: 'Enable scheduled backups' }).first();
  try {
    await locator.waitFor({ state: 'visible', timeout: 1500 });
    const checked = await locator.getAttribute('aria-checked');
    if ((checked === 'true') !== enabled) await locator.click();
    return;
  } catch (_) {
    const semantic = page.locator('flt-semantics[aria-label="Enable scheduled backups"]').first();
    if (await semantic.count()) {
      await semantic.click();
      return;
    }
    await page.getByText('Enable scheduled backups', { exact: true }).click();
  }
}

async function scheduleSwitchState(page) {
  const locator = page.getByRole('switch', { name: 'Enable scheduled backups' }).first();
  try {
    await locator.waitFor({ state: 'visible', timeout: 1500 });
    return await locator.getAttribute('aria-checked');
  } catch (_) {
    const semantic = page.locator('flt-semantics[aria-label="Enable scheduled backups"]').first();
    if (await semantic.count()) return await semantic.getAttribute('aria-checked');
    return null;
  }
}

async function startServer(serverEnv, baseUrl) {
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env: serverEnv,
    detached: true,
    stdio: 'ignore',
  });
  await waitForServer(baseUrl, serverProcess);
}

function forceDueTimestamp(databasePath) {
  const due = Math.floor(Date.now() / 1000) - 300;
  const code = [
    'import sqlite3, sys',
    'connection = sqlite3.connect(sys.argv[1], timeout=10)',
    "changed = connection.execute('UPDATE instance_backup_schedule SET next_run_at=? WHERE schedule_id=1', (int(sys.argv[2]),)).rowcount",
    'connection.commit()',
    'connection.close()',
    'raise SystemExit(0 if changed == 1 else 1)',
  ].join('\n');
  const result = spawnSync('python3', ['-c', code, databasePath, String(due)], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 15000,
  });
  assertThat(!result.error && result.status === 0, 'isolated schedule due timestamp setup failed');
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  if (!PG_SETTINGS_ONLY) {
    setStage('isolated server build');
    buildServer();
  }

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-backup-schedule-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    const archiveDir = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_BACKUP_ARCHIVE_DIR
      : path.join(tempRoot, 'archives');
    const keyPath = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_BACKUP_KEY_FILE
      : path.join(tempRoot, 'operator-backup.key');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    if (!PG_SETTINGS_ONLY) {
      fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 });
      fs.chmodSync(archiveDir, 0o700);
    }
    const databasePath = path.join(dataDir, 'atermius.db');
    if (PG_SETTINGS_ONLY) {
      assertThat(typeof archiveDir === 'string' && archiveDir.length > 0 &&
          typeof keyPath === 'string' && keyPath.length > 0 &&
          fs.statSync(archiveDir).isDirectory() && fs.statSync(keyPath).isFile(),
        'shared PostgreSQL backup configuration is unavailable');
      backupKey = fs.readFileSync(keyPath);
      assertThat(backupKey.length === 32, 'shared PostgreSQL backup key has an invalid size');
    } else {
      backupKey = crypto.randomBytes(32);
      fs.writeFileSync(keyPath, backupKey, { flag: 'wx', mode: 0o600 });
      fs.chmodSync(keyPath, 0o600);
    }
    if (process.platform !== 'win32' && !PG_SETTINGS_ONLY) {
      assertThat((fs.statSync(keyPath).mode & 0o777) === 0o600,
        'temporary backup key permissions were not private');
    }

    const port = PG_SETTINGS_ONLY ? null : await unusedLoopbackPort();
    const baseUrl = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_PG_BACKUP_SCHEDULE_BASE_URL
      : `http://127.0.0.1:${port}`;
    const peerBaseUrl = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_PG_BACKUP_SCHEDULE_NODE_B_URL
      : null;
    assertThat(typeof baseUrl === 'string' && baseUrl.startsWith('http://127.0.0.1:') &&
        (!PG_SETTINGS_ONLY || typeof peerBaseUrl === 'string'),
      'schedule acceptance server URLs are unavailable');
    const suffix = crypto.randomUUID().slice(0, 8);
    adminUsername = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_PG_BACKUP_SCHEDULE_ADMIN_USERNAME
      : `web-backup-schedule-admin-${suffix}@example.test`;
    adminPassword = PG_SETTINGS_ONLY
      ? process.env.ATERMIUS_PG_BACKUP_SCHEDULE_ADMIN_PASSWORD
      : `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-backup-schedule-member-${suffix}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    if (PG_SETTINGS_ONLY) {
      bootstrapToken = process.env.ATERMIUS_PG_BACKUP_SCHEDULE_BOOTSTRAP_TOKEN;
      assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
        'PostgreSQL bootstrap token is unavailable');
    }
    leakSentinels.push(adminPassword, memberPassword, tempRoot, databasePath, keyPath,
      backupKey.toString('hex'), backupKey.toString('base64'));
    const cleanEnv = Object.fromEntries(
      Object.entries(process.env).filter(([key]) => !key.startsWith('ATERMIUS_')),
    );
    const serverEnv = PG_SETTINGS_ONLY ? { ...process.env } : {
      ...cleanEnv,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_BACKUP_ARCHIVE_DIR: archiveDir,
      ATERMIUS_BACKUP_KEY_FILE: keyPath,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };
    serverEnv.ATERMIUS_DATA_DIR = dataDir;
    serverEnv.ATERMIUS_DATABASE_URL = `sqlite://${databasePath}?mode=rwc`;
    serverEnv.ATERMIUS_WEB_DIR = WEB_ROOT;
    serverEnv.ATERMIUS_PUBLIC_ORIGIN = baseUrl;
    serverEnv.ATERMIUS_ADMIN_USERNAMES = adminUsername;
    serverEnv.RUST_LOG = 'off';
    for (const name of [
      'ATERMIUS_PG_BACKUP_SCHEDULE_BASE_URL',
      'ATERMIUS_PG_BACKUP_SCHEDULE_NODE_B_URL',
      'ATERMIUS_PG_BACKUP_SCHEDULE_ADMIN_USERNAME',
      'ATERMIUS_PG_BACKUP_SCHEDULE_ADMIN_PASSWORD',
      'ATERMIUS_PG_BACKUP_SCHEDULE_BOOTSTRAP_TOKEN',
      'ATERMIUS_PG_HTTP_SERVER_BIN',
      'ATERMIUS_RUN_PG_HTTP_ACCEPTANCE',
      'ATERMIUS_TEST_PG_URL',
    ]) delete serverEnv[name];

    if (PG_SETTINGS_ONLY) {
      setStage('connect to two-node PostgreSQL fixture');
      await waitForExternalServer(baseUrl);
    } else {
      setStage('start disposable configured instance');
      await startServer(serverEnv, baseUrl);
      bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');
    }

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
    trackApi(adminPage, events.admin);
    trackApi(memberPage, events.member);
    trackBrowserDiagnostics(adminPage);
    trackBrowserDiagnostics(memberPage);

    setStage('register allowlisted administrator');
    const adminProfile = await createAdminProfile(adminPage, baseUrl, events.admin);
    adminAccessToken = adminProfile.accessToken;
    adminAccountId = adminProfile.accountId;
    adminDeviceId = adminProfile.deviceId;
    reportBoolean('admin_profile_registered', true);

    setStage('register separately invited non-admin');
    invitationToken = cliToken(['create-account-invite', '--username', memberUsername],
      serverEnv, 'account invitation');
    memberAccessToken = await createMemberProfile(memberPage, baseUrl, events.member);
    reportBoolean('member_profile_registered', true);

    setStage('verify non-admin schedule controls hidden and API denied');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberCardVisible = await hasVisibleSemanticText(memberPage, 'Scheduled encrypted backups');
    assertThat(!memberCardVisible, 'non-admin profile rendered scheduled backup controls');
    const noAuthRead = await directApi(baseUrl, 'GET', undefined);
    reportStatus('unauthenticated_schedule_read', noAuthRead.status);
    assertThat(noAuthRead.status === 401, 'unauthenticated schedule read was not denied');
    const memberRead = await directApi(baseUrl, 'GET', memberAccessToken);
    reportStatus('non_admin_schedule_read', memberRead.status);
    assertThat(memberRead.status === 403, 'non-admin schedule read was not denied');
    const memberWrite = await directApi(baseUrl, 'PUT', memberAccessToken, { interval_hours: 1 });
    reportStatus('non_admin_schedule_write', memberWrite.status);
    assertThat(memberWrite.status === 403, 'non-admin schedule write was not denied');
    reportBoolean('non_admin_card_hidden_and_api_denied', true);

    setStage('verify strict schedule body and interval errors');
    const invalidCases = [
      { body: {}, code: 'INVALID_BACKUP_SCHEDULE_REQUEST' },
      { body: { interval_hours: 0 }, code: 'INVALID_BACKUP_INTERVAL' },
      { body: { interval_hours: 721 }, code: 'INVALID_BACKUP_INTERVAL' },
      { body: { interval_hours: 1.5 }, code: 'INVALID_BACKUP_SCHEDULE_REQUEST' },
      { body: { interval_hours: '24' }, code: 'INVALID_BACKUP_SCHEDULE_REQUEST' },
      { body: { interval_hours: true }, code: 'INVALID_BACKUP_SCHEDULE_REQUEST' },
      { body: { interval_hours: null, archive_path: '/tmp/unsafe.atb' },
        code: 'INVALID_BACKUP_SCHEDULE_REQUEST' },
    ];
    for (const [index, item] of invalidCases.entries()) {
      const result = await directApi(baseUrl, 'PUT', adminAccessToken, item.body);
      reportStatus(`invalid_schedule_request_${index + 1}`, result.status);
      assertThat(result.status === 400 && result.code === item.code,
        `strict schedule request case ${index + 1} returned an unexpected error`);
      assertSafe(result.payload);
    }
    reportBoolean('strict_body_and_interval_errors_valid', true);

    setStage('load and validate initial schedule in Settings');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Scheduled encrypted backups'));
    const initialStart = events.admin.length;
    await click(adminPage, 'Load backup schedule');
    const initialEvent = await waitForEvent(events.admin,
      (event) => event.route === 'schedule' && event.method === 'GET' && event.sequence >= initialStart);
    const initial = validateSchedule(await initialEvent.payloadPromise, { interval: null, lastRun: null });
    reportStatus('admin_initial_schedule_read', initialEvent.status);
    assertThat(initialEvent.hasBearer && initialEvent.status === 200 && initial.backup_configured,
      'admin initial schedule was not authenticated/configured');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Enable scheduled backups'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Next run'));
    reportBoolean('admin_schedule_card_and_initial_state_rendered', true);

    setStage('enable one-hour schedule through Settings');
    await setScheduleSwitch(adminPage, true);
    await fill(adminPage, 'Interval in hours', '1');
    const enableStart = events.admin.length;
    await click(adminPage, 'Save schedule');
    const enableEvent = await waitForEvent(events.admin,
      (event) => event.route === 'schedule' && event.method === 'PUT' && event.sequence >= enableStart);
    setStage('validate Settings enable response');
    const enabled = validateSchedule(await enableEvent.payloadPromise, { interval: 1, lastRun: null });
    reportStatus('admin_schedule_enable', enableEvent.status);
    assertThat(enableEvent.hasBearer && enableEvent.status === 200 &&
        exactKeys(enableEvent.body, ['interval_hours']) && enableEvent.body.interval_hours === 1 &&
        Date.parse(enabled.next_run_at) > Date.now(),
      'Settings did not submit a valid one-hour schedule');
    if (PG_SETTINGS_ONLY) {
      setStage('verify enabled schedule is shared with PostgreSQL node B');
      const peerEnabled = await directApi(peerBaseUrl, 'GET', adminAccessToken);
      const peerSchedule = validateSchedule(peerEnabled.payload, {
        interval: 1,
        lastRun: null,
      });
      reportStatus('peer_schedule_after_enable', peerEnabled.status);
      assertThat(peerEnabled.status === 200 && peerSchedule.next_run_at === enabled.next_run_at,
        'second PostgreSQL node did not observe the exact schedule state');
      reportBoolean('schedule_shared_across_postgres_nodes', true);
    }
    setStage('confirm enabled schedule renders in Settings');
    await waitFor(async () => await scheduleSwitchState(adminPage) === 'true');
    setStage('check enabled schedule text for private values');
    const enabledText = await pageVisibleText(adminPage);
    assertThat(!enabledText.includes(keyPath) &&
        !enabledText.includes(backupKey.toString('hex')) &&
        !enabledText.includes(backupKey.toString('base64')),
      'scheduled backup Settings exposed a private key or path');
    reportBoolean('schedule_enabled_from_settings', true);

    setStage('validate real schedule-enable writer in the instance audit API');
    const adminAuditFeed = await directAdminAuditApi(baseUrl, adminAccessToken);
    reportStatus('admin_schedule_audit_feed', adminAuditFeed.status);
    assertThat(adminAuditFeed.status === 200,
      'administrator could not read the instance audit feed after enabling schedule');
    const apiScheduleAuditEvent = validateScheduleAuditEvent(adminAuditFeed.payload, adminProfile);
    reportBoolean('schedule_audit_actor_resource_source_result_valid', true);
    reportBoolean('schedule_audit_resource_id_null_and_private_dto', true);

    setStage('render real schedule-enable audit event in Settings');
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const auditButton = await hasVisibleSemanticText(adminPage, 'Refresh admin audit')
      ? 'Refresh admin audit'
      : 'Load admin audit';
    const auditRefreshStart = events.admin.length;
    await click(adminPage, auditButton);
    const auditRefresh = await waitForEvent(events.admin,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= auditRefreshStart);
    const refreshedAuditFeed = await auditRefresh.payloadPromise;
    reportStatus('settings_schedule_audit_refresh', auditRefresh.status);
    assertThat(auditRefresh.hasBearer && auditRefresh.status === 200,
      'Settings schedule audit-card refresh was not authenticated and successful');
    const refreshedScheduleAuditEvent = validateScheduleAuditEvent(refreshedAuditFeed, adminProfile);
    assertThat(JSON.stringify(refreshedScheduleAuditEvent) ===
        JSON.stringify(apiScheduleAuditEvent),
      'Settings refresh did not preserve the validated schedule audit event');
    await scrollUntilVisibleSemanticText(adminPage, '管理员已更改计划备份');
    const rawScheduleActionVisible = await hasVisibleSemanticText(
      adminPage, 'admin.backup_schedule_updated');
    reportBoolean('schedule_audit_action_localized', true);
    reportBoolean('schedule_audit_raw_action_hidden', !rawScheduleActionVisible);
    assertThat(!rawScheduleActionVisible,
      'Settings audit card displayed the raw schedule action key');

    let run = null;
    if (!PG_SETTINGS_ONLY) {
      setStage('force a due slot in disposable database and restart server');
      await stopServerGroup(serverProcess);
      serverProcess = undefined;
      forceDueTimestamp(databasePath);
      await startServer(serverEnv, baseUrl);

      setStage('wait for actual encrypted scheduled archive');
      const deadline = Date.now() + 30000;
      let completed;
      while (Date.now() < deadline) {
        const current = await directApi(baseUrl, 'GET', adminAccessToken);
        assertThat(current.status === 200, 'admin schedule polling failed after server restart');
        const schedule = validateSchedule(current.payload, { interval: 1 });
        if (schedule.last_run && ['succeeded', 'failed', 'interrupted'].includes(schedule.last_run.status)) {
          completed = schedule;
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      assertThat(completed && completed.last_run.status === 'succeeded',
        'actual due scheduled backup did not succeed');
      run = completed.last_run;
      const archives = fs.readdirSync(archiveDir).filter((name) =>
        name.endsWith(`-${run.run_id}.atb`));
      assertThat(archives.length === 1, 'scheduled run did not create exactly one named encrypted archive');
      const archivePath = path.join(archiveDir, archives[0]);
      assertThat(fs.statSync(archivePath).isFile() && fs.statSync(archivePath).size === run.archive_bytes,
        'scheduled archive did not match the durable run byte count');
      reportBoolean('actual_scheduled_backup_created_archive', true);

      setStage('refresh and validate scheduled run in Settings UI');
      const refreshStart = events.admin.length;
      await click(adminPage, 'Refresh schedule');
      const refreshEvent = await waitForEvent(events.admin,
        (event) => event.route === 'schedule' && event.method === 'GET' && event.sequence >= refreshStart);
      const shownSchedule = validateSchedule(await refreshEvent.payloadPromise, {
        interval: 1,
        lastRun: run,
      });
      reportStatus('admin_schedule_after_run', refreshEvent.status);
      assertThat(refreshEvent.status === 200 && refreshEvent.hasBearer &&
          shownSchedule.last_run.status === 'succeeded',
        'schedule UI refresh did not return the durable successful run');
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Succeeded'));
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Archive bytes'));
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Scheduled for'));
      const rendered = await pageVisibleText(adminPage);
      const formattedBytes = `${new Intl.NumberFormat('en-US').format(run.archive_bytes)} bytes`;
      assertThat(rendered.includes(formattedBytes), 'schedule UI omitted the actual archive byte count');
      assertSafe(rendered);
      assertThat(!rendered.includes(run.run_id), 'schedule UI exposed an internal run identifier');
      reportBoolean('scheduled_run_status_rendered_without_private_data', true);

    } else {
      reportBoolean('scheduled_worker_covered_by_pg_http_acceptance', true);
    }

    setStage('disable schedule through Settings and preserve last run');
    await setScheduleSwitch(adminPage, false);
    const disableStart = events.admin.length;
    await click(adminPage, 'Save schedule');
    const disableEvent = await waitForEvent(events.admin,
      (event) => event.route === 'schedule' && event.method === 'PUT' && event.sequence >= disableStart);
    const disabled = validateSchedule(await disableEvent.payloadPromise, {
      interval: null,
      lastRun: run,
    });
    reportStatus('admin_schedule_disable', disableEvent.status);
    assertThat(disableEvent.hasBearer && disableEvent.status === 200 &&
        exactKeys(disableEvent.body, ['interval_hours']) && disableEvent.body.interval_hours === null &&
        disabled.next_run_at === null,
      'Settings did not disable the schedule using the strict null body');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Disabled'));
    if (run) await waitFor(() => hasVisibleSemanticText(adminPage, 'Succeeded'));
    assertSafe(await pageVisibleText(adminPage));
    reportBoolean('schedule_disabled_and_last_run_preserved', true);
    if (PG_SETTINGS_ONLY) {
      const peerDisabled = await directApi(peerBaseUrl, 'GET', adminAccessToken);
      const peerDisabledSchedule = validateSchedule(peerDisabled.payload, {
        interval: null,
        lastRun: null,
      });
      reportStatus('peer_schedule_after_disable', peerDisabled.status);
      assertThat(peerDisabled.status === 200 && peerDisabledSchedule.next_run_at === null,
        'second PostgreSQL node did not observe the disabled schedule');
      reportBoolean('schedule_disable_shared_across_postgres_nodes', true);
    }

    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    reportBoolean('browser_runtime_errors_absent', true);
    assertThat(apiRequestFailures === 0, 'browser API request failed during schedule Settings flow');
    assertThat(relayRequests === 0, 'schedule Settings flow unexpectedly used SSH Relay');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
  reportBoolean('browser_cleanup_complete', true);
  console.log(`assert: page_errors=${pageErrors}`);
  if (PG_SETTINGS_ONLY) {
    const bundleHash = crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');
    console.log(`assert: request_failures=${apiRequestFailures}`);
    console.log(`assert: relay_requests=${relayRequests}`);
    console.log(`assert: web_release_sha256=${bundleHash}`);
    reportBoolean('pg_backup_schedule_web_pass', true);
    console.log('WEB-PG-BACKUP-SCHEDULE-01 passed');
  } else {
    console.log('WEB-BACKUP-SCHEDULE-01 passed');
  }
}

main().catch(async (error) => {
  await cleanup();
  console.error(`stage: ${stage}`);
  console.error(`assertion: ${typeof error?.safeAssertion === 'string'
    ? error.safeAssertion : 'unclassified failure'}`);
  if (typeof error?.name === 'string' && error.name !== 'Error') {
    console.error(`failure_type: ${error.name}`);
  }
  if (cleanupFailed) console.error('assertion: temporary resource cleanup failed');
  process.exitCode = 1;
});
