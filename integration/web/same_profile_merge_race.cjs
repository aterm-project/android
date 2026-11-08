/*
 * WEB-SYNC-SAME-PROFILE-MERGE-RACE-01: real persistent Chromium tabs share a
 * Drift sharedIndexedDb profile while one tab pauses an automatic merge just
 * before its atomic outbox replacement and the sibling tab appends an edit.
 * The server, database, account and browser profiles are disposable fixtures.
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const {
  reconstructSqliteFile,
  SQLITE_BLOCK_SIZE,
} = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.resolve(process.env.ATERMIUS_WEB_ROOT ||
  path.join(ROOT, 'apps/client/build/web-sync-race'));
const RUN_HOST_JUMP_GRAPH_ONLY = process.argv.includes('--jump-host-graph-only');
const RUN_INBOUND_STORE_RACE_ONLY = process.argv.includes('--inbound-store-race-only');
const RUN_INBOUND_STORE_CONFLICT_ONLY = process.argv.includes('--inbound-store-conflict-only');
const RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY = process.argv.includes(
  '--inbound-store-remote-conflict-only');
const RUN_INBOUND_STORE_CREDENTIAL_CONFLICT_ONLY = process.argv.includes(
  '--inbound-store-credential-conflict-only');
const RUN_INBOUND_STORE_CREDENTIAL_REMOTE_CONFLICT_ONLY = process.argv.includes(
  '--inbound-store-credential-remote-conflict-only');
const RUN_INBOUND_STORE_CREDENTIAL_CRASH_REPLAY_ONLY = process.argv.includes(
  '--inbound-store-credential-crash-replay-only');
const RUN_INBOUND_STORE_CREDENTIAL_ONLY = RUN_INBOUND_STORE_CREDENTIAL_CONFLICT_ONLY ||
  RUN_INBOUND_STORE_CREDENTIAL_REMOTE_CONFLICT_ONLY ||
  RUN_INBOUND_STORE_CREDENTIAL_CRASH_REPLAY_ONLY;
const ACCEPTANCE_ID = RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY
  ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-REMOTE-CONFLICT-01'
  : RUN_INBOUND_STORE_CREDENTIAL_CRASH_REPLAY_ONLY
    ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-CREDENTIAL-CRASH-REPLAY-01'
  : RUN_INBOUND_STORE_CREDENTIAL_REMOTE_CONFLICT_ONLY
    ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-CREDENTIAL-REMOTE-CONFLICT-01'
  : RUN_INBOUND_STORE_CREDENTIAL_CONFLICT_ONLY
    ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-CREDENTIAL-CONFLICT-01'
  : RUN_INBOUND_STORE_CONFLICT_ONLY
    ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-CONFLICT-01'
    : RUN_INBOUND_STORE_RACE_ONLY
      ? 'WEB-SYNC-SAME-PROFILE-INBOUND-STORE-RACE-01'
      : RUN_HOST_JUMP_GRAPH_ONLY
        ? 'WEB-SYNC-SAME-PROFILE-JUMPHOST-RACE-01'
        : 'WEB-SYNC-SAME-PROFILE-MERGE-RACE-01';
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const DATABASE_NAME = 'atermius_vault';
const RUN_ID = crypto.randomUUID();
const LOCAL_STORAGE_CRASH_PROBE_KEY = '__atermius_same_profile_crash_probe';
const LOCAL_STORAGE_CRASH_PROBE_VALUE = crypto.randomUUID();
const USERNAME = `same-profile-race-${RUN_ID.slice(0, 8)}@example.test`;
const PASSWORD = `SameProfile-${crypto.randomBytes(24).toString('base64url')}9`;
const MARKERS = {
  baseName: `race-base-${RUN_ID.slice(0, 8)}`,
  remoteName: `race-remote-${RUN_ID.slice(0, 8)}`,
  localTag: `race-local-tag-${RUN_ID.slice(0, 8)}`,
  address: '192.0.2.91',
  remoteAddress: `race-remote-${RUN_ID.slice(0, 8)}.example.test`,
  localAddress: `race-local-${RUN_ID.slice(0, 8)}.example.test`,
  credentialName: `race-credential-${RUN_ID.slice(0, 8)}`,
  credentialUsername: `race-login-${RUN_ID.slice(0, 8)}`,
  credentialBasePassword: `Credential-Base-${RUN_ID}!`,
  credentialRemotePassword: `Credential-Remote-${RUN_ID}!`,
  credentialLocalPassword: `Credential-Local-${RUN_ID}!`,
};

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let serverLogPath;
let serverProcess;
let ownerContext;
let editorContext;
let bootstrapToken;
let baseUrl;
let cleanupPromise;
let cleanupFailed = false;
let recordId;
let siblingOutboxSnapshot;
let postRaceOutboxSnapshot;
let serverHistoryDiagnostic;
let editorDiagnosticPage;
let siblingFavoriteUiRequiredReload = false;
let ownerProfileMarker = false;
let editorPrimaryMarker = false;
let editorSiblingMarker = false;
let hostGraphReloadDiagnostic;
let favoriteUiDiagnostic = [];
const apiEvents = [];
const apiMarkerMatches = [];
const pageErrors = { owner: 0, primary: 0, sibling: 0 };
const consoleErrors = { owner: 0, primary: 0, sibling: 0 };
const consoleErrorMessages = { owner: [], primary: [], sibling: [] };
const deliberatelyAbortedSyncRequests = { owner: [], primary: [], sibling: [] };
const backendMarkerCounts = { owner: 0, primary: 0, sibling: 0 };
const traceByRequest = new WeakMap();

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function safeDiagnosticText(value, maxLength = 360) {
  let message = String(value ?? '');
  const secrets = [USERNAME, PASSWORD, bootstrapToken, baseUrl, ...Object.values(MARKERS)]
    .filter((item) => typeof item === 'string' && item.length > 0)
    .sort((left, right) => right.length - left.length);
  for (const secret of secrets) message = message.split(secret).join('[redacted]');
  return message
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[redacted-email]')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[redacted-address]')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '[redacted-token]')
    .replace(/http:\/\/127\.0\.0\.1:\d+/g, '[isolated-server]')
    .replace(/\s+/g, ' ')
    .slice(0, maxLength);
}

function safeResponseBodyDiagnostic(body) {
  let payload;
  try { payload = JSON.parse(body); } catch (_) {
    return body ? safeDiagnosticText(body) : null;
  }
  const summary = {};
  const safeKeys = ['code', 'detail', 'error', 'message', 'reason', 'status', 'status_code', 'type'];
  for (const key of safeKeys) {
    const value = payload?.[key];
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      summary[key] = safeDiagnosticText(value);
    } else if (value && typeof value === 'object' && !Array.isArray(value)) {
      const nested = {};
      for (const nestedKey of safeKeys) {
        const nestedValue = value[nestedKey];
        if (typeof nestedValue === 'string' || typeof nestedValue === 'number' ||
          typeof nestedValue === 'boolean') nested[nestedKey] = safeDiagnosticText(nestedValue);
      }
      if (Object.keys(nested).length) summary[key] = nested;
    }
  }
  return Object.keys(summary).length ? summary : { jsonKeys: Object.keys(payload || {}).slice(0, 16) };
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 8 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    `${command} failed in the isolated sync race fixture`);
  return result.stdout || '';
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
    { requireChange = true, timeoutMs = 7000 } = {}) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let changed = false;
  let previous = previousFingerprint;
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

async function waitForServer(child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

function processGroupHasLiveMembers(groupId) {
  try {
    for (const entry of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(entry)) continue;
      let stat;
      try { stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8'); } catch (error) {
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
    try { process.kill(-groupId, 0); return true; } catch (error) {
      return error.code !== 'ESRCH';
    }
  }
}

function signalProcessGroup(groupId, signal) {
  try { process.kill(-groupId, signal); } catch (error) {
    if (error.code !== 'ESRCH') throw new Error('isolated process cleanup failed');
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

function chromiumProfileProcessIdentity(directory) {
  assertThat(fs.existsSync('/proc'), 'Chromium crash acceptance requires Linux /proc');
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
      // Chromium may exit while /proc is being scanned.
    }
  }
  assertThat(matches.length === 1 && matches[0].processGroup === matches[0].pid,
    'persistent profile did not identify one isolated Chromium process group');
  return matches[0];
}

function chromiumProfileHasLiveProcesses(directory) {
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
      // Chromium may exit while /proc is being scanned.
    }
  }
  return false;
}

async function forceKillChromiumProfile(directory) {
  const identity = chromiumProfileProcessIdentity(directory);
  signalProcessGroup(identity.processGroup, 'SIGKILL');
  assertThat(await waitForProcessGroupExit(identity.processGroup, 5000),
    'isolated Chromium process group survived SIGKILL');
  assertThat(!chromiumProfileHasLiveProcesses(directory),
    'a Chromium process still holds the editor profile after SIGKILL');
  return identity;
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  throw new Error('isolated server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    try {
      if (ownerContext) await ownerContext.close().catch(() => {});
      if (editorContext) await editorContext.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) { cleanupFailed = true; }
    finally {
      if (tempRoot) {
        try {
          fs.rmSync(tempRoot, { recursive: true, force: true });
          if (fs.existsSync(tempRoot)) cleanupFailed = true;
        } catch (_) { cleanupFailed = true; }
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

function cliToken(environment) {
  const output = runChecked(SERVER_BINARY, ['bootstrap'], { env: environment, timeout: 30000 });
  const token = output.trim().split(/\s+/).at(-1);
  assertThat(typeof token === 'string' && token.length >= 40,
    'isolated bootstrap credential was unavailable');
  return token;
}

async function waitFor(predicate, label, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} did not appear`);
}

async function waitForSemanticText(page, expected, timeoutMs = 20000) {
  await waitFor(() => page.evaluate((label) => {
    if ((document.body.innerText || '').includes(label)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((node) =>
      `${node.innerText || ''}\n${node.getAttribute('aria-label') || ''}`.includes(label));
  }, expected).catch(() => false), `visible semantic text: ${expected}`, timeoutMs);
}

async function readIndexedDbSqliteImage(page) {
  return page.evaluate(async (databaseName) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(databaseName);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IDB open failed'));
    });
    try {
      if (!db.objectStoreNames.contains('files') ||
          !db.objectStoreNames.contains('blocks')) {
        throw new Error('IDB VFS stores are missing');
      }
      const filesTx = db.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('file read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('file read aborted'));
      });
      const [rows, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file rows unavailable'));
        }),
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file keys unavailable'));
        }),
      ]);
      await filesComplete;
      const mainIndex = rows.findIndex((row) => row?.name === '/database' ||
        row?.name === `/${databaseName}/database` || row?.name?.endsWith('/database'));
      if (mainIndex < 0) throw new Error('main SQLite VFS file is missing');
      const fileId = Number(keys[mainIndex]);
      const blockTx = db.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blockTx.oncomplete = resolve;
        blockTx.onerror = () => reject(blockTx.error || new Error('block read failed'));
        blockTx.onabort = () => reject(blockTx.error || new Error('block read aborted'));
      });
      const range = IDBKeyRange.bound([fileId, 0], [fileId, Number.MAX_SAFE_INTEGER]);
      const [blockKeys, values] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = blockTx.objectStore('blocks').getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('block keys unavailable'));
        }),
        new Promise((resolve, reject) => {
          const request = blockTx.objectStore('blocks').getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('block bytes unavailable'));
        }),
      ]);
      await blocksComplete;
      const blocks = blockKeys.map((key, index) => {
        const value = values[index];
        const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
          ArrayBuffer.isView(value)
            ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
            : null;
        if (!bytes) throw new Error('unsupported SQLite VFS block');
        let binary = '';
        for (let offset = 0; offset < bytes.length; offset += 8192) {
          binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
        }
        return { offset: Number(key?.[1]), base64: btoa(binary) };
      });
      return {
        fileId,
        name: String(rows[mainIndex].name),
        length: Number(rows[mainIndex].length),
        blocks,
      };
    } finally {
      db.close();
    }
  }, DATABASE_NAME);
}

async function safeWebStorageKinds(page) {
  return page.evaluate(() => {
    const summarize = (storage) => {
      const counts = { device: 0, session: 0, refresh: 0, lastServer: 0, other: 0 };
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key.endsWith('.device')) counts.device += 1;
        else if (key.includes('.session.')) counts.session += 1;
        else if (key.includes('.refresh.')) counts.refresh += 1;
        else if (key.endsWith('.last-server')) counts.lastServer += 1;
        else counts.other += 1;
      }
      return counts;
    };
    return {
      localStorage: summarize(localStorage),
      sessionStorage: summarize(sessionStorage),
    };
  });
}

function inspectLocalOutboxSqlite(snapshotPath, recordIds = [recordId]) {
  const script = String.raw`
import json,sqlite3,sys
path,record_ids_json=sys.argv[1:3]
record_ids=json.loads(record_ids_json)
if not isinstance(record_ids,list): record_ids=[]
record_ids=[item for item in record_ids if isinstance(item,str) and item]
db=sqlite3.connect('file:'+path+'?mode=ro',uri=True,timeout=8)
db.row_factory=sqlite3.Row
def header(raw):
 try:
  value=json.loads(raw) if raw else {}
  result=value.get('header',{}) if isinstance(value,dict) else {}
  if not isinstance(result,dict): result={}
  return {key:result.get(key) for key in ('operation','op_id','revision_id','base_revision_id','device_id')}
 except Exception:
  return {'invalidHeader':True}
pending=[]
placeholder=','.join('?' for _ in record_ids)
for row in db.execute('SELECT record_id,op_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE record_id IN ('+placeholder+') ORDER BY created_at,op_id',record_ids) if record_ids else []:
 pending.append({'recordId':row['record_id'],'rowOpId':row['op_id'],'rowBaseRevisionId':row['base_revision_id'],'status':row['status'],'envelopeHeader':header(row['envelope_json']),'baseEnvelopeHeader':header(row['base_envelope_json'])})
cache=[]
for row in db.execute('SELECT record_id,revision_id,is_deleted,envelope_json FROM encrypted_records WHERE record_id IN ('+placeholder+')',record_ids) if record_ids else []:
 cache.append({'recordId':row['record_id'],'revisionId':row['revision_id'],'isDeleted':bool(row['is_deleted']),'envelopeHeader':header(row['envelope_json'])})
print(json.dumps({'pending':pending,'encryptedRecordCache':cache},separators=(',',':')))
db.close()
`;
  const result = spawnSync('python3', ['-c', script, snapshotPath, JSON.stringify(recordIds)], {
    cwd: ROOT, encoding: 'utf8', timeout: 12000, maxBuffer: 256 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'same-profile local outbox metadata query failed');
  return JSON.parse(result.stdout);
}

async function snapshotLocalOutbox(page, suffix, recordIds = null) {
  const snapshotPath = path.join(tempRoot, `same-profile-${suffix}.sqlite`);
  try {
    const image = await readIndexedDbSqliteImage(page);
    assertThat(image.length > 0 && image.length <= 64 * 1024 * 1024 &&
      image.length % SQLITE_BLOCK_SIZE === 0,
    'same-profile client SQLite VFS image was not aligned');
    const bytes = reconstructSqliteFile({
      fileId: image.fileId,
      name: image.name,
      length: image.length,
      blocks: image.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
    fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'w' });
    return inspectLocalOutboxSqlite(snapshotPath, recordIds || [recordId]);
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function inspectInboundStoreRaceSqlite(snapshotPath, selectedRecordId = recordId) {
  const script = String.raw`
import hashlib,json,sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)
db.row_factory=sqlite3.Row
def header(raw):
 try:
  value=json.loads(raw) if raw else {}
  result=value.get('header',{}) if isinstance(value,dict) else {}
  if not isinstance(result,dict): result={}
  return {key:result.get(key) for key in ('operation','op_id','revision_id','base_revision_id','device_id')}
 except Exception:
  return {'invalidHeader':True}
def envelope_info(raw):
 try:
  value=json.loads(raw) if raw else {}
  result=value.get('header',{}) if isinstance(value,dict) else {}
  if not isinstance(result,dict): result={}
  ciphertext=value.get('ciphertext') if isinstance(value,dict) else None
  return {'header':{key:result.get(key) for key in ('operation','op_id','record_id','revision_id','base_revision_id','device_id')},'envelopeHash':hashlib.sha256((raw or '').encode()).hexdigest(),'ciphertextHash':hashlib.sha256(ciphertext.encode()).hexdigest() if isinstance(ciphertext,str) else None}
 except Exception:
  return {'invalidEnvelope':True}
checkpoints=[{'vaultId':row['vault_id'],'cursor':row['cursor'],'serverGeneration':row['server_generation'],'syncStatus':row['sync_status']} for row in db.execute('SELECT vault_id,cursor,server_generation,sync_status FROM sync_checkpoints')]
pending=[]
for row in db.execute('SELECT op_id,base_revision_id,base_envelope_json,envelope_json,status FROM pending_operations WHERE record_id=? ORDER BY created_at,op_id',(sys.argv[2],)):
 pending.append({'opId':row['op_id'],'baseRevisionId':row['base_revision_id'],'status':row['status'],'envelopeHeader':header(row['envelope_json']),'baseEnvelopeHeader':header(row['base_envelope_json']),'envelopeHash':hashlib.sha256(row['envelope_json'].encode()).hexdigest(),'envelopeCiphertextHash':envelope_info(row['envelope_json']).get('ciphertextHash'),'baseEnvelopeHash':hashlib.sha256((row['base_envelope_json'] or '').encode()).hexdigest()})
cache=[]
for row in db.execute('SELECT revision_id,is_deleted,commit_seq,envelope_json FROM encrypted_records WHERE record_id=?',(sys.argv[2],)):
 cache.append({'revisionId':row['revision_id'],'isDeleted':bool(row['is_deleted']),'commitSeq':row['commit_seq'],'envelopeHeader':header(row['envelope_json']),'envelopeHash':hashlib.sha256(row['envelope_json'].encode()).hexdigest(),'envelopeCiphertextHash':envelope_info(row['envelope_json']).get('ciphertextHash')})
conflicts=[]
for row in db.execute('SELECT conflict_id,kind,state,resolution_op_id,resolution_revision_id,branch_envelope_json,remote_envelope_json FROM conflict_branches WHERE record_id=? ORDER BY created_at,conflict_id',(sys.argv[2],)):
 conflicts.append({'conflictId':row['conflict_id'],'kind':row['kind'],'state':row['state'],'resolutionOpId':row['resolution_op_id'],'resolutionRevisionId':row['resolution_revision_id'],'branchEnvelope':envelope_info(row['branch_envelope_json']),'remoteEnvelope':envelope_info(row['remote_envelope_json'])})
integrity=db.execute('PRAGMA integrity_check').fetchone()[0]
print(json.dumps({'integrityCheck':integrity,'checkpoints':checkpoints,'pendingOperations':pending,'encryptedRecordCache':cache,'conflictBranches':conflicts},separators=(',',':')))
db.close()
`;
  const result = spawnSync('python3', ['-c', script, snapshotPath, selectedRecordId], {
    cwd: ROOT, encoding: 'utf8', timeout: 12000, maxBuffer: 512 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'same-profile inbound-store SQLite query failed');
  return JSON.parse(result.stdout);
}

async function snapshotInboundStoreRace(page, suffix, selectedRecordId = recordId) {
  const snapshotPath = path.join(tempRoot, `same-profile-inbound-store-${suffix}.sqlite`);
  try {
    const image = await readIndexedDbSqliteImage(page);
    assertThat(image.length > 0 && image.length <= 64 * 1024 * 1024 &&
      image.length % SQLITE_BLOCK_SIZE === 0,
    'same-profile inbound-store SQLite VFS image was not aligned');
    const bytes = reconstructSqliteFile({
      fileId: image.fileId,
      name: image.name,
      length: image.length,
      blocks: image.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
    fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'w' });
    const snapshot = inspectInboundStoreRaceSqlite(snapshotPath, selectedRecordId);
    snapshot.plaintextMarkersAbsent = !Object.values(MARKERS).some((marker) =>
      bytes.includes(Buffer.from(marker)));
    return snapshot;
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

function siblingEditChain(snapshot, baselineRevisionId) {
  const primary = snapshot?.pending?.find((item) =>
    item.envelopeHeader.operation === 'update' &&
    item.envelopeHeader.base_revision_id === baselineRevisionId);
  const sibling = snapshot?.pending?.find((item) =>
    primary && item.envelopeHeader.operation === 'update' &&
    item.envelopeHeader.revision_id !== primary.envelopeHeader.revision_id &&
    item.envelopeHeader.base_revision_id === primary.envelopeHeader.revision_id);
  return { primary, sibling };
}

async function visibleButton(page, label, timeoutMs = 20000) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const count = await matches.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button was not available: ${label}`);
}

async function click(page, label) {
  await (await visibleButton(page, label)).click();
}

async function field(page, label, timeoutMs = 20000) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const form = page.locator('[role="dialog"], [role="alertdialog"]');
  let matches = form.last().locator(selector);
  if (await matches.count().catch(() => 0) === 0) matches = page.locator(selector);
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const count = await matches.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible field was not available: ${label}`);
}

async function fill(page, label, value, timeoutMs = 30000) {
  const locator = await field(page, label, Math.min(timeoutMs, 20000));
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click({ timeout: timeoutMs });
    await page.waitForTimeout(60);
    await locator.press('Control+A', { timeout: timeoutMs });
    await locator.pressSequentially(value, { delay: 10, timeout: timeoutMs });
    await page.waitForTimeout(70);
    if (await locator.inputValue().catch(() => null) !== value) continue;
    await locator.press('Tab', { timeout: timeoutMs });
    if (await locator.inputValue().catch(() => null) === value) return;
  }
  throw new Error(`visible field did not retain its value: ${label}`);
}

async function paste(page, label, value) {
  const locator = await field(page, label);
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(120);
  if (await locator.inputValue().catch(() => '') !== value) await locator.fill(value);
  assertThat(await locator.inputValue().catch(() => null) === value,
    `clipboard input was not retained: ${label}`);
  await locator.press('Tab');
}

async function enableSemantics(page) {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  'Flutter Web semantics initialization', 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0),
    'Flutter Web semantic controls', 15000);
}

async function waitWorkspace(page) {
  await (await visibleButton(page, 'Settings', 40000)).waitFor({ state: 'visible' });
}

async function recoverSameProfileWorkspace(page) {
  await selectServerModeIfChooser(page);
  const deadline = Date.now() + 45000;
  let connected = false;
  let loginSubmitted = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Settings', exact: true })
      .isVisible().catch(() => false)) {
      await waitWorkspace(page);
      return;
    }
    if (!connected && await page.locator('input[aria-label*="Server URL"]')
      .isVisible().catch(() => false)) {
      // A stored Web session can restore while a new tab briefly exposes the
      // connection form. Give that transition a chance to settle, then retry
      // a transiently detached field without changing the saved URL.
      await page.waitForTimeout(350);
      if (await page.locator('input[aria-label*="Email or username"]')
        .isVisible().catch(() => false)) continue;
      if (!await page.locator('input[aria-label*="Server URL"]')
        .isVisible().catch(() => false)) continue;
      try {
        await fill(page, 'Server URL', baseUrl, 2500);
        await click(page, 'Connect securely');
        connected = true;
      } catch (error) {
        if (error?.name !== 'TimeoutError') throw error;
      }
    } else if (!loginSubmitted && await page.locator('input[aria-label*="Email or username"]')
      .isVisible().catch(() => false)) {
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', PASSWORD);
      await click(page, 'Sign in and unlock');
      loginSubmitted = true;
    }
    await page.waitForTimeout(120);
  }
  const visibleText = await page.locator('body').innerText().catch(() => '');
  const recoveryState = await page.evaluate(() => {
    const summarize = (storage) => {
      const counts = { device: 0, session: 0, refresh: 0, lastServer: 0, other: 0 };
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key.endsWith('.device')) counts.device += 1;
        else if (key.includes('.session.')) counts.session += 1;
        else if (key.includes('.refresh.')) counts.refresh += 1;
        else if (key.endsWith('.last-server')) counts.lastServer += 1;
        else counts.other += 1;
      }
      return counts;
    };
    return {
      url: location.pathname,
      inputLabels: [...document.querySelectorAll('input,textarea')]
        .map((item) => item.getAttribute('aria-label') || item.getAttribute('placeholder') || '')
        .filter(Boolean).slice(0, 12),
      localStorageKinds: summarize(localStorage),
      sessionStorageKinds: summarize(sessionStorage),
    };
  }).catch(() => ({ url: '', inputLabels: [], localStorageKinds: null,
    sessionStorageKinds: null }));
  throw new Error(`same-profile page could not restore workspace: ${JSON.stringify({
    visibleTextTail: safeDiagnosticText(visibleText.slice(-360), 320),
    recoveryState,
    recentAuthResponses: apiEvents.filter((event) =>
      event.profile === 'primary' && event.route.startsWith('auth-')).slice(-4).map((event) => ({
        route: event.route,
        status: event.status,
        response: event.responseBodyDiagnostic,
      })),
  })}`);
}

function routeFor(pathname) {
  if (pathname === '/api/v1/auth/prelogin') return 'auth-prelogin';
  if (pathname === '/api/v1/auth/login') return 'auth-login';
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) return 'changes';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts$/.test(pathname)) return 'conflict-create';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflicts\/[^/]+\/resolve$/.test(pathname)) return 'conflict-resolve';
  if (/^\/api\/v1\/vaults\/[^/]+\/conflict-changes$/.test(pathname)) return 'conflict-changes';
  return null;
}

function safeOperation(value) {
  const header = value?.header && typeof value.header === 'object' ? value.header : {};
  return {
    operation: header.operation || null,
    recordId: header.record_id || null,
    revisionId: header.revision_id || null,
    baseRevisionId: header.base_revision_id || null,
    opId: header.op_id || null,
    deviceId: header.device_id || null,
  };
}

function attachPageObservation(page, profile) {
  page.on('pageerror', () => { pageErrors[profile] += 1; });
  page.on('console', (message) => {
    if (message.type() === 'error') {
      consoleErrors[profile] += 1;
      if (consoleErrorMessages[profile].length < 20) {
        const location = message.location();
        const expectedAbort = message.text().includes('net::ERR_FAILED')
          ? deliberatelyAbortedSyncRequests[profile].find((request) =>
            !request.consoleErrorMatched && request.url === location?.url)
          : null;
        if (expectedAbort) expectedAbort.consoleErrorMatched = true;
        consoleErrorMessages[profile].push({
          text: safeDiagnosticText(message.text()),
          url: safeDiagnosticText(location?.url || ''),
          lineNumber: location?.lineNumber || 0,
          expectedAbortedSyncRequest: expectedAbort ? {
            id: expectedAbort.id,
            method: expectedAbort.method,
            route: expectedAbort.route,
          } : null,
        });
      }
    }
    const prefix = 'ATERMIUS_DRIFT_WEB_IMPLEMENTATION=';
    if (!message.text().startsWith(prefix)) return;
    const marker = message.text().slice(prefix.length).trim();
    if (marker === 'sharedIndexedDb') backendMarkerCounts[profile] += 1;
    if (profile === 'owner') ownerProfileMarker = marker === 'sharedIndexedDb';
    if (profile === 'primary') editorPrimaryMarker = marker === 'sharedIndexedDb';
    if (profile === 'sibling') editorSiblingMarker = marker === 'sharedIndexedDb';
  });
  page.on('request', (request) => {
    let parsedUrl;
    try { parsedUrl = new URL(request.url()); } catch (_) { return; }
    const pathname = parsedUrl.pathname;
    if (!pathname.startsWith('/api/v1/')) return;
    const route = routeFor(pathname);
    const event = route ? {
      profile,
      route,
      method: request.method(),
      requestCursor: route === 'changes' ? parsedUrl.searchParams.get('cursor') : null,
      status: null,
      bodyRead: false,
      operations: [],
      receipts: [],
      changeEvents: [],
      conflictId: null,
      resolution: null,
    } : null;
    const body = request.postData() || '';
    if (Object.values(MARKERS).some((marker) => body.includes(marker))) {
      apiMarkerMatches.push({ profile, direction: 'request' });
    }
    if (event) {
      try {
        const payload = JSON.parse(body);
        if (route === 'push') event.operations = Array.isArray(payload.operations)
          ? payload.operations.map(safeOperation) : [];
        if (route === 'conflict-create' && payload.envelope) {
          event.operations = [safeOperation(payload.envelope)];
        }
        if (route === 'conflict-resolve') {
          event.resolutionRequest = {
            opId: payload.op_id || null,
            resolvedRevisionId: payload.resolved_revision_id || null,
          };
          event.conflictId = pathname.match(/\/conflicts\/([^/]+)\/resolve$/)?.[1] || null;
        }
      } catch (_) {}
      apiEvents.push(event);
    }
    traceByRequest.set(request, event);
  });
  page.on('response', (response) => {
    void (async () => {
      const event = traceByRequest.get(response.request());
      let pathname;
      try { pathname = new URL(response.url()).pathname; } catch (_) { return; }
      if (!pathname.startsWith('/api/v1/')) return;
      const body = await response.text().catch(() => '');
      if (Object.values(MARKERS).some((marker) => body.includes(marker))) {
        apiMarkerMatches.push({ profile, direction: 'response' });
      }
      if (!event) return;
      event.status = response.status();
      event.statusText = safeDiagnosticText(response.statusText());
      event.responseBodyDiagnostic = safeResponseBodyDiagnostic(body);
      event.bodyRead = true;
      let payload;
      try { payload = JSON.parse(body); } catch (_) { return; }
      if (event.route === 'push') {
        event.receipts = Array.isArray(payload.results) ? payload.results.map((item) => ({
          opId: item.op_id,
          revisionId: item.revision_id,
          commitSeq: item.commit_seq,
        })) : [];
      }
      if (event.route === 'changes' && Array.isArray(payload.events)) {
        event.nextCursor = payload.next_cursor ?? null;
        event.serverGeneration = payload.server_generation ?? null;
        event.hasMore = payload.has_more ?? null;
        event.changeEvents = payload.events.map((item) => ({
          commitSeq: item.commit_seq,
          eventType: item.event_type,
          recordId: item.record_id,
          revisionId: item.revision_id,
        }));
      }
      if (event.route === 'conflict-create') event.conflictId = payload.conflict_id || null;
      if (event.route === 'conflict-resolve') event.resolution = {
        status: payload.status,
        resolvedRevisionId: payload.resolved_revision_id,
        resolutionSeq: payload.resolution_seq,
        alreadyResolved: payload.already_resolved,
      };
      if (event.route === 'conflict-changes' && Array.isArray(payload.events)) {
        event.changeEvents = payload.events.map((item) => ({
          seq: item.seq,
          type: item.type,
          conflictId: item.conflict_id,
          resolvedRevisionId: item.resolved_revision_id,
          branchOperation: item.envelope?.header?.operation || null,
        }));
      }
    })().catch(() => {});
  });
}

async function seedSharedIndexedDb(profileDir) {
  const context = await chromium.launchPersistentContext(profileDir, {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    serviceWorkers: 'block',
    ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
  });
  try {
    await context.route(`${baseUrl}/__race_fixture__`, (route) => route.fulfill({
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: '<!doctype html><title>isolated browser fixture</title>',
    }));
    const page = context.pages()[0] || await context.newPage();
    await page.goto(`${baseUrl}/__race_fixture__`, { waitUntil: 'domcontentloaded' });
    const seeded = await page.evaluate(async (name) => {
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open(name, 1);
        request.onupgradeneeded = () => {
          const files = request.result.createObjectStore('files', { autoIncrement: true });
          files.createIndex('fileName', 'name', { unique: true });
          request.result.createObjectStore('blocks');
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('IDB seed failed'));
      });
      const stores = [...db.objectStoreNames].sort();
      db.close();
      return JSON.stringify(stores) === JSON.stringify(['blocks', 'files']);
    }, DATABASE_NAME);
    assertThat(seeded, 'failed to seed isolated shared IndexedDB backend');
  } finally { await context.close(); }
}

function installHostJumpGraphRaceHook() {
  const state = {
    armed: false,
    entries: [],
    resolvers: Object.create(null),
    duplicateGateCount: 0,
    releasedRecordIds: [],
    release(recordId) {
      const resume = this.resolvers[recordId];
      if (typeof resume !== 'function') return false;
      delete this.resolvers[recordId];
      this.releasedRecordIds.push(recordId);
      resume();
      return true;
    },
  };
  Object.defineProperty(window, '__atermiusHostJumpGraphRaceState', { value: state });
  Object.defineProperty(window, '__atermiusSyncE2eHooks', {
    value: {
      beforeHostJumpGraphCommit(payload) {
        if (!state.armed) return Promise.resolve();
        const entry = {
          recordId: String(payload?.recordId || ''),
          jumpHostId: payload?.jumpHostId == null ? null : String(payload.jumpHostId),
          attempt: Number(payload?.attempt),
        };
        state.entries.push(entry);
        if (entry.attempt !== 1) return Promise.resolve();
        if (state.resolvers[entry.recordId]) {
          state.duplicateGateCount += 1;
          return Promise.resolve();
        }
        return new Promise((resolve) => { state.resolvers[entry.recordId] = resolve; });
      },
    },
  });
}

function installInboundStoreRaceHook() {
  const state = {
    armed: false,
    targetRecordId: null,
    entered: false,
    released: false,
    resume: null,
    entries: [],
    checkpointArmed: false,
    checkpointTargetCursor: null,
    checkpointExpectedCursor: null,
    checkpointEntered: false,
    checkpointReleased: false,
    checkpointResume: null,
    checkpointEntries: [],
  };
  Object.defineProperty(window, '__atermiusInboundStoreRaceState', { value: state });
  Object.defineProperty(window, '__atermiusSyncE2eHooks', {
    value: {
      beforeStorePulledEvent(payload) {
        if (!state.armed || String(payload?.recordId || '') !== state.targetRecordId) {
          return Promise.resolve();
        }
        state.entries.push({
          recordId: String(payload?.recordId || ''),
          revisionId: String(payload?.revisionId || ''),
          commitSeq: String(payload?.commitSeq || ''),
          observedPendingOperationCount: Number(payload?.observedPendingOperationCount),
        });
        if (state.entered) return Promise.resolve();
        state.entered = true;
        return new Promise((resolve) => { state.resume = resolve; });
      },
      beforeSaveInboundCheckpoint(payload) {
        if (!state.checkpointArmed ||
            String(payload?.nextCursor || '') !== state.checkpointTargetCursor) {
          return Promise.resolve();
        }
        state.checkpointEntries.push({
          expectedCursor: payload?.expectedCursor == null
            ? null : String(payload.expectedCursor),
          nextCursor: String(payload?.nextCursor || ''),
          serverGeneration: String(payload?.serverGeneration || ''),
          pageEventCount: Number(payload?.pageEventCount),
        });
        if (state.checkpointEntered) return Promise.resolve();
        state.checkpointEntered = true;
        return new Promise((resolve) => { state.checkpointResume = resolve; });
      },
    },
  });
}

async function launchProfile(profileDir, label, addRaceHook = false, beforeNavigate = null) {
  const context = await chromium.launchPersistentContext(profileDir, {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    acceptDownloads: true,
    ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
  });
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  const page = context.pages()[0] || await context.newPage();
  if (addRaceHook) {
    if (addRaceHook === 'inboundStore') {
      await page.addInitScript(installInboundStoreRaceHook);
    } else if (addRaceHook === 'hostJumpGraph') {
      await page.addInitScript(installHostJumpGraphRaceHook);
    } else {
      await page.addInitScript(() => {
      const state = {
        armed: false,
        entered: false,
        resumed: false,
        resume: null,
        preparedCandidates: 0,
      };
      Object.defineProperty(window, '__atermiusSyncRaceState', { value: state });
      Object.defineProperty(window, '__atermiusSyncE2eHooks', {
        value: {
          beforeReplaceMergedOperation() {
            if (!state.armed) return Promise.resolve();
            state.preparedCandidates += 1;
            if (state.entered) return Promise.resolve();
            state.entered = true;
            return new Promise((resolve) => { state.resume = resolve; });
          },
        },
      });
    });
    }
  }
  attachPageObservation(page, label);
  if (beforeNavigate) await beforeNavigate({ context, page });
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await enableSemantics(page);
  return { context, page };
}

async function connect(page) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function registerOwner(page) {
  setStage('register isolated owner');
  await connect(page);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', USERNAME);
  await fill(page, 'Master password · 12+ characters', PASSWORD);
  await fill(page, 'Confirm master password', PASSWORD);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Race owner');
  await fill(page, 'First Vault', 'Same Profile Merge Race Vault');
  bootstrapToken = undefined;
  await click(page, 'Create owner account');
  await waitWorkspace(page);
  await waitFor(() => ownerProfileMarker, 'owner sharedIndexedDb backend');
}

async function enrollSecondDevice(ownerPage, editorPage) {
  setStage('approve editor device');
  await connect(editorPage);
  await field(editorPage, 'Email or username');
  await click(editorPage, 'Add this device');
  await waitFor(() => editorPage.evaluate(() =>
    (document.body.innerText || '').includes('Request this device')),
  'second-device request form');
  await fill(editorPage, 'Account email', USERNAME);
  await fill(editorPage, 'Device name', 'Race editor');
  await click(editorPage, 'Generate request');
  await field(editorPage, 'Copy this enrollment JSON');
  await click(editorPage, 'Copy');
  const enrollment = await editorPage.evaluate(() => navigator.clipboard.readText());
  assertThat(JSON.parse(enrollment).format === 'atermius-device-enrollment-v1',
    'editor enrollment payload format was invalid');
  await click(editorPage, 'Close');
  await click(ownerPage, 'Devices');
  await click(ownerPage, 'Approve enrollment');
  await paste(ownerPage, 'Enrollment JSON', enrollment);
  await click(ownerPage, 'Review keys');
  await click(ownerPage, 'Approve & seal keys');
  await click(ownerPage, 'Copy');
  const approval = await ownerPage.evaluate(() => navigator.clipboard.readText());
  assertThat(approval.includes('atermius-device-approval-v1'),
    'editor approval payload format was invalid');
  await click(ownerPage, 'Done');
  await click(ownerPage, 'Hosts');
  await click(editorPage, 'Import approval');
  await paste(editorPage, 'Paste approval JSON', approval);
  await click(editorPage, 'Import device keys');
  await fill(editorPage, 'Email or username', USERNAME);
  await fill(editorPage, 'Master password', PASSWORD);
  await click(editorPage, 'Sign in and unlock');
  await waitWorkspace(editorPage);
  await waitFor(() => editorPrimaryMarker, 'editor sharedIndexedDb backend');
  await click(editorPage, 'Hosts');
}

function escapeRegExp(value) { return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function hostCard(page, name, id = null) {
  if (id) return page.locator(`flt-semantics[flt-semantics-identifier="ssh-host-${id}"]`);
  return page.getByRole('group', { name: new RegExp(`^Host: ${escapeRegExp(name)};`) }).first();
}

async function waitHost(page, name, id = null) {
  await waitFor(async () => {
    const card = hostCard(page, name, id);
    return await card.count().catch(() => 0) > 0 && await card.isVisible().catch(() => false);
  }, `Host ${name} appears`, 25000);
}

function credentialCard(page, name, id = null) {
  if (id) {
    return page.locator(`flt-semantics[flt-semantics-identifier="ssh-credential-${id}"]`);
  }
  const escaped = escapeRegExp(name);
  return page.getByRole('group', {
    name: new RegExp(`^Credential: ${escaped}; `),
  });
}

async function openCredentialsPage(page) {
  if (!await page.getByText('SSH credentials', { exact: true }).first()
    .isVisible().catch(() => false)) {
    await click(page, 'Credentials');
  }
  await waitFor(() => page.getByText('SSH credentials', { exact: true }).first()
    .isVisible().catch(() => false), 'Credentials page');
}

async function waitCredentialRecord(page, name, id = null) {
  await waitFor(async () => {
    const card = credentialCard(page, name, id);
    return await card.count().catch(() => 0) > 0 &&
      await card.isVisible().catch(() => false);
  }, `Credential ${name} appears`, 25000);
}

async function openCredentialEditor(page, name, id = null) {
  const card = credentialCard(page, name, id);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  const actions = card.getByRole('button');
  assertThat(await actions.count() === 1,
    'Credential card did not expose one action button');
  await actions.first().click();
  await page.getByRole('menuitem', { name: 'Edit', exact: true })
    .click({ timeout: 10000 });
  await waitFor(() => page.getByText('Edit credential', { exact: true }).first()
    .isVisible().catch(() => false), 'Edit Credential dialog');
}

async function createCredential(page) {
  await openCredentialsPage(page);
  await click(page, 'Add credential');
  await waitFor(() => page.getByText('New SSH credential', { exact: true }).first()
    .isVisible().catch(() => false), 'New Credential dialog');
  await fill(page, 'Credential name', MARKERS.credentialName);
  await fill(page, 'SSH username', MARKERS.credentialUsername);
  await fill(page, 'Password', MARKERS.credentialBasePassword);
  await click(page, 'Save encrypted credential');
  await waitCredentialRecord(page, MARKERS.credentialName);
}

async function openRecordList(page, credentialMode) {
  if (credentialMode) await openCredentialsPage(page);
  else await click(page, 'Hosts');
}

async function waitRecord(page, credentialMode) {
  if (credentialMode) {
    await waitCredentialRecord(page, MARKERS.credentialName, recordId);
  } else {
    await waitHost(page, MARKERS.baseName, recordId);
  }
}

async function editCredential(page, changes) {
  await openCredentialsPage(page);
  await openCredentialEditor(page, MARKERS.credentialName, recordId);
  for (const [label, value] of Object.entries(changes)) {
    await fill(page, label, value);
  }
  await click(page, 'Save encrypted credential');
  await waitCredentialRecord(page, MARKERS.credentialName, recordId);
}

async function editRecord(page, credentialMode, changes) {
  if (credentialMode) await editCredential(page, changes);
  else await editHost(page, MARKERS.baseName, changes);
}

async function waitForCredentialPassword(page, expected, label) {
  await openCredentialsPage(page);
  await waitCredentialRecord(page, MARKERS.credentialName, recordId);
  await openCredentialEditor(page, MARKERS.credentialName, recordId);
  const password = await field(page, 'Password');
  await password.click();
  await page.waitForTimeout(150);
  try {
    await waitFor(async () => await password.inputValue().catch(() => null) === expected,
      label, 30000);
  } catch (_) {
    // Keep the secret value out of assertion messages and runner diagnostics.
    throw new Error(`${label} did not match the selected encrypted Credential branch`);
  }
  await click(page, 'Cancel');
}

async function waitForRecordValue(page, credentialMode, expected, label) {
  if (credentialMode) {
    await waitForCredentialPassword(page, expected.password, label);
  } else {
    await waitForHostValues(page, expected, label);
  }
}

async function createHost(page) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitFor(() => page.evaluate(() => (document.body.innerText || '').includes('Add a host')),
    'Add Host editor');
  await fill(page, 'Display name', MARKERS.baseName);
  await fill(page, 'Hostname or IP', MARKERS.address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'race-user');
  await fill(page, 'Tags', 'base-tag');
  await click(page, 'Save encrypted host');
  await waitHost(page, MARKERS.baseName);
}

async function createNamedHost(page, name) {
  await click(page, 'Hosts');
  await click(page, 'Add host');
  await waitFor(() => page.evaluate(() => (document.body.innerText || '').includes('Add a host')),
    `Add Host editor for ${name}`);
  await fill(page, 'Display name', name);
  await fill(page, 'Hostname or IP', MARKERS.address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'race-user');
  await fill(page, 'Tags', 'graph-race');
  await click(page, 'Save encrypted host');
  await waitHost(page, name);
}

async function chooseJumpHostById(page, jumpHostId) {
  const controls = page.getByRole('button', { name: /Jump Host/i });
  let control;
  for (let index = await controls.count() - 1; index >= 0; index -= 1) {
    const candidate = controls.nth(index);
    if (await candidate.isVisible().catch(() => false) &&
        await candidate.isEnabled().catch(() => false)) {
      control = candidate;
      break;
    }
  }
  if (!control) {
    const target = await page.evaluate(() => {
      const matches = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((element) => element.getBoundingClientRect().width > 0 &&
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
            .toLowerCase().includes('jump host'));
      const element = matches.at(-1);
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    });
    assertThat(target, 'Jump Host dropdown control was not visible');
    await page.mouse.click(target.x, target.y);
  } else {
    await control.click();
  }
  const option = page.locator(
    `flt-semantics[flt-semantics-identifier="ssh-jump-host-option-${jumpHostId}"]`,
  ).last();
  await option.waitFor({ state: 'visible', timeout: 10000 });
  await option.click({ force: true });
}

async function editHostJumpRoute(page, name, hostId, jumpHostId) {
  const card = hostCard(page, name, hostId);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitFor(() => page.evaluate(() =>
    (document.body.innerText || '').includes('Save encrypted host')),
  `Host editor for ${name}`);
  await chooseJumpHostById(page, jumpHostId);
  await click(page, 'Save encrypted host');
}

async function editHost(page, oldName, changes) {
  const card = hostCard(page, oldName, recordId);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  for (const [label, value] of Object.entries(changes)) await fill(page, label, value);
  await click(page, 'Save encrypted host');
}

async function favoriteHost(page, name) {
  const card = hostCard(page, name, recordId);
  await card.waitFor({ state: 'visible', timeout: 20000 });
  await card.getByRole('button', { name: 'Favorite', exact: true }).click();
}

async function hostCardShows(page, expected) {
  const card = hostCard(page, expected.name, recordId);
  if (!await card.isVisible().catch(() => false)) return false;
  const label = await card.getAttribute('aria-label').catch(() => '') ||
    await card.innerText().catch(() => '');
  const expectedAddress = expected.address || MARKERS.address;
  if (!label.startsWith(`Host: ${expected.name};`) ||
      !label.includes(`@${expectedAddress}:${expected.port}`)) return false;
  const hasTag = expected.tag === undefined || await card.evaluate((root, tag) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden';
    };
    return [root, ...root.querySelectorAll('flt-semantics, [aria-label]')]
      .some((element) => visible(element) &&
        (element.getAttribute('aria-label') || element.innerText || '').trim().includes(tag));
  }, expected.tag).catch(() => false);
  return (async () => {
    if (!hasTag) return false;
    if (expected.favorite === undefined) return true;
    const favoriteButton = card.getByRole('button', {
      name: expected.favorite ? 'Remove favorite' : 'Favorite', exact: true,
    });
    return favoriteButton.isVisible().catch(() => false);
  })().catch(() => false);
}

async function observeFavoriteUiAtDeadlines(page, hostId, clickStartedAt) {
  // Move away from the IconButton before sampling. Flutter's Tooltip can alter
  // semantics while the pointer is still hovering over the control.
  await page.mouse.move(1400, 950);
  await page.evaluate(() => {
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    return new Promise((resolve) => requestAnimationFrame(() =>
      requestAnimationFrame(resolve)));
  });
  const snapshots = [];
  for (const deadlineMs of [500, 2000, 8000]) {
    await page.waitForTimeout(Math.max(0, deadlineMs - (Date.now() - clickStartedAt)));
    const sampledAtMsAfterClick = Math.max(0, Date.now() - clickStartedAt);
    const card = hostCard(page, MARKERS.baseName, hostId);
    const removeFavoriteInCardLocator = card.getByRole('button', {
      name: 'Remove favorite', exact: true,
    });
    const favoriteInCardLocator = card.getByRole('button', {
      name: 'Favorite', exact: true,
    });
    const removeFavoriteGlobalLocator = page.getByRole('button', {
      name: 'Remove favorite', exact: true,
    });
    const favoriteGlobalLocator = page.getByRole('button', {
      name: 'Favorite', exact: true,
    });
    const [removeFavoriteInCard, favoriteInCard, removeFavoriteGlobal,
      favoriteGlobal, semanticsSummary] = await Promise.all([
      removeFavoriteInCardLocator.isVisible().catch(() => false),
      favoriteInCardLocator.isVisible().catch(() => false),
      removeFavoriteGlobalLocator.isVisible().catch(() => false),
      favoriteGlobalLocator.isVisible().catch(() => false),
      page.evaluate((targetHostId) => {
      const target = document.querySelector(
        `flt-semantics[flt-semantics-identifier="ssh-host-${targetHostId}"]`);
      const classify = (value) => {
        const normalized = (value || '').trim().toLowerCase();
        if (normalized === 'remove favorite') return 'remove-favorite';
        if (normalized === 'favorite') return 'favorite';
        return normalized.includes('favorite') ? 'contains-favorite' : 'other';
      };
      const candidates = [...document.querySelectorAll(
        'flt-semantics,button,[role="button"], [aria-label], [title]')];
      const favoriteNodes = candidates.map((node) => {
        const label = node.getAttribute('aria-label') || '';
        const title = node.getAttribute('title') || '';
        const text = (node.innerText || node.textContent || '').trim();
        if (![label, title, text].some((value) => /favorite/i.test(value))) return null;
        const nearestCard = node.closest(
          'flt-semantics[flt-semantics-identifier^="ssh-host-"]');
        return {
          tag: node.tagName.toLowerCase(),
          role: node.getAttribute('role'),
          labelKind: classify(label),
          titleKind: classify(title),
          textKind: classify(text),
          insideTargetCard: Boolean(target && target.contains(node)),
          parentIsTargetCard: Boolean(target && node.parentElement === target),
          nearestCardIsTarget: Boolean(nearestCard && nearestCard === target),
          hasAriaLabel: label.length > 0,
          hasTitle: title.length > 0,
          ariaHidden: node.getAttribute('aria-hidden'),
          pressed: node.getAttribute('aria-pressed') ?? node.getAttribute('aria-checked'),
          visible: Boolean(node.getBoundingClientRect().width &&
            node.getBoundingClientRect().height),
        };
      }).filter(Boolean).slice(0, 20);
      return {
        cardPresent: Boolean(target),
        cardVisible: Boolean(target?.getBoundingClientRect().width &&
          target?.getBoundingClientRect().height),
        cardLabelKind: classify(target?.getAttribute('aria-label')),
        favoriteNodes,
      };
      }, hostId).catch(() => ({ cardPresent: false, cardVisible: false,
        favoriteNodes: [] })),
    ]);
    snapshots.push({
      atMsAfterClick: sampledAtMsAfterClick,
      deadlineMs,
      cardVisible: await card.isVisible().catch(() => false),
      removeFavoriteInCard,
      favoriteInCard,
      removeFavoriteGlobal,
      favoriteGlobal,
      semanticsSummary,
    });
  }
  return snapshots;
}

async function waitForHostValues(page, expected, label) {
  try {
    await waitFor(() => hostCardShows(page, expected), label, 30000);
  } catch (_) {
    const card = hostCard(page, expected.name, recordId);
    const cardLabel = await card.getAttribute('aria-label').catch(() => '') ||
      await card.innerText().catch(() => '');
    const expectedAddress = expected.address || MARKERS.address;
    const dialogs = page.locator('[role="dialog"], [role="alertdialog"]');
    const dialogText = await dialogs.last().innerText().catch(() => '');
    throw new Error(`${label} failed (card=${await card.isVisible().catch(() => false)}, ` +
      `name=${cardLabel.startsWith(`Host: ${expected.name};`)}, ` +
      `address=${cardLabel.includes(`@${expectedAddress}:${expected.port}`)}, ` +
      `tag=${expected.tag === undefined ? 'unchecked' : cardLabel.includes(expected.tag)}, favorite=${expected.favorite === undefined ? 'unchecked' :
        await card.getByRole('button', {
          name: expected.favorite ? 'Remove favorite' : 'Favorite', exact: true,
        }).isVisible().catch(() => false)}, dialog=${safeDiagnosticText(dialogText)})`);
  }
}

function successfulPush(profile, after = 0) {
  return apiEvents.slice(after).find((event) => event.profile === profile &&
    event.route === 'push' && event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.recordId === recordId && item.operation === 'update'));
}

async function clickSyncWhenIdle(page) {
  const status = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Read-only|Rebuilding snapshot|Snapshot exceeds client limit|Key update needed|Vault deletion pending · read-only|Sign in needed|Device revoked)$/,
  }).first();
  await status.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
  if (!await status.isVisible().catch(() => false)) return;
  const current = (await status.getAttribute('aria-label').catch(() => null)) ||
    (await status.innerText().catch(() => '')).trim();
  if (current !== 'Syncing' &&
      await status.isEnabled().catch(() => false)) await status.click();
}

function readServerSnapshot(selectedRecordId = recordId) {
  const script = String.raw`
import json,sqlite3,sys
db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)
db.row_factory=sqlite3.Row
username,record=sys.argv[2:4]
user=db.execute('SELECT user_id FROM users WHERE username=?',(username,)).fetchone(); assert user
vault=db.execute("SELECT v.vault_id FROM vaults v JOIN vault_members m ON m.vault_id=v.vault_id WHERE v.owner_user_id=? AND m.user_id=? AND m.state='active' AND v.state='active' ORDER BY v.created_at LIMIT 1",(user['user_id'],user['user_id'])).fetchone(); assert vault
vault_id=vault['vault_id']
counter=db.execute('SELECT last_committed_seq,last_conflict_seq FROM vault_counters WHERE vault_id=?',(vault_id,)).fetchone()
versions=db.execute('SELECT revision_id,base_revision_id,commit_seq,device_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record)).fetchall()
conflicts=db.execute('SELECT conflict_id,base_revision_id,resolved_revision_id,conflict_seq,resolution_seq,device_id,op_id,envelope FROM conflicts WHERE vault_id=? AND record_id=? ORDER BY conflict_seq',(vault_id,record)).fetchall()
head=db.execute('SELECT revision_id,deleted FROM record_heads WHERE vault_id=? AND record_id=?',(vault_id,record)).fetchone()
receipts=db.execute('SELECT op_id,revision_id,device_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record)).fetchall()
events=db.execute('SELECT commit_seq,event_type,revision_id FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault_id,record)).fetchall()
def envelope_info(raw):
 try:
  value=json.loads(raw) if raw else {}
  header=value.get('header',{}) if isinstance(value,dict) else {}
  ciphertext=value.get('ciphertext') if isinstance(value,dict) else None
  if not isinstance(header,dict): header={}
  return {'operation':header.get('operation'),'recordId':header.get('record_id'),'revisionId':header.get('revision_id'),'baseRevisionId':header.get('base_revision_id'),'opId':header.get('op_id'),'deviceId':header.get('device_id'),'ciphertextHash':__import__('hashlib').sha256(ciphertext.encode()).hexdigest() if isinstance(ciphertext,str) else None}
 except Exception:
  return {'invalidEnvelope':True}
print(json.dumps({'vaultCommitSeq':str(counter['last_committed_seq']),'vaultConflictSeq':str(counter['last_conflict_seq']),'versions':[{'revisionId':r['revision_id'],'baseRevisionId':r['base_revision_id'],'commitSeq':str(r['commit_seq']),'deviceId':r['device_id'],'operation':r['operation'],'envelope':json.loads(r['envelope'])} for r in versions],'conflictCount':len(conflicts),'conflicts':[{'conflictId':r['conflict_id'],'baseRevisionId':r['base_revision_id'],'resolvedRevisionId':r['resolved_revision_id'],'conflictSeq':str(r['conflict_seq']),'resolutionSeq':str(r['resolution_seq']) if r['resolution_seq'] is not None else None,'deviceId':r['device_id'],'opId':r['op_id'],'branch':envelope_info(r['envelope'])} for r in conflicts],'head':{'revisionId':head['revision_id'],'deleted':bool(head['deleted'])} if head else None,'receipts':[{'opId':r['op_id'],'revisionId':r['revision_id'],'deviceId':r['device_id'],'commitSeq':str(r['commit_seq'])} for r in receipts],'events':[{'commitSeq':str(r['commit_seq']),'eventType':r['event_type'],'revisionId':r['revision_id']} for r in events]},separators=(',',':')))
db.close()
`;
  const result = spawnSync('python3', ['-c', script, databasePath, USERNAME, selectedRecordId], {
    cwd: ROOT, encoding: 'utf8', timeout: 12000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'isolated server snapshot query failed');
  return JSON.parse(result.stdout);
}

function readServerSnapshots(recordIds) {
  return Object.fromEntries(recordIds.map((id) => [id, readServerSnapshot(id)]));
}

async function runInboundStoreRaceScenario({
  ownerPage,
  editorPage,
  siblingPage,
  editorProfilePath,
  baseRevisionId,
  ownerDeviceId,
  credentialMode = false,
  crashReplay = false,
}) {
  const conflictRace = RUN_INBOUND_STORE_CONFLICT_ONLY ||
    RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY ||
    RUN_INBOUND_STORE_CREDENTIAL_ONLY;
  const baselineLocal = await snapshotInboundStoreRace(editorPage, 'baseline');
  assertThat(baselineLocal.integrityCheck === 'ok' &&
    baselineLocal.checkpoints.length === 1 &&
    baselineLocal.checkpoints[0].cursor &&
    baselineLocal.checkpoints[0].serverGeneration &&
    baselineLocal.pendingOperations.length === 0 &&
    baselineLocal.encryptedRecordCache.length === 1 &&
    baselineLocal.encryptedRecordCache[0].revisionId === baseRevisionId &&
    baselineLocal.encryptedRecordCache[0].commitSeq === '1' &&
    baselineLocal.plaintextMarkersAbsent,
  'same-profile editor did not have a clean durable baseline checkpoint/cache');

  const allowPrimarySync = await installSyncRequestBlock(editorPage, 'primary');
  await installSyncRequestBlock(siblingPage, 'sibling');
  setStage(`commit a remote ${credentialMode ? 'Credential secret' : 'Host'} update while same-profile sync requests are held`);
  const ownerPushStart = apiEvents.length;
  const remoteChanges = credentialMode
    ? { Password: MARKERS.credentialRemotePassword }
    : conflictRace
      ? { 'Hostname or IP': MARKERS.remoteAddress }
      : { 'Display name': MARKERS.remoteName };
  await editRecord(ownerPage, credentialMode, remoteChanges);
  await clickSyncWhenIdle(ownerPage);
  await waitFor(() => apiEvents.slice(ownerPushStart).some((event) =>
    event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) => item.recordId === recordId &&
      item.operation === 'update' && item.baseRevisionId === baseRevisionId)),
  `remote ${credentialMode ? 'Credential' : 'Host'} update commits from the shared baseline`);
  const remotePush = apiEvents.slice(ownerPushStart).find((event) =>
    event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
    event.operations.some((item) => item.recordId === recordId && item.operation === 'update'));
  const remoteUpdate = remotePush.operations.find((item) => item.recordId === recordId);
  assertThat(remoteUpdate?.deviceId === ownerDeviceId,
    `remote ${credentialMode ? 'Credential' : 'Host'} update did not use the baseline owner device identity`);
  const remoteSnapshot = readServerSnapshot();
  assertThat(remoteSnapshot.versions.length === 2 &&
    remoteSnapshot.versions.map((item) => item.operation).join(',') === 'create,update' &&
    remoteSnapshot.versions[1].revisionId === remoteUpdate.revisionId &&
    remoteSnapshot.versions[1].baseRevisionId === baseRevisionId &&
    remoteSnapshot.events.length === 2 && remoteSnapshot.receipts.length === 2 &&
    remoteSnapshot.conflictCount === 0 &&
    remoteSnapshot.head?.revisionId === remoteUpdate.revisionId,
  'server did not contain exactly the baseline and the remote winner before the race');

  const pullStart = apiEvents.length;
  await editorPage.evaluate((targetRecordId) => {
    const state = window.__atermiusInboundStoreRaceState;
    state.targetRecordId = targetRecordId;
    state.armed = true;
  }, recordId);
  await allowPrimarySync();
  await clickSyncWhenIdle(editorPage);
  await waitFor(() => editorPage.evaluate(() =>
    window.__atermiusInboundStoreRaceState?.entered === true),
  'primary tab pauses after empty outbox read and before conditional remote store', 45000);
  const hookEvidence = await editorPage.evaluate(() => ({
    entries: window.__atermiusInboundStoreRaceState.entries,
    released: window.__atermiusInboundStoreRaceState.released,
  }));
  assertThat(hookEvidence.entries.length === 1 &&
    hookEvidence.entries[0].recordId === recordId &&
    hookEvidence.entries[0].revisionId === remoteUpdate.revisionId &&
    hookEvidence.entries[0].commitSeq === remoteSnapshot.versions[1].commitSeq &&
    hookEvidence.entries[0].observedPendingOperationCount === 0 &&
    !hookEvidence.released,
  'test barrier did not hold the target remote update after an empty outbox read');
  await waitFor(async () => apiEvents.slice(pullStart).find((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === remoteUpdate.revisionId)),
  'primary receives the remote update page before the store barrier', 20000);
  const inboundPage = apiEvents.slice(pullStart).find((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === remoteUpdate.revisionId));
  assertThat(inboundPage && inboundPage.nextCursor &&
    inboundPage.serverGeneration === baselineLocal.checkpoints[0].serverGeneration,
  'remote update page did not expose its exact cursor and unchanged generation');
  const beforeSiblingSave = await snapshotInboundStoreRace(siblingPage, 'before-sibling-save');
  assertThat(beforeSiblingSave.integrityCheck === 'ok' &&
    beforeSiblingSave.checkpoints.length === 1 &&
    beforeSiblingSave.checkpoints[0].cursor === baselineLocal.checkpoints[0].cursor &&
    beforeSiblingSave.checkpoints[0].serverGeneration ===
      baselineLocal.checkpoints[0].serverGeneration &&
    beforeSiblingSave.pendingOperations.length === 0 &&
    beforeSiblingSave.encryptedRecordCache[0]?.revisionId === baseRevisionId &&
    beforeSiblingSave.plaintextMarkersAbsent,
  'remote update was stored or its cursor advanced while the target page was paused');
  if (credentialMode) {
    await editorPage.evaluate(({ expectedCursor, nextCursor }) => {
      const state = window.__atermiusInboundStoreRaceState;
      state.checkpointExpectedCursor = expectedCursor;
      state.checkpointTargetCursor = nextCursor;
      state.checkpointArmed = true;
    }, {
      expectedCursor: baselineLocal.checkpoints[0].cursor,
      nextCursor: inboundPage.nextCursor,
    });
  }

  setStage(`save a same-record local ${credentialMode ? 'Credential secret' : 'Host'} edit from the sibling tab while primary is paused`);
  const localChanges = credentialMode
    ? { Password: MARKERS.credentialLocalPassword }
    : conflictRace
      ? { 'Hostname or IP': MARKERS.localAddress }
      : { Tags: MARKERS.localTag };
  await editRecord(siblingPage, credentialMode, localChanges);
  const localVisibleValue = credentialMode
    ? { password: MARKERS.credentialLocalPassword }
    : conflictRace
      ? { name: MARKERS.baseName, port: '22', address: MARKERS.localAddress }
      : { name: MARKERS.baseName, port: '22', tag: MARKERS.localTag };
  await waitForRecordValue(siblingPage, credentialMode, localVisibleValue,
    'sibling tab renders its local edit');
  const racedLocal = await snapshotInboundStoreRace(siblingPage, 'local-edit-durable-before-release');
  const localPending = racedLocal.pendingOperations.find((item) =>
    item.status === 'queued' && item.envelopeHeader.operation === 'update');
  assertThat(racedLocal.integrityCheck === 'ok' &&
    racedLocal.checkpoints.length === 1 &&
    racedLocal.checkpoints[0].cursor === baselineLocal.checkpoints[0].cursor &&
    racedLocal.checkpoints[0].serverGeneration ===
      baselineLocal.checkpoints[0].serverGeneration &&
    racedLocal.pendingOperations.length === 1 && Boolean(localPending) &&
    localPending.baseRevisionId === baseRevisionId &&
    localPending.baseEnvelopeHeader.revision_id === baseRevisionId &&
    localPending.envelopeHeader.base_revision_id === baseRevisionId &&
    racedLocal.encryptedRecordCache.length === 1 &&
    racedLocal.encryptedRecordCache[0].revisionId ===
      localPending.envelopeHeader.revision_id &&
    racedLocal.encryptedRecordCache[0].commitSeq === null &&
    racedLocal.plaintextMarkersAbsent,
  'sibling edit was not durably queued against the common base before release');
  const serverBeforeRelease = readServerSnapshot();
  assertThat(serverBeforeRelease.versions.length === 2 &&
    serverBeforeRelease.head?.revisionId === remoteUpdate.revisionId &&
    serverBeforeRelease.receipts.length === 2 && serverBeforeRelease.events.length === 2 &&
    !serverBeforeRelease.receipts.some((item) => item.opId === localPending.opId),
  'local sibling operation reached the server before the guarded store recheck');

  setStage(conflictRace
    ? `release inbound store and preserve same-field ${credentialMode ? 'Credential secret' : 'Host'} conflict`
    : 'release inbound store and run normal same-base Host auto-merge');
  const racePushStart = apiEvents.length;
  await editorPage.evaluate(() => {
    const state = window.__atermiusInboundStoreRaceState;
    state.released = true;
    state.resume?.();
    state.resume = null;
  });
  let conflictDurableBeforeCheckpoint = false;
  if (credentialMode) {
    await waitFor(() => editorPage.evaluate(() =>
      window.__atermiusInboundStoreRaceState?.checkpointEntered === true),
    'Credential conflict is durable before the inbound checkpoint CAS', 45000);
    const checkpointEvidence = await editorPage.evaluate(() => ({
      entries: window.__atermiusInboundStoreRaceState.checkpointEntries,
      released: window.__atermiusInboundStoreRaceState.checkpointReleased,
    }));
    const conflictBeforeCheckpoint = await snapshotInboundStoreRace(
      editorPage, 'credential-conflict-before-checkpoint');
    const branchBeforeCheckpoint = conflictBeforeCheckpoint.conflictBranches[0];
    const serverBeforeCheckpoint = readServerSnapshot();
    const checkpointEntry = checkpointEvidence.entries.find((entry) =>
      entry.expectedCursor === baselineLocal.checkpoints[0].cursor &&
      entry.nextCursor === inboundPage.nextCursor &&
      entry.serverGeneration === inboundPage.serverGeneration &&
      entry.pageEventCount >= 1);
    const branchChecks = {
      count: conflictBeforeCheckpoint.conflictBranches.length === 1,
      kind: branchBeforeCheckpoint?.kind === 'concurrent_edit',
      state: branchBeforeCheckpoint?.state === 'upload_pending',
      localRevision: branchBeforeCheckpoint?.branchEnvelope.header.revision_id ===
        localPending.envelopeHeader.revision_id,
      localCiphertext: branchBeforeCheckpoint?.branchEnvelope.ciphertextHash ===
        localPending.envelopeCiphertextHash,
      remoteRevision: branchBeforeCheckpoint?.remoteEnvelope.header.revision_id ===
        remoteUpdate.revisionId,
      remoteCiphertext: branchBeforeCheckpoint?.remoteEnvelope.ciphertextHash ===
        conflictBeforeCheckpoint.encryptedRecordCache[0]?.envelopeCiphertextHash,
    };
    const checkpointChecks = {
      matchingCheckpointCallback: Boolean(checkpointEntry),
      checkpointNotReleased: !checkpointEvidence.released,
      sqliteIntegrityOk: conflictBeforeCheckpoint.integrityCheck === 'ok',
      oneCheckpointRow: conflictBeforeCheckpoint.checkpoints.length === 1,
      oldCursorRetained: conflictBeforeCheckpoint.checkpoints[0]?.cursor ===
        baselineLocal.checkpoints[0].cursor,
      oldGenerationRetained: conflictBeforeCheckpoint.checkpoints[0]?.serverGeneration ===
        baselineLocal.checkpoints[0].serverGeneration,
      oneConflictPendingOperation: conflictBeforeCheckpoint.pendingOperations.length === 1 &&
        conflictBeforeCheckpoint.pendingOperations[0]?.status === 'conflict' &&
        conflictBeforeCheckpoint.pendingOperations[0]?.opId === localPending.opId,
      remoteEncryptedCacheInstalled: conflictBeforeCheckpoint.encryptedRecordCache.length === 1 &&
        conflictBeforeCheckpoint.encryptedRecordCache[0]?.revisionId === remoteUpdate.revisionId &&
        conflictBeforeCheckpoint.encryptedRecordCache[0]?.commitSeq ===
          remoteSnapshot.versions[1].commitSeq,
      bothConflictBranchesRetained: Object.values(branchChecks).every(Boolean),
      localCredentialMarkersAbsent: conflictBeforeCheckpoint.plaintextMarkersAbsent,
      staleOperationNotAcceptedByServer: serverBeforeCheckpoint.versions.length === 2 &&
        serverBeforeCheckpoint.events.length === 2 &&
        serverBeforeCheckpoint.receipts.length === 2 &&
        !serverBeforeCheckpoint.receipts.some((item) => item.opId === localPending.opId),
    };
    assertThat(Object.values(checkpointChecks).every(Boolean),
      `Credential checkpoint boundary failed branch checks: ${JSON.stringify(branchChecks)}; other checks: ${JSON.stringify(checkpointChecks)}`);
    if (crashReplay) {
      const storageBeforeCrash = await safeWebStorageKinds(editorPage);
      assertThat(storageBeforeCrash.localStorage.device +
        storageBeforeCrash.sessionStorage.device > 0,
      'editor device key was not present in browser storage before SIGKILL');
      setStage('verify same-profile Web storage while the Credential checkpoint callback remains held');
      const storageProbePage = await editorContext.newPage();
      await storageProbePage.addInitScript((expectedOrigin) => {
        const summarize = (storage) => {
          const counts = { device: 0, session: 0, refresh: 0, lastServer: 0, other: 0 };
          for (let index = 0; index < storage.length; index += 1) {
            const key = storage.key(index) || '';
            if (key.endsWith('.device')) counts.device += 1;
            else if (key.includes('.session.')) counts.session += 1;
            else if (key.includes('.refresh.')) counts.refresh += 1;
            else if (key.endsWith('.last-server')) counts.lastServer += 1;
            else counts.other += 1;
          }
          return counts;
        };
        Object.defineProperty(window, '__atermiusCrashStorageAtStart', {
          value: {
            originMatches: location.origin === expectedOrigin,
            localStorage: summarize(localStorage),
            sessionStorage: summarize(sessionStorage),
          },
        });
      }, new URL(baseUrl).origin);
      await storageProbePage.goto(`${baseUrl}/health/ready`, {
        waitUntil: 'domcontentloaded', timeout: 10000,
      });
      const probeStorageAtDocumentStart = await storageProbePage.evaluate(() =>
        window.__atermiusCrashStorageAtStart || null);
      const probeStorageBeforeWrite = await safeWebStorageKinds(storageProbePage);
      assertThat(probeStorageAtDocumentStart?.originMatches === true &&
        probeStorageAtDocumentStart.localStorage.device +
          probeStorageAtDocumentStart.sessionStorage.device > 0 &&
        probeStorageBeforeWrite.localStorage.device +
          probeStorageBeforeWrite.sessionStorage.device > 0,
      `fresh same-origin tab could not read the registered editor device key: ${JSON.stringify({
        atDocumentStart: probeStorageAtDocumentStart,
        current: probeStorageBeforeWrite,
      })}`);

      const storageProbeFingerprint = localStorageLevelDbFingerprint(editorProfilePath);
      await storageProbePage.evaluate(({ key, value }) => {
        localStorage.setItem(key, value);
      }, { key: LOCAL_STORAGE_CRASH_PROBE_KEY, value: LOCAL_STORAGE_CRASH_PROBE_VALUE });
      const storageProbeCommit = await waitForLocalStorageLevelDbCommit(
        editorProfilePath, storageProbeFingerprint, { requireChange: true, timeoutMs: 15000 });
      const probeValueReadable = await storageProbePage.evaluate(({ key, value }) =>
        localStorage.getItem(key) === value,
      { key: LOCAL_STORAGE_CRASH_PROBE_KEY, value: LOCAL_STORAGE_CRASH_PROBE_VALUE });
      const checkpointCallbackStillHeld = await editorPage.evaluate(() =>
        window.__atermiusInboundStoreRaceState?.checkpointEntered === true &&
        window.__atermiusInboundStoreRaceState?.checkpointReleased === false);
      console.log('Credential same-profile storage durability barrier', JSON.stringify({
        checkpointCallbackStillHeld,
        documentStart: probeStorageAtDocumentStart,
        deviceBeforeWrite: probeStorageBeforeWrite.localStorage.device +
          probeStorageBeforeWrite.sessionStorage.device,
        probeWriteCommit: storageProbeCommit,
        probeValueReadable,
      }));
      assertThat(checkpointCallbackStillHeld && storageProbeCommit.changed &&
        storageProbeCommit.stable && probeValueReadable,
      `same-profile Local Storage durability probe did not reach a changed stable LevelDB state: ${JSON.stringify(storageProbeCommit)}`);
      const storageAfterProbeCommit = await safeWebStorageKinds(storageProbePage);
      assertThat(storageAfterProbeCommit.localStorage.device +
        storageAfterProbeCommit.sessionStorage.device > 0,
      'same-profile device identity disappeared after the Local Storage durability probe commit');

      const conflictAfterStorageProbe = await snapshotInboundStoreRace(
        editorPage, 'credential-crash-before-kill-after-storage-probe');
      assertThat(conflictAfterStorageProbe.integrityCheck === 'ok' &&
        conflictAfterStorageProbe.checkpoints[0]?.cursor ===
          baselineLocal.checkpoints[0].cursor &&
        conflictAfterStorageProbe.checkpoints[0]?.serverGeneration ===
          baselineLocal.checkpoints[0].serverGeneration &&
        conflictAfterStorageProbe.pendingOperations.length === 1 &&
        conflictAfterStorageProbe.pendingOperations[0]?.status === 'conflict' &&
        conflictAfterStorageProbe.conflictBranches.length === 1,
      'Local Storage durability barrier changed the held Credential conflict or old checkpoint');
      const serverAfterStorageProbe = readServerSnapshot();
      assertThat(serverAfterStorageProbe.versions.length === 2 &&
        serverAfterStorageProbe.events.length === 2 &&
        serverAfterStorageProbe.receipts.length === 2 &&
        serverAfterStorageProbe.vaultCommitSeq === remoteSnapshot.vaultCommitSeq &&
        serverAfterStorageProbe.head?.revisionId === remoteUpdate.revisionId,
      'Local Storage durability barrier changed the server ledger before crash replay');
      setStage('SIGKILL Chromium with the durable Credential conflict and checkpoint callback still held');
      const killedIdentity = await forceKillChromiumProfile(editorProfilePath);
      editorContext = null;
      editorDiagnosticPage = null;
      editorPage = null;
      siblingPage = null;

      const replayApiStart = apiEvents.length;
      let releaseReplayRoutes;
      let storageAtDocumentStart;
      const restarted = await launchProfile(editorProfilePath, 'primary', false,
        async ({ context, page }) => {
          for (const restoredPage of context.pages()) {
            if (restoredPage !== page) await restoredPage.close().catch(() => {});
          }
          await page.addInitScript((expectedOrigin) => {
            const summarize = (storage) => {
              const counts = { device: 0, session: 0, refresh: 0, lastServer: 0, other: 0 };
              for (let index = 0; index < storage.length; index += 1) {
                const key = storage.key(index) || '';
                if (key.endsWith('.device')) counts.device += 1;
                else if (key.includes('.session.')) counts.session += 1;
                else if (key.includes('.refresh.')) counts.refresh += 1;
                else if (key.endsWith('.last-server')) counts.lastServer += 1;
                else counts.other += 1;
              }
              return counts;
            };
            Object.defineProperty(window, '__atermiusStorageKindsAtStart', {
              value: {
                originMatches: location.origin === expectedOrigin,
                localStorage: summarize(localStorage),
                sessionStorage: summarize(sessionStorage),
              },
            });
          }, new URL(baseUrl).origin);
          releaseReplayRoutes = await installSyncRequestBlock(
            page, 'primary', ['push', 'conflict-create']);
        });
      editorContext = restarted.context;
      editorPage = restarted.page;
      editorDiagnosticPage = restarted.page;
      storageAtDocumentStart = await editorPage.evaluate(() =>
        window.__atermiusStorageKindsAtStart || null);
      const relaunchedIdentity = chromiumProfileProcessIdentity(editorProfilePath);
      assertThat(relaunchedIdentity.pid !== killedIdentity.pid ||
        relaunchedIdentity.startTimeTicks !== killedIdentity.startTimeTicks,
      'same-profile crash replay reused the terminated Chromium process identity');
      const storageAfterCrash = await safeWebStorageKinds(editorPage);
      assertThat(storageAfterCrash.localStorage.device +
        storageAfterCrash.sessionStorage.device > 0,
      `same-profile Chromium crash lost its registered device key: ${JSON.stringify({
        before: storageBeforeCrash,
        atDocumentStart: storageAtDocumentStart,
        after: storageAfterCrash,
      })}`);

      setStage('reopen the same profile at the old cursor and replay the inbound Credential event');
      await recoverSameProfileWorkspace(editorPage);
      await openCredentialsPage(editorPage);
      await waitCredentialRecord(editorPage, MARKERS.credentialName, recordId);
      await waitFor(() => apiEvents.slice(replayApiStart).filter((event) =>
        event.profile === 'primary' && event.route === 'changes' &&
        event.status === 200 && event.bodyRead &&
        event.requestCursor === baselineLocal.checkpoints[0].cursor &&
        event.nextCursor === inboundPage.nextCursor &&
        event.changeEvents.filter((item) => item.recordId === recordId &&
          item.revisionId === remoteUpdate.revisionId).length === 1).length === 1,
      'crash-restarted profile requests the exact remote changes page once from the saved old cursor',
      45000);
      const replayPage = apiEvents.slice(replayApiStart).find((event) =>
        event.profile === 'primary' && event.route === 'changes' &&
        event.status === 200 && event.bodyRead &&
        event.requestCursor === baselineLocal.checkpoints[0].cursor &&
        event.nextCursor === inboundPage.nextCursor &&
        event.changeEvents.some((item) => item.recordId === recordId &&
          item.revisionId === remoteUpdate.revisionId));
      await waitForRecordValue(editorPage, true,
        { password: MARKERS.credentialRemotePassword },
        'crash replay restores the remote Credential value while retaining the local conflict branch');
      await waitFor(() => deliberatelyAbortedSyncRequests.primary.some((item) =>
        item.route === 'conflict-create'),
      'conflict upload remains blocked until the replayed SQLite checkpoint is inspected', 30000);

      let replayedLocal;
      const replayDeadline = Date.now() + 30000;
      do {
        replayedLocal = await snapshotInboundStoreRace(
          editorPage, 'credential-crash-replay-after-checkpoint');
        if (replayedLocal.checkpoints[0]?.cursor === inboundPage.nextCursor) break;
        await new Promise((resolve) => setTimeout(resolve, 150));
      } while (Date.now() < replayDeadline);
      const replayBranch = replayedLocal.conflictBranches[0];
      const replayChecks = {
        oneExactReplayPage: replayPage?.requestCursor === baselineLocal.checkpoints[0].cursor &&
          replayPage.nextCursor === inboundPage.nextCursor && replayPage.serverGeneration ===
            inboundPage.serverGeneration && replayPage.changeEvents.filter((item) =>
              item.recordId === recordId && item.revisionId === remoteUpdate.revisionId).length === 1 &&
          apiEvents.slice(replayApiStart).filter((event) =>
            event.profile === 'primary' && event.route === 'changes' &&
            event.status === 200 && event.bodyRead &&
            event.requestCursor === baselineLocal.checkpoints[0].cursor &&
            event.changeEvents.some((item) => item.recordId === recordId &&
              item.revisionId === remoteUpdate.revisionId)).length === 1,
        sqliteIntegrityOk: replayedLocal.integrityCheck === 'ok',
        singleCheckpoint: replayedLocal.checkpoints.length === 1,
        exactCursorAndGeneration: replayedLocal.checkpoints[0]?.cursor === inboundPage.nextCursor &&
          replayedLocal.checkpoints[0]?.serverGeneration === inboundPage.serverGeneration,
        oneConflictOutboxOperation: replayedLocal.pendingOperations.length === 1 &&
          replayedLocal.pendingOperations[0]?.status === 'conflict' &&
          replayedLocal.pendingOperations[0]?.opId === localPending.opId,
        oneConflictPair: replayedLocal.conflictBranches.length === 1 &&
          replayBranch?.kind === 'concurrent_edit' && replayBranch.state === 'upload_pending',
        originalLocalBranchRetained:
          replayBranch?.branchEnvelope.header.revision_id === localPending.envelopeHeader.revision_id &&
          replayBranch?.branchEnvelope.ciphertextHash === branchBeforeCheckpoint.branchEnvelope.ciphertextHash,
        originalRemoteBranchRetained:
          replayBranch?.remoteEnvelope.header.revision_id === remoteUpdate.revisionId &&
          replayBranch?.remoteEnvelope.ciphertextHash === branchBeforeCheckpoint.remoteEnvelope.ciphertextHash,
        remoteEncryptedCacheRetained: replayedLocal.encryptedRecordCache.length === 1 &&
          replayedLocal.encryptedRecordCache[0]?.revisionId === remoteUpdate.revisionId &&
          replayedLocal.encryptedRecordCache[0]?.commitSeq === remoteSnapshot.versions[1].commitSeq,
        plaintextMarkersAbsent: replayedLocal.plaintextMarkersAbsent,
        noOrdinaryStaleOperationPush: !apiEvents.slice(replayApiStart).some((event) =>
          event.profile === 'primary' && event.route === 'push' &&
          event.operations.some((item) => item.opId === localPending.opId)),
        conflictUploadNotAcceptedYet: !apiEvents.slice(replayApiStart).some((event) =>
          event.profile === 'primary' && event.route === 'conflict-create' &&
          event.status === 200 && event.operations.some((item) =>
            item.opId === localPending.opId)),
      };
      const serverAfterCrashReplay = readServerSnapshot();
      replayChecks.serverLedgerUnchanged =
        JSON.stringify(serverAfterCrashReplay) === JSON.stringify(serverBeforeCheckpoint);
      assertThat(Object.values(replayChecks).every(Boolean),
        `Credential crash replay failed durable state checks: ${JSON.stringify(replayChecks)}`);
      assertThat(typeof releaseReplayRoutes === 'function',
        'same-profile restart did not install the bounded sync-request barrier');
      await releaseReplayRoutes();
      conflictDurableBeforeCheckpoint = true;
    } else {
      await editorPage.evaluate(() => {
        const state = window.__atermiusInboundStoreRaceState;
        state.checkpointArmed = false;
        state.checkpointReleased = true;
        state.checkpointResume?.();
        state.checkpointResume = null;
      });
      conflictDurableBeforeCheckpoint = true;
    }
  }
  if (conflictRace) {
    await runInboundStoreConflictScenario({
      editorPage,
      siblingPage,
      editorProfilePath,
      baselineLocal,
      inboundPage,
      hookEvidence,
      remoteUpdate,
      remoteSnapshot,
      localPending,
      racePushStart,
      keepLocal: !RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY &&
        !RUN_INBOUND_STORE_CREDENTIAL_REMOTE_CONFLICT_ONLY,
      credentialMode,
      conflictDurableBeforeCheckpoint,
      profileAlreadyRestarted: crashReplay,
    });
    return;
  }
  await waitFor(() => successfulPush('primary', racePushStart),
    'primary pushes one merged Host update after the conditional store rejects', 60000);
  const mergedPush = successfulPush('primary', racePushStart);
  const mergedOperation = mergedPush.operations.find((item) => item.recordId === recordId);
  assertThat(mergedOperation?.operation === 'update' &&
    mergedOperation.baseRevisionId === remoteUpdate.revisionId &&
    mergedOperation.revisionId !== localPending.envelopeHeader.revision_id &&
    mergedOperation.opId !== localPending.opId &&
    mergedOperation.deviceId === localPending.envelopeHeader.device_id,
  'normal re-read path did not coalesce the local edit over the remote head');
  assertThat(!apiEvents.slice(racePushStart).some((event) =>
    event.profile === 'primary' && event.route === 'conflict-create' && event.status === 200 &&
    event.operations.some((item) => item.recordId === recordId)),
  'non-overlapping Host field edits were incorrectly uploaded as a conflict');

  const mergedHost = {
    name: MARKERS.remoteName,
    port: '22',
    tag: MARKERS.localTag,
  };
  await waitForHostValues(editorPage, mergedHost,
    'primary decrypts remote Display Name and sibling Tags after merge');
  const mergedServer = readServerSnapshot();
  assertThat(mergedServer.versions.length === 3 &&
    mergedServer.versions.map((item) => item.operation).join(',') === 'create,update,update' &&
    mergedServer.versions[1].revisionId === remoteUpdate.revisionId &&
    mergedServer.versions[2].revisionId === mergedOperation.revisionId &&
    mergedServer.versions[2].baseRevisionId === remoteUpdate.revisionId &&
    mergedServer.versions[2].deviceId === localPending.envelopeHeader.device_id &&
    mergedServer.events.length === 3 && mergedServer.receipts.length === 3 &&
    mergedServer.conflictCount === 0 &&
    mergedServer.head?.revisionId === mergedOperation.revisionId &&
    mergedServer.receipts[2].opId === mergedOperation.opId &&
    mergedServer.receipts[2].revisionId === mergedOperation.revisionId &&
    !mergedServer.receipts.some((item) => item.opId === localPending.opId),
  'server ledger did not commit exactly one merged update without a stale local receipt');
  const mergedLocalBeforeRestart = await snapshotInboundStoreRace(
    editorPage, 'merged-before-restart');
  assertThat(mergedLocalBeforeRestart.integrityCheck === 'ok' &&
    mergedLocalBeforeRestart.encryptedRecordCache.length === 1 &&
    mergedLocalBeforeRestart.encryptedRecordCache[0].revisionId === mergedOperation.revisionId &&
    mergedLocalBeforeRestart.encryptedRecordCache[0].commitSeq ===
      mergedServer.versions[2].commitSeq &&
    !mergedLocalBeforeRestart.pendingOperations.some((item) =>
      ['queued', 'sent', 'cas_wait'].includes(item.status)) &&
    mergedLocalBeforeRestart.checkpoints[0]?.cursor === inboundPage.nextCursor &&
    mergedLocalBeforeRestart.checkpoints[0]?.serverGeneration ===
      inboundPage.serverGeneration &&
    mergedLocalBeforeRestart.plaintextMarkersAbsent,
  'pre-restart sharedIndexedDb did not retain merged cache, clear active outbox, and stop at the inbound page boundary');

  setStage('restart the same persistent editor profile and pull its own merged event');
  const restartApiStart = apiEvents.length;
  await siblingPage.close().catch(() => {});
  await editorContext.close();
  editorContext = null;
  const restarted = await launchProfile(editorProfilePath, 'primary');
  editorContext = restarted.context;
  await recoverSameProfileWorkspace(restarted.page);
  await click(restarted.page, 'Hosts');
  await waitHost(restarted.page, MARKERS.remoteName, recordId);
  await waitForHostValues(restarted.page, mergedHost,
    'restarted same profile decrypts both merged fields');
  await clickSyncWhenIdle(restarted.page);
  await waitFor(() => apiEvents.slice(restartApiStart).find((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === mergedOperation.revisionId)),
  'same-profile restart replays the committed local merged event', 45000);
  const ownEventPage = apiEvents.slice(restartApiStart).find((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === mergedOperation.revisionId));
  assertThat(ownEventPage?.nextCursor && ownEventPage.serverGeneration ===
    inboundPage.serverGeneration,
  'restart own-event page did not carry the expected cursor generation');
  await waitForHostValues(restarted.page, mergedHost,
    'restart remains converged after own-event replay');
  const restartedLocal = await snapshotInboundStoreRace(restarted.page, 'after-restart-sync');
  assertThat(restartedLocal.integrityCheck === 'ok' &&
    restartedLocal.checkpoints.length === 1 &&
    restartedLocal.checkpoints[0].cursor === ownEventPage.nextCursor &&
    restartedLocal.checkpoints[0].serverGeneration === ownEventPage.serverGeneration &&
    restartedLocal.encryptedRecordCache.length === 1 &&
    restartedLocal.encryptedRecordCache[0].revisionId === mergedOperation.revisionId &&
    restartedLocal.encryptedRecordCache[0].commitSeq === mergedServer.versions[2].commitSeq &&
    !restartedLocal.pendingOperations.some((item) =>
      ['queued', 'sent', 'cas_wait'].includes(item.status)) &&
    restartedLocal.plaintextMarkersAbsent,
  'same-profile restart did not converge its durable checkpoint/cache/outbox');
  const afterRestartServer = readServerSnapshot();
  assertThat(afterRestartServer.versions.length === 3 &&
    afterRestartServer.events.length === 3 && afterRestartServer.receipts.length === 3 &&
    afterRestartServer.head?.revisionId === mergedOperation.revisionId &&
    afterRestartServer.receipts.filter((item) =>
      item.opId === mergedOperation.opId && item.revisionId === mergedOperation.revisionId).length === 1 &&
    afterRestartServer.receipts.filter((item) => item.opId === localPending.opId).length === 0,
  'same-profile restart created a duplicate operation, event, receipt, or head');
  assertThat(!apiEvents.slice(restartApiStart).some((event) =>
    event.profile === 'primary' && event.route === 'push' &&
    event.operations.some((item) => item.recordId === recordId)),
  'same-profile restart attempted to push an already acknowledged record operation');

  setStage('verify privacy, browser errors, and isolated fixture cleanup');
  assertCiphertextOnly();
  const unexpectedConsoleErrors = Object.entries(consoleErrorMessages).flatMap(([profile, messages]) =>
    messages.filter((item) => !item.expectedAbortedSyncRequest).map((item) => ({ profile, ...item })));
  assertThat(pageErrors.owner === 0 && pageErrors.primary === 0 && pageErrors.sibling === 0 &&
    unexpectedConsoleErrors.length === 0,
  'same-profile inbound-store race raised a browser error outside the deliberate sibling sync block');
  await cleanup();
  assertThat(!cleanupFailed, 'isolated inbound-store race fixture cleanup failed');
  console.log(`${ACCEPTANCE_ID} passed`, JSON.stringify({
    samePersistentProfileTabs: 2,
    sharedIndexedDbBackend: true,
    initialOutboxReadWasEmpty: hookEvidence.entries[0].observedPendingOperationCount === 0,
    localEditCommittedBeforeConditionalRemoteStore: true,
    conditionalStoreRejectedAndNormalAutoMergeRan: true,
    bothSidesPreserved: ['remote Display Name', 'local Tags'],
    actualSqliteCheckpointCacheOutboxInspected: true,
    serverHistory: ['create', 'remote update', 'single merged update'],
    conflictBranches: 0,
    sameProfileRestartPulledOwnEvent: true,
    noDuplicateOperationOrReceipt: true,
    sqliteIntegrity: restartedLocal.integrityCheck,
    plaintextMarkersAbsent: true,
    unexpectedConsoleErrors: unexpectedConsoleErrors.length,
    pageErrors: pageErrors.owner + pageErrors.primary + pageErrors.sibling,
    fixtureCleanupComplete: true,
    siblingSyncAborts: deliberatelyAbortedSyncRequests.sibling.length,
  }));
}

async function runInboundStoreConflictScenario({
  editorPage,
  siblingPage,
  editorProfilePath,
  baselineLocal,
  inboundPage,
  hookEvidence,
  remoteUpdate,
  remoteSnapshot,
  localPending,
  racePushStart,
  keepLocal,
  credentialMode = false,
  conflictDurableBeforeCheckpoint = false,
  profileAlreadyRestarted = false,
}) {
  const branchValue = (local) => credentialMode
    ? { password: local ? MARKERS.credentialLocalPassword : MARKERS.credentialRemotePassword }
    : {
      name: MARKERS.baseName,
      port: '22',
      address: local ? MARKERS.localAddress : MARKERS.remoteAddress,
    };
  await waitFor(() => apiEvents.slice(racePushStart).find((event) =>
    event.profile === 'primary' && event.route === 'conflict-create' &&
    event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.recordId === recordId &&
      item.opId === localPending.opId)),
  `server stores the paused local ${credentialMode ? 'Credential' : 'Host'} branch as one conflict without a record push`, 60000);
  const conflictUpload = apiEvents.slice(racePushStart).find((event) =>
    event.profile === 'primary' && event.route === 'conflict-create' &&
    event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.recordId === recordId &&
      item.opId === localPending.opId));
  const serverConflictId = conflictUpload?.conflictId;
  assertThat(serverConflictId && conflictUpload.operations.length === 1 &&
    conflictUpload.operations[0].revisionId === localPending.envelopeHeader.revision_id &&
    conflictUpload.operations[0].baseRevisionId === baselineLocal.encryptedRecordCache[0].revisionId &&
    conflictUpload.operations[0].deviceId === localPending.envelopeHeader.device_id,
  'server conflict upload did not preserve the exact stale local signed revision');
  assertThat(!apiEvents.slice(racePushStart).some((event) =>
    event.profile === 'primary' && event.route === 'push' &&
    event.operations.some((item) => item.recordId === recordId &&
      item.opId === localPending.opId)),
  'stale local branch was incorrectly submitted through the ordinary record push API');

  const serverBeforeResolution = readServerSnapshot();
  const serverConflict = serverBeforeResolution.conflicts?.[0];
  assertThat(serverBeforeResolution.versions.length === 2 &&
    serverBeforeResolution.versions.map((item) => item.operation).join(',') === 'create,update' &&
    serverBeforeResolution.events.length === 2 &&
    serverBeforeResolution.receipts.length === 2 &&
    serverBeforeResolution.vaultCommitSeq === '2' &&
    serverBeforeResolution.vaultConflictSeq === '1' &&
    serverBeforeResolution.conflictCount === 1 &&
    serverConflict?.conflictId === serverConflictId &&
    serverConflict.baseRevisionId === baselineLocal.encryptedRecordCache[0].revisionId &&
    serverConflict.resolvedRevisionId === null &&
    serverConflict.conflictSeq === '1' &&
    serverConflict.resolutionSeq === null &&
    serverConflict.opId === localPending.opId &&
    serverConflict.branch.revisionId === localPending.envelopeHeader.revision_id &&
    serverConflict.branch.baseRevisionId === baselineLocal.encryptedRecordCache[0].revisionId &&
    serverConflict.branch.ciphertextHash === localPending.envelopeCiphertextHash &&
    serverBeforeResolution.head?.revisionId === remoteUpdate.revisionId &&
    !serverBeforeResolution.receipts.some((item) => item.opId === localPending.opId),
  'conflict branch upload changed the record ledger or failed to retain the exact local signed branch');

  const localConflict = await snapshotInboundStoreRace(editorPage,
    'conflict-durable-before-restart');
  const conflictBranch = localConflict.conflictBranches?.[0];
  assertThat(localConflict.integrityCheck === 'ok' &&
    localConflict.checkpoints.length === 1 &&
    localConflict.checkpoints[0].cursor === inboundPage.nextCursor &&
    localConflict.checkpoints[0].serverGeneration === inboundPage.serverGeneration &&
    localConflict.encryptedRecordCache.length === 1 &&
    localConflict.encryptedRecordCache[0].revisionId === remoteUpdate.revisionId &&
    localConflict.encryptedRecordCache[0].commitSeq === remoteSnapshot.versions[1].commitSeq &&
    localConflict.pendingOperations.length === 1 &&
    localConflict.pendingOperations[0].status === 'conflict' &&
    localConflict.pendingOperations[0].opId === localPending.opId &&
    localConflict.conflictBranches.length === 1 &&
    conflictBranch?.conflictId === serverConflictId &&
    conflictBranch.kind === 'concurrent_edit' && conflictBranch.state === 'open' &&
    conflictBranch.branchEnvelope.header.revision_id === localPending.envelopeHeader.revision_id &&
    conflictBranch.branchEnvelope.header.op_id === localPending.opId &&
    conflictBranch.branchEnvelope.ciphertextHash === localPending.envelopeCiphertextHash &&
    conflictBranch.remoteEnvelope.header.revision_id === remoteUpdate.revisionId &&
    conflictBranch.remoteEnvelope.ciphertextHash ===
      localConflict.encryptedRecordCache[0].envelopeCiphertextHash &&
    localConflict.plaintextMarkersAbsent,
  'SQLite did not atomically retain both encrypted branches, conflict outbox state, remote cache, and the exact inbound checkpoint');

  setStage(profileAlreadyRestarted
    ? 'continue in the crash-restarted profile with the unresolved local conflict durable'
    : 'restart the same profile with the unresolved local conflict durable');
  let firstRestart;
  if (profileAlreadyRestarted) {
    firstRestart = { context: editorContext, page: editorPage };
  } else {
    if (siblingPage) await siblingPage.close().catch(() => {});
    await editorContext.close();
    editorContext = null;
    firstRestart = await launchProfile(editorProfilePath, 'primary');
    editorContext = firstRestart.context;
    await recoverSameProfileWorkspace(firstRestart.page);
  }
  editorDiagnosticPage = firstRestart.page;
  await openRecordList(firstRestart.page, credentialMode);
  await waitRecord(firstRestart.page, credentialMode);
  await waitForRecordValue(firstRestart.page, credentialMode, branchValue(false),
    'restarted profile keeps the current remote record head visible');
  const firstRestartLocal = await snapshotInboundStoreRace(firstRestart.page,
    'conflict-after-first-restart');
  assertThat(firstRestartLocal.integrityCheck === 'ok' &&
    firstRestartLocal.checkpoints[0]?.cursor === inboundPage.nextCursor &&
    firstRestartLocal.checkpoints[0]?.serverGeneration === inboundPage.serverGeneration &&
    firstRestartLocal.encryptedRecordCache[0]?.revisionId === remoteUpdate.revisionId &&
    firstRestartLocal.pendingOperations.length === 1 &&
    firstRestartLocal.pendingOperations[0].status === 'conflict' &&
    firstRestartLocal.conflictBranches.length === 1 &&
    firstRestartLocal.conflictBranches[0].conflictId === serverConflictId &&
    firstRestartLocal.conflictBranches[0].state === 'open' &&
    firstRestartLocal.plaintextMarkersAbsent,
  'same-profile restart lost the unresolved branch or rewound the committed remote cache/checkpoint');

  const conflictNavigation = firstRestart.page.getByRole('button', {
    name: /^Sync & conflicts(?:\s+\d+)?$/,
  }).first();
  await conflictNavigation.waitFor({ state: 'visible', timeout: 20000 });
  await conflictNavigation.click();
  await waitFor(() => firstRestart.page.getByText('Conflict branches', { exact: true })
    .isVisible().catch(() => false), 'restarted conflict review panel');
  await waitForSemanticText(firstRestart.page, 'Local revision');
  await waitForSemanticText(firstRestart.page, 'Remote revision');

  // Hold the changes feed after the user decision so the second same-profile
  // restart has to replay the newly committed resolution revision.
  await installResolutionReplayBarrier(
    firstRestart.page, 'primary', remoteUpdate.revisionId);
  const resolutionChoice = keepLocal ? 'local' : 'remote';
  const resolutionButtonLabel = keepLocal ? 'Keep this device version' : 'Use synced version';
  const resolutionDialogTitle = keepLocal
    ? 'Keep this device version?'
    : 'Use the synced version?';
  setStage(`explicitly keep the ${resolutionChoice} same-field ${credentialMode ? 'Credential secret' : 'Host'} branch`);
  const resolutionButton = await visibleButton(firstRestart.page, resolutionButtonLabel);
  assertThat(await resolutionButton.isEnabled(),
    `${resolutionChoice} branch could not be explicitly selected after same-profile restart`);
  const resolutionStart = apiEvents.length;
  await resolutionButton.click();
  await waitForSemanticText(firstRestart.page, resolutionDialogTitle);
  await click(firstRestart.page, 'Create resolution');
  await waitFor(() => apiEvents.slice(resolutionStart).some((event) =>
    event.profile === 'primary' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) => item.recordId === recordId &&
      item.operation === 'update' && item.baseRevisionId === remoteUpdate.revisionId)),
  'one newly signed resolution update commits against the remote head', 60000);
  const resolutionPush = apiEvents.slice(resolutionStart).find((event) =>
    event.profile === 'primary' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) => item.recordId === recordId &&
      item.operation === 'update' && item.baseRevisionId === remoteUpdate.revisionId));
  const resolutionOperation = resolutionPush.operations.find((item) =>
    item.recordId === recordId && item.operation === 'update');
  assertThat(resolutionPush.operations.filter((item) => item.recordId === recordId).length === 1 &&
    resolutionOperation.opId !== localPending.opId &&
    resolutionOperation.revisionId !== localPending.envelopeHeader.revision_id &&
    resolutionOperation.baseRevisionId === remoteUpdate.revisionId &&
    resolutionOperation.deviceId === localPending.envelopeHeader.device_id,
  'explicit resolution did not create exactly one new editor-signed update based on the remote revision');
  await waitFor(() => apiEvents.slice(resolutionStart).some((event) =>
    event.profile === 'primary' && event.route === 'conflict-resolve' &&
    event.status === 200 && event.bodyRead &&
    event.resolution?.resolvedRevisionId === resolutionOperation.revisionId),
  'server records the explicit conflict resolution receipt', 45000);
  const resolutionReceipt = apiEvents.slice(resolutionStart).find((event) =>
    event.profile === 'primary' && event.route === 'conflict-resolve' &&
    event.status === 200 && event.bodyRead &&
    event.resolution?.resolvedRevisionId === resolutionOperation.revisionId);
  assertThat(resolutionReceipt.resolution.status === 'resolved' &&
    resolutionReceipt.resolution.alreadyResolved === false &&
    resolutionReceipt.resolution.resolutionSeq === '2',
  'server did not acknowledge the first resolution against the newly committed revision');

  await openRecordList(firstRestart.page, credentialMode);
  await waitForRecordValue(firstRestart.page, credentialMode, branchValue(keepLocal),
    `explicit resolution presents the selected ${resolutionChoice} record branch`);
  const serverAfterResolution = readServerSnapshot();
  assertThat(serverAfterResolution.versions.length === 3 &&
    serverAfterResolution.versions.map((item) => item.operation).join(',') === 'create,update,update' &&
    serverAfterResolution.versions[1].revisionId === remoteUpdate.revisionId &&
    serverAfterResolution.versions[2].revisionId === resolutionOperation.revisionId &&
    serverAfterResolution.versions[2].baseRevisionId === remoteUpdate.revisionId &&
    serverAfterResolution.events.length === 3 &&
    serverAfterResolution.receipts.length === 3 &&
    serverAfterResolution.vaultCommitSeq === '3' &&
    serverAfterResolution.vaultConflictSeq === '2' &&
    serverAfterResolution.conflictCount === 1 &&
    serverAfterResolution.conflicts[0].conflictId === serverConflictId &&
    serverAfterResolution.conflicts[0].resolvedRevisionId === resolutionOperation.revisionId &&
    serverAfterResolution.conflicts[0].conflictSeq === '1' &&
    serverAfterResolution.conflicts[0].resolutionSeq === '2' &&
    serverAfterResolution.conflicts[0].opId === localPending.opId &&
    serverAfterResolution.conflicts[0].branch.revisionId ===
      localPending.envelopeHeader.revision_id &&
    serverAfterResolution.head?.revisionId === resolutionOperation.revisionId &&
    serverAfterResolution.receipts.filter((item) =>
      item.opId === resolutionOperation.opId &&
      item.revisionId === resolutionOperation.revisionId).length === 1 &&
    !serverAfterResolution.receipts.some((item) => item.opId === localPending.opId),
  'server history did not retain both conflict branches and exactly one committed resolution');
  const resolvedLocalBeforeRestart = await snapshotInboundStoreRace(firstRestart.page,
    'resolution-before-second-restart');
  assertThat(resolvedLocalBeforeRestart.integrityCheck === 'ok' &&
    resolvedLocalBeforeRestart.checkpoints[0]?.cursor === inboundPage.nextCursor &&
    resolvedLocalBeforeRestart.checkpoints[0]?.serverGeneration === inboundPage.serverGeneration &&
    resolvedLocalBeforeRestart.encryptedRecordCache[0]?.revisionId === resolutionOperation.revisionId &&
    resolvedLocalBeforeRestart.encryptedRecordCache[0]?.commitSeq ===
      serverAfterResolution.versions[2].commitSeq &&
    resolvedLocalBeforeRestart.pendingOperations.length === 0 &&
    resolvedLocalBeforeRestart.conflictBranches.length === 1 &&
    resolvedLocalBeforeRestart.conflictBranches[0].state === 'resolved' &&
    resolvedLocalBeforeRestart.conflictBranches[0].branchEnvelope.header.revision_id ===
      localPending.envelopeHeader.revision_id &&
    resolvedLocalBeforeRestart.conflictBranches[0].branchEnvelope.ciphertextHash ===
      conflictBranch.branchEnvelope.ciphertextHash &&
    resolvedLocalBeforeRestart.conflictBranches[0].remoteEnvelope.header.revision_id ===
      remoteUpdate.revisionId &&
    resolvedLocalBeforeRestart.conflictBranches[0].remoteEnvelope.ciphertextHash ===
      conflictBranch.remoteEnvelope.ciphertextHash &&
    resolvedLocalBeforeRestart.conflictBranches[0].resolutionOpId === resolutionOperation.opId &&
    resolvedLocalBeforeRestart.conflictBranches[0].resolutionRevisionId ===
      resolutionOperation.revisionId &&
    resolvedLocalBeforeRestart.plaintextMarkersAbsent,
  'completed conflict resolution was not durable locally before replaying its record event');

  setStage('restart again and replay the committed resolution event exactly once');
  const secondRestartApiStart = apiEvents.length;
  await editorContext.close();
  editorContext = null;
  const secondRestart = await launchProfile(editorProfilePath, 'primary');
  editorContext = secondRestart.context;
  await recoverSameProfileWorkspace(secondRestart.page);
  await openRecordList(secondRestart.page, credentialMode);
  await waitRecord(secondRestart.page, credentialMode);
  await waitForRecordValue(secondRestart.page, credentialMode, branchValue(keepLocal),
    `second restart decrypts the explicitly selected ${resolutionChoice} record value`);
  await waitFor(() => apiEvents.slice(secondRestartApiStart).some((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === resolutionOperation.revisionId)),
  'second same-profile restart replays its own resolution record event', 45000);
  const resolutionEventPage = apiEvents.slice(secondRestartApiStart).find((event) =>
    event.profile === 'primary' && event.route === 'changes' && event.status === 200 &&
    event.bodyRead && event.changeEvents.some((item) =>
      item.recordId === recordId && item.revisionId === resolutionOperation.revisionId));
  const resolvedFeedEvent = apiEvents.flatMap((event) => event.changeEvents || []).find((item) =>
    item.type === 'resolved' && item.conflictId === serverConflictId &&
    item.resolvedRevisionId === resolutionOperation.revisionId);
  assertThat(resolutionEventPage.nextCursor &&
    resolutionEventPage.serverGeneration === inboundPage.serverGeneration &&
    resolvedFeedEvent,
  'restart did not observe both the committed record event and conflict-resolution feed event');
  let resolvedAfterRestart;
  const checkpointDeadline = Date.now() + 30000;
  do {
    resolvedAfterRestart = await snapshotInboundStoreRace(secondRestart.page,
      'resolution-after-second-restart');
    if (resolvedAfterRestart.checkpoints[0]?.cursor === resolutionEventPage.nextCursor) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  } while (Date.now() < checkpointDeadline);
  const restartConvergence = {
    integrityOk: resolvedAfterRestart.integrityCheck === 'ok',
    singleCheckpoint: resolvedAfterRestart.checkpoints.length === 1,
    cursorAtResolutionPage: resolvedAfterRestart.checkpoints[0]?.cursor ===
      resolutionEventPage.nextCursor,
    generationMatches: resolvedAfterRestart.checkpoints[0]?.serverGeneration ===
      resolutionEventPage.serverGeneration,
    oneCachedRecord: resolvedAfterRestart.encryptedRecordCache.length === 1,
    cacheHasResolution: resolvedAfterRestart.encryptedRecordCache[0]?.revisionId ===
      resolutionOperation.revisionId,
    cacheCommitMatches: resolvedAfterRestart.encryptedRecordCache[0]?.commitSeq ===
      serverAfterResolution.versions[2].commitSeq,
    emptyOutbox: resolvedAfterRestart.pendingOperations.length === 0,
    oneConflictBranch: resolvedAfterRestart.conflictBranches.length === 1,
    conflictResolved: resolvedAfterRestart.conflictBranches[0]?.state === 'resolved',
    localConflictEnvelopePreserved:
      resolvedAfterRestart.conflictBranches[0]?.branchEnvelope.header.revision_id ===
        localPending.envelopeHeader.revision_id &&
      resolvedAfterRestart.conflictBranches[0]?.branchEnvelope.ciphertextHash ===
        conflictBranch.branchEnvelope.ciphertextHash,
    remoteConflictEnvelopePreserved:
      resolvedAfterRestart.conflictBranches[0]?.remoteEnvelope.header.revision_id ===
        remoteUpdate.revisionId &&
      resolvedAfterRestart.conflictBranches[0]?.remoteEnvelope.ciphertextHash ===
        conflictBranch.remoteEnvelope.ciphertextHash,
    resolutionMatches: resolvedAfterRestart.conflictBranches[0]?.resolutionRevisionId ===
      resolutionOperation.revisionId,
    plaintextMarkersAbsent: resolvedAfterRestart.plaintextMarkersAbsent,
  };
  assertThat(resolvedAfterRestart.integrityCheck === 'ok' &&
    resolvedAfterRestart.checkpoints.length === 1 &&
    resolvedAfterRestart.checkpoints[0].cursor === resolutionEventPage.nextCursor &&
    resolvedAfterRestart.checkpoints[0].serverGeneration ===
      resolutionEventPage.serverGeneration &&
    resolvedAfterRestart.encryptedRecordCache.length === 1 &&
    resolvedAfterRestart.encryptedRecordCache[0].revisionId === resolutionOperation.revisionId &&
    resolvedAfterRestart.encryptedRecordCache[0].commitSeq ===
      serverAfterResolution.versions[2].commitSeq &&
    resolvedAfterRestart.pendingOperations.length === 0 &&
    resolvedAfterRestart.conflictBranches.length === 1 &&
    resolvedAfterRestart.conflictBranches[0].state === 'resolved' &&
    resolvedAfterRestart.conflictBranches[0].branchEnvelope.header.revision_id ===
      localPending.envelopeHeader.revision_id &&
    resolvedAfterRestart.conflictBranches[0].branchEnvelope.ciphertextHash ===
      conflictBranch.branchEnvelope.ciphertextHash &&
    resolvedAfterRestart.conflictBranches[0].remoteEnvelope.header.revision_id ===
      remoteUpdate.revisionId &&
    resolvedAfterRestart.conflictBranches[0].remoteEnvelope.ciphertextHash ===
      conflictBranch.remoteEnvelope.ciphertextHash &&
    resolvedAfterRestart.conflictBranches[0].resolutionRevisionId ===
      resolutionOperation.revisionId &&
    resolvedAfterRestart.plaintextMarkersAbsent,
  `second restart failed to converge the conflict branch, encrypted head, empty outbox and exact changes cursor ${JSON.stringify(restartConvergence)}`);
  const serverAfterRestart = readServerSnapshot();
  assertThat(serverAfterRestart.versions.length === 3 &&
    serverAfterRestart.events.length === 3 &&
    serverAfterRestart.receipts.length === 3 &&
    serverAfterRestart.conflictCount === 1 &&
    serverAfterRestart.head?.revisionId === resolutionOperation.revisionId &&
    serverAfterRestart.conflicts[0].resolvedRevisionId === resolutionOperation.revisionId &&
    serverAfterRestart.receipts.filter((item) =>
      item.opId === resolutionOperation.opId &&
      item.revisionId === resolutionOperation.revisionId).length === 1 &&
    !apiEvents.slice(secondRestartApiStart).some((event) =>
      event.profile === 'primary' &&
      event.route === 'push' &&
      event.operations.some((item) => item.recordId === recordId)) &&
    !apiEvents.slice(secondRestartApiStart).some((event) =>
      event.profile === 'primary' &&
      ((event.route === 'conflict-create' && event.operations.some((item) =>
        item.opId === localPending.opId)) ||
        (event.route === 'conflict-resolve' && event.conflictId === serverConflictId))),
  'same-profile restart duplicated a push, conflict upload/resolution request, or server ledger row');

  setStage('verify privacy, browser errors, and isolated fixture cleanup');
  assertThat(!credentialMode || conflictDurableBeforeCheckpoint,
    'Credential race did not verify durable conflict state before checkpoint advancement');
  assertCiphertextOnly();
  const unexpectedConsoleErrors = Object.entries(consoleErrorMessages).flatMap(([profile, messages]) =>
    messages.filter((item) => !item.expectedAbortedSyncRequest).map((item) => ({ profile, ...item })));
  assertThat(pageErrors.owner === 0 && pageErrors.primary === 0 && pageErrors.sibling === 0 &&
    unexpectedConsoleErrors.length === 0,
  'same-profile conflict race raised a browser error outside the deliberate changes-feed block');
  await cleanup();
  assertThat(!cleanupFailed, 'isolated inbound-store conflict fixture cleanup failed');
  console.log(`${ACCEPTANCE_ID} passed`, JSON.stringify({
    samePersistentProfileTabs: 2,
    sharedIndexedDbBackend: true,
    initialOutboxReadWasEmpty: hookEvidence.entries[0].observedPendingOperationCount === 0,
    overlappingField: credentialMode ? 'Credential password secret' : 'Hostname or IP',
    explicitlySelectedBranch: resolutionChoice,
    bothEncryptedBranchesPreserved: true,
    conflictDurableBeforeCheckpoint,
    checkpointAdvancedAfterDurableConflict: true,
    staleBranchCommittedAsOrdinaryRecord: false,
    serverHistory: ['create', 'remote update', 'explicit resolution update'],
    conflictCreateAndResolutionSequences: ['1', '2'],
    sameProfileRestarts: 2,
    secondRestartPulledOwnResolutionEvent: true,
    exactlyOnceReceiptEventAndHead: true,
    sqliteIntegrity: resolvedAfterRestart.integrityCheck,
    plaintextMarkersAbsent: true,
    unexpectedConsoleErrors: unexpectedConsoleErrors.length,
    pageErrors: pageErrors.owner + pageErrors.primary + pageErrors.sibling,
    fixtureCleanupComplete: true,
    siblingSyncAborts: deliberatelyAbortedSyncRequests.sibling.length,
    heldChangesAborts: deliberatelyAbortedSyncRequests.primary.filter((item) =>
      item.route === 'changes').length,
  }));
}

function assertCiphertextOnly() {
  const paths = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`, serverLogPath]
    .filter((file) => file && fs.existsSync(file));
  for (const file of paths) {
    const bytes = fs.readFileSync(file);
    assertThat(!Object.values(MARKERS).some((marker) => bytes.includes(Buffer.from(marker))),
      'synthetic record marker was present in server persistence or logs');
  }
  assertThat(apiMarkerMatches.length === 0,
    'synthetic record marker was present in a Vault API request or response');
}

async function installSyncRequestBlock(page, profile,
  blockedRoutes = ['push', 'changes', 'conflict-create']) {
  let blocked = true;
  const handler = async (route) => {
    let pathname = '';
    try { pathname = new URL(route.request().url()).pathname; } catch (_) {}
    const syncRoute = routeFor(pathname);
    if (blocked && blockedRoutes.includes(syncRoute)) {
      deliberatelyAbortedSyncRequests[profile].push({
        id: deliberatelyAbortedSyncRequests[profile].length + 1,
        method: route.request().method(),
        route: syncRoute,
        url: route.request().url(),
        consoleErrorMatched: false,
      });
      await route.abort('failed');
    } else {
      await route.continue();
    }
  };
  await page.route('**/api/v1/**', handler);
  return async () => {
    blocked = false;
    await page.unroute('**/api/v1/**', handler);
  };
}

async function installResolutionReplayBarrier(page, profile, baseRevisionId) {
  let holdOwnResolutionEvent = false;
  const handler = async (route) => {
    const request = route.request();
    let pathname = '';
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    const syncRoute = routeFor(pathname);
    if (syncRoute === 'changes' && holdOwnResolutionEvent) {
      deliberatelyAbortedSyncRequests[profile].push({
        id: deliberatelyAbortedSyncRequests[profile].length + 1,
        method: request.method(),
        route: syncRoute,
        url: request.url(),
        consoleErrorMatched: false,
      });
      await route.abort('failed');
      return;
    }
    if (syncRoute !== 'push') {
      await route.continue();
      return;
    }
    let containsResolution = false;
    try {
      const payload = JSON.parse(request.postData() || '{}');
      containsResolution = Array.isArray(payload.operations) &&
        payload.operations.some((item) => item?.header?.record_id === recordId &&
          item?.header?.operation === 'update' &&
          item?.header?.base_revision_id === baseRevisionId);
    } catch (_) {}
    const response = await route.fetch();
    if (containsResolution && response.status() === 200) holdOwnResolutionEvent = true;
    await route.fulfill({ response });
  };
  await page.route('**/api/v1/**', handler);
}

async function createAndCommitNamedHost(ownerPage, name) {
  const start = apiEvents.length;
  await createNamedHost(ownerPage, name);
  await clickSyncWhenIdle(ownerPage);
  await waitFor(() => apiEvents.slice(start).some((event) =>
    event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
    event.bodyRead && event.operations.some((item) => item.operation === 'create')),
  `${name} baseline Host commit`, 45000);
  const event = apiEvents.slice(start).find((candidate) =>
    candidate.profile === 'owner' && candidate.route === 'push' &&
    candidate.status === 200 && candidate.bodyRead &&
    candidate.operations.some((item) => item.operation === 'create'));
  const created = event?.operations.find((item) => item.operation === 'create');
  assertThat(created?.recordId && created.revisionId && created.opId && created.deviceId,
    `${name} baseline Host did not use one signed device operation`);
  return created;
}

async function hookState(page) {
  return page.evaluate(() => {
    const state = window.__atermiusHostJumpGraphRaceState;
    return state ? {
      armed: state.armed,
      entries: state.entries.map((entry) => ({ ...entry })),
      waitingRecordIds: Object.keys(state.resolvers),
      duplicateGateCount: state.duplicateGateCount,
      releasedRecordIds: [...state.releasedRecordIds],
    } : null;
  });
}

async function cardSemanticLabel(page, hostId) {
  const card = hostCard(page, '', hostId);
  return await card.getAttribute('aria-label').catch(() => '') ||
    await card.innerText().catch(() => '');
}

async function runHostJumpGraphScenario(ownerPage) {
  const targetName = MARKERS.baseName;
  const bastionName = MARKERS.remoteName;
  setStage('create two baseline Hosts with direct routes');
  const targetCreate = await createAndCommitNamedHost(ownerPage, targetName);
  const bastionCreate = await createAndCommitNamedHost(ownerPage, bastionName);
  const targetId = targetCreate.recordId;
  const bastionId = bastionCreate.recordId;
  assertThat(targetId !== bastionId, 'Target and Bastion Host IDs were not distinct');
  recordId = targetId;
  const baseline = readServerSnapshots([targetId, bastionId]);
  assertThat(baseline[targetId].versions.length === 1 &&
    baseline[targetId].versions[0].operation === 'create' &&
    baseline[bastionId].versions.length === 1 &&
    baseline[bastionId].versions[0].operation === 'create' &&
    baseline[targetId].conflictCount === 0 && baseline[bastionId].conflictCount === 0,
  'server did not contain exactly one direct-route baseline revision per Host');
  const targetBaseRevisionId = baseline[targetId].head.revisionId;
  const bastionBaseRevisionId = baseline[bastionId].head.revisionId;

  const editorPath = path.join(tempRoot, 'jump-graph-editor-profile');
  fs.mkdirSync(editorPath, { recursive: true, mode: 0o700 });
  fs.chmodSync(editorPath, 0o700);
  await seedSharedIndexedDb(editorPath);
  setStage('approve editor device for same-profile graph race');
  const editor = await launchProfile(editorPath, 'primary', 'hostJumpGraph');
  editorContext = editor.context;
  await enrollSecondDevice(ownerPage, editor.page);
  await waitHost(editor.page, targetName, targetId);
  await waitHost(editor.page, bastionName, bastionId);

  setStage('open sibling Chromium tab sharing editor IndexedDB');
  const siblingPage = await editorContext.newPage();
  editorDiagnosticPage = siblingPage;
  await siblingPage.addInitScript(installHostJumpGraphRaceHook);
  attachPageObservation(siblingPage, 'sibling');
  await siblingPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await enableSemantics(siblingPage);
  await recoverSameProfileWorkspace(siblingPage);
  await click(siblingPage, 'Hosts');
  await waitHost(siblingPage, targetName, targetId);
  await waitHost(siblingPage, bastionName, bastionId);
  await waitFor(() => editorPrimaryMarker && editorSiblingMarker,
    'both editor tabs use Drift sharedIndexedDb');
  assertThat(editorPrimaryMarker && editorSiblingMarker,
    'both editor tabs did not use the same-profile IndexedDB backend');

  const unblockPrimary = await installSyncRequestBlock(editor.page, 'primary');
  await installSyncRequestBlock(siblingPage, 'sibling');
  const initialOutbox = await snapshotLocalOutbox(
    editor.page, 'jump-graph-initial', [targetId, bastionId]);
  assertThat(initialOutbox.encryptedRecordCache.some((item) =>
    item.recordId === targetId && item.revisionId === targetBaseRevisionId) &&
    initialOutbox.encryptedRecordCache.some((item) =>
      item.recordId === bastionId && item.revisionId === bastionBaseRevisionId) &&
    !initialOutbox.pending.some((item) => item.envelopeHeader.operation === 'update'),
  'same-profile editor did not start from the clean direct-route Host heads');

  setStage('pause reciprocal route edits after graph validation and before either save');
  await Promise.all([
    editor.page.evaluate(() => { window.__atermiusHostJumpGraphRaceState.armed = true; }),
    siblingPage.evaluate(() => { window.__atermiusHostJumpGraphRaceState.armed = true; }),
  ]);
  let editActionError = null;
  const targetEdit = editHostJumpRoute(editor.page, targetName, targetId, bastionId)
    .catch((error) => { editActionError ||= error; });
  const bastionEdit = editHostJumpRoute(siblingPage, bastionName, bastionId, targetId)
    .catch((error) => { editActionError ||= error; });
  await waitFor(async () => {
    if (editActionError) throw editActionError;
    const [primaryState, siblingState] = await Promise.all([
      hookState(editor.page), hookState(siblingPage),
    ]);
    return primaryState?.entries.some((item) => item.recordId === targetId &&
      item.jumpHostId === bastionId && item.attempt === 1) &&
      siblingState?.entries.some((item) => item.recordId === bastionId &&
        item.jumpHostId === targetId && item.attempt === 1);
  }, 'both valid reciprocal graph edits reach the pre-save barrier', 45000);
  await Promise.all([targetEdit, bastionEdit]);
  const [primaryAtBarrier, siblingAtBarrier] = await Promise.all([
    hookState(editor.page), hookState(siblingPage),
  ]);
  assertThat(primaryAtBarrier.entries.length === 1 &&
    primaryAtBarrier.entries[0].recordId === targetId &&
    primaryAtBarrier.entries[0].jumpHostId === bastionId &&
    primaryAtBarrier.entries[0].attempt === 1 &&
    siblingAtBarrier.entries.length === 1 &&
    siblingAtBarrier.entries[0].recordId === bastionId &&
    siblingAtBarrier.entries[0].jumpHostId === targetId &&
    siblingAtBarrier.entries[0].attempt === 1,
  'both editor tabs did not independently pass validation before either save');
  const heldOutbox = await snapshotLocalOutbox(
    editor.page, 'jump-graph-before-release', [targetId, bastionId]);
  assertThat(!heldOutbox.pending.some((item) => item.envelopeHeader.operation === 'update') &&
    heldOutbox.encryptedRecordCache.some((item) =>
      item.recordId === targetId && item.revisionId === targetBaseRevisionId) &&
    heldOutbox.encryptedRecordCache.some((item) =>
      item.recordId === bastionId && item.revisionId === bastionBaseRevisionId),
  'one of the reciprocal Host writes occurred before both validation barriers were reached');

  setStage('release Bastion-to-Target winner and confirm its one local outbox update');
  assertThat(await siblingPage.evaluate((id) =>
    window.__atermiusHostJumpGraphRaceState.release(id), bastionId),
  'Bastion save barrier was not waiting');
  await waitFor(async () => {
    const snapshot = await snapshotLocalOutbox(
      siblingPage, 'jump-graph-bastion-write', [targetId, bastionId]);
    const updates = snapshot.pending.filter((item) =>
      item.envelopeHeader.operation === 'update');
    return updates.length === 1 && updates[0].recordId === bastionId &&
      updates[0].status === 'queued' &&
      snapshot.encryptedRecordCache.some((item) => item.recordId === bastionId &&
        item.revisionId === updates[0].envelopeHeader.revision_id);
  }, 'Bastion-to-Target is the only saved update before releasing Target', 30000);

  setStage('release Target-to-Bastion loser and require fresh graph rejection');
  assertThat(await editor.page.evaluate((id) =>
    window.__atermiusHostJumpGraphRaceState.release(id), targetId),
  'Target save barrier was not waiting');
  await waitFor(() => editor.page.getByText(/Jump Host 链不能形成循环/).count()
    .then((count) => count > 0).catch(() => false),
  'Target-to-Bastion edit is rejected after graph reload detects the cycle', 30000);
  const afterRaceOutbox = await snapshotLocalOutbox(
    siblingPage, 'jump-graph-after-rejected-edit', [targetId, bastionId]);
  const localUpdates = afterRaceOutbox.pending.filter((item) =>
    item.envelopeHeader.operation === 'update');
  assertThat(localUpdates.length === 1 && localUpdates[0].recordId === bastionId &&
    localUpdates[0].status === 'queued' &&
    afterRaceOutbox.encryptedRecordCache.some((item) =>
      item.recordId === targetId && item.revisionId === targetBaseRevisionId) &&
    afterRaceOutbox.encryptedRecordCache.some((item) =>
      item.recordId === bastionId &&
      item.revisionId === localUpdates[0].envelopeHeader.revision_id),
  'rejected Target edit added an outbox operation or changed its encrypted cache head');
  const [primaryAfterRace, siblingAfterRace] = await Promise.all([
    hookState(editor.page), hookState(siblingPage),
  ]);
  assertThat(primaryAfterRace.entries.length === 1 &&
    primaryAfterRace.entries[0].attempt === 1 &&
    primaryAfterRace.entries[0].recordId === targetId &&
    siblingAfterRace.entries.length === 1 && siblingAfterRace.entries[0].attempt === 1 &&
    primaryAfterRace.duplicateGateCount === 0 && siblingAfterRace.duplicateGateCount === 0 &&
    primaryAfterRace.releasedRecordIds.join(',') === targetId &&
    siblingAfterRace.releasedRecordIds.join(',') === bastionId,
  `losing retry should reject during fresh graph validation before another pre-save hook; ` +
    `target=${JSON.stringify(primaryAfterRace)}, bastion=${JSON.stringify(siblingAfterRace)}`);

  const syncStart = apiEvents.length;
  await unblockPrimary();
  await clickSyncWhenIdle(editor.page);
  await waitFor(() => apiEvents.slice(syncStart).some((event) =>
    event.route === 'push' && event.status === 200 && event.bodyRead &&
    event.operations.some((item) => item.recordId === bastionId && item.operation === 'update')),
  'single safe Host update is accepted by the isolated server', 45000);
  const graphPushEvents = apiEvents.slice(syncStart).filter((event) =>
    event.route === 'push' && event.status === 200 && event.bodyRead);
  const graphPushOperations = graphPushEvents.flatMap((event) => event.operations)
    .filter((item) => [targetId, bastionId].includes(item.recordId));
  assertThat(graphPushOperations.length === 1 &&
    graphPushOperations[0].recordId === bastionId &&
    graphPushOperations[0].operation === 'update' && graphPushOperations[0].opId,
  'same-profile race emitted more than one Host sync operation or updated the losing Target');

  setStage('verify exactly one committed Host update, event and receipt');
  const committed = readServerSnapshots([targetId, bastionId]);
  const targetHistory = committed[targetId];
  const bastionHistory = committed[bastionId];
  const syncOperation = graphPushOperations[0];
  assertThat(targetHistory.versions.length === 1 &&
    targetHistory.versions[0].operation === 'create' &&
    targetHistory.events.length === 1 && targetHistory.events[0].eventType === 'create' &&
    targetHistory.receipts.length === 1 && targetHistory.conflictCount === 0 &&
    targetHistory.head?.revisionId === targetBaseRevisionId &&
    bastionHistory.versions.length === 2 &&
    bastionHistory.versions.map((item) => item.operation).join(',') === 'create,update' &&
    bastionHistory.versions[1].baseRevisionId === bastionBaseRevisionId &&
    bastionHistory.versions[1].revisionId === syncOperation.revisionId &&
    bastionHistory.events.length === 2 &&
    bastionHistory.events.map((item) => item.eventType).join(',') === 'create,update' &&
    bastionHistory.events[1].revisionId === syncOperation.revisionId &&
    bastionHistory.receipts.length === 2 &&
    bastionHistory.receipts[1].opId === syncOperation.opId &&
    bastionHistory.receipts[1].revisionId === syncOperation.revisionId &&
    bastionHistory.head?.revisionId === syncOperation.revisionId &&
    bastionHistory.head.deleted === false && bastionHistory.conflictCount === 0,
  'server ledger contains a duplicate, losing, conflicting, or missing Host graph operation');

  const finalOutbox = await snapshotLocalOutbox(
    editor.page, 'jump-graph-after-sync', [targetId, bastionId]);
  const updateRows = finalOutbox.pending.filter((item) =>
    item.envelopeHeader.operation === 'update');
  assertThat(updateRows.length <= 1 && updateRows.every((item) =>
    item.recordId === bastionId && item.envelopeHeader.op_id === syncOperation.opId &&
    item.envelopeHeader.revision_id === syncOperation.revisionId && item.status === 'sent'),
  'shared profile outbox retained a duplicate or pending Host update after sync');
  postRaceOutboxSnapshot = finalOutbox;
  serverHistoryDiagnostic = {
    target: {
      versions: targetHistory.versions.map(({ revisionId, baseRevisionId, operation }) =>
        ({ revisionId, baseRevisionId, operation })),
      events: targetHistory.events,
      receipts: targetHistory.receipts,
      conflictCount: targetHistory.conflictCount,
      head: targetHistory.head,
    },
    bastion: {
      versions: bastionHistory.versions.map(({ revisionId, baseRevisionId, operation }) =>
        ({ revisionId, baseRevisionId, operation })),
      events: bastionHistory.events,
      receipts: bastionHistory.receipts,
      conflictCount: bastionHistory.conflictCount,
      head: bastionHistory.head,
    },
  };

  setStage('reload same-profile sibling while primary keeps the profile open');
  let reloadedRouteIssueCount = 0;
  const siblingMarkerCountBeforeReload = backendMarkerCounts.sibling;
  const reloadApiStartIndex = apiEvents.length;
  try {
    await siblingPage.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
    await enableSemantics(siblingPage);
    await recoverSameProfileWorkspace(siblingPage);
    await click(siblingPage, 'Hosts');
    await waitHost(siblingPage, targetName, targetId);
    await waitHost(siblingPage, bastionName, bastionId);
    assertThat(backendMarkerCounts.sibling > siblingMarkerCountBeforeReload,
      'reloaded sibling did not reopen its shared IndexedDB backend');
  } catch (error) {
    const screen = await siblingPage.evaluate(() => {
      const bodyText = document.body?.innerText || '';
      const visibleText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
            style.visibility !== 'hidden' && Number(style.opacity) !== 0;
        })
        .map((element) => `${element.getAttribute('role') || ''}: ` +
          `${element.getAttribute('aria-label') || element.innerText || ''}`.trim())
        .slice(0, 32);
      return {
        readyState: document.readyState,
        pathname: location.pathname,
        bodyText,
        hasSettings: Boolean(document.querySelector('[aria-label="Settings"]')) ||
          bodyText.includes('Settings'),
        hasWorkspaceChooser: bodyText.includes('Choose a workspace'),
        hasOpeningStatus: bodyText.includes('Opening'),
        hasOpenLocally: bodyText.includes('Open locally'),
        hasCheckAgain: bodyText.includes('Check again'),
        hasPersistentStorageAction: bodyText.includes('Request persistent storage'),
        visibleSemantics: visibleText,
      };
    }).catch(() => null);
    let reloadedOutbox = null;
    try {
      reloadedOutbox = await snapshotLocalOutbox(
        siblingPage, 'jump-graph-reload-failure', [targetId, bastionId]);
    } catch (snapshotError) {
      reloadedOutbox = { diagnosticError: safeDiagnosticText(snapshotError?.message) };
    }
    hostGraphReloadDiagnostic = {
      errorName: safeDiagnosticText(error?.name || 'Error'),
      errorMessage: safeDiagnosticText(error?.message || error || 'reload failed'),
      safeBodyText: safeDiagnosticText(screen?.bodyText || ''),
      screenState: screen ? {
        readyState: screen.readyState,
        pathname: screen.pathname,
        hasSettings: screen.hasSettings,
        hasWorkspaceChooser: screen.hasWorkspaceChooser,
        hasOpeningStatus: screen.hasOpeningStatus,
        hasOpenLocally: screen.hasOpenLocally,
        hasCheckAgain: screen.hasCheckAgain,
        hasPersistentStorageAction: screen.hasPersistentStorageAction,
        visibleSemantics: screen.visibleSemantics.map(safeDiagnosticText),
      } : null,
      indexedDbOutbox: reloadedOutbox,
      pageErrors: { ...pageErrors },
      consoleErrors: { ...consoleErrors },
      backendMarkerCounts: { ...backendMarkerCounts },
      siblingMarkerCountBeforeReload,
      reloadApiStartIndex,
      postReloadApiStatus: apiEvents.slice(reloadApiStartIndex).map((event) => ({
        profile: event.profile, route: event.route, method: event.method,
        status: event.status, statusText: event.statusText,
        responseBodyDiagnostic: event.responseBodyDiagnostic,
        bodyRead: event.bodyRead,
        operations: event.operations.map((item) => ({
          operation: item.operation, recordId: item.recordId,
          revisionId: item.revisionId, baseRevisionId: item.baseRevisionId,
        })),
      })),
      recentApiStatus: apiEvents.slice(-12).map((event) => ({
        profile: event.profile, route: event.route, method: event.method,
        status: event.status, statusText: event.statusText,
        responseBodyDiagnostic: event.responseBodyDiagnostic,
        bodyRead: event.bodyRead,
        operations: event.operations.map((item) => ({
          operation: item.operation, recordId: item.recordId,
          revisionId: item.revisionId, baseRevisionId: item.baseRevisionId,
        })),
      })),
    };
    throw error;
  }
  const targetLabel = await cardSemanticLabel(siblingPage, targetId);
  const bastionLabel = await cardSemanticLabel(siblingPage, bastionId);
  reloadedRouteIssueCount = [targetLabel, bastionLabel].filter((label) =>
    label.includes('Jump Host route needs repair') ||
    label.includes('Jump Host 路由需修复')).length;
  assertThat(targetLabel.startsWith(`Host: ${targetName};`) &&
    !targetLabel.includes('Via Jump Host:') &&
    bastionLabel.startsWith(`Host: ${bastionName};`) &&
    bastionLabel.includes(`Via Jump Host: ${targetName}`) &&
    reloadedRouteIssueCount === 0,
  'reloaded same-profile Hosts did not show exactly the safe route and zero route issues');

  setStage('verify encrypted persistence, browser errors and fixture cleanup');
  assertCiphertextOnly();
  assertThat(pageErrors.owner === 0 && pageErrors.primary === 0 && pageErrors.sibling === 0,
    'a same-profile Chromium page raised an uncaught runtime error');
  const capturedConsoleErrorCount = Object.values(consoleErrorMessages)
    .reduce((total, entries) => total + entries.length, 0);
  const totalConsoleErrorCount = Object.values(consoleErrors)
    .reduce((total, count) => total + count, 0);
  const expectedAbortConsoleErrorCount = Object.values(consoleErrorMessages).flat()
    .filter((entry) => entry.expectedAbortedSyncRequest).length;
  assertThat(capturedConsoleErrorCount === totalConsoleErrorCount &&
    expectedAbortConsoleErrorCount === totalConsoleErrorCount,
  `unexpected browser console error outside the exact sync-gate abort requests; ` +
    `errors=${JSON.stringify(consoleErrorMessages)}, aborts=${JSON.stringify(
      Object.fromEntries(Object.entries(deliberatelyAbortedSyncRequests).map(([profile, requests]) =>
        [profile, requests.map(({ id, method, route, consoleErrorMatched }) =>
          ({ id, method, route, consoleErrorMatched }))])))});`);
  await cleanup();
  assertThat(!cleanupFailed, 'isolated Host graph fixture cleanup failed');
  console.log(`${ACCEPTANCE_ID} passed`, JSON.stringify({
    persistentProfiles: 2,
    editorTabsSharingProfile: 2,
    sharedIndexedDbEditorTabs: 2,
    bothReciprocalEditsValidatedBeforeWrites: true,
    validationBarrierEntries: primaryAtBarrier.entries.length + siblingAtBarrier.entries.length,
    releasedOrder: ['Bastion->Target', 'Target->Bastion rejected after refreshed validation'],
    survivingRoute: 'Bastion->Target',
    losingTargetOutboxOperations: 0,
    committedHostUpdateOperations: graphPushOperations.length,
    bastionVersions: bastionHistory.versions.length,
    bastionChangeEvents: bastionHistory.events.length,
    bastionReceipts: bastionHistory.receipts.length,
    targetVersions: targetHistory.versions.length,
    reloadedRouteIssueCount,
    conflictBranches: targetHistory.conflictCount + bastionHistory.conflictCount,
    reloadedTabsWithoutJumpHostRouteIssues: 1,
    reloadedHostCardRouteIssueObservations: 2,
    ciphertextOnlyPersistence: true,
    pageErrors: 0,
    consoleErrors: totalConsoleErrorCount,
    classifiedExpectedAbortConsoleErrors: expectedAbortConsoleErrorCount,
    unexpectedConsoleErrors: 0,
    deliberatelyAbortedSyncRequests: Object.fromEntries(
      Object.entries(deliberatelyAbortedSyncRequests).map(([profile, requests]) =>
        [profile, requests.map(({ id, method, route, consoleErrorMatched }) =>
          ({ id, method, route, consoleErrorMatched }))])),
    fixtureCleanupComplete: true,
  }));
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')) &&
    fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')),
  'build the opted-in Web e2e bundle before this acceptance');
  setStage('build isolated Rust server');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], { timeout: 240000 });

  setStage('create private fixture and start isolated server');
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-same-profile-race-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  serverLogPath = path.join(tempRoot, 'server.log');
  const logFd = fs.openSync(serverLogPath, 'a', 0o600);
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
    RUST_LOG: 'off',
  };
  bootstrapToken = cliToken(serverEnv);
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT, env: serverEnv, detached: true, stdio: ['ignore', logFd, logFd],
  });
  await waitForServer(serverProcess);
  fs.closeSync(logFd);

  try {
    const ownerPath = path.join(tempRoot, 'owner-profile');
    fs.mkdirSync(ownerPath, { recursive: true, mode: 0o700 });
    fs.chmodSync(ownerPath, 0o700);
    await seedSharedIndexedDb(ownerPath);
    setStage('launch and register owner profile');
    const owner = await launchProfile(ownerPath, 'owner');
    ownerContext = owner.context;
    await registerOwner(owner.page);

    if (RUN_HOST_JUMP_GRAPH_ONLY) {
      await runHostJumpGraphScenario(owner.page);
      return;
    }

    setStage(`create and commit baseline ${RUN_INBOUND_STORE_CREDENTIAL_ONLY ? 'Credential' : 'Host'}`);
    const createStart = apiEvents.length;
    if (RUN_INBOUND_STORE_CREDENTIAL_ONLY) {
      await createCredential(owner.page);
    } else {
      await createHost(owner.page);
    }
    await clickSyncWhenIdle(owner.page);
    await waitFor(() => apiEvents.slice(createStart).some((event) =>
      event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
      event.bodyRead && event.operations.some((item) => item.operation === 'create')),
    'baseline Host create commit');
    const createEvent = apiEvents.slice(createStart).find((event) =>
      event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
      event.operations.some((item) => item.operation === 'create'));
    const created = createEvent.operations.find((item) => item.operation === 'create');
    recordId = created?.recordId;
    assertThat(recordId && created.revisionId && created.deviceId,
      'baseline Host did not use a signed device operation');
    const baseSnapshot = readServerSnapshot();
    assertThat(baseSnapshot.versions.length === 1 && baseSnapshot.versions[0].operation === 'create',
      'server did not contain exactly one baseline Host revision');
    const baseRevisionId = baseSnapshot.versions[0].revisionId;

    const editorPath = path.join(tempRoot, 'editor-profile');
    fs.mkdirSync(editorPath, { recursive: true, mode: 0o700 });
    fs.chmodSync(editorPath, 0o700);
    await seedSharedIndexedDb(editorPath);
    const editorStorageBeforeEnrollment = localStorageLevelDbFingerprint(editorPath);
    setStage('approve second device in editor profile');
    const editor = await launchProfile(editorPath, 'primary',
      RUN_INBOUND_STORE_RACE_ONLY || RUN_INBOUND_STORE_CONFLICT_ONLY ||
        RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY ||
        RUN_INBOUND_STORE_CREDENTIAL_ONLY
        ? 'inboundStore' : true);
    editorContext = editor.context;
    await enrollSecondDevice(owner.page, editor.page);
    if (RUN_INBOUND_STORE_CREDENTIAL_CRASH_REPLAY_ONLY) {
      const enrollmentStorageCommit = await waitForLocalStorageLevelDbCommit(
        editorPath, editorStorageBeforeEnrollment,
        { requireChange: true, timeoutMs: 15000 });
      assertThat(enrollmentStorageCommit.changed && enrollmentStorageCommit.stable,
        `editor secure-storage Local Storage LevelDB did not commit after device enrollment: ${JSON.stringify(enrollmentStorageCommit)}`);
    }
    if (RUN_INBOUND_STORE_CREDENTIAL_ONLY) {
      await openCredentialsPage(editor.page);
      await waitCredentialRecord(editor.page, MARKERS.credentialName, recordId);
    } else {
      await waitHost(editor.page, MARKERS.baseName, recordId);
    }

    setStage('open sibling tab in the same persistent editor profile');
    const siblingPage = await editorContext.newPage();
    editorDiagnosticPage = siblingPage;
    await siblingPage.addInitScript(() => {
      Object.defineProperty(window, '__atermiusSyncRaceState', {
        value: {
          armed: false,
          entered: false,
          resumed: false,
          resume: null,
          preparedCandidates: 0,
        },
      });
      Object.defineProperty(window, '__atermiusSyncE2eHooks', {
        value: {
          beforeReplaceMergedOperation() { return Promise.resolve(); },
        },
      });
    });
    attachPageObservation(siblingPage, 'sibling');
    await siblingPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await enableSemantics(siblingPage);
    await recoverSameProfileWorkspace(siblingPage);
    if (RUN_INBOUND_STORE_CREDENTIAL_ONLY) {
      await openCredentialsPage(siblingPage);
      await waitCredentialRecord(siblingPage, MARKERS.credentialName, recordId);
    } else {
      await click(siblingPage, 'Hosts');
      await waitHost(siblingPage, MARKERS.baseName, recordId);
    }
    await waitFor(() => editorSiblingMarker, 'sibling tab sharedIndexedDb backend');
    assertThat(ownerProfileMarker && editorPrimaryMarker && editorSiblingMarker,
      'one or more real Chromium pages did not use Drift sharedIndexedDb');
    if (RUN_INBOUND_STORE_RACE_ONLY || RUN_INBOUND_STORE_CONFLICT_ONLY ||
        RUN_INBOUND_STORE_REMOTE_CONFLICT_ONLY ||
        RUN_INBOUND_STORE_CREDENTIAL_ONLY) {
      await runInboundStoreRaceScenario({
        ownerPage: owner.page,
        editorPage: editor.page,
        siblingPage,
        editorProfilePath: editorPath,
        baseRevisionId,
        ownerDeviceId: created.deviceId,
        credentialMode: RUN_INBOUND_STORE_CREDENTIAL_ONLY,
        crashReplay: RUN_INBOUND_STORE_CREDENTIAL_CRASH_REPLAY_ONLY,
      });
      return;
    }
    await siblingPage.route('**/api/v1/**', (route) => {
      let pathname;
      try { pathname = new URL(route.request().url()).pathname; } catch (_) { pathname = ''; }
      if (['push', 'changes', 'conflict-create'].includes(routeFor(pathname))) {
        return route.abort('failed');
      }
      return route.continue();
    });

    setStage('queue primary-tab edit offline and commit remote winner');
    await editorContext.setOffline(true);
    await editHost(editor.page, MARKERS.baseName, { Tags: MARKERS.localTag });
    await waitForHostValues(editor.page, {
      name: MARKERS.baseName, port: '22', tag: MARKERS.localTag,
    }, 'primary offline Host edit');
    const firstEditServer = readServerSnapshot();
    assertThat(firstEditServer.versions.length === 1 && firstEditServer.head.revisionId === baseRevisionId,
      'primary offline edit changed the server before commit');

    const ownerPushStart = apiEvents.length;
    await editHost(owner.page, MARKERS.baseName, { 'Display name': MARKERS.remoteName });
    await clickSyncWhenIdle(owner.page);
    await waitFor(() => apiEvents.slice(ownerPushStart).some((event) =>
      event.profile === 'owner' && event.route === 'push' && event.status === 200 &&
      event.bodyRead && event.operations.some((item) => item.recordId === recordId &&
        item.operation === 'update' && item.baseRevisionId === baseRevisionId)),
    'remote winner commits from baseline');
    const ownerUpdate = apiEvents.slice(ownerPushStart).flatMap((event) => event.operations)
      .find((item) => item.recordId === recordId && item.operation === 'update');
    assertThat(ownerUpdate?.deviceId === created.deviceId,
      'remote winner did not use the owner device identity');
    const winnerSnapshot = readServerSnapshot();
    assertThat(winnerSnapshot.versions.length === 2 &&
      winnerSnapshot.versions[1].revisionId === ownerUpdate.revisionId &&
      winnerSnapshot.versions[1].baseRevisionId === baseRevisionId &&
      winnerSnapshot.conflictCount === 0,
    'remote winner did not establish the expected uncontested head');

    setStage('arm deterministic barrier and begin primary automatic merge');
    await editor.page.evaluate(() => { window.__atermiusSyncRaceState.armed = true; });
    const pushStart = apiEvents.length;
    await editorContext.setOffline(false);
    await clickSyncWhenIdle(editor.page);
    await waitFor(() => editor.page.evaluate(() =>
      window.__atermiusSyncRaceState?.entered === true),
    'primary tab pauses after merge candidate preparation and before outbox replacement', 45000);

    setStage('append a sibling-tab Favorite edit while the stale merge candidate is paused');
    await siblingPage.evaluate((targetHostId) => {
      window.__atermiusFavoriteClickAt = null;
      const onClick = (event) => {
        const path = event.composedPath();
        const host = path.find((node) => node instanceof Element &&
          node.getAttribute('flt-semantics-identifier') === `ssh-host-${targetHostId}`);
        const button = path.find((node) => node instanceof Element &&
          node.getAttribute('role') === 'button' &&
          /favorite/i.test(node.textContent || ''));
        if (host && button) {
          window.__atermiusFavoriteClickAt = Date.now();
          document.removeEventListener('click', onClick, true);
        }
      };
      document.addEventListener('click', onClick, true);
    }, recordId);
    await favoriteHost(siblingPage, MARKERS.baseName);
    const favoriteClickStartedAt = await siblingPage.evaluate(() =>
      window.__atermiusFavoriteClickAt);
    assertThat(Number.isFinite(favoriteClickStartedAt),
      'Favorite control click event was not observed for deadline timing');
    const favoriteUiObservation = observeFavoriteUiAtDeadlines(
      siblingPage, recordId, favoriteClickStartedAt);
    await waitFor(async () => {
      siblingOutboxSnapshot = await snapshotLocalOutbox(siblingPage, 'after-sibling-save');
      const { primary, sibling } = siblingEditChain(siblingOutboxSnapshot, baseRevisionId);
      return Boolean(primary && sibling);
    }, 'sibling Favorite child operation is persisted in the shared outbox', 20000);
    const { primary: primaryPending, sibling: siblingPending } =
      siblingEditChain(siblingOutboxSnapshot, baseRevisionId);
    assertThat(siblingPending &&
      siblingPending.rowBaseRevisionId === primaryPending.envelopeHeader.revision_id &&
      siblingPending.baseEnvelopeHeader.revision_id === primaryPending.envelopeHeader.revision_id &&
      siblingOutboxSnapshot.encryptedRecordCache[0]?.revisionId ===
        siblingPending.envelopeHeader.revision_id,
    'sibling Favorite edit was not appended as a child of the primary local revision');
    const siblingFavoriteUi = {
      name: MARKERS.baseName, port: '22', favorite: true,
    };
    const favoriteUiSnapshots = await favoriteUiObservation;
    favoriteUiDiagnostic = favoriteUiSnapshots.map((snapshot) => ({
      atMsAfterClick: snapshot.atMsAfterClick,
      deadlineMs: snapshot.deadlineMs,
      cardVisible: snapshot.cardVisible,
      removeFavoriteInCard: snapshot.removeFavoriteInCard,
      favoriteInCard: snapshot.favoriteInCard,
      removeFavoriteGlobal: snapshot.removeFavoriteGlobal,
      favoriteGlobal: snapshot.favoriteGlobal,
      semanticsSummary: snapshot.semanticsSummary,
    }));
    const stableFavoriteSnapshots = favoriteUiSnapshots.filter(
      (snapshot) => snapshot.deadlineMs >= 2000);
    assertThat(favoriteUiSnapshots.length === 3 &&
      favoriteUiSnapshots.every((snapshot) => snapshot.cardVisible) &&
      stableFavoriteSnapshots.length === 2 && stableFavoriteSnapshots.every(
        (snapshot) => snapshot.removeFavoriteInCard && !snapshot.favoriteInCard),
    `same-page Favorite role/name did not settle by click-relative 2s without reload; snapshots=${JSON.stringify(favoriteUiDiagnostic)}`);
    console.log('same-page Favorite semantics after hover/focus clear', JSON.stringify(
      favoriteUiDiagnostic.map((snapshot) => ({
        atMsAfterClick: snapshot.atMsAfterClick,
        cardVisible: snapshot.cardVisible,
        removeFavoriteInCard: snapshot.removeFavoriteInCard,
        favoriteInCard: snapshot.favoriteInCard,
        favoriteNodes: snapshot.semanticsSummary.favoriteNodes.map((node) => ({
          tag: node.tag,
          role: node.role,
          labelKind: node.labelKind,
          titleKind: node.titleKind,
          textKind: node.textKind,
          insideTargetCard: node.insideTargetCard,
          nearestCardIsTarget: node.nearestCardIsTarget,
          ariaHidden: node.ariaHidden,
          pressed: node.pressed,
          visible: node.visible,
        })),
      })),
    ));
    siblingFavoriteUiRequiredReload = false;
    assertThat(await hostCardShows(siblingPage, siblingFavoriteUi),
      `same-page Favorite UI did not update after its own saved action; snapshots=${JSON.stringify(favoriteUiSnapshots)}`);
    assertThat(await editor.page.evaluate(() =>
      window.__atermiusSyncRaceState.preparedCandidates) === 1,
    'the first merge candidate was not paused before the sibling edit');
    assertThat(await siblingPage.evaluate(() =>
      window.__atermiusSyncRaceState?.entered !== true),
    'the sibling tab unexpectedly entered the primary tab test barrier');
    await editor.page.evaluate(() => {
      window.__atermiusSyncRaceState.resumed = true;
      window.__atermiusSyncRaceState.resume?.();
    });

    setStage('verify stale replacement was rejected and the complete outbox was retried');
    await waitFor(() => successfulPush('primary', pushStart) !== undefined ||
      apiEvents.slice(pushStart).some((event) => event.profile === 'primary' &&
        event.route === 'conflict-create' && event.status === 200 && event.bodyRead &&
        event.operations.some((item) => item.recordId === recordId)),
    'primary merge push or conflict outcome after sibling edit', 60000);
    postRaceOutboxSnapshot = await snapshotLocalOutbox(siblingPage, 'after-primary-outcome');
    const mergedPush = successfulPush('primary', pushStart);
    const mergedOps = mergedPush.operations.filter((item) => item.recordId === recordId);
    const merged = mergedOps[0];
    const preparedCandidates = await editor.page.evaluate(() =>
      window.__atermiusSyncRaceState.preparedCandidates);
    assertThat(preparedCandidates >= 2,
      'sync did not prepare a fresh merge candidate after rejecting the stale outbox replacement');
    assertThat(mergedOps.length === 1 && merged.operation === 'update' &&
      merged.baseRevisionId === ownerUpdate.revisionId && merged.revisionId !== ownerUpdate.revisionId &&
      merged.deviceId === siblingPending.envelopeHeader.device_id,
    'retry did not coalesce the full sibling-edited outbox into one update from the remote winner');
    const supersededOriginals = postRaceOutboxSnapshot.pending.filter((item) =>
      item.rowOpId === primaryPending.rowOpId || item.rowOpId === siblingPending.rowOpId);
    const persistedRetry = postRaceOutboxSnapshot.pending.find((item) =>
      item.rowOpId === merged.opId);
    const retryRowStateValid = persistedRetry
      ? persistedRetry.status === 'sent' &&
        persistedRetry.envelopeHeader.revision_id === merged.revisionId &&
        persistedRetry.envelopeHeader.base_revision_id === ownerUpdate.revisionId
      : !postRaceOutboxSnapshot.pending.some((item) => item.rowOpId === merged.opId);
    assertThat(supersededOriginals.length === 2 &&
      supersededOriginals.every((item) => item.status === 'superseded') &&
      retryRowStateValid &&
      postRaceOutboxSnapshot.encryptedRecordCache[0]?.revisionId === merged.revisionId,
    'same-profile shared outbox retained an active stale row or lost its retried merged revision');
    assertThat(!apiEvents.slice(pushStart).some((event) => event.profile === 'primary' &&
      event.route === 'conflict-create' && event.status === 200 &&
      event.operations.some((item) => item.recordId === recordId)),
    'same-profile concurrent local edits were uploaded as a conflict');

    const finalSnapshot = readServerSnapshot();
    serverHistoryDiagnostic = {
      versions: finalSnapshot.versions.map(({ revisionId, baseRevisionId, commitSeq, deviceId, operation }) =>
        ({ revisionId, baseRevisionId, commitSeq, deviceId, operation })),
      conflictCount: finalSnapshot.conflictCount,
      head: finalSnapshot.head,
      receipts: finalSnapshot.receipts,
    };
    assertThat(finalSnapshot.versions.map((item) => item.operation).join(',') === 'create,update,update' &&
      finalSnapshot.versions[1].revisionId === ownerUpdate.revisionId &&
      finalSnapshot.versions[2].revisionId === merged.revisionId &&
      finalSnapshot.versions[2].baseRevisionId === ownerUpdate.revisionId &&
      finalSnapshot.versions[2].deviceId === siblingPending.envelopeHeader.device_id &&
      finalSnapshot.conflictCount === 0 &&
      finalSnapshot.head?.revisionId === merged.revisionId &&
      finalSnapshot.head.deleted === false && finalSnapshot.receipts.length === 3 &&
      finalSnapshot.receipts[2].opId === merged.opId &&
      finalSnapshot.receipts[2].revisionId === merged.revisionId,
    'server history/head/receipt did not record one retry-merged revision');

    const finalHost = {
      name: MARKERS.remoteName,
      port: '22',
      tag: MARKERS.localTag,
      favorite: true,
    };
    await waitForHostValues(editor.page, finalHost, 'primary decrypts merged Host UI state');
    setStage('reload same-profile sibling to render shared merged cache head');
    await siblingPage.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
    await enableSemantics(siblingPage);
    await recoverSameProfileWorkspace(siblingPage);
    await click(siblingPage, 'Hosts');
    await waitHost(siblingPage, MARKERS.remoteName, recordId);
    await waitForHostValues(siblingPage, finalHost, 'sibling decrypts merged Host UI state');
    if (!await hostCardShows(owner.page, finalHost)) {
      await clickSyncWhenIdle(owner.page);
    }
    await waitForHostValues(owner.page, finalHost, 'owner decrypts merged Host UI state');

    setStage('verify isolated privacy and cleanup');
    assertCiphertextOnly();
    assertThat(pageErrors.owner === 0 && pageErrors.primary === 0 && pageErrors.sibling === 0,
      'a real Chromium page raised an uncaught runtime error');
    await cleanup();
    assertThat(!cleanupFailed, 'isolated fixture cleanup failed');
    console.log('WEB-SYNC-SAME-PROFILE-MERGE-RACE-01 passed', JSON.stringify({
      persistentProfiles: 2,
      editorTabsSharingProfile: 2,
      sharedIndexedDbPages: 3,
      staleCandidatePausedBeforeAtomicReplacement: true,
      siblingFavoritePersistedBeforeRelease: true,
      siblingFavoriteUiRequiredReload,
      siblingMergedUiReloadedAfterPush: true,
      staleReplacementRejectedAndRetryInferredFromSingleCoalescedCommit: true,
      mergeCandidatesPreparedAcrossRace: preparedCandidates,
      finalFields: ['remote display name', 'primary-tab tag', 'sibling-tab favorite'],
      serverHistory: ['create', 'remote update', 'retried merged update'],
      conflictBranches: 0,
      ciphertextOnlyPersistence: true,
      pageErrors: 0,
      fixtureCleanupComplete: true,
    }));
  } catch (error) {
    if (!postRaceOutboxSnapshot && editorDiagnosticPage && recordId) {
      try {
        postRaceOutboxSnapshot = await snapshotLocalOutbox(
          editorDiagnosticPage, 'after-failure-before-cleanup');
      } catch (snapshotError) {
        postRaceOutboxSnapshot = { diagnosticError: safeDiagnosticText(snapshotError?.message) };
      }
    }
    const diagnosticPauseMs = Number(process.env.ATERMIUS_E2E_DIAGNOSTIC_PAUSE_MS || 0);
    if (Number.isFinite(diagnosticPauseMs) && diagnosticPauseMs > 0) {
      console.error(`diagnostic screenshots remain temporarily at ${tempRoot}`);
      await new Promise((resolve) => setTimeout(resolve,
        Math.min(diagnosticPauseMs, 120000)));
    }
    await cleanup();
    console.error(`${ACCEPTANCE_ID} failed at ${stage}; safe diagnostics=${JSON.stringify({
      cleanupFailed,
      errorName: safeDiagnosticText(error?.name || 'Error'),
      errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure', 1100),
      backendMarkers: { ownerProfileMarker, editorPrimaryMarker, editorSiblingMarker },
      backendMarkerCounts,
      recentAuthEvents: apiEvents.filter((event) =>
        event.profile === 'primary' && event.route.startsWith('auth-')).slice(-4).map((event) => ({
        route: event.route,
        status: event.status,
        response: event.responseBodyDiagnostic,
      })),
      pageErrors,
      consoleErrors,
      consoleErrorMessages,
      deliberatelyAbortedSyncRequests: Object.fromEntries(
        Object.entries(deliberatelyAbortedSyncRequests).map(([profile, requests]) =>
          [profile, requests.map(({ id, method, route, consoleErrorMatched }) =>
            ({ id, method, route, consoleErrorMatched }))])),
      recentApiEvents: apiEvents.slice(-16).map((event) => ({
        profile: event.profile, route: event.route, method: event.method, status: event.status,
        response: event.route.startsWith('auth-') ? event.responseBodyDiagnostic : undefined,
        operations: event.operations.map((item) => ({
          operation: item.operation, recordId: item.recordId,
          baseRevisionId: item.baseRevisionId, revisionId: item.revisionId,
        })),
      })),
      favoriteUiDiagnostic,
      siblingOutboxSnapshot,
      postRaceOutboxSnapshot,
      serverHistoryDiagnostic,
      hostGraphReloadDiagnostic,
      siblingFavoriteUiRequiredReload,
      markerMatchCount: apiMarkerMatches.length,
    })}`);
    process.exitCode = 1;
  }
}

main().catch(async (error) => {
  await cleanup();
  console.error(`${ACCEPTANCE_ID} failed at ${stage}; safe diagnostics=${JSON.stringify({
    cleanupFailed,
    errorName: safeDiagnosticText(error?.name || 'Error'),
    errorMessage: safeDiagnosticText(error?.message || error || 'unknown failure'),
    pageErrors,
    consoleErrors,
    backendMarkerCounts,
    hostGraphReloadDiagnostic,
  })}`);
  process.exitCode = 1;
});
