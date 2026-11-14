/*
 * Local profile browser acceptance: create an encrypted local profile, CRUD
 * Hosts, Credentials, Groups and Snippets, reload/unlock, explicitly clear the
 * browser origin through CDP, and verify local storage remains ciphertext-only
 * without making a server API request.
 */

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const PROFILE_PASSWORD = `LocalBrowser${crypto.randomBytes(18).toString('hex')}9`;
const TARGET_PROFILE_PASSWORD = `ImportBrowser${crypto.randomBytes(18).toString('hex')}7`;
const ARCHIVE_PASSWORD = `ArchiveBrowser${crypto.randomBytes(18).toString('hex')}5`;
const ORIGIN_CLEAR_PROFILE_PASSWORD = `OriginClear${crypto.randomBytes(18).toString('hex')}3`;
const POST_CLEAR_PROFILE_PASSWORD = `PostClear${crypto.randomBytes(18).toString('hex')}1`;
const HOST_NAME = `local-only-${RUN_ID}`;
const UPDATED_HOST_NAME = `${HOST_NAME}-updated`;
const ORIGIN_CLEAR_HOST_NAME = `before-origin-clear-${RUN_ID}`;
const POST_CLEAR_HOST_NAME = `after-origin-clear-${RUN_ID}`;
const HOST_ADDRESS = `local-${RUN_ID}.example.test`;
const ORIGIN_CLEAR_HOST_ADDRESS = `before-${RUN_ID}.example.test`;
const POST_CLEAR_HOST_ADDRESS = `after-${RUN_ID}.example.test`;
const HOST_USERNAME = `u-${RUN_ID.slice(0, 8)}`;
const ROOT_GROUP_NAME = `local-group-root-${RUN_ID}`;
const CHILD_GROUP_NAME = `local-group-child-${RUN_ID}`;
const UPDATED_CHILD_GROUP_NAME = `${CHILD_GROUP_NAME}-updated`;
const CREDENTIAL_NAME = `local-credential-${RUN_ID}`;
const UPDATED_CREDENTIAL_NAME = `${CREDENTIAL_NAME}-updated`;
const CREDENTIAL_USERNAME = `cu-${RUN_ID.slice(0, 8)}`;
const CREDENTIAL_SECRET = `CredentialSecret-${RUN_ID}`;
const SNIPPET_NAME = `local-snippet-${RUN_ID}`;
const UPDATED_SNIPPET_NAME = `${SNIPPET_NAME}-updated`;
const SNIPPET_BODY_SENTINEL = `snippet-body-${RUN_ID}`;
const UPDATED_SNIPPET_BODY_SENTINEL = `snippet-body-updated-${RUN_ID}`;
const TERMINAL_FONT_SIZE_PREFERENCE_VALUE = '16 px';
const TERMINAL_THEME_PREFERENCE_VALUE = 'Light';
const TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE = 'alt+shift+x';
const ORIGIN_CLEAR_PLAINTEXT_MARKERS = [
  HOST_NAME,
  UPDATED_HOST_NAME,
  HOST_ADDRESS,
  HOST_USERNAME,
  ROOT_GROUP_NAME,
  CHILD_GROUP_NAME,
  UPDATED_CHILD_GROUP_NAME,
  CREDENTIAL_NAME,
  UPDATED_CREDENTIAL_NAME,
  CREDENTIAL_USERNAME,
  CREDENTIAL_SECRET,
  SNIPPET_NAME,
  UPDATED_SNIPPET_NAME,
  SNIPPET_BODY_SENTINEL,
  UPDATED_SNIPPET_BODY_SENTINEL,
  ORIGIN_CLEAR_HOST_NAME,
  ORIGIN_CLEAR_HOST_ADDRESS,
  POST_CLEAR_HOST_NAME,
  POST_CLEAR_HOST_ADDRESS,
  'defaultSection',
  'terminalFontSize',
  'terminalTheme',
  'terminalShortcuts',
  '\"value\":\"16\"',
  '\"value\":\"light\"',
  `\"search\":\"${TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE}\"`,
  TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE,
];
let activeStage = 'setup';

function redactDiagnostic(value, extraSecrets = []) {
  let result = String(value);
  const secrets = [
    PROFILE_PASSWORD,
    TARGET_PROFILE_PASSWORD,
    ARCHIVE_PASSWORD,
    ORIGIN_CLEAR_PROFILE_PASSWORD,
    POST_CLEAR_PROFILE_PASSWORD,
    ...ORIGIN_CLEAR_PLAINTEXT_MARKERS,
    ...extraSecrets,
  ].filter(Boolean).sort((left, right) => right.length - left.length);
  for (const secret of secrets) result = result.split(secret).join('[redacted]');
  return result;
}

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function setActiveStage(stage) {
  activeStage = stage;
  process.stdout.write(`local-profile-stage: ${stage}\n`);
}

function mimeType(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  return ({
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
    '.css': 'text/css; charset=utf-8',
  })[extension] || 'application/octet-stream';
}

async function startStaticServer() {
  const server = http.createServer((request, response) => {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.writeHead(405).end();
      return;
    }
    let pathname;
    try {
      pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    } catch (_) {
      response.writeHead(400).end();
      return;
    }
    const relativePath = pathname === '/' ? 'index.html' : pathname.slice(1);
    const filePath = path.resolve(WEB_ROOT, relativePath);
    if (filePath !== WEB_ROOT && !filePath.startsWith(`${WEB_ROOT}${path.sep}`)) {
      response.writeHead(404).end();
      return;
    }
    fs.stat(filePath, (statError, stat) => {
      if (statError || !stat.isFile()) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, {
        'Content-Type': mimeType(filePath),
        'Cache-Control': 'no-store',
        'Content-Length': stat.size,
        'X-Content-Type-Options': 'nosniff',
      });
      if (request.method === 'HEAD') response.end();
      else fs.createReadStream(filePath).pipe(response);
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    server,
    baseUrl: `http://127.0.0.1:${server.address().port}`,
  };
}

async function activateAccessibilitySemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'visible', timeout: 20000 });
  await placeholder.evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 20000 });
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true });
  await locator.waitFor({ state: 'visible', timeout: 10000 });
  return locator;
}

async function enabledButton(page, label, timeout = 60000) {
  const locator = await button(page, label);
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await locator.isEnabled().catch(() => false)) return locator;
    await page.waitForTimeout(100);
  }
  throw new Error(`button remained disabled while local cleanup was pending: ${label}`);
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  return locator;
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 50 });
    await page.waitForTimeout(200);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`visible input for '${label}' did not retain value`);
}

