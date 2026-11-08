/*
 * WEB-ATTACH-FS-01: use the compiled Host Attachments UI against the real
 * server's filesystem object backend. Profile A uploads a small v1 attachment
 * and syncs its encrypted Host reference; independent Profile B pulls it and
 * Range-downloads/decrypts/saves it. Diagnostics contain fixed stages,
 * counts, and boolean assertions only.
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

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-attachment-fs-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `AttachFs${crypto.randomBytes(20).toString('hex')}9`;
const DEVICE_A = 'Filesystem attachment owner browser';
const DEVICE_B = 'Filesystem attachment replica browser';
const HOST_NAME = `attachment-fs-host-${RUN_ID.slice(0, 8)}`;
const FILE_NAME = `opaque-filesystem-attachment-${RUN_ID.slice(0, 8)}.bin`;
const SOURCE_SIZE = 2 * 1024 * 1024 + 37;
const OBJECT_CHUNK_BYTES = 4 * 1024 * 1024;
const EXPECTED_OBJECT_COUNT = 1;
const PLAINTEXT_MARKER = Buffer.from(`filesystem-attachment-plaintext-${RUN_ID}:`);

let activeStage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let objectStoreRoot;
let replacementObjectStoreRoot;
let symlinkObjectStoreRoot;
let storeIdentity;
let sourcePath;
let sourceDescriptor;
let sourceDigest;
let bootstrapToken;
let serverProcess;
let rejectedIdentityServerProcess;
let rejectedSymlinkServerProcess;
let contextA;
let contextB;
let pageA;
let pageB;
let cleanupPromise;
let cleanupError = false;
let logLeak = false;
const privateMaterial = [];
const sourceMarkerVariants = [];

const originalConsole = {
  log: console.log.bind(console),
  info: console.info.bind(console),
  warn: console.warn.bind(console),
  error: console.error.bind(console),
};
for (const method of Object.keys(originalConsole)) {
  console[method] = (...args) => {
    const rendered = args.map((value) => typeof value === 'string'
      ? value : JSON.stringify(value)).join(' ');
    if (privateMaterial.some((secret) => secret && rendered.includes(secret))) {
      logLeak = true;
      return;
    }
    originalConsole[method](...args);
  };
}

let baseUrl;
let hostRecordId;
let captureHostCreation = false;
let attachmentRevisionId;
let attachmentObjectRefs = [];
const uploadedObjectIds = new Set();
const completedObjectIds = new Set();
const profiles = new Map();
const pendingApiBodyChecks = new Set();
let filesystemPathVisibleInBrowser = false;
let storeIdentityVisibleInBrowser = false;
let unexpectedBrowserOriginCount = 0;
let apiPlaintextMarkerLeak = false;
let databasePlaintextMarkerLeak = false;
let objectPlaintextMarkerLeak = false;
let objectFilenameLeak = false;
let filesystemObjectTreeValid = false;
let filesystemObjectPathMatchesReference = false;
let filesystemScanErrorCategory = 'none';
let filesystemScanEntryCount = 0;
let filesystemScanUnsafeEntry = false;
let storeIdentityPrivate = false;
let replacementIdentityRejected = false;
let symlinkRootRejected = false;
let serverOutputPrivate = true;
let temporaryTreeRemoved = false;
let serverProcessesStopped = true;
let serverApiFailureCount = 0;
let downloadedPath;
let downloadedByteMatch = false;
let downloadedDigestMatch = false;
let downloadedSuggestedNameMatch = false;
let downloadedByteCount = 0;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(stage) {
  activeStage = stage;
  console.log(`stage: ${stage}`);
}

function safeLog(label, evidence) {
  const rendered = JSON.stringify(evidence);
  assertThat(!privateMaterial.some((secret) => secret && rendered.includes(secret)),
    'safe evidence unexpectedly contained private configuration');
  console.log(label, rendered);
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

function environmentWithoutStorageConfig(source = process.env) {
  const env = { ...source };
  for (const key of Object.keys(env)) {
    if (key.startsWith('AWS_') || key.startsWith('ATERMIUS_OBJECT_STORE_')) delete env[key];
  }
  return env;
}

function createSyntheticFile(filePath, size, marker) {
  const block = crypto.randomBytes(1024 * 1024);
  marker.copy(block, 0, 0, Math.min(marker.length, block.length));
  const sentinelOffset = Math.min(marker.length, block.length - 5);
  Buffer.from([0x00, 0x41, 0xff, 0x10, 0x7f]).copy(block, sentinelOffset);
  const descriptor = fs.openSync(filePath, 'wx', 0o600);
  try {
    for (let offset = 0; offset < size;) {
      const length = Math.min(block.length, size - offset);
      const written = fs.writeSync(descriptor, block, 0, length, offset);
      if (written !== length) throw new Error('synthetic attachment write was incomplete');
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

async function waitForServer(child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated filesystem server exited before readiness');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Poll the isolated loopback service while it starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated filesystem server readiness timed out');
}

async function stopServer(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return true;
  child.kill('SIGTERM');
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    new Promise((resolve) => setTimeout(resolve, 5000)),
  ]);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGKILL');
    await Promise.race([
      new Promise((resolve) => child.once('exit', resolve)),
      new Promise((resolve) => setTimeout(resolve, 2000)),
    ]);
  }
  return child.exitCode !== null || child.signalCode !== null;
}

function apiPath(request) {
  try { return new URL(request.url()).pathname; } catch (_) { return ''; }
}

function isObjectEndpoint(request) {
  return request.method() === 'GET' &&
    /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/i.test(apiPath(request));
}

function rangesCoverCiphertext(ranges) {
  if (ranges.length < 2) return false;
  const parsed = ranges.map((item) => {
    const request = /^bytes=(\d+)-(\d+)$/.exec(item.range || '');
    const response = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(item.contentRange || '');
    if (!request || !response || item.status !== 206) return null;
    const values = [request[1], request[2], response[1], response[2], response[3]]
      .map(Number);
    return { requestStart: values[0], requestEnd: values[1], start: values[2],
      end: values[3], total: values[4] };
  });
  if (parsed.some((item) => !item)) return false;
  parsed.sort((left, right) => left.start - right.start);
  const total = parsed[0].total;
  let next = 0;
  for (const item of parsed) {
    if (item.total !== total || item.start !== item.requestStart ||
        item.end !== item.requestEnd || item.start !== next || item.end < item.start) {
      return false;
    }
    next = item.end + 1;
  }
  return total > 0 && next === total;
}

function requestContainsPrivateMaterial(request) {
  const url = request.url();
  const headerValues = Object.values(request.headers());
  const headerText = headerValues.join('\n');
  if (objectStoreRoot && (url.includes(objectStoreRoot) || headerText.includes(objectStoreRoot))) {
    filesystemPathVisibleInBrowser = true;
  }
  if (storeIdentity && (url.includes(storeIdentity) || headerText.includes(storeIdentity))) {
    storeIdentityVisibleInBrowser = true;
  }
  try {
    const parsed = new URL(url);
    if ((parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
        parsed.origin !== baseUrl) {
      unexpectedBrowserOriginCount += 1;
    }
  } catch (_) {}
  const body = request.postDataBuffer();
  if (body && objectStoreRoot && body.includes(Buffer.from(objectStoreRoot))) {
    filesystemPathVisibleInBrowser = true;
  }
  if (body && storeIdentity && body.includes(Buffer.from(storeIdentity))) {
    storeIdentityVisibleInBrowser = true;
  }
  if (body && sourceMarkerVariants.some((marker) => body.includes(marker))) {
    apiPlaintextMarkerLeak = true;
  }
}

function observePage(page, profileName) {
  const observation = {
    profileName,
    pageErrors: 0,
    requestFailures: 0,
    uploadInitCount: 0,
    uploadChunkCount: 0,
    uploadCompletionCount: 0,
    uploadStatuses: [],
    objectGetStarted: 0,
    objectGetFinished: 0,
    objectGetFailed: 0,
    objectGetResponses: [],
    objectRequests: new Map(),
    objectGetIds: new Set(),
    apiFailures: [],
    apiRequests: 0,
    apiResponses: 0,
    requestFailureCategories: {},
  };
  profiles.set(profileName, observation);
  page.on('pageerror', () => { observation.pageErrors += 1; });
  page.on('requestfailed', (request) => {
    observation.requestFailures += 1;
    if (isObjectEndpoint(request)) observation.objectGetFailed += 1;
    const requestPath = apiPath(request);
    const endpoint = !requestPath.startsWith('/api/') ? 'web-resource' :
      /\/auth\/prelogin$/.test(requestPath) ? 'auth-prelogin' :
      /\/auth\/login$/.test(requestPath) ? 'auth-login' :
      /\/auth\//.test(requestPath) ? 'auth-other' :
      /\/sync\//.test(requestPath) ? 'sync' :
      /\/vaults\//.test(requestPath) ? 'vault' : 'other-api';
    const errorText = request.failure()?.errorText || '';
    const failure = /ERR_ABORTED/.test(errorText) ? 'aborted' :
      /ERR_CONNECTION_RESET/.test(errorText) ? 'connection-reset' :
      /ERR_CONNECTION_REFUSED/.test(errorText) ? 'connection-refused' :
      /ERR_TIMED_OUT/.test(errorText) ? 'timed-out' :
      /ERR_NAME_NOT_RESOLVED/.test(errorText) ? 'name-not-resolved' :
      'other';
    const key = `${request.resourceType()}:${request.method()}:${endpoint}:${failure}`;
    observation.requestFailureCategories[key] =
      (observation.requestFailureCategories[key] || 0) + 1;
  });
  page.on('request', (request) => {
    requestContainsPrivateMaterial(request);
    const requestPath = apiPath(request);
    if (requestPath.startsWith('/api/')) observation.apiRequests += 1;
    if (profileName === 'B' && isObjectEndpoint(request)) {
      observation.objectGetStarted += 1;
      const objectMatch = /\/api\/v1\/vaults\/[^/]+\/objects\/([0-9a-f-]{36})$/i
        .exec(requestPath);
      if (objectMatch) observation.objectGetIds.add(objectMatch[1]);
      observation.objectRequests.set(request, {
        range: request.headers().range || null,
        status: null,
        contentRange: null,
        finished: false,
        failed: false,
      });
    }
    if (profileName === 'A' && request.method() === 'POST' &&
        /\/api\/v1\/vaults\/[^/]+\/uploads\/init$/.test(requestPath)) {
      observation.uploadInitCount += 1;
      try {
        const body = request.postDataJSON();
        if (hasCanonicalUuid(body?.object_id)) uploadedObjectIds.add(body.object_id);
      } catch (_) {
        observation.uploadStatuses.push(0);
      }
    }
    if (profileName === 'A' && request.method() === 'PUT' &&
        /\/api\/v1\/uploads\/[^/]+\/chunks\/\d+$/.test(requestPath)) {
      observation.uploadChunkCount += 1;
    }
    if (profileName === 'A' && request.method() === 'POST' &&
        /\/api\/v1\/uploads\/[^/]+\/complete$/.test(requestPath)) {
      observation.uploadCompletionCount += 1;
    }
    if (profileName === 'A' && request.method() === 'POST' &&
        /\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(requestPath)) {
      try {
        const body = request.postDataJSON();
        for (const operation of body?.operations || []) {
          const header = operation?.header;
          if (!hasCanonicalUuid(header?.record_id) ||
              !hasCanonicalUuid(header?.revision_id)) continue;
          if (captureHostCreation && !hostRecordId) {
            hostRecordId = header.record_id;
            captureHostCreation = false;
          }
          if (header.record_id !== hostRecordId || !Array.isArray(header.object_refs)) continue;
          const refs = header.object_refs.filter(hasCanonicalUuid);
          if (refs.length === EXPECTED_OBJECT_COUNT &&
              refs.length === uploadedObjectIds.size &&
              refs.every((objectId) => uploadedObjectIds.has(objectId))) {
            attachmentRevisionId = header.revision_id;
            attachmentObjectRefs = refs.slice();
          }
        }
      } catch (_) {
        apiPlaintextMarkerLeak = true;
      }
    }
  });
  page.on('requestfinished', (request) => {
    const target = observation.objectRequests.get(request);
    if (target && !target.finished) {
      target.finished = true;
      observation.objectGetFinished += 1;
    }
  });
  page.on('response', (response) => {
    const request = response.request();
    const requestPath = apiPath(request);
    if (requestPath.startsWith('/api/')) {
      observation.apiResponses += 1;
      if (response.status() >= 400) {
        serverApiFailureCount += 1;
        const category = /\/sync\//.test(requestPath) ? 'sync' :
          /\/hosts(?:\/|$)/.test(requestPath) ? 'host' :
          /\/auth\/|\/sessions?\//.test(requestPath) ? 'auth' : 'other-api';
        observation.apiFailures.push({ category, status: response.status() });
      }
    }
    if (profileName === 'A' && requestPath.startsWith('/api/v1/uploads/')) {
      observation.uploadStatuses.push(response.status());
    }
    if (profileName === 'B' && observation.objectRequests.has(request)) {
      const target = observation.objectRequests.get(request);
      const headers = response.headers();
      target.status = response.status();
      target.contentRange = headers['content-range'] || null;
      target.etag = headers.etag || null;
      observation.objectGetResponses.push(target);
    }
    if (requestPath.startsWith('/api/')) {
      const pending = response.body().then((body) => {
        if (sourceMarkerVariants.some((marker) => body.includes(marker))) {
          apiPlaintextMarkerLeak = true;
        }
        if (objectStoreRoot && body.includes(Buffer.from(objectStoreRoot))) {
          filesystemPathVisibleInBrowser = true;
        }
        if (storeIdentity && body.includes(Buffer.from(storeIdentity))) {
          storeIdentityVisibleInBrowser = true;
        }
        if (profileName === 'A' && request.method() === 'POST' &&
            /\/api\/v1\/uploads\/[^/]+\/complete$/.test(requestPath) &&
            response.status() >= 200 && response.status() < 300) {
          try {
            const completion = JSON.parse(body.toString('utf8'));
            if (hasCanonicalUuid(completion?.object_id)) {
              completedObjectIds.add(completion.object_id);
            }
          } catch (_) {}
        }
      }).catch(() => {}).finally(() => pendingApiBodyChecks.delete(pending));
      pendingApiBodyChecks.add(pending);
    }
  });
  return observation;
}

function hasCanonicalUuid(value) {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

async function waitFor(predicate, message, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(120);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(120);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('a visible Web form field did not retain its input');
}

async function paste(page, label, value) {
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(150);
  if (await locator.inputValue().catch(() => '') !== value) await fill(page, label, value);
  assertThat(await locator.inputValue() === value,
    'device enrollment clipboard value did not populate the form');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function waitForSemanticText(page, expected, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await page.evaluate((text) => {
      if ((document.body.innerText || '').includes(text)) return true;
      return [...document.querySelectorAll('flt-semantics')].some((element) =>
        `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`.includes(text));
    }, expected).catch(() => false);
    if (found) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected attachment text did not appear in the UI');
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function connectToServer(page) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function enableFlutterSemantics(page) {
  const deadline = Date.now() + 60000;
  let ready = false;
  while (Date.now() < deadline) {
    ready = await page.evaluate(() => Boolean(
      window.__e2eFlutterProbe?.runAppCompleted &&
      document.querySelector('flt-semantics-placeholder'))).catch(() => false);
    if (ready) break;
    await page.waitForTimeout(100);
  }
  assertThat(ready, 'Flutter Web startup did not expose semantics readiness');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 15000 });
}

async function installFlutterProbe(context) {
  await context.addInitScript(() => {
    window.__e2eFlutterProbe = { runAppCompleted: false };
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
              const initialize = engineInitializer.initializeEngine.bind(engineInitializer);
              engineInitializer.initializeEngine = (...args) => initialize(...args).then((runner) => {
                const runApp = runner.runApp.bind(runner);
                runner.runApp = (...runArgs) => Promise.resolve(runApp(...runArgs)).then((result) => {
                  window.__e2eFlutterProbe.runAppCompleted = true;
                  return result;
                });
                return runner;
              });
              return callback(engineInitializer);
            };
          },
        });
      },
    });
  });
}

async function syncNow(page) {
  const sync = page.getByRole('button', { name: /^(Idle|Pending|\d+ pending)$/ }).first();
  await sync.waitFor({ state: 'visible', timeout: 20000 });
  await sync.click();
  await page.getByRole('button', { name: 'Idle', exact: true }).waitFor({
    state: 'visible', timeout: 60000,
  });
}

async function addHost(page) {
  setStage('Profile A Host editor opening');
  await click(page, 'Add host');
  await waitForSemanticText(page, 'Add a host');
  setStage('Profile A Host form entry');
  await fill(page, 'Display name', HOST_NAME);
  await fill(page, 'Hostname or IP', '198.51.100.77');
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'attachment-fs-e2e');
  setStage('Profile A Host form submission');
  await click(page, 'Save encrypted host');
  setStage('Profile A Host card visibility');
  const hostCardLocator = page.getByRole('group', { name: new RegExp(
    HOST_NAME.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
  ) });
  try {
    await hostCardLocator.first().waitFor({ state: 'visible', timeout: 30000 });
  } catch (_) {
    const evidence = {
      matchingHostGroups: await hostCardLocator.count().catch(() => -1),
      matchingVisibleHostNames: await page.getByText(HOST_NAME, { exact: true })
        .count().catch(() => -1),
      addHostDialogCount: await page.getByRole('dialog').count().catch(() => -1),
      visibleAlertCount: await page.getByRole('alert').count().catch(() => -1),
      pageErrorCount: profiles.get('A')?.pageErrors ?? -1,
      apiFailures: (profiles.get('A')?.apiFailures || []).slice(-5),
    };
    safeLog('Profile A Host card safe snapshot', evidence);
    throw new Error('Profile A Host card did not become visible');
  }
}

async function requestDeviceEnrollment(page) {
  await field(page, 'Email or username');
  await click(page, 'Add this device');
  await waitForSemanticText(page, 'Request this device');
  await fill(page, 'Account email', USERNAME);
  await fill(page, 'Device name', DEVICE_B);
  await click(page, 'Generate request');
  await field(page, 'Copy this enrollment JSON');
  await click(page, 'Copy');
  const value = await readClipboard(page);
  let format;
  try { format = JSON.parse(value).format; } catch (_) {}
  assertThat(format === 'atermius-device-enrollment-v1',
    'independent Profile B did not create a valid enrollment request');
  await click(page, 'Close');
  return value;
}

async function approveDeviceEnrollment(page, enrollmentJson) {
  await click(page, 'Devices');
  await click(page, 'Approve enrollment');
  await paste(page, 'Enrollment JSON', enrollmentJson);
  await click(page, 'Review keys');
  await click(page, 'Approve & seal keys');
  await click(page, 'Copy');
  const value = await readClipboard(page);
  assertThat(value.includes('atermius-device-approval-v1'),
    'Profile A did not create the trusted-device approval');
  await click(page, 'Done');
  await click(page, 'Hosts');
  return value;
}

async function importApprovalAndSignIn(page, approvalJson) {
  setStage('Profile B opens approval import dialog');
  await click(page, 'Import approval');
  setStage('Profile B enters approval JSON');
  await paste(page, 'Paste approval JSON', approvalJson);
  setStage('Profile B imports approved device keys');
  await click(page, 'Import device keys');
  setStage('Profile B fills account identity');
  await fill(page, 'Email or username', USERNAME);
  setStage('Profile B fills master password');
  await fill(page, 'Master password', MASTER_PASSWORD);
  setStage('Profile B submits sign-in');
  await click(page, 'Sign in and unlock');
  setStage('Profile B waits for authenticated workspace');
  await waitWorkspace(page);
}

async function safeSignInSnapshot(page) {
  const visible = async (locator) => locator.isVisible().catch(() => false);
  const signIn = page.getByRole('button', { name: 'Sign in and unlock', exact: true }).first();
  const email = page.locator('input[aria-label*="Email or username"]').first();
  const password = page.locator('input[aria-label*="Master password"]').first();
  const bodyText = await page.locator('body').innerText().catch(() => '');
  return {
    workspaceButtonVisible: await visible(page.getByRole('button', {
      name: 'Add host', exact: true,
    }).first()),
    importApprovalVisible: await visible(page.getByRole('button', {
      name: 'Import approval', exact: true,
    }).first()),
    signInButtonVisible: await visible(signIn),
    signInButtonEnabled: await signIn.isEnabled().catch(() => false),
    accountFieldVisible: await visible(email),
    passwordFieldVisible: await visible(password),
    accountFieldPopulated: Boolean(await email.inputValue().catch(() => '')),
    passwordFieldPopulated: Boolean(await password.inputValue().catch(() => '')),
    importDialogVisible: await visible(page.getByRole('dialog').filter({
      hasText: 'Import approved device',
    }).first()),
    visibleDialogCount: await page.getByRole('dialog').count().catch(() => -1),
    visibleAlertCount: await page.getByRole('alert').count().catch(() => -1),
    knownAuthErrorVisible: /incorrect|invalid|failed|error|错误|失败/i.test(bodyText),
    missingDeviceKeyErrorVisible:
      /no registered device key|没有已注册的设备密钥/i.test(bodyText),
    approvalMismatchErrorVisible:
      /approval file|批准文件|设备申请|device request/i.test(bodyText),
  };
}

async function launchProfile(profileDir, name) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    env: environmentWithoutStorageConfig(),
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    acceptDownloads: true,
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profileDir, options);
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
  await installFlutterProbe(context);
  const page = context.pages()[0] || await context.newPage();
  const observation = observePage(page, name);
  return { context, page, observation };
}

function databaseFiles() {
  if (!dataDir || !fs.existsSync(dataDir)) return [];
  return fs.readdirSync(dataDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(dataDir, entry.name));
}

function buffersContainMarker(bytes) {
  return sourceMarkerVariants.some((marker) => bytes.includes(marker));
}

function scanDatabaseForPlaintext() {
  const files = databaseFiles();
  assertThat(files.some((file) => file === databasePath),
    'filesystem acceptance did not create the isolated server database');
  return files.some((file) => {
    const bytes = fs.readFileSync(file);
    return buffersContainMarker(bytes) || bytes.includes(Buffer.from(FILE_NAME)) ||
      bytes.includes(Buffer.from(objectStoreRoot || '\u0000'));
  });
}

function waitForUiButton(page, label, timeoutMs = 300000) {
  return page.getByRole('button', { name: label, exact: true }).waitFor({
    state: 'visible', timeout: timeoutMs,
  });
}

function namespaceKeyValid(key) {
  return /^atermius\/objects\/v1\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}$/i.test(key);
}

function scanObjectStoreTree() {
  const objects = [];
  try {
    const rootStat = fs.lstatSync(objectStoreRoot);
    let unsafeEntry = rootStat.isSymbolicLink() || !rootStat.isDirectory() ||
      rootStat.uid !== process.getuid() || (rootStat.mode & 0o777) !== 0o700;
    const validDirectory = (relativePath) => {
      const parts = relativePath.split('/');
      if (parts[0] !== 'atermius' || parts.length > 6) return false;
      if (parts.length === 1) return true;
      if (parts[1] !== 'objects') return false;
      if (parts.length === 2) return true;
      if (parts[2] !== 'v1') return false;
      return parts.slice(3).every((part) => hasCanonicalUuid(part));
    };
    const visit = (directory, relativeDirectory = '') => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        filesystemScanEntryCount += 1;
        const absolutePath = path.join(directory, entry.name);
        const relativePath = relativeDirectory
          ? `${relativeDirectory}/${entry.name}` : entry.name;
        const stat = fs.lstatSync(absolutePath);
        if (stat.isSymbolicLink()) {
          unsafeEntry = true;
        } else if (stat.isDirectory()) {
          if (!validDirectory(relativePath) || stat.uid !== process.getuid() ||
              (stat.mode & 0o777) !== 0o700) unsafeEntry = true;
          visit(absolutePath, relativePath);
        } else if (stat.isFile() && relativePath === '.atermius-store-id') {
          if (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 ||
              stat.nlink !== 1) unsafeEntry = true;
        } else if (stat.isFile()) {
          if (!namespaceKeyValid(relativePath) || stat.uid !== process.getuid() ||
              (stat.mode & 0o777) !== 0o600 || stat.nlink !== 1) unsafeEntry = true;
          objects.push({ key: relativePath, path: absolutePath, stat,
            bytes: fs.readFileSync(absolutePath) });
        } else {
          unsafeEntry = true;
        }
      }
    };
    visit(objectStoreRoot);
    filesystemScanUnsafeEntry = unsafeEntry;
    return { objects, unsafeEntry };
  } catch (error) {
    filesystemScanErrorCategory = safeFilesystemErrorCategory(error);
    throw error;
  }
}

function safeFilesystemErrorCategory(error) {
  const code = typeof error?.code === 'string' ? error.code : '';
  if (code === 'ENOENT') return 'missing_entry';
  if (code === 'EACCES' || code === 'EPERM') return 'permission_denied';
  if (code === 'ELOOP') return 'symlink_loop';
  if (code === 'ENOTDIR') return 'non_directory_component';
  if (code === 'EIO') return 'filesystem_io';
  if (error?.name === 'TypeError') return 'scan_type_error';
  return 'other_filesystem_error';
}

function inspectStoreIdentity() {
  const rootStat = fs.lstatSync(objectStoreRoot);
  assertThat(rootStat.isDirectory() && !rootStat.isSymbolicLink() &&
    rootStat.uid === process.getuid() && (rootStat.mode & 0o777) === 0o700,
  'filesystem object root permissions or type were invalid');
  const markerPath = path.join(objectStoreRoot, '.atermius-store-id');
  const stat = fs.lstatSync(markerPath);
  assertThat(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1 &&
    stat.uid === process.getuid() && (stat.mode & 0o777) === 0o600,
  'filesystem store identity marker permissions or type were invalid');
  const marker = fs.readFileSync(markerPath, 'utf8');
  const value = marker.endsWith('\n') ? marker.slice(0, -1) : '';
  assertThat(hasCanonicalUuid(value) && marker === `${value}\n`,
    'filesystem store identity marker format was invalid');
  storeIdentity = value;
  privateMaterial.push(value, markerPath, objectStoreRoot);
  const tempEntries = fs.readdirSync(objectStoreRoot, { withFileTypes: true })
    .some((entry) => entry.name.includes('.tmp'));
  return { markerPath, tempEntries };
}

function watchServerOutput(child) {
  let tail = Buffer.alloc(0);
  const inspect = (chunk) => {
    const combined = Buffer.concat([tail, chunk]);
    const pathBytes = objectStoreRoot ? Buffer.from(objectStoreRoot) : null;
    if (buffersContainMarker(combined) ||
        (pathBytes && combined.includes(pathBytes)) ||
        privateMaterial.some((value) => typeof value === 'string' && value &&
          combined.includes(Buffer.from(value))) ||
        combined.includes(Buffer.from(FILE_NAME))) {
      serverOutputPrivate = false;
    }
    tail = combined.subarray(Math.max(0, combined.length - 256));
  };
  child.stdout?.on('data', inspect);
  child.stderr?.on('data', inspect);
}

async function expectStartupRejection(env, stage) {
  const child = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (stage === 'identity') rejectedIdentityServerProcess = child;
  else rejectedSymlinkServerProcess = child;
  watchServerOutput(child);
  let exit = null;
  let timer;
  const outcome = await Promise.race([
    new Promise((resolve) => child.once('exit', (code, signal) => {
      exit = { code, signal };
      resolve('exit');
    })),
    new Promise((resolve) => { timer = setTimeout(() => resolve('timeout'), 7000); }),
  ]);
  clearTimeout(timer);
  if (outcome === 'timeout') {
    await stopServer(child);
    return false;
  }
  return Boolean(exit && (exit.code !== 0 || exit.signal));
}

async function closeResources() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    try { await contextA?.close(); } catch (_) { cleanupError = true; }
    try { await contextB?.close(); } catch (_) { cleanupError = true; }
    for (const child of [serverProcess, rejectedIdentityServerProcess,
      rejectedSymlinkServerProcess]) {
      try {
        if (!await stopServer(child)) serverProcessesStopped = false;
      } catch (_) { serverProcessesStopped = false; }
    }
    if (!serverProcessesStopped) cleanupError = true;
    serverProcess = undefined;
    rejectedIdentityServerProcess = undefined;
    rejectedSymlinkServerProcess = undefined;
    if (sourceDescriptor !== undefined) {
      try { fs.closeSync(sourceDescriptor); } catch (_) { cleanupError = true; }
      sourceDescriptor = undefined;
    }
    if (tempRoot && fs.existsSync(tempRoot)) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
      catch (_) { cleanupError = true; }
    }
    temporaryTreeRemoved = Boolean(tempRoot && !fs.existsSync(tempRoot));
    if (!temporaryTreeRemoved) cleanupError = true;
    if (temporaryTreeRemoved) tempRoot = undefined;
    bootstrapToken = undefined;
    sourceDigest = undefined;
    for (const marker of sourceMarkerVariants) marker.fill(0);
    sourceMarkerVariants.length = 0;
    PLAINTEXT_MARKER.fill(0);
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void closeResources().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void closeResources().finally(() => process.exit(143)); });

async function main() {
  let failureClass = null;
  let failureEvidence = null;
  let nestedEvidence = null;
  try {
    assertThat(EXPECTED_OBJECT_COUNT === 1 && SOURCE_SIZE < 4 * 1024 * 1024,
      'filesystem UI acceptance must remain a single-object v1 attachment');
    setStage('Flutter Web release bundle preflight');
    for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
      assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
        'compiled Flutter Web release bundle is incomplete');
    }
    setStage('isolated filesystem server Cargo build');
    runQuietly('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
      timeout: 30 * 60 * 1000,
      env: environmentWithoutStorageConfig(),
      failureMessage: 'isolated filesystem server build failed',
    });
    assertThat(fs.existsSync(SERVER_BINARY), 'isolated filesystem server binary is missing');

    tempRoot = fs.realpathSync(fs.mkdtempSync(
      path.join(os.tmpdir(), 'atermius-web-host-attachments-filesystem-')));
    fs.chmodSync(tempRoot, 0o700);
    dataDir = path.join(tempRoot, 'server-data');
    objectStoreRoot = path.join(tempRoot, 'object-store');
    fs.mkdirSync(dataDir, { mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    fs.mkdirSync(objectStoreRoot, { mode: 0o700 });
    fs.chmodSync(objectStoreRoot, 0o700);
    assertThat(path.resolve(objectStoreRoot) === objectStoreRoot &&
      fs.realpathSync(objectStoreRoot) === objectStoreRoot &&
      !objectStoreRoot.startsWith(`${dataDir}${path.sep}`) &&
      !dataDir.startsWith(`${objectStoreRoot}${path.sep}`),
    'filesystem object root must be canonical and isolated from server data');
    databasePath = path.join(dataDir, 'atermius.db');
    sourcePath = path.join(tempRoot, FILE_NAME);
    createSyntheticFile(sourcePath, SOURCE_SIZE, PLAINTEXT_MARKER);
    sourceDigest = await digestFile(sourcePath);
    sourceDescriptor = fs.openSync(sourcePath, 'r');
    sourceMarkerVariants.push(
      Buffer.from(PLAINTEXT_MARKER),
      Buffer.from(PLAINTEXT_MARKER.toString('base64')),
      Buffer.from(PLAINTEXT_MARKER.toString('hex')),
      Buffer.from(FILE_NAME),
    );

    const port = await unusedLoopbackPort();
    baseUrl = `http://127.0.0.1:${port}`;
    const serverEnv = environmentWithoutStorageConfig();
    Object.assign(serverEnv, {
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_OBJECT_STORE_BACKEND: 'filesystem',
      ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT: objectStoreRoot,
      RUST_LOG: 'off',
    });

    let profileA;
    let profileB;
    try {
      setStage('isolated filesystem server startup');
      serverProcess = spawn(SERVER_BINARY, ['serve'], {
        cwd: ROOT,
        env: serverEnv,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      watchServerOutput(serverProcess);
      await waitForServer(serverProcess);
      const identity = inspectStoreIdentity();
      assertThat(!identity.tempEntries, 'filesystem store identity left an unfinished marker');
      storeIdentityPrivate = true;
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
        'isolated server did not issue a bootstrap token');
      privateMaterial.push(bootstrapToken);

      const profileADir = path.join(tempRoot, 'profile-a');
      const profileBDir = path.join(tempRoot, 'profile-b');
      fs.mkdirSync(profileADir, { mode: 0o700 });
      fs.mkdirSync(profileBDir, { mode: 0o700 });

      setStage('Profile A isolated Chromium launch');
      profileA = await launchProfile(profileADir, 'A');
      contextA = profileA.context;
      pageA = profileA.page;
      setStage('Profile A Web navigation and semantics');
      const navA = await pageA.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      assertThat(navA && navA.status() === 200, 'Profile A Web app did not load');
      await enableFlutterSemantics(pageA);
      setStage('Profile A owner registration');
      await connectToServer(pageA);
      await field(pageA, 'Owner email');
      await fill(pageA, 'Owner email', USERNAME);
      await fill(pageA, 'Master password · 12+ characters', MASTER_PASSWORD);
      await fill(pageA, 'Confirm master password', MASTER_PASSWORD);
      await fill(pageA, 'One-time bootstrap token', bootstrapToken);
      await fill(pageA, 'Device name', DEVICE_A);
      await fill(pageA, 'First Vault', 'Filesystem attachment acceptance');
      await click(pageA, 'Create owner account');
      bootstrapToken = undefined;
      await waitWorkspace(pageA);
      await syncNow(pageA);

      setStage('Profile B independent Chromium launch');
      profileB = await launchProfile(profileBDir, 'B');
      contextB = profileB.context;
      pageB = profileB.page;
      setStage('Profile B independent Web navigation');
      const navB = await pageB.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      assertThat(navB && navB.status() === 200, 'Profile B Web app did not load');
      await enableFlutterSemantics(pageB);
      await connectToServer(pageB);
      setStage('Profile B trusted device enrollment request');
      let enrollmentJson = await requestDeviceEnrollment(pageB);
      setStage('Profile A approves Profile B device');
      let approvalJson = await approveDeviceEnrollment(pageA, enrollmentJson);
      enrollmentJson = undefined;
      setStage('Profile B imports approval and signs in');
      await importApprovalAndSignIn(pageB, approvalJson);
      approvalJson = undefined;
      await syncNow(pageB);
      await syncNow(pageA);

      setStage('Profile A creates Host');
      captureHostCreation = true;
      await addHost(pageA);
      setStage('Profile A Host sync');
      await syncNow(pageA);
      setStage('Profile A Host server reference');
      await waitFor(() => hasCanonicalUuid(hostRecordId),
        'Profile A Host did not receive a server record reference');
      setStage('Profile A opens Host Attachments');
      const hostCardA = pageA.getByRole('group', { name: new RegExp(HOST_NAME) }).first();
      await hostCardA.getByRole('button', { name: 'Attachments', exact: true }).click();
      setStage('Profile A attachment empty state');
      await waitForSemanticText(pageA, 'No attachments saved for this host.');

      setStage('Profile A selects the small v1 attachment in Host Attachments');
      const chooserPromise = pageA.waitForEvent('filechooser', { timeout: 30000 });
      await click(pageA, 'Attach file');
      const chooser = await chooserPromise;
      await chooser.setFiles(sourcePath);
      setStage('Profile A encrypted v1 upload to filesystem backend');
      await waitFor(() => profileA.observation.uploadInitCount === EXPECTED_OBJECT_COUNT &&
        profileA.observation.uploadCompletionCount === EXPECTED_OBJECT_COUNT &&
        uploadedObjectIds.size === EXPECTED_OBJECT_COUNT &&
        completedObjectIds.size === EXPECTED_OBJECT_COUNT,
      'encrypted v1 attachment upload did not complete its object', 120000);
      await waitForUiButton(pageA, 'Download attachment');
      await waitForSemanticText(pageA, FILE_NAME);
      assertThat(!profileA.observation.uploadStatuses.some((status) => status >= 400),
        'Profile A attachment upload received a failed API status');

      setStage('Profile A syncs encrypted Host attachment references');
      await click(pageA, 'Close');
      await syncNow(pageA);
      await waitFor(() => hasCanonicalUuid(attachmentRevisionId) &&
        attachmentObjectRefs.length === EXPECTED_OBJECT_COUNT,
      'Profile A Host attachment reference revision did not sync', 120000);
      const uploadedSorted = [...uploadedObjectIds].sort();
      const completedSorted = [...completedObjectIds].sort();
      const referenceSorted = [...attachmentObjectRefs].sort();
      const ARefsMatchUpload = JSON.stringify(uploadedSorted) ===
        JSON.stringify(completedSorted) && JSON.stringify(uploadedSorted) ===
        JSON.stringify(referenceSorted);
      assertThat(ARefsMatchUpload,
        'synced Host did not reference exactly the uploaded filesystem object');

      setStage('Profile B pulls and decrypts the synced Host attachment reference');
      await syncNow(pageB);
      const hostCardB = pageB.getByRole('group', { name: new RegExp(HOST_NAME) }).first();
      await hostCardB.waitFor({ state: 'visible', timeout: 120000 });
      await hostCardB.getByRole('button', { name: 'Attachments', exact: true }).click();
      await waitForSemanticText(pageB, FILE_NAME, 120000);
      const downloadButton = await button(pageB, 'Download attachment');
      assertThat(await downloadButton.isEnabled(),
        'Profile B did not expose an enabled attachment download action');

      setStage('Profile B downloads and saves the attachment');
      const downloadPromise = pageB.waitForEvent('download', { timeout: 120000 });
      await downloadButton.click();
      const download = await downloadPromise;
      downloadedSuggestedNameMatch = download.suggestedFilename() === FILE_NAME;
      downloadedPath = path.join(tempRoot, 'profile-b-saved-attachment.bin');
      await download.saveAs(downloadedPath);
      const savedStat = fs.statSync(downloadedPath);
      const savedBytes = fs.readFileSync(downloadedPath);
      const sourceBytes = fs.readFileSync(sourcePath);
      try {
        downloadedByteCount = savedStat.size;
        downloadedByteMatch = savedStat.isFile() && savedBytes.length === SOURCE_SIZE &&
          sourceBytes.length === SOURCE_SIZE && savedBytes.equals(sourceBytes);
        downloadedDigestMatch = await digestFile(downloadedPath) === sourceDigest;
      } finally {
        savedBytes.fill(0);
        sourceBytes.fill(0);
      }
      assertThat(downloadedSuggestedNameMatch && downloadedByteCount === SOURCE_SIZE &&
        downloadedByteMatch && downloadedDigestMatch,
      'Profile B saved output did not match the encrypted Host attachment plaintext');
      setStage('Profile B verifies Range response completion');
      await waitFor(() => profileB.observation.objectGetStarted ===
        profileB.observation.objectGetFinished && profileB.observation.objectGetFailed === 0,
      'Profile B object Range responses did not finish cleanly', 30000);
      const apiRanges = profileB.observation.objectGetResponses.filter((item) => item.range);
      const validApiRanges = rangesCoverCiphertext(apiRanges);
      const profileBRequestedObjects = [...profileB.observation.objectGetIds].sort();
      const profileBResolvedSyncedObjects = [...attachmentObjectRefs].sort();
      const profileBDownloadedSyncedReferences =
        JSON.stringify(profileBRequestedObjects) ===
          JSON.stringify(profileBResolvedSyncedObjects);

      setStage('filesystem root identity mismatch rejection');
      serverProcessesStopped = await stopServer(serverProcess);
      assertThat(serverProcessesStopped, 'primary filesystem server did not stop cleanly');
      serverProcess = undefined;
      replacementObjectStoreRoot = path.join(tempRoot, 'replacement-object-store');
      fs.mkdirSync(replacementObjectStoreRoot, { mode: 0o700 });
      fs.chmodSync(replacementObjectStoreRoot, 0o700);
      privateMaterial.push(replacementObjectStoreRoot);
      const replacementEnv = {
        ...serverEnv,
        ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT: replacementObjectStoreRoot,
      };
      replacementIdentityRejected = await expectStartupRejection(replacementEnv, 'identity');
      const replacementMarkerPath = path.join(replacementObjectStoreRoot, '.atermius-store-id');
      const replacementMarkerExists = fs.existsSync(replacementMarkerPath);
      const replacementMarker = replacementMarkerExists
        ? fs.readFileSync(replacementMarkerPath, 'utf8') : '';
      const replacementId = replacementMarker.endsWith('\n')
        ? replacementMarker.slice(0, -1) : '';
      replacementIdentityRejected = replacementIdentityRejected &&
        hasCanonicalUuid(replacementId) && replacementId !== storeIdentity;
      if (replacementId) privateMaterial.push(replacementId);
      assertThat(replacementIdentityRejected,
        'server did not reject a filesystem root with a different persisted identity');

      setStage('filesystem symlink root rejection');
      const symlinkTarget = path.join(tempRoot, 'symlink-target');
      symlinkObjectStoreRoot = path.join(tempRoot, 'symlink-object-store');
      fs.mkdirSync(symlinkTarget, { mode: 0o700 });
      fs.chmodSync(symlinkTarget, 0o700);
      fs.symlinkSync(symlinkTarget, symlinkObjectStoreRoot, 'dir');
      privateMaterial.push(symlinkObjectStoreRoot, symlinkTarget);
      symlinkRootRejected = await expectStartupRejection({
        ...serverEnv,
        ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT: symlinkObjectStoreRoot,
      }, 'symlink');
      symlinkRootRejected = symlinkRootRejected &&
        !fs.existsSync(path.join(symlinkTarget, '.atermius-store-id'));
      assertThat(symlinkRootRejected,
        'server did not reject the symlink filesystem root before creating its identity');

      setStage('cross-profile references and privacy verification');
      await Promise.allSettled([...pendingApiBodyChecks]);
      assertThat(pendingApiBodyChecks.size === 0,
        'API privacy inspections did not finish before acceptance');
      const { objects, unsafeEntry } = scanObjectStoreTree();
      const objectKeys = objects.map((item) => item.key);
      const expectedObjectKeys = attachmentObjectRefs.map((objectId) =>
        objectKeys.find((key) => key.split('/').at(-2) === objectId));
      filesystemObjectPathMatchesReference = expectedObjectKeys.length === EXPECTED_OBJECT_COUNT &&
        expectedObjectKeys.every((key) => typeof key === 'string' && namespaceKeyValid(key)) &&
        new Set(expectedObjectKeys).size === EXPECTED_OBJECT_COUNT &&
        objectKeys.length === EXPECTED_OBJECT_COUNT;
      objectPlaintextMarkerLeak = objects.some((item) => buffersContainMarker(item.bytes));
      objectFilenameLeak = objects.some((item) => item.bytes.includes(Buffer.from(FILE_NAME)));
      filesystemObjectTreeValid = !unsafeEntry && objects.length === EXPECTED_OBJECT_COUNT &&
        objects.every((item) => namespaceKeyValid(item.key) && item.stat.isFile() &&
          !item.stat.isSymbolicLink() && item.stat.nlink === 1 && item.stat.size > 0) &&
        filesystemObjectPathMatchesReference;
      databasePlaintextMarkerLeak = scanDatabaseForPlaintext();
      const profileIsolation = contextA !== contextB &&
        fs.existsSync(profileADir) && fs.existsSync(profileBDir) &&
        profileADir !== profileBDir;
      const browserPrivacy = !filesystemPathVisibleInBrowser &&
        !storeIdentityVisibleInBrowser && unexpectedBrowserOriginCount === 0 &&
        !apiPlaintextMarkerLeak && !logLeak;
      const noPageErrors = profileA.observation.pageErrors === 0 &&
        profileB.observation.pageErrors === 0;
      nestedEvidence = {
        twoDistinctPersistentProfiles: profileIsolation,
        profileBCrossProfileAttachmentVisible: true,
        syncedReferenceCount: attachmentObjectRefs.length,
        uploadCompletionCount: profileA.observation.uploadCompletionCount,
        filesystemStoredObjectCount: objectKeys.length,
        filesystemScanErrorCategory,
        filesystemScanEntryCount,
        filesystemScanUnsafeEntry,
        referencesMapToNamespacedFilesystemObjects: filesystemObjectPathMatchesReference,
        filesystemObjectTreeValid,
        storeIdentityMarkerPrivateAndOwnerOnly: storeIdentityPrivate,
        profileBRangeRequestCount: apiRanges.length,
        profileBRangeResponsesValid: validApiRanges,
        profileBRequestedObjectCount: profileBRequestedObjects.length,
        profileBDownloadedSyncedReferences,
        savedOutputBytesMatchedExactly: downloadedByteMatch,
        savedOutputSha256Matched: downloadedDigestMatch,
        suggestedFilenameMatched: downloadedSuggestedNameMatch,
        sourceAndSavedByteCount: downloadedByteCount,
        clientPlaintextMarkerAbsentFromFilesystemObjects: !objectPlaintextMarkerLeak,
        attachmentFilenameAbsentFromFilesystemObjects: !objectFilenameLeak,
        clientPlaintextMarkerAndFilenameAbsentFromDatabase: !databasePlaintextMarkerLeak,
        filesystemRootAndIdentityAbsentFromBrowserAndApi: browserPrivacy,
        filesystemRootAbsentFromDatabaseAndServerOutput:
          !databaseFiles().some((file) => fs.readFileSync(file)
            .includes(Buffer.from(objectStoreRoot))) && serverOutputPrivate,
        replacementStoreIdentityRejected: replacementIdentityRejected,
        symlinkFilesystemRootRejected: symlinkRootRejected,
        serverApiFailureResponseCount: serverApiFailureCount,
        pageErrorCount: profileA.observation.pageErrors + profileB.observation.pageErrors,
        requestFailureCount: profileA.observation.requestFailures +
          profileB.observation.requestFailures,
        profileBRangeObjectCount: profileBRequestedObjects.length,
      };
      assertThat(profileIsolation && ARefsMatchUpload && filesystemObjectTreeValid &&
        validApiRanges &&
        profileBDownloadedSyncedReferences &&
        !objectPlaintextMarkerLeak && !objectFilenameLeak && !databasePlaintextMarkerLeak &&
        browserPrivacy && noPageErrors && serverApiFailureCount === 0 &&
        downloadedByteMatch && downloadedDigestMatch && downloadedSuggestedNameMatch &&
        replacementIdentityRejected && symlinkRootRejected && serverOutputPrivate,
      'filesystem upload/sync/Range/privacy evidence did not satisfy the full acceptance contract');

      setStage('Profile B verifies completed download task cleanup');
      const taskLocator = pageB.getByText('Attachment download', { exact: true });
      await waitFor(async () => await taskLocator.count() === 0,
        'completed Profile B attachment download remained in the task list', 30000);
      nestedEvidence.completedDownloadTaskRemoved = await taskLocator.count() === 0;
      assertThat(nestedEvidence.completedDownloadTaskRemoved,
        'completed Profile B attachment download remained in the task list');

      for (const item of objects) item.bytes.fill(0);
      storeIdentity = undefined;
      await closeResources();
      nestedEvidence.serverAndBrowserCleanupPassed = !cleanupError && temporaryTreeRemoved &&
        serverProcessesStopped && !tempRoot && !serverProcess &&
        !rejectedIdentityServerProcess && !rejectedSymlinkServerProcess;
      assertThat(nestedEvidence.serverAndBrowserCleanupPassed,
        'filesystem acceptance did not remove all temporary processes and files');
      safeLog('WEB-ATTACH-FS-01 evidence', nestedEvidence);
      console.log('WEB-ATTACH-FS-01 passed: two-profile Host attachment upload, encrypted sync, filesystem Range download, exact saved bytes and SHA-256.');
    } finally {
      await closeResources();
    }
  } catch (error) {
    failureClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
    const observation = profiles.get('B');
    const rangeResponses = observation?.objectGetResponses || [];
    let objectCount = -1;
    let mappedKeysValid = false;
    filesystemScanEntryCount = 0;
    filesystemScanUnsafeEntry = false;
    filesystemScanErrorCategory = 'none';
    try {
      const tree = scanObjectStoreTree();
      objectCount = tree.objects.length;
      mappedKeysValid = attachmentObjectRefs.length === EXPECTED_OBJECT_COUNT &&
        attachmentObjectRefs.every((objectId) => tree.objects.some((item) =>
          namespaceKeyValid(item.key) && item.key.split('/').at(-2) === objectId));
    } catch (_) {}
    failureEvidence = {
      objectGetStarted: observation?.objectGetStarted ?? -1,
      objectGetFinished: observation?.objectGetFinished ?? -1,
      objectGetFailed: observation?.objectGetFailed ?? -1,
      apiRange206Count: rangeResponses.filter((item) => item.status === 206).length,
      apiRangeOtherResponseCount: rangeResponses.filter((item) => item.status !== 206).length,
      filesystemObjectCount: objectCount,
      filesystemScanErrorCategory,
      filesystemScanEntryCount,
      filesystemScanUnsafeEntry,
      syncedReferenceCount: attachmentObjectRefs.length,
      referencesMapToFilesystemKeys: mappedKeysValid,
      uploadedObjectCount: uploadedObjectIds.size,
      completedObjectCount: completedObjectIds.size,
      downloadByteCount: downloadedByteCount,
      downloadedBytesMatch: downloadedByteMatch,
      downloadedSha256Matches: downloadedDigestMatch,
      suggestedFilenameMatches: downloadedSuggestedNameMatch,
      storeIdentityPrivate: storeIdentityPrivate && !storeIdentityVisibleInBrowser &&
        serverOutputPrivate,
      replacementIdentityRejected,
      symlinkRootRejected,
      objectPlaintextAbsent: !objectPlaintextMarkerLeak,
      filenameAbsentFromObjectBytes: !objectFilenameLeak,
      databasePlaintextAbsent: !databasePlaintextMarkerLeak,
      filesystemRootAbsentFromBrowser: !filesystemPathVisibleInBrowser,
      apiFailureCount: serverApiFailureCount,
      pageErrorCount: profiles.get('A')?.pageErrors + (observation?.pageErrors ?? 0),
      requestFailureCount: profiles.get('A')?.requestFailures +
        (observation?.requestFailures ?? 0),
      profileARequestFailureCategories:
        profiles.get('A')?.requestFailureCategories ?? {},
      profileBRequestFailureCategories:
        observation?.requestFailureCategories ?? {},
      apiFailureResponseCount: observation?.apiFailures.length ?? -1,
      profileAApiFailures: profiles.get('A')?.apiFailures.slice(-5) ?? [],
      profileBApiFailures: observation?.apiFailures.slice(-5) ?? [],
      profileBSignInSnapshot: pageB ? await safeSignInSnapshot(pageB) : null,
      pageClosed: pageB?.isClosed() ?? true,
    };
    await closeResources();
  }
  if (failureClass) {
    console.error('WEB-ATTACH-FS-01 failed at ' + activeStage +
      ' (' + failureClass + '); private diagnostics omitted');
    if (failureEvidence) safeLog('WEB-ATTACH-FS-01 safe stage evidence', failureEvidence);
    process.exitCode = 1;
    return;
  }
  if (cleanupError || logLeak || !serverOutputPrivate) {
    console.error('WEB-ATTACH-FS-01 failed during cleanup or safe-log validation (Error)');
    process.exitCode = 1;
  }
}

main().catch(async (error) => {
  await closeResources().catch(() => {});
  const failureClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  console.error('WEB-ATTACH-FS-01 failed at ' + activeStage +
    ' (' + failureClass + '); private diagnostics omitted');
  process.exitCode = 1;
});
