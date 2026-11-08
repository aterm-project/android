/*
 * WEB-PG-ADMIN-ACCOUNTS-01: exercise PostgreSQL-backed account invitations,
 * account/session administration, and credential revocation from Settings.
 * The Python acceptance fixture owns the PostgreSQL server and credentials.
 * Sensitive values and raw target identifiers remain in memory only.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_BASE_URL;
const API_BASE_URL = typeof BASE_URL === 'string' ? BASE_URL.replace(/\/+$/, '') : BASE_URL;
const ADMIN_USERNAME = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_ADMIN_USERNAME;
const ADMIN_PASSWORD = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_ADMIN_PASSWORD;
let bootstrapToken = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_BOOTSTRAP_TOKEN;
const TARGET_USERNAME = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_TARGET_USERNAME;
const TARGET_PASSWORD = process.env.ATERMIUS_PG_ADMIN_ACCOUNTS_TARGET_PASSWORD;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

const browserSecrets = [ADMIN_PASSWORD, TARGET_PASSWORD, bootstrapToken].filter(Boolean);
let invitationToken;
let adminAccessToken;
let targetAccessToken;
let targetRefreshToken;
let targetLoginVerifier;
let adminUserId;
let adminDeviceId;
let targetUserId;
let targetDeviceId;
let browser;
let adminContext;
let targetContext;
let adminPage;
let targetPage;
let stage = 'preflight';
let cleanupPromise;
let cleanupFailed = false;
let pageErrors = 0;
let consoleErrors = 0;
let requestFailures = 0;
let relayRequests = 0;
let unexpectedHttpErrors = 0;
let expectedRevokedToken401s = 0;
const apiEvents = [];
const safeRouteStatuses = [];
const inFlight = new WeakMap();

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

function reportStatus(name, status) {
  report(name, Number.isInteger(status) ? status : 0);
}

function rememberSecret(value) {
  if (typeof value === 'string' && value.length > 0 && !browserSecrets.includes(value)) {
    browserSecrets.push(value);
  }
}

function safeFailureSummary(error) {
  let summary = typeof error?.message === 'string'
    ? error.message.split(/\r?\n/, 1)[0]
    : '';
  for (const secret of [
    ...browserSecrets,
    invitationToken,
    adminAccessToken,
    targetAccessToken,
    targetRefreshToken,
    targetLoginVerifier,
    ADMIN_USERNAME,
    TARGET_USERNAME,
    adminUserId,
    adminDeviceId,
    targetUserId,
    targetDeviceId,
  ]) {
    if (typeof secret === 'string' && secret.length > 0) summary = summary.replaceAll(secret, '[redacted]');
  }
  return summary
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, '[account]')
    .replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, '[id]')
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .slice(0, 500);
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web or API state did not appear');
}

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

async function clickLastButton(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).last();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  await locator.click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 20 });
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width === 0 || rect.height === 0) return false;
      return `${element.textContent || ''}\n${[...element.attributes]
        .map((attribute) => attribute.value).join('\n')}`.includes(expected);
    });
  }, needle);
}

function normalizeApiRoute(request) {
  let pathname;
  try { pathname = new URL(request.url()).pathname; } catch (_) { return null; }
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/auth/me' || pathname === '/api/v1/me') return 'profile';
  if (pathname === '/api/v1/auth/refresh') return 'refresh';
  if (pathname === '/api/v1/admin/account-invitations') return 'account-invitations';
  if (/^\/api\/v1\/admin\/account-invitations\/[0-9a-f-]+\/revoke$/i.test(pathname)) {
    return 'invitation-revoke';
  }
  if (pathname === '/api/v1/admin/accounts') return 'accounts';
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions\/[0-9a-f-]+\/revoke$/i.test(pathname)) {
    return 'session-revoke';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions\/revoke$/i.test(pathname)) {
    return 'sessions-revoke';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions$/i.test(pathname)) {
    return 'account-sessions';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/status$/i.test(pathname)) {
    return 'account-status';
  }
  if (pathname === '/api/v1/admin/audit') return 'admin-audit';
  return null;
}

function trackApi(page, onTargetRegistrationRequest) {
  const metadataByRequest = new WeakMap();
  const outstanding = new Set();
  inFlight.set(page, outstanding);
  page.on('request', (request) => {
    outstanding.add(request);
    const route = normalizeApiRoute(request);
    if (!route) {
      if (new URL(request.url()).pathname.startsWith('/api/v1/relay/')) relayRequests += 1;
      return;
    }
    let hasBearer = false;
    try { hasBearer = /^Bearer\s+\S+$/i.test(request.headers().authorization || ''); } catch (_) {}
    if (route === 'register' && onTargetRegistrationRequest) {
      try {
        const body = request.postDataJSON();
        if (body?.username === TARGET_USERNAME && typeof body.login_verifier === 'string') {
          targetLoginVerifier = body.login_verifier;
          targetDeviceId = body.device?.device_id;
          rememberSecret(targetLoginVerifier);
        }
      } catch (_) { /* Registration payload details stay out of logs. */ }
    }
    metadataByRequest.set(request, { route, method: request.method(), hasBearer });
  });
  const finish = (request) => outstanding.delete(request);
  page.on('requestfinished', finish);
  page.on('requestfailed', (request) => {
    finish(request);
    requestFailures += 1;
  });
  page.on('response', (response) => {
    const request = response.request();
    finish(request);
    if (response.status() >= 400) unexpectedHttpErrors += 1;
    const metadata = metadataByRequest.get(request);
    if (!metadata) return;
    const event = {
      ...metadata,
      status: response.status(),
      sequence: apiEvents.length,
      payloadPromise: response.json().catch(() => null),
    };
    apiEvents.push(event);
    safeRouteStatuses.push({ route: metadata.route, status: response.status() });
    if (safeRouteStatuses.length > 32) safeRouteStatuses.shift();
  });
  page.on('pageerror', () => { pageErrors += 1; });
  page.on('console', (message) => {
    if (message.type() === 'error') consoleErrors += 1;
  });
}

