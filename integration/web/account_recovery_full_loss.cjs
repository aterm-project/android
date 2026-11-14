/*
 * WEB-RECOVERY-FULL-LOSS-01: current-bundle browser acceptance for TOTP MFA,
 * MFA recovery-code login/replay handling, and signed full account recovery
 * from a clean device. Everything uses a disposable server/account/profile.
 * Output is limited to safe stages, HTTP statuses, counts and booleans.
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
const SERVER_BINARY = process.env.ATERMIUS_WEB_TEST_SERVER_BINARY
  ? path.resolve(process.env.ATERMIUS_WEB_TEST_SERVER_BINARY)
  : path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const PG_RECOVERY_BASE_URL = process.env.ATERMIUS_PG_RECOVERY_WEB_BASE_URL;
const PG_RECOVERY_NODE_A_URL = process.env.ATERMIUS_PG_RECOVERY_WEB_NODE_A_URL;
const PG_RECOVERY_NODE_B_URL = process.env.ATERMIUS_PG_RECOVERY_WEB_NODE_B_URL;
const PG_RECOVERY_PROBE_URL = process.env.ATERMIUS_PG_RECOVERY_WEB_PROBE_URL;
const PG_RECOVERY_PROBE_TOKEN = process.env.ATERMIUS_PG_RECOVERY_WEB_PROBE_TOKEN;
const PG_RECOVERY_USERNAME = process.env.ATERMIUS_PG_RECOVERY_WEB_USERNAME;
const PG_RECOVERY_BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_RECOVERY_WEB_BOOTSTRAP_TOKEN;
const PG_RECOVERY_MODE = Boolean(PG_RECOVERY_BASE_URL);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

let stage = 'preflight';
let tempRoot;
let dataDir;
let databasePath;
let mfaKeyFile;
let serverLogFd;
let serverProcess;
let proxyServer;
let browser;
let context;
let page;
let secondContext;
let recoveryPage;
let memberContext;
let memberPage;
let bootstrapToken;
let username;
let password;
let replacementPassword;
let sharedUsername;
let sharedPassword;
let accountInviteToken;
let vaultInviteToken;
let shareRequestCard;
let sharedVaultName;
let beforeMfaVaultIds = new Set();
let vaultRecoveryCode;
let preRecoveryAccessToken;
let mfaSeedText;
let mfaUri;
let mfaRecoveryCodes = [];
const mfaMaterialNeedles = [];
const vaultRecoveryNeedles = [];
let pageErrors = 0;
let cleanupFailed = false;
let cleanupPromise;
const events = [];
const wireBodies = [];
const consoleMessages = [];
const pageErrorMessages = [];
const proxyRoutes = [];
const recoveryChallengeSecrets = [];
const extraSecrets = [];
const inviteTokenNeedles = [];

function assertThat(ok, message) { if (!ok) throw new Error(message); }
function setStage(value) { stage = value; console.log(`stage: ${value}`); }
function report(label, value) { console.log(`assert: ${label}=${typeof value === 'object' ? JSON.stringify(value) : value}`); }
function safeDiagnostic(value) {
  let text = String(value ?? '');
  const secrets = [bootstrapToken, username, password, replacementPassword, sharedUsername,
    sharedPassword, accountInviteToken, vaultInviteToken, shareRequestCard, vaultRecoveryCode,
    mfaSeedText, mfaUri, ...extraSecrets, ...mfaRecoveryCodes, ...mfaMaterialNeedles,
    ...vaultRecoveryNeedles]
    .filter((secret) => typeof secret === 'string' && secret.length > 0)
    .sort((left, right) => right.length - left.length);
  for (const secret of secrets) text = text.split(secret).join('[redacted]');
  return text
    .replace(/otpauth:\/\/totp\/[^\s"']+/gi, '[provisioning-uri]')
    .replace(/\b[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}\b/g, '[recovery-code]')
    .replace(/\b[A-Z2-7]{32}\b/g, '[totp-seed]')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '[token]')
    .replace(/Bearer\s+[^\s"']+/gi, 'Bearer [redacted]').slice(0, 400);
}

function run(command, args, { env = process.env, timeout = 180000, stdio = ['ignore', 'pipe', 'ignore'] } = {}) {
  const result = spawnSync(command, args, { cwd: ROOT, env, encoding: 'utf8', timeout,
    maxBuffer: 16 * 1024 * 1024, stdio });
  if (result.error || result.status !== 0) throw new Error(`${command} failed`);
  return result.stdout || '';
}

function buildServer() {
  if (process.env.ATERMIUS_WEB_TEST_SERVER_BINARY) {
    assertThat(fs.existsSync(SERVER_BINARY), 'configured server test binary is unavailable');
    return;
  }
  run('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], { stdio: 'ignore' });
  assertThat(fs.existsSync(SERVER_BINARY), 'server binary is unavailable');
}

async function unusedPort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
  return port;
}

function processGroupAlive(group) {
  try {
    for (const entry of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(entry)) continue;
      let stat;
      try { stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8'); } catch (_) { continue; }
      const close = stat.lastIndexOf(')');
      if (close < 0) continue;
      const fields = stat.slice(close + 2).trim().split(/\s+/);
      if (Number(fields[2]) === group && fields[0] !== 'Z' && fields[0] !== 'X') return true;
    }
    return false;
  } catch (_) {
    try { process.kill(-group, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
  }
}

async function stopServer() {
  if (!serverProcess?.pid || !processGroupAlive(serverProcess.pid)) return;
  const group = serverProcess.pid;
  try { process.kill(-group, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline && processGroupAlive(group)) await new Promise((resolve) => setTimeout(resolve, 100));
  if (processGroupAlive(group)) {
    try { process.kill(-group, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    const killDeadline = Date.now() + 3000;
    while (Date.now() < killDeadline && processGroupAlive(group)) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (processGroupAlive(group)) throw new Error('isolated server process did not stop');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    password = undefined;
    replacementPassword = undefined;
    sharedUsername = undefined;
    sharedPassword = undefined;
    accountInviteToken = undefined;
    vaultInviteToken = undefined;
    shareRequestCard = undefined;
    vaultRecoveryCode = undefined;
    mfaSeedText = undefined;
    mfaUri = undefined;
    mfaRecoveryCodes.fill('');
    mfaRecoveryCodes = [];
    mfaMaterialNeedles.fill('');
    vaultRecoveryNeedles.fill('');
    recoveryChallengeSecrets.fill('');
    extraSecrets.fill('');
    inviteTokenNeedles.fill('');
    preRecoveryAccessToken = undefined;
    try {
      if (context) await context.close().catch(() => {});
      if (secondContext) await secondContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
      if (proxyServer?.listening) {
        for (const socket of proxyServer._upgradeSockets || []) socket.destroy();
        await new Promise((resolve, reject) => proxyServer.close((error) => error ? reject(error) : resolve()));
      }
      await stopServer();
    } catch (_) { cleanupFailed = true; }
    finally {
      if (serverLogFd !== undefined) {
        try { fs.closeSync(serverLogFd); } catch (_) { cleanupFailed = true; }
        serverLogFd = undefined;
      }
      if (tempRoot) {
        try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch (_) { cleanupFailed = true; }
        if (fs.existsSync(tempRoot)) cleanupFailed = true;
      }
    }
  })();
  return cleanupPromise;
}

function pgUpstream(value) {
  const parsed = new URL(value || '');
  assertThat(parsed.protocol === 'http:' && parsed.hostname === '127.0.0.1',
    'PG Recovery browser acceptance requires loopback HTTP nodes');
  return { hostname: parsed.hostname, port: Number(parsed.port) };
}

function pgRecoveryNode(pathname) {
  return /^\/api\/v1\/auth\/recovery(?:\/|$)/.test(pathname) ? 'B' : 'A';
}

function makePgRecoveryProxy(baseUrl) {
  const origin = new URL(baseUrl);
  const upstreams = { A: pgUpstream(PG_RECOVERY_NODE_A_URL), B: pgUpstream(PG_RECOVERY_NODE_B_URL) };
  const server = require('node:http').createServer((request, response) => {
    const url = new URL(request.url || '/', baseUrl);
    const node = pgRecoveryNode(url.pathname);
    const target = upstreams[node];
    const record = { method: request.method || 'GET', path: url.pathname, node, status: null };
    if (url.pathname.startsWith('/api/v1/')) proxyRoutes.push(record);
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    const upstreamRequest = require('node:http').request({
      hostname: target.hostname, port: target.port, method: request.method,
      path: `${url.pathname}${url.search}`, headers,
    }, (upstreamResponse) => {
      record.status = upstreamResponse.statusCode || null;
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    });
    upstreamRequest.on('error', () => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
      response.end('upstream unavailable');
    });
    request.pipe(upstreamRequest);
  });
  const upgradeSockets = new Set();
  server.on('upgrade', (request, clientSocket, clientHead) => {
    const url = new URL(request.url || '/', baseUrl);
    const target = upstreams[pgRecoveryNode(url.pathname)];
    const headers = { ...request.headers, host: `127.0.0.1:${target.port}` };
    delete headers['proxy-connection'];
    const upstreamRequest = require('node:http').request({
      hostname: target.hostname, port: target.port, method: 'GET',
      path: `${url.pathname}${url.search}`, headers,
    });
    upstreamRequest.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      let responseHead = `HTTP/1.1 ${upstreamResponse.statusCode || 101} ${upstreamResponse.statusMessage || 'Switching Protocols'}\r\n`;
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        responseHead += `${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`;
      }
      clientSocket.write(`${responseHead}\r\n`);
      if (clientHead?.length) upstreamSocket.write(clientHead);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      upgradeSockets.add(clientSocket);
      upgradeSockets.add(upstreamSocket);
      clientSocket.on('close', () => upgradeSockets.delete(clientSocket));
      upstreamSocket.on('close', () => upgradeSockets.delete(upstreamSocket));
      clientSocket.pipe(upstreamSocket);
      upstreamSocket.pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      clientSocket.write(`HTTP/1.1 ${upstreamResponse.statusCode || 502} ${upstreamResponse.statusMessage || 'Bad Gateway'}\r\n`);
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        clientSocket.write(`${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`);
      }
      clientSocket.write('\r\n');
      upstreamResponse.pipe(clientSocket);
    });
    upstreamRequest.on('error', () => clientSocket.destroy());
    clientSocket.on('close', () => upstreamRequest.destroy());
    upstreamRequest.end();
  });
  server._upgradeSockets = upgradeSockets;
  return server;
}

process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function waitFor(predicate, timeoutMs = 30000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web UI state did not appear');
}

async function waitForServer(baseUrl) {
  const end = Date.now() + 30000;
  while (Date.now() < end) {
    if (serverProcess.exitCode !== null) throw new Error('server exited early');
    try {
      if ((await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1000) })).status === 200) return;
    } catch (_) { /* Wait for the isolated listener. */ }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('server readiness timed out');
}

