/*
 * WEB-RESTORE-COMPOSE-HANDOFF-01: create a restore Stage ID in Web Settings
 * against an already-running disposable Compose instance. The Python Compose
 * acceptance passes only that ID to the offline cutover coordinator.
 */

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const INPUT_FILE = process.env.WEB_RESTORE_STAGE_HANDOFF_INPUT;
const OUTPUT_FILE = process.env.WEB_RESTORE_STAGE_HANDOFF_OUTPUT;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const RESTORE_SOURCES_PATH = '/api/v1/admin/restore-sources';
const JOBS_PATH = '/api/v1/admin/jobs';

let stage = 'preflight';
let browser;
let context;
let page;
let pageErrors = 0;
let externalRequests = 0;
const apiEvents = [];

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

function readPrivateInput() {
  assertThat(typeof INPUT_FILE === 'string' && typeof OUTPUT_FILE === 'string',
    'handoff input/output paths were not configured');
  const inputStat = fs.lstatSync(INPUT_FILE);
  assertThat(inputStat.isFile() && !inputStat.isSymbolicLink() &&
    (inputStat.mode & 0o077) === 0, 'handoff input file was not private');
  const request = JSON.parse(fs.readFileSync(INPUT_FILE, 'utf8'));
  assertThat(request && typeof request === 'object' && !Array.isArray(request) &&
    JSON.stringify(Object.keys(request).sort()) === JSON.stringify([
      'archive_id', 'base_url', 'invitation_token', 'password', 'username',
    ].sort()), 'handoff input shape was invalid');
  const base = new URL(request.base_url);
  assertThat(base.protocol === 'http:' && base.hostname === '127.0.0.1' &&
    base.pathname === '/' && base.search === '' && base.hash === '',
  'handoff origin was not loopback HTTP');
  assertThat(typeof request.username === 'string' && request.username.length > 0 &&
    typeof request.password === 'string' && request.password.length >= 12 &&
    typeof request.invitation_token === 'string' && /^[A-Za-z0-9_-]{40,}$/.test(request.invitation_token) &&
    typeof request.archive_id === 'string' && UUID_RE.test(request.archive_id),
  'handoff account or source fields were invalid');
  const outputParent = fs.lstatSync(path.dirname(OUTPUT_FILE));
  assertThat(outputParent.isDirectory() && !outputParent.isSymbolicLink() &&
    (outputParent.mode & 0o077) === 0, 'handoff output directory was not private');
  assertThat(!fs.existsSync(OUTPUT_FILE) && !fs.existsSync(`${OUTPUT_FILE}.lock`),
    'handoff output path already existed');
  return { request, origin: base.origin };
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
      await locator.press('Control+A');
      await locator.pressSequentially(value, { delay: 20 });
      await locator.press('Tab');
      if (await locator.inputValue() === value) return;
    }
  } catch (_) {
    throw new Error(`could not enter Web field ${label}`);
  }
  throw new Error(`Web field ${label} did not retain input`);
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

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function trackApi() {
  const requests = new WeakMap();
  page.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (!['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol)) return;
    if (url.origin !== new URL(process.env.WEB_RESTORE_STAGE_HANDOFF_ORIGIN).origin) {
      externalRequests += 1;
      return;
    }
    if (url.pathname !== '/api/v1/auth/register' && url.pathname !== RESTORE_SOURCES_PATH &&
        url.pathname !== JOBS_PATH) return;
    let body = null;
    if (url.pathname === JOBS_PATH && request.method() === 'POST') {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    requests.set(request, {
      pathname: url.pathname,
      method: request.method(),
      body,
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
    });
  });
  page.on('response', (response) => {
    const metadata = requests.get(response.request());
    if (!metadata) return;
    apiEvents.push({ ...metadata, status: response.status(), payload: response.json().catch(() => null) });
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

async function main() {
  const { request, origin } = readPrivateInput();
  process.env.WEB_RESTORE_STAGE_HANDOFF_ORIGIN = origin;
  const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
  browser = await chromium.launch(launchOptions);
  context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
  page = await context.newPage();
  page.on('pageerror', () => { pageErrors += 1; });
  trackApi();

  setStage('connect browser to disposable Compose Web origin');
  await configurePage(request.base_url);
  setStage('register allowlisted administrator through invitation UI');
  await field('Email or username');
  await click('Have an instance invitation? Create account');
  await fill('Email on the invitation', request.username);
  await fill('Master password · 12+ characters', request.password);
  await fill('Confirm master password', request.password);
  await fill('Instance invitation token', request.invitation_token);
  await fill('Device name', 'Compose restore-stage handoff');
  await fill('First Vault', 'Compose restore-stage handoff');
  setStage('submit invited administrator registration');
  const registrationStart = apiEvents.length;
  await click('Create invited account');
  const registration = await waitForApi((event) =>
    event.pathname === '/api/v1/auth/register' && event.method === 'POST', registrationStart);
  reportStatus('web_invited_admin_registration', registration.status);
  const registrationPayload = await registration.payload;
  assertThat(registration.status >= 200 && registration.status < 300 &&
    typeof registrationPayload?.access_token === 'string' &&
    UUID_RE.test(registrationPayload?.account_id) && UUID_RE.test(registrationPayload?.device_id),
  'Web invitation registration response was incomplete');
  await (await button('Add host')).waitFor({ state: 'visible', timeout: 45000 });
  request.invitation_token = '';
  request.password = '';

  setStage('open Web Settings and load the existing Compose archive');
  await click('Settings');
  await waitFor(() => hasVisibleSemanticText('Prepare isolated restore copy'));
  const sourceStart = apiEvents.length;
  await click('Load restore sources');
  const sourceEvent = await waitForApi((event) =>
    event.pathname === RESTORE_SOURCES_PATH && event.method === 'GET', sourceStart);
  reportStatus('web_settings_restore_sources', sourceEvent.status);
  const sourcePayload = await sourceEvent.payload;
  assertThat(sourceEvent.status === 200 && sourceEvent.hasBearer &&
    exactKeys(sourcePayload, ['sources', 'total']) && Array.isArray(sourcePayload.sources),
  'Web Settings did not load authenticated restore sources');
  const matchingSource = sourcePayload.sources.find((source) =>
    source?.archive_id === request.archive_id &&
    ['manual', 'scheduled'].includes(source.origin) && ['local', 'replica'].includes(source.source));
  assertThat(matchingSource, 'Web Settings did not list the expected Compose backup');
  assertThat(await hasVisibleSemanticText('Manual') || await hasVisibleSemanticText('Scheduled'),
    'Web Settings did not render the safe restore source label');
  const sourceRadio = page.getByRole('radio', { name: /Manual|Scheduled/ }).first();
  await sourceRadio.waitFor({ state: 'visible', timeout: 15000 });
  const radioLabel = typeof sourceRadio.ariaSnapshot === 'function'
    ? await sourceRadio.ariaSnapshot() : await sourceRadio.innerText();
  assertThat(!radioLabel.includes(request.archive_id),
    'Web source label exposed the archive ID');
  await sourceRadio.click();

  setStage('create restore Stage ID through the Web Settings confirmation');
  await click('Prepare isolated copy');
  await waitFor(() => hasVisibleSemanticText('Prepare isolated restore copy?'));
  const dialogText = await page.evaluate(() => `${document.body.innerText || ''}\n` +
    [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => `${element.textContent || ''}\n` +
        [...element.attributes].map((attribute) => attribute.value).join('\n')).join('\n'));
  assertThat(dialogText.includes('does not activate or replace live data'),
    'Web restore confirmation did not describe the isolated staging boundary');
  const confirm = page.getByRole('button', { name: 'Prepare isolated copy', exact: true }).last();
  await confirm.waitFor({ state: 'visible', timeout: 15000 });
  const postStart = apiEvents.length;
  await confirm.click();
  const post = await waitForApi((event) =>
    event.pathname === JOBS_PATH && event.method === 'POST', postStart);
  reportStatus('web_settings_restore_stage_create', post.status);
  const postPayload = await post.payload;
  assertThat(post.hasBearer && post.status === 202 &&
    exactKeys(post.body, ['request_id', 'action', 'archive_id', 'archive_source']) &&
    UUID_RE.test(post.body.request_id) && post.body.action === 'restore' &&
    post.body.archive_id === request.archive_id && post.body.archive_source === matchingSource.source &&
    exactKeys(postPayload, ['job']) && UUID_RE.test(postPayload.job?.job_id) &&
    postPayload.job?.archive_id === request.archive_id && postPayload.job?.action === 'restore',
  'Web Settings restore request or accepted Stage ID did not match its source');
  const stageId = postPayload.job.job_id;
  assertThat(UUID_RE.test(stageId), 'Web restore response Stage ID was not canonical');
  await waitFor(() => hasVisibleSemanticText('Restore staging · Prepared'), 60000);
  const settingsText = await page.evaluate(() => `${document.body.innerText || ''}\n` +
    [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => `${element.textContent || ''}\n` +
        [...element.attributes].map((attribute) => attribute.value).join('\n')).join('\n'));
  assertThat(settingsText.includes(stageId),
    'Web Settings did not render the Stage ID for operator handoff');
  assertThat(pageErrors === 0, 'Compose Web handoff page reported an uncaught error');
  assertThat(externalRequests === 0, 'Compose Web handoff made an external network request');
  assertThat(apiEvents.filter((event) => event.pathname === JOBS_PATH && event.method === 'POST').length === 1,
    'Web Settings submitted more than one restore stage');

  const outputDescriptor = fs.openSync(OUTPUT_FILE, 'wx', 0o600);
  try {
    fs.writeFileSync(outputDescriptor, `${JSON.stringify({ restore_job_id: stageId })}\n`, 'utf8');
    fs.fsyncSync(outputDescriptor);
  } finally {
    fs.closeSync(outputDescriptor);
  }
  assertThat((fs.statSync(OUTPUT_FILE).mode & 0o777) === 0o600,
    'handoff result file permissions were not private');
  console.log('assert: web_settings_stage_id_written_privately=true');
  console.log('WEB-RESTORE-COMPOSE-HANDOFF-01 passed');
}

async function cleanup() {
  if (context) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

main().catch(async (error) => {
  const safeCode = error?.safeAssertion || 'web_handoff_failed';
  console.error(`failure: stage=${stage} code=${safeCode}`);
  if (safeCode === 'web_handoff_failed') {
    const kind = error?.name === 'TimeoutError' ? 'timeout' :
      error?.message === 'expected Web API response did not arrive' ? 'api_response_timeout' :
      error?.message === 'expected Web state did not appear' ? 'web_state_timeout' :
      error?.message?.startsWith('expected Web field ') ? 'web_field_missing' :
      error?.message?.startsWith('could not enter Web field ') ? 'web_field_input_failed' :
      error?.message?.startsWith('Web field ') ? 'web_field_not_retained' : 'unexpected';
    console.error(`failure: kind=${kind} page_errors=${pageErrors} external_requests=${externalRequests}`);
    console.error(`failure: tracked_api=${apiEvents.map((event) => `${event.method}:${event.pathname}:${event.status}`).join(',') || 'none'}`);
    if (page && !page.isClosed()) {
      const controls = await page.evaluate(() => ({
        invitationButton: [...document.querySelectorAll('flt-semantics')]
          .some((node) => node.getAttribute('aria-label')?.includes('Have an instance invitation? Create account')),
        createButton: [...document.querySelectorAll('flt-semantics')]
          .some((node) => node.getAttribute('aria-label')?.includes('Create invited account')),
        addHostButton: [...document.querySelectorAll('flt-semantics')]
          .some((node) => node.getAttribute('aria-label')?.includes('Add host')),
        inputCount: document.querySelectorAll('input').length,
      })).catch(() => null);
      if (controls) console.error(`failure: visible_controls=${JSON.stringify(controls)}`);
    }
  }
  await cleanup();
  process.exitCode = 1;
}).finally(cleanup);
