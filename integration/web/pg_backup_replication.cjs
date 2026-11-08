/*
 * WEB-PG-BACKUP-REPLICATION-01: create a real encrypted PG backup, wait for
 * its loopback S3 copy through node B, and render the shared safe status in
 * the administrator's Web Settings. The browser receives only node URLs and
 * account bootstrap inputs; PG and S3 configuration remains outside it.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_BACKUP_REPLICATION_NODE_A_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_BACKUP_REPLICATION_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_BACKUP_REPLICATION_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_BACKUP_REPLICATION_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_BACKUP_REPLICATION_BOOTSTRAP_TOKEN;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const REPLICATION_PATH = '/api/v1/admin/backup-replication';
const PREFLIGHT_PATH = '/api/v1/admin/backup-replication/preflight';
const INVITATIONS_PATH = '/api/v1/admin/account-invitations';
const JOBS_PATH = '/api/v1/admin/jobs';
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let browser;
let context;
let memberContext;
let page;
let adminToken;
let stage = 'preflight';
let failureStage;
let pageErrors = 0;
let requestFailures = 0;
let relayRequests = 0;
const browserFailureKinds = [];
const replicationResponses = [];
const jobEvents = [];
const preflightRequests = { admin: [], member: [] };
const preflightResponses = { admin: [], member: [] };

function assertThat(condition, message) {
  if (!condition) {
    const error = new Error(message);
    error.safeAssertion = message;
    throw error;
  }
}

function report(name, value) {
  console.log(`assert: ${name}=${value}`);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
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
    await locator.pressSequentially(value, { delay: 35 });
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible Web field did not retain its input');
}

async function hasVisibleSemanticText(needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) return false;
      return [element.textContent || '', ...[...element.attributes].map((item) => item.value)]
        .some((value) => value.includes(expected));
    });
  }, needle);
}

async function visibleText() {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => `${element.textContent || ''}\n` +
        [...element.attributes].map((item) => item.value).join('\n')).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
}

function trackPage(targetPage, { profile = 'admin', captureAdminToken = true } = {}) {
  targetPage.on('request', (request) => {
    try {
      const url = new URL(request.url());
      if (url.pathname.startsWith('/api/v1/relay/')) relayRequests += 1;
      if (url.pathname === PREFLIGHT_PATH) {
        preflightRequests[profile].push({
          method: request.method(),
          body: request.postData(),
          hasQuery: url.search !== '',
        });
      }
    } catch (_) {
      // Ignore browser-internal requests.
    }
  });
  targetPage.on('response', (response) => {
    let pathname;
    try {
      pathname = new URL(response.url()).pathname;
    } catch (_) {
      return;
    }
    if (captureAdminToken && pathname === '/api/v1/auth/register') {
      response.json().then((body) => { adminToken = body?.access_token; }).catch(() => {});
    }
    if (pathname === PREFLIGHT_PATH) {
      const request = response.request();
      preflightResponses[profile].push({
        method: request.method(),
        status: response.status(),
        body: request.postData(),
        payload: response.json().catch(() => null),
      });
      return;
    }
    if (pathname !== REPLICATION_PATH && pathname !== JOBS_PATH) return;
    const event = {
      method: response.request().method(),
      status: response.status(),
      payload: response.json().catch(() => null),
    };
    (pathname === REPLICATION_PATH ? replicationResponses : jobEvents).push(event);
  });
  targetPage.on('pageerror', (error) => {
    pageErrors += 1;
    browserFailureKinds.push({ type: 'pageerror', name: error?.name === 'TypeError' ? 'TypeError' : 'Error' });
  });
  targetPage.on('requestfailed', (request) => {
    requestFailures += 1;
    let route = 'non_api_resource';
    try {
      route = new URL(request.url()).pathname
        .replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\/|$)/gi, '/:id')
        .replace(/\/[A-Za-z0-9_-]{40,}(?=\/|$)/g, '/:opaque');
      if (!route.startsWith('/api/')) route = 'non_api_resource';
    } catch (_) {
      route = 'non_api_resource';
    }
    const rawError = request.failure()?.errorText || '';
    const error = /^net::ERR_[A-Z_]+$/.test(rawError) ? rawError : 'other';
    browserFailureKinds.push({ type: 'requestfailed', method: request.method(), route, error });
  });
}

async function requestJson(baseUrl, method, pathname, token, body) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

function validateStatus(body) {
  assertThat(body && !Array.isArray(body) &&
    Object.keys(body).sort().join(',') === 'configured,latest_attempt,operation,pending_count' &&
    body.operation === 'backup_replication' && typeof body.configured === 'boolean' &&
    Number.isInteger(body.pending_count) && body.pending_count >= 0,
  'replication status DTO had an unexpected shape');
  if (body.latest_attempt !== null) {
    const attempt = body.latest_attempt;
    assertThat(attempt && !Array.isArray(attempt) &&
      Object.keys(attempt).sort().join(',') ===
        'archive_bytes,archive_id,attempted_at,completed_at,failure_category,state' &&
      UUID_PATTERN.test(attempt.archive_id) &&
      ['pending_archive', 'pending', 'running', 'retry_wait', 'succeeded', 'interrupted', 'failed']
        .includes(attempt.state) &&
      typeof attempt.attempted_at === 'string' && Number.isFinite(Date.parse(attempt.attempted_at)) &&
      (attempt.completed_at === null ||
        (typeof attempt.completed_at === 'string' && Number.isFinite(Date.parse(attempt.completed_at)))) &&
      (attempt.archive_bytes === null ||
        (Number.isSafeInteger(attempt.archive_bytes) && attempt.archive_bytes > 0)) &&
      (attempt.failure_category === null ||
        ['archive_unavailable', 'credentials_invalid', 'remote_unavailable',
          'remote_integrity_mismatch', 'replication_failed'].includes(attempt.failure_category)),
    'replication attempt DTO had an unexpected shape');
  }
  return body;
}

function validateBucketAccessCheck(body) {
  assertThat(body && !Array.isArray(body) &&
    Object.keys(body).sort().join(',') === 'check,result' &&
    body.check === 'bucket_access' && body.result === 'passed',
  'bucket access preflight returned an unexpected safe result DTO');
  return body;
}

function formattedBytes(value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  const number = unit === 0 ? String(value) : amount.toFixed(1);
  return `${number} ${units[unit]} (${new Intl.NumberFormat('en-US').format(value)} bytes)`;
}

async function waitForStatus(baseUrl, archiveId, timeoutMs = 150000) {
  const deadline = Date.now() + timeoutMs;
  let latest;
  while (Date.now() < deadline) {
    const result = await requestJson(baseUrl, 'GET', REPLICATION_PATH, adminToken);
    assertThat(result.status === 200, 'PostgreSQL replication status read failed');
    latest = validateStatus(result.body);
    if (latest.latest_attempt?.archive_id === archiveId &&
        latest.latest_attempt.state === 'succeeded' && latest.pending_count === 0) return latest;
    if (latest.latest_attempt?.archive_id === archiveId &&
        ['failed', 'interrupted'].includes(latest.latest_attempt.state)) {
      throw new Error('PostgreSQL backup replication ended in a safe failure state');
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('PostgreSQL backup replication did not complete before the deadline');
}

async function main() {
  assertThat(BASE_URL && NODE_B_URL && USERNAME && PASSWORD && BOOTSTRAP_TOKEN,
    'PostgreSQL backup replication browser inputs are incomplete');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
    'current Flutter Web release bundle is missing');
  const bundleSha256 = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');
  try {
    setStage('launch isolated Chromium context');
    const options = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(options);
    context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    page = await context.newPage();
    trackPage(page);

    setStage('register allowlisted PostgreSQL administrator through Web');
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    await page.evaluate(async () => { await window.sodium.ready; });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
    await fill('Server URL', BASE_URL);
    await click('Connect securely');
    await field('Owner email');
    await fill('Owner email', USERNAME);
    await fill('Master password · 12+ characters', PASSWORD);
    await fill('Confirm master password', PASSWORD);
    await fill('One-time bootstrap token', BOOTSTRAP_TOKEN);
    await fill('Device name', 'PostgreSQL backup replication acceptance');
    await fill('First Vault', 'PostgreSQL backup replication acceptance');
    await click('Create owner account');
    await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
    await waitFor(() => typeof adminToken === 'string' && adminToken.length >= 40);
    report('admin_profile_registered', true);

    setStage('verify PG admin capability exposes the replication Settings card');
    const capabilities = await requestJson(BASE_URL, 'GET', `${JOBS_PATH}?limit=10&offset=0`, adminToken);
    assertThat(capabilities.status === 200 &&
      Array.isArray(capabilities.body?.supported_actions) &&
      capabilities.body.supported_actions.includes('backup_replication'),
    'PostgreSQL admin capabilities did not expose the backup replication Settings card');
    report('replication_card_capability_advertised', true);

    setStage('click administrator Settings tab');
    await click('Settings');
    setStage('wait for administrator replication card');
    await waitFor(() => hasVisibleSemanticText('Off-site encrypted backup copies'));
    setStage('read empty replication snapshots from both PostgreSQL nodes');
    const [initialA, initialB] = await Promise.all([
      requestJson(BASE_URL, 'GET', REPLICATION_PATH, adminToken),
      requestJson(NODE_B_URL, 'GET', REPLICATION_PATH, adminToken),
    ]);
    report('initial_node_a_status', initialA.status);
    report('initial_node_b_status', initialB.status);
    assertThat(initialA.status === 200 && initialB.status === 200,
      'new administrator could not read replication status on both PG nodes');
    setStage('validate configured empty PG replication DTOs');
    const emptyA = validateStatus(initialA.body);
    const emptyB = validateStatus(initialB.body);
    assertThat(emptyA.configured && emptyB.configured &&
      emptyA.pending_count === 0 && emptyB.pending_count === 0 &&
      emptyA.latest_attempt === null && emptyB.latest_attempt === null &&
      JSON.stringify(emptyA) === JSON.stringify(emptyB),
    'both PostgreSQL nodes did not report the same configured empty replication snapshot');
    report('initial_status_shared_across_nodes', true);

    setStage('load empty replication status in Settings');
    const initialResponseIndex = replicationResponses.length;
    await click('Load replication status');
    await waitFor(() => replicationResponses.length > initialResponseIndex);
    const initialUiResponse = replicationResponses[initialResponseIndex];
    assertThat(initialUiResponse.method === 'GET' && initialUiResponse.status === 200 &&
      JSON.stringify(validateStatus(await initialUiResponse.payload)) === JSON.stringify(emptyA),
    'Settings did not load the safe empty PG replication DTO');
    report('settings_loaded_safe_empty_status', true);

    setStage('verify configured bucket access through the Settings preflight');
    const preflightRequestStart = preflightRequests.admin.length;
    const preflightResponseStart = preflightResponses.admin.length;
    await click('Check bucket access');
    await waitFor(() => preflightResponses.admin.length > preflightResponseStart);
    const preflightRequest = preflightRequests.admin[preflightRequestStart];
    const preflightResponse = preflightResponses.admin[preflightResponseStart];
    const preflightPayload = validateBucketAccessCheck(await preflightResponse.payload);
    assertThat(preflightRequestStart === 0 && preflightResponseStart === 0 &&
      preflightRequests.admin.length === preflightRequestStart + 1 &&
      preflightResponses.admin.length === preflightResponseStart + 1 &&
      preflightResponse.method === 'POST' && preflightRequest?.method === 'POST' &&
      preflightRequest.body === '{}' && preflightResponse.body === '{}' &&
      preflightRequest.hasQuery === false && preflightResponse.status === 200 &&
      preflightPayload.check === 'bucket_access' && preflightPayload.result === 'passed',
    'Settings did not send the fixed empty-body bucket access preflight');
    await waitFor(() => hasVisibleSemanticText('Bucket access verified with HeadBucket.'));
    await waitFor(() => hasVisibleSemanticText('HeadBucket only;'));
    await waitFor(() => hasVisibleSemanticText(
      'This check does not verify uploads, multipart operations, restore, or provider-wide interoperability.',
    ));
    report('settings_bucket_access_preflight_fixed_post_and_dto', true);
    report('settings_bucket_access_preflight_limits_visible', true);

    setStage('create encrypted PostgreSQL backup and observe replica on node B');
    const requestId = crypto.randomUUID();
    const accepted = await requestJson(BASE_URL, 'POST', JOBS_PATH, adminToken, {
      request_id: requestId,
      action: 'backup',
    });
    assertThat(accepted.status === 202 && accepted.body &&
      Object.keys(accepted.body).join(',') === 'job',
    'administrator backup job was not accepted by PostgreSQL');
    const job = accepted.body.job;
    assertThat(job && UUID_PATTERN.test(job.job_id) && job.job_id === job.archive_id &&
      job.request_id === requestId && job.action === 'backup' &&
      job.archive_source === null &&
      ['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
    'PostgreSQL backup job returned an unsafe or invalid DTO');
    report('backup_job_created', true);

    const jobDeadline = Date.now() + 90000;
    let terminal;
    while (Date.now() < jobDeadline) {
      const result = await requestJson(NODE_B_URL, 'GET', `${JOBS_PATH}?limit=20&offset=0`, adminToken);
      assertThat(result.status === 200 && Array.isArray(result.body?.jobs),
        'node B could not read shared PostgreSQL backup job progress');
      terminal = result.body.jobs.find((entry) => entry.job_id === job.job_id);
      if (terminal && ['succeeded', 'failed', 'interrupted'].includes(terminal.status)) break;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assertThat(terminal?.status === 'succeeded' && terminal.result_code === 'completed',
      'shared PostgreSQL backup job did not succeed');
    const sharedReplica = await waitForStatus(NODE_B_URL, job.job_id);
    assertThat(sharedReplica.configured && sharedReplica.latest_attempt?.state === 'succeeded' &&
      sharedReplica.latest_attempt.archive_bytes > 0 &&
      sharedReplica.latest_attempt.failure_category === null &&
      sharedReplica.latest_attempt.completed_at !== null,
    'node B did not read the successful shared S3 replication status');
    report('pg_node_b_shared_success', true);

    setStage('refresh Settings and verify only safe replica metadata is rendered');
    const refreshIndex = replicationResponses.length;
    await click('Refresh replication status');
    await waitFor(() => replicationResponses.length > refreshIndex);
    const refreshed = replicationResponses[refreshIndex];
    const uiStatus = validateStatus(await refreshed.payload);
    assertThat(refreshed.method === 'GET' && refreshed.status === 200 &&
      uiStatus.latest_attempt?.archive_id === job.job_id &&
      uiStatus.latest_attempt.state === 'succeeded' &&
      uiStatus.latest_attempt.archive_bytes === sharedReplica.latest_attempt.archive_bytes &&
      uiStatus.latest_attempt.failure_category === null,
    'Settings did not refresh the successful shared replica DTO');
    await waitFor(() => hasVisibleSemanticText('Remote copy verified'));
    await waitFor(() => hasVisibleSemanticText('Encrypted archive bytes'));
    await waitFor(() => hasVisibleSemanticText('Copies waiting'));
    const rendered = await visibleText();
    assertThat(rendered.includes('Configured') && rendered.includes('Remote copy verified') &&
      rendered.includes(formattedBytes(sharedReplica.latest_attempt.archive_bytes)) &&
      !rendered.includes(job.job_id) && !rendered.includes(PASSWORD) &&
      !rendered.includes(BOOTSTRAP_TOKEN) && !rendered.includes(adminToken),
    'Settings exposed private values or omitted verified archive metadata');
    report('safe_dto_and_ui', true);
    report('settings_rendered_verified_replica', true);
    report('browser_storage_contains_no_bootstrap_or_password', await page.evaluate((markers) => {
      const text = JSON.stringify({
        local: Object.fromEntries(Object.entries(localStorage)),
        session: Object.fromEntries(Object.entries(sessionStorage)),
      });
      return markers.every((marker) => !text.includes(marker));
    }, [PASSWORD, BOOTSTRAP_TOKEN]));
    assertThat(await page.evaluate((markers) => {
      const text = JSON.stringify({
        local: Object.fromEntries(Object.entries(localStorage)),
        session: Object.fromEntries(Object.entries(sessionStorage)),
      });
      return markers.every((marker) => !text.includes(marker));
    }, [PASSWORD, BOOTSTRAP_TOKEN]),
    'bootstrap token or master password was persisted in browser web storage');

    setStage('register a separately invited non-admin browser profile');
    const memberUsername = `pg-preflight-member-${crypto.randomUUID()}@example.test`;
    const memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    const invitationReceipt = await requestJson(
      BASE_URL,
      'POST',
      INVITATIONS_PATH,
      adminToken,
      { username: memberUsername },
    );
    const invitation = invitationReceipt.body?.invitation;
    assertThat(invitationReceipt.status === 201 && invitation &&
      Object.keys(invitation).sort().join(',') ===
        'created_at,expires_at,invitation_id,token,username' &&
      invitation.username === memberUsername &&
      /^[A-Za-z0-9_-]{43}$/.test(invitation.token),
    'could not create the isolated non-admin browser invitation');

    setStage('verify non-admin Settings hides bucket access check');
    memberContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    const memberPage = await memberContext.newPage();
    trackPage(memberPage, { profile: 'member', captureAdminToken: false });
    const adminPage = page;
    page = memberPage;
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    await page.evaluate(async () => { await window.sodium.ready; });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
    await fill('Server URL', BASE_URL);
    await click('Connect securely');
    await field('Email or username');
    await click('Have an instance invitation? Create account');
    await field('Email on the invitation');
    await fill('Email on the invitation', memberUsername);
    await fill('Master password · 12+ characters', memberPassword);
    await fill('Confirm master password', memberPassword);
    await fill('Instance invitation token', invitation.token);
    invitation.token = '';
    await fill('Device name', 'PostgreSQL bucket preflight member');
    await fill('First Vault', 'PostgreSQL bucket preflight member');
    await click('Create invited account');
    await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
    await click('Settings');
    await waitFor(() => hasVisibleSemanticText('Workspace settings'));
    assertThat(!await hasVisibleSemanticText('Check bucket access') &&
      !await hasVisibleSemanticText('Off-site encrypted backup copies'),
    'non-admin Settings rendered the backup bucket access control');
    assertThat(preflightRequests.member.length === 0 &&
      preflightResponses.member.length === 0,
    'non-admin browser issued a backup bucket access preflight request');
    report('non_admin_bucket_access_button_hidden_and_no_request', true);
    page = adminPage;

    report('page_errors', pageErrors);
    report('request_failures', requestFailures);
    report('relay_requests', relayRequests);
    if (pageErrors !== 0 || requestFailures !== 0 || relayRequests !== 0) {
      report('browser_failure_kinds', JSON.stringify(browserFailureKinds.slice(0, 12)));
    }
    assertThat(pageErrors === 0 && requestFailures === 0 && relayRequests === 0,
      'PostgreSQL backup replication browser journey had unexpected errors or Relay requests');
    report('web_release_sha256', bundleSha256);
    report('pg_backup_replication_web_pass', true);
  } catch (error) {
    failureStage = stage;
    throw error;
  } finally {
    setStage('close isolated Chromium context');
    adminToken = undefined;
    await memberContext?.close().catch(() => {});
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
    report('browser_cleanup_complete', true);
  }
}

main().catch((error) => {
  console.error(
    `PG backup replication browser acceptance failed at ${error?.safeAssertion || failureStage || stage}`,
  );
  process.exitCode = 1;
});
