/*
 * WEB-ADMIN-RESTORE-STAGE-01: prove administrator restore preparation creates
 * an isolated copy while the live service stays online, and that failed or
 * interrupted workers are safely reconciled. The test exercises the real
 * Settings UI in separate admin/member Chromium profiles, strict API
 * authorization, cancellation, audit display and startup recovery.
 * Diagnostics contain only fixed labels/statuses.
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
const SERVER_TARGET_DIR = path.resolve(
  process.env.CARGO_TARGET_DIR || path.join(ROOT, 'server/target'),
);
const SERVER_BINARY = path.join(SERVER_TARGET_DIR, 'debug/atermius-server');
const RESTORE_SOURCES_PATH = '/api/v1/admin/restore-sources';
const JOBS_PATH = '/api/v1/admin/jobs';
const ADMIN_AUDIT_PATH = '/api/v1/admin/audit';
const RESTORE_STAGE_DISCARD_PATH = /^\/api\/v1\/admin\/restore-stages\/([0-9a-f-]{36})\/discard$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let debuggerProcess;
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
const adminEvents = [];
const memberEvents = [];
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
  const cargoTmpDir = path.join(SERVER_TARGET_DIR, 'tmp');
  fs.mkdirSync(cargoTmpDir, { recursive: true, mode: 0o700 });
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT,
    env: {
      ...process.env,
      CARGO_TARGET_DIR: SERVER_TARGET_DIR,
      TMPDIR: cargoTmpDir,
    },
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
  await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
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

async function waitForPath(filePath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return true;
    if (debuggerProcess && debuggerProcess.exitCode !== null) return false;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return fs.existsSync(filePath);
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
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1200) });
      if (response.status === 200) return;
    } catch (_) {
      // Keep waiting while the disposable loopback server starts.
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
    memberUsername = undefined;
    memberPassword = undefined;
    adminAccessToken = undefined;
    adminAccountId = undefined;
    adminDeviceId = undefined;
    memberAccessToken = undefined;
    backupKey = undefined;
    leakSentinels.length = 0;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
      await stopServerGroup(serverProcess);
      await stopServerGroup(debuggerProcess);
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
  try {
    await selectServerModeIfChooser(page, locator);
    await locator.waitFor({ state: 'visible', timeout: 20000 });
  } catch (_) {
    const error = new Error(`expected form field ${label} to become visible`);
    error.safeAssertion = `expected form field ${label} to become visible`;
    throw error;
  }
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
  try {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await locator.click();
      await locator.press('Control+A');
      await locator.pressSequentially(value, { delay: 25 });
      await locator.press('Tab');
      if (await locator.inputValue() === value) return;
    }
  } catch (_) {
    const error = new Error(`could not enter form field ${label}`);
    error.safeAssertion = `could not enter form field ${label}`;
    throw error;
  }
  const error = new Error(`form field ${label} did not retain its input`);
  error.safeAssertion = `form field ${label} did not retain its input`;
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
    if (pathname === RESTORE_SOURCES_PATH) return 'restore-sources';
    if (pathname === JOBS_PATH) return 'admin-jobs';
    if (pathname === ADMIN_AUDIT_PATH) return 'admin-audit';
    if (RESTORE_STAGE_DISCARD_PATH.test(pathname)) return 'restore-stage-discard';
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
    let body = null;
    if (['admin-jobs', 'restore-stage-discard'].includes(route) && request.method() === 'POST') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    const url = new URL(request.url());
    byRequest.set(request, {
      route,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      pathname: url.pathname,
      query: Object.fromEntries(url.searchParams.entries()),
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
  throw new Error('expected API response did not arrive');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function posixShellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const secret of leakSentinels) {
    if (secret && secret.length >= 8) {
      assertThat(!serialized.includes(secret), 'a response or rendered view exposed a credential');
    }
  }
  const internalText = /\/(?:root|tmp|var|home|opt|usr|workspace)\/|\b[A-Z]:\\(?:Users|Windows|Program Files)\\|(?:SQLite|sqlx|tokio::|panic at|stack trace|backtrace|internal server error|no such table)/i;
  assertThat(!internalText.test(serialized), 'a response or rendered view exposed internal server details');
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'a response or rendered view exposed the server data path');
}

function validateSources(payload) {
  assertThat(exactKeys(payload, ['sources', 'total']) && Array.isArray(payload.sources) &&
      Number.isInteger(payload.total) && payload.total >= payload.sources.length,
    'restore source page shape was invalid');
  for (const source of payload.sources) {
    assertThat(exactKeys(source, ['archive_id', 'created_at', 'archive_bytes', 'origin', 'source']) &&
        UUID_PATTERN.test(source.archive_id) && Number.isInteger(source.archive_bytes) &&
        source.archive_bytes > 0 && ['manual', 'scheduled'].includes(source.origin) &&
        ['local', 'replica'].includes(source.source) &&
        typeof source.created_at === 'string' && !Number.isNaN(Date.parse(source.created_at)),
      'restore source metadata was invalid');
  }
  assertNoLeaks(payload);
  return payload.sources;
}

function validateJob(job, archiveId) {
  assertThat(exactKeys(job, [
    'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status', 'requested_at',
    'started_at', 'finished_at', 'result_code', 'restore_stage_status',
  ]), 'restore job metadata fields changed');
  assertThat(UUID_PATTERN.test(job.job_id) && UUID_PATTERN.test(job.request_id) &&
      job.action === 'restore' && job.archive_id === archiveId &&
      ['local', 'replica'].includes(job.archive_source),
    'restore job did not preserve its safe IDs');
  assertThat(['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
    'restore job status was invalid');
  const timestamp = (value) => typeof value === 'string' && !Number.isNaN(Date.parse(value));
  assertThat(timestamp(job.requested_at), 'restore request timestamp was invalid');
  assertThat(job.started_at === null || timestamp(job.started_at), 'restore start timestamp was invalid');
  assertThat(job.finished_at === null || timestamp(job.finished_at), 'restore finish timestamp was invalid');
  assertThat(job.result_code === null || ['completed', 'restore_failed', 'interrupted'].includes(job.result_code),
    'restore job result code was invalid');
  if (job.status === 'succeeded') {
    assertThat(job.started_at !== null && job.finished_at !== null && job.result_code === 'completed',
      'succeeded restore job had inconsistent terminal metadata');
    assertThat(['ready', 'discarding', 'discarded', 'unverified'].includes(
      job.restore_stage_status),
      'succeeded restore job had invalid staging lifecycle status');
  } else {
    assertThat(job.restore_stage_status === null,
      'non-succeeded restore job exposed staging lifecycle status');
  }
  if (job.status === 'failed') {
    assertThat(job.started_at !== null && job.finished_at !== null && job.result_code === 'restore_failed',
      'failed restore job had inconsistent terminal metadata');
  }
  if (job.status === 'interrupted') {
    assertThat(job.finished_at !== null && job.result_code === 'interrupted',
      'interrupted restore job had inconsistent terminal metadata');
  }
  assertNoLeaks(job);
  return job;
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

function validateAdminAuditPage(payload) {
  const validShape = exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
    Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
    (payload.next_cursor === null || typeof payload.next_cursor === 'string');
  if (!validShape) {
    const diagnostics = {
      payloadObject: Boolean(payload && typeof payload === 'object' && !Array.isArray(payload)),
      topLevelKeyCount: payload && typeof payload === 'object' && !Array.isArray(payload)
        ? Object.keys(payload).length : null,
      eventsArray: Array.isArray(payload?.events),
      eventCount: Array.isArray(payload?.events) ? payload.events.length : null,
      hasMoreBoolean: typeof payload?.has_more === 'boolean',
      cursorType: payload?.next_cursor === null ? 'null' :
        typeof payload?.next_cursor === 'string' ? 'string' :
          payload?.next_cursor === undefined ? 'missing' : 'other',
    };
    assertThat(false,
      `instance audit page shape was invalid (${JSON.stringify(diagnostics)})`);
  }
  assertNoLeaks(payload);
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
        ['api', 'maintenance'].includes(event.source) &&
        typeof event.occurred_at === 'string' && !Number.isNaN(Date.parse(event.occurred_at)),
      'instance audit event DTO or privacy metadata was invalid');
  }
  return payload.events;
}

function validateRestoreAuditLifecycle(payload, admin, rawJobId) {
  const expectedActions = [
    'admin.restore_requested',
    'admin.restore_started',
    'admin.restore_completed',
  ];
  const restoreEvents = validateAdminAuditPage(payload).filter(
    (event) => event.action.startsWith('admin.restore_'));
  assertThat(restoreEvents.length === expectedActions.length,
    'restore audit feed did not contain exactly three success-lifecycle rows');
  const orderedEvents = expectedActions.map((action) => {
    const matching = restoreEvents.filter((event) => event.action === action);
    assertThat(matching.length === 1, `restore audit feed omitted or duplicated ${action}`);
    const event = matching[0];
    assertThat(event.scope === 'instance' &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
        event.resource_type === 'admin_job' && typeof event.resource_id === 'string' &&
        /^[0-9a-f]{64}$/.test(event.resource_id) && event.resource_id !== rawJobId &&
        event.source === 'api' && event.result === 'success',
      'restore lifecycle audit actor, resource, source or result was invalid');
    assertThat(!JSON.stringify(event).includes(rawJobId),
      'restore audit event exposed the raw job identifier');
    return event;
  });
  assertThat(new Set(orderedEvents.map((event) => event.resource_id)).size === 1 &&
      BigInt(orderedEvents[0].event_id) < BigInt(orderedEvents[1].event_id) &&
      BigInt(orderedEvents[1].event_id) < BigInt(orderedEvents[2].event_id),
    'restore audit lifecycle did not share one HMAC resource or preserve stage order');
  return orderedEvents;
}

function validateFailedRestoreAuditLifecycle(payload, admin, rawJobId) {
  const events = validateAdminAuditPage(payload).filter((event) =>
    event.action.startsWith('admin.restore_'));
  const failedTerminals = events.filter((event) =>
    event.action === 'admin.restore_failed' && event.result === 'failure');
  assertThat(failedTerminals.length === 1,
    'restore audit feed did not contain exactly one real failed restore terminal event');
  const resourceId = failedTerminals[0].resource_id;
  const expectedStages = [
    ['admin.restore_requested', 'success'],
    ['admin.restore_started', 'success'],
    ['admin.restore_failed', 'failure'],
  ];
  const lifecycleEvents = expectedStages.map(([action, result]) => {
    const matching = events.filter((event) =>
      event.resource_id === resourceId && event.action === action &&
      event.result === result);
    assertThat(matching.length === 1,
      `failed restore audit lifecycle omitted or duplicated ${action}`);
    const event = matching[0];
    assertThat(event.scope === 'instance' &&
        event.actor_user_id === admin.accountId &&
        event.actor_device_id === admin.deviceId &&
        event.resource_type === 'admin_job' &&
        typeof event.resource_id === 'string' &&
        /^[0-9a-f]{64}$/.test(event.resource_id) &&
        event.resource_id !== rawJobId && event.source === 'api' &&
        event.result === result && !JSON.stringify(event).includes(rawJobId),
      'failed restore audit actor, resource, source, result or privacy was invalid');
    return event;
  });
  assertThat(BigInt(lifecycleEvents[0].event_id) <
      BigInt(lifecycleEvents[1].event_id) &&
      BigInt(lifecycleEvents[1].event_id) <
      BigInt(lifecycleEvents[2].event_id) &&
      lifecycleEvents.every((event) => event.resource_id === resourceId),
    'failed restore lifecycle did not share one HMAC resource or preserve stage order');
  return lifecycleEvents;
}

function validateInterruptedRestoreAuditLifecycle(payload, admin, rawJobId) {
  const events = validateAdminAuditPage(payload).filter((event) =>
    event.action.startsWith('admin.restore_'));
  const interruptedTerminals = events.filter((event) =>
    event.action === 'admin.restore_interrupted' && event.result === 'failure');
  assertThat(interruptedTerminals.length === 1,
    'restore audit feed did not contain exactly one real interrupted terminal event');
  const resourceId = interruptedTerminals[0].resource_id;
  const expectedStages = [
    ['admin.restore_requested', 'success'],
    ['admin.restore_started', 'success'],
    ['admin.restore_interrupted', 'failure'],
  ];
  const lifecycleEvents = expectedStages.map(([action, result]) => {
    const matching = events.filter((event) =>
      event.resource_id === resourceId && event.action === action &&
      event.result === result);
    assertThat(matching.length === 1,
      `interrupted restore audit lifecycle omitted or duplicated ${action}`);
    const event = matching[0];
    assertThat(event.scope === 'instance' &&
        event.actor_user_id === admin.accountId &&
        event.actor_device_id === admin.deviceId &&
        event.resource_type === 'admin_job' &&
        typeof event.resource_id === 'string' &&
        /^[0-9a-f]{64}$/.test(event.resource_id) &&
        event.resource_id !== rawJobId && event.source === 'api' &&
        event.result === result && !JSON.stringify(event).includes(rawJobId),
      'interrupted restore audit actor, resource, source, result or privacy was invalid');
    return event;
  });
  assertThat(BigInt(lifecycleEvents[0].event_id) <
      BigInt(lifecycleEvents[1].event_id) &&
      BigInt(lifecycleEvents[1].event_id) <
      BigInt(lifecycleEvents[2].event_id) &&
      lifecycleEvents.every((event) => event.resource_id === resourceId),
    'interrupted restore lifecycle did not share one HMAC resource or preserve stage order');
  return lifecycleEvents;
}

function validateRestoreStageDiscardAuditEvent(payload, admin, rawJobId) {
  const matching = validateAdminAuditPage(payload).filter((event) =>
    event.action === 'admin.restore_stage_discarded');
  assertThat(matching.length === 1,
    'restore stage discard audit feed omitted or duplicated its completion event');
  const event = matching[0];
  assertThat(event.scope === 'instance' &&
      event.actor_user_id === admin.accountId &&
      event.actor_device_id === admin.deviceId &&
      event.resource_type === 'admin_job' &&
      typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id) &&
      event.resource_id !== rawJobId && event.result === 'success' && event.source === 'api' &&
      !JSON.stringify(event).includes(rawJobId),
    'restore stage discard audit identity, HMAC, result or privacy was invalid');
  return event;
}

const LIVE_SNAPSHOT_SCRIPT = String.raw`
import hashlib
import json
import os
import sqlite3
import stat
import sys
from pathlib import Path

TABLES = (
    "instance_meta", "users", "auth_credentials", "devices", "sessions",
    "refresh_history", "vaults", "vault_members", "vault_key_envelopes",
    "vault_counters", "record_heads", "record_versions", "change_events",
    "op_receipts", "batch_receipts", "record_graveyard", "snapshots",
    "conflicts", "uploads", "upload_chunks", "blob_objects",
    "object_references", "invitations", "membership_manifests",
)
EXCLUDED_DB_FILES = {"atermius.db", "atermius.db-wal", "atermius.db-shm"}

def stable(value):
    if isinstance(value, bytes):
        return {"bytes_sha256": hashlib.sha256(value).hexdigest(), "bytes_length": len(value)}
    return value

database_path = Path(sys.argv[1]).resolve()
data_root = Path(sys.argv[2]).resolve()
connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True, timeout=10)
connection.execute("PRAGMA query_only=ON")
connection.execute("BEGIN")
business_hash = hashlib.sha256()
table_counts = {}
for table in TABLES:
    rows = connection.execute(f'SELECT * FROM "{table}"').fetchall()
    normalized = [tuple(stable(value) for value in row) for row in rows]
    normalized.sort(key=repr)
    encoded = json.dumps([table, normalized], sort_keys=True, separators=(",", ":"))
    business_hash.update(encoded.encode("utf-8"))
    table_counts[table] = len(normalized)
connection.rollback()
connection.close()

tree_entries = []
for item in sorted(data_root.rglob("*"), key=lambda value: str(value.relative_to(data_root))):
    if item.name in EXCLUDED_DB_FILES:
        continue
    relative = str(item.relative_to(data_root))
    metadata = item.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if item.is_symlink():
        tree_entries.append([relative, "symlink", os.readlink(item), mode])
    elif item.is_file():
        file_hash = hashlib.sha256()
        with item.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                file_hash.update(block)
        tree_entries.append([relative, "file", file_hash.hexdigest(), mode])
    elif item.is_dir():
        tree_entries.append([relative, "directory", mode])
tree_encoded = json.dumps(tree_entries, separators=(",", ":"))
result = {
    "business_sha256": business_hash.hexdigest(),
    "payload_tree_sha256": hashlib.sha256(tree_encoded.encode("utf-8")).hexdigest(),
    "table_counts": table_counts,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
`;

function liveDataSnapshot(databasePath, dataDir) {
  const result = spawnSync('python3', ['-c', LIVE_SNAPSHOT_SCRIPT, databasePath, dataDir], {
    cwd: ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: 30000,
    maxBuffer: 1024 * 1024,
  });
  assertThat(!result.error && result.status === 0,
    'read-only live business and payload snapshot failed');
  let snapshot;
  try {
    snapshot = JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('read-only live business and payload snapshot was malformed');
  }
  assertThat(exactKeys(snapshot, ['business_sha256', 'payload_tree_sha256', 'table_counts']) &&
      /^[0-9a-f]{64}$/.test(snapshot.business_sha256) &&
      /^[0-9a-f]{64}$/.test(snapshot.payload_tree_sha256) &&
      exactKeys(snapshot.table_counts, [
        'instance_meta', 'users', 'auth_credentials', 'devices', 'sessions',
        'refresh_history', 'vaults', 'vault_members', 'vault_key_envelopes',
        'vault_counters', 'record_heads', 'record_versions', 'change_events',
        'op_receipts', 'batch_receipts', 'record_graveyard', 'snapshots',
        'conflicts', 'uploads', 'upload_chunks', 'blob_objects',
        'object_references', 'invitations', 'membership_manifests',
      ]) && Object.values(snapshot.table_counts).every(Number.isInteger),
    'read-only live snapshot summary had an unexpected shape');
  return snapshot;
}

async function armRestoreWorkerBreakpoint(server, privateRoot) {
  assertThat(Number.isInteger(server?.pid),
    'isolated server PID was unavailable for deterministic restore interruption');
  const gdbVersion = spawnSync('gdb', ['--version'], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 5000,
  });
  assertThat(!gdbVersion.error && gdbVersion.status === 0,
    'deterministic restore interruption requires GDB with ptrace access');
  const gdbReadyPath = path.join(privateRoot, 'restore-gdb-ready');
  const gdbHitPath = path.join(privateRoot, 'restore-gdb-hit');
  const gdbScriptPath = path.join(privateRoot, 'restore-worker.gdb');
  const breakpoint = path.join(ROOT, 'server/src/backup.rs');
  const sourceLines = fs.readFileSync(breakpoint, 'utf8').split(/\r?\n/);
  const readArchiveStart = sourceLines.findIndex((line) =>
    line.startsWith('fn read_encrypted_archive('));
  const readArchiveEnd = sourceLines.findIndex((line, index) =>
    index > readArchiveStart && line.startsWith('fn validate_manifest('));
  const syncLine = sourceLines.findIndex((line, index) =>
    index > readArchiveStart && index < readArchiveEnd &&
    line.trim() === 'output.sync_all()?;');
  assertThat(readArchiveStart >= 0 && readArchiveEnd > readArchiveStart &&
      syncLine > readArchiveStart,
    'restore interruption breakpoint source marker was unavailable');
  const escapedBreakpoint = `"${`${breakpoint}:${syncLine + 1}`
    .replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
  fs.writeFileSync(gdbScriptPath,
    `set pagination off\nset confirm off\nbreak ${escapedBreakpoint}\n` +
      'commands 1\n  silent\n' +
      `  shell touch -- ${posixShellQuote(gdbHitPath)}\n  shell sleep 120\n` +
      'end\n' +
      `shell touch -- ${posixShellQuote(gdbReadyPath)}\ncontinue\n`,
    { flag: 'wx', mode: 0o600 });
  debuggerProcess = spawn('gdb', [
    '--quiet', '--batch', '--pid', String(server.pid), '--command', gdbScriptPath,
  ], {
    cwd: ROOT,
    detached: true,
    stdio: 'ignore',
  });
  assertThat(Number.isInteger(debuggerProcess.pid),
    'debugger process did not start for deterministic restore interruption');
  assertThat(await waitForPath(gdbReadyPath, 15000),
    'debugger could not attach and arm the restore worker breakpoint');
  return { hitPath: gdbHitPath };
}

async function createAdminProfile(page, baseUrl, events) {
  setStage('register administrator: connect and render profile form');
  await configurePage(page, baseUrl);
  setStage('register administrator: fill owner profile fields');
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Admin restore-stage acceptance');
  await fill(page, 'First Vault', 'Admin restore-stage acceptance');
  const start = events.length;
  setStage('register administrator: submit and wait for workspace');
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  setStage('register administrator: validate registration response');
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string' &&
      typeof payload?.account_id === 'string' && typeof payload?.device_id === 'string',
    'administrator registration response was incomplete');
  leakSentinels.push(adminPassword, payload.access_token);
  return {
    accessToken: payload.access_token,
    accountId: payload.account_id,
    deviceId: payload.device_id,
  };
}

async function createMemberProfile(page, baseUrl, events) {
  setStage('register invited member: connect and render invite form');
  await configurePage(page, baseUrl);
  setStage('register invited member: fill invitation fields');
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Member restore-stage acceptance');
  await fill(page, 'First Vault', 'Member restore-stage acceptance');
  const start = events.length;
  setStage('register invited member: submit and wait for workspace');
  await click(page, 'Create invited account');
  setStage('register invited member: validate registration response');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string', 'invited non-admin registration response was incomplete');
  leakSentinels.push(memberPassword, payload.access_token);
  return payload.access_token;
}

function cliBackupJob(baseUrl, token, requestId) {
  return directApi(baseUrl, 'POST', JOBS_PATH, {
    token,
    body: { request_id: requestId, action: 'backup' },
  });
}

async function waitForTerminalJob(baseUrl, token, jobId, archiveId) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const page = await directApi(baseUrl, 'GET', '/api/v1/admin/jobs?limit=100&offset=0', { token });
    assertThat(page.status === 200 && exactKeys(page.payload, ['jobs', 'total']),
      'admin restore job polling failed');
    const job = page.payload.jobs.find((item) => item.job_id === jobId);
    if (job && ['succeeded', 'failed', 'interrupted'].includes(job.status)) {
      return validateJob(job, archiveId);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('restore stage job did not reach a terminal state');
}

async function waitForBackupTerminal(baseUrl, token, jobId) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const page = await directApi(baseUrl, 'GET', '/api/v1/admin/jobs?limit=100&offset=0', { token });
    assertThat(page.status === 200 && exactKeys(page.payload, ['jobs', 'total']),
      'disposable backup job polling failed');
    const job = page.payload.jobs.find((item) => item.job_id === jobId);
    if (job && ['succeeded', 'failed', 'interrupted'].includes(job.status)) return job;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('disposable server backup job did not reach a terminal state');
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-restore-stage-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    const archiveDir = path.join(tempRoot, 'archives');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.mkdirSync(archiveDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    fs.chmodSync(archiveDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const keyPath = path.join(tempRoot, 'operator-backup.key');
    backupKey = crypto.randomBytes(32);
    fs.writeFileSync(keyPath, backupKey, { flag: 'wx', mode: 0o600 });
    fs.chmodSync(keyPath, 0o600);

    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const suffix = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-restore-admin-${suffix}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-restore-member-${suffix}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakSentinels.push(adminPassword, memberPassword, tempRoot, databasePath, keyPath,
      backupKey.toString('hex'), backupKey.toString('base64'));
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
      ATERMIUS_BACKUP_ARCHIVE_DIR: archiveDir,
      ATERMIUS_BACKUP_KEY_FILE: keyPath,
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

    setStage('launch isolated administrator and member profiles');
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

    setStage('register administrator and invited non-admin');
    const adminProfile = await createAdminProfile(adminPage, baseUrl, adminEvents);
    adminAccessToken = adminProfile.accessToken;
    adminAccountId = adminProfile.accountId;
    adminDeviceId = adminProfile.deviceId;
    invitationToken = cliToken(['create-account-invite', '--username', memberUsername],
      serverEnv, 'account invitation');
    memberAccessToken = await createMemberProfile(memberPage, baseUrl, memberEvents);
    reportBoolean('two_isolated_profiles_registered', true);

    setStage('create a genuine server-generated restore source');
    const backupRequestId = crypto.randomUUID();
    const backupAccepted = await cliBackupJob(baseUrl, adminAccessToken, backupRequestId);
    reportStatus('fixture_backup_job', backupAccepted.status);
    assertThat(backupAccepted.status === 202 && exactKeys(backupAccepted.payload, ['job']),
      'disposable server backup job was not accepted');
    const backupJob = backupAccepted.payload.job;
    assertThat(backupJob.action === 'backup' && backupJob.request_id === backupRequestId &&
        UUID_PATTERN.test(backupJob.job_id) && backupJob.archive_id === null &&
        backupJob.archive_source === null,
      'fixture server backup job was malformed');
    const backupTerminal = await waitForBackupTerminal(baseUrl, adminAccessToken, backupJob.job_id);
    assertThat(backupTerminal.status === 'succeeded' && backupTerminal.result_code === 'completed',
      'disposable server backup did not complete successfully');
    const archiveCandidates = fs.readdirSync(archiveDir).filter((name) => name.includes(backupJob.job_id) && name.endsWith('.atb'));
    assertThat(archiveCandidates.length === 1, 'server backup did not create its exact archive');
    const sourceArchivePath = path.join(archiveDir, archiveCandidates[0]);
    const archiveHash = crypto.createHash('sha256').update(fs.readFileSync(sourceArchivePath)).digest('hex');
    assertThat(fs.statSync(sourceArchivePath).isFile() && fs.statSync(sourceArchivePath).size > 0,
      'server backup source was not a nonempty regular file');
    reportBoolean('genuine_server_archive_created', true);

    setStage('verify non-admin controls hidden and restore API denied');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberHasCard = await hasVisibleSemanticText(memberPage, 'Prepare isolated restore copy');
    assertThat(!memberHasCard &&
        !await hasVisibleSemanticText(memberPage, 'Instance jobs') &&
        await memberPage.getByRole('button', {
          name: 'Discard isolated copy', exact: true,
        }).count() === 0,
      'non-admin profile rendered administrator restore controls');
    const unauthRead = await directApi(baseUrl, 'GET', `${RESTORE_SOURCES_PATH}?limit=10&offset=0`);
    reportStatus('unauthenticated_restore_source_read', unauthRead.status);
    assertThat(unauthRead.status === 401, 'unauthenticated restore-source read was not denied');
    const memberRead = await directApi(baseUrl, 'GET', `${RESTORE_SOURCES_PATH}?limit=10&offset=0`,
      { token: memberAccessToken });
    reportStatus('non_admin_restore_source_read', memberRead.status);
    assertThat(memberRead.status === 403, 'non-admin restore-source read was not denied');
    const memberWrite = await directApi(baseUrl, 'POST', JOBS_PATH, {
      token: memberAccessToken,
      body: {
        request_id: crypto.randomUUID(), action: 'restore',
        archive_id: backupJob.job_id, archive_source: 'local',
      },
    });
    reportStatus('non_admin_restore_job_create', memberWrite.status);
    assertThat(memberWrite.status === 403, 'non-admin restore submission was not denied');
    reportBoolean('member_controls_hidden_and_api_denied', true);

    setStage('load and validate the safe restore source in Settings');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy'));
    const sourceStart = adminEvents.length;
    await click(adminPage, 'Load restore sources');
    const sourceEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'restore-sources' && event.method === 'GET' &&
        event.sequence >= sourceStart);
    reportStatus('administrator_restore_source_list', sourceEvent.status);
    assertThat(sourceEvent.hasBearer && sourceEvent.status === 200 &&
        sourceEvent.query.limit && sourceEvent.query.offset,
      'Settings source list was not authenticated and paginated');
    const sourcePayload = await sourceEvent.payloadPromise;
    const sources = validateSources(sourcePayload);
    const source = sources.find((item) => item.archive_id === backupJob.job_id);
    assertThat(source && source.origin === 'manual' &&
        source.archive_bytes === fs.statSync(sourceArchivePath).size,
      'Settings source list omitted the valid generated archive metadata');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Manual'));
    setStage('locate the administrator restore source radio');
    const radio = adminPage.getByRole('radio', { name: /Manual/ }).first();
    await radio.waitFor({ state: 'visible', timeout: 15000 });
    setStage('check the safe restore source radio label');
    const radioLabel = typeof radio.ariaSnapshot === 'function'
      ? await radio.ariaSnapshot() : await radio.innerText();
    assertThat(!radioLabel.includes(source.archive_id),
      'restore source accessible label exposed its internal archive identifier');
    const sourceText = await pageVisibleText(adminPage);
    assertThat(!sourceText.includes(path.basename(sourceArchivePath)), 'Settings exposed an archive basename');
    assertThat(!sourceText.includes(archiveDir) && !sourceText.includes(keyPath) &&
        !sourceText.includes(backupKey.toString('hex')) &&
        !sourceText.includes(backupKey.toString('base64')),
      'Settings exposed an operator path or backup key');
    assertNoLeaks(sourceText);
    reportBoolean('safe_source_metadata_rendered_without_private_values', true);

    setStage('select restore source and cancel without submitting');
    setStage('select the generated restore source');
    await radio.click();
    const postsBeforeCancel = adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST').length;
    setStage('open the cancelable restore confirmation');
    await click(adminPage, 'Prepare isolated copy');
    setStage('verify restore confirmation boundary');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy?'));
    const cancelDialogText = await pageVisibleText(adminPage);
    assertThat(cancelDialogText.includes('does not activate or replace live data'),
      'restore confirmation did not explain the isolated staging boundary');
    const cancel = adminPage.getByRole('button', { name: 'Cancel', exact: true }).last();
    setStage('cancel restore confirmation');
    await cancel.click();
    setStage('verify cancel closed without submission');
    await waitFor(async () =>
      await adminPage.getByRole('button', { name: 'Cancel', exact: true }).count() === 0);
    reportBoolean('cancel_confirmation_action_removed', true);
    await adminPage.waitForTimeout(250);
    const postsAfterCancel = adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST').length;
    assertThat(postsAfterCancel === postsBeforeCancel,
      'canceling restore confirmation submitted an admin job');
    reportBoolean('cancel_did_not_submit_restore_job', true);

    setStage('confirm one idempotent isolated restore job');
    await click(adminPage, 'Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy?'));
    const confirms = adminPage.getByRole('button', { name: 'Prepare isolated copy', exact: true });
    assertThat(await confirms.count() === 1, 'restore confirmation CTA was not uniquely available');
    const postStart = adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST').length;
    await confirms.last().click();
    const postEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-jobs' && event.method === 'POST');
    reportStatus('administrator_restore_job_create', postEvent.status);
    assertThat(postEvent.sequence >= 0 && postEvent.hasBearer && postEvent.status === 202 &&
        exactKeys(postEvent.body, ['request_id', 'action', 'archive_id', 'archive_source']) &&
        UUID_PATTERN.test(postEvent.body.request_id) && postEvent.body.action === 'restore' &&
        postEvent.body.archive_id === source.archive_id &&
        postEvent.body.archive_source === source.source,
      'confirmed restore did not send exactly the strict authenticated request');
    const receipt = await postEvent.payloadPromise;
    assertThat(exactKeys(receipt, ['job']) && receipt.job.archive_id === source.archive_id &&
        receipt.job.archive_source === source.source,
      'restore acceptance receipt omitted its safe source ID');
    const accepted = validateJob(receipt.job, source.archive_id);
    assertThat(adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST').length === postStart + 1,
    'confirmed restore submitted more than one admin job');

    setStage('verify terminal job and isolated publication');
    const terminal = await waitForTerminalJob(baseUrl, adminAccessToken,
      accepted.job_id, source.archive_id);
    assertThat(terminal.status === 'succeeded' && terminal.result_code === 'completed',
      'confirmed restore staging job did not succeed');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Restore staging · Prepared'), 30000);
    const renderedAfter = await pageVisibleText(adminPage);
    assertThat(renderedAfter.includes(accepted.job_id), 'safe stage ID was not available for operator review');
    assertThat(!renderedAfter.includes(path.basename(sourceArchivePath)) &&
        !renderedAfter.includes(archiveDir) && !renderedAfter.includes(keyPath) &&
        !renderedAfter.includes(backupKey.toString('hex')) &&
        !renderedAfter.includes(backupKey.toString('base64')),
      'restore UI disclosed source archive identity, path, basename or key');
    assertNoLeaks(renderedAfter);

    const stagePath = path.join(archiveDir, 'restore-staging', `atermius-restore-${accepted.job_id}`);
    assertThat(fs.statSync(stagePath).isDirectory(), 'successful job did not publish its isolated staged directory');
    assertThat(crypto.createHash('sha256').update(fs.readFileSync(sourceArchivePath)).digest('hex') === archiveHash,
      'restore staging modified its source archive');

    setStage('validate real restore lifecycle in the instance audit API');
    const auditFeed = await directApi(baseUrl, 'GET', `${ADMIN_AUDIT_PATH}?limit=100`, {
      token: adminAccessToken,
    });
    reportStatus('administrator_restore_audit_feed', auditFeed.status);
    assertThat(auditFeed.status === 200,
      'administrator could not read the instance audit feed after restore staging');
    const apiRestoreEvents = validateRestoreAuditLifecycle(auditFeed.payload, adminProfile, accepted.job_id);
    reportBoolean('restore_audit_actor_resource_hmac_source_result_valid', true);
    reportBoolean('restore_audit_three_success_stages_ordered', true);

    setStage('render real restore lifecycle in the Settings audit card');
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const auditButton = await hasVisibleSemanticText(adminPage, 'Refresh admin audit')
      ? 'Refresh admin audit'
      : 'Load admin audit';
    const auditRefreshStart = adminEvents.length;
    await click(adminPage, auditButton);
    const auditRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= auditRefreshStart);
    const refreshedAuditFeed = await auditRefresh.payloadPromise;
    reportStatus('settings_restore_audit_refresh', auditRefresh.status);
    assertThat(auditRefresh.hasBearer && auditRefresh.status === 200,
      'Settings restore audit-card refresh was not authenticated and successful');
    const renderedRestoreEvents = validateRestoreAuditLifecycle(
      refreshedAuditFeed, adminProfile, accepted.job_id);
    const eventFingerprint = (event) => JSON.stringify([
      event.event_id, event.scope, event.actor_user_id, event.actor_device_id, event.action,
      event.resource_type, event.resource_id, event.result, event.occurred_at, event.source,
    ]);
    assertThat(apiRestoreEvents.map(eventFingerprint).join('\n') ===
        renderedRestoreEvents.map(eventFingerprint).join('\n'),
      'Settings refresh did not preserve the three validated restore lifecycle events');
    reportBoolean('settings_restore_audit_events_match_validated_writer_events', true);
    const localizedRestoreActions = [
      ['admin.restore_requested', '管理员已请求恢复任务'],
      ['admin.restore_started', '管理员恢复任务已开始'],
      ['admin.restore_completed', '管理员恢复任务已完成'],
    ];
    for (const [action, label] of localizedRestoreActions) {
      assertThat(renderedRestoreEvents.some((event) => event.action === action),
        'refreshed audit feed omitted a real restore lifecycle action');
      await scrollUntilVisibleSemanticText(adminPage, label);
      const rawActionVisible = await hasVisibleSemanticText(adminPage, action);
      assertThat(!rawActionVisible,
        'Settings audit card displayed a raw restore lifecycle action key');
      reportBoolean(`restore_audit_label_${action.replaceAll('.', '_')}`, true);
    }
    reportBoolean('restore_lifecycle_labels_localized_and_raw_keys_hidden', true);

    setStage('discard the successful isolated copy through Settings');
    const liveBeforeDiscard = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const meBeforeDiscard = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    const dataBeforeDiscard = liveDataSnapshot(databasePath, dataDir);
    const sourceHashBeforeDiscard = crypto.createHash('sha256')
      .update(fs.readFileSync(sourceArchivePath)).digest('hex');
    const stageDirectory = path.dirname(stagePath);
    const preparedStageMetadata = fs.lstatSync(stagePath);
    const preparedStageFiles = fs.readdirSync(stagePath).sort();
    const expectedStageFiles = [
      '.atermius-restore-receipt.json', 'atermius.db',
      'auth-rate-limit.key', 'instance-ed25519.key',
    ];
    const stageDirectoryPrivate = preparedStageMetadata.isDirectory() &&
      !preparedStageMetadata.isSymbolicLink() &&
      (preparedStageMetadata.mode & 0o777) === 0o700;
    const stageFileSetExact = JSON.stringify(preparedStageFiles) ===
      JSON.stringify(expectedStageFiles);
    reportStatus('discard_precondition_live_instance', liveBeforeDiscard.status);
    reportStatus('discard_precondition_admin_session', meBeforeDiscard.status);
    reportBoolean('discard_precondition_source_archive_unchanged',
      sourceHashBeforeDiscard === archiveHash);
    reportBoolean('discard_precondition_stage_directory_private', stageDirectoryPrivate);
    reportBoolean('discard_precondition_stage_file_set_exact', stageFileSetExact);
    reportBoolean('discard_precondition_no_unexpected_stage_entries',
      preparedStageFiles.every((name) => expectedStageFiles.includes(name)));
    reportBoolean('discard_precondition_has_sqlite_wal_sidecar',
      preparedStageFiles.includes('atermius.db-wal'));
    reportBoolean('discard_precondition_has_sqlite_shm_sidecar',
      preparedStageFiles.includes('atermius.db-shm'));
    assertThat(liveBeforeDiscard.status === 200 &&
        typeof liveBeforeDiscard.payload.generation === 'string' &&
        meBeforeDiscard.status === 200 && sourceHashBeforeDiscard === archiveHash &&
        stageDirectoryPrivate && stageFileSetExact,
      'discard preconditions were not stable');
    for (const name of preparedStageFiles) {
      const metadata = fs.lstatSync(path.join(stagePath, name));
      assertThat(metadata.isFile() && !metadata.isSymbolicLink() &&
          (metadata.mode & 0o777) === 0o600 && metadata.nlink === 1,
        'prepared stage contained a non-private or unexpected file');
    }

    await scrollUntilVisibleSemanticText(adminPage, 'Instance jobs');
    const discardButton = adminPage.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    });
    assertThat(await discardButton.count() === 1,
      'the ready restore job did not render one discard control');
    const discardCallsBeforeCancel = adminEvents.filter((event) =>
      event.route === 'restore-stage-discard' && event.method === 'POST').length;
    await discardButton.click();
    await waitFor(() => hasVisibleSemanticText(adminPage,
      'Discard isolated restore copy?'));
    const discardCancelDialog = adminPage.getByRole('button', {
      name: 'Cancel', exact: true,
    }).last();
    await discardCancelDialog.click();
    await waitFor(async () => !await hasVisibleSemanticText(adminPage,
      'Discard isolated restore copy?'));
    await adminPage.waitForTimeout(150);
    assertThat(adminEvents.filter((event) =>
      event.route === 'restore-stage-discard' && event.method === 'POST').length ===
        discardCallsBeforeCancel,
      'canceling stage discard submitted a request');
    reportBoolean('discard_cancel_did_not_submit', true);

    const discardBeforeConfirm = adminEvents.length;
    await discardButton.click();
    await waitFor(() => hasVisibleSemanticText(adminPage,
      'Discard isolated restore copy?'));
    const discardConfirm = adminPage.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    }).last();
    await discardConfirm.click();
    const discardEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'restore-stage-discard' &&
        event.method === 'POST' && event.sequence >= discardBeforeConfirm);
    reportStatus('administrator_restore_stage_discard', discardEvent.status);
    const routeMatch = RESTORE_STAGE_DISCARD_PATH.exec(discardEvent.pathname);
    assertThat(routeMatch && discardEvent.hasBearer && discardEvent.status === 200 &&
        exactKeys(discardEvent.body, ['request_id']) &&
        UUID_PATTERN.test(discardEvent.body.request_id) &&
        routeMatch[1] === accepted.job_id,
      'confirmed discard did not submit the exact authenticated job-bound request');
    const discardReceipt = await discardEvent.payloadPromise;
    assertThat(exactKeys(discardReceipt, ['restore_stage']) &&
        exactKeys(discardReceipt.restore_stage,
          ['restore_job_id', 'status', 'discarded_at']) &&
        discardReceipt.restore_stage.restore_job_id === accepted.job_id &&
        discardReceipt.restore_stage.status === 'discarded' &&
        typeof discardReceipt.restore_stage.discarded_at === 'string' &&
        !Number.isNaN(Date.parse(discardReceipt.restore_stage.discarded_at)),
      'restore stage discard receipt did not match the fixed safe contract');
    assertNoLeaks(discardReceipt);
    const discardedAt = discardReceipt.restore_stage.discarded_at;
    await waitFor(() => hasVisibleSemanticText(adminPage,
      'Restore staging · Discarded'));
    await waitFor(() => hasVisibleSemanticText(adminPage,
      'Isolated copy: discarded'));
    assertThat(await adminPage.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    }).count() === 0,
    'discarded restore job still rendered an actionable discard control');

    setStage('verify idempotent discard, private-file removal and live-data preservation');
    for (const requestId of [discardEvent.body.request_id, crypto.randomUUID()]) {
      const replay = await directApi(baseUrl, 'POST',
        `/api/v1/admin/restore-stages/${accepted.job_id}/discard`, {
          token: adminAccessToken,
          body: { request_id: requestId },
        });
      assertThat(replay.status === 200 && exactKeys(replay.payload, ['restore_stage']) &&
          replay.payload.restore_stage.restore_job_id === accepted.job_id &&
          replay.payload.restore_stage.status === 'discarded' &&
          replay.payload.restore_stage.discarded_at === discardedAt,
        'repeated discard did not return the same durable safe receipt');
    }
    const discardedRowsResponse = await directApi(baseUrl, 'GET',
      '/api/v1/admin/jobs?limit=100&offset=0', { token: adminAccessToken });
    assertThat(discardedRowsResponse.status === 200 &&
        exactKeys(discardedRowsResponse.payload, ['jobs', 'total']),
      'admin job listing failed after stage discard');
    const discardedRow = discardedRowsResponse.payload.jobs.find((item) =>
      item.job_id === accepted.job_id);
    const durableDiscarded = validateJob(discardedRow, source.archive_id);
    assertThat(durableDiscarded.restore_stage_status === 'discarded' &&
        fs.existsSync(stageDirectory) && fs.readdirSync(stageDirectory).length === 0 &&
        !fs.existsSync(stagePath) &&
        crypto.createHash('sha256').update(fs.readFileSync(sourceArchivePath)).digest('hex') ===
          sourceHashBeforeDiscard,
      'discard did not remove only the staging copy and preserve its source archive');
    const liveAfterDiscard = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const meAfterDiscard = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(liveAfterDiscard.status === 200 &&
        liveAfterDiscard.payload.generation === liveBeforeDiscard.payload.generation &&
        meAfterDiscard.status === 200 &&
        JSON.stringify(liveDataSnapshot(databasePath, dataDir)) ===
          JSON.stringify(dataBeforeDiscard),
      'discard changed the live generation, session or business data');
    reportBoolean('discard_removed_stage_only_and_preserved_source_and_live_data', true);

    const memberDiscard = await directApi(baseUrl, 'POST',
      `/api/v1/admin/restore-stages/${accepted.job_id}/discard`, {
        token: memberAccessToken,
        body: { request_id: crypto.randomUUID() },
      });
    reportStatus('non_admin_restore_stage_discard', memberDiscard.status);
    assertThat(memberDiscard.status === 403,
      'non-admin restore-stage discard API was not denied');
    const extraFieldDiscard = await directApi(baseUrl, 'POST',
      `/api/v1/admin/restore-stages/${accepted.job_id}/discard`, {
        token: adminAccessToken,
        body: { request_id: crypto.randomUUID(), stage_path: archiveDir },
      });
    const malformedRequestIdDiscard = await directApi(baseUrl, 'POST',
      `/api/v1/admin/restore-stages/${accepted.job_id}/discard`, {
        token: adminAccessToken,
        body: { request_id: 'not-a-uuid' },
      });
    const malformedJobIdDiscard = await directApi(baseUrl, 'POST',
      '/api/v1/admin/restore-stages/not-a-uuid/discard', {
        token: adminAccessToken,
        body: { request_id: crypto.randomUUID() },
      });
    const missingJobDiscard = await directApi(baseUrl, 'POST',
      `/api/v1/admin/restore-stages/${crypto.randomUUID()}/discard`, {
        token: adminAccessToken,
        body: { request_id: crypto.randomUUID() },
      });
    assertThat(extraFieldDiscard.status === 400 &&
        malformedRequestIdDiscard.status === 400 &&
        malformedJobIdDiscard.status === 400 && missingJobDiscard.status === 404,
      'discard endpoint did not enforce its strict body, canonical request ID and not-found contract');
    reportBoolean('discard_request_shape_and_nonexistent_job_are_strict', true);

    setStage('validate one HMAC audit event and localized Settings label for discard');
    const discardAuditFeed = await directApi(baseUrl, 'GET',
      `${ADMIN_AUDIT_PATH}?limit=100`, { token: adminAccessToken });
    assertThat(discardAuditFeed.status === 200,
      'administrator could not read the restore stage discard audit event');
    const apiDiscardEvent = validateRestoreStageDiscardAuditEvent(
      discardAuditFeed.payload, adminProfile, accepted.job_id);
    const discardAuditRefreshStart = adminEvents.length;
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    await click(adminPage, 'Refresh admin audit');
    const discardAuditRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= discardAuditRefreshStart);
    const renderedDiscardFeed = await discardAuditRefresh.payloadPromise;
    const renderedDiscardEvent = validateRestoreStageDiscardAuditEvent(
      renderedDiscardFeed, adminProfile, accepted.job_id);
    assertThat(JSON.stringify(apiDiscardEvent) === JSON.stringify(renderedDiscardEvent),
      'Settings audit card did not preserve the discard event fingerprint');
    await scrollUntilVisibleSemanticText(adminPage, '管理员已丢弃隔离还原副本');
    assertThat(!await hasVisibleSemanticText(adminPage,
      'admin.restore_stage_discarded'),
    'Settings audit card displayed the raw discard action key');
    reportBoolean('discard_audit_is_single_hmac_event_and_localized', true);

    setStage('create a private corrupt-archive restore failure fixture');
    const sourceBytesBeforeFailure = fs.readFileSync(sourceArchivePath);
    assertThat(crypto.createHash('sha256').update(sourceBytesBeforeFailure).digest('hex') ===
        archiveHash,
      'successful restore source changed before the failure fixture');
    const damagedSourceBytes = Buffer.from(sourceBytesBeforeFailure);
    damagedSourceBytes[damagedSourceBytes.length - 1] ^= 0x01;
    const damagedArchiveHash = crypto.createHash('sha256')
      .update(damagedSourceBytes).digest('hex');
    assertThat(damagedArchiveHash !== archiveHash,
      'corrupt-archive failure fixture did not change its content');
    const instanceBeforeFailure = await directApi(baseUrl, 'GET', '/api/v1/instance');
    assertThat(instanceBeforeFailure.status === 200 &&
        typeof instanceBeforeFailure.payload.generation === 'string',
      'live instance state was unavailable before the failed restore job');

    let failedAccepted;
    let failedTerminal;
    let apiFailedRestoreEvents;
    try {
      // This archive and directory belong exclusively to this disposable test
      // instance. Mutating the final byte deterministically exercises the real
      // restore worker's authentication/validation failure path.
      fs.writeFileSync(sourceArchivePath, damagedSourceBytes);
      const damagedSourcesResponse = await directApi(baseUrl, 'GET',
        `${RESTORE_SOURCES_PATH}?limit=10&offset=0`, { token: adminAccessToken });
      assertThat(damagedSourcesResponse.status === 200,
        'damaged test archive was not readable as a restore source');
      const damagedSources = validateSources(damagedSourcesResponse.payload);
      const damagedSource = damagedSources.find((item) =>
        item.archive_id === source.archive_id && item.source === source.source);
      assertThat(damagedSource &&
          damagedSource.archive_bytes === sourceBytesBeforeFailure.length,
        'deterministic corrupt archive was not retained in the safe source catalog');
      assertThat(await radio.isChecked(),
        'the existing Settings selection did not retain the isolated archive ID');
      reportBoolean('private_corrupt_restore_fixture_catalogued', true);

      setStage('submit a real restore job for the corrupt private archive');
      const postsBeforeFailure = adminEvents.filter((event) =>
        event.route === 'admin-jobs' && event.method === 'POST').length;
      await click(adminPage, 'Prepare isolated copy');
      await waitFor(() => hasVisibleSemanticText(
        adminPage, 'Prepare isolated restore copy?'));
      const failedConfirm = adminPage.getByRole('button', {
        name: 'Prepare isolated copy', exact: true,
      });
      assertThat(await failedConfirm.count() === 1,
        'failed restore confirmation CTA was not uniquely available');
      const failedPostSequenceStart = adminEvents.length;
      await failedConfirm.click();
      const failedPostEvent = await waitForEvent(adminEvents,
        (event) => event.route === 'admin-jobs' &&
          event.method === 'POST' &&
          event.sequence >= failedPostSequenceStart);
      assertThat(failedPostEvent.status === 202 && failedPostEvent.hasBearer &&
          exactKeys(failedPostEvent.body,
            ['request_id', 'action', 'archive_id', 'archive_source']) &&
          UUID_PATTERN.test(failedPostEvent.body.request_id) &&
          failedPostEvent.body.request_id !== accepted.request_id &&
          failedPostEvent.body.action === 'restore' &&
          failedPostEvent.body.archive_id === source.archive_id &&
          failedPostEvent.body.archive_source === source.source,
        'Settings did not submit one strict authenticated failed-restore job');
      const failedReceipt = await failedPostEvent.payloadPromise;
      assertThat(exactKeys(failedReceipt, ['job']) &&
          failedReceipt.job.archive_id === source.archive_id &&
          failedReceipt.job.archive_source === source.source,
        'failed restore acceptance receipt did not preserve its safe source ID');
      failedAccepted = validateJob(failedReceipt.job, source.archive_id);
      assertThat(adminEvents.filter((event) =>
        event.route === 'admin-jobs' && event.method === 'POST').length ===
          postsBeforeFailure + 1,
        'failed restore confirmation submitted more than one admin job');

      setStage('verify real failed restore terminal state');
      failedTerminal = await waitForTerminalJob(baseUrl, adminAccessToken,
        failedAccepted.job_id, source.archive_id);
      assertThat(failedTerminal.status === 'failed' &&
          failedTerminal.result_code === 'restore_failed' &&
          failedTerminal.started_at !== null &&
          failedTerminal.finished_at !== null,
        'corrupt archive did not produce a durable failed restore terminal state');
      await waitFor(() => hasVisibleSemanticText(
        adminPage, 'Restore staging · Failed'), 30000);
      reportBoolean('restore_ui_and_job_show_real_failed_terminal_state', true);

      const failedStagePath = path.join(archiveDir, 'restore-staging',
        `atermius-restore-${failedAccepted.job_id}`);
      const existingStageEntries = fs.readdirSync(path.dirname(stagePath)).sort();
      assertThat(!fs.existsSync(failedStagePath) &&
          JSON.stringify(existingStageEntries) === JSON.stringify([]),
        'failed restore left a staging directory after the successful stage was discarded');
      assertThat(crypto.createHash('sha256')
          .update(fs.readFileSync(sourceArchivePath)).digest('hex') === damagedArchiveHash,
        'failed restore unexpectedly modified its corrupt source archive');

      const instanceAfterFailure = await directApi(baseUrl, 'GET', '/api/v1/instance');
      assertThat(instanceAfterFailure.status === 200 &&
          instanceAfterFailure.payload.generation ===
            instanceBeforeFailure.payload.generation &&
          (await directApi(baseUrl, 'GET', '/api/v1/me', {
            token: adminAccessToken,
          })).status === 200,
        'failed staging changed the live instance generation or took the service offline');
      reportBoolean('failed_restore_preserved_live_instance', true);

      setStage('validate real failed restore lifecycle in the instance audit API');
      const failedAuditFeed = await directApi(baseUrl, 'GET',
        `${ADMIN_AUDIT_PATH}?limit=100`, { token: adminAccessToken });
      assertThat(failedAuditFeed.status === 200,
        'administrator could not read the audit feed after failed restore');
      apiFailedRestoreEvents = validateFailedRestoreAuditLifecycle(
        failedAuditFeed.payload, adminProfile, failedAccepted.job_id);
      assertThat(apiRestoreEvents[0].resource_id !==
          apiFailedRestoreEvents[0].resource_id,
        'success and failure restore jobs shared an audit resource HMAC');
      reportBoolean('restore_failure_audit_actor_hmac_source_result_valid', true);
      reportBoolean('restore_failure_audit_three_stages_ordered', true);

      setStage('render failed restore lifecycle in the Settings audit card');
      const failureAuditRefreshStart = adminEvents.length;
      await click(adminPage, 'Refresh admin audit');
      const failureAuditRefresh = await waitForEvent(adminEvents,
        (event) => event.route === 'admin-audit' && event.method === 'GET' &&
          event.sequence >= failureAuditRefreshStart);
      assertThat(failureAuditRefresh.hasBearer && failureAuditRefresh.status === 200,
        'Settings audit-card refresh after restore failure was not authenticated and successful');
      const renderedFailureFeed = await failureAuditRefresh.payloadPromise;
      const renderedAdminEvents = validateAdminAuditPage(renderedFailureFeed);
      const renderedFailureEvents = validateFailedRestoreAuditLifecycle(
        renderedFailureFeed, adminProfile, failedAccepted.job_id);
      const renderedSuccessEvents = renderedAdminEvents.filter((event) =>
        event.resource_id === apiRestoreEvents[0].resource_id &&
        ['admin.restore_requested', 'admin.restore_started',
          'admin.restore_completed'].includes(event.action));
      const eventFingerprint = (event) => JSON.stringify([
        event.event_id, event.scope, event.actor_user_id, event.actor_device_id,
        event.action, event.resource_type, event.resource_id, event.result,
        event.occurred_at, event.source,
      ]);
      assertThat(apiRestoreEvents.map(eventFingerprint).join('\n') ===
          renderedSuccessEvents.map(eventFingerprint).join('\n') &&
          apiFailedRestoreEvents.map(eventFingerprint).join('\n') ===
            renderedFailureEvents.map(eventFingerprint).join('\n'),
        'Settings audit refresh did not preserve both real restore lifecycle fingerprints');
      const localizedFailureActions = [
        ['admin.restore_requested', '管理员已请求恢复任务'],
        ['admin.restore_started', '管理员恢复任务已开始'],
        ['admin.restore_failed', '管理员恢复任务失败'],
      ];
      for (const [action, label] of localizedFailureActions) {
        assertThat(renderedFailureEvents.some((event) => event.action === action),
          'refreshed audit feed omitted a real failed restore lifecycle action');
        await scrollUntilVisibleSemanticText(adminPage, label);
        assertThat(!await hasVisibleSemanticText(adminPage, action),
          'Settings audit card displayed a raw failed restore action key');
      }
      reportBoolean('restore_failure_labels_localized_and_raw_keys_hidden', true);
    } finally {
      // Restore the exact original fixture bytes even when an assertion fails;
      // the enclosing runner owns and deletes the entire private temp root.
      fs.writeFileSync(sourceArchivePath, sourceBytesBeforeFailure);
    }
    assertThat(crypto.createHash('sha256')
        .update(fs.readFileSync(sourceArchivePath)).digest('hex') === archiveHash,
      'failed restore fixture cleanup did not restore the original source archive');

    setStage('capture live data baseline for interrupted restore recovery');
    const liveBeforeInterrupted = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const meBeforeInterrupted = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(liveBeforeInterrupted.status === 200 &&
        typeof liveBeforeInterrupted.payload.generation === 'string' &&
        meBeforeInterrupted.status === 200,
      'live service baseline was unavailable before restore interruption');
    const liveDataBeforeInterrupted = liveDataSnapshot(databasePath, dataDir);
    const sourceHashBeforeInterrupted = crypto.createHash('sha256')
      .update(fs.readFileSync(sourceArchivePath)).digest('hex');
    assertThat(sourceHashBeforeInterrupted === archiveHash,
      'restore source changed before deterministic interruption');

    setStage('arm GDB after the first private archive file write');
    const restoreBreakpoint = await armRestoreWorkerBreakpoint(serverProcess, tempRoot);
    reportBoolean('real_restore_worker_breakpoint_armed', true);

    setStage('submit third real restore job through Settings');
    await click(adminPage, 'Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Prepare isolated restore copy?'));
    const interruptedConfirm = adminPage.getByRole('button', {
      name: 'Prepare isolated copy', exact: true,
    });
    assertThat(await interruptedConfirm.count() === 1,
      'interrupted restore confirmation CTA was not uniquely available');
    const interruptedPostStart = adminEvents.length;
    await interruptedConfirm.click();
    const interruptedPostEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-jobs' && event.method === 'POST' &&
        event.sequence >= interruptedPostStart);
    assertThat(interruptedPostEvent.hasBearer && interruptedPostEvent.status === 202 &&
        exactKeys(interruptedPostEvent.body,
          ['request_id', 'action', 'archive_id', 'archive_source']) &&
        UUID_PATTERN.test(interruptedPostEvent.body.request_id) &&
        interruptedPostEvent.body.action === 'restore' &&
        interruptedPostEvent.body.archive_id === source.archive_id &&
        interruptedPostEvent.body.archive_source === source.source,
      'Settings did not submit one strict authenticated interrupted-restore job');
    const interruptedReceipt = await interruptedPostEvent.payloadPromise;
    assertThat(exactKeys(interruptedReceipt, ['job']) &&
        interruptedReceipt.job.archive_id === source.archive_id &&
        interruptedReceipt.job.archive_source === source.source,
      'interrupted restore acceptance receipt omitted its safe source ID');
    const interruptedAccepted = validateJob(interruptedReceipt.job, source.archive_id);
    assertThat(adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST').length === 3,
    'restore acceptance browser submitted an unexpected number of restore jobs');

    setStage('wait for the real worker to stop inside isolated staging');
    assertThat(await waitForPath(restoreBreakpoint.hitPath, 45000),
      'real restore worker did not reach the deterministic breakpoint');
    const interruptedStageDir = path.join(archiveDir, 'restore-staging');
    const interruptedTargetPath = path.join(interruptedStageDir,
      `atermius-restore-${interruptedAccepted.job_id}`);
    const interruptedTempPath = `${interruptedTargetPath}.staging`;
    const interruptedTempMetadata = fs.lstatSync(interruptedTempPath);
    const interruptedTempEntries = fs.readdirSync(interruptedTempPath);
    assertThat(interruptedTempMetadata.isDirectory() &&
        !interruptedTempMetadata.isSymbolicLink() &&
        (interruptedTempMetadata.mode & 0o777) === 0o700 &&
        interruptedTempEntries.length === 1 &&
        (() => {
          const fileMetadata = fs.lstatSync(path.join(interruptedTempPath,
            interruptedTempEntries[0]));
          return fileMetadata.isFile() && !fileMetadata.isSymbolicLink() &&
            (fileMetadata.mode & 0o777) === 0o600 && fileMetadata.size > 0;
        })() &&
        !fs.existsSync(interruptedTargetPath),
      'restore worker breakpoint did not leave one private payload file in its exact temporary stage');
    reportBoolean('restore_worker_wrote_private_payload_before_interruption', true);

    setStage('SIGKILL isolated server while real restore worker is paused');
    const crashedServerGroup = serverProcess.pid;
    signalProcessGroup(crashedServerGroup, 'SIGKILL');
    assertThat(await waitForProcessGroupExit(crashedServerGroup, 8000),
      'isolated service did not exit after deterministic SIGKILL');
    reportBoolean('isolated_service_process_group_killed', true);
    await stopServerGroup(debuggerProcess);
    debuggerProcess = undefined;

    setStage('restart the same isolated service for startup recovery');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    reportBoolean('same_database_service_restarted_after_crash', true);

    setStage('verify durable interrupted restore terminal state');
    const interruptedTerminal = await waitForTerminalJob(baseUrl, adminAccessToken,
      interruptedAccepted.job_id, source.archive_id);
    assertThat(interruptedTerminal.status === 'interrupted' &&
        interruptedTerminal.action === 'restore' &&
        interruptedTerminal.result_code === 'interrupted' &&
        interruptedTerminal.started_at !== null &&
        interruptedTerminal.finished_at !== null &&
        interruptedTerminal.archive_source === source.source,
      'startup recovery did not persist the exact interrupted restore terminal DTO');
    const interruptedStageEntries = fs.readdirSync(interruptedStageDir).sort();
    assertThat(!fs.existsSync(interruptedTempPath) &&
        !fs.existsSync(interruptedTargetPath) &&
        JSON.stringify(interruptedStageEntries) === JSON.stringify([]),
      'startup recovery left restore staging artifacts after discard and interruption');
    assertThat(crypto.createHash('sha256')
        .update(fs.readFileSync(sourceArchivePath)).digest('hex') ===
        sourceHashBeforeInterrupted,
      'interrupted restore changed its source archive bytes');

    const liveAfterInterrupted = await directApi(baseUrl, 'GET', '/api/v1/instance');
    const meAfterInterrupted = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(liveAfterInterrupted.status === 200 &&
        liveAfterInterrupted.payload.generation === liveBeforeInterrupted.payload.generation &&
        meAfterInterrupted.status === 200,
      'interrupted restore changed live generation or invalidated the admin session');
    const liveDataAfterInterrupted = liveDataSnapshot(databasePath, dataDir);
    assertThat(JSON.stringify(liveDataAfterInterrupted) ===
        JSON.stringify(liveDataBeforeInterrupted),
      'interrupted restore changed live business rows, keys or opaque payload files');
    reportBoolean('interrupted_restore_preserved_live_generation_and_data', true);

    setStage('refresh Settings restore status after startup recovery');
    const statusRefreshStart = adminEvents.length;
    await click(adminPage, 'Refresh restore status');
    const statusRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-jobs' && event.method === 'GET' &&
        event.sequence >= statusRefreshStart);
    assertThat(statusRefresh.hasBearer && statusRefresh.status === 200,
      'Settings restore-status refresh after restart was not authenticated and successful');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Restore staging · Interrupted'), 30000);
    await waitFor(() => hasVisibleSemanticText(
      adminPage, '隔离还原副本准备任务已中断。在线数据未更改。'), 30000);
    reportBoolean('settings_restore_card_shows_interrupted_after_restart', true);

    setStage('validate interrupted restore lifecycle in the instance audit API');
    const interruptedAuditFeed = await directApi(baseUrl, 'GET',
      `${ADMIN_AUDIT_PATH}?limit=100`, { token: adminAccessToken });
    assertThat(interruptedAuditFeed.status === 200,
      'administrator could not read the audit feed after interrupted restore recovery');
    const apiInterruptedEvents = validateInterruptedRestoreAuditLifecycle(
      interruptedAuditFeed.payload, adminProfile, interruptedAccepted.job_id);
    reportBoolean('restore_interrupted_audit_actor_hmac_source_result_valid', true);
    reportBoolean('restore_interrupted_audit_three_stages_ordered', true);

    setStage('render interrupted restore lifecycle in the Settings audit card');
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const interruptedAuditRefreshStart = adminEvents.length;
    await click(adminPage, 'Refresh admin audit');
    const interruptedAuditRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= interruptedAuditRefreshStart);
    const renderedInterruptedFeed = await interruptedAuditRefresh.payloadPromise;
    assertThat(interruptedAuditRefresh.hasBearer && interruptedAuditRefresh.status === 200,
      'Settings audit-card refresh after interrupted restore was not authenticated and successful');
    const renderedInterruptedEvents = validateInterruptedRestoreAuditLifecycle(
      renderedInterruptedFeed, adminProfile, interruptedAccepted.job_id);
    const auditFingerprint = (event) => JSON.stringify([
      event.event_id, event.scope, event.actor_user_id, event.actor_device_id,
      event.action, event.resource_type, event.resource_id, event.result,
      event.occurred_at, event.source,
    ]);
    assertThat(apiInterruptedEvents.map(auditFingerprint).join('\n') ===
        renderedInterruptedEvents.map(auditFingerprint).join('\n'),
      'Settings audit refresh did not preserve the real interrupted lifecycle fingerprints');
    const localizedInterruptedActions = [
      ['admin.restore_requested', '管理员已请求恢复任务'],
      ['admin.restore_started', '管理员恢复任务已开始'],
      ['admin.restore_interrupted', '管理员恢复任务已中断'],
    ];
    for (const [action, label] of localizedInterruptedActions) {
      assertThat(renderedInterruptedEvents.some((event) => event.action === action),
        'refreshed audit feed omitted a real interrupted restore lifecycle action');
      await scrollUntilVisibleSemanticText(adminPage, label);
      assertThat(!await hasVisibleSemanticText(adminPage, action),
        'Settings audit card displayed a raw interrupted restore action key');
    }
    reportBoolean('restore_interrupted_labels_localized_and_raw_keys_hidden', true);

    const live = await directApi(baseUrl, 'GET', '/api/v1/instance');
    assertThat(live.status === 200 && live.payload.generation,
      'live service stopped responding after isolated staging');
    reportBoolean('live_service_online_and_source_archive_unchanged', true);
    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    reportBoolean('browser_runtime_errors_absent', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test server, browser profile or fixture did not clean up');
  setStage('complete');
  console.log('WEB-ADMIN-RESTORE-STAGE-01 passed');
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
