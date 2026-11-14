/*
 * WEB-RECOVERY-01: use the current Flutter Web release bundle to configure
 * account recovery, display/confirm the one-time recovery code, and rotate the
 * Recovery identity. The server, browser profile, database, credentials and
 * recovery codes are disposable. Output contains only fixed stages, HTTP
 * statuses and allow-listed state/count assertions.
 */

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

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let serverLogPath;
let serverLogFd;
let serverProcess;
let browser;
let browserContext;
let bootstrapToken;
let username;
let password;
let cleanupFailed = false;
let cleanupPromise;
const apiEvents = [];
const browserWireBodies = [];
const browserConsoleMessages = [];
const recoveryCodes = [];
const safeFillDiagnostics = [];
const safeCopyDiagnostics = [];
let pageErrorCount = 0;

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
  await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function waitForServer(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1200) });
      if (response.status === 200) return;
    } catch (_) {
      // Keep waiting while this disposable loopback server starts.
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
  throw new Error('server process group did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    username = undefined;
    password = undefined;
    try {
      if (browserContext) await browserContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    } finally {
      if (serverLogFd !== undefined) {
        try { fs.closeSync(serverLogFd); } catch (_) { cleanupFailed = true; }
        serverLogFd = undefined;
      }
      if (tempRoot) {
        try {
          fs.rmSync(tempRoot, { recursive: true, force: true });
          if (fs.existsSync(tempRoot)) cleanupFailed = true;
        } catch (_) {
          cleanupFailed = true;
        }
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
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
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 60 });
    await page.waitForTimeout(200);
    const preBlur = await stableFieldValue(locator, value);
    safeFillDiagnostics.push({ stage, attempt, phase: 'pre_blur', matched: preBlur });
    if (!preBlur) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    const postBlur = await stableFieldValue(locator, value);
    safeFillDiagnostics.push({ stage, attempt, phase: 'post_blur', matched: postBlur });
    if (postBlur) return;
  }
  throw new Error('visible form field did not retain its input');
}

