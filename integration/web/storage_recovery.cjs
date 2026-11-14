/*
 * WEB-STORAGE-RECOVERY: prove unsupported browser storage stops before the
 * local Vault connection opens, then recover after SharedWorker is restored.
 * The page uses an empty, ephemeral browser context and a disposable local
 * Rust server; it never registers, signs in, or calls an application API.
 */

const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const SAFE_IMPLEMENTATIONS = new Set(['opfsShared', 'opfsLocks', 'sharedIndexedDb']);

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function runChecked(command, args, cwd = ROOT) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    timeout: 180000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) throw new Error('acceptance prerequisite failed');
}

async function unusedPort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitReady(baseUrl, child) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error('isolated test server exited early');
    }
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1500),
      });
      if (response.status === 200) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated test server readiness timed out');
}

async function stopServer(child) {
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  if (!child || exited()) return;
  child.kill('SIGTERM');
  if (!await waitForProcessExit(child, 5000)) {
    child.kill('SIGKILL');
    if (!await waitForProcessExit(child, 5000)) {
      throw new Error('isolated test server did not stop');
    }
  }
}

function waitForProcessExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      child.removeListener('exit', finish);
      resolve(true);
    };
    const timer = setTimeout(() => {
      child.removeListener('exit', finish);
      resolve(child.exitCode !== null || child.signalCode !== null);
    }, timeoutMs);
    child.once('exit', finish);
  });
}

function startServer(port, dataDir, baseUrl, logFd) {
  const databaseUrl = `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`;
  const env = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: databaseUrl,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'false',
    ATERMIUS_WEB_DIR: WEB_ROOT,
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };
  return spawn(path.join(ROOT, 'server/target/debug/atermius-server'), ['serve'], {
    cwd: ROOT,
    env,
    stdio: ['ignore', logFd, logFd],
  });
}

