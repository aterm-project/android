/*
 * WEB-OPENSSH-CONFIG-IMPORT-01: import a synthetic OpenSSH config in one
 * Chromium profile and prove the encrypted Host records, including the
 * ProxyJump reference, decrypt in an independently enrolled profile.
 * Config bytes exist only in the browser file chooser; this runner never
 * writes them to disk or opens an SSH connection.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = path.join(SERVER_TARGET_DIR, 'debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `openssh-import-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `OpenSshImport${crypto.randomBytes(24).toString('hex')}9`;
const DEVICE_A = `OpenSSH import A ${RUN_ID.slice(0, 8)}`;
const DEVICE_B = `OpenSSH import B ${RUN_ID.slice(0, 8)}`;
const BASTION_ALIAS = `jump-${RUN_ID.slice(0, 8)}`;
const TARGET_ALIAS = `target-${RUN_ID.slice(0, 8)}`;
const BASTION_HOST = `bastion-${RUN_ID.slice(0, 8)}.example.invalid`;
const TARGET_HOST = `target-${RUN_ID.slice(0, 8)}.example.invalid`;
const BASTION_USER = `gateway-${RUN_ID.slice(0, 8)}`;
const TARGET_USER = `deploy-${RUN_ID.slice(0, 8)}`;
const BASTION_PORT = 31000 + crypto.randomInt(8000);
const TARGET_PORT = 41000 + crypto.randomInt(8000);
const BASTION_KEY_PATH = `/tmp/OPENSSH_IMPORT_PRIVATE_KEY_BASTION_${RUN_ID}`;
const TARGET_KEY_PATH = `/tmp/OPENSSH_IMPORT_PRIVATE_KEY_TARGET_${RUN_ID}`;
const CONFIG_MARKER = `OPENSSH_CONFIG_SOURCE_PRIVATE_MARKER_${RUN_ID}`;
const CONFIG_SOURCE = [
  `# ${CONFIG_MARKER}`,
  `Host ${TARGET_ALIAS}`,
  `  HostName ${TARGET_HOST}`,
  `  User ${TARGET_USER}`,
  `  Port ${TARGET_PORT}`,
  `  ProxyJump ${BASTION_ALIAS}`,
  `  IdentityFile ${TARGET_KEY_PATH}`,
  `Host ${BASTION_ALIAS}`,
  `  HostName ${BASTION_HOST}`,
  `  User ${BASTION_USER}`,
  `  Port ${BASTION_PORT}`,
  `  IdentityFile ${BASTION_KEY_PATH}`,
  '',
].join('\n');
const CONFIG_MARKERS = [
  CONFIG_MARKER,
  BASTION_ALIAS,
  TARGET_ALIAS,
  BASTION_HOST,
  TARGET_HOST,
  BASTION_USER,
  TARGET_USER,
  `Host ${TARGET_ALIAS}`,
  `Host ${BASTION_ALIAS}`,
  `HostName ${TARGET_HOST}`,
  `HostName ${BASTION_HOST}`,
  `User ${TARGET_USER}`,
  `User ${BASTION_USER}`,
  `Port ${TARGET_PORT}`,
  `Port ${BASTION_PORT}`,
  `ProxyJump ${BASTION_ALIAS}`,
  `IdentityFile ${TARGET_KEY_PATH}`,
  `IdentityFile ${BASTION_KEY_PATH}`,
  BASTION_KEY_PATH,
  TARGET_KEY_PATH,
  CONFIG_SOURCE,
];
const SYNC_STATUS = /^(Idle|Pending|Syncing|Retry queued|Offline|Sync error|Snapshot needed|Rebuilding snapshot|Key update needed|Read-only|Sign in needed|Device revoked|Vault deletion pending · read-only|Sync now|\d+ pending)$/;

let stage = 'preflight';

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function safeFailureCategory(error) {
  const message = String(error?.message || '');
  if (message.startsWith('visible input unavailable:') ||
      message.startsWith('visible button unavailable:')) return 'missing-control';
  if (message.startsWith('multiple visible inputs matched')) return 'duplicate-control';
  if (message.startsWith('input did not retain')) return 'value-mismatch';
  if (message === 'host semantic label unavailable') return 'missing-control';
  if (message.includes('did not initialize')) return 'flutter-semantics-unavailable';
  if (error?.name === 'TimeoutError' || /timed out|timeout/i.test(message)) return 'timeout';
  return 'other-safe-error';
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function markerScan(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  return !CONFIG_MARKERS.some((marker) => serialized.includes(marker));
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: options.capture ? ['ignore', 'pipe', 'pipe'] : 'ignore',
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${path.basename(command)} exited unsuccessfully`);
  }
  return result.stdout || '';
}

async function unusedPort() {
  const net = require('node:net');
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitReady(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited before readiness');
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

async function waitForText(page, text, timeoutMs = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible', timeout: timeoutMs,
  });
}

async function waitForHostSemanticLabel(page, expected, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  const semantics = page.locator('flt-semantics');
  while (Date.now() < deadline) {
    const found = await semantics.evaluateAll((nodes, expectedLabel) =>
      nodes.some((node) => {
        const ariaLabel = node.getAttribute('aria-label') || '';
        const innerText = node.innerText || '';
        return ariaLabel.includes(expectedLabel) || innerText.includes(expectedLabel);
      }), expected);
    if (found) return;
    await page.waitForTimeout(100);
  }
  throw new Error('host semantic label unavailable');
}

async function visibleButton(page, label, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const locator = page.getByRole('button', { name: label, exact: true });
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button unavailable: ${label}`);
}

async function click(page, label) {
  await (await visibleButton(page, label)).click();
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  );
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const matches = [];
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) matches.push(candidate);
    }
    assertThat(matches.length <= 1, `multiple visible inputs matched ${label}`);
    if (matches.length === 1) return matches[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`visible input unavailable: ${label}`);
}

async function fill(page, label, value, onStage = null) {
  onStage?.('locate field');
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt++) {
    onStage?.(`click field attempt ${attempt + 1}`);
    await locator.click();
    await page.waitForTimeout(120);
    await locator.press('Control+A');
    onStage?.(`enter value attempt ${attempt + 1}`);
    await locator.pressSequentially(value, { delay: 15 });
    await page.waitForTimeout(120);
    onStage?.(`verify entered value attempt ${attempt + 1}`);
    if (await locator.inputValue() !== value) continue;
    onStage?.(`tab and recheck value attempt ${attempt + 1}`);
    await locator.press('Tab');
    await page.waitForTimeout(80);
    if (await locator.inputValue() === value) return;
  }
  throw new Error(`input did not retain ${label}`);
}

async function paste(page, label, value, onStage = null) {
  onStage?.('locate field');
  const locator = await field(page, label);
  onStage?.('write clipboard');
  await page.evaluate(async (clipboardValue) => {
    await navigator.clipboard.writeText(clipboardValue);
  }, value);

  for (let attempt = 0; attempt < 2; attempt++) {
    onStage?.(`click field attempt ${attempt + 1}`);
    await locator.click();
    await locator.press('Control+A');
    onStage?.(`paste clipboard attempt ${attempt + 1}`);
    await locator.press('Control+V');
    await page.waitForTimeout(300);
    onStage?.(`verify pasted value attempt ${attempt + 1}`);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(80);
    onStage?.(`verify value after tab attempt ${attempt + 1}`);
    if (await locator.inputValue() === value) return;
  }

  onStage?.('fast fill fallback');
  await locator.fill(value);
  await page.waitForTimeout(100);
  onStage?.('verify fallback value');
  if (await locator.inputValue() === value) {
    await locator.press('Tab');
    await page.waitForTimeout(80);
    if (await locator.inputValue() === value) return;
  }
  throw new Error(`input did not retain ${label}`);
}

async function enableSemantics(page) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const state = await page.evaluate(() => ({
      sodiumReady: typeof window.sodium?.ready?.then === 'function',
      placeholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      semanticNodes: document.querySelectorAll('flt-semantics').length,
    }));
    if (state.sodiumReady && (state.placeholder || state.semanticNodes > 0)) break;
    await page.waitForTimeout(100);
  }
  await page.evaluate(async () => window.sodium?.ready);
  const semanticDeadline = Date.now() + 15000;
  while (Date.now() < semanticDeadline) {
    if (await page.locator('flt-semantics').count() > 0) return;
    const placeholder = page.locator('flt-semantics-placeholder');
    if (await placeholder.count() > 0) {
      await placeholder.first().evaluate((node) => node.click());
    }
    await page.waitForTimeout(100);
  }
  throw new Error('Flutter semantics tree did not initialize');
}

async function connectSecurely(page, baseUrl) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function waitForHosts(page) {
  await visibleButton(page, 'Add host', 30000);
}

async function syncNow(page, profile) {
  const deadline = Date.now() + 20000;
  let status;
  while (Date.now() < deadline) {
    const buttons = page.getByRole('button', { name: SYNC_STATUS });
    for (let index = 0; index < await buttons.count(); index += 1) {
      const candidate = buttons.nth(index);
      if (!await candidate.isVisible().catch(() => false)) continue;
      const candidateLabel = (await candidate.getAttribute('aria-label') ||
        await candidate.innerText()).trim();
      if (candidateLabel === 'Syncing') continue;
      status = candidate;
      break;
    }
    if (status) break;
    await page.waitForTimeout(100);
  }
  assertThat(status, `${profile} sync status control was unavailable`);
  const changesResponse = page.waitForResponse((response) => {
    let url;
    try { url = new URL(response.url()); } catch (_) { return false; }
    return response.request().method() === 'GET' && url.pathname.endsWith('/changes');
  }, { timeout: 45000 });
  await status.click();
  const response = await changesResponse;
  assertThat(response.status() === 200, `${profile} changes pull was not successful`);
  const stateDeadline = Date.now() + 45000;
  while (Date.now() < stateDeadline) {
    const currentButtons = page.getByRole('button', { name: SYNC_STATUS });
    let currentLabel = '';
    for (let index = 0; index < await currentButtons.count(); index += 1) {
      const candidate = currentButtons.nth(index);
      if (!await candidate.isVisible().catch(() => false)) continue;
      currentLabel = (await candidate.getAttribute('aria-label') ||
        await candidate.innerText()).trim();
      break;
    }
    if (currentLabel === 'Idle' || currentLabel === 'Read-only') return response;
    if (currentLabel === 'Pending' || /^\d+ pending$/.test(currentLabel)) {
      throw new Error(`${profile} sync ended with pending local records`);
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`${profile} sync did not settle`);
}

async function waitForCondition(predicate, label, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} timed out`);
}

function vaultSnapshot(databasePath, username) {
  const script = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "row=db.execute(\"SELECT v.vault_id,COALESCE(vc.last_committed_seq,0) FROM users u JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' JOIN vaults v ON v.vault_id=vm.vault_id AND v.state='active' LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE u.username=? ORDER BY v.vault_id LIMIT 1\",(sys.argv[2],)).fetchone()",
    "print(json.dumps({'vaultId':row[0] if row else None,'commitSeq':str(row[1]) if row else None}))",
  ].join(';');
  const result = spawnSync('python3', ['-c', script, databasePath, username], {
    encoding: 'utf8', timeout: 8000,
  });
  assertThat(result.status === 0, 'isolated Vault snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverImportSnapshot(databasePath, vaultId, sinceSeq) {
  const script = [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,since=sys.argv[2],int(sys.argv[3])',
    "rows=db.execute('SELECT e.record_id,e.event_type,e.revision_id,e.commit_seq,v.operation,v.envelope FROM change_events e JOIN record_versions v ON v.vault_id=e.vault_id AND v.record_id=e.record_id AND v.revision_id=e.revision_id WHERE e.vault_id=? AND CAST(e.commit_seq AS INTEGER)>? ORDER BY CAST(e.commit_seq AS INTEGER)',(vault,since)).fetchall()",
    'events=[]',
    'for record,kind,revision,seq,operation,envelope_text in rows:',
    '    try: envelope=json.loads(envelope_text)',
    '    except Exception: envelope={}',
    "    header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
    "    valid=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and all(isinstance(envelope.get(key),str) and envelope[key] and all(char.isalnum() or char in '-_' for char in envelope[key]) for key in ('nonce','ciphertext','signature'))",
    "    receipt_rows=db.execute('SELECT record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,header.get('op_id'))).fetchall() if header.get('op_id') else []",
    "    head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "    events.append({'recordId':record,'eventType':kind,'revisionId':revision,'commitSeq':str(seq),'operation':operation,'header':header,'envelope':envelope,'envelopeSha256':hashlib.sha256(json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest(),'validEnvelope':bool(valid),'headRevisionId':head[0] if head else None,'headDeleted':bool(head[1]) if head else None,'headCommitSeq':str(head[2]) if head else None,'receipts':[{'recordId':r[0],'revisionId':r[1],'commitSeq':str(r[2])} for r in receipt_rows]})",
    "print(json.dumps({'events':events,'commitSeq':str(db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()[0])}))",
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, vaultId, String(sinceSeq)], {
    encoding: 'utf8', timeout: 12000, maxBuffer: 8 * 1024 * 1024,
  });
  assertThat(result.status === 0, 'import record state query failed');
  return JSON.parse(result.stdout);
}

function privacyFileMatches(paths) {
  return CONFIG_MARKERS.filter((marker) => paths.some((file) =>
    fs.existsSync(file) && fs.readFileSync(file).includes(Buffer.from(marker))));
}

async function readClientSqliteFiles(page) {
  return page.evaluate(async () => {
    if (typeof indexedDB.databases !== 'function') {
      return { available: false, reason: 'database-list-unavailable' };
    }
    const names = await indexedDB.databases();
    if (!names.some((database) => database.name === 'atermius_vault')) {
      return { available: false, reason: 'vault-database-missing' };
    }
    const connection = await new Promise((resolve, reject) => {
      const request = indexedDB.open('atermius_vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('database open failed'));
      request.onblocked = () => reject(new Error('database open blocked'));
    });
    try {
      if (!connection.objectStoreNames.contains('files') ||
          !connection.objectStoreNames.contains('blocks')) {
        return { available: false, reason: 'sqlite-stores-missing' };
      }
      const filesTx = connection.transaction('files', 'readonly');
      const filesComplete = new Promise((resolve, reject) => {
        filesTx.oncomplete = resolve;
        filesTx.onerror = () => reject(filesTx.error || new Error('file metadata read failed'));
        filesTx.onabort = () => reject(filesTx.error || new Error('file metadata read aborted'));
      });
      const [values, keys] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAll();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file values read failed'));
        }),
        new Promise((resolve, reject) => {
          const request = filesTx.objectStore('files').getAllKeys();
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error || new Error('file keys read failed'));
        }),
        filesComplete,
      ]);
      const files = values.map((value, index) => ({
        fileId: Number(keys[index]),
        name: String(value?.name || ''),
        length: Number(value?.length),
      })).filter((file) => file.name === '/database' ||
        file.name === '/database-journal');
      if (!files.some((file) => file.name === '/database') ||
          files.some((file) => !Number.isSafeInteger(file.fileId) ||
            !Number.isSafeInteger(file.length) || file.length < 0 ||
            file.length > 64 * 1024 * 1024)) {
        return { available: false, reason: 'sqlite-file-metadata-invalid' };
      }
      const blocksTx = connection.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error || new Error('sqlite block read failed'));
        blocksTx.onabort = () => reject(blocksTx.error || new Error('sqlite block read aborted'));
      });
      const store = blocksTx.objectStore('blocks');
      const sqliteFiles = await Promise.all(files.map(async (file) => {
        const range = IDBKeyRange.bound([file.fileId, 0],
          [file.fileId, Number.MAX_SAFE_INTEGER]);
        const [blockKeys, blockValues] = await Promise.all([
          new Promise((resolve, reject) => {
            const request = store.getAllKeys(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('sqlite block keys read failed'));
          }),
          new Promise((resolve, reject) => {
            const request = store.getAll(range);
            request.onsuccess = () => resolve(request.result || []);
            request.onerror = () => reject(request.error || new Error('sqlite block values read failed'));
          }),
        ]);
        const blocks = await Promise.all(blockKeys.map(async (key, index) => {
          const value = blockValues[index];
          let bytes;
          if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
          else if (ArrayBuffer.isView(value)) {
            bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
          } else if (value instanceof Blob) {
            bytes = new Uint8Array(await value.arrayBuffer());
          } else throw new Error('unsupported sqlite block value');
          let binary = '';
          for (let offset = 0; offset < bytes.length; offset += 0x8000) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
          }
          return { offset: Number(key?.[1]), base64: btoa(binary) };
        }));
        return { ...file, blocks };
      }));
      await blocksComplete;
      return { available: true, sqliteFiles };
    } finally {
      connection.close();
    }
  });
}

function inspectClientSqliteMarkerPrivacy(sqliteFiles) {
  const scannedFiles = sqliteFiles
    .filter((file) => file.name === '/database' || file.name === '/database-journal')
    .map((file) => ({
      name: file.name,
      length: file.length,
      bytes: reconstructSqliteFile({
        fileId: file.fileId,
        name: file.name,
        length: file.length,
        blocks: file.blocks.map((block) => ({
          offset: block.offset,
          bytes: Buffer.from(block.base64, 'base64'),
        })),
      }),
    }));
  const leaks = CONFIG_MARKERS.filter((marker) => scannedFiles.some((file) =>
    file.bytes.includes(Buffer.from(marker, 'utf8'))));
  return {
    available: scannedFiles.some((file) => file.name === '/database'),
    databaseLength: scannedFiles.find((file) => file.name === '/database')?.length || 0,
    journalLength: scannedFiles.find((file) => file.name === '/database-journal')?.length || 0,
    markerLeakCount: leaks.length,
  };
}

function waitForChildExit(child, timeoutMs) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    let done = false;
    const finish = (exited) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      child.removeListener('exit', onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMs);
    child.once('exit', onExit);
  });
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
  'compiled Flutter Web release is missing; build the client first');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST]);
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated server binary is unavailable');

  let tempRoot = null;
  let serverLog = null;
  let serverProcess = null;
  let serverLogPath = null;
  let databasePathForCleanup = null;
  let browser = null;
  let contextA = null;
  let contextB = null;
  let bootstrapToken;
  let captureImport = false;
  const browserClosed = new WeakSet();
  const contextsClosed = new WeakSet();
  const pageErrors = [];
  const consoleErrors = [];
  const failedRequests = [];
  const relayTickets = { A: [], B: [] };
  const relayWebSockets = { A: 0, B: 0 };
  const apiPrivacyChecks = [];
  const pushRequests = { A: [], B: [] };
  const pushResponses = { A: [], B: [] };
  const changePages = { A: [], B: [] };
  const pushRequestMap = new WeakMap();
  let finalCleanup = null;
  let cleanupPromise = null;

  const cleanupPass = async () => {
    const failures = [];
    for (const [context, label] of [[contextA, 'contextA'], [contextB, 'contextB']]) {
      if (!context || contextsClosed.has(context)) continue;
      try {
        await context.close();
        contextsClosed.add(context);
      } catch (_) { failures.push(label); }
    }
    if (browser && !browserClosed.has(browser)) {
      try {
        await browser.close();
        browserClosed.add(browser);
      } catch (_) { failures.push('browser'); }
    }
    if (serverProcess && serverProcess.exitCode === null &&
        serverProcess.signalCode === null) {
      try { serverProcess.kill('SIGTERM'); } catch (_) {}
      if (!await waitForChildExit(serverProcess, 5000)) {
        try { serverProcess.kill('SIGKILL'); } catch (_) {}
        if (!await waitForChildExit(serverProcess, 2000)) failures.push('server');
      }
    }
    const serverStopped = !serverProcess || serverProcess.exitCode !== null ||
      serverProcess.signalCode !== null;
    if (!serverStopped) failures.push('server');
    const serverLogClosed = serverLog === null || (() => {
      try { fs.closeSync(serverLog); serverLog = null; return true; } catch (_) { return false; }
    })();
    if (!serverLogClosed) failures.push('server_log');
    const plaintextMarkerCountAfterStop = privacyFileMatches([
      databasePathForCleanup,
      databasePathForCleanup ? `${databasePathForCleanup}-wal` : null,
      databasePathForCleanup ? `${databasePathForCleanup}-shm` : null,
      serverLogPath,
    ].filter(Boolean)).length;
    if (plaintextMarkerCountAfterStop > 0) failures.push('privacy');
    const tempRootBeforeRemove = tempRoot;
    if (serverStopped && tempRoot && fs.existsSync(tempRoot)) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch (_) { failures.push('temp_root'); }
    }
    const tempRootRemoved = !tempRoot || !fs.existsSync(tempRoot);
    if (!tempRootRemoved) failures.push('temp_root');
    finalCleanup = {
      contextAClosed: !contextA || contextsClosed.has(contextA),
      contextBClosed: !contextB || contextsClosed.has(contextB),
      browserClosed: !browser || browserClosed.has(browser),
      serverStopped,
      serverLogClosed,
      tempRoot: tempRootBeforeRemove,
      tempRootRemoved,
      plaintextMarkerCountAfterStop,
      failures,
    };
    console.log(`WEB-OPENSSH-CONFIG-CLEANUP ${JSON.stringify(finalCleanup)}`);
    return failures.length === 0;
  };
  const cleanup = () => {
    if (!cleanupPromise) cleanupPromise = cleanupPass();
    return cleanupPromise;
  };
  const handleTermination = (signal) => {
    if (process.exitCode === 1 || process.exitCode === 130 || process.exitCode === 143) return;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    void cleanup().catch(() => { process.exitCode = 1; });
  };
  const onSigint = () => handleTermination('SIGINT');
  const onSigterm = () => handleTermination('SIGTERM');
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);

  try {
    stage = 'create isolated local server fixtures';
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-openssh-import-'));
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    databasePathForCleanup = databasePath;
    const port = await unusedPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    serverLogPath = path.join(tempRoot, 'server.log');
    serverLog = fs.openSync(serverLogPath, 'a');
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'true',
      ATERMIUS_RELAY_ALLOW_CIDRS: '127.0.0.1/32',
      ATERMIUS_RELAY_ALLOW_PORTS: `${BASTION_PORT},${TARGET_PORT}`,
      RUST_LOG: process.env.RUST_LOG || 'warn',
    };
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT, env: serverEnv, stdio: ['ignore', serverLog, serverLog],
    });
    await waitReady(baseUrl, serverProcess);
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
      maxBuffer: 4096,
    });
    assertThat(bootstrap.status === 0, 'isolated server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
      'isolated server bootstrap token was not issued');

    stage = 'launch independent Chromium profiles';
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    contextA = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
    });
    contextB = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
    });
    await Promise.all([contextA, contextB].map((context) =>
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl })));

    const attachNetworkEvidence = (page, profile) => {
      page.on('pageerror', () => pageErrors.push(profile));
      page.on('console', (message) => {
        if (message.type() === 'error') consoleErrors.push(profile);
      });
      page.on('requestfailed', () => failedRequests.push(profile));
      page.on('request', (request) => {
        let url;
        try { url = new URL(request.url()); } catch (_) { return; }
        if (url.pathname.startsWith('/api/')) {
          apiPrivacyChecks.push({ profile, direction: 'request', markersAbsent: markerScan({
            url: url.href, body: request.postData() || '',
          }) });
        }
        if (url.pathname === '/api/v1/relay/tickets') relayTickets[profile].push(request);
        if (captureImport && url.pathname.endsWith('/sync/push') && request.method() === 'POST') {
          let operations = [];
          try {
            const body = request.postDataJSON();
            operations = (Array.isArray(body?.operations) ? body.operations : []).map((envelope) => ({
              operation: envelope?.header?.operation || null,
              recordId: envelope?.header?.record_id || null,
              revisionId: envelope?.header?.revision_id || null,
              opId: envelope?.header?.op_id || null,
              envelope: envelope || {},
              envelopeSha256: crypto.createHash('sha256').update(stableJson(envelope || {})).digest('hex'),
              envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
                'ciphertext,header,nonce,signature' &&
                ['nonce', 'ciphertext', 'signature'].every((key) =>
                  typeof envelope?.[key] === 'string' && /^[A-Za-z0-9_-]+$/.test(envelope[key])),
              markerFree: markerScan(envelope),
            }));
          } catch (_) {}
          const record = {
            profile,
            operations,
            requestBodyMarkerFree: markerScan(request.postData() || ''),
          };
          pushRequests[profile].push(record);
          pushRequestMap.set(request, record);
        }
      });
      page.on('response', (response) => {
        void (async () => {
          let url;
          try { url = new URL(response.url()); } catch (_) { return; }
          if (url.pathname.startsWith('/api/')) {
            const body = await response.text().catch(() => '');
            apiPrivacyChecks.push({ profile, direction: 'response', markersAbsent: markerScan({
              url: url.href, body,
            }) });
            if (url.pathname.endsWith('/sync/push') &&
                pushRequestMap.has(response.request())) {
              const parsed = (() => { try { return JSON.parse(body); } catch (_) { return {}; } })();
              const item = {
                profile,
                status: response.status(),
                request: pushRequestMap.get(response.request()),
                results: (Array.isArray(parsed?.results) ? parsed.results : []).map((result) => ({
                  opId: result?.op_id || null,
                  revisionId: result?.revision_id || null,
                  commitSeq: result?.commit_seq || null,
                  alreadyCommitted: result?.already_committed === true,
                })),
                responseMarkerFree: markerScan(body),
              };
              pushResponses[profile].push(item);
            }
            if (url.pathname.endsWith('/changes') && requestMethodGet(response)) {
              const parsed = (() => { try { return JSON.parse(body); } catch (_) { return {}; } })();
              const events = Array.isArray(parsed?.events) ? parsed.events : [];
              changePages[profile].push({
                status: response.status(),
                markerFree: markerScan(body),
                events: events.map((event) => ({
                  eventType: event?.event_type || null,
                  recordId: event?.record_id || null,
                  revisionId: event?.revision_id || null,
                  commitSeq: event?.commit_seq || null,
                  envelope: event?.envelope || null,
                  envelopeSha256: crypto.createHash('sha256')
                    .update(stableJson(event?.envelope || {})).digest('hex'),
                  envelopeShapeValid: Object.keys(event?.envelope || {}).sort().join(',') ===
                    'ciphertext,header,nonce,signature',
                })),
              });
            }
          }
        })().catch(() => {});
      });
      page.on('websocket', (websocket) => {
        try {
          if (new URL(websocket.url()).pathname === '/relay/v1/connect') {
            relayWebSockets[profile]++;
          }
        } catch (_) {}
      });
    };

    const pageA = await contextA.newPage();
    const pageB = await contextB.newPage();
    attachNetworkEvidence(pageA, 'A');
    attachNetworkEvidence(pageB, 'B');
    stage = 'initialize independent profile semantics';
    await Promise.all([pageA.goto(baseUrl, { waitUntil: 'domcontentloaded' }),
      pageB.goto(baseUrl, { waitUntil: 'domcontentloaded' })]);
    await Promise.all([enableSemantics(pageA), enableSemantics(pageB)]);
    await pageA.evaluate(() => localStorage.setItem('openssh-import-profile-check', 'A'));
    assertThat(await pageB.evaluate(() =>
      localStorage.getItem('openssh-import-profile-check')) === null,
    'profile A and B unexpectedly shared browser storage');

    stage = 'Profile A connect to the isolated server';
    await connectSecurely(pageA, baseUrl);
    stage = 'Profile A fill owner account email';
    await fill(pageA, 'Owner email', USERNAME);
    stage = 'Profile A fill owner master password';
    await fill(pageA, 'Master password · 12+ characters', MASTER_PASSWORD);
    stage = 'Profile A confirm owner master password';
    await fill(pageA, 'Confirm master password', MASTER_PASSWORD);
    stage = 'Profile A enter one-time bootstrap token';
    await fill(pageA, 'One-time bootstrap token', bootstrapToken);
    stage = 'Profile A set device name';
    await fill(pageA, 'Device name', DEVICE_A);
    stage = 'Profile A set first Vault name';
    await fill(pageA, 'First Vault', `OpenSSH import ${RUN_ID.slice(0, 8)}`);
    stage = 'Profile A submit owner account';
    await click(pageA, 'Create owner account');
    bootstrapToken = undefined;
    stage = 'Profile A wait for the writable Host page';
    await waitForHosts(pageA);

    stage = 'Profile B connect to the isolated server';
    await connectSecurely(pageB, baseUrl);
    stage = 'Profile B open login enrollment controls';
    await field(pageB, 'Email or username');
    await click(pageB, 'Add this device');
    stage = 'Profile B create enrollment request';
    await waitForText(pageB, 'Request this device');
    await fill(pageB, 'Account email', USERNAME);
    await fill(pageB, 'Device name', DEVICE_B);
    await click(pageB, 'Generate request');
    await field(pageB, 'Copy this enrollment JSON');
    await click(pageB, 'Copy');
    const enrollment = await pageB.evaluate(() => navigator.clipboard.readText());
    assertThat(JSON.parse(enrollment).format === 'atermius-device-enrollment-v1',
      'profile B enrollment request format was invalid');
    await click(pageB, 'Close');

    stage = 'Profile A open device enrollment approval';
    await click(pageA, 'Devices');
    await click(pageA, 'Approve enrollment');
    stage = 'Profile A locate Enrollment JSON field';
    await field(pageA, 'Enrollment JSON');
    stage = 'Profile A locate Review keys button';
    await visibleButton(pageA, 'Review keys');
    await paste(pageA, 'Enrollment JSON', enrollment, (substage) => {
      stage = `Profile A Enrollment JSON ${substage}`;
    });
    stage = 'Profile A click Review keys after request entry';
    await click(pageA, 'Review keys');
    stage = 'Profile A click Approve and seal keys';
    await click(pageA, 'Approve & seal keys');
    await visibleButton(pageA, 'Copy');
    await click(pageA, 'Copy');
    const approval = await pageA.evaluate(() => navigator.clipboard.readText());
    assertThat(approval.includes('atermius-device-approval-v1'),
      'profile A device approval was not generated');
    await click(pageA, 'Done');
    stage = 'Profile A return to writable Host page';
    await click(pageA, 'Hosts');
    await waitForHosts(pageA);

    stage = 'Profile B open approval import controls';
    await click(pageB, 'Import approval');
    stage = 'Profile B locate Paste approval JSON field';
    await field(pageB, 'Paste approval JSON');
    await paste(pageB, 'Paste approval JSON', approval, (substage) => {
      stage = `Profile B approval JSON ${substage}`;
    });
    stage = 'Profile B submit imported device keys';
    await click(pageB, 'Import device keys');
    stage = 'Profile B fill account email to unlock';
    await fill(pageB, 'Email or username', USERNAME);
    stage = 'Profile B fill master password to unlock';
    await fill(pageB, 'Master password', MASTER_PASSWORD);
    stage = 'Profile B submit unlock';
    await click(pageB, 'Sign in and unlock');
    stage = 'Profile B wait for decrypted Host page';
    await waitForHosts(pageB);
    await click(pageB, 'Hosts');
    await waitForHosts(pageB);
    const profileBInitialPull = changePages.B.length;
    stage = 'Profile B settle initial Vault sync';
    await syncNow(pageB, 'B');
    const emptyBaselinePending = await pageB.evaluate(() =>
      (document.body?.innerText || '').match(/Pending sync\s*(\d+)/)?.[1] || '0');
    assertThat(emptyBaselinePending === '0', 'profile B had pending work before import');
    stage = 'Profile A settle Vault sync before import baseline';
    await syncNow(pageA, 'A');
    const initialVault = vaultSnapshot(databasePath, USERNAME);
    assertThat(initialVault.vaultId && initialVault.commitSeq !== null,
      'the enrolled profiles did not have an active Vault baseline');

    const profileBPushBaseline = pushRequests.B.length;
    captureImport = true;
    stage = 'Profile A open importer and pass synthetic config bytes';
    await click(pageA, 'Import SSH config');
    await waitForText(pageA, 'Import OpenSSH config');
    const chooseFile = await visibleButton(pageA, 'Choose SSH config file');
    const [chooser] = await Promise.all([
      pageA.waitForEvent('filechooser', { timeout: 10000 }),
      chooseFile.click(),
    ]);
    await chooser.setFiles({
      name: 'config',
      mimeType: 'text/plain',
      buffer: Buffer.from(CONFIG_SOURCE, 'utf8'),
    });
    await waitForText(pageA, 'Preview: 2 Host(s) will be created');
    const previewSnapshot = await pageA.evaluate(({ targetAlias, jumpAlias, secretPaths }) => {
      const text = document.body?.innerText || '';
      const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
      return {
        targetAliasVisible: text.includes(targetAlias),
        jumpAliasVisible: text.includes(jumpAlias),
        importCountVisible: text.includes('Preview: 2 Host(s) will be created'),
        privatePathsVisible: secretPaths.some((path) => text.includes(path)),
        confirmImportNotYetVisible: !buttons.includes('Confirm import'),
        sourceMarkerVisible: text.includes('OPENSSH_CONFIG_SOURCE_PRIVATE_MARKER_'),
      };
    }, { targetAlias: TARGET_ALIAS, jumpAlias: BASTION_ALIAS,
      secretPaths: [BASTION_KEY_PATH, TARGET_KEY_PATH] });
    assertThat(previewSnapshot.targetAliasVisible && previewSnapshot.jumpAliasVisible &&
      previewSnapshot.importCountVisible && !previewSnapshot.privatePathsVisible &&
      previewSnapshot.confirmImportNotYetVisible && !previewSnapshot.sourceMarkerVisible,
    'import preview did not preserve safe fields, hide IdentityFile paths, or require confirmation');
    assertThat(vaultSnapshot(databasePath, USERNAME).commitSeq === initialVault.commitSeq,
      'preview wrote Host records before confirmation');

    stage = 'Profile A click Import 2 Hosts';
    await click(pageA, 'Import 2 Hosts');
    stage = 'Profile A wait for import confirmation dialog';
    await waitForText(pageA, 'Import these Hosts?');
    stage = 'Profile A verify Confirm import button is visible';
    assertThat(await pageA.getByRole('button', {
      name: 'Confirm import', exact: true,
    }).isVisible(), 'explicit confirmation action was missing');
    stage = 'Profile A verify confirmation dialog is not committed';
    assertThat(vaultSnapshot(databasePath, USERNAME).commitSeq === initialVault.commitSeq,
      'opening the confirmation dialog wrote Host records before explicit approval');
    stage = 'Profile A click Confirm import';
    await click(pageA, 'Confirm import');
    stage = 'Profile A wait for Imported 2 Host(s)';
    await waitForText(pageA, 'Imported 2 Host(s)');
    stage = 'Profile A wait for Via Jump Host semantic';
    await waitForHostSemanticLabel(pageA, `Via Jump Host: ${BASTION_ALIAS}`);
    const aHostLabels = await pageA.locator('flt-semantics').evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute('aria-label') || node.innerText || '')
        .filter((text) => text.startsWith('Host: ')));
    assertThat(aHostLabels.some((text) => text.includes(
      `Host: ${TARGET_ALIAS}; ${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}; Via Jump Host: ${BASTION_ALIAS}`)),
    'profile A did not render the imported target through its ProxyJump Host');

    stage = 'wait for profile A encrypted create operations and server commit';
    const committed = await waitForCondition(() => {
      const snapshot = vaultSnapshot(databasePath, USERNAME);
      if (BigInt(snapshot.commitSeq) < BigInt(initialVault.commitSeq) + 2n) return null;
      return snapshot;
    }, 'two imported Host commits');
    const importedState = serverImportSnapshot(databasePath, initialVault.vaultId,
      initialVault.commitSeq);
    const dbEvents = importedState.events;
    assertThat(BigInt(committed.commitSeq) - BigInt(initialVault.commitSeq) === 2n &&
      dbEvents.length === 2 && new Set(dbEvents.map((event) => event.recordId)).size === 2 &&
      dbEvents.every((event) => event.eventType === 'create' &&
        event.operation === 'create' && event.validEnvelope &&
        event.recordId === event.header.record_id &&
        event.revisionId === event.header.revision_id &&
        event.headRevisionId === event.revisionId && !event.headDeleted &&
        event.headCommitSeq === event.commitSeq && event.receipts.length === 1 &&
        event.receipts[0].recordId === event.recordId &&
        event.receipts[0].revisionId === event.revisionId &&
        event.receipts[0].commitSeq === event.commitSeq && markerScan(event.envelope)),
    'SQLite did not contain exactly two opaque create events with matching heads and receipts');
    const pushItems = pushRequests.A.flatMap((request) => request.operations);
    const pushResults = pushResponses.A.flatMap((response) => response.results);
    const expectedRecordIds = new Set(dbEvents.map((event) => event.recordId));
    assertThat(pushItems.length === 2 && pushItems.every((item) =>
      item.operation === 'create' && expectedRecordIds.has(item.recordId) &&
      item.envelopeShapeValid && item.markerFree) &&
      pushResponses.A.length >= 1 && pushResponses.A.every((response) =>
        response.status === 200 && response.request.requestBodyMarkerFree &&
        response.responseMarkerFree) &&
      pushResults.length === 2 && pushResults.every((result) =>
        result.alreadyCommitted === false &&
        dbEvents.some((event) => event.revisionId === result.revisionId &&
          event.header.op_id === result.opId && event.commitSeq === result.commitSeq &&
          pushItems.some((item) => item.opId === result.opId &&
            item.recordId === event.recordId && item.revisionId === event.revisionId &&
            item.envelopeSha256 === event.envelopeSha256))),
      'Profile A did not send exactly two opaque create envelopes with one matching commit receipt each');
    assertThat(pushRequests.B.length === profileBPushBaseline,
      'Profile B pushed local changes while receiving imported Hosts');

    stage = 'Profile B pull exact Host envelopes and decrypt Host plus ProxyJump';
    await click(pageB, 'Hosts');
    await syncNow(pageB, 'B');
    await waitForCondition(() => {
      const page = changePages.B.slice(profileBInitialPull).flatMap((item) => item.events);
      return expectedRecordIds.size === 2 && [...expectedRecordIds].every((recordId) =>
        page.some((event) => event.recordId === recordId && event.eventType === 'create'));
    }, 'profile B receive both imported Host event envelopes');
    const bPages = changePages.B.slice(profileBInitialPull);
    const bEvents = bPages.flatMap((item) => item.events)
      .filter((event) => expectedRecordIds.has(event.recordId));
    assertThat(bPages.length > 0 && bPages.every((page) => page.status === 200 && page.markerFree) &&
      bEvents.length === 2 && bEvents.every((event) => {
        const dbEvent = dbEvents.find((item) => item.recordId === event.recordId);
        const header = event.envelope?.header || {};
        return event.eventType === 'create' && event.envelopeShapeValid &&
          event.envelopeSha256 === dbEvent?.envelopeSha256 &&
          header.record_id === dbEvent.recordId && header.revision_id === dbEvent.revisionId &&
          header.operation === 'create' && markerScan(event.envelope);
      }),
    'Profile B changes response did not contain the exact committed Host envelopes');

    await waitForHostSemanticLabel(pageB, `Via Jump Host: ${BASTION_ALIAS}`);
    const bHostLabels = await pageB.locator('flt-semantics').evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute('aria-label') || node.innerText || '')
        .filter((text) => text.startsWith('Host: ')));
    const targetLabel = `Host: ${TARGET_ALIAS}; ${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}; Via Jump Host: ${BASTION_ALIAS}`;
    const bastionLabel = `Host: ${BASTION_ALIAS}; ${BASTION_USER}@${BASTION_HOST}:${BASTION_PORT}`;
    assertThat(bHostLabels.includes(targetLabel) && bHostLabels.includes(bastionLabel),
      'Profile B did not decrypt and render exact imported Host fields and ProxyJump relationship');
    const bPrivacyProbe = await pageB.evaluate((paths) => {
      const text = document.body?.innerText || '';
      return { identityFilePathVisible: paths.some((value) => text.includes(value)) };
    }, [BASTION_KEY_PATH, TARGET_KEY_PATH]);
    assertThat(!bPrivacyProbe.identityFilePathVisible,
      'Profile B rendered an IdentityFile path');

    stage = 'assert import-only sync, zero Relay, privacy, and browser errors';
    await pageB.waitForTimeout(300);
    if (serverLog !== null) fs.fsyncSync(serverLog);
    const apiLeaks = apiPrivacyChecks.filter((item) => !item.markersAbsent);
    const [idbA, idbB] = await Promise.all([
      readClientSqliteFiles(pageA), readClientSqliteFiles(pageB),
    ]);
    assertThat(idbA.available === true && idbB.available === true,
      'one profile did not expose its Drift SQLite IndexedDB snapshot');
    const indexedDbPrivacyA = inspectClientSqliteMarkerPrivacy(idbA.sqliteFiles);
    const indexedDbPrivacyB = inspectClientSqliteMarkerPrivacy(idbB.sqliteFiles);
    const databaseLeaks = privacyFileMatches([
      databasePath, `${databasePath}-wal`, `${databasePath}-shm`,
    ]);
    const logLeaks = privacyFileMatches([path.join(tempRoot, 'server.log')]);
    assertThat(apiPrivacyChecks.length > 0 && apiLeaks.length === 0,
      'an API request or response exposed OpenSSH config plaintext');
    assertThat(databaseLeaks.length === 0 && logLeaks.length === 0,
      'SQLite/WAL/SHM or server logs exposed OpenSSH config plaintext');
    assertThat(indexedDbPrivacyA.available && indexedDbPrivacyB.available &&
      indexedDbPrivacyA.markerLeakCount === 0 && indexedDbPrivacyB.markerLeakCount === 0,
    'a Profile A or B IndexedDB SQLite snapshot exposed OpenSSH config plaintext');
    assertThat(relayTickets.A.length === 0 && relayTickets.B.length === 0 &&
      relayWebSockets.A === 0 && relayWebSockets.B === 0,
    'import or sync requested an SSH Relay ticket or WebSocket');
    assertThat(pageErrors.length === 0 && consoleErrors.length === 0 && failedRequests.length === 0,
      'a Chromium profile reported a page, console, or failed-request error');

    console.log('WEB-OPENSSH-CONFIG-IMPORT-01 passed', JSON.stringify({
      independentlyEnrolledProfiles: true,
      profileAExplicitConfirmation: true,
      importedHostCount: dbEvents.length,
      encryptedCreateOperationCount: pushItems.length,
      pushReceiptCount: pushResults.length,
      sqliteEventCount: dbEvents.length,
      sqliteDistinctCommitCount: new Set(dbEvents.map((event) => event.commitSeq)).size,
      sqliteHeadAndReceiptLinksExact: true,
      profileBExactEnvelopeDecrypt: true,
      profileBHostCount: bHostLabels.length,
      proxyJumpRelationshipPreserved: bHostLabels.includes(targetLabel),
      apiPlaintextMarkerLeaks: apiLeaks.length,
      sqliteWalShmPlaintextMarkerLeaks: databaseLeaks.length,
      profileAIndexedDbSqliteMarkerLeaks: indexedDbPrivacyA.markerLeakCount,
      profileBIndexedDbSqliteMarkerLeaks: indexedDbPrivacyB.markerLeakCount,
      serverLogPlaintextMarkerLeaks: logLeaks.length,
      relayTicketDelta: relayTickets.A.length + relayTickets.B.length,
      relayWebSocketDelta: relayWebSockets.A + relayWebSockets.B,
      pageErrorCount: pageErrors.length,
      consoleErrorCount: consoleErrors.length,
      failedRequestCount: failedRequests.length,
      syntheticConfigWrittenToDisk: false,
      profileBLocalPushDelta: pushRequests.B.length - profileBPushBaseline,
    }));
  } finally {
    bootstrapToken = undefined;
    const clean = await cleanup();
    if (!clean) process.exitCode = 1;
    process.removeListener('SIGINT', onSigint);
    process.removeListener('SIGTERM', onSigterm);
  }

  assertThat(finalCleanup?.failures.length === 0 && finalCleanup?.tempRootRemoved,
    'isolated import acceptance cleanup was incomplete');
}

function requestMethodGet(response) {
  return response.request().method() === 'GET';
}

main().catch((error) => {
  const errorCategory = safeFailureCategory(error);
  console.error(`WEB-OPENSSH-CONFIG-IMPORT-01 failed at ${stage} (${errorCategory}); sensitive diagnostics omitted`);
  process.exitCode = 1;
});
