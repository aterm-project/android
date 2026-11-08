/*
 * WEB-BACKUP-REPLICATION-01: exercise configured bucket preflight, safe
 * replication status and replica restore source selection in two isolated Flutter Web profiles. The service
 * writes one real encrypted archive, copies it to a loopback-only S3 fixture,
 * then restores from the replica after the local source is removed. Output is
 * limited to fixed stages, HTTP statuses, and booleans.
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
const REPLICATION_PATH = '/api/v1/admin/backup-replication';
const REPLICATION_PREFLIGHT_PATH = '/api/v1/admin/backup-replication/preflight';
const RESTORE_SOURCES_PATH = '/api/v1/admin/restore-sources';
const JOBS_PATH = '/api/v1/admin/jobs';
const ADMIN_AUDIT_PATH = '/api/v1/admin/audit';
const LARGE_OPAQUE_OBJECT_BYTES = 64 * 1024 * 1024;
const OBJECT_UPLOAD_CHUNK_BYTES = 1024 * 1024;
const MULTIPART_THRESHOLD_BYTES = 64 * 1024 * 1024;
// Preserve private disposable state only when a developer explicitly opts in
// while diagnosing this acceptance locally. Never print its filesystem path.
const KEEP_TEMP_FIXTURE =
  process.env.ATERMIUS_KEEP_BACKUP_REPLICATION_FIXTURE === '1';
const REPLICATION_FAILURE_CATEGORIES = [
  'archive_unavailable',
  'credentials_invalid',
  'remote_unavailable',
  'remote_integrity_mismatch',
  'replication_failed',
];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let adminContext;
let memberContext;
let s3Fixture;
let bootstrapToken;
let invitationToken;
let adminUsername;
let adminPassword;
let adminAccountId;
let adminDeviceId;
let memberUsername;
let memberPassword;
let adminAccessToken;
let memberAccessToken;
let backupKey;
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = 0;
const events = { admin: [], member: [] };
const leakMarkers = [];
const serverMultipartPartErrorClasses = new Set();
const apiRequests = { admin: [], member: [] };
let serverDiagnosticTail = '';

function collectServerDiagnostics(chunk) {
  const lines = `${serverDiagnosticTail}${chunk.toString()}`.split(/\r?\n/);
  serverDiagnosticTail = lines.pop() || '';
  for (const line of lines) {
    const match = line.match(/operation="multipart_upload_part".*?error_class="(request_timeout|sdk_timeout|service|response|dispatch_or_construction)"/);
    if (match) serverMultipartPartErrorClasses.add(match[1]);
  }
}

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

function exactKeys(value, expected) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) ===
      JSON.stringify([...expected].sort());
}

function formattedAdminBytes(value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  const formatted = unit === 0 ? String(value) : amount.toFixed(1);
  return `${formatted} ${units[unit]} (${new Intl.NumberFormat('en-US').format(value)} bytes)`;
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  assertThat(leakMarkers.every((marker) => !marker || !serialized.includes(marker)),
    'response or rendered view exposed a private replication marker');
  assertThat(!/(?:SQLite|sqlx::|tokio::|panic at|stack trace|backtrace|internal server error|no such table)/i
    .test(serialized), 'response or rendered view exposed internal server details');
  if (tempRoot) {
    assertThat(!serialized.includes(tempRoot),
      'response or rendered view exposed the disposable data path');
  }
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
      // The fixture service may still be migrating or binding its loopback port.
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

const { startLocalS3Fixture } = require('./support/local_s3_fixture.cjs');

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
    leakMarkers.length = 0;
    if (backupKey) backupKey.fill(0);
    backupKey = undefined;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
    } catch (_) {
      cleanupFailed = true;
    }
    try {
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    }
    if (s3Fixture) {
      try {
        await s3Fixture.close();
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (tempRoot && KEEP_TEMP_FIXTURE) {
      reportBoolean('temporary_fixture_preserved_for_local_diagnosis', true);
    } else if (tempRoot) {
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
  const error = new Error('a visible form field did not retain its input');
  error.safeAssertion = `visible form field rejected input: ${label}`;
  throw error;
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const error = new Error('expected UI or API state did not appear');
  error.safeAssertion = 'expected UI or API state did not appear';
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
      const attributes = [...element.attributes]
        .map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`;
    }).join('\n');
    return visibleText.includes(expected);
  }, needle);
}

async function pageVisibleText(page) {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => {
        const attributes = [...element.attributes]
          .map((attribute) => attribute.value).join('\n');
        return `${element.textContent || ''}\n${attributes}`;
      }).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
}

async function waitForEvent(eventsForProfile, predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = eventsForProfile.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const error = new Error('expected authenticated browser API response did not arrive');
  error.safeAssertion = 'expected authenticated browser API response did not arrive';
  throw error;
}

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === REPLICATION_PREFLIGHT_PATH) return 'backup-replication-preflight';
    if (pathname === REPLICATION_PATH) return 'backup-replication';
    if (pathname === RESTORE_SOURCES_PATH) return 'restore-sources';
    if (pathname === JOBS_PATH) return 'admin-jobs';
    if (pathname === ADMIN_AUDIT_PATH) return 'admin-audit';
  } catch (_) {
    // Ignore browser-internal requests.
  }
  return null;
}

function trackApi(page, eventList, requestList) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    const url = new URL(request.url());
    let body = null;
    if ((route === 'admin-jobs' || route === 'backup-replication-preflight') &&
        request.method() === 'POST') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    const metadata = {
      route,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      query: Object.fromEntries(url.searchParams.entries()),
      body,
    };
    requestList.push(metadata);
    byRequest.set(request, metadata);
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    eventList.push({
      ...metadata,
      status: response.status(),
      sequence: eventList.length,
      payloadPromise: response.json().catch(() => null),
    });
  });
}

async function configurePage(page, baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() =>
    document.querySelectorAll('flt-semantics').length > 0), 15000);
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
  leakMarkers.push(token);
  return token;
}

async function createAdminProfile(page, baseUrl, eventList) {
  setStage('configure administrator browser profile');
  await configurePage(page, baseUrl);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Backup replication administrator');
  await fill(page, 'First Vault', 'Backup replication administrator');
  const start = eventList.length;
  setStage('submit administrator registration');
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  setStage('wait for administrator registration');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(eventList,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string' &&
      UUID_PATTERN.test(payload?.account_id || '') &&
      UUID_PATTERN.test(payload?.device_id || ''),
    'administrator registration response was incomplete');
  leakMarkers.push(payload.access_token);
  adminAccountId = payload.account_id;
  adminDeviceId = payload.device_id;
  return payload.access_token;
}

async function createMemberProfile(page, baseUrl, eventList) {
  await configurePage(page, baseUrl);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Backup replication member');
  await fill(page, 'First Vault', 'Backup replication member');
  const start = eventList.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(eventList,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string',
    'invited member registration response was incomplete');
  leakMarkers.push(payload.access_token);
  return payload.access_token;
}

async function directApi(baseUrl, method, pathname, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertNoLeaks(payload);
  return { status: response.status, payload };
}

async function createLargeOpaqueVaultObject(baseUrl, token) {
  const vaultList = await directApi(baseUrl, 'GET', '/api/v1/vaults', { token });
  assertThat(vaultList.status === 200 && Array.isArray(vaultList.payload?.vaults),
    'administrator Vault list was unavailable for multipart fixture setup');
  const vault = vaultList.payload.vaults.find((candidate) =>
    UUID_PATTERN.test(candidate?.vault_id || '') && candidate.status === 'active' &&
    candidate.can_write === true);
  assertThat(vault, 'administrator had no writable Vault for multipart fixture setup');

  // Completed Vault objects are opaque bytes on the server. Random bytes avoid
  // compressibility so the real encrypted instance archive crosses the S3
  // multipart threshold. The object is uploaded in bounded one-MiB chunks.
  const bytes = crypto.randomBytes(LARGE_OPAQUE_OBJECT_BYTES);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  const objectId = crypto.randomUUID();
  const init = await directApi(baseUrl, 'POST',
    `/api/v1/vaults/${vault.vault_id}/uploads/init`, {
      token,
      body: { object_id: objectId, size: bytes.length, sha256: digest },
    });
  assertThat(init.status === 200 && UUID_PATTERN.test(init.payload?.upload_id || '') &&
      init.payload.chunk_size === OBJECT_UPLOAD_CHUNK_BYTES,
  'opaque Vault object upload reservation was invalid');
  const uploadId = init.payload.upload_id;

  try {
    const chunkCount = Math.ceil(bytes.length / OBJECT_UPLOAD_CHUNK_BYTES);
    for (let index = 0; index < chunkCount; index += 1) {
      const start = index * OBJECT_UPLOAD_CHUNK_BYTES;
      const chunk = bytes.subarray(start,
        Math.min(start + OBJECT_UPLOAD_CHUNK_BYTES, bytes.length));
      const response = await fetch(
        `${baseUrl}/api/v1/uploads/${uploadId}/chunks/${index}`,
        {
          method: 'PUT',
          headers: {
            authorization: `Bearer ${token}`,
            'content-type': 'application/octet-stream',
          },
          body: chunk,
          signal: AbortSignal.timeout(30000),
        },
      );
      const receipt = await response.json().catch(() => null);
      assertThat(response.status === 200 && exactKeys(receipt, [
        'upload_id', 'index', 'sha256', 'already_uploaded',
      ]) && receipt.upload_id === uploadId && receipt.index === index &&
          receipt.sha256 === crypto.createHash('sha256').update(chunk).digest('hex') &&
          receipt.already_uploaded === false,
      'opaque Vault object chunk was not durably accepted');
      assertNoLeaks(receipt);
    }

    const completion = await directApi(baseUrl, 'POST',
      `/api/v1/uploads/${uploadId}/complete`, { token });
    assertThat(completion.status === 200 && exactKeys(completion.payload, [
      'object_id', 'size', 'sha256', 'chunks',
    ]) && completion.payload.object_id === objectId &&
        completion.payload.size === bytes.length && completion.payload.sha256 === digest &&
        Array.isArray(completion.payload.chunks) &&
        completion.payload.chunks.length === chunkCount,
    'opaque Vault object completion did not preserve its size and digest');

    const probeLength = 32;
    const probe = await fetch(
      `${baseUrl}/api/v1/vaults/${vault.vault_id}/objects/${objectId}`,
      {
        headers: {
          authorization: `Bearer ${token}`,
          range: `bytes=0-${probeLength - 1}`,
        },
        signal: AbortSignal.timeout(15000),
      },
    );
    const probeBytes = Buffer.from(await probe.arrayBuffer());
    assertThat(probe.status === 206 &&
        probe.headers.get('content-range') === `bytes 0-${probeLength - 1}/${bytes.length}` &&
        probeBytes.equals(bytes.subarray(0, probeLength)),
    'completed opaque Vault object could not be read back intact');
    reportBoolean('large_opaque_vault_object_uploaded_and_verified', true);
    return bytes.length;
  } finally {
    bytes.fill(0);
  }
}

function validateReplicationStatus(payload) {
  const validShape = exactKeys(payload, [
    'operation', 'configured', 'pending_count', 'latest_attempt',
  ]) && payload.operation === 'backup_replication' &&
      typeof payload.configured === 'boolean' &&
      Number.isInteger(payload.pending_count) && payload.pending_count >= 0 &&
      (payload.latest_attempt === null ||
        exactKeys(payload.latest_attempt, [
          'archive_id', 'state', 'attempted_at', 'completed_at', 'archive_bytes',
          'failure_category',
        ]));
  if (!validShape) {
    reportBoolean('replication_status_payload_is_object',
      payload !== null && typeof payload === 'object' && !Array.isArray(payload));
    reportBoolean('replication_status_payload_has_expected_keys', exactKeys(payload, [
      'operation', 'configured', 'pending_count', 'latest_attempt',
    ]));
    reportBoolean('replication_status_operation_is_expected',
      payload?.operation === 'backup_replication');
    reportBoolean('replication_status_configured_is_boolean',
      typeof payload?.configured === 'boolean');
    reportBoolean('replication_status_pending_count_is_nonnegative_integer',
      Number.isInteger(payload?.pending_count) && payload.pending_count >= 0);
    reportBoolean('replication_status_latest_attempt_is_null_or_expected_object',
      payload?.latest_attempt === null || exactKeys(payload?.latest_attempt, [
        'archive_id', 'state', 'attempted_at', 'completed_at', 'archive_bytes',
        'failure_category',
      ]));
  }
  assertThat(validShape, 'backup replication status response shape was invalid');
  if (payload.latest_attempt !== null) {
    const attempt = payload.latest_attempt;
    const validTimestamp = (value) => typeof value === 'string' &&
      !Number.isNaN(Date.parse(value)) &&
      /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(value);
    assertThat(UUID_PATTERN.test(attempt.archive_id) &&
        ['pending_archive', 'pending', 'running', 'retry_wait', 'succeeded',
          'interrupted', 'failed'].includes(attempt.state) &&
        validTimestamp(attempt.attempted_at) &&
        (attempt.completed_at === null || validTimestamp(attempt.completed_at)) &&
        (attempt.archive_bytes === null ||
          (Number.isInteger(attempt.archive_bytes) && attempt.archive_bytes > 0)) &&
        (attempt.failure_category === null ||
          ['archive_unavailable', 'credentials_invalid', 'remote_unavailable',
            'remote_integrity_mismatch', 'replication_failed'].includes(attempt.failure_category)),
    'backup replication attempt metadata was invalid');
  }
  assertNoLeaks(payload);
  return payload;
}

function validateRestoreSources(payload) {
  assertThat(exactKeys(payload, ['sources', 'total']) &&
      Array.isArray(payload.sources) && Number.isInteger(payload.total) &&
      payload.total >= payload.sources.length,
    'restore source response shape was invalid');
  for (const source of payload.sources) {
    assertThat(exactKeys(source, [
      'archive_id', 'created_at', 'archive_bytes', 'origin', 'source',
    ]) && UUID_PATTERN.test(source.archive_id) &&
        typeof source.created_at === 'string' && !Number.isNaN(Date.parse(source.created_at)) &&
        Number.isInteger(source.archive_bytes) && source.archive_bytes > 0 &&
        ['manual', 'scheduled'].includes(source.origin) &&
        ['local', 'replica'].includes(source.source),
    'restore source metadata was invalid');
  }
  assertNoLeaks(payload);
  return payload.sources;
}

function validateAdminAuditPage(payload) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
  'instance audit page shape was invalid');
  assertNoLeaks(payload);
  const eventFields = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action',
    'resource_type', 'resource_id', 'result', 'occurred_at', 'source',
  ];
  for (const event of payload.events) {
    assertThat(exactKeys(event, eventFields) && /^\d+$/.test(event.event_id) &&
        event.scope === 'instance' &&
        (event.actor_user_id === null || UUID_PATTERN.test(event.actor_user_id)) &&
        (event.actor_device_id === null || UUID_PATTERN.test(event.actor_device_id)) &&
        typeof event.action === 'string' && typeof event.resource_type === 'string' &&
        (event.resource_id === null || /^[0-9a-f]{64}$/.test(event.resource_id)) &&
        ['success', 'failure'].includes(event.result) &&
        ['api', 'maintenance'].includes(event.source) &&
        typeof event.occurred_at === 'string' && !Number.isNaN(Date.parse(event.occurred_at)),
    'instance audit event DTO or privacy metadata was invalid');
  }
  return payload.events;
}

function validateFailedRestoreAuditLifecycle(payload, rawJobId) {
  const restoreEvents = validateAdminAuditPage(payload).filter((event) =>
    event.action.startsWith('admin.restore_'));
  const failedTerminals = restoreEvents.filter((event) =>
    event.action === 'admin.restore_failed' && event.result === 'failure');
  assertThat(failedTerminals.length === 1,
    'restore audit feed did not contain exactly one failed restore terminal event');
  const resourceId = failedTerminals[0].resource_id;
  const expectedStages = [
    ['admin.restore_requested', 'success'],
    ['admin.restore_started', 'success'],
    ['admin.restore_failed', 'failure'],
  ];
  const lifecycle = expectedStages.map(([action, result]) => {
    const matches = restoreEvents.filter((event) => event.resource_id === resourceId &&
      event.action === action && event.result === result);
    assertThat(matches.length === 1,
      `failed restore audit lifecycle omitted or duplicated ${action}`);
    const event = matches[0];
    assertThat(event.actor_user_id === adminAccountId &&
        event.actor_device_id === adminDeviceId &&
        event.resource_type === 'admin_job' &&
        typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id) &&
        event.resource_id !== rawJobId && event.source === 'api' &&
        event.result === result && !JSON.stringify(event).includes(rawJobId),
    'failed restore audit actor, resource HMAC, source, result or privacy was invalid');
    return event;
  });
  const sameFailedJobEvents = restoreEvents.filter((event) => event.resource_id === resourceId);
  assertThat(sameFailedJobEvents.length === expectedStages.length &&
      BigInt(lifecycle[0].event_id) < BigInt(lifecycle[1].event_id) &&
      BigInt(lifecycle[1].event_id) < BigInt(lifecycle[2].event_id),
  'failed restore audit lifecycle was not exact or ordered');
  return lifecycle;
}

function assertNoReplicaFailureDetails(value) {
  assertNoLeaks(value);
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  assertThat(!/(?:NoSuchKey|HeadObject|GetObject|x-amz-[a-z-]+|AmazonS3|s3:\/\/|Credential=)/i
    .test(serialized),
  'missing-replica restore exposed provider diagnostics');
}

function readBusinessDatabaseDigest(databasePath) {
  const code = [
    'import hashlib, json, sqlite3, sys',
    "connection = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True, timeout=10)",
    'tables = (',
    "    'instance_meta', 'users', 'auth_credentials', 'devices', 'sessions',",
    "    'refresh_history', 'vaults', 'vault_members', 'vault_key_envelopes',",
    "    'vault_counters', 'record_heads', 'record_versions', 'change_events',",
    "    'op_receipts', 'batch_receipts', 'record_graveyard', 'snapshots',",
    "    'conflicts', 'uploads', 'upload_chunks', 'blob_objects',",
    "    'object_references', 'invitations', 'membership_manifests',",
    ')',
    'def stable(value):',
    '    if isinstance(value, bytes):',
    '        return {"bytes_sha256": hashlib.sha256(value).hexdigest(), "bytes_length": len(value)}',
    '    return value',
    'snapshot = {}',
    'for table in tables:',
    '    rows = connection.execute("SELECT * FROM " + chr(34) + table + chr(34)).fetchall()',
    '    stable_rows = [tuple(stable(value) for value in row) for row in rows]',
    '    snapshot[table] = sorted(stable_rows, key=repr)',
    'encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()',
    'summary = {"sha256": hashlib.sha256(encoded).hexdigest(), "table_count": len(tables)}',
    'print(json.dumps(summary, sort_keys=True, separators=(",", ":")))',
    'connection.close()',
  ].join('\n');
  const result = spawnSync('python3', ['-c', code, databasePath], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 15000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only live business data digest could not be computed');
  let summary;
  try {
    summary = JSON.parse((result.stdout || '').trim());
  } catch (_) {
    summary = null;
  }
  result.stdout = '';
  assertThat(exactKeys(summary, ['sha256', 'table_count']) &&
      /^[0-9a-f]{64}$/.test(summary.sha256) && summary.table_count === 24,
    'read-only live business data digest summary was invalid');
  return summary;
}

function validateJob(job, { action, archiveId, archiveSource }) {
  assertThat(exactKeys(job, [
    'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status',
    'requested_at', 'started_at', 'finished_at', 'result_code',
    'restore_stage_status',
  ]) && UUID_PATTERN.test(job.job_id) && UUID_PATTERN.test(job.request_id) &&
      job.action === action && (job.archive_id === archiveId) &&
      job.archive_source === archiveSource &&
      ['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
  'admin job receipt did not preserve its selected archive source');
  assertThat(action === 'restore' && job.status === 'succeeded'
    ? ['ready', 'discarded'].includes(job.restore_stage_status)
    : job.restore_stage_status === null,
  'admin job receipt had an invalid isolated restore-copy lifecycle status');
  assertNoLeaks(job);
  return job;
}

function validateAdminJobsPage(page) {
  const expectedActions = [
    'maintenance', 'backup', 'restore', 'backup_status', 'backup_replication',
    'backup_schedule', 'restore_stage_discard', 'restore_replica',
  ];
  return exactKeys(page, ['jobs', 'supported_actions', 'total']) &&
    Array.isArray(page.jobs) && Number.isSafeInteger(page.total) && page.total >= 0 &&
    Array.isArray(page.supported_actions) &&
    JSON.stringify(page.supported_actions) === JSON.stringify(expectedActions);
}

async function waitForAdminJob(baseUrl, token, jobId, { terminal = false } = {}) {
  const deadline = Date.now() + 90000;
  let lastJob = null;
  while (Date.now() < deadline) {
    const page = await directApi(baseUrl, 'GET', `${JOBS_PATH}?limit=100&offset=0`, { token });
    const validPage = page.status === 200 && validateAdminJobsPage(page.payload);
    assertThat(validPage,
      `admin job polling response was invalid (status ${page.status}; keys ${
        page.payload && typeof page.payload === 'object'
          ? Object.keys(page.payload).sort().join(',') : 'non-object'})`);
    lastJob = page.payload.jobs.find((item) => item.job_id === jobId) || null;
    if (lastJob && (!terminal ||
        ['succeeded', 'failed', 'interrupted'].includes(lastJob.status))) return lastJob;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error(lastJob ? 'admin job did not reach a terminal state' :
    'admin job did not appear in its durable list');
}

async function waitForReplicaStatus(baseUrl, token, archiveId, archiveBytes) {
  const configuredTimeout = Number(process.env.ATERMIUS_BACKUP_REPLICATION_STATUS_TIMEOUT_MS);
  const timeoutMs = Number.isInteger(configuredTimeout) &&
      configuredTimeout >= 10000 && configuredTimeout <= 150000
    ? configuredTimeout : 150000;
  const deadline = Date.now() + timeoutMs;
  let latest = null;
  while (Date.now() < deadline) {
    const result = await directApi(baseUrl, 'GET', REPLICATION_PATH, { token });
    assertThat(result.status === 200, 'administrator replication status poll failed');
    latest = validateReplicationStatus(result.payload);
    if (latest.latest_attempt?.archive_id === archiveId &&
        latest.latest_attempt.state === 'succeeded' && latest.pending_count === 0) {
      assertThat(latest.configured && latest.latest_attempt.archive_bytes === archiveBytes &&
          latest.latest_attempt.completed_at !== null &&
          latest.latest_attempt.failure_category === null,
      'replication success metadata did not match the local encrypted archive');
      return latest;
    }
    if (latest.latest_attempt?.archive_id === archiveId &&
        ['failed', 'interrupted'].includes(latest.latest_attempt.state)) {
      reportBoolean(`replication_terminal_state_${latest.latest_attempt.state}`, true);
      for (const category of [
        'archive_unavailable',
        'credentials_invalid',
        'remote_unavailable',
        'remote_integrity_mismatch',
        'replication_failed',
      ]) {
        reportBoolean(`replication_failure_category_${category}`,
          latest.latest_attempt.failure_category === category);
      }
      throw new Error('replication worker reported a safe terminal failure');
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  if (latest?.latest_attempt?.archive_id === archiveId) {
    reportBoolean(`replication_final_state_${latest.latest_attempt.state}`, true);
    for (const category of [
      'archive_unavailable',
      'credentials_invalid',
      'remote_unavailable',
      'remote_integrity_mismatch',
      'replication_failed',
    ]) {
      reportBoolean(`replication_failure_category_${category}`,
        latest.latest_attempt.failure_category === category);
    }
    for (const counter of [
      'httpRequestCount', 'clientErrorCount',
      'headCount', 'getCount', 'putCount', 'servicePutCount',
      'conditionalServicePutCount', 'unconditionalServicePutCount',
      'multipartCreateCount', 'multipartPartCount',
      'multipartCompleteCount', 'conditionalMultipartCompleteCount',
      'unconditionalMultipartCompleteCount', 'conditionalMultipartConflictCount',
      'multipartAbortCount', 'malformedUploadCount', 'wrongBucketCount',
      'unauthorizedRequestCount',
    ]) {
      reportBoolean(`replica_fixture_${counter}_${s3Fixture.stats[counter]}`, true);
    }
    reportBoolean(`replica_fixture_object_count_${s3Fixture.objects.size}`, true);
    for (const errorClass of [
      'request_timeout', 'sdk_timeout', 'service', 'response',
      'dispatch_or_construction',
    ]) {
      reportBoolean(`server_multipart_part_error_${errorClass}`,
        serverMultipartPartErrorClasses.has(errorClass));
    }
  }
  throw new Error(latest?.latest_attempt?.state === 'failed'
    ? 'replication worker reported a safe terminal failure'
    : 'replication worker did not report a completed replica');
}

async function waitForJobEvent(eventList, predicate, startSequence = 0, timeoutMs = 20000) {
  return waitForEvent(eventList,
    (event) => event.sequence >= startSequence && predicate(event), timeoutMs);
}

async function verifyBucketPreflightFailureUi(page, { status, code, expectedText }) {
  const matcher = (url) => new URL(url).pathname === REPLICATION_PREFLIGHT_PATH;
  const serverMessage = code === 'BACKUP_REPLICATION_NOT_CONFIGURED'
    ? 'encrypted backup replication is not configured'
    : 'configured backup bucket access could not be verified';
  const handler = (route) => route.fulfill({
    status,
    contentType: 'application/json',
    body: JSON.stringify({ error: { code, message: serverMessage } }),
  });
  await page.route(matcher, handler);
  try {
    const requestStart = apiRequests.admin.length;
    const eventStart = events.admin.length;
    await click(page, 'Check bucket access');
    const event = await waitForJobEvent(events.admin,
      (candidate) => candidate.route === 'backup-replication-preflight' &&
        candidate.method === 'POST', eventStart);
    await waitFor(() => hasVisibleSemanticText(page, expectedText));
    const payload = await event.payloadPromise;
    const visible = await pageVisibleText(page);
    const request = apiRequests.admin[requestStart];
    assertThat(event.status === status && event.hasBearer &&
        requestStart + 1 === apiRequests.admin.length && request?.hasBearer &&
        request.method === 'POST' && request.route === 'backup-replication-preflight' &&
        exactKeys(request.query, []) && exactKeys(event.query, []) &&
        exactKeys(request.body, []) && exactKeys(event.body, []) &&
        exactKeys(payload, ['error']) && payload.error?.code === code &&
        payload.error?.message === serverMessage &&
        !visible.includes(code) && !visible.includes(serverMessage) &&
        s3Fixture.stats.bucketHeadCount === 1,
    `Settings did not safely render the fixed bucket preflight HTTP ${status} outcome`);
    reportBoolean(`admin_preflight_http_${status}_fixed_error_rendered`, true);
  } finally {
    await page.unroute(matcher, handler);
  }
}

async function verifyBucketPreflightTimeoutUi(page) {
  const requestStart = apiRequests.admin.length;
  const eventStart = events.admin.length;
  s3Fixture.delayNextBucketHead(20000);
  const startedAt = Date.now();
  await click(page, 'Check bucket access');
  const event = await waitForJobEvent(events.admin,
    (candidate) => candidate.route === 'backup-replication-preflight' &&
      candidate.method === 'POST', eventStart, 25000);
  const elapsedMs = Date.now() - startedAt;
  await waitFor(() => hasVisibleSemanticText(page,
    'The server could not verify access to the configured S3 backup bucket.'));
  const payload = await event.payloadPromise;
  const visible = await pageVisibleText(page);
  const request = apiRequests.admin[requestStart];
  assertThat(event.status === 502 && event.hasBearer &&
      requestStart + 1 === apiRequests.admin.length && request?.hasBearer &&
      request.method === 'POST' && request.route === 'backup-replication-preflight' &&
      exactKeys(request.query, []) && exactKeys(event.query, []) &&
      exactKeys(request.body, []) && exactKeys(event.body, []) &&
      exactKeys(payload, ['error']) &&
      payload.error?.code === 'BACKUP_REPLICATION_CHECK_FAILED' &&
      payload.error?.message === 'configured backup bucket access could not be verified' &&
      elapsedMs >= 14000 && elapsedMs < 17500 &&
      !visible.includes('BACKUP_REPLICATION_CHECK_FAILED') &&
      !visible.includes('configured backup bucket access could not be verified') &&
      s3Fixture.stats.bucketHeadCount === 2,
  'delayed bucket Head did not time out within the fixed bounded response');
  reportBoolean('admin_bucket_access_head_timeout_bounded_and_redacted', true);
  reportBoolean('admin_bucket_access_timeout_returned_fixed_502', true);
  console.log(`assert: admin_bucket_access_head_timeout_elapsed_ms=${elapsedMs}`);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
      'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-backup-replication-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    const archiveDir = path.join(tempRoot, 'archives');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    fs.chmodSync(archiveDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const keyPath = path.join(tempRoot, 'operator-backup.key');
    const credentialsPath = path.join(tempRoot, 'replica-credentials.json');
    backupKey = crypto.randomBytes(32);
    fs.writeFileSync(keyPath, backupKey, { flag: 'wx', mode: 0o600 });
    fs.chmodSync(keyPath, 0o600);

    const suffix = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    const bucket = `replica-fixture-${suffix}`;
    const prefix = `replica-prefix-${suffix}`;
    const accessKeyId = `fixture-access-${suffix}`;
    const secretAccessKey = `fixture-secret-${crypto.randomBytes(24).toString('hex')}`;
    fs.writeFileSync(credentialsPath, JSON.stringify({
      access_key_id: accessKeyId,
      secret_access_key: secretAccessKey,
    }), { flag: 'wx', mode: 0o600 });
    fs.chmodSync(credentialsPath, 0o600);
    if (process.platform !== 'win32') {
      assertThat((fs.statSync(keyPath).mode & 0o777) === 0o600 &&
          (fs.statSync(credentialsPath).mode & 0o777) === 0o600,
      'private backup fixture file permissions were not enforced');
    }

    s3Fixture = await startLocalS3Fixture({ bucket, accessKeyId });
    const endpointUrl = s3Fixture.endpointUrl;
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const adminSuffix = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-backup-replication-admin-${adminSuffix}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-backup-replication-member-${adminSuffix}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakMarkers.push(
      tempRoot,
      dataDir,
      archiveDir,
      databasePath,
      keyPath,
      credentialsPath,
      backupKey.toString('hex'),
      backupKey.toString('base64'),
      bucket,
      prefix,
      endpointUrl,
      accessKeyId,
      secretAccessKey,
      adminPassword,
      memberPassword,
    );

    const cleanEnv = Object.fromEntries(Object.entries(process.env)
      .filter(([key]) => !key.startsWith('ATERMIUS_') && !key.startsWith('AWS_')));
    const serverEnv = {
      ...cleanEnv,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_BACKUP_ARCHIVE_DIR: archiveDir,
      ATERMIUS_BACKUP_KEY_FILE: keyPath,
      ATERMIUS_BACKUP_S3_BUCKET: bucket,
      ATERMIUS_BACKUP_S3_REGION: 'us-east-1',
      ATERMIUS_BACKUP_S3_CREDENTIALS_FILE: credentialsPath,
      ATERMIUS_BACKUP_S3_ENDPOINT_URL: endpointUrl,
      ATERMIUS_BACKUP_S3_PREFIX: prefix,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      AWS_EC2_METADATA_DISABLED: 'true',
      RUST_LOG: 'atermius_server::backup_replication=warn',
    };

    setStage('start disposable backup and loopback replica fixtures');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    serverProcess.stderr.on('data', collectServerDiagnostics);
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated administrator and member browser profiles');
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    memberContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    const adminPage = await adminContext.newPage();
    const memberPage = await memberContext.newPage();
    adminPage.on('pageerror', () => { pageErrors += 1; });
    memberPage.on('pageerror', () => { pageErrors += 1; });
    trackApi(adminPage, events.admin, apiRequests.admin);
    trackApi(memberPage, events.member, apiRequests.member);

    setStage('register allowlisted administrator and separately invited member');
    adminAccessToken = await createAdminProfile(adminPage, baseUrl, events.admin);
    invitationToken = cliToken([
      'create-account-invite', '--username', memberUsername,
    ], serverEnv, 'member invitation');
    memberAccessToken = await createMemberProfile(memberPage, baseUrl, events.member);
    reportBoolean('isolated_admin_and_member_profiles_registered', true);

    setStage('verify member backup replication and restore controls are hidden');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    assertThat(!await hasVisibleSemanticText(memberPage, 'Off-site encrypted backup copies') &&
        !await hasVisibleSemanticText(memberPage, 'Load replication status') &&
        !await hasVisibleSemanticText(memberPage, 'Check bucket access') &&
        !await hasVisibleSemanticText(memberPage, 'Prepare isolated restore copy'),
    'non-admin Settings exposed replication or restore controls');
    assertThat(!events.member.some((event) =>
      ['backup-replication', 'backup-replication-preflight', 'restore-sources']
        .includes(event.route)),
    'non-admin browser issued a hidden replication, preflight, or restore-source request');
    assertThat(!apiRequests.member.some((request) =>
      request.route === 'backup-replication-preflight'),
    'non-admin browser issued a hidden bucket-access preflight request');
    assertThat(s3Fixture.stats.bucketHeadCount === 0,
      'non-admin Settings must not probe the configured backup bucket');
    const unauthenticatedStatus = await directApi(baseUrl, 'GET', REPLICATION_PATH);
    reportStatus('unauthenticated_replication_status', unauthenticatedStatus.status);
    assertThat(unauthenticatedStatus.status === 401,
      'unauthenticated replication status read was not denied');
    const memberStatus = await directApi(baseUrl, 'GET', REPLICATION_PATH,
      { token: memberAccessToken });
    reportStatus('member_replication_status', memberStatus.status);
    assertThat(memberStatus.status === 403,
      'non-admin replication status read was not denied');
    const memberSources = await directApi(baseUrl, 'GET',
      `${RESTORE_SOURCES_PATH}?limit=100&offset=0`, { token: memberAccessToken });
    reportStatus('member_restore_source_list', memberSources.status);
    assertThat(memberSources.status === 403,
      'non-admin restore source list was not denied');
    const memberRestore = await directApi(baseUrl, 'POST', JOBS_PATH, {
      token: memberAccessToken,
      body: {
        request_id: crypto.randomUUID(),
        action: 'restore',
        archive_id: crypto.randomUUID(),
        archive_source: 'replica',
      },
    });
    reportStatus('member_restore_job_create', memberRestore.status);
    assertThat(memberRestore.status === 403,
      'non-admin replica restore submission was not denied');
    reportBoolean('member_replication_controls_hidden_and_admin_apis_denied', true);

    setStage('verify administrator safe replication status DTO and Settings card');
    const initialAdminStatus = await directApi(baseUrl, 'GET', REPLICATION_PATH,
      { token: adminAccessToken });
    reportStatus('admin_initial_replication_status', initialAdminStatus.status);
    assertThat(initialAdminStatus.status === 200,
      'administrator replication status read did not succeed');
    const initialStatus = validateReplicationStatus(initialAdminStatus.payload);
    assertThat(initialStatus.configured && initialStatus.latest_attempt === null,
      'configured replica did not begin in a safe empty state');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Off-site encrypted backup copies'));
    assertThat(await hasVisibleSemanticText(adminPage,
      'HeadBucket only; it does not verify uploads, multipart operations, restore, or provider-wide interoperability.'),
    'administrator Settings did not show the access-check capability limits');
    const preflightStart = events.admin.length;
    await click(adminPage, 'Check bucket access');
    const preflightEvent = await waitForJobEvent(events.admin,
      (event) => event.route === 'backup-replication-preflight' &&
        event.method === 'POST', preflightStart);
    reportStatus('admin_backup_replication_preflight', preflightEvent.status);
    await waitFor(() => hasVisibleSemanticText(adminPage,
      'Bucket access verified with HeadBucket.'));
    const preflightEvents = events.admin.filter((event) =>
      event.route === 'backup-replication-preflight' && event.method === 'POST');
    const preflightRequests = apiRequests.admin.filter((request) =>
      request.route === 'backup-replication-preflight' && request.method === 'POST');
    const preflightPayload = await preflightEvent.payloadPromise;
    assertThat(preflightEvent.status === 200 && preflightEvent.hasBearer &&
        exactKeys(preflightEvent.query, []) && preflightEvents.length === 1 &&
        preflightRequests.length === 1 && preflightRequests[0].hasBearer &&
        exactKeys(preflightRequests[0].query, []) &&
        exactKeys(preflightRequests[0].body, []) &&
        exactKeys(preflightEvent.body, []) &&
        JSON.stringify(preflightEvent.body) === '{}' &&
        exactKeys(preflightPayload, ['check', 'result']) &&
        preflightPayload.check === 'bucket_access' &&
        preflightPayload.result === 'passed',
    'administrator Settings did not issue exactly one authenticated empty preflight request or receive the fixed DTO');
    assertThat(s3Fixture.stats.bucketHeadCount === 1 &&
        s3Fixture.stats.headCount === 0 && s3Fixture.stats.putCount === 0,
      'administrator preflight must perform exactly one bucket-level HeadBucket check');
    assertNoLeaks(preflightPayload);
    reportBoolean('admin_bucket_access_preflight_used_fixed_authenticated_contract', true);
    reportBoolean('admin_bucket_access_preflight_limits_visible', true);
    const initialStatusStart = events.admin.length;
    await click(adminPage, 'Load replication status');
    const initialStatusEvent = await waitForJobEvent(events.admin,
      (event) => event.route === 'backup-replication' && event.method === 'GET',
      initialStatusStart);
    reportStatus('admin_settings_replication_status', initialStatusEvent.status);
    assertThat(initialStatusEvent.status === 200 && initialStatusEvent.hasBearer,
      'administrator Settings did not load authenticated replication status');
    const initialUiStatus = validateReplicationStatus(await initialStatusEvent.payloadPromise);
    assertThat(initialUiStatus.latest_attempt === null,
      'empty replication status in Settings had an unexpected attempt');
    const initialAdminText = await pageVisibleText(adminPage);
    assertNoLeaks(initialAdminText);
    reportBoolean('admin_empty_replication_status_rendered_without_private_values', true);
    await verifyBucketPreflightFailureUi(adminPage, {
      status: 502,
      code: 'BACKUP_REPLICATION_CHECK_FAILED',
      expectedText: 'The server could not verify access to the configured S3 backup bucket.',
    });
    await verifyBucketPreflightFailureUi(adminPage, {
      status: 503,
      code: 'BACKUP_REPLICATION_NOT_CONFIGURED',
      expectedText: 'No S3 backup bucket is configured on the server.',
    });
    await verifyBucketPreflightTimeoutUi(adminPage);

    setStage('upload large opaque Vault object for multipart backup coverage');
    const opaqueVaultObjectBytes = await createLargeOpaqueVaultObject(
      baseUrl, adminAccessToken,
    );
    assertThat(opaqueVaultObjectBytes === LARGE_OPAQUE_OBJECT_BYTES,
      'large opaque Vault object did not reach the multipart fixture size');

    setStage('create one real encrypted backup archive');
    const backupRequestId = crypto.randomUUID();
    const backupAccepted = await directApi(baseUrl, 'POST', JOBS_PATH, {
      token: adminAccessToken,
      body: { request_id: backupRequestId, action: 'backup' },
    });
    reportStatus('admin_backup_job_create', backupAccepted.status);
    assertThat(backupAccepted.status === 202 &&
        exactKeys(backupAccepted.payload, ['job']),
    'administrator backup fixture was not accepted');
    const acceptedBackupJob = validateJob(backupAccepted.payload.job, {
      action: 'backup', archiveId: null, archiveSource: null,
    });
    assertThat(acceptedBackupJob.request_id === backupRequestId,
      'backup fixture did not preserve its idempotent request identifier');
    const backupTerminal = await waitForAdminJob(baseUrl, adminAccessToken,
      acceptedBackupJob.job_id, { terminal: true });
    const archiveId = acceptedBackupJob.job_id;
    const archiveCandidates = fs.readdirSync(archiveDir).filter((name) =>
      name.endsWith(`-${archiveId}.atb`));
    const backupStatusDiagnostic = await directApi(baseUrl, 'GET',
      '/api/v1/admin/backup-status', { token: adminAccessToken });
    reportBoolean('backup_status_reports_succeeded',
      backupStatusDiagnostic.status === 200 &&
      backupStatusDiagnostic.payload?.operation === 'backup' &&
      backupStatusDiagnostic.payload?.last_attempt?.result === 'succeeded');
    reportBoolean('generated_archive_file_exists', archiveCandidates.length >= 1);
    const replicationStatusDiagnostic = await directApi(baseUrl, 'GET',
      REPLICATION_PATH, { token: adminAccessToken });
    const diagnosticLatestAttempt = replicationStatusDiagnostic.status === 200
      ? replicationStatusDiagnostic.payload?.latest_attempt
      : null;
    const diagnosticReplicationState = diagnosticLatestAttempt?.state ?? null;
    reportBoolean('replication_state_pending',
      ['pending_archive', 'pending', 'running', 'retry_wait'].includes(
        diagnosticReplicationState));
    reportBoolean('replication_state_succeeded', diagnosticReplicationState === 'succeeded');
    reportBoolean('replication_state_failed', diagnosticReplicationState === 'failed');
    for (const category of REPLICATION_FAILURE_CATEGORIES) {
      reportBoolean(`replication_failure_category_${category}`,
        diagnosticLatestAttempt?.failure_category === category);
    }
    reportBoolean('replication_failure_category_null',
      diagnosticLatestAttempt?.failure_category === null);
    reportBoolean('backup_terminal_succeeded', backupTerminal.status === 'succeeded');
    reportBoolean('backup_terminal_completed_result',
      backupTerminal.result_code === 'completed');
    reportBoolean('backup_terminal_archive_id_null', backupTerminal.archive_id === null);
    assertThat(backupTerminal.status === 'succeeded' &&
        backupTerminal.result_code === 'completed' &&
        backupTerminal.action === 'backup' &&
        backupTerminal.archive_id === null &&
        backupTerminal.archive_source === null,
    'real encrypted backup job did not complete with the expected null archive reference');
    assertThat(archiveCandidates.length === 1,
      'server backup did not create exactly one generated archive');
    const archivePath = path.join(archiveDir, archiveCandidates[0]);
    const archiveStats = fs.statSync(archivePath);
    const archiveBytes = archiveStats.size;
    const archiveSha256 = crypto.createHash('sha256')
      .update(fs.readFileSync(archivePath)).digest('hex');
    assertThat(archiveStats.isFile() && archiveBytes > 0,
      'server generated archive was empty or not a regular file');
    assertThat(archiveBytes > MULTIPART_THRESHOLD_BYTES,
      'real encrypted backup did not exceed the multipart threshold');
    reportBoolean('real_encrypted_archive_exceeded_multipart_threshold', true);
    reportBoolean('real_encrypted_archive_created', true);

    setStage('wait for and validate verified replica status');
    const replicatedStatus = await waitForReplicaStatus(
      baseUrl, adminAccessToken, archiveId, archiveBytes,
    );
    assertThat(s3Fixture.stats.multipartCreateCount === 1 &&
        s3Fixture.stats.multipartPartCount >= 1 &&
        s3Fixture.stats.multipartCompleteCount === 1 &&
        s3Fixture.stats.conditionalMultipartCompleteCount === 1 &&
        s3Fixture.stats.unconditionalMultipartCompleteCount === 0 &&
        s3Fixture.stats.conditionalMultipartConflictCount === 1 &&
        s3Fixture.stats.multipartAbortCount >= 1 &&
        s3Fixture.stats.servicePutCount === 0 &&
        s3Fixture.stats.conditionalServicePutCount === 0 &&
        s3Fixture.stats.unconditionalServicePutCount === 0 &&
        s3Fixture.stats.malformedUploadCount === 0 &&
        s3Fixture.stats.wrongBucketCount === 0 &&
        s3Fixture.stats.unauthorizedRequestCount === 0,
    'backup worker did not complete a conditional multipart archive upload securely');
    const replicaObjectEntry = [...s3Fixture.objects.entries()]
      .find(([key, value]) => key.endsWith(`/${archiveId}.atb`) &&
        value.bytes.length === archiveBytes && value.sha256 === archiveSha256);
    assertThat(Boolean(replicaObjectEntry),
      'loopback replica did not retain the exact encrypted archive digest');
    reportBoolean('service_multipart_completion_was_conditional_and_conflict_verified', true);
    const [replicaObjectKey, replicaObject] = replicaObjectEntry;
    const originalReplicaBytes = Buffer.from(replicaObject.bytes);
    const originalReplicaDigest = replicaObject.sha256;
    const sameArchiveConditionalPutStatus = await s3Fixture.conditionalPutProbe(
      replicaObjectKey, originalReplicaBytes, originalReplicaDigest,
    );
    const afterSameArchiveProbe = s3Fixture.objects.get(replicaObjectKey);
    assertThat(sameArchiveConditionalPutStatus === 412 &&
        afterSameArchiveProbe.bytes.equals(originalReplicaBytes) &&
        afterSameArchiveProbe.sha256 === originalReplicaDigest,
    'same archive conditional retry replaced the verified remote object');
    const conflictingProbeBytes = Buffer.from('different encrypted archive digest probe');
    const conflictingProbeDigest = crypto.createHash('sha256')
      .update(conflictingProbeBytes).digest('hex');
    const differentDigestConditionalPutStatus = await s3Fixture.conditionalPutProbe(
      replicaObjectKey, conflictingProbeBytes, conflictingProbeDigest,
    );
    const afterConflictProbe = s3Fixture.objects.get(replicaObjectKey);
    assertThat(differentDigestConditionalPutStatus === 412 &&
        afterConflictProbe.bytes.equals(originalReplicaBytes) &&
        afterConflictProbe.sha256 === originalReplicaDigest,
    'different digest conflict overwrote the existing replica object');
    assertThat(s3Fixture.stats.lostInitialPutAckCount === 0 &&
        s3Fixture.stats.conditionalMultipartConflictCount === 1 &&
        s3Fixture.stats.getCount >= 1 &&
        s3Fixture.stats.servicePutCount === 0 &&
        s3Fixture.stats.conditionalServicePutCount === 0 &&
        s3Fixture.stats.unconditionalServicePutCount === 0 &&
        s3Fixture.stats.fixtureProbePutCount === 2,
    'conditional multipart conflict did not verify and preserve its existing object');
    reportBoolean('fixture_received_and_verified_replica_upload', true);
    reportBoolean('same_idempotent_archive_retry_preserved_existing_object', true);
    reportBoolean('different_digest_precondition_conflict_preserved_existing_object', true);

    setStage('refresh administrator Settings with completed replica status');
    const replicaUiStart = events.admin.length;
    await click(adminPage, 'Refresh replication status');
    const replicaUiEvent = await waitForJobEvent(events.admin,
      (event) => event.route === 'backup-replication' && event.method === 'GET',
      replicaUiStart);
    reportStatus('admin_settings_replica_refresh', replicaUiEvent.status);
    assertThat(replicaUiEvent.status === 200 && replicaUiEvent.hasBearer,
      'administrator Settings replica refresh was not authenticated');
    const uiReplicaStatus = validateReplicationStatus(await replicaUiEvent.payloadPromise);
    assertThat(uiReplicaStatus.latest_attempt?.archive_id === archiveId &&
        uiReplicaStatus.latest_attempt.state === 'succeeded' &&
        uiReplicaStatus.latest_attempt.archive_bytes === archiveBytes &&
        uiReplicaStatus.latest_attempt.failure_category === null,
    'administrator Settings did not receive the completed replica DTO');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Remote copy verified'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted archive bytes'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Copies waiting'));
    const completedAdminText = await pageVisibleText(adminPage);
    assertNoLeaks(completedAdminText);
    assertThat(!completedAdminText.includes(archiveId) &&
        completedAdminText.includes('Configured') &&
        completedAdminText.includes('Remote copy verified') &&
        completedAdminText.includes(formattedAdminBytes(archiveBytes)),
    'replication Settings did not show safe completion state');
    reportBoolean('admin_replication_state_rendered_without_destination_or_key', true);

    setStage('reject an invalid restore source without echoing markers');
    const invalidSourceMarker = `invalid-source-marker-${crypto.randomUUID()}`;
    leakMarkers.push(invalidSourceMarker);
    const invalidRestore = await directApi(baseUrl, 'POST', JOBS_PATH, {
      token: adminAccessToken,
      body: {
        request_id: crypto.randomUUID(),
        action: 'restore',
        archive_id: archiveId,
        archive_source: invalidSourceMarker,
      },
    });
    reportStatus('invalid_restore_source', invalidRestore.status);
    assertThat(invalidRestore.status === 400,
      'invalid restore source was not rejected as a client error');
    reportBoolean('invalid_source_error_response_contains_no_private_markers', true);

    setStage('load restore sources with same archive available locally and remotely');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy'));
    const sourcesStart = events.admin.length;
    await click(adminPage, 'Load restore sources');
    const sourcesEvent = await waitForJobEvent(events.admin,
      (event) => event.route === 'restore-sources' && event.method === 'GET',
      sourcesStart);
    reportStatus('admin_restore_source_list', sourcesEvent.status);
    assertThat(sourcesEvent.status === 200 && sourcesEvent.hasBearer,
      'administrator restore-source listing was not authenticated');
    const sources = validateRestoreSources(await sourcesEvent.payloadPromise);
    const matchingSources = sources.filter((source) => source.archive_id === archiveId);
    const localSource = matchingSources.find((source) => source.source === 'local');
    const replicaSource = matchingSources.find((source) => source.source === 'replica');
    assertThat(matchingSources.length === 2 && localSource && replicaSource &&
        localSource.origin === 'manual' && replicaSource.origin === 'manual' &&
        localSource.archive_bytes === archiveBytes &&
        replicaSource.archive_bytes === archiveBytes,
    'restore source catalog did not expose both copies with the same archive ID');
    const restorePageText = await pageVisibleText(adminPage);
    assertNoLeaks(restorePageText);
    assertThat(!restorePageText.includes(archiveId),
      'restore source visible text exposed its internal archive ID');

    setStage('select the replica row for the duplicate archive ID');
    const replicaRadio = adminPage.getByRole('radio', { name: /Remote replica/ });
    assertThat(await replicaRadio.count() === 1 &&
        await replicaRadio.isVisible().catch(() => false),
    'the unique remote replica source was not selectable in Settings');
    const radioAccessibleLabel = typeof replicaRadio.ariaSnapshot === 'function'
      ? await replicaRadio.ariaSnapshot()
      : await replicaRadio.innerText();
    assertThat(!radioAccessibleLabel.includes(archiveId),
      'restore radio label exposed the internal archive identifier');
    await replicaRadio.click();
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Remote replica'));
    const localCopyGetsBeforeRestore = s3Fixture.stats.getCount;

    // Keep the identical ID in the UI's fetched local+replica catalog, then
    // remove the local bytes so a successful restore proves the selected
    // replica source was used end-to-end.
    fs.unlinkSync(archivePath);
    assertThat(!fs.existsSync(archivePath),
      'local archive fixture remained available for the remote restore proof');
    await click(adminPage, 'Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy?'));
    assertNoLeaks(await pageVisibleText(adminPage));
    const confirmButton = adminPage.getByRole('button', {
      name: 'Prepare isolated copy', exact: true,
    });
    assertThat(await confirmButton.count() === 1,
      'replica restore confirmation action was not unique');
    const restorePostSequence = events.admin.length;
    await confirmButton.click();
    const restorePost = await waitForJobEvent(events.admin,
      (event) => event.route === 'admin-jobs' && event.method === 'POST',
      restorePostSequence);
    reportStatus('admin_replica_restore_job_create', restorePost.status);
    const restoreRequestId = restorePost.body?.request_id;
    assertThat(restorePost.hasBearer && restorePost.status === 202 &&
        exactKeys(restorePost.body, [
          'request_id', 'action', 'archive_id', 'archive_source',
        ]) && UUID_PATTERN.test(restoreRequestId) &&
        restorePost.body.action === 'restore' &&
        restorePost.body.archive_id === archiveId &&
        restorePost.body.archive_source === 'replica',
    'Settings restore request did not bind the duplicate archive ID to replica');
    const restoreReceipt = await restorePost.payloadPromise;
    assertThat(exactKeys(restoreReceipt, ['job']),
      'replica restore receipt fields were invalid');
    const acceptedRestore = validateJob(restoreReceipt.job, {
      action: 'restore', archiveId, archiveSource: 'replica',
    });
    assertThat(acceptedRestore.request_id === restoreRequestId,
      'replica restore receipt did not preserve the request identity');

    setStage('verify durable restore job preserves replica source and uses replica bytes');
    const restoreTerminal = await waitForAdminJob(baseUrl, adminAccessToken,
      acceptedRestore.job_id, { terminal: true });
    validateJob(restoreTerminal, {
      action: 'restore', archiveId, archiveSource: 'replica',
    });
    assertThat(restoreTerminal.status === 'succeeded' &&
        restoreTerminal.result_code === 'completed',
    'restore job using remote replica did not complete successfully');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Restore staging · Prepared'), 30000);
    const s3ReadsForRestore = s3Fixture.stats.getCount - localCopyGetsBeforeRestore;
    assertThat(s3ReadsForRestore >= 1 &&
        s3Fixture.stats.unauthorizedRequestCount === 0 &&
        s3Fixture.stats.wrongBucketCount === 0,
    'restore worker did not fetch the selected archive from the authenticated replica fixture');
    const jobsAfterRestore = await directApi(baseUrl, 'GET',
      `${JOBS_PATH}?limit=100&offset=0`, { token: adminAccessToken });
    assertThat(jobsAfterRestore.status === 200 &&
        validateAdminJobsPage(jobsAfterRestore.payload),
    'durable admin job listing after replica restore was invalid');
    const durableRestore = jobsAfterRestore.payload.jobs.find((job) =>
      job.job_id === acceptedRestore.job_id);
    assertThat(durableRestore && durableRestore.archive_id === archiveId &&
        durableRestore.archive_source === 'replica' &&
        durableRestore.status === 'succeeded' &&
        durableRestore.restore_stage_status === 'ready',
    'durable restore job lost its replica source');
    const restoreStagePath = path.join(
      archiveDir,
      'restore-staging',
      `atermius-restore-${acceptedRestore.job_id}`,
    );
    assertThat(fs.statSync(restoreStagePath).isDirectory(),
      'replica restore did not publish the isolated staging directory');
    assertNoLeaks(await pageVisibleText(adminPage));
    reportBoolean('replica_restore_completed_after_local_copy_removal', true);

    setStage('reload catalogued replica and remove its loopback object');
    const missingCatalogStart = events.admin.length;
    const missingCatalogButton = await hasVisibleSemanticText(adminPage,
      'Refresh restore sources') ? 'Refresh restore sources' : 'Load restore sources';
    await click(adminPage, missingCatalogButton);
    const missingCatalogEvent = await waitForJobEvent(events.admin,
      (event) => event.route === 'restore-sources' && event.method === 'GET',
      missingCatalogStart);
    assertThat(missingCatalogEvent.status === 200 && missingCatalogEvent.hasBearer,
      'Settings could not reload the catalogued replica source');
    const missingCatalogSources = validateRestoreSources(
      await missingCatalogEvent.payloadPromise);
    const missingReplicaSource = missingCatalogSources.find((source) =>
      source.archive_id === archiveId && source.source === 'replica');
    assertThat(missingCatalogSources.length === 1 && missingReplicaSource &&
        missingReplicaSource.origin === 'manual' &&
        missingReplicaSource.archive_bytes === archiveBytes &&
        JSON.stringify(missingReplicaSource) === JSON.stringify(replicaSource),
    'replica source metadata changed before the missing-object restore');
    const secondReplicaRadio = adminPage.getByRole('radio', { name: /Remote replica/ });
    assertThat(await secondReplicaRadio.count() === 1 &&
        await secondReplicaRadio.isVisible().catch(() => false),
    'the reloaded replica source was not selectable in Settings');
    await secondReplicaRadio.click();

    const instanceBeforeMissingRestore = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const profileBeforeMissingRestore = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    const replicaStatusBeforeMissingRestore = validateReplicationStatus(
      (await directApi(baseUrl, 'GET', REPLICATION_PATH, {
        token: adminAccessToken,
      })).payload);
    assertThat(instanceBeforeMissingRestore.status === 200 &&
        profileBeforeMissingRestore.status === 200 &&
        profileBeforeMissingRestore.payload.account_id === adminAccountId &&
        profileBeforeMissingRestore.payload.device_id === adminDeviceId &&
        replicaStatusBeforeMissingRestore.latest_attempt?.archive_id === archiveId &&
        replicaStatusBeforeMissingRestore.latest_attempt.state === 'succeeded',
    'live instance, authenticated profile or replica status was unavailable before failure test');

    const restoreStagingDirectory = path.join(archiveDir, 'restore-staging');
    const stagingEntriesBeforeMissingRestore = fs.readdirSync(restoreStagingDirectory).sort();
    const liveBusinessDigestBeforeMissingRestore = readBusinessDatabaseDigest(databasePath);
    const missingReplicaHeadCountBefore = s3Fixture.stats.headCount;
    const missingReplicaGetCountBefore = s3Fixture.stats.getCount;
    const replicaMutationCounts = () => JSON.stringify({
      putCount: s3Fixture.stats.putCount,
      servicePutCount: s3Fixture.stats.servicePutCount,
      conditionalServicePutCount: s3Fixture.stats.conditionalServicePutCount,
      unconditionalServicePutCount: s3Fixture.stats.unconditionalServicePutCount,
      multipartCreateCount: s3Fixture.stats.multipartCreateCount,
      multipartPartCount: s3Fixture.stats.multipartPartCount,
      multipartCompleteCount: s3Fixture.stats.multipartCompleteCount,
      conditionalMultipartCompleteCount: s3Fixture.stats.conditionalMultipartCompleteCount,
      unconditionalMultipartCompleteCount: s3Fixture.stats.unconditionalMultipartCompleteCount,
      conditionalMultipartConflictCount: s3Fixture.stats.conditionalMultipartConflictCount,
      fixtureProbePutCount: s3Fixture.stats.fixtureProbePutCount,
    });
    const replicaMutationCountsBefore = replicaMutationCounts();
    assertThat(s3Fixture.objects.has(replicaObjectKey) &&
        replicaObject.bytes.equals(originalReplicaBytes) &&
        crypto.createHash('sha256').update(originalReplicaBytes).digest('hex') ===
          originalReplicaDigest &&
        s3Fixture.objects.delete(replicaObjectKey) &&
        !s3Fixture.objects.has(replicaObjectKey),
    'loopback replica object could not be removed without changing the captured source');
    leakMarkers.push(replicaObjectKey);

    setStage('submit replica restore after catalogued remote object disappears');
    await click(adminPage, 'Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy?'));
    const failedConfirmButton = adminPage.getByRole('button', {
      name: 'Prepare isolated copy', exact: true,
    });
    assertThat(await failedConfirmButton.count() === 1,
      'missing-replica restore confirmation action was not unique');
    const failedRestorePostSequence = events.admin.length;
    await failedConfirmButton.click();
    const failedRestorePost = await waitForJobEvent(events.admin,
      (event) => event.route === 'admin-jobs' && event.method === 'POST',
      failedRestorePostSequence);
    reportStatus('admin_missing_replica_restore_job_create', failedRestorePost.status);
    const failedRestoreRequestId = failedRestorePost.body?.request_id;
    assertThat(failedRestorePost.hasBearer && failedRestorePost.status === 202 &&
        exactKeys(failedRestorePost.body, [
          'request_id', 'action', 'archive_id', 'archive_source',
        ]) && UUID_PATTERN.test(failedRestoreRequestId) &&
        failedRestorePost.body.action === 'restore' &&
        failedRestorePost.body.archive_id === archiveId &&
        failedRestorePost.body.archive_source === 'replica',
    'Settings did not bind the missing-object restore request to the selected replica');
    const failedRestoreReceipt = await failedRestorePost.payloadPromise;
    assertThat(exactKeys(failedRestoreReceipt, ['job']),
      'missing-replica restore receipt fields were invalid');
    const acceptedFailedRestore = validateJob(failedRestoreReceipt.job, {
      action: 'restore', archiveId, archiveSource: 'replica',
    });
    assertThat(acceptedFailedRestore.request_id === failedRestoreRequestId,
      'missing-replica restore receipt did not preserve the request identity');

    setStage('verify fixed missing-replica failure and isolated cleanup');
    const failedRestoreTerminal = await waitForAdminJob(baseUrl, adminAccessToken,
      acceptedFailedRestore.job_id, { terminal: true });
    validateJob(failedRestoreTerminal, {
      action: 'restore', archiveId, archiveSource: 'replica',
    });
    assertThat(failedRestoreTerminal.status === 'failed' &&
        failedRestoreTerminal.result_code === 'restore_failed' &&
        failedRestoreTerminal.started_at !== null &&
        failedRestoreTerminal.finished_at !== null,
    'missing replica did not produce the fixed failed/restore_failed job state');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Restore staging · Failed'), 30000);
    const failedRestoreSettingsText = await pageVisibleText(adminPage);
    assertNoReplicaFailureDetails(failedRestoreSettingsText);
    const failedRestoreReceiptText = JSON.stringify({
      receipt: failedRestoreReceipt,
      job: failedRestoreTerminal,
    });
    assertNoReplicaFailureDetails(failedRestoreReceiptText);
    const failedRestoreStagePath = path.join(restoreStagingDirectory,
      `atermius-restore-${acceptedFailedRestore.job_id}`);
    const failedRestoreTemporaryPath = `${failedRestoreStagePath}.staging`;
    const failedRestoreSourcePath = path.join(restoreStagingDirectory,
      `atermius-restore-${acceptedFailedRestore.job_id}.source.atb`);
    assertThat(!fs.existsSync(failedRestoreStagePath) &&
        !fs.existsSync(failedRestoreTemporaryPath) &&
        !fs.existsSync(failedRestoreSourcePath) &&
        JSON.stringify(fs.readdirSync(restoreStagingDirectory).sort()) ===
          JSON.stringify(stagingEntriesBeforeMissingRestore) &&
        fs.statSync(restoreStagePath).isDirectory(),
    'failed replica restore left a per-job stage/source artifact or changed the prior stage');
    assertThat(!s3Fixture.objects.has(replicaObjectKey) &&
        replicaObject.bytes.equals(originalReplicaBytes) &&
        crypto.createHash('sha256').update(originalReplicaBytes).digest('hex') ===
          originalReplicaDigest &&
        s3Fixture.stats.headCount > missingReplicaHeadCountBefore &&
        s3Fixture.stats.getCount === missingReplicaGetCountBefore &&
        replicaMutationCounts() === replicaMutationCountsBefore,
    'missing replica handling changed cached bytes, fetched data or rewrote the remote object');

    const durableFailedRestorePage = await directApi(baseUrl, 'GET',
      `${JOBS_PATH}?limit=100&offset=0`, { token: adminAccessToken });
    assertThat(durableFailedRestorePage.status === 200 &&
        validateAdminJobsPage(durableFailedRestorePage.payload),
    'durable admin job listing after replica failure was invalid');
    const durableFailedRestore = durableFailedRestorePage.payload.jobs.find((job) =>
      job.job_id === acceptedFailedRestore.job_id);
    assertThat(durableFailedRestore && durableFailedRestore.status === 'failed' &&
        durableFailedRestore.result_code === 'restore_failed' &&
        durableFailedRestore.restore_stage_status === null &&
        durableFailedRestore.archive_id === archiveId &&
        durableFailedRestore.archive_source === 'replica',
    'durable failed restore lost its fixed outcome or selected replica source');

    const sourcesAfterMissingRestore = await directApi(baseUrl, 'GET',
      RESTORE_SOURCES_PATH, { token: adminAccessToken });
    assertThat(sourcesAfterMissingRestore.status === 200,
      'replica source catalog could not be read after failed restore');
    const retainedReplicaSource = validateRestoreSources(sourcesAfterMissingRestore.payload)
      .find((source) => source.archive_id === archiveId && source.source === 'replica');
    const replicaStatusAfterMissingRestore = validateReplicationStatus(
      (await directApi(baseUrl, 'GET', REPLICATION_PATH, {
        token: adminAccessToken,
      })).payload);
    assertThat(retainedReplicaSource &&
        JSON.stringify(retainedReplicaSource) === JSON.stringify(missingReplicaSource) &&
        JSON.stringify(replicaStatusAfterMissingRestore) ===
          JSON.stringify(replicaStatusBeforeMissingRestore),
    'failed restore mutated the catalogued replica metadata or replication status');

    const instanceAfterMissingRestore = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const profileAfterMissingRestore = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(instanceAfterMissingRestore.status === 200 &&
        instanceAfterMissingRestore.payload.generation ===
          instanceBeforeMissingRestore.payload.generation &&
        profileAfterMissingRestore.status === 200 &&
        profileAfterMissingRestore.payload.account_id === adminAccountId &&
        profileAfterMissingRestore.payload.device_id === adminDeviceId,
    'failed restore changed the live instance generation or administrator session');
    setStage('validate missing-replica restore audit lifecycle');
    const failedRestoreAuditFeed = await directApi(baseUrl, 'GET',
      `${ADMIN_AUDIT_PATH}?limit=100`, { token: adminAccessToken });
    assertThat(failedRestoreAuditFeed.status === 200,
      'administrator could not read audit feed after missing-replica restore');
    const failedRestoreAuditLifecycle = validateFailedRestoreAuditLifecycle(
      failedRestoreAuditFeed.payload, acceptedFailedRestore.job_id);
    assertThat(failedRestoreAuditLifecycle.length === 3,
      'missing-replica restore audit lifecycle was incomplete');
    assertNoReplicaFailureDetails(failedRestoreAuditFeed.payload);
    const liveBusinessDigestAfterMissingRestore = readBusinessDatabaseDigest(databasePath);
    assertThat(JSON.stringify(liveBusinessDigestAfterMissingRestore) ===
        JSON.stringify(liveBusinessDigestBeforeMissingRestore),
    'failed restore changed live business rows outside excluded job/audit history');
    reportBoolean('missing_replica_restore_failed_without_stage_or_source_leaks', true);
    reportBoolean('missing_replica_audit_lifecycle_is_exact_and_hmac_bound', true);
    reportBoolean('missing_replica_failure_preserved_live_and_catalog_state', true);

    setStage('final API and browser privacy checks');
    const relevantEvents = [...events.admin, ...events.member].filter((event) =>
      ['backup-replication', 'backup-replication-preflight',
        'restore-sources', 'admin-jobs', 'admin-audit']
        .includes(event.route));
    for (const event of relevantEvents) {
      assertNoLeaks(await event.payloadPromise);
    }
    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    reportBoolean('api_error_and_success_payloads_contain_no_private_markers', true);
    reportBoolean('browser_runtime_errors_absent', true);
    assertThat(s3Fixture.stats.multipartCompleteCount === 1 &&
        s3Fixture.stats.conditionalMultipartCompleteCount === 1 &&
        s3Fixture.stats.unconditionalMultipartCompleteCount === 0 &&
        s3Fixture.stats.conditionalMultipartConflictCount === 1 &&
        s3Fixture.stats.servicePutCount === 0 &&
        s3Fixture.stats.conditionalServicePutCount === 0 &&
        s3Fixture.stats.unconditionalServicePutCount === 0 &&
        s3Fixture.stats.fixtureProbePutCount === 2 &&
        s3Fixture.stats.bucketHeadCount === 2 && s3Fixture.stats.getCount > 0 &&
        s3Fixture.stats.malformedUploadCount === 0 &&
        s3Fixture.stats.wrongBucketCount === 0 &&
        s3Fixture.stats.unauthorizedRequestCount === 0,
    'loopback replica fixture observed an unexpected storage operation');

    console.log('WEB-BACKUP-REPLICATION-01 passed', JSON.stringify({
      independentProfiles: 2,
      adminStatusDtoExact: true,
      memberSettingsHidden: true,
      adminBucketAccessPreflightFixedContract: true,
      adminBucketAccessLimitVisible: true,
      adminBucketAccessSuccessRendered: true,
      adminBucketAccess502FailureRenderedSafely: true,
      adminBucketAccess503UnconfiguredRenderedSafely: true,
      adminBucketAccessTimeoutBoundedAndRedacted: true,
      memberPreflightHiddenAndNotRequested: true,
      memberStatusForbidden: true,
      sameArchiveAvailableAsLocalAndReplica: true,
      selectedRestoreSource: 'replica',
      restoreRequestAndJobPreserveReplicaSource: true,
      restoreFetchedRemoteBytesAfterLocalRemoval: s3ReadsForRestore >= 1,
      missingReplicaRestoreFailedWithoutArtifacts: true,
      missingReplicaRestoreAuditLifecycleExact: true,
      missingReplicaFailurePreservedLiveAndCatalogState: true,
      safeStatusAndRestoreResponses: true,
      noPrivateConfigurationMarkers: true,
      pageErrorCount: pageErrors,
    }));
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed,
    'temporary server, browser profile, S3 fixture or private files did not all clean up');
  setStage('complete');
}

main().catch(async (error) => {
  await cleanup();
  console.error(`WEB-BACKUP-REPLICATION-01 failed at ${stage}`);
  console.error(`assertion: ${typeof error?.safeAssertion === 'string'
    ? error.safeAssertion : 'unclassified failure'}`);
  if (typeof error?.name === 'string' && error.name !== 'Error') {
    console.error(`failure_type: ${error.name}`);
  }
  if (cleanupFailed) console.error('assertion: temporary resource cleanup failed');
  process.exitCode = 1;
});
