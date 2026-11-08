/*
 * WEB-PG-ADMIN-RESTORE-V25-01: exercise the historical marker-25 encrypted
 * archive through the current Web Release and Settings UI against a live,
 * two-node PostgreSQL fixture. The Python owner seeds the source archive and
 * supplies its exact archive ID plus a one-time bootstrap token. This runner
 * verifies Web discard of the prepared copy and never activates or cuts over.
 *
 * Environment contract:
 *   ATERMIUS_PG_V25_RESTORE_NODE_A_URL, ATERMIUS_PG_V25_RESTORE_NODE_B_URL
 *   ATERMIUS_PG_V25_RESTORE_ARCHIVE_ID
 *   ATERMIUS_PG_V25_RESTORE_ADMIN_USERNAME, ATERMIUS_PG_V25_RESTORE_ADMIN_PASSWORD
 *   ATERMIUS_PG_V25_RESTORE_BOOTSTRAP_TOKEN
 *   ATERMIUS_PG_V25_RESTORE_DISCARD_GATE_DIR
 *   optional PLAYWRIGHT_CHROMIUM_EXECUTABLE
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const RESTORE_SOURCES_PATH = '/api/v1/admin/restore-sources';
const JOBS_PATH = '/api/v1/admin/jobs';
const RESTORE_STAGE_DISCARD_PREFIX = '/api/v1/admin/restore-stages/';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

let stage = 'preflight';
let browser;
let context;
let page;
let bootstrapToken;
let adminUsername;
let adminPassword;
let adminAccessToken;
let cleanupFailed = false;
let pageErrors = 0;
let externalRequests = 0;
let apiRequestFailures = 0;
const apiEvents = [];
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
  return parsed.origin;
}

function readConfig() {
  const nodeAUrl = process.env.ATERMIUS_PG_V25_RESTORE_NODE_A_URL;
  const nodeBUrl = process.env.ATERMIUS_PG_V25_RESTORE_NODE_B_URL;
  const archiveId = process.env.ATERMIUS_PG_V25_RESTORE_ARCHIVE_ID;
  const discardGateDir = process.env.ATERMIUS_PG_V25_RESTORE_DISCARD_GATE_DIR;
  adminUsername = process.env.ATERMIUS_PG_V25_RESTORE_ADMIN_USERNAME;
  adminPassword = process.env.ATERMIUS_PG_V25_RESTORE_ADMIN_PASSWORD;
  bootstrapToken = process.env.ATERMIUS_PG_V25_RESTORE_BOOTSTRAP_TOKEN;
  assertThat(typeof nodeAUrl === 'string' && typeof nodeBUrl === 'string',
    'PostgreSQL restore node URLs were not configured');
  assertThat(typeof archiveId === 'string' && UUID_RE.test(archiveId),
    'PostgreSQL historical archive ID was invalid');
  assertThat(typeof adminUsername === 'string' && adminUsername.length > 0 &&
      typeof adminPassword === 'string' && adminPassword.length >= 12 &&
      typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
    'PostgreSQL restore administrator credentials were unavailable');
  assertThat(typeof discardGateDir === 'string' && path.isAbsolute(discardGateDir),
    'PostgreSQL restore discard review gate was unavailable');
  leakSentinels.push(adminPassword, bootstrapToken);
  return {
    nodeAUrl: `${loopbackOrigin(nodeAUrl, 'Node A')}/`,
    nodeBUrl: `${loopbackOrigin(nodeBUrl, 'Node B')}/`,
    archiveId,
    discardGateDir,
  };
}

async function waitForReady(baseUrl, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // The Python fixture owns both already-started PostgreSQL servers.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('PostgreSQL restore server readiness timed out');
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web state did not appear');
}

async function field(label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  try {
    await selectServerModeIfChooser(page, locator);
    await locator.waitFor({ state: 'visible', timeout: 20000 });
  } catch (_) {
    throw new Error(`expected Web field ${label} to become visible`);
  }
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
  try {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await locator.click();
      await page.waitForTimeout(80);
      await locator.press('Control+A');
      await page.waitForTimeout(50);
      await locator.pressSequentially(value, { delay: 20 });
      await page.waitForTimeout(120);
      if (await locator.inputValue() !== value) continue;
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
    await locator.fill(value);
    await page.waitForTimeout(120);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  } catch (_) {
    throw new Error(`could not enter Web field ${label}`);
  }
  let observedLength = 0;
  try { observedLength = (await locator.inputValue()).length; } catch (_) { /* already disconnected */ }
  throw new Error(`Web field ${label} did not retain input (expected length=${value.length}; observed length=${observedLength})`);
}

