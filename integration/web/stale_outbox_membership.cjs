/*
 * WEB-STALE-OUTBOX-01: an active Editor keeps a Host edit in its encrypted
 * local outbox while the Owner adds a pending member (membership version only).
 * The Editor stays open across the outage, reloads current membership in-place
 * after the stale push is rejected, recovers/re-envelopes the edit, and the
 * Owner observes the resulting Host through normal sync.
 *
 * All accounts, browser state, server data, and Host values are disposable.
 * This test never opens an SSH connection and uses a documentation-only IP.
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
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const OWNER_USERNAME = `stale-owner-${RUN_ID.slice(0, 8)}@example.test`;
const EDITOR_USERNAME = `stale-editor-${RUN_ID.slice(0, 8)}@example.test`;
const INVITEE_USERNAME = `stale-invitee-${RUN_ID.slice(0, 8)}@example.test`;
const OWNER_PASSWORD = `Owner-${crypto.randomBytes(24).toString('base64url')}`;
const EDITOR_PASSWORD = `Editor-${crypto.randomBytes(24).toString('base64url')}`;
const INVITEE_PASSWORD = `Invitee-${crypto.randomBytes(24).toString('base64url')}`;
const BASE_HOST_NAME = `stale-base-${RUN_ID.slice(0, 8)}`;
const EDITED_HOST_NAME = `stale-recovered-${RUN_ID.slice(0, 8)}`;
const HOST_ADDRESS = '192.0.2.44';
const HOST_USERNAME = `test-${RUN_ID.slice(0, 6)}`;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let ownerContext;
let editorContext;
let inviteeContext;
let bootstrapToken;
let accountTokens = [];
let cleanupPromise;
let cleanupFailed = false;
const pageErrors = [];
const pushEvents = [];
const inviteEvents = [];
const membershipRefreshEvents = [];
const networkFailures = [];
let traceSequence = 0;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
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
  await new Promise((resolve, reject) => listener.close((error) =>
    error ? reject(error) : resolve()));
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
      // Keep polling during process startup.
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

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline && processGroupHasLiveMembers(groupId)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  const killDeadline = Date.now() + 2500;
  while (Date.now() < killDeadline && processGroupHasLiveMembers(groupId)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (processGroupHasLiveMembers(groupId)) throw new Error('server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    accountTokens = [];
    for (const context of [ownerContext, editorContext, inviteeContext]) {
      if (context) await context.close().catch(() => {});
    }
    if (browser) await browser.close().catch(() => {});
    try {
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupFailed = true;
      } catch (_) {
        cleanupFailed = true;
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function waitFor(predicate, timeoutMs = 25000, message = 'expected browser state did not appear') {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = [];
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const item = locator.nth(index);
      if (await item.isVisible()) visible.push(item);
    }
    assertThat(visible.length <= 1, `form field '${label}' was ambiguous`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`form field '${label}' was not visible`);
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible()) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button '${label}' was not found`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 45 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      return;
    }
  }
  throw new Error(`form field '${label}' did not retain its value`);
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(250);
  if (await locator.inputValue() !== value) await locator.fill(value);
  assertThat(await locator.inputValue() === value, `form field '${label}' rejected test data`);
}

async function enableSemantics(page) {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  30000, 'Flutter Web semantics did not start');
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.locator('flt-semantics').count().then((count) => count > 0),
    15000, 'Flutter Web semantics tree did not appear');
}

async function waitWorkspace(page, timeoutMs = 45000) {
  await (await button(page, 'Settings')).waitFor({ state: 'visible', timeout: timeoutMs });
}

function cliToken(args, environment, label) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: environment,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `${label} issuance failed`);
  const token = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(token, `${label} was unavailable`);
  return token;
}

function routeKind(request) {
  let pathname;
  try { pathname = new URL(request.url()).pathname; } catch (_) { return null; }
  if (request.method() === 'GET' && pathname === '/api/v1/vaults') return 'vault-list';
  if (request.method() === 'GET' && /^\/api\/v1\/vaults\/[^/]+\/membership$/.test(pathname)) {
    return 'membership-chain';
  }
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (/^\/api\/v1\/vaults\/[^/]+\/invitations$/.test(pathname)) return 'invite';
  if (/^\/api\/v1\/invitations\/accept$/.test(pathname)) return 'accept';
  return null;
}

function trackPage(page, profile) {
  const pendingRequests = new WeakMap();
  page.on('pageerror', () => pageErrors.push(profile));
  page.on('requestfailed', (request) => {
    if (request.failure()?.errorText === 'net::ERR_INTERNET_DISCONNECTED') {
      networkFailures.push(profile);
    }
  });
  page.on('request', (request) => {
    const kind = routeKind(request);
    if (kind === 'vault-list' || kind === 'membership-chain') {
      const event = {
        profile,
        kind,
        sequence: ++traceSequence,
        status: null,
        responseProcessed: false,
      };
      membershipRefreshEvents.push(event);
      pendingRequests.set(request, { kind, event });
      return;
    }
    if (!kind || request.method() !== 'POST') return;
    let body = {};
    try { body = request.postDataJSON() || {}; } catch (_) {}
    if (kind === 'push') {
      const operations = Array.isArray(body.operations) ? body.operations : [];
      const event = {
        profile,
        operations: operations.map((envelope) => {
          const header = envelope?.header || {};
          return {
            recordId: header.record_id,
            revisionId: header.revision_id,
            baseRevisionId: header.base_revision_id ?? null,
            operation: header.operation,
            keyEpoch: header.key_epoch,
            membershipVersion: header.membership_version,
            opId: header.op_id,
            envelopeDigest: crypto.createHash('sha256')
              .update(JSON.stringify(envelope)).digest('hex'),
            envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
              'ciphertext,header,nonce,signature',
            ciphertextFieldsPresent: ['ciphertext', 'nonce', 'signature'].every((key) =>
              typeof envelope?.[key] === 'string' && envelope[key].length > 0),
          };
        }),
        containsHostPlaintext: [BASE_HOST_NAME, EDITED_HOST_NAME, HOST_ADDRESS, HOST_USERNAME]
          .some((marker) => JSON.stringify(body).includes(marker)),
        sequence: ++traceSequence,
        status: null,
        responseProcessed: false,
        errorCode: null,
      };
      pushEvents.push(event);
      pendingRequests.set(request, { kind, event });
    } else if (kind === 'invite') {
      pendingRequests.set(request, {
        kind,
        event: {
          profile,
          membershipVersion: null,
          status: null,
          responseProcessed: false,
          sequence: ++traceSequence,
        },
      });
      const event = pendingRequests.get(request).event;
      inviteEvents.push(event);
      try {
        const responseBody = request.postDataJSON();
        event.requestHasTargetIdentity = Boolean(responseBody?.recipient_device_id);
      } catch (_) {
        event.requestHasTargetIdentity = false;
      }
    } else {
      pendingRequests.set(request, { kind, event: null });
    }
  });
  page.on('response', async (response) => {
    const request = response.request();
    const pending = pendingRequests.get(request);
    if (!pending) return;
    if (pending.event) pending.event.status = response.status();
    if (pending.kind === 'invite' && pending.event) {
      try {
        const body = await response.json();
        pending.event.membershipVersion = String(body?.membership_version ?? '');
        pending.event.vaultIdValid = typeof body?.vault_id === 'string' &&
          /^[0-9a-f-]{36}$/i.test(body.vault_id);
        pending.event.tokenPresent = typeof body?.token === 'string';
      } catch (_) {}
    } else if (pending.kind === 'push' && pending.event && response.status() >= 400) {
      try {
        const body = await response.json();
        pending.event.errorCode = typeof body?.error?.code === 'string'
          ? body.error.code : null;
      } catch (_) {}
    }
    if (pending.event) pending.event.responseProcessed = true;
  });
}

async function waitApiEvent(events, predicate, after = -1, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.slice(after + 1).find((item) => predicate(item) && item.responseProcessed);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected API response was not observed');
}

async function waitSemanticText(page, text, timeoutMs = 20000) {
  await waitFor(() => page.evaluate((expected) => {
    const values = [document.body.innerText, ...[...document.querySelectorAll('flt-semantics')]
      .flatMap((node) => [node.innerText || '', node.getAttribute('aria-label') || ''])];
    return values.some((value) => value.includes(expected));
  }, text), timeoutMs, 'expected visible workspace text did not appear');
}

async function waitHost(page, name, expected = true, timeoutMs = 25000) {
  const prefix = `Host: ${name}; `;
  await waitFor(() => page.locator('flt-semantics[role="group"]').evaluateAll((nodes, label) =>
    nodes.some((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 &&
        (node.getAttribute('aria-label') || '').startsWith(label);
    }), prefix).then((visible) => visible === expected), timeoutMs,
  `Host visibility did not become ${expected}`);
}

async function pendingCount(page) {
  return page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    for (const node of nodes) {
      const value = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      if (!/Pending sync/i.test(value)) continue;
      const match = value.match(/Pending sync[^0-9]{0,60}(\d+)/i);
      if (match) return Number(match[1]);
    }
    const buttons = nodes.filter((node) => node.getAttribute('role') === 'button');
    for (const node of buttons) {
      const value = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
      const match = value.match(/(?:pending\s*(\d+)|(\d+)\s*pending)/i);
      if (match) return Number(match[1] || match[2]);
      if (/\bIdle\b/.test(value)) return 0;
    }
    return null;
  }).catch(() => null);
}

async function waitPendingAtLeast(page, expected) {
  let last = null;
  await waitFor(async () => {
    last = await pendingCount(page);
    return last !== null && last >= expected;
  }, 15000, 'offline Host edit did not remain visibly queued');
  return last;
}

async function clearClipboard(page) {
  await page.evaluate(async () => navigator.clipboard.writeText('')).catch(() => {});
}

async function registerOwner(page, baseUrl, environment) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
  await field(page, 'Owner email');
  const result = spawnSync(SERVER_BINARY, ['bootstrap'], {
    cwd: ROOT,
    env: environment,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'disposable bootstrap issuance failed');
  bootstrapToken = (result.stdout || '').trim().split(/\s+/).at(-1);
  result.stdout = '';
  assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
    'disposable bootstrap credential was unavailable');
  await fill(page, 'Owner email', OWNER_USERNAME);
  await fill(page, 'Master password · 12+ characters', OWNER_PASSWORD);
  await fill(page, 'Confirm master password', OWNER_PASSWORD);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Stale outbox Owner fixture');
  await fill(page, 'First Vault', `Stale outbox Vault ${RUN_ID.slice(0, 8)}`);
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await waitWorkspace(page);
}

async function registerInvitedAccount(page, baseUrl, environment, username, password, deviceName) {
  const token = cliToken(['create-account-invite', '--username', username],
    environment, 'disposable account invitation');
  accountTokens.push(token);
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', username);
  await fill(page, 'Master password · 12+ characters', password);
  await fill(page, 'Confirm master password', password);
  await fill(page, 'Instance invitation token', token);
  accountTokens = accountTokens.filter((candidate) => candidate !== token);
  await fill(page, 'Device name', deviceName);
  await fill(page, 'First Vault', `Personal ${deviceName}`);
  await click(page, 'Create invited account');
  await waitWorkspace(page);
}

async function copyDeviceCard(page) {
  await click(page, 'Settings');
  await (await button(page, 'Copy signed share request')).scrollIntoViewIfNeeded();
  await click(page, 'Copy signed share request');
  await click(page, 'Copy');
  const value = await page.evaluate(async () => navigator.clipboard.readText());
  let parsed;
  try { parsed = JSON.parse(value); } catch (_) { throw new Error('share request was not JSON'); }
  assertThat(parsed?.format === 'atermius-vault-share-request-v1' &&
    typeof parsed?.account_id === 'string' && typeof parsed?.device?.device_id === 'string',
  'share request omitted its signed test device identity');
  await clearClipboard(page);
  return value;
}

async function inviteShareCard(ownerPage, cardJson) {
  await click(ownerPage, 'Settings');
  await click(ownerPage, 'Invite member');
  await paste(ownerPage, 'Public Device Card JSON', cardJson);
  await click(ownerPage, 'Verify and review');
  await waitSemanticText(ownerPage, 'Confirm target:');
  const eventStart = inviteEvents.length;
  await click(ownerPage, 'Sign and create invitation');
  const event = await waitApiEvent(inviteEvents, (item) => item.profile === 'owner', eventStart - 1);
  assertThat(event.status === 200 && event.requestHasTargetIdentity &&
    event.vaultIdValid && /^\d+$/.test(event.membershipVersion || '') && event.tokenPresent,
  'Owner membership invitation response was incomplete');
  await click(ownerPage, 'Copy token');
  // The invitation is intentionally left pending. Read only to ensure the UI
  // completed its copy action, then clear browser clipboard and local value.
  let invitationToken = await ownerPage.evaluate(async () => navigator.clipboard.readText());
  assertThat(typeof invitationToken === 'string' && invitationToken.length >= 40,
    'one-time invitation token was not exposed to the disposable fixture');
  await clearClipboard(ownerPage);
  const result = { event, token: invitationToken };
  invitationToken = undefined;
  return result;
}

async function acceptVaultInvitation(page, token) {
  await click(page, 'Settings');
  await click(page, 'Accept invitation');
  await fill(page, 'Invitation token', token);
  await click(page, 'Accept and unlock Vault');
  await waitWorkspace(page);
  await click(page, 'Settings');
  await waitFor(() => page.locator('body').innerText()
    .then((text) => /editor\s*·\s*key epoch/i.test(text)),
  30000, 'accepted profile did not show active Editor membership');
  await click(page, 'Hosts');
}

function hostCard(page, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('group', { name: new RegExp(`^Host: ${escaped}; `) }).first();
}

async function addHost(page) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitSemanticText(page, 'Add a host');
  await fill(page, 'Display name', BASE_HOST_NAME);
  await fill(page, 'Hostname or IP', HOST_ADDRESS);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', HOST_USERNAME);
  await click(page, 'Save encrypted host');
  await waitHost(page, BASE_HOST_NAME, true);
}

async function editHostOffline(page) {
  const card = hostCard(page, BASE_HOST_NAME);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitSemanticText(page, 'Edit host');
  await fill(page, 'Display name', EDITED_HOST_NAME);
  await click(page, 'Save encrypted host');
  await waitHost(page, EDITED_HOST_NAME, true);
  await waitHost(page, BASE_HOST_NAME, false);
}

async function syncNow(page) {
  const buttonLabels = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/;
  const syncButton = page.getByRole('button', { name: buttonLabels }).first();
  await selectServerModeIfChooser(page, syncButton);
  await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  if (await syncButton.isEnabled()) {
    await syncButton.click();
    return true;
  }
  return false;
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-stale-outbox-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const port = await unusedLoopbackPort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: 'off',
  };

  try {
    setStage('start disposable loopback server');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);

    setStage('launch isolated Owner, Editor, and invitee browser profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    const contextOptions = {
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    };
    ownerContext = await browser.newContext(contextOptions);
    editorContext = await browser.newContext(contextOptions);
    inviteeContext = await browser.newContext(contextOptions);
    const ownerPage = await ownerContext.newPage();
    const editorPage = await editorContext.newPage();
    const inviteePage = await inviteeContext.newPage();
    let editorMainFrameNavigations = 0;
    editorPage.on('framenavigated', (frame) => {
      if (frame === editorPage.mainFrame()) editorMainFrameNavigations += 1;
    });
    trackPage(ownerPage, 'owner');
    trackPage(editorPage, 'editor');
    trackPage(inviteePage, 'invitee');
    await Promise.all([ownerPage, editorPage, inviteePage].map((page) =>
      page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 })));
    await Promise.all([ownerPage, editorPage, inviteePage].map(enableSemantics));

    setStage('register disposable Vault Owner');
    await registerOwner(ownerPage, baseUrl, serverEnv);
    setStage('register disposable Editor and invitee accounts');
    await Promise.all([
      registerInvitedAccount(editorPage, baseUrl, serverEnv, EDITOR_USERNAME,
        EDITOR_PASSWORD, 'Stale outbox Editor fixture'),
      registerInvitedAccount(inviteePage, baseUrl, serverEnv, INVITEE_USERNAME,
        INVITEE_PASSWORD, 'Stale outbox invitee fixture'),
    ]);

    setStage('invite Editor and activate its shared Vault membership');
    const editorCard = await copyDeviceCard(editorPage);
    const editorInvitation = await inviteShareCard(ownerPage, editorCard);
    await acceptVaultInvitation(editorPage, editorInvitation.token);
    editorInvitation.token = undefined;
    await clearClipboard(editorPage);

    setStage('create and sync baseline Host to Editor');
    await addHost(ownerPage);
    const baselineCreate = await waitApiEvent(pushEvents, (item) =>
      item.profile === 'owner' && item.status === 200 &&
      item.operations.some((op) => op.operation === 'create'), -1, 45000);
    const baselineHost = baselineCreate.operations.find((op) => op.operation === 'create');
    assertThat(baselineHost && baselineHost.envelopeShapeValid &&
      baselineHost.ciphertextFieldsPresent && !baselineCreate.containsHostPlaintext &&
      /^\d+$/.test(String(baselineHost.keyEpoch)) &&
      /^\d+$/.test(String(baselineHost.membershipVersion)),
    'baseline Host commit did not use an opaque encrypted envelope');
    await click(editorPage, 'Hosts');
    await waitHost(editorPage, BASE_HOST_NAME, true);
    const editorNavigationBaseline = editorMainFrameNavigations;

    setStage('queue an offline Host edit from active Editor profile');
    await editorContext.setOffline(true);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === false),
      5000, 'Chromium did not expose the Editor profile as offline');
    await editHostOffline(editorPage);
    const pendingBefore = await waitPendingAtLeast(editorPage, 1);
    console.log('assert: offline_editor_outbox_retained=true');

    setStage('Owner creates a membership-only pending invitation');
    const inviteeCard = await copyDeviceCard(inviteePage);
    const previousInviteCount = inviteEvents.length;
    const pendingMemberInvitation = await inviteShareCard(ownerPage, inviteeCard);
    const membershipInvitation = pendingMemberInvitation.event;
    pendingMemberInvitation.token = undefined;
    assertThat(inviteEvents.length > previousInviteCount &&
      Number(membershipInvitation.membershipVersion) > Number(baselineHost.membershipVersion),
    'Owner invitation did not advance the signed membership version');
    assertThat(membershipInvitation.status === 200,
      'Owner could not create the disposable membership invitation');

    setStage('restore Editor network and trigger same-session sync');
    const pushStart = pushEvents.length;
    await editorContext.setOffline(false);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === true),
      5000, 'Chromium did not restore the Editor network');
    assertThat(!editorPage.isClosed() && editorMainFrameNavigations === editorNavigationBaseline,
      'Editor page navigated during the offline membership change');
    const visibleSyncTriggered = await syncNow(editorPage);

    setStage('observe old-envelope membership conflict');
    const stalePush = await waitApiEvent(pushEvents, (event) =>
      event.profile === 'editor' && event.status === 409 &&
      event.errorCode === 'MEMBERSHIP_VERSION_CONFLICT' &&
      event.operations.some((op) => op.recordId === baselineHost.recordId &&
        op.operation === 'update'), pushStart - 1, 30000);
    const staleOperation = stalePush.operations.find((op) =>
      op.recordId === baselineHost.recordId && op.operation === 'update');
    assertThat(staleOperation.membershipVersion === baselineHost.membershipVersion &&
      staleOperation.keyEpoch === baselineHost.keyEpoch,
    'Editor did not first submit its queued envelope under the stale membership version');

    setStage('observe current-version recovery retry');
    const recoveredPush = await waitApiEvent(pushEvents, (event) =>
      event.profile === 'editor' && event.status === 200 &&
      event.operations.some((op) => op.recordId === baselineHost.recordId &&
        op.operation === 'update' &&
        op.membershipVersion === membershipInvitation.membershipVersion &&
        op.keyEpoch === baselineHost.keyEpoch), pushStart - 1, 90000);
    const recoveredOperation = recoveredPush.operations.find((op) =>
      op.recordId === baselineHost.recordId && op.operation === 'update' &&
      op.membershipVersion === membershipInvitation.membershipVersion &&
      op.keyEpoch === baselineHost.keyEpoch);
    const refreshesBetweenAttempts = membershipRefreshEvents.filter((event) =>
      event.profile === 'editor' && event.sequence > stalePush.sequence &&
      event.sequence < recoveredPush.sequence && event.responseProcessed && event.status === 200);
    assertThat(refreshesBetweenAttempts.some((event) => event.kind === 'vault-list') &&
      refreshesBetweenAttempts.some((event) => event.kind === 'membership-chain'),
    'Editor retried without reloading the current Vault descriptor and signed membership chain');
    assertThat(recoveredOperation.envelopeShapeValid &&
      recoveredOperation.ciphertextFieldsPresent &&
      recoveredOperation.envelopeDigest !== staleOperation.envelopeDigest &&
      !recoveredPush.containsHostPlaintext,
    'Editor did not replace the stale envelope with a newly encrypted current-version operation');
    await waitFor(async () => (await pendingCount(editorPage)) === 0,
      30000, 'Editor still reported a pending operation after recovery');

    setStage('verify Owner receives the recovered encrypted Host record');
    await click(ownerPage, 'Hosts');
    await waitHost(ownerPage, EDITED_HOST_NAME, true, 45000);
    await waitHost(ownerPage, BASE_HOST_NAME, false, 10000);
    assertThat(pageErrors.length === 0,
      'Flutter Web raised a runtime error in an isolated profile');

    console.log('WEB-STALE-OUTBOX-01 passed', JSON.stringify({
      profiles: 3,
      inviteAdvancedMembershipVersion: true,
      editorOutboxWasPendingOffline: pendingBefore >= 1,
      editorPageStayedOpenAcrossOutage: true,
      visibleSyncActionTriggered: visibleSyncTriggered,
      staleEnvelopeRejectedWithMembershipConflict: true,
      vaultDescriptorAndSignedMembershipReloaded: true,
      sameSessionRecoveredAndReencrypted: true,
      replacementUsesCurrentMembershipVersion: true,
      keyEpochStayedStable: true,
      ownerObservedRecoveredHost: true,
      pushedEnvelopeWasCiphertextOnly: true,
      runtimeErrorCount: pageErrors.length,
    }));
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'disposable server/browser fixtures did not all clean up');
}

main().catch(async (error) => {
  const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  const safeDiagnostics = {
    pushes: pushEvents.slice(-12).map((event) => ({
      profile: event.profile,
      sequence: event.sequence,
      status: event.status,
      errorCode: event.errorCode,
      responseProcessed: event.responseProcessed,
      operations: event.operations.map((operation) => ({
        operation: operation.operation,
        keyEpoch: operation.keyEpoch,
        membershipVersion: operation.membershipVersion,
        envelopeDigest: operation.envelopeDigest,
      })),
    })),
    membershipRefreshes: membershipRefreshEvents.slice(-12).map((event) => ({
      profile: event.profile,
      kind: event.kind,
      sequence: event.sequence,
      status: event.status,
      responseProcessed: event.responseProcessed,
    })),
    invitations: inviteEvents.slice(-8).map((event) => ({
      profile: event.profile,
      sequence: event.sequence,
      status: event.status,
      membershipVersion: event.membershipVersion,
      responseProcessed: event.responseProcessed,
      targetIdentityPresent: event.requestHasTargetIdentity,
      tokenPresent: event.tokenPresent,
    })),
    browserStates: await Promise.all([
      ['owner', ownerPage],
      ['editor', editorPage],
      ['invitee', inviteePage],
    ].map(async ([profile, page]) => {
      const closed = !page || page.isClosed();
      return {
        profile,
        closed,
        editorMembershipVisible: !closed
          ? await page.evaluate(() =>
              /editor\s*·\s*key epoch/i.test(document.body.innerText),
            ).catch(() => false)
          : false,
      };
    })),
    networkFailureCount: networkFailures.length,
    runtimeErrorCount: pageErrors.length,
  };
  await cleanup();
  console.error(`WEB-STALE-OUTBOX-01 failed at ${stage} (${errorClass}); fixture values omitted`);
  console.error(`safe diagnostics: ${JSON.stringify(safeDiagnostics)}`);
  if (!cleanupFailed) process.exitCode = 1;
  else process.exitCode = 2;
});
