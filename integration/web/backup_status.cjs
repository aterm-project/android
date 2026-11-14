/*
 * WEB-BACKUP-STATUS-01: exercise the local backup CLI sidecar through the
 * authenticated instance-admin API and Flutter Web Settings UI. A separately
 * invited member must neither see the card nor read the endpoint. Diagnostics
 * contain only fixed stages, statuses, and booleans.
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
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const STATUS_PATH = '/api/v1/admin/backup-status';
const STATUS_KEYS = ['operation', 'last_attempt'];
const ATTEMPT_KEYS = [
  'attempted_at', 'result', 'migration_version', 'archive_bytes', 'failure_category',
];
const SIDECAR_KEYS = [
  'schema_version', 'operation', 'attempted_at', 'result', 'migration_version',
  'archive_bytes', 'failure_category', 'last_success_at',
];

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
let backupKeyBytes;
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = 0;
const leakSentinels = [];
const safeApiStatuses = [];

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
    if (backupKeyBytes) backupKeyBytes.fill(0);
    backupKeyBytes = undefined;
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
  error.safeAssertion = 'UI state wait timed out';
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

async function hasExactVisibleSemanticText(page, expected) {
  return page.evaluate((value) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      const visible = style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      if (!visible) return false;
      const text = (element.textContent || '').trim();
      const ariaLabel = (element.getAttribute('aria-label') || '').trim();
      return text === value || ariaLabel === value;
    });
  }, expected);
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

function runQuietCli(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    timeout: 60000,
    stdio: 'ignore',
  });
  assertThat(!result.error && result.status === 0, `isolated ${description} failed`);
}

function runQuietCliFailure(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    timeout: 60000,
    stdio: 'ignore',
  });
  assertThat(!result.error && Number.isInteger(result.status) && result.status > 0,
    `isolated ${description} did not return a normal failure status`);
  return result.status;
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

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === STATUS_PATH) return 'backup-status';
  } catch (_) {
    // Ignore browser-internal requests.
  }
  return null;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    byRequest.set(request, {
      route,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      pathname: new URL(request.url()).pathname,
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    const contentType = (response.headers()['content-type'] || '').split(';')[0].trim().toLowerCase();
    const responseBodyPromise = response.body().catch(() => Buffer.alloc(0));
    const parsedPayloadPromise = responseBodyPromise.then((body) => {
      try {
        return { ok: true, payload: JSON.parse(body.toString('utf8')) };
      } catch (_) {
        return { ok: false, payload: null };
      }
    });
    const responseBodyDiagnosticsPromise = responseBodyPromise.then((body) => ({
      byteLength: body.length,
      contentTypeCategory: contentType === 'application/json' ? 'json' :
        contentType === 'text/html' ? 'html' :
        contentType.startsWith('text/') ? 'text' : contentType ? 'other' : 'missing',
      bodyCategory: body.length === 0 ? 'empty' :
        /^[\s]*[\[{]/.test(body.toString('utf8')) ? 'json-shaped' :
        /^[\s]*</.test(body.toString('utf8')) ? 'html-shaped' : 'other',
    }));
    events.push({
      ...metadata,
      status: response.status(),
      sequence: events.length,
      payloadPromise: parsedPayloadPromise.then((parsed) => parsed.payload),
      jsonParseOkPromise: parsedPayloadPromise.then((parsed) => parsed.ok),
      responseBodyDiagnosticsPromise,
    });
    safeApiStatuses.push({ route: metadata.route, status: response.status() });
    if (safeApiStatuses.length > 20) safeApiStatuses.shift();
  });
}

async function waitForEvent(events, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const error = new Error('expected API response did not arrive');
  error.safeAssertion = 'API response wait timed out';
  throw error;
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertNoSecretOrPathFields(value) {
  const forbiddenKey = /(hash|ip|address|password|secret|verifier|envelope|ciphertext|token|filesystem|path|key_file|archive_file)/i;
  const ipv4 = /\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/;
  const visit = (item) => {
    if (Array.isArray(item)) {
      item.forEach(visit);
      return;
    }
    if (!item || typeof item !== 'object') return;
    for (const [key, child] of Object.entries(item)) {
      assertThat(!forbiddenKey.test(key), 'backup status exposed a forbidden field');
      visit(child);
    }
  };
  visit(value);
  assertThat(!ipv4.test(JSON.stringify(value)), 'backup status exposed an IP address');
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const sentinel of leakSentinels) {
    if (sentinel && sentinel.length >= 8) {
      assertThat(!serialized.includes(sentinel), 'backup status exposed a secret or runtime policy');
    }
  }
  const internalText = /\/(?:root|tmp|var|home|opt|usr|workspace)\/|\b[A-Z]:\\(?:Users|Windows|Program Files)\\|(?:SQLite|sqlx|tokio::|panic at|stack trace|backtrace|internal server error|no such table)/i;
  assertThat(!internalText.test(serialized), 'backup status exposed internal server details');
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'backup status exposed a server filesystem path');
}

function validTimestamp(value) {
  return typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function validateBackupStatus(payload, expectedAttempt = undefined) {
  assertThat(exactKeys(payload, STATUS_KEYS) && payload.operation === 'backup',
    'backup status response shape was invalid');
  assertNoSecretOrPathFields(payload);
  assertNoLeaks(payload);
  if (expectedAttempt === null) {
    assertThat(payload.last_attempt === null, 'initial backup status was not empty');
    return null;
  }
  const attempt = payload.last_attempt;
  assertThat(exactKeys(attempt, ATTEMPT_KEYS) && validTimestamp(attempt.attempted_at) &&
      attempt.result === 'succeeded' && Number.isInteger(attempt.migration_version) &&
      attempt.migration_version > 0 && Number.isInteger(attempt.archive_bytes) &&
      attempt.archive_bytes > 0 && attempt.failure_category === null,
    'successful backup status attempt was invalid');
  if (expectedAttempt) {
    assertThat(attempt.attempted_at === expectedAttempt.attempted_at &&
        attempt.migration_version === expectedAttempt.migration_version &&
        attempt.archive_bytes === expectedAttempt.archive_bytes,
      'backup status API did not return the CLI sidecar values');
  }
  return attempt;
}

function validateFailedBackupStatus(payload, expectedAttempt = undefined) {
  assertThat(exactKeys(payload, STATUS_KEYS) && payload.operation === 'backup',
    'failed backup status response shape was invalid');
  const attempt = payload.last_attempt;
  assertThat(exactKeys(attempt, ATTEMPT_KEYS) && validTimestamp(attempt.attempted_at) &&
      attempt.result === 'failed' && attempt.migration_version === null &&
      attempt.archive_bytes === null && attempt.failure_category === 'backup_failed',
    'failed backup status did not expose only the fixed failure category');
  if (expectedAttempt) {
    assertThat(attempt.attempted_at === expectedAttempt.attempted_at &&
        attempt.migration_version === expectedAttempt.migration_version &&
        attempt.archive_bytes === expectedAttempt.archive_bytes &&
        attempt.failure_category === expectedAttempt.failure_category,
      'backup status API did not return the failed CLI sidecar values');
  }
  assertNoSecretOrPathFields(payload);
  assertNoLeaks(payload);
  return attempt;
}

function assertSidecar(sidecar, archiveBytes) {
  assertThat(exactKeys(sidecar, SIDECAR_KEYS) && sidecar.schema_version === 2 &&
      sidecar.operation === 'backup' && validTimestamp(sidecar.attempted_at) &&
      sidecar.result === 'succeeded' && Number.isInteger(sidecar.migration_version) &&
      sidecar.migration_version > 0 && sidecar.archive_bytes === archiveBytes &&
      sidecar.failure_category === null &&
      sidecar.last_success_at === sidecar.attempted_at,
    'backup CLI sidecar shape or values were invalid');
  assertNoSecretOrPathFields(sidecar);
  assertNoLeaks(sidecar);
}

function assertFailedSidecar(sidecar) {
  assertThat(exactKeys(sidecar, SIDECAR_KEYS) && sidecar.schema_version === 2 &&
      sidecar.operation === 'backup' && validTimestamp(sidecar.attempted_at) &&
      sidecar.result === 'failed' && sidecar.migration_version === null &&
      sidecar.archive_bytes === null && sidecar.failure_category === 'backup_failed' &&
      validTimestamp(sidecar.last_success_at) &&
      Date.parse(sidecar.last_success_at) <= Date.parse(sidecar.attempted_at),
    'failed backup CLI sidecar shape or values were invalid');
  assertNoSecretOrPathFields(sidecar);
  assertNoLeaks(sidecar);
}

function snapshotTree(root) {
  const snapshot = {};
  const visit = (directory, prefix = '') => {
    const entries = fs.readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const entryPath = path.join(directory, entry.name);
      const metadata = fs.lstatSync(entryPath);
      const common = {
        mode: metadata.mode & 0o7777,
        mtimeMs: metadata.mtimeMs,
        ctimeMs: metadata.ctimeMs,
      };
      if (metadata.isSymbolicLink()) {
        snapshot[relative] = { ...common, type: 'symlink', target: fs.readlinkSync(entryPath) };
      } else if (metadata.isDirectory()) {
        snapshot[relative] = { ...common, type: 'directory' };
        visit(entryPath, relative);
      } else if (metadata.isFile()) {
        const digest = crypto.createHash('sha256').update(fs.readFileSync(entryPath)).digest('hex');
        snapshot[relative] = { ...common, type: 'file', size: metadata.size, sha256: digest };
      } else {
        snapshot[relative] = { ...common, type: 'other' };
      }
    }
  };
  visit(root);
  return snapshot;
}

function verifyStagingEntries() {
  return fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith('.atermius-backup-verify-')).sort();
}

async function createAdminProfile(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Backup status acceptance admin');
  await fill(page, 'First Vault', 'Backup status acceptance admin');
  const start = events.length;
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.account_id === 'string' && typeof payload?.device_id === 'string' &&
      typeof payload?.access_token === 'string',
    'allowlisted administrator registration response was incomplete');
  leakSentinels.push(adminPassword, payload.access_token);
  return { status: registration.status, accessToken: payload.access_token };
}

async function createMemberProfile(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Backup status acceptance member');
  await fill(page, 'First Vault', 'Backup status acceptance member');
  const start = events.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string',
    'invited non-admin registration response was incomplete');
  leakSentinels.push(memberPassword, payload.access_token);
  return { status: registration.status, accessToken: payload.access_token };
}

function backupStatusEvent(events, sequence = 0) {
  return (event) => event.route === 'backup-status' && event.method === 'GET' &&
    event.pathname === STATUS_PATH && event.sequence >= sequence;
}

function isPlainJsonObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype;
}

function reportSuccessfulStatusShapeDiagnostics(parseOk, payload) {
  reportBoolean('response_json_parse_ok', parseOk);
  const isPlain = isPlainJsonObject(payload);
  reportBoolean('response_payload_plain_object', isPlain);
  const rootKeys = isPlain ? Object.keys(payload).sort() : [];
  console.log(`assert: response_root_keys=${JSON.stringify(rootKeys)}`);
  reportBoolean('response_operation_is_backup', isPlain && payload.operation === 'backup');

  const attempt = isPlain ? payload.last_attempt : undefined;
  reportBoolean('response_last_attempt_is_null', isPlain && attempt === null);
  const attemptIsObject = isPlainJsonObject(attempt);
  reportBoolean('response_last_attempt_is_object', attemptIsObject);
  reportBoolean('response_attempted_at_present_string', attemptIsObject &&
    Object.hasOwn(attempt, 'attempted_at') && typeof attempt.attempted_at === 'string');
  reportBoolean('response_result_present_success_string', attemptIsObject &&
    Object.hasOwn(attempt, 'result') && attempt.result === 'succeeded');
  reportBoolean('response_migration_version_present_integer', attemptIsObject &&
    Object.hasOwn(attempt, 'migration_version') && Number.isInteger(attempt.migration_version));
  reportBoolean('response_archive_bytes_present_integer', attemptIsObject &&
    Object.hasOwn(attempt, 'archive_bytes') && Number.isInteger(attempt.archive_bytes));
  reportBoolean('response_failure_category_present_null', attemptIsObject &&
    Object.hasOwn(attempt, 'failure_category') && attempt.failure_category === null);
}

async function directApi(baseUrl, token) {
  const response = await fetch(`${baseUrl}${STATUS_PATH}`, {
    headers: { accept: 'application/json', authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertNoLeaks(payload);
  return { status: response.status, body: payload };
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-backup-status-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const archivePath = path.join(tempRoot, 'operator-backup.atb');
    const keyPath = path.join(tempRoot, 'operator-backup.key');
    const failedArchivePath = path.join(tempRoot, 'failed-attempt.atb');
    const missingKeyPath = path.join(tempRoot, 'missing-operator-backup.key');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const runId = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-backup-admin-${runId}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-backup-member-${runId}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    const policySentinel = `backup-policy-${crypto.randomUUID()}@example.test`;
    backupKeyBytes = crypto.randomBytes(32);
    leakSentinels.push(
      adminPassword,
      memberPassword,
      tempRoot,
      dataDir,
      databasePath,
      archivePath,
      path.basename(archivePath),
      keyPath,
      path.basename(keyPath),
      failedArchivePath,
      path.basename(failedArchivePath),
      missingKeyPath,
      path.basename(missingKeyPath),
      backupKeyBytes.toString('hex'),
      backupKeyBytes.toString('base64'),
      policySentinel,
    );
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
      ATERMIUS_ADMIN_USERNAMES: `${adminUsername},${policySentinel}`,
      RUST_LOG: 'off',
    };
    const adminEvents = [];
    const memberEvents = [];

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
    trackApi(adminPage, adminEvents);
    trackApi(memberPage, memberEvents);

    setStage('register allowlisted administrator');
    const admin = await createAdminProfile(adminPage, baseUrl, adminEvents);
    adminAccessToken = admin.accessToken;
    reportStatus('admin_registration', admin.status);

    setStage('create separately invited non-admin');
    invitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'account invitation');
    const member = await createMemberProfile(memberPage, baseUrl, memberEvents);
    memberAccessToken = member.accessToken;
    reportStatus('member_registration', member.status);

    setStage('verify non-admin backup status denial');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberHasCard = await hasVisibleSemanticText(memberPage, 'Instance backup status');
    assertThat(!memberHasCard, 'non-admin profile rendered the instance backup status card');
    const memberRead = await directApi(baseUrl, memberAccessToken);
    reportStatus('member_backup_status', memberRead.status);
    assertThat(memberRead.status === 403, 'non-admin backup status request was not denied');
    reportBoolean('non_admin_card_hidden_and_api_denied', true);

    setStage('load initial empty backup status');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Instance backup status'));
    const initialStart = adminEvents.length;
    await click(adminPage, 'Load backup status');
    const initialEvent = await waitForEvent(adminEvents, backupStatusEvent(adminEvents, initialStart));
    const initialPayload = await initialEvent.payloadPromise;
    reportStatus('admin_initial_backup_status', initialEvent.status);
    assertThat(initialEvent.hasBearer && initialEvent.status === 200,
      'admin initial backup status read was not authenticated and successful');
    validateBackupStatus(initialPayload, null);
    await waitFor(() => hasVisibleSemanticText(
      adminPage, 'No CLI or server-triggered backup attempt recorded.'));
    reportBoolean('admin_initial_empty_state_rendered', true);

    setStage('run backup CLI and validate private sidecar');
    fs.writeFileSync(keyPath, backupKeyBytes, { flag: 'wx', mode: 0o600 });
    fs.chmodSync(keyPath, 0o600);
    if (process.platform !== 'win32') {
      assertThat((fs.statSync(keyPath).mode & 0o777) === 0o600,
        'temporary backup key did not have owner-only permissions');
    }
    runQuietCli([
      'backup', '--archive', archivePath, '--key-file', keyPath,
    ], serverEnv, 'backup CLI');
    assertThat(fs.statSync(archivePath).isFile() && fs.statSync(archivePath).size > 0,
      'backup CLI did not write an archive');
    const statusPath = path.join(dataDir, 'backup-status.json');
    const sidecarMetadata = fs.statSync(statusPath);
    if (process.platform !== 'win32') {
      assertThat((sidecarMetadata.mode & 0o777) === 0o600,
        'backup status sidecar did not have owner-only permissions');
    }
    const sidecar = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
    const archiveBytes = fs.statSync(archivePath).size;
    assertSidecar(sidecar, archiveBytes);
    reportBoolean('private_success_sidecar_valid', true);

    setStage('verify archive without changing active state');
    const beforeTree = snapshotTree(dataDir);
    const beforeArchiveDigest = crypto.createHash('sha256').update(fs.readFileSync(archivePath)).digest('hex');
    const beforeStaging = verifyStagingEntries();
    runQuietCli([
      'verify-backup', '--archive', archivePath, '--key-file', keyPath,
    ], serverEnv, 'verify-backup CLI');
    const afterTree = snapshotTree(dataDir);
    const afterArchiveDigest = crypto.createHash('sha256').update(fs.readFileSync(archivePath)).digest('hex');
    const afterStaging = verifyStagingEntries();
    assertThat(JSON.stringify(afterTree) === JSON.stringify(beforeTree),
      'verify-backup changed the active instance state tree');
    assertThat(afterArchiveDigest === beforeArchiveDigest,
      'verify-backup changed the source archive');
    assertThat(JSON.stringify(afterStaging) === JSON.stringify(beforeStaging),
      'verify-backup left a plaintext staging directory behind');
    reportBoolean('verify_backup_preserved_state_archive_and_temp_tree', true);

    setStage('refresh backup status in administrator UI');
    const refreshStart = adminEvents.length;
    await click(adminPage, 'Refresh backup status');
    const refreshEvent = await waitForEvent(adminEvents, backupStatusEvent(adminEvents, refreshStart));
    const refreshPayload = await refreshEvent.payloadPromise;
    reportStatus('admin_successful_backup_status', refreshEvent.status);
    assertThat(refreshEvent.hasBearer && refreshEvent.status === 200,
      'admin refreshed backup status read was not authenticated and successful');
    reportSuccessfulStatusShapeDiagnostics(
      await refreshEvent.jsonParseOkPromise, refreshPayload);
    const attempt = validateBackupStatus(refreshPayload, sidecar);
    assertThat(attempt.archive_bytes === archiveBytes, 'API archive byte count did not match the archive');
    setStage('verify successful backup result is rendered');
    await adminPage.waitForTimeout(300);
    const successMarkerDiagnostics = {
      settings_title: await hasVisibleSemanticText(adminPage, 'Workspace settings'),
      backup_card: await hasVisibleSemanticText(adminPage, 'Instance backup status'),
      succeeded_semantics: await hasVisibleSemanticText(adminPage, 'Succeeded'),
      succeeded_page_text: (await pageVisibleText(adminPage)).includes('Succeeded'),
      failed_semantics: await hasVisibleSemanticText(adminPage, 'Failed'),
      empty_state_semantics: await hasVisibleSemanticText(
        adminPage, 'No CLI or server-triggered backup attempt recorded.'),
      backup_load_error_semantics: await hasVisibleSemanticText(adminPage, '无法加载备份命令状态'),
      loading_label: await hasVisibleSemanticText(adminPage, '正在读取最近一次备份命令状态'),
      load_button: await hasVisibleSemanticText(adminPage, 'Load backup status'),
      refresh_button: await hasVisibleSemanticText(adminPage, 'Refresh backup status'),
      result_label: await hasVisibleSemanticText(adminPage, 'Result'),
      failure_category: await hasVisibleSemanticText(adminPage, 'Failure category'),
    };
    for (const [name, value] of Object.entries(successMarkerDiagnostics)) {
      reportBoolean(`ui_diagnostic_${name}`, value);
    }
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Succeeded'));
    setStage('verify attempted time is rendered');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Attempted at'));
    setStage('verify migration version is rendered');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Migration version'));
    setStage('verify archive byte count is rendered');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Archive bytes'));
    const renderedAdminText = await pageVisibleText(adminPage);
    const yearShownByBrowser = await adminPage.evaluate((value) =>
      String(new Date(value).getFullYear()), attempt.attempted_at);
    const formattedBytes = `${new Intl.NumberFormat('en-US').format(archiveBytes)} bytes`;
    setStage('verify rendered timestamp and metadata values');
    assertThat(renderedAdminText.includes(yearShownByBrowser),
      'admin UI did not render the backup attempt timestamp');
    assertThat(renderedAdminText.includes(String(attempt.migration_version)),
      'admin UI did not render the backup migration version');
    assertThat(renderedAdminText.includes(formattedBytes),
      'admin UI did not render the archive byte count');
    assertNoSecretOrPathFields(refreshPayload);
    assertNoLeaks(refreshPayload);
    assertNoLeaks(renderedAdminText);
    assertNoLeaks(await pageVisibleText(memberPage));
    reportBoolean('success_time_schema_and_bytes_rendered_without_sensitive_data', true);

    setStage('record fixed failure status through backup CLI');
    assertThat(!fs.existsSync(failedArchivePath) && !fs.existsSync(missingKeyPath),
      'failure fixture paths unexpectedly existed before the CLI attempt');
    const failureExitCode = runQuietCliFailure([
      'backup', '--archive', failedArchivePath, '--key-file', missingKeyPath,
    ], serverEnv, 'backup CLI with a missing key');
    console.log(`observed: backup_failure_cli_exit_code=${failureExitCode}`);
    assertThat(!fs.existsSync(failedArchivePath),
      'failed backup CLI unexpectedly created an archive');
    const failedSidecarMetadata = fs.statSync(statusPath);
    if (process.platform !== 'win32') {
      assertThat((failedSidecarMetadata.mode & 0o777) === 0o600,
        'failed backup status sidecar did not have owner-only permissions');
    }
    const failedSidecar = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
    assertFailedSidecar(failedSidecar);
    assertThat(failedSidecar.last_success_at === sidecar.last_success_at,
      'failed backup attempt did not preserve the prior success timestamp');
    reportBoolean('fixed_failure_sidecar_valid', true);

    setStage('refresh fixed failure status in administrator UI');
    const failureRefreshStart = adminEvents.length;
    await click(adminPage, 'Refresh backup status');
    const failureEvent = await waitForEvent(adminEvents, backupStatusEvent(adminEvents, failureRefreshStart));
    const failurePayload = await failureEvent.payloadPromise;
    reportStatus('admin_failed_backup_status', failureEvent.status);
    assertThat(failureEvent.hasBearer && failureEvent.status === 200,
      'admin failed backup status read was not authenticated and successful');
    const failedAttempt = validateFailedBackupStatus(failurePayload, failedSidecar);

    setStage('verify fixed failure state is rendered');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Failed'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Attempted at'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Failure category'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Backup command failed'));
    const renderedFailureText = await pageVisibleText(adminPage);
    const failedYearShownByBrowser = await adminPage.evaluate((value) =>
      String(new Date(value).getFullYear()), failedAttempt.attempted_at);
    assertThat(renderedFailureText.includes(failedYearShownByBrowser),
      'admin UI did not render the failed backup attempt timestamp');
    assertThat(!await hasVisibleSemanticText(adminPage, 'Succeeded') &&
        !await hasVisibleSemanticText(adminPage, 'Migration version') &&
        !await hasVisibleSemanticText(adminPage, 'Archive bytes'),
      'failed backup UI rendered success-only labels');
    const formattedSuccessBytes = `${new Intl.NumberFormat('en-US').format(archiveBytes)} bytes`;
    const migrationVersionValueVisible = await hasExactVisibleSemanticText(
      adminPage, String(sidecar.migration_version));
    const archiveBytesValueVisible = await hasExactVisibleSemanticText(
      adminPage, formattedSuccessBytes);
    reportBoolean('ui_migration_version_value_visible', migrationVersionValueVisible);
    reportBoolean('ui_archive_bytes_value_visible', archiveBytesValueVisible);
    assertThat(!migrationVersionValueVisible && !archiveBytesValueVisible,
      'failed backup UI rendered success-only version or byte values');
    assertNoSecretOrPathFields(failurePayload);
    assertNoLeaks(failurePayload);
    assertNoLeaks(renderedFailureText);
    reportBoolean('fixed_failure_time_and_category_rendered_without_success_metadata', true);

    setStage('verify valid archive preserves recorded failure status');
    const beforeFailureVerifyTree = snapshotTree(dataDir);
    const beforeFailureVerifyArchive = crypto.createHash('sha256')
      .update(fs.readFileSync(archivePath)).digest('hex');
    const beforeFailureVerifyStaging = verifyStagingEntries();
    runQuietCli([
      'verify-backup', '--archive', archivePath, '--key-file', keyPath,
    ], serverEnv, 'verify-backup CLI after backup failure');
    const afterFailureVerifyTree = snapshotTree(dataDir);
    const afterFailureVerifyArchive = crypto.createHash('sha256')
      .update(fs.readFileSync(archivePath)).digest('hex');
    const afterFailureVerifyStaging = verifyStagingEntries();
    assertThat(JSON.stringify(afterFailureVerifyTree) === JSON.stringify(beforeFailureVerifyTree),
      'verify-backup changed the active instance tree after a failed backup');
    assertThat(afterFailureVerifyArchive === beforeFailureVerifyArchive,
      'verify-backup changed the valid archive after a failed backup');
    assertThat(JSON.stringify(afterFailureVerifyStaging) === JSON.stringify(beforeFailureVerifyStaging),
      'verify-backup left staging files after a failed backup');
    const failureSidecarAfterVerify = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
    assertThat(JSON.stringify(failureSidecarAfterVerify) === JSON.stringify(failedSidecar),
      'verify-backup changed the recorded backup failure status');

    const postVerifyRefreshStart = adminEvents.length;
    await click(adminPage, 'Refresh backup status');
    const postVerifyEvent = await waitForEvent(
      adminEvents, backupStatusEvent(adminEvents, postVerifyRefreshStart));
    const postVerifyPayload = await postVerifyEvent.payloadPromise;
    reportStatus('admin_status_after_verify_backup', postVerifyEvent.status);
    assertThat(postVerifyEvent.hasBearer && postVerifyEvent.status === 200,
      'admin status read after verify-backup was not authenticated and successful');
    const postVerifyAttempt = postVerifyPayload?.last_attempt;
    const postVerifyBodyDiagnostics = await postVerifyEvent.responseBodyDiagnosticsPromise;
    console.log('post-verify backup status safe shape', JSON.stringify({
      responseJsonParsed: await postVerifyEvent.jsonParseOkPromise,
      responseContentTypeCategory: postVerifyBodyDiagnostics.contentTypeCategory,
      responseBodyCategory: postVerifyBodyDiagnostics.bodyCategory,
      responseBodyByteLength: postVerifyBodyDiagnostics.byteLength,
      rootKeysValid: exactKeys(postVerifyPayload, STATUS_KEYS),
      operationIsBackup: postVerifyPayload?.operation === 'backup',
      lastAttemptIsNull: postVerifyAttempt === null,
      lastAttemptIsObject: Boolean(postVerifyAttempt && typeof postVerifyAttempt === 'object' &&
        !Array.isArray(postVerifyAttempt)),
      lastAttemptKeysValid: exactKeys(postVerifyAttempt, ATTEMPT_KEYS),
      attemptedAtValid: validTimestamp(postVerifyAttempt?.attempted_at),
      resultCategory: postVerifyAttempt?.result === 'succeeded' ? 'succeeded' :
        postVerifyAttempt?.result === 'failed' ? 'failed' : 'other',
      migrationVersionIsNull: postVerifyAttempt?.migration_version === null,
      archiveBytesIsNull: postVerifyAttempt?.archive_bytes === null,
      failureCategory: postVerifyAttempt?.failure_category === null ? 'none' :
        postVerifyAttempt?.failure_category === 'backup_failed' ? 'backup_failed' : 'other',
    }));
    validateFailedBackupStatus(postVerifyPayload, failedSidecar);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Backup command failed'));
    const postVerifyUiText = await pageVisibleText(adminPage);
    assertThat(!await hasVisibleSemanticText(adminPage, 'Succeeded') &&
        !await hasVisibleSemanticText(adminPage, 'Migration version') &&
        !await hasVisibleSemanticText(adminPage, 'Archive bytes'),
      'admin UI failure state changed after verify-backup');
    assertNoLeaks(postVerifyPayload);
    assertNoLeaks(postVerifyUiText);
    reportBoolean('verify_backup_preserved_failure_status_and_active_tree', true);

    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    reportBoolean('browser_runtime_errors_absent', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
  console.log('WEB-BACKUP-STATUS-01 passed');
}

main().catch(async (error) => {
  const assertion = typeof error?.safeAssertion === 'string'
    ? error.safeAssertion
    : 'unclassified failure';
  console.error(`stage: failed (${stage}); assertion=${JSON.stringify(assertion)}; safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
