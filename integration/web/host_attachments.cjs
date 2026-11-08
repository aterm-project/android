/*
 * WEB-ATTACH-01: exercise client-side encrypted Host attachment upload and
 * download continuation across page reloads through the compiled Flutter Web
 * UI and an isolated local server.
 *
 * The synthetic file, browser profile, SQLite database, and server are private
 * to this run and removed during bounded cleanup. Diagnostics intentionally
 * contain only stage names, error classes, counts, and boolean assertions.
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
const SQLITE = process.env.SQLITE3_PATH || 'sqlite3';
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const ATTACHMENT_SCENARIO = process.env.ATERMIUS_WEB_ATTACHMENT_UPLOAD_SCENARIO ||
  (process.argv.includes('--save-picker') ? 'save-picker' : 'ack-loss');
const SAVE_PICKER_SCENARIO = ATTACHMENT_SCENARIO === 'save-picker';
const UPLOAD_RESERVATION_EXPIRED = ATTACHMENT_SCENARIO === 'expired';
const FORCE_CHROMIUM_PROCESS_KILL = ATTACHMENT_SCENARIO === 'process-kill';
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-attachment-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `AttachE2e${crypto.randomBytes(20).toString('hex')}9`;
const FILE_NAME = `encrypted-attachment-${RUN_ID}.bin`;
const PLAINTEXT_MARKER = Buffer.from(`synthetic-attachment-plaintext-${RUN_ID}:`);
const PLAINTEXT_FILL = crypto.randomBytes(2 * 1024 * 1024 + 73);
const PLAINTEXT = Buffer.concat([
  PLAINTEXT_MARKER,
  Buffer.from([0x00, 0x41, 0xff, 0x10, 0x7f]),
  PLAINTEXT_FILL,
]);

let activeStage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let savePickerFixturePath;
let savePickerFixtureSize;
let savePickerFixtureSha256;
let serverProcess;
let browserContext;
let trustedBrowserContext;
let recoverySetupPage;
let cleanupPromise;
let cleanupFailure;
let bootstrapToken;
let objectDownloadSegments = [];
let objectDownload;
let recoverySetupPhase = 'not-started';
const recoverySetupApiObservations = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(stage) {
  activeStage = stage;
  console.log(`stage: ${stage}`);
}

function runQuietly(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error(options.failureMessage || 'required local command failed');
  }
  return result.stdout || '';
}

function createBoundedSyntheticFile(filePath, size, marker) {
  const block = crypto.randomBytes(1024 * 1024);
  marker.copy(block, 0, 0, Math.min(marker.length, block.length));
  const sentinelOffset = Math.min(marker.length, block.length - 5);
  Buffer.from([0x00, 0x41, 0xff, 0x10, 0x7f]).copy(block, sentinelOffset);
  const descriptor = fs.openSync(filePath, 'wx', 0o600);
  try {
    for (let offset = 0; offset < size;) {
      const length = Math.min(block.length, size - offset);
      const written = fs.writeSync(descriptor, block, 0, length, offset);
      if (written !== length) throw new Error('synthetic fixture write was incomplete');
      offset += written;
    }
  } finally {
    fs.closeSync(descriptor);
    block.fill(0);
  }
}

function digestFile(filePath) {
  return new Promise((resolve, reject) => {
    const digest = crypto.createHash('sha256');
    const input = fs.createReadStream(filePath);
    input.on('data', (chunk) => digest.update(chunk));
    input.once('error', reject);
    input.once('end', () => resolve(digest.digest('hex')));
  });
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
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Keep polling while the private local server is starting.
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
      const state = fields[0];
      const processGroup = Number(fields[2]);
      if (processGroup === groupId && state !== 'Z' && state !== 'X') return true;
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
    if (error.code !== 'ESRCH') throw new Error('could not stop isolated server process group');
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
  throw new Error('isolated server process group did not exit after bounded cleanup');
}

function chromiumProfileProcessGroup(profileDir) {
  if (!fs.existsSync('/proc')) {
    throw new Error('forced Chromium recovery acceptance requires Linux /proc process metadata');
  }
  const expectedArg = `--user-data-dir=${profileDir}`;
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
      matches.push({ pid: Number(entry), processGroup: Number(fields[2]) });
    } catch (_) {
      // Process exited while the isolated Chromium process table was scanned.
    }
  }
  if (matches.length !== 1 || matches[0].processGroup !== matches[0].pid) {
    throw new Error('could not uniquely identify the isolated Chromium process group');
  }
  return matches[0].processGroup;
}

async function forceKillChromiumProfile(profileDir) {
  const groupId = chromiumProfileProcessGroup(profileDir);
  signalProcessGroup(groupId, 'SIGKILL');
  if (!await waitForProcessGroupExit(groupId, 5000)) {
    throw new Error('isolated Chromium process group survived forced termination');
  }
  return groupId;
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    try {
      if (browserContext) await browserContext.close().catch(() => {});
      if (trustedBrowserContext) await trustedBrowserContext.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailure = true;
    } finally {
      if (tempRoot) {
        try {
          fs.rmSync(tempRoot, { recursive: true, force: true });
        } catch (_) {
          cleanupFailure = true;
        }
      }
      PLAINTEXT.fill(0);
      PLAINTEXT_MARKER.fill(0);
      PLAINTEXT_FILL.fill(0);
      for (const segment of objectDownloadSegments) segment.bytes.fill(0);
      objectDownloadSegments = [];
      if (objectDownload?.bytes) objectDownload.bytes.fill(0);
      objectDownload = undefined;
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

function hasCanonicalUuid(value) {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}

function apiPath(request) {
  try {
    return new URL(request.url()).pathname;
  } catch (_) {
    return '';
  }
}

async function waitForText(page, text, timeoutMs = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible',
    timeout: timeoutMs,
  });
}

async function waitForSemanticText(page, text, timeoutMs = 20000) {
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
  throw new Error('expected text was not exposed by Web semantics');
}

function allowlistedApiPath(request) {
  const requestPath = apiPath(request);
  const exactPaths = new Set([
    '/api/v1/auth/prelogin',
    '/api/v1/auth/login',
    '/api/v1/devices',
  ]);
  if (exactPaths.has(requestPath)) return requestPath;
  if (/^\/api\/v1\/vaults\/[^/]+\/devices$/.test(requestPath)) {
    return '/api/v1/vaults/{id}/devices';
  }
  if (/^\/api\/v1\/vaults\/[^/]+\/membership$/.test(requestPath)) {
    return '/api/v1/vaults/{id}/membership';
  }
  if (/^\/api\/v1\/devices\/[^/]+\/revoke$/.test(requestPath)) {
    return '/api/v1/devices/{id}/revoke';
  }
  if (requestPath.startsWith('/api/')) return '/api/{other}';
  return null;
}

async function safeRecoveryPageSummary(targetPage) {
  if (!targetPage || targetPage.isClosed()) {
    return { available: false, closed: true };
  }
  return targetPage.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const textOf = (element) =>
      `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
        .replace(/\s+/g, ' ').trim().toLowerCase();
    const semantics = [...document.querySelectorAll('flt-semantics')];
    const visibleSemantics = semantics.filter(visible);
    const roleCounts = {};
    for (const element of visibleSemantics) {
      const role = element.getAttribute('role') || 'unlabeled';
      roleCounts[role] = (roleCounts[role] || 0) + 1;
    }
    const buttons = visibleSemantics
      .filter((element) => element.getAttribute('role') === 'button')
      .map(textOf);
    const inputs = [...document.querySelectorAll('input, textarea')]
      .filter(visible)
      .map((element) => ({
        type: element.getAttribute('type') || element.tagName.toLowerCase(),
        label: (element.getAttribute('aria-label') || '').toLowerCase(),
      }));
    const hasButton = (label) => buttons.some((text) => text.includes(label));
    const hasInput = (label) => inputs.some((input) => input.label.includes(label));
    return {
      documentReady: document.readyState === 'complete' || document.readyState === 'interactive',
      sodiumPresent: Boolean(window.sodium),
      sodiumReadyThenable: typeof window.sodium?.ready?.then === 'function',
      flutterRunAppCompleted: window.__e2eFlutterProbe?.runAppCompleted === true,
      semanticsPlaceholderPresent: Boolean(document.querySelector('flt-semantics-placeholder')),
      semanticsNodeCount: semantics.length,
      visibleSemanticsNodeCount: visibleSemantics.length,
      roleCounts,
      visibleButtonCount: buttons.length,
      visibleInputCount: inputs.length,
      ui: {
        connectSecurely: hasButton('connect securely'),
        addThisDevice: hasButton('add this device'),
        generateRequest: hasButton('generate request'),
        approveAndSealKeys: hasButton('approve & seal keys'),
        importApproval: hasButton('import approval'),
        importDeviceKeys: hasButton('import device keys'),
        signInAndUnlock: hasButton('sign in and unlock'),
        emailOrUsername: hasInput('email or username'),
        accountEmail: hasInput('account email'),
        deviceName: hasInput('device name'),
        enrollmentJson: hasInput('copy this enrollment json'),
        approvalJson: hasInput('paste approval json'),
        masterPassword: hasInput('master password'),
      },
    };
  }).catch(() => ({ available: false, evaluationFailed: true }));
}

function captureRecoverySetupApi(targetPage, profile) {
  targetPage.on('response', (response) => {
    const request = response.request();
    const path = allowlistedApiPath(request);
    if (!path) return;
    void (async () => {
      let errorCode = null;
      if (response.status() >= 400) {
        try {
          const body = await response.json();
          const code = body?.error?.code || body?.code;
          errorCode = typeof code === 'string' && /^[A-Z0-9_]{1,64}$/.test(code)
            ? code : 'UNCLASSIFIED_API_ERROR';
        } catch (_) {
          errorCode = 'NON_JSON_API_ERROR';
        }
      }
      recoverySetupApiObservations.push({
        profile,
        method: request.method(),
        path,
        status: response.status(),
        errorCode,
      });
      if (recoverySetupApiObservations.length > 40) {
        recoverySetupApiObservations.splice(0,
          recoverySetupApiObservations.length - 40);
      }
    })().catch(() => {});
  });
  targetPage.on('requestfailed', (request) => {
    const path = allowlistedApiPath(request);
    if (!path) return;
    recoverySetupApiObservations.push({
      profile,
      method: request.method(),
      path,
      status: null,
      errorCode: 'REQUEST_FAILED',
    });
    if (recoverySetupApiObservations.length > 40) {
      recoverySetupApiObservations.splice(0,
        recoverySetupApiObservations.length - 40);
    }
  });
}

async function field(page, label, onPhase = null) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
  onPhase?.(`wait for ${label} field`);
  await selectServerModeIfChooser(page, locator);
  onPhase?.(`wait for visible ${label} field`);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function button(page, label, onPhase = null) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  onPhase?.(`wait for ${label} button`);
  await selectServerModeIfChooser(page, locator);
  onPhase?.(`wait for visible ${label} button`);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function click(page, label, onPhase = null) {
  const target = await button(page, label, onPhase);
  onPhase?.(`click ${label} button`);
  await target.click();
}

async function fill(page, label, value, onPhase = null) {
  const locator = await field(page, label, onPhase);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    onPhase?.(`focus ${label} field`);
    await locator.click();
    onPhase?.(`select ${label} field contents`);
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    onPhase?.(`enter ${label} field contents`);
    await locator.pressSequentially(value, { delay: 60 });
    await page.waitForTimeout(200);
    if (await locator.inputValue() === value) {
      onPhase?.(`commit ${label} field contents`);
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('a visible Web form field did not retain its input');
}

async function paste(page, label, value, onPhase = null) {
  onPhase?.(`write clipboard for ${label}`);
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label, onPhase);
  onPhase?.(`focus ${label} field for paste`);
  await locator.click();
  onPhase?.(`select ${label} field contents for paste`);
  await locator.press('Control+A');
  onPhase?.(`paste ${label} field contents`);
  await locator.press('Control+V');
  await page.waitForTimeout(200);
  if (await locator.inputValue().catch(() => '') !== value) {
    await fill(page, label, value, onPhase);
  }
  assertThat(await locator.inputValue() === value,
    'clipboard or fallback paste did not populate the requested enrollment field');
}

async function readClipboard(page, onPhase = null) {
  onPhase?.('read clipboard contents');
  return page.evaluate(() => navigator.clipboard.readText());
}

async function approveEnrollment(page, enrollmentJson, onPhase = null) {
  await click(page, 'Devices', onPhase);
  await click(page, 'Approve enrollment', onPhase);
  await paste(page, 'Enrollment JSON', enrollmentJson, onPhase);
  await click(page, 'Review keys', onPhase);
  await click(page, 'Approve & seal keys', onPhase);
  await button(page, 'Copy', onPhase);
  await click(page, 'Copy', onPhase);
  const approvalJson = await readClipboard(page, onPhase);
  assertThat(approvalJson.includes('atermius-device-approval-v1'),
    'trusted recovery device did not create a valid device approval');
  await click(page, 'Done', onPhase);
  await click(page, 'Hosts', onPhase);
  return approvalJson;
}

async function requestDeviceEnrollment(page, deviceName, onPhase = null) {
  await field(page, 'Email or username', onPhase);
  await click(page, 'Add this device', onPhase);
  onPhase?.('wait for Request this device form');
  await waitForText(page, 'Request this device');
  await fill(page, 'Account email', USERNAME, onPhase);
  await fill(page, 'Device name', deviceName, onPhase);
  await click(page, 'Generate request', onPhase);
  await field(page, 'Copy this enrollment JSON', onPhase);
  await click(page, 'Copy', onPhase);
  const enrollmentJson = await readClipboard(page, onPhase);
  let format;
  try { format = JSON.parse(enrollmentJson).format; } catch (_) {}
  assertThat(format === 'atermius-device-enrollment-v1',
    'recovery browser did not create a valid device enrollment request');
  await click(page, 'Close', onPhase);
  return enrollmentJson;
}

async function importDeviceApprovalAndSignIn(page, approvalJson, onPhase = null) {
  await click(page, 'Import approval', onPhase);
  await paste(page, 'Paste approval JSON', approvalJson, onPhase);
  await click(page, 'Import device keys', onPhase);
  await fill(page, 'Email or username', USERNAME, onPhase);
  await fill(page, 'Master password', MASTER_PASSWORD, onPhase);
  await click(page, 'Sign in and unlock', onPhase);
  onPhase?.('wait for trusted workspace');
  await waitWorkspace(page);
}

async function browserDatabaseStorage(page) {
  return page.evaluate(async () => {
    const databases = typeof indexedDB.databases === 'function'
      ? await indexedDB.databases()
      : [];
    const opfsFiles = [];
    if (navigator.storage?.getDirectory) {
      const root = await navigator.storage.getDirectory();
      const visit = async (directory, prefix, depth) => {
        for await (const [name, handle] of directory.entries()) {
          const relativePath = prefix ? `${prefix}/${name}` : name;
          if (!/journal/i.test(relativePath)) opfsFiles.push(`${handle.kind}:${relativePath}`);
          if (handle.kind === 'directory' && depth < 4) {
            await visit(handle, relativePath, depth + 1);
          }
        }
      };
      await visit(root, '', 0);
    }
    return {
      indexedDbNames: databases.map((database) => database.name || '').sort(),
      opfsEntries: opfsFiles.sort(),
    };
  });
}

function assertBrowserDatabaseStorageSurvived(before, after, description) {
  const opfsDatabasePresent = before?.opfsEntries?.some((entry) =>
    entry.includes('atermius_vault')) === true;
  const indexedDbDatabasePresent = before?.indexedDbNames?.includes('atermius_vault') === true;
  const backend = opfsDatabasePresent ? 'OPFS' :
    indexedDbDatabasePresent ? 'IndexedDB' : 'unknown';
  const opfsStable = backend === 'OPFS' &&
    JSON.stringify(before.opfsEntries) === JSON.stringify(after?.opfsEntries) &&
    after?.opfsEntries?.some((entry) => entry.includes('atermius_vault')) === true;
  const indexedDbStable = backend === 'IndexedDB' &&
    JSON.stringify(before.indexedDbNames) === JSON.stringify(after?.indexedDbNames) &&
    after?.indexedDbNames?.includes('atermius_vault') === true;
  console.log('browser database persistence evidence', JSON.stringify({
    description,
    backend,
    indexedDbNameCount: before?.indexedDbNames?.length || 0,
    indexedDbNamesStable: indexedDbStable,
    opfsEntryCount: before?.opfsEntries?.length || 0,
    opfsEntriesStable: opfsStable,
    persistentStoreStable: indexedDbStable || opfsStable,
  }));
  assertThat(backend !== 'unknown' && (indexedDbStable || opfsStable),
  `${description} did not preserve the same browser database storage entries`);
  return backend;
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function connect(page, baseUrl, onPhase = null) {
  await fill(page, 'Server URL', baseUrl, onPhase);
  await click(page, 'Connect securely', onPhase);
}

async function syncNow(page) {
  const syncButton = page.getByRole('button', { name: /^(Idle|Pending|\d+ pending)$/ }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 20000 });
  await syncButton.click();
  // Idle is the truthful terminal status once the encrypted outbox is empty.
  await page.getByRole('button', { name: 'Idle', exact: true }).waitFor({
    state: 'visible',
    timeout: 30000,
  });
}

async function addHost(page, hostName) {
  setStage('Host editor opening');
  await click(page, 'Add host');
  await waitForText(page, 'Add a host');
  setStage('Host form data entry');
  await fill(page, 'Display name', hostName);
  await fill(page, 'Hostname or IP', '198.51.100.77');
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'attachment-e2e');
  setStage('Host form submission');
  await click(page, 'Save encrypted host');
  setStage('Host card visibility');
  await hostCard(page, hostName).first().waitFor({
    state: 'visible',
    timeout: 15000,
  });
}

function hostCard(page, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('group', { name: new RegExp(escaped) });
}

async function installFlutterLoaderProbe(context) {
  await context.addInitScript(() => {
    window.__e2eFlutterProbe = {
      initializerCalled: false,
      engineInitialized: false,
      runAppCompleted: false,
      error: false,
    };
    const flutter = {};
    let loader;
    Object.defineProperty(window, '_flutter', {
      configurable: true,
      get: () => flutter,
      set: (value) => { if (value && typeof value === 'object') Object.assign(flutter, value); },
    });
    Object.defineProperty(flutter, 'loader', {
      configurable: true,
      get: () => loader,
      set: (value) => {
        loader = value;
        let original;
        Object.defineProperty(loader, 'didCreateEngineInitializer', {
          configurable: true,
          get: () => original,
          set: (callback) => {
            original = function (engineInitializer) {
              window.__e2eFlutterProbe.initializerCalled = true;
              if (typeof engineInitializer?.initializeEngine === 'function') {
                const initializeEngine = engineInitializer.initializeEngine.bind(engineInitializer);
                engineInitializer.initializeEngine = (...args) => initializeEngine(...args).then((runner) => {
                  window.__e2eFlutterProbe.engineInitialized = true;
                  const runApp = runner.runApp.bind(runner);
                  runner.runApp = (...runArgs) => Promise.resolve(runApp(...runArgs)).then((result) => {
                    window.__e2eFlutterProbe.runAppCompleted = true;
                    return result;
                  }, (error) => {
                    window.__e2eFlutterProbe.error = true;
                    throw error;
                  });
                  return runner;
                });
              }
              return callback(engineInitializer);
            };
          },
        });
      },
    });
  });
}

async function enableFlutterSemantics(page, assetResponses, requestFailureCount) {
  const deadline = Date.now() + 60000;
  let startup = null;
  while (Date.now() < deadline) {
    startup = await page.evaluate(async () => {
      const sodium = window.sodium;
      let sodiumReady = false;
      if (typeof sodium?.ready?.then === 'function') {
        sodiumReady = await Promise.race([
          sodium.ready.then(() => true, () => false),
          new Promise((resolve) => setTimeout(() => resolve(false), 100)),
        ]);
      }
      const probe = window.__e2eFlutterProbe || {};
      return {
        readyState: document.readyState,
        sodiumPresent: Boolean(sodium),
        sodiumReadyThenable: typeof sodium?.ready?.then === 'function',
        sodiumReady,
        initializerCalled: probe.initializerCalled === true,
        engineInitialized: probe.engineInitialized === true,
        runAppCompleted: probe.runAppCompleted === true,
        flutterError: probe.error === true,
        semanticsPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
        semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      };
    }).catch(() => ({ evaluateError: true }));
    if (startup.sodiumReady && startup.runAppCompleted && startup.semanticsPlaceholder) break;
    await page.waitForTimeout(100);
  }
  if (!startup?.sodiumReady || !startup?.runAppCompleted || !startup?.semanticsPlaceholder) {
    console.log('Flutter startup readiness diagnostic', JSON.stringify({
      startup,
      assets: assetResponses.slice(-20),
      requestFailureCount,
    }));
    throw new Error('Flutter Web startup readiness timed out');
  }
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  const semanticsDeadline = Date.now() + 15000;
  while (Date.now() < semanticsDeadline) {
    const hasSemantics = await page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0);
    if (hasSemantics) {
      return;
    }
    await page.waitForTimeout(100);
  }
  console.log('Flutter semantics diagnostic', JSON.stringify({
    semanticsNodeCount: await page.evaluate(() => document.querySelectorAll('flt-semantics').length),
    assets: assetResponses.slice(-20),
    requestFailureCount,
  }));
  throw new Error('Flutter Web semantics tree did not appear');
}

function quoteUuid(value) {
  if (!hasCanonicalUuid(value)) throw new Error('Web client exposed a noncanonical identifier');
  return `'${value}'`;
}

function sqliteScalar(sql) {
  const result = spawnSync(SQLITE, ['-batch', '-noheader', databasePath, sql], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated SQLite evidence query failed');
  }
  const value = Number((result.stdout || '').trim());
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error('isolated SQLite evidence query returned no scalar count');
  }
  return value;
}

function currentRevisionReferenceCount(recordId, revisionId, objectId) {
  const sql = `SELECT COUNT(*) FROM record_heads h
    JOIN object_references r
      ON r.vault_id=h.vault_id AND r.revision_id=h.revision_id
    WHERE h.record_id=${quoteUuid(recordId)}
      AND h.revision_id=${quoteUuid(revisionId)}
      AND h.deleted=0 AND r.object_id=${quoteUuid(objectId)}`;
  return sqliteScalar(sql);
}

function storedObjectCount(objectId) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM blob_objects WHERE object_id=${quoteUuid(objectId)}`,
  );
}

function completedObjectReceiptCount(objectId, size, sha256) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM blob_objects WHERE object_id=${quoteUuid(objectId)} ` +
      `AND size=${size} AND sha256='${sha256}'`,
  );
}

function completedUploadCount(uploadId) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM uploads WHERE upload_id=${quoteUuid(uploadId)} AND state='completed'`,
  );
}

function objectReferenceCount(objectId) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM object_references WHERE object_id=${quoteUuid(objectId)}`,
  );
}

function openUploadCount(uploadId, objectId, size, sha256) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM uploads WHERE upload_id=${quoteUuid(uploadId)} ` +
      `AND object_id=${quoteUuid(objectId)} AND expected_size=${size} ` +
      `AND expected_sha256='${sha256}' AND chunk_size=1048576 AND state='open'`,
  );
}

function expiredUploadCount(uploadId) {
  return sqliteScalar(
    `SELECT COUNT(*) FROM uploads WHERE upload_id=${quoteUuid(uploadId)} AND state='expired'`,
  );
}

function uploadReservationExpiry(uploadId) {
  const result = spawnSync(SQLITE, [
    '-batch', '-noheader', databasePath,
    `SELECT expires_at FROM uploads WHERE upload_id=${quoteUuid(uploadId)}`,
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated SQLite upload expiry query failed');
  }
  return (result.stdout || '').trim();
}

function expireUploadReservation(uploadId) {
  const result = spawnSync(SQLITE, [
    '-batch', '-noheader', databasePath,
    `UPDATE uploads SET expires_at='2000-01-01T00:00:00+00:00' ` +
      `WHERE upload_id=${quoteUuid(uploadId)} AND state='open' RETURNING upload_id`,
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0 || (result.stdout || '').trim() !== uploadId) {
    throw new Error('isolated upload reservation could not be expired at the test boundary');
  }
}

function uploadChunkRows(uploadId) {
  const result = spawnSync(SQLITE, [
    '-batch', '-noheader', '-separator', '|', databasePath,
    `SELECT chunk_index,length(bytes),sha256 FROM upload_chunks WHERE upload_id=${quoteUuid(uploadId)} ORDER BY chunk_index`,
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated SQLite upload chunk receipt query failed');
  }
  return (result.stdout || '').trim().split(/\s+/).filter(Boolean).map((line) => {
    const [index, size, sha256] = line.split('|');
    return { index: Number(index), size: Number(size), sha256 };
  });
}

function uploadChunkIndexes(uploadId) {
  const result = spawnSync(SQLITE, [
    '-batch', '-noheader', databasePath,
    `SELECT chunk_index FROM upload_chunks WHERE upload_id=${quoteUuid(uploadId)} ORDER BY chunk_index`,
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated SQLite upload chunk evidence query failed');
  }
  return (result.stdout || '').trim().split(/\s+/).filter(Boolean).map(Number);
}

function currentRevisionWithoutReferenceCount(recordId, revisionId, objectId) {
  const sql = `SELECT COUNT(*) FROM record_heads h
    WHERE h.record_id=${quoteUuid(recordId)}
      AND h.revision_id=${quoteUuid(revisionId)}
      AND h.deleted=0
      AND NOT EXISTS (
        SELECT 1 FROM object_references r
        WHERE r.vault_id=h.vault_id AND r.revision_id=h.revision_id
          AND r.object_id=${quoteUuid(objectId)}
      )`;
  return sqliteScalar(sql);
}

function databaseFiles() {
  if (!dataDir || !fs.existsSync(dataDir)) return [];
  return fs.readdirSync(dataDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(dataDir, entry.name));
}

function databaseContains(bytes) {
  const files = databaseFiles();
  assertThat(files.some((file) => file === databasePath), 'isolated SQLite database was not created');
  return files.some((file) => fs.readFileSync(file).includes(bytes));
}

async function waitFor(predicate, message, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}

function waitForDownload(context, page, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const observedPages = new Map();
    let timer;
    const finish = (error, download) => {
      if (timer) clearTimeout(timer);
      context.off('page', observe);
      context.off('close', onContextClose);
      for (const [candidate, handler] of observedPages) {
        candidate.off('download', handler);
      }
      observedPages.clear();
      if (error) reject(error);
      else resolve(download);
    };
    const observe = (candidate) => {
      if (observedPages.has(candidate)) return;
      const handler = (download) => finish(null, download);
      observedPages.set(candidate, handler);
      candidate.on('download', handler);
    };
    const onContextClose = () => finish(new Error('Browser context closed before download'));
    observe(page);
    context.on('page', observe);
    context.on('close', onContextClose);
    timer = setTimeout(() => {
      let pages = [];
      try { pages = context.pages(); } catch (_) {}
      console.log('browser download timeout diagnostic', JSON.stringify({
        pageCount: pages.length,
        originalPageClosed: page.isClosed(),
        pageProtocols: pages.map((candidate) => {
          try { return new URL(candidate.url()).protocol; } catch (_) { return 'invalid'; }
        }),
      }));
      finish(new Error('UI did not produce a browser download'));
    }, timeoutMs);
  });
}

function assembleObjectDownload(segments, expectedSize, expectedSha256) {
  assertThat(Number.isSafeInteger(expectedSize) && expectedSize > 0,
    'encrypted object upload did not expose its expected byte length');
  assertThat(typeof expectedSha256 === 'string' && /^[0-9a-f]{64}$/.test(expectedSha256),
    'encrypted object upload did not expose its expected ciphertext digest');
  assertThat(segments.length > 0, 'UI download did not produce an object range response');

  const expectedEtag = `"sha256-${expectedSha256}"`;
  const parsed = segments.map((segment) => {
    assertThat(segment.status === 206, 'object download did not use HTTP partial-content responses');
    const requested = /^bytes=(\d+)-(\d+)$/.exec(segment.requestRange || '');
    const returned = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(segment.contentRange || '');
    const contentLength = /^\d+$/.test(segment.contentLength || '')
      ? Number(segment.contentLength)
      : NaN;
    assertThat(requested && returned, 'object range request or Content-Range header was invalid');
    const start = Number(returned[1]);
    const end = Number(returned[2]);
    const total = Number(returned[3]);
    const requestedStart = Number(requested[1]);
    const requestedEnd = Number(requested[2]);
    const byteLength = segment.bytes.length;
    assertThat(Number.isSafeInteger(start) && Number.isSafeInteger(end) &&
      Number.isSafeInteger(total) && total === expectedSize &&
      start === requestedStart && end === requestedEnd && end >= start &&
      end < total && byteLength === end - start + 1 && contentLength === byteLength,
    'object range headers and ciphertext segment length were inconsistent');
    assertThat(segment.etag === expectedEtag && segment.ifRange === expectedEtag,
      'object range ETag or If-Range did not match the uploaded ciphertext digest');
    return { ...segment, start, end, total, byteLength };
  }).sort((left, right) => left.start - right.start || left.end - right.end);

  const coverage = [];
  let nextOffset = 0;
  for (const segment of parsed) {
    const previous = coverage.at(-1);
    if (previous && segment.start === previous.start && segment.end === previous.end) {
      assertThat(segment.bytes.equals(previous.bytes),
        'repeated object range returned different ciphertext bytes');
      continue;
    }
    assertThat(segment.start === nextOffset,
      'object range responses contained a gap or overlap');
    coverage.push(segment);
    nextOffset = segment.end + 1;
  }
  assertThat(nextOffset === expectedSize,
    'object range responses did not cover the complete ciphertext object');
  const bytes = Buffer.concat(coverage.map((segment) => segment.bytes));
  assertThat(bytes.length === expectedSize &&
    crypto.createHash('sha256').update(bytes).digest('hex') === expectedSha256,
  'assembled object ranges did not match the uploaded ciphertext size and digest');
  return {
    bytes,
    rangeCount: parsed.length,
    uniqueRangeCount: coverage.length,
    metadata: parsed.map((segment) => ({
      phase: segment.phase,
      requestRange: segment.requestRange,
      ifRange: segment.ifRange,
      status: segment.status,
      etag: segment.etag,
      contentRange: segment.contentRange,
      contentLength: segment.contentLength,
      byteLength: segment.byteLength,
    })),
  };
}

async function main() {
  assertThat(['ack-loss', 'expired', 'process-kill', 'save-picker'].includes(ATTACHMENT_SCENARIO),
    'unsupported Host attachment acceptance scenario');
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }
  runQuietly('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    failureMessage: 'isolated Rust server build failed',
  });
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated Rust server binary is missing');
  runQuietly(SQLITE, ['--version'], { timeout: 5000, failureMessage: 'sqlite3 CLI is unavailable' });

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-attachments-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'sqlite-data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  const chromiumProfileDir = path.join(tempRoot, 'chromium-profile');
  const trustedProfileDir = path.join(tempRoot, 'trusted-chromium-profile');
  fs.mkdirSync(chromiumProfileDir, { recursive: true, mode: 0o700 });
  if (SAVE_PICKER_SCENARIO) {
    savePickerFixtureSize = 256 * 1024 * 1024 + 1;
    savePickerFixturePath = path.join(tempRoot, FILE_NAME);
    createBoundedSyntheticFile(savePickerFixturePath, savePickerFixtureSize, PLAINTEXT_MARKER);
    savePickerFixtureSha256 = await digestFile(savePickerFixturePath);
  }
  if (FORCE_CHROMIUM_PROCESS_KILL) {
    fs.mkdirSync(trustedProfileDir, { recursive: true, mode: 0o700 });
  }
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

  let initRequestCount = 0;
  let successfulChunkCount = 0;
  let successfulUploadCompletionCount = 0;
  let completedObjectId;
  let uploadedObjectId;
  let uploadedObjectSize;
  let uploadedObjectSha256;
  let completedObjectSize;
  let completedObjectSha256;
  let hostRecordId;
  let attachmentRevisionId;
  let removalRevisionId;
  let uploadedChunkRequestCount = 0;
  let uploadCapturePhase = 'off';
  let uploadInterrupted = false;
  let interruptedUploadId;
  const uploadChunkRequests = [];
  const uploadChunkResponses = [];
  const uploadReservations = [];
  const uploadObjectDeclarations = [];
  const completedObjectReceipts = [];
  let attachmentObjectRefs = [];
  let droppedChunkAck;
  const successfulUploadCompletionIds = [];
  let uploadInterruptionRoute;
  let uploadInterruptionRoutePattern;
  let captureHostCreation = false;
  const knownRecordIds = new Set();
  let captureRevisionStage = 'none';
  let pageErrorCount = 0;
  let rendererCrashCount = 0;
  let captureErrorCount = 0;
  const safeApiErrorCodes = new Set();
  const uploadApiStatuses = [];
  const syncPushStatuses = [];
  const authNetworkObservations = [];
  const objectRangeRequests = [];
  let downloadCapturePhase = 'off';
  let downloadInterrupted = false;
  let downloadInterruptionRoute;
  let downloadInterruptionRoutePattern;
  const startupAssetResponses = [];
  let requestSequence = 0;
  let pickerOpenRequestSequence;
  let firstObjectGetRequestSequence;
  let objectGetStarted = 0;
  let objectGetFinished = 0;
  let objectGetFailed = 0;
  const objectGetStatuses = [];
  let savePickerWriteBytes = 0;
  let savePickerWriteCount = 0;
  let savePickerMaxWriteBytes = 0;
  const savePickerOpenEvents = [];
  const savePickerCloseEvents = [];
  let savePickerAbortCount = 0;
  const savePickerWriteDigest = crypto.createHash('sha256');
  let startupRequestFailureCount = 0;
  let page;
  const attachPageInstrumentation = (targetPage) => {
    targetPage.on('pageerror', () => { pageErrorCount += 1; });
    targetPage.on('crash', () => { rendererCrashCount += 1; });
    targetPage.on('requestfailed', (request) => {
      const requestPath = apiPath(request);
      if (SAVE_PICKER_SCENARIO && request.method() === 'GET' &&
          /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/.test(requestPath)) {
        objectGetFailed += 1;
      }
      if (/sodium|\.wasm$|flutter|main\.dart|canvaskit|sqlite|drift/i.test(apiPath(request))) {
        startupRequestFailureCount += 1;
      }
    });
    targetPage.on('requestfinished', (request) => {
      const requestPath = apiPath(request);
      if (SAVE_PICKER_SCENARIO && request.method() === 'GET' &&
          /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/.test(requestPath)) {
        objectGetFinished += 1;
      }
    });
    targetPage.on('response', (response) => {
      let resourcePath = '';
      try { resourcePath = new URL(response.url()).pathname; } catch (_) {}
      if (/sodium|\.wasm$|flutter|main\.dart|canvaskit|sqlite|drift/i.test(resourcePath)) {
        startupAssetResponses.push({
          path: resourcePath,
          status: response.status(),
          contentType: response.headers()['content-type'] || '',
        });
      }
    });

    targetPage.on('request', (request) => {
      requestSequence += 1;
      const requestPath = apiPath(request);
      if (SAVE_PICKER_SCENARIO && request.method() === 'POST' &&
          requestPath === '/__e2e/save-picker/open' && !pickerOpenRequestSequence) {
        pickerOpenRequestSequence = requestSequence;
      }
      if (SAVE_PICKER_SCENARIO && request.method() === 'GET' &&
          /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/.test(requestPath)) {
        objectGetStarted += 1;
        if (!firstObjectGetRequestSequence) firstObjectGetRequestSequence = requestSequence;
      }
      if (/\/api\/v1\/auth\/(prelogin|login)$/.test(requestPath)) {
        authNetworkObservations.push({ phase: 'request', path: requestPath });
      }
      if (request.method() === 'POST' && /\/api\/v1\/vaults\/[^/]+\/uploads\/init$/.test(requestPath)) {
        initRequestCount += 1;
        try {
          const body = request.postDataJSON();
          if (hasCanonicalUuid(body?.object_id)) {
            uploadedObjectId = body.object_id;
            uploadedObjectSize = body.size;
            uploadedObjectSha256 = body.sha256;
            uploadObjectDeclarations.push({
              objectId: body.object_id,
              size: body.size,
              sha256: body.sha256,
            });
          }
        } catch (_) {
          captureErrorCount += 1;
        }
      }
      if (request.method() === 'POST' && /\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(requestPath)) {
        try {
          const body = request.postDataJSON();
          for (const operation of body?.operations || []) {
            const header = operation?.header;
            if (!hasCanonicalUuid(header?.record_id) || !hasCanonicalUuid(header?.revision_id)) continue;
            const refs = header.object_refs;
            if (captureHostCreation && !knownRecordIds.has(header.record_id)) {
              hostRecordId = header.record_id;
              captureHostCreation = false;
            }
            knownRecordIds.add(header.record_id);
            if (header.record_id !== hostRecordId) continue;
            if (captureRevisionStage === 'attach' && uploadedObjectId && Array.isArray(refs) &&
                refs.includes(uploadedObjectId)) {
              attachmentRevisionId = header.revision_id;
              attachmentObjectRefs = refs.slice();
            }
            const hostHasNoAttachmentRefs = refs == null ||
              (Array.isArray(refs) && !refs.includes(uploadedObjectId));
            if (captureRevisionStage === 'remove' && uploadedObjectId && hostHasNoAttachmentRefs) {
              removalRevisionId = header.revision_id;
            }
          }
        } catch (_) {
          captureErrorCount += 1;
        }
      }
      if (request.method() === 'PUT' && /\/api\/v1\/uploads\/[^/]+\/chunks\/\d+$/.test(requestPath)) {
        uploadedChunkRequestCount += 1;
      }
    });

    targetPage.on('response', (response) => {
      void (async () => {
        const request = response.request();
        const requestPath = apiPath(request);
        if (SAVE_PICKER_SCENARIO && request.method() === 'GET' &&
            /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/.test(requestPath)) {
          objectGetStatuses.push(response.status());
        }
        if (/\/api\/v1\/auth\/(prelogin|login)$/.test(requestPath)) {
          authNetworkObservations.push({ phase: 'response', path: requestPath, status: response.status() });
        }
        const uploadResponsePhase = uploadCapturePhase;
        let responseErrorCode;
        if (requestPath.startsWith('/api/') && response.status() >= 400) {
          try {
            const body = await response.json();
            const code = body?.error?.code || body?.code;
            if (typeof code === 'string' && /^[A-Z0-9_]{1,64}$/.test(code)) {
              responseErrorCode = code;
              safeApiErrorCodes.add(code);
            }
          } catch (_) {
            safeApiErrorCodes.add('NON_JSON_API_ERROR');
          }
        }
        if (/\/api\/v1\/vaults\/[^/]+\/uploads\/init$/.test(requestPath)) {
          uploadApiStatuses.push(response.status());
          if (response.status() >= 200 && response.status() < 300) {
            const body = await response.json();
            if (hasCanonicalUuid(body?.upload_id)) {
              if (!hasCanonicalUuid(interruptedUploadId)) interruptedUploadId = body.upload_id;
              uploadReservations.push({
                uploadId: body.upload_id,
                chunkSize: body.chunk_size,
                expiresAt: body.expires_at,
              });
            }
          }
        }
        if (/\/api\/v1\/uploads\/[^/]+\/chunks\/\d+$/.test(requestPath)) {
          uploadApiStatuses.push(response.status());
          const match = /\/api\/v1\/uploads\/([^/]+)\/chunks\/(\d+)$/.exec(requestPath);
          if (match) {
            const body = response.status() >= 200 && response.status() < 300
              ? await response.json()
              : null;
            uploadChunkResponses.push({
              phase: uploadResponsePhase,
              uploadId: match[1],
              index: Number(match[2]),
              status: response.status(),
              errorCode: responseErrorCode,
              sha256: body?.sha256,
              alreadyUploaded: body?.already_uploaded === true,
            });
          }
        }
        if (/\/api\/v1\/uploads\/[^/]+\/complete$/.test(requestPath)) {
          uploadApiStatuses.push(response.status());
        }
        if (/\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(requestPath)) {
          syncPushStatuses.push(response.status());
        }
        if (request.method() === 'PUT' && /\/api\/v1\/uploads\/[^/]+\/chunks\/\d+$/.test(requestPath) &&
            response.status() >= 200 && response.status() < 300) {
          successfulChunkCount += 1;
        }
        if (request.method() === 'POST' && /\/api\/v1\/uploads\/[^/]+\/complete$/.test(requestPath) &&
            response.status() >= 200 && response.status() < 300) {
          successfulUploadCompletionCount += 1;
          successfulUploadCompletionIds.push(
            /\/api\/v1\/uploads\/([^/]+)\/complete$/.exec(requestPath)?.[1] || '',
          );
          const body = await response.json();
          if (hasCanonicalUuid(body?.object_id)) {
            completedObjectId = body.object_id;
            completedObjectSize = body.size;
            completedObjectSha256 = body.sha256;
            completedObjectReceipts.push({
              objectId: body.object_id,
              size: body.size,
              sha256: body.sha256,
            });
          }
        }
        if (!SAVE_PICKER_SCENARIO && request.method() === 'GET' && uploadedObjectId &&
            requestPath.endsWith(`/objects/${uploadedObjectId}`)) {
          const requestHeaders = request.headers();
          const responseHeaders = response.headers();
          objectDownloadSegments.push({
            phase: downloadCapturePhase,
            status: response.status(),
            requestRange: requestHeaders.range || '',
            ifRange: requestHeaders['if-range'] || '',
            etag: responseHeaders.etag || '',
            contentRange: responseHeaders['content-range'] || '',
            contentLength: responseHeaders['content-length'] || '',
            bytes: Buffer.from(await response.body()),
          });
        }
      })().catch(() => { captureErrorCount += 1; });
    });
  };
  const launchPersistentChromium = async () => {
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browserContext = await chromium.launchPersistentContext(chromiumProfileDir, launchOptions);
    await browserContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    await installFlutterLoaderProbe(browserContext);
    if (SAVE_PICKER_SCENARIO) {
      const savePickerEndpoint = `${baseUrl}/__e2e/save-picker`;
      await browserContext.addInitScript({ content: `(() => {
        const endpoint = ${JSON.stringify(savePickerEndpoint)};
        const state = {
          pickerCalls: 0,
          suggestedName: null,
          userActivation: false,
          writeCalls: 0,
          closeCalls: 0,
          abortCalls: 0,
          writeBytes: 0,
          maxWriteBytes: 0,
        };
        window.__atermiusSavePickerCapture = state;
        window.showSaveFilePicker = async (options) => {
          state.pickerCalls += 1;
          state.suggestedName = options?.suggestedName ?? null;
          state.userActivation = Boolean(navigator.userActivation?.isActive);
          const opened = await fetch(endpoint + '/open', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              suggestedName: state.suggestedName,
              userActivation: state.userActivation,
            }),
          });
          if (!opened.ok) throw new Error('save-picker fixture open rejected');
          return {
            createWritable: async () => ({
              write: async (chunk) => {
                let bytes;
                if (chunk instanceof Uint8Array) bytes = chunk;
                else if (chunk instanceof ArrayBuffer) bytes = new Uint8Array(chunk);
                else if (ArrayBuffer.isView(chunk)) {
                  bytes = new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
                } else {
                  throw new TypeError('unsupported save-picker byte source');
                }
                const response = await fetch(endpoint + '/write', {
                  method: 'POST',
                  body: bytes,
                });
                if (!response.ok) throw new Error('save-picker fixture write rejected');
                state.writeCalls += 1;
                state.writeBytes += bytes.byteLength;
                state.maxWriteBytes = Math.max(state.maxWriteBytes, bytes.byteLength);
              },
              close: async () => {
                state.closeCalls += 1;
                const response = await fetch(endpoint + '/close', {
                  method: 'POST',
                  headers: { 'content-type': 'application/json' },
                  body: JSON.stringify({
                    writeCalls: state.writeCalls,
                    writeBytes: state.writeBytes,
                    maxWriteBytes: state.maxWriteBytes,
                  }),
                });
                if (!response.ok) throw new Error('save-picker fixture integrity gate rejected close');
              },
              abort: async () => {
                state.abortCalls += 1;
                await fetch(endpoint + '/abort', { method: 'POST' });
              },
            }),
          };
        };
      })();` });
    }
    page = browserContext.pages()[0] || await browserContext.newPage();
    attachPageInstrumentation(page);
    return page;
  };
  const installSavePickerSinkRoute = async (targetPage) => {
    if (!SAVE_PICKER_SCENARIO) return;
    await targetPage.route(`${baseUrl}/__e2e/save-picker/**`, async (route) => {
      const pathname = apiPath(route.request());
      if (route.request().method() === 'POST' && pathname === '/__e2e/save-picker/open') {
        const body = route.request().postDataJSON();
        savePickerOpenEvents.push({
          suggestedName: body?.suggestedName,
          userActivation: body?.userActivation === true,
        });
        await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
        return;
      }
      if (route.request().method() === 'POST' && pathname === '/__e2e/save-picker/write') {
        const bytes = route.request().postDataBuffer() || Buffer.alloc(0);
        savePickerWriteDigest.update(bytes);
        savePickerWriteBytes += bytes.length;
        savePickerWriteCount += 1;
        savePickerMaxWriteBytes = Math.max(savePickerMaxWriteBytes, bytes.length);
        await route.fulfill({ status: 204, body: '' });
        return;
      }
      if (route.request().method() === 'POST' && pathname === '/__e2e/save-picker/close') {
        const body = route.request().postDataJSON();
        const deadline = Date.now() + 5000;
        while (objectGetStarted !== objectGetFinished && Date.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
        const evidence = {
          writeCalls: body?.writeCalls,
          writeBytes: body?.writeBytes,
          maxWriteBytes: body?.maxWriteBytes,
          receivedWriteCount: savePickerWriteCount,
          receivedWriteBytes: savePickerWriteBytes,
          receivedMaxWriteBytes: savePickerMaxWriteBytes,
          plaintextSha256: savePickerWriteDigest.copy().digest('hex'),
          objectGetStarted,
          objectGetFinished,
          objectGetFailed,
          objectGetStatuses: objectGetStatuses.slice(),
        };
        savePickerCloseEvents.push(evidence);
        const valid = evidence.writeCalls === savePickerWriteCount &&
          evidence.writeBytes === savePickerFixtureSize &&
          evidence.receivedWriteBytes === savePickerFixtureSize &&
          evidence.plaintextSha256 === savePickerFixtureSha256 &&
          evidence.maxWriteBytes <= 4 * 1024 * 1024 &&
          evidence.objectGetStarted > 0 &&
          evidence.objectGetStarted === evidence.objectGetFinished &&
          evidence.objectGetFailed === 0 &&
          evidence.objectGetStatuses.length === evidence.objectGetFinished &&
          evidence.objectGetStatuses.every((status) => status === 200 || status === 206);
        await route.fulfill({ status: valid ? 204 : 409, body: '' });
        return;
      }
      if (route.request().method() === 'POST' && pathname === '/__e2e/save-picker/abort') {
        savePickerAbortCount += 1;
        await route.fulfill({ status: 204, body: '' });
        return;
      }
      await route.fulfill({ status: 404, body: '' });
    });
  };
  const killAndRelaunchPersistentChromium = async () => {
    const killedProcessGroup = await forceKillChromiumProfile(chromiumProfileDir);
    // The process group is already dead. Closing the disconnected Playwright
    // context can invoke browser shutdown cleanup against the same profile,
    // which is exactly the persistence boundary this scenario is measuring.
    browserContext = undefined;
    page = undefined;
    await launchPersistentChromium();
    const relaunchedProcessGroup = chromiumProfileProcessGroup(chromiumProfileDir);
    const processGroupChanged = relaunchedProcessGroup !== killedProcessGroup;
    assertThat(processGroupChanged,
      'forced Chromium restart reused the killed browser process group');
    return {
      page,
      processGroupChanged,
      oldProcessGroupExited: true,
      newProcessGroupHasExpectedProfile: true,
      reopenedSameProfilePath: true,
    };
  };

  try {
    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
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
    assertThat(!bootstrap.error && bootstrap.status === 0, 'isolated server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
      'isolated server did not issue a bootstrap token');

    setStage('isolated Chromium launch');
    await launchPersistentChromium();
    await installSavePickerSinkRoute(page);

    setStage('Flutter Web navigation');
    const navigation = await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    assertThat(navigation && navigation.status() === 200, 'isolated Web UI did not load');
    setStage('Flutter Web startup');
    await enableFlutterSemantics(page, startupAssetResponses, startupRequestFailureCount);

    setStage('owner account registration');
    await connect(page, baseUrl);
    await field(page, 'Owner email');
    await fill(page, 'Owner email', USERNAME);
    await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(page, 'Confirm master password', MASTER_PASSWORD);
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    await fill(page, 'Device name', 'Attachment Web acceptance');
    await fill(page, 'First Vault', 'Attachment acceptance Vault');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    await waitWorkspace(page);

    let trustedPage;
    let uploadRecoveryNeedsEnrollment = false;
    let downloadRecoveryNeedsEnrollment = false;
    if (FORCE_CHROMIUM_PROCESS_KILL) {
      setStage('prepare independent trusted recovery device');
      const markRecoverySetupPhase = (phase) => {
        recoverySetupPhase = phase;
      };
      const trustedLaunchOptions = {
        headless: true,
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
        locale: 'en-US',
        viewport: { width: 1440, height: 1000 },
        acceptDownloads: true,
      };
      if (CHROMIUM_EXECUTABLE) trustedLaunchOptions.executablePath = CHROMIUM_EXECUTABLE;
      try {
        markRecoverySetupPhase('launch persistent trusted Chromium context');
        trustedBrowserContext = await chromium.launchPersistentContext(
          trustedProfileDir,
          trustedLaunchOptions,
        );
        markRecoverySetupPhase('grant trusted browser clipboard permissions');
        await trustedBrowserContext.grantPermissions(
          ['clipboard-read', 'clipboard-write'], { origin: baseUrl },
        );
        markRecoverySetupPhase('install Flutter loader probe for trusted browser');
        await installFlutterLoaderProbe(trustedBrowserContext);
        markRecoverySetupPhase('obtain trusted recovery page');
        trustedPage = trustedBrowserContext.pages()[0] || await trustedBrowserContext.newPage();
        recoverySetupPage = trustedPage;
        captureRecoverySetupApi(page, 'owner');
        captureRecoverySetupApi(trustedPage, 'trusted');
        markRecoverySetupPhase('navigate trusted recovery page');
        const trustedNavigation = await trustedPage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
        assertThat(trustedNavigation && trustedNavigation.status() === 200,
          'independent trusted recovery profile could not load the Web UI');
        markRecoverySetupPhase('wait for trusted Flutter startup and semantics');
        await enableFlutterSemantics(trustedPage, startupAssetResponses, startupRequestFailureCount);
        await connect(trustedPage, baseUrl, markRecoverySetupPhase);
        markRecoverySetupPhase('wait for trusted sign-in identity field');
        await field(trustedPage, 'Email or username', markRecoverySetupPhase);
        const trustedEnrollment = await requestDeviceEnrollment(
          trustedPage,
          'Attachment trusted recovery device',
          markRecoverySetupPhase,
        );
        const trustedApproval = await approveEnrollment(
          page,
          trustedEnrollment,
          markRecoverySetupPhase,
        );
        await importDeviceApprovalAndSignIn(
          trustedPage,
          trustedApproval,
          markRecoverySetupPhase,
        );
        markRecoverySetupPhase('confirm owner workspace after trusted approval');
        await waitWorkspace(page);
        console.log('trusted recovery device ready', JSON.stringify({
          independentPersistentProfile: true,
          approvedDeviceCanReachWorkspace: true,
        }));
      } catch (error) {
        const contextPageCount = (context) => {
          try { return context?.pages().length ?? 0; } catch (_) { return -1; }
        };
        console.log('trusted recovery setup bounded diagnostic', JSON.stringify({
          phase: recoverySetupPhase,
          errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
          ownerPage: await safeRecoveryPageSummary(page),
          trustedPage: await safeRecoveryPageSummary(trustedPage),
          api: recoverySetupApiObservations.slice(-24),
          processState: {
            serverAlive: serverProcess?.exitCode === null,
            serverExitCode: serverProcess?.exitCode ?? null,
            ownerContextOpen: Boolean(browserContext),
            ownerPageClosed: !page || page.isClosed(),
            ownerContextPageCount: contextPageCount(browserContext),
            trustedContextOpen: Boolean(trustedBrowserContext),
            trustedPageClosed: !trustedPage || trustedPage.isClosed(),
            trustedContextPageCount: contextPageCount(trustedBrowserContext),
            pageErrorCount,
            rendererCrashCount,
            startupRequestFailureCount,
          },
        }));
        throw error;
      }
    }

    setStage('post-registration sync');
    await syncNow(page);
    const hostName = `attachment-host-${RUN_ID.slice(0, 8)}`;
    setStage('Host form and save');
    captureHostCreation = true;
    await addHost(page, hostName);
    setStage('Host revision sync');
    await syncNow(page);
    setStage('Host record identifier capture');
    await waitFor(() => hasCanonicalUuid(hostRecordId), 'Host sync did not expose its opaque record identifier');

    setStage('attachment dialog opening');
    await click(page, 'Attachments');
    setStage('attachment empty-state check');
    await waitForText(page, 'No attachments saved for this host.');
    captureRevisionStage = 'attach';
    uploadInterruptionRoutePattern = '**/api/v1/uploads/*/chunks/*';
    uploadCapturePhase = 'interrupt';
    uploadInterruptionRoute = async (route) => {
      const request = route.request();
      const match = /\/api\/v1\/uploads\/([^/]+)\/chunks\/(\d+)$/.exec(apiPath(request));
      if (request.method() === 'PUT' && match) {
        const uploadId = match[1];
        const index = Number(match[2]);
        const shouldInterrupt = uploadCapturePhase === 'interrupt' &&
          index === 1 && !uploadInterrupted;
        uploadChunkRequests.push({
          phase: uploadCapturePhase,
          uploadId,
          index,
          aborted: shouldInterrupt,
          bodyBytes: request.postDataBuffer()?.length || 0,
          sha256: crypto.createHash('sha256')
            .update(request.postDataBuffer() || Buffer.alloc(0)).digest('hex'),
        });
        if (shouldInterrupt) {
          uploadInterrupted = true;
          if (!UPLOAD_RESERVATION_EXPIRED) {
            const upstream = await route.fetch();
            const upstreamBody = await upstream.json().catch(() => null);
            droppedChunkAck = {
              status: upstream.status(),
              uploadId: upstreamBody?.upload_id,
              index: upstreamBody?.index,
              sha256: upstreamBody?.sha256,
              alreadyUploaded: upstreamBody?.already_uploaded === true,
            };
          }
          await route.abort('failed');
          return;
        }
      }
      await route.continue();
    };
    if (!SAVE_PICKER_SCENARIO) {
      await page.route(uploadInterruptionRoutePattern, uploadInterruptionRoute);
    }
    setStage('FilePicker chooser event');
    const fileChooserPromise = page.waitForEvent('filechooser', { timeout: 15000 });
    await click(page, 'Attach file');
    const fileChooser = await fileChooserPromise;
    setStage('FilePicker synthetic file selection');
    if (SAVE_PICKER_SCENARIO) {
      await fileChooser.setFiles(savePickerFixturePath);
    } else {
      await fileChooser.setFiles({
        name: FILE_NAME,
        mimeType: 'application/octet-stream',
        buffer: PLAINTEXT,
      });
    }
    let fileInputEvidence = { available: false };
    try {
      fileInputEvidence = await fileChooser.element().evaluate((input) => ({
        available: true,
        connected: input.isConnected,
        fileCount: input.files?.length || 0,
        selectedFilePresent: Boolean(input.files?.item(0)),
      }));
    } catch (_) {}
    if (SAVE_PICKER_SCENARIO) {
      const expectedV2ObjectCount = Math.ceil(savePickerFixtureSize / (4 * 1024 * 1024)) + 1;
      setStage('complete bounded file upload across production v1/v2 size boundary');
      await waitFor(() => initRequestCount === expectedV2ObjectCount &&
        successfulUploadCompletionCount === expectedV2ObjectCount &&
        completedObjectReceipts.length === expectedV2ObjectCount,
      'v2 attachment upload did not complete every encrypted object', 30 * 60 * 1000);
      await page.getByRole('button', { name: 'Download attachment', exact: true }).waitFor({
        state: 'visible',
        timeout: 5 * 60 * 1000,
      });
      assertThat(uploadObjectDeclarations.length === expectedV2ObjectCount &&
        new Set(uploadObjectDeclarations.map((item) => item.objectId)).size === expectedV2ObjectCount &&
        uploadObjectDeclarations.every((item) => Number.isSafeInteger(item.size) && item.size > 0) &&
        completedObjectReceipts.length === expectedV2ObjectCount &&
        completedObjectReceipts.every((receipt) => uploadObjectDeclarations.some((item) =>
          item.objectId === receipt.objectId && item.size === receipt.size && item.sha256 === receipt.sha256)),
      'large attachment did not use one completed ciphertext object per v2 directory/data entry');
      setStage('sync v2 Host attachment revision');
      await click(page, 'Close');
      await syncNow(page);
      await waitFor(() => hasCanonicalUuid(attachmentRevisionId) &&
        attachmentObjectRefs.length === expectedV2ObjectCount,
      'v2 Host revision did not sync all encrypted attachment object references', 120000);
      const declarationIds = uploadObjectDeclarations.map((item) => item.objectId).sort();
      assertThat(JSON.stringify(declarationIds) ===
        JSON.stringify(attachmentObjectRefs.slice().sort()),
      'synced Host revision did not reference exactly the uploaded v2 ciphertext objects');
      for (const objectId of declarationIds) {
        assertThat(storedObjectCount(objectId) === 1 && objectReferenceCount(objectId) === 1 &&
          currentRevisionReferenceCount(hostRecordId, attachmentRevisionId, objectId) === 1,
        'v2 ciphertext object was missing from the server or current Host revision');
      }

      setStage('open Host Attachments for the real save-picker click path');
      await click(page, 'Attachments');
      await waitForSemanticText(page, FILE_NAME);
      const downloadButton = await button(page, 'Download attachment');
      assertThat(await downloadButton.isEnabled(),
        'production-size v2 attachment was not enabled for streaming download in Web');
      downloadCapturePhase = 'save-picker';
      let browserDownloadCount = 0;
      page.on('download', () => { browserDownloadCount += 1; });
      setStage('real Host Attachments button through Web File System Access adapter');
      await downloadButton.click();
      await waitFor(() => savePickerCloseEvents.length === 1,
        'Host attachment save did not commit through the File System Access adapter',
        30 * 60 * 1000);
      const pickerState = await page.evaluate(() => ({
        ...window.__atermiusSavePickerCapture,
        secureContext: window.isSecureContext,
      }));
      const closeEvidence = savePickerCloseEvents[0];
      assertThat(savePickerOpenEvents.length === 1 && pickerState.pickerCalls === 1 &&
        pickerState.suggestedName === FILE_NAME &&
        savePickerOpenEvents[0].suggestedName === FILE_NAME &&
        pickerState.userActivation === true && savePickerOpenEvents[0].userActivation === true &&
        pickerOpenRequestSequence < firstObjectGetRequestSequence,
      'save picker did not open with the suggested filename during user activation before object network access');
      assertThat(savePickerWriteCount === Math.ceil(savePickerFixtureSize / (4 * 1024 * 1024)) &&
        savePickerWriteBytes === savePickerFixtureSize && savePickerMaxWriteBytes <= 4 * 1024 * 1024 &&
        closeEvidence.plaintextSha256 === savePickerFixtureSha256 &&
        pickerState.writeCalls === savePickerWriteCount &&
        pickerState.writeBytes === savePickerFixtureSize &&
        pickerState.closeCalls === 1 && pickerState.abortCalls === 0 &&
        savePickerAbortCount === 0 && browserDownloadCount === 0,
      'streamed plaintext writes, full-file digest, close/abort lifecycle, or browser-download behavior was invalid');
      assertThat(closeEvidence.objectGetStarted > 0 &&
        closeEvidence.objectGetStarted === closeEvidence.objectGetFinished &&
        closeEvidence.objectGetFailed === 0 &&
        closeEvidence.objectGetStatuses.length === closeEvidence.objectGetFinished &&
        closeEvidence.objectGetStatuses.every((status) => status === 200 || status === 206),
      'save commit ran before all encrypted object responses completed successfully');
      await page.waitForFunction(() => {
        const save = window.__atermiusSavePickerCapture;
        const button = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .find((element) => (element.getAttribute('aria-label') || '').includes('Download attachment'));
        return save?.closeCalls === 1 && button?.getAttribute('aria-disabled') !== 'true';
      }, null, { timeout: 30000 });
      assertThat(await page.getByText('Attachment download', { exact: true }).count() === 0,
        'completed v2 download task remained in the Host Attachments transfer list');
      assertThat(!databaseContains(PLAINTEXT_MARKER),
        'server SQLite database contained the synthetic attachment plaintext marker');
      assertThat(captureErrorCount === 0 && pageErrorCount === 0 && rendererCrashCount === 0,
        'Web attachment acceptance encountered an inspection, page, or renderer error');
      console.log('Host Attachments save-picker acceptance safe evidence', JSON.stringify({
        scenario: ATTACHMENT_SCENARIO,
        fixtureBytes: savePickerFixtureSize,
        fixtureSha256: savePickerFixtureSha256,
        ciphertextObjectCount: expectedV2ObjectCount,
        objectGetCount: closeEvidence.objectGetFinished,
        streamWriteCount: savePickerWriteCount,
        largestPlaintextWriteBytes: savePickerMaxWriteBytes,
        fullPlaintextDigestMatched: closeEvidence.plaintextSha256 === savePickerFixtureSha256,
        pickerBeforeNetwork: pickerOpenRequestSequence < firstObjectGetRequestSequence,
        pickerHadUserActivation: pickerState.userActivation,
        closeAfterCompleteNetwork: closeEvidence.objectGetStarted === closeEvidence.objectGetFinished,
        browserDownloadCount,
        completedTransferTaskRemoved: true,
        serverPlaintextMarkerAbsent: true,
      }));
      console.log('WEB-ATTACH-01 passed (save-picker): Host Attachments click, bounded v2 upload/download, picker ordering, verified streaming save, and task cleanup succeeded.');
      return;
    }
    setStage('wait for persisted failure after later ciphertext chunk interruption');
    const interruptedUploadDeadline = Date.now() + 30000;
    let interruptedUploadUi = null;
    while (Date.now() < interruptedUploadDeadline) {
      interruptedUploadUi = await page.evaluate((expectedName) => {
        const text = [...document.querySelectorAll('flt-semantics')]
          .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
          .join('\n');
        return {
          failed: /\bfailed\b/i.test(text),
          firstMiBCommitted: /1\.0 MB\s*\/\s*2\.0 MB/.test(text),
          fileNameVisible: text.includes(expectedName),
        };
      }, FILE_NAME).catch(() => null);
      if (interruptedUploadUi) {
        interruptedUploadUi.resumeAvailable = await page.getByRole('button', {
          name: 'Resume upload',
          exact: true,
        }).isVisible().catch(() => false);
      }
      if (interruptedUploadUi?.failed && interruptedUploadUi.firstMiBCommitted &&
          interruptedUploadUi.resumeAvailable) break;
      await page.waitForTimeout(100);
    }
    assertThat(uploadInterrupted && interruptedUploadUi?.failed &&
      interruptedUploadUi.firstMiBCommitted && interruptedUploadUi.resumeAvailable &&
      interruptedUploadUi.fileNameVisible,
    'later ciphertext upload interruption did not persist a resumable first-MiB task');
    await waitFor(() => uploadReservations.length === 1 &&
      hasCanonicalUuid(interruptedUploadId),
    'successful upload initialization did not return its durable reservation');
    assertThat(hasCanonicalUuid(uploadedObjectId) &&
      hasCanonicalUuid(interruptedUploadId),
    'interrupted ciphertext upload did not expose its durable reservation identifiers');
    const partialUploadChunksBeforeReload = uploadChunkRows(interruptedUploadId);
    assertThat(uploadReservations.length === 1 &&
      uploadReservations[0].uploadId === interruptedUploadId &&
      uploadReservations[0].chunkSize === 1024 * 1024 &&
      Date.parse(uploadReservations[0].expiresAt) > Date.now() &&
      Date.parse(uploadReservations[0].expiresAt) <= Date.now() + 25 * 60 * 60 * 1000,
    'initial upload reservation response did not provide a durable upload ID and expiry');
    const initialChunkIndexes = UPLOAD_RESERVATION_EXPIRED ? '[0]' : '[0,1]';
    assertThat(uploadChunkRequests.length === 2 &&
      uploadChunkRequests[0].phase === 'interrupt' &&
      uploadChunkRequests[0].uploadId === interruptedUploadId &&
      uploadChunkRequests[0].index === 0 && !uploadChunkRequests[0].aborted &&
      uploadChunkRequests[1].uploadId === interruptedUploadId &&
      uploadChunkRequests[1].index === 1 && uploadChunkRequests[1].aborted &&
      JSON.stringify(uploadChunkIndexes(interruptedUploadId)) === initialChunkIndexes &&
      successfulChunkCount === 1,
    'test did not interrupt ciphertext chunk one at the configured server boundary');
    if (!UPLOAD_RESERVATION_EXPIRED) {
      assertThat(droppedChunkAck?.status === 200 && droppedChunkAck.index === 1 &&
        droppedChunkAck.uploadId === interruptedUploadId &&
        droppedChunkAck.alreadyUploaded === false &&
        partialUploadChunksBeforeReload.length === 2 &&
        JSON.stringify(partialUploadChunksBeforeReload.map((item) => [item.index, item.size])) ===
          '[[0,1048576],[1,1048576]]' &&
        partialUploadChunksBeforeReload[1].sha256 === droppedChunkAck.sha256,
      'test did not commit ciphertext chunk one upstream and drop exactly its browser-facing acknowledgement');
    } else {
      assertThat(droppedChunkAck === undefined && partialUploadChunksBeforeReload.length === 1 &&
        partialUploadChunksBeforeReload[0].index === 0 &&
        partialUploadChunksBeforeReload[0].size === 1024 * 1024,
      'expiry recovery setup did not leave only ciphertext chunk zero on the server');
    }
    assertThat(openUploadCount(interruptedUploadId, uploadedObjectId,
      uploadedObjectSize, uploadedObjectSha256) === 1 &&
      JSON.stringify(uploadChunkIndexes(interruptedUploadId)) === initialChunkIndexes &&
      storedObjectCount(uploadedObjectId) === 0 &&
      objectReferenceCount(uploadedObjectId) === 0,
    'server did not retain only the expected partial ciphertext under one open reservation');
    console.log('UI attachment upload interruption safe evidence', JSON.stringify({
      scenario: ATTACHMENT_SCENARIO,
      firstChunkPersisted: true,
      laterChunkCommittedButAckLost: !UPLOAD_RESERVATION_EXPIRED,
      laterChunkAbortedBeforeServer: UPLOAD_RESERVATION_EXPIRED,
      progressPersistedAtBytes: 1024 * 1024,
      uploadIdObserved: hasCanonicalUuid(interruptedUploadId),
      reservationExpiryObserved: Boolean(uploadReservations[0]?.expiresAt),
      serverChunkIndexesBeforeReload: uploadChunkIndexes(interruptedUploadId),
      serverCommittedChunkBytes: partialUploadChunksBeforeReload.map((item) => item.size),
      droppedChunkCommitStatus: droppedChunkAck?.status || null,
      serverObjectCountBeforeReload: storedObjectCount(uploadedObjectId),
    }));

    setStage('reload browser page with incomplete attachment upload');
    uploadCapturePhase = 'reload';
    if (FORCE_CHROMIUM_PROCESS_KILL) {
      const secureStoreKeyPresent = await page.evaluate(() =>
        Object.keys(localStorage).some((key) => key.endsWith('.device')));
      console.log('Web device secure-store presence before termination', JSON.stringify({
        deviceRecordPresent: secureStoreKeyPresent,
      }));
      setStage('allow browser profile storage to settle before hard termination');
      await page.waitForTimeout(15000);
      const uploadStorageBeforeHardKill = await browserDatabaseStorage(page);
      setStage('force-kill Chromium after partial upload commit');
      const uploadProcessRestart = await killAndRelaunchPersistentChromium();
      const healthNavigation = await page.goto(`${baseUrl}/health/ready`, {
        waitUntil: 'domcontentloaded',
      });
      assertThat(healthNavigation && healthNavigation.status() === 200,
        'restarted Chromium could not load the isolated server health probe');
      const reopenedProfileStorage = await page.evaluate(() => ({
        deviceRecordPresent: Object.keys(localStorage).some((key) => key.endsWith('.device')),
        storedKeyKinds: Object.keys(localStorage).map((key) => key.split('.').at(-1)).sort(),
      }));
      const uploadStorageAfterHardKill = await browserDatabaseStorage(page);
      const uploadStorageBackend = assertBrowserDatabaseStorageSurvived(uploadStorageBeforeHardKill,
        uploadStorageAfterHardKill, 'attachment upload database after Chromium termination');
      uploadRecoveryNeedsEnrollment = !reopenedProfileStorage.deviceRecordPresent;
      const reopenedPage = await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      assertThat(reopenedPage && reopenedPage.status() === 200,
        'persistent Web profile did not reopen the isolated application after Chromium termination');
      console.log('forced Chromium upload recovery safe evidence', JSON.stringify({
        oldProcessGroupExited: uploadProcessRestart.oldProcessGroupExited,
        newProcessGroupHasExpectedProfile: uploadProcessRestart.newProcessGroupHasExpectedProfile,
        processGroupChanged: uploadProcessRestart.processGroupChanged,
        samePersistentProfileRelaunched: uploadProcessRestart.reopenedSameProfilePath,
        profileStorageBeforeFlutterStartup: reopenedProfileStorage,
        browserDatabaseBackend: uploadStorageBackend,
        browserDatabaseCatalogPersisted: true,
        deviceKeyNeededEnrollment: uploadRecoveryNeedsEnrollment,
        committedServerChunkIndexes: uploadChunkIndexes(interruptedUploadId),
      }));
    } else {
      await click(page, 'Close');
      await page.reload({ waitUntil: 'domcontentloaded' });
    }
    await enableFlutterSemantics(page, startupAssetResponses, startupRequestFailureCount);
    await selectServerModeIfChooser(page);
    if (FORCE_CHROMIUM_PROCESS_KILL) {
      let restartUi;
      try {
        restartUi = await page.evaluate(() => {
          const semanticText = [...document.querySelectorAll('flt-semantics')]
            .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
            .join('\n');
          return {
            urlPath: (() => { try { return new URL(location.href).pathname; } catch (_) { return ''; } })(),
            inputLabels: [...document.querySelectorAll('input,textarea')]
              .map((element) => element.getAttribute('aria-label') || ''),
            buttonLabels: [...document.querySelectorAll('flt-semantics[role="button"]')]
              .map((element) => element.getAttribute('aria-label') || element.innerText || '')
              .filter(Boolean).slice(0, 20),
            signInVisible: semanticText.includes('Sign in and unlock'),
            unlockVisible: semanticText.includes('Unlock'),
            workspaceVisible: semanticText.includes('Add host'),
            connectVisible: semanticText.includes('Connect securely'),
            secureStoreDeviceRecordPresent: Object.keys(localStorage).some((key) => key.endsWith('.device')),
            secureStoreKeyKinds: Object.keys(localStorage).map((key) => key.split('.').at(-1)).sort(),
            deviceKeyErrorVisible: /no registered device key|没有已注册的设备密钥/i.test(document.body.innerText || ''),
          };
        });
      } catch (error) {
        restartUi = {
          evaluationFailed: true,
          errorName: error.name,
          pageClosed: page.isClosed(),
          pageUrl: page.url(),
          pageCount: browserContext.pages().length,
        };
      }
      restartUi.pageErrorCount = pageErrorCount;
      restartUi.rendererCrashCount = rendererCrashCount;
      console.log('post-process-restart UI state', JSON.stringify(restartUi));
    }
    const uploadReconnectButton = page.getByRole('button', {
      name: 'Connect securely', exact: true,
    }).first();
    if (await uploadReconnectButton.isVisible().catch(() => false)) {
      await connect(page, baseUrl);
    }
    if (FORCE_CHROMIUM_PROCESS_KILL && uploadRecoveryNeedsEnrollment) {
      setStage('re-enroll browser after upload process termination');
      const enrollment = await requestDeviceEnrollment(
        page, 'Attachment recovery after upload process kill',
      );
      const approval = await approveEnrollment(trustedPage, enrollment);
      await importDeviceApprovalAndSignIn(page, approval);
    } else {
      setStage('wait for sign-in form after interrupted upload');
      await field(page, 'Email or username');
      setStage('enter sign-in credentials after interrupted upload');
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', MASTER_PASSWORD);
      setStage('submit sign-in after interrupted upload');
      await click(page, 'Sign in and unlock');
      setStage('wait for workspace after interrupted upload');
      try {
        await page.getByRole('button', { name: 'Add host', exact: true }).waitFor({
          state: 'visible',
          timeout: 45000,
        });
      } catch (error) {
      console.log('post-upload-recovery sign-in safe diagnostic', JSON.stringify({
        inputLabels: await page.locator('input,textarea').evaluateAll((elements) =>
          elements.map((element) => element.getAttribute('aria-label') || '')).catch(() => []),
        signInButtonDisabled: await page.getByRole('button', {
          name: 'Sign in and unlock', exact: true,
        }).isDisabled().catch(() => null),
        buttonLabels: await page.getByRole('button').evaluateAll((elements) =>
          elements.map((element) => element.getAttribute('aria-label') || element.innerText || '')
            .filter(Boolean).slice(0, 20)).catch(() => []),
        visibleAuthError: await page.getByText(/incorrect|invalid|failed|error|错误|失败/i)
          .first().isVisible().catch(() => false),
        deviceKeyErrorVisible: await page.getByText(/no registered device key|没有已注册的设备密钥/i)
          .first().isVisible().catch(() => false),
        formInputsPopulated: await page.evaluate((expectedUsername) => {
          const inputs = [...document.querySelectorAll('input')];
          const email = inputs.find((element) => element.getAttribute('aria-label') === 'Email or username');
          const password = inputs.find((element) => element.getAttribute('aria-label') === 'Master password');
          return {
            usernameMatches: email?.value === expectedUsername,
            passwordHasValue: Boolean(password?.value),
          };
        }, USERNAME).catch(() => ({ evaluationFailed: true })),
        authNetworkObservations: authNetworkObservations.slice(-8),
        apiErrorCodes: [...safeApiErrorCodes],
        syncPushStatuses: syncPushStatuses.slice(-5),
        pageErrorCount,
        errorName: error.name,
      }));
      throw error;
      }
    }
    await click(page, 'Hosts');
    setStage('restore locally encrypted attachment Host after upload reload');
    const restoredUploadHostCard = hostCard(page, hostName);
    await restoredUploadHostCard.first().waitFor({ state: 'visible', timeout: 20000 });
    await restoredUploadHostCard.getByRole('button', {
      name: 'Attachments', exact: true,
    }).click();
    await waitForSemanticText(page, FILE_NAME);
    setStage('verify persisted upload progress and upload ID after reload');
    const reloadedUploadDeadline = Date.now() + 20000;
    let reloadedUploadUi = null;
    while (Date.now() < reloadedUploadDeadline) {
      reloadedUploadUi = await page.evaluate(() => {
        const text = [...document.querySelectorAll('flt-semantics')]
          .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
          .join('\n');
        return {
          failed: /\bfailed\b/i.test(text),
          firstMiBCommitted: /1\.0 MB\s*\/\s*2\.0 MB/.test(text),
        };
      }).catch(() => null);
      if (reloadedUploadUi) {
        reloadedUploadUi.resumeAvailable = await page.getByRole('button', {
          name: 'Resume upload', exact: true,
        }).isVisible().catch(() => false);
      }
      if (reloadedUploadUi?.failed && reloadedUploadUi.firstMiBCommitted &&
          reloadedUploadUi.resumeAvailable) break;
      await page.waitForTimeout(100);
    }
    assertThat(reloadedUploadUi?.failed && reloadedUploadUi.firstMiBCommitted &&
      reloadedUploadUi.resumeAvailable,
    'same-profile browser recovery did not restore the failed upload and persisted first-MiB progress');
    if (FORCE_CHROMIUM_PROCESS_KILL) {
      await page.route(uploadInterruptionRoutePattern, uploadInterruptionRoute);
    }
    assertThat(initRequestCount === 1 && uploadReservations.length === 1,
      'same-profile reload created a reservation before the user resumed the failed task');
    const reloadedChunkIndexes = UPLOAD_RESERVATION_EXPIRED ? '[0]' : '[0,1]';
    assertThat(uploadChunkRequests.length === 2 &&
      openUploadCount(interruptedUploadId, uploadedObjectId,
        uploadedObjectSize, uploadedObjectSha256) === 1 &&
      JSON.stringify(uploadChunkIndexes(interruptedUploadId)) === reloadedChunkIndexes &&
      storedObjectCount(uploadedObjectId) === 0 &&
      objectReferenceCount(uploadedObjectId) === 0,
    'reload changed the partial reservation or published an incomplete object/reference');

    if (UPLOAD_RESERVATION_EXPIRED) {
      setStage('expire isolated upload reservation at test boundary');
      expireUploadReservation(interruptedUploadId);
      assertThat(openUploadCount(interruptedUploadId, uploadedObjectId,
        uploadedObjectSize, uploadedObjectSha256) === 1 &&
        Date.parse(uploadReservationExpiry(interruptedUploadId)) < Date.now() &&
        expiredUploadCount(interruptedUploadId) === 0 &&
        JSON.stringify(uploadChunkIndexes(interruptedUploadId)) === '[0]' &&
        storedObjectCount(uploadedObjectId) === 0 &&
        objectReferenceCount(uploadedObjectId) === 0,
      'test boundary changed more than the isolated reservation expiration timestamp');
    }

    setStage('resume ciphertext upload from persisted next chunk index');
    uploadCapturePhase = 'resume';
    await click(page, 'Resume upload');
    await waitFor(() => hasCanonicalUuid(completedObjectId) &&
      completedObjectId === uploadedObjectId,
    'resumed encrypted upload did not complete the declared object');
    const expectedResumeChunkResponses = UPLOAD_RESERVATION_EXPIRED ? 4 : 2;
    await waitFor(() => uploadChunkResponses.filter((item) => item.phase === 'resume').length ===
      expectedResumeChunkResponses,
      'resumed upload chunk receipts were not captured');
    const resumedUploadChunks = uploadChunkRequests.filter((item) => item.phase === 'resume');
    const replacementUploadId = UPLOAD_RESERVATION_EXPIRED
      ? uploadReservations[1]?.uploadId
      : interruptedUploadId;
    if (!UPLOAD_RESERVATION_EXPIRED) {
      assertThat(resumedUploadChunks.length === 2 &&
        resumedUploadChunks.every((item) => item.uploadId === interruptedUploadId && !item.aborted) &&
        JSON.stringify(resumedUploadChunks.map((item) => item.index)) === '[1,2]' &&
        resumedUploadChunks[0].sha256 === uploadChunkRequests[1].sha256 &&
        uploadChunkResponses.find((item) => item.phase === 'resume' && item.index === 1)
          ?.alreadyUploaded === true &&
        uploadChunkResponses.find((item) => item.phase === 'resume' && item.index === 1)
          ?.sha256 === droppedChunkAck.sha256 &&
        uploadChunkResponses.find((item) => item.phase === 'resume' && item.index === 2)
          ?.alreadyUploaded === false &&
        JSON.stringify(uploadChunkRequests.filter((item) => item.phase === 'interrupt')
          .map((item) => item.index)) === '[0,1]' &&
        initRequestCount === 1 && uploadReservations.length === 1,
      'reloaded upload did not idempotently replay the same acknowledged-lost chunk before continuing without gaps');
    } else {
      const expiredChunkResponse = uploadChunkResponses.find((item) =>
        item.phase === 'resume' && item.uploadId === interruptedUploadId && item.index === 1);
      const replacementChunkRequests = resumedUploadChunks.filter((item) =>
        item.uploadId === replacementUploadId);
      assertThat(safeApiErrorCodes.has('UPLOAD_EXPIRED') &&
        expiredChunkResponse?.status === 410 && expiredChunkResponse.errorCode === 'UPLOAD_EXPIRED' &&
        hasCanonicalUuid(replacementUploadId) && replacementUploadId !== interruptedUploadId &&
        initRequestCount === 2 && uploadReservations.length === 2 &&
        uploadReservations[1].uploadId === replacementUploadId &&
        Date.parse(uploadReservations[1].expiresAt) > Date.now() &&
        replacementChunkRequests.length === 3 &&
        JSON.stringify(replacementChunkRequests.map((item) => item.index)) === '[0,1,2]' &&
        replacementChunkRequests.every((item) => !item.aborted) &&
        replacementChunkRequests[0].sha256 === uploadChunkRequests[0].sha256 &&
        uploadChunkRequests.filter((item) => item.phase === 'interrupt').length === 2 &&
        initRequestCount === 2 &&
        uploadChunkResponses.filter((item) => item.phase === 'resume' && item.status >= 200 &&
          item.status < 300).length === 3 &&
        expiredUploadCount(interruptedUploadId) === 1 &&
        JSON.stringify(uploadChunkIndexes(interruptedUploadId)) === '[]',
      'expired reservation did not return UPLOAD_EXPIRED then restart from chunk zero under a new ID');
    }
    assertThat(completedObjectSize === uploadedObjectSize &&
      completedObjectSha256 === uploadedObjectSha256 &&
      completedObjectReceiptCount(uploadedObjectId, uploadedObjectSize,
        uploadedObjectSha256) === 1 &&
      completedUploadCount(replacementUploadId) === 1 &&
      successfulUploadCompletionCount === 1 &&
      successfulUploadCompletionIds.length === 1 &&
      successfulUploadCompletionIds[0] === replacementUploadId &&
      JSON.stringify(uploadChunkIndexes(replacementUploadId)) === '[]' &&
      successfulChunkCount === (UPLOAD_RESERVATION_EXPIRED ? 4 : 3),
    'resumed upload receipt or assembled server object failed its size, digest, or cleanup checks');
    assertThat(objectReferenceCount(uploadedObjectId) === 0,
      'resuming a ciphertext upload committed an object reference before Host synchronization');
    await button(page, 'Download attachment');
    assertThat(!await page.getByRole('button', {
      name: 'Resume upload', exact: true,
    }).isVisible().catch(() => false),
    'completed encrypted upload left a resumable transfer task in the UI');
    console.log('UI attachment upload reload-resume safe evidence', JSON.stringify({
      scenario: ATTACHMENT_SCENARIO,
      sameUploadId: replacementUploadId === interruptedUploadId,
      replacementUploadId: replacementUploadId === interruptedUploadId ? null : replacementUploadId,
      firstResumedChunkIndex: UPLOAD_RESERVATION_EXPIRED
        ? resumedUploadChunks.find((item) => item.uploadId === replacementUploadId)?.index
        : resumedUploadChunks[0].index,
      resumedChunkIndexes: resumedUploadChunks.map((item) => item.index),
      sameCiphertextDigestOnReplay: !UPLOAD_RESERVATION_EXPIRED
        ? resumedUploadChunks[0].sha256 === uploadChunkRequests[1].sha256
        : null,
      replayReceiptAlreadyUploaded: !UPLOAD_RESERVATION_EXPIRED
        ? uploadChunkResponses.find((item) => item.phase === 'resume' && item.index === 1)?.alreadyUploaded
        : null,
      expiredReservationRejected: UPLOAD_RESERVATION_EXPIRED
        ? safeApiErrorCodes.has('UPLOAD_EXPIRED')
        : false,
      newReservationStartsAtChunkZero: UPLOAD_RESERVATION_EXPIRED
        ? resumedUploadChunks.find((item) => item.uploadId === replacementUploadId)?.index === 0
        : false,
      reservationCount: uploadReservations.length,
      oneSuccessfulCompletion: successfulUploadCompletionCount === 1,
      serverUploadState: 'completed',
      serverCiphertextDigestMatched: completedObjectSha256 === uploadedObjectSha256,
      serverTemporaryChunkRowsCleared: uploadChunkIndexes(replacementUploadId).length === 0,
      oldReservationExpired: UPLOAD_RESERVATION_EXPIRED
        ? expiredUploadCount(interruptedUploadId) === 1
        : false,
      hostReferenceWaitsForSync: objectReferenceCount(uploadedObjectId) === 0,
    }));
    setStage('attachment dialog close');
    await click(page, 'Close');
    setStage('post-upload sync');
    await syncNow(page);
    setStage('ciphertext upload and Host revision receipt');
    await waitFor(() => hasCanonicalUuid(uploadedObjectId) &&
      uploadedObjectId === completedObjectId && hasCanonicalUuid(attachmentRevisionId),
    'encrypted object upload or Host revision push did not complete');
    assertThat(initRequestCount === (UPLOAD_RESERVATION_EXPIRED ? 2 : 1) &&
      successfulChunkCount === (UPLOAD_RESERVATION_EXPIRED ? 4 : 3),
      'encrypted object upload did not persist each ciphertext chunk exactly once');

    setStage('UI attachment download');
    await click(page, 'Attachments');
    await button(page, 'Download attachment');
    downloadInterruptionRoutePattern =
      `**/api/v1/vaults/*/objects/${uploadedObjectId}`;
    downloadCapturePhase = 'interrupt';
    downloadInterruptionRoute = async (route) => {
      const request = route.request();
      const requestPath = apiPath(request);
      const range = /^bytes=(\d+)-(\d+)$/.exec(request.headers().range || '');
      if (request.method() === 'GET' &&
          requestPath.endsWith(`/objects/${uploadedObjectId}`) && range) {
        const start = Number(range[1]);
        const shouldInterrupt = downloadCapturePhase === 'interrupt' &&
          start === 1024 * 1024 && !downloadInterrupted;
        objectRangeRequests.push({
          phase: downloadCapturePhase,
          start,
          ifRange: request.headers()['if-range'] || '',
          aborted: shouldInterrupt,
        });
        if (shouldInterrupt) {
          downloadInterrupted = true;
          await route.abort('failed');
          return;
        }
      }
      await route.continue();
    };
    await page.route(downloadInterruptionRoutePattern, downloadInterruptionRoute);
    await click(page, 'Download attachment');
    setStage('interrupt after first verified ciphertext Range');
    const interruptedDeadline = Date.now() + 30000;
    let interruptedTransferUi = null;
    while (Date.now() < interruptedDeadline) {
      interruptedTransferUi = await page.evaluate(() => {
        const text = [...document.querySelectorAll('flt-semantics')]
          .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
          .join('\n');
        return {
          failed: /\bfailed\b/i.test(text),
          oneMiBCommitted: text.includes('1.0 MB /'),
        };
      }).catch(() => null);
      if (interruptedTransferUi) {
        interruptedTransferUi.resumeAvailable = await page.getByRole('button', {
          name: 'Resume download',
          exact: true,
        }).isVisible().catch(() => false);
      }
      if (interruptedTransferUi?.failed && interruptedTransferUi.oneMiBCommitted &&
          interruptedTransferUi.resumeAvailable) break;
      await page.waitForTimeout(100);
    }
    const interruptedRequests = objectRangeRequests.filter((item) => item.phase === 'interrupt');
    console.log('attachment interruption safe evidence', JSON.stringify({
      downloadInterrupted,
      requests: interruptedRequests.map((item) => ({
        start: item.start,
        aborted: item.aborted,
      })),
      transferUi: interruptedTransferUi,
      resumeButtonCount: await page.getByRole('button', {
        name: 'Resume download',
        exact: true,
      }).count().catch(() => -1),
      accessibleTransferButtons: await page.getByRole('button').evaluateAll((elements) =>
        elements.map((element) => element.getAttribute('aria-label') || element.innerText || '')
          .filter((label) => /resume|download/i.test(label)).slice(0, 8)).catch(() => []),
      successfulRanges: objectDownloadSegments.map((item) => ({
        phase: item.phase,
        requestRange: item.requestRange,
        status: item.status,
      })),
    }));
    assertThat(downloadInterrupted && interruptedTransferUi?.failed &&
      interruptedTransferUi.oneMiBCommitted && interruptedTransferUi.resumeAvailable,
    'interrupted download did not persist a failed task with its first MiB available to resume');
    assertThat(interruptedRequests.length === 2 &&
      interruptedRequests[0].start === 0 && interruptedRequests[1].start === 1024 * 1024 &&
      interruptedRequests[1].aborted &&
      interruptedRequests.every((item) => item.ifRange === `"sha256-${completedObjectSha256}"`),
    'test did not allow the first Range and interrupt exactly the second matching-object Range');
    assertThat(storedObjectCount(uploadedObjectId) === 1 &&
      currentRevisionReferenceCount(hostRecordId, attachmentRevisionId, uploadedObjectId) === 1,
    'server object or active Host reference changed during the interrupted client download');

    setStage('reload browser page with incomplete attachment download');
    downloadCapturePhase = 'reload';
    if (FORCE_CHROMIUM_PROCESS_KILL) {
      const downloadStorageBeforeHardKill = await browserDatabaseStorage(page);
      setStage('force-kill Chromium after partial Range download persistence');
      const downloadProcessRestart = await killAndRelaunchPersistentChromium();
      const healthNavigation = await page.goto(`${baseUrl}/health/ready`, {
        waitUntil: 'domcontentloaded',
      });
      assertThat(healthNavigation && healthNavigation.status() === 200,
        'restarted Chromium could not load the isolated server health probe after download');
      const downloadStorageAfterHardKill = await browserDatabaseStorage(page);
      const downloadStorageBackend = assertBrowserDatabaseStorageSurvived(downloadStorageBeforeHardKill,
        downloadStorageAfterHardKill, 'attachment download database after Chromium termination');
      const reopenedProfileStorage = await page.evaluate(() => ({
        deviceRecordPresent: Object.keys(localStorage).some((key) => key.endsWith('.device')),
        storedKeyKinds: Object.keys(localStorage).map((key) => key.split('.').at(-1)).sort(),
      }));
      downloadRecoveryNeedsEnrollment = !reopenedProfileStorage.deviceRecordPresent;
      await page.route(downloadInterruptionRoutePattern, downloadInterruptionRoute);
      const reopenedPage = await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      assertThat(reopenedPage && reopenedPage.status() === 200,
        'persistent Web profile did not reopen the isolated application after download termination');
      console.log('forced Chromium download recovery safe evidence', JSON.stringify({
        oldProcessGroupExited: downloadProcessRestart.oldProcessGroupExited,
        newProcessGroupHasExpectedProfile: downloadProcessRestart.newProcessGroupHasExpectedProfile,
        processGroupChanged: downloadProcessRestart.processGroupChanged,
        samePersistentProfileRelaunched: downloadProcessRestart.reopenedSameProfilePath,
        browserDatabaseBackend: downloadStorageBackend,
        browserDatabaseCatalogPersisted: true,
        deviceKeyNeededEnrollment: downloadRecoveryNeedsEnrollment,
        oneMiBPrefixCommittedBeforeTermination: interruptedTransferUi?.oneMiBCommitted === true,
        completedServerObjectStillPresent: storedObjectCount(uploadedObjectId) === 1,
      }));
    } else {
      await page.reload({ waitUntil: 'domcontentloaded' });
    }
    await enableFlutterSemantics(page, startupAssetResponses, startupRequestFailureCount);
    await selectServerModeIfChooser(page);
    const reconnectButton = page.getByRole('button', {
      name: 'Connect securely',
      exact: true,
    }).first();
    if (await reconnectButton.isVisible().catch(() => false)) {
      await connect(page, baseUrl);
    }
    if (FORCE_CHROMIUM_PROCESS_KILL && downloadRecoveryNeedsEnrollment) {
      setStage('re-enroll browser after download process termination');
      const enrollment = await requestDeviceEnrollment(
        page, 'Attachment recovery after download process kill',
      );
      const approval = await approveEnrollment(trustedPage, enrollment);
      await importDeviceApprovalAndSignIn(page, approval);
    } else {
      setStage('locate sign-in fields after attachment interruption reload');
      await field(page, 'Email or username');
      setStage('enter sign-in credentials after attachment interruption reload');
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', MASTER_PASSWORD);
      setStage('submit sign-in after attachment interruption reload');
      await click(page, 'Sign in and unlock');
      setStage('wait for workspace after attachment interruption reload');
      try {
        await page.getByRole('button', { name: 'Add host', exact: true })
          .waitFor({ state: 'visible', timeout: 45000 });
      } catch (error) {
      console.log('post-reload sign-in safe diagnostic', JSON.stringify({
        controls: await page.evaluate(() => ({
          inputLabels: [...document.querySelectorAll('input,textarea')]
            .map((element) => element.getAttribute('aria-label') || ''),
          buttonLabels: [...document.querySelectorAll('flt-semantics[role="button"]')]
            .map((element) => element.getAttribute('aria-label') || element.innerText || '')
            .filter(Boolean).slice(0, 16),
          errorTextPresent: /(incorrect|invalid|failed|error|try again|错误|失败)/i
            .test(document.body.innerText || ''),
          addHostButtonPresent: (document.body.innerText || '').includes('Add host'),
        })),
        apiErrorCodes: [...safeApiErrorCodes],
        pageErrorCount,
        errorName: error.name,
      }));
      throw error;
      }
    }
    setStage('pull persisted Host after attachment interruption reload');
    await click(page, 'Hosts');
    await syncNow(page);
    setStage('restore attachment Host card after interrupted reload');
    const restoredHostCard = hostCard(page, hostName);
    try {
      await restoredHostCard.first().waitFor({ state: 'visible', timeout: 20000 });
    } catch (error) {
      console.log('post-reload Host visibility safe diagnostic', JSON.stringify({
        errorName: error.name,
        pageState: await page.evaluate((expectedHostName) => {
          const semanticText = [...document.querySelectorAll('flt-semantics')]
            .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
            .join('\n');
          return {
            hostNameInBody: (document.body.innerText || '').includes(expectedHostName),
            hostNameInSemantics: semanticText.includes(expectedHostName),
            addHostVisible: semanticText.includes('Add host'),
            hostsNavVisible: semanticText.includes('Hosts'),
            visibleHostGroupCount: document.querySelectorAll('flt-semantics[role="group"]').length,
          };
        }, hostName).catch(() => ({ evaluationFailed: true })),
        apiErrorCodes: [...safeApiErrorCodes],
        syncPushStatuses: syncPushStatuses.slice(-6),
        serverReferenceCount: (() => {
          try { return currentRevisionReferenceCount(hostRecordId, attachmentRevisionId, uploadedObjectId); }
          catch (_) { return -1; }
        })(),
        storedObjectCount: (() => {
          try { return storedObjectCount(uploadedObjectId); }
          catch (_) { return -1; }
        })(),
      }));
      throw error;
    }
    setStage('open attachment dialog after interrupted reload');
    await restoredHostCard.getByRole('button', {
      name: 'Attachments',
      exact: true,
    }).click();
    setStage('confirm attachment manifest after interrupted reload');
    await waitForSemanticText(page, FILE_NAME);
    setStage('verify encrypted download task survived reload');
    const resumedTaskDeadline = Date.now() + 20000;
    let resumedTaskUi = null;
    while (Date.now() < resumedTaskDeadline) {
      resumedTaskUi = await page.evaluate(() => {
        const text = [...document.querySelectorAll('flt-semantics')]
          .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
          .join('\n');
        return {
          failed: /\bfailed\b/i.test(text),
          oneMiBCommitted: text.includes('1.0 MB /'),
        };
      }).catch(() => null);
      if (resumedTaskUi) {
        resumedTaskUi.resumeAvailable = await page.getByRole('button', {
          name: 'Resume download',
          exact: true,
        }).isVisible().catch(() => false);
      }
      if (resumedTaskUi?.failed && resumedTaskUi.oneMiBCommitted &&
          resumedTaskUi.resumeAvailable) break;
      await page.waitForTimeout(100);
    }
    assertThat(resumedTaskUi?.failed && resumedTaskUi.oneMiBCommitted &&
      resumedTaskUi.resumeAvailable,
    'reloaded browser did not restore the failed download task and persisted one-MiB prefix');

    setStage('resume encrypted object download from persisted Range offset');
    downloadCapturePhase = 'resume';
    const downloadPromise = waitForDownload(browserContext, page, 30000);
    await click(page, 'Resume download');
    const download = await downloadPromise;
    assertThat(download.suggestedFilename() === FILE_NAME, 'UI download filename did not match the attachment');
    const downloadedPath = path.join(tempRoot, 'downloaded-attachment.bin');
    await download.saveAs(downloadedPath);
    const downloadedBytes = fs.readFileSync(downloadedPath);
    const downloadedBytesMatch = downloadedBytes.equals(PLAINTEXT);
    assertThat(downloadedBytesMatch, 'UI-saved attachment bytes did not match the selected file');
    downloadedBytes.fill(0);
    const resumedRequests = objectRangeRequests.filter((item) => item.phase === 'resume');
    assertThat(resumedRequests.length >= 1 &&
      resumedRequests[0].start === 1024 * 1024 &&
      resumedRequests[0].ifRange === `"sha256-${completedObjectSha256}"` &&
      resumedRequests.every((item) => !item.aborted),
    'reloaded attachment download did not resume at the persisted Range offset');
    const expectedResumeStarts = [];
    for (let offset = 1024 * 1024; offset < completedObjectSize; offset += 1024 * 1024) {
      expectedResumeStarts.push(offset);
    }
    assertThat(JSON.stringify(resumedRequests.map((item) => item.start)) ===
      JSON.stringify(expectedResumeStarts),
    'resumed Range requests did not continue contiguously from the persisted prefix');
    console.log('UI attachment reload-resume byte comparison', JSON.stringify({
      downloadedBytesMatch,
      initialRangeRequests: interruptedRequests.map((item) => ({
        start: item.start,
        aborted: item.aborted,
      })),
      resumedRangeStarts: resumedRequests.map((item) => item.start),
      partialCiphertextPersistedAcrossReload: true,
    }));
    await page.getByRole('button', { name: 'Resume download', exact: true })
      .waitFor({ state: 'detached', timeout: 15000 });
    if (downloadInterruptionRoutePattern && downloadInterruptionRoute) {
      await page.unroute(downloadInterruptionRoutePattern, downloadInterruptionRoute);
      downloadInterruptionRoute = undefined;
      downloadInterruptionRoutePattern = undefined;
    }

    setStage('server object response receipt');
    await waitFor(() => Number.isSafeInteger(uploadedObjectSize) &&
      objectDownloadSegments.reduce((total, segment) => total + segment.bytes.length, 0) >= uploadedObjectSize,
    'UI download did not retrieve all ranges of the uploaded server object');
    assertThat(uploadedObjectId === completedObjectId &&
      uploadedObjectSize === completedObjectSize && uploadedObjectSha256 === completedObjectSha256,
    'completed encrypted object receipt did not match its upload declaration');
    objectDownload = assembleObjectDownload(
      objectDownloadSegments,
      completedObjectSize,
      completedObjectSha256,
    );
    console.log('server object Range response metadata', JSON.stringify({
      rangeCount: objectDownload.rangeCount,
      uniqueRangeCount: objectDownload.uniqueRangeCount,
      ciphertextByteLength: objectDownload.bytes.length,
      segments: objectDownload.metadata,
    }));

    setStage('SQLite current Host revision reference query');
    await waitFor(() => databaseFiles().some((file) => file === databasePath),
      'isolated server SQLite file was not created');
    const liveAttachmentReferenceCount = currentRevisionReferenceCount(
      hostRecordId, attachmentRevisionId, uploadedObjectId,
    );
    const liveStoredObjectCount = storedObjectCount(uploadedObjectId);
    console.log('current Host revision and object counts', JSON.stringify({
      liveAttachmentReferenceCount,
      liveStoredObjectCount,
    }));
    assertThat(liveAttachmentReferenceCount === 1 && liveStoredObjectCount === 1,
      'current Host revision does not reference its uploaded encrypted object');
    assertThat(objectDownload.bytes.length === completedObjectSize && objectDownload.bytes.length > 0,
      'server object range responses did not assemble to the expected ciphertext length');
    setStage('blob bytes confidentiality booleans');
    const blobContainsPlaintext = objectDownload.bytes.includes(PLAINTEXT);
    const blobContainsPlaintextMarker = objectDownload.bytes.includes(PLAINTEXT_MARKER);
    const blobContainsFileName = objectDownload.bytes.includes(Buffer.from(FILE_NAME));
    console.log('server blob confidentiality assertions', JSON.stringify({
      blobContainsPlaintext,
      blobContainsPlaintextMarker,
      blobContainsFileName,
    }));
    assertThat(!blobContainsPlaintext && !blobContainsPlaintextMarker && !blobContainsFileName,
      'server object bytes contained synthetic plaintext or its file name');
    setStage('SQLite content confidentiality booleans');
    const databaseContainsPlaintext = databaseContains(PLAINTEXT);
    const databaseContainsPlaintextMarker = databaseContains(PLAINTEXT_MARKER);
    const databaseContainsFileName = databaseContains(Buffer.from(FILE_NAME));
    console.log('server SQLite confidentiality assertions', JSON.stringify({
      databaseContainsPlaintext,
      databaseContainsPlaintextMarker,
      databaseContainsFileName,
    }));
    assertThat(!databaseContainsPlaintext && !databaseContainsPlaintextMarker && !databaseContainsFileName,
      'server SQLite content contained synthetic plaintext or its file name');

    setStage('UI attachment removal request');
    captureRevisionStage = 'remove';
    await click(page, 'Remove attachment');
    setStage('UI attachment removal confirmation');
    await click(page, 'Remove from host');
    setStage('UI attachment removal list refresh');
    await waitForText(page, 'No attachments saved for this host.');
    setStage('close attachment dialog after removal');
    await click(page, 'Close');
    setStage('sync removal revision');
    await syncNow(page);
    setStage('removal revision receipt');
    await waitFor(() => hasCanonicalUuid(removalRevisionId),
      'attachment removal did not produce a Host revision');
    const removedRevisionCurrentCount = currentRevisionWithoutReferenceCount(
      hostRecordId, removalRevisionId, uploadedObjectId,
    );
    assertThat(removedRevisionCurrentCount === 1,
      'current Host revision still references the removed attachment object');

    assertThat(captureErrorCount === 0, 'browser acceptance could not inspect safe API metadata');
    assertThat(pageErrorCount === 0, 'Flutter Web raised a page error during attachment acceptance');
    console.log(`WEB-ATTACH-01 passed (${ATTACHMENT_SCENARIO}): isolated Web registration, encrypted attachment upload, persisted Range download recovery, byte equality, and current-revision removal checks succeeded.`);
  } finally {
    await cleanup();
    if (cleanupFailure) throw new Error('isolated test resources did not all clean up');
  }
}

main().catch((error) => {
  const safeErrorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  console.error(`WEB-ATTACH-01 failed at ${activeStage} (${safeErrorClass}); sensitive diagnostics omitted`);
  process.exitCode = 1;
});