async function stableFieldValue(locator, expected, timeoutMs = 1200) {
  const deadline = Date.now() + timeoutMs;
  let matches = 0;
  while (Date.now() < deadline) {
    if (await locator.inputValue() === expected) {
      matches += 1;
      if (matches >= 3) return true;
    } else {
      matches = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return false;
}

async function waitFor(predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web UI state did not appear');
}

async function waitForEvent(predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = apiEvents.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected recovery API response did not arrive');
}

function routeName(url) {
  try {
    const pathname = new URL(url).pathname;
    if (!pathname.startsWith('/api/v1/')) return null;
    return pathname.slice('/api/v1/'.length);
  } catch (_) {
    return null;
  }
}

function recoveryResponseSummary(route, text) {
  let body;
  try { body = JSON.parse(text); } catch (_) { return {}; }
  if (route === 'auth/recovery/contexts') {
    const present = Array.isArray(body.present_contexts) ? body.present_contexts.length : -1;
    const required = Array.isArray(body.required_contexts) ? body.required_contexts.length : -1;
    return {
      generation: Number.isInteger(body.recovery_generation) ? body.recovery_generation : null,
      recoveryStatus: ['disabled', 'current', 'stale'].includes(body.recovery_status)
        ? body.recovery_status : 'other',
      presentContexts: present,
      requiredContexts: required,
    };
  }
  return {
    generation: Number.isInteger(body.recovery_generation) ? body.recovery_generation : null,
    recoveryStatus: ['configured', 'current', 'stale'].includes(body.recovery_status)
      ? body.recovery_status : null,
  };
}

async function installNetworkAndLogObservers(page, origin) {
  const requestData = new WeakMap();
  page.on('request', (request) => {
    const route = routeName(request.url());
    let sameOrigin = false;
    try { sameOrigin = new URL(request.url()).origin === origin; } catch (_) { /* ignored */ }
    const body = request.postData() || '';
    if (sameOrigin && body) browserWireBodies.push(body);
    requestData.set(request, {
      route,
      method: request.method(),
      body,
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
    });
  });
  page.on('response', async (response) => {
    const request = response.request();
    const metadata = requestData.get(request);
    if (!metadata?.route) return;
    let responseBody = '';
    try { responseBody = await response.text(); } catch (_) { /* not a text response */ }
    let sameOrigin = false;
    try { sameOrigin = new URL(response.url()).origin === origin; } catch (_) { /* ignored */ }
    if (sameOrigin && responseBody) browserWireBodies.push(responseBody);

    const summary = {
      route: metadata.route,
      method: metadata.method,
      status: response.status(),
      hasBearer: metadata.hasBearer,
    };
    if (metadata.route === 'auth/recovery') {
      try {
        const body = JSON.parse(metadata.body || '{}');
        summary.generation = Number.isInteger(body.recovery_generation) ? body.recovery_generation : null;
        summary.submittedBoxes = Array.isArray(body.key_envelopes) ? body.key_envelopes.length : -1;
        summary.hasPreviousRecoveryProof = typeof body.previous_recovery_signature === 'string';
        summary.hasRecoveryCodeField = Object.keys(body).some((key) => /recovery.?code/i.test(key));
      } catch (_) {
        summary.generation = null;
        summary.submittedBoxes = -1;
        summary.hasPreviousRecoveryProof = false;
        summary.hasRecoveryCodeField = false;
      }
    }
    Object.assign(summary, recoveryResponseSummary(metadata.route, responseBody));
    apiEvents.push(summary);
  });
  page.on('console', (message) => browserConsoleMessages.push(message.text()));
  page.on('pageerror', () => { pageErrorCount += 1; });
}

async function readDisplayedCode(page) {
  setStage('wait for recovery code confirmation control');
  await page.getByRole('checkbox', { name: /I stored this code securely/ })
    .waitFor({ state: 'visible', timeout: 10000 });
  setStage('read one-time code from visible Flutter semantics');
  const fromSemantics = await page.locator('flt-semantics').evaluateAll((elements) => {
    const isCode = /^[A-Za-z0-9_-]{43}$/;
    const boundaryPattern = /(?:^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{43})(?:$|[^A-Za-z0-9_-])/;
    for (const element of elements) {
      const values = [
        element.innerText,
        element.textContent,
        element.getAttribute('aria-label'),
        element.getAttribute('aria-valuetext'),
        element.getAttribute('value'),
        element.getAttribute('title'),
      ];
      for (const attribute of Array.from(element.attributes || [])) values.push(attribute.value);
      for (const candidate of values) {
        if (typeof candidate !== 'string') continue;
        const withoutZeroWidth = candidate.replace(/[\u200B-\u200D\uFEFF]/g, '');
        const match = withoutZeroWidth.match(boundaryPattern);
        if (match) return match[1];
        const compact = withoutZeroWidth.trim().replace(/\s+/g, '');
        if (isCode.test(compact)) return compact;
      }
    }
    return '';
  });
  setStage('inspect recovery Copy code semantic hit target');
  const copyButton = page.getByRole('button', { name: /Copy code/ }).first();
  const exactCopyText = page.getByText('Copy code', { exact: true }).first();
  const copyMatches = await page.getByRole('button', { name: /Copy code/ }).count();
  const copyVisible = await copyButton.isVisible().catch(() => false);
  const copyEnabled = await copyButton.isEnabled().catch(() => false);
  const exactTextVisible = await exactCopyText.isVisible().catch(() => false);
  assertThat(copyMatches === 1 && copyVisible && copyEnabled,
    'recovery code copy control was unavailable');
  const hitTarget = await copyButton.evaluate((element) => {
    const rect = element.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    const hit = rect.width > 0 && rect.height > 0
      ? document.elementFromPoint(centerX, centerY) : null;
    const hitRelation = !hit ? 'none'
      : hit === element ? 'self'
        : element.contains(hit) ? 'descendant'
          : hit.contains(element) ? 'ancestor' : 'other';
    const style = getComputedStyle(element);
    const role = element.getAttribute('role');
    return {
      tag: element.tagName,
      role: role === 'button' || role === 'checkbox' ? role : 'other',
      tabIndex: element.tabIndex,
      rect: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      },
      inViewport: rect.right > 0 && rect.bottom > 0
        && rect.left < window.innerWidth && rect.top < window.innerHeight,
      pointerEvents: ['auto', 'none', 'inherit'].includes(style.pointerEvents)
        ? style.pointerEvents : 'other',
      hitRelation,
    };
  });
  const clipboardBaseline = await page.evaluate(() => {
    const metrics = window.__atermiusRecoveryClipboardMetrics;
    return metrics && Number.isInteger(metrics.calls) ? metrics.calls : -1;
  });
  const controlDiagnostic = {
    matches: copyMatches,
    visible: copyVisible,
    enabled: copyEnabled,
    exactTextVisible,
    ...hitTarget,
    clipboardObserverAvailable: clipboardBaseline >= 0,
  };
  safeCopyDiagnostics.push(controlDiagnostic);
  console.log(`control: recovery_copy_code ${JSON.stringify(controlDiagnostic)}`);
  assertThat(clipboardBaseline >= 0, 'recovery clipboard observer was unavailable');

  setStage('focus recovery Copy code semantic control');
  let focusSucceeded = false;
  try {
    await copyButton.focus({ timeout: 5000 });
    focusSucceeded = await copyButton.evaluate((element) => document.activeElement === element);
  } catch (_) { /* the safe focus diagnostic below records the failed action */ }
  safeCopyDiagnostics.push({ focusSucceeded });
  console.log(`control: recovery_copy_code_focus focused=${focusSucceeded}`);
  assertThat(focusSucceeded, 'recovery code copy control did not receive focus');

  setStage('press Enter on recovery Copy code semantic control');
  await page.keyboard.press('Enter');
  setStage('wait for recovery copy acknowledgement');
  try {
    await waitFor(() => page.evaluate(() => {
      const message = 'Recovery code copied.';
      return [...document.querySelectorAll('flt-semantics')].some((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const visible = style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        return visible && ((element.innerText || '').includes(message) ||
          (element.textContent || '').includes(message) ||
          (element.getAttribute('aria-label') || '').includes(message));
      });
    }), 5000);
  } catch (error) {
    const failedActionMetrics = await page.evaluate((callsBefore) => {
      const metrics = window.__atermiusRecoveryClipboardMetrics;
      return metrics ? {
        writeCalls: metrics.calls - callsBefore,
        writeValueLength: metrics.valueLength,
        writeFulfilled: metrics.fulfilled,
      } : { writeCalls: -1, writeValueLength: -1, writeFulfilled: false };
    }, clipboardBaseline).catch(() => ({ writeCalls: -1, writeValueLength: -1, writeFulfilled: false }));
    const acknowledgementState = await page.evaluate(() => {
      const message = 'Recovery code copied.';
      const semantics = [...document.querySelectorAll('flt-semantics')];
      const includesMessage = (element) =>
        (element.innerText || '').includes(message) ||
        (element.textContent || '').includes(message) ||
        (element.getAttribute('aria-label') || '').includes(message);
      const matching = semantics.filter(includesMessage);
      return {
        bodyContainsMessage: (document.body.innerText || '').includes(message),
        semanticMessageCount: matching.length,
        visibleSemanticMessageCount: matching.filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        }).length,
        liveRegionCount: semantics.filter((element) =>
          element.getAttribute('aria-live') === 'polite' ||
          element.getAttribute('aria-live') === 'assertive').length,
      };
    }).catch(() => ({
      bodyContainsMessage: false,
      semanticMessageCount: -1,
      visibleSemanticMessageCount: -1,
      liveRegionCount: -1,
    }));
    const safeAcknowledgement = {
      acknowledgementVisible: false,
      ...failedActionMetrics,
      ...acknowledgementState,
    };
    safeCopyDiagnostics.push(safeAcknowledgement);
    console.log(`control: recovery_copy_ack ${JSON.stringify(safeAcknowledgement)}`);
    throw error;
  }
  setStage('verify clipboard copy and clear it');
  const clipboard = await page.evaluate(async ({ semanticsCode, callsBefore }) => {
    const bounded = (promise, milliseconds, fallback) => Promise.race([
      promise,
      new Promise((resolve) => setTimeout(() => resolve(fallback), milliseconds)),
    ]);
    const codePattern = /^[A-Za-z0-9_-]{43}$/;
    let clipboardText = '';
    let clipboardReadSucceeded = false;
    try {
      const readResult = await bounded(navigator.clipboard.readText(), 750, null);
      if (typeof readResult === 'string') {
        clipboardText = readResult;
        clipboardReadSucceeded = true;
      }
    } catch (_) { /* the displayed code remains a safe in-memory fallback */ }
    const metrics = window.__atermiusRecoveryClipboardMetrics;
    const copyWriteCalls = metrics ? metrics.calls - callsBefore : -1;
    const copyWriteValueLength = metrics ? metrics.valueLength : -1;
    const copyWriteFulfilled = metrics ? metrics.fulfilled : false;
    const semanticsCodeIsValid = codePattern.test(semanticsCode);
    const clipboardMatchesDisplayedCode = semanticsCodeIsValid && clipboardReadSucceeded
      ? clipboardText === semanticsCode : null;
    const fallbackValue = semanticsCodeIsValid ? '' : clipboardText;
    let cleared = false;
    try {
      const clearResult = await bounded(navigator.clipboard.writeText(''), 750, null);
      cleared = clearResult !== null;
    } catch (_) { /* bounded best-effort clipboard cleanup */ }
    return {
      fallbackValue,
      semanticsCodeIsValid,
      clipboardReadSucceeded,
      clipboardReadValueLength: clipboardReadSucceeded ? clipboardText.length : -1,
      clipboardMatchesDisplayedCode,
      copyWriteCalls,
      copyWriteValueLength,
      copyWriteFulfilled,
      cleared,
    };
  }, { semanticsCode: fromSemantics, callsBefore: clipboardBaseline });
  const value = /^[A-Za-z0-9_-]{43}$/.test(fromSemantics) ? fromSemantics : clipboard.fallbackValue;
  const clipboardDiagnostic = {
    readSucceeded: clipboard.clipboardReadSucceeded,
    readValueLength: clipboard.clipboardReadValueLength,
    matchesDisplayedCode: clipboard.clipboardMatchesDisplayedCode,
    writeCalls: clipboard.copyWriteCalls,
    writeValueLength: clipboard.copyWriteValueLength,
    writeFulfilled: clipboard.copyWriteFulfilled,
    cleared: clipboard.cleared,
  };
  safeCopyDiagnostics.push(clipboardDiagnostic);
  console.log(`control: recovery_clipboard ${JSON.stringify(clipboardDiagnostic)}`);
  assertThat(clipboard.cleared, 'browser clipboard could not be cleared after copying the one-time code');
  assertThat(clipboard.copyWriteCalls === 1 && clipboard.copyWriteValueLength === 43
    && clipboard.copyWriteFulfilled,
  'recovery code copy action did not complete exactly one clipboard write');
  assertThat(!clipboard.clipboardReadSucceeded || clipboard.clipboardMatchesDisplayedCode === true,
    'browser clipboard did not match the displayed one-time recovery code');
  assertThat(/^[A-Za-z0-9_-]{43}$/.test(value), 'one-time recovery code format was invalid');
  return value;
}

