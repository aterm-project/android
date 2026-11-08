/*
 * WEB-ADMIN-RELAY-POLICY-01: exercise administrator Relay policy editing in
 * the current Flutter Web bundle against a disposable private-address server.
 * The browser verifies instance and per-account Settings cards; API probes
 * cover member denial, both user/instance revision conflicts, and strict
 * persistence. A private TCP sink also proves account-policy changes revoke
 * unused tickets and close only the selected member's active Relay path.
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
const POLICY_PATH = '/api/v1/admin/relay-policy';
const USER_POLICY_PREFIX = `${POLICY_PATH}/users/`;
const ADMIN_ACCOUNTS_PATH = '/api/v1/admin/accounts';
const ADMIN_AUDIT_PATH = '/api/v1/admin/audit';
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let adminContext;
let memberContext;
let bootstrapToken;
let invitationToken;
let adminUsername;
let adminPassword;
let memberUsername;
let memberPassword;
let memberAccountId;
let memberDeviceId;
let adminAccessToken;
let adminAccountId;
let adminDeviceId;
let memberAccessToken;
let cleanupPromise;
let cleanupFailed = false;
let serverStopConfirmed = true;
let browserStopConfirmed = true;
let relayTargetSinkStopConfirmed = true;
let relayTargetSink;
let pageErrors = 0;
const adminEvents = [];
const memberEvents = [];
const leakSentinels = [];
const flutterAssetStatuses = [];
const browserConsoleErrors = [];
const externalRequestOrigins = [];
let localCanvasKitBootstrapCount = 0;

function assertThat(condition, message) {
  if (!condition) {
    const error = new Error(message);
    error.safeAssertion = message;
    throw error;
  }
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function reportStatus(name, status) {
  console.log(`assert: ${name}_http_status=${status}`);
}

function reportBoolean(name, value) {
  console.log(`assert: ${name}=${value}`);
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

async function startPrivateRelayTarget(address) {
  const peers = new Set();
  let accepted = 0;
  const server = net.createServer((socket) => {
    accepted += 1;
    peers.add(socket);
    socket.once('close', () => peers.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, address, resolve);
  });
  return {
    address,
    port: server.address().port,
    server,
    peers,
    get acceptedCount() { return accepted; },
    get activeCount() { return peers.size; },
    close: async () => {
      for (const peer of peers) peer.destroy();
      if (!server.listening) return;
      await new Promise((resolve, reject) => server.close((error) =>
        error ? reject(error) : resolve()));
    },
  };
}

function privateLanAddress() {
  const result = spawnSync('ip', ['-o', '-4', 'addr', 'show', 'dev', 'eth0', 'scope', 'global'], {
    encoding: 'utf8',
    timeout: 5000,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'a local private IPv4 interface is unavailable');
  const match = result.stdout.match(/\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\//);
  assertThat(match, 'a local private IPv4 interface is unavailable');
  const pieces = match[1].split('.').map(Number);
  const privateAddress = pieces[0] === 10 ||
    (pieces[0] === 172 && pieces[1] >= 16 && pieces[1] <= 31) ||
    (pieces[0] === 192 && pieces[1] === 168);
  assertThat(privateAddress, 'Relay policy acceptance requires an RFC1918 interface address');
  return match[1];
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

async function waitForServer(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1200) });
      if (response.status === 200) return;
    } catch (_) {
      // Keep waiting while the disposable loopback server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    invitationToken = undefined;
    adminUsername = undefined;
    adminPassword = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    memberAccountId = undefined;
    memberDeviceId = undefined;
    adminAccessToken = undefined;
    memberAccessToken = undefined;
    leakSentinels.length = 0;
    if (adminContext) await adminContext.close().catch(() => { cleanupFailed = true; });
    if (memberContext) await memberContext.close().catch(() => { cleanupFailed = true; });
    if (browser) {
      try {
        await browser.close();
        browserStopConfirmed = true;
      } catch (_) {
        browserStopConfirmed = false;
        cleanupFailed = true;
      }
    }
    if (serverProcess) {
      try {
        await stopServerGroup(serverProcess);
        serverStopConfirmed = !processGroupHasLiveMembers(serverProcess.pid);
      } catch (_) {
        serverStopConfirmed = false;
        cleanupFailed = true;
      }
    }
    if (relayTargetSink) {
      try {
        await relayTargetSink.close();
        relayTargetSinkStopConfirmed = true;
      } catch (_) {
        relayTargetSinkStopConfirmed = false;
        cleanupFailed = true;
      }
      relayTargetSink = undefined;
    }
    if (tempRoot) {
      if (!serverStopConfirmed || !browserStopConfirmed || !relayTargetSinkStopConfirmed) {
        cleanupFailed = true;
        console.error('cleanup: preserved temporary data because an owned process or fixture may still be live');
      } else {
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
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 20 });
    await page.waitForTimeout(150);
    if (await locator.inputValue().catch(() => '') !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue().catch(() => '') === value) return;
  }
  const observedValue = await locator.inputValue().catch(() => null);
  const error = new Error('a visible form field did not retain its input');
  error.safeAssertion = `form field input did not persist; expectedLength=${value.length}; ` +
    `observedNonempty=${Boolean(observedValue)}; visible=${await locator.isVisible().catch(() => false)}; ` +
    `enabled=${await locator.isEnabled().catch(() => false)}`;
  throw error;
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
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

async function scrollUntilVisibleSemanticText(page, needle, maxSteps = 24) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(page, needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(900, 850);
    await page.mouse.wheel(0, 750);
    await page.waitForTimeout(60);
  }
  throw new Error('expected Settings audit content did not enter the visible area');
}

async function pageVisibleText(page) {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => {
        const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
        return `${element.textContent || ''}\n${attributes}`;
      }).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
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
  leakSentinels.push(token);
  return token;
}

async function configurePage(page, baseUrl) {
  setStage('open Flutter Web shell');
  const expectedOrigin = new URL(baseUrl).origin;
  page.on('request', (request) => {
    try {
      const origin = new URL(request.url()).origin;
      if (origin !== expectedOrigin) externalRequestOrigins.push(origin);
    } catch (_) {
      // Ignore non-HTTP browser requests.
    }
  });
  await page.route('**/*', async (route) => {
    try {
      const origin = new URL(route.request().url()).origin;
      if (origin !== expectedOrigin) {
        externalRequestOrigins.push(origin);
        await route.abort('blockedbyclient');
        return;
      }
    } catch (_) {
      // Allow browser-internal requests to proceed without URL inspection.
    }
    await route.continue();
  });
  await page.route('**/flutter_bootstrap.js', async (route) => {
    const response = await route.fetch();
    const source = await response.text();
    let localized = source;
    if (!source.includes('"useLocalCanvasKit":true')) {
      localized = source.replace(
        /_flutter\.buildConfig\s*=\s*\{/,
        (match) => `${match}"useLocalCanvasKit":true,`,
      );
    }
    assertThat(localized !== source || source.includes('"useLocalCanvasKit":true'),
      'current Flutter bundle did not expose its local CanvasKit assets');
    localCanvasKitBootstrapCount += 1;
    await route.fulfill({ response, body: localized });
  });
  page.on('response', (response) => {
    try {
      const pathname = new URL(response.url()).pathname;
      if (['/sodium.js', '/flutter_bootstrap.js', '/flutter.js', '/main.dart.js'].includes(pathname) ||
          pathname.startsWith('/canvaskit/')) {
        flutterAssetStatuses.push(`${path.basename(pathname)}:${response.status()}`);
      }
    } catch (_) {
      // Ignore non-HTTP browser responses.
    }
  });
  page.on('console', (message) => {
    if (message.type() !== 'error' && message.type() !== 'warning') return;
    let text = message.text();
    for (const secret of leakSentinels) if (secret) text = text.replaceAll(secret, '[redacted]');
    if (tempRoot) text = text.replaceAll(tempRoot, '[private-path]');
    browserConsoleErrors.push(`${message.type()}:${text.slice(0, 180)}`);
  });
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  const csp = await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute('content');
  assertThat(typeof csp === 'string' && csp.includes("script-src 'self'") &&
      !csp.includes('www.gstatic.com'), 'test-only CanvasKit routing changed the strict page CSP');
  setStage('wait for Flutter Web readiness');
  const ready = await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000).then(() => true).catch(() => false);
  if (!ready) {
    const diagnostic = await page.evaluate(() => ({
      sodiumObject: typeof window.sodium,
      sodiumReady: typeof window.sodium?.ready,
      semanticsPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
      semanticsNodes: document.querySelectorAll('flt-semantics').length,
      canvasCount: document.querySelectorAll('canvas').length,
      flutterView: Boolean(document.querySelector('flutter-view')),
      title: document.title,
    }));
    assertThat(false, `Flutter Web did not become ready (${JSON.stringify(diagnostic)}; assets=${flutterAssetStatuses.join(',')}; console=${browserConsoleErrors.slice(-5).join('|')})`);
  }
  setStage('wait for client cryptography');
  await page.evaluate(async () => { await window.sodium.ready; });
  setStage('enable Flutter Web semantics');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  setStage('wait for accessible Settings controls');
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  setStage('set server address');
  await fill(page, 'Server URL', baseUrl);
  setStage('connect client to disposable server');
  await click(page, 'Connect securely');
}

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === POLICY_PATH) return 'relay-policy';
    if (pathname.startsWith(USER_POLICY_PREFIX)) return 'relay-user-policy';
    if (pathname === ADMIN_ACCOUNTS_PATH) return 'admin-accounts';
    if (pathname === ADMIN_AUDIT_PATH) return 'admin-audit';
  } catch (_) {
    // Ignore browser-internal requests.
  }
  return null;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    let pathname = null;
    try { pathname = new URL(request.url()).pathname; } catch (_) {}
    let body = null;
    if ((route === 'relay-policy' && request.method() === 'PUT') ||
        (route === 'relay-user-policy' && ['PUT', 'DELETE'].includes(request.method()))) {
      try { body = request.postDataJSON(); } catch (_) { body = null; }
    }
    byRequest.set(request, {
      route,
      pathname,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      body,
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    events.push({
      ...metadata,
      status: response.status(),
      responseObservedAt: Date.now(),
      sequence: events.length,
      payloadPromise: response.json().catch(() => null),
    });
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

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const secret of leakSentinels) {
    if (secret && secret.length >= 8) {
      assertThat(!serialized.includes(secret), 'a response or rendered view exposed a credential or private path');
    }
  }
  const internalText = /\/(?:root|tmp|var|home|opt|usr|workspace)\/|\b[A-Z]:\\(?:Users|Windows|Program Files)\\|(?:SQLite|sqlx|tokio::|panic at|stack trace|backtrace|internal server error|no such table)/i;
  assertThat(!internalText.test(serialized), 'a response or rendered view exposed internal server details');
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'a response or rendered view exposed the server data path');
}

