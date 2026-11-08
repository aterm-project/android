/*
 * WEB-STALE-OUTBOX-EPOCH-01: an active Editor keeps a Host edit in its encrypted
 * local outbox while the Owner changes another active member's role, rotating
 * the Vault epoch. The Editor stays open across the outage, reloads its current
 * descriptor, signed membership chain, and epoch key envelope after the stale
 * push is rejected, re-envelopes the edit, and the Owner observes it by sync.
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
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const CREDENTIAL_ONLY = process.argv.includes('--credential-only');
const MULTI_RECORD = process.argv.includes('--multi-record');
const TEST_ID = CREDENTIAL_ONLY
  ? 'WEB-STALE-CREDENTIAL-EPOCH-01'
  : MULTI_RECORD
  ? 'WEB-STALE-MULTI-RECORD-EPOCH-01'
  : 'WEB-STALE-OUTBOX-EPOCH-01';
const RUN_ID = crypto.randomUUID();
const OWNER_USERNAME = `stale-epoch-owner-${RUN_ID.slice(0, 8)}@example.test`;
const EDITOR_USERNAME = `stale-epoch-editor-${RUN_ID.slice(0, 8)}@example.test`;
const ROTATED_MEMBER_USERNAME = `stale-epoch-member-${RUN_ID.slice(0, 8)}@example.test`;
const OWNER_PASSWORD = `Owner-${crypto.randomBytes(24).toString('base64url')}`;
const EDITOR_PASSWORD = `Editor-${crypto.randomBytes(24).toString('base64url')}`;
const ROTATED_MEMBER_PASSWORD = `Member-${crypto.randomBytes(24).toString('base64url')}`;
const BASE_HOST_NAME = `stale-epoch-base-${RUN_ID.slice(0, 8)}`;
const EDITED_HOST_NAME = `stale-epoch-recovered-${RUN_ID.slice(0, 8)}`;
const SECOND_BASE_HOST_NAME = `stale-epoch-second-base-${RUN_ID.slice(0, 8)}`;
const SECOND_EDITED_HOST_NAME = `stale-epoch-second-recovered-${RUN_ID.slice(0, 8)}`;
const HOST_ADDRESS = '192.0.2.44';
const HOST_USERNAME = `test-${RUN_ID.slice(0, 6)}`;
const SECOND_HOST_ADDRESS = '192.0.2.46';
const SECOND_HOST_USERNAME = `second-${RUN_ID.slice(0, 6)}`;
const CREDENTIAL_NAME = `stale-epoch-credential-${RUN_ID.slice(0, 8)}`;
const CREDENTIAL_USERNAME = `credential-user-${RUN_ID.slice(0, 6)}`;
const BASE_CREDENTIAL_SECRET = `credential-before-rotation-${RUN_ID}`;
const EDITED_CREDENTIAL_SECRET = `credential-after-rotation-${RUN_ID}`;

let stage = 'preflight';
let tempRoot;
let databasePath;
let serverProcess;
let browser;
let ownerContext;
let editorContext;
let inviteeContext;
let ownerPage;
let editorPage;
let inviteePage;
let bootstrapToken;
let accountTokens = [];
let cleanupPromise;
let cleanupFailed = false;
let sharedVaultId;
const pageErrors = [];
const pushEvents = [];
const inviteEvents = [];
const membershipRefreshEvents = [];
const rotationEvents = [];
const networkFailures = [];
const changeEvents = [];
const apiPrivacyChecks = [];
let traceSequence = 0;

function fixtureMarkers() {
  return CREDENTIAL_ONLY
    ? [CREDENTIAL_NAME, CREDENTIAL_USERNAME, BASE_CREDENTIAL_SECRET, EDITED_CREDENTIAL_SECRET]
    : [BASE_HOST_NAME, EDITED_HOST_NAME, HOST_ADDRESS, HOST_USERNAME,
      ...(MULTI_RECORD
        ? [SECOND_BASE_HOST_NAME, SECOND_EDITED_HOST_NAME,
          SECOND_HOST_ADDRESS, SECOND_HOST_USERNAME]
        : [])];
}

function containsFixturePlaintext(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  return fixtureMarkers().some((marker) => serialized.includes(marker));
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

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
  if (request.method() === 'GET' && /^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) {
    return 'vault-changes';
  }
  if (request.method() === 'POST' && /^\/api\/v1\/vaults\/[^/]+\/keys\/rotate$/.test(pathname)) {
    return 'rotation';
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
    let pathname = '';
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    if (pathname.startsWith('/api/v1/')) {
      let requestBody = '';
      try { requestBody = request.postData() || ''; } catch (_) {}
      apiPrivacyChecks.push({
        profile,
        direction: 'request',
        route: kind || 'other-api',
        markerFree: !containsFixturePlaintext(requestBody),
      });
      pendingRequests.set(request, { kind: kind || 'other-api', event: null });
    }
    if (kind === 'vault-list' || kind === 'membership-chain') {
      let vaultId = null;
      try {
        const match = new URL(request.url()).pathname.match(/^\/api\/v1\/vaults\/([^/]+)/);
        if (match) vaultId = decodeURIComponent(match[1]);
      } catch (_) {}
      const event = {
        profile,
        kind,
        vaultId,
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
              .update(canonicalJson(envelope)).digest('hex'),
            envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
              'ciphertext,header,nonce,signature',
            ciphertextFieldsPresent: ['ciphertext', 'nonce', 'signature'].every((key) =>
              typeof envelope?.[key] === 'string' && envelope[key].length > 0),
          };
        }),
        containsFixturePlaintext: containsFixturePlaintext(body),
        containsHostPlaintext: !CREDENTIAL_ONLY && containsFixturePlaintext(body),
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
        event.requestTargetDeviceId = typeof responseBody?.recipient_device_id === 'string'
          ? responseBody.recipient_device_id : null;
      } catch (_) {
        event.requestHasTargetIdentity = false;
        event.requestTargetDeviceId = null;
      }
    } else if (kind === 'rotation') {
      const event = {
        profile,
        sequence: ++traceSequence,
        status: null,
        responseProcessed: false,
        activeEpoch: null,
        membershipVersion: null,
      };
      rotationEvents.push(event);
      pendingRequests.set(request, { kind, event });
    } else {
      pendingRequests.set(request, { kind, event: null });
    }
  });
  page.on('response', async (response) => {
    const request = response.request();
    const pending = pendingRequests.get(request);
    if (!pending) return;
    if (pending.event) pending.event.status = response.status();
    let responseText = '';
    try { responseText = await response.text(); } catch (_) {}
    apiPrivacyChecks.push({
      profile,
      direction: 'response',
      route: pending.kind || 'other-api',
      markerFree: !containsFixturePlaintext(responseText),
    });
    let parsedBody = null;
    try { parsedBody = JSON.parse(responseText); } catch (_) {}
    if (pending.kind === 'vault-list' && pending.event) {
      try {
        const body = parsedBody;
        const vaults = Array.isArray(body?.vaults) ? body.vaults : [];
        const descriptor = vaults.find((item) =>
          item?.vault_id === (pending.event.vaultId || sharedVaultId));
        if (descriptor) {
          pending.event.vaultId = descriptor.vault_id;
          pending.event.activeEpoch = String(descriptor.active_key_epoch ?? '');
          pending.event.membershipVersion = String(descriptor.membership_version ?? '');
          pending.event.keyEnvelopeEpochs = Array.isArray(descriptor.key_envelopes)
            ? descriptor.key_envelopes.map((item) => String(item?.key_epoch ?? ''))
            : [];
          pending.event.currentEpochEnvelopePresent = pending.event.keyEnvelopeEpochs
            .includes(pending.event.activeEpoch);
        }
      } catch (_) {}
    } else if (pending.kind === 'membership-chain' && pending.event) {
      try {
        const body = parsedBody;
        const manifests = Array.isArray(body?.manifests) ? body.manifests : [];
        pending.event.manifestCount = manifests.length;
        pending.event.latestMembershipVersion = manifests.length > 0
          ? String(manifests.at(-1)?.membership_version ?? '') : null;
        pending.event.latestManifestHasSignature = manifests.length > 0 &&
          typeof manifests.at(-1)?.signature === 'string' &&
          manifests.at(-1).signature.length > 0;
      } catch (_) {}
    } else if (pending.kind === 'vault-changes') {
      const events = Array.isArray(parsedBody?.events) ? parsedBody.events : [];
      for (const item of events) {
        const envelope = item?.envelope || {};
        const header = envelope?.header || {};
        changeEvents.push({
          profile,
          commitSeq: item?.commit_seq,
          eventType: item?.event_type,
          recordId: item?.record_id,
          revisionId: item?.revision_id,
          operation: header.operation,
          opId: header.op_id,
          envelopeDigest: crypto.createHash('sha256')
            .update(canonicalJson(envelope)).digest('hex'),
          envelopeShapeValid: Object.keys(envelope).sort().join(',') ===
            'ciphertext,header,nonce,signature',
          containsFixturePlaintext: containsFixturePlaintext(item),
          sequence: ++traceSequence,
          responseStatus: response.status(),
        });
      }
    } else if (pending.kind === 'invite' && pending.event) {
      try {
        const body = parsedBody;
        pending.event.membershipVersion = String(body?.membership_version ?? '');
        pending.event.vaultId = typeof body?.vault_id === 'string' ? body.vault_id : null;
        pending.event.vaultIdValid = typeof body?.vault_id === 'string' &&
          /^[0-9a-f-]{36}$/i.test(body.vault_id);
        pending.event.tokenPresent = typeof body?.token === 'string';
      } catch (_) {}
    } else if (pending.kind === 'push' && pending.event && response.status() >= 400) {
      try {
        const body = parsedBody;
        pending.event.errorCode = typeof body?.error?.code === 'string'
          ? body.error.code : null;
      } catch (_) {}
    } else if (pending.kind === 'rotation' && pending.event) {
      try {
        const body = parsedBody;
        pending.event.activeEpoch = String(body?.active_key_epoch ?? '');
        pending.event.membershipVersion = String(body?.membership_version ?? '');
        pending.event.vaultId = typeof body?.vault_id === 'string' ? body.vault_id : null;
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

async function readClientDatabaseFromIndexedDb(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') {
      return { available: false, reason: 'database-list-unavailable' };
    }
    const databases = await indexedDB.databases();
    if (!databases.some((database) => database.name === 'atermius_vault')) {
      return { available: false, reason: 'drift-indexeddb-database-missing' };
    }
    const connection = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
      request.onblocked = () => reject(new Error('IDB open blocked'));
    });
    try {
      if (!connection.objectStoreNames.contains('files') ||
          !connection.objectStoreNames.contains('blocks')) {
        return { available: false, reason: 'drift-file-stores-missing' };
      }
      const filesTx = connection.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('IDB files read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('IDB files read aborted'));
      });
      const filesStore = filesTx.objectStore('files');
      const [values, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesStore.getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = filesStore.getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file key read failed'));
        }),
        filesComplete,
      ]);
      const files = values.map((value, index) => ({
        fileId: Number(keys[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal');
      const databaseFile = files.find((file) => file.name === '/database');
      if (!databaseFile || files.some((file) => !Number.isSafeInteger(file.fileId) ||
          !Number.isSafeInteger(file.length) || file.length < 0 ||
          file.length > 64 * 1024 * 1024)) {
        return { available: false, reason: 'drift-sqlite-file-metadata-invalid' };
      }
      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('IDB blocks read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('IDB blocks read aborted'));
      });
      const store = blocksTx.objectStore('blocks');
      const sqliteFiles = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0],
          [file.fileId, Number.MAX_SAFE_INTEGER]);
        const [blockKeys, blockValues] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = store.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block keys read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = store.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block values read failed'));
          }),
        ]);
        return {
          ...file,
          blocks: blockKeys.map((key, index) => {
            const value = blockValues[index];
            let bytes;
            if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
            else if (ArrayBuffer.isView(value)) {
              bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            } else throw new Error('unsupported IndexedDB block value');
            let binary = '';
            for (let at = 0; at < bytes.length; at += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
            }
            return { offset: Number(key?.[1]), base64: btoa(binary) };
          }),
        };
      }));
      await blocksComplete;
      return { available: true, sqliteFiles };
    } finally {
      connection.close();
    }
  });
}

function inspectClientOutboxHistory(sqliteFiles, vaultId, originalOperation) {
  const snapshotPath = path.join(tempRoot, 'editor-outbox-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'Editor IndexedDB SQLite snapshot had no database or an active journal');
  const bytes = reconstructSqliteFile({
    fileId: databaseFile.fileId,
    name: databaseFile.name,
    length: databaseFile.length,
    blocks: databaseFile.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,op_id,expected_hash=sys.argv[2:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute('SELECT op_id,vault_id,record_id,envelope_json,status FROM pending_operations WHERE op_id=?',(op_id,)).fetchall()",
    "pending=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    'def digest(text):',
    '    value=json.loads(text)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest()',
    'original=None',
    'if len(rows)==1:',
    '    row=rows[0]',
    '    original={"opId":row[0],"vaultId":row[1],"recordId":row[2],"envelopeSha256":digest(row[3]),"status":row[4]}',
    'print(json.dumps({"integrityCheck":integrity,"originalRowCount":len(rows),"original":original,"expectedEnvelopeSha256":expected_hash,"activePendingCount":pending},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath,
      vaultId, originalOperation.opId, originalOperation.envelopeDigest], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only Editor outbox history query failed');
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function serverRecordSnapshot(vaultId, recordId) {
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id=sys.argv[2:]',
    'def digest(raw):',
    '    value=json.loads(raw)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest()',
    "versions=[dict(zip(('revisionId','baseRevisionId','commitSeq','operation','envelopeDigest'),(row[0],row[1],row[2],row[3],digest(row[4])))) for row in db.execute('SELECT revision_id,base_revision_id,commit_seq,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "receipts=[dict(zip(('opId','revisionId','commitSeq'),row)) for row in db.execute('SELECT op_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "events=[dict(zip(('commitSeq','eventType','revisionId','envelopeDigest'),(row[0],row[1],row[2],digest(row[3])))) for row in db.execute('SELECT commit_seq,event_type,revision_id,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "head=db.execute('SELECT revision_id,commit_seq,deleted FROM record_heads WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    'print(json.dumps({"versions":versions,"receipts":receipts,"events":events,"head":dict(zip(("revisionId","commitSeq","deleted"),head)) if head else None},separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', python, databasePath, vaultId, recordId], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only server receipt/version snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverVaultMembershipSnapshot(vaultId, editorUsername, rotatedMemberUsername) {
  const python = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,editor,other=sys.argv[2:]',
    "vault=db.execute('SELECT active_epoch,membership_version FROM vaults WHERE vault_id=?',(vault_id,)).fetchone()",
    "members=[dict(zip(('username','role','state'),row)) for row in db.execute('SELECT u.username,m.role,m.state FROM vault_members m JOIN users u ON u.user_id=m.user_id WHERE m.vault_id=? AND u.username IN (?,?) ORDER BY u.username',(vault_id,editor,other))]",
    'print(json.dumps({"vault":dict(zip(("activeEpoch","membershipVersion"),vault)) if vault else None,"members":members},separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', python, databasePath,
    vaultId, editorUsername, rotatedMemberUsername], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only Vault membership snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverDatabaseContainsMarker(markers) {
  const files = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`];
  return files.some((file) => fs.existsSync(file) && markers.some((marker) =>
    fs.readFileSync(file).includes(Buffer.from(marker))));
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
  let targetDeviceId;
  try { targetDeviceId = JSON.parse(cardJson)?.device?.device_id; } catch (_) {}
  assertThat(typeof targetDeviceId === 'string',
    'signed share request did not contain the target device identity');
  await click(ownerPage, 'Sign and create invitation');
  const event = await waitApiEvent(inviteEvents, (item) => item.profile === 'owner', eventStart - 1);
  assertThat(event.status === 200 && event.requestHasTargetIdentity &&
    event.requestTargetDeviceId === targetDeviceId,
    'Owner membership invitation request did not commit for the target device');
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
  setStage('open Vault invitation form');
  await click(page, 'Settings');
  setStage('open invitation acceptance');
  await click(page, 'Accept invitation');
  setStage('enter disposable Vault invitation token');
  await fill(page, 'Invitation token', token);
  setStage('accept and unlock shared Vault');
  await click(page, 'Accept and unlock Vault');
  setStage('wait for accepted profile workspace');
  await waitWorkspace(page);
  setStage('verify active Editor membership in accepted profile');
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

async function addSecondHost(page) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitSemanticText(page, 'Add a host');
  await fill(page, 'Display name', SECOND_BASE_HOST_NAME);
  await fill(page, 'Hostname or IP', SECOND_HOST_ADDRESS);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', SECOND_HOST_USERNAME);
  await click(page, 'Save encrypted host');
  await waitHost(page, SECOND_BASE_HOST_NAME, true);
}

async function editSecondHostOffline(page) {
  const card = hostCard(page, SECOND_BASE_HOST_NAME);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitSemanticText(page, 'Edit host');
  await fill(page, 'Display name', SECOND_EDITED_HOST_NAME);
  await click(page, 'Save encrypted host');
  await waitHost(page, SECOND_EDITED_HOST_NAME, true);
  await waitHost(page, SECOND_BASE_HOST_NAME, false);
}

async function openCredentials(page) {
  await click(page, 'Credentials');
  await waitSemanticText(page, 'SSH credentials');
}

async function waitCredential(page, expected = true, timeoutMs = 25000) {
  const prefix = `Credential: ${CREDENTIAL_NAME}; `;
  await waitFor(() => page.locator('flt-semantics[role="group"]').evaluateAll((nodes, label) =>
    nodes.some((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 &&
        (node.getAttribute('aria-label') || '').startsWith(label);
    }), prefix).then((visible) => visible === expected), timeoutMs,
  `Credential visibility did not become ${expected}`);
}

async function openCredentialEdit(page) {
  const escaped = CREDENTIAL_NAME.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = page.getByRole('group', { name: new RegExp(`^Credential: ${escaped}; `) });
  await card.waitFor({ state: 'visible', timeout: 20000 });
  const actionButtons = card.getByRole('button');
  assertThat(await actionButtons.count() === 1,
    'Credential card did not expose one action button');
  await actionButtons.first().click();
  await page.getByRole('menuitem', { name: 'Edit', exact: true }).click();
  await waitSemanticText(page, 'Edit credential');
}

async function addPasswordCredential(page) {
  await openCredentials(page);
  await click(page, 'Add credential');
  await waitSemanticText(page, 'New SSH credential');
  await fill(page, 'Credential name', CREDENTIAL_NAME);
  await fill(page, 'SSH username', CREDENTIAL_USERNAME);
  await fill(page, 'Password', BASE_CREDENTIAL_SECRET);
  await click(page, 'Save encrypted credential');
  await waitCredential(page, true);
}

async function editCredentialOffline(page) {
  await openCredentialEdit(page);
  await fill(page, 'Password', EDITED_CREDENTIAL_SECRET);
  await click(page, 'Save encrypted credential');
  await waitCredential(page, true);
}

async function credentialPasswordFieldState(page) {
  return page.evaluate((expected) => {
    const candidates = [...document.querySelectorAll('input[aria-label],textarea[aria-label]')]
      .filter((element) => (element.getAttribute('aria-label') || '').toLowerCase()
        .includes('password'));
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    const visible = candidates.filter(isVisible);
    const field = visible[0] || candidates[0] || null;
    return {
      fieldPresent: candidates.length > 0,
      fieldCount: candidates.length,
      visibleFieldCount: visible.length,
      inputType: field?.getAttribute('type') || (field ? field.tagName.toLowerCase() : null),
      valueLength: field && typeof field.value === 'string' ? field.value.length : null,
      valueMatchesExpected: Boolean(field && field.value === expected),
    };
  }, EDITED_CREDENTIAL_SECRET).catch(() => ({
    fieldPresent: false,
    fieldCount: 0,
    visibleFieldCount: 0,
    inputType: null,
    valueLength: null,
    valueMatchesExpected: false,
    stateReadable: false,
  }));
}

async function readCredentialPassword(page) {
  const observations = [];
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    const credentialsHeading = page.getByText('SSH credentials', { exact: true }).first();
    if (!await credentialsHeading.isVisible().catch(() => false)) await openCredentials(page);
    await openCredentialEdit(page);
    const passwordFields = page.locator(
      'input[aria-label*="Password"],textarea[aria-label*="Password"]');
    await selectServerModeIfChooser(page, passwordFields);
    let fieldLocator = null;
    try {
      await waitFor(async () => {
        for (let index = 0; index < await passwordFields.count(); index += 1) {
          const candidate = passwordFields.nth(index);
          if (await candidate.isVisible()) {
            fieldLocator = candidate;
            return true;
          }
        }
        return false;
      }, 2500, 'password field did not become visible');
      await fieldLocator.click();
    } catch (_) {
      // Record only DOM structure and value metadata below; never include text.
    }
    let state = await credentialPasswordFieldState(page);
    const settleUntil = Math.min(Date.now() + 1800, deadline);
    while (!state.valueMatchesExpected && Date.now() < settleUntil) {
      await page.waitForTimeout(200);
      state = await credentialPasswordFieldState(page);
    }
    observations.push(state);
    await click(page, 'Cancel');
    if (state.valueMatchesExpected) return state;
    await page.waitForTimeout(350);
  }
  const last = observations.at(-1) || {
    fieldPresent: false,
    fieldCount: 0,
    visibleFieldCount: 0,
    inputType: null,
    valueLength: null,
    valueMatchesExpected: false,
  };
  const safeObservations = {
    attempts: observations.length,
    last,
    allFieldsPresent: observations.every((item) => item.fieldPresent),
    anyExpectedValueObserved: observations.some((item) => item.valueMatchesExpected),
  };
  console.log('second profile Password field safe diagnostic', JSON.stringify(safeObservations));
  throw new Error('second profile Password field did not match the updated credential');
}

async function addFixtureRecord(page) {
  if (CREDENTIAL_ONLY) return addPasswordCredential(page);
  return addHost(page);
}

async function editFixtureOffline(page) {
  if (CREDENTIAL_ONLY) return editCredentialOffline(page);
  return editHostOffline(page);
}

async function openFixturePage(page) {
  return CREDENTIAL_ONLY ? openCredentials(page) : click(page, 'Hosts');
}

async function waitFixture(page, edited, expected = true, timeoutMs = 45000) {
  if (CREDENTIAL_ONLY) {
    await waitCredential(page, expected, timeoutMs);
  } else {
    await waitHost(page, edited ? EDITED_HOST_NAME : BASE_HOST_NAME, expected, timeoutMs);
  }
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

async function clickMemberAction(page, username, actionLabel) {
  setStage('Owner finds the target member in visible Flutter semantics');
  const identityBox = await page.evaluate((target) => {
    const candidates = [...document.querySelectorAll('flt-semantics')].flatMap((node) => {
      const label = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
        .replace(/\s+/g, ' ').trim();
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      const visible = rect.width > 0 && rect.height > 0 && rect.right > 0 &&
        rect.bottom > 0 && rect.left < window.innerWidth && rect.top < window.innerHeight &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
      return visible && label.includes(target)
        ? [{ node, labelLength: label.length }]
        : [];
    }).sort((left, right) => left.labelLength - right.labelLength);
    if (candidates.length === 0) return null;
    const candidate = candidates[0].node;
    candidate.scrollIntoView({ block: 'center', inline: 'nearest' });
    const rect = candidate.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  }, username);
  assertThat(identityBox, 'target member identity was not laid out');

  setStage('Owner uniquely maps the target member row to its role action');
  const actions = page.getByRole('button', { name: actionLabel, exact: true });
  const candidates = [];
  for (let index = 0; index < await actions.count(); index += 1) {
    const action = actions.nth(index);
    if (!await action.isVisible()) continue;
    const box = await action.boundingBox();
    if (!box) continue;
    candidates.push({ action, distance: Math.abs((box.y + box.height / 2) -
      (identityBox.y + identityBox.height / 2)) });
  }
  candidates.sort((left, right) => left.distance - right.distance);
  assertThat(candidates.length === 2 && candidates[0].distance < 240 &&
    (candidates.length === 1 || candidates[1].distance - candidates[0].distance > 18),
  'could not uniquely associate the role action with the intended member row');

  setStage('Owner clicks the uniquely matched target member role action');
  await candidates[0].action.click();
}

async function visibleVaultMemberLabels(page) {
  const allowedLabels = [
    'EDITOR · Active',
    'VIEWER · Active',
    'EDITOR · Invitation pending',
    'VIEWER · Invitation pending',
    'EDITOR · Invitation expired',
    'VIEWER · Invitation expired',
    'EDITOR · Invitation needs reissue',
    'VIEWER · Invitation needs reissue',
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

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-stale-outbox-epoch-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  const port = await unusedLoopbackPort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
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

    setStage('launch isolated Owner, Editor, and second-member browser profiles');
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
    ownerPage = await ownerContext.newPage();
    editorPage = await editorContext.newPage();
    inviteePage = await inviteeContext.newPage();
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
    setStage('register disposable Editor and second-member accounts');
    await Promise.all([
      registerInvitedAccount(editorPage, baseUrl, serverEnv, EDITOR_USERNAME,
        EDITOR_PASSWORD, 'Stale outbox Editor fixture'),
      registerInvitedAccount(inviteePage, baseUrl, serverEnv, ROTATED_MEMBER_USERNAME,
        ROTATED_MEMBER_PASSWORD, 'Stale outbox epoch member fixture'),
    ]);

    setStage('invite Editor and activate its shared Vault membership');
    const editorCard = await copyDeviceCard(editorPage);
    const editorInvitation = await inviteShareCard(ownerPage, editorCard);
    sharedVaultId = editorInvitation.event.vaultId;
    assertThat(editorInvitation.event.vaultIdValid &&
      /^[0-9a-f-]{36}$/i.test(sharedVaultId || ''),
    'Editor invitation response did not identify its shared Vault');
    await acceptVaultInvitation(editorPage, editorInvitation.token);
    editorInvitation.token = undefined;
    await clearClipboard(editorPage);

    setStage('invite and activate a second Editor member before the baseline Host');
    const rotatedMemberCard = await copyDeviceCard(inviteePage);
    const rotatedMemberInvitation = await inviteShareCard(ownerPage, rotatedMemberCard);
    await acceptVaultInvitation(inviteePage, rotatedMemberInvitation.token);
    rotatedMemberInvitation.token = undefined;
    await clearClipboard(inviteePage);
    assertThat(rotatedMemberInvitation.event.vaultIdValid &&
      rotatedMemberInvitation.event.vaultId === sharedVaultId,
    'second member invitation targeted a different Vault');

    setStage(`create and sync baseline ${CREDENTIAL_ONLY ? 'Password Credential' : 'Host'} to Editor`);
    await addFixtureRecord(ownerPage);
    const baselineCreate = await waitApiEvent(pushEvents, (item) =>
      item.profile === 'owner' && item.status === 200 &&
      item.operations.some((op) => op.operation === 'create'), -1, 45000);
    const baselineOperation = baselineCreate.operations.find((op) => op.operation === 'create');
    assertThat(baselineOperation && baselineOperation.envelopeShapeValid &&
      baselineOperation.ciphertextFieldsPresent && !baselineCreate.containsFixturePlaintext &&
      /^\d+$/.test(String(baselineOperation.keyEpoch)) &&
      /^\d+$/.test(String(baselineOperation.membershipVersion)),
    'baseline encrypted fixture record commit did not use an opaque envelope');
    const baselineLedger = serverRecordSnapshot(sharedVaultId, baselineOperation.recordId);
    assertThat(baselineLedger.versions.length === 1 && baselineLedger.receipts.length === 1 &&
      baselineLedger.events.length === 1 &&
      baselineLedger.versions[0].revisionId === baselineOperation.revisionId &&
      baselineLedger.versions[0].envelopeDigest === baselineOperation.envelopeDigest &&
      baselineLedger.events[0].envelopeDigest === baselineOperation.envelopeDigest &&
      baselineLedger.receipts[0].opId === baselineOperation.opId,
    'baseline server ledger did not bind the initial envelope to its receipt and change event');
    const baselineOperations = [baselineOperation];
    let secondBaselineOperation = null;
    let secondBaselineLedger = null;
    if (MULTI_RECORD) {
      const secondCreateStart = pushEvents.length;
      setStage('create a second independent Host record before the Editor goes offline');
      await addSecondHost(ownerPage);
      const secondCreate = await waitApiEvent(pushEvents, (item) =>
        item.profile === 'owner' && item.status === 200 &&
        item.operations.some((op) => op.operation === 'create' &&
          op.recordId !== baselineOperation.recordId), secondCreateStart - 1, 45000);
      secondBaselineOperation = secondCreate.operations.find((op) =>
        op.operation === 'create' && op.recordId !== baselineOperation.recordId);
      assertThat(secondBaselineOperation && secondBaselineOperation.envelopeShapeValid &&
        secondBaselineOperation.ciphertextFieldsPresent && !secondCreate.containsFixturePlaintext &&
        secondBaselineOperation.keyEpoch === baselineOperation.keyEpoch &&
        secondBaselineOperation.membershipVersion === baselineOperation.membershipVersion,
      'second Host baseline did not commit as a separate opaque record under the same Vault version');
      secondBaselineLedger = serverRecordSnapshot(sharedVaultId, secondBaselineOperation.recordId);
      assertThat(secondBaselineLedger.versions.length === 1 &&
        secondBaselineLedger.receipts.length === 1 && secondBaselineLedger.events.length === 1 &&
        secondBaselineLedger.versions[0].revisionId === secondBaselineOperation.revisionId &&
        secondBaselineLedger.receipts[0].opId === secondBaselineOperation.opId,
      'second Host baseline ledger did not bind its envelope, receipt, and event');
      baselineOperations.push(secondBaselineOperation);
    }
    await openFixturePage(editorPage);
    await waitFixture(editorPage, false, true);
    if (MULTI_RECORD) {
      await syncNow(editorPage);
      await waitHost(editorPage, SECOND_BASE_HOST_NAME, true, 30000);
    }
    const editorNavigationBaseline = editorMainFrameNavigations;

    setStage(`queue an offline ${CREDENTIAL_ONLY ? 'Password Credential secret update' : 'Host edit'} from active Editor profile`);
    await editorContext.setOffline(true);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === false),
      5000, 'Chromium did not expose the Editor profile as offline');
    await editFixtureOffline(editorPage);
    if (MULTI_RECORD) await editSecondHostOffline(editorPage);
    const pendingBefore = await waitPendingAtLeast(editorPage, MULTI_RECORD ? 2 : 1);
    console.log('assert: offline_editor_outbox_retained=true');

    setStage('Owner opens Settings for the offline membership rotation');
    await click(ownerPage, 'Settings');
    setStage('Owner opens Vault member management');
    await click(ownerPage, 'Manage Vault members');
    setStage('Owner waits for an active Editor membership row');
    await waitFor(async () => (await visibleVaultMemberLabels(ownerPage))
      .includes('EDITOR · Active'), 20000, 'active Editor member row');
    setStage('Owner waits for the rotated member identity in the roster');
    await waitSemanticText(ownerPage, ROTATED_MEMBER_USERNAME);
    setStage('Owner snapshots both active Editor memberships before rotation');
    const beforeRotation = serverVaultMembershipSnapshot(
      sharedVaultId, EDITOR_USERNAME, ROTATED_MEMBER_USERNAME);
    assertThat(beforeRotation.vault &&
      beforeRotation.vault.activeEpoch === Number(baselineOperation.keyEpoch) &&
      beforeRotation.vault.membershipVersion === Number(baselineOperation.membershipVersion) &&
      beforeRotation.members.some((member) => member.username === EDITOR_USERNAME &&
        member.role === 'editor' && member.state === 'active') &&
      beforeRotation.members.some((member) => member.username === ROTATED_MEMBER_USERNAME &&
        member.role === 'editor' && member.state === 'active'),
    'pre-rotation snapshot did not contain both active Editor members at the Host epoch');
    setStage('Owner opens the rotated member role-change confirmation');
    await clickMemberAction(ownerPage, ROTATED_MEMBER_USERNAME, 'Make viewer');
    setStage('Owner waits for the rotated member confirmation text');
    await waitSemanticText(ownerPage, `Change ${ROTATED_MEMBER_USERNAME} from editor to viewer?`);
    setStage('Owner confirms the rotated member Viewer role change');
    const rotationStart = rotationEvents.length;
    await click(ownerPage, 'Change to viewer');
    setStage('Owner waits for successful key-rotation API response');
    const roleRotation = await waitApiEvent(rotationEvents,
      (event) => event.profile === 'owner' && event.status === 200,
      rotationStart - 1, 45000);
    setStage('Owner waits for the refreshed active Viewer roster row');
    await waitFor(async () => (await visibleVaultMemberLabels(ownerPage))
      .includes('VIEWER · Active'), 20000, 'active Viewer member row');
    setStage('Owner verifies the rotated Vault epoch and membership snapshots');
    const afterRotation = serverVaultMembershipSnapshot(
      sharedVaultId, EDITOR_USERNAME, ROTATED_MEMBER_USERNAME);
    assertThat(afterRotation.vault &&
      afterRotation.vault.activeEpoch === beforeRotation.vault.activeEpoch + 1 &&
      afterRotation.vault.membershipVersion === beforeRotation.vault.membershipVersion + 1 &&
      Number.isSafeInteger(afterRotation.vault.activeEpoch) &&
      Number.isSafeInteger(afterRotation.vault.membershipVersion) &&
      afterRotation.members.some((member) => member.username === EDITOR_USERNAME &&
        member.role === 'editor' && member.state === 'active') &&
      afterRotation.members.some((member) => member.username === ROTATED_MEMBER_USERNAME &&
        member.role === 'viewer' && member.state === 'active'),
    'Owner role change did not advance exactly one epoch/version while retaining the offline Editor');
    const currentEpoch = String(afterRotation.vault.activeEpoch);
    const currentMembershipVersion = String(afterRotation.vault.membershipVersion);
    setStage('verify offline change left the server record ledger unchanged before reconnect push');
    const ledgerBeforeReconnect = serverRecordSnapshot(sharedVaultId, baselineOperation.recordId);
    assertThat(JSON.stringify(ledgerBeforeReconnect) === JSON.stringify(baselineLedger),
      'offline fixture edit changed the first server record ledger before reconnect push');
    if (MULTI_RECORD) {
      const secondLedgerBeforeReconnect = serverRecordSnapshot(
        sharedVaultId, secondBaselineOperation.recordId);
      assertThat(JSON.stringify(secondLedgerBeforeReconnect) === JSON.stringify(secondBaselineLedger),
        'offline fixture edit changed the second server record ledger before reconnect push');
    }
    await click(ownerPage, 'Close');

    setStage('restore Editor network and trigger same-session sync');
    const pushStart = pushEvents.length;
    await editorContext.setOffline(false);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === true),
      5000, 'Chromium did not restore the Editor network');
    assertThat(!editorPage.isClosed() && editorMainFrameNavigations === editorNavigationBaseline,
      'Editor page navigated during the offline membership change');
    const visibleSyncTriggered = await syncNow(editorPage);

    setStage('observe old-envelope key epoch rejection');
    const stalePush = await waitApiEvent(pushEvents, (event) =>
      event.profile === 'editor' && event.status === 409 &&
      event.errorCode === 'KEY_EPOCH_OUTDATED' &&
      event.operations.some((op) => op.recordId === baselineOperation.recordId &&
        op.operation === 'update'), pushStart - 1, 30000);
    const staleOperation = stalePush.operations.find((op) =>
      op.recordId === baselineOperation.recordId && op.operation === 'update');
    assertThat(staleOperation.membershipVersion === baselineOperation.membershipVersion &&
      staleOperation.keyEpoch === baselineOperation.keyEpoch &&
      staleOperation.opId && staleOperation.envelopeDigest,
    'Editor did not first submit the original immutable envelope under the old Vault epoch');
    if (MULTI_RECORD) {
      const staleBatchOperations = stalePush.operations.filter((op) =>
        op.operation === 'update' && baselineOperations.some((baseline) =>
          baseline.recordId === op.recordId));
      const secondStaleOperation = staleBatchOperations.find((op) =>
        op.recordId === secondBaselineOperation.recordId);
      assertThat(staleBatchOperations.length === 2 && secondStaleOperation &&
        new Set(staleBatchOperations.map((op) => op.recordId)).size === 2 &&
        staleBatchOperations.every((op) => op.keyEpoch === baselineOperation.keyEpoch &&
          op.membershipVersion === baselineOperation.membershipVersion &&
          op.opId && op.revisionId && op.envelopeDigest),
      'the initial stale 409 did not reject one atomic batch containing both distinct old-epoch Host edits');
    }
    const ledgerAfterStaleRejection = serverRecordSnapshot(sharedVaultId, baselineOperation.recordId);
    assertThat(JSON.stringify(ledgerAfterStaleRejection) === JSON.stringify(baselineLedger) &&
      !ledgerAfterStaleRejection.receipts.some((receipt) => receipt.opId === staleOperation.opId),
    'stale rejection created a server ledger row or operation receipt');
    if (MULTI_RECORD) {
      const secondLedgerAfterStaleRejection = serverRecordSnapshot(
        sharedVaultId, secondBaselineOperation.recordId);
      const secondStale = stalePush.operations.find((op) =>
        op.recordId === secondBaselineOperation.recordId && op.operation === 'update');
      assertThat(JSON.stringify(secondLedgerAfterStaleRejection) ===
        JSON.stringify(secondBaselineLedger) && secondStale &&
        !secondLedgerAfterStaleRejection.receipts.some((receipt) =>
          receipt.opId === secondStale.opId),
      'atomic multi-record stale rejection changed the second record ledger or created a receipt');
    }

    setStage('wait for a current-epoch replacement batch');
    const recoveredPush = await waitApiEvent(pushEvents, (event) =>
      event.profile === 'editor' && event.status === 200 &&
      event.operations.some((op) => op.recordId === baselineOperation.recordId &&
        op.operation === 'update' &&
        op.membershipVersion === currentMembershipVersion &&
        op.keyEpoch === currentEpoch), pushStart - 1, 90000);
    const recoveredOperation = recoveredPush.operations.find((op) =>
      op.recordId === baselineOperation.recordId && op.operation === 'update' &&
      op.membershipVersion === currentMembershipVersion &&
      op.keyEpoch === currentEpoch);
    let secondRecoveredOperation = null;
    if (MULTI_RECORD) {
      setStage('verify the successful replacement batch contains both Host records');
      secondRecoveredOperation = recoveredPush.operations.find((op) =>
        op.recordId === secondBaselineOperation.recordId && op.operation === 'update' &&
        op.membershipVersion === currentMembershipVersion && op.keyEpoch === currentEpoch);
      const replacementBatch = recoveredPush.operations.filter((op) =>
        op.operation === 'update' && baselineOperations.some((baseline) =>
          baseline.recordId === op.recordId));
      assertThat(replacementBatch.length === 2 && secondRecoveredOperation,
        'the successful current-epoch batch did not contain both Host records');
      setStage('verify the second Host received a fresh operation identity');
      const secondReplacementIdentity = {
        operationIdChanged: secondRecoveredOperation.opId !== secondBaselineOperation.opId,
        revisionIdChanged: secondRecoveredOperation.revisionId !== secondBaselineOperation.revisionId,
        envelopeChanged: secondRecoveredOperation.envelopeDigest !== secondBaselineOperation.envelopeDigest,
      };
      console.log('assert: second_host_replacement_identity',
        JSON.stringify(secondReplacementIdentity));
      assertThat(Object.values(secondReplacementIdentity).every(Boolean),
        'the second Host replacement reused its original operation identity or envelope');
    }
    const staleAttemptEventsForFirstRecord = pushEvents.filter((event) =>
      event.profile === 'editor' && event.status === 409 &&
      event.errorCode === 'KEY_EPOCH_OUTDATED' &&
      event.operations.some((op) => op.recordId === baselineOperation.recordId &&
        op.operation === 'update'));
    let staleAttemptEvents;
    let secondStalePush;
    let initialStaleProbes = [];
    let refreshedStaleProbes = [];
    if (MULTI_RECORD) {
      const isTargetUpdate = (op) => op.operation === 'update' &&
        baselineOperations.some((baseline) => baseline.recordId === op.recordId);
      const staleBatches = pushEvents.filter((event) =>
        event.profile === 'editor' && event.status === 409 &&
        event.errorCode === 'KEY_EPOCH_OUTDATED' &&
        event.operations.length === 2 && event.operations.every(isTargetUpdate));
      const retriedBatch = staleBatches.find((event) => event !== stalePush &&
        event.sequence < recoveredPush.sequence);
      assertThat(staleBatches.length === 2 && staleBatches[0] === stalePush && retriedBatch,
        'Editor did not retry the unchanged two-record batch after its signed membership refresh');

      initialStaleProbes = pushEvents.filter((event) =>
        event.profile === 'editor' && event.status === 409 &&
        event.errorCode === 'KEY_EPOCH_OUTDATED' && event.operations.length === 1 &&
        isTargetUpdate(event.operations[0]) &&
        event.sequence > stalePush.sequence && event.sequence < retriedBatch.sequence);
      refreshedStaleProbes = pushEvents.filter((event) =>
        event.profile === 'editor' && event.status === 409 &&
        event.errorCode === 'KEY_EPOCH_OUTDATED' && event.operations.length === 1 &&
        isTargetUpdate(event.operations[0]) &&
        event.sequence > retriedBatch.sequence && event.sequence < recoveredPush.sequence);
      assertThat(initialStaleProbes.length === 1 && refreshedStaleProbes.length === 2 &&
        new Set(refreshedStaleProbes.map((event) => event.operations[0].recordId)).size === 2,
      'multi-record fallback did not make one pre-refresh probe and one refreshed probe per Host');

      const descriptorAndChainRefresh = membershipRefreshEvents.filter((event) =>
        event.profile === 'editor' && event.vaultId === sharedVaultId &&
        event.sequence > initialStaleProbes[0].sequence &&
        event.sequence < retriedBatch.sequence && event.responseProcessed &&
        event.status === 200);
      assertThat(descriptorAndChainRefresh.some((event) =>
        event.kind === 'vault-list' && event.activeEpoch === currentEpoch &&
        event.membershipVersion === currentMembershipVersion &&
        event.currentEpochEnvelopePresent) &&
        descriptorAndChainRefresh.some((event) =>
          event.kind === 'membership-chain' &&
          event.latestMembershipVersion === currentMembershipVersion &&
          event.latestManifestHasSignature),
      'the retry batch was sent before the current descriptor and signed chain responses completed');

      const retriedBatchByRecord = new Map(retriedBatch.operations
        .filter(isTargetUpdate).map((operation) => [operation.recordId, operation]));
      const refreshedProbeByRecord = new Map(refreshedStaleProbes
        .map((event) => [event.operations[0].recordId, event.operations[0]]));
      assertThat(baselineOperations.every((baseline) => {
        const rejected = retriedBatchByRecord.get(baseline.recordId);
        const probe = refreshedProbeByRecord.get(baseline.recordId);
        return rejected && probe && probe.opId === rejected.opId &&
          probe.revisionId === rejected.revisionId &&
          probe.envelopeDigest === rejected.envelopeDigest &&
          probe.keyEpoch === rejected.keyEpoch &&
          probe.membershipVersion === rejected.membershipVersion;
      }), 'a per-record probe changed its immutable stale batch envelope');
      staleAttemptEvents = [stalePush, retriedBatch];
      secondStalePush = retriedBatch;
    } else {
      staleAttemptEvents = staleAttemptEventsForFirstRecord;
      assertThat(staleAttemptEvents.length === 2 && staleAttemptEvents[0] === stalePush &&
        staleAttemptEvents[1].sequence > stalePush.sequence &&
        staleAttemptEvents[1].sequence < recoveredPush.sequence,
      'Editor did not make exactly two ordered stale-version attempts before replacement');
      secondStalePush = staleAttemptEvents[1];
    }
    const refreshedControlPlaneBetweenStaleAttempts = membershipRefreshEvents.filter((event) =>
      event.profile === 'editor' && event.vaultId === sharedVaultId &&
      event.sequence > stalePush.sequence && event.sequence < secondStalePush.sequence &&
      event.responseProcessed && event.status === 200);
    assertThat(refreshedControlPlaneBetweenStaleAttempts.some((event) =>
      event.kind === 'vault-list' &&
        event.vaultId === sharedVaultId &&
        event.activeEpoch === currentEpoch &&
        event.membershipVersion === currentMembershipVersion &&
        event.currentEpochEnvelopePresent) &&
      refreshedControlPlaneBetweenStaleAttempts.some((event) =>
        event.kind === 'membership-chain' &&
        event.latestMembershipVersion === currentMembershipVersion &&
        event.latestManifestHasSignature),
    'Editor sent the second stale probe before current descriptor, key envelope, and signed chain responses completed');
    assertThat(recoveredOperation.envelopeShapeValid &&
      recoveredOperation.ciphertextFieldsPresent &&
      recoveredOperation.opId !== staleOperation.opId &&
      recoveredOperation.envelopeDigest !== staleOperation.envelopeDigest &&
      recoveredOperation.recordId === staleOperation.recordId &&
      recoveredOperation.revisionId !== staleOperation.revisionId &&
      !recoveredPush.containsFixturePlaintext,
    'Editor did not replace the stale envelope with a newly encrypted current-epoch operation');
    if (MULTI_RECORD) {
      const secondBatchAttempt = stalePush.operations.find((op) =>
        op.recordId === secondBaselineOperation.recordId && op.operation === 'update');
      const secondProbeAttempt = refreshedStaleProbes.find((event) =>
        event.operations[0].recordId === secondBaselineOperation.recordId)?.operations[0];
      assertThat(secondBatchAttempt && secondProbeAttempt &&
        secondProbeAttempt.opId === secondBatchAttempt.opId &&
        secondProbeAttempt.revisionId === secondBatchAttempt.revisionId &&
        secondProbeAttempt.envelopeDigest === secondBatchAttempt.envelopeDigest &&
        secondProbeAttempt.keyEpoch === secondBatchAttempt.keyEpoch &&
        secondProbeAttempt.membershipVersion === secondBatchAttempt.membershipVersion,
      'the second record did not receive the batch-level stale rejection and an individual probe before replacement');
    }
    await waitFor(async () => (await pendingCount(editorPage)) === 0,
      30000, 'Editor still reported a pending operation after recovery');

    setStage('verify two identical stale attempts and one replacement push');
    const recordPushes = pushEvents.filter((event) => event.profile === 'editor' &&
      event.operations.some((operation) => operation.recordId === baselineOperation.recordId &&
        operation.operation === 'update'));
    const staleOperationFor = (event) => event.operations.find((operation) =>
      operation.recordId === baselineOperation.recordId && operation.operation === 'update');
    const firstStaleOperation = staleOperationFor(staleAttemptEvents[0]);
    const secondStaleOperation = staleOperationFor(staleAttemptEvents[1]);
    const firstRecordInitialProbe = MULTI_RECORD
      ? initialStaleProbes.find((event) => event.operations[0].recordId === baselineOperation.recordId)
      : null;
    const firstRecordRefreshedProbe = MULTI_RECORD
      ? refreshedStaleProbes.find((event) => event.operations[0].recordId === baselineOperation.recordId)
      : null;
    const expectedFirstRecordPushes = MULTI_RECORD
      ? [stalePush, ...(firstRecordInitialProbe ? [firstRecordInitialProbe] : []),
        secondStalePush, firstRecordRefreshedProbe, recoveredPush]
      : [stalePush, secondStalePush, recoveredPush];
    assertThat(recordPushes.length === expectedFirstRecordPushes.length &&
      expectedFirstRecordPushes.every((event, index) => recordPushes[index] === event) &&
      firstStaleOperation && secondStaleOperation &&
      secondStaleOperation.opId === firstStaleOperation.opId &&
      secondStaleOperation.revisionId === firstStaleOperation.revisionId &&
      secondStaleOperation.envelopeDigest === firstStaleOperation.envelopeDigest &&
      secondStaleOperation.keyEpoch === firstStaleOperation.keyEpoch &&
      secondStaleOperation.membershipVersion === firstStaleOperation.membershipVersion &&
      firstStaleOperation.opId === staleOperation.opId &&
      firstStaleOperation.revisionId === staleOperation.revisionId &&
      firstStaleOperation.envelopeDigest === staleOperation.envelopeDigest &&
      firstStaleOperation.keyEpoch === baselineOperation.keyEpoch &&
      firstStaleOperation.membershipVersion === baselineOperation.membershipVersion &&
      recordPushes.filter((event) => event.status === 200).length === 1 &&
      !recordPushes.some((event) => event.containsFixturePlaintext),
    'Editor changed a stale envelope between probes, sent an unexpected operation, or exposed fixture plaintext');
    if (MULTI_RECORD) {
      const secondRecordPushes = pushEvents.filter((event) => event.profile === 'editor' &&
        event.operations.some((operation) => operation.recordId === secondBaselineOperation.recordId &&
          operation.operation === 'update'));
      const secondRecordInitialProbe = initialStaleProbes.find((event) =>
        event.operations[0].recordId === secondBaselineOperation.recordId);
      const secondRecordRefreshedProbe = refreshedStaleProbes.find((event) =>
        event.operations[0].recordId === secondBaselineOperation.recordId);
      const expectedSecondRecordPushes = [stalePush,
        ...(secondRecordInitialProbe ? [secondRecordInitialProbe] : []), secondStalePush,
        secondRecordRefreshedProbe, recoveredPush];
      const originalSecondOperation = stalePush.operations.find((operation) =>
        operation.recordId === secondBaselineOperation.recordId);
      const secondRecordStaleOperations = secondRecordPushes
        .filter((event) => event.status === 409)
        .map((event) => event.operations.find((operation) =>
          operation.recordId === secondBaselineOperation.recordId));
      assertThat(secondRecordPushes.length === expectedSecondRecordPushes.length &&
        expectedSecondRecordPushes.every((event, index) => secondRecordPushes[index] === event) &&
        originalSecondOperation && secondRecordStaleOperations.every((operation) =>
          operation && operation.opId === originalSecondOperation.opId &&
          operation.revisionId === originalSecondOperation.revisionId &&
          operation.envelopeDigest === originalSecondOperation.envelopeDigest &&
          operation.keyEpoch === originalSecondOperation.keyEpoch &&
          operation.membershipVersion === originalSecondOperation.membershipVersion) &&
        secondRecordPushes.filter((event) => event.status === 200).length === 1 &&
        !secondRecordPushes.some((event) => event.containsFixturePlaintext),
      'Editor changed the second Host stale envelope, sent an unexpected operation, or exposed fixture plaintext');
    }

    setStage('verify server retained exactly one replacement commit and head');
    const serverRecord = serverRecordSnapshot(sharedVaultId, baselineOperation.recordId);
    assertThat(serverRecord.versions.length === 2 && serverRecord.receipts.length === 2 &&
      serverRecord.events.length === 2 && serverRecord.head &&
      serverRecord.versions[0].revisionId === baselineOperation.revisionId &&
      serverRecord.versions[1].revisionId === recoveredOperation.revisionId &&
      serverRecord.versions[1].baseRevisionId === baselineOperation.revisionId &&
      serverRecord.versions[1].envelopeDigest === recoveredOperation.envelopeDigest &&
      serverRecord.events[1].envelopeDigest === recoveredOperation.envelopeDigest &&
      serverRecord.receipts.some((receipt) => receipt.opId === baselineOperation.opId) &&
      serverRecord.receipts.some((receipt) => receipt.opId === recoveredOperation.opId &&
        receipt.revisionId === recoveredOperation.revisionId) &&
      !serverRecord.receipts.some((receipt) => receipt.opId === staleOperation.opId) &&
      serverRecord.events[1].eventType === 'update' &&
      serverRecord.events[1].revisionId === recoveredOperation.revisionId &&
      serverRecord.head.revisionId === recoveredOperation.revisionId &&
      serverRecord.head.deleted === 0,
    'server did not retain exactly one replacement version, event, receipt, and current head');

    setStage('verify local outbox preserved the original immutable attempt as superseded');
    const clientSqlite = await readClientDatabaseFromIndexedDb(editorPage);
    assertThat(clientSqlite.available && Array.isArray(clientSqlite.sqliteFiles),
      `Editor IndexedDB SQLite snapshot was unavailable: ${clientSqlite.reason || 'unknown'}`);
    const clientOutbox = inspectClientOutboxHistory(
      clientSqlite.sqliteFiles, sharedVaultId, staleOperation);
    assertThat(clientOutbox.integrityCheck === 'ok' &&
      clientOutbox.originalRowCount === 1 && clientOutbox.original &&
      clientOutbox.original.status === 'superseded' &&
      clientOutbox.original.opId === staleOperation.opId &&
      clientOutbox.original.recordId === baselineOperation.recordId &&
      clientOutbox.original.envelopeSha256 === staleOperation.envelopeDigest &&
      clientOutbox.activePendingCount === 0,
    'local outbox did not preserve the original immutable envelope as superseded history');
    if (MULTI_RECORD) {
      const secondStaleOperation = stalePush.operations.find((op) =>
        op.recordId === secondBaselineOperation.recordId && op.operation === 'update');
      const secondOutbox = inspectClientOutboxHistory(
        clientSqlite.sqliteFiles, sharedVaultId, secondStaleOperation);
      assertThat(secondOutbox.integrityCheck === 'ok' &&
        secondOutbox.originalRowCount === 1 && secondOutbox.original &&
        secondOutbox.original.status === 'superseded' &&
        secondOutbox.original.opId === secondStaleOperation.opId &&
        secondOutbox.original.recordId === secondBaselineOperation.recordId &&
        secondOutbox.original.envelopeSha256 === secondStaleOperation.envelopeDigest &&
        secondOutbox.activePendingCount === 0,
      'second original outbox envelope was not retained immutably as superseded history');
    }

    setStage(`verify server storage and all observed API bodies omit ${CREDENTIAL_ONLY ? 'Credential' : 'Host'} plaintext`);
    assertThat(!serverDatabaseContainsMarker(fixtureMarkers()),
      'server SQLite database or WAL contained a fixture plaintext marker');
    await waitFor(() => Promise.resolve(apiPrivacyChecks.length > 0 &&
      apiPrivacyChecks.every((check) => check.markerFree)), 15000,
    'an observed API request or response contained fixture plaintext');

    setStage(`verify Owner pulls and decrypts the recovered ${CREDENTIAL_ONLY ? 'Password Credential' : 'Host'}`);
    const ownerPullSequenceFloor = recoveredPush.sequence;
    setStage('Owner opens the record view and requests current changes');
    await openFixturePage(ownerPage);
    await syncNow(ownerPage);
    setStage('verify Owner displays the recovered Host');
    await waitFixture(ownerPage, true, true, 45000);
    setStage('verify Owner received the exact replacement change event');
    await waitFor(() => changeEvents.some((event) =>
      event.profile === 'owner' && event.responseStatus === 200 &&
      event.sequence > ownerPullSequenceFloor &&
      event.recordId === baselineOperation.recordId &&
      event.revisionId === recoveredOperation.revisionId &&
      event.opId === recoveredOperation.opId &&
      event.envelopeDigest === recoveredOperation.envelopeDigest &&
      event.envelopeShapeValid && !event.containsFixturePlaintext),
    30000, 'second profile did not pull the exact replacement envelope');
    if (MULTI_RECORD) {
      setStage('verify Owner received the exact second replacement change event');
      await waitFor(() => changeEvents.some((event) =>
        event.profile === 'owner' && event.responseStatus === 200 &&
        event.sequence > ownerPullSequenceFloor &&
        event.recordId === secondBaselineOperation.recordId &&
        event.revisionId === secondRecoveredOperation.revisionId &&
        event.opId === secondRecoveredOperation.opId &&
        event.envelopeDigest === secondRecoveredOperation.envelopeDigest &&
        event.envelopeShapeValid && !event.containsFixturePlaintext),
      30000, 'Owner did not pull the exact second replacement envelope');
    }
    if (CREDENTIAL_ONLY) {
      setStage('allow Owner change-event projection to settle before opening credential editor');
      await ownerPage.waitForTimeout(1000);
      setStage('read Owner Password field with bounded projection-hydration retry');
      const ownerPasswordState = await readCredentialPassword(ownerPage);
      assertThat(ownerPasswordState.valueMatchesExpected,
        'second profile did not decrypt the updated Password Credential secret');
    } else {
      await waitFixture(ownerPage, false, false, 10000);
      if (MULTI_RECORD) {
        await waitHost(ownerPage, SECOND_EDITED_HOST_NAME, true, 20000);
        await waitHost(ownerPage, SECOND_BASE_HOST_NAME, false, 10000);
      }
    }

    if (MULTI_RECORD) {
      const secondServerRecord = serverRecordSnapshot(
        sharedVaultId, secondBaselineOperation.recordId);
      const secondStaleOperation = stalePush.operations.find((op) =>
        op.recordId === secondBaselineOperation.recordId && op.operation === 'update');
      assertThat(secondRecoveredOperation && secondServerRecord.versions.length === 2 &&
        secondServerRecord.receipts.length === 2 && secondServerRecord.events.length === 2 &&
        secondServerRecord.versions[0].revisionId === secondBaselineOperation.revisionId &&
        secondServerRecord.versions[1].revisionId === secondRecoveredOperation.revisionId &&
        secondServerRecord.versions[1].baseRevisionId === secondBaselineOperation.revisionId &&
        secondServerRecord.versions[1].envelopeDigest === secondRecoveredOperation.envelopeDigest &&
        secondServerRecord.receipts.some((receipt) =>
          receipt.opId === secondRecoveredOperation.opId &&
          receipt.revisionId === secondRecoveredOperation.revisionId) &&
        !secondServerRecord.receipts.some((receipt) => receipt.opId === secondStaleOperation.opId) &&
        secondServerRecord.events[1].eventType === 'update' &&
        secondServerRecord.head?.revisionId === secondRecoveredOperation.revisionId &&
        secondServerRecord.head.deleted === 0 &&
        secondRecoveredOperation.envelopeShapeValid &&
        secondRecoveredOperation.ciphertextFieldsPresent &&
        secondRecoveredOperation.opId !== secondStaleOperation.opId &&
        secondRecoveredOperation.revisionId !== secondStaleOperation.revisionId &&
        secondRecoveredOperation.envelopeDigest !== secondStaleOperation.envelopeDigest &&
        pageErrors.length === 0,
      'second Host did not converge to exactly one current-epoch replacement with a clean Owner pull');
    }
    assertThat(pageErrors.length === 0,
      'Flutter Web raised a runtime error in an isolated profile');

    console.log(`${TEST_ID} passed`, JSON.stringify({
      profiles: 3,
      targetRecordKind: CREDENTIAL_ONLY ? 'password-credential' : 'host',
      targetRecordCount: MULTI_RECORD ? 2 : 1,
      multiRecordBatchFallbackReached: MULTI_RECORD,
      secondMemberRoleChangeAdvancedMembershipVersion: true,
      secondMemberRoleChangeRotatedKeyEpoch: true,
      editorRetainedActiveWriteAccess: true,
      editorOutboxWasPendingOffline: pendingBefore >= 1,
      serverLedgerUnchangedBeforeReconnectPush: true,
      editorPageStayedOpenAcrossOutage: true,
      visibleSyncActionTriggered: visibleSyncTriggered,
      staleEnvelopeRejectedWithKeyEpochOutdated: true,
      staleRejectionCreatedNoReceiptOrLedgerChange: true,
      currentDescriptorKeyEnvelopeAndSignedMembershipReloaded: true,
      sameSessionRecoveredAndReencrypted: true,
      replacementUsesRotatedEpochAndMembershipVersion: true,
      rewrappedOperationIdentityChanged: recoveredOperation.opId !== staleOperation.opId &&
        recoveredOperation.revisionId !== staleOperation.revisionId &&
        recoveredOperation.envelopeDigest !== staleOperation.envelopeDigest,
      originalOutboxAttemptRemainsImmutableAndSuperseded: true,
      replacementCommittedOnceWithOneReceiptVersionEventAndHead: true,
      secondProfilePulledExactReplacementEnvelope: true,
      secondProfileDecryptedUpdatedPasswordCredential: CREDENTIAL_ONLY,
      APIRequestsResponsesAndServerDatabaseStayedCiphertextOnly:
        apiPrivacyChecks.length > 0 && apiPrivacyChecks.every((check) => check.markerFree),
      runtimeErrorCount: pageErrors.length,
    }));
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'disposable server/browser fixtures did not all clean up');
  console.log(`${TEST_ID} cleanup passed`);
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
      vaultIdValid: event.vaultIdValid,
      responseProcessed: event.responseProcessed,
      targetIdentityPresent: event.requestHasTargetIdentity,
      tokenPresent: event.tokenPresent,
    })),
    rotations: rotationEvents.slice(-4).map((event) => ({
      profile: event.profile,
      sequence: event.sequence,
      status: event.status,
      activeEpoch: event.activeEpoch,
      membershipVersion: event.membershipVersion,
      responseProcessed: event.responseProcessed,
    })),
    browserStates: await Promise.all([
      ['owner', ownerPage],
      ['editor', editorPage],
      ['rotatedMember', inviteePage],
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
  console.error(`${TEST_ID} failed at ${stage} (${errorClass}); fixture values omitted`);
  console.error(`safe diagnostics: ${JSON.stringify(safeDiagnostics)}`);
  if (!cleanupFailed) process.exitCode = 1;
  else process.exitCode = 2;
});
