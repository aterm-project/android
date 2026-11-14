/*
 * WEB-STALE-OUTBOX-REVOKED-01: an Editor keeps a Host edit in its encrypted
 * local outbox while the Owner revokes that Editor and rotates the Vault key.
 * On reconnect, the client reloads signed control-plane state, drops local
 * access to the removed Vault, and preserves the uncommitted encrypted outbox.
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
const RUN_ID = crypto.randomUUID();
const OWNER_USERNAME = `stale-owner-${RUN_ID.slice(0, 8)}@example.test`;
const EDITOR_USERNAME = `stale-editor-${RUN_ID.slice(0, 8)}@example.test`;
const OWNER_PASSWORD = `Owner-${crypto.randomBytes(24).toString('base64url')}`;
const EDITOR_PASSWORD = `Editor-${crypto.randomBytes(24).toString('base64url')}`;
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
let ownerPage;
let editorPage;
let bootstrapToken;
let accountTokens = [];
let cleanupPromise;
let cleanupFailed = false;
const pageErrors = [];
const pushEvents = [];
const inviteEvents = [];
const membershipRefreshEvents = [];
const rotationEvents = [];
const networkFailures = [];
let traceSequence = 0;
let sharedVaultId;
let databasePath;

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
    for (const context of [ownerContext, editorContext]) {
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
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (request.method() === 'POST' && /^\/api\/v1\/vaults\/[^/]+\/keys\/rotate$/.test(pathname)) {
    return 'rotation';
  }
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
    if (kind === 'vault-list' || kind === 'membership-chain' || kind === 'vault-changes') {
      let vaultId = null;
      try {
        const match = new URL(request.url()).pathname.match(/^\/api\/v1\/vaults\/([^/]+)/);
        if (match) vaultId = decodeURIComponent(match[1]);
      } catch (_) {}
      const event = {
        profile,
        kind,
        sameSharedVault: Boolean(sharedVaultId && vaultId === sharedVaultId),
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
        containsHostPlaintext: [BASE_HOST_NAME, EDITED_HOST_NAME, HOST_ADDRESS, HOST_USERNAME]
          .some((marker) => JSON.stringify(body).includes(marker)),
        sequence: ++traceSequence,
        status: null,
        responseProcessed: false,
        errorCode: null,
      };
      pushEvents.push(event);
      pendingRequests.set(request, { kind, event });
    } else if (kind === 'rotation') {
      const event = {
        profile,
        sequence: ++traceSequence,
        status: null,
        responseProcessed: false,
        vaultId: null,
        activeEpoch: null,
        membershipVersion: null,
      };
      rotationEvents.push(event);
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
        pending.event.vaultId = typeof body?.vault_id === 'string' ? body.vault_id : null;
        pending.event.vaultIdValid = typeof body?.vault_id === 'string' &&
          /^[0-9a-f-]{36}$/i.test(body.vault_id);
        pending.event.tokenPresent = typeof body?.token === 'string';
      } catch (_) {}
    } else if ((pending.kind === 'push' || pending.kind === 'vault-changes') &&
        pending.event && response.status() >= 400) {
      try {
        const body = await response.json();
        pending.event.errorCode = typeof body?.error?.code === 'string'
          ? body.error.code : null;
      } catch (_) {}
    } else if (pending.kind === 'vault-list' && pending.event) {
      try {
        const body = await response.json();
        const vaults = Array.isArray(body?.vaults) ? body.vaults : [];
        pending.event.sharedVaultPresent = sharedVaultId
          ? vaults.some((vault) => vault?.vault_id === sharedVaultId)
          : null;
      } catch (_) {}
    } else if (pending.kind === 'rotation' && pending.event) {
      try {
        const body = await response.json();
        pending.event.vaultId = typeof body?.vault_id === 'string' ? body.vault_id : null;
        pending.event.activeEpoch = String(body?.active_key_epoch ?? '');
        pending.event.membershipVersion = String(body?.membership_version ?? '');
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

function inspectClientPendingOperation(sqliteFiles, vaultId, recordId) {
  const snapshotPath = path.join(tempRoot, 'editor-outbox-snapshot.sqlite');
  const databaseFile = sqliteFiles.find((file) => file.name === '/database');
  const journalFile = sqliteFiles.find((file) => file.name === '/database-journal');
  assertThat(databaseFile && (!journalFile || journalFile.length === 0),
    'Editor IndexedDB snapshot had no database or an active journal');
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
    'vault_id,record_id=sys.argv[2:]',
    "integrity=db.execute('PRAGMA integrity_check').fetchone()[0]",
    "rows=db.execute(\"SELECT op_id,vault_id,record_id,envelope_json,status FROM pending_operations WHERE vault_id=? AND record_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,record_id)).fetchall()",
    "pending=db.execute(\"SELECT count(*) FROM pending_operations WHERE vault_id=? AND status!='superseded'\",(vault_id,)).fetchone()[0]",
    'def digest(text):',
    '    value=json.loads(text)',
    '    canonical=json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)',
    '    return hashlib.sha256(canonical.encode()).hexdigest(),value',
    'operations=[]',
    'for row in rows:',
    '    envelope_hash,envelope=digest(row[3])',
    '    header=envelope.get("header",{})',
    '    operations.append({"opId":row[0],"vaultId":row[1],"recordId":row[2],"revisionId":header.get("revision_id"),"baseRevisionId":header.get("base_revision_id"),"operation":header.get("operation"),"keyEpoch":header.get("key_epoch"),"membershipVersion":header.get("membership_version"),"envelopeSha256":envelope_hash,"status":row[4]})',
    'print(json.dumps({"integrityCheck":integrity,"operations":operations,"activePendingCount":pending},separators=(",",":")))',
  ].join('\n');
  try {
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId, recordId], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!result.error && result.status === 0,
      'read-only Editor outbox snapshot query failed');
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function serverRecordSnapshot(vaultId, recordId) {
  const python = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,record_id=sys.argv[2:]',
    "versions=[dict(zip(('revisionId','baseRevisionId','commitSeq','operation'),row)) for row in db.execute('SELECT revision_id,base_revision_id,commit_seq,operation FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "receipts=[dict(zip(('opId','revisionId','commitSeq'),row)) for row in db.execute('SELECT op_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "events=[dict(zip(('commitSeq','eventType','revisionId'),row)) for row in db.execute('SELECT commit_seq,event_type,revision_id FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record_id))]",
    "head=db.execute('SELECT revision_id,commit_seq,deleted FROM record_heads WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()",
    'print(json.dumps({"versions":versions,"receipts":receipts,"events":events,"head":dict(zip(("revisionId","commitSeq","deleted"),head)) if head else None},separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', python, databasePath, vaultId, recordId], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only server record snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverVaultMembershipSnapshot(vaultId, ownerUsername, editorUsername) {
  const python = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'db.execute("PRAGMA query_only=ON")',
    'vault_id,owner,editor=sys.argv[2:]',
    "vault=db.execute('SELECT active_epoch,membership_version FROM vaults WHERE vault_id=?',(vault_id,)).fetchone()",
    "members=[dict(zip(('username','role','state'),row)) for row in db.execute('SELECT u.username,m.role,m.state FROM vault_members m JOIN users u ON u.user_id=m.user_id WHERE m.vault_id=? AND u.username IN (?,?) ORDER BY u.username',(vault_id,owner,editor))]",
    'print(json.dumps({"vault":dict(zip(("activeEpoch","membershipVersion"),vault)) if vault else None,"members":members},separators=(",",":")))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', python, databasePath, vaultId,
    ownerUsername, editorUsername], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only server membership snapshot query failed');
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
    event.requestTargetDeviceId === targetDeviceId &&
    event.vaultIdValid && /^\d+$/.test(event.membershipVersion || '') && event.tokenPresent,
  'Owner membership invitation did not target the signed Editor device');
  await click(ownerPage, 'Copy token');
  // Read only to ensure the UI completed its copy action, then clear the
  // browser clipboard and local value.
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
  const buttonLabels = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only|Device revoked)$/;
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

    setStage('launch isolated Owner and Editor browser profiles');
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
    ownerPage = await ownerContext.newPage();
    editorPage = await editorContext.newPage();
    let editorMainFrameNavigations = 0;
    editorPage.on('framenavigated', (frame) => {
      if (frame === editorPage.mainFrame()) editorMainFrameNavigations += 1;
    });
    trackPage(ownerPage, 'owner');
    trackPage(editorPage, 'editor');
    await Promise.all([ownerPage, editorPage].map((page) =>
      page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 })));
    await Promise.all([ownerPage, editorPage].map(enableSemantics));

    setStage('register disposable Vault Owner');
    await registerOwner(ownerPage, baseUrl, serverEnv);
    setStage('register disposable Editor account');
    await registerInvitedAccount(editorPage, baseUrl, serverEnv, EDITOR_USERNAME,
      EDITOR_PASSWORD, 'Stale outbox Editor fixture');

    setStage('invite Editor and activate its shared Vault membership');
    const editorCard = await copyDeviceCard(editorPage);
    const editorInvitation = await inviteShareCard(ownerPage, editorCard);
    assertThat(editorInvitation.event.vaultIdValid &&
      /^[0-9a-f-]{36}$/i.test(editorInvitation.event.vaultId || ''),
    'Owner invite response omitted the shared Vault identifier');
    sharedVaultId = editorInvitation.event.vaultId;
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
    databasePath = path.join(dataDir, 'atermius.db');
    const initialServerRecord = serverRecordSnapshot(sharedVaultId, baselineHost.recordId);
    const membershipBefore = serverVaultMembershipSnapshot(
      sharedVaultId, OWNER_USERNAME, EDITOR_USERNAME);
    assertThat(initialServerRecord.versions.length === 1 &&
      initialServerRecord.receipts.length === 1 && initialServerRecord.events.length === 1 &&
      initialServerRecord.head?.revisionId === baselineHost.revisionId &&
      membershipBefore.vault &&
      membershipBefore.vault.activeEpoch === Number(baselineHost.keyEpoch) &&
      membershipBefore.vault.membershipVersion === Number(baselineHost.membershipVersion) &&
      membershipBefore.members.some((member) => member.username === OWNER_USERNAME &&
        member.role === 'owner' && member.state === 'active') &&
      membershipBefore.members.some((member) => member.username === EDITOR_USERNAME &&
        member.role === 'editor' && member.state === 'active'),
    'baseline did not show one committed Host and the active Editor membership');

    setStage('queue an offline Host edit from active Editor profile');
    await editorContext.setOffline(true);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === false),
      5000, 'Chromium did not expose the Editor profile as offline');
    await editHostOffline(editorPage);
    const pendingBefore = await waitPendingAtLeast(editorPage, 1);
    console.log('assert: offline_editor_outbox_retained=true');
    setStage('snapshot the immutable local Editor operation before revocation');
    const outboxBeforeSnapshot = await readClientDatabaseFromIndexedDb(editorPage);
    assertThat(outboxBeforeSnapshot.available &&
      Array.isArray(outboxBeforeSnapshot.sqliteFiles),
    'Editor IndexedDB snapshot was unavailable before revocation');
    const outboxBefore = inspectClientPendingOperation(
      outboxBeforeSnapshot.sqliteFiles, sharedVaultId, baselineHost.recordId);
    assertThat(outboxBefore.integrityCheck === 'ok' &&
      outboxBefore.operations.length === 1 &&
      outboxBefore.activePendingCount === 1 &&
      outboxBefore.operations[0].operation === 'update' &&
      outboxBefore.operations[0].status === 'queued' &&
      outboxBefore.operations[0].keyEpoch === baselineHost.keyEpoch &&
      outboxBefore.operations[0].membershipVersion === baselineHost.membershipVersion,
    'Editor did not retain exactly one queued old-version Host edit before revocation');
    const recordBeforeRevocation = serverRecordSnapshot(sharedVaultId, baselineHost.recordId);
    assertThat(JSON.stringify(recordBeforeRevocation) === JSON.stringify(initialServerRecord),
      'server Host record changed before the Owner revoked the offline Editor');

    setStage('Owner revokes the offline Editor and rotates the Vault key');
    await click(ownerPage, 'Settings');
    setStage('Owner opens the active Editor membership');
    await click(ownerPage, 'Manage Vault members');
    await waitSemanticText(ownerPage, 'EDITOR · Active');
    const rotationStart = rotationEvents.length;
    setStage('Owner opens revocation confirmation');
    await click(ownerPage, 'Revoke access');
    await waitSemanticText(ownerPage, 'Revoke member access?');
    setStage('Owner confirms revocation and key rotation');
    await click(ownerPage, 'Revoke and rotate key');
    const rotation = await waitApiEvent(rotationEvents,
      (event) => event.profile === 'owner' && event.status === 200,
      rotationStart - 1, 45000);
    assertThat(rotation.vaultId === sharedVaultId,
      'Owner rotation response referred to a different Vault');
    await waitSemanticText(ownerPage, 'EDITOR · Revoked');
    const membershipAfter = serverVaultMembershipSnapshot(
      sharedVaultId, OWNER_USERNAME, EDITOR_USERNAME);
    assertThat(membershipAfter.vault &&
      membershipAfter.vault.activeEpoch === membershipBefore.vault.activeEpoch + 1 &&
      membershipAfter.vault.membershipVersion ===
        membershipBefore.vault.membershipVersion + 1 &&
      membershipAfter.members.some((member) => member.username === OWNER_USERNAME &&
        member.role === 'owner' && member.state === 'active') &&
      membershipAfter.members.some((member) => member.username === EDITOR_USERNAME &&
        member.role === 'editor' && member.state === 'revoked'),
    'Owner revocation did not advance one key epoch/version and revoke the Editor');
    await click(ownerPage, 'Close');

    setStage('restore Editor network while its offline edit is pending');
    const syncStart = traceSequence;
    await editorContext.setOffline(false);
    await waitFor(() => editorPage.evaluate(() => navigator.onLine === true),
      5000, 'Chromium did not restore the Editor network');
    assertThat(!editorPage.isClosed() && editorMainFrameNavigations === editorNavigationBaseline,
      'Editor page navigated during offline membership revocation');
    setStage('request sync from the still-open Editor page');
    const visibleSyncTriggered = await syncNow(editorPage);
    setStage('classify Editor revocation transition and request ordering');
    let revocationTransition;
    await waitFor(() => {
      const events = membershipRefreshEvents.filter((event) =>
        event.profile === 'editor' && event.sequence > syncStart &&
        event.responseProcessed);
      const denied = events.find((event) => event.kind === 'vault-changes' &&
        event.sameSharedVault && event.status === 404 && event.errorCode === 'NOT_FOUND');
      const removed = events.find((event) => event.kind === 'vault-list' &&
        event.status === 200 && event.sharedVaultPresent === false);
      if (denied && removed && removed.sequence > denied.sequence) {
        revocationTransition = { kind: 'denied-read-before-roster', denied, removed };
        return true;
      }
      if (removed && (!denied || removed.sequence < denied.sequence)) {
        revocationTransition = { kind: 'roster-before-shared-read', removed };
        return true;
      }
      return false;
    }, 45000, 'Editor did not observe a safe revoked-Vault transition');

    setStage('verify signed roster removal preceded any shared-Vault follow-up');
    const removedDescriptor = revocationTransition.removed;
    if (revocationTransition.kind === 'denied-read-before-roster') {
      assertThat(revocationTransition.denied.responseProcessed &&
        revocationTransition.denied.sameSharedVault &&
        revocationTransition.denied.errorCode === 'NOT_FOUND',
      'revoked Editor read did not receive the opaque shared-Vault denial');
    } else {
      const personalVaultRead = await waitApiEvent(membershipRefreshEvents,
        (event) => event.profile === 'editor' && event.kind === 'vault-changes' &&
          event.sequence > removedDescriptor.sequence && !event.sameSharedVault &&
          event.status === 200,
        -1, 30000);
      assertThat(personalVaultRead.responseProcessed,
        'Editor did not continue only with a different active Vault after roster removal');
    }
    assertThat(!membershipRefreshEvents.some((event) =>
      event.profile === 'editor' && event.kind === 'vault-changes' &&
      event.sequence > removedDescriptor.sequence && event.sameSharedVault) &&
      !pushEvents.some((event) => event.profile === 'editor' &&
        event.sequence > syncStart),
    'Editor read or pushed the revoked Vault after the roster removed it');

    await waitHost(editorPage, BASE_HOST_NAME, false, 15000);
    await waitHost(editorPage, EDITED_HOST_NAME, false, 15000);
    if (revocationTransition.kind === 'denied-read-before-roster') {
      await waitFor(() => editorPage.getByRole('button', {
        name: 'Device revoked', exact: true,
      }).isVisible().catch(() => false), 15000,
      'Editor did not surface the removed Vault access state');
    }

    setStage('verify the original Editor outbox remains encrypted and unacknowledged');
    const outboxAfterSnapshot = await readClientDatabaseFromIndexedDb(editorPage);
    assertThat(outboxAfterSnapshot.available &&
      Array.isArray(outboxAfterSnapshot.sqliteFiles),
    'Editor IndexedDB snapshot was unavailable after revocation');
    const outboxAfter = inspectClientPendingOperation(
      outboxAfterSnapshot.sqliteFiles, sharedVaultId, baselineHost.recordId);
    const originalLocalOperation = outboxBefore.operations[0];
    assertThat(outboxAfter.integrityCheck === 'ok' &&
      outboxAfter.operations.length === 1 && outboxAfter.activePendingCount === 1 &&
      outboxAfter.operations[0].opId === originalLocalOperation.opId &&
      outboxAfter.operations[0].revisionId === originalLocalOperation.revisionId &&
      outboxAfter.operations[0].envelopeSha256 === originalLocalOperation.envelopeSha256 &&
      ['queued', 'sent'].includes(outboxAfter.operations[0].status) &&
      outboxAfter.operations[0].keyEpoch === originalLocalOperation.keyEpoch &&
      outboxAfter.operations[0].membershipVersion ===
        originalLocalOperation.membershipVersion && removedDescriptor.sharedVaultPresent === false,
    'Editor did not preserve the immutable pending envelope while dropping Vault access');

    setStage('verify the revoked operation did not change server state');
    const recordAfterRevocation = serverRecordSnapshot(sharedVaultId, baselineHost.recordId);
    const editorPushes = pushEvents.filter((event) => event.profile === 'editor' &&
      event.sequence > syncStart);
    assertThat(JSON.stringify(recordAfterRevocation) === JSON.stringify(recordBeforeRevocation) &&
      recordAfterRevocation.versions.length === 1 &&
      recordAfterRevocation.receipts.length === 1 &&
      recordAfterRevocation.events.length === 1 &&
      recordAfterRevocation.head?.revisionId === baselineHost.revisionId &&
      !recordAfterRevocation.receipts.some((receipt) =>
        receipt.opId === originalLocalOperation.opId) &&
      editorPushes.length === 0,
    'revoked Editor operation was committed, acknowledged, or changed the server head');

    setStage('verify no Host plaintext entered API or server storage');
    assertThat(!pushEvents.some((event) => event.containsHostPlaintext) &&
      !serverDatabaseContainsMarker([BASE_HOST_NAME, EDITED_HOST_NAME, HOST_ADDRESS, HOST_USERNAME]),
    'Host plaintext appeared in API push or server SQLite/WAL/SHM');

    setStage('verify Owner never receives the revoked Host edit');
    await click(ownerPage, 'Hosts');
    await waitHost(ownerPage, BASE_HOST_NAME, true);
    await waitHost(ownerPage, EDITED_HOST_NAME, false);
    assertThat(pageErrors.length === 0,
      'Flutter Web raised a runtime error in an isolated profile');

    console.log('WEB-STALE-OUTBOX-REVOKED-01 passed', JSON.stringify({
      profiles: 2,
      ownerRotatedKeyAndRevokedEditor: true,
      editorOutboxWasPendingOffline: pendingBefore >= 1,
      editorPageStayedOpenAcrossOutage: true,
      visibleSyncTriggered,
      revokedVaultTransition: revocationTransition.kind,
      clientReloadedAndDroppedRevokedVault: removedDescriptor.sharedVaultPresent === false,
      originalEncryptedOperationPreservedAndBlocked: true,
      noReceiptOrServerRecordAdvance: true,
      noEditorOperationWasCommittedOrAcknowledged: true,
      ownerDidNotReceiveEditedHost: true,
      APIAndServerDatabaseStayedCiphertextOnly: true,
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
      sameSharedVault: event.sameSharedVault,
      sharedVaultPresent: event.sharedVaultPresent,
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
  console.error(`WEB-STALE-OUTBOX-REVOKED-01 failed at ${stage} (${errorClass}); fixture values omitted`);
  console.error(`safe diagnostics: ${JSON.stringify(safeDiagnostics)}`);
  if (!cleanupFailed) process.exitCode = 1;
  else process.exitCode = 2;
});