function validatePolicy(payload, { revision, cidrs, ports, enabled = true }) {
  assertThat(exactKeys(payload, [
    'policy', 'deployment_limits', 'max_connections_per_user', 'revision', 'updated_at',
  ]), 'Relay policy response fields changed');
  assertThat(exactKeys(payload.policy, ['enabled', 'allow_cidrs', 'allow_ports']) &&
      exactKeys(payload.deployment_limits, ['relay_available', 'allow_cidrs', 'allow_ports']),
    'Relay policy settings or immutable deployment limits had an invalid shape');
  assertThat(payload.policy.enabled === enabled && payload.revision === revision &&
      JSON.stringify(payload.policy.allow_cidrs) === JSON.stringify(cidrs) &&
      JSON.stringify(payload.policy.allow_ports) === JSON.stringify(ports),
    'Relay policy values or revision did not match the saved values');
  assertThat(payload.deployment_limits.relay_available === true &&
      Array.isArray(payload.deployment_limits.allow_cidrs) &&
      Array.isArray(payload.deployment_limits.allow_ports) &&
      Number.isInteger(payload.max_connections_per_user) && payload.max_connections_per_user > 0,
    'immutable Relay deployment limits were missing');
  assertThat(payload.updated_at === null ||
      (typeof payload.updated_at === 'string' && !Number.isNaN(Date.parse(payload.updated_at))),
    'Relay policy update timestamp was invalid');
  assertNoLeaks(payload);
  return payload;
}

function validateUserPolicy(payload, {
  userId,
  inherited,
  revision,
  instancePolicyRevision,
  policy,
  effectivePolicy,
  updatedAt,
}) {
  assertThat(exactKeys(payload, [
    'user_id', 'inherited', 'policy', 'effective_policy',
    'instance_policy_revision', 'revision', 'updated_at',
  ]), 'account Relay policy response fields changed');
  assertThat(payload.user_id === userId && payload.inherited === inherited &&
      payload.revision === revision &&
      payload.instance_policy_revision === instancePolicyRevision,
    'account Relay policy identity, inheritance, or revision did not match');
  assertThat(exactKeys(payload.policy, ['enabled', 'allow_cidrs', 'allow_ports']) &&
      exactKeys(payload.effective_policy, ['enabled', 'allow_cidrs', 'allow_ports']),
    'account Relay policy selection or effective state had an invalid shape');
  if (policy) {
    assertThat(payload.policy.enabled === policy.enabled &&
        JSON.stringify(payload.policy.allow_cidrs) === JSON.stringify(policy.cidrs) &&
        JSON.stringify(payload.policy.allow_ports) === JSON.stringify(policy.ports),
      'account Relay policy selection did not match the expected saved or inherited state');
  }
  if (effectivePolicy) {
    assertThat(payload.effective_policy.enabled === effectivePolicy.enabled &&
        JSON.stringify(payload.effective_policy.allow_cidrs) ===
          JSON.stringify(effectivePolicy.cidrs) &&
        JSON.stringify(payload.effective_policy.allow_ports) ===
          JSON.stringify(effectivePolicy.ports),
      'account Relay effective policy did not match the expected intersection');
  }
  if (updatedAt === null) {
    assertThat(payload.updated_at === null,
      'never-mutated account Relay policy did not report a null update time');
  } else if (updatedAt === 'set') {
    assertThat(typeof payload.updated_at === 'string' &&
        !Number.isNaN(Date.parse(payload.updated_at)),
      'mutated account Relay policy omitted a valid update time');
  } else if (updatedAt !== undefined) {
    assertThat(payload.updated_at === updatedAt,
      'account Relay policy update timestamp changed unexpectedly');
  }
  assertNoLeaks(payload);
  return payload;
}

async function directApi(baseUrl, method, pathname, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertNoLeaks(payload);
  return { status: response.status, payload };
}

async function createRelayTicket(baseUrl, token, deviceId, targetHost, targetPort) {
  const result = await directApi(baseUrl, 'POST', '/api/v1/relay/tickets', {
    token,
    body: { device_id: deviceId, target_host: targetHost, target_port: targetPort },
  });
  return result;
}

