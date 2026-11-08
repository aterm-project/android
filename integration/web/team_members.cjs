/*
 * WEB-TEAM-01: exercise a real invited account and Vault membership lifecycle
 * through three independent Flutter Web profiles on a disposable server.
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
let ownerSecondaryContext;
let bootstrapToken;
let accountInvitationToken;
let vaultInvitationToken;
let oldVaultInvitationToken;
let revokedVaultInvitationToken;
let acceptedVaultInvitationToken;
let ownerUsername;
let memberUsername;
let ownerPassword;
let memberPassword;
let databasePath;
let cleanupPromise;
let cleanupFailed = false;
let safeApiTrace = [];
let safeUiTrace = [];
let roleRotationApiTrace = [];
let safeControllerTrace = [];
let captureRoleRotationApiTrace = false;
let captureViewerSyncPushProbe = false;
let viewerSyncPushProbe = null;
let currentMemberBearer = null;
let ownerAccountId;
let ownerDeviceId;
let memberAccountId;
let memberDeviceId;
let vaultInvitationAuditIds = [];
const pendingApiRequests = new Map();
let nextApiRequestId = 0;
let expectedSharedVaultId = null;
let safeFailureReason = null;

function assertThat(condition, message) {
  if (!condition) {
    safeFailureReason = message;
    throw new Error(message);
  }
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
    oldVaultInvitationToken = undefined;
    revokedVaultInvitationToken = undefined;
    acceptedVaultInvitationToken = undefined;
    ownerUsername = undefined;
    memberUsername = undefined;
    ownerPassword = undefined;
    memberPassword = undefined;
    viewerSyncPushProbe = null;
    captureViewerSyncPushProbe = false;
    currentMemberBearer = null;
    ownerAccountId = undefined;
    ownerDeviceId = undefined;
    memberAccountId = undefined;
    memberDeviceId = undefined;
    vaultInvitationAuditIds = [];
    try {
      if (ownerContext) await ownerContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (ownerSecondaryContext) await ownerSecondaryContext.close().catch(() => {});
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
  const matches = page.getByRole('button', {
    name: label,
    ...(typeof label === 'string' ? { exact: true } : {}),
  });
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
  throw new Error(`visible control not found: ${String(label)}`);
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
  let inputRetained = false;
  let clipboardReadbackMatches = false;
  let directFillFallback = false;
  try {
    await page.evaluate(async (clipboardValue) => navigator.clipboard.writeText(clipboardValue), value);
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(500);
    visibleAfter = await locator.isVisible().catch(() => false);
    inputRetained = await locator.inputValue().then((current) => current === value).catch(() => false);
    clipboardReadbackMatches = await page.evaluate(async (clipboardValue) =>
      navigator.clipboard.readText().then((current) => current === clipboardValue).catch(() => false), value);
    if (!inputRetained && clipboardReadbackMatches) {
      // Headless Chromium can occasionally drop the keyboard paste event
      // after a dialog transition even though its clipboard API is healthy.
      await locator.fill(value);
      inputRetained = await locator.inputValue().then((current) => current === value).catch(() => false);
      directFillFallback = inputRetained;
    }
    if (inputRetained) {
      await locator.press('Tab');
      if (directFillFallback) {
        safeUiTrace.push({
          profile: profile || 'unknown',
          point: 'clipboard-paste-fallback',
          field: label,
          clipboard_readback_matches: clipboardReadbackMatches,
        });
      }
      return;
    }
    throw new Error('clipboard content was not retained');
  } catch (_) {
    safeUiTrace.push({
      profile: profile || 'unknown',
      point: 'clipboard-paste-failed',
      field: label,
      locator_found: true,
      visible_at_start: visibleAtStart,
      visible_after: visibleAfter,
      input_retained: inputRetained,
      clipboard_readback_matches: clipboardReadbackMatches,
      direct_fill_fallback: directFillFallback,
      page_errors: pageErrors?.count ?? null,
    });
    throw new Error('clipboard text was not retained in the form field');
  }
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
  if (pathname === '/api/v1/auth/recovery/contexts') return 'recovery-contexts';
  if (pathname === '/api/v1/auth/recovery/key-envelopes') return 'recovery-key-envelopes';
  if (pathname === '/api/v1/devices') return 'device-directory';
  if (pathname === '/api/v1/vaults') return 'vault-list';
  if (/^\/api\/v1\/vaults\/[^/]+\/devices$/.test(pathname)) return 'vault-device-directory';
  if (/^\/api\/v1\/vaults\/[^/]+\/membership$/.test(pathname)) return 'vault-membership';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflict-changes$/.test(pathname)) return 'vault-conflict-changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts\/[^/]+\/resolve$/.test(pathname)) return 'vault-conflict-resolve';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts$/.test(pathname)) return 'vault-conflicts';
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) return 'vault-changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/snapshots$/.test(pathname)) return 'vault-snapshot-create';
  if (/^\/api\/v1\/snapshots\/[^/]+$/.test(pathname)) return 'vault-snapshot-get';
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'vault-sync-push';
  if (/^\/api\/v1\/vaults\/[^/]+\/invitations$/.test(pathname)) return 'vault-invite';
  if (/^\/api\/v1\/invitations\/accept$/.test(pathname)) return 'vault-accept';
  if (/^\/api\/v1\/vaults\/[^/]+\/keys\/rotate$/.test(pathname)) return 'vault-rotate';
  if (/^\/api\/v1\/vaults\/[^/]+\/members$/.test(pathname)) return 'vault-members';
  if (pathname === '/api/v1/audit') return 'audit';
  if (/^\/api\/v1\/vaults\/[^/]+\/presence$/.test(pathname)) return 'vault-presence';
  return null;
}

function trackApi(page, profile, events, pageErrors) {
  const requestData = new WeakMap();
  page.on('request', (request) => {
    const route = classifyRequest(request);
    if (!route) return;
    const authorization = request.headers().authorization || '';
    const metadata = {
      request_id: ++nextApiRequestId,
      request_started_at: Date.now(),
      profile,
      route,
      method: request.method(),
      hasBearer: authorization.startsWith('Bearer ') && authorization.length > 7,
      ...(route.startsWith('vault-') && (() => {
        const path = new URL(request.url()).pathname;
        const match = path.match(/^\/api\/v1\/vaults\/([^/]+)/);
        return match ? { expected_vault_match: expectedSharedVaultId === null || match[1] === expectedSharedVaultId } : {};
      })()),
      ...(route === 'vault-sync-push' ? {
        operation_count: (() => {
          try {
            const operations = request.postDataJSON()?.operations;
            return Array.isArray(operations) ? operations.length : null;
          } catch (_) {
            return null;
          }
        })(),
      } : {}),
    };
    if (captureViewerSyncPushProbe && profile === 'member' &&
        route === 'vault-sync-push' && request.method() === 'POST') {
      try {
        const body = request.postData();
        const payload = JSON.parse(body || 'null');
        const pathname = new URL(request.url()).pathname;
        const match = pathname.match(/^\/api\/v1\/vaults\/([^/]+)\/sync\/push$/);
        if (match?.[1] === expectedSharedVaultId &&
            payload?.vault_id === expectedSharedVaultId &&
            Array.isArray(payload?.operations) && payload.operations.length === 1 &&
            authorization.startsWith('Bearer ')) {
          // Keep the already-accepted signed request and bearer only in memory;
          // replay it later to prove Viewer ACLs fence even a valid retry.
          viewerSyncPushProbe = {
            request_id: metadata.request_id,
            url: request.url(),
            authorization,
            body,
          };
          captureViewerSyncPushProbe = false;
        }
      } catch (_) {
        // A later assertion reports if no suitable signed write was captured.
      }
    }
    requestData.set(request, metadata);
    pendingApiRequests.set(request, metadata);
  });
  page.on('response', async (response) => {
    const request = response.request();
    pendingApiRequests.delete(request);
    const metadata = requestData.get(request);
    if (metadata?.profile === 'member' && metadata.hasBearer) {
      const authorization = request.headers().authorization || '';
      currentMemberBearer = response.status() === 401 || !authorization.startsWith('Bearer ')
        ? null : authorization;
    }
    if (metadata) {
      const event = { ...metadata, status: response.status(), sequence: events.length };
      event.payloadPromise = response.body().then((bytes) => {
        event.responseBodyLength = bytes.length;
        return JSON.parse(bytes.toString('utf8'));
      }).catch(() => null);
      events.push(event);
      const safeEntry = {
        profile,
        route: metadata.route,
        method: metadata.method,
        status: event.status,
        duration_ms: Math.max(0, Date.now() - metadata.request_started_at),
        content_type: response.headers()['content-type'] || null,
      };
      if (typeof metadata.expected_vault_match === 'boolean') {
        safeEntry.expected_vault_match = metadata.expected_vault_match;
      }
      if (metadata.route === 'instance' || metadata.route === 'vault-invite' ||
          metadata.route === 'vault-members' || metadata.route === 'vault-presence' ||
          metadata.route === 'recovery-contexts' ||
          metadata.route === 'device-directory' || metadata.route === 'vault-device-directory' ||
          metadata.route === 'vault-membership' ||
          metadata.route === 'vault-changes' || metadata.route === 'vault-snapshot-create' ||
          metadata.route === 'vault-snapshot-get' || metadata.route === 'vault-sync-push' ||
          metadata.route === 'vault-list' || metadata.route === 'vault-conflict-changes' ||
          metadata.route === 'vault-conflicts' || metadata.route === 'vault-conflict-resolve' ||
          metadata.route === 'audit') {
        try {
          const body = await event.payloadPromise;
          if (body === null) safeEntry.response_body_bytes = event.responseBodyLength ?? null;
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
          } else if (metadata.route === 'vault-presence') {
            const devices = Array.isArray(body?.devices) ? body.devices : [];
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              device_count: devices.length,
              device_keys: devices[0] && typeof devices[0] === 'object'
                ? Object.keys(devices[0]).sort() : [],
              ttl_seconds: typeof body?.ttl_seconds === 'number' ? body.ttl_seconds : null,
            };
          } else if (metadata.route === 'device-directory' ||
              metadata.route === 'vault-device-directory') {
            const devices = Array.isArray(body?.devices) ? body.devices : [];
            const statusCounts = {};
            for (const device of devices) {
              const status = typeof device?.status === 'string' ? device.status : 'unknown';
              statusCounts[status] = (statusCounts[status] || 0) + 1;
            }
            safeEntry.response_shape = {
              device_count: devices.length,
              status_counts: statusCounts,
              valid_device_id_count: devices.filter((device) =>
                typeof device?.device_id === 'string' && /^[0-9a-f-]{36}$/i.test(device.device_id)).length,
              valid_signing_key_count: devices.filter((device) =>
                typeof device?.signing_public_key === 'string' && device.signing_public_key.length > 0).length,
            };
          } else if (metadata.route === 'vault-membership') {
            const manifests = Array.isArray(body?.manifests) ? body.manifests
              : Array.isArray(body?.memberships) ? body.memberships
              : Array.isArray(body?.entries) ? body.entries
              : Array.isArray(body?.chain) ? body.chain : [];
            const latest = manifests.at(-1);
            const manifest = latest?.manifest?.manifest || latest?.manifest || {};
            safeEntry.response_shape = {
              manifest_count: manifests.length,
              latest_version: Number.isSafeInteger(latest?.membership_version)
                ? latest.membership_version : null,
              latest_key_epoch: Number.isSafeInteger(manifest?.key_epoch)
                ? manifest.key_epoch : null,
              member_count: Array.isArray(manifest?.members) ? manifest.members.length : null,
              signature_present: typeof latest?.signature === 'string' && latest.signature.length > 0,
            };
          } else if (metadata.route === 'recovery-contexts') {
            const required = Array.isArray(body?.required) ? body.required : [];
            const present = Array.isArray(body?.present) ? body.present : [];
            safeEntry.response_shape = {
              recovery_status: typeof body?.status === 'string' ? body.status : null,
              required_context_count: required.length,
              present_context_count: present.length,
              generation_valid: Number.isSafeInteger(body?.generation) && body.generation > 0,
              identity_envelope_present: Boolean(body?.identity_envelope),
            };
          } else if (metadata.route === 'vault-changes') {
            const changes = Array.isArray(body?.events) ? body.events : [];
            const eventTypes = {};
            for (const item of changes) {
              const type = typeof item?.event_type === 'string' ? item.event_type : 'unknown';
              eventTypes[type] = (eventTypes[type] || 0) + 1;
            }
            safeEntry.response_shape = {
              event_count: changes.length,
              event_types: eventTypes,
              has_more: typeof body?.has_more === 'boolean' ? body.has_more : null,
              next_cursor_present: typeof body?.next_cursor === 'string' && body.next_cursor.length > 0,
              generation_valid: typeof body?.server_generation === 'string' && /^[0-9a-f-]{36}$/i.test(body.server_generation),
            };
          } else if (metadata.route === 'vault-snapshot-create') {
            safeEntry.response_shape = {
              snapshot_id_valid: typeof body?.snapshot_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.snapshot_id),
              high_watermark_valid: typeof body?.high_watermark === 'string' && /^(0|[1-9][0-9]*)$/.test(body.high_watermark),
              next_cursor_present: typeof body?.next_cursor === 'string' && body.next_cursor.length > 0,
            };
          } else if (metadata.route === 'vault-snapshot-get') {
            const manifest = Array.isArray(body?.manifest) ? body.manifest : [];
            safeEntry.response_shape = {
              manifest_count: manifest.length,
              opaque_envelope_count: manifest.filter((item) =>
                item?.envelope && typeof item.envelope === 'object' &&
                typeof item.envelope.ciphertext === 'string').length,
              high_watermark_valid: typeof body?.high_watermark === 'string' && /^(0|[1-9][0-9]*)$/.test(body.high_watermark),
              next_cursor_present: typeof body?.next_cursor === 'string' && body.next_cursor.length > 0,
            };
          } else if (metadata.route === 'vault-sync-push') {
            const results = Array.isArray(body?.results) ? body.results : [];
            safeEntry.response_shape = {
              operation_count: metadata.operation_count,
              receipt_count: results.length,
              already_committed_count: results.filter((item) => item?.already_committed === true).length,
            };
          } else if (metadata.route === 'vault-list') {
            const vaults = Array.isArray(body?.vaults) ? body.vaults : [];
            const shared = vaults.find((item) => item?.vault_id === expectedSharedVaultId);
            const roleStates = {};
            for (const item of vaults) {
              const key = `${String(item?.role || 'unknown')}:${String(item?.status || 'unknown')}`;
              roleStates[key] = (roleStates[key] || 0) + 1;
            }
            safeEntry.response_shape = {
              vault_count: vaults.length,
              role_states: roleStates,
              writable_vault_count: vaults.filter((item) => item?.can_write === true).length,
              expected_shared_vault_present: Boolean(shared),
              expected_shared_vault_role: typeof shared?.role === 'string' ? shared.role : null,
              expected_shared_vault_state: typeof shared?.status === 'string' ? shared.status : null,
            };
          } else if (metadata.route === 'vault-conflict-changes') {
            const conflicts = Array.isArray(body?.events) ? body.events : [];
            const eventTypes = {};
            for (const item of conflicts) {
              const type = typeof item?.type === 'string' ? item.type : 'unknown';
              eventTypes[type] = (eventTypes[type] || 0) + 1;
            }
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              event_count: conflicts.length,
              event_types: eventTypes,
              opaque_envelope_count: conflicts.filter((item) =>
                item?.envelope && typeof item.envelope === 'object' &&
                typeof item.envelope.ciphertext === 'string').length,
              high_watermark_valid: typeof body?.high_watermark === 'string' && /^(0|[1-9][0-9]*)$/.test(body.high_watermark),
              next_after_seq_valid: typeof body?.next_after_seq === 'string' && /^(0|[1-9][0-9]*)$/.test(body.next_after_seq),
              has_more: typeof body?.has_more === 'boolean' ? body.has_more : null,
            };
      } else if (metadata.route === 'vault-conflicts' && metadata.method === 'POST') {
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              status: typeof body?.status === 'string' ? body.status : null,
              conflict_id_valid: typeof body?.conflict_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.conflict_id),
              record_id_valid: typeof body?.record_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.record_id),
              revision_id_valid: typeof body?.revision_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.revision_id),
            };
          } else if (metadata.route === 'vault-conflicts') {
            const conflicts = Array.isArray(body?.conflicts) ? body.conflicts : [];
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              conflict_count: conflicts.length,
              opaque_envelope_count: conflicts.filter((item) =>
                item?.envelope && typeof item.envelope === 'object' &&
                typeof item.envelope.ciphertext === 'string').length,
              high_watermark_valid: typeof body?.high_watermark === 'string' && /^(0|[1-9][0-9]*)$/.test(body.high_watermark),
              conflict_high_watermark_valid: typeof body?.conflict_high_watermark === 'string' && /^(0|[1-9][0-9]*)$/.test(body.conflict_high_watermark),
              has_more: typeof body?.has_more === 'boolean' ? body.has_more : null,
            };
      } else if (metadata.route === 'vault-conflict-resolve') {
            safeEntry.response_shape = {
              keys: Object.keys(body || {}).sort(),
              status: typeof body?.status === 'string' ? body.status : null,
              resolved_revision_id_valid: typeof body?.resolved_revision_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.resolved_revision_id),
              resolution_seq_valid: typeof body?.resolution_seq === 'string' && /^(0|[1-9][0-9]*)$/.test(body.resolution_seq),
              already_resolved: typeof body?.already_resolved === 'boolean' ? body.already_resolved : null,
            };
          } else if (metadata.route === 'audit') {
            const auditEvents = Array.isArray(body?.events) ? body.events : [];
            const scopes = {};
            const actions = {};
            for (const item of auditEvents) {
              const scope = typeof item?.scope === 'string' ? item.scope : 'unknown';
              const action = typeof item?.action === 'string' ? item.action : 'unknown';
              scopes[scope] = (scopes[scope] || 0) + 1;
              actions[action] = (actions[action] || 0) + 1;
            }
            safeEntry.response_shape = {
              event_count: auditEvents.length,
              scopes,
              actions,
              has_more: typeof body?.has_more === 'boolean' ? body.has_more : null,
            };
          } else {
            const members = Array.isArray(body?.members) ? body.members : [];
            const roleStates = {};
            const memberUserIds = members
              .map((item) => item?.user_id)
              .filter((userId) => typeof userId === 'string' && userId.length > 0);
            for (const item of members) {
              const key = `${String(item?.role || 'unknown')}:${String(item?.state || 'unknown')}`;
              roleStates[key] = (roleStates[key] || 0) + 1;
            }
            const invitationStates = members
              .filter((item) => item?.state === 'invited')
              .map((item) => ({
                status: typeof item?.invitation?.status === 'string' ? item.invitation.status : null,
                has_expiry: typeof item?.invitation?.expires_at === 'string',
              }));
            safeEntry.response_shape = {
              member_count: members.length,
              unique_user_count: new Set(memberUserIds).size,
              duplicate_user_count: memberUserIds.length - new Set(memberUserIds).size,
              role_states: roleStates,
              invitation_states: invitationStates,
            };
          }
        } catch (_) {
          safeEntry.response_shape = { json: false };
        }
      }
      safeApiTrace.push(safeEntry);
      if (safeApiTrace.length > 30) safeApiTrace = safeApiTrace.slice(-30);
      if (captureRoleRotationApiTrace) {
        roleRotationApiTrace.push(safeEntry);
        if (roleRotationApiTrace.length > 80) roleRotationApiTrace.shift();
      }
    }
  });
  page.on('requestfailed', (request) => {
    const route = classifyRequest(request);
    if (!route) return;
    pendingApiRequests.delete(request);
    safeApiTrace.push({ profile, route, method: request.method(), transport_failed: true });
    if (safeApiTrace.length > 30) safeApiTrace = safeApiTrace.slice(-30);
  });
  page.on('console', (message) => {
    if (!captureRoleRotationApiTrace || profile !== 'owner') return;
    const match = message.text().match(/^ATERMIUS_TEAM_TRACE:([A-Za-z0-9_.:-]+)$/);
    if (!match) return;
    safeControllerTrace.push({ profile, phase: match[1] });
    if (safeControllerTrace.length > 80) safeControllerTrace.shift();
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

async function waitEventMethod(events, profile, route, method, after = -1, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = events.find((event) =>
      event.profile === profile && event.route === route &&
      event.method === method && event.sequence > after);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`expected ${profile} ${method} ${route} API response did not arrive`);
}

function assertStatus(event, expected, label) {
  console.log(`observed: ${label}_http_status=${event.status}`);
  assertThat(event.status === expected, `${label} response had unexpected status`);
  if (['vault-invite', 'vault-accept', 'vault-rotate', 'vault-members', 'vault-presence',
    'vault-changes', 'vault-snapshot-create', 'vault-snapshot-get', 'vault-sync-push', 'vault-list',
    'vault-conflict-changes', 'vault-conflicts', 'vault-conflict-resolve'].includes(event.route) &&
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
    '2 devices online',
    '1 device online',
    'No devices online',
    'EDITOR · Invitation pending',
    'VIEWER · Invitation pending',
    'EDITOR · Invitation expired',
    'VIEWER · Invitation expired',
    'EDITOR · Invitation needs reissue',
    'VIEWER · Invitation needs reissue',
    'OWNER · Active',
    'EDITOR · Active',
    'VIEWER · Active',
    'INVITED',
    'EXPIRED',
    'NEEDS REISSUE',
    'ACTIVE',
    'REVOKED',
    'EDITOR · Revoked',
    'Invitation pending',
    'Invitation expires',
    'Invitation expired',
    'Invitation needs reissue',
    'Invite member',
    'Settings > Invite member',
    'Make viewer',
    'Make editor',
    'Revoke access',
    'Revoke invitation',
    'Transfer ownership',
    'View Vault members',
    'Change to viewer',
    'Change to editor',
    'Revoke and rotate key',
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

async function safeMembershipRotationUiState(page) {
  const labels = await staticMembershipSemantics(page);
  const registration = await safeOwnerRegistrationState(page);
  const bodyText = await page.locator('body').innerText().catch(() => '');
  return {
    viewer_active_visible: labels.includes('VIEWER · Active'),
    editor_active_visible: labels.includes('EDITOR · Active'),
    owner_active_visible: labels.includes('OWNER · Active'),
    login_form_visible: registration.login_username_visible,
    rotation_lock_error_visible: bodyText.includes('成员轮换结果暂时无法确认'),
    rotation_commit_error_visible: bodyText.includes('服务端成员轮换已提交'),
    rotation_success_notice_visible: bodyText.includes('成员角色已更新'),
    generic_error_word_visible: /\b(?:error|failed|unable)\b/i.test(bodyText),
  };
}

async function syncNow(page, options = {}) {
  const syncButton = page.getByRole('button', {
    name: /^(Idle|Pending|\d+ pending|Syncing|Retry queued|Offline|Sync error|Read-only)$/,
  }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 20000 });
  await waitFor(() => syncButton.isEnabled(), 30000);
  await syncButton.click();
  if (typeof options.completeWhen === 'function') {
    await waitFor(options.completeWhen, options.timeoutMs ?? 30000);
    return;
  }
  await page.getByRole('button', { name: 'Idle', exact: true }).waitFor({
    state: 'visible',
    timeout: 30000,
  });
}

async function safeSyncStatusLabelCounts(page) {
  const labels = ['Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error', 'Read-only'];
  const counts = {};
  for (const label of labels) {
    counts[label] = await page.getByRole('button', { name: label, exact: true }).count().catch(() => 0);
  }
  counts['N pending'] = await page.getByRole('button', { name: /^\d+ pending$/ }).count().catch(() => 0);
  return counts;
}

async function safeHostHandoffState(page, targetHostName, pageErrors) {
  const body = await page.locator('body').innerText().catch(() => '');
  const escaped = targetHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const hostCount = await page.getByRole('group', { name: /^Host:/ }).count().catch(() => null);
  const targetHostCount = await hostCardGroup(page, targetHostName).count().catch(() => null);
  const broadTargetGroupCount = await page.getByRole('group', { name: new RegExp(escaped) }).count().catch(() => null);
  const addHost = page.getByRole('button', { name: 'Add host', exact: true });
  const addHostCount = await addHost.count().catch(() => 0);
  const statusLabels = ['Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error'];
  let syncStatus = null;
  for (const label of statusLabels) {
    if (await page.getByRole('button', { name: label, exact: true }).isVisible().catch(() => false)) {
      syncStatus = label;
      break;
    }
  }
  if (syncStatus === null && await page.getByRole('button', { name: /^\d+ pending$/ }).isVisible().catch(() => false)) {
    syncStatus = 'pending';
  }
  return {
    shared_vault_name_visible: body.includes('Team lifecycle Vault'),
    editor_key_epoch_visible: /editor\s*·\s*key epoch/i.test(body),
    hosts_navigation_visible: await page.getByRole('button', { name: 'Hosts', exact: true }).isVisible().catch(() => false),
    host_count: hostCount,
    target_host_count: targetHostCount,
    broad_target_group_count: broadTargetGroupCount,
    add_host_button_count: addHostCount,
    add_host_enabled: addHostCount > 0 ? await addHost.first().isEnabled().catch(() => false) : false,
    sync_status: syncStatus,
    page_error_count: pageErrors?.count ?? null,
  };
}

async function safeConflictReviewState(page, pageErrors) {
  const buttonCount = async (name) => page.getByRole('button', { name, exact: true }).count().catch(() => 0);
  return {
    conflicts_page_visible: await page.getByText('Conflict branches', { exact: true }).isVisible().catch(() => false),
    keep_device_version_button_count: await buttonCount('Keep this device version'),
    use_synced_version_button_count: await buttonCount('Use synced version'),
    create_resolution_button_count: await buttonCount('Create resolution'),
    page_error_count: pageErrors?.count ?? null,
  };
}

function hostCardGroup(page, hostName) {
  const escaped = hostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('group', { name: new RegExp(`^Host: ${escaped};`) });
}

async function editHostDisplayName(page, oldName, newName) {
  const card = hostCardGroup(page, oldName);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await fill(page, 'Display name', newName);
  await click(page, 'Save encrypted host');
  await hostCardGroup(page, newName).waitFor({ state: 'visible', timeout: 15000 });
}

function updatePendingInvitation({ username, expiresAt, keyEpoch, membershipVersion }) {
  const script = [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1],timeout=5)',
    'row=db.execute("SELECT i.invitation_id,i.key_envelope FROM invitations i JOIN users u ON u.user_id=i.recipient_user_id WHERE u.username=? AND i.accepted_at IS NULL ORDER BY i.issuance_order DESC,i.created_at DESC,i.invitation_id DESC LIMIT 1", (sys.argv[2],)).fetchone()',
    'assert row',
    'envelope=json.loads(row[1])',
    'if sys.argv[4]: envelope["key_epoch"]=int(sys.argv[4])',
    'if sys.argv[5]: envelope["membership_version"]=int(sys.argv[5])',
    'cursor=db.execute("UPDATE invitations SET expires_at=?,key_envelope=? WHERE invitation_id=?", (sys.argv[3],json.dumps(envelope,separators=(",",":")),row[0]))',
    'db.commit()',
    'print(cursor.rowcount)',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, username, expiresAt,
    keyEpoch == null ? '' : String(keyEpoch), membershipVersion == null ? '' : String(membershipVersion)], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0 && result.stdout.trim() === '1',
    'isolated invitation status fixture was not updated');
}

function readTeamInvitationSnapshot({ ownerUsername, memberUsername }) {
  const script = [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1],timeout=5)',
    'db.row_factory=sqlite3.Row',
    'owner,member=sys.argv[2:4]',
    'owner_id=db.execute("SELECT user_id FROM users WHERE username=?",(owner,)).fetchone()',
    'member_id=db.execute("SELECT user_id FROM users WHERE username=?",(member,)).fetchone()',
    'assert owner_id and member_id',
    'vault=db.execute("SELECT vault_id,active_epoch,membership_version FROM vaults WHERE owner_user_id=? AND state=\'active\' ORDER BY created_at LIMIT 1",(owner_id[0],)).fetchone()',
    'assert vault',
    'vault_id=vault["vault_id"]',
    'membership=db.execute("SELECT role,state FROM vault_members WHERE vault_id=? AND user_id=?",(vault_id,member_id[0])).fetchone()',
    'assert membership',
    'invitation=db.execute("SELECT invitation_id,accepted_at,expires_at,issuance_order FROM invitations WHERE vault_id=? AND recipient_user_id=? ORDER BY issuance_order DESC,created_at DESC,invitation_id DESC LIMIT 1",(vault_id,member_id[0])).fetchone()',
    'assert invitation',
    'manifest=db.execute("SELECT membership_version,digest,signature FROM membership_manifests WHERE vault_id=? ORDER BY membership_version DESC LIMIT 1",(vault_id,)).fetchone()',
    'assert manifest',
    'manifest_count=db.execute("SELECT COUNT(*) FROM membership_manifests WHERE vault_id=?",(vault_id,)).fetchone()[0]',
    'print(json.dumps({"vault_id":vault_id,"active_epoch":vault["active_epoch"],"membership_version":vault["membership_version"],"member_role":membership["role"],"member_state":membership["state"],"invitation_id":invitation["invitation_id"],"invitation_accepted_at":invitation["accepted_at"],"invitation_expires_at":invitation["expires_at"],"invitation_issuance_order":invitation["issuance_order"],"manifest_count":manifest_count,"manifest_version":manifest["membership_version"],"manifest_digest":manifest["digest"],"manifest_signature":manifest["signature"]},sort_keys=True))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, ownerUsername, memberUsername], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const output = result.stdout || '';
  result.stdout = '';
  assertThat(!result.error && result.status === 0, 'isolated invitation state snapshot failed');
  try {
    return JSON.parse(output);
  } catch (_) {
    throw new Error('isolated invitation state snapshot was invalid');
  }
}

async function postVaultInvitationAccept({ baseUrl, bearer, token }) {
  assertThat(typeof bearer === 'string' && bearer.startsWith('Bearer '),
    'member session was unavailable for the invitation API probe');
  const response = await fetch(`${baseUrl}/api/v1/invitations/accept`, {
    method: 'POST',
    headers: { authorization: bearer, 'content-type': 'application/json' },
    body: JSON.stringify({ token }),
    signal: AbortSignal.timeout(10000),
  });
  let payload = null;
  try {
    payload = await response.json();
  } catch (_) {
    // The sanitized status/code assertion below fails closed.
  }
  return { status: response.status, errorCode: payload?.error?.code ?? null };
}

async function assertInvitationRejectedWithoutMutation({
  baseUrl,
  bearer,
  token,
  ownerUsername,
  memberUsername,
  expectedStatus,
  expectedCode,
  label,
}) {
  const before = readTeamInvitationSnapshot({ ownerUsername, memberUsername });
  const response = await postVaultInvitationAccept({ baseUrl, bearer, token });
  const after = readTeamInvitationSnapshot({ ownerUsername, memberUsername });
  const unchanged = JSON.stringify(after) === JSON.stringify(before);
  assertThat(response.status === expectedStatus && response.errorCode === expectedCode && unchanged,
    `${label} was not rejected with the expected server state preserved`);
  console.log(`assert: ${label}=true`);
}

function readTeamConflictSnapshot({ ownerUsername, memberUsername, recordId = null }) {
  const script = [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1],timeout=5)',
    'db.row_factory=sqlite3.Row',
    'owner,member,record=sys.argv[2:5]',
    'owner_id=db.execute("SELECT user_id FROM users WHERE username=?",(owner,)).fetchone()',
    'member_id=db.execute("SELECT user_id FROM users WHERE username=?",(member,)).fetchone()',
    'assert owner_id and member_id',
    'vault=db.execute("SELECT v.vault_id FROM vaults v JOIN vault_members a ON a.vault_id=v.vault_id JOIN vault_members b ON b.vault_id=v.vault_id WHERE v.owner_user_id=? AND v.state=\'active\' AND a.user_id=? AND a.state=\'active\' AND b.user_id=? AND b.state=\'active\'",(owner_id[0],owner_id[0],member_id[0])).fetchone()',
    'assert vault',
    'vault_id=vault[0]',
    'membership=db.execute("SELECT a.role AS owner_role,a.state AS owner_state,b.role AS member_role,b.state AS member_state FROM vault_members a JOIN vault_members b ON b.vault_id=a.vault_id WHERE a.vault_id=? AND a.user_id=? AND b.user_id=?",(vault_id,owner_id[0],member_id[0])).fetchone()',
    'counter=db.execute("SELECT last_committed_seq,last_conflict_seq FROM vault_counters WHERE vault_id=?",(vault_id,)).fetchone()',
    'out={"vault_id":vault_id,"owner_user_id":owner_id[0],"member_user_id":member_id[0],"membership":dict(membership),"last_committed_seq":counter[0],"last_conflict_seq":counter[1],"all_versions":[dict(row) for row in db.execute("SELECT r.record_id,r.revision_id,r.base_revision_id,r.commit_seq,r.device_id,d.user_id AS author_user_id,r.operation FROM record_versions r JOIN devices d ON d.device_id=r.device_id WHERE r.vault_id=? ORDER BY r.commit_seq",(vault_id,))]}',
    'if record:',
    ' head=db.execute("SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?",(vault_id,record)).fetchone()',
    ' out["head"]=dict(head) if head else None',
    ' out["versions"]=[dict(row) for row in db.execute("SELECT r.revision_id,r.base_revision_id,r.commit_seq,r.device_id,d.user_id AS author_user_id,r.operation FROM record_versions r JOIN devices d ON d.device_id=r.device_id WHERE r.vault_id=? AND r.record_id=? ORDER BY r.commit_seq",(vault_id,record))]',
    ' out["receipts"]=[dict(row) for row in db.execute("SELECT op_id,device_id,record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq",(vault_id,record))]',
    ' out["events"]=[dict(row) for row in db.execute("SELECT commit_seq,event_type,record_id,revision_id FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq",(vault_id,record))]',
    ' out["conflicts"]=[]',
    ' for row in db.execute("SELECT conflict_id,record_id,base_revision_id,resolved_revision_id,conflict_seq,resolution_seq,device_id,envelope FROM conflicts WHERE vault_id=? AND record_id=? ORDER BY conflict_seq",(vault_id,record)):',
    '  header=json.loads(row["envelope"]).get("header",{})',
    '  out["conflicts"].append({"conflict_id":row["conflict_id"],"record_id":row["record_id"],"base_revision_id":row["base_revision_id"],"resolved_revision_id":row["resolved_revision_id"],"conflict_seq":row["conflict_seq"],"resolution_seq":row["resolution_seq"],"device_id":row["device_id"],"branch_revision_id":header.get("revision_id"),"branch_device_id":header.get("device_id"),"branch_operation":header.get("operation")})',
    'print(json.dumps(out,separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, ownerUsername, memberUsername, recordId || ''], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'team conflict server snapshot query failed');
  return JSON.parse(result.stdout);
}

function assertCiphertextOnlyMarkers(markers) {
  const paths = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`];
  for (const databaseFile of paths) {
    if (!fs.existsSync(databaseFile)) continue;
    const bytes = fs.readFileSync(databaseFile);
    for (const marker of markers) {
      assertThat(!bytes.includes(Buffer.from(marker)),
        'server database exposed a synthetic host plaintext marker');
    }
  }
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
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-team-'));
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
  ownerUsername = `web-team-owner-${crypto.randomUUID().slice(0, 8)}@example.test`;
  memberUsername = `web-team-member-${crypto.randomUUID().slice(0, 8)}@example.test`;
  ownerPassword = `Owner-${crypto.randomBytes(32).toString('base64url')}`;
  memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
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
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    memberContext = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
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
    await Promise.all([
      button(ownerPage, 'Connect securely'),
      button(memberPage, 'Connect securely'),
    ]);

    setStage('Owner registration: enter server URL');
    await fill(ownerPage, 'Server URL', baseUrl);
    setStage('Owner registration: connect to instance');
    await click(ownerPage, 'Connect securely');
    setStage('Owner registration: wait for bootstrap form');
    await field(ownerPage, 'Owner email');
    safeUiTrace.push({ profile: 'owner', point: 'owner-registration-form', state: await safeOwnerRegistrationState(ownerPage) });
    setStage('Owner registration: issue local bootstrap credential');
    const bootstrapResult = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
      maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrapResult.error && bootstrapResult.status === 0, 'isolated bootstrap failed');
    bootstrapToken = (bootstrapResult.stdout || '').trim().split(/\s+/).at(-1);
    bootstrapResult.stdout = '';
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap credential is unavailable');
    setStage('Owner registration: fill account form');
    setStage('Owner registration: fill Owner email');
    await fill(ownerPage, 'Owner email', ownerUsername, { profile: 'owner', pageErrors });
    setStage('Owner registration: fill master password');
    await fill(ownerPage, 'Master password · 12+ characters', ownerPassword, { profile: 'owner', pageErrors });
    setStage('Owner registration: fill password confirmation');
    await fill(ownerPage, 'Confirm master password', ownerPassword, { profile: 'owner', pageErrors });
    setStage('Owner registration: fill bootstrap token');
    await fill(ownerPage, 'One-time bootstrap token', bootstrapToken, { profile: 'owner', pageErrors });
    setStage('Owner registration: fill device name');
    await fill(ownerPage, 'Device name', 'Team owner browser', { profile: 'owner', pageErrors });
    setStage('Owner registration: fill first Vault name');
    await fill(ownerPage, 'First Vault', 'Team lifecycle Vault', { profile: 'owner', pageErrors });
    let after = apiEvents.length - 1;
    setStage('Owner registration: submit account creation');
    await click(ownerPage, 'Create owner account');
    bootstrapToken = undefined;
    setStage('Owner registration: wait for workspace');
    await waitWorkspace(ownerPage);
    setStage('Owner registration: verify registration API');
    const ownerRegistrationEvent = await waitEvent(apiEvents, 'owner', 'register', after);
    assertStatus(ownerRegistrationEvent, 200, 'owner_registration');
    const ownerRegistration = await ownerRegistrationEvent.payloadPromise;
    ownerAccountId = ownerRegistration?.account_id;
    ownerDeviceId = ownerRegistration?.device_id;
    assertThat(/^[0-9a-f-]{36}$/i.test(ownerAccountId || '') &&
      /^[0-9a-f-]{36}$/i.test(ownerDeviceId || ''),
    'Owner registration did not return safe account and device identifiers');

    setStage('member account registration');
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
    await fill(memberPage, 'Device name', 'Team member browser');
    await fill(memberPage, 'First Vault', 'Member personal Vault');
    after = apiEvents.length - 1;
    await click(memberPage, 'Create invited account');
    await waitWorkspace(memberPage);
    const memberRegistrationEvent = await waitEvent(apiEvents, 'member', 'register', after);
    assertStatus(memberRegistrationEvent, 200, 'member_registration');
    const memberRegistration = await memberRegistrationEvent.payloadPromise;
    memberAccountId = memberRegistration?.account_id;
    memberDeviceId = memberRegistration?.device_id;
    assertThat(/^[0-9a-f-]{36}$/i.test(memberAccountId || '') &&
      /^[0-9a-f-]{36}$/i.test(memberDeviceId || ''),
    'Member registration did not return safe account and device identifiers');

    setStage('signed share request');
    await click(memberPage, 'Settings');
    await (await button(memberPage, 'Copy signed share request')).scrollIntoViewIfNeeded();
    await click(memberPage, 'Copy signed share request');
    const shareCard = await copyClipboard(memberPage, 'Copy');
    let parsedCard;
    try { parsedCard = JSON.parse(shareCard); } catch (_) { throw new Error('share request clipboard was not JSON'); }
    assertThat(parsedCard.format === 'atermius-vault-share-request-v1', 'share request format was invalid');
    assertThat(typeof parsedCard.account_id === 'string' && typeof parsedCard.device?.device_id === 'string',
      'share request did not bind an account and device');

    setStage('Owner validates device card and creates Vault invitation');
    await click(ownerPage, 'Settings');
    await (await button(ownerPage, 'Invite member')).scrollIntoViewIfNeeded();
    await click(ownerPage, 'Invite member');
    setStage('Owner pastes signed public device card');
    await paste(ownerPage, 'Public Device Card JSON', shareCard, { profile: 'owner', pageErrors });
    setStage('Owner verifies signed public device card');
    await click(ownerPage, 'Verify and review');
    await waitFor(() => ownerPage.getByText('Confirm target:', { exact: false }).isVisible());
    assertThat(await ownerPage.getByText(memberUsername, { exact: true }).count() === 0,
      'public device card review unexpectedly exposed the member login name');
    after = apiEvents.length - 1;
    setStage('Owner signs and submits Vault invitation');
    await click(ownerPage, 'Sign and create invitation');
    setStage('Waiting for Owner Vault invitation API response');
    const createInvite = await waitEvent(apiEvents, 'owner', 'vault-invite', after);
    assertStatus(createInvite, 200, 'vault_invitation');
    setStage('Owner copies one-time Vault invitation');
    vaultInvitationToken = await copyClipboard(ownerPage, 'Copy token');
    assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInvitationToken), 'Vault invitation token format was invalid');
    vaultInvitationAuditIds.push(
      readTeamInvitationSnapshot({ ownerUsername, memberUsername }).invitation_id);
    oldVaultInvitationToken = vaultInvitationToken;
    setStage('Owner opens members dialog for pending invitation');
    await click(ownerPage, 'Manage Vault members');
    setStage('Owner observes pending invitation state');
    await waitFor(async () => {
      const labels = await staticMembershipSemantics(ownerPage);
      return labels.includes('EDITOR · Invitation pending');
    });
    safeUiTrace.push({ profile: 'owner', point: 'pending-member-dialog', labels: await staticMembershipSemantics(ownerPage) });
    setStage('Owner confirms pending role and state');
    let membershipLabels = await staticMembershipSemantics(ownerPage);
    assertThat(membershipLabels.includes('EDITOR · Invitation pending'),
      'Owner did not see the expected pending member role in Web semantics');
    assertThat(membershipLabels.includes('Invitation expires'),
      'Owner did not see the pending invitation expiry');
    await click(ownerPage, 'Close');

    setStage('Owner observes expired invitation and retains revoke control');
    updatePendingInvitation({
      username: memberUsername,
      expiresAt: '2000-01-01T00:00:00+00:00',
    });
    setStage('member submits the expired Vault invitation to the server');
    await assertInvitationRejectedWithoutMutation({
      baseUrl,
      bearer: currentMemberBearer,
      token: oldVaultInvitationToken,
      ownerUsername,
      memberUsername,
      expectedStatus: 410,
      expectedCode: 'INVITATION_EXPIRED',
      label: 'expired_vault_invitation_rejected_without_state_change',
    });
    await click(ownerPage, 'Manage Vault members');
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Invitation expired'));
    membershipLabels = await staticMembershipSemantics(ownerPage);
    safeUiTrace.push({ profile: 'owner', point: 'expired-member-dialog', labels: membershipLabels });
    assertThat(membershipLabels.includes('EDITOR · Invitation expired') &&
      membershipLabels.includes('Revoke invitation') &&
      membershipLabels.includes('Settings > Invite member'),
      'expired invitation was not labeled or could not be revoked');
    await click(ownerPage, 'Close');

    setStage('Owner observes stale invitation and retains revoke control');
    updatePendingInvitation({
      username: memberUsername,
      expiresAt: '2999-01-01T00:00:00+00:00',
      keyEpoch: 999,
      membershipVersion: 999,
    });
    setStage('member submits the stale Vault invitation to the server');
    await assertInvitationRejectedWithoutMutation({
      baseUrl,
      bearer: currentMemberBearer,
      token: oldVaultInvitationToken,
      ownerUsername,
      memberUsername,
      expectedStatus: 409,
      expectedCode: 'INVITATION_STALE',
      label: 'stale_vault_invitation_rejected_without_state_change',
    });
    oldVaultInvitationToken = undefined;
    await click(ownerPage, 'Manage Vault members');
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Invitation needs reissue'));
    membershipLabels = await staticMembershipSemantics(ownerPage);
    safeUiTrace.push({ profile: 'owner', point: 'stale-member-dialog', labels: membershipLabels });
    assertThat(membershipLabels.includes('EDITOR · Invitation needs reissue') &&
      membershipLabels.includes('Revoke invitation') &&
      membershipLabels.includes('Settings > Invite member'),
      'stale invitation was not labeled or could not be revoked');
    await click(ownerPage, 'Close');

    setStage('Owner reissues a stale Vault invitation');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Invite member');
    await paste(ownerPage, 'Public Device Card JSON', shareCard, { profile: 'owner', pageErrors });
    await click(ownerPage, 'Verify and review');
    await waitFor(() => ownerPage.getByText('Confirm target:', { exact: false }).isVisible());
    after = apiEvents.length - 1;
    await click(ownerPage, 'Sign and create invitation');
    assertStatus(await waitEvent(apiEvents, 'owner', 'vault-invite', after), 200, 'vault_invitation_reissue');
    vaultInvitationToken = await copyClipboard(ownerPage, 'Copy token');
    assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInvitationToken), 'reissued Vault invitation token format was invalid');

    setStage('Owner opens the reissued pending invitation for revocation');
    revokedVaultInvitationToken = vaultInvitationToken;
    const pendingBeforeRevoke = readTeamInvitationSnapshot({ ownerUsername, memberUsername });
    vaultInvitationAuditIds.push(pendingBeforeRevoke.invitation_id);
    assertThat(pendingBeforeRevoke.member_state === 'invited' &&
      pendingBeforeRevoke.invitation_accepted_at === null,
    'reissued invitation was not pending before Owner revocation');
    setStage('Owner opens reissued members dialog');
    // Invitation creation leaves the owner on Settings.
    await click(ownerPage, 'Manage Vault members');
    setStage('Owner sees the reissued pending invitation');
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Invitation pending'));
    setStage('Owner selects pending invitation revocation');
    await click(ownerPage, 'Revoke invitation');
    setStage('Owner confirms pending invitation revocation dialog');
    await ownerPage.getByText('Revoke invitation?', { exact: true })
      .waitFor({ state: 'visible' });
    setStage('Owner confirms pending invitation revocation');
    after = apiEvents.length - 1;
    await click(ownerPage, 'Revoke and rotate key');
    const revokePendingInvite = await waitEvent(apiEvents, 'owner', 'vault-rotate', after);
    assertStatus(revokePendingInvite, 200, 'pending_invitation_revoke');
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Revoked'));
    const revokedInvitationState = readTeamInvitationSnapshot({ ownerUsername, memberUsername });
    assertThat(revokedInvitationState.member_state === 'revoked' &&
      revokedInvitationState.invitation_accepted_at === null &&
      revokedInvitationState.membership_version === pendingBeforeRevoke.membership_version + 1 &&
      revokedInvitationState.active_epoch === pendingBeforeRevoke.active_epoch + 1 &&
      revokedInvitationState.manifest_version === revokedInvitationState.membership_version &&
      revokedInvitationState.manifest_count === pendingBeforeRevoke.manifest_count + 1 &&
      revokedInvitationState.manifest_digest !== pendingBeforeRevoke.manifest_digest,
    'Owner confirmation did not revoke the pending ACL and append a signed membership version');
    await click(ownerPage, 'Close');
    setStage('member submits the revoked pending invitation token');
    await assertInvitationRejectedWithoutMutation({
      baseUrl,
      bearer: currentMemberBearer,
      token: revokedVaultInvitationToken,
      ownerUsername,
      memberUsername,
      expectedStatus: 409,
      expectedCode: 'INVITATION_STALE',
      label: 'revoked_pending_invitation_rejected_without_state_change',
    });
    revokedVaultInvitationToken = undefined;

    setStage('Owner re-invites the member after revoking the pending invitation');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Invite member');
    await paste(ownerPage, 'Public Device Card JSON', shareCard, { profile: 'owner', pageErrors });
    await click(ownerPage, 'Verify and review');
    await waitFor(() => ownerPage.getByText('Confirm target:', { exact: false }).isVisible());
    after = apiEvents.length - 1;
    await click(ownerPage, 'Sign and create invitation');
    assertStatus(await waitEvent(apiEvents, 'owner', 'vault-invite', after), 200, 'vault_invitation_after_revoke');
    vaultInvitationToken = await copyClipboard(ownerPage, 'Copy token');
    assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInvitationToken), 'replacement Vault invitation token format was invalid');
    vaultInvitationAuditIds.push(
      readTeamInvitationSnapshot({ ownerUsername, memberUsername }).invitation_id);

    setStage('member accepts one-time Vault invitation');
    await click(memberPage, 'Settings');
    await (await button(memberPage, 'Accept invitation')).scrollIntoViewIfNeeded();
    await click(memberPage, 'Accept invitation');
    await fill(memberPage, 'Invitation token', vaultInvitationToken);
    acceptedVaultInvitationToken = vaultInvitationToken;
    vaultInvitationToken = undefined;
    after = apiEvents.length - 1;
    await click(memberPage, 'Accept and unlock Vault');
    await waitWorkspace(memberPage);
    assertStatus(await waitEvent(apiEvents, 'member', 'vault-accept', after), 200, 'vault_invitation_accept');
    setStage('member replays the accepted one-time token against the server');
    await assertInvitationRejectedWithoutMutation({
      baseUrl,
      bearer: currentMemberBearer,
      token: acceptedVaultInvitationToken,
      ownerUsername,
      memberUsername,
      expectedStatus: 409,
      expectedCode: 'INVITATION_USED',
      label: 'accepted_vault_invitation_replay_rejected_without_state_change',
    });
    acceptedVaultInvitationToken = undefined;

    setStage('two authorized members create a shared encrypted host');
    const conflictBaseName = `Shared conflict baseline ${crypto.randomUUID()}`;
    const ownerBranchName = `Owner offline edit ${crypto.randomUUID()}`;
    const memberBranchName = `Member offline edit ${crypto.randomUUID()}`;
    const conflictMarkers = [ownerBranchName, memberBranchName];
    setStage('read shared Vault baseline snapshot');
    const beforeHostCreate = readTeamConflictSnapshot({ ownerUsername, memberUsername });
    assertThat(beforeHostCreate.membership.owner_role === 'owner' &&
      beforeHostCreate.membership.owner_state === 'active' &&
      beforeHostCreate.membership.member_role === 'editor' &&
      beforeHostCreate.membership.member_state === 'active',
    'server membership fixture did not authorize both collaboration editors');
    console.log('assert: server_confirms_active_owner_and_editor_membership=true');
    expectedSharedVaultId = beforeHostCreate.vault_id;
    setStage('Owner opens Hosts and saves the common record');
    await click(ownerPage, 'Hosts');
    await click(ownerPage, 'Add host');
    await fill(ownerPage, 'Display name', conflictBaseName);
    await fill(ownerPage, 'Hostname or IP', '198.51.100.84');
    await fill(ownerPage, 'Port', '22');
    await fill(ownerPage, 'SSH username', 'team-conflict-test');
    await click(ownerPage, 'Save encrypted host');
    setStage('Owner synchronizes common host baseline');
    await syncNow(ownerPage);
    setStage('verify shared host baseline commit');
    const afterHostCreate = readTeamConflictSnapshot({ ownerUsername, memberUsername });
    const createdRows = afterHostCreate.all_versions.filter((item) =>
      Number(item.commit_seq) > Number(beforeHostCreate.last_committed_seq) && item.operation === 'create');
    assertThat(createdRows.length === 1, 'shared conflict baseline did not create one server record');
    const conflictRecordId = createdRows[0].record_id;
    assertThat(/^[0-9a-f-]{36}$/.test(conflictRecordId), 'shared conflict baseline record id was invalid');
    const baseRevision = createdRows[0].revision_id;
    setStage('Member opens Hosts and verifies Editor write control');
    try {
      await click(memberPage, 'Hosts');
      await waitFor(async () => (await button(memberPage, 'Add host')).isEnabled(), 30000);
    } catch (_) {
      safeUiTrace.push({
        profile: 'member',
        point: 'shared-host-baseline-handoff',
        phase: 'open-hosts-or-editor-control',
        state: await safeHostHandoffState(memberPage, conflictBaseName, pageErrors),
      });
      throw new Error('Member did not reach the shared Host page with Editor write access');
    }
    setStage('Member syncs common host baseline and receives changes response');
    const beforeMemberSync = apiEvents.length - 1;
    try {
      await syncNow(memberPage);
      const memberChanges = await waitEventMethod(
        apiEvents, 'member', 'vault-changes', 'GET', beforeMemberSync, 30000);
      assertStatus(memberChanges, 200, 'member_shared_host_changes');
      assertThat(memberChanges.expected_vault_match === true,
        'Member changes request targeted a Vault other than the shared collaboration Vault');
    } catch (_) {
      safeUiTrace.push({
        profile: 'member',
        point: 'shared-host-baseline-handoff',
        phase: 'sync-or-changes-response',
        state: await safeHostHandoffState(memberPage, conflictBaseName, pageErrors),
        recent_changes_responses: safeApiTrace.filter((entry) =>
          entry.profile === 'member' && entry.route === 'vault-changes').slice(-5),
      });
      throw new Error('Member did not complete the shared Vault changes sync');
    }
    setStage('Member verifies common host baseline is visible');
    try {
      await hostCardGroup(memberPage, conflictBaseName).waitFor({ state: 'visible', timeout: 30000 });
    } catch (_) {
      safeUiTrace.push({
        profile: 'member',
        point: 'shared-host-baseline-handoff',
        phase: 'host-not-visible-after-successful-sync',
        state: await safeHostHandoffState(memberPage, conflictBaseName, pageErrors),
        recent_changes_responses: safeApiTrace.filter((entry) =>
          entry.profile === 'member' && entry.route === 'vault-changes').slice(-5),
      });
      throw new Error('Member synced the shared Vault but the common Host was not visible');
    }
    console.log('assert: both_editors_loaded_same_committed_base=true');

    setStage('both editors save concurrent changes while offline');
    await Promise.all([ownerContext.setOffline(true), memberContext.setOffline(true)]);
    await Promise.all([
      editHostDisplayName(ownerPage, conflictBaseName, ownerBranchName),
      editHostDisplayName(memberPage, conflictBaseName, memberBranchName),
    ]);
    const offlineEdits = readTeamConflictSnapshot({ ownerUsername, memberUsername, recordId: conflictRecordId });
    assertThat(offlineEdits.versions.length === 1 && offlineEdits.head.revision_id === baseRevision,
      'offline local edits changed the shared server head before either member reconnected');

    setStage('member reconnects first and commits its stale-base branch');
    captureViewerSyncPushProbe = true;
    try {
      await memberContext.setOffline(false);
      await syncNow(memberPage);
    } finally {
      captureViewerSyncPushProbe = false;
    }
    assertThat(viewerSyncPushProbe !== null,
      'Member sync did not expose a signed Vault write for the Viewer ACL probe');
    const memberWriteEvent = apiEvents.findLast((event) =>
      event.request_id === viewerSyncPushProbe.request_id);
    assertThat(memberWriteEvent?.route === 'vault-sync-push' &&
      memberWriteEvent.profile === 'member' && memberWriteEvent.method === 'POST',
    'Viewer ACL probe did not capture the Member sync-push response');
    assertStatus(memberWriteEvent, 200, 'member_signed_write_probe_source');
    assertThat(memberWriteEvent.expected_vault_match === true,
      'Viewer ACL probe source write targeted a different Vault');
    const memberWritePayload = JSON.parse(viewerSyncPushProbe.body);
    const memberWriteEnvelope = memberWritePayload.operations[0];
    assertThat(memberWritePayload.vault_id === expectedSharedVaultId &&
      typeof memberWritePayload.device_id === 'string' &&
      memberWriteEnvelope?.header?.vault_id === expectedSharedVaultId &&
      memberWriteEnvelope?.header?.record_id === conflictRecordId &&
      memberWriteEnvelope?.header?.operation === 'update' &&
      typeof memberWriteEnvelope.signature === 'string' &&
      typeof memberWriteEnvelope.ciphertext === 'string',
    'Viewer ACL probe source was not a signed update for the shared Host record');
    const memberCommit = readTeamConflictSnapshot({ ownerUsername, memberUsername, recordId: conflictRecordId });
    assertThat(memberCommit.versions.length === 2 &&
      memberCommit.versions[1].operation === 'update' &&
      memberCommit.versions[1].base_revision_id === baseRevision &&
      memberCommit.head.revision_id === memberCommit.versions[1].revision_id,
    'first concurrent member edit did not become the new server head from the common base');
    assertThat(memberCommit.receipts.length === 2 && memberCommit.events.length === 2,
      'first concurrent edit did not produce its operation receipt and change event');

    setStage('Owner reconnects and syncs stale local branch');
    await ownerContext.setOffline(false);
    const priorOwnerApiShapes = new Set(safeApiTrace);
    try {
      await syncNow(ownerPage, {
        timeoutMs: 45000,
        completeWhen: async () => {
          const newOwnerShapes = safeApiTrace.filter((entry) => !priorOwnerApiShapes.has(entry));
          const sawCreatedConflictEvent = newOwnerShapes.some((entry) =>
            entry.profile === 'owner' && entry.route === 'vault-conflict-changes' &&
            entry.method === 'GET' && entry.status === 200 &&
            Number(entry.response_shape?.event_types?.created || 0) > 0);
          const statusCounts = await safeSyncStatusLabelCounts(ownerPage);
          const settledStatus = statusCounts.Syncing === 0 &&
            (statusCounts.Idle > 0 || statusCounts.Pending > 0 ||
              statusCounts['N pending'] > 0 || statusCounts['Retry queued'] > 0);
          return sawCreatedConflictEvent && settledStatus;
        },
      });
    } catch (_) {
      safeUiTrace.push({
        profile: 'owner',
        point: 'owner-conflict-sync-completion',
        status_label_counts: await safeSyncStatusLabelCounts(ownerPage),
        api_shapes: safeApiTrace.filter((entry) =>
          !priorOwnerApiShapes.has(entry) && entry.profile === 'owner').slice(-12),
      });
      throw new Error('Owner sync did not observe a created conflict event and settled status');
    }
    setStage('Owner opens Settings');
    await click(ownerPage, 'Settings');
    setStage('Owner opens conflict center');
    await click(ownerPage, /^Sync & conflicts(?:\s+\d+)?$/);
    setStage('Owner waits for explicit conflict review control');
    try {
      await waitFor(async () =>
        await ownerPage.getByRole('button', { name: 'Keep this device version', exact: true }).count() === 1,
      45000);
    } catch (_) {
      safeUiTrace.push({
        profile: 'owner',
        point: 'concurrent-conflict-review',
        phase: 'wait-review-control',
        state: await safeConflictReviewState(ownerPage, pageErrors),
      });
      throw new Error('Owner did not see the explicit concurrent-conflict review control');
    }
    setStage('Owner reads and validates server conflict snapshot');
    const openConflict = readTeamConflictSnapshot({ ownerUsername, memberUsername, recordId: conflictRecordId });
    safeUiTrace.push({
      profile: 'owner',
      point: 'concurrent-conflict-review',
      phase: 'server-conflict-snapshot',
      conflict_count: openConflict.conflicts.length,
      unresolved_count: openConflict.conflicts.filter((item) => item.resolved_revision_id === null).length,
      base_matches_shared_revision: openConflict.conflicts[0]?.base_revision_id === baseRevision,
    });
    assertThat(openConflict.conflicts.length === 1 &&
      openConflict.conflicts[0].base_revision_id === baseRevision &&
      openConflict.conflicts[0].resolved_revision_id === null,
    'stale owner edit did not create one unresolved server conflict branch');
    setStage('Owner clicks Keep this device version');
    const keepOwnerBranch = await button(ownerPage, 'Keep this device version');
    await keepOwnerBranch.scrollIntoViewIfNeeded();
    await keepOwnerBranch.click();
    setStage('Owner confirms Create resolution');
    const beforeResolutionRequest = apiEvents.length - 1;
    await click(ownerPage, 'Create resolution');
    setStage('Owner waits for server conflict-resolution response');
    const resolutionResponse = await waitEventMethod(
      apiEvents,
      'owner',
      'vault-conflict-resolve',
      'POST',
      beforeResolutionRequest,
      45000,
    );
    assertStatus(resolutionResponse, 200, 'owner_conflict_resolution');
    assertThat(resolutionResponse.expected_vault_match === true,
      'Owner conflict resolution request targeted a Vault other than the shared collaboration Vault');
    setStage('Owner waits for resolution UI confirmation');
    await waitFor(async () =>
      await ownerPage.getByRole('button', { name: 'Keep this device version', exact: true }).count() === 0,
    45000);
    setStage('Owner reads and validates resolved server snapshot');
    const resolved = readTeamConflictSnapshot({ ownerUsername, memberUsername, recordId: conflictRecordId });
    safeUiTrace.push({
      profile: 'owner',
      point: 'concurrent-conflict-review',
      phase: 'resolved-server-snapshot',
      version_count: resolved.versions.length,
      receipt_count: resolved.receipts.length,
      event_count: resolved.events.length,
      conflict_count: resolved.conflicts.length,
      head_present: Boolean(resolved.head),
      resolved_revision_present: Boolean(resolved.conflicts[0]?.resolved_revision_id),
      resolution_sequence_present: resolved.conflicts[0]?.resolution_seq !== null &&
        resolved.conflicts[0]?.resolution_seq !== undefined,
    });
    assertThat(resolved.versions.length === 3 && resolved.receipts.length === 3 && resolved.events.length === 3,
      'explicit conflict resolution did not produce exactly one accepted revision, receipt, and event');
    assertThat(resolved.versions[0].revision_id === baseRevision &&
      resolved.versions[1].base_revision_id === baseRevision &&
      resolved.versions[2].base_revision_id === resolved.versions[1].revision_id &&
      resolved.head.revision_id === resolved.versions[2].revision_id &&
      resolved.head.deleted === 0 &&
      resolved.conflicts.length === 1 &&
      resolved.conflicts[0].resolved_revision_id === resolved.head.revision_id &&
      resolved.conflicts[0].resolution_seq !== null,
    'resolved server versions, CAS bases, conflict event, or active record head were inconsistent');
    assertThat(resolved.versions[0].author_user_id === resolved.owner_user_id &&
      resolved.versions[1].author_user_id === resolved.member_user_id &&
      resolved.versions[2].author_user_id === resolved.owner_user_id,
    'server version author devices did not match the expected two member accounts');
    assertThat(resolved.receipts.every((receipt, index) =>
      receipt.revision_id === resolved.versions[index].revision_id &&
      receipt.commit_seq === resolved.versions[index].commit_seq) &&
      resolved.events.every((event, index) =>
        event.revision_id === resolved.versions[index].revision_id &&
        event.commit_seq === resolved.versions[index].commit_seq &&
        event.event_type === resolved.versions[index].operation),
    'accepted revisions did not have matching operation receipts and change events');
    assertThat(/^[0-9a-f-]{36}$/.test(resolved.conflicts[0].branch_revision_id) &&
      resolved.conflicts[0].branch_revision_id !== resolved.head.revision_id &&
      resolved.conflicts[0].branch_revision_id !== resolved.versions[1].revision_id &&
      resolved.conflicts[0].branch_device_id !== resolved.versions[1].device_id &&
      resolved.conflicts[0].branch_operation === 'update' &&
      resolved.conflicts[0].conflict_seq < resolved.conflicts[0].resolution_seq &&
      resolved.last_conflict_seq === resolved.conflicts[0].resolution_seq,
    'server did not preserve a distinct owner conflict branch followed by its resolution event');
    console.log('assert: owner_explicitly_kept_its_conflicting_device_version=true');
    console.log('assert: server_versions_receipts_events_conflict_resolution_and_head_converged=true');

    setStage('member pulls the explicit resolution and both profiles converge');
    const memberChangesBeforeResolutionPull = new Set(safeApiTrace.filter((entry) =>
      entry.profile === 'member' && entry.route === 'vault-changes'));
    try {
      await click(ownerPage, 'Hosts');
      await click(memberPage, 'Hosts');
      await syncNow(memberPage);
      await Promise.all([
        hostCardGroup(ownerPage, ownerBranchName).waitFor({ state: 'visible', timeout: 30000 }),
        hostCardGroup(memberPage, ownerBranchName).waitFor({ state: 'visible', timeout: 30000 }),
      ]);
    } catch (_) {
      safeUiTrace.push({
        profile: 'member',
        point: 'explicit-resolution-convergence',
        phase: 'timeout',
        owner_state: await safeHostHandoffState(ownerPage, ownerBranchName, pageErrors),
        member_state: await safeHostHandoffState(memberPage, ownerBranchName, pageErrors),
        member_change_responses: safeApiTrace.filter((entry) =>
          entry.profile === 'member' && entry.route === 'vault-changes').map((entry) => ({
          after_resolution_started: !memberChangesBeforeResolutionPull.has(entry),
          status: entry.status,
          expected_vault_match: entry.expected_vault_match,
          event_types: entry.response_shape?.event_types || {},
          event_count: entry.response_shape?.event_count ?? null,
        })).slice(-8),
      });
      throw new Error('Member did not pull and render the server-accepted resolution');
    }
    assertThat(await hostCardGroup(ownerPage, ownerBranchName).count() === 1 &&
      await hostCardGroup(memberPage, ownerBranchName).count() === 1 &&
      await hostCardGroup(ownerPage, memberBranchName).count() === 0 &&
      await hostCardGroup(memberPage, memberBranchName).count() === 0,
    'two authorized profiles did not converge to the explicitly selected encrypted record version');
    assertCiphertextOnlyMarkers(conflictMarkers);
    console.log('assert: both_profiles_converged_and_server_storage_remained_ciphertext_only=true');

    setStage('independent Owner device requests enrollment');
    ownerSecondaryContext = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    const ownerSecondaryPage = await ownerSecondaryContext.newPage();
    trackApi(ownerSecondaryPage, 'owner-secondary', apiEvents, pageErrors);
    await ownerSecondaryPage.goto(baseUrl, {
      waitUntil: 'domcontentloaded',
      timeout: 30000,
    });
    await enableSemantics(ownerSecondaryPage);
    await fill(ownerSecondaryPage, 'Server URL', baseUrl,
      { profile: 'owner-secondary', pageErrors });
    setStage('independent Owner device opens secure connection flow');
    await click(ownerSecondaryPage, 'Connect securely');
    await field(ownerSecondaryPage, 'Email or username');
    setStage('independent Owner device opens enrollment request form');
    await click(ownerSecondaryPage, 'Add this device');
    await fill(ownerSecondaryPage, 'Account email', ownerUsername,
      { profile: 'owner-secondary', pageErrors });
    await fill(ownerSecondaryPage, 'Device name', 'Team owner second browser',
      { profile: 'owner-secondary', pageErrors });
    setStage('independent Owner device creates and copies signed request');
    await click(ownerSecondaryPage, 'Generate request');
    const enrollmentJson = await copyClipboard(ownerSecondaryPage, 'Copy');
    let requestedDeviceId;
    try {
      const request = JSON.parse(enrollmentJson);
      requestedDeviceId = request.device?.device_id;
      assertThat(request.format === 'atermius-device-enrollment-v1' &&
        typeof requestedDeviceId === 'string' && requestedDeviceId.length > 0,
      'independent Owner profile did not create a signed device enrollment');
    } catch (_) {
      throw new Error('independent Owner device enrollment was not valid JSON');
    }
    await click(ownerSecondaryPage, 'Close');

    setStage('Owner approves and imports the independent device');
    await click(ownerPage, 'Devices');
    await click(ownerPage, 'Approve enrollment');
    await paste(ownerPage, 'Enrollment JSON', enrollmentJson,
      { profile: 'owner', pageErrors });
    await click(ownerPage, 'Review keys');
    await click(ownerPage, 'Approve & seal keys');
    const approvalJson = await copyClipboard(ownerPage, 'Copy');
    let approvedDeviceId;
    try {
      const approval = JSON.parse(approvalJson);
      approvedDeviceId = approval.device?.device_id;
      assertThat(approval.format === 'atermius-device-approval-v1' &&
        approvedDeviceId === requestedDeviceId,
      'Owner device approval did not match the independent profile request');
    } catch (_) {
      throw new Error('Owner device approval was not valid JSON');
    }
    await click(ownerPage, 'Done');
    await click(ownerSecondaryPage, 'Import approval');
    await paste(ownerSecondaryPage, 'Paste approval JSON', approvalJson,
      { profile: 'owner-secondary', pageErrors });
    await click(ownerSecondaryPage, 'Import device keys');
    await fill(ownerSecondaryPage, 'Email or username', ownerUsername,
      { profile: 'owner-secondary', pageErrors });
    await fill(ownerSecondaryPage, 'Master password', ownerPassword,
      { profile: 'owner-secondary', pageErrors });
    after = apiEvents.length - 1;
    await click(ownerSecondaryPage, 'Sign in and unlock');
    await waitWorkspace(ownerSecondaryPage);
    const secondOwnerHeartbeat = await waitEvent(
      apiEvents, 'owner-secondary', 'vault-presence', after);
    assertStatus(secondOwnerHeartbeat, 200, 'second_owner_presence_heartbeat');
    assertThat(secondOwnerHeartbeat.method === 'POST',
      'independent Owner profile did not renew its own presence lease');

    setStage('Owner refreshes Members and sees both same-account devices');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Manage Vault members');
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Active'));
    after = apiEvents.length - 1;
    await click(ownerPage, 'Refresh members and online devices');
    const ownerPresenceRead = await waitEventMethod(
      apiEvents, 'owner', 'vault-presence', 'GET', after);
    assertStatus(ownerPresenceRead, 200, 'owner_members_presence_refresh');
    await waitFor(() => safeApiTrace.some((entry) =>
      entry.profile === 'owner' && entry.route === 'vault-presence' &&
      entry.response_shape?.keys?.join(',') === 'devices,ttl_seconds'));
    await waitFor(async () =>
      (await staticMembershipSemantics(ownerPage)).includes('2 devices online'));
    const membersRosterTrace = safeApiTrace.findLast((entry) =>
      entry.profile === 'owner' && entry.route === 'vault-members' &&
      entry.response_shape?.member_count === 2);
    const ownerLabels = await staticMembershipSemantics(ownerPage);
    safeUiTrace.push({
      profile: 'owner',
      point: 'same-account-membership-row-uniqueness',
      owner_active_visible: ownerLabels.includes('OWNER · Active'),
      editor_active_visible: ownerLabels.includes('EDITOR · Active'),
      two_devices_visible: ownerLabels.includes('2 devices online'),
    });
    assertThat(membersRosterTrace?.response_shape?.unique_user_count === 2 &&
      membersRosterTrace.response_shape.duplicate_user_count === 0 &&
      membersRosterTrace.response_shape.role_states?.['owner:active'] === 1 &&
      membersRosterTrace.response_shape.role_states?.['editor:active'] === 1 &&
      ownerLabels.includes('OWNER · Active') &&
      ownerLabels.includes('EDITOR · Active') &&
      ownerLabels.includes('2 devices online'),
      'multiple active sessions split one account into duplicate Members rows');
    const presenceTrace = safeApiTrace.findLast((entry) =>
      entry.profile === 'owner' && entry.route === 'vault-presence');
    assertThat(
      presenceTrace?.response_shape?.keys?.join(',') === 'devices,ttl_seconds' &&
        presenceTrace?.response_shape?.device_keys?.join(',') ===
          'device_id,last_seen_at,user_id',
      'Web presence response included fields outside the minimal device DTO',
    );
    safeUiTrace.push({
      profile: 'owner',
      point: 'same-account-presence',
      labels: ownerLabels,
    });
    await click(ownerPage, 'Close');

    setStage('Owner opens Settings for role change');
    await click(ownerPage, 'Settings');
    setStage('Owner opens member list after invitation acceptance');
    await click(ownerPage, 'Manage Vault members');
    safeUiTrace.push({ profile: 'owner', point: 'active-member-dialog', labels: await staticMembershipSemantics(ownerPage) });
    setStage('Owner waits for active Editor row');
    await waitFor(async () => (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Active'));
    setStage('Owner opens Editor role-change confirmation');
    await click(ownerPage, 'Make viewer');
    setStage('Owner confirms Viewer role change');
    roleRotationApiTrace = [];
    safeControllerTrace = [];
    captureRoleRotationApiTrace = true;
    const roleChangeAfter = apiEvents.length - 1;
    await click(ownerPage, 'Change to viewer');
    setStage('Owner waits for Viewer role API response');
    const roleChange = await waitEvent(apiEvents, 'owner', 'vault-rotate', roleChangeAfter);
    assertStatus(roleChange, 200, 'role_change_to_viewer');
    setStage('Owner reads the server roster after Viewer role change');
    let viewerRosterEvent;
    try {
      viewerRosterEvent = await waitEvent(
        apiEvents, 'owner', 'vault-members', roleChange.sequence, 10000);
    } catch (_) {
      safeUiTrace.push({
        profile: 'owner',
        point: 'viewer-role-roster-timeout',
        ui: await safeMembershipRotationUiState(ownerPage),
        route_trace: roleRotationApiTrace,
        controller_trace: safeControllerTrace.slice(-50),
        recent_control_routes: safeApiTrace
          .filter((entry) => entry.profile === 'owner' &&
            ['device-directory', 'vault-device-directory', 'vault-membership',
              'vault-members', 'vault-list', 'vault-rotate', 'recovery-contexts',
              'recovery-key-envelopes'].includes(entry.route))
          .slice(-14),
        pending_api_requests: [...pendingApiRequests.values()]
          .map((entry) => ({
            profile: entry.profile,
            route: entry.route,
            method: entry.method,
            age_ms: Math.max(0, Date.now() - entry.request_started_at),
          }))
          .slice(-20),
      });
      throw new Error('Owner did not request an updated member roster after role rotation');
    }
    assertStatus(viewerRosterEvent, 200, 'viewer_role_roster_refresh');
    const viewerRosterBody = await viewerRosterEvent.payloadPromise;
    const viewerRosterRoles = {};
    for (const item of Array.isArray(viewerRosterBody?.members)
      ? viewerRosterBody.members : []) {
      const key = `${String(item?.role || 'unknown')}:${String(item?.state || 'unknown')}`;
      viewerRosterRoles[key] = (viewerRosterRoles[key] || 0) + 1;
    }
    safeUiTrace.push({
      profile: 'owner',
      point: 'viewer-role-server-roster',
      role_states: viewerRosterRoles,
    });
    assertThat(viewerRosterRoles['owner:active'] === 1 &&
      viewerRosterRoles['viewer:active'] === 1 &&
      viewerRosterRoles['editor:active'] === undefined,
    'server member roster did not reflect the committed Viewer role');
    setStage('Owner verifies active Viewer row');
    safeUiTrace.push({
      profile: 'owner',
      point: 'viewer-role-ui-roster',
      labels: await staticMembershipSemantics(ownerPage),
    });
    await waitFor(async () => (await staticMembershipSemantics(ownerPage)).includes('VIEWER · Active'));
    captureRoleRotationApiTrace = false;
    await click(ownerPage, 'Close');

    setStage('member receives Viewer access state');
    await click(memberPage, 'Settings');
    await waitFor(async () => {
      const body = await memberPage.locator('body').innerText();
      return /viewer\s*·\s*key epoch/i.test(body) || /Vault role\s*viewer/i.test(body);
    }, 45000);
    await click(memberPage, 'View Vault members');
    await waitFor(async () => {
      const labels = await staticMembershipSemantics(memberPage);
      return labels.includes('VIEWER · Active') && labels.includes('2 devices online');
    });
    const viewerLabels = await staticMembershipSemantics(memberPage);
    assertThat(!viewerLabels.includes('Make viewer') &&
      !viewerLabels.includes('Make editor') &&
      !viewerLabels.includes('Revoke access') &&
      !viewerLabels.includes('Transfer ownership'),
    'read-only Viewer Members UI exposed management actions');
    safeUiTrace.push({
      profile: 'member',
      point: 'viewer-presence-read-only',
      labels: viewerLabels,
    });
    await click(memberPage, 'Close');
    setStage('Viewer opens account audit scope');
    let viewerAuditAfter = apiEvents.length - 1;
    await click(memberPage, 'Audit log');
    const viewerAccountAuditEvent = await waitEvent(
      apiEvents, 'member', 'audit', viewerAuditAfter);
    assertStatus(viewerAccountAuditEvent, 200, 'viewer_account_audit');
    const viewerAccountAuditPage = await viewerAccountAuditEvent.payloadPromise;
    assertThat(Array.isArray(viewerAccountAuditPage?.events) &&
      viewerAccountAuditPage.events.some((event) => event.scope === 'account'),
    'Viewer account audit scope omitted the member’s own account events');
    setStage('Viewer selects Vault audit scope');
    viewerAuditAfter = apiEvents.length - 1;
    await memberPage.getByText('当前 Vault', { exact: true }).click();
    const viewerVaultAuditEvent = await waitEvent(
      apiEvents, 'member', 'audit', viewerAuditAfter);
    assertStatus(viewerVaultAuditEvent, 200, 'viewer_vault_audit');
    const viewerVaultAuditPage = await viewerVaultAuditEvent.payloadPromise;
    assertThat(Array.isArray(viewerVaultAuditPage?.events),
      'Viewer Vault audit response was not an event page');
    const viewerSharedVaultAuditEvents = viewerVaultAuditPage.events.filter(
      (event) => event.scope === 'vault' && event.vault_id === expectedSharedVaultId);
    const viewerOtherVaultAuditEventCount = viewerVaultAuditPage.events.filter(
      (event) => event.scope === 'vault' && event.vault_id !== expectedSharedVaultId).length;
    const viewerPersonalVaultCreatedAuditCount = viewerVaultAuditPage.events.filter(
      (event) => event.scope === 'vault' && event.action === 'vault.created' &&
        event.vault_id !== expectedSharedVaultId).length;
    await waitFor(async () => await memberPage.getByText(
      'Vault 范围审计仅对当前 Vault 的 Owner 和 Editor 开放；当前权限不会返回 Vault 事件。',
      { exact: true },
    ).count() === 1);
    const sharedInvitationAuditLabelCount = await memberPage.getByText(
      '成员邀请已接受', { exact: false },
    ).count();
    const personalVaultCreatedLabelCount = await memberPage.getByText(
      'Vault 已创建', { exact: false },
    ).count();
    assertThat(viewerSharedVaultAuditEvents.length === 0 &&
      viewerOtherVaultAuditEventCount > 0 &&
      viewerPersonalVaultCreatedAuditCount === 1 &&
      sharedInvitationAuditLabelCount === 0 &&
      personalVaultCreatedLabelCount === 0,
      'Viewer received audit events for the shared Vault');
    safeUiTrace.push({
      profile: 'member',
      point: 'viewer-audit-vault-scope',
      account_event_count: viewerVaultAuditPage.events.filter(
        (event) => event.scope === 'account').length,
      shared_vault_event_count: viewerSharedVaultAuditEvents.length,
      other_owned_vault_event_count: viewerOtherVaultAuditEventCount,
      personal_vault_created_event_count: viewerPersonalVaultCreatedAuditCount,
      shared_invitation_label_count: sharedInvitationAuditLabelCount,
      personal_vault_created_label_count: personalVaultCreatedLabelCount,
      read_only_notice_visible: true,
    });
    console.log('assert: viewer_account_audit_allowed_vault_audit_filtered=true');
    await click(memberPage, 'Hosts');
    const addHostViewer = await button(memberPage, 'Add host');
    await waitFor(() => addHostViewer.isDisabled());
    console.log('assert: viewer_cannot_add_host=true');

    setStage('Viewer replays a valid signed record write against the server ACL');
    const beforeViewerWriteProbe = readTeamConflictSnapshot({
      ownerUsername, memberUsername, recordId: conflictRecordId,
    });
    assertThat(typeof currentMemberBearer === 'string' &&
      currentMemberBearer.startsWith('Bearer '),
    'Member browser did not retain a current authenticated session for the Viewer ACL probe');
    const viewerWriteResponse = await fetch(viewerSyncPushProbe.url, {
      method: 'POST',
      headers: {
        authorization: currentMemberBearer,
        'content-type': 'application/json',
      },
      body: viewerSyncPushProbe.body,
      signal: AbortSignal.timeout(10000),
    });
    let viewerWriteErrorCode = null;
    try {
      viewerWriteErrorCode = (await viewerWriteResponse.json())?.error?.code ?? null;
    } catch (_) {
      // The status and fixed expected code assertion below will fail closed.
    }
    assertThat(viewerWriteResponse.status === 403 &&
      viewerWriteErrorCode === 'VAULT_READ_ONLY',
    'server did not reject the Viewer sync write with the Vault read-only ACL');
    const afterViewerWriteProbe = readTeamConflictSnapshot({
      ownerUsername, memberUsername, recordId: conflictRecordId,
    });
    assertThat(JSON.stringify(afterViewerWriteProbe) === JSON.stringify(beforeViewerWriteProbe),
      'rejected Viewer sync write changed server record, receipt, event, conflict, or commit state');
    viewerSyncPushProbe = null;
    console.log('assert: viewer_server_sync_push_denied_without_commit=true');

    setStage('Owner restores Editor access');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Manage Vault members');
    await click(ownerPage, 'Make editor');
    await click(ownerPage, 'Change to editor');
    const promote = await waitEvent(apiEvents, 'owner', 'vault-rotate', roleChange.sequence);
    assertStatus(promote, 200, 'role_change_to_editor');
    await click(ownerPage, 'Close');
    await click(memberPage, 'Settings');
    await waitFor(async () => {
      const body = await memberPage.locator('body').innerText();
      return /editor\s*·\s*key epoch/i.test(body) || /Vault role\s*editor/i.test(body);
    }, 45000);
    await click(memberPage, 'Hosts');
    await waitFor(async () => (await button(memberPage, 'Add host')).isEnabled());
    console.log('assert: editor_can_add_host=true');

    setStage('Owner opens member list before revocation');
    await click(ownerPage, 'Settings');
    await click(ownerPage, 'Manage Vault members');
    setStage('Owner opens member revocation confirmation');
    await click(ownerPage, 'Revoke access');
    setStage('Owner confirms member revocation');
    const revokedMemberSessionBearer = currentMemberBearer;
    assertThat(typeof revokedMemberSessionBearer === 'string' &&
      revokedMemberSessionBearer.startsWith('Bearer '),
    'Member browser did not retain its pre-revocation session for the ACL probe');
    await click(ownerPage, 'Revoke and rotate key');
    setStage('Owner waits for member revocation API response');
    const revoke = await waitEvent(apiEvents, 'owner', 'vault-rotate', promote.sequence);
    assertStatus(revoke, 200, 'member_revocation');
    setStage('Owner verifies revoked member row');
    await waitFor(async () => (await staticMembershipSemantics(ownerPage)).includes('EDITOR · Revoked'));
    await click(ownerPage, 'Close');

    setStage('existing member bearer cannot read the revoked Vault');
    const revokedMemberRoster = await fetch(
      `${baseUrl}/api/v1/vaults/${expectedSharedVaultId}/members`,
      {
        method: 'GET',
        headers: { authorization: revokedMemberSessionBearer },
        signal: AbortSignal.timeout(10000),
      },
    );
    const revokedMemberVaultList = await fetch(`${baseUrl}/api/v1/vaults`, {
      method: 'GET',
      headers: { authorization: revokedMemberSessionBearer },
      signal: AbortSignal.timeout(10000),
    });
    let accessibleVaults = [];
    try {
      accessibleVaults = (await revokedMemberVaultList.json())?.vaults ?? [];
    } catch (_) {
      // Status and absence assertions below fail closed.
    }
    assertThat(revokedMemberRoster.status === 404 &&
      revokedMemberVaultList.status === 200 &&
      Array.isArray(accessibleVaults) &&
      !accessibleVaults.some((vault) => vault?.vault_id === expectedSharedVaultId),
    'pre-revocation bearer retained access to the revoked Vault');
    currentMemberBearer = null;
    console.log('assert: existing_member_bearer_cannot_read_revoked_vault=true');

    setStage('member active UI drops the revoked Vault without re-login');
    await waitFor(async () =>
      !(await memberPage.locator('body').innerText()).includes('Team lifecycle Vault'),
    20000);
    console.log('assert: existing_member_session_hides_revoked_vault=true');

    setStage('revoked member reauthenticates against current server membership');
    await click(memberPage, 'Settings');
    await click(memberPage, 'Lock and sign out');
    await field(memberPage, 'Email or username');
    await fill(memberPage, 'Email or username', memberUsername);
    await fill(memberPage, 'Master password', memberPassword);
    after = apiEvents.length - 1;
    await click(memberPage, 'Sign in and unlock');
    await waitWorkspace(memberPage);
    assertStatus(await waitEvent(apiEvents, 'member', 'login', after), 200, 'member_relogin_after_revocation');
    await click(memberPage, 'Settings');
    await waitFor(async () => !(await memberPage.locator('body').innerText()).includes('Team lifecycle Vault'));
    console.log('assert: revoked_vault_absent_after_fresh_login=true');

    setStage('Owner opens audit log for completed Team lifecycle');
    let auditAfter = apiEvents.length - 1;
    await click(ownerPage, 'Audit log');
    const accountAuditEvent = await waitEvent(apiEvents, 'owner', 'audit', auditAfter);
    assertStatus(accountAuditEvent, 200, 'owner_account_audit');
    auditAfter = apiEvents.length - 1;
    await ownerPage.getByText('当前 Vault', { exact: true }).click();
    const vaultAuditEvent = await waitEvent(apiEvents, 'owner', 'audit', auditAfter);
    assertStatus(vaultAuditEvent, 200, 'owner_vault_audit');
    const auditPage = await vaultAuditEvent.payloadPromise;
    const auditDtoKeys = [
      'action', 'actor_device_id', 'actor_user_id', 'event_id', 'occurred_at',
      'resource_id', 'resource_type', 'result', 'scope', 'source', 'vault_id',
    ];
    assertThat(Object.keys(auditPage || {}).sort().join(',') === 'events,has_more,next_cursor' &&
      Array.isArray(auditPage?.events),
    'Vault audit page DTO did not match the expected response shape');
    const vaultAuditEvents = auditPage.events.filter((event) =>
      event?.scope === 'vault' && event?.vault_id === expectedSharedVaultId);
    const actionEvents = (action) => vaultAuditEvents.filter((event) => event.action === action);
    const invitationCreatedEvents = actionEvents('vault.invitation_created');
    const invitationAcceptedEvents = actionEvents('vault.invitation_accepted');
    const memberRevokedEvents = actionEvents('vault.member_revoked');
    const memberRoleChangedEvents = actionEvents('vault.member_role_changed');
    const keyRotatedEvents = actionEvents('vault.key_rotated');
    assertThat(vaultAuditEvents.every((event) =>
      Object.keys(event || {}).sort().join(',') === auditDtoKeys.join(',') &&
      typeof event.event_id === 'string' && /^(0|[1-9][0-9]*)$/.test(event.event_id) &&
      typeof event.occurred_at === 'string' && Number.isFinite(Date.parse(event.occurred_at))),
    'Vault audit event DTO did not match the exact schema');
    const allAuditEventIds = vaultAuditEvents.map((event) => BigInt(event.event_id));
    assertThat(allAuditEventIds.every((value, index) =>
      index === 0 || value > allAuditEventIds[index - 1]),
    'Vault audit events were not returned in increasing event order');
    assertThat(invitationCreatedEvents.length === 3 &&
      invitationAcceptedEvents.length === 1 &&
      memberRevokedEvents.length === 2 &&
      memberRoleChangedEvents.length === 2 &&
      keyRotatedEvents.length === 4,
    'Vault audit feed did not contain the expected invitation and membership lifecycle events');
    const actorMatches = (items, userId, deviceId) => items.every((event) =>
      event.actor_user_id === userId && event.actor_device_id === deviceId &&
      event.result === 'success' && event.source === 'api');
    assertThat(actorMatches(invitationCreatedEvents, ownerAccountId, ownerDeviceId) &&
      actorMatches(memberRevokedEvents, ownerAccountId, ownerDeviceId) &&
      actorMatches(memberRoleChangedEvents, ownerAccountId, ownerDeviceId) &&
      actorMatches(keyRotatedEvents, ownerAccountId, ownerDeviceId) &&
      actorMatches(invitationAcceptedEvents, memberAccountId, memberDeviceId),
    'Vault audit lifecycle actor, device, result, or source did not match the actual writer');
    const createdInvitationIds = invitationCreatedEvents.map((event) => event.resource_id).sort();
    assertThat(invitationCreatedEvents.every((event) => event.resource_type === 'invitation' &&
      /^[0-9a-f-]{36}$/i.test(event.resource_id || '')) &&
      createdInvitationIds.join(',') === [...vaultInvitationAuditIds].sort().join(',') &&
      invitationAcceptedEvents[0].resource_type === 'invitation' &&
      invitationAcceptedEvents[0].resource_id === vaultInvitationAuditIds.at(-1),
    'Vault audit invitation events did not bind the created and accepted invitation IDs');
    assertThat(memberRevokedEvents.every((event) =>
      event.resource_type === 'membership' && event.resource_id === memberAccountId) &&
      memberRoleChangedEvents.every((event) =>
        event.resource_type === 'membership' && event.resource_id === memberAccountId) &&
      keyRotatedEvents.every((event) =>
        event.resource_type === 'vault' && event.resource_id === expectedSharedVaultId),
    'Vault audit member or key-rotation resource references were incorrect');
    const auditLabels = [
      ['已创建成员邀请', 3],
      ['成员邀请已接受', 1],
      ['成员访问已撤销', 2],
      ['成员权限已更改', 2],
      ['Vault 密钥已轮换', 4],
    ];
    for (const [label, minimumCount] of auditLabels) {
      await waitFor(async () =>
        await ownerPage.getByText(label, { exact: false }).count() >= minimumCount);
      assertThat(await ownerPage.getByText(label, { exact: false }).count() >= minimumCount,
        'Vault audit UI did not render an invitation or membership lifecycle label');
    }
    console.log('assert: team_invitation_membership_and_rotation_audit_lifecycle=true');

    // The recipient's prior offline database may still contain ciphertext. A
    // fresh login obtains only personal Vault membership from the server.
    assertThat(revoke.status === 200, 'server did not commit member revocation');
    assertThat(pageErrors.count === 0, 'Flutter reported a page runtime error');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async () => {
  console.error(`stage: failed (${stage})`);
  if (safeFailureReason) console.error(`assertion: ${safeFailureReason}`);
  if (safeUiTrace.length > 0) {
    console.error(`ui: ${JSON.stringify(safeUiTrace)}`);
  }
  if (safeApiTrace.length > 0) {
    console.error(`api: ${JSON.stringify(safeApiTrace.slice(-12))}`);
  }
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
