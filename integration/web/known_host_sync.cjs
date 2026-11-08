/*
 * WEB-KNOWNHOST-01: sync an approved SSH host key to a separately enrolled
 * Web profile, race two stale-view approvals, and exercise a real same-origin
 * two-tab userauth-versus-revoke boundary before the changed-key checks.
 *
 * All browser data, server state, SSH host keys and logs are confined to a
 * disposable temporary directory. The SSHD binds only eth0's address and the
 * server Relay allowlist contains exactly that address and the SSHD port.
 * Root SSH login, password authentication, forwarding, TTY and tunnels are
 * disabled. SSH identities and userauth gate state are run-scoped fixtures;
 * none of the SSHD instances can open an interactive session.
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
const SSHD = process.env.SSHD_PATH || '/usr/sbin/sshd';
const SSH_KEYGEN = process.env.SSH_KEYGEN_PATH || '/usr/bin/ssh-keygen';
const SSH_OUTCOME_TIMEOUT_MS = 100000;
const BROWSER_CLEANUP_TIMEOUT_MS = 5000;
const RUN_ID = crypto.randomUUID();
const EMAIL = `known-host-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `KnownHost${crypto.randomBytes(24).toString('hex')}9`;
let activeStage = 'setup';
const safeApiStatuses = [];
const safeBrowserIssues = [];
const safeStartupProbes = [];
let safeApiSequence = 0;
let safeNetworkSequence = 0;

function executableOnPath(name) {
  for (const directory of (process.env.PATH || '').split(path.delimiter)) {
    const candidate = path.join(directory || process.cwd(), name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch (_) {}
  }
  return null;
}

async function boundedAction(action, timeoutMs = BROWSER_CLEANUP_TIMEOUT_MS) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(action),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('cleanup timeout')), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function cleanupStep(label, action, timeoutMs = BROWSER_CLEANUP_TIMEOUT_MS) {
  try {
    const result = await boundedAction(action, timeoutMs);
    if (result === false) throw new Error('cleanup did not confirm completion');
    console.log(`WEB-KNOWNHOST-01 cleanup ${label}: complete`);
    return true;
  } catch (_) {
    console.warn(`WEB-KNOWNHOST-01 cleanup ${label}: timed out or failed`);
    return false;
  }
}

async function stopOwnedBrowserServer(browserServer) {
  if (!browserServer) return true;
  let child;
  try { child = browserServer.process(); } catch (_) {}
  const graceful = await cleanupStep('Chromium server close', () => browserServer.close());
  if (graceful && (!child || childHasExited(child))) return true;

  await cleanupStep('Chromium server kill', () => browserServer.kill());
  if (!child || !Number.isInteger(child.pid)) {
    console.warn('WEB-KNOWNHOST-01 cleanup Chromium process exit: unconfirmed');
    return false;
  }
  await waitForChildExit(child, 2000);
  if (!childHasExited(child)) {
    try { child.kill('SIGKILL'); } catch (_) {}
    await waitForChildExit(child, 1500);
  }
  const stopped = childHasExited(child);
  console.log(`WEB-KNOWNHOST-01 cleanup Chromium process exit: ${stopped ? 'complete' : 'unconfirmed'}`);
  return stopped;
}

function childHasExited(child) {
  return !child || child.exitCode !== null || child.signalCode !== null;
}

async function waitForChildExit(child, timeoutMs) {
  if (childHasExited(child)) return true;
  let timer;
  let onExit;
  try {
    await Promise.race([
      new Promise((resolve) => {
        onExit = resolve;
        child.once('exit', onExit);
      }),
      new Promise((resolve) => { timer = setTimeout(resolve, timeoutMs); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
    if (onExit) child.removeListener('exit', onExit);
  }
  return childHasExited(child);
}

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function safeApiRoute(pathname) {
  if (pathname.endsWith('/sync/push')) return 'sync_push';
  if (pathname.endsWith('/changes')) return 'sync_changes';
  if (pathname.endsWith('/membership')) return 'vault_membership';
  if (pathname === '/api/v1/devices' || pathname.endsWith('/devices')) return 'devices';
  if (pathname.endsWith('/relay/tickets')) return 'relay_ticket';
  if (pathname.endsWith('/register') || pathname.endsWith('/login')) return 'auth';
  return 'other_api';
}

function safeApiEndpointClass(pathname) {
  const segments = pathname.split('/').filter(Boolean);
  if (segments[0] !== 'api' || segments[1] !== 'v1') return 'other';
  const resource = segments[2] || 'root';
  const subresource = segments[3] || 'root';
  if (resource === 'vaults') {
    const action = segments[4] === 'sync' ? `sync_${segments[5] || 'root'}`
      : segments[4] === 'membership' ? `membership_${segments[5] || 'root'}`
        : segments[4] || 'root';
    return `vault_${action}`;
  }
  if (resource === 'auth') return `auth_${subresource}`;
  if (resource === 'relay' || resource === 'notifications' || resource === 'presence') {
    return `${resource}_${subresource}`;
  }
  return `api_${resource}_${subresource}`;
}

function trackSafeApiResponses(page, profile) {
  const requestSequences = new WeakMap();
  page.on('request', (request) => {
    try {
      const url = new URL(request.url());
      if (url.pathname.startsWith('/api/v1/')) {
        requestSequences.set(request, ++safeNetworkSequence);
      }
    } catch (_) {}
  });
  page.on('response', (response) => {
    try {
      const url = new URL(response.url());
      if (!url.pathname.startsWith('/api/v1/')) return;
      const request = response.request();
      const status = {
        sequence: ++safeApiSequence,
        requestSequence: requestSequences.get(request) || null,
        networkSequence: ++safeNetworkSequence,
        profile,
        method: request.method(),
        route: safeApiRoute(url.pathname),
        endpointClass: safeApiEndpointClass(url.pathname),
        status: response.status(),
        changeEventCount: null,
      };
      safeApiStatuses.push(status);
      if (safeApiStatuses.length > 2000) safeApiStatuses.shift();
      if (status.route === 'sync_changes') {
        void response.json().then((body) => {
          status.changeEventCount = Array.isArray(body?.events) ? body.events.length : null;
        }).catch(() => {});
      }
    } catch (_) {}
  });
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${path.basename(command)} failed in isolated fixture`);
  }
  return result.stdout || '';
}

async function unusedPort(host) {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function localEth0Address() {
  const result = spawnSync('ip', ['-o', '-4', 'addr', 'show', 'dev', 'eth0', 'scope', 'global'], {
    encoding: 'utf8', timeout: 5000,
  });
  const match = (result.stdout || '').match(/\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\//);
  if (result.status !== 0 || !match || /^127\.|^169\.254\./.test(match[1])) return null;
  return match[1];
}

async function waitReady(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited before readiness');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1500) });
      if (response.status === 200) return;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

async function waitForTcp(address, port, child, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated SSHD exited before readiness');
    const connected = await new Promise((resolve) => {
      const socket = net.createConnection({ host: address, port });
      socket.setTimeout(500);
      socket.once('connect', () => { socket.destroy(); resolve(true); });
      socket.once('error', () => resolve(false));
      socket.once('timeout', () => { socket.destroy(); resolve(false); });
    });
    if (connected) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('isolated SSHD did not listen on its fixture address');
}

async function hasSemanticsText(page, text) {
  const semantics = page.locator('flt-semantics');
  return semantics.evaluateAll((nodes, target) => nodes.some((node) => {
    const label = node.getAttribute('aria-label') || '';
    const visibleText = node.innerText || node.textContent || '';
    const normalized = `${label} ${visibleText}`.replace(/\s+/g, ' ').trim();
    return normalized.includes(target);
  }), text).catch(() => false);
}

async function waitForText(page, text, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await hasSemanticsText(page, text)) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected accessible Web UI label did not appear');
}

async function safeTrustPanelState(page) {
  return page.locator('flt-semantics').evaluateAll((nodes) => {
    const labels = nodes.flatMap((node) => {
      const style = getComputedStyle(node);
      const bounds = node.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          bounds.width <= 0 || bounds.height <= 0 || bounds.bottom <= 0 ||
          bounds.top >= innerHeight || bounds.right <= 0 || bounds.left >= innerWidth) {
        return [];
      }
      return [`${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
        .replace(/\s+/g, ' ').trim()];
    });
    const pageText = document.body.innerText || '';
    return {
      settingsHeadingVisible: labels.some((label) => label.includes('SSH host-key trust')),
      trustedStatusCount: labels.filter((label) => /\bTRUSTED\b/i.test(label)).length,
      revokedStatusCount: labels.filter((label) => /\bREVOKED\b/i.test(label)).length,
      conflictStatusCount: labels.filter((label) => /\bCONFLICT\b.*\bCONNECTIONS BLOCKED\b/i.test(label)).length,
      revokeDialogVisible: labels.some((label) => label.includes('Revoke SSH host-key trust?')),
      emptyStateVisible: labels.some((label) => label.includes('No host keys have been approved in this Vault.')),
      revokeControlCount: labels.filter((label) => label.includes('Revoke SSH host-key trust')).length,
      revokeSuccessNoticeVisible: pageText.includes('SSH 主机密钥信任已撤销并加密保存到当前 Vault。'),
      genericErrorNoticeVisible: /(?:failed|error|失败|错误|无法|只读)/i.test(pageText),
      accessibleErrorNoticeVisible: labels.some((label) =>
        /(?:failed|error|失败|错误|无法|只读|不可用|超时)/i.test(label)),
      errorCategories: [
        ['sync', /(?:sync|同步)/i],
        ['permission', /(?:read.only|permission|只读|权限|成员)/i],
        ['revision', /(?:revision|版本|冲突)/i],
        ['storage', /(?:database|storage|数据库|存储)/i],
        ['transport', /(?:connection|network|transport|连接|网络)/i],
      ].filter(([, pattern]) => labels.some((label) => pattern.test(label)))
        .map(([category]) => category),
    };
  }).catch(() => ({ stateUnavailable: true }));
}

async function safeSyncButtonLabels(page) {
  return page.locator('flt-semantics[role="button"]').evaluateAll((nodes) =>
    nodes.map((node) => node.getAttribute('aria-label') || node.innerText || '')
      .map((label) => label.trim())
      .filter((label) => /^(?:Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/.test(label))
      .slice(0, 8),
  ).catch(() => []);
}

async function waitForKnownHostState(
  page,
  state,
  expectedMinimumCount,
  timeout = 20000,
) {
  const fieldName = {
    trusted: 'trustedStatusCount',
    revoked: 'revokedStatusCount',
    conflict: 'conflictStatusCount',
  }[state];
  assertThat(fieldName, 'known-host state assertion is invalid');
  await scrollSettingsToKnownHostPanel(page);
  const deadline = Date.now() + timeout;
  let firstVisibleError = null;
  while (Date.now() < deadline) {
    const panelState = await safeTrustPanelState(page);
    const count = panelState[fieldName] ?? -1;
    if (expectedMinimumCount === 0 ? count === 0 : count >= expectedMinimumCount) {
      return;
    }
    if (!firstVisibleError &&
        (panelState.genericErrorNoticeVisible || panelState.accessibleErrorNoticeVisible)) {
      firstVisibleError = {
        genericErrorNoticeVisible: panelState.genericErrorNoticeVisible,
        accessibleErrorNoticeVisible: panelState.accessibleErrorNoticeVisible,
        errorCategories: panelState.errorCategories,
      };
    }
    await page.waitForTimeout(100);
  }
  const finalState = await safeTrustPanelState(page);
  throw new Error(`known-host trust panel did not reach the expected visible state: ${JSON.stringify({
    finalState,
    firstVisibleError,
    syncButtons: await safeSyncButtonLabels(page),
  })}`);
}

async function trustedRowSemantics(page, expectedEndpoint) {
  const empty = {
    sshEd25519LabelPresent: false,
    trustedLabelPresent: false,
    conflictLabelPresent: false,
    trustedRowSemanticsFound: false,
    endpointLabelPresent: false,
    emptyStatePresent: false,
    revokeControlPresent: false,
    sshEd25519LabelCount: 0,
    trustedLabelCount: 0,
  };
  return page.locator('flt-semantics').evaluateAll((nodes, endpoint) => {
    const visibleLabels = [];
    for (const node of nodes) {
      const style = getComputedStyle(node);
      const bounds = node.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          bounds.width <= 0 || bounds.height <= 0 || bounds.bottom <= 0 ||
          bounds.top >= innerHeight || bounds.right <= 0 || bounds.left >= innerWidth) {
        continue;
      }
      visibleLabels.push(`${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
        .replace(/\s+/g, ' ').trim());
    }
    const sshEd25519LabelCount = visibleLabels.filter((label) =>
      label.toLowerCase().includes('ssh-ed25519')).length;
    const trustedLabelCount = visibleLabels.filter((label) => /\btrusted\b/i.test(label)).length;
    const conflictLabelCount = visibleLabels.filter((label) =>
      /\bconflict\b.*\bconnections blocked\b/i.test(label)).length;
    const sshEd25519LabelPresent = sshEd25519LabelCount > 0;
    const trustedLabelPresent = trustedLabelCount > 0;
    const conflictLabelPresent = conflictLabelCount > 0;
    const endpointLabelPresent = visibleLabels.some((label) => label.includes(endpoint));
    return {
      sshEd25519LabelPresent,
      trustedLabelPresent,
      // Flutter Web may omit the endpoint/algorithm Text from its semantics
      // DOM while still exposing the status and row action. Require the trust
      // state and revoke affordance here; SSH behavior checks later prove that
      // this is the expected endpoint's encrypted record.
      trustedRowSemanticsFound: (trustedLabelPresent || conflictLabelPresent) &&
        visibleLabels.some((label) => label.includes('Revoke SSH host-key trust')),
      endpointLabelPresent,
      emptyStatePresent: visibleLabels.some((label) =>
        label.includes('No host keys have been approved in this Vault.')),
      revokeControlPresent: visibleLabels.some((label) =>
        label.includes('Revoke SSH host-key trust')),
      sshEd25519LabelCount,
      trustedLabelCount,
      conflictLabelCount,
      conflictLabelPresent,
    };
  }, expectedEndpoint).catch(() => empty);
}

async function knownHostHeadingTop(page) {
  return page.locator('flt-semantics').evaluateAll((nodes) => {
    for (const node of nodes) {
      const text = `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
        .replace(/\s+/g, ' ').trim();
      if (!text.includes('SSH host-key trust')) continue;
      const bounds = node.getBoundingClientRect();
      return Number.isFinite(bounds.top) ? bounds.top : null;
    }
    return null;
  }).catch(() => null);
}

async function scrollSettingsToKnownHostPanel(page) {
  const viewport = await page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
  await page.mouse.move(
    Math.min(viewport.width - 40, Math.round(viewport.width * 0.75)),
    Math.min(viewport.height - 60, Math.round(viewport.height * 0.75)),
  );
  for (let step = 0; step < 12; step += 1) {
    await page.mouse.wheel(0, 600);
    await page.waitForTimeout(80);
  }
  await page.mouse.wheel(0, -600);
  await page.waitForTimeout(180);
}

async function scrollSettingsToTrustedRow(page, expectedEndpoint, maxAttempts = 6) {
  const viewport = await page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
  const x = Math.min(viewport.width - 40, Math.round(viewport.width * 0.75));
  const y = Math.min(viewport.height - 60, Math.round(viewport.height * 0.75));
  let attempts = 0;
  let scrollDeltaSteps = 0;
  let headingTop = await knownHostHeadingTop(page);
  let signals = await trustedRowSemantics(page, expectedEndpoint);
  while (!signals.trustedRowSemanticsFound && attempts < maxAttempts) {
    await page.mouse.move(x, y);
    await page.mouse.wheel(0, 480);
    attempts += 1;
    await page.waitForTimeout(180);
    const nextHeadingTop = await knownHostHeadingTop(page);
    if (headingTop !== null && nextHeadingTop !== null && Math.abs(nextHeadingTop - headingTop) >= 2) {
      scrollDeltaSteps += 1;
    }
    headingTop = nextHeadingTop;
    signals = await trustedRowSemantics(page, expectedEndpoint);
  }
  const semanticsDeadline = Date.now() + 20000;
  while (!signals.trustedRowSemanticsFound && Date.now() < semanticsDeadline) {
    await page.waitForTimeout(200);
    signals = await trustedRowSemantics(page, expectedEndpoint);
  }
  console.log(JSON.stringify({
    knownhost_row_scroll_attempts: attempts,
    knownhost_heading_scroll_delta_steps: scrollDeltaSteps,
    knownhost_heading_scroll_delta_observed: scrollDeltaSteps > 0,
    ssh_ed25519_label_present: signals.sshEd25519LabelPresent,
    trusted_label_present: signals.trustedLabelPresent,
    conflict_label_present: signals.conflictLabelPresent,
    endpoint_label_present: signals.endpointLabelPresent,
    trusted_row_semantics_found: signals.trustedRowSemanticsFound,
    empty_state_present: signals.emptyStatePresent,
    revoke_control_present: signals.revokeControlPresent,
    ssh_ed25519_label_count: signals.sshEd25519LabelCount,
    trusted_label_count: signals.trustedLabelCount,
  }));
  return signals;
}

async function revokeKnownHostFingerprint(
  page,
  tempRoot,
  endpoint,
  fingerprint,
  expectedRevokedCount,
) {
  const { action, dialogs } = await beginKnownHostFingerprintRevoke(
    page,
    endpoint,
    fingerprint,
  );
  activeStage = 'return exact KnownHost row to the visible viewport';
  await action.scrollIntoViewIfNeeded({ timeout: 10000 });
  await action.waitFor({ state: 'visible', timeout: 10000 });
  activeStage = 'wait for KnownHost revoked state';
  const stateWaitStartedAt = Date.now();
  try {
    await waitForKnownHostState(page, 'revoked', expectedRevokedCount, 50000);
  } catch (error) {
    await page.screenshot({
      path: path.join(tempRoot, 'knownhost-revoke-state.png'),
      fullPage: false,
    }).catch(() => {});
    console.log('KnownHost revoke UI state', JSON.stringify({
      waitMilliseconds: Date.now() - stateWaitStartedAt,
      trustPanel: await safeTrustPanelState(page),
      waitFailure: error?.name === 'TimeoutError' ? 'timeout' : 'state_assertion',
      apiTail: safeApiStatuses.slice(-12).map(({ profile, method, route, status }) =>
        ({ profile, method, route, status })),
    }));
    throw error;
  }
}

async function beginKnownHostFingerprintRevoke(page, endpoint, fingerprint) {
  activeStage = 'locate exact endpoint-and-fingerprint revoke action';
  const expectedLabel = `Revoke SSH host-key trust for ${endpoint} (${fingerprint})`;
  const action = page.getByRole('button', { name: expectedLabel, exact: true });
  const actionCount = await action.count();
  console.log('KnownHost revoke target safe evidence', JSON.stringify({
    exactActionCount: actionCount,
    uniqueTargetFound: actionCount === 1,
  }));
  assertThat(actionCount === 1,
    'the requested KnownHost row did not expose one unique revoke action');
  await action.scrollIntoViewIfNeeded({ timeout: 10000 });
  await action.waitFor({ state: 'visible', timeout: 10000 });
  activeStage = 'open revoke confirmation dialog for exact KnownHost row';
  await action.click();
  activeStage = 'wait for exact KnownHost revoke confirmation dialog';
  await waitForText(page, 'Revoke SSH host-key trust?');
  activeStage = 'confirm revoke for exact KnownHost row';
  const dialogs = page.locator(
    'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
  ).filter({ hasText: 'Revoke SSH host-key trust?' });
  const dialogCount = await dialogs.count();
  assertThat(dialogCount === 1 && await dialogs.first().isVisible(),
    'the exact KnownHost revoke confirmation dialog was not uniquely visible');
  const confirm = dialogs.first().getByRole('button', {
    name: 'Revoke trust', exact: true,
  });
  assertThat(await confirm.count() === 1 && await confirm.isEnabled(),
    'the active KnownHost revoke confirmation did not expose one enabled confirm action');
  await confirm.click();
  await dialogs.first().waitFor({ state: 'hidden', timeout: 10000 });
  return { action, dialogs };
}

async function button(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible()) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error('required Web UI button did not appear');
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function field(page, label) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 15000 });
  return locator;
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 60 });
    await page.waitForTimeout(200);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error('Web UI field did not retain its synthetic input');
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(300);
  if (await locator.inputValue() !== value) {
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(300);
  }
  if (await locator.inputValue() !== value) {
    await locator.fill(value);
    await page.waitForTimeout(100);
  }
  assertThat(await locator.inputValue() === value, 'Web UI did not accept the synthetic enrollment data');
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function installFlutterLoaderProbe(context) {
  await context.addInitScript(() => {
    window.__e2eFlutterProbe = { initializerCalled: false, engineInitialized: false, runAppCompleted: false };
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
                const initialize = engineInitializer.initializeEngine.bind(engineInitializer);
                engineInitializer.initializeEngine = (...args) => initialize(...args).then((runner) => {
                  window.__e2eFlutterProbe.engineInitialized = true;
                  const runApp = runner.runApp.bind(runner);
                  runner.runApp = (...runArgs) => Promise.resolve(runApp(...runArgs)).then((result) => {
                    window.__e2eFlutterProbe.runAppCompleted = true;
                    return result;
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

async function enableSemantics(page) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const ready = await page.evaluate(() => window.__e2eFlutterProbe?.runAppCompleted === true &&
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder')));
    if (ready) break;
    await page.waitForTimeout(100);
  }
  const ready = await page.evaluate(() => window.__e2eFlutterProbe?.runAppCompleted === true &&
    Boolean(document.querySelector('flt-semantics-placeholder')));
  assertThat(ready, 'Flutter Web did not reach its accessible startup state');
  const sodiumState = await page.evaluate(async () => Promise.race([
    window.sodium.ready.then(() => 'ready', () => 'failed'),
    new Promise((resolve) => setTimeout(() => resolve('timeout'), 10000)),
  ]));
  assertThat(sodiumState === 'ready', 'browser cryptography did not initialize');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 15000 });
}

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function openSameProfileWebTab(context, baseUrl) {
  activeStage = 'same-profile tab create page';
  const page = await context.newPage();
  trackSafeApiResponses(page, 'A2');
  activeStage = 'same-profile tab navigate to application origin';
  await page.goto(baseUrl);
  activeStage = 'same-profile tab initialize Flutter and browser crypto';
  await enableSemantics(page);
  activeStage = 'same-profile tab select server account and sync mode';
  await selectServerModeIfChooser(page, null);
  activeStage = 'same-profile tab detect server, login or workspace state';
  const deadline = Date.now() + 25000;
  let state;
  let serverFormVisibleSince;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) {
      state = 'workspace';
      break;
    }
    if (await page.locator('input[aria-label*="Email or username"]')
      .isVisible().catch(() => false)) {
      state = 'login';
      break;
    }
    const serverFormVisible = await page.locator('input[aria-label*="Server URL"]')
      .isVisible().catch(() => false);
    if (serverFormVisible) {
      serverFormVisibleSince ??= Date.now();
      // Server mode briefly shows its connection form while restoring the
      // last server from shared browser storage. Let that async restore settle
      // before typing into a form that may immediately transition to login.
      if (Date.now() - serverFormVisibleSince >= 2500) {
        state = 'server';
        break;
      }
    } else {
      serverFormVisibleSince = undefined;
    }
    await page.waitForTimeout(100);
  }
  if (!state) {
    const readiness = await page.evaluate(() => ({
      originMatchesLoopback: location.origin.startsWith('http://127.0.0.1:'),
      flutterReady: window.__e2eFlutterProbe?.runAppCompleted === true,
      serverUrlFieldVisible: [...document.querySelectorAll('input')].some((input) =>
        input.getAttribute('aria-label')?.includes('Server URL')),
      loginEmailFieldVisible: [...document.querySelectorAll('input')].some((input) =>
        input.getAttribute('aria-label')?.includes('Email or username')),
      addHostButtonVisible: [...document.querySelectorAll('flt-semantics[role="button"]')]
        .some((button) => button.getAttribute('aria-label') === 'Add host'),
      visibleSemanticNodeCount: [...document.querySelectorAll('flt-semantics')]
        .filter((node) => node.getBoundingClientRect().width > 0 &&
          node.getBoundingClientRect().height > 0).length,
    })).catch(() => ({ pageEvaluationAvailable: false }));
    activeStage = `same-profile tab unrecognized readiness ${JSON.stringify(readiness)}`;
  }
  assertThat(state, 'same-profile second tab did not reach server, login or workspace');
  if (state === 'server') {
    activeStage = 'same-profile tab fill explicit server URL';
    await fill(page, 'Server URL', baseUrl);
    activeStage = 'same-profile tab submit explicit server connection';
    await click(page, 'Connect securely');
    activeStage = 'same-profile tab wait for server connection result';
    const nextDeadline = Date.now() + 25000;
    while (Date.now() < nextDeadline) {
      if (await page.getByRole('button', { name: 'Add host', exact: true })
        .isVisible().catch(() => false)) {
        state = 'workspace';
        break;
      }
      if (await page.locator('input[aria-label*="Email or username"]')
        .isVisible().catch(() => false)) {
        state = 'login';
        break;
      }
      await page.waitForTimeout(100);
    }
  }
  if (state === 'login') {
    activeStage = 'same-profile tab sign in to the existing account';
    await fill(page, 'Email or username', EMAIL);
    await fill(page, 'Master password', MASTER_PASSWORD);
    await click(page, 'Sign in and unlock');
  }
  activeStage = 'same-profile tab wait for workspace';
  await waitWorkspace(page);
  return page;
}

async function syncNow(page, { force = false } = {}) {
  const pattern = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/;
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const statusButtons = page.getByRole('button', { name: pattern });
    const count = await statusButtons.count();
    let status;
    let statusButton;
    for (let index = 0; index < count; index += 1) {
      const candidate = statusButtons.nth(index);
      if (await candidate.isVisible()) {
        statusButton = candidate;
        status = (await candidate.getAttribute('aria-label') || await candidate.innerText()).trim();
        break;
      }
    }
    if (status === 'Idle' && !force) return;
    if (status === 'Syncing') {
      await page.waitForTimeout(150);
      continue;
    }
    if (statusButton) {
      await statusButton.click();
      if (force) return;
    }
    try {
      await page.getByRole('button', { name: 'Idle', exact: true }).waitFor({ state: 'visible', timeout: 45000 });
      return;
    } catch (_) {}
  }
  const safeStatuses = await page.evaluate(() => {
    const allowed = /^(?:Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/;
    return [...document.querySelectorAll('flt-semantics[role="button"]')]
      .map((element) => element.getAttribute('aria-label') || element.innerText || '')
      .map((label) => label.trim())
      .filter((label) => allowed.test(label))
      .slice(0, 8);
  }).catch(() => []);
  activeStage = `${activeStage} (safe sync states: ${JSON.stringify(safeStatuses)})`;
  throw new Error('Vault synchronization did not settle');
}

async function waitForSafeApiResponse(
  profile,
  route,
  afterSequence,
  timeoutMs = 60000,
  afterRequestSequence = null,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = safeApiStatuses.find((candidate) =>
      candidate.sequence > afterSequence &&
      candidate.profile === profile &&
      candidate.route === route &&
      (afterRequestSequence === null ||
        candidate.requestSequence > afterRequestSequence));
    if (event) {
      assertThat(event.status === 200, `isolated ${profile} ${route} response was not successful`);
      return event;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`isolated ${profile} ${route} response did not arrive`);
}

async function waitForProfileChangesEvent(
  profile,
  afterNetworkSequence,
  expectedMinimum,
  timeoutMs = 60000,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const changes = safeApiStatuses.filter((status) =>
      status.profile === profile &&
      status.route === 'sync_changes' &&
      status.requestSequence > afterNetworkSequence);
    const eventResponse = changes.find((status) =>
      status.status === 200 &&
      Number.isInteger(status.changeEventCount) &&
      status.changeEventCount >= expectedMinimum);
    if (eventResponse) return eventResponse;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`isolated ${profile} Changes response did not include the expected event`);
}

async function gateSyncPush(page) {
  const pattern = '**/api/v1/vaults/*/sync/push';
  let released = false;
  let releaseGate;
  let signalBlocked;
  const blocked = new Promise((resolve) => { signalBlocked = resolve; });
  const releasePromise = new Promise((resolve) => { releaseGate = resolve; });
  const handler = async (route) => {
    if (!released) {
      signalBlocked();
      await releasePromise;
    }
    await route.continue();
  };
  await page.route(pattern, handler);
  return {
    waitUntilBlocked: async (timeoutMs = 45000) => Promise.race([
      blocked,
      new Promise((_, reject) => setTimeout(
        () => reject(new Error('isolated sync push did not reach the concurrency gate')),
        timeoutMs,
      )),
    ]),
    release: () => {
      if (released) return;
      released = true;
      releaseGate();
    },
    remove: async () => {
      released = true;
      releaseGate();
      await page.unroute(pattern, handler);
    },
  };
}

async function blockVaultSyncReads(page) {
  const patterns = [
    '**/api/v1/vaults/*/changes**',
    '**/api/v1/vaults/*/conflict-changes**',
  ];
  const handlers = [];
  let aborted = 0;
  await page.evaluate(() => {
    Object.defineProperty(window.navigator, 'onLine', {
      configurable: true,
      get: () => false,
    });
  });
  for (const pattern of patterns) {
    const handler = async (route) => {
      aborted++;
      await route.abort('failed');
    };
    handlers.push({ pattern, handler });
    await page.route(pattern, handler);
  }
  return {
    get aborted() { return aborted; },
    remove: async () => {
      for (const { pattern, handler } of handlers) {
        await page.unroute(pattern, handler);
      }
      await page.evaluate(() => {
        Object.defineProperty(window.navigator, 'onLine', {
          configurable: true,
          get: () => true,
        });
      }).catch(() => {});
    },
  };
}

function createSshdConfig(
  tempRoot,
  address,
  port,
  hostKey,
  instanceName = 'primary',
  { authorizedKeysCommand, loginGraceTime = 10 } = {},
) {
  assertThat(Number.isInteger(loginGraceTime) && loginGraceTime >= 10 && loginGraceTime <= 600,
    'isolated SSHD login grace time is outside its supported test range');
  const configPath = path.join(tempRoot, `${instanceName}_sshd_config`);
  const lines = [
    `Port ${port}`,
    `ListenAddress ${address}`,
    `HostKey ${hostKey}`,
    `PidFile ${path.join(tempRoot, `${instanceName}_sshd.pid`)}`,
    'Protocol 2',
    'PubkeyAuthentication yes',
    'AuthenticationMethods publickey',
    'PasswordAuthentication no',
    'KbdInteractiveAuthentication no',
    'PermitRootLogin no',
    'AuthorizedKeysFile none',
    'StrictModes no',
    'UsePAM no',
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'AllowAgentForwarding no',
    'AllowTcpForwarding no',
    'X11Forwarding no',
    'PermitTunnel no',
    'PermitTTY no',
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 1',
    `LoginGraceTime ${loginGraceTime}`,
    'LogLevel DEBUG1',
  ];
  if (authorizedKeysCommand) {
    const loginUser = authorizedKeysCommand.loginUser || authorizedKeysCommand.user;
    lines.push(
      `AuthorizedKeysCommand ${authorizedKeysCommand.command} %u %f`,
      `AuthorizedKeysCommandUser ${authorizedKeysCommand.user}`,
      `AllowUsers ${loginUser}`,
      'MaxSessions 0',
      'ForceCommand /bin/false',
    );
  }
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  runChecked(SSHD, ['-t', '-f', configPath], { timeout: 10000 });
  const effective = runChecked(SSHD, ['-T', '-f', configPath], { timeout: 10000 });
  for (const setting of ['permitrootlogin no', 'passwordauthentication no',
    'allowtcpforwarding no', 'x11forwarding no', 'permittty no']) {
    assertThat(effective.split('\n').includes(setting), 'isolated SSHD safety policy was not applied');
  }
  if (authorizedKeysCommand) {
    const loginUser = authorizedKeysCommand.loginUser || authorizedKeysCommand.user;
    for (const setting of [
      `authorizedkeyscommand ${authorizedKeysCommand.command} %u %f`,
      `authorizedkeyscommanduser ${authorizedKeysCommand.user}`,
      'authenticationmethods publickey',
      'authorizedkeysfile none',
      'maxsessions 0',
      'forcecommand /bin/false',
      `logingracetime ${loginGraceTime}`,
      `allowusers ${loginUser}`,
    ]) {
      assertThat(effective.split('\n').includes(setting),
        'isolated SSHD userauth gate policy was not applied');
    }
  }
  return configPath;
}

function createUserauthGate(tempRoot, account) {
  const temporaryParent = os.tmpdir();
  const temporaryParentStat = fs.statSync(temporaryParent);
  const temporaryParentMode = temporaryParentStat.mode;
  assertThat(temporaryParentStat.isDirectory(),
    'userauth gate temporary parent is not a directory');
  assertThat((temporaryParentMode & 0o0022) === 0 || (temporaryParentMode & 0o1000) !== 0,
    'userauth gate temporary parent must be private or sticky');
  const gateRoot = fs.mkdtempSync(path.join(temporaryParent, 'atermius-authgate-'));
  const stateRoot = path.join(gateRoot, 'state');
  const commandPath = path.join(gateRoot, 'authorized-keys-gate');
  const enteredMarker = path.join(stateRoot, 'entered');
  const releasedMarker = path.join(stateRoot, 'released');
  try {
    assertThat(Number.isInteger(account.uid) && account.uid > 0 &&
      Number.isInteger(account.gid) && account.gid > 0,
    'userauth gate requires a verified run-scoped account');
    // The script directory permits traversal only; its state directory belongs
    // to the dedicated fixture account so other local users cannot plant markers.
    fs.chmodSync(gateRoot, 0o711);
    fs.mkdirSync(stateRoot, { mode: 0o700 });
    fs.chownSync(stateRoot, account.uid, account.gid);
    fs.chmodSync(stateRoot, 0o700);

    const quotePath = (value) => "'" + String(value).replaceAll("'", "'\\''") + "'";
    const command = [
      '#!/bin/sh',
      'set -eu',
      'umask 077',
      `if [ -e ${quotePath(releasedMarker)} ]; then exit 0; fi`,
      `printf 'entered\\n' > ${quotePath(enteredMarker)}`,
      `while [ ! -e ${quotePath(releasedMarker)} ]; do /bin/sleep 0.05; done`,
      // An empty authorized-keys response deliberately rejects this synthetic
      // public key after the browser releases the SSH userauth lock.
      'exit 0',
    ].join('\n') + '\n';
    fs.writeFileSync(commandPath, command, { mode: 0o755 });
    fs.chmodSync(commandPath, 0o755);
    const stat = fs.statSync(commandPath);
    assertThat(stat.uid === 0 && (stat.mode & 0o022) === 0,
      'userauth gate command ownership or permissions were unsafe');
    const stateStat = fs.statSync(stateRoot);
    assertThat(stateStat.uid === account.uid && stateStat.gid === account.gid &&
      (stateStat.mode & 0o777) === 0o700,
    'userauth gate state directory ownership or permissions were unsafe');

    const privateKeyPath = path.join(tempRoot, 'userauth_gate_client_rsa');
    runChecked(SSH_KEYGEN, [
      '-q', '-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '', '-f', privateKeyPath,
    ], { timeout: 30000 });
    fs.chmodSync(privateKeyPath, 0o600);
    const privateKey = fs.readFileSync(privateKeyPath, 'utf8').trimEnd();

    let entered = false;
    let released = false;
    return {
      root: gateRoot,
      stateRoot,
      commandPath,
      accountUid: account.uid,
      accountGid: account.gid,
      privateKey,
      async waitUntilEntered(timeoutMs = 30000) {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
          try {
            if (fs.readFileSync(enteredMarker, 'utf8').trim() === 'entered') {
              entered = true;
              return;
            }
          } catch (_) {}
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        throw new Error('OpenSSH userauth gate was not entered');
      },
      release() {
        if (released || !entered) return false;
        fs.writeFileSync(releasedMarker, 'released\n', { mode: 0o600 });
        fs.chownSync(releasedMarker, account.uid, account.gid);
        fs.chmodSync(releasedMarker, 0o600);
        released = true;
        return true;
      },
      clearPrivateKey() { this.privateKey = ''; },
      get entered() { return entered; },
      get released() { return released; },
    };
  } catch (error) {
    // The caller cannot retain this path if construction fails before return.
    try {
      for (const marker of ['entered', 'released']) {
        const markerPath = path.join(stateRoot, marker);
        if (fs.existsSync(markerPath)) fs.unlinkSync(markerPath);
      }
      if (fs.existsSync(commandPath)) fs.unlinkSync(commandPath);
      if (fs.existsSync(stateRoot)) fs.rmdirSync(stateRoot);
      if (fs.existsSync(gateRoot)) fs.rmdirSync(gateRoot);
    } catch (_) {}
    throw error;
  }
}

function cleanupUserauthGate(gate) {
  if (!gate) return true;
  const rootStat = fs.lstatSync(gate.root);
  assertThat(rootStat.isDirectory() && rootStat.uid === 0 &&
    (rootStat.mode & 0o777) === 0o711,
  'refusing to remove a changed userauth gate root');
  assertThat(fs.readdirSync(gate.root).sort().join(',') === 'authorized-keys-gate,state',
    'refusing to remove unexpected files from userauth gate root');
  const commandStat = fs.lstatSync(gate.commandPath);
  assertThat(commandStat.isFile() && commandStat.uid === 0 &&
    (commandStat.mode & 0o022) === 0,
  'refusing to remove a changed userauth gate command');
  const stateStat = fs.lstatSync(gate.stateRoot);
  assertThat(stateStat.isDirectory() && stateStat.uid === gate.accountUid &&
    stateStat.gid === gate.accountGid && (stateStat.mode & 0o777) === 0o700,
  'refusing to remove a changed userauth gate state directory');
  for (const entry of fs.readdirSync(gate.stateRoot)) {
    assertThat(entry === 'entered' || entry === 'released',
      'refusing to remove an unexpected userauth gate marker');
    const markerPath = path.join(gate.stateRoot, entry);
    const markerStat = fs.lstatSync(markerPath);
    assertThat(markerStat.isFile() && markerStat.uid === gate.accountUid &&
      markerStat.gid === gate.accountGid && (markerStat.mode & 0o077) === 0,
      'refusing to remove a changed userauth gate marker');
    fs.unlinkSync(markerPath);
  }
  fs.rmdirSync(gate.stateRoot);
  fs.unlinkSync(gate.commandPath);
  fs.rmdirSync(gate.root);
  return true;
}

function userauthAccountFixture() {
  return {
    name: `atermius-auth-${RUN_ID.replaceAll('-', '').slice(0, 16)}`,
    comment: `atermius-test-${RUN_ID.replaceAll('-', '')}`,
    home: '/tmp',
    shell: '/bin/sh',
    uid: null,
    gid: null,
    created: false,
  };
}

function provisionUserauthAccount(fixture) {
  const getentUser = spawnSync('getent', ['passwd', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  const getentGroup = spawnSync('getent', ['group', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  assertThat(!getentUser.error && !getentGroup.error &&
    getentUser.status === 2 && !getentUser.stdout.trim() &&
    getentGroup.status === 2 && !getentGroup.stdout.trim(),
  'run-scoped SSH user or group name was already present');

  const useradd = spawnSync('useradd', [
    '--system', '--user-group', '--no-create-home',
    '--home-dir', fixture.home, '--shell', fixture.shell,
    '--comment', fixture.comment, fixture.name,
  ], { encoding: 'utf8', timeout: 10000 });
  if (!useradd.error && useradd.status === 0) {
    fixture.created = true;
  } else {
    // A timed-out useradd may have completed its account write before the
    // child was reaped. Claim cleanup ownership only with this run's GECOS tag.
    const partial = spawnSync('getent', ['passwd', fixture.name], {
      encoding: 'utf8', timeout: 3000,
    });
    const partialFields = (partial.stdout || '').trim().split(':');
    if (!partial.error && partial.status === 0 && partialFields[0] === fixture.name &&
        partialFields[4] === fixture.comment && partialFields[5] === fixture.home &&
        partialFields[6] === fixture.shell) {
      fixture.created = true;
    }
    assertThat(false, 'could not create the isolated unprivileged SSH userauth account');
  }

  const accountResult = spawnSync('getent', ['passwd', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  const fields = (accountResult.stdout || '').trim().split(':');
  const uid = Number(fields[2]);
  const gid = Number(fields[3]);
  assertThat(!accountResult.error && accountResult.status === 0 &&
    fields[0] === fixture.name && fields[4] === fixture.comment &&
    fields[5] === fixture.home && fields[6] === fixture.shell &&
    Number.isInteger(uid) && uid > 0 && Number.isInteger(gid) && gid > 0,
  'isolated SSH userauth account did not match its run-scoped identity');
  fixture.uid = uid;
  fixture.gid = gid;

  const randomPassword = crypto.randomBytes(48);
  const passwordInput = Buffer.from(`${randomPassword.toString('base64url')}\n`);
  randomPassword.fill(0);
  let hashResult;
  try {
    hashResult = spawnSync('openssl', ['passwd', '-6', '-stdin'], {
      input: passwordInput, encoding: 'utf8', timeout: 5000,
    });
  } finally {
    passwordInput.fill(0);
  }
  assertThat(!hashResult.error && hashResult.status === 0 &&
    /^\$6\$/.test((hashResult.stdout || '').trim()),
  'could not create an inaccessible password hash for the isolated SSH account');

  const credentialLine = Buffer.from(`${fixture.name}:${hashResult.stdout.trim()}\n`);
  let passwordSet;
  try {
    passwordSet = spawnSync('chpasswd', ['--encrypted'], {
      input: credentialLine, encoding: 'utf8', timeout: 5000,
    });
  } finally {
    credentialLine.fill(0);
  }
  assertThat(!passwordSet.error && passwordSet.status === 0,
    'could not unlock the run-scoped SSH account for OpenSSH key authorization');
  const passwordStatus = spawnSync('passwd', ['-S', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  assertThat(!passwordStatus.error && passwordStatus.status === 0 &&
    (passwordStatus.stdout || '').trim().split(/\s+/)[1] === 'P',
  'OpenSSH fixture account remained locked after provisioning');
}

function cleanupUserauthAccount(fixture) {
  if (!fixture?.created) return;
  const allowedName = new RegExp(`^atermius-auth-[0-9a-f]{16}$`);
  if (!allowedName.test(fixture.name) || !/^atermius-test-[0-9a-f]{32}$/.test(fixture.comment) ||
      fixture.home !== '/tmp' || fixture.shell !== '/bin/sh') {
    throw new Error('refusing to remove an SSH user outside the isolated fixture identity');
  }
  const lookup = spawnSync('getent', ['passwd', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  assertThat(!lookup.error && (lookup.status === 0 || lookup.status === 2),
    'could not safely inspect the isolated SSH account during cleanup');
  let gid = fixture.gid;
  let uid = fixture.uid;
  if (lookup.status === 0 && lookup.stdout.trim()) {
    const fields = lookup.stdout.trim().split(':');
    const actualUid = Number(fields[2]);
    const actualGid = Number(fields[3]);
    assertThat(fields[0] === fixture.name && fields[4] === fixture.comment &&
      fields[5] === fixture.home && fields[6] === fixture.shell &&
      Number.isInteger(actualUid) && actualUid > 0 && Number.isInteger(actualGid) && actualGid > 0 &&
      (uid === null || uid === actualUid) && (gid === null || gid === actualGid),
    'refusing to remove an SSH account whose run-scoped identity changed');
    uid = actualUid;
    gid = actualGid;

    const liveFixtureProcesses = () => {
      const livePids = [];
      for (const entry of fs.readdirSync('/proc')) {
        if (!/^\d+$/.test(entry) || Number(entry) === process.pid) continue;
        let status;
        try { status = fs.readFileSync(`/proc/${entry}/status`, 'utf8'); } catch (_) { continue; }
        const uidFields = status.match(/^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/m);
        const state = status.match(/^State:\s+(\w+)/m)?.[1];
        if (uidFields && [1, 2, 3, 4].some((index) => Number(uidFields[index]) === uid) &&
            state !== 'Z' && state !== 'X') livePids.push(Number(entry));
      }
      return livePids;
    };
    // SSHD's owned process group was stopped immediately before this step.
    // Let children exit, then fail closed if any remain instead of signaling
    // numeric PIDs that could have been recycled between /proc inspection and kill.
    let remaining = [];
    for (let attempt = 0; attempt < 30; attempt++) {
      remaining = liveFixtureProcesses();
      if (remaining.length === 0) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
    assertThat(remaining.length === 0,
      'isolated SSH account still had a live process after its SSHD group stopped');
    const removed = spawnSync('userdel', [fixture.name], {
      encoding: 'utf8', timeout: 10000,
    });
    assertThat(!removed.error && removed.status === 0,
      'could not remove the isolated SSH account');
    const after = spawnSync('getent', ['passwd', fixture.name], {
      encoding: 'utf8', timeout: 3000,
    });
    assertThat(!after.error && after.status === 2 && !after.stdout.trim(),
      'isolated SSH account remained after cleanup');
  }

  const group = spawnSync('getent', ['group', fixture.name], {
    encoding: 'utf8', timeout: 3000,
  });
  assertThat(!group.error && (group.status === 0 || group.status === 2),
    'could not safely inspect the isolated SSH group during cleanup');
  if (group.status === 0 && group.stdout.trim()) {
    const fields = group.stdout.trim().split(':');
    const actualGid = Number(fields[2]);
    const members = (fields[3] || '').split(',').filter(Boolean);
    assertThat(fields[0] === fixture.name && Number.isInteger(actualGid) && actualGid > 0 &&
      (gid === null || gid === actualGid) && members.length === 0,
    'refusing to remove an SSH group with changed identity or members');
    const removed = spawnSync('groupdel', [fixture.name], {
      encoding: 'utf8', timeout: 10000,
    });
    assertThat(!removed.error && removed.status === 0,
      'could not remove the isolated SSH account group');
  }
  fixture.created = false;
}

function readKeyFingerprint(hostKeyPath) {
  const output = runChecked(SSH_KEYGEN, ['-lf', `${hostKeyPath}.pub`, '-E', 'sha256'], { timeout: 10000 });
  const fingerprint = output.match(/\bSHA256:[A-Za-z0-9+/=]+\b/)?.[0];
  assertThat(fingerprint, 'fixture SSH host fingerprint could not be derived');
  return fingerprint;
}

function assertVaultCiphertextAtRest(dataDir, ...plaintextMarkers) {
  const databasePath = path.join(dataDir, 'atermius.db');
  assertThat(fs.existsSync(databasePath), 'isolated server SQLite database was not created');
  const databaseHeader = Buffer.alloc(16);
  const databaseFd = fs.openSync(databasePath, 'r');
  try {
    fs.readSync(databaseFd, databaseHeader, 0, databaseHeader.length, 0);
  } finally {
    fs.closeSync(databaseFd);
  }
  assertThat(databaseHeader.equals(Buffer.from('SQLite format 3\0')),
    'isolated server database did not have a SQLite header');
  const storedBytes = ['atermius.db', 'atermius.db-wal', 'atermius.db-shm', 'atermius.db-journal']
    .map((name) => path.join(dataDir, name))
    .filter((filePath) => fs.existsSync(filePath))
    .map((filePath) => fs.readFileSync(filePath));
  assertThat(storedBytes.length > 0, 'isolated server SQLite files could not be inspected');
  for (const plaintext of plaintextMarkers) {
    assertThat(!storedBytes.some((bytes) => bytes.includes(Buffer.from(plaintext))),
      'server SQLite storage contained plaintext Host or KnownHost data');
  }
}

function readVaultSyncTotals(dataDir) {
  const databasePath = path.join(dataDir, 'atermius.db');
  const python = [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "row=db.execute('SELECT COALESCE(SUM(last_committed_seq),0) FROM vault_counters').fetchone()",
    "versions=db.execute('SELECT COUNT(*) FROM record_versions').fetchone()[0]",
    "events=db.execute('SELECT COUNT(*) FROM change_events').fetchone()[0]",
    "receipts=db.execute('SELECT COUNT(*) FROM op_receipts').fetchone()[0]",
    "heads=db.execute('SELECT COUNT(*) FROM record_heads').fetchone()[0]",
    "head_state=db.execute('SELECT vault_id,record_id,revision_id,deleted,commit_seq FROM record_heads ORDER BY vault_id,record_id').fetchall()",
    "print(json.dumps({'commit_seq':row[0],'versions':versions,'events':events,'receipts':receipts,'heads':heads,'head_state':head_state}))",
  ].join(';');
  const result = spawnSync('python3', ['-c', python, databasePath], {
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error('isolated Vault sync totals could not be inspected');
  }
  return JSON.parse(result.stdout.trim());
}

async function readKnownHostDecisionLocks(page) {
  return page.evaluate(async () => {
    if (!navigator.locks || typeof navigator.locks.query !== 'function') {
      return { supported: false, held: [], pending: [] };
    }
    const state = await navigator.locks.query();
    const owned = (state.held || []).filter((lock) =>
      typeof lock.name === 'string' && lock.name.startsWith('atermius.known-host-auth.v1.'));
    const waiting = (state.pending || []).filter((lock) =>
      typeof lock.name === 'string' && lock.name.startsWith('atermius.known-host-auth.v1.'));
    return {
      supported: true,
      held: owned.map(({ name, mode }) => ({ name, mode })),
      pending: waiting.map(({ name, mode }) => ({ name, mode })),
    };
  });
}

function readSshdLogSummary(tempRoot) {
  let log = '';
  try { log = fs.readFileSync(path.join(tempRoot, 'sshd.log'), 'utf8'); } catch (_) {}
  const lines = log.split(/\r?\n/).filter(Boolean);
  const count = (pattern) => lines.filter((line) => pattern.test(line)).length;
  const event = (line) => {
    if (/server listening/i.test(line)) return 'listening';
    if (/connection from/i.test(line)) return 'connection_accepted';
    if (/userauth|publickey|passwordauthentication/i.test(line)) return 'authentication';
    if (/invalid user/i.test(line)) return 'invalid_user';
    if (/kex|key exchange|host key/i.test(line)) return 'key_exchange';
    if (/preauth/i.test(line)) return 'preauth_close';
    if (/received disconnect|disconnect/i.test(line)) return 'disconnect';
    if (/connection closed|connection reset|disconnected from/i.test(line)) return 'connection_close';
    if (/fatal|error/i.test(line)) return 'server_error';
    return 'other';
  };
  return {
    acceptedConnections: count(/Connection from /i),
    keyExchangeFailures: count(/kex_exchange_identification|Unable to negotiate|no matching .* found/i),
    publicKeyAttempts: count(/userauth-request.*publickey|Failed publickey|Accepted publickey/i),
    acceptedPublicKeys: count(/Accepted publickey/i),
    failedPublicKeys: count(/Failed publickey/i),
    invalidUsers: count(/Invalid user /i),
    preAuthClosures: count(/Connection closed by authenticating user|Connection closed by .* \[preauth\]/i),
    transportClosures: count(/Connection reset|Connection closed|Disconnected from/i),
    eventSequence: lines.map(event).slice(-30),
  };
}

function reachedAuthenticationBoundary(outcome, diagnostics, before, after, relayDelta) {
  return (outcome === 'failed_unclassified' || outcome === 'timeout') &&
    diagnostics?.activeTabState === 'failed' &&
    after.invalidUsers > before.invalidUsers &&
    relayDelta.connections > 0 && relayDelta.sentFrames > 0;
}

function reachedHostKeyRejectionBoundary(outcome, ui, before, after, relayDelta) {
  return outcome === 'failed_unclassified' &&
    ui.activeTabState === 'failed' &&
    !ui.approvalPrompt &&
    after.preAuthClosures > before.preAuthClosures &&
    after.invalidUsers === before.invalidUsers &&
    after.keyExchangeFailures === before.keyExchangeFailures &&
    relayDelta.connections > 0 &&
    relayDelta.sentFrames > 0;
}

function assertOneVaultCommit(before, after, operation) {
  for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
    assertThat(after[field] - before[field] === 1,
      `${operation} did not add exactly one Vault ${field} row`);
  }
}

function assertOneVaultHeadRevision(before, after, operation) {
  for (const field of ['commit_seq', 'versions', 'events', 'receipts']) {
    assertThat(after[field] - before[field] === 1,
      `${operation} did not add exactly one Vault ${field} row`);
  }
  assertThat(after.heads === before.heads,
    `${operation} changed the number of current Vault record heads`);
  const keyOf = (row) => `${row[0]}:${row[1]}`;
  const beforeByKey = new Map(before.head_state.map((row) => [keyOf(row), row]));
  const afterByKey = new Map(after.head_state.map((row) => [keyOf(row), row]));
  const changedKeys = [...new Set([...beforeByKey.keys(), ...afterByKey.keys()])]
    .filter((key) => JSON.stringify(beforeByKey.get(key)) !== JSON.stringify(afterByKey.get(key)));
  assertThat(changedKeys.length === 1,
    `${operation} did not advance exactly one existing Vault record head`);
  const oldHead = beforeByKey.get(changedKeys[0]);
  const newHead = afterByKey.get(changedKeys[0]);
  assertThat(oldHead && newHead && oldHead[2] !== newHead[2] && newHead[4] > oldHead[4],
    `${operation} did not replace one existing head with its new revision`);
}

function assertVaultCommitCount(before, after, expected, operation) {
  for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
    assertThat(after[field] - before[field] === expected,
      `${operation} did not add exactly ${expected} Vault ${field} rows`);
  }
}

function startSshd(configPath, tempRoot) {
  const logFd = fs.openSync(path.join(tempRoot, 'sshd.log'), 'a', 0o600);
  const child = spawn(SSHD, ['-D', '-e', '-f', configPath], {
    cwd: tempRoot,
    env: process.env,
    stdio: ['ignore', logFd, logFd],
    detached: true,
  });
  child.once('exit', () => { try { fs.closeSync(logFd); } catch (_) {} });
  child.once('error', () => { try { fs.closeSync(logFd); } catch (_) {} });
  return child;
}

async function stopGroup(child) {
  if (childHasExited(child)) return true;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
  await waitForChildExit(child, 4000);
  if (!childHasExited(child)) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
    await waitForChildExit(child, 1500);
  }
  return childHasExited(child);
}

async function observeSshUi(page, expectedHostName) {
  return page.evaluate((hostName) => {
    const semanticNodes = [...document.querySelectorAll('flt-semantics')];
    const semanticLabels = semanticNodes.map((node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
        .replace(/\s+/g, ' ').trim());
    const text = [document.body.innerText || '', ...semanticLabels]
      .join('\n').replace(/\s+/g, ' ');
    const activeTab = semanticLabels.find((label) =>
      label.includes(`${hostName} terminal tab`) && /\bactive\b/i.test(label));
    const activeTabState = activeTab?.match(
      /terminal tab,\s*(connecting|connected|disconnected|failed),\s*active\b/i,
    )?.[1]?.toLowerCase() || null;
    return {
      activeTabFound: Boolean(activeTab),
      activeTabState,
      semanticNodeCount: semanticNodes.length,
      failureHints: [
        ['vault_sync', /vault.{0,20}sync|sync.{0,30}vault|vault同步|同步.*vault/i],
        ['host_key', /host.?key|fingerprint|主机密钥|指纹/i],
        ['relay_or_socket', /relay|websocket|socket|connection|连接/i],
        ['authentication', /authentication|permission denied|身份验证|认证/i],
        ['ssh_handshake', /ssh handshake|ssh握手|握手失败/i],
        ['timeout', /timeout|timed out|超时/i],
      ].filter(([, pattern]) => pattern.test(text)).map(([hint]) => hint),
      changedKeyError: /SSH 主机密钥与已保存指纹不同，连接已拒绝|saved host key fingerprint (?:differs|does not match)/i.test(text),
      authenticationError: /SSH 身份验证失败|authentication failed|permission denied|public.?key.*failed|认证失败|身份验证失败|身份验证完成前中断/i.test(text),
      relayError: /无法建立 SSH 中继 WebSocket|SSH relay (?:connection )?(?:failed|error)|relay ticket (?:failed|error)|WebSocket connection failed/i.test(text),
      sshTimeout: /SSH 中继连接超时|SSH connection timed out|SSH handshake timed out|SSH.*(?:timeout|timed out|超时)/i.test(text),
      sshHandshakeFailure: /SSH.{0,24}handshake|SSH.{0,12}握手|握手.{0,16}(?:失败|中断)/i.test(text),
      sshTransportClosed: /SSH 网络连接已中断|SSH transport closed/i.test(text),
      approvalPrompt: text.includes('Verify SSH host key'),
      genericHostKeyError: /已拒绝尚未信任的 SSH 主机密钥|SSH 主机密钥信任检查已停止/i.test(text),
      vaultDecisionStale: /Vault changed after SSH host-key trust was checked/i.test(text),
      vaultScopeChanged: /当前账户或 Vault 已更改，无法验证 SSH 主机密钥/i.test(text),
      approvalNotConfirmed: /Vault sync did not confirm (?:this|the reviewed) SSH host-key approval/i.test(text),
      vaultTransitionBlocked: /Vault 正在恢复或变更成员状态|正在刷新 Vault 成员状态|快照恢复期间|当前 Vault 已锁定/i.test(text),
      vaultSyncStateError: /Vault 同步状态异常|无法完成当前 Vault 同步/i.test(text),
      tooManyHostKeyChecks: /Too many SSH host-key checks were requested/i.test(text),
      hostKeyVerificationGeneric: /SSH 主机密钥验证失败|SSH host.?key verification failed/i.test(text),
      connectedMarker: /\bCONNECTED\b/.test(text),
    };
  }, expectedHostName);
}

function classifySshUi(observation, baseline, { ignoreApprovalPrompt = false } = {}) {
  if (observation.activeTabState === 'connected') return 'connected';
  if (observation.changedKeyError && observation.activeTabState !== 'connected') {
    return 'changed_key_rejected';
  }
  if (observation.approvalPrompt && !ignoreApprovalPrompt) return 'approval_prompt';
  const isNew = (signal) => observation[signal] && !baseline?.[signal];
  if (observation.activeTabState === 'failed' && isNew('authenticationError')) {
    return 'authentication_rejected';
  }
  if (observation.activeTabState === 'failed' && isNew('relayError')) return 'relay_error';
  if (observation.activeTabState === 'failed' && isNew('sshTimeout')) return 'ssh_timeout';
  if (observation.activeTabState === 'failed' && isNew('sshHandshakeFailure')) return 'ssh_handshake_failure';
  if (observation.activeTabState === 'failed' && isNew('sshTransportClosed')) return 'ssh_transport_closed';
  if (observation.activeTabState === 'failed' && isNew('genericHostKeyError')) {
    return 'host_key_error';
  }
  if (observation.activeTabState === 'failed' &&
      observation.activeTabState !== baseline?.activeTabState) {
    return 'failed_unclassified';
  }
  if (!ignoreApprovalPrompt && observation.approvalPrompt) return 'approval_prompt';
  return null;
}

async function pollSshOutcome(
  page,
  timeoutMs = 20000,
  { ignoreApprovalPrompt = false, expectedHostName, baseline } = {},
) {
  const deadline = Date.now() + timeoutMs;
  let lastObservation = await observeSshUi(page, expectedHostName);
  while (Date.now() < deadline) {
    lastObservation = await observeSshUi(page, expectedHostName);
    const classification = classifySshUi(lastObservation, baseline, { ignoreApprovalPrompt });
    if (classification) return { classification, diagnostics: lastObservation };
    await page.waitForTimeout(100);
  }
  return { classification: 'timeout', diagnostics: lastObservation };
}

async function addSshHostAndCredential(
  page,
  address,
  port,
  { credential: existingCredential, hostName: requestedHostName } = {},
) {
  let credential = existingCredential;
  if (!credential) {
    activeStage = 'encrypted SSH host fixture: open Credentials';
    await click(page, 'Credentials');
    activeStage = 'encrypted SSH host fixture: open new Credential form';
    await click(page, 'Add credential');
    credential = {
      name: `Temporary credential ${RUN_ID.slice(0, 6)}`,
      username: `invalid-${RUN_ID.slice(0, 6)}`,
    };
    activeStage = 'encrypted SSH host fixture: fill Credential name';
    await fill(page, 'Credential name', credential.name);
    activeStage = 'encrypted SSH host fixture: fill Credential username';
    await fill(page, 'SSH username', credential.username);
    activeStage = 'encrypted SSH host fixture: fill Credential secret';
    await fill(page, 'Password', `synthetic-${crypto.randomBytes(18).toString('hex')}`);
    activeStage = 'encrypted SSH host fixture: save Credential';
    await click(page, 'Save encrypted credential');
    activeStage = 'encrypted SSH host fixture: wait for Credential card';
    await page.getByRole('group', { name: /Temporary credential/ }).first().waitFor({ state: 'visible', timeout: 15000 });
  }

  activeStage = 'encrypted SSH host fixture: navigate to Hosts';
  await click(page, 'Hosts');
  activeStage = 'encrypted SSH host fixture: open Add host form';
  await click(page, 'Add host');
  activeStage = 'encrypted SSH host fixture: wait for Add host form';
  await waitForText(page, 'Add a host');
  const hostName = requestedHostName || `Temporary key check ${RUN_ID.slice(0, 6)}`;
  activeStage = 'encrypted SSH host fixture: fill Host display name';
  await fill(page, 'Display name', hostName);
  activeStage = 'encrypted SSH host fixture: fill Host address';
  await fill(page, 'Hostname or IP', address);
  activeStage = 'encrypted SSH host fixture: fill Host port';
  await fill(page, 'Port', String(port));
  activeStage = 'encrypted SSH host fixture: fill Host username';
  await fill(page, 'SSH username', credential.username);
  const fieldName = 'SSH credential override';
  const selectedCredential = `${credential.name} · ${credential.username}`;
  activeStage = 'encrypted SSH host fixture: open Credential override dropdown';
  const credentialField = page.getByRole('button', { name: /SSH credential override/i }).last();
  await credentialField.waitFor({ state: 'visible', timeout: 10000 });
  const credentialFieldBounds = await credentialField.boundingBox();
  if (credentialFieldBounds) {
    await page.mouse.click(
      credentialFieldBounds.x + credentialFieldBounds.width / 2,
      credentialFieldBounds.y + credentialFieldBounds.height / 2,
    );
  } else {
    await credentialField.click();
  }
  activeStage = 'encrypted SSH host fixture: select Credential override';
  const optionDeadline = Date.now() + 10000;
  let optionPoint;
  let optionEvidence = { visibleOptionCount: 0, matchingOptionCount: 0 };
  while (Date.now() < optionDeadline && !optionPoint) {
    optionEvidence = await page.evaluate((expected) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const nodes = [...document.querySelectorAll(
        'flt-semantics[role="menuitem"], flt-semantics[role="option"]',
      )].filter(visible).map((element) => {
        const rect = element.getBoundingClientRect();
        const text = `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
          .replace(/\s+/g, ' ').trim();
        return {
          matches: text.includes(expected),
          point: { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 },
        };
      });
      const matching = nodes.filter((item) => item.matches);
      return {
        visibleOptionCount: nodes.length,
        matchingOptionCount: matching.length,
        point: matching[0]?.point || null,
      };
    }, selectedCredential).catch(() => ({
      visibleOptionCount: 0,
      matchingOptionCount: 0,
      point: null,
    }));
    optionPoint = optionEvidence.point;
    if (!optionPoint) await page.waitForTimeout(100);
  }
  if (optionPoint) {
    await page.mouse.click(optionPoint.x, optionPoint.y);
  } else {
    console.log('known-host Credential option safe evidence', JSON.stringify({
      fieldControlVisible: await credentialField.isVisible().catch(() => false),
      visibleOptionCount: optionEvidence.visibleOptionCount,
      matchingOptionCount: optionEvidence.matchingOptionCount,
    }));
    throw new Error('SSH credential override option was not exposed by Flutter semantics');
  }
  const selectedValueDeadline = Date.now() + 5000;
  let selectedValueVisible = false;
  while (Date.now() < selectedValueDeadline && !selectedValueVisible) {
    selectedValueVisible = await page.evaluate(({ expectedField, expectedValue }) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      return [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .map((element) => `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
          .replace(/\s+/g, ' ').trim())
        .some((text) => text.toLowerCase().includes(expectedField.toLowerCase()) &&
          text.includes(expectedValue));
    }, { expectedField: fieldName, expectedValue: selectedCredential }).catch(() => false);
    if (!selectedValueVisible) await page.waitForTimeout(100);
  }
  if (!selectedValueVisible) {
    console.log('known-host Credential selection safe evidence', JSON.stringify({
      selectedValueVisible: false,
      fieldControlVisible: await credentialField.isVisible().catch(() => false),
    }));
    throw new Error('Host Credential selection did not appear in its field control');
  }
  activeStage = 'encrypted SSH host fixture: save encrypted Host';
  await click(page, 'Save encrypted host');
  activeStage = 'encrypted SSH host fixture: wait for saved Host card';
  const card = page.getByRole('group', { name: hostName, exact: false }).first();
  await card.waitFor({ state: 'visible', timeout: 15000 });
  return { hostName, card, credential };
}

async function addPrivateKeyCredential(page, { name, username, privateKey }) {
  activeStage = 'same-profile userauth race: open Credentials';
  await click(page, 'Credentials');
  activeStage = 'same-profile userauth race: open private-key Credential form';
  await click(page, 'Add credential');
  await fill(page, 'Credential name', name);
  await fill(page, 'SSH username', username);
  await click(page, 'Private key');
  await paste(page, 'PEM private key', privateKey);
  await click(page, 'Save encrypted credential');
  await page.getByRole('group', { name: new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) })
    .first().waitFor({ state: 'visible', timeout: 15000 });
  return { name, username };
}

async function enrollSecondDevice(ownerPage, secondPage) {
  await click(secondPage, 'Add this device');
  await waitForText(secondPage, 'Request this device');
  await fill(secondPage, 'Account email', EMAIL);
  await fill(secondPage, 'Device name', 'KnownHost Web profile B');
  await click(secondPage, 'Generate request');
  await field(secondPage, 'Copy this enrollment JSON');
  await click(secondPage, 'Copy');
  const enrollmentJson = await readClipboard(secondPage);
  let format;
  try { format = JSON.parse(enrollmentJson).format; } catch (_) {}
  assertThat(format === 'atermius-device-enrollment-v1', 'second profile enrollment request was malformed');
  await click(secondPage, 'Close');

  await click(ownerPage, 'Devices');
  await click(ownerPage, 'Approve enrollment');
  await paste(ownerPage, 'Enrollment JSON', enrollmentJson);
  await click(ownerPage, 'Review keys');
  await click(ownerPage, 'Approve & seal keys');
  await button(ownerPage, 'Copy');
  await click(ownerPage, 'Copy');
  const approvalJson = await readClipboard(ownerPage);
  assertThat(approvalJson.includes('atermius-device-approval-v1'), 'owner device approval was malformed');
  await click(ownerPage, 'Done');
  await click(ownerPage, 'Hosts');
  await waitWorkspace(ownerPage);

  await click(secondPage, 'Import approval');
  await paste(secondPage, 'Paste approval JSON', approvalJson);
  await click(secondPage, 'Import device keys');
  await fill(secondPage, 'Email or username', EMAIL);
  await fill(secondPage, 'Master password', MASTER_PASSWORD);
  await click(secondPage, 'Sign in and unlock');
  await waitWorkspace(secondPage);
}

async function main() {
  activeStage = 'Web bundle prerequisites';
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')), 'build the Flutter Web release before this acceptance');
  activeStage = 'isolated SSHD prerequisites';
  assertThat(fs.existsSync(SSHD) && fs.existsSync(SSH_KEYGEN), 'OpenSSH server tools are required');
  const requiredAuthFixtureTools = [
    'getent', 'useradd', 'userdel', 'groupdel', 'openssl', 'chpasswd', 'passwd',
  ].filter((name) => !executableOnPath(name));
  assertThat(requiredAuthFixtureTools.length === 0 &&
    fs.existsSync('/bin/sleep') && (fs.statSync('/bin/sleep').mode & 0o111) !== 0,
  'run-scoped OpenSSH userauth gate account tools are required');
  assertThat(process.getuid?.() === 0, 'the isolated SSHD fixture requires a root test process');
  assertThat(fs.existsSync('/run/sshd') && fs.statSync('/run/sshd').isDirectory(),
    'the existing OpenSSH privilege-separation directory is required');
  const address = localEth0Address();
  assertThat(address, 'an eth0 IPv4 fixture address is required');

  activeStage = 'isolated Rust server build';
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], { timeout: 240000 });
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated server binary was not built');

  activeStage = 'temporary fixture setup';
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-knownhost-web-'));
  fs.chmodSync(tempRoot, 0o700);
  let serverLog;
  let serverProcess;
  let sshdProcess;
  let conflictSshdProcess;
  let sameProfileSshdProcess;
  let sameProfilePage;
  let sameProfileAuthGate;
  let sameProfileAuthAccount;
  let browser;
  let browserServer;
  let browserServerCleanupPromise;
  let ownerContext;
  let secondContext;
  let bootstrapToken;
  let terminationSignal;
  const relayTraffic = {
    connections: 0,
    sentFrames: 0,
    receivedFrames: 0,
    sentBytes: 0,
    receivedBytes: 0,
    closes: 0,
    errors: 0,
  };
  const relayTrafficSnapshot = () => ({ ...relayTraffic });
  const relayTrafficDelta = (baseline) => Object.fromEntries(
    Object.keys(relayTraffic).map((key) => [key, relayTraffic[key] - baseline[key]]),
  );
  const stopTestBrowserServer = () => {
    if (!browserServer) return Promise.resolve();
    browserServerCleanupPromise ||= stopOwnedBrowserServer(browserServer);
    return browserServerCleanupPromise;
  };
  const pollAuthenticationBoundary = async ({
    page,
    expectedHostName,
    baseline,
    relayBaseline,
    sshdBaseline,
  }) => {
    const deadline = Date.now() + SSH_OUTCOME_TIMEOUT_MS;
    let diagnostics;
    let lastClassification;
    while (Date.now() < deadline) {
      diagnostics = await observeSshUi(page, expectedHostName);
      const classification = classifySshUi(diagnostics, baseline);
      lastClassification = classification || lastClassification;
      // A stale page-level authentication banner can keep the ordinary UI
      // classifier at failed_unclassified even after the transport reaches
      // sshd. Check the independent server and Relay evidence before exiting.
      if (classification && classification !== 'failed_unclassified') {
        return { classification, diagnostics };
      }

      const sshdAfter = readSshdLogSummary(tempRoot);
      const relay = relayTrafficDelta(relayBaseline);
      const reached = reachedAuthenticationBoundary(
        'failed_unclassified',
        diagnostics,
        sshdBaseline,
        sshdAfter,
        relay,
      );
      if (reached) {
        return {
          classification: 'authentication_rejected',
          diagnostics,
          authenticationEvidence: {
            reached: true,
            invalidUserDelta: sshdAfter.invalidUsers - sshdBaseline.invalidUsers,
            relay,
          },
        };
      }
      await page.waitForTimeout(100);
    }
    return { classification: lastClassification || 'timeout', diagnostics };
  };
  const frameLength = (payload) => typeof payload === 'string'
    ? Buffer.byteLength(payload)
    : Buffer.isBuffer(payload) ? payload.length : 0;
  const handleTermination = (signal) => {
    if (terminationSignal) return;
    terminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    for (const child of [sshdProcess, conflictSshdProcess, sameProfileSshdProcess, serverProcess]) {
      if (!child || !Number.isInteger(child.pid)) continue;
      try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
    }
    void stopTestBrowserServer();
  };
  const onInterrupt = () => handleTermination('SIGINT');
  const onTerminate = () => handleTermination('SIGTERM');
  process.once('SIGINT', onInterrupt);
  process.once('SIGTERM', onTerminate);
  try {
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { mode: 0o700 });
    serverLog = fs.openSync(path.join(tempRoot, 'server.log'), 'a', 0o600);
    const serverPort = await unusedPort('127.0.0.1');
    const sshPort = await unusedPort(address);
    let conflictPort = await unusedPort(address);
    while (conflictPort === sshPort) conflictPort = await unusedPort(address);
    const sameProfileAuthPort = await unusedPort(address);
    assertThat(new Set([sshPort, conflictPort, sameProfileAuthPort]).size === 3,
      'isolated SSH fixture ports were not unique');
    const baseUrl = `http://127.0.0.1:${serverPort}`;
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${serverPort}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'true',
      ATERMIUS_RELAY_ALLOW_CIDRS: `${address}/32`,
      ATERMIUS_RELAY_ALLOW_PORTS: `${sshPort},${conflictPort},${sameProfileAuthPort}`,
      RUST_LOG: process.env.RUST_LOG || 'warn',
    };
    activeStage = 'temporary SSH host-key fixture';
    const initialHostKey = path.join(tempRoot, 'fixture_host_ed25519');
    runChecked(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', initialHostKey], { timeout: 30000 });
    fs.chmodSync(initialHostKey, 0o600);
    const initialFingerprint = readKeyFingerprint(initialHostKey);
    let sshdConfig = createSshdConfig(tempRoot, address, sshPort, initialHostKey);

    activeStage = 'same-profile userauth gate and account fixture validation';
    const sameProfileHostKey = path.join(tempRoot, 'same_profile_auth_host_ed25519');
    runChecked(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', sameProfileHostKey], {
      timeout: 30000,
    });
    fs.chmodSync(sameProfileHostKey, 0o600);
    const sameProfileFingerprint = readKeyFingerprint(sameProfileHostKey);
    sameProfileAuthAccount = userauthAccountFixture();
    provisionUserauthAccount(sameProfileAuthAccount);
    sameProfileAuthGate = createUserauthGate(tempRoot, sameProfileAuthAccount);
    const sameProfileSshdConfig = createSshdConfig(
      tempRoot,
      address,
      sameProfileAuthPort,
      sameProfileHostKey,
      'same_profile_userauth',
      {
        authorizedKeysCommand: {
          command: sameProfileAuthGate.commandPath,
          user: sameProfileAuthAccount.name,
          loginUser: sameProfileAuthAccount.name,
        },
        loginGraceTime: 300,
      },
    );
    const sameProfileCredentialName = `Userauth race ${RUN_ID.slice(0, 8)}`;
    const sameProfileHostName = `Userauth lock race ${RUN_ID.slice(0, 8)}`;

    activeStage = 'isolated server startup';
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
    });
    assertThat(bootstrap.status === 0, 'disposable server bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(bootstrapToken && bootstrapToken.length >= 40, 'disposable server did not issue bootstrap credentials');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT, env: serverEnv, stdio: ['ignore', serverLog, serverLog], detached: true,
    });
    await waitReady(baseUrl, serverProcess);
    sshdProcess = startSshd(sshdConfig, tempRoot);
    await waitForTcp(address, sshPort, sshdProcess);

    activeStage = 'isolated browser startup';
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) {
      launchOptions.executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
    }
    browserServer = await chromium.launchServer(launchOptions);
    browser = await chromium.connect(browserServer.wsEndpoint());
    ownerContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    secondContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    await Promise.all([ownerContext, secondContext].map((context) =>
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl })));
    await Promise.all([installFlutterLoaderProbe(ownerContext), installFlutterLoaderProbe(secondContext)]);
    const ownerPage = await ownerContext.newPage();
    const secondPage = await secondContext.newPage();
    for (const [page, profile] of [[ownerPage, 'A'], [secondPage, 'B']]) {
      const apiRequestSequences = new WeakMap();
      page.on('pageerror', (error) => {
        const message = String(error?.message || '');
        const category = /ReferenceError/i.test(message) ? 'javascript_reference'
          : /TypeError/i.test(message) ? 'javascript_type'
            : /SyntaxError/i.test(message) ? 'javascript_syntax'
              : /crypto|sodium|wasm/i.test(message) ? 'browser_crypto'
                : 'javascript_runtime';
        safeBrowserIssues.push({ profile, source: 'pageerror', category,
        });
      });
      page.on('console', (message) => {
        if (message.type() !== 'error') return;
        const text = message.text();
        const category = /ReferenceError/i.test(text) ? 'javascript_reference'
          : /TypeError/i.test(text) ? 'javascript_type'
            : /SyntaxError/i.test(text) ? 'javascript_syntax'
              : /crypto|sodium|wasm/i.test(text) ? 'browser_crypto'
                : 'console_error';
        safeBrowserIssues.push({ profile, source: 'console', category,
        });
      });
      page.on('websocket', (websocket) => {
        try {
          if (!/\/relay\/v1\/connect$/.test(new URL(websocket.url()).pathname)) return;
        } catch (_) { return; }
        relayTraffic.connections++;
        websocket.on('framesent', (payload) => {
          relayTraffic.sentFrames++;
          relayTraffic.sentBytes += frameLength(payload);
        });
        websocket.on('framereceived', (payload) => {
          relayTraffic.receivedFrames++;
          relayTraffic.receivedBytes += frameLength(payload);
        });
        websocket.on('close', () => { relayTraffic.closes++; });
        websocket.on('socketerror', () => { relayTraffic.errors++; });
      });
      page.on('request', (request) => {
        try {
          const url = new URL(request.url());
          if (!url.pathname.startsWith('/api/v1/')) return;
          apiRequestSequences.set(request, ++safeNetworkSequence);
        } catch (_) {}
      });
      page.on('response', (response) => {
        try {
          const url = new URL(response.url());
          if (!url.pathname.startsWith('/api/v1/')) return;
          const request = response.request();
          const status = {
            sequence: ++safeApiSequence,
            requestSequence: apiRequestSequences.get(request) || null,
            networkSequence: ++safeNetworkSequence,
            profile,
            method: request.method(),
            route: safeApiRoute(url.pathname),
            endpointClass: safeApiEndpointClass(url.pathname),
            status: response.status(),
            changeEventCount: null,
          };
          safeApiStatuses.push(status);
          if (safeApiStatuses.length > 2000) safeApiStatuses.shift();
          if (status.route === 'sync_changes') {
            void response.json().then((body) => {
              status.changeEventCount = Array.isArray(body?.events) ? body.events.length : null;
            }).catch(() => {});
          }
        } catch (_) {}
      });
    }
    await Promise.all([ownerPage.goto(baseUrl), secondPage.goto(baseUrl)]);
    try {
      await Promise.all([enableSemantics(ownerPage), enableSemantics(secondPage)]);
    } catch (error) {
      for (const [page, profile] of [[ownerPage, 'A'], [secondPage, 'B']]) {
        let probe;
        try {
          probe = await page.evaluate(() => ({
            flutterProbe: {
              initializerCalled: window.__e2eFlutterProbe?.initializerCalled === true,
              engineInitialized: window.__e2eFlutterProbe?.engineInitialized === true,
              runAppCompleted: window.__e2eFlutterProbe?.runAppCompleted === true,
            },
            sodiumPresent: Boolean(window.sodium),
            sodiumReadyPromisePresent: Boolean(window.sodium?.ready?.then),
            semanticsPlaceholderPresent: Boolean(document.querySelector('flt-semantics-placeholder')),
            semanticsTreePresent: Boolean(document.querySelector('flt-semantics')),
          }));
        } catch (_) {
          probe = { pageUnavailable: true };
        }
        safeStartupProbes.push({ profile, ...probe });
      }
      throw error;
    }
    await Promise.all([button(ownerPage, 'Connect securely'), button(secondPage, 'Connect securely')]);

    activeStage = 'owner account bootstrap';
    await fill(ownerPage, 'Server URL', baseUrl);
    await click(ownerPage, 'Connect securely');
    await fill(ownerPage, 'Owner email', EMAIL);
    await fill(ownerPage, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(ownerPage, 'Confirm master password', MASTER_PASSWORD);
    await fill(ownerPage, 'One-time bootstrap token', bootstrapToken);
    await fill(ownerPage, 'Device name', 'KnownHost Web profile A');
    await fill(ownerPage, 'First Vault', 'KnownHost sync fixture');
    await click(ownerPage, 'Create owner account');
    bootstrapToken = undefined;
    await waitWorkspace(ownerPage);

    activeStage = 'second-device enrollment';
    await fill(secondPage, 'Server URL', baseUrl);
    await click(secondPage, 'Connect securely');
    await field(secondPage, 'Email or username');
    await enrollSecondDevice(ownerPage, secondPage);

    activeStage = 'encrypted SSH host fixture';
    const baselineFixture = await addSshHostAndCredential(ownerPage, address, sshPort);
    await syncNow(ownerPage);

    activeStage = 'explicit host-key approval';
    await click(ownerPage, 'Hosts');
    const hostName = baselineFixture.hostName;
    const ownerCard = ownerPage.getByRole('group', { name: hostName, exact: false }).first();
    await ownerCard.waitFor({ state: 'visible', timeout: 15000 });
    const initialBaseline = await observeSshUi(ownerPage, hostName);
    await ownerCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const initialOutcomeResult = await pollSshOutcome(ownerPage, 20000, {
      expectedHostName: hostName,
      baseline: initialBaseline,
    });
    const initialOutcome = initialOutcomeResult.classification;
    activeStage = `first connection result (${initialOutcome})`;
    assertThat(initialOutcome === 'approval_prompt',
      'first device did not request explicit approval for the unseen SSH key');
    activeStage = 'approval confirmation button';
    const approvedBaseline = await observeSshUi(ownerPage, hostName);
    const approvedRelayBaseline = relayTrafficSnapshot();
    const approvedSshdBaseline = readSshdLogSummary(tempRoot);
    const approvalApiSequence = safeApiSequence;
    await click(ownerPage, 'Trust after verification');
    await waitForSafeApiResponse('A', 'sync_push', approvalApiSequence);
    activeStage = 'approved-key connection verification result';
    const approvedOutcomeResult = await pollSshOutcome(
      ownerPage,
      SSH_OUTCOME_TIMEOUT_MS,
      { ignoreApprovalPrompt: true, expectedHostName: hostName, baseline: approvedBaseline },
    );
    let approvedOutcome = approvedOutcomeResult.classification;
    const approvedRelayDelta = relayTrafficDelta(approvedRelayBaseline);
    const approvedSshdAfter = readSshdLogSummary(tempRoot);
    const approvedReachedAuthentication = reachedAuthenticationBoundary(
      approvedOutcome,
      approvedOutcomeResult.diagnostics,
      approvedSshdBaseline,
      approvedSshdAfter,
      approvedRelayDelta,
    );
    if (approvedReachedAuthentication) approvedOutcome = 'authentication_rejected';
    const safeOutcomes = new Set([
      'approval_prompt',
      'changed_key_rejected',
      'authentication_rejected',
      'relay_error',
      'ssh_timeout',
      'ssh_handshake_failure',
      'ssh_transport_closed',
      'host_key_error',
      'connected',
      'timeout',
      'failed_unclassified',
    ]);
    if (approvedOutcome !== 'authentication_rejected') {
      console.log('safe approved-key verification evidence', JSON.stringify({
        outcome: safeOutcomes.has(approvedOutcome) ? approvedOutcome : 'unknown',
        ui: approvedOutcomeResult.diagnostics,
        sshd: approvedSshdAfter,
        sshdInvalidUserDelta: approvedSshdAfter.invalidUsers - approvedSshdBaseline.invalidUsers,
        relay: approvedRelayDelta,
      }));
    }
    activeStage = `approved-key connection verification result (${safeOutcomes.has(approvedOutcome) ? approvedOutcome : 'unknown'})`;
    assertThat(approvedOutcome === 'authentication_rejected',
      'approved key did not pass verification before SSH authentication');
    activeStage = 'explicit sync trigger for profile A approval';
    await syncNow(ownerPage, { force: true });
    activeStage = 'profile A sync_push response after approval';
    await waitForSafeApiResponse('A', 'sync_push', approvalApiSequence);
    activeStage = 'profile A sync completion after push response';
    await syncNow(ownerPage);
    activeStage = 'open profile A trust panel';
    await click(ownerPage, 'Settings');
    activeStage = 'profile A trust panel heading';
    await waitForText(ownerPage, 'SSH host-key trust');
    activeStage = 'scroll profile A Settings viewport to trusted row';
    const endpoint = `${address}:${sshPort}`;
    const ownerKnownHostSignals = await scrollSettingsToTrustedRow(ownerPage, endpoint);
    assertThat(ownerKnownHostSignals.trustedRowSemanticsFound,
      'profile A trusted host-key row semantics did not appear after bounded scroll');
    activeStage = 'profile A trusted record row semantics';

    activeStage = 'explicit sync trigger for profile B';
    const profileBSyncApiSequence = safeApiSequence;
    await syncNow(secondPage, { force: true });
    activeStage = 'profile B sync_changes response after explicit sync';
    await waitForSafeApiResponse('B', 'sync_changes', profileBSyncApiSequence);
    activeStage = 'profile B sync completion after changes response';
    await syncNow(secondPage);
    activeStage = 'open profile B trust panel';
    await click(secondPage, 'Settings');
    activeStage = 'profile B trust panel heading';
    await waitForText(secondPage, 'SSH host-key trust');
    activeStage = 'scroll profile B Settings viewport to trusted row';
    const secondKnownHostSignals = await scrollSettingsToTrustedRow(secondPage, endpoint);
    assertThat(secondKnownHostSignals.trustedRowSemanticsFound,
      'profile B trusted host-key row semantics did not appear after bounded scroll');
    activeStage = 'profile B trusted record row semantics';

    activeStage = 'synced key accepted by second device';
    await click(secondPage, 'Hosts');
    const secondCard = secondPage.getByRole('group', { name: hostName, exact: false }).first();
    await secondCard.waitFor({ state: 'visible', timeout: 20000 });
    const originalKeyBaseline = await observeSshUi(secondPage, hostName);
    const originalKeyRelayBaseline = relayTrafficSnapshot();
    const originalKeySshdBaseline = readSshdLogSummary(tempRoot);
    await secondCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const originalKeyOutcomeResult = await pollAuthenticationBoundary({
      page: secondPage,
      expectedHostName: hostName,
      baseline: originalKeyBaseline,
      relayBaseline: originalKeyRelayBaseline,
      sshdBaseline: originalKeySshdBaseline,
    });
    const originalKeyOutcome = originalKeyOutcomeResult.classification;
    assertThat(originalKeyOutcome === 'authentication_rejected',
      'second device did not proceed past synced host-key verification');

    activeStage = 'create an initially untrusted conflict endpoint';
    const conflictHostName = 'Concurrent trust check ' + RUN_ID.slice(0, 6);
    await addSshHostAndCredential(
      ownerPage,
      address,
      conflictPort,
      { credential: baselineFixture.credential, hostName: conflictHostName },
    );
    activeStage = 'push the newly added conflict Host from profile A';
    const conflictHostPushSequence = safeApiSequence;
    await syncNow(ownerPage, { force: true });
    await waitForSafeApiResponse('A', 'sync_push', conflictHostPushSequence);
    await syncNow(ownerPage);
    const conflictEndpoint = address + ':' + conflictPort;

    const conflictHostKeyA = path.join(tempRoot, 'fixture_conflict_a_ed25519');
    runChecked(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', conflictHostKeyA], { timeout: 30000 });
    fs.chmodSync(conflictHostKeyA, 0o600);
    const conflictFingerprintA = readKeyFingerprint(conflictHostKeyA);
    const conflictHostKeyB = path.join(tempRoot, 'fixture_conflict_b_ed25519');
    runChecked(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', conflictHostKeyB], { timeout: 30000 });
    fs.chmodSync(conflictHostKeyB, 0o600);
    const conflictFingerprintB = readKeyFingerprint(conflictHostKeyB);
    assertThat(conflictFingerprintA !== conflictFingerprintB &&
      conflictFingerprintA !== initialFingerprint &&
      conflictFingerprintB !== initialFingerprint,
    'conflict fixture host keys were not three distinct fingerprints');

    let conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyA,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);

    activeStage = 'force profile B pull for conflict Host';
    await click(secondPage, 'Hosts');
    const conflictHostPullSequence = safeApiSequence;
    await syncNow(secondPage, { force: true });
    activeStage = 'verify profile B changes response for conflict Host';
    await waitForSafeApiResponse('B', 'sync_changes', conflictHostPullSequence);
    activeStage = 'settle profile B sync projection for conflict Host';
    await syncNow(secondPage);
    activeStage = 'wait for profile B conflict Host card';
    const conflictSecondCard = secondPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();
    try {
      await conflictSecondCard.waitFor({ state: 'visible', timeout: 20000 });
    } catch (_) {
      const profileBHostEvidence = await secondPage.locator('flt-semantics').evaluateAll((nodes, expected) => {
        const labels = nodes.map((node) =>
          `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
            .replace(/\s+/g, ' ').trim());
        const hostLabels = labels.filter((label) => label.startsWith('Host:'));
        return {
          expectedHostNameInSemantics: labels.some((label) => label.includes(expected)),
          visibleHostCardCount: hostLabels.length,
          expectedHostCardCount: hostLabels.filter((label) => label.includes(expected)).length,
        };
      }, conflictHostName).catch(() => ({ semanticsUnavailable: true }));
      const profileBChanges = safeApiStatuses.filter((item) =>
        item.profile === 'B' && item.route === 'sync_changes').slice(-3);
      console.log('KnownHost profile B Host sync evidence', JSON.stringify({
        ...profileBHostEvidence,
        recentChanges: profileBChanges.map(({ sequence, status, changeEventCount }) => ({
          sequence, status, changeEventCount: changeEventCount ?? null,
        })),
      }));
      throw new Error('Profile B did not render the synchronized conflict Host');
    }

    activeStage = 'offline baseline before profile A and B queue first trust';
    const offlineApprovalServerBaseline = readVaultSyncTotals(dataDir);
    const offlineApprovalApiSequence = safeApiSequence;
    const offlineRelayBaseline = relayTrafficSnapshot();
    const offlineSshdBaseline = readSshdLogSummary(tempRoot);
    const offlineGateA = await blockVaultSyncReads(ownerPage);
    const offlineGateB = await blockVaultSyncReads(secondPage);
    const conflictOwnerCard = ownerPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();

    activeStage = 'profile A explicit queue-only first-key confirmation while sync reads fail';
    const conflictOwnerBaseline = await observeSshUi(ownerPage, conflictHostName);
    await conflictOwnerCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const conflictOwnerPrompt = await pollSshOutcome(ownerPage, 20000, {
      expectedHostName: conflictHostName,
      baseline: conflictOwnerBaseline,
    });
    assertThat(conflictOwnerPrompt.classification === 'approval_prompt',
      'profile A did not request approval for the first unknown conflict key');
    await waitForText(ownerPage, 'Vault sync is unreachable');
    await click(ownerPage, 'Queue approval and stop');
    await waitForText(ownerPage,
      'SSH 已停止：首次主机密钥审批已加密排队，Vault 同步确认后请重新连接');
    await click(ownerPage, 'Settings');
    await waitForText(ownerPage, 'QUEUED — NOT TRUSTED');
    await click(ownerPage, 'Hosts');

    activeStage = 'rotate conflict endpoint to key B while profile A remains offline';
    await stopGroup(conflictSshdProcess);
    conflictSshdProcess = null;
    conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyB,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);

    activeStage = 'profile B explicit queue-only first-key confirmation while sync reads fail';
    const conflictSecondBaseline = await observeSshUi(secondPage, conflictHostName);
    await conflictSecondCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const conflictSecondPrompt = await pollSshOutcome(secondPage, 20000, {
      expectedHostName: conflictHostName,
      baseline: conflictSecondBaseline,
    });
    assertThat(conflictSecondPrompt.classification === 'approval_prompt',
      'profile B did not see the independently rotated SSH host key as unknown');
    await waitForText(secondPage, 'Vault sync is unreachable');
    try {
      await click(secondPage, 'Queue approval and stop');
      await waitForText(secondPage,
        'SSH 已停止：首次主机密钥审批已加密排队，Vault 同步确认后请重新连接');
      await click(secondPage, 'Settings');
      await waitForText(secondPage, 'QUEUED — NOT TRUSTED');
      await click(secondPage, 'Hosts');

      assertThat(offlineGateA.aborted > 0 && offlineGateB.aborted > 0,
        'both browser profiles did not exercise the transport-outage classifier');
      const offlineQueuedServerTotals = readVaultSyncTotals(dataDir);
      for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
        assertThat(offlineQueuedServerTotals[field] === offlineApprovalServerBaseline[field],
          `offline local approval changed server ${field} before reconnect`);
      }
      assertThat(!safeApiStatuses.some((item) =>
        item.sequence > offlineApprovalApiSequence && item.route === 'sync_push'),
      'a KnownHost approval was pushed while each profile was offline');
      const offlineRelayDelta = relayTrafficDelta(offlineRelayBaseline);
      const offlineSshdAfter = readSshdLogSummary(tempRoot);
      assertThat(offlineRelayDelta.connections > 0 && offlineRelayDelta.sentFrames > 0,
        'blocking Vault reads also blocked SSH Relay traffic');
      assertThat(offlineSshdAfter.invalidUsers === offlineSshdBaseline.invalidUsers,
        'an SSH authentication attempt continued from an offline queued approval');

      activeStage = 'unblock both profiles and commit exactly two encrypted first-key approvals';
      const reconnectSequence = safeApiSequence;
      await Promise.all([offlineGateA.remove(), offlineGateB.remove()]);
      await Promise.all([
        waitForSafeApiResponse('A', 'sync_push', reconnectSequence),
        waitForSafeApiResponse('B', 'sync_push', reconnectSequence),
      ]);
      const afterOfflineApprovalCommits = readVaultSyncTotals(dataDir);
      assertVaultCommitCount(
        offlineApprovalServerBaseline,
        afterOfflineApprovalCommits,
        2,
        'two independently queued KnownHost creates after reconnect',
      );
    } finally {
      await Promise.all([offlineGateA.remove(), offlineGateB.remove()]);
    }

    activeStage = 'both offline branches pulled by both devices and classified as conflict';
    const conflictPullSequence = safeApiSequence;
    await Promise.all([
      syncNow(ownerPage, { force: true }),
      syncNow(secondPage, { force: true }),
    ]);
    await Promise.all([
      waitForSafeApiResponse('A', 'sync_changes', conflictPullSequence),
      waitForSafeApiResponse('B', 'sync_changes', conflictPullSequence),
    ]);
    await Promise.all([syncNow(ownerPage), syncNow(secondPage)]);
    await Promise.all([click(ownerPage, 'Settings'), click(secondPage, 'Settings')]);
    await Promise.all([
      waitForKnownHostState(ownerPage, 'conflict', 1),
      waitForKnownHostState(secondPage, 'conflict', 1),
    ]);
    const ownerConflictSignals = await scrollSettingsToTrustedRow(ownerPage, conflictEndpoint);
    const secondConflictSignals = await scrollSettingsToTrustedRow(secondPage, conflictEndpoint);
    assertThat(ownerConflictSignals.conflictLabelPresent && secondConflictSignals.conflictLabelPresent,
      'concurrent approvals did not appear as an explicit conflict on both devices');

    activeStage = 'both conflicting fingerprints rejected by profile A';
    await click(ownerPage, 'Hosts');
    const conflictRejectB = ownerPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();
    const keyBRejectBaseline = await observeSshUi(ownerPage, conflictHostName);
    const keyBRejectRelayBaseline = relayTrafficSnapshot();
    const keyBRejectSshdBaseline = readSshdLogSummary(tempRoot);
    await conflictRejectB.getByRole('button', { name: 'Connect', exact: true }).click();
    const keyBRejectResult = await pollSshOutcome(ownerPage, SSH_OUTCOME_TIMEOUT_MS, {
      expectedHostName: conflictHostName,
      baseline: keyBRejectBaseline,
    });
    let keyBReject = keyBRejectResult.classification;
    const keyBRejectSshdAfter = readSshdLogSummary(tempRoot);
    const keyBRejectRelayDelta = relayTrafficDelta(keyBRejectRelayBaseline);
    if (reachedHostKeyRejectionBoundary(
      keyBReject,
      keyBRejectResult.diagnostics,
      keyBRejectSshdBaseline,
      keyBRejectSshdAfter,
      keyBRejectRelayDelta,
    )) keyBReject = 'changed_key_rejected';
    if (keyBReject !== 'changed_key_rejected') {
      console.log('safe conflicting-key B rejection evidence', JSON.stringify({
        outcome: keyBReject,
        ui: keyBRejectResult.diagnostics,
        sshdDelta: {
          invalidUsers: keyBRejectSshdAfter.invalidUsers - keyBRejectSshdBaseline.invalidUsers,
          preAuthClosures: keyBRejectSshdAfter.preAuthClosures - keyBRejectSshdBaseline.preAuthClosures,
          keyExchangeFailures: keyBRejectSshdAfter.keyExchangeFailures - keyBRejectSshdBaseline.keyExchangeFailures,
        },
        relay: keyBRejectRelayDelta,
      }));
    }
    assertThat(keyBReject === 'changed_key_rejected',
      'profile A did not fail closed for conflict fingerprint B');

    activeStage = 'rotate conflict endpoint to key A and reject it on profile B';
    await stopGroup(conflictSshdProcess);
    conflictSshdProcess = null;
    conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyA,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);
    await click(secondPage, 'Hosts');
    const conflictRejectA = secondPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();
    const keyARejectBaseline = await observeSshUi(secondPage, conflictHostName);
    const keyARejectRelayBaseline = relayTrafficSnapshot();
    const keyARejectSshdBaseline = readSshdLogSummary(tempRoot);
    await conflictRejectA.getByRole('button', { name: 'Connect', exact: true }).click();
    const keyARejectResult = await pollSshOutcome(secondPage, SSH_OUTCOME_TIMEOUT_MS, {
      expectedHostName: conflictHostName,
      baseline: keyARejectBaseline,
    });
    let keyAReject = keyARejectResult.classification;
    const keyARejectSshdAfter = readSshdLogSummary(tempRoot);
    const keyARejectRelayDelta = relayTrafficDelta(keyARejectRelayBaseline);
    if (reachedHostKeyRejectionBoundary(
      keyAReject,
      keyARejectResult.diagnostics,
      keyARejectSshdBaseline,
      keyARejectSshdAfter,
      keyARejectRelayDelta,
    )) keyAReject = 'changed_key_rejected';
    if (keyAReject !== 'changed_key_rejected') {
      console.log('safe conflicting-key A rejection evidence', JSON.stringify({
        outcome: keyAReject,
        ui: keyARejectResult.diagnostics,
        sshdDelta: {
          invalidUsers: keyARejectSshdAfter.invalidUsers - keyARejectSshdBaseline.invalidUsers,
          preAuthClosures: keyARejectSshdAfter.preAuthClosures - keyARejectSshdBaseline.preAuthClosures,
          keyExchangeFailures: keyARejectSshdAfter.keyExchangeFailures - keyARejectSshdBaseline.keyExchangeFailures,
        },
        relay: keyARejectRelayDelta,
      }));
    }
    assertThat(keyAReject === 'changed_key_rejected',
      'profile B did not fail closed for conflict fingerprint A');

    activeStage = 'profile A revokes the unselected conflict fingerprint';
    await click(ownerPage, 'Settings');
    await waitForText(ownerPage, 'SSH host-key trust');
    const conflictResolutionBefore = readVaultSyncTotals(dataDir);
    const revokePushSequence = safeApiSequence;
    await revokeKnownHostFingerprint(
      ownerPage,
      tempRoot,
      conflictEndpoint,
      conflictFingerprintA,
      1,
    );
    activeStage = 'manual sync after conflict-key revocation';
    await syncNow(ownerPage, { force: true });
    activeStage = 'wait for conflict-key revocation push';
    try {
      await waitForSafeApiResponse('A', 'sync_push', revokePushSequence);
    } catch (error) {
      console.log('KnownHost revoke sync state', JSON.stringify({
        syncButtons: await safeSyncButtonLabels(ownerPage),
        trustPanel: await safeTrustPanelState(ownerPage),
        apiTail: safeApiStatuses.slice(-10).map(({ profile, method, route, status }) =>
          ({ profile, method, route, status })),
      }));
      throw error;
    }
    activeStage = 'verify exactly-once conflict-key revocation commit';
    await syncNow(ownerPage);
    const conflictResolutionAfter = readVaultSyncTotals(dataDir);
    console.log('KnownHost conflict-revoke commit deltas', JSON.stringify(
      Object.fromEntries(['commit_seq', 'versions', 'events', 'receipts', 'heads']
        .map((field) => [field, conflictResolutionAfter[field] - conflictResolutionBefore[field]])),
    ));
    assertOneVaultHeadRevision(conflictResolutionBefore, conflictResolutionAfter,
      'conflict-key revocation');
    activeStage = 'wait for local revoked row after revocation sync';
    await waitForKnownHostState(ownerPage, 'revoked', 1);
    activeStage = 'wait for local conflict to clear after revocation sync';
    await waitForKnownHostState(ownerPage, 'conflict', 0);

    activeStage = 'profile B pulls the encrypted host-key revocation';
    await click(secondPage, 'Hosts');
    const revokePullSequence = safeApiSequence;
    await syncNow(secondPage, { force: true });
    await waitForSafeApiResponse('B', 'sync_changes', revokePullSequence);
    await syncNow(secondPage);
    const afterConflictRevokePull = readVaultSyncTotals(dataDir);
    for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
      assertThat(afterConflictRevokePull[field] === conflictResolutionAfter[field],
        `profile B conflict-revocation pull changed server ${field} totals`);
    }
    await click(secondPage, 'Settings');
    await waitForText(secondPage, 'SSH host-key trust');
    await Promise.all([
      waitForKnownHostState(secondPage, 'revoked', 1),
      waitForKnownHostState(secondPage, 'conflict', 0),
    ]);

    activeStage = 'retained key B passes verification on both devices';
    await stopGroup(conflictSshdProcess);
    conflictSshdProcess = null;
    conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyB,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);
    for (const [profile, page] of [['A', ownerPage], ['B', secondPage]]) {
      await click(page, 'Hosts');
      const retainedCard = page.getByRole('group', {
        name: conflictHostName,
        exact: false,
      }).first();
      const retainedBaseline = await observeSshUi(page, conflictHostName);
      const retainedRelayBaseline = relayTrafficSnapshot();
      const retainedSshdBaseline = readSshdLogSummary(tempRoot);
      await retainedCard.getByRole('button', { name: 'Connect', exact: true }).click();
      const retainedOutcome = await pollAuthenticationBoundary({
        page,
        expectedHostName: conflictHostName,
        baseline: retainedBaseline,
        relayBaseline: retainedRelayBaseline,
        sshdBaseline: retainedSshdBaseline,
      });
      if (retainedOutcome.classification !== 'authentication_rejected') {
        console.log('safe retained-key verification evidence', JSON.stringify({
          profile,
          outcome: retainedOutcome.classification,
          ui: retainedOutcome.diagnostics,
          authentication: retainedOutcome.authenticationEvidence,
        }));
      }
      assertThat(retainedOutcome.classification === 'authentication_rejected',
        `profile ${profile} did not trust the explicitly retained key after revoke sync`);
    }

    activeStage = 'revoke the retained key so the previously revoked key can be reviewed again';
    await click(ownerPage, 'Settings');
    await waitForText(ownerPage, 'SSH host-key trust');
    const retainedKeyRevokeBefore = readVaultSyncTotals(dataDir);
    const retainedKeyRevokeSequence = safeApiSequence;
    await revokeKnownHostFingerprint(
      ownerPage,
      tempRoot,
      conflictEndpoint,
      conflictFingerprintB,
      2,
    );
    activeStage = 'manual sync after retained-key revocation';
    await syncNow(ownerPage, { force: true });
    activeStage = 'wait for retained-key revocation push';
    await waitForSafeApiResponse('A', 'sync_push', retainedKeyRevokeSequence);
    activeStage = 'verify exactly-once retained-key revocation commit';
    await syncNow(ownerPage);
    const retainedKeyRevokeAfter = readVaultSyncTotals(dataDir);
    assertOneVaultHeadRevision(retainedKeyRevokeBefore, retainedKeyRevokeAfter,
      'retained-key revocation');

    activeStage = 'profile B pulls retained-key revocation';
    const finalRevokePullSequence = safeApiSequence;
    await syncNow(secondPage, { force: true });
    await waitForSafeApiResponse('B', 'sync_changes', finalRevokePullSequence);
    await syncNow(secondPage);
    const afterFinalRevokePull = readVaultSyncTotals(dataDir);
    for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
      assertThat(afterFinalRevokePull[field] === retainedKeyRevokeAfter[field],
        `profile B pull changed server ${field} totals`);
    }

    activeStage = 'show the exact previously revoked fingerprint before reapproval';
    await stopGroup(conflictSshdProcess);
    conflictSshdProcess = null;
    conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyA,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);
    await click(ownerPage, 'Hosts');
    const reapprovalCard = ownerPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();
    const reapprovalBaseline = await observeSshUi(ownerPage, conflictHostName);
    await reapprovalCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const reapprovalPrompt = await pollSshOutcome(ownerPage, 20000, {
      expectedHostName: conflictHostName,
      baseline: reapprovalBaseline,
    });
    assertThat(reapprovalPrompt.classification === 'approval_prompt',
      'profile A did not request explicit review of the revoked fingerprint');
    await waitForText(ownerPage,
      'This exact fingerprint was revoked before. Reapproval creates a new encrypted trust record for this Vault and syncs it to its devices. Verify it out of band before continuing.');

    activeStage = 'profile A explicitly reapproves the reviewed revoked fingerprint';
    const reapprovalBefore = readVaultSyncTotals(dataDir);
    const reapprovalPushSequence = safeApiSequence;
    const reapprovalRelayBaseline = relayTrafficSnapshot();
    const reapprovalSshdBaseline = readSshdLogSummary(tempRoot);
    await click(ownerPage, 'Trust after verification');
    const reapprovalOutcomeResult = await pollSshOutcome(ownerPage, SSH_OUTCOME_TIMEOUT_MS, {
      ignoreApprovalPrompt: true,
      expectedHostName: conflictHostName,
      baseline: reapprovalBaseline,
    });
    let reapprovalOutcome = reapprovalOutcomeResult.classification;
    const reapprovalRelayDelta = relayTrafficDelta(reapprovalRelayBaseline);
    const reapprovalSshdAfter = readSshdLogSummary(tempRoot);
    const reapprovalReachedAuthentication = reachedAuthenticationBoundary(
      reapprovalOutcome,
      reapprovalOutcomeResult.diagnostics,
      reapprovalSshdBaseline,
      reapprovalSshdAfter,
      reapprovalRelayDelta,
    );
    if (reapprovalReachedAuthentication) reapprovalOutcome = 'authentication_rejected';
    if (reapprovalOutcome !== 'authentication_rejected') {
      console.log('safe revoked-key reapproval evidence', JSON.stringify({
        outcome: safeOutcomes.has(reapprovalOutcome)
          ? reapprovalOutcome
          : 'unknown',
        ui: reapprovalOutcomeResult.diagnostics,
        sshd: reapprovalSshdAfter,
        sshdInvalidUserDelta: reapprovalSshdAfter.invalidUsers - reapprovalSshdBaseline.invalidUsers,
        relay: reapprovalRelayDelta,
        vaultTotals: { before: reapprovalBefore, after: readVaultSyncTotals(dataDir) },
        apiTail: safeApiStatuses.slice(-12).map(({ profile, method, route, status }) =>
          ({ profile, method, route, status })),
      }));
    }
    assertThat(reapprovalOutcome === 'authentication_rejected',
      'profile A did not verify the explicitly reapproved key before SSH authentication failed');
    const reapprovalPushResponse = await waitForSafeApiResponse(
      'A',
      'sync_push',
      reapprovalPushSequence,
    );
    const reapprovalAfter = readVaultSyncTotals(dataDir);
    assertOneVaultCommit(reapprovalBefore, reapprovalAfter,
      'explicit KnownHost reapproval');

    activeStage = 'profile B starts a post-commit explicit reapproval pull';
    await syncNow(secondPage, { force: true });
    activeStage = 'profile B receives post-commit explicit reapproval Changes';
    const reapprovalChangesResponse = await waitForProfileChangesEvent(
      'B',
      reapprovalPushResponse.networkSequence,
      1,
    );
    activeStage = 'profile B completes explicit reapproval synchronization';
    await syncNow(secondPage);
    const afterReapprovalPull = readVaultSyncTotals(dataDir);
    console.log('safe profile B explicit reapproval pull evidence', JSON.stringify({
      status: reapprovalChangesResponse.status,
      changeEventCount: reapprovalChangesResponse.changeEventCount,
      requestSequence: reapprovalChangesResponse.requestSequence,
      networkSequence: reapprovalChangesResponse.networkSequence,
      serverTotalsUnchanged: ['commit_seq', 'versions', 'events', 'receipts', 'heads'].every(
        (field) => afterReapprovalPull[field] === reapprovalAfter[field]),
    }));
    for (const field of ['commit_seq', 'versions', 'events', 'receipts', 'heads']) {
      assertThat(afterReapprovalPull[field] === reapprovalAfter[field],
        `profile B pull changed server ${field} totals`);
    }
    activeStage = 'profile B opens the Host list after explicit reapproval';
    await click(secondPage, 'Hosts');
    const reapprovedOnSecondCard = secondPage.getByRole('group', {
      name: conflictHostName,
      exact: false,
    }).first();
    const reapprovedOnSecondBaseline = await observeSshUi(secondPage, conflictHostName);
    const reapprovedOnSecondRelayBaseline = relayTrafficSnapshot();
    const reapprovedOnSecondSshdBaseline = readSshdLogSummary(tempRoot);
    activeStage = 'profile B verifies the explicitly reapproved SSH fingerprint';
    await reapprovedOnSecondCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const reapprovedOnSecondOutcome = await pollAuthenticationBoundary({
      page: secondPage,
      expectedHostName: conflictHostName,
      baseline: reapprovedOnSecondBaseline,
      relayBaseline: reapprovedOnSecondRelayBaseline,
      sshdBaseline: reapprovedOnSecondSshdBaseline,
    });
    console.log('safe profile B explicit reapproval SSH evidence', JSON.stringify({
      outcome: safeOutcomes.has(reapprovedOnSecondOutcome.classification)
        ? reapprovedOnSecondOutcome.classification
        : 'unknown',
      ui: reapprovedOnSecondOutcome.diagnostics,
      authentication: reapprovedOnSecondOutcome.authenticationEvidence,
      changesEventCount: reapprovalChangesResponse.changeEventCount,
      apiTail: safeApiStatuses.slice(-12).map(({
        sequence,
        requestSequence,
        networkSequence,
        profile,
        method,
        route,
        status,
        changeEventCount,
      }) => ({ sequence, requestSequence, networkSequence, profile, method, route, status, changeEventCount })),
    }));
    assertThat(reapprovedOnSecondOutcome.classification === 'authentication_rejected',
      'profile B did not trust the reapproved fingerprint after syncing its encrypted record');

    activeStage = 'the other revoked key remains rejected after explicit reapproval';
    await stopGroup(conflictSshdProcess);
    conflictSshdProcess = null;
    conflictSshdConfig = createSshdConfig(
      tempRoot,
      address,
      conflictPort,
      conflictHostKeyB,
      'conflict',
    );
    conflictSshdProcess = startSshd(conflictSshdConfig, tempRoot);
    await waitForTcp(address, conflictPort, conflictSshdProcess);
    await click(secondPage, 'Hosts');
    const stillRevokedBaseline = await observeSshUi(secondPage, conflictHostName);
    const stillRevokedRelayBaseline = relayTrafficSnapshot();
    const stillRevokedSshdBaseline = readSshdLogSummary(tempRoot);
    const stillRevokedApiSequence = safeApiSequence;
    await reapprovedOnSecondCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const stillRevokedOutcome = await pollSshOutcome(secondPage, SSH_OUTCOME_TIMEOUT_MS, {
      expectedHostName: conflictHostName,
      baseline: stillRevokedBaseline,
    });
    let stillRevokedClassification = stillRevokedOutcome.classification;
    const stillRevokedSshdAfter = readSshdLogSummary(tempRoot);
    const stillRevokedRelayDelta = relayTrafficDelta(stillRevokedRelayBaseline);
    if (reachedHostKeyRejectionBoundary(
      stillRevokedClassification,
      stillRevokedOutcome.diagnostics,
      stillRevokedSshdBaseline,
      stillRevokedSshdAfter,
      stillRevokedRelayDelta,
    )) stillRevokedClassification = 'changed_key_rejected';
    if (stillRevokedClassification !== 'changed_key_rejected') {
      console.log('safe other-revoked-key rejection evidence', JSON.stringify({
        outcome: stillRevokedClassification,
        ui: stillRevokedOutcome.diagnostics,
        sshdDelta: {
          invalidUsers: stillRevokedSshdAfter.invalidUsers - stillRevokedSshdBaseline.invalidUsers,
          preAuthClosures: stillRevokedSshdAfter.preAuthClosures - stillRevokedSshdBaseline.preAuthClosures,
          keyExchangeFailures: stillRevokedSshdAfter.keyExchangeFailures - stillRevokedSshdBaseline.keyExchangeFailures,
        },
        relay: stillRevokedRelayDelta,
        apiTail: safeApiStatuses.filter((item) => item.sequence > stillRevokedApiSequence)
          .slice(-8).map(({ profile, method, route, status }) =>
            ({ profile, method, route, status })),
      }));
    }
    assertThat(stillRevokedClassification === 'changed_key_rejected',
      'profile B accepted or prompted to trust the other revoked conflict fingerprint');

    activeStage = 'changed key rejection after sync';
    await stopGroup(sshdProcess);
    sshdProcess = null;
    const changedHostKey = path.join(tempRoot, 'fixture_host_changed_ed25519');
    runChecked(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedHostKey], { timeout: 30000 });
    fs.chmodSync(changedHostKey, 0o600);
    const changedFingerprint = readKeyFingerprint(changedHostKey);
    assertThat(changedFingerprint !== initialFingerprint &&
      changedFingerprint !== conflictFingerprintA &&
      changedFingerprint !== conflictFingerprintB,
    'replacement SSHD fixture reused a previously approved host fingerprint');
    sshdConfig = createSshdConfig(tempRoot, address, sshPort, changedHostKey);
    sshdProcess = startSshd(sshdConfig, tempRoot);
    await waitForTcp(address, sshPort, sshdProcess);
    await click(secondPage, 'Hosts');
    const changedKeyBaseline = await observeSshUi(secondPage, hostName);
    await secondCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const changedKeyOutcomeResult = await pollSshOutcome(secondPage, SSH_OUTCOME_TIMEOUT_MS, {
      expectedHostName: hostName,
      baseline: changedKeyBaseline,
    });
    const changedKeyOutcome = changedKeyOutcomeResult.classification;
    if (changedKeyOutcome !== 'changed_key_rejected') {
      console.log('known-host changed-key classification diagnostics', JSON.stringify({
        expected: 'changed_key_rejected',
        observed: changedKeyOutcome,
        ...changedKeyOutcomeResult.diagnostics,
      }));
    }
    assertThat(changedKeyOutcome === 'changed_key_rejected',
      'second device did not classify the replacement key as a changed-key rejection');
    await waitForText(secondPage, 'SSH 主机密钥与已保存指纹不同，连接已拒绝', 20000);
    assertThat(!(await secondPage.getByText('CONNECTED', { exact: true }).count()),
      'second device connected after the SSH host key changed');

    activeStage = 'start same-profile userauth SSHD fixture';
    sameProfileSshdProcess = startSshd(sameProfileSshdConfig, tempRoot);
    await waitForTcp(address, sameProfileAuthPort, sameProfileSshdProcess);

    activeStage = 'save isolated RSA SSH identity in the encrypted Credential';
    let sameProfilePrivateKey = sameProfileAuthGate.privateKey;
    let sameProfileCredential;
    try {
      sameProfileCredential = await addPrivateKeyCredential(ownerPage, {
        name: sameProfileCredentialName,
        username: sameProfileAuthAccount.name,
        privateKey: sameProfilePrivateKey,
      });
    } finally {
      sameProfilePrivateKey = '';
      sameProfileAuthGate.clearPrivateKey();
    }
    await addSshHostAndCredential(ownerPage, address, sameProfileAuthPort, {
      credential: sameProfileCredential,
      hostName: sameProfileHostName,
    });
    const sameProfileFixturePushSequence = safeApiSequence;
    await syncNow(ownerPage, { force: true });
    await waitForSafeApiResponse('A', 'sync_push', sameProfileFixturePushSequence);
    await syncNow(ownerPage);

    activeStage = 'same-profile tab A explicitly approves the auth-gated host key';
    const sameProfileHostCard = ownerPage.getByRole('group', {
      name: sameProfileHostName,
      exact: false,
    }).first();
    const sameProfileApprovalBaseline = await observeSshUi(ownerPage, sameProfileHostName);
    const sameProfileSshdBeforeConnect = readSshdLogSummary(tempRoot);
    await sameProfileHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const sameProfileApproval = await pollSshOutcome(ownerPage, 20000, {
      expectedHostName: sameProfileHostName,
      baseline: sameProfileApprovalBaseline,
    });
    assertThat(sameProfileApproval.classification === 'approval_prompt',
      'same-profile auth fixture did not ask for explicit host-key approval');
    const sameProfileAuthPendingBaseline = await observeSshUi(ownerPage, sameProfileHostName);
    const sameProfileTrustPushSequence = safeApiSequence;
    await click(ownerPage, 'Trust after verification');
    await sameProfileAuthGate.waitUntilEntered();
    await waitForSafeApiResponse('A', 'sync_push', sameProfileTrustPushSequence);
    await syncNow(ownerPage);

    const authHeldLocks = await readKnownHostDecisionLocks(ownerPage);
    assertThat(authHeldLocks.supported,
      'Chromium did not expose Web Locks state for same-profile arbitration');
    const heldAuthLocks = authHeldLocks.held.filter((lock) => lock.mode === 'shared');
    assertThat(heldAuthLocks.length === 1 && authHeldLocks.pending.length === 0,
      'tab A did not hold exactly one shared KnownHost authentication lock at userauth');
    const sameProfileLockName = heldAuthLocks[0].name;
    const sameProfileSshdAtGate = readSshdLogSummary(tempRoot);
    assertThat(sameProfileSshdAtGate.acceptedPublicKeys === sameProfileSshdBeforeConnect.acceptedPublicKeys &&
      sameProfileSshdAtGate.failedPublicKeys === sameProfileSshdBeforeConnect.failedPublicKeys,
    'the SSHD userauth gate returned before tab B attempted revocation');
    const sameProfileRevocationBefore = readVaultSyncTotals(dataDir);

    activeStage = 'open real same-origin second tab in the same BrowserContext';
    sameProfilePage = await openSameProfileWebTab(ownerContext, baseUrl);
    activeStage = 'verify same-profile page context';
    assertThat(sameProfilePage.context() === ownerContext,
      'the revoke tab was not created in the SSH-owning browser profile');
    activeStage = 'verify exact same-profile tab origin';
    const [ownerOrigin, revokeOrigin] = await Promise.all([
      ownerPage.evaluate(() => location.origin),
      sameProfilePage.evaluate(() => location.origin),
    ]);
    assertThat(ownerOrigin === revokeOrigin && ownerOrigin === new URL(baseUrl).origin,
      'same-profile SSH and revoke tabs did not share the exact application origin');
    activeStage = 'open KnownHost settings in same-profile revoke tab';
    await click(sameProfilePage, 'Settings');
    await waitForText(sameProfilePage, 'SSH host-key trust');
    activeStage = 'inspect same-profile trusted KnownHost record';
    await scrollSettingsToKnownHostPanel(sameProfilePage);
    const panelBeforePendingRevoke = await safeTrustPanelState(sameProfilePage);
    assertThat((panelBeforePendingRevoke.trustedStatusCount || 0) > 0,
      'same-profile revoke tab did not load the current trusted KnownHost record');
    const revokedStatusCountBefore = panelBeforePendingRevoke.revokedStatusCount || 0;
    const sameProfileRevokeApiSequence = safeApiSequence;
    await beginKnownHostFingerprintRevoke(
      sameProfilePage,
      `${address}:${sameProfileAuthPort}`,
      sameProfileFingerprint,
    );

    activeStage = 'observe pending exclusive revoke against held SSH userauth';
    const pendingLockDeadline = Date.now() + 20000;
    let pendingRevokeLocks = await readKnownHostDecisionLocks(sameProfilePage);
    while (Date.now() < pendingLockDeadline &&
        !pendingRevokeLocks.pending.some((lock) =>
          lock.name === sameProfileLockName && lock.mode === 'exclusive')) {
      await sameProfilePage.waitForTimeout(50);
      pendingRevokeLocks = await readKnownHostDecisionLocks(sameProfilePage);
    }
    assertThat(pendingRevokeLocks.supported &&
      pendingRevokeLocks.held.some((lock) =>
        lock.name === sameProfileLockName && lock.mode === 'shared') &&
      pendingRevokeLocks.pending.some((lock) =>
        lock.name === sameProfileLockName && lock.mode === 'exclusive') &&
      !pendingRevokeLocks.held.some((lock) =>
        lock.name === sameProfileLockName && lock.mode === 'exclusive'),
    'same-origin revoke did not queue exclusively behind tab A shared userauth');
    const totalsWhileRevokeWaits = readVaultSyncTotals(dataDir);
    assertThat(JSON.stringify(totalsWhileRevokeWaits) === JSON.stringify(sameProfileRevocationBefore),
      'KnownHost revocation changed durable Vault rows while SSH userauth still held its shared lock');
    const panelWhileRevokeWaits = await safeTrustPanelState(sameProfilePage);
    assertThat(panelWhileRevokeWaits.revokedStatusCount === revokedStatusCountBefore,
      'same-profile KnownHost row became revoked before SSH userauth completed');

    activeStage = 'release real OpenSSH userauth after confirming revoke is pending';
    assertThat(sameProfileAuthGate.release(),
      'the isolated userauth gate could not be released after lock ordering was observed');
    const authFailureResult = await pollSshOutcome(ownerPage, 20000, {
      ignoreApprovalPrompt: true,
      expectedHostName: sameProfileHostName,
      baseline: sameProfileAuthPendingBaseline,
    });
    const authFailureDeadline = Date.now() + 10000;
    let sameProfileSshdAfterAuth = readSshdLogSummary(tempRoot);
    while (Date.now() < authFailureDeadline &&
        sameProfileSshdAfterAuth.failedPublicKeys !== sameProfileSshdAtGate.failedPublicKeys + 1) {
      await new Promise((resolve) => setTimeout(resolve, 50));
      sameProfileSshdAfterAuth = readSshdLogSummary(tempRoot);
    }
    assertThat(sameProfileAuthGate.released &&
      sameProfileSshdAfterAuth.failedPublicKeys - sameProfileSshdAtGate.failedPublicKeys === 1 &&
      sameProfileSshdAfterAuth.acceptedPublicKeys === sameProfileSshdAtGate.acceptedPublicKeys &&
      authFailureResult.diagnostics.activeTabState === 'failed',
    'the held SSH userauth did not complete as one rejected public-key attempt');
    const authReleasedLocks = await readKnownHostDecisionLocks(ownerPage);
    assertThat(!authReleasedLocks.held.some((lock) =>
      lock.name === sameProfileLockName && lock.mode === 'shared'),
    'tab A retained its shared KnownHost lock after sshd completed userauth');

    activeStage = 'wait for same-profile queued revoke writer to finish local projection';
    const revokeWriterDeadline = Date.now() + 30000;
    let revokeWriterLocks = await readKnownHostDecisionLocks(sameProfilePage);
    while (Date.now() < revokeWriterDeadline &&
        (revokeWriterLocks.pending.some((lock) =>
          lock.name === sameProfileLockName && lock.mode === 'exclusive') ||
          revokeWriterLocks.held.some((lock) =>
            lock.name === sameProfileLockName && lock.mode === 'exclusive'))) {
      await sameProfilePage.waitForTimeout(50);
      revokeWriterLocks = await readKnownHostDecisionLocks(sameProfilePage);
    }
    assertThat(revokeWriterLocks.supported &&
      !revokeWriterLocks.pending.some((lock) =>
        lock.name === sameProfileLockName && lock.mode === 'exclusive') &&
      !revokeWriterLocks.held.some((lock) =>
        lock.name === sameProfileLockName && lock.mode === 'exclusive'),
    'the queued same-profile revoke writer did not finish after userauth released its shared lock');
    await waitForKnownHostState(
      sameProfilePage,
      'revoked',
      revokedStatusCountBefore + 1,
      20000,
    );

    activeStage = 'send same-profile queued KnownHost revocation';
    await syncNow(sameProfilePage, { force: true });
    activeStage = 'wait for same-profile KnownHost revocation push response';
    await waitForSafeApiResponse('A2', 'sync_push', sameProfileRevokeApiSequence);
    activeStage = 'wait for same-profile KnownHost push acknowledgement';
    await syncNow(sameProfilePage);
    activeStage = 'verify same-profile KnownHost revocation projection';
    await waitForKnownHostState(
      sameProfilePage,
      'revoked',
      revokedStatusCountBefore + 1,
      20000,
    );
    const sameProfileRevocationAfter = readVaultSyncTotals(dataDir);
    assertOneVaultHeadRevision(
      sameProfileRevocationBefore,
      sameProfileRevocationAfter,
      'same-profile userauth-race revocation',
    );
    assertThat(sameProfileRevocationAfter.commit_seq - sameProfileRevocationBefore.commit_seq === 1 &&
      sameProfileRevocationAfter.versions - sameProfileRevocationBefore.versions === 1 &&
      sameProfileRevocationAfter.events - sameProfileRevocationBefore.events === 1 &&
      sameProfileRevocationAfter.receipts - sameProfileRevocationBefore.receipts === 1 &&
      sameProfileRevocationAfter.heads === sameProfileRevocationBefore.heads,
    'same-profile race revocation had unexpected durable Vault deltas');

    activeStage = 'prove next authentication sees the now-revoked exact fingerprint';
    await click(ownerPage, 'Hosts');
    const laterAuthBaseline = await observeSshUi(ownerPage, sameProfileHostName);
    const laterAuthSshdBaseline = readSshdLogSummary(tempRoot);
    const laterAuthVaultBaseline = readVaultSyncTotals(dataDir);
    const ownerRaceCard = ownerPage.getByRole('group', {
      name: sameProfileHostName,
      exact: false,
    }).first();
    await ownerRaceCard.getByRole('button', { name: 'Connect', exact: true }).click();
    const revokedFingerprintPrompt = await pollSshOutcome(ownerPage, 20000, {
      expectedHostName: sameProfileHostName,
      baseline: laterAuthBaseline,
    });
    assertThat(revokedFingerprintPrompt.classification === 'approval_prompt',
      'tab A did not recheck the committed revocation before later SSH userauth');
    await waitForText(ownerPage,
      'This exact fingerprint was revoked before. Reapproval creates a new encrypted trust record for this Vault and syncs it to its devices. Verify it out of band before continuing.');
    const sshdBeforeRevokedPromptDismiss = readSshdLogSummary(tempRoot);
    assertThat(sshdBeforeRevokedPromptDismiss.publicKeyAttempts === laterAuthSshdBaseline.publicKeyAttempts &&
      sshdBeforeRevokedPromptDismiss.failedPublicKeys === laterAuthSshdBaseline.failedPublicKeys &&
      sshdBeforeRevokedPromptDismiss.acceptedPublicKeys === laterAuthSshdBaseline.acceptedPublicKeys,
    'a later SSH authentication attempt reached sshd public-key userauth after revocation commit');
    await click(ownerPage, 'Reject');
    const afterRejectDeadline = Date.now() + 10000;
    let afterRevokedRejectUi = await observeSshUi(ownerPage, sameProfileHostName);
    while (Date.now() < afterRejectDeadline && afterRevokedRejectUi.activeTabState !== 'failed') {
      await ownerPage.waitForTimeout(50);
      afterRevokedRejectUi = await observeSshUi(ownerPage, sameProfileHostName);
    }
    const sameProfileSshdAfterLaterAttempt = readSshdLogSummary(tempRoot);
    const sameProfileVaultAfterLaterAttempt = readVaultSyncTotals(dataDir);
    assertThat(afterRevokedRejectUi.activeTabState === 'failed' &&
      sameProfileSshdAfterLaterAttempt.publicKeyAttempts === laterAuthSshdBaseline.publicKeyAttempts &&
      sameProfileSshdAfterLaterAttempt.failedPublicKeys === laterAuthSshdBaseline.failedPublicKeys &&
      sameProfileSshdAfterLaterAttempt.acceptedPublicKeys === laterAuthSshdBaseline.acceptedPublicKeys &&
      JSON.stringify(sameProfileVaultAfterLaterAttempt) === JSON.stringify(laterAuthVaultBaseline),
    'post-revocation connection reached userauth or changed durable Vault state');

    assertVaultCiphertextAtRest(
      dataDir,
      hostName,
      conflictHostName,
      sameProfileHostName,
      sameProfileCredentialName,
      sameProfileAuthAccount.name,
      `${address}:${sshPort}`,
      `${address}:${conflictPort}`,
      `${address}:${sameProfileAuthPort}`,
      initialFingerprint,
      conflictFingerprintA,
      conflictFingerprintB,
      changedFingerprint,
      sameProfileFingerprint,
    );

    console.log('same-origin KnownHost auth/revoke evidence', JSON.stringify({
      tabsShareBrowserContext: sameProfilePage.context() === ownerContext,
      tabsShareOrigin: ownerOrigin === revokeOrigin,
      sharedLockAtUserauth: true,
      exclusiveRevokeQueuedBehindSharedAuth: true,
      vaultUnchangedWhileRevokeQueued: true,
      authCompletion: 'one_failed_public_key',
      revokeVaultDelta: {
        commit_seq: sameProfileRevocationAfter.commit_seq - sameProfileRevocationBefore.commit_seq,
        versions: sameProfileRevocationAfter.versions - sameProfileRevocationBefore.versions,
        events: sameProfileRevocationAfter.events - sameProfileRevocationBefore.events,
        receipts: sameProfileRevocationAfter.receipts - sameProfileRevocationBefore.receipts,
        heads: sameProfileRevocationAfter.heads - sameProfileRevocationBefore.heads,
      },
      laterRevokedFingerprintReachedUserauth: false,
    }));
    console.log('WEB-KNOWNHOST-01 passed: cross-profile KnownHost sync, offline queued trust decisions, conflict resolution, explicit revocation and reapproval, changed-key rejection, encrypted server storage, and a true same-origin two-tab userauth-versus-revoke race all passed.');
  } finally {
    process.removeListener('SIGINT', onInterrupt);
    process.removeListener('SIGTERM', onTerminate);
    bootstrapToken = undefined;
    const sameProfileAuthGateReleased = !sameProfileAuthGate ||
      !sameProfileAuthGate.entered || sameProfileAuthGate.released ||
      await cleanupStep('release isolated SSH userauth gate', () => sameProfileAuthGate.release());
    const contextCleanupResults = await Promise.all([
      ownerContext && cleanupStep('owner browser context close', () => ownerContext.close()),
      secondContext && cleanupStep('second browser context close', () => secondContext.close()),
    ].filter(Boolean));
    const browserConnectionStopped = !browser || await cleanupStep(
      'Playwright browser connection close',
      () => browser.close(),
    );
    const browserProcessStopped = await cleanupStep(
      'Chromium fixture process exit',
      () => stopTestBrowserServer(),
      16000,
    );
    const primarySshStopped = await cleanupStep(
      'primary SSH fixture stop',
      () => stopGroup(sshdProcess),
      6500,
    );
    const conflictSshStopped = await cleanupStep(
      'conflict SSH fixture stop',
      () => stopGroup(conflictSshdProcess),
      6500,
    );
    const sameProfileSshStopped = await cleanupStep(
      'same-profile SSH userauth fixture stop',
      () => stopGroup(sameProfileSshdProcess),
      6500,
    );
    const sameProfileAccountRemoved = !sameProfileAuthAccount?.created || await cleanupStep(
      'same-profile temporary SSH account removal',
      () => cleanupUserauthAccount(sameProfileAuthAccount),
      15000,
    );
    const sameProfileAuthGateRemoved = !sameProfileAuthGate || await cleanupStep(
      'same-profile SSH userauth gate removal',
      () => cleanupUserauthGate(sameProfileAuthGate),
      5000,
    );
    const serverStopped = await cleanupStep(
      'server fixture stop',
      () => stopGroup(serverProcess),
      6500,
    );
    if (serverLog !== undefined) {
      try { fs.closeSync(serverLog); } catch (_) {}
    }
    const cleanupConfirmed = sameProfileAuthGateReleased && sameProfileAccountRemoved &&
      sameProfileAuthGateRemoved &&
      contextCleanupResults.every(Boolean) &&
      browserConnectionStopped && browserProcessStopped && primarySshStopped &&
      conflictSshStopped && sameProfileSshStopped && serverStopped;
    if (cleanupConfirmed) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        console.log('WEB-KNOWNHOST-01 cleanup temporary fixture removal: complete');
      } catch (_) {
        console.warn('WEB-KNOWNHOST-01 cleanup temporary fixture removal: failed');
        process.exitCode = 1;
      }
    } else {
      console.warn('WEB-KNOWNHOST-01 cleanup temporary fixture removal: skipped because process exit was unconfirmed');
      process.exitCode = 1;
    }
  }
}

main().catch((error) => {
  const message = String(error?.message || '');
  const errorCategory = error?.name === 'TimeoutError' || /timed out|timeout/i.test(message)
    ? 'timeout'
    : /browserType\.launch|Failed to launch|Executable doesn't exist|Target page, context or browser has been closed/i.test(message)
      ? 'browser_startup'
      : /net::ERR_|ECONNREFUSED|ERR_CONNECTION/i.test(message)
        ? 'browser_navigation'
        : /did not reach its accessible startup state|cryptography did not initialize/i.test(message)
          ? 'web_runtime_startup'
          : /did not|expected|failed|invalid|missing/i.test(message)
            ? 'acceptance_assertion'
            : 'runtime_error';
  const errorCode = /^[A-Z0-9_]{2,40}$/.test(String(error?.code || ''))
    ? error.code
    : undefined;
  const safeKnownHostStateFailure = message.startsWith(
    'known-host trust panel did not reach the expected visible state:',
  ) ? message.slice(0, 900) : undefined;
  console.error(`WEB-KNOWNHOST-01 failed at ${activeStage}; safe failure=${JSON.stringify({
    errorName: typeof error?.name === 'string' ? error.name : 'unknown',
    errorCategory,
    ...(errorCode ? { errorCode } : {}),
    ...(safeKnownHostStateFailure ? { knownHostStateFailure: safeKnownHostStateFailure } : {}),
  })}; safe browser issues=${JSON.stringify(safeBrowserIssues.slice(-12))}; startup probes=${JSON.stringify(safeStartupProbes)}; safe API status categories=${JSON.stringify(safeApiStatuses.slice(-20))}; sensitive details omitted`);
  process.exitCode = 1;
});