async function confirmDisplayedCode(page) {
  const checkbox = page.getByRole('checkbox', { name: /I stored this code securely/ });
  setStage('focus recovery code acknowledgement checkbox');
  await checkbox.waitFor({ state: 'visible', timeout: 10000 });
  await checkbox.focus({ timeout: 5000 });
  const checkboxFocused = await checkbox.evaluate((element) =>
    document.activeElement === element);
  assertThat(checkboxFocused, 'recovery acknowledgement checkbox did not receive focus');
  setStage('press Space on recovery code acknowledgement checkbox');
  await page.keyboard.press('Space');
  setStage('verify recovery code acknowledgement');
  await waitFor(async () => (await checkbox.getAttribute('aria-checked')) === 'true', 5000);
  const finish = await button(page, 'Finish');
  setStage('focus Finish recovery confirmation');
  await finish.focus({ timeout: 5000 });
  const finishFocused = await finish.evaluate((element) =>
    document.activeElement === element);
  assertThat(finishFocused && await finish.isEnabled(),
    'Finish recovery confirmation was not keyboard-ready');
  setStage('press Enter on Finish recovery confirmation');
  await page.keyboard.press('Enter');
}

async function scanBrowserPersistence(page, needles) {
  return page.evaluate(async (patterns) => {
    const haystacks = [];
    const decoder = new TextDecoder();
    const seen = new WeakSet();
    function visit(value) {
      if (value == null) return;
      if (typeof value === 'string') { haystacks.push(value); return; }
      if (typeof value !== 'object') return;
      if (seen.has(value)) return;
      seen.add(value);
      if (value instanceof ArrayBuffer) { haystacks.push(decoder.decode(value)); return; }
      if (ArrayBuffer.isView(value)) {
        haystacks.push(decoder.decode(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)));
        return;
      }
      if (value instanceof Blob) return;
      if (Array.isArray(value)) { for (const item of value) visit(item); return; }
      for (const [key, item] of Object.entries(value)) { haystacks.push(key); visit(item); }
    }
    const storageCounts = { local: localStorage.length, session: sessionStorage.length, indexedDb: 0, cacheEntries: 0, opfsFiles: 0 };
    for (const storage of [localStorage, sessionStorage]) {
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        if (key != null) { haystacks.push(key); haystacks.push(storage.getItem(key) || ''); }
      }
    }
    if (typeof indexedDB.databases === 'function') {
      const databases = await indexedDB.databases();
      for (const info of databases) {
        if (!info.name) continue;
        const db = await new Promise((resolve, reject) => {
          const open = indexedDB.open(info.name);
          open.onsuccess = () => resolve(open.result);
          open.onerror = () => reject(open.error);
        }).catch(() => null);
        if (!db) continue;
        try {
          const stores = Array.from(db.objectStoreNames);
          for (const storeName of stores) {
            const rows = await new Promise((resolve, reject) => {
              const transaction = db.transaction(storeName, 'readonly');
              const request = transaction.objectStore(storeName).getAll();
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            }).catch(() => []);
            storageCounts.indexedDb += rows.length;
            visit(rows);
          }
        } finally { db.close(); }
      }
    }
    if ('caches' in window) {
      for (const cacheName of await caches.keys()) {
        const cache = await caches.open(cacheName);
        for (const request of await cache.keys()) {
          const response = await cache.match(request);
          if (response) {
            storageCounts.cacheEntries += 1;
            try { haystacks.push(await response.clone().text()); } catch (_) { /* binary cache entry */ }
          }
        }
      }
    }
    if (navigator.storage?.getDirectory) {
      async function walk(directory) {
        for await (const [name, handle] of directory.entries()) {
          haystacks.push(name);
          if (handle.kind === 'directory') await walk(handle);
          else {
            storageCounts.opfsFiles += 1;
            try { haystacks.push(await (await handle.getFile()).text()); } catch (_) { /* binary file */ }
          }
        }
      }
      try { await walk(await navigator.storage.getDirectory()); } catch (_) { /* unsupported or denied */ }
    }
    const cookies = document.cookie;
    if (cookies) haystacks.push(cookies);
    return {
      storageCounts,
      absentFromBrowserPersistence: patterns.every((pattern) => !haystacks.some((text) => text.includes(pattern))),
    };
  }, needles);
}

