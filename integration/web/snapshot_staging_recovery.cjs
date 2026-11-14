/*
 * WEB-SNAPSHOT-STAGING-01: durable Web snapshot staging across a real
 * Chromium process restart. The local proxy forces a one-record page size so
 * a small fixture deterministically creates a continuation boundary.
 *
 * This runner only changes HTTP requests made by the test browser. It reads
 * the actual Drift SQLite file from IndexedDB's files/blocks stores and
 * checks that an interrupted partial stage stays separate from the active
 * cache and checkpoint, then resumes from the persisted opaque cursor.
 */
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `snapshot-stage-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `Stage${crypto.randomBytes(24).toString('hex')}9`;
const DEVICE_NAME = `Snapshot Stage ${RUN_ID.slice(0, 8)}`;
const VAULT_NAME = `Snapshot Stage Vault ${RUN_ID.slice(0, 8)}`;
const HOSTS = [
  { name: `stage-host-a-${RUN_ID}`, address: '192.0.2.101', username: `stage-a-${RUN_ID.slice(0, 8)}` },
  { name: `stage-host-b-${RUN_ID}`, address: '192.0.2.102', username: `stage-b-${RUN_ID.slice(0, 8)}` },
];
const MARKERS = HOSTS.flatMap((host) => [host.name, host.address, host.username]);

let tempRoot;
let dataDir;
let profileDir;
let databasePath;
let baseUrl;
let serverProcess;
let context;
let page;
let bootstrapToken;
let stageLabel = 'preflight';
let firstPageReachedResolve;
let firstPageReachedReject;
let firstContinuationReachedResolve;
let firstContinuationReachedReject;
let resumedPageReachedResolve;
let resumedPageReachedReject;
let firstPageGate = deferred();
let firstContinuationGate = deferred();
let resumedPageGate = deferred();
let holdFirstContinuation = false;
let abortHeldContinuation = false;
let heldContinuationAbortCount = 0;
let intentionalAbortRouteSucceeded = false;
let intentionalAbortRouteError;
let interruptionErrorDelta;
let intentionalPageRequestFailureCount = 0;
let unexpectedRequestFailureCount = 0;
let intentionallyAbortedCursor;
let intentionallyAbortedSnapshotId;
let releaseHeldContinuation;
const heldContinuationGate = new Promise((resolve) => { releaseHeldContinuation = resolve; });
let browserEpoch = 0;
let recoverySnapshotId;
let snapshotCheckpointCursor;
let snapshotItemCount;
let snapshotCreates = 0;
let snapshotCreateCountBeforeRestart;
let snapshotPageRequests = [];
let changes410Count = 0;
let targetVaultId;
let targetChangesCursor;
let expiredTargetCursorActive = false;
let expiredTargetCursorMarkedAt;
let snapshotActivatedAt;
let nextTargetChangesRequestId = 1;
const targetChangesRequests = [];
const targetChangesRequestByObject = new WeakMap();
const targetChangesRequestByGuid = new Map();
const pendingChanges410ConsoleCandidates = new Map();
let intentionallyAbortedRequestUrl;
let successfulHostPushCount = 0;
let pushedVaultId;
const browserEpochDiagnostics = new Map();
let cleanupComplete = false;
let browserCloseComplete = false;
let browserDisconnectedAfterClose = false;
let profileProcessesStopped = false;
let serverProcessGroupStopped = false;
let tempRootRemoved = false;
let closedBrowserEpochCount = 0;
let browserCloseFailureCount = 0;

function setStage(value) {
  stageLabel = value;
  console.log(`stage: ${value}`);
}

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
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

function withTimeout(promise, timeoutMs, description) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${description} timed out`)), timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

function safeMessage(error) {
  let message = typeof error?.message === 'string' ? error.message : String(error);
  for (const secret of [USERNAME, MASTER_PASSWORD, bootstrapToken, ...MARKERS]) {
    if (secret) message = message.split(secret).join('[redacted]');
  }
  return message.slice(0, 1200);
}

function safeConsoleText(text) {
  let value = String(text || '');
  for (const secret of [USERNAME, MASTER_PASSWORD, bootstrapToken, ...MARKERS]) {
    if (secret) value = value.split(secret).join('[redacted]');
  }
  return value.slice(0, 500);
}

function canonicalHttpUrl(value) {
  try {
    const url = new URL(value, baseUrl);
    url.hash = '';
    return url.href;
  } catch (_) {
    return '';
  }
}

function changes410Key(epoch, url) {
  return `${epoch}\n${canonicalHttpUrl(url)}`;
}

function safeConsoleUrl(value) {
  try {
    const url = new URL(value, baseUrl);
    url.username = '';
    url.password = '';
    for (const key of [...url.searchParams.keys()]) url.searchParams.set(key, '[redacted]');
    url.hash = '';
    return url.href.slice(0, 500);
  } catch (_) {
    return safeConsoleText(value).slice(0, 500);
  }
}

function diagnosticsForEpoch(epoch) {
  let diagnostics = browserEpochDiagnostics.get(epoch);
  if (!diagnostics) {
    diagnostics = { pageErrors: [], consoleErrors: [] };
    browserEpochDiagnostics.set(epoch, diagnostics);
  }
  return diagnostics;
}

function summarizeEpochDiagnostics(epoch) {
  const diagnostics = diagnosticsForEpoch(epoch);
  const consoleCounts = diagnostics.consoleErrors.reduce((counts, event) => {
    counts[event.category] = (counts[event.category] || 0) + 1;
    return counts;
  }, {});
  return {
    epoch,
    pageErrorCount: diagnostics.pageErrors.length,
    consoleErrorCount: diagnostics.consoleErrors.length,
    consoleErrorCounts: consoleCounts,
    pageErrors: diagnostics.pageErrors,
    consoleErrors: diagnostics.consoleErrors,
  };
}

function unexpectedConsoleErrorCount(epoch) {
  return diagnosticsForEpoch(epoch).consoleErrors.filter((event) => event.category === 'unexpected').length;
}

function targetChangesRequestRecord(request) {
  const requestGuid = request?._guid || request?._initializer?.guid;
  const existing = targetChangesRequestByObject.get(request) ||
    (requestGuid ? targetChangesRequestByGuid.get(requestGuid) : undefined);
  if (existing) return existing;
  if (!targetVaultId || !targetChangesCursor) return null;
  let url;
  try { url = new URL(request.url()); } catch (_) { return null; }
  const match = url.pathname.match(/^\/api\/v1\/vaults\/([0-9a-f-]+)\/changes$/i);
  if (request.method() !== 'GET' || !match || match[1].toLowerCase() !== targetVaultId.toLowerCase() ||
      url.searchParams.get('cursor') !== targetChangesCursor) return null;
  const record = {
    requestId: nextTargetChangesRequestId++,
    browserEpoch,
    requestAt: Date.now(),
    vaultId: targetVaultId,
    cursor: targetChangesCursor,
    cursorSha256: crypto.createHash('sha256').update(targetChangesCursor).digest('hex'),
    requestUrl: canonicalHttpUrl(request.url()),
    expiredAtRequest: expiredTargetCursorActive,
    routeAction: null,
    routeActionAt: null,
    responseStatus: null,
    responseAt: null,
    consoleErrorCount: 0,
  };
  targetChangesRequests.push(record);
  targetChangesRequestByObject.set(request, record);
  if (requestGuid) targetChangesRequestByGuid.set(requestGuid, record);
  return record;
}