async function terminalShortcutFieldDiagnostics(page) {
  return page.evaluate(() => {
    const label = '搜索终端历史';
    const isVisible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const inputControls = [...document.querySelectorAll('input, textarea')]
      .filter((element) =>
        (element.getAttribute('aria-label') || '').includes(label))
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          tag: element.tagName.toLowerCase(),
          type: element.getAttribute('type') || '',
          role: element.getAttribute('role') || '',
          ariaLabel: element.getAttribute('aria-label') || '',
          value: element.value || '',
          valueAttribute: element.getAttribute('value') || '',
          visible: isVisible(element),
          bounds: [Math.round(rect.x), Math.round(rect.y),
            Math.round(rect.width), Math.round(rect.height)],
        };
      });
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => isVisible(element))
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          role: element.getAttribute('role') || '',
          ariaLabel: element.getAttribute('aria-label') || '',
          ariaValueText: element.getAttribute('aria-valuetext') || '',
          text: (element.innerText || '').slice(0, 120),
          bounds: [Math.round(rect.x), Math.round(rect.y),
            Math.round(rect.width), Math.round(rect.height)],
        };
      })
      .filter((element) =>
        element.ariaLabel.includes(label) || element.text.includes(label))
      .slice(0, 12);
    const active = document.activeElement;
    const activeElement = active ? {
      tag: active.tagName.toLowerCase(),
      role: active.getAttribute('role') || '',
      ariaLabel: active.getAttribute('aria-label') || '',
      value: 'value' in active ? String(active.value || '') : '',
      outerHTML: active.outerHTML.slice(0, 500),
    } : null;
    const visibleTerminalText = (document.body.innerText || '')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => /终端|快捷键|默认工作区|16 px|Light|搜索终端历史/.test(line))
      .slice(0, 40);
    const canvases = [...document.querySelectorAll('canvas')].map((canvas) => {
      const rect = canvas.getBoundingClientRect();
      return {
        width: canvas.width,
        height: canvas.height,
        visible: isVisible(canvas),
        bounds: [Math.round(rect.x), Math.round(rect.y),
          Math.round(rect.width), Math.round(rect.height)],
      };
    });
    return {
      inputCount: inputControls.length,
      inputs: inputControls,
      semantics,
      activeElement,
      visibleTerminalText,
      canvases,
    };
  });
}

async function waitForFieldValue(page, label, value, context, timeout = 10000) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  );
  const matchCount = await locator.count();
  if (matchCount !== 1) {
    throw new Error(`${context}: expected one visible field for '${label}', found ${matchCount}`);
  }
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  // Flutter Web keeps a hidden/idle DOM text-editing input until the field is
  // focused. Clicking the unique semantic field synchronizes that input with
  // the rendered controller value before inputValue() is used as the oracle.
  await locator.click();
  await locator.focus();
  const deadline = Date.now() + timeout;
  let actual = await locator.inputValue().catch(() => '');
  while (Date.now() < deadline) {
    if (actual === value) return;
    await page.waitForTimeout(100);
    actual = await locator.inputValue().catch(() => '');
  }
  const diagnostics = label === '搜索终端历史'
    ? await terminalShortcutFieldDiagnostics(page).catch(() => null)
    : null;
  let screenshotPath = null;
  if (label === '搜索终端历史' && context.includes('archive import')) {
    screenshotPath = '/tmp/atermius-local-profile-shortcut-import.png';
    await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {
      screenshotPath = null;
    });
  }
  throw new Error(`${context}: field '${label}' was '${actual}' after reload/import; ` +
    `fieldDiagnostics=${JSON.stringify(diagnostics)}; screenshot=${screenshotPath || 'unavailable'}`);
}

async function saveEncryptedLocalPreference(page, buttonLabel) {
  await (await enabledButton(page, buttonLabel)).click();
  // This confirmation is emitted after the repository write has completed.
  await visibleText(page, '偏好已加密保存在此本地配置中。', 15000);
}