function inspectRelayTicket(databasePath, ticket) {
  const digest = crypto.createHash('sha256').update(ticket).digest('hex');
  const script = [
    'import json,pathlib,sqlite3,sys',
    'uri=pathlib.Path(sys.argv[1]).as_uri()+"?mode=ro"',
    'db=sqlite3.connect(uri,uri=True)',
    'row=db.execute("SELECT target_ip,target_port,consumed_at FROM relay_tickets WHERE ticket_hash=?",(sys.argv[2],)).fetchone()',
    'print(json.dumps({"present":row is not None,"opaque":bool(row and row[0].startswith("rtd1:")),"unconsumed":bool(row and row[2] is None),"destination_cleared":bool(row and row[0]=="" and row[1]==0)}))',
  ].join(';');
  const result = spawnSync('python3', ['-c', script, databasePath, digest], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only Relay ticket state probe failed');
  let state;
  try { state = JSON.parse(result.stdout); } catch (_) { state = null; }
  assertThat(exactKeys(state, ['present', 'opaque', 'unconsumed', 'destination_cleared']) &&
      Object.values(state).every((value) => typeof value === 'boolean'),
    'read-only Relay ticket state probe returned invalid diagnostics');
  return state;
}

async function openRelayProbe(page, baseUrl, ticket, connectPath, probeId) {
  const opened = await page.evaluate(({ baseUrl, ticket, connectPath, probeId }) => {
    window.__atermiusAdminRelayProbes ??= {};
    return new Promise((resolve, reject) => {
      const url = new URL(connectPath, baseUrl);
      url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
      const probe = {
        socket: new WebSocket(url.toString()),
        opened: false,
        closed: false,
        closedAt: null,
        closeCode: null,
        socketError: false,
      };
      window.__atermiusAdminRelayProbes[probeId] = probe;
      const timer = setTimeout(() => reject(new Error('Relay probe open timed out')), 10000);
      probe.socket.addEventListener('open', () => {
        probe.opened = true;
        probe.socket.send(ticket);
        clearTimeout(timer);
        resolve(true);
      }, { once: true });
      probe.socket.addEventListener('close', (event) => {
        probe.closed = true;
        probe.closedAt = Date.now();
        probe.closeCode = event.code;
      });
      probe.socket.addEventListener('error', () => {
        probe.socketError = true;
      });
    });
  }, { baseUrl, ticket, connectPath, probeId });
  assertThat(opened === true, 'Relay probe did not open its WebSocket');
}

async function relayProbeStatus(page, probeId) {
  return page.evaluate((key) => {
    const probe = window.__atermiusAdminRelayProbes?.[key];
    if (!probe) return null;
    return {
      opened: probe.opened === true,
      closed: probe.closed === true,
      closedAt: Number.isFinite(probe.closedAt) ? probe.closedAt : null,
      closeCode: Number.isInteger(probe.closeCode) ? probe.closeCode : null,
      socketError: probe.socketError === true,
    };
  }, probeId);
}

async function closeRelayProbe(page, probeId) {
  await page.evaluate((key) => {
    const probe = window.__atermiusAdminRelayProbes?.[key];
    if (probe && probe.socket.readyState < WebSocket.CLOSING) {
      probe.socket.close(1000, 'fixture complete');
    }
  }, probeId).catch(() => {});
}

function validateUserRelayAudit(payload, actor, expectedCounts, targetAddress) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'account audit page shape was invalid after Relay lifecycle probes');
  const rows = payload.events.filter((event) =>
    event.action === 'relay.ticket_issued' || event.action === 'relay.connected');
  assertThat(rows.length === expectedCounts.ticketIssued + expectedCounts.connected &&
      rows.every((event) => exactKeys(event, [
        'event_id', 'scope', 'vault_id', 'actor_user_id', 'actor_device_id',
        'action', 'resource_type', 'resource_id', 'result', 'occurred_at', 'source',
      ]) && /^\d+$/.test(event.event_id) && event.scope === 'account' &&
      event.vault_id === null && event.actor_user_id === actor.userId &&
      event.actor_device_id === actor.deviceId && event.resource_type === 'relay' &&
      event.resource_id === null && event.result === 'success' && event.source === 'api' &&
      !Number.isNaN(Date.parse(event.occurred_at))),
    'Relay audit rows contained unexpected scope, actor, resource or status data');
  assertThat(rows.filter((event) => event.action === 'relay.ticket_issued').length ===
        expectedCounts.ticketIssued &&
      rows.filter((event) => event.action === 'relay.connected').length ===
        expectedCounts.connected,
    'Relay audit rows did not match the successful ticket and connection ledger');
  const serialized = JSON.stringify(rows);
  assertThat(!serialized.includes(targetAddress) && !serialized.includes(actor.username),
    'account Relay audit events exposed target or username metadata');
  assertNoLeaks(rows);
  return rows.length;
}

function validateAdminAuditPage(payload) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'instance audit page shape was invalid');
  assertNoLeaks(payload);
  const eventFields = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
    'resource_id', 'result', 'occurred_at', 'source',
  ];
  for (const event of payload.events) {
    assertThat(exactKeys(event, eventFields) && /^\d+$/.test(event.event_id) &&
        event.scope === 'instance' &&
        (event.actor_user_id === null || typeof event.actor_user_id === 'string') &&
        (event.actor_device_id === null || typeof event.actor_device_id === 'string') &&
        (event.resource_id === null || /^[0-9a-f]{64}$/.test(event.resource_id)) &&
        ['success', 'failure'].includes(event.result) &&
        ['api', 'maintenance'].includes(event.source) &&
        typeof event.occurred_at === 'string' && !Number.isNaN(Date.parse(event.occurred_at)),
      'instance audit event DTO or privacy metadata was invalid');
  }
  return payload.events;
}

function validateRelayPolicyAuditEvent(payload, admin) {
  const rows = validateAdminAuditPage(payload).filter(
    (event) => event.action === 'admin.relay_policy_updated');
  assertThat(rows.length === 1, 'admin audit feed did not contain exactly one Relay policy write');
  const event = rows[0];
  assertThat(event.scope === 'instance' &&
      event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
      event.resource_type === 'relay_policy' && event.resource_id === null &&
      event.result === 'success' && event.source === 'api',
    'Relay policy audit event actor, resource, source or result was invalid');
  const serialized = JSON.stringify(event);
  assertThat(!serialized.includes(adminUsername) && !serialized.includes(adminPassword),
    'Relay policy audit event exposed account or credential data');
  return event;
}