function safeChangesRequestSummary(record) {
  return {
    requestId: record.requestId,
    browserEpoch: record.browserEpoch,
    requestAt: record.requestAt,
    beforeSnapshotActivation: record.expiredAtRequest,
    vaultId: record.vaultId,
    cursorSha256: record.cursorSha256,
    expiredAtRequest: record.expiredAtRequest,
    routeAction: record.routeAction,
    responseStatus: record.responseStatus,
    consoleErrorCount: record.consoleErrorCount,
  };
}

function chromiumProcessesUsingProfile() {
  if (!profileDir || !fs.existsSync('/proc')) return null;
  const processes = new Map();
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const commandLine = fs.readFileSync(`/proc/${entry}/cmdline`, 'utf8').replaceAll('\0', ' ');
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (fields[0] === 'Z' || fields[0] === 'X') continue;
      processes.set(Number(entry), {
        parentPid: Number(fields[1]),
        commandLine,
      });
    } catch (_) {}
  }
  const tree = new Set([...processes.entries()]
    .filter(([, process]) => process.commandLine.includes(profileDir))
    .map(([pid]) => pid));
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, process] of processes.entries()) {
      if (!tree.has(pid) && tree.has(process.parentPid)) {
        tree.add(pid);
        changed = true;
      }
    }
  }
  return [...tree];
}

async function stopChromiumProfileProcesses() {
  const initial = chromiumProcessesUsingProfile();
  if (initial === null) return false;
  const terminate = (signal) => {
    for (const pid of chromiumProcessesUsingProfile() || []) {
      try { process.kill(pid, signal); } catch (_) {}
    }
  };
  terminate('SIGTERM');
  let deadline = Date.now() + 3000;
  while (Date.now() < deadline && chromiumProcessesUsingProfile()?.length) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (chromiumProcessesUsingProfile()?.length) {
    terminate('SIGKILL');
    deadline = Date.now() + 3000;
    while (Date.now() < deadline && chromiumProcessesUsingProfile()?.length) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  return chromiumProcessesUsingProfile()?.length === 0;
}

async function waitForChromiumProfileDisconnect(timeoutMs = 5000) {
  if (!profileDir || !fs.existsSync('/proc')) return false;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const processes = chromiumProcessesUsingProfile();
    if (processes && processes.length === 0) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return (chromiumProcessesUsingProfile() || []).length === 0;
}

async function unusedLoopbackPort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function waitForServer(child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited before readiness');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1500) });
      if (response.status === 200) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

function processGroupHasLiveMembers(groupId) {
  if (!fs.existsSync('/proc')) return false;
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') return true;
    } catch (_) {}
  }
  return false;
}

async function stopProcessGroup(child) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline && processGroupHasLiveMembers(child.pid)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (processGroupHasLiveMembers(child.pid)) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
    const killDeadline = Date.now() + 4000;
    while (Date.now() < killDeadline && processGroupHasLiveMembers(child.pid)) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  assertThat(!processGroupHasLiveMembers(child.pid), 'isolated server process group survived cleanup');
}

async function waitForCondition(condition, description, timeoutMs = 30000, pageRef = page) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await condition()) return;
    await pageRef.waitForTimeout(100);
  }
  throw new Error(`${description} timed out`);
}

function visibleFieldSelector(label) {
  return `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
}

async function field(pageRef, label, timeoutMs = 15000) {
  const locator = pageRef.locator(visibleFieldSelector(label));
  await selectServerModeIfChooser(pageRef, locator);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (let i = 0; i < await locator.count(); i++) {
      const candidate = locator.nth(i);
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
    for (let i = 0; i < await locator.count(); i++) {
      const candidate = locator.nth(i);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await pageRef.waitForTimeout(100);
  }
  throw new Error('expected visible browser button was unavailable');
}

async function click(pageRef, label) {
  await (await button(pageRef, label)).click();
}

async function fill(pageRef, label, value) {
  const locator = await field(pageRef, label);
  for (let attempt = 0; attempt < 3; attempt++) {
    await locator.click();
    await pageRef.waitForTimeout(100);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 18 });
    await pageRef.waitForTimeout(150);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await pageRef.waitForTimeout(80);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('visible browser field did not retain its value');
}

async function waitForSemanticText(pageRef, expected, timeoutMs = 30000) {
  await waitForCondition(() => pageRef.evaluate((text) => {
    if ((document.body.innerText || '').includes(text)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`.includes(text));
  }, expected).catch(() => false), `visible semantic text`, timeoutMs, pageRef);
}

async function visibleUiSummary(pageRef) {
  return pageRef.evaluate(() => ({
    text: (document.body?.innerText || '').slice(0, 1600),
    semanticButtons: [...document.querySelectorAll('flt-semantics[role="button"]')]
      .map((node) => (node.innerText || node.getAttribute('aria-label') || '').trim())
      .filter(Boolean).slice(0, 40),
  })).catch(() => ({ unavailable: true }));
}

async function waitForWorkspace(pageRef) {
  await waitForCondition(() => pageRef.getByRole('button', { name: 'Add host', exact: true })
    .isVisible().catch(() => false), 'authenticated workspace', 45000, pageRef);
}

async function recoverWorkspaceAfterRestart() {
  await selectServerModeIfChooser(page);
  const deadline = Date.now() + 45000;
  let serverConnectionSubmitted = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) return;
    if (await page.getByRole('button', { name: 'Rebuild snapshot', exact: true })
      .isVisible().catch(() => false)) return;
    if (!loginSubmitted && await page.locator(visibleFieldSelector('Email or username'))
      .isVisible().catch(() => false)) {
      setStage('restart: restore the same authenticated account session');
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', MASTER_PASSWORD);
      await click(page, 'Sign in and unlock');
      loginSubmitted = true;
    } else if (!serverConnectionSubmitted && await page.locator(visibleFieldSelector('Server URL'))
      .isVisible().catch(() => false)) {
      await page.waitForTimeout(350);
      if (await page.locator(visibleFieldSelector('Email or username'))
        .isVisible().catch(() => false)) continue;
      setStage('restart: reconnect the same local server origin');
      await fill(page, 'Server URL', baseUrl);
      await click(page, 'Connect securely');
      serverConnectionSubmitted = true;
    }
    await page.waitForTimeout(150);
  }
  const visibleState = await page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== 'hidden';
    };
    const fields = [...document.querySelectorAll('input')].filter(visible)
      .map((element) => element.getAttribute('aria-label') || '');
    const visibleText = [document.body.innerText || '',
      ...[...document.querySelectorAll('flt-semantics')].filter(visible)
        .map((node) => `${node.innerText || ''} ${node.getAttribute('aria-label') || ''}`),
    ].join(' ');
    return {
      serverUrlField: fields.some((label) => label.includes('Server URL')),
      accountField: fields.some((label) => label.includes('Email or username')),
      recoveryWorkspaceVisible: visibleText.includes('Add host'),
      chooserVisible: visibleText.includes('Choose a workspace'),
      unlockVisible: visibleText.includes('Unlock'),
      signInButtonVisible: [...document.querySelectorAll('flt-semantics[role="button"]')]
        .some((node) => visible(node) && (node.innerText || '').includes('Sign in and unlock')),
    };
  }).catch(() => ({ unavailable: true }));
  throw new Error(`same-profile restart did not restore the authenticated workspace: ${JSON.stringify(visibleState)}`);
}