async function waitForApiEvent(start, route, method, timeoutMs = 45000) {
  await waitFor(() => apiEvents.some((event) => event.sequence >= start &&
    event.route === route && event.method === method), timeoutMs);
  return apiEvents.find((event) => event.sequence >= start &&
    event.route === route && event.method === method);
}

async function configurePage(page) {
  setStage('open Web Release from PostgreSQL-backed server');
  const response = await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  reportStatus('pg_admin_accounts_web_index_status', response?.status() ?? 0);
  assertThat(response?.status() === 200, 'Web Release index did not load');
  setStage('wait for Flutter Web runtime');
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
  await fill(page, 'Server URL', BASE_URL);
  await click(page, 'Connect securely');
}

async function directApi(method, pathname, { token, body } = {}) {
  const response = await fetch(`${API_BASE_URL}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20000),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertSafeDto(value) {
  const forbidden = /(password|secret|verifier|envelope|ciphertext|token|hash|ip|address)/i;
  const visit = (item) => {
    if (Array.isArray(item)) { item.forEach(visit); return; }
    if (!item || typeof item !== 'object') return;
    for (const [key, child] of Object.entries(item)) {
      assertThat(!forbidden.test(key), 'admin DTO contained a forbidden field');
      visit(child);
    }
  };
  visit(value);
  const ipv4 = /\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/;
  assertThat(!ipv4.test(JSON.stringify(value)), 'admin DTO contained an IP address');
}

function validateAccountsPage(payload, expectedStatus) {
  assertThat(exactKeys(payload, ['accounts', 'total', 'limit', 'offset']) &&
    Array.isArray(payload.accounts) && Number.isInteger(payload.total) &&
    Number.isInteger(payload.limit) && Number.isInteger(payload.offset),
  'admin account list page shape was invalid');
  assertSafeDto(payload);
  for (const account of payload.accounts) {
    assertThat(exactKeys(account, [
      'user_id', 'username', 'status', 'created_at', 'active_device_count', 'active_session_count',
    ]), 'admin account metadata shape changed');
  }
  const row = payload.accounts.find((account) => account.user_id === targetUserId);
  assertThat(row && row.username === TARGET_USERNAME && row.status === expectedStatus,
    'admin account list omitted the expected target status');
  return row;
}

function validateSessionsPage(payload) {
  assertThat(exactKeys(payload, ['sessions', 'total', 'limit', 'offset']) &&
    Array.isArray(payload.sessions) && Number.isInteger(payload.total) &&
    Number.isInteger(payload.limit) && Number.isInteger(payload.offset),
  'admin account sessions page shape was invalid');
  assertSafeDto(payload);
  for (const session of payload.sessions) {
    assertThat(exactKeys(session, [
      'session_id', 'device_id', 'device_name', 'created_at', 'access_expires_at',
      'refresh_expires_at', 'revoked_at', 'active',
    ]), 'admin session metadata shape changed');
  }
  return payload.sessions;
}

function validateInvitationReceipt(payload) {
  const invitation = payload?.invitation;
  assertThat(exactKeys(payload, ['invitation']) && exactKeys(invitation, [
    'invitation_id', 'username', 'created_at', 'expires_at', 'token',
  ]) && typeof invitation.invitation_id === 'string' &&
    invitation.username === TARGET_USERNAME &&
    Number.isFinite(Date.parse(invitation.created_at)) &&
    Number.isFinite(Date.parse(invitation.expires_at)) &&
    /^[A-Za-z0-9_-]{43}$/.test(invitation.token),
  'account invitation receipt was invalid');
  const lifetime = (Date.parse(invitation.expires_at) - Date.parse(invitation.created_at)) / 1000;
  assertThat(lifetime >= 604799 && lifetime <= 604801,
    'account invitation lifetime was not seven days');
  return invitation;
}

async function assertTokensRejected(tokens, label) {
  const access = await directApi('GET', '/api/v1/me', { token: tokens.accessToken });
  const refresh = await directApi('POST', '/api/v1/auth/refresh', {
    body: { refresh_token: tokens.refreshToken },
  });
  reportStatus(`${label}_access_denied_status`, access.status);
  reportStatus(`${label}_refresh_denied_status`, refresh.status);
  assertThat(access.status === 401 && refresh.status === 401,
    `revoked ${label} credentials were not denied`);
  expectedRevokedToken401s += 2;
}

async function loginTargetAgain() {
  const response = await directApi('POST', '/api/v1/auth/login', {
    body: {
      username: TARGET_USERNAME,
      login_verifier: targetLoginVerifier,
      device_id: targetDeviceId,
    },
  });
  assertThat(response.status === 200 && typeof response.body?.access_token === 'string' &&
    typeof response.body?.refresh_token === 'string',
  'fresh target login did not create a second session');
  return { accessToken: response.body.access_token, refreshToken: response.body.refresh_token };
}

async function validateAuditPrivacy() {
  const auditEvents = [];
  let cursor;
  let firstStatus = 0;
  for (let pageNumber = 0; pageNumber < 50; pageNumber += 1) {
    const suffix = cursor
      ? `&cursor=${encodeURIComponent(cursor)}`
      : '';
    const response = await directApi('GET', `/api/v1/admin/audit?limit=100${suffix}`, {
      token: adminAccessToken,
    });
    if (pageNumber === 0) firstStatus = response.status;
    const payload = response.body;
    assertThat(response.status === 200 &&
      exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'admin audit feed envelope was invalid');
    auditEvents.push(...payload.events);
    if (!payload.has_more) break;
    assertThat(typeof payload.next_cursor === 'string' && payload.next_cursor.length > 0,
      'admin audit cursor was missing while more rows were available');
    cursor = payload.next_cursor;
    assertThat(pageNumber < 49, 'admin audit pagination exceeded the acceptance bound');
  }
  reportStatus('pg_admin_accounts_audit_list', firstStatus);
  const actions = [
    'admin.account_session_revoked',
    'admin.account_sessions_revoked',
    'admin.account_disabled',
    'admin.account_enabled',
  ];
  const rows = auditEvents.filter((event) => actions.includes(event.action) &&
    event.actor_user_id === adminUserId && event.actor_device_id === adminDeviceId);
  const requiredFields = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
    'resource_id', 'result', 'occurred_at', 'source',
  ];
  assertThat(rows.length === actions.length, 'admin lifecycle audit events were incomplete');
  for (const action of actions) {
    const matching = rows.filter((event) => event.action === action);
    assertThat(matching.length === 1, 'admin lifecycle audit action count was unexpected');
  }
  for (const event of rows) {
    assertThat(exactKeys(event, requiredFields) && /^\d+$/.test(event.event_id) &&
      event.scope === 'instance' && event.actor_user_id === adminUserId &&
      event.actor_device_id === adminDeviceId && event.resource_type === 'account' &&
      typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id) &&
      event.resource_id !== targetUserId && event.result === 'success' && event.source === 'api' &&
      Number.isFinite(Date.parse(event.occurred_at)),
    'admin lifecycle audit row had an invalid actor or identifier');
    const serialized = JSON.stringify(event);
    assertThat(!serialized.includes(targetUserId) && !serialized.includes(TARGET_USERNAME),
      'admin audit row exposed the raw target identifier');
  }
  const eventIds = rows.map((event) => BigInt(event.event_id));
  const orderedRows = [...rows].sort((left, right) =>
    BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1);
  assertThat(orderedRows.map((event) => event.action).join(',') === actions.join(','),
    'account lifecycle audit events were not ordered by operation');
  for (let index = 1; index < eventIds.length; index += 1) {
    assertThat(eventIds[index - 1] !== eventIds[index], 'admin audit event IDs were duplicated');
  }
  report('pg_admin_accounts_safe_dto_privacy', true);
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    invitationToken = undefined;
    adminAccessToken = undefined;
    targetAccessToken = undefined;
    targetRefreshToken = undefined;
    targetLoginVerifier = undefined;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      if (targetContext) await targetContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
    } catch (_) { cleanupFailed = true; }
  })();
  return cleanupPromise;
}

async function main() {
  assertThat(BASE_URL && ADMIN_USERNAME && ADMIN_PASSWORD && bootstrapToken &&
    TARGET_USERNAME && TARGET_PASSWORD,
  'PostgreSQL admin accounts browser environment is incomplete');
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
      'compiled Flutter Web Release bundle is incomplete');
  }
  const parsedBase = new URL(BASE_URL);
  assertThat(['http:', 'https:'].includes(parsedBase.protocol) &&
    parsedBase.username === '' && parsedBase.password === '',
  'PostgreSQL browser base URL was invalid');

  try {
    const options = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(options);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await adminContext.route('**/favicon.ico', (route) => route.fulfill({
      status: 204,
      headers: { 'cache-control': 'no-store' },
    }));
    adminPage = await adminContext.newPage();
    trackApi(adminPage);
    await configurePage(adminPage);

    setStage('register allowlisted administrator through Web UI');
    await field(adminPage, 'Owner email');
    await fill(adminPage, 'Owner email', ADMIN_USERNAME);
    await fill(adminPage, 'Master password · 12+ characters', ADMIN_PASSWORD);
    await fill(adminPage, 'Confirm master password', ADMIN_PASSWORD);
    await fill(adminPage, 'One-time bootstrap token', bootstrapToken);
    await fill(adminPage, 'Device name', 'PostgreSQL account controls');
    await fill(adminPage, 'First Vault', 'PostgreSQL account controls');
    const adminRegisterStart = apiEvents.length;
    await click(adminPage, 'Create owner account');
    bootstrapToken = undefined;
    await (await button(adminPage, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
    const adminRegister = await waitForApiEvent(adminRegisterStart, 'register', 'POST');
    const adminReceipt = await adminRegister.payloadPromise;
    assertThat(adminRegister.status >= 200 && adminRegister.status < 300 &&
      typeof adminReceipt?.account_id === 'string' &&
      typeof adminReceipt?.device_id === 'string' &&
      typeof adminReceipt?.access_token === 'string',
    'allowlisted administrator registration receipt was incomplete');
    adminUserId = adminReceipt.account_id;
    adminDeviceId = adminReceipt.device_id;
    adminAccessToken = adminReceipt.access_token;
    rememberSecret(adminAccessToken);
    adminRegister.payloadPromise = Promise.resolve(null);
    report('pg_admin_accounts_admin_registration', true);
    reportStatus('pg_admin_accounts_admin_registration_http_status', adminRegister.status);

    setStage('open PostgreSQL Settings account invitation controls');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Instance accounts and sessions'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Account invitations'));
    const initialInvitationStart = apiEvents.length;
    await click(adminPage, 'Load account invitations');
    const initialInvitation = await waitForApiEvent(
      initialInvitationStart, 'account-invitations', 'GET');
    assertThat(initialInvitation.status === 200 && initialInvitation.hasBearer,
      'admin invitation list was not an authenticated success');
    await initialInvitation.payloadPromise;

    setStage('issue ordinary target invitation in Settings');
    await click(adminPage, 'Issue account invitation');
    await fill(adminPage, 'Invitation username', TARGET_USERNAME);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Invitation expires in days') &&
      hasVisibleSemanticText(adminPage, '7 days'));
    const issueStart = apiEvents.length;
    await click(adminPage, 'Create invitation');
    const issueEvent = await waitForApiEvent(issueStart, 'account-invitations', 'POST');
    const issuePayload = await issueEvent.payloadPromise;
    reportStatus('pg_admin_accounts_invitation_issue', issueEvent.status);
    assertThat(issueEvent.status === 201 && issueEvent.hasBearer,
      'account invitation creation was not an authenticated 201');
    const invitation = validateInvitationReceipt(issuePayload);
    const invitationId = invitation.invitation_id;
    invitationToken = invitation.token;
    rememberSecret(invitationToken);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'One-time invitation token') &&
      hasVisibleSemanticText(adminPage, invitationToken));
    await click(adminPage, 'Done');
    const persistedInvitation = await adminPage.evaluate(() => JSON.stringify({
      local: Object.entries(localStorage),
      session: Object.entries(sessionStorage),
    }));
    assertThat(!persistedInvitation.includes(invitationToken),
      'one-time invitation token was persisted in browser storage');
    issuePayload.invitation.token = '';
    issueEvent.payloadPromise = Promise.resolve(null);
    report('pg_admin_accounts_invitation_visible_then_cleared', true);

    setStage('register ordinary target account in second Chromium context');
    targetContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await targetContext.route('**/favicon.ico', (route) => route.fulfill({
      status: 204,
      headers: { 'cache-control': 'no-store' },
    }));
    targetPage = await targetContext.newPage();
    trackApi(targetPage, true);
    await configurePage(targetPage);
    await field(targetPage, 'Email or username');
    await click(targetPage, 'Have an instance invitation? Create account');
    await field(targetPage, 'Email on the invitation');
    await fill(targetPage, 'Email on the invitation', TARGET_USERNAME);
    await fill(targetPage, 'Master password · 12+ characters', TARGET_PASSWORD);
    await fill(targetPage, 'Confirm master password', TARGET_PASSWORD);
    await fill(targetPage, 'Instance invitation token', invitationToken);
    invitationToken = undefined;
    await fill(targetPage, 'Device name', 'PostgreSQL account target');
    await fill(targetPage, 'First Vault', 'PostgreSQL account target Vault');
    const targetRegisterStart = apiEvents.length;
    await click(targetPage, 'Create invited account');
    await (await button(targetPage, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
    const targetRegister = await waitForApiEvent(targetRegisterStart, 'register', 'POST');
    const targetReceipt = await targetRegister.payloadPromise;
    assertThat(targetRegister.status >= 200 && targetRegister.status < 300 &&
      targetRegister.hasBearer === false && typeof targetReceipt?.account_id === 'string' &&
      typeof targetReceipt?.device_id === 'string' &&
      typeof targetReceipt?.access_token === 'string' &&
      typeof targetReceipt?.refresh_token === 'string' &&
      typeof targetLoginVerifier === 'string' && targetDeviceId === targetReceipt.device_id,
    'ordinary account registration receipt was incomplete');
    targetUserId = targetReceipt.account_id;
    targetDeviceId = targetReceipt.device_id;
    targetAccessToken = targetReceipt.access_token;
    targetRefreshToken = targetReceipt.refresh_token;
    [targetUserId, targetDeviceId, targetAccessToken, targetRefreshToken]
      .forEach(rememberSecret);
    targetRegister.payloadPromise = Promise.resolve(null);
    reportStatus('pg_admin_accounts_member_registration', targetRegister.status);

    const consumedStart = apiEvents.length;
    await click(adminPage, 'Refresh account invitations');
    const consumedEvent = await waitForApiEvent(consumedStart, 'account-invitations', 'GET');
    const consumedPage = await consumedEvent.payloadPromise;
    const consumedRow = consumedPage?.invitations?.find((row) => row.invitation_id === invitationId);
    assertThat(consumedEvent.status === 200 && consumedEvent.hasBearer && consumedRow &&
      consumedRow.username === TARGET_USERNAME && consumedRow.status === 'consumed' &&
      !JSON.stringify(consumedPage).includes('token'),
    'invitation was not consumed into a safe Settings list DTO');
    report('pg_admin_accounts_invitation_consumed', true);

    // The target account is registered and returned its first session. Capture
    // errors observed through that point, then stop observing its independent
    // first-sync traffic before closing the context; this acceptance covers
    // admin account controls, not completion of the target's sync bootstrap.
    setStage('close invited-account registration context');
    assertThat(pageErrors === 0 && consoleErrors === 0 && requestFailures === 0 &&
      unexpectedHttpErrors === 0,
    'invited-account registration browser recorded an unexpected error');
    targetPage.removeAllListeners();
    await targetContext.close();
    targetContext = undefined;
    targetPage = undefined;

    setStage('load PostgreSQL account list in Settings');
    const accountsStart = apiEvents.length;
    await click(adminPage, 'Refresh admin accounts');
    const accountsEvent = await waitForApiEvent(accountsStart, 'accounts', 'GET');
    assertThat(accountsEvent.status === 200 && accountsEvent.hasBearer,
      'admin account list was not an authenticated success');
    let accountsPayload = await accountsEvent.payloadPromise;
    let targetAccount = validateAccountsPage(accountsPayload, 'active');
    assertThat(targetAccount.active_device_count === 1 && targetAccount.active_session_count === 1,
      'new target account active device/session counts were unexpected');
    reportStatus('pg_admin_accounts_list', accountsEvent.status);

    setStage('load target account sessions in Settings');
    const sessionsStart = apiEvents.length;
    await click(adminPage, 'View sessions');
    const sessionsEvent = await waitForApiEvent(sessionsStart, 'account-sessions', 'GET');
    const sessionsPayload = await sessionsEvent.payloadPromise;
    assertThat(sessionsEvent.status === 200 && sessionsEvent.hasBearer,
      'admin target session listing was not an authenticated success');
    const initialSessions = validateSessionsPage(sessionsPayload);
    assertThat(sessionsPayload.total === 1 && initialSessions.length === 1 &&
      initialSessions[0].device_id === targetDeviceId && initialSessions[0].active === true &&
      initialSessions[0].revoked_at === null,
    'initial target session metadata did not match the registered device');
    const firstSessionId = initialSessions[0].session_id;
    reportStatus('pg_admin_accounts_sessions_list', sessionsEvent.status);
    report('pg_admin_accounts_safe_session_dto', true);

    setStage('revoke one target session from Settings');
    await click(adminPage, 'Revoke session');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoke this session?'));
    const singleRevokeStart = apiEvents.length;
    await clickLastButton(adminPage, 'Revoke session');
    const singleRevoke = await waitForApiEvent(singleRevokeStart, 'session-revoke', 'POST');
    const singleReceipt = await singleRevoke.payloadPromise;
    assertThat(singleRevoke.status === 200 && singleRevoke.hasBearer &&
      singleReceipt?.account_id === targetUserId && singleReceipt?.session_id === firstSessionId &&
      singleReceipt?.revoked === true && singleReceipt?.changed === true,
    'individual session revoke receipt was invalid');
    const afterSingle = await waitForApiEvent(singleRevokeStart, 'account-sessions', 'GET');
    const afterSinglePayload = await afterSingle.payloadPromise;
    const afterSingleSessions = validateSessionsPage(afterSinglePayload);
    assertThat(afterSingle.status === 200 && afterSingleSessions.length === 1 &&
      afterSingleSessions[0].session_id === firstSessionId && afterSingleSessions[0].active === false &&
      afterSingleSessions[0].revoked_at !== null,
    'Settings did not refresh the individually revoked session');
    reportStatus('pg_admin_accounts_single_revoke', singleRevoke.status);
    await assertTokensRejected({ accessToken: targetAccessToken, refreshToken: targetRefreshToken },
      'single_revoke');

    setStage('create second target session for bulk revoke coverage');
    const secondLogin = await loginTargetAgain();
    rememberSecret(secondLogin.accessToken);
    rememberSecret(secondLogin.refreshToken);
    const sessionsRefreshStart = apiEvents.length;
    await click(adminPage, 'Refresh account sessions');
    const secondSessionsEvent = await waitForApiEvent(
      sessionsRefreshStart, 'account-sessions', 'GET');
    const secondSessionsPayload = await secondSessionsEvent.payloadPromise;
    const secondSessions = validateSessionsPage(secondSessionsPayload);
    assertThat(secondSessionsEvent.status === 200 && secondSessionsPayload.total === 2 &&
      secondSessions.filter((session) => session.active).length === 1,
    'fresh target login did not create one active session for bulk revoke');

    setStage('revoke remaining target sessions from Settings');
    await click(adminPage, 'Revoke all sessions');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoke all sessions?'));
    const bulkStart = apiEvents.length;
    await clickLastButton(adminPage, 'Revoke sessions');
    const bulkRevoke = await waitForApiEvent(bulkStart, 'sessions-revoke', 'POST');
    const bulkReceipt = await bulkRevoke.payloadPromise;
    assertThat(bulkRevoke.status === 200 && bulkRevoke.hasBearer &&
      bulkReceipt?.account_id === targetUserId && bulkReceipt?.revoked_sessions === 1,
    'bulk session revoke receipt was invalid');
    reportStatus('pg_admin_accounts_bulk_revoke', bulkRevoke.status);
    await assertTokensRejected(secondLogin, 'bulk_revoke');

    setStage('create active target session for disable coverage');
    const thirdLogin = await loginTargetAgain();
    rememberSecret(thirdLogin.accessToken);
    rememberSecret(thirdLogin.refreshToken);
    const beforeDisableSessionsStart = apiEvents.length;
    await click(adminPage, 'Refresh account sessions');
    const beforeDisableSessionsEvent = await waitForApiEvent(
      beforeDisableSessionsStart, 'account-sessions', 'GET');
    const beforeDisableSessions = await beforeDisableSessionsEvent.payloadPromise;
    assertThat(beforeDisableSessionsEvent.status === 200 &&
      beforeDisableSessions.sessions?.filter((session) => session.active).length === 1,
    'target account did not have an active session before disable');

    setStage('disable target account from Settings');
    await click(adminPage, 'Disable account');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Disable account?'));
    const disableStart = apiEvents.length;
    await clickLastButton(adminPage, 'Disable account');
    const disableEvent = await waitForApiEvent(disableStart, 'account-status', 'PUT');
    const disableReceipt = await disableEvent.payloadPromise;
    assertThat(disableEvent.status === 200 && disableEvent.hasBearer &&
      disableReceipt?.account_id === targetUserId && disableReceipt?.status === 'disabled' &&
      disableReceipt?.changed === true && disableReceipt?.revoked_sessions === 1,
    'target account disable receipt was invalid');
    reportStatus('pg_admin_accounts_disable', disableEvent.status);
    await assertTokensRejected(thirdLogin, 'disabled');
    const disabledAccountsEvent = await waitForApiEvent(disableStart, 'accounts', 'GET');
    const disabledAccountsPayload = await disabledAccountsEvent.payloadPromise;
    targetAccount = validateAccountsPage(disabledAccountsPayload, 'disabled');
    assertThat(targetAccount.active_session_count === 0,
      'disabled target account retained active sessions');

    setStage('re-enable target account from Settings');
    await click(adminPage, 'Re-enable account');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Re-enable account?'));
    const enableStart = apiEvents.length;
    await clickLastButton(adminPage, 'Re-enable account');
    const enableEvent = await waitForApiEvent(enableStart, 'account-status', 'PUT');
    const enableReceipt = await enableEvent.payloadPromise;
    assertThat(enableEvent.status === 200 && enableEvent.hasBearer &&
      enableReceipt?.account_id === targetUserId && enableReceipt?.status === 'active' &&
      enableReceipt?.changed === true && enableReceipt?.revoked_sessions === 0,
    'target account re-enable receipt was invalid');
    reportStatus('pg_admin_accounts_enable', enableEvent.status);
    const enabledAccountsEvent = await waitForApiEvent(enableStart, 'accounts', 'GET');
    const enabledAccountsPayload = await enabledAccountsEvent.payloadPromise;
    validateAccountsPage(enabledAccountsPayload, 'active');

    setStage('verify every prior target credential stays revoked after re-enable');
    await assertTokensRejected({ accessToken: targetAccessToken, refreshToken: targetRefreshToken },
      'old_after_reenable');
    await assertTokensRejected(secondLogin, 'second_old_after_reenable');
    await assertTokensRejected(thirdLogin, 'third_old_after_reenable');
    report('pg_admin_accounts_old_access_denied_after_reenable', true);
    report('pg_admin_accounts_old_refresh_denied_after_reenable', true);

    setStage('verify admin Settings and session remain usable');
    const finalAccountsStart = apiEvents.length;
    await click(adminPage, 'Refresh admin accounts');
    const finalAccountsEvent = await waitForApiEvent(finalAccountsStart, 'accounts', 'GET');
    assertThat(finalAccountsEvent.status === 200 && finalAccountsEvent.hasBearer,
      'administrator could not continue using Settings after target lifecycle changes');
    const finalAccountPayload = await finalAccountsEvent.payloadPromise;
    validateAccountsPage(finalAccountPayload, 'active');
    const adminProfile = await directApi('GET', '/api/v1/me', { token: adminAccessToken });
    assertThat(adminProfile.status === 200, 'administrator session was not usable after target changes');
    report('pg_admin_accounts_admin_remains_usable', true);

    setStage('validate account and session audit privacy');
    await validateAuditPrivacy();

    assertThat(pageErrors === 0 && consoleErrors === 0 && requestFailures === 0 &&
      relayRequests === 0 && unexpectedHttpErrors === 0,
    'browser recorded an unexpected runtime, network, Relay, or HTTP error');
    report('pg_admin_accounts_expected_revoked_token_401_count', expectedRevokedToken401s);
    report('pg_admin_accounts_browser_errors_absent', true);
    report('pg_admin_accounts_settings_pass', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'browser resources did not all close cleanly');
  report('pg_admin_accounts_cleanup', true);
  setStage('complete');
}

main().catch(async (error) => {
  console.error(`stage: failed (${stage}); error type=${error?.name || 'unknown'}; detail=${JSON.stringify(safeFailureSummary(error))}; safe route statuses=${JSON.stringify(safeRouteStatuses)}; browser counters=${JSON.stringify({ pageErrors, consoleErrors, requestFailures, relayRequests, unexpectedHttpErrors })}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
