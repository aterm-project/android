/*
 * WEB-SYNC-CRASH-01: exercise encrypted record outbox recovery across Chromium
 * termination, including server-committed lost acknowledgements and local faults.
 *
 * The server, SQLite database, persistent Chromium profile, bootstrap token,
 * user credentials and Host fixture are private to this run. Diagnostics only
 * contain stage names, opaque IDs, envelope hashes, status codes and counts.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { MAX_SQLITE_FILE_BYTES, reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');
const { buildIdbWriteFailureWorkerPrelude } = require('./idb_write_failure_worker.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SIMULATE_SECURE_STORE_LOSS = process.argv.includes('--simulate-secure-store-loss');
const UNCOMMITTED_CREDENTIAL_BEFORE_CRASH = process.argv.includes(
  '--uncommitted-credential-before-crash');
const UNCOMMITTED_GROUP_BEFORE_CRASH = process.argv.includes(
  '--uncommitted-group-before-crash');
const UNCOMMITTED_SNIPPET_BEFORE_CRASH = process.argv.includes(
  '--uncommitted-snippet-before-crash');
const UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH = process.argv.includes(
  '--uncommitted-host-update-before-crash');
const UNCOMMITTED_BEFORE_CRASH = process.argv.includes('--uncommitted-before-crash') ||
  UNCOMMITTED_CREDENTIAL_BEFORE_CRASH || UNCOMMITTED_GROUP_BEFORE_CRASH ||
  UNCOMMITTED_SNIPPET_BEFORE_CRASH || UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH;
const IDB_WRITE_FAILURE_RETRY = process.argv.includes('--idb-write-failure-retry');
const INBOUND_CHECKPOINT_WRITE_FAILURE = process.argv.includes(
  '--inbound-checkpoint-write-failure');
const INBOUND_OUTBOX_CHECKPOINT_RACE = process.argv.includes(
  '--inbound-outbox-checkpoint-race');
const INBOUND_CHANGES_CRASH = process.argv.includes('--inbound-changes-crash') ||
  INBOUND_CHECKPOINT_WRITE_FAILURE || INBOUND_OUTBOX_CHECKPOINT_RACE;
const REDACTION_INDEXEDDB_ORDERING = process.argv.includes(
  '--record-redaction-indexeddb',
);
const ORIGIN_LOSS_AFTER_OFFLINE_EDIT = process.argv.includes(
  '--origin-loss-after-offline-edit');
const IDB_TEST_CHANNEL = `atermius-idb-write-failure-${crypto.randomUUID()}`;
const SEED_SHARED_IDB = UNCOMMITTED_BEFORE_CRASH || IDB_WRITE_FAILURE_RETRY ||
  INBOUND_CHANGES_CRASH || REDACTION_INDEXEDDB_ORDERING;
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `sync-crash-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `SyncCrash${crypto.randomBytes(24).toString('hex')}9`;
const DEVICE_NAME = `Sync crash ${RUN_ID.slice(0, 8)}`;
const TRUSTED_DEVICE_NAME = `Sync crash trusted ${RUN_ID.slice(0, 8)}`;
const RECOVERY_DEVICE_NAME = `Sync crash recovered ${RUN_ID.slice(0, 8)}`;
const VAULT_NAME = `Sync crash Vault ${RUN_ID.slice(0, 8)}`;
const HOST_NAME = `sync-crash-host-${RUN_ID}`;
const HOST_UPDATED_NAME = `sync-crash-host-updated-${RUN_ID}`;
const LOCAL_STORAGE_CRASH_PROBE_KEY = '__atermius_crash_persistence_probe';
const LOCAL_STORAGE_CRASH_PROBE_VALUE = crypto.randomUUID();
const HOST_ADDRESS = '192.0.2.77';
const HOST_USERNAME = 'sync-crash-user';
const HOST_PLAINTEXT_MARKERS = [HOST_NAME, HOST_UPDATED_NAME, HOST_ADDRESS, HOST_USERNAME];
const ORIGIN_LOSS_EDIT_NAME = `origin-loss-edit-${RUN_ID}`;
const ORIGIN_LOSS_PLAINTEXT_MARKERS = [
  ...HOST_PLAINTEXT_MARKERS,
  ORIGIN_LOSS_EDIT_NAME,
];
const CREDENTIAL_NAME = `sync-crash-credential-${RUN_ID}`;
const CREDENTIAL_USERNAME = `sync-crash-login-${RUN_ID.slice(0, 12)}`;
const CREDENTIAL_PASSWORD = `SyncCrashCredentialSecret-${crypto.randomBytes(24).toString('hex')}`;
const CREDENTIAL_PLAINTEXT_MARKERS = [
  CREDENTIAL_NAME,
  CREDENTIAL_USERNAME,
  CREDENTIAL_PASSWORD,
];
const GROUP_NAME = `sync-crash-group-${RUN_ID}`;
const GROUP_PLAINTEXT_MARKERS = [GROUP_NAME];
const SNIPPET_TITLE = `sync-crash-snippet-title-${RUN_ID}`;
const SNIPPET_BODY_MARKER = `sync-crash-snippet-body-${RUN_ID}`;
const SNIPPET_BODY = `printf '%s\\n' '${SNIPPET_BODY_MARKER}'`;
const SNIPPET_PLAINTEXT_MARKERS = [SNIPPET_TITLE, SNIPPET_BODY_MARKER];
const PRIMARY_RECORD_NAME = UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
  ? CREDENTIAL_NAME
  : UNCOMMITTED_GROUP_BEFORE_CRASH ? GROUP_NAME
    : UNCOMMITTED_SNIPPET_BEFORE_CRASH ? SNIPPET_TITLE
      : UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH ? HOST_UPDATED_NAME : HOST_NAME;
const PRIMARY_RECORD_TYPE = UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
  ? 'Password Credential'
  : UNCOMMITTED_GROUP_BEFORE_CRASH ? 'Group'
    : UNCOMMITTED_SNIPPET_BEFORE_CRASH ? 'Snippet' : 'Host';
const PRIMARY_PLAINTEXT_MARKERS = UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
  ? CREDENTIAL_PLAINTEXT_MARKERS
  : UNCOMMITTED_GROUP_BEFORE_CRASH
    ? GROUP_PLAINTEXT_MARKERS
    : UNCOMMITTED_SNIPPET_BEFORE_CRASH
      ? SNIPPET_PLAINTEXT_MARKERS : HOST_PLAINTEXT_MARKERS;
const INBOUND_HOST_FIXTURES = [
  {
    name: `sync-crash-inbound-a-${RUN_ID}`,
    address: `198.51.100.${10 + Number.parseInt(RUN_ID.slice(0, 2), 16) % 200}`,
    username: `inbound-a-${RUN_ID.slice(0, 8)}`,
  },
  {
    name: `sync-crash-inbound-b-${RUN_ID}`,
    address: `203.0.113.${10 + Number.parseInt(RUN_ID.slice(2, 4), 16) % 200}`,
    username: `inbound-b-${RUN_ID.slice(0, 8)}`,
  },
];
const INBOUND_RACE_HOST = {
  name: `sync-crash-outbox-race-${RUN_ID}`,
  address: `192.0.2.${20 + Number.parseInt(RUN_ID.slice(4, 6), 16) % 200}`,
  username: `outbox-race-${RUN_ID.slice(0, 8)}`,
};
const INBOUND_PLAINTEXT_MARKERS = [
  ...HOST_PLAINTEXT_MARKERS,
  ...INBOUND_HOST_FIXTURES.flatMap(({ name, address, username }) =>
    [name, address, username]),
  ...Object.values(INBOUND_RACE_HOST),
];
const REDACTION_PLAINTEXT_MARKERS = HOST_PLAINTEXT_MARKERS;

let activeStage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let profileDir;
let profileDirAtCrash;
let trustedProfileDir;
let serverProcess;
let browserContext;
let trustedContext;
let page;
let idbSecondPage;
let trustedPage;
let bootstrapToken;
let cleanupPromise;
let cleanupFailure = false;
let pageErrorCount = 0;
let idbSecondPageErrorCount = 0;
const safeApiLifecycleResponses = [];
let safeApiLifecycleCursor = 0;
let failedPushRequestCount = 0;
let captureUncommittedOperation = false;
let allowUncommittedRecoveryPush = false;
let uncommittedRecoveryReceipt;
let uncommittedRecoveryPushCount = 0;
let deviceIdAtRegistration;
let deviceIdAtLogin;
let deviceIdAtTrustedLogin;
let recoveryDeviceIdAtLogin;
let recoveryEnrollmentMode = 'not-started';
let deviceRecordPresentBeforeCrash = false;
let deviceRecordPresentAfterRestart = false;
let driftImplementation;
let localOutboxBeforeCrash;
let localOutboxAfterRecovery;
let trustedPageErrorCount = 0;
let trustedSyncPushRequestCount = 0;
let trustedPulledOperation;
let hostUpdateBaselinePromise;
let deferredHostUpdateBaselineResolve;
let droppedCommit;
let deferredCommitResolve;
let deferredAckResolve;
let deferredFailureResolve;
let deferredCommitReject;
let deferredAckReject;
let deferredFailureReject;
let commitPromise;
let acknowledgementDroppedPromise;
let failedPushPromise;
let crashOperation;
let restartChangesMatch;
let gateRestartChangesPage = false;
let restartChangesGateEvidence;
let restartChangesRequestCount = 0;
let restartChangesRouteCount = 0;
let restartChangesNon200Count = 0;
let restartChangesNoMatchCount = 0;
let restartChangesRouteFailureCount = 0;
let restartChangesLastStatus;
let restartChangesLastEventCount;
let restartChangesFailureClass;
let blockLostAckChangesBeforeCrash = false;
let preCrashLostAckChangesRequestCount = 0;
let preCrashLostAckChangesAbortCount = 0;
let preCrashLostAckChangesMatched = false;
const recoveredPushSummaries = [];
let captureLostAcknowledgement = false;
let idbWorkerRouteCount = 0;
let idbFailurePushRequestsBeforeRetry = 0;
let idbFailurePushRequestsAfterRetry = 0;
let idbFailureAllPushRequests = 0;
let idbFailureOperation;
let idbFailureReceipt;
let idbFailureRetryEnabled = false;
let idbFailureUiEvidence;
let idbFailureProbeEvidence;
let idbSecondTabEvidence;
let idbSyncControlDiagnostic;
let inboundReceiverArmed = false;
let inboundChangesRoutePhase = 'inactive';
let inboundOldCheckpoint;
let inboundBaselinePendingCount;
let inboundProducerRelease = deferred();
let inboundReceiverProbeArmed = false;
let inboundPreCrashPageSignal = deferred();
let inboundPreCrashPageEvidence;
let inboundReplayResponseSignal = deferred();
let inboundReplayResponseRelease = deferred();
let inboundReplayEvidence;
let inboundReplayRequestCount = 0;
let inboundReplayFirstCursor;
let inboundPreCrashRequestCount = 0;
let inboundPreCrashFirstCursor;
let inboundOwnerPushRequestCount = 0;
let inboundOutboxRacePhase = 'inactive';
let inboundOutboxRacePageRelease = deferred();
let inboundOutboxRacePageEvidence;
let inboundOutboxRaceRestartPageEvidence;
let inboundOutboxRacePushRelease = deferred();
let inboundOutboxRacePushResponseRelease = deferred();
let inboundOutboxRacePushRequestCount = 0;
let inboundOutboxRacePushAbortCount = 0;
let inboundOutboxRaceRestartPushCount = 0;
let inboundOutboxRacePushOperation;
let inboundOutboxRacePushReceipt;
let inboundOutboxRaceOwnEventPageEvidence;
let inboundWorkerCompletionHolds = 0;
let inboundPostFaultChangesRequestCount = 0;
let inboundProducerPushRequestCount = 0;
let inboundProducerPushRouteFailureCount = 0;
const inboundProducerPushStatuses = [];
const inboundProducerOperations = [];
let inboundCaptureProducerCreates = false;
let originLossBaselineOperation;
let hostUpdateBaselineOperation;
let trustedPulledBaselineOperation;
let redactionAuthorization;
let redactionCapabilityReportStatuses = [];
let trustedRedactionCapabilityReportStatuses = [];
let redactionLoginStatuses = [];
let redactionAuthRequestRoutes = [];
let redactionAuthResponseStatuses = [];
let redactionLifecycleOperations = [];
let redactionChangesRouteActive = false;
let redactionChangesPages = [];
let redactionChangesPageSignal = deferred();
let redactionChangesPageRelease = deferred();
let redactionChangesPageHold = false;
let redactionPurgeResponse;
let redactionTarget;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(stage) {
  activeStage = stage;
  console.log(`stage: ${stage}`);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function envelopeSummary(envelope, markers = HOST_PLAINTEXT_MARKERS) {
  const header = envelope?.header || {};
  return {
    recordId: header.record_id,
    revisionId: header.revision_id,
    baseRevisionId: header.base_revision_id ?? null,
    opId: header.op_id,
    deviceId: header.device_id,
    deviceSeq: header.device_seq,
    operation: header.operation,
    envelopeSha256: crypto.createHash('sha256')
      .update(stableJson(envelope))
      .digest('hex'),
    exactEnvelopeShape: JSON.stringify(Object.keys(envelope || {}).sort()) ===
      JSON.stringify(['ciphertext', 'header', 'nonce', 'signature']),
    ciphertextOnlyHeader: Object.keys(header).every((key) => new Set([
      'wire_version', 'server_space_id', 'vault_id', 'record_id',
      'revision_id', 'base_revision_id', 'op_id', 'device_id', 'device_seq',
      'key_epoch', 'membership_version', 'record_schema', 'operation',
      'crypto_suite', 'kdf_salt', 'object_refs',
    ]).has(key)),
    encodedCiphertextFields: ['nonce', 'ciphertext', 'signature'].every((key) =>
      typeof envelope?.[key] === 'string' && /^[A-Za-z0-9_-]+$/.test(envelope[key])),
    markersAbsent: markers.every((marker) =>
      !stableJson(envelope).includes(marker)),
  };
}

function runQuietly(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: options.maxBuffer || 4 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error(options.failureMessage || 'required local command failed');
  }
  return result.stdout || '';
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
    if (child.exitCode !== null) throw new Error('isolated server exited before readiness');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1500),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Keep polling while the isolated server starts.
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
    if (error.code !== 'ESRCH') throw new Error('could not stop isolated process group');
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

function chromiumProfileHasLiveProcesses(directory) {
  if (!directory || !fs.existsSync('/proc')) return false;
  const expectedArg = `--user-data-dir=${directory}`;
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8').split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (fields[0] !== 'Z' && fields[0] !== 'X') return true;
    } catch (_) {
      // Chromium can exit while /proc is being scanned.
    }
  }
  return false;
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  throw new Error('isolated server process group survived bounded cleanup');
}

function chromiumProfileProcessIdentity(directory) {
  assertThat(fs.existsSync('/proc'), 'Chromium kill acceptance requires Linux /proc');
  const expectedArg = `--user-data-dir=${directory}`;
  const matches = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8').split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      matches.push({
        pid: Number(entry),
        processGroup: Number(fields[2]),
        startTimeTicks: fields[19],
      });
    } catch (_) {
      // Chromium can exit while /proc is being scanned.
    }
  }
  assertThat(matches.length === 1 && matches[0].processGroup === matches[0].pid,
    'isolated Chromium process group was not uniquely identified');
  return matches[0];
}

function chromiumProfileProcessGroup(directory) {
  return chromiumProfileProcessIdentity(directory).processGroup;
}

async function forceKillChromiumProfile(directory) {
  const groupId = chromiumProfileProcessGroup(directory);
  signalProcessGroup(groupId, 'SIGKILL');
  assertThat(await waitForProcessGroupExit(groupId, 5000),
    'isolated Chromium process group survived SIGKILL');
  return groupId;
}

function apiPath(request) {
  try { return new URL(request.url()).pathname; } catch (_) { return ''; }
}

function safeApiRouteFamily(request) {
  const pathname = apiPath(request);
  if (pathname === '/api/v1/auth/register') return 'auth.register';
  if (pathname === '/api/v1/auth/login') return 'auth.login';
  if (pathname === '/api/v1/auth/refresh') return 'auth.refresh';
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(pathname)) {
    return 'vault.sync.push';
  }
  if (/^\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(pathname)) {
    return 'vault.changes';
  }
  return null;
}

function takeSafeApiLifecycleDelta() {
  const events = safeApiLifecycleResponses.slice(safeApiLifecycleCursor);
  safeApiLifecycleCursor = safeApiLifecycleResponses.length;
  return events.slice(-30);
}

function safeLocalStorageLevelDbMetadata(profilePath) {
  const directory = path.join(profilePath, 'Default', 'Local Storage', 'leveldb');
  try {
    const files = fs.readdirSync(directory).map((name) => {
      const stat = fs.statSync(path.join(directory, name));
      const kind = name.endsWith('.log') ? 'log'
        : name.endsWith('.ldb') || name.endsWith('.sst') ? 'table'
          : name.startsWith('MANIFEST-') ? 'manifest'
            : name === 'CURRENT' ? 'current' : 'metadata';
      return {
        kind,
        byteLength: stat.size,
        modifiedAgeMs: Math.max(0, Date.now() - stat.mtimeMs),
      };
    });
    files.sort((left, right) => left.kind.localeCompare(right.kind) ||
      left.byteLength - right.byteLength);
    return {
      directoryPresent: true,
      fileCount: files.length,
      totalBytes: files.reduce((total, file) => total + file.byteLength, 0),
      files,
    };
  } catch (_) {
    return { directoryPresent: false, fileCount: 0, totalBytes: 0, files: [] };
  }
}

function localStorageLevelDbFingerprint(profilePath) {
  const directory = path.join(profilePath, 'Default', 'Local Storage', 'leveldb');
  try {
    return fs.readdirSync(directory).map((name) => {
      const stat = fs.statSync(path.join(directory, name));
      const kind = name.endsWith('.log') ? 'log'
        : name.endsWith('.ldb') || name.endsWith('.sst') ? 'table'
          : name.startsWith('MANIFEST-') ? 'manifest'
            : name === 'CURRENT' ? 'current' : 'metadata';
      return `${kind}:${stat.size}:${Math.trunc(stat.mtimeMs)}`;
    }).sort().join('|');
  } catch (_) {
    return 'missing';
  }
}

async function waitForLocalStorageLevelDbCommit(profilePath, previousFingerprint,
    { requireChange = true, timeoutMs = 5000 } = {}) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let previous = previousFingerprint;
  let changed = false;
  let stableSamples = 0;
  while (Date.now() < deadline) {
    const current = localStorageLevelDbFingerprint(profilePath);
    if (current !== previousFingerprint) changed = true;
    if (current === previous) stableSamples += 1;
    else stableSamples = 0;
    if ((!requireChange || changed) && stableSamples >= 2) {
      return { changed, stable: true, elapsedMs: Date.now() - startedAt };
    }
    previous = current;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return { changed, stable: false, elapsedMs: Date.now() - startedAt };
}

async function logUncommittedPersistenceCheckpoint(label, pageRef = page) {
  const storage = await safeBrowserStorageDiagnostic(pageRef);
  console.log(`${PRIMARY_RECORD_TYPE} safe persistence checkpoint: ${label}`, JSON.stringify({
    storage,
    localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
    apiResponses: takeSafeApiLifecycleDelta(),
  }));
  return storage;
}

function visibleFieldSelector(label) {
  return `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
}

async function field(pageRef, label, timeoutMs = 15000) {
  const locator = pageRef.locator(visibleFieldSelector(label));
  await selectServerModeIfChooser(pageRef, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await pageRef.waitForTimeout(100);
  }
  throw new Error('expected visible browser field was unavailable');
}

async function button(pageRef, label, timeoutMs = 15000) {
  const locator = pageRef.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(pageRef, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let index = 0; index < await locator.count(); index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await pageRef.waitForTimeout(100);
  }
  throw new Error('expected visible browser button was unavailable');
}

async function click(pageRef, label) {
  await (await button(pageRef, label)).click();
}

async function pullTrustedProfileChanges() {
  const syncButton = trustedPage.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  const currentLabel = await syncButton.getAttribute('aria-label') ||
    (await syncButton.innerText()).trim();
  if (currentLabel === 'Syncing') return;
  const changesRequest = trustedPage.waitForRequest((request) => {
    let pathname = '';
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    return request.method() === 'GET' &&
      /\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(pathname);
  }, { timeout: 15000 });
  await syncButton.click();
  await changesRequest;
}

async function clickCredentialMenuAction(pageRef, credentialName, action) {
  const escapedName = credentialName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const card = pageRef.getByRole('group', {
    name: new RegExp(`^Credential: ${escapedName}; `),
  });
  await card.waitFor({ state: 'visible', timeout: 15000 });
  const actionButtons = card.getByRole('button');
  assertThat(await actionButtons.count() === 1,
    'recovered Credential card did not expose one action button');
  await actionButtons.first().click();
  await pageRef.getByRole('menuitem', { name: action, exact: true })
    .click({ timeout: 10000 });
}

async function clickGroupMenuAction(pageRef, groupName, action) {
  const actions = pageRef.getByRole('button', {
    name: `Group actions: ${groupName}`,
    exact: true,
  }).last();
  await actions.waitFor({ state: 'visible', timeout: 15000 });
  await actions.click();
  await pageRef.getByRole('menuitem', { name: action, exact: true })
    .click({ timeout: 10000 });
}

async function fill(pageRef, label, value) {
  const locator = await field(pageRef, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await pageRef.waitForTimeout(150);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 35 });
    await pageRef.waitForTimeout(180);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await pageRef.waitForTimeout(80);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('visible browser field did not retain its value');
}

async function pasteClipboard(pageRef, label, value) {
  await pageRef.evaluate((text) => navigator.clipboard.writeText(text), value);
  try {
    const locator = await field(pageRef, label);
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await pageRef.waitForTimeout(200);
    if (await locator.inputValue().catch(() => '') !== value) {
      await fill(pageRef, label, value);
    }
    assertThat(await locator.inputValue() === value,
      'clipboard or visible-field fallback did not populate an enrollment field');
  } finally {
    await pageRef.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  }
}

async function readClipboard(pageRef) {
  return pageRef.evaluate(() => navigator.clipboard.readText());
}

async function requestDeviceEnrollment(pageRef, deviceName) {
  setStage('enrollment: open request from device login');
  await field(pageRef, 'Email or username');
  await click(pageRef, 'Add this device');
  setStage('enrollment: wait for request form');
  await waitForSemanticText(pageRef, 'Request this device');
  setStage('enrollment: fill requested account and device name');
  await fill(pageRef, 'Account email', USERNAME);
  await fill(pageRef, 'Device name', deviceName);
  setStage('enrollment: generate signed device request');
  await click(pageRef, 'Generate request');
  setStage('enrollment: copy and validate public request');
  await field(pageRef, 'Copy this enrollment JSON');
  await click(pageRef, 'Copy');
  const enrollmentJson = await readClipboard(pageRef);
  await pageRef.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  let format;
  try { format = JSON.parse(enrollmentJson).format; } catch (_) {}
  assertThat(format === 'atermius-device-enrollment-v1',
    'browser did not create a valid device enrollment request');
  await click(pageRef, 'Close');
  return enrollmentJson;
}

async function approveEnrollment(pageRef, enrollmentJson) {
  setStage('enrollment approval: open trusted device review');
  await click(pageRef, 'Devices');
  await click(pageRef, 'Approve enrollment');
  setStage('enrollment approval: paste request and review keys');
  await pasteClipboard(pageRef, 'Enrollment JSON', enrollmentJson);
  await click(pageRef, 'Review keys');
  setStage('enrollment approval: seal approved Vault keys');
  await click(pageRef, 'Approve & seal keys');
  await button(pageRef, 'Copy');
  await click(pageRef, 'Copy');
  setStage('enrollment approval: capture and validate sealed response');
  const approvalJson = await readClipboard(pageRef);
  await pageRef.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  let format;
  try { format = JSON.parse(approvalJson).format; } catch (_) {}
  assertThat(format === 'atermius-device-approval-v1',
    'trusted device did not create a valid device approval');
  await click(pageRef, 'Done');
  await click(pageRef, 'Hosts');
  return approvalJson;
}

async function importDeviceApprovalAndSignIn(pageRef, approvalJson) {
  setStage('enrollment import: open approval dialog');
  await click(pageRef, 'Import approval');
  setStage('enrollment import: fill trusted response field');
  try {
    const approvalInput = await field(pageRef, 'Paste approval JSON');
    await approvalInput.fill(approvalJson);
    assertThat(await approvalInput.inputValue() === approvalJson,
      'approval JSON did not populate the visible import field');
  } catch (error) {
    const diagnostic = await safeConnectionDiagnostic(pageRef);
    const approvalInputVisible = await pageRef
      .locator(visibleFieldSelector('Paste approval JSON'))
      .isVisible().catch(() => false);
    console.log('device approval paste safe diagnostic', JSON.stringify({
      diagnostic,
      approvalInputVisible,
      pageErrors: pageRef === page ? pageErrorCount : trustedPageErrorCount,
      errorClass: error?.name === 'TimeoutError' ? 'timeout' : 'error',
    }));
    await pageRef.screenshot({
      path: path.join(tempRoot, 'approval-paste-failure.png'),
    }).catch(() => {});
    throw error;
  }
  setStage('enrollment import: import device key envelopes');
  await click(pageRef, 'Import device keys');
  setStage('enrollment import: fill account identity');
  await fill(pageRef, 'Email or username', USERNAME);
  setStage('enrollment import: fill master password');
  await fill(pageRef, 'Master password', MASTER_PASSWORD);
  setStage('enrollment import: submit sign-in');
  await click(pageRef, 'Sign in and unlock');
  setStage('enrollment import: wait for trusted workspace');
  try {
    await waitForWorkspace(pageRef);
  } catch (error) {
    const diagnostic = await safeConnectionDiagnostic(pageRef);
    console.log('device enrollment import safe diagnostic', JSON.stringify({
      diagnostic,
      pageErrors: pageRef === page ? pageErrorCount : trustedPageErrorCount,
    }));
    await pageRef.screenshot({
      path: path.join(tempRoot, 'enrollment-workspace-failure.png'),
    }).catch(() => {});
    throw error;
  }
}

async function waitForCondition(condition, description, timeoutMs = 30000, pageRef = page) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await condition()) return;
    await pageRef.waitForTimeout(100);
  }
  throw new Error(`${description} timed out`);
}

async function waitForWorkspace(pageRef, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await pageRef.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) return;
    await pageRef.waitForTimeout(100);
  }
  throw new Error('workspace did not become available');
}

async function waitForSemanticText(pageRef, expected, timeoutMs = 30000) {
  await waitForCondition(async () => pageRef.evaluate((text) => {
    if ((document.body.innerText || '').includes(text)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
        .includes(text));
  }, expected).catch(() => false), 'expected record UI state', timeoutMs, pageRef);
}

async function visibleSyncState(pageRef) {
  return pageRef.evaluate(() => {
    const labels = [];
    for (const element of document.querySelectorAll('flt-semantics')) {
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const label = [element.getAttribute('aria-label') || '',
        element.getAttribute('title') || '', element.innerText || '']
        .join(' ').replace(/\s+/g, ' ').trim();
      if (/pending\s+\d+.*conflicts\s+\d+/i.test(label)) labels.push(label);
    }
    return labels[0] || null;
  }).catch(() => null);
}

async function visiblePendingCount(pageRef) {
  const status = await visibleSyncState(pageRef);
  const match = status?.match(/pending\s+(\d+)/i);
  return match ? Number(match[1]) : null;
}

async function safeConnectionDiagnostic(pageRef) {
  return pageRef.evaluate((expectedServerUrl) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
    };
    const visibleText = [document.body.innerText || '',
      ...[...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`),
    ].join('\n');
    const serverUrlInputs = [...document.querySelectorAll('input,textarea')]
      .filter(visible)
      .filter((element) => (element.getAttribute('aria-label') || '').includes('Server URL'));
    const connectButtons = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .filter((element) => /Connect securely/.test(
        `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`));
    return {
      chooseWorkspaceVisible: visibleText.includes('Choose a workspace'),
      serverModeVisible: visibleText.includes('Server account and sync'),
      chooseDeviceVisible: visibleText.includes('Choose this device') ||
        visibleText.includes('device approval'),
      enrollmentVisible: visibleText.includes('Add this device') ||
        visibleText.includes('Generate request'),
      unlockVisible: visibleText.includes('Unlock'),
      retryVisible: visibleText.includes('Retry'),
      serverUrlInputCount: serverUrlInputs.length,
      serverUrlValueMatches: serverUrlInputs.some((element) =>
        element.value === expectedServerUrl),
      connectButtonCount: connectButtons.length,
      connectButtonStates: connectButtons.map((element) => {
        const rect = element.getBoundingClientRect();
        const hit = document.elementFromPoint(rect.left + rect.width / 2,
          rect.top + rect.height / 2);
        return {
          enabled: element.getAttribute('aria-disabled') !== 'true' &&
            !element.hasAttribute('disabled'),
          centerHitsTarget: Boolean(hit &&
            (hit === element || element.contains(hit) || hit.contains(element))),
        };
      }),
      signInUsernameVisible: [...document.querySelectorAll('input')]
        .some((element) => visible(element) &&
          (element.getAttribute('aria-label') || '').includes('Email or username')),
      signInInputState: (() => {
        const inputs = [...document.querySelectorAll('input')].filter(visible);
        const username = inputs.find((element) =>
          (element.getAttribute('aria-label') || '').includes('Email or username'));
        const password = inputs.find((element) =>
          (element.getAttribute('aria-label') || '').includes('Master password'));
        return {
          usernamePresent: Boolean(username?.value),
          passwordLength: password?.value?.length || 0,
        };
      })(),
      signInButtonEnabled: [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .some((element) => /Sign in and unlock/.test(
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`) &&
          element.getAttribute('aria-disabled') !== 'true' &&
          !element.hasAttribute('disabled')),
      signInButtonVisible: [...document.querySelectorAll('flt-semantics[role="button"]')]
        .some((element) => visible(element) && /Sign in and unlock/.test(
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`)),
      signInFeedbackCategories: [...new Set(visibleText.toLowerCase().match(
        /invalid|incorrect|unauthorized|try again|network|server unavailable|too many attempts/g,
      ) || [])].sort(),
      signInFeedbackZhCategories: [
        ['registered-device-missing', '当前浏览器没有已注册的设备密钥'],
        ['login-failed', '登录失败'],
        ['account-password-invalid', '账户或密码错误'],
        ['device-not-approved', '设备尚未批准'],
        ['request-pending', '请稍后重试'],
        ['network-error', '网络'],
      ].filter(([, marker]) => visibleText.includes(marker)).map(([category]) => category),
      addHostVisible: visibleText.includes('Add host'),
    };
  }, baseUrl).catch(() => ({ diagnosticUnavailable: true }));
}

async function safeBrowserStorageDiagnostic(pageRef) {
  return pageRef.evaluate((expectedOrigin) => {
    const kinds = (storage) => {
      const found = new Set();
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key === 'FlutterSecureStorage') found.add('secure-store-key');
        else if (key.endsWith('.device')) found.add('device');
        else if (key.includes('.session.')) found.add('session');
        else if (key.includes('.refresh.')) found.add('refresh');
        else if (key.endsWith('.last-server')) found.add('last-server');
        else if (key.startsWith('FlutterSecureStorage.')) found.add('other-secure-store');
        else found.add('other');
      }
      return [...found].sort();
    };
    const localKinds = kinds(window.localStorage);
    const sessionKinds = kinds(window.sessionStorage);
    return {
      expectedOrigin: window.location.origin === expectedOrigin,
      secureContext: window.isSecureContext === true,
      localStorageKinds: localKinds,
      sessionStorageKinds: sessionKinds,
      deviceRecordPresent: localKinds.includes('device') || sessionKinds.includes('device'),
    };
  }, new URL(baseUrl).origin).catch(() => ({ diagnosticUnavailable: true }));
}

async function readClientDatabaseFromIndexedDb(pageRef) {
  return pageRef.evaluate(async () => {
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
      const fileValuesPromise = new Promise((resolve, reject) => {
        const request = filesStore.getAll();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error || new Error('IDB file metadata read failed'));
      });
      const fileIdsPromise = new Promise((resolve, reject) => {
        const request = filesStore.getAllKeys();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error || new Error('IDB file key read failed'));
      });
      const [fileValues, fileIds] = await Promise.all([
        fileValuesPromise, fileIdsPromise, filesComplete,
      ]);
      const metadata = fileValues.map((value, index) => ({
        fileId: Number(fileIds[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' ||
        file.name === '/database-journal');
      const databaseFile = metadata.find((file) => file.name === '/database');
      if (!databaseFile) {
        return {
          available: false,
          reason: 'drift-sqlite-database-file-missing',
          databaseName: 'atermius_vault',
          fileNames: metadata.map((file) => file.name),
        };
      }

      const selectedFiles = metadata.filter((file) =>
        file.name === '/database' || file.name === '/database-journal');
      if (selectedFiles.some((file) => !Number.isSafeInteger(file.fileId) ||
          !Number.isSafeInteger(file.length) || file.length < 0 ||
          file.length > 64 * 1024 * 1024)) {
        return { available: false, reason: 'drift-sqlite-file-size-out-of-range' };
      }

      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('IDB blocks read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('IDB blocks read aborted'));
      });
      const blocksStore = blocksTx.objectStore('blocks');
      const requests = selectedFiles.map((file) => {
        const range = IDBKeyRange.bound(
          [file.fileId, 0], [file.fileId, 9007199254740992]);
        const keysPromise = new Promise((resolve, reject) => {
          const request = blocksStore.getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB block keys read failed'));
        });
        const valuesPromise = new Promise((resolve, reject) => {
          const request = blocksStore.getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB block values read failed'));
        });
        return Promise.all([keysPromise, valuesPromise]).then(([keys, values]) => ({
          file,
          blocks: keys.map((key, index) => ({
            offset: Number(key?.[1]),
            value: values[index],
          })),
        }));
      });
      const fileBlocks = await Promise.all([...requests, blocksComplete]);
      const filesWithBlocks = fileBlocks.filter((entry) => entry && entry.file)
        .map(({ file, blocks }) => ({
          ...file,
          blocks: blocks.map(({ offset, value }) => {
            let bytes;
            if (value instanceof ArrayBuffer) {
              bytes = new Uint8Array(value);
            } else if (ArrayBuffer.isView(value)) {
              bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            } else if (value instanceof Blob) {
              return value.arrayBuffer().then((buffer) => ({
                offset, byteLength: buffer.byteLength,
                base64: btoa(String.fromCharCode(...new Uint8Array(buffer))),
              }));
            } else {
              throw new Error('unsupported IndexedDB block value');
            }
            let binary = '';
            for (let offsetAt = 0; offsetAt < bytes.length; offsetAt += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(offsetAt, offsetAt + 0x8000));
            }
            return { offset, byteLength: bytes.length, base64: btoa(binary) };
          }),
        }));
      const resolvedFiles = await Promise.all(filesWithBlocks.map(async (file) => ({
        ...file,
        blocks: await Promise.all(file.blocks),
      })));
      const mainFile = resolvedFiles.find((file) => file.name === '/database');
      if (!mainFile || mainFile.length === 0) {
        return { available: false, reason: 'drift-sqlite-database-empty' };
      }
      return {
        available: true,
        databaseName: 'atermius_vault',
        objectStoreNames: ['files', 'blocks'],
        sqliteFiles: resolvedFiles,
      };
    } finally {
      connection.close();
    }
  });
}

async function snapshotClientVaultCounts(pageRef) {
  const stored = await readClientDatabaseFromIndexedDb(pageRef);
  assertThat(stored?.available === true,
    `actual IndexedDB SQLite snapshot unavailable: ${stored?.reason || 'unknown'}`);
  const summary = inspectClientVaultCounts(stored.sqliteFiles);
  assertThat(summary?.available === true && summary.integrityCheck === 'ok',
    `actual IndexedDB SQLite count snapshot invalid: ${summary?.reason || summary?.integrityCheck || 'unknown'}`);
  return summary;
}

function inspectClientOutboxFiles(
  sqliteFiles, operation, markers = PRIMARY_PLAINTEXT_MARKERS,
) {
  const snapshotPath = path.join(tempRoot, 'client-vault-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { unavailableReason: journalFile ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  let databaseBytes;
  try {
    databaseBytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { unavailableReason: 'sqlite-database-blocks-invalid' };
  }
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  const localPlaintextMarkerFound = markers.some((marker) =>
    databaseBytes.includes(Buffer.from(marker, 'utf8')));
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'op_id,vault_id,record_id,revision_id,expected_hash,expected_commit_seq=sys.argv[2:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute('SELECT op_id,vault_id,record_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE op_id=?',(op_id,)).fetchall()",
    "record=db.execute('SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    "record_ops=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded'\",(vault_id,record_id)).fetchone()[0]",
    "vault_ops=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    'def digest(text):',
    '    if text is None: return None',
    '    value=json.loads(text)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest()',
    'pending=None',
    'if len(rows)==1:',
    '    row=rows[0]',
    '    pending={"opId":row[0],"vaultId":row[1],"recordId":row[2],"baseRevisionId":row[3],"baseEnvelopePresent":row[4] is not None,"baseEnvelopeSha256":digest(row[4]),"envelopeSha256":digest(row[5]),"status":row[6]}',
    'result={"integrityCheck":integrity,"pendingCount":len(rows),"pending":pending,"recordOperationCount":record_ops,"vaultOperationCount":vault_ops,"record":None}',
    'if record:',
    '    result["record"]={"revisionId":record[0],"envelopeSha256":digest(record[1]),"commitSeq":record[2],"isDeleted":bool(record[3])}',
    'print(json.dumps(result,separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath,
      operation.opId, operation.vaultId, operation.recordId,
      operation.revisionId, operation.envelopeSha256,
      operation.receipt?.commitSeq || ''], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) return { unavailableReason: 'sqlite-query-failed' };
    return {
      ...JSON.parse(result.stdout),
      plaintextMarkerFound: localPlaintextMarkerFound,
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function inspectClientPendingHostOutbox(
  sqliteFiles, vaultId, recordId, markers = ORIGIN_LOSS_PLAINTEXT_MARKERS,
) {
  const snapshotPath = path.join(tempRoot, 'client-origin-loss-outbox.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'B IndexedDB snapshot had no database or an active journal');
  const databaseBytes = reconstructSqliteFile({
    fileId: databaseFile.fileId,
    name: databaseFile.name,
    length: databaseFile.length,
    blocks: databaseFile.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  const localPlaintextMarkerFound = markers.some((marker) =>
    databaseBytes.includes(Buffer.from(marker, 'utf8')));
  const python = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id=sys.argv[2:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute(\"SELECT op_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    "vault_pending=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    "record=db.execute('SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    'def parse(text):',
    '    try: return json.loads(text) if text is not None else None',
    '    except Exception: return None',
    'def digest(text):',
    '    value=parse(text)',
    '    if value is None: return None',
    '    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()',
    'pending=None',
    'if len(rows)==1:',
    '    row=rows[0]',
    '    envelope=parse(row[3]) or {}',
    '    header=envelope.get("header",{}) if isinstance(envelope,dict) else {}',
    '    pending={"opId":row[0],"baseRevisionId":row[1],"baseEnvelopePresent":row[2] is not None,"revisionId":header.get("revision_id"),"headerBaseRevisionId":header.get("base_revision_id"),"operation":header.get("operation"),"envelopeSha256":digest(row[3]),"status":row[4] }',
    'record_summary=None',
    'if record:',
    '    record_summary={"revisionId":record[0],"envelopeSha256":digest(record[1]),"commitSeq":str(record[2]) if record[2] is not None else None,"isDeleted":bool(record[3])}',
    'print(json.dumps({"integrityCheck":integrity,"recordPendingCount":len(rows),"vaultPendingCount":vault_pending,"pending":pending,"record":record_summary},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId, recordId], {
      encoding: 'utf8',
      timeout: 10000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'B IndexedDB outbox query failed');
    return {
      ...JSON.parse(result.stdout),
      plaintextMarkerFound: localPlaintextMarkerFound,
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function inspectClientInboundChangesFiles(
  sqliteFiles, vaultId, operations, expectedCheckpoint, baselinePendingCount,
) {
  const snapshotPath = path.join(tempRoot, 'client-inbound-crash-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { available: false, reason: journalFile
      ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  let databaseBytes;
  try {
    databaseBytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { available: false, reason: 'sqlite-database-blocks-invalid' };
  }
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try {
    const python = [
      'import hashlib,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'expected=json.loads(sys.stdin.read())',
      'vault_id=expected["vaultId"]',
      'operations=expected["operations"]',
      'checkpoint_expected=expected["checkpoint"]',
      'markers=expected["markers"]',
      'baseline_pending=expected["baselinePendingCount"]',
      "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
      "checkpoints=db.execute('SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=?',(vault_id,)).fetchall()",
      "pending_count=db.execute('SELECT count(*) FROM pending_operations WHERE vault_id=?',(vault_id,)).fetchone()[0]",
      'def digest(text):',
      '    try: value=json.loads(text)',
      '    except Exception: return None',
      '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
      '    return hashlib.sha256(canonical.encode()).hexdigest()',
      'records=[]',
      'for operation in operations:',
      '    rows=db.execute("SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?",(vault_id,operation["recordId"])).fetchall()',
      '    records.append({"rowCount":len(rows),"revisionMatches":len(rows)==1 and rows[0][0]==operation["revisionId"],"envelopeHashMatches":len(rows)==1 and digest(rows[0][1])==operation["envelopeSha256"],"commitSeq":str(rows[0][2]) if len(rows)==1 and rows[0][2] is not None else None,"commitSeqMatches":len(rows)==1 and str(rows[0][2])==operation["commitSeq"],"notDeleted":len(rows)==1 and not rows[0][3]})',
      'checkpoint=None',
      'if len(checkpoints)==1: checkpoint={"cursor":checkpoints[0][0],"serverGeneration":checkpoints[0][1]}',
      'checkpoint_matches_old=(checkpoint==checkpoint_expected)',
      'with open(sys.argv[1],"rb") as source: database_bytes=source.read()',
      'marker_found=any(marker.encode() in database_bytes for marker in markers)',
      'result={"integrityCheck":integrity,"checkpointRowCount":len(checkpoints),"checkpoint":checkpoint,"checkpointMatchesExpected":checkpoint_matches_old,"records":records,"recordsExactlyOnce":len(records)==2 and all(row["rowCount"]==1 and row["revisionMatches"] and row["envelopeHashMatches"] and row["commitSeqMatches"] and row["notDeleted"] for row in records),"pendingOperationCount":pending_count,"pendingCountMatchesBaseline":pending_count==baseline_pending,"plaintextMarkerFound":marker_found}',
      'print(json.dumps(result,separators=(",",":")))',
    ].join('\n');
    const input = JSON.stringify({
      vaultId,
      operations: operations.map((operation) => ({
        recordId: operation.recordId,
        revisionId: operation.revisionId,
        envelopeSha256: operation.envelopeSha256,
        commitSeq: operation.receipt.commitSeq,
      })),
      checkpoint: expectedCheckpoint,
      markers: INBOUND_PLAINTEXT_MARKERS,
      baselinePendingCount,
    });
    const result = spawnSync('python3', ['-c', python, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      input, stdio: ['pipe', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) {
      return { available: false, reason: 'sqlite-inbound-query-failed' };
    }
    return {
      available: true,
      ...JSON.parse(result.stdout),
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function snapshotClientInboundChanges(pageRef, ...args) {
  const stored = await readClientDatabaseFromIndexedDb(pageRef);
  if (stored?.available !== true) {
    return { available: false, reason: stored?.reason || 'idb-snapshot-unavailable' };
  }
  return inspectClientInboundChangesFiles(stored.sqliteFiles, ...args);
}

function inspectClientInboundOutboxRaceFiles(
  sqliteFiles, vaultId, remoteOperations = [], localRecordId = null,
) {
  const snapshotPath = path.join(tempRoot, 'client-inbound-outbox-race.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { available: false, reason: journalFile
      ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  let databaseBytes;
  try {
    databaseBytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { available: false, reason: 'sqlite-database-blocks-invalid' };
  }
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try {
    const python = [
      'import hashlib,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'expected=json.loads(sys.stdin.read())',
      'vault_id=expected["vaultId"]',
      "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
      "checkpoints=db.execute('SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=?',(vault_id,)).fetchall()",
      'checkpoint=None',
      'if len(checkpoints)==1: checkpoint={"cursor":checkpoints[0][0],"serverGeneration":checkpoints[0][1]}',
      'def digest(text):',
      '    try: value=json.loads(text) if text is not None else None',
      '    except Exception: return None',
      '    if value is None: return None',
      '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
      '    return hashlib.sha256(canonical.encode()).hexdigest()',
      'def parse_header(text):',
      '    try: value=json.loads(text) if text is not None else {}',
      '    except Exception: value={}',
      '    header=value.get("header",{}) if isinstance(value,dict) else {}',
      '    return header if isinstance(header,dict) else {}',
      'pending=[]',
      "for row in db.execute(\"SELECT op_id,record_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE vault_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,)):",
      '    header=parse_header(row[4])',
      '    cache=db.execute("SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?",(vault_id,row[1])).fetchall()',
      '    pending.append({"opId":row[0],"recordId":row[1],"rowBaseRevisionId":row[2],"revisionId":header.get("revision_id"),"headerBaseRevisionId":header.get("base_revision_id"),"operation":header.get("operation"),"deviceId":header.get("device_id"),"envelopeSha256":digest(row[4]),"baseEnvelopePresent":row[3] is not None,"status":row[5],"cacheRowCount":len(cache),"cacheRevisionId":cache[0][0] if len(cache)==1 else None,"cacheEnvelopeSha256":digest(cache[0][1]) if len(cache)==1 else None,"cacheCommitSeq":str(cache[0][2]) if len(cache)==1 and cache[0][2] is not None else None,"cacheDeleted":bool(cache[0][3]) if len(cache)==1 else None})',
      'local_record=None',
      'if expected.get("localRecordId"): ',
      '    rows=db.execute("SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?",(vault_id,expected["localRecordId"])).fetchall()',
      '    local_record={"rowCount":len(rows),"revisionId":rows[0][0] if len(rows)==1 else None,"envelopeSha256":digest(rows[0][1]) if len(rows)==1 else None,"commitSeq":str(rows[0][2]) if len(rows)==1 and rows[0][2] is not None else None,"isDeleted":bool(rows[0][3]) if len(rows)==1 else None}',
      'remote=[]',
      'for operation in expected["remoteOperations"]:',
      '    rows=db.execute("SELECT revision_id,envelope_json,commit_seq,is_deleted FROM encrypted_records WHERE vault_id=? AND record_id=?",(vault_id,operation["recordId"])).fetchall()',
      '    remote.append({"recordId":operation["recordId"],"rowCount":len(rows),"revisionMatches":len(rows)==1 and rows[0][0]==operation["revisionId"],"envelopeHashMatches":len(rows)==1 and digest(rows[0][1])==operation["envelopeSha256"],"commitSeq":str(rows[0][2]) if len(rows)==1 and rows[0][2] is not None else None,"commitSeqMatches":len(rows)==1 and str(rows[0][2])==operation["commitSeq"],"notDeleted":len(rows)==1 and not rows[0][3]})',
      'with open(sys.argv[1],"rb") as source: database_bytes=source.read()',
      'marker_found=any(marker.encode() in database_bytes for marker in expected["markers"])',
      'print(json.dumps({"integrityCheck":integrity,"checkpointRowCount":len(checkpoints),"checkpoint":checkpoint,"pendingOperations":pending,"localRecord":local_record,"remoteRecords":remote,"remoteRecordsExactlyOnce":len(remote)==len(expected["remoteOperations"]) and all(row["rowCount"]==1 and row["revisionMatches"] and row["envelopeHashMatches"] and row["commitSeqMatches"] and row["notDeleted"] for row in remote),"plaintextMarkerFound":marker_found},separators=(",",":")))',
    ].join('\n');
    const input = JSON.stringify({
      vaultId,
      remoteOperations: remoteOperations.map((operation) => ({
        recordId: operation.recordId,
        revisionId: operation.revisionId,
        envelopeSha256: operation.envelopeSha256,
        commitSeq: operation.receipt.commitSeq,
      })),
      localRecordId,
      markers: INBOUND_PLAINTEXT_MARKERS,
    });
    const result = spawnSync('python3', ['-c', python, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 8192,
      input, stdio: ['pipe', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) {
      return { available: false, reason: 'sqlite-inbound-outbox-race-query-failed' };
    }
    return {
      available: true,
      ...JSON.parse(result.stdout),
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function snapshotClientInboundOutboxRace(
  pageRef, vaultId, remoteOperations = [], localRecordId = null,
) {
  const stored = await readClientDatabaseFromIndexedDb(pageRef);
  if (stored?.available !== true) {
    return { available: false, reason: stored?.reason || 'idb-snapshot-unavailable' };
  }
  return inspectClientInboundOutboxRaceFiles(
    stored.sqliteFiles, vaultId, remoteOperations, localRecordId);
}

function inspectClientRedactionStateFiles(sqliteFiles, expected) {
  const snapshotPath = path.join(tempRoot, 'client-redaction-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { available: false, reason: journalFile
      ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  let databaseBytes;
  try {
    databaseBytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { available: false, reason: 'sqlite-database-blocks-invalid' };
  }
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try {
    const python = [
      'import json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'expected=json.loads(sys.stdin.read())',
      "tables={row[0] for row in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
      "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
      'vault_id=expected["vaultId"]',
      'record_id=expected["recordId"]',
      'instance_id=expected["instanceId"]',
      'server_space_id=expected["serverSpaceId"]',
      'checkpoints=[]',
      "if 'sync_checkpoints' in tables: checkpoints=db.execute('SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=? AND instance_id=? AND server_space_id=?',(vault_id,instance_id,server_space_id)).fetchall()",
      'checkpoint=None',
      'if len(checkpoints)==1: checkpoint={"cursor":checkpoints[0][0],"serverGeneration":checkpoints[0][1]}',
      'record_count=0',
      "if 'encrypted_records' in tables: record_count=db.execute('SELECT count(*) FROM encrypted_records WHERE vault_id=? AND record_id=? AND instance_id=? AND server_space_id=?',(vault_id,record_id,instance_id,server_space_id)).fetchone()[0]",
      'redactions=[]',
      "if 'sync_redactions' in tables: redactions=db.execute('SELECT proof_json FROM sync_redactions WHERE vault_id=? AND record_id=? AND instance_id=? AND server_space_id=?',(vault_id,record_id,instance_id,server_space_id)).fetchall()",
      'proof=None',
      'if len(redactions)==1:\n    try: proof=json.loads(redactions[0][0])\n    except Exception: proof=None',
      'expected_proof=expected["proof"]',
      'pending_count=0',
      "if 'pending_operations' in tables: pending_count=db.execute('SELECT count(*) FROM pending_operations WHERE vault_id=? AND record_id=? AND instance_id=? AND server_space_id=?',(vault_id,record_id,instance_id,server_space_id)).fetchone()[0]",
      'with open(sys.argv[1],"rb") as source: database_bytes=source.read()',
      'result={"integrityCheck":integrity,"checkpointRowCount":len(checkpoints),"checkpoint":checkpoint,"checkpointMatchesOld":checkpoint==expected["oldCheckpoint"],"checkpointMatchesTarget":checkpoint==expected["targetCheckpoint"],"encryptedRecordCount":record_count,"redactionRowCount":len(redactions),"redactionProofMatches":proof==expected_proof,"pendingRecordCount":pending_count,"plaintextMarkerFound":any(marker.encode() in database_bytes for marker in expected["markers"])}',
      'print(json.dumps(result,separators=(",",":")))',
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      input: JSON.stringify(expected), stdio: ['pipe', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) {
      return { available: false, reason: 'sqlite-redaction-query-failed' };
    }
    return {
      available: true,
      ...JSON.parse(result.stdout),
      sourceDatabase: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function snapshotClientRedactionState(pageRef, expected) {
  const stored = await readClientDatabaseFromIndexedDb(pageRef);
  if (stored?.available !== true) {
    return { available: false, reason: stored?.reason || 'idb-snapshot-unavailable' };
  }
  return inspectClientRedactionStateFiles(stored.sqliteFiles, expected);
}

function inspectClientVaultCounts(sqliteFiles) {
  const snapshotPath = path.join(tempRoot, 'client-vault-count-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  if (!databaseFile || (journalFile && journalFile.length !== 0)) {
    return { available: false, reason: journalFile
      ? 'sqlite-journal-not-empty' : 'sqlite-database-file-missing' };
  }
  let databaseBytes;
  try {
    databaseBytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (_) {
    return { available: false, reason: 'sqlite-database-blocks-invalid' };
  }
  fs.writeFileSync(snapshotPath, databaseBytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try {
    const python = [
      'import json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      "tables={row[0] for row in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
      "counts={name:db.execute('SELECT count(*) FROM '+name).fetchone()[0] for name in ('encrypted_records','pending_operations') if name in tables}",
      "print(json.dumps({'integrityCheck':db.execute('PRAGMA integrity_check').fetchone()[0],'tableCounts':counts},separators=(',',':')))",
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshotPath], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 2048,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) {
      return { available: false, reason: 'sqlite-count-query-failed' };
    }
    return {
      available: true,
      ...JSON.parse(result.stdout),
      databaseName: 'atermius_vault',
      sourceStores: ['files', 'blocks'],
      databaseFileLength: databaseFile.length,
      databaseBlockCount: databaseFile.blocks.length,
      journalFileLength: journalFile?.length ?? 0,
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function waitForIndexedDbOutboxState(pageRef, operation, state, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let lastReason = 'IndexedDB snapshot unavailable';
  let lastDetails = null;
  while (Date.now() < deadline) {
    try {
      const stored = await readClientDatabaseFromIndexedDb(pageRef);
      if (stored?.available) {
        const snapshot = inspectClientOutboxFiles(
          stored.sqliteFiles, operation, PRIMARY_PLAINTEXT_MARKERS);
        lastDetails = snapshot ? {
          unavailableReason: snapshot.unavailableReason,
          integrityCheck: snapshot.integrityCheck,
          pendingCount: snapshot.pendingCount,
          pending: snapshot.pending,
          recordOperationCount: snapshot.recordOperationCount,
          vaultOperationCount: snapshot.vaultOperationCount,
          record: snapshot.record,
          plaintextMarkerFound: snapshot.plaintextMarkerFound,
          databaseFileLength: snapshot.databaseFileLength,
          databaseBlockCount: snapshot.databaseBlockCount,
        } : { sqliteSnapshot: 'unreadable' };
        const matchingRecord = snapshot?.record?.revisionId === operation.revisionId &&
          snapshot.record.envelopeSha256 === operation.envelopeSha256 &&
          !snapshot.record.isDeleted;
        const expectedBaseRevisionId = operation.baseRevisionId ?? null;
        const expectedBaseEnvelopePresent = operation.baseEnvelopePresent ??
          expectedBaseRevisionId !== null;
        const expectedCachedCommitSeq = operation.expectedCachedCommitSeq ?? null;
        if (state === 'pending') {
          if (snapshot?.integrityCheck === 'ok' && snapshot.pendingCount === 1 &&
              snapshot.vaultOperationCount === 1 &&
              snapshot.pending?.opId === operation.opId &&
              snapshot.pending.vaultId === operation.vaultId &&
              snapshot.pending.recordId === operation.recordId &&
              snapshot.pending.baseRevisionId === expectedBaseRevisionId &&
              snapshot.pending.baseEnvelopePresent === expectedBaseEnvelopePresent &&
              (operation.baseEnvelopeSha256 === undefined ||
                snapshot.pending.baseEnvelopeSha256 === operation.baseEnvelopeSha256) &&
              snapshot.pending.envelopeSha256 === operation.envelopeSha256 &&
              ['queued', 'sent'].includes(snapshot.pending.status) &&
              snapshot.recordOperationCount === 1 && matchingRecord &&
              snapshot.record.commitSeq === expectedCachedCommitSeq &&
              snapshot.plaintextMarkerFound === false) {
            return { ...snapshot, indexedDb: {
              databaseName: stored.databaseName,
              objectStoreNames: stored.objectStoreNames,
              sqlitePath: '/database',
              databaseFileLength: snapshot.databaseFileLength,
              databaseBlockCount: snapshot.databaseBlockCount,
            } };
          }
          lastReason = snapshot?.pendingCount === 1
            ? `pending-${snapshot.pending?.status || 'row-mismatch'}`
            : `pending-count-${snapshot?.pendingCount ?? 'unavailable'}`;
        } else if (state === 'committed' && snapshot?.integrityCheck === 'ok' &&
            snapshot.pendingCount === 0 && snapshot.recordOperationCount === 0 &&
            snapshot.vaultOperationCount === 0 &&
            matchingRecord && snapshot.record.commitSeq === operation.receipt?.commitSeq &&
            snapshot.plaintextMarkerFound === false) {
          return { ...snapshot, indexedDb: {
            databaseName: stored.databaseName,
            objectStoreNames: stored.objectStoreNames,
            sqlitePath: '/database',
            databaseFileLength: snapshot.databaseFileLength,
            databaseBlockCount: snapshot.databaseBlockCount,
          } };
        } else {
          lastReason = `snapshot-integrity-${snapshot?.integrityCheck || 'unavailable'}`;
        }
      } else {
        lastReason = stored?.reason || 'IndexedDB snapshot unavailable';
      }
    } catch (_) {
      lastReason = 'IndexedDB snapshot read failed';
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`actual IndexedDB outbox did not reach ${state} state: ${JSON.stringify({
    reason: lastReason,
    ...lastDetails,
  })}`);
}

async function waitForIdbProbeEvent(pageRef, type, timeoutMs = 15000) {
  try {
    return await pageRef.evaluate(async ({ expectedType, waitMs }) => {
      const probe = window.__atermiusIdbWriteFailureProbe;
      if (!probe) throw new Error('IndexedDB test probe was not installed');
      return probe.waitFor(expectedType, waitMs);
    }, { expectedType: type, waitMs: timeoutMs });
  } catch (error) {
    const probe = await pageRef.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null,
    ).catch(() => []);
    const eventTypes = probe?.recentTypes || [];
    const evaluationErrorClass = /^[A-Za-z]+$/.test(error?.name || '')
      ? error.name : 'Error';
    console.error('IndexedDB probe safe diagnostic', JSON.stringify({
      expectedEvent: type,
      evaluationErrorClass,
      workerRouteHits: idbWorkerRouteCount,
      driftWebImplementation: driftImplementation || null,
      probeEventCounts: probe?.counts || {},
      probeEventSequence: eventTypes,
    }));
    throw new Error(`IndexedDB test probe event missing: ${type}; evaluation=${evaluationErrorClass}; observed=${eventTypes.join(',')}`);
  }
}

async function waitForIdbProbeCount(pageRef, type, minimumCount, timeoutMs = 10000) {
  await waitForCondition(async () => {
    const summary = await pageRef.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null,
    ).catch(() => null);
    return (summary?.counts?.[type] || 0) >= minimumCount;
  }, `IndexedDB probe count ${type} >= ${minimumCount}`, timeoutMs, pageRef);
}

async function waitForIdbProbeAnyEvent(pageRef, types, timeoutMs = 10000) {
  let observed;
  await waitForCondition(async () => {
    const counts = await pageRef.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe?.eventSummary?.()?.counts || {},
    ).catch(() => ({}));
    observed = types.find((type) => (counts[type] || 0) > 0);
    return observed;
  }, 'cross-tab Drift query response after IndexedDB abort', timeoutMs, pageRef);
  return observed;
}

async function visiblePersistenceFailure(pageRef, expectedHostName) {
  return pageRef.evaluate((hostName) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
    };
    const nodes = [...document.querySelectorAll('flt-semantics,[role="alert"],[aria-live]')]
      .filter(visible);
    const labels = nodes.map((element) => ({
      text: `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
        .replace(/\s+/g, ' ').trim(),
      alertScoped: element.getAttribute('role') === 'alert' ||
        Boolean(element.getAttribute('aria-live')),
    }));
    const categories = [...new Set(labels.flatMap(({ text }) => {
      const found = [];
      if (/本地存储状态需要恢复/.test(text)) found.push('recovery-required');
      if (/error|failed|exception/i.test(text)) found.push('error');
      if (/abort/i.test(text)) found.push('abort');
      if (/database|indexed.?db/i.test(text)) found.push('database');
      if (/storage/i.test(text)) found.push('storage');
      if (/quota/i.test(text)) found.push('quota');
      if (/transaction/i.test(text)) found.push('transaction');
      return found;
    }))].sort();
    const alertErrorCount = labels.filter(({ text, alertScoped }) => alertScoped &&
      /error|failed|abort|storage|database|quota|transaction|exception/i.test(text)).length;
    const errorSemanticCount = labels.filter(({ text }) =>
      /error|failed|abort|storage|database|quota|transaction|exception/i.test(text)).length;
    const text = (document.body.innerText || '').replace(/\s+/g, ' ');
    const recoveryRequiredVisible =
      text.includes('本地存储状态需要恢复') &&
      text.includes('关闭所有 Atermius 标签页');
    return {
      surfaced: alertErrorCount > 0 || errorSemanticCount > 0 ||
        recoveryRequiredVisible,
      alertErrorCount,
      errorSemanticCount,
      categories,
      hostEditorStillVisible: text.includes('Hostname or IP'),
      hostNameVisible: text.includes(hostName),
      saveSuccessNoticeVisible: text.includes('主机已在本地加密保存，等待同步。'),
      recoveryRequiredVisible,
      retryActionVisible: recoveryRequiredVisible ||
        [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .some((element) => /Add host|Add your first host/.test(
          `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)),
    };
  }, expectedHostName);
}

async function waitForSyncControlSettle(pageRef, timeoutMs = 5000) {
  const startedAt = Date.now();
  let state;
  let previousStateKey;
  let stableSamples = 0;
  do {
    state = await pageRef.evaluate(() => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0;
      };
      const candidate = [...document.querySelectorAll(
        'button,[role="button"]',
      )].find((element) => {
        const label = `${element.getAttribute('aria-label') || ''} ${
          element.innerText || element.textContent || ''}`.replace(/\s+/g, ' ').trim();
        return /Sync now|Syncing|Recovery required/.test(label) && visible(element);
      });
      if (!candidate) {
        return { visible: false, enabled: false, label: 'missing' };
      }
      const rawLabel = `${candidate.getAttribute('aria-label') || ''} ${
        candidate.innerText || candidate.textContent || ''}`.replace(/\s+/g, ' ').trim();
      return {
        visible: true,
        enabled: candidate.getAttribute('aria-disabled') !== 'true' &&
          !candidate.hasAttribute('disabled'),
        label: /Recovery required/.test(rawLabel) && /Syncing/.test(rawLabel)
          ? 'recovery-syncing' :
          /Recovery required/.test(rawLabel) ? 'recovery-required' :
          /Syncing/.test(rawLabel) ? 'syncing' :
          /Sync now/.test(rawLabel) ? 'sync-now' : 'other',
      };
    }).catch(() => ({ visible: false, enabled: false, label: 'unavailable' }));
    const stateKey = `${state.label}:${state.visible}:${state.enabled}`;
    if (!['syncing', 'recovery-syncing'].includes(state.label) &&
        stateKey === previousStateKey) {
      stableSamples += 1;
      if (stableSamples >= 2) break;
    } else {
      stableSamples = 0;
    }
    previousStateKey = stateKey;
    await pageRef.waitForTimeout(150);
  } while (Date.now() - startedAt < timeoutMs);
  return {
    ...state,
    settled: !['syncing', 'recovery-syncing'].includes(state.label) &&
      stableSamples >= 2,
    stableSamples,
    waitMs: Math.min(Date.now() - startedAt, timeoutMs),
  };
}

async function waitForQuarantineRequestCountsSettle(
  pageRef,
  pushBaseline,
  timeoutMs = 4000,
) {
  const startedAt = Date.now();
  let previousKey;
  let stableSamples = 0;
  let state = { databaseRequestsAfterAbort: null, pushRequestsAfterBaseline: null };
  do {
    const databaseRequestsAfterAbort = await pageRef.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe?.eventSummary?.()?.counts?.[
        'drift-database-request-after-abort-observed'] || 0,
    ).catch(() => null);
    state = {
      databaseRequestsAfterAbort,
      pushRequestsAfterBaseline: idbFailureAllPushRequests - pushBaseline,
    };
    const key = `${state.databaseRequestsAfterAbort}:${state.pushRequestsAfterBaseline}`;
    if (key === previousKey) {
      stableSamples += 1;
      if (stableSamples >= 3) break;
    } else {
      stableSamples = 0;
    }
    previousKey = key;
    await pageRef.waitForTimeout(150);
  } while (Date.now() - startedAt < timeoutMs);
  return {
    ...state,
    settled: stableSamples >= 3,
    stableSamples,
    waitMs: Math.min(Date.now() - startedAt, timeoutMs),
  };
}

function summarizeInboundChangesPage(body, operations) {
  const events = Array.isArray(body?.events) ? body.events : [];
  const matched = operations.map((operation) => {
    const matches = events.filter((event) => {
      const summary = envelopeSummary(event?.envelope, INBOUND_PLAINTEXT_MARKERS);
      return summary.opId === operation.opId &&
        summary.recordId === operation.recordId &&
        summary.revisionId === operation.revisionId &&
        summary.envelopeSha256 === operation.envelopeSha256;
    });
    if (matches.length !== 1) return null;
    const event = matches[0];
    const summary = envelopeSummary(event.envelope, INBOUND_PLAINTEXT_MARKERS);
    return {
      ...summary,
      commitSeq: String(event?.commit_seq ?? ''),
      eventType: event?.event_type,
    };
  });
  return {
    statusMatches: Array.isArray(body?.events),
    exactlyTwoEvents: events.length === 2 && matched.every(Boolean),
    noMorePages: body?.has_more === false,
    nextCursor: typeof body?.next_cursor === 'string' ? body.next_cursor : null,
    serverGeneration: typeof body?.server_generation === 'string'
      ? body.server_generation : null,
    events: matched,
  };
}

async function enterHostForm(
  pageRef, hostName = HOST_NAME,
  { address = HOST_ADDRESS, username = HOST_USERNAME } = {},
) {
  await click(pageRef, 'Add host');
  await waitForSemanticText(pageRef, 'Add a host');
  await fill(pageRef, 'Display name', hostName);
  await fill(pageRef, 'Hostname or IP', address);
  await fill(pageRef, 'Port', '22');
  await fill(pageRef, 'SSH username', username);
}

function verifyInboundProducerServerSnapshot(operation, finalCommitSeq) {
  const baselineCommitSeq = (BigInt(finalCommitSeq) - 1n).toString();
  const snapshot = serverRecordSnapshot(
    operation, baselineCommitSeq, INBOUND_PLAINTEXT_MARKERS);
  const matches = snapshot.versionCount === 1 && snapshot.versionMatches &&
    snapshot.versionOperation === 'create' &&
    snapshot.versionCommitSeq === operation.receipt.commitSeq &&
    snapshot.eventCount === 1 && snapshot.eventMatches &&
    snapshot.eventCommitSeq === operation.receipt.commitSeq &&
    snapshot.eventEnvelopeHash === operation.envelopeSha256 &&
    snapshot.receiptCount === 1 && snapshot.receiptMatches &&
    snapshot.receiptCommitSeq === operation.receipt.commitSeq &&
    snapshot.headMatches && !snapshot.headDeleted &&
    snapshot.headCommitSeq === operation.receipt.commitSeq &&
    snapshot.commitSeq === finalCommitSeq &&
    snapshot.expectedCommitSeq === finalCommitSeq &&
    snapshot.envelopeHash === operation.envelopeSha256 &&
    snapshot.opaqueEnvelope && !snapshot.plaintextMarkerFound &&
    !snapshot.serverPlaintextMarkerFound;
  if (!matches) {
    console.log('inbound producer server record mismatch safe diagnostic',
      JSON.stringify({
        operationCommitSeq: operation.receipt.commitSeq,
        expectedVaultCommitSeq: finalCommitSeq,
        snapshot,
      }));
  }
  assertThat(matches,
  'producer server snapshot did not show exactly one opaque encrypted event');
  return snapshot;
}

function checkpointMatchesRaceBoundary(snapshot, expected) {
  if (expected == null) {
    return snapshot.checkpointRowCount === 0 ||
      (snapshot.checkpointRowCount === 1 &&
        snapshot.checkpoint?.cursor == null &&
        snapshot.checkpoint?.serverGeneration == null);
  }
  return snapshot.checkpointRowCount === 1 &&
    snapshot.checkpoint?.cursor === expected.cursor &&
    snapshot.checkpoint?.serverGeneration === expected.serverGeneration;
}

function inboundRaceLocalPending(snapshot, expected = null) {
  if (!Array.isArray(snapshot?.pendingOperations) ||
      snapshot.pendingOperations.length !== 1) return null;
  const operation = snapshot.pendingOperations[0];
  if (operation.operation !== 'create' ||
      !['queued', 'sent'].includes(operation.status) ||
      operation.cacheRowCount !== 1 ||
      operation.cacheRevisionId !== operation.revisionId ||
      operation.cacheEnvelopeSha256 !== operation.envelopeSha256 ||
      operation.cacheCommitSeq !== null || operation.cacheDeleted !== false) {
    return null;
  }
  const expectedBaseRevisionId = expected?.rowBaseRevisionId ??
    expected?.baseRevisionId ?? null;
  if (expected && (operation.opId !== expected.opId ||
      operation.recordId !== expected.recordId ||
      operation.revisionId !== expected.revisionId ||
      operation.envelopeSha256 !== expected.envelopeSha256 ||
      operation.rowBaseRevisionId !== expectedBaseRevisionId ||
      operation.headerBaseRevisionId !== expectedBaseRevisionId)) {
    return null;
  }
  return operation;
}

function sameInboundRaceOperation(left, right) {
  return Boolean(left && right &&
    left.opId === right.opId &&
    left.recordId === right.recordId &&
    left.revisionId === right.revisionId &&
    left.rowBaseRevisionId === right.rowBaseRevisionId &&
    left.headerBaseRevisionId === right.headerBaseRevisionId &&
    left.operation === right.operation &&
    left.envelopeSha256 === right.envelopeSha256 &&
    left.cacheRowCount === right.cacheRowCount &&
    left.cacheRevisionId === right.cacheRevisionId &&
    left.cacheEnvelopeSha256 === right.cacheEnvelopeSha256 &&
    left.cacheCommitSeq === right.cacheCommitSeq &&
    left.cacheDeleted === right.cacheDeleted);
}

async function runInboundOutboxCheckpointRaceAfterProducer({
  initialVault,
  oldCursor,
  baselineCommitSeq,
}) {
  setStage('wait for the two-event changes page to be fetched and held before application');
  await waitForCondition(() => inboundOutboxRacePageEvidence !== undefined,
    'receiver did not hold the fetched inbound changes page', 30000, page);
  assertThat(!inboundOutboxRacePageEvidence.failure &&
    inboundOutboxRacePageEvidence.requestCursor === oldCursor &&
    inboundOutboxRacePageEvidence.exactlyTwoEvents &&
    inboundOutboxRacePageEvidence.noMorePages &&
    inboundOutboxRacePageEvidence.nextCursor &&
    inboundOutboxRacePageEvidence.serverGeneration &&
    inboundOutboxRacePageEvidence.events?.[0]?.commitSeq ===
      (BigInt(baselineCommitSeq) + 1n).toString() &&
    inboundOutboxRacePageEvidence.events?.[1]?.commitSeq ===
      (BigInt(baselineCommitSeq) + 2n).toString(),
  'held inbound page did not match the old cursor and exact remote events');

  inboundOutboxRacePhase = 'pre-restart';
  setStage('save a separate local Host while the inbound page response is held');
  await click(page, 'Hosts');
  await enterHostForm(page, INBOUND_RACE_HOST.name, {
    address: INBOUND_RACE_HOST.address,
    username: INBOUND_RACE_HOST.username,
  });
  await click(page, 'Save encrypted host');
  await waitForSemanticText(page, INBOUND_RACE_HOST.name);
  await waitForPendingCount(page, 1, 20000);
  let beforePageRelease;
  await waitForCondition(async () => {
    beforePageRelease = await snapshotClientInboundOutboxRace(
      page, initialVault.vaultId);
    const operation = inboundRaceLocalPending(beforePageRelease);
    return beforePageRelease.available &&
      beforePageRelease.integrityCheck === 'ok' &&
      checkpointMatchesRaceBoundary(beforePageRelease, inboundOldCheckpoint) &&
      operation !== null &&
      !beforePageRelease.plaintextMarkerFound;
  }, 'durable local outbox row before inbound page release', 20000, page);
  const localBefore = inboundRaceLocalPending(beforePageRelease);
  assertThat(localBefore?.operation === 'create' &&
    localBefore.recordId && localBefore.opId && localBefore.revisionId &&
    localBefore.envelopeSha256 && localBefore.cacheCommitSeq === null,
  'local Host was not present as one opaque durable create operation');
  console.log('inbound/outbox race pre-page evidence', JSON.stringify({
    checkpointUnchanged: checkpointMatchesRaceBoundary(
      beforePageRelease, inboundOldCheckpoint),
    pendingOperationCount: beforePageRelease.pendingOperations.length,
    localOperationDurable: true,
    localEnvelopeMatchesCache: localBefore.cacheEnvelopeSha256 ===
      localBefore.envelopeSha256,
    sqliteIntegrity: beforePageRelease.integrityCheck,
    plaintextMarkersAbsent: !beforePageRelease.plaintextMarkerFound,
  }));

  setStage('release the inbound changes page after the local outbox is durable');
  inboundOutboxRacePageRelease.resolve();
  await waitForCondition(() => inboundPreCrashPageEvidence !== undefined,
    'held changes page was not delivered to the receiver', 15000, page);
  assertThat(!inboundPreCrashPageEvidence.failure &&
    inboundPreCrashPageEvidence.requestCursor === oldCursor &&
    inboundPreCrashPageEvidence.nextCursor ===
      inboundOutboxRacePageEvidence.nextCursor,
  'released inbound page changed its validated cursor boundary');

  setStage('wait for the receiver to reach its first local push after page CAS');
  await waitForCondition(() => inboundOutboxRacePushOperation !== undefined,
    'receiver did not attempt the retained local outbox operation', 30000, page);
  assertThat(inboundOutboxRacePushRequestCount >= 1 &&
    inboundOutboxRacePushOperation.operation === 'create' &&
    inboundOutboxRacePushOperation.vaultId === initialVault.vaultId &&
    inboundOutboxRacePushOperation.recordId === localBefore.recordId &&
    inboundOutboxRacePushOperation.opId === localBefore.opId &&
    inboundOutboxRacePushOperation.revisionId === localBefore.revisionId &&
    inboundOutboxRacePushOperation.envelopeSha256 ===
      localBefore.envelopeSha256 &&
    inboundOutboxRacePushOperation.markersAbsent,
  'receiver push request changed or reordered the captured local operation');
  const pageBoundary = {
    cursor: inboundOutboxRacePageEvidence.nextCursor,
    serverGeneration: inboundOutboxRacePageEvidence.serverGeneration,
  };

  setStage('inspect actual SQLite after inbound page CAS while push remains blocked');
  let afterPageCas;
  await waitForCondition(async () => {
    afterPageCas = await snapshotClientInboundOutboxRace(
      page, initialVault.vaultId, inboundProducerOperations,
      localBefore.recordId);
    const localPending = inboundRaceLocalPending(afterPageCas, localBefore);
    return afterPageCas.available && afterPageCas.integrityCheck === 'ok' &&
      checkpointMatchesRaceBoundary(afterPageCas, pageBoundary) &&
      afterPageCas.remoteRecordsExactlyOnce && localPending !== null &&
      !afterPageCas.plaintextMarkerFound;
  }, 'page checkpoint and local outbox coexist in actual IndexedDB', 20000, page);
  const localAfterPage = inboundRaceLocalPending(afterPageCas, localBefore);
  const uncommittedServerLocal = serverRecordSnapshot(
    inboundOutboxRacePushOperation,
    (BigInt(baselineCommitSeq) + 2n).toString(),
    INBOUND_PLAINTEXT_MARKERS,
  );
  assertThat(localAfterPage !== null &&
    sameInboundRaceOperation(localAfterPage, localBefore) &&
    afterPageCas.localRecord?.rowCount === 1 &&
    afterPageCas.localRecord.revisionId === localBefore.revisionId &&
    afterPageCas.localRecord.envelopeSha256 === localBefore.envelopeSha256 &&
    afterPageCas.localRecord.commitSeq === null &&
    inboundOutboxRacePageEvidence.nextCursor !== oldCursor &&
    uncommittedServerLocal.versionCount === 0 &&
    uncommittedServerLocal.eventCount === 0 &&
    uncommittedServerLocal.receiptCount === 0 &&
    uncommittedServerLocal.headMatches === false &&
    uncommittedServerLocal.commitSeq ===
      (BigInt(baselineCommitSeq) + 2n).toString(),
  'checkpoint CAS erased, changed, or committed the pending local outbox operation');
  console.log('inbound/outbox race after-page-CAS evidence', JSON.stringify({
    checkpointMatchesPage: checkpointMatchesRaceBoundary(afterPageCas, pageBoundary),
    remoteRecordsExactlyOnce: afterPageCas.remoteRecordsExactlyOnce,
    localOutboxPreserved: true,
    localEnvelopeMatchesCache: true,
    localServerReceiptAbsent: uncommittedServerLocal.receiptCount === 0,
    sqliteIntegrity: afterPageCas.integrityCheck,
    plaintextMarkersAbsent: !afterPageCas.plaintextMarkerFound,
  }));

  setStage('abort the first pre-restart push without contacting the server');
  inboundOutboxRacePushRelease.resolve();
  await waitForCondition(() => inboundOutboxRacePushAbortCount >= 1,
    'first local outbox request was not aborted before server commit', 10000, page);
  await page.waitForTimeout(750);
  const beforeCrash = await snapshotClientInboundOutboxRace(
    page, initialVault.vaultId, inboundProducerOperations,
    localBefore.recordId);
  const localBeforeCrash = inboundRaceLocalPending(beforeCrash, localBefore);
  assertThat(beforeCrash.available && beforeCrash.integrityCheck === 'ok' &&
    checkpointMatchesRaceBoundary(beforeCrash, pageBoundary) &&
    beforeCrash.remoteRecordsExactlyOnce && localBeforeCrash !== null &&
    beforeCrash.localRecord?.envelopeSha256 === localBefore.envelopeSha256 &&
    beforeCrash.localRecord?.commitSeq === null &&
    !beforeCrash.plaintextMarkerFound &&
    inboundOutboxRacePushRequestCount === inboundOutboxRacePushAbortCount &&
    serverVaultSnapshot().commitSeq ===
      (BigInt(baselineCommitSeq) + 2n).toString(),
  'pre-restart blocked push changed the durable cursor, local operation, or server ledger');
  const deviceStorageBeforeCrash = await safeBrowserStorageDiagnostic(page);
  assertThat(deviceStorageBeforeCrash.deviceRecordPresent,
    'receiver device identity was absent before same-profile restart');

  setStage('SIGKILL receiver Chromium with inbound cursor advanced and local outbox pending');
  const killedIdentity = chromiumProfileProcessIdentity(profileDir);
  const killedProcessGroup = await forceKillChromiumProfile(profileDir);
  assertThat(killedProcessGroup === killedIdentity.processGroup,
    'hard termination targeted a different outbox-race Chromium process group');
  browserContext = undefined;
  page = undefined;
  inboundChangesRoutePhase = 'outbox-race-restart';
  inboundOutboxRacePhase = 'post-restart';

  setStage('reopen the same profile and resume from the saved inbound page boundary');
  await launchPersistentChromium();
  const relaunchedIdentity = chromiumProfileProcessIdentity(profileDir);
  assertThat(relaunchedIdentity.pid !== killedIdentity.pid ||
    relaunchedIdentity.startTimeTicks !== killedIdentity.startTimeTicks,
  'same-profile receiver restart reused the terminated browser process identity');
  await initializeFlutter(page);
  await recoverWorkspace(page);
  await waitForCondition(() => inboundOutboxRaceRestartPageEvidence !== undefined,
    'restarted receiver did not request changes from the saved page boundary',
    30000, page);
  assertThat(!inboundOutboxRaceRestartPageEvidence.failure &&
    inboundOutboxRaceRestartPageEvidence.requestCursor === pageBoundary.cursor &&
    inboundOutboxRaceRestartPageEvidence.eventCount === 0 &&
    inboundOutboxRaceRestartPageEvidence.serverGeneration ===
      pageBoundary.serverGeneration &&
    serverVaultSnapshot().commitSeq ===
      (BigInt(baselineCommitSeq) + 2n).toString(),
  'restart did not preserve the checkpoint after the two remote events');

  setStage('hold the successful restart push response for durable outbox inspection');
  await waitForCondition(() => inboundOutboxRacePushReceipt !== undefined,
    'same-profile restart did not commit its retained local outbox operation',
    30000, page);
  assertThat(inboundOutboxRaceRestartPushCount === 1 &&
    inboundOutboxRacePushReceipt.opId === localBefore.opId &&
    inboundOutboxRacePushReceipt.revisionId === localBefore.revisionId &&
    inboundOutboxRacePushReceipt.commitSeq ===
      (BigInt(baselineCommitSeq) + 3n).toString() &&
    inboundOutboxRacePushReceipt.alreadyCommitted === false,
  'restart push did not commit the original operation exactly once');
  const localServerAfterPush = serverRecordSnapshot(
    inboundOutboxRacePushOperation,
    (BigInt(baselineCommitSeq) + 2n).toString(),
    INBOUND_PLAINTEXT_MARKERS,
  );
  let afterRestartServerCommit;
  await waitForCondition(async () => {
    afterRestartServerCommit = await snapshotClientInboundOutboxRace(
      page, initialVault.vaultId, inboundProducerOperations,
      localBefore.recordId);
    const localPending = inboundRaceLocalPending(afterRestartServerCommit, localBefore);
    return afterRestartServerCommit.available &&
      afterRestartServerCommit.integrityCheck === 'ok' &&
      checkpointMatchesRaceBoundary(afterRestartServerCommit,
        { cursor: inboundOutboxRaceRestartPageEvidence.nextCursor,
          serverGeneration: inboundOutboxRaceRestartPageEvidence.serverGeneration }) &&
      afterRestartServerCommit.remoteRecordsExactlyOnce &&
      localPending !== null && !afterRestartServerCommit.plaintextMarkerFound;
  }, 'restart request retains local outbox until its receipt is acknowledged', 20000, page);
  assertThat(localServerAfterPush.versionCount === 1 &&
    localServerAfterPush.versionMatches &&
    localServerAfterPush.versionCommitSeq === inboundOutboxRacePushReceipt.commitSeq &&
    localServerAfterPush.eventCount === 1 && localServerAfterPush.eventMatches &&
    localServerAfterPush.receiptCount === 1 && localServerAfterPush.receiptMatches &&
    localServerAfterPush.headMatches &&
    localServerAfterPush.commitSeq ===
      (BigInt(baselineCommitSeq) + 3n).toString() &&
    localServerAfterPush.envelopeHash === localBefore.envelopeSha256 &&
    !localServerAfterPush.plaintextMarkerFound &&
    !localServerAfterPush.serverPlaintextMarkerFound &&
    inboundRaceLocalPending(afterRestartServerCommit, localBefore) !== null,
  'successful restart commit was not exactly one while the local outbox remained durable');

  inboundChangesRoutePhase = 'outbox-race-own-event';
  inboundOutboxRacePushResponseRelease.resolve();
  setStage('wait for the acknowledged local operation to clear from the outbox');
  await waitForPendingCount(page, 0, 30000);
  await waitForCondition(async () => {
    afterRestartServerCommit = await snapshotClientInboundOutboxRace(
      page, initialVault.vaultId, inboundProducerOperations,
      localBefore.recordId);
    return afterRestartServerCommit.available &&
      afterRestartServerCommit.integrityCheck === 'ok' &&
      afterRestartServerCommit.pendingOperations.length === 0 &&
      afterRestartServerCommit.localRecord?.rowCount === 1 &&
      afterRestartServerCommit.localRecord.revisionId === localBefore.revisionId &&
      afterRestartServerCommit.localRecord.envelopeSha256 ===
        localBefore.envelopeSha256 &&
      afterRestartServerCommit.localRecord.commitSeq ===
        inboundOutboxRacePushReceipt.commitSeq &&
      !afterRestartServerCommit.plaintextMarkerFound;
  }, 'receipt acknowledgement clears exactly the local outbox while retaining its cache',
  20000, page);

  setStage('sync the local operation event back through the changes feed');
  if (inboundOutboxRaceOwnEventPageEvidence === undefined) {
    await clickSyncNow(page);
  }
  await waitForCondition(() => inboundOutboxRaceOwnEventPageEvidence !== undefined,
    'local operation event was not observed on a subsequent changes page', 30000, page);
  assertThat(!inboundOutboxRaceOwnEventPageEvidence.failure &&
    inboundOutboxRaceOwnEventPageEvidence.requestCursor ===
      inboundOutboxRaceRestartPageEvidence.nextCursor &&
    inboundOutboxRaceOwnEventPageEvidence.eventCount === 1 &&
    inboundOutboxRaceOwnEventPageEvidence.matchingEventCount === 1 &&
    inboundOutboxRaceOwnEventPageEvidence.eventCommitSeq ===
      inboundOutboxRacePushReceipt.commitSeq,
  'subsequent sync did not replay exactly the local operation event');
  const finalCheckpoint = {
    cursor: inboundOutboxRaceOwnEventPageEvidence.nextCursor,
    serverGeneration: inboundOutboxRaceOwnEventPageEvidence.serverGeneration,
  };
  await waitForCondition(async () => {
    afterRestartServerCommit = await snapshotClientInboundOutboxRace(
      page, initialVault.vaultId, inboundProducerOperations,
      localBefore.recordId);
    return afterRestartServerCommit.available &&
      afterRestartServerCommit.integrityCheck === 'ok' &&
      checkpointMatchesRaceBoundary(afterRestartServerCommit, finalCheckpoint) &&
      afterRestartServerCommit.remoteRecordsExactlyOnce &&
      afterRestartServerCommit.pendingOperations.length === 0 &&
      afterRestartServerCommit.localRecord?.rowCount === 1 &&
      afterRestartServerCommit.localRecord.revisionId === localBefore.revisionId &&
      afterRestartServerCommit.localRecord.envelopeSha256 ===
        localBefore.envelopeSha256 &&
      afterRestartServerCommit.localRecord.commitSeq ===
        inboundOutboxRacePushReceipt.commitSeq &&
      !afterRestartServerCommit.plaintextMarkerFound;
  }, 'same-profile sync converges at the local event cursor without duplicates',
  20000, page);

  const finalServerRecords = inboundProducerOperations.map((operation) =>
    verifyInboundProducerServerSnapshot(
      operation, (BigInt(baselineCommitSeq) + 3n).toString()));
  const finalLocalServer = serverRecordSnapshot(
    inboundOutboxRacePushOperation,
    (BigInt(baselineCommitSeq) + 2n).toString(),
    INBOUND_PLAINTEXT_MARKERS,
  );
  assertThat(finalLocalServer.versionCount === 1 &&
    finalLocalServer.eventCount === 1 && finalLocalServer.receiptCount === 1 &&
    finalLocalServer.headMatches && finalLocalServer.commitSeq ===
      (BigInt(baselineCommitSeq) + 3n).toString() &&
    serverVaultSnapshot().commitSeq ===
      (BigInt(baselineCommitSeq) + 3n).toString() &&
    inboundOutboxRaceRestartPushCount === 1 && pageErrorCount === 0 &&
    trustedPageErrorCount === 0,
  'final server ledger or browser state did not converge exactly once');
  assertThat(finalServerRecords.every((snapshot) => snapshot.versionCount === 1 &&
    snapshot.eventCount === 1 && snapshot.receiptCount === 1),
  'remote producer records were duplicated or skipped during local outbox recovery');
  const storageAfterRestart = await safeBrowserStorageDiagnostic(page);
  assertThat(storageAfterRestart.deviceRecordPresent,
    'same-profile restart lost the original device identity');
  console.log('WEB-SYNC-OUTBOX-CHECKPOINT-RACE-01 evidence', JSON.stringify({
    receiverBackend: driftImplementation || null,
    localOutboxCreatedBeforePageApply: true,
    pageCursorAdvancedBeforePush: checkpointMatchesRaceBoundary(
      afterPageCas, pageBoundary),
    remoteRecordsExactlyOnce: afterRestartServerCommit.remoteRecordsExactlyOnce,
    preRestartPushAttemptsAborted: inboundOutboxRacePushAbortCount,
    preRestartLocalServerReceiptAbsent: uncommittedServerLocal.receiptCount === 0,
    sameProfileRestartUsedDurablePageBoundary:
      inboundOutboxRaceRestartPageEvidence.requestCursor === pageBoundary.cursor,
    restartPushCount: inboundOutboxRaceRestartPushCount,
    localReceiptAlreadyCommitted: inboundOutboxRacePushReceipt.alreadyCommitted,
    localOperationExactlyOnce: finalLocalServer.versionCount === 1 &&
      finalLocalServer.eventCount === 1 && finalLocalServer.receiptCount === 1,
    ownEventReplayExactlyOnce:
      inboundOutboxRaceOwnEventPageEvidence.matchingEventCount === 1,
    finalCheckpointMatchesOwnEventPage:
      checkpointMatchesRaceBoundary(afterRestartServerCommit, finalCheckpoint),
    sqliteIntegrity: afterRestartServerCommit.integrityCheck,
    plaintextMarkersAbsent: !afterRestartServerCommit.plaintextMarkerFound &&
      !finalLocalServer.serverPlaintextMarkerFound,
    originalDeviceIdentityPreserved: storageAfterRestart.deviceRecordPresent,
    serverCommitSeqBeforeAndAfter: {
      beforeLocalPush: String(BigInt(baselineCommitSeq) + 2n),
      final: serverVaultSnapshot().commitSeq,
    },
    cleanupExpected: true,
  }));
}

async function runInboundChangesCrashAcceptance(initialVault) {
  setStage('inspect the receiver IndexedDB SQLite checkpoint baseline');
  const baseline = await snapshotClientInboundChanges(
    page, initialVault.vaultId, [], null, 0);
  assertThat(baseline.available && baseline.integrityCheck === 'ok' &&
    baseline.checkpointRowCount <= 1 && baseline.pendingOperationCount === 0 &&
    baseline.pendingCountMatchesBaseline,
  'receiver IndexedDB baseline was not a clean SQLite database');
  inboundOldCheckpoint = baseline.checkpoint;
  inboundBaselinePendingCount = baseline.pendingOperationCount;
  const oldCursor = inboundOldCheckpoint?.cursor ?? null;
  const baselineCommitSeq = initialVault.commitSeq;

  setStage('confirm receiver SharedWorker completion probe is loaded');
  await waitForIdbProbeEvent(page, 'worker-route-loaded', 10000);
  await waitForIdbProbeEvent(page, 'drift-port-observer-installed', 10000);
  const initialProbe = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null);
  assertThat(initialProbe?.counts?.[
    'write-transaction-completion-probe-unavailable'] === undefined,
  'SharedWorker could not install the IndexedDB completion callback probe');

  setStage('capture two trusted-device encrypted Host commits');
  await trustedContext.route('**/api/v1/vaults/*/sync/push', async (route) => {
    inboundProducerPushRequestCount += 1;
    const captured = [];
    try {
      const body = route.request().postDataJSON();
      const envelopes = Array.isArray(body?.operations) ? body.operations : [];
      for (const envelope of envelopes) {
        const summary = envelopeSummary(envelope, INBOUND_PLAINTEXT_MARKERS);
        if (inboundCaptureProducerCreates && summary.operation === 'create') {
          captured.push({
            ...summary,
            vaultId: envelope?.header?.vault_id || body?.vault_id,
          });
        }
      }
      const upstream = await route.fetch();
      inboundProducerPushStatuses.push(upstream.status());
      const responseBody = await upstream.body();
      const result = JSON.parse(responseBody.toString('utf8'));
      const receipts = Array.isArray(result?.results) ? result.results : [];
      for (const operation of captured) {
        const receipt = receipts.find((candidate) =>
          candidate?.op_id === operation.opId &&
          candidate?.revision_id === operation.revisionId);
        if (upstream.status() === 200 && receipt) {
          const existing = inboundProducerOperations.find((candidate) =>
            candidate.opId === operation.opId);
          if (!existing) inboundProducerOperations.push({
            ...operation,
            receipt: {
              opId: receipt.op_id,
              revisionId: receipt.revision_id,
              commitSeq: String(receipt.commit_seq),
              alreadyCommitted: receipt.already_committed === true,
            },
          });
        }
      }
      await route.fulfill({ response: upstream, body: responseBody });
    } catch (_) {
      inboundProducerPushRouteFailureCount += 1;
      await route.abort('failed').catch(() => {});
    }
  });

  inboundChangesRoutePhase = 'pre-crash-wait-for-producer';
  inboundReceiverArmed = true;

  for (const fixture of INBOUND_HOST_FIXTURES) {
    const fixtureIndex = INBOUND_HOST_FIXTURES.indexOf(fixture) + 1;
    setStage(`trusted B: open inbound Host ${fixtureIndex} form`);
    await enterHostForm(trustedPage, fixture.name, {
      address: fixture.address,
      username: fixture.username,
    });
    inboundCaptureProducerCreates = true;
    setStage(`trusted B: save inbound Host ${fixtureIndex}`);
    await click(trustedPage, 'Save encrypted host');
    try {
      setStage(`trusted B: wait for inbound Host ${fixtureIndex} server receipt`);
      await waitForCondition(() => inboundProducerOperations.length >=
        fixtureIndex,
      'trusted Host create did not receive a server receipt', 45000, trustedPage);
    } catch (error) {
      const ui = await visiblePersistenceFailure(trustedPage, fixture.name)
        .catch(() => ({}));
      console.log('trusted producer safe diagnostic', JSON.stringify({
        producerPushRequests: inboundProducerPushRequestCount,
        producerRouteFailures: inboundProducerPushRouteFailureCount,
        producerPushStatuses: inboundProducerPushStatuses,
        capturedReceipts: inboundProducerOperations.length,
        serverCommitSeq: serverVaultSnapshot().commitSeq,
        hostVisible: ui.hostNameVisible === true,
        saveSuccessNoticeVisible: ui.saveSuccessNoticeVisible === true,
        recoveryRequiredVisible: ui.recoveryRequiredVisible === true,
        errorCategories: ui.categories || [],
      }));
      throw error;
    } finally {
      inboundCaptureProducerCreates = false;
    }
  }
  assertThat(inboundProducerOperations.length === 2 &&
    inboundProducerOperations.every((operation) =>
      operation.vaultId === initialVault.vaultId &&
      operation.exactEnvelopeShape && operation.ciphertextOnlyHeader &&
      operation.encodedCiphertextFields && operation.markersAbsent &&
      operation.receipt.opId === operation.opId &&
      operation.receipt.revisionId === operation.revisionId &&
      !operation.receipt.alreadyCommitted),
  'trusted producer did not create two opaque encrypted records');
  inboundProducerOperations.sort((left, right) =>
    BigInt(left.receipt.commitSeq) < BigInt(right.receipt.commitSeq) ? -1 : 1);
  assertThat(inboundProducerOperations[0].receipt.commitSeq ===
      (BigInt(baselineCommitSeq) + 1n).toString() &&
    inboundProducerOperations[1].receipt.commitSeq ===
      (BigInt(baselineCommitSeq) + 2n).toString(),
  'trusted producer commits were not the next two Vault events');
  const serverBeforeCrash = inboundProducerOperations.map((operation) =>
    verifyInboundProducerServerSnapshot(
      operation,
      (BigInt(baselineCommitSeq) + 2n).toString(),
    ));
  assertThat(serverVaultSnapshot().commitSeq ===
    (BigInt(baselineCommitSeq) + 2n).toString(),
  'receiver fixture did not start from exactly two committed remote events');

  inboundProducerRelease.resolve();
  // Opening Sync & conflicts gives the test a deterministic way to start a
  // pull when background sync has not already issued the gated request.
  if (await trustedPage.getByRole('button', {
    name: 'Add host', exact: true,
  }).isVisible().catch(() => false)) {
    // Leave the producer profile idle after both commits.
  }
  if (await page.getByRole('button', {
    name: 'Sync & conflicts', exact: true,
  }).isVisible().catch(() => false)) {
    await click(page, 'Sync & conflicts');
    await waitForSemanticText(page, 'Sync health');
    const syncNow = await button(page, 'Sync now').catch(() => null);
    if (syncNow && await syncNow.isEnabled().catch(() => false)) {
      await click(page, 'Sync now');
    }
  }
  if (INBOUND_OUTBOX_CHECKPOINT_RACE) {
    await runInboundOutboxCheckpointRaceAfterProducer({
      initialVault,
      oldCursor,
      baselineCommitSeq,
    });
    return;
  }
  await waitForCondition(() => inboundPreCrashPageEvidence !== undefined,
    'receiver did not fetch the two gated changes events', 30000, page);
  assertThat(!inboundPreCrashPageEvidence.failure &&
    inboundPreCrashPageEvidence.requestCursor === oldCursor &&
    inboundPreCrashPageEvidence.exactlyTwoEvents &&
    inboundPreCrashPageEvidence.noMorePages,
  'pre-crash changes page did not use the old cursor and contain exactly two events');

  let heldCount = 0;
  let preCrashLocalSnapshot;
  let crashBoundaryFound = false;
  setStage('hold committed IndexedDB writes until both remote records and old cursor coexist');
  for (let candidate = 0; candidate < 32; candidate += 1) {
    await waitForIdbProbeCount(page,
      'write-transaction-completion-callback-held', heldCount + 1, 20000);
    await waitForIdbProbeCount(page,
      'write-transaction-durable-complete', heldCount + 1, 5000);
    heldCount += 1;
    preCrashLocalSnapshot = await snapshotClientInboundChanges(
      page,
      initialVault.vaultId,
      inboundProducerOperations,
      inboundOldCheckpoint,
      inboundBaselinePendingCount,
    );
    if (preCrashLocalSnapshot.available &&
        preCrashLocalSnapshot.integrityCheck === 'ok' &&
        preCrashLocalSnapshot.checkpointRowCount ===
          (inboundOldCheckpoint ? 1 : 0) &&
        preCrashLocalSnapshot.checkpointMatchesExpected &&
        preCrashLocalSnapshot.recordsExactlyOnce &&
        preCrashLocalSnapshot.pendingCountMatchesBaseline &&
        !preCrashLocalSnapshot.plaintextMarkerFound) {
      crashBoundaryFound = true;
      break;
    }
    await page.evaluate(() => {
      window.__atermiusIdbWriteFailureProbe
        .continueCommittedCompletion(true);
    });
  }
  assertThat(crashBoundaryFound,
    'could not hold a durable event-application commit with both records saved and the old cursor unchanged');
  await page.waitForTimeout(100);
  const stableBoundarySnapshot = await snapshotClientInboundChanges(
    page,
    initialVault.vaultId,
    inboundProducerOperations,
    inboundOldCheckpoint,
    inboundBaselinePendingCount,
  );
  assertThat(stableBoundarySnapshot.available &&
    stableBoundarySnapshot.integrityCheck === 'ok' &&
    stableBoundarySnapshot.checkpointRowCount ===
      (inboundOldCheckpoint ? 1 : 0) &&
    stableBoundarySnapshot.checkpointMatchesExpected &&
    stableBoundarySnapshot.recordsExactlyOnce &&
    stableBoundarySnapshot.pendingCountMatchesBaseline &&
    !stableBoundarySnapshot.plaintextMarkerFound,
  'receiver cursor advanced while the committed Drift completion callback was held');
  preCrashLocalSnapshot = stableBoundarySnapshot;
  inboundWorkerCompletionHolds = heldCount;
  console.log('inbound changes durable crash boundary', JSON.stringify({
    heldCommittedTransactions: heldCount,
    durableCompletionCallbackHeld: true,
    bothEncryptedRecordsExactlyOnce: preCrashLocalSnapshot.recordsExactlyOnce,
    oldCursorUnchanged: preCrashLocalSnapshot.checkpointMatchesExpected,
    sqliteIntegrityCheck: preCrashLocalSnapshot.integrityCheck,
    pendingCountUnchanged: preCrashLocalSnapshot.pendingCountMatchesBaseline,
    plaintextMarkersAbsent: !preCrashLocalSnapshot.plaintextMarkerFound,
  }));

  let checkpointFailureEvidence;
  if (INBOUND_CHECKPOINT_WRITE_FAILURE) {
    setStage('arm a one-shot fault for the next sync_checkpoints VFS write');
    const probeCountsBeforeFault = await page.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe?.eventSummary?.()?.counts || {},
    );
    const faultBaseline = {
      armed: probeCountsBeforeFault.armed || 0,
      checkpointWriteSql: probeCountsBeforeFault['checkpoint-write-sql-observed'] || 0,
      targeted: probeCountsBeforeFault['write-transaction-targeted'] || 0,
      abortRequested: probeCountsBeforeFault['write-transaction-abort-requested'] || 0,
      abortEvent: probeCountsBeforeFault['write-transaction-abort-event'] || 0,
      quarantineResponse: probeCountsBeforeFault[
        'drift-error-response-quarantine-marker'] || 0,
    };
    await page.evaluate(() => {
      window.__atermiusIdbWriteFailureProbe.arm({
        holdCommittedCallback: false,
        requireCheckpointWrite: true,
      });
    });
    await waitForIdbProbeCount(page, 'armed', faultBaseline.armed + 1, 5000);

    setStage('release the durable final event callback and abort the checkpoint write');
    await page.evaluate(() => {
      window.__atermiusIdbWriteFailureProbe.continueCommittedCompletion(false);
    });
    await waitForIdbProbeCount(page, 'checkpoint-write-sql-observed',
      faultBaseline.checkpointWriteSql + 1, 15000);
    await waitForIdbProbeCount(page, 'write-transaction-targeted',
      faultBaseline.targeted + 1, 15000);
    await waitForIdbProbeCount(page, 'write-transaction-abort-requested',
      faultBaseline.abortRequested + 1, 5000);
    await waitForIdbProbeCount(page, 'write-transaction-abort-event',
      faultBaseline.abortEvent + 1, 5000);
    await waitForIdbProbeCount(page, 'drift-error-response-quarantine-marker',
      faultBaseline.quarantineResponse + 1, 10000);
    inboundChangesRoutePhase = 'post-checkpoint-abort';

    const probeAfterFault = await page.evaluate(() =>
      window.__atermiusIdbWriteFailureProbe.eventSummary(),
    );
    const faultEventStart = probeAfterFault.recentTypes.lastIndexOf('armed');
    const faultEvents = probeAfterFault.recentTypes.slice(faultEventStart + 1);
    const eventIndex = (type) => faultEvents.indexOf(type);
    assertThat(faultEventStart >= 0 &&
      probeAfterFault.counts['checkpoint-write-sql-observed'] ===
        faultBaseline.checkpointWriteSql + 1 &&
      probeAfterFault.counts['write-transaction-targeted'] ===
        faultBaseline.targeted + 1 &&
      probeAfterFault.counts['write-transaction-abort-requested'] ===
        faultBaseline.abortRequested + 1 &&
      probeAfterFault.counts['write-transaction-abort-event'] ===
        faultBaseline.abortEvent + 1 &&
      probeAfterFault.counts['drift-error-response-quarantine-marker'] ===
        faultBaseline.quarantineResponse + 1 &&
      eventIndex('checkpoint-write-sql-observed') >= 0 &&
      eventIndex('write-transaction-targeted') >
        eventIndex('checkpoint-write-sql-observed') &&
      eventIndex('write-transaction-abort-requested') >
        eventIndex('write-transaction-targeted') &&
      eventIndex('write-transaction-abort-event') >
        eventIndex('write-transaction-abort-requested'),
    'checkpoint-write fault did not observe and abort exactly one checkpoint VFS transaction');

    setStage('confirm recovery-required state after checkpoint persistence abort');
    await waitForCondition(async () =>
      (await visiblePersistenceFailure(page, HOST_NAME)).recoveryRequiredVisible,
    'checkpoint write failure did not put the receiver into recovery-required state',
    10000, page);
    const afterCheckpointAbort = await snapshotClientInboundChanges(
      page,
      initialVault.vaultId,
      inboundProducerOperations,
      inboundOldCheckpoint,
      inboundBaselinePendingCount,
    );
    assertThat(afterCheckpointAbort.available &&
      afterCheckpointAbort.integrityCheck === 'ok' &&
      afterCheckpointAbort.checkpointRowCount ===
        (inboundOldCheckpoint ? 1 : 0) &&
      afterCheckpointAbort.checkpointMatchesExpected &&
      afterCheckpointAbort.recordsExactlyOnce &&
      afterCheckpointAbort.pendingCountMatchesBaseline &&
      !afterCheckpointAbort.plaintextMarkerFound &&
      inboundOwnerPushRequestCount === 0,
    'checkpoint abort changed the old cursor, durable event rows, pending outbox, or receiver push state');
    await page.waitForTimeout(750);
    assertThat(inboundPostFaultChangesRequestCount === 0 &&
      inboundOwnerPushRequestCount === 0,
    'receiver retried changes or attempted a push before the same-profile restart');
    checkpointFailureEvidence = {
      checkpointWriteSqlObserved: true,
      exactlyOneBlocksTransactionTargeted: true,
      exactlyOneBlocksTransactionAborted: true,
      recoveryRequiredVisible: true,
      oldCursorAndGenerationUnchanged:
        afterCheckpointAbort.checkpointMatchesExpected,
      localRecordsExactlyOnce: afterCheckpointAbort.recordsExactlyOnce,
      pendingOutboxUnchanged:
        afterCheckpointAbort.pendingCountMatchesBaseline,
      sqliteIntegrity: afterCheckpointAbort.integrityCheck,
      plaintextMarkersAbsent: !afterCheckpointAbort.plaintextMarkerFound,
      changesRequestsBeforeRestart: inboundPostFaultChangesRequestCount,
      receiverPushRequests: inboundOwnerPushRequestCount,
    };
    console.log('inbound checkpoint write fault boundary', JSON.stringify(
      checkpointFailureEvidence));
  }

  setStage(INBOUND_CHECKPOINT_WRITE_FAILURE
    ? 'SIGKILL receiver Chromium after checkpoint abort'
    : 'SIGKILL receiver Chromium at the committed changes page boundary');
  const killedBrowserIdentity = chromiumProfileProcessIdentity(profileDir);
  const killedProcessGroup = await forceKillChromiumProfile(profileDir);
  assertThat(killedProcessGroup === killedBrowserIdentity.processGroup,
    'hard termination targeted a different receiver Chromium process group');
  browserContext = undefined;
  page = undefined;

  setStage('reopen the same receiver profile and hold the first changes response');
  inboundChangesRoutePhase = 'restart-hold-page';
  inboundReplayResponseSignal = deferred();
  inboundReplayResponseRelease = deferred();
  inboundReplayEvidence = undefined;
  inboundReplayRequestCount = 0;
  inboundReplayFirstCursor = undefined;
  await launchPersistentChromium();
  const relaunchedIdentity = chromiumProfileProcessIdentity(profileDir);
  assertThat(relaunchedIdentity.pid !== killedBrowserIdentity.pid ||
    relaunchedIdentity.startTimeTicks !== killedBrowserIdentity.startTimeTicks,
  'receiver Chromium restart reused the terminated process identity');
  await initializeFlutter(page);
  await recoverWorkspace(page);
  await waitForIdbProbeEvent(page, 'worker-route-loaded', 10000);
  await waitForCondition(() => inboundReplayEvidence !== undefined,
    'restarted receiver did not request the old changes page', 30000, page);
  assertThat(!inboundReplayEvidence.failure &&
    inboundReplayEvidence.requestCursor === oldCursor &&
    inboundReplayRequestCount === 1 &&
    inboundReplayEvidence.exactlyTwoEvents &&
    inboundReplayEvidence.noMorePages,
  'first post-crash changes request did not replay the old cursor page exactly once');
  assertThat(inboundPreCrashPageEvidence.serverGeneration &&
    inboundReplayEvidence.serverGeneration ===
      inboundPreCrashPageEvidence.serverGeneration,
  'server generation changed between the original page and checkpoint replay');
  const beforeReplayRelease = await snapshotClientInboundChanges(
    page,
    initialVault.vaultId,
    inboundProducerOperations,
    inboundOldCheckpoint,
    inboundBaselinePendingCount,
  );
  assertThat(beforeReplayRelease.available &&
    beforeReplayRelease.integrityCheck === 'ok' &&
    beforeReplayRelease.checkpointRowCount ===
      (inboundOldCheckpoint ? 1 : 0) &&
    beforeReplayRelease.checkpointMatchesExpected &&
    beforeReplayRelease.recordsExactlyOnce &&
    beforeReplayRelease.pendingCountMatchesBaseline &&
    !beforeReplayRelease.plaintextMarkerFound,
  'restart changed the committed receiver snapshot before replay response release');
  inboundChangesRoutePhase = 'inactive';
  inboundReplayResponseRelease.resolve();

  setStage('verify replay projects both records and advances the checkpoint once');
  await click(page, 'Hosts');
  await waitForCondition(() => page.evaluate((names) => {
    const renderedText = [document.body.innerText || '',
      ...[...document.querySelectorAll('flt-semantics')].flatMap((node) => [
        node.innerText || '', node.getAttribute('aria-label') || '',
      ])].join('\n');
    return names.every((name) => renderedText.includes(name));
  }, INBOUND_HOST_FIXTURES.map((fixture) => fixture.name)),
  'replayed remote Host records were not projected into the workspace', 30000, page);
  const expectedCheckpoint = {
    cursor: inboundReplayEvidence.nextCursor,
    serverGeneration: inboundReplayEvidence.serverGeneration,
  };
  let afterReplay;
  await waitForCondition(async () => {
    afterReplay = await snapshotClientInboundChanges(
      page,
      initialVault.vaultId,
      inboundProducerOperations,
      expectedCheckpoint,
      inboundBaselinePendingCount,
    );
    return afterReplay.available && afterReplay.integrityCheck === 'ok' &&
      afterReplay.checkpointRowCount === 1 &&
      afterReplay.checkpointMatchesExpected &&
      afterReplay.recordsExactlyOnce &&
      afterReplay.pendingCountMatchesBaseline &&
      !afterReplay.plaintextMarkerFound;
  }, 'durable replay checkpoint at the page boundary', 30000, page);
  console.log('inbound replay durable checkpoint evidence', JSON.stringify({
    checkpointRowCount: afterReplay.checkpointRowCount,
    checkpointMatchesResponse: afterReplay.checkpointMatchesExpected,
    responseCursorPresent: Boolean(inboundReplayEvidence.nextCursor),
    responseCursorDiffersFromOld:
      inboundReplayEvidence.nextCursor !== oldCursor,
    recordsExactlyOnce: afterReplay.recordsExactlyOnce,
    pendingOutboxUnchanged: afterReplay.pendingCountMatchesBaseline,
    sqliteIntegrity: afterReplay.integrityCheck,
  }));
  assertThat(afterReplay.available && afterReplay.integrityCheck === 'ok' &&
    afterReplay.checkpointRowCount === 1 &&
    afterReplay.checkpointMatchesExpected && afterReplay.recordsExactlyOnce &&
    afterReplay.pendingCountMatchesBaseline &&
    !afterReplay.plaintextMarkerFound &&
    inboundReplayEvidence.nextCursor !== oldCursor,
  'replay did not persist both encrypted records once and advance exactly to next_cursor');
  assertThat(inboundOwnerPushRequestCount === 0,
    'receiver attempted an unexpected server push during inbound replay');
  const serverAfterReplay = inboundProducerOperations.map((operation) =>
    verifyInboundProducerServerSnapshot(
      operation,
      (BigInt(baselineCommitSeq) + 2n).toString(),
    ));
  const serverSnapshotUnchanged =
    stableJson(serverAfterReplay) === stableJson(serverBeforeCrash);
  const serverCommitSeqAfterReplay = serverVaultSnapshot().commitSeq;
  if (!serverSnapshotUnchanged || serverCommitSeqAfterReplay !==
      (BigInt(baselineCommitSeq) + 2n).toString()) {
    console.log('inbound server replay mismatch safe diagnostic', JSON.stringify({
      snapshotUnchanged: serverSnapshotUnchanged,
      commitSeqMatchesExpected: serverCommitSeqAfterReplay ===
        (BigInt(baselineCommitSeq) + 2n).toString(),
      before: serverBeforeCrash,
      after: serverAfterReplay,
      serverCommitSeqAfterReplay,
    }));
  }
  assertThat(serverSnapshotUnchanged && serverCommitSeqAfterReplay ===
    (BigInt(baselineCommitSeq) + 2n).toString(),
  'server receipt/version/event/head counts changed during inbound replay');
  assertThat(pageErrorCount === 0 && trustedPageErrorCount === 0,
    'inbound changes crash recovery raised a browser page error');
  console.log('WEB-SYNC-CRASH-01 inbound changes acceptance', JSON.stringify({
    receiverBackend: driftImplementation || null,
    committedRemoteEvents: inboundProducerOperations.length,
    oldCursorUsedBeforeCrash: inboundPreCrashPageEvidence.requestCursor === oldCursor,
    oldCursorUsedOnFirstRestartRequest: inboundReplayEvidence.requestCursor === oldCursor,
    restartedPageReplayedBothEvents: inboundReplayEvidence.exactlyTwoEvents,
    projectedHostCount: INBOUND_HOST_FIXTURES.length,
    replayCheckpointAdvanced: afterReplay.checkpointMatchesExpected,
    localRecordsExactlyOnce: afterReplay.recordsExactlyOnce,
    pendingOutboxUnchanged: afterReplay.pendingCountMatchesBaseline,
    receiverPushRequests: inboundOwnerPushRequestCount,
    serverStateUnchangedAfterCrash: stableJson(serverAfterReplay) ===
      stableJson(serverBeforeCrash),
    localSqliteIntegrity: afterReplay.integrityCheck,
    localPlaintextMarkersAbsent: !afterReplay.plaintextMarkerFound,
    serverPlaintextMarkersAbsent: serverAfterReplay.every((snapshot) =>
      !snapshot.plaintextMarkerFound && !snapshot.serverPlaintextMarkerFound),
    workerRouteHits: idbWorkerRouteCount,
    heldCommittedTransactions: inboundWorkerCompletionHolds,
    checkpointWriteFailure: checkpointFailureEvidence,
  }));
}

function redactionTargetHostCard(pageRef) {
  const escapedHostName = HOST_NAME.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return pageRef.getByRole('group', {
    name: new RegExp(`^Host: ${escapedHostName};`),
  }).first();
}

async function deleteRedactionTargetHost(pageRef) {
  const card = redactionTargetHostCard(pageRef);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'More actions', exact: true }).click();
  await pageRef.getByRole('menuitem', { name: 'Delete', exact: true }).click();
  await waitForSemanticText(pageRef, 'Delete this item?');
  const dialog = pageRef.getByRole('alertdialog')
    .filter({ hasText: 'Delete this item?' }).first();
  await dialog.getByRole('button', { name: 'Delete', exact: true }).click();
  await waitForCondition(async () =>
    !await card.isVisible().catch(() => false),
  'redaction target Host disappeared from the active list', 20000, pageRef);
}

function expireRedactionTombstone(vaultId, recordId, revisionId) {
  const sql = [
    'import sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1],timeout=8)',
    'db.execute("PRAGMA busy_timeout=8000")',
    'cursor=db.execute("UPDATE record_versions SET created_at=?,restore_until=? WHERE vault_id=? AND record_id=? AND revision_id=? AND operation=\'delete\'",(\'2000-01-01T00:00:00Z\',\'2000-01-31T00:00:00Z\',sys.argv[2],sys.argv[3],sys.argv[4]))',
    'db.commit()',
    'print(cursor.rowcount)',
    'db.close()',
  ].join('\n');
  const result = spawnSync('python3', ['-c', sql, databasePath, vaultId, recordId, revisionId], {
    encoding: 'utf8', timeout: 12000, maxBuffer: 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0 && result.stdout.trim() === '1',
    'could not expire exactly the isolated Vault tombstone');
}

async function purgeRedactionTarget(vaultId, deletedOperation) {
  await waitForCondition(() => redactionAuthorization !== undefined,
    'owner bearer authorization was not observed on an authenticated request',
    10000);
  assertThat(redactionCapabilityReportStatuses.includes(200),
    'owner redaction capability report was not accepted before purge');
  expireRedactionTombstone(
    vaultId, deletedOperation.recordId, deletedOperation.revisionId,
  );
  const response = await fetch(
    `${baseUrl}/api/v1/vaults/${vaultId}/records/${deletedOperation.recordId}/purge`,
    {
      method: 'POST',
      headers: {
        authorization: redactionAuthorization,
        'content-type': 'application/json',
        'x-atermius-redaction-marker': 'v1',
      },
      body: JSON.stringify({
        expected_deleted_revision_id: deletedOperation.revisionId,
        expected_deleted_seq: deletedOperation.receipt.commitSeq,
      }),
      signal: AbortSignal.timeout(15000),
    },
  );
  const body = await response.json().catch(() => null);
  if (response.status !== 200 || body?.status !== 'purged' ||
      !body?.redaction || body.redaction.record_id !== deletedOperation.recordId ||
      body.redaction.deleted_revision_id !== deletedOperation.revisionId ||
      body.redaction.deleted_seq !== deletedOperation.receipt.commitSeq) {
    const code = typeof body?.error?.code === 'string'
      ? body.error.code : 'invalid-response';
    throw new Error(`owner redaction purge failed (${response.status}, ${code})`);
  }
  redactionPurgeResponse = {
    status: response.status,
    alreadyPurged: body.already_purged === true,
    proof: body.redaction,
  };
  return redactionPurgeResponse;
}

async function clickSyncNow(pageRef) {
  await click(pageRef, 'Sync & conflicts');
  await waitForSemanticText(pageRef, 'Sync health');
  await waitForCondition(async () => {
    const syncButton = pageRef.getByRole('button', { name: 'Sync now', exact: true });
    const enabled = await syncButton.isVisible().catch(() => false) &&
      await syncButton.isEnabled().catch(() => false);
    return enabled || redactionChangesPages.length > 0;
  }, 'redaction sync control became available', 20000, pageRef);
  const syncButton = pageRef.getByRole('button', { name: 'Sync now', exact: true });
  if (await syncButton.isVisible().catch(() => false) &&
      await syncButton.isEnabled().catch(() => false)) {
    await syncButton.click();
  }
}

function redactionStateExpectation(vaultId, proof, oldCheckpoint, targetCheckpoint) {
  return {
    vaultId,
    recordId: proof.record_id,
    instanceId: proof.instance_id,
    serverSpaceId: proof.server_space_id,
    proof,
    oldCheckpoint,
    targetCheckpoint,
    markers: REDACTION_PLAINTEXT_MARKERS,
  };
}

async function runRecordRedactionIndexedDbAcceptance(initialVault) {
  assertThat(driftImplementation === 'sharedIndexedDb',
    'record redaction persistence acceptance requires the sharedIndexedDb backend');
  await waitForCondition(() => redactionCapabilityReportStatuses.includes(200),
    'owner redaction capability report was not accepted', 30000);
  await waitForCondition(() => redactionAuthorization !== undefined,
    'owner bearer authorization was not observed', 10000);
  await waitForCondition(() => trustedRedactionCapabilityReportStatuses.includes(200),
    'trusted Web device redaction capability report was not accepted', 30000);

  setStage('create an encrypted Host before redaction');
  await click(page, 'Hosts');
  await enterHostForm(page);
  await click(page, 'Save encrypted host');
  await waitForSemanticText(page, HOST_NAME);
  await waitForCondition(() => redactionLifecycleOperations.some((item) =>
    item.operation === 'create' && item.recordId && item.receipt?.commitSeq),
  'server did not acknowledge the redaction fixture Host create', 30000);
  const createOperation = redactionLifecycleOperations.find((item) =>
    item.operation === 'create' && item.recordId && item.receipt?.commitSeq);
  assertThat(createOperation.vaultId === initialVault.vaultId &&
    createOperation.markersAbsent,
  'redaction fixture create did not match the opaque server operation');

  setStage('delete the Host and commit its tombstone');
  await deleteRedactionTargetHost(page);
  await waitForCondition(() => redactionLifecycleOperations.some((item) =>
    item.recordId === createOperation.recordId && item.operation === 'delete' &&
    item.receipt?.commitSeq),
  'server did not acknowledge the redaction fixture tombstone', 30000);
  const deleteOperation = redactionLifecycleOperations.find((item) =>
    item.recordId === createOperation.recordId && item.operation === 'delete' &&
    item.receipt?.commitSeq);
  assertThat(deleteOperation.vaultId === initialVault.vaultId &&
    deleteOperation.revisionId && deleteOperation.receipt.commitSeq,
  'server tombstone receipt was malformed');

  redactionTarget = {
    vaultId: initialVault.vaultId,
    recordId: deleteOperation.recordId,
  };
  redactionChangesPages = [];
  redactionChangesPageSignal = deferred();
  redactionChangesPageRelease = deferred();
  redactionChangesPageHold = true;
  redactionChangesRouteActive = true;
  setStage('issue owner purge request against the expired exact tombstone');
  const purge = await purgeRedactionTarget(initialVault.vaultId, deleteOperation);
  const proof = purge.proof;
  assertThat(proof.format === 'atermius-record-redaction-proof-v1' &&
    proof.record_id === deleteOperation.recordId &&
    proof.deleted_revision_id === deleteOperation.revisionId &&
    proof.deleted_seq === deleteOperation.receipt.commitSeq &&
    typeof proof.redaction_id === 'string' &&
    typeof proof.redaction_seq === 'string',
  'owner purge response did not contain the exact signed redaction statement');

  setStage('capture the redacted changes page and its opaque cursor');
  const inspectPreRedaction = () => snapshotClientRedactionState(page, {
    vaultId: initialVault.vaultId,
    recordId: proof.record_id,
    instanceId: proof.instance_id,
    serverSpaceId: proof.server_space_id,
    proof,
    oldCheckpoint: null,
    targetCheckpoint: null,
    markers: REDACTION_PLAINTEXT_MARKERS,
  });
  let preRedaction;
  await waitForCondition(async () => {
    preRedaction = await inspectPreRedaction();
    return preRedaction.available && preRedaction.integrityCheck === 'ok' &&
      preRedaction.redactionRowCount === 0 &&
      preRedaction.encryptedRecordCount === 1 &&
      preRedaction.pendingRecordCount === 0;
  }, 'local tombstone outbox acknowledgement persisted before purge replay',
  15000, page);
  const oldCheckpoint = preRedaction.checkpoint;
  assertThat(oldCheckpoint &&
    (oldCheckpoint.cursor === null || typeof oldCheckpoint.cursor === 'string') &&
    typeof oldCheckpoint.serverGeneration === 'string',
  'pre-redaction IndexedDB state did not retain the tombstone and checkpoint');
  await clickSyncNow(page);
  const redactionPage = await Promise.race([
    redactionChangesPageSignal.promise,
    new Promise((_, reject) => setTimeout(() =>
      reject(new Error('client did not request the redaction changes page')),
    30000)),
  ]);
  assertThat(redactionPage.status === 200 &&
    redactionPage.redactionMarkerCount >= 1 &&
    redactionPage.proofs.every((eventProof) =>
      stableJson(eventProof) === stableJson(proof)) &&
    redactionPage.noMorePages && redactionPage.nextCursor &&
    redactionPage.requestCursor === oldCheckpoint.cursor &&
    redactionPage.requestCursor !== redactionPage.nextCursor &&
    redactionPage.serverGeneration &&
    stableJson(redactionPage.proof) === stableJson(proof),
  'changes page did not carry the exact proof and next opaque cursor');

  const targetCheckpoint = {
    cursor: redactionPage.nextCursor,
    serverGeneration: redactionPage.serverGeneration,
  };
  const expected = redactionStateExpectation(
    initialVault.vaultId, proof, oldCheckpoint, targetCheckpoint,
  );

  setStage('hold durable IndexedDB callbacks and observe redaction apply ordering');
  await waitForIdbProbeEvent(page, 'worker-route-loaded', 10000);
  await waitForIdbProbeEvent(page, 'drift-port-observer-installed', 10000);
  await page.evaluate(() => {
    window.__atermiusIdbWriteFailureProbe.arm({ holdCommittedCallback: true });
  });
  await waitForIdbProbeEvent(page, 'armed', 5000);
  redactionChangesPageHold = false;
  redactionChangesPageRelease.resolve();
  let held = 0;
  let durableRedaction;
  for (let attempt = 0; attempt < 32; attempt += 1) {
    await waitForIdbProbeCount(
      page, 'write-transaction-completion-callback-held', held + 1, 20000,
    );
    await waitForIdbProbeCount(
      page, 'write-transaction-durable-complete', held + 1, 5000,
    );
    held += 1;
    const current = await snapshotClientRedactionState(page, expected);
    if (current.available && current.integrityCheck === 'ok') {
      const redactionApplied = current.redactionRowCount === 1 &&
        current.redactionProofMatches && current.encryptedRecordCount === 0;
      assertThat(!current.checkpointMatchesTarget || redactionApplied,
        'durable sync cursor advanced before the redaction proof and cache erasure');
      if (redactionApplied) {
        durableRedaction = current;
        break;
      }
    }
    await page.evaluate(() => {
      window.__atermiusIdbWriteFailureProbe.continueCommittedCompletion(true);
    });
  }
  assertThat(durableRedaction && durableRedaction.redactionProofMatches &&
    durableRedaction.encryptedRecordCount === 0 &&
    (durableRedaction.checkpointMatchesOld ||
      durableRedaction.checkpointMatchesTarget) &&
    durableRedaction.pendingRecordCount === 0 &&
    !durableRedaction.plaintextMarkerFound,
  'no durable IndexedDB commit contained the verified erasure and matching cursor state');
  console.log('record redaction durable apply boundary', JSON.stringify({
    heldCommittedTransactions: held,
    proofStored: durableRedaction.redactionProofMatches,
    activeEncryptedRecordCount: durableRedaction.encryptedRecordCount,
    checkpointMatchesOld: durableRedaction.checkpointMatchesOld,
    checkpointMatchesTarget: durableRedaction.checkpointMatchesTarget,
    pendingRecordCount: durableRedaction.pendingRecordCount,
    sqliteIntegrityCheck: durableRedaction.integrityCheck,
    localPlaintextMarkersAbsent: !durableRedaction.plaintextMarkerFound,
  }));

  setStage('confirm and settle the same-profile Web device identity before crash');
  const storageBeforeCrash = await safeBrowserStorageDiagnostic(page);
  console.log('record redaction Web storage before crash', JSON.stringify({
    storage: storageBeforeCrash,
    localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
  }));
  assertThat(storageBeforeCrash.expectedOrigin === true &&
    storageBeforeCrash.secureContext === true &&
    storageBeforeCrash.deviceRecordPresent === true,
  'registered Web device identity was not present before redaction crash');
  const appPageFingerprint = localStorageLevelDbFingerprint(profileDir);
  await page.goto('about:blank', { waitUntil: 'load', timeout: 10000 });
  const appPageUnbind = await waitForLocalStorageLevelDbCommit(
    profileDir, appPageFingerprint, { requireChange: false, timeoutMs: 5000 });
  const storageBarrierPage = await browserContext.newPage();
  await storageBarrierPage.goto(`${baseUrl}/health/ready`, {
    waitUntil: 'domcontentloaded', timeout: 10000,
  });
  const storageAtDocumentStart = await storageBarrierPage.evaluate(() =>
    window.__atermiusStorageAtDocumentStart || null);
  const storageAfterUnbind = await safeBrowserStorageDiagnostic(storageBarrierPage);
  console.log('record redaction Web storage after app-page unbind', JSON.stringify({
    appPageUnbind,
    storageAtDocumentStart,
    storage: storageAfterUnbind,
    localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
  }));
  assertThat(page.url() === 'about:blank' && appPageUnbind.stable &&
    storageAtDocumentStart?.expectedOrigin === true &&
    storageAtDocumentStart.deviceRecordPresent === true &&
    storageAfterUnbind.deviceRecordPresent === true,
  'registered Web device identity did not persist after releasing the app-page storage binding');
  const storageProbeFingerprint = localStorageLevelDbFingerprint(profileDir);
  await storageBarrierPage.evaluate(({ key, value }) => {
    window.localStorage.setItem(key, value);
  }, {
    key: LOCAL_STORAGE_CRASH_PROBE_KEY,
    value: LOCAL_STORAGE_CRASH_PROBE_VALUE,
  });
  const storageProbeCommit = await waitForLocalStorageLevelDbCommit(
    profileDir, storageProbeFingerprint, { requireChange: true, timeoutMs: 5000 });
  const storageProbeVisibleBeforeCrash = await storageBarrierPage.evaluate(
    ({ key, value }) => window.localStorage.getItem(key) === value,
    {
      key: LOCAL_STORAGE_CRASH_PROBE_KEY,
      value: LOCAL_STORAGE_CRASH_PROBE_VALUE,
    },
  );
  console.log('record redaction Web localStorage durability barrier', JSON.stringify({
    ...storageProbeCommit,
    probeVisibleBeforeCrash: storageProbeVisibleBeforeCrash,
  }));
  assertThat(storageProbeCommit.changed && storageProbeCommit.stable &&
    storageProbeVisibleBeforeCrash,
  'same-profile localStorage probe did not reach a changed and stable LevelDB state');
  page = storageBarrierPage;
  const redactionBeforeCrash = await snapshotClientRedactionState(page, expected);
  assertThat(redactionBeforeCrash.available &&
    redactionBeforeCrash.integrityCheck === 'ok' &&
    redactionBeforeCrash.redactionRowCount === 1 &&
    redactionBeforeCrash.redactionProofMatches &&
    redactionBeforeCrash.encryptedRecordCount === 0 &&
    (redactionBeforeCrash.checkpointMatchesOld ||
      redactionBeforeCrash.checkpointMatchesTarget) &&
    redactionBeforeCrash.pendingRecordCount === 0 &&
    !redactionBeforeCrash.plaintextMarkerFound,
  'localStorage unbind changed the durable redaction IndexedDB state');

  setStage('SIGKILL Chromium after the redaction IndexedDB transaction is durable');
  const killedIdentity = chromiumProfileProcessIdentity(profileDir);
  const killedGroup = await forceKillChromiumProfile(profileDir);
  assertThat(killedGroup === killedIdentity.processGroup,
    'hard termination targeted a different redaction Chromium profile');
  browserContext = undefined;
  page = undefined;

  setStage('reload the same browser profile and verify cursor/redaction durability');
  redactionChangesPages = [];
  await launchPersistentChromium();
  let storageAtRestartDocumentStart;
  await initializeFlutter(page, async () => {
    storageAtRestartDocumentStart = await page.evaluate(() =>
      window.__atermiusStorageAtDocumentStart || null);
    const storage = await safeBrowserStorageDiagnostic(page);
    console.log('record redaction Web storage at restart document start', JSON.stringify({
      storageAtDocumentStart: storageAtRestartDocumentStart,
      storage,
    }));
  });
  const storageAfterRestart = await safeBrowserStorageDiagnostic(page);
  const localStorageCrashProbePersistedAfterCrash = await page.evaluate(
    ({ key, value }) => window.localStorage.getItem(key) === value,
    {
      key: LOCAL_STORAGE_CRASH_PROBE_KEY,
      value: LOCAL_STORAGE_CRASH_PROBE_VALUE,
    },
  );
  console.log('record redaction Web storage after hard restart', JSON.stringify({
    storageAtDocumentStart: storageAtRestartDocumentStart,
    storage: storageAfterRestart,
    localStorageCrashProbePersistedAfterCrash,
    localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
  }));
  assertThat(storageAtRestartDocumentStart?.expectedOrigin === true &&
    storageAfterRestart.expectedOrigin === true &&
    localStorageCrashProbePersistedAfterCrash,
  'same-profile restart did not reopen the original browser origin');
  const redactionAfterRestartBeforeLogin = await snapshotClientRedactionState(
    page, expected);
  assertThat(redactionAfterRestartBeforeLogin.available &&
    redactionAfterRestartBeforeLogin.integrityCheck === 'ok' &&
    redactionAfterRestartBeforeLogin.redactionRowCount === 1 &&
    redactionAfterRestartBeforeLogin.redactionProofMatches &&
    redactionAfterRestartBeforeLogin.encryptedRecordCount === 0 &&
    (redactionAfterRestartBeforeLogin.checkpointMatchesOld ||
      redactionAfterRestartBeforeLogin.checkpointMatchesTarget) &&
    redactionAfterRestartBeforeLogin.pendingRecordCount === 0 &&
    !redactionAfterRestartBeforeLogin.plaintextMarkerFound,
  'same-profile restart lost the durable redaction proof or encrypted-record erasure');
  console.log('record redaction IndexedDB immediately after hard restart', JSON.stringify({
    proofStored: redactionAfterRestartBeforeLogin.redactionProofMatches,
    activeEncryptedRecordCount: redactionAfterRestartBeforeLogin.encryptedRecordCount,
    checkpointMatchesOld: redactionAfterRestartBeforeLogin.checkpointMatchesOld,
    checkpointMatchesTarget: redactionAfterRestartBeforeLogin.checkpointMatchesTarget,
    pendingRecordCount: redactionAfterRestartBeforeLogin.pendingRecordCount,
    sqliteIntegrityCheck: redactionAfterRestartBeforeLogin.integrityCheck,
    localPlaintextMarkersAbsent: !redactionAfterRestartBeforeLogin.plaintextMarkerFound,
  }));
  if (storageAfterRestart.deviceRecordPresent) {
    recoveryEnrollmentMode = 'same-device';
    await recoverWorkspace(page, 30000);
    assertThat(typeof deviceIdAtRegistration === 'string' &&
      deviceIdAtRegistration.length > 0 &&
      deviceIdAtLogin === deviceIdAtRegistration,
    'same-device recovery did not sign in with the original registered device identity');
  } else {
    recoveryEnrollmentMode = 'trusted-device-reenrollment';
    setStage('restart: request trusted-device reenrollment after secure-store loss');
    await prepareForDeviceEnrollment(page);
    let enrollmentJson = await requestDeviceEnrollment(page, RECOVERY_DEVICE_NAME);
    setStage('trusted recovery: approve reenrollment after hard restart');
    let approvalJson = await approveEnrollment(trustedPage, enrollmentJson);
    enrollmentJson = undefined;
    deviceIdAtLogin = undefined;
    await importDeviceApprovalAndSignIn(page, approvalJson);
    approvalJson = undefined;
    assertThat(typeof deviceIdAtLogin === 'string' &&
      deviceIdAtLogin.length > 0 &&
      deviceIdAtLogin !== deviceIdAtRegistration,
    'trusted-device recovery did not sign in with a replacement device identity');
    await waitForWorkspace(page);
    await waitForCondition(() => redactionCapabilityReportStatuses.length >= 2,
      're-enrolled Web device did not publish its redaction capability report', 30000);
  }
  if (durableRedaction.checkpointMatchesOld) {
    await clickSyncNow(page);
  }
  await waitForCondition(async () => {
    const state = await snapshotClientRedactionState(page, expected);
    return state.available && state.integrityCheck === 'ok' &&
      state.redactionRowCount === 1 && state.redactionProofMatches &&
      state.encryptedRecordCount === 0 &&
      state.checkpointMatchesTarget && state.pendingRecordCount === 0 &&
      !state.plaintextMarkerFound;
  }, 'same-profile reload did not preserve redaction proof, erasure and next cursor',
  30000, page);
  const afterReload = await snapshotClientRedactionState(page, expected);
  assertThat(afterReload.checkpointMatchesTarget &&
    afterReload.redactionRowCount === 1 && afterReload.redactionProofMatches &&
    afterReload.encryptedRecordCount === 0 && afterReload.pendingRecordCount === 0 &&
    afterReload.integrityCheck === 'ok' && !afterReload.plaintextMarkerFound,
  'reloaded IndexedDB did not retain an atomic safe redaction state');
  if (durableRedaction.checkpointMatchesOld) {
    assertThat(redactionChangesPages.some((candidate) =>
      candidate.requestCursor === oldCheckpoint.cursor &&
      candidate.redactionMarkerCount >= 1 &&
      candidate.proofs.every((eventProof) =>
        stableJson(eventProof) === stableJson(proof))),
    'same-profile restart did not replay the redacted feed from its pre-redaction cursor');
  }
  await click(page, 'Hosts');
  await waitForCondition(async () =>
    !await redactionTargetHostCard(page).isVisible().catch(() => false),
  'redacted Host remained visible after persistent-profile reload', 15000, page);
  assertThat(pageErrorCount === 0,
    'redaction reload acceptance raised an uncaught browser page error');
  assertThat(trustedPageErrorCount === 0,
    'trusted recovery device raised a browser page error during redaction acceptance');
  console.log('WEB-SYNC-REDACTION-IDB-01 passed', JSON.stringify({
    ownerPurgeAccepted: true,
    signedRedactionProofApplied: afterReload.redactionProofMatches,
    activeEncryptedRecordCount: afterReload.encryptedRecordCount,
    redactionLedgerRows: afterReload.redactionRowCount,
    cursorDurableAcrossReload: afterReload.checkpointMatchesTarget,
    duplicateProofReplayPages: redactionChangesPages.length,
    recoveryEnrollmentMode,
    deviceIdentityPersistedAfterCrash: storageAfterRestart.deviceRecordPresent,
    sameDeviceIdentityMatched: recoveryEnrollmentMode === 'same-device' &&
      deviceIdAtLogin === deviceIdAtRegistration,
    localStorageCrashProbePersistedAfterCrash,
    plaintextMarkersAbsent: !afterReload.plaintextMarkerFound,
    sqliteIntegrityCheck: afterReload.integrityCheck,
    browserPageErrors: pageErrorCount,
  }));
}

async function runIdbWriteFailureRetryAcceptance(baselineCommitSeq) {
  setStage('confirm persistent Web device identity before the write fault');
  await waitForCondition(async () =>
    (await safeBrowserStorageDiagnostic(page))?.deviceRecordPresent === true,
  'registered Web device identity was not durably visible before the write fault', 10000);
  const storageBeforeFault = await safeBrowserStorageDiagnostic(page);

  setStage('inspect local IndexedDB SQLite baseline before injected write failure');
  const localBaseline = await snapshotClientVaultCounts(page);
  const baseCounts = localBaseline.tableCounts;
  assertThat(Number.isSafeInteger(baseCounts?.encrypted_records) &&
    Number.isSafeInteger(baseCounts?.pending_operations),
  'local SQLite baseline omitted encrypted record or pending operation counts');

  const uiBeforeFault = await visiblePersistenceFailure(page, HOST_NAME);
  setStage('confirm instrumented Drift SharedWorker is loaded');
  await waitForIdbProbeEvent(page, 'worker-route-loaded', 5000);
  await waitForIdbProbeEvent(page, 'drift-port-observer-installed', 5000);
  setStage('open a second same-origin tab on the same IndexedDB vault');
  idbSecondPage = await browserContext.newPage();
  idbSecondPage.on('pageerror', () => { idbSecondPageErrorCount += 1; });
  idbSecondPage.on('console', (message) => {
    const match = message.text().match(/ATERMIUS_DRIFT_WEB_IMPLEMENTATION=(\w+)/);
    if (match) driftImplementation = match[1];
  });
  await initializeFlutter(idbSecondPage);
  if (!(await idbSecondPage.getByRole('button', {
    name: 'Add host', exact: true,
  }).isVisible().catch(() => false))) {
    await recoverWorkspace(idbSecondPage);
  }
  await waitForWorkspace(idbSecondPage);
  await click(idbSecondPage, 'Sync & conflicts');
  await waitForSemanticText(idbSecondPage, 'Sync health');
  await waitForCondition(async () => {
    const syncButton = await button(idbSecondPage, 'Sync now').catch(() => null);
    return syncButton && await syncButton.isEnabled().catch(() => false);
  }, 'second-tab sync control did not become available before the storage fault',
  15000, idbSecondPage);
  await waitForIdbProbeEvent(page, 'drift-database-port-associated-2', 10000);
  setStage('fill Host form before arming the IndexedDB fault');
  await enterHostForm(page);
  setStage('arm the one-shot IndexedDB worker fault');
  await page.evaluate(() => {
    window.__atermiusIdbWriteFailureProbe.arm({
      deferAbortForConcurrentRead: true,
    });
  });
  await waitForIdbProbeEvent(page, 'armed', 5000);
  setStage('submit Host save while the one-shot IndexedDB fault is armed');
  await click(page, 'Save encrypted host');
  setStage('wait for the IndexedDB blocks write transaction to be targeted');
  await waitForIdbProbeEvent(page, 'write-transaction-targeted', 20000);
  await waitForIdbProbeEvent(page, 'write-transaction-abort-deferred', 5000);
  await waitForIdbProbeEvent(page, 'write-transaction-commit-held', 5000);
  const secondTabReadBaseline = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'drift-query-request-observed'] || 0,
  );
  const secondTabPortReadBaseline = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'drift-query-request-port-2'] || 0,
  );
  const crossPortCancellationBaseline = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'cross-tab-query-cancellation-from-other-port'] || 0,
  );
  setStage('send second-tab sync request while the IndexedDB flush is held open');
  await click(idbSecondPage, 'Sync now');
  await waitForIdbProbeCount(
    page,
    'drift-query-request-port-2',
    secondTabPortReadBaseline + 1,
    10000,
  );
  const secondTabReadObserved = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'drift-query-request-observed'] || 0,
  );
  const secondTabPortReadObserved = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'drift-query-request-port-2'] || 0,
  );
  idbSecondTabEvidence = {
    sameOriginTabOpened: true,
    databaseBackend: driftImplementation || null,
    workerRequestCountBeforeSync: secondTabReadBaseline,
    workerRequestCountAfterSync: secondTabReadObserved,
    secondTabPortOrdinal: 2,
    secondTabPortRequestCountBeforeSync: secondTabPortReadBaseline,
    secondTabPortRequestCountAfterSync: secondTabPortReadObserved,
    crossPortCancellationCountBeforeSync: crossPortCancellationBaseline,
    syncRequestReachedSharedWorker: secondTabReadObserved > secondTabReadBaseline &&
      secondTabPortReadObserved > secondTabPortReadBaseline,
  };
  setStage('release the held IndexedDB transaction and observe its abort');
  await page.evaluate(() => {
    window.__atermiusIdbWriteFailureProbe.continueAbort();
  });
  setStage('wait for the IndexedDB blocks transaction abort request');
  await waitForIdbProbeEvent(page, 'write-transaction-abort-requested', 5000);
  setStage('wait for the IndexedDB blocks transaction abort event');
  await waitForIdbProbeEvent(page, 'write-transaction-abort-event', 5000);
  setStage('read sanitized IndexedDB fault event telemetry');
  const probeSummary = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary(),
  );
  const armIndex = probeSummary.recentTypes.lastIndexOf('armed');
  assertThat(armIndex >= 0, 'IndexedDB fault telemetry omitted the arm event');
  const faultEvents = probeSummary.recentTypes.slice(armIndex + 1);
  const faultEventIndex = (type) => faultEvents.indexOf(type);
  const targetedIndex = faultEventIndex('write-transaction-targeted');
  const crossTabQueryIndex = faultEvents.findIndex((type, index) =>
    index > targetedIndex && type === 'drift-query-request-port-2');
  assertThat(idbWorkerRouteCount > 0 &&
    probeSummary.counts['worker-route-loaded'] > 0 &&
    probeSummary.counts['write-transaction-targeted'] > 0 &&
    probeSummary.counts['write-transaction-abort-requested'] > 0 &&
    probeSummary.counts['write-transaction-abort-event'] > 0 &&
    probeSummary.counts['write-transaction-abort-release-received'] > 0 &&
    probeSummary.counts['write-transaction-commit-held'] > 0 &&
    probeSummary.counts['write-transaction-complete'] === undefined &&
    probeSummary.counts['drift-port-observer-installed'] > 0 &&
    probeSummary.counts['write-transaction-abort-failed'] === undefined,
  'instrumented SharedWorker did not observe and abort the blocks write transaction');
  assertThat((probeSummary.counts['blocks-put-observed'] || 0) +
    (probeSummary.counts['blocks-update-observed'] || 0) > 0 &&
    probeSummary.counts['blocks-write-vault-database'] > 0 &&
    targetedIndex >= 0 &&
    crossTabQueryIndex > targetedIndex &&
    faultEventIndex('write-transaction-abort-requested') >
      crossTabQueryIndex &&
    faultEventIndex('write-transaction-abort-release-received') >
      crossTabQueryIndex &&
    faultEventIndex('write-transaction-abort-event') >
      faultEventIndex('write-transaction-abort-requested'),
  'IndexedDB fault event sequence did not show a second-tab database-port request followed by abort');
  assertThat(
    (probeSummary.counts['drift-error-response-quarantine-marker'] || 0) >= 1 &&
      probeSummary.counts['drift-error-response-persistence-marker'] === undefined &&
      probeSummary.counts['drift-error-response-other'] === undefined &&
      probeSummary.counts['drift-sqlite-error-response'] === undefined &&
      faultEventIndex('drift-error-response-quarantine-marker') >
        faultEventIndex('write-transaction-abort-requested'),
    'aborted IndexedDB transaction did not return the fixed quarantine marker',
  );
  idbFailureProbeEvidence = {
    workerRouteHits: idbWorkerRouteCount,
    driftWebImplementation: driftImplementation || null,
    eventCounts: probeSummary.counts,
    eventSequenceAfterArm: faultEvents,
    secondTabQueryArrivedBeforeAbort: crossTabQueryIndex > targetedIndex &&
      faultEventIndex('write-transaction-abort-requested') > crossTabQueryIndex,
    atLeastOneFixedQuarantineResponseAfterAbort:
      (probeSummary.counts['drift-error-response-quarantine-marker'] || 0) >= 1,
  };
  setStage('inspect visible UI response to IndexedDB abort');
  await waitForCondition(async () => {
    const state = await visiblePersistenceFailure(page, HOST_NAME);
    const newFailureSignal = state.alertErrorCount > uiBeforeFault.alertErrorCount ||
      state.categories.some((category) => !uiBeforeFault.categories.includes(category));
    return newFailureSignal && state.retryActionVisible &&
      !state.hostNameVisible ? state : false;
  }, 'visible recoverable storage error after IndexedDB transaction abort', 7000)
    .catch(() => false);
  let storageError = await visiblePersistenceFailure(page, HOST_NAME);
  const secondTabStateAfterAbort = await visiblePersistenceFailure(
    idbSecondPage,
    HOST_NAME,
  );
  idbFailureUiEvidence = {
    primary: {
      surfaced: storageError.surfaced,
      recoveryRequiredVisible: storageError.recoveryRequiredVisible,
      hostEditorStillVisible: storageError.hostEditorStillVisible,
      hostNameVisible: storageError.hostNameVisible,
      saveSuccessNoticeVisible: storageError.saveSuccessNoticeVisible,
    },
    secondTab: {
      surfaced: secondTabStateAfterAbort.surfaced,
      recoveryRequiredVisible: secondTabStateAfterAbort.recoveryRequiredVisible,
    },
    quarantineBroadcast: {
      primary: await page.evaluate(() =>
        window.__atermiusDatabaseQuarantineProbe?.summary?.() || null),
      secondTab: await idbSecondPage.evaluate(() =>
        window.__atermiusDatabaseQuarantineProbe?.summary?.() || null),
    },
  };
  setStage('confirm the second tab received recovery-required state');
  await waitForCondition(async () =>
    (await visiblePersistenceFailure(idbSecondPage, HOST_NAME))
      .recoveryRequiredVisible,
  'second same-origin tab did not show the recovery-required banner',
  7000, idbSecondPage);
  setStage('inspect second-tab sync control after quarantine');
  const initialSyncUiAfterQuarantine = await waitForSyncControlSettle(idbSecondPage);
  setStage('confirm the interleaved second-tab query fails closed after abort');
  let crossTabQueryResponse;
  try {
    crossTabQueryResponse = await waitForIdbProbeAnyEvent(page, [
      'cross-tab-query-quarantine-response',
      'cross-tab-query-persistence-failure-response',
      'cross-tab-query-success-response',
      'cross-tab-query-other-error-response',
      'cross-tab-query-sqlite-error-response',
      'cross-tab-query-cancelled-response',
    ], 10000);
  } catch (_) {
    crossTabQueryResponse = null;
  }
  const syncUiAfterQuarantine =
    initialSyncUiAfterQuarantine.label === 'recovery-syncing' ||
        !initialSyncUiAfterQuarantine.settled
      ? await waitForSyncControlSettle(idbSecondPage, 3000)
      : initialSyncUiAfterQuarantine;
  idbSyncControlDiagnostic = {
    initial: initialSyncUiAfterQuarantine,
    afterQueryResponseWait: syncUiAfterQuarantine,
    crossTabQueryResponse: crossTabQueryResponse || null,
  };
  idbSecondTabEvidence ||= {};
  idbSecondTabEvidence.syncUiAfterQuarantine = syncUiAfterQuarantine;
  idbSecondTabEvidence.initialSyncUiAfterQuarantine =
    initialSyncUiAfterQuarantine;
  idbFailureProbeEvidence.crossTabQueryResponse = crossTabQueryResponse || null;
  assertThat(crossTabQueryResponse === 'cross-tab-query-quarantine-response',
    `interleaved second-tab query response did not fail closed: ${crossTabQueryResponse || 'missing'}`);
  const completedProbeSummary = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary(),
  );
  assertThat(completedProbeSummary.counts[
    'drift-error-response-quarantine-marker'] === 2 &&
    completedProbeSummary.counts['drift-error-response-persistence-marker'] === undefined &&
    completedProbeSummary.counts['drift-error-response-other'] === undefined &&
    completedProbeSummary.counts['drift-sqlite-error-response'] === undefined,
  'IndexedDB abort did not return one write failure and one cross-tab quarantine marker');
  idbFailureProbeEvidence.eventCounts = completedProbeSummary.counts;
  assertThat(syncUiAfterQuarantine.settled && syncUiAfterQuarantine.visible &&
    syncUiAfterQuarantine.label === 'recovery-required',
  `second-tab sync control did not settle into the visible recovery-required state: ${JSON.stringify(syncUiAfterQuarantine)}`);
  assertThat(!syncUiAfterQuarantine.enabled,
    `second-tab recovery-required sync control remained enabled: ${JSON.stringify(syncUiAfterQuarantine)}`);
  const postAbortRequestCountBeforeAction = await page.evaluate(() =>
    window.__atermiusIdbWriteFailureProbe.eventSummary().counts[
      'drift-database-request-after-abort-observed'] || 0,
  );
  const pushCountBeforeAction = idbFailureAllPushRequests;
  setStage('verify quarantined second-tab sync control remains disabled');
  const quietCounts = await waitForQuarantineRequestCountsSettle(
    idbSecondPage,
    pushCountBeforeAction,
  );
  const syncUiAfterAction = await waitForSyncControlSettle(idbSecondPage);
  idbSecondTabEvidence.syncUiAfterAction = syncUiAfterAction;
  idbSecondTabEvidence.requestCountsAfterQuarantine = quietCounts;
  idbSecondTabEvidence.syncRequestReachedWorkerBeforeAbort =
    idbFailureProbeEvidence.secondTabQueryArrivedBeforeAbort;
  idbSecondTabEvidence.syncActionAttemptedAfterQuarantine = false;
  idbSecondTabEvidence.syncActionBlockedByRecovery =
    syncUiAfterQuarantine.label === 'recovery-required' &&
    !syncUiAfterQuarantine.enabled;
  idbSecondTabEvidence.databaseRequestsAfterQuarantine =
    quietCounts.databaseRequestsAfterAbort;
  idbSecondTabEvidence.pushRequestsDuringQuarantineQuietWindow =
    quietCounts.pushRequestsAfterBaseline;
  idbSecondTabEvidence.syncControlSettled =
    syncUiAfterQuarantine.settled && syncUiAfterAction.settled &&
    quietCounts.settled;
  idbSecondTabEvidence.syncStillInFlight =
    syncUiAfterQuarantine.label === 'syncing' ||
    syncUiAfterAction.label === 'syncing';
  idbSecondTabEvidence.syncActionUnavailable = !syncUiAfterQuarantine.enabled;
  assertThat(quietCounts.settled,
    'post-abort database and push counters did not settle within the bounded quiet window');
  assertThat(postAbortRequestCountBeforeAction === 0 &&
    idbSecondTabEvidence.databaseRequestsAfterQuarantine === 0,
    'SharedWorker received a database request after the IndexedDB abort');
  assertThat(idbSecondTabEvidence.pushRequestsDuringQuarantineQuietWindow === 0,
    'server push request occurred while the second tab was quarantined');
  idbSecondTabEvidence.recoveryBannerVisible = true;
  idbSecondTabEvidence.syncBlockedByQuarantine =
    idbSecondTabEvidence.recoveryBannerVisible === true &&
    idbSecondTabEvidence.syncActionBlockedByRecovery === true &&
    idbSecondTabEvidence.databaseRequestsAfterQuarantine === 0 &&
    idbSecondTabEvidence.pushRequestsDuringQuarantineQuietWindow === 0;
  assertThat(syncUiAfterAction.settled && syncUiAfterAction.visible &&
    syncUiAfterAction.label === 'recovery-required' &&
    !syncUiAfterAction.enabled,
  `second-tab sync control changed while recovery remained required: ${JSON.stringify(syncUiAfterAction)}`);

  setStage('attempt a second local Host mutation in the poisoned session');
  const poisonedHostName = `${HOST_NAME}-after-abort`;
  await enterHostForm(page, poisonedHostName);
  await click(page, 'Save encrypted host');
  await waitForCondition(async () =>
    (await visiblePersistenceFailure(page, HOST_NAME)).recoveryRequiredVisible,
  'same-session mutation did not remain in recovery-required state', 7000);
  const sameSessionPageState = await page.evaluate((names) => {
    const text = document.body.innerText || '';
    return {
      originalGhostVisible: text.includes(names.original),
      secondMutationVisible: text.includes(names.poisoned),
      recoveryBannerVisible: text.includes('本地存储状态需要恢复') &&
        text.includes('关闭所有 Atermius 标签页'),
    };
  }, { original: HOST_NAME, poisoned: poisonedHostName });
  assertThat(!sameSessionPageState.originalGhostVisible &&
    !sameSessionPageState.secondMutationVisible &&
    sameSessionPageState.recoveryBannerVisible,
  'poisoned same-session mutation exposed a Host or lost the recovery banner');
  const secondTabPageState = await visiblePersistenceFailure(
    idbSecondPage,
    HOST_NAME,
  );
  idbSecondTabEvidence.recoveryBannerVisible =
    secondTabPageState.recoveryRequiredVisible;
  idbSecondTabEvidence.recoveryBannerPersists =
    secondTabPageState.recoveryRequiredVisible;

  storageError = await visiblePersistenceFailure(page, HOST_NAME);
  idbFailureUiEvidence = {
    before: {
      surfaced: uiBeforeFault.surfaced,
      alertErrorCount: uiBeforeFault.alertErrorCount,
      errorSemanticCount: uiBeforeFault.errorSemanticCount,
      categories: uiBeforeFault.categories,
    },
    after: {
      surfaced: storageError.surfaced,
      alertErrorCount: storageError.alertErrorCount,
      errorSemanticCount: storageError.errorSemanticCount,
      categories: storageError.categories,
      newFailureSignal: storageError.alertErrorCount > uiBeforeFault.alertErrorCount ||
        storageError.categories.some((category) =>
          !uiBeforeFault.categories.includes(category)),
      hostEditorStillVisible: storageError.hostEditorStillVisible,
      hostNameVisible: storageError.hostNameVisible,
      saveSuccessNoticeVisible: storageError.saveSuccessNoticeVisible,
      retryActionVisible: storageError.retryActionVisible,
      recoveryRequiredVisible: storageError.recoveryRequiredVisible,
    },
  };

  setStage('inspect durable IndexedDB SQLite snapshot after the aborted transaction');
  await page.waitForTimeout(500);
  const localAfterAbort = await snapshotClientVaultCounts(page);
  assertThat(JSON.stringify(localAfterAbort.tableCounts) === JSON.stringify(baseCounts),
    'aborted IndexedDB transaction left an encrypted record or outbox row in durable SQLite');
  const serverAfterAbort = serverVaultSnapshot();
  assertThat(serverAfterAbort.commitSeq === baselineCommitSeq,
    'server commit sequence changed before the local storage retry');
  assertThat(idbFailurePushRequestsBeforeRetry === 0,
    'client attempted a server push before the failed local write was restarted');
  assertThat(idbWorkerRouteCount > 0,
    'current Flutter bundle did not load the instrumented Drift SharedWorker');
  assertThat(storageError?.surfaced === true &&
    (idbFailureUiEvidence.after.newFailureSignal === true ||
      storageError.recoveryRequiredVisible === true),
  'aborted local IndexedDB write did not surface a new visible recoverable error');
  assertThat(storageError?.hostEditorStillVisible === false &&
    storageError?.hostNameVisible === false &&
    storageError?.recoveryRequiredVisible === true,
  'failed Host save did not leave the Host absent with a recovery-required banner');
  assertThat(storageError?.saveSuccessNoticeVisible === false,
    'failed local Host persistence displayed the successful local-save notice');
  console.log('IndexedDB write failure pre-restart evidence', JSON.stringify({
    injectedFaultProbe: idbFailureProbeEvidence,
    sameOriginCrossTabQuarantine: idbSecondTabEvidence,
    durableSqliteIntegrity: localAfterAbort.integrityCheck,
    durableRecordAndOutboxCountsUnchanged:
      JSON.stringify(localAfterAbort.tableCounts) === JSON.stringify(baseCounts),
    durableTableCounts: localAfterAbort.tableCounts,
    visibleRecoverableError: storageError.surfaced,
    newVisibleFailureSignal: idbFailureUiEvidence.after.newFailureSignal,
    hostEditorVisible: storageError.hostEditorStillVisible,
    hostCardVisible: storageError.hostNameVisible,
    retryActionVisible: storageError.retryActionVisible,
    successNoticeVisible: storageError.saveSuccessNoticeVisible,
    preRetryServerCommitSeq: serverAfterAbort.commitSeq,
    preRetryPushCount: idbFailurePushRequestsBeforeRetry,
  }));
  setStage('hard terminate Chromium at the verified durable rollback boundary');
  const killedBrowserIdentity = chromiumProfileProcessIdentity(profileDir);
  const killedProcessGroup = await forceKillChromiumProfile(profileDir);
  assertThat(killedProcessGroup === killedBrowserIdentity.processGroup,
    'hard termination targeted a different Chromium process group');
  browserContext = undefined;
  page = undefined;

  setStage('restart the same persistent profile with the one-shot fault disarmed');
  await launchPersistentChromium();
  setStage('verify Chromium process identity after restart');
  const relaunchedBrowserIdentity = chromiumProfileProcessIdentity(profileDir);
  assertThat(relaunchedBrowserIdentity.pid !== killedBrowserIdentity.pid ||
    relaunchedBrowserIdentity.startTimeTicks !== killedBrowserIdentity.startTimeTicks,
  'Chromium restart reused the terminated process identity');
  setStage('inspect persistent Web storage before Flutter restart initialization');
  let storageImmediatelyAfterRestart;
  await initializeFlutter(page, async () => {
    storageImmediatelyAfterRestart = await safeBrowserStorageDiagnostic(page);
  });
  console.log('Web storage after rollback restart', JSON.stringify({
    immediatelyAfterRestart: storageImmediatelyAfterRestart,
  }));
  assertThat(storageImmediatelyAfterRestart?.expectedOrigin === true,
    'restarted browser storage probe did not use the original origin');
  setStage('verify persisted Web device identity after restart');
  const storageAfterRestart = await safeBrowserStorageDiagnostic(page);
  deviceRecordPresentAfterRestart = storageAfterRestart?.deviceRecordPresent === true;
  if (deviceRecordPresentAfterRestart) {
    recoveryEnrollmentMode = 'same-device';
    await recoverWorkspace(page);
  } else {
    recoveryEnrollmentMode = 'trusted-device-reenrollment';
    await prepareForDeviceEnrollment(page);
    let enrollmentJson = await requestDeviceEnrollment(page, RECOVERY_DEVICE_NAME);
    let approvalJson = await approveEnrollment(trustedPage, enrollmentJson);
    enrollmentJson = undefined;
    await importDeviceApprovalAndSignIn(page, approvalJson);
    approvalJson = undefined;
    recoveryDeviceIdAtLogin = deviceIdAtLogin;
    await waitForWorkspace(page);
    assertThat(trustedPageErrorCount === 0,
      'trusted recovery device raised a browser page error');
  }
  await waitForWorkspace(page);
  const hostBeforeRetry = await page.evaluate((hostName) =>
    (document.body.innerText || '').includes(hostName), HOST_NAME);
  assertThat(!hostBeforeRetry,
    'failed local Host creation appeared after restart despite transaction rollback');
  const localAfterRestart = await snapshotClientVaultCounts(page);
  assertThat(JSON.stringify(localAfterRestart.tableCounts) === JSON.stringify(baseCounts),
    'restart did not recover the last durable SQLite snapshot after the aborted write');
  assertThat(serverVaultSnapshot().commitSeq === baselineCommitSeq,
    'server changed while restarting after local IndexedDB rollback');

  setStage('retry Host creation after restart with the fault disarmed');
  idbFailureRetryEnabled = true;
  await enterHostForm(page);
  await click(page, 'Save encrypted host');
  await waitForCondition(() => idbFailureReceipt !== undefined,
    'retry did not receive a successful server receipt', 45000);
  assertThat(idbFailureOperation?.operation === 'create' &&
    idbFailureReceipt.opId === idbFailureOperation.opId &&
    idbFailureReceipt.revisionId === idbFailureOperation.revisionId &&
    idbFailureReceipt.commitSeq === (BigInt(baselineCommitSeq) + 1n).toString() &&
    !idbFailureReceipt.alreadyCommitted,
  'post-restart retry did not create exactly one new server receipt');
  idbFailureOperation.receipt = idbFailureReceipt;
  await waitForSemanticText(page, HOST_NAME);
  await waitForPendingCount(page, 0, 45000);
  const localAfterRetry = await waitForIndexedDbOutboxState(
    page, idbFailureOperation, 'committed', 20000);
  assertThat(localAfterRetry.pendingCount === 0 &&
    localAfterRetry.vaultOperationCount === 0 &&
    localAfterRetry.record.commitSeq === idbFailureReceipt.commitSeq,
  'successful retry did not clear its local outbox row after acknowledgement');

  setStage('verify exactly-once server state and local outbox cleanup');
  const finalServer = serverRecordSnapshot(idbFailureOperation, baselineCommitSeq);
  assertThat(idbFailurePushRequestsAfterRetry === 1 &&
    finalServer.versionCount === 1 && finalServer.versionMatches &&
    finalServer.versionCommitSeq === idbFailureReceipt.commitSeq &&
    finalServer.eventCount === 1 && finalServer.eventMatches &&
    finalServer.eventCommitSeq === idbFailureReceipt.commitSeq &&
    finalServer.receiptCount === 1 && finalServer.receiptMatches &&
    finalServer.receiptCommitSeq === idbFailureReceipt.commitSeq &&
    finalServer.headMatches && !finalServer.headDeleted &&
    finalServer.headCommitSeq === idbFailureReceipt.commitSeq &&
    finalServer.commitSeq === idbFailureReceipt.commitSeq &&
    finalServer.envelopeHash === idbFailureOperation.envelopeSha256 &&
    finalServer.eventEnvelopeHash === idbFailureOperation.envelopeSha256 &&
    finalServer.opaqueEnvelope && !finalServer.plaintextMarkerFound &&
    !finalServer.serverPlaintextMarkerFound,
  'retry did not leave exactly one opaque server version, event, receipt and head');
  assertThat(storageError?.surfaced === true &&
    idbFailureUiEvidence.after.newFailureSignal === true,
  'aborted local IndexedDB write did not surface a new visible recoverable error');
  assertThat(storageError?.hostEditorStillVisible === false &&
    storageError?.hostNameVisible === false && storageError?.retryActionVisible === true,
  'failed Host save did not leave the Host absent with a visible retry action');
  assertThat(storageError?.saveSuccessNoticeVisible === false,
    'failed local Host persistence displayed the successful local-save notice');
  assertThat(pageErrorCount === 0,
    'retry/restart path raised an uncaught Flutter Web page error');
  if (recoveryEnrollmentMode === 'trusted-device-reenrollment') {
    assertThat(typeof recoveryDeviceIdAtLogin === 'string' &&
      recoveryDeviceIdAtLogin.length > 0 &&
      recoveryDeviceIdAtLogin !== deviceIdAtRegistration,
    'trusted-device recovery did not establish a new Web device identity');
  }

  console.log('WEB-SYNC-CRASH-01 IndexedDB durable rollback and retry passed', JSON.stringify({
    driftWebImplementation: driftImplementation || null,
    injectedFault: 'one-shot IndexedDB readwrite transaction abort after first blocks mutation',
    simulatedRealQuotaExhaustion: false,
    simulatedBrowserOriginEviction: false,
    hardChromiumTermination: true,
    samePersistentProfileRelaunched: true,
    chromiumProcessIdentityChanged: true,
    recoveryEnrollmentMode,
    deviceRecordPresentAfterRestart,
    recoveryDeviceIdentityChanged: recoveryEnrollmentMode === 'trusted-device-reenrollment'
      ? recoveryDeviceIdAtLogin !== deviceIdAtRegistration : false,
    workerRouteHits: idbWorkerRouteCount,
    injectedFaultProbe: idbFailureProbeEvidence,
    durableSqliteIntegrity: localAfterAbort.integrityCheck,
    durableRecordAndOutboxCountsUnchanged: true,
    deviceIdentityBeforeFault: storageBeforeFault.deviceRecordPresent,
    visibleRecoverableError: storageError.surfaced,
    currentBundleUiErrorLimitation: storageError.surfaced
      ? null : 'aborted IndexedDB transaction was not surfaced as a visible save error',
    hostEditorVisibleAfterFault: storageError.hostEditorStillVisible,
    failedHostCardVisibleAfterFault: storageError.hostNameVisible,
    addHostRetryActionVisible: storageError.retryActionVisible,
    successNoticeVisibleAfterFault: storageError.saveSuccessNoticeVisible,
    failedHostAbsentAfterRestart: !hostBeforeRetry,
    preRetryServerCommitSeq: serverAfterAbort.commitSeq,
    retryPushCount: idbFailurePushRequestsAfterRetry,
    retryReceiptAlreadyCommitted: idbFailureReceipt.alreadyCommitted,
    serverCounts: {
      receipts: finalServer.receiptCount,
      versions: finalServer.versionCount,
      events: finalServer.eventCount,
      matchingHead: finalServer.headMatches,
      baselineCommitSeq,
      hostCommitSeq: idbFailureReceipt.commitSeq,
    },
    localOutboxAfterRetry: {
      pendingCount: localAfterRetry.pendingCount,
      vaultOperationCount: localAfterRetry.vaultOperationCount,
      recordCommitSeq: localAfterRetry.record.commitSeq,
    },
    browserPageErrors: pageErrorCount,
    secondTabPageErrors: idbSecondPageErrorCount,
  }));
}

async function waitForPendingCount(pageRef, expected, timeoutMs = 30000) {
  let lastCount = null;
  await waitForCondition(async () => {
    lastCount = await visiblePendingCount(pageRef);
    if (lastCount === null) return false;
    return lastCount === expected;
  }, `sync pending count ${expected} (last ${lastCount})`, timeoutMs, pageRef);
}

async function initializeFlutter(pageRef, onDocumentCommit = null) {
  await pageRef.goto(baseUrl, {
    waitUntil: onDocumentCommit ? 'commit' : 'domcontentloaded',
    timeout: 30000,
  });
  if (onDocumentCommit) {
    await onDocumentCommit();
    await pageRef.waitForLoadState('domcontentloaded', { timeout: 30000 });
  }
  await waitForCondition(() => pageRef.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
    'Flutter and sodium startup', 30000, pageRef);
  await pageRef.evaluate(async () => { await window.sodium.ready; });
  await pageRef.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitForCondition(() => pageRef.evaluate(() =>
    document.querySelectorAll('flt-semantics').length > 0),
  'Flutter semantics startup', 15000, pageRef);
}

async function recoverWorkspace(pageRef, timeoutMs = 30000) {
  await selectServerModeIfChooser(pageRef);
  const deadline = Date.now() + timeoutMs;
  let serverConnectionSubmitted = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await pageRef.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) return;
    if (!loginSubmitted && await pageRef.locator(visibleFieldSelector('Email or username'))
      .isVisible().catch(() => false)) {
      setStage('restart: enter account identity');
      await fill(pageRef, 'Email or username', USERNAME);
      setStage('restart: enter account password');
      await fill(pageRef, 'Master password', MASTER_PASSWORD);
      setStage('restart: submit account sign in');
      await click(pageRef, 'Sign in and unlock');
      loginSubmitted = true;
    } else if (!serverConnectionSubmitted && await pageRef.locator(visibleFieldSelector('Server URL'))
      .isVisible().catch(() => false)) {
      // Give saved-session restoration one short turn to settle before acting
      // on a transient server chooser field from the first Flutter frame.
      await pageRef.waitForTimeout(350);
      if (await pageRef.locator(visibleFieldSelector('Email or username'))
        .isVisible().catch(() => false)) continue;
      setStage('restart: enter isolated server URL');
      try {
        await fill(pageRef, 'Server URL', baseUrl);
      } catch (error) {
        const connectionState = await safeConnectionDiagnostic(pageRef);
        await pageRef.screenshot({
          path: path.join(tempRoot, 'server-reconnect-failure.png'),
        }).catch(() => {});
        console.log('restart server URL input safe diagnostic', JSON.stringify({
          errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
          connectionState,
        }));
        throw error;
      }
      setStage('restart: submit isolated server connection');
      try {
        await click(pageRef, 'Connect securely');
      } catch (error) {
        const connectionState = await safeConnectionDiagnostic(pageRef);
        await pageRef.screenshot({
          path: path.join(tempRoot, 'server-reconnect-failure.png'),
        }).catch(() => {});
        console.log('restart server connection safe diagnostic', JSON.stringify({
          errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
          connectionState,
        }));
        throw error;
      }
      serverConnectionSubmitted = true;
    }
    if (await pageRef.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) return;
    await pageRef.waitForTimeout(150);
  }
  const recoveryState = await safeConnectionDiagnostic(pageRef);
  const recoveryStorage = REDACTION_INDEXEDDB_ORDERING
    ? await safeBrowserStorageDiagnostic(pageRef) : null;
  await pageRef.screenshot({
    path: path.join(tempRoot, 'recovery-workspace-failure.png'),
  }).catch(() => {});
  console.log('restart workspace safe diagnostic', JSON.stringify({
    recoveryState,
    recoveryStorage,
  }));
  throw new Error('restart did not return the same persistent profile to its workspace');
}

function serverVaultSnapshot() {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "rows=db.execute(\"SELECT v.vault_id,COALESCE(vc.last_committed_seq,0) FROM users u JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' JOIN vaults v ON v.vault_id=vm.vault_id LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE u.username=? AND v.state='active' ORDER BY v.vault_id\",(sys.argv[2],)).fetchall()",
    "print(json.dumps({'vaults':[{'vaultId':row[0],'commitSeq':str(row[1])} for row in rows]}))",
  ].join(';'), databasePath, USERNAME], {
    encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(result.status === 0, 'read-only Vault snapshot query failed');
  const snapshot = JSON.parse(result.stdout);
  assertThat(Array.isArray(snapshot.vaults) && snapshot.vaults.length === 1,
    'isolated account did not have exactly one active Vault');
  return snapshot.vaults[0];
}

function serverRecordSnapshot(
  operation, baselineCommitSeq, markers = HOST_PLAINTEXT_MARKERS,
) {
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,record,revision,op_id,baseline=sys.argv[2:]',
    'check=json.loads(sys.stdin.read())',
    'markers=check["markers"]',
    "versions=db.execute('SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id,envelope,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "receipts=db.execute('SELECT record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall()",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    'def digest(text):',
    '    value=json.loads(text)',
    '    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()',
    'def safe_envelope(text):',
    '    try: value=json.loads(text)',
    '    except Exception: return False',
    '    allowed_header={"wire_version","server_space_id","vault_id","record_id","revision_id","base_revision_id","op_id","device_id","device_seq","key_epoch","membership_version","record_schema","operation","crypto_suite","kdf_salt","object_refs"}',
    '    header=value.get("header",{}) if isinstance(value,dict) else {}',
    '    return set(value)=={"header","nonce","ciphertext","signature"} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(value.get(k),str) and value[k] for k in ("nonce","ciphertext","signature"))',
    'envelope_text=versions[0][2] if len(versions)==1 else ""',
    'envelope_hash=digest(envelope_text) if envelope_text else None',
    'marker_found=any(marker.encode() in envelope_text.encode() for marker in markers) if envelope_text else False',
    'result={"versionCount":len(versions),"versionMatches":len(versions)==1 and versions[0][0]==revision,"versionCommitSeq":str(versions[0][3]) if len(versions)==1 else None,"versionOperation":versions[0][1] if len(versions)==1 else None,"eventCount":len(events),"eventMatches":len(events)==1 and events[0][0]==revision,"eventCommitSeq":str(events[0][2]) if len(events)==1 else None,"eventEnvelopeHash":digest(events[0][1]) if len(events)==1 else None,"headMatches":bool(head and head[0]==revision and not head[1]),"headDeleted":bool(head and head[1]),"headCommitSeq":str(head[2]) if head else None,"receiptCount":len(receipts),"receiptMatches":len(receipts)==1 and receipts[0][0]==record and receipts[0][1]==revision,"receiptCommitSeq":str(receipts[0][2]) if len(receipts)==1 else None,"commitSeq":str(counter[0]) if counter else None,"expectedCommitSeq":str(int(baseline)+1),"envelopeHash":envelope_hash,"opaqueEnvelope":safe_envelope(envelope_text),"plaintextMarkerFound":marker_found}',
    'print(json.dumps(result))',
  ].join('\n'), databasePath, operation.vaultId, operation.recordId,
  operation.revisionId, operation.opId, String(baselineCommitSeq)], {
    encoding: 'utf8',
    timeout: 10000,
    input: JSON.stringify({ markers }),
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(result.status === 0, 'read-only server record snapshot query failed');
  const snapshot = JSON.parse(result.stdout);
  const byteFindings = serverPlaintextMarkerFindings(markers);
  return { ...snapshot, ...byteFindings };
}

function serverHostUpdateSnapshot(
  baselineOperation, updateOperation, initialCommitSeq,
  markers = HOST_PLAINTEXT_MARKERS,
) {
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,record,baseline_revision,baseline_op,update_revision,update_op,initial=sys.argv[2:]',
    'check=json.loads(sys.stdin.read())',
    'markers=check["markers"]',
    "versions=db.execute('SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id,envelope,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "receipts=db.execute('SELECT op_id,record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id IN (?,?)',(vault,baseline_op,update_op)).fetchall()",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    'def digest(text):',
    '    value=json.loads(text)',
    '    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()',
    'def safe_envelope(text):',
    '    try: value=json.loads(text)',
    '    except Exception: return False',
    '    allowed_header={"wire_version","server_space_id","vault_id","record_id","revision_id","base_revision_id","op_id","device_id","device_seq","key_epoch","membership_version","record_schema","operation","crypto_suite","kdf_salt","object_refs"}',
    '    header=value.get("header",{}) if isinstance(value,dict) else {}',
    '    return set(value)=={"header","nonce","ciphertext","signature"} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(value.get(k),str) and value[k] for k in ("nonce","ciphertext","signature"))',
    'def exact(rows,revision,operation):',
    '    return [row for row in rows if row[0]==revision and (len(row)<2 or row[1]==operation)]',
    'baseline_versions=exact(versions,baseline_revision,"create")',
    'update_versions=exact(versions,update_revision,"update")',
    'baseline_events=[row for row in events if row[0]==baseline_revision]',
    'update_events=[row for row in events if row[0]==update_revision]',
    'baseline_receipts=[row for row in receipts if row[0]==baseline_op and row[1]==record and row[2]==baseline_revision]',
    'update_receipts=[row for row in receipts if row[0]==update_op and row[1]==record and row[2]==update_revision]',
    'baseline_seq=int(initial)+1',
    'update_seq=int(initial)+2',
    'version_envelope=update_versions[0][2] if len(update_versions)==1 else ""',
    'event_envelope=update_events[0][1] if len(update_events)==1 else ""',
    'marker_found=any(marker.encode() in version_envelope.encode() for marker in markers) if version_envelope else False',
    'result={"versionCount":len(versions),"baselineVersionMatches":len(baseline_versions)==1 and int(baseline_versions[0][3])==baseline_seq,"updateVersionMatches":len(update_versions)==1 and int(update_versions[0][3])==update_seq,"updateVersionOperation":update_versions[0][1] if len(update_versions)==1 else None,"eventCount":len(events),"baselineEventMatches":len(baseline_events)==1 and int(baseline_events[0][2])==baseline_seq,"updateEventMatches":len(update_events)==1 and int(update_events[0][2])==update_seq,"updateEventEnvelopeHash":digest(event_envelope) if event_envelope else None,"baselineReceiptCount":len(baseline_receipts),"updateReceiptCount":len(update_receipts),"updateReceiptMatches":len(update_receipts)==1 and int(update_receipts[0][3])==update_seq,"headMatchesBaseline":bool(head and head[0]==baseline_revision and not head[1] and int(head[2])==baseline_seq),"headMatchesUpdate":bool(head and head[0]==update_revision and not head[1] and int(head[2])==update_seq),"headDeleted":bool(head and head[1]),"headCommitSeq":str(head[2]) if head else None,"commitSeq":str(counter[0]) if counter else None,"expectedBaselineCommitSeq":str(baseline_seq),"expectedUpdateCommitSeq":str(update_seq),"updateEnvelopeHash":digest(version_envelope) if version_envelope else None,"opaqueUpdateEnvelope":safe_envelope(version_envelope) if version_envelope else False,"plaintextMarkerFound":marker_found}',
    'print(json.dumps(result,separators=(",",":")))',
  ].join('\n'), databasePath, baselineOperation.vaultId,
  baselineOperation.recordId, baselineOperation.revisionId,
  baselineOperation.opId, updateOperation.revisionId, updateOperation.opId,
  String(initialCommitSeq)], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    input: JSON.stringify({ markers }),
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only Host update server snapshot query failed');
  return {
    ...JSON.parse(result.stdout),
    ...serverPlaintextMarkerFindings(markers),
  };
}

function serverOriginLossSnapshot(vaultId, recordId, baselineRevisionId, lostOpId) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault_id,record_id,baseline_revision,lost_op_id=sys.argv[2:]',
    "versions=db.execute('SELECT revision_id,commit_seq,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id)).fetchall()",
    "events=db.execute('SELECT revision_id,commit_seq,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id)).fetchall()",
    "receipts=db.execute('SELECT count(*) FROM op_receipts WHERE vault_id=? AND op_id=?',(vault_id,lost_op_id)).fetchone()[0]",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault_id,)).fetchone()",
    'def op_ids(rows):',
    '    result=[]',
    '    for row in rows:',
    '        try: result.append(json.loads(row[2]).get("header",{}).get("op_id"))',
    '        except Exception: result.append(None)',
    '    return result',
    'print(json.dumps({"versionCount":len(versions),"versionRevisionIds":[row[0] for row in versions],"versionCommitSeqs":[str(row[1]) for row in versions],"versionOpIds":op_ids(versions),"eventCount":len(events),"eventRevisionIds":[row[0] for row in events],"eventCommitSeqs":[str(row[1]) for row in events],"eventOpIds":op_ids(events),"lostReceiptCount":receipts,"headRevisionId":head[0] if head else None,"headDeleted":bool(head[1]) if head else None,"headCommitSeq":str(head[2]) if head else None,"commitSeq":str(counter[0]) if counter else None,"headMatchesBaseline":bool(head and head[0]==baseline_revision and not head[1])},separators=(",",":")))',
  ].join('\n'), databasePath, vaultId, recordId, baselineRevisionId, lostOpId], {
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only origin-loss server snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverPlaintextMarkerFindings(markers = HOST_PLAINTEXT_MARKERS) {
  const files = ['atermius.db', 'atermius.db-wal', 'atermius.db-shm']
    .map((name) => path.join(dataDir, name))
    .filter((candidate) => fs.existsSync(candidate));
  const buffers = files.map((candidate) => fs.readFileSync(candidate));
  return {
    serverPlaintextMarkerFound: markers.some((marker) =>
      buffers.some((bytes) => bytes.includes(Buffer.from(marker)))),
  };
}

async function attachPageInstrumentation(context, pageRef) {
  if (IDB_WRITE_FAILURE_RETRY || INBOUND_CHANGES_CRASH ||
      REDACTION_INDEXEDDB_ORDERING) {
    await context.addInitScript(({ channelName }) => {
      const channel = new BroadcastChannel(channelName);
      const events = [];
      const counts = Object.create(null);
      const quarantineMessages = [];
      const quarantineChannel = new BroadcastChannel(
        'atermius.database.quarantine.v1',
      );
      quarantineChannel.addEventListener('message', (event) => {
        if (typeof event.data === 'string') quarantineMessages.push(event.data);
      });
      channel.onmessage = (event) => {
        const value = event.data;
        if (!value || typeof value.type !== 'string') return;
        events.push(value);
        counts[value.type] = (counts[value.type] || 0) + 1;
        if (events.length > 1000) events.shift();
      };
      window.__atermiusIdbWriteFailureProbe = {
        arm(options = {}) {
          channel.postMessage({ type: 'arm', ...options });
        },
        continueCommittedCompletion(rearm = false) {
          channel.postMessage({
            type: 'continue-committed-completion',
            rearm: rearm === true,
          });
        },
        continueAbort() {
          channel.postMessage({ type: 'continue-abort' });
        },
        waitFor(type, timeoutMs = 10000) {
          return new Promise((resolve, reject) => {
            const deadline = Date.now() + timeoutMs;
            const poll = () => {
              const existing = events.find((event) => event.type === type);
              if (existing || counts[type] > 0) {
                resolve(existing || { type });
              } else if (Date.now() >= deadline) {
                reject(new Error(`IndexedDB probe event timed out: ${type}`));
              } else {
                setTimeout(poll, 25);
              }
            };
            poll();
          });
        },
        eventTypes() {
          return events.map((event) => event.type);
        },
        eventSummary() {
          return { counts: { ...counts }, recentTypes: events.map((event) => event.type) };
        },
      };
      window.__atermiusDatabaseQuarantineProbe = {
        summary() {
          return {
            messageCount: quarantineMessages.length,
            databaseNames: [...new Set(quarantineMessages)].sort(),
          };
        },
      };
    }, { channelName: IDB_TEST_CHANNEL });

    await context.route('**/drift_worker.js', async (route) => {
      idbWorkerRouteCount += 1;
      try {
        const upstream = await route.fetch();
        const original = await upstream.text();
        const prelude = buildIdbWriteFailureWorkerPrelude(IDB_TEST_CHANNEL);
        const headers = upstream.headers();
        delete headers['content-length'];
        delete headers['content-encoding'];
        delete headers['transfer-encoding'];
        await route.fulfill({ status: upstream.status(), headers, body: prelude + original });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
    });
  }

  pageRef.on('pageerror', () => { pageErrorCount += 1; });
  pageRef.on('console', (message) => {
    const match = message.text().match(/ATERMIUS_DRIFT_WEB_IMPLEMENTATION=(\w+)/);
    if (match) driftImplementation = match[1];
  });
  if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
    pageRef.on('response', (response) => {
      const route = safeApiRouteFamily(response.request());
      if (!route) return;
      const method = response.request().method();
      if (!['GET', 'POST', 'PUT', 'DELETE'].includes(method)) return;
      safeApiLifecycleResponses.push({
        route,
        method,
        status: response.status(),
        failed: false,
        stage: activeStage,
      });
      if (safeApiLifecycleResponses.length > 200) {
        const removed = safeApiLifecycleResponses.length - 200;
        safeApiLifecycleResponses.splice(0, removed);
        safeApiLifecycleCursor = Math.max(0, safeApiLifecycleCursor - removed);
      }
    });
  }
  pageRef.on('requestfailed', (request) => {
    if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
      const route = safeApiRouteFamily(request);
      const method = request.method();
      if (route && ['GET', 'POST', 'PUT', 'DELETE'].includes(method)) {
        safeApiLifecycleResponses.push({
          route,
          method,
          status: null,
          failed: true,
          stage: activeStage,
        });
      }
    }
    if (apiPath(request).endsWith('/sync/push')) {
      let containsCrashOperation = false;
      const expectedOpId = crashOperation?.opId || droppedCommit?.opId;
      try {
        const body = request.postDataJSON();
        containsCrashOperation = Array.isArray(body?.operations) &&
          body.operations.some((envelope) =>
            envelope?.header?.op_id === expectedOpId);
      } catch (_) {}
      if (containsCrashOperation) {
        failedPushRequestCount += 1;
        if (deferredFailureResolve) deferredFailureResolve();
      }
    }
  });
  pageRef.on('request', (request) => {
    if (REDACTION_INDEXEDDB_ORDERING) {
      const pathname = apiPath(request);
      if (pathname === '/api/v1/auth/prelogin' ||
          pathname === '/api/v1/auth/login' ||
          pathname === '/api/v1/auth/refresh') {
        redactionAuthRequestRoutes.push(`${request.method()} ${pathname}`);
      }
      void request.allHeaders().then((headers) => {
        if (!redactionAuthorization &&
            /^Bearer\s+\S+$/i.test(headers.authorization || '')) {
          redactionAuthorization = headers.authorization;
        }
      }).catch(() => {});
    }
    if (gateRestartChangesPage && request.method() === 'GET' &&
        apiPath(request).endsWith('/changes')) {
      restartChangesRequestCount += 1;
    }
    if (apiPath(request) === '/api/v1/auth/register') {
      try {
        const body = request.postDataJSON();
        const candidate = body?.device_id || body?.device?.device_id;
        if (typeof candidate === 'string') deviceIdAtRegistration = candidate;
      } catch (_) {}
    }
    if (apiPath(request) === '/api/v1/auth/login') {
      try {
        const body = request.postDataJSON();
        const candidate = body?.device_id || body?.device?.device_id;
        if (typeof candidate === 'string') deviceIdAtLogin = candidate;
      } catch (_) {}
    }
  });
  if (REDACTION_INDEXEDDB_ORDERING) {
    pageRef.on('response', (response) => {
      const pathname = apiPath(response.request());
      if (pathname === '/api/v1/auth/prelogin' ||
          pathname === '/api/v1/auth/login' ||
          pathname === '/api/v1/auth/refresh') {
        redactionAuthResponseStatuses.push({
          route: pathname,
          status: response.status(),
        });
      }
      if (pathname === '/api/v1/auth/login') {
        redactionLoginStatuses.push(response.status());
      }
      if (pathname === '/api/v1/devices/redaction-capabilities') {
        redactionCapabilityReportStatuses.push(response.status());
      }
    });
  }
  pageRef.on('response', async (response) => {
    const pathname = apiPath(response.request());
    if (!pathname.endsWith('/changes') || response.status() !== 200) return;
    try {
      const body = await response.json();
      for (const event of (Array.isArray(body?.events) ? body.events : [])) {
        const summary = envelopeSummary(event?.envelope, PRIMARY_PLAINTEXT_MARKERS);
        if (summary.opId !== crashOperation?.opId) continue;
        restartChangesMatch = {
          ...summary,
          commitSeq: String(event?.commit_seq ?? ''),
          eventType: event?.event_type,
        };
      }
    } catch (_) {
      // Only safe ID/hash summaries are retained; malformed pulls are ignored
      // and the required matching event assertion will fail at the end.
    }
  });

  await context.route('**/api/v1/vaults/*/changes*', async (route) => {
    if (INBOUND_CHECKPOINT_WRITE_FAILURE &&
        inboundChangesRoutePhase === 'post-checkpoint-abort') {
      inboundPostFaultChangesRequestCount += 1;
      await route.abort('failed').catch(() => {});
      return;
    }
    if (REDACTION_INDEXEDDB_ORDERING && redactionChangesRouteActive) {
      const requestCursor = new URL(route.request().url()).searchParams.get('cursor');
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        const body = JSON.parse(responseBody.toString('utf8'));
        const events = Array.isArray(body?.events) ? body.events : [];
        const expectedRecordId = redactionTarget?.recordId ||
          redactionPurgeResponse?.proof?.record_id;
        const matching = events.filter((event) =>
          event?.event_type === 'record_redacted' &&
          event?.record_id === expectedRecordId);
        if (upstream.status() !== 200 || matching.length === 0) {
          await route.fulfill({ response: upstream, body: responseBody });
          return;
        }
        const pageSummary = {
          requestCursor,
          status: upstream.status(),
          eventCount: events.length,
          redactionMarkerCount: matching.length,
          proof: matching[0]?.redaction,
          proofs: matching.map((event) => event?.redaction),
          hasMore: body?.has_more,
          noMorePages: body?.has_more === false,
          nextCursor: typeof body?.next_cursor === 'string'
            ? body.next_cursor : null,
          serverGeneration: typeof body?.server_generation === 'string'
            ? body.server_generation : null,
        };
        redactionChangesPages.push(pageSummary);
        redactionChangesPageSignal.resolve(pageSummary);
        if (redactionChangesPageHold) {
          await redactionChangesPageRelease.promise;
        }
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_CHANGES_CRASH &&
        inboundChangesRoutePhase === 'pre-crash-wait-for-producer') {
      inboundPreCrashRequestCount += 1;
      const requestCursor = new URL(route.request().url()).searchParams.get('cursor');
      if (inboundPreCrashRequestCount === 1) inboundPreCrashFirstCursor = requestCursor;
      try {
        await inboundProducerRelease.promise;
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        assertThat(upstream.status() === 200,
          'receiver changes request did not return HTTP 200');
        const pageSummary = summarizeInboundChangesPage(
          JSON.parse(responseBody.toString('utf8')),
          inboundProducerOperations,
        );
        assertThat(pageSummary.exactlyTwoEvents && pageSummary.noMorePages &&
          pageSummary.nextCursor,
        'receiver changes response did not contain exactly the two producer events');
        assertThat(requestCursor === (inboundOldCheckpoint?.cursor ?? null),
          'pre-crash changes request did not use the saved old cursor');
        if (INBOUND_OUTBOX_CHECKPOINT_RACE) {
          inboundOutboxRacePageEvidence = {
            requestCursor,
            status: upstream.status(),
            ...pageSummary,
          };
          await inboundOutboxRacePageRelease.promise;
        } else if (!inboundReceiverProbeArmed) {
          inboundReceiverProbeArmed = true;
          setStage('arm the durable inbound event persistence probe');
          await page.evaluate(() => {
            window.__atermiusIdbWriteFailureProbe.arm({
              holdCommittedCallback: true,
            });
          });
          await waitForIdbProbeEvent(page, 'armed', 5000);
        }
        await route.fulfill({ response: upstream, body: responseBody });
        inboundPreCrashPageEvidence = {
          requestCursor,
          status: upstream.status(),
          ...pageSummary,
        };
        inboundPreCrashPageSignal.resolve(inboundPreCrashPageEvidence);
      } catch (error) {
        inboundPreCrashPageEvidence = { failure: 'route-error' };
        inboundPreCrashPageSignal.resolve(inboundPreCrashPageEvidence);
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_OUTBOX_CHECKPOINT_RACE &&
        inboundChangesRoutePhase === 'outbox-race-restart') {
      const requestCursor = new URL(route.request().url()).searchParams.get('cursor');
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        const body = JSON.parse(responseBody.toString('utf8'));
        const events = Array.isArray(body?.events) ? body.events : [];
        assertThat(upstream.status() === 200 && events.length === 0 &&
          body?.has_more === false &&
          requestCursor === inboundOutboxRacePageEvidence?.nextCursor &&
          body?.server_generation === inboundOutboxRacePageEvidence?.serverGeneration &&
          typeof body?.next_cursor === 'string',
        'same-profile restart did not resume after the durable inbound page boundary');
        inboundOutboxRaceRestartPageEvidence = {
          requestCursor,
          status: upstream.status(),
          eventCount: events.length,
          hasMore: body.has_more,
          nextCursor: body.next_cursor,
          serverGeneration: body.server_generation,
        };
        inboundChangesRoutePhase = 'outbox-race-await-push';
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        inboundOutboxRaceRestartPageEvidence = { failure: 'route-error' };
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_OUTBOX_CHECKPOINT_RACE &&
        inboundChangesRoutePhase === 'outbox-race-own-event' &&
        !inboundOutboxRaceOwnEventPageEvidence &&
        inboundOutboxRacePushOperation) {
      const requestCursor = new URL(route.request().url()).searchParams.get('cursor');
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        const body = JSON.parse(responseBody.toString('utf8'));
        const events = Array.isArray(body?.events) ? body.events : [];
        const matching = events.filter((event) => {
          const summary = envelopeSummary(event?.envelope, INBOUND_PLAINTEXT_MARKERS);
          return summary.opId === inboundOutboxRacePushOperation.opId &&
            summary.recordId === inboundOutboxRacePushOperation.recordId &&
            summary.revisionId === inboundOutboxRacePushOperation.revisionId &&
            summary.envelopeSha256 === inboundOutboxRacePushOperation.envelopeSha256;
        });
        assertThat(upstream.status() === 200 && matching.length === 1 &&
          events.length === 1 && body?.has_more === false &&
          body?.server_generation === inboundOutboxRacePageEvidence?.serverGeneration &&
          typeof body?.next_cursor === 'string',
        'post-restart changes page did not contain exactly the local operation once');
        inboundOutboxRaceOwnEventPageEvidence = {
          requestCursor,
          status: upstream.status(),
          eventCount: events.length,
          matchingEventCount: matching.length,
          eventCommitSeq: String(matching[0]?.commit_seq ?? ''),
          nextCursor: body.next_cursor,
          serverGeneration: body.server_generation,
        };
        inboundChangesRoutePhase = 'outbox-race-complete';
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        inboundOutboxRaceOwnEventPageEvidence = { failure: 'route-error' };
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_CHANGES_CRASH &&
        inboundChangesRoutePhase === 'restart-hold-page') {
      inboundReplayRequestCount += 1;
      const requestCursor = new URL(route.request().url()).searchParams.get('cursor');
      if (inboundReplayRequestCount === 1) inboundReplayFirstCursor = requestCursor;
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        assertThat(upstream.status() === 200,
          'restarted changes replay did not return HTTP 200');
        const pageSummary = summarizeInboundChangesPage(
          JSON.parse(responseBody.toString('utf8')),
          inboundProducerOperations,
        );
        assertThat(pageSummary.exactlyTwoEvents && pageSummary.noMorePages &&
          pageSummary.nextCursor,
        'restarted changes page did not replay exactly the two committed events');
        inboundReplayEvidence = {
          requestCursor,
          status: upstream.status(),
          ...pageSummary,
        };
        inboundReplayResponseSignal.resolve(inboundReplayEvidence);
        await inboundReplayResponseRelease.promise;
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (error) {
        inboundReplayEvidence = { failure: 'route-error' };
        inboundReplayResponseSignal.resolve(inboundReplayEvidence);
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (gateRestartChangesPage) restartChangesRouteCount += 1;
    if (!gateRestartChangesPage && blockLostAckChangesBeforeCrash && droppedCommit) {
      preCrashLostAckChangesRequestCount += 1;
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        if (upstream.status() !== 200) {
          await route.fulfill({ response: upstream, body: responseBody });
          return;
        }
        const body = JSON.parse(responseBody.toString('utf8'));
        const events = Array.isArray(body?.events) ? body.events : [];
        const matching = events.some((event) => {
          const summary = envelopeSummary(event?.envelope);
          return summary.opId === droppedCommit.opId &&
            summary.recordId === droppedCommit.recordId &&
            summary.revisionId === droppedCommit.revisionId &&
            summary.envelopeSha256 === droppedCommit.envelopeSha256;
        });
        if (matching) {
          preCrashLostAckChangesMatched = true;
          preCrashLostAckChangesAbortCount += 1;
          await route.abort('failed');
          return;
        }
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (!gateRestartChangesPage || restartChangesGateEvidence || !crashOperation) {
      await route.continue();
      return;
    }
    let upstream;
    try {
      upstream = await route.fetch();
      restartChangesLastStatus = upstream.status();
      const responseBody = await upstream.body();
      if (upstream.status() !== 200) {
        restartChangesNon200Count += 1;
        await route.fulfill({ response: upstream, body: responseBody });
        return;
      }
      const body = JSON.parse(responseBody.toString('utf8'));
      const events = Array.isArray(body?.events) ? body.events : [];
      restartChangesLastEventCount = events.length;
      let matchingEvent;
      for (const event of events) {
        const summary = envelopeSummary(event?.envelope);
        if (summary.opId === crashOperation.opId &&
            summary.recordId === crashOperation.recordId &&
            summary.revisionId === crashOperation.revisionId &&
            summary.envelopeSha256 === crashOperation.envelopeSha256) {
          matchingEvent = {
            ...summary,
            commitSeq: String(event?.commit_seq ?? ''),
            eventType: event?.event_type,
          };
          break;
        }
      }
      if (!matchingEvent) {
        restartChangesNoMatchCount += 1;
        await route.fulfill({ response: upstream, body: responseBody });
        return;
      }

      await waitForCondition(async () =>
        await visiblePendingCount(pageRef) === 1,
      'original Host outbox pending before matching changes page release', 15000);
      const pendingBeforeRelease = await visiblePendingCount(pageRef);
      assertThat(pendingBeforeRelease === 1,
        'original Host outbox was not pending before its matching changes page');
      restartChangesGateEvidence = {
        opId: matchingEvent.opId,
        recordId: matchingEvent.recordId,
        revisionId: matchingEvent.revisionId,
        envelopeSha256: matchingEvent.envelopeSha256,
        commitSeq: matchingEvent.commitSeq,
        pendingBeforeRelease,
      };
      await route.fulfill({ response: upstream, body: responseBody });
    } catch (error) {
      restartChangesRouteFailureCount += 1;
      restartChangesFailureClass = error?.message?.includes('pending count 1')
        ? 'pending-not-one'
        : 'route-error';
      await route.abort('failed').catch(() => {});
    }
  });

  await context.route('**/api/v1/vaults/*/sync/push', async (route) => {
    if (IDB_WRITE_FAILURE_RETRY) idbFailureAllPushRequests += 1;
    if (INBOUND_OUTBOX_CHECKPOINT_RACE &&
        inboundOutboxRacePhase === 'pre-restart') {
      inboundOutboxRacePushRequestCount += 1;
      try {
        const body = route.request().postDataJSON();
        const operations = Array.isArray(body?.operations) ? body.operations : [];
        const summaries = operations.map((envelope) => ({
          ...envelopeSummary(envelope, INBOUND_PLAINTEXT_MARKERS),
          vaultId: envelope?.header?.vault_id || body?.vault_id,
        }));
        if (summaries.length === 1 && !inboundOutboxRacePushOperation) {
          inboundOutboxRacePushOperation = summaries[0];
        }
        await inboundOutboxRacePushRelease.promise;
        await route.abort('failed').catch(() => {});
        inboundOutboxRacePushAbortCount += 1;
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_OUTBOX_CHECKPOINT_RACE &&
        inboundOutboxRacePhase === 'post-restart') {
      inboundOutboxRaceRestartPushCount += 1;
      try {
        const body = route.request().postDataJSON();
        const operations = Array.isArray(body?.operations) ? body.operations : [];
        const summaries = operations.map((envelope) => ({
          ...envelopeSummary(envelope, INBOUND_PLAINTEXT_MARKERS),
          vaultId: envelope?.header?.vault_id || body?.vault_id,
        }));
        const operation = summaries.length === 1 ? summaries[0] : null;
        assertThat(operation &&
          operation.opId === inboundOutboxRacePushOperation?.opId &&
          operation.recordId === inboundOutboxRacePushOperation?.recordId &&
          operation.revisionId === inboundOutboxRacePushOperation?.revisionId &&
          operation.envelopeSha256 === inboundOutboxRacePushOperation?.envelopeSha256 &&
          operation.operation === 'create' && operation.markersAbsent,
        'same-profile restart push changed the retained local operation');
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        const response = JSON.parse(responseBody.toString('utf8'));
        const receipts = Array.isArray(response?.results) ? response.results : [];
        const receipt = receipts.find((item) => item?.op_id === operation.opId &&
          item?.revision_id === operation.revisionId);
        assertThat(upstream.status() === 200 && receipt,
          'same-profile restart push did not receive the original local operation receipt');
        inboundOutboxRacePushReceipt = {
          opId: receipt.op_id,
          revisionId: receipt.revision_id,
          commitSeq: String(receipt.commit_seq),
          alreadyCommitted: receipt.already_committed === true,
        };
        await inboundOutboxRacePushResponseRelease.promise;
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }
    if (INBOUND_CHANGES_CRASH && inboundReceiverArmed) {
      inboundOwnerPushRequestCount += 1;
      await route.abort('failed').catch(() => {});
      return;
    }
    let summaries = [];
    let parsedVaultId;
    let operation;
    try {
      const body = route.request().postDataJSON();
      parsedVaultId = body?.vault_id;
      const operations = Array.isArray(body?.operations) ? body.operations : [];
      summaries = operations.map((envelope) => ({
          ...envelopeSummary(envelope, PRIMARY_PLAINTEXT_MARKERS),
        vaultId: envelope?.header?.vault_id || body?.vault_id,
        batchIdPresent: typeof body?.batch_id === 'string',
      }));
      operation = summaries.length === 1 ? summaries[0] : null;
    } catch (_) {}

    if (REDACTION_INDEXEDDB_ORDERING && summaries.length > 0) {
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.body();
        const body = JSON.parse(responseBody.toString('utf8'));
        const receipts = Array.isArray(body?.results) ? body.results : [];
        if (upstream.status() === 200) {
          for (const summary of summaries) {
            const receipt = receipts.find((candidate) =>
              candidate?.op_id === summary.opId &&
              candidate?.revision_id === summary.revisionId);
            if (!receipt) continue;
            redactionLifecycleOperations.push({
              ...summary,
              vaultId: summary.vaultId || parsedVaultId,
              receipt: {
                opId: receipt.op_id,
                revisionId: receipt.revision_id,
                commitSeq: String(receipt.commit_seq),
                alreadyCommitted: receipt.already_committed === true,
              },
            });
          }
        }
        await route.fulfill({ response: upstream, body: responseBody });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }

    if (UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH &&
        !hostUpdateBaselineOperation && operation?.operation === 'create') {
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.json();
        const receipts = Array.isArray(responseBody?.results)
          ? responseBody.results : [];
        const receipt = receipts.find((candidate) =>
          candidate?.op_id === operation.opId &&
          candidate?.revision_id === operation.revisionId);
        assertThat(upstream.status() === 200 && receipt,
          'Host update recovery baseline did not receive a matching receipt');
        hostUpdateBaselineOperation = {
          ...operation,
          receipt: {
            opId: receipt.op_id,
            revisionId: receipt.revision_id,
            commitSeq: String(receipt.commit_seq),
          },
        };
        if (deferredHostUpdateBaselineResolve) {
          deferredHostUpdateBaselineResolve(hostUpdateBaselineOperation);
        }
        await route.fulfill({ response: upstream, body: JSON.stringify(responseBody) });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }

    if (ORIGIN_LOSS_AFTER_OFFLINE_EDIT && !originLossBaselineOperation &&
        operation?.operation === 'create') {
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.json();
        const receipts = Array.isArray(responseBody?.results)
          ? responseBody.results : [];
        const receipt = receipts.find((candidate) =>
          candidate?.op_id === operation.opId &&
          candidate?.revision_id === operation.revisionId);
        assertThat(upstream.status() === 200 && receipt,
          'owner baseline Host did not receive a matching server receipt');
        originLossBaselineOperation = {
          ...operation,
          receipt: {
            opId: receipt.op_id,
            revisionId: receipt.revision_id,
            commitSeq: String(receipt.commit_seq),
          },
        };
        await route.fulfill({
          response: upstream,
          body: JSON.stringify(responseBody),
        });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }

    if (IDB_WRITE_FAILURE_RETRY) {
      if (!idbFailureRetryEnabled) {
        idbFailurePushRequestsBeforeRetry += 1;
        await route.abort('failed').catch(() => {});
        return;
      }
      if (operation?.operation !== 'create') {
        await route.continue();
        return;
      }
      idbFailurePushRequestsAfterRetry += 1;
      try {
        const upstream = await route.fetch();
        const responseBody = await upstream.json();
        const receipts = Array.isArray(responseBody?.results)
          ? responseBody.results : [];
        const receipt = receipts.find((candidate) =>
          candidate?.op_id === operation.opId &&
          candidate?.revision_id === operation.revisionId);
        if (upstream.status() === 200 && receipt) {
          idbFailureOperation = operation;
          idbFailureReceipt = {
            opId: receipt.op_id,
            revisionId: receipt.revision_id,
            commitSeq: String(receipt.commit_seq),
            alreadyCommitted: receipt.already_committed === true,
          };
        }
        await route.fulfill({ response: upstream, body: JSON.stringify(responseBody) });
      } catch (_) {
        await route.abort('failed').catch(() => {});
      }
      return;
    }

    const expectedUncommittedOperation = UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH
      ? 'update' : 'create';
    if (UNCOMMITTED_BEFORE_CRASH && captureUncommittedOperation &&
        operation?.operation === expectedUncommittedOperation) {
      captureUncommittedOperation = false;
      crashOperation = operation;
      if (deferredCommitResolve) deferredCommitResolve(crashOperation);
      await route.abort('failed').catch(() => {});
      return;
    }

    const knownOperationId = crashOperation?.opId || droppedCommit?.opId;
    const retry = knownOperationId
      ? summaries.find((summary) => summary.opId === knownOperationId)
      : null;
    if (retry) {
      recoveredPushSummaries.push(retry);
      if (UNCOMMITTED_BEFORE_CRASH && allowUncommittedRecoveryPush) {
        uncommittedRecoveryPushCount += 1;
        try {
          const upstream = await route.fetch();
          const responseBody = await upstream.json();
          const receipts = Array.isArray(responseBody?.results)
            ? responseBody.results : [];
          const receipt = receipts.find((candidate) =>
            candidate?.op_id === crashOperation.opId);
          if (upstream.status() === 200 &&
              receipt?.revision_id === crashOperation.revisionId &&
              !uncommittedRecoveryReceipt) {
            uncommittedRecoveryReceipt = {
              opId: receipt.op_id,
              revisionId: receipt.revision_id,
              commitSeq: String(receipt.commit_seq),
              alreadyCommitted: receipt.already_committed === true,
            };
          }
          await route.fulfill({ response: upstream, body: JSON.stringify(responseBody) });
        } catch (_) {
          await route.abort('failed').catch(() => {});
        }
        return;
      }
      await route.abort('failed').catch(() => {});
      return;
    }

    if (!captureLostAcknowledgement || !operation || operation.operation !== 'create') {
      await route.continue();
      return;
    }

    if (droppedCommit) {
      // If an automatic retry races the forced shutdown, stop it before the
      // server. The main process will terminate Chromium immediately below.
      if (operation.opId === droppedCommit.opId) {
        await route.abort('failed').catch(() => {});
        return;
      }
      await route.continue();
      return;
    }

    try {
      const upstream = await route.fetch();
      const responseBody = await upstream.json();
      const receipts = Array.isArray(responseBody?.results) ? responseBody.results : [];
      const receipt = receipts.find((candidate) => candidate?.op_id === operation.opId);
      assertThat(upstream.status() === 200 && receipt?.revision_id === operation.revisionId,
        'server did not commit the intercepted Host operation');
      const receiptSummary = {
        opId: receipt.op_id,
        revisionId: receipt.revision_id,
        commitSeq: String(receipt.commit_seq),
        alreadyCommitted: receipt.already_committed === true,
      };
      droppedCommit = { ...operation, receipt: receiptSummary };
      captureLostAcknowledgement = false;
      blockLostAckChangesBeforeCrash = true;
      if (deferredCommitResolve) deferredCommitResolve(droppedCommit);

      // Deliberately discard the real successful response after the server
      // committed it. This produces the same ambiguous outcome as a lost ACK.
      await route.abort('failed');
      if (deferredAckResolve) deferredAckResolve();
    } catch (_) {
      if (!droppedCommit && deferredCommitReject) {
        deferredCommitReject(new Error('intercepted Host commit failed before a safe receipt'));
      }
      if (deferredAckReject && !droppedCommit) {
        deferredAckReject(new Error('could not drop the browser-facing Host acknowledgement'));
      }
      await route.abort('failed').catch(() => {});
    }
  });
}

async function launchPersistentChromium({ simulateSecureStoreLoss = false } = {}) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  browserContext = await chromium.launchPersistentContext(profileDir, options);
  await browserContext.grantPermissions(['clipboard-read', 'clipboard-write'], {
    origin: baseUrl,
  });
  if (simulateSecureStoreLoss) {
    await browserContext.addInitScript(({ expectedOrigin }) => {
      if (window.location.origin !== expectedOrigin) return;
      let removedDevice = 0;
      let removedSession = 0;
      let removedRefresh = 0;
      const selected = [];
      for (let index = 0; index < window.localStorage.length; index += 1) {
        const key = window.localStorage.key(index) || '';
        if (key.endsWith('.device')) {
          selected.push(key);
          removedDevice += 1;
        } else if (key.includes('.session.')) {
          selected.push(key);
          removedSession += 1;
        } else if (key.includes('.refresh.')) {
          selected.push(key);
          removedRefresh += 1;
        }
      }
      for (const key of selected) window.localStorage.removeItem(key);
      window.__atermiusSecureStoreLossSummary = {
        removedDevice,
        removedSession,
        removedRefresh,
      };
    }, { expectedOrigin: new URL(baseUrl).origin });
  }
  await browserContext.addInitScript(({ expectedOrigin }) => {
    if (window.location.origin !== expectedOrigin) return;
    const kinds = (storage) => {
      const found = new Set();
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key === 'FlutterSecureStorage') found.add('secure-store-key');
        else if (key.endsWith('.device')) found.add('device');
        else if (key.includes('.session.')) found.add('session');
        else if (key.includes('.refresh.')) found.add('refresh');
        else if (key.endsWith('.last-server')) found.add('last-server');
        else if (key.startsWith('FlutterSecureStorage.')) found.add('other-secure-store');
        else found.add('other');
      }
      return [...found].sort();
    };
    const localStorageKinds = kinds(window.localStorage);
    const sessionStorageKinds = kinds(window.sessionStorage);
    window.__atermiusStorageAtDocumentStart = {
      expectedOrigin: true,
      secureContext: window.isSecureContext === true,
      localStorageKinds,
      sessionStorageKinds,
      deviceRecordPresent: localStorageKinds.includes('device') ||
        sessionStorageKinds.includes('device'),
    };
  }, { expectedOrigin: new URL(baseUrl).origin });
  page = browserContext.pages()[0] || await browserContext.newPage();
  await attachPageInstrumentation(browserContext, page);
  return page;
}

async function seedIndexedDbDriftDatabase(context) {
  const seedPage = await context.newPage();
  try {
    await seedPage.goto(`${baseUrl}/health/ready`, {
      waitUntil: 'domcontentloaded', timeout: 10000,
    });
    const result = await seedPage.evaluate(async () => {
      const connection = await new Promise((resolve, reject) => {
        const request = indexedDB.open('atermius_vault', 1);
        request.onupgradeneeded = () => {
          const database = request.result;
          const files = database.createObjectStore('files', { autoIncrement: true });
          files.createIndex('fileName', 'name', { unique: true });
          database.createObjectStore('blocks');
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('IDB seed failed'));
        request.onblocked = () => reject(new Error('IDB seed blocked'));
      });
      const stores = [...connection.objectStoreNames].sort();
      connection.close();
      return {
        databaseName: 'atermius_vault',
        objectStoreNames: stores,
        expectedSchema: JSON.stringify(stores) === JSON.stringify(['blocks', 'files']),
      };
    });
    assertThat(result.expectedSchema,
      'could not create the current Drift IndexedDB files/blocks schema');
    return result;
  } finally {
    await seedPage.close().catch(() => {});
  }
}

async function launchTrustedChromium() {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  trustedContext = await chromium.launchPersistentContext(trustedProfileDir, options);
  await trustedContext.grantPermissions(['clipboard-read', 'clipboard-write'], {
    origin: baseUrl,
  });
  trustedPage = trustedContext.pages()[0] || await trustedContext.newPage();
  trustedPage.on('pageerror', () => { trustedPageErrorCount += 1; });
  trustedPage.on('request', (request) => {
    const pathname = apiPath(request);
    if (pathname === '/api/v1/auth/login') {
      try {
        const body = request.postDataJSON();
        const candidate = body?.device_id || body?.device?.device_id;
        if (typeof candidate === 'string') deviceIdAtTrustedLogin = candidate;
      } catch (_) {}
    }
    if (pathname.endsWith('/sync/push')) trustedSyncPushRequestCount += 1;
  });
  trustedPage.on('response', async (response) => {
    if (REDACTION_INDEXEDDB_ORDERING &&
        apiPath(response.request()) === '/api/v1/devices/redaction-capabilities') {
      trustedRedactionCapabilityReportStatuses.push(response.status());
    }
    if (!(UNCOMMITTED_CREDENTIAL_BEFORE_CRASH ||
        UNCOMMITTED_GROUP_BEFORE_CRASH ||
        UNCOMMITTED_SNIPPET_BEFORE_CRASH ||
        UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH) ||
        !apiPath(response.request()).endsWith('/changes') ||
        response.status() !== 200) return;
    try {
      const body = await response.json();
      for (const event of (Array.isArray(body?.events) ? body.events : [])) {
        const summary = envelopeSummary(event?.envelope, PRIMARY_PLAINTEXT_MARKERS);
        if (UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH &&
            summary.opId === hostUpdateBaselineOperation?.opId) {
          trustedPulledBaselineOperation = {
            ...summary,
            commitSeq: String(event?.commit_seq ?? ''),
            eventType: event?.event_type,
          };
        }
        if (summary.opId !== crashOperation?.opId) continue;
        trustedPulledOperation = {
          ...summary,
          commitSeq: String(event?.commit_seq ?? ''),
          eventType: event?.event_type,
        };
      }
    } catch (_) {
      // Only safe operation/hash metadata is retained for the acceptance.
    }
  });
  return trustedPage;
}

async function connectFreshProfile(pageRef) {
  await initializeFlutter(pageRef);
  await fill(pageRef, 'Server URL', baseUrl);
  await click(pageRef, 'Connect securely');
  await field(pageRef, 'Email or username');
}

async function enrollTrustedRecoveryDevice() {
  setStage('trusted B: launch independent persistent profile');
  await launchTrustedChromium();
  setStage('trusted B: connect to isolated server');
  await connectFreshProfile(trustedPage);
  setStage('trusted B: request device enrollment');
  let enrollmentJson = await requestDeviceEnrollment(trustedPage, TRUSTED_DEVICE_NAME);
  setStage('owner A: approve trusted B device enrollment');
  let approvalJson = await approveEnrollment(page, enrollmentJson);
  enrollmentJson = undefined;
  setStage('trusted B: import approval and sign in');
  await importDeviceApprovalAndSignIn(trustedPage, approvalJson);
  approvalJson = undefined;
  await waitForWorkspace(trustedPage);
  assertThat(trustedPageErrorCount === 0,
    'trusted recovery device raised a browser page error');
}

function originLossHostCard(pageRef, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return pageRef.getByRole('group', {
    name: new RegExp(`^Host: ${escaped}; `),
  }).first();
}

async function waitForOriginLossHost(pageRef, name, expected, timeoutMs = 30000) {
  const card = originLossHostCard(pageRef, name);
  await waitForCondition(async () =>
    await card.isVisible().catch(() => false) === expected,
  `Host visibility ${expected}`, timeoutMs, pageRef);
}

async function runUncommittedHostUpdateCrashAcceptance(initialVault) {
  assertThat(initialVault.vaultId && /^(0|[1-9][0-9]*)$/.test(initialVault.commitSeq),
    'Host update recovery did not receive a canonical initial Vault checkpoint');
  assertThat(/^[0-9a-f-]{36}$/i.test(deviceIdAtTrustedLogin || ''),
    'second profile did not have an approved device identity');

  const baselineSignal = deferred();
  hostUpdateBaselinePromise = baselineSignal.promise;
  deferredHostUpdateBaselineResolve = baselineSignal.resolve;
  setStage('create baseline Host and commit one server version');
  await click(page, 'Hosts');
  await enterHostForm(page, HOST_NAME);
  await click(page, 'Save encrypted host');
  hostUpdateBaselineOperation = await Promise.race([
    hostUpdateBaselinePromise,
    new Promise((_, reject) => setTimeout(() =>
      reject(new Error('baseline Host create did not receive its server receipt')), 45000)),
  ]);
  await waitForOriginLossHost(page, HOST_NAME, true, 30000);
  await waitForPendingCount(page, 0, 30000);
  assertThat(hostUpdateBaselineOperation.operation === 'create' &&
    hostUpdateBaselineOperation.vaultId === initialVault.vaultId &&
    hostUpdateBaselineOperation.receipt.revisionId ===
      hostUpdateBaselineOperation.revisionId &&
    hostUpdateBaselineOperation.receipt.commitSeq ===
      (BigInt(initialVault.commitSeq) + 1n).toString(),
  'baseline Host create did not commit exactly once after the initial Vault state');
  const baselineSnapshot = serverRecordSnapshot(
    hostUpdateBaselineOperation, initialVault.commitSeq, PRIMARY_PLAINTEXT_MARKERS);
  assertThat(baselineSnapshot.versionCount === 1 && baselineSnapshot.versionMatches &&
    baselineSnapshot.versionOperation === 'create' &&
    baselineSnapshot.eventCount === 1 && baselineSnapshot.eventMatches &&
    baselineSnapshot.receiptCount === 1 && baselineSnapshot.receiptMatches &&
    baselineSnapshot.headMatches && !baselineSnapshot.headDeleted &&
    baselineSnapshot.commitSeq === hostUpdateBaselineOperation.receipt.commitSeq &&
    baselineSnapshot.opaqueEnvelope && !baselineSnapshot.plaintextMarkerFound &&
    !baselineSnapshot.serverPlaintextMarkerFound,
  'server did not persist one opaque baseline Host before its update');

  setStage('trusted Profile B pulls and decrypts the baseline Host');
  await click(trustedPage, 'Hosts');
  if (trustedPulledBaselineOperation?.opId !== hostUpdateBaselineOperation.opId) {
    await pullTrustedProfileChanges();
  }
  await waitForOriginLossHost(trustedPage, HOST_NAME, true, 30000);
  await waitForCondition(() =>
    trustedPulledBaselineOperation?.opId === hostUpdateBaselineOperation.opId,
  'Profile B did not observe the exact baseline Host change event', 15000, trustedPage);
  assertThat(trustedPulledBaselineOperation.recordId ===
      hostUpdateBaselineOperation.recordId &&
    trustedPulledBaselineOperation.revisionId ===
      hostUpdateBaselineOperation.revisionId &&
    trustedPulledBaselineOperation.envelopeSha256 ===
      hostUpdateBaselineOperation.envelopeSha256 &&
    trustedPulledBaselineOperation.commitSeq ===
      hostUpdateBaselineOperation.receipt.commitSeq,
  'Profile B baseline pull did not match the committed Host envelope');

  const updateSignal = deferred();
  const acknowledgementSignal = deferred();
  const failedPushSignal = deferred();
  commitPromise = updateSignal.promise;
  acknowledgementDroppedPromise = acknowledgementSignal.promise;
  failedPushPromise = failedPushSignal.promise;
  deferredCommitResolve = updateSignal.resolve;
  deferredCommitReject = updateSignal.reject;
  deferredAckResolve = acknowledgementSignal.resolve;
  deferredAckReject = acknowledgementSignal.reject;
  deferredFailureResolve = failedPushSignal.resolve;
  deferredFailureReject = failedPushSignal.reject;
  captureLostAcknowledgement = false;
  captureUncommittedOperation = true;

  setStage('edit the existing Host and block its uncommitted update push');
  const hostCard = originLossHostCard(page, HOST_NAME);
  await hostCard.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitForSemanticText(page, 'Edit host');
  await fill(page, 'Display name', HOST_UPDATED_NAME);
  await click(page, 'Save encrypted host');
  crashOperation = await Promise.race([
    commitPromise,
    new Promise((_, reject) => setTimeout(() =>
      reject(new Error('browser did not send the local Host update')), 45000)),
  ]);
  await Promise.race([
    failedPushPromise,
    new Promise((_, reject) => setTimeout(() =>
      reject(new Error('browser did not observe the deliberately blocked Host update')), 5000)),
  ]);

  assertThat(crashOperation.operation === 'update' &&
    crashOperation.recordId === hostUpdateBaselineOperation.recordId &&
    crashOperation.baseRevisionId === hostUpdateBaselineOperation.revisionId &&
    crashOperation.revisionId !== hostUpdateBaselineOperation.revisionId &&
    crashOperation.vaultId === initialVault.vaultId &&
    crashOperation.exactEnvelopeShape && crashOperation.ciphertextOnlyHeader &&
    crashOperation.encodedCiphertextFields && crashOperation.markersAbsent &&
    crashOperation.envelopeSha256,
  'captured Host edit was not one opaque update based on the committed Host revision');
  crashOperation.baseEnvelopePresent = true;
  crashOperation.baseEnvelopeSha256 = hostUpdateBaselineOperation.envelopeSha256;
  // Optimistic local revisions have no server commit sequence until the
  // recovered update receives its server receipt.
  crashOperation.expectedCachedCommitSeq = null;

  await waitForOriginLossHost(page, HOST_UPDATED_NAME, true, 30000);
  await waitForPendingCount(page, 1);
  setStage('inspect durable IndexedDB outbox and optimistic Host update');
  localOutboxBeforeCrash = await waitForIndexedDbOutboxState(
    page, crashOperation, 'pending', 20000);
  assertThat(localOutboxBeforeCrash.pendingCount === 1 &&
    localOutboxBeforeCrash.vaultOperationCount === 1 &&
    localOutboxBeforeCrash.pending.status === 'sent' &&
    localOutboxBeforeCrash.pending.baseRevisionId ===
      hostUpdateBaselineOperation.revisionId &&
    localOutboxBeforeCrash.pending.baseEnvelopePresent &&
    localOutboxBeforeCrash.pending.baseEnvelopeSha256 ===
      hostUpdateBaselineOperation.envelopeSha256 &&
    localOutboxBeforeCrash.pending.envelopeSha256 === crashOperation.envelopeSha256 &&
    localOutboxBeforeCrash.record.revisionId === crashOperation.revisionId &&
    localOutboxBeforeCrash.record.commitSeq === null &&
    !localOutboxBeforeCrash.plaintextMarkerFound,
  'real IndexedDB did not durably retain the exact Host update and its baseline');
  const preCrashServer = serverHostUpdateSnapshot(
    hostUpdateBaselineOperation, crashOperation, initialVault.commitSeq,
    PRIMARY_PLAINTEXT_MARKERS);
  assertThat(preCrashServer.versionCount === 1 &&
    preCrashServer.baselineVersionMatches && preCrashServer.eventCount === 1 &&
    preCrashServer.baselineEventMatches && preCrashServer.baselineReceiptCount === 1 &&
    preCrashServer.updateReceiptCount === 0 && preCrashServer.headMatchesBaseline &&
    !preCrashServer.headDeleted && preCrashServer.commitSeq ===
      hostUpdateBaselineOperation.receipt.commitSeq &&
    !preCrashServer.plaintextMarkerFound && !preCrashServer.serverPlaintextMarkerFound,
  'server head or ledger changed before the uncommitted Host update was retried');

  setStage('verify the original device identity and kill Chromium');
  const storageBeforeKill = await safeBrowserStorageDiagnostic(page);
  assertThat(storageBeforeKill.deviceRecordPresent,
    'original Web device key was absent before the update crash');
  await page.waitForTimeout(15000);
  const storageAfterSettle = await safeBrowserStorageDiagnostic(page);
  assertThat(storageAfterSettle.deviceRecordPresent &&
    await visiblePendingCount(page) === 1,
  'Host update outbox or device identity changed before SIGKILL');
  deviceRecordPresentBeforeCrash = true;
  profileDirAtCrash = profileDir;
  const killedProcessGroup = await forceKillChromiumProfile(profileDir);
  browserContext = undefined;
  page = undefined;
  idbSecondPage = undefined;
  allowUncommittedRecoveryPush = true;

  setStage('relaunch the same Chromium profile and replay the exact update');
  await launchPersistentChromium();
  assertThat(profileDir === profileDirAtCrash &&
    chromiumProfileProcessGroup(profileDir) !== killedProcessGroup,
  'Host update recovery did not launch a new process with the same persistent profile');
  let storageAtDocumentStart;
  await initializeFlutter(page, async () => {
    storageAtDocumentStart = await page.evaluate(() =>
      window.__atermiusStorageAtDocumentStart || null);
  });
  const storageAfterRestart = await safeBrowserStorageDiagnostic(page);
  deviceRecordPresentAfterRestart = storageAtDocumentStart?.deviceRecordPresent === true &&
    storageAfterRestart.deviceRecordPresent === true;
  assertThat(deviceRecordPresentAfterRestart,
    'same-profile restart did not preserve the original Web device identity');
  recoveryEnrollmentMode = 'same-device';
  await recoverWorkspace(page);
  await waitForOriginLossHost(page, HOST_UPDATED_NAME, true, 30000);
  await waitForCondition(() => uncommittedRecoveryReceipt !== undefined,
    'same-profile restart did not commit the persisted Host update', 45000, page);
  const expectedUpdateCommitSeq =
    (BigInt(hostUpdateBaselineOperation.receipt.commitSeq) + 1n).toString();
  assertThat(uncommittedRecoveryReceipt.opId === crashOperation.opId &&
    uncommittedRecoveryReceipt.revisionId === crashOperation.revisionId &&
    uncommittedRecoveryReceipt.commitSeq === expectedUpdateCommitSeq &&
    !uncommittedRecoveryReceipt.alreadyCommitted,
  'recovery push did not produce exactly one first receipt for the Host update');
  crashOperation.receipt = uncommittedRecoveryReceipt;
  await waitForPendingCount(page, 0, 45000);
  localOutboxAfterRecovery = await waitForIndexedDbOutboxState(
    page, crashOperation, 'committed', 20000);
  assertThat(localOutboxAfterRecovery.pendingCount === 0 &&
    localOutboxAfterRecovery.vaultOperationCount === 0 &&
    localOutboxAfterRecovery.record.revisionId === crashOperation.revisionId &&
    localOutboxAfterRecovery.record.commitSeq === expectedUpdateCommitSeq &&
    localOutboxAfterRecovery.record.envelopeSha256 === crashOperation.envelopeSha256,
  'same-profile restart did not acknowledge and clear the exact Host update');
  assertThat(deviceIdAtRegistration === crashOperation.deviceId &&
    recoveredPushSummaries.some((summary) =>
      summary.opId === crashOperation.opId &&
      summary.recordId === crashOperation.recordId &&
      summary.revisionId === crashOperation.revisionId &&
      summary.baseRevisionId === hostUpdateBaselineOperation.revisionId &&
      summary.deviceId === crashOperation.deviceId &&
      summary.envelopeSha256 === crashOperation.envelopeSha256),
  'restart did not replay the same signed update operation and base revision');

  const recoveredServer = serverHostUpdateSnapshot(
    hostUpdateBaselineOperation, crashOperation, initialVault.commitSeq,
    PRIMARY_PLAINTEXT_MARKERS);
  assertThat(recoveredServer.versionCount === 2 &&
    recoveredServer.baselineVersionMatches && recoveredServer.updateVersionMatches &&
    recoveredServer.updateVersionOperation === 'update' &&
    recoveredServer.eventCount === 2 && recoveredServer.baselineEventMatches &&
    recoveredServer.updateEventMatches && recoveredServer.baselineReceiptCount === 1 &&
    recoveredServer.updateReceiptCount === 1 &&
    recoveredServer.updateReceiptMatches && recoveredServer.headMatchesUpdate &&
    !recoveredServer.headDeleted && recoveredServer.commitSeq === expectedUpdateCommitSeq &&
    recoveredServer.updateEnvelopeHash === crashOperation.envelopeSha256 &&
    recoveredServer.updateEventEnvelopeHash === crashOperation.envelopeSha256 &&
    recoveredServer.opaqueUpdateEnvelope && !recoveredServer.plaintextMarkerFound &&
    !recoveredServer.serverPlaintextMarkerFound,
  'server ledger did not contain exactly one opaque Host update after restart');

  setStage('approved Profile B pulls and decrypts the recovered Host update');
  const pushCountBeforePull = trustedSyncPushRequestCount;
  await waitForOriginLossHost(trustedPage, HOST_UPDATED_NAME, true, 30000)
    .catch(() => {});
  if (trustedPulledOperation?.opId !== crashOperation.opId) {
    await pullTrustedProfileChanges();
  }
  await waitForCondition(() =>
    trustedPulledOperation?.opId === crashOperation.opId,
  'Profile B did not receive the exact recovered Host update event', 20000, trustedPage);
  assertThat(trustedPulledOperation.recordId === crashOperation.recordId &&
    trustedPulledOperation.revisionId === crashOperation.revisionId &&
    trustedPulledOperation.baseRevisionId === hostUpdateBaselineOperation.revisionId &&
    trustedPulledOperation.envelopeSha256 === crashOperation.envelopeSha256 &&
    trustedPulledOperation.commitSeq === expectedUpdateCommitSeq &&
    trustedPulledOperation.markersAbsent,
  'Profile B pulled a different Host update envelope or revision');
  await waitForOriginLossHost(trustedPage, HOST_UPDATED_NAME, true, 30000);
  const updatedCard = originLossHostCard(trustedPage, HOST_UPDATED_NAME);
  await updatedCard.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitForSemanticText(trustedPage, 'Edit host');
  const displayName = await field(trustedPage, 'Display name');
  await displayName.click();
  await trustedPage.waitForTimeout(150);
  const decryptedName = await displayName.inputValue();
  assertThat(decryptedName === HOST_UPDATED_NAME,
    'Profile B did not decrypt the updated Host display name');
  await click(trustedPage, 'Cancel');
  assertThat(trustedSyncPushRequestCount === pushCountBeforePull,
    'Profile B unexpectedly pushed while pulling the recovered update');
  const serverAfterPull = serverHostUpdateSnapshot(
    hostUpdateBaselineOperation, crashOperation, initialVault.commitSeq,
    PRIMARY_PLAINTEXT_MARKERS);
  assertThat(stableJson(serverAfterPull) === stableJson(recoveredServer),
    'Profile B pull changed the exactly-once Host update ledger');
  assertThat(pageErrorCount === 0 && trustedPageErrorCount === 0,
    'a browser profile raised a page error during Host update recovery');

  console.log('WEB-SYNC-HOST-UPDATE-CRASH-01 safe evidence', JSON.stringify({
    samePersistentProfileRelaunched: true,
    serverUncommittedBeforeCrash: true,
    originalDeviceIdentityPreserved: true,
    updateOperationIdentityStable: true,
    updateBaseRevisionId: crashOperation.baseRevisionId,
    localOutboxBeforeCrash: {
      pendingCount: localOutboxBeforeCrash.pendingCount,
      baseRevisionMatches: localOutboxBeforeCrash.pending.baseRevisionId ===
        hostUpdateBaselineOperation.revisionId,
      baseEnvelopeMatches: localOutboxBeforeCrash.pending.baseEnvelopeSha256 ===
        hostUpdateBaselineOperation.envelopeSha256,
      envelopeSha256: crashOperation.envelopeSha256,
      plaintextMarkerFound: localOutboxBeforeCrash.plaintextMarkerFound,
    },
    localOutboxAfterRecovery: {
      pendingCount: localOutboxAfterRecovery.pendingCount,
      commitSeq: localOutboxAfterRecovery.record.commitSeq,
    },
    server: {
      versions: recoveredServer.versionCount,
      events: recoveredServer.eventCount,
      updateReceipts: recoveredServer.updateReceiptCount,
      headMatchesUpdate: recoveredServer.headMatchesUpdate,
      baselineCommitSeq: hostUpdateBaselineOperation.receipt.commitSeq,
      updateCommitSeq: expectedUpdateCommitSeq,
      opaqueEnvelope: recoveredServer.opaqueUpdateEnvelope,
      plaintextMarkerFound: recoveredServer.plaintextMarkerFound ||
        recoveredServer.serverPlaintextMarkerFound,
    },
    profileBDecryptedUpdatedName: decryptedName === HOST_UPDATED_NAME,
    profileBPushesDuringPull: trustedSyncPushRequestCount - pushCountBeforePull,
    ownerPageErrors: pageErrorCount,
    profileBPageErrors: trustedPageErrorCount,
  }));
}

async function runOriginLossAcceptance(initialVault) {
  const originalBDeviceId = deviceIdAtTrustedLogin;
  assertThat(/^[0-9a-f-]{36}$/i.test(originalBDeviceId || ''),
    'initial B profile did not have a registered device identity');
  setStage('create owner-acknowledged baseline Host');
  await click(page, 'Hosts');
  await enterHostForm(page);
  await click(page, 'Save encrypted host');
  await waitForOriginLossHost(page, HOST_NAME, true, 45000);
  await waitForCondition(() => Boolean(originLossBaselineOperation?.receipt?.commitSeq),
    'owner baseline Host receipt', 30000, page);
  await waitForPendingCount(page, 0, 30000);
  const baselineOperation = originLossBaselineOperation;
  assertThat(baselineOperation.vaultId === initialVault.vaultId &&
    baselineOperation.operation === 'create' &&
    /^[0-9a-f-]{36}$/i.test(baselineOperation.recordId || '') &&
    /^[0-9a-f-]{36}$/i.test(baselineOperation.revisionId || '') &&
    baselineOperation.receipt.revisionId === baselineOperation.revisionId,
  'owner baseline Host operation did not have safe matching identifiers');
  const baselineServer = serverRecordSnapshot(
    baselineOperation, initialVault.commitSeq, ORIGIN_LOSS_PLAINTEXT_MARKERS);
  assertThat(baselineServer.versionCount === 1 && baselineServer.versionMatches &&
    baselineServer.versionOperation === 'create' &&
    baselineServer.versionCommitSeq === baselineOperation.receipt.commitSeq &&
    baselineServer.eventCount === 1 && baselineServer.eventMatches &&
    baselineServer.eventCommitSeq === baselineOperation.receipt.commitSeq &&
    baselineServer.receiptCount === 1 && baselineServer.receiptMatches &&
    baselineServer.receiptCommitSeq === baselineOperation.receipt.commitSeq &&
    baselineServer.headMatches && baselineServer.commitSeq ===
      baselineOperation.receipt.commitSeq &&
    baselineServer.opaqueEnvelope && !baselineServer.plaintextMarkerFound &&
    !baselineServer.serverPlaintextMarkerFound,
  'owner baseline Host was not committed exactly once as an opaque record');

  setStage('sync and verify baseline Host on B');
  await pullTrustedProfileChanges();
  await waitForOriginLossHost(trustedPage, HOST_NAME, true, 45000);
  const baselineLocal = inspectClientOutboxFiles(
    (await readClientDatabaseFromIndexedDb(trustedPage)).sqliteFiles,
    baselineOperation,
    ORIGIN_LOSS_PLAINTEXT_MARKERS,
  );
  assertThat(baselineLocal.integrityCheck === 'ok' &&
    baselineLocal.vaultOperationCount === 0 &&
    baselineLocal.pendingCount === 0 &&
    baselineLocal.record?.revisionId === baselineOperation.revisionId &&
    baselineLocal.record?.envelopeSha256 === baselineOperation.envelopeSha256 &&
    baselineLocal.record?.commitSeq === baselineOperation.receipt.commitSeq &&
    !baselineLocal.plaintextMarkerFound,
  'B did not persist the acknowledged owner baseline before the offline edit');

  setStage('queue exactly one offline Host edit on B');
  await trustedContext.setOffline(true);
  await waitForCondition(() => trustedPage.evaluate(() => navigator.onLine === false),
    'B Chromium offline state', 10000, trustedPage);
  const bPushesBeforeEdit = trustedSyncPushRequestCount;
  const originalCard = originLossHostCard(trustedPage, HOST_NAME);
  await originalCard.waitFor({ state: 'visible', timeout: 20000 });
  await originalCard.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitForSemanticText(trustedPage, 'Edit host');
  await fill(trustedPage, 'Display name', ORIGIN_LOSS_EDIT_NAME);
  await click(trustedPage, 'Save encrypted host');
  await waitForOriginLossHost(trustedPage, ORIGIN_LOSS_EDIT_NAME, true, 30000);
  await waitForPendingCount(trustedPage, 1, 30000);
  await click(trustedPage, 'Sync & conflicts');
  await waitForSemanticText(trustedPage, 'Browser storage');
  await waitForSemanticText(trustedPage,
    'clearing this site’s browser data before sync removes them from this browser.');
  await click(trustedPage, 'Hosts');
  await waitForOriginLossHost(trustedPage, ORIGIN_LOSS_EDIT_NAME, true);
  await trustedPage.waitForTimeout(500);
  const pendingBeforeClear = inspectClientPendingHostOutbox(
    (await readClientDatabaseFromIndexedDb(trustedPage)).sqliteFiles,
    baselineOperation.vaultId,
    baselineOperation.recordId,
  );
  const branchOperation = pendingBeforeClear.pending;
  console.log('origin-loss offline outbox safe evidence', JSON.stringify({
    integrityCheck: pendingBeforeClear.integrityCheck,
    recordPendingCount: pendingBeforeClear.recordPendingCount,
    vaultPendingCount: pendingBeforeClear.vaultPendingCount,
    pending: branchOperation && {
      opId: branchOperation.opId,
      revisionId: branchOperation.revisionId,
      baseRevisionId: branchOperation.baseRevisionId,
      headerBaseRevisionId: branchOperation.headerBaseRevisionId,
      operation: branchOperation.operation,
      status: branchOperation.status,
      envelopeSha256: branchOperation.envelopeSha256,
    },
    record: pendingBeforeClear.record,
    plaintextMarkerFound: pendingBeforeClear.plaintextMarkerFound,
    pushCountUnchanged: trustedSyncPushRequestCount === bPushesBeforeEdit,
    pagePendingCount: await visiblePendingCount(trustedPage),
  }));
  assertThat(pendingBeforeClear.integrityCheck === 'ok' &&
    pendingBeforeClear.recordPendingCount === 1 &&
    pendingBeforeClear.vaultPendingCount === 1 &&
    branchOperation?.status === 'queued' &&
    branchOperation.operation === 'update' &&
    /^[0-9a-f-]{36}$/i.test(branchOperation.opId || '') &&
    /^[0-9a-f-]{36}$/i.test(branchOperation.revisionId || '') &&
    branchOperation.baseRevisionId === baselineOperation.revisionId &&
    branchOperation.headerBaseRevisionId === baselineOperation.revisionId &&
    pendingBeforeClear.record?.revisionId === branchOperation.revisionId &&
    pendingBeforeClear.record?.envelopeSha256 === branchOperation.envelopeSha256 &&
    pendingBeforeClear.record?.commitSeq == null &&
    !pendingBeforeClear.plaintextMarkerFound &&
    trustedSyncPushRequestCount === bPushesBeforeEdit,
  'B did not retain exactly one unpushed encrypted Host edit in IndexedDB');
  const beforeClearServer = serverOriginLossSnapshot(
    baselineOperation.vaultId,
    baselineOperation.recordId,
    baselineOperation.revisionId,
    branchOperation.opId,
  );
  assertThat(beforeClearServer.versionCount === 1 &&
    beforeClearServer.versionRevisionIds[0] === baselineOperation.revisionId &&
    beforeClearServer.eventCount === 1 &&
    beforeClearServer.eventRevisionIds[0] === baselineOperation.revisionId &&
    beforeClearServer.lostReceiptCount === 0 &&
    beforeClearServer.headMatchesBaseline &&
    beforeClearServer.commitSeq === baselineOperation.receipt.commitSeq,
  'offline B edit changed server state before origin loss');

  setStage('clear only B origin through CDP with persistent profile retained');
  const profileIdentityBeforeClear = fs.statSync(trustedProfileDir).ino;
  assertThat(trustedContext.pages().length === 1,
    'B profile had an unexpected extra page before origin clearing');
  await trustedPage.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await trustedPage.waitForTimeout(250);
  const clearSession = await trustedContext.newCDPSession(trustedPage);
  await clearSession.send('Storage.clearDataForOrigin', {
    origin: new URL(baseUrl).origin,
    storageTypes: 'all',
  });
  await clearSession.detach();
  await trustedContext.close();
  trustedContext = undefined;
  trustedPage = undefined;
  const profileRetainedAfterClear = fs.existsSync(trustedProfileDir) &&
    fs.statSync(trustedProfileDir).ino === profileIdentityBeforeClear;
  assertThat(profileRetainedAfterClear,
    'CDP origin clearing removed or replaced B persistent user-data directory');
  await waitForWorkspace(page);
  await waitForOriginLossHost(page, HOST_NAME, true);
  assertThat(pageErrorCount === 0,
    'owner A lost its workspace while B origin data was cleared');

  setStage('relaunch B and request owner-approved device re-enrollment');
  await launchTrustedChromium();
  assertThat(fs.statSync(trustedProfileDir).ino === profileIdentityBeforeClear,
    'B Chromium did not relaunch with the same persistent user-data directory');
  await connectFreshProfile(trustedPage);
  const requestJson = await requestDeviceEnrollment(
    trustedPage, RECOVERY_DEVICE_NAME);
  const approvalJson = await approveEnrollment(page, requestJson);
  await importDeviceApprovalAndSignIn(trustedPage, approvalJson);
  const recoveredDeviceId = deviceIdAtTrustedLogin;
  assertThat(/^[0-9a-f-]{36}$/i.test(recoveredDeviceId || '') &&
    recoveredDeviceId !== originalBDeviceId,
  'B did not enroll a fresh device identity through owner approval');
  const recoveredVault = serverVaultSnapshot();
  assertThat(recoveredVault.vaultId === initialVault.vaultId,
    'B re-enrollment did not return to the original account Vault');

  setStage('verify acknowledged server head restored and lost edit absent');
  await waitForOriginLossHost(trustedPage, HOST_NAME, true, 45000);
  await waitForOriginLossHost(trustedPage, ORIGIN_LOSS_EDIT_NAME, false, 15000);
  await waitForPendingCount(trustedPage, 0, 45000);
  const recoveredLocal = inspectClientOutboxFiles(
    (await readClientDatabaseFromIndexedDb(trustedPage)).sqliteFiles,
    baselineOperation,
    ORIGIN_LOSS_PLAINTEXT_MARKERS,
  );
  assertThat(recoveredLocal.integrityCheck === 'ok' &&
    recoveredLocal.vaultOperationCount === 0 &&
    recoveredLocal.pendingCount === 0 &&
    recoveredLocal.record?.revisionId === baselineOperation.revisionId &&
    recoveredLocal.record?.envelopeSha256 === baselineOperation.envelopeSha256 &&
    recoveredLocal.record?.commitSeq === baselineOperation.receipt.commitSeq &&
    !recoveredLocal.plaintextMarkerFound,
  'B recovery did not restore only the acknowledged server head');
  const finalServer = serverOriginLossSnapshot(
    baselineOperation.vaultId,
    baselineOperation.recordId,
    baselineOperation.revisionId,
    branchOperation.opId,
  );
  const finalOwnerRecord = serverRecordSnapshot(
    baselineOperation, initialVault.commitSeq, ORIGIN_LOSS_PLAINTEXT_MARKERS);
  assertThat(finalServer.versionCount === 1 &&
    finalServer.versionRevisionIds[0] === baselineOperation.revisionId &&
    finalServer.versionOpIds[0] === baselineOperation.opId &&
    finalServer.eventCount === 1 &&
    finalServer.eventRevisionIds[0] === baselineOperation.revisionId &&
    finalServer.eventOpIds[0] === baselineOperation.opId &&
    finalServer.lostReceiptCount === 0 &&
    finalServer.headMatchesBaseline &&
    finalServer.headCommitSeq === baselineOperation.receipt.commitSeq &&
    finalServer.commitSeq === baselineOperation.receipt.commitSeq &&
    finalOwnerRecord.versionCount === 1 && finalOwnerRecord.eventCount === 1 &&
    finalOwnerRecord.receiptCount === 1 && finalOwnerRecord.headMatches &&
    !finalOwnerRecord.serverPlaintextMarkerFound,
  'server retained a version, event, receipt or head for the lost B edit');
  await waitForOriginLossHost(page, HOST_NAME, true);
  assertThat(pageErrorCount === 0 && trustedPageErrorCount === 0,
    'origin-loss recovery raised an uncaught browser page error');

  console.log('WEB-SYNC-ORIGIN-LOSS-01 result', JSON.stringify({
    originLossSimulation: 'CDP Storage.clearDataForOrigin on B only',
    persistentProfileRetained: profileRetainedAfterClear &&
      fs.statSync(trustedProfileDir).ino === profileIdentityBeforeClear,
    ownerAStayedOnline: true,
    freshDeviceApprovedByOwner: recoveredDeviceId !== originalBDeviceId,
    sameVaultAfterEnrollment: recoveredVault.vaultId === initialVault.vaultId,
    offlineOutboxCountBeforeClear: pendingBeforeClear.vaultPendingCount,
    offlineEditWasNeverPushed: trustedSyncPushRequestCount === bPushesBeforeEdit,
    syncHealthExplainedBrowserLocalOutbox: true,
    restoredHostMatchesOwnerHead: recoveredLocal.record?.revisionId ===
      baselineOperation.revisionId,
    lostEditVisibleAfterRecovery: await originLossHostCard(trustedPage,
      ORIGIN_LOSS_EDIT_NAME).isVisible().catch(() => false),
    pendingAfterRecovery: recoveredLocal.vaultOperationCount,
    server: {
      versionCount: finalServer.versionCount,
      eventCount: finalServer.eventCount,
      baselineReceiptCount: finalOwnerRecord.receiptCount,
      lostEditReceiptCount: finalServer.lostReceiptCount,
      headMatchesBaseline: finalServer.headMatchesBaseline,
      commitSeq: finalServer.commitSeq,
    },
    recordId: baselineOperation.recordId,
    baselineRevisionId: baselineOperation.revisionId,
    lostOpId: branchOperation.opId,
    lostRevisionId: branchOperation.revisionId,
    lostEnvelopeSha256: branchOperation.envelopeSha256,
    ownerDeviceId: deviceIdAtRegistration,
    originalBDeviceId,
    recoveredBDeviceId: recoveredDeviceId,
    ownerPageErrors: pageErrorCount,
    bPageErrors: trustedPageErrorCount,
  }));
}

async function prepareForDeviceEnrollment(pageRef) {
  await selectServerModeIfChooser(pageRef);
  if (await pageRef.locator(visibleFieldSelector('Email or username'))
    .isVisible().catch(() => false)) return;
  if (await pageRef.locator(visibleFieldSelector('Server URL'))
    .isVisible().catch(() => false)) {
    await fill(pageRef, 'Server URL', baseUrl);
    await click(pageRef, 'Connect securely');
  }
  await field(pageRef, 'Email or username', 20000);
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    try {
      if (trustedContext) await trustedContext.close().catch(() => {});
      if (browserContext) await browserContext.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailure = true;
    } finally {
      if (tempRoot) {
        try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
        catch (_) { cleanupFailure = true; }
      }
      page = undefined;
      idbSecondPage = undefined;
      browserContext = undefined;
      trustedPage = undefined;
      trustedContext = undefined;
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

let baseUrl;

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'compiled Flutter Web release bundle is missing');
  if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
    const mainBundleSha256 = crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(WEB_ROOT, 'main.dart.js'))).digest('hex');
    console.log(`${PRIMARY_RECORD_TYPE} runner Web bundle identity`, JSON.stringify({
      mainDartJsSha256: mainBundleSha256,
    }));
  }
  assertThat(fs.existsSync(SERVER_BINARY),
    `server binary missing at ${SERVER_BINARY}; build it before running the suite`);

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-sync-crash-'));
  dataDir = path.join(tempRoot, 'data');
  profileDir = path.join(tempRoot, 'chromium-profile');
  trustedProfileDir = path.join(tempRoot, 'trusted-chromium-profile');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(profileDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(trustedProfileDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  fs.chmodSync(profileDir, 0o700);
  fs.chmodSync(trustedProfileDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  const port = await unusedLoopbackPort();
  baseUrl = `http://127.0.0.1:${port}`;
  const databaseUrl = `sqlite://${databasePath}?mode=rwc`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: databaseUrl,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };

  try {
    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT, env: serverEnv, detached: true, stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrap.error && bootstrap.status === 0,
      'isolated server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
      'isolated server bootstrap token is unavailable');
    bootstrap.stdout = '';

    setStage('persistent Chromium launch and Flutter startup');
    await launchPersistentChromium();
    if (SEED_SHARED_IDB) {
      setStage('seed disposable profile for the safe shared IndexedDB backend');
      const storageSeed = await seedIndexedDbDriftDatabase(browserContext);
      console.log('isolated Web IndexedDB backend seed', JSON.stringify(storageSeed));
    }
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await waitForCondition(() => page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))),
    'Flutter and sodium startup', 30000);
    await page.evaluate(async () => { await window.sodium.ready; });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await waitForCondition(() => page.evaluate(() =>
      document.querySelectorAll('flt-semantics').length > 0),
    'Flutter semantics startup', 15000);

    setStage('configure isolated server and register the first trusted device');
    setStage('registration: enter isolated server URL');
    await fill(page, 'Server URL', baseUrl);
    setStage('registration: connect to isolated server');
    await click(page, 'Connect securely');
    setStage('registration: wait for owner email field');
    await field(page, 'Owner email');
    setStage('registration: enter owner email');
    await fill(page, 'Owner email', USERNAME);
    setStage('registration: enter master password');
    await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
    setStage('registration: confirm master password');
    await fill(page, 'Confirm master password', MASTER_PASSWORD);
    setStage('registration: enter bootstrap token');
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    setStage('registration: enter first device name');
    await fill(page, 'Device name', DEVICE_NAME);
    setStage('registration: enter first Vault name');
    await fill(page, 'First Vault', VAULT_NAME);
    setStage('registration: submit owner registration');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    await waitForWorkspace(page);
    assertThat(pageErrorCount === 0, 'registration raised a browser page error');

    await enrollTrustedRecoveryDevice();
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      await logUncommittedPersistenceCheckpoint('after device registration');
    }

    setStage(IDB_WRITE_FAILURE_RETRY
      ? 'capture baseline after owner registration'
      : 'capture baseline after trusted-device enrollment');
    if (SEED_SHARED_IDB) {
      await waitForCondition(() => driftImplementation === 'sharedIndexedDb',
        'Web did not select the seeded safe shared IndexedDB backend', 15000);
    }
    const initialVault = serverVaultSnapshot();
    const baselineCommitSeq = initialVault.commitSeq;
    assertThat(/^(0|[1-9][0-9]*)$/.test(baselineCommitSeq),
      'initial Vault commit sequence was not canonical');

    if (ORIGIN_LOSS_AFTER_OFFLINE_EDIT) {
      await runOriginLossAcceptance(initialVault);
      console.log('WEB-SYNC-ORIGIN-LOSS-01 passed');
      return;
    }

    if (UNCOMMITTED_HOST_UPDATE_BEFORE_CRASH) {
      await runUncommittedHostUpdateCrashAcceptance(initialVault);
      console.log('WEB-SYNC-HOST-UPDATE-CRASH-01 passed');
      return;
    }

    if (REDACTION_INDEXEDDB_ORDERING) {
      await runRecordRedactionIndexedDbAcceptance(initialVault);
      console.log('WEB-SYNC-REDACTION-IDB-01 passed');
      return;
    }

    if (INBOUND_CHANGES_CRASH) {
      await runInboundChangesCrashAcceptance(initialVault);
      console.log(INBOUND_OUTBOX_CHECKPOINT_RACE
        ? 'WEB-SYNC-OUTBOX-CHECKPOINT-RACE-01 passed'
        : INBOUND_CHECKPOINT_WRITE_FAILURE
          ? 'WEB-SYNC-CHECKPOINT-FAULT-01 passed (checkpoint write abort and replay)'
          : 'WEB-SYNC-CRASH-01 passed (inbound changes crash recovery)');
      return;
    }

    if (IDB_WRITE_FAILURE_RETRY) {
      await runIdbWriteFailureRetryAcceptance(baselineCommitSeq);
      return;
    }

    setStage(UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
      ? 'arm single Password Credential outbox interception'
      : UNCOMMITTED_GROUP_BEFORE_CRASH
        ? 'arm single Group outbox interception'
        : UNCOMMITTED_SNIPPET_BEFORE_CRASH
          ? 'arm single Snippet outbox interception'
          : 'arm single Host lost-ack interception');
    const commitSignal = deferred();
    const ackSignal = deferred();
    const failedPushSignal = deferred();
    commitPromise = commitSignal.promise;
    acknowledgementDroppedPromise = ackSignal.promise;
    failedPushPromise = failedPushSignal.promise;
    deferredCommitResolve = commitSignal.resolve;
    deferredCommitReject = commitSignal.reject;
    deferredAckResolve = ackSignal.resolve;
    deferredAckReject = ackSignal.reject;
    deferredFailureResolve = failedPushSignal.resolve;
    deferredFailureReject = failedPushSignal.reject;
    captureLostAcknowledgement = !UNCOMMITTED_BEFORE_CRASH;
    captureUncommittedOperation = UNCOMMITTED_BEFORE_CRASH;

    setStage(UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
      ? 'save Password Credential locally and block its first server push'
      : UNCOMMITTED_GROUP_BEFORE_CRASH
        ? 'save Group locally and block its first server push'
        : UNCOMMITTED_SNIPPET_BEFORE_CRASH
          ? 'save Snippet locally and block its first server push'
        : UNCOMMITTED_BEFORE_CRASH
          ? 'save Host locally and block its first server push'
          : 'save Host locally and wait for server commit with dropped response');
    if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH) {
      await click(page, 'Credentials');
      await waitForSemanticText(page, 'SSH credentials');
      await click(page, 'Add credential');
      await waitForSemanticText(page, 'New SSH credential');
      await fill(page, 'Credential name', CREDENTIAL_NAME);
      await fill(page, 'SSH username', CREDENTIAL_USERNAME);
      await fill(page, 'Password', CREDENTIAL_PASSWORD);
      await click(page, 'Save encrypted credential');
    } else if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
      await click(page, 'Groups');
      await waitForSemanticText(page, 'Host groups');
      await click(page, 'New group');
      await waitForSemanticText(page, 'New host group');
      await fill(page, 'Group name', GROUP_NAME);
      await click(page, 'Save encrypted group');
    } else if (UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      await click(page, 'Snippets');
      await waitForSemanticText(page, 'Command snippets');
      await click(page, 'New snippet');
      await waitForSemanticText(page, 'New command snippet');
      await fill(page, 'Title', SNIPPET_TITLE);
      await fill(page, 'Script body', SNIPPET_BODY);
      await click(page, 'Save snippet');
    } else {
      await click(page, 'Add host');
      await waitForSemanticText(page, 'Add a host');
      await fill(page, 'Display name', HOST_NAME);
      await fill(page, 'Hostname or IP', HOST_ADDRESS);
      await fill(page, 'Port', '22');
      await fill(page, 'SSH username', HOST_USERNAME);
      await click(page, 'Save encrypted host');
    }
    crashOperation = await Promise.race([
      commitPromise,
      new Promise((_, reject) => setTimeout(() =>
        reject(new Error(UNCOMMITTED_BEFORE_CRASH
          ? `browser did not send the intercepted local ${PRIMARY_RECORD_TYPE} operation`
          : 'server did not commit the intercepted Host push')), 45000)),
    ]);
    if (!UNCOMMITTED_BEFORE_CRASH) await acknowledgementDroppedPromise;
    await Promise.race([
      failedPushPromise,
      new Promise((_, reject) => setTimeout(() =>
        reject(new Error(UNCOMMITTED_BEFORE_CRASH
          ? 'browser did not observe the deliberately blocked local push'
          : 'browser did not observe the deliberately dropped push response')), 5000)),
    ]);
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      await logUncommittedPersistenceCheckpoint(
        `after blocked ${PRIMARY_RECORD_TYPE} push`);
    }
    assertThat(crashOperation.operation === 'create' &&
      crashOperation.recordId && crashOperation.revisionId && crashOperation.opId &&
      crashOperation.vaultId === initialVault.vaultId &&
      crashOperation.exactEnvelopeShape && crashOperation.ciphertextOnlyHeader &&
      crashOperation.encodedCiphertextFields && crashOperation.markersAbsent &&
      crashOperation.envelopeSha256,
    `intercepted ${PRIMARY_RECORD_TYPE} request was not a single opaque encrypted envelope`);
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      assertThat(typeof deviceIdAtRegistration === 'string' &&
        deviceIdAtRegistration.length > 0 &&
        crashOperation.deviceId === deviceIdAtRegistration,
      `original ${PRIMARY_RECORD_TYPE} envelope device ID did not match the registered device identity`);
    }
    if (!UNCOMMITTED_BEFORE_CRASH) {
      assertThat(crashOperation.receipt.opId === crashOperation.opId &&
        crashOperation.receipt.revisionId === crashOperation.revisionId &&
        crashOperation.receipt.commitSeq === (BigInt(baselineCommitSeq) + 1n).toString() &&
        !crashOperation.receipt.alreadyCommitted,
      'isolated server receipt did not prove exactly one new Host commit before the crash');
    }
    await waitForSemanticText(page, PRIMARY_RECORD_NAME);
    await waitForPendingCount(page, 1);
    if (UNCOMMITTED_BEFORE_CRASH) {
      setStage('inspect the actual IndexedDB SQLite outbox before termination');
      localOutboxBeforeCrash = await waitForIndexedDbOutboxState(
        page, crashOperation, 'pending', 20000);
      assertThat(localOutboxBeforeCrash.pendingCount === 1 &&
        localOutboxBeforeCrash.vaultOperationCount === 1 &&
        localOutboxBeforeCrash.pending.status === 'sent' &&
        localOutboxBeforeCrash.pending.envelopeSha256 === crashOperation.envelopeSha256 &&
        localOutboxBeforeCrash.record.commitSeq === null,
      `actual IndexedDB did not retain the exact server-uncommitted ${PRIMARY_RECORD_TYPE} outbox row`);
    }

    setStage('confirm Web device key is stored before hard termination');
    const storageBeforeKill = await safeBrowserStorageDiagnostic(page);
    console.log('Web storage before Chromium termination',
      JSON.stringify(storageBeforeKill));
    assertThat(storageBeforeKill.deviceRecordPresent,
      'registered Web device key was absent before Chromium termination');
    setStage('allow browser secure-store writes to settle before hard termination');
    await page.waitForTimeout(15000);
    const storageAfterSettle = await safeBrowserStorageDiagnostic(page);
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      await logUncommittedPersistenceCheckpoint('after 15-second settle');
    }
    console.log('Web storage after secure-store settle',
      JSON.stringify(storageAfterSettle));
    assertThat(storageAfterSettle.deviceRecordPresent,
      'registered Web device key disappeared before Chromium termination');
    deviceRecordPresentBeforeCrash = storageAfterSettle.deviceRecordPresent;
    const pendingAfterSettle = await visiblePendingCount(page);
    assertThat(pendingAfterSettle === 1,
      `${PRIMARY_RECORD_TYPE} outbox reconciled before the forced Chromium termination`);

    setStage(UNCOMMITTED_BEFORE_CRASH
      ? `verify no ${PRIMARY_RECORD_TYPE} server receipt exists then SIGKILL isolated Chromium`
      : 'verify committed ciphertext then SIGKILL isolated Chromium');
    const beforeCrashServer = serverRecordSnapshot(
      crashOperation, baselineCommitSeq, PRIMARY_PLAINTEXT_MARKERS);
    if (UNCOMMITTED_BEFORE_CRASH) {
      assertThat(beforeCrashServer.versionCount === 0 &&
        beforeCrashServer.eventCount === 0 && beforeCrashServer.receiptCount === 0 &&
        !beforeCrashServer.headMatches && !beforeCrashServer.headDeleted &&
        beforeCrashServer.commitSeq === baselineCommitSeq,
      'the blocked local operation unexpectedly committed before Chromium termination');
    } else {
      assertThat(beforeCrashServer.versionCount === 1 && beforeCrashServer.versionMatches &&
        beforeCrashServer.versionCommitSeq === beforeCrashServer.expectedCommitSeq &&
        beforeCrashServer.eventCount === 1 && beforeCrashServer.eventMatches &&
        beforeCrashServer.eventCommitSeq === beforeCrashServer.expectedCommitSeq &&
        beforeCrashServer.receiptCount === 1 && beforeCrashServer.receiptMatches &&
        beforeCrashServer.receiptCommitSeq === beforeCrashServer.expectedCommitSeq &&
        beforeCrashServer.headMatches && !beforeCrashServer.headDeleted &&
        beforeCrashServer.headCommitSeq === beforeCrashServer.expectedCommitSeq &&
        beforeCrashServer.commitSeq === beforeCrashServer.expectedCommitSeq &&
        beforeCrashServer.envelopeHash === crashOperation.envelopeSha256 &&
        beforeCrashServer.eventEnvelopeHash === crashOperation.envelopeSha256 &&
        beforeCrashServer.opaqueEnvelope && !beforeCrashServer.plaintextMarkerFound &&
        !beforeCrashServer.serverPlaintextMarkerFound,
      'server did not persist exactly one opaque Host operation before Chromium termination');
    }
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      const storageImmediatelyBeforeKill = await logUncommittedPersistenceCheckpoint(
        'after server snapshot, immediately before SIGKILL');
      assertThat(storageImmediatelyBeforeKill.deviceRecordPresent,
        `${PRIMARY_RECORD_TYPE} device key disappeared before the SIGKILL boundary`);

      setStage(`release the ${PRIMARY_RECORD_TYPE} app page localStorage binding`);
      const appPageFingerprint = localStorageLevelDbFingerprint(profileDir);
      await page.goto('about:blank', { waitUntil: 'load', timeout: 10000 });
      const appPageUnbind = await waitForLocalStorageLevelDbCommit(
        profileDir, appPageFingerprint, {
          requireChange: UNCOMMITTED_GROUP_BEFORE_CRASH,
          timeoutMs: 5000,
        });
      console.log(`${PRIMARY_RECORD_TYPE} app-page storage-unbind barrier`, JSON.stringify({
        navigatedToBlank: page.url() === 'about:blank',
        ...appPageUnbind,
        localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
      }));
      assertThat(page.url() === 'about:blank' && appPageUnbind.stable &&
        (UNCOMMITTED_SNIPPET_BEFORE_CRASH || appPageUnbind.changed),
      `${PRIMARY_RECORD_TYPE} app-page storage unbind did not reach a stable Local Storage LevelDB state`);

      setStage(`read ${PRIMARY_RECORD_TYPE} storage from a fresh same-origin page`);
      const storageBarrierPage = await browserContext.newPage();
      await storageBarrierPage.goto(`${baseUrl}/health/ready`, {
        waitUntil: 'domcontentloaded', timeout: 10000,
      });
      const storageBarrierDocumentStart = await storageBarrierPage.evaluate(() =>
        window.__atermiusStorageAtDocumentStart || null);
      const storageAfterAppPageUnbind = await safeBrowserStorageDiagnostic(
        storageBarrierPage);
      console.log(`${PRIMARY_RECORD_TYPE} same-origin storage after app-page unbind`, JSON.stringify({
        documentStart: storageBarrierDocumentStart,
        current: storageAfterAppPageUnbind,
      }));
      assertThat(storageAfterAppPageUnbind.expectedOrigin === true &&
        storageAfterAppPageUnbind.secureContext === true &&
        storageAfterAppPageUnbind.deviceRecordPresent === true &&
        storageBarrierDocumentStart?.deviceRecordPresent === true,
      `same-origin page did not reload the original ${PRIMARY_RECORD_TYPE} secure-store device marker after unbind`);

      const outboxAfterStorageUnbind = await waitForIndexedDbOutboxState(
        storageBarrierPage, crashOperation, 'pending', 20000);
      assertThat(outboxAfterStorageUnbind.pendingCount === 1 &&
        outboxAfterStorageUnbind.vaultOperationCount === 1 &&
        outboxAfterStorageUnbind.pending.opId === crashOperation.opId &&
        outboxAfterStorageUnbind.pending.envelopeSha256 ===
          crashOperation.envelopeSha256 &&
        outboxAfterStorageUnbind.record.commitSeq === null,
      `storage-unbind barrier changed the pending ${PRIMARY_RECORD_TYPE} outbox operation`);
      console.log(`${PRIMARY_RECORD_TYPE} outbox after storage-unbind barrier`, JSON.stringify({
        pendingCount: outboxAfterStorageUnbind.pendingCount,
        vaultOperationCount: outboxAfterStorageUnbind.vaultOperationCount,
        operationMatches: outboxAfterStorageUnbind.pending.opId ===
          crashOperation.opId,
        envelopeHashMatches: outboxAfterStorageUnbind.pending.envelopeSha256 ===
          crashOperation.envelopeSha256,
        noServerCommit: outboxAfterStorageUnbind.record.commitSeq === null,
      }));

      setStage(`release the ${PRIMARY_RECORD_TYPE} storage probe page binding`);
      const probePageFingerprint = localStorageLevelDbFingerprint(profileDir);
      await storageBarrierPage.goto('about:blank', {
        waitUntil: 'load', timeout: 10000,
      });
      const probePageUnbind = await waitForLocalStorageLevelDbCommit(
        profileDir, probePageFingerprint, { requireChange: false, timeoutMs: 1000 });
      console.log(`${PRIMARY_RECORD_TYPE} probe-page storage-unbind barrier`, JSON.stringify({
        navigatedToBlank: storageBarrierPage.url() === 'about:blank',
        ...probePageUnbind,
        localStorageLevelDb: safeLocalStorageLevelDbMetadata(profileDir),
      }));
      assertThat(storageBarrierPage.url() === 'about:blank' && probePageUnbind.stable,
        `read-only ${PRIMARY_RECORD_TYPE} storage probe did not release its origin binding to a stable state`);

      setStage(`reconfirm no ${PRIMARY_RECORD_TYPE} commit after storage-unbind barriers`);
      const serverAfterStorageUnbind = serverRecordSnapshot(
        crashOperation, baselineCommitSeq, PRIMARY_PLAINTEXT_MARKERS);
      assertThat(serverAfterStorageUnbind.versionCount === 0 &&
        serverAfterStorageUnbind.eventCount === 0 &&
        serverAfterStorageUnbind.receiptCount === 0 &&
        !serverAfterStorageUnbind.headMatches &&
        !serverAfterStorageUnbind.headDeleted &&
        serverAfterStorageUnbind.commitSeq === baselineCommitSeq,
      `the storage-unbind barrier unexpectedly committed the pending ${PRIMARY_RECORD_TYPE} operation`);
      profileDirAtCrash = profileDir;
    }
    if (!UNCOMMITTED_GROUP_BEFORE_CRASH) profileDirAtCrash = profileDir;
    const killedProcessGroup = await forceKillChromiumProfile(profileDir);
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      console.log(`${PRIMARY_RECORD_TYPE} Local Storage LevelDB after SIGKILL safe metadata`,
        JSON.stringify(safeLocalStorageLevelDbMetadata(profileDir)));
    }
    blockLostAckChangesBeforeCrash = false;
    // Do not close the disconnected Playwright context: doing so may perform
    // normal shutdown cleanup against the exact persistence boundary tested.
  browserContext = undefined;
  page = undefined;
  idbSecondPage = undefined;

    restartChangesMatch = null;
    restartChangesGateEvidence = undefined;
    gateRestartChangesPage = !UNCOMMITTED_BEFORE_CRASH;
    allowUncommittedRecoveryPush = UNCOMMITTED_BEFORE_CRASH;
    setStage(SIMULATE_SECURE_STORE_LOSS
      ? 'simulate Web device/session secure-store loss during restarted app startup'
      : 'relaunch the same persistent Chromium profile');
    await launchPersistentChromium({
      simulateSecureStoreLoss: SIMULATE_SECURE_STORE_LOSS,
    });
    assertThat(profileDir === profileDirAtCrash,
      'Chromium restart did not reuse the exact persistent Profile directory');
    const relaunchedProcessGroup = chromiumProfileProcessGroup(profileDir);
    assertThat(relaunchedProcessGroup !== killedProcessGroup,
      'Chromium restart reused the terminated process group');
    let storageImmediatelyAfterRestart;
    let storageAtDocumentStart;
    let secureStoreLossSummary;
    await initializeFlutter(page, async () => {
      storageAtDocumentStart = await page.evaluate(() =>
        window.__atermiusStorageAtDocumentStart || null);
      storageImmediatelyAfterRestart = await safeBrowserStorageDiagnostic(page);
      if (SIMULATE_SECURE_STORE_LOSS) {
        secureStoreLossSummary = await page.evaluate(() =>
          window.__atermiusSecureStoreLossSummary || null);
      }
      console.log('Web storage at restart document start',
        JSON.stringify(storageAtDocumentStart));
      console.log('Web storage after Chromium restart before Flutter startup',
        JSON.stringify(storageImmediatelyAfterRestart));
    });
    assertThat(storageImmediatelyAfterRestart?.expectedOrigin === true,
      'restarted browser storage probe did not use the original origin');
    if (SIMULATE_SECURE_STORE_LOSS) {
      console.log('simulated Web secure-store loss summary', JSON.stringify({
        ...secureStoreLossSummary,
        deviceRecordPresent: storageImmediatelyAfterRestart.deviceRecordPresent,
        localStorageKinds: storageImmediatelyAfterRestart.localStorageKinds,
      }));
      assertThat(secureStoreLossSummary?.removedDevice > 0 &&
        secureStoreLossSummary?.removedSession > 0 &&
        secureStoreLossSummary?.removedRefresh > 0 &&
        !storageImmediatelyAfterRestart.deviceRecordPresent,
      'secure-store loss simulation did not remove device and session entries');
    }
    setStage('inspect Web device key after Chromium restart');
    const storageAfterFlutterStartup = await safeBrowserStorageDiagnostic(page);
    console.log('Web storage after Flutter startup',
      JSON.stringify(storageAfterFlutterStartup));
    deviceRecordPresentAfterRestart =
      storageAtDocumentStart?.deviceRecordPresent === true &&
      storageAfterFlutterStartup.deviceRecordPresent === true;
    if ((UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) &&
        !SIMULATE_SECURE_STORE_LOSS) {
      assertThat(storageAtDocumentStart?.expectedOrigin === true &&
        storageAtDocumentStart.deviceRecordPresent === true &&
        storageAfterFlutterStartup.deviceRecordPresent === true,
      `default ${PRIMARY_RECORD_TYPE} crash recovery lost the original Web device identity`);
    }
    if (deviceRecordPresentAfterRestart) {
      recoveryEnrollmentMode = 'same-device';
      setStage('recover original Web device session');
      await recoverWorkspace(page);
    } else {
      recoveryEnrollmentMode = 'trusted-device-reenrollment';
      setStage('restart A: connect and request trusted-device recovery enrollment');
      await prepareForDeviceEnrollment(page);
      let enrollmentJson = await requestDeviceEnrollment(page, RECOVERY_DEVICE_NAME);
      setStage('trusted B: approve restarted A enrollment');
      let approvalJson = await approveEnrollment(trustedPage, enrollmentJson);
      enrollmentJson = undefined;
      setStage('restart A: import trusted approval and sign in');
      deviceIdAtLogin = undefined;
      await importDeviceApprovalAndSignIn(page, approvalJson);
      approvalJson = undefined;
      recoveryDeviceIdAtLogin = deviceIdAtLogin;
      await waitForWorkspace(page);
      assertThat(trustedPageErrorCount === 0,
        'trusted recovery device raised a browser page error');
    }
    if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH) {
      await click(page, 'Credentials');
    } else if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
      await click(page, 'Groups');
    } else if (UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      await click(page, 'Snippets');
    }
    await waitForSemanticText(page, PRIMARY_RECORD_NAME);

    if (UNCOMMITTED_BEFORE_CRASH) {
      setStage('verify restart submits the persisted uncommitted operation');
      await waitForCondition(() => uncommittedRecoveryReceipt !== undefined,
      'restarted Web client did not commit the persisted record operation', 45000);
      assertThat(uncommittedRecoveryReceipt.opId === crashOperation.opId &&
        uncommittedRecoveryReceipt.revisionId === crashOperation.revisionId &&
        uncommittedRecoveryReceipt.commitSeq ===
          (BigInt(baselineCommitSeq) + 1n).toString() &&
        !uncommittedRecoveryReceipt.alreadyCommitted,
      'restart push did not produce the first server receipt for the exact local operation');
      crashOperation.receipt = uncommittedRecoveryReceipt;
      await waitForPendingCount(page, 0, 45000);
    } else {
      setStage('verify restart reconciled the original changes envelope');
      try {
        await waitForCondition(() => restartChangesMatch !== null &&
          restartChangesGateEvidence !== undefined,
        'restart changes pull did not pass the committed original envelope gate', 30000);
      } catch (error) {
        const diagnostic = {
          recoveryEnrollmentMode,
          changesRequestCount: restartChangesRequestCount,
          changesRouteCount: restartChangesRouteCount,
          non200Count: restartChangesNon200Count,
          noMatchingEventCount: restartChangesNoMatchCount,
          routeFailureCount: restartChangesRouteFailureCount,
          routeFailureClass: restartChangesFailureClass,
          lastStatus: restartChangesLastStatus || null,
          lastEventCount: restartChangesLastEventCount ?? null,
          changeEnvelopeObserved: restartChangesMatch !== null,
          gateEvidencePresent: restartChangesGateEvidence !== undefined,
          gatePendingCount: restartChangesGateEvidence?.pendingBeforeRelease ?? null,
          currentPendingCount: await visiblePendingCount(page),
          currentSyncState: await visibleSyncState(page),
          recoveryPushCount: recoveredPushSummaries.length,
          pageErrorCount,
        };
        console.log('restart changes safe diagnostic', JSON.stringify(diagnostic));
        await page.screenshot({
          path: path.join(tempRoot, 'changes-recovery-failure.png'),
        }).catch(() => {});
        throw error;
      }
      console.log('restart changes safe evidence', JSON.stringify({
        changesRequestCount: restartChangesRequestCount,
        changesRouteCount: restartChangesRouteCount,
        non200Count: restartChangesNon200Count,
        noMatchingEventCount: restartChangesNoMatchCount,
        routeFailureCount: restartChangesRouteFailureCount,
        lastStatus: restartChangesLastStatus || null,
        lastEventCount: restartChangesLastEventCount ?? null,
        changeEnvelopeObserved: restartChangesMatch !== null,
        gateEvidencePresent: restartChangesGateEvidence !== undefined,
        gatePendingCount: restartChangesGateEvidence?.pendingBeforeRelease ?? null,
        currentPendingCount: await visiblePendingCount(page),
      }));
      assertThat(restartChangesMatch.opId === crashOperation.opId &&
        restartChangesMatch.recordId === crashOperation.recordId &&
        restartChangesMatch.revisionId === crashOperation.revisionId &&
        restartChangesMatch.envelopeSha256 === crashOperation.envelopeSha256 &&
        restartChangesMatch.commitSeq === crashOperation.receipt.commitSeq &&
        restartChangesMatch.exactEnvelopeShape && restartChangesMatch.ciphertextOnlyHeader &&
        restartChangesMatch.encodedCiphertextFields && restartChangesMatch.markersAbsent,
      'restart did not pull and match the exact original encrypted operation');
      assertThat(restartChangesGateEvidence.opId === crashOperation.opId &&
        restartChangesGateEvidence.recordId === crashOperation.recordId &&
        restartChangesGateEvidence.revisionId === crashOperation.revisionId &&
        restartChangesGateEvidence.envelopeSha256 === crashOperation.envelopeSha256 &&
        restartChangesGateEvidence.commitSeq === crashOperation.receipt.commitSeq &&
        restartChangesGateEvidence.pendingBeforeRelease === 1,
      'matching changes response was not held while the original outbox item was pending');
      await waitForPendingCount(page, 0, 45000);
    }
    if (UNCOMMITTED_BEFORE_CRASH) {
      setStage('inspect actual IndexedDB outbox after server acknowledgement');
      localOutboxAfterRecovery = await waitForIndexedDbOutboxState(
        page, crashOperation, 'committed', 20000);
      assertThat(localOutboxAfterRecovery.pendingCount === 0 &&
        localOutboxAfterRecovery.vaultOperationCount === 0 &&
        localOutboxAfterRecovery.record.commitSeq === crashOperation.receipt.commitSeq &&
        localOutboxAfterRecovery.record.revisionId === crashOperation.revisionId &&
        localOutboxAfterRecovery.record.envelopeSha256 === crashOperation.envelopeSha256,
      'actual IndexedDB did not clear the operation after its server receipt');
    }
    if (recoveryEnrollmentMode === 'same-device' && deviceIdAtLogin) {
      assertThat(deviceIdAtRegistration === deviceIdAtLogin,
        'persistent profile re-login did not use the original device identity');
    }
    if (recoveryEnrollmentMode === 'trusted-device-reenrollment') {
      assertThat(typeof recoveryDeviceIdAtLogin === 'string' &&
        recoveryDeviceIdAtLogin.length > 0,
      'trusted-device recovery did not submit a new A device identity');
      assertThat(recoveryDeviceIdAtLogin !== deviceIdAtRegistration,
        're-enrolled A unexpectedly reused its prior device identity');
    }
    if (recoveredPushSummaries.length > 0) {
      assertThat(recoveredPushSummaries.every((summary) =>
        summary.opId === crashOperation.opId &&
        summary.revisionId === crashOperation.revisionId &&
        summary.envelopeSha256 === crashOperation.envelopeSha256),
      'restart retry changed the committed operation identity or ciphertext');
    }
    if (UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      assertThat(uncommittedRecoveryPushCount > 0 &&
        recoveredPushSummaries.some((summary) =>
          summary.opId === crashOperation.opId &&
          summary.recordId === crashOperation.recordId &&
          summary.revisionId === crashOperation.revisionId &&
          summary.deviceId === crashOperation.deviceId &&
          summary.envelopeSha256 === crashOperation.envelopeSha256),
      `same-profile restart did not resubmit the exact ${PRIMARY_RECORD_TYPE} operation, envelope and device identity`);
    }

    setStage(`verify exactly-once ${PRIMARY_RECORD_TYPE} counts and commit sequences`);
    const finalServer = serverRecordSnapshot(
      crashOperation, baselineCommitSeq, PRIMARY_PLAINTEXT_MARKERS);
    const hostCommitSeq = crashOperation.receipt.commitSeq;
    assertThat(finalServer.versionCount === 1 && finalServer.versionMatches &&
      finalServer.versionCommitSeq === hostCommitSeq &&
      finalServer.eventCount === 1 && finalServer.eventMatches &&
      finalServer.eventCommitSeq === hostCommitSeq &&
      finalServer.receiptCount === 1 && finalServer.receiptMatches &&
      finalServer.receiptCommitSeq === hostCommitSeq &&
      finalServer.headMatches && !finalServer.headDeleted &&
      finalServer.headCommitSeq === hostCommitSeq &&
      BigInt(finalServer.commitSeq) >= BigInt(hostCommitSeq) &&
      finalServer.envelopeHash === crashOperation.envelopeSha256 &&
      finalServer.eventEnvelopeHash === crashOperation.envelopeSha256 &&
      finalServer.opaqueEnvelope && !finalServer.plaintextMarkerFound &&
      !finalServer.serverPlaintextMarkerFound,
      `restart duplicated or changed the original server ${PRIMARY_RECORD_TYPE} commit`);
    if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH || UNCOMMITTED_GROUP_BEFORE_CRASH ||
        UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      assertThat(finalServer.versionOperation === 'create' &&
        finalServer.commitSeq === finalServer.expectedCommitSeq,
      `${PRIMARY_RECORD_TYPE} recovery did not produce one exact Vault commit`);
    }
    if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH || UNCOMMITTED_GROUP_BEFORE_CRASH ||
        UNCOMMITTED_SNIPPET_BEFORE_CRASH) {
      setStage(`trusted Profile B opens ${PRIMARY_RECORD_TYPE} workspace`);
      const pushCountBeforeTrustedPull = trustedSyncPushRequestCount;
      if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH) {
        await click(trustedPage, 'Credentials');
        await waitForSemanticText(trustedPage, 'SSH credentials');
      } else if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
        await click(trustedPage, 'Groups');
        await waitForSemanticText(trustedPage, 'Host groups');
      } else {
        await click(trustedPage, 'Snippets');
        await waitForSemanticText(trustedPage, 'Command snippets');
      }
      setStage('trusted Profile B requests a fresh Vault changes page');
      await pullTrustedProfileChanges();
      setStage(`trusted Profile B receives the recovered ${PRIMARY_RECORD_TYPE} event`);
      await waitForCondition(() => trustedPulledOperation !== undefined,
        `trusted Profile B did not receive the recovered ${PRIMARY_RECORD_TYPE} changes event`,
        20000, trustedPage);
      assertThat(trustedPulledOperation.opId === crashOperation.opId &&
        trustedPulledOperation.recordId === crashOperation.recordId &&
        trustedPulledOperation.revisionId === crashOperation.revisionId &&
        trustedPulledOperation.envelopeSha256 === crashOperation.envelopeSha256 &&
        trustedPulledOperation.markersAbsent,
      `trusted Profile B did not pull the exact opaque ${PRIMARY_RECORD_TYPE} operation`);
      if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH) {
        await waitForSemanticText(trustedPage, CREDENTIAL_NAME, 30000);
        setStage('trusted Profile B opens the recovered Credential editor');
        await clickCredentialMenuAction(trustedPage, CREDENTIAL_NAME, 'Edit');
        await waitForSemanticText(trustedPage, 'Edit credential');
        setStage('trusted Profile B verifies the decrypted Password in memory');
        const passwordField = await field(trustedPage, 'Password');
        await passwordField.click();
        // Flutter Web synchronizes the TextEditingController contents to its
        // hidden editing input after focus. Match the cross-profile reader.
        await trustedPage.waitForTimeout(150);
        const recoveredPassword = await passwordField.inputValue();
        console.log('Profile B decrypted Password safe evidence', JSON.stringify({
          matchesExpectedSecret: recoveredPassword === CREDENTIAL_PASSWORD,
          valueLength: recoveredPassword.length,
        }));
        assertThat(recoveredPassword === CREDENTIAL_PASSWORD,
          'trusted Profile B did not decrypt the exact recovered Password secret');
        setStage('trusted Profile B closes the Credential editor without writing');
        await click(trustedPage, 'Cancel');
      } else if (UNCOMMITTED_GROUP_BEFORE_CRASH) {
        await waitForSemanticText(trustedPage, GROUP_NAME, 30000);
        setStage('trusted Profile B opens the recovered Group editor');
        await clickGroupMenuAction(trustedPage, GROUP_NAME, 'Edit group');
        await waitForSemanticText(trustedPage, 'Edit host group');
        setStage('trusted Profile B reads the decrypted Group name');
        const groupNameField = await field(trustedPage, 'Group name');
        await groupNameField.click();
        await trustedPage.waitForTimeout(150);
        const recoveredGroupName = await groupNameField.inputValue();
        console.log('Profile B decrypted Group safe evidence', JSON.stringify({
          matchesExpectedName: recoveredGroupName === GROUP_NAME,
          valueLength: recoveredGroupName.length,
        }));
        assertThat(recoveredGroupName === GROUP_NAME,
          'trusted Profile B did not decrypt the exact recovered Group name');
        setStage('trusted Profile B closes the Group editor without writing');
        await click(trustedPage, 'Cancel');
      } else {
        await waitForSemanticText(trustedPage, SNIPPET_TITLE, 30000);
        setStage('trusted Profile B opens the recovered Snippet editor');
        const editButtons = trustedPage.getByRole('button', {
          name: 'Edit', exact: true,
        });
        const editButtonCount = await editButtons.count();
        const visibleEditButtons = [];
        for (let index = 0; index < editButtonCount; index += 1) {
          if (await editButtons.nth(index).isVisible().catch(() => false)) {
            visibleEditButtons.push(editButtons.nth(index));
          }
        }
        assertThat(visibleEditButtons.length === 1,
          'trusted Profile B did not show one editable recovered Snippet');
        await visibleEditButtons[0].click();
        await waitForSemanticText(trustedPage, 'Edit command snippet');
        const readFocusedField = async (label) => {
          const locator = await field(trustedPage, label);
          await locator.click();
          await trustedPage.waitForTimeout(150);
          return locator.inputValue();
        };
        const recoveredSnippetTitle = await readFocusedField('Title');
        const recoveredSnippetBody = await readFocusedField('Script body');
        console.log('Profile B decrypted Snippet safe evidence', JSON.stringify({
          titleMatchesExpected: recoveredSnippetTitle === SNIPPET_TITLE,
          bodyMatchesExpected: recoveredSnippetBody === SNIPPET_BODY,
          bodyLength: recoveredSnippetBody.length,
        }));
        assertThat(recoveredSnippetTitle === SNIPPET_TITLE &&
          recoveredSnippetBody === SNIPPET_BODY,
        'trusted Profile B did not decrypt the exact recovered Snippet fields');
        setStage('trusted Profile B closes the Snippet editor without writing');
        await click(trustedPage, 'Cancel');
      }
      assertThat(trustedSyncPushRequestCount === pushCountBeforeTrustedPull,
        'trusted Profile B unexpectedly submitted a sync push while pulling');
      const serverAfterTrustedPull = serverRecordSnapshot(
        crashOperation, baselineCommitSeq, PRIMARY_PLAINTEXT_MARKERS);
      assertThat(stableJson(serverAfterTrustedPull) === stableJson(finalServer),
        'trusted Profile B pull changed the exactly-once server record ledger');
      assertThat(trustedPageErrorCount === 0,
        `trusted Profile B raised a browser page error while decrypting the ${PRIMARY_RECORD_TYPE}`);
    }
    assertThat(pageErrorCount === 0, 'restarted Flutter Web raised a page error');

      console.log(UNCOMMITTED_SNIPPET_BEFORE_CRASH
        ? 'WEB-SNIPPET-CRASH-01 passed'
        : UNCOMMITTED_CREDENTIAL_BEFORE_CRASH
        ? 'WEB-CREDENTIAL-CRASH-01 passed'
        : UNCOMMITTED_GROUP_BEFORE_CRASH
          ? 'WEB-GROUP-CRASH-01 passed'
          : 'WEB-SYNC-CRASH-01 passed', JSON.stringify({
      recordType: PRIMARY_RECORD_TYPE,
      chromiumProcessKilled: true,
      samePersistentProfileRelaunched: true,
      serverUncommittedBeforeCrash: UNCOMMITTED_BEFORE_CRASH,
      recoveryEnrollmentMode,
      simulatedSecureStoreLoss: SIMULATE_SECURE_STORE_LOSS,
      deviceRecordPresentBeforeCrash,
      deviceRecordPresentAfterRestart,
      sameDeviceIdentityOnRelogin: recoveryEnrollmentMode === 'same-device'
        ? deviceIdAtLogin
          ? deviceIdAtRegistration === deviceIdAtLogin
          : 'session-restored-without-login-request'
        : 'not-applicable-device-was-re-enrolled',
      originalEnvelopeMatchesRegisteredDevice:
        UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH
        ? crashOperation.deviceId === deviceIdAtRegistration
        : null,
      recoveryPushMatchesOriginalDevice:
        UNCOMMITTED_GROUP_BEFORE_CRASH || UNCOMMITTED_SNIPPET_BEFORE_CRASH
        ? recoveredPushSummaries.some((summary) =>
          summary.opId === crashOperation.opId &&
          summary.deviceId === crashOperation.deviceId)
        : null,
      trustedDeviceWasAuthenticatedBeforeCrash: true,
      recoveryDeviceIdentityChanged: recoveryEnrollmentMode === 'trusted-device-reenrollment'
        ? recoveryDeviceIdAtLogin !== deviceIdAtRegistration
        : false,
      serverCommittedBeforeAckDrop: !UNCOMMITTED_BEFORE_CRASH,
      driftWebImplementation: driftImplementation || null,
      browserObservedLostPushResponseBeforeKill: failedPushRequestCount > 0,
      originalOperationReconciledFromChanges: !UNCOMMITTED_BEFORE_CRASH,
      operationCommittedByRestartPush: UNCOMMITTED_BEFORE_CRASH,
      matchingChangesPageReleasedWhilePending: !UNCOMMITTED_BEFORE_CRASH,
      pendingBeforeMatchingChangesRelease: UNCOMMITTED_BEFORE_CRASH
        ? null : restartChangesGateEvidence.pendingBeforeRelease,
      recoveryRetryCount: recoveredPushSummaries.length,
      uncommittedRecoveryPushCount,
      sameOperationRecoveryRetriesAborted: !UNCOMMITTED_BEFORE_CRASH,
      operationIdStable: true,
      revisionIdStable: true,
      envelopeSha256Stable: true,
      outboxPendingAfterRecovery: 0,
      localIndexedDbOutboxBeforeCrash: localOutboxBeforeCrash,
      localIndexedDbOutboxAfterRecovery: localOutboxAfterRecovery,
      serverCounts: {
        receipts: finalServer.receiptCount,
        versions: finalServer.versionCount,
        events: finalServer.eventCount,
        matchingHead: finalServer.headMatches,
        baselineCommitSeq,
        recordCommitSeq: hostCommitSeq,
        vaultCommitSeqAfterRecovery: finalServer.commitSeq,
      },
      serverStorageOpaque: true,
      browserPageErrors: pageErrorCount,
      trustedBrowserPageErrors: trustedPageErrorCount,
      recoveredPasswordCredentialDecryptedByProfileB:
        UNCOMMITTED_CREDENTIAL_BEFORE_CRASH,
      recoveredGroupDecryptedByProfileB: UNCOMMITTED_GROUP_BEFORE_CRASH,
      recoveredSnippetDecryptedByProfileB: UNCOMMITTED_SNIPPET_BEFORE_CRASH,
      trustedProfilePushesDuringPull: trustedSyncPushRequestCount,
    }));
  } catch (error) {
    const safeErrorClass = error?.name === 'TimeoutError'
      ? 'timeout'
      : error?.message?.includes('did not') ? 'acceptance-assertion' : 'runtime-error';
    if (INBOUND_CHANGES_CRASH) {
      const runnerFrame = String(error?.stack || '')
        .split('\n')
        .find((line) => line.includes('sync_crash_recovery.cjs')) || '';
      const runnerLine = runnerFrame.match(/sync_crash_recovery\.cjs:(\d+):(\d+)/)?.[1]
        || null;
      const localSnapshot = page && inboundReplayEvidence?.nextCursor
        ? await snapshotClientInboundChanges(
          page,
          inboundProducerOperations[0]?.vaultId,
          inboundProducerOperations,
          {
            cursor: inboundReplayEvidence.nextCursor,
            serverGeneration: inboundReplayEvidence.serverGeneration,
          },
          inboundBaselinePendingCount,
        ).catch(() => null)
        : null;
      const visibleHosts = await page?.evaluate((names) => {
        const rendered = [document.body.innerText || '',
          ...[...document.querySelectorAll('flt-semantics')].flatMap((node) => [
            node.innerText || '', node.getAttribute('aria-label') || '',
          ])].join('\n');
        return names.map((name) => rendered.includes(name));
      }, INBOUND_HOST_FIXTURES.map((fixture) => fixture.name)).catch(() => null);
      const probe = await page?.evaluate(() =>
        window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null,
      ).catch(() => null);
      const safeFailureMessages = new Set([
        'replayed remote Host records were not projected into the workspace',
        'replay did not persist both encrypted records once and advance exactly to next_cursor',
        'receiver attempted an unexpected server push during inbound replay',
        'producer server snapshot did not show exactly one opaque encrypted event',
        'server receipt/version/event/head counts changed during inbound replay',
        'inbound changes crash recovery raised a browser page error',
      ]);
      console.error('Inbound changes failure context', JSON.stringify({
        stage: activeStage,
        errorName: /^[A-Za-z]+$/.test(error?.name || '') ? error.name : 'Error',
        failedInvariant: safeFailureMessages.has(error?.message)
          ? error.message : null,
        runnerLine,
        preCrash: inboundPreCrashPageEvidence ? {
          requestCursorMatchesOld: inboundPreCrashPageEvidence.requestCursor ===
            (inboundOldCheckpoint?.cursor ?? null),
          eventCount: inboundPreCrashPageEvidence.eventCount,
          exactlyTwoEvents: inboundPreCrashPageEvidence.exactlyTwoEvents,
        } : null,
        replay: inboundReplayEvidence ? {
          requestCursorMatchesOld: inboundReplayEvidence.requestCursor ===
            (inboundOldCheckpoint?.cursor ?? null),
          eventCount: inboundReplayEvidence.eventCount,
          exactlyTwoEvents: inboundReplayEvidence.exactlyTwoEvents,
          nextCursorPresent: Boolean(inboundReplayEvidence.nextCursor),
          nextCursorMatchesOld:
            inboundReplayEvidence.nextCursor ===
              (inboundOldCheckpoint?.cursor ?? null),
          requestCount: inboundReplayRequestCount,
        } : null,
        localSnapshot: localSnapshot ? {
          available: localSnapshot.available,
          integrityCheck: localSnapshot.integrityCheck,
          checkpointMatchesExpected: localSnapshot.checkpointMatchesExpected,
          recordsExactlyOnce: localSnapshot.recordsExactlyOnce,
          pendingCountMatchesBaseline: localSnapshot.pendingCountMatchesBaseline,
          plaintextMarkerFound: localSnapshot.plaintextMarkerFound,
        } : null,
        visibleHosts,
        receiverPushRequests: inboundOwnerPushRequestCount,
        workerCompletionHolds: inboundWorkerCompletionHolds,
        probeEventCounts: probe?.counts || {},
        pageErrors: pageErrorCount,
        trustedPageErrors: trustedPageErrorCount,
      }));
    }
    if (REDACTION_INDEXEDDB_ORDERING) {
      const probe = await page?.evaluate(() =>
        window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null,
      ).catch(() => null);
      const runnerFrame = String(error?.stack || '')
        .split('\n')
        .find((line) => line.includes('sync_crash_recovery.cjs')) || '';
      const runnerLine = runnerFrame.match(/sync_crash_recovery\.cjs:(\d+):(\d+)/)?.[1]
        || null;
      console.error('Record redaction IndexedDB failure context', JSON.stringify({
        stage: activeStage,
        errorName: /^[A-Za-z]+$/.test(error?.name || '') ? error.name : 'Error',
        runnerLine,
        workerRouteHits: idbWorkerRouteCount,
        driftWebImplementation: driftImplementation || null,
        capabilityReportStatuses: redactionCapabilityReportStatuses,
        loginStatuses: redactionLoginStatuses,
        authRequestRoutes: redactionAuthRequestRoutes,
        authResponseStatuses: redactionAuthResponseStatuses,
        purgeStatus: redactionPurgeResponse?.status || null,
        redactionTargetObserved: Boolean(redactionTarget?.recordId),
        interceptedRedactionPages: redactionChangesPages.map((candidate) => ({
          status: candidate.status,
          eventCount: candidate.eventCount,
          redactionMarkerCount: candidate.redactionMarkerCount,
          noMorePages: candidate.noMorePages,
        })),
        probeEventCounts: probe?.counts || {},
        pageErrors: pageErrorCount,
      }));
    }
    if (UNCOMMITTED_CREDENTIAL_BEFORE_CRASH) {
      const credentialUi = await trustedPage?.evaluate((expectedName) => {
        const semantics = [...document.querySelectorAll('flt-semantics')];
        const matchingGroups = semantics.filter((element) =>
          element.getAttribute('role') === 'group' &&
          (element.getAttribute('aria-label') || '').includes(expectedName));
        const visibleDialogs = semantics.filter((element) =>
          element.getAttribute('role') === 'alertdialog' &&
          element.getBoundingClientRect().width > 0 &&
          element.getBoundingClientRect().height > 0);
        const visibleCredential = semantics.some((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 &&
            `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
              .includes(expectedName);
        });
        return {
          visibleCredentialName: visibleCredential,
          matchingCredentialCardCount: matchingGroups.length,
          matchingCardActionButtonCount: matchingGroups.reduce((count, group) =>
            count + group.querySelectorAll('[role="button"]').length, 0),
          visibleAlertDialogCount: visibleDialogs.length,
          editCredentialTitleVisible: semantics.some((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 &&
              (element.innerText || '').trim() === 'Edit credential';
          }),
          passwordInputCount: [...document.querySelectorAll('input[type="password"]')]
            .filter((element) => element.getBoundingClientRect().width > 0 &&
              element.getBoundingClientRect().height > 0).length,
        };
      }, CREDENTIAL_NAME).catch(() => ({ unavailable: true }));
      console.error('Credential crash acceptance safe failure context', JSON.stringify({
        stage: activeStage,
        errorName: /^[A-Za-z]+$/.test(error?.name || '') ? error.name : 'Error',
        credentialUi,
        exactChangesOperationObserved: Boolean(trustedPulledOperation &&
          trustedPulledOperation.opId === crashOperation?.opId &&
          trustedPulledOperation.recordId === crashOperation?.recordId &&
          trustedPulledOperation.revisionId === crashOperation?.revisionId),
        profileBPushRequests: trustedSyncPushRequestCount,
        profileBPageErrors: trustedPageErrorCount,
      }));
    }
    if (IDB_WRITE_FAILURE_RETRY) {
      const probe = await page?.evaluate(() =>
        window.__atermiusIdbWriteFailureProbe?.eventSummary?.() || null,
      ).catch(() => null);
      const runnerFrame = String(error?.stack || '')
        .split('\n')
        .find((line) => line.includes('sync_crash_recovery.cjs')) || '';
      const runnerLine = runnerFrame.match(/sync_crash_recovery\.cjs:(\d+):(\d+)/)?.[1]
        || null;
      console.error('IndexedDB probe failure context', JSON.stringify({
        stage: activeStage,
        errorName: /^[A-Za-z]+$/.test(error?.name || '') ? error.name : 'Error',
        runnerLine,
        workerRouteHits: idbWorkerRouteCount,
        driftWebImplementation: driftImplementation || null,
        probeEventCounts: probe?.counts || {},
        probeEventSequence: probe?.recentTypes || [],
        secondTabSyncControl: idbSyncControlDiagnostic || null,
        failureUiEvidence: idbFailureUiEvidence,
        primaryPageErrors: pageErrorCount,
        secondTabPageErrors: idbSecondPageErrorCount,
      }));
    }
    const safeIdbFailureMessages = new Set([
      'registered Web device identity was not durably visible before the write fault timed out',
      'aborted IndexedDB transaction left an encrypted record or outbox row in durable SQLite',
      'server commit sequence changed before the local storage retry',
      'client attempted a server push before the failed local write was restarted',
      'current Flutter bundle did not load the instrumented Drift SharedWorker',
      'hard termination targeted a different Chromium process group',
      'Chromium restart reused the terminated process identity',
      'restarted browser storage probe did not use the original origin',
      'restarted profile did not retain its registered Web device identity',
      'restart did not return the same persistent profile to its workspace',
      'failed local Host creation appeared after restart despite transaction rollback',
      'restart did not recover the last durable SQLite snapshot after the aborted write',
      'server changed while restarting after local IndexedDB rollback',
      'IndexedDB fault telemetry omitted the arm event',
      'instrumented SharedWorker did not observe and abort the blocks write transaction',
      'IndexedDB fault event sequence did not show a vault blocks mutation followed by abort',
      'retry did not receive a successful server receipt timed out',
      'post-restart retry did not create exactly one new server receipt',
      'successful retry did not clear its local outbox row after acknowledgement',
      'retry did not leave exactly one opaque server version, event, receipt and head',
      'aborted local IndexedDB write did not surface a new visible recoverable error',
      'failed Host save did not leave the Host absent with a visible retry action',
      'retry/restart path raised an uncaught Flutter Web page error',
    ]);
    const safeKnownMessage = IDB_WRITE_FAILURE_RETRY
      ? [...safeIdbFailureMessages].find((message) =>
        error?.message?.includes(message)) : undefined;
    const safeProbeFailure = IDB_WRITE_FAILURE_RETRY
      ? error?.message?.match(/^IndexedDB test probe event missing: ([a-z-]+); evaluation=([A-Za-z]+); observed=([a-z,-]*)$/)
      : undefined;
    const safeAssertion = safeKnownMessage
      ? `: ${safeKnownMessage}`
      : safeProbeFailure
      ? `: probe event ${safeProbeFailure[1]} missing (evaluation ${safeProbeFailure[2]}); observed=${safeProbeFailure[3] || 'none'}`
      : '';
    const safeSnapshotDetail = /^actual IndexedDB outbox did not reach (pending|committed) state: \{/.test(
      error?.message || '') ? ` ${error.message}` : '';
    console.error(`WEB-SYNC-CRASH-01 failed at ${activeStage} (${safeErrorClass})${safeAssertion}${safeSnapshotDetail}`);
    if (IDB_WRITE_FAILURE_RETRY && idbFailureUiEvidence) {
      console.error('IndexedDB failure UI safe evidence', JSON.stringify(idbFailureUiEvidence));
    }
    throw error;
  } finally {
    await cleanup();
    const cleanupEvidence = {
      tempRootRemoved: Boolean(tempRoot) && !fs.existsSync(tempRoot),
      serverProcessGroupStopped: !serverProcess?.pid ||
        !processGroupHasLiveMembers(serverProcess.pid),
      browserProfileRemoved: Boolean(profileDir) && !fs.existsSync(profileDir),
      trustedProfileRemoved: Boolean(trustedProfileDir) &&
        !fs.existsSync(trustedProfileDir),
      browserProfileProcessesStopped: !chromiumProfileHasLiveProcesses(profileDir) &&
        !chromiumProfileHasLiveProcesses(trustedProfileDir),
    };
    console.log('isolated fixture cleanup evidence', JSON.stringify(cleanupEvidence));
    if (Object.values(cleanupEvidence).some((value) => value !== true)) {
      cleanupFailure = true;
    }
    if (cleanupFailure) {
      console.error('WEB-SYNC-CRASH-01 cleanup reported an isolated fixture cleanup failure');
      process.exitCode = 1;
    }
  }
}

main().catch(() => {
  process.exitCode = 1;
});