async function field(target, label) {
  const locator = target.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`).first();
  await selectServerModeIfChooser(target, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function button(target, label) {
  const locator = target.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(target, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function click(target, label) { await (await button(target, label)).click(); }

async function fill(target, label, value) {
  const locator = await field(target, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await target.waitForTimeout(100);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 35 });
    await target.waitForTimeout(120);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await target.waitForTimeout(80);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('visible form field did not retain input');
}

function routeName(url) {
  try {
    const pathName = new URL(url).pathname;
    if (!pathName.startsWith('/api/v1/')) return null;
    return pathName.slice('/api/v1/'.length).split('/').map((part) => UUID.test(part) ? ':id' : part).join('/');
  } catch (_) { return null; }
}

function safeSummary(route, text) {
  try {
    const value = JSON.parse(text);
    if (route === 'auth/login') return {
      mfaRequired: value.mfa_required === true,
      sessionIssued: typeof value.access_token === 'string' && typeof value.refresh_token === 'string',
    };
    if (route === 'auth/login/mfa') return {
      sessionIssued: typeof value.access_token === 'string' && typeof value.refresh_token === 'string',
    };
    if (route === 'auth/mfa') return {
      enabled: typeof value.enabled === 'boolean' ? value.enabled : null,
      recoveryCodesRemaining: Number.isInteger(value.recovery_codes_remaining) ? value.recovery_codes_remaining : null,
    };
    if (route === 'auth/mfa/recovery-codes') return {
      recoveryCodesIssued: Array.isArray(value.recovery_codes) ? value.recovery_codes.length : null,
    };
    if (route === 'auth/recovery/start') return {
      challengePresent: typeof value.challenge === 'string',
      generation: Number.isInteger(value.recovery_generation) ? value.recovery_generation : null,
      challengeIdHash: typeof value.challenge_id === 'string'
        ? crypto.createHash('sha256').update(value.challenge_id).digest('hex') : null,
      challengeHash: typeof value.challenge === 'string'
        ? crypto.createHash('sha256').update(Buffer.from(value.challenge, 'base64url')).digest('hex') : null,
    };
    if (route === 'auth/recovery/inspect') return {
      requiredContexts: Array.isArray(value.required_contexts) ? value.required_contexts.length : -1,
      presentContexts: Array.isArray(value.present_contexts) ? value.present_contexts.length : -1,
      requiredContextTuples: Array.isArray(value.required_contexts)
        ? value.required_contexts.map((item) => ({
          vaultId: typeof item?.vault_id === 'string' ? item.vault_id : null,
          keyEpoch: Number.isSafeInteger(item?.key_epoch) ? item.key_epoch : null,
          membershipVersion: Number.isSafeInteger(item?.membership_version)
            ? item.membership_version : null,
        })) : [],
    };
    if (route === 'auth/recovery/complete') return {
      recovered: value.status === 'recovered',
      recoveredDevicePresent: typeof value.device_id === 'string',
      recoveredDeviceId: typeof value.device_id === 'string' ? value.device_id : null,
      recoveryGeneration: Number.isInteger(value.recovery_generation) ? value.recovery_generation : null,
      errorCode: typeof value.error?.code === 'string' && /^[A-Z0-9_]{1,64}$/.test(value.error.code)
        ? value.error.code : null,
    };
    if (route === 'vaults/:id/keys/rotate') return {
      vaultId: typeof value.vault_id === 'string' ? value.vault_id : null,
      ownerUserId: typeof value.owner_user_id === 'string' ? value.owner_user_id : null,
      activeKeyEpoch: Number.isSafeInteger(value.active_key_epoch)
        ? value.active_key_epoch : null,
      membershipVersion: Number.isSafeInteger(value.membership_version)
        ? value.membership_version : null,
      vaultStatus: typeof value.status === 'string' ? value.status : null,
      errorCode: typeof value.error?.code === 'string' &&
        /^[A-Z0-9_]{1,64}$/.test(value.error.code) ? value.error.code : null,
    };
  } catch (_) { /* Error response details are never logged. */ }
  return {};
}

async function observe(target, origin, { captureSession = true } = {}) {
  const requests = new WeakMap();
  target.on('request', (request) => {
    const route = routeName(request.url());
    let sameOrigin = false;
    try { sameOrigin = new URL(request.url()).origin === origin; } catch (_) { /* Ignore. */ }
    const body = request.postData() || '';
    if (sameOrigin && body) wireBodies.push(body);
    requests.set(request, { route, method: request.method(), hasBearer: (request.headers().authorization || '').startsWith('Bearer ') });
  });
  target.on('response', async (response) => {
    const metadata = requests.get(response.request());
    if (!metadata?.route) return;
    let body = '';
    try { body = await response.text(); } catch (_) { /* Ignore unreadable response body. */ }
    if (body) wireBodies.push(body);
    if (captureSession && ['auth/register', 'auth/login', 'auth/login/mfa'].includes(metadata.route)
        && response.status() === 200) {
      try {
        const value = JSON.parse(body);
        if (typeof value.access_token === 'string') preRecoveryAccessToken = value.access_token;
      } catch (_) { /* Never surface an unreadable token response. */ }
    }
    if (metadata.route === 'auth/recovery/start') {
      try {
        const value = JSON.parse(body);
        if (typeof value.challenge_id === 'string') recoveryChallengeSecrets.push(value.challenge_id);
        if (typeof value.challenge === 'string') recoveryChallengeSecrets.push(value.challenge);
      } catch (_) { /* Never surface an unreadable challenge response. */ }
    }
    events.push({ route: metadata.route, method: metadata.method, status: response.status(), hasBearer: metadata.hasBearer,
      ...safeSummary(metadata.route, body) });
  });
  target.on('console', (message) => consoleMessages.push(safeDiagnostic(message.text())));
  target.on('pageerror', (error) => {
    pageErrors += 1;
    pageErrorMessages.push(safeDiagnostic(`${error?.name || 'Error'}: ${error?.message || ''}`));
  });
}

async function waitForEvent(predicate, timeoutMs = 30000) {
  await waitFor(() => events.some(predicate), timeoutMs);
  return events.find(predicate);
}

async function activate(target, baseUrl, observeOptions) {
  await observe(target, baseUrl, observeOptions);
  setStage('load Flutter Web bundle');
  await target.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => target.evaluate(() => typeof window.sodium?.ready?.then === 'function'
    && Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  setStage('activate Flutter accessibility semantics');
  await target.evaluate(async () => { await window.sodium.ready; });
  await target.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => target.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  setStage('connect Flutter Web to isolated server');
  await fill(target, 'Server URL', baseUrl);
  await click(target, 'Connect securely');
}

async function readMfaEnrollment(target) {
  await target.getByText('Set up authenticator app', { exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  const material = await target.locator('flt-semantics').evaluateAll((elements) => {
    let secret = '';
    let uri = '';
    const valuesToScan = [document.body.innerText, document.body.textContent];
    for (const element of elements) {
      valuesToScan.push(element.innerText, element.textContent,
        element.getAttribute('aria-label'), element.getAttribute('aria-valuetext'));
    }
    for (const value of valuesToScan) {
      if (typeof value !== 'string') continue;
      const text = value.trim();
      const compact = text.replace(/[\s\u200B-\u200D\uFEFF]/g, '');
      const seed = compact.match(/[A-Z2-7]{32}/g)?.at(-1);
      if (seed) secret = seed;
      const match = compact.match(/otpauth:\/\/totp\/[^\s]+/);
      if (match) uri = match[0];
    }
    return {
      secret,
      uri,
      diagnostics: {
        bodyTextLength: (document.body.innerText || '').length,
        semanticCount: elements.length,
        seedPatternPresent: valuesToScan.some((value) => typeof value === 'string'
          && /[A-Z2-7]{32}/.test(value.replace(/[\s\u200B-\u200D\uFEFF]/g, ''))),
        uriPatternPresent: valuesToScan.some((value) => typeof value === 'string'
          && /otpauth:\/\/totp\//.test(value.replace(/[\s\u200B-\u200D\uFEFF]/g, ''))),
      },
    };
  });
  assertThat(/^[A-Z2-7]{32}$/.test(material.secret),
    `TOTP secret was not available through transient UI semantics (${JSON.stringify(material.diagnostics)})`);
  const uri = new URL(material.uri);
  assertThat(uri.protocol === 'otpauth:' && uri.hostname === 'totp'
    && uri.searchParams.get('secret') === material.secret, 'TOTP provisioning URI did not match the displayed seed');
  mfaSeedText = material.secret;
  mfaUri = material.uri;
  mfaMaterialNeedles.push(material.secret, material.uri);
}

function decodeBase32(text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let buffer = 0;
  let bits = 0;
  const bytes = [];
  for (const char of text) {
    const value = alphabet.indexOf(char);
    if (value < 0) throw new Error('invalid test TOTP seed');
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) { bits -= 8; bytes.push((buffer >> bits) & 255); }
  }
  const result = Buffer.from(bytes);
  if (result.length !== 20) throw new Error('invalid test TOTP seed length');
  return result;
}

function totpAtStep(secret, step) {
  const seed = decodeBase32(secret);
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = crypto.createHmac('sha1', seed).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary = ((digest[offset] & 0x7f) << 24) | (digest[offset + 1] << 16)
    | (digest[offset + 2] << 8) | digest[offset + 3];
  seed.fill(0);
  counter.fill(0);
  return String(binary % 1000000).padStart(6, '0');
}

function currentTotpStep() { return Math.floor(Date.now() / 1000 / 30); }

async function freshTotp(secret, afterStep = -1) {
  while (currentTotpStep() <= afterStep) {
    const remaining = 30000 - (Date.now() % 30000);
    await new Promise((resolve) => setTimeout(resolve, Math.min(remaining + 100, 1000)));
  }
  let step = currentTotpStep();
  const remaining = 30000 - (Date.now() % 30000);
  if (remaining < 4500) {
    await new Promise((resolve) => setTimeout(resolve, remaining + 300));
    step = currentTotpStep();
  }
  return { code: totpAtStep(secret, step), step };
}

async function readMfaCodes(target) {
  await target.getByRole('checkbox', { name: 'I saved these codes securely', exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  const codes = await target.locator('flt-semantics').evaluateAll((elements) => {
    const matches = new Set();
    const pattern = /[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}/g;
    for (const element of elements) {
      for (const value of [element.innerText, element.textContent, element.getAttribute('aria-label'), element.getAttribute('aria-valuetext')]) {
        if (typeof value !== 'string') continue;
        for (const found of value.matchAll(pattern)) matches.add(found[0]);
      }
    }
    return [...matches];
  });
  assertThat(codes.length === 10, 'one-time MFA recovery dialog did not show ten unique codes');
  mfaRecoveryCodes = codes;
  mfaMaterialNeedles.push(...codes);
}

async function confirmMfaCodes(target) {
  const checkbox = target.getByRole('checkbox', { name: 'I saved these codes securely', exact: true });
  await checkbox.click();
  await waitFor(async () => (await checkbox.getAttribute('aria-checked')) === 'true', 5000);
  await click(target, 'Finish');
}

async function enrollMfa(target, baseUrl, currentPassword) {
  await click(target, 'Settings');
  await click(target, 'Set up authenticator');
  await fill(target, 'Current master password', currentPassword);
  await click(target, 'Continue');
  const setupIndex = events.length;
  const setup = await waitForEvent((event) => event.route === 'auth/mfa/totp/setup'
    && event.method === 'POST' && events.indexOf(event) >= setupIndex);
  assertThat(setup.status === 200 && setup.hasBearer, 'authenticated TOTP setup failed');
  await readMfaEnrollment(target);
  const proof = await freshTotp(mfaSeedText);
  await fill(target, 'Authenticator code', proof.code);
  const confirmIndex = events.length;
  await click(target, 'Verify and enable');
  const confirmed = await waitForEvent((event) => event.route === 'auth/mfa/totp/confirm'
    && event.method === 'POST' && events.indexOf(event) >= confirmIndex);
  assertThat(confirmed.status === 200 && confirmed.hasBearer, 'TOTP confirmation failed');
  await readMfaCodes(target);
  await confirmMfaCodes(target);
  await target.getByRole('button', { name: 'Disable MFA', exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  return proof.step;
}

async function lockWorkspace(target) {
  const lock = target.getByRole('button', { name: 'Lock workspace', exact: true }).first();
  await lock.waitFor({ state: 'visible', timeout: 15000 });
  await lock.click();
  await button(target, 'Unlock workspace');
  await click(target, 'Sign out');
  await field(target, 'Email or username');
}

async function beginMfaLogin(target, currentPassword) {
  await fill(target, 'Email or username', username);
  await fill(target, 'Master password', currentPassword);
  const start = events.length;
  await click(target, 'Sign in and unlock');
  const login = await waitForEvent((event) => event.route === 'auth/login'
    && event.method === 'POST' && events.indexOf(event) >= start);
  assertThat(login.status === 202 && login.mfaRequired && !login.sessionIssued && !login.hasBearer,
    'password-only login did not stop at an MFA challenge without a session');
  return { start: events.length, login };
}

async function submitMfa(target, method, code, expectedStatus) {
  if (method === 'recovery_code') {
    const toggle = target.getByRole('button', { name: 'Use a recovery code', exact: true });
    if (await toggle.count()) await toggle.click();
    await fill(target, 'Recovery code', code);
  } else {
    const toggle = target.getByRole('button', { name: 'Use authenticator code', exact: true });
    if (await toggle.count()) await toggle.click();
    await fill(target, 'Authenticator code', code);
  }
  const start = events.length;
  await click(target, 'Verify and unlock');
  const result = await waitForEvent((event) => event.route === 'auth/login/mfa'
    && event.method === 'POST' && events.indexOf(event) >= start);
  assertThat(result.status === expectedStatus, `MFA login returned unexpected HTTP ${result.status}`);
  if (expectedStatus === 200) {
    assertThat(result.sessionIssued && !result.hasBearer, 'MFA success response did not issue the session DTO');
    await button(target, 'Add host');
  } else {
    assertThat(!result.sessionIssued, 'failed MFA proof issued a session');
  }
  return result;
}

async function signInNormally(target, currentPassword) {
  await fill(target, 'Email or username', username);
  await fill(target, 'Master password', currentPassword);
  const start = events.length;
  await click(target, 'Sign in and unlock');
  const login = await waitForEvent((event) => event.route === 'auth/login'
    && event.method === 'POST' && events.indexOf(event) >= start);
  assertThat(login.status === 200 && !login.mfaRequired && login.sessionIssued && !login.hasBearer,
    'replacement-password login should succeed without an MFA challenge after full Recovery');
  await button(target, 'Add host');
}

async function inspectBrowserPersistence(target, needles) {
  return target.evaluate(async (values) => {
    const text = values.filter((value) => typeof value === 'string' && value.length >= 16);
    const encoder = new TextEncoder();
    const bytePatterns = text.map((needle) => encoder.encode(needle));
    let matched = false;
    let failures = 0;
    const check = (value) => {
      if (typeof value === 'string' && text.some((needle) => value.includes(needle))) matched = true;
    };
    const checkBytes = (bytes) => {
      const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      for (const pattern of bytePatterns) {
        if (pattern.length > data.length) continue;
        outer: for (let start = 0; start <= data.length - pattern.length; start += 1) {
          for (let offset = 0; offset < pattern.length; offset += 1) {
            if (data[start + offset] !== pattern[offset]) continue outer;
          }
          matched = true;
          return;
        }
      }
    };
    const seen = new WeakSet();
    const visit = async (value) => {
      if (typeof value === 'string') { check(value); return; }
      if (!value || typeof value !== 'object') return;
      if (value instanceof Blob) { checkBytes(await value.arrayBuffer()); return; }
      if (value instanceof ArrayBuffer) { checkBytes(value); return; }
      if (ArrayBuffer.isView(value)) {
        checkBytes(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
        return;
      }
      if (seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) { for (const item of value) await visit(item); return; }
      for (const [key, item] of Object.entries(value)) { check(key); await visit(item); }
    };
    for (const storageName of ['localStorage', 'sessionStorage']) {
      try {
        const storage = window[storageName];
        for (let index = 0; index < storage.length; index += 1) {
          const key = storage.key(index);
          check(key || '');
          check(key ? storage.getItem(key) || '' : '');
        }
      } catch (_) {
        failures += 1;
      }
    }
    try {
      const databases = await indexedDB.databases();
      for (const info of databases) {
        if (!info.name) continue;
        const db = await new Promise((resolve, reject) => {
          const request = indexedDB.open(info.name);
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
          request.onblocked = () => reject(new Error('blocked'));
        });
        try {
          for (const store of Array.from(db.objectStoreNames)) {
            const rows = await new Promise((resolve, reject) => {
              const request = db.transaction(store, 'readonly').objectStore(store).getAll();
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            for (const row of rows) await visit(row);
          }
        } finally { db.close(); }
      }
    } catch (_) { failures += 1; }
    try {
      const cacheNames = await caches.keys();
      for (const cacheName of cacheNames) {
        check(cacheName);
        const cache = await caches.open(cacheName);
        for (const request of await cache.keys()) {
          check(request.url);
          const response = await cache.match(request);
          if (!response) continue;
          for (const [key, value] of response.headers.entries()) { check(key); check(value); }
          checkBytes(await response.arrayBuffer());
        }
      }
    } catch (_) { failures += 1; }
    try {
      if (typeof navigator.storage?.getDirectory !== 'function') throw new Error('OPFS unavailable');
      const root = await navigator.storage.getDirectory();
      const scanDirectory = async (directory) => {
        for await (const [name, handle] of directory.entries()) {
          check(name);
          if (handle.kind === 'directory') await scanDirectory(handle);
          else checkBytes(await (await handle.getFile()).arrayBuffer());
        }
      };
      await scanDirectory(root);
    } catch (_) { failures += 1; }
    return { matched, failures };
  }, needles);
}

function callPgRecoveryProbe(payload, failureMessage) {
  const script = [
    'import json,sys,urllib.request',
    'data=json.load(sys.stdin)',
    'request=urllib.request.Request(data["url"],data=json.dumps(data["payload"]).encode(),headers={"content-type":"application/json","x-probe-token":data["token"]},method="POST")',
    'with urllib.request.urlopen(request,timeout=15) as response: print(response.read().decode())',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script], {
    input: JSON.stringify({ url: PG_RECOVERY_PROBE_URL, token: PG_RECOVERY_PROBE_TOKEN, payload }),
    encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) throw new Error(failureMessage);
  return result.stdout.trim().split('\n').at(-1);
}

function readAccountSnapshot() {
  if (PG_RECOVERY_MODE) {
    return JSON.parse(callPgRecoveryProbe(
      { action: 'snapshot', username },
      'isolated PostgreSQL account snapshot failed',
    ));
  }
  const script = [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1]); db.row_factory=sqlite3.Row',
    'user=db.execute("SELECT user_id FROM users WHERE username=?",(sys.argv[2],)).fetchone(); assert user is not None; uid=user[0]',
    'devices=[dict(x) for x in db.execute("SELECT device_id,status FROM devices WHERE user_id=? ORDER BY created_at",(uid,))]',
    'sessions=[dict(x) for x in db.execute("SELECT session_id,device_id,revoked_at FROM sessions WHERE user_id=? ORDER BY created_at",(uid,))]',
    'vaults=[dict(x) for x in db.execute("SELECT v.vault_id,v.active_epoch,v.membership_version,vm.role,vm.state AS member_state FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE vm.user_id=? AND vm.state=\'active\' AND v.state IN (\'active\',\'deleting\') ORDER BY v.created_at,v.vault_id",(uid,))]',
    'versions=[dict(x) for x in db.execute("SELECT vault_id,record_id,revision_id,digest,envelope,commit_seq FROM record_versions WHERE vault_id IN (SELECT vault_id FROM vault_members WHERE user_id=?) ORDER BY commit_seq",(uid,))]',
    'mfa=db.execute("SELECT enabled_at FROM auth_mfa WHERE user_id=? AND enabled_at IS NOT NULL",(uid,)).fetchone()',
    'codes=db.execute("SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=? AND consumed_at IS NULL",(uid,)).fetchone()[0]',
    'recovery=db.execute("SELECT recovery_generation FROM account_recovery WHERE user_id=?",(uid,)).fetchone()',
    'boxes=[dict(x) for x in db.execute("SELECT vault_id,key_epoch,envelope FROM account_recovery_key_envelopes WHERE user_id=?",(uid,))]',
    'keyboxes=[dict(x) for x in db.execute("SELECT vault_id,epoch,membership_version,recipient_device_id,envelope FROM vault_key_envelopes WHERE recipient_user_id=?",(uid,))]',
    'print(json.dumps({"user_id":uid,"devices":devices,"sessions":sessions,"vaults":vaults,"versions":versions,"mfa_enabled":mfa is not None,"mfa_recovery_codes":codes,"recovery_generation":recovery[0] if recovery else None,"recovery_boxes":boxes,"keyboxes":keyboxes}))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, username], { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error('isolated account snapshot failed');
  return JSON.parse(result.stdout.trim().split('\n').at(-1));
}

function readVaultMemberRoles(vaultId) {
  if (PG_RECOVERY_MODE) {
    return JSON.parse(callPgRecoveryProbe(
      { action: 'vault_roles', vault_id: vaultId },
      'isolated PostgreSQL Vault membership snapshot failed',
    ));
  }
  const script = [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1]); db.row_factory=sqlite3.Row',
    'rows=db.execute("SELECT role,state,COUNT(*) AS count FROM vault_members WHERE vault_id=? GROUP BY role,state ORDER BY role,state",(sys.argv[2],)).fetchall()',
    'print(json.dumps([dict(row) for row in rows]))',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath, vaultId], {
    encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) throw new Error('isolated Vault membership snapshot failed');
  return JSON.parse(result.stdout.trim().split('\n').at(-1));
}

async function issueDisposableAccountInvitation(invitedUsername, serverEnv, baseUrl) {
  if (PG_RECOVERY_MODE) {
    assertThat(typeof preRecoveryAccessToken === 'string',
      'PostgreSQL Recovery fixture needs the current administrator session');
    const response = await fetch(`${baseUrl}/api/v1/admin/account-invitations`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${preRecoveryAccessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ username: invitedUsername }),
    });
    const body = await response.json().catch(() => null);
    assertThat(response.status === 201 && typeof body?.invitation?.token === 'string',
      'PostgreSQL Recovery fixture account invitation was not issued by the administrator route');
    return body.invitation.token;
  }
  const result = spawnSync(SERVER_BINARY, [
    'create-account-invite', '--username', invitedUsername,
  ], {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'disposable Recovery collaborator invitation issuance failed');
  const token = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(typeof token === 'string',
    'disposable Recovery collaborator invitation was not returned');
  return token;
}

async function clearClipboard(target) {
  await target.evaluate(async () => {
    try { await navigator.clipboard.writeText(''); } catch (_) { /* Best-effort fixture cleanup. */ }
  });
}

async function pasteText(target, label, value) {
  const locator = await field(target, label);
  try {
    await target.evaluate(async (clipboardValue) =>
      navigator.clipboard.writeText(clipboardValue), value);
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await target.waitForTimeout(300);
    if (await locator.inputValue().catch(() => '') !== value) {
      await locator.fill(value);
    }
    await locator.press('Tab');
    await waitFor(() => locator.inputValue().then((current) => current === value)
      .catch(() => false), 5000);
  } catch (_) {
    throw new Error('large signed device card was not retained in the invite form');
  } finally {
    await clearClipboard(target);
  }
}

async function waitForSemanticText(target, text, timeoutMs = 20000) {
  await waitFor(() => target.evaluate((expected) => {
    if ((document.body.innerText || '').includes(expected)) return true;
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      ((element.innerText || '') + '\n' +
        (element.getAttribute('aria-label') || '')).includes(expected));
  }, text).catch(() => false), timeoutMs);
}

async function waitForOwnerSyncIdle(target, timeoutMs = 45000) {
  let stableSamples = 0;
  await waitFor(async () => {
    const signals = await target.locator('flt-semantics').evaluateAll((elements) =>
      elements.filter((element) => element.getAttribute('role') === 'button')
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 &&
            getComputedStyle(element).visibility !== 'hidden';
        })
        .map((element) => [element.innerText, element.textContent,
          element.getAttribute('aria-label'), element.getAttribute('aria-valuetext'),
          element.getAttribute('title')]
          .filter((value) => typeof value === 'string')
          .join(' '))
        .filter((value) => /\b(?:Idle|Syncing|Pending)\b|pending\s+\d+/i.test(value)));
    const status = signals.find((value) => /\bIdle\b/.test(value));
    const pendingCount = status?.match(/pending\s+(\d+)/i)?.[1];
    const conflicts = status?.match(/conflicts\s+(\d+)/i)?.[1];
    // Flutter Web exposes the top-bar status label to accessibility, while its
    // tooltip counts may not be in the semantic tree until hovered. "Idle" is
    // emitted only when the controller has no pending outbox items.
    const idleAndDrained = status && (!pendingCount || pendingCount === '0') &&
      (!conflicts || conflicts === '0');
    stableSamples = idleAndDrained ? stableSamples + 1 : 0;
    return stableSamples >= 8;
  }, timeoutMs);
}

async function selectVaultByName(target, targetName) {
  const selector = target.getByRole('button', { name: /^Choose vault(?:\s|$)/ });
  const current = await selector.first().innerText().catch(() => '');
  if (current.includes(targetName)) return;
  await selector.first().waitFor({ state: 'visible', timeout: 15000 });
  await selector.first().click();
  const deadline = Date.now() + 10000;
  let targetItem;
  while (Date.now() < deadline) {
    const items = await target.evaluate((name) =>
      [...document.querySelectorAll('flt-semantics[role="menuitem"]')]
        .map((node) => {
          const rect = node.getBoundingClientRect();
          const text = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`;
          return text.includes(name) && rect.width > 0 && rect.height > 0
            ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
            : null;
        }).filter(Boolean), targetName).catch(() => []);
    if (items.length === 1) {
      targetItem = items[0];
      break;
    }
    await target.waitForTimeout(100);
  }
  assertThat(targetItem, 'Vault switcher did not show the expected recovery fixture Vault');
  await target.mouse.click(targetItem.x + targetItem.width / 2,
    targetItem.y + targetItem.height / 2);
  await waitFor(async () => (await selector.first().innerText().catch(() => ''))
    .includes(targetName), 10000);
}