async function configurePage(baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  await fill('Server URL', baseUrl);
  await click('Connect securely');
}

async function hasVisibleSemanticText(needle) {
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

async function scrollUntilVisibleSemanticText(needle, maxSteps = 32) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(900, 850);
    await page.mouse.wheel(0, 700);
    await page.waitForTimeout(80);
  }
  throw new Error('expected Settings card did not enter the visible area');
}

async function visiblePageText() {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => element.textContent || '')
      .join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  // The account name is an identifier and may be rendered by the signed-in
  // shell; only credentials and bearer material belong in the leak sentinel.
  for (const secret of leakSentinels) {
    if (secret && secret.length >= 8) {
      assertThat(!serialized.includes(secret), 'a response or rendered view exposed a credential');
    }
  }
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function trackBrowser(baseOrigin) {
  const pending = new WeakMap();
  page.on('pageerror', () => { pageErrors += 1; });
  page.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol) && url.origin !== baseOrigin) {
      externalRequests += 1;
    }
    if (url.pathname !== '/api/v1/auth/register' && url.pathname !== RESTORE_SOURCES_PATH &&
        url.pathname !== JOBS_PATH &&
        !url.pathname.startsWith(RESTORE_STAGE_DISCARD_PREFIX)) return;
    let body = null;
    if ((url.pathname === JOBS_PATH && request.method() === 'POST') ||
        (url.pathname.startsWith(RESTORE_STAGE_DISCARD_PREFIX) && request.method() === 'POST')) {
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
  page.on('requestfailed', (request) => {
    try {
      if (new URL(request.url()).pathname.startsWith('/api/')) apiRequestFailures += 1;
    } catch (_) {
      // Ignore browser-internal requests.
    }
  });
  page.on('response', (response) => {
    const metadata = pending.get(response.request());
    if (!metadata) return;
    apiEvents.push({
      ...metadata,
      status: response.status(),
      sequence: apiEvents.length,
      payloadPromise: response.json().catch(() => null),
    });
  });
}

async function waitForApi(predicate, startIndex, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = apiEvents.slice(startIndex).find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web API response did not arrive');
}

