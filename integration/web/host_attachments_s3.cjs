/*
 * WEB-ATTACH-S3-01: use the compiled Host Attachments UI against the real
 * server's S3 object backend, with one loopback-only opaque object-store fake.
 * Profile A uploads a production-v2 attachment and syncs its encrypted Host
 * reference; independent Profile B pulls it and Range-downloads/decrypts it.
 * Diagnostics contain only fixed stages, counts, and boolean assertions.
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
const { startOpaqueObjectStoreFixture } = require('./opaque_object_store_fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-attachment-s3-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `AttachS3${crypto.randomBytes(20).toString('hex')}9`;
const DEVICE_A = 'S3 attachment owner browser';
const DEVICE_B = 'S3 attachment replica browser';
const HOST_NAME = `attachment-s3-host-${RUN_ID.slice(0, 8)}`;
const FILE_NAME = `opaque-large-attachment-${RUN_ID.slice(0, 8)}.bin`;
const SOURCE_SIZE = 256 * 1024 * 1024 + 1;
const OBJECT_CHUNK_BYTES = 4 * 1024 * 1024;
const EXPECTED_OBJECT_COUNT = Math.ceil(SOURCE_SIZE / OBJECT_CHUNK_BYTES) + 1;
const PLAINTEXT_MARKER = Buffer.from(`s3-attachment-plaintext-${RUN_ID}:`);
const OBJECT_BUCKET = `atermius-e2e-${RUN_ID.slice(0, 8)}`;
const OBJECT_REGION = 'us-east-1';

let activeStage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let credentialsPath;
let sourcePath;
let sourceDescriptor;
let sourceDigest;
let bootstrapToken;
let fixture;
let serverProcess;
let contextA;
let contextB;
let pageA;
let pageB;
let cleanupPromise;
let cleanupError = false;
let logLeak = false;
const privateMaterial = [];
const browserForbiddenMaterial = [];
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

let objectAccessKeyId = `e2eAccess${crypto.randomBytes(12).toString('hex')}`;
let objectSecretAccessKey = crypto.randomBytes(36).toString('base64url');

let baseUrl;
let hostRecordId;
let captureHostCreation = false;
let attachmentRevisionId;
let attachmentObjectRefs = [];
const uploadedObjectIds = new Set();
const completedObjectIds = new Set();
const profiles = new Map();
const pendingApiBodyChecks = new Set();
let fixtureEndpointVisibleInBrowser = false;
let fixtureControlVisibleInBrowser = false;
let objectCredentialVisibleInBrowser = false;
let unexpectedBrowserOriginCount = 0;
let apiPlaintextMarkerLeak = false;
let databasePlaintextMarkerLeak = false;
let objectPlaintextMarkerLeak = false;
let objectFilenameLeak = false;
let serverApiFailureCount = 0;
let downloadSinkOpenCount = 0;
let downloadSinkCloseCount = 0;
let downloadSinkAbortCount = 0;
let downloadSinkWriteCount = 0;
let downloadSinkWriteBytes = 0;
let downloadSinkMaxWriteBytes = 0;
let downloadSinkByteMismatch = false;
let downloadSinkDigest;
let downloadSinkDigestMatches = false;
let downloadSinkOpenDuringUserActivation = false;
let downloadSinkSuggestedNameMatches = false;
let pickerOpenRequestSequence;
let firstObjectGetRequestSequence;
let requestSequence = 0;

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

function environmentWithoutCloudCredentials(source = process.env) {
  const env = { ...source };
  for (const key of Object.keys(env)) {
    if (key.startsWith('AWS_') || key.startsWith('ATERMIUS_OBJECT_STORE_S3_') ||
        key === 'ATERMIUS_OBJECT_STORE_BACKEND') delete env[key];
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
    if (child.exitCode !== null) throw new Error('isolated S3 server exited before readiness');
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
  throw new Error('isolated S3 server readiness timed out');
}

async function stopServer(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    new Promise((resolve) => setTimeout(resolve, 5000)),
  ]);
  if (child.exitCode === null) child.kill('SIGKILL');
}

function apiPath(request) {
  try { return new URL(request.url()).pathname; } catch (_) { return ''; }
}

function isObjectEndpoint(request) {
  return request.method() === 'GET' &&
    /^\/api\/v1\/vaults\/[^/]+\/objects\/[0-9a-f-]{36}$/i.test(apiPath(request));
}

function requestContainsPrivateMaterial(request) {
  const url = request.url();
  const requestPath = apiPath(request);
  const isTestSinkRequest = requestPath.startsWith('/__e2e/attachment-sink/');
  if (url.includes(fixture?.endpointUrl || '\u0000') ||
      url.includes(fixture?.controlUrl || '\u0000') ||
      url.includes(fixture?.controlToken || '\u0000')) {
    fixtureEndpointVisibleInBrowser = true;
    if (url.includes(fixture?.controlUrl || '\u0000') ||
        url.includes(fixture?.controlToken || '\u0000')) {
      fixtureControlVisibleInBrowser = true;
    }
  }
  if (url.includes(objectAccessKeyId) || url.includes(objectSecretAccessKey)) {
    objectCredentialVisibleInBrowser = true;
  }
  const headerValues = Object.values(request.headers());
  if (browserForbiddenMaterial.some((secret) => secret &&
      headerValues.some((value) => value.includes(secret)))) {
    objectCredentialVisibleInBrowser = true;
  }
  try {
    const parsed = new URL(url);
    if ((parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
        parsed.origin !== baseUrl) {
      unexpectedBrowserOriginCount += 1;
    }
  } catch (_) {}
  const body = request.postDataBuffer();
  if (body && browserForbiddenMaterial.some((secret) =>
    secret && body.includes(Buffer.from(secret)))) {
    objectCredentialVisibleInBrowser = true;
  }
  // The save-picker test sink intentionally receives decrypted chunks so the
  // runner can compare them to disk. All other browser request bodies must
  // keep the canary encrypted.
  if (!isTestSinkRequest && body &&
      sourceMarkerVariants.some((marker) => body.includes(marker))) {
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
  };
  profiles.set(profileName, observation);
  page.on('pageerror', () => { observation.pageErrors += 1; });
  page.on('requestfailed', (request) => {
    observation.requestFailures += 1;
    if (isObjectEndpoint(request)) observation.objectGetFailed += 1;
  });
  page.on('request', (request) => {
    requestSequence += 1;
    requestContainsPrivateMaterial(request);
    const requestPath = apiPath(request);
    if (requestPath.startsWith('/api/')) observation.apiRequests += 1;
    if (profileName === 'B' && request.method() === 'POST' &&
        requestPath === '/__e2e/attachment-sink/open' && !pickerOpenRequestSequence) {
      pickerOpenRequestSequence = requestSequence;
    }
    if (profileName === 'B' && isObjectEndpoint(request)) {
      observation.objectGetStarted += 1;
      const objectMatch = /\/api\/v1\/vaults\/[^/]+\/objects\/([0-9a-f-]{36})$/i
        .exec(requestPath);
      if (objectMatch) observation.objectGetIds.add(objectMatch[1]);
      if (!firstObjectGetRequestSequence) firstObjectGetRequestSequence = requestSequence;
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
    if (requestPath.startsWith('/api/') && !isObjectEndpoint(request)) {
      const pending = response.body().then((body) => {
        if (sourceMarkerVariants.some((marker) => body.includes(marker))) {
          apiPlaintextMarkerLeak = true;
        }
        if (body.includes(Buffer.from(objectAccessKeyId)) ||
            body.includes(Buffer.from(objectSecretAccessKey)) ||
            body.includes(Buffer.from(fixture?.controlToken || ''))) {
          objectCredentialVisibleInBrowser = true;
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
  await fill(page, 'SSH username', 'attachment-s3-e2e');
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
  await click(page, 'Import approval');
  await paste(page, 'Paste approval JSON', approvalJson);
  await click(page, 'Import device keys');
  await fill(page, 'Email or username', USERNAME);
  await fill(page, 'Master password', MASTER_PASSWORD);
  await click(page, 'Sign in and unlock');
  await waitWorkspace(page);
}

async function launchProfile(profileDir, name, withSavePicker = false) {
  const options = {
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    env: environmentWithoutCloudCredentials(),
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    acceptDownloads: true,
  };
  if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
  const context = await chromium.launchPersistentContext(profileDir, options);
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
  await installFlutterProbe(context);
  if (withSavePicker) await installSavePicker(context);
  const page = context.pages()[0] || await context.newPage();
  const observation = observePage(page, name);
  return { context, page, observation };
}

async function installSavePicker(context) {
  const sinkEndpoint = `${baseUrl}/__e2e/attachment-sink`;
  await context.addInitScript((endpoint) => {
    const state = {
      pickerCalls: 0,
      suggestedName: null,
      userActivation: false,
      writeCalls: 0,
      writeBytes: 0,
      maxWriteBytes: 0,
      closeCalls: 0,
      abortCalls: 0,
    };
    window.__e2eAttachmentSavePicker = state;
    window.showSaveFilePicker = async (options) => {
      state.pickerCalls += 1;
      state.suggestedName = options?.suggestedName ?? null;
      state.userActivation = Boolean(navigator.userActivation?.isActive);
      const response = await fetch(`${endpoint}/open`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          suggestedName: state.suggestedName,
          userActivation: state.userActivation,
        }),
      });
      if (!response.ok) throw new Error('test save sink open failed');
      return {
        createWritable: async () => ({
          write: async (value) => {
            let bytes;
            if (value instanceof Uint8Array) bytes = value;
            else if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
            else if (ArrayBuffer.isView(value)) {
              bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            } else throw new TypeError('unsupported save sink byte source');
            const written = await fetch(`${endpoint}/write`, { method: 'POST', body: bytes });
            if (!written.ok) throw new Error('test save sink write failed');
            state.writeCalls += 1;
            state.writeBytes += bytes.byteLength;
            state.maxWriteBytes = Math.max(state.maxWriteBytes, bytes.byteLength);
          },
          close: async () => {
            state.closeCalls += 1;
            const closed = await fetch(`${endpoint}/close`, {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                writeCalls: state.writeCalls,
                writeBytes: state.writeBytes,
                maxWriteBytes: state.maxWriteBytes,
              }),
            });
            if (!closed.ok) throw new Error('test save sink integrity gate rejected close');
          },
          abort: async () => {
            state.abortCalls += 1;
            await fetch(`${endpoint}/abort`, { method: 'POST' });
          },
        }),
      };
    };
  }, sinkEndpoint);
}

async function installSaveSinkRoutes(page, sourceDescriptorForCompare, observation) {
  const digest = crypto.createHash('sha256');
  let sinkOffset = 0;
  let sinkMismatch = false;
  const sinkEvents = { open: 0, close: 0, abort: 0 };
  await page.route(`${baseUrl}/__e2e/attachment-sink/**`, async (route) => {
    const request = route.request();
    const pathname = apiPath(request);
    if (request.method() === 'POST' && pathname === '/__e2e/attachment-sink/open') {
      const body = request.postDataJSON() || {};
      sinkEvents.open += 1;
      downloadSinkOpenCount += 1;
      downloadSinkOpenDuringUserActivation = body.userActivation === true;
      downloadSinkSuggestedNameMatches = body.suggestedName === FILE_NAME;
      await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
      return;
    }
    if (request.method() === 'POST' && pathname === '/__e2e/attachment-sink/write') {
      const bytes = request.postDataBuffer() || Buffer.alloc(0);
      const expected = Buffer.alloc(bytes.length);
      let read = 0;
      while (read < expected.length) {
        const count = fs.readSync(sourceDescriptorForCompare, expected, read,
          expected.length - read, sinkOffset + read);
        if (count <= 0) break;
        read += count;
      }
      if (read !== bytes.length || !bytes.equals(expected)) sinkMismatch = true;
      expected.fill(0);
      digest.update(bytes);
      sinkOffset += bytes.length;
      downloadSinkWriteCount += 1;
      downloadSinkWriteBytes += bytes.length;
      downloadSinkMaxWriteBytes = Math.max(downloadSinkMaxWriteBytes, bytes.length);
      await route.fulfill({ status: bytes.length > 0 ? 204 : 400, body: '' });
      bytes.fill(0);
      return;
    }
    if (request.method() === 'POST' && pathname === '/__e2e/attachment-sink/close') {
      const body = request.postDataJSON() || {};
      const deadline = Date.now() + 10000;
      while (observation.objectGetStarted !== observation.objectGetFinished +
          observation.objectGetFailed && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      sinkEvents.close += 1;
      downloadSinkCloseCount += 1;
      downloadSinkByteMismatch = sinkMismatch;
      downloadSinkDigest = digest.copy().digest('hex');
      downloadSinkDigestMatches = downloadSinkDigest === sourceDigest;
      const countsMatch = body.writeCalls === downloadSinkWriteCount &&
        body.writeBytes === SOURCE_SIZE && body.maxWriteBytes <= OBJECT_CHUNK_BYTES &&
        downloadSinkWriteBytes === SOURCE_SIZE && sinkOffset === SOURCE_SIZE;
      const networkComplete = observation.objectGetStarted > 0 &&
        observation.objectGetStarted === observation.objectGetFinished &&
        observation.objectGetFailed === 0 &&
        observation.objectGetResponses.length === observation.objectGetFinished;
      const valid = !sinkMismatch && downloadSinkDigestMatches && countsMatch && networkComplete;
      await route.fulfill({ status: valid ? 204 : 409, body: '' });
      return;
    }
    if (request.method() === 'POST' && pathname === '/__e2e/attachment-sink/abort') {
      sinkEvents.abort += 1;
      downloadSinkAbortCount += 1;
      await route.fulfill({ status: 204, body: '' });
      return;
    }
    await route.fulfill({ status: 404, body: '' });
  });
  return sinkEvents;
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
    'S3 acceptance did not create the isolated server database');
  return files.some((file) => buffersContainMarker(fs.readFileSync(file)) ||
    fs.readFileSync(file).includes(Buffer.from(FILE_NAME)));
}

function waitForUiButton(page, label, timeoutMs = 300000) {
  return page.getByRole('button', { name: label, exact: true }).waitFor({
    state: 'visible', timeout: timeoutMs,
  });
}

function namespaceKeyValid(key) {
  return /^atermius\/objects\/v1\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}$/i.test(key);
}

function makeCredentialsFile() {
  credentialsPath = path.join(tempRoot, 's3-client-credentials.json');
  const content = JSON.stringify({
    access_key_id: objectAccessKeyId,
    secret_access_key: objectSecretAccessKey,
  });
  fs.writeFileSync(credentialsPath, content, { flag: 'wx', mode: 0o600 });
  fs.chmodSync(credentialsPath, 0o600);
  const stat = fs.statSync(credentialsPath);
  assertThat(stat.isFile() && stat.nlink === 1 && stat.uid === process.getuid() &&
    (stat.mode & 0o777) === 0o600 && !credentialsPath.startsWith(`${dataDir}${path.sep}`),
  'temporary S3 credentials file did not satisfy private-file constraints');
  privateMaterial.push(objectAccessKeyId, objectSecretAccessKey);
  browserForbiddenMaterial.push(objectAccessKeyId, objectSecretAccessKey);
}

async function closeResources() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    try { await contextA?.close(); } catch (_) { cleanupError = true; }
    try { await contextB?.close(); } catch (_) { cleanupError = true; }
    await stopServer(serverProcess).catch(() => { cleanupError = true; });
    try { await fixture?.close(); } catch (_) { cleanupError = true; }
    if (sourceDescriptor !== undefined) {
      try { fs.closeSync(sourceDescriptor); } catch (_) { cleanupError = true; }
      sourceDescriptor = undefined;
    }
    if (tempRoot && fs.existsSync(tempRoot)) {
      try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
      catch (_) { cleanupError = true; }
    }
    bootstrapToken = undefined;
    sourceDigest = undefined;
    objectSecretAccessKey = '';
    objectAccessKeyId = '';
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
    assertThat(EXPECTED_OBJECT_COUNT === 66,
      'production large-file boundary no longer maps to the expected v2 object count');
    setStage('Flutter Web release bundle preflight');
    for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
      assertThat(fs.existsSync(path.join(WEB_ROOT, asset)),
        'compiled Flutter Web release bundle is incomplete');
    }
    setStage('isolated S3 server Cargo build');
    runQuietly('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
      timeout: 30 * 60 * 1000,
      env: environmentWithoutCloudCredentials(),
      failureMessage: 'isolated S3 server build failed',
    });
    assertThat(fs.existsSync(SERVER_BINARY), 'isolated server binary is missing');

    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-host-attachments-s3-'));
    fs.chmodSync(tempRoot, 0o700);
    dataDir = path.join(tempRoot, 'server-data');
    fs.mkdirSync(dataDir, { mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
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

    privateMaterial.push(objectSecretAccessKey);
    setStage('loopback fake S3 startup');
    fixture = await startOpaqueObjectStoreFixture({
      bucket: OBJECT_BUCKET,
      region: OBJECT_REGION,
      accessKeyId: objectAccessKeyId,
      secretAccessKey: objectSecretAccessKey,
      maxObjectBytes: 64 * 1024 * 1024,
    });
    privateMaterial.push(fixture.controlToken, fixture.controlUrl, fixture.endpointUrl);
    browserForbiddenMaterial.push(fixture.controlToken, fixture.controlUrl,
      fixture.endpointUrl);
    assertThat(new URL(fixture.endpointUrl).hostname === '127.0.0.1' &&
      new URL(fixture.endpointUrl).protocol === 'http:',
    'opaque S3 fixture endpoint was not IPv4 loopback HTTP');
    makeCredentialsFile();

    const port = await unusedLoopbackPort();
    baseUrl = `http://127.0.0.1:${port}`;
    const serverEnv = environmentWithoutCloudCredentials();
    Object.assign(serverEnv, {
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_OBJECT_STORE_BACKEND: 's3',
      ATERMIUS_OBJECT_STORE_S3_BUCKET: fixture.bucket,
      ATERMIUS_OBJECT_STORE_S3_REGION: OBJECT_REGION,
      ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE: credentialsPath,
      ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL: fixture.endpointUrl,
      RUST_LOG: 'off',
    });

    let profileA;
    let profileB;
    try {
      setStage('isolated S3 server startup');
      serverProcess = spawn(SERVER_BINARY, ['serve'], {
        cwd: ROOT,
        env: serverEnv,
        stdio: 'ignore',
      });
      await waitForServer(serverProcess);
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
      await fill(pageA, 'First Vault', 'S3 attachment acceptance');
      await click(pageA, 'Create owner account');
      bootstrapToken = undefined;
      await waitWorkspace(pageA);
      await syncNow(pageA);

      setStage('Profile B independent Chromium launch');
      profileB = await launchProfile(profileBDir, 'B', true);
      contextB = profileB.context;
      pageB = profileB.page;
      const sinkEvents = await installSaveSinkRoutes(pageB, sourceDescriptor,
        profileB.observation);
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

      setStage('Profile A selects the production-size attachment in Host Attachments');
      const chooserPromise = pageA.waitForEvent('filechooser', { timeout: 30000 });
      await click(pageA, 'Attach file');
      const chooser = await chooserPromise;
      await chooser.setFiles(sourcePath);
      setStage('Profile A encrypted v2 upload to S3-backed server');
      await waitFor(() => profileA.observation.uploadInitCount === EXPECTED_OBJECT_COUNT &&
        profileA.observation.uploadCompletionCount === EXPECTED_OBJECT_COUNT &&
        uploadedObjectIds.size === EXPECTED_OBJECT_COUNT &&
        completedObjectIds.size === EXPECTED_OBJECT_COUNT,
      'encrypted attachment upload did not complete all v2 objects', 30 * 60 * 1000);
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
      assertThat(ARefsMatchUpload, 'synced Host did not reference exactly the uploaded S3 objects');

      setStage('Profile B pulls and decrypts the synced Host attachment reference');
      await syncNow(pageB);
      const hostCardB = pageB.getByRole('group', { name: new RegExp(HOST_NAME) }).first();
      await hostCardB.waitFor({ state: 'visible', timeout: 120000 });
      await hostCardB.getByRole('button', { name: 'Attachments', exact: true }).click();
      await waitForSemanticText(pageB, FILE_NAME, 120000);
      const downloadButton = await button(pageB, 'Download attachment');
      assertThat(await downloadButton.isEnabled(),
        'Profile B did not expose an enabled attachment download action');

      setStage('Profile B invokes Host Attachments Range download');
      await downloadButton.click();
      setStage('Profile B awaits streamed download and sink close');
      await waitFor(() => downloadSinkCloseCount === 1,
        'Profile B did not commit the verified streamed attachment', 30 * 60 * 1000);
      setStage('Profile B verifies save picker session');
      const pickerState = await pageB.evaluate(() => ({
        pickerCalls: window.__e2eAttachmentSavePicker?.pickerCalls || 0,
        suggestedName: window.__e2eAttachmentSavePicker?.suggestedName || null,
        userActivation: window.__e2eAttachmentSavePicker?.userActivation === true,
        writeCalls: window.__e2eAttachmentSavePicker?.writeCalls || 0,
        writeBytes: window.__e2eAttachmentSavePicker?.writeBytes || 0,
        maxWriteBytes: window.__e2eAttachmentSavePicker?.maxWriteBytes || 0,
        closeCalls: window.__e2eAttachmentSavePicker?.closeCalls || 0,
        abortCalls: window.__e2eAttachmentSavePicker?.abortCalls || 0,
      }));
      assertThat(downloadSinkOpenCount === 1 && sinkEvents.open === 1 &&
        pickerState.pickerCalls === 1 && pickerState.userActivation &&
        downloadSinkOpenDuringUserActivation && downloadSinkSuggestedNameMatches &&
        pickerOpenRequestSequence < firstObjectGetRequestSequence,
      'Profile B save sink did not open once during user activation before Range requests');
      assertThat(downloadSinkByteMismatch === false && downloadSinkDigestMatches &&
        downloadSinkWriteBytes === SOURCE_SIZE && downloadSinkWriteCount > 1 &&
        downloadSinkMaxWriteBytes <= OBJECT_CHUNK_BYTES &&
        pickerState.writeBytes === SOURCE_SIZE && pickerState.writeCalls === downloadSinkWriteCount &&
        pickerState.closeCalls === 1 && pickerState.abortCalls === 0 &&
        downloadSinkAbortCount === 0,
      'Profile B decrypted bytes did not exactly match the source size, bytes, digest, and save lifecycle');
      setStage('Profile B verifies Range response completion');
      await waitFor(() => profileB.observation.objectGetStarted ===
        profileB.observation.objectGetFinished && profileB.observation.objectGetFailed === 0,
      'Profile B object Range responses did not finish cleanly', 30000);
      const apiRanges = profileB.observation.objectGetResponses.filter((item) => item.range);
      const validApiRanges = apiRanges.length > 0 && apiRanges.every((item) =>
        item.status === 206 && /^bytes \d+-\d+\/\d+$/.test(item.contentRange || ''));
      const profileBRequestedObjects = [...profileB.observation.objectGetIds].sort();
      const profileBResolvedSyncedObjects = [...attachmentObjectRefs].sort();
      const profileBDownloadedSyncedReferences =
        JSON.stringify(profileBRequestedObjects) ===
          JSON.stringify(profileBResolvedSyncedObjects);

      setStage('cross-profile references and privacy verification');
      await Promise.allSettled([...pendingApiBodyChecks]);
      assertThat(pendingApiBodyChecks.size === 0,
        'API privacy inspections did not finish before acceptance');
      const objectKeys = [...fixture.objects.keys()];
      const expectedObjectKeys = attachmentObjectRefs.map((objectId) =>
        objectKeys.find((key) => key.split('/').at(-2) === objectId));
      const storedReferenceKeysMatch = expectedObjectKeys.length === EXPECTED_OBJECT_COUNT &&
        expectedObjectKeys.every((key) => typeof key === 'string' && namespaceKeyValid(key)) &&
        new Set(expectedObjectKeys).size === EXPECTED_OBJECT_COUNT &&
        objectKeys.length === EXPECTED_OBJECT_COUNT;
      const objectBytes = [...fixture.objects.values()];
      objectPlaintextMarkerLeak = objectBytes.some((item) => buffersContainMarker(item.bytes));
      objectFilenameLeak = objectBytes.some((item) => item.bytes.includes(Buffer.from(FILE_NAME)));
      const S3PutRequests = fixture.requests.filter((item) => item.method === 'PUT');
      const conditionalS3Writes = S3PutRequests.length === EXPECTED_OBJECT_COUNT &&
        S3PutRequests.every((item) => item.conditional && item.status === 200) &&
        fixture.stats.unconditionalPut === 0 &&
        fixture.stats.conditionalPut === EXPECTED_OBJECT_COUNT;
      const fixtureRangeRequests = fixture.requests.filter((item) =>
        item.method === 'GET' && item.range);
      const validFixtureRanges = fixtureRangeRequests.length > 0 &&
        fixtureRangeRequests.every((item) => item.status === 206);
      databasePlaintextMarkerLeak = scanDatabaseForPlaintext();
      const profileIsolation = contextA !== contextB &&
        fs.existsSync(profileADir) && fs.existsSync(profileBDir) &&
        profileADir !== profileBDir;
      const browserPrivacy = !fixtureEndpointVisibleInBrowser &&
        !fixtureControlVisibleInBrowser && !objectCredentialVisibleInBrowser &&
        unexpectedBrowserOriginCount === 0 && !apiPlaintextMarkerLeak && !logLeak;
      const noPageErrors = profileA.observation.pageErrors === 0 &&
        profileB.observation.pageErrors === 0 && !cleanupError;
      const noFakeErrors = fixture.stats.unauthorized === 0 &&
        fixture.stats.wrongBucketOrKey === 0;
      nestedEvidence = {
        twoDistinctPersistentProfiles: profileIsolation,
        profileBCrossProfileAttachmentVisible: true,
        syncedReferenceCount: attachmentObjectRefs.length,
        uploadCompletionCount: profileA.observation.uploadCompletionCount,
        fixtureStoredObjectCount: objectKeys.length,
        referencesMapToNamespacedS3Objects: storedReferenceKeysMatch,
        S3ConditionalPutCount: fixture.stats.conditionalPut,
        noUnconditionalS3Put: fixture.stats.unconditionalPut === 0,
        profileBRangeRequestCount: apiRanges.length,
        profileBRangeResponsesValid: validApiRanges,
        profileBRequestedObjectCount: profileBRequestedObjects.length,
        profileBDownloadedSyncedReferences,
        fixtureRangeRequestCount: fixtureRangeRequests.length,
        fixtureRangeResponsesValid: validFixtureRanges,
        plaintextBytesMatchedExactly: !downloadSinkByteMismatch,
        plaintextSha256Matched: downloadSinkDigestMatches,
        sourceByteCount: SOURCE_SIZE,
        clientPlaintextMarkerAbsentFromS3Objects: !objectPlaintextMarkerLeak,
        attachmentFilenameAbsentFromS3Objects: !objectFilenameLeak,
        clientPlaintextMarkerAndFilenameAbsentFromDatabase: !databasePlaintextMarkerLeak,
        fixtureCredentialOrControlApiAbsentFromBrowser: browserPrivacy,
        fixtureAuthAndNamespaceErrors: fixture.stats.unauthorized + fixture.stats.wrongBucketOrKey,
        serverApiFailureResponseCount: serverApiFailureCount,
        pageErrorCount: profileA.observation.pageErrors + profileB.observation.pageErrors,
        savePickerHadUserActivation: downloadSinkOpenDuringUserActivation,
        savePickerOpenedBeforeObjectGet: pickerOpenRequestSequence < firstObjectGetRequestSequence,
        completedDownloadTaskRemoved: true,
        profileBRelayTickets: 0,
      };
      assertThat(profileIsolation && ARefsMatchUpload && storedReferenceKeysMatch &&
        conditionalS3Writes && validApiRanges && validFixtureRanges &&
        profileBDownloadedSyncedReferences &&
        !objectPlaintextMarkerLeak && !objectFilenameLeak && !databasePlaintextMarkerLeak &&
        browserPrivacy && noFakeErrors && noPageErrors && downloadSinkDigestMatches &&
        downloadSinkByteMismatch === false,
      'S3 upload/sync/Range/privacy evidence did not satisfy the full acceptance contract');
      setStage('Profile B verifies completed download task cleanup');
      const taskLocator = pageB.getByText('Attachment download', { exact: true });
      await waitFor(async () => await taskLocator.count() === 0,
        'completed Profile B attachment download remained in the task list', 30000);
      const remainingDownloadTask = await taskLocator.count();
      assertThat(remainingDownloadTask === 0,
        'completed Profile B attachment download remained in the task list');
      nestedEvidence.completedDownloadTaskRemoved = true;
      safeLog('WEB-ATTACH-S3-01 evidence', nestedEvidence);
      console.log('WEB-ATTACH-S3-01 passed: Host Attachments UI upload, Profile A to B sync, loopback S3 Range read, exact bytes and SHA-256.');
    } finally {
      await closeResources();
    }
  } catch (error) {
    failureClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
    if (activeStage.startsWith('Profile B') ||
        activeStage === 'cross-profile references and privacy verification') {
      const observation = profiles.get('B');
      const rangeResponses = observation?.objectGetResponses || [];
      const fixtureRanges = fixture?.requests?.filter((item) =>
        item.method === 'GET' && item.range) || [];
      const objectKeys = [...(fixture?.objects?.keys() || [])];
      const mappedObjectKeys = attachmentObjectRefs.map((objectId) =>
        objectKeys.find((key) => key.split('/').at(-2) === objectId));
      const mappedKeysValid = mappedObjectKeys.length === EXPECTED_OBJECT_COUNT &&
        mappedObjectKeys.every((key) => typeof key === 'string' && namespaceKeyValid(key)) &&
        new Set(mappedObjectKeys).size === EXPECTED_OBJECT_COUNT;
      const refsMatchUpload = uploadedObjectIds.size === EXPECTED_OBJECT_COUNT &&
        [...uploadedObjectIds].sort().join(',') === [...completedObjectIds].sort().join(',') &&
        [...uploadedObjectIds].sort().join(',') === [...attachmentObjectRefs].sort().join(',');
      const storedObjects = [...(fixture?.objects?.values() || [])];
      failureEvidence = {
        sinkOpenCount: downloadSinkOpenCount,
        sinkCloseCount: downloadSinkCloseCount,
        sinkAbortCount: downloadSinkAbortCount,
        sinkWriteCount: downloadSinkWriteCount,
        sinkWriteBytes: downloadSinkWriteBytes,
        sinkByteMismatch: downloadSinkByteMismatch,
        sinkDigestMatched: downloadSinkDigestMatches,
        pickerUserActivation: downloadSinkOpenDuringUserActivation,
        pickerNameMatched: downloadSinkSuggestedNameMatches,
        objectGetStarted: observation?.objectGetStarted ?? -1,
        objectGetFinished: observation?.objectGetFinished ?? -1,
        objectGetFailed: observation?.objectGetFailed ?? -1,
        apiRange206Count: rangeResponses.filter((item) => item.status === 206).length,
        apiRangeOtherResponseCount: rangeResponses.filter((item) => item.status !== 206).length,
        fixtureRangeRequestCount: fixtureRanges.length,
        fixtureRange206Count: fixtureRanges.filter((item) => item.status === 206).length,
        fixtureRangeOtherStatusCount: fixtureRanges.filter((item) => item.status !== 206).length,
        fixtureRangeStat: fixture?.stats?.rangeGet ?? -1,
        fixtureFullGetRequestCount: fixture?.requests?.filter((item) =>
          item.method === 'GET' && !item.range).length ?? -1,
        fixtureStoredObjectCount: objectKeys.length,
        syncedReferenceCount: attachmentObjectRefs.length,
        referencesMapToCurrentFourSegmentNamespace: mappedKeysValid,
        uploadedIdsMatchSyncedReferences: refsMatchUpload,
        conditionalS3PutCount: fixture?.stats?.conditionalPut ?? -1,
        unconditionalS3PutCount: fixture?.stats?.unconditionalPut ?? -1,
        objectPlaintextMarkerAbsent: !objectPlaintextMarkerLeak,
        objectFilenameAbsent: !objectFilenameLeak,
        databasePlaintextAbsent: !databasePlaintextMarkerLeak,
        browserPrivacyPassed: !fixtureEndpointVisibleInBrowser &&
          !fixtureControlVisibleInBrowser && !objectCredentialVisibleInBrowser &&
          unexpectedBrowserOriginCount === 0 && !apiPlaintextMarkerLeak && !logLeak,
        fakeS3ErrorCount: (fixture?.stats?.unauthorized ?? 0) +
          (fixture?.stats?.wrongBucketOrKey ?? 0),
        pageErrorCount: observation?.pageErrors ?? -1,
        requestFailureCount: observation?.requestFailures ?? -1,
        apiFailureCategories: observation?.apiFailures.slice(-5) || [],
        pageClosed: pageB?.isClosed() ?? true,
      };
    }
    await closeResources();
  }
  if (failureClass) {
    console.error(`WEB-ATTACH-S3-01 failed at ${activeStage} (${failureClass}); private diagnostics omitted`);
    if (failureEvidence) safeLog('WEB-ATTACH-S3-01 safe stage evidence', failureEvidence);
    process.exitCode = 1;
    return;
  }
  if (cleanupError || logLeak) {
    console.error('WEB-ATTACH-S3-01 failed during cleanup or safe-log validation (Error)');
    process.exitCode = 1;
  }
}

main().catch(async (error) => {
  await closeResources().catch(() => {});
  const failureClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  console.error(`WEB-ATTACH-S3-01 failed at ${activeStage} (${failureClass}); private diagnostics omitted`);
  process.exitCode = 1;
});
