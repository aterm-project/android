/*
 * WEB-TEAM-OWNERSHIP-AUDIT-01: verify ownership transfer through the Web UI,
 * including cancel/confirm, role capability handoff, and Vault audit rendering.
 * Console output is limited to stages and sanitized status assertions.
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
let ownerContext;
let memberContext;
let bootstrapToken;
let accountInvitationToken;
let vaultInvitationToken;
let ownerUsername;
let memberUsername;
let ownerPassword;
let memberPassword;
let ownerAccountId;
let ownerDeviceId;
let memberAccountId;
let cleanupPromise;
let cleanupFailed = false;
let safeApiTrace = [];
let safeUiTrace = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function safeFailureMessage(error) {
  const firstLine = String(error?.message || error || 'unknown failure').split('\n')[0];
  return firstLine
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[redacted]')
    .replace(/[A-Za-z0-9_-]{80,}/g, '[redacted]')
    .slice(0, 240);
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
      // Continue while the loopback service starts.
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

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    accountInvitationToken = undefined;
    vaultInvitationToken = undefined;
    ownerUsername = undefined;
    memberUsername = undefined;
    ownerPassword = undefined;
    memberPassword = undefined;
    ownerAccountId = undefined;
    ownerDeviceId = undefined;
    memberAccountId = undefined;
    try {
      if (ownerContext) await ownerContext.close().catch(() => {});
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

async function preserveFailureScreenshot() {
  const context = /member|new Owner/i.test(stage) ? memberContext : ownerContext;
  const page = context?.pages().find((candidate) => !candidate.isClosed());
  if (!page) return;
  const screenshotPath = path.join(
    os.tmpdir(),
    'atermius-web-team-ownership-failure-' + crypto.randomUUID() + '.png',
  );
  try {
    await page.screenshot({ path: screenshotPath, fullPage: true, animations: 'disabled' });
    fs.chmodSync(screenshotPath, 0o600);
    console.error('failure screenshot: ' + screenshotPath);
  } catch (_) {
    // Keep the original acceptance failure as the reported cause.
  }
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function button(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible()) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible control not found: ${label}`);
}

async function buttonIsVisible(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  const count = await matches.count();
  for (let index = 0; index < count; index += 1) {
    if (await matches.nth(index).isVisible()) return true;
  }
  return false;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value, { profile = 'unknown', pageErrors } = {}) {
  let locator;
  let visibleAtStart = false;
  let visibleAfter = false;
  let inputRetained = false;
  try {
    locator = await field(page, label);
    visibleAtStart = await locator.isVisible();
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await locator.click();
      await locator.press('Control+A');
      await locator.pressSequentially(value, { delay: 60 });
      await page.waitForTimeout(180);
      visibleAfter = await locator.isVisible().catch(() => false);
      inputRetained = await locator.inputValue().then((current) => current === value).catch(() => false);
      if (inputRetained) {
        await locator.press('Tab');
        return;
      }
    }
    throw new Error('field entry was not retained');
  } catch (_) {
    safeUiTrace.push({
      profile,
      point: 'field-fill-failed',
      field: label,
      locator_found: Boolean(locator),
      visible_at_start: visibleAtStart,
      visible_after: visibleAfter,
      input_retained: inputRetained,
      page_errors: pageErrors?.count ?? null,
    });
    throw new Error('a visible form field did not retain its input');
  }
}

async function paste(page, label, value, { profile, pageErrors } = {}) {
  const locator = await field(page, label);
  const visibleAtStart = await locator.isVisible();
  let visibleAfter = false;
  let clipboardPasteRetained = false;
  let exactValueFillRetained = false;
  try {
    await page.evaluate(async (clipboardValue) => navigator.clipboard.writeText(clipboardValue), value);
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(500);
    visibleAfter = await locator.isVisible().catch(() => false);
    clipboardPasteRetained = await locator.inputValue().then((current) => current === value).catch(() => false);
    if (clipboardPasteRetained) {
      await locator.press('Tab');
      console.log('observed: device_card_input_method=clipboard_paste');
      return;
    }
  } catch (_) {
    // Try the same public card value through the visible UI field below.
  }
  try {
    await locator.fill(value);
    exactValueFillRetained = await locator.inputValue().then((current) => current === value).catch(() => false);
    if (exactValueFillRetained) {
      await locator.press('Tab');
      console.log('observed: device_card_input_method=exact_value_fill_fallback');
      return;
    }
  } catch (_) {
    // Record only fixed metadata if both user-visible input methods fail.
  }
  safeUiTrace.push({
    profile: profile || 'unknown',
    point: 'device-card-input-failed',
    field: label,
    locator_found: true,
    visible_at_start: visibleAtStart,
    visible_after: visibleAfter,
    clipboard_paste_retained: clipboardPasteRetained,
    exact_value_fill_retained: exactValueFillRetained,
    page_errors: pageErrors?.count ?? null,
  });
  throw new Error('public device card was not retained in the visible form field');
}

async function waitFor(predicate, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected browser state did not appear');
}

async function waitWorkspace(page) {
  await (await button(page, 'Settings')).waitFor({ state: 'visible', timeout: 40000 });
}

async function enableSemantics(page) {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
}

function cliToken(args, environment, marker) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: environment,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `${marker} issuance failed`);
  const value = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(value, `${marker} was not returned`);
  return value;
}

function classifyRequest(request) {
  let pathname;
  try { pathname = new URL(request.url()).pathname; } catch (_) { return null; }
  if (pathname === '/api/v1/instance') return 'instance';
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/auth/login') return 'login';
  if (/^\/api\/v1\/vaults\/[^/]+\/invitations$/.test(pathname)) return 'vault-invite';
  if (/^\/api\/v1\/invitations\/accept$/.test(pathname)) return 'vault-accept';
  if (/^\/api\/v1\/vaults\/[^/]+\/keys\/rotate$/.test(pathname)) return 'vault-rotate';
  if (/^\/api\/v1\/vaults\/[^/]+\/members$/.test(pathname)) return 'vault-members';
  if (/^\/api\/v1\/vaults\/[^/]+\/ownership\/transfer$/.test(pathname)) return 'ownership-transfer';
  if (pathname === '/api/v1/audit') return 'audit';
  return null;
}

function trackApi(page, profile, events, pageErrors) {
  const requestData = new WeakMap();
  page.on('request', (request) => {
    const route = classifyRequest(request);
    if (!route) return;
    const authorization = request.headers().authorization || '';
    requestData.set(request, {
      profile,
      route,
      method: request.method(),
      hasBearer: authorization.startsWith('Bearer ') && authorization.length > 7,
    });
  });
  page.on('response', async (response) => {
    const metadata = requestData.get(response.request());
    if (metadata) {
      const event = { ...metadata, status: response.status(), sequence: events.length };
      if (metadata.route === 'register' || metadata.route === 'audit') {
        event.payloadPromise = response.json().then((body) => {
          if (metadata.route === 'register') {
            return {
              account_id: typeof body?.account_id === 'string' ? body.account_id : null,
              device_id: typeof body?.device_id === 'string' ? body.device_id : null,
            };
          }
          return {
            has_more: body?.has_more === true,
            events: Array.isArray(body?.events) ? body.events.map((item) => ({
              event_id: item?.event_id,
              scope: item?.scope,
              vault_id: item?.vault_id,
              action: item?.action,
              resource_type: item?.resource_type,
              resource_id: item?.resource_id,
              result: item?.result,
              actor_user_id: item?.actor_user_id,
              actor_device_id: item?.actor_device_id,
              source: item?.source,
            })) : [],
          };
        });
      }
      events.push(event);
      const safeEntry = { profile, route: metadata.route, method: metadata.method, status: event.status };
      if (metadata.route === 'instance' || metadata.route === 'vault-invite' || metadata.route === 'vault-members') {
        try {
          const body = await response.json();
          if (metadata.route === 'instance') {
            safeEntry.response_shape = {
              setup_required: typeof body?.setup_required === 'boolean' ? body.setup_required : null,
              instance_id_valid: typeof body?.instance_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.instance_id),
              server_space_id_valid: typeof body?.server_space_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.server_space_id),
              signing_key_present: typeof body?.signing_public_key === 'string' && body.signing_public_key.length > 0,
              transition_count: Array.isArray(body?.signing_key_transitions) ? body.signing_key_transitions.length : null,
              protocol_version_type: typeof body?.protocol_version,
              capabilities_count: Array.isArray(body?.capabilities) ? body.capabilities.length : null,
            };
          } else if (metadata.route === 'vault-invite') {
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              role: typeof body?.role === 'string' ? body.role : null,
              has_token: typeof body?.token === 'string',
              has_invitation_id: typeof body?.invitation_id === 'string',
              has_vault_id: typeof body?.vault_id === 'string',
              membership_version_type: typeof body?.membership_version,
            };
          } else {
            const members = Array.isArray(body?.members) ? body.members : [];
            const roleStates = {};
            for (const item of members) {
              const key = `${String(item?.role || 'unknown')}:${String(item?.state || 'unknown')}`;
              roleStates[key] = (roleStates[key] || 0) + 1;
            }
            safeEntry.response_shape = { member_count: members.length, role_states: roleStates };
          }
        } catch (_) {
          safeEntry.response_shape = { json: false };
        }
      }
      safeApiTrace.push(safeEntry);
      if (safeApiTrace.length > 30) safeApiTrace = safeApiTrace.slice(-30);
    }
  });
  page.on('pageerror', () => { pageErrors.count += 1; });
}

async function waitEvent(events, profile, route, after = -1, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = events.find((event) =>
      event.profile === profile && event.route === route && event.sequence > after);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`expected ${profile} ${route} API response did not arrive`);
}

function assertStatus(event, expected, label) {
  console.log(`observed: ${label}_http_status=${event.status}`);
  assertThat(event.status === expected, `${label} response had unexpected status`);
  if (['vault-invite', 'vault-accept', 'vault-rotate', 'vault-members',
    'ownership-transfer', 'audit'].includes(event.route) &&
      expected !== 401) {
    assertThat(event.hasBearer, `${label} did not use an authenticated session`);
  }
  console.log(`assert: ${label}=true`);
}

async function copyClipboard(page, buttonLabel) {
  await click(page, buttonLabel);
  return page.evaluate(async () => navigator.clipboard.readText());
}

async function staticMembershipSemantics(page) {
  const allowedLabels = [
    'Members ·',
    'OWNER · Active',
    'EDITOR · Invitation pending',
    'VIEWER · Invitation pending',
    'EDITOR · Active',
    'VIEWER · Active',
    'INVITED',
    'ACTIVE',
    'REVOKED',
    'EDITOR · Revoked',
    'Invitation pending',
    'Make viewer',
    'Make editor',
    'Revoke access',
    'Revoke invitation',
    'Change to viewer',
    'Change to editor',
    'Revoke and rotate key',
    'Transfer ownership',
  ];
  return page.locator('flt-semantics').evaluateAll((nodes, labels) => {
    const found = new Set();
    for (const node of nodes) {
      const value = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
      for (const label of labels) {
        if (value.includes(label)) found.add(label);
      }
    }
    return [...found].sort();
  }, allowedLabels);
}

async function safeOwnerRegistrationState(page) {
  return page.locator('flt-semantics').evaluateAll((nodes) => {
    const labels = nodes.map((node) => `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`);
    const joined = labels.join('\n');
    return {
      server_url_visible: labels.some((value) => value.includes('Server URL')),
      connect_visible: labels.some((value) => value.includes('Connect securely')),
      owner_email_visible: labels.some((value) => value.includes('Owner email')),
      invitation_email_visible: labels.some((value) => value.includes('Email on the invitation')),
      login_username_visible: labels.some((value) => value.includes('Email or username')),
      create_owner_visible: labels.some((value) => value.includes('Create owner account')),
      error_present: labels.some((value) => /无法连接到服务端|服务端没有提供有效的实例签名身份|服务端实例身份已改变|服务端签名密钥与已固定身份不符/.test(value)),
      identity_error: /服务端没有提供有效的实例签名身份/.test(joined) ? 'invalid_instance_identity'
        : /服务端实例身份已改变/.test(joined) ? 'instance_identity_changed'
        : /服务端签名密钥与已固定身份不符/.test(joined) ? 'signing_key_mismatch'
        : /无法连接到服务端/.test(joined) ? 'connection_error' : null,
    };
  });
}


async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-team-ownership-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const port = await unusedLoopbackPort();
  const baseUrl = 'http://127.0.0.1:' + port;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: '127.0.0.1:' + port,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: 'sqlite://' + path.join(dataDir, 'atermius.db') + '?mode=rwc',
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: 'off',
  };
  ownerUsername = 'web-owner-transfer-' + crypto.randomUUID().slice(0, 8) + '@example.test';
  memberUsername = 'web-member-transfer-' + crypto.randomUUID().slice(0, 8) + '@example.test';
  ownerPassword = 'Owner-' + crypto.randomBytes(32).toString('base64url');
  memberPassword = 'Member-' + crypto.randomBytes(32).toString('base64url');
  const apiEvents = [];
  const pageErrors = { count: 0 };

  try {
    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);

    setStage('isolated Chromium profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    ownerContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    memberContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    const ownerPage = await ownerContext.newPage();
    const memberPage = await memberContext.newPage();
    trackApi(ownerPage, 'owner', apiEvents, pageErrors);
    trackApi(memberPage, 'member', apiEvents, pageErrors);
    await Promise.all([
      ownerPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 }),
      memberPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 }),
    ]);
    await Promise.all([enableSemantics(ownerPage), enableSemantics(memberPage)]);
    await Promise.all([button(ownerPage, 'Connect securely'), button(memberPage, 'Connect securely')]);

    setStage('register initial Vault Owner');
    await fill(ownerPage, 'Server URL', baseUrl);
    await click(ownerPage, 'Connect securely');
    await field(ownerPage, 'Owner email');
    const bootstrapResult = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrapResult.error && bootstrapResult.status === 0, 'isolated bootstrap failed');
    bootstrapToken = (bootstrapResult.stdout || '').trim().split(/\s+/).at(-1);
    bootstrapResult.stdout = '';
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap credential is unavailable');
    await fill(ownerPage, 'Owner email', ownerUsername, { profile: 'owner', pageErrors });
    await fill(ownerPage, 'Master password · 12+ characters', ownerPassword, { profile: 'owner', pageErrors });
    await fill(ownerPage, 'Confirm master password', ownerPassword, { profile: 'owner', pageErrors });
    await fill(ownerPage, 'One-time bootstrap token', bootstrapToken, { profile: 'owner', pageErrors });
    await fill(ownerPage, 'Device name', 'Transfer test owner browser', { profile: 'owner', pageErrors });
    await fill(ownerPage, 'First Vault', 'Ownership transfer acceptance', { profile: 'owner', pageErrors });
    let after = apiEvents.length - 1;
    await click(ownerPage, 'Create owner account');
    bootstrapToken = undefined;
    await waitWorkspace(ownerPage);
    const ownerRegistration = await waitEvent(apiEvents, 'owner', 'register', after);
    assertStatus(ownerRegistration, 200, 'owner_registration');
    const ownerRegistrationBody = await ownerRegistration.payloadPromise;
    ownerAccountId = ownerRegistrationBody?.account_id;
    ownerDeviceId = ownerRegistrationBody?.device_id;
    assertThat(typeof ownerAccountId === 'string' && typeof ownerDeviceId === 'string',
      'owner registration did not return opaque account and device IDs');

    setStage('register invited member profile');
    accountInvitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'instance account invitation');
    await fill(memberPage, 'Server URL', baseUrl);
    await click(memberPage, 'Connect securely');
    await field(memberPage, 'Email or username');
    await click(memberPage, 'Have an instance invitation? Create account');
    await field(memberPage, 'Email on the invitation');
    await fill(memberPage, 'Email on the invitation', memberUsername);
    await fill(memberPage, 'Master password · 12+ characters', memberPassword);
    await fill(memberPage, 'Confirm master password', memberPassword);
    await fill(memberPage, 'Instance invitation token', accountInvitationToken);
    accountInvitationToken = undefined;
    await fill(memberPage, 'Device name', 'Transfer test member browser');
    await fill(memberPage, 'First Vault', 'Member personal Vault');
    after = apiEvents.length - 1;
    await click(memberPage, 'Create invited account');
    await waitWorkspace(memberPage);
    const memberRegistration = await waitEvent(apiEvents, 'member', 'register', after);
    assertStatus(memberRegistration, 200, 'member_registration');
    const memberRegistrationBody = await memberRegistration.payloadPromise;
    memberAccountId = memberRegistrationBody?.account_id;
    assertThat(typeof memberAccountId === 'string' && memberAccountId !== ownerAccountId,
      'member registration did not return a distinct opaque account ID');

    setStage('member opens signed public device card');
    await click(memberPage, 'Settings');
    await (await button(memberPage, 'Copy signed share request')).scrollIntoViewIfNeeded();
    await click(memberPage, 'Copy signed share request');
    setStage('member copies signed public device card');
    const shareCard = await copyClipboard(memberPage, 'Copy');
    let parsedCard;
    try { parsedCard = JSON.parse(shareCard); } catch (_) { throw new Error('share request clipboard was not JSON'); }
    assertThat(parsedCard.format === 'atermius-vault-share-request-v1' &&
      typeof parsedCard.account_id === 'string' && typeof parsedCard.device?.device_id === 'string',
    'share request did not contain its expected signed public identity');
    setStage('Owner creates one-time Vault invitation');
    await click(ownerPage, 'Settings');
    await (await button(ownerPage, 'Invite member')).scrollIntoViewIfNeeded();
    await click(ownerPage, 'Invite member');
    await paste(ownerPage, 'Public Device Card JSON', shareCard, { profile: 'owner', pageErrors });
    await click(ownerPage, 'Verify and review');
    await waitFor(() => ownerPage.getByText('Confirm target:', { exact: false }).isVisible());
    assertThat(await ownerPage.getByText(memberUsername, { exact: true }).count() === 0,
      'public device card review unexpectedly exposed the member login name');
    after = apiEvents.length - 1;
    await click(ownerPage, 'Sign and create invitation');
    const invite = await waitEvent(apiEvents, 'owner', 'vault-invite', after);
    assertStatus(invite, 200, 'vault_invitation');
    vaultInvitationToken = await copyClipboard(ownerPage, 'Copy token');
    assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInvitationToken), 'Vault invitation token format was invalid');

    setStage('member accepts Editor invitation');
    await click(memberPage, 'Settings');
    await click(memberPage, 'Accept invitation');
    await fill(memberPage, 'Invitation token', vaultInvitationToken);
    vaultInvitationToken = undefined;
    after = apiEvents.length - 1;
    await click(memberPage, 'Accept and unlock Vault');
    await waitWorkspace(memberPage);
    assertStatus(await waitEvent(apiEvents, 'member', 'vault-accept', after), 200, 'vault_invitation_accept');
    await waitFor(async () => /editor\s*·\s*key epoch/i.test(await memberPage.locator('body').innerText()), 45000);

    setStage('Owner opens active Editor member row');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Manage Vault members');
    await waitFor(async () => (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Active'));
    assertThat((await staticMembershipSemantics(ownerPage)).includes('Transfer ownership'),
      'active Editor row did not expose ownership transfer');

    setStage('cancel ownership transfer confirmation');
    const transferCountBeforeCancel = apiEvents.filter((event) =>
      event.profile === 'owner' && event.route === 'ownership-transfer').length;
    await click(ownerPage, 'Transfer ownership');
    await ownerPage.getByText('Transfer Vault ownership?', { exact: true })
      .waitFor({ state: 'visible' });
    await click(ownerPage, 'Keep current Owner');
    await waitFor(async () => await ownerPage.getByText('Transfer Vault ownership?', {
      exact: true,
    }).count() === 0);
    await ownerPage.waitForTimeout(300);
    const transferCountAfterCancel = apiEvents.filter((event) =>
      event.profile === 'owner' && event.route === 'ownership-transfer').length;
    assertThat(transferCountAfterCancel === transferCountBeforeCancel,
      'canceling the ownership dialog sent a transfer request');
    console.log('assert: ownership_transfer_cancel_has_no_request=true');

    setStage('confirm ownership transfer and key rotation');
    await click(ownerPage, 'Transfer ownership');
    await ownerPage.getByText('Transfer Vault ownership?', { exact: true })
      .waitFor({ state: 'visible' });
    const transferStart = apiEvents.length - 1;
    await click(ownerPage, 'Transfer and rotate key');
    const transferEvent = await waitEvent(apiEvents, 'owner', 'ownership-transfer', transferStart);
    assertStatus(transferEvent, 200, 'ownership_transfer');
    await waitFor(async () => await ownerPage.getByText(
      'Members · Ownership transfer acceptance', { exact: true },
    ).count() === 0);
    console.log('assert: ownership_transfer_confirmed=true');

    setStage('verify former Owner Editor capability');
    await click(ownerPage, 'Settings');
    setStage('former Owner waits for Owner-only controls to disappear');
    const formerOwnerCapabilities = {
      profile: 'owner',
      point: 'former-owner-management-capability',
      invite_button_visible: true,
      manage_button_visible: true,
    };
    safeUiTrace.push(formerOwnerCapabilities);
    await waitFor(async () => {
      formerOwnerCapabilities.invite_button_visible = await buttonIsVisible(ownerPage, 'Invite member');
      formerOwnerCapabilities.manage_button_visible = await buttonIsVisible(ownerPage, 'Manage Vault members');
      return !formerOwnerCapabilities.invite_button_visible && !formerOwnerCapabilities.manage_button_visible;
    }, 45000);
    assertThat(!formerOwnerCapabilities.invite_button_visible && !formerOwnerCapabilities.manage_button_visible,
    'former Owner retained an Owner-only member-management control');
    setStage('former Owner opens Hosts');
    await click(ownerPage, 'Hosts');
    setStage('former Owner confirms Host write capability');
    const formerOwnerAddHost = await button(ownerPage, 'Add host');
    const formerOwnerHostCapability = {
      profile: 'owner',
      point: 'former-owner-host-write-capability',
      add_host_enabled: false,
    };
    safeUiTrace.push(formerOwnerHostCapability);
    await waitFor(async () => {
      formerOwnerHostCapability.add_host_enabled = await formerOwnerAddHost.isEnabled();
      return formerOwnerHostCapability.add_host_enabled;
    }, 45000);
    assertThat(formerOwnerHostCapability.add_host_enabled, 'former Owner Editor could not add a Host');
    console.log('assert: former_owner_is_editor_with_write_capability=true');

    setStage('verify new Owner management and write capability');
    await click(memberPage, 'Settings');
    const newOwnerCapabilities = {
      profile: 'member',
      point: 'new-owner-management-capability',
      invite_button_visible: false,
      manage_button_visible: false,
    };
    safeUiTrace.push(newOwnerCapabilities);
    await waitFor(async () => {
      newOwnerCapabilities.invite_button_visible = await buttonIsVisible(memberPage, 'Invite member');
      newOwnerCapabilities.manage_button_visible = await buttonIsVisible(memberPage, 'Manage Vault members');
      return newOwnerCapabilities.invite_button_visible && newOwnerCapabilities.manage_button_visible;
    }, 60000);
    assertThat(await buttonIsVisible(memberPage, 'Invite member') &&
      await buttonIsVisible(memberPage, 'Manage Vault members'),
    'new Owner did not receive Owner-only member-management controls');
    await click(memberPage, 'Manage Vault members');
    await waitFor(async () => (await staticMembershipSemantics(memberPage)).includes('OWNER · Active'));
    await click(memberPage, 'Close');
    await click(memberPage, 'Hosts');
    const newOwnerAddHost = await button(memberPage, 'Add host');
    await waitFor(async () => await newOwnerAddHost.isEnabled(), 45000);
    console.log('assert: new_owner_has_management_and_write_capability=true');

    setStage('render Vault ownership and membership audit rows');
    const accountAuditStart = apiEvents.length - 1;
    await click(memberPage, 'Audit log');
    const accountAudit = await waitEvent(apiEvents, 'member', 'audit', accountAuditStart);
    assertStatus(accountAudit, 200, 'new_owner_account_audit');
    const auditStart = apiEvents.length - 1;
    await memberPage.getByText('当前 Vault', { exact: true }).click();
    const auditEvent = await waitEvent(apiEvents, 'member', 'audit', auditStart);
    assertStatus(auditEvent, 200, 'new_owner_vault_audit');
    const auditPage = await auditEvent.payloadPromise;
    const vaultEvents = auditPage.events.filter((event) => event.scope === 'vault');
    const roleChanges = vaultEvents.filter((event) => event.action === 'vault.member_role_changed');
    const ownershipChanges = vaultEvents.filter((event) => event.action === 'vault.ownership_transferred');
    const keyRotations = vaultEvents.filter((event) => event.action === 'vault.key_rotated');
    assertThat(roleChanges.length === 2 &&
      new Set(roleChanges.map((event) => event.resource_id)).size === 2 &&
      roleChanges.every((event) => event.resource_type === 'membership' &&
        event.result === 'success' && event.source === 'api' &&
        event.actor_user_id === ownerAccountId && event.actor_device_id === ownerDeviceId) &&
      new Set(roleChanges.map((event) => event.resource_id)).has(ownerAccountId) &&
      new Set(roleChanges.map((event) => event.resource_id)).has(memberAccountId),
    'Vault audit did not show the two committed membership role changes');
    assertThat(ownershipChanges.length === 1 &&
      ownershipChanges[0].resource_id === memberAccountId &&
      ownershipChanges[0].actor_user_id === ownerAccountId &&
      ownershipChanges[0].actor_device_id === ownerDeviceId &&
      ownershipChanges[0].result === 'success' && ownershipChanges[0].source === 'api',
    'Vault audit did not show the ownership transfer actor and target');
    assertThat(keyRotations.length === 1 &&
      keyRotations[0].actor_user_id === ownerAccountId &&
      keyRotations[0].result === 'success' && keyRotations[0].source === 'api',
    'Vault audit did not show the key rotation committed with ownership transfer');
    const auditUiCounts = {
      profile: 'member',
      point: 'vault-audit-rendered-action-counts',
      membership_role_change_rows: 0,
      ownership_transfer_rows: 0,
      key_rotation_rows: 0,
    };
    safeUiTrace.push(auditUiCounts);
    for (const [label, expectedCount, resultKey] of [
      ['成员权限已更改', 2, 'membership_role_change_rows'],
      ['Vault 所有权已转移', 1, 'ownership_transfer_rows'],
      ['Vault 密钥已轮换', 1, 'key_rotation_rows'],
    ]) {
      const renderedText = memberPage.getByText(label, { exact: false });
      await waitFor(async () => {
        auditUiCounts[resultKey] = await renderedText.count();
        return auditUiCounts[resultKey] >= expectedCount;
      });
      assertThat(auditUiCounts[resultKey] >= expectedCount,
        'Vault audit UI omitted a transfer action row');
    }
    console.log('assert: vault_membership_ownership_and_key_audit_rendered=true');
    assertThat(pageErrors.count === 0, 'Flutter reported a page runtime error');
  } catch (error) {
    await preserveFailureScreenshot();
    throw error;
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async (error) => {
  console.error(`stage: failed (${stage}); reason=${safeFailureMessage(error)}`);
  if (safeApiTrace.length > 0) {
    console.error(`api: ${JSON.stringify(safeApiTrace)}`);
  }
  if (safeUiTrace.length > 0) {
    console.error(`ui: ${JSON.stringify(safeUiTrace)}`);
  }
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
