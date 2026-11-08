/*
 * WEB-PG-ADMIN-AUDIT-01: verify the existing Settings audit page against the
 * opt-in PostgreSQL runtime. The Python fixture owns the disposable schema,
 * seeded synthetic instance events, and server lifecycle.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_ADMIN_AUDIT_BASE_URL;
const USERNAME = process.env.ATERMIUS_PG_ADMIN_AUDIT_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_ADMIN_AUDIT_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_ADMIN_AUDIT_BOOTSTRAP_TOKEN;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RAW_RESOURCE_MARKER = 'pg-admin-audit-private-resource-marker';
const browserPersistenceNeedles = [PASSWORD, BOOTSTRAP_TOKEN].filter((value) =>
  typeof value === 'string' && value.length >= 16);
const sessionTokenNeedles = [];

let browser;
let context;
let page;
let stage = 'preflight';
let failureStage;
let pageErrors = 0;
let consoleErrors = 0;
const consoleErrorDetails = [];
let requestFailures = 0;
let relayRequests = 0;
const auditResponses = [];
const errorResponses = [];
const presenceResponses = [];
const adminJobResponses = [];
const adminBackupStatusResponses = [];
const adminOverviewResponses = [];
const adminInvitationResponses = [];
const adminVaultResponses = [];
const securityResponses = [];
let expectedOldPasswordLogin401 = false;

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

function rememberBrowserSecret(value, target = browserPersistenceNeedles) {
  if (typeof value === 'string' && value.length >= 16 && !target.includes(value)) target.push(value);
}

function sanitizeConsoleError(value) {
  let sanitized = value;
  for (const secret of browserPersistenceNeedles) {
    if (secret) sanitized = sanitized.split(secret).join('<redacted>');
  }
  for (const secret of sessionTokenNeedles) {
    if (secret) sanitized = sanitized.split(secret).join('<redacted>');
  }
  return sanitized
    .replace(/Bearer\s+\S+/gi, 'Bearer <redacted>')
    .replace(/https?:\/\/[^\s?#]+[?#][^\s]*/gi, '<url-with-query>')
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '<email>')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '<long-token>')
    .slice(0, 240);
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
  try {
    await locator.waitFor({ state: 'visible', timeout: 20000 });
  } catch (error) {
    const semantics = await page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
      .map((element) => ({
        label: element.getAttribute('aria-label'),
        role: element.getAttribute('role'),
        disabled: element.getAttribute('aria-disabled'),
      })).filter((entry) => /audit|next|previous|page|vault|quota|settings/i.test(`${entry.label || ''} ${entry.role || ''}`))
      .slice(-12)).catch(() => []);
    report('button_locator_diagnostics', JSON.stringify({
      requested: label,
      semantics,
      consoleErrors,
      consoleErrorDetails,
    }));
    throw error;
  }
  return locator;
}