async function exerciseAccountRelayPolicyUi({
  page,
  memberPage,
  baseUrl,
  databasePath,
  relayTargetSink,
  targetUserId,
  targetUsername,
  currentAdminUserId,
  lanIp,
  deploymentCidr,
  targetPort,
  currentAdminDeviceId,
  targetDeviceId,
}) {
  const targetPath = `${USER_POLICY_PREFIX}${targetUserId}`;
  const targetCidrs = [`${lanIp}/32`];
  const targetPorts = [22, targetPort].sort((left, right) => left - right);
  const targetPortsText = targetPorts.join(', ');
  const initialSelection = {
    enabled: true,
    cidrs: targetCidrs,
    ports: targetPorts,
  };

  setStage('confirm target and current-admin policies are independently inherited');
  const inheritedTargetResponse = await directApi(baseUrl, 'GET', targetPath, {
    token: adminAccessToken,
  });
  reportStatus('target_account_policy_initial_read', inheritedTargetResponse.status);
  assertThat(inheritedTargetResponse.status === 200,
    'administrator could not read the selected account Relay policy');
  validateUserPolicy(inheritedTargetResponse.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instancePolicyRevision: 1,
    policy: initialSelection,
    effectivePolicy: initialSelection,
    updatedAt: null,
  });
  const currentAdminPath = `${USER_POLICY_PREFIX}${currentAdminUserId}`;
  const currentAdminBeforeResponse = await directApi(
    baseUrl, 'GET', currentAdminPath, { token: adminAccessToken },
  );
  assertThat(currentAdminBeforeResponse.status === 200,
    'administrator could not read its own account policy for isolation checking');
  validateUserPolicy(currentAdminBeforeResponse.payload, {
    userId: currentAdminUserId,
    inherited: true,
    revision: 0,
    instancePolicyRevision: 1,
    policy: initialSelection,
    effectivePolicy: initialSelection,
    updatedAt: null,
  });

  setStage('load account directory and confirm account-policy controls are lazy');
  if (!await hasVisibleSemanticText(page, 'Workspace settings')) {
    await click(page, 'Settings');
  }
  await waitFor(() => hasVisibleSemanticText(page, 'Workspace settings'));
  setStage('scroll Settings to the administrator account directory');
  await page.mouse.move(900, 850);
  for (let step = 0; step < 30; step += 1) {
    await page.mouse.wheel(0, 1200);
    await page.waitForTimeout(40);
  }
  await page.waitForTimeout(250);
  setStage('load administrator account directory');
  const accountListStart = adminEvents.length;
  await click(page, 'Load admin accounts');
  const accountListEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'admin-accounts' && event.method === 'GET' &&
      event.sequence >= accountListStart);
  const accountList = await accountListEvent.payloadPromise;
  assertThat(accountListEvent.hasBearer && accountListEvent.status === 200 &&
      exactKeys(accountList, ['accounts', 'total', 'limit', 'offset']) &&
      Array.isArray(accountList.accounts) && accountList.total === 2 &&
      accountList.accounts.length === 2,
    'administrator account list was not an authenticated well-shaped response');
  const accountFields = [
    'user_id', 'username', 'status', 'created_at',
    'active_device_count', 'active_session_count',
  ];
  assertThat(accountList.accounts.every((account) =>
    exactKeys(account, accountFields) && UUID_PATTERN.test(account.user_id) &&
    typeof account.username === 'string' &&
    ['active', 'disabled', 'deleting'].includes(account.status)),
  'administrator account list row exposed an unexpected shape');
  const targetRow = accountList.accounts.find((account) =>
    account.user_id === targetUserId);
  const currentAdminRow = accountList.accounts.find((account) =>
    account.user_id === currentAdminUserId);
  assertThat(targetRow?.username === targetUsername && targetRow.status === 'active' &&
      currentAdminRow?.status === 'active',
    'target account was not a separate active account in the admin directory');
  assertNoLeaks(accountList);
  await waitFor(() => hasVisibleSemanticText(page, targetUsername));
  const targetPolicyButton = page.getByRole('button', {
    name: 'Relay policy', exact: true,
  });
  assertThat(await targetPolicyButton.count() === 1 &&
      await targetPolicyButton.isVisible(),
    'the sole non-current active account did not expose one Relay policy control');
  const targetPolicyReadsBeforeExpand = adminEvents.filter((event) =>
    event.route === 'relay-user-policy' && event.pathname === targetPath &&
    event.method === 'GET').length;
  assertThat(targetPolicyReadsBeforeExpand === 0,
    'account Relay policy was fetched before its card was expanded');
  reportBoolean('target_account_active_noncurrent_and_policy_lazy', true);

  setStage('expand the selected account card and load inherited policy');
  const lazyLoadStart = adminEvents.length;
  await targetPolicyButton.click();
  const userPolicyLoadEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'GET' &&
      event.sequence >= lazyLoadStart);
  const instancePolicyLoadEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-policy' &&
      event.pathname === POLICY_PATH && event.method === 'GET' &&
      event.sequence >= lazyLoadStart);
  assertThat(userPolicyLoadEvent.hasBearer && userPolicyLoadEvent.status === 200 &&
      instancePolicyLoadEvent.hasBearer && instancePolicyLoadEvent.status === 200,
    'expanded account card did not load both policy snapshots as an administrator');
  const loadedUserPolicy = await userPolicyLoadEvent.payloadPromise;
  const loadedInstancePolicy = await instancePolicyLoadEvent.payloadPromise;
  validatePolicy(loadedInstancePolicy, {
    revision: 1,
    cidrs: targetCidrs,
    ports: targetPorts,
  });
  validateUserPolicy(loadedUserPolicy, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instancePolicyRevision: 1,
    policy: initialSelection,
    effectivePolicy: initialSelection,
    updatedAt: null,
  });
  assertThat(adminEvents.filter((event) =>
    event.route === 'relay-user-policy' && event.pathname === targetPath &&
    event.method === 'GET' && event.sequence >= lazyLoadStart).length === 1,
  'expanding the account card issued duplicate user-policy reads');
  await waitFor(() => hasVisibleSemanticText(
    page, 'Selection: inherited from the instance policy',
  ));
  const accountEnabled = page.getByRole('checkbox', {
    name: 'Enable Relay for this account', exact: true,
  });
  const accountCidrs = page.getByRole('textbox', {
    name: /^Allowed CIDR networks/,
  });
  const accountPorts = page.getByRole('textbox', {
    name: /^Allowed ports/,
  }).last();
  const readAccountDraft = async () => {
    await page.waitForTimeout(150);
    const enabled = await accountEnabled.isChecked();
    await accountCidrs.click();
    await page.waitForTimeout(150);
    const cidrs = await accountCidrs.inputValue();
    await accountPorts.click();
    await page.waitForTimeout(150);
    const ports = await accountPorts.inputValue();
    return { enabled, cidrs, ports };
  };
  const inheritedDraft = await readAccountDraft();
  reportBoolean('inherited_account_draft_enabled', inheritedDraft.enabled);
  reportBoolean('inherited_account_cidrs_match',
    inheritedDraft.cidrs === targetCidrs.join('\n'));
  reportBoolean('inherited_account_ports_match',
    inheritedDraft.ports === targetPortsText);
  reportBoolean('inherited_account_cidr_line_count',
    inheritedDraft.cidrs.split('\n').filter(Boolean).length);
  reportBoolean('inherited_account_port_line_count',
    inheritedDraft.ports.split('\n').filter(Boolean).length);
  assertThat(inheritedDraft.enabled &&
      inheritedDraft.cidrs === targetCidrs.join('\n') &&
      inheritedDraft.ports === targetPortsText,
    'inherited Relay values were not seeded into the selected account draft');
  reportBoolean('expanded_account_policy_rendered_as_inherited', true);

  setStage('connect the target member and administrator through Relay to a private TCP sink');
  const issueProbeTicket = async (token, deviceId) => {
    const issued = await createRelayTicket(
      baseUrl, token, deviceId, relayTargetSink.address, targetPort,
    );
    assertThat(issued.status === 200 &&
        exactKeys(issued.payload, ['ticket', 'expires_at', 'connect_path']) &&
        typeof issued.payload.ticket === 'string' &&
        /^[A-Za-z0-9_-]{43}$/.test(issued.payload.ticket) &&
        typeof issued.payload.expires_at === 'string' &&
        !Number.isNaN(Date.parse(issued.payload.expires_at)) &&
        issued.payload.connect_path === '/relay/v1/connect',
      'active Relay probe ticket response did not match the bounded public DTO');
    leakSentinels.push(issued.payload.ticket);
    return issued.payload;
  };
  const memberActiveTicket = await issueProbeTicket(
    memberAccessToken, targetDeviceId,
  );
  const memberProbeId = 'member-active-before-policy-change';
  await openRelayProbe(
    memberPage, baseUrl, memberActiveTicket.ticket,
    memberActiveTicket.connect_path, memberProbeId,
  );
  const adminActiveTicket = await issueProbeTicket(
    adminAccessToken, currentAdminDeviceId,
  );
  const adminProbeId = 'admin-active-before-policy-change';
  await openRelayProbe(
    page, baseUrl, adminActiveTicket.ticket,
    adminActiveTicket.connect_path, adminProbeId,
  );
  await waitFor(() => relayTargetSink.acceptedCount === 2 &&
    relayTargetSink.activeCount === 2, 10000);
  const memberActiveStatus = await relayProbeStatus(memberPage, memberProbeId);
  const adminActiveStatus = await relayProbeStatus(page, adminProbeId);
  assertThat(memberActiveStatus?.opened && !memberActiveStatus.closed &&
      adminActiveStatus?.opened && !adminActiveStatus.closed,
    'both accounts did not establish an active Relay path before the policy change');

  const pendingMemberTicket = await issueProbeTicket(
    memberAccessToken, targetDeviceId,
  );
  const pendingTicketState = inspectRelayTicket(
    databasePath, pendingMemberTicket.ticket,
  );
  assertThat(pendingTicketState.present && pendingTicketState.opaque &&
      pendingTicketState.unconsumed && !pendingTicketState.destinationCleared,
    'member test ticket was not stored as an opaque unused Relay ticket');
  reportBoolean('member_and_admin_relay_active_with_opaque_unused_ticket', true);

  setStage('save an explicit disabled account override through Settings');
  setStage('disable the target account Relay checkbox');
  await accountEnabled.click();
  await page.waitForTimeout(150);
  reportBoolean('account_override_checkbox_disabled_before_save',
    !await accountEnabled.isChecked());
  const accountSaveButton = page.getByRole('button', {
    name: 'Save override', exact: true,
  });
  reportBoolean('account_override_save_button_enabled',
    await accountSaveButton.isEnabled());
  const overrideSaveStart = adminEvents.length;
  await accountSaveButton.click();
  setStage('wait for account override PUT response');
  const overrideSaveEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'PUT' &&
      event.sequence >= overrideSaveStart);
  const relayPolicyChangedAt = overrideSaveEvent.responseObservedAt;
  assertThat(Number.isSafeInteger(relayPolicyChangedAt),
    'account policy update response did not carry a timing marker');
  reportStatus('administrator_account_policy_override', overrideSaveEvent.status);
  const overrideRequest = {
    expected_revision: 0,
    expected_instance_policy_revision: 1,
    enabled: false,
    allow_cidrs: targetCidrs,
    allow_ports: targetPorts,
  };
  assertThat(overrideSaveEvent.hasBearer && overrideSaveEvent.status === 200 &&
      exactKeys(overrideSaveEvent.body, Object.keys(overrideRequest)) &&
      overrideSaveEvent.body.expected_revision === 0 &&
      overrideSaveEvent.body.expected_instance_policy_revision === 1 &&
      overrideSaveEvent.body.enabled === false &&
      JSON.stringify(overrideSaveEvent.body.allow_cidrs) === JSON.stringify(targetCidrs) &&
      JSON.stringify(overrideSaveEvent.body.allow_ports) === JSON.stringify(targetPorts),
    'Settings did not submit a strict user and instance revision CAS override');
  const overrideSaved = await overrideSaveEvent.payloadPromise;
  const disabledSelection = { enabled: false, cidrs: targetCidrs, ports: targetPorts };
  validateUserPolicy(overrideSaved, {
    userId: targetUserId,
    inherited: false,
    revision: 1,
    instancePolicyRevision: 1,
    policy: disabledSelection,
    effectivePolicy: disabledSelection,
    updatedAt: 'set',
  });
  await waitFor(() => hasVisibleSemanticText(page, 'Selection: account override'));
  const savedDraft = await readAccountDraft();
  assertThat(!savedDraft.enabled && savedDraft.cidrs === targetCidrs.join('\n') &&
      savedDraft.ports === targetPortsText,
    'saved account override was not reflected in its selected card');
  const targetAfterOverride = await directApi(baseUrl, 'GET', targetPath, {
    token: adminAccessToken,
  });
  assertThat(targetAfterOverride.status === 200,
    'target account override could not be read back');
  validateUserPolicy(targetAfterOverride.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 1,
    instancePolicyRevision: 1,
    policy: disabledSelection,
    effectivePolicy: disabledSelection,
    updatedAt: overrideSaved.updated_at,
  });
  const currentAdminAfterOverride = await directApi(
    baseUrl, 'GET', currentAdminPath, { token: adminAccessToken },
  );
  validateUserPolicy(currentAdminAfterOverride.payload, {
    userId: currentAdminUserId,
    inherited: true,
    revision: 0,
    instancePolicyRevision: 1,
    policy: initialSelection,
    effectivePolicy: initialSelection,
    updatedAt: null,
  });
  reportBoolean('explicit_override_persisted_for_target_only', true);

  setStage('verify policy write revoked the unused member ticket and closed only its active Relay');
  const revokedTicketState = inspectRelayTicket(
    databasePath, pendingMemberTicket.ticket,
  );
  assertThat(!revokedTicketState.present,
    'successful account-policy update did not delete the unused member ticket');
  const relayPolicyCloseWindowMs = 3500;
  const relayPolicyCloseTimeRemaining = Math.max(1,
    relayPolicyCloseWindowMs - (Date.now() - relayPolicyChangedAt));
  await waitFor(async () =>
    (await relayProbeStatus(memberPage, memberProbeId))?.closed === true,
  relayPolicyCloseTimeRemaining);
  const memberRelayClosedStatus = await relayProbeStatus(memberPage, memberProbeId);
  const memberRelayCloseLatencyMs = memberRelayClosedStatus?.closedAt - relayPolicyChangedAt;
  console.log(`assert: member_relay_close_latency_ms=${memberRelayCloseLatencyMs}`);
  reportBoolean('member_relay_closed_within_policy_poll_window',
    Number.isSafeInteger(memberRelayCloseLatencyMs) &&
      memberRelayCloseLatencyMs >= 0 &&
      memberRelayCloseLatencyMs <= relayPolicyCloseWindowMs);
  assertThat(Number.isSafeInteger(memberRelayCloseLatencyMs) &&
      memberRelayCloseLatencyMs >= 0 &&
      memberRelayCloseLatencyMs <= relayPolicyCloseWindowMs,
    'member active Relay connection outlived the bounded policy recheck window');
  await waitFor(() => relayTargetSink.activeCount === 1, 2500);
  await new Promise((resolve) => setTimeout(resolve, 2200));
  const unaffectedAdminStatus = await relayProbeStatus(page, adminProbeId);
  assertThat(unaffectedAdminStatus?.opened && !unaffectedAdminStatus.closed &&
      relayTargetSink.activeCount === 1,
    'account policy update closed or disrupted the administrator Relay connection');

  const deniedMemberTicket = await createRelayTicket(
    baseUrl, memberAccessToken, targetDeviceId,
    relayTargetSink.address, targetPort,
  );
  reportStatus('member_ticket_after_account_disable', deniedMemberTicket.status);
  assertThat(deniedMemberTicket.status === 503 &&
      deniedMemberTicket.payload?.error?.code === 'RELAY_DISABLED',
    'new ticket issuance for the disabled member was not rejected');
  assertNoLeaks(deniedMemberTicket.payload);

  setStage('verify consuming the revoked ticket cannot connect and admin Relay remains available');
  const rejectedTicketProbeId = 'member-revoked-ticket-after-policy-change';
  await openRelayProbe(
    memberPage, baseUrl, pendingMemberTicket.ticket,
    pendingMemberTicket.connect_path, rejectedTicketProbeId,
  );
  await waitFor(async () =>
    (await relayProbeStatus(memberPage, rejectedTicketProbeId))?.closed === true, 3000);
  await new Promise((resolve) => setTimeout(resolve, 250));
  assertThat(relayTargetSink.acceptedCount === 2 && relayTargetSink.activeCount === 1,
    'consuming the revoked member ticket created a target TCP connection');
  const adminAfterChangeTicket = await issueProbeTicket(
    adminAccessToken, currentAdminDeviceId,
  );
  const adminAfterChangeProbeId = 'admin-fresh-ticket-after-member-policy-change';
  await openRelayProbe(
    page, baseUrl, adminAfterChangeTicket.ticket,
    adminAfterChangeTicket.connect_path, adminAfterChangeProbeId,
  );
  await waitFor(() => relayTargetSink.acceptedCount === 3 &&
    relayTargetSink.activeCount === 2, 5000);
  const adminFreshStatus = await relayProbeStatus(page, adminAfterChangeProbeId);
  assertThat(adminFreshStatus?.opened && !adminFreshStatus.closed,
    'the unaffected administrator could not establish a new Relay connection');
  reportBoolean('revoked_member_ticket_rejected_and_admin_unaffected', true);

  await closeRelayProbe(page, adminProbeId);
  await closeRelayProbe(page, adminAfterChangeProbeId);
  await waitFor(() => relayTargetSink.activeCount === 0, 5000);
  await closeRelayProbe(memberPage, memberProbeId);
  await closeRelayProbe(memberPage, rejectedTicketProbeId);
  reportBoolean('active_relay_probe_sockets_closed_before_account_conflict_flow', true);

  const waitForRelayAuditCounts = async (token, expected) => {
    let lastPage;
    await waitFor(async () => {
      const response = await directApi(baseUrl, 'GET', '/api/v1/audit?limit=100', {
        token,
      });
      if (response.status !== 200 || !Array.isArray(response.payload?.events)) {
        return false;
      }
      lastPage = response.payload;
      const actions = lastPage.events.filter((event) =>
        event.action === 'relay.ticket_issued' || event.action === 'relay.connected');
      return actions.filter((event) => event.action === 'relay.ticket_issued').length ===
            expected.ticketIssued &&
          actions.filter((event) => event.action === 'relay.connected').length ===
            expected.connected;
    }, 5000);
    return lastPage;
  };
  setStage('verify account-scope Relay ticket and connection audit privacy');
  const memberAudit = await waitForRelayAuditCounts(memberAccessToken, {
    ticketIssued: 2,
    connected: 1,
  });
  const memberRelayAuditCount = validateUserRelayAudit(memberAudit, {
    userId: targetUserId,
    deviceId: targetDeviceId,
    username: targetUsername,
  }, { ticketIssued: 2, connected: 1 }, relayTargetSink.address);
  const adminAudit = await waitForRelayAuditCounts(adminAccessToken, {
    ticketIssued: 2,
    connected: 2,
  });
  const adminRelayAuditCount = validateUserRelayAudit(adminAudit, {
    userId: currentAdminUserId,
    deviceId: currentAdminDeviceId,
    username: adminUsername,
  }, { ticketIssued: 2, connected: 2 }, relayTargetSink.address);
  assertThat(memberRelayAuditCount === 3 && adminRelayAuditCount === 4,
    'account Relay audit event counts did not match successful fixture operations');
  reportBoolean('account_relay_audit_isolated_and_target_private', true);

  setStage('preserve the account draft after a stale user-policy revision conflict');
  await accountEnabled.click();
  await page.waitForTimeout(150);
  reportBoolean('account_draft_enabled_before_stale_user_save',
    await accountEnabled.isChecked());
  const competingUserWrite = await directApi(baseUrl, 'PUT', targetPath, {
    token: adminAccessToken,
    body: {
      expected_revision: 1,
      expected_instance_policy_revision: 1,
      enabled: false,
      allow_cidrs: targetCidrs,
      allow_ports: [],
    },
  });
  reportStatus('competing_account_policy_revision', competingUserWrite.status);
  assertThat(competingUserWrite.status === 200,
    'the account revision conflict fixture update did not succeed');
  validateUserPolicy(competingUserWrite.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instancePolicyRevision: 1,
    policy: { enabled: false, cidrs: targetCidrs, ports: [] },
    effectivePolicy: { enabled: false, cidrs: targetCidrs, ports: [] },
    updatedAt: 'set',
  });
  const staleUserSaveStart = adminEvents.length;
  await click(page, 'Save override');
  const staleUserSave = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'PUT' &&
      event.sequence >= staleUserSaveStart);
  reportStatus('stale_user_revision_account_save', staleUserSave.status);
  const staleUserPayload = await staleUserSave.payloadPromise;
  assertThat(staleUserSave.hasBearer && staleUserSave.status === 409 &&
      exactKeys(staleUserSave.body, Object.keys(overrideRequest)) &&
      staleUserSave.body.expected_revision === 1 &&
      staleUserSave.body.expected_instance_policy_revision === 1 &&
      staleUserSave.body.enabled === true &&
      JSON.stringify(staleUserSave.body.allow_cidrs) === JSON.stringify(targetCidrs) &&
      JSON.stringify(staleUserSave.body.allow_ports) === JSON.stringify(targetPorts) &&
      staleUserPayload?.error?.code === 'RELAY_USER_POLICY_CONFLICT',
    'stale user-policy write did not return the expected conflict for the submitted draft');
  assertNoLeaks(staleUserPayload);
  await waitFor(() => page.getByRole('button', {
    name: 'Reload latest policy, keep draft', exact: true,
  }).isVisible());
  const staleUserDraft = await readAccountDraft();
  assertThat(staleUserDraft.enabled &&
      staleUserDraft.cidrs === targetCidrs.join('\n') &&
      staleUserDraft.ports === targetPortsText,
    'stale user-policy conflict did not preserve the edited draft');
  const targetAfterStaleUserSave = await directApi(baseUrl, 'GET', targetPath, {
    token: adminAccessToken,
  });
  validateUserPolicy(targetAfterStaleUserSave.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instancePolicyRevision: 1,
    policy: { enabled: false, cidrs: targetCidrs, ports: [] },
    effectivePolicy: { enabled: false, cidrs: targetCidrs, ports: [] },
    updatedAt: 'set',
  });
  reportBoolean('stale_user_revision_conflict_kept_draft_and_server_state', true);

  setStage('reload current user policy while retaining the edited draft');
  const firstReloadStart = adminEvents.length;
  await click(page, 'Reload latest policy, keep draft');
  const firstReloadUserEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'GET' &&
      event.sequence >= firstReloadStart);
  const firstReloadInstanceEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-policy' &&
      event.pathname === POLICY_PATH && event.method === 'GET' &&
      event.sequence >= firstReloadStart);
  validateUserPolicy(await firstReloadUserEvent.payloadPromise, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instancePolicyRevision: 1,
    policy: { enabled: false, cidrs: targetCidrs, ports: [] },
    effectivePolicy: { enabled: false, cidrs: targetCidrs, ports: [] },
    updatedAt: 'set',
  });
  validatePolicy(await firstReloadInstanceEvent.payloadPromise, {
    revision: 1,
    cidrs: targetCidrs,
    ports: targetPorts,
  });
  const userReloadDraft = await readAccountDraft();
  assertThat(userReloadDraft.enabled &&
      userReloadDraft.cidrs === targetCidrs.join('\n') &&
      userReloadDraft.ports === targetPortsText,
    'reloading the latest user revision discarded the preserved draft');
  const selectedAfterUserReload = await pageVisibleText(page);
  assertThat(selectedAfterUserReload.includes('Selected state: disabled') &&
      selectedAfterUserReload.includes('ports: none'),
    'reloaded account policy did not distinguish selected state from preserved draft');
  reportBoolean('reload_latest_user_policy_kept_draft', true);

  setStage('preserve account draft after a stale instance-policy revision conflict');
  const competingInstanceWrite = await directApi(baseUrl, 'PUT', POLICY_PATH, {
    token: adminAccessToken,
    body: {
      expected_revision: 1,
      enabled: false,
      allow_cidrs: targetCidrs,
      allow_ports: targetPorts,
    },
  });
  reportStatus('competing_instance_policy_revision', competingInstanceWrite.status);
  assertThat(competingInstanceWrite.status === 200,
    'the instance revision conflict fixture update did not succeed');
  validatePolicy(competingInstanceWrite.payload, {
    revision: 2,
    enabled: false,
    cidrs: targetCidrs,
    ports: targetPorts,
  });
  const staleInstanceSaveStart = adminEvents.length;
  await click(page, 'Save override');
  const staleInstanceSave = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'PUT' &&
      event.sequence >= staleInstanceSaveStart);
  reportStatus('stale_instance_revision_account_save', staleInstanceSave.status);
  const staleInstancePayload = await staleInstanceSave.payloadPromise;
  assertThat(staleInstanceSave.hasBearer && staleInstanceSave.status === 409 &&
      exactKeys(staleInstanceSave.body, Object.keys(overrideRequest)) &&
      staleInstanceSave.body.expected_revision === 2 &&
      staleInstanceSave.body.expected_instance_policy_revision === 1 &&
      staleInstanceSave.body.enabled === true &&
      JSON.stringify(staleInstanceSave.body.allow_cidrs) === JSON.stringify(targetCidrs) &&
      JSON.stringify(staleInstanceSave.body.allow_ports) === JSON.stringify(targetPorts) &&
      staleInstancePayload?.error?.code === 'RELAY_USER_POLICY_CONFLICT',
    'stale instance-policy write did not return conflict for the preserved draft');
  assertNoLeaks(staleInstancePayload);
  await waitFor(() => page.getByRole('button', {
    name: 'Reload latest policy, keep draft', exact: true,
  }).isVisible());
  const staleInstanceDraft = await readAccountDraft();
  assertThat(staleInstanceDraft.enabled &&
      staleInstanceDraft.cidrs === targetCidrs.join('\n') &&
      staleInstanceDraft.ports === targetPortsText,
    'stale instance-policy conflict did not preserve the edited draft');
  const targetAfterStaleInstanceSave = await directApi(baseUrl, 'GET', targetPath, {
    token: adminAccessToken,
  });
  validateUserPolicy(targetAfterStaleInstanceSave.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instancePolicyRevision: 2,
    policy: { enabled: false, cidrs: targetCidrs, ports: [] },
    effectivePolicy: { enabled: false, cidrs: targetCidrs, ports: [] },
    updatedAt: 'set',
  });
  reportBoolean('stale_instance_revision_conflict_kept_draft_and_server_state', true);

  setStage('reload current instance revision and reset target account to inherit');
  const finalReloadStart = adminEvents.length;
  await click(page, 'Reload latest policy, keep draft');
  const finalReloadUserEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'GET' &&
      event.sequence >= finalReloadStart);
  const finalReloadInstanceEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-policy' &&
      event.pathname === POLICY_PATH && event.method === 'GET' &&
      event.sequence >= finalReloadStart);
  validateUserPolicy(await finalReloadUserEvent.payloadPromise, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instancePolicyRevision: 2,
    policy: { enabled: false, cidrs: targetCidrs, ports: [] },
    effectivePolicy: { enabled: false, cidrs: targetCidrs, ports: [] },
    updatedAt: 'set',
  });
  validatePolicy(await finalReloadInstanceEvent.payloadPromise, {
    revision: 2,
    enabled: false,
    cidrs: targetCidrs,
    ports: targetPorts,
  });
  const instanceReloadDraft = await readAccountDraft();
  assertThat(instanceReloadDraft.enabled &&
      instanceReloadDraft.cidrs === targetCidrs.join('\n') &&
      instanceReloadDraft.ports === targetPortsText,
    'reloading the latest instance revision discarded the account draft');
  const resetStart = adminEvents.length;
  await click(page, 'Reset to inherit');
  const resetEvent = await waitForEvent(adminEvents,
    (event) => event.route === 'relay-user-policy' &&
      event.pathname === targetPath && event.method === 'DELETE' &&
      event.sequence >= resetStart);
  reportStatus('administrator_account_policy_reset', resetEvent.status);
  assertThat(resetEvent.hasBearer && resetEvent.status === 200 &&
      exactKeys(resetEvent.body, ['expected_revision']) &&
      resetEvent.body.expected_revision === 2,
    'Settings did not submit the selected account revision for inherit reset');
  const resetResponse = await resetEvent.payloadPromise;
  const finalInstanceSelection = {
    enabled: false,
    cidrs: targetCidrs,
    ports: targetPorts,
  };
  validateUserPolicy(resetResponse, {
    userId: targetUserId,
    inherited: true,
    revision: 3,
    instancePolicyRevision: 2,
    policy: finalInstanceSelection,
    effectivePolicy: finalInstanceSelection,
    updatedAt: 'set',
  });
  await waitFor(() => hasVisibleSemanticText(
    page, 'Selection: inherited from the instance policy',
  ));
  const resetDraft = await readAccountDraft();
  assertThat(!resetDraft.enabled && resetDraft.cidrs === targetCidrs.join('\n') &&
      resetDraft.ports === targetPortsText,
    'reset did not restore the inherited instance values in the UI');
  const finalTargetResponse = await directApi(baseUrl, 'GET', targetPath, {
    token: adminAccessToken,
  });
  validateUserPolicy(finalTargetResponse.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 3,
    instancePolicyRevision: 2,
    policy: finalInstanceSelection,
    effectivePolicy: finalInstanceSelection,
    updatedAt: resetResponse.updated_at,
  });
  const currentAdminAfterReset = await directApi(
    baseUrl, 'GET', currentAdminPath, { token: adminAccessToken },
  );
  validateUserPolicy(currentAdminAfterReset.payload, {
    userId: currentAdminUserId,
    inherited: true,
    revision: 0,
    instancePolicyRevision: 2,
    policy: finalInstanceSelection,
    effectivePolicy: finalInstanceSelection,
    updatedAt: null,
  });
  reportBoolean('reset_restored_inheritance_for_target_only', true);

  setStage('verify user-policy audit ledger and target-identity privacy');
  const finalAudit = await directApi(baseUrl, 'GET', ADMIN_AUDIT_PATH, {
    token: adminAccessToken,
  });
  assertThat(finalAudit.status === 200,
    'administrator could not read policy audit records after account policy workflow');
  const policyAuditEvents = validateAdminAuditPage(finalAudit.payload).filter(
    (event) => event.action === 'admin.relay_policy_updated');
  const instanceAuditEvents = policyAuditEvents.filter(
    (event) => event.resource_type === 'relay_policy');
  const userAuditEvents = policyAuditEvents.filter(
    (event) => event.resource_type === 'relay_user_policy');
  assertThat(policyAuditEvents.length === 5 && instanceAuditEvents.length === 2 &&
      userAuditEvents.length === 3 &&
      instanceAuditEvents.every((event) => event.resource_id === null) &&
      userAuditEvents.every((event) => /^[0-9a-f]{64}$/.test(event.resource_id) &&
        event.resource_id !== targetUserId) &&
      policyAuditEvents.every((event) => event.actor_user_id === currentAdminUserId &&
        event.actor_device_id === adminDeviceId && event.result === 'success' &&
        event.source === 'api'),
    'policy write ledger did not contain only the expected successful instance and user writes');
  const auditText = JSON.stringify(policyAuditEvents);
  assertThat(!auditText.includes(targetUsername) && !auditText.includes(adminUsername) &&
      !auditText.includes(memberPassword) && !auditText.includes(adminPassword),
    'Relay policy audit records exposed account or credential data');
  reportBoolean('policy_write_audit_count_and_opaque_target_resource_valid', true);
}