async function waitForSemanticText(page, text, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await page.evaluate((expected) => {
      if ((document.body.innerText || '').includes(expected)) return true;
      return [...document.querySelectorAll('flt-semantics')].some((element) =>
        `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
          .includes(expected));
    }, text).catch(() => false);
    if (found) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected accessible startup text was not rendered');
}

async function activateAccessibilitySemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 15000 });
  await placeholder.evaluate((element) => element.click());
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const hasSemantics = await page.evaluate(() =>
      document.querySelectorAll('flt-semantics').length > 0,
    ).catch(() => false);
    if (hasSemantics) return;
    await page.waitForTimeout(100);
  }
  throw new Error('Flutter semantics tree did not appear after accessibility activation');
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Web release is incomplete');
  }

  let browser;
  let context;
  let page;
  let serverProcess;
  let serverLogFd;
  let tempRoot;
  let activeStage = 'setup';
  const apiRequests = [];
  const implementationMarkers = [];
  const pageErrorCategories = [];
  let recoveryScreenVisible = false;
  let recoveryLiveRegionAccessible = false;
  let initialLiveRegions = [];
  let authFlowVisible = false;
  let retryVisible = false;
  let nativeConstructorRestored = false;
  const browserSignalCategories = [];

  try {
    runChecked('cargo', ['build', '--locked', '--manifest-path', 'server/Cargo.toml']);
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-storage-recovery-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    serverLogFd = fs.openSync(path.join(tempRoot, 'server.log'), 'a');
    const port = await unusedPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    serverProcess = startServer(port, dataDir, baseUrl, serverLogFd);
    await waitReady(baseUrl, serverProcess);
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({ locale: 'zh-CN', viewport: { width: 1280, height: 900 } });

    // Preserve the actual browser constructor and hide it before Flutter or
    // Drift starts. Retry restores this exact function in the same realm.
    await context.addInitScript(() => {
      const nativeSharedWorker = globalThis.SharedWorker;
      Object.defineProperty(globalThis, '__atermiusNativeSharedWorker', {
        configurable: false,
        enumerable: false,
        value: nativeSharedWorker,
      });
      Object.defineProperty(globalThis, 'SharedWorker', {
        configurable: true,
        writable: true,
        value: undefined,
      });

      const storage = globalThis.navigator?.storage;
      if (storage) {
        const probe = {
          persisted: false,
          persistedCalls: 0,
          persistCalls: 0,
          estimateCalls: 0,
        };
        Object.defineProperty(globalThis, '__atermiusStorageProbe', {
          configurable: false,
          enumerable: false,
          value: probe,
        });
        Object.defineProperties(storage, {
          persisted: {
            configurable: true,
            value: async () => {
              probe.persistedCalls++;
              return probe.persisted;
            },
          },
          persist: {
            configurable: true,
            value: async () => {
              probe.persistCalls++;
              probe.persisted = true;
              return true;
            },
          },
          estimate: {
            configurable: true,
            value: async () => {
              probe.estimateCalls++;
              return { usage: 4096, quota: 16384 };
            },
          },
        });
      }
    });

    page = await context.newPage();
    page.on('request', (request) => {
      const url = new URL(request.url());
      if (url.pathname.startsWith('/api/')) {
        apiRequests.push({ method: request.method(), path: url.pathname });
      }
    });
    page.on('console', (message) => {
      const prefix = 'ATERMIUS_DRIFT_WEB_IMPLEMENTATION=';
      if (message.text().startsWith(prefix)) {
        implementationMarkers.push(message.text().slice(prefix.length).trim());
      }
    });
    page.on('pageerror', (error) => {
      pageErrorCategories.push(error?.name === 'TypeError' ? 'type-error' : 'runtime-error');
    });
    page.on('requestfailed', (request) => {
      const pathname = new URL(request.url()).pathname;
      browserSignalCategories.push(pathname.endsWith('.wasm') ? 'wasm-load-failure' :
        pathname.endsWith('.js') ? 'script-load-failure' : 'resource-load-failure');
    });
    page.on('console', (message) => {
      if (message.type() === 'error') browserSignalCategories.push('console-error');
    });

    activeStage = 'initial workspace chooser';
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await waitForSemanticText(page, 'Choose a workspace', 30000);
    await waitForSemanticText(page, 'Server account and sync', 15000);
    activeStage = 'browser storage status and estimate';
    await waitForSemanticText(page, 'Persistent storage is not enabled', 15000);
    await waitForSemanticText(page, 'Estimated usage: 4 KiB of 16 KiB for this site', 15000);
    const persistenceRequest = page.getByRole('button', {
      name: 'Request persistent storage',
      exact: true,
    });
    await persistenceRequest.waitFor({ state: 'visible', timeout: 15000 });
    await persistenceRequest.click();
    await waitForSemanticText(page, 'Persistent storage is enabled', 15000);
    const storageProbe = await page.evaluate(() => globalThis.__atermiusStorageProbe);
    assertThat(storageProbe?.persistCalls === 1,
      'persistent storage request was not sent to navigator.storage.persist');
    assertThat(storageProbe.persistedCalls >= 2,
      'the UI trusted the request result without re-reading persisted state');
    assertThat(storageProbe.estimateCalls >= 2,
      'the UI did not refresh the quota estimate after requesting persistence');
    assertThat(apiRequests.length === 0, 'application API was called before selecting Server mode');
    assertThat(implementationMarkers.length === 0,
      'Drift opened a Vault database before selecting Server mode');
    const initialServerContinue = page.getByRole('button', { name: 'Continue', exact: true });
    await initialServerContinue.waitFor({ state: 'visible', timeout: 15000 });
    assertThat(await initialServerContinue.isEnabled(), 'initial Server mode Continue button is disabled');
    await initialServerContinue.click();

    activeStage = 'unsupported storage recovery UI';
    await waitForSemanticText(page, '需要受支持的浏览器存储', 15000);

    // The server-specific failure stays on the mode chooser. Its Continue
    // action is the retry; no database or account UI may appear meanwhile.
    const retryButton = page.getByRole('button', { name: 'Continue', exact: true });
    retryVisible = await retryButton.isVisible();
    const initialState = await page.evaluate(() => {
      const bodyText = document.body.innerText || '';
      const liveRegions = [...document.querySelectorAll('[aria-live]')].filter((element) => {
        const rect = element.getBoundingClientRect();
        return ['polite', 'assertive'].includes(element.getAttribute('aria-live')) &&
          rect.width > 0 && rect.height > 0;
      });
      const semanticStorageGuidance = [...document.querySelectorAll('flt-semantics')]
        .some((element) =>
          `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
            .includes('需要受支持的浏览器存储'),
        );
      return {
        secureStorageCopy: /OPFS/.test(bodyText) && /共享 IndexedDB/.test(bodyText),
        authUiPresent: /Email or username|Sign in and unlock|Connect securely/.test(bodyText),
        liveRegionPresent: liveRegions.some((element) =>
          element.getAttribute('aria-live') === 'assertive',
        ),
        liveRegionHasStorageGuidance: semanticStorageGuidance,
        liveRegionDetails: [...document.querySelectorAll('[aria-live]')].map((element) => ({
          value: element.getAttribute('aria-live'),
          text: `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`.trim(),
          visible: (() => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          })(),
        })),
        nativeConstructorSaved: typeof globalThis.__atermiusNativeSharedWorker === 'function',
        sharedWorkerHidden: typeof globalThis.SharedWorker === 'undefined',
      };
    });
    initialLiveRegions = initialState.liveRegionDetails;
    recoveryScreenVisible = true;
    recoveryLiveRegionAccessible = initialState.liveRegionPresent &&
      initialState.liveRegionHasStorageGuidance;
    assertThat(retryVisible, 'server storage retry is not exposed as a visible accessible button');
    assertThat(initialState.secureStorageCopy, 'storage error does not explain supported secure storage');
    assertThat(recoveryLiveRegionAccessible, 'recovery announcement is not exposed through a live region');
    assertThat(!initialState.authUiPresent, 'authentication UI appeared before local storage was accepted');
    assertThat(initialState.nativeConstructorSaved && initialState.sharedWorkerHidden,
      'SharedWorker capability override was not installed as intended');
    assertThat(implementationMarkers.length === 0,
      'Drift opened a Vault database before rejecting unsupported storage');
    await page.waitForTimeout(800);
    assertThat(apiRequests.length === 0, 'application API was called before startup recovery');
    assertThat(implementationMarkers.length === 0,
      'Drift emitted a database-open marker before retry');

    activeStage = 'restore native storage capability and retry';
    nativeConstructorRestored = await page.evaluate(() => {
      const nativeSharedWorker = globalThis.__atermiusNativeSharedWorker;
      if (typeof nativeSharedWorker !== 'function') return false;
      Object.defineProperty(globalThis, 'SharedWorker', {
        configurable: true,
        writable: true,
        value: nativeSharedWorker,
      });
      return globalThis.SharedWorker === nativeSharedWorker;
    });
    assertThat(nativeConstructorRestored, 'native SharedWorker constructor was not restored');
    await retryButton.click();

    activeStage = 'retry result server action semantics';
    await waitForSemanticText(page, 'Connect securely', 30000);
    activeStage = 'retry result server URL field semantics';
    await page.locator('input[aria-label*="Server URL"]').waitFor({
      state: 'visible',
      timeout: 15000,
    });
    authFlowVisible = true;

    // The selected implementation arrives via the Flutter console marker.
    // Give the app a short settle interval, then assert only allowlisted names.
    const markerDeadline = Date.now() + 10000;
    while (!implementationMarkers.length && Date.now() < markerDeadline) {
      await page.waitForTimeout(100);
    }
    assertThat(implementationMarkers.length > 0, 'retry did not open a safe persistent backend');
    assertThat(implementationMarkers.every((value) => SAFE_IMPLEMENTATIONS.has(value)),
      'retry selected a storage backend outside the safe persistent allowlist');
    assertThat(authFlowVisible, 'retry did not enter the server authentication flow');
    assertThat(apiRequests.length === 0, 'startup recovery unexpectedly called an application API');
    assertThat(pageErrorCategories.length === 0, 'browser reported an uncaught application error');

    console.log('WEB-STORAGE-RECOVERY passed', JSON.stringify({
      unsupportedStorageRecovery: recoveryScreenVisible,
      secureStorageExplanation: true,
      persistentStateRechecked: storageProbe.persistedCalls >= 2,
      storageEstimateVisible: true,
      persistentRequestCalls: storageProbe.persistCalls,
      accessibleRetry: retryVisible,
      liveRegion: recoveryLiveRegionAccessible,
      databaseOpenBeforeRetry: false,
      apiRequestsBeforeAndAfterRetry: apiRequests.length,
      restoredNativeSharedWorker: nativeConstructorRestored,
      selectedSafeBackends: [...new Set(implementationMarkers)],
      authFlowAfterRetry: authFlowVisible,
      uncaughtPageErrors: pageErrorCategories.length,
    }));
  } catch (error) {
    console.error('WEB-STORAGE-RECOVERY failed at', activeStage, `(${error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error'})`);
    const domSummary = page ? await page.evaluate(() => {
      const bodyText = document.body.innerText || '';
      const semanticsText = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const visibleText = `${bodyText}\n${semanticsText}`;
      const roleCounts = {};
      for (const element of document.querySelectorAll('flt-semantics')) {
        const role = element.getAttribute('role') || 'unlabeled';
        roleCounts[role] = (roleCounts[role] || 0) + 1;
      }
      return {
        path: location.pathname,
        documentReady: document.readyState,
        bodyTextLength: bodyText.length,
        hasInitialLoader: bodyText.includes('Starting Atermius'),
        flutterViewCount: document.querySelectorAll('flutter-view').length,
        semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
        roleCounts,
        liveRegionCount: document.querySelectorAll('[aria-live]').length,
        liveRegions: [...document.querySelectorAll('[aria-live]')].map((element) => ({
          value: element.getAttribute('aria-live'),
          text: `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`.trim(),
          visible: (() => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          })(),
        })),
        storageTitlePresent: visibleText.includes('需要受支持的浏览器存储'),
        genericStartupErrorPresent: visibleText.includes('无法初始化安全工作区'),
        startupProgressPresent: visibleText.includes('正在准备安全工作区'),
        retryPresent: visibleText.includes('重试'),
        authServerHeadingPresent: visibleText.includes('Connect to your server'),
        authServerActionPresent: visibleText.includes('Connect securely'),
        authLoginHeadingPresent: visibleText.includes('Unlock your workspace'),
      };
    }).catch(() => ({ evaluationFailed: true })) : { pageCreated: false };
    console.error(JSON.stringify({
      recoveryScreenVisible,
      recoveryLiveRegionAccessible,
      initialLiveRegions,
      retryVisible,
      nativeConstructorRestored,
      authFlowVisible,
      apiRequestCount: apiRequests.length,
      databaseOpenMarkerCount: implementationMarkers.length,
      pageErrorCategories,
      browserSignalCategories,
      domSummary,
      selectedBackends: implementationMarkers.filter((value) => SAFE_IMPLEMENTATIONS.has(value)),
    }));
    process.exitCode = 1;
  } finally {
    let cleanupFailed = false;
    if (context) await context.close().catch(() => { cleanupFailed = true; });
    if (browser) await browser.close().catch(() => { cleanupFailed = true; });
    await stopServer(serverProcess).catch(() => { cleanupFailed = true; });
    if (serverProcess && serverProcess.exitCode === null && serverProcess.signalCode === null) {
      cleanupFailed = true;
    }
    if (serverLogFd !== undefined) {
      try { fs.closeSync(serverLogFd); } catch (_) { cleanupFailed = true; }
    }
    if (tempRoot) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch (_) { cleanupFailed = true; }
      if (fs.existsSync(tempRoot)) cleanupFailed = true;
    }
    if (cleanupFailed) {
      console.error('WEB-STORAGE-RECOVERY cleanup incomplete');
      process.exitCode = 1;
    }
    // No credentials or persistent browser profile are created by this test.
  }
}

main().catch(() => {
  console.error('WEB-STORAGE-RECOVERY failed during harness setup (Error)');
  process.exitCode = 1;
});
