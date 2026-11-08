/*
 * WEB-LOCAL-MIGRATION-01: move encrypted LocalVault records into one new sync
 * Vault from an authenticated server workspace. A real quota failure may leave
 * a durable staged prefix and an exactly matching server commit prefix; the
 * target push is then intercepted with one 503 before the same journal resumes.
 * Assertions inspect only synthetic marker presence, opaque envelope hashes,
 * durable row counts, and UI state; credentials/envelope contents are never
 * written to diagnostics.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const LOCAL_PASSWORD = `LocalMigration-${crypto.randomBytes(24).toString('hex')}9`;
const OWNER_PASSWORD = `ServerMigration-${crypto.randomBytes(24).toString('base64url')}9`;
const OWNER_USERNAME = `web-local-migration-${RUN_ID.slice(0, 8)}@example.test`;
const HOST_NAME = `local-migration-host-${RUN_ID}`;
const HOST_ADDRESS = `local-migration-${RUN_ID}.example.test`;
const HOST_USERNAME = `local-user-${RUN_ID.slice(0, 8)}`;
const CREDENTIAL_NAME = `local-migration-credential-${RUN_ID}`;
const CREDENTIAL_USERNAME = `local-credential-user-${RUN_ID.slice(0, 8)}`;
const CREDENTIAL_SECRET = `LocalMigrationSecret-${RUN_ID}`;
const GROUP_NAME = `local-migration-group-${RUN_ID}`;
const SNIPPET_NAME = `local-migration-snippet-${RUN_ID}`;
const SNIPPET_BODY = `printf 'LocalMigrationSnippet-${RUN_ID}'`;
const TARGET_VAULT_NAME = `Migrated ${RUN_ID.slice(0, 8)}`;
const SECOND_DEVICE_NAME = `Migration second device ${RUN_ID.slice(0, 8)}`;
const EXPECTED_MIGRATED_RECORDS = 8;
const MIGRATION_QUOTA_LIMIT_BYTES = 8 * 1024 * 1024;
const MIGRATION_QUOTA_HEADROOM_BYTES = 80 * 1024;
const MIGRATION_QUOTA_ESTIMATE_SAFETY_BYTES = 56 * 1024;
const MIGRATION_QUOTA_CAP_WINDOW_BYTES = 192 * 1024;
const MIGRATION_QUOTA_PROBE_DB = `atermius_migration_quota_probe_${RUN_ID}`;
const LOCAL_MIGRATION_TABLES = [
  'local_vault_records',
  'local_vault_migrations',
  'local_vault_migration_items',
  'local_vault_migration_create_payloads',
];
const PLAINTEXT_MARKERS = [
  HOST_NAME,
  HOST_ADDRESS,
  HOST_USERNAME,
  CREDENTIAL_NAME,
  CREDENTIAL_USERNAME,
  CREDENTIAL_SECRET,
  GROUP_NAME,
  SNIPPET_NAME,
  SNIPPET_BODY,
  'mod+alt+shift+x',
  'mod+alt+y',
  'mod+alt+shift+y',
  'mod+alt+shift+z',
];

let stage = 'preflight';
let tempRoot;
let serverProcess;
let browser;
let context;
let secondContext;
let quotaSession;
let appOrigin;
let bootstrapToken;
let ownerAccessToken;
let ownerDeviceId;
let cleanupPromise;
let cleanupFailed = false;
let rejectedMigrationPushes = 0;
let failedPushes = 0;
let migrationCreatePayload;
let firstMigrationPush503Evidence = null;
let secondDeviceTargetVaultIndex = -1;
let secondDeviceTargetChangesEvidence = null;
let secondDeviceTargetHeaderMatches = null;
let secondDeviceTargetDisplayName = null;
let secondDevicePreferenceEvidence = null;
let secondDeviceSyncUiEvidence = null;
let secondDeviceRecordUiEvidence = null;
let secondDeviceSettingsEvidence = null;
let ownerSnippetEvidence = null;
let snippetDiagnosticRoot = null;
const apiEvents = [];
const requestEventByObject = new WeakMap();
const pageErrors = [];
const remoteRequests = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
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
      // The disposable instance is still starting.
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

async function boundedCleanup(label, action, timeoutMs) {
  let timer;
  const outcome = await Promise.race([
    Promise.resolve().then(action).then(
      () => ({ status: 'complete' }),
      (error) => ({ status: 'error', errorType: error?.name || 'unknown' }),
    ),
    new Promise((resolve) => {
      timer = setTimeout(() => resolve({ status: 'timeout' }), timeoutMs);
    }),
  ]);
  clearTimeout(timer);
  console.log(`safe cleanup ${JSON.stringify({ label, ...outcome })}`);
  if (outcome.status !== 'complete') cleanupFailed = true;
  return outcome.status === 'complete';
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    ownerAccessToken = undefined;
    if (quotaSession) {
      await boundedCleanup('restore-origin-quota-override', () =>
        quotaSession.send('Storage.overrideQuotaForOrigin', { origin: appOrigin }), 1500);
      await boundedCleanup('detach-origin-quota-session', () => quotaSession.detach(), 1000);
      quotaSession = null;
    }
    const cleanupPage = context?.pages()?.[0] || null;
    if (cleanupPage && !cleanupPage.isClosed()) {
      let probeCleanup;
      try {
        probeCleanup = await Promise.race([cleanupPage.evaluate(async (databaseName) => {
          let deleteOutcome = 'success';
          await new Promise((resolve) => {
            const request = indexedDB.deleteDatabase(databaseName);
            request.onsuccess = () => resolve();
            request.onerror = () => {
              deleteOutcome = request.error?.name || 'delete-error';
              resolve();
            };
            request.onblocked = () => {
              deleteOutcome = 'blocked';
              resolve();
            };
          });
          const databases = typeof indexedDB.databases === 'function'
            ? await indexedDB.databases()
            : null;
          const databasePresent = Array.isArray(databases) &&
            databases.some((database) => database.name === databaseName);
          return { deleteOutcome, databasePresent,
            deleted: deleteOutcome === 'success' && Array.isArray(databases) && !databasePresent };
        }, MIGRATION_QUOTA_PROBE_DB), new Promise((resolve) => setTimeout(() => resolve({
          deleteOutcome: 'cleanup-timeout', databasePresent: null, deleted: false,
        }), 2000))]);
      } catch (error) {
        probeCleanup = { deleteOutcome: error?.name || 'page-evaluate-error',
          databasePresent: null, deleted: false };
      }
      console.log(`safe final migration quota probe cleanup ${JSON.stringify(probeCleanup)}`);
      if (!probeCleanup.deleted) cleanupFailed = true;
    }
    if (context) await boundedCleanup('close-primary-browser-context', () => context.close(), 3000);
    if (secondContext) await boundedCleanup('close-second-browser-context', () => secondContext.close(), 3000);
    if (browser) {
      const browserClosed = await boundedCleanup('close-browser', () => browser.close(), 5000);
      if (!browserClosed && typeof browser.process === 'function') {
        const browserChild = browser.process();
        if (browserChild && Number.isInteger(browserChild.pid)) {
          try { process.kill(-browserChild.pid, 'SIGKILL'); } catch (_) {}
        }
      }
    }
    try {
      await stopServerGroup(serverProcess);
      console.log('safe cleanup {"label":"stop-disposable-server","status":"complete"}');
    } catch (error) {
      cleanupFailed = true;
      console.log(`safe cleanup ${JSON.stringify({
        label: 'stop-disposable-server', status: 'error', errorType: error?.name || 'unknown',
      })}`);
    }
    for (const directory of [tempRoot, snippetDiagnosticRoot]) {
      if (!directory) continue;
      try {
        fs.rmSync(directory, { recursive: true, force: true });
        if (fs.existsSync(directory)) cleanupFailed = true;
      } catch (_) {
        cleanupFailed = true;
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

async function activateAccessibilitySemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 20000 });
  await placeholder.evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 20000 });
}

async function button(page, label, timeoutMs = 30000) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await locator.waitFor({ state: 'visible', timeout: timeoutMs });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function field(page, label, timeoutMs = 30000) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await locator.waitFor({ state: 'visible', timeout: timeoutMs });
  return locator;
}

async function fieldEvidence(page, label, timeoutMs = 8000) {
  try {
    await field(page, label, timeoutMs);
    return true;
  } catch (_) {
    return false;
  }
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(40);
    await locator.pressSequentially(value, { delay: 25 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function selectVisibleMenuItem(page, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    for (const role of ['menuitem', 'option']) {
      const locator = page.getByRole(role, { name: label, exact: true });
      if (await locator.count().catch(() => 0) !== 1 ||
          !await locator.isVisible().catch(() => false)) continue;
      try {
        await locator.click({ timeout: 1200 });
        return;
      } catch (_) {
        // Flutter's semantics overlay can lag the actual popup during rebuild.
      }
    }
    const clicked = await page.evaluate((expected) => {
      const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      };
      const matches = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const role = element.getAttribute('role');
          const innerText = (element.innerText || '').trim();
          const ariaLabel = (element.getAttribute('aria-label') || '').trim();
          // Workspace navigation can have the same label as a dropdown entry.
          return role !== 'button' && visible(element) &&
            (innerText === expected || ariaLabel === expected);
        });
      if (matches.length !== 1) return false;
      matches[0].click();
      return true;
    }, label).catch(() => false);
    if (clicked) return;
    await page.waitForTimeout(100);
  }
  throw new Error('the exact visible dropdown option was unavailable');
}

async function tapPreferenceDropdown(page, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const accessibleName = new RegExp(`^${escaped}(?:$|[,，\\s])`);
  const candidates = [
    page.getByRole('combobox', { name: accessibleName }),
    page.getByRole('button', { name: accessibleName }),
    page.getByRole('textbox', { name: accessibleName }),
  ];
  const roleMatches = [];
  for (const locator of candidates) {
    const count = await locator.count();
    if (count > 0) roleMatches.push({ locator, count });
  }
  const uniqueMatches = roleMatches.filter((match) => match.count === 1);
  if (roleMatches.length === 1 && uniqueMatches.length === 1) {
    await uniqueMatches[0].locator.click();
    return;
  }
  if (roleMatches.length > 0) {
    throw new Error('the preference dropdown accessible name was ambiguous');
  }

  const clicked = await page.evaluate((expected) => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const matches = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => {
        if (!visible(element)) return false;
        const role = element.getAttribute('role') || '';
        const label = (element.getAttribute('aria-label') || element.innerText || '').trim();
        return ['button', 'combobox', 'textbox'].includes(role) &&
          label.startsWith(expected) && !label.startsWith('保存');
      });
    if (matches.length !== 1) return false;
    matches[0].click();
    return true;
  }, label).catch(() => false);
  if (!clicked) throw new Error('the preference dropdown control was unavailable');
}

async function writeClipboard(page, value) {
  await page.evaluate((text) => navigator.clipboard.writeText(text), value);
}

async function readAndClearClipboard(page) {
  try {
    return await page.evaluate(() => navigator.clipboard.readText());
  } finally {
    await page.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  }
}

async function pasteClipboardField(page, label, value) {
  try {
    await writeClipboard(page, value);
    const locator = await field(page, label);
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(200);
    if (await locator.inputValue().catch(() => '') !== value) {
      await fill(page, label, value);
    }
    assertThat(await locator.inputValue() === value,
      'clipboard or visible-field fallback did not populate an enrollment field');
  } finally {
    await page.evaluate(() => navigator.clipboard.writeText('')).catch(() => {});
  }
}

async function visibleText(page, text, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const visible = await page.evaluate((expected) => {
      const semanticText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body.innerText || ''}\n${semanticText}`.includes(expected);
    }, text).catch(() => false);
    if (visible) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected visible UI state did not appear');
}

async function waitAbsent(page, text, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const visible = await page.evaluate((expected) => {
      const semanticText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body?.innerText || ''}\n${semanticText}`.includes(expected);
    }, text).catch(() => true);
    if (!visible) return;
    await page.waitForTimeout(100);
  }
  throw new Error('recovery state did not remove a blocked action');
}

async function anyVisibleText(page, candidates, timeoutMs = 0) {
  const deadline = Date.now() + timeoutMs;
  while (true) {
    const found = await page.evaluate((expectedValues) => {
      const visibleText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return expectedValues.some((expected) => visibleText.includes(expected));
    }, candidates).catch(() => false);
    if (found || Date.now() >= deadline) return found;
    await page.waitForTimeout(100);
  }
}

async function vaultHeaderMatches(page, expectedNames) {
  return page.evaluate((names) => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    return [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .some((element) => {
        const text = `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`;
        return text.includes('Choose vault') && names.some((name) => text.includes(name));
      });
  }, expectedNames).catch(() => false);
}

async function migratedPreferenceEvidence(page) {
  const dropdowns = await page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const nodes = [...document.querySelectorAll('flt-semantics')].filter(visible);
    const textOf = (element) =>
      `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`.trim();
    const selectedNearLabel = (labelText, expectedValue) => {
      const labels = nodes.filter((element) => textOf(element).includes(labelText));
      const candidates = nodes.filter((element) => {
        const value = textOf(element).replace(/\s+/g, ' ').trim();
        const role = element.getAttribute('role');
        const isControl = role === 'combobox' ||
          element.getAttribute('aria-haspopup') === 'listbox' || role === 'button';
        return value.includes(expectedValue) && value.length < 180 && isControl;
      });
      return labels.some((label) => {
        const labelRect = label.getBoundingClientRect();
        return candidates.some((candidate) => {
          const candidateText = textOf(candidate).replace(/\s+/g, ' ').trim();
          if (!candidateText.includes(expectedValue)) return false;
          const candidateRect = candidate.getBoundingClientRect();
          return Math.abs(candidateRect.y - labelRect.y) < 120 &&
            Math.abs(candidateRect.x - labelRect.x) < 500;
        });
      });
    };
    return {
      defaultSectionLabelVisible: nodes.some((element) =>
        textOf(element).includes('Default workspace section')),
      terminalFontSizeLabelVisible: nodes.some((element) =>
        textOf(element).includes('Terminal font size')),
      terminalThemeLabelVisible: nodes.some((element) =>
        textOf(element).includes('Terminal color theme')),
      selectedDefaultSection: selectedNearLabel('Default workspace section', 'Snippets'),
      selectedTerminalFontSize: selectedNearLabel('Terminal font size', '16 px'),
      selectedTerminalTheme: selectedNearLabel('Terminal color theme', 'Light'),
    };
  }).catch(() => ({
    defaultSectionLabelVisible: false,
    terminalFontSizeLabelVisible: false,
    terminalThemeLabelVisible: false,
    selectedDefaultSection: false,
    selectedTerminalFontSize: false,
    selectedTerminalTheme: false,
  }));
  const shortcutFields = {
    search: 'Search terminal scrollback',
    searchNext: 'Next search match',
    searchPrevious: 'Previous search match',
    disconnect: 'Disconnect active terminal tab',
  };
  const expectedShortcutValues = {
    search: 'mod+alt+shift+x',
    searchNext: 'mod+alt+y',
    searchPrevious: 'mod+alt+shift+y',
    disconnect: 'mod+alt+shift+z',
  };
  const shortcutsLabelVisible = await visibleTextEvidence(
    page, 'Terminal keyboard shortcuts', 1500,
  );
  const shortcutScroll = await scrollToBottomAttempt(page);
  const shortcuts = {};
  const shortcutFieldDiagnostics = {};
  for (const [action, label] of Object.entries(shortcutFields)) {
    const inputSelector = `input[data-semantics-role="text-field"][aria-label*=${JSON.stringify(label)}]`;
    const textFieldInput = page.locator(inputSelector);
    const generalInput = page.locator(
      `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
    );
    const expected = expectedShortcutValues[action];
    let textFieldCount = 0;
    let generalInputCount = 0;
    let inputCount = 0;
    try {
      textFieldCount = await textFieldInput.count();
      generalInputCount = await generalInput.count();
      assertThat(textFieldCount <= 1 && generalInputCount <= 1,
        'a supported terminal shortcut label resolved to multiple inputs');
      const input = textFieldCount === 1 ? textFieldInput : generalInput;
      inputCount = textFieldCount === 1 ? textFieldCount : generalInputCount;
      let attached = false;
      let visible = false;
      let viewportIntersecting = false;
      let focused = false;
      let valueMatchesExpected = false;
      let activeElementValueMatchesExpected = false;
      if (inputCount === 1) {
        await input.waitFor({ state: 'visible', timeout: 5000 });
        attached = true;
        visible = await input.isVisible().catch(() => false);
        await input.scrollIntoViewIfNeeded();
        viewportIntersecting = await input.evaluate((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 &&
            rect.left < window.innerWidth && rect.top < window.innerHeight;
        }).catch(() => false);
        await input.click({ timeout: 5000 });
        await input.focus();
        const deadline = Date.now() + 5000;
        let value = await input.inputValue().catch(() => null);
        while (value !== expected && Date.now() < deadline) {
          await page.waitForTimeout(150);
          value = await input.inputValue().catch(() => null);
        }
        valueMatchesExpected = value === expected;
        activeElementValueMatchesExpected = await page.evaluate((expectedValue) => {
          const active = document.activeElement;
          return typeof active?.value === 'string' && active.value === expectedValue;
        }, expected).catch(() => false);
        focused = await input.evaluate((element) => element === document.activeElement)
          .catch(() => false);
      }
      const semanticEvidence = await page.evaluate(({ expectedLabel, expectedValue }) => {
        const inViewport = (element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0 &&
            rect.right > 0 && rect.bottom > 0 && rect.left < window.innerWidth &&
            rect.top < window.innerHeight;
        };
        const candidates = [...document.querySelectorAll('flt-semantics[role="textbox"]')]
          .filter((element) => (element.getAttribute('aria-label') || '')
            .includes(expectedLabel));
        return {
          count: candidates.length,
          visibleCount: candidates.filter(inViewport).length,
          role: candidates.length === 1 ? candidates[0].getAttribute('role') : null,
          labelAndChordExact: candidates.some((element) => {
            const fullLabel = element.getAttribute('aria-label') || '';
            return fullLabel.includes(expectedLabel) && fullLabel.includes(expectedValue);
          }),
        };
      }, { expectedLabel: label, expectedValue: expected }).catch(() => ({
        count: 0, visibleCount: 0, role: null, labelAndChordExact: false,
      }));
      shortcuts[action] = inputCount === 1 && attached && visible &&
        viewportIntersecting && focused && valueMatchesExpected &&
        activeElementValueMatchesExpected;
      shortcutFieldDiagnostics[action] = {
        label,
        role: textFieldCount === 1 ? 'text-field-input' : semanticEvidence.role,
        inputCount,
        textFieldCount,
        attached,
        visible,
        viewportIntersecting,
        semanticTextboxCount: semanticEvidence.count,
        visibleSemanticTextboxCount: semanticEvidence.visibleCount,
        focused,
        activeElementValueMatchesExpected,
        ariaLabelAndChordExact: semanticEvidence.labelAndChordExact,
        valueMatchesExpected,
        accepted: shortcuts[action],
      };
    } catch (_) {
      shortcuts[action] = false;
      shortcutFieldDiagnostics[action] = {
        label,
        role: null,
        inputCount,
        textFieldCount,
        attached: false,
        visible: false,
        viewportIntersecting: false,
        semanticTextboxCount: 0,
        visibleSemanticTextboxCount: 0,
        focused: false,
        activeElementValueMatchesExpected: false,
        ariaLabelAndChordExact: false,
        valueMatchesExpected: false,
        accepted: false,
      };
    }
  }
  return {
    ...dropdowns,
    shortcutsLabelVisible,
    shortcutScroll,
    shortcutFieldDiagnostics,
    shortcutBindings: shortcuts,
  };
}

async function secondDeviceSyncHealthEvidence(page, expectedVaultNames) {
  const metrics = await page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const body = document.body.innerText || '';
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const text = `${body}\n${semantics}`;
    const countAfter = (label, suffix = '') => {
      const index = text.lastIndexOf(label);
      if (index < 0) return null;
      const match = text.slice(index + label.length, index + label.length + 80)
        .match(/^\s*(\d+)(?:\s+changes?)?/i);
      return match ? Number(match[1]) : null;
    };
    const statuses = [
      'Idle', 'Pending', 'Syncing', 'Read-only', 'Rebuilding snapshot',
      'Retry queued', 'Snapshot needed', 'Key update needed',
      'Device revoked', 'Sign in needed', 'Offline', 'Sync error',
    ];
    const unavailableMatch = text.match(/(\d+) encrypted record\(s\) could not be verified/);
    const headings = ['Sync health', 'Workspace settings', 'Your server fleet'];
    return {
      activePageHeading: headings.find((heading) => text.includes(heading)) ?? null,
      syncStatus: statuses.find((status) => text.includes(status)) ?? null,
      outboxItems: countAfter('Outbox items'),
      lastPullChanges: countAfter('Last pull'),
      openConflicts: countAfter('Open conflicts'),
      unavailableRecordCount: unavailableMatch ? Number(unavailableMatch[1]) : null,
      unavailableWarningVisible: Boolean(unavailableMatch),
      syncErrorVisible: text.includes('Sync error') || text.includes('Something went wrong') ||
        text.includes('Unable to'),
      metricsLabelsVisible: ['Sync status', 'Outbox items', 'Last pull', 'Open conflicts']
        .filter((label) => text.includes(label)),
    };
  });
  return {
    ...metrics,
    currentVaultHeaderMatchesTarget: await vaultHeaderMatches(page, expectedVaultNames),
  };
}

async function waitForSyncSettled(page, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  let idleSince = null;
  const syncNowButton = page.getByRole('button', { name: 'Sync now', exact: true }).first();
  while (Date.now() < deadline) {
    const visibleSyncText = await page.evaluate(() => {
      const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      };
      const body = document.body.innerText || '';
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${body}\n${semantics}`;
    }).catch(() => '');
    const idle = /\bIdle\b/.test(visibleSyncText) &&
      !/Syncing(?:…|\.\.\.)?/.test(visibleSyncText);
    const syncNowVisible = await syncNowButton.isVisible().catch(() => false);
    const syncNowEnabled = syncNowVisible && await syncNowButton.isEnabled().catch(() => false);
    if (idle && syncNowEnabled) {
      idleSince ??= Date.now();
      if (Date.now() - idleSince >= 750) return;
    } else {
      idleSince = null;
    }
    await page.waitForTimeout(100);
  }
  throw new Error('second-device Sync did not settle to enabled Sync now and Idle');
}

async function recordViewEvidence(page, heading, expectedMarkers, emptyStateLabels) {
  await visibleText(page, heading, 45000);
  const deadline = Date.now() + 10000;
  let evidence;
  do {
    evidence = await page.evaluate(({ expectedHeading, markers, emptyLabels }) => {
      const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      };
      const body = document.body.innerText || '';
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const text = `${body}\n${semantics}`;
      return {
        activePageHeadingVisible: text.includes(expectedHeading),
        markersVisible: Object.fromEntries(
          Object.entries(markers).map(([label, marker]) => [label, text.includes(marker)]),
        ),
        emptyStateLabels: emptyLabels.filter((label) => text.includes(label)),
      };
    }, { expectedHeading: heading, markers: expectedMarkers, emptyLabels: emptyStateLabels })
      .catch(() => ({
        activePageHeadingVisible: false,
        markersVisible: Object.fromEntries(Object.keys(expectedMarkers).map((key) => [key, false])),
        emptyStateLabels: [],
      }));
    if (Object.values(evidence.markersVisible).every(Boolean) ||
        evidence.emptyStateLabels.length > 0 || Date.now() >= deadline) {
      return evidence;
    }
    await page.waitForTimeout(100);
  } while (Date.now() < deadline);
  return evidence;
}

async function scrollToTopAttempt(page) {
  const result = await page.evaluate(() => {
    const candidates = [document.scrollingElement, ...document.querySelectorAll('*')]
      .filter((element) => element && element.scrollHeight > element.clientHeight + 4);
    for (const element of candidates) {
      element.scrollTop = 0;
      element.scrollLeft = 0;
    }
    window.scrollTo(0, 0);
    return { scrollableContainerCount: candidates.length };
  }).catch(() => ({ scrollableContainerCount: 0 }));
  await page.keyboard.press('Home').catch(() => {});
  await page.waitForTimeout(150);
  return { attempted: true, ...result };
}

async function scrollToBottomAttempt(page) {
  const result = await page.evaluate(() => {
    const candidates = [document.scrollingElement, ...document.querySelectorAll('*')]
      .filter((element) => element && element.scrollHeight > element.clientHeight + 4);
    const before = candidates.map((element) => element.scrollTop);
    for (const element of candidates) {
      element.scrollTop = element.scrollHeight;
      element.scrollLeft = 0;
    }
    window.scrollTo(0, document.documentElement.scrollHeight);
    return {
      scrollableContainerCount: candidates.length,
      movedContainerCount: candidates.filter((element, index) => element.scrollTop !== before[index]).length,
      atBottomContainerCount: candidates.filter((element) =>
        element.scrollTop >= element.scrollHeight - element.clientHeight - 2).length,
    };
  }).catch(() => ({ scrollableContainerCount: 0, movedContainerCount: 0,
    atBottomContainerCount: 0 }));
  await page.keyboard.press('End').catch(() => {});
  await page.waitForTimeout(150);
  return { attempted: true, ...result };
}

async function snippetPageVisualEvidence(page, profileLabel, scrollEvidence) {
  const visibleEvidence = await page.evaluate(() => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
    const text = `${document.body.innerText || ''}\n${semantics
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n')}`;
    const cardLike = semantics.filter((element) => {
      const role = element.getAttribute('role');
      const rect = element.getBoundingClientRect();
      const largeTileButton = role === 'button' && rect.width >= 220 && rect.height >= 55;
      return role === 'listitem' || role === 'article' || largeTileButton;
    });
    return {
      untitledSnippetVisible: text.includes('Untitled snippet'),
      visibleUiCardOrListTileCount: cardLike.length,
      visibleListItemCount: semantics.filter((element) =>
        element.getAttribute('role') === 'listitem').length,
      visibleArticleCount: semantics.filter((element) =>
        element.getAttribute('role') === 'article').length,
      visibleLargeButtonTileCount: semantics.filter((element) => {
        const rect = element.getBoundingClientRect();
        return element.getAttribute('role') === 'button' &&
          rect.width >= 220 && rect.height >= 55;
      }).length,
    };
  }).catch(() => ({
    untitledSnippetVisible: false,
    visibleUiCardOrListTileCount: 0,
    visibleListItemCount: 0,
    visibleArticleCount: 0,
    visibleLargeButtonTileCount: 0,
  }));
  const screenshotPath = path.join(snippetDiagnosticRoot, `${profileLabel}-snippets.png`);
  let screenshotSaved = false;
  try {
    await page.screenshot({ path: screenshotPath, fullPage: false });
    screenshotSaved = fs.existsSync(screenshotPath);
  } catch (_) {
    // Preserve the boolean UI diagnostics if screenshot capture is unavailable.
  }
  return {
    ...visibleEvidence,
    scrollToTop: scrollEvidence,
    screenshotSaved,
    screenshotPath: screenshotSaved ? screenshotPath : null,
  };
}

async function visibleTextEvidence(page, expectedText, timeoutMs = 8000) {
  try {
    await visibleText(page, expectedText, timeoutMs);
    return true;
  } catch (_) {
    return false;
  }
}

async function tapSemanticTextContaining(page, text) {
  const tapped = await page.evaluate((expected) => {
    const visible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      const label = `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`;
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0 &&
        label.includes(expected);
    };
    const actionable = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible);
    if (actionable.length === 1) {
      actionable[0].click();
      return true;
    }
    const matches = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .sort((left, right) => {
        const a = left.getBoundingClientRect();
        const b = right.getBoundingClientRect();
        return a.width * a.height - b.width * b.height;
      });
    if (matches.length === 0) return false;
    matches[0].click();
    return true;
  }, text);
  if (!tapped) throw new Error('visible local-profile action was not found');
}

async function waitFor(predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected API state did not appear');
}

function apiRoute(pathname) {
  if (pathname === '/api/v1/auth/register') return 'register';
  if (pathname === '/api/v1/auth/login') return 'login';
  if (pathname === '/api/v1/vaults') return 'vaults';
  if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) return 'push';
  if (/^\/api\/v1\/vaults\/[^/]+\/changes$/.test(pathname)) return 'changes';
  return pathname.startsWith('/api/v1/') ? 'other-api' : null;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function trackApi(page, contextLabel = 'owner') {
  page.on('request', (request) => {
    let url;
    try {
      url = new URL(request.url());
    } catch (_) {
      return;
    }
    if (url.origin !== appOrigin) remoteRequests.push(url.origin);
    const route = apiRoute(url.pathname);
    if (!route) return;
    const event = {
      contextLabel,
      route,
      method: request.method(),
      pathname: url.pathname,
      status: null,
      failed: false,
      requestedAt: Date.now(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      markerLeakInRequest: false,
      vaultId: null,
      responsePromise: null,
    };
    if ((route === 'vaults' && request.method() === 'POST') || route === 'push') {
      const body = request.postData() || '';
      event.markerLeakInRequest = PLAINTEXT_MARKERS.some((marker) => body.includes(marker));
      if (route === 'vaults' && request.method() === 'POST') {
        try {
          const body = request.postDataJSON();
          event.vaultId = body?.vault_id || null;
          migrationCreatePayload = body;
        } catch (_) {
          event.vaultId = null;
          migrationCreatePayload = null;
        }
      }
    }
    apiEvents.push(event);
    requestEventByObject.set(request, event);
  });
  page.on('response', (response) => {
    const event = requestEventByObject.get(response.request());
    if (!event) return;
    event.status = response.status();
    if (event.route === 'register' || event.route === 'login' ||
        event.route === 'vaults' || event.route === 'changes') {
      event.responsePromise = response.json().catch(() => null);
    }
  });
  page.on('requestfailed', (request) => {
    const event = requestEventByObject.get(request);
    if (event) event.failed = true;
  });
}

async function eventFor(route, method, fromIndex = 0, timeoutMs = 30000) {
  await waitFor(() => apiEvents.slice(fromIndex).some((event) =>
    event.route === route && event.method === method && event.status !== null), timeoutMs);
  return apiEvents.slice(fromIndex).find((event) =>
    event.route === route && event.method === method && event.status !== null);
}

async function waitForTargetChangesEvidence(fromIndex, targetVaultId, timeoutMs = 45000) {
  const expectedPath = `/api/v1/vaults/${targetVaultId}/changes`;
  const relevant = () => apiEvents.slice(fromIndex).filter((event) =>
    event.contextLabel === 'second-device' && event.route === 'changes' &&
    event.method === 'GET' && event.pathname === expectedPath);
  const deadline = Date.now() + timeoutMs;
  while (timeoutMs > 0 && Date.now() < deadline &&
      !relevant().some((event) => event.status !== null)) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const requests = relevant();
  const responses = requests.filter((event) => event.status !== null);
  const successful = responses.filter((event) => event.status === 200);
  const bodies = await Promise.all(successful.map((event) =>
    event.responsePromise ?? Promise.resolve(null)));
  const eventCounts = bodies.map((body) =>
    Array.isArray(body?.events) ? body.events.length : -1);
  const opaqueCreateRecordIds = new Set(bodies.flatMap((body) =>
    Array.isArray(body?.events)
      ? body.events.filter((event) => event.event_type === 'create' &&
          typeof event.record_id === 'string' &&
          typeof event.envelope?.ciphertext === 'string')
        .map((event) => event.record_id)
      : []));
  const completeOpaqueBatch = opaqueCreateRecordIds.size === EXPECTED_MIGRATED_RECORDS;
  const errorCodes = [...new Set(bodies.map((body) => body?.error?.code)
    .filter((code) => typeof code === 'string' && /^[A-Z0-9_]{1,64}$/.test(code)))];
  return {
    requestCount: requests.length,
    responseCount: responses.length,
    pendingCount: requests.filter((event) => event.status === null).length,
    statusCodes: responses.map((event) => event.status),
    eventCounts,
    uniqueOpaqueRecordCount: opaqueCreateRecordIds.size,
    completeOpaqueBatch,
    errorCodes,
  };
}

function cliCredential(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `isolated ${description} failed`);
  const value = (result.stdout || '').trim().split(/\s+/).at(-1);
  result.stdout = '';
  assertThat(typeof value === 'string' && value.length >= 40,
    `isolated ${description} credential is unavailable`);
  return value;
}

async function directApi(baseUrl, method, pathname, token) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${token}`,
    },
    signal: AbortSignal.timeout(15000),
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

async function fillOriginToQuota(page) {
  return page.evaluate(async (databaseName) => {
    let database;
    try {
      database = await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName, 1);
        request.onupgradeneeded = () => request.result.createObjectStore('payload');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('probe open failed'));
      });
      let successfulWrites = 0;
      let writtenBytes = 0;
      let quotaError = null;
      let nextKey = 0;
      const write = async (size) => new Promise((resolve) => {
        const transaction = database.transaction('payload', 'readwrite');
        const key = nextKey++;
        const request = transaction.objectStore('payload').put(
          crypto.getRandomValues(new Uint8Array(size)), key,
        );
        let requestError;
        request.onerror = () => { requestError = request.error?.name || null; };
        transaction.oncomplete = () => resolve({ error: null });
        transaction.onabort = () => resolve({
          error: transaction.error?.name || requestError || 'AbortError',
        });
        transaction.onerror = () => {};
      });
      for (let attempt = 0; attempt < 2048; attempt += 1) {
        const result = await write(65536);
        if (result.error) {
          quotaError = result.error;
          break;
        }
        successfulWrites += 1;
        writtenBytes += 65536;
      }
      const estimate = await navigator.storage.estimate();
      return {
        quotaError,
        successfulWrites,
        writtenBytes,
        usage: Number.isSafeInteger(estimate.usage) ? estimate.usage : null,
        quota: Number.isSafeInteger(estimate.quota) ? estimate.quota : null,
      };
    } catch (error) {
      return { quotaError: null, openError: error?.name || 'Error', successfulWrites: 0 };
    } finally { database?.close(); }
  }, MIGRATION_QUOTA_PROBE_DB);
}

async function readOriginStorageEstimate(page, maxWaitMs = 4000) {
  return page.evaluate(async (waitMs) => {
    const startedAt = performance.now();
    let previousUsage = null;
    let stableSamples = 0;
    let latest = { usage: null, quota: null };
    while (performance.now() - startedAt <= waitMs) {
      const value = await navigator.storage.estimate();
      latest = {
        usage: Number.isSafeInteger(value.usage) ? value.usage : null,
        quota: Number.isSafeInteger(value.quota) ? value.quota : null,
      };
      if (latest.usage === previousUsage) stableSamples += 1;
      else stableSamples = 0;
      previousUsage = latest.usage;
      if (stableSamples >= 3) {
        return { ...latest, stable: true, samples: stableSamples + 1 };
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return { ...latest, stable: false, samples: null };
  }, maxWaitMs);
}

async function fillOriginToHeadroom(page, headroomBytes) {
  return page.evaluate(async ({ databaseName, headroomBytes }) => {
    const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
    const estimate = async () => {
      const value = await navigator.storage.estimate();
      return {
        usage: Number.isSafeInteger(value.usage) ? value.usage : null,
        quota: Number.isSafeInteger(value.quota) ? value.quota : null,
      };
    };
    const stableEstimate = async () => {
      let priorUsage = null;
      let stableSamples = 0;
      let latest = { usage: null, quota: null };
      for (let sample = 0; sample < 40; sample += 1) {
        latest = await estimate();
        if (latest.usage === priorUsage) stableSamples += 1;
        else stableSamples = 0;
        priorUsage = latest.usage;
        if (stableSamples >= 3) return latest;
        await pause(100);
      }
      return latest;
    };
    let database;
    try {
      const baseline = await stableEstimate();
      if (!Number.isSafeInteger(baseline.usage) || !Number.isSafeInteger(baseline.quota) ||
          baseline.quota <= baseline.usage + headroomBytes) {
        return { error: 'invalid-reset-baseline', baselineUsage: baseline.usage,
          quota: baseline.quota, headroomBytes };
      }
      database = await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName, 1);
        request.onupgradeneeded = () => request.result.createObjectStore('payload');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('probe refill open failed'));
      });
      let successfulWrites = 0;
      let writtenBytes = 0;
      let nextKey = 0;
      let writeError = null;
      const write = async (size) => new Promise((resolve) => {
        const transaction = database.transaction('payload', 'readwrite');
        const request = transaction.objectStore('payload').put(
          crypto.getRandomValues(new Uint8Array(size)), nextKey++,
        );
        let requestError;
        request.onerror = () => { requestError = request.error?.name || null; };
        transaction.oncomplete = () => resolve(null);
        transaction.onabort = () => resolve(
          transaction.error?.name || requestError || 'AbortError',
        );
        transaction.onerror = () => {};
      });
      let current = baseline;
      for (let attempt = 0; attempt < 2048; attempt += 1) {
        const reserve = current.quota - current.usage;
        if (reserve <= headroomBytes) break;
        const size = Math.max(256, Math.min(8192,
          Math.floor((reserve - headroomBytes) / 4096) * 4096 || 256));
        writeError = await write(size);
        if (writeError) break;
        successfulWrites += 1;
        writtenBytes += size;
        current = await stableEstimate();
        if (!Number.isSafeInteger(current.usage) || !Number.isSafeInteger(current.quota)) {
          writeError = 'storage-estimate-unavailable';
          break;
        }
      }
      const finalEstimate = await stableEstimate();
      const actualReserveBytes = Number.isSafeInteger(finalEstimate.usage) &&
          Number.isSafeInteger(finalEstimate.quota)
        ? finalEstimate.quota - finalEstimate.usage
        : null;
      const databases = typeof indexedDB.databases === 'function'
        ? await indexedDB.databases()
        : null;
      return {
        error: writeError,
        baselineUsage: baseline.usage,
        quota: baseline.quota,
        requestedHeadroomBytes: headroomBytes,
        successfulWrites,
        writtenBytes,
        finalUsage: finalEstimate.usage,
        finalQuota: finalEstimate.quota,
        actualReserveBytes,
        probeDatabasePresent: Array.isArray(databases) &&
          databases.some((entry) => entry.name === databaseName),
      };
    } catch (error) {
      return { error: error?.name || 'Error', messageCategory: 'probe-refill' };
    } finally { database?.close(); }
  }, { databaseName: MIGRATION_QUOTA_PROBE_DB, headroomBytes });
}

async function confirmOriginQuotaExceeded(page) {
  return page.evaluate(async (databaseName) => {
    let database;
    const key = 'local-migration-quota-confirmation';
    try {
      database = await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('probe open failed'));
      });
      const writeOutcome = await new Promise((resolve) => {
        const transaction = database.transaction('payload', 'readwrite');
        const request = transaction.objectStore('payload').put(
          crypto.getRandomValues(new Uint8Array(65536)), key,
        );
        let requestError;
        request.onerror = () => { requestError = request.error?.name || null; };
        transaction.oncomplete = () => resolve({ success: true, error: null });
        transaction.onabort = () => resolve({
          success: false,
          error: transaction.error?.name || requestError || 'AbortError',
        });
        transaction.onerror = () => {};
      });
      if (writeOutcome.success) {
        await new Promise((resolve) => {
          const transaction = database.transaction('payload', 'readwrite');
          transaction.objectStore('payload').delete(key);
          transaction.oncomplete = transaction.onabort = resolve;
          transaction.onerror = () => {};
        });
      }
      return {
        attemptedBytes: 65536,
        writeSucceeded: writeOutcome.success,
        quotaError: writeOutcome.error,
      };
    } catch (error) {
      return { attemptedBytes: 65536, openError: error?.name || 'Error' };
    } finally { database?.close(); }
  }, MIGRATION_QUOTA_PROBE_DB);
}

async function deleteMigrationQuotaProbe(page) {
  return page.evaluate(async (databaseName) => {
    let deleteOutcome = 'success';
    await new Promise((resolve) => {
      const request = indexedDB.deleteDatabase(databaseName);
      request.onsuccess = () => resolve();
      request.onerror = () => {
        deleteOutcome = request.error?.name || 'delete-error';
        resolve();
      };
      request.onblocked = () => {
        deleteOutcome = 'blocked';
        resolve();
      };
    });
    const databases = typeof indexedDB.databases === 'function'
      ? await indexedDB.databases()
      : null;
    const databasePresent = Array.isArray(databases) &&
      databases.some((database) => database.name === databaseName);
    return { deleteOutcome, databasePresent, deleted: deleteOutcome === 'success' &&
      Array.isArray(databases) && !databasePresent };
  }, MIGRATION_QUOTA_PROBE_DB);
}

async function localVaultSqliteCounts(page, databaseName, label) {
  const file = await page.evaluate(async (name) => {
    let db;
    let phase = 'indexeddb-open';
    let sqliteJournalPresent = null;
    let sqliteJournalLength = null;
    try {
      db = await new Promise((resolve, reject) => {
        const request = indexedDB.open(name);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error('local database open failed'));
      });
      phase = 'check-vfs-stores';
      if (!db.objectStoreNames.contains('files') || !db.objectStoreNames.contains('blocks')) {
        const error = new Error('local database VFS stores are missing');
        error.name = 'MissingVfsStores';
        throw error;
      }
      phase = 'read-vfs-file-rows';
      const files = await new Promise((resolve, reject) => {
        const tx = db.transaction('files', 'readonly');
        const request = tx.objectStore('files').getAll();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error);
      });
      const journalFile = files.find((row) => row?.name === '/database-journal' ||
        row?.name === `/${name}/database-journal` || row?.name?.endsWith('/database-journal'));
      sqliteJournalPresent = Boolean(journalFile);
      sqliteJournalLength = journalFile ? Number(journalFile.length) : null;
      phase = 'read-vfs-file-keys';
      const tx = db.transaction('files', 'readonly');
      const txComplete = new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('local DB file read aborted'));
      });
      const keys = await new Promise((resolve, reject) => {
        const request = tx.objectStore('files').getAllKeys();
        request.onsuccess = () => resolve(request.result || []);
        request.onerror = () => reject(request.error);
      });
      await txComplete;
      phase = 'locate-sqlite-main-file';
      const index = files.findIndex((row) => row?.name === '/database' ||
        row?.name === `/${name}/database` || row?.name?.endsWith('/database'));
      if (index < 0) {
        const error = new Error('local SQLite main file is missing');
        error.name = 'MissingSqliteMainFile';
        throw error;
      }
      const row = files[index];
      const fileId = Number(keys[index]);
      phase = 'read-vfs-blocks';
      const blocksTx = db.transaction('blocks', 'readonly');
      const blocksComplete = new Promise((resolve, reject) => {
        blocksTx.oncomplete = resolve;
        blocksTx.onerror = () => reject(blocksTx.error);
        blocksTx.onabort = () => reject(blocksTx.error || new Error('local DB block read aborted'));
      });
      const range = IDBKeyRange.bound([fileId, 0], [fileId, Number.MAX_SAFE_INTEGER]);
      const [blockKeys, values] = await Promise.all([
        new Promise((resolve, reject) => {
          const request = blocksTx.objectStore('blocks').getAllKeys(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error);
        }),
        new Promise((resolve, reject) => {
          const request = blocksTx.objectStore('blocks').getAll(range);
          request.onsuccess = () => resolve(request.result || []);
          request.onerror = () => reject(request.error);
        }),
      ]);
      await blocksComplete;
      phase = 'serialize-vfs-blocks';
      const blocks = blockKeys.map((key, i) => {
        const value = values[i];
        const bytes = value instanceof ArrayBuffer ? new Uint8Array(value) :
          ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
        if (!bytes) {
          const error = new Error('unsupported local SQLite block');
          error.name = 'UnsupportedVfsBlock';
          throw error;
        }
        return { offset: Number(key?.[1]), base64: btoa(String.fromCharCode(...bytes)) };
      });
      return {
        fileId,
        name: row.name,
        length: Number(row.length),
        blocks,
        sqliteJournalPresent,
        sqliteJournalLength,
      };
    } catch (error) {
      return {
        snapshotError: {
          phase,
          name: typeof error?.name === 'string' ? error.name : 'Error',
          code: Number.isInteger(error?.code) ? error.code : null,
          sqliteJournalPresent,
          sqliteJournalLength,
        },
      };
    } finally { db?.close(); }
  }, databaseName);
  if (file?.snapshotError) {
    const error = new Error('LocalVault IndexedDB snapshot extraction failed');
    error.safeStage = `indexeddb:${file.snapshotError.phase}:${file.snapshotError.name}:${file.snapshotError.code ?? 'no-code'}`;
    error.safeDetails = {
      sqliteJournal: {
        name: 'database-journal',
        present: file.snapshotError.sqliteJournalPresent,
        length: file.snapshotError.sqliteJournalLength,
      },
    };
    throw error;
  }
  let bytes;
  try {
    bytes = reconstructSqliteFile({
      fileId: file.fileId,
      name: file.name,
      length: file.length,
      blocks: file.blocks.map((block) => ({
        offset: block.offset,
        bytes: Buffer.from(block.base64, 'base64'),
      })),
    });
  } catch (cause) {
    const error = new Error('LocalVault SQLite VFS reconstruction failed');
    error.safeStage = `vfs-reconstruct:${cause?.name || 'Error'}`;
    error.safeDetails = {
      sqliteJournal: {
        name: 'database-journal',
        present: file.sqliteJournalPresent,
        length: file.sqliteJournalLength,
      },
    };
    throw error;
  }
  const snapshot = path.join(tempRoot, `${label}.sqlite`);
  try {
    fs.writeFileSync(snapshot, bytes, { mode: 0o600, flag: 'wx' });
  } catch (cause) {
    const error = new Error('LocalVault SQLite snapshot file could not be written');
    error.safeStage = `snapshot-file:${cause?.code || cause?.name || 'Error'}`;
    throw error;
  }
  try {
    const pythonBody = [
      'import hashlib,json,sqlite3,sys',
      "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
      'db.row_factory=sqlite3.Row',
      'db.execute("PRAGMA query_only=ON")',
      'tables=json.loads(sys.argv[2])',
      "allowed={'local_vault_records','local_vault_migrations','local_vault_migration_items','local_vault_migration_create_payloads'}",
      'assert set(tables) <= allowed',
      "result={'integrity':db.execute('PRAGMA integrity_check').fetchone()[0]}",
      "result['counts']={table:db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in tables}",
      "result['migrationStates']=dict(db.execute('SELECT status,COUNT(*) FROM local_vault_migrations GROUP BY status').fetchall())",
      "result['migrationJournals']=[{'migrationId':r['migration_id'],'targetVaultId':r['target_vault_id'],'expectedItemCount':r['expected_item_count'],'status':r['status']} for r in db.execute('SELECT migration_id,target_vault_id,expected_item_count,status FROM local_vault_migrations ORDER BY created_at_ms,migration_id').fetchall()]",
      "items=db.execute('SELECT migration_id,record_id,record_type,target_envelope_json,target_envelope_sha256 FROM local_vault_migration_items ORDER BY migration_id,record_id').fetchall()",
      "result['migrationItems']=[]",
      "for r in items:\n envelope_json=r['target_envelope_json']; envelope=json.loads(envelope_json); header=envelope.get('header') if isinstance(envelope,dict) else {}; ciphertext=envelope.get('ciphertext') if isinstance(envelope,dict) else None; computed_envelope_hash=hashlib.sha256(envelope_json.encode('utf-8')).hexdigest(); canonical_envelope_json=json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False); canonical_envelope_hash=hashlib.sha256(canonical_envelope_json.encode('utf-8')).hexdigest(); ciphertext_hash=hashlib.sha256(ciphertext.encode('utf-8')).hexdigest() if isinstance(ciphertext,str) else None; result['migrationItems'].append({'migrationId':r['migration_id'],'recordId':r['record_id'],'recordType':r['record_type'],'storedEnvelopeSha256':r['target_envelope_sha256'],'computedEnvelopeSha256':computed_envelope_hash,'canonicalEnvelopeSha256':canonical_envelope_hash,'ciphertextSha256':ciphertext_hash,'opId':header.get('op_id') if isinstance(header,dict) else None,'revisionId':header.get('revision_id') if isinstance(header,dict) else None,'targetVaultId':header.get('vault_id') if isinstance(header,dict) else None,'envelopeValid':isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and isinstance(ciphertext,str) and len(ciphertext)>=32 and isinstance(envelope.get('nonce'),str) and isinstance(envelope.get('signature'),str)})",
      "payloads=db.execute('SELECT migration_id,payload_json,payload_sha256 FROM local_vault_migration_create_payloads ORDER BY migration_id').fetchall()",
      "result['migrationCreatePayloads']=[]",
      "for r in payloads:\n payload=json.loads(r['payload_json']); result['migrationCreatePayloads'].append({'migrationId':r['migration_id'],'targetVaultId':payload.get('vault_id') if isinstance(payload,dict) else None,'storedPayloadSha256':r['payload_sha256'],'computedPayloadSha256':hashlib.sha256(r['payload_json'].encode('utf-8')).hexdigest()})",
    ].join('\n');
    const python = [
      'try:',
      ...pythonBody.split('\n').map((line) => `  ${line}`),
      'except Exception as error:',
      "  print(json.dumps({'queryError': {'type': type(error).__name__, 'sqliteErrorName': getattr(error, 'sqlite_errorname', None), 'sqliteErrorCode': getattr(error, 'sqlite_errorcode', None)}}))",
      'else:',
      "  print(json.dumps(result,separators=(',',':')))",
    ].join('\n');
    const result = spawnSync('python3', ['-c', python, snapshot, JSON.stringify(LOCAL_MIGRATION_TABLES)], {
      cwd: ROOT,
      encoding: 'utf8',
      timeout: 10000,
      stdio: ['ignore', 'pipe', 'ignore'],
      maxBuffer: 32768,
    });
    if (result.error || result.status !== 0) {
      const error = new Error('LocalVault read-only SQLite query failed');
      error.safeStage = `sqlite-query:${result.error?.code || `exit-${result.status}`}`;
      error.safeDetails = {
        sqliteJournal: {
          name: 'database-journal',
          present: file.sqliteJournalPresent,
          length: file.sqliteJournalLength,
        },
      };
      throw error;
    }
    let resultValue;
    try {
      resultValue = JSON.parse(result.stdout);
    } catch (_) {
      const error = new Error('LocalVault read-only SQLite result was invalid');
      error.safeStage = 'sqlite-query:invalid-json';
      throw error;
    }
    if (resultValue?.queryError) {
      const error = new Error('LocalVault read-only SQLite query raised a controlled exception');
      const queryError = resultValue.queryError;
      error.safeStage = `sqlite-query:${queryError.type || 'unknown'}:${queryError.sqliteErrorName || 'no-name'}:${queryError.sqliteErrorCode ?? 'no-code'}`;
      error.safeDetails = {
        sqliteJournal: {
          name: 'database-journal',
          present: file.sqliteJournalPresent,
          length: file.sqliteJournalLength,
        },
      };
      throw error;
    }
    return {
      ...resultValue,
      sqliteJournal: {
        name: 'database-journal',
        present: file.sqliteJournalPresent,
        length: file.sqliteJournalLength,
      },
      plaintextMarkerFound: PLAINTEXT_MARKERS.some((marker) => bytes.includes(Buffer.from(marker))),
    };
  } finally { fs.rmSync(snapshot, { force: true }); }
}

function safeSnapshotErrorEvidence(error) {
  return {
    category: error?.safeStage || error?.name || 'unknown',
    sqliteJournal: error?.safeDetails?.sqliteJournal || {
      name: 'database-journal',
      present: null,
      length: null,
    },
  };
}

function quotaMigrationSnapshotEvidence(snapshot, targetVaultId, requestPayloadSha256) {
  const counts = snapshot?.counts || {};
  const journal = snapshot?.migrationJournals?.[0];
  const items = snapshot?.migrationItems;
  const payload = snapshot?.migrationCreatePayloads?.[0];
  const sourceRowsValid = counts.local_vault_records === EXPECTED_MIGRATED_RECORDS;
  const journalValid = counts.local_vault_migrations === 1 &&
    snapshot?.migrationStates?.frozen === 1 &&
    snapshot?.migrationJournals?.length === 1 &&
    journal?.status === 'frozen' && journal?.targetVaultId === targetVaultId &&
    journal?.expectedItemCount === EXPECTED_MIGRATED_RECORDS;
  const stagedEnvelopesValid = counts.local_vault_migration_items >= 1 &&
    counts.local_vault_migration_items <= EXPECTED_MIGRATED_RECORDS &&
    Array.isArray(items) && items.length === counts.local_vault_migration_items &&
    items.every((item) => item.migrationId === journal?.migrationId &&
      item.targetVaultId === targetVaultId && item.envelopeValid &&
      /^[0-9a-f]{64}$/.test(item.storedEnvelopeSha256 || '') &&
      item.storedEnvelopeSha256 === item.computedEnvelopeSha256 &&
      /^[0-9a-f]{64}$/.test(item.ciphertextSha256 || ''));
  const createPayloadValid = counts.local_vault_migration_create_payloads === 1 &&
    snapshot?.migrationCreatePayloads?.length === 1 &&
    payload?.migrationId === journal?.migrationId &&
    payload?.targetVaultId === targetVaultId &&
    /^[0-9a-f]{64}$/.test(payload?.storedPayloadSha256 || '') &&
    payload?.storedPayloadSha256 === payload?.computedPayloadSha256 &&
    payload?.storedPayloadSha256 === requestPayloadSha256;
  const plaintextClean = snapshot?.plaintextMarkerFound === false;
  return {
    integrityValid: snapshot?.integrity === 'ok',
    sourceRowsValid,
    journalValid,
    stagedEnvelopesValid,
    createPayloadValid,
    plaintextClean,
    sqliteJournal: snapshot?.sqliteJournal || null,
    allValid: snapshot?.integrity === 'ok' && sourceRowsValid && journalValid &&
      stagedEnvelopesValid && createPayloadValid && plaintextClean,
  };
}

function filesUnder(directory) {
  const files = [];
  const visit = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile()) files.push(absolute);
    }
  };
  visit(directory);
  return files;
}

function inspectDatabase(databasePath, targetVaultId) {
  const python = String.raw`
import hashlib, json, sqlite3, sys
database_path, vault_id = sys.argv[1], sys.argv[2]
markers = json.loads(sys.argv[3])
connection = sqlite3.connect('file:' + database_path + '?mode=ro', uri=True, timeout=5)
connection.row_factory = sqlite3.Row
versions = connection.execute('SELECT record_id,revision_id,envelope,commit_seq,operation FROM record_versions WHERE vault_id=? ORDER BY commit_seq', (vault_id,)).fetchall()
heads = connection.execute('SELECT record_id,revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? ORDER BY record_id', (vault_id,)).fetchall()
events = connection.execute('SELECT record_id,revision_id,event_type,envelope,commit_seq FROM change_events WHERE vault_id=? ORDER BY commit_seq', (vault_id,)).fetchall()
receipts = connection.execute('SELECT op_id,record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? ORDER BY commit_seq', (vault_id,)).fetchall()
counts = {'record_versions': len(versions), 'record_heads': len(heads),
          'change_events': len(events), 'op_receipts': len(receipts)}
vault_count = connection.execute('SELECT COUNT(*) FROM vaults WHERE vault_id=?', (vault_id,)).fetchone()[0]
def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
def digest(value):
    return hashlib.sha256(canonical_json(value).encode('utf-8')).hexdigest()
def valid_envelope(value):
    return (isinstance(value, dict) and set(value) == {'header','nonce','ciphertext','signature'} and
            isinstance(value.get('header'), dict) and isinstance(value.get('nonce'), str) and
            isinstance(value.get('ciphertext'), str) and len(value['ciphertext']) >= 32 and
            isinstance(value.get('signature'), str) and len(value['signature']) >= 32 and
            value['header'].get('vault_id') == vault_id and value['header'].get('operation') == 'create' and
            isinstance(value['header'].get('record_id'), str) and
            isinstance(value['header'].get('op_id'), str) and
            isinstance(value['header'].get('revision_id'), str))
records = []
for row in versions:
    envelope = json.loads(row['envelope'])
    header = envelope.get('header') if isinstance(envelope, dict) else {}
    canonical = canonical_json(envelope)
    records.append({'recordId':row['record_id'], 'revisionId':row['revision_id'],
                    'operation':row['operation'], 'commitSeq':row['commit_seq'],
                    'opId':header.get('op_id') if isinstance(header, dict) else None,
                    'envelopeSha256':hashlib.sha256(canonical.encode('utf-8')).hexdigest(),
                    'envelopeValid':valid_envelope(envelope) and
                        header.get('record_id') == row['record_id'] and
                        header.get('revision_id') == row['revision_id'] and
                        header.get('operation') == row['operation'],
                    'plaintextMarkersAbsent':not any(marker in row['envelope'] for marker in markers)})
head_rows = [{'recordId':r['record_id'], 'revisionId':r['revision_id'],
              'deleted':r['deleted'], 'commitSeq':r['commit_seq']} for r in heads]
event_rows = []
for row in events:
    envelope = json.loads(row['envelope'])
    canonical = canonical_json(envelope)
    event_rows.append({'recordId':row['record_id'], 'revisionId':row['revision_id'],
                       'eventType':row['event_type'], 'commitSeq':row['commit_seq'],
                       'envelopeSha256':hashlib.sha256(canonical.encode('utf-8')).hexdigest()})
receipt_rows = [{'opId':r['op_id'], 'recordId':r['record_id'],
                 'revisionId':r['revision_id'], 'commitSeq':r['commit_seq']} for r in receipts]
version_by_id = {r['recordId']:r for r in records}
heads_by_id = {r['recordId']:r for r in head_rows}
events_by_id = {r['recordId']:r for r in event_rows}
receipts_by_id = {r['recordId']:r for r in receipt_rows}
unique_ids = len(version_by_id) == len(records)
unique_op_ids = len({r['opId'] for r in receipt_rows}) == len(receipt_rows)
heads_consistent = len(heads_by_id) == len(head_rows) == len(records) and all(
    record_id in heads_by_id and heads_by_id[record_id]['revisionId'] == version['revisionId'] and
    heads_by_id[record_id]['deleted'] == 0 and heads_by_id[record_id]['commitSeq'] == version['commitSeq']
    for record_id, version in version_by_id.items())
events_consistent = len(events_by_id) == len(event_rows) == len(records) and all(
    record_id in events_by_id and events_by_id[record_id]['revisionId'] == version['revisionId'] and
    events_by_id[record_id]['eventType'] == 'create' and
    events_by_id[record_id]['commitSeq'] == version['commitSeq'] and
    events_by_id[record_id]['envelopeSha256'] == version['envelopeSha256']
    for record_id, version in version_by_id.items())
receipts_consistent = len(receipts_by_id) == len(receipt_rows) == len(records) and all(
    record_id in receipts_by_id and receipts_by_id[record_id]['revisionId'] == version['revisionId'] and
    receipts_by_id[record_id]['commitSeq'] == version['commitSeq'] and
    receipts_by_id[record_id]['opId'] == version['opId']
    for record_id, version in version_by_id.items())
print(json.dumps({'vault_count':vault_count, **counts, 'records':records,
                  'unique_record_ids':unique_ids, 'unique_op_ids':unique_op_ids,
                  'envelopes_valid':all(item['envelopeValid'] for item in records),
                  'plaintext_markers_absent':all(item['plaintextMarkersAbsent'] for item in records),
                  'heads_consistent':heads_consistent, 'events_consistent':events_consistent,
                  'receipts_consistent':receipts_consistent}, separators=(',',':')))
connection.close()
`;
  const result = spawnSync('python3', [
    '-c', python, databasePath, targetVaultId, JSON.stringify(PLAINTEXT_MARKERS),
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 15000,
    stdio: ['ignore', 'pipe', 'ignore'],
    maxBuffer: 2 * 1024 * 1024,
  });
  assertThat(!result.error && result.status === 0, 'read-only database inspection failed');
  try {
    const value = JSON.parse(result.stdout);
    result.stdout = '';
    return value;
  } catch (_) {
    result.stdout = '';
    throw new Error('read-only database metadata was invalid');
  }
}

function assertServerMatchesStagedSubset(server, stagedItems, targetVaultId, options = {}) {
  const requirePending = options.requirePending !== false;
  const requireIncomplete = options.requireIncomplete !== false;
  const records = server?.records;
  assertThat(server?.vault_count === 1 && Array.isArray(records),
    'target server snapshot is missing its single Vault or version rows');
  assertThat(server.record_versions === records.length && server.record_heads === records.length &&
    server.change_events === records.length && server.op_receipts === records.length,
  'target server version, head, event, and receipt counts do not agree');
  assertThat(server.unique_record_ids && server.unique_op_ids,
    'target server snapshot contains duplicate record or operation IDs');
  assertThat(server.envelopes_valid && server.plaintext_markers_absent,
    'target server snapshot contains an invalid or plaintext-marked envelope');
  assertThat(server.heads_consistent && server.events_consistent && server.receipts_consistent,
    'target server heads, events, or receipts do not match committed versions');
  const stagedByRecordId = new Map();
  for (const item of stagedItems || []) {
    assertThat(item.envelopeValid && item.targetVaultId === targetVaultId &&
      item.recordId && item.canonicalEnvelopeSha256 && item.opId && item.revisionId &&
      !stagedByRecordId.has(item.recordId),
    'durable migration snapshot has an invalid or duplicate staged envelope');
    stagedByRecordId.set(item.recordId, item);
  }
  assertThat(stagedByRecordId.size > 0 && records.length <= EXPECTED_MIGRATED_RECORDS &&
    (!requireIncomplete || records.length < EXPECTED_MIGRATED_RECORDS) &&
    (!requirePending || records.length < stagedByRecordId.size),
  'server record count violated the requested pending or incomplete checkpoint');
  const serverRecordIds = new Set();
  for (const record of records) {
    const staged = stagedByRecordId.get(record.recordId);
    assertThat(!serverRecordIds.has(record.recordId) && staged && record.envelopeValid &&
      record.plaintextMarkersAbsent && record.operation === 'create' &&
      record.revisionId === staged.revisionId && record.opId === staged.opId &&
      record.envelopeSha256 === staged.canonicalEnvelopeSha256,
    'server committed a record that does not exactly match a unique durable staged envelope');
    serverRecordIds.add(record.recordId);
  }
  const fingerprint = crypto.createHash('sha256').update(stableJson({
    counts: {
      record_versions: server.record_versions,
      record_heads: server.record_heads,
      change_events: server.change_events,
      op_receipts: server.op_receipts,
    },
    records: records.map((record) => ({
      recordId: record.recordId,
      revisionId: record.revisionId,
      opId: record.opId,
      envelopeSha256: record.envelopeSha256,
      commitSeq: record.commitSeq,
    })).sort((left, right) => left.recordId.localeCompare(right.recordId)),
  }), 'utf8').digest('hex');
  return { serverRecordCount: records.length, stagedRecordCount: stagedByRecordId.size,
    pendingStagedCount: stagedByRecordId.size - records.length, fingerprint };
}

function safeServerSnapshotSummary(server, stagedItems = []) {
  const summarize = (items, projector) => crypto.createHash('sha256')
    .update(stableJson((items || []).map(projector).sort((left, right) =>
      stableJson(left).localeCompare(stableJson(right)))), 'utf8')
    .digest('hex');
  return {
    vaultCount: server?.vault_count ?? null,
    recordVersions: server?.record_versions ?? null,
    recordHeads: server?.record_heads ?? null,
    changeEvents: server?.change_events ?? null,
    opReceipts: server?.op_receipts ?? null,
    rowCount: Array.isArray(server?.records) ? server.records.length : null,
    uniqueRecordIds: server?.unique_record_ids ?? null,
    uniqueOpIds: server?.unique_op_ids ?? null,
    envelopesValid: server?.envelopes_valid ?? null,
    plaintextMarkersAbsent: server?.plaintext_markers_absent ?? null,
    headsConsistent: server?.heads_consistent ?? null,
    eventsConsistent: server?.events_consistent ?? null,
    receiptsConsistent: server?.receipts_consistent ?? null,
    serverMetadataSha256: summarize(server?.records, (record) => ({
      recordId: record.recordId,
      revisionId: record.revisionId,
      opId: record.opId,
      envelopeSha256: record.envelopeSha256,
      commitSeq: record.commitSeq,
    })),
    stagedCount: Array.isArray(stagedItems) ? stagedItems.length : null,
    stagedMetadataSha256: summarize(stagedItems, (item) => ({
      recordId: item.recordId,
      revisionId: item.revisionId,
      opId: item.opId,
      envelopeSha256: item.canonicalEnvelopeSha256,
    })),
  };
}

function sameServerSnapshot(left, right) {
  const project = (snapshot) => ({
    vault_count: snapshot.vault_count,
    record_versions: snapshot.record_versions,
    record_heads: snapshot.record_heads,
    change_events: snapshot.change_events,
    op_receipts: snapshot.op_receipts,
    records: snapshot.records?.map((record) => ({
      recordId: record.recordId,
      revisionId: record.revisionId,
      opId: record.opId,
      operation: record.operation,
      commitSeq: record.commitSeq,
      envelopeSha256: record.envelopeSha256,
    })).sort((a, b) => a.recordId.localeCompare(b.recordId)),
  });
  return stableJson(project(left)) === stableJson(project(right));
}

function serverSnapshotExtends(previous, current) {
  if (!previous || !current || previous.vault_count !== current.vault_count ||
      !Array.isArray(previous.records) || !Array.isArray(current.records) ||
      current.records.length < previous.records.length) return false;
  const currentByRecordId = new Map(current.records.map((record) => [record.recordId, record]));
  return previous.records.every((record) => {
    const next = currentByRecordId.get(record.recordId);
    return next && next.revisionId === record.revisionId && next.opId === record.opId &&
      next.operation === record.operation && next.commitSeq === record.commitSeq &&
      next.envelopeSha256 === record.envelopeSha256;
  });
}

function targetPushEvents(targetVaultId) {
  const targetPath = `/api/v1/vaults/${targetVaultId}/sync/push`;
  return apiEvents.filter((event) => event.method === 'POST' &&
    event.pathname === targetPath);
}

async function captureStableServerBaseline(databasePath, targetVaultId, readStagedSnapshot,
  assertionOptions = {}) {
  const targetPath = `/api/v1/vaults/${targetVaultId}/sync/push`;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    await waitFor(() => !apiEvents.some((event) => event.method === 'POST' &&
      event.pathname === targetPath && event.status === null && !event.failed), 5000);
    const requestCountBeforeQuiet = targetPushEvents(targetVaultId).length;
    await new Promise((resolve) => setTimeout(resolve, 850));
    const requestCountAfterQuiet = targetPushEvents(targetVaultId).length;
    const hasPending = targetPushEvents(targetVaultId).some((event) =>
      event.status === null && !event.failed);
    if (hasPending || requestCountBeforeQuiet !== requestCountAfterQuiet) continue;
    const first = inspectDatabase(databasePath, targetVaultId);
    await new Promise((resolve) => setTimeout(resolve, 250));
    const second = inspectDatabase(databasePath, targetVaultId);
    const requestCountAfterSnapshots = targetPushEvents(targetVaultId).length;
    if (requestCountAfterSnapshots !== requestCountAfterQuiet ||
        targetPushEvents(targetVaultId).some((event) => event.status === null && !event.failed) ||
        !sameServerSnapshot(first, second)) {
      continue;
    }
    const stagedSnapshot = await readStagedSnapshot();
    if (targetPushEvents(targetVaultId).length !== requestCountAfterSnapshots ||
        targetPushEvents(targetVaultId).some((event) => event.status === null && !event.failed)) {
      continue;
    }
    console.log(`safe stable target subset candidate ${JSON.stringify(
      safeServerSnapshotSummary(second, stagedSnapshot.migrationItems),
    )}`);
    const stagedRows = stagedSnapshot.migrationItems || [];
    const stagedRecordIds = stagedRows.map((item) => item.recordId).filter(Boolean);
    const stagedOpIds = stagedRows.map((item) => item.opId).filter(Boolean);
    console.log(`safe staged envelope field checks ${JSON.stringify({
      stagedCount: stagedRows.length,
      allEnvelopeValid: stagedRows.every((item) => item.envelopeValid === true),
      allTargetIdsMatch: stagedRows.every((item) => item.targetVaultId === targetVaultId),
      allRequiredIdsPresent: stagedRows.every((item) => Boolean(
        item.recordId && item.opId && item.revisionId,
      )),
      allCanonicalHashesPresent: stagedRows.every((item) =>
        /^[0-9a-f]{64}$/.test(item.canonicalEnvelopeSha256 || '')),
      recordIdsUnique: new Set(stagedRecordIds).size === stagedRecordIds.length,
      operationIdsUnique: new Set(stagedOpIds).size === stagedOpIds.length,
    })}`);
    const summary = assertServerMatchesStagedSubset(
      second, stagedSnapshot.migrationItems, targetVaultId, assertionOptions,
    );
    return { snapshot: second, stagedSnapshot, summary,
      targetPushCount: requestCountAfterSnapshots };
  }
  throw new Error('target sync pushes did not drain into a stable server baseline');
}

async function enrollAndApproveSecondDevice(ownerPage, secondPage, destinationVaultId) {
  setStage('request enrollment from independent second device context');
  await field(secondPage, 'Email or username');
  await click(secondPage, 'Add this device');
  await visibleText(secondPage, 'Request this device');
  await fill(secondPage, 'Account email', OWNER_USERNAME);
  await fill(secondPage, 'Device name', SECOND_DEVICE_NAME);
  await click(secondPage, 'Generate request');
  await field(secondPage, 'Copy this enrollment JSON');
  await click(secondPage, 'Copy');
  const enrollmentJson = await readAndClearClipboard(secondPage);
  let enrollmentFormat;
  let requestedDeviceId;
  try {
    const request = JSON.parse(enrollmentJson);
    enrollmentFormat = request.format;
    requestedDeviceId = request.device?.device_id || request.device_id;
  } catch (_) {}
  assertThat(enrollmentFormat === 'atermius-device-enrollment-v1' &&
      typeof requestedDeviceId === 'string' && requestedDeviceId.length > 0 &&
      requestedDeviceId !== ownerDeviceId,
    'second browser context did not produce a distinct signed device enrollment');
  await click(secondPage, 'Close');

  setStage('owner opens trusted devices to approve second device');
  await click(ownerPage, 'Devices');
  setStage('owner opens enrollment review');
  await click(ownerPage, 'Approve enrollment');
  setStage('owner imports public enrollment request');
  await pasteClipboardField(ownerPage, 'Enrollment JSON', enrollmentJson);
  setStage('owner reviews second-device public keys');
  await click(ownerPage, 'Review keys');
  setStage('owner seals destination Vault keys for second device');
  await click(ownerPage, 'Approve & seal keys');
  await button(ownerPage, 'Copy');
  await click(ownerPage, 'Copy');
  const approvalJson = await readAndClearClipboard(ownerPage);
  let approvalFormat;
  let approvedDeviceId;
  try {
    const approval = JSON.parse(approvalJson);
    approvalFormat = approval.format;
    approvedDeviceId = approval.device?.device_id || approval.device_id ||
      approval.recipient_device_id;
  } catch (_) {}
  assertThat(approvalFormat === 'atermius-device-approval-v1' &&
      (approvedDeviceId == null || approvedDeviceId === requestedDeviceId),
    'owner did not produce the matching signed device approval');
  await click(ownerPage, 'Done');
  await click(ownerPage, 'Hosts');

  setStage('second device imports sealed keys and signs in');
  await click(secondPage, 'Import approval');
  await pasteClipboardField(secondPage, 'Paste approval JSON', approvalJson);
  await click(secondPage, 'Import device keys');
  await fill(secondPage, 'Email or username', OWNER_USERNAME);
  await fill(secondPage, 'Master password', OWNER_PASSWORD);
  const loginStart = apiEvents.length;
  await click(secondPage, 'Sign in and unlock');
  await button(secondPage, 'Add host', 60000);
  const loginEvent = await eventFor('login', 'POST', loginStart);
  const loginResult = await loginEvent.responsePromise;
  assertThat(loginEvent.status >= 200 && loginEvent.status < 300 &&
      typeof loginResult?.access_token === 'string' &&
      loginResult.device_id === requestedDeviceId,
    'second device login did not use its separately enrolled identity');
  let secondAccessToken = loginResult.access_token;
  loginResult.access_token = null;
  const secondVaultList = await directApi(
    appOrigin,
    'GET',
    '/api/v1/vaults',
    secondAccessToken,
  );
  secondAccessToken = undefined;
  const secondVaults = secondVaultList.body?.vaults;
  const secondTarget = Array.isArray(secondVaults)
    ? secondVaults.find((vault) => vault.vault_id === destinationVaultId)
    : null;
  const targetVaultIndex = Array.isArray(secondVaults)
    ? secondVaults.findIndex((vault) => vault.vault_id === destinationVaultId)
    : -1;
  assertThat(secondVaultList.status === 200 && Array.isArray(secondVaults) &&
      secondVaults.length === 2 && secondTarget &&
      Array.isArray(secondTarget.key_envelopes) &&
      secondTarget.key_envelopes.some((envelope) =>
        envelope.recipient_device_id === requestedDeviceId),
    'second device did not receive a target Vault descriptor and sealed key envelope');
  console.log(`safe second-device Vault list evidence ${JSON.stringify({
    vaultCount: secondVaults.length,
    targetVaultPosition: targetVaultIndex + 1,
    targetEnvelopeAddressedToNewDevice: true,
  })}`);
  secondVaultList.body = null;

  return { requestedDeviceId, targetVaultIndex };
}

async function selectVaultByName(page, vaultName, vaultId, targetVaultIndex) {
  const fallbackName = `Vault ${vaultId.slice(0, 8)}`;
  secondDeviceTargetDisplayName = vaultName;
  setStage('check whether second device auto-selected the migrated Vault');
  const migratedRecordVisible = await anyVisibleText(page,
    [HOST_NAME, GROUP_NAME, SNIPPET_NAME], 5000);
  if (migratedRecordVisible) {
    secondDeviceTargetHeaderMatches = await vaultHeaderMatches(page,
      [vaultName, fallbackName]);
    reportBoolean('second_device_current_vault_header_matches_target',
      secondDeviceTargetHeaderMatches);
    reportBoolean('second_device_migrated_workspace_auto_selected', true);
    return;
  }

  setStage('open migrated Vault from Settings on independent second device');
  assertThat(Number.isInteger(targetVaultIndex) && targetVaultIndex >= 0,
    'target Vault was missing from the second device descriptor list');
  setStage('open second-device Settings page');
  await click(page, 'Settings');
  setStage('locate Vaults section on second-device Settings page');
  await visibleText(page, 'Vaults', 15000);
  const displayName = await anyVisibleText(page, [vaultName], 3000)
    ? vaultName
    : fallbackName;
  secondDeviceTargetDisplayName = displayName;
  setStage('confirm destination Vault tile on second-device Settings page');
  await visibleText(page, displayName, 15000);

  // _loadVaults preserves the server descriptor order and initially selects
  // its first entry. Settings renders the remaining Open Vault controls in
  // that same order, omitting the current Vault's disabled action.
  let openVaultButtonIndex = null;
  if (targetVaultIndex > 0) {
    openVaultButtonIndex = targetVaultIndex - 1;
    setStage('open destination Vault from its Settings tile');
    const openVault = page.getByRole('button', { name: 'Open Vault', exact: true })
      .nth(openVaultButtonIndex);
    await openVault.waitFor({ state: 'visible', timeout: 15000 });
    await openVault.click();
  }
  console.log(`safe second-device Settings tile action ${JSON.stringify({
    targetVaultPosition: targetVaultIndex + 1,
    openVaultButtonIndex,
    targetAlreadyCurrent: targetVaultIndex === 0,
  })}`);
  if (targetVaultIndex === 0) {
    secondDeviceTargetHeaderMatches = await vaultHeaderMatches(page, [displayName]);
  } else {
    secondDeviceTargetHeaderMatches = false;
    await waitFor(async () => {
      secondDeviceTargetHeaderMatches = await vaultHeaderMatches(page, [displayName]);
      return secondDeviceTargetHeaderMatches;
    }, 15000);
  }
  const currentVaultHeaderMatchesTarget = secondDeviceTargetHeaderMatches;
  reportBoolean('second_device_current_vault_header_matches_target',
    currentVaultHeaderMatchesTarget);
  setStage('confirm destination Vault selection before second-device sync');
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  let page;
  let secondPage;
  let localDatabaseName;
  let targetVaultId;
  try {
    setStage('build isolated server');
    buildServer();

    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-local-migration-'));
    fs.chmodSync(tempRoot, 0o700);
    snippetDiagnosticRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), 'atermius-migration-snippet-diagnostic-'),
    );
    fs.chmodSync(snippetDiagnosticRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const databasePath = path.join(dataDir, 'atermius.db');
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

    setStage('start disposable loopback server');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliCredential(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated Chromium and create local-only source data');
    appOrigin = baseUrl;
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({ locale: 'zh-CN', viewport: { width: 1440, height: 1000 } });
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: appOrigin });
    page = await context.newPage();
    trackApi(page);
    page.on('pageerror', () => pageErrors.push('page-error'));
    await page.goto(appOrigin, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    setStage('wait for workspace chooser before local source setup');
    await visibleText(page, 'Choose a workspace');
    quotaSession = await context.newCDPSession(page);
    await quotaSession.send('Storage.overrideQuotaForOrigin', {
      origin: appOrigin,
      quotaSize: MIGRATION_QUOTA_LIMIT_BYTES,
    });
    setStage('open local-only profile flow');
    await click(page, 'Open locally');
    await visibleText(page, '还没有本地配置');
    await fill(page, '主密码', LOCAL_PASSWORD);
    await click(page, '创建并解锁');
    await visibleText(page, '还没有 Host', 90000);

    setStage('seed local group');
    await click(page, '分组');
    await visibleText(page, '还没有分组');
    await click(page, '添加分组');
    await fill(page, '分组名称', GROUP_NAME);
    await click(page, '保存分组');
    await visibleText(page, GROUP_NAME);

    setStage('seed local Host');
    await click(page, 'Host');
    await click(page, '添加 Host');
    await fill(page, '名称', HOST_NAME);
    await fill(page, '主机名或 IP', HOST_ADDRESS);
    await fill(page, 'SSH 用户名', HOST_USERNAME);
    await tapSemanticTextContaining(page, '不属于分组');
    await selectVisibleMenuItem(page, GROUP_NAME);
    await click(page, '保存加密 Host');
    await visibleText(page, HOST_NAME);

    setStage('seed local Credential');
    await click(page, '凭据');
    await visibleText(page, '还没有凭据');
    await click(page, '添加凭据');
    await fill(page, '凭据名称', CREDENTIAL_NAME);
    await fill(page, '用户名', CREDENTIAL_USERNAME);
    await fill(page, '密码', CREDENTIAL_SECRET);
    await click(page, '保存加密凭据');
    await visibleText(page, CREDENTIAL_NAME);

    setStage('seed local Snippet');
    await click(page, '片段');
    await visibleText(page, '还没有片段');
    await click(page, '添加片段');
    await fill(page, '片段标题', SNIPPET_NAME);
    await fill(page, '脚本正文', SNIPPET_BODY);
    await fill(page, '标签（逗号分隔）', 'migration, encrypted');
    await click(page, '保存加密片段');
    await visibleText(page, SNIPPET_NAME);

    setStage('open local preference settings');
    await click(page, '偏好设置');
    setStage('wait for local default section preference control');
    await visibleText(page, '默认工作区');
    setStage('select local default section preference');
    await tapPreferenceDropdown(page, '默认工作区');
    setStage('choose Snippets for local default section preference');
    await selectVisibleMenuItem(page, '片段');
    setStage('save local default section preference');
    await click(page, '保存默认工作区');
    setStage('confirm local default section preference save');
    await visibleText(page, '偏好已保存并应用。');
    await visibleText(page, '命令片段');
    setStage('reopen local preference settings for terminal tuples');
    await click(page, '偏好设置');
    await visibleText(page, '终端字号');
    setStage('seed the three supported terminal preference tuples');
    await tapPreferenceDropdown(page, '终端字体大小');
    await selectVisibleMenuItem(page, '16 px');
    await click(page, '保存终端字号');
    await visibleText(page, '偏好已加密保存在此本地配置中。');
    await tapPreferenceDropdown(page, '终端配色');
    await selectVisibleMenuItem(page, 'Light');
    await click(page, '保存终端主题');
    await visibleText(page, '偏好已加密保存在此本地配置中。');
    await fill(page, '搜索终端历史', 'mod+alt+shift+x');
    await fill(page, '下一个匹配项', 'mod+alt+y');
    await fill(page, '上一个匹配项', 'mod+alt+shift+y');
    await fill(page, '断开当前终端', 'mod+alt+shift+z');
    await click(page, '保存快捷键');
    await visibleText(page, '偏好已加密保存在此本地配置中。');
    reportBoolean('local_source_seeded_four_allowlisted_all_platform_preference_tuples', true);
    assertThat(apiEvents.length === 0, 'LocalVault source creation contacted a server API');
    const localCatalog = await page.evaluate(async () => {
      const databases = typeof indexedDB.databases === 'function'
        ? await indexedDB.databases()
        : [];
      return databases.map((database) => database.name).filter(Boolean);
    });
    localDatabaseName = localCatalog.find((name) => name.startsWith('atermius_local_vault_'));
    assertThat(localDatabaseName && localCatalog.includes('atermius_profile_catalog'),
      'encrypted local source profile was not persisted in this browser');
    const seededSource = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-seeded-source',
    );
    assertThat(seededSource.integrity === 'ok' &&
      seededSource.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      seededSource.counts.local_vault_migrations === 0 &&
      seededSource.counts.local_vault_migration_items === 0 &&
      seededSource.counts.local_vault_migration_create_payloads === 0 &&
      !seededSource.plaintextMarkerFound,
    'the LocalVault source did not durably seed four supported preferences as encrypted rows');
    reportBoolean('local_source_created_without_api_requests', true);
    reportBoolean('local_source_contains_eight_encrypted_records_including_four_supported_preferences', true);

    setStage('register and sign in to the server workspace');
    await click(page, '退出本地配置');
    await visibleText(page, 'Choose a workspace');
    setStage('configure server connection form');
    await click(page, 'Continue');
    await fill(page, 'Server URL', baseUrl);
    await click(page, 'Connect securely');
    setStage('load first-account registration form');
    await fill(page, 'Owner email', OWNER_USERNAME);
    await fill(page, 'Master password · 12+ characters', OWNER_PASSWORD);
    await fill(page, 'Confirm master password', OWNER_PASSWORD);
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    await fill(page, 'Device name', 'Local migration browser');
    await fill(page, 'First Vault', 'Local migration account');
    bootstrapToken = undefined;
    const registrationEventStart = apiEvents.length;
    setStage('submit first-account registration');
    await click(page, 'Create owner account');
    await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 60000 });
    const registration = await eventFor('register', 'POST', registrationEventStart);
    assertThat(registration.status >= 200 && registration.status < 300 && registration.hasBearer === false,
      'first-account registration request did not complete');
    const registeredAccount = await registration.responsePromise;
    assertThat(typeof registeredAccount?.access_token === 'string' &&
        typeof registeredAccount?.account_id === 'string' && typeof registeredAccount?.device_id === 'string',
      'registered server profile response was incomplete');
    ownerAccessToken = registeredAccount.access_token;
    ownerDeviceId = registeredAccount.device_id;
    ownerDeviceId = registeredAccount.device_id;
    reportBoolean('authenticated_server_workspace_opened', true);

    setStage('open LocalVault migration from authenticated server settings');
    await click(page, 'Settings');
    await visibleText(page, 'Review local profile migration');
    await click(page, 'Review local profile migration');
    await visibleText(page, 'Move local encrypted records to a new sync Vault');
    await fill(page, 'Local profile password', LOCAL_PASSWORD);
    await click(page, 'Unlock and validate');
    await visibleText(page, 'Local profile unlocked');

    const originUsageBeforeQuotaProbe = await readOriginStorageEstimate(page, 1000);
    console.log(`safe origin storage before quota probe ${JSON.stringify(originUsageBeforeQuotaProbe)}`);
    setStage('prove origin quota exhaustion with a disposable probe database');
    const quotaProbe = await fillOriginToQuota(page);
    console.log(`safe local migration quota probe ${JSON.stringify(quotaProbe)}`);
    assertThat(quotaProbe.quotaError === 'QuotaExceededError' ||
      quotaProbe.openError === 'QuotaExceededError',
    `IndexedDB quota was not exhausted before migration: ${JSON.stringify(quotaProbe)}`);
    setStage('reset the disposable quota database and measure the reset baseline');
    const quotaProbeReset = await deleteMigrationQuotaProbe(page);
    assertThat(quotaProbeReset.deleted && !quotaProbeReset.databasePresent,
      `quota probe database was not deleted before refill: ${JSON.stringify(quotaProbeReset)}`);
    const resetBaseline = await readOriginStorageEstimate(page, 4000);
    const quotaOverrideBeforeRefill = await quotaSession.send(
      'Storage.getUsageAndQuota', { origin: appOrigin },
    );
    assertThat(resetBaseline.stable && Number.isSafeInteger(resetBaseline.usage) &&
      Number.isSafeInteger(resetBaseline.quota),
    `origin storage reset baseline did not stabilize within the bounded wait: ${JSON.stringify({
      resetBaseline,
      sourceBeforeProbe: originUsageBeforeQuotaProbe,
    })}`);
    const requestedRefillReserve = MIGRATION_QUOTA_HEADROOM_BYTES +
      MIGRATION_QUOTA_ESTIMATE_SAFETY_BYTES;
    const refillQuotaWindow = MIGRATION_QUOTA_CAP_WINDOW_BYTES;
    const desiredQuotaCap = resetBaseline.usage + refillQuotaWindow;
    let quotaCapRaised = false;
    if (resetBaseline.quota < desiredQuotaCap) {
      await quotaSession.send('Storage.overrideQuotaForOrigin', {
        origin: appOrigin,
        quotaSize: desiredQuotaCap,
      });
      quotaCapRaised = true;
    }
    const baselineAfterQuotaCap = await readOriginStorageEstimate(page, 2000);
    const quotaOverrideAfterRefillCap = await quotaSession.send(
      'Storage.getUsageAndQuota', { origin: appOrigin },
    );
    const quotaProbeRefill = await fillOriginToHeadroom(
      page, requestedRefillReserve,
    );
    console.log(`safe migration quota probe reset/refill ${JSON.stringify({
      reset: quotaProbeReset,
      sourceBeforeProbeUsage: originUsageBeforeQuotaProbe.usage,
      baselineUsage: quotaProbeRefill.baselineUsage,
      resetBaselineUsage: resetBaseline.usage,
      resetBaselineQuota: resetBaseline.quota,
      resetBaselineStable: resetBaseline.stable,
      resetBaselineSamples: resetBaseline.samples,
      quotaOverrideBefore: {
        usage: quotaOverrideBeforeRefill.usage,
        quota: quotaOverrideBeforeRefill.quota,
        overrideActive: quotaOverrideBeforeRefill.overrideActive,
      },
      quotaCapRaised,
      desiredQuotaCap,
      quotaOverrideAfter: {
        usage: quotaOverrideAfterRefillCap.usage,
        quota: quotaOverrideAfterRefillCap.quota,
        overrideActive: quotaOverrideAfterRefillCap.overrideActive,
      },
      afterCapEstimate: baselineAfterQuotaCap,
      quota: quotaProbeRefill.quota,
      requestedHeadroomBytes: quotaProbeRefill.requestedHeadroomBytes,
      safetyMarginBytes: MIGRATION_QUOTA_ESTIMATE_SAFETY_BYTES,
      successfulWrites: quotaProbeRefill.successfulWrites,
      writtenBytes: quotaProbeRefill.writtenBytes,
      finalUsage: quotaProbeRefill.finalUsage,
      finalQuota: quotaProbeRefill.finalQuota,
      actualReserveBytes: quotaProbeRefill.actualReserveBytes,
      probeDatabasePresent: quotaProbeRefill.probeDatabasePresent,
      error: quotaProbeRefill.error || null,
    })}`);
    assertThat(!quotaProbeRefill.error && quotaProbeRefill.probeDatabasePresent &&
      quotaProbeRefill.successfulWrites > 0 &&
      Number.isSafeInteger(quotaProbeRefill.actualReserveBytes) &&
      quotaProbeRefill.actualReserveBytes >= MIGRATION_QUOTA_HEADROOM_BYTES &&
      quotaProbeRefill.actualReserveBytes <=
        requestedRefillReserve + MIGRATION_QUOTA_ESTIMATE_SAFETY_BYTES,
    `quota probe refill did not leave the required measured headroom: ${JSON.stringify({
      baselineUsage: quotaProbeRefill.baselineUsage,
      quota: quotaProbeRefill.quota,
      writtenBytes: quotaProbeRefill.writtenBytes,
      finalUsage: quotaProbeRefill.finalUsage,
      finalQuota: quotaProbeRefill.finalQuota,
      actualReserveBytes: quotaProbeRefill.actualReserveBytes,
      error: quotaProbeRefill.error || null,
    })}`);
    const vaultsBeforeQuotaAttempt = await directApi(baseUrl, 'GET', '/api/v1/vaults', ownerAccessToken);
    assertThat(vaultsBeforeQuotaAttempt.status === 200 &&
      Array.isArray(vaultsBeforeQuotaAttempt.body?.vaults),
    'could not capture the server Vault baseline before local migration quota injection');
    const vaultIdsBeforeQuotaAttempt = vaultsBeforeQuotaAttempt.body.vaults
      .map((vault) => vault.vault_id).sort();

    setStage('set the exact destination name before the quota migration attempt');
    await fill(page, 'New sync Vault name', TARGET_VAULT_NAME);
    const quotaMigrationStart = apiEvents.length;
    const interruptedPushStart = quotaMigrationStart;
    let firstTargetPushRouteSeen = false;
    let blockedTargetRetryCount = 0;
    let allowTargetMigrationRetry = false;
    await page.route('**/api/v1/vaults/*/sync/push', async (route) => {
      const request = route.request();
      const pathname = new URL(request.url()).pathname;
      const createdTargetId = migrationCreatePayload?.vault_id;
      const createdTargetPushPath = createdTargetId
        ? `/api/v1/vaults/${createdTargetId}/sync/push`
        : null;
      if (!firstTargetPushRouteSeen && request.method() === 'POST' &&
          createdTargetPushPath && pathname === createdTargetPushPath) {
        firstTargetPushRouteSeen = true;
        const before503 = inspectDatabase(databasePath, createdTargetId);
        rejectedMigrationPushes += 1;
        failedPushes += 1;
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: {
            code: 'TEMPORARY_UNAVAILABLE', message: 'temporarily unavailable',
          } }),
        });
        const after503 = inspectDatabase(databasePath, createdTargetId);
        firstMigrationPush503Evidence = {
          targetVaultId: createdTargetId,
          before: before503,
          after: after503,
          unchanged: sameServerSnapshot(before503, after503),
        };
        console.log(`safe immediate target 503 snapshot ${JSON.stringify({
          before: safeServerSnapshotSummary(before503),
          after: safeServerSnapshotSummary(after503),
          unchanged: firstMigrationPush503Evidence.unchanged,
        })}`);
        assertThat(firstMigrationPush503Evidence.unchanged,
          'the single intercepted initial target 503 changed server state');
        return;
      }
      if (request.method() === 'POST' && createdTargetPushPath &&
          pathname === createdTargetPushPath && !allowTargetMigrationRetry) {
        blockedTargetRetryCount += 1;
        await route.abort('failed');
        return;
      }
      await route.continue();
    });
    setStage('exhausted source quota leaves a durable recoverable migration stage');
    await click(page, 'Preflight and migrate');
    setStage('wait for the one durable destination Vault create after quota staging');
    await waitFor(() => apiEvents.slice(quotaMigrationStart).some((event) =>
      event.route === 'vaults' && event.method === 'POST' && event.status !== null), 30000);
    const readQuotaRecoveryUi = () => page.evaluate(() => {
      const semanticText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const text = `${document.body.innerText || ''}\n${semanticText}`;
      return {
        storageQuarantine: text.includes('本地存储写入中断') && text.includes('重新加载页面'),
        journalRecovery: text.includes('Migration needs recovery') &&
          text.includes('Continue migration'),
      };
    });
    setStage('classify the quota recovery UI while requiring a durable journal checkpoint');
    await waitFor(async () => {
      const state = await readQuotaRecoveryUi();
      return state.storageQuarantine || state.journalRecovery;
    }, 30000);
    const quotaRecoveryUi = await readQuotaRecoveryUi();
    const storageQuarantineRequired = quotaRecoveryUi.storageQuarantine;
    assertThat(storageQuarantineRequired || quotaRecoveryUi.journalRecovery,
      'quota failure did not reach a recognized recovery state');
    if (storageQuarantineRequired) {
      await button(page, '重新加载页面');
    }
    setStage('record safe migration checkpoint invariants before reserve confirmation');
    const quotaUiTargetId = migrationCreatePayload?.vault_id;
    let quotaUiSnapshot = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-at-quota-ui-checkpoint',
    );
    const quotaUiPushCount = targetPushEvents(quotaUiTargetId || '').length;
    const quotaUiStagedCount = quotaUiSnapshot.counts.local_vault_migration_items;
    const quotaUiJournal = quotaUiSnapshot.migrationJournals?.[0];
    const quotaUiCheckpoint = {
      integrity: quotaUiSnapshot.integrity,
      recordCount: quotaUiSnapshot.counts.local_vault_records,
      journalCount: quotaUiSnapshot.counts.local_vault_migrations,
      journalStatus: quotaUiJournal?.status || null,
      stagedCount: quotaUiStagedCount,
      expectedItemCount: quotaUiJournal?.expectedItemCount ?? null,
      journalTargetMatchesCreatedTarget: quotaUiJournal?.targetVaultId === quotaUiTargetId,
      createPayloadCount: quotaUiSnapshot.counts.local_vault_migration_create_payloads,
      plaintextMarkerFound: quotaUiSnapshot.plaintextMarkerFound,
      pushCount: quotaUiPushCount,
      uiCategory: storageQuarantineRequired ? 'storage-quarantine' : 'journal-recovery',
    };
    console.log(`safe LocalVault quota UI checkpoint ${JSON.stringify(quotaUiCheckpoint)}`);
    assertThat(quotaUiSnapshot.integrity === 'ok' &&
      quotaUiSnapshot.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      quotaUiSnapshot.counts.local_vault_migrations === 1 &&
      quotaUiJournal?.status === 'frozen' &&
      quotaUiStagedCount >= 1 && quotaUiStagedCount <= EXPECTED_MIGRATED_RECORDS &&
      quotaUiJournal.expectedItemCount === EXPECTED_MIGRATED_RECORDS &&
      quotaUiJournal.targetVaultId === quotaUiTargetId &&
      quotaUiSnapshot.counts.local_vault_migration_create_payloads === 1 &&
      !quotaUiSnapshot.plaintextMarkerFound,
    'quota recovery UI did not have one frozen 1..8 item LocalVault checkpoint');
    setStage('confirm migration stopped with origin storage still at real quota');
    const quotaAfterMigration = await confirmOriginQuotaExceeded(page);
    console.log(`safe origin quota confirmation after migration ${JSON.stringify(quotaAfterMigration)}`);
    let postMigrationQuotaFill = null;
    if (quotaAfterMigration.quotaError !== 'QuotaExceededError') {
      setStage('fill only the disposable quota probe until the post-migration origin returns a quota error');
      postMigrationQuotaFill = await fillOriginToQuota(page);
      console.log(`safe post-migration disposable quota fill ${JSON.stringify(postMigrationQuotaFill)}`);
    }
    assertThat((quotaAfterMigration.quotaError === 'QuotaExceededError' &&
      quotaAfterMigration.writeSucceeded === false) ||
      postMigrationQuotaFill?.quotaError === 'QuotaExceededError',
    'the migration recovery checkpoint was not accompanied by a real origin QuotaExceededError');
    setStage('verify quota attempt created one target and inspect durable push outcomes');
    const apiAfterQuotaAttempt = apiEvents.slice(quotaMigrationStart);
    const quotaAttemptVaultCreates = apiAfterQuotaAttempt.filter((event) =>
      event.route === 'vaults' && event.method === 'POST');
    const quotaAttemptPushes = apiAfterQuotaAttempt.filter((event) =>
      event.method === 'POST' && event.pathname ===
        `/api/v1/vaults/${quotaUiTargetId}/sync/push`);
    assertThat(quotaAttemptVaultCreates.length === 1 &&
      quotaAttemptVaultCreates[0].status >= 200 && quotaAttemptVaultCreates[0].status < 300 &&
      typeof quotaAttemptVaultCreates[0].vaultId === 'string' &&
      !vaultIdsBeforeQuotaAttempt.includes(quotaAttemptVaultCreates[0].vaultId) &&
      quotaAttemptVaultCreates[0].vaultId === quotaUiTargetId,
    'quota recovery did not create exactly one new destination Vault');
    targetVaultId = quotaAttemptVaultCreates[0].vaultId;
    console.log(`safe browser API requests during quota migration attempt ${JSON.stringify(
      apiAfterQuotaAttempt.map((event) => ({
        route: event.route,
        method: event.method,
        status: event.status,
        pathname: event.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/g, '{id}'),
      })),
    )}`);
    setStage('wait for quota-stage target pushes to finish before reading server state');
    assertThat(quotaAttemptPushes.every((event) => event.status !== null || event.failed),
      'a quota-stage target push remained unresolved at the migration checkpoint');
    setStage('capture the exact durable target Vault create payload');
    const quotaCreatePayload = migrationCreatePayload &&
      JSON.parse(stableJson(migrationCreatePayload));
    assertThat(quotaCreatePayload && quotaCreatePayload.vault_id === targetVaultId,
      'the single target creation request did not carry its exact Vault identifier');
    const quotaPayloadSha256 = crypto.createHash('sha256')
      .update(stableJson(quotaCreatePayload), 'utf8').digest('hex');
    setStage('assert quota-stage requests contain no local plaintext marker');
    assertThat(!apiAfterQuotaAttempt.some((event) => event.markerLeakInRequest),
      'a local plaintext marker appeared in a quota-stage migration request');
    const vaultsAfterQuotaAttempt = await directApi(baseUrl, 'GET', '/api/v1/vaults', ownerAccessToken);
    assertThat(vaultsAfterQuotaAttempt.status === 200 &&
      vaultsAfterQuotaAttempt.body.vaults.length === vaultIdsBeforeQuotaAttempt.length + 1 &&
      vaultsAfterQuotaAttempt.body.vaults.filter((vault) => vault.vault_id === targetVaultId).length === 1,
    'quota-stage target was not durably listed exactly once');

    setStage('drain target pushes and capture a stable server subset baseline');
    const stableQuotaBaseline = await captureStableServerBaseline(
      databasePath,
      targetVaultId,
      () => localVaultSqliteCounts(page, localDatabaseName,
        'local-migration-stable-quota-checkpoint'),
      { requirePending: false, requireIncomplete: false },
    );
    quotaUiSnapshot = stableQuotaBaseline.stagedSnapshot;
    const quotaServerBaseline = stableQuotaBaseline.snapshot;
    console.log(`safe stable quota-stage server baseline ${JSON.stringify({
      recordCount: stableQuotaBaseline.summary.serverRecordCount,
      stagedCount: stableQuotaBaseline.summary.stagedRecordCount,
      pendingStagedCount: stableQuotaBaseline.summary.pendingStagedCount,
      targetPushCount: stableQuotaBaseline.targetPushCount,
      digest: stableQuotaBaseline.summary.fingerprint,
    })}`);

    const expectedTargetPushPath = `/api/v1/vaults/${targetVaultId}/sync/push`;

    setStage('release quota and reload the same source profile');
    await quotaSession.send('Storage.overrideQuotaForOrigin', { origin: appOrigin });
    const quotaProbeReleased = await deleteMigrationQuotaProbe(page);
    console.log(`safe migration quota probe released ${JSON.stringify(quotaProbeReleased)}`);
    assertThat(quotaProbeReleased.deleted && !quotaProbeReleased.databasePresent,
      `temporary quota probe database remained after quota release: ${JSON.stringify(quotaProbeReleased)}`);
    const restoredQuota = await quotaSession.send('Storage.getUsageAndQuota', { origin: appOrigin });
    assertThat(restoredQuota.overrideActive === false,
      'migration Chromium quota override remained active during recovery');
    let sourceBeforeQuotaReload = null;
    let sourceBeforeQuotaReloadError = null;
    try {
      setStage('read LocalVault state after quota release and before page reload');
      sourceBeforeQuotaReload = await localVaultSqliteCounts(
        page, localDatabaseName, 'local-migration-before-quota-reload',
      );
    } catch (error) {
      sourceBeforeQuotaReloadError = safeSnapshotErrorEvidence(error);
    }
    console.log(`safe LocalVault pre-reload snapshot availability ${JSON.stringify({
      readable: sourceBeforeQuotaReload != null,
      error: sourceBeforeQuotaReloadError,
      sqliteJournal: sourceBeforeQuotaReload?.sqliteJournal || null,
      quotaOverrideActive: restoredQuota.overrideActive,
    })}`);
    setStage('require a complete LocalVault digest baseline before same-profile reload');
    assertThat(sourceBeforeQuotaReload != null,
      'quota-stage LocalVault snapshot was unavailable before reload; digest comparison is inconclusive');
    const preReloadQuotaEvidence = quotaMigrationSnapshotEvidence(
      sourceBeforeQuotaReload,
      targetVaultId,
      quotaPayloadSha256,
    );
    console.log(`safe quota LocalVault pre-reload metadata summary ${JSON.stringify({
      integrity: sourceBeforeQuotaReload.integrity,
      counts: sourceBeforeQuotaReload.counts,
      migrationStates: sourceBeforeQuotaReload.migrationStates,
      ...preReloadQuotaEvidence,
    })}`);
    assertThat(preReloadQuotaEvidence.allValid,
      'pre-reload source snapshot did not prove the exact frozen target, durable payload, and staged ciphertext');
    const quotaReload = page.waitForNavigation({
      waitUntil: 'domcontentloaded', timeout: 20000,
    });
    if (storageQuarantineRequired) {
      await click(page, '重新加载页面');
    } else {
      await page.reload({ waitUntil: 'domcontentloaded' });
    }
    await quotaReload;
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace', 60000);

    setStage('inspect source LocalVault and migration journal after same-profile reload');
    let sourceAfterQuotaReload = null;
    let sourceAfterQuotaReloadError = null;
    try {
      sourceAfterQuotaReload = await localVaultSqliteCounts(
        page, localDatabaseName, 'local-migration-after-quota-reload',
      );
    } catch (error) {
      sourceAfterQuotaReloadError = safeSnapshotErrorEvidence(error);
    }
    console.log(`safe LocalVault post-reload snapshot availability ${JSON.stringify({
      readable: sourceAfterQuotaReload != null,
      error: sourceAfterQuotaReloadError,
      sqliteJournal: sourceAfterQuotaReload?.sqliteJournal || null,
      chooserVisible: await visibleTextEvidence(page, 'Choose a workspace', 1000),
    })}`);
    let diagnosticLocalUnlockReached = false;
    let postUnlockSnapshotError = null;
    if (!sourceAfterQuotaReload) {
      setStage('unlock the existing LocalVault profile to distinguish VFS snapshot from profile recovery');
      await click(page, 'Open locally');
      await visibleText(page, '选择配置解锁');
      await tapSemanticTextContaining(page, '本地配置 · ');
      await fill(page, '本地配置主密码', LOCAL_PASSWORD);
      await click(page, '解锁本地配置');
      diagnosticLocalUnlockReached = await anyVisibleText(
        page, [HOST_NAME, GROUP_NAME, SNIPPET_NAME], 60000,
      );
      if (diagnosticLocalUnlockReached) {
        try {
          sourceAfterQuotaReload = await localVaultSqliteCounts(
            page, localDatabaseName, 'local-migration-after-local-unlock',
          );
          postUnlockSnapshotError = null;
        } catch (error) {
          postUnlockSnapshotError = safeSnapshotErrorEvidence(error);
        }
      } else {
        postUnlockSnapshotError = 'local-profile-unlock-did-not-render-seeded-record';
      }
      console.log(`safe LocalVault unlock snapshot diagnostic ${JSON.stringify({
        localProfileUnlockReached: diagnosticLocalUnlockReached,
        readableAfterUnlock: sourceAfterQuotaReload != null,
        postUnlockSnapshotErrorCategory: postUnlockSnapshotError,
      })}`);
      if (!diagnosticLocalUnlockReached) {
        throw new Error('LocalVault profile did not unlock to a seeded workspace after quota recovery');
      }
      await click(page, '退出本地配置');
      await visibleText(page, 'Choose a workspace', 30000);
    }
    if (!sourceAfterQuotaReload) {
      reportBoolean('localvault_sqlite_snapshot_unavailable_after_reload_and_unlock', true);
    }
    let quotaFailureSourceSnapshot = null;
    let quotaFailureJournal = null;
    let quotaFailureItems = null;
    let quotaFailurePayloads = null;
    let quotaJournal = null;
    let quotaPayload = null;
    let pre503ServerBaseline = null;
    if (sourceAfterQuotaReload) {
    assertThat(sourceAfterQuotaReload.integrity === 'ok' &&
      sourceAfterQuotaReload.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      sourceAfterQuotaReload.counts.local_vault_migrations === 1 &&
      sourceAfterQuotaReload.counts.local_vault_migration_items >= 1 &&
      sourceAfterQuotaReload.counts.local_vault_migration_items <= EXPECTED_MIGRATED_RECORDS &&
      sourceAfterQuotaReload.counts.local_vault_migration_create_payloads === 1 &&
      sourceAfterQuotaReload.migrationStates.frozen === 1 &&
      !sourceAfterQuotaReload.plaintextMarkerFound,
    'same-profile reload did not restore eight source rows and one valid partial frozen migration');
    quotaFailureSourceSnapshot = sourceAfterQuotaReload;
    quotaFailureJournal = sourceAfterQuotaReload.migrationJournals;
    quotaFailureItems = sourceAfterQuotaReload.migrationItems;
    quotaFailurePayloads = sourceAfterQuotaReload.migrationCreatePayloads;
    quotaJournal = quotaFailureJournal?.[0];
    quotaPayload = quotaFailurePayloads?.[0];
    const quotaFailureEvidence = {
      integrity: sourceAfterQuotaReload.integrity,
      counts: sourceAfterQuotaReload.counts,
      migrationStates: sourceAfterQuotaReload.migrationStates,
      journalCount: quotaFailureJournal?.length ?? 0,
      journalFrozen: quotaJournal?.status === 'frozen',
      journalTargetMatchesCreatedVault: quotaJournal?.targetVaultId === targetVaultId,
      expectedItemCount: quotaJournal?.expectedItemCount ?? null,
      stagedEnvelopeCount: quotaFailureItems?.length ?? 0,
      stagedEnvelopeDigestsValid: Array.isArray(quotaFailureItems) &&
        quotaFailureItems.every((item) => item.envelopeValid &&
          item.targetVaultId === targetVaultId &&
          item.storedEnvelopeSha256 === item.computedEnvelopeSha256 &&
          /^[0-9a-f]{64}$/.test(item.ciphertextSha256 || '')),
      createPayloadCount: quotaFailurePayloads?.length ?? 0,
      createPayloadMatchesRequest: Boolean(quotaPayload && quotaPayload.storedPayloadSha256 ===
        quotaPayloadSha256),
      plaintextMarkerFound: sourceAfterQuotaReload.plaintextMarkerFound,
    };
    console.log(`safe quota LocalVault metadata summary ${JSON.stringify(quotaFailureEvidence)}`);
    setStage('assert source rows and frozen migration journal after reload');
    assertThat(sourceAfterQuotaReload.counts.local_vault_migrations === 1 &&
      sourceAfterQuotaReload.counts.local_vault_migration_items >= 1 &&
      sourceAfterQuotaReload.counts.local_vault_migration_items <= EXPECTED_MIGRATED_RECORDS &&
      quotaFailureJournal.length === 1 && quotaJournal.status === 'frozen' &&
      quotaJournal.targetVaultId === targetVaultId &&
      quotaJournal.expectedItemCount === EXPECTED_MIGRATED_RECORDS &&
      quotaFailureItems.length === sourceAfterQuotaReload.counts.local_vault_migration_items,
    'quota recovery did not persist exactly one frozen partial journal for the created target');
    setStage('assert staged migration envelopes are durable ciphertext after reload');
    assertThat(quotaFailureItems.every((item) => item.migrationId === quotaJournal.migrationId &&
        item.targetVaultId === targetVaultId && item.envelopeValid &&
        /^[0-9a-f]{64}$/.test(item.storedEnvelopeSha256 || '') &&
        item.storedEnvelopeSha256 === item.computedEnvelopeSha256 &&
        /^[0-9a-f]{64}$/.test(item.ciphertextSha256 || '')),
    'quota recovery did not persist valid opaque staged target envelopes');
    setStage('assert durable create payload matches the one target POST after reload');
    assertThat(quotaFailurePayloads.length === 1 &&
      quotaPayload.migrationId === quotaJournal.migrationId &&
      quotaPayload.targetVaultId === targetVaultId &&
      /^[0-9a-f]{64}$/.test(quotaPayload.storedPayloadSha256 || '') &&
      quotaPayload.storedPayloadSha256 === quotaPayload.computedPayloadSha256 &&
      quotaPayload.storedPayloadSha256 === quotaPayloadSha256,
    'quota recovery did not persist the exact durable Vault creation payload');
    if (sourceBeforeQuotaReload) {
      setStage('compare every staged ciphertext digest across same-profile reload');
      assertThat(JSON.stringify(sourceAfterQuotaReload.migrationJournals) ===
          JSON.stringify(sourceBeforeQuotaReload.migrationJournals) &&
        JSON.stringify(sourceAfterQuotaReload.migrationCreatePayloads) ===
          JSON.stringify(sourceBeforeQuotaReload.migrationCreatePayloads) &&
        JSON.stringify(sourceAfterQuotaReload.migrationItems.map((item) => ({
          migrationId: item.migrationId,
          recordId: item.recordId,
          ciphertextSha256: item.ciphertextSha256,
          storedEnvelopeSha256: item.storedEnvelopeSha256,
          computedEnvelopeSha256: item.computedEnvelopeSha256,
          targetVaultId: item.targetVaultId,
        })).sort((left, right) => left.recordId.localeCompare(right.recordId))) ===
          JSON.stringify(sourceBeforeQuotaReload.migrationItems.map((item) => ({
            migrationId: item.migrationId,
            recordId: item.recordId,
            ciphertextSha256: item.ciphertextSha256,
            storedEnvelopeSha256: item.storedEnvelopeSha256,
            computedEnvelopeSha256: item.computedEnvelopeSha256,
            targetVaultId: item.targetVaultId,
          })).sort((left, right) => left.recordId.localeCompare(right.recordId))),
      'same-profile reload changed the durable target, payload, or a staged ciphertext digest');
      reportBoolean('same_profile_reload_preserved_each_preexisting_staged_ciphertext_sha256', true);
    } else {
      reportBoolean('same_profile_pre_reload_snapshot_available_for_hash_comparison', false);
    }
    console.log(`safe source state after migration quota reload ${JSON.stringify({
      integrity: sourceAfterQuotaReload.integrity,
      counts: sourceAfterQuotaReload.counts,
      migrationStates: sourceAfterQuotaReload.migrationStates,
    })}`);
    const vaultsAfterQuotaReload = await directApi(baseUrl, 'GET', '/api/v1/vaults', ownerAccessToken);
    assertThat(vaultsAfterQuotaReload.status === 200 &&
      vaultsAfterQuotaReload.body.vaults.length === vaultIdsBeforeQuotaAttempt.length + 1 &&
      vaultsAfterQuotaReload.body.vaults.filter((vault) => vault.vault_id === targetVaultId).length === 1,
    'quota reload lost or duplicated the already-created migration target');
    const databaseAfterQuotaReload = inspectDatabase(databasePath, targetVaultId);
    const quotaReloadSubset = assertServerMatchesStagedSubset(
      databaseAfterQuotaReload, sourceAfterQuotaReload.migrationItems, targetVaultId,
      { requirePending: false, requireIncomplete: false },
    );
    assertThat(serverSnapshotExtends(quotaServerBaseline, databaseAfterQuotaReload),
      'same-profile reload removed or changed a previously committed staged envelope');
    console.log(`safe post-reload server baseline ${JSON.stringify({
      recordCount: quotaReloadSubset.serverRecordCount,
      stagedCount: quotaReloadSubset.stagedRecordCount,
      pendingStagedCount: quotaReloadSubset.pendingStagedCount,
      digest: quotaReloadSubset.fingerprint,
    })}`);
    pre503ServerBaseline = databaseAfterQuotaReload;
    reportBoolean('quota_failure_preserved_same_target_journal_payload_and_staged_ciphertext', true);
    }
    assertThat(quotaFailureSourceSnapshot != null && Array.isArray(quotaFailureItems) &&
      quotaJournal != null,
    'same-profile reload did not yield a resumable migration snapshot for later recovery checks');

    const settingsAvailable = await visibleTextEvidence(page, 'Settings', 1000);
    if (!settingsAvailable) {
      setStage('restore server session after same-profile reload');
      await click(page, 'Continue');
      // A reload restores the previously configured server URL asynchronously.
      // On a fresh server-mode entry, the URL form is still shown instead.
      let loginFormReady = await fieldEvidence(page, 'Email or username', 60000);
      if (!loginFormReady && await fieldEvidence(page, 'Server URL', 1000)) {
        setStage('reconnect server after same-profile reload');
        await fill(page, 'Server URL', baseUrl);
        await click(page, 'Connect securely');
        loginFormReady = await fieldEvidence(page, 'Email or username', 30000);
      }
      assertThat(loginFormReady,
        'server session restore did not reach the account login form after reload');
      setStage('wait for account login after same-profile reload');
      await field(page, 'Email or username');
      setStage('fill account login after same-profile reload');
      await fill(page, 'Email or username', OWNER_USERNAME);
      await fill(page, 'Master password', OWNER_PASSWORD);
      const loginButton = await button(page, 'Sign in and unlock');
      assertThat(!(await loginButton.isDisabled()),
        'account login action remained disabled after same-profile reload');
      setStage('submit account login after same-profile reload');
      await click(page, 'Sign in and unlock');
      setStage('wait for authenticated workspace after quota recovery');
    }
    setStage('open or resume LocalVault migration after re-authentication');
    let migrationScreenReady = await visibleTextEvidence(
      page, 'Move local encrypted records to a new sync Vault', 2500,
    );
    if (!migrationScreenReady) {
      await (await button(page, 'Settings')).waitFor({ state: 'visible', timeout: 60000 });
      await click(page, 'Settings');
      await visibleText(page, 'Review local profile migration');
      await click(page, 'Review local profile migration');
      migrationScreenReady = await visibleTextEvidence(
        page, 'Move local encrypted records to a new sync Vault', 30000,
      );
    }
    assertThat(migrationScreenReady,
      'LocalVault migration review did not reopen after account login');
    if (await fieldEvidence(page, 'Local profile password', 1500)) {
      await fill(page, 'Local profile password', LOCAL_PASSWORD);
      await click(page, 'Unlock and validate');
      await visibleText(page, 'Local profile unlocked');
    } else {
      await visibleText(page, 'Local profile unlocked');
    }
    if (!sourceAfterQuotaReload) {
      setStage('verify recovery journal remains resumable after actual LocalVault unlock');
      const recoveryVisible = await visibleTextEvidence(page, 'Migration needs recovery', 10000);
      let continueAvailable = false;
      try {
        await button(page, 'Continue migration', 10000);
        continueAvailable = true;
      } catch (_) {}
      console.log(`safe LocalVault post-unlock recovery UI evidence ${JSON.stringify({
        recoveryVisible,
        continueAvailable,
        preUnlockSnapshotError: sourceAfterQuotaReloadError,
        postUnlockSnapshotErrorCategory: postUnlockSnapshotError,
        localProfileUnlockReached: diagnosticLocalUnlockReached,
      })}`);
      assertThat(recoveryVisible && continueAvailable,
        'unreadable LocalVault snapshot did not retain an actionable migration recovery journal');
      throw new Error('LocalVault migration journal stayed unreadable after profile unlock; stopped before resume');
    }
    const reopenedSource = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-after-unlock',
    );
    setStage('verify LocalVault after migration profile reopen');
    assertThat(reopenedSource.integrity === 'ok' &&
      reopenedSource.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      reopenedSource.counts.local_vault_migrations === 1 &&
      reopenedSource.counts.local_vault_migration_items === quotaFailureItems.length &&
      reopenedSource.counts.local_vault_migration_create_payloads === 1 &&
      reopenedSource.migrationStates.frozen === 1 &&
      JSON.stringify(reopenedSource.migrationJournals) ===
        JSON.stringify(quotaFailureSourceSnapshot.migrationJournals) &&
      JSON.stringify(reopenedSource.migrationCreatePayloads) ===
        JSON.stringify(quotaFailureSourceSnapshot.migrationCreatePayloads) &&
      JSON.stringify(reopenedSource.migrationItems.map((item) => ({
        migrationId: item.migrationId,
        recordId: item.recordId,
        ciphertextSha256: item.ciphertextSha256,
        storedEnvelopeSha256: item.storedEnvelopeSha256,
        computedEnvelopeSha256: item.computedEnvelopeSha256,
        targetVaultId: item.targetVaultId,
      })).sort((left, right) => left.recordId.localeCompare(right.recordId))) ===
        JSON.stringify(quotaFailureItems.map((item) => ({
          migrationId: item.migrationId,
          recordId: item.recordId,
          ciphertextSha256: item.ciphertextSha256,
          storedEnvelopeSha256: item.storedEnvelopeSha256,
          computedEnvelopeSha256: item.computedEnvelopeSha256,
          targetVaultId: item.targetVaultId,
        })).sort((left, right) => left.recordId.localeCompare(right.recordId))) &&
      !reopenedSource.plaintextMarkerFound,
    'same-profile recovery did not preserve the exact quota-stage journal and staged ciphertext');
    await visibleText(page, 'Migration needs recovery');
    await quotaSession.detach().catch(() => {});
    quotaSession = null;

    setStage('confirm the initial target push received the real 503 before recovery resume');
    const target503AlreadyObserved = apiEvents.slice(interruptedPushStart).some((event) =>
      event.route === 'push' && event.method === 'POST' &&
      event.pathname === expectedTargetPushPath && event.status === 503);
    if (!target503AlreadyObserved) await click(page, 'Continue migration');
    setStage('wait for the exact target Vault push 503 response');
    await waitFor(() => apiEvents.slice(interruptedPushStart).some((event) =>
      event.route === 'push' && event.method === 'POST' &&
      event.pathname === expectedTargetPushPath && event.status === 503), 60000);
    setStage('confirm the real 503 remains associated with migration recovery UI');
    await visibleText(page, 'Migration needs recovery', 30000);
    setStage('wait for the initial recovery attempt to finish staging before snapshot');
    const recoveryResumeButton = page.getByRole('button', {
      name: 'Continue migration', exact: true,
    });
    await recoveryResumeButton.waitFor({ state: 'visible', timeout: 30000 });
    try {
      await waitFor(() => recoveryResumeButton.isEnabled(), 30000);
    } catch (_) {
      let settleSnapshot = null;
      let settleSnapshotError = null;
      try {
        settleSnapshot = await localVaultSqliteCounts(
          page, localDatabaseName, 'local-migration-settle-timeout-diagnostic',
        );
      } catch (error) {
        settleSnapshotError = safeSnapshotErrorEvidence(error);
      }
      const settlePushEvents = targetPushEvents(targetVaultId);
      console.log(`safe recovery-attempt settle timeout ${JSON.stringify({
        resumeButtonVisible: await recoveryResumeButton.isVisible().catch(() => false),
        resumeButtonEnabled: await recoveryResumeButton.isEnabled().catch(() => false),
        sourceReadable: settleSnapshot != null,
        sourceSnapshotError: settleSnapshotError,
        sourceIntegrity: settleSnapshot?.integrity || null,
        sourceRecordCount: settleSnapshot?.counts.local_vault_records ?? null,
        journalCount: settleSnapshot?.counts.local_vault_migrations ?? null,
        journalStatus: settleSnapshot?.migrationJournals?.[0]?.status || null,
        stagedCount: settleSnapshot?.counts.local_vault_migration_items ?? null,
        createPayloadCount:
          settleSnapshot?.counts.local_vault_migration_create_payloads ?? null,
        plaintextMarkerFound: settleSnapshot?.plaintextMarkerFound ?? null,
        target503Count: settlePushEvents.filter((event) => event.status === 503).length,
        target2xxCount: settlePushEvents.filter((event) =>
          event.status >= 200 && event.status < 300).length,
        targetAbortedCount: blockedTargetRetryCount,
        targetUnresolvedCount: settlePushEvents.filter((event) =>
          event.status === null && !event.failed).length,
      })}`);
      throw new Error('recovery attempt did not settle before the bounded timeout');
    }
    const target503Responses = apiEvents.filter((event) =>
      event.route === 'push' && event.method === 'POST' &&
      event.pathname === expectedTargetPushPath && event.status === 503);
    const allVaultCreatesBeforeResume = apiEvents.filter((event) =>
      event.route === 'vaults' && event.method === 'POST');
    assertThat(target503Responses.length === 1 && rejectedMigrationPushes === 1 &&
      firstTargetPushRouteSeen && firstMigrationPush503Evidence?.targetVaultId === targetVaultId &&
      firstMigrationPush503Evidence.unchanged,
    'migration did not receive exactly one intercepted 503 from the existing target Vault push path');
    assertThat(allVaultCreatesBeforeResume.length === 1 &&
      allVaultCreatesBeforeResume[0].vaultId === targetVaultId &&
      allVaultCreatesBeforeResume[0].status >= 200 &&
      allVaultCreatesBeforeResume[0].status < 300,
    'resuming the frozen journal created another target Vault');
    assertThat(!apiEvents.slice(interruptedPushStart).some((event) => event.markerLeakInRequest),
      'a local plaintext marker appeared in an encrypted migration request');
    await waitFor(() => targetPushEvents(targetVaultId).every((event) =>
      event.status !== null || event.failed), 10000);
    const targetPushOutcomesBeforeResume = targetPushEvents(targetVaultId);
    const targetSuccessesBeforeResume = targetPushOutcomesBeforeResume.filter((event) =>
      event.status >= 200 && event.status < 300).length;
    console.log(`safe target retry hold outcomes ${JSON.stringify({
      intercepted503Count: targetPushOutcomesBeforeResume.filter((event) =>
        event.status === 503).length,
      abortedRetryCount: blockedTargetRetryCount,
      successfulPushCountBeforeExplicitResume: targetSuccessesBeforeResume,
      unresolvedRequestCount: targetPushOutcomesBeforeResume.filter((event) =>
        event.status === null && !event.failed).length,
    })}`);
    assertThat(target503Responses.length === 1 && targetSuccessesBeforeResume === 0,
      'target auto-retry wrote server state before the explicit migration resume');
    const after503Source = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-after-503',
    );
    assertThat(after503Source.integrity === 'ok' &&
      after503Source.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      after503Source.counts.local_vault_migrations === 1 &&
      after503Source.counts.local_vault_migration_items === after503Source.migrationItems.length &&
      after503Source.counts.local_vault_migration_items >= quotaFailureItems.length &&
      after503Source.counts.local_vault_migration_items <= EXPECTED_MIGRATED_RECORDS &&
      after503Source.counts.local_vault_migration_create_payloads === 1 &&
      after503Source.migrationStates.frozen === 1 &&
      after503Source.migrationJournals.length === 1 &&
      after503Source.migrationJournals[0].targetVaultId === targetVaultId &&
      after503Source.migrationJournals[0].migrationId === quotaJournal.migrationId &&
      JSON.stringify(after503Source.migrationCreatePayloads) ===
        JSON.stringify(quotaFailureSourceSnapshot.migrationCreatePayloads) &&
      after503Source.migrationItems.every((item) => item.envelopeValid &&
        item.migrationId === quotaJournal.migrationId &&
        item.targetVaultId === targetVaultId &&
        item.storedEnvelopeSha256 === item.computedEnvelopeSha256 &&
        /^[0-9a-f]{64}$/.test(item.canonicalEnvelopeSha256 || '') &&
        /^[0-9a-f]{64}$/.test(item.ciphertextSha256 || '')) &&
      quotaFailureItems.every((stagedBeforeReload) =>
        after503Source.migrationItems.some((stagedAfterResume) =>
          stagedAfterResume.migrationId === stagedBeforeReload.migrationId &&
          stagedAfterResume.recordId === stagedBeforeReload.recordId &&
          stagedAfterResume.ciphertextSha256 === stagedBeforeReload.ciphertextSha256 &&
          stagedAfterResume.storedEnvelopeSha256 === stagedBeforeReload.storedEnvelopeSha256 &&
          stagedAfterResume.computedEnvelopeSha256 === stagedBeforeReload.computedEnvelopeSha256 &&
          stagedAfterResume.canonicalEnvelopeSha256 === stagedBeforeReload.canonicalEnvelopeSha256 &&
          stagedAfterResume.opId === stagedBeforeReload.opId &&
          stagedAfterResume.revisionId === stagedBeforeReload.revisionId)) &&
      !after503Source.plaintextMarkerFound,
    '503 recovery did not preserve the same journal and every previously staged encrypted operation');
    console.log(`safe staged append after first recovery attempt ${JSON.stringify({
      quotaCheckpointStagedCount: quotaFailureItems.length,
      after503StagedCount: after503Source.migrationItems.length,
      newlyStagedCount: after503Source.migrationItems.length - quotaFailureItems.length,
      oldStagedCiphertextAndEnvelopeHashesPreserved: quotaFailureItems.every((stagedBeforeReload) =>
        after503Source.migrationItems.some((stagedAfterResume) =>
          stagedAfterResume.migrationId === stagedBeforeReload.migrationId &&
          stagedAfterResume.recordId === stagedBeforeReload.recordId &&
          stagedAfterResume.ciphertextSha256 === stagedBeforeReload.ciphertextSha256 &&
          stagedAfterResume.storedEnvelopeSha256 === stagedBeforeReload.storedEnvelopeSha256 &&
          stagedAfterResume.computedEnvelopeSha256 === stagedBeforeReload.computedEnvelopeSha256 &&
          stagedAfterResume.canonicalEnvelopeSha256 === stagedBeforeReload.canonicalEnvelopeSha256 &&
          stagedAfterResume.opId === stagedBeforeReload.opId &&
          stagedAfterResume.revisionId === stagedBeforeReload.revisionId)),
      journalFrozen: after503Source.migrationStates.frozen === 1,
      plaintextMarkerFound: after503Source.plaintextMarkerFound,
    })}`);
    const after503Database = inspectDatabase(databasePath, targetVaultId);
    const after503Subset = assertServerMatchesStagedSubset(
      after503Database, after503Source.migrationItems, targetVaultId,
      { requirePending: false, requireIncomplete: false },
    );
    assertThat(firstMigrationPush503Evidence?.unchanged &&
      serverSnapshotExtends(pre503ServerBaseline, after503Database),
    'server state lost a committed prefix or the initial 503 changed target state');
    console.log(`safe post-503 target snapshot ${JSON.stringify({
      recordCount: after503Subset.serverRecordCount,
      stagedCount: after503Subset.stagedRecordCount,
      pendingStagedCount: after503Subset.pendingStagedCount,
      digest: after503Subset.fingerprint,
    })}`);
    const beforeResumeVaults = await directApi(baseUrl, 'GET', '/api/v1/vaults', ownerAccessToken);
    assertThat(beforeResumeVaults.status === 200 && Array.isArray(beforeResumeVaults.body?.vaults) &&
        beforeResumeVaults.body.vaults.filter((item) => item.vault_id === targetVaultId).length === 1,
      'the interrupted migration target was not durably listed exactly once');
    reportBoolean('same_target_resumed_after_real_503_without_server_state_delta', true);

    setStage('verify LocalVault write freeze from a second browser tab');
    const probePage = await context.newPage();
    await probePage.goto(appOrigin, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(probePage);
    await visibleText(probePage, 'Choose a workspace');
    await click(probePage, 'Open locally');
    await visibleText(probePage, '选择配置解锁');
    await tapSemanticTextContaining(probePage, '本地配置 · ');
    await fill(probePage, '本地配置主密码', LOCAL_PASSWORD);
    await click(probePage, '解锁本地配置');
    await click(probePage, 'Host');
    await visibleText(probePage, HOST_NAME);
    await tapSemanticTextContaining(probePage, HOST_NAME);
    await visibleText(probePage, '编辑本地 Host');
    const attemptedHostName = `${HOST_NAME}-while-frozen`;
    await fill(probePage, '名称', attemptedHostName);
    await click(probePage, '保存加密 Host');
    await visibleText(probePage, '更新 Host 失败，请重试。', 30000);
    const rejectedFrozenWrite = await probePage.evaluate((attemptedName) => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return !`${document.body.innerText || ''}\n${semantics}`.includes(attemptedName);
    }, attemptedHostName);
    assertThat(rejectedFrozenWrite, 'LocalVault accepted a write while a migration remained resumable');
    await probePage.close();
    reportBoolean('source_write_frozen_while_recovery_pending', true);

    setStage('confirm retry hold retained the same frozen LocalVault journal');
    const sourceBeforeExplicitResume = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-before-explicit-resume',
    );
    const sourceBeforeExplicitResumeItems = sourceBeforeExplicitResume.migrationItems.map((item) => ({
      migrationId: item.migrationId,
      recordId: item.recordId,
      ciphertextSha256: item.ciphertextSha256,
      storedEnvelopeSha256: item.storedEnvelopeSha256,
      computedEnvelopeSha256: item.computedEnvelopeSha256,
      targetVaultId: item.targetVaultId,
    })).sort((left, right) => left.recordId.localeCompare(right.recordId));
    const post503StagedHashCheckpoint = after503Source.migrationItems.map((item) => ({
      migrationId: item.migrationId,
      recordId: item.recordId,
      ciphertextSha256: item.ciphertextSha256,
      storedEnvelopeSha256: item.storedEnvelopeSha256,
      computedEnvelopeSha256: item.computedEnvelopeSha256,
      targetVaultId: item.targetVaultId,
    })).sort((left, right) => left.recordId.localeCompare(right.recordId));
    const sourceBeforeExplicitResumeEvidence = {
      integrity: sourceBeforeExplicitResume.integrity,
      recordCount: sourceBeforeExplicitResume.counts.local_vault_records,
      journalCount: sourceBeforeExplicitResume.counts.local_vault_migrations,
      journalStatus: sourceBeforeExplicitResume.migrationJournals?.[0]?.status || null,
      journalTargetMatchesCreatedVault:
        sourceBeforeExplicitResume.migrationJournals?.[0]?.targetVaultId === targetVaultId,
      stagedCount: sourceBeforeExplicitResume.counts.local_vault_migration_items,
      expectedStagedCount: after503Source.migrationItems.length,
      payloadCount: sourceBeforeExplicitResume.counts.local_vault_migration_create_payloads,
      frozenJournalCount: sourceBeforeExplicitResume.migrationStates?.frozen || 0,
      stagedHashesMatchPost503Checkpoint: JSON.stringify(sourceBeforeExplicitResumeItems) ===
        JSON.stringify(post503StagedHashCheckpoint),
      plaintextMarkerFound: sourceBeforeExplicitResume.plaintextMarkerFound,
      targetRetryAbortCount: blockedTargetRetryCount,
    };
    console.log(`safe source state before explicit migration resume ${JSON.stringify(
      sourceBeforeExplicitResumeEvidence,
    )}`);
    assertThat(sourceBeforeExplicitResumeEvidence.integrity === 'ok' &&
      sourceBeforeExplicitResumeEvidence.recordCount === EXPECTED_MIGRATED_RECORDS &&
      sourceBeforeExplicitResumeEvidence.frozenJournalCount === 1 &&
      sourceBeforeExplicitResumeEvidence.journalCount === 1 &&
      sourceBeforeExplicitResumeEvidence.journalTargetMatchesCreatedVault &&
      sourceBeforeExplicitResumeEvidence.stagedCount === after503Source.migrationItems.length &&
      sourceBeforeExplicitResumeEvidence.stagedHashesMatchPost503Checkpoint &&
      !sourceBeforeExplicitResumeEvidence.plaintextMarkerFound &&
      sourceBeforeExplicitResume.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      sourceBeforeExplicitResume.migrationStates.frozen === 1 &&
      sourceBeforeExplicitResume.migrationJournals.length === 1 &&
      sourceBeforeExplicitResume.migrationJournals[0].targetVaultId === targetVaultId &&
      sourceBeforeExplicitResume.counts.local_vault_migration_items === after503Source.migrationItems.length &&
      JSON.stringify(sourceBeforeExplicitResumeItems) === JSON.stringify(post503StagedHashCheckpoint) &&
      !sourceBeforeExplicitResume.plaintextMarkerFound,
    'automatic retry hold changed or unfroze the exact durable LocalVault journal');

    setStage('resume the exact staged target after the transient outage');
    allowTargetMigrationRetry = true;
    const resumeButtons = page.getByRole('button', { name: 'Continue migration', exact: true });
    await resumeButtons.first().waitFor({ state: 'visible', timeout: 30000 });
    await resumeButtons.first().click();
    await visibleText(page, 'Migration completed', 120000);
    await visibleText(page, '迁移已完成', 30000);
    const createPostsAfterResume = apiEvents.filter((event) =>
      event.route === 'vaults' && event.method === 'POST');
    assertThat(createPostsAfterResume.length === 1 &&
        createPostsAfterResume[0].vaultId === targetVaultId,
      'resume attempted another Vault creation instead of reusing its exact target');
    const successfulPush = apiEvents.some((event) =>
      event.route === 'push' && event.method === 'POST' &&
      event.pathname === expectedTargetPushPath && event.status >= 200 && event.status < 300);
    assertThat(successfulPush, 'resumed migration did not receive a successful sync push response');
    reportBoolean('resume_reused_same_vault_and_exact_operations', true);

    setStage('verify target Vault changes and browser-visible decrypted records');
    const changes = await directApi(
      baseUrl,
      'GET',
      `/api/v1/vaults/${encodeURIComponent(targetVaultId)}/changes?limit=100`,
      ownerAccessToken,
    );
    assertThat(changes.status === 200 && Array.isArray(changes.body?.events) &&
        changes.body.events.length === EXPECTED_MIGRATED_RECORDS && changes.body.events.every((event) =>
          event.event_type === 'create' && event.envelope && typeof event.envelope.ciphertext === 'string'),
      'target change feed did not contain exactly the migrated opaque record envelopes');
    const serializedChanges = JSON.stringify(changes.body);
    assertThat(!PLAINTEXT_MARKERS.some((marker) => serializedChanges.includes(marker)),
      'target change feed exposed a local plaintext marker');
    await click(page, 'Close');
    await click(page, 'Hosts');
    await visibleText(page, HOST_NAME, 45000);
    await click(page, 'Credentials');
    await visibleText(page, CREDENTIAL_NAME, 45000);
    const credentialVisible = await page.evaluate((secret) => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body.innerText || ''}\n${semantics}`.includes(secret);
    }, CREDENTIAL_SECRET);
    assertThat(!credentialVisible, 'migrated Credential secret was rendered into the workspace');
    reportBoolean('migrated_host_and_credential_decrypt_in_server_workspace', true);

    setStage('record owner-side migrated Snippet visibility');
    await click(page, 'Snippets');
    const ownerSnippetScroll = await scrollToTopAttempt(page);
    ownerSnippetEvidence = await recordViewEvidence(
      page,
      'Command snippets',
      { snippetName: SNIPPET_NAME },
      ['No snippets yet'],
    );
    Object.assign(ownerSnippetEvidence,
      await snippetPageVisualEvidence(page, 'owner', ownerSnippetScroll));
    console.log(`safe owner Snippets view evidence ${JSON.stringify(ownerSnippetEvidence)}`);

    setStage('enroll and approve independent second device');
    secondContext = await browser.newContext({
      locale: 'zh-CN',
      viewport: { width: 1440, height: 1000 },
    });
    await secondContext.grantPermissions(['clipboard-read', 'clipboard-write'], {
      origin: appOrigin,
    });
    secondPage = await secondContext.newPage();
    trackApi(secondPage, 'second-device');
    const secondDeviceApiStart = apiEvents.length;
    secondPage.on('pageerror', () => pageErrors.push('page-error'));
    await secondPage.goto(appOrigin, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(secondPage);
    await visibleText(secondPage, 'Choose a workspace');
    await click(secondPage, 'Continue');
    await fill(secondPage, 'Server URL', baseUrl);
    await click(secondPage, 'Connect securely');
    await field(secondPage, 'Email or username');
    const enrolledDevice = await enrollAndApproveSecondDevice(
      page,
      secondPage,
      targetVaultId,
    );
    secondDeviceTargetVaultIndex = enrolledDevice.targetVaultIndex;
    assertThat(enrolledDevice.requestedDeviceId !== ownerDeviceId,
      'second approved device reused the original device identity');
    const registeredDevices = await directApi(baseUrl, 'GET', '/api/v1/devices', ownerAccessToken);
    const accountDevices = registeredDevices.body?.devices;
    assertThat(registeredDevices.status === 200 && Array.isArray(accountDevices) &&
        accountDevices.filter((device) => device.status === 'active').length === 2 &&
        accountDevices.some((device) => device.device_id === ownerDeviceId && device.status === 'active') &&
        accountDevices.some((device) => device.device_id === enrolledDevice.requestedDeviceId &&
          device.name === SECOND_DEVICE_NAME && device.status === 'active'),
      'second signed device was not separately registered as active');
    const destinationDevices = await directApi(
      baseUrl,
      'GET',
      `/api/v1/vaults/${encodeURIComponent(targetVaultId)}/devices`,
      ownerAccessToken,
    );
    assertThat(destinationDevices.status === 200 &&
        Array.isArray(destinationDevices.body?.devices) &&
        destinationDevices.body.devices.some((device) =>
          device.device_id === enrolledDevice.requestedDeviceId && device.status === 'active'),
      'approved second device did not receive target Vault membership/key availability');
    reportBoolean('second_device_separately_enrolled_and_approved', true);

    await selectVaultByName(
      secondPage,
      TARGET_VAULT_NAME,
      targetVaultId,
      enrolledDevice.targetVaultIndex,
    );

    setStage('record whether an automatic target pull has completed');
    const automaticTargetChanges = await waitForTargetChangesEvidence(
      secondDeviceApiStart,
      targetVaultId,
      0,
    );
    secondDeviceTargetChangesEvidence = { automatic: automaticTargetChanges };
    console.log(`safe second-device automatic pull checkpoint ${JSON.stringify(automaticTargetChanges)}`);
    reportBoolean('second_device_automatic_target_pull_completed',
      automaticTargetChanges.statusCodes.includes(200));
    let receivedOpaqueBatch = automaticTargetChanges.completeOpaqueBatch;
    setStage('open second-device Sync & conflicts page');
    await click(secondPage, 'Sync & conflicts');
    setStage('wait for second-device sync status');
    await visibleText(secondPage, 'Sync health');
    setStage('record target pulls that started before explicit sync');
    const beforeExplicitSync = await waitForTargetChangesEvidence(
      secondDeviceApiStart,
      targetVaultId,
      0,
    );
    secondDeviceTargetChangesEvidence.beforeExplicitSync = beforeExplicitSync;
    console.log(`safe second-device pre-click target pull evidence ${JSON.stringify(beforeExplicitSync)}`);
    receivedOpaqueBatch = beforeExplicitSync.completeOpaqueBatch;
    if (!receivedOpaqueBatch) {
      setStage('wait for automatic second-device sync to settle');
      await waitForSyncSettled(secondPage);
      const settledAutomaticChanges = await waitForTargetChangesEvidence(
        secondDeviceApiStart,
        targetVaultId,
        0,
      );
      secondDeviceTargetChangesEvidence.afterAutomaticSettle = settledAutomaticChanges;
      console.log(`safe second-device settled automatic pull evidence ${JSON.stringify(settledAutomaticChanges)}`);
      receivedOpaqueBatch = settledAutomaticChanges.completeOpaqueBatch;
    }
    if (!receivedOpaqueBatch) {
      setStage('start explicit second-device Vault sync');
      const explicitSyncApiStart = apiEvents.length;
      await click(secondPage, 'Sync now');
      setStage('wait for exact destination Vault changes response');
      const explicitTargetChanges = await waitForTargetChangesEvidence(
        explicitSyncApiStart,
        targetVaultId,
      );
      secondDeviceTargetChangesEvidence.explicitResponse = explicitTargetChanges;
      console.log(`safe second-device explicit sync response evidence ${JSON.stringify(explicitTargetChanges)}`);
      assertThat(explicitTargetChanges.statusCodes.includes(200),
        'explicit second-device sync did not receive the destination Vault changes response');
    }
    setStage('wait for second-device Sync control and status to settle');
    await waitForSyncSettled(secondPage);
    setStage('verify completed second-device target changes import');
    const completedTargetChanges = await waitForTargetChangesEvidence(
      secondDeviceApiStart,
      targetVaultId,
      0,
    );
    secondDeviceTargetChangesEvidence.afterSyncIdle = completedTargetChanges;
    console.log(`safe second-device completed sync evidence ${JSON.stringify(completedTargetChanges)}`);
    receivedOpaqueBatch = receivedOpaqueBatch || completedTargetChanges.completeOpaqueBatch;
    assertThat(receivedOpaqueBatch,
      `second device did not receive all ${EXPECTED_MIGRATED_RECORDS} opaque migration events for the destination Vault`);
    reportBoolean('second_device_received_all_eight_opaque_migration_events', true);

    setStage('capture completed second-device Sync health metrics');
    secondDeviceSyncUiEvidence = await secondDeviceSyncHealthEvidence(secondPage, [
      secondDeviceTargetDisplayName,
      TARGET_VAULT_NAME,
      `Vault ${targetVaultId.slice(0, 8)}`,
    ]);
    console.log(`safe second-device sync UI evidence ${JSON.stringify(secondDeviceSyncUiEvidence)}`);

    secondDeviceRecordUiEvidence = {};
    setStage('inspect second-device Snippets workspace');
    await click(secondPage, 'Snippets');
    const secondSnippetScroll = await scrollToTopAttempt(secondPage);
    secondDeviceRecordUiEvidence.snippets = await recordViewEvidence(
      secondPage,
      'Command snippets',
      { snippetName: SNIPPET_NAME },
      ['No snippets yet'],
    );
    Object.assign(secondDeviceRecordUiEvidence.snippets,
      await snippetPageVisualEvidence(secondPage, 'second-device', secondSnippetScroll));
    setStage('inspect second-device Hosts workspace');
    await click(secondPage, 'Hosts');
    secondDeviceRecordUiEvidence.hosts = await recordViewEvidence(
      secondPage,
      'Hosts',
      { hostName: HOST_NAME, address: HOST_ADDRESS, username: HOST_USERNAME },
      ['No hosts saved yet'],
    );
    setStage('inspect second-device Groups workspace');
    await click(secondPage, 'Groups');
    secondDeviceRecordUiEvidence.groups = await recordViewEvidence(
      secondPage,
      'Host groups',
      { groupName: GROUP_NAME },
      ['No host groups yet'],
    );
    setStage('inspect second-device Credentials workspace');
    await click(secondPage, 'Credentials');
    secondDeviceRecordUiEvidence.credentials = await recordViewEvidence(
      secondPage,
      'SSH credentials',
      {
        credentialName: CREDENTIAL_NAME,
        username: CREDENTIAL_USERNAME,
        credentialSecret: CREDENTIAL_SECRET,
      },
      ['No credentials saved'],
    );

    setStage('inspect second-device Vault and workspace preference in Settings');
    await click(secondPage, 'Settings');
    const syncedPreferencesVisible = await visibleTextEvidence(
      secondPage, 'Vault-synced preferences', 45000,
    );
    const currentVaultLabelVisible = await visibleTextEvidence(secondPage, 'Current Vault');
    const targetVaultNameVisible = await visibleTextEvidence(
      secondPage, secondDeviceTargetDisplayName,
    );
    const defaultSectionLabelVisible = await visibleTextEvidence(
      secondPage, 'Default workspace section',
    );
    secondDevicePreferenceEvidence = await migratedPreferenceEvidence(secondPage);
    secondDeviceSettingsEvidence = {
      syncedPreferencesVisible,
      currentVaultLabelVisible,
      targetVaultNameVisible,
      currentVaultHeaderMatchesTarget: await vaultHeaderMatches(secondPage, [
        secondDeviceTargetDisplayName,
        TARGET_VAULT_NAME,
        `Vault ${targetVaultId.slice(0, 8)}`,
      ]),
      defaultSectionLabelVisible,
      preference: secondDevicePreferenceEvidence,
    };
    console.log(`safe second-device record view evidence ${JSON.stringify(secondDeviceRecordUiEvidence)}`);
    console.log(`safe second-device Settings evidence ${JSON.stringify(secondDeviceSettingsEvidence)}`);

    const expectedRecordFieldsVisible =
      Object.values(secondDeviceRecordUiEvidence.snippets.markersVisible).every(Boolean) &&
      Object.values(secondDeviceRecordUiEvidence.hosts.markersVisible).every(Boolean) &&
      Object.values(secondDeviceRecordUiEvidence.groups.markersVisible).every(Boolean) &&
      secondDeviceRecordUiEvidence.credentials.markersVisible.credentialName &&
      secondDeviceRecordUiEvidence.credentials.markersVisible.username &&
      !secondDeviceRecordUiEvidence.credentials.markersVisible.credentialSecret;
    assertThat(expectedRecordFieldsVisible,
      'second device did not decrypt all expected migrated record fields or exposed the Credential secret');
    assertThat(secondDeviceSettingsEvidence.syncedPreferencesVisible &&
        secondDeviceSettingsEvidence.currentVaultLabelVisible &&
        secondDeviceSettingsEvidence.targetVaultNameVisible &&
        secondDeviceSettingsEvidence.currentVaultHeaderMatchesTarget &&
        secondDevicePreferenceEvidence.defaultSectionLabelVisible &&
        secondDevicePreferenceEvidence.terminalFontSizeLabelVisible &&
        secondDevicePreferenceEvidence.terminalThemeLabelVisible &&
        secondDevicePreferenceEvidence.selectedDefaultSection &&
        secondDevicePreferenceEvidence.selectedTerminalFontSize &&
        secondDevicePreferenceEvidence.selectedTerminalTheme &&
        secondDevicePreferenceEvidence.shortcutsLabelVisible &&
        Object.values(secondDevicePreferenceEvidence.shortcutBindings).every(Boolean),
      'second device did not decrypt the exact four supported migrated preference tuples');
    reportBoolean('second_device_decrypted_all_four_supported_preference_tuples_after_approved_sync', true);

    setStage('verify completed source journal and all server commits against staged ciphertext hashes');
    const finalLocalVaultSnapshot = await localVaultSqliteCounts(
      page, localDatabaseName, 'local-migration-final-staged-envelope-snapshot',
    );
    assertThat(finalLocalVaultSnapshot.integrity === 'ok' &&
      finalLocalVaultSnapshot.counts.local_vault_records === EXPECTED_MIGRATED_RECORDS &&
      finalLocalVaultSnapshot.counts.local_vault_migrations === 1 &&
      finalLocalVaultSnapshot.counts.local_vault_migration_items === EXPECTED_MIGRATED_RECORDS &&
      finalLocalVaultSnapshot.migrationStates.completed === 1 &&
      finalLocalVaultSnapshot.migrationItems.length === EXPECTED_MIGRATED_RECORDS &&
      finalLocalVaultSnapshot.migrationItems.every((item) => item.envelopeValid &&
        item.targetVaultId === targetVaultId &&
        item.storedEnvelopeSha256 === item.computedEnvelopeSha256 &&
        item.recordId && item.opId && item.revisionId &&
        /^[0-9a-f]{64}$/.test(item.canonicalEnvelopeSha256 || '')) &&
      !finalLocalVaultSnapshot.plaintextMarkerFound,
    'completed source journal did not retain all eight validated staged ciphertext envelopes');
    const db = inspectDatabase(databasePath, targetVaultId);
    const finalServerSubset = assertServerMatchesStagedSubset(
      db, finalLocalVaultSnapshot.migrationItems, targetVaultId,
      { requirePending: false, requireIncomplete: false },
    );
    assertThat(db.vault_count === 1 && db.record_versions === EXPECTED_MIGRATED_RECORDS &&
        db.record_heads === EXPECTED_MIGRATED_RECORDS &&
        db.change_events === EXPECTED_MIGRATED_RECORDS &&
        db.op_receipts === EXPECTED_MIGRATED_RECORDS && db.envelopes_valid &&
        db.plaintext_markers_absent && db.unique_record_ids && db.unique_op_ids &&
        db.heads_consistent && db.events_consistent && db.receipts_consistent &&
        db.records.length === EXPECTED_MIGRATED_RECORDS &&
        finalServerSubset.serverRecordCount === EXPECTED_MIGRATED_RECORDS &&
        finalServerSubset.pendingStagedCount === 0,
      'server database did not contain exactly eight unique opaque records, heads, events, and receipts matching durable staged envelopes');
    console.log(`safe final server commit metadata ${JSON.stringify({
      recordCount: finalServerSubset.serverRecordCount,
      stagedCount: finalServerSubset.stagedRecordCount,
      pendingStagedCount: finalServerSubset.pendingStagedCount,
      fingerprint: finalServerSubset.fingerprint,
      versions: db.record_versions,
      heads: db.record_heads,
      events: db.change_events,
      receipts: db.op_receipts,
    })}`);
    const dataFiles = filesUnder(dataDir);
    for (const filePath of dataFiles) {
      const bytes = fs.readFileSync(filePath);
      assertThat(!PLAINTEXT_MARKERS.some((marker) => bytes.includes(Buffer.from(marker))),
        'a migration plaintext marker appeared in a durable server file');
    }
    const finalVaults = await directApi(baseUrl, 'GET', '/api/v1/vaults', ownerAccessToken);
    assertThat(finalVaults.status === 200 && finalVaults.body.vaults.length === 2 &&
        finalVaults.body.vaults.filter((item) => item.vault_id === targetVaultId).length === 1,
      'resume produced an extra target Vault');
    const localStillExists = await page.evaluate(async (expectedName) => {
      const databases = typeof indexedDB.databases === 'function'
        ? await indexedDB.databases()
        : [];
      return databases.some((database) => database.name === expectedName) &&
        databases.some((database) => database.name === 'atermius_profile_catalog');
    }, localDatabaseName);
    assertThat(localStillExists, 'migration removed the original encrypted LocalVault');
    assertThat(remoteRequests.length === 0, 'browser contacted a non-fixture origin');
    assertThat(pageErrors.length === 0, 'Chromium reported a Web runtime exception');
    reportBoolean('server_sqlite_contains_only_opaque_record_envelopes', true);
    reportBoolean('source_localvault_remains_persisted', true);
    console.log('WEB-LOCAL-MIGRATION-01 passed: Host, Credential, Group, Snippet, and exactly four explicitly supported workspace/all preferences (defaultSection, terminalFontSize, terminalTheme, terminalShortcuts) were re-encrypted into one new sync Vault; a second separately approved device synced and decrypted the same values; recovery reused the same target; server storage contained only opaque envelopes.');
  } catch (error) {
    await page?.waitForTimeout(250).catch(() => {});
    const diagnostics = page ? await page.evaluate(() => {
      const text = `${document.body.innerText || ''}\n${[...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n')}`;
      const states = [
        'Choose a workspace',
        'Connect to your server',
        'Connect securely',
        'Unlock your workspace',
        'Email or username',
        'Master password',
        'Sign in and unlock',
        'Add this device',
        'Import approval',
        'Migrate local profiles',
        'Move local encrypted records to a new sync Vault',
        'Unlock a local-only profile',
        'Local profile unlocked',
        'Start a new migration',
        'Migration needs recovery',
        'Migration completed',
        '正在预检全部本地记录',
        '本地数据已完整预检并冻结',
        '正在准备新的同步 Vault',
        '正在确认新 Vault 为空',
        '正在使用目标 Vault 密钥加密并暂存记录',
        '正在将加密记录同步到新 Vault',
        '迁移未完成',
        '本地存储写入中断',
        '请先释放存储空间',
        '重新加载页面',
        'Preflight and migrate',
        '无法安全恢复此迁移',
        '同步 Vault 已切换',
        '本地迁移日志已保留',
      ];
      const visibleSemantics = [...document.querySelectorAll('flt-semantics')].filter((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      });
      const safeSemanticText = (element) =>
        `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
          .replace(/\s+/g, ' ').trim();
      const localWorkspaceOptions = ['主机', '凭据', '分组', '片段'];
      const preferenceMenu = {
        visibleSnippetOption: visibleSemantics.some((element) =>
          safeSemanticText(element) === '片段'),
        visibleMenuItemCount: visibleSemantics.filter((element) =>
          element.getAttribute('role') === 'menuitem').length,
        visibleDefaultSectionControlCount: visibleSemantics.filter((element) => {
          const value = safeSemanticText(element);
          return value.includes('默认工作区') &&
            (element.getAttribute('role') === 'button' ||
              element.getAttribute('role') === 'combobox' ||
              element.getAttribute('aria-haspopup') === 'listbox');
        }).length,
        visibleWorkspaceOptionCount: visibleSemantics.filter((element) =>
          localWorkspaceOptions.some((option) => safeSemanticText(element) === option)).length,
      };
      return {
        chooser: text.includes('Choose a workspace'),
        serverUrl: Boolean(document.querySelector('input[aria-label*="Server URL"]')),
        loginUsername: Boolean(document.querySelector('input[aria-label*="Email or username"]')),
        loginPassword: Boolean(document.querySelector('input[aria-label*="Master password"]')),
        loginAction: text.includes('Sign in and unlock'),
        loginActionDisabled: [...document.querySelectorAll('flt-semantics[role="button"]')]
          .some((element) => (element.innerText || element.getAttribute('aria-label') || '')
            .includes('Sign in and unlock') &&
            (element.getAttribute('aria-disabled') === 'true' || element.hasAttribute('disabled'))),
        ownerEmail: Boolean(document.querySelector('input[aria-label*="Owner email"]')),
        accountToken: Boolean(document.querySelector('input[aria-label*="One-time bootstrap token"]')),
        createOwnerAction: text.includes('Create owner account'),
        hostWorkspace: text.includes('Add host'),
        genericError: text.includes('Something went wrong') || text.includes('Unable to'),
        matchedStates: states.filter((state) => text.includes(state)),
        preferenceMenu,
      };
    }).catch(() => null) : null;
    await secondPage?.waitForTimeout(100).catch(() => {});
    const secondDeviceUi = secondPage ? await secondPage.evaluate((markers) => {
      const visibleText = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
      };
      const bodyText = document.body.innerText || '';
      const semanticText = [...document.querySelectorAll('flt-semantics')]
        .filter(visibleText)
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const allVisibleText = `${bodyText}\n${semanticText}`;
      const labels = [
        'Settings', 'Vaults', 'Open Vault', 'Choose vault', 'Hosts', 'Groups',
        'Credentials', 'Snippets', 'Sync & conflicts', 'Sync health', 'Sync now',
        'Syncing…', 'Command snippets', 'Workspace settings', 'Your server fleet',
        'Host groups', 'SSH credentials', 'Sync status', 'Outbox items',
        'Last pull', 'Open conflicts', 'Add host', 'Something went wrong',
        'Unable to', 'Sync error',
      ];
      const headings = [
        'Workspace settings', 'Your server fleet', 'Host groups',
        'SSH credentials', 'Command snippets', 'Sync health',
      ];
      const syncStates = [
        'Idle', 'Pending', 'Syncing', 'Read-only', 'Rebuilding snapshot',
        'Retry queued', 'Snapshot needed', 'Key update needed',
        'Device revoked', 'Sign in needed', 'Offline', 'Sync error',
      ];
      return {
        visibleBodyLabels: labels.filter((label) => bodyText.includes(label)),
        visibleSemanticLabels: labels.filter((label) => semanticText.includes(label)),
        activePageHeading: headings.find((heading) => allVisibleText.includes(heading)) ?? null,
        syncStatus: syncStates.find((status) => allVisibleText.includes(status)) ?? null,
        syncErrorVisible: allVisibleText.includes('Sync error') ||
          allVisibleText.includes('Something went wrong') ||
          allVisibleText.includes('Unable to'),
        unavailableEncryptedRecordsWarning: allVisibleText.includes(
          'encrypted record(s) could not be verified',
        ),
        unsupportedPreferenceWarning: allVisibleText.includes(
          'unsupported preference',
        ),
        migratedMarkersVisible: {
          host: allVisibleText.includes(markers.host),
          group: allVisibleText.includes(markers.group),
          snippet: allVisibleText.includes(markers.snippet),
          credential: allVisibleText.includes(markers.credential),
          credentialSecret: allVisibleText.includes(markers.secret),
        },
      };
    }, {
      host: HOST_NAME,
      group: GROUP_NAME,
      snippet: SNIPPET_NAME,
      credential: CREDENTIAL_NAME,
      secret: CREDENTIAL_SECRET,
    }).catch(() => null) : null;
    const routeStatuses = apiEvents.map((event) => {
      const path = event.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/g, '{id}');
      return `${event.method}:${path}:${event.status ?? 'pending'}`;
    });
    const requestDiagnostics = apiEvents
      .filter((event) => event.status === null)
      .map((event) => ({
        method: event.method,
        pathname: event.pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/g, '{id}'),
        requestfailed: event.failed,
        ageMs: Math.max(0, Date.now() - event.requestedAt),
      }));
    let targetDevicesDiagnostic = null;
    if (targetVaultId && ownerAccessToken) {
      try {
        const result = await directApi(
          appOrigin,
          'GET',
          `/api/v1/vaults/${encodeURIComponent(targetVaultId)}/devices`,
          ownerAccessToken,
        );
        const devices = result.body?.devices;
        targetDevicesDiagnostic = {
          directStatus: result.status,
          directDeviceCount: Array.isArray(devices) ? devices.length : -1,
          browserPending: requestDiagnostics.some((event) =>
            event.method === 'GET' && /\/vaults\/\{id\}\/devices$/.test(event.pathname)),
          browserRequestFailed: requestDiagnostics.some((event) =>
            event.method === 'GET' && /\/vaults\/\{id\}\/devices$/.test(event.pathname) &&
            event.requestfailed),
          browserPendingAgeMs: requestDiagnostics
            .filter((event) => event.method === 'GET' && /\/vaults\/\{id\}\/devices$/.test(event.pathname))
            .map((event) => event.ageMs),
        };
      } catch (_) {
        targetDevicesDiagnostic = { directProbeFailed: true };
      }
    }
    let membershipDiagnostic = null;
    if (targetVaultId && ownerAccessToken && migrationCreatePayload?.membership) {
      try {
        const result = await directApi(
          appOrigin,
          'GET',
          `/api/v1/vaults/${encodeURIComponent(targetVaultId)}/membership?from=0`,
          ownerAccessToken,
        );
        const expected = migrationCreatePayload.membership;
        const rows = result.body?.manifests;
        const row = Array.isArray(rows) ? rows[0] : null;
        const signed = row?.manifest;
        const expectedBody = expected?.manifest;
        const actualBody = signed?.manifest;
        const expectedSigned = {
          vault_id: migrationCreatePayload.vault_id,
          membership_version: expected?.membership_version,
          previous_digest: expected?.previous_digest,
          manifest: expectedBody,
          signature: expected?.signature,
        };
        membershipDiagnostic = {
          status: result.status,
          rowCount: Array.isArray(rows) ? rows.length : -1,
          signedWrapper: Boolean(signed && typeof signed === 'object' && !Array.isArray(signed)),
          topVersionEqual: row?.membership_version === expected?.membership_version,
          topPreviousDigestEqual: row?.previous_digest === expected?.previous_digest,
          topSignatureEqual: row?.signature === expected?.signature,
          signerEqual: row?.signer_device_id === expectedBody?.signer_device_id,
          signedVaultEqual: signed?.vault_id === migrationCreatePayload.vault_id,
          signedVersionEqual: signed?.membership_version === expected?.membership_version,
          signedPreviousDigestEqual: signed?.previous_digest === expected?.previous_digest,
          signedSignatureEqual: signed?.signature === expected?.signature,
          businessManifestEqual: stableJson(actualBody) === stableJson(expectedBody),
          completeSignedRecordEqual: stableJson(signed) === stableJson(expectedSigned),
        };
      } catch (_) {
        membershipDiagnostic = { readFailed: true };
      }
    }
    console.error(`WEB-LOCAL-MIGRATION-01 failed at stage=${stage}; error_type=${error?.name || 'unknown'}; api=${routeStatuses.join(',')}; pending_requests=${JSON.stringify(requestDiagnostics)}; target_devices=${JSON.stringify(targetDevicesDiagnostic)}; ui=${JSON.stringify(diagnostics)}; owner_snippet=${JSON.stringify(ownerSnippetEvidence)}; second_device_ui=${JSON.stringify(secondDeviceUi)}; second_device_sync_ui=${JSON.stringify(secondDeviceSyncUiEvidence)}; second_device_record_views=${JSON.stringify(secondDeviceRecordUiEvidence)}; second_device_settings=${JSON.stringify(secondDeviceSettingsEvidence)}; second_device_vault_position=${secondDeviceTargetVaultIndex + 1}; second_device_target_header_matches=${secondDeviceTargetHeaderMatches}; second_device_target_changes=${JSON.stringify(secondDeviceTargetChangesEvidence)}; second_device_preference=${JSON.stringify(secondDevicePreferenceEvidence)}; membership=${JSON.stringify(membershipDiagnostic)}; failed_pushes=${rejectedMigrationPushes}; page_errors=${pageErrors.length}`);
    process.exitCode = 1;
  } finally {
    await cleanup();
    if (cleanupFailed) {
      console.error('WEB-LOCAL-MIGRATION-01 cleanup failed');
      process.exitCode = 1;
    }
  }
}

main().catch(async (error) => {
  console.error(`WEB-LOCAL-MIGRATION-01 failed during initialization; error_type=${error?.name || 'unknown'}`);
  await cleanup();
  process.exitCode = 1;
});
