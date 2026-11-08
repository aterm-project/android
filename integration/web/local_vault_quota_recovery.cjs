/*
 * WEB-LOCAL-QUOTA-01: prove a LocalVault Host save survives real Chromium
 * origin quota failure without a partial record, then succeeds once storage
 * recovers in the same persistent browser profile.
 */

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const PROFILE_PASSWORD = `LocalQuota${crypto.randomBytes(20).toString('hex')}9`;
const HOST_NAME = `local-quota-${RUN_ID}`;
const HOST_ADDRESS = `host-${RUN_ID}.example.test`;
const HOST_USERNAME = `user-${RUN_ID.slice(0, 8)}`;
const MARKERS = [HOST_NAME, HOST_ADDRESS, HOST_USERNAME];
const QUOTA_LIMIT_BYTES = 8 * 1024 * 1024;

let activeStage = 'preflight';
let tempRoot;
let profileDir;
let context;
let page;
let staticServer;
let cdp;
let quotaOrigin;
let pageErrors = 0;
let cleanupFailed = false;
const apiRequests = [];
const remoteRequests = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  activeStage = value;
  console.log(`stage: ${value}`);
}

function mimeType(filePath) {
  return ({
    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png',
    '.ico': 'image/x-icon', '.css': 'text/css; charset=utf-8',
  })[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

async function startStaticServer() {
  const server = http.createServer((request, response) => {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405).end();
      return;
    }
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
    catch (_) { response.writeHead(400).end(); return; }
    const filePath = path.resolve(WEB_ROOT, pathname === '/' ? 'index.html' : pathname.slice(1));
    if (filePath !== WEB_ROOT && !filePath.startsWith(`${WEB_ROOT}${path.sep}`)) {
      response.writeHead(404).end();
      return;
    }
    fs.stat(filePath, (error, stat) => {
      if (error || !stat.isFile()) { response.writeHead(404).end(); return; }
      response.writeHead(200, {
        'Content-Type': mimeType(filePath),
        'Cache-Control': 'no-store',
        'Content-Length': stat.size,
        'X-Content-Type-Options': 'nosniff',
      });
      if (request.method === 'HEAD') response.end();
      else fs.createReadStream(filePath).pipe(response);
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  staticServer = server;
  return `http://127.0.0.1:${server.address().port}`;
}

function instrument(targetPage) {
  targetPage.on('pageerror', () => { pageErrors += 1; });
  targetPage.on('request', (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (url.origin !== `http://127.0.0.1:${staticServer.address().port}`) {
      remoteRequests.push(`${url.origin}${url.pathname}`);
    }
    if (/^\/(api|auth|sync)(\/|$)/.test(url.pathname)) {
      apiRequests.push(`${request.method()} ${url.pathname}`);
    }
  });
}

async function launchSameProfile() {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    locale: 'zh-CN',
    viewport: { width: 1280, height: 900 },
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  context = await chromium.launchPersistentContext(profileDir, options);
  page = context.pages()[0] || await context.newPage();
  instrument(page);
  return page;
}

async function activateSemantics() {
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'visible', timeout: 20000 });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 20000 });
}

async function visibleText(expected, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const present = await page.evaluate((text) => {
      const semantic = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
            style.visibility !== 'hidden' && Number(style.opacity) !== 0;
        }).map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body?.innerText || ''}\n${semantic}`.includes(text);
    }, expected).catch(() => false);
    if (present) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`expected UI text unavailable: ${expected}`);
}

async function waitAbsent(expected, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const present = await page.evaluate((text) => {
      const semantic = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
            style.visibility !== 'hidden' && Number(style.opacity) !== 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body?.innerText || ''}\n${semantic}`.includes(text);
    }, expected).catch(() => true);
    if (!present) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`text remained visible: ${expected}`);
}

async function button(label, timeoutMs = 20000) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await locator.waitFor({ state: 'visible', timeout: timeoutMs });
  return locator;
}

