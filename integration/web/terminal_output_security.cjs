'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { startSshFixture } = require('./ssh_fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = 'terminal-security-' + RUN_ID.slice(0, 8) + '@example.test';
const MASTER_PASSWORD = 'Terminal-' + crypto.randomBytes(24).toString('base64url');
const DEVICE_NAME = 'Terminal output security';
const HOST_NAME = 'Terminal security ' + RUN_ID.slice(0, 8);
const CREDENTIAL_NAME = 'Terminal security credential ' + RUN_ID.slice(0, 8);
let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let context;
let page;
let sshFixture;
let terminalFixtureContext;
let bootstrapToken;
let externalRequests = 0;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}
function setStage(value) {
  stage = value;
  console.log('stage: ' + value);
}
function isPrivateIpv4(address) {
  if (!net.isIPv4(address)) return false;
  const octets = address.split('.').map(Number);
  return octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
}
function privateIpv4Address() {
  const addresses = Object.values(os.networkInterfaces())
    .flatMap((entries) => entries || [])
    .filter((entry) => entry.family === 'IPv4' && !entry.internal &&
      isPrivateIpv4(entry.address))
    .map((entry) => entry.address);
  assertThat(addresses.length > 0, 'fixture requires an assigned private IPv4 interface');
  return addresses[0];
}
async function unusedPort(address) {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, address, resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close((error) =>
    error ? reject(error) : resolve()));
  return port;
}
function buildServer() {
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT, stdio: 'ignore', timeout: 180000,
  });
  assertThat(!result.error && result.status === 0 && fs.existsSync(SERVER_BINARY),
    'isolated server build failed');
}
async function waitForServer(baseUrl, child) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(baseUrl + '/health/ready', {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
  }
  throw new Error('isolated server readiness timed out');
}
function issueBootstrapToken(environment) {
  const result = spawnSync(SERVER_BINARY, ['bootstrap'], {
    cwd: ROOT, env: environment, encoding: 'utf8', timeout: 30000,
    maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, 'bootstrap token issuance failed');
  const token = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(typeof token === 'string', 'bootstrap token was unavailable');
  return token;
}
function shellQuote(value) {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}
async function cleanup() {
  bootstrapToken = undefined;
  terminalFixtureContext = undefined;
  if (context) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
  if (sshFixture) await sshFixture.cleanup().catch(() => {});
  if (serverProcess && Number.isInteger(serverProcess.pid)) {
    try { process.kill(-serverProcess.pid, 'SIGTERM'); } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 250));
    try { process.kill(-serverProcess.pid, 'SIGKILL'); } catch (_) {}
  }
  if (tempRoot) fs.rmSync(tempRoot, { recursive: true, force: true });
}
process.once('SIGINT', () => { void cleanup().finally(() => process.exit(130)); });
process.once('SIGTERM', () => { void cleanup().finally(() => process.exit(143)); });