async function clickWorkspaceNavigation(pageRef, label) {
  const pattern = label === 'Sync & conflicts' ? /^Sync & conflicts(?:\s+\d+)?$/ : label;
  const byButton = pageRef.getByRole('button', { name: pattern, exact: typeof pattern === 'string' });
  if (await byButton.isVisible().catch(() => false)) {
    await byButton.click();
    return;
  }
  const text = pageRef.getByText(pattern).last();
  await text.waitFor({ state: 'visible', timeout: 15000 });
  await text.click();
}

async function readClientDatabaseFromIndexedDb(pageRef) {
  return pageRef.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') return { available: false, reason: 'database-list-unavailable' };
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
      if (!connection.objectStoreNames.contains('files') || !connection.objectStoreNames.contains('blocks')) {
        return { available: false, reason: 'drift-file-stores-missing' };
      }
      const filesTx = connection.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('IDB files read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('IDB files read aborted'));
      });
      const store = filesTx.objectStore('files');
      const [values, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = store.getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file metadata read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = store.getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('IDB file key read failed'));
        }),
        filesComplete,
      ]);
      const selected = values.map((value, index) => ({
        fileId: Number(keys[index]), name: String(value?.name || ''), length: Number(value?.length),
      })).filter((file) => file.name === '/database' || file.name === '/database-journal');
      if (!selected.some((file) => file.name === '/database')) {
        return { available: false, reason: 'drift-sqlite-database-file-missing' };
      }
      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('IDB blocks read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('IDB blocks read aborted'));
      });
      const blocksStore = blocksTx.objectStore('blocks');
      const filesWithBlocks = await Promise.all(selected.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0], [file.fileId, 9007199254740992]);
        const [blockKeys, blockValues] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = blocksStore.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block keys read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = blocksStore.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('IDB block values read failed'));
          }),
        ]);
        return { ...file, blocks: blockKeys.map((key, index) => {
          const value = blockValues[index];
          const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
            ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
          if (!bytes) throw new Error('unsupported IndexedDB block value');
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 0x8000) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
          }
          return { offset: Number(key?.[1]), byteLength: bytes.length, base64: btoa(binary) };
        }) };
      }));
      await blocksComplete;
      return { available: true, sqliteFiles: filesWithBlocks };
    } finally {
      connection.close();
    }
  });
}

function withSqliteSnapshot(sqliteFiles, callback) {
  const database = sqliteFiles.find((file) => file.name === '/database');
  const journal = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(database && (!journal || journal.length === 0), 'IndexedDB SQLite snapshot has an active journal or missing database');
  const bytes = reconstructSqliteFile({
    fileId: database.fileId,
    name: database.name,
    length: database.length,
    blocks: database.blocks.map((block) => ({ offset: block.offset, bytes: Buffer.from(block.base64, 'base64') })),
  });
  const snapshotPath = path.join(tempRoot, `client-vault-${crypto.randomUUID()}.sqlite`);
  fs.writeFileSync(snapshotPath, bytes, { mode: 0o600 });
  fs.chmodSync(snapshotPath, 0o600);
  try { return callback(snapshotPath, bytes); }
  finally { fs.rmSync(snapshotPath, { force: true }); }
}

function inspectStageDatabase(sqliteFiles, vaultId, markers) {
  return withSqliteSnapshot(sqliteFiles, (snapshotPath, databaseBytes) => {
    const python = [
      'import hashlib,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'vault_id=sys.argv[2]',
      "tables={r[0] for r in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
      "required={'sync_snapshot_recovery_stages','sync_snapshot_recovery_items','sync_snapshot_recovery_cursors','encrypted_records','sync_checkpoints'}",
      'missing=sorted(required-tables)',
      'def digest(text):',
      '    try: value=json.loads(text)',
      '    except Exception: return None',
      '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
      '    return hashlib.sha256(canonical.encode()).hexdigest()',
      'result={"integrity":db.execute("PRAGMA integrity_check").fetchone()[0],"missingTables":missing}',
      'if not missing:',
      '    stages=db.execute("SELECT snapshot_id,high_watermark,conflict_high_watermark,checkpoint_cursor,expires_at,next_page_cursor,expected_item_count,verified_item_count,serialized_manifest_bytes,page_count,complete FROM sync_snapshot_recovery_stages WHERE vault_id=? ORDER BY created_at DESC",(vault_id,)).fetchall()',
      '    stage=None',
      '    if len(stages)==1:',
      '        r=stages[0]',
      '        items=db.execute("SELECT record_id,ordinal,revision_id,deleted,envelope_json,commit_seq FROM sync_snapshot_recovery_items WHERE vault_id=? AND snapshot_id=? ORDER BY ordinal",(vault_id,r[0])).fetchall()',
      '        cursors=db.execute("SELECT cursor FROM sync_snapshot_recovery_cursors WHERE vault_id=? AND snapshot_id=?",(vault_id,r[0])).fetchall()',
      '        parsed=[]',
      '        for item in items:',
      '            try: envelope=json.loads(item[4])',
      '            except Exception: envelope={}',
      '            parsed.append({"recordId":item[0],"ordinal":item[1],"revisionId":item[2],"deleted":bool(item[3]),"envelopeKeys":sorted(envelope) if isinstance(envelope,dict) else [],"hasCiphertext":isinstance(envelope,dict) and isinstance(envelope.get("ciphertext"),str),"hasNonce":isinstance(envelope,dict) and isinstance(envelope.get("nonce"),str),"envelopeSha256":digest(item[4])})',
      '        stage={"snapshotId":r[0],"highWatermark":r[1],"conflictHighWatermark":r[2],"checkpointCursor":r[3],"expiresAt":r[4],"nextPageCursor":r[5],"expectedItemCount":r[6],"verifiedItemCount":r[7],"serializedManifestBytes":r[8],"pageCount":r[9],"complete":bool(r[10]),"items":parsed,"cursorRowCount":len(cursors),"cursorMatchesNextPage":len(cursors)==1 and cursors[0][0]==r[5]}',
      '    cache=db.execute("SELECT count(*),coalesce(sum(is_deleted),0) FROM encrypted_records WHERE vault_id=?",(vault_id,)).fetchone()',
      '    cache_records=db.execute("SELECT record_id,revision_id,is_deleted FROM encrypted_records WHERE vault_id=? ORDER BY record_id",(vault_id,)).fetchall()',
      '    checkpoints=db.execute("SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=?",(vault_id,)).fetchall()',
      '    result.update({"stageRowCount":len(stages),"stage":stage,"stageItemRows":db.execute("SELECT count(*) FROM sync_snapshot_recovery_items WHERE vault_id=?",(vault_id,)).fetchone()[0],"stageCursorRows":db.execute("SELECT count(*) FROM sync_snapshot_recovery_cursors WHERE vault_id=?",(vault_id,)).fetchone()[0],"cacheCount":cache[0],"cacheDeletedCount":cache[1],"cacheRecords":[{"recordId":r[0],"revisionId":r[1],"deleted":bool(r[2])} for r in cache_records],"checkpointRowCount":len(checkpoints),"checkpoint":({"cursor":checkpoints[0][0],"serverGeneration":checkpoints[0][1]} if len(checkpoints)==1 else None),"pendingCount":db.execute("SELECT count(*) FROM pending_operations WHERE vault_id=?",(vault_id,)).fetchone()[0]})',
      'print(json.dumps(result,separators=(",",":")))',
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0, 'read-only IndexedDB SQLite inspection failed');
    const summary = JSON.parse(result.stdout);
    summary.plaintextMarkerFound = markers.some((marker) => databaseBytes.includes(Buffer.from(marker, 'utf8')));
    summary.databaseFileBytes = databaseBytes.length;
    return summary;
  });
}