async function createAdminProfile(page, baseUrl, events) {
  setStage('configure administrator registration page');
  await configurePage(page, baseUrl);
  setStage('fill administrator registration fields');
  await field(page, 'Owner email');
  setStage('fill administrator owner email');
  await fill(page, 'Owner email', adminUsername);
  setStage('fill administrator master password');
  await fill(page, 'Master password · 12+ characters', adminPassword);
  setStage('fill administrator password confirmation');
  await fill(page, 'Confirm master password', adminPassword);
  setStage('fill administrator bootstrap token');
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  setStage('fill administrator device name');
  await fill(page, 'Device name', 'Admin relay-policy acceptance');
  setStage('fill administrator first Vault name');
  await fill(page, 'First Vault', 'Admin relay-policy acceptance');
  const start = events.length;
  setStage('submit administrator registration');
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  setStage('wait for administrator registration');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string' &&
      typeof payload?.account_id === 'string' && typeof payload?.device_id === 'string',
    'administrator registration response was incomplete');
  leakSentinels.push(adminPassword, payload.access_token, payload.refresh_token);
  return {
    accessToken: payload.access_token,
    accountId: payload.account_id,
    deviceId: payload.device_id,
  };
}

async function createMemberProfile(page, baseUrl, events) {
  setStage('configure member invitation page');
  await configurePage(page, baseUrl);
  setStage('fill member invitation fields');
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Member relay-policy acceptance');
  await fill(page, 'First Vault', 'Member relay-policy acceptance');
  const start = events.length;
  setStage('submit member registration');
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string' &&
      typeof payload?.account_id === 'string' && UUID_PATTERN.test(payload.account_id) &&
      typeof payload?.device_id === 'string' && UUID_PATTERN.test(payload.device_id),
    'invited non-admin registration response was incomplete');
  leakSentinels.push(memberPassword, payload.access_token, payload.refresh_token);
  return {
    accessToken: payload.access_token,
    accountId: payload.account_id,
    deviceId: payload.device_id,
  };
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web bundle is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-relay-policy-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const lanIp = privateLanAddress();
    setStage('start isolated private Relay TCP sink');
    relayTargetSink = await startPrivateRelayTarget(lanIp);
    const relayTargetPort = relayTargetSink.port;
    const deploymentPorts = [...new Set([22, 2222, relayTargetPort])]
      .sort((left, right) => left - right);
    const instancePolicyPorts = [...new Set([22, relayTargetPort])]
      .sort((left, right) => left - right);
    const octets = lanIp.split('.').map(Number);
    const deploymentCidr = `${octets[0]}.${octets[1]}.${octets[2]}.0/24`;
    const suffix = crypto.randomUUID().slice(0, 8);
    adminUsername = `web-relay-policy-admin-${suffix}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-relay-policy-member-${suffix}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakSentinels.push(adminPassword, memberPassword, tempRoot, databasePath);
    const cleanEnv = Object.fromEntries(
      Object.entries(process.env).filter(([key]) => !key.startsWith('ATERMIUS_')),
    );
    const serverEnv = {
      ...cleanEnv,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'true',
      ATERMIUS_RELAY_ALLOW_CIDRS: deploymentCidr,
      ATERMIUS_RELAY_ALLOW_PORTS: deploymentPorts.join(','),
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };

    setStage('start disposable RFC1918-limited instance');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    serverStopConfirmed = false;
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated administrator and member profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const adminPage = await adminContext.newPage();
    const memberPage = await memberContext.newPage();
    adminPage.on('pageerror', () => { pageErrors += 1; });
    memberPage.on('pageerror', () => { pageErrors += 1; });
    trackApi(adminPage, adminEvents);
    trackApi(memberPage, memberEvents);

    setStage('register administrator and invited member');
    const adminProfile = await createAdminProfile(adminPage, baseUrl, adminEvents);
    adminAccessToken = adminProfile.accessToken;
    adminAccountId = adminProfile.accountId;
    adminDeviceId = adminProfile.deviceId;
    invitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'account invitation',
    );
    const memberProfile = await createMemberProfile(memberPage, baseUrl, memberEvents);
    memberAccessToken = memberProfile.accessToken;
    memberAccountId = memberProfile.accountId;
    memberDeviceId = memberProfile.deviceId;
    assertThat(memberAccountId !== adminAccountId,
      'invited account and current administrator unexpectedly share an identity');
    reportBoolean('two_isolated_profiles_registered', true);

    setStage('verify member controls hidden and API denied');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    assertThat(!await hasVisibleSemanticText(memberPage, 'SSH relay policy'),
      'non-admin profile rendered Relay policy controls');
    assertThat(!await hasVisibleSemanticText(memberPage, 'Account Relay policy') &&
        !await hasVisibleSemanticText(memberPage, 'Save override'),
      'non-admin profile rendered target-account Relay policy controls');
    const unauthenticated = await directApi(baseUrl, 'GET', POLICY_PATH);
    reportStatus('unauthenticated_policy_read', unauthenticated.status);
    assertThat(unauthenticated.status === 401, 'unauthenticated Relay policy read was not denied');
    const memberRead = await directApi(baseUrl, 'GET', POLICY_PATH, { token: memberAccessToken });
    reportStatus('member_policy_read', memberRead.status);
    assertThat(memberRead.status === 403 && memberRead.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin Relay policy read was not denied');
    const memberWrite = await directApi(baseUrl, 'PUT', POLICY_PATH, {
      token: memberAccessToken,
      body: {
        expected_revision: 0,
        enabled: true,
        allow_cidrs: [deploymentCidr],
        allow_ports: [22],
      },
    });
    reportStatus('member_policy_write', memberWrite.status);
    assertThat(memberWrite.status === 403 && memberWrite.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin Relay policy write was not denied');
    const memberUserPolicyPath = `${USER_POLICY_PREFIX}${memberAccountId}`;
    const memberUserPolicyRead = await directApi(baseUrl, 'GET', memberUserPolicyPath, {
      token: memberAccessToken,
    });
    reportStatus('member_account_policy_read', memberUserPolicyRead.status);
    assertThat(memberUserPolicyRead.status === 403 &&
        memberUserPolicyRead.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin account Relay policy read was not denied');
    const memberUserPolicyWrite = await directApi(baseUrl, 'PUT', memberUserPolicyPath, {
      token: memberAccessToken,
      body: {
        expected_revision: 0,
        expected_instance_policy_revision: 1,
        enabled: false,
        allow_cidrs: [deploymentCidr],
        allow_ports: [22],
      },
    });
    reportStatus('member_account_policy_write', memberUserPolicyWrite.status);
    assertThat(memberUserPolicyWrite.status === 403 &&
        memberUserPolicyWrite.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin account Relay policy write was not denied');
    const memberUserPolicyReset = await directApi(baseUrl, 'DELETE', memberUserPolicyPath, {
      token: memberAccessToken,
      body: { expected_revision: 0 },
    });
    reportStatus('member_account_policy_reset', memberUserPolicyReset.status);
    assertThat(memberUserPolicyReset.status === 403 &&
        memberUserPolicyReset.payload?.error?.code === 'INSTANCE_ADMIN_REQUIRED',
      'non-admin account Relay policy reset was not denied');
    reportBoolean('member_controls_hidden_and_api_denied', true);

    setStage('load and inspect safe deployment limits in Settings');
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'SSH relay policy'));
    const startRead = adminEvents.length;
    const loadButton = adminPage.getByRole('button', { name: /Load relay policy|Refresh relay policy/ }).first();
    await selectServerModeIfChooser(adminPage, loadButton);
    await loadButton.click();
    const loaded = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-policy' && event.method === 'GET' &&
        event.sequence >= startRead && event.hasBearer && event.status === 200);
    const initial = await loaded.payloadPromise;
    validatePolicy(initial, {
      revision: 0,
      cidrs: [deploymentCidr],
      ports: deploymentPorts,
    });
    assertThat(initial.updated_at === null, 'unconfigured policy did not report a null update time');
    const safeLimits = await pageVisibleText(adminPage);
    assertThat(safeLimits.includes('Saved settings can only narrow the immutable limits configured by the server operator.') &&
        safeLimits.includes('Deployment relay availability') && safeLimits.includes('Available') &&
        safeLimits.includes(deploymentCidr) &&
        safeLimits.includes(deploymentPorts.join(', ')) &&
        safeLimits.includes('ATERMIUS_RELAY_ENABLED=true'),
      'Settings omitted immutable deployment ceilings or the deployment gate explanation');
    assertNoLeaks(safeLimits);
    reportBoolean('safe_limits_and_deployment_gate_rendered', true);

    setStage('save a narrower policy through the Settings form');
    const cidrsField = await field(adminPage, 'Allowed CIDRs');
    const portsField = await field(adminPage, 'Allowed ports');
    await fill(adminPage, 'Allowed CIDRs', `${lanIp}/32`);
    await fill(adminPage, 'Allowed ports', instancePolicyPorts.join('\n'));
    const saveStart = adminEvents.length;
    await click(adminPage, 'Save relay policy');
    const savedEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-policy' && event.method === 'PUT' &&
        event.sequence >= saveStart);
    reportStatus('administrator_policy_save', savedEvent.status);
    assertThat(savedEvent.status === 200 && savedEvent.hasBearer &&
        exactKeys(savedEvent.body, ['expected_revision', 'enabled', 'allow_cidrs', 'allow_ports']) &&
        savedEvent.body.expected_revision === 0 && savedEvent.body.enabled === true &&
        JSON.stringify(savedEvent.body.allow_cidrs) === JSON.stringify([`${lanIp}/32`]) &&
        JSON.stringify(savedEvent.body.allow_ports) === JSON.stringify(instancePolicyPorts),
      'Settings submitted an incorrect or non-strict Relay policy body');
    const saved = await savedEvent.payloadPromise;
    validatePolicy(saved, {
      revision: 1,
      cidrs: [`${lanIp}/32`],
      ports: instancePolicyPorts,
    });
    assertThat(saved.updated_at !== null, 'saved policy omitted its update time');
    reportBoolean('administrator_saved_narrow_policy', true);

    setStage('validate real Relay policy writer in the instance audit API');
    const auditFeed = await directApi(baseUrl, 'GET', ADMIN_AUDIT_PATH, {
      token: adminAccessToken,
    });
    reportStatus('administrator_relay_policy_audit_feed', auditFeed.status);
    assertThat(auditFeed.status === 200,
      'administrator could not read the instance audit feed after saving Relay policy');
    const apiAuditEvent = validateRelayPolicyAuditEvent(auditFeed.payload, {
      accountId: adminAccountId,
      deviceId: adminDeviceId,
    });
    reportBoolean('relay_policy_audit_actor_resource_source_result_valid', true);
    reportBoolean('relay_policy_audit_resource_id_null_and_private_dto', true);

    setStage('render real Relay policy audit event in the Settings audit card');
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const auditButton = await hasVisibleSemanticText(adminPage, 'Refresh admin audit')
      ? 'Refresh admin audit'
      : 'Load admin audit';
    const auditRefreshStart = adminEvents.length;
    await click(adminPage, auditButton);
    const auditRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.sequence >= auditRefreshStart);
    const refreshedAuditPayload = await auditRefresh.payloadPromise;
    reportStatus('settings_relay_policy_audit_refresh', auditRefresh.status);
    assertThat(auditRefresh.hasBearer && auditRefresh.status === 200,
      'Settings audit-card refresh was not authenticated and successful');
    const refreshedAuditEvent = validateRelayPolicyAuditEvent(refreshedAuditPayload, {
      accountId: adminAccountId,
      deviceId: adminDeviceId,
    });
    assertThat(JSON.stringify(refreshedAuditEvent) === JSON.stringify(apiAuditEvent),
      'Settings refresh did not render the same validated Relay policy audit event');
    await scrollUntilVisibleSemanticText(adminPage, '管理员已更新 SSH Relay 策略');
    const rawAuditActionVisible = await hasVisibleSemanticText(
      adminPage, 'admin.relay_policy_updated');
    reportBoolean('relay_policy_audit_action_localized', true);
    reportBoolean('relay_policy_audit_raw_action_hidden', !rawAuditActionVisible);
    assertThat(!rawAuditActionVisible,
      'Settings audit card displayed the raw Relay policy action key');

    setStage('reload and verify persisted policy values');
    const startReload = adminEvents.length;
    const reloadButton = adminPage.getByRole('button', { name: 'Refresh relay policy', exact: true }).first();
    await selectServerModeIfChooser(adminPage, reloadButton);
    await reloadButton.click();
    const reloadedEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'relay-policy' && event.method === 'GET' &&
        event.sequence >= startReload && event.status === 200);
    const reloaded = await reloadedEvent.payloadPromise;
    validatePolicy(reloaded, {
      revision: 1,
      cidrs: [`${lanIp}/32`],
      ports: instancePolicyPorts,
    });
    assertThat(reloaded.updated_at === saved.updated_at &&
        await cidrsField.inputValue() === `${lanIp}/32` &&
        await portsField.inputValue() === instancePolicyPorts.join('\n'),
      'Settings did not reload the persisted Relay policy into its form');
    await exerciseAccountRelayPolicyUi({
      page: adminPage,
      memberPage,
      baseUrl,
      databasePath,
      relayTargetSink,
      targetUserId: memberAccountId,
      targetUsername: memberUsername,
      currentAdminUserId: adminAccountId,
      lanIp,
      deploymentCidr,
      targetPort: relayTargetPort,
      currentAdminDeviceId: adminDeviceId,
      targetDeviceId: memberDeviceId,
    });
    const finalText = await pageVisibleText(adminPage);
    assertNoLeaks(finalText);
    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    assertThat(localCanvasKitBootstrapCount === 2,
      'test did not use the same-origin CanvasKit configuration for both real browser profiles');
    assertThat(externalRequestOrigins.length === 0,
      'browser attempted to load a public origin instead of same-origin bundled assets');
    assertThat(flutterAssetStatuses.some((item) => item === 'canvaskit.js:200') &&
        flutterAssetStatuses.some((item) => item === 'canvaskit.wasm:200'),
      'same-origin CanvasKit assets did not load from the current bundle');
    reportBoolean('self_only_csp_preserved', true);
    reportBoolean('same_origin_bundled_canvaskit_used_test_only', true);
    reportBoolean('public_resource_requests_absent', true);
    reportBoolean('reloaded_policy_persisted_and_browser_clean', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary server, browser profile or fixture did not clean up');
  assertThat(!tempRoot || !fs.existsSync(tempRoot), 'disposable Relay policy roots remained after cleanup');
  setStage('complete');
  console.log('WEB-ADMIN-RELAY-POLICY-01 passed');
}

main().catch(async (error) => {
  await cleanup();
  console.error(`stage: ${stage}`);
  console.error(`assertion: ${typeof error?.safeAssertion === 'string'
    ? error.safeAssertion : 'unclassified failure'}`);
  if (typeof error?.name === 'string' && error.name !== 'Error') {
    console.error(`failure_type: ${error.name}`);
  }
  if (cleanupFailed) console.error('assertion: temporary resource cleanup failed');
  process.exitCode = 1;
});