async function field(label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function fill(label, value) {
  const locator = await field(label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 35 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`input did not retain value for ${label}`);
}

async function tapSemanticContaining(text) {
  const tapped = await page.evaluate((expected) => {
    const isVisibleMatch = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      const label = `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`;
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0 && label.includes(expected);
    };
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(isVisibleMatch);
    if (buttons.length === 1) {
      buttons[0].click();
      return true;
    }
    const matches = [...document.querySelectorAll('flt-semantics')].filter(isVisibleMatch);
    if (!matches.length) return false;
    matches.sort((a, b) => {
      const left = a.getBoundingClientRect();
      const right = b.getBoundingClientRect();
      return left.width * left.height - right.width * right.height;
    });
    matches[0].click();
    return true;
  }, text);
  assertThat(tapped, `local profile action was not visible: ${text}`);
}

async function openLocalProfile(profileId, navigate = true) {
  if (navigate) {
    await page.goto(quotaOrigin, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
  }
  await visibleText('Choose a workspace');
  await (await button('Open locally')).click();
  await visibleText('选择配置解锁');
  await tapSemanticContaining(`本地配置 · ${profileId.slice(0, 8)}`);
  await page.waitForTimeout(350);
  const controls = await page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0;
    };
    return {
      inputLabels: [...document.querySelectorAll('input,textarea')]
        .filter(visible).map((element) => element.getAttribute('aria-label') || ''),
      actionLabels: [...document.querySelectorAll('flt-semantics[role="button"],button')]
        .filter(visible).map((element) => element.getAttribute('aria-label') || element.innerText || ''),
      hasUnlockHeading: [...document.querySelectorAll('flt-semantics')]
        .filter(visible).some((element) => (element.innerText || '').includes('选择配置解锁')),
    };
  });
  if (!controls.inputLabels.includes('本地配置主密码')) {
    console.log('WEB-LOCAL-QUOTA-01 profile chooser controls', JSON.stringify(controls));
  }
  await fill('本地配置主密码', PROFILE_PASSWORD);
  await (await button('解锁本地配置')).click();
}

async function openLocalModeChooser() {
  await page.goto(quotaOrigin, { waitUntil: 'domcontentloaded', timeout: 20000 });
  await activateSemantics();
  await visibleText('Choose a workspace');
  await (await button('Open locally')).click();
}

async function localDatabaseNames() {
  return page.evaluate(async () => (await indexedDB.databases())
    .map((database) => database.name || '').filter(Boolean).sort());
}

async function fillOriginToQuota() {
  return page.evaluate(async () => {
    let database;
    try {
      database = await new Promise((resolve, reject) => {
        const request = indexedDB.open('atermius_local_quota_probe', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('payload');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('probe open failed'));
      });
      let successfulWrites = 0;
      let writtenBytes = 0;
      let quotaError = null;
      let key = 0;
      const write = async (size) => new Promise((resolve) => {
        const transaction = database.transaction('payload', 'readwrite');
        const request = transaction.objectStore('payload').put(crypto.getRandomValues(
          new Uint8Array(size),
        ), key++);
        let requestError;
        request.onerror = () => { requestError = request.error?.name || null; };
        transaction.oncomplete = () => resolve(null);
        transaction.onabort = () => resolve(
          transaction.error?.name || requestError || 'AbortError',
        );
        transaction.onerror = () => {};
      });
      for (const size of [65536, 4096, 256]) {
        for (let attempt = 0; attempt < 1024; attempt += 1) {
          const error = await write(size);
          if (error) { quotaError ||= error; break; }
          successfulWrites += 1;
          writtenBytes += size;
        }
        if (quotaError) break;
      }
      const estimate = await navigator.storage.estimate();
      return {
        quotaError,
        successfulWrites,
        writtenBytes,
        usage: Number.isSafeInteger(estimate.usage) ? estimate.usage : null,
        quota: Number.isSafeInteger(estimate.quota) ? estimate.quota : null,
      };
    } catch (error) {
      return { quotaError: null, openError: error?.name || 'Error', successfulWrites: 0 };
    } finally { database?.close(); }
  });
}

async function deleteQuotaProbe() {
  await page.evaluate(async () => new Promise((resolve) => {
    const request = indexedDB.deleteDatabase('atermius_local_quota_probe');
    request.onsuccess = request.onerror = request.onblocked = resolve;
  }));
}