async function createSharedRecoveryFixture({ baseUrl, serverEnv, currentHostName, currentHostAddress }) {
  setStage('create a second encrypted Vault for shared Recovery coverage');
  sharedVaultName = `Recovery shared ${crypto.randomUUID().slice(0, 8)}`;
  await click(page, 'Settings');
  await waitForSemanticText(page, 'Vaults', 15000);
  await click(page, 'Create another Vault');
  await page.getByText('Create Vault', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
  await fill(page, 'Vault name', sharedVaultName);
  await click(page, 'Create encrypted Vault');
  await click(page, 'Hosts');
  await page.getByRole('button', { name: new RegExp(`^Choose vault.*${sharedVaultName}`) })
    .waitFor({ state: 'visible', timeout: 15000 });

  const historicalHostName = `Recovery historical ${crypto.randomUUID().slice(0, 8)}`;
  const historicalHostAddress = `recovery-old-${crypto.randomUUID().slice(0, 8)}.example.invalid`;
  let historicalRecordId;
  let historicalRevisionId;
  setStage('create a shared-Vault Host under its original key epoch');
  await click(page, 'Add host');
  await page.getByText('Add a host', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
  await fill(page, 'Display name', historicalHostName);
  await fill(page, 'Hostname or IP', historicalHostAddress);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'recovery-historical-user');
  await click(page, 'Save encrypted host');
  await page.getByRole('group', { name: `Host: ${historicalHostName};`, exact: false })
    .waitFor({ state: 'visible', timeout: 45000 });
  await waitFor(() => readAccountSnapshot().versions.length === 2, 30000);
  const historicalSnapshot = readAccountSnapshot();
  const historicalRows = historicalSnapshot.versions.filter((version) =>
    !beforeMfaVaultIds.has(version.vault_id));
  assertThat(historicalRows.length === 1,
    'shared Vault did not retain exactly one historical Host revision before rotation');
  historicalRecordId = historicalRows[0].record_id;
  historicalRevisionId = historicalRows[0].revision_id;
  const historicalVault = historicalSnapshot.vaults.find((vault) =>
    vault.vault_id === historicalRows[0].vault_id);
  let historicalHeader;
  try { historicalHeader = JSON.parse(historicalRows[0].envelope)?.header; } catch (_) { historicalHeader = null; }
  const historicalMembershipVersion = Number(historicalHeader?.membership_version);
  assertThat(Number(historicalHeader?.key_epoch) === 1 && historicalVault &&
    Number.isSafeInteger(historicalMembershipVersion) &&
    historicalMembershipVersion <= Number(historicalVault.membership_version),
  'historical Host revision was not bound to the original shared Vault epoch and membership');

  sharedUsername = `recovery-collaborator-${crypto.randomUUID().slice(0, 8)}@example.test`;
  sharedPassword = `Collaborator-${crypto.randomBytes(24).toString('base64url')}`;
  accountInviteToken = await issueDisposableAccountInvitation(sharedUsername, serverEnv, baseUrl);
  extraSecrets.push(sharedPassword, sharedUsername);
  inviteTokenNeedles.push(accountInviteToken);
  memberContext = await browser.newContext({
    locale: 'en-US',
    viewport: { width: 1440, height: 1000 },
    permissions: ['clipboard-read', 'clipboard-write'],
  });
  memberPage = await memberContext.newPage();
  setStage('register an invited collaborator for the shared Vault');
  await activate(memberPage, baseUrl, { captureSession: false });
  await field(memberPage, 'Email or username');
  await click(memberPage, 'Have an instance invitation? Create account');
  await field(memberPage, 'Email on the invitation');
  await fill(memberPage, 'Email on the invitation', sharedUsername);
  await fill(memberPage, 'Master password · 12+ characters', sharedPassword);
  await fill(memberPage, 'Confirm master password', sharedPassword);
  await fill(memberPage, 'Instance invitation token', accountInviteToken);
  accountInviteToken = undefined;
  await fill(memberPage, 'Device name', 'Recovery collaborator browser');
  await fill(memberPage, 'First Vault', 'Recovery collaborator personal');
  await click(memberPage, 'Create invited account');
  await waitFor(() => memberPage.getByRole('button', { name: 'Hosts', exact: true }).isVisible(), 45000);

  setStage('create a signed collaborator share request');
  await click(memberPage, 'Settings');
  await click(memberPage, 'Copy signed share request');
  await click(memberPage, 'Copy');
  shareRequestCard = await memberPage.evaluate(async () => navigator.clipboard.readText());
  let parsedCard;
  try { parsedCard = JSON.parse(shareRequestCard); } catch (_) { parsedCard = null; }
  assertThat(parsedCard?.format === 'atermius-vault-share-request-v1' &&
    typeof parsedCard?.account_id === 'string' && typeof parsedCard?.device?.device_id === 'string',
  'collaborator did not produce a signed device share request');
  await clearClipboard(memberPage);

  setStage('invite collaborator into the second Vault');
  await click(page, 'Settings');
  await click(page, 'Invite member');
  await pasteText(page, 'Public Device Card JSON', shareRequestCard);
  await click(page, 'Verify and review');
  await page.getByText('Confirm target:', { exact: false }).waitFor({ state: 'visible', timeout: 15000 });
  await click(page, 'Sign and create invitation');
  await click(page, 'Copy token');
  vaultInviteToken = await page.evaluate(async () => navigator.clipboard.readText());
  assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInviteToken),
    'shared Vault invitation token was not copied by the owner');
  inviteTokenNeedles.push(vaultInviteToken);
  await clearClipboard(page);

  setStage('activate collaborator membership and read the shared historical Host');
  await click(memberPage, 'Settings');
  await click(memberPage, 'Accept invitation');
  await fill(memberPage, 'Invitation token', vaultInviteToken);
  await click(memberPage, 'Accept and unlock Vault');
  await click(memberPage, 'Hosts');
  await memberPage.getByRole('group', { name: `Host: ${historicalHostName};`, exact: false })
    .waitFor({ state: 'visible', timeout: 45000 });
  const collaboratorHistoricalCard = memberPage.getByRole('group', {
    name: `Host: ${historicalHostName};`, exact: false,
  });
  assertThat((await collaboratorHistoricalCard.getAttribute('aria-label'))
      ?.includes(`@${historicalHostAddress}:22`) === true,
    'accepted collaborator could not decrypt the pre-share Host');

  const ownerBeforeRotation = readAccountSnapshot();
  const sharedVault = ownerBeforeRotation.vaults.find((vault) =>
    !beforeMfaVaultIds.has(vault.vault_id));
  assertThat(ownerBeforeRotation.vaults.length === 2 && sharedVault &&
    Number(sharedVault.active_epoch) === 1 && Number.isSafeInteger(Number(sharedVault.membership_version)),
  'shared Vault was not active at its original key epoch before membership rotation');
  const oldSharedMembershipVersion = Number(sharedVault.membership_version);

  setStage('rotate the shared Vault key while retaining both active members');
  const memberRolesBeforeRotation = readVaultMemberRoles(sharedVault.vault_id);
  assertThat(JSON.stringify(memberRolesBeforeRotation) === JSON.stringify([
    { role: 'editor', state: 'active', count: 1 },
    { role: 'owner', state: 'active', count: 1 },
  ]), 'shared Vault invitation did not leave one active Owner and one active Editor before rotation');
  setStage('open shared Vault member management');
  await click(page, 'Settings');
  setStage('wait for idle owner sync before role rotation');
  await waitForOwnerSyncIdle(page);
  await click(page, 'Manage Vault members');
  setStage('open Viewer role confirmation');
  await click(page, 'Make viewer');
  await page.getByText('Rotate key and change role?', { exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  setStage('submit signed Viewer role rotation');
  const rotationEventStart = events.length;
  await click(page, 'Change to viewer');
  const rotationEvent = await waitForEvent((event) =>
    events.indexOf(event) >= rotationEventStart &&
    event.route === 'vaults/:id/keys/rotate' && event.method === 'POST', 20000);
  const rotationEvents = events.slice(rotationEventStart).filter((event) =>
    event.route === 'vaults/:id/keys/rotate' && event.method === 'POST');
  assertThat(rotationEvents.length === 1 && rotationEvent.status === 200 &&
    rotationEvent.vaultId === sharedVault.vault_id &&
    rotationEvent.ownerUserId === readAccountSnapshot().user_id &&
    rotationEvent.activeKeyEpoch === 2 &&
    rotationEvent.membershipVersion === oldSharedMembershipVersion + 1 &&
    rotationEvent.vaultStatus === 'active',
  'signed Viewer role rotation did not return the expected active key epoch and membership version');
  setStage('wait for shared Vault key epoch rotation');
  await waitFor(() => {
    const after = readAccountSnapshot();
    const changed = after.vaults.find((vault) => vault.vault_id === sharedVault.vault_id);
    return changed && Number(changed.active_epoch) === 2 &&
      Number(changed.membership_version) === oldSharedMembershipVersion + 1;
  }, 30000);
  const rotatedOwnerSnapshot = readAccountSnapshot();
  const historicalAfterRotation = rotatedOwnerSnapshot.versions.find((version) =>
    version.record_id === historicalRecordId && version.revision_id === historicalRevisionId);
  let historicalRotatedHeader;
  try { historicalRotatedHeader = JSON.parse(historicalAfterRotation?.envelope)?.header; } catch (_) { historicalRotatedHeader = null; }
  assertThat(historicalAfterRotation && Number(historicalRotatedHeader?.key_epoch) === 1 &&
    Number(historicalRotatedHeader?.membership_version) === historicalMembershipVersion,
  'shared Vault rotation rewrote or rebound the historical Host revision');
  const memberRolesAfterRotation = readVaultMemberRoles(sharedVault.vault_id);
  assertThat(JSON.stringify(memberRolesAfterRotation) === JSON.stringify([
    { role: 'owner', state: 'active', count: 1 },
    { role: 'viewer', state: 'active', count: 1 },
  ]), 'shared Vault role rotation did not retain exactly one active Owner and one active Viewer');
  setStage('close member dialog after shared Vault key rotation');
  await click(page, 'Close');
  setStage('return to Hosts after shared Vault key rotation');
  await click(page, 'Hosts');
  await page.getByRole('group', { name: `Host: ${historicalHostName};`, exact: false })
    .waitFor({ state: 'visible', timeout: 30000 });

  setStage('create a current-epoch Host after shared Vault key rotation');
  await click(page, 'Add host');
  await page.getByText('Add a host', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
  await fill(page, 'Display name', currentHostName);
  await fill(page, 'Hostname or IP', currentHostAddress);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', 'recovery-current-user');
  await click(page, 'Save encrypted host');
  await page.getByRole('group', { name: `Host: ${currentHostName};`, exact: false })
    .waitFor({ state: 'visible', timeout: 45000 });
  await waitFor(() => readAccountSnapshot().versions.length === 3, 30000);
  const memberCurrentHostCard = memberPage.getByRole('group', {
    name: `Host: ${currentHostName};`, exact: false,
  });
  await memberCurrentHostCard.waitFor({ state: 'visible', timeout: 45000 });
  assertThat((await memberCurrentHostCard.getAttribute('aria-label'))
      ?.includes(`@${currentHostAddress}:22`) === true,
    'retained Viewer could not decrypt the shared Vault Host after key rotation');
  const fixture = readAccountSnapshot();
  const personal = fixture.vaults.find((vault) => beforeMfaVaultIds.has(vault.vault_id));
  const finalShared = fixture.vaults.find((vault) => vault.vault_id === sharedVault.vault_id);
  assertThat(personal && Number(personal.active_epoch) === 1 &&
    finalShared && Number(finalShared.active_epoch) === 2 &&
    Number(finalShared.membership_version) === oldSharedMembershipVersion + 1,
  'personal/shared Vault epoch fixture did not reach its expected two-Vault state');
  const expectedContexts = [
    {
      vault_id: personal.vault_id,
      key_epoch: Number(personal.active_epoch),
      membership_version: Number(personal.membership_version),
    },
    {
      vault_id: finalShared.vault_id,
      key_epoch: 1,
      // The encrypted Host keeps its creation-time header version; the
      // recovered keybox is authorized by the signed manifest version where
      // this user became an active recipient of the historical epoch.
      membership_version: oldSharedMembershipVersion,
    },
    {
      vault_id: finalShared.vault_id,
      key_epoch: Number(finalShared.active_epoch),
      membership_version: Number(finalShared.membership_version),
    },
  ];
  const recordEpochs = fixture.versions.map((version) => {
    let envelope;
    try { envelope = JSON.parse(version.envelope); } catch (_) { envelope = null; }
    return {
      vault_id: version.vault_id,
      key_epoch: Number(envelope?.header?.key_epoch),
      membership_version: Number(envelope?.header?.membership_version),
    };
  });
  const historicalVersion = fixture.versions.find((version) =>
    version.record_id === historicalRecordId && version.revision_id === historicalRevisionId);
  const historicalFixtureHeader = historicalVersion
    ? (() => { try { return JSON.parse(historicalVersion.envelope)?.header; } catch (_) { return null; } })()
    : null;
  const currentSharedVersions = fixture.versions.filter((version) =>
    version.vault_id === finalShared.vault_id && version.record_id !== historicalRecordId);
  const currentSharedHeader = currentSharedVersions.length === 1
    ? (() => { try { return JSON.parse(currentSharedVersions[0].envelope)?.header; } catch (_) { return null; } })()
    : null;
  assertThat(recordEpochs.some((item) => item.vault_id === personal.vault_id && item.key_epoch === 1) &&
    historicalVersion?.vault_id === finalShared.vault_id &&
    Number(historicalFixtureHeader?.key_epoch) === 1 &&
    Number(historicalFixtureHeader?.membership_version) === historicalMembershipVersion &&
    currentSharedVersions.length === 1 && Number(currentSharedHeader?.key_epoch) === 2 &&
    Number(currentSharedHeader?.membership_version) === Number(finalShared.membership_version),
  'recovery fixture Host revisions are not bound to personal, historical shared, and current shared key epochs');
  const memberDialog = await page.locator('body').innerText().catch(() => '');
  assertThat(!memberDialog.includes(sharedPassword),
    'collaborator password unexpectedly appeared in the owner UI');
  return {
    personalVaultId: personal.vault_id,
    sharedVaultId: finalShared.vault_id,
    sharedVaultName,
    historicalHostName,
    historicalHostAddress,
    historicalMembershipVersion,
    currentHostName,
    currentHostAddress,
    expectedContexts,
  };
}

function clearDisposableAuthRateLimits() {
  if (PG_RECOVERY_MODE) {
    callPgRecoveryProbe(
      { action: 'clear_rate_limits' },
      'isolated PostgreSQL auth rate-limit fixture reset failed',
    );
    return;
  }
  const script = [
    'import sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1])',
    'db.execute("DELETE FROM auth_rate_limits WHERE endpoint IN (?,?,?)",("prelogin","login","mfa_login"))',
    'db.commit()',
  ].join('\n');
  const result = spawnSync('python3', ['-c', script, databasePath], {
    encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated MFA rate-limit fixture reset failed');
  }
}

async function rememberPgSecrets(secrets) {
  if (!PG_RECOVERY_MODE) return false;
  const response = await fetch(PG_RECOVERY_PROBE_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-probe-token': PG_RECOVERY_PROBE_TOKEN },
    body: JSON.stringify({ action: 'remember_and_scan', username, secrets }),
    signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new Error('Recovery privacy probe failed');
  return (await response.json()).matched === true;
}

async function assertOldSessionRevokedOnBothNodes(token) {
  if (!PG_RECOVERY_MODE) return [];
  assertThat(typeof token === 'string' && token.length >= 40, 'original session token was not observed in memory');
  const statuses = await Promise.all([PG_RECOVERY_NODE_A_URL, PG_RECOVERY_NODE_B_URL].map(async (origin) => {
    const response = await fetch(`${origin}/api/v1/me`, {
      headers: { authorization: `Bearer ${token}`, origin: PG_RECOVERY_BASE_URL },
      signal: AbortSignal.timeout(5000),
    });
    return response.status;
  }));
  assertThat(statuses.every((status) => status === 401), 'Recovery did not reject the lost session on both PG nodes');
  return statuses;
}

function scanServerFiles(root, needles) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const file = path.join(root, entry.name);
    if (entry.isDirectory()) { if (scanServerFiles(file, needles)) return true; }
    else if (entry.isFile()) {
      const bytes = fs.readFileSync(file);
      if (needles.some((needle) => needle.length >= 16 && bytes.includes(needle))) return true;
      const text = bytes.toString('utf8');
      if (needles.some((needle) => needle.length >= 16 && text.includes(needle.toString('base64url')))) return true;
    }
  }
  return false;
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'current Flutter Web bundle is incomplete');
  }
  setStage(PG_RECOVERY_MODE ? 'external PostgreSQL servers' : 'isolated server build');
  if (!PG_RECOVERY_MODE) buildServer();

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-mfa-recovery-'));
  fs.chmodSync(tempRoot, 0o700);
  let keyMode = null;
  let baseUrl;
  let env;
  if (PG_RECOVERY_MODE) {
    assertThat(PG_RECOVERY_NODE_A_URL && PG_RECOVERY_NODE_B_URL && PG_RECOVERY_PROBE_URL
      && PG_RECOVERY_PROBE_TOKEN && PG_RECOVERY_USERNAME && PG_RECOVERY_BOOTSTRAP_TOKEN,
    'PG Recovery browser fixture inputs are incomplete');
    baseUrl = PG_RECOVERY_BASE_URL;
    username = PG_RECOVERY_USERNAME;
    bootstrapToken = PG_RECOVERY_BOOTSTRAP_TOKEN;
    proxyServer = makePgRecoveryProxy(baseUrl);
    await new Promise((resolve, reject) => {
      proxyServer.once('error', reject);
      proxyServer.listen(Number(new URL(baseUrl).port), '127.0.0.1', resolve);
    });
  } else {
    dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    databasePath = path.join(dataDir, 'atermius.db');
    mfaKeyFile = path.join(tempRoot, 'mfa-seed.key');
    const mfaKey = crypto.randomBytes(32);
    fs.writeFileSync(mfaKeyFile, mfaKey, { flag: 'wx', mode: 0o600 });
    mfaKey.fill(0);
    fs.chmodSync(mfaKeyFile, 0o600);
    keyMode = fs.statSync(mfaKeyFile).mode & 0o777;
    assertThat(keyMode === 0o600, 'MFA encryption key file was not owner-only');
    const logPath = path.join(tempRoot, 'server.log');
    serverLogFd = fs.openSync(logPath, 'w', 0o600);
    const port = await unusedPort();
    baseUrl = `http://127.0.0.1:${port}`;
    env = { ...process.env, ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir, ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT, ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_MFA_ENCRYPTION_KEY_FILE: mfaKeyFile,
      ATERMIUS_REGISTRATION_OPEN: 'false', ATERMIUS_RELAY_ENABLED: 'false', RUST_LOG: 'off' };
  }
  username = username || `mfa-${crypto.randomUUID().slice(0, 8)}@example.test`;
  password = `Initial-${crypto.randomBytes(24).toString('base64url')}`;
  replacementPassword = `Recovered-${crypto.randomBytes(24).toString('base64url')}`;
  const hostName = `MFA recovery host ${crypto.randomUUID().slice(0, 8)}`;
  const hostAddress = `mfa-${crypto.randomUUID().slice(0, 8)}.example.invalid`;
  let recoveryFixture = null;
  let originalProfilePersistence = { failures: 0, matched: false };
  let memberProfilePersistence = { failures: 0, matched: false };
  let hostPlaintextNeedles = [];
  let preRecoveryPrivacyNeedles = [];
  let expectedRecoveryContexts = [];
  let expectedContextCount = 1;

  try {
    if (!PG_RECOVERY_MODE) {
      setStage('isolated server startup');
      serverProcess = spawn(SERVER_BINARY, ['serve'], { cwd: ROOT, env, detached: true,
        stdio: ['ignore', serverLogFd, serverLogFd] });
      await waitForServer(baseUrl);
      setStage('isolated instance bootstrap');
      bootstrapToken = run(SERVER_BINARY, ['bootstrap'], { env, timeout: 30000 }).trim().split(/\s+/).at(-1);
    }
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40, 'bootstrap token unavailable');

    const launch = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launch.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launch);
    context = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    page = await context.newPage();
    setStage('current Web bundle and owner registration');
    await activate(page, baseUrl);
    await field(page, 'Owner email');
    await fill(page, 'Owner email', username);
    await fill(page, 'Master password · 12+ characters', password);
    await fill(page, 'Confirm master password', password);
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    await fill(page, 'Device name', 'Disposable original device');
    await fill(page, 'First Vault', 'MFA full recovery');
    const registrationIndex = events.length;
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    const registration = await waitForEvent((event) => event.route === 'auth/register'
      && event.method === 'POST' && events.indexOf(event) >= registrationIndex);
    assertThat(registration.status === 200 && !registration.hasBearer, 'owner registration failed');
    await button(page, 'Add host');

    setStage('create a synthetic encrypted Host');
    await click(page, 'Add host');
    await page.getByText('Add a host', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
    await fill(page, 'Display name', hostName);
    await fill(page, 'Hostname or IP', hostAddress);
    await fill(page, 'Port', '22');
    await fill(page, 'SSH username', 'recovery-personal-user');
    await click(page, 'Save encrypted host');
    await page.getByRole('group', { name: `Host: ${hostName};`, exact: false })
      .waitFor({ state: 'visible', timeout: 45000 });
    setStage('wait for encrypted Host sync commit');
    await waitFor(() => readAccountSnapshot().versions.length === 1, 30000);
    const beforeMfa = readAccountSnapshot();
    if (Array.isArray(beforeMfa.vaults)) {
      beforeMfaVaultIds = new Set(beforeMfa.vaults.map((vault) => vault.vault_id));
    }
    assertThat(beforeMfa.versions.length === 1 && !beforeMfa.mfa_enabled,
      'synthetic account did not start with one opaque Host revision and MFA disabled');

    setStage('enroll TOTP and display the one-time recovery codes');
    const enrollmentStep = await enrollMfa(page, baseUrl, password);
    const setupSnapshot = readAccountSnapshot();
    assertThat(setupSnapshot.mfa_enabled && setupSnapshot.mfa_recovery_codes === 10,
      'TOTP setup did not persist one encrypted factor and ten recovery-code hashes');
    const mfaCodesFromFirstSet = [...mfaRecoveryCodes];
    const setupPersistence = await inspectBrowserPersistence(page, [mfaSeedText, mfaUri, ...mfaCodesFromFirstSet]);
    assertThat(setupPersistence.failures === 0 && !setupPersistence.matched,
      'MFA enrollment material appeared in persistent browser storage');
    const persistedMfaLeak = scanServerFiles(tempRoot, [Buffer.from(mfaSeedText), Buffer.from(mfaUri),
      ...mfaCodesFromFirstSet.map((code) => Buffer.from(code))]);
    assertThat(!persistedMfaLeak, 'plaintext MFA material appeared in server files');

    setStage('rotate MFA recovery codes and invalidate the previous one-time set');
    await click(page, 'Rotate recovery codes');
    await fill(page, 'Current master password', password);
    const rotationProof = await freshTotp(mfaSeedText, enrollmentStep);
    await fill(page, 'Authenticator code', rotationProof.code);
    const rotateStart = events.length;
    await click(page, 'Rotate codes');
    const rotatedEvent = await waitForEvent((event) => event.route === 'auth/mfa/recovery-codes'
      && event.method === 'POST' && events.indexOf(event) >= rotateStart);
    assertThat(rotatedEvent.status === 200,
      'MFA recovery-code rotation did not succeed');
    await readMfaCodes(page);
    const mfaCodesFromRotatedSet = [...mfaRecoveryCodes];
    const recoveryCodeForLogin = mfaCodesFromRotatedSet[0];
    await confirmMfaCodes(page);
    const rotatedSnapshot = readAccountSnapshot();
    assertThat(rotatedSnapshot.mfa_enabled && rotatedSnapshot.mfa_recovery_codes === 10,
      'recovery-code rotation did not replace the complete one-time code set');
    const rotationPersistence = await inspectBrowserPersistence(page, mfaMaterialNeedles);
    assertThat(rotationPersistence.failures === 0 && !rotationPersistence.matched,
      'rotated MFA material appeared in persistent browser storage');
    const rotationFileLeak = scanServerFiles(tempRoot, mfaMaterialNeedles.map((secret) => Buffer.from(secret)));
    assertThat(!rotationFileLeak, 'plaintext MFA material appeared in server files after rotation');

    setStage('reject password-only login until a TOTP proof succeeds');
    await lockWorkspace(page);
    let challenge = await beginMfaLogin(page, password);
    assertThat(!events.slice(challenge.start).some((event) => event.hasBearer),
      'a bearer request occurred before the second factor was submitted');
    let proof = await freshTotp(mfaSeedText, rotationProof.step);
    await submitMfa(page, 'totp', proof.code, 200);
    let usedTotp = proof;

    setStage('reject replayed TOTP, then accept one recovery code');
    await lockWorkspace(page);
    challenge = await beginMfaLogin(page, password);
    await submitMfa(page, 'totp', usedTotp.code, 401);
    const replacedCode = await submitMfa(page, 'recovery_code', mfaCodesFromFirstSet[0], 401);
    report('mfa_pre_rotation_recovery_code_status', replacedCode.status);
    await submitMfa(page, 'recovery_code', recoveryCodeForLogin, 200);
    let afterCodeLogin = readAccountSnapshot();
    assertThat(afterCodeLogin.mfa_recovery_codes === 9, 'successful recovery-code login did not consume exactly one code');

    setStage('reject recovery-code replay and enforce the challenge attempt limit');
    await lockWorkspace(page);
    // Earlier successful and replay flows share this disposable account/IP.
    // Reset only auth buckets so this scenario reaches the separate five-factor
    // challenge cap; the Python acceptance checks limiter behavior.
    clearDisposableAuthRateLimits();
    challenge = await beginMfaLogin(page, password);
    await submitMfa(page, 'recovery_code', recoveryCodeForLogin, 401);
    const bogus = totpAtStep(mfaSeedText, currentTotpStep() + 4);
    for (let attempt = 1; attempt <= 6; attempt += 1) {
      await submitMfa(page, 'totp', bogus, 401);
    }
    clearDisposableAuthRateLimits();
    await click(page, 'Cancel sign-in');
    await field(page, 'Email or username');
    await fill(page, 'Email or username', username);
    await fill(page, 'Master password', password);
    const limitedLoginStart = events.length;
    await click(page, 'Sign in and unlock');
    const limitedChallenge = await waitForEvent((event) => event.route === 'auth/login'
      && event.method === 'POST' && events.indexOf(event) >= limitedLoginStart);
    assertThat(limitedChallenge.status === 202 && limitedChallenge.mfaRequired,
      'a fresh challenge was not available after the exhausted challenge was closed');
    proof = await freshTotp(mfaSeedText, usedTotp.step);
    await fill(page, 'Authenticator code', proof.code);
    const recoveredLoginStart = events.length;
    await click(page, 'Verify and unlock');
    const recoveredLogin = await waitForEvent((event) => event.route === 'auth/login/mfa'
      && event.method === 'POST' && events.indexOf(event) >= recoveredLoginStart);
    assertThat(recoveredLogin.status === 200 && recoveredLogin.sessionIssued,
      'a fresh TOTP code did not complete a new MFA challenge');
    await button(page, 'Add host');
    usedTotp = proof;
    report('mfa_failed_attempts_before_challenge_rejection', 5);
    report('mfa_recovery_code_replay_status', 401);

    setStage('disable MFA with current password and an unused TOTP code');
    await click(page, 'Settings');
    await click(page, 'Disable MFA');
    await click(page, 'Continue');
    await fill(page, 'Current master password', password);
    const disableProof = await freshTotp(mfaSeedText, usedTotp.step);
    await fill(page, 'Authenticator code', disableProof.code);
    const disableStart = events.length;
    await click(page, 'Disable MFA');
    const disabledStatus = await waitForEvent((event) => event.route === 'auth/mfa/totp'
      && event.method === 'DELETE' && events.indexOf(event) >= disableStart);
    assertThat(disabledStatus.status === 200, 'MFA disable action failed');
    await page.getByRole('button', { name: 'Set up authenticator', exact: true })
      .waitFor({ state: 'visible', timeout: 15000 });
    assertThat(!readAccountSnapshot().mfa_enabled, 'MFA disable left the factor enabled');

    setStage('re-enable MFA before last-device Recovery');
    clearDisposableAuthRateLimits();
    const reenrollmentStep = await enrollMfa(page, baseUrl, password);
    const reenrolled = readAccountSnapshot();
    assertThat(reenrolled.mfa_enabled && reenrolled.mfa_recovery_codes === 10,
      'MFA re-enrollment did not issue a replacement recovery-code set');
    const reenrollmentPersistence = await inspectBrowserPersistence(page, mfaMaterialNeedles);
    assertThat(reenrollmentPersistence.failures === 0 && !reenrollmentPersistence.matched,
      're-enrolled MFA material appeared in persistent browser storage');
    const reenrollmentFileLeak = scanServerFiles(tempRoot,
      mfaMaterialNeedles.map((secret) => Buffer.from(secret)));
    assertThat(!reenrollmentFileLeak, 'plaintext re-enrolled MFA material appeared in server files');

    const currentHostName = `Recovery current ${crypto.randomUUID().slice(0, 8)}`;
    const currentHostAddress = `recovery-current-${crypto.randomUUID().slice(0, 8)}.example.invalid`;
    recoveryFixture = await createSharedRecoveryFixture({
      baseUrl,
      serverEnv: env,
      currentHostName,
      currentHostAddress,
    });
    expectedRecoveryContexts = recoveryFixture.expectedContexts;
    expectedContextCount = expectedRecoveryContexts.length;

    setStage('configure signed Account Recovery through Settings');
    clearDisposableAuthRateLimits();
    await click(page, 'Settings');
    await click(page, 'Set up recovery');
    await fill(page, 'Current master password', password);
    await click(page, 'Continue');
    await page.getByRole('checkbox', { name: /I stored this code securely/ }).waitFor({ state: 'visible', timeout: 15000 });
    const firstCode = await page.locator('flt-semantics').evaluateAll((elements) => {
      const pattern = /(?:^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{43})(?:$|[^A-Za-z0-9_-])/;
      for (const element of elements) {
        for (const value of [element.innerText, element.textContent, element.getAttribute('aria-label'), element.getAttribute('aria-valuetext')]) {
          if (typeof value !== 'string') continue;
          const match = value.replace(/[\u200B-\u200D\uFEFF]/g, '').match(pattern);
          if (match) return match[1];
        }
      }
      return '';
    });
    assertThat(/^[A-Za-z0-9_-]{43}$/.test(firstCode), 'Vault Recovery code was not available in its confirmation UI');
    vaultRecoveryCode = firstCode;
    vaultRecoveryNeedles.push(firstCode);
    const recoveryCheckbox = page.getByRole('checkbox', { name: /I stored this code securely/ });
    await recoveryCheckbox.click();
    await waitFor(async () => (await recoveryCheckbox.getAttribute('aria-checked')) === 'true', 5000);
    await click(page, 'Finish');
    const generationOne = readAccountSnapshot();
    assertThat(generationOne.recovery_generation === 1 &&
      generationOne.recovery_boxes.length === expectedContextCount,
    'signed Recovery setup did not create one keybox for each required Vault epoch');
    const setupBoxPairs = generationOne.recovery_boxes.map((box) =>
      `${box.vault_id}:${Number(box.key_epoch)}`).sort();
    const expectedBoxPairs = expectedRecoveryContexts.map((item) =>
      `${item.vault_id}:${item.key_epoch}`).sort();
    assertThat(JSON.stringify(setupBoxPairs) === JSON.stringify(expectedBoxPairs),
      'Recovery setup did not persist the exact personal/shared Vault epoch set');
    const recoverySetupPersistence = await inspectBrowserPersistence(page, [vaultRecoveryCode]);
    assertThat(recoverySetupPersistence.failures === 0 && !recoverySetupPersistence.matched,
      'the Vault Recovery code appeared in persistent browser storage after setup');

    hostPlaintextNeedles = [hostName, hostAddress, 'recovery-personal-user',
      ...(recoveryFixture ? [recoveryFixture.historicalHostName,
        recoveryFixture.historicalHostAddress, 'recovery-historical-user',
        recoveryFixture.currentHostName, recoveryFixture.currentHostAddress,
        'recovery-current-user'] : [])]
      .filter((value) => typeof value === 'string' && value.length >= 16);
    preRecoveryPrivacyNeedles = [...mfaMaterialNeedles, ...vaultRecoveryNeedles,
      ...inviteTokenNeedles, ...hostPlaintextNeedles, password, replacementPassword,
      sharedPassword, preRecoveryAccessToken]
      .filter((value) => typeof value === 'string' && value.length >= 16);
    originalProfilePersistence = await inspectBrowserPersistence(page, preRecoveryPrivacyNeedles);
    assertThat(originalProfilePersistence.failures === 0 && !originalProfilePersistence.matched,
      'plaintext password, Recovery/MFA material, invitation token, or Host field appeared in the original browser profile');
    if (memberPage) {
      memberProfilePersistence = await inspectBrowserPersistence(memberPage, preRecoveryPrivacyNeedles);
      assertThat(memberProfilePersistence.failures === 0 && !memberProfilePersistence.matched,
        'plaintext password, invitation token, or Host field appeared in the collaborator browser profile');
    }

    setStage('discard original browser profile with device and session still active');
    await context.close();
    context = undefined;
    const oldSessions = generationOne.sessions.filter((item) => item.revoked_at === null);
    assertThat(oldSessions.length === 1, 'expected one live session before device loss');
    // The isolated database snapshot below proves full Recovery revoked this
    // live session before any replacement-password login.
    report('live_session_count_before_recovery', oldSessions.length);
    secondContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    recoveryPage = await secondContext.newPage();
    await activate(recoveryPage, baseUrl);
    await field(recoveryPage, 'Email or username');
    setStage('complete signed full Account Recovery from a clean browser profile');
    setStage('open the recovery-code verification form on the replacement device');
    await click(recoveryPage, 'Recover account with recovery code');
    setStage('enter the account identity and Recovery code');
    await fill(recoveryPage, 'Account name', username);
    await fill(recoveryPage, 'Recovery code', vaultRecoveryCode);
    setStage('enter and confirm the replacement master password');
    await fill(recoveryPage, 'New master password · 12+ characters', replacementPassword);
    await fill(recoveryPage, 'Confirm new master password', replacementPassword);
    await fill(recoveryPage, 'New device name', 'Recovered last device');
    const recoverStart = events.length;
    setStage('inspect the signed Recovery key contexts');
    await click(recoveryPage, 'Verify recovery code');
    const challengeEvent = await waitForEvent((event) => event.route === 'auth/recovery/start' && events.indexOf(event) >= recoverStart);
    const inspectEvent = await waitForEvent((event) => event.route === 'auth/recovery/inspect' && events.indexOf(event) >= recoverStart);
    assertThat(challengeEvent.status === 200 && !challengeEvent.hasBearer && challengeEvent.challengePresent,
      'anonymous Recovery start failed');
    const inspectedContexts = (inspectEvent.requiredContextTuples || [])
      .map((item) => ({
        vault_id: item.vaultId,
        key_epoch: item.keyEpoch,
        membership_version: item.membershipVersion,
      }))
      .sort((left, right) => `${left.vault_id}:${left.key_epoch}`
        .localeCompare(`${right.vault_id}:${right.key_epoch}`));
    assertThat(inspectEvent.status === 200 && !inspectEvent.hasBearer
      && inspectEvent.requiredContexts === expectedContextCount
      && inspectEvent.presentContexts === expectedContextCount,
    'Recovery inspection did not return the complete required key context set');
    const expected = expectedRecoveryContexts.map((item) => ({ ...item }))
      .sort((left, right) => `${left.vault_id}:${left.key_epoch}`
        .localeCompare(`${right.vault_id}:${right.key_epoch}`));
    assertThat(JSON.stringify(inspectedContexts) === JSON.stringify(expected),
      `Recovery inspection changed a Vault/key context: expected ${JSON.stringify(expected)}, received ${JSON.stringify(inspectedContexts)}`);
    const commitCheckbox = recoveryPage.getByRole('checkbox', { name: /I stored this code securely/ });
    await commitCheckbox.waitFor({ state: 'visible', timeout: 15000 });
    await waitFor(async () => recoveryPage.locator('flt-semantics').evaluateAll((elements) => {
      const pattern = /(?:^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{43})(?:$|[^A-Za-z0-9_-])/;
      return elements.some((element) => [element.innerText, element.textContent,
        element.getAttribute('aria-label'), element.getAttribute('aria-valuetext')]
        .some((value) => typeof value === 'string'
          && pattern.test(value.replace(/[\u200B-\u200D\uFEFF]/g, ''))));
    }), 15000);
    const newRecoveryCode = await recoveryPage.locator('flt-semantics').evaluateAll((elements) => {
      for (const element of elements) {
        for (const value of [element.innerText, element.textContent, element.getAttribute('aria-label'), element.getAttribute('aria-valuetext')]) {
          if (typeof value !== 'string') continue;
          const match = value.replace(/[\u200B-\u200D\uFEFF]/g, '').match(/(?:^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{43})(?:$|[^A-Za-z0-9_-])/);
          if (match) return match[1];
        }
      }
      return '';
    });
    assertThat(/^[A-Za-z0-9_-]{43}$/.test(newRecoveryCode), 'rotated Recovery code was not displayed');
    vaultRecoveryNeedles.push(newRecoveryCode);
    await commitCheckbox.click();
    await waitFor(async () => (await commitCheckbox.getAttribute('aria-checked')) === 'true', 5000);
    const completeIndex = events.length;
    await click(recoveryPage, 'Commit recovery');
    const completion = await waitForEvent((event) => event.route === 'auth/recovery/complete'
      && events.indexOf(event) >= completeIndex);
    assertThat(completion.status === 200 && completion.recovered && completion.recoveredDevicePresent,
      'signed Account Recovery completion failed');
    const afterComplete = readAccountSnapshot();
    assertThat(!afterComplete.mfa_enabled && afterComplete.mfa_recovery_codes === 0,
      'successful signed Account Recovery did not clear MFA and its recovery codes');
    const completedPairs = afterComplete.recovery_boxes.map((box) =>
      `${box.vault_id}:${Number(box.key_epoch)}`).sort();
    const expectedPairs = expectedRecoveryContexts.map((item) =>
      `${item.vault_id}:${item.key_epoch}`).sort();
    const recoveredDeviceBoxes = afterComplete.keyboxes.filter((box) =>
      box.recipient_device_id === completion.recoveredDeviceId);
    const completedDeviceContexts = recoveredDeviceBoxes.map((box) => ({
      vault_id: box.vault_id,
      key_epoch: Number(box.epoch),
      membership_version: Number(box.membership_version),
    })).sort((left, right) => `${left.vault_id}:${left.key_epoch}`
      .localeCompare(`${right.vault_id}:${right.key_epoch}`));
    const expectedDeviceContexts = expectedRecoveryContexts.map((item) => ({ ...item }))
      .sort((left, right) => `${left.vault_id}:${left.key_epoch}`
        .localeCompare(`${right.vault_id}:${right.key_epoch}`));
    assertThat(JSON.stringify(completedPairs) === JSON.stringify(expectedPairs) &&
      JSON.stringify(completedDeviceContexts) === JSON.stringify(expectedDeviceContexts),
    'Recovery completion did not replace every exact signed context for the new device and generation');
    if (PG_RECOVERY_MODE) {
      const immediateChallenge = (afterComplete.recovery_challenges || []).filter((item) =>
        item.challenge_id_hash === challengeEvent.challengeIdHash
          && item.challenge_hash === challengeEvent.challengeHash);
      assertThat(immediateChallenge.length === 1 && immediateChallenge[0].recovery_generation === 1
        && immediateChallenge[0].consumed_at !== null,
      'PostgreSQL did not persist the consumed challenge as hashes at Recovery completion');
      report('pg_challenge_consumed_immediately', true);
    }
    assertThat(afterComplete.devices.filter((item) => item.status === 'active').length === 1
      && afterComplete.devices.filter((item) => item.status === 'revoked').length === 1,
    'full Recovery did not revoke the lost device and retain one replacement');
    assertThat(afterComplete.sessions.filter((item) => item.revoked_at === null).length === 0,
      'anonymous completion should not create a session before replacement-password login');
    const preRecoveryToken = preRecoveryAccessToken;
    preRecoveryAccessToken = undefined;
    const oldSessionStatuses = await assertOldSessionRevokedOnBothNodes(preRecoveryToken);

    setStage('replacement password signs in and opens preserved personal Vault data');
    await field(recoveryPage, 'Email or username');
    await signInNormally(recoveryPage, replacementPassword);
    await recoveryPage.getByRole('group', { name: `Host: ${hostName};`, exact: false })
      .waitFor({ state: 'visible', timeout: 45000 });
    const personalHostCard = recoveryPage.getByRole('group', {
      name: `Host: ${hostName};`, exact: false,
    });
    assertThat((await personalHostCard.getAttribute('aria-label'))
        ?.includes(`@${hostAddress}:22`) === true,
      'recovered Web device could not decrypt the personal Vault Host');
    await click(recoveryPage, 'Hosts');
    await selectVaultByName(recoveryPage, recoveryFixture.sharedVaultName);
    await click(recoveryPage, 'Hosts');
    const historicalHostCard = recoveryPage.getByRole('group', {
      name: `Host: ${recoveryFixture.historicalHostName};`, exact: false,
    });
    const currentHostCard = recoveryPage.getByRole('group', {
      name: `Host: ${recoveryFixture.currentHostName};`, exact: false,
    });
    await historicalHostCard.waitFor({ state: 'visible', timeout: 45000 });
    await currentHostCard.waitFor({ state: 'visible', timeout: 45000 });
    assertThat((await historicalHostCard.getAttribute('aria-label'))
        ?.includes(`@${recoveryFixture.historicalHostAddress}:22`) === true &&
      (await currentHostCard.getAttribute('aria-label'))
        ?.includes(`@${recoveryFixture.currentHostAddress}:22`) === true,
    'recovered Web device could not decrypt shared Vault data from historical and current key epochs');
    const finalSnapshot = readAccountSnapshot();
    assertThat(finalSnapshot.mfa_enabled === false && finalSnapshot.mfa_recovery_codes === 0,
      'MFA state reappeared after recovery password login');
    assertThat(finalSnapshot.versions.length === generationOne.versions.length
      && JSON.stringify(finalSnapshot.versions) === JSON.stringify(generationOne.versions),
    'Recovery changed or lost an opaque Host revision across the personal/shared Vaults');
    assertThat(finalSnapshot.recovery_generation === 2 &&
      finalSnapshot.recovery_boxes.length === expectedContextCount,
    'full Recovery did not rotate identity and recreate every required keybox');
    if (PG_RECOVERY_MODE) {
      const recoveryRoute = proxyRoutes.find((route) => route.method === 'POST'
        && route.path === '/api/v1/auth/recovery/complete' && route.status === 200);
      const loginRoute = [...proxyRoutes].reverse().find((route) => route.method === 'POST'
        && route.path === '/api/v1/auth/login' && route.status === 200);
      const hostRead = proxyRoutes.some((route) => route.method === 'GET' && route.node === 'A'
        && route.status === 200 && /\/api\/v1\/vaults\/[^/]+\/(?:changes|records)/.test(route.path));
      assertThat(recoveryRoute?.node === 'B', 'full Recovery completion did not run on PostgreSQL node B');
      assertThat(loginRoute?.node === 'A', 'replacement-password login did not read recovered credentials on node A');
      assertThat(hostRead, 'node A did not serve a successful Host sync read after Recovery');
      report('pg_recovery_complete_node', recoveryRoute.node);
      report('pg_replacement_login_node', loginRoute.node);
      report('pg_preserved_host_read_on_node_a', hostRead);
    }

    setStage('scan MFA secrets from persistent browser/server storage and logs');
    const recoveredSessionToken = preRecoveryAccessToken;
    const recoveryStartEvent = events.find((event) => event.route === 'auth/recovery/start'
      && event.challengeIdHash && event.challengeHash);
    assertThat(Boolean(recoveryStartEvent), 'Recovery challenge hashes were not captured for PG assertions');
    const allRecoverySecrets = [...preRecoveryPrivacyNeedles,
      ...recoveryChallengeSecrets, preRecoveryToken, recoveredSessionToken]
      .filter((value) => typeof value === 'string' && value.length > 0);
    const browserScan = await inspectBrowserPersistence(recoveryPage,
      allRecoverySecrets);
    assertThat(browserScan.failures === 0 && !browserScan.matched,
      'TOTP seed, provisioning URI, or recovery code appeared in persistent browser storage');
    const serverLeak = scanServerFiles(tempRoot, allRecoverySecrets.map((secret) => Buffer.from(secret)));
    const pgLeak = await rememberPgSecrets(allRecoverySecrets);
    assertThat(!serverLeak, 'plaintext MFA or Vault Recovery material appeared in server files');
    assertThat(!pgLeak, 'plaintext Recovery/MFA/session material appeared in PostgreSQL rows');
    assertThat(!consoleMessages.some((message) => allRecoverySecrets.some((secret) => secret && message.includes(secret))),
      'secret material appeared in Web console output');
    assertThat(!hostPlaintextNeedles.some((marker) => wireBodies.some((body) => body.includes(marker))),
      'synthetic personal/shared Host field appeared in API traffic');
    assertThat(!wireBodies.some((body) => body.includes(sharedPassword)),
      'collaborator master password appeared in API traffic');
    assertThat(!wireBodies.some((body) => body.includes(password) || body.includes(replacementPassword)),
      'owner master password appeared in API traffic');
    assertThat(pageErrors === 0, 'Flutter Web raised a page error');
    if (keyMode !== null) report('mfa_key_file_mode_0600', keyMode === 0o600);
    report('mfa_recovery_code_count_shown_once', mfaCodesFromFirstSet.length);
    report('mfa_login_challenge_status', 202);
    report('mfa_replayed_totp_status', 401);
    report('mfa_recovery_code_login_status', 200);
    report('mfa_recovery_code_replay_status', 401);
    report('mfa_attempt_limit_reached', true);
    report('mfa_disable_status', disabledStatus.status);
    report('signed_full_recovery_mfa_cleared', !finalSnapshot.mfa_enabled && finalSnapshot.mfa_recovery_codes === 0);
    report('replacement_login_mfa_required', false);
    report('preserved_opaque_host_revision_count', finalSnapshot.versions.length);
    report('recovered_required_vault_epoch_contexts', expectedContextCount);
    report('recovery_context_tuples', expectedRecoveryContexts.map((item) => ({
      vault_id: item.vault_id,
      key_epoch: item.key_epoch,
      membership_version: item.membership_version,
    })).sort((left, right) => `${left.vault_id}:${left.key_epoch}`
      .localeCompare(`${right.vault_id}:${right.key_epoch}`)));
    if (recoveryFixture) {
      report('recovered_distinct_vault_count', new Set(expectedRecoveryContexts.map((item) => item.vault_id)).size);
      report('recovered_shared_historical_and_current_epochs', true);
    }
    report('browser_persistence_scan_failures', browserScan.failures);
    report('browser_persistence_secret_match', browserScan.matched);
    report('original_profile_persistence_scan_failures', originalProfilePersistence.failures);
    report('original_profile_persistence_secret_match', originalProfilePersistence.matched);
    report('collaborator_profile_persistence_scan_failures', memberProfilePersistence.failures);
    report('collaborator_profile_persistence_secret_match', memberProfilePersistence.matched);
    report('reenrollment_browser_persistence_secret_match', reenrollmentPersistence.matched);
    report('recovery_setup_browser_persistence_secret_match', recoverySetupPersistence.matched);
    report('server_file_secret_match', serverLeak);
    if (PG_RECOVERY_MODE) {
      report('pg_plaintext_secret_match', pgLeak);
      report('pg_old_session_statuses', oldSessionStatuses);
      report('pg_recovery_challenge_id_hash', recoveryStartEvent.challengeIdHash);
      report('pg_recovery_challenge_hash', recoveryStartEvent.challengeHash);
      report('pg_recovery_device_id', events.find((event) => event.route === 'auth/recovery/complete')?.recoveredDeviceId || 'missing');
    }
    report('flutter_page_errors', pageErrors);
    console.log('WEB-RECOVERY-FULL-LOSS-01 passed: MFA controls and signed full Recovery completed; the recovered Web client opened personal/shared Vault data across required key epochs.');
  } catch (error) {
    console.error(`failed stage: ${stage}`);
    const diagnosticTarget = [recoveryPage, memberPage, page]
      .find((target) => target && !target.isClosed());
    if (diagnosticTarget) {
      const diagnostics = {
        browserConnected: browser?.isConnected?.() ?? false,
        pageStates: [page, recoveryPage, memberPage].map((target) => target
          ? { closed: target.isClosed(), url: target.isClosed() ? null : safeDiagnostic(target.url()) }
          : null),
        pageErrors,
        pageErrorMessages: pageErrorMessages.slice(-4),
        consoleMessageCount: consoleMessages.length,
        consoleMessages: consoleMessages.slice(-6),
        semanticNodeCount: await diagnosticTarget.locator('flt-semantics').count().catch(() => -1),
        visibleText: safeDiagnostic(await diagnosticTarget.locator('body').innerText().catch(() => '')),
        memberRoleLabels: ((await diagnosticTarget.locator('body').innerText().catch(() => ''))
          .match(/\b(?:OWNER|EDITOR|VIEWER)\s+·\s+(?:Active|Invited|Revoked)\b/g) || []),
        syncButtonLabels: await diagnosticTarget.locator('flt-semantics').evaluateAll((elements) =>
          elements.filter((element) => element.getAttribute('role') === 'button')
            .map((element) => [element.innerText, element.textContent,
              element.getAttribute('aria-label'), element.getAttribute('aria-valuetext'),
              element.getAttribute('title')].filter((value) => typeof value === 'string').join(' '))
            .filter((value) => /\b(?:Idle|Syncing|Pending)\b|pending\s+\d+/i.test(value)))
          .catch(() => []),
        documentTitle: await diagnosticTarget.title().catch(() => ''),
      };
      console.error(`safe browser diagnostics: ${JSON.stringify(diagnostics)}`);
    }
    const safeApiSummary = events.filter((event) => event.route?.startsWith('auth/recovery/')
      || event.route?.includes('members')
      || event.route?.includes('keys/rotate') || event.route === 'vaults/:id/membership'
      || event.route === 'vaults/:id/changes' || event.route === 'vaults/:id/sync/push')
      .slice(-40).map(({ route, method, status, hasBearer, vaultId, ownerUserId,
        activeKeyEpoch, membershipVersion, vaultStatus, errorCode, recovered,
        recoveredDevicePresent, recoveryGeneration, requiredContexts, presentContexts }) => ({ route,
        method, status, hasBearer, vaultId, ownerUserId, activeKeyEpoch,
        membershipVersion, vaultStatus, errorCode, recovered, recoveredDevicePresent,
        recoveryGeneration, requiredContexts, presentContexts }));
    console.error(`safe API summary: ${JSON.stringify(safeApiSummary)}`);
    throw new Error(`WEB-RECOVERY-FULL-LOSS-01 failed at ${stage}: ${error?.message || 'unknown error'}`);
  } finally {
    await cleanup();
    if (cleanupFailed) throw new Error('temporary MFA/Recovery resources did not clean up');
  }
}

main().catch((error) => {
  console.error(error?.message || 'WEB-RECOVERY-FULL-LOSS-01 failed');
  process.exitCode = 1;
});
