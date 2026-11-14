/*
 * WEB-PG-BACKUP-REPLICA-RESTORE-01: create an encrypted PostgreSQL backup,
 * observe its shared S3 replica on both nodes, and prepare/discard an isolated
 * restore copy from the remote replica through the Web Settings controls.
 *
 * The browser runner receives only the two loopback API URLs and Web account
 * bootstrap inputs. PG URLs, S3 configuration, credential paths and archive
 * bytes remain outside this process. An optional private handoff pauses after
 * the target reports a ready stage so the fixture owner can inspect it.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const NODE_A_URL = process.env.ATERMIUS_PG_REPLICA_RESTORE_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_REPLICA_RESTORE_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_REPLICA_RESTORE_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_REPLICA_RESTORE_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_REPLICA_RESTORE_BOOTSTRAP_TOKEN;
const HANDOFF_DIR = process.env.ATERMIUS_PG_REPLICA_RESTORE_HANDOFF_DIR;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

const JOBS_PATH = '/api/v1/admin/jobs';
const REPLICATION_PATH = '/api/v1/admin/backup-replication';
const RESTORE_SOURCES_PATH = '/api/v1/admin/restore-sources';
const RESTORE_STAGE_DISCARD_PREFIX = '/api/v1/admin/restore-stages/';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_SOURCE_PAGE = 100;

let stage = 'preflight';
let browser;
let context;
let page;
let adminAccessToken;
let pageErrors = 0;
let requestFailures = 0;
let relayRequests = 0;
let externalRequests = 0;
const secretSentinels = [];
const webApiEvents = [];

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

function report(name, value) {
  console.log(`assert: ${name}=${value}`);
}

function exactKeys(value, expected) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) ===
      JSON.stringify([...expected].sort());
}

function loopbackOrigin(value, name) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (_) {
    assertThat(false, `${name} URL was invalid`);
  }
  assertThat(parsed.protocol === 'http:' && parsed.hostname === '127.0.0.1' &&
      parsed.pathname === '/' && parsed.search === '' && parsed.hash === '' &&
      parsed.username === '' && parsed.password === '',
    `${name} URL was not an HTTP loopback origin`);
  return `${parsed.origin}/`;
}

function readConfiguration() {
  assertThat(typeof NODE_A_URL === 'string' && typeof NODE_B_URL === 'string' &&
      typeof USERNAME === 'string' && USERNAME.length > 0 &&
      typeof PASSWORD === 'string' && PASSWORD.length >= 12 &&
      typeof BOOTSTRAP_TOKEN === 'string' && BOOTSTRAP_TOKEN.length >= 40,
    'PostgreSQL replica restore browser inputs are incomplete');
  const nodeAUrl = loopbackOrigin(NODE_A_URL, 'Node A');
  const nodeBUrl = loopbackOrigin(NODE_B_URL, 'Node B');
  assertThat(nodeAUrl !== nodeBUrl, 'PostgreSQL restore nodes must have distinct origins');
  if (HANDOFF_DIR !== undefined) {
    assertThat(path.isAbsolute(HANDOFF_DIR),
      'PostgreSQL restore handoff directory must be an absolute path');
    const details = fs.lstatSync(HANDOFF_DIR);
    assertThat(details.isDirectory() && !details.isSymbolicLink() &&
        (details.mode & 0o077) === 0,
      'PostgreSQL restore handoff path must be an existing private directory');
    const handoffFiles = [
      'replica-ready.json', 'continue-replica', 'stage-ready.json', 'continue',
      'discarded.json', 'try-missing', 'missing-failed.json', 'corrupt-replica',
    ];
    assertThat(handoffFiles.every((name) => !fs.existsSync(path.join(HANDOFF_DIR, name))),
      'PostgreSQL restore handoff directory contains stale control files');
  }
  secretSentinels.push(PASSWORD, BOOTSTRAP_TOKEN);
  return { nodeAUrl, nodeBUrl, handoffDir: HANDOFF_DIR };
}

function assertNoSecrets(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const secret of secretSentinels) {
    if (typeof secret === 'string' && secret.length >= 8) {
      assertThat(!serialized.includes(secret),
        'a response or rendered view exposed a browser credential');
    }
  }
}

async function field(label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  await locator.scrollIntoViewIfNeeded();
  return locator;
}

async function button(label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function click(label) {
  await (await button(label)).click();
}

async function fill(label, value) {
  const locator = await field(label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 25 });
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    if (await locator.inputValue() === value) return;
  }
  throw new Error(`Web field ${label} did not retain input`);
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web state did not appear');
}

async function hasVisibleSemanticText(needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) return false;
      const attributes = [...element.attributes].map((item) => item.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`.includes(expected);
    });
  }, needle);
}

async function scrollUntilVisibleSemanticText(needle, maxSteps = 48) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(900, 850);
    await page.mouse.wheel(0, 700);
    await page.waitForTimeout(80);
  }
  throw new Error('expected Settings content did not become visible');
}

async function visiblePageText() {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => `${element.textContent || ''}\n` +
        [...element.attributes].map((item) => item.value).join('\n')).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
}

function trackBrowser(baseOrigin) {
  const pending = new WeakMap();
  page.on('pageerror', () => { pageErrors += 1; });
  page.on('request', (request) => {
    let url;
    try {
      url = new URL(request.url());
    } catch (_) {
      return;
    }
    if (['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol) &&
        url.origin !== baseOrigin) externalRequests += 1;
    if (url.pathname.startsWith('/api/v1/relay/')) relayRequests += 1;
    if (url.pathname !== '/api/v1/auth/register' &&
        url.pathname !== JOBS_PATH && url.pathname !== RESTORE_SOURCES_PATH &&
        !url.pathname.startsWith(RESTORE_STAGE_DISCARD_PREFIX)) return;
    let body = null;
    if (url.pathname === JOBS_PATH && request.method() === 'POST') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    } else if (url.pathname.startsWith(RESTORE_STAGE_DISCARD_PREFIX) &&
        request.method() === 'POST') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    pending.set(request, {
      pathname: url.pathname,
      method: request.method(),
      query: Object.fromEntries(url.searchParams.entries()),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      body,
    });
  });
  page.on('requestfailed', () => { requestFailures += 1; });
  page.on('response', (response) => {
    const metadata = pending.get(response.request());
    if (!metadata) return;
    webApiEvents.push({
      ...metadata,
      status: response.status(),
      sequence: webApiEvents.length,
      payload: response.json().catch(() => null),
    });
  });
}

async function waitForWebApi(predicate, startIndex, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = webApiEvents.slice(startIndex).find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Settings API request did not complete');
}

async function requestJson(baseUrl, method, pathname, token, body) {
  const response = await fetch(new URL(pathname.replace(/^\/+/, ''), baseUrl), {
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
  assertNoSecrets(payload);
  return { status: response.status, payload };
}

async function waitForReady(baseUrl) {
  const response = await fetch(new URL('health/ready', baseUrl), {
    signal: AbortSignal.timeout(5000),
  });
  assertThat(response.status === 200, 'a PostgreSQL restore node was not ready');
}

async function configureWeb(baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
  await fill('Server URL', baseUrl);
  await click('Connect securely');
}

async function registerAllowlistedOwner(baseUrl) {
  setStage('register allowlisted owner through Web');
  await configureWeb(baseUrl);
  await field('Owner email');
  await fill('Owner email', USERNAME);
  await fill('Master password · 12+ characters', PASSWORD);
  await fill('Confirm master password', PASSWORD);
  await fill('One-time bootstrap token', BOOTSTRAP_TOKEN);
  await fill('Device name', 'PostgreSQL replica restore acceptance');
  await fill('First Vault', 'PostgreSQL replica restore acceptance');
  const start = webApiEvents.length;
  await click('Create owner account');
  await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const event = await waitForWebApi((item) =>
    item.pathname === '/api/v1/auth/register' && item.method === 'POST', start);
  const payload = await event.payload;
  assertThat(event.status >= 200 && event.status < 300 &&
      typeof payload?.access_token === 'string' && payload.access_token.length >= 40 &&
      UUID_RE.test(payload?.account_id) && UUID_RE.test(payload?.device_id),
    'Web bootstrap owner registration response was incomplete');
  const serialized = JSON.stringify(payload);
  assertThat(!serialized.includes(PASSWORD) && !serialized.includes(BOOTSTRAP_TOKEN),
    'Web registration response echoed an input credential');
  adminAccessToken = payload.access_token;
  secretSentinels.push(adminAccessToken);
  report('allowlisted_owner_registered_in_web', true);
}

function validateJob(job, expected = {}) {
  const keys = [
    'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status',
    'requested_at', 'started_at', 'finished_at', 'result_code', 'restore_stage_status',
  ];
  assertThat(exactKeys(job, keys) && UUID_RE.test(job.job_id) &&
      UUID_RE.test(job.request_id) && UUID_RE.test(job.archive_id) &&
      ['backup', 'restore'].includes(job.action) &&
      ['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
    'administrator job DTO had an unexpected shape');
  const validTimestamp = (value) => typeof value === 'string' &&
    Number.isFinite(Date.parse(value));
  assertThat(validTimestamp(job.requested_at) &&
      (job.started_at === null || validTimestamp(job.started_at)) &&
      (job.finished_at === null || validTimestamp(job.finished_at)) &&
      (job.result_code === null || [
        'completed', 'backup_failed', 'restore_failed', 'interrupted',
      ].includes(job.result_code)) &&
      (job.restore_stage_status === null || [
        'ready', 'failed', 'discarding', 'discarded', 'unverified', 'interrupted',
      ].includes(job.restore_stage_status)),
    'administrator job timestamps were invalid');
  if (expected.jobId !== undefined) {
    assertThat(job.job_id === expected.jobId && job.request_id === expected.requestId &&
        job.action === expected.action && job.archive_id === expected.archiveId &&
        job.archive_source === expected.archiveSource,
      'administrator job did not preserve its exact request and archive source');
  }
  if (job.action === 'backup') {
    assertThat(job.archive_source === null && job.restore_stage_status === null,
      'manual backup DTO exposed an invalid source or restore stage');
  } else {
    assertThat(job.archive_source === 'local' || job.archive_source === 'replica',
      'restore job did not identify its fixed archive source');
  }
  assertNoSecrets(job);
  return job;
}

async function getJobs(baseUrl) {
  const result = await requestJson(
    baseUrl, 'GET', `${JOBS_PATH}?limit=${MAX_SOURCE_PAGE}&offset=0`, adminAccessToken);
  const validShape = exactKeys(result.payload, ['jobs', 'total']) ||
    exactKeys(result.payload, ['jobs', 'supported_actions', 'total']);
  assertThat(result.status === 200 && validShape &&
      Array.isArray(result.payload.jobs) && Number.isInteger(result.payload.total) &&
      result.payload.total >= result.payload.jobs.length &&
      (result.payload.supported_actions === undefined ||
        (Array.isArray(result.payload.supported_actions) &&
          result.payload.supported_actions.every((item) => typeof item === 'string'))),
    'administrator job page response was invalid');
  return result.payload;
}

async function waitForJob(baseUrl, jobId, accept, timeoutMs, failureLabel) {
  const deadline = Date.now() + timeoutMs;
  const seen = new Set();
  while (Date.now() < deadline) {
    const pageData = await getJobs(baseUrl);
    const raw = pageData.jobs.find((job) => job.job_id === jobId);
    if (raw) {
      const job = validateJob(raw);
      seen.add(job.status);
      if (accept(job)) return { job, seen: [...seen] };
      if (['failed', 'interrupted'].includes(job.status)) {
        throw new Error(failureLabel);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(failureLabel);
}

function validateReplicationStatus(payload) {
  assertThat(exactKeys(payload, ['configured', 'latest_attempt', 'operation', 'pending_count']) &&
      payload.operation === 'backup_replication' && typeof payload.configured === 'boolean' &&
      Number.isInteger(payload.pending_count) && payload.pending_count >= 0,
    'replication status DTO had an unexpected shape');
  if (payload.latest_attempt !== null) {
    const attempt = payload.latest_attempt;
    assertThat(exactKeys(attempt, [
      'archive_bytes', 'archive_id', 'attempted_at', 'completed_at', 'failure_category', 'state',
    ]) && UUID_RE.test(attempt.archive_id) &&
        ['pending_archive', 'pending', 'running', 'retry_wait', 'succeeded', 'interrupted', 'failed']
          .includes(attempt.state) &&
        typeof attempt.attempted_at === 'string' &&
        Number.isFinite(Date.parse(attempt.attempted_at)) &&
        (attempt.completed_at === null ||
          (typeof attempt.completed_at === 'string' &&
            Number.isFinite(Date.parse(attempt.completed_at)))) &&
        (attempt.archive_bytes === null ||
          (Number.isSafeInteger(attempt.archive_bytes) && attempt.archive_bytes > 0)) &&
        (attempt.failure_category === null || [
          'archive_unavailable', 'credentials_invalid', 'remote_unavailable',
          'remote_integrity_mismatch', 'replication_failed',
        ].includes(attempt.failure_category)),
    'replication attempt DTO had an unexpected shape');
  }
  assertNoSecrets(payload);
  return payload;
}

async function waitForReplica(baseUrl, archiveId, timeoutMs = 240000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await requestJson(baseUrl, 'GET', REPLICATION_PATH, adminAccessToken);
    assertThat(result.status === 200, 'Node B replication status read failed');
    const status = validateReplicationStatus(result.payload);
    if (status.latest_attempt?.archive_id === archiveId &&
        status.latest_attempt.state === 'succeeded' && status.pending_count === 0) {
      return status;
    }
    if (status.latest_attempt?.archive_id === archiveId &&
        ['failed', 'interrupted'].includes(status.latest_attempt.state)) {
      throw new Error('Node B replication ended in a fixed failure state');
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('Node B replication did not complete before the deadline');
}

function validateSourcePage(payload) {
  assertThat(exactKeys(payload, ['sources', 'total']) &&
      Array.isArray(payload.sources) && Number.isInteger(payload.total) &&
      payload.total === payload.sources.length && payload.total <= MAX_SOURCE_PAGE,
    'restore source catalog page was incomplete or malformed');
  for (const source of payload.sources) {
    assertThat(exactKeys(source, ['archive_id', 'created_at', 'archive_bytes', 'origin', 'source']) &&
        UUID_RE.test(source.archive_id) && Number.isSafeInteger(source.archive_bytes) &&
        source.archive_bytes > 0 && ['manual', 'scheduled'].includes(source.origin) &&
        ['local', 'replica'].includes(source.source) &&
        typeof source.created_at === 'string' && Number.isFinite(Date.parse(source.created_at)),
    'restore source metadata was not the safe closed DTO');
  }
  assertNoSecrets(payload);
  return payload.sources;
}

async function readRestoreSources(baseUrl) {
  const result = await requestJson(baseUrl, 'GET',
    `${RESTORE_SOURCES_PATH}?limit=${MAX_SOURCE_PAGE}&offset=0`, adminAccessToken);
  assertThat(result.status === 200, 'a PostgreSQL restore source catalog could not be read');
  return validateSourcePage(result.payload);
}

async function inspectBrowserPersistence() {
  return page.evaluate(async (values) => {
    let leaked = false;
    let readErrors = 0;
    const needles = values.filter((value) => typeof value === 'string' && value.length >= 8);
    const check = (value) => {
      if (typeof value === 'string' && needles.some((needle) => value.includes(needle))) {
        leaked = true;
      }
    };
    const visit = (value, seen = new WeakSet()) => {
      if (typeof value === 'string') { check(value); return; }
      if (!value || typeof value !== 'object' || seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) {
        for (const item of value) visit(item, seen);
        return;
      }
      for (const [key, item] of Object.entries(value)) {
        check(key);
        visit(item, seen);
      }
    };
    for (const storage of [localStorage, sessionStorage]) {
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        check(key || '');
        check(key ? storage.getItem(key) || '' : '');
      }
    }
    try {
      if (typeof indexedDB.databases === 'function') {
        for (const info of await indexedDB.databases()) {
          if (!info.name) continue;
          const db = await new Promise((resolve, reject) => {
            const request = indexedDB.open(info.name);
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
            request.onblocked = () => reject(new Error('blocked'));
          });
          try {
            for (const storeName of Array.from(db.objectStoreNames)) {
              const rows = await new Promise((resolve, reject) => {
                const request = db.transaction(storeName, 'readonly')
                  .objectStore(storeName).getAll();
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => reject(request.error);
              });
              for (const row of rows) visit(row);
            }
          } finally {
            db.close();
          }
        }
      } else {
        readErrors += 1;
      }
    } catch (_) {
      readErrors += 1;
    }
    return { leaked, readErrors };
  }, secretSentinels);
}

async function writeHandoffPause(handoffDir, markerName, markerValue, signalName) {
  if (!handoffDir) return;
  const directory = fs.lstatSync(handoffDir);
  assertThat(directory.isDirectory() && !directory.isSymbolicLink() &&
      (directory.mode & 0o077) === 0,
    'restore handoff directory changed type');
  const permittedHandoffs = {
    'replica-ready.json': { fields: ['archive_id'], signal: 'continue-replica' },
    'stage-ready.json': { fields: ['archive_id', 'job_id'], signal: 'continue' },
    'discarded.json': { fields: ['archive_id'], signal: 'try-missing' },
    'missing-failed.json': { fields: ['archive_id'], signal: 'corrupt-replica' },
  };
  const permitted = permittedHandoffs[markerName];
  assertThat(permitted && permitted.signal === signalName &&
      exactKeys(markerValue, permitted.fields) &&
      UUID_RE.test(markerValue.archive_id) &&
      (markerValue.job_id === undefined || UUID_RE.test(markerValue.job_id)),
    'restore handoff marker was not limited to safe archive and job identifiers');
  const readyPath = path.join(handoffDir, markerName);
  const tempPath = path.join(handoffDir, `.${markerName}.${process.pid}.${crypto.randomUUID()}.tmp`);
  const content = JSON.stringify(markerValue);
  let file;
  try {
    file = await fs.promises.open(tempPath, 'wx', 0o600);
    await file.writeFile(content, { encoding: 'utf8' });
    await file.sync();
    await file.close();
    file = undefined;
    await fs.promises.rename(tempPath, readyPath);
  } catch (_) {
    await file?.close().catch(() => {});
    await fs.promises.unlink(tempPath).catch(() => {});
    throw new Error('safe restore handoff marker could not be written');
  }
  report(`private_handoff_${markerName.replace(/[^a-z]+/gi, '_').toLowerCase()}_written`, true);
  const continuePath = path.join(handoffDir, signalName);
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    try {
      const details = await fs.promises.lstat(continuePath);
      assertThat(details.isFile() && !details.isSymbolicLink(),
        'restore handoff continue marker was not a regular file');
      report(`private_handoff_${signalName.replace(/[^a-z]+/gi, '_').toLowerCase()}_received`, true);
      return;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  report(`private_handoff_${signalName.replace(/[^a-z]+/gi, '_').toLowerCase()}_timed_out_auto_continue`, true);
}

async function main() {
  const config = readConfiguration();
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
    'current Flutter Web Release bundle is missing');
  const bundleSha256 = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');

  try {
    setStage('wait for both PostgreSQL nodes');
    await Promise.all([waitForReady(config.nodeAUrl), waitForReady(config.nodeBUrl)]);

    const options = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(options);
    context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    page = await context.newPage();
    trackBrowser(new URL(config.nodeAUrl).origin);

    await registerAllowlistedOwner(config.nodeAUrl);

    setStage('verify PostgreSQL advertises replica restore capability');
    const capabilityPage = await getJobs(config.nodeAUrl);
    const actions = capabilityPage.supported_actions;
    assertThat(Array.isArray(actions) && actions.includes('backup_replication') &&
        actions.includes('restore') && actions.includes('restore_replica') &&
        actions.includes('restore_stage_discard'),
      'PostgreSQL admin capabilities did not include backup replication and replica restore');
    const profile = await requestJson(config.nodeAUrl, 'GET', '/api/v1/me', adminAccessToken);
    assertThat(profile.status === 200 && profile.payload?.policy?.instance_admin === true,
      'registered Web owner was not recognized as the allowlisted administrator');
    report('pg_restore_replica_capability_advertised', true);

    setStage('create one manual encrypted backup');
    const backupRequestId = crypto.randomUUID();
    const backupResponse = await requestJson(config.nodeAUrl, 'POST', JOBS_PATH,
      adminAccessToken, { request_id: backupRequestId, action: 'backup' });
    assertThat(backupResponse.status === 202 && exactKeys(backupResponse.payload, ['job']),
      'manual PostgreSQL backup job was not accepted');
    const acceptedBackup = validateJob(backupResponse.payload.job, {
      jobId: backupResponse.payload.job?.job_id,
      requestId: backupRequestId,
      action: 'backup',
      archiveId: backupResponse.payload.job?.archive_id,
      archiveSource: null,
    });
    assertThat(acceptedBackup.job_id === acceptedBackup.archive_id &&
        acceptedBackup.request_id === backupRequestId,
      'manual backup receipt did not preserve the archive identity');
    const archiveId = acceptedBackup.archive_id;
    report('manual_encrypted_backup_accepted', true);

    setStage('observe the successful backup and S3 replication from Node B');
    const backupOnB = await waitForJob(config.nodeBUrl, acceptedBackup.job_id,
      (job) => job.status === 'succeeded' && job.result_code === 'completed',
      180000, 'Node B did not observe a successful manual backup job');
    assertThat(backupOnB.job.archive_id === archiveId,
      'Node B backup job did not preserve the archive identity');
    const replicaStatus = await waitForReplica(config.nodeBUrl, archiveId);
    assertThat(replicaStatus.configured && replicaStatus.latest_attempt?.state === 'succeeded' &&
        replicaStatus.latest_attempt.failure_category === null &&
        replicaStatus.latest_attempt.completed_at !== null && replicaStatus.pending_count === 0,
      'Node B did not report verified replication success');
    report('node_b_verified_replication_success', true);

    setStage('compare safe replica restore-source catalogs on both nodes');
    const [sourcesA, sourcesB] = await Promise.all([
      readRestoreSources(config.nodeAUrl), readRestoreSources(config.nodeBUrl),
    ]);
    const replicasA = sourcesA.filter((source) => source.source === 'replica')
      .sort((left, right) => left.archive_id.localeCompare(right.archive_id));
    const replicasB = sourcesB.filter((source) => source.source === 'replica')
      .sort((left, right) => left.archive_id.localeCompare(right.archive_id));
    const replicaA = replicasA.find((source) => source.archive_id === archiveId);
    const replicaB = replicasB.find((source) => source.archive_id === archiveId);
    assertThat(replicaA && replicaB && replicaA.origin === 'manual' &&
        replicaB.origin === 'manual' && JSON.stringify(replicasA) === JSON.stringify(replicasB),
      'Node A and Node B did not expose the same safe replica source catalog');
    report('safe_replica_catalogs_match_across_nodes', true);

    if (config.handoffDir) {
      setStage('pause for replica object verification before restore submission');
      await writeHandoffPause(config.handoffDir, 'replica-ready.json', { archive_id: archiveId },
        'continue-replica');
    }

    setStage('open Settings and load replica restore sources');
    await click('Settings');
    await scrollUntilVisibleSemanticText('Prepare isolated restore copy');
    await waitFor(() => hasVisibleSemanticText('Load restore sources'));
    const sourcesStart = webApiEvents.length;
    await click('Load restore sources');
    const sourceEvent = await waitForWebApi((event) =>
      event.pathname === RESTORE_SOURCES_PATH && event.method === 'GET' &&
        event.sequence >= sourcesStart);
    assertThat(sourceEvent.status === 200 && sourceEvent.hasBearer &&
        sourceEvent.query.limit && sourceEvent.query.offset,
      'Settings did not load the authenticated PostgreSQL restore source catalog');
    const uiSources = validateSourcePage(await sourceEvent.payload);
    const uiReplicasInOrder = uiSources.filter((source) => source.source === 'replica');
    const uiReplicas = [...uiReplicasInOrder]
      .sort((left, right) => left.archive_id.localeCompare(right.archive_id));
    assertThat(JSON.stringify(uiReplicas) === JSON.stringify(replicasA),
      'Settings did not receive the same safe replica source catalog as the API nodes');

    const replicaIndex = uiReplicasInOrder.findIndex((source) => source.archive_id === archiveId);
    const remoteRadios = page.getByRole('radio', { name: /Remote replica/ });
    await waitFor(async () => await remoteRadios.count() === uiReplicas.length);
    assertThat(replicaIndex >= 0 && await remoteRadios.count() === uiReplicas.length,
      'Settings did not render each available remote replica as a selectable source');
    const replicaRadio = remoteRadios.nth(replicaIndex);
    await replicaRadio.waitFor({ state: 'visible', timeout: 15000 });
    const accessibleLabel = typeof replicaRadio.ariaSnapshot === 'function'
      ? await replicaRadio.ariaSnapshot() : await replicaRadio.innerText();
    assertThat(!accessibleLabel.includes(archiveId),
      'Settings exposed the internal archive ID in the replica source label');
    await replicaRadio.click();
    report('settings_selected_remote_replica', true);

    setStage('prepare an isolated restore copy through Settings');
    await click('Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText('Prepare isolated restore copy?'));
    const confirmation = await visiblePageText();
    assertNoSecrets(confirmation);
    assertThat(confirmation.includes('does not activate or replace live data'),
      'Settings restore confirmation omitted the live-data safety boundary');
    const confirmButton = page.getByRole('button', {
      name: 'Prepare isolated copy', exact: true,
    });
    assertThat(await confirmButton.count() === 1,
      'Settings did not present exactly one restore confirmation action');
    const restoreStart = webApiEvents.length;
    await confirmButton.click();
    const restoreEvent = await waitForWebApi((event) =>
      event.pathname === JOBS_PATH && event.method === 'POST' &&
        event.sequence >= restoreStart);
    assertThat(restoreEvent.status === 202 && restoreEvent.hasBearer &&
        exactKeys(restoreEvent.body, ['request_id', 'action', 'archive_id', 'archive_source']) &&
        UUID_RE.test(restoreEvent.body.request_id) && restoreEvent.body.action === 'restore' &&
        restoreEvent.body.archive_id === archiveId && restoreEvent.body.archive_source === 'replica',
      'Settings did not submit the strict authenticated replica restore request');
    const restoreReceipt = await restoreEvent.payload;
    assertThat(exactKeys(restoreReceipt, ['job']) &&
        restoreReceipt.job?.archive_id === archiveId &&
        restoreReceipt.job?.archive_source === 'replica' &&
        restoreReceipt.job?.request_id === restoreEvent.body.request_id,
      'replica restore receipt did not match the Settings request');
    const acceptedRestore = validateJob(restoreReceipt.job, {
      jobId: restoreReceipt.job.job_id,
      requestId: restoreEvent.body.request_id,
      action: 'restore',
      archiveId,
      archiveSource: 'replica',
    });
    assertThat(webApiEvents.filter((event) =>
      event.pathname === JOBS_PATH && event.method === 'POST').length === 1,
    'Settings submitted an unexpected number of administrator jobs');
    report('settings_submitted_replica_restore_once', true);

    setStage('wait for Node B to observe the ready replica restore stage');
    const preparedOnB = await waitForJob(config.nodeBUrl, acceptedRestore.job_id,
      (job) => job.status === 'succeeded' && job.restore_stage_status === 'ready',
      180000, 'Node B did not observe the ready replica restore stage');
    assertThat(preparedOnB.job.archive_source === 'replica' &&
        preparedOnB.job.archive_id === archiveId,
      'Node B restore job did not retain the remote archive source');
    report('node_b_observed_ready_replica_restore_stage', true);

    setStage('verify prepared replica stage in Web Settings');
    await scrollUntilVisibleSemanticText('Restore staging · Prepared', 60);
    await scrollUntilVisibleSemanticText('Stage ID', 60);
    await scrollUntilVisibleSemanticText(acceptedRestore.job_id, 60);
    const settingsBeforeDiscard = await visiblePageText();
    assertNoSecrets(settingsBeforeDiscard);
    report('settings_rendered_prepared_replica_stage', true);

    if (config.handoffDir) {
      await writeHandoffPause(config.handoffDir, 'stage-ready.json', {
        job_id: acceptedRestore.job_id,
        archive_id: archiveId,
      }, 'continue');
    }

    setStage('discard the isolated replica restore copy through Settings');
    await scrollUntilVisibleSemanticText('Instance jobs', 60);
    const discardButton = page.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    });
    assertThat(await discardButton.count() === 1,
      'Settings did not render one discard control for the prepared replica stage');
    const discardStart = webApiEvents.length;
    await discardButton.click();
    await waitFor(() => hasVisibleSemanticText('Discard isolated restore copy?'));
    const confirmDiscard = page.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    });
    assertThat(await confirmDiscard.count() === 1,
      'Settings did not render exactly one discard confirmation action');
    await confirmDiscard.click();
    const discardEvent = await waitForWebApi((event) =>
      event.pathname === `${RESTORE_STAGE_DISCARD_PREFIX}${acceptedRestore.job_id}/discard` &&
        event.method === 'POST' && event.sequence >= discardStart);
    assertThat(discardEvent.status === 200 && discardEvent.hasBearer &&
        exactKeys(discardEvent.body, ['request_id']) && UUID_RE.test(discardEvent.body.request_id),
      'Settings did not submit the strict authenticated restore-stage discard request');
    const discardReceipt = await discardEvent.payload;
    assertThat(exactKeys(discardReceipt, ['restore_stage']) &&
        exactKeys(discardReceipt.restore_stage, ['restore_job_id', 'status', 'discarded_at']) &&
        discardReceipt.restore_stage.restore_job_id === acceptedRestore.job_id &&
        discardReceipt.restore_stage.status === 'discarded' &&
        typeof discardReceipt.restore_stage.discarded_at === 'string' &&
        Number.isFinite(Date.parse(discardReceipt.restore_stage.discarded_at)),
      'Settings discard receipt did not match the safe closed contract');
    assertNoSecrets(discardReceipt);
    await waitFor(() => hasVisibleSemanticText('Restore staging · Discarded'));
    await waitFor(() => hasVisibleSemanticText('Isolated copy: discarded'));

    setStage('verify Node B observes the cross-node discarded stage');
    const discardedOnB = await waitForJob(config.nodeBUrl, acceptedRestore.job_id,
      (job) => job.restore_stage_status === 'discarded', 30000,
      'Node B did not observe the discarded replica restore stage');
    assertThat(discardedOnB.job.archive_source === 'replica' &&
        discardedOnB.job.archive_id === archiveId &&
        discardedOnB.job.status === 'succeeded',
      'Node B discarded job lost its durable replica source or job outcome');
    const stillOnline = await requestJson(config.nodeAUrl, 'GET', '/api/v1/me', adminAccessToken);
    assertThat(stillOnline.status === 200,
      'source PostgreSQL instance did not remain available after isolated stage discard');
    report('node_b_observed_discarded_replica_restore_stage', true);

    if (config.handoffDir) {
      setStage('pause for missing-replica negative restore check');
      await writeHandoffPause(config.handoffDir, 'discarded.json', { archive_id: archiveId },
        'try-missing');

      setStage('submit a safe negative restore request after replica removal');
      const missingRequestId = crypto.randomUUID();
      const missingResponse = await requestJson(config.nodeAUrl, 'POST', JOBS_PATH,
        adminAccessToken, {
          request_id: missingRequestId,
          action: 'restore',
          archive_id: archiveId,
          archive_source: 'replica',
        });
      assertThat(missingResponse.status === 202 &&
          exactKeys(missingResponse.payload, ['job']),
        'missing-replica restore was not accepted as a durable administrator job');
      const missingAccepted = validateJob(missingResponse.payload.job, {
        jobId: missingResponse.payload.job?.job_id,
        requestId: missingRequestId,
        action: 'restore',
        archiveId,
        archiveSource: 'replica',
      });
      assertThat(missingAccepted.job_id !== acceptedRestore.job_id,
        'missing-replica retry unexpectedly reused the discarded restore job');

      const missingFailure = (job) => job.status === 'failed' &&
        job.result_code === 'restore_failed' && job.archive_source === 'replica' &&
        job.archive_id === archiveId && job.restore_stage_status === 'failed';
      const [missingOnA, missingOnB] = await Promise.all([
        waitForJob(config.nodeAUrl, missingAccepted.job_id, missingFailure, 90000,
          'Node A did not record the fixed missing-replica restore failure'),
        waitForJob(config.nodeBUrl, missingAccepted.job_id, missingFailure, 90000,
          'Node B did not observe the fixed missing-replica restore failure'),
      ]);
      for (const observed of [missingOnA.job, missingOnB.job]) {
        assertThat(observed.result_code === 'restore_failed' &&
            observed.archive_source === 'replica' && observed.archive_id === archiveId &&
            observed.restore_stage_status === 'failed',
          'missing-replica failure lost its fixed outcome or source');
      }
      report('missing_replica_restore_failed_safely_on_both_nodes', true);
      report('missing_replica_public_job_dto_has_no_binding_or_provider_diagnostics', true);

      setStage('pause before same-length remote content mismatch check');
      await writeHandoffPause(config.handoffDir, 'missing-failed.json', { archive_id: archiveId },
        'corrupt-replica');
      const corruptRequestId = crypto.randomUUID();
      const corruptResponse = await requestJson(config.nodeAUrl, 'POST', JOBS_PATH,
        adminAccessToken, {
          request_id: corruptRequestId,
          action: 'restore',
          archive_id: archiveId,
          archive_source: 'replica',
        });
      assertThat(corruptResponse.status === 202 &&
          exactKeys(corruptResponse.payload, ['job']),
        'content-mismatch restore was not accepted as a durable administrator job');
      const corruptAccepted = validateJob(corruptResponse.payload.job, {
        jobId: corruptResponse.payload.job?.job_id,
        requestId: corruptRequestId,
        action: 'restore',
        archiveId,
        archiveSource: 'replica',
      });
      assertThat(corruptAccepted.job_id !== acceptedRestore.job_id &&
          corruptAccepted.job_id !== missingAccepted.job_id,
        'content-mismatch restore unexpectedly reused an earlier restore job');
      const contentMismatchFailure = (job) => job.status === 'failed' &&
        job.result_code === 'restore_failed' && job.archive_source === 'replica' &&
        job.archive_id === archiveId && job.restore_stage_status === 'failed';
      const [mismatchOnA, mismatchOnB] = await Promise.all([
        waitForJob(config.nodeAUrl, corruptAccepted.job_id, contentMismatchFailure, 90000,
          'Node A did not record the fixed content-mismatch restore failure'),
        waitForJob(config.nodeBUrl, corruptAccepted.job_id, contentMismatchFailure, 90000,
          'Node B did not observe the fixed content-mismatch restore failure'),
      ]);
      for (const observed of [mismatchOnA.job, mismatchOnB.job]) {
        assertThat(observed.result_code === 'restore_failed' &&
            observed.archive_source === 'replica' && observed.archive_id === archiveId &&
            observed.restore_stage_status === 'failed',
          'content-mismatch failure lost its fixed outcome or source');
      }
      report('mismatched_replica_digest_failed_safely_on_both_nodes', true);
    } else {
      report('missing_replica_negative_check_skipped_without_private_handoff', true);
      report('content_mismatch_negative_check_skipped_without_private_handoff', true);
    }

    setStage('check browser storage and request cleanliness');
    const visible = await visiblePageText();
    assertNoSecrets(visible);
    const persistence = await inspectBrowserPersistence();
    assertThat(!persistence.leaked && persistence.readErrors === 0,
      'a browser credential was persisted in readable Web storage');
    assertThat(pageErrors === 0 && requestFailures === 0 && relayRequests === 0 &&
        externalRequests === 0,
      'Web replica restore had a page, request, Relay, or external-network error');
    report('browser_storage_credentials_absent', true);
    report('page_errors', pageErrors);
    report('request_failures', requestFailures);
    report('relay_requests', relayRequests);
    report('external_requests', externalRequests);
    report('web_release_sha256', bundleSha256);
    report('pg_backup_replica_restore_web_pass', true);
    console.log('WEB-PG-BACKUP-REPLICA-RESTORE-01 passed');
  } catch (error) {
    const safe = typeof error?.safeAssertion === 'string'
      ? error.safeAssertion : 'unexpected_failure';
    console.error(`PG replica restore browser acceptance failed at ${stage}: ${safe}`);
    process.exitCode = 1;
  } finally {
    setStage('close isolated Chromium context');
    adminAccessToken = undefined;
    try { await context?.close(); } catch (_) { process.exitCode = 1; }
    try { await browser?.close(); } catch (_) { process.exitCode = 1; }
    report('browser_cleanup_complete', true);
  }
}

main().catch(() => {
  console.error(`PG replica restore browser acceptance failed at ${stage}: unexpected_failure`);
  process.exitCode = 1;
});
