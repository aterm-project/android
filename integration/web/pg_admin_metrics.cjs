/*
 * WEB-PG-ADMIN-METRICS-01: exercise one-time scrape credential management in
 * Flutter Settings against the disposable two-node PostgreSQL HTTP fixture.
 * Output contains stages, statuses, and booleans only; credential values are
 * kept in memory long enough to verify copy and cross-node scrape behavior.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_ADMIN_METRICS_BASE_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_ADMIN_METRICS_NODE_B_URL;
const USERNAME = process.env.ATERMIUS_PG_ADMIN_METRICS_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_ADMIN_METRICS_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_ADMIN_METRICS_BOOTSTRAP_TOKEN;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const CREDENTIAL_PATH = '/api/v1/admin/metrics-credential';
const METRICS_PATH = '/api/v1/admin/metrics';

let browser;
let context;
let page;
let stage = 'preflight';
let failureStage;
let pageErrors = 0;
let requestFailures = 0;
let relayRequests = 0;
let adminToken;
let copiedCredential;
const credentialResponses = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function report(name, value) {
  console.log(`assert: ${name}=${value}`);
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
      const values = [element.textContent || '', ...[...element.attributes].map((item) => item.value)];
      return values.some((value) => value.includes(expected));
    });
  }, needle);
}

function trackResponses(targetPage) {
  targetPage.on('request', (request) => {
    try {
      if (new URL(request.url()).pathname.startsWith('/api/v1/relay/')) relayRequests += 1;
    } catch (_) {
      // Ignore non-URL requests.
    }
  });
  targetPage.on('response', (response) => {
    let url;
    try {
      url = new URL(response.url());
    } catch (_) {
      return;
    }
    if (url.pathname === '/api/v1/auth/register') {
      response.json().then((body) => { adminToken = body?.access_token; }).catch(() => {});
    }
    if (url.pathname !== CREDENTIAL_PATH) return;
    const event = {
      method: response.request().method(),
      status: response.status(),
      payload: response.json().catch(() => null),
    };
    credentialResponses.push(event);
  });
  targetPage.on('pageerror', () => { pageErrors += 1; });
  targetPage.on('requestfailed', () => { requestFailures += 1; });
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

async function scrape(baseUrl, credential) {
  const response = await fetch(`${baseUrl}${METRICS_PATH}`, {
    headers: { authorization: `Bearer ${credential}`, accept: 'text/plain' },
    signal: AbortSignal.timeout(15000),
  });
  const exposition = await response.text();
  return {
    status: response.status,
    contentTypeValid: (response.headers.get('content-type') || '').includes('version=0.0.4') &&
      (response.headers.get('content-type') || '').startsWith('text/plain;'),
    noStore: response.headers.get('cache-control') === 'no-store',
    nosniff: response.headers.get('x-content-type-options') === 'nosniff',
    sampleCount: exposition.split('\n').filter((line) => line && !line.startsWith('#')).length,
  };
}

async function configureServer() {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
  await fill('Server URL', BASE_URL);
  await click('Connect securely');
}

async function registerAllowlistedAdmin() {
  setStage('connect Web client to PostgreSQL server');
  await configureServer();
  await field('Owner email');
  await fill('Owner email', USERNAME);
  await fill('Master password · 12+ characters', PASSWORD);
  await fill('Confirm master password', PASSWORD);
  await fill('One-time bootstrap token', BOOTSTRAP_TOKEN);
  await fill('Device name', 'PostgreSQL metrics acceptance');
  await fill('First Vault', 'PostgreSQL metrics acceptance');
  setStage('register allowlisted administrator in Web');
  await click('Create owner account');
  await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
  await waitFor(() => typeof adminToken === 'string' && adminToken.length >= 40);
  report('admin_registered_in_browser', true);
}

async function waitForCredentialResponse(method, fromIndex) {
  await waitFor(() => credentialResponses.some((event, index) =>
    index >= fromIndex && event.method === method));
  return credentialResponses.find((event, index) => index >= fromIndex && event.method === method);
}

async function rotateAndCopy(buttonLabel) {
  const fromIndex = credentialResponses.length;
  await click(buttonLabel);
  const confirm = page.getByRole('button', { name: 'Rotate credential', exact: true }).last();
  await confirm.waitFor({ state: 'visible', timeout: 10000 });
  await confirm.click();
  const response = await waitForCredentialResponse('POST', fromIndex);
  const payload = await response.payload;
  assertThat(response.status === 200 && payload &&
    Object.keys(payload).sort().join(',') === 'created_at,credential' &&
    typeof payload.created_at === 'string' && Number.isFinite(Date.parse(payload.created_at)) &&
    typeof payload.credential === 'string' && /^atm_[A-Za-z0-9_-]{43}$/.test(payload.credential),
  'Settings did not create a valid one-time PostgreSQL scrape credential');
  report('credential_rotation_response_valid', true);

  await waitFor(() => hasVisibleSemanticText('Save this credential now'), 10000);
  await click('Copy credential');
  await waitFor(() => hasVisibleSemanticText('Copied'), 10000);
  copiedCredential = await page.evaluate(async () => navigator.clipboard.readText());
  const validCopy = /^atm_[A-Za-z0-9_-]{43}$/.test(copiedCredential) &&
    copiedCredential === payload.credential;
  await page.evaluate(async () => navigator.clipboard.writeText(''));
  const clipboardCleared = await page.evaluate(async () =>
    (await navigator.clipboard.readText()) === '');
  assertThat(validCopy && clipboardCleared,
    'Settings copy must match the one-time response and clear the browser clipboard');
  report('credential_copied_and_clipboard_cleared', true);
  const credential = copiedCredential;
  await click("I've saved it");
  await waitFor(async () => !(await hasVisibleSemanticText(credential)), 5000);
  assertThat(!(await hasVisibleSemanticText(credential)),
    'dismissed one-time credential remained visible in the Settings page');
  report('credential_dismissed', true);
  copiedCredential = undefined;
  return credential;
}

async function main() {
  assertThat(BASE_URL && NODE_B_URL && USERNAME && PASSWORD && BOOTSTRAP_TOKEN,
    'PG metrics browser fixture environment is incomplete');
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
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL });
    page = await context.newPage();
    trackResponses(page);

    await registerAllowlistedAdmin();
    setStage('open Prometheus credential card in Settings');
    await click('Settings');
    await waitFor(() => hasVisibleSemanticText('Prometheus scrape credential'));
    assertThat(await hasVisibleSemanticText('Prometheus scrape credential'),
      'allowlisted admin Settings did not render the PostgreSQL scrape credential card');

    const inactiveA = await requestJson(BASE_URL, 'GET', CREDENTIAL_PATH, adminToken);
    const inactiveB = await requestJson(NODE_B_URL, 'GET', CREDENTIAL_PATH, adminToken);
    assertThat(inactiveA.status === 200 && inactiveB.status === 200 &&
      inactiveA.body?.active === false && inactiveA.body?.updated_at === null &&
      JSON.stringify(inactiveA.body) === JSON.stringify(inactiveB.body),
    'new PG instance must report matching inactive credential status on both nodes');

    setStage('create and copy first scrape credential from Settings');
    const first = await rotateAndCopy('Create credential');
    report('credential_created', true);
    const firstStatus = await requestJson(NODE_B_URL, 'GET', CREDENTIAL_PATH, adminToken);
    const firstScrape = await scrape(NODE_B_URL, first);
    assertThat(firstStatus.status === 200 && firstStatus.body?.active === true &&
      firstScrape.status === 200 && firstScrape.contentTypeValid && firstScrape.noStore &&
      firstScrape.nosniff && firstScrape.sampleCount === 14,
    'Web-created credential was not shared with node B or did not scrape the fixed metrics contract');
    report('pg_node_b_scrape', true);

    setStage('rotate credential from Settings and dismiss one-time value');
    const second = await rotateAndCopy('Rotate credential');
    report('credential_rotated', true);
    const oldA = await scrape(BASE_URL, first);
    const oldB = await scrape(NODE_B_URL, first);
    const newA = await scrape(BASE_URL, second);
    const newB = await scrape(NODE_B_URL, second);
    assertThat(oldA.status === 401 && oldB.status === 401 &&
      newA.status === 200 && newB.status === 200,
    'Web rotation must invalidate the old credential and activate the new value on both PG nodes');
    report('old_credential_invalidated_on_both_nodes', true);

    setStage('revoke credential from Settings');
    await click('Revoke credential');
    const confirmRevoke = page.getByRole('button', { name: 'Revoke credential', exact: true }).last();
    await confirmRevoke.waitFor({ state: 'visible', timeout: 10000 });
    const fromIndex = credentialResponses.length;
    await confirmRevoke.click();
    const revokedEvent = await waitForCredentialResponse('DELETE', fromIndex);
    const revokedBody = await revokedEvent.payload;
    const revokedStatusA = await requestJson(BASE_URL, 'GET', CREDENTIAL_PATH, adminToken);
    const revokedStatusB = await requestJson(NODE_B_URL, 'GET', CREDENTIAL_PATH, adminToken);
    const revokedA = await scrape(BASE_URL, second);
    const revokedB = await scrape(NODE_B_URL, second);
    assertThat(revokedEvent.status === 200 && revokedBody?.revoked === true &&
      revokedStatusA.status === 200 && revokedStatusB.status === 200 &&
      revokedStatusA.body?.active === false && revokedStatusB.body?.active === false &&
      revokedA.status === 401 && revokedB.status === 401,
    'Settings revocation did not clear shared PG state and invalidate scrapes on both nodes');
    report('credential_revoked', true);

    const checks = {
      pageErrors,
      requestFailures,
      relayRequests,
      settingsCredentialPostCount: credentialResponses.filter((event) => event.method === 'POST').length,
      settingsCredentialDeleteCount: credentialResponses.filter((event) => event.method === 'DELETE').length,
    };
    const clean = pageErrors === 0 && requestFailures === 0 && relayRequests === 0 &&
      checks.settingsCredentialPostCount === 2 && checks.settingsCredentialDeleteCount === 1;
    report('page_errors', pageErrors);
    report('request_failures', requestFailures);
    report('relay_requests', relayRequests);
    report('pg_admin_metrics_final_checks', JSON.stringify(checks));
    assertThat(clean, 'PostgreSQL metrics Settings flow had unexpected browser requests or errors');
    report('web_release_sha256', bundleSha256);
  } catch (error) {
    failureStage = stage;
    throw error;
  } finally {
    setStage('close Chromium context and clear clipboard');
    if (page) await page.evaluate(async () => navigator.clipboard?.writeText('')).catch(() => {});
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
    report('browser_cleanup_complete', true);
  }
}

main().catch((error) => {
  console.error(`PG metrics browser acceptance failed at ${failureStage || stage}: ${error?.name || 'Error'}`);
  process.exitCode = 1;
});
