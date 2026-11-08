/*
 * Web IT-01: isolated browser profiles enroll, sync an encrypted host, and
 * observe each other's commits. All server state and credentials are local to
 * this run and removed on exit.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { startSshFixture } = require('./ssh_fixture.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const {
  reconstructSqliteFile,
  SQLITE_BLOCK_SIZE,
} = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const CLIENT_DATABASE_NAME = 'atermius_vault';
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const CARGO_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(ROOT, process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = path.join(CARGO_TARGET_DIR, 'debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `web-it-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `WebE2e${crypto.randomBytes(20).toString('hex')}9`;
const VAULT_PREFERENCE_ONLY = process.argv.includes('--vault-preferences-only');
const GROUPS_ONLY = process.argv.includes('--groups-only');
const CREDENTIAL_CONFLICTS_ONLY = process.argv.includes('--credential-conflicts-only');
const HOST_SECURITY_CONFLICTS_ONLY = process.argv.includes('--host-security-conflicts-only');
const MISSED_MEMBERSHIP_HINT_ONLY = process.argv.includes('--missed-membership-hint-only');
const MULTI_VAULT_SWITCH_ONLY = process.argv.includes('--multi-vault-only');
const MULTI_VAULT_CONFLICT_STAGE_ONLY =
  process.argv.includes('--stop-after-conflict') ||
  process.env.ATERMIUS_MULTI_VAULT_CONFLICT_STAGE_ONLY === '1';
const SAME_PROFILE_STALE_PAGE_ONLY =
  process.argv.includes('--same-profile-stale-page-only');
// Match serialized preference fields, not generic words that can appear in
// unrelated server schema such as the auth_credentials table.
const VAULT_PREFERENCE_PLAINTEXT_MARKERS = [
  '"type":"preference"',
  '"scope":"workspace"',
  '"key":"defaultSection"',
  '"key":"terminalFontSize"',
  '"key":"terminalTheme"',
  '"key":"terminalShortcuts"',
  'terminal.search',
  'terminal.searchNext',
  'terminal.searchPrevious',
  'terminal.disconnect',
  'mod+alt+shift+f',
  '"value":"hosts"',
  '"value":"credentials"',
  '"value":"groups"',
  '"value":"snippets"',
  '"value":"16"',
  '"value":"light"',
  '"platform_family":"all"',
  'default_section_conflict_repair',
  'preference_conflict_repair',
  'retained_record_id',
];
const CROSS_ATTACHMENT_NAME = `cross-profile-${RUN_ID}.bin`;
const CROSS_ATTACHMENT_MARKER = Buffer.from(`cross-profile-attachment-plaintext-${RUN_ID}:`);
const CROSS_ATTACHMENT_PLAINTEXT = Buffer.concat([
  CROSS_ATTACHMENT_MARKER,
  Buffer.from([0x00, 0x42, 0xff, 0x11, 0x7e]),
  crypto.randomBytes(67),
]);
let activeStage = 'setup';

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const output = `${result.stdout || ''}\n${result.stderr || ''}`.trim();
    throw new Error(`${command} ${args.join(' ')} failed (${result.status}):\n${output.slice(-5000)}`);
  }
  return result.stdout;
}

async function unusedPort(address = '127.0.0.1') {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, address, resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function localEth0Address() {
  const result = spawnSync('ip', [
    '-o', '-4', 'addr', 'show', 'dev', 'eth0', 'scope', 'global',
  ], { encoding: 'utf8', timeout: 5000 });
  const address = (result.stdout || '').match(/\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\//)?.[1];
  const octets = address?.split('.').map(Number);
  const privateAddress = octets?.length === 4 && (
    octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168));
  return result.status === 0 && privateAddress ? address : null;
}

async function waitReady(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited early (${child.exitCode})`);
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1500) });
      if (response.status === 200) return;
      lastError = `readiness returned ${response.status}`;
    } catch (error) {
      lastError = error.message;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`server readiness timed out: ${lastError || 'no response'}`);
}

async function waitForText(page, text, timeout = 20000) {
  await page.getByText(text, { exact: false }).first().waitFor({ state: 'visible', timeout });
}

async function waitForHostEditorDialog(page, timeout = 20000) {
  const dialog = page.getByRole('alertdialog').filter({ hasText: 'Edit host' });
  await dialog.waitFor({ state: 'visible', timeout });
  return dialog;
}

async function waitForSemanticText(page, text, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = await page.evaluate((expected) => {
      if ((document.body.innerText || '').includes(expected)) return true;
      return [...document.querySelectorAll('flt-semantics')].some((element) =>
        ((element.innerText || '') + '\n' +
          (element.getAttribute('aria-label') || '')).includes(expected));
    }, text).catch(() => false);
    if (found) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected text was not exposed by visible Web semantics');
}

async function waitForVisibleSemanticPattern(page, pattern, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  const expression = { source: pattern.source, flags: pattern.flags };
  while (Date.now() < deadline) {
    const found = await page.locator('flt-semantics').evaluateAll((nodes, spec) => {
      const regex = new RegExp(spec.source, spec.flags);
      return nodes.some((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        const visible = rect.width > 0 && rect.height > 0 &&
          rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth &&
          style.visibility !== 'hidden' && style.display !== 'none';
        if (!visible) return false;
        const content = `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`;
        return regex.test(content);
      });
    }, expression).catch(() => false);
    if (found) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected role label was not exposed by visible Web semantics');
}

// Deliberately inspect only the exact terminal-input label. Keep this safe for
// acceptance logs: do not read page text, neighboring labels, values, or errors.
async function terminalInputSemanticDiagnostic(page) {
  return page.locator('[aria-label="SSH terminal input"]').evaluateAll((nodes) => {
    const candidates = nodes.map((element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return {
        role: element.getAttribute('role'),
        tag: element.tagName.toLowerCase(),
        rect: {
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          top: Math.round(rect.top),
          left: Math.round(rect.left),
        },
        style: {
          display: style.display,
          visibility: style.visibility,
          opacity: style.opacity,
          pointerEvents: style.pointerEvents,
        },
        tabIndex: element.tabIndex,
        focused: document.activeElement === element,
      };
    });
    return {
      exactLabelCount: nodes.length,
      exactTextboxRoleCount: candidates.filter((item) => item.role === 'textbox').length,
      focusedExactLabelCount: candidates.filter((item) => item.focused).length,
      candidates,
    };
  }).catch(() => ({
    exactLabelCount: null,
    exactTextboxRoleCount: null,
    focusedExactLabelCount: null,
    candidates: [],
    diagnosticUnavailable: true,
  }));
}

async function roleEpochSemanticEvidence(page) {
  return page.locator('flt-semantics').evaluateAll((nodes) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.visibility !== 'hidden' && style.display !== 'none';
    };
    const rolePattern = (role) => new RegExp(
      `\\b${role}\\s*·\\s*key epoch\\s+\\d+`, 'i');
    const text = (node) =>
      `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
    const evidence = {};
    for (const role of ['owner', 'editor', 'viewer']) {
      const pattern = rolePattern(role);
      const matches = nodes.filter((node) => pattern.test(text(node)));
      evidence[role] = {
        count: matches.length,
        visibleCount: matches.filter(visible).length,
      };
    }
    return evidence;
  }).catch(() => ({
    owner: { count: null, visibleCount: null },
    editor: { count: null, visibleCount: null },
    viewer: { count: null, visibleCount: null },
  }));
}

async function visibleSemanticTextEvidence(page, expectedText) {
  return page.locator('flt-semantics').evaluateAll((nodes, expected) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.visibility !== 'hidden' && style.display !== 'none';
    };
    const matches = nodes.filter((node) =>
      `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`
        .includes(expected));
    return {
      matchCount: matches.length,
      visibleMatchCount: matches.filter(visible).length,
    };
  }, expectedText).catch(() => ({
    matchCount: null,
    visibleMatchCount: null,
  }));
}

function safePageErrorKind(error) {
  const allowed = new Set([
    'Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError',
    'URIError', 'EvalError', 'AssertionError', 'StateError',
  ]);
  return allowed.has(error?.name) ? error.name : 'Other';
}

async function scrollLastVisibleSemanticNodeContaining(page, text) {
  const matches = page.locator('flt-semantics').filter({ hasText: text });
  const evidence = {
    locatorCount: await matches.count().catch(() => 0),
    visibleLocatorCount: 0,
    scrollAttempted: false,
    scrollSucceeded: false,
  };
  for (let index = evidence.locatorCount - 1; index >= 0; index -= 1) {
    const candidate = matches.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    evidence.visibleLocatorCount++;
    if (evidence.scrollAttempted) continue;
    evidence.scrollAttempted = true;
    await candidate.scrollIntoViewIfNeeded();
    evidence.scrollSucceeded = true;
  }
  return evidence;
}

async function visibleVaultMemberLabels(page) {
  const allowedLabels = [
    'EDITOR · Active',
    'VIEWER · Active',
    'EDITOR · Invitation pending',
    'VIEWER · Invitation pending',
    'EDITOR · Invitation expired',
    'VIEWER · Invitation expired',
    'EDITOR · Invitation needs reissue',
    'VIEWER · Invitation needs reissue',
  ];
  return page.locator('flt-semantics').evaluateAll((nodes, labels) => {
    const found = new Set();
    for (const node of nodes) {
      const value = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`;
      for (const label of labels) {
        if (value.includes(label)) found.add(label);
      }
    }
    return [...found].sort();
  }, allowedLabels);
}

async function field(page, label) {
  // Flutter places a full form-field description in the semantics input's
  // aria-label (helper text + field label), so exact getByLabel misses it.
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector);
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const visible = [];
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible()) visible.push(candidate);
    }
    assertThat(visible.length <= 1,
      `browser field '${label}' matched multiple visible inputs`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`browser field '${label}' did not match one visible input`);
}

async function focusedFieldValue(page, label) {
  const locator = await field(page, label);
  await locator.click();
  // Flutter Web synchronizes TextEditingController contents to its hidden
  // editing input after focus. Match the settle interval used by fill().
  await page.waitForTimeout(150);
  return locator.inputValue();
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
  throw new Error(`visible button not found: ${label}`);
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
  const details = await locator.evaluate((element) => ({
    tag: element.tagName, type: element.type,
  }));
  throw new Error(`browser field '${label}' did not retain input (requested ${value.length} chars; ${JSON.stringify(details)})`);
}

async function fillQuick(page, label, value) {
  const locator = await field(page, label);
  await locator.fill(value);
  await locator.press('Tab');
  await page.waitForTimeout(100);
  if (await locator.inputValue() === value) return;
  await fill(page, label, value);
}

async function installArchiveBusyErrorProbe(page) {
  await page.evaluate(() => {
    window.__e2eArchiveBusyErrorObserver?.disconnect?.();
    const probe = { syncOrArchiveBusyObserved: false };
    const observer = new MutationObserver(() => {
      const semanticText = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`)
        .join('\n');
      if (semanticText.includes('请等待当前同步或归档操作完成。')) {
        probe.syncOrArchiveBusyObserved = true;
      }
    });
    observer.observe(document.body, {
      childList: true,
      characterData: true,
      subtree: true,
    });
    window.__e2eArchiveBusyErrorProbe = probe;
    window.__e2eArchiveBusyErrorObserver = observer;
  });
}

async function waitForArchiveDownloadOrBusy(page, timeoutMs) {
  let downloadedArchive = null;
  const onDownload = (download) => { downloadedArchive = download; };
  page.on('download', onDownload);
  try {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (downloadedArchive) return { downloadedArchive };
      const busyErrorObserved = await page.evaluate(() =>
        window.__e2eArchiveBusyErrorProbe?.syncOrArchiveBusyObserved === true,
      ).catch(() => false);
      if (busyErrorObserved) return { busyErrorObserved: true };
      await page.waitForTimeout(100);
    }
    return { timedOut: true };
  } finally {
    page.off('download', onDownload);
  }
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(300);
  let actual = await locator.inputValue();
  if (actual !== value) {
    // Chromium's headless clipboard may report clipboard text correctly while
    // dropping the Control+V event into Flutter's textarea. Retry once, then
    // enter the same value through the visible field's normal input events.
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(300);
    actual = await locator.inputValue();
    if (actual !== value) {
      await locator.fill(value);
      await page.waitForTimeout(100);
      actual = await locator.inputValue();
      if (actual === value) {
        console.log(`clipboard paste fallback used visible input for '${label}' (length=${value.length})`);
        return;
      }
    }
  }
  if (actual !== value) {
    const input = await locator.evaluate((element) => ({
      tag: element.tagName,
      type: element.type,
    }));
    const clipboardLength = await page.evaluate(async () =>
      (await navigator.clipboard.readText()).length).catch(() => null);
    throw new Error(
      `browser field '${label}' did not accept clipboard content ` +
      `(expectedLength=${value.length}, actualLength=${actual.length}, ` +
      `clipboardLength=${clipboardLength}, element=${JSON.stringify(input)}, ` +
      `pageText omitted)`,
    );
  }
}

async function safePageDiagnostic(page) {
  return page.evaluate(() => {
    const roleCounts = {};
    for (const element of document.querySelectorAll('flt-semantics')) {
      const role = element.getAttribute('role') || 'unlabeled';
      roleCounts[role] = (roleCounts[role] || 0) + 1;
    }
    const buttonStates = { count: 0, visible: 0, enabled: 0, disabled: 0 };
    for (const element of document.querySelectorAll('flt-semantics[role="button"]')) {
      buttonStates.count += 1;
      const rect = element.getBoundingClientRect();
      const visible = rect.width > 0 && rect.height > 0;
      const disabled = element.getAttribute('aria-disabled') === 'true';
      if (visible) buttonStates.visible += 1;
      if (disabled) buttonStates.disabled += 1;
      else if (visible) buttonStates.enabled += 1;
    }
    const inputs = [...document.querySelectorAll('input,textarea')].map((element) => ({
      tag: element.tagName,
      type: element.type || '',
      visible: element.getBoundingClientRect().width > 0 &&
        element.getBoundingClientRect().height > 0,
      valueLength: element.value?.length || 0,
      disabled: Boolean(element.disabled),
      readOnly: Boolean(element.readOnly),
    }));
    const knownButtonLabels = new Set([
      'Add host', 'Credentials', 'Groups', 'Snippets', 'Settings',
      'Sign in and unlock', 'Open locally', 'Check again',
      'Request persistent storage', 'Idle', 'Pending', 'Syncing',
      'Retry queued', 'Offline', 'Sync error', 'Snapshot needed',
      'Key update needed', 'Read-only',
    ]);
    const safeButtonLabels = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .map((element) => (element.getAttribute('aria-label') || element.innerText || '')
        .replace(/\s+/g, ' ').trim())
      .filter((label) => knownButtonLabels.has(label) || /^\d+ pending$/.test(label));
    const archivePhaseCodes = [
      ['prepare', '准备验证'],
      ['decrypt_container', '解密归档容器'],
      ['read_manifest_blocks', '读取归档清单和 binary blocks'],
      ['validate_manifest', '验证归档格式和目标'],
      ['manifest_top_level', '检查归档 manifest 顶层字段'],
      ['manifest_identity', '检查归档 manifest 身份和角色'],
      ['manifest_types', '检查归档 manifest 字段类型'],
      ['manifest_snapshot', '检查归档 snapshot schema'],
      ['manifest_limits', '检查归档 manifest 条目上限'],
      ['manifest_heads', '检查归档 snapshot head 字段'],
      ['manifest_revisions', '检查归档 revision 字段'],
      ['manifest_conflicts', '检查归档 conflict 字段'],
      ['manifest_devices', '检查归档设备目录字段'],
      ['manifest_membership', '检查归档 membership 字段'],
      ['manifest_outbox', '检查归档 outbox 字段'],
      ['manifest_branches', '检查归档 conflict branch 字段'],
      ['membership_trust', '验证成员签名链和设备信任'],
      ['key_envelope_epoch', '验证归档 key envelope 和 epoch key'],
      ['encrypted_objects', '验证归档加密对象 block'],
      ['history_revisions', '验证归档历史 revisions'],
      ['history_conflicts', '验证归档历史 conflicts'],
      ['local_outbox_conflicts', '验证归档本地 outbox 和 conflict branches'],
      ['device_sequence_floors', '验证归档设备序列水位'],
    ];
    const bodyText = document.body.innerText || '';
    const safePhaseSearchText = [bodyText,
      ...[...document.querySelectorAll('flt-semantics')].flatMap((element) =>
        [element.innerText || '', element.getAttribute('aria-label') || '']),
    ].join('\n');
    const archiveFailurePhase = archivePhaseCodes.find(([, label]) =>
      safePhaseSearchText.includes(`上次归档验证失败阶段：${label}`))?.[0] || null;
    return {
      path: location.pathname,
      semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      roleCounts,
      buttonStates,
      safeButtonLabels,
      inputs,
      bodyTextLength: bodyText.length,
      archiveFailurePhase,
    };
  }).catch(() => ({ path: '/', diagnosticUnavailable: true }));
}

async function safeArchiveExportUiState(page) {
  return page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const text = document.body.innerText || '';
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')];
    const continueButton = buttons.find((element) =>
      (element.getAttribute('aria-label') || element.innerText || '').trim() === 'Continue');
    return {
      exportDialogOpen: text.includes('Encrypt Vault archive'),
      passwordInputCount: [...document.querySelectorAll('input[type="password"]')]
        .filter(visible).length,
      continueButtonVisible: Boolean(continueButton && visible(continueButton)),
      continueButtonDisabled: continueButton?.getAttribute('aria-disabled') === 'true',
      archiveSaveSuccessVisible: text.includes('Encrypted Vault archive saved.'),
      archiveSaveCancelledVisible: text.includes('Archive save was canceled.'),
      archiveBusyProgressVisible: document.querySelectorAll(
        'flt-semantics[role="progressbar"]',
      ).length > 0,
      alertCount: document.querySelectorAll('flt-semantics[role="alert"]').length,
    };
  }).catch(() => ({ diagnosticUnavailable: true }));
}

async function safeTerminalFontSizeUiSummary(page, expectedFontSize) {
  return page.evaluate((fontSize) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.visibility !== 'hidden' && style.display !== 'none';
    };
    const nodes = [...document.querySelectorAll('flt-semantics')]
      .filter(visible);
    const descriptor = (element) => [
      element.getAttribute('aria-label') || '',
      element.innerText || '',
      element.parentElement?.innerText || '',
    ].join('\n');
    const descriptions = nodes.map((element) => ({
      role: element.getAttribute('role') || '',
      disabled: element.getAttribute('aria-disabled') === 'true',
      text: descriptor(element),
      directText: [
        element.getAttribute('aria-label') || '',
        element.innerText || '',
        element.textContent || '',
        element.getAttribute('title') || '',
      ].join('\n'),
    }));
    const expectedSize = new RegExp(`\\b${fontSize}\\s*px\\b`, 'i');
    const fontSizeControls = descriptions.filter((item) =>
      item.role === 'button' && /Terminal font size/i.test(item.directText) &&
      !/^Save\b/i.test(item.directText.trim()));
    const saveButton = descriptions.filter((item) =>
      item.role === 'button' && /Save terminal font size/i.test(item.text));
    return {
      path: location.pathname,
      semanticNodeCount: nodes.length,
      settingsPanelVisible: descriptions.some((item) =>
        /Vault-synced preferences/i.test(item.text)),
      fontSizeControlVisible: fontSizeControls.length > 0,
      selectedSizeVisible: fontSizeControls.some((item) =>
        expectedSize.test(item.directText)),
      targetOptionVisible: descriptions.some((item) =>
        /^(menuitem|option)$/.test(item.role) && expectedSize.test(item.text)),
      saveButtonVisible: saveButton.length > 0,
      saveButtonEnabled: saveButton.some((item) => !item.disabled),
      saveSuccessVisible: descriptions.some((item) =>
        /Saved \d+ px\. This encrypted preference will sync/i.test(item.text)),
      saveFailureVisible: descriptions.some((item) =>
        /Could not save terminal font size/i.test(item.text)),
      preferenceErrorVisible: descriptions.some((item) =>
        /Vault preference data needs attention|preference.*duplicate|repair state.*cannot be verified/i
          .test(item.text)),
      defaultSectionConflictVisible: descriptions.some((item) =>
        /Choose the default preference record to keep/i.test(item.text)),
      fontSizeConflictVisible: descriptions.some((item) =>
        /Choose the terminal font-size record to keep/i.test(item.text)),
      readOnlyVaultVisible: descriptions.some((item) =>
        /This Vault is read-only/i.test(item.text)),
    };
  }, expectedFontSize).catch(() => ({ diagnosticUnavailable: true }));
}

function safeApiSummary(entries, limit = 20) {
  return entries.slice(-limit).map(({ profile, method, path: apiPath, status, errorCode }) => ({
    profile,
    method,
    path: apiPath.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi, '/{id}'),
    status,
    errorCode,
  }));
}

function pageErrorCategory(error) {
  const message = String(error?.message || '').toLowerCase();
  if (/disposed|deactivated/.test(message)) return 'widget-lifecycle';
  if (/setstate/.test(message)) return 'set-state';
  if (/assertion/.test(message)) return 'assertion';
  if (/typeerror/.test(message)) return 'type-error';
  if (/referenceerror/.test(message)) return 'reference-error';
  return 'runtime-error';
}

function serverVersionCountForDevice(databasePath, deviceId) {
  assertThat(
    typeof deviceId === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(deviceId),
    'device snapshot did not contain a canonical device ID',
  );
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "count=db.execute('SELECT COUNT(*) FROM record_versions WHERE device_id=?',(sys.argv[2],)).fetchone()[0]",
    "print(json.dumps({'count':count}))",
  ].join(';'), databasePath, deviceId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server record-state inspection failed');
  try {
    const summary = JSON.parse(result.stdout);
    assertThat(Number.isSafeInteger(summary.count) && summary.count >= 0,
      'server record-state inspection returned an invalid count');
    return summary.count;
  } catch (_) {
    throw new Error('server record-state inspection returned invalid data');
  }
}

function serverCredentialSnapshot(databasePath, vaultId, expectedOperations, markers) {
  assertThat(typeof vaultId === 'string' && Array.isArray(expectedOperations) &&
    expectedOperations.length >= 2 && Array.isArray(markers),
  'credential server snapshot is missing its Vault, operations, or markers');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault=sys.argv[2]',
    'check=json.loads(sys.stdin.read())',
    'expected=check[\'operations\']',
    'markers=check[\'markers\']',
    'record_ids=sorted(set(item[\'recordId\'] for item in expected))',
    'allowed_header={\'wire_version\',\'server_space_id\',\'vault_id\',\'record_id\',\'revision_id\',\'base_revision_id\',\'op_id\',\'device_id\',\'device_seq\',\'key_epoch\',\'membership_version\',\'record_schema\',\'operation\',\'crypto_suite\',\'kdf_salt\',\'object_refs\'}',
    'records=[]',
    'for record_id in record_ids:',
    "    rows=db.execute('SELECT revision_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record_id)).fetchall()",
    "    head=db.execute('SELECT revision_id,deleted FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record_id)).fetchone()",
    "    events=db.execute('SELECT revision_id FROM change_events WHERE vault_id=? AND record_id=?',(vault,record_id)).fetchall()",
    '    operations=[]',
    '    envelopes_valid=True',
    '    marker_found=False',
    '    for revision,operation,envelope_text in rows:',
    '        try: envelope=json.loads(envelope_text)',
    '        except Exception: envelope={}',
    "        header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
    "        envelopes_valid = envelopes_valid and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(envelope.get(key),str) and len(envelope.get(key))>0 for key in ('nonce','ciphertext','signature'))",
    '        marker_found = marker_found or any(marker and marker in envelope_text for marker in markers)',
    '        op_id=header.get(\'op_id\') if isinstance(header,dict) else None',
    "        receipts=db.execute('SELECT record_id,revision_id FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall() if op_id else []",
    "        operations.append({'revisionId':revision,'operation':operation,'headerOperation':header.get('operation') if isinstance(header,dict) else None,'opId':op_id,'receiptCount':len(receipts),'receiptMatches':len(receipts)==1 and receipts[0][0]==record_id and receipts[0][1]==revision,'revisionEventCount':sum(1 for event in events if event[0]==revision),'envelopeShapeValid':bool(envelopes_valid)})",
    "    graveyard=db.execute('SELECT deleted_revision FROM record_graveyard WHERE vault_id=? AND record_id=?',(vault,record_id)).fetchone()",
    "    records.append({'recordId':record_id,'versionCount':len(rows),'operations':operations,'eventCount':len(events),'headRevisionId':head[0] if head else None,'headDeleted':bool(head and head[1]),'graveyardRevisionId':graveyard[0] if graveyard else None,'allEnvelopesCiphertextOnly':envelopes_valid,'plaintextMarkerFound':marker_found})",
    "print(json.dumps({'records':records}))",
  ].join('\n'), databasePath, vaultId], {
    encoding: 'utf8',
    timeout: 8000,
    input: JSON.stringify({ operations: expectedOperations, markers }),
  });
  assertThat(result.status === 0, 'credential server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('credential server-state inspection returned invalid data');
  }
}

function serverCredentialRevisionFeedSnapshot(
  databasePath, vaultId, recordId, revisionId,
) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault,record,revision=sys.argv[2:5]',
    "versions=db.execute('SELECT commit_seq FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchall()",
    "events=db.execute('SELECT commit_seq FROM change_events WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchall()",
    "receipts=db.execute('SELECT commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchall()",
    "head=db.execute('SELECT revision_id FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "maximum=db.execute('SELECT MAX(commit_seq) FROM change_events WHERE vault_id=?',(vault,)).fetchone()[0]",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()[0]",
    "print(json.dumps({'versionCount':len(versions),'versionCommitSeqs':[str(row[0]) for row in versions],'eventCount':len(events),'eventCommitSeqs':[str(row[0]) for row in events],'receiptCount':len(receipts),'receiptCommitSeqs':[str(row[0]) for row in receipts],'headMatches':bool(head and head[0]==revision),'vaultMaxChangeSeq':str(maximum) if maximum is not None else None,'vaultCounterSeq':str(counter)}))",
  ].join('\n'), databasePath, vaultId, recordId, revisionId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  if (result.status !== 0) return { querySucceeded: false };
  try {
    return { querySucceeded: true, ...JSON.parse(result.stdout) };
  } catch (_) {
    return { querySucceeded: false };
  }
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function syncOperationSummary(body) {
  const operations = Array.isArray(body?.operations) ? body.operations : [];
  const summaries = operations.map((envelope) => {
    const header = envelope?.header || {};
    return {
      opId: header.op_id,
      revisionId: header.revision_id,
      recordId: header.record_id,
      deviceId: header.device_id,
      deviceSeq: header.device_seq,
      operation: header.operation,
      envelopeSha256: crypto.createHash('sha256')
        .update(stableJson(envelope))
        .digest('hex'),
    };
  });
  if (summaries.length !== 1) {
    return { operationCount: summaries.length, operations: summaries };
  }
  const [summary] = summaries;
  return { operationCount: 1, ...summary };
}

function safeCredentialEnvelopeSummary(envelope, markers) {
  const header = envelope?.header || {};
  const envelopeKeys = Object.keys(envelope || {}).sort();
  const allowedEnvelopeKeys = ['ciphertext', 'header', 'nonce', 'signature'];
  const allowedHeaderKeys = new Set([
    'wire_version', 'server_space_id', 'vault_id', 'record_id',
    'revision_id', 'base_revision_id', 'op_id', 'device_id', 'device_seq',
    'key_epoch', 'membership_version', 'record_schema', 'operation',
    'crypto_suite', 'kdf_salt', 'object_refs',
  ]);
  const serialized = stableJson(envelope);
  const validEncodedFields = ['nonce', 'ciphertext', 'signature'].every((key) =>
    typeof envelope?.[key] === 'string' &&
    /^[A-Za-z0-9_-]+$/.test(envelope[key]));
  return {
    ...syncOperationSummary({ operations: [envelope] }),
    exactEnvelopeShape: JSON.stringify(envelopeKeys) === JSON.stringify(allowedEnvelopeKeys),
    metadataOnlyHeader: Object.keys(header).every((key) => allowedHeaderKeys.has(key)),
    encodedCiphertextFields: validEncodedFields,
    plaintextMarkersAbsent: markers.every((marker) =>
      typeof marker === 'string' && marker.length > 0 && !serialized.includes(marker)),
  };
}

function serverVaultSnapshot(databasePath, username) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "rows=db.execute(\"SELECT v.vault_id,COALESCE(vc.last_committed_seq,0),v.active_epoch,v.membership_version FROM users u JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' JOIN vaults v ON v.vault_id=vm.vault_id LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE u.username=? AND v.state='active' ORDER BY v.vault_id\",(sys.argv[2],)).fetchall()",
    "print(json.dumps({'vaults':[{'vaultId':row[0],'commitSeq':str(row[1]),'activeKeyEpoch':str(row[2]),'membershipVersion':str(row[3])} for row in rows]}))",
  ].join(';'), databasePath, username], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server vault snapshot inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('server vault snapshot inspection returned invalid data');
  }
}

function serverVaultPreferenceSnapshot(
  databasePath,
  vaultId,
  operation,
  markers,
  { expectedDeleted = false } = {},
) {
  assertThat(typeof vaultId === 'string' && vaultId.length > 0 &&
    typeof operation?.recordId === 'string' &&
    typeof operation?.revisionId === 'string' &&
    typeof operation?.opId === 'string' && Array.isArray(markers),
  'Vault preference snapshot is missing its Vault, operation, or markers');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault,record,revision,op_id,expected_operation,expected_deleted=sys.argv[2:]',
    'markers=json.loads(sys.stdin.read())',
    "rows=db.execute('SELECT revision_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "receipt=db.execute('SELECT record_id,revision_id FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall()",
    'allowed_header={\'wire_version\',\'server_space_id\',\'vault_id\',\'record_id\',\'revision_id\',\'base_revision_id\',\'op_id\',\'device_id\',\'device_seq\',\'key_epoch\',\'membership_version\',\'record_schema\',\'operation\',\'crypto_suite\',\'kdf_salt\',\'object_refs\'}',
    "envelopes=[row[2] for row in rows]+[row[1] for row in events]",
    'parsed=[]',
    'for text in envelopes:',
    '    try: value=json.loads(text)',
    '    except Exception: value={}',
    "    header=value.get('header',{}) if isinstance(value,dict) else {}",
    "    fields_valid=isinstance(value,dict) and set(value)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(value.get(key),str) and __import__('re').fullmatch(r'[A-Za-z0-9_-]+',value[key]) for key in ('nonce','ciphertext','signature'))",
    "    parsed.append({'fieldsValid':bool(fields_valid),'headerMetadataOnly':isinstance(header,dict) and set(header).issubset(allowed_header),'plaintextMarkersAbsent':not any(marker in text for marker in markers)})",
    "matching_events=[row for row in events if row[0]==revision and json.loads(row[1]).get('header',{}).get('operation')==expected_operation]",
    "print(json.dumps({'versionCount':len(rows),'revisionVersionCount':sum(1 for row in rows if row[0]==revision),'createOperationCount':sum(1 for row in rows if row[0]==revision and row[1]=='create'),'operationCount':sum(1 for row in rows if row[0]==revision and row[1]==expected_operation),'eventTotalCount':len(events),'eventCount':len(matching_events),'envelopes':parsed,'receiptCount':len(receipt),'receiptMatches':len(receipt)==1 and receipt[0][0]==record and receipt[0][1]==revision,'headCount':1 if head else 0,'headRevisionMatches':bool(head) and head[0]==revision,'headDeleted':bool(head[1]) if head else None,'headCommitSeq':str(head[2]) if head else None,'headMatches':bool(head) and head[0]==revision and bool(head[1])==(expected_deleted=='true')}))",
  ].join('\n'), databasePath, vaultId, operation.recordId,
  operation.revisionId, operation.opId, operation.operation,
  String(expectedDeleted)], {
    encoding: 'utf8',
    timeout: 8000,
    input: JSON.stringify(markers),
  });
  assertThat(result.status === 0, 'Vault preference server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Vault preference server-state inspection returned invalid data');
  }
}

function serverVaultPreferenceLifecycleSnapshot(databasePath, vaultId, recordId) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'db.execute("PRAGMA query_only=ON")',
    'vault,record=sys.argv[2:4]',
    "versions=db.execute('SELECT revision_id,operation,commit_seq,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id,event_type,commit_seq,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "receipts=db.execute('SELECT op_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "graveyard=db.execute('SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    'def op_id(text):',
    '    try: return json.loads(text).get("header",{}).get("op_id")',
    '    except Exception: return None',
    'print(json.dumps({',
    '  "vaultCommitSeq":str(counter[0]) if counter else None,',
    '  "versions":[{"revisionId":row[0],"operation":row[1],"commitSeq":str(row[2]),"opId":op_id(row[3])} for row in versions],',
    '  "events":[{"revisionId":row[0],"operation":row[1],"commitSeq":str(row[2]),"opId":op_id(row[3])} for row in events],',
    '  "receipts":[{"opId":row[0],"revisionId":row[1],"commitSeq":str(row[2])} for row in receipts],',
    '  "head":{"revisionId":head[0],"deleted":bool(head[1]),"commitSeq":str(head[2])} if head else None,',
    '  "graveyard":{"revisionId":graveyard[0],"commitSeq":str(graveyard[1])} if graveyard else None',
  '},separators=(",",":")))',
  ].join('\n'), databasePath, vaultId, recordId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0,
    'Vault preference lifecycle snapshot inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Vault preference lifecycle snapshot was invalid');
  }
}

function serverVaultSnippetSnapshot(databasePath, vaultId, operation, markers) {
  assertThat(typeof vaultId === 'string' && vaultId.length > 0 &&
    typeof operation?.recordId === 'string' &&
    typeof operation?.revisionId === 'string' &&
    typeof operation?.opId === 'string' && Array.isArray(markers) &&
    markers.length >= 4,
  'Snippet server snapshot is missing its Vault, operation, or markers');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys,re,hashlib',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault,record,revision,op_id=sys.argv[2:]',
    'markers=json.loads(sys.stdin.read())',
    "versions=db.execute('SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id,envelope,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "receipts=db.execute('SELECT record_id,revision_id FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall()",
    "allowed_header={'wire_version','server_space_id','vault_id','record_id','revision_id','base_revision_id','op_id','device_id','device_seq','key_epoch','membership_version','record_schema','operation','crypto_suite','kdf_salt','object_refs'}",
    'def inspect(text):',
    '    try: value=json.loads(text)',
    '    except Exception: value={}',
    "    header=value.get('header',{}) if isinstance(value,dict) else {}",
    "    fields_valid=isinstance(value,dict) and set(value)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(value.get(key),str) and re.fullmatch(r'[A-Za-z0-9_-]+',value[key]) for key in ('nonce','ciphertext','signature'))",
    "    identity_matches=isinstance(header,dict) and header.get('record_id')==record and header.get('revision_id')==revision and header.get('op_id')==op_id and header.get('operation')=='create'",
    "    return {'fieldsValid':bool(fields_valid),'identityMatches':bool(identity_matches),'plaintextMarkersAbsent':not any(marker in text for marker in markers)}",
    'def stable(value):',
    '    if isinstance(value,dict): return \'{\'+\',\'.join(json.dumps(key,ensure_ascii=False,separators=(\',\',\':\'))+\':\'+stable(value[key]) for key in sorted(value))+\'}\'',
    '    if isinstance(value,list): return \'[\'+\',\'.join(stable(item) for item in value)+\']\'',
    '    return json.dumps(value,ensure_ascii=False,separators=(\',\',\':\'))',
    'def envelope_hash(text):',
    '    try: value=json.loads(text)',
    '    except Exception: return None',
    "    return hashlib.sha256(stable(value).encode('utf-8')).hexdigest()",
    'matching_versions=[row for row in versions if row[0]==revision and row[1]==\'create\']',
    'matching_events=[row for row in events if row[0]==revision]',
    "version_summary=inspect(matching_versions[0][2]) if matching_versions else {'fieldsValid':False,'identityMatches':False,'plaintextMarkersAbsent':False}",
    "event_summary=inspect(matching_events[0][1]) if matching_events else {'fieldsValid':False,'identityMatches':False,'plaintextMarkersAbsent':False}",
    "print(json.dumps({'versionCount':len(versions),'matchingVersionCount':len(matching_versions),'eventCount':len(events),'matchingEventCount':len(matching_events),'versionEnvelope':version_summary,'eventEnvelope':event_summary,'versionEnvelopeSha256':envelope_hash(matching_versions[0][2]) if matching_versions else None,'eventEnvelopeSha256':envelope_hash(matching_events[0][1]) if matching_events else None,'receiptCount':len(receipts),'receiptMatches':len(receipts)==1 and receipts[0][0]==record and receipts[0][1]==revision,'headMatches':bool(head) and head[0]==revision and not head[1] and bool(matching_versions) and head[2]==matching_versions[0][3],'commitSeqMatches':bool(matching_versions) and bool(matching_events) and matching_versions[0][3]==matching_events[0][2]}))",
  ].join('\n'), databasePath, vaultId, operation.recordId,
  operation.revisionId, operation.opId], {
    encoding: 'utf8',
    timeout: 8000,
    input: JSON.stringify(markers),
  });
  assertThat(result.status === 0, 'Snippet server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Snippet server-state inspection returned invalid data');
  }
}

function serverVaultGroupSnapshot(databasePath, vaultId, operations, markers) {
  assertThat(typeof vaultId === 'string' && vaultId.length > 0 &&
    Array.isArray(operations) && operations.length >= 1 &&
    operations.every((item) => item && typeof item.recordId === 'string' &&
      typeof item.revisionId === 'string' && typeof item.opId === 'string' &&
      ['create', 'update', 'delete'].includes(item.operation)) &&
    Array.isArray(markers),
  'Vault Group snapshot is missing its Vault, operations, or markers');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys,re',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault=sys.argv[2]',
    'expected=json.loads(sys.argv[3])',
    'markers=json.loads(sys.stdin.read())',
    "allowed_header={'wire_version','server_space_id','vault_id','record_id','revision_id','base_revision_id','op_id','device_id','device_seq','key_epoch','membership_version','record_schema','operation','crypto_suite','kdf_salt','object_refs'}",
    'checks=[]',
    'record_ids=sorted({item[\'recordId\'] for item in expected})',
    'envelopes=[]',
    'heads=[]',
    'for record in record_ids:',
    "    rows=db.execute('SELECT revision_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "    events=db.execute('SELECT revision_id,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "    head=db.execute('SELECT revision_id,deleted FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    '    for row in rows: envelopes.append(row[2])',
    '    for event in events: envelopes.append(event[1])',
    "    latest=next((item for item in reversed(expected) if item['recordId']==record),None)",
    "    expected_deleted=latest['operation']=='delete'",
    "    heads.append({'recordId':record,'versionCount':len(rows),'eventCount':len(events),'deleted':bool(head[1]) if head else None,'headMatches':bool(head) and head[0]==latest['revisionId'] and bool(head[1])==expected_deleted})",
    'for item in expected:',
    "    receipts=db.execute('SELECT record_id,revision_id FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,item['opId'])).fetchall()",
    "    versions=db.execute('SELECT revision_id,operation,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,item['recordId'])).fetchall()",
    "    events=db.execute('SELECT revision_id,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,item['recordId'])).fetchall()",
    "    matching_versions=[row for row in versions if row[0]==item['revisionId'] and row[1]==item['operation']]",
    "    matching_events=[row for row in events if row[0]==item['revisionId']]",
    "    version_header=json.loads(matching_versions[0][2]).get('header',{}) if matching_versions else {}",
    "    event_header=json.loads(matching_events[0][1]).get('header',{}) if matching_events else {}",
    "    version_envelope_matches=version_header.get('record_id')==item['recordId'] and version_header.get('revision_id')==item['revisionId'] and version_header.get('op_id')==item['opId'] and version_header.get('operation')==item['operation']",
    "    event_envelope_matches=event_header.get('record_id')==item['recordId'] and event_header.get('revision_id')==item['revisionId'] and event_header.get('op_id')==item['opId'] and event_header.get('operation')==item['operation']",
    "    checks.append({'opId':item['opId'],'recordId':item['recordId'],'revisionId':item['revisionId'],'operation':item['operation'],'receiptMatches':len(receipts)==1 and receipts[0][0]==item['recordId'] and receipts[0][1]==item['revisionId'],'versionMatches':len(matching_versions)==1,'eventMatches':len(matching_events)==1,'versionEnvelopeMatches':version_envelope_matches,'eventEnvelopeMatches':event_envelope_matches})",
    'parsed=[]',
    'for text in envelopes:',
    '    try: value=json.loads(text)',
    '    except Exception: value={}',
    "    header=value.get('header',{}) if isinstance(value,dict) else {}",
    "    fields_valid=isinstance(value,dict) and set(value)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(value.get(key),str) and re.fullmatch(r'[A-Za-z0-9_-]+',value[key]) for key in ('nonce','ciphertext','signature'))",
    "    parsed.append({'fieldsValid':bool(fields_valid),'headerMetadataOnly':isinstance(header,dict) and set(header).issubset(allowed_header),'plaintextMarkersAbsent':not any(marker in text for marker in markers)})",
    "print(json.dumps({'checks':checks,'heads':heads,'envelopeCount':len(envelopes),'envelopes':parsed}))",
  ].join('\n'), databasePath, vaultId, JSON.stringify(operations)], {
    encoding: 'utf8',
    timeout: 8000,
    input: JSON.stringify(markers),
  });
  assertThat(result.status === 0, 'Vault Group server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Vault Group server-state inspection returned invalid data');
  }
}

function serverDatabasePlaintextMarkers(databasePath, markers) {
  const files = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`];
  const contents = files.filter((file) => fs.existsSync(file))
    .map((file) => fs.readFileSync(file));
  const combined = Buffer.concat(contents);
  return markers.filter((marker) => combined.includes(Buffer.from(marker)));
}

function serverLogPlaintextMarkerEvidence(logPath, markers) {
  let contents;
  try {
    contents = fs.readFileSync(logPath);
  } catch (_) {
    return { available: false, markerAbsent: false, byteLength: null };
  }
  return {
    available: true,
    markerAbsent: markers.every((marker) =>
      !contents.includes(Buffer.from(marker))),
    byteLength: contents.length,
  };
}

function serverCredentialResolutionSnapshot(databasePath, vaultId, conflictIds) {
  assertThat(typeof vaultId === 'string' && Array.isArray(conflictIds) &&
    conflictIds.length > 0 && conflictIds.every((id) => typeof id === 'string'),
  'Credential conflict-resolution inspection is missing identifiers');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault=sys.argv[2]',
    'ids=json.loads(sys.stdin.read())',
    'rows=[]',
    'for conflict_id in ids:',
    "    conflict=db.execute('SELECT resolved_revision_id FROM conflicts WHERE vault_id=? AND conflict_id=?',(vault,conflict_id)).fetchall()",
    "    audit=db.execute(\"SELECT actor_user_id,actor_device_id,result,source FROM audit_events WHERE scope_type='vault' AND scope_id=? AND action='vault.conflict_resolved' AND resource_type='conflict' AND resource_id=?\",(vault,conflict_id)).fetchall()",
    "    rows.append({'conflictRowCount':len(conflict),'resolvedRevisionId':conflict[0][0] if conflict else None,'resolutionAuditCount':len(audit),'resolutionAuditSuccessCount':sum(1 for row in audit if row[2]=='success' and row[3]=='api'),'resolutionAuditActorPresent':bool(audit and audit[0][0] and audit[0][1])})",
    "print(json.dumps({'conflicts':rows}))",
  ].join('\n'), databasePath, vaultId], {
    encoding: 'utf8',
    timeout: 8000,
    input: JSON.stringify(conflictIds),
  });
  assertThat(result.status === 0,
    'Credential conflict-resolution inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Credential conflict-resolution inspection returned invalid data');
  }
}

function serverMultiTabSnapshot(databasePath, vaultId, deviceId, operations, baselineCommitSeq) {
  assertThat(typeof vaultId === 'string' && vaultId.length > 0 &&
    typeof deviceId === 'string' && deviceId.length > 0 &&
    Array.isArray(operations) && operations.length === 2 &&
    operations.every((item) => item && typeof item.opId === 'string' &&
      typeof item.recordId === 'string' && typeof item.revisionId === 'string' &&
      typeof item.deviceSeq === 'string'),
  'multi-tab server snapshot is missing operation identities');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault,device,baseline,operations_json=sys.argv[2:]',
    'expected=json.loads(operations_json)',
    'items=[]',
    'for item in expected:',
    "    op_id,record_id,revision_id,device_seq=item['opId'],item['recordId'],item['revisionId'],item['deviceSeq']",
    "    receipts=db.execute('SELECT device_id,device_seq,record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall()",
    "    versions=db.execute('SELECT revision_id,envelope FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record_id)).fetchall()",
    "    events=db.execute('SELECT revision_id FROM change_events WHERE vault_id=? AND record_id=?',(vault,record_id)).fetchall()",
    "    head=db.execute('SELECT revision_id,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record_id)).fetchall()",
    "    version_header=json.loads(versions[0][1]).get('header',{}) if versions else {}",
    "    items.append({'opId':op_id,'receiptCount':len(receipts),'receiptMatches':bool(receipts) and receipts[0][0]==device and receipts[0][1]==device_seq and receipts[0][2]==record_id and receipts[0][3]==revision_id,'recordVersionCount':len(versions),'revisionVersionCount':sum(1 for row in versions if row[0]==revision_id),'versionOpMatches':version_header.get('op_id')==op_id and version_header.get('device_seq')==device_seq,'changeEventCount':len(events),'revisionEventCount':sum(1 for row in events if row[0]==revision_id),'headCount':len(head),'headMatches':bool(head) and head[0][0]==revision_id})",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    "sequence_receipts=db.execute('SELECT device_seq FROM op_receipts WHERE vault_id=? AND device_id=? AND device_seq IN (?,?)',(vault,device,expected[0]['deviceSeq'],expected[1]['deviceSeq'])).fetchall()",
    "print(json.dumps({'items':items,'baselineCommitSeq':baseline,'finalCommitSeq':str(counter[0]) if counter else None,'matchingDeviceSequenceReceiptCount':len(sequence_receipts),'matchingDeviceSequences':[row[0] for row in sequence_receipts]}))",
  ].join('\n'), databasePath, vaultId, deviceId, String(baselineCommitSeq), JSON.stringify(operations)], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'multi-tab server operation inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('multi-tab server operation inspection returned invalid data');
  }
}

function serverOutboxSnapshot(databasePath, request, firstBatchId, replayBatchId) {
  for (const [label, value] of Object.entries({
    vaultId: request?.vaultId,
    deviceId: request?.deviceId,
    opId: request?.opId,
    recordId: request?.recordId,
    revisionId: request?.revisionId,
    firstBatchId,
    replayBatchId,
  })) {
    assertThat(typeof value === 'string' && value.length > 0,
      `outbox snapshot is missing ${label}`);
  }
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'vault,device,op,record,revision,first_batch,replay_batch=sys.argv[2:]',
    "receipt=db.execute('SELECT revision_id,commit_seq,record_id FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op)).fetchall()",
    "versions=db.execute('SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()[0]",
    "revision_versions=db.execute('SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchone()[0]",
    "events=db.execute('SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchone()[0]",
    "batches=db.execute('SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id IN (?,?)',(vault,device,first_batch,replay_batch)).fetchone()[0]",
    "counter=db.execute('SELECT last_committed_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    "print(json.dumps({'receiptCount':len(receipt),'receipt':({'revisionId':receipt[0][0],'commitSeq':str(receipt[0][1]),'recordId':receipt[0][2]} if receipt else None),'recordVersionCount':versions,'revisionVersionCount':revision_versions,'changeEventCount':events,'batchReceiptCount':batches,'vaultCommitSeq':str(counter[0]) if counter else None}))",
  ].join(';'), databasePath, request.vaultId, request.deviceId,
  request.opId, request.recordId, request.revisionId, firstBatchId, replayBatchId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server outbox idempotency inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('server outbox idempotency inspection returned invalid data');
  }
}

function ageVaultChangeHistory(databasePath, vaultId) {
  assertThat(typeof vaultId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(vaultId),
  'long-offline fixture is missing a canonical Vault ID');
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=rw',uri=True,timeout=10)",
    "changed=db.execute(\"UPDATE change_events SET created_at='2000-01-01T00:00:00+00:00' WHERE vault_id=?\",(sys.argv[2],)).rowcount",
    'db.commit()',
    "print(json.dumps({'agedEventCount':changed}))",
  ].join(';'), databasePath, vaultId], {
    encoding: 'utf8',
    timeout: 12000,
  });
  assertThat(result.status === 0, 'long-offline fixture could not age its isolated change history');
  try {
    const summary = JSON.parse(result.stdout);
    assertThat(Number.isSafeInteger(summary.agedEventCount) && summary.agedEventCount > 0,
      'long-offline fixture did not age any change events');
    return summary.agedEventCount;
  } catch (_) {
    throw new Error('long-offline fixture returned invalid maintenance input data');
  }
}

function serverLongOfflineSnapshot(databasePath, vaultId, recordId, branch = null) {
  assertThat(typeof vaultId === 'string' && typeof recordId === 'string',
    'long-offline server inspection is missing record identity');
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,record,branch_json=sys.argv[2:]',
    'branch=json.loads(branch_json)',
    "counter=db.execute('SELECT last_committed_seq,minimum_available_seq,last_conflict_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    "head=db.execute('SELECT revision_id,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    "versions=db.execute('SELECT revision_id FROM record_versions WHERE vault_id=? AND record_id=?',(vault,record)).fetchall()",
    "events=db.execute('SELECT revision_id FROM change_events WHERE vault_id=? AND record_id=?',(vault,record)).fetchall()",
    "all_events=db.execute('SELECT COUNT(*) FROM change_events WHERE vault_id=?',(vault,)).fetchone()[0]",
    "op_id=branch.get('opId') or ''",
    "stale_revision=branch.get('revisionId') or ''",
    "receipts=db.execute('SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchone()[0] if op_id else 0",
    "stale_versions=db.execute('SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,stale_revision)).fetchone()[0] if stale_revision else 0",
    "stale_events=db.execute('SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,stale_revision)).fetchone()[0] if stale_revision else 0",
    "conflict_rows=db.execute('SELECT record_id,base_revision_id,device_id,envelope,resolved_revision_id FROM conflicts WHERE vault_id=? AND op_id=?',(vault,op_id)).fetchall() if op_id else []",
    "conflict_matches=[]",
    "for row in conflict_rows:",
    "    try: header=json.loads(row[3]).get('header',{})",
    "    except Exception: header={}",
    "    try: envelope=json.loads(row[3])",
    "    except Exception: envelope={}",
    "    allowed_header={'wire_version','server_space_id','vault_id','record_id','revision_id','base_revision_id','op_id','device_id','device_seq','key_epoch','membership_version','record_schema','operation','crypto_suite','kdf_salt','object_refs'}",
    "    encoded_fields=all(isinstance(envelope.get(key),str) and len(envelope[key])>0 and all(char.isalnum() or char in '-_' for char in envelope[key]) for key in ('nonce','ciphertext','signature'))",
    "    shape_valid=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(envelope.get('header'),dict) and set(envelope['header']).issubset(allowed_header) and encoded_fields",
    "    canonical=json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()",
    "    envelope_hash=hashlib.sha256(canonical).hexdigest()",
    "    marker_absent=not any(marker.encode() in row[3].encode() for marker in branch.get('markers',[]))",
    "    conflict_matches.append(row[0]==record and row[1]==branch.get('baseRevisionId') and row[2]==branch.get('deviceId') and header.get('op_id')==op_id and header.get('revision_id')==stale_revision and header.get('device_id')==row[2] and shape_valid and marker_absent and (not branch.get('envelopeSha256') or envelope_hash==branch.get('envelopeSha256'))) ",
    "resolved_matches=[row[4]==branch.get('resolvedRevisionId') for row in conflict_rows]",
    "print(json.dumps({'lastCommittedSeq':str(counter[0]) if counter else None,'minimumAvailableSeq':str(counter[1]) if counter else None,'lastConflictSeq':str(counter[2]) if counter else None,'headRevisionId':head[0] if head else None,'headCommitSeq':str(head[1]) if head else None,'recordVersionCount':len(versions),'staleRevisionVersionCount':stale_versions,'recordChangeEventCount':len(events),'staleRevisionEventCount':stale_events,'vaultChangeEventCount':all_events,'staleOperationReceiptCount':receipts,'matchingConflictCount':len(conflict_rows),'matchingConflictEnvelopeCount':sum(1 for match in conflict_matches if match),'matchingResolvedConflictCount':sum(1 for match in resolved_matches if match)}))",
  ].join('\n'), databasePath, vaultId, recordId, JSON.stringify(branch || {})], {
    encoding: 'utf8',
    timeout: 12000,
  });
  assertThat(result.status === 0, 'long-offline server state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('long-offline server state inspection returned invalid data');
  }
}

function serverAttachmentSnapshot(databasePath, vaultId, recordId, revisionId, objectId) {
  for (const [label, value] of Object.entries({
    vaultId, recordId, revisionId, objectId,
  })) {
    assertThat(typeof value === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value),
    `attachment snapshot is missing a canonical ${label}`);
  }
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    `db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)`,
    'vault,record,revision,object_id=sys.argv[2:]',
    `versions=db.execute('SELECT envelope FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,record,revision)).fetchall()`,
    `refs=db.execute('SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=? AND object_id=?',(vault,revision,object_id)).fetchone()[0]`,
    `blob=db.execute('SELECT bytes,sha256,size FROM blob_objects WHERE vault_id=? AND object_id=?',(vault,object_id)).fetchone()`,
    `header=json.loads(versions[0][0]).get('header',{}) if versions else {}`,
    `body=blob[0] if blob else b''`,
    `print(json.dumps({'revisionCount':len(versions),'referenceCount':refs,'headerHasObjectRef':object_id in header.get('object_refs',[]),'objectPresent':blob is not None,'objectByteLength':len(body),'objectSizeMatches':bool(blob) and len(body)==blob[2],'objectDigestMatches':bool(blob) and hashlib.sha256(body).hexdigest()==blob[1]}))`,
  ].join(';'), databasePath, vaultId, recordId, revisionId, objectId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server attachment reference inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('server attachment reference inspection returned invalid data');
  }
}

function classifyArchiveFailure(error) {
  if (error?.archiveFailureClass) {
    return {
      failureClass: error.archiveFailureClass,
      uiErrorRegexFamily: error.uiErrorRegexFamily || null,
      safeErrorCategory: error.safeErrorCategory || null,
      archiveFailurePhase: error.archiveFailurePhase || null,
      progressCategoryCounts: error.progressCategoryCounts || {},
    };
  }
  if (error?.name === 'TimeoutError') {
    return { failureClass: 'locator-timeout', uiErrorRegexFamily: null, progressCategoryCounts: {} };
  }
  return { failureClass: 'other', uiErrorRegexFamily: null, progressCategoryCounts: {} };
}

function safeArchiveErrorCategory(lines, phaseCode = null) {
  const diagnosticText = lines.join('\n');
  const categories = [
    ['archive-password-integrity', /归档密码错误|完整性校验失败/i],
    ['archive-container', /归档头|归档文件大小|归档文件被截断|归档分块|分块长度|归档尾部|归档长度|不是受支持的 Atermius 加密归档/i],
    ['manifest-schema', /归档格式字段|归档字段类型|local_pending schema|清单格式|manifest/i],
    ['key-envelope', /key envelope|密钥信封/i],
    ['membership-trust', /membership|成员|设备信任|设备目录|签名链|签名无效/i],
    ['conflict-state', /conflict|冲突/i],
    ['local-outbox', /outbox|local_pending|device_seq|操作元数据|序列/i],
    ['revision-history', /revision|修订|base_revision|watermark|水位|snapshot|快照/i],
    ['encrypted-object', /object|对象|binary block|二进制/i],
  ];
  const messageCategory = categories.find(([, pattern]) =>
    pattern.test(diagnosticText))?.[0];
  if (messageCategory) return messageCategory;
  const phaseCategories = {
    decrypt_container: 'archive-container-decryption',
    read_manifest_blocks: 'archive-payload-decoding',
    validate_manifest: 'archive-manifest-validation',
    manifest_top_level: 'archive-manifest-top-level',
    manifest_identity: 'archive-manifest-identity',
    manifest_types: 'archive-manifest-types',
    manifest_snapshot: 'archive-manifest-snapshot',
    manifest_limits: 'archive-manifest-limits',
    manifest_heads: 'archive-manifest-snapshot-heads',
    manifest_revisions: 'archive-manifest-revisions',
    manifest_conflicts: 'archive-manifest-conflicts',
    manifest_devices: 'archive-manifest-devices',
    manifest_membership: 'archive-manifest-membership',
    manifest_outbox: 'archive-manifest-outbox',
    manifest_branches: 'archive-manifest-conflict-branches',
    membership_trust: 'membership-trust-validation',
    key_envelope_epoch: 'key-envelope-epoch-validation',
    encrypted_objects: 'encrypted-object-validation',
    history_revisions: 'revision-history-validation',
    history_conflicts: 'conflict-history-validation',
    local_outbox_conflicts: 'local-outbox-conflict-validation',
    device_sequence_floors: 'device-sequence-floor-validation',
  };
  return phaseCategories[phaseCode] || 'format-exception-other';
}

function safeArchiveFailurePhase(lines) {
  const phaseLabels = [
    ['prepare', '准备验证'],
    ['decrypt_container', '解密归档容器'],
    ['read_manifest_blocks', '读取归档清单和 binary blocks'],
    ['validate_manifest', '验证归档格式和目标'],
    ['manifest_top_level', '检查归档 manifest 顶层字段'],
    ['manifest_identity', '检查归档 manifest 身份和角色'],
    ['manifest_types', '检查归档 manifest 字段类型'],
    ['manifest_snapshot', '检查归档 snapshot schema'],
    ['manifest_limits', '检查归档 manifest 条目上限'],
    ['manifest_heads', '检查归档 snapshot head 字段'],
    ['manifest_revisions', '检查归档 revision 字段'],
    ['manifest_conflicts', '检查归档 conflict 字段'],
    ['manifest_devices', '检查归档设备目录字段'],
    ['manifest_membership', '检查归档 membership 字段'],
    ['manifest_outbox', '检查归档 outbox 字段'],
    ['manifest_branches', '检查归档 conflict branch 字段'],
    ['membership_trust', '验证成员签名链和设备信任'],
    ['key_envelope_epoch', '验证归档 key envelope 和 epoch key'],
    ['encrypted_objects', '验证归档加密对象 block'],
    ['history_revisions', '验证归档历史 revisions'],
    ['history_conflicts', '验证归档历史 conflicts'],
    ['local_outbox_conflicts', '验证归档本地 outbox 和 conflict branches'],
    ['device_sequence_floors', '验证归档设备序列水位'],
  ];
  const text = lines.join('\n');
  return phaseLabels.find(([, label]) =>
    text.includes(`上次归档验证失败阶段：${label}`))?.[0] || null;
}

function safeArchiveContainerSummary(filePath) {
  const bytes = fs.readFileSync(filePath);
  const summary = {
    byteLength: bytes.length,
    magicMatches: bytes.length >= 12 && bytes.subarray(0, 8).toString('utf8') === 'ATVLTAR1',
    headerLengthValid: false,
    headerJsonValid: false,
    headerFieldsValid: false,
    chunkLayoutValid: false,
    chunkCount: 0,
    payloadLength: null,
  };
  if (!summary.magicMatches) return summary;
  const headerLength = bytes.readUInt32BE(8);
  const headerEnd = 12 + headerLength;
  summary.headerLengthValid = headerLength >= 2 && headerLength <= 64 * 1024 &&
    headerEnd <= bytes.length;
  if (!summary.headerLengthValid) return summary;
  let header;
  try {
    header = JSON.parse(bytes.subarray(12, headerEnd).toString('utf8'));
    summary.headerJsonValid = Boolean(header && typeof header === 'object' && !Array.isArray(header));
  } catch (_) {
    return summary;
  }
  const payloadLength = header.payload_length;
  const chunkSize = header.chunk_size;
  const declaredChunkCount = header.chunk_count;
  summary.payloadLength = Number.isSafeInteger(payloadLength) ? payloadLength : null;
  summary.headerFieldsValid = header.format === 'atermius-vault-archive' &&
    header.version === 1 && header.cipher_suite === 'xchacha20-poly1305-ietf' &&
    Number.isSafeInteger(payloadLength) && payloadLength > 0 &&
    chunkSize === 1024 * 1024 && Number.isSafeInteger(declaredChunkCount) &&
    declaredChunkCount === Math.ceil(payloadLength / chunkSize);
  if (!summary.headerFieldsValid) return summary;
  let offset = headerEnd;
  let totalClearLength = 0;
  let observedCount = 0;
  while (observedCount < declaredChunkCount && offset + 28 <= bytes.length) {
    const clearLength = bytes.readUInt32BE(offset);
    offset += 4 + 24;
    const expectedLength = Math.min(chunkSize, payloadLength - totalClearLength);
    if (clearLength !== expectedLength || clearLength <= 0 ||
        offset + clearLength + 16 > bytes.length) return summary;
    offset += clearLength + 16;
    totalClearLength += clearLength;
    observedCount += 1;
  }
  summary.chunkCount = observedCount;
  summary.chunkLayoutValid = observedCount === declaredChunkCount &&
    totalClearLength === payloadLength && offset === bytes.length;
  return summary;
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function clickMenuItem(page, label) {
  const collectEvidence = async () => page.evaluate((expected) => {
    const knownLabels = ['Edit group', 'Delete group'];
    const labelClass = (value) => {
      const normalized = String(value || '').replace(/\s+/g, ' ').trim().toLowerCase();
      return knownLabels.find((known) => normalized.includes(known.toLowerCase())) ||
        (normalized.length === 0 ? '' : 'other');
    };
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const collect = (element) => {
      const ariaLabel = element.getAttribute('aria-label') || '';
      const innerText = element.innerText || '';
      const textContent = element.textContent || '';
      const title = element.getAttribute('title') || '';
      const names = [ariaLabel, innerText, textContent, title];
      const rect = element.getBoundingClientRect();
      return {
        element,
        text: names.join(' ').replace(/\s+/g, ' ').trim(),
        rect,
        summary: {
          tag: element.tagName.toLowerCase(),
          role: element.getAttribute('role') || '',
          type: element.getAttribute('type') || '',
          ariaLabelClass: labelClass(ariaLabel),
          innerTextClass: labelClass(innerText),
          textContentClass: labelClass(textContent),
          titleClass: labelClass(title),
          ariaLabelLength: ariaLabel.length,
          innerTextLength: innerText.length,
          textContentLength: textContent.length,
          titleLength: title.length,
          ariaLabelMatchesExpected: ariaLabel.toLowerCase().includes(expected.toLowerCase()),
          innerTextMatchesExpected: innerText.toLowerCase().includes(expected.toLowerCase()),
          textContentMatchesExpected: textContent.toLowerCase().includes(expected.toLowerCase()),
          titleMatchesExpected: title.toLowerCase().includes(expected.toLowerCase()),
          boundingBox: {
            x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.width), height: Math.round(rect.height),
          },
          tabIndex: element.tabIndex,
          ariaDisabled: element.getAttribute('aria-disabled') === 'true',
        },
      };
    };
    const all = [...document.querySelectorAll('flt-semantics')].map(collect);
    const menuItems = all.filter((item) => item.summary.role === 'menuitem' &&
      item.rect.width > 0 && item.rect.height > 0);
    const options = all.filter((item) => item.summary.role === 'option' &&
      item.rect.width > 0 && item.rect.height > 0);
    const matching = [...menuItems, ...options]
      .filter((item) => item.text.toLowerCase().includes(expected.toLowerCase()))
      .sort((left, right) => left.text.length - right.text.length);
    const rect = matching[0]?.rect;
    return {
      menuItemNodeCount: all.filter((item) => item.summary.role === 'menuitem').length,
      optionNodeCount: all.filter((item) => item.summary.role === 'option').length,
      visibleMenuItemCount: menuItems.length,
      visibleOptionCount: options.length,
      matchingItemCount: matching.length,
      visibleMenuItemSummary: menuItems.map((item) => item.summary).slice(0, 8),
      visibleOptionSummary: options.map((item) => item.summary).slice(0, 8),
      visiblePopupRoleCounts: all.reduce((counts, item) => {
        if (item.rect.width > 0 && item.rect.height > 0) {
          const role = item.summary.role || 'unlabeled';
          counts[role] = (counts[role] || 0) + 1;
        }
        return counts;
      }, {}),
      point: rect == null ? null : {
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2,
      },
    };
  }, label).catch(() => ({
    visibleMenuItemCount: 0,
    visibleOptionCount: 0,
    matchingItemCount: 0,
    menuItemNodeCount: 0,
    optionNodeCount: 0,
    visibleMenuItemSummary: [],
    visibleOptionSummary: [],
    visiblePopupRoleCounts: {},
    point: null,
  }));
  let evidence = await collectEvidence();
  let anyMenuItem = page.getByRole('menuitem').first();
  if (evidence.menuItemNodeCount === 0 && evidence.optionNodeCount === 0) {
    await anyMenuItem.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
    evidence = await collectEvidence();
  }
  let interaction = 'semantic-center-click';
  if (evidence.point) {
    await page.mouse.click(evidence.point.x, evidence.point.y);
  } else {
    interaction = 'playwright-role-locator';
    const byRole = page.getByRole('menuitem', { name: label, exact: true }).last();
    await byRole.waitFor({ state: 'visible', timeout: 2500 }).catch(() => {});
    if (await byRole.isVisible().catch(() => false)) {
      await byRole.click();
    } else {
      const menuItemCount = await page.getByRole('menuitem').count().catch(() => 0);
      const requestedItemIndex = label === 'Edit group' ? 0 : 1;
      const indexedItem = page.getByRole('menuitem').nth(requestedItemIndex);
      if (menuItemCount > requestedItemIndex &&
          await indexedItem.isVisible().catch(() => false)) {
        interaction = 'indexed-menuitem-role-locator';
        await indexedItem.click();
      } else {
        interaction = 'playwright-text-locator';
        const byText = page.getByText(label, { exact: true }).last();
        await byText.waitFor({ state: 'visible', timeout: 2500 }).catch(() => {});
        if (await byText.isVisible().catch(() => false)) {
          await byText.click();
        } else {
          interaction = 'keyboard-menu-position';
          // PopupMenuItem order in Server Groups is Edit then Delete. Home/End
          // targets the requested item without relying on missing DOM text.
          await page.keyboard.press(label === 'Edit group' ? 'Home' : 'End');
          await page.keyboard.press('Enter');
        }
      }
    }
  }
  const result = {
    visibleMenuItemCount: evidence.visibleMenuItemCount,
    visibleOptionCount: evidence.visibleOptionCount,
    matchingItemCount: evidence.matchingItemCount,
    menuItemNodeCount: evidence.menuItemNodeCount,
    optionNodeCount: evidence.optionNodeCount,
    visibleMenuItemSummary: evidence.visibleMenuItemSummary,
    visibleOptionSummary: evidence.visibleOptionSummary,
    visiblePopupRoleCounts: evidence.visiblePopupRoleCounts,
    interaction,
  };
  if (interaction !== 'semantic-center-click') {
    console.log('WEB-GROUPS-MENU-SEMANTICS', JSON.stringify(result));
  }
  return result;
}

async function chooseDropdownOption(page, fieldLabel, optionLabel) {
  const escapedLabel = fieldLabel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const controls = page.getByRole('button', {
    name: new RegExp(escapedLabel, 'i'),
  });
  let control;
  for (let index = await controls.count() - 1; index >= 0; index -= 1) {
    const candidate = controls.nth(index);
    const candidateName = [
      await candidate.getAttribute('aria-label').catch(() => ''),
      await candidate.innerText().catch(() => ''),
    ].join(' ').replace(/\s+/g, ' ').trim();
    if (/^save\b/i.test(candidateName)) continue;
    if (await candidate.isVisible().catch(() => false) &&
        await candidate.isEnabled().catch(() => false)) {
      control = candidate;
      break;
    }
  }
  if (!control) {
    const target = await page.evaluate((label) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const matches = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((element) => visible(element) &&
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
            .toLowerCase().includes(label.toLowerCase()));
      const element = matches.at(-1);
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    }, fieldLabel).catch(() => null);
    if (!target) throw new Error(`visible dropdown not found: ${fieldLabel}`);
    await page.mouse.click(target.x, target.y);
  } else {
    await control.click();
  }

  const collectEvidence = async () => page.evaluate((expected) => {
    const isColor = (value) => /^#[0-9a-f]{6}$/i.test(value.trim());
    const optionClass = (value) => {
      const normalized = String(value || '').replace(/\s+/g, ' ').trim();
      if (normalized.length === 0) return '';
      if (isColor(normalized)) {
        return normalized.toLowerCase() === expected.toLowerCase()
          ? 'expected-color' : 'other-color';
      }
      if (normalized === 'Top-level group') return 'top-level-group';
      return 'other';
    };
    const nodes = [...document.querySelectorAll(
      'flt-semantics[role="menuitem"], flt-semantics[role="option"]',
    )].map((element) => {
      const rect = element.getBoundingClientRect();
      const ariaLabel = element.getAttribute('aria-label') || '';
      const innerText = element.innerText || '';
      const textContent = element.textContent || '';
      const title = element.getAttribute('title') || '';
      const names = [ariaLabel, innerText, textContent, title];
      const normalized = names.join(' ').replace(/\s+/g, ' ').trim();
      return {
        text: normalized,
        point: rect.width > 0 && rect.height > 0 ? {
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        } : null,
        summary: {
          role: element.getAttribute('role') || '',
          ariaLabelClass: optionClass(ariaLabel),
          innerTextClass: optionClass(innerText),
          textContentClass: optionClass(textContent),
          titleClass: optionClass(title),
          ariaLabelLength: ariaLabel.length,
          innerTextLength: innerText.length,
          textContentLength: textContent.length,
          matchesExpected: normalized.toLowerCase().includes(expected.toLowerCase()),
          boundingBox: {
            x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.width), height: Math.round(rect.height),
          },
        },
      };
    });
    const matching = nodes.filter((item) => item.point &&
      item.text.toLowerCase().includes(expected.toLowerCase()));
    matching.sort((left, right) => left.text.length - right.text.length);
    return {
      menuItemCount: nodes.filter((item) => item.summary.role === 'menuitem').length,
      optionCount: nodes.filter((item) => item.summary.role === 'option').length,
      matchingCount: matching.length,
      summaries: nodes.map((item) => item.summary).slice(0, 12),
      point: matching[0]?.point || null,
    };
  }, optionLabel).catch(() => ({
    menuItemCount: 0, optionCount: 0, matchingCount: 0, summaries: [], point: null,
  }));

  const menuSemantics = page.locator(
    'flt-semantics[role="menuitem"], flt-semantics[role="option"]',
  ).first();
  await menuSemantics.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
  let evidence = await collectEvidence();
  let interaction = 'semantic-center-click';
  let selectionTriggered = false;
  if (evidence.point) {
    await page.mouse.click(evidence.point.x, evidence.point.y);
    selectionTriggered = true;
  } else {
    interaction = 'playwright-role-locator';
    const roleCandidates = [
      page.getByRole('menuitem', { name: optionLabel, exact: true }).last(),
      page.getByRole('option', { name: optionLabel, exact: true }).last(),
    ];
    let selected = false;
    for (const candidate of roleCandidates) {
      await candidate.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
      if (await candidate.isVisible().catch(() => false)) {
        const box = await candidate.boundingBox().catch(() => null);
        if (box && box.width > 0 && box.height > 0) {
          interaction = 'playwright-role-target-center-click';
          await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
          selected = true;
        } else {
          await candidate.click();
          selected = true;
        }
        break;
      }
    }
    if (!selected) {
      interaction = 'playwright-text-locator';
      const textOption = page.getByText(optionLabel, { exact: true }).last();
      await textOption.waitFor({ state: 'visible', timeout: 5000 }).catch(() => {});
      if (await textOption.isVisible().catch(() => false)) {
        await textOption.click();
        selected = true;
      }
    }
    if (!selected) {
      evidence = await collectEvidence();
      if (/^#[0-9a-f]{6}$/i.test(optionLabel) && evidence.summaries.some((item) =>
        item.ariaLabelClass === 'expected-color' ||
        item.innerTextClass === 'expected-color' ||
        item.textContentClass === 'expected-color')) {
        const target = await page.evaluate((expected) => {
          const target = [...document.querySelectorAll('flt-semantics[role="menuitem"]')]
            .find((element) => {
              const rect = element.getBoundingClientRect();
              if (rect.width <= 0 || rect.height <= 0) return false;
              const text = `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
                .replace(/\s+/g, ' ').trim();
              return text.toLowerCase().includes(expected.toLowerCase());
            });
          if (!target) return null;
          const rect = target.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        }, optionLabel).catch(() => null);
        if (target) {
          interaction = 'color-option-semantic-center-click';
          await page.mouse.click(target.x, target.y);
          selected = true;
        }
      }
    }
    if (!selected) {
      if (/^#[0-9a-f]{6}$/i.test(optionLabel)) {
        console.log('WEB-GROUPS-COLOR-OPTION-DIAGNOSTIC', JSON.stringify({
          fieldKind: 'color',
          optionKind: 'hex-color',
          menuItemCount: evidence.menuItemCount,
          optionCount: evidence.optionCount,
          matchingCount: evidence.matchingCount,
          summaries: evidence.summaries,
        }));
      }
      throw new Error('visible dropdown option was unavailable after semantic and text waits');
    }
    selectionTriggered = selected;
  }
  const selectedField = async () => page.evaluate(({ expectedField, expectedValue }) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const optionNodeCount = [...document.querySelectorAll(
      'flt-semantics[role="menuitem"], flt-semantics[role="option"]',
    )].filter(visible).length;
    const controls = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((element) => `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''} ${element.getAttribute('title') || ''}`
        .replace(/\s+/g, ' ').trim())
      .filter((text) => text.toLowerCase().includes(expectedField.toLowerCase()) &&
        !/^save\b/i.test(text));
    return {
      visibleOptionNodeCount: optionNodeCount,
      fieldControlCount: controls.length,
      expectedValueVisible: controls.some((text) => text.includes(expectedValue)),
      matchingFieldControlCount: controls.filter((text) => text.includes(expectedValue)).length,
    };
  }, { expectedField: fieldLabel, expectedValue: optionLabel }).catch(() => ({
    visibleOptionNodeCount: 0,
    fieldControlCount: 0,
    expectedValueVisible: false,
    matchingFieldControlCount: 0,
  }));
  let selectedEvidence = await selectedField();
  const selectionDeadline = Date.now() + 5000;
  while (selectionTriggered && Date.now() < selectionDeadline &&
      (selectedEvidence.visibleOptionNodeCount > 0 ||
       !selectedEvidence.expectedValueVisible)) {
    await page.waitForTimeout(100);
    selectedEvidence = await selectedField();
  }
  if (/^#[0-9a-f]{6}$/i.test(optionLabel) &&
      interaction !== 'semantic-center-click') {
    console.log('WEB-GROUPS-COLOR-OPTION-DIAGNOSTIC', JSON.stringify({
      fieldKind: 'color',
      optionKind: 'hex-color',
      menuItemCount: evidence.menuItemCount,
      optionCount: evidence.optionCount,
      matchingCount: evidence.matchingCount,
      selected: selectionTriggered && selectedEvidence.expectedValueVisible,
      interaction,
      matchingSummaryCount: evidence.summaries.filter((item) => item.matchesExpected).length,
      fieldControlCount: selectedEvidence.fieldControlCount,
      expectedColorVisible: selectedEvidence.expectedValueVisible,
      visibleOptionNodeCountAfterSelection: selectedEvidence.visibleOptionNodeCount,
    }));
  }
  if (!selectionTriggered || !selectedEvidence.expectedValueVisible) {
    throw new Error('dropdown selection did not appear in the selected field control');
  }
}

async function selectedDropdownOptionVisible(page, fieldLabel, optionLabel) {
  if (fieldLabel === 'Default workspace section') {
    return page.evaluate(({ expectedField, expectedValue }) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && rect.right > 0 &&
          rect.bottom > 0 && rect.left < window.innerWidth &&
          rect.top < window.innerHeight && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const knownOptions = ['Workspace', 'Hosts', 'Credentials', 'Groups', 'All'];
      const option = knownOptions.find((value) =>
        value.toLowerCase() === expectedValue.toLowerCase());
      if (!option) return { selectedValueVisible: false, menuOpen: true };

      const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const exactCombinedLabel = (value) => new RegExp(
        `^${escapeRegex(expectedField)}(?:\\s*[,;:–—-]\\s*|\\s+)${escapeRegex(option)}$`,
        'i',
      ).test(value);
      const readSemanticNodes = () => [...document.querySelectorAll('flt-semantics')]
        .map((element) => {
          const rect = element.getBoundingClientRect();
          const role = element.getAttribute('role') || '';
          const ariaLabel = normalize(element.getAttribute('aria-label'));
          const valueAttribute = normalize(element.getAttribute('value'));
          const ariaValueNow = normalize(element.getAttribute('aria-valuenow'));
          const ariaValueText = normalize(element.getAttribute('aria-valuetext'));
          const title = normalize(element.getAttribute('title'));
          const text = normalize(element.innerText || element.textContent);
          const ariaLabelledBy = normalize(element.getAttribute('aria-labelledby'));
          const ariaDescribedBy = normalize(element.getAttribute('aria-describedby'));
          const ariaDescription = normalize(element.getAttribute('aria-description'));
          const attributeNames = [...element.attributes]
            .map((attribute) => attribute.name).sort();
          return { element, role, ariaLabel, valueAttribute, ariaValueNow,
            ariaValueText, title, text, ariaLabelledBy, ariaDescribedBy,
            ariaDescription, attributeNames, inViewport: visible(element),
            rect: { x: rect.left, y: rect.top, width: rect.width,
              height: rect.height, right: rect.right, bottom: rect.bottom } };
        });
      let allSemanticNodes = readSemanticNodes();
      const exactPairsBeforeScroll = allSemanticNodes.filter((item) =>
        exactCombinedLabel(item.ariaLabel) ||
        (item.ariaLabel === expectedField && item.ariaValueText === option));
      let scrolledExactNode = false;
      if (exactPairsBeforeScroll.length === 1 &&
          !exactPairsBeforeScroll[0].inViewport) {
        exactPairsBeforeScroll[0].element.scrollIntoView({
          block: 'center', inline: 'nearest', behavior: 'instant',
        });
        scrolledExactNode = true;
        allSemanticNodes = readSemanticNodes();
      }
      const allNodes = allSemanticNodes.filter((item) => item.inViewport);

      const fixedPhrases = {
        preferences: 'Vault-synced preferences',
        field: expectedField,
        credentials: 'Credentials',
        groups: 'Groups',
      };
      const phraseMatches = (value) => {
        const normalized = normalize(value);
        const containsToken = (phrase) => new RegExp(
          `(?:^|\\W)${phrase.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&')}(?:$|\\W)`,
          'i',
        ).test(normalized);
        return {
          preferencesExact: normalized === fixedPhrases.preferences,
          preferencesIncludes: normalized.toLowerCase().includes(
            fixedPhrases.preferences.toLowerCase()),
          fieldExact: normalized === fixedPhrases.field,
          fieldIncludes: normalized.toLowerCase().includes(
            fixedPhrases.field.toLowerCase()),
          credentialsExact: normalized === fixedPhrases.credentials,
          credentialsIncludes: containsToken(fixedPhrases.credentials),
          groupsExact: normalized === fixedPhrases.groups,
          groupsIncludes: containsToken(fixedPhrases.groups),
        };
      };
      const inventoryNodes = allSemanticNodes.map((item) => {
        const aria = phraseMatches(item.ariaLabel);
        const value = phraseMatches(item.valueAttribute);
        const valueText = phraseMatches(item.ariaValueText);
        const title = phraseMatches(item.title);
        const visibleText = phraseMatches(item.text);
        const combined = Object.fromEntries(Object.keys(aria).map((key) =>
          [key, aria[key] || value[key] || valueText[key] || title[key] ||
            visibleText[key]]));
        const hasAriaAttributes = item.attributeNames.some((name) =>
          ['aria-label', 'aria-valuetext', 'aria-valuenow', 'aria-labelledby',
            'aria-describedby', 'aria-description'].includes(name));
        const matchedPhrase = Object.values(combined).some(Boolean);
        return { item, aria, value, valueText, title, visibleText,
          combined, hasAriaAttributes, matchedPhrase };
      });
      const diagnosticRelevantNodes = inventoryNodes.filter((entry) =>
        entry.hasAriaAttributes || entry.matchedPhrase)
        .filter((entry) => entry.item.rect.x >= window.innerWidth * 0.15 ||
          entry.matchedPhrase)
        .slice(0, 60);
      const semanticInventory = {
        semanticNodeCount: allSemanticNodes.length,
        visibleSemanticNodeCount: allNodes.length,
        exactPairNodeCountBeforeScroll: exactPairsBeforeScroll.length,
        exactPairNodeCountAfterScroll: allSemanticNodes.filter((item) =>
          exactCombinedLabel(item.ariaLabel) ||
          (item.ariaLabel === expectedField && item.ariaValueText === option)).length,
        exactPairInViewportCount: allSemanticNodes.filter((item) =>
          item.inViewport && (exactCombinedLabel(item.ariaLabel) ||
            (item.ariaLabel === expectedField && item.ariaValueText === option))).length,
        scrolledExactNode,
        exactPhraseCounts: {
          preferences: inventoryNodes.filter((entry) =>
            entry.combined.preferencesExact).length,
          field: inventoryNodes.filter((entry) => entry.combined.fieldExact).length,
          credentials: inventoryNodes.filter((entry) =>
            entry.combined.credentialsExact).length,
          groups: inventoryNodes.filter((entry) => entry.combined.groupsExact).length,
        },
        includesPhraseCounts: {
          preferences: inventoryNodes.filter((entry) =>
            entry.combined.preferencesIncludes).length,
          field: inventoryNodes.filter((entry) =>
            entry.combined.fieldIncludes).length,
          credentials: inventoryNodes.filter((entry) =>
            entry.combined.credentialsIncludes).length,
          groups: inventoryNodes.filter((entry) =>
            entry.combined.groupsIncludes).length,
        },
        ariaAttributeCounts: Object.fromEntries([
          'aria-label', 'value', 'aria-valuetext', 'aria-valuenow',
          'aria-labelledby', 'aria-describedby', 'aria-description',
        ].map((name) => [name, {
          all: allSemanticNodes.filter((item) => name === 'value'
            ? item.element.hasAttribute('value')
            : item.element.hasAttribute(name)).length,
          inViewport: allNodes.filter((item) => name === 'value'
            ? item.element.hasAttribute('value')
            : item.element.hasAttribute(name)).length,
        }])),
        relevantNodeCount: diagnosticRelevantNodes.length,
        relevantNodes: diagnosticRelevantNodes.map(({ item, aria, value,
          valueText, title, visibleText }) => ({
          role: ['button', 'combobox', 'group', 'heading', 'listbox',
            'menu', 'menuitem', 'option'].includes(item.role)
            ? item.role : 'other',
          attributeNames: item.attributeNames,
          phraseMatches: {
            ariaLabel: aria,
            value: value,
            ariaValueText: valueText,
            title: title,
            visibleText,
          },
          lengths: {
            ariaLabel: item.ariaLabel.length,
            value: item.valueAttribute.length,
            ariaValueText: item.ariaValueText.length,
            title: item.title.length,
            visibleText: item.text.length,
            ariaLabelledBy: item.ariaLabelledBy.length,
            ariaDescribedBy: item.ariaDescribedBy.length,
            ariaDescription: item.ariaDescription.length,
          },
          bounds: Object.fromEntries(Object.entries(item.rect).map(([key, value]) =>
            [key, Math.round(value)])),
        })),
      };

      const headingNodes = allNodes.filter((item) =>
        item.ariaLabel === 'Vault-synced preferences' ||
        item.text === 'Vault-synced preferences' ||
        item.title === 'Vault-synced preferences');
      const heading = headingNodes.length === 1 ? headingNodes[0] : null;
      const ariaPairNodes = allNodes.filter((item) =>
        exactCombinedLabel(item.ariaLabel) ||
        (item.ariaLabel === expectedField && item.ariaValueText === option));
      const candidates = ariaPairNodes.filter((item) => {
        if (!['group', 'button', 'combobox'].includes(item.role) ||
            item.rect.height > 96 || item.rect.width > window.innerWidth * 0.96) {
          return false;
        }
        // The Flutter page exposes the selected field node but does not expose
        // an exact heading node. Require this unique, short field/value node to
        // sit in the main content column; do not infer its value from a parent
        // group or nearby text.
        return item.rect.x >= window.innerWidth * 0.15;
      });
      const candidate = candidates.length === 1 ? candidates[0] : null;
      const interactiveElements = candidate
        ? [
          ...(candidate.role === 'button' || candidate.role === 'combobox'
            ? [candidate.element] : []),
          ...candidate.element.querySelectorAll(
            'flt-semantics[role="button"], flt-semantics[role="combobox"]'),
        ].filter(visible)
        : [];

      const menuRoles = new Set(['menu', 'menuitem', 'listbox', 'option']);
      const roleMenuNodes = allNodes.filter((item) => menuRoles.has(item.role));
      const candidateAndControls = candidate
        ? allNodes.filter((item) => candidate.element === item.element ||
          candidate.element.contains(item.element) ||
          interactiveElements.includes(item.element))
        : [];
      const expandedNodes = candidateAndControls.filter((item) =>
        item.element.hasAttribute('aria-expanded'));
      const expandedTrueNodes = expandedNodes.filter((item) =>
        item.element.getAttribute('aria-expanded') === 'true');
      const expandedOrUnknownNodes = expandedNodes.filter((item) =>
        item.element.getAttribute('aria-expanded') !== 'false');
      const popupNodes = candidateAndControls.filter((item) =>
        item.element.hasAttribute('aria-haspopup'));
      const mainPanelLeft = heading?.rect.x ?? window.innerWidth * 0.15;
      const outsideFieldKnownOptions = allNodes.filter((item) => {
        if (!candidate || candidate.element.contains(item.element) ||
            item.rect.x < mainPanelLeft - 24 ||
            !['button', 'combobox', 'menuitem', 'option', ''].includes(item.role)) {
          return false;
        }
        const knownName = [item.ariaLabel, item.text, item.title]
          .some((name) => knownOptions.some((known) => name === known));
        return knownName;
      });
      const menuSignalCount = roleMenuNodes.length + expandedTrueNodes.length +
        outsideFieldKnownOptions.length;
      const menuOpen = menuSignalCount > 0;
      const menuStateUnknown = candidate !== null && menuSignalCount === 0 &&
        (expandedOrUnknownNodes.length > 0 ||
         (popupNodes.length > 0 && expandedNodes.length === 0) ||
         (popupNodes.length === 0 && expandedNodes.length === 0));

      const fixedAttribute = (value) => {
        if (value === expectedField) return 'field';
        if (exactCombinedLabel(value)) return 'field+selected-value';
        if (knownOptions.includes(value)) return `option:${value}`;
        return value ? 'other' : '';
      };
      const fixedStateAttribute = (value, allowed) =>
        allowed.includes(value) ? value : value ? 'other' : '';
      const structuralNodes = [];
      const addStructure = (item, kind) => {
        if (!item || structuralNodes.some((entry) => entry.element === item.element)) return;
        structuralNodes.push({
          element: item.element,
          kind,
          role: item.role || 'other',
          ariaLabel: fixedAttribute(item.ariaLabel),
          value: fixedAttribute(item.valueAttribute),
          ariaValueNow: /^-?\d+(?:\.\d+)?$/.test(item.ariaValueNow)
            ? 'numeric' : item.ariaValueNow ? 'other' : '',
          ariaValueText: fixedAttribute(item.ariaValueText),
          title: fixedAttribute(item.title),
          ariaExpanded: fixedStateAttribute(
            item.element.getAttribute('aria-expanded'), ['true', 'false']),
          ariaHasPopup: fixedStateAttribute(
            item.element.getAttribute('aria-haspopup'),
            ['true', 'false', 'menu', 'listbox', 'tree', 'grid', 'dialog']),
          ariaLabelLength: item.ariaLabel.length,
          valueLength: item.valueAttribute.length,
          ariaValueNowLength: item.ariaValueNow.length,
          ariaValueTextLength: item.ariaValueText.length,
          titleLength: item.title.length,
          bounds: Object.fromEntries(Object.entries(item.rect).map(([key, value]) =>
            [key, Math.round(value)])),
        });
      };
      addStructure(candidate || ariaPairNodes[0], 'field-value-node');
      const structuralControlSource = candidate || ariaPairNodes[0];
      const observedControls = structuralControlSource
        ? [
          ...(structuralControlSource.role === 'button' ||
              structuralControlSource.role === 'combobox'
            ? [structuralControlSource.element] : []),
          ...structuralControlSource.element.querySelectorAll(
            'flt-semantics[role="button"], flt-semantics[role="combobox"]'),
        ].filter(visible)
        : [];
      for (const child of observedControls) {
        const match = allNodes.find((item) => item.element === child);
        addStructure(match, 'dropdown-control');
      }
      let parent = structuralControlSource?.element.parentElement || null;
      while (parent && parent !== document.body &&
          parent.tagName.toLowerCase() !== 'flt-semantics') {
        parent = parent.parentElement;
      }
      if (parent && parent.tagName.toLowerCase() === 'flt-semantics') {
        addStructure(allNodes.find((item) => item.element === parent),
          'nearest-semantic-parent');
      }
      const structuralAnchor = candidate || ariaPairNodes[0] || null;
      const rowNodes = structuralAnchor
        ? allNodes.filter((item) => {
          const centerY = item.rect.y + item.rect.height / 2;
          const anchorCenterY = structuralAnchor.rect.y +
            structuralAnchor.rect.height / 2;
          return heading !== null && item.rect.x >= heading.rect.x - 24 &&
            Math.abs(centerY - anchorCenterY) <= 48 && item.rect.height <= 96 &&
            item.rect.width <= window.innerWidth * 0.96;
        }).slice(0, 32).map((item) => ({
          role: ['button', 'combobox', 'group', 'heading', 'listbox',
            'menu', 'menuitem', 'option'].includes(item.role)
            ? item.role : 'other',
          ariaLabel: fixedAttribute(item.ariaLabel),
          value: fixedAttribute(item.valueAttribute),
          ariaValueNow: /^-?\d+(?:\.\d+)?$/.test(item.ariaValueNow)
            ? 'numeric' : item.ariaValueNow ? 'other' : '',
          ariaValueText: fixedAttribute(item.ariaValueText),
          title: fixedAttribute(item.title),
          ariaExpanded: fixedStateAttribute(
            item.element.getAttribute('aria-expanded'), ['true', 'false']),
          ariaHasPopup: fixedStateAttribute(
            item.element.getAttribute('aria-haspopup'),
            ['true', 'false', 'menu', 'listbox', 'tree', 'grid', 'dialog']),
          ariaLabelLength: item.ariaLabel.length,
          valueLength: item.valueAttribute.length,
          ariaValueNowLength: item.ariaValueNow.length,
          ariaValueTextLength: item.ariaValueText.length,
          titleLength: item.title.length,
          bounds: Object.fromEntries(Object.entries(item.rect).map(([key, value]) =>
            [key, Math.round(value)])),
        }))
        : [];

      const exactCandidate = candidate !== null && interactiveElements.length === 1;
      return {
        selectedValueVisible: exactCandidate && !menuOpen && !menuStateUnknown,
        menuOpen,
        menuSignalCount,
        menuStateUnknown,
        headingNodeCount: headingNodes.length,
        headingRole: heading?.role || 'missing-or-ambiguous',
        ariaPairNodeCount: ariaPairNodes.length,
        exactCandidateCount: candidates.length,
        candidateRole: candidate?.role || 'missing-or-ambiguous',
        candidateHasExactCombinedAriaLabel: candidate !== null &&
          exactCombinedLabel(candidate.ariaLabel),
        candidateHasExactAriaLabelAndValueText: candidate !== null &&
          candidate.ariaLabel === expectedField && candidate.ariaValueText === option,
        interactiveChildCount: interactiveElements.length,
        roleMenuNodeCount: roleMenuNodes.length,
        expandedAttributeNodeCount: expandedNodes.length,
        expandedOrUnknownNodeCount: expandedOrUnknownNodes.length,
        popupAttributeNodeCount: popupNodes.length,
        outsideFieldKnownOptionCount: outsideFieldKnownOptions.length,
        structuralNodes: structuralNodes.map(({ element, ...item }) => item),
        rowNodeCount: rowNodes.length,
        rowNodes,
        semanticInventory,
      };
    }, { expectedField: fieldLabel, expectedValue: optionLabel }).catch(() => ({
      selectedValueVisible: false,
      menuOpen: true,
      menuSignalCount: 0,
      menuStateUnknown: true,
      headingNodeCount: 0,
      headingRole: 'diagnostic-unavailable',
      ariaPairNodeCount: 0,
      exactCandidateCount: 0,
      candidateRole: 'diagnostic-unavailable',
      candidateHasExactCombinedAriaLabel: false,
      candidateHasExactAriaLabelAndValueText: false,
      interactiveChildCount: 0,
      roleMenuNodeCount: 0,
      expandedAttributeNodeCount: 0,
      expandedOrUnknownNodeCount: 0,
      popupAttributeNodeCount: 0,
      outsideFieldKnownOptionCount: 0,
      structuralNodes: [],
      rowNodeCount: 0,
      rowNodes: [],
      semanticInventory: { unavailable: true },
    }));
  }
  return legacySelectedDropdownOptionVisible(page, fieldLabel, optionLabel);
}

async function legacySelectedDropdownOptionVisible(page, fieldLabel, optionLabel) {
  return page.evaluate(({ expectedField, expectedValue }) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 &&
        rect.left < window.innerWidth && rect.top < window.innerHeight &&
        style.visibility !== 'hidden' && style.display !== 'none' &&
        Number(style.opacity || 1) > 0;
    };
    const knownOptions = ['Workspace', 'Hosts', 'Credentials', 'Groups', 'All'];
    const controlRoles = new Set(['button', 'combobox', 'listbox', 'menuitem', 'option']);
    const nodes = [...document.querySelectorAll('flt-semantics')].filter(visible)
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          element,
          role: element.getAttribute('role') || '',
          ariaValueText: element.getAttribute('aria-valuetext') || '',
          parts: [
            element.getAttribute('aria-label') || '',
            element.getAttribute('aria-valuetext') || '',
            element.innerText || '',
            element.textContent || '',
            element.getAttribute('title') || '',
          ].map((part) => part.replace(/\s+/g, ' ').trim()).filter(Boolean),
          text: [
            element.getAttribute('aria-label') || '',
            element.innerText || '',
            element.textContent || '',
            element.getAttribute('title') || '',
          ].join(' ').replace(/\s+/g, ' ').trim(),
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
          width: rect.width,
          height: rect.height,
          centerY: (rect.top + rect.bottom) / 2,
        };
      });
    const settingsHeadingLefts = nodes.filter((item) =>
      item.text.toLowerCase().includes('vault-synced preferences'))
      .map((item) => item.left);
    const mainPanelLeft = settingsHeadingLefts.length > 0
      ? Math.min(...settingsHeadingLefts)
      : window.innerWidth * 0.18;
    const mainPanelLeftWithInset = Math.max(0, mainPanelLeft - 12);
    const maxFieldWidth = window.innerWidth * 0.88;
    const roleCounts = Object.fromEntries([
      'button', 'combobox', 'listbox', 'menuitem', 'option', 'group', 'other',
    ].map((role) => [role, nodes.filter((item) =>
      role === 'other' ? !['button', 'combobox', 'listbox', 'menuitem', 'option', 'group'].includes(item.role)
        : item.role === role).length]));
    const exactFieldLabelNodes = nodes.filter((item) => item.parts.some((part) =>
      part.toLowerCase() === expectedField.toLowerCase()));
    const fieldLabelNodes = exactFieldLabelNodes.length > 0
      ? exactFieldLabelNodes
      : nodes.filter((item) =>
        item.text.toLowerCase().includes(expectedField.toLowerCase()));
    const controls = fieldLabelNodes.filter((item) =>
      controlRoles.has(item.role) && !/^save\b/i.test(item.text));
    const mainPanelNodes = nodes.filter((item) => item.left >= mainPanelLeftWithInset);
    const menuOptions = nodes.filter((item) =>
      ['menuitem', 'option'].includes(item.role));
    const optionNameMatches = Object.fromEntries(knownOptions.map((name) => {
      const pattern = new RegExp(`(?:^|\\W)${name}(?:$|\\W)`, 'i');
      return [name, controls.some((item) => pattern.test(item.text))];
    }));
    const visibleOptionNameMatches = Object.fromEntries(knownOptions.map((name) => {
      const pattern = new RegExp(`(?:^|\\W)${name}(?:$|\\W)`, 'i');
      return [name, menuOptions.some((item) => pattern.test(item.text))];
    }));
    const mainPanelOptionNameMatches = Object.fromEntries(knownOptions.map((name) => {
      const pattern = new RegExp(`(?:^|\\W)${name}(?:$|\\W)`, 'i');
      return [name, mainPanelNodes.some((item) => pattern.test(item.text))];
    }));
    const knownOptionNodeCountsByRole = Object.fromEntries(knownOptions.map((name) => {
      const exactNodes = nodes.filter((item) => item.parts.some((part) =>
        part.trim().toLowerCase() === name.toLowerCase()));
      const roles = [...new Set(exactNodes.map((item) => item.role || 'other'))].sort();
      return [name, Object.fromEntries(roles.map((role) => [role,
        exactNodes.filter((item) => (item.role || 'other') === role).length]))];
    }));
    const optionCount = menuOptions.length;
    const expectedKnownOption = knownOptions.find((name) =>
      name.toLowerCase() === expectedValue.toLowerCase());
    const expectedValueNamePattern = expectedKnownOption
      ? new RegExp(`(?:^|\\W)${expectedKnownOption}(?:$|\\W)`, 'i')
      : null;
    const exactOptionControls = expectedKnownOption
      ? nodes.filter((item) => ['button', 'combobox'].includes(item.role) &&
        item.parts.some((part) =>
          part.trim().toLowerCase() === expectedKnownOption.toLowerCase()) &&
        item.left >= mainPanelLeftWithInset)
      : [];
    const directLabelValueNodes = expectedKnownOption
      ? nodes.filter((item) => item.left >= mainPanelLeftWithInset &&
        item.parts.some((part) =>
          part.toLowerCase() === expectedField.toLowerCase()) &&
        item.ariaValueText.trim().toLowerCase() ===
          expectedKnownOption.toLowerCase() &&
        item.width <= maxFieldWidth && item.height <= 96)
      : [];
    const directLabelValueNode = directLabelValueNodes[0] || null;
    const directLabelValueLabelExact = Boolean(directLabelValueNode &&
      directLabelValueNode.parts.some((part) =>
        part.toLowerCase() === expectedField.toLowerCase()));
    const directLabelValueAttributeExact = Boolean(directLabelValueNode &&
      directLabelValueNode.ariaValueText.trim().toLowerCase() ===
        expectedKnownOption?.toLowerCase());
    const expandedControlCount = nodes.filter((item) =>
      item.element.getAttribute('aria-expanded') === 'true').length;
    const visibleMenuOptionCount = menuOptions.length;
    const menuOpen = visibleMenuOptionCount > 0 || expandedControlCount > 0 ||
      nodes.some((item) => item.role === 'listbox');
    const combinedFieldValueNodes = expectedKnownOption
      ? nodes.filter((item) => item.left >= mainPanelLeftWithInset &&
        item.width <= maxFieldWidth && item.height <= 96 &&
        ['group', 'button', 'combobox', ''].includes(item.role) &&
        item.parts.some((part) =>
          part.toLowerCase().includes(expectedField.toLowerCase()) &&
          expectedValueNamePattern.test(part)))
      : [];
    const combinedFieldValueNode = combinedFieldValueNodes[0] || null;
    const combinedFieldValueRole = combinedFieldValueNode?.role || 'other';
    const combinedFieldValueLabelIncluded = Boolean(combinedFieldValueNode &&
      combinedFieldValueNode.parts.some((part) =>
        part.toLowerCase().includes(expectedField.toLowerCase())));
    const combinedFieldValueSelectedOptionIncluded = Boolean(combinedFieldValueNode &&
      combinedFieldValueNode.parts.some((part) =>
        expectedValueNamePattern.test(part)));
    const combinedFieldValueRoleAllowed =
      ['group', 'button', 'combobox', 'other'].includes(combinedFieldValueRole);
    const combinedFieldValueMatch = !menuOpen &&
      combinedFieldValueNodes.length === 1 && combinedFieldValueRoleAllowed;
    const ancestorMatches = new Set();
    if (!menuOpen && expectedKnownOption) {
      for (const labelNode of fieldLabelNodes) {
        let ancestor = labelNode.element;
        while (ancestor && ancestor !== document.body) {
          if (ancestor.tagName && ancestor.tagName.toLowerCase() === 'flt-semantics') {
            const rect = ancestor.getBoundingClientRect();
            const isSmallMainPanelContainer = rect.left >= mainPanelLeftWithInset &&
              rect.width <= maxFieldWidth && rect.height <= 84;
            if (isSmallMainPanelContainer) {
              const descendants = nodes.filter((item) => item.element === ancestor ||
                ancestor.contains(item.element));
              const exactFieldCount = descendants.filter((item) =>
                item.parts.some((part) =>
                  part.toLowerCase() === expectedField.toLowerCase())).length;
              const exactValueControlCount = descendants.filter((item) =>
                (['button', 'combobox'].includes(item.role) &&
                  item.parts.some((part) =>
                    part.trim().toLowerCase() === expectedKnownOption.toLowerCase())) ||
                (item.parts.some((part) =>
                  part.toLowerCase() === expectedField.toLowerCase()) &&
                  item.ariaValueText.trim().toLowerCase() ===
                    expectedKnownOption.toLowerCase())).length;
              if (exactFieldCount === 1 && exactValueControlCount === 1) {
                ancestorMatches.add(ancestor);
              }
            }
          }
          ancestor = ancestor.parentElement;
        }
      }
    }
    const sameFieldAncestorMatches = !menuOpen && ancestorMatches.size === 1;
    const directLabelValueRole = directLabelValueNode?.role || 'other';
    const directLabelValueRoleAllowed =
      ['group', 'button', 'combobox', 'other'].includes(directLabelValueRole);
    const directLabelValueMatch = !menuOpen &&
      directLabelValueNodes.length === 1 && directLabelValueRoleAllowed;
    const fieldLabelsInMainPanel = fieldLabelNodes.filter((item) =>
      item.left >= mainPanelLeftWithInset);
    const exactFieldLabelInMainPanel = exactFieldLabelNodes.filter((item) =>
      item.left >= mainPanelLeftWithInset);
    const mainPanelExactValueNodes = expectedKnownOption
      ? nodes.filter((item) => item.left >= mainPanelLeftWithInset &&
        item.parts.some((part) =>
          part.trim().toLowerCase() === expectedKnownOption.toLowerCase()))
      : [];
    const relationPairs = exactFieldLabelInMainPanel.flatMap((labelNode) =>
      mainPanelExactValueNodes.map((valueNode) => {
        const labelAncestors = [];
        for (let node = labelNode.element; node && node !== document; node = node.parentElement) {
          labelAncestors.push(node);
        }
        const valueAncestors = new Set();
        for (let node = valueNode.element; node && node !== document; node = node.parentElement) {
          valueAncestors.add(node);
        }
        const common = labelAncestors.find((node) => valueAncestors.has(node)) || null;
        const verticalGap = Math.max(0,
          labelNode.top - valueNode.bottom,
          valueNode.top - labelNode.bottom);
        const horizontalOverlap = valueNode.left <= labelNode.right &&
          valueNode.right >= labelNode.left;
        const horizontalGap = Math.max(0,
          labelNode.left - valueNode.right,
          valueNode.left - labelNode.right);
        const descendants = common
          ? nodes.filter((item) => item.element === common || common.contains(item.element))
          : [];
        return {
          distance: Math.hypot(valueNode.centerY - labelNode.centerY,
            ((valueNode.left + valueNode.right) -
              (labelNode.left + labelNode.right)) / 2),
          sameRow: verticalGap <= 12 && (horizontalOverlap || horizontalGap <= 12),
          candidateRole: valueNode.role || 'other',
          commonRole: common?.getAttribute('role') || 'other',
          commonWidth: common ? Math.round(common.getBoundingClientRect().width) : null,
          commonHeight: common ? Math.round(common.getBoundingClientRect().height) : null,
          commonExactFieldCount: descendants.filter((item) => item.parts.some((part) =>
            part.toLowerCase() === expectedField.toLowerCase())).length,
          commonExactValueCount: descendants.filter((item) => item.parts.some((part) =>
            part.trim().toLowerCase() === expectedKnownOption.toLowerCase())).length,
        };
      }));
    relationPairs.sort((a, b) => a.distance - b.distance);
    const nearestRelation = relationPairs[0] || null;
    const linkedCandidates = expectedKnownOption && !menuOpen
      ? exactOptionControls.filter((item) => {
        return fieldLabelsInMainPanel.some((labelNode) => {
          const verticalGap = Math.max(0,
            labelNode.top - item.bottom,
            item.top - labelNode.bottom);
          const horizontalOverlap = item.left <= labelNode.right &&
            item.right >= labelNode.left;
          const horizontalGap = Math.max(0,
            labelNode.left - item.right,
            item.left - labelNode.right);
          return verticalGap <= 12 &&
            (horizontalOverlap || horizontalGap <= 12);
        });
      })
      : [];
    /* Only accept one tiny shared semantics row with exactly one matching
     * label and value control, or strict geometric overlap with the same row. */
    const nearestCandidateDistancePx = fieldLabelsInMainPanel.length > 0 &&
        exactOptionControls.length > 0
      ? Math.min(...exactOptionControls.flatMap((item) =>
        fieldLabelsInMainPanel.map((labelNode) =>
          Math.round(Math.abs(item.centerY - labelNode.centerY)))))
      : null;
    const expectedValueVisible = !menuOpen && (directLabelValueMatch ||
      combinedFieldValueMatch ||
      sameFieldAncestorMatches ||
      (fieldLabelsInMainPanel.length > 0 && linkedCandidates.length === 1));
    return {
      optionCount,
      roleCounts,
      fieldLabelPresent: fieldLabelNodes.length > 0,
      fieldLabelNodeCount: fieldLabelNodes.length,
      exactFieldLabelNodeCount: exactFieldLabelNodes.length,
      knownOptionNodeCountsByRole,
      mainPanelLeftPx: Math.round(mainPanelLeft),
      uniqueMainPanelExactValueCandidateCount: mainPanelExactValueNodes.length,
      nearestCenterDistancePx: nearestRelation ? Math.round(nearestRelation.distance) : null,
      nearestRectSameRow: nearestRelation?.sameRow ?? false,
      nearestCandidateRole: nearestRelation?.candidateRole ?? null,
      minimumCommonAncestorRole: nearestRelation?.commonRole ?? null,
      minimumCommonAncestorWidthPx: nearestRelation?.commonWidth ?? null,
      minimumCommonAncestorHeightPx: nearestRelation?.commonHeight ?? null,
      minimumCommonAncestorExactFieldCount: nearestRelation?.commonExactFieldCount ?? 0,
      minimumCommonAncestorExactValueCount: nearestRelation?.commonExactValueCount ?? 0,
      directLabelValueNodeCount: directLabelValueNodes.length,
      directLabelValueMatch,
      directLabelValueRole,
      directLabelValueRoleAllowed,
      directLabelValueLabelExact,
      directLabelValueAttributeExact,
      combinedFieldValueNameCount: combinedFieldValueNodes.length,
      combinedFieldValueRole,
      combinedFieldValueRoleAllowed,
      combinedFieldValueWidthPx: combinedFieldValueNode?.width ?? null,
      combinedFieldValueHeightPx: combinedFieldValueNode?.height ?? null,
      combinedFieldValueLabelIncluded,
      combinedFieldValueSelectedOptionIncluded,
      combinedFieldValueMatch,
      fieldControlCount: controls.length,
      selectedValueVisible: expectedValueVisible,
      menuOpen,
      visibleMenuOptionCount,
      expandedControlCount,
      exactOptionControlCount: exactOptionControls.length,
      strictRowCandidateCount: linkedCandidates.length,
      ancestorCandidateCount: ancestorMatches.size,
      linkedCandidateCount: linkedCandidates.length,
      sameFieldAncestorMatches,
      nearestCandidateDistancePx,
      optionNameMatches,
      visibleOptionNameMatches,
      mainPanelOptionNameMatches,
    };
  }, { expectedField: fieldLabel, expectedValue: optionLabel }).catch(() => ({
    optionCount: 0,
    roleCounts: {},
    fieldLabelPresent: false,
    fieldLabelNodeCount: 0,
    exactFieldLabelNodeCount: 0,
    knownOptionNodeCountsByRole: {},
    mainPanelLeftPx: null,
    uniqueMainPanelExactValueCandidateCount: 0,
    nearestCenterDistancePx: null,
    nearestRectSameRow: false,
    nearestCandidateRole: null,
    minimumCommonAncestorRole: null,
    minimumCommonAncestorWidthPx: null,
    minimumCommonAncestorHeightPx: null,
    minimumCommonAncestorExactFieldCount: 0,
    minimumCommonAncestorExactValueCount: 0,
    directLabelValueNodeCount: 0,
    directLabelValueMatch: false,
    directLabelValueRole: 'other',
    directLabelValueRoleAllowed: false,
    directLabelValueLabelExact: false,
    directLabelValueAttributeExact: false,
    combinedFieldValueNameCount: 0,
    combinedFieldValueRole: 'other',
    combinedFieldValueRoleAllowed: false,
    combinedFieldValueWidthPx: null,
    combinedFieldValueHeightPx: null,
    combinedFieldValueLabelIncluded: false,
    combinedFieldValueSelectedOptionIncluded: false,
    combinedFieldValueMatch: false,
    fieldControlCount: 0,
    selectedValueVisible: false,
    menuOpen: false,
    visibleMenuOptionCount: 0,
    linkedCandidateCount: 0,
    sameFieldAncestorMatches: false,
    nearestCandidateDistancePx: null,
    optionNameMatches: {},
    visibleOptionNameMatches: {},
    mainPanelOptionNameMatches: {},
  }));
}

async function waitForSelectedDropdownOptionVisible(
  page, fieldLabel, optionLabel, timeoutMs = 5000,
) {
  const initial = await selectedDropdownOptionVisible(page, fieldLabel, optionLabel);
  let settled = initial;
  if (fieldLabel === 'Default workspace section') {
    const deadline = Date.now() + timeoutMs;
    const fieldReady = (evidence) => evidence.ariaPairNodeCount === 1 &&
      evidence.exactCandidateCount === 1 && evidence.interactiveChildCount === 1 &&
      evidence.menuSignalCount === 0;
    while (!fieldReady(settled) && Date.now() < deadline) {
      await page.waitForTimeout(100);
      settled = await selectedDropdownOptionVisible(page, fieldLabel, optionLabel);
    }
    const menuProbe = await probeDefaultSectionMenuClosure(
      page, fieldLabel, optionLabel);
    settled = await selectedDropdownOptionVisible(page, fieldLabel, optionLabel);
    settled.menuProbeOpened = menuProbe.opened;
    settled.menuProbeClosed = menuProbe.closed;
    settled.menuProbeOpenSignalCount = menuProbe.openSignalCount;
    settled.menuProbeClosedSignalCount = menuProbe.closedSignalCount;
    settled.selectedValueVisible = fieldReady(settled) &&
      (settled.candidateHasExactCombinedAriaLabel ||
       settled.candidateHasExactAriaLabelAndValueText) &&
      menuProbe.opened && menuProbe.closed;
  } else {
    const deadline = Date.now() + timeoutMs;
    while (!settled.selectedValueVisible && Date.now() < deadline) {
      await page.waitForTimeout(100);
      settled = await selectedDropdownOptionVisible(page, fieldLabel, optionLabel);
    }
  }
  return { initial, settled };
}

async function probeDefaultSectionMenuClosure(page, fieldLabel, optionLabel) {
  const evidence = await selectedDropdownOptionVisible(page, fieldLabel, optionLabel);
  const control = evidence.structuralNodes?.find((item) =>
    item.kind === 'dropdown-control' && item.bounds?.width > 0 &&
    item.bounds?.height > 0);
  if (!control || evidence.ariaPairNodeCount !== 1 ||
      evidence.exactCandidateCount !== 1 || evidence.interactiveChildCount !== 1) {
    return { opened: false, closed: false, openSignalCount: 0,
      closedSignalCount: evidence.menuSignalCount ?? 0 };
  }
  const x = control.bounds.x + control.bounds.width / 2;
  const y = control.bounds.y + control.bounds.height / 2;
  let opened = false;
  let openSignalCount = 0;
  let closed = false;
  let closedSignalCount = -1;
  try {
    if ((evidence.menuSignalCount ?? 0) > 0) {
      await page.keyboard.press('Escape').catch(() => {});
      await waitUntil(async () => {
        const current = await selectedDropdownOptionVisible(
          page, fieldLabel, optionLabel);
        return current.menuSignalCount === 0;
      }, 3000, 'default section dropdown initial menu close');
    }
    await page.mouse.click(x, y);
    await waitUntil(async () => {
      const current = await selectedDropdownOptionVisible(
        page, fieldLabel, optionLabel);
      openSignalCount = current.menuSignalCount ?? 0;
      return openSignalCount > 0;
    }, 3000, 'default section dropdown open semantics');
    opened = true;
  } catch (_) {
    opened = false;
  } finally {
    await page.keyboard.press('Escape').catch(() => {});
  }
  if (opened) {
    try {
      await waitUntil(async () => {
        const current = await selectedDropdownOptionVisible(
          page, fieldLabel, optionLabel);
        closedSignalCount = current.menuSignalCount ?? -1;
        return closedSignalCount === 0;
      }, 3000, 'default section dropdown closed semantics');
      closed = true;
    } catch (_) {
      closed = false;
    }
  }
  return { opened, closed, openSignalCount, closedSignalCount };
}

async function groupRowEvidence(page, groupName, parentName) {
  return page.evaluate(({ expectedName, expectedParentName }) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const visibleTexts = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => visible(element))
      .map((element) => ({
        text: `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
          .replace(/\s+/g, ' ').trim(),
      }));
    const matchingSemantics = visibleTexts
      .filter((item) => item.text.includes(expectedName));
    const candidates = matchingSemantics
      .filter((item) => /\b\d+\s+hosts?\b/.test(item.text));
    candidates.sort((left, right) => left.text.length - right.text.length);
    const bodyText = document.body.innerText || '';
    const lines = bodyText.split(/\r?\n/)
      .map((line) => line.trim()).filter(Boolean);
    const index = lines.indexOf(expectedName);
    const summary = candidates.length > 0
      ? candidates[0].text
      : index < 0 ? '' : lines.slice(index, index + 5).join(' · ');
    const allVisibleText = `${bodyText}\n${visibleTexts.map((item) => item.text).join('\n')}`;
    const parentPhrase = `Inside ${expectedParentName}`;
    return {
      summaryHasChild: summary.includes(expectedName),
      summaryHasParent: summary.includes(parentPhrase),
      summaryHasOneHost: /\b1\s+host\b/.test(summary),
      summaryLength: summary.length,
      visibleMatchingSemanticsCandidateCount: matchingSemantics.length,
      visibleMatchingSemanticsWithParentCount: matchingSemantics.filter((item) =>
        item.text.includes(parentPhrase)).length,
      visibleMatchingSemanticsWithOneHostCount: matchingSemantics.filter((item) =>
        /\b1\s+host\b/.test(item.text)).length,
      pageHasParentRelationshipText: allVisibleText.includes(parentPhrase),
      pageHasOneHostText: /\b1\s+host\b/.test(allVisibleText),
    };
  }, { expectedName: groupName, expectedParentName: parentName }).catch(() => ({
    summaryHasChild: false,
    summaryHasParent: false,
    summaryHasOneHost: false,
    summaryLength: 0,
    visibleMatchingSemanticsCandidateCount: 0,
    visibleMatchingSemanticsWithParentCount: 0,
    visibleMatchingSemanticsWithOneHostCount: 0,
    pageHasParentRelationshipText: false,
    pageHasOneHostText: false,
    diagnosticUnavailable: true,
  }));
}

async function clickSyncConflictsNavigation(page) {
  const exactLabel = page.getByRole('button', {
    name: 'Sync & conflicts',
    exact: true,
  });
  const badgeTolerant = page.getByRole('button', {
    name: /^Sync & conflicts(?:\s+\d+)?$/,
  });
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await badgeTolerant.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = badgeTolerant.nth(index);
      if (await candidate.isVisible()) {
        await candidate.click();
        return;
      }
    }
    await page.waitForTimeout(100);
  }
  const [exactLabelCount, badgeTolerantCount, visibleBadgeTolerantCount] =
    await Promise.all([
      exactLabel.count().catch(() => 0),
      badgeTolerant.count().catch(() => 0),
      (async () => {
        const count = await badgeTolerant.count().catch(() => 0);
        let visible = 0;
        for (let index = 0; index < count; index += 1) {
          if (await badgeTolerant.nth(index).isVisible().catch(() => false)) visible++;
        }
        return visible;
      })(),
    ]);
  console.log('sync inbox navigation locator diagnostic', JSON.stringify({
    errorClass: 'locator-timeout',
    exactLabelCount,
    badgeTolerantCount,
    visibleBadgeTolerantCount,
  }));
  throw new Error('visible Sync & conflicts navigation button not found');
}

async function waitForUniqueVisibleButton(
  page,
  exactLabel,
  partialName,
) {
  // Flutter Web's semantics DOM can expose a visible role=button node before
  // Playwright's accessibility snapshot has indexed its computed name. Match
  // the same sanitized semantic labels used by the diagnostics, then click the
  // unique visible node directly.
  const semanticsButtons = page.locator('flt-semantics[role="button"]');
  const deadline = Date.now() + 15000;
  let finalState = {
    exactNameCount: 0,
    matchCount: 0,
    visibleCount: 0,
    actionableCount: 0,
    viewportActionableCount: 0,
    matches: [],
  };
  while (Date.now() < deadline) {
    const state = await semanticsButtons.evaluateAll((nodes, options) => {
      const pattern = new RegExp(options.pattern, options.flags);
      const matches = [];
      nodes.forEach((node, index) => {
        const label = [
          node.getAttribute('aria-label') || '',
          node.innerText || '',
        ].join(' ').replace(/\s+/g, ' ').trim();
        if (!pattern.test(label)) return;
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        const visible = rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none' &&
          !node.closest('[aria-hidden="true"]');
        const inViewport = visible && rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth;
        matches.push({
          index,
          exactName: label === options.exactLabel,
          visible,
          inViewport,
          enabled: node.getAttribute('aria-disabled') !== 'true',
        });
      });
      return matches;
    }, {
      pattern: partialName.source,
      flags: partialName.flags,
      exactLabel,
    });
    const viewportCandidates = state.filter((item) =>
      item.visible && item.enabled && item.inViewport);
    const actionableCandidates = state.filter((item) =>
      item.visible && item.enabled);
    const candidates = viewportCandidates.length > 0
      ? viewportCandidates
      : actionableCandidates;
    finalState = {
      exactNameCount: state.filter((item) => item.exactName).length,
      matchCount: state.length,
      visibleCount: state.filter((item) => item.visible).length,
      actionableCount: candidates.length,
      viewportActionableCount: candidates.filter((item) => item.inViewport).length,
      matches: state.map(({ exactName, visible, inViewport, enabled }) => ({
        exactName,
        visible,
        inViewport,
        enabled,
      })),
    };
    if (candidates.length === 1) {
      const candidate = semanticsButtons.nth(candidates[0].index);
      await candidate.scrollIntoViewIfNeeded().catch(() => {});
      return candidate;
    }
    await page.waitForTimeout(100);
  }
  console.log('conflict action locator diagnostic', JSON.stringify({
    errorClass: finalState.viewportActionableCount > 1 ||
      (finalState.viewportActionableCount === 0 && finalState.actionableCount > 1)
      ? 'multiple-actionable-matches-timeout'
      : 'actionable-match-timeout',
    ...finalState,
  }));
  throw new Error('unique visible enabled conflict action was not found');
}

async function clickLastButton(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = count - 1; index >= 0; index -= 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible()) {
        await candidate.click();
        return;
      }
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button not found: ${label}`);
}

async function clickConfirmDialogButton(page, dialogTitle, label) {
  const title = page.getByText(dialogTitle, { exact: true });
  await title.waitFor({ state: 'visible', timeout: 15000 });
  const dialogCandidates = ['dialog', 'alertdialog'].map((role) =>
    page.getByRole(role).filter({ has: title }));
  const dialogCounts = await Promise.all(dialogCandidates.map((dialog) =>
    dialog.count().catch(() => 0)));
  const matches = dialogCandidates.filter((_, index) => dialogCounts[index] === 1);
  if (matches.length !== 1 || dialogCounts.reduce((sum, count) => sum + count, 0) !== 1) {
    console.log('confirmation dialog locator diagnostic', JSON.stringify({
      dialogRoleCounts: dialogCounts,
      titleVisible: await title.isVisible().catch(() => false),
    }));
    throw new Error('unique confirmation dialog was unavailable');
  }

  const buttons = matches[0].getByRole('button', { name: label, exact: true });
  const count = await buttons.count().catch(() => 0);
  if (count !== 1) {
    console.log('confirmation button locator diagnostic', JSON.stringify({
      dialogRoleCounts: dialogCounts,
      buttonCount: count,
    }));
    throw new Error('unique confirmation button was unavailable');
  }
  const button = buttons.first();
  const visible = await button.isVisible().catch(() => false);
  const enabled = await button.isEnabled().catch(() => false);
  const isHitTarget = await button.evaluate((element) => {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const hit = document.elementFromPoint(
      rect.left + rect.width / 2,
      rect.top + rect.height / 2,
    );
    return Boolean(hit && (
      hit === element || element.contains(hit) || hit.contains(element)
    ));
  }).catch(() => false);
  if (!visible || !enabled || !isHitTarget) {
    console.log('confirmation button locator diagnostic', JSON.stringify({
      dialogRoleCounts: dialogCounts,
      buttonCount: count,
      visible,
      enabled,
      isHitTarget,
    }));
    throw new Error('confirmation button was not uniquely interactable');
  }
  await button.click();
}

async function safeRevokeButtonEvidence(page) {
  const matches = page.getByRole('button', {
    name: 'Revoke device', exact: true,
  });
  const playwrightButtons = [];
  const count = await matches.count().catch(() => -1);
  for (let index = 0; index < Math.max(0, count); index += 1) {
    const candidate = matches.nth(index);
    const box = await candidate.boundingBox().catch(() => null);
    playwrightButtons.push({
      visible: await candidate.isVisible().catch(() => false),
      enabled: await candidate.isEnabled().catch(() => false),
      box: box ? {
        x: Math.round(box.x),
        y: Math.round(box.y),
        width: Math.round(box.width),
        height: Math.round(box.height),
      } : null,
    });
  }
  const semantic = await page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const textValues = [document.body.innerText || ''];
    for (const element of document.querySelectorAll('flt-semantics')) {
      if (!visible(element)) continue;
      textValues.push(element.getAttribute('aria-label') || '');
      textValues.push(element.innerText || '');
    }
    const hasText = (expected) => textValues.some((value) =>
      value.replace(/\s+/g, ' ').trim().includes(expected));
    const nodes = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter((element) => {
        if (!visible(element)) return false;
        const labels = [
          element.getAttribute('aria-label') || '',
          element.getAttribute('title') || '',
          element.innerText || '',
          element.textContent || '',
        ];
        return labels.some((value) =>
          value.replace(/\s+/g, ' ').trim() === 'Revoke device');
      });
    return {
      devicesPageVisible: hasText('Trusted devices'),
      revokeDialogVisible: hasText('Revoke device?'),
      semanticButtonCount: nodes.length,
      semanticButtons: nodes.map((element) => {
        const rect = element.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const hit = document.elementFromPoint(x, y);
        const hitButton = hit?.closest('flt-semantics[role="button"]') || null;
        const hitDialog = hit?.closest('[role="dialog"],flt-semantics[role="dialog"]') || null;
        let hitClassification = 'no-element';
        if (hit && (hit === element || element.contains(hit) || hit.contains(element))) {
          hitClassification = 'target-button';
        } else if (hitDialog) {
          hitClassification = 'dialog-overlay';
        } else if (hitButton) {
          hitClassification = 'other-button';
        } else if (hit?.closest('flt-semantics')) {
          hitClassification = 'other-semantics';
        } else if (hit) {
          hitClassification = 'other-dom';
        }
        return {
          visible: true,
          enabled: element.getAttribute('aria-disabled') !== 'true' &&
            !element.hasAttribute('disabled'),
          box: {
            x: Math.round(rect.x),
            y: Math.round(rect.y),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          },
          elementFromPoint: hitClassification,
        };
      }),
    };
  }).catch(() => ({ diagnosticUnavailable: true }));
  return {
    playwrightCount: count,
    playwrightVisibleCount: playwrightButtons.filter((item) => item.visible).length,
    playwrightEnabledCount: playwrightButtons.filter((item) =>
      item.visible && item.enabled).length,
    playwrightButtons,
    ...semantic,
  };
}

async function connect(page, baseUrl) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function enableFlutterSemantics(page, profile, evidence) {
  const startupDeadline = Date.now() + 30000;
  let startupReady = false;
  while (Date.now() < startupDeadline) {
    startupReady = await page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      window.__e2eFlutterProbe?.runAppCompleted === true &&
      Boolean(document.querySelector('flt-semantics-placeholder')));
    if (startupReady) break;
    await page.waitForTimeout(100);
  }
  if (!startupReady) {
    const startup = await page.evaluate(async () => {
      const sodium = window.sodium;
      let sodiumReady = 'missing';
      let sodiumRejected = false;
      if (typeof sodium?.ready?.then === 'function') {
        sodiumReady = await Promise.race([
          sodium.ready.then(() => 'resolved', () => {
            sodiumRejected = true;
            return 'rejected';
          }),
          new Promise((resolve) => setTimeout(() => resolve('pending'), 150)),
        ]);
      }
        const probe = window.__e2eFlutterProbe || null;
      const startupSignals = window.__e2eStartupSignals || { csp: [], runtimeErrors: [] };
      const errorText = String(probe?.error || '');
      const errorType = errorText.match(/\b(TypeError|ReferenceError|SyntaxError|SecurityError|RangeError|CompileError|LinkError|RuntimeError|Error)\b/)?.[1] || null;
      const relevantScripts = [...document.scripts]
        .map((script) => ({
          path: script.src ? new URL(script.src, location.href).pathname : '[inline]',
          async: script.async,
          defer: script.defer,
          type: script.type || 'text/javascript',
        }))
        .filter((script) => /sodium|flutter|main\.dart|bootstrap/i.test(script.path));
      const relevantResources = performance.getEntriesByType('resource')
        .map((entry) => {
          try { return new URL(entry.name).pathname; } catch (_) { return ''; }
        })
        .filter((path) => /sodium|\.wasm$|flutter|main\.dart|canvaskit/i.test(path))
        .slice(-30);
      return {
        url: location.pathname,
        readyState: document.readyState,
        title: document.title,
        sodiumPresent: Boolean(sodium),
        sodiumReadyThenable: typeof sodium?.ready?.then === 'function',
        sodiumReady,
        sodiumRejected,
        flutterProbe: probe && {
          initializerCalled: probe.initializerCalled === true,
          engineInitialized: probe.engineInitialized === true,
          runAppCompleted: probe.runAppCompleted === true,
          hasError: Boolean(probe.error),
          errorType,
        },
        startupSignals: {
          cspViolationCount: startupSignals.csp.length,
          cspDirectiveCounts: startupSignals.csp.reduce((counts, item) => {
            counts[item.directive] = (counts[item.directive] || 0) + 1;
            return counts;
          }, {}),
          blockedUriCategories: startupSignals.csp.reduce((counts, item) => {
            counts[item.blockedUriCategory] = (counts[item.blockedUriCategory] || 0) + 1;
            return counts;
          }, {}),
          runtimeErrorTypes: startupSignals.runtimeErrors.reduce((counts, type) => {
            counts[type] = (counts[type] || 0) + 1;
            return counts;
          }, {}),
        },
        semanticsPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
        semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
        bodyTextLength: document.body.innerText.length,
        relevantScripts,
        relevantResources,
      };
    }).catch(() => ({ evaluateError: true }));
    const assets = evidence.responseDiagnostics
      .filter((item) => /sodium|\.wasm$|flutter|main\.dart|canvaskit/i.test(item.path))
      .slice(-30);
    const diagnostic = {
      profile,
      startup,
      assets,
      requestFailureCount: evidence.browserDiagnostics.filter((item) =>
        item.profile === profile && item.kind === 'request-failed').length,
      pageErrorCount: evidence.pageErrors.length,
      cspViolationCount: evidence.cspViolations.length,
    };
    console.log('Flutter startup timeout diagnostic', JSON.stringify(diagnostic, null, 2));
    assertThat(false, `Flutter startup or accessibility placeholder did not appear (${profile}); see sanitized startup diagnostic`);
  }
  const sodiumState = await page.evaluate(async () => Promise.race([
    window.sodium.ready.then(() => 'resolved', () => 'rejected'),
    new Promise((resolve) => setTimeout(() => resolve('timeout'), 10000)),
  ]));
  assertThat(sodiumState === 'resolved', `sodium.js ready state is ${sodiumState}`);
  // Flutter Web keeps controls on a canvas until its accessibility placeholder
  // is activated. Clicking that real placeholder exposes the semantic tree to
  // browser automation and assistive technology.
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  const semanticsDeadline = Date.now() + 15000;
  let hasSemantics = false;
  while (Date.now() < semanticsDeadline) {
    hasSemantics = await page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0);
    if (hasSemantics) break;
    await page.waitForTimeout(100);
  }
  assertThat(hasSemantics, 'Flutter semantics tree did not appear after enabling accessibility');
}

async function installFlutterLoaderProbe(context) {
  await context.addInitScript(() => {
    window.__e2eStartupSignals = { csp: [], runtimeErrors: [] };
    const safeRuntimeErrorType = (value) => {
      const name = String(value?.name || value || '').match(/\b(TypeError|ReferenceError|SyntaxError|SecurityError|RangeError|CompileError|LinkError|RuntimeError|Error)\b/)?.[1];
      return name || 'OtherError';
    };
    addEventListener('securitypolicyviolation', (event) => {
      const knownDirectives = new Set([
        'default-src', 'base-uri', 'form-action', 'frame-ancestors', 'object-src',
        'script-src', 'script-src-elem', 'style-src', 'img-src', 'font-src',
        'connect-src', 'worker-src', 'manifest-src',
      ]);
      const directive = String(event.violatedDirective || '').split(/\s+/)[0] || 'unknown';
      const rawUri = String(event.blockedURI || '');
      const blockedUriCategory = rawUri === 'inline' || rawUri === 'eval'
        ? rawUri
        : rawUri.startsWith('data:') ? 'data'
        : rawUri.startsWith('blob:') ? 'blob'
        : rawUri.startsWith('https:') ? 'https'
        : rawUri.startsWith('http:') ? 'http'
        : rawUri.startsWith('file:') ? 'file'
        : rawUri.length === 0 ? 'empty'
        : 'other';
      if (window.__e2eStartupSignals.csp.length < 50) {
        window.__e2eStartupSignals.csp.push({
          directive: knownDirectives.has(directive) ? directive : 'other',
          blockedUriCategory,
        });
      }
    });
    addEventListener('unhandledrejection', (event) => {
      if (window.__e2eStartupSignals.runtimeErrors.length < 50) {
        window.__e2eStartupSignals.runtimeErrors.push(safeRuntimeErrorType(event.reason));
      }
    });
    addEventListener('error', (event) => {
      if (window.__e2eStartupSignals.runtimeErrors.length < 50) {
        window.__e2eStartupSignals.runtimeErrors.push(safeRuntimeErrorType(event.error || event.message));
      }
    });
    window.__e2eFlutterProbe = {
      initializerCalled: false,
      engineInitialized: false,
      runAppCompleted: false,
      error: null,
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
                    window.__e2eFlutterProbe.error = String(error);
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

async function waitWorkspace(page) {
  await button(page, 'Add host');
}

async function openCredentialsPage(page) {
  const heading = page.getByText('SSH credentials', { exact: true }).first();
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    if (await heading.isVisible().catch(() => false)) return;
    await click(page, 'Credentials');
    await page.waitForTimeout(250);
  }
  throw new Error('Credentials page did not become visible');
}

async function syncNow(page, {
  verifyProjection,
  expectedVaultId,
} = {}) {
  const syncButton = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  try {
    await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  } catch (error) {
    const status = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .filter((label) => /^(?:Idle|Pending|Syncing|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only|\d+ pending)$/.test(label))
        .slice(0, 8),
    ).catch(() => []);
    console.log('sync button diagnostic', JSON.stringify({
      statusLabels: status,
      page: await safePageDiagnostic(page),
    }));
    throw error;
  }
  const currentLabel = await syncButton.getAttribute('aria-label') ||
    (await syncButton.innerText()).trim();
  if (currentLabel !== 'Syncing') {
    const changesRequest = page.waitForRequest((request) => {
      const url = new URL(request.url());
      return request.method() === 'GET' &&
        (expectedVaultId
          ? url.pathname === `/api/v1/vaults/${expectedVaultId}/changes`
          : /\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(url.pathname));
    }, { timeout: 15000 });
    await syncButton.click();
    try {
      // A short sync can render no visible Syncing frame. Require a fresh
      // authoritative changes request instead of accepting the old Idle label.
      await changesRequest;
    } catch (error) {
      console.log('sync start diagnostic', JSON.stringify({
        previousLabel: currentLabel,
        page: await safePageDiagnostic(page),
      }));
      throw error;
    }
  }
  // Writers settle at Idle and read-only members settle at Read-only; neither
  // state can be inferred from a generic “Synced” label.
  try {
    await page.getByRole('button', { name: /^(Idle|Read-only)$/ }).first().waitFor({
      state: 'visible',
      timeout: 45000,
    });
  } catch (error) {
    const status = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .filter((label) => /^(?:Idle|Pending|Syncing|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only|\d+ pending)$/.test(label))
        .slice(0, 8),
    ).catch(() => []);
    console.log('sync completion diagnostic', JSON.stringify({
      statusLabels: status,
      page: await safePageDiagnostic(page),
    }));
    throw error;
  }
  if (verifyProjection) await verifyProjection();
}

function waitForVaultPushResponse(page, vaultId) {
  return page.waitForResponse((response) => {
    const request = response.request();
    return request.method() === 'POST' &&
      new URL(response.url()).pathname ===
        `/api/v1/vaults/${vaultId}/sync/push`;
  }, { timeout: 45000 }).then(
    (response) => ({ response }),
    (error) => ({ error }),
  );
}

async function syncUntilVaultPush(
  page,
  vaultId,
  pushResponsePromise,
  { waitForIdle = true } = {},
) {
  const syncButton = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  const currentLabel = await syncButton.getAttribute('aria-label') ||
    (await syncButton.innerText()).trim();
  if (currentLabel !== 'Syncing') {
    const changesRequest = page.waitForRequest((request) =>
      request.method() === 'GET' &&
      new URL(request.url()).pathname ===
        `/api/v1/vaults/${vaultId}/changes`,
    { timeout: 15000 });
    await syncButton.click();
    await changesRequest;
  }
  const pushResult = await pushResponsePromise;
  if (pushResult.error) {
    pushResult.error.syncPhase = 'push-response';
    throw pushResult.error;
  }
  if (!pushResult.response.ok()) {
    throw new Error(
      `Expected Vault sync push failed (status=${pushResult.response.status()})`,
    );
  }
  if (waitForIdle) {
    try {
      await page.getByRole('button', { name: /^Idle$/ }).first().waitFor({
        state: 'visible',
        timeout: 45000,
      });
    } catch (error) {
      error.syncPhase = 'idle-after-push';
      throw error;
    }
  }
  return pushResult.response;
}

async function triggerSyncWithoutWaitingForIdle(page) {
  const syncButton = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
  }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  const currentLabel = await syncButton.getAttribute('aria-label') ||
    (await syncButton.innerText()).trim();
  if (currentLabel !== 'Syncing') await syncButton.click();
}

async function syncUntilVaultConflictIsCommitted({
  page,
  apiDiagnostics,
  databasePath,
  vaultId,
}) {
  const startIndex = apiDiagnostics.length;
  const changesPath = `/api/v1/vaults/${vaultId}/changes`;
  const conflictUploadPath = `/api/v1/vaults/${vaultId}/conflicts`;
  let previousStatusKey = null;
  let consecutiveStableStatusReads = 0;
  await triggerSyncWithoutWaitingForIdle(page);

  const observed = async () => {
    const responses = apiDiagnostics.slice(startIndex);
    const changes200 = responses.some((entry) => entry.profile === 'A' &&
      entry.method === 'GET' && entry.path === changesPath && entry.status === 200);
    const conflictUpload = responses.find((entry) => entry.profile === 'A' &&
      entry.method === 'POST' && entry.path === conflictUploadPath &&
      entry.status >= 200 && entry.status < 300);
    const openConflictCount = serverVaultConflictCount(databasePath, vaultId);
    const labels = await visibleSyncStatusLabels(page);
    const pendingOrIdle = labels.some((label) => label === 'Idle' ||
      label === 'Pending' || /^\d+ pending$/.test(label));
    const syncing = labels.some((label) => label === 'Syncing');
    const statusKey = labels.slice().sort().join('|');
    if (pendingOrIdle && !syncing && statusKey === previousStatusKey) {
      consecutiveStableStatusReads++;
    } else {
      consecutiveStableStatusReads = pendingOrIdle && !syncing ? 1 : 0;
    }
    previousStatusKey = pendingOrIdle && !syncing ? statusKey : null;
    return {
      changes200,
      conflictUpload: Boolean(conflictUpload),
      openConflictCount,
      labels,
      settledStatus: consecutiveStableStatusReads >= 2,
      consecutiveStableStatusReads,
    };
  };

  let state = await observed();
  try {
    await waitUntil(async () => {
      state = await observed();
      return state.changes200 && state.conflictUpload &&
        state.openConflictCount > 0 && state.settledStatus;
    }, 45000, 'Vault A changes, conflict upload, and server open-conflict evidence');
  } catch (error) {
    state = await observed();
    console.log('multi-Vault conflict sync evidence', JSON.stringify({
      changes200: state.changes200,
      conflictUpload2xx: state.conflictUpload,
      serverOpenConflictPresent: state.openConflictCount > 0,
      syncStatusClass: state.labels.map((label) =>
        /^\d+ pending$/.test(label) ? 'pending-count' : label),
      api: safeApiSummary(apiDiagnostics.slice(startIndex), 12),
    }));
    throw error;
  }
  console.log('multi-Vault conflict sync evidence', JSON.stringify({
    changes200: state.changes200,
    conflictUpload2xx: state.conflictUpload,
    serverOpenConflictPresent: state.openConflictCount > 0,
    syncStatusClass: state.labels.map((label) =>
      /^\d+ pending$/.test(label) ? 'pending-count' : label),
  }));
  assertThat(state.changes200 && state.conflictUpload &&
    state.openConflictCount > 0 && state.settledStatus,
  'Vault A sync did not publish the expected server conflict');
}

async function hostCardEvidence(page, name, expectedEndpoint = null) {
  return page.evaluate(({ expectedName, endpoint }) => {
    const cardLabels = [...document.querySelectorAll('flt-semantics[role="group"]')]
      .map((node) => node.getAttribute('aria-label') || '')
      .map((label) => label.trim())
      .filter((label) => label.startsWith('Host: '));
    const namePrefix = `Host: ${expectedName}; `;
    const matchingLabels = cardLabels.filter((label) => label.startsWith(namePrefix));
    const savedHosts = [...document.querySelectorAll('flt-semantics')].find((node) => {
      const text = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      return /Saved hosts/i.test(text);
    });
    const savedHostsText = [
      savedHosts?.getAttribute('aria-label') || '',
      savedHosts?.innerText || '',
      savedHosts?.parentElement?.innerText || '',
    ].join('\n');
    const savedHostsMatch = savedHostsText.match(/Saved hosts\D{0,32}(\d+)/i) ||
      savedHostsText.match(/(\d+)\D{0,32}Saved hosts/i);
    return {
      hostCardGroupCount: cardLabels.length,
      matchingHostCardCount: matchingLabels.length,
      nameVisible: matchingLabels.length > 0,
      endpointVisible: endpoint == null
        ? null
        : matchingLabels.some((label) => label.includes(`@${endpoint}`)),
      savedHostsCount: savedHostsMatch ? Number(savedHostsMatch[1]) : null,
    };
  }, { expectedName: name, endpoint: expectedEndpoint }).catch(() => ({
    hostCardGroupCount: null,
    matchingHostCardCount: null,
    nameVisible: false,
    endpointVisible: expectedEndpoint == null ? null : false,
    savedHostsCount: null,
    diagnosticUnavailable: true,
  }));
}

function hostCardByRecordId(page, recordId) {
  return page.locator(
    `flt-semantics[flt-semantics-identifier="ssh-host-${recordId}"]`,
  );
}

async function hostCardIdentifierEvidence(page, recordId, name, endpoint) {
  return page.evaluate(({ recordId, expectedName, expectedEndpoint }) => {
    const identifier = `ssh-host-${recordId}`;
    const nodes = [...document.querySelectorAll(
      'flt-semantics[flt-semantics-identifier]',
    )].filter((node) =>
      node.getAttribute('flt-semantics-identifier') === identifier);
    const node = nodes[0];
    if (!node) return {
      identifierNodeCount: nodes.length,
      semanticRole: 'missing',
      nameMatches: false,
      endpointMatches: false,
      inViewport: false,
    };
    const label = node.getAttribute('aria-label') || '';
    const rect = node.getBoundingClientRect();
    const style = getComputedStyle(node);
    const visible = rect.width > 0 && rect.height > 0 &&
      style.display !== 'none' && style.visibility !== 'hidden';
    return {
      identifierNodeCount: nodes.length,
      semanticRole: node.getAttribute('role') === 'group' ? 'group' : 'other',
      nameMatches: label.startsWith(`Host: ${expectedName}; `),
      endpointMatches: label.includes(`@${expectedEndpoint}`),
      inViewport: visible && rect.bottom > 0 && rect.top < window.innerHeight &&
        rect.right > 0 && rect.left < window.innerWidth,
    };
  }, { recordId, expectedName: name, expectedEndpoint: endpoint }).catch(() => ({
    identifierNodeCount: 0,
    semanticRole: 'diagnostic-unavailable',
    nameMatches: false,
    endpointMatches: false,
    inViewport: false,
    diagnosticUnavailable: true,
  }));
}

async function hostCardRelationshipEvidence(page, recordId, expectedGroupName) {
  return page.evaluate(({ recordId, expectedGroupName }) => {
    const elementsByIdentifier = (identifier) => [...document.querySelectorAll(
      'flt-semantics[flt-semantics-identifier]',
    )].filter((node) => node.getAttribute('flt-semantics-identifier') === identifier);
    const roots = elementsByIdentifier(`ssh-host-${recordId}`);
    const groupNodes = elementsByIdentifier(`ssh-host-group-${recordId}`);
    const unavailableNodes = elementsByIdentifier(
      `ssh-host-group-unavailable-${recordId}`,
    );
    const root = roots[0];
    if (!root) return {
      identifierNodeCount: roots.length,
      expectedGroupTagPresent: false,
      expectedGroupTagVisible: false,
      groupIdentifierNodeCount: groupNodes.length,
      groupLabelMatches: false,
      groupNodeOverlapsCard: false,
      unavailableGroupTagPresent: false,
      unavailableIdentifierNodeCount: unavailableNodes.length,
    };
    const cardRect = root.getBoundingClientRect();
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      if (rect.width <= 0 || rect.height <= 0 || style.display === 'none' ||
          style.visibility === 'hidden' || Number(style.opacity || '1') <= 0) {
        return false;
      }
      let left = Math.max(rect.left, 0);
      let top = Math.max(rect.top, 0);
      let right = Math.min(rect.right, window.innerWidth);
      let bottom = Math.min(rect.bottom, window.innerHeight);
      for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
        const ancestorStyle = getComputedStyle(ancestor);
        if (ancestorStyle.display === 'none' ||
            ancestorStyle.visibility === 'hidden' ||
            Number(ancestorStyle.opacity || '1') <= 0 ||
            ancestor.getAttribute('aria-hidden') === 'true') return false;
        const clipRect = ancestor.getBoundingClientRect();
        if (/(hidden|clip|auto|scroll)/.test(ancestorStyle.overflowX)) {
          left = Math.max(left, clipRect.left);
          right = Math.min(right, clipRect.right);
        }
        if (/(hidden|clip|auto|scroll)/.test(ancestorStyle.overflowY)) {
          top = Math.max(top, clipRect.top);
          bottom = Math.min(bottom, clipRect.bottom);
        }
      }
      return right > left && bottom > top;
    };
    const overlapsCard = (element) => {
      const rect = element.getBoundingClientRect();
      return Math.min(cardRect.right, rect.right) > Math.max(cardRect.left, rect.left) &&
        Math.min(cardRect.bottom, rect.bottom) > Math.max(cardRect.top, rect.top);
    };
    const groupLabelMatches = groupNodes.length === 1 &&
      groupNodes[0].getAttribute('aria-label') === `Group: ${expectedGroupName}`;
    const groupLabelContainsExpected = groupNodes.length === 1 &&
      (groupNodes[0].getAttribute('aria-label') || '').includes(expectedGroupName);
    const groupLabelPresent = groupNodes.length === 1 &&
      Boolean((groupNodes[0].getAttribute('aria-label') || '').trim());
    const groupNodeOverlapsCard = groupNodes.length === 1 &&
      overlapsCard(groupNodes[0]);
    const groupNodeVisible = groupNodes.length === 1 && isVisible(groupNodes[0]);
    const hostLabelContainsExpectedGroup =
      (root.getAttribute('aria-label') || '').includes(`; Group: ${expectedGroupName}`);
    const hostLabelIndicatesGroupRepair =
      (root.getAttribute('aria-label') || '').includes('; Group needs repair:');
    const expectedGroupTagVisible = groupNodeOverlapsCard && groupNodeVisible;
    // Flutter Web may retain a semantics identifier/geometry for the nested
    // tag while folding its label into the Host card's accessible name.
    const expectedGroupTagPresent = groupNodes.length === 1 &&
      groupNodeOverlapsCard && hostLabelContainsExpectedGroup;
    const unavailableNodeLabelMatches = unavailableNodes.some((node) =>
      node.getAttribute('aria-label') === 'Unavailable group');
    const unavailableGroupNodeOverlapsCard = unavailableNodes.length === 1 &&
      overlapsCard(unavailableNodes[0]);
    // Flutter Web can fold the tag's child label into the Host card semantics
    // while preserving the child identifier and geometry.
    const unavailableGroupTagPresent = unavailableNodes.length === 1 &&
      unavailableGroupNodeOverlapsCard &&
      (unavailableNodeLabelMatches || hostLabelIndicatesGroupRepair);
    return {
      identifierNodeCount: roots.length,
      expectedGroupTagPresent,
      expectedGroupTagVisible,
      groupIdentifierNodeCount: groupNodes.length,
      groupLabelMatches,
      groupLabelContainsExpected,
      groupLabelPresent,
      groupNodeOverlapsCard,
      groupNodeVisible,
      hostLabelContainsExpectedGroup,
      hostLabelIndicatesGroupRepair,
      unavailableNodeLabelMatches,
      unavailableGroupNodeOverlapsCard,
      unavailableGroupTagPresent,
      unavailableIdentifierNodeCount: unavailableNodes.length,
    };
  }, { recordId, expectedGroupName }).catch(() => ({
    identifierNodeCount: 0,
    expectedGroupTagPresent: false,
    expectedGroupTagVisible: false,
    groupIdentifierNodeCount: 0,
    groupLabelMatches: false,
    groupLabelContainsExpected: false,
    groupLabelPresent: false,
    groupNodeOverlapsCard: false,
    groupNodeVisible: false,
    hostLabelContainsExpectedGroup: false,
    hostLabelIndicatesGroupRepair: false,
    unavailableNodeLabelMatches: false,
    unavailableGroupNodeOverlapsCard: false,
    unavailableGroupTagPresent: false,
    unavailableIdentifierNodeCount: 0,
    diagnosticUnavailable: true,
  }));
}

async function waitForHostCardByRecordId(page, recordId, name, endpoint) {
  const deadline = Date.now() + 20000;
  let evidence = null;
  while (Date.now() < deadline) {
    evidence = await hostCardIdentifierEvidence(page, recordId, name, endpoint);
    if (evidence.identifierNodeCount === 1 && evidence.nameMatches &&
        evidence.endpointMatches && evidence.inViewport) return evidence;
    await page.waitForTimeout(100);
  }
  console.log('offline Host identifier projection diagnostic', JSON.stringify(
    evidence || { diagnosticUnavailable: true },
  ));
  throw new Error('offline Host card did not project by its stable identifier');
}

async function visibleSyncStatusLabels(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics[role="button"]')]
      .map((element) => (element.getAttribute('aria-label') || element.innerText || '').trim())
      .filter((label) => /^(?:Idle|Pending|Syncing|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only|\d+ pending)$/.test(label))
      .slice(0, 8),
  ).catch(() => []);
}

async function longOfflineTimeoutDiagnostic({
  page,
  apiEntries,
  apiStartIndex,
  databasePath,
  vaultId,
  recordId,
  endpoint,
  hostNames,
  branch = null,
  conflictFeedApiStartIndex = null,
  conflictFeedEventStartIndex = 0,
  observedBConflictEvents = [],
  expectedConflictId = null,
  expectedConflictHostLabel = null,
}) {
  const safeProtocolErrorCodes = new Set([
    'CURSOR_EXPIRED',
    'SNAPSHOT_EXPIRED',
    'SERVER_GENERATION_CHANGED',
    'HISTORY_CURSOR_EXPIRED',
    'CONFLICT_FEED_GENERATION_CHANGED',
    'CONFLICT_FEED_SEQUENCE_AHEAD',
    'AUDIT_CURSOR_EXPIRED',
  ]);
  const [syncStatusLabels, hostCards, buttonState, conflictUiState] = await Promise.all([
    visibleSyncStatusLabels(page),
    Promise.all(Object.entries(hostNames).map(async ([key, name]) => [
      key,
      await hostCardEvidence(page, name, endpoint),
    ])),
    page.evaluate(() => {
      const allowedNames = new Set([
        'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
        'Snapshot needed', 'Key update needed', 'Read-only', 'Rebuild snapshot',
        'Add host', 'Hosts', 'Connect', 'Edit host', 'Delete host', 'Favorite host',
      ]);
      const visible = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((node) => {
          const rect = node.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        })
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
        .filter(Boolean);
      const knownNameCounts = {};
      let otherButtonCount = 0;
      for (const name of visible) {
        if (!allowedNames.has(name)) {
          otherButtonCount++;
          continue;
        }
        knownNameCounts[name] = (knownNameCounts[name] || 0) + 1;
      }
      return { visibleButtonCount: visible.length, knownNameCounts, otherButtonCount };
    }).catch(() => ({ diagnosticUnavailable: true })),
    page.evaluate((expectedHostLabel) => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((node) => ({
          role: node.getAttribute('role') || '',
          text: node.innerText || '',
          label: node.getAttribute('aria-label') || '',
          visible: (() => {
            const rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          })(),
        }));
      const inboxHeadingVisible = semantics.some((node) => node.visible &&
        `${node.text}\n${node.label}`.includes('跨设备冲突收件箱'));
      const reviewCountText = semantics
        .filter((node) => node.visible)
        .map((node) => `${node.text}\n${node.label}`)
        .find((value) => /\d+\s*待审阅/.test(value));
      const reviewCount = reviewCountText?.match(/(\d+)\s*待审阅/);
      const buttons = semantics.filter((node) => node.visible && node.role === 'button')
        .map((node) => `${node.text}\n${node.label}`);
      const bodyText = document.body.innerText || '';
      const semanticTextAndLabels = semantics.flatMap((node) => [node.text, node.label]);
      return {
        inboxHeadingVisible,
        pendingReviewCount: reviewCount ? Number(reviewCount[1]) : null,
        adoptBranchButtonCount: buttons.filter((label) => label.includes('采用此分支')).length,
        keepCurrentButtonCount: buttons.filter((label) => label.includes('保留当前版本')).length,
        keepDeviceBranchButtonCount: buttons.filter((label) => label.includes('Keep this device version')).length,
        useSyncedVersionButtonCount: buttons.filter((label) => label.includes('Use synced version')).length,
        expectedHostLabelInBodyText: typeof expectedHostLabel === 'string' &&
          bodyText.includes(expectedHostLabel),
        expectedHostLabelInSemantics: typeof expectedHostLabel === 'string' &&
          semanticTextAndLabels.some((value) => value.includes(expectedHostLabel)),
      };
    }, expectedConflictHostLabel).catch(() => ({ diagnosticUnavailable: true })),
  ]);
  let serverState = { available: false };
  try {
    const snapshot = serverLongOfflineSnapshot(databasePath, vaultId, recordId, branch);
    const headPresent = Boolean(snapshot.headRevisionId);
    serverState = {
      available: true,
      lastCommittedSeq: snapshot.lastCommittedSeq,
      minimumAvailableSeq: snapshot.minimumAvailableSeq,
      lastConflictSeq: snapshot.lastConflictSeq,
      headCount: headPresent ? 1 : 0,
      headCommitSeq: snapshot.headCommitSeq,
      recordVersionCount: snapshot.recordVersionCount,
      staleRevisionVersionCount: snapshot.staleRevisionVersionCount,
      recordChangeEventCount: snapshot.recordChangeEventCount,
      vaultChangeEventCount: snapshot.vaultChangeEventCount,
      staleOperationReceiptCount: snapshot.staleOperationReceiptCount,
      staleRevisionEventCount: snapshot.staleRevisionEventCount,
      matchingConflictCount: snapshot.matchingConflictCount,
      matchingConflictEnvelopeCount: snapshot.matchingConflictEnvelopeCount,
    };
  } catch (_) {
    // Keep a timeout report useful without surfacing SQL or fixture details.
  }
  const apiRoutes = safeApiSummary(apiEntries.slice(apiStartIndex), 20)
    .map(({ method, path: apiPath, status, errorCode }) => ({
      method,
      path: apiPath,
      status,
      ...(safeProtocolErrorCodes.has(errorCode) ? { errorCode } : {}),
    }));
  const conflictChangesResponses = conflictFeedApiStartIndex == null
    ? []
    : apiEntries.slice(conflictFeedApiStartIndex)
      .filter((entry) => entry.profile === 'B' && entry.method === 'GET' &&
        entry.path.startsWith('/api/v1/vaults/') &&
        entry.path.endsWith('/conflict-changes'))
      .slice(-20)
      .map((entry) => ({
        status: entry.status,
        requestAfterSeq: entry.conflictFeedRequest?.afterSeq ?? null,
        requestHasServerGeneration: entry.conflictFeedRequest?.hasServerGeneration ?? null,
        responseAfterSeq: entry.conflictFeedResponse?.afterSeq ?? null,
        responseHighWatermark: entry.conflictFeedResponse?.highWatermark ?? null,
        responseNextAfterSeq: entry.conflictFeedResponse?.nextAfterSeq ?? null,
        responseHasMore: entry.conflictFeedResponse?.hasMore ?? null,
        eventCount: Array.isArray(entry.conflictEventSummaries)
          ? entry.conflictEventSummaries.length
          : null,
        containsExpectedConflictId: Boolean(expectedConflictId &&
          entry.conflictEventSummaries?.some((event) =>
            event.type === 'created' && event.conflictId === expectedConflictId)),
        containsExpectedResolvedConflict: Boolean(expectedConflictId &&
          entry.conflictEventSummaries?.some((event) =>
            event.type === 'resolved' && event.conflictId === expectedConflictId)),
      }));
  const longOfflineResolutionResponses = apiEntries.slice(apiStartIndex)
    .filter((entry) => entry.profile === 'B' &&
      entry.longOfflineResolutionSummary)
    .slice(-10)
    .map((entry) => ({
      status: entry.status,
      resolved: entry.longOfflineResolutionSummary.resolved,
      resolutionSeq: entry.longOfflineResolutionSummary.resolutionSeq,
      resolutionSeqIsDecimal: entry.longOfflineResolutionSummary.resolutionSeqIsDecimal,
      matchesCurrentHead: entry.longOfflineResolutionSummary.matchesCurrentHead,
      alreadyResolved: entry.longOfflineResolutionSummary.alreadyResolved,
    }));
  const summarizeExpectedCreatedEvents = (events) => {
    const matching = expectedConflictId
      ? events.filter((event) => event.type === 'created' &&
          event.conflictId === expectedConflictId)
      : [];
    return {
      expectedCreatedEventMatchCount: matching.length,
      hasEnvelope: matching.map((event) => Boolean(event.hasEnvelope)),
      seqIsString: matching.map((event) => typeof event.seq === 'string'),
    };
  };
  const summarizeExpectedResolvedEvents = (events) => {
    const matching = expectedConflictId
      ? events.filter((event) => event.type === 'resolved' &&
          event.conflictId === expectedConflictId)
      : [];
    return {
      expectedResolvedEventMatchCount: matching.length,
      hasEnvelope: matching.map((event) => Boolean(event.hasEnvelope)),
      seqIsString: matching.map((event) => typeof event.seq === 'string'),
      resolvedRevisionPresent: matching.map((event) =>
        typeof event.resolvedRevisionId === 'string'),
    };
  };
  const conflictFeedObservedEvents = {
    beforeExplicitPull: summarizeExpectedCreatedEvents(
      observedBConflictEvents.slice(0, conflictFeedEventStartIndex),
    ),
    allObservedAtTimeout: summarizeExpectedCreatedEvents(observedBConflictEvents),
    expectedResolvedAtTimeout: summarizeExpectedResolvedEvents(observedBConflictEvents),
  };
  const savedHostsCount = hostCards[0]?.[1]?.savedHostsCount ?? null;
  return {
    apiRoutes,
    conflictChangesResponses,
    longOfflineResolutionResponses,
    conflictFeedObservedEvents,
    syncStatusLabels,
    hostCards: Object.fromEntries(hostCards),
    savedHostsCount,
    buttonState,
    conflictUiState,
    serverState,
  };
}

async function hostRecordVisible(page, name, expectedEndpoint = null) {
  return page.evaluate(({ expectedName, endpoint }) => {
    const namePrefix = `Host: ${expectedName}; `;
    return [...document.querySelectorAll('flt-semantics[role="group"]')]
      .map((node) => (node.getAttribute('aria-label') || '').trim())
      .some((label) => label.startsWith(namePrefix) &&
        (endpoint == null || label.includes(`@${endpoint}`)));
  }, { expectedName: name, endpoint: expectedEndpoint }).catch(() => false);
}

async function visibleSavedHostsCount(page) {
  return page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    const candidate = nodes.find((node) => {
      const text = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      return /Saved hosts/i.test(text);
    });
    const text = [
      candidate?.getAttribute('aria-label') || '',
      candidate?.innerText || '',
      candidate?.parentElement?.innerText || '',
    ].join('\n');
    const match = text.match(/Saved hosts\D{0,32}(\d+)/i) ||
      text.match(/(\d+)\D{0,32}Saved hosts/i);
    return match ? Number(match[1]) : null;
  }).catch(() => null);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hostCardGroup(page, name) {
  return page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)}; `),
  }).first();
}

async function waitForHostRecord(page, name, expected, expectedEndpoint = null) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (await hostRecordVisible(page, name, expectedEndpoint) === expected) return;
    await page.waitForTimeout(100);
  }
  console.log('host record visibility diagnostic', JSON.stringify({
    expectedVisible: expected,
    endpointRequired: expectedEndpoint !== null,
    evidence: await hostCardEvidence(page, name, expectedEndpoint),
    syncStatusLabels: await visibleSyncStatusLabels(page),
    page: await safePageDiagnostic(page),
  }));
  throw new Error(`host record visibility did not become ${expected}`);
}

async function scrollHostsPageToBottom(page) {
  const viewport = page.viewportSize() || { width: 1280, height: 720 };
  await page.mouse.move(
    Math.floor(viewport.width * 0.7),
    Math.floor(viewport.height * 0.75),
  );
  for (let attempt = 0; attempt < 12; attempt += 1) {
    await page.mouse.wheel(0, 1200);
    await page.waitForTimeout(60);
  }
}

async function waitForCredentialRecord(page, name, expected = true) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const visible = await page.evaluate((expectedName) => {
      const expectedCardLabelPrefix = `Credential: ${expectedName}; `;
      return [...document.querySelectorAll('flt-semantics[role="group"]')]
        .some((element) => {
        const rect = element.getBoundingClientRect();
          const label = element.getAttribute('aria-label') || '';
          return rect.width > 0 && rect.height > 0 &&
            label.startsWith(expectedCardLabelPrefix);
        });
    }, name).catch(() => false);
    if (visible === expected) return;
    await page.waitForTimeout(100);
  }
  const evidence = await page.evaluate((expectedName) => {
    const groups = [...document.querySelectorAll('flt-semantics[role="group"]')];
    const labels = groups.map((element) => element.getAttribute('aria-label') || '');
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const text = document.body.innerText || '';
    const expectedCardLabelPrefix = `Credential: ${expectedName}; `;
    const matchingGroups = groups.filter((element) =>
      visible(element) &&
      (element.getAttribute('aria-label') || '').startsWith(expectedCardLabelPrefix));
    return {
      expectedNameVisible: matchingGroups.length > 0,
      visibleCredentialGroupCount: groups.filter(visible).length,
      matchingVisibleGroupCount: matchingGroups.length,
      emptyStateVisible: text.includes('No credentials saved'),
      unavailableRecordNoticeVisible: text.includes('encrypted record(s) could not be verified'),
      syncErrorVisible: /sync failed|decryption failed|error|failed/i.test(text),
      anyCredentialNameLabels: labels.length > 0,
    };
  }, name).catch(() => ({ unavailable: true }));
  console.log('credential record visibility safe evidence', JSON.stringify({
    expectedVisible: expected,
    evidence,
  }));
  throw new Error(`credential '${name}' visibility did not become ${expected}`);
}

async function dismissCredentialEditorForConvergence(page, profile) {
  const dialogs = page.getByRole('alertdialog');
  const dialogCount = await dialogs.count().catch(() => 0);
  const visibleIndexes = [];
  for (let index = 0; index < dialogCount; index++) {
    if (await dialogs.nth(index).isVisible().catch(() => false)) {
      visibleIndexes.push(index);
    }
  }
  if (visibleIndexes.length === 0) {
    console.log('credential convergence editor state', JSON.stringify({
      profile, visibleAlertdialogCount: 0, dismissed: false,
    }));
    return false;
  }
  assertThat(visibleIndexes.length === 1,
    'profile had multiple visible dialogs before Credential convergence checks');
  const dialog = dialogs.nth(visibleIndexes[0]);
  const title = dialog.getByText('Edit credential', { exact: true });
  const titleCount = await title.count().catch(() => 0);
  const titleVisible = titleCount === 1 &&
    await title.isVisible().catch(() => false);
  const inputTypes = await dialog.locator('input').evaluateAll((inputs) =>
    inputs.map((input) => input.getAttribute('type') || 'text'))
    .catch(() => []);
  const textInputCount = inputTypes.filter((type) => type === 'text').length;
  const passwordInputCount = inputTypes.filter((type) => type === 'password').length;
  const cancel = dialog.getByRole('button', { name: 'Cancel', exact: true });
  const cancelCount = await cancel.count().catch(() => 0);
  const cancelVisible = cancelCount === 1 &&
    await cancel.isVisible().catch(() => false);
  const cancelEnabled = cancelCount === 1 &&
    await cancel.isEnabled().catch(() => false);
  console.log('credential convergence editor evidence', JSON.stringify({
    profile,
    visibleAlertdialogCount: visibleIndexes.length,
    editorTitleCount: titleCount,
    editorTitleVisible: titleVisible,
    textInputCount,
    passwordInputCount,
    cancelCount,
    cancelVisible,
    cancelEnabled,
  }));
  assertThat(titleVisible && textInputCount === 2 && passwordInputCount === 1 &&
    inputTypes.length === 3 && cancelVisible && cancelEnabled,
  'visible dialog was not the expected three-field Credential editor');
  await cancel.click();
  await dialog.waitFor({ state: 'hidden', timeout: 10000 });
  const remainingDialogs = page.getByRole('alertdialog');
  const remainingDialogCount = await remainingDialogs.count().catch(() => 0);
  let remainingVisibleCount = 0;
  for (let index = 0; index < remainingDialogCount; index++) {
    if (await remainingDialogs.nth(index).isVisible().catch(() => false)) {
      remainingVisibleCount++;
    }
  }
  assertThat(remainingVisibleCount === 0,
    'Credential editor remained visible after its scoped Cancel action');
  console.log('credential convergence editor dismissed', JSON.stringify({
    profile, remainingVisibleAlertdialogCount: remainingVisibleCount,
  }));
  return true;
}

async function openCredentialMenuAction(page, credentialName, action) {
  const card = page.getByRole('group', {
    name: new RegExp(`^Credential: ${escapeRegExp(credentialName)}; `),
  });
  const cardCount = await card.count();
  if (cardCount !== 1) {
    const groupEvidence = await page.evaluate((expectedName) => {
      const groups = [...document.querySelectorAll('flt-semantics[role="group"]')];
      const labels = groups.map((element) => element.getAttribute('aria-label') || '');
      return {
        groupCount: groups.length,
        matchingLabelCount: labels.filter((label) => label.includes(expectedName)).length,
        matchingLabelLengths: labels.filter((label) => label.includes(expectedName))
          .map((label) => label.length),
      };
    }, credentialName).catch(() => ({ unavailable: true }));
    console.log('credential action card safe evidence', JSON.stringify({
      cardCount,
      groupEvidence,
    }));
    throw new Error('credential action card was not unique');
  }
  await card.waitFor({ state: 'visible', timeout: 15000 });
  const buttons = card.getByRole('button');
  const buttonCount = await buttons.count();
  if (buttonCount !== 1) {
    console.log('credential action button safe evidence', JSON.stringify({
      semanticCardCount: cardCount,
      buttonCount,
    }));
    throw new Error('credential card did not expose one action button');
  }
  const actionButton = buttons.first();
  const actionButtonEnabled = await actionButton.isEnabled();
  if (!actionButtonEnabled) {
    console.log('credential action button safe evidence', JSON.stringify({
      semanticCardCount: cardCount,
      buttonCount,
      actionButtonEnabled,
    }));
    throw new Error('credential action button was disabled');
  }
  await actionButton.click();
  console.log('credential action button clicked', JSON.stringify({
    actionButtonCount: buttonCount,
    actionButtonEnabled,
  }));
  const menuItem = page.getByRole('menuitem', { name: action, exact: true });
  try {
    await menuItem.click({ timeout: 10000 });
  } catch (error) {
    console.log('credential action menu item safe evidence', JSON.stringify({
      menuItemCountAtFailure: await menuItem.count().catch(() => -1),
      menuRoleCount: await page.getByRole('menuitem').count().catch(() => -1),
      actionRequested: action,
    }));
    throw error;
  }
  console.log('credential action menu item selected', JSON.stringify({
    actionRequested: action,
  }));
  const expectedDialogTitle = action === 'Edit'
    ? 'Edit credential'
    : 'Delete this item?';
  try {
    await page.getByText(expectedDialogTitle, { exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
  } catch (error) {
    console.log('credential action dialog safe evidence', JSON.stringify({
      expectedEditTitleVisible: await page.getByText('Edit credential', { exact: true })
        .count().catch(() => -1) > 0,
      expectedDeleteTitleVisible: await page.getByText('Delete this item?', { exact: true })
        .count().catch(() => -1) > 0,
      dialogRoleCount: await page.getByRole('dialog').count().catch(() => -1),
    }));
    throw error;
  }
  console.log('credential action dialog opened', JSON.stringify({
    editDialog: action === 'Edit',
    deleteDialog: action === 'Delete',
  }));
}

async function chooseHostCredential(page, credentialName, credentialUsername) {
  const choice = `${credentialName} · ${credentialUsername}`;
  await chooseDropdownOption(page, 'SSH credential override', choice);
}

async function addHost(page, { name, address, username, credential = null }) {
  await click(page, 'Add host');
  await waitForText(page, 'Add a host');
  await fill(page, 'Display name', name);
  await fill(page, 'Hostname or IP', address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', username);
  if (credential) {
    await chooseHostCredential(page, credential.name, credential.username);
  }
  await click(page, 'Save encrypted host');
  try {
    await waitForHostRecord(page, name, true, `${address}:22`);
  } catch (error) {
    console.log('add-host diagnostic', JSON.stringify({
      host: await hostCardEvidence(page, name, `${address}:22`),
      syncStatusLabels: await visibleSyncStatusLabels(page),
      page: await safePageDiagnostic(page),
    }));
    throw error;
  }
}

async function createVaultThroughSettings(page, name) {
  await click(page, 'Settings');
  await waitForSemanticText(page, 'Vaults');
  await click(page, 'Create another Vault');
  await waitForText(page, 'Create Vault');
  await fill(page, 'Vault name', name);
  await click(page, 'Create encrypted Vault');
  await click(page, 'Hosts');
  await waitWorkspace(page);
  await waitForVisibleSemanticPattern(page, new RegExp(escapeRegExp(name)));
}

async function selectVaultByName(page, currentName, targetName) {
  if (currentName === targetName) return;
  const selector = page.getByRole('button', { name: /^Choose vault(?:\s|$)/ });
  const deadline = Date.now() + 15000;
  let clicked = false;
  while (Date.now() < deadline) {
    const count = await selector.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const candidate = selector.nth(index);
      if (await candidate.isVisible().catch(() => false)) {
        await candidate.click();
        clicked = true;
        break;
      }
    }
    if (clicked) break;
    await page.waitForTimeout(100);
  }
  assertThat(clicked,
    `Choose vault selector was not visible while switching from ${currentName}`);
  const menuItems = page.getByRole('menuitem');
  const roleMenuItemCount = await menuItems.count().catch(() => 0);
  const menuItemEvidence = await menuItems.evaluateAll((nodes) => nodes.map((node) => ({
    ariaLabel: node.getAttribute('aria-label') || '',
    role: node.getAttribute('role') || '',
    innerText: (node.innerText || '').slice(0, 120),
    outerHTML: node.outerHTML.slice(0, 360),
  }))).catch(() => []);
  const semanticMenuItems = page.locator('flt-semantics[role="menuitem"]');
  const semanticMenuItemCount = await semanticMenuItems.count().catch(() => 0);
  const semanticMenuItemEvidence = await semanticMenuItems.evaluateAll((nodes) =>
    nodes.map((node) => ({
      ariaLabel: node.getAttribute('aria-label') || '',
      role: node.getAttribute('role') || '',
      innerText: (node.innerText || '').slice(0, 120),
      outerHTML: node.outerHTML.slice(0, 360),
    }))).catch(() => []);
  const textOption = page.getByText(targetName, { exact: true });
  const exactTextCount = await textOption.count().catch(() => 0);
  const exactTextVisible = await textOption.last().isVisible().catch(() => false);
  let delayedMenuItemEvidence = [];
  const menuDeadline = Date.now() + 4000;
  while (Date.now() < menuDeadline) {
    delayedMenuItemEvidence = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics')]
        .filter((node) => node.getAttribute('role') === 'menuitem')
        .map((node) => {
          const rect = node.getBoundingClientRect();
          return {
            ariaLabel: node.getAttribute('aria-label') || '',
            role: node.getAttribute('role') || '',
            innerText: (node.innerText || '').slice(0, 120),
            textContent: (node.textContent || '').slice(0, 120),
            rect: {
              x: Math.round(rect.x),
              y: Math.round(rect.y),
              width: Math.round(rect.width),
              height: Math.round(rect.height),
            },
            outerHTML: node.outerHTML.slice(0, 360),
          };
        })).catch(() => []);
    const targetVisible = delayedMenuItemEvidence.some((item) =>
      `${item.ariaLabel} ${item.innerText} ${item.textContent}`
        .includes(targetName) && item.rect.width > 0 && item.rect.height > 0);
    if (targetVisible) break;
    await page.waitForTimeout(100);
  }
  console.log('multi-Vault selector menu evidence', JSON.stringify({
    currentName,
    targetName,
    roleMenuItemCount,
    roleMenuItemText: await menuItems.allTextContents().catch(() => []),
    menuItemEvidence,
    semanticMenuItemCount,
    semanticMenuItemText: await semanticMenuItems.allTextContents().catch(() => []),
    semanticMenuItemEvidence,
    delayedMenuItemEvidence,
    exactTextCount,
    exactTextVisible,
  }));
  const targetIndexes = delayedMenuItemEvidence
    .map((item, index) => ({ item, index }))
    .filter(({ item }) =>
      `${item.ariaLabel} ${item.innerText} ${item.textContent}`
        .includes(targetName) && item.rect.width > 0 && item.rect.height > 0);
  assertThat(targetIndexes.length === 1,
    `Vault selection menu did not expose one item for ${targetName}`);
  const targetRect = targetIndexes[0].item.rect;
  await page.mouse.click(
    targetRect.x + targetRect.width / 2,
    targetRect.y + targetRect.height / 2,
  );
  const selectionDeadline = Date.now() + 5000;
  let selected = false;
  while (Date.now() < selectionDeadline) {
    const labels = await selector.evaluateAll((nodes) => nodes.map((node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`));
    if (labels.some((label) => label.includes(targetName))) {
      selected = true;
      break;
    }
    await page.waitForTimeout(100);
  }
  assertThat(selected, `Vault selector did not switch to ${targetName}`);
}

async function ensureVaultSelected(page, targetName, otherVaultName) {
  const selector = page.getByRole('button', { name: /^Choose vault(?:\s|$)/ });
  const selectorText = await selector.first().innerText().catch(() => '');
  if (selectorText.includes(targetName)) return;
  await selectVaultByName(page, otherVaultName, targetName);
}

async function saveDefaultSectionPreference(page, section) {
  await click(page, 'Settings');
  await waitForSemanticText(page, 'Vault-synced preferences');
  await chooseDropdownOption(page, 'Default workspace section', section);
  await click(page, 'Save synced preference');
  await waitForSemanticText(page,
    `Saved as ${section}. This preference is encrypted in the active Vault`);
  await syncNow(page);
}

async function scrollPreferencesToDefaultSection(page) {
  const viewport = await page.evaluate(() => ({
    width: window.innerWidth,
    height: window.innerHeight,
  }));
  const x = Math.round(viewport.width * 0.72);
  const y = Math.round(viewport.height * 0.84);
  await page.mouse.move(x, y);
  for (let index = 0; index < 2; index += 1) {
    await page.mouse.wheel(0, 420);
    await page.waitForTimeout(120);
  }
}

async function assertVaultSelectionEvidence(
  page, vaultId, expectedName, vaultA, vaultB, context = {},
) {
  const stagePrefix = activeStage;
  activeStage = `${stagePrefix}: open Sync & conflicts`;
  await clickSyncConflictsNavigation(page);
  activeStage = `${stagePrefix}: wait for Sync health`;
  await waitForSemanticText(page, 'Sync health');
  activeStage = `${stagePrefix}: scroll Recovery details into view`;
  const heading = await page.evaluate(() => {
    const nodes = [...document.querySelectorAll('flt-semantics')];
    const node = nodes.find((element) =>
      `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`
        .includes('Recovery details'));
    if (!node) return false;
    node.scrollIntoView({ block: 'center' });
    return true;
  }).catch(() => false);
  assertThat(heading,
    'Sync health did not expose Recovery details in Flutter semantics');
  await waitForSemanticText(page, 'Recovery details');
  await waitForSemanticText(page, 'Current Vault');

  activeStage = `${stagePrefix}: verify selected Vault UI and API context`;
  const currentVaultLabel = await visibleSemanticTextEvidence(page, 'Current Vault');
  const vaultSelector = page.getByRole('button', { name: /^Choose vault(?:\s|$)/ });
  const selectorLabels = await vaultSelector.evaluateAll((nodes) => nodes.map((node) =>
    `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`));
  const chipMatchesExpected = selectorLabels.some((label) =>
    label.includes(expectedName));
  const semanticUuidCount = await page.locator('flt-semantics').evaluateAll(
    (nodes, expectedVaultId) => nodes.filter((node) =>
      node.getAttribute('aria-label') === expectedVaultId ||
      (node.innerText || '').includes(expectedVaultId)).length,
    vaultId,
  ).catch(() => 0);

  const listingVaults = context.databasePath && context.username
    ? serverVaultSnapshot(context.databasePath, context.username).vaults
    : (context.listingVaults || []);
  const listingEvidence = {
    count: listingVaults.length,
    containsA: listingVaults.some((item) => item.vaultId === vaultA),
    containsB: listingVaults.some((item) => item.vaultId === vaultB),
    containsExpected: listingVaults.some((item) => item.vaultId === vaultId),
    currentCommitSeqIsDecimal: listingVaults.some((item) =>
      item.vaultId === vaultId && /^(0|[1-9][0-9]*)$/.test(item.commitSeq)),
  };
  const changesRequests = context.changesRequests || [];
  const changesStartIndex = Number.isInteger(context.changesStartIndex)
    ? context.changesStartIndex : 0;
  const expectedPathRequests = () => changesRequests
    .slice(changesStartIndex)
    .filter((entry) => entry.profile === context.apiProfile &&
      entry.pageRole === context.apiPageRole && entry.vaultId === vaultId);
  const pathDeadline = Date.now() + 8000;
  while (expectedPathRequests().length === 0 && Date.now() < pathDeadline) {
    await page.waitForTimeout(100);
  }

  assertThat(currentVaultLabel.visibleMatchCount > 0,
    'Sync Health did not expose the Current Vault label');
  assertThat(chipMatchesExpected,
    `Vault selector chip did not identify ${expectedName}`);
  assertThat(listingEvidence.count === 2 && listingEvidence.containsA &&
      listingEvidence.containsB && listingEvidence.containsExpected &&
      listingEvidence.currentCommitSeqIsDecimal,
  'server Vault listing/current revision did not contain both expected Vault contexts');
  assertThat(expectedPathRequests().length > 0,
    `selected ${expectedName} did not issue a matching owner-profile changes request`);

  console.log('Sync Health Vault selection evidence', JSON.stringify({
    expectedIdLength: vaultId.length,
    expectedName,
    currentVaultLabelVisibleCount: currentVaultLabel.visibleMatchCount,
    currentVaultUuidSemanticsCount: semanticUuidCount,
    chipMatchesExpected,
    listingEvidence,
    changesRequestStartIndex: changesStartIndex,
    ownerProfileExpectedPathRequestCount: expectedPathRequests().length,
  }));
  activeStage = stagePrefix;
}

function serverVaultConflictCount(databasePath, vaultId) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "row=db.execute('SELECT COUNT(*) FROM conflicts WHERE vault_id=? AND resolved_revision_id IS NULL',(sys.argv[2],)).fetchone()",
    "print(json.dumps({'openConflictCount':int(row[0])}))",
  ].join(';'), databasePath, vaultId], {
    encoding: 'utf8',
    timeout: 8000,
    maxBuffer: 4096,
  });
  assertThat(!result.error && result.status === 0,
    'multi-Vault conflict-state inspection failed');
  return JSON.parse(result.stdout).openConflictCount;
}

function serverVaultFixtureHostCount(databasePath, vaultId, recordIds) {
  if (!recordIds.length) return 0;
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    'ids=json.loads(sys.argv[3])',
    'placeholders=\',\'.join(\'?\' for _ in ids)',
    "row=db.execute('SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND deleted=0 AND record_id IN ('+placeholders+')',[sys.argv[2],*ids]).fetchone()",
    "print(json.dumps({'count':int(row[0])}))",
  ].join(';'), databasePath, vaultId, JSON.stringify(recordIds)], {
    encoding: 'utf8',
    timeout: 8000,
    maxBuffer: 4096,
  });
  assertThat(!result.error && result.status === 0,
    'multi-Vault fixture Host-state inspection failed');
  return JSON.parse(result.stdout).count;
}

function fixtureHostRecordIdsFromPushes(capture, startIndex, vaultId) {
  return [...new Set(capture.pushes.slice(startIndex)
    .filter((push) => push.pathVaultId === vaultId && push.bodyVaultId === vaultId)
    .flatMap((push) => push.recordIds))];
}

async function multiVaultProjectionDiagnostic({
  page,
  capture,
  databasePath,
  vaultA,
  vaultB,
  hostA,
  hostB,
  hostAEndpoint,
  hostBEndpoint,
  hostARecordIds,
  hostBRecordIds,
  stage,
  heldChangesRequest,
  bChangesStartIndex,
}) {
  const [hostAEvidence, hostBEvidence, vaultChip, currentSections] = await Promise.all([
    hostCardEvidence(page, hostA, hostAEndpoint),
    hostCardEvidence(page, hostB, hostBEndpoint),
    page.getByRole('button', { name: /^Choose vault(?:\s|$)/ })
      .evaluateAll((nodes, expectedName) => nodes.some((node) =>
        `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
          .includes(expectedName)), 'Multi Vault B').catch(() => false),
    page.evaluate(() => {
      const current = [...document.querySelectorAll('flt-semantics[aria-current]')]
        .filter((node) => {
          const rect = node.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        });
      const matches = (known) => current.some((node) => {
        const label = `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
          .replace(/\s+/g, ' ').trim();
        return label === known || label.includes(known);
      });
      return {
        currentNodeCount: current.length,
        hosts: matches('Hosts'),
        settings: matches('Settings'),
        credentials: matches('Credentials'),
        groups: matches('Groups'),
      };
    }).catch(() => ({ currentNodeCount: 0, hosts: false,
      settings: false, credentials: false, groups: false })),
  ]);
  const bChanges = capture.changesRequests.slice(bChangesStartIndex).filter((request) =>
    request.profile === 'A' && request.pageRole === 'owner-main' &&
    request.vaultId === vaultB);
  return {
    stage,
    heldRequestCaptured: heldChangesRequest !== null,
    vaultChipMatchesB: vaultChip,
    activeSection: currentSections,
    hostCards: {
      a: hostAEvidence,
      b: hostBEvidence,
      visibleSavedHostsCount: await visibleSavedHostsCount(page),
    },
    ownerProfileBChangesRequestCount: bChanges.length,
    serverFixtureHostCounts: {
      a: serverVaultFixtureHostCount(databasePath, vaultA, hostARecordIds),
      b: serverVaultFixtureHostCount(databasePath, vaultB, hostBRecordIds),
      aCapturedHostIdCount: hostARecordIds.length,
      bCapturedHostIdCount: hostBRecordIds.length,
    },
  };
}

async function runMultiVaultSwitchAcceptance({
  ownerPage,
  secondPage,
  ownerContext,
  secondContext,
  databasePath,
  capture,
  apiDiagnostics = [],
}) {
  const baseline = serverVaultSnapshot(databasePath, USERNAME);
  assertThat(baseline.vaults.length === 2,
    'multi-Vault acceptance did not create exactly two active Vaults');
  const vaultA = capture.vaultA;
  const vaultB = baseline.vaults.find((item) => item.vaultId !== vaultA)?.vaultId;
  assertThat(typeof vaultA === 'string' && typeof vaultB === 'string',
    'multi-Vault acceptance could not identify the two server Vault IDs');
  const nameA = 'Web sync test vault';
  const nameB = 'Multi Vault B';
  const suffix = RUN_ID.slice(0, 10);
  const hostA = `Vault A ${suffix}`;
  const hostB = `Vault B ${suffix}`;
  const baseAddress = `base-${suffix}.multi-vault.example.test`;
  const ownerBranchAddress = `owner-${suffix}.multi-vault.example.test`;
  const secondBranchAddress = `second-${suffix}.multi-vault.example.test`;

  capture.active = true;
  const hostAPushStart = capture.pushes.length;
  activeStage = 'multi-Vault: select Vault A on owner';
  await ensureVaultSelected(ownerPage, nameA, nameB);
  activeStage = 'multi-Vault: open owner Hosts in Vault A';
  await click(ownerPage, 'Hosts');
  activeStage = 'multi-Vault: create owner Host in Vault A';
  await addHost(ownerPage, {
    name: hostA,
    address: baseAddress,
    username: 'multi-vault-user',
  });
  activeStage = 'multi-Vault: sync owner Host in Vault A';
  await syncNow(ownerPage);
  const hostARecordIds = fixtureHostRecordIdsFromPushes(
    capture, hostAPushStart, vaultA);
  assertThat(hostARecordIds.length > 0,
    'Vault A fixture Host record ID was not captured from its sync push');
  activeStage = 'multi-Vault: select Vault A on second profile';
  await ensureVaultSelected(secondPage, nameA, nameB);
  activeStage = 'multi-Vault: open second Hosts in Vault A';
  await click(secondPage, 'Hosts');
  activeStage = 'multi-Vault: sync second profile in Vault A';
  await syncNow(secondPage);
  activeStage = 'multi-Vault: wait for second profile to decrypt Vault A Host';
  await waitForHostRecord(secondPage, hostA, true, `${baseAddress}:22`);

  activeStage = 'multi-Vault: switch owner to Vault B';
  await selectVaultByName(ownerPage, nameA, nameB);
  activeStage = 'multi-Vault: open owner Hosts in Vault B';
  await click(ownerPage, 'Hosts');
  const hostBPushStart = capture.pushes.length;
  activeStage = 'multi-Vault: create independent owner Host in Vault B';
  await addHost(ownerPage, {
    name: hostB,
    address: `only-b-${suffix}.multi-vault.example.test`,
    username: 'multi-vault-user',
  });
  activeStage = 'multi-Vault: sync owner Host in Vault B';
  await syncNow(ownerPage);
  const hostBRecordIds = fixtureHostRecordIdsFromPushes(
    capture, hostBPushStart, vaultB);
  assertThat(hostBRecordIds.length > 0,
    'Vault B fixture Host record ID was not captured from its sync push');
  activeStage = 'multi-Vault: switch second profile to Vault B';
  await selectVaultByName(secondPage, nameA, nameB);
  activeStage = 'multi-Vault: open second Hosts in Vault B';
  await click(secondPage, 'Hosts');
  activeStage = 'multi-Vault: sync second profile in Vault B';
  await syncNow(secondPage);
  activeStage = 'multi-Vault: verify second profile decrypts Vault B Host';
  await waitForHostRecord(secondPage, hostB, true,
    `only-b-${suffix}.multi-vault.example.test:22`);

  activeStage = 'multi-Vault: save Vault B preference';
  await saveDefaultSectionPreference(ownerPage, 'Credentials');
  activeStage = 'multi-Vault: switch owner to Vault A for preference';
  await selectVaultByName(ownerPage, nameB, nameA);
  activeStage = 'multi-Vault: open owner Hosts in Vault A for preference';
  await click(ownerPage, 'Hosts');
  activeStage = 'multi-Vault: save Vault A preference';
  await saveDefaultSectionPreference(ownerPage, 'Groups');
  activeStage = 'multi-Vault: switch second profile to Vault A';
  await selectVaultByName(secondPage, nameB, nameA);
  activeStage = 'multi-Vault: open owner Hosts after preferences';
  await click(ownerPage, 'Hosts');
  activeStage = 'multi-Vault: open second Hosts after preferences';
  await click(secondPage, 'Hosts');
  activeStage = 'multi-Vault: verify A Hosts before round trip';
  await waitForHostRecord(ownerPage, hostA, true, `${baseAddress}:22`);
  await waitForHostRecord(secondPage, hostA, true, `${baseAddress}:22`);

  activeStage = 'multi-Vault: A to B to A isolation on both devices';
  for (const [page, profile] of [[ownerPage, 'owner'], [secondPage, 'second']]) {
    activeStage = `multi-Vault: ${profile} open Hosts before switching A to B`;
    await click(page, 'Hosts');
    const vaultBChangesStartIndex = capture.changesRequests.length;
    activeStage = `multi-Vault: ${profile} switch A to B`;
    await selectVaultByName(page, nameA, nameB);
    activeStage = `multi-Vault: ${profile} open Hosts in B`;
    await click(page, 'Hosts');
    activeStage = `multi-Vault: ${profile} sync selected Vault B`;
    await syncNow(page);
    activeStage = `multi-Vault: ${profile} verify B Host projection`;
    await waitForHostRecord(page, hostB, true,
      `only-b-${suffix}.multi-vault.example.test:22`);
    activeStage = `multi-Vault: ${profile} verify A Host absent in B`;
    await waitForHostRecord(page, hostA, false);
    activeStage = `multi-Vault: ${profile} verify B Host count`;
    assertThat(await visibleSavedHostsCount(page) === 1,
      `${profile} Vault B host count included another Vault`);
    activeStage = `multi-Vault: ${profile} verify current Vault B ID`;
    await assertVaultSelectionEvidence(page, vaultB, nameB, vaultA, vaultB, {
      changesRequests: capture.changesRequests,
      apiProfile: profile === 'owner' ? 'A' : 'B',
      apiPageRole: profile === 'owner' ? 'owner-main' : 'second',
      changesStartIndex: vaultBChangesStartIndex,
      databasePath,
      username: USERNAME,
    });
    activeStage = `multi-Vault: ${profile} verify B sync counters`;
    await waitForVisibleSemanticPattern(page, /pending 0 · conflicts 0/);
    activeStage = `multi-Vault: ${profile} open Settings for B preference`;
    await click(page, 'Settings');
    activeStage = `multi-Vault: ${profile} verify B preference`;
    await waitForSemanticText(page, 'Vault-synced preferences');
    await scrollPreferencesToDefaultSection(page);
    const bPreference = await waitForSelectedDropdownOptionVisible(
      page, 'Default workspace section', 'Credentials');
    {
      console.log('multi-Vault B preference DOM inventory', JSON.stringify({
        profile,
        headingNodeCount: bPreference.settled.headingNodeCount,
        headingRole: bPreference.settled.headingRole,
        exactCandidateCount: bPreference.settled.exactCandidateCount,
        ariaPairNodeCount: bPreference.settled.ariaPairNodeCount,
        candidateRole: bPreference.settled.candidateRole,
        candidateHasExactCombinedAriaLabel:
          bPreference.settled.candidateHasExactCombinedAriaLabel,
        candidateHasExactAriaLabelAndValueText:
          bPreference.settled.candidateHasExactAriaLabelAndValueText,
        interactiveChildCount: bPreference.settled.interactiveChildCount,
        structuralNodes: bPreference.settled.structuralNodes,
        menuOpen: bPreference.settled.menuOpen,
        menuStateUnknown: bPreference.settled.menuStateUnknown,
        menuSignalCount: bPreference.settled.menuSignalCount,
        roleMenuNodeCount: bPreference.settled.roleMenuNodeCount,
        expandedAttributeNodeCount:
          bPreference.settled.expandedAttributeNodeCount,
        expandedOrUnknownNodeCount:
          bPreference.settled.expandedOrUnknownNodeCount,
        popupAttributeNodeCount: bPreference.settled.popupAttributeNodeCount,
        outsideFieldKnownOptionCount:
          bPreference.settled.outsideFieldKnownOptionCount,
        menuProbeOpened: bPreference.settled.menuProbeOpened,
        menuProbeClosed: bPreference.settled.menuProbeClosed,
        menuProbeOpenSignalCount:
          bPreference.settled.menuProbeOpenSignalCount,
        menuProbeClosedSignalCount:
          bPreference.settled.menuProbeClosedSignalCount,
        rowNodeCount: bPreference.settled.rowNodeCount,
        rowNodes: bPreference.settled.rowNodes,
        semanticInventory: bPreference.settled.semanticInventory,
        initialCandidateCount: bPreference.initial.exactCandidateCount,
        expectedSelectionMatchesAfterProbe:
          bPreference.settled.selectedValueVisible,
      }));
    }
    assertThat(bPreference.settled.selectedValueVisible &&
      (bPreference.settled.candidateHasExactCombinedAriaLabel ||
       bPreference.settled.candidateHasExactAriaLabelAndValueText) &&
      bPreference.settled.menuProbeOpened && bPreference.settled.menuProbeClosed,
    `${profile} Vault B preference semantics did not expose the selected value`);
    const vaultAChangesStartIndex = capture.changesRequests.length;
    activeStage = `multi-Vault: ${profile} switch B to A`;
    await selectVaultByName(page, nameB, nameA);
    activeStage = `multi-Vault: ${profile} open Hosts in A`;
    await click(page, 'Hosts');
    activeStage = `multi-Vault: ${profile} sync selected Vault A`;
    await syncNow(page);
    activeStage = `multi-Vault: ${profile} verify A Host projection`;
    await waitForHostRecord(page, hostA, true, `${baseAddress}:22`);
    activeStage = `multi-Vault: ${profile} verify B Host absent in A`;
    await waitForHostRecord(page, hostB, false);
    activeStage = `multi-Vault: ${profile} verify A Host count`;
    assertThat(await visibleSavedHostsCount(page) === 1,
      `${profile} Vault A host count included another Vault`);
    activeStage = `multi-Vault: ${profile} verify current Vault A ID`;
    await assertVaultSelectionEvidence(page, vaultA, nameA, vaultA, vaultB, {
      changesRequests: capture.changesRequests,
      apiProfile: profile === 'owner' ? 'A' : 'B',
      apiPageRole: profile === 'owner' ? 'owner-main' : 'second',
      changesStartIndex: vaultAChangesStartIndex,
      databasePath,
      username: USERNAME,
    });
    activeStage = `multi-Vault: ${profile} verify A sync counters`;
    await waitForVisibleSemanticPattern(page, /pending 0 · conflicts 0/);
    activeStage = `multi-Vault: ${profile} open Settings for A preference`;
    await click(page, 'Settings');
    activeStage = `multi-Vault: ${profile} verify A preference`;
    await waitForSemanticText(page, 'Vault-synced preferences');
    await scrollPreferencesToDefaultSection(page);
    const aPreference = await waitForSelectedDropdownOptionVisible(
      page, 'Default workspace section', 'Groups');
    assertThat(aPreference.settled.selectedValueVisible &&
      (aPreference.settled.candidateHasExactCombinedAriaLabel ||
       aPreference.settled.candidateHasExactAriaLabelAndValueText) &&
      aPreference.settled.menuProbeOpened && aPreference.settled.menuProbeClosed,
    `${profile} Vault A preference semantics did not expose the selected value`);
  }

  activeStage = 'multi-Vault conflict: owner opens Hosts in A';
  await click(ownerPage, 'Hosts');
  activeStage = 'multi-Vault conflict: both devices go offline';
  await ownerContext.setOffline(true);
  await secondContext.setOffline(true);
  activeStage = 'multi-Vault conflict: owner edits A Host offline';
  await editHostConnection(ownerPage, hostA,
    { address: ownerBranchAddress }, `${ownerBranchAddress}:22`);
  activeStage = 'multi-Vault conflict: second device opens Hosts in A offline';
  await click(secondPage, 'Hosts');
  activeStage = 'multi-Vault conflict: second device edits A Host offline';
  await editHostConnection(secondPage, hostA,
    { address: secondBranchAddress }, `${secondBranchAddress}:22`);
  activeStage = 'multi-Vault conflict: second device reconnects and syncs';
  await secondContext.setOffline(false);
  await syncNow(secondPage);
  activeStage = 'multi-Vault conflict: owner reconnects and syncs';
  await ownerContext.setOffline(false);
  await syncUntilVaultConflictIsCommitted({
    page: ownerPage,
    apiDiagnostics,
    databasePath,
    vaultId: vaultA,
  });
  activeStage = 'multi-Vault conflict: wait for A conflict record';
  assertThat(serverVaultConflictCount(databasePath, vaultA) > 0,
    'Vault A conflict was not committed after conflict-specific sync completed');
  activeStage = 'multi-Vault conflict: assert no B conflict record';
  assertThat(serverVaultConflictCount(databasePath, vaultB) === 0,
    'Vault A conflict appeared in Vault B server state');

  if (MULTI_VAULT_CONFLICT_STAGE_ONLY) {
    console.log('multi-Vault conflict stage completed before stale-response race');
    return;
  }

  activeStage = 'multi-Vault: stale A changes response cannot replace B projection';
  const changesPath = `/api/v1/vaults/${vaultA}/changes`;
  const changesRoutePattern = `**${changesPath}*`;
  let releaseHeldChanges;
  const heldChangesReleased = new Promise((resolve) => {
    releaseHeldChanges = resolve;
  });
  let resolveHeldChangesEntered;
  const heldChangesEntered = new Promise((resolve) => {
    resolveHeldChangesEntered = resolve;
  });
  let heldChangesCount = 0;
  let heldChangesRequest = null;
  let heldRouteError = null;
  let staleSyncPromise;
  let staleChangesResponsePromise;
  const releaseChanges = () => releaseHeldChanges();
  const holdOneAChangesResponse = async (route) => {
    const request = route.request();
    const requestUrl = new URL(request.url());
    if (heldChangesCount === 0 && request.method() === 'GET' &&
        requestUrl.pathname === changesPath) {
      heldChangesCount++;
      heldChangesRequest = request;
      resolveHeldChangesEntered();
      await heldChangesReleased;
    }
    try {
      await route.continue();
    } catch (error) {
      heldRouteError = error;
      await route.abort().catch(() => {});
    }
  };
  await ownerContext.route(changesRoutePattern, holdOneAChangesResponse);
  try {
    staleChangesResponsePromise = ownerPage.waitForResponse((response) => {
      const request = response.request();
      return heldChangesRequest !== null && request === heldChangesRequest &&
        request.method() === 'GET' &&
        new URL(response.url()).pathname === changesPath;
    }, { timeout: 30000 }).then(
      (response) => ({ response }),
      (error) => ({ error }),
    );
    staleSyncPromise = syncNow(ownerPage).then(
      () => ({ error: null }),
      (error) => ({ error }),
    );
    let holdTimeout;
    try {
      await Promise.race([
        heldChangesEntered,
        new Promise((_, reject) => {
          holdTimeout = setTimeout(
            () => reject(new Error('Vault A changes request was not held')),
            20000,
          );
        }),
      ]);
    } finally {
      clearTimeout(holdTimeout);
    }
    assertThat(heldChangesCount === 1,
      'the stale-response route did not hold exactly one Vault A changes request');

    const vaultBChangesStartIndex = capture.changesRequests.length;
    const vaultBConflictStartIndex = capture.conflictRequests.length;
    activeStage = 'multi-Vault stale response: switch owner to B while A is held';
    await selectVaultByName(ownerPage, nameA, nameB);
    activeStage = 'multi-Vault stale response: open Hosts in B while A is held';
    await click(ownerPage, 'Hosts');
    activeStage = 'multi-Vault stale response: sync B while A is held';
    await syncNow(ownerPage, { expectedVaultId: vaultB });
    const hostBEndpoint = `only-b-${suffix}.multi-vault.example.test:22`;
    activeStage = 'multi-Vault stale response: verify B Host projection before release';
    try {
      await waitForHostRecord(ownerPage, hostB, true, hostBEndpoint);
      await waitForHostRecord(ownerPage, hostA, false);
      assertThat(await visibleSavedHostsCount(ownerPage) === 1,
        'Vault B Host projection was incorrect while Vault A response was held');
    } catch (error) {
      console.log('multi-Vault projection evidence before stale response release',
        JSON.stringify(await multiVaultProjectionDiagnostic({
          page: ownerPage,
          capture,
          databasePath,
          vaultA,
          vaultB,
          hostA,
          hostB,
          hostAEndpoint: `${baseAddress}:22`,
          hostBEndpoint,
          hostARecordIds,
          hostBRecordIds,
          stage: activeStage,
          heldChangesRequest,
          bChangesStartIndex: vaultBChangesStartIndex,
        })));
      throw error;
    }
    await assertVaultSelectionEvidence(ownerPage, vaultB, nameB, vaultA, vaultB, {
      changesRequests: capture.changesRequests,
      apiProfile: 'A',
      apiPageRole: 'owner-main',
      changesStartIndex: vaultBChangesStartIndex,
      databasePath,
      username: USERNAME,
    });
    await waitForVisibleSemanticPattern(ownerPage, /pending 0 · conflicts 0/);
    await click(ownerPage, 'Settings');
    await waitForSemanticText(ownerPage, 'Vault-synced preferences');
    assertThat((await waitForSelectedDropdownOptionVisible(
      ownerPage, 'Default workspace section', 'Credentials')).settled.selectedValueVisible,
    'Vault B preference changed while Vault A response was held');
    await click(ownerPage, 'Hosts');

    activeStage = 'multi-Vault stale response: release held Vault A changes response';
    releaseChanges();
    const changesResponse = await staleChangesResponsePromise;
    assertThat(!changesResponse.error && changesResponse.response.status() === 200,
      `held Vault A changes response did not complete successfully (status=${changesResponse.response?.status() ?? 'missing'})`);
    assertThat(changesResponse.response.request() === heldChangesRequest,
      'the released response did not belong to the exact held Vault A changes request');
    const staleSyncResult = await staleSyncPromise;
    assertThat(!staleSyncResult.error,
      'the held Vault A synchronization failed after response release');
    if (heldRouteError) {
      throw new Error('held Vault A changes route failed to release cleanly');
    }

    assertThat(capture.active, 'multi-Vault capture stopped during stale response check');
    const bConflictsDuringStale = capture.conflictRequests
      .slice(vaultBConflictStartIndex)
      .filter((item) => item.profile === 'A' &&
        item.pageRole === 'owner-main' && item.vaultId === vaultB);
    assertThat(bConflictsDuringStale.length === 0,
      'stale Vault A response triggered a conflict request under Vault B');
    activeStage = 'multi-Vault stale response: verify B Host projection after release';
    try {
      await waitForHostRecord(ownerPage, hostB, true, hostBEndpoint);
      await waitForHostRecord(ownerPage, hostA, false);
      assertThat(await visibleSavedHostsCount(ownerPage) === 1,
        'Vault A changes response contaminated the Vault B Host list');
    } catch (error) {
      console.log('multi-Vault projection evidence after stale response release',
        JSON.stringify(await multiVaultProjectionDiagnostic({
          page: ownerPage,
          capture,
          databasePath,
          vaultA,
          vaultB,
          hostA,
          hostB,
          hostAEndpoint: `${baseAddress}:22`,
          hostBEndpoint,
          hostARecordIds,
          hostBRecordIds,
          stage: activeStage,
          heldChangesRequest,
        })));
      throw error;
    }
    await assertVaultSelectionEvidence(ownerPage, vaultB, nameB, vaultA, vaultB, {
      changesRequests: capture.changesRequests,
      apiProfile: 'A',
      apiPageRole: 'owner-main',
      changesStartIndex: vaultBChangesStartIndex,
      databasePath,
      username: USERNAME,
    });
    await waitForVisibleSemanticPattern(ownerPage, /pending 0 · conflicts 0/);
    await click(ownerPage, 'Settings');
    await waitForSemanticText(ownerPage, 'Vault-synced preferences');
    assertThat((await waitForSelectedDropdownOptionVisible(
      ownerPage, 'Default workspace section', 'Credentials')).settled.selectedValueVisible,
    'Vault A changes response contaminated the Vault B preference');
    await click(ownerPage, 'Hosts');
    await selectVaultByName(ownerPage, nameB, nameA);
    await click(ownerPage, 'Hosts');

    console.log('multi-Vault stale changes response race verified', JSON.stringify({
      heldVaultIdLength: vaultA.length,
      activeVaultAfterReleaseIdLength: vaultB.length,
      heldPathWasVaultA: true,
      activeVaultWasVaultB: true,
      heldChangesRequests: heldChangesCount,
      responseStatus: changesResponse.response.status(),
      bHostCount: 1,
      bPendingCount: 0,
      bConflictCount: 0,
      bPreference: 'Credentials',
      relayTickets: capture.relayTickets,
      relayWebSockets: capture.relayWebSockets,
    }));
  } finally {
    releaseChanges();
    await ownerContext.unroute(changesRoutePattern, holdOneAChangesResponse)
      .catch(() => {});
    if (staleSyncPromise) {
      await Promise.race([
        staleSyncPromise,
        new Promise((resolve) => setTimeout(resolve, 5000)),
      ]);
    }
  }

  activeStage = 'multi-Vault: isolate pending A outbox while B syncs';
  await ownerContext.setOffline(true);
  await addHost(ownerPage, {
    name: `Queued A ${suffix}`,
    address: `queued-a-${suffix}.multi-vault.example.test`,
    username: 'multi-vault-user',
  });
  activeStage = 'multi-Vault pending A: switch owner to B';
  await selectVaultByName(ownerPage, nameA, nameB);
  activeStage = 'multi-Vault pending A: wait for B seed Host projection';
  await click(ownerPage, 'Hosts');
  await waitForHostRecord(
    ownerPage,
    hostB,
    true,
    `only-b-${suffix}.multi-vault.example.test:22`,
  );
  activeStage = 'multi-Vault pending A: add queued B Host offline';
  await addHost(ownerPage, {
    name: `Queued B ${suffix}`,
    address: `queued-b-${suffix}.multi-vault.example.test`,
    username: 'multi-vault-user',
  });
  activeStage = 'multi-Vault pending A: wait for queued B Host projection';
  await waitForHostRecord(
    ownerPage,
    `Queued B ${suffix}`,
    true,
    `queued-b-${suffix}.multi-vault.example.test:22`,
  );
  const bPendingPushStart = capture.pushes.length;
  const bPendingChangesStart = capture.changesRequests.length;
  const bPendingConflictStart = capture.conflictRequests.length;
  const bPendingPushResponse = waitForVaultPushResponse(ownerPage, vaultB);
  activeStage = 'multi-Vault pending A: restore owner network';
  await ownerContext.setOffline(false);
  assertThat(
    await ownerPage.evaluate(() => navigator.onLine),
    'owner browser remained offline after restoring network access',
  );
  await waitUntil(async () => ownerPage.evaluate(async () => {
    try {
      const response = await fetch('/health/ready', { cache: 'no-store' });
      return response.status === 200;
    } catch (_) {
      return false;
    }
  }), 15000, 'owner API connectivity after restoring network access');
  const reconnectVaultLabels = await ownerPage.getByRole('button', {
    name: /^Choose vault(?:\s|$)/,
  }).evaluateAll((nodes) => nodes.map((node) =>
    `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`));
  const reconnectStillOnB = reconnectVaultLabels.some((label) =>
    label.includes(nameB));
  assertThat(reconnectStillOnB,
    'owner left Vault B before reconnect synchronization began');
  activeStage = 'multi-Vault pending A: sync B outbox';
  try {
    await syncUntilVaultPush(ownerPage, vaultB, bPendingPushResponse);
  } catch (error) {
    console.log('multi-Vault queued B sync evidence', JSON.stringify({
      syncPhase: error.syncPhase || 'trigger-or-wait',
      ownerOnline: await ownerPage.evaluate(() => navigator.onLine).catch(() => false),
      reconnectStillOnB,
      reconnectVaultLabels: reconnectVaultLabels.map((label) => label.slice(0, 100)),
      statusLabels: await visibleSyncStatusLabels(ownerPage).catch(() => []),
      changes: capture.changesRequests.slice(bPendingChangesStart).map((item) => ({
        profile: item.profile,
        pageRole: item.pageRole,
        selectedPathVault: item.vaultId === vaultB ? 'B'
          : item.vaultId === vaultA ? 'A' : 'other',
      })),
      pushes: capture.pushes.slice(bPendingPushStart).map((item) => ({
        profile: item.profile,
        pageRole: item.pageRole,
        routeVault: item.pathVaultId === vaultB ? 'B'
          : item.pathVaultId === vaultA ? 'A' : 'other',
        bodyVault: item.bodyVaultId === vaultB ? 'B'
          : item.bodyVaultId === vaultA ? 'A' : 'other',
        operationCount: item.recordIds.length,
      })),
      serverBHeadCount: serverVaultFixtureHostCount(
        databasePath,
        vaultB,
        capture.pushes.slice(bPendingPushStart)
          .filter((item) => item.profile === 'A' &&
            item.pageRole === 'owner-main' &&
            item.pathVaultId === vaultB && item.bodyVaultId === vaultB)
          .flatMap((item) => item.recordIds),
      ),
      api: apiDiagnostics.slice(-24).map((item) => ({
        profile: item.profile,
        method: item.method,
        path: item.path
          .replace(`/vaults/${vaultA}/`, '/vaults/A/')
          .replace(`/vaults/${vaultB}/`, '/vaults/B/'),
        status: item.status,
      })),
    }));
    throw error;
  }
  const ownerPushesDuringB = capture.pushes.slice(bPendingPushStart)
    .filter((item) => item.profile === 'A' && item.pageRole === 'owner-main');
  const bPushes = ownerPushesDuringB.filter((item) =>
    item.pathVaultId === vaultB && item.bodyVaultId === vaultB);
  const aPushesWhileBSelected = ownerPushesDuringB.filter((item) =>
    item.pathVaultId === vaultA || item.bodyVaultId === vaultA);
  const bChangesDuringSync = capture.changesRequests
    .slice(bPendingChangesStart)
    .filter((item) => item.profile === 'A' &&
      item.pageRole === 'owner-main' && item.vaultId === vaultB);
  const bConflictRequestsDuringSync = capture.conflictRequests
    .slice(bPendingConflictStart)
    .filter((item) => item.profile === 'A' &&
      item.pageRole === 'owner-main' && item.vaultId === vaultB);
  const settledVaultLabels = await ownerPage.getByRole('button', {
    name: /^Choose vault(?:\s|$)/,
  }).evaluateAll((nodes) => nodes.map((node) =>
    `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`));
  console.log('multi-Vault queued B settled evidence', JSON.stringify({
    selectedB: settledVaultLabels.some((label) => label.includes(nameB)),
    statusLabels: await visibleSyncStatusLabels(ownerPage).catch(() => []),
    ownerBChanges: bChangesDuringSync.length,
    ownerBPushes: bPushes.map((item) => ({
      routeVault: item.pathVaultId === vaultB ? 'B' : 'other',
      bodyVault: item.bodyVaultId === vaultB ? 'B' : 'other',
      operationCount: item.recordIds.length,
    })),
    ownerAConflictRequests: capture.conflictRequests
      .slice(bPendingConflictStart)
      .filter((item) => item.profile === 'A' &&
        item.pageRole === 'owner-main' && item.vaultId === vaultA).length,
  }));
  assertThat(settledVaultLabels.some((label) => label.includes(nameB)),
    'owner left Vault B before the queued-B sync settled');
  assertThat(bChangesDuringSync.length > 0,
    'the owner did not request Vault B changes during the queued-B sync stage');
  assertThat(bPushes.length > 0 && bPushes.every((item) => item.recordIds.length > 0),
    'the owner did not submit queued B operations during the queued-B sync stage');
  assertThat(aPushesWhileBSelected.length === 0,
    'the owner submitted a Vault A outbox operation while Vault B was selected');
  assertThat(ownerPushesDuringB.every((item) =>
    item.pathVaultId === vaultB && item.bodyVaultId === vaultB),
  'a queued-B stage push was not bound to the selected Vault B ID');
  assertThat(bConflictRequestsDuringSync.length === 0,
    'Vault A conflict workflow requested conflict data under Vault B');

  const aResumePushStart = capture.pushes.length;
  const aResumeChangesStart = capture.changesRequests.length;
  const aResumeConflictStart = capture.conflictRequests.length;
  const aResumePushResponse = waitForVaultPushResponse(ownerPage, vaultA);
  await selectVaultByName(ownerPage, nameB, nameA);
  await click(ownerPage, 'Hosts');
  await waitForHostRecord(
    ownerPage,
    `Queued A ${suffix}`,
    true,
    `queued-a-${suffix}.multi-vault.example.test:22`,
  );
  activeStage = 'multi-Vault pending A: resume A outbox';
  try {
    await syncUntilVaultPush(
      ownerPage,
      vaultA,
      aResumePushResponse,
      // Vault A intentionally retains the unresolved conflict created earlier
      // in this scenario. Its conflict row keeps the aggregate status pending
      // after the independent queued Host has committed.
      { waitForIdle: false },
    );
  } catch (error) {
    console.log('multi-Vault queued A resume evidence', JSON.stringify({
      syncPhase: error.syncPhase || 'selection-or-trigger',
      selectedVaultLabels: await ownerPage.getByRole('button', {
        name: /^Choose vault(?:\s|$)/,
      }).evaluateAll((nodes) => nodes.map((node) =>
        `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`)),
      statusLabels: await visibleSyncStatusLabels(ownerPage).catch(() => []),
      changes: capture.changesRequests.slice(aResumeChangesStart).map((item) => ({
        profile: item.profile,
        pageRole: item.pageRole,
        selectedPathVault: item.vaultId === vaultA ? 'A'
          : item.vaultId === vaultB ? 'B' : 'other',
      })),
      pushes: capture.pushes.slice(aResumePushStart).map((item) => ({
        profile: item.profile,
        pageRole: item.pageRole,
        routeVault: item.pathVaultId === vaultA ? 'A'
          : item.pathVaultId === vaultB ? 'B' : 'other',
        bodyVault: item.bodyVaultId === vaultA ? 'A'
          : item.bodyVaultId === vaultB ? 'B' : 'other',
        operationCount: item.recordIds.length,
      })),
      serverAHeadCount: serverVaultFixtureHostCount(
        databasePath,
        vaultA,
        capture.pushes.slice(aResumePushStart)
          .filter((item) => item.profile === 'A' &&
            item.pageRole === 'owner-main' &&
            item.pathVaultId === vaultA && item.bodyVaultId === vaultA)
          .flatMap((item) => item.recordIds),
      ),
      ownerConflicts: capture.conflictRequests.slice(aResumeConflictStart)
        .filter((item) => item.profile === 'A' &&
          item.pageRole === 'owner-main').length,
      api: apiDiagnostics.slice(-16).map((item) => ({
        profile: item.profile,
        method: item.method,
        path: item.path
          .replace(`/vaults/${vaultA}/`, '/vaults/A/')
          .replace(`/vaults/${vaultB}/`, '/vaults/B/'),
        status: item.status,
      })),
    }));
    throw error;
  }
  const aPendingPushes = capture.pushes.slice(aResumePushStart)
    .filter((item) => item.profile === 'A' && item.pageRole === 'owner-main' &&
      item.pathVaultId === vaultA && item.bodyVaultId === vaultA);
  const aChangesAfterReselect = capture.changesRequests
    .slice(aResumeChangesStart)
    .filter((item) => item.profile === 'A' &&
      item.pageRole === 'owner-main' && item.vaultId === vaultA);
  assertThat(aChangesAfterReselect.length > 0,
    'the owner did not request Vault A changes after reselecting Vault A');
  const aPendingRecordIds = new Set(aPendingPushes.flatMap((item) => item.recordIds));
  assertThat(aPendingRecordIds.size > 0,
    'Vault A pending outbox did not resume after selecting Vault A');
  const bPendingRecordIds = new Set(bPushes.flatMap((item) => item.recordIds));
  assertThat(serverVaultFixtureHostCount(
    databasePath, vaultB, [...bPendingRecordIds]) > 0,
  'the queued B stage push did not commit a record head in Vault B');
  assertThat(serverVaultFixtureHostCount(
    databasePath, vaultA, [...aPendingRecordIds]) > 0,
  'the resumed A push did not commit a record head in Vault A');
  assertThat(bPushes.every((item) => item.recordIds.every((recordId) =>
    !aPendingRecordIds.has(recordId))),
  'Vault A pending outbox operation was pushed while Vault B was selected');
  assertThat(capture.relayTickets === 0 && capture.relayWebSockets === 0,
    'multi-Vault switching unexpectedly requested an SSH Relay session');
  assertThat(capture.pushes.every((item) => item.pathVaultId === item.bodyVaultId),
    'a sync push body Vault ID differed from its route Vault ID');

  console.log('WEB-MULTI-VAULT-SWITCH-01 passed', JSON.stringify({
    activeVaultCountVerified: 2,
    activeVaultIdLengthsVerified: [vaultA.length, vaultB.length],
    hostCountsPerVault: { A: 1, B: 1 },
    preferencesIsolated: true,
    aPendingRecordIds: aPendingRecordIds.size,
    bPendingRecordIds: bPendingRecordIds.size,
    bPushRequests: bPushes.length,
    bChangesRequestsDuringQueuedSync: bChangesDuringSync.length,
    bConflictRequestsDuringQueuedSync: bConflictRequestsDuringSync.length,
    aPushesWhileBSelected: aPushesWhileBSelected.length,
    aOpenConflicts: serverVaultConflictCount(databasePath, vaultA),
    bOpenConflicts: serverVaultConflictCount(databasePath, vaultB),
    relayTickets: capture.relayTickets,
    relayWebSockets: capture.relayWebSockets,
  }));
}

function safeErrorClass(error) {
  const name = error?.name;
  return ['TimeoutError', 'TypeError', 'ReferenceError', 'Error'].includes(name)
    ? name
    : 'OtherError';
}

function safeErrorTextClass(error) {
  const message = String(error?.message || '').toLowerCase();
  if (/host record visibility/.test(message)) return 'host-row-visibility';
  if (/timeout/.test(message)) return 'timeout';
  if (/pending badge|pending sync/.test(message)) return 'pending-badge';
  if (/button|locator|visible/.test(message)) return 'visible-control';
  if (/input|field|fill/.test(message)) return 'form-input';
  return 'other';
}

async function readIndexedDbSqliteImage(page, timeoutMs = 5000) {
  return page.evaluate(async ({ databaseName, timeoutMs }) => {
    let connection;
    let snapshotTx;
    let snapshotTxFinished = false;
    let settled = false;
    let closeWhenOpened = false;
    let timeoutHandle;
    const closeConnection = () => {
      if (!connection) return;
      try {
        connection.close();
      } catch (_) {}
      connection = null;
    };
    const cancelSnapshot = () => {
      settled = true;
      closeWhenOpened = true;
      if (snapshotTx && !snapshotTxFinished) {
        try {
          snapshotTx.abort();
        } catch (_) {}
      }
      closeConnection();
    };
    const timeout = new Promise((_, reject) => {
      timeoutHandle = setTimeout(() => {
        cancelSnapshot();
        reject(new Error('snapshot read timeout'));
      }, timeoutMs);
    });
    const read = async () => {
      connection = await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName);
        request.onsuccess = () => {
          connection = request.result;
          if (closeWhenOpened || settled) {
            closeConnection();
            reject(new Error('snapshot open completed after cancellation'));
            return;
          }
          resolve(connection);
        };
        request.onerror = () => reject(request.error || new Error('IDB open failed'));
        request.onblocked = () => reject(new Error('IDB open blocked'));
      });
      if (!connection.objectStoreNames.contains('files') ||
          !connection.objectStoreNames.contains('blocks')) {
        throw new Error('IDB VFS stores unavailable');
      }
      snapshotTx = connection.transaction(['files', 'blocks'], 'readonly');
      snapshotTx.addEventListener('complete', () => { snapshotTxFinished = true; },
        { once: true });
      snapshotTx.addEventListener('abort', () => { snapshotTxFinished = true; },
        { once: true });
      const transactionDone = new Promise((resolve, reject) => {
        snapshotTx.addEventListener('complete', resolve, { once: true });
        snapshotTx.addEventListener('error', () =>
          reject(snapshotTx.error || new Error('snapshot transaction failed')),
        { once: true });
        snapshotTx.addEventListener('abort', () =>
          reject(snapshotTx.error || new Error('snapshot transaction aborted')),
        { once: true });
      });
      transactionDone.catch(() => {});
      const sqliteFiles = await new Promise((resolve, reject) => {
        let fileRows = null;
        let fileKeys = null;
        let blockReadsQueued = false;
        const fail = (error) => reject(error || new Error('SQLite VFS read failed'));
        const maybeReadBlocks = () => {
          if (fileRows === null || fileKeys === null || blockReadsQueued) return;
          blockReadsQueued = true;
          const files = fileRows.map((row, index) => ({
            fileId: Number(fileKeys[index]),
            name: String(row?.name || ''),
            length: Number(row?.length),
          })).map((file) => ({
            ...file,
            logicalName: file.name === '/database' || file.name.endsWith('/database')
              ? '/database'
              : file.name === '/database-journal' || file.name.endsWith('/database-journal')
                ? '/database-journal'
                : null,
          })).filter((file) => file.logicalName !== null);
          const databaseFile = files.find((file) => file.logicalName === '/database');
          if (!databaseFile || files.some((file) =>
            !Number.isSafeInteger(file.fileId) || !Number.isSafeInteger(file.length) ||
            file.length < 0 || file.length > 64 * 1024 * 1024)) {
            fail(new Error('SQLite VFS file metadata invalid'));
            return;
          }
          const blockStore = snapshotTx.objectStore('blocks');
          const blockPromises = files.map((file) => new Promise((resolveBlocks, rejectBlocks) => {
            const range = IDBKeyRange.bound([file.fileId, 0],
              [file.fileId, Number.MAX_SAFE_INTEGER]);
            const keysRequest = blockStore.getAllKeys(range);
            const valuesRequest = blockStore.getAll(range);
            let blockKeys;
            let blockValues;
            let remaining = 2;
            const complete = () => {
              remaining--;
              if (remaining !== 0) return;
              try {
                file.blocks = blockKeys.map((key, index) => {
                  const value = blockValues[index];
                  const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
                    ArrayBuffer.isView(value)
                      ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
                      : null;
                  if (!bytes) throw new Error('unsupported SQLite VFS block');
                  let binary = '';
                  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
                    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
                  }
                  return { offset: Number(key?.[1]), base64: btoa(binary) };
                });
                resolveBlocks(file);
              } catch (error) {
                rejectBlocks(error);
              }
            };
            keysRequest.onsuccess = () => { blockKeys = keysRequest.result || []; complete(); };
            keysRequest.onerror = () => rejectBlocks(keysRequest.error || new Error('block keys unavailable'));
            valuesRequest.onsuccess = () => { blockValues = valuesRequest.result || []; complete(); };
            valuesRequest.onerror = () => rejectBlocks(valuesRequest.error || new Error('block values unavailable'));
          }));
          Promise.all(blockPromises).then(resolve, reject);
        };
        const filesStore = snapshotTx.objectStore('files');
        const rowsRequest = filesStore.getAll();
        const keysRequest = filesStore.getAllKeys();
        rowsRequest.onsuccess = () => { fileRows = rowsRequest.result || []; maybeReadBlocks(); };
        rowsRequest.onerror = () => fail(rowsRequest.error);
        keysRequest.onsuccess = () => { fileKeys = keysRequest.result || []; maybeReadBlocks(); };
        keysRequest.onerror = () => fail(keysRequest.error);
        snapshotTx.addEventListener('error', () => fail(snapshotTx.error));
        snapshotTx.addEventListener('abort', () => fail(snapshotTx.error));
      });
      await transactionDone;
      return { available: true, sqliteFiles };
    };
    try {
      const result = await Promise.race([read(), timeout]);
      settled = true;
      closeWhenOpened = true;
      closeConnection();
      return result;
    } catch (error) {
      cancelSnapshot();
      throw error;
    } finally {
      clearTimeout(timeoutHandle);
      closeConnection();
    }
  }, { databaseName: CLIENT_DATABASE_NAME, timeoutMs });
}

function inspectSyncCheckpointSqlite(sqliteFiles, snapshotPath, vaultId) {
  const databaseFile = sqliteFiles?.find((file) =>
    file.logicalName === '/database' || file.name === '/database');
  const journalFile = sqliteFiles?.find((file) =>
    file.logicalName === '/database-journal' || file.name === '/database-journal');
  if (!databaseFile || databaseFile.length <= 0 ||
      databaseFile.length % SQLITE_BLOCK_SIZE !== 0 ||
      (journalFile && journalFile.length !== 0)) {
    return {
      available: false,
      journalEmpty: !journalFile || journalFile.length === 0,
      reasonCategory: !databaseFile ? 'sqlite-image-missing'
        : journalFile?.length ? 'sqlite-journal-active' : 'sqlite-image-invalid',
    };
  }
  try {
    const bytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
    fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'w' });
    fs.chmodSync(snapshotPath, 0o600);
    const python = [
      'import base64,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'vault_id=sys.argv[2]',
      "tables={row[0] for row in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
      "result={'available':True,'journalEmpty':True,'integrityCheck':db.execute('PRAGMA integrity_check').fetchone()[0]}",
      "if 'sync_checkpoints' not in tables:",
      "    result.update({'available':False,'reasonCategory':'checkpoint-table-missing','checkpointRowCount':0,'checkpoints':[]})",
      'else:',
      "    rows=db.execute('SELECT cursor,server_generation FROM sync_checkpoints WHERE vault_id=?',(vault_id,)).fetchall()",
      '    checkpoints=[]',
      '    for cursor,generation in rows:',
      '        sequence=None',
      '        if isinstance(cursor,str):',
      '            try:',
      "                raw=base64.urlsafe_b64decode(cursor+'='*((4-len(cursor)%4)%4))",
      '                payload=json.loads(raw[:-32].decode("utf-8")) if len(raw)>32 else {}',
      "                if payload.get('v')==1 and type(payload.get('seq')) is int and payload['seq']>=0:",
      "                    sequence=str(payload['seq'])",
      '            except Exception:',
      '                pass',
      "        checkpoints.append({'cursorPresent':isinstance(cursor,str) and bool(cursor),'cursorSequence':sequence,'serverGenerationPresent':isinstance(generation,str) and bool(generation)})",
      "    result.update({'checkpointRowCount':len(checkpoints),'checkpoints':checkpoints})",
      'print(json.dumps(result,separators=(",",":")))',
      'db.close()',
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshotPath, vaultId], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 10000,
      maxBuffer: 16 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) {
      return { available: false, reasonCategory: 'sqlite-read-only-query-failed' };
    }
    return JSON.parse(result.stdout);
  } catch (error) {
    return {
      available: false,
      journalEmpty: !journalFile || journalFile.length === 0,
      reasonCategory: /sqlite|block|file|metadata/i.test(String(error?.message || ''))
        ? 'sqlite-image-invalid'
        : 'sqlite-snapshot-failed',
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function waitForPersistedSyncCheckpoint({
  page,
  tempRoot,
  vaultId,
  minimumSequence,
  timeoutMs = 15000,
}) {
  const deadline = Date.now() + timeoutMs;
  let lastSnapshot = { available: false, reasonCategory: 'snapshot-not-read' };
  while (Date.now() < deadline) {
    try {
      const image = await readIndexedDbSqliteImage(page, 5000);
      lastSnapshot = image?.available && Array.isArray(image.sqliteFiles)
        ? inspectSyncCheckpointSqlite(
          image.sqliteFiles,
          path.join(tempRoot, 'sync-checkpoint-snapshot.sqlite'),
          vaultId,
        )
        : { available: false, reasonCategory: 'indexeddb-snapshot-unavailable' };
      const checkpoint = lastSnapshot.checkpoints?.[0];
      if (lastSnapshot.available && lastSnapshot.integrityCheck === 'ok' &&
          lastSnapshot.journalEmpty && lastSnapshot.checkpointRowCount === 1 &&
          checkpoint?.cursorPresent && checkpoint.serverGenerationPresent &&
          checkpoint.cursorSequence !== null &&
          BigInt(checkpoint.cursorSequence) >= BigInt(minimumSequence)) {
        return lastSnapshot;
      }
    } catch (error) {
      lastSnapshot = {
        available: false,
        reasonCategory: /timeout/i.test(String(error?.message || ''))
          ? 'indexeddb-read-timeout'
          : 'indexeddb-read-failed',
      };
    }
    await page.waitForTimeout(250);
  }
  return lastSnapshot;
}

function inspectOfflineGroupHostSqlite(
  sqliteFiles,
  snapshotPath,
  vaultId,
  expectedGroupRecordId,
  markers,
) {
  const databaseFile = sqliteFiles?.find((file) =>
    file.logicalName === '/database' || file.name === '/database');
  const journalFile = sqliteFiles?.find((file) =>
    file.logicalName === '/database-journal' || file.name === '/database-journal');
  if (!databaseFile || databaseFile.length <= 0 ||
      databaseFile.length % SQLITE_BLOCK_SIZE !== 0 ||
      (journalFile && journalFile.length !== 0)) {
    return {
      available: false,
      journalEmpty: !journalFile || journalFile.length === 0,
      reasonCategory: !databaseFile ? 'sqlite-image-missing'
        : journalFile?.length ? 'sqlite-journal-active' : 'sqlite-image-invalid',
    };
  }
  try {
    const bytes = reconstructSqliteFile({
      fileId: databaseFile.fileId,
      name: databaseFile.name,
      length: databaseFile.length,
      blocks: databaseFile.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
    const sqlitePlaintextMarkersAbsent = markers.every((marker) =>
      typeof marker === 'string' && marker.length > 0 &&
      !bytes.includes(Buffer.from(marker)));
    fs.writeFileSync(snapshotPath, bytes, { mode: 0o600, flag: 'w' });
    fs.chmodSync(snapshotPath, 0o600);
    const python = [
      'import hashlib,json,sqlite3,sys,re',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.execute("PRAGMA query_only=ON")',
      'vault_id,group_id=sys.argv[2:4]',
      'markers=json.loads(sys.stdin.read())',
      "tables={row[0] for row in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}",
      "result={'available':True,'journalEmpty':True,'integrityCheck':db.execute('PRAGMA integrity_check').fetchone()[0]}",
      "if not {'encrypted_records','pending_operations'}.issubset(tables):",
      "    result.update({'available':False,'reasonCategory':'client-tables-missing','activePendingCount':None,'operations':[]})",
      'else:',
      "    rows=db.execute(\"SELECT op_id,record_id,base_revision_id,envelope_json,status FROM pending_operations WHERE vault_id=? AND status!='superseded' ORDER BY created_at,op_id\",(vault_id,)).fetchall()",
      "    result['activePendingCount']=len(rows)",
      "    allowed={'wire_version','server_space_id','vault_id','record_id','revision_id','base_revision_id','op_id','device_id','device_seq','key_epoch','membership_version','record_schema','operation','crypto_suite','kdf_salt','object_refs'}",
      '    operations=[]',
      '    for row in rows:',
      '        op_id,record_id,base_revision_id,envelope_text,status=row',
      '        try: envelope=json.loads(envelope_text)',
      '        except Exception: envelope={}',
      "        header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
      "        valid_shape=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict)",
      "        metadata_only=valid_shape and set(header).issubset(allowed)",
      "        encoded=valid_shape and all(isinstance(envelope.get(key),str) and re.fullmatch(r'[A-Za-z0-9_-]+',envelope[key]) for key in ('nonce','ciphertext','signature'))",
      "        marker_absent=all(isinstance(marker,str) and marker and marker not in envelope_text for marker in markers)",
      "        header_group_ref=any(key in header for key in ('group_id','groupId','host_group_id','parent_group_id')) or group_id in json.dumps(header,sort_keys=True,separators=(',',':'))",
      "        header_identity=valid_shape and header.get('vault_id')==vault_id and header.get('record_id')==record_id and header.get('op_id')==op_id and header.get('operation')=='create' and header.get('base_revision_id') is None and base_revision_id is None",
      "        records=db.execute('SELECT revision_id,envelope_json,is_deleted,commit_seq FROM encrypted_records WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchall()",
      "        record_pending_count=db.execute('SELECT count(*) FROM pending_operations WHERE vault_id=? AND record_id=?',(vault_id,record_id)).fetchone()[0]",
      "        record_match=False",
      '        if len(records)==1 and valid_shape:',
      '            try: record_match=json.loads(records[0][1])==envelope',
      '            except Exception: record_match=False',
      "        revision=header.get('revision_id') if isinstance(header,dict) else None",
      "        canonical=json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False) if valid_shape else ''",
      "        envelope_hash=hashlib.sha256(canonical.encode('utf-8')).hexdigest() if valid_shape else None",
      "        operations.append({'opId':op_id,'recordId':record_id,'revisionId':revision,'baseRevisionId':base_revision_id,'headerBaseRevisionId':header.get('base_revision_id') if isinstance(header,dict) else None,'operation':header.get('operation') if isinstance(header,dict) else None,'recordSchema':header.get('record_schema') if isinstance(header,dict) else None,'status':status,'envelopeSha256':envelope_hash,'envelopeShapeValid':bool(valid_shape),'headerIdentityMatches':bool(header_identity),'metadataOnlyHeader':bool(metadata_only),'encodedCiphertextFields':bool(encoded),'plaintextMarkersAbsent':bool(marker_absent),'groupReferenceAbsentFromHeader':not header_group_ref,'matchingEncryptedRecordCount':len(records),'encryptedRecordMatchesEnvelope':bool(record_match),'encryptedRecordRevisionMatches':len(records)==1 and records[0][0]==revision,'encryptedRecordActive':len(records)==1 and not bool(records[0][2]),'encryptedRecordCommitSequenceNull':len(records)==1 and records[0][3] is None,'recordPendingOperationCount':record_pending_count})",
      "    result['operations']=operations",
      "print(json.dumps(result,separators=(',',':')))",
      'db.close()',
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshotPath,
      vaultId, expectedGroupRecordId], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 10000,
      maxBuffer: 16 * 1024,
      stdio: ['pipe', 'pipe', 'ignore'],
      input: JSON.stringify(markers),
    });
    if (result.error || result.status !== 0) {
      return { available: false, reasonCategory: 'sqlite-read-only-query-failed' };
    }
    return {
      ...JSON.parse(result.stdout),
      sqlitePlaintextMarkersAbsent,
    };
  } catch (error) {
    return {
      available: false,
      journalEmpty: !journalFile || journalFile.length === 0,
      reasonCategory: /sqlite|block|file|metadata/i.test(String(error?.message || ''))
        ? 'sqlite-image-invalid'
        : 'sqlite-snapshot-failed',
    };
  } finally {
    fs.rmSync(snapshotPath, { force: true });
  }
}

async function readOfflineGroupHostSnapshot(
  page,
  tempRoot,
  vaultId,
  expectedGroupRecordId,
  markers,
) {
  const image = await readIndexedDbSqliteImage(page, 5000);
  if (!image?.available || !Array.isArray(image.sqliteFiles)) {
    return { available: false, reasonCategory: 'indexeddb-snapshot-unavailable' };
  }
  return inspectOfflineGroupHostSqlite(
    image.sqliteFiles,
    path.join(tempRoot, 'offline-group-host-snapshot.sqlite'),
    vaultId,
    expectedGroupRecordId,
    markers,
  );
}

function offlineGroupHostCreateReady(snapshot) {
  const operation = snapshot?.operations?.[0];
  return Boolean(snapshot?.available && snapshot.integrityCheck === 'ok' &&
    snapshot.journalEmpty && snapshot.sqlitePlaintextMarkersAbsent &&
    snapshot.activePendingCount === 1 &&
    snapshot.operations?.length === 1 && operation &&
    typeof operation.recordId === 'string' && operation.recordId.length > 0 &&
    operation.operation === 'create' && operation.baseRevisionId == null &&
    operation.headerBaseRevisionId == null && operation.status === 'queued' &&
    [1, 2].includes(operation.recordSchema) &&
    typeof operation.envelopeSha256 === 'string' &&
    /^[0-9a-f]{64}$/.test(operation.envelopeSha256) &&
    operation.envelopeShapeValid && operation.headerIdentityMatches &&
    operation.metadataOnlyHeader &&
    operation.encodedCiphertextFields && operation.plaintextMarkersAbsent &&
    operation.groupReferenceAbsentFromHeader &&
    operation.matchingEncryptedRecordCount === 1 &&
    operation.recordPendingOperationCount === 1 &&
    operation.encryptedRecordMatchesEnvelope &&
    operation.encryptedRecordRevisionMatches &&
    operation.encryptedRecordActive &&
    operation.encryptedRecordCommitSequenceNull);
}

async function waitForOfflineGroupHostCreate(
  page,
  tempRoot,
  vaultId,
  expectedGroupRecordId,
  markers,
  timeoutMs = 15000,
) {
  const deadline = Date.now() + timeoutMs;
  let lastSnapshot = { available: false, reasonCategory: 'snapshot-not-read' };
  let snapshotReadCount = 0;
  let lastReadFailureCategory = null;
  while (Date.now() < deadline) {
    try {
      lastSnapshot = await readOfflineGroupHostSnapshot(
        page, tempRoot, vaultId, expectedGroupRecordId, markers);
      snapshotReadCount++;
      if (offlineGroupHostCreateReady(lastSnapshot)) {
        return { ...lastSnapshot, ready: true, snapshotReadCount };
      }
    } catch (error) {
      lastReadFailureCategory = /timeout/i.test(String(error?.message || ''))
        ? 'indexeddb-read-timeout'
        : /blocked/i.test(String(error?.message || ''))
          ? 'indexeddb-read-blocked'
          : 'indexeddb-read-failed';
    }
    await page.waitForTimeout(350);
  }
  return {
    ...lastSnapshot,
    ready: false,
    snapshotReadCount,
    lastReadFailureCategory,
  };
}

async function editHostFailureDiagnostic({
  page,
  oldName,
  newName,
  apiDiagnostics = [],
  apiStartIndex = apiDiagnostics.length,
  step,
  error,
  errorTextClass = null,
}) {
  const [oldHostCard, newHostCard, syncStatusLabels, pendingBadgeCount,
    visibleErrorCategory] = await Promise.all([
    hostCardEvidence(page, oldName),
    hostCardEvidence(page, newName),
    visibleSyncStatusLabels(page),
    pendingCardCount(page),
    page.evaluate(() => {
      const text = (document.body.innerText || '').toLowerCase();
      if (/sync failed|同步失败/.test(text)) return 'sync-failure-visible';
      if (/decryption failed|解密失败/.test(text)) return 'decryption-failure-visible';
      if (/required|invalid|must be/.test(text)) return 'field-validation-visible';
      if (/error|failed|失败/.test(text)) return 'generic-error-visible';
      return 'none';
    }).catch(() => 'unavailable'),
  ]);
  const apiSinceEdit = safeApiSummary(apiDiagnostics.slice(apiStartIndex), 16)
    .map(({ method, path: apiPath, status }) => ({ method, path: apiPath, status }));
  const savedHostsCount = newHostCard.savedHostsCount ?? oldHostCard.savedHostsCount;
  console.log('edit-host failure diagnostic', JSON.stringify({
    step,
    errorClass: safeErrorClass(error),
    errorTextClass: errorTextClass || safeErrorTextClass(error),
    visibleErrorCategory,
    oldHostCard: {
      visible: oldHostCard.nameVisible,
      matchingCardCount: oldHostCard.matchingHostCardCount,
      hostCardGroupCount: oldHostCard.hostCardGroupCount,
    },
    newHostCard: {
      visible: newHostCard.nameVisible,
      matchingCardCount: newHostCard.matchingHostCardCount,
      hostCardGroupCount: newHostCard.hostCardGroupCount,
    },
    savedHostsCount,
    syncStatusLabels,
    pendingBadgeCount,
    apiSinceEdit,
  }));
}

async function editHostName(page, oldName, newName, diagnosticContext = {}) {
  const stagePrefix = activeStage;
  const { apiDiagnostics = [], apiStartIndex = apiDiagnostics.length } = diagnosticContext;
  const diagnostic = (step, error) => editHostFailureDiagnostic({
    page,
    oldName,
    newName,
    apiDiagnostics,
    apiStartIndex,
    step,
    error,
  });
  activeStage = `${stagePrefix}: locate current Host row`;
  const card = hostCardGroup(page, oldName);
  try {
    await card.waitFor({ state: 'visible', timeout: 15000 });
  } catch (error) {
    await diagnostic('locate-current-row', error);
    throw error;
  }
  activeStage = `${stagePrefix}: open Host editor`;
  try {
    await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  } catch (error) {
    await diagnostic('open-editor', error);
    throw error;
  }
  activeStage = `${stagePrefix}: wait for Host editor`;
  try {
    await waitForText(page, 'Edit host');
  } catch (error) {
    await diagnostic('wait-for-editor', error);
    throw error;
  }
  activeStage = `${stagePrefix}: enter updated display name`;
  try {
    await fill(page, 'Display name', newName);
  } catch (error) {
    await diagnostic('fill-display-name', error);
    throw error;
  }
  activeStage = `${stagePrefix}: save updated Host`;
  try {
    await click(page, 'Save encrypted host');
  } catch (error) {
    await diagnostic('save-host', error);
    throw error;
  }
  activeStage = `${stagePrefix}: verify updated Host row`;
  try {
    await waitForHostRecord(page, newName, true);
  } catch (error) {
    await diagnostic('wait-for-updated-row', error);
    throw error;
  }
}

async function editHostConnection(page, name, changes, expectedEndpoint) {
  const card = hostCardGroup(page, name);
  await card.waitFor({ state: 'visible', timeout: 15000 });
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitForText(page, 'Edit host');
  if (changes.address !== undefined) {
    await fill(page, 'Hostname or IP', changes.address);
  }
  if (changes.port !== undefined) {
    await fill(page, 'Port', String(changes.port));
  }
  await click(page, 'Save encrypted host');
  await waitForHostRecord(page, name, true, expectedEndpoint);
}

async function assertVisible(page, text, expected, expectedEndpoint = null) {
  await waitForHostRecord(page, text, expected, expectedEndpoint);
}

async function waitForArchiveConfirmation(
  page,
  timeoutMs = 120000,
  baselineErrorLines = [],
) {
  const deadline = Date.now() + timeoutMs;
  const idleLimitMs = 20000;
  let lastProgress = '';
  let lastProgressAt = Date.now();
  let lastState = null;
  const progressCategoryCounts = { preparing: 0, verifying: 0, importing: 0, restoring: 0, other: 0 };
  const fail = (failureClass, uiErrorRegexFamily = null,
    safeErrorCategory = null, archiveFailurePhase = null) => {
    const error = new Error('archive verification failed');
    error.archiveFailureClass = failureClass;
    error.uiErrorRegexFamily = uiErrorRegexFamily;
    error.safeErrorCategory = safeErrorCategory;
    error.archiveFailurePhase = archiveFailurePhase;
    error.progressCategoryCounts = { ...progressCategoryCounts };
    return error;
  };
  while (Date.now() < deadline) {
    lastState = await page.evaluate(() => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((element) => ({
          role: element.getAttribute('role'),
          text: element.innerText || '',
          label: element.getAttribute('aria-label') || '',
        }))
        .filter((item) => item.role || item.text || item.label);
      const labels = semantics.flatMap((item) => [item.text, item.label]);
      const buttons = semantics
        .filter((item) => item.role === 'button')
        .map((item) => `${item.text}\n${item.label}`);
      const lines = [...new Set([
        ...document.body.innerText.split('\n').map((line) => line.trim()),
        ...labels.flatMap((value) => value.split('\n').map((line) => line.trim())),
      ].filter(Boolean))];
      return {
        lines,
        buttons,
        hasConfirmation: lines.some((line) => line.includes('Import verified Vault archive?')),
        hasImportButton: buttons.some((label) => label.includes('Import to this Vault')),
      };
    }).catch(() => ({ lines: [], buttons: [], hasConfirmation: false, hasImportButton: false, evaluationError: true }));
    if (lastState.hasConfirmation || lastState.hasImportButton) return lastState;

    const progress = lastState.lines
      .filter((line) => /^(Preparing|Verifying|Importing|正在|准备|验证|读取|校验|解析|处理|上传)/i.test(line))
      .slice(-10);
    for (const line of progress) {
      if (/^(Preparing|准备)/i.test(line)) progressCategoryCounts.preparing += 1;
      else if (/^(Verifying|验证|校验|解析)/i.test(line)) progressCategoryCounts.verifying += 1;
      else if (/^(Importing|正在导入)/i.test(line)) progressCategoryCounts.importing += 1;
      else if (/^(Restoring|正在恢复|正在处理)/i.test(line)) progressCategoryCounts.restoring += 1;
      else progressCategoryCounts.other += 1;
    }
    const progressKey = progress.join('\n');
    if (progressKey && progressKey !== lastProgress) {
      console.log('archive progress update', JSON.stringify({ indicatorCount: progress.length }));
      lastProgress = progressKey;
      lastProgressAt = Date.now();
    }
    const uiErrorFamilies = [
      ['format-exception', /FormatException/i],
      ['exception', /Exception:/i],
      ['error', /Error:/i],
      ['failure', /failed|失败/i],
      ['invalid', /无效/i],
      ['unavailable', /无法/i],
      ['denied', /拒绝/i],
    ];
    const currentErrorLines = lastState.lines.filter((line) =>
      uiErrorFamilies.some(([, pattern]) => pattern.test(line)) &&
      !baselineErrorLines.includes(line));
    const uiErrorFamily = uiErrorFamilies.find(([, pattern]) =>
      currentErrorLines.some((line) => pattern.test(line)))?.[0];
    const archiveFailurePhase = safeArchiveFailurePhase(lastState.lines);
    if (uiErrorFamily) {
      throw fail(
        'ui-error',
        uiErrorFamily,
        safeArchiveErrorCategory(currentErrorLines, archiveFailurePhase),
        archiveFailurePhase,
      );
    }
    if (!progressKey && Date.now() - lastProgressAt >= idleLimitMs) {
      throw fail('no-progress');
    }
    await page.waitForTimeout(250);
  }
  throw fail('deadline');
}

async function sampleArchiveApply(page) {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .map((element) => ({
        role: element.getAttribute('role') || '',
        text: element.innerText || '',
        label: element.getAttribute('aria-label') || '',
      }))
      .filter((item) => item.role || item.text || item.label);
    const values = [document.body.innerText, ...semantics.flatMap((item) => [item.text, item.label])];
    const lines = [...new Set(values.flatMap((value) => value.split('\n')
      .map((line) => line.trim()).filter(Boolean)))];
    const buttons = semantics.filter((item) => item.role === 'button')
      .map((item) => `${item.text}\n${item.label}`.trim());
    const relevant = lines.filter((line) =>
      /archive|import|restore|host|pending|saving|saved|error|exception|fail|failed|success|验证|导入|恢复|保存|失败|错误/i.test(line));
    const progress = lines.filter((line) =>
      /上传缺失加密对象|原子恢复|importing|restoring|正在导入|正在恢复/i.test(line));
    const success = relevant.some((line) =>
      /Vault archive imported and local state restored|归档已验证并恢复/i.test(line));
    const applyErrorCategory = relevant.some((line) =>
      /请等待当前同步或归档操作完成|wait for the current sync/i.test(line))
      ? 'sync-busy'
      : relevant.some((line) =>
        /FormatException/i.test(line))
      ? 'format-exception'
      : relevant.some((line) =>
        /Exception:|Error:|failed|失败|无效|无法|拒绝/i.test(line))
      ? 'apply-error'
      : null;
    return {
      relevantCount: relevant.length,
      buttonCount: buttons.length,
      progressCount: progress.length,
      confirmationVisible: lines.some((line) => line.includes('Import verified Vault archive?')),
      importButtonVisible: buttons.some((label) => label.includes('Import to this Vault')),
      success,
      error: applyErrorCategory !== null,
      applyErrorCategory,
      path: location.pathname,
    };
  });
}

function redactDiagnosticText(value) {
  void value;
  return '[UI text omitted]';
}

async function waitForArchiveApply(page, apiDiagnostics, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  let previousKey = '';
  let lastLoggedAt = 0;
  let lastSample = null;
  let successSeen = false;
  let idleSince = null;
  while (Date.now() < deadline) {
    lastSample = await sampleArchiveApply(page).catch((error) => ({
      relevantCount: 0, buttonCount: 0, progressCount: 0, confirmationVisible: false,
      importButtonVisible: false, success: false, error: false, evaluationError: true,
    }));
    const safeSample = { ...lastSample };
    const key = JSON.stringify({
      relevantCount: safeSample.relevantCount,
      buttonCount: safeSample.buttonCount,
      path: safeSample.path,
    });
    const now = Date.now();
    if (key !== previousKey || now - lastLoggedAt >= 5000) {
      console.log('archive apply sample', JSON.stringify({
        elapsedMs: 120000 - Math.max(0, deadline - now),
        ...safeSample,
        recentApi: safeApiSummary(apiDiagnostics, 12),
      }));
      previousKey = key;
      lastLoggedAt = now;
    }
    if (lastSample.error) {
      const error = new Error('archive apply surfaced a UI error');
      error.archiveApplyErrorCategory = lastSample.applyErrorCategory;
      throw error;
    }
    if (lastSample.success) {
      successSeen = true;
      break;
    }
    const dialogStillOpen = lastSample.confirmationVisible || lastSample.importButtonVisible;
    if (!dialogStillOpen && (lastSample.progressCount || 0) === 0) {
      if (idleSince === null) idleSince = now;
      // The dialog closes before async apply starts. If no apply progress or
      // dialog is visible for a stable interval, final data assertions decide
      // whether the import committed, even if its snackbar was too transient.
      if (now - idleSince >= 2000) break;
    } else {
      idleSince = null;
    }
    await page.waitForTimeout(200);
  }
  if (!successSeen && Date.now() >= deadline) {
    console.log('archive apply timed out', JSON.stringify({
      lastSample,
      recentApi: safeApiSummary(apiDiagnostics, 35),
    }, null, 2));
    throw new Error('archive import did not settle before its deadline');
  }
  return { successSeen, lastSample };
}

async function pendingCount(locator) {
  const [label, text] = await Promise.all([
    locator.getAttribute('aria-label').catch(() => ''),
    locator.innerText().catch(() => ''),
  ]);
  const match = `${label || ''}\n${text || ''}`.match(/(\d+)\s*pending/i);
  return match ? Number(match[1]) : null;
}

async function pendingCardCount(page) {
  return visiblePendingSyncValue(page);
}

async function waitForPendingCardCount(page, minimum) {
  const deadline = Date.now() + 10000;
  let lastCount = null;
  while (Date.now() < deadline) {
    lastCount = await pendingCardCount(page);
    if (lastCount !== null && lastCount >= minimum) return lastCount;
    await page.waitForTimeout(100);
  }
  throw new Error(`pending sync card count did not reach ${minimum}; observed=${lastCount}`);
}

function safeNotificationFrame(payload, profile, direction) {
  let decoded;
  try {
    decoded = JSON.parse(Buffer.isBuffer(payload) ? payload.toString('utf8') : payload);
  } catch (_) {
    return { profile, direction, type: 'invalid_json' };
  }
  const type = typeof decoded?.type === 'string' ? decoded.type : 'unknown';
  if (direction === 'sent') return { profile, direction, type };
  if (type === 'ready') {
    return {
      profile,
      direction,
      type,
      keys: Object.keys(decoded).sort(),
      serverGenerationIsUuid: typeof decoded.server_generation === 'string' &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(decoded.server_generation),
      syncRequired: decoded.sync_required === true,
      heartbeatSeconds: decoded.heartbeat_seconds,
      pollIntervalSeconds: decoded.poll_interval_seconds,
    };
  }
  if (type === 'sync_required') {
    return {
      profile,
      direction,
      type,
      keys: Object.keys(decoded).sort(),
      hasVaultId: typeof decoded.vault_id === 'string',
      vaultIdIsUuid: decoded.vault_id === null ||
        (typeof decoded.vault_id === 'string' &&
          /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(decoded.vault_id)),
      commitSeqPresent: Object.hasOwn(decoded, 'commit_seq'),
      commitSeqIsDecimal: typeof decoded.commit_seq === 'string' && /^(0|[1-9][0-9]*)$/.test(decoded.commit_seq),
      conflictSeq: typeof decoded.conflict_seq === 'string' ? decoded.conflict_seq : null,
      conflictSeqPresent: Object.hasOwn(decoded, 'conflict_seq'),
      conflictSeqIsDecimal: typeof decoded.conflict_seq === 'string' && /^(0|[1-9][0-9]*)$/.test(decoded.conflict_seq),
    };
  }
  return { profile, direction, type };
}

function parseNotificationFrame(payload) {
  try {
    return JSON.parse(Buffer.isBuffer(payload) ? payload.toString('utf8') : payload);
  } catch (_) {
    return null;
  }
}

function isExactMembershipSetHint(frame) {
  return frame !== null && typeof frame === 'object' && !Array.isArray(frame) &&
    JSON.stringify(Object.keys(frame).sort()) ===
      JSON.stringify(['commit_seq', 'type', 'vault_id']) &&
    frame.type === 'sync_required' && frame.vault_id === null &&
    frame.commit_seq === null;
}

function recoveryApiPathTag(pathname) {
  if (pathname === '/api/v1/devices') return 'account-devices';
  if (pathname === '/api/v1/vaults') return 'vault-list';
  if (/^\/api\/v1\/vaults\/[^/]+\/devices$/.test(pathname)) {
    return 'vault-devices';
  }
  if (/^\/api\/v1\/vaults\/[^/]+\/membership$/.test(pathname)) {
    return 'vault-membership';
  }
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) {
    return 'changes';
  }
  return null;
}

function issueInstanceAccountInvite(username, serverEnv) {
  const result = spawnSync(SERVER_BINARY, [
    'create-account-invite', '--username', username,
  ], {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'temporary read-only account invitation issuance failed');
  const token = (result.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/)?.[1];
  result.stdout = '';
  assertThat(typeof token === 'string',
    'temporary read-only account invitation was not returned');
  return token;
}

async function waitUntil(predicate, timeoutMs = 20000, label = 'browser state') {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} did not become ready`);
}

async function visiblePendingSyncValue(page) {
  return page.evaluate(() => {
    const candidates = [...document.querySelectorAll('flt-semantics')]
      .map((node) => [
        node.getAttribute('aria-label') || '',
        node.innerText || '',
        node.parentElement?.innerText || '',
      ].join('\n'));
    for (const text of candidates) {
      if (!/Pending sync/i.test(text)) continue;
      const match = text.match(/Pending sync\D{0,40}(\d+)/i);
      if (match) return Number(match[1]);
    }
    return null;
  }).catch(() => null);
}

async function runMissedMembershipHintAcceptance({
  browser,
  baseUrl,
  serverEnv,
  ownerPage,
  siblingPage,
  wireCapture,
  ownerUsername,
  databasePath,
  startupEvidence,
}) {
  activeStage = 'missed membership hint: prepare Owner and approved sibling';
  const suffix = crypto.randomUUID().slice(0, 8);
  const memberUsername = `web-hint-viewer-${suffix}@example.test`;
  const memberPassword = `Viewer-${crypto.randomBytes(28).toString('base64url')}`;
  const markerAfterRotation = `missed-hint-new-epoch-${suffix}`;
  const markerUsername = `missed-hint-user-${suffix}`;
  const endpoint = `missed-hint-target-${suffix}.example.test`;
  const capture = Object.assign(wireCapture, {
    targetRecordId: null,
    viewerVaultAcceptanceStatuses: [],
    targetEventResponseGateArmedCount: 0,
    dropMembershipSetHint: false,
    droppedMembershipSetHintCount: 0,
    droppedMembershipSetHintTimes: [],
    forwardedMembershipSetHintCount: 0,
    ownerRoleRotationRequests: [],
    ownerRoleRotationResponses: [],
    expectedEpoch: null,
    expectedMembershipVersion: null,
    ownerPushes: [],
    targetChangesResponses: [],
    recoveryRequests: [],
    controlPlaneResponses: [],
    siblingSyncRequests: [],
    vaultListResponses: [],
    membershipResponses: [],
    viewerDeviceId: null,
    targetVaultSignerDeviceIds: [],
    targetVaultKeyEnvelopeSummaries: [],
    targetEventSignerDeviceId: null,
    deliveredCommitHints: [],
    syncPushRequests: 0,
    changesRequests: [],
    pageErrors: 0,
    pageErrorKinds: [],
    pageErrorsAtActivation: null,
    targetSelectedAtActivation: null,
    activationSyncStatusLabels: [],
    ownerRoleRotationResponseObserved: false,
    expectedTargetCommitSeq: null,
    exactTargetCommitHintObserved: false,
    siblingPageErrors: 0,
    apiOrder: 0,
    holdNextVaultList: false,
    vaultListHeld: false,
    releaseVaultList: null,
  });
  const requestCursor = new WeakMap();
  const requestOrder = new WeakMap();
  const recoveryRequestByRequest = new WeakMap();
  const markers = [markerAfterRotation, endpoint, markerUsername];
  let viewerContext;
  let viewerPage;
  let accountInvitationToken;
  let vaultInvitationToken;
  let shareRequest;
  let ownerRoleRotationRequestListener;
  let ownerRoleRotationResponseListener;
  const siblingPageErrorListener = () => { capture.siblingPageErrors++; };
  siblingPage.on('pageerror', siblingPageErrorListener);
  const siblingSyncRequestByRequest = new WeakMap();
  let siblingSyncRequestListener;
  let siblingSyncResponseListener;

  try {
    activeStage = 'missed membership hint: inspect Owner Vault baseline';
    const initialVaults = serverVaultSnapshot(databasePath, ownerUsername).vaults;
    assertThat(initialVaults.length === 1,
      'missed-hint acceptance did not find exactly one Owner Vault');
    capture.targetVaultId = initialVaults[0].vaultId;
    assertThat(initialVaults[0].commitSeq === '0',
      'missed-hint acceptance requires an empty Vault changes feed before enrollment');

    activeStage = 'missed membership hint: verify approved B has no pending writes';
    await syncNow(siblingPage);

    activeStage = 'missed membership hint: prepare temporary Viewer context';
    viewerContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    });
    await viewerContext.grantPermissions(
      ['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    await installFlutterLoaderProbe(viewerContext);
    activeStage = 'missed membership hint: register and invite Viewer catalyst';

    await viewerContext.route('**/api/v1/**/changes**', async (route) => {
      const request = route.request();
      if (!capture.active || request.method() !== 'GET') {
        await route.continue();
        return;
      }
      const upstream = await route.fetch();
      if (upstream.status() === 200 && capture.targetRecordId !== null) {
        try {
          const body = await upstream.json();
          const events = Array.isArray(body?.events) ? body.events : [];
          const target = events.find((event) =>
            event?.envelope?.header?.record_id === capture.targetRecordId &&
            String(event?.envelope?.header?.key_epoch) === capture.expectedEpoch &&
            String(event?.envelope?.header?.membership_version) ===
              capture.expectedMembershipVersion);
          if (target) {
            // Arm the next Vault-list gate before the controller can observe
            // the unknown-key page and start its signed control-plane reload.
            capture.targetEventResponseGateArmedCount++;
            capture.holdNextVaultList = true;
          }
        } catch (_) {}
      }
      await route.fulfill({ response: upstream });
    });
    await viewerContext.route('**/api/v1/vaults**', async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      if (capture.holdNextVaultList && request.method() === 'GET' &&
          url.pathname === '/api/v1/vaults') {
        capture.holdNextVaultList = false;
        capture.vaultListHeld = true;
        capture.releaseVaultList = () => route.continue();
        return;
      }
      await route.fallback();
    });

    await viewerContext.routeWebSocket('**/api/v1/notifications', (webSocket) => {
      const serverSocket = webSocket.connectToServer();
      webSocket.onMessage((message) => serverSocket.send(message));
      serverSocket.onMessage((message) => {
        const frame = parseNotificationFrame(message);
        if (frame?.type === 'ready') capture.recoveryReadyFrames++;
        if (capture.dropMembershipSetHint && isExactMembershipSetHint(frame)) {
          capture.droppedMembershipSetHintCount++;
          capture.droppedMembershipSetHintTimes.push(Date.now());
          return;
        }
        if (isExactMembershipSetHint(frame)) {
          capture.forwardedMembershipSetHintCount++;
        }
        if (capture.active && frame?.type === 'sync_required' &&
            frame.vault_id === capture.targetVaultId &&
            typeof frame.commit_seq === 'string' &&
            /^(0|[1-9][0-9]*)$/.test(frame.commit_seq)) {
          if (frame.commit_seq === capture.expectedTargetCommitSeq) {
            capture.exactTargetCommitHintObserved = true;
          }
          capture.deliveredCommitHints.push({
            source: 'viewer-recovery',
            vaultId: frame.vault_id,
            commitSeq: frame.commit_seq,
          });
        }
        webSocket.send(message);
      });
    });
    viewerPage = await viewerContext.newPage();
    viewerPage.on('pageerror', (error) => {
      capture.pageErrors++;
      capture.pageErrorKinds.push(safePageErrorKind(error));
    });
    viewerPage.on('response', (response) => {
      try {
        const url = new URL(response.url());
        if (response.request().method() === 'POST' &&
            url.pathname === '/api/v1/invitations/accept') {
          capture.viewerVaultAcceptanceStatuses.push(response.status());
        }
      } catch (_) {}
    });
    activeStage = 'missed membership hint: load temporary Viewer Web app';
    await viewerPage.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    activeStage = 'missed membership hint: enable temporary Viewer Flutter semantics';
    await enableFlutterSemantics(viewerPage, 'C', startupEvidence);
    activeStage = 'missed membership hint: wait for temporary Viewer connection control';
    await button(viewerPage, 'Connect securely');
    viewerPage.on('request', (request) => {
      const url = new URL(request.url());
      if (!capture.active || !url.pathname.startsWith('/api/')) return;
      const order = ++capture.apiOrder;
      requestOrder.set(request, order);
      if (request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
        capture.syncPushRequests++;
      }
      if (request.method() !== 'GET') return;
      const path = recoveryApiPathTag(url.pathname);
      if (!path) return;
      if (path === 'vault-devices' &&
          url.pathname !== `/api/v1/vaults/${capture.targetVaultId}/devices`) return;
      if (path === 'vault-membership' &&
          url.pathname !== `/api/v1/vaults/${capture.targetVaultId}/membership`) return;
      const diagnostic = {
        path,
        targetVaultRequest: path === 'changes' &&
          url.pathname === `/api/v1/vaults/${capture.targetVaultId}/changes`,
        order,
        responseReceived: false,
        status: null,
        cursor: null,
        rowCount: null,
        targetVaultPresent: null,
        membershipVersion: null,
        keyEpoch: null,
        matchingCurrentKeyEnvelopeCount: null,
        manifestCount: null,
        targetRecordPresent: null,
        commitSeq: null,
      };
      if (path === 'changes') {
        const cursor = url.searchParams.get('cursor') ?? '<first-page>';
        requestCursor.set(request, cursor);
        diagnostic.cursor = cursor;
        capture.changesRequests.push({ order, cursor, status: null,
          responseReceived: false,
          targetVaultRequest: diagnostic.targetVaultRequest,
          afterOwnerRoleRotationResponse:
            capture.ownerRoleRotationResponseObserved,
          afterTargetCommitHint: capture.exactTargetCommitHintObserved });
      }
      capture.recoveryRequests.push(diagnostic);
      recoveryRequestByRequest.set(request, diagnostic);
    });
    viewerPage.on('response', async (response) => {
      if (!capture.active) return;
      const request = response.request();
      const url = new URL(response.url());
      const order = requestOrder.get(request) ?? ++capture.apiOrder;
      const diagnostic = recoveryRequestByRequest.get(request) ?? null;
      if (diagnostic) {
        diagnostic.responseReceived = true;
        diagnostic.status = response.status();
        if (diagnostic.path === 'changes') {
          const changesRequest = capture.changesRequests.find((entry) =>
            entry.order === diagnostic.order);
          if (changesRequest) {
            changesRequest.responseReceived = true;
            changesRequest.status = response.status();
          }
        }
      }
      if (request.method() === 'GET' && url.pathname.endsWith('/changes') &&
          response.status() === 200) {
        try {
          const body = await response.json();
          const events = Array.isArray(body?.events) ? body.events : [];
          const match = events.find((event) =>
            event?.envelope?.header?.record_id === capture.targetRecordId);
          if (diagnostic) {
            diagnostic.targetRecordPresent = match !== undefined;
            diagnostic.changeEventCount = events.length;
            diagnostic.changeEvents = events.map((event) => {
              const header = event?.envelope?.header;
              return {
                commitSeq: typeof event?.commit_seq === 'string' &&
                  /^(0|[1-9][0-9]*)$/.test(event.commit_seq)
                  ? event.commit_seq : null,
                keyEpoch: header?.key_epoch == null
                  ? null : String(header.key_epoch),
                membershipVersion: header?.membership_version == null
                  ? null : String(header.membership_version),
                signerDeviceId: typeof header?.device_id === 'string'
                  ? header.device_id : null,
              };
            });
          }
          if (match) {
            const summary = safeCredentialEnvelopeSummary(
              match.envelope, markers);
            if (diagnostic) {
              diagnostic.commitSeq = String(match.commit_seq);
              diagnostic.keyEpoch = String(match.envelope.header.key_epoch);
              diagnostic.membershipVersion = String(
                match.envelope.header.membership_version);
            }
            capture.targetEventSignerDeviceId =
              typeof match.envelope.header.device_id === 'string'
                ? match.envelope.header.device_id : null;
            capture.targetChangesResponses.push({
              order,
              targetVaultRequest: diagnostic?.targetVaultRequest === true,
              status: response.status(),
              requestCursor: requestCursor.get(request),
              eventCount: events.length,
              commitSeq: String(match.commit_seq),
              keyEpoch: String(match.envelope.header.key_epoch),
              membershipVersion: String(match.envelope.header.membership_version),
              envelopeShapeValid: summary.exactEnvelopeShape &&
                summary.metadataOnlyHeader && summary.encodedCiphertextFields,
              plaintextMarkersAbsent: summary.plaintextMarkersAbsent,
            });
          }
        } catch (_) {}
      } else if (request.method() === 'GET' &&
          (url.pathname === '/api/v1/devices' ||
            url.pathname === `/api/v1/vaults/${capture.targetVaultId}/devices`)) {
        const summary = {
          path: recoveryApiPathTag(url.pathname),
          order,
          status: response.status(),
          rowCount: null,
        };
        try {
          if (response.status() === 200) {
            const body = await response.json();
            const rows = Array.isArray(body?.devices) ? body.devices : [];
            summary.rowCount = rows.length;
            if (diagnostic) diagnostic.rowCount = summary.rowCount;
            if (summary.path === 'account-devices') {
              capture.viewerDeviceId = rows.length === 1 &&
                typeof rows[0]?.device_id === 'string'
                ? rows[0].device_id : null;
            } else {
              capture.targetVaultSignerDeviceIds = rows.map((device) =>
                device?.device_id).filter((id) => typeof id === 'string');
            }
          }
        } catch (_) {}
        capture.controlPlaneResponses.push(summary);
      } else if (request.method() === 'GET' &&
          url.pathname === '/api/v1/vaults') {
        const summary = {
          order,
          status: response.status(),
          targetVaultPresent: false,
          activeKeyEpoch: null,
          membershipVersion: null,
          matchingCurrentKeyEnvelopeCount: 0,
        };
        try {
          if (response.status() === 200) {
            const body = await response.json();
            const vault = (Array.isArray(body?.vaults) ? body.vaults : [])
              .find((item) => item?.vault_id === capture.targetVaultId);
            if (vault) {
              const epoch = String(vault.active_key_epoch);
              const version = String(vault.membership_version);
              const addressedEnvelopes = (Array.isArray(vault.key_envelopes)
                ? vault.key_envelopes : []).filter((item) =>
                typeof capture.viewerDeviceId === 'string' &&
                item?.recipient_device_id === capture.viewerDeviceId);
              capture.targetVaultKeyEnvelopeSummaries = addressedEnvelopes.map((item) => ({
                keyEpoch: String(item?.key_epoch),
                membershipVersion: String(item?.membership_version),
                signerDeviceId: typeof item?.signer_device_id === 'string'
                  ? item.signer_device_id : null,
              }));
              const matchingEnvelopes = addressedEnvelopes.filter((item) =>
                String(item?.key_epoch) === epoch &&
                String(item?.membership_version) === version);
              summary.targetVaultPresent = true;
              summary.activeKeyEpoch = epoch;
              summary.membershipVersion = version;
              summary.matchingCurrentKeyEnvelopeCount = matchingEnvelopes.length;
              if (diagnostic) {
                diagnostic.targetVaultPresent = true;
                diagnostic.keyEpoch = epoch;
                diagnostic.membershipVersion = version;
                diagnostic.matchingCurrentKeyEnvelopeCount = matchingEnvelopes.length;
                diagnostic.addressedEnvelopeCount = addressedEnvelopes.length;
                diagnostic.addressedEnvelopeKeyEpoch = matchingEnvelopes.length > 0
                  ? String(matchingEnvelopes[0].key_epoch) : null;
                diagnostic.addressedEnvelopeMembershipVersion = matchingEnvelopes.length > 0
                  ? String(matchingEnvelopes[0].membership_version) : null;
              }
            }
          }
        } catch (_) {}
        capture.vaultListResponses.push(summary);
      } else if (request.method() === 'GET' &&
          url.pathname === `/api/v1/vaults/${capture.targetVaultId}/membership`) {
        const summary = {
          order,
          status: response.status(),
          manifestCount: null,
          membershipVersion: null,
          keyEpoch: null,
        };
        try {
          if (response.status() === 200) {
            const body = await response.json();
            const rows = Array.isArray(body?.manifests) ? body.manifests : [];
            const versions = rows.map((row) => ({
              version: Number(row?.membership_version),
              epoch: Number(row?.manifest?.manifest?.key_epoch),
            })).filter((item) => Number.isSafeInteger(item.version) &&
              Number.isSafeInteger(item.epoch));
            const latest = versions.sort((left, right) =>
              left.version - right.version).at(-1);
            summary.manifestCount = rows.length;
            if (diagnostic) diagnostic.manifestCount = rows.length;
            if (latest) {
              summary.membershipVersion = String(latest.version);
              summary.keyEpoch = String(latest.epoch);
              if (diagnostic) {
                diagnostic.membershipVersion = summary.membershipVersion;
                diagnostic.keyEpoch = summary.keyEpoch;
              }
            }
          }
        } catch (_) {}
        capture.membershipResponses.push(summary);
      }
    });

    activeStage = 'missed membership hint: issue Viewer account invitation';
    const accountInvitation = issueInstanceAccountInvite(memberUsername, serverEnv);
    accountInvitationToken = accountInvitation;
    activeStage = 'missed membership hint: fill Viewer server URL';
    await fill(viewerPage, 'Server URL', baseUrl);
    activeStage = 'missed membership hint: connect Viewer to test server';
    await click(viewerPage, 'Connect securely');
    activeStage = 'missed membership hint: wait for Viewer login form';
    await field(viewerPage, 'Email or username');
    activeStage = 'missed membership hint: open invited Viewer registration';
    await click(viewerPage, 'Have an instance invitation? Create account');
    activeStage = 'missed membership hint: fill Viewer registration';
    await field(viewerPage, 'Email on the invitation');
    await fill(viewerPage, 'Email on the invitation', memberUsername);
    await fill(viewerPage, 'Master password · 12+ characters', memberPassword);
    await fill(viewerPage, 'Confirm master password', memberPassword);
    await fill(viewerPage, 'Instance invitation token', accountInvitationToken);
    accountInvitationToken = undefined;
    await fill(viewerPage, 'Device name', `Read-only viewer ${suffix}`);
    await fill(viewerPage, 'First Vault', `Viewer personal ${suffix}`);
    activeStage = 'missed membership hint: submit Viewer registration';
    await click(viewerPage, 'Create invited account');
    activeStage = 'missed membership hint: load Viewer workspace';
    await waitWorkspace(viewerPage);

    activeStage = 'missed membership hint: open Viewer Settings';
    await click(viewerPage, 'Settings');
    activeStage = 'missed membership hint: locate Viewer share request control';
    const shareButton = await button(viewerPage, 'Copy signed share request');
    await shareButton.scrollIntoViewIfNeeded();
    activeStage = 'missed membership hint: copy Viewer share request';
    await click(viewerPage, 'Copy signed share request');
    activeStage = 'missed membership hint: confirm Viewer share request copy';
    await click(viewerPage, 'Copy');
    activeStage = 'missed membership hint: wait for signed Viewer share request clipboard';
    let shareRequestValue;
    await waitUntil(async () => {
      try {
        shareRequest = await readClipboard(viewerPage);
        shareRequestValue = JSON.parse(shareRequest);
        return shareRequestValue?.format === 'atermius-vault-share-request-v1';
      } catch (_) {
        return false;
      }
    }, 8000, 'signed Viewer share request clipboard');
    activeStage = 'missed membership hint: validate Viewer share request';
    assertThat(shareRequestValue.format === 'atermius-vault-share-request-v1' &&
      typeof shareRequestValue.account_id === 'string' &&
      typeof shareRequestValue.device?.device_id === 'string',
    'read-only device did not produce a signed share request');

    activeStage = 'missed membership hint: open Owner Settings for Vault invitation';
    await click(ownerPage, 'Settings');
    activeStage = 'missed membership hint: locate Owner Vault invitation control';
    const inviteButton = await button(ownerPage, 'Invite member');
    await inviteButton.scrollIntoViewIfNeeded();
    activeStage = 'missed membership hint: open Owner Vault invitation form';
    await click(ownerPage, 'Invite member');
    activeStage = 'missed membership hint: paste Viewer signed share request';
    await paste(ownerPage, 'Public Device Card JSON', shareRequest);
    activeStage = 'missed membership hint: verify Viewer signed share request';
    await click(ownerPage, 'Verify and review');
    activeStage = 'missed membership hint: wait for Vault invitation target';
    await waitForText(ownerPage, 'Confirm target:');
    activeStage = 'missed membership hint: create Vault invitation';
    await click(ownerPage, 'Sign and create invitation');
    activeStage = 'missed membership hint: locate Vault invitation token copy';
    await button(ownerPage, 'Copy token');
    activeStage = 'missed membership hint: copy Vault invitation token';
    await click(ownerPage, 'Copy token');
    activeStage = 'missed membership hint: read Vault invitation token';
    vaultInvitationToken = await readClipboard(ownerPage);
    activeStage = 'missed membership hint: validate Vault invitation token';
    assertThat(/^[A-Za-z0-9_-]{40,}$/.test(vaultInvitationToken),
      'Owner did not produce a one-time Vault invitation token');
    activeStage = 'missed membership hint: open Viewer Settings for Vault acceptance';
    await click(viewerPage, 'Settings');
    activeStage = 'missed membership hint: open Viewer Vault acceptance form';
    await click(viewerPage, 'Accept invitation');
    activeStage = 'missed membership hint: fill Viewer Vault invitation token';
    await fill(viewerPage, 'Invitation token', vaultInvitationToken);
    vaultInvitationToken = undefined;
    activeStage = 'missed membership hint: submit Viewer Vault invitation';
    await click(viewerPage, 'Accept and unlock Vault');
    activeStage = 'missed membership hint: observe Viewer Vault acceptance response';
    await waitUntil(() => capture.viewerVaultAcceptanceStatuses.length > 0,
      20000, 'Viewer Vault invitation acceptance request');
    assertThat(capture.viewerVaultAcceptanceStatuses.at(-1) === 200,
      'Viewer Vault invitation acceptance returned a non-success status');
    activeStage = 'missed membership hint: scroll accepted Editor Vault descriptor into view';
    const editorRoleWaitStartedAt = Date.now();
    let editorDescriptorScroll = null;
    try {
      editorDescriptorScroll = await scrollLastVisibleSemanticNodeContaining(
        viewerPage, 'Web sync test vault');
      activeStage = 'missed membership hint: verify accepted Editor role';
      await waitForVisibleSemanticPattern(viewerPage,
        /\beditor\s*·\s*key epoch\s+\d+/i, 45000);
    } catch (error) {
      console.log('diagnostic: accepted Viewer role readiness', JSON.stringify({
        invitationAcceptStatus: capture.viewerVaultAcceptanceStatuses.at(-1) ?? null,
        waitDurationMs: Date.now() - editorRoleWaitStartedAt,
        roleSemantics: await roleEpochSemanticEvidence(viewerPage),
        targetDescriptorScroll: editorDescriptorScroll,
        syncStatusLabels: await visibleSyncStatusLabels(viewerPage),
        pageErrors: {
          sibling: capture.siblingPageErrors,
          viewer: capture.pageErrors,
        },
      }));
      throw error;
    }
    activeStage = 'missed membership hint: open Viewer Hosts for baseline sync';
    await click(viewerPage, 'Hosts');
    activeStage = 'missed membership hint: request accepted Viewer baseline sync';
    await syncNow(viewerPage);
    activeStage = 'missed membership hint: wait for recovery Viewer notification channel';
    await waitUntil(() => capture.recoveryReadyFrames > 0, 20000,
      'recovery Viewer notification connection');
    activeStage = 'missed membership hint: freeze recovery Viewer clock';
    await viewerPage.clock.setFixedTime(new Date());
    activeStage = 'missed membership hint: sync approved Owner sibling baseline';
    await syncNow(siblingPage);
    // Keep the 45-second preflight from racing the deliberately missed hint.
    // The recovery subject's DateTime source is frozen while real timers run.

    const beforeRotation = serverVaultSnapshot(databasePath, ownerUsername).vaults;
    assertThat(beforeRotation.length === 1 &&
      beforeRotation[0].vaultId === capture.targetVaultId,
    'Owner Vault changed before the missed-hint scenario');
    capture.targetSelectedAtActivation = await visibleSemanticTextEvidence(
      viewerPage, 'Web sync test vault');
    capture.activationSyncStatusLabels = await visibleSyncStatusLabels(viewerPage);
    capture.pageErrorsAtActivation = capture.pageErrors;
    assertThat(capture.targetSelectedAtActivation.visibleMatchCount > 0,
      'Viewer did not visibly select the shared target Vault before role rotation');
    console.log('assert: viewer_shared_target_selected_before_rotation=true');
    capture.active = true;
    capture.dropMembershipSetHint = false;

    activeStage = 'missed membership hint: open Owner Settings for role rotation';
    await click(ownerPage, 'Settings');
    activeStage = 'missed membership hint: open Owner Vault member management';
    await click(ownerPage, 'Manage Vault members');
    activeStage = 'missed membership hint: wait for active Editor member';
    await waitUntil(async () => (await visibleVaultMemberLabels(ownerPage))
      .includes('EDITOR · Active'), 20000, 'active Editor member row');
    activeStage = 'missed membership hint: choose Editor role change to Viewer';
    await click(ownerPage, 'Make viewer');

    const roleRotationPath = `/api/v1/vaults/${capture.targetVaultId}/keys/rotate`;
    const roleRotationRequests = new WeakMap();
    ownerRoleRotationRequestListener = (request) => {
      const url = new URL(request.url());
      if (request.method() === 'POST' && url.pathname === roleRotationPath) {
        const rotation = { sentAt: Date.now(), status: null, responseReceivedAt: null };
        roleRotationRequests.set(request, rotation);
        capture.ownerRoleRotationRequests.push(rotation);
      }
    };
    ownerRoleRotationResponseListener = (response) => {
      const rotation = roleRotationRequests.get(response.request());
      if (!rotation) return;
      rotation.status = response.status();
      rotation.responseReceivedAt = Date.now();
      capture.ownerRoleRotationResponses.push(rotation);
    };
    ownerPage.on('request', ownerRoleRotationRequestListener);
    ownerPage.on('response', ownerRoleRotationResponseListener);
    const droppedHintCountBeforeRoleRotation =
      capture.droppedMembershipSetHintCount;
    const forwardedHintCountBeforeRoleRotation =
      capture.forwardedMembershipSetHintCount;
    capture.dropMembershipSetHint = true;
    activeStage = 'missed membership hint: confirm Viewer role change';
    await click(ownerPage, 'Change to viewer');
    activeStage = 'missed membership hint: observe Owner role-rotation response';
    await waitUntil(() => capture.ownerRoleRotationResponses.length > 0,
      20000, 'Owner Viewer role-rotation response');
    const roleRotationResponse = capture.ownerRoleRotationResponses.at(-1);
    assertThat(roleRotationResponse.status === 200,
      'Owner Viewer role-rotation request did not succeed');
    capture.ownerRoleRotationResponseObserved = true;
    activeStage = 'missed membership hint: wait for active Viewer member';
    await waitUntil(async () => (await visibleVaultMemberLabels(ownerPage))
      .includes('VIEWER · Active'), 20000, 'active Viewer member row');
    activeStage = 'missed membership hint: observe dropped membership-set notification';
    await waitUntil(() =>
      capture.droppedMembershipSetHintCount > droppedHintCountBeforeRoleRotation &&
      capture.droppedMembershipSetHintTimes.some((receivedAt) =>
        receivedAt >= roleRotationResponse.sentAt &&
        receivedAt <= roleRotationResponse.responseReceivedAt + 10000),
      15000, 'suppressed Viewer membership-set hint');
    assertThat(capture.droppedMembershipSetHintCount >
      droppedHintCountBeforeRoleRotation &&
      capture.droppedMembershipSetHintTimes.some((receivedAt) =>
        receivedAt >= roleRotationResponse.sentAt &&
        receivedAt <= roleRotationResponse.responseReceivedAt + 10000),
    'suppressed membership-set hint did not follow the committed role rotation');
    const droppedHintTimesInRotationWindow =
      capture.droppedMembershipSetHintTimes.filter((receivedAt) =>
        receivedAt >= roleRotationResponse.sentAt &&
        receivedAt <= roleRotationResponse.responseReceivedAt + 10000);
    console.log('observed: Viewer role-rotation hint timing', JSON.stringify({
      rotationStatus: roleRotationResponse.status,
      rotationSentAt: roleRotationResponse.sentAt,
      rotationResponseReceivedAt: roleRotationResponse.responseReceivedAt,
      droppedHintCountDelta: capture.droppedMembershipSetHintCount -
        droppedHintCountBeforeRoleRotation,
      droppedHintReceivedInRotationWindow: droppedHintTimesInRotationWindow.length > 0,
      droppedHintInRotationWindowCount: droppedHintTimesInRotationWindow.length,
      forwardedHintCountDelta: capture.forwardedMembershipSetHintCount -
        forwardedHintCountBeforeRoleRotation,
      latestDroppedHintReceivedAt: Math.max(...droppedHintTimesInRotationWindow),
    }));
    ownerPage.off('request', ownerRoleRotationRequestListener);
    ownerPage.off('response', ownerRoleRotationResponseListener);

    const rotatedVault = serverVaultSnapshot(databasePath, ownerUsername).vaults
      .find((vault) => vault.vaultId === capture.targetVaultId);
    assertThat(rotatedVault !== undefined &&
      Number(rotatedVault.activeKeyEpoch) === Number(beforeRotation[0].activeKeyEpoch) + 1 &&
      Number(rotatedVault.membershipVersion) === Number(beforeRotation[0].membershipVersion) + 1,
    'real Viewer role change did not commit one new key epoch and membership version');
    capture.expectedEpoch = rotatedVault.activeKeyEpoch;
    capture.expectedMembershipVersion = rotatedVault.membershipVersion;

    await click(ownerPage, 'Close');
    await click(ownerPage, 'Hosts');
    const ownerPushListener = (request) => {
      const url = new URL(request.url());
      if (request.method() !== 'POST' || !url.pathname.endsWith('/sync/push')) return;
      try {
        const body = request.postDataJSON();
        for (const envelope of body?.operations || []) {
          const header = envelope?.header;
          if (typeof header?.record_id !== 'string') continue;
          capture.ownerPushes.push({
            recordId: header.record_id,
            keyEpoch: String(header.key_epoch),
            membershipVersion: String(header.membership_version),
            operation: String(header.operation),
          });
          if (String(header.key_epoch) === capture.expectedEpoch &&
              String(header.membership_version) === capture.expectedMembershipVersion) {
            capture.targetRecordId = header.record_id;
          }
        }
      } catch (_) {}
    };
    ownerPage.on('request', ownerPushListener);
    activeStage = 'missed membership hint: commit new-epoch Host';
    await addHost(ownerPage, {
      name: markerAfterRotation,
      address: endpoint,
      username: markerUsername,
    });
    await syncNow(ownerPage);
    ownerPage.off('request', ownerPushListener);
    const targetPush = capture.ownerPushes.find((entry) =>
      entry.keyEpoch === capture.expectedEpoch &&
      entry.membershipVersion === capture.expectedMembershipVersion);
    const targetId = targetPush?.recordId;
    assertThat(typeof targetId === 'string',
      'Owner did not create the new-epoch Host operation');
    capture.targetRecordId = targetId;
    await waitForHostRecord(ownerPage, markerAfterRotation, true, `${endpoint}:22`);
    const committed = serverVaultSnapshot(databasePath, ownerUsername).vaults
      .find((vault) => vault.vaultId === capture.targetVaultId);
    assertThat(committed?.commitSeq === String(Number(rotatedVault.commitSeq) + 1),
      'new-epoch Host did not create exactly one Vault commit');
    capture.expectedTargetCommitSeq = committed.commitSeq;
    activeStage = 'missed membership hint: observe target commit notification';
    await waitUntil(() => capture.deliveredCommitHints.some((entry) =>
      entry.vaultId === capture.targetVaultId && entry.commitSeq === committed.commitSeq),
    15000, 'normal notification for the committed target record');
    const matchingTargetCommitHints = capture.deliveredCommitHints.filter((entry) =>
      entry.vaultId === capture.targetVaultId && entry.commitSeq === committed.commitSeq);

    activeStage = 'missed membership hint: hold Viewer control-plane refresh';
    try {
      await waitUntil(() => capture.vaultListHeld,
        30000, 'client membership refresh gate after unknown-epoch event');
    } catch (error) {
      console.log('diagnostic: Viewer control-plane refresh gate', JSON.stringify({
        holdNextVaultList: capture.holdNextVaultList,
        vaultListHeld: capture.vaultListHeld,
        targetEventResponseGateArmedCount: capture.targetEventResponseGateArmedCount,
        exactEventArmedGate: capture.targetEventResponseGateArmedCount > 0,
        changesRequestCount: capture.changesRequests.length,
        targetChangesRequestCount: capture.changesRequests.filter((entry) =>
          entry.targetVaultRequest).length,
        targetChangesResponseCount: capture.targetChangesResponses.length,
        targetChangesRequests: capture.changesRequests.map((entry) => ({
            targetVaultRequest: entry.targetVaultRequest,
            order: entry.order,
            responseReceived: entry.responseReceived,
            status: entry.status,
            afterOwnerRoleRotationResponse:
              entry.afterOwnerRoleRotationResponse,
            afterExactTargetCommitHint: entry.afterTargetCommitHint,
          })),
        targetChangesResponses: capture.targetChangesResponses.map((entry) => ({
          targetVaultRequest: entry.targetVaultRequest,
          order: entry.order,
          status: entry.status,
          eventCount: entry.eventCount,
          keyEpoch: entry.keyEpoch,
          membershipVersion: entry.membershipVersion,
        })),
        deliveredTargetCommitHintCount: matchingTargetCommitHints.length,
        targetSelectedAtActivation: capture.targetSelectedAtActivation,
        targetSelectedAtFailure: await visibleSemanticTextEvidence(
          viewerPage, 'Web sync test vault'),
        activationSyncStatusLabels: capture.activationSyncStatusLabels,
        matchingNewEpochEventArmed:
          capture.targetEventResponseGateArmedCount === 1,
        dropMembershipSetHint: capture.dropMembershipSetHint,
        droppedMembershipSetHintCount: capture.droppedMembershipSetHintCount,
        droppedMembershipSetHintCountSinceRotation:
          capture.droppedMembershipSetHintCount - droppedHintCountBeforeRoleRotation,
        forwardedMembershipSetHintCount: capture.forwardedMembershipSetHintCount,
        forwardedMembershipSetHintCountSinceRotation:
          capture.forwardedMembershipSetHintCount - forwardedHintCountBeforeRoleRotation,
        syncStatusLabels: await visibleSyncStatusLabels(viewerPage),
        pageErrors: {
          sibling: capture.siblingPageErrors,
          viewer: capture.pageErrors,
          viewerAtActivation: capture.pageErrorsAtActivation,
          viewerSinceActivation: capture.pageErrorsAtActivation == null
            ? null : capture.pageErrors - capture.pageErrorsAtActivation,
          viewerKinds: capture.pageErrorKinds,
        },
      }));
      throw error;
    }
    await waitUntil(() => capture.targetChangesResponses.length >= 1,
      10000, 'initial opaque new-epoch changes response capture');
    capture.dropMembershipSetHint = false;
    assertThat(capture.forwardedMembershipSetHintCount ===
      forwardedHintCountBeforeRoleRotation,
    'a duplicate membership-set hint reached the Viewer before its first target changes response');
    const firstChanges = capture.targetChangesResponses[0];
    assertThat(firstChanges?.targetVaultRequest === true &&
      firstChanges.status === 200 &&
      firstChanges.keyEpoch === capture.expectedEpoch &&
      firstChanges.membershipVersion === capture.expectedMembershipVersion &&
      firstChanges.plaintextMarkersAbsent && firstChanges.envelopeShapeValid,
    'read-only pull did not encounter the opaque new-epoch event');
    const firstChangesPageMetadata = capture.recoveryRequests.find((entry) =>
      entry.path === 'changes' && entry.targetVaultRequest &&
      entry.order === firstChanges.order);
    const firstChangesPageEvents = firstChangesPageMetadata?.changeEvents ?? [];
    assertThat(firstChanges.eventCount === 1 && firstChangesPageEvents.length === 1,
      'initial missed-key changes page contained unexpected additional events');
    assertThat(firstChangesPageEvents[0].commitSeq === committed.commitSeq &&
      firstChangesPageEvents[0].keyEpoch === capture.expectedEpoch &&
      firstChangesPageEvents[0].membershipVersion ===
        capture.expectedMembershipVersion,
    'initial target event metadata did not match the committed Host');
    assertThat(!await hostRecordVisible(viewerPage, markerAfterRotation, `${endpoint}:22`),
      'unknown-epoch Host rendered before membership/key refresh completed');
    assertThat(capture.targetChangesResponses.length === 1,
      'changes cursor advanced or retried while the control-plane refresh was held');
    assertThat(capture.targetEventResponseGateArmedCount === 1,
      'the control-plane gate was not armed by the specific unknown-epoch event page');
    assertThat((await visibleSyncStatusLabels(viewerPage)).includes('Key update needed'),
      'read-only Viewer UI did not expose the bounded key-update recovery state');
    assertThat(capture.syncPushRequests === 0,
      'read-only Viewer unexpectedly attempted a sync push before key refresh');

    await capture.releaseVaultList?.().catch(() => {});
    capture.releaseVaultList = null;
    const emitViewerRecoveryDiagnostics = async (phase) => {
      const recoveryChangeRequests = capture.changesRequests.filter((entry) =>
        entry.targetVaultRequest && entry.order >= firstChanges.order);
      const currentViewerVaultSigners = new Set(
        capture.targetVaultSignerDeviceIds);
      const requests = capture.recoveryRequests.filter((entry) =>
        entry.order >= firstChanges.order).map((entry) => ({
        path: entry.path,
        targetVaultRequest: entry.targetVaultRequest,
        order: entry.order,
        responseReceived: entry.responseReceived,
        status: entry.status,
        cursorPresent: entry.path === 'changes' &&
          typeof entry.cursor === 'string' && entry.cursor !== '<first-page>',
        firstPageCursor: entry.path === 'changes' && entry.cursor === '<first-page>',
      }));
      const responses = capture.recoveryRequests.filter((entry) =>
        entry.order >= firstChanges.order && entry.responseReceived).map((entry) => ({
        path: entry.path,
        targetVaultRequest: entry.targetVaultRequest,
        order: entry.order,
        status: entry.status,
        rowCount: entry.rowCount,
        targetVaultPresent: entry.targetVaultPresent,
        membershipVersion: entry.membershipVersion,
        epoch: entry.keyEpoch,
        matchingCurrentKeyEnvelopeCount: entry.matchingCurrentKeyEnvelopeCount,
        manifestCount: entry.manifestCount,
        targetRecordPresent: entry.targetRecordPresent,
        commitSeq: entry.commitSeq,
        eventCount: entry.changeEventCount,
        changeEvents: (entry.changeEvents ?? []).map((event) => ({
          commitSeq: event.commitSeq,
          keyEpoch: event.keyEpoch,
          membershipVersion: event.membershipVersion,
          signerPresent: typeof event.signerDeviceId === 'string' &&
            currentViewerVaultSigners.has(event.signerDeviceId),
        })),
        targetEventSignerPresent: entry.path === 'changes' &&
          entry.targetRecordPresent === true &&
          typeof capture.targetEventSignerDeviceId === 'string'
          ? currentViewerVaultSigners.has(capture.targetEventSignerDeviceId) : null,
        addressedEnvelopeCount: entry.addressedEnvelopeCount,
        addressedEnvelopeKeyEpoch: entry.addressedEnvelopeKeyEpoch,
        addressedEnvelopeMembershipVersion:
          entry.addressedEnvelopeMembershipVersion,
      }));
      const changes = capture.changesRequests.filter((entry) =>
        entry.order >= firstChanges.order).map((entry) => ({
        targetVaultRequest: entry.targetVaultRequest,
        order: entry.order,
        cursorPresent: typeof entry.cursor === 'string' &&
          entry.cursor !== '<first-page>',
        firstPageCursor: entry.cursor === '<first-page>',
        responseReceived: entry.responseReceived,
        status: entry.status,
      }));
      console.log('observed: Viewer recovery request and response metadata',
        JSON.stringify({
          phase,
          syncStatusLabels: await visibleSyncStatusLabels(viewerPage),
          requests,
          responses,
          changes,
          addressedViewerKeyEnvelopes:
            capture.targetVaultKeyEnvelopeSummaries.map((entry) => ({
              keyEpoch: entry.keyEpoch,
              membershipVersion: entry.membershipVersion,
              signerPresent: typeof entry.signerDeviceId === 'string' &&
                currentViewerVaultSigners.has(entry.signerDeviceId),
            })),
          cursorRequestsAfterFirstEvent: recoveryChangeRequests.length,
          firstTwoChangesRequestsUseSameCursor:
            recoveryChangeRequests.length >= 2 &&
            recoveryChangeRequests[0].cursor === recoveryChangeRequests[1].cursor,
        }));
    };
    const waitForViewerRecoveryObservation = async (stage, predicate, label) => {
      activeStage = stage;
      try {
        await waitUntil(predicate, 20000, label);
      } catch (error) {
        await emitViewerRecoveryDiagnostics(`timeout:${stage}`);
        throw error;
      }
    };

    await emitViewerRecoveryDiagnostics(
      'before response waits after releasing Vault-list gate');
    await waitForViewerRecoveryObservation(
      'missed membership hint: observe same-cursor retry after Viewer refresh',
      () => capture.targetChangesResponses.length >= 2,
      'same-cursor changes retry after signed membership refresh');
    await waitForViewerRecoveryObservation(
      'missed membership hint: observe refreshed Viewer Vault list response',
      () => capture.vaultListResponses.some((entry) =>
        entry.order > firstChanges.order),
      'refreshed Viewer Vault-list response');
    await waitForViewerRecoveryObservation(
      'missed membership hint: observe signed Viewer membership response',
      () => capture.membershipResponses.some((entry) =>
        entry.order > firstChanges.order),
      'refreshed signed Viewer membership response');
    await waitForViewerRecoveryObservation(
      'missed membership hint: observe refreshed Viewer device rosters',
      () => capture.controlPlaneResponses.some((entry) =>
        entry.path === 'account-devices' && entry.order > firstChanges.order) &&
        capture.controlPlaneResponses.some((entry) =>
          entry.path === 'vault-devices' && entry.order > firstChanges.order),
      'refreshed Viewer account and Vault device responses');
    await emitViewerRecoveryDiagnostics('after required control-plane responses');

    const finalVaultRead = capture.vaultListResponses.filter((entry) =>
      entry.order > firstChanges.order).at(-1);
    const finalMembership = capture.membershipResponses.filter((entry) =>
      entry.order > firstChanges.order).at(-1);
    const deviceRefresh = capture.controlPlaneResponses.find((entry) =>
      entry.path === 'account-devices' && entry.order > firstChanges.order);
    const vaultDeviceRefresh = capture.controlPlaneResponses.find((entry) =>
      entry.path === 'vault-devices' &&
      entry.order > firstChanges.order);
    const eventRetries = capture.targetChangesResponses.slice(0, 2);
    assertThat(eventRetries.length === 2 &&
      eventRetries.every((entry) => entry.targetVaultRequest) &&
      typeof eventRetries[0].requestCursor === 'string' &&
      eventRetries[0].requestCursor === eventRetries[1].requestCursor,
    'read-only recovery did not retry the event from the unchanged local changes cursor');
    assertThat(eventRetries[1].commitSeq === eventRetries[0].commitSeq &&
      eventRetries[1].commitSeq === committed.commitSeq &&
      eventRetries[1].keyEpoch === eventRetries[0].keyEpoch &&
      eventRetries[1].keyEpoch === capture.expectedEpoch &&
      eventRetries[1].membershipVersion === eventRetries[0].membershipVersion &&
      eventRetries[1].membershipVersion === capture.expectedMembershipVersion,
    'retry event commit, key epoch, or membership version differed from the initial target event');
    assertThat(finalVaultRead?.activeKeyEpoch === capture.expectedEpoch &&
      finalVaultRead.membershipVersion === capture.expectedMembershipVersion &&
      finalVaultRead.matchingCurrentKeyEnvelopeCount > 0 &&
      finalMembership?.keyEpoch === capture.expectedEpoch &&
      finalMembership.membershipVersion === capture.expectedMembershipVersion &&
      deviceRefresh?.status === 200 && deviceRefresh.rowCount > 0 &&
      vaultDeviceRefresh?.status === 200 && vaultDeviceRefresh.rowCount > 0,
    'current signed membership, device roster, or device key envelope was not loaded before retry');
    assertThat(typeof firstChangesPageEvents[0].signerDeviceId === 'string' &&
      capture.targetVaultSignerDeviceIds.includes(
        firstChangesPageEvents[0].signerDeviceId),
    'target event signer was absent from the refreshed Viewer Vault device roster');
    assertThat(eventRetries[1].order > finalVaultRead.order &&
      eventRetries[1].order > finalMembership.order &&
      eventRetries[1].order > deviceRefresh.order &&
      eventRetries[1].order > vaultDeviceRefresh.order,
    'event retry started before the current control-plane material was read');
    assertThat(eventRetries[0].order < deviceRefresh.order &&
      eventRetries[0].order < finalVaultRead.order &&
      eventRetries[0].order < vaultDeviceRefresh.order &&
      eventRetries[0].order < finalMembership.order,
    'membership recovery did not follow the failed new-epoch event page');
    assertThat(eventRetries.every((entry) => entry.plaintextMarkersAbsent &&
      entry.envelopeShapeValid),
    'the server exposed plaintext or a malformed envelope in the changes response');
    assertThat(eventRetries.every((entry) => entry.eventCount === 1),
      'target changes retry page contained unexpected additional events');
    await waitForViewerRecoveryObservation(
      'missed membership hint: wait for Viewer read-only recovery state',
      async () => (await visibleSyncStatusLabels(viewerPage))
        .includes('Read-only'),
      'read-only sync state after control-plane recovery');
    activeStage = 'missed membership hint: render decrypted Host after Viewer refresh';
    await waitForHostRecord(viewerPage, markerAfterRotation, true, `${endpoint}:22`);
    activeStage = 'missed membership hint: verify dropped and delivered hints after replay';
    console.log('observed: Viewer post-replay acceptance state', JSON.stringify({
      readOnlyVisible: (await visibleSyncStatusLabels(viewerPage)).includes('Read-only'),
      targetHostVisible: await hostRecordVisible(viewerPage, markerAfterRotation,
        `${endpoint}:22`),
      droppedMembershipHintCount: capture.droppedMembershipSetHintCount,
      forwardedMembershipHintCount: capture.forwardedMembershipSetHintCount,
      matchingTargetCommitHintCount: matchingTargetCommitHints.length,
      recoverySyncPushRequestCount: capture.syncPushRequests,
      pageErrorCount: capture.pageErrors,
      targetChangesResponseCount: capture.targetChangesResponses.length,
    }));
    assertThat(capture.droppedMembershipSetHintCount >= 1 &&
      matchingTargetCommitHints.length >= 1,
    'the membership hint was not suppressed or the later normal commit hint was not delivered');
    activeStage = 'missed membership hint: verify no unexpected recovery sync push';
    assertThat(capture.syncPushRequests === 0,
      'read-only Viewer recovery attempted an unexpected sync push');
    activeStage = 'missed membership hint: verify browser has no page errors';
    assertThat(capture.pageErrors === 0,
      'Viewer browser raised an uncaught page error during missed-hint recovery');
    activeStage = 'missed membership hint: verify recovery request quiescence';
    await viewerPage.waitForTimeout(500);
    activeStage = 'missed membership hint: assert target changes response quiescence';
    assertThat(capture.targetChangesResponses.length === 2,
      'read-only recovery made extra requests for the target changes page after sync quiesced');
    const targetCursorRequests = capture.changesRequests.filter((entry) =>
      entry.targetVaultRequest && entry.order >= eventRetries[0].order &&
      entry.cursor === eventRetries[0].requestCursor);
    activeStage = 'missed membership hint: assert exact target cursor request count';
    assertThat(targetCursorRequests.length === 2 &&
      targetCursorRequests[0].order === eventRetries[0].order &&
      targetCursorRequests[1].order === eventRetries[1].order,
    'read-only recovery did not make exactly two GET /changes requests at the target cursor');
    const targetVaultChangesRequests = capture.changesRequests.filter((entry) =>
      entry.targetVaultRequest && entry.order >= firstChanges.order);
    activeStage = 'missed membership hint: assert total target Vault changes requests';
    assertThat(targetVaultChangesRequests.length === 2 &&
      targetVaultChangesRequests.every((entry) =>
        entry.responseReceived && entry.status === 200) &&
      targetVaultChangesRequests[0].order === eventRetries[0].order &&
      targetVaultChangesRequests[1].order === eventRetries[1].order,
    'recovery made an unexpected target Vault changes request or received a non-200 response');
    const targetVaultApiPath = `/api/v1/vaults/${capture.targetVaultId}`;
    const siblingSyncApiTag = (request) => {
      const pathname = new URL(request.url()).pathname;
      if (request.method() === 'POST' &&
          pathname === `${targetVaultApiPath}/sync/push`) {
        return 'sync-push';
      }
      if (request.method() !== 'GET') return null;
      if (pathname === `${targetVaultApiPath}/changes`) return 'changes';
      if (pathname === '/api/v1/devices') return 'account-devices';
      if (pathname === '/api/v1/vaults') return 'vault-list';
      if (pathname === `${targetVaultApiPath}/devices`) return 'vault-devices';
      if (pathname === `${targetVaultApiPath}/membership`) return 'vault-membership';
      return null;
    };
    siblingSyncRequestListener = (request) => {
      const path = siblingSyncApiTag(request);
      if (path === null) return;
      const entry = {
        path,
        order: capture.siblingSyncRequests.length + 1,
        completed: false,
        status: null,
      };
      capture.siblingSyncRequests.push(entry);
      siblingSyncRequestByRequest.set(request, entry);
    };
    siblingSyncResponseListener = (response) => {
      const entry = siblingSyncRequestByRequest.get(response.request());
      if (!entry) return;
      entry.completed = true;
      entry.status = response.status();
    };
    siblingPage.on('request', siblingSyncRequestListener);
    siblingPage.on('response', siblingSyncResponseListener);
    const siblingSyncRequestStartCount = capture.siblingSyncRequests.length;
    const siblingSyncSnapshot = async () => {
      const syncStatusLabels = await visibleSyncStatusLabels(siblingPage);
      const requests = capture.siblingSyncRequests
        .slice(siblingSyncRequestStartCount)
        .map(({ path, order, status, completed }) => ({
          path, order, status, completed,
        }));
      const completedChangesCount = requests.filter((entry) =>
        entry.path === 'changes' && entry.completed && entry.status === 200).length;
      return {
        syncStatusLabels,
        requests,
        checks: {
          allRequestsCompleted: requests.every((entry) => entry.completed),
          allResponses200: requests.every((entry) =>
            entry.completed && entry.status === 200),
          completedChangesCount,
        },
      };
    };
    const emitSiblingSyncDiagnostic = async () => {
      console.log('diagnostic: Owner sibling post-rotation sync', JSON.stringify({
        ...(await siblingSyncSnapshot()),
      }));
    };
    const waitForSiblingSyncQuiescence = async () => {
      const deadline = Date.now() + 15000;
      let idleSince = null;
      let previousRequestCount = capture.siblingSyncRequests.length -
        siblingSyncRequestStartCount;
      while (Date.now() < deadline) {
        const snapshot = await siblingSyncSnapshot();
        const currentRequestCount = snapshot.requests.length;
        const requestCountChanged = currentRequestCount !== previousRequestCount;
        previousRequestCount = currentRequestCount;
        const idle = snapshot.syncStatusLabels.length > 0 &&
          snapshot.syncStatusLabels.every((label) => label === 'Idle');
        const requestsSuccessful = snapshot.checks.allRequestsCompleted &&
          snapshot.checks.allResponses200 &&
          snapshot.checks.completedChangesCount >= 1;
        if (requestCountChanged || !idle || !requestsSuccessful) {
          idleSince = null;
        } else if (idleSince === null) {
          idleSince = Date.now();
        } else if (Date.now() - idleSince >= 500) {
          return;
        }
        await siblingPage.waitForTimeout(100);
      }
      throw new Error('Owner sibling sync did not reach bounded Idle quiescence');
    };
    activeStage = 'missed membership hint: sync Owner sibling after rotation';
    try {
      await syncNow(siblingPage);
    } catch (error) {
      await emitSiblingSyncDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: verify Owner sibling decrypts target Host';
    try {
      await waitForHostRecord(siblingPage, markerAfterRotation, true,
        `${endpoint}:22`);
    } catch (error) {
      await emitSiblingSyncDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: wait for Owner sibling sync quiescence';
    try {
      await waitForSiblingSyncQuiescence();
    } catch (error) {
      await emitSiblingSyncDiagnostic();
      throw error;
    }
    console.log('assert: owner_sibling_sync_quiesced=true');
    await emitSiblingSyncDiagnostic();
    let siblingDescriptorScrollEvidence = {
      targetTitleSemanticLocatorCount: 0,
      targetTitleVisibleSemanticLocatorCount: 0,
      targetTitleScrollAttempted: false,
      targetTitleScrollSucceeded: false,
    };
    const siblingSettingsUiEvidence = async () => {
      const body = await siblingPage.locator('body').innerText().catch(() => '');
      const semanticsEvidence = await siblingPage.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none';
        };
        const nodes = [...document.querySelectorAll('flt-semantics')];
        const label = (node) =>
          `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
        const checks = {
          roleKeyEpoch: /\b(?:owner|editor|viewer)\s*·\s*key epoch\s+\d+/i,
          ownerRoleKeyEpoch: /\bowner\s*·\s*key epoch\s+\d+/i,
          editorRoleKeyEpoch: /\beditor\s*·\s*key epoch\s+\d+/i,
          viewerRoleKeyEpoch: /\bviewer\s*·\s*key epoch\s+\d+/i,
          targetTitle: /Web sync test vault/i,
          currentVault: /CURRENT VAULT/i,
          vaultsHeading: /^\s*Vaults\s*$/i,
        };
        const counts = (pattern) => ({
          count: nodes.filter((node) => pattern.test(label(node))).length,
          visibleCount: nodes.filter((node) =>
            pattern.test(label(node)) && visible(node)).length,
        });
        return {
          semanticsNodeCount: nodes.length,
          roleKeyEpoch: counts(checks.roleKeyEpoch),
          ownerRoleKeyEpoch: counts(checks.ownerRoleKeyEpoch),
          editorRoleKeyEpoch: counts(checks.editorRoleKeyEpoch),
          viewerRoleKeyEpoch: counts(checks.viewerRoleKeyEpoch),
          targetTitle: counts(checks.targetTitle),
          currentVault: counts(checks.currentVault),
          vaultsHeading: counts(checks.vaultsHeading),
        };
      }).catch(() => ({
        semanticsNodeCount: null,
        roleKeyEpoch: { count: null, visibleCount: null },
        ownerRoleKeyEpoch: { count: null, visibleCount: null },
        editorRoleKeyEpoch: { count: null, visibleCount: null },
        viewerRoleKeyEpoch: { count: null, visibleCount: null },
        targetTitle: { count: null, visibleCount: null },
        currentVault: { count: null, visibleCount: null },
        vaultsHeading: { count: null, visibleCount: null },
      }));
      const syncStatusLabels = await visibleSyncStatusLabels(siblingPage);
      const targetVaultTitleVisible = /Web sync test vault/i.test(body);
      const currentVaultMarkerVisible = /CURRENT VAULT/i.test(body);
      const syncSnapshot = await siblingSyncSnapshot();
      const settingsButtons = siblingPage.getByRole('button', {
        name: 'Settings', exact: true,
      });
      const manageMemberButtons = siblingPage.getByRole('button', {
        name: 'Manage Vault members', exact: true,
      });
      let settingsControlVisible = false;
      let manageVaultMembersControlVisible = false;
      try {
        for (let index = 0; index < await settingsButtons.count(); index += 1) {
          if (await settingsButtons.nth(index).isVisible()) {
            settingsControlVisible = true;
            break;
          }
        }
        for (let index = 0; index < await manageMemberButtons.count(); index += 1) {
          if (await manageMemberButtons.nth(index).isVisible()) {
            manageVaultMembersControlVisible = true;
            break;
          }
        }
      } catch (_) {
        // Keep diagnostics to allowlisted booleans if the page is closing.
      }
      return {
        settingsControlVisible,
        manageVaultMembersControlVisible,
        workspaceSettingsHeadingVisible: /Workspace settings/i.test(body),
        vaultsSectionVisible: /\bVaults\b/i.test(body),
        noVaultEmptyMessageVisible:
          /No Vault is currently available to this device/i.test(body),
        anyRoleKeyEpochLabelVisible:
          /\b(?:owner|editor|viewer)\s*·\s*key epoch\s+\d+/i.test(body),
        roleLabels: {
          owner: /owner\s*·\s*key epoch/i.test(body),
          editor: /editor\s*·\s*key epoch/i.test(body),
          viewer: /viewer\s*·\s*key epoch/i.test(body),
        },
        semanticsEvidence,
        descriptorScroll: siblingDescriptorScrollEvidence,
        targetVaultTitleVisible,
        currentVaultMarkerVisible,
        targetVaultSelected: targetVaultTitleVisible && currentVaultMarkerVisible,
        syncStatusLabels,
        syncCompletionState: syncSnapshot.checks,
        apiRequests: syncSnapshot.requests,
        pageErrors: {
          sibling: capture.siblingPageErrors,
          viewer: capture.pageErrors,
        },
      };
    };
    const emitSiblingRoleUiDiagnostic = async () => {
      console.log('diagnostic: Owner sibling role UI',
        JSON.stringify(await siblingSettingsUiEvidence()));
    };
    activeStage = 'missed membership hint: click Owner sibling Settings';
    try {
      await click(siblingPage, 'Settings');
    } catch (error) {
      await emitSiblingRoleUiDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: locate Owner member management control';
    try {
      const manageMemberButton = await button(siblingPage, 'Manage Vault members');
      await manageMemberButton.scrollIntoViewIfNeeded();
    } catch (error) {
      await emitSiblingRoleUiDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: scroll target Vault semantic descriptor into view';
    const targetTitleSemantics = siblingPage.locator('flt-semantics')
      .filter({ hasText: 'Web sync test vault' });
    siblingDescriptorScrollEvidence.targetTitleSemanticLocatorCount =
      await targetTitleSemantics.count().catch(() => 0);
    try {
      for (let index = siblingDescriptorScrollEvidence.targetTitleSemanticLocatorCount - 1;
        index >= 0; index -= 1) {
        const candidate = targetTitleSemantics.nth(index);
        if (!await candidate.isVisible().catch(() => false)) continue;
        siblingDescriptorScrollEvidence.targetTitleVisibleSemanticLocatorCount++;
        if (siblingDescriptorScrollEvidence.targetTitleScrollAttempted) continue;
        siblingDescriptorScrollEvidence.targetTitleScrollAttempted = true;
        await candidate.scrollIntoViewIfNeeded();
        siblingDescriptorScrollEvidence.targetTitleScrollSucceeded = true;
      }
    } catch (error) {
      await emitSiblingRoleUiDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: wait for Owner role label after descriptor scroll';
    try {
      await waitForVisibleSemanticPattern(siblingPage,
        /\bowner\s*·\s*key epoch\s+\d+/i, 20000);
    } catch (error) {
      await emitSiblingRoleUiDiagnostic();
      throw error;
    }
    activeStage = 'missed membership hint: verify Viewer role after recovery';
    await click(viewerPage, 'Settings');
    let finalViewerDescriptorScroll = null;
    try {
      finalViewerDescriptorScroll = await scrollLastVisibleSemanticNodeContaining(
        viewerPage, 'Web sync test vault');
      await waitForVisibleSemanticPattern(viewerPage,
        /\bviewer\s*·\s*key epoch\s+\d+/i, 20000);
    } catch (error) {
      console.log('diagnostic: final Viewer role readiness', JSON.stringify({
        roleSemantics: await roleEpochSemanticEvidence(viewerPage),
        targetDescriptorScroll: finalViewerDescriptorScroll,
        syncStatusLabels: await visibleSyncStatusLabels(viewerPage),
        pageErrors: {
          sibling: capture.siblingPageErrors,
          viewer: capture.pageErrors,
        },
      }));
      throw error;
    }
    activeStage = 'missed membership hint: verify Viewer cannot add a Host';
    await click(viewerPage, 'Hosts');
    assertThat(await (await button(viewerPage, 'Add host')).isDisabled(),
      'refreshed Viewer role unexpectedly allowed local Host creation');

    console.log('assert: membership_hint_suppressed=true');
    console.log('assert: later_commit_hint_delivered=true');
    console.log('assert: membership_and_current_key_envelope_loaded_before_event_retry=true');
    console.log('assert: event_not_rendered_or_cursor_advanced_before_key_refresh=true');
    console.log('assert: unexpected_recovery_sync_pushes=0');
    console.log('scope: this browser journey verifies no recovery sync push; pending-outbox retention is covered by the Flutter storage regression');
    console.log(`observed: dropped_membership_hint_count=${capture.droppedMembershipSetHintCount}`);
    console.log('WEB-MISSED-MEMBERSHIP-HINT-01 passed');
  } finally {
    await capture.releaseVaultList?.().catch(() => {});
    capture.dropMembershipSetHint = false;
    siblingPage.off('pageerror', siblingPageErrorListener);
    if (siblingSyncRequestListener) {
      siblingPage.off('request', siblingSyncRequestListener);
    }
    if (siblingSyncResponseListener) {
      siblingPage.off('response', siblingSyncResponseListener);
    }
    if (ownerRoleRotationRequestListener) {
      ownerPage.off('request', ownerRoleRotationRequestListener);
    }
    if (ownerRoleRotationResponseListener) {
      ownerPage.off('response', ownerRoleRotationResponseListener);
    }
    accountInvitationToken = undefined;
    vaultInvitationToken = undefined;
    shareRequest = undefined;
    viewerPage = undefined;
    if (viewerContext) await viewerContext.close().catch(() => {});
  }
}

async function waitForNotificationFrame(events, predicate, afterIndex = 0, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = events.slice(afterIndex).find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`notification frame timed out; observed=${JSON.stringify(
    events.slice(afterIndex).map(({ profile, direction, type }) => ({ profile, direction, type })).slice(-20),
  )}`);
}

async function waitForApiEntry(entries, predicate, afterIndex = 0, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = entries.slice(afterIndex).find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected authorized API pull did not occur after sync notification');
}

async function waitForDeviceStatus(
  snapshots,
  profile,
  name,
  status,
  timeoutMs = 15000,
  { requestAtOrAfterMs = null } = {},
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const eligible = snapshots[profile].filter((snapshot) =>
      requestAtOrAfterMs === null || snapshot.requestAtMs >= requestAtOrAfterMs);
    const latest = eligible.slice().reverse()
      .find((snapshot) => snapshot.devices.some((device) => device.name === name));
    const found = latest?.devices.find((device) => device.name === name);
    if (found?.status === status) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`device status did not become ${status}`);
}

async function waitForConflictFeedEvent(events, predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = events.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected conflict feed event was not observed');
}

function changesCursorSequence(cursor) {
  if (typeof cursor !== 'string') return null;
  try {
    const decoded = Buffer.from(cursor, 'base64url');
    if (decoded.length <= 32) return null;
    const payload = JSON.parse(decoded.subarray(0, decoded.length - 32).toString('utf8'));
    return payload?.v === 1 && Number.isSafeInteger(payload.seq) && payload.seq >= 0
      ? String(payload.seq)
      : null;
  } catch (_) {
    return null;
  }
}

async function openSameProfilePeerTab({ page, baseUrl, startupEvidence }) {
  const response = await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  assertThat(response && response.status() === 200,
    'same-profile peer-tab navigation did not return HTTP 200');
  await enableFlutterSemantics(page, 'A', startupEvidence);
  await selectServerModeIfChooser(page);
  const deadline = Date.now() + 20000;
  let entryReady = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', {
      name: 'Add host', exact: true,
    }).isVisible().catch(() => false) ||
        await page.locator('input[aria-label*="Email or username"]')
          .first().isVisible().catch(() => false)) {
      entryReady = true;
      break;
    }
    const canConnect = await page.getByRole('button', {
      name: 'Connect securely', exact: true,
    }).isVisible().catch(() => false) &&
      await page.locator('input[aria-label*="Server URL"]')
        .first().isVisible().catch(() => false);
    if (canConnect) {
      await page.waitForTimeout(300);
      if (await page.getByRole('button', {
        name: 'Add host', exact: true,
      }).isVisible().catch(() => false) ||
          await page.locator('input[aria-label*="Email or username"]')
            .first().isVisible().catch(() => false)) {
        entryReady = true;
        break;
      }
      await connect(page, baseUrl);
      entryReady = true;
      break;
    }
    await page.waitForTimeout(100);
  }
  assertThat(entryReady, 'same-profile peer tab did not reach workspace or login');
  const login = page.locator('input[aria-label*="Email or username"]').first();
  if (await login.isVisible().catch(() => false)) {
    await fill(page, 'Email or username', USERNAME);
    await fill(page, 'Master password', MASTER_PASSWORD);
    await click(page, 'Sign in and unlock');
  }
  await waitWorkspace(page);
}

async function captureHostPush(page, recordId, operation) {
  const pushResponse = await page.waitForResponse((response) => {
    const request = response.request();
    if (request.method() !== 'POST' ||
        !new URL(response.url()).pathname.endsWith('/sync/push')) return false;
    try {
      return (request.postDataJSON()?.operations || []).some((envelope) =>
        envelope?.header?.record_id === recordId &&
        envelope?.header?.operation === operation);
    } catch (_) {
      return false;
    }
  }, { timeout: 45000 });
  assertThat(pushResponse.status() === 200,
    `Host ${operation} request did not receive a successful sync receipt`);
  const request = pushResponse.request();
  const payload = request.postDataJSON();
  const envelope = (payload?.operations || []).find((item) =>
    item?.header?.record_id === recordId && item?.header?.operation === operation);
  const receiptBody = await pushResponse.json();
  const header = envelope?.header || {};
  const receipt = (receiptBody?.results || []).find((item) => item.op_id === header.op_id);
  assertThat(typeof header.revision_id === 'string' &&
    typeof header.op_id === 'string' && receipt?.revision_id === header.revision_id &&
    typeof receipt?.commit_seq === 'string' && /^(0|[1-9][0-9]*)$/.test(receipt.commit_seq),
  `Host ${operation} request did not have a matching durable receipt`);
  return {
    operation,
    recordId,
    revisionId: header.revision_id,
    baseRevisionId: header.base_revision_id ?? null,
    opId: header.op_id,
    deviceId: header.device_id,
    deviceSeq: header.device_seq,
    envelopeSha256: syncOperationSummary({ operations: [envelope] }).envelopeSha256,
    commitSeq: receipt.commit_seq,
    alreadyCommitted: receipt.already_committed === true,
  };
}

function safeChangesPageSummary(requestUrl, status, body, recordId) {
  const events = Array.isArray(body?.events) ? body.events : [];
  const targetEvents = events.flatMap((event) => {
    const header = event?.envelope?.header || {};
    if (header.record_id !== recordId) return [];
    return [{
      recordId: header.record_id,
      revisionId: header.revision_id ?? null,
      operation: header.operation ?? null,
      baseRevisionId: header.base_revision_id ?? null,
      commitSeq: typeof event?.commit_seq === 'string' ? event.commit_seq : null,
    }];
  });
  const url = new URL(requestUrl);
  return {
    status,
    requestCursorSequence: changesCursorSequence(url.searchParams.get('cursor')),
    nextCursorSequence: changesCursorSequence(body?.next_cursor),
    targetEvents,
  };
}

async function runSameProfileStaleChangesAcceptance({
  ownerPage,
  ownerTabPage,
  secondPage,
  ownerContext,
  baseUrl,
  databasePath,
  tempRoot,
  startupEvidence,
  multiTab,
  observedAuthDeviceIds,
}) {
  const vaults = serverVaultSnapshot(databasePath, USERNAME).vaults;
  assertThat(vaults.length === 1,
    'stale changes-page acceptance requires one active Owner Vault');
  const vaultId = vaults[0].vaultId;
  const implementations = await Promise.all([ownerPage, ownerTabPage].map(async (page) => ({
    origin: await page.evaluate(() => location.origin),
    localStorageKeys: await page.evaluate(() => Object.keys(localStorage).sort()),
    indexedDbNames: await page.evaluate(async () => (await indexedDB.databases())
      .map((database) => database.name).filter(Boolean).sort()),
    backend: multiTab.databaseImplementations.get(page),
  })));
  const crossTabSafeBackends = new Set(['opfsShared', 'opfsLocks', 'sharedIndexedDb']);
  assertThat(implementations.every((item) => item.origin === baseUrl &&
    item.backend === implementations[0].backend &&
    JSON.stringify(item.localStorageKeys) === JSON.stringify(implementations[0].localStorageKeys) &&
    JSON.stringify(item.indexedDbNames) === JSON.stringify(implementations[0].indexedDbNames)) &&
    crossTabSafeBackends.has(implementations[0].backend),
  'two same-profile tabs did not select the same persistent cross-tab-safe database');
  const ownerDeviceId = observedAuthDeviceIds.get(ownerPage);
  const peerDeviceId = observedAuthDeviceIds.get(ownerTabPage);
  const secondDeviceId = observedAuthDeviceIds.get(secondPage);
  assertThat(typeof ownerDeviceId === 'string' &&
    (peerDeviceId === undefined || peerDeviceId === ownerDeviceId) &&
    typeof secondDeviceId === 'string' && secondDeviceId !== ownerDeviceId,
  'same-profile peer tab and independent Profile B did not use distinct expected devices');

  const suffix = RUN_ID.slice(0, 8);
  const baseName = `stale-page-base-${suffix}`;
  const intermediateName = `stale-page-r1-${suffix}`;
  const newestName = `stale-page-r2-${suffix}`;
  const address = `192.0.2.${20 + Number.parseInt(suffix.slice(0, 2), 16) % 200}`;
  activeStage = 'same-profile stale-page: commit the baseline Host on Profile A';
  const createResponsePromise = ownerPage.waitForResponse((response) => {
    const request = response.request();
    if (request.method() !== 'POST' ||
        !new URL(response.url()).pathname.endsWith('/sync/push')) return false;
    try {
      return (request.postDataJSON()?.operations || []).some((envelope) =>
        envelope?.header?.operation === 'create');
    } catch (_) {
      return false;
    }
  }, { timeout: 45000 });
  await addHost(ownerPage, {
    name: baseName,
    address,
    username: `race-${suffix}`,
  });
  await syncNow(ownerPage, { expectedVaultId: vaultId });
  const createResponse = await createResponsePromise;
  assertThat(createResponse.status() === 200,
    'baseline Host create did not receive a successful receipt');
  const createPayload = createResponse.request().postDataJSON();
  const createEnvelope = (createPayload?.operations || []).find((item) =>
    item?.header?.operation === 'create');
  const recordId = createEnvelope?.header?.record_id;
  const createHeader = createEnvelope?.header || {};
  const createBody = await createResponse.json();
  const createReceipt = (createBody?.results || []).find((item) =>
    item.op_id === createHeader.op_id);
  assertThat(typeof recordId === 'string' &&
    createReceipt?.revision_id === createHeader.revision_id &&
    typeof createReceipt?.commit_seq === 'string',
  'baseline Host create did not expose a matching operation receipt');
  const baseRevisionId = createHeader.revision_id;
  const baseCommitSeq = createReceipt.commit_seq;
  await syncNow(ownerTabPage, { expectedVaultId: vaultId });
  await syncNow(secondPage, { expectedVaultId: vaultId });
  await Promise.all([ownerPage, ownerTabPage, secondPage].map((page) =>
    waitForHostRecord(page, baseName, true)));

  activeStage = 'same-profile stale-page: commit an intermediate revision from Profile B';
  await ownerContext.setOffline(true);
  await Promise.all([ownerPage, ownerTabPage].map((page) => page.waitForFunction(
    () => navigator.onLine === false, undefined, { timeout: 10000 },
  )));
  const intermediatePushPromise = captureHostPush(secondPage, recordId, 'update');
  await editHostName(secondPage, baseName, intermediateName);
  await syncNow(secondPage, { expectedVaultId: vaultId });
  const intermediate = await intermediatePushPromise;
  assertThat(intermediate.baseRevisionId === baseRevisionId &&
    intermediate.deviceId === secondDeviceId && intermediate.alreadyCommitted === false,
  'Profile B intermediate revision did not descend from the baseline Host');
  await Promise.all([ownerPage, ownerTabPage].map((page) =>
    waitForHostRecord(page, baseName, true)));

  let releaseOlderPage;
  const olderPageRelease = new Promise((resolve) => { releaseOlderPage = resolve; });
  let olderPageHeld = false;
  let olderPageSummary = null;
  let ownerChangesRouteCalls = 0;
  let siblingChangesBarrierReleased = false;
  let siblingBlockedChangesRequests = 0;
  let siblingAllowedChangesRequests = 0;
  const ownerChangesRequests = [];
  const ownerChangesFailures = [];
  const ownerChangesPageSummaries = [];
  const siblingPageSummaries = [];
  let ownerSyncTriggerPromise = null;
  const changesPattern = '**/api/v1/vaults/*/changes*';
  const observeOwnerChangesRequest = (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (request.method() === 'GET' && /\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(url.pathname)) {
      ownerChangesRequests.push({
        cursorSequence: changesCursorSequence(url.searchParams.get('cursor')),
      });
    }
  };
  const observeOwnerChangesFailure = (request) => {
    let url;
    try { url = new URL(request.url()); } catch (_) { return; }
    if (request.method() === 'GET' && /\/api\/v1\/vaults\/[0-9a-f-]+\/changes$/i.test(url.pathname)) {
      ownerChangesFailures.push({
        cursorSequence: changesCursorSequence(url.searchParams.get('cursor')),
        errorKind: request.failure()?.errorText ? 'network-failure' : 'unknown',
      });
    }
  };
  const holdIntermediatePage = async (route) => {
    ownerChangesRouteCalls++;
    if (route.request().method() !== 'GET' || olderPageHeld) return route.continue();
    const response = await route.fetch();
    let body = null;
    try { body = await response.json(); } catch (_) {}
    const summary = safeChangesPageSummary(route.request().url(), response.status(), body, recordId);
    ownerChangesPageSummaries.push(summary);
    if (!summary.targetEvents.some((item) => item.revisionId === intermediate.revisionId)) {
      return route.fulfill({ response });
    }
    olderPageHeld = true;
    olderPageSummary = summary;
    await olderPageRelease;
    await route.fulfill({ response });
  };
  const recordSiblingPages = async (route) => {
    if (route.request().method() !== 'GET') return route.continue();
    if (!siblingChangesBarrierReleased) {
      siblingBlockedChangesRequests++;
      return route.abort('internetdisconnected');
    }
    siblingAllowedChangesRequests++;
    const response = await route.fetch();
    let body = null;
    try { body = await response.json(); } catch (_) {}
    siblingPageSummaries.push(
      safeChangesPageSummary(route.request().url(), response.status(), body, recordId),
    );
    await route.fulfill({ response });
  };

  await ownerPage.route(changesPattern, holdIntermediatePage);
  await ownerTabPage.route(changesPattern, recordSiblingPages);
  ownerPage.on('request', observeOwnerChangesRequest);
  ownerPage.on('requestfailed', observeOwnerChangesFailure);
  try {
    activeStage = 'same-profile stale-page: hold Profile A tab response containing the intermediate revision';
    let barrierStep = 'restore profile network';
    try {
      await ownerContext.setOffline(false);
      await Promise.all([ownerPage, ownerTabPage].map((page) => page.waitForFunction(
        () => navigator.onLine === true, undefined, { timeout: 10000 },
      )));
      barrierStep = 'trigger owner sync and wait for R1 interception concurrently';
      ownerSyncTriggerPromise = triggerSyncWithoutWaitingForIdle(ownerPage)
        .then(() => null, (error) => error);
      const heldPageWait = waitUntil(() => olderPageHeld, 45000,
        'Profile A fetched the intermediate changes page');
      heldPageWait.catch(() => {});
      const firstBarrierResult = await Promise.race([
        heldPageWait.then(() => 'held'),
        ownerSyncTriggerPromise.then((error) => error || 'trigger-complete'),
      ]);
      if (firstBarrierResult instanceof Error) throw firstBarrierResult;
      if (firstBarrierResult !== 'held') await heldPageWait;
    } catch (error) {
      console.log('stale changes-page barrier safe diagnostic', JSON.stringify({
        errorKind: safePageErrorKind(error),
        errorClass: safeErrorClass(error),
        errorTextClass: safeErrorTextClass(error),
        barrierStep,
        olderPageHeld,
        intermediateRevisionMatched: ownerChangesPageSummaries.some((summary) =>
          summary.targetEvents.some((item) =>
            item.revisionId === intermediate.revisionId)),
        ownerChangesRouteCalls,
        ownerChangesRequests,
        ownerChangesFailures,
        ownerChangesPageSummaries: ownerChangesPageSummaries.slice(-5),
        siblingBlockedChangesRequests,
        siblingPageSummaries,
        ownerSyncStatus: await visibleSyncStatusLabels(ownerPage),
        siblingSyncStatus: await visibleSyncStatusLabels(ownerTabPage),
        ownerPage: await safePageDiagnostic(ownerPage),
        ownerTabPage: await safePageDiagnostic(ownerTabPage),
      }));
      throw error;
    }
    const heldSummary = olderPageSummary;
    assertThat(heldSummary.status === 200 &&
      heldSummary.targetEvents.filter((item) => item.revisionId === intermediate.revisionId).length === 1 &&
      !heldSummary.targetEvents.some((item) => item.revisionId === baseRevisionId),
    'held Profile A response did not contain exactly the intermediate target revision');
    assertThat(siblingPageSummaries.length === 0,
      'sibling tab applied a changes page before the main-tab R1 barrier was held');

    activeStage = 'same-profile stale-page: commit a newer revision while the older response is held';
    const newestPushPromise = captureHostPush(secondPage, recordId, 'update');
    await editHostName(secondPage, intermediateName, newestName);
    await syncNow(secondPage, { expectedVaultId: vaultId });
    const newest = await newestPushPromise;
    assertThat(newest.baseRevisionId === intermediate.revisionId &&
      newest.deviceId === secondDeviceId && newest.alreadyCommitted === false &&
      BigInt(newest.commitSeq) > BigInt(intermediate.commitSeq),
    'newer Profile B revision did not descend from the intermediate Host revision');

    activeStage = 'same-profile stale-page: sibling tab writes the newer revision into shared IndexedDB';
    const siblingSummaryStart = siblingPageSummaries.length;
    siblingChangesBarrierReleased = true;
    await waitUntil(async () => {
      const labels = await visibleSyncStatusLabels(ownerTabPage);
      return labels.length > 0 && !labels.includes('Syncing');
    }, 15000, 'same-profile sibling leaves the blocked offline/retry sync state');
    await syncNow(ownerTabPage, { expectedVaultId: vaultId });
    await waitUntil(() => siblingPageSummaries.slice(siblingSummaryStart).some((summary) =>
      summary.status === 200 && summary.targetEvents.some((item) =>
        item.revisionId === newest.revisionId)), 30000,
    'same-profile sibling changes page containing the newer revision');
    await Promise.all([ownerTabPage, secondPage].map((page) =>
      waitForHostRecord(page, newestName, true)));

    const newerSiblingPage = siblingPageSummaries.find((summary) =>
      summary.status === 200 && summary.targetEvents.some((item) =>
        item.revisionId === newest.revisionId));
    assertThat(newerSiblingPage &&
      typeof newerSiblingPage.nextCursorSequence === 'string' &&
      BigInt(newerSiblingPage.nextCursorSequence) >= BigInt(newest.commitSeq),
    'same-profile sibling page did not expose the durable newer changes boundary');
    activeStage = 'same-profile stale-page: inspect durable shared checkpoint after sibling applies R2';
    const siblingCheckpointSnapshot = await waitForPersistedSyncCheckpoint({
      page: ownerTabPage,
      tempRoot,
      vaultId,
      minimumSequence: newerSiblingPage.nextCursorSequence,
    });
    const siblingCheckpoint = siblingCheckpointSnapshot.checkpoints?.[0];
    assertThat(siblingCheckpointSnapshot.available &&
      siblingCheckpointSnapshot.integrityCheck === 'ok' &&
      siblingCheckpointSnapshot.journalEmpty &&
      siblingCheckpointSnapshot.checkpointRowCount === 1 &&
      siblingCheckpoint?.cursorPresent &&
      siblingCheckpoint.serverGenerationPresent &&
      BigInt(siblingCheckpoint.cursorSequence) >= BigInt(newest.commitSeq),
    'shared IndexedDB did not durably checkpoint the sibling tab newer changes page');

    activeStage = 'same-profile stale-page: release the late intermediate response';
    releaseOlderPage();
    const ownerSyncTriggerError = await ownerSyncTriggerPromise;
    assertThat(!ownerSyncTriggerError || olderPageSummary !== null,
      'owner sync action failed before its intermediate page reached the held-response barrier');
    await waitUntil(async () => {
      const labels = await visibleSyncStatusLabels(ownerPage);
      return labels.some((label) => label !== 'Syncing');
    }, 45000, 'delayed Profile A sync to settle after stale response');
    const delayedPageCheckpointSnapshot = await waitForPersistedSyncCheckpoint({
      page: ownerPage,
      tempRoot,
      vaultId,
      minimumSequence: siblingCheckpoint.cursorSequence,
    });
    const delayedPageCheckpoint = delayedPageCheckpointSnapshot.checkpoints?.[0];
    assertThat(delayedPageCheckpointSnapshot.available &&
      delayedPageCheckpointSnapshot.integrityCheck === 'ok' &&
      delayedPageCheckpointSnapshot.journalEmpty &&
      delayedPageCheckpointSnapshot.checkpointRowCount === 1 &&
      delayedPageCheckpoint?.cursorPresent &&
      delayedPageCheckpoint.serverGenerationPresent &&
      BigInt(delayedPageCheckpoint.cursorSequence) >=
        BigInt(siblingCheckpoint.cursorSequence),
    'late stale changes page regressed the durable same-profile sync checkpoint');
    await ownerPage.unroute(changesPattern, holdIntermediatePage);
    await ownerTabPage.unroute(changesPattern, recordSiblingPages);

    activeStage = 'same-profile stale-page: reload shared storage with Vault changes API blocked';
    const changesPath = `/api/v1/vaults/${vaultId}/changes`;
    const changesApiPattern = '**/api/v1/vaults/*/changes*';
    let blockedOwnerChangesReads = 0;
    let blockedPeerChangesReads = 0;
    let reloadUnlockAction = 'already-unlocked';
    const blockOwnerVaultChangesRead = async (route) => {
      const request = route.request();
      let url;
      try { url = new URL(request.url()); } catch (_) { return route.continue(); }
      if (request.method() !== 'GET' || url.pathname !== changesPath) {
        return route.continue();
      }
      if (request.frame().page() === ownerPage) blockedOwnerChangesReads++;
      else if (request.frame().page() === ownerTabPage) blockedPeerChangesReads++;
      await route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({
          error: {
            code: 'E2E_CHANGES_UNAVAILABLE',
            message: 'Vault changes intentionally unavailable during local cache reload',
          },
        }),
      });
    };
    await ownerContext.route(changesApiPattern, blockOwnerVaultChangesRead);
    const emailInput = ownerPage.locator('input[aria-label*="Email or username"]').first();
    const masterPasswordInput = ownerPage.locator('input[aria-label*="Master password"]').first();
    const localPasswordInput = ownerPage.locator(
      'input[aria-label*="本地配置主密码"]',
    ).first();
    const localUnlockButton = ownerPage.getByRole('button', {
      name: '解锁本地配置', exact: true,
    });
    const loginButton = ownerPage.getByRole('button', {
      name: 'Sign in and unlock', exact: true,
    });
    const addHostButton = ownerPage.getByRole('button', {
      name: 'Add host', exact: true,
    });
    let reloadEntryCandidate = null;
    let stableReloadEntryReads = 0;
    let reloadStage = 'reload start';
    try {
      assertThat(await ownerPage.evaluate(() => navigator.onLine),
        'static Web origin must remain reachable during API-only offline reload');
      const reloadResponse = await ownerPage.reload({ waitUntil: 'domcontentloaded' });
      assertThat(reloadResponse && reloadResponse.status() === 200,
        'delayed same-profile tab reload did not return HTTP 200');
      reloadStage = 'reload done';
      reloadStage = 'semantics start';
      await enableFlutterSemantics(ownerPage, 'A', startupEvidence);
      reloadStage = 'semantics done';
      reloadStage = 'chooser start';
      await selectServerModeIfChooser(ownerPage);
      reloadStage = 'chooser done';
      reloadStage = 'wait stable reload entry';
      let previousReloadEntry = null;
      await waitUntil(async () => {
        const emailVisible = await emailInput.isVisible().catch(() => false);
        const passwordVisible = await masterPasswordInput.isVisible().catch(() => false);
        const loginVisible = await loginButton.isVisible().catch(() => false);
        const localPasswordVisible = await localPasswordInput.isVisible().catch(() => false);
        const localUnlockVisible = await localUnlockButton.isVisible().catch(() => false);
        const workspaceVisible = await addHostButton.isVisible().catch(() => false);
        const candidate = emailVisible && passwordVisible && loginVisible
          ? 'email-login'
          : passwordVisible && loginVisible
          ? 'password-only-login'
          : localPasswordVisible && localUnlockVisible
          ? 'local-unlock'
          : workspaceVisible
          ? 'workspace'
          : null;
        reloadEntryCandidate = candidate;
        if (candidate !== null && candidate === previousReloadEntry) {
          stableReloadEntryReads++;
        } else {
          stableReloadEntryReads = candidate === null ? 0 : 1;
        }
        previousReloadEntry = candidate;
        return stableReloadEntryReads >= 2;
      }, 30000, 'delayed tab login or workspace entry');
      reloadStage = `stable reload entry: ${reloadEntryCandidate}`;
      if (reloadEntryCandidate === 'email-login') {
        reloadStage = 'email fill start';
        await fill(ownerPage, 'Email or username', USERNAME);
        assertThat(await emailInput.inputValue() === USERNAME,
          'reloaded Owner username field did not retain its fixture value');
        reloadStage = 'email fill done';
        reloadStage = 'password fill start';
        await fill(ownerPage, 'Master password', MASTER_PASSWORD);
        assertThat(await masterPasswordInput.inputValue() === MASTER_PASSWORD,
          'reloaded Owner master-password field did not retain its fixture value');
        reloadStage = 'password fill done';
        reloadStage = 'click start';
        await click(ownerPage, 'Sign in and unlock');
        reloadStage = 'click done';
        reloadUnlockAction = 'sign-in-and-unlock';
      } else if (reloadEntryCandidate === 'password-only-login') {
        reloadStage = 'password fill start';
        await fill(ownerPage, 'Master password', MASTER_PASSWORD);
        assertThat(await masterPasswordInput.inputValue() === MASTER_PASSWORD,
          'reloaded Owner master-password field did not retain its fixture value');
        reloadStage = 'password fill done';
        reloadStage = 'click start';
        await click(ownerPage, 'Sign in and unlock');
        reloadStage = 'click done';
        reloadUnlockAction = 'password-only-sign-in-and-unlock';
      } else if (reloadEntryCandidate === 'local-unlock') {
        reloadStage = 'password fill start';
        await fill(ownerPage, '本地配置主密码', MASTER_PASSWORD);
        assertThat(await localPasswordInput.inputValue() === MASTER_PASSWORD,
          'reloaded local-profile password field did not retain its fixture value');
        reloadStage = 'password fill done';
        reloadStage = 'click start';
        await click(ownerPage, '解锁本地配置');
        reloadStage = 'click done';
        reloadUnlockAction = 'local-profile-unlock';
      } else {
        assertThat(reloadEntryCandidate === 'workspace',
          'reloaded delayed tab did not expose a supported login or workspace entry');
      }
      reloadStage = 'wait workspace';
      await waitWorkspace(ownerPage);
      reloadStage = 'wait workspace done';
      await waitForHostRecord(ownerPage, newestName, true);
      await waitForHostRecord(ownerPage, intermediateName, false);

      if (blockedOwnerChangesReads === 0) {
        const blockedChangesResponsePromise = ownerPage.waitForResponse((response) => {
          const request = response.request();
          return request.method() === 'GET' &&
            new URL(response.url()).pathname === changesPath &&
            response.status() === 503;
        }, { timeout: 20000 });
        await triggerSyncWithoutWaitingForIdle(ownerPage);
        const blockedChangesResponse = await blockedChangesResponsePromise;
        assertThat(blockedChangesResponse.status() === 503,
          'owner Vault changes read was not held behind the controlled offline route');
      }
      assertThat(blockedOwnerChangesReads >= 1,
        'delayed owner tab did not attempt a Vault changes read while server reads were blocked');
      await waitForHostRecord(ownerPage, newestName, true);
      await waitForHostRecord(ownerPage, intermediateName, false);
      await Promise.all([ownerTabPage, secondPage].map((page) =>
        waitForHostRecord(page, newestName, true)));
    } catch (error) {
      console.log('stale changes API-only offline reload safe diagnostic', JSON.stringify({
        errorKind: safePageErrorKind(error),
        reloadStage,
        staticOriginOnline: await ownerPage.evaluate(() => navigator.onLine).catch(() => null),
        blockedOwnerChangesReads,
        blockedPeerChangesReads,
        reloadUnlockAction,
        reloadEntryCandidate,
        stableReloadEntryReads,
        emailInputVisible: await emailInput.isVisible().catch(() => false),
        emailInputValueLength: await emailInput.inputValue().then((value) => value.length).catch(() => null),
        masterPasswordInputVisible: await masterPasswordInput.isVisible().catch(() => false),
        masterPasswordInputValueLength: await masterPasswordInput.inputValue().then((value) => value.length).catch(() => null),
        signInButtonVisible: await ownerPage.getByRole('button', {
          name: 'Sign in and unlock', exact: true,
        }).isVisible().catch(() => false),
        signInButtonEnabled: await ownerPage.getByRole('button', {
          name: 'Sign in and unlock', exact: true,
        }).isEnabled().catch(() => false),
        ownerSyncStatus: await visibleSyncStatusLabels(ownerPage),
        newestHostVisible: await hostRecordVisible(ownerPage, newestName).catch(() => null),
        intermediateHostVisible: await hostRecordVisible(ownerPage, intermediateName).catch(() => null),
        ownerPage: await safePageDiagnostic(ownerPage),
      }));
      throw error;
    } finally {
      await ownerContext.unroute(changesApiPattern, blockOwnerVaultChangesRead).catch(() => {});
    }

    assertThat(olderPageSummary.requestCursorSequence !== null &&
      BigInt(olderPageSummary.requestCursorSequence) < BigInt(intermediate.commitSeq) &&
      BigInt(newerSiblingPage.requestCursorSequence) < BigInt(newest.commitSeq) &&
      BigInt(newerSiblingPage.nextCursorSequence) >= BigInt(newest.commitSeq) &&
      olderPageSummary.targetEvents.some((item) =>
        item.revisionId === intermediate.revisionId && item.operation === 'update') &&
      newerSiblingPage.targetEvents.some((item) =>
        item.revisionId === newest.revisionId && item.baseRevisionId === intermediate.revisionId),
    'changes-page barriers did not prove ordered intermediate and newer revisions');
    console.log('same-profile stale changes-page serialization verified', JSON.stringify({
      twoTabsSharedPersistentBackend: implementations[0].backend,
      independentWriterDevice: true,
      siblingChangesRequestsBlockedUntilMainR1Held: siblingBlockedChangesRequests,
      intermediatePageHeldAfterFetch: true,
      siblingTabAppliedNewerRevisionBeforeRelease: true,
      siblingChangesRequestsAfterRelease: siblingAllowedChangesRequests,
      olderResponseReleasedLast: true,
      vaultChangesApiBlockedDuringReload: blockedOwnerChangesReads,
      apiOfflineReloadKeptNewestHostRevision: true,
      reloadUnlockAction,
      intermediateHeadWasNotRestored: true,
      stalePageRequestSequence: olderPageSummary.requestCursorSequence,
      intermediateCommitSequence: intermediate.commitSeq,
      newestCommitSequence: newest.commitSeq,
      siblingPageRequestSequence: newerSiblingPage.requestCursorSequence,
      siblingPageNextSequence: newerSiblingPage.nextCursorSequence,
      durableCheckpointAfterSiblingSequence: siblingCheckpoint.cursorSequence,
      durableCheckpointAfterLatePageSequence: delayedPageCheckpoint.cursorSequence,
      durableCheckpointDidNotRegress: true,
    }));
  } finally {
    ownerPage.off('requestfailed', observeOwnerChangesFailure);
    releaseOlderPage();
    await ownerPage.unroute(changesPattern, holdIntermediatePage).catch(() => {});
    await ownerTabPage.unroute(changesPattern, recordSiblingPages).catch(() => {});
    ownerPage.off('request', observeOwnerChangesRequest);
  }
}

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')), 'missing compiled Web release; build apps/client for Web first');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')), 'missing compiled main.dart.js');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'drift_worker.js')), 'missing compiled drift_worker.js');
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'sqlite3.wasm')), 'missing compiled sqlite3.wasm');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST]);
  assertThat(fs.existsSync(SERVER_BINARY), `server binary missing at ${SERVER_BINARY}`);

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-it-'));
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const serverLog = fs.openSync(path.join(tempRoot, 'server.log'), 'a');
  const port = await unusedPort();
  const shortcutSshAddress = VAULT_PREFERENCE_ONLY ? localEth0Address() : null;
  assertThat(!VAULT_PREFERENCE_ONLY || shortcutSshAddress,
    'Vault preference acceptance requires an assigned private eth0 address for its isolated SSH fixture');
  const shortcutSshPort = VAULT_PREFERENCE_ONLY
    ? await unusedPort(shortcutSshAddress)
    : null;
  const shortcutSshUsername = VAULT_PREFERENCE_ONLY
    ? `atermius-ws-${crypto.randomBytes(8).toString('hex')}`
    : null;
  const shortcutSshPassword = VAULT_PREFERENCE_ONLY
    ? crypto.randomBytes(32).toString('base64url')
    : null;
  const baseUrl = `http://127.0.0.1:${port}`;
  const databaseUrl = `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: databaseUrl,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: VAULT_PREFERENCE_ONLY ? 'true' : 'false',
    ...(VAULT_PREFERENCE_ONLY ? {
      ATERMIUS_RELAY_ALLOW_CIDRS: `${shortcutSshAddress}/32`,
      ATERMIUS_RELAY_ALLOW_PORTS: String(shortcutSshPort),
    } : {}),
    // The browser test ages only its disposable Vault's change_events before
    // invoking the production maintenance command. One day is the minimum
    // supported retention, keeping the fixture out of production defaults.
    ATERMIUS_HISTORY_RETENTION_DAYS: '1',
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };
  let serverProcess;
  let browser;
  let bootstrapToken;
  let archivePassword;
  let archivePath;
  let shortcutSshFixture;
  let ownerContext;
  let secondContext;
  let ownerTabPage;
  const pageErrors = [];
  const browserDiagnostics = [];
  const responseDiagnostics = [];
  const cspViolations = [];
  const apiDiagnostics = [];
  const deviceRevocationRequests = [];
  const deviceSnapshots = { A: [], B: [] };
  const apiRequestStartedAt = new WeakMap();
  const notificationEvents = [];
  const multiVaultCapture = {
    active: false,
    vaultA: null,
    pushes: [],
    changesRequests: [],
    conflictRequests: [],
    relayTickets: 0,
    relayWebSockets: 0,
  };
  const missedHintWire = {
    active: false,
    dropMembershipSetHint: false,
    droppedMembershipSetHintCount: 0,
    deliveredCommitHints: [],
    siblingReadyFrames: 0,
    recoveryReadyFrames: 0,
    targetVaultId: null,
  };
  const targetHostRecordIds = new Set();
  const ownerHostRecordIds = new Set();
  const observedConflictIds = { A: new Set(), B: new Set() };
  const observedConflictFeedEvents = { A: [], B: [] };
  let captureTargetHostPush = false;
  let captureOwnerHostPush = false;
  const outboxRecovery = {
    mode: 'off',
    first: null,
    reconciledEvent: null,
    failureCategory: null,
  };
  const crossAttachment = {
    active: false,
    vaultId: null,
    objectId: null,
    recordId: null,
    revisionId: null,
    ownerEnvelopeSha256: null,
    ownerObjectRefs: [],
    recipientManifest: null,
  };
  const credentialSyncCapture = {
    active: false,
    markers: [],
    recordIds: new Set(),
    pushAttempts: [],
    pulls: [],
    serverGenerations: new Map(),
  };
  const credentialConflictCapture = {
    active: false,
    markers: [],
    recordId: null,
    pushes: [],
    pushResponses: [],
    branchUploads: [],
    conflictFeedEvents: [],
    resolutionRequests: [],
    resolutionResponses: [],
    httpRequestChecks: [],
    httpResponseChecks: [],
    browserLogChecks: [],
  };
  const credentialSyncRouteDiagnostics = new Map();
  const vaultPreferenceSyncCapture = {
    active: false,
    retainedRecordId: null,
    pushes: [],
    pulls: [],
  };
  const preferenceLostAck = {
    mode: 'off',
    targetOpId: null,
    first: null,
    failureCategory: null,
    heldRetryCount: 0,
    isolatedOfflineBeforeAck: false,
  };
  const snippetSyncCapture = {
    active: false,
    markers: [],
    pushes: [],
    pulls: [],
    relayTicketRequestCount: 0,
  };
  const groupSyncCapture = {
    active: false,
    markers: [],
    pushes: [],
    pulls: [],
  };
  let ownerPulledTargetHostRecord = false;
  let ownerPreDeletionAccessToken;
  let accountCancelRequestObserved = false;
  let accountCancelAuthorizationPresent = false;
  const archiveChangesReadsAbortedAt = [];
  const observedAuthDeviceIds = new WeakMap();
  const multiTab = {
    active: false,
    pushAttempts: [],
    databaseImplementations: new WeakMap(),
  };
  const longOffline = {
    active: false,
    captureHostCreate: false,
    captureHeadUpdate: false,
    vaultId: null,
    recordId: null,
    initialRevisionId: null,
    initialCommit: null,
    currentHeadUpdate: null,
    conflictId: null,
    bChangesCursorPresent: false,
    expiredPullHadCursor: false,
    expiredChangesResponses: 0,
    snapshotCreateResponses: 0,
    snapshotHeadObserved: null,
    branchUploads: [],
    branchUploadResponses: [],
    branchPushAttempts: [],
  };

  try {
    if (VAULT_PREFERENCE_ONLY) {
      shortcutSshFixture = await startSshFixture({
        bindAddress: shortcutSshAddress,
        ports: [shortcutSshPort],
        username: shortcutSshUsername,
        password: shortcutSshPassword,
      });
      assertThat(shortcutSshFixture.servers.length === 1 &&
        shortcutSshFixture.servers[0].address === shortcutSshAddress &&
        shortcutSshFixture.servers[0].port === shortcutSshPort,
      'Vault preference SSH fixture did not start on its reserved private endpoint');
    }
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      stdio: ['ignore', serverLog, serverLog],
    });
    await waitReady(baseUrl, serverProcess);
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
    });
    assertThat(bootstrap.status === 0, `temporary server bootstrap failed (${bootstrap.status})`);
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(bootstrapToken && bootstrapToken.length >= 40, 'temporary server did not issue a bootstrap token');

    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    ownerContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    });
    secondContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    });
    if (MISSED_MEMBERSHIP_HINT_ONLY) {
      await secondContext.routeWebSocket('**/api/v1/notifications', (webSocket) => {
        const serverSocket = webSocket.connectToServer();
        webSocket.onMessage((message) => serverSocket.send(message));
        serverSocket.onMessage((message) => {
          const frame = parseNotificationFrame(message);
          if (frame?.type === 'ready') missedHintWire.siblingReadyFrames++;
          webSocket.send(message);
        });
      });
    }
    await Promise.all([ownerContext, secondContext].map((context) =>
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl })));
    await Promise.all([installFlutterLoaderProbe(ownerContext), installFlutterLoaderProbe(secondContext)]);
    await ownerContext.addInitScript(() => {
      const probe = {
        downloadAnchorClicks: 0,
        blobDownloadAnchorClicks: 0,
        otherDownloadAnchorClicks: 0,
      };
      Object.defineProperty(window, '__e2eDownloadProbe', { value: probe });
      const originalClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function (...args) {
        if (this.download) {
          probe.downloadAnchorClicks++;
          if (this.href.startsWith('blob:')) probe.blobDownloadAnchorClicks++;
          else probe.otherDownloadAnchorClicks++;
        }
        return Reflect.apply(originalClick, this, args);
      };
    });
    const ownerPage = await ownerContext.newPage();
    ownerTabPage = await ownerContext.newPage();
    const secondPage = await secondContext.newPage();
    const profileForPage = (page) => page === secondPage ? 'B' : 'A';
    const pageRoleForPage = (page) => page === ownerPage
      ? 'owner-main' : page === ownerTabPage ? 'owner-tab' : 'second';
    for (const page of [ownerPage, ownerTabPage, secondPage]) {
    const profile = profileForPage(page);
    const pageRole = pageRoleForPage(page);
    page.on('pageerror', (error) => pageErrors.push({
      profile,
      kind: 'page-error',
      category: pageErrorCategory(error),
    }));
    page.on('pageerror', (error) => {
      if (!credentialConflictCapture.active) return;
      const text = String(error?.message || error || '');
      credentialConflictCapture.browserLogChecks.push({
        profile,
        source: 'page-error',
        markersAbsent: credentialConflictCapture.markers.every((marker) =>
          !text.includes(marker)),
      });
    });
      page.on('requestfailed', (request) => {
        const failure = request.failure()?.errorText || '';
        const path = new URL(request.url()).pathname
          .replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi, '/{id}');
        if (/CSP/i.test(failure)) cspViolations.push(`${profile}: blocked request`);
        browserDiagnostics.push({
          profile,
          kind: 'request-failed',
          method: request.method(),
          path,
          requestAtMs: apiRequestStartedAt.get(request) ?? null,
          atMs: Date.now(),
          failureCategory: /ERR_INTERNET_DISCONNECTED/i.test(failure)
            ? 'offline'
            : /ERR_NETWORK_CHANGED/i.test(failure)
            ? 'network-changed'
            : /ERR_ABORTED/i.test(failure)
            ? 'aborted'
            : /ERR_CONNECTION_REFUSED/i.test(failure)
            ? 'connection-refused'
            : failure
            ? 'other-network-error'
            : 'unknown',
        });
      });
      page.on('websocket', (websocket) => {
        const websocketPath = new URL(websocket.url()).pathname;
        if (multiVaultCapture.active && /relay/i.test(websocketPath)) {
          multiVaultCapture.relayWebSockets++;
        }
        if (websocketPath !== '/api/v1/notifications') return;
        notificationEvents.push({ profile, direction: 'connection', type: 'open' });
        websocket.on('framesent', ({ payload }) => {
          notificationEvents.push(safeNotificationFrame(payload, profile, 'sent'));
        });
        websocket.on('framereceived', ({ payload }) => {
          notificationEvents.push({
            ...safeNotificationFrame(payload, profile, 'received'),
            receivedAtMs: Date.now(),
          });
        });
        websocket.on('close', () => {
          notificationEvents.push({ profile, direction: 'connection', type: 'closed' });
        });
      });
      page.on('request', (request) => {
        const url = new URL(request.url());
        if (multiVaultCapture.active && url.pathname.startsWith('/api/v1/vaults/')) {
          const vaultMatch = url.pathname.match(/^\/api\/v1\/vaults\/([0-9a-f-]+)/i);
          const vaultId = vaultMatch?.[1] || null;
          if (request.method() === 'GET' && url.pathname.endsWith('/changes')) {
            multiVaultCapture.changesRequests.push({ profile, pageRole, vaultId });
          }
          if (url.pathname.endsWith('/sync/push')) {
            try {
              const body = request.postDataJSON();
              multiVaultCapture.pushes.push({
                profile,
                pageRole,
                pathVaultId: vaultId,
                bodyVaultId: body?.vault_id || null,
                vaultId: body?.vault_id || vaultId,
                recordIds: (Array.isArray(body?.operations) ? body.operations : [])
                  .map((item) => item?.header?.record_id)
                  .filter((item) => typeof item === 'string'),
              });
            } catch (_) {}
          }
          if (/\/conflicts(?:\/|$)/.test(url.pathname)) {
            multiVaultCapture.conflictRequests.push({ profile, pageRole, vaultId });
          }
        }
        if (multiVaultCapture.active &&
            request.method() === 'POST' && url.pathname === '/api/v1/relay/tickets') {
          multiVaultCapture.relayTickets++;
        }
        if (credentialConflictCapture.active &&
            url.pathname.startsWith('/api/')) {
          const body = request.postData() || '';
          const markersAbsent = credentialConflictCapture.markers.every((marker) =>
            !body.includes(marker));
          credentialConflictCapture.httpRequestChecks.push({
            profile,
            method: request.method(),
            path: url.pathname,
            markersAbsent,
          });
          if (/\/conflicts\/[0-9a-f-]+\/resolve$/i.test(url.pathname)) {
            credentialConflictCapture.resolutionRequests.push({
              profile,
              method: request.method(),
              path: url.pathname,
              markersAbsent,
            });
          }
        }
        if (/^\/api\/v1\/devices\/[0-9a-f-]+\/revoke$/i.test(url.pathname)) {
          deviceRevocationRequests.push({ profile, method: request.method() });
        }
        if (snippetSyncCapture.active && request.method() === 'POST' &&
            url.pathname === '/api/v1/relay/tickets') {
          snippetSyncCapture.relayTicketRequestCount++;
        }
        if (url.pathname.startsWith('/api/')) {
          apiRequestStartedAt.set(request, Date.now());
        }
        if (url.pathname === '/api/v1/auth/register' ||
            url.pathname === '/api/v1/auth/login') {
          try {
            const body = request.postDataJSON();
            const deviceId = body?.device_id || body?.device?.device_id;
            if (typeof deviceId === 'string') {
              observedAuthDeviceIds.set(page, deviceId);
            }
          } catch (_) {}
        }
        if (multiTab.active && profile === 'A' &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            const summary = syncOperationSummary(body);
            multiTab.pushAttempts.push({
              tab: page === ownerPage ? 'owner-main' : 'owner-second-tab',
              vaultId: body?.vault_id,
              deviceId: body?.device_id,
              batchId: body?.batch_id,
              operations: summary.operations ||
                (summary.opId ? [summary] : []),
            });
          } catch (_) {}
        }
        if (page === ownerPage && url.pathname === '/api/v1/account/delete') {
          const authorization = request.headers().authorization || '';
          ownerPreDeletionAccessToken = authorization.startsWith('Bearer ')
            ? authorization.slice('Bearer '.length)
            : undefined;
        }
        if (page === ownerPage && url.pathname === '/api/v1/account/delete/cancel') {
          accountCancelRequestObserved = true;
          accountCancelAuthorizationPresent = Boolean(request.headers().authorization);
        }
        if (page === secondPage && captureTargetHostPush &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const requestBody = request.postDataJSON();
            for (const operation of requestBody?.operations || []) {
              const recordId = operation?.header?.record_id;
              if (typeof recordId === 'string') targetHostRecordIds.add(recordId);
            }
          } catch (_) {}
        }
        if (page === ownerPage && captureOwnerHostPush &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const requestBody = request.postDataJSON();
            for (const operation of requestBody?.operations || []) {
              const recordId = operation?.header?.record_id;
              if (typeof recordId === 'string') ownerHostRecordIds.add(recordId);
            }
          } catch (_) {}
        }
        if (credentialSyncCapture.active && profile === 'A' &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const requestBody = request.postDataJSON();
            const bodyKeys = Object.keys(requestBody || {}).sort();
            const serialized = JSON.stringify(requestBody);
            const expectedBodyKeys = [
              'batch_id', 'device_id', 'operations', 'protocol_version',
              'server_generation', 'vault_id',
            ];
            const requestBodyShapeValid =
              JSON.stringify(bodyKeys) === JSON.stringify(expectedBodyKeys);
            const requestBodyPlaintextMarkersAbsent =
              credentialSyncCapture.markers.every((marker) =>
                !serialized.includes(marker));
            for (const envelope of requestBody?.operations || []) {
              const summary = safeCredentialEnvelopeSummary(
                envelope,
                credentialSyncCapture.markers,
              );
              if (typeof summary.recordId === 'string') {
                credentialSyncCapture.recordIds.add(summary.recordId);
              }
              credentialSyncCapture.pushAttempts.push({
                profile,
                vaultId: requestBody.vault_id,
                deviceId: requestBody.device_id,
                batchId: requestBody.batch_id,
                requestBodyShapeValid,
                requestBodyPlaintextMarkersAbsent,
                ...summary,
              });
            }
          } catch (_) {}
        }
        if (credentialConflictCapture.active && request.method() === 'POST' &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            const serialized = stableJson(body);
            for (const envelope of body?.operations || []) {
              const header = envelope?.header || {};
              if (credentialConflictCapture.recordId &&
                  header.record_id !== credentialConflictCapture.recordId) continue;
              const summary = safeCredentialEnvelopeSummary(
                envelope,
                credentialConflictCapture.markers,
              );
              if (!credentialConflictCapture.recordId &&
                  typeof summary.recordId === 'string') {
                credentialConflictCapture.recordId = summary.recordId;
              }
              credentialConflictCapture.pushes.push({
                profile,
                requestBodyPlaintextMarkersAbsent:
                  credentialConflictCapture.markers.every((marker) =>
                    !serialized.includes(marker)),
                baseRevisionId: header.base_revision_id ?? null,
                ...summary,
              });
            }
          } catch (_) {}
        }
        if (vaultPreferenceSyncCapture.active &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            const serialized = stableJson(body);
            const bodyKeys = Object.keys(body || {}).sort();
            const expectedBodyKeys = [
              'batch_id', 'device_id', 'operations', 'protocol_version',
              'server_generation', 'vault_id',
            ];
            const operations = Array.isArray(body?.operations)
              ? body.operations
              : [];
            vaultPreferenceSyncCapture.pushes.push({
              profile,
              vaultId: body?.vault_id,
              bodyShapeValid: JSON.stringify(bodyKeys) ===
                JSON.stringify(expectedBodyKeys),
              plaintextMarkersAbsent:
                VAULT_PREFERENCE_PLAINTEXT_MARKERS.every((marker) =>
                  !serialized.includes(marker)),
              operations: operations.map((envelope) => ({
                ...syncOperationSummary({ operations: [envelope] }),
                baseRevisionId: envelope?.header?.base_revision_id ?? null,
                retainedRecordIdAbsent:
                  vaultPreferenceSyncCapture.retainedRecordId == null ||
                  !stableJson(envelope).includes(
                    vaultPreferenceSyncCapture.retainedRecordId,
                  ),
                ...safeCredentialEnvelopeSummary(
                  envelope,
                  VAULT_PREFERENCE_PLAINTEXT_MARKERS,
                ),
              })),
            });
          } catch (_) {}
        }
        if (snippetSyncCapture.active && profile === 'A' &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            const serialized = stableJson(body);
            const bodyKeys = Object.keys(body || {}).sort();
            const expectedBodyKeys = [
              'batch_id', 'device_id', 'operations', 'protocol_version',
              'server_generation', 'vault_id',
            ];
            snippetSyncCapture.pushes.push({
              vaultId: body?.vault_id,
              bodyShapeValid: JSON.stringify(bodyKeys) ===
                JSON.stringify(expectedBodyKeys),
              plaintextMarkersAbsent: snippetSyncCapture.markers.every((marker) =>
                !serialized.includes(marker)),
              operations: (Array.isArray(body?.operations) ? body.operations : [])
                .map((envelope) => ({
                  ...safeCredentialEnvelopeSummary(
                    envelope,
                    snippetSyncCapture.markers,
                  ),
                })),
            });
          } catch (_) {}
        }
        if (groupSyncCapture.active &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            const serialized = stableJson(body);
            const bodyKeys = Object.keys(body || {}).sort();
            const expectedBodyKeys = [
              'batch_id', 'device_id', 'operations', 'protocol_version',
              'server_generation', 'vault_id',
            ];
            groupSyncCapture.pushes.push({
              profile,
              vaultId: body?.vault_id,
              deviceId: body?.device_id,
              bodyShapeValid: JSON.stringify(bodyKeys) ===
                JSON.stringify(expectedBodyKeys),
              plaintextMarkersAbsent: groupSyncCapture.markers.every((marker) =>
                !serialized.includes(marker)),
              operations: (Array.isArray(body?.operations) ? body.operations : [])
                .map((envelope) => ({
                  ...safeCredentialEnvelopeSummary(
                    envelope,
                    groupSyncCapture.markers,
                  ),
                  baseRevisionId: envelope?.header?.base_revision_id ?? null,
                })),
            });
          } catch (_) {}
        }
        if (longOffline.active && profile === 'B' &&
            request.method() === 'GET' && url.pathname.endsWith('/changes')) {
          longOffline.bChangesCursorPresent ||= url.searchParams.has('cursor');
        }
        if (longOffline.active && request.method() === 'POST' &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const body = request.postDataJSON();
            for (const envelope of body?.operations || []) {
              const header = envelope?.header || {};
              if (page === ownerPage && longOffline.captureHostCreate &&
                  header.operation === 'create' &&
                  typeof header.record_id === 'string' &&
                  typeof header.revision_id === 'string') {
                const summary = syncOperationSummary({ operations: [envelope] });
                longOffline.vaultId = body?.vault_id || null;
                longOffline.recordId = header.record_id;
                longOffline.initialRevisionId = header.revision_id;
                longOffline.initialCommit = {
                  ...summary,
                  baseRevisionId: header.base_revision_id ?? null,
                  deviceId: header.device_id,
                  operation: header.operation,
                };
                longOffline.captureHostCreate = false;
              } else if (page === ownerPage && longOffline.captureHeadUpdate &&
                  header.record_id === longOffline.recordId &&
                  header.operation === 'update' &&
                  typeof header.revision_id === 'string') {
                const summary = syncOperationSummary({ operations: [envelope] });
                longOffline.currentHeadUpdate = {
                  ...summary,
                  baseRevisionId: header.base_revision_id ?? null,
                  deviceId: header.device_id,
                  operation: header.operation,
                };
              } else if (page === secondPage &&
                  header.record_id === longOffline.recordId) {
                const summary = syncOperationSummary({ operations: [envelope] });
                longOffline.branchPushAttempts.push({
                  ...summary,
                  baseRevisionId: header.base_revision_id ?? null,
                });
              }
            }
          } catch (_) {}
        }
        if (longOffline.active && page === secondPage &&
            request.method() === 'POST' && url.pathname.endsWith('/conflicts')) {
          try {
            const body = request.postDataJSON();
            const envelope = body?.envelope;
            const header = envelope?.header || {};
            if (header.record_id === longOffline.recordId) {
              const summary = syncOperationSummary({ operations: [envelope] });
              longOffline.branchUploads.push({
                ...summary,
                baseRevisionId: header.base_revision_id ?? null,
                deviceId: header.device_id,
                operation: header.operation,
              });
            }
          } catch (_) {}
        }
        if (credentialConflictCapture.active && request.method() === 'POST' &&
            url.pathname.endsWith('/conflicts')) {
          try {
            const body = request.postDataJSON();
            const envelope = body?.envelope;
            const header = envelope?.header || {};
            if (!credentialConflictCapture.recordId ||
                header.record_id === credentialConflictCapture.recordId) {
              const serialized = stableJson(body);
              credentialConflictCapture.branchUploads.push({
                profile,
                requestBodyPlaintextMarkersAbsent:
                  credentialConflictCapture.markers.every((marker) =>
                    !serialized.includes(marker)),
                baseRevisionId: header.base_revision_id ?? null,
                ...safeCredentialEnvelopeSummary(
                  envelope,
                  credentialConflictCapture.markers,
                ),
              });
            }
          } catch (_) {}
        }
        if (page === ownerPage && crossAttachment.active &&
            request.method() === 'POST' && url.pathname.endsWith('/uploads/init')) {
          try {
            const requestBody = request.postDataJSON();
            if (typeof requestBody?.object_id === 'string' &&
                /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestBody.object_id)) {
              crossAttachment.objectId = requestBody.object_id;
            }
          } catch (_) {}
        }
        if (page === ownerPage && crossAttachment.active &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const requestBody = request.postDataJSON();
            for (const operation of requestBody?.operations || []) {
              const header = operation?.header;
              const refs = header?.object_refs;
              if (typeof header?.record_id === 'string' &&
                  typeof header?.revision_id === 'string' &&
                  Array.isArray(refs) && refs.includes(crossAttachment.objectId)) {
                crossAttachment.vaultId = requestBody.vault_id;
                crossAttachment.recordId = header.record_id;
                crossAttachment.revisionId = header.revision_id;
                crossAttachment.ownerEnvelopeSha256 = syncOperationSummary({
                  operations: [operation],
                }).envelopeSha256;
                crossAttachment.ownerObjectRefs = refs.slice();
              }
            }
          } catch (_) {}
        }
      });
      page.on('console', (message) => {
        const consoleText = message.text();
        if (credentialConflictCapture.active) {
          credentialConflictCapture.browserLogChecks.push({
            profile,
            source: 'console',
            markersAbsent: credentialConflictCapture.markers.every((marker) =>
              !consoleText.includes(marker)),
          });
        }
        const implementationPrefix = 'ATERMIUS_DRIFT_WEB_IMPLEMENTATION=';
        if (consoleText.startsWith(implementationPrefix)) {
          multiTab.databaseImplementations.set(
            page,
            consoleText.slice(implementationPrefix.length).trim(),
          );
        }
        if (message.type() === 'error') {
          if (/content security policy|blocked by csp|refused to (load|execute|connect)/i.test(consoleText)) {
            cspViolations.push(`${profile}: console CSP violation`);
          }
          browserDiagnostics.push({ profile, kind: 'console-error' });
        }
      });
      page.on('response', async (response) => {
        const url = response.url();
        if (new URL(url).pathname.startsWith('/api/')) {
          const responsePath = new URL(url).pathname;
          if (credentialConflictCapture.active) {
            const body = await response.body().catch(() => null);
            const bodyText = body?.toString('utf8') ?? '';
            const markersAbsent = body !== null &&
              credentialConflictCapture.markers.every((marker) =>
                !bodyText.includes(marker));
            credentialConflictCapture.httpResponseChecks.push({
              profile,
              method: response.request().method(),
              path: responsePath,
              status: response.status(),
              bodyReadable: body !== null,
              markersAbsent,
            });
            if (/\/conflicts\/[0-9a-f-]+\/resolve$/i.test(responsePath)) {
              credentialConflictCapture.resolutionResponses.push({
                profile,
                method: response.request().method(),
                path: responsePath,
                status: response.status(),
                bodyReadable: body !== null,
                markersAbsent,
              });
            }
          }
          const entry = {
            profile,
            method: response.request().method(),
            path: responsePath,
            status: response.status(),
            authorizationPresent: Boolean(
              response.request().headers().authorization?.startsWith('Bearer '),
            ),
            requestAtMs: apiRequestStartedAt.get(response.request()) ?? Date.now(),
            atMs: Date.now(),
          };
          if (credentialConflictCapture.active && entry.method === 'POST' &&
              responsePath.endsWith('/sync/push')) {
            try {
              const requestBody = response.request().postDataJSON();
              const serialized = stableJson(requestBody);
              for (const envelope of requestBody?.operations || []) {
                const header = envelope?.header || {};
                if (credentialConflictCapture.recordId &&
                    header.record_id !== credentialConflictCapture.recordId) continue;
                credentialConflictCapture.pushResponses.push({
                  profile,
                  status: response.status(),
                  requestBodyPlaintextMarkersAbsent:
                    credentialConflictCapture.markers.every((marker) =>
                      !serialized.includes(marker)),
                  baseRevisionId: header.base_revision_id ?? null,
                  ...safeCredentialEnvelopeSummary(
                    envelope,
                    credentialConflictCapture.markers,
                  ),
                });
              }
            } catch (_) {
              credentialConflictCapture.pushResponses.push({
                profile,
                status: response.status(),
                parseFailed: true,
              });
            }
          }
          if (response.status() >= 400) {
            try {
              const body = await response.json();
              entry.errorCode = body?.error?.code || body?.code || 'unknown';
            } catch (_) { entry.errorCode = 'non-json'; }
            if (longOffline.active && profile === 'B' &&
                response.request().method() === 'GET' &&
                entry.path.endsWith('/changes') && response.status() === 410 &&
                entry.errorCode === 'CURSOR_EXPIRED') {
              longOffline.expiredChangesResponses++;
              longOffline.expiredPullHadCursor ||=
                new URL(url).searchParams.has('cursor');
            }
          } else if (response.request().method() === 'POST' &&
              new URL(url).pathname.endsWith('/sync/push')) {
            try {
              const body = await response.json();
              const results = Array.isArray(body?.results) ? body.results : [];
              entry.pushReceiptSummary = {
                batchIdPresent: typeof body?.batch_id === 'string',
                resultCount: results.length,
                results: results.map((item) => ({
                  opId: typeof item?.op_id === 'string' ? item.op_id : null,
                  revisionId: typeof item?.revision_id === 'string'
                    ? item.revision_id
                    : null,
                  commitSeq: typeof item?.commit_seq === 'string' &&
                    /^(0|[1-9][0-9]*)$/.test(item.commit_seq)
                    ? item.commit_seq
                    : null,
                  alreadyCommitted: item?.already_committed === true,
                })),
              };
            } catch (_) {
              entry.pushReceiptSummary = { parseFailed: true };
            }
          } else if (new URL(url).pathname.endsWith('/changes')) {
            // Inspect opaque record IDs only in memory to prove the authorized
            // pull contains the push from the other profile. Never log envelopes.
            const expectedRecordIds = profile === 'A'
              ? targetHostRecordIds
              : ownerHostRecordIds;
            try {
              const body = await response.json();
              if (typeof body?.server_generation === 'string' &&
                  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.server_generation)) {
                credentialSyncCapture.serverGenerations.set(profile,
                  body.server_generation);
              }
              {
                const cursor = new URL(url).searchParams.get('cursor');
                let requestCursor = null;
                if (cursor !== null) {
                  try {
                    const decoded = Buffer.from(cursor, 'base64url');
                    const payload = decoded.subarray(0, decoded.length - 32);
                    const value = JSON.parse(payload.toString('utf8'));
                    if (value?.v === 1 && typeof value.generation === 'string' &&
                        typeof value.seq === 'number' &&
                        Number.isSafeInteger(value.seq) && value.seq >= 0) {
                      requestCursor = {
                        generation: value.generation,
                        sequence: String(value.seq),
                      };
                    }
                  } catch (_) {}
                }
                entry.changesPageSummary = {
                  eventCount: Array.isArray(body?.events) ? body.events.length : null,
                  hasMore: typeof body?.has_more === 'boolean' ? body.has_more : null,
                  serverGeneration: typeof body?.server_generation === 'string'
                    ? body.server_generation
                    : null,
                  requestCursorPresent: cursor !== null,
                  requestCursorLength: cursor === null ? 0 : cursor.length,
                  requestCursorGeneration: requestCursor?.generation ?? null,
                  requestCursorSequence: requestCursor?.sequence ?? null,
                  nextCursorPresent: typeof body?.next_cursor === 'string',
                  nextCursorLength: typeof body?.next_cursor === 'string'
                    ? body.next_cursor.length
                    : 0,
                };
                try {
                  const encoded = body?.next_cursor;
                  if (typeof encoded === 'string') {
                    const decoded = Buffer.from(encoded, 'base64url');
                    const payload = decoded.subarray(0, decoded.length - 32);
                    const value = JSON.parse(payload.toString('utf8'));
                    if (value?.v === 1 && typeof value.seq === 'number' &&
                        Number.isSafeInteger(value.seq) && value.seq >= 0) {
                      entry.changesPageSummary.nextCursorSequence = String(value.seq);
                    }
                  }
                } catch (_) {}
                entry.changesPageEvents = credentialConflictCapture.active &&
                  profile === 'B'
                  ? (Array.isArray(body?.events) ? body.events : [])
                  .map((event) => {
                    const header = event?.envelope?.header || {};
                    const commitSeq = event?.commit_seq;
                    return {
                      recordId: typeof header.record_id === 'string' &&
                        /^[0-9a-f-]{36}$/i.test(header.record_id)
                        ? header.record_id : null,
                      revisionId: typeof header.revision_id === 'string' &&
                        /^[0-9a-f-]{36}$/i.test(header.revision_id)
                        ? header.revision_id : null,
                      operation: typeof header.operation === 'string'
                        ? header.operation : null,
                      commitSeq: typeof commitSeq === 'string' &&
                        /^(0|[1-9][0-9]*)$/.test(commitSeq)
                        ? commitSeq : null,
                    };
                  })
                  : [];
                const bChangesRouteState = credentialSyncRouteDiagnostics
                  .get(secondContext)?.changes;
                if (credentialConflictCapture.active && profile === 'B' &&
                    bChangesRouteState?.releaseCompleted &&
                    bChangesRouteState.firstResponseAfterRelease === null) {
                  bChangesRouteState.firstResponseAfterRelease = {
                    status: response.status(),
                    requestSequence:
                      entry.changesPageSummary.requestCursorSequence ?? null,
                    nextSequence:
                      entry.changesPageSummary.nextCursorSequence ?? null,
                    eventCount: entry.changesPageSummary.eventCount,
                    hasMore: entry.changesPageSummary.hasMore,
                    eventOperations: entry.changesPageEvents.map((event) =>
                      event.operation),
                    eventCommitSequences: entry.changesPageEvents.map((event) =>
                      event.commitSeq),
                    hasExpectedRecord: entry.changesPageEvents.some((event) =>
                      event.recordId === bChangesRouteState.expectedRecordId),
                    hasExpectedRevision: entry.changesPageEvents.some((event) =>
                      event.revisionId === bChangesRouteState.expectedRemoteRevisionId),
                    hasExpectedRecordAndRevision: entry.changesPageEvents.some((event) =>
                      event.recordId === bChangesRouteState.expectedRecordId &&
                      event.revisionId === bChangesRouteState.expectedRemoteRevisionId),
                    syntheticRouteInvocationsAfterRelease:
                      bChangesRouteState.syntheticInvocationsAfterRelease,
                  };
                }
              }
              if (snippetSyncCapture.active && profile === 'B') {
                const serialized = stableJson(body);
                const responsePlaintextMarkersAbsent =
                  snippetSyncCapture.markers.every((marker) =>
                    !serialized.includes(marker));
                const pushedOperations = snippetSyncCapture.pushes
                  .flatMap((push) => push.operations);
                for (const event of body?.events || []) {
                  const envelope = event?.envelope;
                  const operation = safeCredentialEnvelopeSummary(
                    envelope,
                    snippetSyncCapture.markers,
                  );
                  if (!pushedOperations.some((item) =>
                    item.opId === operation.opId &&
                    item.recordId === operation.recordId &&
                    item.revisionId === operation.revisionId)) continue;
                  snippetSyncCapture.pulls.push({
                    responsePlaintextMarkersAbsent,
                    commitSeq: String(event?.commit_seq),
                    ...operation,
                  });
                }
              }
              if (vaultPreferenceSyncCapture.active &&
                  (profile === 'A' || profile === 'B')) {
                const serialized = stableJson(body);
                const plaintextMarkersAbsent =
                  VAULT_PREFERENCE_PLAINTEXT_MARKERS.every((marker) =>
                    !serialized.includes(marker));
                for (const event of body?.events || []) {
                  const envelope = event?.envelope;
                  const recordId = envelope?.header?.record_id;
                  const operation = safeCredentialEnvelopeSummary(
                    envelope,
                    VAULT_PREFERENCE_PLAINTEXT_MARKERS,
                  );
                  const pushedOperations = vaultPreferenceSyncCapture.pushes
                    .flatMap((push) => push.operations.map((item) => ({
                      ...item,
                      profile: push.profile,
                    })));
                  const pushedOperation = pushedOperations.find((item) =>
                    item.recordId === operation.recordId &&
                    item.revisionId === operation.revisionId &&
                    item.opId === operation.opId);
                  if (!pushedOperation) {
                    continue;
                  }
                  vaultPreferenceSyncCapture.pulls.push({
                    profile,
                    originProfile: pushedOperation.profile,
                    responsePlaintextMarkersAbsent: plaintextMarkersAbsent,
                    commitSeq: typeof event?.commit_seq === 'string' &&
                      /^(0|[1-9][0-9]*)$/.test(event.commit_seq)
                      ? event.commit_seq
                      : null,
                    ...operation,
                  });
                }
              }
              if (groupSyncCapture.active) {
                const serialized = stableJson(body);
                const responsePlaintextMarkersAbsent =
                  groupSyncCapture.markers.every((marker) =>
                    !serialized.includes(marker));
                const pushedOperations = groupSyncCapture.pushes
                  .flatMap((push) => push.operations.map((operation) => ({
                    ...operation,
                    profile: push.profile,
                    vaultId: push.vaultId,
                  })));
                for (const event of body?.events || []) {
                  const envelope = event?.envelope;
                  const operation = safeCredentialEnvelopeSummary(
                    envelope,
                    groupSyncCapture.markers,
                  );
                  const origin = pushedOperations.find((item) =>
                    item.opId === operation.opId &&
                    item.revisionId === operation.revisionId &&
                    item.recordId === operation.recordId);
                  if (!origin || origin.profile === profile) continue;
                  groupSyncCapture.pulls.push({
                    profile,
                    originProfile: origin.profile,
                    vaultId: origin.vaultId,
                    responsePlaintextMarkersAbsent,
                    commitSeq: String(event?.commit_seq),
                    ...operation,
                  });
                }
              }
              if (credentialSyncCapture.active && profile === 'B') {
                const serialized = stableJson(body);
                const responsePlaintextMarkersAbsent =
                  credentialSyncCapture.markers.every((marker) =>
                    !serialized.includes(marker));
                for (const event of body?.events || []) {
                  const envelope = event?.envelope;
                  const recordId = envelope?.header?.record_id;
                  if (!credentialSyncCapture.recordIds.has(recordId)) continue;
                  credentialSyncCapture.pulls.push({
                    profile,
                    recordId,
                    commitSeq: String(event?.commit_seq),
                    responsePlaintextMarkersAbsent,
                    ...safeCredentialEnvelopeSummary(
                      envelope,
                      credentialSyncCapture.markers,
                    ),
                  });
                }
              }
              const included = (body?.events || []).some((event) =>
                expectedRecordIds.has(event?.envelope?.header?.record_id));
              if (page === ownerPage && outboxRecovery.first) {
                const targetOpId = outboxRecovery.first.request.opId;
                const event = (body?.events || []).find((item) =>
                  item?.envelope?.header?.op_id === targetOpId);
                if (event) {
                  const summary = syncOperationSummary({
                    operations: [event.envelope],
                  });
                  outboxRecovery.reconciledEvent = {
                    ...summary,
                    commitSeq: String(event.commit_seq),
                  };
                }
              }
              if (page === secondPage && crossAttachment.active &&
                  crossAttachment.recordId) {
                const event = (body?.events || []).find((item) =>
                  item?.envelope?.header?.record_id === crossAttachment.recordId &&
                  item?.envelope?.header?.revision_id === crossAttachment.revisionId);
                if (event) {
                  const summary = syncOperationSummary({
                    operations: [event.envelope],
                  });
                  const refs = event?.envelope?.header?.object_refs;
                  crossAttachment.recipientManifest = {
                    ...summary,
                    commitSeq: String(event.commit_seq),
                    hasObjectRef: Array.isArray(refs) &&
                      refs.includes(crossAttachment.objectId),
                  };
                }
              }
              if (page === ownerPage) {
                entry.includesTargetRecordId = included;
                ownerPulledTargetHostRecord ||= included;
              } else if (page === secondPage) {
                entry.includesOwnerHostRecordId = included;
              }
            } catch (_) {}
          } else if (longOffline.active && profile === 'B' &&
              response.request().method() === 'POST' &&
              /\/api\/v1\/vaults\/[0-9a-f-]+\/snapshots$/.test(new URL(url).pathname)) {
            longOffline.snapshotCreateResponses++;
          } else if (longOffline.active && profile === 'B' &&
              response.request().method() === 'GET' &&
              /\/api\/v1\/snapshots\/[0-9a-f-]+$/.test(new URL(url).pathname)) {
            try {
              const body = await response.json();
              const manifest = Array.isArray(body?.manifest) ? body.manifest : [];
              const head = manifest.find((item) => item?.record_id === longOffline.recordId);
              const header = head?.envelope?.header || {};
              longOffline.snapshotHeadObserved = {
                present: Boolean(head),
                revisionId: header.revision_id || null,
                matchesOwnerHead: header.revision_id === longOffline.currentHeadUpdate?.revisionId,
                snapshotIdMatches: typeof body?.snapshot_id === 'string',
                highWatermarkPresent: typeof body?.high_watermark === 'string',
                manifestHeadCount: manifest.length,
              };
            } catch (_) {}
          } else if (new URL(url).pathname.endsWith('/conflicts') &&
              response.request().method() === 'POST') {
            try {
              const body = await response.json();
              if (typeof body?.conflict_id === 'string') {
                observedConflictIds[profile].add(body.conflict_id);
                entry.createdConflictIdObserved = true;
                if (longOffline.active && profile === 'B' &&
                    response.request().method() === 'POST') {
                  longOffline.branchUploadResponses.push({
                    conflictId: body.conflict_id,
                    status: response.status(),
                  });
                }
              }
            } catch (_) {}
          } else if (new URL(url).pathname.endsWith('/conflict-changes')) {
            try {
              const body = await response.json();
              const events = Array.isArray(body?.events) ? body.events : [];
              if (credentialConflictCapture.active) {
                const serialized = stableJson(body);
                const responsePlaintextMarkersAbsent =
                  credentialConflictCapture.markers.every((marker) =>
                    !serialized.includes(marker));
                credentialConflictCapture.conflictFeedEvents.push(
                  ...events.filter((event) =>
                    event?.record_id === credentialConflictCapture.recordId)
                    .map((event) => {
                      const hasEnvelope = Object.hasOwn(event || {}, 'envelope');
                      const envelopeSummary = hasEnvelope
                        ? safeCredentialEnvelopeSummary(
                          event.envelope,
                          credentialConflictCapture.markers,
                        )
                        : null;
                      return {
                        profile,
                        seq: event?.seq,
                        type: event?.type,
                        conflictId: event?.conflict_id,
                        recordId: event?.record_id,
                        hasEnvelope,
                        envelopeSummary,
                        resolvedRevisionId: event?.resolved_revision_id ?? null,
                        responsePlaintextMarkersAbsent,
                      };
                    }),
                );
              }
              observedConflictFeedEvents[profile].push(
                ...events.map((event) => ({
                  seq: event?.seq,
                  type: event?.type,
                  conflictId: event?.conflict_id,
                  recordId: event?.record_id,
                  hasEnvelope: Object.hasOwn(event || {}, 'envelope'),
                  resolvedRevisionId: event?.resolved_revision_id ?? null,
                })),
              );
              entry.conflictEventSummaries = events.map((event) => ({
                seq: event?.seq,
                type: event?.type,
                conflictId: event?.conflict_id,
                hasEnvelope: Object.hasOwn(event || {}, 'envelope'),
                resolvedRevisionId: event?.resolved_revision_id ?? null,
              }));
              if (profile === 'B') {
                const requestUrl = new URL(url);
                const decimal = (value) => typeof value === 'string' &&
                  /^(0|[1-9][0-9]*)$/.test(value) ? value : null;
                entry.conflictFeedRequest = {
                  afterSeq: decimal(requestUrl.searchParams.get('after_seq')),
                  hasServerGeneration: requestUrl.searchParams.has('server_generation'),
                };
                entry.conflictFeedResponse = {
                  afterSeq: decimal(body?.after_seq),
                  highWatermark: decimal(body?.high_watermark),
                  nextAfterSeq: decimal(body?.next_after_seq),
                  hasMore: typeof body?.has_more === 'boolean' ? body.has_more : null,
                };
              }
            } catch (_) { entry.conflictEventSummaries = []; }
          } else if (longOffline.active && profile === 'B' &&
              response.request().method() === 'POST' &&
              /\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts\/([0-9a-f-]+)\/resolve$/.test(new URL(url).pathname)) {
            const resolutionPath = new URL(url).pathname;
            const resolutionMatch = resolutionPath.match(
              /\/api\/v1\/vaults\/[0-9a-f-]+\/conflicts\/([0-9a-f-]+)\/resolve$/,
            );
            if (resolutionMatch?.[1] === longOffline.conflictId) {
              try {
                const body = await response.json();
                entry.longOfflineResolutionSummary = {
                  resolved: body?.status === 'resolved',
                  resolutionSeq: typeof body?.resolution_seq === 'string' &&
                    /^(0|[1-9][0-9]*)$/.test(body.resolution_seq)
                    ? body.resolution_seq
                    : null,
                  resolutionSeqIsDecimal: typeof body?.resolution_seq === 'string' &&
                    /^(0|[1-9][0-9]*)$/.test(body.resolution_seq),
                  matchesCurrentHead: body?.resolved_revision_id ===
                    longOffline.currentHeadUpdate?.revisionId,
                  alreadyResolved: body?.already_resolved === true,
                };
              } catch (_) {
                entry.longOfflineResolutionSummary = {
                  resolved: false,
                  resolutionSeq: null,
                  resolutionSeqIsDecimal: false,
                  matchesCurrentHead: false,
                  alreadyResolved: false,
                };
              }
            }
          } else if (new URL(url).pathname === '/api/v1/devices') {
            try {
              const body = await response.json();
              const devices = Array.isArray(body?.devices) ? body.devices : [];
              deviceSnapshots[profile].push({
                requestAtMs: apiRequestStartedAt.get(response.request()) ?? Date.now(),
                responseAtMs: Date.now(),
                devices: devices
                  .filter((device) => typeof device?.device_id === 'string' &&
                    typeof device?.name === 'string' && typeof device?.status === 'string')
                  .map((device) => ({
                    deviceId: device.device_id,
                    name: device.name,
                    status: device.status,
                  })),
              });
            } catch (_) {}
          } else if (new URL(url).pathname.endsWith('/membership')) {
            // Record only the response shape in diagnostics; the body contains
            // signer material and signatures that do not help selector triage.
            try {
              const body = await response.json();
              const first = body?.manifests?.[0];
              entry.responseShape = {
                topLevelKeys: Object.keys(body || {}).sort(),
                manifestCount: Array.isArray(body?.manifests) ? body.manifests.length : null,
                rowKeys: first && typeof first === 'object' ? Object.keys(first).sort() : [],
                wrapperKeys: first?.manifest && typeof first.manifest === 'object'
                  ? Object.keys(first.manifest).sort()
                  : [],
                signedBodyKeys: first?.manifest?.manifest && typeof first.manifest.manifest === 'object'
                  ? Object.keys(first.manifest.manifest).sort()
                  : [],
              };
            } catch (_) { entry.responseShape = null; }
          }
          apiDiagnostics.push(entry);
        }
        const resourcePath = new URL(url).pathname;
        if (resourcePath === '/sodium.js' || resourcePath.endsWith('.wasm') ||
            resourcePath.endsWith('/main.dart.js') || resourcePath.endsWith('/flutter_bootstrap.js') ||
            resourcePath.includes('canvaskit')) {
          const headers = response.headers();
          responseDiagnostics.push({
            profile,
            path: resourcePath,
            sameOrigin: new URL(url).origin === baseUrl,
            status: response.status(),
            contentType: headers['content-type'] || '',
            cacheControl: headers['cache-control'] || '',
            cspHasSelfScript: (headers['content-security-policy'] || '').includes("script-src 'self'"),
          });
        }
      });
    }

    await ownerContext.route('**/api/v1/vaults/*/sync/push', async (route) => {
      const mode = outboxRecovery.mode;
      if (mode === 'off') {
        await route.continue();
        return;
      }
      try {
        const body = route.request().postDataJSON();
        const operation = syncOperationSummary(body);
        if (mode === 'drop-first') {
          if (operation.operationCount !== 1) {
            await route.continue();
            return;
          }
          const upstream = await route.fetch();
          const responseBody = await upstream.json();
          const receipt = Array.isArray(responseBody?.results)
            ? responseBody.results[0]
            : null;
          outboxRecovery.first = {
            request: {
              ...operation,
              batchId: body.batch_id,
              vaultId: body.vault_id,
              deviceId: body.device_id,
            },
            httpStatus: upstream.status(),
            receipt: receipt && {
              opId: receipt.op_id,
              revisionId: receipt.revision_id,
              commitSeq: receipt.commit_seq,
              alreadyCommitted: receipt.already_committed,
            },
          };
          // The real server has committed and returned its receipt. Deliberately
          // lose only the browser-facing response, leaving the local outbox
          // unacknowledged just as it would be after a connection reset.
          outboxRecovery.mode = 'hold';
          await route.abort('failed');
          return;
        }

        const targetOpId = outboxRecovery.first?.request?.opId;
        if (!targetOpId || operation.opId !== targetOpId) {
          await route.continue();
          return;
        }
        if (mode === 'hold') {
          await route.abort('failed');
          return;
        }
        await route.continue();
      } catch (_) {
        outboxRecovery.failureCategory = 'route-or-upstream-error';
        await route.abort('failed').catch(() => {});
      }
    });

    const navigationResponses = await Promise.all([
      ownerPage.goto(baseUrl, { waitUntil: 'domcontentloaded' }),
      secondPage.goto(baseUrl, { waitUntil: 'domcontentloaded' }),
    ]);
    for (const response of navigationResponses) {
      assertThat(response && response.status() === 200, 'browser root navigation did not return HTTP 200');
      const headers = await response.allHeaders();
      const csp = headers['content-security-policy'] || '';
      assertThat(csp.includes("frame-ancestors 'none'") &&
        csp.includes("script-src 'self' 'wasm-unsafe-eval'") &&
        headers['x-content-type-options'] === 'nosniff' &&
        headers['x-frame-options'] === 'DENY' &&
        headers['referrer-policy'] === 'no-referrer' &&
        headers['cache-control'] === 'no-cache',
      'root response security or cache headers did not match the expected policy');
    }
    const startupEvidence = { responseDiagnostics, browserDiagnostics, pageErrors, cspViolations };
    activeStage = 'Flutter startup';
    await Promise.all([
      enableFlutterSemantics(ownerPage, 'A', startupEvidence),
      enableFlutterSemantics(secondPage, 'B', startupEvidence),
    ]);
    await Promise.all([
      button(ownerPage, 'Connect securely'),
      button(secondPage, 'Connect securely'),
    ]);
    console.log('stage: both Flutter pages loaded; sodium and CanvasKit verified');
    const clientCsp = await ownerPage.locator('meta[http-equiv="Content-Security-Policy"]')
      .getAttribute('content');
    assertThat(clientCsp && clientCsp.includes("script-src 'self' 'wasm-unsafe-eval'") &&
      clientCsp.includes("connect-src 'self'"), 'compiled Web index is missing the expected same-origin CSP');
    const staticPolicy = await ownerPage.evaluate(async () => {
      const response = await fetch('/main.dart.js');
      return {
        status: response.status,
        contentType: response.headers.get('content-type') || '',
        cacheControl: response.headers.get('cache-control') || '',
        csp: response.headers.get('content-security-policy') || '',
        byteLength: (await response.arrayBuffer()).byteLength,
      };
    });
    assertThat(staticPolicy.status === 200 &&
      /(?:text|application)\/javascript/i.test(staticPolicy.contentType) &&
      staticPolicy.cacheControl === 'no-cache' && staticPolicy.byteLength > 0 &&
      staticPolicy.csp.includes("frame-ancestors 'none'") &&
      staticPolicy.csp.includes("script-src 'self' 'wasm-unsafe-eval'"),
    `main.dart.js response policy is incorrect: ${JSON.stringify(staticPolicy)}`);
    const networkDeadline = Date.now() + 10000;
    while (Date.now() < networkDeadline &&
        (!responseDiagnostics.some((item) => item.path === '/sodium.js') ||
         !responseDiagnostics.some((item) => item.path.endsWith('.wasm')))) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const sodiumResponses = responseDiagnostics.filter((item) => item.path === '/sodium.js');
    const wasmResponses = responseDiagnostics.filter((item) => item.path.endsWith('.wasm'));
    assertThat(sodiumResponses.length >= 2, `sodium.js response missing: ${JSON.stringify(responseDiagnostics)}`);
    assertThat(sodiumResponses.every((item) => item.status === 200 &&
      item.contentType.startsWith('text/javascript')),
    `sodium.js was not served as JavaScript: ${JSON.stringify(sodiumResponses)}`);
    assertThat(wasmResponses.length > 0 && wasmResponses.every((item) =>
      item.status === 200 && item.contentType.includes('application/wasm')),
    `Flutter WASM response was not served correctly: ${JSON.stringify(wasmResponses)}`);
    const canvasKitResponses = responseDiagnostics.filter((item) =>
      item.path.toLowerCase().includes('canvaskit'));
    assertThat(canvasKitResponses.some((item) => item.path.endsWith('.js') &&
      item.status === 200 && item.sameOrigin) &&
      canvasKitResponses.some((item) => item.path.endsWith('.wasm') &&
        item.status === 200 && item.sameOrigin),
    `local CanvasKit JavaScript/WASM was not served successfully: ${JSON.stringify(canvasKitResponses)}`);
    const missingAsset = await ownerPage.evaluate(async (name) => {
      const response = await fetch(`/${name}`);
      return { status: response.status, contentType: response.headers.get('content-type') || '',
        prefix: (await response.text()).slice(0, 80) };
    }, `missing-sodium-${RUN_ID}.js`);
    assertThat(missingAsset.status === 404 && !missingAsset.contentType.includes('text/html'),
      `missing JS asset fell through to SPA: ${JSON.stringify(missingAsset)}`);
    // Prove the pages are independent browser profiles before provisioning.
    await ownerPage.evaluate(() => {
      localStorage.setItem('atermius-web-it-profile-marker', 'owner');
      const request = indexedDB.open('atermius-web-it-isolation', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('markers');
      request.onsuccess = () => {
        const tx = request.result.transaction('markers', 'readwrite');
        tx.objectStore('markers').put('owner', 'profile');
      };
    });
    await ownerPage.waitForTimeout(300);
    const secondProfileHasOwnerStorage = await secondPage.evaluate(async () => {
      const databases = await indexedDB.databases();
      return localStorage.getItem('atermius-web-it-profile-marker') !== null ||
        databases.some((database) => database.name === 'atermius-web-it-isolation');
    });
    assertThat(!secondProfileHasOwnerStorage, 'browser contexts share localStorage or IndexedDB');

    await connect(ownerPage, baseUrl);
    activeStage = 'owner account registration';
    await field(ownerPage, 'Owner email');
    console.log('stage: owner bootstrap form opened');
    await fill(ownerPage, 'Owner email', USERNAME);
    await fill(ownerPage, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(ownerPage, 'Confirm master password', MASTER_PASSWORD);
    await fill(ownerPage, 'One-time bootstrap token', bootstrapToken);
    await fill(ownerPage, 'Device name', 'Web profile A');
    await fill(ownerPage, 'First Vault', 'Web sync test vault');
    const passwordInput = await field(ownerPage, 'Master password · 12+ characters');
    const confirmPasswordInput = await field(ownerPage, 'Confirm master password');
    assertThat(await passwordInput.inputValue() === await confirmPasswordInput.inputValue(),
      'browser password inputs do not contain matching values before submission');
    await click(ownerPage, 'Create owner account');
    bootstrapToken = undefined;
    try {
      await waitWorkspace(ownerPage);
    } catch (error) {
      const serverLogPath = path.join(tempRoot, 'server.log');
      console.log('owner registration diagnostic', JSON.stringify({
        page: await safePageDiagnostic(ownerPage),
        api: safeApiSummary(apiDiagnostics, 25),
        pageErrorCount: pageErrors.length,
        browserDiagnosticCount: browserDiagnostics.filter((item) => item.profile === 'A').length,
        serverLogBytes: fs.existsSync(serverLogPath) ? fs.statSync(serverLogPath).size : null,
      }));
      throw error;
    }
    console.log('stage: owner registration completed and workspace opened');
    const sqliteWasm = await ownerPage.evaluate(async () => {
      const response = await fetch('/sqlite3.wasm');
      const bytes = await response.arrayBuffer();
      return {
        status: response.status,
        contentType: response.headers.get('content-type') || '',
        byteLength: bytes.byteLength,
      };
    });
    assertThat(sqliteWasm.status === 200 && sqliteWasm.contentType.includes('application/wasm') &&
      sqliteWasm.byteLength > 0,
    `SQLite WASM was not served correctly: ${JSON.stringify({sqliteWasm, responses: responseDiagnostics})}`);

    if (MULTI_VAULT_SWITCH_ONLY) {
      activeStage = 'multi-Vault: create second independent Vault before device enrollment';
      const initialVaults = serverVaultSnapshot(
        path.join(dataDir, 'atermius.db'),
        USERNAME,
      ).vaults;
      assertThat(initialVaults.length === 1,
        'multi-Vault fixture did not begin with exactly one Vault');
      multiVaultCapture.vaultA = initialVaults[0].vaultId;
      await createVaultThroughSettings(ownerPage, 'Multi Vault B');
    }

    await connect(secondPage, baseUrl);
    await field(secondPage, 'Email or username');
    console.log('stage: second profile unlock form opened');
    await click(secondPage, 'Add this device');
    activeStage = 'device enrollment';
    await waitForText(secondPage, 'Request this device');
    await fill(secondPage, 'Account email', USERNAME);
    await fill(secondPage, 'Device name', 'Web profile B');
    await click(secondPage, 'Generate request');
    const enrollmentField = await field(secondPage, 'Copy this enrollment JSON');
    await click(secondPage, 'Copy');
    const enrollmentJson = await readClipboard(secondPage);
    let enrollmentFormat = null;
    try { enrollmentFormat = JSON.parse(enrollmentJson).format || null; } catch (_) {}
    assertThat(enrollmentFormat === 'atermius-device-enrollment-v1',
      'profile B did not generate a valid enrollment request');
    await click(secondPage, 'Close');

    await click(ownerPage, 'Devices');
    await click(ownerPage, 'Approve enrollment');
    activeStage = 'device approval';
    await paste(ownerPage, 'Enrollment JSON', enrollmentJson);
    await click(ownerPage, 'Review keys');
    const approveButton = await button(ownerPage, 'Approve & seal keys');
      const approveControl = await approveButton.evaluate((element) => ({
        tag: element.tagName, role: element.getAttribute('role'),
        disabled: element.getAttribute('aria-disabled'),
        visible: element.getBoundingClientRect().width > 0 &&
          element.getBoundingClientRect().height > 0,
      }));
    await ownerPage.evaluate(() => {
      window.__e2eApproveClickSeen = false;
      document.addEventListener('click', (event) => {
        const target = event.target.closest('flt-semantics[role="button"]');
        if (target?.innerText?.includes('Approve & seal keys')) window.__e2eApproveClickSeen = true;
      }, true);
    });
    await approveButton.click();
    const approvalCopy = ownerPage.getByRole('button', { name: 'Copy', exact: true }).first();
    let approvalReady = false;
    let immediateError = '';
    const approvalDeadline = Date.now() + 5000;
    while (Date.now() < approvalDeadline) {
      await ownerPage.waitForTimeout(200);
      approvalReady = await approvalCopy.isVisible().catch(() => false);
      const observedText = await ownerPage.locator('body').innerText().catch(() => '');
      immediateError = /Bad state:|FormatException:|epoch.*不在本设备/.test(observedText) ? 'ui-error' : immediateError;
      if (approvalReady || immediateError) break;
    }
    if (!approvalReady) {
      await click(ownerPage, 'Cancel');
      await ownerPage.waitForTimeout(500);
      const afterDismiss = await ownerPage.locator('body').innerText().catch(() => '');
      const localError = /^(Bad state|FormatException|Exception):/m.test(afterDismiss)
        ? 'ui-error'
        : immediateError;
      console.log('device approval diagnostic', {
        approveControl,
        clickSeen: await ownerPage.evaluate(() => window.__e2eApproveClickSeen),
        api: safeApiSummary(apiDiagnostics, 12),
        uiErrorPresent: Boolean(localError),
        pageErrorCount: pageErrors.length,
      });
      throw new Error('profile A did not produce the device approval response');
    }
    await click(ownerPage, 'Copy');
    const approvalJson = await readClipboard(ownerPage);
    assertThat(approvalJson.includes('atermius-device-approval-v1'), 'profile A did not generate a device approval');
    console.log('stage: profile A Copy clipboard read and approval format validated');
    await click(ownerPage, 'Done');
    // Approval leaves the owner on the Devices page; return to Hosts before
    // starting the two-profile sync checks below.
    await click(ownerPage, 'Hosts');
    await waitWorkspace(ownerPage);

    await click(secondPage, 'Import approval');
    await paste(secondPage, 'Paste approval JSON', approvalJson);
    await click(secondPage, 'Import device keys');
    await fill(secondPage, 'Email or username', USERNAME);
    await fill(secondPage, 'Master password', MASTER_PASSWORD);
    await click(secondPage, 'Sign in and unlock');
    try {
      await waitWorkspace(secondPage);
    } catch (error) {
      const serverLogPath = path.join(tempRoot, 'server.log');
      console.log('second-profile login diagnostic', JSON.stringify({
        page: await safePageDiagnostic(secondPage),
        api: safeApiSummary(apiDiagnostics, 30),
        pageErrorCount: pageErrors.length,
        browserDiagnosticCount: browserDiagnostics.filter((item) => item.profile === 'B').length,
        serverLogBytes: fs.existsSync(serverLogPath) ? fs.statSync(serverLogPath).size : null,
      }));
      throw error;
    }

    if (SAME_PROFILE_STALE_PAGE_ONLY) {
      activeStage = 'same-profile stale-page: initialize the second same-origin Owner tab';
      await openSameProfilePeerTab({
        page: ownerTabPage,
        baseUrl,
        startupEvidence,
      });
      await runSameProfileStaleChangesAcceptance({
        ownerPage,
        ownerTabPage,
        secondPage,
        ownerContext,
        baseUrl,
        databasePath: path.join(dataDir, 'atermius.db'),
        tempRoot,
        startupEvidence,
        multiTab,
        observedAuthDeviceIds,
      });
      assertThat(pageErrors.length === 0,
        `stale changes-page acceptance raised ${pageErrors.length} page errors`);
      return;
    }

    if (MULTI_VAULT_SWITCH_ONLY) {
      try {
        await runMultiVaultSwitchAcceptance({
          ownerPage,
          secondPage,
          ownerContext,
          secondContext,
          databasePath: path.join(dataDir, 'atermius.db'),
          capture: multiVaultCapture,
          apiDiagnostics,
        });
      } catch (error) {
        const serverLogPath = path.join(tempRoot, 'server.log');
        const ownerVaultSelectorLabels = await ownerPage.locator(
          'flt-semantics[role="button"]',
        ).evaluateAll((nodes) => nodes.map((node) => ({
          label: node.getAttribute('aria-label') || '',
          text: node.innerText || '',
        })).filter((item) => /vault|web sync test|multi vault/i.test(
          `${item.label}\n${item.text}`,
        )).map((item) => ({
          label: item.label.slice(0, 100),
          text: item.text.slice(0, 100),
        }))).catch(() => []);
        console.log('multi-Vault safe failure evidence', JSON.stringify({
          activeStage,
          errorClass: safeErrorClass(error),
          errorTextClass: safeErrorTextClass(error),
          ownerVaultSelectorLabels,
          ownerPage: await safePageDiagnostic(ownerPage).catch(() => ({ unavailable: true })),
          secondPage: await safePageDiagnostic(secondPage).catch(() => ({ unavailable: true })),
          api: safeApiSummary(apiDiagnostics, 24),
          browser: browserDiagnostics.slice(-16),
          pageErrors: pageErrors.map(({ profile, category }) => ({ profile, category })),
          serverLogBytes: fs.existsSync(serverLogPath)
            ? fs.statSync(serverLogPath).size
            : null,
        }));
        throw error;
      }
      assertThat(pageErrors.length === 0,
        `multi-Vault browser raised ${pageErrors.length} page errors`);
      return;
    }

    if (MISSED_MEMBERSHIP_HINT_ONLY) {
      await runMissedMembershipHintAcceptance({
        browser,
        baseUrl,
        serverEnv,
        ownerPage,
        siblingPage: secondPage,
        wireCapture: missedHintWire,
        ownerUsername: USERNAME,
        databasePath: path.join(dataDir, 'atermius.db'),
        startupEvidence: { responseDiagnostics, browserDiagnostics, pageErrors, cspViolations },
      });
      return;
    }

    if (HOST_SECURITY_CONFLICTS_ONLY) {
      const databasePath = path.join(dataDir, 'atermius.db');
      const baseline = serverVaultSnapshot(databasePath, USERNAME);
      assertThat(baseline.vaults.length === 1,
        'Host security conflict acceptance did not find exactly one active Vault');
      const vaultId = baseline.vaults[0].vaultId;
      const suffix = RUN_ID.slice(0, 12);
      const hostName = `Reviewed host ${suffix}`;
      const baseAddress = `base-${suffix}.host-security.example.test`;
      const branchAAddress = `owner-${suffix}.host-security.example.test`;
      const branchBPort = 22222;
      const markers = [hostName, baseAddress, branchAAddress];
      credentialConflictCapture.markers = markers;
      credentialConflictCapture.active = true;
      const apiCaptureStart = apiDiagnostics.length;
      const pageErrorStart = pageErrors.length;
      const cspViolationStart = cspViolations.length;
      activeStage = 'Host security conflict: create and synchronize the base Host';
      const waitForHostEvidence = async (predicate, page, label, timeoutMs = 25000) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
          const value = predicate();
          if (value) return value;
          await page.waitForTimeout(100);
        }
        throw new Error(`Host security conflict capture timed out: ${label}`);
      };
      try {
        await addHost(ownerPage, {
          name: hostName,
          address: baseAddress,
          username: `deploy-${suffix}`,
        });
        await syncNow(ownerPage);
        const baseCreate = await waitForHostEvidence(
          () => credentialConflictCapture.pushResponses.find((item) =>
            item.profile === 'A' && item.status === 200 &&
            item.operation === 'create'),
          ownerPage,
          'base Host commit receipt',
        );
        assertThat(baseCreate.recordId === credentialConflictCapture.recordId &&
          /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
            .test(baseCreate.recordId || ''),
        'base Host creation did not produce one canonical encrypted record');
        await syncNow(secondPage);
        await waitForHostRecord(secondPage, hostName, true, `${baseAddress}:22`);
        const afterBase = serverVaultSnapshot(databasePath, USERNAME);
        const baseCommitSeq = BigInt(afterBase.vaults[0].commitSeq);

        activeStage = 'Host security conflict: stage independent offline connection changes';
        await Promise.all([
          ownerContext.setOffline(true),
          secondContext.setOffline(true),
        ]);
        await editHostConnection(
          ownerPage,
          hostName,
          { address: branchAAddress },
          `${branchAAddress}:22`,
        );
        await editHostConnection(
          secondPage,
          hostName,
          { port: branchBPort },
          `${baseAddress}:${branchBPort}`,
        );

        activeStage = 'Host security conflict: commit A and preserve B stale branch';
        await ownerContext.setOffline(false);
        try {
          await syncNow(ownerPage);
        } catch (error) {
          console.log('Host security profile A sync catch reached', safeErrorClass(error));
          let syncStatusLabels = [];
          try {
            syncStatusLabels = await visibleSyncStatusLabels(ownerPage);
            const recentApi = apiDiagnostics.slice(apiCaptureStart).map((entry) => ({
              profile: entry.profile === 'A' || entry.profile === 'B' ? entry.profile : null,
              method: typeof entry.method === 'string' ? entry.method : null,
              path: typeof entry.path === 'string'
                ? entry.path.replace(/\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi, '/{id}')
                : null,
              status: Number.isInteger(entry.status) ? entry.status : null,
              errorCode: typeof entry.errorCode === 'string' ? entry.errorCode : null,
            })).slice(-14);
            console.log('Host security profile A sync safe diagnostic', JSON.stringify({
              syncStatusLabels,
              recentApi,
              hostPushAttempts: credentialConflictCapture.pushes.filter((item) =>
                item.profile === 'A' && item.recordId === baseCreate.recordId).length,
              hostPushResponses: credentialConflictCapture.pushResponses.filter((item) =>
                item.profile === 'A' && item.recordId === baseCreate.recordId).length,
              browserErrorCount: pageErrors.length - pageErrorStart,
            }));
          } catch (_) {
            console.log('Host security profile A sync diagnostic could not be collected');
          }
          throw error;
        }
        const ownerHead = await waitForHostEvidence(
          () => credentialConflictCapture.pushResponses.find((item) =>
            item.profile === 'A' && item.status === 200 &&
            item.recordId === baseCreate.recordId &&
            item.operation === 'update' &&
            item.baseRevisionId === baseCreate.revisionId),
          ownerPage,
          'profile A current Host head',
        );
        const afterOwnerHead = serverVaultSnapshot(databasePath, USERNAME);
        assertThat(BigInt(afterOwnerHead.vaults[0].commitSeq) === baseCommitSeq + 1n,
          'profile A Host update did not create exactly one Vault commit');

        activeStage = 'Host security conflict: publish B stale signed branch';
        await secondContext.setOffline(false);
        // A stale local outbox intentionally remains unresolved until the inbox
        // choice is staged; wait for the branch upload, not an Idle badge.
        await triggerSyncWithoutWaitingForIdle(secondPage);
        const staleBranch = await waitForHostEvidence(
          () => credentialConflictCapture.branchUploads.find((item) =>
            item.profile === 'B' && item.recordId === baseCreate.recordId &&
            item.operation === 'update' &&
            item.baseRevisionId === baseCreate.revisionId),
          secondPage,
          'profile B signed stale Host branch',
        );
        assertThat(staleBranch.plaintextMarkersAbsent &&
          staleBranch.exactEnvelopeShape && staleBranch.metadataOnlyHeader &&
          staleBranch.encodedCiphertextFields,
        'stale Host branch upload did not remain an opaque signed envelope');
        const serverConflictId = await waitForHostEvidence(
          () => [...observedConflictIds.B].at(-1),
          secondPage,
          'server conflict identifier',
        );
        const createdOnB = await waitForHostEvidence(
          () => credentialConflictCapture.conflictFeedEvents.find((event) =>
            event.profile === 'B' && event.type === 'created' &&
            event.conflictId === serverConflictId),
          secondPage,
          'profile B verified conflict feed entry',
        );
        assertThat(createdOnB.hasEnvelope && createdOnB.responsePlaintextMarkersAbsent,
          'Host conflict feed omitted its signed envelope or exposed plaintext');

        activeStage = 'Host security conflict: open the conflict inbox';
        await secondPage.getByRole('button', { name: /Sync & conflicts/ })
          .first().click();
        activeStage = 'Host security conflict: wait for the conflict inbox';
        await waitForText(secondPage, '跨设备冲突收件箱');
        await scrollLastVisibleSemanticNodeContaining(
          secondPage,
          'Conflict branches',
        );
        activeStage = 'Host security conflict: locate the Host review action';
        const reviewButton = secondPage.getByRole('button', {
          name: 'Review Host connection settings', exact: true,
        }).first();
        try {
          await reviewButton.waitFor({ state: 'visible', timeout: 20000 });
        } catch (error) {
          console.log('Host review action safe diagnostic', JSON.stringify({
            page: await safePageDiagnostic(secondPage),
            buttonCount: await reviewButton.count().catch(() => -1),
            createdConflictEventCaptured: credentialConflictCapture.conflictFeedEvents
              .some((event) => event.profile === 'B' && event.type === 'created' &&
                event.conflictId === serverConflictId),
            browserErrorCount: pageErrors.length - pageErrorStart,
            errorClass: safeErrorClass(error),
          }));
          throw error;
        }
        assertThat(await reviewButton.isEnabled(),
          'profile B could not open review for its verified Host conflict');
        const resolutionRequestsBeforeChoice =
          credentialConflictCapture.resolutionRequests.length;
        const resolutionStart = credentialConflictCapture.resolutionResponses.length;
        activeStage = 'Host security conflict: load the signed branch preview';
        await reviewButton.click();
        activeStage = 'Host security conflict: verify the review dialog and safe values';
        await waitForText(secondPage, 'Review Host connection settings');
        activeStage = 'Host security conflict: verify the base endpoint';
        await waitForText(secondPage, baseAddress);
        activeStage = 'Host security conflict: verify the current endpoint';
        await waitForText(secondPage, branchAAddress);
        activeStage = 'Host security conflict: verify the branch port';
        await waitForText(secondPage, String(branchBPort));
        activeStage = 'Host security conflict: verify masked fields';
        await waitForText(secondPage, 'Proxy settings');
        await waitForText(secondPage, 'Credential selection, proxy settings');
        assertThat(credentialConflictCapture.resolutionRequests.length ===
          resolutionRequestsBeforeChoice,
        'Host conflict was resolved before the user confirmed a complete tuple');
        const conflictTupleRadio = secondPage.getByRole('radio', {
          name: /^Use the conflict branch tuple\b/,
        });
        const currentTupleRadio = secondPage.getByRole('radio', {
          name: /^Use the current Vault tuple\b/,
        });
        assertThat(await conflictTupleRadio.count() === 1 &&
          await currentTupleRadio.count() === 1,
        'review dialog did not offer exactly the two whole-tuple choices');

        activeStage = 'Host security conflict: choose the complete conflict tuple';
        const pushesBeforeReview = credentialConflictCapture.pushResponses.length;
        const pushRequestsBeforeReview = credentialConflictCapture.pushes.length;
        const mergeApiStart = apiDiagnostics.length;
        const mergeAttemptAtMs = Date.now();
        await conflictTupleRadio.click();
        activeStage = 'Host security conflict: save reviewed tuple with current-device signing';
        const saveButton = secondPage.getByRole('button', {
          name: 'Save reviewed tuple', exact: true,
        });
        const saveButtonState = await saveButton.evaluateAll((nodes) => nodes.map((node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return {
            visible: rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none',
            enabled: !node.hasAttribute('disabled') &&
              node.getAttribute('aria-disabled') !== 'true',
            inViewport: rect.bottom > 0 && rect.right > 0 &&
              rect.top < window.innerHeight && rect.left < window.innerWidth,
          };
        })).catch(() => []);
        console.log('Host reviewed tuple save button state', JSON.stringify({
          buttonCount: await saveButton.count().catch(() => -1),
          buttons: saveButtonState,
          dialogCount: await secondPage.getByRole('dialog').count().catch(() => -1),
        }));
        try {
          await saveButton.click({ timeout: 15000 });
        } catch (error) {
          const hitTest = await saveButton.evaluate((node) => {
            const rect = node.getBoundingClientRect();
            const hit = document.elementFromPoint(
              rect.left + rect.width / 2,
              rect.top + rect.height / 2,
            );
            const isWithinButton = Boolean(hit && (hit === node || node.contains(hit)));
            const hitSemantics = hit?.closest('flt-semantics');
            return {
              buttonInViewport: rect.bottom > 0 && rect.right > 0 &&
                rect.top < window.innerHeight && rect.left < window.innerWidth,
              isWithinButton,
              hitTag: hit?.tagName === 'FLT-SEMANTICS' ? 'flt-semantics' :
                hit?.tagName === 'CANVAS' ? 'canvas' :
                  hit?.tagName === 'BODY' ? 'body' : 'other',
              hitIsSemantics: Boolean(hitSemantics),
              hitIsButtonSemantics: Boolean(hitSemantics &&
                hitSemantics.getAttribute('role') === 'button'),
            };
          }).catch(() => ({ hitTestUnavailable: true }));
          console.log('Host reviewed tuple save click diagnostic', JSON.stringify({
            errorClass: safeErrorClass(error),
            errorCategory: /intercepts pointer events/i.test(error?.message || '')
              ? 'pointer_intercepted'
              : /Timeout/i.test(error?.message || '') ? 'timeout' : 'other',
            hitTest,
            page: await safePageDiagnostic(secondPage).catch(() => ({ unavailable: true })),
            pageErrorCount: pageErrors.length - pageErrorStart,
          }));
          throw error;
        }
        let mergedPush;
        try {
          mergedPush = await waitForHostEvidence(
            () => credentialConflictCapture.pushResponses.find((item) =>
              item.profile === 'B' && item.status === 200 &&
              item.recordId === baseCreate.recordId &&
              item.operation === 'update' &&
              item.baseRevisionId === ownerHead.revisionId &&
              credentialConflictCapture.pushResponses.indexOf(item) >= pushesBeforeReview),
            secondPage,
            'current-device signed selected tuple commit',
          );
        } catch (error) {
          const safeDiagnostic = {
            dialogCount: -1,
            saveButtonCount: -1,
            saveButtonEnabled: false,
            mergeErrorVisible: false,
            api: [],
            pushRequestCount: credentialConflictCapture.pushes.length -
              pushRequestsBeforeReview,
            recentRequestFailures: browserDiagnostics
              .filter((item) => item.kind === 'request-failed' &&
                item.profile === 'B' && item.atMs >= mergeAttemptAtMs)
              .slice(-12)
              .map((item) => ({
                method: item.method,
                path: item.path,
                failureCategory: item.failureCategory,
              })),
            pushResponses: credentialConflictCapture.pushResponses
              .slice(pushesBeforeReview)
              .map((item) => ({
                profile: item.profile,
                status: item.status,
                parseFailed: Boolean(item.parseFailed),
                operation: item.operation ?? null,
                baseRevisionPresent: Boolean(item.baseRevisionId),
              })),
            resolutionRequestCount: credentialConflictCapture.resolutionRequests.length,
            browserErrorCount: pageErrors.length - pageErrorStart,
            errorClass: safeErrorClass(error),
          };
          try {
            safeDiagnostic.page = await safePageDiagnostic(secondPage);
          } catch (_) {
            safeDiagnostic.pageDiagnosticUnavailable = true;
          }
          safeDiagnostic.dialogCount = await secondPage.getByRole('dialog')
            .count().catch(() => -1);
          safeDiagnostic.saveButtonCount = await saveButton.count().catch(() => -1);
          safeDiagnostic.saveButtonEnabled = await saveButton.isEnabled()
            .catch(() => false);
          safeDiagnostic.mergeErrorVisible = await secondPage
            .getByText('Could not save the reviewed tuple', { exact: false })
            .first().isVisible().catch(() => false);
          try {
            safeDiagnostic.api = safeApiSummary(
              apiDiagnostics.slice(mergeApiStart), 40,
            );
          } catch (_) {
            safeDiagnostic.apiDiagnosticUnavailable = true;
          }
          console.log(
            'Host reviewed tuple safe diagnostic',
            JSON.stringify(safeDiagnostic),
          );
          throw error;
        }
        const acceptedMergePushes = credentialConflictCapture.pushResponses
          .slice(pushesBeforeReview)
          .filter((item) => item.profile === 'B' && item.status === 200 &&
            item.recordId === baseCreate.recordId && item.operation === 'update' &&
            item.baseRevisionId === ownerHead.revisionId);
        const mergePushRequests = credentialConflictCapture.pushes
          .slice(pushRequestsBeforeReview)
          .filter((item) => item.profile === 'B' &&
            item.recordId === baseCreate.recordId && item.operation === 'update' &&
            item.baseRevisionId === ownerHead.revisionId);
        console.log('Host reviewed tuple push evidence', JSON.stringify({
          envelopeChecks: {
            plaintextMarkersAbsent: Boolean(mergedPush.plaintextMarkersAbsent),
            exactEnvelopeShape: Boolean(mergedPush.exactEnvelopeShape),
            metadataOnlyHeader: Boolean(mergedPush.metadataOnlyHeader),
            encodedCiphertextFields: Boolean(mergedPush.encodedCiphertextFields),
          },
          acceptedMergePushCount: acceptedMergePushes.length,
          mergePushRequestCount: mergePushRequests.length,
          resolutionRequestCount: credentialConflictCapture.resolutionRequests.length,
          expectedResolutionRequestCount: resolutionRequestsBeforeChoice + 1,
        }));
        activeStage = 'Host security conflict: verify opaque signed update envelope';
        assertThat(mergedPush.plaintextMarkersAbsent &&
          mergedPush.exactEnvelopeShape && mergedPush.metadataOnlyHeader &&
          mergedPush.encodedCiphertextFields &&
          acceptedMergePushes.length === 1 && mergePushRequests.length === 1,
        'reviewed Host merge was not one opaque signed update');
        activeStage = 'Host security conflict: wait for server resolution acknowledgement';
        const successfulResolution = await waitForHostEvidence(
          () => credentialConflictCapture.resolutionResponses
            .slice(resolutionStart)
            .find((item) => item.profile === 'B' && item.status === 200),
          secondPage,
          'server conflict resolution acknowledgement',
        );
        assertThat(credentialConflictCapture.resolutionRequests.length ===
          resolutionRequestsBeforeChoice + 1,
        'conflict resolution request was not issued exactly once');
        assertThat(successfulResolution.markersAbsent,
          'conflict resolution acknowledgement exposed a plaintext marker');

        activeStage = 'Host security conflict: verify commit, resolution and convergence';
        const afterMerge = serverVaultSnapshot(databasePath, USERNAME);
        assertThat(BigInt(afterMerge.vaults[0].commitSeq) ===
          BigInt(afterOwnerHead.vaults[0].commitSeq) + 1n,
        'reviewed Host merge did not create exactly one additional Vault commit');
        const recordState = serverVaultPreferenceLifecycleSnapshot(
          databasePath,
          vaultId,
          baseCreate.recordId,
        );
        assertThat(recordState.versions.length === 3 &&
          recordState.events.length === 3 && recordState.receipts.length === 3 &&
          recordState.head?.revisionId === mergedPush.revisionId &&
          recordState.head.deleted === false &&
          recordState.versions.some((item) =>
            item.revisionId === mergedPush.revisionId &&
            item.operation === 'update' && item.opId === mergedPush.opId),
        'server Host ledger did not contain one exact merge version, receipt, event, and head');
        const resolutionState = serverCredentialResolutionSnapshot(
          databasePath,
          vaultId,
          [serverConflictId],
        ).conflicts[0];
        assertThat(resolutionState.conflictRowCount === 1 &&
          resolutionState.resolvedRevisionId === mergedPush.revisionId &&
          resolutionState.resolutionAuditCount === 1 &&
          resolutionState.resolutionAuditSuccessCount === 1 &&
          resolutionState.resolutionAuditActorPresent,
        'server did not link Host conflict resolution to the selected signed revision');

        await syncNow(ownerPage);
        await syncNow(secondPage);
        activeStage = 'Host security conflict: navigate Profile B to Hosts for convergence';
        await click(secondPage, 'Hosts');
        activeStage = 'Host security conflict: verify Host convergence on both profiles';
        await waitForHostRecord(
          ownerPage,
          hostName,
          true,
          `${baseAddress}:${branchBPort}`,
        );
        await waitForHostRecord(
          secondPage,
          hostName,
          true,
          `${baseAddress}:${branchBPort}`,
        );
        const resolvedOnA = credentialConflictCapture.conflictFeedEvents.find((event) =>
          event.profile === 'A' && event.type === 'resolved' &&
          event.conflictId === serverConflictId);
        const resolvedOnB = credentialConflictCapture.conflictFeedEvents.find((event) =>
          event.profile === 'B' && event.type === 'resolved' &&
          event.conflictId === serverConflictId);
        assertThat(resolvedOnA && resolvedOnB && !resolvedOnA.hasEnvelope &&
          !resolvedOnB.hasEnvelope &&
          resolvedOnA.resolvedRevisionId === mergedPush.revisionId &&
          resolvedOnB.resolvedRevisionId === mergedPush.revisionId,
        'both profiles did not converge on the same resolved Host revision');

        const plaintextMarkersFound = serverDatabasePlaintextMarkers(
          databasePath,
          markers,
        );
        const logEvidence = serverLogPlaintextMarkerEvidence(
          path.join(tempRoot, 'server.log'),
          markers,
        );
        assertThat(plaintextMarkersFound.length === 0 && logEvidence.available &&
          logEvidence.markerAbsent &&
          credentialConflictCapture.pushes.every((item) =>
            item.plaintextMarkersAbsent && item.requestBodyPlaintextMarkersAbsent) &&
          credentialConflictCapture.branchUploads.every((item) =>
            item.plaintextMarkersAbsent && item.requestBodyPlaintextMarkersAbsent) &&
          credentialConflictCapture.httpRequestChecks.every((item) => item.markersAbsent) &&
          credentialConflictCapture.httpResponseChecks.every((item) => item.markersAbsent) &&
          credentialConflictCapture.browserLogChecks.every((item) => item.markersAbsent),
        'Host settings plaintext appeared in transport, server storage, or server logs');
        const relayActivity = apiDiagnostics.slice(apiCaptureStart).filter((entry) =>
          /\/api\/v1\/relay\/tickets|\/api\/v1\/relay\/connect|\/api\/v1\/terminal/i
            .test(entry.path));
        assertThat(relayActivity.length === 0,
          'Host conflict review unexpectedly started a Relay or terminal connection');
        assertThat(pageErrors.length === pageErrorStart &&
          cspViolations.length === cspViolationStart,
        'Host conflict review produced a browser runtime error or CSP violation');
        credentialConflictCapture.active = false;
        console.log('WEB-HOST-SECURITY-CONFLICT-01 passed', JSON.stringify({
          twoProfilesConverged: true,
          selectedWholeTuple: true,
          currentDeviceSignedUpdate: true,
          oneMergeCommitAndReceipt: true,
          conflictResolvedRevisionMatchesHead: true,
          plaintextAbsentFromTransportStorageAndLogs: true,
          relayOrTerminalStarted: false,
          browserRuntimeErrors: pageErrors.length - pageErrorStart,
        }));
      } finally {
        credentialConflictCapture.active = false;
      }
      return;
    }

    if (CREDENTIAL_CONFLICTS_ONLY) {
      const databasePath = path.join(dataDir, 'atermius.db');
      const baseline = serverVaultSnapshot(databasePath, USERNAME);
      assertThat(baseline.vaults.length === 1,
        'Credential conflict acceptance did not find exactly one active Vault');
      const vaultId = baseline.vaults[0].vaultId;
      const baseName = `Credential conflict base ${RUN_ID.slice(0, 8)}`;
      const branchAName = `Credential conflict A ${RUN_ID.slice(0, 8)}`;
      const branchBName = `Credential conflict B ${RUN_ID.slice(0, 8)}`;
      const username = `conflict-user-${RUN_ID.slice(0, 8)}`;
      const branchAUsername = `conflict-a-user-${RUN_ID}`;
      const branchBUsername = `conflict-b-user-${RUN_ID}`;
      const generatePrivateKey = () => crypto.generateKeyPairSync('ed25519', {
        privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
        publicKeyEncoding: { type: 'spki', format: 'pem' },
      }).privateKey.trimEnd();
      const basePrivateKey = generatePrivateKey();
      const branchAPrivateKey = generatePrivateKey();
      const branchBPrivateKey = generatePrivateKey();
      const basePassphrase = `conflict-base-passphrase-${RUN_ID}`;
      const branchAPassphrase = `conflict-a-passphrase-${RUN_ID}`;
      const branchBPassphrase = `conflict-b-passphrase-${RUN_ID}`;
      const markers = [baseName, branchAName, branchBName, username,
        branchAUsername, branchBUsername,
        basePrivateKey.split('\n')[1], branchAPrivateKey.split('\n')[1],
        branchBPrivateKey.split('\n')[1],
        basePassphrase, branchAPassphrase, branchBPassphrase];
      credentialConflictCapture.markers = markers;
      credentialConflictCapture.active = true;
      credentialSyncCapture.markers = markers;
      credentialSyncCapture.active = true;
      let conflictStep = 'create and synchronize the base Credential';
      try {
        await openCredentialsPage(ownerPage);
        await click(ownerPage, 'Add credential');
        await fill(ownerPage, 'Credential name', baseName);
        await fill(ownerPage, 'SSH username', username);
        await click(ownerPage, 'Private key');
        await paste(ownerPage, 'PEM private key', basePrivateKey);
        await fill(ownerPage, 'Key passphrase (optional)', basePassphrase);
        await click(ownerPage, 'Save encrypted credential');
        await waitForCredentialRecord(ownerPage, baseName, true);
        await syncNow(ownerPage);

        const waitForCapture = async (predicate, page, label, timeoutMs = 20000) => {
          const deadline = Date.now() + timeoutMs;
          while (Date.now() < deadline) {
            const found = predicate();
            if (found) return found;
            await page.waitForTimeout(100);
          }
          throw new Error(`Credential conflict capture timed out: ${label}`);
        };
        const credentialSyncIsolation = new Map();
        const isolateCredentialSync = async (context) => {
          assertThat(!credentialSyncIsolation.has(context),
            'Credential sync isolation was already active for this profile');
          const profile = context === secondContext ? 'B' : 'A';
          const generation = credentialSyncCapture.serverGenerations.get(profile);
          assertThat(typeof generation === 'string',
            'Credential sync isolation has no validated server generation');
          const diagnostics = {
            changes: {
              syntheticInvocationsBeforeRelease: 0,
              syntheticInvocationsAfterRelease: 0,
              releaseAttempted: false,
              releaseCompleted: false,
              expectedRecordId: null,
              expectedRemoteRevisionId: null,
              firstResponseAfterRelease: null,
            },
          };
          credentialSyncRouteDiagnostics.set(context, diagnostics);
          const routes = [
            {
              pattern: '**/api/v1/vaults/*/sync/push*',
              handler: (route) => route.abort('internetdisconnected'),
            },
            {
              pattern: '**/api/v1/vaults/*/changes*',
              handler: async (route) => {
                const changesState = diagnostics.changes;
                if (changesState.releaseCompleted) {
                  changesState.syntheticInvocationsAfterRelease++;
                } else {
                  changesState.syntheticInvocationsBeforeRelease++;
                }
                const requestUrl = new URL(route.request().url());
                const requestedCursor = requestUrl.searchParams.get('cursor');
                await route.fulfill({
                  status: 200,
                  contentType: 'application/json',
                  body: JSON.stringify({
                    events: [],
                    next_cursor: requestedCursor,
                    has_more: false,
                    server_generation: generation,
                  }),
                });
              },
            },
            {
              pattern: '**/api/v1/vaults/*/conflict-changes*',
              handler: async (route) => {
                const requestUrl = new URL(route.request().url());
                const requestedAfterSeq =
                  requestUrl.searchParams.get('after_seq') || '0';
                const vaultMatch = requestUrl.pathname.match(
                  /\/api\/v1\/vaults\/([0-9a-f-]+)\/conflict-changes$/i,
                );
                if (!vaultMatch) {
                  await route.abort('failed');
                  return;
                }
                await route.fulfill({
                  status: 200,
                  contentType: 'application/json',
                  body: JSON.stringify({
                    vault_id: vaultMatch[1],
                    after_seq: requestedAfterSeq,
                    high_watermark: requestedAfterSeq,
                    events: [],
                    next_after_seq: requestedAfterSeq,
                    has_more: false,
                    server_generation: generation,
                  }),
                });
              },
            },
          ];
          credentialSyncIsolation.set(context, routes);
          try {
            for (const route of routes) {
              await context.route(route.pattern, route.handler);
            }
          } catch (error) {
            await restoreCredentialSync(context);
            throw error;
          }
        };
        const releaseCredentialSyncRoute = async (context, pattern) => {
          const routes = credentialSyncIsolation.get(context) || [];
          const index = routes.findIndex((route) => route.pattern === pattern);
          if (index < 0) return;
          const [route] = routes.splice(index, 1);
          const changesState = route.pattern.endsWith('/changes*')
            ? credentialSyncRouteDiagnostics.get(context)?.changes
            : null;
          if (changesState) changesState.releaseAttempted = true;
          await context.unroute(route.pattern, route.handler);
          if (changesState) changesState.releaseCompleted = true;
        };
        const restoreCredentialSync = async (context) => {
          const routes = credentialSyncIsolation.get(context) || [];
          for (const route of routes) {
            await context.unroute(route.pattern, route.handler);
          }
          credentialSyncIsolation.delete(context);
        };
        const credentialConflictPostPredicate = (profile) => (entry) =>
          entry.profile === profile && entry.method === 'POST' &&
          /\/conflicts$/.test(entry.path) &&
          (entry.status === 200 || entry.status === 201);
        const waitForCredentialConflictPost = async ({
          profile, page, afterIndex, expectedRecordId, expectedRemoteRevisionId,
        }) => {
          const predicate = credentialConflictPostPredicate(profile);
          let retrySyncWasStillActive = false;
          let retryControlFailureClass = null;
          let retryControlDiagnostic = null;
          let explicitSyncFallback = null;
          const syncButtonPattern = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/;
          const safeSyncControlDiagnostic = async () => {
            const syncButton = page.getByRole('button', { name: syncButtonPattern });
            const count = await syncButton.count().catch(() => 0);
            const instances = [];
            for (let index = 0; index < count; index++) {
              const candidate = syncButton.nth(index);
              const rawLabel = await candidate.getAttribute('aria-label').catch(() => null) ||
                await candidate.innerText().catch(() => '');
              const label = rawLabel.trim();
              instances.push({
                label: syncButtonPattern.test(label) ? label : 'other',
                visible: await candidate.isVisible().catch(() => false),
                enabled: await candidate.isEnabled().catch(() => false),
              });
            }
            const pageState = await page.evaluate(() => {
              const allowedStatuses = new Set([
                'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline',
                'Sync error', 'Snapshot needed', 'Key update needed',
                'Read-only',
              ]);
              const allowedHeadings = new Set([
                '跨设备冲突收件箱', 'SSH credentials', 'Credentials',
                'Your server fleet', 'Host groups', 'Sync health',
                'Trusted devices', 'Workspace settings', 'Vault setup',
                'No accessible Vaults', 'Hosts', 'Settings', 'Vaults',
                'Workspace',
              ]);
              const navigation = [
                ['Hosts', '主机'], ['Groups', '分组'],
                ['Credentials', '凭据'], ['Snippets', '命令片段'],
                ['Workspaces', '工作区布局'], ['Terminal', '终端'],
                ['SFTP', '文件'], ['Sync & conflicts', '同步与冲突'],
                ['Audit log', '审计记录'], ['Devices', '设备'],
                ['Settings', '设置'],
              ];
              const knownButtons = new Set([
                'Add host', 'New group', 'Add credential',
                'Save encrypted credential', 'Cancel', 'Edit', 'Delete',
                'Sync now', 'Merge password fields', '采用此分支',
                '保留当前版本', 'Use conflict branch',
                'Use current Vault version', 'Save merged Credential',
                'Review current version', 'Add credential',
                'Search', 'Clear search', 'Copy', 'Lock',
              ]);
              const statusLabels = [...document.querySelectorAll(
                'flt-semantics[role="button"]',
              )].map((element) =>
                (element.getAttribute('aria-label') || element.innerText || '').trim(),
              ).filter((label) => allowedStatuses.has(label) || /^\d+ pending$/.test(label))
                .map((label) => /^\d+ pending$/.test(label) ? 'pending-count' : label);
              const headingLabels = [...document.querySelectorAll(
                'h1,h2,h3,flt-semantics[role="heading"]',
              )].map((element) =>
                (element.getAttribute('aria-label') || element.innerText || '').trim(),
              ).filter((label) => label.length > 0)
                .map((label) => allowedHeadings.has(label) ? label : 'other');
              const navItems = [];
              const visibleButtons = [];
              for (const element of document.querySelectorAll(
                'flt-semantics[role="button"]',
              )) {
                const rect = element.getBoundingClientRect();
                const visible = rect.width > 0 && rect.height > 0 &&
                  getComputedStyle(element).visibility !== 'hidden' &&
                  getComputedStyle(element).display !== 'none';
                if (!visible) continue;
                const rawLabel = (element.getAttribute('aria-label') ||
                  element.innerText || '').trim().replace(/\s+/g, ' ');
                const nav = navigation.find(([english, chinese]) =>
                  rawLabel === english || rawLabel === `${english} · ${chinese}`);
                const ariaPressed = element.getAttribute('aria-pressed');
                const ariaSelected = element.getAttribute('aria-selected');
                const ariaCurrent = element.getAttribute('aria-current');
                if (nav) {
                  navItems.push({
                    item: nav[0],
                    selectionState: ariaPressed === 'true' || ariaSelected === 'true' ||
                      (ariaCurrent !== null && ariaCurrent !== 'false')
                      ? 'selected'
                      : ariaPressed === 'false' || ariaSelected === 'false' ||
                        ariaCurrent === 'false'
                      ? 'not-selected' : 'unexposed',
                  });
                  continue;
                }
                const compositeSync = rawLabel.match(
                  /^(Idle|Pending|Syncing|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only) · pending (\d+) · conflicts (\d+)$/,
                );
                if (compositeSync) {
                  visibleButtons.push({
                    label: 'sync-status-tooltip',
                    status: compositeSync[1],
                    pendingCountPresent: true,
                    conflictsCountPresent: true,
                  });
                } else if (knownButtons.has(rawLabel)) {
                  visibleButtons.push({ label: rawLabel });
                }
              }
              const roleCounts = {};
              for (const element of document.querySelectorAll('flt-semantics[role]')) {
                const role = element.getAttribute('role');
                roleCounts[role] = (roleCounts[role] || 0) + 1;
              }
              return {
                route: window.location.pathname,
                statusLabels: [...new Set(statusLabels)],
                headingLabels: [...new Set(headingLabels)],
                visibleButtons,
                navigationItems: navItems,
                roleCounts,
              };
            }).catch(() => ({ route: 'unavailable', statusLabels: [],
              headingLabels: [], visibleButtons: [], navigationItems: [],
              roleCounts: {} }));
            return { syncLocatorCount: count, instances, ...pageState };
          };
          for (let attempt = 0; attempt < 3; attempt++) {
            const alreadyObserved = apiDiagnostics.slice(afterIndex).find(predicate);
            if (alreadyObserved) return alreadyObserved;
            const retryIndex = apiDiagnostics.length;
            const syncButton = page.getByRole('button', {
              name: syncButtonPattern,
            }).first();
            try {
              await syncButton.waitFor({ state: 'visible', timeout: 15000 });
              const deadline = Date.now() + 15000;
              let currentLabel = await syncButton.getAttribute('aria-label') ||
                (await syncButton.innerText()).trim();
              while (currentLabel === 'Syncing' && Date.now() < deadline) {
                await page.waitForTimeout(100);
                currentLabel = await syncButton.getAttribute('aria-label') ||
                  (await syncButton.innerText()).trim();
              }
              if (currentLabel === 'Syncing') {
                retrySyncWasStillActive = true;
                break;
              }
              await syncButton.click();
            } catch (error) {
              retryControlFailureClass = safeErrorClass(error);
              if (attempt === 0) {
                retryControlDiagnostic = await safeSyncControlDiagnostic();
                if (retryControlDiagnostic.syncLocatorCount === 0) {
                  const navigation = page.getByRole('button', {
                    name: /^Sync & conflicts(?: · 同步与冲突)?(?:\s+\d+)?$/,
                  });
                  const navigationCount = await navigation.count().catch(() => 0);
                  const visibleEnabledNavigation = [];
                  for (let index = 0; index < navigationCount; index++) {
                    const candidate = navigation.nth(index);
                    if (await candidate.isVisible().catch(() => false) &&
                        await candidate.isEnabled().catch(() => false)) {
                      visibleEnabledNavigation.push(index);
                    }
                  }
                  explicitSyncFallback = {
                    navigationCount,
                    visibleEnabledNavigationCount: visibleEnabledNavigation.length,
                    navigationClicked: false,
                    syncHealthHeadingVisible: false,
                    syncNowCount: 0,
                    syncNowVisibleEnabledCount: 0,
                    syncNowClicked: false,
                    conflictPostObserved: false,
                    diagnosticLogged: false,
                  };
                  const logExplicitSyncFallback = () => {
                    if (explicitSyncFallback.diagnosticLogged) return;
                    const { diagnosticLogged: _, ...safeDiagnostic } =
                      explicitSyncFallback;
                    console.log('credential conflict explicit sync fallback',
                      JSON.stringify(safeDiagnostic));
                    explicitSyncFallback.diagnosticLogged = true;
                  };
                  if (visibleEnabledNavigation.length === 1 &&
                      retryControlDiagnostic.navigationItems.filter((item) =>
                        item.item === 'Sync & conflicts').length === 1) {
                    await navigation.nth(visibleEnabledNavigation[0]).click();
                    explicitSyncFallback.navigationClicked = true;
                    const syncHealthHeading = page.getByText('Sync health', {
                      exact: true,
                    });
                    try {
                      await syncHealthHeading.waitFor({
                        state: 'visible', timeout: 10000,
                      });
                      explicitSyncFallback.syncHealthHeadingVisible = true;
                    } catch (_) {}
                    if (explicitSyncFallback.syncHealthHeadingVisible) {
                      const syncNow = page.getByRole('button', {
                        name: 'Sync now', exact: true,
                      });
                      const syncStates = {
                        syncing: page.getByRole('button', {
                          name: /^Syncing…$/, exact: false,
                        }),
                        rebuildingSnapshot: page.getByRole('button', {
                          name: /^(?:Rebuild snapshot|Rebuilding snapshot…)$/,
                        }),
                        recoveryRequired: page.getByRole('button', {
                          name: /^Recovery required(?: · Syncing…)?$/,
                        }),
                      };
                      const controlEvidence = async (locator) => {
                        const count = await locator.count().catch(() => 0);
                        let visibleCount = 0;
                        let visibleEnabledCount = 0;
                        for (let index = 0; index < count; index++) {
                          const candidate = locator.nth(index);
                          if (await candidate.isVisible().catch(() => false)) {
                            visibleCount++;
                            if (await candidate.isEnabled().catch(() => false)) {
                              visibleEnabledCount++;
                            }
                          }
                        }
                        return { count, visibleCount, visibleEnabledCount };
                      };
                      const controlDeadline = Date.now() + 15000;
                      let syncControlEvidence = null;
                      while (Date.now() < controlDeadline) {
                        const [syncNowEvidence, syncingEvidence,
                          rebuildingEvidence, recoveryEvidence] = await Promise.all([
                          controlEvidence(syncNow),
                          controlEvidence(syncStates.syncing),
                          controlEvidence(syncStates.rebuildingSnapshot),
                          controlEvidence(syncStates.recoveryRequired),
                        ]);
                        syncControlEvidence = {
                          ...syncNowEvidence,
                          syncing: syncingEvidence,
                          rebuildingSnapshot: rebuildingEvidence,
                          recoveryRequired: recoveryEvidence,
                        };
                        explicitSyncFallback.syncNowCount =
                          syncNowEvidence.count;
                        explicitSyncFallback.syncNowVisibleEnabledCount =
                          syncNowEvidence.visibleEnabledCount;
                        explicitSyncFallback.syncingCount =
                          syncingEvidence.count;
                        explicitSyncFallback.syncingVisibleEnabledCount =
                          syncingEvidence.visibleEnabledCount;
                        explicitSyncFallback.rebuildingSnapshotCount =
                          rebuildingEvidence.count;
                        explicitSyncFallback.rebuildingSnapshotVisibleCount =
                          rebuildingEvidence.visibleCount;
                        explicitSyncFallback.recoveryRequiredCount =
                          recoveryEvidence.count;
                        explicitSyncFallback.recoveryRequiredVisibleCount =
                          recoveryEvidence.visibleCount;
                        if (syncNowEvidence.count > 1 ||
                            syncNowEvidence.visibleEnabledCount > 1 ||
                            (syncNowEvidence.count === 1 &&
                             syncNowEvidence.visibleEnabledCount === 1)) {
                          break;
                        }
                        await page.waitForTimeout(250);
                      }
                      if (explicitSyncFallback.syncNowCount === 1 &&
                          explicitSyncFallback.syncNowVisibleEnabledCount === 1) {
                        explicitSyncFallback.syncNowClicked = true;
                        const fallbackRetryStart = apiDiagnostics.length;
                        await syncNow.click();
                        try {
                          const conflictPost = await waitForApiEntry(
                            apiDiagnostics, predicate, fallbackRetryStart, 20000,
                          );
                          explicitSyncFallback.conflictPostObserved = true;
                          logExplicitSyncFallback();
                          return conflictPost;
                        } catch (_) {
                          explicitSyncFallback.conflictPostObserved =
                            apiDiagnostics.slice(fallbackRetryStart).some(predicate);
                          if (explicitSyncFallback.conflictPostObserved) {
                            logExplicitSyncFallback();
                            return apiDiagnostics.slice(fallbackRetryStart).find(predicate);
                          }
                        }
                      }
                      explicitSyncFallback.syncControlEvidence =
                        syncControlEvidence;
                    }
                  }
                  logExplicitSyncFallback();
                }
              }
              break;
            }
            try {
              return await waitForApiEntry(apiDiagnostics, predicate,
                retryIndex, 12000);
            } catch (_) {
              // Continue only after this full sync attempt produced no branch
              // upload; diagnostic below records sanitized changes metadata.
            }
          }
          const finalConflictPost = apiDiagnostics.slice(afterIndex).find(predicate);
          if (finalConflictPost) {
            console.log('credential conflict POST observed at final bounded check',
              JSON.stringify({ profile, status: finalConflictPost.status }));
            return finalConflictPost;
          }
          const recentBChanges = apiDiagnostics
            .filter((entry) => entry.profile === profile && entry.method === 'GET' &&
              entry.path.startsWith('/api/v1/vaults/') &&
              entry.path.endsWith('/changes'))
            .slice(-6)
            .map((entry) => ({
              status: entry.status,
              eventCount: entry.changesPageSummary?.eventCount ?? null,
              hasMore: entry.changesPageSummary?.hasMore ?? null,
              requestCursorPresent:
                entry.changesPageSummary?.requestCursorPresent ?? null,
              requestSequence: entry.changesPageSummary?.requestCursorSequence ?? null,
              nextSequence: entry.changesPageSummary?.nextCursorSequence ?? null,
              generationPresent:
                typeof entry.changesPageSummary?.serverGeneration === 'string',
              eventOperations: (entry.changesPageEvents || [])
                .map((event) => event.operation),
              eventCommitSequences: (entry.changesPageEvents || [])
                .map((event) => event.commitSeq),
              hasExpectedRecord: (entry.changesPageEvents || []).some((event) =>
                event.recordId === expectedRecordId),
              hasExpectedRevision: (entry.changesPageEvents || []).some((event) =>
                event.revisionId === expectedRemoteRevisionId),
              hasExpectedRecordAndRevision: (entry.changesPageEvents || []).some((event) =>
                event.recordId === expectedRecordId &&
                event.revisionId === expectedRemoteRevisionId),
            }));
          const expectedAPushResponses = apiDiagnostics
            .filter((entry) => entry.profile === 'A' && entry.method === 'POST' &&
              entry.path.endsWith('/sync/push') &&
              Array.isArray(entry.pushReceiptSummary?.results) &&
              entry.pushReceiptSummary.results.some((result) =>
                result.revisionId === expectedRemoteRevisionId))
            .map((entry) => ({
              status: entry.status,
              matchingReceipt: entry.pushReceiptSummary.results.some((result) =>
                result.revisionId === expectedRemoteRevisionId),
              commitSequences: entry.pushReceiptSummary.results
                .filter((result) => result.revisionId === expectedRemoteRevisionId)
                .map((result) => result.commitSeq),
              alreadyCommitted: entry.pushReceiptSummary.results
                .filter((result) => result.revisionId === expectedRemoteRevisionId)
                .map((result) => result.alreadyCommitted),
            }));
          const bRouteDiagnostic = credentialSyncRouteDiagnostics
            .get(secondContext)?.changes || null;
          console.log('credential conflict publish diagnostic', JSON.stringify({
            profile,
            attempts: 3,
            retrySyncWasStillActive,
            retryControlFailureClass,
            retryControlDiagnostic,
            explicitSyncFallback,
            expectedRemoteRevisionObserved: credentialSyncCapture.pulls.some((item) =>
              item.profile === profile && item.recordId === expectedRecordId &&
              item.revisionId === expectedRemoteRevisionId),
            expectedRemoteRevisionServerState: serverCredentialRevisionFeedSnapshot(
              databasePath, vaultId, expectedRecordId, expectedRemoteRevisionId,
            ),
            expectedAPushResponses,
            bChangesRoute: bRouteDiagnostic ? {
              syntheticInvocationsBeforeRelease:
                bRouteDiagnostic.syntheticInvocationsBeforeRelease,
              syntheticInvocationsAfterRelease:
                bRouteDiagnostic.syntheticInvocationsAfterRelease,
              releaseAttempted: bRouteDiagnostic.releaseAttempted,
              releaseCompleted: bRouteDiagnostic.releaseCompleted,
              firstResponseAfterRelease:
                bRouteDiagnostic.firstResponseAfterRelease,
            } : null,
            recentBChanges,
            conflictPostObserved: apiDiagnostics.slice(afterIndex).some(predicate),
          }));
          throw new Error('stale Credential branch was not uploaded');
        };
        const assertStaleCredentialPushNotCommitted = ({
          recordId, baseRevisionId, staleOperation, committedOperations, markers: staleMarkers,
        }) => {
          const committed = serverCredentialSnapshot(
            databasePath, vaultId, committedOperations.map((item) => ({
              recordId: item.recordId,
              revisionId: item.revisionId,
              operation: item.operation,
              opId: item.opId,
            })), staleMarkers,
          ).records.find((item) => item.recordId === recordId);
          const attempt = serverLongOfflineSnapshot(databasePath, vaultId, recordId, {
            opId: staleOperation.opId,
            revisionId: staleOperation.revisionId,
            baseRevisionId: staleOperation.baseRevisionId,
            deviceId: staleOperation.deviceId,
            envelopeSha256: staleOperation.envelopeSha256,
            markers: staleMarkers,
          });
          assertThat(committed?.versionCount === committedOperations.length &&
            committed.eventCount === committedOperations.length &&
            committed.headRevisionId === committedOperations.at(-1).revisionId &&
            attempt.headRevisionId === committedOperations.at(-1).revisionId &&
            attempt.staleRevisionVersionCount === 0 &&
            attempt.staleRevisionEventCount === 0 &&
            attempt.staleOperationReceiptCount === 0 &&
            attempt.matchingConflictCount === 0,
          'stale sync push 409 created a receipt, version, event, head, or conflict row');
        };
        const uploadStaleCredentialConflictBranch = async ({
          page, context, recordId, committedOperations, markers: staleMarkers,
        }) => {
          const profile = page === secondPage ? 'B' : 'A';
          assertThat(profile === 'B' && context === secondContext,
            'stale Credential conflict upload must use profile B');
          const conflictApiStart = apiDiagnostics.length;
          const stalePushApiStart = apiDiagnostics.length;
          const requestCaptureStart = credentialConflictCapture.pushes.length;
          const responseCaptureStart = credentialConflictCapture.pushResponses.length;
          const beforeConflictIds = new Set(observedConflictIds.B);
          const startedAt = Date.now();
          let step = 'trigger-sync';

          await releaseCredentialSyncRoute(
            context, '**/api/v1/vaults/*/sync/push*',
          );
          const stalePushPredicate = (entry) =>
            entry.profile === profile && entry.method === 'POST' &&
            /\/sync\/push$/.test(entry.path) && entry.status === 409;
          let stalePushResponse = apiDiagnostics
            .slice(stalePushApiStart).find(stalePushPredicate);
          let triggerErrorClass = null;
          if (!stalePushResponse) {
            step = 'trigger-sync';
            try {
              await triggerSyncWithoutWaitingForIdle(page);
            } catch (error) {
              triggerErrorClass = safeErrorClass(error);
            }
            stalePushResponse = apiDiagnostics
              .slice(stalePushApiStart).find(stalePushPredicate);
          }
          if (!stalePushResponse) {
            step = 'await-head-cas-409';
            try {
              stalePushResponse = await waitForApiEntry(
                apiDiagnostics, stalePushPredicate, stalePushApiStart, 45000,
              );
            } catch (error) {
              console.log('stale Credential push step diagnostic', JSON.stringify({
                step,
                elapsedMs: Date.now() - startedAt,
                errorClass: safeErrorClass(error),
                triggerErrorClass,
                bPushResponses: apiDiagnostics.slice(stalePushApiStart)
                  .filter((item) => item.profile === profile &&
                    item.method === 'POST' && /\/sync\/push$/.test(item.path))
                  .map((item) => ({ status: item.status,
                    isRevisionConflict: item.errorCode === 'REVISION_CONFLICT' })),
                requestEnvelopeCaptures:
                  credentialConflictCapture.pushes.length - requestCaptureStart,
                responseEnvelopeCaptures:
                  credentialConflictCapture.pushResponses.length - responseCaptureStart,
              }));
              throw error;
            }
          }
          if (triggerErrorClass) {
            console.log('stale Credential push trigger recovered by observed CAS',
              JSON.stringify({
                step: 'trigger-sync',
                errorClass: triggerErrorClass,
                observedStatus: stalePushResponse.status,
                observedRevisionConflict:
                  stalePushResponse.errorCode === 'REVISION_CONFLICT',
              }));
          }
          assertThat(stalePushResponse.errorCode === 'REVISION_CONFLICT',
            'profile B stale push did not return the expected HEAD CAS conflict');

          step = 'capture-409-envelope';
          const responseEvidence = credentialConflictCapture.pushResponses
            .slice(responseCaptureStart)
            .find((item) => item.profile === profile && item.status === 409 &&
              item.recordId === recordId && item.operation === 'update');
          const requestEvidence = credentialConflictCapture.pushes
            .slice(requestCaptureStart)
            .find((item) => item.profile === profile && item.recordId === recordId &&
              item.operation === 'update');
          const staleOperation = responseEvidence || requestEvidence;
          if (!staleOperation) {
            console.log('stale Credential push step diagnostic', JSON.stringify({
              step,
              elapsedMs: Date.now() - startedAt,
              responseStatus: stalePushResponse.status,
              expectedErrorCode: stalePushResponse.errorCode === 'REVISION_CONFLICT',
              requestEnvelopeCaptureCount:
                credentialConflictCapture.pushes.length - requestCaptureStart,
              responseEnvelopeCaptureCount:
                credentialConflictCapture.pushResponses.length - responseCaptureStart,
              profileBRequestCaptureCount: credentialConflictCapture.pushes
                .slice(requestCaptureStart)
                .filter((item) => item.profile === profile).length,
              profileBResponseCaptureCount: credentialConflictCapture.pushResponses
                .slice(responseCaptureStart)
                .filter((item) => item.profile === profile).length,
            }));
          }
          assertThat(Boolean(staleOperation),
            '409 response did not expose its stale operation envelope');
          assertThat(staleOperation.requestBodyPlaintextMarkersAbsent &&
            staleOperation.plaintextMarkersAbsent && staleOperation.exactEnvelopeShape &&
            staleOperation.metadataOnlyHeader && staleOperation.encodedCiphertextFields,
          'stale Credential push envelope was not ciphertext-only');
          assertStaleCredentialPushNotCommitted({
            recordId,
            staleOperation,
            committedOperations,
            markers: staleMarkers,
          });

          // First observe the HEAD CAS rejection while B's read routes are held.
          // Then let B read the committed A branch, which causes the repository
          // to publish this same losing operation as an opaque conflict branch.
          const changesRouteState = credentialSyncRouteDiagnostics
            .get(context)?.changes;
          if (changesRouteState) {
            changesRouteState.expectedRecordId = recordId;
            changesRouteState.expectedRemoteRevisionId =
              committedOperations.at(-1).revisionId;
          }
          await releaseCredentialSyncRoute(
            context, '**/api/v1/vaults/*/changes*',
          );
          const conflictPost = await waitForCredentialConflictPost({
            profile,
            page,
            afterIndex: conflictApiStart,
            expectedRecordId: recordId,
            expectedRemoteRevisionId: committedOperations.at(-1).revisionId,
          });
          const expectedAPushResponses = apiDiagnostics
            .filter((entry) => entry.profile === 'A' && entry.method === 'POST' &&
              entry.path.endsWith('/sync/push') &&
              Array.isArray(entry.pushReceiptSummary?.results) &&
              entry.pushReceiptSummary.results.some((result) =>
                result.revisionId === committedOperations.at(-1).revisionId))
            .map((entry) => ({
              status: entry.status,
              matchingReceipt: entry.pushReceiptSummary.results.some((result) =>
                result.revisionId === committedOperations.at(-1).revisionId),
              commitSequences: entry.pushReceiptSummary.results
                .filter((result) => result.revisionId === committedOperations.at(-1).revisionId)
                .map((result) => result.commitSeq),
              alreadyCommitted: entry.pushReceiptSummary.results
                .filter((result) => result.revisionId === committedOperations.at(-1).revisionId)
                .map((result) => result.alreadyCommitted),
            }));
          const changesDiagnostic = credentialSyncRouteDiagnostics
            .get(context)?.changes;
          console.log('credential conflict changes route diagnostic', JSON.stringify({
            profile,
            conflictPostStatus: conflictPost.status,
            expectedAPushResponses,
            bChangesRoute: changesDiagnostic ? {
              syntheticInvocationsBeforeRelease:
                changesDiagnostic.syntheticInvocationsBeforeRelease,
              syntheticInvocationsAfterRelease:
                changesDiagnostic.syntheticInvocationsAfterRelease,
              releaseAttempted: changesDiagnostic.releaseAttempted,
              releaseCompleted: changesDiagnostic.releaseCompleted,
              firstResponseAfterRelease: changesDiagnostic.firstResponseAfterRelease,
            } : null,
          }));
          assertThat(conflictPost.status === 200 || conflictPost.status === 201,
            `profile B Credential conflict returned HTTP ${conflictPost.status}`);
          await releaseCredentialSyncRoute(
            context, '**/api/v1/vaults/*/conflict-changes*',
          );

          const newConflictIds = [...observedConflictIds.B]
            .filter((conflictId) => !beforeConflictIds.has(conflictId));
          assertThat(newConflictIds.length === 1,
            'stale Credential branch did not create exactly one conflict');
          const conflictId = newConflictIds[0];
          const branchUpload = await waitForCapture(() =>
            credentialConflictCapture.branchUploads.find((item) =>
              item.profile === profile && item.recordId === recordId &&
              item.operation === 'update'), page, 'B conflict envelope');
          assertThat(branchUpload.opId === staleOperation.opId &&
            branchUpload.revisionId === staleOperation.revisionId &&
            branchUpload.baseRevisionId === staleOperation.baseRevisionId &&
            branchUpload.envelopeSha256 === staleOperation.envelopeSha256 &&
            branchUpload.deviceId === staleOperation.deviceId &&
            branchUpload.requestBodyPlaintextMarkersAbsent &&
            branchUpload.plaintextMarkersAbsent && branchUpload.exactEnvelopeShape &&
            branchUpload.metadataOnlyHeader && branchUpload.encodedCiphertextFields,
          'conflict POST did not preserve the exact 409-rejected encrypted branch');
          return { staleOperation, branchUpload, conflictId, stalePushResponse };
        };
        const createOperation = await waitForCapture(() =>
          credentialConflictCapture.pushes.find((item) =>
            item.profile === 'A' && item.operation === 'create' &&
            item.recordId === credentialConflictCapture.recordId),
        ownerPage, 'base create');
        assertThat(typeof createOperation.recordId === 'string' &&
          typeof createOperation.revisionId === 'string' &&
          createOperation.requestBodyPlaintextMarkersAbsent &&
          createOperation.plaintextMarkersAbsent && createOperation.exactEnvelopeShape &&
          createOperation.metadataOnlyHeader && createOperation.encodedCiphertextFields,
        'base Credential push was not a ciphertext-only operation');

        conflictStep = 'verify the base Credential is decrypted on profile B';
        await openCredentialsPage(secondPage);
        await waitForCredentialRecord(secondPage, baseName, true);
        await waitForCapture(() => credentialSyncCapture.pulls.find((item) =>
          item.profile === 'B' && item.recordId === createOperation.recordId &&
          item.operation === 'create'), secondPage, 'base changes pull');
        await openCredentialMenuAction(secondPage, baseName, 'Edit');
        assertThat(await focusedFieldValue(secondPage, 'Credential name') === baseName &&
          await focusedFieldValue(secondPage, 'SSH username') === username &&
          await focusedFieldValue(secondPage, 'PEM private key') === basePrivateKey &&
          await focusedFieldValue(secondPage, 'Key passphrase (optional)') ===
            basePassphrase,
        'profile B did not decrypt the base Credential fields');
        await click(secondPage, 'Cancel');

        conflictStep = 'create concurrent isolated local Credential edits';
        let branchAOperation;
        let branchBUpload;
        let conflictId;
        let conflictNotificationStart;
        let conflictFeedApiStart;
        try {
          await Promise.all([
            isolateCredentialSync(ownerContext),
            isolateCredentialSync(secondContext),
          ]);
          await openCredentialMenuAction(ownerPage, baseName, 'Edit');
          await fill(ownerPage, 'Credential name', branchAName);
          await fill(ownerPage, 'SSH username', branchAUsername);
          await paste(ownerPage, 'PEM private key', branchAPrivateKey);
          await fill(ownerPage, 'Key passphrase (optional)', branchAPassphrase);
          await click(ownerPage, 'Save encrypted credential');
          await waitForCredentialRecord(ownerPage, branchAName, true);
          await openCredentialMenuAction(secondPage, baseName, 'Edit');
          await fill(secondPage, 'Credential name', branchBName);
          await fill(secondPage, 'SSH username', branchBUsername);
          await paste(secondPage, 'PEM private key', branchBPrivateKey);
          await fill(secondPage, 'Key passphrase (optional)', branchBPassphrase);
          await click(secondPage, 'Save encrypted credential');
          await waitForCredentialRecord(secondPage, branchBName, true);

          conflictStep = 'commit profile A Credential branch first';
          await restoreCredentialSync(ownerContext);
          const beforeACommit = credentialConflictCapture.pushes.length;
          await syncNow(ownerPage);
          branchAOperation = await waitForCapture(() =>
            credentialConflictCapture.pushes.slice(beforeACommit).find((item) =>
              item.profile === 'A' && item.recordId === createOperation.recordId &&
              item.operation === 'update'), ownerPage, 'A update');
          assertThat(branchAOperation.baseRevisionId === createOperation.revisionId &&
            branchAOperation.requestBodyPlaintextMarkersAbsent &&
            branchAOperation.plaintextMarkersAbsent && branchAOperation.exactEnvelopeShape &&
            branchAOperation.metadataOnlyHeader && branchAOperation.encodedCiphertextFields,
          'profile A concurrent Credential edit did not preserve its encrypted base branch');

          conflictStep = 'upload profile B stale Credential branch';
          conflictNotificationStart = notificationEvents.length;
          conflictFeedApiStart = apiDiagnostics.length;
          const staleConflict = await uploadStaleCredentialConflictBranch({
            page: secondPage,
            context: secondContext,
            recordId: createOperation.recordId,
            committedOperations: [createOperation, branchAOperation],
            markers,
          });
          conflictId = staleConflict.conflictId;
          branchBUpload = staleConflict.branchUpload;
        } finally {
          await Promise.all([
            restoreCredentialSync(ownerContext),
            restoreCredentialSync(secondContext),
          ]);
        }

        conflictStep = 'receive and verify Credential conflict feed';
        const conflictFeedVerificationApiStart = conflictFeedApiStart ??
          apiDiagnostics.length;
        let conflictHint;
        try {
          conflictHint = await waitForNotificationFrame(notificationEvents,
            (frame) => frame.profile === 'A' && frame.direction === 'received' &&
              frame.type === 'sync_required' && frame.conflictSeqPresent === true,
            conflictNotificationStart, 15000);
        } catch (error) {
          console.log('Credential conflict notification safe diagnostic', JSON.stringify({
            notificationEventsSinceStart: notificationEvents
              .slice(conflictNotificationStart)
              .map((frame) => ({
                profile: frame.profile,
                direction: frame.direction,
                type: frame.type,
                conflictSeqPresent: frame.conflictSeqPresent === true,
                commitSeqPresent: frame.commitSeqPresent === true,
              }))
              .slice(-20),
            AReceivedSyncRequiredCount: notificationEvents
              .slice(conflictNotificationStart)
              .filter((frame) => frame.profile === 'A' &&
                frame.direction === 'received' && frame.type === 'sync_required').length,
            conflictFeedApiResponses: apiDiagnostics
              .slice(conflictFeedVerificationApiStart)
              .filter((entry) => entry.path.endsWith('/conflict-changes'))
              .map((entry) => ({ profile: entry.profile, status: entry.status,
                eventCount: entry.conflictEventSummaries?.length ?? null,
                expectedCreatedEventPresent: (entry.conflictEventSummaries || []).some(
                  (event) => event.type === 'created' &&
                    event.conflictId === conflictId),
              })),
            observedConflictFeed: Object.fromEntries(['A', 'B'].map((profile) => [
              profile,
              observedConflictFeedEvents[profile]
                .filter((event) => event.conflictId === conflictId)
                .map((event) => ({
                  type: event.type,
                  hasEnvelope: event.hasEnvelope,
                  recordMatches: event.recordId === createOperation.recordId,
                })),
            ])),
          }));
          throw error;
        }
        console.log('Credential conflict notification frame summary', JSON.stringify({
          matched: true,
          profile: conflictHint.profile,
          direction: conflictHint.direction,
          type: conflictHint.type,
          vaultIdIsUuid: conflictHint.vaultIdIsUuid === true,
          conflictSeqPresent: conflictHint.conflictSeqPresent === true,
          conflictSeqIsDecimal: conflictHint.conflictSeqIsDecimal === true,
          commitSeqPresent: conflictHint.commitSeqPresent === true,
          commitSeqIsDecimal: conflictHint.commitSeqIsDecimal === true,
          receivedSyncRequiredSinceStart: notificationEvents
            .slice(conflictNotificationStart)
            .filter((frame) => frame.direction === 'received' &&
              frame.type === 'sync_required').length,
          conflictFeedResponses: apiDiagnostics
            .slice(conflictFeedVerificationApiStart)
            .filter((entry) => entry.path.endsWith('/conflict-changes'))
            .map((entry) => ({ profile: entry.profile, status: entry.status,
              eventCount: entry.conflictEventSummaries?.length ?? null,
              expectedCreatedEventPresent: (entry.conflictEventSummaries || []).some(
                (event) => event.type === 'created' &&
                  event.conflictId === conflictId),
            })),
        }));
        assertThat(conflictHint.vaultIdIsUuid && conflictHint.conflictSeqIsDecimal &&
          conflictHint.commitSeqPresent === false,
        'Credential conflict notification included invalid or record-level metadata');
        const waitForCreatedConflictOnProfile = async (profile) => {
          try {
            return await waitForConflictFeedEvent(
              observedConflictFeedEvents[profile],
              (event) => event.type === 'created' && event.conflictId === conflictId,
            );
          } catch (error) {
            console.log('Credential conflict feed wait safe diagnostic', JSON.stringify({
              profile,
              matchingCreatedEventPresent: observedConflictFeedEvents[profile]
                .some((event) => event.type === 'created' &&
                  event.conflictId === conflictId),
              matchingFeedResponseCount: apiDiagnostics
                .slice(conflictFeedVerificationApiStart)
                .filter((entry) => entry.profile === profile &&
                  entry.path.endsWith('/conflict-changes')).length,
              matchingFeedResponseSummaries: apiDiagnostics
                .slice(conflictFeedVerificationApiStart)
                .filter((entry) => entry.profile === profile &&
                  entry.path.endsWith('/conflict-changes'))
                .map((entry) => ({ status: entry.status,
                  eventCount: entry.conflictEventSummaries?.length ?? null,
                  expectedCreatedEventPresent: (entry.conflictEventSummaries || [])
                    .some((event) => event.type === 'created' &&
                      event.conflictId === conflictId),
                })),
            }));
            throw error;
          }
        };
        const conflictCreatedOnA = await waitForCreatedConflictOnProfile('A');
        const conflictCreatedOnB = await waitForCreatedConflictOnProfile('B');
        const capturedConflictEvents = credentialConflictCapture.conflictFeedEvents
          .filter((event) => event.conflictId === conflictId);
        const createdEventEvidence = Object.fromEntries(['A', 'B'].map((profile) => {
          const observed = profile === 'A' ? conflictCreatedOnA : conflictCreatedOnB;
          const captured = capturedConflictEvents.find((event) =>
            event.profile === profile && event.type === 'created');
          return [profile, {
            observed: observed.type === 'created' && observed.hasEnvelope === true,
            observedRecordMatches: observed.recordId === createOperation.recordId,
            captured: Boolean(captured),
            capturedEnvelopeMatchesBranch: captured?.envelopeSummary?.envelopeSha256 ===
              branchBUpload.envelopeSha256,
            capturedPlaintextMarkersAbsent: captured?.responsePlaintextMarkersAbsent === true &&
              captured?.envelopeSummary?.plaintextMarkersAbsent === true,
            capturedEnvelopeShapeValid: captured?.envelopeSummary?.exactEnvelopeShape === true &&
              captured?.envelopeSummary?.metadataOnlyHeader === true &&
              captured?.envelopeSummary?.encodedCiphertextFields === true,
          }];
        }));
        console.log('Credential conflict feed frame summary', JSON.stringify({
          createdEventEvidence,
          conflictFeedResponses: apiDiagnostics
            .slice(conflictFeedVerificationApiStart)
            .filter((entry) => entry.path.endsWith('/conflict-changes'))
            .map((entry) => ({ profile: entry.profile, status: entry.status,
              eventCount: entry.conflictEventSummaries?.length ?? null,
              expectedCreatedEventPresent: (entry.conflictEventSummaries || []).some(
                (event) => event.type === 'created' &&
                  event.conflictId === conflictId),
            })),
        }));
        assertThat(conflictCreatedOnA.hasEnvelope && conflictCreatedOnB.hasEnvelope &&
          conflictCreatedOnA.recordId === createOperation.recordId &&
          conflictCreatedOnB.recordId === createOperation.recordId &&
          capturedConflictEvents.some((event) => event.profile === 'A' &&
            event.type === 'created' && event.hasEnvelope &&
            event.responsePlaintextMarkersAbsent &&
            event.envelopeSummary?.envelopeSha256 === branchBUpload.envelopeSha256 &&
            event.envelopeSummary?.exactEnvelopeShape &&
            event.envelopeSummary?.metadataOnlyHeader &&
            event.envelopeSummary?.encodedCiphertextFields &&
            event.envelopeSummary?.plaintextMarkersAbsent) &&
          capturedConflictEvents.some((event) => event.profile === 'B' &&
            event.type === 'created' && event.hasEnvelope &&
            event.responsePlaintextMarkersAbsent &&
            event.envelopeSummary?.envelopeSha256 === branchBUpload.envelopeSha256 &&
            event.envelopeSummary?.exactEnvelopeShape &&
            event.envelopeSummary?.metadataOnlyHeader &&
            event.envelopeSummary?.encodedCiphertextFields &&
            event.envelopeSummary?.plaintextMarkersAbsent),
        'both profiles did not receive the same opaque Credential conflict branch');

        conflictStep = 'adopt the verified Credential branch in the conflict inbox';
        const conflictInboxNav = ownerPage.getByRole('button', {
          name: /Sync & conflicts/,
        }).first();
        await conflictInboxNav.waitFor({ state: 'visible', timeout: 15000 });
        await conflictInboxNav.click();
        await waitForText(ownerPage, '跨设备冲突收件箱');
        const privateKeyMergeActions = ownerPage.getByRole('button', {
          name: 'Merge password fields', exact: true,
        });
        assertThat(await privateKeyMergeActions.count() === 0,
          'private-key Credential incorrectly exposed the password-only merge action');
        const adoptButton = await button(ownerPage, '采用此分支');
        assertThat(await adoptButton.isEnabled(),
          'A did not enable Credential branch adoption after verification');
        const beforeAdoption = credentialConflictCapture.pushes.length;
        await adoptButton.click();
        await waitForText(ownerPage, '采用已验证的设备分支？');
        await click(ownerPage, '重新签名并同步');
        const adoptedOperation = await waitForCapture(() =>
          credentialConflictCapture.pushes.slice(beforeAdoption).find((item) =>
            item.profile === 'A' && item.recordId === createOperation.recordId &&
            item.operation === 'update' &&
            item.baseRevisionId === branchAOperation.revisionId),
        ownerPage, 'adopted re-signed update', 45000);
        assertThat(adoptedOperation.opId !== branchAOperation.opId &&
          adoptedOperation.revisionId !== branchBUpload.revisionId &&
          adoptedOperation.requestBodyPlaintextMarkersAbsent &&
          adoptedOperation.plaintextMarkersAbsent && adoptedOperation.exactEnvelopeShape &&
          adoptedOperation.metadataOnlyHeader && adoptedOperation.encodedCiphertextFields,
        'adopted Credential branch was not re-signed as a fresh encrypted operation');

        conflictStep = 'verify both Credential replicas converged';
        await click(ownerPage, 'Credentials');
        const credentialConvergencePageEvidence = async (page) => page.evaluate(() => {
          const navigation = [
            ['Hosts', '主机'], ['Groups', '分组'], ['Credentials', '凭据'],
            ['Snippets', '命令片段'], ['Workspaces', '工作区布局'],
            ['Terminal', '终端'], ['SFTP', '文件'],
            ['Sync & conflicts', '同步与冲突'], ['Audit log', '审计记录'],
            ['Devices', '设备'], ['Settings', '设置'],
          ];
          const items = [];
          for (const element of document.querySelectorAll(
            'flt-semantics[role="button"]',
          )) {
            const rect = element.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) continue;
            const label = (element.getAttribute('aria-label') ||
              element.innerText || '').trim().replace(/\\s+/g, ' ');
            const match = navigation.find(([english, chinese]) =>
              label === english || label === `${english} · ${chinese}`);
            if (!match) continue;
            const pressed = element.getAttribute('aria-pressed');
            const selected = element.getAttribute('aria-selected');
            const current = element.getAttribute('aria-current');
            items.push({
              item: match[0],
              selectionState: pressed === 'true' || selected === 'true' ||
                (current !== null && current !== 'false')
                ? 'selected'
                : pressed === 'false' || selected === 'false' || current === 'false'
                  ? 'not-selected' : 'unexposed',
            });
          }
          return {
            syncHealthHeadingVisible: [...document.querySelectorAll(
              'h1,h2,h3,flt-semantics[role="heading"]',
            )].some((element) => (element.getAttribute('aria-label') ||
              element.innerText || '').trim() === 'Sync health'),
            navigationItems: items,
          };
        }).catch(() => ({ syncHealthHeadingVisible: false, navigationItems: [] }));
        const profileBPageBeforeCredentialNavigation =
          await credentialConvergencePageEvidence(secondPage);
        await click(secondPage, 'Credentials');
        const convergenceNavigationEvidence = {
          A: await credentialConvergencePageEvidence(ownerPage),
          B: await credentialConvergencePageEvidence(secondPage),
          BWasOnSyncHealthBeforeNavigation:
            profileBPageBeforeCredentialNavigation.syncHealthHeadingVisible,
        };
        console.log('credential adoption convergence navigation',
          JSON.stringify(convergenceNavigationEvidence));
        const waitForAdoptedCredentialRecord = async (
          page, profile, check, name, expectedPresent,
        ) => {
          try {
            await waitForCredentialRecord(page, name, expectedPresent);
          } catch (error) {
            const pushReceipts = apiDiagnostics
              .filter((entry) => entry.profile === 'A' && entry.method === 'POST' &&
                entry.path.endsWith('/sync/push') &&
                Array.isArray(entry.pushReceiptSummary?.results))
              .flatMap((entry) => {
                const matches = entry.pushReceiptSummary.results.filter((receipt) =>
                  receipt.revisionId === adoptedOperation.revisionId);
                return matches.length === 0 ? [] : matches.map((receipt) => ({
                  status: entry.status,
                  matchingReceipt: true,
                  commitSeq: receipt.commitSeq,
                  alreadyCommitted: receipt.alreadyCommitted,
                }));
              });
            const adoptedPulls = credentialSyncCapture.pulls
              .filter((item) => item.profile === 'B' &&
                item.recordId === createOperation.recordId)
              .map((item) => ({
                operation: item.operation,
                commitSeq: item.commitSeq,
                adoptedRevisionObserved:
                  item.revisionId === adoptedOperation.revisionId,
              }));
            const profileBChangeReads = apiDiagnostics
              .filter((entry) => entry.profile === 'B' && entry.method === 'GET' &&
                entry.path.endsWith('/changes'))
              .map((entry) => ({
                status: entry.status,
                eventCount: entry.changesPageSummary?.eventCount ?? null,
                requestCursorSequence:
                  entry.changesPageSummary?.requestCursorSequence ?? null,
                nextCursorSequence:
                  entry.changesPageSummary?.nextCursorSequence ?? null,
                adoptedRevisionObserved:
                  (entry.changesPageEvents || []).some((event) =>
                    event.recordId === createOperation.recordId &&
                    event.revisionId === adoptedOperation.revisionId),
              }));
            const serverState = serverCredentialRevisionFeedSnapshot(
              databasePath, vaultId, createOperation.recordId,
              adoptedOperation.revisionId,
            );
            const pushCaptured = credentialConflictCapture.pushes.some((item) =>
              item.profile === 'A' && item.recordId === createOperation.recordId &&
              item.revisionId === adoptedOperation.revisionId &&
              item.operation === 'update');
            console.log('credential adoption convergence failure evidence',
              JSON.stringify({
                profile,
                check,
                expectedPresent: expectedPresent,
                pushCaptured,
                pushReceipts,
                adoptedPulls,
                profileBChangeReads,
                serverCommit: serverState.querySucceeded ? {
                  querySucceeded: true,
                  versionCount: serverState.versionCount,
                  versionCommitSeqs: serverState.versionCommitSeqs,
                  eventCount: serverState.eventCount,
                  eventCommitSeqs: serverState.eventCommitSeqs,
                  receiptCount: serverState.receiptCount,
                  receiptCommitSeqs: serverState.receiptCommitSeqs,
                  headMatches: serverState.headMatches,
                  vaultMaxChangeSeq: serverState.vaultMaxChangeSeq,
                  vaultCounterSeq: serverState.vaultCounterSeq,
                } : { querySucceeded: false },
              }));
            throw error;
          }
        };
        await waitForAdoptedCredentialRecord(
          ownerPage, 'A', 'present', branchBName, true,
        );
        await waitForAdoptedCredentialRecord(
          ownerPage, 'A', 'absent', branchAName, false,
        );
        await waitForAdoptedCredentialRecord(
          secondPage, 'B', 'present', branchBName, true,
        );
        await waitForAdoptedCredentialRecord(
          secondPage, 'B', 'absent', branchAName, false,
        );
        for (const [page, profile] of [[ownerPage, 'A'], [secondPage, 'B']]) {
          await openCredentialMenuAction(page, branchBName, 'Edit');
          const selectedName = await focusedFieldValue(page, 'Credential name');
          const selectedUsername = await focusedFieldValue(page, 'SSH username');
          const selectedPrivateKey = await focusedFieldValue(page, 'PEM private key');
          const selectedPassphrase = await focusedFieldValue(
            page, 'Key passphrase (optional)',
          );
          assertThat(selectedName === branchBName &&
            selectedUsername === branchBUsername &&
            selectedPrivateKey === branchBPrivateKey &&
            selectedPassphrase === branchBPassphrase,
          `profile ${profile} did not decrypt the selected Credential branch`);
          await click(page, 'Cancel');
        }

        const resolvedOnA = await waitForConflictFeedEvent(
          observedConflictFeedEvents.A,
          (event) => event.type === 'resolved' && event.conflictId === conflictId,
        );
        const resolvedOnB = await waitForConflictFeedEvent(
          observedConflictFeedEvents.B,
          (event) => event.type === 'resolved' && event.conflictId === conflictId,
        );
        const capturedResolved = credentialConflictCapture.conflictFeedEvents
          .filter((event) => event.conflictId === conflictId && event.type === 'resolved');
        assertThat(!resolvedOnA.hasEnvelope && !resolvedOnB.hasEnvelope &&
          resolvedOnA.resolvedRevisionId === adoptedOperation.revisionId &&
          resolvedOnA.resolvedRevisionId === resolvedOnB.resolvedRevisionId &&
          capturedResolved.length >= 2 &&
          capturedResolved.every((event) => !event.hasEnvelope &&
            event.responsePlaintextMarkersAbsent),
        'Credential conflict resolution did not converge without returning another envelope');

        conflictStep = 'inspect exact Credential conflict and commit rows';
        const expectedOperations = [createOperation, branchAOperation, adoptedOperation]
          .map((item) => ({
            recordId: item.recordId,
            revisionId: item.revisionId,
            operation: item.operation,
            opId: item.opId,
          }));
        const snapshot = serverCredentialSnapshot(
          databasePath, vaultId, expectedOperations, markers,
        );
        const credential = snapshot.records.find((item) =>
          item.recordId === createOperation.recordId);
        const conflictSnapshot = serverLongOfflineSnapshot(
          databasePath, vaultId, createOperation.recordId, {
            opId: branchBUpload.opId,
            revisionId: branchBUpload.revisionId,
            baseRevisionId: branchBUpload.baseRevisionId,
            deviceId: branchBUpload.deviceId,
            envelopeSha256: branchBUpload.envelopeSha256,
            resolvedRevisionId: adoptedOperation.revisionId,
            markers,
          },
        );
        const uniqueOperationIds = new Set(expectedOperations.map((item) => item.opId));
        assertThat(snapshot.records.length === 1 && credential?.versionCount === 3 &&
          credential.operations.every((item) => item.receiptCount === 1 &&
            item.receiptMatches && item.revisionEventCount === 1 &&
            item.headerOperation === item.operation) &&
          credential.allEnvelopesCiphertextOnly && !credential.plaintextMarkerFound &&
          credential.headRevisionId === adoptedOperation.revisionId &&
          !credential.headDeleted && uniqueOperationIds.size === 3 &&
          conflictSnapshot.recordVersionCount === 3 &&
          conflictSnapshot.staleRevisionVersionCount === 0 &&
          conflictSnapshot.staleRevisionEventCount === 0 &&
          conflictSnapshot.staleOperationReceiptCount === 0 &&
          conflictSnapshot.matchingConflictCount === 1 &&
          conflictSnapshot.matchingConflictEnvelopeCount === 1 &&
          conflictSnapshot.matchingResolvedConflictCount === 1 &&
          conflictSnapshot.headRevisionId === adoptedOperation.revisionId,
        'server did not retain one conflict branch and exactly three committed Credential revisions');
        const plaintextMarkersFound = serverDatabasePlaintextMarkers(databasePath, markers);
        assertThat(plaintextMarkersFound.length === 0,
          'server SQLite/WAL/SHM contained a Credential conflict plaintext marker');
        assertThat(credentialConflictCapture.pushes.filter((item) =>
          item.recordId === createOperation.recordId).every((item) =>
          item.requestBodyPlaintextMarkersAbsent && item.plaintextMarkersAbsent &&
          item.exactEnvelopeShape && item.metadataOnlyHeader &&
          item.encodedCiphertextFields) &&
          credentialConflictCapture.branchUploads.length >= 1 &&
          credentialConflictCapture.branchUploads.every((item) =>
            item.requestBodyPlaintextMarkersAbsent && item.plaintextMarkersAbsent &&
            item.exactEnvelopeShape && item.metadataOnlyHeader &&
            item.encodedCiphertextFields),
        'Credential conflict requests or envelopes exposed plaintext markers');
        assertThat(pageErrors.length === 0 && cspViolations.length === 0,
          'Credential conflict acceptance observed browser errors or CSP violations');

        const mergeMarkerSets = [];
        const rememberMergeMarkers = (scenarioMarkers) => {
          mergeMarkerSets.push(...scenarioMarkers);
          const allMarkers = [...new Set(mergeMarkerSets)];
          credentialConflictCapture.markers = [...new Set([
            ...credentialConflictCapture.markers,
            ...allMarkers,
          ])];
          credentialSyncCapture.markers = [...new Set([
            ...credentialSyncCapture.markers,
            ...allMarkers,
          ])];
          return allMarkers;
        };
        const createPasswordCredential = async ({ name, username: login, password, markers: scenarioMarkers }) => {
          const allMarkers = rememberMergeMarkers(scenarioMarkers);
          await ownerPage.evaluate(() =>
            console.info('WEB-CREDENTIAL-MERGE-PRIVACY-PROBE'));
          credentialConflictCapture.recordId = null;
          const pushStart = credentialConflictCapture.pushes.length;
          await openCredentialsPage(ownerPage);
          await click(ownerPage, 'Add credential');
          await fill(ownerPage, 'Credential name', name);
          await fill(ownerPage, 'SSH username', login);
          await fill(ownerPage, 'Password', password);
          await click(ownerPage, 'Save encrypted credential');
          await waitForCredentialRecord(ownerPage, name, true);
          await syncNow(ownerPage);
          const created = await waitForCapture(() =>
            credentialConflictCapture.pushes.slice(pushStart).find((item) =>
              item.profile === 'A' && item.operation === 'create' &&
              item.recordId === credentialConflictCapture.recordId),
          ownerPage, 'merge Credential create');
          assertThat(created.requestBodyPlaintextMarkersAbsent &&
            created.plaintextMarkersAbsent && created.exactEnvelopeShape &&
            created.metadataOnlyHeader && created.encodedCiphertextFields,
          'merge Credential create was not ciphertext-only');
          await openCredentialsPage(secondPage);
          await waitForCredentialRecord(secondPage, name, true);
          await waitForCapture(() => credentialSyncCapture.pulls.find((item) =>
            item.profile === 'B' && item.recordId === created.recordId &&
            item.operation === 'create'), secondPage, 'merge Credential base pull');
          await openCredentialMenuAction(secondPage, name, 'Edit');
          assertThat(await focusedFieldValue(secondPage, 'Credential name') === name &&
            await focusedFieldValue(secondPage, 'SSH username') === login &&
            await focusedFieldValue(secondPage, 'Password') === password,
          'profile B did not decrypt the merge Credential base');
          await click(secondPage, 'Cancel');
          assertThat(allMarkers.length >= scenarioMarkers.length,
            'merge Credential marker inventory was incomplete');
          return created;
        };
        const createCredentialConflict = async ({
          recordId, createdOperation, baseName, aChanges, bChanges,
        }) => {
          try {
            await Promise.all([
              isolateCredentialSync(ownerContext),
              isolateCredentialSync(secondContext),
            ]);
            await openCredentialMenuAction(ownerPage, baseName, 'Edit');
            for (const [field, value] of Object.entries(aChanges)) {
              await fill(ownerPage, field, value);
            }
            await click(ownerPage, 'Save encrypted credential');
            const aVisibleName = aChanges['Credential name'] || baseName;
            await waitForCredentialRecord(ownerPage, aVisibleName, true);
            await openCredentialMenuAction(secondPage, baseName, 'Edit');
            for (const [field, value] of Object.entries(bChanges)) {
              await fill(secondPage, field, value);
            }
            await click(secondPage, 'Save encrypted credential');
            const beforeOwnerCommit = credentialConflictCapture.pushes.length;
            await restoreCredentialSync(ownerContext);
            await syncNow(ownerPage);
            const aOperation = await waitForCapture(() =>
              credentialConflictCapture.pushes.slice(beforeOwnerCommit).find((item) =>
                item.profile === 'A' && item.recordId === recordId &&
                item.operation === 'update'), ownerPage, 'merge A branch commit');
            const staleConflict = await uploadStaleCredentialConflictBranch({
              page: secondPage,
              context: secondContext,
              recordId,
              committedOperations: [createdOperation, aOperation],
              markers: credentialConflictCapture.markers,
            });
            const conflictId = staleConflict.conflictId;
            const branch = staleConflict.branchUpload;
            assertThat(branch.opId !== aOperation.opId &&
              branch.revisionId !== aOperation.revisionId &&
              branch.baseRevisionId === createdOperation.revisionId,
            'merge Credential conflict branch was not an opaque stale update');
            await waitForConflictFeedEvent(observedConflictFeedEvents.A,
              (event) => event.type === 'created' && event.conflictId === conflictId);
            await restoreCredentialSync(secondContext);
            await waitForConflictFeedEvent(observedConflictFeedEvents.B,
              (event) => event.type === 'created' && event.conflictId === conflictId);
            await syncNow(ownerPage);
            return { aOperation, branch, conflictId };
          } finally {
            await Promise.all([
              restoreCredentialSync(ownerContext),
              restoreCredentialSync(secondContext),
            ]);
          }
        };
        const credentialMergeControlSnapshot = async (page, expectedCredentialName) => {
          const opener = page.getByRole('button', {
            name: 'Merge password fields', exact: true,
          });
          const openerCount = await opener.count().catch(() => 0);
          const openerInstances = [];
          for (let index = 0; index < openerCount; index++) {
            const candidate = opener.nth(index);
            openerInstances.push({
              semanticElement: await candidate.evaluate((element) => ({
                tagName: element.tagName,
                id: element.getAttribute('id'),
                role: element.getAttribute('role'),
                ariaLabel: element.getAttribute('aria-label'),
              })).catch(() => null),
              closestGroup: await candidate.evaluate((element, expectedName) => {
                const group = element.closest('flt-semantics[role="group"]');
                return {
                  id: group?.getAttribute('id') ?? null,
                  containsExpectedCredentialName: Boolean(group && expectedName &&
                    (group.textContent || '').includes(expectedName)),
                };
              }, expectedCredentialName).catch(() => ({
                id: null,
                containsExpectedCredentialName: false,
              })),
              visible: await candidate.isVisible().catch(() => false),
              enabled: await candidate.isEnabled().catch(() => false),
            });
          }
          const groupIds = openerInstances.map((item) => item.closestGroup.id);
          const sameClosestGroup = groupIds.length > 0 && groupIds[0] !== null &&
            groupIds.every((id) => id === groupIds[0]);
          const inboxHeading = page.getByText('跨设备冲突收件箱', { exact: true });
          return {
            inboxHeadingCount: await inboxHeading.count().catch(() => 0),
            inboxHeadingVisible: await inboxHeading.first().isVisible().catch(() => false),
            mergeOpenerCount: openerCount,
            mergeOpenerInstances: openerInstances,
            sameClosestGroup,
            visibleMergeOpenerCount: openerInstances.filter((item) =>
              item.visible).length,
            actionableMergeOpenerCount: openerInstances.filter((item) =>
              item.visible && item.enabled).length,
            semanticsGroups: await page.locator('flt-semantics[role="group"]')
              .count().catch(() => 0),
            safeActionLabels: await page.evaluate(() => {
              const allowed = new Set([
                'Merge password fields', '采用此分支', '保留当前版本',
                'Use conflict branch', 'Use current Vault version',
                'Save merged Credential', 'Review current version',
              ]);
              return [...document.querySelectorAll('flt-semantics[role="button"]')]
                .map((node) => (node.getAttribute('aria-label') || '').trim())
                .filter((label) => allowed.has(label));
            }).catch(() => []),
          };
        };
        const credentialMergeDialogSnapshot = async (page) => {
          const dialogs = page.getByRole('alertdialog');
          const count = await dialogs.count().catch(() => 0);
          const exactTitles = page.getByText('Merge password fields', {
            exact: true,
          });
          const exactTitleCount = await exactTitles.count().catch(() => 0);
          let exactTitleVisibleCount = 0;
          for (let index = 0; index < exactTitleCount; index++) {
            if (await exactTitles.nth(index).isVisible().catch(() => false)) {
              exactTitleVisibleCount++;
            }
          }
          const instances = [];
          for (let index = 0; index < count; index++) {
            const dialog = dialogs.nth(index);
            const title = dialog.getByText('Merge password fields', { exact: true });
            const save = dialog.getByRole('button', {
              name: 'Save merged Credential', exact: true,
            });
            instances.push({
              roleMetadata: await dialog.evaluate((element) => ({
                tagName: element.tagName,
                role: element.getAttribute('role'),
                id: element.getAttribute('id'),
                ariaLabelMatchesTitle:
                  element.getAttribute('aria-label') === 'Merge password fields',
                ariaLabelLength: element.getAttribute('aria-label')?.length ?? 0,
                ariaLabelledByPresent:
                  Boolean(element.getAttribute('aria-labelledby')),
                textContainsExactTitle:
                  (element.textContent || '').includes('Merge password fields'),
              })).catch(() => null),
              visible: await dialog.isVisible().catch(() => false),
              titleCount: await title.count().catch(() => 0),
              titleVisible: await title.first().isVisible().catch(() => false),
              saveCount: await save.count().catch(() => 0),
              saveVisible: await save.first().isVisible().catch(() => false),
              saveEnabled: await save.first().isEnabled().catch(() => false),
            });
          }
          return {
            alertdialogCount: count,
            visibleAlertdialogCount: instances.filter((item) => item.visible).length,
            exactTitleCount,
            exactTitleVisibleCount,
            instances,
          };
        };
        const openPasswordMergeDialog = async (page, expectedCredentialName) => {
          console.log('credential merge UI phase', JSON.stringify({
            phase: 'navigate-to-conflict-inbox',
          }));
          await clickSyncConflictsNavigation(page);
          try {
            await waitForText(page, '跨设备冲突收件箱');
          } catch (error) {
            console.log('credential merge inbox diagnostic', JSON.stringify({
              phase: 'inbox-heading',
            controls: await credentialMergeControlSnapshot(page, expectedCredentialName),
            }));
            throw error;
          }
          const opener = page.getByRole('button', {
            name: 'Merge password fields', exact: true,
          });
          const openerDeadline = Date.now() + 15000;
          let actionableOpenerIndex = null;
          while (Date.now() < openerDeadline) {
            const count = await opener.count().catch(() => 0);
            const candidates = [];
            for (let index = 0; index < count; index++) {
              const candidate = opener.nth(index);
              candidates.push({
                index,
                semanticElement: await candidate.evaluate((element) => ({
                  ariaLabel: element.getAttribute('aria-label'),
                })).catch(() => null),
                closestGroup: await candidate.evaluate((element, expectedName) => {
                  const group = element.closest('flt-semantics[role="group"]');
                  return {
                    id: group?.getAttribute('id') ?? null,
                    containsExpectedCredentialName: Boolean(group && expectedName &&
                      (group.textContent || '').includes(expectedName)),
                  };
                }, expectedCredentialName).catch(() => ({
                  id: null,
                  containsExpectedCredentialName: false,
                })),
                visible: await candidate.isVisible().catch(() => false),
                enabled: await candidate.isEnabled().catch(() => false),
              });
            }
            const candidateGroupIds = candidates.map((item) => item.closestGroup.id);
            const sameClosestGroup = candidateGroupIds.length > 0 &&
              candidateGroupIds[0] !== null &&
              candidateGroupIds.every((id) => id === candidateGroupIds[0]);
            const actionable = candidates.filter((item) => item.visible && item.enabled &&
              (sameClosestGroup
                ? candidates.length === 1 ||
                  item.semanticElement?.ariaLabel === 'Merge password fields'
                : item.closestGroup.containsExpectedCredentialName));
            if (actionable.length === 1) {
              actionableOpenerIndex = actionable[0].index;
              break;
            }
            await page.waitForTimeout(100);
          }
          const controls = await credentialMergeControlSnapshot(page, expectedCredentialName);
          console.log('credential merge opener diagnostic', JSON.stringify({
            phase: 'opener-ready', controls,
          }));
          assertThat(actionableOpenerIndex !== null,
            'verified password conflict did not expose one enabled merge action');
          await opener.nth(actionableOpenerIndex).click();
          const dialogs = page.getByRole('alertdialog');
          const dialogDeadline = Date.now() + 15000;
          let dialogSnapshot = await credentialMergeDialogSnapshot(page);
          while (Date.now() < dialogDeadline) {
            const visibleDialogIndex = dialogSnapshot.instances.findIndex((item) =>
              item.visible);
            const ready = dialogSnapshot.visibleAlertdialogCount === 1 &&
              dialogSnapshot.exactTitleCount === 1 &&
              dialogSnapshot.exactTitleVisibleCount === 1 &&
              visibleDialogIndex >= 0 &&
              dialogSnapshot.instances[visibleDialogIndex]?.titleCount === 1 &&
              dialogSnapshot.instances[visibleDialogIndex]?.titleVisible &&
              dialogSnapshot.instances[visibleDialogIndex]?.saveCount === 1 &&
              dialogSnapshot.instances[visibleDialogIndex]?.saveVisible;
            if (ready) break;
            await page.waitForTimeout(100);
            dialogSnapshot = await credentialMergeDialogSnapshot(page);
          }
          const visibleDialogIndices = dialogSnapshot.instances
            .map((item, index) => item.visible ? index : -1)
            .filter((index) => index >= 0);
          const visibleDialogIndex = visibleDialogIndices[0];
          const dialogReady = dialogSnapshot.visibleAlertdialogCount === 1 &&
            dialogSnapshot.exactTitleCount === 1 &&
            dialogSnapshot.exactTitleVisibleCount === 1 &&
            visibleDialogIndices.length === 1 &&
            dialogSnapshot.instances[visibleDialogIndex]?.titleCount === 1 &&
            dialogSnapshot.instances[visibleDialogIndex]?.titleVisible &&
            dialogSnapshot.instances[visibleDialogIndex]?.saveCount === 1 &&
            dialogSnapshot.instances[visibleDialogIndex]?.saveVisible;
          if (!dialogReady) {
            console.log('credential merge dialog diagnostic', JSON.stringify({
              phase: 'dialog-opened',
              snapshot: dialogSnapshot,
              controls: await credentialMergeControlSnapshot(page, expectedCredentialName),
            }));
            throw new Error('merge AlertDialog did not expose one visible exact title and Save control');
          }
          return dialogs.nth(visibleDialogIndex);
        };
        const mergeFieldGroup = async (dialog, label) => {
          const group = dialog.getByRole('group', {
            name: label, exact: true,
          });
          const groupCount = await group.count();
          const nodes = [];
          for (let index = 0; index < groupCount; index++) {
            const candidate = group.nth(index);
            const radios = candidate.getByRole('radio');
            const radioCount = await radios.count();
            const radioEvidence = [];
            for (let radioIndex = 0; radioIndex < radioCount; radioIndex++) {
              radioEvidence.push(await radios.nth(radioIndex).evaluate((element) => {
                const ids = (element.getAttribute('aria-labelledby') || '')
                  .split(/\s+/).filter(Boolean);
                const labelledByText = ids.map((id) =>
                  document.getElementById(id)?.textContent || '').join(' ');
                return {
                  role: element.getAttribute('role') || 'none',
                  id: element.getAttribute('id') || null,
                  ariaLabelContainsMask:
                    (element.getAttribute('aria-label') || '').includes('••••••••'),
                  labelledByContainsMask: labelledByText.includes('••••••••'),
                  ariaLabelLength:
                    (element.getAttribute('aria-label') || '').length,
                  labelledByPresent: ids.length > 0,
                };
              }).catch(() => ({ querySucceeded: false })));
            }
            nodes.push({
              ...await candidate.evaluate((element, expectedLabel) => ({
                role: element.getAttribute('role') || 'none',
                id: element.getAttribute('id') || null,
                ariaLabelExact:
                  element.getAttribute('aria-label') === expectedLabel,
                ariaLabelLength:
                  (element.getAttribute('aria-label') || '').length,
                radioDescendantCount: element.querySelectorAll(
                  'flt-semantics[role="radio"]',
                ).length,
                leafRadioCount: [...element.querySelectorAll(
                  'flt-semantics[role="radio"]',
                )].filter((radio) => !radio.querySelector(
                  'flt-semantics[role="radio"]',
                )).length,
              }), label).catch(() => ({ querySucceeded: false })),
              nestedSameLabelGroupCount: await candidate.getByRole('group', {
                name: label, exact: true,
              }).count().catch(() => 0),
              radioLocatorCount: radioCount,
              radioEvidence,
            });
          }
          const nestedSameLabelGroupCount = groupCount === 1
            ? await group.getByRole('group', {
              name: label, exact: true,
            }).count().catch(() => 0)
            : null;
          const radioCount = groupCount === 1
            ? await group.getByRole('radio').count().catch(() => 0)
            : null;
          console.log('credential merge field group precondition', JSON.stringify({
            label,
            assertionName:
              'mergeFieldGroup: exactly one named leaf group with exactly two radios',
            assertionLocation: 'cross_profile_sync.cjs:mergeFieldGroup',
            namedGroupCount: groupCount,
            nestedSameLabelGroupCount,
            radioCount,
            nodes,
          }));
          assertThat(groupCount === 1,
            `merge review did not expose exactly one ${label} field group`);
          assertThat(nestedSameLabelGroupCount === 0,
            `merge review ${label} group was not the unique labeled leaf group`);
          assertThat(radioCount === 2,
            `merge review ${label} leaf group did not contain both source radios`);
          return group;
        };
        const chooseMergeSource = async (dialog, label, source) => {
          const group = await mergeFieldGroup(dialog, label);
          const choiceName = source === 'conflict'
            ? 'Use conflict branch'
            : 'Use current Vault version';
          const oppositeChoiceName = source === 'conflict'
            ? 'Use current Vault version'
            : 'Use conflict branch';
          const radio = group.getByRole('radio', {
            name: new RegExp(`^${escapeRegExp(choiceName)}(?:\\b|$)`),
          });
          const oppositeRadio = group.getByRole('radio', {
            name: new RegExp(`^${escapeRegExp(oppositeChoiceName)}(?:\\b|$)`),
          });
          const radioCount = await radio.count();
          const radioVisible = radioCount === 1 &&
            await radio.isVisible().catch(() => false);
          const radioEnabled = radioCount === 1 &&
            await radio.isEnabled().catch(() => false);
          if (radioCount !== 1 || !radioVisible || !radioEnabled) {
            const allRadios = group.getByRole('radio');
            const allRadioEvidence = [];
            for (let index = 0; index < await allRadios.count(); index++) {
              allRadioEvidence.push(await allRadios.nth(index).evaluate((element) => {
                const ids = (element.getAttribute('aria-labelledby') || '')
                  .split(/\s+/).filter(Boolean);
                const labelledBy = ids.map((id) =>
                  document.getElementById(id)?.textContent || '').join(' ');
                const ariaLabel = element.getAttribute('aria-label') || '';
                const accessibleCandidate = ariaLabel || labelledBy ||
                  (element.textContent || '');
                return {
                  role: element.getAttribute('role') || 'none',
                  id: element.getAttribute('id') || null,
                  ariaLabelLength: ariaLabel.length,
                  labelledByPresent: ids.length > 0,
                  candidateLength: accessibleCandidate.length,
                  startsWithConflictChoice:
                    accessibleCandidate.startsWith('Use conflict branch'),
                  startsWithCurrentChoice:
                    accessibleCandidate.startsWith('Use current Vault version'),
                  ariaChecked: element.getAttribute('aria-checked') === 'true',
                  ariaDisabled: element.getAttribute('aria-disabled') === 'true',
                };
              }).catch(() => ({ querySucceeded: false })));
            }
            console.log('credential merge source radio safe diagnostic',
              JSON.stringify({
                field: label,
                source,
                expectedAccessibleNamePrefix: choiceName,
                matchedRadioCount: radioCount,
                matchedRadioVisible: radioVisible,
                matchedRadioEnabled: radioEnabled,
                allRadioCount: allRadioEvidence.length,
                allRadios: allRadioEvidence,
              }));
          }
          assertThat(radioCount === 1 && radioVisible && radioEnabled,
          `merge review did not expose one selectable ${label} source`);
          await radio.click();
          const checkedDeadline = Date.now() + 3000;
          let radioChecked = false;
          let oppositeRadioChecked = false;
          while (Date.now() < checkedDeadline) {
            radioChecked = await radio.isChecked().catch(() => false);
            oppositeRadioChecked = await oppositeRadio.isChecked()
              .catch(() => false);
            if (radioChecked || oppositeRadioChecked) break;
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
          if (!radioChecked || oppositeRadioChecked) {
            console.log('credential merge selected source safe diagnostic',
              JSON.stringify({
                field: label,
                source,
                targetRadioCount: await radio.count().catch(() => 0),
                targetRadioVisible: await radio.isVisible().catch(() => false),
                targetRadioEnabled: await radio.isEnabled().catch(() => false),
                targetRadioChecked: radioChecked,
                oppositeRadioCount: await oppositeRadio.count().catch(() => 0),
                oppositeRadioChecked,
              }));
          }
          assertThat(radioChecked && !oppositeRadioChecked,
            `merge review did not select the requested ${label} source`);
        };
        const assertMergeSourceUnselected = async (dialog, label) => {
          const group = await mergeFieldGroup(dialog, label);
          const choices = await group.getByRole('radio').all();
          assertThat(choices.length === 2,
            `stale merge review did not expose both ${label} choices`);
          for (const choice of choices) {
            assertThat(!(await choice.isChecked()),
              `stale merge review retained a ${label} choice`);
          }
        };
        const savePasswordMerge = async (dialog) => {
          const save = dialog.getByRole('button', {
            name: 'Save merged Credential', exact: true,
          });
          assertThat(await save.count() === 1 && await save.isVisible() &&
            await save.isEnabled(),
          'password Credential merge was not ready to save');
          await save.click();
        };
        const assertMergeCommit = async ({ created, firstUpdate, optionalInterveningUpdate,
          merged, branch, conflictId, expectedVersionCount, markers: auditMarkers }) => {
          const expected = [created, firstUpdate,
            ...(optionalInterveningUpdate ? [optionalInterveningUpdate] : []), merged]
            .map((item) => ({
              recordId: item.recordId,
              revisionId: item.revisionId,
              operation: item.operation,
              opId: item.opId,
            }));
          const snapshot = serverCredentialSnapshot(
            databasePath, vaultId, expected, auditMarkers,
          );
          const record = snapshot.records.find((item) => item.recordId === created.recordId);
          const branchSnapshot = serverLongOfflineSnapshot(
            databasePath, vaultId, created.recordId, {
              opId: branch.opId,
              revisionId: branch.revisionId,
              baseRevisionId: branch.baseRevisionId,
              deviceId: branch.deviceId,
              envelopeSha256: branch.envelopeSha256,
              resolvedRevisionId: merged.revisionId,
              markers: auditMarkers,
            },
          );
          const resolution = serverCredentialResolutionSnapshot(
            databasePath, vaultId, [conflictId],
          ).conflicts[0];
          assertThat(snapshot.records.length === 1 &&
            record?.versionCount === expectedVersionCount &&
            record.eventCount === expectedVersionCount &&
            record.operations.length === expectedVersionCount &&
            record.operations.every((item) => item.receiptCount === 1 &&
              item.receiptMatches && item.revisionEventCount === 1 &&
              item.headerOperation === item.operation) &&
            record.allEnvelopesCiphertextOnly && !record.plaintextMarkerFound &&
            record.headRevisionId === merged.revisionId && !record.headDeleted &&
            branchSnapshot.recordVersionCount === expectedVersionCount &&
            branchSnapshot.staleRevisionVersionCount === 0 &&
            branchSnapshot.staleRevisionEventCount === 0 &&
            branchSnapshot.staleOperationReceiptCount === 0 &&
            branchSnapshot.matchingConflictCount === 1 &&
            branchSnapshot.matchingConflictEnvelopeCount === 1 &&
            branchSnapshot.matchingResolvedConflictCount === 1 &&
            branchSnapshot.headRevisionId === merged.revisionId &&
            resolution?.conflictRowCount === 1 &&
            resolution.resolvedRevisionId === merged.revisionId &&
            resolution.resolutionAuditCount === 1 &&
            resolution.resolutionAuditSuccessCount === 1 &&
            resolution.resolutionAuditActorPresent,
          'server merge commit did not produce exactly one resolution revision, receipt, event, head, and audit');
          return { record, branchSnapshot };
        };

        const fieldMergeMarkers = [
          `Merge fields base name ${RUN_ID}`,
          `Merge fields A name ${RUN_ID}`,
          `Merge fields tab name ${RUN_ID}`,
          `merge-fields-base-user-${RUN_ID}`,
          `merge-fields-B-user-${RUN_ID}`,
          `merge-fields-password-${RUN_ID}`,
        ];
        let fieldMergeStep = 'create one-field-per-profile Credential';
        const fieldBaseName = fieldMergeMarkers[0];
        const fieldAName = fieldMergeMarkers[1];
        const fieldTabName = fieldMergeMarkers[2];
        const fieldBaseUser = fieldMergeMarkers[3];
        const fieldBUser = fieldMergeMarkers[4];
        const fieldPassword = fieldMergeMarkers[5];
        try {
          const fieldCreated = await createPasswordCredential({
            name: fieldBaseName,
            username: fieldBaseUser,
            password: fieldPassword,
            markers: fieldMergeMarkers,
          });
          fieldMergeStep = 'create divergent Name and Username branches';
          const fieldConflict = await createCredentialConflict({
            recordId: fieldCreated.recordId,
            createdOperation: fieldCreated,
            baseName: fieldBaseName,
            aChanges: { 'Credential name': fieldAName },
            bChanges: { 'SSH username': fieldBUser },
          });
          fieldMergeStep = 'open merge review before head advances';
          let dialog = await openPasswordMergeDialog(ownerPage, fieldAName);
          const secretGroup = await mergeFieldGroup(dialog, 'Password secret');
          const maskedSourceRadioName = (sourceLabel) => new RegExp(
            `^${escapeRegExp(sourceLabel)}[\\s\\S]*••••••••$`,
          );
          const conflictSecretRadio = secretGroup.getByRole('radio', {
            name: maskedSourceRadioName('Use conflict branch'),
          });
          const currentSecretRadio = secretGroup.getByRole('radio', {
            name: maskedSourceRadioName('Use current Vault version'),
          });
          const secretSave = dialog.getByRole('button', {
            name: 'Save merged Credential', exact: true,
          });
          const secretReviewEvidence = {
            secretGroupCount: await secretGroup.count(),
            conflictSecretRadioCount: await conflictSecretRadio.count(),
            conflictSecretRadioVisible:
              await conflictSecretRadio.isVisible().catch(() => false),
            conflictSecretRadioEnabled:
              await conflictSecretRadio.isEnabled().catch(() => false),
            conflictSecretRadioChecked:
              await conflictSecretRadio.isChecked().catch(() => false),
            currentSecretRadioCount: await currentSecretRadio.count(),
            currentSecretRadioVisible:
              await currentSecretRadio.isVisible().catch(() => false),
            currentSecretRadioEnabled:
              await currentSecretRadio.isEnabled().catch(() => false),
            currentSecretRadioChecked:
              await currentSecretRadio.isChecked().catch(() => false),
            maskedOnlyConflictAccessibleNameCount:
              await conflictSecretRadio.count(),
            maskedOnlyCurrentAccessibleNameCount:
              await currentSecretRadio.count(),
            secretMarkerPresentInDom: await ownerPage.evaluate((marker) =>
              document.body.textContent?.includes(marker) || false,
            fieldPassword),
            saveCount: await secretSave.count(),
            saveEnabled: await secretSave.isEnabled().catch(() => false),
          };
          console.log('credential merge initial secret review safe evidence',
            JSON.stringify(secretReviewEvidence));
          assertThat(secretReviewEvidence.secretGroupCount === 1 &&
            secretReviewEvidence.conflictSecretRadioCount === 1 &&
            secretReviewEvidence.conflictSecretRadioVisible &&
            secretReviewEvidence.conflictSecretRadioEnabled &&
            !secretReviewEvidence.conflictSecretRadioChecked &&
            secretReviewEvidence.currentSecretRadioCount === 1 &&
            secretReviewEvidence.currentSecretRadioVisible &&
            secretReviewEvidence.currentSecretRadioEnabled &&
            !secretReviewEvidence.currentSecretRadioChecked &&
            secretReviewEvidence.maskedOnlyConflictAccessibleNameCount === 1 &&
            secretReviewEvidence.maskedOnlyCurrentAccessibleNameCount === 1 &&
            !secretReviewEvidence.secretMarkerPresentInDom &&
            secretReviewEvidence.saveCount === 1 &&
            !secretReviewEvidence.saveEnabled,
          'password merge review did not keep both equal secret choices masked and unselected');
          await chooseMergeSource(dialog, 'Name', 'current');
          await chooseMergeSource(dialog, 'Username', 'conflict');
          await chooseMergeSource(dialog, 'Password secret', 'current');

          fieldMergeStep = 'advance current Vault head from same-profile second tab';
          const ownerTabResponse = await ownerTabPage.goto(baseUrl, {
            waitUntil: 'domcontentloaded',
          });
          assertThat(ownerTabResponse && ownerTabResponse.status() === 200,
            'same-profile merge review tab navigation did not return HTTP 200');
          await enableFlutterSemantics(ownerTabPage, 'A', startupEvidence);
          await selectServerModeIfChooser(ownerTabPage);
          const ownerTabEntryDeadline = Date.now() + 20000;
          let ownerTabEntryReady = false;
          while (Date.now() < ownerTabEntryDeadline) {
            if (await ownerTabPage.getByRole('button', {
              name: 'Add host', exact: true,
            }).isVisible().catch(() => false) ||
                await ownerTabPage.locator('input[aria-label*="Email or username"]')
                  .first().isVisible().catch(() => false)) {
              ownerTabEntryReady = true;
              break;
            }
            const canConnect = await ownerTabPage.getByRole('button', {
              name: 'Connect securely', exact: true,
            }).isVisible().catch(() => false) &&
              await ownerTabPage.locator('input[aria-label*="Server URL"]')
                .first().isVisible().catch(() => false);
            if (canConnect) {
              await ownerTabPage.waitForTimeout(400);
              if (await ownerTabPage.getByRole('button', {
                name: 'Add host', exact: true,
              }).isVisible().catch(() => false) ||
                  await ownerTabPage.locator('input[aria-label*="Email or username"]')
                    .first().isVisible().catch(() => false)) {
                ownerTabEntryReady = true;
                break;
              }
              await connect(ownerTabPage, baseUrl);
              ownerTabEntryReady = true;
              break;
            }
            await ownerTabPage.waitForTimeout(100);
          }
          assertThat(ownerTabEntryReady,
            'same-profile merge review tab did not reach workspace or login');
          const ownerTabLogin = ownerTabPage.locator(
            'input[aria-label*="Email or username"]',
          ).first();
          if (await ownerTabLogin.isVisible().catch(() => false)) {
            await fill(ownerTabPage, 'Email or username', USERNAME);
            await fill(ownerTabPage, 'Master password', MASTER_PASSWORD);
            await click(ownerTabPage, 'Sign in and unlock');
          }
          await waitWorkspace(ownerTabPage);
          await openCredentialsPage(ownerTabPage);
          await waitForCredentialRecord(ownerTabPage, fieldAName, true);
          const pushCountBeforeHeadAdvance = credentialConflictCapture.pushes.length;
          await openCredentialMenuAction(ownerTabPage, fieldAName, 'Edit');
          await fill(ownerTabPage, 'Credential name', fieldTabName);
          await click(ownerTabPage, 'Save encrypted credential');
          await waitForCredentialRecord(ownerTabPage, fieldTabName, true);
          await syncNow(ownerTabPage);
          const tabHeadOperation = await waitForCapture(() =>
            credentialConflictCapture.pushes.slice(pushCountBeforeHeadAdvance).find((item) =>
              item.profile === 'A' && item.recordId === fieldCreated.recordId &&
              item.operation === 'update'),
          ownerTabPage, 'same-profile intervening update');
          assertThat(tabHeadOperation.baseRevisionId === fieldConflict.aOperation.revisionId,
            'same-profile tab did not advance from the committed A head');

          fieldMergeStep = 'reject stale review without commit artifacts';
          const pushesBeforeStaleSave = credentialConflictCapture.pushes.length;
          const resolutionsBeforeStaleSave = credentialConflictCapture.resolutionRequests.length;
          const beforeStaleSnapshot = serverCredentialSnapshot(databasePath, vaultId, [
            fieldCreated, fieldConflict.aOperation, tabHeadOperation,
          ].map((item) => ({
            recordId: item.recordId,
            revisionId: item.revisionId,
            operation: item.operation,
            opId: item.opId,
          })), fieldMergeMarkers).records[0];
          await savePasswordMerge(dialog);
          await waitForSemanticText(ownerPage,
            'The current Vault version changed while you were reviewing');
          assertThat(!(await dialog.getByRole('button', {
            name: 'Save merged Credential', exact: true,
          }).isEnabled()), 'stale merge review left Save enabled after clearing choices');
          await assertMergeSourceUnselected(dialog, 'Name');
          await assertMergeSourceUnselected(dialog, 'Username');
          const afterStaleSnapshot = serverCredentialSnapshot(databasePath, vaultId, [
            fieldCreated, fieldConflict.aOperation, tabHeadOperation,
          ].map((item) => ({
            recordId: item.recordId,
            revisionId: item.revisionId,
            operation: item.operation,
            opId: item.opId,
          })), fieldMergeMarkers).records[0];
          assertThat(credentialConflictCapture.pushes.length === pushesBeforeStaleSave &&
            credentialConflictCapture.resolutionRequests.length === resolutionsBeforeStaleSave &&
            beforeStaleSnapshot.headRevisionId === afterStaleSnapshot.headRevisionId &&
            beforeStaleSnapshot.versionCount === afterStaleSnapshot.versionCount &&
            beforeStaleSnapshot.eventCount === afterStaleSnapshot.eventCount &&
            beforeStaleSnapshot.operations.length === afterStaleSnapshot.operations.length,
          'stale merge review created a push, resolution request, revision, receipt, event, or head change');

          fieldMergeStep = 're-review current head and commit field merge';
          const reviewCurrent = dialog.getByRole('button', {
            name: 'Review current version', exact: true,
          });
          assertThat(await reviewCurrent.count() === 1 && await reviewCurrent.isEnabled(),
            'stale merge review did not offer an explicit current-head review');
          await reviewCurrent.click();
          await dialog.getByRole('button', {
            name: 'Save merged Credential', exact: true,
          }).waitFor({ state: 'visible', timeout: 10000 });
          await chooseMergeSource(dialog, 'Name', 'current');
          await chooseMergeSource(dialog, 'Username', 'conflict');
          await chooseMergeSource(dialog, 'Password secret', 'current');
          const pushStart = credentialConflictCapture.pushes.length;
          const fieldMergeApiStart = apiDiagnostics.length;
          const fieldMergeHttpRequestStart =
            credentialConflictCapture.httpRequestChecks.length;
          const fieldMergeHttpResponseStart =
            credentialConflictCapture.httpResponseChecks.length;
          const fieldMergeResolutionRequestStart =
            credentialConflictCapture.resolutionRequests.length;
          const fieldMergeResolutionResponseStart =
            credentialConflictCapture.resolutionResponses.length;
          await savePasswordMerge(dialog);
          const fieldMerged = await waitForCapture(() =>
            credentialConflictCapture.pushes.slice(pushStart).find((item) =>
              item.profile === 'A' && item.recordId === fieldCreated.recordId &&
              item.operation === 'update' &&
              item.baseRevisionId === tabHeadOperation.revisionId),
          ownerPage, 'field merge update', 45000);
          const runFieldMergeSync = async (page, profile) => {
            const syncApiStart = apiDiagnostics.length;
            const syncRequestStart = credentialConflictCapture.httpRequestChecks.length;
            const syncResponseStart = credentialConflictCapture.httpResponseChecks.length;
            try {
              await syncNow(page);
            } catch (error) {
              const routeKind = (path) => {
                if (path.endsWith('/sync/push')) return 'push';
                if (path.endsWith('/changes')) return 'changes';
                if (/\/conflicts\/[^/]+\/resolve$/.test(path)) return 'resolve';
                if (path.endsWith('/conflicts')) return 'conflicts';
                return 'other';
              };
              const summarizeRoutes = (rows) => {
                const grouped = new Map();
                for (const row of rows) {
                  const key = JSON.stringify(row);
                  grouped.set(key, (grouped.get(key) || 0) + 1);
                }
                return [...grouped.entries()].map(([key, count]) => ({
                  ...JSON.parse(key), count,
                }));
              };
              const requestRoutes = credentialConflictCapture.httpRequestChecks
                .slice(fieldMergeHttpRequestStart)
                .map((item) => ({
                  profile: item.profile,
                  method: item.method,
                  kind: routeKind(item.path),
                }));
              const responseRoutes = credentialConflictCapture.httpResponseChecks
                .slice(fieldMergeHttpResponseStart)
                .map((item) => ({
                  profile: item.profile,
                  method: item.method,
                  kind: routeKind(item.path),
                  status: item.status,
                }));
              const apiRoutes = apiDiagnostics.slice(fieldMergeApiStart)
                .map((item) => ({
                  profile: item.profile,
                  method: item.method,
                  kind: routeKind(item.path),
                  status: item.status,
                }));
              const mergePushResponses = credentialConflictCapture.pushResponses
                .slice(pushStart)
                .filter((item) => item.profile === 'A' &&
                  item.opId === fieldMerged.opId &&
                  item.revisionId === fieldMerged.revisionId)
                .map((item) => ({
                  status: item.status,
                  envelopeMatched: true,
                  parseFailed: item.parseFailed === true,
                }));
              const mergePushReceipts = apiDiagnostics.slice(fieldMergeApiStart)
                .filter((item) => item.method === 'POST' &&
                  item.path.endsWith('/sync/push'))
                .flatMap((item) => {
                  const receipts = item.pushReceiptSummary?.results || [];
                  const matches = receipts.filter((receipt) =>
                    receipt.opId === fieldMerged.opId &&
                    receipt.revisionId === fieldMerged.revisionId);
                  return matches.map((receipt) => ({
                    profile: item.profile,
                    status: item.status,
                    matchingReceipt: true,
                    commitSeq: receipt.commitSeq,
                    alreadyCommitted: receipt.alreadyCommitted,
                  }));
                });
              const resolutionRequests = credentialConflictCapture.resolutionRequests
                .slice(fieldMergeResolutionRequestStart)
                .filter((item) => /\/conflicts\/[^/]+\/resolve$/.test(item.path));
              const resolutionResponses = credentialConflictCapture.resolutionResponses
                .slice(fieldMergeResolutionResponseStart)
                .filter((item) => /\/conflicts\/[^/]+\/resolve$/.test(item.path))
                .map((item) => ({ profile: item.profile, status: item.status }));
              const serverState = serverCredentialRevisionFeedSnapshot(
                databasePath, vaultId, fieldMerged.recordId, fieldMerged.revisionId,
              );
              console.log('credential field merge sync timeout evidence', JSON.stringify({
                profile,
                statusLabels: await visibleSyncStatusLabels(page),
                apiResponsesSincePushStart: summarizeRoutes(apiRoutes),
                requestsSincePushStart: summarizeRoutes(requestRoutes),
                responsesSincePushStart: summarizeRoutes(responseRoutes),
                syncCallApiResponseCount: apiDiagnostics.length - syncApiStart,
                syncCallRequestCount:
                  credentialConflictCapture.httpRequestChecks.length - syncRequestStart,
                syncCallResponseCount:
                  credentialConflictCapture.httpResponseChecks.length - syncResponseStart,
                mergePushResponses,
                mergePushReceipts,
                resolutionRequestCount: resolutionRequests.length,
                resolutionResponseCount: resolutionResponses.length,
                resolutionResponseStatuses: resolutionResponses,
                serverState: {
                  querySucceeded: serverState.querySucceeded === true,
                  versionCount: serverState.versionCount ?? null,
                  versionCommitSeqs: serverState.versionCommitSeqs ?? [],
                  eventCount: serverState.eventCount ?? null,
                  eventCommitSeqs: serverState.eventCommitSeqs ?? [],
                  receiptCount: serverState.receiptCount ?? null,
                  receiptCommitSeqs: serverState.receiptCommitSeqs ?? [],
                  headMatches: serverState.headMatches ?? false,
                  vaultMaxChangeSeq: serverState.vaultMaxChangeSeq ?? null,
                  vaultCounterSeq: serverState.vaultCounterSeq ?? null,
                },
              }));
              throw error;
            }
          };
          await runFieldMergeSync(ownerPage, 'A');
          const fieldBChangesStart = apiDiagnostics.length;
          await triggerSyncWithoutWaitingForIdle(secondPage);
          await waitForCapture(() => apiDiagnostics.slice(fieldBChangesStart)
            .find((item) => item.profile === 'B' && item.method === 'GET' &&
              item.path.endsWith('/changes') && item.status === 200),
          secondPage, 'profile B field merge changes pull', 45000);
          const fieldResolvedB = await waitForConflictFeedEvent(
            observedConflictFeedEvents.B,
            (event) => event.type === 'resolved' &&
              event.conflictId === fieldConflict.conflictId,
            45000,
          );
          const fieldBChanges = apiDiagnostics.slice(fieldBChangesStart)
            .filter((item) => item.profile === 'B' && item.method === 'GET' &&
              item.path.endsWith('/changes'));
          assertThat(fieldBChanges.length > 0 &&
            fieldBChanges.every((item) => item.status === 200),
          'profile B did not successfully pull the field merge commit');
          console.log('credential field merge B pull verified', JSON.stringify({
            changesResponseCount: fieldBChanges.length,
            allChangesResponsesSuccessful: fieldBChanges.every((item) => item.status === 200),
          }));
          assertThat(fieldResolvedB.resolvedRevisionId === fieldMerged.revisionId &&
            !fieldResolvedB.hasEnvelope,
          'profile B did not observe the matching envelope-free resolution event');
          console.log('credential field merge B resolution event verified', JSON.stringify({
            resolvedEventObserved: true,
            revisionMatchesMerge: true,
            envelopeAbsent: true,
          }));
          // A resolved feed event closes the stale outbox chain. Wait for the
          // UI to settle fully so pending operations cannot be hidden by the
          // later decrypted-record assertions.
          await syncNow(secondPage);
          const fieldResolutionPath = new RegExp(
            `/conflicts/${escapeRegExp(fieldConflict.conflictId)}/resolve$`,
          );
          const fieldResolutionResponse = await waitForCapture(() =>
            credentialConflictCapture.resolutionResponses.find((item) =>
              item.profile === 'A' && fieldResolutionPath.test(item.path) &&
              item.status === 200), ownerPage, 'field merge resolution response', 45000);
          const fieldResolutionRequests = credentialConflictCapture.resolutionRequests
            .filter((item) => fieldResolutionPath.test(item.path));
          const fieldResolutionResponses = credentialConflictCapture.resolutionResponses
            .filter((item) => fieldResolutionPath.test(item.path));
          assertThat(fieldResolutionResponse.method === 'POST' &&
            fieldResolutionResponse.markersAbsent &&
            fieldResolutionRequests.length === 1 &&
            fieldResolutionRequests[0].method === 'POST' &&
            fieldResolutionRequests[0].markersAbsent &&
            fieldResolutionResponses.length === 1,
          'field merge did not resolve its conflict exactly once without plaintext');
          const fieldResolvedA = await waitForConflictFeedEvent(
            observedConflictFeedEvents.A,
            (event) => event.type === 'resolved' &&
              event.conflictId === fieldConflict.conflictId,
          );
          assertThat(fieldResolvedA.resolvedRevisionId === fieldMerged.revisionId &&
            fieldResolvedB.resolvedRevisionId === fieldMerged.revisionId &&
            !fieldResolvedA.hasEnvelope && !fieldResolvedB.hasEnvelope,
          'field merge resolution did not converge on the single committed revision');
          console.log('credential field merge A resolution event verified', JSON.stringify({
            resolvedEventObserved: true,
            revisionMatchesMerge: fieldResolvedA.resolvedRevisionId === fieldMerged.revisionId,
            envelopeAbsent: !fieldResolvedA.hasEnvelope,
          }));
          await click(ownerPage, 'Credentials');
          console.log('credential field merge record wait', JSON.stringify({
            profile: 'A', recordSlot: 'merged', expectedPresent: true,
          }));
          await waitForCredentialRecord(ownerPage, fieldTabName, true);
          console.log('credential field merge record wait', JSON.stringify({
            profile: 'A', recordSlot: 'conflict-branch', expectedPresent: false,
          }));
          await waitForCredentialRecord(ownerPage, fieldAName, false);
          const bSyncHealthHeading = await secondPage.getByText('Sync health', {
            exact: true,
          }).isVisible().catch(() => false);
          console.log('credential field merge B navigation before record checks',
            JSON.stringify({ syncHealthHeadingVisible: bSyncHealthHeading }));
          await click(secondPage, 'Credentials');
          console.log('credential field merge record wait', JSON.stringify({
            profile: 'B', recordSlot: 'merged', expectedPresent: true,
          }));
          await waitForCredentialRecord(secondPage, fieldTabName, true);
          console.log('credential field merge record wait', JSON.stringify({
            profile: 'B', recordSlot: 'conflict-branch', expectedPresent: false,
          }));
          await waitForCredentialRecord(secondPage, fieldAName, false);
          for (const [page, profile] of [[ownerPage, 'A'], [secondPage, 'B']]) {
            await openCredentialMenuAction(page, fieldTabName, 'Edit');
            assertThat(await focusedFieldValue(page, 'Credential name') === fieldTabName &&
              await focusedFieldValue(page, 'SSH username') === fieldBUser &&
              await focusedFieldValue(page, 'Password') === fieldPassword,
            `profile ${profile} did not converge on the selected field merge`);
            await click(page, 'Cancel');
          }
          const fieldAuditMarkers = rememberMergeMarkers(fieldMergeMarkers);
          const fieldCommit = await assertMergeCommit({
            created: fieldCreated,
            firstUpdate: fieldConflict.aOperation,
            optionalInterveningUpdate: tabHeadOperation,
            merged: fieldMerged,
            branch: fieldConflict.branch,
            conflictId: fieldConflict.conflictId,
            expectedVersionCount: 4,
            markers: fieldAuditMarkers,
          });

          const secretMergeMarkers = [
            `Merge secret base name ${RUN_ID}`,
            `merge-secret-user-${RUN_ID}`,
            `merge-secret-base-password-${RUN_ID}`,
            `merge-secret-A-password-${RUN_ID}`,
            `merge-secret-B-password-${RUN_ID}`,
          ];
          let secretMergeStep = 'create same-field secret Credential';
          const secretName = secretMergeMarkers[0];
          const secretUser = secretMergeMarkers[1];
          const secretBase = secretMergeMarkers[2];
          const secretA = secretMergeMarkers[3];
          const secretB = secretMergeMarkers[4];
          const secretCreated = await createPasswordCredential({
            name: secretName,
            username: secretUser,
            password: secretBase,
            markers: secretMergeMarkers,
          });
          try {
            secretMergeStep = 'create same-field password divergence';
            const secretConflict = await createCredentialConflict({
              recordId: secretCreated.recordId,
              createdOperation: secretCreated,
              baseName: secretName,
              aChanges: { Password: secretA },
              bChanges: { Password: secretB },
            });
            secretMergeStep = 'require explicit password source selection';
            const secretDialog = await openPasswordMergeDialog(ownerPage, secretName);
            const secretSave = secretDialog.getByRole('button', {
              name: 'Save merged Credential', exact: true,
            });
            assertThat(await secretDialog.getByText('Same on both branches', {
              exact: false,
            }).count() >= 2 && !(await secretSave.isEnabled()),
            'equal Name/Username fields or mandatory secret selection state were incorrect');
            await chooseMergeSource(secretDialog, 'Password secret', 'conflict');
            assertThat(await secretSave.isEnabled(),
              'explicit secret source choice did not enable password merge');
            const secretPushStart = credentialConflictCapture.pushes.length;
            secretMergeStep = 'stage selected secret branch and commit on profile A';
            await savePasswordMerge(secretDialog);
            const secretMerged = await waitForCapture(() =>
              credentialConflictCapture.pushes.slice(secretPushStart).find((item) =>
                item.profile === 'A' && item.recordId === secretCreated.recordId &&
                item.operation === 'update' &&
                item.baseRevisionId === secretConflict.aOperation.revisionId),
            ownerPage, 'same-field secret merge update', 45000);
            await syncNow(ownerPage);
            secretMergeStep = 'pull and resolve secret merge on profile B';
            const secretBChangesStart = apiDiagnostics.length;
            await triggerSyncWithoutWaitingForIdle(secondPage);
            await waitForCapture(() => apiDiagnostics.slice(secretBChangesStart)
              .find((item) => item.profile === 'B' && item.method === 'GET' &&
                item.path.endsWith('/changes') && item.status === 200),
            secondPage, 'profile B secret merge changes pull', 45000);
            const secretResolvedB = await waitForConflictFeedEvent(
              observedConflictFeedEvents.B,
              (event) => event.type === 'resolved' &&
                event.conflictId === secretConflict.conflictId,
              45000,
            );
            assertThat(secretResolvedB.resolvedRevisionId === secretMerged.revisionId &&
              !secretResolvedB.hasEnvelope,
            'profile B did not observe the matching envelope-free secret resolution event');
            await syncNow(secondPage);
            const secretResolutionPath = new RegExp(
              `/conflicts/${escapeRegExp(secretConflict.conflictId)}/resolve$`,
            );
            const secretResolutionResponse = await waitForCapture(() =>
              credentialConflictCapture.resolutionResponses.find((item) =>
                item.profile === 'A' && secretResolutionPath.test(item.path) &&
                item.status === 200), ownerPage, 'secret merge resolution response', 45000);
            const secretResolutionRequests = credentialConflictCapture.resolutionRequests
              .filter((item) => secretResolutionPath.test(item.path));
            const secretResolutionResponses = credentialConflictCapture.resolutionResponses
              .filter((item) => secretResolutionPath.test(item.path));
            assertThat(secretResolutionResponse.method === 'POST' &&
              secretResolutionResponse.markersAbsent &&
              secretResolutionRequests.length === 1 &&
              secretResolutionRequests[0].method === 'POST' &&
              secretResolutionRequests[0].markersAbsent &&
              secretResolutionResponses.length === 1,
            'secret merge did not resolve its conflict exactly once without plaintext');
            const secretResolvedA = await waitForConflictFeedEvent(
              observedConflictFeedEvents.A,
              (event) => event.type === 'resolved' &&
                event.conflictId === secretConflict.conflictId,
            );
            assertThat(secretResolvedA.resolvedRevisionId === secretMerged.revisionId &&
              !secretResolvedA.hasEnvelope,
            'profile A did not observe the matching envelope-free secret resolution event');
            await click(ownerPage, 'Credentials');
            await dismissCredentialEditorForConvergence(secondPage, 'B');
            await click(secondPage, 'Credentials');
            secretMergeStep = 'verify decrypted secret convergence on both profiles';
            console.log('credential secret record wait', JSON.stringify({
              profile: 'A', recordSlot: 'merged', expectedPresent: true,
            }));
            await waitForCredentialRecord(ownerPage, secretName, true);
            console.log('credential secret record wait', JSON.stringify({
              profile: 'B', recordSlot: 'merged', expectedPresent: true,
            }));
            await waitForCredentialRecord(secondPage, secretName, true);
            for (const [page, profile] of [[ownerPage, 'A'], [secondPage, 'B']]) {
              await openCredentialMenuAction(page, secretName, 'Edit');
              const nameMatches =
                await focusedFieldValue(page, 'Credential name') === secretName;
              const usernameMatches =
                await focusedFieldValue(page, 'SSH username') === secretUser;
              const passwordMatches =
                await focusedFieldValue(page, 'Password') === secretB;
              const selectedFieldsMatch = nameMatches && usernameMatches && passwordMatches;
              console.log('credential secret decrypted merge check', JSON.stringify({
                profile,
                nameMatches,
                usernameMatches,
                passwordMatches,
                selectedFieldsMatch,
              }));
              if (!selectedFieldsMatch) {
                const serverState = serverCredentialRevisionFeedSnapshot(
                  databasePath, vaultId, secretMerged.recordId, secretMerged.revisionId,
                );
                const matchingPushReceipts = apiDiagnostics
                  .slice(secretPushStart)
                  .filter((item) => item.method === 'POST' &&
                    item.path.endsWith('/sync/push'))
                  .flatMap((item) => (item.pushReceiptSummary?.results || [])
                    .filter((receipt) => receipt.opId === secretMerged.opId &&
                      receipt.revisionId === secretMerged.revisionId)
                    .map((receipt) => ({
                      profile: item.profile,
                      status: item.status,
                      matchingReceipt: true,
                      commitSeq: receipt.commitSeq,
                      alreadyCommitted: receipt.alreadyCommitted,
                    })));
                console.log('credential secret merge sanitized server evidence', JSON.stringify({
                  profile,
                  matchingPushReceipts,
                  serverState: {
                    querySucceeded: serverState.querySucceeded === true,
                    versionCount: serverState.versionCount ?? null,
                    versionCommitSeqs: serverState.versionCommitSeqs ?? [],
                    eventCount: serverState.eventCount ?? null,
                    eventCommitSeqs: serverState.eventCommitSeqs ?? [],
                    receiptCount: serverState.receiptCount ?? null,
                    receiptCommitSeqs: serverState.receiptCommitSeqs ?? [],
                    headMatches: serverState.headMatches ?? false,
                    vaultMaxChangeSeq: serverState.vaultMaxChangeSeq ?? null,
                    vaultCounterSeq: serverState.vaultCounterSeq ?? null,
                  },
                }));
              }
              assertThat(selectedFieldsMatch,
              `profile ${profile} did not converge on the explicitly selected password`);
              await click(page, 'Cancel');
            }
            const secretAuditMarkers = rememberMergeMarkers(secretMergeMarkers);
            const secretCommit = await assertMergeCommit({
              created: secretCreated,
              firstUpdate: secretConflict.aOperation,
              merged: secretMerged,
              branch: secretConflict.branch,
              conflictId: secretConflict.conflictId,
              expectedVersionCount: 3,
              markers: secretAuditMarkers,
            });

            const allMergeMarkers = [...new Set(mergeMarkerSets)];
            const mergeHttpChecks = [
              ...credentialConflictCapture.httpRequestChecks,
              ...credentialConflictCapture.httpResponseChecks,
            ];
            const mergeBrowserChecks = credentialConflictCapture.browserLogChecks;
            assertThat(mergeHttpChecks.length > 0 &&
              mergeHttpChecks.every((item) => item.markersAbsent) &&
              credentialConflictCapture.httpResponseChecks.every((item) =>
                item.bodyReadable) &&
              mergeBrowserChecks.length >= 2 &&
              mergeBrowserChecks.every((item) => item.markersAbsent),
            'merge HTTP bodies or captured browser logs contained a secret marker');
            const mergeDatabaseMarkers = serverDatabasePlaintextMarkers(
              databasePath, allMergeMarkers,
            );
            assertThat(mergeDatabaseMarkers.length === 0,
              'server SQLite/WAL/SHM contained a merge Credential marker');
            const serverLogEvidence = serverLogPlaintextMarkerEvidence(
              path.join(tempRoot, 'server.log'), allMergeMarkers,
            );
            assertThat(serverLogEvidence.available && serverLogEvidence.markerAbsent,
              'captured server log contained a merge Credential marker');
            assertThat(credentialConflictCapture.pushes.filter((item) =>
              [fieldCreated.recordId, secretCreated.recordId].includes(item.recordId))
              .every((item) => item.requestBodyPlaintextMarkersAbsent &&
                item.plaintextMarkersAbsent && item.exactEnvelopeShape &&
                item.metadataOnlyHeader && item.encodedCiphertextFields) &&
              credentialConflictCapture.branchUploads.filter((item) =>
                [fieldCreated.recordId, secretCreated.recordId].includes(item.recordId))
                .every((item) => item.requestBodyPlaintextMarkersAbsent &&
                  item.plaintextMarkersAbsent && item.exactEnvelopeShape &&
                  item.metadataOnlyHeader && item.encodedCiphertextFields),
            'merge sync or conflict envelopes exposed a marker');
            assertThat(pageErrors.length === 0 && cspViolations.length === 0,
              'Credential field merge acceptance observed browser errors or CSP violations');
            credentialConflictCapture.active = false;
            credentialSyncCapture.active = false;
            console.log('WEB-CREDENTIAL-FIELD-MERGE-01 passed', JSON.stringify({
              oneFieldPerProfileMerge: true,
              staleReviewRejectedWithoutArtifacts: true,
              staleReviewCreatedNoPushOrResolution: true,
              sameFieldSecretRequiredExplicitChoice: true,
              profilesConverged: true,
              fieldMergeCommittedRevisions: fieldCommit.record.versionCount,
              secretMergeCommittedRevisions: secretCommit.record.versionCount,
              fieldMergeResolvedAuditCount: 1,
              secretMergeResolvedAuditCount: 1,
              httpAndBrowserMarkerChecks: mergeHttpChecks.length + mergeBrowserChecks.length,
              sqliteWalShmMarkers: mergeDatabaseMarkers.length,
              serverLogAvailable: serverLogEvidence.available,
              serverLogMarkersAbsent: serverLogEvidence.markerAbsent,
            }));
          } catch (error) {
            console.log('Credential same-field secret merge sanitized failure summary', JSON.stringify({
              step: secretMergeStep,
              errorClass: safeErrorClass(error),
              errorCategory: safeErrorTextClass(error),
              A: await safePageDiagnostic(ownerPage),
              B: await safePageDiagnostic(secondPage),
            }));
            throw error;
          }
        } catch (error) {
          console.log('Credential one-field-per-profile merge sanitized failure summary', JSON.stringify({
            step: fieldMergeStep,
            errorClass: safeErrorClass(error),
            errorCategory: safeErrorTextClass(error),
            A: await safePageDiagnostic(ownerPage),
            B: await safePageDiagnostic(secondPage),
            ownerTab: await safePageDiagnostic(ownerTabPage),
          }));
          throw error;
        }

        credentialConflictCapture.active = false;
        credentialSyncCapture.active = false;
        console.log('WEB-CREDENTIAL-CONFLICT-01 passed', JSON.stringify({
          concurrentProfiles: 2,
          sameCredentialRecord: true,
          conflictBranchPreserved: conflictSnapshot.matchingConflictCount === 1,
          staleBranchNeverCommitted: conflictSnapshot.staleOperationReceiptCount === 0 &&
            conflictSnapshot.staleRevisionVersionCount === 0 &&
            conflictSnapshot.staleRevisionEventCount === 0,
          adoptedBranchResignedByA: true,
          bothProfilesDecryptAndConverge: true,
          committedCredentialRevisions: credential.versionCount,
          receiptsPerCommittedRevision: credential.operations.map((item) =>
            item.receiptCount),
          serverPlaintextMarkers: plaintextMarkersFound.length,
          conflictResolutionEventsWithoutEnvelope: capturedResolved.length,
        }));
        return;
      } catch (error) {
        console.log('Credential conflict acceptance sanitized failure summary', JSON.stringify({
          step: conflictStep,
          errorClass: safeErrorClass(error),
          errorCategory: safeErrorTextClass(error),
          A: await safePageDiagnostic(ownerPage),
          B: await safePageDiagnostic(secondPage),
          api: safeApiSummary(apiDiagnostics, 24).map(({ profile, method, path, status }) => ({
            profile, method, path, status,
          })),
          browserPageErrorCount: pageErrors.length,
          cspViolationCount: cspViolations.length,
        }));
        throw error;
      }
    }

    if (GROUPS_ONLY) {
      const groupBranchApiStart = apiDiagnostics.length;
      let groupMutationStep = 'initialize group acceptance';
      let groupDiagnosticPage = ownerPage;
      let groupDiagnosticProfile = 'A';
      try {
      const databasePath = path.join(dataDir, 'atermius.db');
      const baseline = serverVaultSnapshot(databasePath, USERNAME);
      assertThat(baseline.vaults.length === 1,
        'Vault Group acceptance did not find exactly one active Vault');
      const vaultId = baseline.vaults[0].vaultId;
      const suffix = RUN_ID.slice(0, 8);
      const parentName = `E2E Parent ${suffix}`;
      const childName = `E2E Child ${suffix}`;
      const updatedChildName = `E2E Child Updated ${suffix}`;
      const hostName = `E2E Group Host ${suffix}`;
      const hostAddress = '198.51.100.93';
      const hostUsername = `e2e-group-${suffix}`;
      const bastionName = `E2E Bastion ${suffix}`;
      const bastionAddress = '198.51.100.94';
      const bastionUsername = `e2e-bastion-${suffix}`;
      const graphAlphaName = `E2E Cycle Alpha ${suffix}`;
      const graphBetaName = `E2E Cycle Beta ${suffix}`;
      const inheritedCredentialName = `E2E Parent Credential ${suffix}`;
      const inheritedCredentialUsername = `e2e-inherited-user-${suffix}`;
      const inheritedCredentialSecret = `e2e-inherited-secret-${RUN_ID}`;
      const danglingGroupName = `E2E Deleted Group ${suffix}`;
      const danglingHostName = `E2E Dangling Group Host ${suffix}`;
      const danglingHostAddress = '198.51.100.95';
      const danglingHostUsername = `e2e-dangling-${suffix}`;
      groupSyncCapture.markers = [
        parentName,
        childName,
        updatedChildName,
        hostName,
        hostAddress,
        hostUsername,
        bastionName,
        bastionAddress,
        bastionUsername,
        graphAlphaName,
        graphBetaName,
        'jump_host_id',
        inheritedCredentialName,
        inheritedCredentialUsername,
        inheritedCredentialSecret,
        danglingGroupName,
        danglingHostName,
        danglingHostAddress,
        danglingHostUsername,
      ];
      groupSyncCapture.active = true;

      const pushOperations = (pushes) => pushes.flatMap((push) =>
        push.operations.map((operation) => ({
          ...operation,
          profile: push.profile,
          vaultId: push.vaultId,
          deviceId: push.deviceId,
          bodyShapeValid: push.bodyShapeValid,
          requestPlaintextMarkersAbsent: push.plaintextMarkersAbsent,
        })));
      const dropdownValueEvidence = async (page, fieldLabel, expectedValue) =>
        page.evaluate(({ expectedField, expectedValue }) => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const nodes = [...document.querySelectorAll('flt-semantics')]
            .filter((element) => visible(element))
            .map((element) => ({
              role: element.getAttribute('role') || '',
              text: `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''} ${element.getAttribute('title') || ''}`
                .replace(/\s+/g, ' ').trim(),
            }));
          const fieldControls = nodes.filter((item) =>
            ['button', 'combobox', 'listbox'].includes(item.role) &&
            item.text.toLowerCase().includes(expectedField.toLowerCase()));
          const fieldValueCategory = fieldControls.some((item) =>
            item.text.includes(expectedValue)) ? 'expected'
            : fieldControls.some((item) => /no group/i.test(item.text))
              ? 'no-group'
              : fieldControls.some((item) => /unavailable group/i.test(item.text))
                ? 'unavailable-group'
                : fieldControls.length === 0 ? 'field-not-found' : 'other';
          return {
            fieldControlCount: fieldControls.length,
            fieldControlShowsExpectedValue: fieldControls.some((item) =>
              item.text.includes(expectedValue)),
            matchingFieldControlCount: fieldControls.filter((item) =>
              item.text.includes(expectedValue)).length,
            fieldValueCategory,
          };
        }, { expectedField: fieldLabel, expectedValue }).catch(() => ({
        fieldControlCount: 0,
        fieldControlShowsExpectedValue: false,
        matchingFieldControlCount: 0,
        fieldValueCategory: 'diagnostic-unavailable',
        diagnosticUnavailable: true,
      }));
      const groupEditorValueEvidence = async (page, expectedValue) =>
        page.evaluate((expectedValue) => {
          const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            if (rect.width <= 0 || rect.height <= 0 || style.display === 'none' ||
                style.visibility === 'hidden' || Number(style.opacity || '1') <= 0) {
              return false;
            }
            let left = Math.max(rect.left, 0);
            let top = Math.max(rect.top, 0);
            let right = Math.min(rect.right, window.innerWidth);
            let bottom = Math.min(rect.bottom, window.innerHeight);
            for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
              const ancestorStyle = getComputedStyle(ancestor);
              if (ancestorStyle.display === 'none' ||
                  ancestorStyle.visibility === 'hidden' ||
                  Number(ancestorStyle.opacity || '1') <= 0 ||
                  ancestor.getAttribute('aria-hidden') === 'true') return false;
              const clipRect = ancestor.getBoundingClientRect();
              if (/(hidden|clip|auto|scroll)/.test(ancestorStyle.overflowX)) {
                left = Math.max(left, clipRect.left);
                right = Math.min(right, clipRect.right);
              }
              if (/(hidden|clip|auto|scroll)/.test(ancestorStyle.overflowY)) {
                top = Math.max(top, clipRect.top);
                bottom = Math.min(bottom, clipRect.bottom);
              }
            }
            return right > left && bottom > top;
          };
          const nodes = [...document.querySelectorAll(
            '[role="dialog"], [role="alertdialog"]',
          )];
          const dialogs = nodes.filter((dialog) => {
            const content = [dialog, ...dialog.querySelectorAll(
              'flt-semantics, [aria-label], [title], [role], button, span, div',
            )].filter(visible).map((element) => [
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.innerText,
              element.textContent,
            ].map(normalize).filter(Boolean)).flat();
            return content.includes('Edit host');
          });
          const dialog = dialogs[0] || (nodes.length === 1 ? nodes[0] : null);
          if (!dialog) return {
            alertDialogNodeCount: nodes.length,
            matchingEditDialogCount: dialogs.length,
            editTitleCount: 0,
            groupFieldCount: 0,
            groupLabelCount: 0,
            expectedGroupCount: 0,
            expectedGroupVisible: false,
            noGroupVisible: false,
            unavailableGroupVisible: false,
            expectedGroupSubstringVisible: false,
            saveHostButtonCount: 0,
            cancelButtonCount: 0,
          };
          const descendants = [dialog, ...dialog.querySelectorAll(
            'flt-semantics, [aria-label], [title], [role], button, span, div',
          )].filter(visible);
          const valuesByNode = descendants.map((element) => ({
            element,
            values: [
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.innerText,
              element.textContent,
            ].map(normalize).filter(Boolean),
          }));
          const exactCount = (value) => valuesByNode.filter(({ values }) =>
            values.includes(value)).length;
          const groupFieldCount = valuesByNode.filter(({ element, values }) =>
            element.getAttribute('role') === 'button' &&
            values.some((value) => value.includes('Group'))).length;
          const buttonCount = (buttonLabel) => valuesByNode.filter(({ element, values }) =>
            element.getAttribute('role') === 'button' &&
            values.some((value) => value === buttonLabel)).length;
          return {
            alertDialogNodeCount: nodes.length,
            matchingEditDialogCount: dialogs.length,
            editTitleCount: exactCount('Edit host'),
            groupFieldCount,
            groupLabelCount: exactCount('Group'),
            expectedGroupCount: exactCount(expectedValue),
            expectedGroupVisible: exactCount(expectedValue) > 0,
            noGroupVisible: exactCount('No group') > 0,
            unavailableGroupVisible: exactCount('Unavailable group') > 0,
            expectedGroupSubstringVisible: valuesByNode.some(({ values }) =>
              values.some((value) => value.includes(expectedValue))),
            saveHostButtonCount: buttonCount('Save encrypted host'),
            cancelButtonCount: buttonCount('Cancel'),
          };
        }, expectedValue).catch(() => ({
          alertDialogNodeCount: 0,
          matchingEditDialogCount: 0,
          editTitleCount: 0,
          groupFieldCount: 0,
          groupLabelCount: 0,
          expectedGroupCount: 0,
          expectedGroupVisible: false,
          noGroupVisible: false,
          unavailableGroupVisible: false,
          expectedGroupSubstringVisible: false,
          saveHostButtonCount: 0,
          cancelButtonCount: 0,
          diagnosticUnavailable: true,
        }));
      const visibleGroupRelationshipEvidence = async (page, expectedParentName) =>
        page.evaluate((expectedParent) => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const texts = [...document.querySelectorAll('flt-semantics')]
            .filter((element) => visible(element))
            .map((element) =>
              `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
                .replace(/\s+/g, ' ').trim());
          const combined = `${document.body.innerText || ''}\n${texts.join('\n')}`;
          return {
            visibleParentRelationNodeCount: texts.filter((text) => /\bInside\b/i.test(text)).length,
            visibleHostCountNodeCount: texts.filter((text) =>
              /\b\d+\s+hosts?\b/i.test(text)).length,
            visibleOneHostNodeCount: texts.filter((text) =>
              /\b1\s+host\b/i.test(text)).length,
            expectedParentRelationVisible: combined.includes(`Inside ${expectedParent}`),
            oneHostCountVisible: /\b1\s+host\b/i.test(combined),
          };
        }, expectedParentName).catch(() => ({
          visibleParentRelationNodeCount: 0,
          visibleHostCountNodeCount: 0,
          visibleOneHostNodeCount: 0,
          expectedParentRelationVisible: false,
          oneHostCountVisible: false,
          diagnosticUnavailable: true,
        }));
      const graphRepairEvidence = async (page, alphaName, betaName) =>
        page.evaluate(({ alphaName, betaName }) => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const texts = [...document.querySelectorAll('flt-semantics')]
            .filter(visible)
            .map((element) => ({
              role: element.getAttribute('role') || '',
              text: `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
                .replace(/\s+/g, ' ').trim(),
            }));
          const combined = [document.body.innerText || '',
            ...texts.map((item) => item.text)].join('\n');
          return {
            alphaVisible: combined.includes(alphaName),
            betaVisible: combined.includes(betaName),
            affectedRepairRowCount: texts.filter((item) =>
              item.text.includes('Parent relationship needs repair')).length,
            repairWarningVisible: combined.includes('are missing or cyclic.'),
            repairButtonVisible: texts.some((item) => item.role === 'button' &&
              item.text.includes('Repair a group')),
          };
        }, { alphaName, betaName }).catch(() => ({
          alphaVisible: false,
          betaVisible: false,
          affectedRepairRowCount: 0,
          repairWarningVisible: false,
          repairButtonVisible: false,
          diagnosticUnavailable: true,
        }));
      const runGroupMutation = async (stage, page, profile, expectedOperation, action) => {
        activeStage = `Vault Group acceptance: ${stage}`;
        groupDiagnosticPage = page;
        groupDiagnosticProfile = profile;
        groupMutationStep = 'perform mutation action';
        const firstPushIndex = groupSyncCapture.pushes.length;
        await action();
        groupMutationStep = 'wait for encrypted sync to become idle';
        await syncNow(page);
        groupMutationStep = 'capture and deduplicate encrypted push operation';
        const deadline = Date.now() + 15000;
        let captured = [];
        while (Date.now() < deadline) {
          const byOperationId = new Map();
          for (const operation of pushOperations(
            groupSyncCapture.pushes.slice(firstPushIndex),
          )) {
            if (!byOperationId.has(operation.opId)) {
              byOperationId.set(operation.opId, operation);
            } else {
              const previous = byOperationId.get(operation.opId);
              assertThat(previous.envelopeSha256 === operation.envelopeSha256 &&
                previous.recordId === operation.recordId &&
                previous.revisionId === operation.revisionId,
              'Vault Group retry changed an operation identity or encrypted envelope');
            }
          }
          captured = [...byOperationId.values()];
          if (captured.some((operation) => operation.profile === profile)) break;
          await page.waitForTimeout(100);
        }
        groupMutationStep = 'validate captured operation identity and Vault';
        assertThat(captured.length === 1 && captured[0].profile === profile &&
          captured[0].operation === expectedOperation &&
          captured[0].vaultId === vaultId,
        `Vault Group ${stage} did not produce one encrypted ${expectedOperation} operation`);
        return captured[0];
      };
      const waitForGroupPush = async (
        firstPushIndex,
        profile,
        recordId,
        expectedOperation,
      ) => {
        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
          const matches = pushOperations(
            groupSyncCapture.pushes.slice(firstPushIndex),
          ).filter((item) => item.profile === profile &&
            item.recordId === recordId && item.operation === expectedOperation);
          const byOperationId = new Map();
          for (const item of matches) {
            const previous = byOperationId.get(item.opId);
            if (previous) {
              assertThat(previous.envelopeSha256 === item.envelopeSha256 &&
                previous.revisionId === item.revisionId &&
                previous.baseRevisionId === item.baseRevisionId,
              'Group retry changed an offline graph operation or envelope');
            } else {
              byOperationId.set(item.opId, item);
            }
          }
          if (byOperationId.size > 0) {
            assertThat(byOperationId.size === 1,
              'one offline Group edit produced multiple encrypted operations');
            return [...byOperationId.values()][0];
          }
          await ownerPage.waitForTimeout(100);
        }
        throw new Error(`profile ${profile} did not push its offline Group ${expectedOperation}`);
      };
      const waitForSingleGroupPush = async (
        firstPushIndex,
        profile,
        expectedOperation,
      ) => {
        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
          const byOperationId = new Map();
          for (const item of pushOperations(
            groupSyncCapture.pushes.slice(firstPushIndex),
          ).filter((candidate) => candidate.profile === profile &&
            candidate.operation === expectedOperation)) {
            const previous = byOperationId.get(item.opId);
            if (previous) {
              assertThat(previous.envelopeSha256 === item.envelopeSha256 &&
                previous.recordId === item.recordId &&
                previous.revisionId === item.revisionId &&
                previous.baseRevisionId === item.baseRevisionId,
              'a retried Group acceptance operation changed its identity or envelope');
            } else {
              byOperationId.set(item.opId, item);
            }
          }
          if (byOperationId.size > 0) {
            assertThat(byOperationId.size === 1,
              `profile ${profile} produced multiple ${expectedOperation} operations`);
            return [...byOperationId.values()][0];
          }
          await ownerPage.waitForTimeout(100);
        }
        throw new Error(
          `profile ${profile} did not push one ${expectedOperation} operation`,
        );
      };
      const waitForPull = async (operation, receiver, origin) => {
        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
          if (groupSyncCapture.pulls.some((item) =>
            item.profile === receiver && item.originProfile === origin &&
            item.opId === operation.opId && item.recordId === operation.recordId &&
            item.revisionId === operation.revisionId)) return;
          await ownerPage.waitForTimeout(100);
        }
        throw new Error(`profile ${receiver} did not pull the encrypted Vault Group operation`);
      };
      const openGroupActions = async (page, name) => {
        const actions = page.getByRole('button', {
          name: `Group actions: ${name}`,
          exact: true,
        }).last();
        await actions.waitFor({ state: 'visible', timeout: 10000 });
        await actions.click();
      };
      const assertReferenceBlocked = async (page, name, expectedReferenceText) => {
        groupDiagnosticPage = page;
        groupDiagnosticProfile = page === secondPage ? 'B' : 'A';
        groupMutationStep = 'open referenced Group actions menu';
        await openGroupActions(page, name);
        groupMutationStep = 'open referenced Group delete confirmation';
        await clickMenuItem(page, 'Delete group');
        groupMutationStep = 'inspect referenced Group delete protection';
        await waitForText(page, 'Delete group?');
        const dialogText = await page.locator('body').innerText();
        assertThat(dialogText.includes(expectedReferenceText),
          'referenced Vault Group deletion did not explain the blocking references');
        const confirm = page.getByRole('button', {
          name: 'Delete group', exact: true,
        }).last();
        await confirm.waitFor({ state: 'visible', timeout: 10000 });
        assertThat(!(await confirm.isEnabled()),
          'referenced Vault Group deletion confirmation was enabled');
        groupMutationStep = 'cancel referenced Group delete confirmation';
        await click(page, 'Cancel');
      };
      const inheritedCredentialTextEvidence = async (
        page,
        sourceGroupName,
        credentialName,
        credentialUsername,
      ) => {
        const expected = `Inherited from ${sourceGroupName}: ${credentialName} · ${credentialUsername}`;
        const deadline = Date.now() + 10000;
        let evidence = { expectedTextVisible: false, matchingNodeCount: 0 };
        while (Date.now() < deadline) {
          evidence = await page.evaluate((expectedText) => {
            const visible = (element) => {
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            const nodes = [...document.querySelectorAll('flt-semantics')]
              .filter(visible)
              .map((element) =>
                `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
                  .replace(/\s+/g, ' ').trim());
            const bodyText = document.body.innerText || '';
            const matchingNodeCount = nodes.filter((text) =>
              text.includes(expectedText)).length;
            return {
              expectedTextVisible: bodyText.includes(expectedText) || matchingNodeCount > 0,
              matchingNodeCount,
            };
          }, expected).catch(() => ({
            expectedTextVisible: false,
            matchingNodeCount: 0,
            diagnosticUnavailable: true,
          }));
          if (evidence.expectedTextVisible) return evidence;
          await page.waitForTimeout(100);
        }
        return evidence;
      };
      const assertCredentialDecryptedOnProfile = async (page, profile) => {
        groupDiagnosticPage = page;
        groupDiagnosticProfile = profile;
        groupMutationStep = `open ${profile} Credentials to verify decrypted password record`;
        await openCredentialsPage(page);
        await waitForCredentialRecord(page, inheritedCredentialName, true);
        groupMutationStep = `open ${profile} inherited Credential editor`;
        await openCredentialMenuAction(page, inheritedCredentialName, 'Edit');
        await waitForSemanticText(page, 'Edit credential');
        groupMutationStep = `read ${profile} decrypted Credential fields`;
        const nameValue = await focusedFieldValue(page, 'Credential name');
        const usernameValue = await focusedFieldValue(page, 'SSH username');
        const secretValue = await focusedFieldValue(page, 'Password');
        const evidence = {
          profile,
          nameMatches: nameValue === inheritedCredentialName,
          usernameMatches: usernameValue === inheritedCredentialUsername,
          secretMatches: secretValue === inheritedCredentialSecret,
          nameLength: nameValue.length,
          usernameLength: usernameValue.length,
          secretLength: secretValue.length,
        };
        console.log('WEB-GROUPS-CREDENTIAL-DECRYPTION-EVIDENCE', JSON.stringify(evidence));
        assertThat(evidence.nameMatches && evidence.usernameMatches && evidence.secretMatches,
          `profile ${profile} did not decrypt the inherited Credential record`);
        groupMutationStep = `close ${profile} Credential editor without mutation`;
        await click(page, 'Cancel');
      };
      const assertDecryptedRelationships = async (
        page,
        profile,
        groupName,
        expectedJumpHostOption,
      ) => {
        const summaryEvidence = await groupRowEvidence(page, groupName, parentName);
        const parentVisibleEvidence = await visibleGroupRelationshipEvidence(
          page,
          parentName,
        );

        groupMutationStep = `open ${profile} parent Group editor to inspect default Credential`;
        await openGroupActions(page, parentName);
        const parentMenuEvidence = await clickMenuItem(page, 'Edit group');
        await waitForSemanticText(page, 'Edit host group');
        const parentCredentialEvidence = await dropdownValueEvidence(
          page,
          'Default SSH credential',
          inheritedCredentialName,
        );
        await click(page, 'Cancel');
        assertThat(parentCredentialEvidence.fieldControlShowsExpectedValue,
          `profile ${profile} did not decrypt the parent Group default Credential`);

        groupMutationStep = `open ${profile} child Group editor to inspect decrypted Parent selection`;
        await openGroupActions(page, groupName);
        const groupMenuEvidence = await clickMenuItem(page, 'Edit group');
        await waitForSemanticText(page, 'Edit host group');
        groupMutationStep = `read ${profile} child Group Parent selection`;
        const parentFieldEvidence = await dropdownValueEvidence(
          page,
          'Parent group',
          parentName,
        );
        const childDefaultEvidence = await dropdownValueEvidence(
          page,
          'Default SSH credential',
          'No default credential',
        );
        groupMutationStep = `cancel ${profile} child Group editor without mutation`;
        await click(page, 'Cancel');
        assertThat(parentFieldEvidence.fieldControlShowsExpectedValue &&
          childDefaultEvidence.fieldControlShowsExpectedValue,
        `profile ${profile} decrypted child Group with an unexpected Parent or default Credential`);

        groupMutationStep = `navigate ${profile} to Hosts to inspect assigned Host`;
        await click(page, 'Hosts');
        await waitForHostRecord(page, hostName, true, `${hostAddress}:22`);
        const hostCard = hostCardGroup(page, hostName);
        groupMutationStep = `open ${profile} Host editor to inspect decrypted Group selection`;
        await hostCard.getByRole('button', { name: 'Edit host', exact: true }).click();
        await waitForText(page, 'Edit host');
        const hostEditorOpened = true;
        groupMutationStep = `read ${profile} Host Group selection`;
        const hostFieldEvidence = await dropdownValueEvidence(
          page,
          'Group',
          groupName,
        );
        const overrideEvidence = await dropdownValueEvidence(
          page,
          'SSH credential override',
          'Inherit from Group',
        );
        groupMutationStep = `verify ${profile} decrypted Host Jump Host selection`;
        await chooseDropdownOption(
          page,
          'Jump Host',
          expectedJumpHostOption,
        );
        const jumpHostEvidence = await dropdownValueEvidence(
          page,
          'Jump Host',
          expectedJumpHostOption,
        );
        const inheritedTextEvidence = await inheritedCredentialTextEvidence(
          page,
          parentName,
          inheritedCredentialName,
          inheritedCredentialUsername,
        );
        groupMutationStep = `cancel ${profile} Host editor without mutation`;
        await click(page, 'Cancel');
        assertThat(hostFieldEvidence.fieldControlShowsExpectedValue &&
          overrideEvidence.fieldControlShowsExpectedValue &&
          inheritedTextEvidence.expectedTextVisible &&
          jumpHostEvidence.fieldControlShowsExpectedValue,
        `profile ${profile} Host did not resolve its Group credential and Jump Host route`);

        console.log('WEB-GROUPS-DECRYPTED-RELATIONSHIP-EVIDENCE', JSON.stringify({
          profile,
          groupRecordIdsCaptured: parentOperation.recordId !== childOperation.recordId &&
            childOperation.recordId !== hostOperation.recordId,
          groupMenuInteraction: groupMenuEvidence.interaction,
          groupMenuMatchCount: groupMenuEvidence.matchingItemCount,
          parentGroupMenuInteraction: parentMenuEvidence.interaction,
          parentCredentialEvidence,
          groupEditorOpened: true,
          parentFieldEvidence,
          childDefaultEvidence,
          hostVisible: true,
          hostEditorOpened,
          hostFieldEvidence,
          overrideEvidence,
          jumpHostEvidence,
          inheritedCredentialTextEvidence: inheritedTextEvidence,
          visibleListSummaryOptional: {
            hasParent: summaryEvidence.summaryHasParent,
            hasOneHost: summaryEvidence.summaryHasOneHost,
            parentRelationNodeCount: parentVisibleEvidence.visibleParentRelationNodeCount,
            oneHostCountNodeCount: parentVisibleEvidence.visibleOneHostNodeCount,
          },
        }));
        groupMutationStep = `return ${profile} to Groups after relationship checks`;
        await click(page, 'Groups');
        await waitForSemanticText(page, groupName);
      };

      activeStage = 'Vault Group acceptance: create inherited Credential on A';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      await openCredentialsPage(ownerPage);
      const inheritedCredentialOperation = await runGroupMutation(
        'create inherited Credential on A', ownerPage, 'A', 'create', async () => {
          groupMutationStep = 'open inherited Credential form on A';
          await click(ownerPage, 'Add credential');
          groupMutationStep = 'wait for inherited Credential editor on A';
          await waitForSemanticText(ownerPage, 'New SSH credential');
          groupMutationStep = 'fill inherited Credential name on A';
          await fill(ownerPage, 'Credential name', inheritedCredentialName);
          groupMutationStep = 'fill inherited Credential username on A';
          await fill(ownerPage, 'SSH username', inheritedCredentialUsername);
          groupMutationStep = 'fill inherited Credential secret on A';
          await fill(ownerPage, 'Password', inheritedCredentialSecret);
          groupMutationStep = 'save encrypted inherited Credential on A';
          await click(ownerPage, 'Save encrypted credential');
          groupMutationStep = 'wait for inherited Credential render on A';
          await waitForCredentialRecord(ownerPage, inheritedCredentialName, true);
        },
      );

      activeStage = 'Vault Group acceptance: open A Groups workspace';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'open A Groups workspace';
      await click(ownerPage, 'Groups');
      groupMutationStep = 'wait for A Groups workspace';
      await waitForText(ownerPage, 'Host groups');
      const parentOperation = await runGroupMutation(
        'create parent group on A', ownerPage, 'A', 'create', async () => {
          groupMutationStep = 'open New Group dialog on A';
          await click(ownerPage, 'New group');
          groupMutationStep = 'wait for New Group editor on A';
          await waitForSemanticText(ownerPage, 'New host group');
          groupMutationStep = 'fill parent Group name on A';
          await fill(ownerPage, 'Group name', parentName);
          groupMutationStep = 'select parent Group color on A';
          await chooseDropdownOption(ownerPage, 'Color', '#4FC3F7');
          groupMutationStep = 'assign inherited Credential as parent Group default on A';
          await chooseDropdownOption(
            ownerPage,
            'Default SSH credential',
            inheritedCredentialName,
          );
          groupMutationStep = 'save encrypted parent Group on A';
          await click(ownerPage, 'Save encrypted group');
          groupMutationStep = 'wait for parent Group render on A';
          await waitForSemanticText(ownerPage, parentName);
        },
      );

      const childOperation = await runGroupMutation(
        'create child group on A', ownerPage, 'A', 'create', async () => {
          groupMutationStep = 'open New child Group dialog on A';
          await click(ownerPage, 'New group');
          groupMutationStep = 'wait for New child Group editor on A';
          await waitForSemanticText(ownerPage, 'New host group');
          groupMutationStep = 'fill child Group name on A';
          await fill(ownerPage, 'Group name', childName);
          groupMutationStep = 'select Parent group on A';
          await chooseDropdownOption(ownerPage, 'Parent group', parentName);
          groupMutationStep = 'save encrypted child Group on A';
          await click(ownerPage, 'Save encrypted group');
          groupMutationStep = 'wait for child Group render on A';
          await waitForSemanticText(ownerPage, childName);
        },
      );

      activeStage = 'Vault Group acceptance: navigate A to Hosts for assignment';
      groupMutationStep = 'navigate A to Hosts for assignment';
      await click(ownerPage, 'Hosts');
      const bastionOperation = await runGroupMutation(
        'create direct Bastion Host on A', ownerPage, 'A', 'create', async () => {
          groupMutationStep = 'open direct Bastion Host form on A';
          await click(ownerPage, 'Add host');
          groupMutationStep = 'wait for direct Bastion Host form on A';
          await waitForText(ownerPage, 'Add a host');
          groupMutationStep = 'fill direct Bastion Host display name on A';
          await fill(ownerPage, 'Display name', bastionName);
          groupMutationStep = 'fill direct Bastion Host address on A';
          await fill(ownerPage, 'Hostname or IP', bastionAddress);
          groupMutationStep = 'fill direct Bastion Host port on A';
          await fill(ownerPage, 'Port', '22');
          groupMutationStep = 'fill direct Bastion Host username on A';
          await fill(ownerPage, 'SSH username', bastionUsername);
          groupMutationStep = 'save direct Bastion Host on A';
          await click(ownerPage, 'Save encrypted host');
          groupMutationStep = 'wait for direct Bastion Host render on A';
          await waitForHostRecord(
            ownerPage,
            bastionName,
            true,
            `${bastionAddress}:22`,
          );
        },
      );
      const hostOperation = await runGroupMutation(
        'create grouped Host through Bastion on A', ownerPage, 'A', 'create', async () => {
          groupMutationStep = 'open Add host form on A';
          await click(ownerPage, 'Add host');
          groupMutationStep = 'wait for Add host form on A';
          await waitForText(ownerPage, 'Add a host');
          groupMutationStep = 'fill Host Display name on A';
          await fill(ownerPage, 'Display name', hostName);
          groupMutationStep = 'fill Hostname or IP on A';
          await fill(ownerPage, 'Hostname or IP', hostAddress);
          groupMutationStep = 'fill Host Port on A';
          await fill(ownerPage, 'Port', '22');
          groupMutationStep = 'fill Host SSH username on A';
          await fill(ownerPage, 'SSH username', hostUsername);
          groupMutationStep = 'select Host Group dropdown on A';
          await chooseDropdownOption(ownerPage, 'Group', childName);
          groupMutationStep = 'confirm Host inherits Group credential on A';
          await chooseDropdownOption(
            ownerPage,
            'SSH credential override',
            'Inherit from Group',
          );
          groupMutationStep = 'assign direct Bastion Host on A';
          await chooseDropdownOption(
            ownerPage,
            'Jump Host',
            `${bastionName} · ${bastionAddress}:22`,
          );
          groupMutationStep = 'save encrypted Host on A';
          await click(ownerPage, 'Save encrypted host');
          groupMutationStep = 'wait for saved Host render on A';
          await waitForHostRecord(ownerPage, hostName, true, `${hostAddress}:22`);
        },
      );

      const initialGroupOperations = [
        inheritedCredentialOperation,
        parentOperation,
        childOperation,
        bastionOperation,
        hostOperation,
      ];
      assertThat(new Set(initialGroupOperations.map((item) => item.recordId)).size === 5 &&
        initialGroupOperations.every((item) => item.operation === 'create'),
      'Vault Group and Jump Host setup did not produce five distinct encrypted records');
      assertThat(parentOperation.recordId !== childOperation.recordId &&
        childOperation.recordId !== hostOperation.recordId &&
        parentOperation.recordId !== hostOperation.recordId &&
        inheritedCredentialOperation.recordId !== parentOperation.recordId &&
        inheritedCredentialOperation.recordId !== childOperation.recordId &&
        inheritedCredentialOperation.recordId !== bastionOperation.recordId &&
        inheritedCredentialOperation.recordId !== hostOperation.recordId &&
        bastionOperation.recordId !== hostOperation.recordId &&
        childOperation.recordId !== bastionOperation.recordId,
      'Credential, Groups, Bastion, and target Host record IDs were not distinct');

      activeStage = 'Vault Group acceptance: verify A decrypted relationships';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'reopen A Groups workspace';
      await click(ownerPage, 'Groups');
      groupMutationStep = 'verify A decrypted parent and Host references';
      await waitForSemanticText(ownerPage, childName);
      await assertDecryptedRelationships(
        ownerPage,
        'A',
        childName,
        `${bastionName} · ${bastionAddress}:22`,
      );

      activeStage = 'Vault Group acceptance: B pulls records and decrypts graph';
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'sync A Group and Host records to B';
      await syncNow(secondPage);
      groupMutationStep = 'wait for B to pull inherited Credential ciphertext';
      await waitForPull(inheritedCredentialOperation, 'B', 'A');
      groupMutationStep = 'verify B decrypted inherited Credential fields';
      await assertCredentialDecryptedOnProfile(secondPage, 'B');
      groupMutationStep = 'verify decrypted Host on B';
      await click(secondPage, 'Hosts');
      await waitForHostRecord(secondPage, hostName, true, `${hostAddress}:22`);
      groupMutationStep = 'open B Groups workspace';
      await click(secondPage, 'Groups');
      groupMutationStep = 'verify B decrypted parent and Host references';
      await waitForSemanticText(secondPage, parentName);
      await waitForSemanticText(secondPage, childName);
      await assertDecryptedRelationships(
        secondPage,
        'B',
        childName,
        `${bastionName} · ${bastionAddress}:22`,
      );
      for (const operation of initialGroupOperations) {
        await waitForPull(operation, 'B', 'A');
      }

      const updatedOperation = await runGroupMutation(
        'rename child group on B', secondPage, 'B', 'update', async () => {
          groupMutationStep = 'open child Group actions menu on B';
          await openGroupActions(secondPage, childName);
          groupMutationStep = 'select Edit group action on B';
          await clickMenuItem(secondPage, 'Edit group');
          groupMutationStep = 'wait for Edit Group dialog on B';
          await waitForSemanticText(secondPage, 'Edit host group');
          groupMutationStep = 'fill updated child Group name on B';
          await fill(secondPage, 'Group name', updatedChildName);
          groupMutationStep = 'confirm Parent group in editor on B';
          await chooseDropdownOption(secondPage, 'Parent group', parentName);
          groupMutationStep = 'save encrypted child Group update on B';
          await click(secondPage, 'Save encrypted group');
          groupMutationStep = 'wait for updated child Group render on B';
          await waitForSemanticText(secondPage, updatedChildName);
        },
      );
      assertThat(updatedOperation.recordId === childOperation.recordId &&
        updatedOperation.baseRevisionId === childOperation.revisionId &&
        updatedOperation.revisionId !== childOperation.revisionId,
      'profile B Group edit did not update the child record at its captured base revision');

      const updatedHostRouteOperation = await runGroupMutation(
        'clear target Jump Host route on B', secondPage, 'B', 'update', async () => {
          groupMutationStep = 'navigate B to Hosts for Jump Host route edit';
          await click(secondPage, 'Hosts');
          groupMutationStep = 'wait for target Host on B before route edit';
          await waitForHostRecord(
            secondPage,
            hostName,
            true,
            `${hostAddress}:22`,
          );
          const hostCard = hostCardGroup(secondPage, hostName);
          groupMutationStep = 'open target Host editor on B for route edit';
          await hostCard.getByRole('button', {
            name: 'Edit host', exact: true,
          }).click();
          groupMutationStep = 'wait for target Host editor on B';
          await waitForText(secondPage, 'Edit host');
          groupMutationStep = 'clear target Jump Host route on B';
          await chooseDropdownOption(
            secondPage,
            'Jump Host',
            'Direct connection',
          );
          groupMutationStep = 'save encrypted target Host route update on B';
          await click(secondPage, 'Save encrypted host');
          groupMutationStep = 'wait for target Host after route update on B';
          await waitForHostRecord(
            secondPage,
            hostName,
            true,
            `${hostAddress}:22`,
          );
        },
      );
      assertThat(updatedHostRouteOperation.recordId === hostOperation.recordId &&
        updatedHostRouteOperation.baseRevisionId === hostOperation.revisionId &&
        updatedHostRouteOperation.revisionId !== hostOperation.revisionId,
      'profile B Jump Host edit did not update the target Host at its captured base revision');

      activeStage = 'Vault Group acceptance: A receives B update';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'wait for A to render B child Group update';
      await waitForSemanticText(ownerPage, updatedChildName, 30000);
      groupMutationStep = 'verify A pulled B child Group update';
      await waitForPull(updatedOperation, 'A', 'B');
      groupMutationStep = 'wait for A to pull B target Host route update';
      await waitForPull(updatedHostRouteOperation, 'A', 'B');
      groupMutationStep = 'verify decrypted Group and Jump Host updates on A';
      await assertDecryptedRelationships(
        ownerPage,
        'A',
        updatedChildName,
        'Direct connection',
      );

      activeStage = 'Vault Group acceptance: referenced deletion protection';
      await assertReferenceBlocked(
        ownerPage,
        updatedChildName,
        'Move or unassign 1 host(s) and 0 child group(s)',
      );
      await assertReferenceBlocked(
        ownerPage,
        parentName,
        'Move or unassign 0 host(s) and 1 child group(s)',
      );

      activeStage = 'Vault Group acceptance: create cross-device graph baseline';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'create first independent graph Group on A';
      const graphAlphaCreateOperation = await runGroupMutation(
        'create first independent graph Group on A', ownerPage, 'A', 'create', async () => {
          await click(ownerPage, 'New group');
          await waitForSemanticText(ownerPage, 'New host group');
          await fill(ownerPage, 'Group name', graphAlphaName);
          await click(ownerPage, 'Save encrypted group');
          await waitForSemanticText(ownerPage, graphAlphaName);
        },
      );
      groupMutationStep = 'create second independent graph Group on A';
      const graphBetaCreateOperation = await runGroupMutation(
        'create second independent graph Group on A', ownerPage, 'A', 'create', async () => {
          await click(ownerPage, 'New group');
          await waitForSemanticText(ownerPage, 'New host group');
          await fill(ownerPage, 'Group name', graphBetaName);
          await click(ownerPage, 'Save encrypted group');
          await waitForSemanticText(ownerPage, graphBetaName);
        },
      );
      assertThat(graphAlphaCreateOperation.recordId !== graphBetaCreateOperation.recordId,
        'cross-device Group graph baseline did not use independent encrypted records');
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'sync independent graph Groups to B';
      await syncNow(secondPage);
      await waitForPull(graphAlphaCreateOperation, 'B', 'A');
      await waitForPull(graphBetaCreateOperation, 'B', 'A');
      await click(secondPage, 'Groups');
      await waitForSemanticText(secondPage, graphAlphaName);
      await waitForSemanticText(secondPage, graphBetaName);

      activeStage = 'Vault Group acceptance: make different Group edits offline';
      groupMutationStep = 'disconnect both independent profiles';
      await Promise.all([
        ownerContext.setOffline(true),
        secondContext.setOffline(true),
      ]);
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'queue A parent edit while offline';
      await openGroupActions(ownerPage, graphAlphaName);
      await clickMenuItem(ownerPage, 'Edit group');
      await waitForSemanticText(ownerPage, 'Edit host group');
      await chooseDropdownOption(ownerPage, 'Parent group', graphBetaName);
      await click(ownerPage, 'Save encrypted group');
      await waitForSemanticText(ownerPage, `Inside ${graphBetaName}`);

      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'queue B parent edit while offline';
      await openGroupActions(secondPage, graphBetaName);
      await clickMenuItem(secondPage, 'Edit group');
      await waitForSemanticText(secondPage, 'Edit host group');
      await chooseDropdownOption(secondPage, 'Parent group', graphAlphaName);
      await click(secondPage, 'Save encrypted group');
      await waitForSemanticText(secondPage, `Inside ${graphAlphaName}`);

      const alphaPushStart = groupSyncCapture.pushes.length;
      activeStage = 'Vault Group acceptance: commit A offline graph branch';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'reconnect A and sync its distinct Group record';
      await ownerContext.setOffline(false);
      await syncNow(ownerPage);
      const graphAlphaUpdateOperation = await waitForGroupPush(
        alphaPushStart,
        'A',
        graphAlphaCreateOperation.recordId,
        'update',
      );
      assertThat(graphAlphaUpdateOperation.baseRevisionId === graphAlphaCreateOperation.revisionId &&
        graphAlphaUpdateOperation.revisionId !== graphAlphaCreateOperation.revisionId,
      'profile A offline Group edit did not preserve its original record base');

      const betaPushStart = groupSyncCapture.pushes.length;
      activeStage = 'Vault Group acceptance: commit B offline graph branch';
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'reconnect B and capture its distinct Group record push';
      await secondContext.setOffline(false);
      const graphBetaUpdateOperation = await waitForGroupPush(
        betaPushStart,
        'B',
        graphBetaCreateOperation.recordId,
        'update',
      );
      assertThat(graphBetaUpdateOperation.baseRevisionId === graphBetaCreateOperation.revisionId &&
        graphBetaUpdateOperation.revisionId !== graphBetaCreateOperation.revisionId &&
        graphAlphaUpdateOperation.recordId !== graphBetaUpdateOperation.recordId,
      'independent offline Group graph edits were not committed at their distinct captured bases');
      groupMutationStep = 'finish B reconnect sync and reload decrypted Group records';
      await syncNow(secondPage);
      groupMutationStep = 'wait for B to pull A distinct Group graph update';
      await waitForPull(graphAlphaUpdateOperation, 'B', 'A');
      groupMutationStep = 'verify cycle warning after B merges the distinct Group records';
      await waitForSemanticText(secondPage, 'Parent relationship needs repair');
      const graphRepairEvidenceOnB = await graphRepairEvidence(
        secondPage,
        graphAlphaName,
        graphBetaName,
      );
      console.log('WEB-GROUPS-GRAPH-REPAIR-EVIDENCE', JSON.stringify({
        profile: 'B', ...graphRepairEvidenceOnB,
      }));
      await secondPage.getByRole('button', {
        name: 'Repair a group', exact: true,
      }).waitFor({ state: 'visible', timeout: 15000 });
      assertThat(graphRepairEvidenceOnB.alphaVisible &&
        graphRepairEvidenceOnB.betaVisible &&
        graphRepairEvidenceOnB.affectedRepairRowCount >= 2 &&
        graphRepairEvidenceOnB.repairWarningVisible &&
        graphRepairEvidenceOnB.repairButtonVisible,
      'profile B did not surface both synced Group parent links and their repair action');

      activeStage = 'Vault Group acceptance: verify and repair merged graph';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'pull B distinct Group graph branch on A';
      await syncNow(ownerPage);
      await waitForPull(graphBetaUpdateOperation, 'A', 'B');
      groupMutationStep = 'verify cycle warning after A merges the distinct Group records';
      await waitForSemanticText(ownerPage, 'Parent relationship needs repair');
      const graphRepairEvidenceOnA = await graphRepairEvidence(
        ownerPage,
        graphAlphaName,
        graphBetaName,
      );
      console.log('WEB-GROUPS-GRAPH-REPAIR-EVIDENCE', JSON.stringify({
        profile: 'A', ...graphRepairEvidenceOnA,
      }));
      await ownerPage.getByRole('button', {
        name: 'Repair a group', exact: true,
      }).waitFor({ state: 'visible', timeout: 15000 });
      assertThat(graphRepairEvidenceOnA.alphaVisible &&
        graphRepairEvidenceOnA.betaVisible &&
        graphRepairEvidenceOnA.affectedRepairRowCount >= 2 &&
        graphRepairEvidenceOnA.repairWarningVisible &&
        graphRepairEvidenceOnA.repairButtonVisible,
      'profile A did not surface both synced Group parent links and their repair action');
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'open actionable Group graph repair on B';
      const repairButton = secondPage.getByRole('button', {
        name: 'Repair a group', exact: true,
      });
      await repairButton.waitFor({ state: 'visible', timeout: 10000 });
      const repairPushStart = groupSyncCapture.pushes.length;
      await repairButton.click();
      groupMutationStep = 'wait for first affected Group repair editor';
      await waitForSemanticText(secondPage, 'Edit host group');
      groupMutationStep = 'identify Group selected by repair action';
      const repairTargetName = await focusedFieldValue(secondPage, 'Group name');
      const graphRepairBaseOperation = repairTargetName === graphAlphaName
        ? graphAlphaUpdateOperation
        : repairTargetName === graphBetaName
          ? graphBetaUpdateOperation
          : null;
      assertThat(graphRepairBaseOperation != null,
        'Group repair action opened an unrelated Group record');
      groupMutationStep = 'select Top-level group in affected Group editor';
      await chooseDropdownOption(secondPage, 'Parent group', 'Top-level group');
      groupMutationStep = 'save repaired Group parent relationship';
      await click(secondPage, 'Save encrypted group');
      groupMutationStep = 'capture encrypted Group graph repair update';
      const graphRepairOperation = await waitForGroupPush(
        repairPushStart,
        'B',
        graphRepairBaseOperation.recordId,
        'update',
      );
      assertThat(graphRepairOperation.baseRevisionId === graphRepairBaseOperation.revisionId &&
        graphRepairOperation.revisionId !== graphRepairBaseOperation.revisionId,
      'Group graph repair did not update the latest synchronized revision');
      await secondPage.getByRole('button', {
        name: 'Repair a group', exact: true,
      }).waitFor({ state: 'hidden', timeout: 10000 });

      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      groupMutationStep = 'pull Group graph repair on A';
      await syncNow(ownerPage);
      await waitForPull(graphRepairOperation, 'A', 'B');
      await ownerPage.getByRole('button', {
        name: 'Repair a group', exact: true,
      }).waitFor({ state: 'hidden', timeout: 10000 });

      activeStage = 'Vault Group acceptance: prepare a Group for offline stale reference';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      const danglingGroupCreateOperation = await runGroupMutation(
        'create Group for dangling-reference acceptance on A',
        ownerPage,
        'A',
        'create',
        async () => {
          await click(ownerPage, 'New group');
          await waitForSemanticText(ownerPage, 'New host group');
          await fill(ownerPage, 'Group name', danglingGroupName);
          await click(ownerPage, 'Save encrypted group');
          await waitForSemanticText(ownerPage, danglingGroupName);
        },
      );
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      groupMutationStep = 'sync the Group to B before taking B offline';
      await syncNow(secondPage);
      await waitForPull(danglingGroupCreateOperation, 'B', 'A');
      await waitForSemanticText(secondPage, danglingGroupName);

      groupMutationStep = 'take B offline with the old Group cached';
      await secondContext.setOffline(true);
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      const danglingGroupDeleteOperation = await runGroupMutation(
        'delete Group on A while B is offline',
        ownerPage,
        'A',
        'delete',
        async () => {
          await openGroupActions(ownerPage, danglingGroupName);
          await clickMenuItem(ownerPage, 'Delete group');
          await waitForText(ownerPage, 'Delete group?');
          const confirm = ownerPage.getByRole('button', {
            name: 'Delete group', exact: true,
          }).last();
          await confirm.waitFor({ state: 'visible', timeout: 10000 });
          assertThat(await confirm.isEnabled(),
            'unreferenced Group deletion was unexpectedly disabled');
          await confirm.click();
          await ownerPage.getByRole('button', {
            name: `Group actions: ${danglingGroupName}`, exact: true,
          }).waitFor({ state: 'hidden', timeout: 10000 });
        },
      );
      assertThat(danglingGroupDeleteOperation.recordId ===
        danglingGroupCreateOperation.recordId &&
        danglingGroupDeleteOperation.baseRevisionId ===
          danglingGroupCreateOperation.revisionId,
      'A did not tombstone the synced Group at its captured revision');

      activeStage = 'Vault Group acceptance: create a Host against B stale Group offline';
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      const offlineHostPushStart = groupSyncCapture.pushes.length;
      groupMutationStep = 'open Hosts on offline B';
      await click(secondPage, 'Hosts');
      await waitForSemanticText(secondPage, 'Your server fleet');
      const offlineSavedHostsBefore = await visibleSavedHostsCount(secondPage);
      groupMutationStep = 'open Host editor on offline B';
      await click(secondPage, 'Add host');
      await waitForText(secondPage, 'Add a host');
      groupMutationStep = 'fill dangling Host name on offline B';
      await fill(secondPage, 'Display name', danglingHostName);
      await fill(secondPage, 'Hostname or IP', danglingHostAddress);
      await fill(secondPage, 'Port', '22');
      await fill(secondPage, 'SSH username', danglingHostUsername);
      groupMutationStep = 'assign B cached Group to offline Host';
      await chooseDropdownOption(secondPage, 'Group', danglingGroupName);
      const selectedDanglingGroupEvidence = await dropdownValueEvidence(
        secondPage,
        'Group',
        danglingGroupName,
      );
      assertThat(selectedDanglingGroupEvidence.fieldControlShowsExpectedValue &&
        danglingGroupCreateOperation.recordId ===
          danglingGroupDeleteOperation.recordId,
      'offline Host editor did not show the exact cached Group selected for its encrypted reference');
      const offlineHostBaselineSnapshot = await readOfflineGroupHostSnapshot(
        secondPage,
        tempRoot,
        vaultId,
        danglingGroupCreateOperation.recordId,
        groupSyncCapture.markers,
      );
      assertThat(offlineHostBaselineSnapshot.available &&
        offlineHostBaselineSnapshot.integrityCheck === 'ok' &&
        offlineHostBaselineSnapshot.journalEmpty &&
        offlineHostBaselineSnapshot.sqlitePlaintextMarkersAbsent &&
        offlineHostBaselineSnapshot.activePendingCount === 0,
      'B had pending or unreadable local Vault state before offline Host creation');
      groupMutationStep = 'save Host locally on offline B';
      let offlineHostSaveClickError = null;
      try {
        await click(secondPage, 'Save encrypted host');
      } catch (error) {
        offlineHostSaveClickError = {
          errorClass: safeErrorClass(error),
          errorCategory: safeErrorTextClass(error),
        };
      }
      groupMutationStep = 'confirm durable opaque offline Host create in B SQLite';
      const offlineHostLocalSnapshot = await waitForOfflineGroupHostCreate(
        secondPage,
        tempRoot,
        vaultId,
        danglingGroupCreateOperation.recordId,
        groupSyncCapture.markers,
      );
      const offlineHostEditorVisible = await secondPage.getByText(
        'Add a host', { exact: true },
      ).isVisible().catch(() => false);
      const offlineProfileBPushes = groupSyncCapture.pushes
        .slice(offlineHostPushStart)
        .filter((push) => push.profile === 'B')
        .flatMap((push) => push.operations);
      console.log('Vault Group offline Host local-state diagnostic', JSON.stringify({
        baselineIntegrityOk: offlineHostBaselineSnapshot.integrityCheck === 'ok',
        baselineSqliteMarkersAbsent:
          offlineHostBaselineSnapshot.sqlitePlaintextMarkersAbsent,
        baselinePendingCount: offlineHostBaselineSnapshot.activePendingCount,
        localSnapshotReady: offlineHostLocalSnapshot.ready,
        localSnapshotAvailable: offlineHostLocalSnapshot.available === true,
        localSnapshotReasonCategory: offlineHostLocalSnapshot.reasonCategory || null,
        localIntegrityOk: offlineHostLocalSnapshot.integrityCheck === 'ok',
        localSqliteMarkersAbsent:
          offlineHostLocalSnapshot.sqlitePlaintextMarkersAbsent,
        localActivePendingCount: offlineHostLocalSnapshot.activePendingCount ?? null,
        localOperationCount: offlineHostLocalSnapshot.operations?.length ?? null,
        localOutboxStatus: ['queued', 'sent', 'superseded'].includes(
          offlineHostLocalSnapshot.operations?.[0]?.status)
          ? offlineHostLocalSnapshot.operations[0].status : 'other',
        localRecordSchema: [1, 2].includes(
          offlineHostLocalSnapshot.operations?.[0]?.recordSchema)
          ? offlineHostLocalSnapshot.operations[0].recordSchema : null,
        localEnvelopeSha256Present: /^[0-9a-f]{64}$/.test(
          offlineHostLocalSnapshot.operations?.[0]?.envelopeSha256 || ''),
        localCreateHeaderValid: Boolean(offlineHostLocalSnapshot.operations?.[0]?.operation === 'create' &&
          offlineHostLocalSnapshot.operations?.[0]?.baseRevisionId == null &&
          offlineHostLocalSnapshot.operations?.[0]?.headerBaseRevisionId == null &&
          offlineHostLocalSnapshot.operations?.[0]?.headerIdentityMatches),
        localEnvelopeOpaque: Boolean(offlineHostLocalSnapshot.operations?.[0]?.envelopeShapeValid &&
          offlineHostLocalSnapshot.operations?.[0]?.metadataOnlyHeader &&
          offlineHostLocalSnapshot.operations?.[0]?.encodedCiphertextFields &&
          offlineHostLocalSnapshot.operations?.[0]?.plaintextMarkersAbsent &&
          offlineHostLocalSnapshot.operations?.[0]?.groupReferenceAbsentFromHeader),
        localEncryptedRecordMatchesOutbox: Boolean(offlineHostLocalSnapshot.operations?.[0]?.matchingEncryptedRecordCount === 1 &&
          offlineHostLocalSnapshot.operations?.[0]?.encryptedRecordMatchesEnvelope &&
          offlineHostLocalSnapshot.operations?.[0]?.encryptedRecordRevisionMatches &&
          offlineHostLocalSnapshot.operations?.[0]?.encryptedRecordActive &&
          offlineHostLocalSnapshot.operations?.[0]?.encryptedRecordCommitSequenceNull),
        localEncryptedRecordCount: offlineHostLocalSnapshot.operations?.[0]?.matchingEncryptedRecordCount ?? 0,
        localRecordPendingOperationCount: offlineHostLocalSnapshot.operations?.[0]?.recordPendingOperationCount ?? 0,
        selectedGroupVisibleInEditor: selectedDanglingGroupEvidence.fieldControlShowsExpectedValue,
        saveClickErrorClass: offlineHostSaveClickError?.errorClass || null,
        saveClickErrorCategory: offlineHostSaveClickError?.errorCategory || null,
        hostEditorVisibleAfterSave: offlineHostEditorVisible,
        offlinePushCount: offlineProfileBPushes.length,
      }));
      assertThat(offlineProfileBPushes.length === 0,
        'offline B uploaded its Host or Group reference before reconnecting');
      assertThat(offlineGroupHostCreateReady(offlineHostLocalSnapshot),
        'offline Host Save did not persist exactly one opaque create in encrypted_records and pending_operations');
      assertThat(offlineHostSaveClickError === null && !offlineHostEditorVisible,
        'offline Host Save click did not complete or left the editor open');
      const offlineHostRecordId = offlineHostLocalSnapshot.operations?.[0]?.recordId;
      assertThat(typeof offlineHostRecordId === 'string' &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
          .test(offlineHostRecordId),
      'offline Host create did not expose a stable local record identity');
      const offlineSavedHostsAfter = await visibleSavedHostsCount(secondPage);
      groupMutationStep = 'wait for offline Host card projection on B';
      try {
        await scrollHostsPageToBottom(secondPage);
        await hostCardByRecordId(secondPage, offlineHostRecordId)
          .scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
        await waitForHostCardByRecordId(
          secondPage,
          offlineHostRecordId,
          danglingHostName,
          `${danglingHostAddress}:22`,
        );
      } catch (error) {
        const [offlineHostIdentifierEvidence, offlineSyncStatusLabels,
          editorVisible] = await Promise.all([
          hostCardIdentifierEvidence(secondPage, offlineHostRecordId,
            danglingHostName, `${danglingHostAddress}:22`),
          visibleSyncStatusLabels(secondPage),
          secondPage.getByText('Add a host', { exact: true })
            .isVisible().catch(() => false),
        ]);
        console.log('Vault Group offline Host card projection diagnostic', JSON.stringify({
          localEncryptedCreatePresent: offlineGroupHostCreateReady(offlineHostLocalSnapshot),
          localRecordCount: offlineHostLocalSnapshot.operations?.[0]?.matchingEncryptedRecordCount ?? 0,
          pendingOperationCount: offlineHostLocalSnapshot.activePendingCount ?? null,
          savedHostsBefore: offlineSavedHostsBefore,
          savedHostsAfter: offlineSavedHostsAfter,
          evidence: offlineHostIdentifierEvidence,
          syncStatusLabels: offlineSyncStatusLabels,
          hostEditorVisible: editorVisible,
          visibilityErrorClass: safeErrorClass(error),
          visibilityErrorCategory: safeErrorTextClass(error),
        }));
        throw error;
      }
      const offlineHostCardEvidence = await hostCardIdentifierEvidence(
        secondPage,
        offlineHostRecordId,
        danglingHostName,
        `${danglingHostAddress}:22`,
      );
      console.log('Vault Group offline Host card identifier evidence', JSON.stringify({
        identifierNodeCount: offlineHostCardEvidence.identifierNodeCount,
        semanticRole: offlineHostCardEvidence.semanticRole,
        nameMatches: offlineHostCardEvidence.nameMatches,
        endpointMatches: offlineHostCardEvidence.endpointMatches,
        inViewport: offlineHostCardEvidence.inViewport,
        savedHostsBefore: offlineSavedHostsBefore,
        savedHostsAfter: offlineSavedHostsAfter,
      }));
      assertThat(Number.isInteger(offlineSavedHostsBefore) &&
        Number.isInteger(offlineSavedHostsAfter) &&
        offlineSavedHostsAfter === offlineSavedHostsBefore + 1,
      'offline Host did not increment the visible Saved hosts count');
      assertThat(offlineHostCardEvidence.identifierNodeCount === 1 &&
        offlineHostCardEvidence.nameMatches &&
        offlineHostCardEvidence.endpointMatches &&
        offlineHostCardEvidence.inViewport,
      'durably saved offline Host did not appear in B Host-card projection');
      const offlineHostCard = hostCardByRecordId(secondPage, offlineHostRecordId);
      const offlineHostRelationshipEvidence = await hostCardRelationshipEvidence(
        secondPage,
        offlineHostRecordId,
        danglingGroupName,
      );
      console.log('Vault Group offline Host card Group-tag evidence', JSON.stringify({
        identifierNodeCount: offlineHostRelationshipEvidence.identifierNodeCount,
        expectedGroupTagPresent:
          offlineHostRelationshipEvidence.expectedGroupTagPresent,
        expectedGroupTagVisible:
          offlineHostRelationshipEvidence.expectedGroupTagVisible,
        groupIdentifierNodeCount:
          offlineHostRelationshipEvidence.groupIdentifierNodeCount,
        groupLabelMatches:
          offlineHostRelationshipEvidence.groupLabelMatches,
        groupLabelContainsExpected:
          offlineHostRelationshipEvidence.groupLabelContainsExpected,
        groupLabelPresent:
          offlineHostRelationshipEvidence.groupLabelPresent,
        groupNodeOverlapsCard:
          offlineHostRelationshipEvidence.groupNodeOverlapsCard,
        groupNodeVisible:
          offlineHostRelationshipEvidence.groupNodeVisible,
        hostLabelContainsExpectedGroup:
          offlineHostRelationshipEvidence.hostLabelContainsExpectedGroup,
        unavailableGroupTagPresent:
          offlineHostRelationshipEvidence.unavailableGroupTagPresent,
      }));
      groupMutationStep = 'open offline Host editor';
      await offlineHostCard.getByRole('button', {
        name: 'Edit host', exact: true,
      }).click();
      groupMutationStep = 'wait for offline Host editor';
      const offlineHostEditorDialog = await waitForHostEditorDialog(secondPage);
      const selectedOfflineGroupText = offlineHostEditorDialog.getByText(
        danglingGroupName, { exact: true },
      ).first();
      if (await selectedOfflineGroupText.count()) {
        await selectedOfflineGroupText.scrollIntoViewIfNeeded({ timeout: 5000 })
          .catch(() => {});
      }
      groupMutationStep = 'inspect decrypted offline Host Group field';
      const persistedOfflineHostGroupEvidence = await dropdownValueEvidence(
        secondPage,
        'Group',
        danglingGroupName,
      );
      console.log('Vault Group offline Host Group-field evidence', JSON.stringify({
        fieldControlCount: persistedOfflineHostGroupEvidence.fieldControlCount,
        expectedGroupVisible:
          persistedOfflineHostGroupEvidence.fieldControlShowsExpectedValue,
        fieldValueCategory:
          persistedOfflineHostGroupEvidence.fieldValueCategory,
        matchingFieldControlCount:
          persistedOfflineHostGroupEvidence.matchingFieldControlCount,
      }));
      const persistedEditorGroupEvidence = await groupEditorValueEvidence(
        secondPage,
        danglingGroupName,
      );
      if (persistedEditorGroupEvidence.alertDialogNodeCount !== 1 ||
          !persistedEditorGroupEvidence.expectedGroupSubstringVisible) {
        await secondPage.screenshot({
          path: '/tmp/atermius-group-editor-evidence.png',
        }).catch(() => {});
      }
      console.log('Vault Group offline Host scoped Group evidence', JSON.stringify({
        alertDialogNodeCount:
          persistedEditorGroupEvidence.alertDialogNodeCount,
        matchingEditDialogCount:
          persistedEditorGroupEvidence.matchingEditDialogCount,
        editTitleCount: persistedEditorGroupEvidence.editTitleCount,
        groupFieldCount: persistedEditorGroupEvidence.groupFieldCount,
        groupLabelCount: persistedEditorGroupEvidence.groupLabelCount,
        expectedGroupCount: persistedEditorGroupEvidence.expectedGroupCount,
        expectedGroupVisible:
          persistedEditorGroupEvidence.expectedGroupVisible,
        expectedGroupSubstringVisible:
          persistedEditorGroupEvidence.expectedGroupSubstringVisible,
        noGroupVisible: persistedEditorGroupEvidence.noGroupVisible,
        unavailableGroupVisible:
          persistedEditorGroupEvidence.unavailableGroupVisible,
        saveHostButtonCount: persistedEditorGroupEvidence.saveHostButtonCount,
        cancelButtonCount: persistedEditorGroupEvidence.cancelButtonCount,
      }));
      groupMutationStep = 'cancel offline Host editor';
      await offlineHostEditorDialog.getByRole('button', {
        name: 'Cancel', exact: true,
      }).click();
      await offlineHostEditorDialog.waitFor({ state: 'hidden', timeout: 10000 });
      groupMutationStep = 'assert offline Host decrypted Group';
      assertThat(persistedEditorGroupEvidence.alertDialogNodeCount === 1 &&
        persistedEditorGroupEvidence.matchingEditDialogCount === 1 &&
        persistedEditorGroupEvidence.saveHostButtonCount === 1 &&
        persistedEditorGroupEvidence.cancelButtonCount === 1 &&
        persistedOfflineHostGroupEvidence.fieldControlShowsExpectedValue &&
        persistedOfflineHostGroupEvidence.matchingFieldControlCount === 1 &&
        persistedEditorGroupEvidence.expectedGroupSubstringVisible &&
        !persistedEditorGroupEvidence.noGroupVisible &&
        !persistedEditorGroupEvidence.unavailableGroupVisible,
        'B local Host row did not decrypt back to the selected stale Group');
      assertThat(offlineHostRelationshipEvidence.identifierNodeCount === 1 &&
        offlineHostRelationshipEvidence.expectedGroupTagPresent &&
        offlineHostRelationshipEvidence.expectedGroupTagVisible &&
        offlineHostRelationshipEvidence.hostLabelContainsExpectedGroup &&
        !offlineHostRelationshipEvidence.unavailableGroupTagPresent,
      'offline Host card did not project its selected cached Group');
      const offlineHostAfterCancelSnapshot = await readOfflineGroupHostSnapshot(
        secondPage,
        tempRoot,
        vaultId,
        danglingGroupCreateOperation.recordId,
        groupSyncCapture.markers,
      );
      const offlinePushesAfterCancel = groupSyncCapture.pushes
        .slice(offlineHostPushStart)
        .filter((push) => push.profile === 'B')
        .flatMap((push) => push.operations);
      assertThat(offlineGroupHostCreateReady(offlineHostAfterCancelSnapshot) &&
        offlineHostAfterCancelSnapshot.operations[0].opId ===
          offlineHostLocalSnapshot.operations[0].opId &&
        offlineHostAfterCancelSnapshot.operations[0].envelopeSha256 ===
          offlineHostLocalSnapshot.operations[0].envelopeSha256 &&
        offlinePushesAfterCancel.length === 0,
      'opening and canceling the offline Host editor changed its encrypted outbox or pushed data');
      console.log('Vault Group offline Host decrypted-reference diagnostic', JSON.stringify({
        localHostCardVisible: offlineHostCardEvidence.nameVisible &&
          offlineHostCardEvidence.endpointVisible,
        savedHostDecryptsToSelectedGroup:
          persistedOfflineHostGroupEvidence.fieldControlShowsExpectedValue,
        localEncryptedCreateUnchangedAfterCancel: true,
        localOutboxStatus: ['queued', 'sent', 'superseded'].includes(
          offlineHostAfterCancelSnapshot.operations[0].status)
          ? offlineHostAfterCancelSnapshot.operations[0].status : 'other',
        offlinePushCountAfterCancel: offlinePushesAfterCancel.length,
      }));

      activeStage = 'Vault Group acceptance: reconnect B and surface the dangling Host Group';
      const danglingHostReconnectPushStart = groupSyncCapture.pushes.length;
      groupMutationStep = 'reconnect B and sync the queued Host create';
      await secondContext.setOffline(false);
      await syncNow(secondPage);
      groupMutationStep = 'wait for the opaque B Host create';
      const danglingHostCreateOperation = await waitForSingleGroupPush(
        danglingHostReconnectPushStart,
        'B',
        'create',
      );
      groupMutationStep = 'validate the reconnected Host create envelope';
      assertThat(danglingHostCreateOperation.recordId !==
          danglingGroupDeleteOperation.recordId &&
        danglingHostCreateOperation.baseRevisionId == null &&
        danglingHostCreateOperation.exactEnvelopeShape &&
        danglingHostCreateOperation.metadataOnlyHeader &&
        danglingHostCreateOperation.encodedCiphertextFields &&
        danglingHostCreateOperation.plaintextMarkersAbsent &&
        danglingHostCreateOperation.bodyShapeValid &&
        danglingHostCreateOperation.requestPlaintextMarkersAbsent,
      'offline B Host did not arrive as one opaque, independently encrypted create operation');
      const offlineLocalCreate = offlineHostLocalSnapshot.operations[0];
      groupMutationStep = 'match reconnected Host create to local ciphertext';
      assertThat(danglingHostCreateOperation.opId === offlineLocalCreate.opId &&
        danglingHostCreateOperation.recordId === offlineLocalCreate.recordId &&
        danglingHostCreateOperation.revisionId === offlineLocalCreate.revisionId &&
        danglingHostCreateOperation.envelopeSha256 === offlineLocalCreate.envelopeSha256,
      'reconnected Host push did not match the exact locally persisted encrypted create');
      await waitForPull(danglingGroupDeleteOperation, 'B', 'A');
      groupMutationStep = 'verify the reconnected Host decrypts';
      await waitForHostRecord(
        secondPage,
        danglingHostName,
        true,
        `${danglingHostAddress}:22`,
      );
      const reconnectedHostCardEvidence = await hostCardEvidence(
        secondPage,
        danglingHostName,
        `${danglingHostAddress}:22`,
      );
      assertThat(reconnectedHostCardEvidence.nameVisible &&
        reconnectedHostCardEvidence.endpointVisible,
      'offline Host had no decrypted card after its opaque outbox create was committed');
      groupMutationStep = 'wait for the unavailable Group repair warning';
      await waitForSemanticText(
        secondPage,
        'Host references unavailable Groups',
      );
      await secondPage.waitForTimeout(1000);
      groupMutationStep = 'verify the unavailable Group tag semantics';
      const reconnectedHostRelationshipEvidence =
        await hostCardRelationshipEvidence(
          secondPage,
          danglingHostCreateOperation.recordId,
          danglingGroupName,
        );
      console.log('Vault Group reconnected Host relationship evidence', JSON.stringify({
        identifierNodeCount:
          reconnectedHostRelationshipEvidence.identifierNodeCount,
        hostLabelContainsExpectedGroup:
          reconnectedHostRelationshipEvidence.hostLabelContainsExpectedGroup,
        unavailableIdentifierNodeCount:
          reconnectedHostRelationshipEvidence.unavailableIdentifierNodeCount,
        hostLabelIndicatesGroupRepair:
          reconnectedHostRelationshipEvidence.hostLabelIndicatesGroupRepair,
        unavailableNodeLabelMatches:
          reconnectedHostRelationshipEvidence.unavailableNodeLabelMatches,
        unavailableGroupNodeOverlapsCard:
          reconnectedHostRelationshipEvidence.unavailableGroupNodeOverlapsCard,
        unavailableGroupTagPresent:
          reconnectedHostRelationshipEvidence.unavailableGroupTagPresent,
      }));
      assertThat(reconnectedHostRelationshipEvidence.identifierNodeCount === 1 &&
        reconnectedHostRelationshipEvidence.unavailableIdentifierNodeCount === 1 &&
        reconnectedHostRelationshipEvidence.hostLabelIndicatesGroupRepair &&
        reconnectedHostRelationshipEvidence.unavailableGroupTagPresent,
      'reconnected Host did not expose its unavailable Group tag');
      const danglingHostCard = hostCardGroup(secondPage, danglingHostName);
      groupMutationStep = 'locate the explicit Host Group repair action';
      const repairHostAction = danglingHostCard.getByRole('button', {
        name: 'Repair Host Group', exact: true,
      });
      await repairHostAction.waitFor({ state: 'visible', timeout: 10000 });

      const beforeRepairOperations = pushOperations(
        groupSyncCapture.pushes,
      ).filter((item) => item.recordId === danglingHostCreateOperation.recordId);
      assertThat(beforeRepairOperations.length === 1 &&
        beforeRepairOperations[0].profile === 'B' &&
        beforeRepairOperations[0].operation === 'create',
      'B automatically dirtied or updated the dangling Host before explicit repair');
      const preRepairSyncStatus = await visibleSyncStatusLabels(secondPage);
      assertThat(preRepairSyncStatus.includes('Idle') &&
        !preRepairSyncStatus.some((label) =>
          label === 'Pending' || /^\d+ pending$/.test(label)),
      'B retained an automatic Host repair write after its full sync settled');
      const beforeRepairSnapshot = serverVaultGroupSnapshot(
        databasePath,
        vaultId,
        [
          danglingGroupCreateOperation,
          danglingGroupDeleteOperation,
          danglingHostCreateOperation,
        ],
        groupSyncCapture.markers,
      );
      const deletedGroupBeforeRepair = beforeRepairSnapshot.heads.find(
        (item) => item.recordId === danglingGroupCreateOperation.recordId,
      );
      const hostBeforeRepair = beforeRepairSnapshot.heads.find(
        (item) => item.recordId === danglingHostCreateOperation.recordId,
      );
      assertThat(beforeRepairSnapshot.checks.length === 3 &&
        beforeRepairSnapshot.checks.every((item) => item.receiptMatches &&
          item.versionMatches && item.eventMatches &&
          item.versionEnvelopeMatches && item.eventEnvelopeMatches) &&
        beforeRepairSnapshot.heads.length === 2 &&
        deletedGroupBeforeRepair?.versionCount === 2 &&
        deletedGroupBeforeRepair.eventCount === 2 &&
        deletedGroupBeforeRepair.deleted === true &&
        deletedGroupBeforeRepair.headMatches &&
        hostBeforeRepair?.versionCount === 1 &&
        hostBeforeRepair.eventCount === 1 &&
        hostBeforeRepair.deleted === false &&
        hostBeforeRepair.headMatches &&
        beforeRepairSnapshot.envelopeCount === 6 &&
        beforeRepairSnapshot.envelopes.every((item) => item.fieldsValid &&
          item.headerMetadataOnly && item.plaintextMarkersAbsent),
      'server ledger did not show only the Group tombstone and unmodified Host create before repair');

      activeStage = 'Vault Group acceptance: explicitly unassign the stale Host Group on B';
      groupDiagnosticPage = secondPage;
      groupDiagnosticProfile = 'B';
      const danglingHostUpdateOperation = await runGroupMutation(
        'explicitly clear the dangling Host Group on B',
        secondPage,
        'B',
        'update',
        async () => {
          const hostCard = hostCardGroup(secondPage, danglingHostName);
          await hostCard.getByRole('button', {
            name: 'Repair Host Group', exact: true,
          }).click();
          await waitForText(secondPage, 'Edit host');
          await waitForText(
            secondPage,
            'This saved Group is unavailable. Choose No group to clear it.',
          );
          await chooseDropdownOption(secondPage, 'Group', 'No group');
          await click(secondPage, 'Save encrypted host');
          await waitForHostRecord(
            secondPage,
            danglingHostName,
            true,
            `${danglingHostAddress}:22`,
          );
        },
      );
      assertThat(danglingHostUpdateOperation.recordId ===
          danglingHostCreateOperation.recordId &&
        danglingHostUpdateOperation.baseRevisionId ===
          danglingHostCreateOperation.revisionId &&
        danglingHostUpdateOperation.revisionId !==
          danglingHostCreateOperation.revisionId,
      'explicit Host Group repair did not update the offline Host at its captured base');
      await secondPage.getByRole('button', {
        name: 'Repair a Host', exact: true,
      }).waitFor({ state: 'hidden', timeout: 10000 });
      await danglingHostCard.getByText('Unavailable group', {
        exact: true,
      }).waitFor({ state: 'hidden', timeout: 10000 });

      activeStage = 'Vault Group acceptance: A pulls and decrypts the repaired Host';
      groupDiagnosticPage = ownerPage;
      groupDiagnosticProfile = 'A';
      await syncNow(ownerPage);
      await waitForPull(danglingHostCreateOperation, 'A', 'B');
      await waitForPull(danglingHostUpdateOperation, 'A', 'B');
      await click(ownerPage, 'Hosts');
      await waitForHostRecord(
        ownerPage,
        danglingHostName,
        true,
        `${danglingHostAddress}:22`,
      );
      const repairedHostCard = hostCardGroup(ownerPage, danglingHostName);
      await repairedHostCard.getByRole('button', {
        name: 'Edit host', exact: true,
      }).click();
      await waitForText(ownerPage, 'Edit host');
      const repairedHostGroupEvidence = await dropdownValueEvidence(
        ownerPage,
        'Group',
        'No group',
      );
      await click(ownerPage, 'Cancel');
      const repairedOwnerBodyText = await ownerPage.locator('body').innerText();
      assertThat(repairedHostGroupEvidence.fieldControlShowsExpectedValue &&
        await repairedHostCard.getByText('Unavailable group', {
          exact: true,
        }).count() === 0 &&
        !repairedOwnerBodyText.includes('Host references unavailable Groups'),
      'A did not decrypt the explicit No group repair or still showed an issue');

      const allUniqueOperations = new Map();
      activeStage = 'Vault Group acceptance: inspect encrypted server records';
      for (const operation of pushOperations(groupSyncCapture.pushes)) {
        const previous = allUniqueOperations.get(operation.opId);
        if (previous) {
          assertThat(previous.envelopeSha256 === operation.envelopeSha256 &&
            previous.recordId === operation.recordId &&
            previous.revisionId === operation.revisionId,
          'Vault Group retries changed a captured envelope');
        } else {
          allUniqueOperations.set(operation.opId, operation);
        }
      }
      const operations = [...allUniqueOperations.values()];
      assertThat(operations.length === 16 &&
        operations.filter((item) => item.operation === 'create').length === 9 &&
        operations.filter((item) => item.operation === 'update').length === 6 &&
        operations.filter((item) => item.operation === 'delete').length === 1 &&
        operations.some((item) => item.opId === danglingGroupDeleteOperation.opId &&
          item.recordId === danglingGroupCreateOperation.recordId &&
          item.operation === 'delete') &&
        operations.some((item) => item.opId === danglingHostCreateOperation.opId &&
          item.recordId === danglingHostUpdateOperation.recordId &&
          item.operation === 'create') &&
        operations.some((item) => item.opId === danglingHostUpdateOperation.opId &&
          item.recordId === danglingHostCreateOperation.recordId &&
          item.operation === 'update'),
      'Vault Group acceptance observed an unexpected create, update, or delete operation');
      assertThat(groupSyncCapture.pushes.every((push) =>
        push.vaultId === vaultId && push.bodyShapeValid &&
        push.plaintextMarkersAbsent && push.operations.every((item) =>
          item.exactEnvelopeShape && item.metadataOnlyHeader &&
          item.encodedCiphertextFields && item.plaintextMarkersAbsent)),
      'Vault Group push request included plaintext or a non-opaque envelope');
      const serverGroups = serverVaultGroupSnapshot(
        databasePath,
        vaultId,
        [
          inheritedCredentialOperation,
          parentOperation,
          childOperation,
          bastionOperation,
          hostOperation,
          updatedOperation,
          updatedHostRouteOperation,
          graphAlphaCreateOperation,
          graphBetaCreateOperation,
          graphAlphaUpdateOperation,
          graphBetaUpdateOperation,
          graphRepairOperation,
          danglingGroupCreateOperation,
          danglingGroupDeleteOperation,
          danglingHostCreateOperation,
          danglingHostUpdateOperation,
        ],
        groupSyncCapture.markers,
      );
      const versionCounts = new Map(serverGroups.heads.map((item) =>
        [item.recordId, item]));
      const graphAlphaExpectedCount = 2 +
        (graphRepairOperation.recordId === graphAlphaCreateOperation.recordId ? 1 : 0);
      const graphBetaExpectedCount = 2 +
        (graphRepairOperation.recordId === graphBetaCreateOperation.recordId ? 1 : 0);
      const danglingGroupHead = versionCounts.get(
        danglingGroupCreateOperation.recordId,
      );
      const danglingHostHead = versionCounts.get(
        danglingHostCreateOperation.recordId,
      );
      assertThat(serverGroups.checks.length === 16 &&
        serverGroups.checks.every((item) => item.receiptMatches &&
          item.versionMatches && item.eventMatches &&
          item.versionEnvelopeMatches && item.eventEnvelopeMatches) &&
        serverGroups.heads.length === 9 &&
        serverGroups.heads.every((item) => item.headMatches) &&
        versionCounts.get(inheritedCredentialOperation.recordId)?.versionCount === 1 &&
        versionCounts.get(inheritedCredentialOperation.recordId)?.eventCount === 1 &&
        versionCounts.get(parentOperation.recordId)?.versionCount === 1 &&
        versionCounts.get(parentOperation.recordId)?.eventCount === 1 &&
        versionCounts.get(childOperation.recordId)?.versionCount === 2 &&
        versionCounts.get(childOperation.recordId)?.eventCount === 2 &&
        versionCounts.get(bastionOperation.recordId)?.versionCount === 1 &&
        versionCounts.get(bastionOperation.recordId)?.eventCount === 1 &&
        versionCounts.get(hostOperation.recordId)?.versionCount === 2 &&
        versionCounts.get(hostOperation.recordId)?.eventCount === 2 &&
        versionCounts.get(graphAlphaCreateOperation.recordId)?.versionCount === graphAlphaExpectedCount &&
        versionCounts.get(graphAlphaCreateOperation.recordId)?.eventCount === graphAlphaExpectedCount &&
        versionCounts.get(graphBetaCreateOperation.recordId)?.versionCount === graphBetaExpectedCount &&
        versionCounts.get(graphBetaCreateOperation.recordId)?.eventCount === graphBetaExpectedCount &&
        danglingGroupHead?.versionCount === 2 &&
        danglingGroupHead.eventCount === 2 &&
        danglingGroupHead.deleted === true &&
        danglingGroupHead.headMatches &&
        danglingHostHead?.versionCount === 2 &&
        danglingHostHead.eventCount === 2 &&
        danglingHostHead.deleted === false &&
        danglingHostHead.headMatches &&
        serverGroups.envelopeCount === 32 &&
        serverGroups.envelopes.every((item) => item.fieldsValid &&
          item.headerMetadataOnly && item.plaintextMarkersAbsent),
      'Vault Group, Jump Host, or dangling Host Group ledger entries did not match');
      const databasePlaintextMarkers = serverDatabasePlaintextMarkers(
        databasePath,
        groupSyncCapture.markers,
      );
      assertThat(databasePlaintextMarkers.length === 0,
        'server SQLite, WAL, or SHM contained Vault Group plaintext markers');
      const groupServerLogEvidence = serverLogPlaintextMarkerEvidence(
        path.join(tempRoot, 'server.log'),
        groupSyncCapture.markers,
      );
      assertThat(groupServerLogEvidence.available &&
        groupServerLogEvidence.markerAbsent,
      'server log contained a Vault Group plaintext marker');

      const crossProfilePulls = [
        ...initialGroupOperations.map((operation) => ({
          operation,
          receiver: 'B',
          origin: 'A',
        })),
        { operation: updatedOperation, receiver: 'A', origin: 'B' },
        { operation: updatedHostRouteOperation, receiver: 'A', origin: 'B' },
        { operation: graphAlphaCreateOperation, receiver: 'B', origin: 'A' },
        { operation: graphBetaCreateOperation, receiver: 'B', origin: 'A' },
        { operation: graphAlphaUpdateOperation, receiver: 'B', origin: 'A' },
        { operation: graphBetaUpdateOperation, receiver: 'A', origin: 'B' },
        { operation: graphRepairOperation, receiver: 'A', origin: 'B' },
        { operation: danglingGroupCreateOperation, receiver: 'B', origin: 'A' },
        { operation: danglingGroupDeleteOperation, receiver: 'B', origin: 'A' },
        { operation: danglingHostCreateOperation, receiver: 'A', origin: 'B' },
        { operation: danglingHostUpdateOperation, receiver: 'A', origin: 'B' },
      ];
      for (const expected of crossProfilePulls) {
        await waitForPull(expected.operation, expected.receiver, expected.origin);
        const pull = groupSyncCapture.pulls.find((item) =>
          item.profile === expected.receiver &&
          item.originProfile === expected.origin &&
          item.opId === expected.operation.opId &&
          item.revisionId === expected.operation.revisionId);
        assertThat(pull?.responsePlaintextMarkersAbsent &&
          pull.exactEnvelopeShape && pull.metadataOnlyHeader &&
          pull.encodedCiphertextFields && pull.plaintextMarkersAbsent,
        'cross-profile Vault Group pull did not carry an opaque ciphertext envelope');
      }
      assertThat(pageErrors.length === 0 && cspViolations.length === 0,
        'Vault Group acceptance observed browser runtime or CSP errors');
      groupSyncCapture.active = false;
      console.log('WEB-GROUPS-01 passed: A created inherited Credential/Group/Jump Host relationships and B decrypted and edited them. Separate offline Group edits produced and repaired a graph cycle. A then deleted a Group while B was offline; B created a Host using its stale Group cache, synced the dangling reference without an automatic Host update, explicitly repaired it to No group, and A pulled/decrypted the repair. Push/pull envelopes, operation receipts, version/event/head ledger, SQLite/WAL/server-log plaintext markers, and fixture cleanup were checked.', JSON.stringify({
        isolatedProfiles: true,
        inheritedCredentialRecordIdCaptured: true,
        parentRecordIdCaptured: true,
        childRecordIdCaptured: true,
        bastionRecordIdCaptured: true,
        hostRecordIdCaptured: true,
        bDecryptedParentIdHostGroupIdAndJumpHostId: true,
        aAndBResolvedInheritedCredentialWithoutOverride: true,
        bastionMarkerPlaintextAbsent: true,
        routeUpdatePushAndCrossProfilePull: true,
        distinctOfflineGroupEditsMergedToCycle: true,
        graphRepairSyncedToBothProfiles: true,
        danglingGroupDeletedWhileBOffline: true,
        staleGroupHostCreatedOfflineOnB: true,
        offlineHostVerifiedByOpaqueOutboxCreateAndDecryptedCard: true,
        danglingHostRepairShownWithoutAutomaticDirtyWrite: true,
        explicitNoGroupRepairPushedOnce: true,
        repairedHostPulledAndDecryptedOnA: true,
        blockedReferencedGroupDeletes: 2,
        uniqueOperations: operations.length,
        versionCounts: serverGroups.heads.map((item) => item.versionCount),
        eventCounts: serverGroups.heads.map((item) => item.eventCount),
        serverPlaintextMarkersAbsent: true,
        serverLogMarkersAbsent: groupServerLogEvidence.markerAbsent,
      }));
      return;
      } catch (error) {
        console.log('Vault Group branch sanitized failure summary', JSON.stringify({
          stage: activeStage,
          step: groupMutationStep,
          profile: groupDiagnosticProfile,
          errorClass: safeErrorClass(error),
          errorCategory: safeErrorTextClass(error),
          page: await safePageDiagnostic(groupDiagnosticPage),
          api: safeApiSummary(apiDiagnostics.slice(groupBranchApiStart), 32)
            .map(({ profile: apiProfile, method, path: apiPath, status }) => ({
              profile: apiProfile,
              method,
              path: apiPath,
              status,
            })),
          pageErrorCount: pageErrors.filter((item) =>
            item.profile === groupDiagnosticProfile).length,
          cspViolationCount: cspViolations.length,
        }));
        throw error;
      }
    }

    if (VAULT_PREFERENCE_ONLY) {
      const databasePath = path.join(dataDir, 'atermius.db');
      const beforePreference = serverVaultSnapshot(databasePath, USERNAME);
      assertThat(beforePreference.vaults.length === 1,
        'Vault preference acceptance did not find exactly one active Vault');
      const vaultId = beforePreference.vaults[0].vaultId;
      activeStage = 'Vault preference acceptance: settle both profiles';
      await Promise.all([syncNow(ownerPage), syncNow(secondPage)]);
      vaultPreferenceSyncCapture.active = true;
      await Promise.all([
        ownerContext.setOffline(true),
        secondContext.setOffline(true),
      ]);
      activeStage = 'Vault preference acceptance: open both offline settings';
      await Promise.all([
        click(ownerPage, 'Settings'),
        click(secondPage, 'Settings'),
      ]);
      await Promise.all([
        waitForSemanticText(ownerPage, 'Vault-synced preferences'),
        waitForSemanticText(secondPage, 'Vault-synced preferences'),
      ]);

      const saveOfflineDefault = async (page, section, profile) => {
        activeStage = `Vault preference acceptance: create ${section} offline on ${profile}`;
        await chooseDropdownOption(page, 'Default workspace section', section);
        await click(page, 'Save synced preference');
        await waitForSemanticText(page,
          `Saved as ${section}. This preference is encrypted in the active Vault`);
      };
      await saveOfflineDefault(ownerPage, 'Groups', 'A');
      await saveOfflineDefault(secondPage, 'Credentials', 'B');
      assertThat(vaultPreferenceSyncCapture.pushes.every((push) =>
        push.operations.length === 0),
      'an offline profile uploaded a preference before reconnecting');

      const uniquePreferenceOperations = (profile) => {
        const operations = vaultPreferenceSyncCapture.pushes
          .filter((push) => push.profile === profile)
          .flatMap((push) => push.operations);
        return [...new Map(operations.map((item) => [item.opId, item])).values()];
      };
      const waitForPreferenceCreate = async (profile) => {
        const deadline = Date.now() + 30000;
        while (Date.now() < deadline) {
          const operations = uniquePreferenceOperations(profile)
            .filter((item) => item.operation === 'create');
          if (operations.length > 0) {
            assertThat(operations.length === 1 &&
              operations[0].exactEnvelopeShape &&
              operations[0].metadataOnlyHeader &&
              operations[0].encodedCiphertextFields &&
              operations[0].plaintextMarkersAbsent,
            `profile ${profile} did not push exactly one opaque default preference create`);
            return operations[0];
          }
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        throw new Error(`profile ${profile} did not push its offline preference`);
      };

      activeStage = 'Vault preference acceptance: reconnect and push A first';
      await ownerContext.setOffline(false);
      await syncNow(ownerPage);
      const ownerCreate = await waitForPreferenceCreate('A');
      const ownerCreatePush = vaultPreferenceSyncCapture.pushes.find((push) =>
        push.profile === 'A' && push.operations.some((item) =>
          item.opId === ownerCreate.opId));
      assertThat(ownerCreatePush?.vaultId === vaultId &&
        ownerCreate.operation === 'create',
        'profile A preference create used an unexpected Vault or operation');
      assertThat(uniquePreferenceOperations('B').length === 0,
        'offline profile B observed or uploaded profile A before reconnecting');

      activeStage = 'Vault preference acceptance: configure B committed-create ACK loss';
      await secondContext.route(
        '**/api/v1/vaults/*/sync/push',
        async (route) => {
          if (preferenceLostAck.mode === 'off') {
            await route.continue();
            return;
          }
          try {
            const request = route.request();
            const body = request.postDataJSON();
            const operation = syncOperationSummary(body);
            const header = body?.operations?.length === 1
              ? body.operations[0]?.header
              : null;
            if (preferenceLostAck.mode === 'drop-first' &&
                body?.operations?.length === 1 &&
                header?.operation === 'create' &&
                typeof header?.record_id === 'string' &&
                typeof header?.op_id === 'string') {
              const serialized = stableJson(body);
              const envelope = body.operations[0];
              vaultPreferenceSyncCapture.pushes.push({
                profile: 'B',
                vaultId: body.vault_id,
                bodyShapeValid: JSON.stringify(Object.keys(body || {}).sort()) ===
                  JSON.stringify([
                    'batch_id', 'device_id', 'operations', 'protocol_version',
                    'server_generation', 'vault_id',
                  ]),
                plaintextMarkersAbsent:
                  VAULT_PREFERENCE_PLAINTEXT_MARKERS.every((marker) =>
                    !serialized.includes(marker)),
                operations: [{
                  ...syncOperationSummary({ operations: [envelope] }),
                  baseRevisionId: envelope?.header?.base_revision_id ?? null,
                  retainedRecordIdAbsent: true,
                  ...safeCredentialEnvelopeSummary(
                    envelope,
                    VAULT_PREFERENCE_PLAINTEXT_MARKERS,
                  ),
                }],
              });
              const upstream = await route.fetch();
              const responseBody = await upstream.json();
              const receipt = Array.isArray(responseBody?.results)
                ? responseBody.results[0]
                : null;
              preferenceLostAck.first = {
                request: {
                  ...operation,
                  vaultId: body.vault_id,
                },
                httpStatus: upstream.status(),
                receipt: receipt && {
                  opId: receipt.op_id,
                  revisionId: receipt.revision_id,
                  commitSeq: receipt.commit_seq,
                  alreadyCommitted: receipt.already_committed,
                },
              };
              preferenceLostAck.targetOpId = header.op_id;
              preferenceLostAck.mode = 'hold';
              // The upstream commit and receipt are real. Isolate the browser
              // immediately so notification-driven pull cannot clear its
              // durable outbox before Profile A writes the later tombstone.
              await secondContext.setOffline(true);
              preferenceLostAck.isolatedOfflineBeforeAck = true;
              await route.abort('failed');
              return;
            }
            if (preferenceLostAck.mode === 'hold' &&
                body?.operations?.some((item) =>
                  item?.header?.op_id === preferenceLostAck.targetOpId)) {
              preferenceLostAck.heldRetryCount++;
              await route.abort('failed');
              return;
            }
            await route.continue();
          } catch (_) {
            preferenceLostAck.failureCategory = 'route-or-upstream-error';
            await route.abort('failed').catch(() => {});
          }
        },
      );

      activeStage = 'Vault preference acceptance: reconnect B and commit create while dropping ACK';
      preferenceLostAck.mode = 'drop-first';
      await secondContext.setOffline(false);
      await triggerSyncWithoutWaitingForIdle(secondPage);
      const secondCommitDeadline = Date.now() + 30000;
      while (Date.now() < secondCommitDeadline &&
          !preferenceLostAck.first && !preferenceLostAck.failureCategory) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(!preferenceLostAck.failureCategory && preferenceLostAck.first,
        'Profile B did not reach the server through the response-loss route');
      const secondCreate = await waitForPreferenceCreate('B');
      const secondCreatePush = vaultPreferenceSyncCapture.pushes.find((push) =>
        push.profile === 'B' && push.operations.some((item) =>
          item.opId === secondCreate.opId));
      assertThat(secondCreatePush?.vaultId === vaultId &&
        secondCreate.operation === 'create' &&
        secondCreate.recordId !== ownerCreate.recordId &&
        preferenceLostAck.first.request.recordId === secondCreate.recordId &&
        preferenceLostAck.first.request.revisionId === secondCreate.revisionId &&
        preferenceLostAck.first.httpStatus === 200 &&
        preferenceLostAck.first.receipt?.alreadyCommitted === false &&
        preferenceLostAck.first.receipt?.opId === secondCreate.opId &&
        preferenceLostAck.first.receipt?.revisionId === secondCreate.revisionId &&
        /^[1-9][0-9]*$/.test(
          preferenceLostAck.first.receipt?.commitSeq || '',
        ),
      'B create did not commit exactly once before its browser ACK was dropped');
      assertThat(preferenceLostAck.mode === 'hold',
        'Profile B response loss did not hold the original operation for retry detection');
      assertThat(preferenceLostAck.isolatedOfflineBeforeAck,
        'Profile B was not disconnected immediately after the server commit');
      const secondCreateCommitSnapshot = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        secondCreate,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      assertThat(secondCreateCommitSnapshot.versionCount === 1 &&
        secondCreateCommitSnapshot.createOperationCount === 1 &&
        secondCreateCommitSnapshot.eventCount === 1 &&
        secondCreateCommitSnapshot.receiptMatches &&
        secondCreateCommitSnapshot.headMatches &&
        secondCreateCommitSnapshot.headDeleted === false &&
        secondCreateCommitSnapshot.headCommitSeq ===
          preferenceLostAck.first.receipt?.commitSeq,
      'B response loss happened before a durable server create receipt/head');

      activeStage = 'Vault preference acceptance: hold B offline with one pending outbox operation';
      await secondContext.setOffline(true);
      await click(secondPage, 'Hosts');
      let secondPendingAfterLostAck;
      try {
        secondPendingAfterLostAck = await waitForPendingCardCount(
          secondPage,
          1,
        );
      } catch (_) {
        console.log('Vault preference lost-ACK pending safe evidence',
          JSON.stringify({
            visiblePendingSyncValue: await visiblePendingSyncValue(secondPage),
            safePage: await safePageDiagnostic(secondPage),
            responseLoss: {
              routeMode: preferenceLostAck.mode,
              failureCategory: preferenceLostAck.failureCategory,
              heldRetryCount: preferenceLostAck.heldRetryCount,
              isolatedOfflineBeforeAck:
                preferenceLostAck.isolatedOfflineBeforeAck,
              serverHttpStatus: preferenceLostAck.first?.httpStatus ?? null,
              receiptWasFirstCommit:
                preferenceLostAck.first?.receipt?.alreadyCommitted === false,
              commitSeq: preferenceLostAck.first?.receipt?.commitSeq ?? null,
              ownCreatePullCountBeforeA: vaultPreferenceSyncCapture.pulls.filter(
                (item) => item.profile === 'B' && item.originProfile === 'B' &&
                  item.recordId === preferenceLostAck.first?.request?.recordId &&
                  item.opId === preferenceLostAck.first?.request?.opId &&
                  item.operation === 'create',
              ).length,
            },
            api: safeApiSummary(apiDiagnostics.filter((entry) =>
              entry.profile === 'B'), 8),
          }));
        throw new Error('Profile B did not expose its pending create after ACK loss');
      }
      assertThat(secondPendingAfterLostAck === 1,
        'Profile B did not retain exactly one local pending preference operation after ACK loss');
      const ownCreatePullsBeforeA = vaultPreferenceSyncCapture.pulls.filter(
        (item) => item.profile === 'B' && item.originProfile === 'B' &&
          item.recordId === secondCreate.recordId &&
          item.opId === secondCreate.opId && item.operation === 'create',
      );
      assertThat(ownCreatePullsBeforeA.length === 0,
        'Profile B pulled its own committed create before A wrote the tombstone');
      await click(secondPage, 'Settings');

      activeStage = 'Vault preference acceptance: A sync after B create';
      await syncNow(ownerPage);
      const ownerCandidateId = ownerCreate.recordId;
      const secondCandidateId = secondCreate.recordId;
      activeStage = 'Vault preference acceptance: verify both candidate radios on A';
      activeStage = 'Vault preference acceptance: select retained ID radio on A';
      const candidateRadios = ownerPage.getByRole('radio', {
        name: `Default section: Groups; Record ID: ${ownerCandidateId}; Revision: ${ownerCreate.revisionId}`,
        exact: true,
      });
      try {
        await candidateRadios.last().waitFor({ state: 'visible', timeout: 10000 });
      } catch (_) {
        const radios = await ownerPage.evaluate(() =>
          [...document.querySelectorAll('flt-semantics[role="radio"]')]
            .map((element) => ({
              label: element.getAttribute('aria-label') || '',
              text: (element.innerText || element.textContent || '').slice(0, 240),
              checked: element.getAttribute('aria-checked'),
              visible: element.getBoundingClientRect().width > 0 &&
                element.getBoundingClientRect().height > 0,
            })),
        ).catch(() => []);
        console.log('Vault preference candidate radio diagnostic', JSON.stringify({
          ownerCandidateId,
          secondCandidateId,
          radios,
          radioCount: await ownerPage.getByRole('radio').count().catch(() => -1),
        }));
        throw new Error('retained candidate record ID was not exposed by its radio');
      }
      activeStage = 'Vault preference acceptance: verify B candidate semantic label';
      const losingCandidateRadio = ownerPage.getByRole('radio', {
        name: `Default section: Credentials; Record ID: ${secondCandidateId}; Revision: ${secondCreate.revisionId}`,
        exact: true,
      });
      try {
        await losingCandidateRadio.waitFor({ state: 'visible', timeout: 10000 });
      } catch (_) {
        const radios = await ownerPage.evaluate(() =>
          [...document.querySelectorAll('flt-semantics[role="radio"]')]
            .map((element) => ({
              label: element.getAttribute('aria-label') || '',
              text: (element.innerText || element.textContent || '').slice(0, 240),
              checked: element.getAttribute('aria-checked'),
              visible: element.getBoundingClientRect().width > 0 &&
                element.getBoundingClientRect().height > 0,
            })),
        ).catch(() => []);
        console.log('Vault preference losing candidate radio diagnostic', JSON.stringify({
          expectedSection: 'Credentials',
          expectedRecordId: secondCandidateId,
          expectedRevisionId: secondCreate.revisionId,
          radios,
        }));
        throw new Error('B candidate did not expose its value, record ID, and revision label');
      }
      activeStage = 'Vault preference acceptance: click explicitly identified A radio';
      const selectedCandidateRadio = candidateRadios.last();
      await selectedCandidateRadio.click();
      let selectedCandidateChecked = false;
      await waitUntil(async () =>
        await selectedCandidateRadio.getAttribute('aria-checked') === 'true',
      5000, 'explicitly selected A preference radio').then(() => {
        selectedCandidateChecked = true;
      }).catch(() => {});
      activeStage = 'Vault preference acceptance: wait for enabled repair button';
      vaultPreferenceSyncCapture.retainedRecordId = ownerCandidateId;
      const repairButton = ownerPage.getByRole('button', {
        name: 'Keep selected record and remove duplicates', exact: true,
      });
      await repairButton.waitFor({ state: 'visible', timeout: 10000 });
      let repairButtonEnabled = false;
      await waitUntil(() => repairButton.isEnabled().catch(() => false),
        5000, 'explicit preference repair button enabled').then(() => {
        repairButtonEnabled = true;
      }).catch(() => {});
      if (!selectedCandidateChecked || !repairButtonEnabled) {
        const selectionState = await ownerPage.evaluate(() => ({
          radios: [...document.querySelectorAll('flt-semantics[role="radio"]')]
            .map((element) => ({
              label: element.getAttribute('aria-label') || '',
              checked: element.getAttribute('aria-checked'),
              disabled: element.getAttribute('aria-disabled'),
            })),
          repairButtons: [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter((element) =>
              (element.getAttribute('aria-label') || element.innerText || '')
                .includes('Keep selected record'))
            .map((element) => ({
              label: element.getAttribute('aria-label') || '',
              disabled: element.getAttribute('aria-disabled'),
            })),
        })).catch(() => ({ diagnosticUnavailable: true }));
        console.log('Vault preference selected radio diagnostic', JSON.stringify({
          selectionState,
          candidateId: ownerCandidateId,
          selectedCandidateChecked,
          buttonEnabled: repairButtonEnabled,
        }));
      }
      assertThat(selectedCandidateChecked,
        'choosing the record ID did not select the explicit preference radio');
      assertThat(repairButtonEnabled,
        'choosing the record ID did not enable explicit preference repair');
      activeStage = 'Vault preference acceptance: submit explicit A record repair';
      const repairApiStart = apiDiagnostics.length;
      await repairButton.click();
      activeStage = 'Vault preference acceptance: await repair sync confirmation';
      let repairInteractionPhase = 'wait-for-first-outcome';
      try {
        const repairConfirmation =
          'The selected default preference was confirmed after Vault sync.';
        const singletonRecoveryConfirmation =
          'The default preference was confirmed after Vault sync.';
        const repairRetry = ownerPage.getByRole('button', {
          name: 'Retry and verify repair', exact: true,
        });
        const waitForRepairOutcome = async (
          timeoutMs,
          scrollForInlineStatus = true,
        ) => {
          const deadline = Date.now() + timeoutMs;
          while (Date.now() < deadline) {
          const outcome = await ownerPage.evaluate(({ success, recovered, failure }) => {
            const semanticText = [...document.querySelectorAll('flt-semantics')]
              .map((element) =>
                `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
              .join('\n');
            const text = `${document.body.innerText || ''}\n${semanticText}`;
            if (text.includes(success)) return 'success';
            if (text.includes(recovered)) return 'recovered';
            if (text.includes(failure)) return 'retry';
            return null;
          }, {
            success: repairConfirmation,
            recovered: singletonRecoveryConfirmation,
            failure: 'Repair is not confirmed yet. Sync the active Vault and retry with the same record ID.',
            }).catch(() => null);
            if (outcome != null) return outcome;
            // Flutter can expose the inline result only after its scroll
            // viewport enters view, especially when the conflict card shrinks.
            if (scrollForInlineStatus) await ownerPage.mouse.wheel(0, 180);
            await ownerPage.waitForTimeout(150);
          }
          return null;
        };
        let repairOutcome = await waitForRepairOutcome(45000);
        if (repairOutcome === 'retry') {
          repairInteractionPhase = 'scroll-back-to-retry-controls';
          // The retry controls are above the inline status in the same tall
          // Settings card; return to that card before querying its semantics.
          await ownerPage.mouse.wheel(0, -900);
          await ownerPage.waitForTimeout(150);
          // A separate automatic sync can verify the committed tombstone
          // while the repair result is being rendered. In that ordering the
          // stale retry message is replaced with a neutral singleton-recovery
          // confirmation and the conflict card disappears. Re-check the
          // outcome before looking for retry controls, then re-check once more
          // if the card vanishes while its radio is being resolved.
          repairInteractionPhase = 'recheck-outcome-before-retry';
          repairOutcome = await waitForRepairOutcome(2000, false);
          if (repairOutcome === 'retry') {
            repairInteractionPhase = 'wait-for-retry-button';
            const retainedRadio = ownerPage.getByRole('radio', {
              name: new RegExp(`Default section: Groups; Record ID: ${ownerCandidateId};`),
            }).last();
            try {
              const retryButtonVisible = await repairRetry.isVisible();
              if (!retryButtonVisible) {
                repairOutcome = await waitForRepairOutcome(5000);
              } else {
                await repairRetry.scrollIntoViewIfNeeded();
                repairInteractionPhase = 'verify-retained-radio';
                const retainedRadioVisible = await retainedRadio.isVisible();
                if (!retainedRadioVisible) {
                  repairOutcome = await waitForRepairOutcome(5000);
                } else {
                  await retainedRadio.scrollIntoViewIfNeeded();
                  assertThat(await retainedRadio.getAttribute('aria-checked') === 'true',
                    'retry did not keep the explicitly selected preference record ID');
                  assertThat(await repairRetry.isEnabled(),
                    'the pinned preference repair retry was not enabled');
                  repairInteractionPhase = 'click-retry';
                  await repairRetry.click();
                  repairInteractionPhase = 'wait-for-retry-outcome';
                  repairOutcome = await waitForRepairOutcome(45000);
                }
              }
            } catch (retryUiError) {
              // Automatic sync may finish between checking the radio and
              // using the retry button. Treat disappearing controls as a
              // success only when the panel exposes its verified recovery
              // outcome; otherwise preserve the original UI failure.
              const recoveredOutcome = await waitForRepairOutcome(5000);
              if (recoveredOutcome !== 'success' &&
                  recoveredOutcome !== 'recovered') {
                throw retryUiError;
              }
              repairOutcome = recoveredOutcome;
            }
          }
        }
        repairInteractionPhase = 'assert-success-outcome';
        assertThat(repairOutcome === 'success' || repairOutcome === 'recovered',
          'the selected preference repair was not confirmed after its retry');
      } catch (_) {
        const repairUiState = await ownerPage.evaluate((interactionPhase) => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const relevantText = [...document.querySelectorAll('flt-semantics')]
            .filter((element) => {
              return visible(element) &&
                /repair|preference|sync/i.test(
                  `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`,
                );
            })
            .map((element) => ({
              role: element.getAttribute('role') || '',
              label: (element.getAttribute('aria-label') || element.innerText || '')
                .replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, '{record-id}')
                .slice(0, 120),
            }))
            .slice(-12);
          const syncControls = [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter((element) => visible(element))
            .map((element) => element.getAttribute('aria-label') || element.innerText || '')
            .filter((label) => /pending|syncing|sync now|sync status|retry wait/i.test(label))
            .slice(-6)
            .map((label) => ({
              label: label.slice(0, 160),
              pendingCount: Number(label.match(/pending\s+(\d+)/i)?.[1] ?? NaN),
              status: label.match(/\b(idle|pending|syncing|retry[_ ]wait|error)\b/i)?.[1]
                ?.toLowerCase() ?? null,
            }));
          const candidateRadios = [...document.querySelectorAll('flt-semantics[role="radio"]')]
            .map((element) => ({
              label: element.getAttribute('aria-label') || element.innerText || '',
              checked: element.getAttribute('aria-checked'),
              disabled: element.getAttribute('aria-disabled'),
              hasLayout: visible(element),
            }));
          const repairActions = [...document.querySelectorAll('flt-semantics[role="button"]')]
            .map((element) => ({
              label: element.getAttribute('aria-label') || element.innerText || '',
              disabled: element.getAttribute('aria-disabled'),
              hasLayout: visible(element),
            }))
            .filter((item) => /Keep selected record|Retry and verify repair/.test(item.label));
          const allSemanticText = [...document.querySelectorAll('flt-semantics')]
            .map((element) =>
              `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
            .join('\n');
          return {
            repairButtonCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
              .filter((element) =>
                /Keep selected record|Retry and verify repair/.test(
                  element.getAttribute('aria-label') || element.innerText || '',
                ))
              .length,
            successMessagePresent: allSemanticText.includes(
              'The selected default preference was confirmed after Vault sync.',
            ),
            failureMessagePresent: allSemanticText.includes(
              'Repair is not confirmed yet. Sync the active Vault and retry with the same record ID.',
            ),
            settingsHeadingPresent: allSemanticText.includes('Workspace settings'),
            scrollPosition: Math.round(window.scrollY),
            repairInteractionPhase: interactionPhase,
            repairActions,
            relevantText,
            syncControls,
            localActivePreferenceCount: candidateRadios.length,
            candidateRadios,
          };
        }, repairInteractionPhase).catch(() => ({ diagnosticUnavailable: true }));
        const attemptedDeletes = uniquePreferenceOperations('A').filter((item) =>
          item.operation === 'delete' && item.recordId === secondCandidateId);
        let serverTombstoneSnapshot = null;
        let serverWinnerSnapshot = null;
        try {
          serverWinnerSnapshot = serverVaultPreferenceSnapshot(
            databasePath,
            vaultId,
            ownerCreate,
            VAULT_PREFERENCE_PLAINTEXT_MARKERS,
          );
        } catch (_) {
          serverWinnerSnapshot = { unavailable: true };
        }
        if (attemptedDeletes.length === 1) {
          try {
            serverTombstoneSnapshot = serverVaultPreferenceSnapshot(
              databasePath,
              vaultId,
              attemptedDeletes[0],
              [...VAULT_PREFERENCE_PLAINTEXT_MARKERS, ownerCandidateId],
              { expectedDeleted: true },
            );
          } catch (_) {
            serverTombstoneSnapshot = { unavailable: true };
          }
        }
        const repairApi = apiDiagnostics.slice(repairApiStart)
          .filter((entry) => entry.path.endsWith('/sync/push') ||
            entry.path.endsWith('/changes'))
          .map((entry) => ({
            profile: entry.profile,
            method: entry.method,
            path: entry.path.replace(
              /\/[0-9a-f]{8}-[0-9a-f-]{27,}(?=\/|$)/gi,
              '/{id}',
            ),
            status: entry.status,
            errorCode: entry.errorCode,
            pushReceiptSummary: entry.pushReceiptSummary,
            changesPageSummary: entry.changesPageSummary,
          }));
        const deletePulls = vaultPreferenceSyncCapture.pulls.filter((item) =>
          item.recordId === secondCandidateId && item.operation === 'delete');
        const ownerRetainedSectionEvidence = await ownerPage.evaluate(() =>
          [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter((element) => {
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0 &&
                /Default workspace section/i.test(
                  `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`,
                );
            })
            .map((element) => element.getAttribute('aria-label') || element.innerText || '')
            .slice(-2),
        );
        const repairPendingSettingsCount = await visiblePendingSyncValue(ownerPage);
        let repairPendingHostsCount = null;
        try {
          await click(ownerPage, 'Hosts');
          await waitUntil(async () => {
            repairPendingHostsCount = await pendingCardCount(ownerPage);
            return repairPendingHostsCount !== null;
          }, 5000, 'pending count diagnostic on Hosts');
          await click(ownerPage, 'Settings');
        } catch (_) {
          // The status card is only rendered on Hosts; retain the current
          // Settings-page evidence if navigation or semantics are unavailable.
        }
        const repairSyncStatusLabels = await visibleSyncStatusLabels(ownerPage);
        const candidateConflictVisible = await ownerPage.getByText(
          'Choose the default preference record to keep', { exact: true },
        ).isVisible().catch(() => false);
        const committedRepairDespiteUiRetry = attemptedDeletes.length === 1 &&
          serverWinnerSnapshot?.versionCount === 1 &&
          serverWinnerSnapshot?.createOperationCount === 1 &&
          serverWinnerSnapshot?.headMatches === true &&
          serverWinnerSnapshot?.headDeleted === false &&
          serverTombstoneSnapshot?.versionCount === 2 &&
          serverTombstoneSnapshot?.operationCount === 1 &&
          serverTombstoneSnapshot?.eventCount === 1 &&
          serverTombstoneSnapshot?.receiptMatches === true &&
          serverTombstoneSnapshot?.headMatches === true &&
          serverTombstoneSnapshot?.headDeleted === true &&
          repairUiState.failureMessagePresent &&
          repairUiState.repairActions.length === 0 &&
          ownerRetainedSectionEvidence.some((label) => /Groups/.test(label));
        console.log('Vault preference repair confirmation diagnostic', JSON.stringify({
          repairUiState,
          deleteOperations: attemptedDeletes.map((item) => ({
              recordId: item.recordId,
              revisionId: item.revisionId,
              baseRevisionId: item.baseRevisionId,
              plaintextMarkersAbsent: item.plaintextMarkersAbsent,
            })),
          deletePulls: deletePulls.map((item) => ({
            profile: item.profile,
            originProfile: item.originProfile,
            recordId: item.recordId,
            revisionId: item.revisionId,
            opId: item.opId,
            operation: item.operation,
          })),
          serverWinnerSnapshot,
          serverTombstoneSnapshot,
          ownerRetainedSectionEvidence,
          repairPendingSettingsCount,
          repairPendingHostsCount,
          repairSyncStatusLabels,
          candidateConflictVisible,
          committedRepairDespiteUiRetry,
          api: repairApi,
        }));
        throw new Error(committedRepairDespiteUiRetry
          ? 'repair committed but UI showed retry failure without candidate/retry controls'
          : 'repair did not expose the confirmed success message');
      }
      activeStage = 'Vault preference acceptance: verify repair controls are gone';
      const anyRepairAction = ownerPage.getByRole('button', {
        name: /Keep selected record|Retry and verify repair/,
      });
      await anyRepairAction.waitFor({ state: 'hidden', timeout: 15000 });

      const repairDeletes = uniquePreferenceOperations('A').filter((item) =>
        item.operation === 'delete' && item.recordId === secondCandidateId);
      assertThat(repairDeletes.length === 1 &&
        repairDeletes[0].baseRevisionId === secondCreate.revisionId &&
        repairDeletes[0].retainedRecordIdAbsent &&
        repairDeletes[0].exactEnvelopeShape &&
        repairDeletes[0].metadataOnlyHeader &&
        repairDeletes[0].encodedCiphertextFields &&
        repairDeletes[0].plaintextMarkersAbsent,
      'repair did not CAS-delete B candidate using an opaque tombstone');
      assertThat(vaultPreferenceSyncCapture.pushes.every((push) =>
        push.vaultId === vaultId && push.bodyShapeValid &&
        push.plaintextMarkersAbsent && push.operations.every((item) =>
          item.exactEnvelopeShape && item.metadataOnlyHeader &&
          item.encodedCiphertextFields && item.plaintextMarkersAbsent)),
      'Vault preference push request included plaintext or a non-opaque envelope');

      activeStage = 'Vault preference acceptance: verify committed winner and tombstone';
      const serverWinner = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        ownerCreate,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      const serverTombstone = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        repairDeletes[0],
        [...VAULT_PREFERENCE_PLAINTEXT_MARKERS, ownerCandidateId],
        { expectedDeleted: true },
      );
      const winnerSnapshotAccepted = serverWinner.versionCount === 1 &&
        serverWinner.createOperationCount === 1 &&
        serverWinner.operationCount === 1 && serverWinner.eventCount === 1 &&
        serverWinner.receiptMatches && serverWinner.headMatches &&
        serverWinner.envelopes.length === 2 &&
        serverWinner.envelopes.every((item) => item.fieldsValid &&
          item.headerMetadataOnly && item.plaintextMarkersAbsent);
      if (!winnerSnapshotAccepted) {
        console.log('Vault preference active winner snapshot shape',
          JSON.stringify(serverWinner));
      }
      activeStage = 'Vault preference acceptance: assert active winner SQLite snapshot';
      assertThat(winnerSnapshotAccepted,
      'server SQLite did not retain the selected active preference as ciphertext');
      const tombstoneSnapshotAccepted = serverTombstone.versionCount === 2 &&
        serverTombstone.operationCount === 1 && serverTombstone.eventCount === 1 &&
        serverTombstone.receiptMatches && serverTombstone.headMatches &&
        serverTombstone.envelopes.length === 4 &&
        serverTombstone.envelopes.every((item) => item.fieldsValid &&
          item.headerMetadataOnly && item.plaintextMarkersAbsent);
      if (!tombstoneSnapshotAccepted) {
        console.log('Vault preference tombstone snapshot shape',
          JSON.stringify(serverTombstone));
      }
      activeStage = 'Vault preference acceptance: assert loser tombstone SQLite snapshot';
      assertThat(tombstoneSnapshotAccepted,
      'server SQLite did not retain the losing record as a ciphertext-only tombstone');
      activeStage = 'Vault preference acceptance: assert SQLite plaintext markers absent';
      const databasePlaintextMarkers = serverDatabasePlaintextMarkers(
        databasePath,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      if (databasePlaintextMarkers.length > 0) {
        console.log('Vault preference SQLite plaintext marker diagnostic',
          JSON.stringify({
            matchedMarkerCount: databasePlaintextMarkers.length,
            matchedMarkers: databasePlaintextMarkers,
          }));
      }
      assertThat(databasePlaintextMarkers.length === 0,
        'server SQLite files contained preference values or repair marker plaintext');

      activeStage = 'Vault preference acceptance: B pulls and converges on winner';
      const serverStateBeforeBReturn = serverVaultPreferenceLifecycleSnapshot(
        databasePath,
        vaultId,
        secondCandidateId,
      );
      const expectedCreateSeq = preferenceLostAck.first.receipt.commitSeq;
      const createVersion = serverStateBeforeBReturn.versions.find((item) =>
        item.opId === secondCreate.opId && item.revisionId === secondCreate.revisionId);
      const createReceipt = serverStateBeforeBReturn.receipts.find((item) =>
        item.opId === secondCreate.opId && item.revisionId === secondCreate.revisionId);
      const deleteVersion = serverStateBeforeBReturn.versions.find((item) =>
        item.opId === repairDeletes[0].opId &&
        item.revisionId === repairDeletes[0].revisionId);
      const deleteReceipt = serverStateBeforeBReturn.receipts.find((item) =>
        item.opId === repairDeletes[0].opId &&
        item.revisionId === repairDeletes[0].revisionId);
      assertThat(serverStateBeforeBReturn.versions.length === 2 &&
        serverStateBeforeBReturn.versions[0].operation === 'create' &&
        createVersion?.commitSeq === expectedCreateSeq &&
        createReceipt?.commitSeq === expectedCreateSeq &&
        deleteVersion?.operation === 'delete' &&
        BigInt(deleteVersion.commitSeq) > BigInt(expectedCreateSeq) &&
        serverStateBeforeBReturn.events.length === 2 &&
        serverStateBeforeBReturn.events[0].operation === 'create' &&
        serverStateBeforeBReturn.events[0].opId === secondCreate.opId &&
        serverStateBeforeBReturn.events[0].commitSeq === expectedCreateSeq &&
        serverStateBeforeBReturn.events[1].operation === 'delete' &&
        serverStateBeforeBReturn.events[1].opId === repairDeletes[0].opId &&
        serverStateBeforeBReturn.events[1].commitSeq === deleteVersion.commitSeq &&
        serverStateBeforeBReturn.receipts.length === 2 &&
        deleteReceipt?.commitSeq === deleteVersion.commitSeq &&
        serverStateBeforeBReturn.head?.revisionId === repairDeletes[0].revisionId &&
        serverStateBeforeBReturn.head.deleted === true &&
        serverStateBeforeBReturn.head.commitSeq === deleteVersion.commitSeq &&
        serverStateBeforeBReturn.graveyard?.revisionId === repairDeletes[0].revisionId &&
        serverStateBeforeBReturn.graveyard.commitSeq === deleteVersion.commitSeq,
      'server preference lifecycle before B return did not contain one committed create followed by A tombstone');
      const retriesBeforeBReturn = preferenceLostAck.heldRetryCount;
      await secondContext.setOffline(false);
      await syncNow(secondPage);
      assertThat(preferenceLostAck.heldRetryCount === retriesBeforeBReturn,
        'Profile B reposted its pending create instead of resolving it from the pulled commit event');
      const ownCreatePulls = vaultPreferenceSyncCapture.pulls.filter((item) =>
        item.profile === 'B' && item.originProfile === 'B' &&
        item.operation === 'create' && item.recordId === secondCandidateId &&
        item.revisionId === secondCreate.revisionId &&
        item.opId === secondCreate.opId);
      assertThat(ownCreatePulls.length > 0 && ownCreatePulls.every((item) =>
        item.commitSeq === expectedCreateSeq && item.responsePlaintextMarkersAbsent &&
        item.plaintextMarkersAbsent && item.exactEnvelopeShape &&
        item.metadataOnlyHeader && item.encodedCiphertextFields),
      'Profile B did not pull its committed create receipt before applying the tombstone');
      const convergencePulls = vaultPreferenceSyncCapture.pulls.filter((item) =>
        item.profile === 'B' && item.recordId === repairDeletes[0].recordId &&
        item.opId === repairDeletes[0].opId &&
        item.revisionId === repairDeletes[0].revisionId);
      assertThat(convergencePulls.length > 0 && convergencePulls.every((item) =>
        item.responsePlaintextMarkersAbsent && item.plaintextMarkersAbsent &&
        item.exactEnvelopeShape && item.metadataOnlyHeader &&
        item.encodedCiphertextFields),
      'profile B did not pull A encrypted tombstone');
      const uniqueConvergenceSeqs = [...new Set(convergencePulls.map((item) =>
        item.commitSeq))];
      assertThat(uniqueConvergenceSeqs.length === 1 &&
        BigInt(uniqueConvergenceSeqs[0]) > BigInt(expectedCreateSeq),
      'Profile B did not observe the tombstone strictly after its own committed create');
      await secondPage.getByText(
        'Choose the default preference record to keep', { exact: true },
      ).waitFor({ state: 'hidden', timeout: 15000 });
      const selectedSectionEvidence = await secondPage.evaluate(() =>
        [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 &&
              /Default workspace section/i.test(
                `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`,
              );
          })
          .map((element) => element.getAttribute('aria-label') || element.innerText || '')
          .slice(-2),
      );
      assertThat(selectedSectionEvidence.some((label) => /Groups/.test(label)),
        'profile B did not apply the selected Groups preference after pulling the tombstone');
      await click(secondPage, 'Hosts');
      await waitUntil(async () =>
        await visiblePendingSyncValue(secondPage) === 0,
      10000, 'Profile B pending outbox count to reach zero after pull-first reconciliation');
      const pendingAfterBReturn = await pendingCardCount(secondPage);
      assertThat(pendingAfterBReturn === 0,
        'Profile B still showed its lost-ACK create as pending after pull-first reconciliation');
      await click(secondPage, 'Settings');
      const serverStateAfterBReturn = serverVaultPreferenceLifecycleSnapshot(
        databasePath,
        vaultId,
        secondCandidateId,
      );
      assertThat(stableJson(serverStateAfterBReturn) ===
        stableJson(serverStateBeforeBReturn),
      'Profile B reconciliation changed server receipts, versions, events, head, graveyard, or Vault commit sequence');
      await secondContext.unroute('**/api/v1/vaults/*/sync/push');
      preferenceLostAck.mode = 'off';

      let activeShortcutOperation = null;
      const shortcutSshDiagnosticSubsteps = new Set([
        'click-hosts',
        'await-host-record',
        'locate-host-card',
        'await-connect-control',
        'click-connect',
        'await-host-key-confirmation',
        'trust-host-key',
        'await-connected',
        'await-terminal-workspace-title',
        'await-terminal-input',
        'verify-terminal-input',
        'focus-terminal',
        'dispatch-search-shortcut',
        'await-search-field',
        'fill-search-field',
        'verify-search-input',
      ]);
      let activeShortcutSshSubstep = 'not-started';
      const runVaultPreferenceStage = async (
        stage,
        action,
        { page = secondPage, profile = 'B', fontSize = null } = {},
      ) => {
        activeStage = `Vault preference acceptance: ${stage}`;
        const stageApiStart = apiDiagnostics.length;
        try {
          return await action();
        } catch (error) {
          if (stage === 'B opens its real TerminalView on SSH') {
            const sshFixtureCounts = {
              available: false,
              tcpConnectionsAccepted: null,
              tcpConnectionsOpen: null,
              keyExchangeStarted: null,
              passwordAccepted: null,
              passwordRejected: null,
              sessionStarts: null,
              shellSessions: null,
              commandSessions: null,
            };
            try {
              const server = shortcutSshFixture?.servers?.[0];
              if (typeof server?.summary === 'function') {
                const summary = server.summary();
                const safeCount = (value) => Number.isSafeInteger(value) && value >= 0
                  ? value
                  : null;
                sshFixtureCounts.available = true;
                sshFixtureCounts.tcpConnectionsAccepted =
                  safeCount(summary.tcpConnectionsAccepted);
                sshFixtureCounts.tcpConnectionsOpen =
                  safeCount(summary.tcpConnectionsOpen);
                sshFixtureCounts.keyExchangeStarted =
                  safeCount(summary.keyExchangeStarted);
                sshFixtureCounts.passwordAccepted =
                  safeCount(summary.passwordAccepted);
                sshFixtureCounts.passwordRejected =
                  safeCount(summary.passwordRejected);
                sshFixtureCounts.sessionStarts = safeCount(summary.sessionStarts);
                sshFixtureCounts.shellSessions = safeCount(summary.shellSessions);
                sshFixtureCounts.commandSessions = safeCount(summary.commandSessions);
              }
            } catch (_) {}
            const substep = shortcutSshDiagnosticSubsteps.has(
              activeShortcutSshSubstep,
            ) ? activeShortcutSshSubstep : 'unknown';
            try {
              console.log('Vault shortcut SSH sanitized stage diagnostic',
                JSON.stringify({ substep, sshFixtureCounts }));
            } catch (_) {
              console.log('Vault shortcut SSH sanitized stage diagnostic unavailable',
                JSON.stringify({ substep: 'unknown', sshFixtureCountsAvailable: false }));
            }
            throw new Error(`Vault preference stage failed: ${stage}`);
          }
          try {
            const pageDiagnostic = profile === 'A'
              ? await safeTerminalFontSizeUiSummary(page, fontSize)
              : await safePageDiagnostic(page);
            const preferencePushCounts = Object.fromEntries(['A', 'B'].map((name) => [
              name,
              vaultPreferenceSyncCapture.pushes
                .filter((push) => push.profile === name)
                .reduce((total, push) => total + push.operations.length, 0),
            ]));
            const preferencePullCounts = Object.fromEntries(['A', 'B'].map((name) => [
              name,
              vaultPreferenceSyncCapture.pulls.filter((pull) =>
                pull.profile === name).length,
            ]));
            const preferencePullKinds = Object.fromEntries(['A', 'B'].map((name) => [
              name,
              vaultPreferenceSyncCapture.pulls
                .filter((pull) => pull.profile === name)
                .reduce((counts, pull) => {
                  const operation = pull.operation || 'unknown';
                  counts[operation] = (counts[operation] || 0) + 1;
                  return counts;
                }, {}),
            ]));
            const stageChangesPages = apiDiagnostics.slice(stageApiStart)
              .filter((entry) => entry.profile === profile &&
                entry.method === 'GET' && entry.path.endsWith('/changes'))
              .map((entry) => ({
                status: entry.status,
                eventCount: entry.changesPageSummary?.eventCount ?? null,
                hasMore: entry.changesPageSummary?.hasMore ?? null,
                requestCursorPresent:
                  entry.changesPageSummary?.requestCursorPresent === true,
                cursorAdvanced: (() => {
                  const requestSequence =
                    entry.changesPageSummary?.requestCursorSequence;
                  const nextSequence =
                    entry.changesPageSummary?.nextCursorSequence;
                  if (requestSequence == null || nextSequence == null) return null;
                  try {
                    return BigInt(nextSequence) > BigInt(requestSequence);
                  } catch (_) {
                    return null;
                  }
                })(),
              }));
            let shortcutPullEvidence = null;
            if (activeShortcutOperation && profile === 'B') {
              const matchingPulls = vaultPreferenceSyncCapture.pulls.filter((pull) =>
                pull.profile === 'B' && pull.originProfile === 'A' &&
                pull.opId === activeShortcutOperation.opId &&
                pull.recordId === activeShortcutOperation.recordId &&
                pull.revisionId === activeShortcutOperation.revisionId &&
                pull.operation === 'create');
              let searchBindingMatches = false;
              let searchBindingMatchesDefault = false;
              let searchBindingLength = null;
              try {
                const fieldValue = await focusedFieldValue(
                  page, 'Search terminal scrollback',
                );
                searchBindingMatches = fieldValue === 'mod+alt+shift+j';
                searchBindingMatchesDefault = fieldValue === 'mod+alt+shift+f';
                searchBindingLength = fieldValue.length;
              } catch (_) {}
              const conflictPanelEvidence = await visibleSemanticTextEvidence(
                page, 'Choose the shortcut preference record to keep',
              ).catch(() => ({ visibleMatchCount: 0 }));
              const conflictMessageEvidence = await visibleSemanticTextEvidence(
                page, '此 Vault 中终端快捷键偏好存在重复记录',
              ).catch(() => ({ visibleMatchCount: 0 }));
              const unsupportedPreferenceEvidence = await visibleSemanticTextEvidence(
                page, '此 Vault 含有当前客户端不支持的偏好设置。',
              ).catch(() => ({ visibleMatchCount: 0 }));
              const shortcutSaveButton = page.getByRole('button', {
                name: 'Save shortcuts', exact: true,
              });
              const shortcutSaveButtonCount = await shortcutSaveButton.count()
                .catch(() => 0);
              const shortcutSaveButtonEnabled = shortcutSaveButtonCount === 1
                ? await shortcutSaveButton.isEnabled().catch(() => false)
                : false;
              shortcutPullEvidence = {
                matchingCreatePullCount: matchingPulls.length,
                matchingPullCiphertextOnly: matchingPulls.length > 0 &&
                  matchingPulls.every((pull) => pull.responsePlaintextMarkersAbsent &&
                    pull.exactEnvelopeShape && pull.metadataOnlyHeader &&
                    pull.encodedCiphertextFields && pull.plaintextMarkersAbsent),
                matchingPullSequenceCount: matchingPulls.filter((pull) =>
                  pull.commitSeq === activeShortcutOperation.commitSeq).length,
                searchBindingMatches,
                searchBindingMatchesDefault,
                searchBindingLength,
                shortcutConflictPanelVisible:
                  conflictPanelEvidence.visibleMatchCount > 0,
                shortcutConflictMessageVisible:
                  conflictMessageEvidence.visibleMatchCount > 0,
                unsupportedPreferenceMessageVisible:
                  unsupportedPreferenceEvidence.visibleMatchCount > 0,
                shortcutSaveButtonCount,
                shortcutSaveButtonEnabled,
              };
            }
            console.log('Vault preference sanitized stage diagnostic', JSON.stringify({
              stage,
              profile,
              errorClass: safeErrorClass(error),
              errorCategory: safeErrorTextClass(error),
              page: pageDiagnostic,
              api: safeApiSummary(apiDiagnostics.slice(stageApiStart), 12),
              preferencePushCounts,
              preferencePullCounts,
              preferencePullKinds,
              changesPages: stageChangesPages,
              shortcutPullEvidence,
              pageErrorCount: pageErrors.filter((item) =>
                item.profile === profile).length,
            }));
          } catch (_) {
            console.log('Vault preference sanitized stage diagnostic', JSON.stringify({
              stage,
              profile,
              errorClass: safeErrorClass(error),
              errorCategory: safeErrorTextClass(error),
              diagnosticsUnavailable: true,
            }));
          }
          throw new Error(`Vault preference stage failed: ${stage}`);
        }
      };

      const terminalFontSize = 16;
      const preFontOperationIds = new Set(
        uniquePreferenceOperations('A').map((operation) => operation.opId),
      );
      const preFontVault = serverVaultSnapshot(databasePath, USERNAME)
        .vaults.find((item) => item.vaultId === vaultId);
      assertThat(preFontVault != null,
        'Vault preference acceptance lost its active Vault before font-size save');
      const fontApiStart = apiDiagnostics.length;
      const fontOperationStartAt = Date.now();
      await runVaultPreferenceStage(
        'A font-size preference state is ready',
        async () => {
          const fontSizeControl = ownerPage.getByRole('button', {
            name: /^Terminal font size\b/i,
          }).last();
          await fontSizeControl.scrollIntoViewIfNeeded();
          const ui = await safeTerminalFontSizeUiSummary(
            ownerPage,
            terminalFontSize,
          );
          assertThat(ui.fontSizeControlVisible &&
            !ui.preferenceErrorVisible && !ui.defaultSectionConflictVisible &&
            !ui.fontSizeConflictVisible && !ui.readOnlyVaultVisible,
          'profile A still has an unresolved or read-only Vault preference state');
        },
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );
      await runVaultPreferenceStage(
        'select terminal font-size option on A',
        async () => {
          await chooseDropdownOption(
            ownerPage,
            'Terminal font size',
            `${terminalFontSize} px`,
          );
          const selected = await selectedDropdownOptionVisible(
            ownerPage,
            'Terminal font size',
            `${terminalFontSize} px`,
          );
          assertThat(selected.fieldControlCount === 1 && selected.selectedValueVisible &&
            selected.optionCount === 0,
            'profile A terminal font-size control did not retain the selected value');
        },
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );
      await runVaultPreferenceStage(
        'A terminal font-size save button becomes enabled',
        async () => {
          const saveButton = ownerPage.getByRole('button', {
            name: 'Save terminal font size', exact: true,
          });
          await saveButton.waitFor({ state: 'visible', timeout: 10000 });
          await waitUntil(
            () => saveButton.isEnabled().catch(() => false),
            5000,
            'terminal font-size save button enabled',
          );
        },
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );
      await runVaultPreferenceStage(
        'click A terminal font-size save button',
        async () => click(ownerPage, 'Save terminal font size'),
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );
      await runVaultPreferenceStage(
        'wait for A controller save confirmation',
        async () => waitForSemanticText(ownerPage,
          `Saved ${terminalFontSize} px. This encrypted preference will sync to devices with access to this Vault.`),
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );
      await runVaultPreferenceStage(
        'sync A terminal font-size preference',
        async () => syncNow(ownerPage),
        { page: ownerPage, profile: 'A', fontSize: terminalFontSize },
      );

      const fontCreateDeadline = Date.now() + 30000;
      let ownerFontCreates = [];
      while (Date.now() < fontCreateDeadline) {
        ownerFontCreates = uniquePreferenceOperations('A').filter((operation) =>
          operation.operation === 'create' &&
          !preFontOperationIds.has(operation.opId));
        if (ownerFontCreates.length > 0) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      assertThat(ownerFontCreates.length === 1 &&
        ownerFontCreates[0].operation === 'create' &&
        ownerFontCreates[0].recordId !== ownerCreate.recordId &&
        ownerFontCreates[0].exactEnvelopeShape &&
        ownerFontCreates[0].metadataOnlyHeader &&
        ownerFontCreates[0].encodedCiphertextFields &&
        ownerFontCreates[0].plaintextMarkersAbsent,
      'profile A did not create exactly one opaque terminal font-size preference');
      const ownerFontCreate = ownerFontCreates[0];
      const ownerFontPush = vaultPreferenceSyncCapture.pushes.find((push) =>
        push.profile === 'A' && push.operations.some((operation) =>
          operation.opId === ownerFontCreate.opId));
      assertThat(ownerFontPush?.vaultId === vaultId &&
        ownerFontPush.bodyShapeValid && ownerFontPush.plaintextMarkersAbsent,
      'profile A font-size push used the wrong Vault or exposed preference plaintext');
      const fontServerSnapshot = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        ownerFontCreate,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      await waitUntil(() => apiDiagnostics.slice(fontApiStart)
        .some((entry) => entry.profile === 'A' &&
          entry.method === 'POST' && entry.path.endsWith('/sync/push') &&
          (entry.pushReceiptSummary?.results || []).some((receipt) =>
            receipt.opId === ownerFontCreate.opId &&
            receipt.revisionId === ownerFontCreate.revisionId)),
      10000, 'font-size API push receipt');
      const fontPushReceipts = apiDiagnostics.slice(fontApiStart)
        .filter((entry) => entry.profile === 'A' &&
          entry.method === 'POST' && entry.path.endsWith('/sync/push'))
        .flatMap((entry) => entry.pushReceiptSummary?.results || [])
        .filter((receipt) => receipt.opId === ownerFontCreate.opId &&
          receipt.revisionId === ownerFontCreate.revisionId);
      const fontCommitDelta = BigInt(fontServerSnapshot.headCommitSeq || '0') -
        BigInt(preFontVault.commitSeq);
      assertThat(fontCommitDelta === 1n &&
        fontServerSnapshot.versionCount === 1 &&
        fontServerSnapshot.createOperationCount === 1 &&
        fontServerSnapshot.operationCount === 1 &&
        fontServerSnapshot.eventTotalCount === 1 &&
        fontServerSnapshot.eventCount === 1 &&
        fontServerSnapshot.receiptCount === 1 &&
        fontServerSnapshot.receiptMatches && fontServerSnapshot.headMatches &&
        fontServerSnapshot.envelopes.length === 2 &&
        fontServerSnapshot.envelopes.every((envelope) =>
          envelope.fieldsValid && envelope.headerMetadataOnly &&
          envelope.plaintextMarkersAbsent) &&
        fontPushReceipts.length > 0 &&
        fontPushReceipts.every((receipt) =>
          receipt.commitSeq === fontServerSnapshot.headCommitSeq),
      'server/API did not confirm exactly one ciphertext-only font preference commit');
      const fontDatabasePlaintextMarkers = serverDatabasePlaintextMarkers(
        databasePath,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      assertThat(fontDatabasePlaintextMarkers.length === 0,
        'server SQLite, WAL, or SHM contained terminal font preference plaintext');

      const waitForBFontSizePull = async () => {
        const pullDeadline = Date.now() + 20000;
        let matchingFontPulls = [];
        while (Date.now() < pullDeadline) {
          matchingFontPulls = vaultPreferenceSyncCapture.pulls.filter((pull) =>
            pull.profile === 'B' && pull.originProfile === 'A' &&
            pull.opId === ownerFontCreate.opId &&
            pull.recordId === ownerFontCreate.recordId &&
            pull.revisionId === ownerFontCreate.revisionId &&
            pull.operation === 'create');
          if (matchingFontPulls.length > 0) break;
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        const uniqueFontPulls = [...new Map(matchingFontPulls.map((pull) =>
          [`${pull.profile}:${pull.opId}:${pull.revisionId}`, pull])).values()];
        assertThat(uniqueFontPulls.length === 1 &&
          uniqueFontPulls[0].commitSeq === fontServerSnapshot.headCommitSeq &&
          matchingFontPulls.every((pull) =>
            pull.responsePlaintextMarkersAbsent &&
            pull.plaintextMarkersAbsent && pull.exactEnvelopeShape &&
            pull.metadataOnlyHeader && pull.encodedCiphertextFields),
        'profile B did not pull the same opaque font-size create from A');
        const changesReads = apiDiagnostics.filter((entry) =>
          entry.profile === 'B' && entry.method === 'GET' &&
          entry.path.endsWith('/changes') && entry.status === 200 &&
          entry.atMs >= fontOperationStartAt);
        assertThat(changesReads.length > 0,
          'profile B font-size pull had no successful changes API response');
        return uniqueFontPulls[0];
      };
      await runVaultPreferenceStage('B pulls the font-size create from A', async () => {
        await syncNow(secondPage);
        await waitForBFontSizePull();
      });

      const preThemeOperationIds = new Set(
        uniquePreferenceOperations('A').map((operation) => operation.opId),
      );
      const preThemeVault = serverVaultSnapshot(databasePath, USERNAME)
        .vaults.find((item) => item.vaultId === vaultId);
      assertThat(preThemeVault != null,
        'Vault preference acceptance lost its active Vault before theme save');
      const themeApiStart = apiDiagnostics.length;
      const themeOperationStartAt = Date.now();
      await runVaultPreferenceStage('A terminal theme preference state is ready', async () => {
        await chooseDropdownOption(ownerPage, 'Terminal color theme', 'Light');
        const selected = await selectedDropdownOptionVisible(
          ownerPage,
          'Terminal color theme',
          'Light',
        );
        assertThat(selected.fieldControlCount === 1 &&
          selected.selectedValueVisible && selected.optionCount === 0,
        'profile A terminal-theme control did not retain the selected Light value');
      });
      await runVaultPreferenceStage('A terminal theme save button becomes enabled', async () => {
        const saveButton = ownerPage.getByRole('button', {
          name: 'Save terminal color theme', exact: true,
        });
        await saveButton.waitFor({ state: 'visible', timeout: 10000 });
        await waitUntil(
          () => saveButton.isEnabled().catch(() => false),
          5000,
          'terminal theme save button enabled',
        );
      });
      await runVaultPreferenceStage('click A terminal theme save button', async () =>
        click(ownerPage, 'Save terminal color theme'));
      await runVaultPreferenceStage('wait for A terminal theme save confirmation', async () =>
        waitForSemanticText(ownerPage,
          'Saved Light. This encrypted preference will sync to devices with access to this Vault.'));
      await runVaultPreferenceStage('sync A terminal theme preference', async () =>
        syncNow(ownerPage));

      const themeCreateDeadline = Date.now() + 30000;
      let ownerThemeCreates = [];
      while (Date.now() < themeCreateDeadline) {
        ownerThemeCreates = uniquePreferenceOperations('A').filter((operation) =>
          operation.operation === 'create' &&
          !preThemeOperationIds.has(operation.opId));
        if (ownerThemeCreates.length > 0) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      assertThat(ownerThemeCreates.length === 1 &&
        ownerThemeCreates[0].exactEnvelopeShape &&
        ownerThemeCreates[0].metadataOnlyHeader &&
        ownerThemeCreates[0].encodedCiphertextFields &&
        ownerThemeCreates[0].plaintextMarkersAbsent,
      'profile A did not create exactly one opaque terminal-theme preference');
      const ownerThemeCreate = ownerThemeCreates[0];
      const ownerThemePush = vaultPreferenceSyncCapture.pushes.find((push) =>
        push.profile === 'A' && push.operations.some((operation) =>
          operation.opId === ownerThemeCreate.opId));
      assertThat(ownerThemePush?.vaultId === vaultId &&
        ownerThemePush.bodyShapeValid && ownerThemePush.plaintextMarkersAbsent,
      'profile A terminal-theme push used the wrong Vault or exposed preference plaintext');
      const themeServerSnapshot = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        ownerThemeCreate,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      await waitUntil(() => apiDiagnostics.slice(themeApiStart)
        .some((entry) => entry.profile === 'A' &&
          entry.method === 'POST' && entry.path.endsWith('/sync/push') &&
          (entry.pushReceiptSummary?.results || []).some((receipt) =>
            receipt.opId === ownerThemeCreate.opId &&
            receipt.revisionId === ownerThemeCreate.revisionId)),
      10000, 'terminal-theme API push receipt');
      const themePushReceipts = apiDiagnostics.slice(themeApiStart)
        .filter((entry) => entry.profile === 'A' &&
          entry.method === 'POST' && entry.path.endsWith('/sync/push'))
        .flatMap((entry) => entry.pushReceiptSummary?.results || [])
        .filter((receipt) => receipt.opId === ownerThemeCreate.opId &&
          receipt.revisionId === ownerThemeCreate.revisionId);
      const themeCommitDelta =
        BigInt(themeServerSnapshot.headCommitSeq || '0') -
        BigInt(preThemeVault.commitSeq);
      assertThat(themeCommitDelta === 1n &&
        themeServerSnapshot.versionCount === 1 &&
        themeServerSnapshot.createOperationCount === 1 &&
        themeServerSnapshot.operationCount === 1 &&
        themeServerSnapshot.eventTotalCount === 1 &&
        themeServerSnapshot.eventCount === 1 &&
        themeServerSnapshot.receiptCount === 1 &&
        themeServerSnapshot.receiptMatches && themeServerSnapshot.headMatches &&
        themeServerSnapshot.envelopes.length === 2 &&
        themeServerSnapshot.envelopes.every((envelope) =>
          envelope.fieldsValid && envelope.headerMetadataOnly &&
          envelope.plaintextMarkersAbsent) &&
        themePushReceipts.length > 0 &&
        themePushReceipts.every((receipt) =>
          receipt.commitSeq === themeServerSnapshot.headCommitSeq),
      'server/API did not confirm exactly one ciphertext-only terminal-theme preference commit');
      assertThat(serverDatabasePlaintextMarkers(
        databasePath,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      ).length === 0,
      'server SQLite, WAL, or SHM contained terminal-theme preference plaintext');

      const waitForBThemePull = async () => {
        const pullDeadline = Date.now() + 20000;
        let matchingThemePulls = [];
        while (Date.now() < pullDeadline) {
          matchingThemePulls = vaultPreferenceSyncCapture.pulls.filter((pull) =>
            pull.profile === 'B' && pull.originProfile === 'A' &&
            pull.opId === ownerThemeCreate.opId &&
            pull.recordId === ownerThemeCreate.recordId &&
            pull.revisionId === ownerThemeCreate.revisionId &&
            pull.operation === 'create');
          if (matchingThemePulls.length > 0) break;
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        const uniqueThemePulls = [...new Map(matchingThemePulls.map((pull) =>
          [`${pull.profile}:${pull.opId}:${pull.revisionId}`, pull])).values()];
        const changesReads = apiDiagnostics.filter((entry) =>
          entry.profile === 'B' && entry.method === 'GET' &&
          entry.path.endsWith('/changes') && entry.status === 200 &&
          entry.atMs >= themeOperationStartAt);
        const pullEvidence = {
          matchingPullCount: matchingThemePulls.length,
          uniquePullCount: uniqueThemePulls.length,
          commitSequenceMatches: uniqueThemePulls.length === 1 &&
            uniqueThemePulls[0].commitSeq === themeServerSnapshot.headCommitSeq,
          allPulledEnvelopesOpaque: matchingThemePulls.length > 0 &&
            matchingThemePulls.every((pull) =>
              pull.responsePlaintextMarkersAbsent &&
              pull.plaintextMarkersAbsent && pull.exactEnvelopeShape &&
              pull.metadataOnlyHeader && pull.encodedCiphertextFields),
          changesReadCount: changesReads.length,
          changesStatuses: apiDiagnostics.filter((entry) =>
            entry.profile === 'B' && entry.method === 'GET' &&
            entry.path.endsWith('/changes') && entry.atMs >= themeOperationStartAt)
            .map((entry) => entry.status),
        };
        if (uniqueThemePulls.length !== 1 ||
            !pullEvidence.commitSequenceMatches ||
            !pullEvidence.allPulledEnvelopesOpaque ||
            changesReads.length === 0) {
          console.log('Vault terminal-theme pull safe evidence',
            JSON.stringify(pullEvidence));
        }
        assertThat(uniqueThemePulls.length === 1 &&
          pullEvidence.commitSequenceMatches &&
          pullEvidence.allPulledEnvelopesOpaque,
        'profile B did not pull the same opaque terminal-theme create from A');
        assertThat(changesReads.length > 0,
          'profile B terminal-theme pull had no successful changes response');
        return uniqueThemePulls[0];
      };
      await runVaultPreferenceStage('B syncs the terminal-theme create from A', async () =>
        syncNow(secondPage));
      await runVaultPreferenceStage('B changes feed contains the terminal-theme create', async () =>
        waitForBThemePull());
      await runVaultPreferenceStage('B Settings applies the decrypted Light theme', async () => {
        await click(secondPage, 'Settings');
        await waitForSemanticText(secondPage, 'Vault-synced preferences');
        const themeControl = secondPage.getByRole('button', {
          name: /^Terminal color theme\b/i,
        }).last();
        await themeControl.scrollIntoViewIfNeeded();
        await themeControl.waitFor({ state: 'visible', timeout: 10000 });
        let selected;
        await waitUntil(async () => {
          selected = await selectedDropdownOptionVisible(
            secondPage,
            'Terminal color theme',
            'Light',
          );
          return selected.fieldControlCount === 1 &&
            selected.selectedValueVisible && selected.optionCount === 0;
        }, 5000, 'profile B decrypted Light terminal theme');
        assertThat(selected.fieldControlCount === 1 &&
          selected.selectedValueVisible && selected.optionCount === 0,
        'profile B did not apply the decrypted Light terminal theme');
      });
      const shortcutSearchChord = 'mod+alt+shift+j';
      VAULT_PREFERENCE_PLAINTEXT_MARKERS.push(shortcutSearchChord);
      const preShortcutOperationIds = new Set(
        uniquePreferenceOperations('A').map((operation) => operation.opId),
      );
      const preShortcutVault = serverVaultSnapshot(databasePath, USERNAME)
        .vaults.find((item) => item.vaultId === vaultId);
      assertThat(preShortcutVault != null,
        'Vault preference acceptance lost its active Vault before shortcut save');
      const shortcutApiStart = apiDiagnostics.length;
      await runVaultPreferenceStage('A saves the semantic terminal search shortcut', async () => {
        await fill(ownerPage, 'Search terminal scrollback', shortcutSearchChord);
        const save = ownerPage.getByRole('button', {
          name: 'Save shortcuts', exact: true,
        });
        await save.waitFor({ state: 'visible', timeout: 10000 });
        await waitUntil(() => save.isEnabled().catch(() => false),
          5000, 'terminal shortcut save button enabled');
        await save.click();
        await waitForSemanticText(ownerPage,
          'Saved. These encrypted semantic bindings will sync to devices with access to this Vault.');
      }, { page: ownerPage, profile: 'A' });
      await runVaultPreferenceStage('A syncs the semantic terminal shortcut', async () =>
        syncNow(ownerPage), { page: ownerPage, profile: 'A' });

      const shortcutCreateDeadline = Date.now() + 30000;
      let ownerShortcutCreates = [];
      while (Date.now() < shortcutCreateDeadline) {
        ownerShortcutCreates = uniquePreferenceOperations('A').filter((operation) =>
          operation.operation === 'create' &&
          !preShortcutOperationIds.has(operation.opId));
        if (ownerShortcutCreates.length > 0) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      assertThat(ownerShortcutCreates.length === 1 &&
        ownerShortcutCreates[0].exactEnvelopeShape &&
        ownerShortcutCreates[0].metadataOnlyHeader &&
        ownerShortcutCreates[0].encodedCiphertextFields &&
        ownerShortcutCreates[0].plaintextMarkersAbsent,
      'profile A did not create exactly one opaque terminal-shortcut preference');
      const ownerShortcutCreate = ownerShortcutCreates[0];
      const ownerShortcutPush = vaultPreferenceSyncCapture.pushes.find((push) =>
        push.profile === 'A' && push.operations.some((operation) =>
          operation.opId === ownerShortcutCreate.opId));
      assertThat(ownerShortcutPush?.vaultId === vaultId &&
        ownerShortcutPush.bodyShapeValid && ownerShortcutPush.plaintextMarkersAbsent,
      'profile A terminal-shortcut push used the wrong Vault or exposed action/chord plaintext');
      const shortcutServerSnapshot = serverVaultPreferenceSnapshot(
        databasePath,
        vaultId,
        ownerShortcutCreate,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      activeShortcutOperation = {
        ...ownerShortcutCreate,
        commitSeq: shortcutServerSnapshot.headCommitSeq,
      };
      await waitUntil(() => apiDiagnostics.slice(shortcutApiStart).some((entry) =>
        entry.profile === 'A' && entry.method === 'POST' &&
        entry.path.endsWith('/sync/push') &&
        (entry.pushReceiptSummary?.results || []).some((receipt) =>
          receipt.opId === ownerShortcutCreate.opId &&
          receipt.revisionId === ownerShortcutCreate.revisionId)),
      10000, 'terminal-shortcut API push receipt');
      const shortcutPushReceipts = apiDiagnostics.slice(shortcutApiStart)
        .filter((entry) => entry.profile === 'A' && entry.method === 'POST' &&
          entry.path.endsWith('/sync/push'))
        .flatMap((entry) => entry.pushReceiptSummary?.results || [])
        .filter((receipt) => receipt.opId === ownerShortcutCreate.opId &&
          receipt.revisionId === ownerShortcutCreate.revisionId);
      assertThat(BigInt(shortcutServerSnapshot.headCommitSeq || '0') -
        BigInt(preShortcutVault.commitSeq) === 1n &&
        shortcutServerSnapshot.versionCount === 1 &&
        shortcutServerSnapshot.createOperationCount === 1 &&
        shortcutServerSnapshot.operationCount === 1 &&
        shortcutServerSnapshot.eventTotalCount === 1 &&
        shortcutServerSnapshot.eventCount === 1 &&
        shortcutServerSnapshot.receiptCount === 1 &&
        shortcutServerSnapshot.receiptMatches && shortcutServerSnapshot.headMatches &&
        shortcutServerSnapshot.envelopes.length === 2 &&
        shortcutServerSnapshot.envelopes.every((envelope) =>
          envelope.fieldsValid && envelope.headerMetadataOnly &&
          envelope.plaintextMarkersAbsent) &&
        shortcutPushReceipts.length === 1 &&
        shortcutPushReceipts[0].commitSeq === shortcutServerSnapshot.headCommitSeq,
      'server/API did not confirm one ciphertext-only terminal-shortcut commit');
      assertThat(serverDatabasePlaintextMarkers(
        databasePath,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      ).length === 0,
      'server SQLite, WAL, or SHM contained terminal-shortcut action/chord plaintext');

      await runVaultPreferenceStage('B pulls and decrypts the terminal shortcut', async () => {
        await syncNow(secondPage);
        await waitUntil(() => vaultPreferenceSyncCapture.pulls.some((pull) =>
          pull.profile === 'B' && pull.originProfile === 'A' &&
          pull.opId === ownerShortcutCreate.opId &&
          pull.recordId === ownerShortcutCreate.recordId &&
          pull.revisionId === ownerShortcutCreate.revisionId &&
          pull.operation === 'create'), 20000, 'B terminal shortcut pull');
        const pulled = vaultPreferenceSyncCapture.pulls.filter((pull) =>
          pull.profile === 'B' && pull.originProfile === 'A' &&
          pull.opId === ownerShortcutCreate.opId &&
          pull.recordId === ownerShortcutCreate.recordId &&
          pull.revisionId === ownerShortcutCreate.revisionId &&
          pull.operation === 'create');
        assertThat(pulled.length === 1 &&
          pulled[0].commitSeq === shortcutServerSnapshot.headCommitSeq &&
          pulled.every((pull) => pull.responsePlaintextMarkersAbsent &&
            pull.exactEnvelopeShape && pull.metadataOnlyHeader &&
            pull.encodedCiphertextFields && pull.plaintextMarkersAbsent),
        'profile B did not pull the same opaque terminal-shortcut create');
        await click(secondPage, 'Settings');
        await waitForSemanticText(secondPage, 'Vault-synced preferences');
        const shortcutSearchBinding = await field(
          secondPage, 'Search terminal scrollback',
        );
        await shortcutSearchBinding.click();
        await secondPage.waitForTimeout(150);
        await waitUntil(async () =>
          await shortcutSearchBinding.inputValue() === shortcutSearchChord,
        10000, 'profile B decrypted search shortcut binding');
      });
      const shortcutCredentialName = `shortcut-ssh-${RUN_ID.slice(0, 8)}`;
      const shortcutHostName = `shortcut-host-${RUN_ID.slice(0, 8)}`;
      VAULT_PREFERENCE_PLAINTEXT_MARKERS.push(
        shortcutCredentialName,
        shortcutHostName,
        shortcutSshUsername,
        shortcutSshPassword,
        shortcutSshAddress,
      );
      await runVaultPreferenceStage('B creates an encrypted SSH fixture credential', async () => {
        await openCredentialsPage(secondPage);
        await click(secondPage, 'Add credential');
        await fill(secondPage, 'Credential name', shortcutCredentialName);
        await fill(secondPage, 'SSH username', shortcutSshUsername);
        await fill(secondPage, 'Password', shortcutSshPassword);
        await click(secondPage, 'Save encrypted credential');
        await waitForCredentialRecord(secondPage, shortcutCredentialName, true);
        await syncNow(secondPage);
      });
      await runVaultPreferenceStage('B creates an encrypted SSH fixture Host', async () => {
        await click(secondPage, 'Hosts');
        await click(secondPage, 'Add host');
        await waitForText(secondPage, 'Add a host');
        await fill(secondPage, 'Display name', shortcutHostName);
        await fill(secondPage, 'Hostname or IP', shortcutSshAddress);
        await fill(secondPage, 'Port', String(shortcutSshPort));
        await fill(secondPage, 'SSH username', shortcutSshUsername);
        await chooseHostCredential(secondPage, shortcutCredentialName, shortcutSshUsername);
        await click(secondPage, 'Save encrypted host');
        await waitForHostRecord(
          secondPage,
          shortcutHostName,
          true,
          `${shortcutSshAddress}:${shortcutSshPort}`,
        );
        await syncNow(secondPage);
      });
      const shortcutFixtureVaultState = serverVaultSnapshot(databasePath, USERNAME)
        .vaults.find((item) => item.vaultId === vaultId);
      assertThat(shortcutFixtureVaultState != null,
        'server did not retain profile B shortcut SSH fixture records');
      await runVaultPreferenceStage('lock B', async () => {
        await click(secondPage, 'Lock');
        await field(secondPage, 'Email or username');
      });
      const locatorState = async (locator, includeEnabled = false) => {
        const count = await locator.count().catch(() => 0);
        let visibleCount = 0;
        let enabledCount = 0;
        for (let index = 0; index < count; index += 1) {
          const candidate = locator.nth(index);
          if (await candidate.isVisible().catch(() => false)) {
            visibleCount += 1;
            if (await candidate.isEnabled().catch(() => false)) enabledCount += 1;
          }
        }
        return {
          count,
          visible: visibleCount > 0,
          ...(includeEnabled ? { enabled: enabledCount > 0 } : {}),
        };
      };
      const reloadControlState = async () => ({
        inputs: {
          email: await locatorState(secondPage.locator(
            'input[aria-label*="Email or username"]',
          )),
          serverUrl: await locatorState(secondPage.locator(
            'input[aria-label*="Server URL"]',
          )),
          password: await locatorState(secondPage.locator(
            'input[aria-label*="Master password"]',
          )),
        },
        buttons: {
          continue: await locatorState(secondPage.getByRole('button', {
            name: 'Continue', exact: true,
          }), true),
          connect: await locatorState(secondPage.getByRole('button', {
            name: 'Connect securely', exact: true,
          }), true),
          signIn: await locatorState(secondPage.getByRole('button', {
            name: 'Sign in and unlock', exact: true,
          }), true),
          unlock: await locatorState(secondPage.getByRole('button', {
            name: 'Unlock', exact: true,
          }), true),
          workspace: await locatorState(secondPage.getByRole('button', {
            name: 'Add host', exact: true,
          }), true),
        },
      });
      let reloadedControls;
      await runVaultPreferenceStage('login form after reload B', async () => {
        await secondPage.reload({ waitUntil: 'domcontentloaded' });
        await enableFlutterSemantics(secondPage, 'B', startupEvidence);
        reloadedControls = await reloadControlState();
        if (reloadedControls.buttons.continue.visible &&
            reloadedControls.buttons.continue.enabled) {
          activeStage = 'Vault preference acceptance: continue workspace chooser B';
          await secondPage.getByRole('button', {
            name: 'Continue', exact: true,
          }).last().click();
        }
        let connectedToServer = false;
        const loginDeadline = Date.now() + 20000;
        while (Date.now() < loginDeadline) {
          reloadedControls = await reloadControlState();
          if (reloadedControls.buttons.workspace.visible ||
              reloadedControls.inputs.email.visible ||
              reloadedControls.inputs.password.visible) {
            break;
          }
          if (!connectedToServer && reloadedControls.inputs.serverUrl.visible &&
              reloadedControls.buttons.connect.enabled) {
            activeStage = 'Vault preference acceptance: connect server after reload B';
            try {
              await connect(secondPage, baseUrl);
            } catch (_) {
              // Connecting switches the Flutter page to sign-in. Playwright
              // can report a detached Connect button while that transition
              // succeeds; accept the transition only when the expected
              // server-backed sign-in or unlocked workspace is now visible.
              await secondPage.waitForTimeout(250);
              const afterConnect = await reloadControlState();
              const serverBackedPageVisible =
                afterConnect.buttons.workspace.visible ||
                (afterConnect.inputs.email.visible &&
                  afterConnect.inputs.password.visible);
              if (!serverBackedPageVisible) throw new Error('connect failed');
            }
            connectedToServer = true;
          }
          await secondPage.waitForTimeout(100);
        }
        reloadedControls = await reloadControlState();
        console.log('Vault preference reload controls', JSON.stringify(reloadedControls));
        assertThat(reloadedControls.buttons.workspace.visible ||
          (reloadedControls.inputs.email.visible &&
            reloadedControls.inputs.password.visible) ||
          (reloadedControls.inputs.password.visible &&
            reloadedControls.buttons.unlock.visible),
        'reloaded profile B did not expose a known workspace or unlock path');
      });
      await runVaultPreferenceStage('login submit B', async () => {
        reloadedControls = await reloadControlState();
        if (reloadedControls.buttons.workspace.visible) return;
        if (reloadedControls.inputs.email.visible &&
            reloadedControls.inputs.password.visible) {
          await fill(secondPage, 'Email or username', USERNAME);
          await fill(secondPage, 'Master password', MASTER_PASSWORD);
          await click(secondPage, 'Sign in and unlock');
          return;
        }
        if (reloadedControls.inputs.password.visible &&
            reloadedControls.buttons.unlock.visible) {
          await fill(secondPage, 'Master password', MASTER_PASSWORD);
          await click(secondPage, 'Unlock');
          return;
        }
        assertThat(false, 'profile B had no recognized login or unlock controls');
      });
      await runVaultPreferenceStage('Groups workspace applied on B', async () => {
        await waitForSemanticText(secondPage, 'Host groups', 30000);
        const newGroupButton = secondPage.getByRole('button', {
          name: 'New group', exact: true,
        });
        await newGroupButton.waitFor({ state: 'visible', timeout: 10000 });
        assertThat(await newGroupButton.isVisible(),
          'Groups workspace did not expose the New group action');
      });
      await runVaultPreferenceStage('B Settings reflects decrypted font size', async () => {
        const afterReloadVault = serverVaultSnapshot(databasePath, USERNAME)
          .vaults.find((item) => item.vaultId === vaultId);
        assertThat(afterReloadVault?.commitSeq === shortcutFixtureVaultState.commitSeq,
          'profile B reload unexpectedly committed a Vault mutation');
        await click(secondPage, 'Settings');
        await waitForSemanticText(secondPage, 'Vault-synced preferences');
        const fontSizeControl = secondPage.getByRole('button', {
          name: /^Terminal font size\b/i,
        }).last();
        await fontSizeControl.scrollIntoViewIfNeeded();
        const settingEvidence = await selectedDropdownOptionVisible(
          secondPage,
          'Terminal font size',
          `${terminalFontSize} px`,
        );
        assertThat(settingEvidence.fieldControlCount === 1 &&
          settingEvidence.selectedValueVisible && settingEvidence.optionCount === 0,
          'profile B Settings did not select the decrypted terminal font size');
        const themeControl = secondPage.getByRole('button', {
          name: /^Terminal color theme\b/i,
        }).last();
        await themeControl.scrollIntoViewIfNeeded();
        await themeControl.waitFor({ state: 'visible', timeout: 10000 });
        let themeEvidence;
        await waitUntil(async () => {
          themeEvidence = await selectedDropdownOptionVisible(
            secondPage,
            'Terminal color theme',
            'Light',
          );
          return themeEvidence.fieldControlCount === 1 &&
            themeEvidence.selectedValueVisible && themeEvidence.optionCount === 0;
        }, 5000, 'profile B terminal theme after lock/reload/login');
        assertThat(themeEvidence.fieldControlCount === 1 &&
          themeEvidence.selectedValueVisible && themeEvidence.optionCount === 0,
        'profile B Settings did not retain the decrypted terminal theme after reload');
      });
      await runVaultPreferenceStage('B opens its real TerminalView on SSH', async () => {
        activeShortcutSshSubstep = 'click-hosts';
        await click(secondPage, 'Hosts');
        activeShortcutSshSubstep = 'await-host-record';
        await waitForHostRecord(
          secondPage,
          shortcutHostName,
          true,
          `${shortcutSshAddress}:${shortcutSshPort}`,
        );
        activeShortcutSshSubstep = 'locate-host-card';
        const card = hostCardGroup(secondPage, shortcutHostName);
        const connect = card.getByRole('button', { name: 'Connect', exact: true });
        activeShortcutSshSubstep = 'await-connect-control';
        await connect.waitFor({ state: 'visible', timeout: 10000 });
        activeShortcutSshSubstep = 'click-connect';
        await connect.click();
        activeShortcutSshSubstep = 'await-host-key-confirmation';
        await secondPage.getByText('Verify SSH host key', { exact: true })
          .waitFor({ state: 'visible', timeout: 20000 });
        activeShortcutSshSubstep = 'trust-host-key';
        await click(secondPage, 'Trust after verification');
        activeShortcutSshSubstep = 'await-connected';
        await waitForSemanticText(secondPage, 'CONNECTED', 30000);
        activeShortcutSshSubstep = 'await-terminal-workspace-title';
        await secondPage.getByText('Terminal workspace', { exact: true })
          .waitFor({ state: 'visible', timeout: 15000 });
        const terminalInput = secondPage.getByRole('textbox', {
          name: 'SSH terminal input', exact: true,
        });
        activeShortcutSshSubstep = 'await-terminal-input';
        try {
          await terminalInput.waitFor({ state: 'visible', timeout: 15000 });
        } catch (_) {
          console.log('Vault terminal input exact-label diagnostic',
            JSON.stringify(await terminalInputSemanticDiagnostic(secondPage)));
          throw new Error('semantic SSH terminal input did not become visible');
        }
        activeShortcutSshSubstep = 'verify-terminal-input';
        assertThat(await terminalInput.count() === 1,
          'connected profile B did not expose one semantic TerminalView input');
        activeShortcutSshSubstep = 'focus-terminal';
        await terminalInput.click();
        activeShortcutSshSubstep = 'dispatch-search-shortcut';
        await secondPage.keyboard.press('Control+Alt+Shift+j');
        const searchField = secondPage.locator(
          'input[aria-label*="Search terminal scrollback"]',
        );
        activeShortcutSshSubstep = 'await-search-field';
        await searchField.waitFor({ state: 'visible', timeout: 10000 });
        activeShortcutSshSubstep = 'fill-search-field';
        await searchField.fill('fixture search');
        activeShortcutSshSubstep = 'verify-search-input';
        assertThat(await searchField.inputValue() === 'fixture search',
          'search TextField did not accept ordinary text after the shortcut action');
      });
      activeStage = 'Vault preference acceptance: scan server database after SSH search';
      const postSshPlaintextMarkers = serverDatabasePlaintextMarkers(
        databasePath,
        VAULT_PREFERENCE_PLAINTEXT_MARKERS,
      );
      console.log('Vault preference post-SSH database privacy scan', JSON.stringify({
        markerCount: VAULT_PREFERENCE_PLAINTEXT_MARKERS.length,
        matchingMarkerCount: postSshPlaintextMarkers.length,
        matchingMarkerCategories: postSshPlaintextMarkers.map((marker) =>
          marker === shortcutSearchChord ? 'shortcut-chord' :
          marker === shortcutCredentialName ? 'ssh-credential-name' :
          marker === shortcutHostName ? 'ssh-host-name' :
          marker === shortcutSshUsername ? 'ssh-username' :
          marker === shortcutSshPassword ? 'ssh-password' :
          marker === shortcutSshAddress ? 'ssh-address' :
          'vault-preference-marker'),
        allMarkersAbsent: postSshPlaintextMarkers.length === 0,
      }));
      assertThat(postSshPlaintextMarkers.length === 0,
      'server SQLite, WAL, or SHM contained shortcut SSH credential or Host plaintext');
      console.log('Vault preference sync acceptance passed', JSON.stringify({
        isolatedProfiles: true,
        concurrentOfflineCreates: true,
        ownerExplicitlyRetainedRecordId: ownerCandidateId,
        losingCandidateCasTombstoned: true,
        recipientPulledTombstoneAndConverged: true,
        recipientReloadedAndAppliedWinner: true,
        ownerSavedAllowedTerminalFontSize: terminalFontSize,
        recipientPulledAndDecryptedFontSizeAfterReload: true,
        recipientSettingsReflectFontSize: true,
        fontPreferenceReceiptVersionEventHeadAndCommitChecked: true,
        fontPreferenceServerAndApiCiphertextOnly: true,
        ownerSavedLightTerminalTheme: true,
        recipientPulledThemeAndAppliedIt: true,
        recipientSettingsRetainedThemeAfterLockReloadLogin: true,
        themePreferenceReceiptVersionEventHeadAndCommitChecked: true,
        themePreferenceServerAndApiCiphertextOnly: true,
        ownerSavedSemanticTerminalSearchShortcut: true,
        recipientPulledAndDecryptedShortcutBinding: true,
        shortcutActionOpenedFocusedRecipientTerminalSearch: true,
        shortcutPreferenceActionAndChordCiphertextOnly: true,
        pushPlaintextAbsent: true,
        serverDatabasePlaintextAbsent: true,
        localProfileNoApiTestRemainsIndependent: true,
      }));
      return;
    }

    // Normal profile acceptance: prove a structured Bash Snippet is encrypted
    // before leaving A, pulled as an opaque envelope by B, and reconstructed by
    // B's normal Vault decrypt/read path. This deliberately never opens the
    // execution review or sends a command to an SSH connection.
    activeStage = 'cross-profile Snippet sync: prepare isolated fixture';
    const snippetDatabasePath = path.join(dataDir, 'atermius.db');
    const snippetVaultState = serverVaultSnapshot(snippetDatabasePath, USERNAME);
    assertThat(snippetVaultState.vaults.length === 1,
      'cross-profile Snippet acceptance did not find exactly one active Vault');
    const snippetVaultId = snippetVaultState.vaults[0].vaultId;
    const snippetSuffix = RUN_ID.replaceAll('-', '');
    const snippetTitleMarker = `atermius-snippet-title-${RUN_ID}`;
    const snippetProgramMarker = `atermius_program_${snippetSuffix}`;
    const snippetParameterMarker = `atermius_parameter_${snippetSuffix}`;
    const snippetDefaultMarker = `atermius-snippet-default-${RUN_ID}`;
    const snippetArgumentMarker = `atermius-snippet-argv-${RUN_ID}`;
    const snippetTagMarker = `atermius-snippet-tag-${RUN_ID}`;
    const snippetMarkers = [
      snippetTitleMarker,
      snippetProgramMarker,
      snippetParameterMarker,
      snippetDefaultMarker,
      snippetArgumentMarker,
      snippetTagMarker,
    ];
    const snippetTitle = `E2E synchronized Bash Snippet ${snippetTitleMarker}`;
    const snippetParameters = [{
      name: snippetParameterMarker,
      type: 'text',
      default: snippetDefaultMarker,
    }];
    const snippetArguments = [
      { kind: 'literal', value: `--${snippetArgumentMarker}` },
      { kind: 'parameter', name: snippetParameterMarker },
    ];
    const snippetApiStart = apiDiagnostics.length;
    snippetSyncCapture.markers = snippetMarkers;
    snippetSyncCapture.active = true;

    activeStage = 'cross-profile Snippet sync: open A Snippets workspace';
    await click(ownerPage, 'Snippets');
    activeStage = 'cross-profile Snippet sync: wait for A Snippets workspace';
    await waitForSemanticText(ownerPage, 'Command snippets');
    activeStage = 'cross-profile Snippet sync: open new Snippet editor on A';
    await click(ownerPage, 'New snippet');
    activeStage = 'cross-profile Snippet sync: wait for new Snippet editor on A';
    await waitForSemanticText(ownerPage, 'New command snippet');
    activeStage = 'cross-profile Snippet sync: fill title on A';
    await fill(ownerPage, 'Title', snippetTitle);
    activeStage = 'cross-profile Snippet sync: select structured Bash mode on A';
    await chooseDropdownOption(
      ownerPage,
      'Execution mode',
      'Structured Bash command',
    );
    activeStage = 'cross-profile Snippet sync: fill program on A';
    await fill(ownerPage, 'Program', snippetProgramMarker);
    activeStage = 'cross-profile Snippet sync: fill text parameter schema on A';
    await fill(ownerPage, 'Parameter definitions (JSON array)',
      JSON.stringify(snippetParameters));
    activeStage = 'cross-profile Snippet sync: fill argv definition on A';
    await fill(ownerPage, 'Arguments (JSON array)',
      JSON.stringify(snippetArguments));
    activeStage = 'cross-profile Snippet sync: fill Snippet tag on A';
    await fill(ownerPage, 'Tags, separated by commas', snippetTagMarker);
    activeStage = 'cross-profile Snippet sync: save structured Snippet on A';
    await click(ownerPage, 'Save snippet');
    activeStage = 'cross-profile Snippet sync: push from A';
    await syncNow(ownerPage);

    const capturedSnippetOperations = snippetSyncCapture.pushes
      .flatMap((push) => push.operations);
    const uniqueSnippetOperations = new Map();
    for (const operation of capturedSnippetOperations) {
      const previous = uniqueSnippetOperations.get(operation.opId);
      if (previous) {
        assertThat(previous.envelopeSha256 === operation.envelopeSha256 &&
          previous.recordId === operation.recordId &&
          previous.revisionId === operation.revisionId,
        'Snippet sync retry changed the operation or encrypted envelope');
      } else {
        uniqueSnippetOperations.set(operation.opId, operation);
      }
    }
    assertThat(uniqueSnippetOperations.size === 1,
      'A did not push exactly one unique encrypted Snippet create operation');
    const snippetOperation = [...uniqueSnippetOperations.values()][0];
    assertThat(snippetOperation.operation === 'create' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
        .test(snippetOperation.recordId || ''),
    'Snippet create did not use a new UUIDv4 record operation');
    assertThat(snippetSyncCapture.pushes.length > 0 &&
      snippetSyncCapture.pushes.every((push) =>
        push.vaultId === snippetVaultId && push.bodyShapeValid &&
        push.plaintextMarkersAbsent && push.operations.length === 1 &&
        push.operations.every((item) => item.opId === snippetOperation.opId &&
          item.exactEnvelopeShape && item.metadataOnlyHeader &&
          item.encodedCiphertextFields && item.plaintextMarkersAbsent)),
    'Snippet push request exposed marker text or a non-opaque ciphertext envelope');

    activeStage = 'cross-profile Snippet sync: inspect server persistence';
    const serverSnippet = serverVaultSnippetSnapshot(
      snippetDatabasePath,
      snippetVaultId,
      snippetOperation,
      snippetMarkers,
    );
    assertThat(serverSnippet.versionCount === 1 &&
      serverSnippet.matchingVersionCount === 1 &&
      serverSnippet.eventCount === 1 &&
      serverSnippet.matchingEventCount === 1 &&
      serverSnippet.receiptCount === 1 && serverSnippet.receiptMatches &&
      serverSnippet.headMatches && serverSnippet.commitSeqMatches &&
      serverSnippet.versionEnvelope.fieldsValid &&
      serverSnippet.versionEnvelope.identityMatches &&
      serverSnippet.versionEnvelope.plaintextMarkersAbsent &&
      serverSnippet.eventEnvelope.fieldsValid &&
      serverSnippet.eventEnvelope.identityMatches &&
      serverSnippet.eventEnvelope.plaintextMarkersAbsent &&
      serverSnippet.versionEnvelopeSha256 === snippetOperation.envelopeSha256 &&
      serverSnippet.eventEnvelopeSha256 === snippetOperation.envelopeSha256 &&
      serverSnippet.versionEnvelopeSha256 === serverSnippet.eventEnvelopeSha256,
    'server did not persist exactly one matching Snippet op, version, event, and head');
    assertThat(serverDatabasePlaintextMarkers(
      snippetDatabasePath,
      snippetMarkers,
    ).length === 0,
    'server SQLite, WAL, or SHM contained Snippet plaintext markers');

    activeStage = 'cross-profile Snippet sync: B pulls encrypted record';
    await syncNow(secondPage, {
      verifyProjection: async () => {
        activeStage = 'cross-profile Snippet sync: open B Snippets workspace';
        await click(secondPage, 'Snippets');
        activeStage = 'cross-profile Snippet sync: wait for B Snippets page';
        await waitForSemanticText(secondPage, 'Command snippets');
        activeStage = 'cross-profile Snippet sync: wait for decrypted B Snippet';
        try {
          // A wire-level changes response is not acceptance. Complete the
          // sync cycle, then require the decrypted record in B's projection.
          await waitForSemanticText(secondPage, snippetTitle, 20000);
        } catch (error) {
          console.log('profile B Snippet projection safe evidence', JSON.stringify({
            expectedTitleVisible: (await visibleSemanticTextEvidence(
              secondPage, snippetTitle,
            )).visibleMatchCount,
            matchingEncryptedPullCount: snippetSyncCapture.pulls.filter((item) =>
              item.opId === snippetOperation.opId &&
              item.recordId === snippetOperation.recordId &&
              item.revisionId === snippetOperation.revisionId).length,
            page: await safePageDiagnostic(secondPage),
          }));
          throw error;
        }
      },
    });
    const pullDeadline = Date.now() + 30000;
    while (Date.now() < pullDeadline && !snippetSyncCapture.pulls.some((item) =>
      item.opId === snippetOperation.opId &&
      item.recordId === snippetOperation.recordId &&
      item.revisionId === snippetOperation.revisionId)) {
      await secondPage.waitForTimeout(100);
    }
    const snippetPulls = snippetSyncCapture.pulls.filter((item) =>
      item.opId === snippetOperation.opId &&
      item.recordId === snippetOperation.recordId &&
      item.revisionId === snippetOperation.revisionId);
    assertThat(snippetPulls.length > 0 && snippetPulls.every((item) =>
      item.responsePlaintextMarkersAbsent && item.exactEnvelopeShape &&
      item.metadataOnlyHeader && item.encodedCiphertextFields &&
      item.plaintextMarkersAbsent && item.envelopeSha256 ===
        snippetOperation.envelopeSha256),
    'profile B did not receive the same opaque encrypted Snippet operation');

    activeStage = 'cross-profile Snippet sync: verify B Snippet list row';
    const snippetEditButtons = secondPage.getByRole('button', {
      name: 'Edit', exact: true,
    });
    const snippetEditButtonCount = await snippetEditButtons.count();
    const visibleSnippetEditButtonIndexes = [];
    for (let index = 0; index < snippetEditButtonCount; index++) {
      if (await snippetEditButtons.nth(index).isVisible().catch(() => false)) {
        visibleSnippetEditButtonIndexes.push(index);
      }
    }
    const emptySnippetStateVisible = await secondPage.getByText(
      'No snippets yet', { exact: true },
    ).isVisible().catch(() => false);
    if (visibleSnippetEditButtonIndexes.length === 0 || emptySnippetStateVisible) {
      console.log('profile B Snippet list safe evidence', JSON.stringify({
        editButtonCount: snippetEditButtonCount,
        visibleEditButtonCount: visibleSnippetEditButtonIndexes.length,
        emptyStateVisible: emptySnippetStateVisible,
        expectedTitleVisible: (await visibleSemanticTextEvidence(
          secondPage, snippetTitle,
        )).visibleMatchCount,
        matchingEncryptedPullCount: snippetPulls.length,
        api: safeApiSummary(apiDiagnostics.slice(snippetApiStart), 24),
        page: await safePageDiagnostic(secondPage),
      }));
    }
    assertThat(visibleSnippetEditButtonIndexes.length >= 1 &&
      !emptySnippetStateVisible,
      'B Snippets page did not show exactly one populated editable record');
    const snippetEditButton = snippetEditButtons.nth(
      visibleSnippetEditButtonIndexes[0],
    );
    activeStage = 'cross-profile Snippet sync: open B Snippet editor';
    await snippetEditButton.click();
    activeStage = 'cross-profile Snippet sync: wait for B Snippet editor';
    await waitForSemanticText(secondPage, 'Edit command snippet');
    activeStage = 'cross-profile Snippet sync: read B title';
    const receivedTitle = await focusedFieldValue(secondPage, 'Title');
    activeStage = 'cross-profile Snippet sync: read B program';
    const receivedProgram = await focusedFieldValue(secondPage, 'Program');
    let receivedParameters;
    let receivedArguments;
    let receivedTags;
    try {
      activeStage = 'cross-profile Snippet sync: read B text parameter schema';
      receivedParameters = JSON.parse(await (
        await focusedFieldValue(secondPage, 'Parameter definitions (JSON array')
      ));
      activeStage = 'cross-profile Snippet sync: read B argv definition';
      receivedArguments = JSON.parse(await (
        await focusedFieldValue(secondPage, 'Arguments (JSON array')
      ));
      activeStage = 'cross-profile Snippet sync: read B tags';
      receivedTags = await focusedFieldValue(
        secondPage,
        'Tags, separated by commas',
      );
    } catch (_) {
      throw new Error('B Snippet editor did not expose valid structured JSON fields');
    }
    activeStage = 'cross-profile Snippet sync: inspect B mode';
    const snippetModeEvidence = await secondPage.evaluate(() => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const controls = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .map((element) =>
          `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`,
        )
        .filter((label) => /Execution mode/i.test(label));
      return {
        controlCount: controls.length,
        structuredBashSelected: controls.some((label) =>
          /Structured Bash command/.test(label)),
      };
    });
    assertThat(receivedTitle === snippetTitle &&
      snippetModeEvidence.controlCount === 1 &&
      snippetModeEvidence.structuredBashSelected &&
      receivedProgram === snippetProgramMarker &&
      stableJson(receivedParameters) === stableJson(snippetParameters) &&
      stableJson(receivedArguments) === stableJson(snippetArguments) &&
      receivedTags === snippetTagMarker,
    'B decrypted Snippet editor fields did not exactly match A structured definition');
    activeStage = 'cross-profile Snippet sync: close B editor without running';
    await click(secondPage, 'Cancel');
    assertThat(snippetSyncCapture.relayTicketRequestCount === 0 &&
      !apiDiagnostics.slice(snippetApiStart).some((entry) =>
        entry.method === 'POST' && entry.path === '/api/v1/relay/tickets'),
    'Snippet sync acceptance unexpectedly requested an SSH Relay ticket');
    snippetSyncCapture.active = false;
    activeStage = 'cross-profile Snippet sync: restore A Hosts workspace';
    await click(ownerPage, 'Hosts');
    await waitWorkspace(ownerPage);
    activeStage = 'cross-profile Snippet sync: restore B Hosts workspace';
    await click(secondPage, 'Hosts');
    await waitWorkspace(secondPage);
    console.log('WEB-SNIPPET-SYNC-01 passed', JSON.stringify({
      isolatedProfiles: true,
      structuredBashSnippetCreatedOnA: true,
      pushCiphertextOnly: true,
      pullCiphertextOnly: true,
      bDecryptedSnippetVisibleAndEditable: true,
      bSnippetListRowPresent: snippetEditButtonCount === 1 &&
        !emptySnippetStateVisible,
      modeProgramTextParameterAndArgvDefinitionsMatched: true,
      serverOpVersionEventAndHeadExactlyOnce: true,
      serverDatabasePlaintextMarkersAbsent: true,
      sshExecutionOrRelayTicketRequested: false,
      pushAttemptCount: snippetSyncCapture.pushes.length,
      matchingPullCount: snippetPulls.length,
      visibleSnippetEditButtonCount: visibleSnippetEditButtonIndexes.length,
      versionCount: serverSnippet.versionCount,
      eventCount: serverSnippet.eventCount,
      receiptCount: serverSnippet.receiptCount,
      versionAndEventEnvelopeHashesMatchedPush: true,
      relayTicketRequestCount: snippetSyncCapture.relayTicketRequestCount,
      bothProfilesRestoredToHostsWorkspace: true,
    }));

    activeStage = 'same-profile multi-tab: navigate owner tab';
    const ownerTabResponse = await ownerTabPage.goto(baseUrl, {
      waitUntil: 'domcontentloaded',
    });
    assertThat(ownerTabResponse && ownerTabResponse.status() === 200,
      'same-profile owner tab root navigation did not return HTTP 200');
    activeStage = 'same-profile multi-tab: enable owner tab semantics';
    await enableFlutterSemantics(ownerTabPage, 'A', startupEvidence);
    await selectServerModeIfChooser(ownerTabPage);
    const ownerTabConnectButton = ownerTabPage.getByRole('button', {
      name: 'Connect securely', exact: true,
    }).first();
    const ownerTabLoginField = ownerTabPage.locator(
      'input[aria-label*="Email or username"]',
    ).first();
    const ownerTabServerField = ownerTabPage.locator(
      'input[aria-label*="Server URL"]',
    ).first();
    const ownerTabAddHost = ownerTabPage.getByRole('button', {
      name: 'Add host', exact: true,
    }).first();
    const ownerTabEntryDeadline = Date.now() + 20000;
    let ownerTabEntryReady = false;
    while (Date.now() < ownerTabEntryDeadline) {
      if (await ownerTabLoginField.isVisible().catch(() => false) ||
          await ownerTabAddHost.isVisible().catch(() => false)) {
        ownerTabEntryReady = true;
        break;
      }
      const manualConnectReady =
        await ownerTabConnectButton.isVisible().catch(() => false) &&
        await ownerTabServerField.isVisible().catch(() => false);
      if (manualConnectReady) {
        // A saved server is restored asynchronously after the secure database
        // preflight. Give it a chance to transition to login before submitting
        // the transient first-run server form.
        await ownerTabPage.waitForTimeout(400);
        if (await ownerTabLoginField.isVisible().catch(() => false) ||
            await ownerTabAddHost.isVisible().catch(() => false)) {
          ownerTabEntryReady = true;
          break;
        }
        activeStage = 'same-profile multi-tab: connect owner tab';
        await connect(ownerTabPage, baseUrl);
        ownerTabEntryReady = true;
        break;
      }
      await ownerTabPage.waitForTimeout(100);
    }
    assertThat(ownerTabEntryReady,
      'same-profile owner tab did not reach its server, login, or workspace screen');
    if (await ownerTabLoginField.isVisible().catch(() => false)) {
      activeStage = 'same-profile multi-tab: sign in Owner tab';
      await fill(ownerTabPage, 'Email or username', USERNAME);
      await fill(ownerTabPage, 'Master password', MASTER_PASSWORD);
      await click(ownerTabPage, 'Sign in and unlock');
    } else if (!(await ownerTabPage.getByRole('button', {
      name: 'Add host', exact: true,
    }).isVisible().catch(() => false))) {
      console.log('same-profile tab startup diagnostic', JSON.stringify({
        page: await safePageDiagnostic(ownerTabPage),
        api: safeApiSummary(apiDiagnostics, 20),
      }));
      throw new Error('same-profile owner tab did not reach login or workspace');
    }
    activeStage = 'same-profile multi-tab: wait for owner tab workspace';
    await waitWorkspace(ownerTabPage);

    const ownerRegisteredDeviceId = observedAuthDeviceIds.get(ownerPage);
    const ownerTabLoginDeviceId = observedAuthDeviceIds.get(ownerTabPage);
    const independentDeviceId = observedAuthDeviceIds.get(secondPage);
    assertThat(typeof ownerRegisteredDeviceId === 'string' &&
      (ownerTabLoginDeviceId === undefined ||
        ownerRegisteredDeviceId === ownerTabLoginDeviceId) &&
      typeof independentDeviceId === 'string' &&
      independentDeviceId !== ownerTabLoginDeviceId,
    'same-profile tabs did not use the registered Owner device identity');
    const sameProfileStorage = await Promise.all([ownerPage, ownerTabPage].map((page) =>
      page.evaluate(async () => ({
        origin: location.origin,
        localStorageKeys: Object.keys(localStorage).sort(),
        indexedDbNames: (await indexedDB.databases())
          .map((database) => database.name)
          .filter(Boolean)
          .sort(),
      }))));
    const ownerDatabaseImplementation = multiTab.databaseImplementations.get(ownerPage);
    const ownerTabDatabaseImplementation = multiTab.databaseImplementations.get(ownerTabPage);
    const safeWebDatabaseImplementations = new Set([
      'opfsShared', 'opfsLocks', 'sharedIndexedDb',
    ]);
    assertThat(sameProfileStorage[0].origin === baseUrl &&
      sameProfileStorage[1].origin === baseUrl &&
      JSON.stringify(sameProfileStorage[0].localStorageKeys) ===
        JSON.stringify(sameProfileStorage[1].localStorageKeys) &&
      JSON.stringify(sameProfileStorage[0].indexedDbNames) ===
        JSON.stringify(sameProfileStorage[1].indexedDbNames),
    'same-profile tabs do not expose the same origin storage catalog');
    assertThat(safeWebDatabaseImplementations.has(ownerDatabaseImplementation) &&
      ownerDatabaseImplementation === ownerTabDatabaseImplementation,
    'same-profile tabs did not select the same persistent, cross-tab-safe Drift backend');

    const multiTabVaults = serverVaultSnapshot(
      path.join(dataDir, 'atermius.db'), USERNAME,
    ).vaults;
    assertThat(multiTabVaults.length === 1,
      'multi-tab Owner account did not resolve to exactly one active Vault');
    const multiTabVaultId = multiTabVaults[0].vaultId;
    const multiTabBaselineCommitSeq = multiTabVaults[0].commitSeq;
    const multiTabHostA = `same-profile-a-${RUN_ID.slice(0, 6)}`;
    const multiTabHostB = `same-profile-b-${RUN_ID.slice(0, 6)}`;
    const sameProfileReconnectApiStartIndex = apiDiagnostics.length;
    const sameProfileReconnectBrowserStartIndex = browserDiagnostics.length;
    const sameProfileReconnectPageErrorStartIndex = pageErrors.length;
    const sameProfileReconnectNotificationStartIndex = notificationEvents.length;
    activeStage = 'same-profile multi-tab: take both tabs offline';
    await ownerContext.setOffline(true);
    await Promise.all([ownerPage, ownerTabPage].map((page) =>
      page.waitForFunction(() => navigator.onLine === false, undefined, {
        timeout: 10000,
      }),
    ));
    multiTab.active = true;
    activeStage = 'same-profile multi-tab: create distinct offline Hosts';
    await Promise.all([
      addHost(ownerPage, {
        name: multiTabHostA,
        address: '198.51.100.61',
        username: 'same-profile-a',
      }),
      addHost(ownerTabPage, {
        name: multiTabHostB,
        address: '198.51.100.62',
        username: 'same-profile-b',
      }),
    ]);
    await Promise.all([
      assertVisible(ownerPage, multiTabHostA, true),
      assertVisible(ownerTabPage, multiTabHostB, true),
    ]);
    await ownerPage.waitForTimeout(700);
    const beforeReconnect = serverVaultSnapshot(
      path.join(dataDir, 'atermius.db'), USERNAME,
    ).vaults[0];
    assertThat(beforeReconnect.vaultId === multiTabVaultId &&
      beforeReconnect.commitSeq === multiTabBaselineCommitSeq,
    'offline same-profile edits reached the server before reconnection');

    activeStage = 'same-profile multi-tab: restore browser network';
    multiTab.pushAttempts.length = 0;
    try {
      await ownerContext.setOffline(false);
      await Promise.all([ownerPage, ownerTabPage].map((page) =>
        page.waitForFunction(() => navigator.onLine === true, undefined, {
          timeout: 10000,
        }),
      ));
    } catch (error) {
      console.log('same-profile network restoration safe diagnostics', JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        ownerContextPageCount: ownerContext.pages().length,
        ownerPageClosed: ownerPage.isClosed(),
        secondTabClosed: ownerTabPage.isClosed(),
        browserOnline: await Promise.all([ownerPage, ownerTabPage].map((page) =>
          page.evaluate(() => navigator.onLine).catch(() => null),
        )),
        ownerPage: await safePageDiagnostic(ownerPage),
        secondTab: await safePageDiagnostic(ownerTabPage),
      }));
      throw error;
    }
    activeStage = 'same-profile multi-tab: synchronize both online tabs';
    try {
      await Promise.all([
        syncNow(ownerPage),
        syncNow(ownerTabPage),
      ]);
    } catch (error) {
      console.log('same-profile reconnect safe diagnostics', JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        ownerPage: await safePageDiagnostic(ownerPage),
        secondTab: await safePageDiagnostic(ownerTabPage),
        api: safeApiSummary(apiDiagnostics.slice(sameProfileReconnectApiStartIndex), 80),
        authApi: apiDiagnostics.slice(sameProfileReconnectApiStartIndex)
          .filter((entry) => entry.path.startsWith('/api/v1/auth/'))
          .map((entry) => ({
            profile: entry.profile,
            method: entry.method,
            path: entry.path,
            status: entry.status,
          })),
        failedRequests: browserDiagnostics.slice(sameProfileReconnectBrowserStartIndex)
          .filter((item) => item.kind === 'request-failed' && item.path.startsWith('/api/'))
          .slice(-30),
        pageErrors: pageErrors.slice(sameProfileReconnectPageErrorStartIndex),
        notificationEvents: notificationEvents
          .slice(sameProfileReconnectNotificationStartIndex)
          .map((event) => ({
            profile: event.profile,
            direction: event.direction,
            type: event.type,
            code: event.code ?? null,
            closeCode: event.closeCode ?? null,
          })),
        pushAttemptCount: multiTab.pushAttempts.length,
      }));
      throw error;
    }
    await Promise.all([
      assertVisible(ownerPage, multiTabHostA, true),
      assertVisible(ownerPage, multiTabHostB, true),
      assertVisible(ownerTabPage, multiTabHostA, true),
      assertVisible(ownerTabPage, multiTabHostB, true),
    ]);

    const multiTabAttemptOperations = multiTab.pushAttempts.flatMap((attempt) =>
      (attempt.operations || []).map((operation) => ({
        ...operation,
        requestVaultId: attempt.vaultId,
        requestDeviceId: attempt.deviceId,
        tab: attempt.tab,
      })));
    const operationsById = new Map();
    for (const operation of multiTabAttemptOperations) {
      assertThat(operation.requestVaultId === multiTabVaultId &&
        operation.requestDeviceId === ownerRegisteredDeviceId &&
        operation.deviceId === ownerRegisteredDeviceId,
      'same-profile sync request changed Vault or device identity');
      const prior = operationsById.get(operation.opId);
      if (prior) {
        assertThat(prior.recordId === operation.recordId &&
          prior.revisionId === operation.revisionId &&
          prior.deviceSeq === operation.deviceSeq &&
          prior.envelopeSha256 === operation.envelopeSha256,
        'same-profile retry changed an operation identity or encrypted envelope');
      } else {
        operationsById.set(operation.opId, operation);
      }
    }
    const multiTabOperations = [...operationsById.values()];
    assertThat(multiTabOperations.length === 2 &&
      new Set(multiTabOperations.map((item) => item.opId)).size === 2 &&
      new Set(multiTabOperations.map((item) => item.recordId)).size === 2 &&
      new Set(multiTabOperations.map((item) => item.revisionId)).size === 2 &&
      new Set(multiTabOperations.map((item) => item.deviceSeq)).size === 2,
    `same-profile sync exposed ${multiTabOperations.length} unique operations for two distinct Hosts`);
    const multiTabSnapshot = serverMultiTabSnapshot(
      path.join(dataDir, 'atermius.db'),
      multiTabVaultId,
      ownerRegisteredDeviceId,
      multiTabOperations,
      multiTabBaselineCommitSeq,
    );
    const commitDelta = Number(multiTabSnapshot.finalCommitSeq) -
      Number(multiTabSnapshot.baselineCommitSeq);
    assertThat(multiTabSnapshot.items.length === 2 &&
      multiTabSnapshot.items.every((item) => item.receiptCount === 1 &&
        item.receiptMatches && item.recordVersionCount === 1 &&
        item.revisionVersionCount === 1 && item.versionOpMatches &&
        item.changeEventCount === 1 && item.revisionEventCount === 1 &&
        item.headCount === 1 && item.headMatches) &&
      multiTabSnapshot.matchingDeviceSequenceReceiptCount === 2 &&
      new Set(multiTabSnapshot.matchingDeviceSequences).size === 2 &&
      commitDelta === 2,
    'same-profile sync lost or duplicated an operation, version, event, head, or device sequence');
    const finalOwnerRows = await Promise.all([ownerPage, ownerTabPage].map(async (page) =>
      [
        await hostRecordVisible(page, multiTabHostA),
        await hostRecordVisible(page, multiTabHostB),
      ]));
    assertThat(finalOwnerRows.every((rows) => rows.every(Boolean)),
      'same-profile tabs did not both render the converged Host set');
    multiTab.active = false;
    console.log('same-profile multi-tab synchronization verified', JSON.stringify({
      sameRegisteredDevice: true,
      sharedOriginStorageCatalog: true,
      driftBackend: ownerDatabaseImplementation,
      offlineHosts: 2,
      uniqueOperations: multiTabOperations.length,
      wireAttempts: multiTab.pushAttempts.length,
      operationReceiptsPerHost: multiTabSnapshot.items.map((item) => item.receiptCount),
      versionsPerHost: multiTabSnapshot.items.map((item) => item.recordVersionCount),
      eventsPerHost: multiTabSnapshot.items.map((item) => item.changeEventCount),
      deviceSequencesUnique: true,
      vaultCommitDelta: commitDelta,
      bothTabsConverged: true,
    }));
    await ownerTabPage.close();

    const passwordCredentialName = `profile-a-password-${RUN_ID.slice(0, 6)}`;
    const updatedPasswordCredentialName = `${passwordCredentialName}-updated`;
    const passwordCredentialUser = `pw-${RUN_ID.slice(0, 6)}`;
    const passwordCredentialSecret = `credential-password-secret-${RUN_ID}`;
    const updatedPasswordCredentialSecret = `credential-password-updated-${RUN_ID}`;
    const privateKeyCredentialName = `profile-a-key-${RUN_ID.slice(0, 6)}`;
    const privateKeyCredentialUser = `key-${RUN_ID.slice(0, 6)}`;
    const privateKeyCredentialPassphrase = `credential-key-passphrase-${RUN_ID}`;
    const privateKeyCredentialText = crypto.generateKeyPairSync('ed25519', {
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    }).privateKey.trimEnd();
    credentialSyncCapture.markers = [
      passwordCredentialName,
      updatedPasswordCredentialName,
      passwordCredentialUser,
      passwordCredentialSecret,
      updatedPasswordCredentialSecret,
      privateKeyCredentialName,
      privateKeyCredentialUser,
      privateKeyCredentialPassphrase,
      privateKeyCredentialText,
    ];
    credentialSyncCapture.active = true;

    activeStage = 'cross-profile Credential sync: open profile A credentials';
    await openCredentialsPage(ownerPage);
    // Periodic membership refresh temporarily pauses writes. Let any due
    // refresh finish before opening the editor so Save is not rejected after
    // the dialog closes.
    activeStage = 'cross-profile Credential sync: settle profile A before editing';
    await syncNow(ownerPage);
    activeStage = 'cross-profile Credential sync: open password credential form';
    await click(ownerPage, 'Add credential');
    activeStage = 'cross-profile Credential sync: enter password credential name';
    await fill(ownerPage, 'Credential name', passwordCredentialName);
    activeStage = 'cross-profile Credential sync: enter password credential username';
    await fill(ownerPage, 'SSH username', passwordCredentialUser);
    activeStage = 'cross-profile Credential sync: enter password credential secret';
    await fill(ownerPage, 'Password', passwordCredentialSecret);
    const credentialSaveApiStart = apiDiagnostics.length;
    const credentialSavePushStart = credentialSyncCapture.pushAttempts.length;
    activeStage = 'cross-profile Credential sync: save password credential';
    await click(ownerPage, 'Save encrypted credential');
    activeStage = 'cross-profile Credential sync: confirm password credential';
    try {
      await waitForCredentialRecord(ownerPage, passwordCredentialName, true);
    } catch (error) {
      const visibleSaveError = await ownerPage.evaluate(() => {
        const text = (document.body.innerText || '').toLowerCase();
        if (/credentials? (?:could not|failed)|credential.*error/.test(text)) {
          return 'credential-save-error';
        }
        if (/登录状态已过期|reauthenticate|session.*expired/.test(text)) {
          return 'session-error';
        }
        if (/capability|required device|schema 2/.test(text)) {
          return 'capability-error';
        }
        return 'none';
      }).catch(() => 'unavailable');
      console.log('profile A local Credential save safe evidence', JSON.stringify({
        credentialEditorVisible: await ownerPage.getByText(
          'New SSH credential', { exact: true },
        ).first().isVisible().catch(() => false),
        emptyStateVisible: await ownerPage.getByText(
          'No credentials saved', { exact: true },
        ).isVisible().catch(() => false),
        visibleSaveError,
        observedCredentialPushesAfterSave:
          credentialSyncCapture.pushAttempts.length - credentialSavePushStart,
        recentApi: safeApiSummary(apiDiagnostics.slice(credentialSaveApiStart), 24),
        page: await safePageDiagnostic(ownerPage),
      }));
      throw error;
    }
    activeStage = 'cross-profile Credential sync: push password credential for local round-trip';
    await syncNow(ownerPage);
    const passwordCredentialRecordId = credentialSyncCapture.pushAttempts
      .find((item) => item.operation === 'create')?.recordId;
    assertThat(typeof passwordCredentialRecordId === 'string',
      'profile A did not submit its encrypted password Credential operation');
    activeStage = 'cross-profile Credential sync: open local password Credential editor';
    await openCredentialMenuAction(ownerPage, passwordCredentialName, 'Edit');
    activeStage = 'cross-profile Credential sync: inspect local password Credential name';
    activeStage = 'cross-profile Credential sync: inspect local password Credential name';
    const ownerCredentialNameValue = await focusedFieldValue(ownerPage, 'Credential name');
    activeStage = 'cross-profile Credential sync: inspect local password Credential username';
    const ownerCredentialUserValue = await focusedFieldValue(ownerPage, 'SSH username');
    activeStage = 'cross-profile Credential sync: inspect local password Credential secret';
    const ownerCredentialPasswordValue = await focusedFieldValue(ownerPage, 'Password');
    activeStage = 'cross-profile Credential sync: verify local password Credential fields';
    console.log('profile A password credential round-trip safe evidence', JSON.stringify({
      nameMatches: ownerCredentialNameValue === passwordCredentialName,
      usernameMatches: ownerCredentialUserValue === passwordCredentialUser,
      passwordMatches: ownerCredentialPasswordValue === passwordCredentialSecret,
      valueLengths: {
        name: ownerCredentialNameValue.length,
        username: ownerCredentialUserValue.length,
        password: ownerCredentialPasswordValue.length,
      },
    }));
    assertThat(ownerCredentialNameValue === passwordCredentialName &&
      ownerCredentialUserValue === passwordCredentialUser &&
      ownerCredentialPasswordValue === passwordCredentialSecret,
    'profile A did not retain its newly saved password Credential fields');
    await click(ownerPage, 'Cancel');

    // Profile B was already approved and unlocked. Switching to its Credentials
    // page only observes the live device sync; the test does not invoke syncNow
    // or reload B before reading the decrypted record.
    activeStage = 'cross-profile Credential sync: open profile B credentials';
    await openCredentialsPage(secondPage);
    activeStage = 'cross-profile Credential sync: profile B receives password credential';
    const profileBCredentialPageEvidence = await secondPage.evaluate((expectedName) => {
      const text = document.body.innerText || '';
      const groups = [...document.querySelectorAll('flt-semantics[role="group"]')];
      const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        })
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .map((label) => label.trim())
        .filter(Boolean);
      return {
        credentialsHeading: text.includes('SSH credentials'),
        emptyCredentialState: text.includes('No credentials saved'),
        addCredentialAction: buttons.includes('Add credential'),
        hostsHeading: text.includes('Saved hosts'),
        expectedCredentialNameInBody: text.includes(expectedName),
        expectedCredentialNameInGroup: groups.some((element) =>
          (element.getAttribute('aria-label') || '').includes(expectedName)),
        groupCount: groups.length,
        visibleButtonCount: buttons.length,
      };
    }, passwordCredentialName).catch(() => ({ unavailable: true }));
    console.log('profile B Credential sync preflight', JSON.stringify({
      credentialsHeading: profileBCredentialPageEvidence.credentialsHeading,
      emptyState: profileBCredentialPageEvidence.emptyCredentialState,
      expectedNameVisible: profileBCredentialPageEvidence.expectedCredentialNameInBody,
      groupCount: profileBCredentialPageEvidence.groupCount,
      observedPushCount: credentialSyncCapture.pushAttempts.length,
      observedPullCount: credentialSyncCapture.pulls.length,
    }));
    try {
      await waitForCredentialRecord(secondPage, passwordCredentialName, true);
    } catch (error) {
      const uiEvidence = await secondPage.evaluate((expectedName) => {
        const groups = [...document.querySelectorAll('flt-semantics[role="group"]')];
        const labels = groups.map((element) => element.getAttribute('aria-label') || '');
        return {
          expectedNameInBody: (document.body.innerText || '').includes(expectedName),
          expectedNameInGroup: labels.some((label) => label.includes(expectedName)),
          visibleGroupCount: groups.filter((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          }).length,
          visibleCredentialNameTextCount: [...document.querySelectorAll('flt-semantics')]
            .filter((element) => {
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0 &&
                (element.innerText || '').includes(expectedName);
            }).length,
        };
      }, passwordCredentialName).catch(() => ({ unavailable: true }));
      console.log('profile B Credential receipt diagnostic', JSON.stringify({
        nameVisible: uiEvidence.expectedNameInBody,
        nameGroupVisible: uiEvidence.expectedNameInGroup,
        visibleGroupCount: uiEvidence.visibleGroupCount,
        matchingTextElementCount: uiEvidence.visibleCredentialNameTextCount,
        observedPullCount: credentialSyncCapture.pulls.length,
      }));
      throw error;
    }
    activeStage = 'cross-profile Credential sync: validate password Credential push envelope';
    const waitForCredentialPull = async (recordId, operation) => {
      const deadline = Date.now() + 15000;
      while (Date.now() < deadline) {
        const found = credentialSyncCapture.pulls.find((item) =>
          item.recordId === recordId && item.operation === operation);
        if (found) return found;
        await secondPage.waitForTimeout(100);
      }
      const matchingPulls = credentialSyncCapture.pulls.filter((item) =>
        item.profile === 'B' && item.recordId === recordId);
      console.log('credential pull safe evidence', JSON.stringify({
        expectedOperation: operation,
        observedPullCount: credentialSyncCapture.pulls.length,
        matchingPullCount: matchingPulls.length,
        matchingCreateCount: matchingPulls.filter((item) => item.operation === 'create').length,
        matchingUpdateCount: matchingPulls.filter((item) => item.operation === 'update').length,
        matchingDeleteCount: matchingPulls.filter((item) => item.operation === 'delete').length,
      }));
      throw new Error(`profile B did not receive the ${operation} Credential ciphertext event`);
    };
    const assertCredentialWireEvidence = (attempts, label) => {
      assertThat(attempts.length > 0, `${label} had no observed sync push`);
      assertThat(attempts.every((item) => item.requestBodyShapeValid &&
        item.requestBodyPlaintextMarkersAbsent && item.exactEnvelopeShape &&
        item.metadataOnlyHeader && item.encodedCiphertextFields &&
        item.plaintextMarkersAbsent),
      `${label} push body was not a ciphertext-only envelope`);
      const byOperationId = new Map();
      for (const attempt of attempts) {
        const previous = byOperationId.get(attempt.opId);
        if (previous) {
          assertThat(previous.envelopeSha256 === attempt.envelopeSha256 &&
            previous.revisionId === attempt.revisionId &&
            previous.deviceSeq === attempt.deviceSeq,
          `${label} retry changed its operation identity or encrypted envelope`);
        } else {
          byOperationId.set(attempt.opId, attempt);
        }
      }
      assertThat(byOperationId.size === 1,
        `${label} generated duplicate operation identities for one edit`);
      return [...byOperationId.values()][0];
    };
    const passwordCreateOperation = assertCredentialWireEvidence(
      credentialSyncCapture.pushAttempts.filter((item) =>
        item.recordId === passwordCredentialRecordId && item.operation === 'create'),
      'password Credential create',
    );
    activeStage = 'cross-profile Credential sync: wait for password Credential ciphertext pull';
    const passwordCreatePull = await waitForCredentialPull(
      passwordCredentialRecordId, 'create',
    );
    activeStage = 'cross-profile Credential sync: validate password Credential pull envelope';
    assertThat(passwordCreatePull.plaintextMarkersAbsent &&
      passwordCreatePull.exactEnvelopeShape && passwordCreatePull.metadataOnlyHeader &&
      passwordCreatePull.encodedCiphertextFields,
    'profile B changes response exposed password Credential plaintext');
    activeStage = 'cross-profile Credential sync: open password Credential editor on profile B';
    await openCredentialMenuAction(secondPage, passwordCredentialName, 'Edit');
    const profileBEditorEvidence = await secondPage.evaluate(() => {
      const text = document.body.innerText || '';
      const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .join('\n');
      return {
        editDialogVisible: text.includes('Edit credential'),
        newDialogVisible: text.includes('New SSH credential'),
        passwordKindVisible: buttons.includes('Password'),
        privateKeyKindVisible: buttons.includes('Private key'),
      };
    }).catch(() => ({ unavailable: true }));
    activeStage = 'cross-profile Credential sync: inspect synchronized password Credential fields on profile B';
    const decryptedNameValue = await focusedFieldValue(secondPage, 'Credential name');
    const decryptedUserValue = await focusedFieldValue(secondPage, 'SSH username');
    const decryptedPasswordValue = await focusedFieldValue(secondPage, 'Password');
    activeStage = 'cross-profile Credential sync: verify synchronized password Credential fields on profile B';
    console.log('profile B decrypted password field safe evidence', JSON.stringify({
      nameMatches: decryptedNameValue === passwordCredentialName,
      usernameMatches: decryptedUserValue === passwordCredentialUser,
      matchesExpected: decryptedPasswordValue === passwordCredentialSecret,
      valueLengths: {
        name: decryptedNameValue.length,
        username: decryptedUserValue.length,
        password: decryptedPasswordValue.length,
      },
      editor: profileBEditorEvidence,
    }));
    assertThat(decryptedNameValue === passwordCredentialName &&
      decryptedUserValue === passwordCredentialUser &&
      decryptedPasswordValue === passwordCredentialSecret,
    'profile B did not decrypt the synchronized password Credential fields');
    await click(secondPage, 'Cancel');

    activeStage = 'cross-profile Credential sync: create private-key credential on profile A';
    await click(ownerPage, 'Add credential');
    await fill(ownerPage, 'Credential name', privateKeyCredentialName);
    await fill(ownerPage, 'SSH username', privateKeyCredentialUser);
    await click(ownerPage, 'Private key');
    await paste(ownerPage, 'PEM private key', privateKeyCredentialText);
    await fill(ownerPage, 'Key passphrase (optional)', privateKeyCredentialPassphrase);
    await click(ownerPage, 'Save encrypted credential');
    await waitForCredentialRecord(ownerPage, privateKeyCredentialName, true);
    await syncNow(ownerPage);
    const privateKeyCredentialRecordId = credentialSyncCapture.pushAttempts
      .find((item) => item.operation === 'create' &&
        item.recordId !== passwordCredentialRecordId)?.recordId;
    assertThat(typeof privateKeyCredentialRecordId === 'string',
      'profile A did not submit its encrypted private-key Credential operation');

    activeStage = 'cross-profile Credential sync: profile B decrypts private-key credential';
    const privateKeyCreatePull = await waitForCredentialPull(
      privateKeyCredentialRecordId, 'create',
    );
    console.log('private-key Credential pull envelope safe evidence', JSON.stringify({
      eventFound: true,
      createOperation: privateKeyCreatePull.operation === 'create',
      exactEnvelopeShape: privateKeyCreatePull.exactEnvelopeShape,
      metadataOnlyHeader: privateKeyCreatePull.metadataOnlyHeader,
      encodedCiphertextFields: privateKeyCreatePull.encodedCiphertextFields,
      plaintextMarkersAbsent: privateKeyCreatePull.plaintextMarkersAbsent,
    }));
    assertThat(privateKeyCreatePull.plaintextMarkersAbsent &&
      privateKeyCreatePull.exactEnvelopeShape && privateKeyCreatePull.metadataOnlyHeader &&
      privateKeyCreatePull.encodedCiphertextFields,
    'profile B changes response exposed private-key Credential plaintext');
    activeStage = 'cross-profile Credential sync: show private-key Credential on profile B';
    await waitForCredentialRecord(secondPage, privateKeyCredentialName, true);
    console.log('profile B private-key Credential row visible', JSON.stringify({
      expectedRecordVisible: true,
      matchingPullCount: credentialSyncCapture.pulls.filter((item) =>
        item.profile === 'B' && item.recordId === privateKeyCredentialRecordId &&
        item.operation === 'create').length,
    }));
    activeStage = 'cross-profile Credential sync: open private-key Credential editor on profile B';
    await openCredentialMenuAction(secondPage, privateKeyCredentialName, 'Edit');
    activeStage = 'cross-profile Credential sync: inspect synchronized private key on profile B';
    const decryptedPrivateKey = await focusedFieldValue(secondPage, 'PEM private key');
    activeStage = 'cross-profile Credential sync: inspect synchronized key passphrase on profile B';
    const decryptedPassphrase = await focusedFieldValue(secondPage, 'Key passphrase (optional)');
    console.log('profile B private-key Credential field safe evidence', JSON.stringify({
      privateKeyMatches: decryptedPrivateKey === privateKeyCredentialText,
      passphraseMatches: decryptedPassphrase === privateKeyCredentialPassphrase,
      valueLengths: {
        privateKey: decryptedPrivateKey.length,
        passphrase: decryptedPassphrase.length,
      },
    }));
    assertThat(decryptedPrivateKey === privateKeyCredentialText &&
      decryptedPassphrase === privateKeyCredentialPassphrase,
    'profile B did not decrypt the private-key Credential and passphrase');
    await click(secondPage, 'Cancel');

    activeStage = 'cross-profile Credential sync: open password credential editor on profile A';
    await openCredentialMenuAction(ownerPage, passwordCredentialName, 'Edit');
    activeStage = 'cross-profile Credential sync: enter updated password credential name on profile A';
    await fill(ownerPage, 'Credential name', updatedPasswordCredentialName);
    activeStage = 'cross-profile Credential sync: enter updated password credential secret on profile A';
    await fill(ownerPage, 'Password', updatedPasswordCredentialSecret);
    activeStage = 'cross-profile Credential sync: save updated password credential on profile A';
    await click(ownerPage, 'Save encrypted credential');
    activeStage = 'cross-profile Credential sync: verify updated password credential on profile A';
    await waitForCredentialRecord(ownerPage, updatedPasswordCredentialName, true);
    await waitForCredentialRecord(ownerPage, passwordCredentialName, false);
    activeStage = 'cross-profile Credential sync: sync updated password credential from profile A';
    await syncNow(ownerPage);
    activeStage = 'cross-profile Credential sync: capture updated password credential push from profile A';
    const updateCaptureDeadline = Date.now() + 15000;
    let passwordUpdateAttempts = [];
    while (Date.now() < updateCaptureDeadline) {
      passwordUpdateAttempts = credentialSyncCapture.pushAttempts.filter((item) =>
        item.recordId === passwordCredentialRecordId && item.operation === 'update');
      if (passwordUpdateAttempts.length > 0) break;
      await ownerPage.waitForTimeout(100);
    }
    activeStage = 'cross-profile Credential sync: validate updated password credential push on profile A';
    console.log('password Credential update wire safe evidence', JSON.stringify({
      totalObservedCredentialOperations: credentialSyncCapture.pushAttempts.length,
      targetUpdateOperationCount: passwordUpdateAttempts.length,
      observedOperationKinds: [...new Set(
        credentialSyncCapture.pushAttempts.map((item) => item.operation),
      )].sort(),
      syncStatusLabels: await visibleSyncStatusLabels(ownerPage),
      pendingOperationCount: await visiblePendingSyncValue(ownerPage),
      recentApi: safeApiSummary(apiDiagnostics, 12),
    }));
    const passwordUpdateOperation = assertCredentialWireEvidence(
      passwordUpdateAttempts,
      'password Credential update',
    );

    activeStage = 'cross-profile Credential sync: profile B receives password update';
    await waitForCredentialRecord(secondPage, updatedPasswordCredentialName, true);
    await waitForCredentialRecord(secondPage, passwordCredentialName, false);
    const passwordUpdatePull = await waitForCredentialPull(
      passwordCredentialRecordId, 'update',
    );
    assertThat(passwordUpdatePull.plaintextMarkersAbsent &&
      passwordUpdatePull.exactEnvelopeShape && passwordUpdatePull.metadataOnlyHeader &&
      passwordUpdatePull.encodedCiphertextFields,
    'profile B changes response exposed updated password Credential plaintext');
    await openCredentialMenuAction(secondPage, updatedPasswordCredentialName, 'Edit');
    const decryptedUpdatedPassword = await focusedFieldValue(secondPage, 'Password');
    console.log('profile B updated password field safe evidence', JSON.stringify({
      matchesExpected: decryptedUpdatedPassword === updatedPasswordCredentialSecret,
      valueLength: decryptedUpdatedPassword.length,
    }));
    assertThat(decryptedUpdatedPassword === updatedPasswordCredentialSecret,
    'profile B did not decrypt the updated password Credential secret');
    await click(secondPage, 'Cancel');

    activeStage = 'cross-profile Credential sync: open private-key delete action on profile A';
    await openCredentialMenuAction(ownerPage, privateKeyCredentialName, 'Delete');
    activeStage = 'cross-profile Credential sync: confirm private-key deletion on profile A';
    await waitForText(ownerPage, 'Delete this item?');
    activeStage = 'cross-profile Credential sync: click private-key deletion confirmation on profile A';
    await click(ownerPage, 'Delete');
    activeStage = 'cross-profile Credential sync: verify private-key tombstone on profile A';
    await waitForCredentialRecord(ownerPage, privateKeyCredentialName, false);
    activeStage = 'cross-profile Credential sync: push private-key deletion from profile A';
    await syncNow(ownerPage);
    activeStage = 'cross-profile Credential sync: verify private-key deletion envelope';
    const privateKeyDeleteOperation = assertCredentialWireEvidence(
      credentialSyncCapture.pushAttempts.filter((item) =>
        item.recordId === privateKeyCredentialRecordId && item.operation === 'delete'),
      'private-key Credential delete',
    );

    activeStage = 'cross-profile Credential sync: profile B receives private-key deletion';
    await waitForCredentialRecord(secondPage, privateKeyCredentialName, false);
    const privateKeyDeletePull = await waitForCredentialPull(
      privateKeyCredentialRecordId, 'delete',
    );
    assertThat(privateKeyDeletePull.plaintextMarkersAbsent &&
      privateKeyDeletePull.exactEnvelopeShape && privateKeyDeletePull.metadataOnlyHeader &&
      privateKeyDeletePull.encodedCiphertextFields,
    'profile B changes response exposed private-key deletion plaintext');

    const credentialExpectedOperations = [
      passwordCreateOperation,
      passwordUpdateOperation,
      credentialSyncCapture.pushAttempts.find((item) =>
        item.recordId === privateKeyCredentialRecordId && item.operation === 'create'),
      privateKeyDeleteOperation,
    ].map((item) => ({
      recordId: item.recordId,
      revisionId: item.revisionId,
      operation: item.operation,
      opId: item.opId,
    }));
    const credentialSnapshot = serverCredentialSnapshot(
      path.join(dataDir, 'atermius.db'),
      multiTabVaultId,
      credentialExpectedOperations,
      credentialSyncCapture.markers,
    );
    const credentialSnapshotById = new Map(credentialSnapshot.records.map((record) =>
      [record.recordId, record]));
    const passwordCredentialSnapshot = credentialSnapshotById.get(passwordCredentialRecordId);
    const privateKeyCredentialSnapshot = credentialSnapshotById.get(privateKeyCredentialRecordId);
    const uniqueCredentialOperationIds = new Set(
      credentialExpectedOperations.map((item) => item.opId),
    );
    assertThat(credentialSnapshot.records.length === 2 &&
      uniqueCredentialOperationIds.size === 4 &&
      passwordCredentialSnapshot?.versionCount === 2 &&
      JSON.stringify(passwordCredentialSnapshot.operations.map((item) => item.operation)) ===
        JSON.stringify(['create', 'update']) &&
      passwordCredentialSnapshot.operations.every((item) => item.receiptCount === 1 &&
        item.receiptMatches && item.revisionEventCount === 1 &&
        item.headerOperation === item.operation) &&
      privateKeyCredentialSnapshot?.versionCount === 2 &&
      JSON.stringify(privateKeyCredentialSnapshot.operations.map((item) => item.operation)) ===
        JSON.stringify(['create', 'delete']) &&
      privateKeyCredentialSnapshot.operations.every((item) => item.receiptCount === 1 &&
        item.receiptMatches && item.revisionEventCount === 1 &&
        item.headerOperation === item.operation) &&
      passwordCredentialSnapshot.allEnvelopesCiphertextOnly &&
      privateKeyCredentialSnapshot.allEnvelopesCiphertextOnly &&
      !passwordCredentialSnapshot.plaintextMarkerFound &&
      !privateKeyCredentialSnapshot.plaintextMarkerFound &&
      !passwordCredentialSnapshot.headDeleted &&
      privateKeyCredentialSnapshot.headDeleted &&
      privateKeyCredentialSnapshot.headRevisionId === privateKeyDeleteOperation.revisionId &&
      privateKeyCredentialSnapshot.graveyardRevisionId === privateKeyDeleteOperation.revisionId,
    'server Credential rows were not ciphertext-only or included duplicate/lost commits');
    assertThat(credentialSyncCapture.pulls.some((item) =>
      item.recordId === passwordCredentialRecordId && item.operation === 'create') &&
      credentialSyncCapture.pulls.some((item) =>
        item.recordId === passwordCredentialRecordId && item.operation === 'update') &&
      credentialSyncCapture.pulls.some((item) =>
        item.recordId === privateKeyCredentialRecordId && item.operation === 'create') &&
      credentialSyncCapture.pulls.some((item) =>
        item.recordId === privateKeyCredentialRecordId && item.operation === 'delete') &&
      credentialSyncCapture.pulls.every((item) => item.profile === 'B' &&
        item.responsePlaintextMarkersAbsent && item.plaintextMarkersAbsent),
    'profile B did not pull all encrypted Credential changes without plaintext');
    credentialSyncCapture.active = false;
    console.log('cross-profile Credential synchronization verified', JSON.stringify({
      approvedProfileBDecryptedPassword: true,
      approvedProfileBDecryptedPrivateKeyAndPassphrase: true,
      passwordUpdatePropagated: true,
      privateKeyDeletePropagated: true,
      serverCredentialRecords: credentialSnapshot.records.length,
      uniqueCredentialOperations: uniqueCredentialOperationIds.size,
      versionCounts: credentialSnapshot.records.map((record) => record.versionCount),
      receiptsPerOperation: credentialSnapshot.records.flatMap((record) =>
        record.operations.map((item) => item.receiptCount)),
      ciphertextOnlyRequestsAndPersistence: true,
      responsePlaintextMarkersAbsent: true,
    }));

    await click(ownerPage, 'Hosts');
    await waitWorkspace(ownerPage);
    await click(secondPage, 'Hosts');
    await waitWorkspace(secondPage);
    const hostOne = `profile-a-${RUN_ID.slice(0, 6)}`;
    activeStage = 'cross-profile sync: disconnect profile A';
    await ownerContext.setOffline(true);
    await ownerPage.waitForTimeout(500);
    activeStage = 'cross-profile sync: create offline A record';
    await addHost(ownerPage, {
      name: hostOne,
      address: '198.51.100.17',
      username: 'e2e-user',
      credential: {
        name: updatedPasswordCredentialName,
        username: passwordCredentialUser,
      },
    });
    await ownerPage.waitForTimeout(1000);
    activeStage = 'cross-profile sync: confirm offline A record';
    await assertVisible(ownerPage, hostOne, true);
    // Reconnecting can immediately resume the queued outbox. Start recording
    // the recipient notification and owner push before network restoration so
    // this test observes auto-sync work that begins inside setOffline(false).
    const reverseNotificationStart = notificationEvents.length;
    const secondApiStartIndex = apiDiagnostics.length;
    const ownerHostPushStartAtMs = Date.now();
    captureOwnerHostPush = true;
    activeStage = 'cross-profile sync: reconnect profile A';
    await ownerContext.setOffline(false);
    activeStage = 'cross-profile sync: push A record';
    await syncNow(ownerPage);
    captureOwnerHostPush = false;
    assertThat(ownerHostRecordIds.size > 0,
      'A sync push did not expose an opaque revision ID for the offline host');
    // The authenticated second profile now receives sync hints and pulls
    // automatically. Do not manually sync or reload it before asserting this.
    activeStage = 'cross-profile sync: wait for profile B automatic pull';
    await assertVisible(secondPage, hostOne, true);
    activeStage = 'cross-profile Credential sync: verify Host credential reference on profile B';
    const linkedHostCard = hostCardGroup(secondPage, hostOne);
    await linkedHostCard.getByRole('button', {
      name: 'Edit host', exact: true,
    }).click();
    await waitForText(secondPage, 'Edit host');
    const expectedLinkedCredentialText = `${updatedPasswordCredentialName} · ${passwordCredentialUser}`;
    const expectedCredentialResolution = `Host override: ${expectedLinkedCredentialText}`;
    try {
      // Assert the editor's resolved-reference explanation. Flutter's
      // DropdownButtonFormField semantics vary by renderer and do not
      // consistently combine the field label with its selected option.
      // This status is derived from Host.credentialId resolving against the
      // synchronized Credential records, so it directly verifies the link.
      await waitForSemanticText(secondPage, expectedCredentialResolution, 15000);
    } catch (error) {
      const resolvedReference = await visibleSemanticTextEvidence(
        secondPage, expectedCredentialResolution,
      );
      const unavailableReference = await visibleSemanticTextEvidence(
        secondPage, 'Host override is unavailable.',
      );
      console.log('profile B Host Credential reference safe evidence', JSON.stringify({
        editorVisible: await secondPage.getByText('Edit host', { exact: true })
          .first().isVisible().catch(() => false),
        resolvedReferenceVisibleCount: resolvedReference.visibleMatchCount,
        unavailableReferenceVisibleCount: unavailableReference.visibleMatchCount,
      }));
      throw error;
    }
    const linkedCredentialEvidence = await visibleSemanticTextEvidence(
      secondPage, expectedCredentialResolution,
    );
    assertThat(linkedCredentialEvidence.visibleMatchCount >= 1,
    'profile B did not decrypt the Host reference to its synchronized Credential');
    console.log('profile B Host Credential reference safe evidence', JSON.stringify({
      resolvedReferenceVisible: linkedCredentialEvidence.visibleMatchCount > 0,
      hostEditorVisible: true,
    }));
    await click(secondPage, 'Cancel');
    activeStage = 'cross-profile sync: verify profile B notification';
    let reverseSyncHint;
    try {
      reverseSyncHint = await waitForNotificationFrame(notificationEvents,
        (frame) => frame.profile === 'B' && frame.direction === 'received' && frame.type === 'sync_required',
        reverseNotificationStart, 12000);
    } catch (error) {
      console.log('reverse notification diagnostic', JSON.stringify({
        events: notificationEvents.slice(reverseNotificationStart).map((frame) => ({
          profile: frame.profile,
          direction: frame.direction,
          type: frame.type,
          vaultIdIsUuid: frame.vaultIdIsUuid,
          commitSeqIsDecimal: frame.commitSeqIsDecimal,
          receivedAtMs: frame.receivedAtMs,
        })),
        api: safeApiSummary(apiDiagnostics.slice(secondApiStartIndex), 35),
        page: await safePageDiagnostic(secondPage),
      }));
      throw error;
    }
    assertThat(reverseSyncHint.vaultIdIsUuid && reverseSyncHint.commitSeqIsDecimal,
      'B sync hint did not contain valid vault and commit metadata');
    const secondPull = await waitForApiEntry(apiDiagnostics, (entry) =>
      entry.profile === 'B' && entry.method === 'GET' && /\/changes$/.test(entry.path) &&
      entry.includesOwnerHostRecordId === true && entry.requestAtMs >= ownerHostPushStartAtMs &&
      entry.requestAtMs >= reverseSyncHint.receivedAtMs, secondApiStartIndex, 12000);
    assertThat(secondPull.status === 200,
      'B notification did not trigger an authorized changes pull for A’s offline host');
    const reverseHintToPullMs = secondPull.requestAtMs - reverseSyncHint.receivedAtMs;
    assertThat(reverseHintToPullMs >= 0 && reverseHintToPullMs < 5000,
      `B changes pull was not prompt after A sync hint (${reverseHintToPullMs}ms)`);
    console.log('reverse notification sync hint verified', JSON.stringify({
      hintType: reverseSyncHint.type,
      changesPullStatus: secondPull.status,
      hintToPullMs: reverseHintToPullMs,
      expectedRecordPulled: secondPull.includesOwnerHostRecordId,
      hostVisibleWithoutManualSync: true,
    }));

    // The independent black-box notification tests assert the exact ready
    // frame and first-message ticket rules. This browser flow instead verifies
    // that both clients receive sync_required and act on it without a manual
    // refresh; browser frame callbacks are unreliable for the initial frame.

    // Exercise a genuinely offline edit in the second independent profile,
    // then reconnect and synchronize it back; A must react to the server hint
    // without a manual sync click.
    const hostTwo = `profile-b-${RUN_ID.slice(0, 6)}`;
    const hostTwoEndpoint = '198.51.100.29:22';
    activeStage = 'cross-profile sync: settle B before offline create';
    await syncNow(secondPage);
    const ownerSavedHostsBeforeTargetPull = await visibleSavedHostsCount(ownerPage);
    activeStage = 'cross-profile sync: disconnect profile B for offline create';
    await secondContext.setOffline(true);
    activeStage = 'cross-profile sync: create B offline Host';
    await addHost(secondPage, {
      name: hostTwo,
      address: '198.51.100.29',
      username: 'offline-user',
    });
    activeStage = 'cross-profile sync: confirm B offline Host and queue';
    await secondPage.waitForTimeout(1000);
    await assertVisible(secondPage, hostTwo, true, hostTwoEndpoint);
    console.log('B offline Host queued UI evidence', JSON.stringify({
      hostVisible: await hostRecordVisible(secondPage, hostTwo),
      visibleSavedHostsCount: await visibleSavedHostsCount(secondPage),
      syncStatusLabels: await visibleSyncStatusLabels(secondPage),
      browserReportsOffline: await secondPage.evaluate(() => !navigator.onLine),
    }));
    const notificationStart = notificationEvents.length;
    const ownerApiStartIndex = apiDiagnostics.length;
    const ownerTargetPushStartAtMs = Date.now();
    captureTargetHostPush = true;
    activeStage = 'cross-profile sync: reconnect B';
    await secondContext.setOffline(false);
    activeStage = 'cross-profile sync: push B offline Host';
    await syncNow(secondPage);
    captureTargetHostPush = false;
    activeStage = 'cross-profile sync: verify B pushed one Host record';
    if (targetHostRecordIds.size !== 1) {
      console.log('B offline Host push safe evidence', JSON.stringify({
        capturedUniqueRecordCount: targetHostRecordIds.size,
        capturedPushRequestCount: apiDiagnostics.slice(ownerApiStartIndex)
          .filter((entry) => entry.profile === 'B' && entry.method === 'POST' &&
            entry.path.endsWith('/sync/push')).length,
        pushStatuses: apiDiagnostics.slice(ownerApiStartIndex)
          .filter((entry) => entry.profile === 'B' && entry.method === 'POST' &&
            entry.path.endsWith('/sync/push'))
          .map((entry) => entry.status),
        recentApi: safeApiSummary(
          apiDiagnostics.slice(ownerApiStartIndex), 20,
        ),
        syncStatusLabels: await visibleSyncStatusLabels(secondPage),
        pendingBadgeCount: await pendingCardCount(secondPage),
        hostVisible: await hostRecordVisible(secondPage, hostTwo),
        page: await safePageDiagnostic(secondPage),
      }));
    }
    assertThat(targetHostRecordIds.size === 1,
      `B's sync push contained ${targetHostRecordIds.size} target record IDs; expected the single offline host`);
    activeStage = 'cross-profile sync: wait for B commit notification';
    const syncHint = await waitForNotificationFrame(notificationEvents,
      (frame) => frame.profile === 'A' && frame.direction === 'received' && frame.type === 'sync_required',
      notificationStart, 12000);
    assertThat(syncHint.vaultIdIsUuid && syncHint.commitSeqIsDecimal &&
      JSON.stringify(syncHint.keys) === JSON.stringify(['commit_seq', 'type', 'vault_id']),
    'owner notification hint did not contain only valid sync metadata');
    activeStage = 'cross-profile sync: wait for A authorized changes pull';
    let ownerPull;
    try {
      ownerPull = await waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'A' && entry.method === 'GET' && /\/changes$/.test(entry.path) &&
        entry.status === 200 && entry.requestAtMs >= ownerTargetPushStartAtMs &&
        entry.requestAtMs >= syncHint.receivedAtMs, ownerApiStartIndex, 12000);
    } catch (error) {
      console.log('owner notification pull diagnostic', JSON.stringify({
        hint: {
          type: syncHint.type,
          receivedAtMs: syncHint.receivedAtMs,
          vaultIdIsUuid: syncHint.vaultIdIsUuid,
          commitSeqIsDecimal: syncHint.commitSeqIsDecimal,
        },
        ownerChangesRequests: apiDiagnostics.slice(ownerApiStartIndex)
          .filter((entry) => entry.profile === 'A' && entry.method === 'GET' &&
            /\/changes$/.test(entry.path))
          .map((entry) => ({
            status: entry.status,
            requestAtMs: entry.requestAtMs,
            atMs: entry.atMs,
            includesTargetRecordId: entry.includesTargetRecordId === true,
            eventCount: entry.changesPageSummary?.eventCount ?? null,
          })),
        recentApi: safeApiSummary(apiDiagnostics.slice(ownerApiStartIndex), 20),
        syncStatusLabels: await visibleSyncStatusLabels(ownerPage),
        ownerPendingCount: await pendingCardCount(ownerPage),
        page: await safePageDiagnostic(ownerPage),
      }));
      throw error;
    }
    assertThat(ownerPull.status === 200, 'owner sync hint did not trigger an authorized changes pull');
    const targetPulledBeforeHint = apiDiagnostics.slice(ownerApiStartIndex).some((entry) =>
      entry.profile === 'A' && entry.method === 'GET' && /\/changes$/.test(entry.path) &&
      entry.status === 200 && entry.includesTargetRecordId === true &&
      entry.requestAtMs >= ownerTargetPushStartAtMs &&
      entry.requestAtMs < syncHint.receivedAtMs);
    assertThat(ownerPull.includesTargetRecordId === true || targetPulledBeforeHint,
      'owner had not received B’s record in either the hint-triggered pull or the overlapping pre-hint pull');
    const hintToPullMs = ownerPull.requestAtMs - syncHint.receivedAtMs;
    assertThat(hintToPullMs >= 0 && hintToPullMs < 5000,
      `owner changes pull was not prompt after sync hint (${hintToPullMs}ms)`);
    activeStage = 'cross-profile sync: render B Host on A';
    try {
      await waitForHostRecord(ownerPage, hostTwo, true, hostTwoEndpoint);
    } catch (error) {
      let settledSyncStatusLabels = [];
      const settleDeadline = Date.now() + 5000;
      while (Date.now() < settleDeadline) {
        settledSyncStatusLabels = await visibleSyncStatusLabels(ownerPage);
        if (!settledSyncStatusLabels.includes('Syncing')) break;
        await ownerPage.waitForTimeout(100);
      }
      const ownerRenderState = await hostCardEvidence(ownerPage, hostTwo, hostTwoEndpoint);
      console.log('owner host pull/render diagnostic', JSON.stringify({
        renderState: ownerRenderState,
        syncStatusLabelsAfterPullSettled: settledSyncStatusLabels,
        savedHostsBeforeTargetPull: ownerSavedHostsBeforeTargetPull,
        ownerChangesPullStatus: ownerPull.status,
        ownerPullContainedTarget: ownerPull.includesTargetRecordId === true,
        ownerTargetRecordCount: targetHostRecordIds.size,
        pageErrorCount: pageErrors.length,
        api: safeApiSummary(apiDiagnostics, 10),
      }));
      throw error;
    }
    const ownerHostEvidence = await hostCardEvidence(ownerPage, hostTwo, hostTwoEndpoint);
    const ownerHostNameVisible = ownerHostEvidence.nameVisible;
    const ownerHostAddressVisible = ownerHostEvidence.endpointVisible;
    const ownerSyncStatusLabels = await visibleSyncStatusLabels(ownerPage);
    if (!ownerHostNameVisible || !ownerHostAddressVisible || !ownerPulledTargetHostRecord) {
      console.log('owner host field diagnostic', JSON.stringify({
        nameVisible: ownerHostNameVisible,
        addressAndPortVisible: ownerHostAddressVisible,
        hostCardGroupCount: ownerHostEvidence.hostCardGroupCount,
        matchingHostCardCount: ownerHostEvidence.matchingHostCardCount,
        savedHostsBeforeTargetPull: ownerSavedHostsBeforeTargetPull,
        savedHostsAfterTargetPull: ownerHostEvidence.savedHostsCount,
        syncStatusLabels: ownerSyncStatusLabels,
        ownerChangesPullStatus: ownerPull.status,
        ownerPullContainedTarget: ownerPull.includesTargetRecordId === true,
        ownerPulledTargetHostRecord,
        pageErrorCount: pageErrors.length,
        api: safeApiSummary(apiDiagnostics.slice(ownerApiStartIndex), 12),
      }));
    }
    assertThat(ownerHostNameVisible && ownerHostAddressVisible,
      'A pulled a row with the wrong host name/address after B sync');
    assertThat(ownerPulledTargetHostRecord,
      'A changes pull did not include the record ID submitted by B for the offline host');
    console.log('notification sync hint verified', JSON.stringify({
      syncHintType: syncHint.type,
      ownerChangesPullStatus: ownerPull.status,
      hintToPullMs,
      expectedRecordPulled: ownerPulledTargetHostRecord,
      recordPulledBeforeHint: targetPulledBeforeHint,
      successfulChangesPullAfterHint: true,
      expectedHostNameAndAddressVisible: true,
      manualOwnerSync: false,
    }));

    // Keep one Host edit in B's offline outbox while A advances the same
    // record. Age only this disposable Vault's change events, then invoke the
    // real server maintenance command so B exercises production cursor expiry
    // and the visible verified-snapshot recovery workflow in Chromium.
    const longOfflineHost = `profile-a-long-offline-${RUN_ID.slice(0, 6)}`;
    const longOfflineHeadName = `${longOfflineHost}-owner-head`;
    const longOfflineBranchName = `${longOfflineHost}-offline-branch`;
    const longOfflineHostEndpoint = '198.51.100.61:22';
    longOffline.active = true;
    longOffline.captureHostCreate = true;
    const longOfflineBaselineApiStartIndex = apiDiagnostics.length;
    activeStage = 'long-offline recovery: create shared Host baseline';
    await addHost(ownerPage, {
      name: longOfflineHost,
      address: '198.51.100.61',
      username: 'long-offline-user',
    });
    await syncNow(ownerPage);
    if (!(longOffline.recordId && longOffline.vaultId &&
        longOffline.initialRevisionId && longOffline.initialCommit?.opId)) {
      console.log('long-offline Host baseline safe diagnostic', JSON.stringify({
        capturedRecordId: Boolean(longOffline.recordId),
        capturedVaultId: Boolean(longOffline.vaultId),
        capturedRevisionId: Boolean(longOffline.initialRevisionId),
        capturedOperationId: Boolean(longOffline.initialCommit?.opId),
        captureStillArmed: longOffline.captureHostCreate,
        hostVisible: await hostCardEvidence(ownerPage, longOfflineHost,
          longOfflineHostEndpoint),
        syncStatusLabels: await visibleSyncStatusLabels(ownerPage),
        api: safeApiSummary(apiDiagnostics.slice(longOfflineBaselineApiStartIndex), 20),
        page: await safePageDiagnostic(ownerPage),
      }));
      throw new Error('A did not commit the long-offline Host baseline');
    }
    await waitForHostRecord(secondPage, longOfflineHost, true);
    await syncNow(secondPage);
    const longOfflineBaseline = serverLongOfflineSnapshot(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
      longOffline.recordId,
    );
    assertThat(longOfflineBaseline.headRevisionId === longOffline.initialRevisionId &&
      longOfflineBaseline.recordVersionCount === 1 &&
      longOfflineBaseline.staleOperationReceiptCount === 0,
    'long-offline Host baseline did not have one committed revision');

    activeStage = 'long-offline recovery: queue B edit while disconnected';
    await secondContext.setOffline(true);
    const longOfflineBEditApiStart = apiDiagnostics.length;
    await editHostName(secondPage, longOfflineHost, longOfflineBranchName, {
      apiDiagnostics,
      apiStartIndex: longOfflineBEditApiStart,
    });
    try {
      await waitForHostRecord(secondPage, longOfflineBranchName, true);
    } catch (error) {
      await editHostFailureDiagnostic({
        page: secondPage,
        oldName: longOfflineHost,
        newName: longOfflineBranchName,
        apiDiagnostics,
        apiStartIndex: longOfflineBEditApiStart,
        step: 'confirm-updated-row',
        error,
      });
      throw error;
    }
    activeStage = 'long-offline recovery: queue B edit while disconnected: verify pending badge';
    const longOfflinePendingCountAtFirstRender = await pendingCardCount(secondPage);
    let longOfflinePendingBefore;
    try {
      longOfflinePendingBefore = await waitForPendingCardCount(secondPage, 1);
    } catch (error) {
      await editHostFailureDiagnostic({
        page: secondPage,
        oldName: longOfflineHost,
        newName: longOfflineBranchName,
        apiDiagnostics,
        apiStartIndex: longOfflineBEditApiStart,
        step: 'wait-for-positive-pending-badge',
        error,
        errorTextClass: 'pending-badge-timeout',
      });
      console.log('long-offline pending outbox count diagnostic', JSON.stringify({
        firstObservedPendingCount: longOfflinePendingCountAtFirstRender,
        lastObservedPendingCount: await pendingCardCount(secondPage),
        requiredMinimum: 1,
      }));
      throw error;
    }
    console.log('long-offline pending outbox count confirmed', JSON.stringify({
      firstObservedPendingCount: longOfflinePendingCountAtFirstRender,
      pendingCountAfterWait: longOfflinePendingBefore,
      requiredMinimum: 1,
    }));
    assertThat(longOfflinePendingBefore !== null && longOfflinePendingBefore > 0,
      'B did not retain a measurable offline outbox item before snapshot recovery');

    activeStage = 'long-offline recovery: commit competing A head';
    const ownerHeadEditApiStart = apiDiagnostics.length;
    longOffline.captureHeadUpdate = true;
    await editHostName(ownerPage, longOfflineHost, longOfflineHeadName);
    await syncNow(ownerPage);
    longOffline.captureHeadUpdate = false;
    const capturedCompetingHead = longOffline.currentHeadUpdate;
    const capturedCompetingHeadValid =
      capturedCompetingHead?.baseRevisionId === longOffline.initialRevisionId &&
      Boolean(capturedCompetingHead?.revisionId) &&
      capturedCompetingHead.revisionId !== longOffline.initialRevisionId;
    if (!capturedCompetingHeadValid) {
      const currentHeadEvidence = serverLongOfflineSnapshot(
        path.join(dataDir, 'atermius.db'),
        longOffline.vaultId,
        longOffline.recordId,
      );
      console.log('long-offline competing head safe evidence', JSON.stringify({
        targetUpdateCaptured: Boolean(capturedCompetingHead),
        baseRevisionMatchedInitial: capturedCompetingHead?.baseRevisionId ===
          longOffline.initialRevisionId,
        capturedRevisionChanged: Boolean(capturedCompetingHead?.revisionId) &&
          capturedCompetingHead.revisionId !== longOffline.initialRevisionId,
        serverHeadIsCapturedRevision: Boolean(capturedCompetingHead?.revisionId) &&
          currentHeadEvidence.headRevisionId === capturedCompetingHead.revisionId,
        serverRecordVersionCount: currentHeadEvidence.recordVersionCount,
        ownerSyncPushResponses: apiDiagnostics.slice(ownerHeadEditApiStart)
          .filter((entry) => entry.profile === 'A' && entry.method === 'POST' &&
            entry.path.endsWith('/sync/push'))
          .map((entry) => entry.status),
      }));
    }
    assertThat(capturedCompetingHeadValid,
    'A did not commit a competing revision from the original Host base');
    const beforeCompaction = serverLongOfflineSnapshot(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
      longOffline.recordId,
    );
    assertThat(beforeCompaction.headRevisionId === longOffline.currentHeadUpdate.revisionId &&
      beforeCompaction.recordVersionCount === 2 &&
      Number(beforeCompaction.lastCommittedSeq) > Number(longOfflineBaseline.lastCommittedSeq),
    'A competing revision did not become the server Host head');

    activeStage = 'long-offline recovery: compact test Vault history';
    const agedChangeEventCount = ageVaultChangeHistory(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
    );
    const maintenanceOutput = runChecked(SERVER_BINARY, ['maintenance'], { env: serverEnv });
    assertThat(maintenanceOutput.includes('Maintenance completed.'),
      'real server history maintenance did not complete');
    const afterCompaction = serverLongOfflineSnapshot(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
      longOffline.recordId,
    );
    assertThat(afterCompaction.vaultChangeEventCount === 0 &&
      Number(afterCompaction.minimumAvailableSeq) ===
        Number(afterCompaction.lastCommittedSeq) + 1 &&
      afterCompaction.headRevisionId === beforeCompaction.headRevisionId &&
      afterCompaction.recordVersionCount === beforeCompaction.recordVersionCount,
    'maintenance did not compact the aged pull history while retaining the immutable Host head');

    const expiredApiStart = apiDiagnostics.length;
    let conflictFeedDiagnostic = null;
    const logLongOfflineWaitFailure = async (waitStage) => {
      console.log('long-offline recovery wait diagnostic', JSON.stringify({
        waitStage,
        ...await longOfflineTimeoutDiagnostic({
          page: secondPage,
          apiEntries: apiDiagnostics,
          apiStartIndex: expiredApiStart,
          databasePath: path.join(dataDir, 'atermius.db'),
          vaultId: longOffline.vaultId,
          recordId: longOffline.recordId,
          endpoint: longOfflineHostEndpoint,
          branch: longOffline.branchUploads.at(-1) ?? null,
          hostNames: {
            baseline: longOfflineHost,
            ownerHead: longOfflineHeadName,
            offlineBranch: longOfflineBranchName,
          },
          conflictFeedApiStartIndex: conflictFeedDiagnostic?.apiStartIndex ?? null,
          conflictFeedEventStartIndex: conflictFeedDiagnostic?.eventStartIndex ?? 0,
          observedBConflictEvents: observedConflictFeedEvents.B,
          expectedConflictId: conflictFeedDiagnostic?.expectedConflictId ?? null,
          expectedConflictHostLabel: conflictFeedDiagnostic?.expectedHostLabel ?? null,
        }),
      }));
    };
    const withLongOfflineWaitDiagnostic = async (waitStage, operation) => {
      activeStage = waitStage;
      try {
        return await operation();
      } catch (error) {
        try {
          await logLongOfflineWaitFailure(waitStage);
        } catch (diagnosticError) {
          // Preserve the acceptance failure if gathering diagnostics itself
          // races with page teardown or fixture cleanup. Never log either raw
          // error because they can include page or request details.
          console.log('long-offline recovery diagnostics unavailable', JSON.stringify({
            waitStage,
            primaryErrorClass: safeErrorClass(error),
            diagnosticErrorClass: safeErrorClass(diagnosticError),
          }));
        }
        throw error;
      }
    };
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: reconnect B browser context',
      () => secondContext.setOffline(false),
    );
    const hasExpiredPull = () => apiDiagnostics.slice(expiredApiStart).some((entry) =>
      entry.profile === 'B' && entry.method === 'GET' &&
      /\/changes$/.test(entry.path) && entry.status === 410 &&
      entry.errorCode === 'CURSOR_EXPIRED');
    if (!hasExpiredPull()) {
      const syncTrigger = secondPage.getByRole('button', {
        name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Key update needed|Read-only)$/,
      }).first();
      await withLongOfflineWaitDiagnostic(
        'long-offline recovery: wait for accessible sync status button',
        () => syncTrigger.waitFor({ state: 'visible', timeout: 15000 }),
      );
      const syncLabel = await syncTrigger.getAttribute('aria-label') ||
        (await syncTrigger.innerText()).trim();
      if (syncLabel !== 'Syncing') {
        await withLongOfflineWaitDiagnostic(
          'long-offline recovery: click sync status button',
          () => syncTrigger.click(),
        );
      }
    }
    const expiredPull = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for GET /changes HTTP 410 CURSOR_EXPIRED',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'GET' &&
        /\/changes$/.test(entry.path) && entry.status === 410 &&
        entry.errorCode === 'CURSOR_EXPIRED', expiredApiStart, 20000),
    );
    assertThat(longOffline.expiredPullHadCursor &&
      longOffline.expiredChangesResponses > 0,
    'B did not receive CURSOR_EXPIRED for its persisted pre-compaction cursor');
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: open Sync & conflicts recovery controls',
      () => click(secondPage, 'Sync & conflicts'),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for expired-cursor recovery message',
      () => waitForSemanticText(secondPage,
        'The sync cursor expired or the server generation changed.'),
    );
    const rebuildSnapshot = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for accessible Rebuild snapshot button',
      () => button(secondPage, 'Rebuild snapshot'),
    );
    assertThat(await rebuildSnapshot.isVisible(),
      'the visible Web recovery UI did not offer snapshot rebuilding after HTTP 410');
    const recoveryApiStart = apiDiagnostics.length;
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: click Rebuild snapshot button',
      () => rebuildSnapshot.click(),
    );
    const createdSnapshot = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for snapshot creation response',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'POST' &&
        /\/api\/v1\/vaults\/[0-9a-f-]+\/snapshots$/.test(entry.path) &&
        entry.status >= 200 && entry.status < 300, recoveryApiStart, 30000),
    );
    const fetchedSnapshot = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for snapshot fetch response',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'GET' &&
        /\/api\/v1\/snapshots\/[0-9a-f-]+$/.test(entry.path) &&
        entry.status === 200, recoveryApiStart, 30000),
    );
    const uploadedBranch = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for stale-branch conflict response',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'POST' &&
        /\/conflicts$/.test(entry.path) && entry.status >= 200 &&
        entry.status < 300 && entry.createdConflictIdObserved === true,
      recoveryApiStart, 45000),
    );
    assertThat(createdSnapshot.status === 200 && fetchedSnapshot.status === 200 &&
      uploadedBranch.status === 200 && longOffline.snapshotCreateResponses > 0 &&
      longOffline.snapshotHeadObserved?.present === true &&
      longOffline.snapshotHeadObserved?.matchesOwnerHead === true &&
      longOffline.snapshotHeadObserved?.highWatermarkPresent === true,
    'B did not fetch a verified snapshot containing A’s current Host head');
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for snapshot recovery completion message',
      () => waitForText(secondPage, '快照恢复完成'),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: return to Hosts after snapshot recovery',
      () => click(secondPage, 'Hosts'),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: verify current owner Host card after snapshot',
      () => waitForHostRecord(secondPage, longOfflineHeadName, true, longOfflineHostEndpoint),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: verify stale branch absent after snapshot',
      () => waitForHostRecord(secondPage, longOfflineBranchName, false),
    );

    const branchOperation = longOffline.branchUploads.at(-1);
    const longOfflineConflictId = [...observedConflictIds.B].at(-1);
    assertThat(branchOperation?.recordId === longOffline.recordId &&
      branchOperation?.baseRevisionId === longOffline.initialRevisionId &&
      branchOperation?.revisionId &&
      branchOperation.revisionId !== longOffline.currentHeadUpdate.revisionId &&
      branchOperation?.opId &&
      branchOperation?.envelopeSha256 &&
      typeof longOfflineConflictId === 'string' &&
      longOffline.branchUploadResponses.length === 1,
    'snapshot recovery did not preserve and upload B’s exact stale-base signed branch');

    const afterConflictUpload = serverLongOfflineSnapshot(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
      longOffline.recordId,
      branchOperation,
    );
    assertThat(afterConflictUpload.headRevisionId === longOffline.currentHeadUpdate.revisionId &&
      afterConflictUpload.lastCommittedSeq === beforeCompaction.lastCommittedSeq &&
      afterConflictUpload.recordVersionCount === beforeCompaction.recordVersionCount &&
      afterConflictUpload.staleOperationReceiptCount === 0 &&
      afterConflictUpload.staleRevisionVersionCount === 0 &&
      afterConflictUpload.staleRevisionEventCount === 0 &&
      afterConflictUpload.vaultChangeEventCount === 0 &&
      afterConflictUpload.matchingConflictCount === 1 &&
      afterConflictUpload.matchingConflictEnvelopeCount === 1 &&
      Number(afterConflictUpload.lastConflictSeq) ===
        Number(beforeCompaction.lastConflictSeq) + 1,
    'stale local branch changed the main head or created a duplicate receipt/version/event');
    assertThat(longOffline.branchPushAttempts.length === 0,
      'snapshot recovery sent the stale local branch to main-head sync/push');

    activeStage = 'long-offline recovery: make conflict visible across profiles';
    // Snapshot recovery starts the automatic sync loop after uploading the
    // preserved branch. It may pull the created event before this explicit
    // status-button click, so cover the whole recovery interval in the oracle.
    const bConflictFeedApiStart = expiredApiStart;
    conflictFeedDiagnostic = {
      apiStartIndex: bConflictFeedApiStart,
      eventStartIndex: observedConflictFeedEvents.B.length,
      expectedConflictId: longOfflineConflictId,
      expectedHostLabel: longOfflineHeadName,
    };
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: trigger B conflict-feed pull',
      () => triggerSyncWithoutWaitingForIdle(secondPage),
    );
    const bConflictFeedPull = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B successful conflict-feed pull during recovery',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'GET' &&
        /\/conflict-changes$/.test(entry.path) && entry.status === 200 &&
        entry.conflictEventSummaries?.some((event) =>
          event.type === 'created' && event.conflictId === longOfflineConflictId),
      bConflictFeedApiStart, 30000),
    );
    assertThat(bConflictFeedPull.status === 200,
      'B did not receive the expected conflict event from an authorized conflict-feed pull');
    const bConflictFeedEvent = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B conflict-feed event',
      () => waitForConflictFeedEvent(
        observedConflictFeedEvents.B,
        (event) => event.type === 'created' && event.conflictId === longOfflineConflictId,
      ),
    );
    assertThat(bConflictFeedEvent.hasEnvelope && typeof bConflictFeedEvent.seq === 'string',
      'B conflict-feed pull did not retain the expected opaque event');
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: open B conflict inbox',
      () => clickSyncConflictsNavigation(secondPage),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B conflict inbox heading',
      () => waitForText(secondPage, '跨设备冲突收件箱'),
    );
    const bConflictHostLabelEvidence = await secondPage.evaluate((expected) => {
      const bodyText = document.body.innerText || '';
      const semanticTextAndLabels = [...document.querySelectorAll('flt-semantics')]
        .filter((node) => {
          const rect = node.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        })
        .flatMap((node) => [node.innerText || '', node.getAttribute('aria-label') || '']);
      return {
        bodyTextVisible: bodyText.includes(expected),
        semanticsTextOrLabelVisible: semanticTextAndLabels.some((value) => value.includes(expected)),
      };
    }, longOfflineHeadName).catch(() => ({
      bodyTextVisible: false,
      semanticsTextOrLabelVisible: false,
    }));
    console.log('B conflict Host label visibility', JSON.stringify(bConflictHostLabelEvidence));
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B viewport-visible conflict Host label',
      () => waitForVisibleSemanticPattern(
        secondPage,
        new RegExp(escapeRegExp(longOfflineHeadName)),
      ),
    );
    const bConflictAction = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B conflict action',
      () => waitForUniqueVisibleButton(secondPage,
        '采用此分支', /采用此分支/),
    );
    const bKeepCurrentAction = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B keep-current action',
      () => waitForUniqueVisibleButton(secondPage,
        '保留当前版本', /保留当前版本/),
    );
    assertThat(await bConflictAction.isVisible() && await bConflictAction.isEnabled() &&
      await bKeepCurrentAction.isVisible() && await bKeepCurrentAction.isEnabled(),
    'B did not render unique, visible, enabled adopt and keep-current actions');

    longOffline.conflictId = longOfflineConflictId;
    const bKeepCurrentApiStart = apiDiagnostics.length;
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: open keep-current confirmation',
      () => bKeepCurrentAction.click(),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for keep-current confirmation dialog',
      () => waitForSemanticText(secondPage, '保留当前已提交版本？'),
    );
    const confirmKeepCurrent = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for enabled keep-current confirmation',
      () => waitForUniqueVisibleButton(secondPage,
        '确认保留版本', /确认保留版本/),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: confirm keep-current resolution',
      () => confirmKeepCurrent.click(),
    );
    const bKeepCurrentResponse = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B keep-current resolution response',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'POST' &&
        /\/conflicts\/[0-9a-f-]+\/resolve$/.test(entry.path) &&
        entry.status === 200 &&
        entry.longOfflineResolutionSummary?.resolved === true &&
        entry.longOfflineResolutionSummary?.resolutionSeqIsDecimal === true &&
        entry.longOfflineResolutionSummary?.matchesCurrentHead === true &&
        entry.longOfflineResolutionSummary?.alreadyResolved === false,
      bKeepCurrentApiStart, 30000),
    );
    assertThat(bKeepCurrentResponse.longOfflineResolutionSummary?.resolved === true &&
      bKeepCurrentResponse.longOfflineResolutionSummary?.resolutionSeqIsDecimal === true &&
      bKeepCurrentResponse.longOfflineResolutionSummary?.matchesCurrentHead === true &&
      bKeepCurrentResponse.longOfflineResolutionSummary?.alreadyResolved === false,
    'B did not record keep-current against A’s verified committed Host head');

    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: trigger B resolution-feed pull',
      () => triggerSyncWithoutWaitingForIdle(secondPage),
    );
    const bResolvedEventPull = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B successful resolved-event feed pull',
      () => waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'GET' &&
        /\/conflict-changes$/.test(entry.path) && entry.status === 200 &&
        entry.conflictEventSummaries?.some((event) =>
          event.type === 'resolved' && event.conflictId === longOfflineConflictId &&
          !event.hasEnvelope &&
          event.resolvedRevisionId === longOffline.currentHeadUpdate?.revisionId),
      bKeepCurrentApiStart, 30000),
    );
    assertThat(bResolvedEventPull.status === 200,
      'B did not receive the resolution event through the conflict feed');
    const longOfflineResolvedOnB = await withLongOfflineWaitDiagnostic(
      'long-offline recovery: wait for B resolved conflict event',
      () => waitForConflictFeedEvent(observedConflictFeedEvents.B,
        (event) => event.type === 'resolved' &&
          event.conflictId === longOfflineConflictId),
    );
    assertThat(!longOfflineResolvedOnB.hasEnvelope &&
      typeof longOfflineResolvedOnB.seq === 'string' &&
      longOfflineResolvedOnB.resolvedRevisionId === longOffline.currentHeadUpdate.revisionId,
    'B resolution event included ciphertext or did not name the verified current head');
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: verify B resolved inbox section',
      () => waitForSemanticText(secondPage, '已处理分支 · 1'),
    );
    await withLongOfflineWaitDiagnostic(
      'long-offline recovery: return B to Hosts after inbox resolution',
      () => click(secondPage, 'Hosts'),
    );

    await syncNow(ownerPage);
    const conflictFeedOnA = await waitForConflictFeedEvent(
      observedConflictFeedEvents.A,
      (event) => event.type === 'created' && event.conflictId === longOfflineConflictId,
    );
    const conflictFeedOnB = await waitForConflictFeedEvent(
      observedConflictFeedEvents.B,
      (event) => event.type === 'created' && event.conflictId === longOfflineConflictId,
    );
    assertThat(conflictFeedOnA.hasEnvelope && conflictFeedOnB.hasEnvelope &&
      observedConflictFeedEvents.A.filter((event) =>
        event.type === 'created' && event.conflictId === longOfflineConflictId).length === 1 &&
      observedConflictFeedEvents.B.filter((event) =>
        event.type === 'created' && event.conflictId === longOfflineConflictId).length === 1,
    'the preserved offline branch did not converge as exactly one signed conflict event');
    const longOfflineResolvedOnA = await waitForConflictFeedEvent(
      observedConflictFeedEvents.A,
      (event) => event.type === 'resolved' && event.conflictId === longOfflineConflictId,
    );
    const longOfflineResolvedOnBConfirmed = await waitForConflictFeedEvent(
      observedConflictFeedEvents.B,
      (event) => event.type === 'resolved' && event.conflictId === longOfflineConflictId,
    );
    assertThat(!longOfflineResolvedOnA.hasEnvelope &&
      !longOfflineResolvedOnBConfirmed.hasEnvelope &&
      typeof longOfflineResolvedOnA.seq === 'string' &&
      typeof longOfflineResolvedOnBConfirmed.seq === 'string' &&
      longOfflineResolvedOnA.resolvedRevisionId === longOffline.currentHeadUpdate.revisionId &&
      longOfflineResolvedOnBConfirmed.resolvedRevisionId ===
        longOffline.currentHeadUpdate.revisionId &&
      observedConflictFeedEvents.A.filter((event) =>
        event.type === 'resolved' && event.conflictId === longOfflineConflictId).length === 1 &&
      observedConflictFeedEvents.B.filter((event) =>
        event.type === 'resolved' && event.conflictId === longOfflineConflictId).length === 1,
    'the single keep-current resolution did not converge as one ciphertext-free event per profile');
    await clickSyncConflictsNavigation(ownerPage);
    await waitForText(ownerPage, '跨设备冲突收件箱');
    await waitForSemanticText(ownerPage, '已处理分支 · 1');
    await click(ownerPage, 'Hosts');
    await waitForHostRecord(ownerPage, longOfflineHeadName, true, longOfflineHostEndpoint);
    await waitForHostRecord(secondPage, longOfflineHeadName, true, longOfflineHostEndpoint);
    await Promise.all([
      waitForHostRecord(ownerPage, longOfflineBranchName, false),
      waitForHostRecord(secondPage, longOfflineBranchName, false),
    ]);
    const afterConflictRetry = serverLongOfflineSnapshot(
      path.join(dataDir, 'atermius.db'),
      longOffline.vaultId,
      longOffline.recordId,
      branchOperation,
    );
    assertThat(afterConflictRetry.headRevisionId === longOffline.currentHeadUpdate.revisionId &&
      afterConflictRetry.lastCommittedSeq === beforeCompaction.lastCommittedSeq &&
      afterConflictRetry.recordVersionCount === beforeCompaction.recordVersionCount &&
      afterConflictRetry.staleOperationReceiptCount === 0 &&
      afterConflictRetry.staleRevisionVersionCount === 0 &&
      afterConflictRetry.staleRevisionEventCount === 0 &&
      afterConflictRetry.matchingConflictCount === 1 &&
      afterConflictRetry.matchingConflictEnvelopeCount === 1 &&
      afterConflictRetry.vaultChangeEventCount === 0 &&
      Number(afterConflictRetry.lastConflictSeq) ===
        Number(afterConflictUpload.lastConflictSeq) + 1 &&
      Number(afterConflictRetry.lastConflictSeq) ===
        Number(bKeepCurrentResponse.longOfflineResolutionSummary.resolutionSeq ?? -1) &&
      longOffline.branchPushAttempts.length === 0,
    'repeated cross-profile pulls duplicated conflict state or overwrote the current head');
    longOffline.active = false;
    console.log('long-offline cursor-expiry recovery verified', JSON.stringify({
      expiredCursorHttpStatus: expiredPull.status,
      expiredCursorError: expiredPull.errorCode,
      agedChangeEvents: agedChangeEventCount,
      retainedChangeEventsAfterMaintenance: afterCompaction.vaultChangeEventCount,
      currentHeadRetainedThroughCompaction: true,
      recoveryUiObserved: true,
      snapshotFetchedAndVerified: true,
      pendingOutboxBeforeSnapshot: longOfflinePendingBefore,
      exactStaleBranchPreservedAsConflict: true,
      mainHeadPushOfStaleBranch: false,
      staleOperationReceiptCount: afterConflictRetry.staleOperationReceiptCount,
      staleRevisionVersionCount: afterConflictRetry.staleRevisionVersionCount,
      staleRevisionEventCount: afterConflictRetry.staleRevisionEventCount,
      conflictRowsForBranch: afterConflictRetry.matchingConflictCount,
      conflictEventsPerProfile: [
        observedConflictFeedEvents.A.filter((event) =>
          event.type === 'created' && event.conflictId === longOfflineConflictId).length,
        observedConflictFeedEvents.B.filter((event) =>
          event.type === 'created' && event.conflictId === longOfflineConflictId).length,
      ],
      resolutionEventsPerProfile: [
        observedConflictFeedEvents.A.filter((event) =>
          event.type === 'resolved' && event.conflictId === longOfflineConflictId).length,
        observedConflictFeedEvents.B.filter((event) =>
          event.type === 'resolved' && event.conflictId === longOfflineConflictId).length,
      ],
      keepCurrentResolutionCommitted: true,
      bothProfilesObservedResolvedEvent: true,
      bothProfilesKeepCurrentHeadVisible: true,
    }));

    // Commit a local outbox operation at the server, then simulate a lost
    // browser response and renderer restart. Recovery must resend the exact
    // signed operation under a fresh batch ID and reuse the original receipt.
    const restartHost = 'profile-a-restart-' + RUN_ID.slice(0, 6);
    activeStage = 'outbox restart recovery: create offline Host';
    await ownerContext.setOffline(true);
    await addHost(ownerPage, {
      name: restartHost,
      address: '198.51.100.33',
      username: 'restart-user',
    });
    await assertVisible(ownerPage, restartHost, true);
    await ownerContext.setOffline(false);
    outboxRecovery.mode = 'drop-first';
    activeStage = 'outbox restart recovery: commit server push and drop response';
    const outboxSyncTrigger = ownerPage.getByRole('button', {
      name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/,
    }).first();
    await outboxSyncTrigger.waitFor({ state: 'visible', timeout: 15000 });
    await outboxSyncTrigger.click();
    const firstCommitDeadline = Date.now() + 30000;
    while (Date.now() < firstCommitDeadline &&
        !outboxRecovery.first && !outboxRecovery.failureCategory) {
      await ownerPage.waitForTimeout(100);
    }
    assertThat(!outboxRecovery.failureCategory && outboxRecovery.first,
      'first push did not reach the server through the response-loss route');
    const firstOutbox = outboxRecovery.first;
    assertThat(firstOutbox.httpStatus === 200 &&
      firstOutbox.receipt?.alreadyCommitted === false &&
      firstOutbox.receipt?.opId === firstOutbox.request.opId &&
      firstOutbox.receipt?.revisionId === firstOutbox.request.revisionId &&
      /^[1-9][0-9]*$/.test(firstOutbox.receipt?.commitSeq || ''),
    'the server did not return a first-commit receipt before the browser response was dropped');
    const firstOutboxSnapshot = serverOutboxSnapshot(
      path.join(dataDir, 'atermius.db'),
      firstOutbox.request,
      firstOutbox.request.batchId,
      firstOutbox.request.batchId,
    );
    assertThat(firstOutboxSnapshot.receiptCount === 1 &&
      firstOutboxSnapshot.receipt?.revisionId === firstOutbox.request.revisionId &&
      firstOutboxSnapshot.recordVersionCount === 1 &&
      firstOutboxSnapshot.revisionVersionCount === 1 &&
      firstOutboxSnapshot.changeEventCount === 1 &&
      firstOutboxSnapshot.batchReceiptCount === 1 &&
      firstOutboxSnapshot.vaultCommitSeq === firstOutbox.receipt.commitSeq,
    'first response-loss commit did not create exactly one atomic server record and receipt');
    assertThat(outboxRecovery.mode === 'hold',
      'the browser response was not lost before the local operation remained queued');
    // Give the rejected fetch a turn to settle in Flutter before replacing
    // its renderer; the post-reload replay below is the durable-outbox proof.
    await ownerPage.waitForTimeout(500);

    activeStage = 'outbox restart recovery: reload browser page';
    await ownerPage.reload({ waitUntil: 'domcontentloaded' });
    activeStage = 'outbox restart recovery: restart Flutter renderer';
    await enableFlutterSemantics(ownerPage, 'A', startupEvidence);
    activeStage = 'outbox restart recovery: restore configured server';
    const reconnectButton = ownerPage.getByRole('button', {
      name: 'Connect securely',
      exact: true,
    }).first();
    if (await reconnectButton.isVisible().catch(() => false)) {
      await connect(ownerPage, baseUrl);
    }
    activeStage = 'outbox restart recovery: wait for login form';
    await field(ownerPage, 'Email or username');
    activeStage = 'outbox restart recovery: reauthenticate same Web profile';
    await fill(ownerPage, 'Email or username', USERNAME);
    await fill(ownerPage, 'Master password', MASTER_PASSWORD);
    await click(ownerPage, 'Sign in and unlock');
    await waitWorkspace(ownerPage);
    activeStage = 'outbox restart recovery: reconcile persisted operation from server changes';
    await syncNow(ownerPage);
    const reconciliationDeadline = Date.now() + 8000;
    while (Date.now() < reconciliationDeadline &&
        !outboxRecovery.reconciledEvent) {
      await ownerPage.waitForTimeout(100);
    }
    assertThat(outboxRecovery.reconciledEvent,
      'the reloaded browser did not pull the server commit matching its persisted outbox operation');
    const reconciledOutbox = outboxRecovery.reconciledEvent;
    assertThat(reconciledOutbox.opId === firstOutbox.request.opId &&
      reconciledOutbox.revisionId === firstOutbox.request.revisionId &&
      reconciledOutbox.recordId === firstOutbox.request.recordId &&
      reconciledOutbox.envelopeSha256 === firstOutbox.request.envelopeSha256 &&
      reconciledOutbox.commitSeq === firstOutbox.receipt.commitSeq,
    'server changes did not contain the exact signed operation that survived the browser reload');
    const reconciledOutboxSnapshot = serverOutboxSnapshot(
      path.join(dataDir, 'atermius.db'),
      firstOutbox.request,
      firstOutbox.request.batchId,
      firstOutbox.request.batchId,
    );
    assertThat(reconciledOutboxSnapshot.receiptCount === 1 &&
      reconciledOutboxSnapshot.receipt?.revisionId === firstOutbox.request.revisionId &&
      reconciledOutboxSnapshot.recordVersionCount === 1 &&
      reconciledOutboxSnapshot.revisionVersionCount === 1 &&
      reconciledOutboxSnapshot.changeEventCount === 1 &&
      reconciledOutboxSnapshot.batchReceiptCount === 1 &&
      reconciledOutboxSnapshot.vaultCommitSeq === firstOutboxSnapshot.vaultCommitSeq,
    'response-loss recovery changed the server commit or duplicated its operation record');
    await assertVisible(ownerPage, restartHost, true);
    console.log('browser outbox restart recovery verified', JSON.stringify({
      responseLostAfterRealServerCommit: true,
      operationAndEnvelopePreservedAcrossReload: true,
      matchingCommitRecoveredFromChanges: true,
      operationReceiptCount: reconciledOutboxSnapshot.receiptCount,
      recordVersionCount: reconciledOutboxSnapshot.recordVersionCount,
      changeEventCount: reconciledOutboxSnapshot.changeEventCount,
      batchReceiptCount: reconciledOutboxSnapshot.batchReceiptCount,
      vaultSequenceUnchangedAfterReload: true,
    }));

    // A's encrypted Host manifest carries the object reference through normal
    // sync. B should display the encrypted manifest fields and retrieve the
    // ciphertext object on demand, then decrypt the exact original file.
    const attachmentHost = 'profile-a-attachment-' + RUN_ID.slice(0, 6);
    activeStage = 'cross-profile attachment: create source Host';
    await addHost(ownerPage, {
      name: attachmentHost,
      address: '198.51.100.45',
      username: 'attachment-user',
    });
    await syncNow(ownerPage);
    await assertVisible(secondPage, attachmentHost, true);
    activeStage = 'cross-profile attachment: open source attachment dialog';
    const sourceHostCard = hostCardGroup(ownerPage, attachmentHost);
    await sourceHostCard.getByRole('button', {
      name: 'Attachments',
      exact: true,
    }).click();
    await waitForText(ownerPage, 'No attachments saved for this host.');
    crossAttachment.active = true;
    activeStage = 'cross-profile attachment: choose synthetic file';
    const attachmentChooserPromise = ownerPage.waitForEvent('filechooser', {
      timeout: 15000,
    });
    await click(ownerPage, 'Attach file');
    const attachmentChooser = await attachmentChooserPromise;
    await attachmentChooser.setFiles({
      name: CROSS_ATTACHMENT_NAME,
      mimeType: 'application/octet-stream',
      buffer: CROSS_ATTACHMENT_PLAINTEXT,
    });
    await button(ownerPage, 'Download attachment');
    await click(ownerPage, 'Close');
    activeStage = 'cross-profile attachment: upload object and sync manifest';
    await syncNow(ownerPage);
    const attachmentCommitDeadline = Date.now() + 30000;
    while (Date.now() < attachmentCommitDeadline &&
        (!crossAttachment.objectId || !crossAttachment.recordId ||
         !crossAttachment.revisionId || !crossAttachment.vaultId)) {
      await ownerPage.waitForTimeout(100);
    }
    assertThat(crossAttachment.objectId && crossAttachment.recordId &&
      crossAttachment.revisionId && crossAttachment.vaultId &&
      crossAttachment.ownerObjectRefs.includes(crossAttachment.objectId) &&
      typeof crossAttachment.ownerEnvelopeSha256 === 'string',
    'A did not commit a signed Host revision that references the uploaded object');
    activeStage = 'cross-profile attachment: receive manifest on profile B';
    await waitForHostRecord(secondPage, attachmentHost, true);
    const attachmentManifestDeadline = Date.now() + 12000;
    while (Date.now() < attachmentManifestDeadline &&
        !crossAttachment.recipientManifest) {
      await secondPage.waitForTimeout(100);
    }
    const recipientManifest = crossAttachment.recipientManifest;
    assertThat(recipientManifest?.recordId === crossAttachment.recordId &&
      recipientManifest?.revisionId === crossAttachment.revisionId &&
      recipientManifest?.envelopeSha256 === crossAttachment.ownerEnvelopeSha256 &&
      recipientManifest?.hasObjectRef === true,
    'B did not pull the exact signed Host manifest and object reference from A');
    const attachmentSnapshot = serverAttachmentSnapshot(
      path.join(dataDir, 'atermius.db'),
      crossAttachment.vaultId,
      crossAttachment.recordId,
      crossAttachment.revisionId,
      crossAttachment.objectId,
    );
    assertThat(attachmentSnapshot.revisionCount === 1 &&
      attachmentSnapshot.referenceCount === 1 &&
      attachmentSnapshot.headerHasObjectRef &&
      attachmentSnapshot.objectPresent &&
      attachmentSnapshot.objectByteLength > CROSS_ATTACHMENT_PLAINTEXT.length &&
      attachmentSnapshot.objectSizeMatches &&
      attachmentSnapshot.objectDigestMatches,
    'server did not retain exactly one signed object reference to a valid encrypted object');
    activeStage = 'cross-profile attachment: locate B Host attachment action';
    const recipientHostCard = hostCardGroup(secondPage, attachmentHost);
    await recipientHostCard.getByRole('button', {
      name: 'Attachments',
      exact: true,
    }).click();
    activeStage = 'cross-profile attachment: verify B rendered manifest file name';
    try {
      await waitForSemanticText(secondPage, CROSS_ATTACHMENT_NAME);
    } catch (error) {
      const recipientAttachmentUi = await secondPage.evaluate((fileName) => {
        const body = document.body.innerText || '';
        const semantics = [...document.querySelectorAll('flt-semantics')]
          .map((element) => (element.innerText || '') + '\n' +
            (element.getAttribute('aria-label') || ''))
          .join('\n');
        return {
          fileNameVisible: body.includes(fileName),
          fileNameInSemantics: semantics.includes(fileName),
          dialogVisible: /Attachments\s*[·:]|Attachments/i.test(semantics),
          emptyStateVisible: semantics.includes('No attachments saved for this host.'),
          downloadButtonCount: document.querySelectorAll(
            'flt-semantics[role="button"][aria-label*="Download attachment"]',
          ).length,
          removeButtonCount: document.querySelectorAll(
            'flt-semantics[role="button"][aria-label*="Remove attachment"]',
          ).length,
          hostCardCount: [...document.querySelectorAll('flt-semantics[role="group"]')]
            .filter((node) => ((node.getAttribute('aria-label') || '') + '\n' +
              (node.innerText || '')).includes('profile-a-attachment-')).length,
        };
      }, CROSS_ATTACHMENT_NAME).catch(() => ({ evaluationError: true }));
      console.log('cross-profile recipient attachment UI diagnostic', JSON.stringify({
        recipientAttachmentUi,
        safePage: await safePageDiagnostic(secondPage),
        api: safeApiSummary(apiDiagnostics.slice(-20), 20),
      }));
      throw error;
    }
    activeStage = 'cross-profile attachment: download object from profile B';
    const recipientDownloadPromise = secondPage.waitForEvent('download', {
      timeout: 30000,
    });
    await click(secondPage, 'Download attachment');
    const recipientDownload = await recipientDownloadPromise;
    assertThat(recipientDownload.suggestedFilename() === CROSS_ATTACHMENT_NAME,
      'B download did not use the encrypted manifest file name');
    const recipientPath = path.join(tempRoot, 'profile-b-attachment.bin');
    await recipientDownload.saveAs(recipientPath);
    const recipientBytes = fs.readFileSync(recipientPath);
    const recipientBytesMatch = recipientBytes.equals(CROSS_ATTACHMENT_PLAINTEXT);
    recipientBytes.fill(0);
    assertThat(recipientBytesMatch,
      'profile B did not download and decrypt the exact attachment bytes uploaded by A');
    await click(secondPage, 'Close');
    const attachmentStoredBytes = ['atermius.db', 'atermius.db-wal']
      .map((name) => path.join(dataDir, name))
      .filter((filePath) => fs.existsSync(filePath))
      .map((filePath) => fs.readFileSync(filePath));
    const serverHasAttachmentPlaintext = attachmentStoredBytes.some((bytes) =>
      bytes.includes(CROSS_ATTACHMENT_PLAINTEXT));
    const serverHasAttachmentMarker = attachmentStoredBytes.some((bytes) =>
      bytes.includes(CROSS_ATTACHMENT_MARKER));
    const serverHasAttachmentName = attachmentStoredBytes.some((bytes) =>
      bytes.includes(Buffer.from(CROSS_ATTACHMENT_NAME)));
    assertThat(!serverHasAttachmentPlaintext && !serverHasAttachmentMarker &&
      !serverHasAttachmentName,
    'server SQLite contained the attachment plaintext or encrypted-manifest file name in plaintext');
    console.log('cross-profile attachment sync verified', JSON.stringify({
      signedManifestPulledByB: true,
      objectReferenceCount: attachmentSnapshot.referenceCount,
      encryptedObjectPresent: attachmentSnapshot.objectPresent,
      encryptedObjectDigestValid: attachmentSnapshot.objectDigestMatches,
      recipientListedManifestFileName: true,
      recipientDownloadBytesMatch: recipientBytesMatch,
      serverPlaintextStored: serverHasAttachmentPlaintext,
      serverPlaintextMarkerStored: serverHasAttachmentMarker,
      serverFileNameStored: serverHasAttachmentName,
    }));
    crossAttachment.active = false;
    for (const bytes of attachmentStoredBytes) bytes.fill(0);

    // Make both devices edit the same committed Host revision while offline.
    // A commits first; B's later push must preserve its signed branch as a
    // server conflict event. A then adopts that branch through the Web inbox,
    // which must create a new A-signed revision and converge back to B.
    const hostTwoA = `${hostTwo}-device-a`;
    const hostTwoB = `${hostTwo}-device-b`;
    activeStage = 'cross-profile conflict: open Hosts on both profiles';
    await Promise.all([click(ownerPage, 'Hosts'), click(secondPage, 'Hosts')]);
    await Promise.all([
      waitForHostRecord(ownerPage, hostTwo, true, hostTwoEndpoint),
      waitForHostRecord(secondPage, hostTwo, true, hostTwoEndpoint),
    ]);
    await Promise.all([ownerContext.setOffline(true), secondContext.setOffline(true)]);
    activeStage = 'cross-profile conflict: edit Host in profile A while offline';
    await editHostName(ownerPage, hostTwo, hostTwoA);
    activeStage = 'cross-profile conflict: edit Host in profile B while offline';
    await editHostName(secondPage, hostTwo, hostTwoB);
    activeStage = 'cross-profile conflict: verify both offline branches';
    await Promise.all([ownerPage.waitForTimeout(500), secondPage.waitForTimeout(500)]);

    activeStage = 'cross-profile conflict: commit first branch';
    await ownerContext.setOffline(false);
    const ownerConflictPushStart = ownerHostRecordIds.size;
    captureOwnerHostPush = true;
    await syncNow(ownerPage);
    captureOwnerHostPush = false;
    assertThat(ownerHostRecordIds.size > ownerConflictPushStart,
      'A did not submit its divergent Host revision');

    activeStage = 'cross-profile conflict: upload second-device branch';
    const conflictNotificationStart = notificationEvents.length;
    const conflictApiStart = apiDiagnostics.length;
    await secondContext.setOffline(false);
    activeStage = 'cross-profile conflict: wait for B conflict creation response';
    const conflictPost = await waitForApiEntry(apiDiagnostics, (entry) =>
      entry.profile === 'B' && entry.method === 'POST' && /\/conflicts$/.test(entry.path) &&
      entry.status >= 200 && entry.status < 300, conflictApiStart, 45000);
    assertThat(conflictPost.status === 200 || conflictPost.status === 201,
      `B's server conflict creation returned HTTP ${conflictPost.status}`);
    const serverConflictId = [...observedConflictIds.B].at(-1);
    assertThat(typeof serverConflictId === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(serverConflictId),
    'B conflict creation did not return a canonical server conflict ID');

    activeStage = 'cross-profile conflict: automatic conflict-feed notification';
    const conflictHint = await waitForNotificationFrame(notificationEvents,
      (frame) => frame.profile === 'A' && frame.direction === 'received' &&
        frame.type === 'sync_required' && frame.conflictSeqPresent === true,
      conflictNotificationStart, 15000);
    assertThat(conflictHint.vaultIdIsUuid && conflictHint.conflictSeqIsDecimal &&
      conflictHint.commitSeqPresent === false &&
      JSON.stringify(conflictHint.keys) === JSON.stringify(['conflict_seq', 'type', 'vault_id']),
    'A conflict notification exposed invalid or unexpected metadata');
    const ownerConflictPull = await waitForApiEntry(apiDiagnostics, (entry) =>
      entry.profile === 'A' && entry.method === 'GET' &&
      /\/conflict-changes$/.test(entry.path) &&
      entry.conflictEventSummaries?.some((event) =>
        event.type === 'created' && event.conflictId === serverConflictId),
    conflictApiStart, 15000);
    assertThat(ownerConflictPull.status === 200,
      'A conflict notification did not trigger the authorized conflict inbox pull');
    const createdOnA = await waitForConflictFeedEvent(observedConflictFeedEvents.A,
      (event) => event.type === 'created' && event.conflictId === serverConflictId);
    const createdOnB = await waitForConflictFeedEvent(observedConflictFeedEvents.B,
      (event) => event.type === 'created' && event.conflictId === serverConflictId);
    assertThat(createdOnA.hasEnvelope && createdOnB.hasEnvelope &&
      typeof createdOnA.seq === 'string' && typeof createdOnB.seq === 'string',
    'conflict creation events did not retain their opaque signed envelopes');

    activeStage = 'cross-profile conflict: open sync and conflicts inbox';
    const conflictInboxNav = ownerPage.getByRole('button', { name: /Sync & conflicts/ }).first();
    await conflictInboxNav.waitFor({ state: 'visible', timeout: 15000 });
    await conflictInboxNav.click();
    activeStage = 'cross-profile conflict: wait for conflict inbox heading';
    await waitForText(ownerPage, '跨设备冲突收件箱');
    activeStage = 'cross-profile conflict: locate enabled branch adoption';
    const adoptButton = await button(ownerPage, '采用此分支');
    assertThat(await adoptButton.isEnabled(),
      'A did not enable branch adoption after signature and Vault verification');
    activeStage = 'cross-profile conflict: open branch adoption confirmation';
    await adoptButton.click();
    activeStage = 'cross-profile conflict: wait for re-sign confirmation';
    await waitForText(ownerPage, '采用已验证的设备分支？');
    activeStage = 'cross-profile conflict: confirm branch adoption';
    await click(ownerPage, '重新签名并同步');

    activeStage = 'cross-profile conflict: verify convergence and resolution receipt';
    await click(ownerPage, 'Hosts');
    await waitForHostRecord(ownerPage, hostTwoB, true, hostTwoEndpoint);
    await waitForHostRecord(secondPage, hostTwoB, true, hostTwoEndpoint);
    await waitForHostRecord(ownerPage, hostTwoA, false);
    await waitForHostRecord(secondPage, hostTwoA, false);
    const resolvedOnA = await waitForConflictFeedEvent(observedConflictFeedEvents.A,
      (event) => event.type === 'resolved' && event.conflictId === serverConflictId);
    const resolvedOnB = await waitForConflictFeedEvent(observedConflictFeedEvents.B,
      (event) => event.type === 'resolved' && event.conflictId === serverConflictId);
    assertThat(!resolvedOnA.hasEnvelope && !resolvedOnB.hasEnvelope &&
      typeof resolvedOnA.resolvedRevisionId === 'string' &&
      resolvedOnA.resolvedRevisionId === resolvedOnB.resolvedRevisionId,
    'resolved conflict event duplicated ciphertext or disagreed across profiles');

    // The server database may contain the opaque envelopes and metadata, but
    // neither plaintext Host label from the competing branches may be present.
    const storedBytes = ['atermius.db', 'atermius.db-wal']
      .map((name) => path.join(dataDir, name))
      .filter((filePath) => fs.existsSync(filePath))
      .map((filePath) => fs.readFileSync(filePath));
    for (const plaintext of [hostTwoA, hostTwoB]) {
      assertThat(!storedBytes.some((bytes) => bytes.includes(Buffer.from(plaintext))),
        'server SQLite storage contained a plaintext Host label');
    }
    console.log('cross-profile conflict inbox verified', JSON.stringify({
      conflictIdObserved: true,
      conflictHintContainsOnlyMetadata: true,
      createdEnvelopePresent: true,
      adoptedBranchWasResignedByCurrentDevice: true,
      resolvedEventOmitsEnvelope: true,
      bothProfilesConverged: true,
      serverStoredPlaintext: false,
    }));

    // Export a third committed record from A, then import the encrypted
    // same-Vault archive into B before B pulls that record from the server.
    // Notifications remain enabled; temporarily fail only B's changes reads
    // so the archive workflow can verify/apply before its normal pull succeeds.
    await secondContext.route('**/api/v1/vaults/*/changes*', async (route) => {
      const requestUrl = new URL(route.request().url());
      if (route.request().method() === 'GET' && requestUrl.pathname.endsWith('/changes')) {
        archiveChangesReadsAbortedAt.push(Date.now());
        await route.abort('internetdisconnected');
        return;
      }
      await route.continue();
    });
    console.log('archive pre-pull hold enabled for profile B changes GETs');
    const archiveNotificationStart = notificationEvents.length;
    const archiveHost = `profile-a-archive-${RUN_ID.slice(0, 6)}`;
    await addHost(ownerPage, {
      name: archiveHost,
      address: '198.51.100.41',
      username: 'archive-user',
    });
    await syncNow(ownerPage);
    const archiveHint = await waitForNotificationFrame(notificationEvents,
      (frame) => frame.profile === 'B' && frame.direction === 'received' && frame.type === 'sync_required',
      archiveNotificationStart, 12000);
    const archiveReadDeadline = Date.now() + 12000;
    while (Date.now() < archiveReadDeadline &&
        !archiveChangesReadsAbortedAt.some((atMs) => atMs >= archiveHint.receivedAtMs)) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assertThat(archiveChangesReadsAbortedAt.some((atMs) => atMs >= archiveHint.receivedAtMs),
      'B did not attempt the server changes pull after the archive sync hint');
    await assertVisible(secondPage, archiveHost, false);
    console.log('archive pre-pull hold observed', JSON.stringify({
      hintType: archiveHint.type,
      blockedChangesReadsAfterHint: archiveChangesReadsAbortedAt.filter((atMs) =>
        atMs >= archiveHint.receivedAtMs).length,
      archiveHostHiddenBeforeImport: true,
    }));

    // Export one committed Host plus a locally queued create operation. The
    // pending create is intentionally excluded from server history and must
    // still round-trip through the archive as opaque outbox state.
    activeStage = 'portable archive: install source push hold';
    const archivePendingHost = `profile-a-archive-pending-${RUN_ID.slice(0, 6)}`;
    let archivePendingPushAbortCount = 0;
    const archivePendingPushBlocker = async (route) => {
      archivePendingPushAbortCount++;
      await route.abort('internetdisconnected');
    };
    await ownerContext.route(
      '**/api/v1/vaults/*/sync/push',
      archivePendingPushBlocker,
    );
    console.log('archive source push hold installed');
    activeStage = 'portable archive: create source pending Host';
    const ownerPushRecordCountBeforeArchive = ownerHostRecordIds.size;
    captureOwnerHostPush = true;
    await addHost(ownerPage, {
      name: archivePendingHost,
      address: '198.51.100.42',
      username: 'archive-pending-user',
    });
    console.log('archive source pending Host created locally');
    activeStage = 'portable archive: trigger source pending push attempt';
    await triggerSyncWithoutWaitingForIdle(ownerPage);
    activeStage = 'portable archive: observe source pending push attempt';
    await waitUntil(
      () => ownerHostRecordIds.size > ownerPushRecordCountBeforeArchive,
      10000,
      'source archive Host push attempt',
    );
    captureOwnerHostPush = false;
    const archiveSourcePendingCount =
      ownerHostRecordIds.size - ownerPushRecordCountBeforeArchive;
    console.log('archive source pending outbox preflight', JSON.stringify({
      pendingCount: archiveSourcePendingCount,
      pushAbortObserved: archivePendingPushAbortCount > 0,
      sourceRecordVisible: true,
    }));
    assertThat(archiveSourcePendingCount === 1 &&
      archivePendingPushAbortCount > 0,
    'archive pending create was not held locally without a server commit');
    activeStage = 'portable archive: wait for interrupted push to settle';
    await waitForPendingCardCount(ownerPage, archiveSourcePendingCount);
    await waitUntil(async () =>
      !(await visibleSyncStatusLabels(ownerPage)).includes('Syncing'),
    15000, 'archive source push attempt to settle');
    console.log('archive source push settled with pending outbox', JSON.stringify({
      pendingCount: await pendingCardCount(ownerPage),
      syncStatusLabels: await visibleSyncStatusLabels(ownerPage),
    }));

    activeStage = 'portable archive: open owner Settings';
    await click(ownerPage, 'Settings');
    archivePassword = 'ArchiveE2e2026!Long';
    activeStage = 'portable archive: start export download';
    let archiveDownloadEvents = 0;
    ownerPage.on('download', () => { archiveDownloadEvents++; });
    let exportedArchive;
    let archiveBusyErrorObserved = false;
    for (let attempt = 1; attempt <= 3 && !exportedArchive; attempt++) {
      await waitUntil(async () =>
        !(await visibleSyncStatusLabels(ownerPage)).includes('Syncing'),
      30000, 'owner sync to settle before archive export');
      if (attempt > 1) await ownerPage.waitForTimeout(500);
      await click(ownerPage, 'Export archive');
      activeStage = 'portable archive: enter export password';
      await fillQuick(ownerPage, 'New archive password', archivePassword);
      await fillQuick(ownerPage, 'Confirm archive password', archivePassword);
      await installArchiveBusyErrorProbe(ownerPage);
      activeStage = 'portable archive: confirm export';
      const archiveOutcome = waitForArchiveDownloadOrBusy(ownerPage, 60000);
      await click(ownerPage, 'Continue');
      activeStage = 'portable archive: await export download';
      const result = await archiveOutcome;
      exportedArchive = result.downloadedArchive;
      archiveBusyErrorObserved ||= result.busyErrorObserved === true;
      if (!exportedArchive && result.busyErrorObserved && attempt < 3) {
        console.log('archive export deferred while synchronization is active',
          JSON.stringify({ attempt, retrying: true }));
        continue;
      }
      if (!exportedArchive) break;
    }
    if (!exportedArchive) {
      console.log('archive export download safe diagnostic', JSON.stringify({
        errorClass: 'TimeoutError',
        downloadEventObserved: archiveDownloadEvents > 0,
        syncOrArchiveBusyErrorObserved: archiveBusyErrorObserved,
        syncStatusLabels: await visibleSyncStatusLabels(ownerPage),
        pendingCount: await pendingCardCount(ownerPage),
        exportUi: await safeArchiveExportUiState(ownerPage),
        downloadProbe: await ownerPage.evaluate(() => ({
          ...((window.__e2eDownloadProbe && {
            downloadAnchorClicks: window.__e2eDownloadProbe.downloadAnchorClicks,
            blobDownloadAnchorClicks: window.__e2eDownloadProbe.blobDownloadAnchorClicks,
            otherDownloadAnchorClicks: window.__e2eDownloadProbe.otherDownloadAnchorClicks,
          }) || {}),
        })).catch(() => ({ unavailable: true })),
        ownerPageErrorCategories: pageErrors.filter((item) => item.profile === 'A')
          .slice(-10).map((item) => item.category),
        page: await safePageDiagnostic(ownerPage),
        recentApi: safeApiSummary(apiDiagnostics, 12),
      }));
      throw new Error('archive export did not produce a download');
    }
    await ownerPage.evaluate(() => window.__e2eArchiveBusyErrorObserver?.disconnect?.());
    archivePath = path.join(tempRoot, 'profile-a.atvlt');
    await exportedArchive.saveAs(archivePath);
    activeStage = 'portable archive: validate exported container';
    assertThat(fs.statSync(archivePath).size > 0, 'archive export produced an empty file');
    const archiveContainerSummary = safeArchiveContainerSummary(archivePath);
    console.log('archive exported container structure', JSON.stringify(archiveContainerSummary));
    assertThat(archiveContainerSummary.magicMatches &&
      archiveContainerSummary.headerLengthValid && archiveContainerSummary.headerJsonValid &&
      archiveContainerSummary.headerFieldsValid && archiveContainerSummary.chunkLayoutValid,
    'archive export download did not preserve the expected container structure');
    activeStage = 'portable archive: verify export confirmation';
    await waitForText(ownerPage, 'Encrypted Vault archive saved.');

    // Leave B with one local outbox item. Abort only its sync-push requests so
    // trust/history reads for archive validation still reach the test server.
    const outboxHost = `profile-b-archive-pending-${RUN_ID.slice(0, 6)}`;
    await secondContext.route('**/api/v1/vaults/*/sync/push', (route) => route.abort());
    await addHost(secondPage, {
      name: outboxHost,
      address: '198.51.100.53',
      username: 'pending-user',
    });
    const pendingBeforeImport = secondPage.getByRole('button', { name: /^\d+ pending$/ }).first();
    await pendingBeforeImport.waitFor({ state: 'visible', timeout: 15000 });
    const pendingBeforeCount = await pendingCount(pendingBeforeImport);
    assertThat(pendingBeforeCount !== null && pendingBeforeCount > 0,
      'B profile did not have a measurable pending outbox item before archive import');
    await assertVisible(secondPage, archiveHost, false);
    await click(secondPage, 'Settings');
    const archiveChooser = secondPage.waitForEvent('filechooser', { timeout: 30000 });
    await click(secondPage, 'Import archive');
    await (await archiveChooser).setFiles(archivePath);
    await fill(secondPage, 'Archive password', archivePassword);
    activeStage = 'portable archive verification';
    const existingArchiveUiErrors = await secondPage.evaluate(() => {
      const values = [document.body.innerText, ...[...document.querySelectorAll('flt-semantics')]
        .flatMap((element) => [element.innerText || '', element.getAttribute('aria-label') || ''])];
      return [...new Set(values.flatMap((value) => value.split('\n')
        .map((line) => line.trim()).filter((line) =>
          /FormatException|Exception:|Error:|failed|失败|无效|无法|拒绝/i.test(line))))];
    }).catch(() => []);
    await click(secondPage, 'Verify archive');
    try {
      await waitForArchiveConfirmation(
        secondPage,
        120000,
        existingArchiveUiErrors,
      );
    } catch (error) {
      console.log('archive verification diagnostic', JSON.stringify({
        source: 'integration/web/cross_profile_sync.cjs:waitForArchiveConfirmation',
        sourceLine: 416,
        ...classifyArchiveFailure(error),
        page: await safePageDiagnostic(secondPage),
        api: safeApiSummary(apiDiagnostics, 35),
      }));
      throw error;
    }
    await waitForText(secondPage, 'Encrypted object blocks: 1');
    activeStage = 'portable archive: apply verified archive';
    await click(secondPage, 'Import to this Vault');
    let applyObservation;
    try {
      applyObservation = await waitForArchiveApply(secondPage, apiDiagnostics, 120000);
    } catch (error) {
      console.log('archive apply safe diagnostic', JSON.stringify({
        category: error.archiveApplyErrorCategory || 'no-visible-category',
        page: await safePageDiagnostic(secondPage),
      }));
      throw error;
    }
    console.log('archive apply settled; validating local records', JSON.stringify({
      successToastSeen: applyObservation.successSeen,
      applyErrorCategory: applyObservation.lastSample?.applyErrorCategory || null,
      pendingBeforeCount,
    }));
    activeStage = 'portable archive: return to Hosts workspace';
    try {
      await click(secondPage, 'Hosts');
      await secondPage.waitForTimeout(350);
      await secondPage.screenshot({ path: '/tmp/atermius-archive-import-hosts-after-click.png' }).catch(() => {});
      console.log('archive Hosts navigation submitted', JSON.stringify({
        page: await safePageDiagnostic(secondPage),
      }));
      await waitWorkspace(secondPage);
      activeStage = 'portable archive: verify imported host in workspace';
      const importedHostSemantics = await secondPage.evaluate((expectedName) => {
        const nodes = [...document.querySelectorAll('flt-semantics')];
        const labels = nodes.map((node) =>
          `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`);
        return {
          expectedNameInBodyText: (document.body.innerText || '').includes(expectedName),
          expectedNameInSemantics: labels.some((label) => label.includes(expectedName)),
          expectedNameInGroup: nodes.some((node, index) =>
            node.getAttribute('role') === 'group' && labels[index].includes(expectedName)),
          hostGroupCount: nodes.filter((node) => node.getAttribute('role') === 'group').length,
          visibleHostTextNodes: nodes.filter((node, index) =>
            /profile-[ab]-/.test(labels[index]) && node.getBoundingClientRect().width > 0).length,
        };
      }, archiveHost).catch(() => ({ pageEvaluation: 'unavailable' }));
      console.log('archive imported host semantic probe', JSON.stringify(importedHostSemantics));
      await assertVisible(secondPage, archiveHost, true);
    } catch (error) {
      console.log('archive Hosts return diagnostic started', JSON.stringify({ stage: activeStage }));
      const archiveRowState = await secondPage.evaluate((expectedName) => {
        const nodes = [...document.querySelectorAll('flt-semantics')];
        const labels = nodes.map((node) =>
          `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`);
        return {
          expectedNameInBodyText: (document.body.innerText || '').includes(expectedName),
          expectedNameInSemantics: labels.some((label) => label.includes(expectedName)),
          matchingGroupCount: nodes.filter((node) => node.getAttribute('role') === 'group' &&
            labels[nodes.indexOf(node)]?.includes(expectedName)).length,
          hostsWorkspaceButtonCount: nodes.filter((node) =>
            node.getAttribute('role') === 'button' &&
            /Hosts/.test(node.getAttribute('aria-label') || node.innerText || '')).length,
          pendingLabelCount: labels.filter((label) => /\d+ pending/.test(label)).length,
          semanticNodeCount: nodes.length,
        };
      }, archiveHost).catch(() => ({ pageEvaluation: 'unavailable' }));
      await secondPage.screenshot({ path: '/tmp/atermius-archive-import-hosts.png' }).catch(() => {});
      console.log('archive imported host visibility diagnostic', JSON.stringify({
        rowState: archiveRowState,
        page: await safePageDiagnostic(secondPage),
        api: safeApiSummary(apiDiagnostics, 20),
        pageErrorCount: pageErrors.length,
        profileBDiagnosticCount: browserDiagnostics.filter((item) => item.profile === 'B').length,
        pendingBeforeCount,
      }));
      throw error;
    }
    await assertVisible(secondPage, outboxHost, true);
    activeStage = 'portable archive: verify pending outbox preservation';
    const pendingAfterCount = await waitForPendingCardCount(secondPage, pendingBeforeCount);
    assertThat(pendingAfterCount === pendingBeforeCount + archiveSourcePendingCount,
      `archive import did not merge exactly the source pending outbox (${pendingBeforeCount} before, ${pendingAfterCount} after)`);
    console.log('archive same-vault round-trip passed', JSON.stringify({
      archiveHostVisible: true,
      originalOutboxHostVisible: true,
      sourcePendingOutboxIncluded: true,
      pendingBeforeCount,
      pendingAfterCount,
      successToastSeen: applyObservation.successSeen,
    }));
    await secondContext.unroute('**/api/v1/vaults/*/changes*');
    await secondContext.unroute('**/api/v1/vaults/*/sync/push');
    await ownerContext.unroute(
      '**/api/v1/vaults/*/sync/push',
      archivePendingPushBlocker,
    );

    // Revoke profile B while it holds one new encrypted Host operation only
    // in its local outbox. First cancel the UI confirmation to prove that a
    // cancellation has no server effect, then explicitly confirm the revoke.
    activeStage = 'trusted-device revocation: locate active profile B';
    await click(ownerPage, 'Devices');
    const targetDevice = await waitForDeviceStatus(
      deviceSnapshots, 'A', 'Web profile B', 'active',
    );
    await secondContext.setOffline(true);
    await secondPage.waitForTimeout(500);
    const pendingBeforeRevocation = await pendingCardCount(secondPage);
    assertThat(pendingBeforeRevocation !== null,
      'profile B pending count was unavailable before its offline edit');
    const serverVersionsBeforeRevocation = serverVersionCountForDevice(
      path.join(dataDir, 'atermius.db'), targetDevice.deviceId,
    );
    const revokedTargetHost = `profile-b-revoked-${RUN_ID.slice(0, 6)}`;
    activeStage = 'trusted-device revocation: queue offline encrypted Host';
    await addHost(secondPage, {
      name: revokedTargetHost,
      address: '198.51.100.77',
      username: 'revoked-pending-user',
    });
    const pendingWithRevokedTarget = await waitForPendingCardCount(
      secondPage, pendingBeforeRevocation + 1,
    );
    await assertVisible(secondPage, revokedTargetHost, true);

    const revokePath = `/api/v1/devices/${targetDevice.deviceId}/revoke`;
    const beforeCancelApi = apiDiagnostics.length;
    activeStage = 'trusted-device revocation: cancel confirmation';
    await click(ownerPage, 'Revoke device');
    await waitForText(ownerPage, 'Revoke device?', 30000);
    await click(ownerPage, 'Cancel');
    await ownerPage.getByText('Revoke device?', { exact: true })
      .waitFor({ state: 'hidden', timeout: 15000 });
    assertThat(!apiDiagnostics.slice(beforeCancelApi).some((entry) =>
      entry.method === 'POST' && entry.path === revokePath),
    'canceling device revocation unexpectedly sent a server request');

    activeStage = 'trusted-device revocation: wait for Devices page after cancel';
    const revokeApiStart = apiDiagnostics.length;
    try {
      await waitForText(ownerPage, 'Trusted devices', 15000);
    } catch (error) {
      console.log('device revoke target safe evidence', JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        state: await safeRevokeButtonEvidence(ownerPage),
        page: await safePageDiagnostic(ownerPage),
        recentApi: safeApiSummary(apiDiagnostics, 12),
      }));
      throw error;
    }
    const beforeOpeningRevokeDialog = await safeRevokeButtonEvidence(ownerPage);
    if (beforeOpeningRevokeDialog.playwrightVisibleCount !== 1 ||
        beforeOpeningRevokeDialog.playwrightEnabledCount !== 1) {
      console.log('device revoke target safe evidence', JSON.stringify({
        state: beforeOpeningRevokeDialog,
        page: await safePageDiagnostic(ownerPage),
        recentApi: safeApiSummary(apiDiagnostics, 12),
      }));
      throw new Error('unique visible enabled device revoke action was unavailable');
    }
    console.log('device revoke target safe evidence', JSON.stringify({
      state: beforeOpeningRevokeDialog,
    }));
    activeStage = 'trusted-device revocation: open confirmation dialog';
    try {
      await clickLastButton(ownerPage, 'Revoke device');
    } catch (error) {
      console.log('device revoke click safe evidence', JSON.stringify({
        action: 'open-confirmation',
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        before: beforeOpeningRevokeDialog,
        after: await safeRevokeButtonEvidence(ownerPage),
        page: await safePageDiagnostic(ownerPage),
      }));
      throw error;
    }
    activeStage = 'trusted-device revocation: wait for confirmation dialog';
    try {
      await waitForText(ownerPage, 'Revoke device?', 30000);
    } catch (error) {
      console.log('device revoke confirmation diagnostic', JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        state: await safeRevokeButtonEvidence(ownerPage),
        page: await safePageDiagnostic(ownerPage),
        deviceSnapshotCount: deviceSnapshots.A.length,
        recentApi: safeApiSummary(apiDiagnostics, 12),
      }));
      throw error;
    }
    const beforeConfirmingRevoke = await safeRevokeButtonEvidence(ownerPage);
    console.log('device revoke confirmation safe evidence', JSON.stringify({
      state: beforeConfirmingRevoke,
    }));
    activeStage = 'trusted-device revocation: confirm profile B revoke';
    let revokeResponse;
    const expectedRevokeResponse = ownerPage.waitForResponse((response) => {
      const request = response.request();
      return request.method() === 'POST' &&
        new URL(response.url()).pathname === revokePath;
    }, { timeout: 15000 });
    const confirmRevokeClick = clickConfirmDialogButton(
      ownerPage,
      'Revoke device?',
      'Revoke device',
    );
    activeStage = 'trusted-device revocation: wait for revoke response';
    try {
      const [response] = await Promise.all([
        expectedRevokeResponse,
        confirmRevokeClick,
      ]);
      revokeResponse = response;
    } catch (error) {
      console.log('device revoke click safe evidence', JSON.stringify({
        action: 'confirm-revoke',
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        before: beforeConfirmingRevoke,
        after: await safeRevokeButtonEvidence(ownerPage),
        page: await safePageDiagnostic(ownerPage),
      }));
      throw error;
    }
    console.log('trusted-device revoke response observed', JSON.stringify({
      profile: 'A',
      method: 'POST',
      path: '/api/v1/devices/{id}/revoke',
      status: revokeResponse.status(),
    }));
    const revokeResponseObservedAtMs = Date.now();
    activeStage = 'trusted-device revocation: correlate API response';
    try {
      await waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'A' && entry.method === 'POST' && entry.path === revokePath,
      revokeApiStart, 15000);
    } catch (error) {
      console.log('trusted-device revoke response timeout diagnostic', JSON.stringify({
        requestObserved: deviceRevocationRequests.length,
        requestMethods: deviceRevocationRequests.slice(-8).map((item) => ({
          profile: item.profile,
          method: item.method,
        })),
        revokeApiResponses: safeApiSummary(apiDiagnostics.filter((entry) =>
          entry.path.endsWith('/revoke')), 8),
        ownerPageErrorCount: pageErrors.filter((item) => item.profile === 'A').length,
        ownerRequestFailedPathCount: browserDiagnostics.filter((item) =>
          item.profile === 'A' && item.kind === 'request-failed' &&
          item.path.endsWith('/revoke')).length,
        page: await safePageDiagnostic(ownerPage),
        revokeButton: await safeRevokeButtonEvidence(ownerPage),
      }));
      throw error;
    }
    activeStage = 'trusted-device revocation: assert HTTP status';
    assertThat(revokeResponse.status() === 200,
      `profile B revocation returned HTTP ${revokeResponse.status()}`);
    // The devices page does not poll its inventory after a revoke response.
    // Leave and reopen it so the status oracle observes a new GET initiated
    // after the successful mutation, matching the explicit freshness barrier
    // used by WEB-DEVICE-REVOKE-01.
    activeStage = 'trusted-device revocation: request fresh device snapshot';
    await click(ownerPage, 'Hosts');
    await click(ownerPage, 'Devices');
    activeStage = 'trusted-device revocation: observe revoked device status';
    try {
      await waitForDeviceStatus(
        deviceSnapshots,
        'A',
        'Web profile B',
        'revoked',
        15000,
        { requestAtOrAfterMs: revokeResponseObservedAtMs },
      );
    } catch (error) {
      const postRevokeSnapshots = deviceSnapshots.A.filter((snapshot) =>
        snapshot.requestAtMs >= revokeResponseObservedAtMs);
      console.log('trusted-device revoke status diagnostic', JSON.stringify({
        statusSnapshotsObserved: deviceSnapshots.A.length,
        postRevokeStatusSnapshots: postRevokeSnapshots.length,
        matchingDeviceStates: postRevokeSnapshots
          .map((snapshot) => snapshot.devices.find((device) => device.name === 'Web profile B'))
          .filter(Boolean)
          .map((device) => device.status),
        revokeHttpStatus: revokeResponse.status(),
      }));
      throw error;
    }

    // synchronize() refreshes the account-device control plane before it
    // requests Vault data. A revoked device is rejected at that preflight,
    // which should stop all later Vault-device/changes/push requests.
    const deniedSyncStart = apiDiagnostics.length;
    activeStage = 'trusted-device revocation: wait for target browser online';
    await secondContext.setOffline(false);
    try {
      await waitUntil(
        () => secondPage.evaluate(() => navigator.onLine === true),
        5000,
        'revoked profile B browser did not report online after reconnection',
      );
    } catch (error) {
      console.log('revoked profile reconnect online diagnostic', JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        browserOnline: await secondPage.evaluate(() => navigator.onLine === true)
          .catch(() => null),
        pageClosed: secondPage.isClosed(),
        recentApi: safeApiSummary(apiDiagnostics, 8),
      }));
      throw error;
    }
    activeStage = 'trusted-device revocation: locate sync action';
    const syncStatusButton = secondPage.getByRole('button', {
      name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Sign in needed|Device revoked)$/,
    }).first();
    const syncButtonDeadline = Date.now() + 20000;
    let syncButtonClicked = false;
    let syncButtonLabel = null;
    while (Date.now() < syncButtonDeadline) {
      if (await syncStatusButton.isVisible().catch(() => false) &&
          await syncStatusButton.isEnabled().catch(() => false)) {
        const label = await syncStatusButton.getAttribute('aria-label') ||
          (await syncStatusButton.innerText()).trim();
        syncButtonLabel = label;
        if (label !== 'Syncing') {
          await syncStatusButton.click();
          syncButtonClicked = true;
          break;
        }
      }
      await secondPage.waitForTimeout(100);
    }
    assertThat(syncButtonClicked, 'profile B sync action was unavailable after reconnection');
    activeStage = 'trusted-device revocation: wait for account sync preflight response';
    let deniedSync;
    try {
      deniedSync = await waitForApiEntry(apiDiagnostics, (entry) =>
        entry.profile === 'B' && entry.method === 'GET' &&
        entry.path === '/api/v1/devices' &&
        entry.status >= 400,
      deniedSyncStart, 20000);
    } catch (error) {
      let browserOnline = null;
      let statusLabels = [];
      try { browserOnline = await secondPage.evaluate(() => navigator.onLine === true); } catch (_) {}
      try { statusLabels = await visibleSyncStatusLabels(secondPage); } catch (_) {}
      console.log('revoked profile sync preflight diagnostic', JSON.stringify({
        browserOnline,
        syncStatusButtonClicked: syncButtonClicked,
        syncStatusButtonLabel: syncButtonLabel,
        syncStatusLabels: statusLabels,
        signInNeededVisible: await secondPage.getByText('Sign in needed', { exact: true })
          .first().isVisible().catch(() => false),
        observedResponses: apiDiagnostics.slice(deniedSyncStart).filter((entry) =>
          entry.profile === 'B').slice(-12).map((entry) => ({
          method: entry.method,
          route: entry.path === '/api/v1/devices'
            ? 'account-devices'
            : /^\/api\/v1\/vaults\/[^/]+\/devices$/.test(entry.path)
            ? 'vault-devices'
            : /^\/api\/v1\/vaults\/[^/]+\/changes$/.test(entry.path)
            ? 'changes'
            : /^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(entry.path)
            ? 'sync-push'
            : 'other-api',
          status: entry.status,
          authorizationPresent: entry.authorizationPresent === true,
          errorCode: entry.errorCode || null,
        })),
      }));
      throw error;
    }
    assertThat(deniedSync.status === 401 && deniedSync.errorCode === 'AUTH_REQUIRED' &&
      deniedSync.authorizationPresent,
    'revoked profile B sync preflight was not denied with an authenticated AUTH_REQUIRED response');
    await waitForText(secondPage, 'Sign in needed');
    const deniedSyncIndex = apiDiagnostics.indexOf(deniedSync);
    const vaultDataPlaneAfterDenial = apiDiagnostics.slice(deniedSyncIndex + 1).some((entry) =>
      entry.profile === 'B' &&
      /^\/api\/v1\/vaults\/[^/]+\/(?:devices|changes|sync\/push)$/.test(entry.path));
    assertThat(!vaultDataPlaneAfterDenial,
      'revoked profile B sent a Vault data-plane request after its account preflight was denied');
    await assertVisible(secondPage, revokedTargetHost, true);
    const pendingAfterDeniedSync = await waitForPendingCardCount(
      secondPage, pendingWithRevokedTarget,
    );
    assertThat(pendingAfterDeniedSync >= pendingWithRevokedTarget,
      'revoked profile B lost encrypted pending work after a denied sync');

    const serverVersionsAfterRevocation = serverVersionCountForDevice(
      path.join(dataDir, 'atermius.db'), targetDevice.deviceId,
    );
    assertThat(serverVersionsAfterRevocation === serverVersionsBeforeRevocation,
      'revoked profile B committed its offline Host record to server state');
    activeStage = 'trusted-device revocation: verify absence from owner account';
    await click(ownerPage, 'Hosts');
    await syncNow(ownerPage);
    await assertVisible(ownerPage, revokedTargetHost, false);
    console.log('cross-profile trusted-device revocation verified', JSON.stringify({
      canceledRequestAbsent: true,
      revokeHttpStatus: revokeResponse.status,
      targetDeviceRevoked: true,
      deniedSyncRoute: '/api/v1/devices',
      deniedSyncHttpStatus: deniedSync.status,
      deniedSyncCode: deniedSync.errorCode,
      deniedSyncAuthenticated: deniedSync.authorizationPresent,
      vaultDataPlaneStopped: !vaultDataPlaneAfterDenial,
      pendingWorkRetained: pendingAfterDeniedSync >= pendingWithRevokedTarget,
      targetHostAbsentFromOwner: true,
      targetRecordAbsentFromServer: serverVersionsAfterRevocation === serverVersionsBeforeRevocation,
    }));

    // Exercise the complete account lifecycle in the real Web UI: scheduling
    // revokes the active session, cancellation from the login screen is
    // sessionless and does not restore it, and a new login succeeds.
    activeStage = 'account deletion: open Settings';
    await click(ownerPage, 'Settings');
    activeStage = 'account deletion: open scheduling confirmation';
    await waitForText(ownerPage, 'Account deletion');
    await click(ownerPage, 'Schedule account deletion');
    await waitForText(ownerPage, 'Schedule account deletion?');
    activeStage = 'account deletion: final confirmation';
    await click(ownerPage, 'Continue to final confirmation');
    activeStage = 'account deletion: enter confirmation phrase';
    await fill(ownerPage, 'Type DELETE to confirm', 'DELETE');
    activeStage = 'account deletion: re-enter master password';
    await fill(ownerPage, 'Re-enter account master password', MASTER_PASSWORD);
    activeStage = 'account deletion: submit schedule';
    await click(ownerPage, 'Schedule deletion');
    activeStage = 'account deletion: wait for signed-out form';
    try {
      await field(ownerPage, 'Email or username');
    } catch (error) {
      console.log('account deletion transition diagnostic', JSON.stringify({
        page: await safePageDiagnostic(ownerPage),
        api: safeApiSummary(apiDiagnostics, 20),
      }));
      throw error;
    }
    activeStage = 'account deletion: verify scheduled state';
    await waitForText(ownerPage, 'Cancel scheduled account deletion');
    const deletionResponse = apiDiagnostics.slice().reverse()
      .find((entry) => entry.method === 'POST' && entry.path === '/api/v1/account/delete');
    assertThat(deletionResponse?.status === 200,
      `account deletion request did not succeed (status=${deletionResponse?.status ?? 'missing'})`);
    assertThat(ownerPreDeletionAccessToken,
      'account deletion request did not carry the authenticated session');

    activeStage = 'account deletion: verify server revoked prior session';
    const revokedBeforeCancel = await ownerPage.evaluate(async (token) => {
      const response = await fetch('/api/v1/me', {
        headers: { Authorization: `Bearer ${token}` },
      });
      const body = await response.json().catch(() => ({}));
      return { status: response.status, code: body?.error?.code || null };
    }, ownerPreDeletionAccessToken);
    assertThat(revokedBeforeCancel.status === 401 && revokedBeforeCancel.code === 'AUTH_REQUIRED',
      `scheduled deletion left the old browser session active: ${JSON.stringify(revokedBeforeCancel)}`);

    activeStage = 'account deletion: sign in for sessionless cancellation';
    try {
      await fill(ownerPage, 'Email or username', USERNAME);
    } catch (error) {
      console.log('sessionless cancellation sign-in safe diagnostic', JSON.stringify({
        emailInputCount: await ownerPage.locator('input[aria-label*="Email or username"]').count()
          .catch(() => -1),
        visibleEmailInput: await ownerPage.locator('input[aria-label*="Email or username"]')
          .first().isVisible().catch(() => false),
        loginButtonVisible: await ownerPage.getByRole('button', {
          name: 'Sign in and unlock', exact: true,
        }).isVisible().catch(() => false),
        cancelButtonVisible: await ownerPage.getByRole('button', {
          name: 'Cancel scheduled account deletion', exact: true,
        }).isVisible().catch(() => false),
        page: await safePageDiagnostic(ownerPage),
        api: safeApiSummary(apiDiagnostics, 10),
      }));
      throw error;
    }
    activeStage = 'account deletion: enter password for sessionless cancellation';
    await fill(ownerPage, 'Master password', MASTER_PASSWORD);
    const cancelResponsePromise = ownerPage.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname === '/api/v1/account/delete/cancel' &&
        response.request().method() === 'POST';
    }, { timeout: 30000 });
    activeStage = 'account deletion: find sessionless cancellation action';
    const cancelButton = await button(ownerPage, 'Cancel scheduled account deletion');
    activeStage = 'account deletion: submit sessionless cancellation';
    try {
      await cancelButton.click();
    } catch (error) {
      const cancelButtonVisible = await cancelButton.isVisible().catch(() => false);
      const cancelButtonEnabled = await cancelButton.isEnabled().catch(() => false);
      const loginButtonVisible = await ownerPage.getByRole('button', {
        name: 'Sign in and unlock', exact: true,
      }).isVisible().catch(() => false);
      console.log('sessionless cancellation safe diagnostic', JSON.stringify({
        cancelButtonVisible,
        cancelButtonEnabled,
        loginButtonVisible,
        page: await safePageDiagnostic(ownerPage),
        api: safeApiSummary(apiDiagnostics, 10),
      }));
      throw error;
    }
    activeStage = 'account deletion: await sessionless cancellation response';
    const cancelHttpResponse = await cancelResponsePromise;
    assertThat(cancelHttpResponse.status() === 200,
      `sessionless account cancellation returned HTTP ${cancelHttpResponse.status()}`);
    assertThat(accountCancelRequestObserved,
      'browser did not observe the account cancellation request');
    assertThat(!accountCancelAuthorizationPresent,
      'sessionless account cancellation unexpectedly carried an Authorization header');
    const freshLoginButton = await button(ownerPage, 'Sign in and unlock');
    assertThat(await freshLoginButton.isVisible(),
      'cancellation restored a session instead of leaving the login form active');
    activeStage = 'account deletion: verify cancelled session remains revoked';
    const oldSessionAfterCancel = await ownerPage.evaluate(async (token) => {
      const response = await fetch('/api/v1/me', {
        headers: { Authorization: `Bearer ${token}` },
      });
      const body = await response.json().catch(() => ({}));
      return { status: response.status, code: body?.error?.code || null };
    }, ownerPreDeletionAccessToken);
    assertThat(oldSessionAfterCancel.status === 401 && oldSessionAfterCancel.code === 'AUTH_REQUIRED',
      `cancellation revived the pre-deletion browser session: ${JSON.stringify(oldSessionAfterCancel)}`);
    activeStage = 'account deletion: enter fresh-login password';
    await fill(ownerPage, 'Master password', MASTER_PASSWORD);
    activeStage = 'account deletion: submit fresh login';
    await click(ownerPage, 'Sign in and unlock');
    activeStage = 'account deletion: verify fresh login workspace';
    try {
      await waitWorkspace(ownerPage);
    } catch (error) {
      console.log('fresh login transition diagnostic', JSON.stringify({
        page: await safePageDiagnostic(ownerPage),
        api: safeApiSummary(apiDiagnostics, 18),
      }));
      throw error;
    }
    ownerPreDeletionAccessToken = undefined;

    activeStage = 'account deletion: check browser runtime errors';
    if (pageErrors.length > 0 || cspViolations.length > 0) {
      console.log('browser runtime error summary', JSON.stringify({
        pageErrors: pageErrors.reduce((counts, item) => {
          const key = `${item.profile}:${item.category}`;
          counts[key] = (counts[key] || 0) + 1;
          return counts;
        }, {}),
        cspViolationCount: cspViolations.length,
      }));
    }
    assertThat(pageErrors.length === 0, `browser raised ${pageErrors.length} page errors`);
    assertThat(cspViolations.length === 0,
      `browser observed CSP-blocked requests or console violations: ${JSON.stringify(cspViolations)}`);
    console.log('WEB-IT-01 passed: two isolated profiles enrolled, encrypted host and attachment sync worked, browser outbox recovery completed without duplicate writes, and account deletion was cancelled sessionlessly before a fresh login.');
  } finally {
    let shortcutFixtureCleanupFailed = false;
    bootstrapToken = undefined;
    archivePassword = undefined;
    archivePath = undefined;
    ownerPreDeletionAccessToken = undefined;
    CROSS_ATTACHMENT_PLAINTEXT.fill(0);
    CROSS_ATTACHMENT_MARKER.fill(0);
    if (secondContext) {
      await secondContext.unroute('**/api/v1/vaults/*/changes*').catch(() => {});
      await secondContext.unroute('**/api/v1/vaults/*/sync/push').catch(() => {});
    }
    if (ownerContext) await ownerContext.close().catch(() => {});
    if (secondContext) await secondContext.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
    if (serverProcess && serverProcess.exitCode === null) {
      serverProcess.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => serverProcess.once('exit', resolve)),
        new Promise((resolve) => setTimeout(resolve, 5000)),
      ]);
      if (serverProcess.exitCode === null) serverProcess.kill('SIGKILL');
    }
    if (shortcutSshFixture) {
      try {
        await shortcutSshFixture.cleanup();
      } catch (_) {
        shortcutFixtureCleanupFailed = true;
      }
    }
    fs.closeSync(serverLog);
    fs.rmSync(tempRoot, { recursive: true, force: true });
    if (shortcutFixtureCleanupFailed) {
      throw new Error('isolated SSH fixture cleanup failed');
    }
  }
}

main().catch((error) => {
  const safeErrorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  const suite = GROUPS_ONLY
    ? 'WEB-GROUPS-01'
    : SAME_PROFILE_STALE_PAGE_ONLY
    ? 'WEB-MULTITAB-STALE-CHANGES-01'
    : MULTI_VAULT_SWITCH_ONLY
    ? 'WEB-MULTI-VAULT-SWITCH-01'
    : HOST_SECURITY_CONFLICTS_ONLY
    ? 'WEB-HOST-SECURITY-CONFLICT-01'
    : VAULT_PREFERENCE_ONLY
    ? 'WEB-VAULT-PREFERENCE-01'
    : MISSED_MEMBERSHIP_HINT_ONLY
    ? 'WEB-MISSED-MEMBERSHIP-HINT-01'
    : CREDENTIAL_CONFLICTS_ONLY
    ? 'WEB-CREDENTIAL-CONFLICT-01'
    : 'WEB-IT-01';
  console.error(`${suite} failed at ${activeStage} (${safeErrorClass}); sensitive diagnostic text omitted`);
  process.exitCode = 1;
});
