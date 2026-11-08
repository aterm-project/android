/*
 * WEB-ADMIN-AUDIT-01: bootstrap a disposable allowlisted administrator,
 * create a real instance audit event, and verify it through the Settings UI.
 * A separately invited non-admin profile must not render the admin audit card.
 * Output contains only stage names, HTTP statuses, and boolean assertions.
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
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const AUDIT_PAGINATION_ONLY = process.env.ATERMIUS_ADMIN_AUDIT_PAGINATION_ONLY === '1';

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let adminContext;
let memberContext;
let bootstrapToken;
let accountInvitationToken;
let adminUsername;
let adminPassword;
let memberUsername;
let memberPassword;
let adminAccessToken;
let cleanupPromise;
let cleanupFailed = false;
const safeApiStatuses = [];

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
  await new Promise((resolve, reject) => {
    listener.close((error) => error ? reject(error) : resolve());
  });
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
      // Continue polling while the loopback service starts.
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
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') {
        return true;
      }
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

async function restartAfterGenerationRecovery(serverEnv, baseUrl) {
  await stopServerGroup(serverProcess);
  serverProcess = undefined;
  const recovery = spawnSync(
    SERVER_BINARY,
    ['recover-generation', '--server-stopped'],
    {
      cwd: ROOT,
      env: serverEnv,
      timeout: 30000,
      stdio: 'ignore',
    },
  );
  assertThat(!recovery.error && recovery.status === 0,
    'isolated offline generation recovery failed');
  serverProcess = spawn(SERVER_BINARY, ['serve'], {
    cwd: ROOT,
    env: serverEnv,
    detached: true,
    stdio: 'ignore',
  });
  await waitForServer(baseUrl, serverProcess);
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    accountInvitationToken = undefined;
    adminUsername = undefined;
    adminPassword = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    adminAccessToken = undefined;
    try {
      for (const page of adminContext?.pages() || []) {
        await page.evaluate(async () => {
          try { await navigator.clipboard.writeText(''); } catch (_) {}
        }).catch(() => {});
      }
      if (adminContext) await adminContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
      await stopServerGroup(serverProcess);
    } catch (_) {
      cleanupFailed = true;
    } finally {
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

process.once('SIGINT', () => {
  void cleanup().finally(() => process.exit(130));
});
process.once('SIGTERM', () => {
  void cleanup().finally(() => process.exit(143));
});

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

async function clickOneTimeCredentialCopy(page) {
  const locator = page.getByRole('button', {
    name: /^(Copy credential|Copy failed; select the value manually|Copied)$/,
  }).first();
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  await locator.click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 35 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
}

async function waitForText(page, text, timeoutMs = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible',
    timeout: timeoutMs,
  });
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    const visibleText = nodes.filter((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    }).map((element) => {
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`;
    }).join('\n');
    return visibleText.includes(expected);
  }, needle);
}

async function hasVisibleOneTimeCredentialValue(page) {
  return page.evaluate(() => {
    const credentialPattern = /atm_[A-Za-z0-9_-]{43}/;
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) {
        return false;
      }
      const attributes = [...element.attributes]
        .map((attribute) => attribute.value);
      return [element.textContent || '', ...attributes]
        .some((value) => credentialPattern.test(value));
    });
  });
}

async function rejectNextBrowserClipboardWrite(page) {
  return page.evaluate(() => {
    const clipboard = navigator.clipboard;
    if (!clipboard || typeof clipboard.writeText !== 'function') return false;
    const marker = '__atermiusTestClipboardWriteRejected';
    Object.defineProperty(window, marker, {
      configurable: true,
      writable: true,
      value: false,
    });
    try {
      Object.defineProperty(clipboard, 'writeText', {
        configurable: true,
        value: async () => {
          delete clipboard.writeText;
          window[marker] = true;
          throw new DOMException(
            'Blocked by the isolated clipboard acceptance fixture',
            'NotAllowedError',
          );
        },
      });
      return true;
    } catch (_) {
      delete window[marker];
      return false;
    }
  });
}

async function scrollToAuditLabel(page, label) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (await hasVisibleSemanticText(page, label)) return true;
    await page.mouse.wheel(0, 650);
    await page.waitForTimeout(80);
  }
  return hasVisibleSemanticText(page, label);
}

function cliToken(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `isolated ${description} failed`);
  const token = (result.stdout || '').trim().split(/\s+/).at(-1);
  result.stdout = '';
  assertThat(typeof token === 'string' && token.length >= 40,
    `isolated ${description} credential is unavailable`);
  return token;
}

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === '/api/v1/admin/audit') return 'admin-audit';
    if (pathname === '/api/v1/admin/metrics-credential') return 'admin-metrics-credential';
  } catch (_) {
    // Ignore non-URL and browser-internal requests.
  }
  return null;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    byRequest.set(request, {
      route,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      hasCursor: route === 'admin-audit' &&
        new URL(request.url()).searchParams.has('cursor'),
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    const payloadState = { parsed: null, parseErrorType: null, keys: null };
    const payloadPromise = response.json().then((payload) => {
      payloadState.parsed = true;
      if (metadata.route === 'admin-audit') {
        payloadState.keys = payload && typeof payload === 'object' && !Array.isArray(payload)
          ? Object.keys(payload).sort()
          : [];
      }
      if (metadata.route === 'admin-metrics-credential' && metadata.method === 'POST') {
        const credential = payload?.credential;
        return {
          credentialShapeValid: typeof credential === 'string' &&
            /^atm_[A-Za-z0-9_-]{43}$/.test(credential),
          createdAtValid: typeof payload?.created_at === 'string' &&
            !Number.isNaN(Date.parse(payload.created_at)),
          exactFields: payload && Object.keys(payload).sort().join(',') ===
            'created_at,credential',
        };
      }
      return payload;
    }).catch((error) => {
      payloadState.parsed = false;
      payloadState.parseErrorType = error?.name || 'Error';
      return null;
    });
    events.push({
      ...metadata,
      status: response.status(),
      contentType: response.headers()['content-type'] || '',
      payloadState,
      sequence: events.length,
      payloadPromise,
    });
    safeApiStatuses.push({ route: metadata.route, status: response.status() });
    if (safeApiStatuses.length > 10) safeApiStatuses.shift();
  });
}

async function waitForEvent(events, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected API response did not arrive');
}

async function advanceAdminAuditUntilActions(page, events, firstResponse, actions, scope) {
  let response = firstResponse;
  let payload = await response.payloadPromise;
  let pageNumber = 1;
  const hasActions = (candidate) => Array.isArray(candidate?.events) &&
    actions.every((action) => candidate.events.some((event) => event.action === action));
  while (!hasActions(payload)) {
    assertThat(pageNumber < 100 && await (await button(page, 'Next')).isEnabled(),
      `${scope} audit actions were absent and no next page was available`);
    const requestStart = events.length;
    await click(page, 'Next');
    response = await waitForEvent(events, (event) => event.route === 'admin-audit' &&
      event.sequence >= requestStart && event.hasCursor);
    payload = await response.payloadPromise;
    pageNumber += 1;
    assertThat(response.status === 200 && response.hasBearer &&
        Array.isArray(payload?.events),
      `${scope} audit page response was invalid`);
    await waitFor(() => hasVisibleSemanticText(page, `Page ${pageNumber}`));
  }
  return { response, payload, pageNumber };
}

async function fetchAllInstanceAdminAuditPages(baseUrl, bearerToken) {
  const events = [];
  let cursor;
  let pageCount = 0;
  let hasMore = true;
  while (hasMore) {
    assertThat(pageCount < 100, 'instance audit fixture exceeded the page safety bound');
    const query = new URLSearchParams({ limit: '100' });
    if (cursor) query.set('cursor', cursor);
    const response = await jsonRequest(
      baseUrl, 'GET', `/api/v1/admin/audit?${query.toString()}`, bearerToken);
    assertThat(response.status === 200 && Array.isArray(response.body?.events) &&
        typeof response.body?.has_more === 'boolean',
      'instance audit API returned an invalid page while traversing its cursor');
    events.push(...response.body.events);
    hasMore = response.body.has_more;
    cursor = response.body.next_cursor;
    pageCount += 1;
    assertThat(!hasMore || (typeof cursor === 'string' && cursor.length > 0),
      'instance audit API omitted its next cursor');
  }
  return { status: 200, pageCount, events };
}

async function rotateScrapeCredentialFromSettings(
  page, events, buttonLabel, injectClipboardFailure = false) {
  const requestStart = events.length;
  await click(page, buttonLabel);
  const confirm = page.getByRole('button', { name: 'Rotate credential', exact: true }).last();
  await confirm.waitFor({ state: 'visible', timeout: 10000 });
  await confirm.click();
  const event = await waitForEvent(events, (candidate) =>
    candidate.route === 'admin-metrics-credential' &&
    candidate.method === 'POST' && candidate.sequence >= requestStart);
  const result = await event.payloadPromise;
  assertThat(event.status === 200 && result?.exactFields === true &&
      result?.credentialShapeValid === true && result?.createdAtValid === true,
    'Settings did not rotate the scrape credential with the exact one-time response shape');
  setStage('wait for one-time credential dialog');
  await waitFor(() => hasVisibleSemanticText(page, 'Save this credential now'), 10000);
  const clipboardCapabilities = await page.evaluate(async () => {
    const query = async (name) => {
      try {
        return (await navigator.permissions.query({ name })).state;
      } catch (error) {
        return error?.name || 'unavailable';
      }
    };
    return {
      secureContext: window.isSecureContext,
      apiAvailable: Boolean(navigator.clipboard),
      pageFocused: document.hasFocus(),
      readPermission: await query('clipboard-read'),
      writePermission: await query('clipboard-write'),
    };
  });
  try {
    if (injectClipboardFailure) {
      setStage('install isolated browser clipboard rejection');
      assertThat(await rejectNextBrowserClipboardWrite(page),
        'browser clipboard failure fixture could not be installed');
      setStage('click one-time credential copy button and trigger rejection');
      await clickOneTimeCredentialCopy(page);
      setStage('verify manual-selection fallback after browser clipboard rejection');
      await waitFor(async () => {
        const [rejectionObserved, manualSelectionHintVisible,
          credentialValueVisible, retryButtonVisible] = await Promise.all([
          page.evaluate(() =>
            window.__atermiusTestClipboardWriteRejected === true),
          hasVisibleSemanticText(
            page, 'If copying is unavailable, select the value above.'),
          hasVisibleOneTimeCredentialValue(page),
          page.getByRole('button', {
            name: /^(Copy credential|Copy failed; select the value manually)$/,
          }).first().isVisible().catch(() => false),
        ]);
        return rejectionObserved && manualSelectionHintVisible &&
          credentialValueVisible && retryButtonVisible;
      }, 10000);
      const failureSurface = {
        rejectionObserved: await page.evaluate(() =>
          window.__atermiusTestClipboardWriteRejected === true),
        failureVisible: await hasVisibleSemanticText(
          page, 'Copy failed; select the value manually'),
        manualSelectionHintVisible: await hasVisibleSemanticText(
          page, 'If copying is unavailable, select the value above.'),
        copiedVisible: await hasVisibleSemanticText(page, 'Copied'),
        retryButtonVisible: await page.getByRole('button', {
          name: /^(Copy credential|Copy failed; select the value manually)$/,
        }).first().isVisible().catch(() => false),
        credentialValueVisible: await hasVisibleOneTimeCredentialValue(page),
        credentialDialogVisible: await hasVisibleSemanticText(
          page, 'Save this credential now'),
      };
      console.log(`assert: clipboard_failure_fallback=${JSON.stringify(failureSurface)}`);
      assertThat(failureSurface.rejectionObserved &&
          failureSurface.manualSelectionHintVisible &&
          !failureSurface.copiedVisible && failureSurface.retryButtonVisible &&
          failureSurface.credentialValueVisible && failureSurface.credentialDialogVisible,
        'browser clipboard rejection did not preserve an accessible selectable retry state');
      setStage('retry one-time credential copy after browser rejection');
      await clickOneTimeCredentialCopy(page);
    } else {
      setStage('click one-time credential copy button');
      await clickOneTimeCredentialCopy(page);
    }
    setStage('wait for one-time credential retry result');
    await waitFor(async () => {
      const [copied, copyFailed] = await Promise.all([
        hasVisibleSemanticText(page, 'Copied'),
        hasVisibleSemanticText(page, 'Copy failed; select the value manually'),
      ]);
      return copied || copyFailed;
    }, 10000);
    const [copiedLabelVisible, copyFailureVisible] = await Promise.all([
      hasVisibleSemanticText(page, 'Copied'),
      hasVisibleSemanticText(page, 'Copy failed; select the value manually'),
    ]);
    reportBoolean('clipboard_copy_failed_visible', copyFailureVisible);
    assertThat(copiedLabelVisible && !copyFailureVisible,
      'one-time credential copy did not complete successfully');
    setStage('read copied credential and validate shape');
    const credential = await page.evaluate(async () => navigator.clipboard.readText());
    const credentialShapeValid = /^atm_[A-Za-z0-9_-]{43}$/.test(credential);
    if (!credentialShapeValid) {
      console.log(`assert: clipboard_copy_diagnostics=${JSON.stringify({
        ...clipboardCapabilities,
        copiedLabelVisible: true,
        credentialShapeValid,
        clipboardLength: credential.length,
      })}`);
      throw new Error('Settings did not copy a valid one-time scrape credential');
    }
    setStage('clear copied credential from browser clipboard');
    await page.evaluate(async () => navigator.clipboard.writeText(''));
    setStage('verify browser clipboard was cleared');
    let clipboardReadAttempts = 0;
    try {
      await waitFor(async () => {
        clipboardReadAttempts += 1;
        return await page.evaluate(async () =>
          (await navigator.clipboard.readText()) === '');
      }, 3000);
    } catch (_) {
      console.log(`assert: clipboard_clear_diagnostics=${JSON.stringify({
        ...clipboardCapabilities,
        copiedLabelVisible: true,
        credentialShapeValid,
        clipboardReadAttempts,
        clipboardCleared: false,
      })}`);
      throw new Error('acceptance runner could not verify browser clipboard cleanup');
    }
    setStage('browser clipboard cleanup verified');
    return credential;
  } catch (error) {
    const rejectionObserved = await page.evaluate(() =>
      window.__atermiusTestClipboardWriteRejected === true).catch(() => false);
    const copySurface = {
      rejectionObserved,
      copiedLabelVisible: await page.getByRole('button', {
        name: 'Copied', exact: true,
      }).first().isVisible().catch(() => false),
      copyFailureVisible: await hasVisibleSemanticText(
        page, 'Copy failed; select the value manually').catch(() => false),
      copyButtonVisible: await page.getByRole('button', {
        name: 'Copy credential', exact: true,
      }).first().isVisible().catch(() => false),
      copyButtonText: await page.getByRole('button', {
        name: 'Copy credential', exact: true,
      }).first().textContent().catch(() => null),
      credentialDialogVisible: await hasVisibleSemanticText(page, 'Save this credential now')
        .catch(() => false),
    };
    console.log(`assert: clipboard_failure_diagnostics=${JSON.stringify({
      ...clipboardCapabilities,
      failureStage: stage,
      failureType: error?.name || 'Error',
      ...copySurface,
    })}`);
    throw error;
  }
}

async function scrapeMetrics(baseUrl, credential) {
  const response = await fetch(`${baseUrl}/api/v1/admin/metrics`, {
    headers: { authorization: `Bearer ${credential}`, accept: 'text/plain' },
    signal: AbortSignal.timeout(15000),
  });
  const body = await response.text();
  const metricLines = body.split('\n').filter((line) => line && !line.startsWith('#'));
  const pushResultLines = metricLines.filter((line) =>
    line.startsWith('atermius_mobile_push_send_results_total{'));
  const expectedPushSeries = new Set([
    'apns:accepted',
    'apns:invalid_token',
    'apns:retryable_failure',
    'fcm_v1:accepted',
    'fcm_v1:invalid_token',
    'fcm_v1:retryable_failure',
  ]);
  const observedPushSeries = new Set();
  let pushResultSeriesValid = pushResultLines.length === expectedPushSeries.size;
  for (const line of pushResultLines) {
    const match = line.match(
      /^atermius_mobile_push_send_results_total\{provider="(apns|fcm_v1)",outcome="(accepted|invalid_token|retryable_failure)"\} ([0-9]+)$/,
    );
    if (!match) {
      pushResultSeriesValid = false;
      continue;
    }
    const key = `${match[1]}:${match[2]}`;
    if (observedPushSeries.has(key)) pushResultSeriesValid = false;
    observedPushSeries.add(key);
  }
  if (observedPushSeries.size !== expectedPushSeries.size ||
      [...expectedPushSeries].some((series) => !observedPushSeries.has(series))) {
    pushResultSeriesValid = false;
  }
  return {
    status: response.status,
    contentTypeValid: (response.headers.get('content-type') || '').includes('version=0.0.4'),
    noStore: response.headers.get('cache-control') === 'no-store',
    fixedSeriesCount: metricLines.length,
    pushResultSeriesCount: pushResultLines.length,
    pushResultSeriesValid,
  };
}

async function exerciseScrapeCredentialSettings(page, baseUrl, adminToken, events) {
  setStage('create one-time Prometheus scrape credential in Settings');
  const first = await rotateScrapeCredentialFromSettings(
    page, events, 'Create credential', true);
  setStage('verify first scrape credential endpoint scope');
  const firstMetrics = await scrapeMetrics(baseUrl, first);
  assertThat(firstMetrics.status === 200 && firstMetrics.contentTypeValid &&
      firstMetrics.noStore && firstMetrics.fixedSeriesCount === 20 &&
      firstMetrics.pushResultSeriesCount === 6 && firstMetrics.pushResultSeriesValid,
    'dedicated scrape credential did not read the fixed aggregate metrics contract');
  setStage('verify scrape credential cannot read admin overview');
  const wrongScope = await jsonRequest(
    baseUrl, 'GET', '/api/v1/admin/overview', first);
  assertThat(wrongScope.status === 401,
    'dedicated scrape credential was accepted outside the metrics endpoint');
  const auditBeforeCredentialAdminAttempts = await fetchAllInstanceAdminAuditPages(
    baseUrl, adminToken);
  const auditActionCount = auditBeforeCredentialAdminAttempts.events.filter((event) =>
    ['admin.metrics_credential_rotated', 'admin.metrics_credential_revoked'].includes(event.action)).length;
  const credentialStatusWithScrapeToken = await jsonRequest(
    baseUrl, 'GET', '/api/v1/admin/metrics-credential', first);
  const rotateWithScrapeToken = await jsonRequest(
    baseUrl, 'POST', '/api/v1/admin/metrics-credential', first);
  const revokeWithScrapeToken = await jsonRequest(
    baseUrl, 'DELETE', '/api/v1/admin/metrics-credential', first);
  const auditAfterCredentialAdminAttempts = await fetchAllInstanceAdminAuditPages(
    baseUrl, adminToken);
  const auditActionCountAfterAttempts = auditAfterCredentialAdminAttempts.events.filter((event) =>
      ['admin.metrics_credential_rotated', 'admin.metrics_credential_revoked'].includes(event.action)).length;
  assertThat(credentialStatusWithScrapeToken.status === 401 &&
      rotateWithScrapeToken.status === 401 && revokeWithScrapeToken.status === 401 &&
      auditActionCountAfterAttempts === auditActionCount &&
      (await scrapeMetrics(baseUrl, first)).status === 200,
    'scrape credential gained management access or changed credential state/audit history');

  await click(page, "I've saved it");
  setStage('verify first scrape credential is hidden after dismissal');
  await waitFor(async () => !(await hasVisibleSemanticText(page, first)), 5000);
  assertThat(!(await hasVisibleSemanticText(page, first)),
    'one-time credential remained visible after the dialog closed');

  setStage('rotate scrape credential and reject the previous value');
  const second = await rotateScrapeCredentialFromSettings(page, events, 'Rotate credential');
  const oldMetrics = await scrapeMetrics(baseUrl, first);
  const newMetrics = await scrapeMetrics(baseUrl, second);
  assertThat(oldMetrics.status === 401 && newMetrics.status === 200,
    'rotation did not immediately invalidate only the previous scrape credential');
  await click(page, "I've saved it");
  setStage('verify rotated scrape credential is hidden after dismissal');
  await waitFor(async () => !(await hasVisibleSemanticText(page, second)), 5000);
  assertThat(!(await hasVisibleSemanticText(page, second)),
    'rotated one-time credential remained visible after the dialog closed');

  setStage('revoke scrape credential and verify audit privacy');
  await click(page, 'Revoke credential');
  const confirmRevoke = page.getByRole('button', { name: 'Revoke credential', exact: true }).last();
  await confirmRevoke.waitFor({ state: 'visible', timeout: 10000 });
  const deleteStart = events.length;
  setStage('submit scrape credential revocation');
  await confirmRevoke.click();
  const deleted = await waitForEvent(events, (candidate) =>
    candidate.route === 'admin-metrics-credential' &&
    candidate.method === 'DELETE' && candidate.sequence >= deleteStart);
  const deletion = await deleted.payloadPromise;
  reportStatus('scrape_credential_revoke', deleted.status);
  reportBoolean('scrape_credential_revoke_response_valid', deletion?.revoked === true);
  setStage('verify revoked scrape credential is rejected');
  assertThat(deleted.status === 200 && deletion?.revoked === true,
    'Settings did not revoke the current scrape credential');
  const revokedMetrics = await scrapeMetrics(baseUrl, second);
  reportStatus('revoked_scrape_credential_metrics', revokedMetrics.status);
  assertThat(revokedMetrics.status === 401,
    'revoked scrape credential remained usable');

  setStage('verify scrape credential lifecycle audit privacy');
  const audit = await fetchAllInstanceAdminAuditPages(baseUrl, adminToken);
  const actions = audit.events.filter((event) =>
    ['admin.metrics_credential_rotated', 'admin.metrics_credential_revoked'].includes(event.action));
  const expectedActions = actions.filter((event) =>
    event.action === 'admin.metrics_credential_rotated').length === 2 &&
    actions.filter((event) =>
      event.action === 'admin.metrics_credential_revoked').length === 1;
  const safeAuditRows = actions.length === 3 && actions.every((event) =>
    event.resource_type === 'metrics_credential' && event.resource_id === null &&
    event.result === 'success');
  const serializedAudit = JSON.stringify(actions);
  reportBoolean('scrape_credential_audit_rows_valid',
    audit.status === 200 && expectedActions && safeAuditRows &&
      !serializedAudit.includes(first) && !serializedAudit.includes(second));
  assertThat(audit.status === 200 && expectedActions && safeAuditRows &&
      !serializedAudit.includes(first) && !serializedAudit.includes(second),
    'scrape credential audit events were missing or contained credential material');
  setStage('verify scrape credentials remain hidden after revocation');
  assertThat(!(await hasVisibleSemanticText(page, first)) &&
      !(await hasVisibleSemanticText(page, second)),
    'Settings retained a scrape credential after dismissal and revocation');
  reportStatus('scrape_credential_rotate_and_revoke', deleted.status);
  reportBoolean('scrape_credential_scope_rotation_copy_audit', true);
}

async function configurePage(page, baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function createAdminAccount(page, baseUrl, apiEvents) {
  setStage('open Flutter Web for administrator registration');
  await configurePage(page, baseUrl);
  setStage('wait for owner registration form');
  await field(page, 'Owner email');
  setStage('fill administrator email');
  await fill(page, 'Owner email', adminUsername);
  setStage('fill administrator master password');
  await fill(page, 'Master password · 12+ characters', adminPassword);
  setStage('fill administrator password confirmation');
  await fill(page, 'Confirm master password', adminPassword);
  setStage('fill bootstrap credential');
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  setStage('fill administrator device name');
  await fill(page, 'Device name', 'Admin audit acceptance');
  setStage('fill administrator Vault name');
  await fill(page, 'First Vault', 'Admin audit acceptance');
  const start = apiEvents.length;
  setStage('submit allowlisted administrator registration');
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  setStage('wait for allowlisted administrator workspace');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  setStage('read allowlisted registration response');
  const register = await waitForEvent(apiEvents,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await register.payloadPromise;
  assertThat(register.status >= 200 && register.status < 300 && payload,
    'allowlisted administrator registration was rejected');
  assertThat(typeof payload.account_id === 'string' &&
      typeof payload.access_token === 'string' &&
      typeof payload.device_id === 'string' &&
      Array.isArray(payload.vaults) && typeof payload.vaults[0]?.vault_id === 'string',
    'admin registration response omitted session fixture fields');
  adminAccessToken = payload.access_token;
  reportStatus('allowlisted_registration', register.status);
  return {
    accountId: payload.account_id,
    deviceId: payload.device_id,
    vaultId: payload.vaults[0].vault_id,
  };
}

async function jsonRequest(baseUrl, method, pathname, token, body) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

function validateInstanceAdminAuditEvent(event, expected) {
  const fields = [
    'action', 'actor_device_id', 'actor_user_id', 'event_id', 'occurred_at',
    'resource_id', 'resource_type', 'result', 'scope', 'source',
  ].sort();
  assertThat(event && Object.keys(event).sort().join(',') === fields.join(','),
    'instance audit event DTO fields changed');
  assertThat(event.scope === 'instance' && event.action === expected.action &&
      event.resource_type === expected.resourceType && event.result === 'success' &&
      event.source === expected.source && typeof event.occurred_at === 'string' &&
      /^[0-9a-f]{64}$/.test(event.resource_id),
    'instance audit event scope, action or HMAC resource metadata was invalid');
  assertThat(event.actor_user_id === expected.actorUserId &&
      event.actor_device_id === expected.actorDeviceId,
    'instance audit event actor metadata was invalid');
  if (expected.rawResourceId) {
    assertThat(event.resource_id !== expected.rawResourceId,
      'instance audit event exposed a raw resource identifier');
  }
  return true;
}

function reportStatus(assertion, status) {
  console.log(`assert: ${assertion}_http_status=${status}`);
}

function reportBoolean(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-audit-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    adminUsername = `web-admin-audit-${crypto.randomUUID().slice(0, 8)}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-audit-member-${crypto.randomUUID().slice(0, 8)}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };
    const apiEvents = [];
    let pageErrorCount = 0;

    setStage('start disposable allowlisted instance');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch Chromium profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await adminContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    const adminPage = await adminContext.newPage();
    adminPage.on('pageerror', () => { pageErrorCount += 1; });
    trackApi(adminPage, apiEvents);

    setStage('register allowlisted administrator in Flutter Web');
    const admin = await createAdminAccount(adminPage, baseUrl, apiEvents);
    const listed = await jsonRequest(baseUrl, 'GET', '/api/v1/admin/vaults?limit=1&offset=0', adminAccessToken);
    assertThat(listed.status === 200 && Array.isArray(listed.body?.vaults) && listed.body.vaults.length === 1,
      'instance admin Vault fixture could not be read');
    const quotaBytes = listed.body.vaults[0].quota_bytes;
    assertThat(Number.isSafeInteger(quotaBytes) && quotaBytes > 0, 'admin Vault quota fixture was invalid');

    setStage('create real admin Vault quota audit event');
    const quotaWrite = await jsonRequest(baseUrl, 'PUT',
      `/api/v1/admin/vaults/${admin.vaultId}/quota`, adminAccessToken, { quota_bytes: quotaBytes });
    reportStatus('real_quota_write', quotaWrite.status);
    assertThat(quotaWrite.status === 200, 'real quota write did not create an audit event');
    const profile = await jsonRequest(baseUrl, 'GET', '/api/v1/me', adminAccessToken);
    reportStatus('allowlisted_profile', profile.status);
    reportBoolean('profile_instance_admin_policy', profile.body?.policy?.instance_admin === true);
    assertThat(profile.status === 200 && profile.body?.policy?.instance_admin === true,
      'allowlisted registration did not receive instance admin policy');
    listed.body = undefined;

    setStage('create enough real audit events for admin pagination');
    for (let index = 0; index < 101; index += 1) {
      const eventWrite = await jsonRequest(baseUrl, 'PUT',
        `/api/v1/admin/vaults/${admin.vaultId}/quota`, adminAccessToken,
        { quota_bytes: quotaBytes });
      assertThat(eventWrite.status === 200,
        'could not create the audit rows needed to exercise admin pagination');
    }
    reportBoolean('admin_audit_pagination_fixture_created', true);

    setStage('navigate allowlisted administrator to Settings');
    await click(adminPage, 'Settings');
    setStage('verify Settings page navigation');
    await adminPage.waitForTimeout(500);
    const settingsDiagnostics = await adminPage.evaluate(() => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const visibleText = `${document.body.innerText || ''}\n${semantics}`;
      return {
        workspaceSettingsPresent: visibleText.includes('Workspace settings'),
        auditCardPresent: visibleText.includes('Instance admin audit'),
        metricsCredentialCardPresent: visibleText.includes('Prometheus scrape credential'),
        overviewCardPresent: visibleText.includes('Instance admin overview'),
        vaultCardPresent: visibleText.includes('Instance Vault quotas'),
        settingsNavPresent: visibleText.includes('Settings'),
      };
    });
    for (const [key, value] of Object.entries(settingsDiagnostics)) {
      reportBoolean(`settings_dom_${key}`, value);
    }
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Workspace settings'), 15000);
    setStage('inspect administrator card visibility');
    const overviewCardVisible = await hasVisibleSemanticText(adminPage, 'Instance admin overview');
    const vaultCardVisible = await hasVisibleSemanticText(adminPage, 'Instance Vault quotas');
    const adminAuditCardVisible = await hasVisibleSemanticText(adminPage, 'Instance admin audit');
    const metricsCredentialCardVisible = await hasVisibleSemanticText(
      adminPage, 'Prometheus scrape credential');
    reportBoolean('admin_overview_card_visible', overviewCardVisible);
    reportBoolean('admin_vault_card_visible', vaultCardVisible);
    reportBoolean('admin_audit_card_visible', adminAuditCardVisible);
    reportBoolean('admin_metrics_credential_card_visible', metricsCredentialCardVisible);
    assertThat(overviewCardVisible && vaultCardVisible && adminAuditCardVisible &&
        metricsCredentialCardVisible,
      'allowlisted instance admin cards were not visible in Settings');
    if (AUDIT_PAGINATION_ONLY) {
      reportBoolean('metrics_credential_ui_skipped_for_focused_audit_acceptance', true);
    } else {
      await exerciseScrapeCredentialSettings(adminPage, baseUrl, adminAccessToken, apiEvents);
    }
    const loadStart = apiEvents.length;
    setStage('click Load admin audit');
    await click(adminPage, 'Load admin audit');
    setStage('wait for authenticated admin audit response');
    const firstResponse = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' && event.sequence >= loadStart);
    const firstPayload = await firstResponse.payloadPromise;
    reportStatus('admin_audit_page', firstResponse.status);
    setStage('validate admin audit page response');
    console.log(`assert: admin_audit_first_page_shape=${JSON.stringify({
      hasBearer: firstResponse.hasBearer,
      eventCount: firstPayload?.events?.length ?? null,
      hasMore: typeof firstPayload?.has_more === 'boolean'
        ? firstPayload.has_more : null,
    })}`);
    const validPageShape = firstResponse.status === 200 && firstResponse.hasBearer &&
      firstPayload && Array.isArray(firstPayload.events) &&
      typeof firstPayload.has_more === 'boolean' &&
      firstPayload.events.length === 100 && firstPayload.has_more === true;
    reportBoolean('admin_audit_page_shape_valid', Boolean(validPageShape));
    assertThat(validPageShape,
      'Settings did not load the real first-page admin audit response');
    if (!AUDIT_PAGINATION_ONLY) {
      const completeAudit = await fetchAllInstanceAdminAuditPages(baseUrl, adminAccessToken);
      const metricsCredentialEvents = completeAudit.events.filter((event) =>
        ['admin.metrics_credential_rotated', 'admin.metrics_credential_revoked'].includes(event.action));
      const metricsCredentialAuditValid = metricsCredentialEvents.length === 3 &&
        metricsCredentialEvents.filter((event) =>
          event.action === 'admin.metrics_credential_rotated').length === 2 &&
        metricsCredentialEvents.filter((event) =>
          event.action === 'admin.metrics_credential_revoked').length === 1 &&
        metricsCredentialEvents.every((event) => event.scope === 'instance' &&
          event.resource_type === 'metrics_credential' && event.resource_id === null &&
          event.result === 'success' && event.source === 'api' &&
          event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId);
      reportBoolean('scrape_credential_audit_events_found_across_pages',
        metricsCredentialEvents.length === 3);
      assertThat(metricsCredentialAuditValid,
        'admin audit feed omitted safe scrape credential lifecycle events');
    }
    const quotaEvent = firstPayload.events.find((event) => event.action === 'admin.vault_quota_set');
    const targetEventFound = Boolean(quotaEvent);
    const actorAndResourceValid = quotaEvent && quotaEvent.scope === 'instance' &&
        quotaEvent.actor_user_id === admin.accountId &&
        quotaEvent.actor_device_id === admin.deviceId &&
        quotaEvent.resource_type === 'vault' && quotaEvent.result === 'success' &&
        quotaEvent.source === 'api' && typeof quotaEvent.resource_id === 'string' &&
        /^[0-9a-f]{64}$/.test(quotaEvent.resource_id) && quotaEvent.resource_id !== admin.vaultId;
    reportBoolean('quota_action_event_found', targetEventFound);
    reportBoolean('quota_event_actor_and_hmac_valid', Boolean(actorAndResourceValid));
    assertThat(actorAndResourceValid,
      'admin feed omitted the expected actor/action or exposed an unprotected Vault ID');
    setStage('render localized admin audit action in Settings card');
    await waitFor(() => hasVisibleSemanticText(adminPage, '管理员已更改 Vault 配额'));
    const localizedActionVisible = await hasVisibleSemanticText(
      adminPage, '管理员已更改 Vault 配额');
    const rawActionVisible = await hasVisibleSemanticText(adminPage, 'admin.vault_quota_set');
    reportBoolean('admin_audit_action_localized', localizedActionVisible);
    reportBoolean('admin_audit_action_key_hidden', !rawActionVisible);
    reportBoolean('admin_audit_actor_and_hmac_payload_validated', Boolean(actorAndResourceValid));
    assertThat(localizedActionVisible && !rawActionVisible,
      'Settings did not render the quota audit action through its localized label');

    setStage('refresh instance admin audit');
    const refreshButton = await button(adminPage, 'Refresh admin audit');
    const refreshStart = apiEvents.length;
    await refreshButton.click();
    const refreshed = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' && event.sequence >= refreshStart);
    const refreshedPayload = await refreshed.payloadPromise;
    assertThat(refreshed.status === 200 && refreshed.hasBearer &&
        refreshedPayload?.events?.some((event) => event.action === 'admin.vault_quota_set'),
      'admin audit refresh did not reload the instance feed');
    reportStatus('admin_audit_refresh', refreshed.status);
    reportBoolean('admin_audit_refresh_kept_event', true);

    setStage('open the second instance admin audit page');
    const nextPageButton = await button(adminPage, 'Next');
    assertThat(await nextPageButton.isEnabled(),
      'instance admin audit did not enable Next when more events were available');
    const nextPageStart = apiEvents.length;
    await nextPageButton.click();
    const secondPageResponse = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' &&
        event.sequence >= nextPageStart && event.hasCursor);
    const secondPagePayload = await secondPageResponse.payloadPromise;
    assertThat(secondPageResponse.status === 200 && secondPageResponse.hasBearer &&
        Array.isArray(secondPagePayload?.events) &&
        secondPagePayload.events.length > 0 && secondPagePayload.events.length < 100 &&
        secondPagePayload.has_more === false,
      'instance admin audit did not return the final cursor page');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Page 2'));
    if (!AUDIT_PAGINATION_ONLY) {
      const rotateActionLocalized = await hasVisibleSemanticText(
        adminPage, '管理员已轮换 Prometheus 抓取凭据');
      const revokeActionLocalized = await hasVisibleSemanticText(
        adminPage, '管理员已撤销 Prometheus 抓取凭据');
      const rawRotateActionVisible = await hasVisibleSemanticText(
        adminPage, 'admin.metrics_credential_rotated');
      const rawRevokeActionVisible = await hasVisibleSemanticText(
        adminPage, 'admin.metrics_credential_revoked');
      reportBoolean('scrape_credential_audit_actions_localized',
        rotateActionLocalized && revokeActionLocalized);
      reportBoolean('scrape_credential_audit_action_keys_hidden',
        !rawRotateActionVisible && !rawRevokeActionVisible);
      assertThat(rotateActionLocalized && revokeActionLocalized &&
          !rawRotateActionVisible && !rawRevokeActionVisible,
        'Settings did not localize and safely render scrape credential audit rows');
    }
    const previousPageButton = await button(adminPage, 'Previous');
    assertThat(await previousPageButton.isEnabled() &&
        !(await (await button(adminPage, 'Next')).isEnabled()),
      'instance admin audit navigation did not reflect the final page');
    reportStatus('admin_audit_second_page', secondPageResponse.status);
    reportBoolean('admin_audit_second_page_navigation', true);

    setStage('return to the first instance admin audit page');
    const previousPageStart = apiEvents.length;
    await previousPageButton.click();
    const previousPageResponse = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' &&
        event.sequence >= previousPageStart && !event.hasCursor);
    const previousPagePayload = await previousPageResponse.payloadPromise;
    assertThat(previousPageResponse.status === 200 && previousPageResponse.hasBearer &&
        previousPagePayload?.events?.length === 100 &&
        previousPagePayload.has_more === true,
      'Previous did not restore the first instance admin audit page');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Page 1'));

    setStage('rotate instance generation with a cached admin audit cursor');
    await restartAfterGenerationRecovery(serverEnv, baseUrl);
    reportBoolean('admin_audit_generation_rotated_offline', true);

    setStage('verify stale admin audit cursor returns AUDIT_CURSOR_EXPIRED');
    const expiredCursorStart = apiEvents.length;
    await (await button(adminPage, 'Next')).click();
    const expiredCursorResponse = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' &&
        event.sequence >= expiredCursorStart && event.hasCursor);
    const expiredCursorPayload = await expiredCursorResponse.payloadPromise;
    const expiredCursorCode = expiredCursorPayload?.error?.code;
    assertThat(expiredCursorResponse.status === 410 &&
        expiredCursorCode === 'AUDIT_CURSOR_EXPIRED',
      'admin audit did not reject a cursor from the previous server generation');
    await waitFor(() => hasVisibleSemanticText(adminPage, '管理员审计游标已过期'));
    const reloadFirstPageButton = await button(adminPage, 'Reload first page');
    reportStatus('admin_audit_generation_expired_cursor', expiredCursorResponse.status);
    reportBoolean('admin_audit_generation_error_retry_visible', true);

    setStage('recover admin audit from expired cursor on the first page');
    const retryStart = apiEvents.length;
    await reloadFirstPageButton.click();
    const retryResponse = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' &&
        event.sequence >= retryStart && !event.hasCursor);
    const retryPayload = await retryResponse.payloadPromise;
    console.log(`assert: admin_audit_retry_response_shape=${JSON.stringify({
      status: retryResponse.status,
      hasBearer: retryResponse.hasBearer,
      noCursor: !retryResponse.hasCursor,
      jsonContentType: retryResponse.contentType.includes('application/json'),
      parsedJson: retryResponse.payloadState.parsed,
      parseErrorType: retryResponse.payloadState.parseErrorType,
      payloadKeys: retryResponse.payloadState.keys,
      eventCount: retryPayload?.events?.length ?? null,
      hasMore: typeof retryPayload?.has_more === 'boolean'
        ? retryPayload.has_more : null,
    })}`);
    setStage('validate refreshed admin audit first-page response');
    assertThat(retryResponse.status === 200 && retryResponse.hasBearer &&
        retryPayload?.events?.length === 100 && retryPayload.has_more === true,
      'admin audit retry did not reload the first page after generation rotation');
    setStage('wait for admin audit first-page label after generation recovery');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Page 1'));
    await adminPage.waitForTimeout(500);
    setStage('inspect recovered admin audit error and retry controls');
    const expiredCursorErrorVisible = await hasVisibleSemanticText(
      adminPage, '管理员审计游标已过期');
    const reloadFirstPageVisible = await hasVisibleSemanticText(
      adminPage, 'Reload first page');
    console.log(`assert: admin_audit_recovered_surface=${JSON.stringify({
      pageOneVisible: true,
      expiredCursorErrorVisible,
      reloadFirstPageVisible,
    })}`);
    assertThat(!expiredCursorErrorVisible && !reloadFirstPageVisible,
      'admin audit kept its expired-cursor error after a successful first-page retry');
    setStage('verify admin audit navigation reset after recovery');
    const recoveredNextEnabled = await (await button(adminPage, 'Next')).isEnabled();
    const recoveredPreviousDisabled = await (await button(adminPage, 'Previous')).isDisabled();
    console.log(`assert: admin_audit_recovered_navigation=${JSON.stringify({
      nextEnabled: recoveredNextEnabled,
      previousDisabled: recoveredPreviousDisabled,
    })}`);
    assertThat(recoveredNextEnabled && recoveredPreviousDisabled,
      'admin audit navigation did not reset after reloading the first page');
    reportStatus('admin_audit_generation_recovery_first_page', retryResponse.status);
    reportBoolean('admin_audit_generation_recovery_navigation_reset', true);

    setStage('create separately invited non-admin profile');
    accountInvitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'account invitation');
    setStage('validate real invitation audit row');
    const invitationAudit = await fetchAllInstanceAdminAuditPages(baseUrl, adminAccessToken);
    const invitationEvent = invitationAudit.events.find(
      (event) => event.action === 'instance.account_invitation_issued');
    const validInvitationEvent = validateInstanceAdminAuditEvent(invitationEvent, {
        action: 'instance.account_invitation_issued',
        actorUserId: null,
        actorDeviceId: null,
        resourceType: 'account_invitation',
        source: 'maintenance',
      }) && !JSON.stringify(invitationEvent).includes(accountInvitationToken) &&
      !JSON.stringify(invitationEvent).includes(memberUsername);
    reportStatus('invitation_audit_feed', invitationAudit.status);
    reportBoolean('invitation_audit_pages_traversed', invitationAudit.pageCount > 0);
    reportBoolean('invitation_audit_dto_private', Boolean(validInvitationEvent));
    assertThat(validInvitationEvent,
      'instance invitation audit row included unexpected fields or invitation data');
    const invitationRefreshStart = apiEvents.length;
    await click(adminPage, 'Refresh admin audit');
    const invitationRefresh = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' && event.sequence >= invitationRefreshStart);
    const invitationPage = await advanceAdminAuditUntilActions(
      adminPage, apiEvents, invitationRefresh, ['instance.account_invitation_issued'],
      'invitation');
    assertThat(invitationPage.response.status === 200 && invitationPage.response.hasBearer,
      'admin audit refresh omitted the real account invitation event');
    const invitationLabelVisible = await hasVisibleSemanticText(
      adminPage, '实例管理员邀请已签发');
    const invitationKeyVisible = await hasVisibleSemanticText(
      adminPage, 'instance.account_invitation_issued');
    reportBoolean('invitation_audit_action_localized', invitationLabelVisible);
    reportBoolean('invitation_audit_action_key_hidden', !invitationKeyVisible);
    assertThat(invitationLabelVisible && !invitationKeyVisible,
      'invitation audit event did not render through its localized label');
    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const memberPage = await memberContext.newPage();
    memberPage.on('pageerror', () => { pageErrorCount += 1; });
    await configurePage(memberPage, baseUrl);
    await field(memberPage, 'Email or username');
    await click(memberPage, 'Have an instance invitation? Create account');
    await field(memberPage, 'Email on the invitation');
    await fill(memberPage, 'Email on the invitation', memberUsername);
    await fill(memberPage, 'Master password · 12+ characters', memberPassword);
    await fill(memberPage, 'Confirm master password', memberPassword);
    await fill(memberPage, 'Instance invitation token', accountInvitationToken);
    accountInvitationToken = undefined;
    await fill(memberPage, 'Device name', 'Non-admin audit acceptance');
    await fill(memberPage, 'First Vault', 'Non-admin audit acceptance');
    await click(memberPage, 'Create invited account');
    await (await button(memberPage, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });

    setStage('verify non-admin Settings omit instance admin audit');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberHasAdminAuditCard = await hasVisibleSemanticText(memberPage, 'Instance admin audit');
    const memberHasMetricsCredentialCard = await hasVisibleSemanticText(
      memberPage, 'Prometheus scrape credential');
    reportBoolean('non_admin_admin_audit_card_absent', !memberHasAdminAuditCard);
    reportBoolean('non_admin_metrics_credential_card_absent', !memberHasMetricsCredentialCard);
    assertThat(!memberHasAdminAuditCard && !memberHasMetricsCredentialCard,
      'non-admin profile rendered an instance-admin-only Settings card');

    setStage('create real account and session administration audit events');
    const accounts = await jsonRequest(
      baseUrl, 'GET', '/api/v1/admin/accounts?limit=100&offset=0', adminAccessToken);
    const targetAccount = accounts.body?.accounts?.find(
      (account) => account.username === memberUsername);
    assertThat(accounts.status === 200 && targetAccount &&
        targetAccount.status === 'active' &&
        typeof targetAccount.user_id === 'string' &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
          targetAccount.user_id),
      'admin account inventory did not return the invited target');
    const sessions = await jsonRequest(
      baseUrl, 'GET',
      `/api/v1/admin/accounts/${targetAccount.user_id}/sessions?limit=100&offset=0`,
      adminAccessToken);
    const memberSession = sessions.body?.sessions?.find(
      (session) => session.active === true && session.revoked_at === null);
    assertThat(sessions.status === 200 && sessions.body?.total === 1 && memberSession &&
        typeof memberSession.session_id === 'string',
      'admin session inventory did not return the invited account session');
    const revokeSession = await jsonRequest(
      baseUrl, 'POST',
      `/api/v1/admin/accounts/${targetAccount.user_id}/sessions/${memberSession.session_id}/revoke`,
      adminAccessToken);
    assertThat(revokeSession.status === 200 && revokeSession.body?.revoked === true &&
        revokeSession.body?.changed === true,
      'administrator could not revoke the invited account session');
    const disableAccount = await jsonRequest(
      baseUrl, 'PUT', `/api/v1/admin/accounts/${targetAccount.user_id}/status`,
      adminAccessToken, { status: 'disabled' });
    assertThat(disableAccount.status === 200 && disableAccount.body?.status === 'disabled' &&
        disableAccount.body?.changed === true,
      'administrator could not disable the invited account');
    const enableAccount = await jsonRequest(
      baseUrl, 'PUT', `/api/v1/admin/accounts/${targetAccount.user_id}/status`,
      adminAccessToken, { status: 'active' });
    assertThat(enableAccount.status === 200 && enableAccount.body?.status === 'active' &&
        enableAccount.body?.changed === true,
      'administrator could not re-enable the invited account');
    const accountAudit = await fetchAllInstanceAdminAuditPages(baseUrl, adminAccessToken);
    reportStatus('account_action_audit_feed', accountAudit.status);
    assertThat(accountAudit.status === 200 && Array.isArray(accountAudit.events),
      'admin audit feed did not return the account lifecycle events');
    const expectedAccountActions = [
      'admin.account_session_revoked', 'admin.account_disabled', 'admin.account_enabled',
    ];
    for (const action of expectedAccountActions) {
      const event = accountAudit.events.find((candidate) => candidate.action === action);
      validateInstanceAdminAuditEvent(event, {
        action,
        actorUserId: admin.accountId,
        actorDeviceId: admin.deviceId,
        resourceType: 'account',
        source: 'api',
        rawResourceId: targetAccount.user_id,
      });
    }
    accountAudit.events = undefined;
    reportBoolean('account_action_audit_dtos_private', true);

    setStage('render account lifecycle audit labels');
    const accountAuditRefreshStart = apiEvents.length;
    await click(adminPage, 'Refresh admin audit');
    const accountAuditRefresh = await waitForEvent(apiEvents,
      (event) => event.route === 'admin-audit' && event.sequence >= accountAuditRefreshStart);
    const accountActionsPage = await advanceAdminAuditUntilActions(
      adminPage, apiEvents, accountAuditRefresh, expectedAccountActions, 'account lifecycle');
    assertThat(accountActionsPage.response.status === 200 && accountActionsPage.response.hasBearer,
      'admin audit refresh omitted an account lifecycle event');
    const localizedAccountActions = [
      ['admin.account_session_revoked', '管理员已撤销账户会话'],
      ['admin.account_disabled', '管理员已停用账户'],
      ['admin.account_enabled', '管理员已启用账户'],
    ];
    for (const [action, label] of localizedAccountActions) {
      const localizedVisible = await scrollToAuditLabel(adminPage, label);
      const rawKeyVisible = await hasVisibleSemanticText(adminPage, action);
      reportBoolean(`audit_label_${action.replaceAll('.', '_')}`, localizedVisible);
      assertThat(localizedVisible && !rawKeyVisible,
        'account lifecycle audit event did not render through its localized label');
    }
    assertThat(pageErrorCount === 0, 'Flutter reported a page runtime error');
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
}

main().catch(async (error) => {
  console.error(`stage: failed (${stage}); error type=${error?.name || 'unknown'}; safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