async function directApi(baseUrl, method, pathname, { token, body, skipLeakCheck = false } = {}) {
  const route = new URL(pathname.replace(/^\/+/, ''), baseUrl).toString();
  const response = await fetch(route, {
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
  if (!skipLeakCheck) assertNoLeaks(payload);
  return { status: response.status, payload };
}

async function createAdminProfile(baseUrl) {
  setStage('connect to Node A and register the bootstrap owner in Web');
  await configurePage(baseUrl);
  await field('Owner email');
  await fill('Owner email', adminUsername);
  await fill('Master password · 12+ characters', adminPassword);
  await fill('Confirm master password', adminPassword);
  await fill('One-time bootstrap token', bootstrapToken);
  await fill('Device name', 'PG v25 restore Settings acceptance');
  await fill('First Vault', 'PG v25 restore Settings acceptance');
  const start = apiEvents.length;
  await click('Create owner account');
  bootstrapToken = undefined;
  await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForApi((event) =>
    event.pathname === '/api/v1/auth/register' && event.method === 'POST', start);
  reportStatus('web_bootstrap_admin_registration', registration.status);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string' &&
      UUID_RE.test(payload?.account_id) && UUID_RE.test(payload?.device_id),
    'Web bootstrap administrator registration response was incomplete');
  assertNoLeaks(payload);
  adminAccessToken = payload.access_token;
  leakSentinels.push(adminAccessToken);
  reportBoolean('admin_profile_registered', true);
}

function validateRestoreSourcePage(payload, archiveId) {
  assertThat(exactKeys(payload, ['sources', 'total']) && Array.isArray(payload.sources) &&
      Number.isInteger(payload.total) && payload.total >= payload.sources.length,
    'restore source page shape was invalid');
  for (const source of payload.sources) {
    assertThat(exactKeys(source, ['archive_id', 'created_at', 'archive_bytes', 'origin', 'source']) &&
        UUID_RE.test(source.archive_id) && Number.isInteger(source.archive_bytes) &&
        source.archive_bytes > 0 && ['manual', 'scheduled'].includes(source.origin) &&
        ['local', 'replica'].includes(source.source) &&
        typeof source.created_at === 'string' && !Number.isNaN(Date.parse(source.created_at)),
    'restore source metadata was invalid');
  }
  assertNoLeaks(payload);
  const target = payload.sources.find((source) => source.archive_id === archiveId);
  assertThat(target && target.source === 'local',
    'Settings source page did not contain the expected local historical archive');
  return { target, localSources: payload.sources.filter((source) => source.source === 'local') };
}

function validateJob(job, expected) {
  assertThat(exactKeys(job, [
    'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status', 'requested_at',
    'started_at', 'finished_at', 'result_code', 'restore_stage_status',
  ]), 'restore job metadata fields changed');
  assertThat(UUID_RE.test(job.job_id) && job.job_id === expected.jobId &&
      UUID_RE.test(job.request_id) && job.request_id === expected.requestId &&
      job.action === 'restore' && job.archive_id === expected.archiveId &&
      job.archive_source === 'local',
    'shared restore job did not preserve the submitted request and source');
  assertThat(['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
    'shared restore job status was invalid');
  const timestamp = (value) => typeof value === 'string' && !Number.isNaN(Date.parse(value));
  assertThat(timestamp(job.requested_at) &&
      (job.started_at === null || timestamp(job.started_at)) &&
      (job.finished_at === null || timestamp(job.finished_at)),
    'shared restore job timestamps were invalid');
  if (job.status === 'succeeded') {
    assertThat(job.started_at !== null && job.finished_at !== null &&
        job.result_code === 'completed' &&
        ['ready', 'discarding', 'discarded'].includes(job.restore_stage_status),
      'successful restore job did not preserve a valid isolated stage lifecycle');
  }
  assertNoLeaks(job);
  return job;
}

async function waitForSharedPreparedJob(baseUrl, expected, timeoutMs = 70000) {
  const deadline = Date.now() + timeoutMs;
  const seen = new Set();
  while (Date.now() < deadline) {
    const result = await directApi(baseUrl, 'GET', `${JOBS_PATH}?limit=100&offset=0`, {
      token: adminAccessToken,
    });
    const pageShape = exactKeys(result.payload, ['jobs', 'total']) ||
      exactKeys(result.payload, ['jobs', 'supported_actions', 'total']);
    if (!(result.status === 200 && pageShape &&
        Array.isArray(result.payload.jobs) && Number.isInteger(result.payload.total) &&
        result.payload.total >= result.payload.jobs.length &&
        (result.payload.supported_actions === undefined ||
          (Array.isArray(result.payload.supported_actions) &&
            result.payload.supported_actions.every((action) => typeof action === 'string'))))) {
      const keys = result.payload && typeof result.payload === 'object' && !Array.isArray(result.payload)
        ? Object.keys(result.payload).sort().join(',') : typeof result.payload;
      throw new Error(`Node B admin job poll was invalid (status=${result.status}; keys=${keys})`);
    }
    const rawJob = result.payload.jobs.find((item) => item.job_id === expected.jobId);
    if (rawJob) {
      const job = validateJob(rawJob, expected);
      seen.add(job.status);
      if (job.status === 'succeeded') {
        assertThat(job.restore_stage_status === 'ready',
          'Node B did not observe the prepared stage before discard');
        return { job, seen: [...seen] };
      }
      if (['failed', 'interrupted'].includes(job.status)) {
        console.log(`assert: terminal_restore_status=${job.status} result_code=${job.result_code ?? 'null'} restore_stage_status=${job.restore_stage_status ?? 'null'}`);
        assertThat(false, 'Node B observed a terminal restore failure');
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error('Node B did not observe the shared prepared restore job');
}

async function waitForSharedDiscardedJob(baseUrl, expected, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await directApi(baseUrl, 'GET', `${JOBS_PATH}?limit=100&offset=0`, {
      token: adminAccessToken,
    });
    const validPage = result.status === 200 &&
      (exactKeys(result.payload, ['jobs', 'total']) ||
        exactKeys(result.payload, ['jobs', 'supported_actions', 'total'])) &&
      Array.isArray(result.payload.jobs);
    assertThat(validPage, 'Node B could not read the shared restore job after discard');
    const rawJob = result.payload.jobs.find((item) => item.job_id === expected.jobId);
    if (rawJob) {
      const job = validateJob(rawJob, expected);
      if (job.restore_stage_status === 'discarded') return job;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Node B did not observe the discarded restore stage');
}

async function waitForPythonDiscardReview(gateDir) {
  const readyPath = path.join(gateDir, 'stage-ready');
  const continuePath = path.join(gateDir, 'continue-discard');
  assertThat(fs.statSync(gateDir).isDirectory(), 'Python restore review gate directory was invalid');
  fs.writeFileSync(readyPath, 'ready\n', { flag: 'wx', mode: 0o600 });
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    if (fs.existsSync(continuePath)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Python did not finish validating the prepared restore stage');
}

async function cleanup() {
  bootstrapToken = undefined;
  adminUsername = undefined;
  adminPassword = undefined;
  adminAccessToken = undefined;
  leakSentinels.length = 0;
  if (context) {
    try { await context.close(); } catch (_) { cleanupFailed = true; }
  }
  if (browser) {
    try { await browser.close(); } catch (_) { cleanupFailed = true; }
  }
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function main() {
  const config = readConfig();
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
      'compiled current Web Release bundle is incomplete');
  }
  const bundleHash = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');

  try {
    setStage('wait for both PostgreSQL nodes');
    await Promise.all([waitForReady(config.nodeAUrl), waitForReady(config.nodeBUrl)]);

    setStage('verify unauthenticated restore access is denied for the fixture archive');
    const unauthenticatedSources = await directApi(
      config.nodeAUrl, 'GET', `${RESTORE_SOURCES_PATH}?limit=100&offset=0`);
    reportStatus('unauthenticated_restore_source_list', unauthenticatedSources.status);
    assertThat(unauthenticatedSources.status === 401,
      'unauthenticated restore-source listing was not denied');
    const deniedRequestId = crypto.randomUUID();
    const deniedSubmission = await directApi(config.nodeBUrl, 'POST', JOBS_PATH, {
      body: {
        request_id: deniedRequestId,
        action: 'restore',
        archive_id: config.archiveId,
        archive_source: 'local',
      },
    });
    reportStatus('unauthenticated_restore_submission', deniedSubmission.status);
    assertThat(deniedSubmission.status === 401,
      'unauthenticated restore submission was not denied');
    reportBoolean('unauthorized_restore_routes_denied', true);

    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    page = await context.newPage();
    trackBrowser(new URL(config.nodeAUrl).origin);

    await createAdminProfile(config.nodeAUrl);
    setStage('check PostgreSQL instance-admin restore capability');
    const capabilities = await directApi(
      config.nodeAUrl,
      'GET',
      '/api/v1/admin/jobs?limit=20&offset=0',
      { token: adminAccessToken },
    );
    reportStatus('admin_job_capabilities', capabilities.status);
    const supportedActions = capabilities.payload?.supported_actions;
    assertThat(capabilities.status === 200 && Array.isArray(supportedActions),
      'administrator job capability response was unavailable');
    console.log(`assert: supported_admin_actions=${supportedActions.join(',')}`);
    assertThat(supportedActions.includes('restore'),
      'PostgreSQL did not advertise restore for the isolated target');
    assertThat(supportedActions.includes('restore_stage_discard'),
      'PostgreSQL did not advertise isolated restore-stage discard');
    const adminProfile = await directApi(config.nodeAUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
      skipLeakCheck: true,
    });
    reportStatus('admin_profile_read', adminProfile.status);
    const adminProfileJson = JSON.stringify(adminProfile.payload);
    const echoedCredentialKinds = [
      ['admin_password', leakSentinels[0]],
      ['bootstrap_token', leakSentinels[1]],
      ['access_token', adminAccessToken],
    ].filter(([, secret]) => secret && adminProfileJson.includes(secret))
      .map(([kind]) => kind);
    console.log(`assert: admin_profile_echoed_credentials=${echoedCredentialKinds.join(',')}`);
    assertThat(echoedCredentialKinds.length === 0,
      'the Web account profile response echoed a credential');
    const serverClaimsAdmin = adminProfile.payload?.policy?.instance_admin === true;
    reportBoolean('server_profile_claims_instance_admin', serverClaimsAdmin);
    assertThat(adminProfile.status === 200 && serverClaimsAdmin,
      'the Web account profile did not grant the allowlisted administrator policy');
    setStage('open Settings and load the exact historical archive source');
    await click('Settings');
    await waitFor(() => hasVisibleSemanticText('Workspace settings'));
    reportBoolean('settings_page_opened', true);
    try {
      await scrollUntilVisibleSemanticText('Prepare isolated restore copy');
    } catch (error) {
      const rendered = await visiblePageText();
      for (const marker of [
        'Scheduled encrypted backups', 'Instance restore', 'Instance admin audit',
        'Instance overview', 'Maintenance jobs', 'No supported encrypted archives',
      ]) {
        reportBoolean(`settings_marker_${marker.replace(/[^a-z]+/gi, '_').toLowerCase()}`,
          rendered.includes(marker));
      }
      const jobsEvents = apiEvents.filter((event) =>
        event.pathname === JOBS_PATH && event.method === 'GET');
      console.log(`assert: settings_admin_jobs_responses=${jobsEvents.map((event) => event.status).join(',')}`);
      throw error;
    }
    await waitFor(() => hasVisibleSemanticText('Load restore sources'));
    const sourceStart = apiEvents.length;
    await click('Load restore sources');
    const sourceEvent = await waitForApi((event) =>
      event.pathname === RESTORE_SOURCES_PATH && event.method === 'GET' &&
      event.sequence >= sourceStart);
    reportStatus('settings_restore_source_list', sourceEvent.status);
    assertThat(sourceEvent.status === 200 && sourceEvent.hasBearer &&
        sourceEvent.query.limit && sourceEvent.query.offset,
      'Settings restore source list was not an authenticated page');
    const sourcePage = await sourceEvent.payloadPromise;
    const { target, localSources } = validateRestoreSourcePage(sourcePage, config.archiveId);
    const targetIndex = localSources.findIndex((source) => source.archive_id === target.archive_id);
    const localRadios = page.getByRole('radio', { name: /Local archive/ });
    await waitFor(async () => await localRadios.count() === localSources.length, 15000);
    assertThat(targetIndex >= 0 && await localRadios.count() === localSources.length,
      'Settings did not render the local archive source rows');
    const sourceRadio = localRadios.nth(targetIndex);
    await sourceRadio.waitFor({ state: 'visible', timeout: 15000 });
    const radioLabel = typeof sourceRadio.ariaSnapshot === 'function'
      ? await sourceRadio.ariaSnapshot() : await sourceRadio.innerText();
    assertThat(!radioLabel.includes(config.archiveId),
      'Settings exposed the internal archive ID in its source label');
    reportBoolean('settings_restore_archive_id_hidden_from_source_label', true);
    await sourceRadio.click();
    reportBoolean('pg_v25_restore_source_loaded', true);

    setStage('confirm one isolated restore through Settings');
    await click('Prepare isolated copy');
    await waitFor(() => hasVisibleSemanticText('Prepare isolated restore copy?'));
    const dialogText = await visiblePageText();
    assertThat(dialogText.includes('does not activate or replace live data'),
      'restore confirmation did not describe the isolated staging boundary');
    const confirms = page.getByRole('button', { name: 'Prepare isolated copy', exact: true });
    assertThat(await confirms.count() === 1,
      'restore confirmation action was not uniquely available');
    const postStart = apiEvents.length;
    await confirms.last().click();
    const post = await waitForApi((event) =>
      event.pathname === JOBS_PATH && event.method === 'POST' && event.sequence >= postStart);
    reportStatus('settings_restore_submission', post.status);
    assertThat(post.status === 202 && post.hasBearer &&
        exactKeys(post.body, ['request_id', 'action', 'archive_id', 'archive_source']) &&
        UUID_RE.test(post.body.request_id) && post.body.action === 'restore' &&
        post.body.archive_id === config.archiveId && post.body.archive_source === 'local',
      'Settings did not submit the strict authenticated request for the fixture archive');
    const receipt = await post.payloadPromise;
    assertThat(exactKeys(receipt, ['job']) &&
        receipt.job?.archive_id === config.archiveId &&
        receipt.job?.archive_source === 'local' &&
        receipt.job?.request_id === post.body.request_id,
      'restore acceptance receipt did not match the Settings request');
    const accepted = validateJob(receipt.job, {
      jobId: receipt.job.job_id,
      requestId: post.body.request_id,
      archiveId: config.archiveId,
    });
    assertThat(apiEvents.filter((event) =>
      event.pathname === JOBS_PATH && event.method === 'POST').length === 1,
    'Settings submitted more than one restore job');
    reportBoolean('pg_v25_restore_submitted_once', true);
    console.log(`assert: pg_v25_restore_job_id=${accepted.job_id}`);

    setStage('poll the shared restore job from Node B');
    const shared = await waitForSharedPreparedJob(config.nodeBUrl, {
      jobId: accepted.job_id,
      requestId: accepted.request_id,
      archiveId: config.archiveId,
    });
    reportBoolean('restore_job_shared_from_node_b', true);
    console.log(`assert: node_b_restore_statuses=${shared.seen.join(',')}`);

    setStage('verify Prepared status and Stage ID in Settings');
    try {
      await scrollUntilVisibleSemanticText('Restore staging · Prepared', 48);
      await scrollUntilVisibleSemanticText('Stage ID', 48);
      await scrollUntilVisibleSemanticText(accepted.job_id, 48);
    } catch (_) {
      const renderedBeforeFailure = await visiblePageText();
      const settingsJobEvents = apiEvents.filter((event) =>
        event.pathname === JOBS_PATH && event.method === 'GET');
      const pageJobs = await Promise.all(settingsJobEvents.map(async (event) => {
        const payload = await event.payloadPromise;
        return Array.isArray(payload?.jobs)
          ? payload.jobs.find((job) => job.job_id === accepted.job_id) ?? null
          : null;
      }));
      const observedJobs = pageJobs.filter(Boolean);
      const visibleRestoreStatuses = [...renderedBeforeFailure.matchAll(/Restore staging[^\n]*/g)]
        .map((match) => match[0]).slice(0, 5);
      const latestJobsPayload = settingsJobEvents.length
        ? await settingsJobEvents.at(-1).payloadPromise : null;
      console.log(`assert: settings_admin_jobs_responses=${settingsJobEvents.map((event) => event.status).join(',')}`);
      console.log(`assert: settings_restore_job_statuses=${observedJobs.map((job) => job.status).join(',')}`);
      console.log(`assert: settings_restore_stage_statuses=${observedJobs.map((job) => job.restore_stage_status ?? 'null').join(',')}`);
      console.log(`assert: settings_restore_visible_statuses=${visibleRestoreStatuses.join(' || ') || 'none'}`);
      console.log(`assert: settings_latest_supported_actions=${latestJobsPayload?.supported_actions?.join(',') ?? 'none'}`);
      reportBoolean('settings_restore_stage_id_visible', renderedBeforeFailure.includes(accepted.job_id));
      reportBoolean('settings_restore_card_heading_visible', renderedBeforeFailure.includes('Prepare isolated restore copy'));
      reportBoolean('settings_restore_status_refresh_visible', renderedBeforeFailure.includes('Refresh restore status'));
      reportBoolean('settings_restore_stage_id_label_visible', renderedBeforeFailure.includes('Stage ID'));
      reportBoolean('settings_restore_polling_error_visible', renderedBeforeFailure.includes('Unable to refresh restore stage status'));
      reportBoolean('settings_admin_jobs_error_visible', renderedBeforeFailure.includes('Unable to refresh instance jobs'));
      reportBoolean('settings_restore_status_queued_visible', renderedBeforeFailure.includes('Restore staging · Queued'));
      reportBoolean('settings_restore_status_running_visible', renderedBeforeFailure.includes('Restore staging · Preparing isolated copy'));
      throw new Error('Settings did not render Prepared status after the shared restore completed');
    }
    const stageIdLabelVisible = await hasVisibleSemanticText('Stage ID');
    const stageIdValueVisible = await hasVisibleSemanticText(accepted.job_id);
    reportBoolean('settings_restore_stage_id_semantically_rendered',
      stageIdLabelVisible && stageIdValueVisible);
    assertThat(stageIdLabelVisible && stageIdValueVisible,
      'Settings did not render the prepared Stage ID');
    reportBoolean('settings_restore_prepared_stage_id_rendered', true);
    const sourceProfile = await directApi(config.nodeAUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(sourceProfile.status === 200,
      'the online source instance did not remain usable after isolated restore staging');
    reportBoolean('source_instance_remains_usable', true);
    assertThat(pageErrors === 0, 'Web Settings reported an uncaught page error');
    assertThat(apiRequestFailures === 0, 'Web Settings had a failed API request');
    assertThat(externalRequests === 0, 'Web Settings made an external network request');

    setStage('wait for Python to verify the prepared target and stage contents');
    await waitForPythonDiscardReview(config.discardGateDir);

    setStage('verify strict discard route handling without touching the prepared stage');
    const nonexistentRestoreJobId = crypto.randomUUID();
    const extraTargetField = await directApi(config.nodeAUrl, 'POST',
      `${RESTORE_STAGE_DISCARD_PREFIX}${nonexistentRestoreJobId}/discard`, {
        token: adminAccessToken,
        body: { request_id: crypto.randomUUID(), target_database: 'untrusted-target' },
      });
    const nonexistentJob = await directApi(config.nodeBUrl, 'POST',
      `${RESTORE_STAGE_DISCARD_PREFIX}${nonexistentRestoreJobId}/discard`, {
        token: adminAccessToken,
        body: { request_id: crypto.randomUUID() },
      });
    assertThat(extraTargetField.status === 400 && nonexistentJob.status === 404,
      'discard route must reject caller-supplied target data and unknown stage IDs');
    reportBoolean('restore_stage_discard_rejects_untrusted_target_and_missing_job', true);

    setStage('discard the isolated PostgreSQL restore stage through Settings');
    await scrollUntilVisibleSemanticText('Instance jobs', 48);
    const discardButton = page.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    });
    assertThat(await discardButton.count() === 1,
      'the prepared PostgreSQL restore did not render one discard control');
    const discardStart = apiEvents.length;
    await discardButton.click();
    await waitFor(() => hasVisibleSemanticText('Discard isolated restore copy?'));
    const confirmDiscard = page.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    }).last();
    await confirmDiscard.click();
    const discardEvent = await waitForApi((event) =>
      event.pathname === `${RESTORE_STAGE_DISCARD_PREFIX}${accepted.job_id}/discard` &&
      event.method === 'POST' && event.sequence >= discardStart);
    reportStatus('settings_restore_stage_discard', discardEvent.status);
    const discardPayload = await discardEvent.payloadPromise;
    if (discardEvent.status !== 200) {
      console.log(`assert: discard_error_code=${discardPayload?.error?.code ?? 'unknown'}`);
      const discardMessage = discardPayload?.error?.message;
      if (typeof discardMessage === 'string') {
        console.log(`assert: discard_error_message=${JSON.stringify(discardMessage.slice(0, 180))}`);
      }
    }
    assertThat(discardEvent.status === 200 && discardEvent.hasBearer &&
        exactKeys(discardEvent.body, ['request_id']) && UUID_RE.test(discardEvent.body.request_id),
      'Settings did not submit the strict authenticated stage-discard request');
    const discardReceipt = discardPayload;
    assertThat(exactKeys(discardReceipt, ['restore_stage']) &&
        exactKeys(discardReceipt.restore_stage,
          ['restore_job_id', 'status', 'discarded_at']) &&
        discardReceipt.restore_stage.restore_job_id === accepted.job_id &&
        discardReceipt.restore_stage.status === 'discarded' &&
        typeof discardReceipt.restore_stage.discarded_at === 'string' &&
        !Number.isNaN(Date.parse(discardReceipt.restore_stage.discarded_at)),
      'Settings discard response did not match the fixed safe receipt contract');
    assertNoLeaks(discardReceipt);
    const discardedAt = discardReceipt.restore_stage.discarded_at;
    await waitFor(() => hasVisibleSemanticText('Restore staging · Discarded'));
    await waitFor(() => hasVisibleSemanticText('Isolated copy: discarded'));
    assertThat(await page.getByRole('button', {
      name: 'Discard isolated copy', exact: true,
    }).count() === 0,
    'discarded restore job still rendered an actionable discard control');
    reportBoolean('settings_restore_stage_discarded', true);

    setStage('verify discarded status on Node B and retry idempotency');
    const discarded = await waitForSharedDiscardedJob(config.nodeBUrl, {
      jobId: accepted.job_id,
      requestId: accepted.request_id,
      archiveId: config.archiveId,
    });
    assertThat(discarded.restore_stage_status === 'discarded',
      'Node B did not expose the durable discarded status to the original requester');
    reportBoolean('restore_stage_discard_shared_from_node_b', true);
    for (const [baseUrl, requestId] of [
      [config.nodeAUrl, discardEvent.body.request_id],
      [config.nodeBUrl, crypto.randomUUID()],
    ]) {
      const replay = await directApi(baseUrl, 'POST',
        `${RESTORE_STAGE_DISCARD_PREFIX}${accepted.job_id}/discard`, {
          token: adminAccessToken,
          body: { request_id: requestId },
        });
      assertThat(replay.status === 200 && exactKeys(replay.payload, ['restore_stage']) &&
          exactKeys(replay.payload.restore_stage,
            ['restore_job_id', 'status', 'discarded_at']) &&
          replay.payload.restore_stage.restore_job_id === accepted.job_id &&
          replay.payload.restore_stage.status === 'discarded' &&
          replay.payload.restore_stage.discarded_at === discardedAt,
        'same-node or cross-node retry did not return the same durable discard receipt');
    }
    reportBoolean('restore_stage_discard_idempotent_across_nodes', true);
    const liveAfterDiscard = await directApi(config.nodeAUrl, 'GET', '/api/v1/me', {
      token: adminAccessToken,
    });
    assertThat(liveAfterDiscard.status === 200,
      'the online source instance did not remain usable after stage discard');
    reportBoolean('source_instance_remains_usable_after_stage_discard', true);
    assertThat(pageErrors === 0, 'Web Settings reported an uncaught page error during discard');
    assertThat(apiRequestFailures === 0, 'Web Settings had a failed API request during discard');
    assertThat(externalRequests === 0, 'Web Settings made an external network request during discard');
  } finally {
    await cleanup();
  }

  assertThat(!cleanupFailed, 'browser resources did not all close cleanly');
  reportBoolean('browser_cleanup_complete', true);
  setStage('complete');
  console.log(`assert: page_errors=${pageErrors}`);
  console.log(`assert: request_failures=${apiRequestFailures}`);
  console.log(`assert: external_requests=${externalRequests}`);
  console.log('assert: web_release_bundle_path=apps/client/build/web/main.dart.js');
  console.log(`assert: web_release_sha256=${bundleHash}`);
  reportBoolean('pg_v25_restore_web_pass', true);
  console.log('WEB-PG-ADMIN-RESTORE-V25-01 passed');
}

main().catch(async (error) => {
  const code = typeof error?.safeAssertion === 'string'
    ? error.safeAssertion : 'pg_v25_restore_web_failed';
  let detail = String(error?.message || 'unknown').slice(0, 1200);
  for (const secret of leakSentinels) {
    if (secret) detail = detail.split(secret).join('[REDACTED]');
  }
  detail = detail.replaceAll(ROOT, '[ROOT]')
    .replace(/https?:\/\/127\.0\.0\.1:\d+/g, '[LOOPBACK]');
  console.error(`failure: stage=${stage} code=${code} detail=${detail}`);
  await cleanup();
  process.exitCode = 1;
});