async function sqliteVfsState(databaseName, tableName, label) {
  const file = await page.evaluate(async (name) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(name);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('local database open failed'));
    });
    try {
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        throw new Error('local database VFS stores are missing');
      }
      const files = await new Promise((resolve, reject) => {
        const tx = db.transaction('files', 'readonly');
        const req = tx.objectStore('files').getAll();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => reject(req.error);
      });
      const fileTx = db.transaction('files', 'readonly');
      const fileTxComplete = new Promise((resolve, reject) => {
        fileTx.oncomplete = resolve;
        fileTx.onerror = () => reject(fileTx.error);
        fileTx.onabort = () => reject(fileTx.error || new Error('local database file read aborted'));
      });
      const keys = await new Promise((resolve, reject) => {
        const req = fileTx.objectStore('files').getAllKeys();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => reject(req.error);
      });
      await fileTxComplete;
      const index = files.findIndex((row) => row?.name === '/database' ||
        row?.name === `/${name}/database` || row?.name?.endsWith('/database'));
      if (index < 0) throw new Error('local SQLite main file is missing');
      const row = files[index];
      const fileId = Number(keys[index]);
      const tx = db.transaction('blocks', 'readonly');
      const txComplete = new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('local database block read aborted'));
      });
      const range = IDBKeyRange.bound([fileId, 0], [fileId, Number.MAX_SAFE_INTEGER]);
      const [blockKeys, values] = await Promise.all([
        new Promise((resolve, reject) => {
          const req = tx.objectStore('blocks').getAllKeys(range);
          req.onsuccess = () => resolve(req.result || []);
          req.onerror = () => reject(req.error);
        }),
        new Promise((resolve, reject) => {
          const req = tx.objectStore('blocks').getAll(range);
          req.onsuccess = () => resolve(req.result || []);
          req.onerror = () => reject(req.error);
        }),
      ]);
      await txComplete;
      const blocks = blockKeys.map((key, i) => {
        const value = values[i];
        const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
          ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
        if (!bytes) throw new Error('unsupported local SQLite block');
        return { offset: Number(key?.[1]), base64: btoa(String.fromCharCode(...bytes)) };
      });
      return { fileId, name: row.name, length: Number(row.length), blocks };
    } finally { db.close(); }
  }, databaseName);

  const bytes = reconstructSqliteFile({
    fileId: file.fileId,
    name: file.name,
    length: file.length,
    blocks: file.blocks.map((block) => ({
      offset: block.offset,
      bytes: Buffer.from(block.base64, 'base64'),
    })),
  });
  const snapshot = path.join(tempRoot, `${label}.sqlite`);
  fs.writeFileSync(snapshot, bytes, { mode: 0o600, flag: 'wx' });
  try {
    const python = [
      'import json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'table=sys.argv[2]',
      "assert table in ('local_vault_records','local_vault_binding','local_profile_catalog')",
      "result={'integrity':db.execute('PRAGMA integrity_check').fetchone()[0]}",
      `result['tableExists']=db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",(table,)).fetchone() is not None`,
      "result['recordCount']=db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] if result['tableExists'] else None",
      'print(json.dumps(result,separators=(",",":")))',
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshot, tableName], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 1024, stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) throw new Error('LocalVault read-only snapshot failed');
    const summary = JSON.parse(result.stdout);
    return {
      ...summary,
      markerFound: MARKERS.some((marker) => bytes.includes(Buffer.from(marker))),
      databaseBytes: file.length,
    };
  } finally { fs.rmSync(snapshot, { force: true }); }
}

async function localVaultSqliteState(profileId, label) {
  return sqliteVfsState(`atermius_local_vault_${profileId}`, 'local_vault_records', label);
}

async function localVaultBindingState(profileId, label) {
  return sqliteVfsState(`atermius_local_vault_${profileId}`, 'local_vault_binding', label);
}

async function localCatalogSqliteState(label) {
  return sqliteVfsState('atermius_profile_catalog', 'local_profile_catalog', label);
}