async function visibleText(page, text, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const visible = await page.evaluate((expected) => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body.innerText || ''}\n${semantics}`.includes(expected);
    }, text).catch(() => false);
    if (visible) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`expected visible UI text was not found: ${text}`);
}

async function waitForTextAbsent(page, text, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const visible = await page.evaluate((expected) => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      return `${document.body.innerText || ''}\n${semantics}`.includes(expected);
    }, text).catch(() => true);
    if (!visible) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`text did not disappear after the committed change: ${text}`);
}

async function tapSemanticButtonContaining(page, text) {
  const result = await page.evaluate((expected) => {
    const isVisibleMatch = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const label = `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`;
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0 &&
          label.includes(expected);
    };
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(isVisibleMatch);
    if (buttons.length === 1) {
      buttons[0].click();
      return { tapped: true, labels: [] };
    }
    // Flutter sometimes exposes tappable ListTile title semantics without a
    // button role. The text is still an actionable semantics node; choose its
    // smallest visible match to avoid clicking a containing list container.
    const textNodes = [...document.querySelectorAll('flt-semantics')]
      .filter(isVisibleMatch)
      .sort((left, right) => {
        const a = left.getBoundingClientRect();
        const b = right.getBoundingClientRect();
        return a.width * a.height - b.width * b.height;
      });
    if (textNodes.length === 0) return false;
    textNodes[0].click();
    return { tapped: true, labels: [] };
  }, text);
  if (!result?.tapped) {
    const visibleButtons = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .slice(0, 40));
    throw new Error(`visible semantics button not found: ${text}; visible buttons=${JSON.stringify(visibleButtons)}`);
  }
}

async function tapPreferenceDropdown(page, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const accessibleName = new RegExp(`^${escaped}(?:$|[,，\\s])`);
  const roleCandidates = [
    ['combobox', page.getByRole('combobox', { name: accessibleName })],
    ['button', page.getByRole('button', { name: accessibleName })],
    ['textbox', page.getByRole('textbox', { name: accessibleName })],
  ];
  const roleMatches = [];
  for (const [role, locator] of roleCandidates) {
    const count = await locator.count();
    if (count > 0) roleMatches.push({ role, locator, count });
  }
  const uniqueRoleMatches = roleMatches.filter((match) => match.count === 1);
  if (roleMatches.length === 1 && uniqueRoleMatches.length === 1) {
    await uniqueRoleMatches[0].locator.click();
    return;
  }
  if (roleMatches.length > 0) {
    throw new Error(`preference dropdown role/name was ambiguous for '${label}': ` +
      JSON.stringify(roleMatches.map(({ role, count }) => ({ role, count }))));
  }

  const result = await page.evaluate((expected) => {
    const isVisible = (element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    };
    const matches = [...document.querySelectorAll('flt-semantics')]
      .filter((element) => {
        if (!isVisible(element)) return false;
        const role = element.getAttribute('role') || '';
        const label = (element.getAttribute('aria-label') || element.innerText || '').trim();
        return ['button', 'combobox', 'textbox'].includes(role) &&
          label.startsWith(expected) && !label.startsWith('保存');
      });
    const candidates = [...document.querySelectorAll('flt-semantics')]
      .filter(isVisible)
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          role: element.getAttribute('role'),
          label: element.getAttribute('aria-label') || '',
          text: (element.innerText || '').slice(0, 120),
          bounds: [Math.round(rect.x), Math.round(rect.y),
            Math.round(rect.width), Math.round(rect.height)],
        };
      })
      .filter((candidate) => candidate.label.startsWith(expected) ||
        candidate.text.trim().startsWith(expected) ||
        candidate.label.includes(`保存${expected}`) || candidate.text.includes(`保存${expected}`))
      .slice(0, 12);
    if (matches.length !== 1) return { tapped: false, count: matches.length, candidates };
    matches[0].click();
    return { tapped: true, count: matches.length, candidates };
  }, label);
  if (!result.tapped) {
    throw new Error(`preference dropdown was not unique for '${label}': ` +
      `candidateCount=${result.count}; candidates=${JSON.stringify(result.candidates)}`);
  }
}

async function selectVisibleMenuItem(page, text) {
  const deadline = Date.now() + 10000;
  let lastDiagnostic = { count: 0, candidates: [] };
  while (Date.now() < deadline) {
    const menuItem = page.getByRole('menuitem', { name: text, exact: true });
    if (await menuItem.count() === 1 && await menuItem.isVisible().catch(() => false)) {
      await menuItem.click();
      return;
    }
    const result = await page.evaluate((expected) => {
      const isVisible = (element) => {
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
          // Exclude the always-visible workspace navigation button with the
          // same label as a dropdown option. Only the popup's exact option
          // node can be selected through this fallback.
          return role !== 'button' && isVisible(element) &&
            (innerText === expected || ariaLabel === expected);
        });
      const candidates = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => isVisible(element) &&
          `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`
            .includes(expected))
        .slice(0, 12)
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            role: element.getAttribute('role'),
            label: element.getAttribute('aria-label') || '',
            text: (element.innerText || '').slice(0, 120),
            bounds: [Math.round(rect.x), Math.round(rect.y),
              Math.round(rect.width), Math.round(rect.height)],
          };
        });
      if (matches.length !== 1) return { tapped: false, count: matches.length, candidates };
      matches[0].click();
      return { tapped: true, count: matches.length, candidates };
    }, text);
    lastDiagnostic = result;
    if (result.tapped) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`visible semantics menu item not found: ${text}; ` +
    `candidateCount=${lastDiagnostic.count}; candidates=${JSON.stringify(lastDiagnostic.candidates)}`);
}

async function waitForLocalProfileList(page, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const state = await page.evaluate(() => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const text = `${document.body.innerText || ''}\n${semantics}`;
      return {
        hasProfileList: text.includes('选择配置解锁'),
        empty: text.includes('还没有本地配置'),
        readError: text.includes('无法读取本地配置列表'),
      };
    }).catch(() => null);
    if (state?.hasProfileList) return;
    if (state?.empty || state?.readError) {
      throw new Error(`local profile catalog did not restore a profile: ${JSON.stringify(state)}`);
    }
    await page.waitForTimeout(100);
  }
  throw new Error('timed out waiting for local profile catalog to load');
}

async function scanLocalDatabaseStorage(page, markers, { missingProfileId = null } = {}) {
  return page.evaluate(async ({ searchMarkers, missingProfileId }) => {
    const names = typeof indexedDB.databases === 'function'
      ? (await indexedDB.databases()).map((database) => database.name).filter(Boolean)
      : [];
    const localNames = names.filter((name) =>
      name === 'atermius_profile_catalog' || name.startsWith('atermius_local_vault_'));
    const databaseBytes = new Map();
    for (const name of localNames) {
      const connection = await new Promise((resolve, reject) => {
        const request = indexedDB.open(name);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      const chunks = [];
      if (connection.objectStoreNames.contains('blocks')) {
        const blocks = await new Promise((resolve, reject) => {
          const request = connection.transaction('blocks', 'readonly')
            .objectStore('blocks').getAll();
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
        });
        const collect = async (value) => {
          if (typeof value === 'string') {
            chunks.push(value);
          } else if (value instanceof ArrayBuffer) {
            chunks.push(new TextDecoder().decode(value));
          } else if (ArrayBuffer.isView(value)) {
            chunks.push(new TextDecoder().decode(value));
          } else if (typeof Blob !== 'undefined' && value instanceof Blob) {
            chunks.push(new TextDecoder().decode(await value.arrayBuffer()));
          } else if (Array.isArray(value)) {
            for (const child of value) await collect(child);
          } else if (value && typeof value === 'object') {
            for (const child of Object.values(value)) await collect(child);
          }
        };
        for (const block of blocks) await collect(block);
      }
      databaseBytes.set(name, chunks.join(''));
      connection.close();
    }
    const catalogBytes = databaseBytes.get('atermius_profile_catalog') || '';
    const profileVaults = localNames
      .filter((name) => name.startsWith('atermius_local_vault_'))
      .map((name) => ({
        name,
        profileId: name.slice('atermius_local_vault_'.length),
        bytes: databaseBytes.get(name) || '',
      }));
    const webStorage = JSON.stringify({
      localStorage: Object.fromEntries(
        Array.from({ length: localStorage.length }, (_, index) => {
          const key = localStorage.key(index);
          return [key, key === null ? null : localStorage.getItem(key)];
        }),
      ),
      sessionStorage: Object.fromEntries(
        Array.from({ length: sessionStorage.length }, (_, index) => {
          const key = sessionStorage.key(index);
          return [key, key === null ? null : sessionStorage.getItem(key)];
        }),
      ),
    });
    return {
      localDatabaseNames: localNames,
      serverDatabaseAbsent: !names.includes('atermius_vault'),
      profileIds: profileVaults.map((profile) => profile.profileId),
      profileIdsInCatalog: profileVaults.every((profile) =>
        catalogBytes.includes(profile.profileId)),
      catalogContainsMissingProfile: missingProfileId === null ||
        catalogBytes.includes(missingProfileId),
      vaultBindingChecks: profileVaults.map((profile) => ({
        profileId: profile.profileId,
        bound: profile.bytes.includes(profile.profileId),
      })),
      plaintextMarkersFound: searchMarkers.filter((marker) =>
        [...databaseBytes.values(), webStorage].some((contents) => contents.includes(marker))),
    };
  }, { searchMarkers: markers, missingProfileId });
}

async function assertEncryptedBrowserStorage(page, { missingProfileId = null } = {}) {
  const storage = await scanLocalDatabaseStorage(page, ORIGIN_CLEAR_PLAINTEXT_MARKERS, { missingProfileId });
  assertThat(storage.serverDatabaseAbsent, 'local mode opened the server Vault database');
  assertThat(
    storage.localDatabaseNames.length === storage.profileIds.length + 1 &&
      storage.profileIds.length > 0,
    'local mode did not open one catalog and one LocalVault database per profile',
  );
  assertThat(storage.profileIdsInCatalog, 'local profile metadata was not persisted in the catalog database');
  assertThat(storage.catalogContainsMissingProfile, 'fail-closed profile was removed from its catalog');
  assertThat(
    storage.vaultBindingChecks.every((profile) =>
      profile.profileId === missingProfileId ? !profile.bound : profile.bound),
    missingProfileId === null
      ? 'a LocalVault profile binding was not persisted'
      : 'missing LocalVault was silently rebound as a new profile',
  );
  assertThat(
    storage.plaintextMarkersFound.length === 0,
    'a Host, Credential, Snippet, or preference plaintext marker was present in browser storage',
  );
}

async function assertOriginClearState(page, oldProfileIds, plaintextMarkers) {
  const state = await page.evaluate(async ({ oldIds, markers }) => {
    const databaseNames = typeof indexedDB.databases === 'function'
      ? (await indexedDB.databases()).map((database) => database.name).filter(Boolean)
      : [];
    const databaseTexts = [];
    for (const name of databaseNames) {
      const database = await new Promise((resolve, reject) => {
        const request = indexedDB.open(name);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      if (database.objectStoreNames.contains('blocks')) {
        const values = await new Promise((resolve, reject) => {
          const request = database.transaction('blocks', 'readonly')
            .objectStore('blocks').getAll();
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
        });
        const collect = async (value, chunks) => {
          if (typeof value === 'string') chunks.push(value);
          else if (value instanceof ArrayBuffer) chunks.push(new TextDecoder().decode(value));
          else if (ArrayBuffer.isView(value)) chunks.push(new TextDecoder().decode(value));
          else if (typeof Blob !== 'undefined' && value instanceof Blob) {
            chunks.push(new TextDecoder().decode(await value.arrayBuffer()));
          } else if (Array.isArray(value)) {
            for (const child of value) await collect(child, chunks);
          } else if (value && typeof value === 'object') {
            for (const child of Object.values(value)) await collect(child, chunks);
          }
        };
        const chunks = [];
        for (const value of values) await collect(value, chunks);
        databaseTexts.push(chunks.join(''));
      }
      database.close();
    }
    const serializedDatabases = databaseTexts.join('\n');
    const localAndSessionStorage = JSON.stringify({
      localStorage: Object.fromEntries(Array.from({ length: localStorage.length }, (_, i) => {
        const key = localStorage.key(i);
        return [key, key === null ? null : localStorage.getItem(key)];
      })),
      sessionStorage: Object.fromEntries(Array.from({ length: sessionStorage.length }, (_, i) => {
        const key = sessionStorage.key(i);
        return [key, key === null ? null : sessionStorage.getItem(key)];
      })),
    });
    const caches = typeof window.caches?.keys === 'function' ? await window.caches.keys() : [];
    const serviceWorkers = typeof navigator.serviceWorker?.getRegistrations === 'function'
      ? await navigator.serviceWorker.getRegistrations()
      : [];
    const text = `${document.body.innerText || ''}\n${serializedDatabases}\n${localAndSessionStorage}`;
    return {
      databaseNames,
      hasLocalVault: databaseNames.some((name) => name.startsWith('atermius_local_vault_')),
      oldProfileIdsFound: oldIds.filter((profileId) => text.includes(profileId)),
      plaintextMarkersFound: markers.filter((marker) => text.includes(marker)),
      localStorageCount: localStorage.length,
      sessionStorageCount: sessionStorage.length,
      cacheNames: caches,
      serviceWorkerCount: serviceWorkers.length,
      cookie: document.cookie,
      emptyCatalogVisible: (document.body.innerText || '').includes('还没有本地配置'),
    };
  }, { oldIds: oldProfileIds, markers: plaintextMarkers });

  assertThat(state.emptyCatalogVisible, 'origin clear did not restore the honest empty local-profile state');
  assertThat(!state.hasLocalVault, `origin clear left a LocalVault database: ${JSON.stringify(state.databaseNames)}`);
  assertThat(
    state.databaseNames.every((name) => name === 'atermius_profile_catalog'),
    `origin clear left unexpected IndexedDB databases: ${JSON.stringify(state.databaseNames)}`,
  );
  assertThat(state.oldProfileIdsFound.length === 0,
    `origin clear left old profile IDs in browser data: ${JSON.stringify(state.oldProfileIdsFound)}`);
  assertThat(state.plaintextMarkersFound.length === 0,
    `origin clear left old record plaintext in browser data: ${JSON.stringify(state.plaintextMarkersFound)}`);
  assertThat(state.localStorageCount === 0 && state.sessionStorageCount === 0,
    'origin clear left Web Storage entries');
  assertThat(state.cacheNames.length === 0, `origin clear left Cache Storage entries: ${JSON.stringify(state.cacheNames)}`);
  assertThat(state.serviceWorkerCount === 0, 'origin clear left a service-worker registration');
  assertThat(state.cookie === '', 'origin clear left an origin cookie');
}

async function waitForHostSave(page, hostName) {
  const stateFor = () => page.evaluate((name) => {
    const semanticText = [...document.querySelectorAll('flt-semantics')]
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const text = `${document.body.innerText || ''}\n${semanticText}`;
    const editorVisible = text.includes('添加本地 Host') || text.includes('编辑本地 Host');
    return {
      hostVisible: text.includes(name) && !editorVisible,
      editorVisible,
      saveFailed: text.includes('保存 Host 失败'),
      validation: ['Host name is required', 'Host address is required',
        'Username is required', 'Port must be between 1 and 65535']
        .find((message) => text.includes(message)) || null,
    };
  }, hostName);
  const deadline = Date.now() + 30000;
  let state = await stateFor();
  while (Date.now() < deadline && !state.hostVisible && !state.saveFailed && !state.validation) {
    await page.waitForTimeout(100);
    state = await stateFor();
  }
  if (!state.hostVisible) {
    throw new Error(`Host save did not complete (${JSON.stringify(state)})`);
  }
}

async function assertCredentialSecretNotVisible(page) {
  const visible = await page.evaluate((secret) => {
    const semanticText = [...document.querySelectorAll('flt-semantics')]
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    const bodyText = document.body.innerText || '';
    return bodyText.includes(secret) || semanticText.includes(secret);
  }, CREDENTIAL_SECRET);
  assertThat(!visible, 'credential secret appeared in visible Web UI text');
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function archiveWithVersion(container, version) {
  assertThat(container.toString('ascii', 0, 8) === 'ATLOCAL1', 'archive magic was not recognized');
  const headerLength = container.readUInt32BE(8);
  const oldBodyStart = 12 + headerLength;
  const header = JSON.parse(container.subarray(12, oldBodyStart).toString('utf8'));
  header.version = version;
  const headerBytes = Buffer.from(canonicalJson(header), 'utf8');
  const headerLengthBytes = Buffer.alloc(4);
  headerLengthBytes.writeUInt32BE(headerBytes.length);
  return Buffer.concat([
    Buffer.from('ATLOCAL1', 'ascii'),
    headerLengthBytes,
    headerBytes,
    container.subarray(oldBodyStart),
  ]);
}

async function chooseArchiveAndSubmitPassword(page, archivePath, password) {
  const fileChooserPromise = page.waitForEvent('filechooser', { timeout: 15000 });
  await (await button(page, '导入本地加密归档')).click();
  const fileChooser = await fileChooserPromise;
  await fileChooser.setFiles(archivePath);
  await visibleText(page, '输入本地归档口令');
  await fill(page, '本地归档口令', password);
  await (await button(page, '继续')).click();
}

async function assertEmptyImportedWorkspaces(page) {
  await visibleText(page, '还没有 Host');
  await (await button(page, '凭据')).click();
  await visibleText(page, '还没有凭据');
  await (await button(page, '分组')).click();
  await visibleText(page, '还没有分组');
  await (await button(page, '片段')).click();
  await visibleText(page, '还没有片段');
  await (await button(page, '偏好设置')).click();
  await visibleText(page, '默认工作区');
  await visibleText(page, '主机');
  await (await button(page, 'Host')).click();
  await visibleText(page, '还没有 Host');
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Web release is incomplete');
  }

  let context;
  let page;
  let staticServer;
  const archiveTestDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-local-profile-archive-'));
  const browserProfileDirectory = path.join(archiveTestDirectory, 'chromium-user-data');
  const sourceArchivePath = path.join(archiveTestDirectory, 'source.atlocal');
  let sourceProfileId;
  let targetProfileId;
  let originClearProfileId;
  let postClearProfileId;
  const apiRequests = [];
  const remoteRequests = [];
  const pageErrors = [];

  try {
    staticServer = await startStaticServer();
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    const persistentOptions = {
      ...launchOptions,
      locale: 'zh-CN',
      viewport: { width: 1280, height: 900 },
    };
    context = await chromium.launchPersistentContext(browserProfileDirectory, persistentOptions);
    const observeContextRequests = (observedContext) => observedContext.on('request', (request) => {
      const url = new URL(request.url());
      if (url.origin !== staticServer.baseUrl) remoteRequests.push(`${url.origin}${url.pathname}`);
      if (/^\/(api|auth|sync)(\/|$)/.test(url.pathname)) {
        apiRequests.push(`${request.method()} ${url.pathname}`);
      }
    });
    const observePageErrors = (observedPage) => observedPage.on('pageerror', () => pageErrors.push('page-error'));
    observeContextRequests(context);
    page = await context.newPage();
    observePageErrors(page);

    setActiveStage('initial mode selection');
    await page.goto(staticServer.baseUrl, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace');
    await (await button(page, 'Open locally')).click();
    await visibleText(page, '还没有本地配置');
    await visibleText(page, '暂不支持跨设备同步');

    setActiveStage('create local profile');
    await fill(page, '主密码', PROFILE_PASSWORD);
    await (await button(page, '创建并解锁')).click();
    await visibleText(page, '还没有 Host', 90000);
    await visibleText(page, 'Web LocalVault 暂不支持 SSH / SFTP');
    await visibleText(page, '浏览器中的 LocalVault 可在本地加密管理 Host 和凭据');
    await button(page, '返回工作区选择');

    setActiveStage('create hierarchical encrypted Groups');
    await (await button(page, '分组')).click();
    await visibleText(page, '还没有分组');
    await (await button(page, '添加分组')).click();
    await fill(page, '分组名称', ROOT_GROUP_NAME);
    await (await button(page, '保存分组')).click();
    await visibleText(page, ROOT_GROUP_NAME);
    await (await button(page, '添加分组')).click();
    await fill(page, '分组名称', CHILD_GROUP_NAME);
    await tapSemanticButtonContaining(page, '父级分组');
    await selectVisibleMenuItem(page, ROOT_GROUP_NAME);
    await (await button(page, '保存分组')).click();
    await visibleText(page, CHILD_GROUP_NAME);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('edit encrypted Group');
    await tapSemanticButtonContaining(page, `分组操作：${CHILD_GROUP_NAME}`);
    await selectVisibleMenuItem(page, '编辑分组');
    await visibleText(page, '编辑本地分组');
    await fill(page, '分组名称', UPDATED_CHILD_GROUP_NAME);
    await (await button(page, '保存分组')).click();
    await visibleText(page, UPDATED_CHILD_GROUP_NAME);
    await assertEncryptedBrowserStorage(page);

    // The selected Groups action returns to Hosts so the Host can be assigned
    // to the child Group from the same encrypted LocalVault.
    await (await button(page, 'Host')).click();

    setActiveStage('create Host');
    await (await button(page, '添加 Host')).click();
    await fill(page, '名称', HOST_NAME);
    await fill(page, '主机名或 IP', HOST_ADDRESS);
    await fill(page, 'SSH 用户名', HOST_USERNAME);
    await tapSemanticButtonContaining(page, '不属于分组');
    await selectVisibleMenuItem(page, UPDATED_CHILD_GROUP_NAME);
    await fill(page, '标签', 'browser, local');
    await (await button(page, '保存加密 Host')).click();
    await waitForHostSave(page, HOST_NAME);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('verify Web LocalVault Host actions do not offer browser SSH');
    await tapSemanticButtonContaining(page, 'Host 操作');
    const editHostMenuItem = page.getByRole('menuitem', {
      name: '编辑',
      exact: true,
    });
    await editHostMenuItem.waitFor({ state: 'visible', timeout: 10000 });
    const browserConnectItems = page.getByRole('menuitem', {
      name: /^连接（本机直连）$|^连接（本机跳板）$/,
    });
    assertThat(await browserConnectItems.count() === 0,
      'Web LocalVault exposed a browser SSH connection action');

    // Edit the Host from its action menu, then persist an updated name before reload.
    setActiveStage('edit Host');
    await selectVisibleMenuItem(page, '编辑');
    await visibleText(page, '编辑本地 Host');
    await fill(page, '名称', UPDATED_HOST_NAME);
    await (await button(page, '保存加密 Host')).click();
    await visibleText(page, UPDATED_HOST_NAME);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('create and edit encrypted local Credential');
    await (await button(page, '凭据')).click();
    await visibleText(page, '还没有凭据');
    await (await button(page, '添加凭据')).click();
    await fill(page, '凭据名称', CREDENTIAL_NAME);
    await fill(page, '用户名', CREDENTIAL_USERNAME);
    await fill(page, '密码', CREDENTIAL_SECRET);
    await (await button(page, '保存加密凭据')).click();
    await visibleText(page, CREDENTIAL_NAME);
    await assertCredentialSecretNotVisible(page);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('create and edit encrypted local Snippet');
    await (await button(page, '片段')).click();
    await visibleText(page, '还没有片段');
    await visibleText(page, '本地模式只管理加密片段');
    await (await button(page, '添加片段')).click();
    await fill(page, '片段标题', SNIPPET_NAME);
    await fill(page, '脚本正文', `printf "${SNIPPET_BODY_SENTINEL}"`);
    await fill(page, '标签（逗号分隔）', 'browser, encrypted');
    await (await button(page, '保存加密片段')).click();
    await visibleText(page, SNIPPET_NAME);
    await waitForTextAbsent(page, SNIPPET_BODY_SENTINEL);
    await assertEncryptedBrowserStorage(page);

    // The per-Snippet action button includes the title in its tooltip, so use
    // the unique subtitle tags to target the tappable list row for editing.
    await tapSemanticButtonContaining(page, 'browser, encrypted');
    await visibleText(page, '编辑本地片段');
    await fill(page, '片段标题', UPDATED_SNIPPET_NAME);
    await fill(page, '脚本正文', `echo "${UPDATED_SNIPPET_BODY_SENTINEL}"`);
    await (await button(page, '保存加密片段')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME);
    await waitForTextAbsent(page, UPDATED_SNIPPET_BODY_SENTINEL);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('switch to Credential workspace after Snippet edit');
    await (await button(page, '凭据')).click();
    await visibleText(page, '添加凭据');
    setActiveStage('edit encrypted local Credential');
    await tapSemanticButtonContaining(page, CREDENTIAL_NAME);
    await visibleText(page, '编辑本地凭据');
    await fill(page, '凭据名称', UPDATED_CREDENTIAL_NAME);
    // A blank secret on edit preserves the existing encrypted secret.
    await (await button(page, '保存加密凭据')).click();
    await visibleText(page, UPDATED_CREDENTIAL_NAME);
    await assertCredentialSecretNotVisible(page);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('save encrypted LocalVault preferences');
    await (await button(page, '偏好设置')).click();
    await visibleText(page, '默认工作区');
    await tapPreferenceDropdown(page, '默认工作区');
    await selectVisibleMenuItem(page, '片段');
    await (await button(page, '保存默认工作区')).click();
    await visibleText(page, '偏好已保存并应用。', 15000);
    await visibleText(page, '命令片段');
    await (await button(page, '偏好设置')).click();
    await visibleText(page, '终端字号');

    await tapPreferenceDropdown(page, '终端字体大小');
    await selectVisibleMenuItem(page, TERMINAL_FONT_SIZE_PREFERENCE_VALUE);
    await saveEncryptedLocalPreference(page, '保存终端字号');
    await visibleText(page, TERMINAL_FONT_SIZE_PREFERENCE_VALUE);

    await tapPreferenceDropdown(page, '终端配色');
    await selectVisibleMenuItem(page, TERMINAL_THEME_PREFERENCE_VALUE);
    await saveEncryptedLocalPreference(page, '保存终端主题');
    await visibleText(page, TERMINAL_THEME_PREFERENCE_VALUE);

    await fill(page, '搜索终端历史', TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE);
    await saveEncryptedLocalPreference(page, '保存快捷键');
    assertThat(
      await (await field(page, '搜索终端历史')).inputValue() ===
        TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE,
      'saved local terminal search shortcut did not remain selected',
    );
    await assertEncryptedBrowserStorage(page);
    await (await button(page, 'Host')).click();
    await visibleText(page, UPDATED_HOST_NAME);

    setActiveStage('export encrypted Local-only profile archive');
    const archiveDownloadPromise = page.waitForEvent('download', {
      timeout: 30000,
    });
    await (await button(page, '导出本地加密归档')).click();
    await visibleText(page, '设置本地归档口令');
    await fill(page, '本地归档口令', ARCHIVE_PASSWORD);
    await fill(page, '确认本地归档口令', ARCHIVE_PASSWORD);
    await (await button(page, '继续')).click();
    const archiveDownload = await archiveDownloadPromise;
    await archiveDownload.saveAs(sourceArchivePath);
    const sourceArchive = fs.readFileSync(sourceArchivePath);
    assertThat(sourceArchive.toString('ascii', 0, 8) === 'ATLOCAL1', 'exported archive did not use the Local profile format');
    for (const marker of [UPDATED_HOST_NAME, HOST_ADDRESS, CREDENTIAL_SECRET,
      UPDATED_SNIPPET_BODY_SENTINEL, ROOT_GROUP_NAME, UPDATED_CHILD_GROUP_NAME,
      'terminalFontSize', 'terminalTheme', 'terminalShortcuts',
      '\"value\":\"16\"', '\"value\":\"light\"',
      `\"search\":\"${TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE}\"`,
      TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE]) {
      assertThat(!sourceArchive.includes(Buffer.from(marker)), `exported archive exposed plaintext marker: ${marker}`);
    }
    sourceProfileId = await page.evaluate(async () => {
      const names = (await indexedDB.databases()).map((database) => database.name || '');
      const vault = names.find((name) => name.startsWith('atermius_local_vault_'));
      return vault ? vault.slice('atermius_local_vault_'.length) : '';
    });
    assertThat(sourceProfileId.length > 0, 'source LocalVault profile ID was not found');
    await assertEncryptedBrowserStorage(page);

    setActiveStage('create an independent empty target profile');
    await (await button(page, '锁定配置')).click();
    await (await enabledButton(page, '创建并解锁')).waitFor({ state: 'visible' });
    await waitForLocalProfileList(page);
    await fill(page, '主密码', TARGET_PROFILE_PASSWORD);
    await (await button(page, '创建并解锁')).click();
    await visibleText(page, '还没有 Host', 90000);
    targetProfileId = await page.evaluate(async (sourceId) => {
      const names = (await indexedDB.databases()).map((database) => database.name || '');
      const profileIds = names.filter((name) => name.startsWith('atermius_local_vault_'))
        .map((name) => name.slice('atermius_local_vault_'.length));
      return profileIds.find((profileId) => profileId !== sourceId) || '';
    }, sourceProfileId);
    assertThat(targetProfileId.length > 0 && targetProfileId !== sourceProfileId,
      'new target profile did not receive an independent LocalVault');
    await assertEncryptedBrowserStorage(page);

    const badArchiveCases = [
      {
        name: 'wrong password',
        file: 'wrong-password.atlocal',
        bytes: sourceArchive,
        password: `WrongArchive${crypto.randomBytes(12).toString('hex')}7`,
      },
      {
        name: 'tampered ciphertext',
        file: 'tampered.atlocal',
        bytes: (() => {
          const copy = Buffer.from(sourceArchive);
          copy[copy.length - 1] ^= 1;
          return copy;
        })(),
        password: ARCHIVE_PASSWORD,
      },
      {
        name: 'truncated container',
        file: 'truncated.atlocal',
        bytes: sourceArchive.subarray(0, sourceArchive.length - 1),
        password: ARCHIVE_PASSWORD,
      },
      {
        name: 'unknown container version',
        file: 'unknown-version.atlocal',
        bytes: archiveWithVersion(sourceArchive, 2),
        password: ARCHIVE_PASSWORD,
      },
    ];
    for (const badCase of badArchiveCases) {
      setActiveStage(`reject ${badCase.name} without partial import`);
      const badArchivePath = path.join(archiveTestDirectory, badCase.file);
      fs.writeFileSync(badArchivePath, badCase.bytes);
      await chooseArchiveAndSubmitPassword(page, badArchivePath, badCase.password);
      await visibleText(page, '无法导入本地归档；目标配置没有部分写入。');
      await visibleText(page, '还没有 Host');
      await assertEncryptedBrowserStorage(page);
    }
    await assertEmptyImportedWorkspaces(page);

    setActiveStage('import verified Local-only archive into the new profile');
    await chooseArchiveAndSubmitPassword(page, sourceArchivePath, ARCHIVE_PASSWORD);
    await visibleText(page, UPDATED_SNIPPET_NAME, 90000);
    await assertEncryptedBrowserStorage(page);
    await (await button(page, 'Host')).click();
    await visibleText(page, UPDATED_HOST_NAME);
    await (await button(page, '凭据')).click();
    await visibleText(page, UPDATED_CREDENTIAL_NAME);
    await assertCredentialSecretNotVisible(page);
    await (await button(page, '分组')).click();
    await visibleText(page, ROOT_GROUP_NAME);
    await visibleText(page, UPDATED_CHILD_GROUP_NAME);
    await (await button(page, '片段')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME);
    await waitForTextAbsent(page, UPDATED_SNIPPET_BODY_SENTINEL);
    await (await button(page, '偏好设置')).click();
    await visibleText(page, '默认工作区');
    await visibleText(page, '片段');
    await visibleText(page, TERMINAL_FONT_SIZE_PREFERENCE_VALUE);
    await visibleText(page, TERMINAL_THEME_PREFERENCE_VALUE);
    await waitForFieldValue(
      page,
      '搜索终端历史',
      TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE,
      'terminal shortcut after archive import',
    );
    await assertEncryptedBrowserStorage(page);

    // The original profile remains independently decryptable and unchanged
    // after importing its archive into a second profile.
    setActiveStage('verify original profile remains unchanged after archive import');
    await (await button(page, '锁定配置')).click();
    await waitForLocalProfileList(page);
    await tapSemanticButtonContaining(page, `本地配置 · ${sourceProfileId.slice(0, 8)}`);
    await fill(page, '本地配置主密码', PROFILE_PASSWORD);
    await (await button(page, '解锁本地配置')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME, 90000);
    await assertEncryptedBrowserStorage(page);
    await (await button(page, 'Host')).click();
    await visibleText(page, UPDATED_HOST_NAME);
    await (await button(page, '凭据')).click();
    await visibleText(page, UPDATED_CREDENTIAL_NAME);
    await (await button(page, '分组')).click();
    await visibleText(page, UPDATED_CHILD_GROUP_NAME);
    await (await button(page, '片段')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME);

    // Lock before navigation, then prove the profile catalog, encrypted
    // records and imported workspace/terminal preferences survive reload.
    setActiveStage('lock and reload');
    await (await button(page, '锁定配置')).click();
    await (await enabledButton(page, '创建并解锁')).waitFor({ state: 'visible' });
    await waitForLocalProfileList(page);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace');
    await (await button(page, 'Open locally')).click();
    await waitForLocalProfileList(page);
    await tapSemanticButtonContaining(page, `本地配置 · ${targetProfileId.slice(0, 8)}`);
    await fill(page, '本地配置主密码', TARGET_PROFILE_PASSWORD);
    await (await button(page, '解锁本地配置')).click();
    setActiveStage('unlock and restore configured Snippets workspace');
    await visibleText(page, '命令片段');
    await visibleText(page, UPDATED_SNIPPET_NAME);
    await assertEncryptedBrowserStorage(page);
    setActiveStage('restore encrypted terminal preferences after lock and reload');
    await (await button(page, '偏好设置')).click();
    await visibleText(page, '默认工作区');
    await visibleText(page, TERMINAL_FONT_SIZE_PREFERENCE_VALUE);
    await visibleText(page, TERMINAL_THEME_PREFERENCE_VALUE);
    await waitForFieldValue(
      page,
      '搜索终端历史',
      TERMINAL_SEARCH_SHORTCUT_PREFERENCE_VALUE,
      'terminal shortcut after lock/reload/unlock',
    );
    await assertEncryptedBrowserStorage(page);
    await (await button(page, '片段')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME);
    await (await button(page, '分组')).click();
    await visibleText(page, ROOT_GROUP_NAME);
    await visibleText(page, UPDATED_CHILD_GROUP_NAME);
    await assertEncryptedBrowserStorage(page);
    await (await button(page, '片段')).click();
    await visibleText(page, UPDATED_SNIPPET_NAME);
    await waitForTextAbsent(page, UPDATED_SNIPPET_BODY_SENTINEL);
    await assertEncryptedBrowserStorage(page);
    setActiveStage('delete local Snippet');
    await tapSemanticButtonContaining(page, `片段操作：${UPDATED_SNIPPET_NAME}`);
    await selectVisibleMenuItem(page, '删除片段');
    await visibleText(page, '删除片段？');
    await (await button(page, '删除')).click();
    await visibleText(page, '还没有片段');
    await assertEncryptedBrowserStorage(page);
    await (await button(page, '凭据')).click();
    await visibleText(page, UPDATED_CREDENTIAL_NAME);
    await assertCredentialSecretNotVisible(page);
    await assertEncryptedBrowserStorage(page);

    setActiveStage('delete local Credential');
    await (await button(page, '凭据操作')).click();
    await selectVisibleMenuItem(page, '删除凭据');
    await visibleText(page, '删除凭据？');
    await (await button(page, '删除')).click();
    await visibleText(page, '还没有凭据');
    await assertEncryptedBrowserStorage(page);

    setActiveStage('protect referenced Group deletion');
    await (await button(page, '凭据')).click();
    await (await button(page, '分组')).click();
    await (await button(page, `分组操作：${UPDATED_CHILD_GROUP_NAME}`)).click();
    await selectVisibleMenuItem(page, '删除分组');
    await visibleText(page, '删除分组？');
    await (await button(page, '删除')).click();
    await visibleText(page, '分组仍被子分组或 Host 使用');

    setActiveStage('unlink Host and delete Groups');
    await (await button(page, '凭据')).click();
    await (await button(page, 'Host')).click();
    await visibleText(page, UPDATED_HOST_NAME);
    await tapSemanticButtonContaining(page, 'Host 操作');
    await selectVisibleMenuItem(page, '删除');
    await visibleText(page, '删除 Host？');
    await (await button(page, '删除')).click();
    await waitForTextAbsent(page, UPDATED_HOST_NAME);
    await (await button(page, '分组')).click();
    await visibleText(page, ROOT_GROUP_NAME);
    for (const groupName of [UPDATED_CHILD_GROUP_NAME, ROOT_GROUP_NAME]) {
      await (await button(page, `分组操作：${groupName}`)).click();
      await selectVisibleMenuItem(page, '删除分组');
      await visibleText(page, '删除分组？');
      await (await button(page, '删除')).click();
      await waitForTextAbsent(page, groupName);
    }
    await visibleText(page, '还没有分组');
    await assertEncryptedBrowserStorage(page);

    // Keep one independent encrypted LocalVault populated while the origin
    // clear is prepared. The source LocalVault failure scenario below remains
    // intact and is completed before the whole-origin clear.
    setActiveStage('persist LocalProfile and LocalVault before explicit origin clear');
    await (await button(page, '锁定配置')).click();
    await waitForLocalProfileList(page);
    await fill(page, '主密码', ORIGIN_CLEAR_PROFILE_PASSWORD);
    await (await button(page, '创建并解锁')).click();
    await visibleText(page, '还没有 Host', 90000);
    originClearProfileId = await page.evaluate(async (knownIds) => {
      const names = (await indexedDB.databases()).map((database) => database.name || '');
      const profileIds = names.filter((name) => name.startsWith('atermius_local_vault_'))
        .map((name) => name.slice('atermius_local_vault_'.length));
      return profileIds.find((profileId) => !knownIds.includes(profileId)) || '';
    }, [sourceProfileId, targetProfileId]);
    assertThat(originClearProfileId && ![sourceProfileId, targetProfileId].includes(originClearProfileId),
      'pre-clear LocalVault did not receive a new profile ID');
    await (await button(page, '添加 Host')).click();
    await fill(page, '名称', ORIGIN_CLEAR_HOST_NAME);
    await fill(page, '主机名或 IP', ORIGIN_CLEAR_HOST_ADDRESS);
    await fill(page, 'SSH 用户名', HOST_USERNAME);
    await (await button(page, '保存加密 Host')).click();
    await waitForHostSave(page, ORIGIN_CLEAR_HOST_NAME);
    await assertEncryptedBrowserStorage(page);

    // Confirm this record survives a page reload and unlock in the same
    // persistent Chromium profile before clearing origin storage.
    await (await button(page, '锁定配置')).click();
    await waitForLocalProfileList(page);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace');
    await (await button(page, 'Open locally')).click();
    await waitForLocalProfileList(page);
    await tapSemanticButtonContaining(page, `本地配置 · ${originClearProfileId.slice(0, 8)}`);
    await fill(page, '本地配置主密码', ORIGIN_CLEAR_PROFILE_PASSWORD);
    await (await button(page, '解锁本地配置')).click();
    await visibleText(page, ORIGIN_CLEAR_HOST_NAME, 90000);
    await assertEncryptedBrowserStorage(page);
    await (await button(page, '锁定配置')).click();
    await waitForLocalProfileList(page);

    // Removing the encrypted Vault while preserving its catalog must not
    // initialize a new empty Vault on the next unlock attempt.
    setActiveStage('fail closed when the LocalVault database is missing');
    await (await enabledButton(page, '创建并解锁')).waitFor({ state: 'visible' });
    await waitForLocalProfileList(page);
    const deletedVaultName = await page.evaluate(async (profileId) => {
      const databases = await indexedDB.databases();
      const target = databases.find((database) =>
        database.name === `atermius_local_vault_${profileId}`,
      );
      if (!target?.name) throw new Error('encrypted LocalVault database was not found');
      await new Promise((resolve, reject) => {
        const request = indexedDB.deleteDatabase(target.name);
        request.onsuccess = resolve;
        request.onerror = () => reject(request.error);
        request.onblocked = () => reject(new Error('LocalVault deletion was blocked'));
      });
      return target.name;
    }, sourceProfileId);
    assertThat(deletedVaultName === `atermius_local_vault_${sourceProfileId}`, 'deleted the wrong browser database');
    const sourceVaultAbsentBeforeUnlock = await page.evaluate(async (profileId) =>
      !(await indexedDB.databases()).some((database) =>
        database.name === `atermius_local_vault_${profileId}`));
    assertThat(sourceVaultAbsentBeforeUnlock,
      'source LocalVault remained present after the isolated deletion');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace');
    await (await button(page, 'Open locally')).click();
    await waitForLocalProfileList(page);
    await tapSemanticButtonContaining(page, `本地配置 · ${sourceProfileId.slice(0, 8)}`);
    await fill(page, '本地配置主密码', PROFILE_PASSWORD);
    await (await button(page, '解锁本地配置')).click();
    await visibleText(page, '本地配置数据缺失或无法读取');
    await visibleText(page, '选择配置解锁');
    await waitForTextAbsent(page, '还没有 Host');
    await assertEncryptedBrowserStorage(page, { missingProfileId: sourceProfileId });

    // This is an explicit CDP origin clear, not a deterministic simulation of
    // passive browser eviction.
    setActiveStage('explicitly clear all browser data for the local origin');
    for (const otherPage of context.pages()) {
      if (otherPage !== page) await otherPage.close();
    }
    await page.close();
    page = null;
    assertThat(context.pages().length === 0,
      'an application page remained open before clearing origin storage');
    // Closing the final app page removes its SharedWorker client; lock and
    // page disposal release the catalog and vault connections before clearing.
    await new Promise((resolve) => setTimeout(resolve, 250));
    const clearPage = await context.newPage();
    page = clearPage;
    observePageErrors(page);
    const originClearSession = await context.newCDPSession(clearPage);
    await originClearSession.send('Storage.clearDataForOrigin', {
      origin: staticServer.baseUrl,
      storageTypes: 'all',
    });
    await originClearSession.detach();
    await clearPage.close();
    page = null;
    page = await context.newPage();
    observePageErrors(page);
    await page.goto(staticServer.baseUrl, { waitUntil: 'domcontentloaded' });
    await activateAccessibilitySemantics(page);
    await visibleText(page, 'Choose a workspace');
    await (await button(page, 'Open locally')).click();
    // Opening local mode invokes the catalog's read-only SQL list operation;
    // the empty state is therefore also the table-level zero-row check.
    await visibleText(page, '还没有本地配置');
    await assertOriginClearState(
      page,
      [sourceProfileId, targetProfileId, originClearProfileId],
      ORIGIN_CLEAR_PLAINTEXT_MARKERS,
    );

    setActiveStage('create and use a new profile after the explicit origin clear');
    await fill(page, '主密码', POST_CLEAR_PROFILE_PASSWORD);
    await (await button(page, '创建并解锁')).click();
    await visibleText(page, '还没有 Host', 90000);
    postClearProfileId = await page.evaluate(async () => {
      const names = (await indexedDB.databases()).map((database) => database.name || '');
      const vault = names.find((name) => name.startsWith('atermius_local_vault_'));
      return vault ? vault.slice('atermius_local_vault_'.length) : '';
    });
    assertThat(postClearProfileId &&
      ![sourceProfileId, targetProfileId, originClearProfileId].includes(postClearProfileId),
    'new post-clear profile reused an old profile ID');
    await (await button(page, '添加 Host')).click();
    await fill(page, '名称', POST_CLEAR_HOST_NAME);
    await fill(page, '主机名或 IP', POST_CLEAR_HOST_ADDRESS);
    await fill(page, 'SSH 用户名', HOST_USERNAME);
    await (await button(page, '保存加密 Host')).click();
    await waitForHostSave(page, POST_CLEAR_HOST_NAME);
    await assertEncryptedBrowserStorage(page);
    await visibleText(page, POST_CLEAR_HOST_NAME);
    await waitForTextAbsent(page, ORIGIN_CLEAR_HOST_NAME);

    setActiveStage('return from LocalVault to the accessible workspace chooser');
    await (await button(page, '返回工作区选择')).click();
    await visibleText(page, 'Choose a workspace');

    assertThat(apiRequests.length === 0, 'local mode made an API/auth/sync request');
    const remoteOrigins = [...new Set(remoteRequests.map((url) => new URL(url).origin))];
    assertThat(
      remoteRequests.length === 0,
      `local mode contacted unexpected origins: ${redactDiagnostic(JSON.stringify(remoteOrigins), [sourceProfileId, targetProfileId, originClearProfileId, postClearProfileId])}; requests=${redactDiagnostic(JSON.stringify(remoteRequests), [sourceProfileId, targetProfileId, originClearProfileId, postClearProfileId])}`,
    );
    assertThat(pageErrors.length === 0, 'local mode raised a browser runtime error');
    console.log('Local profile browser acceptance passed: Web LocalVault Host page clearly explains unavailable SSH/SFTP and returns accessibly to the workspace chooser; encrypted Host, Credential, nested Group, Snippet and LocalVault Preferences CRUD; font size, theme and shortcut preferences survived archive import plus lock/reload/unlock and were absent from plaintext IndexedDB/archive data; portable archive wrong-password, tamper, truncation and unknown-version rejection; missing-Vault fail-closed unlock, explicit CDP origin clear and fresh-profile creation, ciphertext-only storage and zero API/remote requests.');
  } catch (error) {
    const uiState = page ? await page.evaluate(async () => {
      const semantics = [...document.querySelectorAll('flt-semantics')]
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const text = `${document.body.innerText || ''}\n${semantics}`;
      const databases = typeof indexedDB.databases === 'function'
        ? (await indexedDB.databases()).map((database) => database.name)
        : [];
      const databaseDetails = await Promise.all(databases.map(async (name) => {
        const connection = await new Promise((resolve, reject) => {
          const request = indexedDB.open(name);
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
        }).catch(() => null);
        if (!connection) return { name, stores: [] };
        const stores = await Promise.all([...connection.objectStoreNames].map(async (storeName) => ({
          name: storeName,
          count: await new Promise((resolve) => {
            const request = connection.transaction(storeName, 'readonly').objectStore(storeName).count();
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => resolve(null);
          }),
        })));
        connection.close();
        return { name, stores };
      }));
      const safeDatabaseName = (name) => name === 'atermius_profile_catalog'
        ? name
        : name.startsWith('atermius_local_vault_')
          ? 'atermius_local_vault_[redacted]'
          : '[other IndexedDB]';
      return {
        modeChooser: text.includes('Choose a workspace'),
        profileList: text.includes('选择配置解锁'),
        emptyProfiles: text.includes('还没有本地配置'),
        catalogError: text.includes('无法读取本地配置列表'),
        cleanupError: text.includes('无法安全关闭本地配置'),
        emptyHosts: text.includes('还没有 Host'),
        hostScreen: text.includes('添加 Host'),
        credentialScreen: text.includes('添加凭据'),
        groupScreen: text.includes('添加分组'),
        snippetScreen: text.includes('添加片段'),
        toolbarLabels: [...new Set([...document.querySelectorAll('flt-semantics')]
          .map((element) => element.getAttribute('aria-label') || '')
          .filter((label) => ['Host', '凭据', '分组', '片段', '锁定配置'].includes(label)))],
        createScreen: text.includes('创建新配置'),
        textLength: text.length,
        indexedDbNames: databases.map(safeDatabaseName),
        indexedDbDetails: databaseDetails.map((database) => ({
          ...database,
          name: safeDatabaseName(database.name),
        })),
      };
    }).catch(() => null) : null;
    const oldProfileIds = [sourceProfileId, targetProfileId, originClearProfileId, postClearProfileId];
    throw new Error(`${activeStage}: ${redactDiagnostic(error.message, oldProfileIds)}; ui=${JSON.stringify(uiState)}`);
  } finally {
    if (context) await context.close().catch(() => {});
    if (staticServer) await new Promise((resolve) => staticServer.server.close(resolve));
    fs.rmSync(archiveTestDirectory, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(`Local profile browser acceptance failed: ${error.message}`);
  process.exitCode = 1;
});
