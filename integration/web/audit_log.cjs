/*
 * WEB-AUDIT-01: verify the authenticated audit API and the account / active
 * Vault views in the current Flutter Web bundle, including cursor pagination,
 * malformed-cursor rejection, and recovery after server-generation rotation.
 * The SQLite fixture is created only inside this run's private temp directory;
 * synthetic rows are keyed from this disposable Owner's real audit scopes and
 * are removed with the database during strict cleanup.
 * Output is limited to fixed stages, API route/status pairs, and booleans/counts.
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
const CARGO_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(ROOT, process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = path.join(CARGO_TARGET_DIR, 'debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const SYNTHETIC_AUDIT_ROWS = 101;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let browserContext;
let siblingContext;
let bootstrapToken;
let username;
let password;
let siblingEnrollmentJson;
let siblingApprovalJson;
let cleanupPromise;
let cleanupFailed = false;
const safeApiStatuses = [];
const safeFillDiagnostics = [];

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
      // Continue polling while the loopback service starts.
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

async function restartAfterGenerationRecovery(serverEnv, baseUrl) {
  await stopServerGroup(serverProcess);
  serverProcess = undefined;
  const recovery = spawnSync(
    SERVER_BINARY,
    ['recover-generation', '--server-stopped'],
    {
      cwd: ROOT,
      env: serverEnv,
      timeout: 30000,
      stdio: 'ignore',
    },
  );
  assertThat(!recovery.error && recovery.status === 0,
    'isolated offline generation recovery failed');
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env: serverEnv,
    detached: true,
    stdio: 'ignore',
  });
  await waitForServer(baseUrl, serverProcess);
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    username = undefined;
    password = undefined;
    siblingEnrollmentJson = undefined;
    siblingApprovalJson = undefined;
    try {
      if (siblingContext) await siblingContext.close().catch(() => {});
      if (browserContext) await browserContext.close().catch(() => {});
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
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  let locator;
  try {
    locator = await field(page, label);
    safeFillDiagnostics.push({ stage, phase: 'field_visible', visible: true });
  } catch (error) {
    safeFillDiagnostics.push({
      stage,
      phase: 'field_visible',
      visible: false,
      error_type: String(error?.name || 'unknown').slice(0, 40),
    });
    throw error;
  }
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 20 });
    const beforeBlur = await waitForStableFieldValue(locator, value);
    safeFillDiagnostics.push({
      stage,
      attempt,
      phase: 'before_blur',
      stable_reads: beforeBlur.stableReads,
      matched: beforeBlur.matched,
    });
    if (!beforeBlur.matched) continue;

    await locator.press('Tab');
    await page.waitForTimeout(100);
    const afterBlur = await waitForStableFieldValue(locator, value);
    safeFillDiagnostics.push({
      stage,
      attempt,
      phase: 'after_blur',
      stable_reads: afterBlur.stableReads,
      matched: afterBlur.matched,
    });
    if (afterBlur.matched) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitForStableFieldValue(locator, expected, timeoutMs = 1200) {
  const deadline = Date.now() + timeoutMs;
  let stableReads = 0;
  while (Date.now() < deadline) {
    if (await locator.inputValue() === expected) {
      stableReads += 1;
      if (stableReads >= 3) return { matched: true, stableReads };
    } else {
      stableReads = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { matched: false, stableReads };
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
}

async function waitForText(page, text, timeoutMs = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible',
    timeout: timeoutMs,
  });
}

async function paste(page, label, value) {
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  let pasted = false;
  try {
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(200);
    pasted = await locator.inputValue().catch(() => '') === value;
  } catch (error) {
    safeFillDiagnostics.push({
      stage,
      phase: 'clipboard_paste_action',
      error_type: String(error?.name || 'unknown').slice(0, 40),
    });
  }
  if (!pasted) {
    try {
      // Approval JSON can be several thousand characters. The ordinary form
      // helper types slowly for debounce-sensitive fields; direct fill is
      // deterministic here and avoids timing out while replaying JSON keys.
      await locator.fill(value);
      const beforeBlur = await waitForStableFieldValue(locator, value);
      safeFillDiagnostics.push({
        stage,
        phase: 'approval_json_fill',
        stable_reads: beforeBlur.stableReads,
        matched: beforeBlur.matched,
      });
      if (beforeBlur.matched) {
        await locator.press('Tab');
        await page.waitForTimeout(100);
      }
    } catch (error) {
      safeFillDiagnostics.push({
        stage,
        phase: 'approval_json_fill',
        error_type: String(error?.name || 'unknown').slice(0, 40),
      });
    }
  }
  assertThat(await locator.inputValue().catch(() => '') === value,
    'clipboard or fallback paste did not populate the enrollment field');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function requestSiblingDeviceEnrollment(page, deviceName) {
  await field(page, 'Email or username');
  await click(page, 'Add this device');
  await waitForText(page, 'Request this device');
  await fill(page, 'Account email', username);
  await fill(page, 'Device name', deviceName);
  await click(page, 'Generate request');
  await field(page, 'Copy this enrollment JSON');
  await click(page, 'Copy');
  const enrollmentJson = await readClipboard(page);
  let format;
  try { format = JSON.parse(enrollmentJson).format; } catch (_) {}
  assertThat(format === 'atermius-device-enrollment-v1',
    'sibling browser did not create a valid device enrollment request');
  await click(page, 'Close');
  return enrollmentJson;
}

async function approveSiblingDeviceEnrollment(page, enrollmentJson) {
  await click(page, 'Devices');
  await click(page, 'Approve enrollment');
  await paste(page, 'Enrollment JSON', enrollmentJson);
  await click(page, 'Review keys');
  await click(page, 'Approve & seal keys');
  await button(page, 'Copy');
  await click(page, 'Copy');
  const approvalJson = await readClipboard(page);
  assertThat(approvalJson.includes('atermius-device-approval-v1'),
    'owner browser did not create a valid sibling device approval');
  await click(page, 'Done');
  await click(page, 'Hosts');
  return approvalJson;
}

async function importSiblingApprovalAndSignIn(page, approvalJson) {
  setStage('sibling approval: open import form');
  await click(page, 'Import approval');
  setStage('sibling approval: paste approval JSON');
  await paste(page, 'Paste approval JSON', approvalJson);
  setStage('sibling approval: import device keys');
  await click(page, 'Import device keys');
  setStage('sibling approval: enter account email');
  await fill(page, 'Email or username', username);
  setStage('sibling approval: enter master password');
  await fill(page, 'Master password', password);
  setStage('sibling approval: sign in');
  await click(page, 'Sign in and unlock');
  setStage('sibling approval: wait for workspace');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 30000 });
}

async function visibleFlutterSemanticsCount(page, text) {
  return page.locator('flt-semantics').evaluateAll((nodes, expected) =>
    nodes.filter((node) => {
      const label = `${node.getAttribute('aria-label') || ''} ${node.textContent || ''}`;
      const bounds = node.getBoundingClientRect();
      return label.includes(expected) && bounds.width > 0 && bounds.height > 0 &&
        getComputedStyle(node).visibility !== 'hidden';
    }).length,
  text);
}

function apiRoute(request) {
  let pathname;
  try {
    pathname = new URL(request.url()).pathname;
  } catch (_) {
    return null;
  }
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/audit') return 'audit';
  if (pathname === '/api/v1/vaults') return 'vaults';
  return null;
}

function addSyntheticAuditRows(databasePath, syntheticReplayFamilyId, syntheticConflictId) {
  // This fixture runs only against the just-created private SQLite database.
  // It discovers the scope from this run's committed registration event rather
  // than inventing or reusing any account identifier or production data.
  const fixture = String.raw`
import sqlite3, sys, time
connection = sqlite3.connect(sys.argv[1], timeout=10)
try:
    source = connection.execute(
        "SELECT scope_id, actor_user_id, actor_device_id FROM audit_events "
        "WHERE scope_type='account' AND action='account.created' "
        "ORDER BY event_id LIMIT 1"
    ).fetchone()
    vault = connection.execute(
        "SELECT scope_id, actor_user_id, actor_device_id FROM audit_events "
        "WHERE scope_type='vault' AND action='vault.created' "
        "ORDER BY event_id LIMIT 1"
    ).fetchone()
    if source is None or not source[0] or not source[1] or not source[2]:
        raise SystemExit(21)
    if vault is None or not vault[0] or not vault[1] or not vault[2]:
        raise SystemExit(24)
    timestamp = int(time.time())
    row_count = int(sys.argv[2])
    if row_count < 2:
        raise SystemExit(22)
    rows = [
        ('vault', vault[0], vault[1], vault[2], 'vault.conflict_resolved',
         'conflict', sys.argv[4], 'success', timestamp, 'api')
    ]
    rows.append(
        ('account', source[0], source[1], source[2], 'auth.mfa_totp_enabled',
         'account', source[1], 'success', timestamp, 'api')
    )
    rows.extend(
        ('account', source[0], source[1], source[2], 'account.created',
         'account', None, 'success', timestamp, 'api')
        for _ in range(row_count - 3)
    )
    rows.append(('account', source[0], None, None, 'auth.refresh_reuse_detected',
                 'session_family', sys.argv[3], 'failure', timestamp, 'api'))
    inserted = connection.executemany(
        "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id," 
        "action,resource_type,resource_id,result,occurred_at,source) VALUES(?,?,?,?,?,?,?,?,?,?)",
        rows
    )
    if inserted.rowcount != row_count:
        raise SystemExit(23)
    connection.commit()
finally:
    connection.close()
`;
  const result = spawnSync('python3', [
    '-c', fixture, databasePath, String(SYNTHETIC_AUDIT_ROWS),
    syntheticReplayFamilyId, syntheticConflictId,
  ], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 15000,
  });
  assertThat(!result.error && result.status === 0, 'isolated audit fixture creation failed');
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

async function auditPayload(event) {
  const payload = await event.payloadPromise;
  assertThat(
    payload && Array.isArray(payload.events) && typeof payload.has_more === 'boolean',
    'audit API returned an invalid page',
  );
  return payload;
}

function reportStatus(assertion, status) {
  console.log(`assert: ${assertion}_http_status=${status}`);
}

function reportBoolean(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
}

function reportCount(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-audit-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
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

    username = `web-audit-${crypto.randomUUID().slice(0, 8)}@example.test`;
    password = `Audit-${crypto.randomBytes(32).toString('base64url')}`;
    const apiEvents = [];
    const eventByRequest = new WeakMap();
    let pageErrorCount = 0;

    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);

    setStage('isolated instance bootstrap');
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
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap credential is unavailable');
    bootstrapResult.stdout = '';

    setStage('isolated Chromium context');
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    browserContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    await browserContext.grantPermissions(
      ['clipboard-read', 'clipboard-write'], { origin: baseUrl },
    );
    const page = await browserContext.newPage();
    page.on('pageerror', () => { pageErrorCount += 1; });
    page.on('request', (request) => {
      const route = apiRoute(request);
      if (!route) return;
      const authorization = request.headers().authorization || '';
      let auditHasCursor = false;
      if (route === 'audit') {
        try {
          auditHasCursor = new URL(request.url()).searchParams.has('cursor');
        } catch (_) {
          // Keep only the safe presence bit; never retain or print the cursor.
        }
      }
      eventByRequest.set(request, {
        route,
        method: request.method(),
        hasBearer: authorization.startsWith('Bearer ') && authorization.length > 7,
        auditHasCursor,
      });
    });
    page.on('response', (response) => {
      const metadata = eventByRequest.get(response.request());
      if (!metadata) return;
      const event = {
        ...metadata,
        status: response.status(),
        sequence: apiEvents.length,
        payloadPromise: metadata.route === 'audit' || metadata.route === 'vaults'
          ? response.json().catch(() => null)
          : Promise.resolve(null),
      };
      apiEvents.push(event);
      safeApiStatuses.push({ route: metadata.route, status: response.status() });
      if (safeApiStatuses.length > 12) safeApiStatuses.shift();
    });

    setStage('load Flutter client');
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    setStage('wait for Flutter assets and semantics placeholder');
    await waitFor(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    setStage('wait for sodium initialization');
    await page.evaluate(async () => { await window.sodium.ready; });
    setStage('activate Flutter semantics');
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    setStage('wait for accessible Flutter controls');
    await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
    setStage('configure server endpoint');
    await fill(page, 'Server URL', baseUrl);
    setStage('connect server endpoint');
    await click(page, 'Connect securely');
    setStage('wait for owner registration form');
    await field(page, 'Owner email');

    setStage('fill owner account email');
    await fill(page, 'Owner email', username);
    setStage('fill owner account password');
    await fill(page, 'Master password · 12+ characters', password);
    setStage('fill owner account password confirmation');
    await fill(page, 'Confirm master password', password);
    setStage('fill owner registration bootstrap token');
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    setStage('fill owner device name');
    await fill(page, 'Device name', 'Audit acceptance browser');
    setStage('fill first Vault name');
    await fill(page, 'First Vault', 'Audit acceptance vault');
    const registerStart = apiEvents.length;
    setStage('submit owner account registration');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    setStage('wait for registered workspace');
    await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 30000 });
    setStage('wait for owner registration response');
    const registerEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'register' && event.sequence >= registerStart,
    );
    assertThat(registerEvent.status >= 200 && registerEvent.status < 300, 'owner registration was rejected');
    reportStatus('registration', registerEvent.status);
    const vaultListEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'vaults' && event.sequence >= registerStart,
    );
    const vaultList = await vaultListEvent.payloadPromise;
    assertThat(vaultListEvent.status === 200 && Array.isArray(vaultList?.vaults) &&
      vaultList.vaults.length === 1,
    'new owner did not expose one active Vault descriptor');
    const activeVaultId = vaultList.vaults[0].vault_id;

    setStage('isolated synthetic audit pagination fixture');
    const syntheticReplayFamilyId = crypto.randomUUID();
    const syntheticConflictId = crypto.randomUUID();
    addSyntheticAuditRows(databasePath, syntheticReplayFamilyId, syntheticConflictId);
    reportCount('synthetic_audit_rows', SYNTHETIC_AUDIT_ROWS);

    setStage('open account audit scope');
    const firstPageStart = apiEvents.length;
    await click(page, 'Audit log');
    const firstPageEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= firstPageStart,
    );
    const firstPage = await auditPayload(firstPageEvent);
    assertThat(firstPageEvent.status === 200 && firstPageEvent.hasBearer, 'audit API did not accept the authenticated session');
    assertThat(firstPage.events.length === 100 && firstPage.has_more, 'audit first page did not contain the expected continuation');
    const pageOneScopes = new Set(firstPage.events.map((item) => item.scope));
    assertThat(pageOneScopes.has('account') && pageOneScopes.has('vault'), 'first audit page omitted an expected scope');
    const conflictEvents = firstPage.events.filter(
      (item) => item.action === 'vault.conflict_resolved',
    );
    assertThat(conflictEvents.length === 1 &&
        conflictEvents[0].scope === 'vault' &&
        conflictEvents[0].vault_id === activeVaultId &&
        conflictEvents[0].resource_type === 'conflict' &&
        conflictEvents[0].resource_id === syntheticConflictId &&
        conflictEvents[0].result === 'success' &&
        conflictEvents[0].source === 'api',
      'first audit page omitted the isolated Vault conflict-resolution event');
    const mfaEnabledEvents = firstPage.events.filter(
      (item) => item.action === 'auth.mfa_totp_enabled',
    );
    assertThat(mfaEnabledEvents.length === 1 &&
        mfaEnabledEvents[0].scope === 'account' &&
        mfaEnabledEvents[0].resource_type === 'account',
      'first audit page omitted the account-scoped MFA event');
    reportStatus('authenticated_audit_page_one', firstPageEvent.status);
    reportCount('audit_page_one_events', firstPage.events.length);
    reportBoolean('audit_page_one_has_more', firstPage.has_more);
    await waitForText(page, '账户创建');
    await waitForText(page, '已启用多重身份验证');
    reportBoolean('mfa_totp_enabled_audit_label_visible', true);
    assertThat(await page.getByText('Vault 冲突已解决', { exact: true }).count() === 0,
      'account audit scope rendered the Vault conflict-resolution event');
    reportBoolean('account_scope_hides_vault_conflict_event', true);
    reportBoolean('account_scope_event_visible', true);

    setStage('next audit cursor page');
    const secondPageStart = apiEvents.length;
    await click(page, '下一页');
    const secondPageEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= secondPageStart,
    );
    const secondPage = await auditPayload(secondPageEvent);
    const secondPageAccountCount = secondPage.events.filter((item) => item.scope === 'account').length;
    const secondPageVaultCount = secondPage.events.filter((item) => item.scope === 'vault').length;
    const secondPageCreatedCount = secondPage.events.filter((item) => item.action === 'account.created').length;
    const replayEvents = secondPage.events.filter((item) => item.action === 'auth.refresh_reuse_detected');
    reportCount('audit_page_two_events', secondPage.events.length);
    reportBoolean('audit_page_two_has_more', secondPage.has_more);
    reportCount('audit_page_two_account_scope_events', secondPageAccountCount);
    reportCount('audit_page_two_vault_scope_events', secondPageVaultCount);
    assertThat(secondPageEvent.status === 200 && secondPageEvent.hasBearer, 'audit cursor request was not authenticated');
    assertThat(secondPage.events.length === 3 && !secondPage.has_more,
      'audit cursor did not return all remaining rows');
    assertThat(secondPageAccountCount === secondPage.events.length && secondPageVaultCount === 0,
      'second audit page has an unexpected scope');
    assertThat(secondPageCreatedCount === 2 && replayEvents.length === 1,
      'second audit page did not contain the expected synthetic action mix');
    const replayEvent = replayEvents[0];
    assertThat(replayEvent.scope === 'account' &&
        replayEvent.actor_user_id === null &&
        replayEvent.actor_device_id === null &&
        replayEvent.result === 'failure' &&
        replayEvent.resource_type === 'session_family' &&
        replayEvent.resource_id === syntheticReplayFamilyId &&
        replayEvent.source === 'api',
      'refresh-reuse audit event did not preserve its sanitized account-level fields');
    const replayEventJson = JSON.stringify(replayEvent);
    const tokenLikeFields = Object.keys(replayEvent).filter((key) => /token|secret|credential/i.test(key));
    assertThat(tokenLikeFields.length === 0 &&
        !/refresh[_ -]?token|bearer\s+[a-z0-9._~-]+/i.test(replayEventJson),
      'refresh-reuse audit event exposed request-token material');
    reportBoolean('refresh_reuse_audit_fields_sanitized', true);
    reportBoolean('refresh_reuse_audit_request_token_absent', true);
    reportStatus('authenticated_audit_page_two', secondPageEvent.status);
    setStage('render second audit page rows');
    const accountActionLabels = page.getByText('账户创建', { exact: false });
    await waitFor(() => accountActionLabels.count().then((count) => count === secondPageCreatedCount));
    reportCount('audit_page_two_visible_account_rows', await accountActionLabels.count());
    await waitForText(page, '检测到刷新凭据重放，相关会话已撤销');
    reportBoolean('refresh_reuse_audit_label_visible', true);
    setStage('check second-page navigation state');
    const nextPageButton = await button(page, '下一页');
    const previousPageButton = await button(page, '上一页');
    const nextPageDisabled = await nextPageButton.isDisabled();
    const previousPageEnabled = await previousPageButton.isEnabled();
    reportBoolean('audit_next_page_disabled', nextPageDisabled);
    reportBoolean('audit_previous_page_enabled', previousPageEnabled);
    assertThat(nextPageDisabled && previousPageEnabled, 'audit navigation did not reflect the final page');

    setStage('previous audit cursor page');
    const previousPageStart = apiEvents.length;
    await click(page, '上一页');
    setStage('wait for previous audit cursor response');
    const previousPageEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= previousPageStart,
    );
    const previousPage = await auditPayload(previousPageEvent);
    reportStatus('authenticated_previous_audit_page', previousPageEvent.status);
    reportCount('previous_audit_page_events', previousPage.events.length);
    reportBoolean('previous_audit_page_has_more', previousPage.has_more);
    assertThat(previousPageEvent.status === 200 && previousPage.events.length === 100 && previousPage.has_more,
      'audit previous cursor did not restore the first page');
    setStage('restore first-page navigation and rows');
    await waitFor(async () => await nextPageButton.isEnabled() && await previousPageButton.isDisabled());
    const firstPageVisibleAccountRows = await accountActionLabels.count();
    reportCount('audit_page_one_visible_account_rows_after_previous', firstPageVisibleAccountRows);
    const firstPageNextEnabled = await nextPageButton.isEnabled();
    const firstPagePreviousDisabled = await previousPageButton.isDisabled();
    reportBoolean('audit_page_one_next_enabled', firstPageNextEnabled);
    reportBoolean('audit_page_one_previous_disabled', firstPagePreviousDisabled);
    assertThat(firstPageVisibleAccountRows > 0 && firstPageNextEnabled && firstPagePreviousDisabled,
      'audit navigation did not restore the first-page state');
    reportBoolean('audit_previous_page_restored', true);

    setStage('open active Vault audit scope');
    const vaultScopeStart = apiEvents.length;
    await page.getByText('当前 Vault', { exact: true }).click();
    setStage('wait for active Vault scope notice');
    await waitForText(page, '当前显示');
    setStage('wait for active Vault audit response');
    const vaultScopeEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= vaultScopeStart,
    );
    const vaultPage = await auditPayload(vaultScopeEvent);
    assertThat(vaultScopeEvent.status === 200 && vaultScopeEvent.hasBearer, 'active Vault audit request was not authenticated');
    assertThat(vaultPage.events.some((item) => item.scope === 'vault'), 'active Vault audit page omitted Vault events');
    const visibleConflictEvents = vaultPage.events.filter(
      (item) => item.action === 'vault.conflict_resolved' &&
        item.resource_id === syntheticConflictId,
    );
    reportCount('active_vault_conflict_resolution_api_events', visibleConflictEvents.length);
    const vaultCreatedEvents = vaultPage.events.filter((item) => item.action === 'vault.created');
    reportBoolean('conflict_scope_matches_created_vault', visibleConflictEvents.length === 1 &&
      vaultCreatedEvents.some((item) => item.vault_id === visibleConflictEvents[0].vault_id));
    reportBoolean('conflict_event_matches_active_vault', visibleConflictEvents.length === 1 &&
      visibleConflictEvents[0].vault_id === activeVaultId);
    assertThat(visibleConflictEvents.length === 1,
      'active Vault audit page omitted the synthetic conflict-resolution event');
    const auditRefreshButton = await button(page, '刷新');
    await waitFor(async () => await auditRefreshButton.isEnabled());
    setStage('wait for active Vault created label');
    await waitFor(async () => await visibleFlutterSemanticsCount(page, 'Vault 已创建') > 0);
    setStage('wait for active Vault conflict-resolution label');
    const conflictLabelCount = await visibleFlutterSemanticsCount(page, 'Vault 冲突已解决');
    reportCount('active_vault_conflict_resolution_visible_semantics', conflictLabelCount);
    assertThat(conflictLabelCount > 0,
      'active Vault page did not render the conflict-resolution action label');
    reportStatus('authenticated_active_vault_audit', vaultScopeEvent.status);
    reportBoolean('active_vault_scope_event_visible', true);
    reportBoolean('active_vault_conflict_resolution_label_visible', true);

    setStage('capture valid cursor before generation recovery');
    const generationFirstPageStart = apiEvents.length;
    await page.getByText('账户', { exact: true }).click();
    const generationFirstPageEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' &&
        event.sequence >= generationFirstPageStart &&
        !event.auditHasCursor,
    );
    const generationFirstPage = await auditPayload(generationFirstPageEvent);
    assertThat(generationFirstPageEvent.status === 200 &&
        generationFirstPageEvent.hasBearer &&
        generationFirstPage.events.length === 100 &&
        generationFirstPage.has_more,
      'could not capture a valid cursor before generation recovery');
    reportStatus('pre_recovery_audit_page',
      generationFirstPageEvent.status);

    setStage('rotate disposable server generation offline');
    await restartAfterGenerationRecovery(serverEnv, baseUrl);
    reportBoolean('offline_generation_recovery_completed', true);

    setStage('submit cursor from prior server generation');
    const expiredCursorStart = apiEvents.length;
    await click(page, '下一页');
    const expiredCursorEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' &&
        event.sequence >= expiredCursorStart &&
        event.auditHasCursor,
    );
    const expiredCursorPayload = await expiredCursorEvent.payloadPromise;
    const expiredCursorCode = expiredCursorPayload?.error?.code;
    reportStatus('generation_expired_cursor',
      expiredCursorEvent.status);
    reportBoolean('generation_expired_cursor_rejected',
      expiredCursorEvent.status === 410 &&
        expiredCursorCode === 'AUDIT_CURSOR_EXPIRED');
    assertThat(expiredCursorEvent.hasBearer &&
        expiredCursorEvent.status === 410 &&
        expiredCursorCode === 'AUDIT_CURSOR_EXPIRED',
      'server did not reject cursor from the prior generation');

    setStage('recover generation-expired cursor in Web UI');
    const generationErrorHeading = page.getByRole('heading', {
      name: '无法加载审计记录',
      exact: true,
    });
    await generationErrorHeading.waitFor({
      state: 'visible',
      timeout: 20000,
    });
    const generationRetryButton = await button(page, '从第一页重试');
    reportBoolean('generation_expired_cursor_retry_visible', true);

    setStage('retry audit after generation recovery');
    const generationRetryStart = apiEvents.length;
    await generationRetryButton.click();
    const generationRetryEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' &&
        event.sequence >= generationRetryStart &&
        !event.auditHasCursor,
    );
    const generationRetryPage = await auditPayload(generationRetryEvent);
    assertThat(generationRetryEvent.status === 200 &&
        generationRetryEvent.hasBearer &&
        generationRetryPage.events.length === 100 &&
        generationRetryPage.has_more,
      'audit did not recover from the expired cursor on the first page');
    reportStatus('generation_recovery_first_page',
      generationRetryEvent.status);
    reportCount('generation_recovery_first_page_events',
      generationRetryPage.events.length);
    await waitForText(page, '账户创建');
    await waitFor(async () =>
      await page.getByText('无法加载审计记录', { exact: true }).count() === 0);
    const generationNextPageButton = await button(page, '下一页');
    const generationPreviousPageButton = await button(page, '上一页');
    assertThat(await generationNextPageButton.isEnabled() &&
        await generationPreviousPageButton.isDisabled(),
      'audit navigation did not recover after server-generation rotation');
    reportBoolean('generation_recovery_navigation_restored', true);

    setStage('arm one-time malformed cursor response');
    let cursorCorruptionArmed = true;
    let cursorCorruptionCount = 0;
    let cursorCorruptionApplied = false;
    const corruptFirstPageCursor = async (route) => {
      let requestUrl;
      try {
        requestUrl = new URL(route.request().url());
      } catch (_) {
        await route.continue();
        return;
      }
      if (!cursorCorruptionArmed ||
          route.request().method() !== 'GET' ||
          requestUrl.pathname !== '/api/v1/audit' ||
          requestUrl.searchParams.has('cursor')) {
        await route.continue();
        return;
      }

      cursorCorruptionArmed = false;
      try {
        const upstream = await route.fetch();
        const payload = await upstream.json();
        if (upstream.status() !== 200 ||
            !payload ||
            !Array.isArray(payload.events) ||
            payload.has_more !== true ||
            typeof payload.next_cursor !== 'string' ||
            payload.next_cursor.length === 0) {
          cursorCorruptionApplied = false;
          await route.fulfill({ response: upstream });
          return;
        }
        const headers = { ...upstream.headers() };
        delete headers['content-length'];
        delete headers['content-encoding'];
        delete headers['transfer-encoding'];
        await route.fulfill({
          status: upstream.status(),
          headers,
          body: JSON.stringify({ ...payload, next_cursor: 'broken-test-audit-cursor' }),
        });
        cursorCorruptionCount += 1;
        cursorCorruptionApplied = true;
      } catch (_) {
        cursorCorruptionApplied = false;
        try {
          await route.continue();
        } catch (_) {
          // The route may already have been fulfilled; later assertions expose failure safely.
        }
      }
    };
    await page.route('**/api/v1/audit*', corruptFirstPageCursor);

    setStage('load account first page with one-time cursor mutation');
    const corruptedFirstPageStart = apiEvents.length;
    await click(page, '刷新');
    const corruptedFirstPageEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' &&
        event.sequence >= corruptedFirstPageStart &&
        !event.auditHasCursor,
    );
    const corruptedFirstPage = await auditPayload(corruptedFirstPageEvent);
    assertThat(cursorCorruptionApplied && cursorCorruptionCount === 1,
      'one-time first-page cursor mutation was not applied');
    assertThat(corruptedFirstPageEvent.status === 200 &&
        corruptedFirstPageEvent.hasBearer &&
        corruptedFirstPage.events.length === 100 &&
        corruptedFirstPage.has_more,
      'mutated first-page response did not preserve its successful page shape');
    reportStatus('mutated_account_audit_page', corruptedFirstPageEvent.status);
    reportCount('mutated_account_audit_page_events', corruptedFirstPage.events.length);
    reportBoolean('one_time_cursor_mutation_applied', true);

    setStage('submit malformed cursor to real server');
    const rejectedCursorStart = apiEvents.length;
    await click(page, '下一页');
    const rejectedCursorEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' &&
        event.sequence >= rejectedCursorStart &&
        event.auditHasCursor,
    );
    const rejectedCursorPayload = await rejectedCursorEvent.payloadPromise;
    const rejectedCursorCode = rejectedCursorPayload?.error?.code;
    reportStatus('malformed_cursor_server_response', rejectedCursorEvent.status);
    reportBoolean('malformed_cursor_server_rejected',
      rejectedCursorEvent.status === 400 && rejectedCursorCode === 'INVALID_AUDIT_CURSOR');
    assertThat(rejectedCursorEvent.hasBearer &&
        rejectedCursorEvent.status === 400 &&
        rejectedCursorCode === 'INVALID_AUDIT_CURSOR',
      'real server did not reject the malformed audit cursor');

    setStage('wait for audit error retry action');
    await page.mouse.wheel(0, -10000);
    const auditErrorHeading = page.getByRole('heading', {
      name: '无法加载审计记录',
      exact: true,
    });
    await auditErrorHeading.waitFor({
      state: 'visible',
      timeout: 20000,
    });
    const retryButton = await button(page, '从第一页重试');
    reportBoolean('audit_loading_error_retry_visible', true);
    const auditErrorHeadingCount = await auditErrorHeading.count();
    reportCount('audit_error_title_heading_matches', auditErrorHeadingCount);
    assertThat(auditErrorHeadingCount === 1,
      'audit loading error did not expose one accessible heading');
    reportBoolean('audit_loading_error_visible', true);
    await page.unroute('**/api/v1/audit*', corruptFirstPageCursor);

    setStage('retry audit from the first page');
    const retryStart = apiEvents.length;
    await retryButton.click();
    const retryEvent = await waitForEvent(
      apiEvents,
      (event) => event.route === 'audit' && event.sequence >= retryStart,
    );
    const retryPage = await auditPayload(retryEvent);
    assertThat(retryEvent.status === 200 &&
        retryEvent.hasBearer &&
        !retryEvent.auditHasCursor &&
        retryPage.events.length === 100 &&
        retryPage.has_more,
      'first-page audit retry did not restore a successful page');
    reportStatus('audit_first_page_retry', retryEvent.status);
    reportCount('audit_first_page_retry_events', retryPage.events.length);

    setStage('verify audit UI recovery');
    await waitForText(page, '账户创建');
    await waitFor(async () =>
      await page.getByText('无法加载审计记录', { exact: true }).count() === 0);
    const recoveredNextButton = await button(page, '下一页');
    const recoveredPreviousButton = await button(page, '上一页');
    const recoveredNextEnabled = await recoveredNextButton.isEnabled();
    const recoveredPreviousDisabled = await recoveredPreviousButton.isDisabled();
    reportBoolean('audit_error_cleared_after_retry', true);
    reportBoolean('audit_first_page_navigation_restored',
      recoveredNextEnabled && recoveredPreviousDisabled);
    assertThat(recoveredNextEnabled && recoveredPreviousDisabled,
      'audit UI did not return to the first-page navigation state');

    setStage('start independent sibling Web profile');
    siblingContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    });
    await siblingContext.grantPermissions(
      ['clipboard-read', 'clipboard-write'], { origin: baseUrl },
    );
    const siblingPage = await siblingContext.newPage();
    let siblingPageErrorCount = 0;
    const siblingApiEvents = [];
    const siblingEventByRequest = new WeakMap();
    siblingPage.on('pageerror', () => { siblingPageErrorCount += 1; });
    siblingPage.on('request', (request) => {
      const route = apiRoute(request);
      if (!route) return;
      const authorization = request.headers().authorization || '';
      let auditHasCursor = false;
      if (route === 'audit') {
        try {
          auditHasCursor = new URL(request.url()).searchParams.has('cursor');
        } catch (_) {
          // Retain only whether a cursor was present.
        }
      }
      siblingEventByRequest.set(request, {
        route,
        method: request.method(),
        hasBearer: authorization.startsWith('Bearer ') && authorization.length > 7,
        auditHasCursor,
      });
    });
    siblingPage.on('response', (response) => {
      const metadata = siblingEventByRequest.get(response.request());
      if (!metadata) return;
      const event = {
        ...metadata,
        status: response.status(),
        sequence: siblingApiEvents.length,
        payloadPromise: metadata.route === 'audit' || metadata.route === 'vaults'
          ? response.json().catch(() => null)
          : Promise.resolve(null),
      };
      siblingApiEvents.push(event);
      safeApiStatuses.push({ route: `sibling_${metadata.route}`, status: response.status() });
      if (safeApiStatuses.length > 12) safeApiStatuses.shift();
    });

    setStage('load sibling Flutter client');
    await siblingPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await waitFor(() => siblingPage.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    await siblingPage.evaluate(async () => { await window.sodium.ready; });
    await siblingPage.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await waitFor(() => siblingPage.evaluate(() =>
      document.querySelectorAll('flt-semantics').length > 0), 15000);
    await fill(siblingPage, 'Server URL', baseUrl);
    await click(siblingPage, 'Connect securely');
    await field(siblingPage, 'Email or username');

    setStage('request sibling device enrollment');
    siblingEnrollmentJson = await requestSiblingDeviceEnrollment(
      siblingPage, 'Audit acceptance sibling browser',
    );
    let enrollmentDeviceId;
    try {
      enrollmentDeviceId = JSON.parse(siblingEnrollmentJson)?.device?.device_id;
    } catch (_) {}
    assertThat(typeof enrollmentDeviceId === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(enrollmentDeviceId),
    'sibling enrollment did not contain a valid device identifier');

    setStage('approve sibling enrollment in owner profile');
    siblingApprovalJson = await approveSiblingDeviceEnrollment(page, siblingEnrollmentJson);
    siblingEnrollmentJson = undefined;

    setStage('import sibling approval and sign in');
    const siblingLoginStart = siblingApiEvents.length;
    await importSiblingApprovalAndSignIn(siblingPage, siblingApprovalJson);
    siblingApprovalJson = undefined;
    const siblingVaultListEvent = await waitForEvent(
      siblingApiEvents,
      (event) => event.route === 'vaults' && event.sequence >= siblingLoginStart,
    );
    const siblingVaultList = await siblingVaultListEvent.payloadPromise;
    const siblingActiveVault = siblingVaultList?.vaults?.find(
      (item) => item.vault_id === activeVaultId,
    );
    assertThat(siblingVaultListEvent.status === 200 && siblingActiveVault &&
      siblingActiveVault.key_envelopes?.some(
        (item) => item.recipient_device_id === enrollmentDeviceId,
      ),
    'approved sibling profile did not receive the active Vault key envelope');
    reportStatus('sibling_vault_list', siblingVaultListEvent.status);
    reportBoolean('sibling_received_active_vault_key_envelope', true);

    setStage('open sibling audit log');
    const siblingAccountAuditStart = siblingApiEvents.length;
    await click(siblingPage, 'Audit log');
    const siblingAccountAuditEvent = await waitForEvent(
      siblingApiEvents,
      (event) => event.route === 'audit' && event.sequence >= siblingAccountAuditStart,
    );
    const siblingAccountAuditPage = await auditPayload(siblingAccountAuditEvent);
    assertThat(siblingAccountAuditEvent.status === 200 && siblingAccountAuditEvent.hasBearer,
      'approved sibling profile could not load authenticated audit events');
    reportStatus('sibling_account_audit', siblingAccountAuditEvent.status);

    setStage('open sibling active Vault audit scope');
    await waitFor(() => siblingPage.getByText('当前 Vault', { exact: true }).count()
      .then((count) => count === 1));
    const siblingVaultAuditStart = siblingApiEvents.length;
    await siblingPage.getByText('当前 Vault', { exact: true }).click();
    const siblingVaultAuditEvent = await waitForEvent(
      siblingApiEvents,
      (event) => event.route === 'audit' && event.sequence >= siblingVaultAuditStart,
    );
    const siblingVaultAuditPage = await auditPayload(siblingVaultAuditEvent);
    const siblingConflictEvents = siblingVaultAuditPage.events.filter(
      (item) => item.action === 'vault.conflict_resolved' &&
        item.resource_id === syntheticConflictId,
    );
    assertThat(siblingVaultAuditEvent.status === 200 && siblingVaultAuditEvent.hasBearer &&
      siblingVaultAuditPage.events.some((item) => item.scope === 'vault') &&
      siblingConflictEvents.length === 1 &&
      siblingConflictEvents[0].scope === 'vault' &&
      siblingConflictEvents[0].vault_id === activeVaultId &&
      siblingConflictEvents[0].actor_user_id === visibleConflictEvents[0].actor_user_id &&
      siblingConflictEvents[0].actor_device_id === visibleConflictEvents[0].actor_device_id,
    'approved sibling profile did not receive the same Vault conflict audit event');
    await waitFor(() => visibleFlutterSemanticsCount(
      siblingPage, 'Vault 冲突已解决',
    ).then((count) => count > 0));
    const siblingConflictLabelCount = await visibleFlutterSemanticsCount(
      siblingPage, 'Vault 冲突已解决',
    );
    reportStatus('sibling_active_vault_audit', siblingVaultAuditEvent.status);
    reportCount('sibling_conflict_resolution_events', siblingConflictEvents.length);
    reportCount('sibling_conflict_resolution_visible_semantics', siblingConflictLabelCount);
    reportBoolean('sibling_same_vault_conflict_event_visible', true);
    assertThat(siblingPageErrorCount === 0,
      'sibling Flutter profile reported a page runtime error');

    assertThat(pageErrorCount === 0, 'Flutter reported a page runtime error');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async () => {
  console.error(`stage: failed (${stage}); safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  if (safeFillDiagnostics.length > 0) {
    console.error(`fill: ${JSON.stringify(safeFillDiagnostics.slice(-12))}`);
  }
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
