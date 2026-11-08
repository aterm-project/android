/*
 * WEB-ADMIN-ACCOUNTS-01: verify allowlisted account/session and invitation
 * controls in Settings against a disposable server. The admin UI issues and
 * revokes one-time account invitations, then manages a separately invited
 * account's sessions and status. Credentials stay in memory and are never
 * printed. API metadata is checked for secret/IP fields.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

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
let adminDeviceId;
let adminAccessToken;
let memberUsername;
let memberPassword;
let memberLoginVerifier;
let memberDeviceId;
let memberAccessToken;
let memberRefreshToken;
let cleanupPromise;
let cleanupFailed = false;
const safeApiStatuses = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
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

function safeFailureSummary(error) {
  let summary = typeof error?.message === 'string'
    ? error.message.split(/\r?\n/, 1)[0]
    : '';
  for (const secret of [
    bootstrapToken,
    invitationToken,
    adminPassword,
    adminAccessToken,
    memberPassword,
    memberLoginVerifier,
    memberAccessToken,
    memberRefreshToken,
  ]) {
    if (typeof secret === 'string' && secret.length > 0) {
      summary = summary.replaceAll(secret, '[redacted]');
    }
  }
  return summary
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, '[account]')
    .slice(0, 700);
}

function buildServer() {
  const buildTmpDir = path.join(ROOT, 'server/target/tmp');
  fs.mkdirSync(buildTmpDir, { recursive: true });
  // The shared /tmp mount can be close to capacity in this workspace. Keep
  // rustc/linker scratch files beside the generated Cargo target instead.
  process.env.TMPDIR = buildTmpDir;
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT,
    env: {
      ...process.env,
      CARGO_TARGET_DIR: path.join(ROOT, 'server/target'),
      TMPDIR: buildTmpDir,
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
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') {
        return true;
      }
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
    adminDeviceId = undefined;
    adminAccessToken = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    memberLoginVerifier = undefined;
    memberDeviceId = undefined;
    memberAccessToken = undefined;
    memberRefreshToken = undefined;
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

async function clickLastButton(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).last();
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  await locator.click();
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

async function configurePage(page, baseUrl) {
  const runtimeDiagnostics = [];
  page.on('console', (message) => {
    if (message.type() === 'error') runtimeDiagnostics.push(message.text().slice(0, 180));
  });
  page.on('pageerror', (error) => {
    runtimeDiagnostics.push(`pageerror:${error.name}:${error.message}`.slice(0, 180));
  });
  page.on('requestfailed', (request) => {
    runtimeDiagnostics.push(`requestfailed:${new URL(request.url()).pathname}`.slice(0, 180));
  });
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  try {
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  } catch (error) {
    const state = await page.evaluate(() => ({
      sodium: typeof window.sodium,
      sodiumReady: typeof window.sodium?.ready?.then,
      placeholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      semantics: document.querySelectorAll('flt-semantics').length,
      flutter: typeof window.flutter,
      flutterView: Boolean(document.querySelector('flutter-view')),
      scripts: [...document.scripts].map((script) => script.src.split('/').pop()),
      readyState: document.readyState,
      title: document.title,
      body: (document.body?.innerText || '').slice(0, 80),
    }));
    throw new Error(`Flutter bootstrap diagnostic runtime=${JSON.stringify(runtimeDiagnostics.slice(0, 5))} state=${JSON.stringify(state)}: ${error.message}`);
  }
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
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
  return token;
}

function apiRoute(request) {
  let pathname;
  try {
    pathname = new URL(request.url()).pathname;
  } catch (_) {
    return null;
  }
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/admin/audit') return 'admin-audit';
  if (pathname === '/api/v1/admin/account-invitations') return 'admin-account-invitations';
  if (/^\/api\/v1\/admin\/account-invitations\/[0-9a-f-]+\/revoke$/.test(pathname)) {
    return 'admin-account-invitation-revoke';
  }
  if (pathname === '/api/v1/admin/accounts') return 'admin-accounts';
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions\/revoke$/.test(pathname)) {
    return 'admin-bulk-revoke';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions\/[0-9a-f-]+\/revoke$/.test(pathname)) {
    return 'admin-session-revoke';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/sessions$/.test(pathname)) {
    return 'admin-account-sessions';
  }
  if (/^\/api\/v1\/admin\/accounts\/[0-9a-f-]+\/status$/.test(pathname)) {
    return 'admin-account-status';
  }
  return null;
}

function trackApi(page, events, onRegisterRequest) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    let registerRequest = null;
    if (route === 'register' && onRegisterRequest) {
      try {
        registerRequest = request.postDataJSON();
        onRegisterRequest(registerRequest);
      } catch (_) {
        registerRequest = null;
      }
    }
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
    events.push({
      ...metadata,
      status: response.status(),
      sequence: events.length,
      payloadPromise: response.json().catch(() => null),
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
  throw new Error('expected API response did not arrive');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertNoSecretOrIpFields(value) {
  const forbiddenKey = /(hash|ip|address|password|secret|verifier|envelope|ciphertext|token)/i;
  const ipv4 = /\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/;
  const visit = (item) => {
    if (Array.isArray(item)) {
      item.forEach(visit);
      return;
    }
    if (!item || typeof item !== 'object') return;
    for (const [key, child] of Object.entries(item)) {
      assertThat(!forbiddenKey.test(key), 'admin metadata exposed a forbidden secret/IP field');
      visit(child);
    }
  };
  visit(value);
  assertThat(!ipv4.test(JSON.stringify(value)), 'admin metadata exposed an IP address');
}

function validateAccountsPage(payload, targetUserId, expectedUsername, expectedStatus) {
  assertThat(exactKeys(payload, ['accounts', 'total', 'limit', 'offset']) &&
      Array.isArray(payload.accounts) && Number.isInteger(payload.total) &&
      Number.isInteger(payload.limit) && Number.isInteger(payload.offset),
    'admin accounts page shape was invalid');
  assertNoSecretOrIpFields(payload);
  const expectedAccountKeys = [
    'user_id', 'username', 'status', 'created_at', 'active_device_count', 'active_session_count',
  ];
  for (const account of payload.accounts) {
    assertThat(exactKeys(account, expectedAccountKeys), 'admin account metadata fields changed');
  }
  const target = payload.accounts.find((account) => account.user_id === targetUserId);
  assertThat(target && target.username === expectedUsername && target.status === expectedStatus,
    'admin account listing omitted expected target metadata/status');
  return target;
}

function validateInvitationPage(payload, invitationId, expectedUsername, expectedStatus) {
  const envelopeValid = exactKeys(payload, ['invitations', 'total', 'limit', 'offset']) &&
      Array.isArray(payload.invitations) && Number.isInteger(payload.total) &&
      Number.isInteger(payload.limit) && Number.isInteger(payload.offset);
  if (!envelopeValid) {
    const summary = payload && typeof payload === 'object'
      ? {
        keys: Object.keys(payload).sort(),
        invitationsType: Array.isArray(payload.invitations) ? 'array' : typeof payload.invitations,
        totalType: typeof payload.total,
        limitType: typeof payload.limit,
        offsetType: typeof payload.offset,
      }
      : { payloadType: typeof payload };
    throw new Error(`admin account invitation page envelope was invalid: ${JSON.stringify(summary)}`);
  }
  assertNoSecretOrIpFields(payload);
  for (const invitation of payload.invitations) {
    assertThat(exactKeys(invitation, [
      'invitation_id', 'username', 'created_at', 'expires_at', 'status',
    ]) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      .test(invitation.invitation_id) && typeof invitation.username === 'string' &&
      typeof invitation.created_at === 'string' &&
      !Number.isNaN(Date.parse(invitation.created_at)) &&
      typeof invitation.expires_at === 'string' &&
      !Number.isNaN(Date.parse(invitation.expires_at)) &&
      ['pending', 'expired', 'consumed', 'revoked'].includes(invitation.status),
    'admin account invitation row shape or state was invalid');
  }
  if (!invitationId) return null;
  const invitation = payload.invitations.find((item) => item.invitation_id === invitationId);
  assertThat(invitation && invitation.username === expectedUsername &&
      invitation.status === expectedStatus,
    'admin account invitation status did not match its real lifecycle');
  return invitation;
}

function validateIssuedInvitationReceipt(payload, expectedUsername) {
  assertThat(exactKeys(payload, ['invitation']) &&
      exactKeys(payload.invitation, [
        'invitation_id', 'username', 'created_at', 'expires_at', 'token',
      ]) &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        .test(payload.invitation.invitation_id) &&
      payload.invitation.username === expectedUsername &&
      typeof payload.invitation.created_at === 'string' &&
      !Number.isNaN(Date.parse(payload.invitation.created_at)) &&
      typeof payload.invitation.expires_at === 'string' &&
      !Number.isNaN(Date.parse(payload.invitation.expires_at)) &&
      typeof payload.invitation.token === 'string' &&
      /^[A-Za-z0-9_-]{43}$/.test(payload.invitation.token),
    'one-time account invitation receipt shape or token was invalid');
  const lifetimeSeconds = (Date.parse(payload.invitation.expires_at) -
    Date.parse(payload.invitation.created_at)) / 1000;
  assertThat(lifetimeSeconds >= 604799 && lifetimeSeconds <= 604801,
    'default account invitation lifetime was not seven days');
  return payload.invitation;
}

function validateAccountInvitationAudit(payload, adminUserId, adminDeviceId,
    issuedInvitations, revokedInvitationId) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'administrator invitation audit page shape was invalid');
  const expectedFields = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
    'resource_id', 'result', 'occurred_at', 'source',
  ];
  const invitationEvents = payload.events.filter((event) =>
    event.action === 'instance.account_invitation_issued' ||
    event.action === 'instance.account_invitation_revoked');
  for (const event of invitationEvents) {
    assertThat(exactKeys(event, expectedFields) && /^\d+$/.test(event.event_id) &&
        event.scope === 'instance' && event.actor_user_id === adminUserId &&
        event.actor_device_id === adminDeviceId && event.resource_type === 'account_invitation' &&
        typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id) &&
        event.result === 'success' && event.source === 'api' &&
        typeof event.occurred_at === 'string' && !Number.isNaN(Date.parse(event.occurred_at)),
      'account invitation audit actor/resource/source/result was invalid');
  }
  const issuedEvents = invitationEvents.filter((event) =>
    event.action === 'instance.account_invitation_issued');
  const revokedEvents = invitationEvents.filter((event) =>
    event.action === 'instance.account_invitation_revoked');
  assertThat(issuedEvents.length === issuedInvitations.length && revokedEvents.length === 1,
    'account invitation audit event count did not match its issue/revoke lifecycle');
  const issuedResourceIds = new Set(issuedEvents.map((event) => event.resource_id));
  assertThat(issuedResourceIds.size === issuedInvitations.length &&
      issuedEvents.every((event) =>
        !issuedInvitations.some((invitation) => event.resource_id === invitation.invitation_id)),
    'account invitation audit did not use unique opaque HMAC resource identifiers');
  const revokedInvitationEvents = invitationEvents.filter((event) =>
    event.resource_id === revokedEvents[0].resource_id);
  const orderedIssuedEvents = [...issuedEvents].sort((left, right) =>
    BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1);
  assertThat(revokedEvents[0].resource_id !== revokedInvitationId &&
      issuedResourceIds.has(revokedEvents[0].resource_id) &&
      revokedEvents[0].resource_id === orderedIssuedEvents.at(-1)?.resource_id &&
      BigInt(orderedIssuedEvents.at(-1)?.event_id || '0') < BigInt(revokedEvents[0].event_id) &&
      revokedInvitationEvents.some((event) => event.action === 'instance.account_invitation_issued') &&
      revokedInvitationEvents.some((event) => event.action === 'instance.account_invitation_revoked'),
    'revocation audit did not bind to the invitation issuance resource');
  const ids = invitationEvents.map((event) => BigInt(event.event_id));
  assertThat(new Set(ids.map(String)).size === ids.length,
    'account invitation audit event IDs were duplicated');
  return invitationEvents;
}

function validateSessionsPage(payload) {
  assertThat(exactKeys(payload, ['sessions', 'total', 'limit', 'offset']) &&
      Array.isArray(payload.sessions) && Number.isInteger(payload.total) &&
      Number.isInteger(payload.limit) && Number.isInteger(payload.offset),
    'admin session page shape was invalid');
  assertNoSecretOrIpFields(payload);
  const expectedSessionKeys = [
    'session_id', 'device_id', 'device_name', 'created_at', 'access_expires_at',
    'refresh_expires_at', 'revoked_at', 'active',
  ];
  for (const session of payload.sessions) {
    assertThat(exactKeys(session, expectedSessionKeys), 'admin session metadata fields changed');
  }
  return payload.sessions;
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
  return { status: response.status, body: await response.json().catch(() => null) };
}

async function memberLogin(baseUrl) {
  const response = await directApi(baseUrl, 'POST', '/api/v1/auth/login', {
    body: {
      username: memberUsername,
      login_verifier: memberLoginVerifier,
      device_id: memberDeviceId,
    },
  });
  reportStatus('fresh_member_login', response.status);
  assertThat(response.status === 200 &&
      typeof response.body?.access_token === 'string' &&
      typeof response.body?.refresh_token === 'string',
    'fresh sign-in did not establish a new member session');
  return {
    accessToken: response.body.access_token,
    refreshToken: response.body.refresh_token,
  };
}

async function assertTokensRejected(baseUrl, tokens, label) {
  const access = await directApi(baseUrl, 'GET', '/api/v1/me', { token: tokens.accessToken });
  const refresh = await directApi(baseUrl, 'POST', '/api/v1/auth/refresh', {
    body: { refresh_token: tokens.refreshToken },
  });
  reportStatus(`${label}_old_access`, access.status);
  reportStatus(`${label}_old_refresh`, refresh.status);
  assertThat(access.status === 401 && refresh.status === 401,
    `old ${label} session credentials were accepted`);
}

async function waitForPageRoute(events, route, start, predicate = () => true) {
  return waitForEvent(events,
    (event) => event.route === route && event.sequence >= start && predicate(event));
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-accounts-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    adminUsername = `web-admin-accounts-${crypto.randomUUID().slice(0, 8)}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-account-target-${crypto.randomUUID().slice(0, 8)}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    const revokedInvitationUsername =
      `web-revoked-invite-${crypto.randomUUID().slice(0, 8)}@example.test`;
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };
    const adminEvents = [];
    const memberEvents = [];
    let adminPageErrors = 0;
    let memberPageErrors = 0;

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
    const adminPage = await adminContext.newPage();
    adminPage.on('pageerror', () => { adminPageErrors += 1; });
    trackApi(adminPage, adminEvents);

    setStage('configure administrator app connection');
    await configurePage(adminPage, baseUrl);
    setStage('fill allowlisted administrator registration');
    await field(adminPage, 'Owner email');
    await fill(adminPage, 'Owner email', adminUsername);
    await fill(adminPage, 'Master password · 12+ characters', adminPassword);
    await fill(adminPage, 'Confirm master password', adminPassword);
    await fill(adminPage, 'One-time bootstrap token', bootstrapToken);
    await fill(adminPage, 'Device name', 'Admin accounts acceptance');
    await fill(adminPage, 'First Vault', 'Admin accounts acceptance');
    const adminRegisterStart = adminEvents.length;
    setStage('submit allowlisted administrator registration');
    await click(adminPage, 'Create owner account');
    bootstrapToken = undefined;
    setStage('wait for administrator account shell');
    await (await button(adminPage, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
    setStage('read administrator registration receipt');
    const adminRegister = await waitForPageRoute(adminEvents, 'register', adminRegisterStart);
    const adminRegisterBody = await adminRegister.payloadPromise;
    assertThat(adminRegister.status >= 200 && adminRegister.status < 300 &&
        typeof adminRegisterBody?.account_id === 'string',
      'allowlisted admin registration failed');
    adminDeviceId = adminRegisterBody.device_id;
    adminAccessToken = adminRegisterBody.access_token;
    assertThat(typeof adminDeviceId === 'string' &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(adminDeviceId) &&
        typeof adminAccessToken === 'string',
      'allowlisted admin registration omitted its device/session identifiers');
    reportStatus('admin_registration', adminRegister.status);

    setStage('issue one-time account invitation from administrator Settings');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Instance accounts and sessions'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Account invitations'));
    const initialInvitationsStart = adminEvents.length;
    await click(adminPage, 'Load account invitations');
    const initialInvitationsEvent = await waitForPageRoute(
      adminEvents, 'admin-account-invitations', initialInvitationsStart,
      (event) => event.method === 'GET');
    reportStatus('admin_account_invitations_list', initialInvitationsEvent.status);
    assertThat(initialInvitationsEvent.hasBearer && initialInvitationsEvent.status === 200,
      'administrator account invitation list was not authorized');
    const initialInvitations = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(initialInvitations.status === 200,
      'initial administrator account invitation state read failed');
    validateInvitationPage(initialInvitations.body);
    reportBoolean('admin_invitation_list_dto_contains_no_token_or_hash', true);

    await adminContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    await click(adminPage, 'Issue account invitation');
    await fill(adminPage, 'Invitation username', memberUsername);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Invitation expires in days'));
    await waitFor(() => hasVisibleSemanticText(adminPage, '7 days'));
    const issueStart = adminEvents.length;
    await click(adminPage, 'Create invitation');
    const issueEvent = await waitForPageRoute(adminEvents,
      'admin-account-invitations', issueStart,
      (event) => event.method === 'POST');
    reportStatus('admin_account_invitation_issue', issueEvent.status);
    assertThat(issueEvent.hasBearer && issueEvent.status === 201,
      'account invitation creation was not an authenticated 201');
    const issueReceipt = await issueEvent.payloadPromise;
    const issuedInvitation = validateIssuedInvitationReceipt(issueReceipt, memberUsername);
    const issuedInvitationId = issuedInvitation.invitation_id;
    invitationToken = issuedInvitation.token;
    await waitFor(() => hasVisibleSemanticText(adminPage, 'One-time invitation token'));
    await waitFor(() => hasVisibleSemanticText(adminPage, invitationToken));
    reportBoolean('one_time_invitation_token_visible_in_settings', true);
    setStage('copy issued invitation token from Settings');
    await click(adminPage, 'Copy invitation token');
    await adminPage.waitForTimeout(500);
    reportBoolean('copy_confirmation_visible',
      await hasVisibleSemanticText(adminPage, 'Invitation token copied.'));
    reportBoolean('copy_button_disabled_after_copy',
      await (await button(adminPage, 'Copy invitation token')).isDisabled());
    let copiedToken = await adminPage.evaluate(() => navigator.clipboard.readText());
    assertThat(copiedToken === invitationToken,
      'copy action did not place the issued token on the clipboard');
    copiedToken = '';
    await adminPage.evaluate(() => navigator.clipboard.writeText(''));
    setStage('verify copied invitation token cleared from Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Invitation token copied.'));
    await waitFor(async () => !(await hasVisibleSemanticText(adminPage, invitationToken)));
    reportBoolean('one_time_invitation_token_cleared_from_settings', true);
    await click(adminPage, 'Done');
    const persistedInvitationState = await adminPage.evaluate(() => JSON.stringify({
      local: Object.entries(localStorage),
      session: Object.entries(sessionStorage),
    }));
    assertThat(!persistedInvitationState.includes(invitationToken),
      'one-time account invitation token was persisted in browser storage');
    issueReceipt.invitation.token = '';
    issuedInvitation.token = '';
    issueEvent.payloadPromise = Promise.resolve(null);
    reportBoolean('admin_one_time_invitation_copied_then_cleared', true);

    setStage('verify safe pending invitation list and register invited account');
    const pendingInvitationsStart = adminEvents.length;
    await click(adminPage, 'Refresh account invitations');
    const pendingInvitationsEvent = await waitForPageRoute(
      adminEvents, 'admin-account-invitations', pendingInvitationsStart,
      (event) => event.method === 'GET');
    assertThat(pendingInvitationsEvent.status === 200 && pendingInvitationsEvent.hasBearer,
      'pending account invitation refresh was not an authenticated success');
    const pendingInvitations = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(pendingInvitations.status === 200,
      'pending account invitation state read failed');
    validateInvitationPage(pendingInvitations.body,
      issuedInvitationId, memberUsername, 'pending');
    reportBoolean('pending_invitation_status_safe_list', true);

    setStage('issue and revoke a pending invitation from Settings');
    await click(adminPage, 'Issue account invitation');
    await fill(adminPage, 'Invitation username', revokedInvitationUsername);
    const revokedIssueStart = adminEvents.length;
    await click(adminPage, 'Create invitation');
    const revokedIssueEvent = await waitForPageRoute(adminEvents,
      'admin-account-invitations', revokedIssueStart,
      (event) => event.method === 'POST');
    reportStatus('pending_account_invitation_issue', revokedIssueEvent.status);
    assertThat(revokedIssueEvent.hasBearer && revokedIssueEvent.status === 201,
      'pending account invitation creation was not an authenticated 201');
    const revokedIssueReceipt = await revokedIssueEvent.payloadPromise;
    const revokedInvitation = validateIssuedInvitationReceipt(
      revokedIssueReceipt, revokedInvitationUsername);
    const revokedInvitationId = revokedInvitation.invitation_id;
    let revokedInvitationToken = revokedInvitation.token;
    await waitFor(() => hasVisibleSemanticText(adminPage, revokedInvitationToken));
    reportBoolean('second_invitation_token_visible_before_dismissal', true);
    await click(adminPage, 'Done');
    revokedIssueReceipt.invitation.token = '';
    revokedInvitation.token = '';
    revokedInvitationToken = undefined;
    revokedIssueEvent.payloadPromise = Promise.resolve(null);

    const pendingRevokeListStart = adminEvents.length;
    await click(adminPage, 'Refresh account invitations');
    const pendingRevokeListEvent = await waitForPageRoute(
      adminEvents, 'admin-account-invitations', pendingRevokeListStart,
      (event) => event.method === 'GET');
    assertThat(pendingRevokeListEvent.status === 200 && pendingRevokeListEvent.hasBearer,
      'administrator could not list a pending invitation before revocation');
    const pendingRevokeList = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(pendingRevokeList.status === 200,
      'pending invitation state read before revocation failed');
    validateInvitationPage(pendingRevokeList.body,
      revokedInvitationId, revokedInvitationUsername, 'pending');
    await waitFor(() => hasVisibleSemanticText(adminPage, revokedInvitationUsername));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Pending'));
    await click(adminPage, 'Revoke invitation');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoke account invitation?'));
    const revokeStart = adminEvents.length;
    await click(adminPage, 'Confirm revoke invitation');
    const revokeEvent = await waitForPageRoute(adminEvents,
      'admin-account-invitation-revoke', revokeStart,
      (event) => event.method === 'POST');
    reportStatus('admin_account_invitation_revoke', revokeEvent.status);
    const revokeReceipt = await revokeEvent.payloadPromise;
    assertThat(revokeEvent.hasBearer && revokeEvent.status === 200 &&
        exactKeys(revokeReceipt, ['invitation_id', 'status', 'revoked_at']) &&
        revokeReceipt.invitation_id === revokedInvitationId &&
        revokeReceipt.status === 'revoked' && typeof revokeReceipt.revoked_at === 'string' &&
        !Number.isNaN(Date.parse(revokeReceipt.revoked_at)),
      'pending invitation revoke receipt was invalid');
    const revokedListStart = adminEvents.length;
    await click(adminPage, 'Refresh account invitations');
    const revokedListEvent = await waitForPageRoute(
      adminEvents, 'admin-account-invitations', revokedListStart,
      (event) => event.method === 'GET');
    assertThat(revokedListEvent.status === 200 && revokedListEvent.hasBearer,
      'administrator invitation list refresh after revoke failed');
    const revokedList = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(revokedList.status === 200,
      'revoked invitation state read failed');
    validateInvitationPage(revokedList.body,
      revokedInvitationId, revokedInvitationUsername, 'revoked');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoked'));
    const idempotentRevoke = await directApi(baseUrl, 'POST',
      `/api/v1/admin/account-invitations/${revokedInvitationId}/revoke`, {
        token: adminAccessToken,
      });
    assertThat(idempotentRevoke.status === 200 &&
        idempotentRevoke.body?.invitation_id === revokedInvitationId &&
        idempotentRevoke.body?.status === 'revoked',
      'repeated pending invitation revoke was not idempotent');
    reportBoolean('pending_invitation_revocation_and_idempotent_repeat', true);

    const invitationAuditStart = adminEvents.length;
    await click(adminPage, 'Load admin audit');
    const invitationAuditUiEvent = await waitForPageRoute(
      adminEvents, 'admin-audit', invitationAuditStart,
      (event) => event.method === 'GET');
    const renderedInvitationAudit = await invitationAuditUiEvent.payloadPromise;
    assertThat(invitationAuditUiEvent.status === 200 && invitationAuditUiEvent.hasBearer,
      'Settings audit refresh for account invitations was not authenticated');
    validateAccountInvitationAudit(
      renderedInvitationAudit, adminRegisterBody.account_id, adminDeviceId,
      [{ invitation_id: issuedInvitationId }, { invitation_id: revokedInvitationId }],
      revokedInvitationId);
    assertThat(await hasVisibleSemanticText(adminPage, '实例管理员邀请已签发') &&
        await hasVisibleSemanticText(adminPage, '实例管理员邀请已撤销') &&
        !await hasVisibleSemanticText(adminPage, 'instance.account_invitation_revoked'),
      'Settings audit card did not localize account invitation issue and revoke events');
    reportBoolean('account_invitation_audit_api_and_settings_labels_valid', true);

    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const memberPage = await memberContext.newPage();
    memberPage.on('pageerror', () => { memberPageErrors += 1; });
    trackApi(memberPage, memberEvents, (body) => {
      if (body?.username !== memberUsername || typeof body.login_verifier !== 'string') return;
      memberLoginVerifier = body.login_verifier;
      memberDeviceId = body.device?.device_id;
    });
    await configurePage(memberPage, baseUrl);
    await field(memberPage, 'Email or username');
    await click(memberPage, 'Have an instance invitation? Create account');
    await field(memberPage, 'Email on the invitation');
    await fill(memberPage, 'Email on the invitation', memberUsername);
    await fill(memberPage, 'Master password · 12+ characters', memberPassword);
    await fill(memberPage, 'Confirm master password', memberPassword);
    await fill(memberPage, 'Instance invitation token', invitationToken);
    invitationToken = undefined;
    await fill(memberPage, 'Device name', 'Account control target browser');
    await fill(memberPage, 'First Vault', 'Account control target Vault');
    const memberRegisterStart = memberEvents.length;
    await click(memberPage, 'Create invited account');
    await (await button(memberPage, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
    const memberRegister = await waitForPageRoute(memberEvents, 'register', memberRegisterStart);
    const memberRegisterBody = await memberRegister.payloadPromise;
    assertThat(memberRegister.status >= 200 && memberRegister.status < 300 &&
        typeof memberRegisterBody?.account_id === 'string' &&
        typeof memberRegisterBody?.access_token === 'string' &&
        typeof memberRegisterBody?.refresh_token === 'string' &&
        typeof memberRegisterBody?.device_id === 'string' &&
        typeof memberLoginVerifier === 'string' && typeof memberDeviceId === 'string',
      'invited account registration response was incomplete');
    const targetUserId = memberRegisterBody.account_id;
    memberAccessToken = memberRegisterBody.access_token;
    memberRefreshToken = memberRegisterBody.refresh_token;
    assertThat(memberRegisterBody.device_id === memberDeviceId,
      'captured login device did not match account registration');
    reportStatus('non_admin_registration', memberRegister.status);

    setStage('verify invitation was consumed and token is absent from admin list');
    const consumedInvitationsStart = adminEvents.length;
    await click(adminPage, 'Refresh account invitations');
    const consumedInvitationsEvent = await waitForPageRoute(
      adminEvents, 'admin-account-invitations', consumedInvitationsStart,
      (event) => event.method === 'GET');
    assertThat(consumedInvitationsEvent.status === 200 && consumedInvitationsEvent.hasBearer,
      'admin could not refresh invitations after account registration');
    const consumedInvitations = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(consumedInvitations.status === 200,
      'administrator invitation state read after registration failed');
    validateInvitationPage(consumedInvitations.body,
      issuedInvitation.invitation_id, memberUsername, 'consumed');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Consumed'));
    reportBoolean('registered_account_consumed_one_time_invitation', true);

    setStage('verify instance account invitation routes deny non-admin access');
    const unauthenticatedInviteRead = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0');
    reportStatus('unauthenticated_account_invitation_list', unauthenticatedInviteRead.status);
    assertThat(unauthenticatedInviteRead.status === 401,
      'unauthenticated account invitation list was not denied');
    const memberInviteRead = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: memberAccessToken });
    reportStatus('non_admin_account_invitation_list', memberInviteRead.status);
    assertThat(memberInviteRead.status === 403,
      'non-admin account invitation list was not denied');
    const memberInviteWrite = await directApi(baseUrl, 'POST',
      '/api/v1/admin/account-invitations', {
        token: memberAccessToken,
        body: { username: `non-admin-${crypto.randomUUID()}@example.test` },
      });
    reportStatus('non_admin_account_invitation_issue', memberInviteWrite.status);
    assertThat(memberInviteWrite.status === 403,
      'non-admin account invitation creation was not denied');
    const memberInviteRevoke = await directApi(baseUrl, 'POST',
      `/api/v1/admin/account-invitations/${revokedInvitationId}/revoke`, {
        token: memberAccessToken,
      });
    reportStatus('non_admin_account_invitation_revoke', memberInviteRevoke.status);
    assertThat(memberInviteRevoke.status === 403,
      'non-admin account invitation revocation was not denied');
    const listAfterNonAdmin = await directApi(baseUrl, 'GET',
      '/api/v1/admin/account-invitations?limit=50&offset=0', { token: adminAccessToken });
    assertThat(listAfterNonAdmin.status === 200 &&
        listAfterNonAdmin.body?.total === consumedInvitations.body.total,
      'non-admin invitation mutations changed the invitation directory');
    reportBoolean('account_invitation_admin_acl_enforced', true);

    setStage('verify non-admin Settings gating');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberHasAccountsCard = await hasVisibleSemanticText(memberPage, 'Instance accounts and sessions');
    reportBoolean('non_admin_accounts_card_absent', !memberHasAccountsCard);
    assertThat(!memberHasAccountsCard, 'non-admin profile rendered instance account controls');
    const memberHasInvitationCard = await hasVisibleSemanticText(memberPage, 'Account invitations');
    assertThat(!memberHasInvitationCard,
      'non-admin profile rendered instance account invitation controls');

    setStage('open administrator Settings account controls');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Instance accounts and sessions'));
    const listStart = adminEvents.length;
    await click(adminPage, 'Refresh admin accounts');
    const accountsEvent = await waitForPageRoute(adminEvents, 'admin-accounts', listStart);
    const accountsPayload = await accountsEvent.payloadPromise;
    reportStatus('admin_accounts_list', accountsEvent.status);
    assertThat(accountsEvent.method === 'GET' && accountsEvent.hasBearer && accountsEvent.status === 200,
      'admin account list request was not an authenticated success');
    const targetMetadata = validateAccountsPage(accountsPayload, targetUserId, memberUsername, 'active');
    assertThat(targetMetadata.active_device_count === 1 && targetMetadata.active_session_count === 1,
      'initial account directory counts did not match the invited account');
    reportBoolean('account_metadata_shape_private', true);
    await waitFor(() => hasVisibleSemanticText(adminPage, memberUsername));
    reportBoolean('account_metadata_rendered', true);

    setStage('load target account sessions');
    const sessionsStart = adminEvents.length;
    await click(adminPage, 'View sessions');
    const sessionsEvent = await waitForPageRoute(adminEvents, 'admin-account-sessions', sessionsStart);
    const sessionsPayload = await sessionsEvent.payloadPromise;
    reportStatus('admin_account_sessions', sessionsEvent.status);
    assertThat(sessionsEvent.method === 'GET' && sessionsEvent.hasBearer && sessionsEvent.status === 200 &&
        sessionsEvent.pathname === `/api/v1/admin/accounts/${targetUserId}/sessions`,
      'admin session listing request was not an authenticated success');
    const initialSessions = validateSessionsPage(sessionsPayload);
    assertThat(sessionsPayload.total === 1 && initialSessions.length === 1 &&
        initialSessions[0].device_id === memberDeviceId && initialSessions[0].active === true &&
        initialSessions[0].revoked_at === null,
      'initial target session metadata was unexpected');
    const firstSessionId = initialSessions[0].session_id;
    reportBoolean('session_metadata_shape_private', true);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Account sessions'));
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Account control target browser'));

    setStage('revoke one session from administrator UI');
    await click(adminPage, 'Revoke session');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoke this session?'));
    const revokeOneStart = adminEvents.length;
    await clickLastButton(adminPage, 'Revoke session');
    const revokeOneEvent = await waitForPageRoute(adminEvents, 'admin-session-revoke', revokeOneStart);
    const revokeOneReceipt = await revokeOneEvent.payloadPromise;
    reportStatus('admin_individual_session_revoke', revokeOneEvent.status);
    assertThat(revokeOneEvent.method === 'POST' && revokeOneEvent.hasBearer &&
        revokeOneEvent.status === 200 && revokeOneReceipt?.account_id === targetUserId &&
        revokeOneReceipt?.session_id === firstSessionId && revokeOneReceipt?.revoked === true &&
        revokeOneReceipt?.changed === true,
      'individual session revocation receipt was invalid');
    const sessionRefreshAfterOne = await waitForPageRoute(
      adminEvents, 'admin-account-sessions', revokeOneStart,
    );
    const afterOneSessions = validateSessionsPage(await sessionRefreshAfterOne.payloadPromise);
    assertThat(afterOneSessions.find((session) => session.session_id === firstSessionId)?.revoked_at,
      'revoked session remained unrevoked in the UI refresh');
    await assertTokensRejected(baseUrl, {
      accessToken: memberAccessToken,
      refreshToken: memberRefreshToken,
    }, 'individually revoked');

    setStage('create a fresh session for bulk revoke coverage');
    const secondLogin = await memberLogin(baseUrl);
    const refreshSessionsStart = adminEvents.length;
    await click(adminPage, 'Refresh account sessions');
    const secondSessionsEvent = await waitForPageRoute(
      adminEvents, 'admin-account-sessions', refreshSessionsStart,
    );
    const secondSessionsPayload = await secondSessionsEvent.payloadPromise;
    const afterSecondLogin = validateSessionsPage(secondSessionsPayload);
    assertThat(secondSessionsPayload.total === 2 &&
        afterSecondLogin.filter((session) => session.active).length === 1,
      'fresh login did not create one additional active session');

    setStage('bulk revoke sessions from administrator UI');
    await click(adminPage, 'Revoke all sessions');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Revoke all sessions?'));
    const bulkStart = adminEvents.length;
    await clickLastButton(adminPage, 'Revoke sessions');
    const bulkEvent = await waitForPageRoute(adminEvents, 'admin-bulk-revoke', bulkStart);
    const bulkReceipt = await bulkEvent.payloadPromise;
    reportStatus('admin_bulk_session_revoke', bulkEvent.status);
    assertThat(bulkEvent.method === 'POST' && bulkEvent.hasBearer && bulkEvent.status === 200 &&
        bulkReceipt?.account_id === targetUserId && bulkReceipt?.revoked_sessions === 1,
      'bulk session revocation receipt was invalid');
    await assertTokensRejected(baseUrl, secondLogin, 'bulk revoked');

    setStage('validate the bulk-session audit DTO, privacy and order');
    const bulkAudit = await directApi(baseUrl, 'GET', '/api/v1/admin/audit?limit=100', {
      token: adminAccessToken,
    });
    reportStatus('bulk_session_audit_feed', bulkAudit.status);
    const auditFields = [
      'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
      'resource_id', 'result', 'occurred_at', 'source',
    ];
    const bulkRows = bulkAudit.body?.events?.filter(
      (event) => event.action === 'admin.account_sessions_revoked') || [];
    const individualRows = bulkAudit.body?.events?.filter(
      (event) => event.action === 'admin.account_session_revoked') || [];
    const bulkAuditRow = bulkRows.find((event) =>
      event.resource_type === 'account' && event.resource_id !== targetUserId);
    const individualAuditRow = individualRows.find((event) =>
      event.resource_type === 'account' && event.resource_id !== targetUserId);
    const validBulkAudit = bulkAudit.status === 200 &&
      exactKeys(bulkAudit.body, ['events', 'next_cursor', 'has_more']) &&
      typeof bulkAudit.body.has_more === 'boolean' &&
      (bulkAudit.body.next_cursor === null || typeof bulkAudit.body.next_cursor === 'string') &&
      bulkRows.length === 1 && individualRows.length === 1 &&
      exactKeys(bulkAuditRow, auditFields) && /^\d+$/.test(bulkAuditRow.event_id) &&
      bulkAuditRow.scope === 'instance' &&
      bulkAuditRow.actor_user_id === adminRegisterBody.account_id &&
      bulkAuditRow.actor_device_id === adminDeviceId &&
      bulkAuditRow.action === 'admin.account_sessions_revoked' &&
      bulkAuditRow.resource_type === 'account' &&
      typeof bulkAuditRow.resource_id === 'string' && /^[0-9a-f]{64}$/.test(bulkAuditRow.resource_id) &&
      bulkAuditRow.result === 'success' && bulkAuditRow.source === 'api' &&
      typeof bulkAuditRow.occurred_at === 'string' &&
      !Number.isNaN(Date.parse(bulkAuditRow.occurred_at)) &&
      exactKeys(individualAuditRow, auditFields) &&
      individualAuditRow.actor_user_id === adminRegisterBody.account_id &&
      individualAuditRow.actor_device_id === adminDeviceId &&
      individualAuditRow.resource_id === bulkAuditRow.resource_id &&
      BigInt(individualAuditRow.event_id) < BigInt(bulkAuditRow.event_id) &&
      !JSON.stringify(bulkAuditRow).includes(targetUserId) &&
      !JSON.stringify(bulkAuditRow).includes(memberUsername);
    assertThat(validBulkAudit,
      'bulk session revoke audit DTO, HMAC privacy, actor or lifecycle order was invalid');
    reportBoolean('bulk_session_audit_exact_dto_actor_device_hmac_order_valid', true);

    setStage('render bulk-session audit label in the current Settings UI');
    const bulkAuditRefreshStart = adminEvents.length;
    await click(adminPage, 'Refresh admin audit');
    const bulkAuditRefresh = await waitForPageRoute(
      adminEvents, 'admin-audit', bulkAuditRefreshStart, (event) => event.method === 'GET');
    const renderedBulkAudit = await bulkAuditRefresh.payloadPromise;
    const renderedBulkRow = renderedBulkAudit?.events?.find(
      (event) => event.action === 'admin.account_sessions_revoked');
    assertThat(bulkAuditRefresh.status === 200 && bulkAuditRefresh.hasBearer &&
        renderedBulkRow && JSON.stringify(renderedBulkRow) === JSON.stringify(bulkAuditRow),
      'Settings refresh did not render the exact validated bulk-session audit DTO');
    const bulkAuditLabel = '管理员已撤销账户的全部会话';
    await waitFor(() => hasVisibleSemanticText(adminPage, bulkAuditLabel));
    assertThat(await hasVisibleSemanticText(adminPage, bulkAuditLabel) &&
        !await hasVisibleSemanticText(adminPage, 'admin.account_sessions_revoked'),
      'Settings did not localize the bulk-session action or exposed its raw key');
    reportBoolean('bulk_session_audit_settings_label_localized', true);

    setStage('create a fresh session for account disable coverage');
    const thirdLogin = await memberLogin(baseUrl);

    setStage('disable target account from administrator UI');
    await click(adminPage, 'Disable account');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Disable account?'));
    const disableStart = adminEvents.length;
    await clickLastButton(adminPage, 'Disable account');
    const disableEvent = await waitForPageRoute(adminEvents, 'admin-account-status', disableStart);
    const disableReceipt = await disableEvent.payloadPromise;
    reportStatus('admin_account_disable', disableEvent.status);
    assertThat(disableEvent.method === 'PUT' && disableEvent.hasBearer && disableEvent.status === 200 &&
        disableReceipt?.account_id === targetUserId && disableReceipt?.status === 'disabled' &&
        disableReceipt?.changed === true && disableReceipt?.revoked_sessions === 1,
      'account disable receipt was invalid');
    await assertTokensRejected(baseUrl, thirdLogin, 'disabled');
    const disabledLogin = await directApi(baseUrl, 'POST', '/api/v1/auth/login', {
      body: {
        username: memberUsername,
        login_verifier: memberLoginVerifier,
        device_id: memberDeviceId,
      },
    });
    reportStatus('login_while_disabled', disabledLogin.status);
    assertThat(disabledLogin.status === 401, 'disabled account accepted a new login');
    const disabledAccountsEvent = await waitForPageRoute(adminEvents, 'admin-accounts', disableStart);
    const disabledAccounts = await disabledAccountsEvent.payloadPromise;
    const disabledMetadata = validateAccountsPage(disabledAccounts, targetUserId, memberUsername, 'disabled');
    assertThat(disabledMetadata.active_session_count === 0 && disabledMetadata.active_device_count === 1,
      'disabled account retained active session or lost its trusted device');

    setStage('re-enable target account from administrator UI');
    await click(adminPage, 'Re-enable account');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Re-enable account?'));
    const enableStart = adminEvents.length;
    await clickLastButton(adminPage, 'Re-enable account');
    const enableEvent = await waitForPageRoute(adminEvents, 'admin-account-status', enableStart);
    const enableReceipt = await enableEvent.payloadPromise;
    reportStatus('admin_account_enable', enableEvent.status);
    assertThat(enableEvent.method === 'PUT' && enableEvent.hasBearer && enableEvent.status === 200 &&
        enableReceipt?.account_id === targetUserId && enableReceipt?.status === 'active' &&
        enableReceipt?.changed === true && enableReceipt?.revoked_sessions === 0,
      'account enable receipt was invalid');
    await assertTokensRejected(baseUrl, thirdLogin, 're-enabled old');
    const enabledAccountsEvent = await waitForPageRoute(adminEvents, 'admin-accounts', enableStart);
    const enabledAccounts = await enabledAccountsEvent.payloadPromise;
    validateAccountsPage(enabledAccounts, targetUserId, memberUsername, 'active');

    setStage('verify fresh login after re-enable');
    const fourthLogin = await memberLogin(baseUrl);
    const freshProfile = await directApi(baseUrl, 'GET', '/api/v1/me', {
      token: fourthLogin.accessToken,
    });
    reportStatus('fresh_profile_after_reenable', freshProfile.status);
    assertThat(freshProfile.status === 200, 'enabled account could not start a fresh session');
    await assertTokensRejected(baseUrl, {
      accessToken: memberAccessToken,
      refreshToken: memberRefreshToken,
    }, 'original pre-revoke');
    reportBoolean('old_tokens_not_revived_after_enable', true);

    assertThat(adminPageErrors === 0 && memberPageErrors === 0,
      'Flutter reported a browser runtime error');
    reportBoolean('browser_runtime_errors_absent', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async (error) => {
  console.error(`stage: failed (${stage}); error type=${error?.name || 'unknown'}; detail=${JSON.stringify(safeFailureSummary(error))}; safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