async function fill(label, value) {
  const locator = await field(label);
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 60 });
    await page.waitForTimeout(200);
    if (!(await waitForStableFieldValue(locator, value)).matched) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if ((await waitForStableFieldValue(locator, value)).matched) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitForStableFieldValue(locator, value, timeoutMs = 1200) {
  const deadline = Date.now() + timeoutMs;
  let stableMatches = 0;
  while (Date.now() < deadline) {
    if ((await locator.inputValue()) === value) {
      stableMatches += 1;
      if (stableMatches >= 3) return { matched: true };
    } else {
      stableMatches = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { matched: false };
}

async function hasVisibleSemanticText(needle) {
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

function safeSecuritySummary(pathname, payload) {
  const accessToken = payload?.access_token;
  const refreshToken = payload?.refresh_token;
  if (typeof accessToken === 'string') rememberBrowserSecret(accessToken, sessionTokenNeedles);
  if (typeof refreshToken === 'string') rememberBrowserSecret(refreshToken, sessionTokenNeedles);
  rememberBrowserSecret(accessToken);
  rememberBrowserSecret(refreshToken);

  if (pathname === '/api/v1/auth/register' || pathname === '/api/v1/auth/login') {
    return {
      mfaRequired: payload?.mfa_required === true,
      sessionIssued: typeof accessToken === 'string' && typeof refreshToken === 'string',
    };
  }
  if (pathname === '/api/v1/auth/prelogin') {
    return {
      accountIdPresent: typeof payload?.account_id === 'string',
      kdfPresent: payload?.kdf !== null && typeof payload?.kdf === 'object',
    };
  }
  if (pathname === '/api/v1/auth/login/mfa') {
    return { sessionIssued: typeof accessToken === 'string' && typeof refreshToken === 'string' };
  }
  if (pathname === '/api/v1/auth/mfa/totp/setup') {
    rememberBrowserSecret(payload?.secret);
    rememberBrowserSecret(payload?.provisioning_uri);
    return {
      setupMaterialValid: /^[A-Z2-7]{32}$/.test(payload?.secret || '') &&
        typeof payload?.provisioning_uri === 'string' &&
        payload.provisioning_uri.includes(payload.secret),
    };
  }
  if (pathname === '/api/v1/auth/mfa/totp/confirm') {
    const codes = Array.isArray(payload?.recovery_codes) ? payload.recovery_codes : [];
    codes.forEach((code) => rememberBrowserSecret(code));
    return { recoveryCodeCount: codes.length };
  }
  if (pathname === '/api/v1/auth/mfa') {
    return {
      enabled: typeof payload?.enabled === 'boolean' ? payload.enabled : null,
      recoveryCodesRemaining: Number.isInteger(payload?.recovery_codes_remaining)
        ? payload.recovery_codes_remaining : null,
    };
  }
  if (pathname === '/api/v1/auth/password-change') return {
    changed: payload?.status === 'changed',
    sessionPreserved: payload?.session_preserved === true,
    otherSessionsRevoked: payload?.other_sessions_revoked === true,
  };
  if (pathname === '/api/v1/me') return { profileLoaded: payload !== null && typeof payload === 'object' };
  if (pathname === '/api/v1/auth/recovery/contexts') {
    return { recoveryContextsLoaded: payload !== null && typeof payload === 'object' };
  }
  return {};
}

async function waitForSecurityResponse(sequence, pathname, method, timeoutMs = 45000) {
  await waitFor(() => securityResponses.some((entry) => entry.sequence >= sequence &&
    entry.path === pathname && entry.method === method), timeoutMs);
  return securityResponses.find((entry) => entry.sequence >= sequence &&
    entry.path === pathname && entry.method === method);
}

async function readMfaEnrollment() {
  await page.getByText('Set up authenticator app', { exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  const material = await page.locator('flt-semantics').evaluateAll((elements) => {
    let secret = '';
    let uri = '';
    const values = [document.body.innerText, document.body.textContent];
    for (const element of elements) {
      values.push(element.innerText, element.textContent,
        element.getAttribute('aria-label'), element.getAttribute('aria-valuetext'));
    }
    for (const value of values) {
      if (typeof value !== 'string') continue;
      const compact = value.replace(/[\s\u200B-\u200D\uFEFF]/g, '');
      const seed = compact.match(/[A-Z2-7]{32}/g)?.at(-1);
      if (seed) secret = seed;
      const uriMatch = compact.match(/otpauth:\/\/totp\/[^\s]+/);
      if (uriMatch) uri = uriMatch[0];
    }
    return { secret, uri };
  });
  assertThat(/^[A-Z2-7]{32}$/.test(material.secret),
    'TOTP setup did not expose a valid transient seed');
  let provisioningUri;
  try { provisioningUri = new URL(material.uri); } catch (_) { /* Safe validation below. */ }
  assertThat(provisioningUri?.protocol === 'otpauth:' && provisioningUri.hostname === 'totp' &&
    provisioningUri.searchParams.get('secret') === material.secret,
  'TOTP provisioning URI did not match the setup seed');
  rememberBrowserSecret(material.secret);
  rememberBrowserSecret(material.uri);
  return material.secret;
}

function decodeBase32(value) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let buffer = 0;
  let bits = 0;
  const bytes = [];
  for (const character of value) {
    const decoded = alphabet.indexOf(character);
    if (decoded < 0) throw new Error('invalid test TOTP seed');
    buffer = (buffer << 5) | decoded;
    bits += 5;
    if (bits >= 8) { bits -= 8; bytes.push((buffer >> bits) & 255); }
  }
  const result = Buffer.from(bytes);
  if (result.length !== 20) throw new Error('invalid test TOTP seed length');
  return result;
}

function totpAtStep(secret, step) {
  const seed = decodeBase32(secret);
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = crypto.createHmac('sha1', seed).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary = ((digest[offset] & 0x7f) << 24) | (digest[offset + 1] << 16) |
    (digest[offset + 2] << 8) | digest[offset + 3];
  seed.fill(0);
  counter.fill(0);
  return String(binary % 1000000).padStart(6, '0');
}

function currentTotpStep() { return Math.floor(Date.now() / 1000 / 30); }

async function freshTotp(secret, afterStep = -1) {
  while (currentTotpStep() <= afterStep) {
    const remaining = 30000 - (Date.now() % 30000);
    await new Promise((resolve) => setTimeout(resolve, Math.min(remaining + 100, 1000)));
  }
  let step = currentTotpStep();
  const remaining = 30000 - (Date.now() % 30000);
  if (remaining < 4500) {
    await new Promise((resolve) => setTimeout(resolve, remaining + 300));
    step = currentTotpStep();
  }
  const code = totpAtStep(secret, step);
  rememberBrowserSecret(code);
  return { code, step };
}

async function readMfaRecoveryCodes() {
  await page.getByRole('checkbox', { name: 'I saved these codes securely', exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  const codes = await page.locator('flt-semantics').evaluateAll((elements) => {
    const foundCodes = new Set();
    const pattern = /[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}/g;
    for (const element of elements) {
      for (const value of [element.innerText, element.textContent,
        element.getAttribute('aria-label'), element.getAttribute('aria-valuetext')]) {
        if (typeof value !== 'string') continue;
        for (const match of value.matchAll(pattern)) foundCodes.add(match[0]);
      }
    }
    return [...foundCodes];
  });
  assertThat(codes.length === 10, 'MFA enrollment did not show ten unique recovery codes');
  codes.forEach((code) => rememberBrowserSecret(code));
  return codes;
}

async function inspectBrowserPersistence(needles) {
  return page.evaluate(async (values) => {
    const text = values.filter((value) => typeof value === 'string' && value.length >= 16);
    let matched = false;
    let failures = 0;
    const check = (value) => {
      if (typeof value === 'string' && text.some((needle) => value.includes(needle))) matched = true;
    };
    const visit = (value, seen = new WeakSet()) => {
      if (typeof value === 'string') { check(value); return; }
      if (!value || typeof value !== 'object' || seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) { for (const item of value) visit(item, seen); return; }
      for (const [key, item] of Object.entries(value)) { check(key); visit(item, seen); }
    };
    for (const storage of [localStorage, sessionStorage]) {
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        check(key || '');
        check(key ? storage.getItem(key) || '' : '');
      }
    }
    try {
      const databases = await indexedDB.databases();
      for (const info of databases) {
        if (!info.name) continue;
        const db = await new Promise((resolve, reject) => {
          const request = indexedDB.open(info.name);
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
          request.onblocked = () => reject(new Error('blocked'));
        });
        try {
          for (const store of Array.from(db.objectStoreNames)) {
            const rows = await new Promise((resolve, reject) => {
              const request = db.transaction(store, 'readonly').objectStore(store).getAll();
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            for (const row of rows) visit(row);
          }
        } finally { db.close(); }
      }
    } catch (_) { failures += 1; }
    return { matched, failures };
  }, needles);
}

function watchAuditResponses(targetPage) {
  targetPage.on('response', (response) => {
    let url;
    try {
      url = new URL(response.url());
    } catch (_) {
      return;
    }
    const responseRequest = response.request();
    const securityPaths = new Set([
      '/api/v1/auth/register', '/api/v1/auth/prelogin', '/api/v1/auth/login', '/api/v1/auth/login/mfa',
      '/api/v1/auth/password-change', '/api/v1/me', '/api/v1/auth/mfa',
      '/api/v1/auth/mfa/totp/setup', '/api/v1/auth/mfa/totp/confirm',
      '/api/v1/auth/recovery/contexts',
    ]);
    if (securityPaths.has(url.pathname)) {
      const payload = response.json().then((value) => safeSecuritySummary(url.pathname, value))
        .catch(() => ({}));
      securityResponses.push({
        sequence: securityResponses.length,
        method: responseRequest.method(),
        path: url.pathname,
        status: response.status(),
        hasBearer: /^Bearer\s+\S+$/i.test(responseRequest.headers().authorization || ''),
        payload,
      });
    }
    if (response.status() >= 400) {
      errorResponses.push({
        status: response.status(),
        path: url.pathname,
        method: responseRequest.method(),
        stage,
        expected: expectedOldPasswordLogin401 && responseRequest.method() === 'POST' &&
          url.pathname === '/api/v1/auth/login' && response.status() === 401,
        payload: response.json().catch(() => null),
      });
    }
    if (/^\/api\/v1\/vaults\/[^/]+\/presence$/.test(url.pathname)) {
      presenceResponses.push({ method: response.request().method(), status: response.status() });
    }
    if (url.pathname === '/api/v1/admin/jobs') {
      adminJobResponses.push({
        method: response.request().method(),
        status: response.status(),
        payload: response.json().catch(() => null),
      });
    }
    if (url.pathname === '/api/v1/admin/backup-status') {
      adminBackupStatusResponses.push({
        method: responseRequest.method(),
        status: response.status(),
        hasBearer: /^Bearer\s+\S+$/i.test(responseRequest.headers().authorization || ''),
        payload: response.json().catch(() => null),
      });
    }
    if (url.pathname === '/api/v1/admin/overview') {
      adminOverviewResponses.push({
        method: response.request().method(),
        status: response.status(),
        payload: response.json().catch(() => null),
      });
    }
    if (url.pathname === '/api/v1/admin/vaults' ||
        /^\/api\/v1\/admin\/vaults\/[^/]+\/quota$/.test(url.pathname)) {
      const request = response.request();
      adminVaultResponses.push({
        sequence: adminVaultResponses.length,
        method: request.method(),
        path: url.pathname,
        status: response.status(),
        hasBearer: /^Bearer\s+\S+$/i.test(request.headers().authorization || ''),
        payload: response.json().catch(() => null),
      });
    }
    if (url.pathname === '/api/v1/admin/account-invitations' ||
        /^\/api\/v1\/admin\/account-invitations\/[^/]+\/revoke$/.test(url.pathname)) {
      const request = response.request();
      adminInvitationResponses.push({
        sequence: adminInvitationResponses.length,
        method: request.method(),
        path: url.pathname,
        status: response.status(),
        hasBearer: /^Bearer\s+\S+$/i.test(request.headers().authorization || ''),
        payload: response.json().catch(() => null),
      });
    }
    if (url.pathname.startsWith('/api/v1/relay/')) relayRequests += 1;
    if (url.pathname !== '/api/v1/admin/audit') return;
    const request = response.request();
    auditResponses.push({
      sequence: auditResponses.length,
      status: response.status(),
      hasCursor: url.searchParams.has('cursor'),
      hasBearer: /^Bearer\s+\S+$/i.test(request.headers().authorization || ''),
      payload: response.json().catch(() => null),
    });
  });
}

async function waitForAuditResponse(sequence, hasCursor) {
  try {
    await waitFor(() => auditResponses.some((entry) =>
      entry.sequence >= sequence && entry.hasCursor === hasCursor));
  } catch (error) {
    report('audit_response_diagnostics', JSON.stringify({
      responseCount: auditResponses.length,
      expectedCursor: hasCursor,
      responses: auditResponses.map((entry) => ({
        status: entry.status,
        hasCursor: entry.hasCursor,
        hasBearer: entry.hasBearer,
      })),
      pageErrors,
      consoleErrors,
      requestFailures,
    }));
    throw error;
  }
  return auditResponses.find((entry) =>
    entry.sequence >= sequence && entry.hasCursor === hasCursor);
}

async function waitForInvitationResponse(sequence, method, revoke = false) {
  await waitFor(() => adminInvitationResponses.some((entry) =>
    entry.sequence >= sequence && entry.method === method &&
    (revoke ? entry.path.endsWith('/revoke') : entry.path === '/api/v1/admin/account-invitations')));
  return adminInvitationResponses.find((entry) =>
    entry.sequence >= sequence && entry.method === method &&
    (revoke ? entry.path.endsWith('/revoke') : entry.path === '/api/v1/admin/account-invitations'));
}

async function waitForAdminVaultResponse(sequence, method, quotaWrite = false) {
  try {
    await waitFor(() => adminVaultResponses.some((entry) =>
      entry.sequence >= sequence && entry.method === method &&
      (quotaWrite ? entry.path.endsWith('/quota') : entry.path === '/api/v1/admin/vaults')));
  } catch (error) {
    report('pg_admin_vault_response_diagnostics', JSON.stringify({
      expected: { sequence, method, quotaWrite },
      responses: adminVaultResponses.map((entry) => ({
        sequence: entry.sequence, method: entry.method, path: entry.path,
        status: entry.status, hasBearer: entry.hasBearer,
      })),
      errors: errorResponses.map((entry) => ({ status: entry.status, path: entry.path })),
      visibleText: await page.locator('body').innerText().catch(() => '').then((text) => text.slice(-900)),
    }));
    throw error;
  }
  return adminVaultResponses.find((entry) =>
    entry.sequence >= sequence && entry.method === method &&
    (quotaWrite ? entry.path.endsWith('/quota') : entry.path === '/api/v1/admin/vaults'));
}

function validateEvent(event) {
  const expectedFields = [
    'action', 'actor_device_id', 'actor_user_id', 'event_id', 'occurred_at',
    'resource_id', 'resource_type', 'result', 'scope', 'source',
  ].sort();
  return event && Object.keys(event).sort().join(',') === expectedFields.join(',') &&
    event.scope === 'instance' && event.action === 'admin.account_disabled' &&
    event.actor_device_id === null && event.actor_user_id === null &&
    event.resource_type === 'account' && event.result === 'success' &&
    event.source === 'api' && typeof event.occurred_at === 'string' &&
    /^\d+$/.test(event.event_id) && /^[0-9a-f]{64}$/.test(event.resource_id) &&
    event.resource_id !== RAW_RESOURCE_MARKER;
}

async function configureServer() {
  setStage('open Web Release from PostgreSQL-backed server');
  const response = await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  report('web_release_index_status', response?.status() ?? 0);
  report('web_release_index_html', (response?.headers()['content-type'] || '').includes('text/html'));
  const assetStatuses = await Promise.all(['main.dart.js', 'drift_worker.js', 'sqlite3.wasm'].map(async (asset) => {
    const assetResponse = await page.request.get(`${BASE_URL}/${asset}`, { timeout: 10000 }).catch(() => null);
    return assetResponse?.status() ?? 0;
  }));
  report('web_release_asset_statuses', assetStatuses.join(','));
  setStage('wait for Flutter Web runtime');
  try {
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  } catch (error) {
    const diagnostics = await page.evaluate(() => ({
      bodyLength: document.body?.innerText?.length || 0,
      hasPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      hasMainScript: [...document.scripts].some((script) => script.src.includes('main.dart.js')),
      sodiumReady: typeof window.sodium?.ready?.then === 'function',
    })).catch(() => ({ bodyLength: -1, hasPlaceholder: false, hasMainScript: false, sodiumReady: false }));
    console.log(`assert: flutter_runtime_diagnostics=${JSON.stringify({
      ...diagnostics,
      pageErrors,
      consoleErrors,
      requestFailures,
    })}`);
    throw error;
  }
  await page.evaluate(async () => { await window.sodium.ready; });
  setStage('select server workspace mode');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
  setStage('enter PostgreSQL server URL');
  await fill('Server URL', BASE_URL);
  setStage('connect securely to PostgreSQL server');
  await (await button('Connect securely')).click();
}

async function registerAllowlistedAdmin() {
  setStage('connect Web client to PostgreSQL-backed server');
  await configureServer();
  setStage('wait for first-owner registration form');
  await field('Owner email');
  setStage('fill allowlisted administrator identity');
  await fill('Owner email', USERNAME);
  setStage('fill administrator master password');
  await fill('Master password · 12+ characters', PASSWORD);
  setStage('confirm administrator master password');
  await fill('Confirm master password', PASSWORD);
  setStage('enter one-time bootstrap token');
  await fill('One-time bootstrap token', BOOTSTRAP_TOKEN);
  setStage('name administrator device');
  await fill('Device name', 'PostgreSQL admin audit acceptance');
  setStage('name administrator Vault');
  await fill('First Vault', 'PostgreSQL admin audit acceptance');
  setStage('register allowlisted administrator through Web UI');
  await (await button('Create owner account')).click();
  await button('Add host');
  report('admin_registration_in_web', true);
}

async function validatePage(entry, expectedLength, hasMore, hasCursor) {
  const payload = await entry.payload;
  const ids = Array.isArray(payload?.events)
    ? payload.events.map((event) => Number(event.event_id)) : [];
  const ascending = ids.every((eventId, index) => index === 0 || ids[index - 1] < eventId);
  const exact = entry.status === 200 && entry.hasCursor === hasCursor && entry.hasBearer &&
    Object.keys(payload || {}).sort().join(',') === 'events,has_more,next_cursor' &&
    payload.events.length === expectedLength && payload.has_more === hasMore &&
    (hasMore ? typeof payload.next_cursor === 'string' : payload.next_cursor === null) &&
    ascending && payload.events.every(validateEvent) &&
    !JSON.stringify(payload).includes(RAW_RESOURCE_MARKER);
  return { payload, exact };
}

async function reportPageDiagnostics(name, entry, validated) {
  const payload = validated.payload;
  report(name, JSON.stringify({
    status: entry.status,
    hasBearer: entry.hasBearer,
    payloadKeys: Object.keys(payload || {}).sort(),
    errorCode: typeof payload?.error === 'string' ? payload.error : null,
    eventCount: Array.isArray(payload?.events) ? payload.events.length : null,
    hasMore: typeof payload?.has_more === 'boolean' ? payload.has_more : null,
    nextCursorType: typeof payload?.next_cursor,
    exact: validated.exact,
  }));
}

async function main() {
  assertThat(BASE_URL && USERNAME && PASSWORD && BOOTSTRAP_TOKEN,
    'PG browser acceptance environment is incomplete');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
    'current Flutter Web release bundle is missing');
  const bundleSha256 = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');
  let pgBackupStatusPass = false;

  try {
    setStage('launch isolated Chromium context');
    const options = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(options);
    context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await context.route('**/favicon.ico', (route) => route.fulfill({
      status: 204,
      headers: { 'cache-control': 'no-store' },
    }));
    page = await context.newPage();
    page.on('pageerror', () => { pageErrors += 1; });
    page.on('console', (message) => {
      if (message.type() === 'error') {
        consoleErrors += 1;
        if (consoleErrorDetails.length < 6) {
          consoleErrorDetails.push(sanitizeConsoleError(message.text()));
        }
      }
    });
    page.on('requestfailed', () => { requestFailures += 1; });
    watchAuditResponses(page);

    await registerAllowlistedAdmin();
    setStage('open Settings and verify PostgreSQL admin audit card');
    await (await button('Settings')).click();
    await waitFor(() => hasVisibleSemanticText('Instance admin audit'));
    assertThat(await hasVisibleSemanticText('Instance admin audit'),
      'allowlisted administrator did not see the instance audit card');
    setStage('load shared PostgreSQL backup status in Settings');
    await waitFor(() => hasVisibleSemanticText('Instance backup status'));
    const backupStatusStart = adminBackupStatusResponses.length;
    await (await button('Load backup status')).click();
    await waitFor(() => adminBackupStatusResponses.length > backupStatusStart);
    const backupStatusResponse = adminBackupStatusResponses.at(-1);
    const backupStatusPayload = await backupStatusResponse.payload;
    pgBackupStatusPass = backupStatusResponse.method === 'GET' &&
      backupStatusResponse.status === 200 && backupStatusResponse.hasBearer &&
      Object.keys(backupStatusPayload || {}).sort().join(',') === 'last_attempt,operation' &&
      backupStatusPayload.operation === 'backup' && backupStatusPayload.last_attempt === null;
    assertThat(pgBackupStatusPass,
      'PostgreSQL Settings did not read the empty backup status through the authenticated shared route');
    await waitFor(() => hasVisibleSemanticText('No CLI or server-triggered backup attempt recorded.'));
    report('pg_admin_backup_status_web_pass', true);
    report('pg_admin_backup_status_responses', JSON.stringify({
      method: backupStatusResponse.method,
      status: backupStatusResponse.status,
      hasBearer: backupStatusResponse.hasBearer,
      payload: backupStatusPayload,
    }));
    if (process.env.ATERMIUS_PG_ADMIN_AUDIT_STATUS_ONLY === '1') {
      const persistenceResult = await inspectBrowserPersistence(browserPersistenceNeedles);
      const pageClean = pageErrors === 0 && consoleErrors === 0 && requestFailures === 0 &&
        relayRequests === 0 && persistenceResult.failures === 0 && !persistenceResult.matched;
      report('pg_admin_backup_status_browser_secrets_absent',
        !persistenceResult.matched && persistenceResult.failures === 0);
      report('page_errors', pageErrors);
      report('console_errors', consoleErrors);
      report('request_failures', requestFailures);
      report('relay_requests', relayRequests);
      report('web_release_bundle_path', path.relative(ROOT, path.join(WEB_ROOT, 'main.dart.js')));
      report('web_release_sha256', bundleSha256);
      assertThat(pageClean, 'PostgreSQL backup-status browser flow had an unexpected error or persisted secret');
      return;
    }
    setStage('load PostgreSQL instance overview from Settings');
    let overviewRequestStart = adminOverviewResponses.length;
    await (await button('Load overview')).click();
    await waitFor(() => adminOverviewResponses.length > overviewRequestStart);
    await waitFor(() => hasVisibleSemanticText('Accounts'));
    report('pg_admin_overview_rendered', true);
    setStage('load first PostgreSQL instance audit page');
    let requestStart = auditResponses.length;
    await (await button('Load admin audit')).click();
    let response = await waitForAuditResponse(requestStart, false);
    let validated = await validatePage(response, 100, true, false);
    report('first_page_shape_diagnostics', JSON.stringify({
      status: response.status,
      hasBearer: response.hasBearer,
      payloadKeys: Object.keys(validated.payload || {}).sort(),
      eventCount: validated.payload?.events?.length ?? null,
      hasMore: validated.payload?.has_more ?? null,
      nextCursorType: typeof validated.payload?.next_cursor,
      eventKeys: Object.keys(validated.payload?.events?.[0] || {}).sort(),
      action: validated.payload?.events?.[0]?.action,
      scope: validated.payload?.events?.[0]?.scope,
      source: validated.payload?.events?.[0]?.source,
      ascendingEventIds: validated.payload?.events?.every((event, index, events) =>
        index === 0 || Number(events[index - 1].event_id) < Number(event.event_id)) ?? false,
      allEventDtosValid: validated.payload?.events?.every(validateEvent) ?? false,
      hmacShape: /^[0-9a-f]{64}$/.test(validated.payload?.events?.[0]?.resource_id || ''),
      privateMarkerAbsent: !JSON.stringify(validated.payload || {}).includes(RAW_RESOURCE_MARKER),
    }));
    assertThat(validated.exact, 'PostgreSQL audit first page had an invalid DTO or cursor shape');
    report('pg_admin_audit_first_page', `${response.status};100;has_more`);
    setStage('verify first-page Settings pagination label');
    await waitFor(() => hasVisibleSemanticText('Page 1'));
    report('pg_admin_audit_page_one_rendered', true);
    setStage('verify localized Settings audit action');
    await waitFor(() => hasVisibleSemanticText('管理员已停用账户'));
    assertThat(await hasVisibleSemanticText('admin.account_disabled') === false,
      'Settings rendered an untranslated PostgreSQL admin action key');
    assertThat(await hasVisibleSemanticText(RAW_RESOURCE_MARKER) === false,
      'Settings exposed a raw PostgreSQL audit resource marker');
    report('pg_admin_audit_action_localized', true);
    report('pg_admin_audit_resource_hmac_only', true);

    setStage('advance to final PostgreSQL audit cursor page');
    requestStart = auditResponses.length;
    await (await button('Next')).click();
    response = await waitForAuditResponse(requestStart, true);
    validated = await validatePage(response, 1, false, true);
    await reportPageDiagnostics('cursor_page_shape_diagnostics', response, validated);
    assertThat(validated.exact, 'PostgreSQL audit cursor page had an invalid DTO shape');
    await waitFor(() => hasVisibleSemanticText('Page 2'));
    report('pg_admin_audit_cursor_page', `${response.status};1;final`);

    setStage('return to first PostgreSQL audit page');
    requestStart = auditResponses.length;
    await (await button('Previous')).click();
    response = await waitForAuditResponse(requestStart, false);
    validated = await validatePage(response, 100, true, false);
    await reportPageDiagnostics('previous_page_shape_diagnostics', response, validated);
    assertThat(validated.exact, 'PostgreSQL audit Previous did not restore the first page');
    await waitFor(() => hasVisibleSemanticText('Page 1'));
    report('pg_admin_audit_previous_page', response.status);

    setStage('wait for PostgreSQL Vault quota Settings card');
    await waitFor(() => hasVisibleSemanticText('Instance Vault quotas'));
    setStage('click Load Vaults in PostgreSQL Settings');
    let vaultStart = adminVaultResponses.length;
    await (await button('Load Vaults')).click();
    setStage('validate PostgreSQL Vault quota inventory response');
    let vaultResponse = await waitForAdminVaultResponse(vaultStart, 'GET');
    const initialVaultPage = await vaultResponse.payload;
    assertThat(vaultResponse.status === 200 && vaultResponse.hasBearer &&
      Object.keys(initialVaultPage || {}).sort().join(',') === 'limit,offset,total,vaults' &&
      initialVaultPage.limit === 50 && initialVaultPage.offset === 0 &&
      Array.isArray(initialVaultPage.vaults) && initialVaultPage.total >= 1 &&
      initialVaultPage.vaults.every((vault) =>
        Object.keys(vault).sort().join(',') ===
          'created_at,owner_user_id,owner_username,quota_bytes,reserved_upload_bytes,state,stored_bytes,vault_id') &&
      !JSON.stringify(initialVaultPage).toLowerCase().includes('envelope') &&
      !JSON.stringify(initialVaultPage).toLowerCase().includes('ciphertext'),
    'PG Settings Vault inventory did not return the safe bounded DTO');
    const adminVault = initialVaultPage.vaults.find((vault) => vault.owner_username === USERNAME);
    assertThat(adminVault && adminVault.state === 'active' &&
      Number.isSafeInteger(adminVault.quota_bytes) && adminVault.quota_bytes > 0 &&
      Number.isSafeInteger(adminVault.stored_bytes) && Number.isSafeInteger(adminVault.reserved_upload_bytes),
    'PG Settings Vault inventory omitted the allowlisted admin Vault or storage counters');
    // Flutter's semantics tree may expose the row's actions before every text
    // node is individually discoverable by Playwright. Waiting for the action
    // we are about to use verifies that the parsed Vault row was rendered.
    await waitFor(() => hasVisibleSemanticText('Edit quota'));
    setStage('open PostgreSQL Vault quota editor');
    await (await button('Edit quota')).click();
    await waitFor(() => hasVisibleSemanticText('Edit Vault quota'));
    const requestedQuota = String(adminVault.quota_bytes + (1 << 30));
    await fill('Quota in bytes', requestedQuota);
    setStage('save PostgreSQL Vault quota through Settings');
    vaultStart = adminVaultResponses.length;
    await (await button('Save quota')).click();
    vaultResponse = await waitForAdminVaultResponse(vaultStart, 'PUT', true);
    const quotaReceipt = await vaultResponse.payload;
    assertThat(vaultResponse.status === 200 && vaultResponse.hasBearer &&
      Object.keys(quotaReceipt || {}).sort().join(',') ===
        'quota_bytes,reserved_upload_bytes,stored_bytes,updated_at,vault_id' &&
      quotaReceipt.vault_id === adminVault.vault_id &&
      quotaReceipt.quota_bytes === Number(requestedQuota) &&
      quotaReceipt.stored_bytes === adminVault.stored_bytes &&
      quotaReceipt.reserved_upload_bytes === adminVault.reserved_upload_bytes &&
      Number.isFinite(Date.parse(quotaReceipt.updated_at)),
    'PG Settings quota editor did not receive the exact quota receipt');
    setStage('verify PostgreSQL quota refresh in Settings');
    vaultResponse = await waitForAdminVaultResponse(vaultStart, 'GET');
    const refreshedVaultPage = await vaultResponse.payload;
    const refreshedAdminVault = refreshedVaultPage?.vaults?.find((vault) =>
      vault.vault_id === adminVault.vault_id);
    assertThat(vaultResponse.status === 200 && vaultResponse.hasBearer &&
      refreshedAdminVault?.quota_bytes === Number(requestedQuota),
    'PG Settings did not refresh the saved Vault quota');
    report('pg_admin_vault_quota_ui', 'list;edit;refresh;safe-dto');

    setStage('load PostgreSQL account invitations in Settings');
    await waitFor(() => hasVisibleSemanticText('Account invitations'));
    let invitationStart = adminInvitationResponses.length;
    await (await button('Load account invitations')).click();
    let invitationResponse = await waitForInvitationResponse(invitationStart, 'GET');
    const initialInvitationPage = await invitationResponse.payload;
    assertThat(invitationResponse.status === 200 && invitationResponse.hasBearer &&
      Object.keys(initialInvitationPage || {}).sort().join(',') === 'invitations,limit,offset,total' &&
      Array.isArray(initialInvitationPage.invitations) && initialInvitationPage.total === 0,
    'PG account invitation list did not load an empty safe page');
    report('pg_admin_invitation_list', '200;empty;safe-dto');

    const invitationUsername = `pg-admin-ui-${crypto.randomUUID()}@example.test`;
    await (await button('Issue account invitation')).click();
    await fill('Invitation username', invitationUsername);
    invitationStart = adminInvitationResponses.length;
    await (await button('Create invitation')).click();
    invitationResponse = await waitForInvitationResponse(invitationStart, 'POST');
    const issuePayload = await invitationResponse.payload;
    const issue = issuePayload?.invitation;
    assertThat(invitationResponse.status === 201 && invitationResponse.hasBearer &&
      Object.keys(issue || {}).sort().join(',') === 'created_at,expires_at,invitation_id,token,username' &&
      issue.username === invitationUsername && /^[A-Za-z0-9_-]{43}$/.test(issue.token) &&
      Date.parse(issue.expires_at) > Date.parse(issue.created_at),
    'PG Settings invitation creation receipt was invalid');
    let invitationToken = issue.token;
    await waitFor(() => hasVisibleSemanticText('One-time invitation token') &&
      hasVisibleSemanticText(invitationToken));
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE_URL });
    await (await button('Copy invitation token')).click();
    await waitFor(() => hasVisibleSemanticText('Invitation token copied.'));
    let copiedInvitationToken = await page.evaluate(() => navigator.clipboard.readText());
    assertThat(copiedInvitationToken === invitationToken,
      'PG Settings did not copy the one-time invitation token');
    await page.evaluate(() => navigator.clipboard.writeText(''));
    copiedInvitationToken = '';
    await (await button('Done')).click();
    const invitationStorage = await page.evaluate(() => JSON.stringify({
      local: Object.entries(localStorage),
      session: Object.entries(sessionStorage),
    }));
    assertThat(!invitationStorage.includes(invitationToken),
      'PG invitation token was persisted in browser storage');
    report('pg_admin_invitation_one_time_copy_clear', true);

    invitationStart = adminInvitationResponses.length;
    await (await button('Refresh account invitations')).click();
    invitationResponse = await waitForInvitationResponse(invitationStart, 'GET');
    const pendingPage = await invitationResponse.payload;
    const pendingRows = pendingPage?.invitations;
    assertThat(invitationResponse.status === 200 && invitationResponse.hasBearer &&
      Object.keys(pendingPage || {}).sort().join(',') === 'invitations,limit,offset,total' &&
      pendingPage.total === 1 && pendingRows?.length === 1 &&
      Object.keys(pendingRows[0]).sort().join(',') === 'created_at,expires_at,invitation_id,status,username' &&
      pendingRows[0].invitation_id === issue.invitation_id &&
      pendingRows[0].username === invitationUsername && pendingRows[0].status === 'pending' &&
      !JSON.stringify(pendingPage).includes(invitationToken),
    'PG invitation refresh did not return the safe pending row');
    await waitFor(() => hasVisibleSemanticText(invitationUsername) &&
      hasVisibleSemanticText('Pending'));
    await (await button('Revoke invitation')).click();
    await waitFor(() => hasVisibleSemanticText('Revoke account invitation?'));
    invitationStart = adminInvitationResponses.length;
    await (await button('Confirm revoke invitation')).click();
    invitationResponse = await waitForInvitationResponse(invitationStart, 'POST', true);
    const revokeReceipt = await invitationResponse.payload;
    assertThat(invitationResponse.status === 200 && invitationResponse.hasBearer &&
      Object.keys(revokeReceipt || {}).sort().join(',') === 'invitation_id,revoked_at,status' &&
      revokeReceipt.invitation_id === issue.invitation_id && revokeReceipt.status === 'revoked' &&
      Number.isFinite(Date.parse(revokeReceipt.revoked_at)),
    'PG Settings invitation revoke receipt was invalid');
    invitationStart = adminInvitationResponses.length;
    await (await button('Refresh account invitations')).click();
    invitationResponse = await waitForInvitationResponse(invitationStart, 'GET');
    const revokedPage = await invitationResponse.payload;
    assertThat(invitationResponse.status === 200 && revokedPage.total === 1 &&
      revokedPage.invitations[0].invitation_id === issue.invitation_id &&
      revokedPage.invitations[0].status === 'revoked',
    'PG Settings did not refresh to the revoked invitation state');
    await waitFor(() => hasVisibleSemanticText('Revoked'));
    report('pg_invite_issue_revoke', true);
    invitationToken = '';
    issue.token = '';
    issuePayload.invitation.token = '';

    setStage('wait for PostgreSQL account sync to become idle');
    await waitFor(async () =>
      !(await hasVisibleSemanticText('Syncing')) &&
      !(await hasVisibleSemanticText('Rebuilding snapshot')), 60000);
    report('pg_security_prechange_sync_quiescent', true);
    const changedPassword = `Changed-${crypto.randomBytes(32).toString('base64url')}`;
    rememberBrowserSecret(changedPassword);
    setStage('enter current password in PostgreSQL Settings');
    await fill('Current master password', PASSWORD);
    setStage('enter replacement password in PostgreSQL Settings');
    await fill('New master password', changedPassword);
    await fill('Confirm new master password', changedPassword);
    let securityStart = securityResponses.length;
    const changePasswordButton = await button('Change master password');
    const changePasswordEnabled = await changePasswordButton.isEnabled();
    report('pg_security_password_change_button_enabled', changePasswordEnabled);
    assertThat(changePasswordEnabled, 'password change form did not enable its submit control');
    setStage('submit PostgreSQL owner master password change');
    // Flutter Web can place this card below the viewport after Settings
    // pagination. Submit once and inspect the form state before waiting for
    // the prelogin response; a failed validation must not trigger duplicate
    // password-change attempts.
    await changePasswordButton.scrollIntoViewIfNeeded();
    await changePasswordButton.click();
    const passwordFormSubmitObserved = async () => {
      const preloginStarted = securityResponses.some((entry) =>
        entry.sequence >= securityStart && entry.method === 'POST' &&
        entry.path === '/api/v1/auth/prelogin');
      if (preloginStarted) return true;
      return page.evaluate(() => {
        const labels = [
          'Current master password',
          'New master password',
          'Confirm new master password',
        ];
        const fields = labels.map((label) =>
          document.querySelector(`input[aria-label*=${JSON.stringify(label)}]`));
        return fields.length === 3 && fields.every((field) => field && field.value === '');
      });
    };
    const submitObserved = await waitFor(passwordFormSubmitObserved, 2500)
      .then(() => true)
      .catch(() => false);
    report('pg_security_password_change_form_submit_observed', submitObserved);
    setStage('wait for PostgreSQL password-change prelogin');
    let passwordPrelogin;
    try {
      passwordPrelogin = await waitForSecurityResponse(
        securityStart, '/api/v1/auth/prelogin', 'POST');
    } catch (error) {
      const diagnostics = await page.evaluate(() => ({
        visibleText: [...document.querySelectorAll('flt-semantics')]
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
              style.visibility !== 'hidden' && Number(style.opacity) !== 0;
          })
          .map((element) => element.getAttribute('aria-label') || element.textContent || '')
          .filter((text) => text && /password|sync|snapshot|error|current master|change master/i.test(text))
          .join('\n').slice(-1800),
        passwordFieldLengths: [...document.querySelectorAll('input')]
          .filter((element) => /password/i.test(element.getAttribute('aria-label') || ''))
          .map((element) => (element.value || '').length),
        passwordButtons: [...document.querySelectorAll('button,[role="button"],flt-semantics')]
          .filter((element) => /change master password/i.test(
            `${element.getAttribute('aria-label') || ''} ${element.textContent || ''}`))
          .map((element) => ({
            tag: element.tagName.toLowerCase(),
            role: element.getAttribute('role'),
            label: element.getAttribute('aria-label'),
            disabled: element.getAttribute('aria-disabled'),
            rect: (() => { const r = element.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })(),
          })),
      })).catch(() => ({ visibleText: '<unavailable>', securityResponses: [], errorResponses: [] }));
      report('pg_security_prelogin_wait_diagnostics', JSON.stringify({
        ...diagnostics,
        securityResponses: securityResponses.map((entry) => ({
          sequence: entry.sequence, method: entry.method, path: entry.path, status: entry.status,
        })),
        errorResponses: errorResponses.map((entry) => ({
          method: entry.method, path: entry.path, status: entry.status, stage: entry.stage,
        })),
        visibleText: sanitizeConsoleError(diagnostics.visibleText),
        passwordButtonEnabled: await changePasswordButton.isEnabled().catch(() => false),
      }));
      throw error;
    }
    const passwordPreloginSummary = await passwordPrelogin.payload;
    assertThat(passwordPrelogin.status === 200 && !passwordPrelogin.hasBearer &&
      passwordPreloginSummary.accountIdPresent === true && passwordPreloginSummary.kdfPresent === true,
    'password change did not retrieve its safe prelogin KDF parameters');
    report('pg_security_password_change_prelogin', '200;safe-kdf');
    setStage('wait for PostgreSQL password change response');
    const passwordChange = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/password-change', 'POST', 120000);
    const passwordChangeSummary = await passwordChange.payload;
    assertThat(passwordChange.status === 200 && passwordChange.hasBearer &&
      passwordChangeSummary.changed === true && passwordChangeSummary.sessionPreserved === true &&
      passwordChangeSummary.otherSessionsRevoked === true,
    'PG Settings password change did not use the current authenticated session');
    const profileAfterChange = await waitForSecurityResponse(
      passwordChange.sequence + 1, '/api/v1/me', 'GET');
    assertThat(profileAfterChange.status === 200 && profileAfterChange.hasBearer,
      'PG account session did not remain valid after password change');
    report('pg_security_password_change', true);

    setStage('lock the account before checking old password rejection');
    await (await button('Lock and sign out')).click();
    await field('Email or username');
    await fill('Email or username', USERNAME);
    await fill('Master password', PASSWORD);
    securityStart = securityResponses.length;
    expectedOldPasswordLogin401 = true;
    let oldPasswordLogin;
    try {
      await (await button('Sign in and unlock')).click();
      oldPasswordLogin = await waitForSecurityResponse(
        securityStart, '/api/v1/auth/login', 'POST');
    } finally {
      expectedOldPasswordLogin401 = false;
    }
    const oldPasswordSummary = await oldPasswordLogin?.payload;
    const oldPasswordError = errorResponses.find((entry) => entry.expected);
    const oldPasswordErrorCode = (await oldPasswordError?.payload)?.error?.code ?? null;
    assertThat(oldPasswordLogin?.status === 401 && !oldPasswordLogin.hasBearer &&
      oldPasswordSummary?.sessionIssued !== true && oldPasswordErrorCode === 'AUTH_REQUIRED',
    'old master password was not rejected without issuing a session');
    report('pg_security_old_password_denied', true);
    report('pg_security_expected_old_login_401', true);
    report('pg_security_old_password_response', '401;AUTH_REQUIRED');

    setStage('unlock PostgreSQL account with the changed master password');
    await fill('Master password', changedPassword);
    securityStart = securityResponses.length;
    await (await button('Sign in and unlock')).click();
    const changedPasswordLogin = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/login', 'POST');
    const changedPasswordSummary = await changedPasswordLogin.payload;
    assertThat(changedPasswordLogin.status === 200 && !changedPasswordLogin.hasBearer &&
      changedPasswordSummary.sessionIssued === true && changedPasswordSummary.mfaRequired === false,
    'changed master password did not unlock the account before MFA enrollment');
    await (await button('Add host')).waitFor({ state: 'visible', timeout: 30000 });
    const recoveryContexts = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/recovery/contexts', 'GET');
    const recoveryContextsSummary = await recoveryContexts.payload;
    assertThat(recoveryContexts.status === 200 && recoveryContexts.hasBearer &&
      recoveryContextsSummary.recoveryContextsLoaded === true,
    'account recovery state did not finish refreshing before the next sign-out');
    report('pg_security_recovery_contexts_loaded', true);
    report('pg_security_new_password_unlock', true);

    setStage('enroll TOTP MFA through PostgreSQL-backed Settings');
    await (await button('Settings')).click();
    await (await button('Set up authenticator')).click();
    await fill('Current master password', changedPassword);
    await (await button('Continue')).click();
    securityStart = securityResponses.length;
    const totpSetup = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/mfa/totp/setup', 'POST');
    const totpSetupSummary = await totpSetup.payload;
    assertThat(totpSetup.status === 200 && totpSetup.hasBearer &&
      totpSetupSummary.setupMaterialValid === true,
    'PostgreSQL TOTP setup did not return valid enrollment material');
    const totpSeed = await readMfaEnrollment();
    const enrollmentProof = await freshTotp(totpSeed);
    await fill('Authenticator code', enrollmentProof.code);
    securityStart = securityResponses.length;
    await (await button('Verify and enable')).click();
    const totpConfirmed = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/mfa/totp/confirm', 'POST');
    const totpConfirmSummary = await totpConfirmed.payload;
    assertThat(totpConfirmed.status === 200 && totpConfirmed.hasBearer &&
      totpConfirmSummary.recoveryCodeCount === 10,
    'PostgreSQL TOTP confirmation did not issue ten one-time recovery codes');
    const recoveryCodes = await readMfaRecoveryCodes();
    assertThat(recoveryCodes.length === totpConfirmSummary.recoveryCodeCount,
      'recovery-code dialog did not match the safe server count');
    const savedCodes = page.getByRole('checkbox', {
      name: 'I saved these codes securely', exact: true,
    });
    await savedCodes.click();
    await waitFor(async () => (await savedCodes.getAttribute('aria-checked')) === 'true', 5000);
    await (await button('Finish')).click();
    await (await button('Disable MFA')).waitFor({ state: 'visible', timeout: 15000 });
    report('pg_security_totp_enrollment', true);
    report('pg_security_recovery_code_count', recoveryCodes.length);

    setStage('lock and verify password-only login requires TOTP');
    await (await button('Lock and sign out')).click();
    await field('Email or username');
    await fill('Email or username', USERNAME);
    await fill('Master password', changedPassword);
    securityStart = securityResponses.length;
    await (await button('Sign in and unlock')).click();
    const passwordOnlyLogin = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/login', 'POST');
    const passwordOnlySummary = await passwordOnlyLogin.payload;
    assertThat(passwordOnlyLogin.status === 202 && !passwordOnlyLogin.hasBearer &&
      passwordOnlySummary.mfaRequired === true && passwordOnlySummary.sessionIssued === false,
    'password-only login did not stop at the MFA challenge without a session');
    report('pg_security_password_only_login_requires_mfa', true);

    const authenticatorToggle = page.getByRole('button', {
      name: 'Use authenticator code', exact: true,
    });
    if (await authenticatorToggle.count()) await authenticatorToggle.click();
    const loginProof = await freshTotp(totpSeed, enrollmentProof.step);
    await fill('Authenticator code', loginProof.code);
    securityStart = securityResponses.length;
    await (await button('Verify and unlock')).click();
    const totpLogin = await waitForSecurityResponse(
      securityStart, '/api/v1/auth/login/mfa', 'POST');
    const totpLoginSummary = await totpLogin.payload;
    assertThat(totpLogin.status === 200 && !totpLogin.hasBearer &&
      totpLoginSummary.sessionIssued === true,
    'valid TOTP proof did not issue a login session');
    await (await button('Add host')).waitFor({ state: 'visible', timeout: 30000 });
    report('pg_security_totp_login_unlock', true);

    await Promise.all(securityResponses.map((entry) => entry.payload));
    assertThat(sessionTokenNeedles.length >= 4,
      'Web auth responses did not provide access and refresh token values for the persistence check');
    const persistenceResult = await inspectBrowserPersistence(browserPersistenceNeedles);
    const pgSecurityPersistencePass = !persistenceResult.matched && persistenceResult.failures === 0;
    report('pg_security_session_token_needles_scanned', sessionTokenNeedles.length);
    report('pg_security_persistent_secrets_absent', pgSecurityPersistencePass);
    report('pg_security_persistence_scan', JSON.stringify({
      browserStores: 'localStorage;sessionStorage;indexedDB',
      matchedSecret: persistenceResult.matched,
      scanFailures: persistenceResult.failures,
    }));
    assertThat(pgSecurityPersistencePass,
      'password, TOTP enrollment material, recovery codes, or session tokens appeared in browser persistence');

    const expectedOldPasswordErrors = await Promise.all(errorResponses.filter((entry) => entry.expected)
      .map(async (entry) => ({ ...entry, code: (await entry.payload)?.error?.code ?? null })));
    assertThat(expectedOldPasswordErrors.length === 1 &&
      expectedOldPasswordErrors[0].status === 401 &&
      expectedOldPasswordErrors[0].method === 'POST' &&
      expectedOldPasswordErrors[0].path === '/api/v1/auth/login' &&
      expectedOldPasswordErrors[0].code === 'AUTH_REQUIRED',
    'expected old-password 401 was not classified as the single intentional security rejection');
    const httpErrors = await Promise.all(errorResponses.filter((entry) => !entry.expected).map(async (entry) => ({
      status: entry.status,
      path: entry.path,
      method: entry.method,
      stage: entry.stage,
      code: (await entry.payload)?.error?.code ?? null,
    })));
    const securitySummaryResponses = await Promise.all(securityResponses.map(async (entry) => ({
      method: entry.method,
      path: entry.path,
      status: entry.status,
      hasBearer: entry.hasBearer,
      summary: await entry.payload,
    })));
    const presenceErrors = httpErrors.filter((entry) =>
      /^\/api\/v1\/vaults\/[0-9a-f-]{36}\/presence$/i.test(entry.path));
    const expectedOldPasswordConsoleErrors = expectedOldPasswordErrors.length === 1 &&
      consoleErrorDetails.some((detail) =>
        detail === 'Failed to load resource: the server responded with a status of 401 (Unauthorized)')
      ? 1 : 0;
    const unexpectedConsoleErrors = consoleErrors - expectedOldPasswordConsoleErrors;
    const pgAdminJobsPass = adminJobResponses.length > 0 &&
      adminJobResponses.every((entry) => entry.status === 200 && entry.method === 'GET') &&
      (await Promise.all(adminJobResponses.map(async (entry) => entry.payload))).some((payload) =>
        payload?.jobs?.length === 0 && payload.total === 0 &&
        JSON.stringify(payload.supported_actions) ===
          JSON.stringify(['maintenance', 'backup_status', 'backup_schedule']));
    const pgAdminOverviewPass = adminOverviewResponses.length > 0 &&
      adminOverviewResponses.every((entry) => entry.status === 200 && entry.method === 'GET') &&
      (await Promise.all(adminOverviewResponses.map(async (entry) => entry.payload))).some((payload) => {
        const expectedCounts = [
          'accounts_active', 'accounts_deleting', 'accounts_disabled', 'accounts_total',
          'devices_active', 'reserved_upload_bytes', 'stored_bytes', 'vault_quota_bytes',
          'vaults_active', 'vaults_deleting',
        ];
        const countKeys = Object.keys(payload?.counts || {}).sort();
        return Object.keys(payload || {}).sort().join(',') === 'counts,generated_at,instance,relay' &&
          Object.keys(payload.instance || {}).sort().join(',') ===
            'generation,instance_id,protocol_version,server_space_id' &&
          payload.instance.protocol_version === 1 &&
          countKeys.join(',') === expectedCounts.join(',') &&
          Object.values(payload.counts).every((value) => Number.isSafeInteger(value) && value >= 0) &&
          Object.keys(payload.relay || {}).sort().join(',') ===
            'allow_cidrs,allow_ports,enabled,max_connections_per_user' &&
          payload.relay.enabled === false && payload.relay.allow_cidrs.length === 0 &&
          payload.relay.allow_ports.length === 0 &&
          Number.isSafeInteger(payload.relay.max_connections_per_user) &&
          payload.relay.max_connections_per_user > 0 &&
          typeof payload.generated_at === 'string' && Number.isFinite(Date.parse(payload.generated_at)) &&
          !JSON.stringify(payload).toLowerCase().includes('username') &&
          !JSON.stringify(payload).toLowerCase().includes('envelope');
      });
    const expectedPgScopeLimitedCalls = httpErrors.length === 0 && presenceErrors.length === 0;
    const pgPresenceRoutesPass = presenceResponses.length > 0 &&
      presenceResponses.every((entry) => entry.status === 200);
    report('page_errors', pageErrors);
    report('console_errors', consoleErrors);
    report('expected_old_password_console_errors', expectedOldPasswordConsoleErrors);
    report('unexpected_console_errors', unexpectedConsoleErrors);
    report('console_error_details', JSON.stringify(consoleErrorDetails));
    report('request_failures', requestFailures);
    report('http_error_responses', JSON.stringify(httpErrors));
    report('pg_admin_jobs_list_available', pgAdminJobsPass);
    report('pg_admin_overview_available_and_safe', pgAdminOverviewPass);
    report('pg_admin_invitation_responses', JSON.stringify(adminInvitationResponses.map((entry) => ({
      method: entry.method,
      path: entry.path,
      status: entry.status,
      hasBearer: entry.hasBearer,
    }))));
    report('pg_admin_jobs_responses', JSON.stringify(await Promise.all(adminJobResponses.map(async (entry) => ({
      method: entry.method,
      status: entry.status,
      payload: await entry.payload,
    })))));
    report('no_unexpected_scope_limited_calls', expectedPgScopeLimitedCalls);
    report('pg_presence_browser_routes', pgPresenceRoutesPass);
    report('pg_presence_responses', JSON.stringify(presenceResponses));
    report('relay_requests', relayRequests);
    report('web_release_bundle_path', path.relative(ROOT, path.join(WEB_ROOT, 'main.dart.js')));
    report('web_release_sha256', bundleSha256);
    const pgAdminInvitationsPass = adminInvitationResponses.length === 7 &&
      adminInvitationResponses.every((entry) => entry.status === 200 || entry.status === 201) &&
      adminInvitationResponses.filter((entry) => entry.method === 'GET').length === 5 &&
      adminInvitationResponses.filter((entry) => entry.method === 'POST').length === 2;
    report('pg_admin_invitation_settings_pass', pgAdminInvitationsPass);
    const pgAdminVaultQuotaPass = adminVaultResponses.length === 3 &&
      adminVaultResponses.every((entry) => entry.status === 200 && entry.hasBearer) &&
      adminVaultResponses.filter((entry) => entry.method === 'GET').length === 2 &&
      adminVaultResponses.filter((entry) => entry.method === 'PUT').length === 1;
    report('pg_admin_vault_quota_responses', JSON.stringify(adminVaultResponses.map((entry) => ({
      method: entry.method,
      path: entry.path,
      status: entry.status,
      hasBearer: entry.hasBearer,
    }))));
    report('pg_admin_vault_quota_settings_pass', pgAdminVaultQuotaPass);
    const hasSecurityResponse = (pathname, method, status, predicate = () => true) =>
      securitySummaryResponses.some((entry) => entry.path === pathname &&
        entry.method === method && entry.status === status && predicate(entry));
    const pgSecuritySettingsPass =
      hasSecurityResponse('/api/v1/auth/password-change', 'POST', 200,
        (entry) => entry.hasBearer && entry.summary.changed === true &&
          entry.summary.sessionPreserved === true && entry.summary.otherSessionsRevoked === true) &&
      hasSecurityResponse('/api/v1/me', 'GET', 200, (entry) => entry.hasBearer) &&
      hasSecurityResponse('/api/v1/auth/login', 'POST', 401,
        (entry) => !entry.hasBearer && entry.summary.sessionIssued !== true) &&
      hasSecurityResponse('/api/v1/auth/login', 'POST', 200,
        (entry) => !entry.hasBearer && entry.summary.sessionIssued === true &&
          entry.summary.mfaRequired === false) &&
      hasSecurityResponse('/api/v1/auth/recovery/contexts', 'GET', 200,
        (entry) => entry.hasBearer && entry.summary.recoveryContextsLoaded === true) &&
      hasSecurityResponse('/api/v1/auth/mfa/totp/setup', 'POST', 200,
        (entry) => entry.hasBearer && entry.summary.setupMaterialValid === true) &&
      hasSecurityResponse('/api/v1/auth/mfa/totp/confirm', 'POST', 200,
        (entry) => entry.hasBearer && entry.summary.recoveryCodeCount === 10) &&
      hasSecurityResponse('/api/v1/auth/login', 'POST', 202,
        (entry) => !entry.hasBearer && entry.summary.mfaRequired === true &&
          entry.summary.sessionIssued === false) &&
      hasSecurityResponse('/api/v1/auth/login/mfa', 'POST', 200,
        (entry) => !entry.hasBearer && entry.summary.sessionIssued === true) &&
      pgSecurityPersistencePass;
    report('pg_security_api_responses', JSON.stringify(securitySummaryResponses));
    report('pg_security_settings_pass', pgSecuritySettingsPass);
    const finalChecks = {
      pageErrors,
      consoleErrors,
      expectedOldPasswordConsoleErrors,
      unexpectedConsoleErrors,
      requestFailures,
      relayRequests,
      expectedPgScopeLimitedCalls,
      pgPresenceRoutesPass,
      pgAdminJobsPass,
      pgBackupStatusPass,
      pgAdminOverviewPass,
      pgAdminInvitationsPass,
      pgAdminVaultQuotaPass,
      pgSecuritySettingsPass,
    };
    report('pg_admin_final_checks', JSON.stringify(finalChecks));
    assertThat(pageErrors === 0 && requestFailures === 0 && relayRequests === 0 &&
      unexpectedConsoleErrors === 0 && expectedOldPasswordConsoleErrors === 1 &&
      expectedPgScopeLimitedCalls && pgPresenceRoutesPass && pgAdminJobsPass &&
      pgBackupStatusPass && pgAdminOverviewPass && pgAdminInvitationsPass && pgAdminVaultQuotaPass &&
      pgSecuritySettingsPass,
    `PG admin audit browser flow failed its final checks: ${JSON.stringify(finalChecks)}`);
  } catch (error) {
    failureStage = stage;
    throw error;
  } finally {
    setStage('close Chromium profile and verify cleanup');
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
    report('browser_cleanup_complete', true);
  }
}

main().catch((error) => {
  console.error(`PG admin audit browser acceptance failed at ${failureStage || stage}: ${error?.name || 'Error'}`);
  console.error(`PG admin audit sanitized failure: ${sanitizeConsoleError(error?.message || '')}`);
  report('browser_error_diagnostics', JSON.stringify({
    pageErrors,
    consoleErrors,
    consoleErrorDetails,
    requestFailures,
    relayRequests,
  }));
  void context?.close().catch(() => {}).finally(() => browser?.close().catch(() => {}));
  process.exitCode = 1;
});