async function createHost() {
  await (await button('添加 Host')).click();
  await visibleText('添加本地 Host');
  await fill('名称', HOST_NAME);
  await fill('主机名或 IP', HOST_ADDRESS);
  await fill('SSH 用户名', HOST_USERNAME);
  await (await button('保存加密 Host')).click();
}

async function visibleOccurrenceCount(text) {
  return page.evaluate((expected) => {
    const semantic = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity) !== 0;
      }).map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const visibleText = `${document.body?.innerText || ''}\n${semantic}`;
    return visibleText.includes(expected) ? 1 : 0;
  }, text);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Web release is incomplete');
  }
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-local-quota-'));
  fs.chmodSync(tempRoot, 0o700);
  profileDir = path.join(tempRoot, 'chromium-profile');
  fs.mkdirSync(profileDir, { mode: 0o700 });
  const baseUrl = await startStaticServer();
  let summary;
  try {
    setStage('launch persistent profile and create LocalVault');
    await launchSameProfile();
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await visibleText('Choose a workspace');
    cdp = await context.newCDPSession(page);
    quotaOrigin = baseUrl;
    await cdp.send('Storage.overrideQuotaForOrigin', {
      origin: quotaOrigin, quotaSize: QUOTA_LIMIT_BYTES,
    });
    await (await button('Open locally')).click();
    await visibleText('还没有本地配置');
    await fill('主密码', PROFILE_PASSWORD);
    await (await button('创建并解锁')).click();
    await visibleText('还没有 Host', 90000);
    const profileId = await page.evaluate(async () => {
      const rows = await indexedDB.databases();
      const vault = rows.find((row) => row.name?.startsWith('atermius_local_vault_'));
      return vault?.name.slice('atermius_local_vault_'.length) || '';
    });
    assertThat(profileId.length > 0, 'LocalVault database was not initialized');
    const baseline = await localVaultSqliteState(profileId, 'baseline');
    assertThat(baseline.integrity === 'ok' && baseline.recordCount === 0 &&
      !baseline.markerFound, 'empty LocalVault baseline was not durable and clean');

    setStage('exhaust origin quota with native IndexedDB writes');
    const quotaProbe = await fillOriginToQuota();
    assertThat(quotaProbe.quotaError === 'QuotaExceededError' &&
      quotaProbe.successfulWrites > 0 && quotaProbe.writtenBytes > 0,
    'native IndexedDB did not reproduce QuotaExceededError under the origin quota');

    setStage('attempt encrypted LocalVault Host save under quota exhaustion');
    await createHost();
    const localRecoveryMessage =
      '本地存储写入中断。请先释放存储空间并关闭此站点的其他 Atermius 标签页，然后重新加载页面恢复后重试。';
    await visibleText(localRecoveryMessage, 20000);
    await visibleText('重新加载页面');
    await waitAbsent('还没有 Host');
    await waitAbsent('添加 Host');
    await waitAbsent(HOST_NAME);
    const failed = await localVaultSqliteState(profileId, 'failed');
    assertThat(failed.integrity === 'ok' && failed.recordCount === baseline.recordCount &&
      !failed.markerFound, 'failed save left a LocalVault record or plaintext marker');
    assertThat(apiRequests.length === 0 && remoteRequests.length === 0,
      'LocalVault failure contacted an API or remote origin');

    setStage('release quota and remove probe data');
    await cdp.send('Storage.overrideQuotaForOrigin', { origin: quotaOrigin });
    await deleteQuotaProbe();
    const restoredQuota = await cdp.send('Storage.getUsageAndQuota', { origin: quotaOrigin });
    assertThat(restoredQuota.overrideActive === false, 'Chromium quota override remained active');
    await cdp.detach().catch(() => {});
    cdp = null;

    setStage('reload the same persistent profile and verify failed save is absent');
    const hostRecoveryNavigation = page.waitForNavigation({
      waitUntil: 'domcontentloaded', timeout: 20000,
    });
    await (await button('重新加载页面')).click();
    await hostRecoveryNavigation;
    await activateSemantics();
    await visibleText('Choose a workspace');
    await openLocalProfile(profileId, false);
    await visibleText('还没有 Host', 30000);
    await waitAbsent(HOST_NAME);
    const afterRecoveryReload = await localVaultSqliteState(profileId, 'after-failure-reload');
    assertThat(afterRecoveryReload.integrity === 'ok' &&
      afterRecoveryReload.recordCount === baseline.recordCount &&
      !afterRecoveryReload.markerFound,
    'same-profile recovery reload found a partial failed Host record');

    setStage('retry the exact encrypted Host save after storage recovery');
    await createHost();
    await visibleText(HOST_NAME, 30000);
    const recovered = await localVaultSqliteState(profileId, 'recovered');
    assertThat(recovered.integrity === 'ok' && recovered.recordCount === 1 &&
      !recovered.markerFound, 'retry did not leave exactly one opaque LocalVault record');
    const visibleCountBeforeLock = await visibleOccurrenceCount(HOST_NAME);
    assertThat(visibleCountBeforeLock >= 1, 'retry did not render the decryptable Host');

    setStage('lock and reload persistent profile to verify decryptable recovery');
    await (await button('锁定配置')).click();
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await openLocalProfile(profileId);
    await visibleText(HOST_NAME, 30000);
    const visibleCountAfterReload = await visibleOccurrenceCount(HOST_NAME);
    const finalDb = await localVaultSqliteState(profileId, 'final');
    assertThat(visibleCountAfterReload >= 1 && finalDb.integrity === 'ok' &&
      finalDb.recordCount === 1 && !finalDb.markerFound,
    'locked/reloaded LocalVault did not decrypt its single encrypted Host');
    assertThat(apiRequests.length === 0 && remoteRequests.length === 0,
      'LocalVault quota recovery contacted an API or remote origin');
    assertThat(pageErrors === 0, 'browser raised an uncaught error during quota recovery');

    summary = {
      quotaLimitBytes: QUOTA_LIMIT_BYTES,
      nativeQuotaError: quotaProbe.quotaError,
      failedSaveVisible: true,
      failedRecordCount: failed.recordCount,
      failedRecordCountAfterRecoveryReload: afterRecoveryReload.recordCount,
      retryRecordCount: recovered.recordCount,
      decryptedHostAfterLockReload: true,
      duplicateHostRecords: recovered.recordCount - 1,
      localApiRequests: apiRequests.length,
      remoteRequests: remoteRequests.length,
      plaintextMarkersFound: false,
      uncaughtPageErrors: pageErrors,
    };

    setStage('initialize LocalProfileCatalog under exhausted origin quota');
    await context.close();
    context = null;
    profileDir = path.join(tempRoot, 'catalog-chromium-profile');
    fs.mkdirSync(profileDir, { mode: 0o700 });
    await launchSameProfile();
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await visibleText('Choose a workspace');
    cdp = await context.newCDPSession(page);
    await cdp.send('Storage.overrideQuotaForOrigin', {
      origin: quotaOrigin, quotaSize: QUOTA_LIMIT_BYTES,
    });
    const catalogQuotaProbe = await fillOriginToQuota();
    assertThat(catalogQuotaProbe.quotaError === 'QuotaExceededError' &&
      catalogQuotaProbe.successfulWrites > 0,
    'catalog scenario did not first exhaust origin quota with native IndexedDB writes');

    await (await button('Open locally')).click();
    const catalogFailureMessage =
      '本地存储写入中断。请先释放存储空间并关闭此站点的其他 Atermius 标签页，然后重新加载页面恢复后重试。';
    await visibleText(catalogFailureMessage, 20000);
    await visibleText('Choose a workspace');
    await waitAbsent('还没有本地配置');
    const databasesAfterCatalogFailure = await localDatabaseNames();
    assertThat(!databasesAfterCatalogFailure.some((name) =>
      name.startsWith('atermius_local_vault_')),
    'catalog initialization failure created a partial LocalVault profile database');
    const catalogFailureStayedInChooser = !(await (await button('Open locally')).isEnabled());
    await button('重新加载页面');

    setStage('release quota and retry LocalProfileCatalog in the same browser profile');
    await cdp.send('Storage.overrideQuotaForOrigin', { origin: quotaOrigin });
    await deleteQuotaProbe();
    const catalogRestoredQuota = await cdp.send('Storage.getUsageAndQuota', { origin: quotaOrigin });
    assertThat(catalogRestoredQuota.overrideActive === false,
      'catalog scenario Chromium quota override remained active');
    const reloadNavigation = page.waitForNavigation({
      waitUntil: 'domcontentloaded', timeout: 20000,
    });
    await (await button('重新加载页面')).click();
    await reloadNavigation;
    await activateSemantics();
    await visibleText('Choose a workspace');
    await (await button('Open locally')).click();
    try {
      await visibleText('还没有本地配置', 30000);
    } catch (error) {
      const ui = await page.evaluate(() => (document.body?.innerText || '').slice(0, 1000));
      throw new Error(`${error.message}; catalog retry UI: ${ui}`);
    }
    await waitAbsent(catalogFailureMessage);
    const emptyCatalog = await localCatalogSqliteState('catalog-empty-after-retry');
    assertThat(emptyCatalog.integrity === 'ok' && emptyCatalog.tableExists &&
      emptyCatalog.recordCount === 0,
    'catalog retry did not produce a valid empty profile catalog');

    setStage('create a profile after catalog recovery and inspect ciphertext bindings');
    await fill('主密码', PROFILE_PASSWORD);
    await (await button('创建并解锁')).click();
    await visibleText('还没有 Host', 90000);
    const catalogProfileIds = (await localDatabaseNames())
      .filter((name) => name.startsWith('atermius_local_vault_'))
      .map((name) => name.slice('atermius_local_vault_'.length));
    assertThat(catalogProfileIds.length === 1 && catalogProfileIds[0].length > 0,
      'catalog retry did not create exactly one LocalVault profile');
    const catalogProfileId = catalogProfileIds[0];
    const populatedCatalog = await localCatalogSqliteState('catalog-created-after-retry');
    const createdBinding = await localVaultBindingState(catalogProfileId, 'binding-created-after-retry');
    const emptyLocalVault = await localVaultSqliteState(catalogProfileId, 'vault-created-after-retry');
    assertThat(populatedCatalog.integrity === 'ok' && populatedCatalog.tableExists &&
      populatedCatalog.recordCount === 1 && createdBinding.integrity === 'ok' &&
      createdBinding.tableExists && createdBinding.recordCount === 1 &&
      emptyLocalVault.integrity === 'ok' && emptyLocalVault.recordCount === 0,
    'recovered profile catalog or LocalVault binding was not atomically durable');

    setStage('lock, reload, and unlock the catalog-bound profile');
    await (await button('锁定配置')).click();
    await visibleText('选择配置解锁');
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await openLocalProfile(catalogProfileId, false);
    await visibleText('还没有 Host', 30000);
    const catalogAfterReload = await localCatalogSqliteState('catalog-after-reload');
    const bindingAfterReload = await localVaultBindingState(catalogProfileId, 'binding-after-reload');
    assertThat(catalogAfterReload.integrity === 'ok' && catalogAfterReload.recordCount === 1 &&
      bindingAfterReload.integrity === 'ok' && bindingAfterReload.recordCount === 1,
    'catalog profile and LocalVault binding did not survive lock/reload/unlock');

    setStage('initialize catalog successfully before exhausting quota for profile-row creation');
    await context.close();
    context = null;
    cdp = null;
    profileDir = path.join(tempRoot, 'catalog-row-chromium-profile');
    fs.mkdirSync(profileDir, { mode: 0o700 });
    await launchSameProfile();
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await visibleText('Choose a workspace');
    await openLocalModeChooser();
    await visibleText('还没有本地配置');
    const emptyCatalogBeforePressure = await localCatalogSqliteState('catalog-row-empty-before-pressure');
    assertThat(emptyCatalogBeforePressure.integrity === 'ok' &&
      emptyCatalogBeforePressure.tableExists && emptyCatalogBeforePressure.recordCount === 0,
    'catalog row scenario did not start with a durable empty initialized catalog');

    // Restart the same persistent profile after catalog schema creation. Apply
    // Chromium's quota override before reopening the already initialized DB so
    // the failure is injected at the later profile-row transaction/flush.
    await context.close();
    context = null;
    await launchSameProfile();
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await visibleText('Choose a workspace');
    cdp = await context.newCDPSession(page);
    await cdp.send('Storage.overrideQuotaForOrigin', {
      origin: quotaOrigin, quotaSize: QUOTA_LIMIT_BYTES,
    });
    await (await button('Open locally')).click();
    await visibleText('还没有本地配置');
    const catalogRowQuotaProbe = await fillOriginToQuota();
    console.log('safe catalog profile-row quota probe', JSON.stringify(catalogRowQuotaProbe));
    assertThat(catalogRowQuotaProbe.quotaError === 'QuotaExceededError' &&
      catalogRowQuotaProbe.successfulWrites > 0,
    `catalog row scenario did not exhaust quota after successful catalog initialization: ${JSON.stringify(catalogRowQuotaProbe)}`);

    setStage('create LocalProfile under real quota exhaustion after catalog initialization');
    await fill('主密码', PROFILE_PASSWORD);
    await (await button('创建并解锁')).click();
    const recoveryMessage =
      '本地存储写入中断。请先释放存储空间并关闭此站点的其他 Atermius 标签页，然后重新加载页面恢复后重试。';
    await visibleText(recoveryMessage, 20000);
    await visibleText('重新加载页面');
    const vaultDatabasesAfterFailedCreate = (await localDatabaseNames())
      .filter((name) => name.startsWith('atermius_local_vault_'));
    assertThat(vaultDatabasesAfterFailedCreate.length === 0,
      'LocalProfile catalog-row quota failure created a LocalVault database before durable catalog success');
    await waitAbsent('创建并解锁');

    setStage('release quota and reload after catalog profile-row failure');
    await cdp.send('Storage.overrideQuotaForOrigin', { origin: quotaOrigin });
    await deleteQuotaProbe();
    const catalogRowRestoredQuota = await cdp.send('Storage.getUsageAndQuota', { origin: quotaOrigin });
    assertThat(catalogRowRestoredQuota.overrideActive === false,
      'catalog row scenario Chromium quota override remained active');
    const catalogRowReload = page.waitForNavigation({
      waitUntil: 'domcontentloaded', timeout: 20000,
    });
    await (await button('重新加载页面')).click();
    await catalogRowReload;
    await activateSemantics();
    await visibleText('Choose a workspace');
    await openLocalModeChooser();
    await visibleText('还没有本地配置', 30000);
    await waitAbsent(recoveryMessage);
    const catalogAfterFailedCreateReload = await localCatalogSqliteState('catalog-row-after-failure-reload');
    const vaultDatabasesAfterFailureReload = (await localDatabaseNames())
      .filter((name) => name.startsWith('atermius_local_vault_'));
    assertThat(catalogAfterFailedCreateReload.integrity === 'ok' &&
      catalogAfterFailedCreateReload.tableExists &&
      catalogAfterFailedCreateReload.recordCount === 0 &&
      vaultDatabasesAfterFailureReload.length === 0,
    'failed catalog profile-row write left a partial/orphan profile after reload');

    setStage('retry profile creation and verify one durable catalog row and binding');
    await fill('主密码', PROFILE_PASSWORD);
    await (await button('创建并解锁')).click();
    await visibleText('还没有 Host', 90000);
    const rowRetryProfileIds = (await localDatabaseNames())
      .filter((name) => name.startsWith('atermius_local_vault_'))
      .map((name) => name.slice('atermius_local_vault_'.length));
    assertThat(rowRetryProfileIds.length === 1 && rowRetryProfileIds[0].length > 0,
      'catalog row quota retry did not create exactly one LocalVault profile');
    const rowRetryProfileId = rowRetryProfileIds[0];
    const catalogAfterProfileRowRetry = await localCatalogSqliteState('catalog-row-after-retry');
    const bindingAfterProfileRowRetry = await localVaultBindingState(
      rowRetryProfileId, 'catalog-row-binding-after-retry',
    );
    assertThat(catalogAfterProfileRowRetry.integrity === 'ok' &&
      catalogAfterProfileRowRetry.recordCount === 1 &&
      bindingAfterProfileRowRetry.integrity === 'ok' &&
      bindingAfterProfileRowRetry.recordCount === 1,
    'catalog row retry did not create exactly one valid profile and binding');
    await (await button('锁定配置')).click();
    await visibleText('选择配置解锁');
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 20000 });
    await activateSemantics();
    await openLocalProfile(rowRetryProfileId, false);
    await visibleText('还没有 Host', 30000);
    const catalogAfterProfileRowRetryReload = await localCatalogSqliteState(
      'catalog-row-after-retry-reload',
    );
    const bindingAfterProfileRowRetryReload = await localVaultBindingState(
      rowRetryProfileId, 'catalog-row-binding-after-retry-reload',
    );
    assertThat(catalogAfterProfileRowRetryReload.integrity === 'ok' &&
      catalogAfterProfileRowRetryReload.recordCount === 1 &&
      bindingAfterProfileRowRetryReload.integrity === 'ok' &&
      bindingAfterProfileRowRetryReload.recordCount === 1,
    'retried LocalProfile row or binding did not survive lock/reload/unlock');
    assertThat(apiRequests.length === 0 && remoteRequests.length === 0,
      'LocalProfileCatalog quota recovery contacted an API or remote origin');
    assertThat(pageErrors === 0, 'browser raised an uncaught error during catalog quota recovery');

    Object.assign(summary, {
      catalogInitQuotaError: catalogQuotaProbe.quotaError,
      catalogFailureStayedInChooser,
      catalogFailureReloadRequired: true,
      catalogFailureDidNotCreateVault: true,
      catalogRetrySucceeded: true,
      catalogRowsAfterRetry: emptyCatalog.recordCount,
      catalogRowsAfterProfileCreate: populatedCatalog.recordCount,
      catalogRowsAfterReload: catalogAfterReload.recordCount,
      localVaultBindingRowsAfterReload: bindingAfterReload.recordCount,
      catalogProfileUnlockedAfterReload: true,
      catalogProfileRowQuotaError: catalogRowQuotaProbe.quotaError,
      profileCreateControlHiddenAfterFailure: true,
      catalogProfileRowFailureReloadRequired: true,
      catalogRowsAfterFailedCreateReload: catalogAfterFailedCreateReload.recordCount,
      localVaultsAfterFailedProfileCreate: vaultDatabasesAfterFailureReload.length,
      catalogRowsAfterProfileRowRetry: catalogAfterProfileRowRetry.recordCount,
      localVaultBindingsAfterProfileRowRetry: bindingAfterProfileRowRetry.recordCount,
      catalogRowsAfterProfileRowRetryReload: catalogAfterProfileRowRetryReload.recordCount,
      localVaultBindingsAfterProfileRowRetryReload: bindingAfterProfileRowRetryReload.recordCount,
      catalogProfileRowRetryUnlockedAfterReload: true,
      localApiRequests: apiRequests.length,
      remoteRequests: remoteRequests.length,
      uncaughtPageErrors: pageErrors,
    });
  } finally {
    if (cdp) {
      try { await cdp.send('Storage.overrideQuotaForOrigin', { origin: quotaOrigin }); }
      catch (_) {}
      try { await cdp.detach(); } catch (_) {}
    }
    if (context) await context.close().catch(() => { cleanupFailed = true; });
    if (staticServer) await new Promise((resolve) => staticServer.close(resolve));
    if (tempRoot) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
      catch (_) { cleanupFailed = true; }
      if (fs.existsSync(tempRoot)) cleanupFailed = true;
    }
  }
  assertThat(!cleanupFailed, 'quota runner did not clean its browser profile and temp files');
  console.log('WEB-LOCAL-QUOTA-01 passed', JSON.stringify(summary));
}

main().catch((error) => {
  console.error(`WEB-LOCAL-QUOTA-01 failed at ${activeStage}: ${error.message}`);
  if (page && !page.isClosed()) {
    page.evaluate(() => ({
      title: document.title,
      body: (document.body?.innerText || '').slice(0, 1000),
    })).then((state) => console.error('WEB-LOCAL-QUOTA-01 UI diagnostic', JSON.stringify(state)))
      .catch(() => {});
  }
  process.exitCode = 1;
});