async function inspectBrowserStage(vaultId) {
  const stored = await readClientDatabaseFromIndexedDb(page);
  assertThat(stored?.available === true, `actual Chromium IndexedDB unavailable: ${stored?.reason || 'unknown'}`);
  return inspectStageDatabase(stored.sqliteFiles, vaultId, MARKERS);
}

async function launchBrowser() {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  context = await chromium.launchPersistentContext(profileDir, options);
  browserEpoch += 1;
  const activeBrowserEpoch = browserEpoch;
  diagnosticsForEpoch(activeBrowserEpoch);
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
  page = context.pages()[0] || await context.newPage();
  page.on('pageerror', (error) => {
    diagnosticsForEpoch(activeBrowserEpoch).pageErrors.push({
      message: safeMessage(error),
    });
  });
  page.on('console', (message) => {
    if (message.type() !== 'error') return;
    const location = message.location();
    const eventUrl = canonicalHttpUrl(location.url || '');
    let category = 'unexpected';
    const candidates = pendingChanges410ConsoleCandidates.get(eventUrl) || [];
    const matching410 = candidates.find((record) => record.browserEpoch === activeBrowserEpoch &&
      record.responseStatus === 410 && record.consoleErrorCount === 0);
    if (matching410 && /status of 410(?:\s|\()/i.test(message.text())) {
      category = 'expected-cursor-expiry-410';
      matching410.consoleErrorCount += 1;
    } else if (activeBrowserEpoch === 1 && abortHeldContinuation && intentionallyAbortedRequestUrl &&
        intentionallyAbortedSnapshotId === recoverySnapshotId &&
        eventUrl === canonicalHttpUrl(intentionallyAbortedRequestUrl) &&
        /net::ERR_FAILED/i.test(message.text())) {
      category = 'intentional-continuation-abort';
    }
    diagnosticsForEpoch(activeBrowserEpoch).consoleErrors.push({
      category,
      message: safeConsoleText(message.text()),
      location: {
        url: safeConsoleUrl(location.url || ''),
        lineNumber: Number.isInteger(location.lineNumber) ? location.lineNumber : null,
        columnNumber: Number.isInteger(location.columnNumber) ? location.columnNumber : null,
      },
    });
  });
  page.on('request', (request) => { targetChangesRequestRecord(request); });
  page.on('response', (response) => {
    const request = response.request();
    const record = targetChangesRequestRecord(request);
    if (record) {
      record.responseStatus = response.status();
      record.responseAt = Date.now();
      if (record.routeAction === 'expired-cursor-410' && response.status() === 410) {
        const url = record.requestUrl;
        const candidates = pendingChanges410ConsoleCandidates.get(url) || [];
        candidates.push(record);
        pendingChanges410ConsoleCandidates.set(url, candidates);
      }
    }
  });
  page.on('requestfailed', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) {}
    const requestSnapshotId = url?.pathname.match(/^\/api\/v1\/snapshots\/([0-9a-f-]+)$/i)?.[1];
    if (activeBrowserEpoch === 1 && abortHeldContinuation && request.method() === 'GET' && url &&
        requestSnapshotId === intentionallyAbortedSnapshotId && requestSnapshotId === recoverySnapshotId &&
        url.searchParams.get('page_cursor') === intentionallyAbortedCursor &&
        canonicalHttpUrl(request.url()) === canonicalHttpUrl(intentionallyAbortedRequestUrl)) {
      intentionalPageRequestFailureCount += 1;
    } else {
      unexpectedRequestFailureCount += 1;
    }
  });
  await installNetworkControls();
}