async function waitFor(predicate, timeoutMs, message) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await page.waitForTimeout(100);
  }
  throw new Error(message);
}
async function field(label) {
  const selector = 'input[aria-label*=' + JSON.stringify(label) +
    '],textarea[aria-label*=' + JSON.stringify(label) + ']';
  const locator = page.locator(selector);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = [];
    for (let i = 0; i < await locator.count(); i++) {
      const candidate = locator.nth(i);
      if (await candidate.isVisible().catch(() => false)) visible.push(candidate);
    }
    assertThat(visible.length <= 1, 'ambiguous field: ' + label);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error('field was not visible: ' + label);
}
async function button(label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    for (let i = 0; i < await locator.count(); i++) {
      const candidate = locator.nth(i);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error('button was not visible: ' + label);
}
async function click(label) {
  await (await button(label)).click();
}
async function closeTerminalSearchSafely() {
  const searchLocator = page.getByRole('textbox', {
    name: 'Search terminal scrollback', exact: true,
  });
  const searchCount = await searchLocator.count().catch(() => 0);
  const searchVisible = searchCount === 1 &&
    await searchLocator.isVisible().catch(() => false);
  const locatorFocus = searchVisible ? await searchLocator.evaluate((element) => {
    const active = document.activeElement;
    return {
      related: Boolean(active && (active === element || element.contains(active) ||
        (active !== document.body && active.contains(element)))),
      elementTag: element.tagName.toLowerCase(),
      activeTag: active?.tagName?.toLowerCase() || '',
      elementRole: element.getAttribute('role') || '',
      activeRole: active?.getAttribute('role') || '',
    };
  }).catch(() => ({ related: false, elementTag: '', activeTag: '', elementRole: '', activeRole: '' }))
    : { related: false, elementTag: '', activeTag: '', elementRole: '', activeRole: '' };
  assertThat(searchVisible && locatorFocus.related,
    'terminal search textbox was not uniquely focused before keyboard close: ' +
      JSON.stringify({ searchCount, searchVisible, locatorFocus }));

  const closeLocator = page.getByRole('button', {
    name: 'Close terminal search', exact: true,
  });
  const closeCount = await closeLocator.count().catch(() => 0);
  const closeVisible = closeCount === 1 && await closeLocator.isVisible().catch(() => false);
  assertThat(closeVisible,
    'Close terminal search button was not uniquely visible: ' +
      JSON.stringify({ closeCount, closeVisible }));
  await closeLocator.focus({ timeout: 2000 });
  const closeFocus = await closeLocator.evaluate((element) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const active = document.activeElement;
    const labels = [element.getAttribute('aria-label'), element.innerText,
      element.textContent, element.getAttribute('title')].map(normalize);
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute('role') || (tag === 'button' ? 'button' : '');
    return {
      related: Boolean(active && (active === element || element.contains(active) ||
        (active !== document.body && active.contains(element)))),
      targetRoleExact: role === 'button',
      targetNameExact: labels.includes('Close terminal search'),
      activeRole: active?.getAttribute('role') || '',
      activeTag: active?.tagName?.toLowerCase() || '',
    };
  });
  assertThat(closeFocus.related && closeFocus.targetRoleExact && closeFocus.targetNameExact,
    'Close terminal search did not receive exact keyboard focus: ' +
      JSON.stringify({ closeCount, closeVisible, ...closeFocus }));
  await page.keyboard.press('Enter');
  await closeLocator.waitFor({ state: 'hidden', timeout: 5000 });
}
async function fill(label, value) {
  const locator = await field(label);
  for (let attempt = 0; attempt < 3; attempt++) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 10 });
    if (await locator.inputValue() === value) {
      await locator.press('Tab').catch(() => {});
      return;
    }
  }
  throw new Error('field did not retain fixture value: ' + label);
}
async function waitForText(expected, timeoutMs) {
  await waitFor(() => page.evaluate((text) => {
    const labels = [document.body.innerText,
      ...[...document.querySelectorAll('flt-semantics')]
        .flatMap((node) => [node.innerText || '', node.getAttribute('aria-label') || ''])];
    return labels.some((value) => value.includes(text));
  }, expected), timeoutMs || 20000, 'expected UI text was not visible');
}
async function enableSemantics() {
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))),
  30000, 'Flutter Web semantics did not start');
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.locator('flt-semantics').count().then((count) => count > 0),
    15000, 'Flutter Web semantics did not appear');
}
async function registerOwner(baseUrl) {
  await fill('Server URL', baseUrl);
  await click('Connect securely');
  await fill('Owner email', USERNAME);
  await fill('Master password · 12+ characters', MASTER_PASSWORD);
  await fill('Confirm master password', MASTER_PASSWORD);
  await fill('One-time bootstrap token', bootstrapToken);
  await fill('Device name', DEVICE_NAME);
  await fill('First Vault', 'Terminal output security');
  await click('Create owner account');
  bootstrapToken = undefined;
  await button('Add host');
}
async function selectCredentialOption(name) {
  const controls = page.getByRole('button', { name: /SSH credential override/i });
  assertThat(await controls.count() > 0, 'SSH credential override control was missing');
  await controls.last().click();
  const optionDeadline = Date.now() + 5000;
  let optionPoint;
  while (!optionPoint && Date.now() < optionDeadline) {
    optionPoint = await page.evaluate((expected) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const candidates = [...document.querySelectorAll('flt-semantics')].flatMap((element) => {
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0 ||
            rect.left >= window.innerWidth || rect.top >= window.innerHeight) return [];
        const labels = [
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].map(normalize).filter(Boolean);
        const matchingLabel = labels.find((label) => label.includes(expected));
        return matchingLabel ? [{
          label: matchingLabel,
          area: rect.width * rect.height,
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        }] : [];
      });
      candidates.sort((left, right) => left.label.length - right.label.length || left.area - right.area);
      const candidate = candidates[0];
      return candidate ? { x: candidate.x, y: candidate.y, label: candidate.label } : null;
    }, name).catch(() => null);
    if (!optionPoint) await page.waitForTimeout(100);
  }
  assertThat(Boolean(optionPoint), 'exact SSH credential option was not visible');
  assertThat(optionPoint.label.includes(name), 'SSH credential option hit point did not match requested credential');
  await page.mouse.click(optionPoint.x, optionPoint.y);

  await waitFor(() => page.evaluate(({ expectedField, expectedValue }) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 &&
        rect.left < window.innerWidth && rect.top < window.innerHeight;
    };
    return [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((element) => [
        element.getAttribute('aria-label') || '', element.innerText || '',
        element.textContent || '', element.getAttribute('title') || '',
      ].join(' ').replace(/\s+/g, ' ').trim())
      .some((label) => label.toLowerCase().includes(expectedField.toLowerCase()) &&
        label.includes(expectedValue));
  }, { expectedField: 'SSH credential override', expectedValue: name }),
  5000, 'SSH credential override did not retain the exact selected credential');
}
async function createCredentialAndHost(address, port, sshUsername, sshPassword) {
  await click('Credentials');
  await click('Add credential');
  await fill('Credential name', CREDENTIAL_NAME);
  await fill('SSH username', sshUsername);
  await click('Password');
  await fill('Password', sshPassword);
  await click('Save encrypted credential');
  await page.getByRole('group', { name: new RegExp(CREDENTIAL_NAME) })
    .first().waitFor({ state: 'visible', timeout: 15000 });
  await click('Hosts');
  await click('Add host');
  await waitForText('Add a host');
  await fill('Display name', HOST_NAME);
  await fill('Hostname or IP', address);
  await fill('Port', String(port));
  await fill('SSH username', sshUsername);
  await selectCredentialOption(CREDENTIAL_NAME + ' · ' + sshUsername);
  await click('Save encrypted host');
  const card = page.getByRole('group', { name: new RegExp(HOST_NAME) }).first();
  await card.waitFor({ state: 'visible', timeout: 15000 });
  await card.getByRole('button', { name: 'Connect', exact: true }).click();
}
async function connectAndTrust(fingerprint) {
  const trust = page.getByRole('button', { name: 'Trust after verification', exact: true });
  await trust.waitFor({ state: 'visible', timeout: 45000 });
  const fingerprintDeadline = Date.now() + 10000;
  let fingerprintEvidence;
  while (Date.now() < fingerprintDeadline) {
    fingerprintEvidence = await page.evaluate((expected) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 &&
          rect.top < innerHeight && rect.left < innerWidth;
      };
      const semantics = [...document.querySelectorAll('flt-semantics')];
      const visibleText = semantics.filter(visible).map((node) => [
        node.getAttribute('aria-label') || '',
        node.getAttribute('aria-valuetext') || '',
        node.innerText || node.textContent || '',
      ].join(' ')).join('\n');
      const accessibleFingerprintNodes = [...document.querySelectorAll(
        '[aria-label], [aria-description], [aria-valuetext], [title], [alt]',
      )].filter(visible).flatMap((node) => [...node.attributes]
        .filter((attribute) => [
          'aria-label', 'aria-description', 'aria-valuetext', 'title', 'alt',
        ].includes(attribute.name) && attribute.value.includes(expected))
        .map((attribute) => attribute.value));
      const fingerprints = [...new Set(accessibleFingerprintNodes.flatMap((value) =>
        value.match(/SHA256:[A-Za-z0-9+/=]+/g) || []))];
      return {
        trustPromptVisible: visibleText.includes('Verify SSH host key') &&
          visibleText.includes('Trust after verification'),
        fingerprintVisible: fingerprints.includes(expected),
        fingerprintCount: fingerprints.length,
        exactFixtureMatch: fingerprints.length === 1 && fingerprints[0] === expected,
      };
    }, fingerprint).catch(() => null);
    if (fingerprintEvidence?.trustPromptVisible && fingerprintEvidence.exactFixtureMatch) break;
    await page.waitForTimeout(100);
  }
  assertThat(fingerprintEvidence?.trustPromptVisible && fingerprintEvidence.exactFixtureMatch,
    'visible host-key fingerprint did not exactly match the SSH fixture: ' +
      JSON.stringify(fingerprintEvidence));
  await trust.click();
  await page.getByRole('button', {
    name: HOST_NAME + ' terminal tab, connected, active', exact: true,
  }).waitFor({ state: 'visible', timeout: 45000 });
  await page.getByRole('textbox', { name: 'SSH terminal input', exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
}
async function sendTerminalCommand(command) {
  assertThat(terminalFixtureContext?.username && terminalFixtureContext?.address,
    'trusted terminal fixture context was unavailable');
  const header = page.getByText(
    terminalFixtureContext.username + '@' + terminalFixtureContext.address,
    { exact: true },
  ).first();
  const headerDeadline = Date.now() + 10000;
  while (Date.now() < headerDeadline && !await header.isVisible().catch(() => false)) {
    await page.waitForTimeout(100);
  }
  assertThat(await header.isVisible().catch(() => false),
    'exact SSH fixture terminal header was not visible');
  const headerBox = await header.boundingBox().catch(() => null);
  const viewport = page.viewportSize() || { width: 1440, height: 1000 };
  assertThat(headerBox && headerBox.width > 0 && headerBox.height > 0,
    'exact SSH fixture terminal header bounds were unavailable');
  const top = Math.ceil(headerBox.y + headerBox.height + 8);
  const width = Math.max(0, Math.round(viewport.width - headerBox.x - 16));
  const height = Math.max(0, Math.round(viewport.height - top - 48));
  assertThat(width > 100 && height > 100,
    'SSH fixture terminal surface had no usable bounds');
  await page.mouse.click(
    Math.round(headerBox.x + width / 2),
    Math.round(top + height / 2),
  );

  const input = page.getByRole('textbox', { name: 'SSH terminal input', exact: true });
  const inputCount = await input.count().catch(() => 0);
  const inputVisible = inputCount === 1 && await input.isVisible().catch(() => false);
  assertThat(inputVisible, 'SSH terminal input was not uniquely visible after surface focus');
  const focusDeadline = Date.now() + 5000;
  let focusState;
  while (Date.now() < focusDeadline) {
    focusState = await input.evaluate((element) => {
      let active = document.activeElement;
      for (let depth = 0; depth < 8 && active?.shadowRoot?.activeElement; depth++) {
        active = active.shadowRoot.activeElement;
      }
      const semanticsFocused = element.getAttribute('aria-focused') === 'true';
      const activeLabelIsTerminalInput =
        active?.getAttribute('aria-label') === 'SSH terminal input';
      return {
        semanticsFocused,
        activeLabelIsTerminalInput,
        activeTag: active?.tagName?.toLowerCase() || '',
        activeRole: active?.getAttribute('role') || '',
      };
    }).catch(() => ({
      semanticsFocused: false, activeLabelIsTerminalInput: false,
      activeTag: '', activeRole: '',
    }));
    if (focusState.semanticsFocused ||
        focusState.activeLabelIsTerminalInput) break;
    await page.waitForTimeout(100);
  }
  assertThat(focusState?.semanticsFocused ||
    focusState?.activeLabelIsTerminalInput,
  'SSH terminal input did not receive exact focus after surface selection: ' +
    JSON.stringify({ inputCount, inputVisible, ...focusState }));
  await page.keyboard.type(command, { delay: 5 });
  await page.keyboard.press('Enter');
}
function ptyCaseScript(name, actions) {
  return [
    'before=$(stty size)', actions, 'after=$(stty size)',
    `printf 'PTY_BEFORE_${name}:%s\\n' "$before"`,
    `printf 'PTY_AFTER_${name}:%s\\n' "$after"`,
    `if [ "$before" = "$after" ]; then ${shellPrintMarker(`PTY_SIZE_UNCHANGED_${name}`)}; else ${shellPrintMarker(`PTY_SIZE_CHANGED_${name}`)}; fi`,
  ].join('; ');
}
function shellPrintMarker(marker, newline = true) {
  const splitAt = Math.ceil(marker.length / 2);
  const format = newline ? '%s%s\\n' : '%s%s';
  return `printf '${format}' ${shellQuote(marker.slice(0, splitAt))} ${shellQuote(marker.slice(splitAt))}`;
}
async function sendFixtureCommand(caseName, script, resultMarker, ptyCase, recoveryMarkers = []) {
  setStage('send terminal output security case: ' + caseName);
  await sendTerminalCommand('bash -c ' + shellQuote(script));
  // Let the remote before/after stty samples and output completion settle
  // before opening scrollback search, whose bar can resize the terminal grid.
  await page.waitForTimeout(1500);
  let currentMarker = resultMarker;
  try {
    await searchScrollback(resultMarker);
    for (const marker of recoveryMarkers) {
      currentMarker = marker;
      await searchScrollback(marker);
    }
  } catch (error) {
    const resultEvidence = error.safeSearchEvidence || {
      found: false, status: 'unavailable', currentMatch: null, totalMatches: 0,
    };
    if (ptyCase && currentMarker === resultMarker) {
      const changedMarker = 'PTY_SIZE_CHANGED_' + ptyCase;
      const changedEvidence = await searchScrollbackEvidence(changedMarker, 1500).catch(() => ({
        found: false, status: 'unavailable', currentMatch: null, totalMatches: 0,
      }));
      const summary = (evidence) => ({
        found: evidence.found,
        status: evidence.status || (evidence.found ? 'one match' : 'unavailable'),
        count: evidence.totalMatches ?? evidence.currentMatch ?? 0,
      });
      console.log('terminal_output_security_result_diagnostic', JSON.stringify({
        caseName,
        resultMarker: currentMarker,
        result: summary(resultEvidence),
        changedMarker,
        changed: summary(changedEvidence),
      }));
    }
    error.message = 'fixed case ' + caseName + ' result marker ' + currentMarker +
      ' failed: ' + error.message;
    throw error;
  }
  await closeTerminalSearchSafely();
}
async function searchScrollbackEvidence(marker, timeoutMs = 10000) {
  let search = page.getByRole('textbox', { name: /Search terminal scrollback/i });
  if (await search.count() === 0) await click('Search terminal scrollback');
  search = page.getByRole('textbox', { name: /Search terminal scrollback/i });
  await search.waitFor({ state: 'visible', timeout: 15000 });
  await search.fill(marker);
  const statusPattern = /(?:Searching(?:…|\.\.\.)?|\d+ of \d+ matches|\d+ matches)(?:\s*·\s*results limited)?/i;
  const deadline = Date.now() + timeoutMs;
  let status = '';
  let observedRefresh = false;
  while (Date.now() < deadline) {
    status = await page.evaluate((patternSource) => {
      const pattern = new RegExp(patternSource, 'i');
      for (const node of document.querySelectorAll('flt-semantics')) {
        const text = [node.getAttribute('aria-label') || '',
          node.innerText || '', node.textContent || ''].join(' ').replace(/\s+/g, ' ');
        const match = text.match(pattern);
        if (match) return match[0].trim();
      }
      return '';
    }, statusPattern.source).catch(() => '');

    if (/^(?:Searching(?:…|\.\.\.)?|0 matches)(?:\s*·\s*results limited)?$/i.test(status)) {
      observedRefresh = true;
    }
    const hasOneMatch = /^(?:1 of [12] matches|1 matches)(?:\s*·\s*results limited)?$/i
      .test(status);
    if (observedRefresh && hasOneMatch) {
      const countStatus = status.replace(/\s*·\s*results limited$/i, '');
      const matchCounts = countStatus.match(/^(\d+) of (\d+) matches$/i) ||
        countStatus.match(/^(\d+) matches$/i);
      return {
        found: true,
        status: countStatus,
        currentMatch: matchCounts?.length === 3 ? Number(matchCounts[1]) :
          matchCounts?.length === 2 ? Number(matchCounts[1]) : null,
        totalMatches: matchCounts?.length === 3 ? Number(matchCounts[2]) :
          matchCounts?.length === 2 ? Number(matchCounts[1]) : null,
      };
    }
    await page.waitForTimeout(100);
  }
  const countStatus = status.replace(/\s*·\s*results limited$/i, '');
  const matchCounts = countStatus.match(/^(\d+) of (\d+) matches$/i) ||
    countStatus.match(/^(\d+) matches$/i);
  return {
    found: false,
    status: countStatus || 'unavailable',
    currentMatch: matchCounts?.length === 3 ? Number(matchCounts[1]) :
      matchCounts?.length === 2 ? Number(matchCounts[1]) : null,
    totalMatches: matchCounts?.length === 3 ? Number(matchCounts[2]) :
      matchCounts?.length === 2 ? Number(matchCounts[1]) : null,
    observedRefresh,
  };
}
async function searchScrollback(marker) {
  const evidence = await searchScrollbackEvidence(marker);
  if (evidence.found) return;
  const safeEvidence = {
    found: evidence.found,
    status: evidence.status || 'unavailable',
    currentMatch: evidence.currentMatch,
    totalMatches: evidence.totalMatches,
    observedRefresh: evidence.observedRefresh,
  };
  const error = new Error('terminal scrollback did not reach a one-match state: ' +
    JSON.stringify({ status: evidence.status || 'one match', currentMatch: evidence.currentMatch,
      totalMatches: evidence.totalMatches, observedRefresh: evidence.observedRefresh }));
  error.safeSearchEvidence = safeEvidence;
  throw error;
}
async function installBrowserSideEffectSpies() {
  await context.addInitScript(() => {
    const state = {
      clipboardWrites: 0, clipboardCopyCommands: 0, windowsOpened: 0,
      scriptRuns: 0, javascriptAnchors: 0, injectedImages: 0,
    };
    Object.defineProperty(window, '__terminalOutputSecurity', {
      configurable: false, value: state,
    });
    const clipboard = globalThis.Clipboard?.prototype;
    if (clipboard && typeof clipboard.writeText === 'function') {
      Object.defineProperty(clipboard, 'writeText', {
        configurable: true, value: async () => { state.clipboardWrites++; },
      });
    }
    const originalExec = Document.prototype.execCommand;
    Document.prototype.execCommand = function (command, ...args) {
      if (String(command).toLowerCase() === 'copy') state.clipboardCopyCommands++;
      return typeof originalExec === 'function' ? originalExec.call(this, command, ...args) : false;
    };
    const originalOpen = window.open;
    window.open = function (...args) {
      state.windowsOpened++;
      return typeof originalOpen === 'function' ? originalOpen.apply(this, args) : null;
    };
    const inspect = (element) => {
      if (!(element instanceof Element)) return;
      if (element.matches('a[href^="javascript:"]')) state.javascriptAnchors++;
      if (element.matches('img')) state.injectedImages++;
      for (const child of element.querySelectorAll('a[href^="javascript:"],img')) {
        if (child.matches('a[href^="javascript:"]')) state.javascriptAnchors++;
        else state.injectedImages++;
      }
    };
    new MutationObserver((records) => {
      for (const record of records) {
        if (record.type === 'attributes') inspect(record.target);
        for (const node of record.addedNodes) inspect(node);
      }
    }).observe(document, {
      subtree: true, childList: true, attributes: true, attributeFilter: ['href'],
    });
  });
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Web release is incomplete');
  }
  const sshAddress = privateIpv4Address();
  const sshPort = await unusedPort(sshAddress);
  const apiPort = await unusedPort('127.0.0.1');
  const baseUrl = 'http://127.0.0.1:' + apiPort;
  setStage('build isolated server and start private OpenSSH fixture');
  buildServer();
  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-terminal-output-security-'));
  fs.chmodSync(tempRoot, 0o700);
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  sshFixture = await startSshFixture({
    bindAddress: sshAddress,
    ports: [sshPort],
    includeStty: true,
  });
  const sshServer = sshFixture.servers[0];
  terminalFixtureContext = {
    username: sshFixture.username,
    address: sshAddress,
  };
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: '127.0.0.1:' + apiPort,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: 'sqlite://' + path.join(dataDir, 'atermius.db') + '?mode=rwc',
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'true',
    ATERMIUS_RELAY_ALLOW_CIDRS: sshAddress + '/32',
    ATERMIUS_RELAY_ALLOW_PORTS: String(sshPort),
    ATERMIUS_TERMINAL_COLLABORATION_ENABLED: 'false',
    RUST_LOG: 'off',
  };
  try {
    setStage('start disposable server and Chromium');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT, env: serverEnv, detached: true, stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = issueBootstrapToken(serverEnv);
    browser = await chromium.launch({
      headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'],
      ...(CHROMIUM_EXECUTABLE ? { executablePath: CHROMIUM_EXECUTABLE } : {}),
    });
    context = await browser.newContext({
      locale: 'en-US', viewport: { width: 1440, height: 1000 },
      permissions: ['clipboard-read', 'clipboard-write'],
    });
    await installBrowserSideEffectSpies();
    page = await context.newPage();
    page.on('request', (request) => {
      if (!request.url().startsWith(baseUrl)) externalRequests++;
    });
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await enableSemantics();
    await button('Connect securely');

    setStage('register Owner and save encrypted SSH Credential and Host');
    await registerOwner(baseUrl);
    await createCredentialAndHost(sshAddress, sshPort, sshFixture.username, sshFixture.password);

    setStage('verify SSH fingerprint and establish Relay shell');
    await connectAndTrust(sshServer.hostFingerprint);
    const viewportBefore = await page.evaluate(() => ({
      width: window.innerWidth, height: window.innerHeight,
    }));

    setStage('send malicious, fragmented, incomplete, and oversized terminal output');
    setStage('send terminal output security case: baseline');
    await sendTerminalCommand(shellPrintMarker('TERMINAL_SECURITY_BASELINE_OK'));
    await searchScrollback('TERMINAL_SECURITY_BASELINE_OK');
    await closeTerminalSearchSafely();

    await sendFixtureCommand('direct', ptyCaseScript('DIRECT',
      shellPrintMarker('TERMINAL_SECURITY_DIRECT_OUTPUT_SENTINEL') +
        '; printf "%b" "\\033[8;500;500t"; read -t 0.2 -r _ || :'),
    'PTY_SIZE_UNCHANGED_DIRECT', 'DIRECT', ['TERMINAL_SECURITY_DIRECT_OUTPUT_SENTINEL']);
    await sendFixtureCommand('OSC',
      "printf '%b' '\\033]52;c;SGVsbG8=\\007\\033]8;;javascript:window.__terminalOutputSecurity.scriptRuns++\\033\\\\CLICK-TRAP\\033]8;;\\033\\\\\\033]0;<img src=x onerror=window.__terminalOutputSecurity.scriptRuns++>\\007'; " +
        shellPrintMarker('OSC_SIDE_EFFECTS_SHOULD_STAY_ZERO'),
    'OSC_SIDE_EFFECTS_SHOULD_STAY_ZERO');
    await sendFixtureCommand('fragmented', ptyCaseScript('FRAGMENTED',
      'printf "%b" "\\033[8;"; read -t 0.2 -r _ || :; printf "%b" "400;120t"; ' +
        shellPrintMarker('FRAGMENTED_CSI_RECOVERED', false) + '; read -t 0.2 -r _ || :'),
    'PTY_SIZE_UNCHANGED_FRAGMENTED', 'FRAGMENTED', ['FRAGMENTED_CSI_RECOVERED']);
    await sendFixtureCommand('incomplete', ptyCaseScript('INCOMPLETE',
      'printf "%b" "\\033[8;500"; read -t 0.2 -r _ || :; printf "%b" "\\030"; ' +
        shellPrintMarker('INCOMPLETE_CSI_CANCEL_RECOVERED', false)),
    'PTY_SIZE_UNCHANGED_INCOMPLETE', 'INCOMPLETE', ['INCOMPLETE_CSI_CANCEL_RECOVERED']);
    await sendFixtureCommand('overlong', ptyCaseScript('OVERLONG',
      'printf "%b" "\\033["; printf "%4097s" ""; printf "%b" "8;500;500t"; ' +
        shellPrintMarker('OVERLONG_CSI_RECOVERED', false) + '; read -t 0.2 -r _ || :'),
    'PTY_SIZE_UNCHANGED_OVERLONG', 'OVERLONG', ['OVERLONG_CSI_RECOVERED']);
    await sendFixtureCommand('parameters', ptyCaseScript('PARAMETERS',
      'params=""; for ((i=0; i<258; i++)); do params+="8;"; done; printf "%b" "\\033[${params}t"; ' +
        shellPrintMarker('TOO_MANY_CSI_PARAMETERS_RECOVERED', false) + '; read -t 0.2 -r _ || :'),
    'PTY_SIZE_UNCHANGED_PARAMETERS', 'PARAMETERS', ['TOO_MANY_CSI_PARAMETERS_RECOVERED']);
    await sendFixtureCommand('number', ptyCaseScript('NUMBER',
      'printf "%b" "\\033[8;100000000000000000000;500t"; ' +
        shellPrintMarker('OVERSIZED_CSI_NUMBER_RECOVERED', false) + '; read -t 0.2 -r _ || :'),
    'PTY_SIZE_UNCHANGED_NUMBER', 'NUMBER', ['OVERSIZED_CSI_NUMBER_RECOVERED']);

    setStage('assert output recovery and zero browser side effects');
    const effects = await page.evaluate(() => ({
      ...window.__terminalOutputSecurity,
      viewport: { width: window.innerWidth, height: window.innerHeight },
    }));
    assertThat(effects.clipboardWrites === 0 && effects.clipboardCopyCommands === 0,
      'remote output triggered clipboard behavior');
    assertThat(effects.windowsOpened === 0 && effects.javascriptAnchors === 0,
      'remote output opened or created a hostile link');
    assertThat(effects.scriptRuns === 0 && effects.injectedImages === 0,
      'remote output executed or inserted attacker markup');
    assertThat(externalRequests === 0, 'remote output initiated external browser requests');
    assertThat(effects.viewport.width === viewportBefore.width &&
      effects.viewport.height === viewportBefore.height,
    'remote output changed browser viewport');
    console.log('assert: terminal_output_security_passed', JSON.stringify({
      csi8ResizeDenied: true, ptySizeBeforeAfterEqualForEveryCase: true,
      fragmentedIncompleteOversizedSequencesRecovered: true,
      clipboardWrites: effects.clipboardWrites,
      clipboardCopyCommands: effects.clipboardCopyCommands,
      windowsOpened: effects.windowsOpened,
      javascriptAnchors: effects.javascriptAnchors,
      scriptRuns: effects.scriptRuns,
      injectedImages: effects.injectedImages,
      externalRequests, viewportUnchanged: true,
    }));
  } finally {
    await cleanup();
  }
}

main().catch(async (error) => {
  console.error('WEB-TERMINAL-OUTPUT-SECURITY-01 failed during ' + stage +
    ': ' + error.message);
  await cleanup();
  process.exitCode = 1;
});