function searchFilesForNeedles(root, needles) {
  const found = new Set();
  if (!fs.existsSync(root)) return found;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      for (const match of searchFilesForNeedles(fullPath, needles)) found.add(match);
    } else if (entry.isFile()) {
      let bytes;
      try { bytes = fs.readFileSync(fullPath); } catch (_) { continue; }
      for (const needle of needles) {
        if (bytes.includes(Buffer.from(needle, 'utf8'))) found.add(needle);
      }
    }
  }
  return found;
}

function reportStatus(label, status) {
  console.log(`assert: ${label}_http_status=${status}`);
}

function reportBoolean(label, value) {
  console.log(`assert: ${label}=${value}`);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-recovery-'));
  fs.chmodSync(tempRoot, 0o700);
  dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  databasePath = path.join(dataDir, 'atermius.db');
  serverLogPath = path.join(tempRoot, 'server.log');
  serverLogFd = fs.openSync(serverLogPath, 'w', 0o600);
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
  username = `web-recovery-${crypto.randomUUID().slice(0, 8)}@example.test`;
  password = `Recovery-${crypto.randomBytes(32).toString('base64url')}`;

  try {
    setStage('isolated server startup');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: ['ignore', serverLogFd, serverLogFd],
    });
    await waitForServer(baseUrl, serverProcess);

    setStage('isolated instance bootstrap');
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
      maxBuffer: 4096,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    assertThat(!bootstrap.error && bootstrap.status === 0, 'isolated bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap credential unavailable');
    bootstrap.stdout = '';

    setStage('isolated Chromium context');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    browserContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await browserContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    const page = await browserContext.newPage();
    await installNetworkAndLogObservers(page, baseUrl);
    await page.addInitScript(() => {
      const clipboardPrototype = globalThis.Clipboard?.prototype;
      const original = clipboardPrototype
        ? Object.getOwnPropertyDescriptor(clipboardPrototype, 'writeText') : null;
      const metrics = { calls: -1, valueLength: -1, fulfilled: false };
      Object.defineProperty(window, '__atermiusRecoveryClipboardMetrics', {
        configurable: true,
        value: metrics,
      });
      if (!original || typeof original.value !== 'function' || !original.configurable) return;
      metrics.calls = 0;
      metrics.valueLength = 0;
      Object.defineProperty(clipboardPrototype, 'writeText', {
        ...original,
        value: function (value) {
          metrics.calls += 1;
          metrics.valueLength = typeof value === 'string' ? value.length : -1;
          metrics.fulfilled = false;
          return Promise.resolve()
            .then(() => Reflect.apply(original.value, this, [value]))
            .then((result) => {
              metrics.fulfilled = true;
              return result;
            }, (error) => {
              metrics.fulfilled = false;
              throw error;
            });
        },
      });
    });

    setStage('load current Flutter Web bundle');
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    setStage('wait for Flutter assets and semantics');
    await waitFor(() => page.evaluate(() => typeof window.sodium?.ready?.then === 'function'
      && Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    await page.evaluate(async () => { await window.sodium.ready; });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);

    setStage('configure server endpoint');
    await fill(page, 'Server URL', baseUrl);
    await click(page, 'Connect securely');
    await field(page, 'Owner email');

    setStage('register disposable Owner');
    setStage('owner registration email');
    await fill(page, 'Owner email', username);
    setStage('owner registration master password');
    await fill(page, 'Master password · 12+ characters', password);
    setStage('owner registration password confirmation');
    await fill(page, 'Confirm master password', password);
    setStage('owner registration bootstrap token');
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    setStage('owner registration device name');
    await fill(page, 'Device name', 'Recovery browser');
    setStage('owner registration first Vault');
    await fill(page, 'First Vault', 'Recovery acceptance');
    const registrationStart = apiEvents.length;
    setStage('owner registration submit');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    await button(page, 'Add host');
    const registration = await waitForEvent((event) => event.route === 'auth/register'
      && event.method === 'POST' && apiEvents.indexOf(event) >= registrationStart);
    assertThat(registration.status === 200, 'Owner registration failed');
    reportStatus('owner_registration', registration.status);

    setStage('open account recovery settings');
    await click(page, 'Settings');
    await button(page, 'Set up recovery');

    setStage('setup recovery from the Web UI');
    const setupStart = apiEvents.length;
    await click(page, 'Set up recovery');
    await fill(page, 'Current master password', password);
    await click(page, 'Continue');
    const setupEvent = await waitForEvent((event) => event.route === 'auth/recovery'
      && event.method === 'PUT' && apiEvents.indexOf(event) >= setupStart);
    assertThat(setupEvent.status === 200 && setupEvent.hasBearer,
      'recovery setup did not use the authenticated UI session');
    assertThat(setupEvent.generation === 1 && !setupEvent.hasPreviousRecoveryProof,
      'initial recovery generation or proof shape was incorrect');
    assertThat(!setupEvent.hasRecoveryCodeField, 'setup request contains a recovery-code field');
    reportStatus('recovery_setup', setupEvent.status);

    const firstCode = await readDisplayedCode(page);
    recoveryCodes.push(firstCode);
    await confirmDisplayedCode(page);
    setStage('wait for configured Recovery status in visible semantics');
    await waitFor(() => page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics')].some((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const visible = style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        return visible && ((element.innerText || '').includes('Recovery is current.') ||
          (element.textContent || '').includes('Recovery is current.') ||
          (element.getAttribute('aria-label') || '').includes('Recovery is current.'));
      })), 20000);
    const firstContexts = await waitForEvent((event) => event.route === 'auth/recovery/contexts'
      && event.method === 'GET' && event.generation === 1 && event.recoveryStatus === 'current'
      && event.presentContexts >= 1);
    assertThat(firstContexts.requiredContexts === firstContexts.presentContexts,
      'initial recovery setup left a required Vault keybox missing');
    reportBoolean('setup_keybox_coverage_complete', true);

    setStage('rotate recovery identity from the Web UI');
    const rotationStart = apiEvents.length;
    await click(page, 'Rotate recovery code');
    await fill(page, 'Current master password', password);
    await click(page, 'Continue');
    const rotationEvent = await waitForEvent((event) => event.route === 'auth/recovery'
      && event.method === 'PUT' && apiEvents.indexOf(event) >= rotationStart);
    assertThat(rotationEvent.status === 200 && rotationEvent.hasBearer,
      'recovery rotation did not use the authenticated UI session');
    assertThat(rotationEvent.generation === 2 && rotationEvent.hasPreviousRecoveryProof,
      'rotation did not advance generation with the previous Recovery identity proof');
    assertThat(!rotationEvent.hasRecoveryCodeField, 'rotation request contains a recovery-code field');
    reportStatus('recovery_rotation', rotationEvent.status);

    const nextCode = await readDisplayedCode(page);
    assertThat(nextCode !== firstCode, 'rotation reused the previous recovery code');
    recoveryCodes.push(nextCode);
    await confirmDisplayedCode(page);
    setStage('wait for rotated Recovery status in visible semantics');
    await waitFor(() => page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics')].some((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const visible = style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        return visible && ((element.innerText || '').includes('Recovery is current.') ||
          (element.textContent || '').includes('Recovery is current.') ||
          (element.getAttribute('aria-label') || '').includes('Recovery is current.'));
      })), 20000);
    const rotatedContexts = await waitForEvent((event) => event.route === 'auth/recovery/contexts'
      && event.method === 'GET' && event.generation === 2 && event.recoveryStatus === 'current'
      && event.presentContexts >= 1);
    assertThat(rotatedContexts.requiredContexts === firstContexts.requiredContexts
      && rotatedContexts.presentContexts === firstContexts.presentContexts,
    'rotation did not preserve full Vault keybox coverage');

    setStage('audit browser-visible recovery secret boundaries');
    const persistence = await scanBrowserPersistence(page, recoveryCodes);
    assertThat(persistence.absentFromBrowserPersistence,
      'a one-time recovery code was found in browser persistence');
    const networkContainsCode = browserWireBodies.some((body) => recoveryCodes.some((code) => body.includes(code)));
    const consoleContainsCode = browserConsoleMessages.some((message) => recoveryCodes.some((code) => message.includes(code)));
    assertThat(!networkContainsCode, 'a one-time recovery code appeared in a browser request or response body');
    assertThat(!consoleContainsCode, 'a one-time recovery code appeared in browser console output');
    const browserCookies = await browserContext.cookies(baseUrl);
    assertThat(!browserCookies.some((cookie) => recoveryCodes.some((code) => cookie.value.includes(code))),
      'a one-time recovery code appeared in a browser cookie');
    reportBoolean('recovery_codes_absent_from_network_logs_and_browser_persistence', true);
    reportBoolean('active_context_boxes_survived_rotation', true);
    assertThat(pageErrorCount === 0, 'Flutter emitted a runtime page error');

    setStage('stop disposable server and inspect its persistence');
    await stopServerGroup(serverProcess);
    serverProcess = undefined;
    if (serverLogFd !== undefined) {
      fs.closeSync(serverLogFd);
      serverLogFd = undefined;
    }
    const persistedLeaks = searchFilesForNeedles(tempRoot, recoveryCodes);
    assertThat(persistedLeaks.size === 0,
      'a one-time recovery code was found in the disposable server database or log');
    reportBoolean('recovery_codes_absent_from_server_database_and_logs', true);
    console.log(`assert: browser_persistence_scan=local:${persistence.storageCounts.local},session:${persistence.storageCounts.session},indexeddb_rows:${persistence.storageCounts.indexedDb},cache_entries:${persistence.storageCounts.cacheEntries},opfs_files:${persistence.storageCounts.opfsFiles}`);
    console.log(`assert: recovery_http_events=${JSON.stringify(apiEvents.filter((event) => event.route.startsWith('auth/recovery')).map(({ route, method, status, generation, recoveryStatus, presentContexts, requiredContexts, submittedBoxes, hasPreviousRecoveryProof, hasRecoveryCodeField }) => ({ route, method, status, generation, recoveryStatus, presentContexts, requiredContexts, submittedBoxes, hasPreviousRecoveryProof, hasRecoveryCodeField })))}`);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async (error) => {
  const rawErrorClass = error?.constructor?.name;
  const safeErrorClass = ['Error', 'TimeoutError', 'AssertionError'].includes(rawErrorClass)
    ? rawErrorClass : 'OtherError';
  console.error(`stage: failed (${stage}); error class=${safeErrorClass}`);
  console.error(`safe recovery events=${JSON.stringify(apiEvents.filter((event) => event.route.startsWith('auth/recovery')).map(({ route, method, status, generation, recoveryStatus, presentContexts, requiredContexts }) => ({ route, method, status, generation, recoveryStatus, presentContexts, requiredContexts })))}`);
  console.error(`safe fill diagnostics=${JSON.stringify(safeFillDiagnostics.slice(-10))}`);
  console.error(`safe copy diagnostics=${JSON.stringify(safeCopyDiagnostics)}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