async function installNetworkControls() {
  await context.route('**/api/v1/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const changesRecord = targetChangesRequestRecord(request);
    if (changesRecord && expiredTargetCursorActive) {
      changesRecord.routeAction = 'expired-cursor-410';
      changesRecord.routeActionAt = Date.now();
      changes410Count += 1;
      await route.fulfill({
        status: 410,
        contentType: 'application/json',
        body: JSON.stringify({ error: { code: 'CURSOR_EXPIRED', message: 'test cursor expired' } }),
      });
      return;
    }
    if (request.method() === 'POST' && /\/api\/v1\/vaults\/[0-9a-f-]+\/snapshots$/i.test(url.pathname)) {
      snapshotCreates += 1;
      const response = await route.fetch();
      const body = await response.json().catch(() => ({}));
      if (response.status() >= 200 && response.status() < 300) {
        recoverySnapshotId = typeof body.snapshot_id === 'string' ? body.snapshot_id : recoverySnapshotId;
        snapshotCheckpointCursor = typeof body.next_cursor === 'string' ? body.next_cursor : snapshotCheckpointCursor;
        snapshotItemCount = Number.isSafeInteger(body.item_count) ? body.item_count : snapshotItemCount;
      }
      await route.fulfill({ response });
      return;
    }
    if (request.method() === 'GET' && /^\/api\/v1\/snapshots\/[0-9a-f-]+$/i.test(url.pathname)) {
      const pageCursor = url.searchParams.get('page_cursor');
      const requestInfo = {
        browserEpoch,
        snapshotId: url.pathname.split('/').at(-1),
        pageCursorPresent: Boolean(pageCursor),
        pageCursor,
      };
      snapshotPageRequests.push(requestInfo);
      if (!pageCursor && snapshotPageRequests.length === 1) {
        firstPageReachedResolve(requestInfo);
      }
      if (pageCursor && browserEpoch === 1 && holdFirstContinuation) {
        holdFirstContinuation = false;
        firstContinuationReachedResolve(requestInfo);
        await heldContinuationGate;
        if (abortHeldContinuation) {
          intentionallyAbortedRequestUrl = request.url();
          intentionallyAbortedSnapshotId = requestInfo.snapshotId;
          try {
            await route.abort('failed');
            heldContinuationAbortCount += 1;
            intentionalAbortRouteSucceeded = true;
          } catch (error) {
            intentionalAbortRouteError = safeMessage(error);
            throw error;
          }
          return;
        }
      }
      if (pageCursor && browserEpoch >= 2) {
        resumedPageReachedResolve(requestInfo);
      }
      if (browserEpoch >= 2 && !pageCursor) {
        // A restarted process must use the persisted cursor, never fetch the
        // first manifest page again.
        const error = new Error('resumed snapshot recovery requested page one again');
        resumedPageReachedReject(error);
        throw error;
      }
      url.searchParams.set('limit', '1');
      await route.continue({ url: url.toString() });
      return;
    }
    if (request.method() === 'POST' && /\/api\/v1\/vaults\/[0-9a-f-]+\/sync\/push$/i.test(url.pathname)) {
      try {
        const body = request.postDataJSON();
        if (typeof body?.vault_id === 'string') pushedVaultId = body.vault_id;
      } catch (_) {}
      const response = await route.fetch();
      const body = await response.json().catch(() => ({}));
      if (response.status() >= 200 && response.status() < 300) {
        successfulHostPushCount += Array.isArray(body.results) ? body.results.length : 1;
      }
      await route.fulfill({ response });
      return;
    }
    await route.continue();
  });
}

async function enableFlutter() {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitForCondition(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' && Boolean(document.querySelector('flt-semantics-placeholder')))
    .catch(() => false), 'Flutter crypto and startup', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitForCondition(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0)
    .catch(() => false), 'Flutter semantics', 15000);
}

async function createOwnerAccount() {
  setStage('register owner in disposable local server');
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
  await field(page, 'Owner email');
  await fill(page, 'Owner email', USERNAME);
  await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
  await fill(page, 'Confirm master password', MASTER_PASSWORD);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', DEVICE_NAME);
  await fill(page, 'First Vault', VAULT_NAME);
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await waitForWorkspace(page);
}

async function createHost(host) {
  await click(page, 'Add host');
  await waitForSemanticText(page, 'Add a host');
  await fill(page, 'Display name', host.name);
  await fill(page, 'Hostname or IP', host.address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', host.username);
  await click(page, 'Save encrypted host');
  await waitForSemanticText(page, host.name);
}

async function waitForPushes(count) {
  await waitForCondition(async () => successfulHostPushCount >= count && pushedVaultId !== undefined,
    'encrypted host commits', 45000);
}

async function getBaseline(vaultId) {
  const stored = await readClientDatabaseFromIndexedDb(page);
  assertThat(stored?.available === true, 'baseline Chromium IndexedDB snapshot unavailable');
  return inspectStageDatabase(stored.sqliteFiles, vaultId, MARKERS);
}

async function navigateToSync() {
  await clickWorkspaceNavigation(page, 'Sync & conflicts');
  await waitForCondition(() => page.getByRole('button', { name: 'Sync now', exact: true })
    .isVisible().catch(() => false), 'Sync now control', 20000);
}

async function ensureInitialCheckpoint(vaultId) {
  await navigateToSync();
  await click(page, 'Sync now');
  await waitForCondition(async () => {
    const summary = await getBaseline(vaultId).catch(() => null);
    return summary?.checkpointRowCount === 1 && typeof summary.checkpoint?.cursor === 'string' &&
      summary.checkpoint.cursor.length > 0 && summary.pendingCount === 0;
  }, 'initial committed changes cursor', 30000);
}

async function triggerCursorExpiryAndRecoveryWithOptions({
  holdFirstPageContinuation = false,
  restarted = false,
  previous410Count = changes410Count,
} = {}) {
  if (!expiredTargetCursorActive) {
    expiredTargetCursorActive = true;
    expiredTargetCursorMarkedAt = Date.now();
  }
  const recoveryPrompt = page.getByRole('button', { name: 'Rebuild snapshot', exact: true });
  if (!await recoveryPrompt.isVisible().catch(() => false)) {
    const epochAlreadyRequestedExpiredCursor = targetChangesRequests.some((record) =>
      record.browserEpoch === browserEpoch && record.routeAction === 'expired-cursor-410');
    if (!restarted || !epochAlreadyRequestedExpiredCursor) {
      await navigateToSync();
      if (!await recoveryPrompt.isVisible().catch(() => false)) await click(page, 'Sync now');
    }
  }
  try {
    await waitForCondition(() => page.getByRole('button', { name: 'Rebuild snapshot', exact: true })
      .isVisible().catch(() => false), 'snapshot recovery prompt', 30000);
  } catch (error) {
    const state = await visibleUiSummary(page);
    throw new Error(`${safeMessage(error)}; visible UI=${JSON.stringify(state)}`);
  }
  assertThat(changes410Count > previous410Count, 'test did not produce an injected CURSOR_EXPIRED response');
  const expiredRequests = targetChangesRequests.filter((record) =>
    record.browserEpoch === browserEpoch && record.routeAction === 'expired-cursor-410');
  assertThat(expiredRequests.length >= 1 && expiredRequests.every((record) =>
    record.vaultId === targetVaultId && record.cursor === targetChangesCursor && record.responseStatus === 410),
  'every matching expired Vault cursor request before snapshot recovery did not receive HTTP 410');
  holdFirstContinuation = holdFirstPageContinuation;
  await click(page, 'Rebuild snapshot');
}

async function main() {
  const bundlePath = path.join(WEB_ROOT, 'main.dart.js');
  try {
  assertThat(['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']
    .every((name) => fs.existsSync(path.join(WEB_ROOT, name))), 'compiled Flutter Web release bundle is missing');
  assertThat(fs.existsSync(SERVER_BINARY), `server binary missing at ${SERVER_BINARY}; build it before running`);
  const bundleSha256 = crypto.createHash('sha256').update(fs.readFileSync(bundlePath)).digest('hex');
  console.log(`WEB-SNAPSHOT-STAGING-BUNDLE ${JSON.stringify({ mainDartJsSha256: bundleSha256 })}`);

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-snapshot-stage-'));
  dataDir = path.join(tempRoot, 'data');
  profileDir = path.join(tempRoot, 'chromium-profile');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(profileDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  fs.chmodSync(profileDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  const port = await unusedLoopbackPort();
  baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };

    setStage('start isolated server and owner bootstrap');
    serverProcess = spawn(SERVER_BINARY, ['serve'], { cwd: ROOT, env: serverEnv, detached: true, stdio: 'ignore' });
    await waitForServer(serverProcess);
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
      maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrap.error && bootstrap.status === 0, 'isolated server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap token unavailable');
    bootstrap.stdout = '';

    setStage('launch persistent Chromium and register account');
    await launchBrowser();
    await enableFlutter();
    await createOwnerAccount();
    await waitForCondition(() => diagnosticsForEpoch(1).pageErrors.length === 0, 'browser page stability');

    setStage('create two encrypted host heads to guarantee a multi-page snapshot');
    await createHost(HOSTS[0]);
    await waitForPushes(1);
    await createHost(HOSTS[1]);
    await waitForPushes(2);
    const vaultId = pushedVaultId;
    assertThat(/^[0-9a-f-]{36}$/i.test(vaultId), 'host push did not provide a canonical Vault ID');
    await ensureInitialCheckpoint(vaultId);
    const baseline = await getBaseline(vaultId);
    assertThat(baseline.integrity === 'ok' && baseline.cacheCount >= 2 && baseline.pendingCount === 0,
      'baseline IndexedDB cache is incomplete or has pending writes');
    assertThat(baseline.checkpointRowCount === 1 && typeof baseline.checkpoint?.cursor === 'string' &&
      baseline.checkpoint.cursor.length > 0 && typeof baseline.checkpoint.serverGeneration === 'string',
    'baseline Vault did not have a durable changes cursor and generation');
    assertThat(!baseline.plaintextMarkerFound, 'host fixture plaintext appeared in baseline IndexedDB SQLite bytes');
    targetVaultId = vaultId;
    targetChangesCursor = baseline.checkpoint.cursor;

    setStage('expire the persisted cursor and begin paginated snapshot recovery');
    firstPageGate = deferred();
    firstPageReachedResolve = firstPageGate.resolve;
    firstPageReachedReject = firstPageGate.reject;
    firstContinuationGate = deferred();
    firstContinuationReachedResolve = firstContinuationGate.resolve;
    firstContinuationReachedReject = firstContinuationGate.reject;
    resumedPageGate = deferred();
    await triggerCursorExpiryAndRecoveryWithOptions({ holdFirstPageContinuation: true });
    await withTimeout(firstPageGate.promise, 60000, 'snapshot first page request');
    setStage('wait until page one is durably staged and page two is blocked before reaching server');
    const interruptedRequest = await withTimeout(
      firstContinuationGate.promise, 60000, 'snapshot continuation page request');
    assertThat(interruptedRequest.snapshotId === recoverySnapshotId && interruptedRequest.pageCursorPresent,
      'first continuation request did not belong to the expected snapshot');

    const partial = await inspectBrowserStage(vaultId);
    assertThat(partial.integrity === 'ok' && partial.missingTables.length === 0,
      'partial IndexedDB database failed integrity or lacks the staging schema');
    assertThat(partial.stageRowCount === 1 && partial.stage?.snapshotId === recoverySnapshotId &&
      partial.stage.complete === false && partial.stage.pageCount === 1 &&
      partial.stage.verifiedItemCount === 1 && partial.stage.expectedItemCount >= 2 &&
      partial.stage.nextPageCursor && partial.stage.cursorRowCount === 1 &&
      partial.stage.cursorMatchesNextPage && partial.stage.items.length === 1,
    'first verified snapshot page and continuation cursor were not durably committed together');
    assertThat(snapshotCreates === 1 && snapshotItemCount === partial.stage.expectedItemCount,
      'snapshot creation manifest count did not match the persisted staged-page count boundary');
    assertThat(partial.cacheCount === baseline.cacheCount && partial.checkpoint?.cursor === baseline.checkpoint?.cursor &&
      partial.checkpoint?.serverGeneration === baseline.checkpoint?.serverGeneration,
    'partial snapshot stage changed the active cache or checkpoint before activation');
    assertThat(!partial.plaintextMarkerFound && partial.stage.items.every((item) =>
      JSON.stringify(item.envelopeKeys) === JSON.stringify(['ciphertext', 'header', 'nonce', 'signature']) &&
      item.hasCiphertext && item.hasNonce),
    'partial snapshot stage contains plaintext or a non-opaque envelope');
    console.log('WEB-SNAPSHOT-STAGING-PARTIAL', JSON.stringify({
      integrity: partial.integrity,
      activeCacheCountUnchanged: partial.cacheCount === baseline.cacheCount,
      checkpointUnchanged: partial.checkpoint?.cursor === baseline.checkpoint?.cursor,
      persistedPageCount: partial.stage.pageCount,
      persistedItemCount: partial.stage.verifiedItemCount,
      expectedItemCount: partial.stage.expectedItemCount,
      continuationCursorCommitted: partial.stage.cursorMatchesNextPage,
      halfStageSeparateFromActiveCache: true,
      plaintextMarkerFound: partial.plaintextMarkerFound,
    }));
    snapshotCreateCountBeforeRestart = snapshotCreates;

    setStage('terminate browser at the confirmed durable first-page boundary');
    const expectedCursor = interruptedRequest.pageCursor;
    assertThat(expectedCursor === partial.stage.nextPageCursor, 'held request cursor differs from persisted continuation');
    const beforeInterruptionDiagnostics = summarizeEpochDiagnostics(1);
    console.log('WEB-SNAPSHOT-STAGING-EPOCH-DIAGNOSTICS', JSON.stringify(beforeInterruptionDiagnostics));
    assertThat(beforeInterruptionDiagnostics.pageErrorCount === 0 && unexpectedConsoleErrorCount(1) === 0,
      'page errors or console errors unrelated to an exact injected /changes 410 occurred before interruption');
    const firstEpochExpiredRequests = targetChangesRequests.filter((record) =>
      record.browserEpoch === 1 && record.routeAction === 'expired-cursor-410');
    assertThat(firstEpochExpiredRequests.length >= 1 && firstEpochExpiredRequests.every((record) =>
      record.vaultId === targetVaultId && record.cursor === targetChangesCursor && record.responseStatus === 410),
    'the first browser epoch did not return HTTP 410 for every recorded request using the exact expired Vault cursor');
    intentionallyAbortedCursor = expectedCursor;
    intentionallyAbortedSnapshotId = recoverySnapshotId;
    abortHeldContinuation = true;
    releaseHeldContinuation();
    await page.waitForTimeout(25);
    const firstContext = context;
    await firstContext.close();
    closedBrowserEpochCount += 1;
    context = null;
    page = null;
    browserDisconnectedAfterClose = await waitForChromiumProfileDisconnect();
    assertThat(browserDisconnectedAfterClose, 'the interrupted Chromium process remained connected after close');
    interruptionErrorDelta = summarizeEpochDiagnostics(1);
    console.log('WEB-SNAPSHOT-STAGING-EPOCH-DIAGNOSTICS', JSON.stringify(interruptionErrorDelta));
    assertThat(interruptionErrorDelta.pageErrorCount === 0 && unexpectedConsoleErrorCount(1) === 0,
      'the interrupted browser epoch recorded an unrelated page or console error');
    assertThat(heldContinuationAbortCount === 1,
      'the deliberately interrupted page_cursor request was not aborted exactly once');
    assertThat(intentionalAbortRouteSucceeded && !intentionalAbortRouteError &&
      intentionallyAbortedSnapshotId === recoverySnapshotId,
    'the deliberate continuation route abort failed or targeted another snapshot');
    assertThat(intentionalPageRequestFailureCount === 1 && unexpectedRequestFailureCount === 0,
      'the deliberate continuation interruption did not produce exactly one matching failed request');

    setStage('relaunch Chromium with the exact same user-data directory');
    resumedPageGate = deferred();
    resumedPageReachedResolve = resumedPageGate.resolve;
    resumedPageReachedReject = resumedPageGate.reject;
    const resumedPageOutcome = resumedPageGate.promise.then(
      (request) => ({ request }),
      (error) => ({ error }),
    );
    const restartCursorExpiryBaseline = changes410Count;
    await launchBrowser();
    await enableFlutter();
    await recoverWorkspaceAfterRestart();
    await triggerCursorExpiryAndRecoveryWithOptions({
      restarted: true,
      previous410Count: restartCursorExpiryBaseline,
    });

    setStage('verify the restarted browser requested the saved continuation cursor');
    const resumedOutcome = await withTimeout(resumedPageOutcome, 60000, 'resumed continuation request');
    if (resumedOutcome.error) throw resumedOutcome.error;
    const resumedRequest = resumedOutcome.request;
    assertThat(resumedRequest.pageCursorPresent && resumedRequest.pageCursor === expectedCursor,
      'restarted browser did not resume from the exact persisted continuation cursor');
    assertThat(snapshotCreateCountBeforeRestart === 1 && snapshotCreates === snapshotCreateCountBeforeRestart &&
      snapshotPageRequests.filter((item) => item.browserEpoch === 2).length === 1,
      'restart created a new snapshot or replayed the first page instead of resuming');

    setStage('wait for recovery activation and inspect committed IndexedDB state');
    await waitForCondition(async () => {
      try {
        const summary = await inspectBrowserStage(vaultId);
        const activated = summary.integrity === 'ok' && summary.stageRowCount === 0 &&
          summary.stageItemRows === 0 && summary.stageCursorRows === 0 &&
          summary.cacheCount === snapshotItemCount &&
          summary.checkpoint?.cursor === snapshotCheckpointCursor;
        if (activated) {
          snapshotActivatedAt ??= Date.now();
          expiredTargetCursorActive = false;
        }
        return activated;
      } catch (_) { return false; }
    }, 'final cache/checkpoint activation and staging cleanup', 60000);
    await clickWorkspaceNavigation(page, 'Hosts');
    await waitForSemanticText(page, HOSTS[0].name, 45000);
    await waitForSemanticText(page, HOSTS[1].name, 45000);
    const final = await inspectBrowserStage(vaultId);
    assertThat(final.integrity === 'ok' && final.missingTables.length === 0 &&
      final.stageRowCount === 0 && final.stageItemRows === 0 && final.stageCursorRows === 0,
    'completed recovery left staging metadata, items, or cursors behind');
    assertThat(final.cacheCount === snapshotItemCount && final.cacheCount === partial.stage.expectedItemCount &&
      final.checkpoint?.cursor === snapshotCheckpointCursor && final.checkpointRowCount === 1,
    'final active cache and checkpoint do not match the completed snapshot boundary');
    assertThat(JSON.stringify(final.cacheRecords) === JSON.stringify(baseline.cacheRecords),
      'final active cache record IDs/revisions differ from the pre-recovery Vault state');
    assertThat(final.pendingCount === 0 && !final.plaintextMarkerFound,
      'final snapshot recovery introduced pending writes or local plaintext in IndexedDB');
    const resumedSnapshotPages = snapshotPageRequests.filter((item) => item.browserEpoch === 2);
    assertThat(snapshotCreates === snapshotCreateCountBeforeRestart && snapshotPageRequests.length >= 3 &&
      snapshotPageRequests[0].browserEpoch === 1 &&
      snapshotPageRequests[0].pageCursorPresent === false &&
      snapshotPageRequests[1].browserEpoch === 1 &&
      snapshotPageRequests[1].pageCursor === expectedCursor &&
      resumedSnapshotPages.length >= 1 &&
      resumedSnapshotPages[0].snapshotId === recoverySnapshotId &&
      resumedSnapshotPages[0].pageCursor === expectedCursor,
    'snapshot request sequence did not prove first-page then resumed-continuation behavior');
    const matchingTargetChangesRequests = targetChangesRequests.filter((record) =>
      record.vaultId === targetVaultId && record.cursor === targetChangesCursor);
    const preActivationTargetRequests = matchingTargetChangesRequests.filter((record) => record.expiredAtRequest);
    const postActivationTargetRequests = matchingTargetChangesRequests.filter((record) => !record.expiredAtRequest);
    const restartedPreActivationRequests = preActivationTargetRequests.filter((record) => record.browserEpoch === 2);
    assertThat(snapshotActivatedAt !== undefined && snapshotCheckpointCursor === targetChangesCursor,
      'post-recovery 200 cannot be accepted because the snapshot checkpoint cursor differs from the expired cursor');
    assertThat(preActivationTargetRequests.length >= 2 &&
      preActivationTargetRequests.every((record) =>
        record.expiredAtRequest && record.routeAction === 'expired-cursor-410' && record.responseStatus === 410) &&
      restartedPreActivationRequests.length >= 1 &&
      postActivationTargetRequests.length === 1 &&
      postActivationTargetRequests[0].cursor === snapshotCheckpointCursor &&
      postActivationTargetRequests[0].responseStatus === 200 &&
      postActivationTargetRequests[0].routeAction === null,
    'a matching Vault cursor request escaped the expired-cursor 410 window or restarted from a different cursor');
    assertThat(heldContinuationAbortCount === 1 && intentionalAbortRouteSucceeded &&
      !intentionalAbortRouteError && intentionallyAbortedSnapshotId === recoverySnapshotId &&
      intentionalPageRequestFailureCount === 1 && unexpectedRequestFailureCount === 0,
    'the only deliberate browser interruption was not one successful exact snapshot-id/cursor route abort');
    const restartedDiagnostics = summarizeEpochDiagnostics(2);
    console.log('WEB-SNAPSHOT-STAGING-EPOCH-DIAGNOSTICS', JSON.stringify(restartedDiagnostics));
    assertThat(restartedDiagnostics.pageErrorCount === 0 && unexpectedConsoleErrorCount(2) === 0,
      'browser reported an unexpected page or console error');

    console.log('WEB-SNAPSHOT-STAGING-RESULT', JSON.stringify({
      passed: true,
      chromiumRestartedWithSameProfile: true,
      cursorExpiryResponses: changes410Count,
      targetCursorRequestSequence: matchingTargetChangesRequests.map(safeChangesRequestSummary),
      snapshotCreatesTotal: snapshotCreates,
      snapshotCreatesAfterRestart: snapshotCreates - snapshotCreateCountBeforeRestart,
      firstPageCursorWasNull: !snapshotPageRequests[0].pageCursorPresent,
      resumedCursorMatchesPersisted: resumedSnapshotPages[0].pageCursor === expectedCursor,
      activeCacheBeforeActivation: partial.cacheCount,
      activeCacheAfterActivation: final.cacheCount,
      activeCacheRecordIdsAndRevisionsPreserved: true,
      completedSnapshotItemCount: snapshotItemCount,
      snapshotCheckpointMatchesExpiredCursor: snapshotCheckpointCursor === targetChangesCursor,
      checkpointMatchesSnapshotBoundary: final.checkpoint?.cursor === snapshotCheckpointCursor,
      snapshotCursorSameAsBaseline: snapshotCheckpointCursor === baseline.checkpoint?.cursor,
      activationBeforeCursorRequestSequence: preActivationTargetRequests.length,
      activationAfterCursorRequestStatuses: postActivationTargetRequests.map((record) => record.responseStatus),
      stageAndCursorRowsCleared: final.stageRowCount === 0 && final.stageItemRows === 0 && final.stageCursorRows === 0,
      plaintextMarkerFound: final.plaintextMarkerFound,
      browserEpochDiagnostics: [...browserEpochDiagnostics.keys()].map(summarizeEpochDiagnostics),
      preInterruptionErrors: {
        pageErrors: beforeInterruptionDiagnostics.pageErrorCount,
        consoleErrors: beforeInterruptionDiagnostics.consoleErrorCounts,
      },
      intentionalContinuationAbortCount: heldContinuationAbortCount,
      intentionalPageRequestFailureCount,
      unexpectedRequestFailureCount,
      deliberateInterruptionErrorDelta: interruptionErrorDelta,
      webBundleMainDartJsSha256: crypto.createHash('sha256').update(fs.readFileSync(bundlePath)).digest('hex'),
    }));
  } catch (error) {
    console.error(`WEB-SNAPSHOT-STAGING-01 failed at ${stageLabel}; type=${error?.name || 'Error'}; message=${JSON.stringify(safeMessage(error))}`);
    for (const epoch of browserEpochDiagnostics.keys()) {
      console.error(`WEB-SNAPSHOT-STAGING-EPOCH-DIAGNOSTICS ${JSON.stringify(summarizeEpochDiagnostics(epoch))}`);
    }
    console.error(`WEB-SNAPSHOT-STAGING-CHANGES-REQUESTS ${JSON.stringify(targetChangesRequests.map(safeChangesRequestSummary))}`);
    console.error(`WEB-SNAPSHOT-STAGING-CURSOR-BOUNDARY ${JSON.stringify({
      targetChangesCursorSha256: targetChangesCursor ? crypto.createHash('sha256').update(targetChangesCursor).digest('hex') : null,
      snapshotCheckpointCursorSha256: snapshotCheckpointCursor
        ? crypto.createHash('sha256').update(snapshotCheckpointCursor).digest('hex') : null,
      snapshotCursorMatchesExpiredCursor: Boolean(targetChangesCursor && snapshotCheckpointCursor === targetChangesCursor),
      activationObserved: snapshotActivatedAt !== undefined,
    })}`);
    let abortedCursorMatches = false;
    try {
      abortedCursorMatches = Boolean(intentionallyAbortedRequestUrl &&
        new URL(intentionallyAbortedRequestUrl).searchParams.get('page_cursor') === intentionallyAbortedCursor);
    } catch (_) {}
    console.error(`WEB-SNAPSHOT-STAGING-ABORT ${JSON.stringify({
      snapshotIdMatched: intentionallyAbortedSnapshotId === recoverySnapshotId,
      cursorMatched: abortedCursorMatches,
      routeSucceeded: intentionalAbortRouteSucceeded,
      routeError: intentionalAbortRouteError,
      routeAbortCount: heldContinuationAbortCount,
      requestFailureCount: intentionalPageRequestFailureCount,
    })}`);
    process.exitCode = 1;
  } finally {
    abortHeldContinuation = true;
    releaseHeldContinuation?.();
    if (context) {
      try {
        await context.close();
        closedBrowserEpochCount += 1;
        browserDisconnectedAfterClose = await waitForChromiumProfileDisconnect();
        if (!browserDisconnectedAfterClose) throw new Error('Chromium remained running after context.close');
      } catch (error) {
        browserCloseFailureCount += 1;
        process.exitCode = 1;
        console.error(`Chromium context cleanup failed: ${JSON.stringify(safeMessage(error))}`);
      }
    }
    context = null;
    page = null;
    await stopProcessGroup(serverProcess).catch((error) => {
      process.exitCode = 1;
      console.error(`isolated server cleanup failed: ${JSON.stringify(safeMessage(error))}`);
    });
    serverProcessGroupStopped = !serverProcess || !processGroupHasLiveMembers(serverProcess.pid);
    if (!serverProcessGroupStopped) process.exitCode = 1;
    profileProcessesStopped = !profileDir || await stopChromiumProfileProcesses().catch((error) => {
      process.exitCode = 1;
      console.error(`Chromium process cleanup failed: ${JSON.stringify(safeMessage(error))}`);
      return false;
    });
    if (!profileProcessesStopped) process.exitCode = 1;
    if (tempRoot) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
      catch (_) { process.exitCode = 1; }
    }
    tempRootRemoved = !tempRoot || !fs.existsSync(tempRoot);
    if (!tempRootRemoved) process.exitCode = 1;
    browserCloseComplete = browserCloseFailureCount === 0 && closedBrowserEpochCount === browserEpoch;
    if (browserEpoch === 0) browserDisconnectedAfterClose = true;
    cleanupComplete = !context && browserCloseComplete && browserDisconnectedAfterClose &&
      profileProcessesStopped && serverProcessGroupStopped && tempRootRemoved;
    console.log(`WEB-SNAPSHOT-STAGING-CLEANUP ${JSON.stringify({
      complete: cleanupComplete,
      closedBrowserEpochs: closedBrowserEpochCount,
      browserEpochs: browserEpoch,
      browserDisconnectedAfterClose,
      profileProcessesStopped,
      serverProcessGroupStopped,
      tempRootRemoved,
    })}`);
    if (!cleanupComplete) process.exitCode = 1;
  }
}

void main();
