#!/usr/bin/env node
'use strict';

/* PG-ADMIN-RELAY-01: exercise the existing Relay Settings UI against PG. */

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const BASE_URL = process.env.ATERMIUS_PG_ADMIN_RELAY_BASE_URL;
const NODE_B_URL = process.env.ATERMIUS_PG_ADMIN_RELAY_NODE_B_URL;
const PUBLIC_ORIGIN = process.env.ATERMIUS_PUBLIC_ORIGIN;
const USERNAME = process.env.ATERMIUS_PG_ADMIN_RELAY_USERNAME;
const PASSWORD = process.env.ATERMIUS_PG_ADMIN_RELAY_PASSWORD;
const BOOTSTRAP_TOKEN = process.env.ATERMIUS_PG_ADMIN_RELAY_BOOTSTRAP_TOKEN;
const TARGET_USERNAME = process.env.ATERMIUS_PG_ADMIN_RELAY_TARGET_USERNAME;
const TARGET_PASSWORD = process.env.ATERMIUS_PG_ADMIN_RELAY_TARGET_PASSWORD;
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const GROUP_NAME = `PG Ops ${crypto.randomBytes(4).toString('hex')}`;
const SECOND_GROUP_NAME = process.env.ATERMIUS_PG_ADMIN_RELAY_SECOND_GROUP_NAME ||
  `PG Relay Multi ${crypto.randomBytes(4).toString('hex')}`;

let browser;
let context;
let page;
let stage = 'preflight';
let pageErrors = 0;
let requestFailures = 0;
let externalRequests = 0;
let accessToken = null;
let invitationToken = null;
const relayAdminResponses = [];
const secrets = [PASSWORD, BOOTSTRAP_TOKEN, TARGET_PASSWORD].filter(Boolean);

function assertThat(value, message) {
  if (!value) throw new Error(message);
}

function report(name, value) {
  console.log(`assert: ${name}=${value}`);
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected Web state did not appear');
}

async function field(label, targetPage = page) {
  const locator = targetPage.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(targetPage, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  await locator.scrollIntoViewIfNeeded();
  return locator;
}

async function button(label, targetPage = page) {
  const locator = targetPage.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(targetPage, locator);
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  await locator.scrollIntoViewIfNeeded();
  return locator;
}

async function click(label, targetPage = page) {
  await (await button(label, targetPage)).click();
}

async function chooseDropdownOption(fieldLabel, optionLabel) {
  const fieldPoint = await page.evaluate((label) => {
    const candidates = [...document.querySelectorAll('flt-semantics')].filter((element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity) !== 0 &&
        ['button', 'combobox', 'textbox'].includes(element.getAttribute('role')) &&
        `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
          .toLowerCase().includes(label.toLowerCase());
    });
    const target = candidates.at(-1);
    if (!target) return null;
    target.scrollIntoView({ block: 'center', inline: 'nearest' });
    const rect = target.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  }, fieldLabel);
  if (fieldPoint) {
    await page.mouse.click(fieldPoint.x, fieldPoint.y);
  } else {
    const control = page.getByRole('combobox', { name: fieldLabel }).last();
    await control.waitFor({ state: 'visible', timeout: 10000 });
    await control.scrollIntoViewIfNeeded();
    await control.click();
  }

  await waitFor(async () => page.evaluate((expected) =>
    [...document.querySelectorAll('flt-semantics[role="option"], flt-semantics[role="menuitem"]')]
      .some((element) => {
        const rect = element.getBoundingClientRect();
        const value = `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`;
        return rect.width > 0 && rect.height > 0 && value.includes(expected);
      }), optionLabel), 10000);
  const optionPoint = await page.evaluate((expected) => {
    const candidates = [...document.querySelectorAll(
      'flt-semantics[role="option"], flt-semantics[role="menuitem"]',
    )].filter((element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 &&
        `${element.getAttribute('aria-label') || ''} ${element.innerText || ''} ${element.textContent || ''}`
          .includes(expected);
    });
    const target = candidates.at(-1);
    if (!target) return null;
    target.scrollIntoView({ block: 'center', inline: 'nearest' });
    const rect = target.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  }, optionLabel);
  if (optionPoint) {
    await page.mouse.click(optionPoint.x, optionPoint.y);
  } else {
    const option = page.getByText(optionLabel, { exact: true }).last();
    await option.waitFor({ state: 'visible', timeout: 10000 });
    await option.click();
  }
}

async function fill(label, value, targetPage = page) {
  const locator = await field(label, targetPage);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await targetPage.waitForTimeout(120);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 35 });
    await targetPage.waitForTimeout(180);
    if (await locator.inputValue().catch(() => '') !== value) continue;
    await locator.press('Tab');
    await targetPage.waitForTimeout(100);
    if (await locator.inputValue().catch(() => '') === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function hasVisibleSemanticText(needle, targetPage = page) {
  return targetPage.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) === 0 || rect.width <= 0 || rect.height <= 0) return false;
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`.includes(expected);
    });
  }, needle);
}

function watchResponses(targetPage = page, captureOwnerToken = false) {
  targetPage.on('response', (response) => {
    let url;
    try { url = new URL(response.url()); } catch (_) { return; }
    if (url.pathname !== '/api/v1/auth/register' &&
        !url.pathname.startsWith('/api/v1/admin/relay-policy') &&
        !url.pathname.startsWith('/api/v1/admin/relay-groups') &&
        !url.pathname.startsWith('/api/v1/admin/accounts') &&
        !url.pathname.startsWith('/api/v1/admin/account-invitations')) return;
    const request = response.request();
    const entry = {
      sequence: relayAdminResponses.length,
      path: url.pathname,
      method: request.method(),
      status: response.status(),
      hasBearer: /^Bearer\s+\S+$/i.test(request.headers().authorization || ''),
      body: null,
      payload: response.json().catch(() => null),
    };
    try { entry.body = request.postDataJSON(); } catch (_) {}
    relayAdminResponses.push(entry);
    if (captureOwnerToken && url.pathname === '/api/v1/auth/register') {
      entry.payload.then((payload) => {
        if (typeof payload?.access_token === 'string') accessToken = payload.access_token;
      });
    }
  });
  targetPage.on('request', (request) => {
    try {
      if (new URL(request.url()).origin !== new URL(BASE_URL).origin) externalRequests += 1;
    } catch (_) { externalRequests += 1; }
  });
}

async function waitForResponse(after, predicate, timeoutMs = 30000) {
  await waitFor(() => relayAdminResponses.some((entry) =>
    entry.sequence >= after && predicate(entry)), timeoutMs);
  return relayAdminResponses.find((entry) =>
    entry.sequence >= after && predicate(entry));
}

async function apiGet(url) {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(10000),
  });
  return { status: response.status, payload: await response.json() };
}

async function apiSend(url, method, body) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  return { status: response.status, payload: await response.json() };
}

async function requestTargetTicket(accessToken, deviceId, targetHost, targetPort) {
  const response = await fetch(`${NODE_B_URL}/api/v1/relay/tickets`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      device_id: deviceId,
      target_host: targetHost,
      target_port: targetPort,
    }),
    signal: AbortSignal.timeout(10000),
  });
  return { status: response.status, payload: await response.json() };
}

async function consumeTargetTicket(ticket) {
  const endpoint = new URL(BASE_URL);
  assertThat(endpoint.protocol === 'http:' && PUBLIC_ORIGIN,
    'PG Relay ticket-consumption fixture requires its configured loopback Origin');
  return new Promise((resolve) => {
    const socket = net.connect({ host: endpoint.hostname, port: Number(endpoint.port || 80) });
    const key = crypto.randomBytes(16).toString('base64');
    let response = Buffer.alloc(0);
    let upgraded = false;
    let sent = false;
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve({ upgraded, sent });
    };
    const timer = setTimeout(finish, 3000);
    socket.setTimeout(3000);
    socket.on('connect', () => {
      socket.write([
        'GET /relay/v1/connect HTTP/1.1',
        `Host: ${endpoint.host}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Key: ${key}`,
        'Sec-WebSocket-Version: 13',
        `Origin: ${PUBLIC_ORIGIN}`,
        '',
        '',
      ].join('\r\n'));
    });
    socket.on('data', (chunk) => {
      if (upgraded) return;
      response = Buffer.concat([response, chunk]);
      const boundary = response.indexOf('\r\n\r\n');
      if (boundary < 0) return;
      const headers = response.subarray(0, boundary).toString('latin1');
      upgraded = /^HTTP\/1\.1 101\b/m.test(headers);
      if (!upgraded) return finish();
      const payload = Buffer.from(ticket, 'utf8');
      const mask = crypto.randomBytes(4);
      const masked = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));
      socket.write(Buffer.concat([
        Buffer.from([0x81, 0x80 | payload.length]), mask, masked,
      ]));
      sent = true;
      setTimeout(finish, 500);
    });
    socket.on('timeout', finish);
    socket.on('end', finish);
    socket.on('close', finish);
    socket.on('error', finish);
  });
}

function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === [...keys].sort().join(',');
}

function validateUserPolicy(payload, expected) {
  assertThat(exactKeys(payload, [
    'user_id', 'inherited', 'policy', 'effective_policy',
    'instance_policy_revision', 'revision', 'updated_at',
  ]), 'account Relay policy response fields changed');
  assertThat(payload.user_id === expected.userId &&
    payload.inherited === expected.inherited &&
    payload.revision === expected.revision &&
    payload.instance_policy_revision === expected.instanceRevision,
  'account Relay policy identity or revisions did not match');
  const validateSelection = (actual, selection) => exactKeys(actual, [
    'enabled', 'allow_cidrs', 'allow_ports',
  ]) && actual.enabled === selection.enabled &&
    JSON.stringify(actual.allow_cidrs) === JSON.stringify(selection.cidrs) &&
    JSON.stringify(actual.allow_ports) === JSON.stringify(selection.ports);
  assertThat(validateSelection(payload.policy, expected.policy) &&
    validateSelection(payload.effective_policy, expected.effective),
  'account Relay selected or effective policy did not match the expected state');
  assertThat(payload.updated_at === null ||
    (typeof payload.updated_at === 'string' && !Number.isNaN(Date.parse(payload.updated_at))),
  'account Relay policy update timestamp was invalid');
  return payload;
}

async function inspectBrowserSecrets(targetPage = page, extraSecret = null) {
  const values = await targetPage.evaluate(() => {
    const output = [];
    for (const store of [localStorage, sessionStorage]) {
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        output.push(key || '', store.getItem(key) || '');
      }
    }
    return output.join('\n');
  });
  return [...secrets, BOOTSTRAP_TOKEN, invitationToken, accessToken, extraSecret]
    .filter((secret) => typeof secret === 'string' && secret.length > 0)
    .every((secret) => !values.includes(secret));
}

async function registerInvitedTarget() {
  setStage('issue a private PG account invitation for the Relay target');
  const issued = await apiSend(`${BASE_URL}/api/v1/admin/account-invitations`, 'POST', {
    username: TARGET_USERNAME,
  });
  const invitation = issued.payload?.invitation;
  assertThat(issued.status === 201 && exactKeys(issued.payload, ['invitation']) &&
    exactKeys(invitation, ['invitation_id', 'username', 'created_at', 'expires_at', 'token']) &&
    invitation.username === TARGET_USERNAME &&
    /^[A-Za-z0-9_-]{43}$/.test(invitation.token),
  'could not issue the PG Relay target invitation');
  invitationToken = invitation.token;
  const inviteSecret = invitationToken;
  secrets.push(inviteSecret);
  issued.payload.invitation.token = '';

  const targetContext = await browser.newContext({
    locale: 'en-US', viewport: { width: 1440, height: 1000 },
  });
  const targetPage = await targetContext.newPage();
  targetPage.on('pageerror', () => { pageErrors += 1; });
  targetPage.on('requestfailed', () => { requestFailures += 1; });
  watchResponses(targetPage, false);
  try {
    setStage('open an isolated invited account browser profile');
    const index = await targetPage.goto(BASE_URL, {
      waitUntil: 'domcontentloaded', timeout: 30000,
    });
    assertThat(index?.status() === 200, 'PG invited-account Web index did not load');
    await waitFor(() => targetPage.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
    await targetPage.evaluate(async () => { await window.sodium.ready; });
    await targetPage.locator('flt-semantics-placeholder')
      .evaluate((element) => element.click());
    await waitFor(() => targetPage.evaluate(() =>
      document.querySelectorAll('flt-semantics').length > 0));
    await fill('Server URL', BASE_URL, targetPage);
    await click('Connect securely', targetPage);
    await field('Email or username', targetPage);
    await click('Have an instance invitation? Create account', targetPage);
    await field('Email on the invitation', targetPage);
    await fill('Email on the invitation', TARGET_USERNAME, targetPage);
    await fill('Master password · 12+ characters', TARGET_PASSWORD, targetPage);
    await fill('Confirm master password', TARGET_PASSWORD, targetPage);
    await fill('Instance invitation token', invitationToken, targetPage);
    invitationToken = null;
    await fill('Device name', 'PG Relay target account', targetPage);
    await fill('First Vault', 'PG Relay target Vault', targetPage);
    const before = relayAdminResponses.length;
    await click('Create invited account', targetPage);
    await (await button('Add host', targetPage)).waitFor({
      state: 'visible', timeout: 45000,
    });
    const registration = await waitForResponse(before, (entry) =>
      entry.path === '/api/v1/auth/register' && entry.method === 'POST');
    const receipt = await registration.payload;
    assertThat(registration.status >= 200 && registration.status < 300 &&
      !registration.hasBearer && typeof receipt?.account_id === 'string' &&
      typeof receipt?.device_id === 'string' && typeof receipt?.access_token === 'string',
    'invited PG Relay target registration did not return an account and session');
    const targetUserId = receipt.account_id;
    const targetDeviceId = receipt.device_id;
    const targetAccessToken = receipt.access_token;
    secrets.push(targetAccessToken);
    assertThat(await inspectBrowserSecrets(targetPage, inviteSecret) &&
      await inspectBrowserSecrets(targetPage, targetAccessToken),
      'invitation token or credentials appeared in invited-account browser storage');
    registration.body = null;
    registration.payload = Promise.resolve(null);
    receipt.access_token = '';
    receipt.refresh_token = '';
    targetPage.removeAllListeners();
    setStage('close invited-account registration browser profile');
    return { targetUserId, targetDeviceId, targetAccessToken };
  } finally {
    await targetContext.close().catch(() => {});
  }
}

async function configureAndRegisterAdmin() {
  setStage('load PostgreSQL Web Release');
  const index = await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  report('web_release_index_status', index?.status() ?? 0);
  assertThat(index?.status() === 200, 'PG Web Release index did not load');
  setStage('wait for Flutter Web runtime');
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  setStage('select server workspace mode');
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0));
  setStage('connect Web client to PostgreSQL');
  await fill('Server URL', BASE_URL);
  await click('Connect securely');
  setStage('complete first-owner registration through Web');
  await field('Owner email');
  await fill('Owner email', USERNAME);
  await fill('Master password · 12+ characters', PASSWORD);
  await fill('Confirm master password', PASSWORD);
  await fill('One-time bootstrap token', BOOTSTRAP_TOKEN);
  await fill('Device name', 'PostgreSQL Relay Settings acceptance');
  await fill('First Vault', 'PostgreSQL Relay Settings acceptance');
  const before = relayAdminResponses.length;
  await click('Create owner account');
  const registration = await waitForResponse(before, (entry) =>
    entry.path === '/api/v1/auth/register' && entry.method === 'POST');
  const registrationPayload = await registration.payload;
  report('admin_registration_status', registration.status);
  report('admin_registration_error_code', registrationPayload?.error?.code || 'none');
  assertThat([200, 201].includes(registration.status),
    'allowlisted administrator registration did not succeed');
  await waitFor(() => typeof accessToken === 'string' && accessToken.length >= 32);
  await button('Add host');
  report('admin_registered_through_pg_web', true);
}

async function exerciseInstancePolicyUi() {
  setStage('wait for SSH relay policy card');
  await waitFor(() => hasVisibleSemanticText('SSH relay policy'));
  setStage('load PostgreSQL instance Relay policy from Settings');
  const start = relayAdminResponses.length;
  await click('Load relay policy');
  const loaded = await waitForResponse(start, (entry) =>
    entry.path === '/api/v1/admin/relay-policy' && entry.method === 'GET');
  const initial = await loaded.payload;
  assertThat(loaded.status === 200 && loaded.hasBearer && initial?.revision === 0 &&
    initial?.deployment_limits?.relay_available === true,
  'PG Settings did not load the authenticated instance Relay policy');
  report('instance_policy_ui_read', true);

  await fill('Allowed CIDRs', '10.1.0.0/16');
  await fill('Allowed ports', '22');
  const saveStart = relayAdminResponses.length;
  await click('Save relay policy');
  const saved = await waitForResponse(saveStart, (entry) =>
    entry.path === '/api/v1/admin/relay-policy' && entry.method === 'PUT');
  const savedPayload = await saved.payload;
  assertThat(saved.status === 200 && saved.hasBearer &&
    saved.body?.expected_revision === 0 && saved.body?.enabled === true &&
    JSON.stringify(saved.body?.allow_cidrs) === JSON.stringify(['10.1.0.0/16']) &&
    JSON.stringify(saved.body?.allow_ports) === JSON.stringify([22]) &&
    savedPayload?.revision === 1 && savedPayload?.policy?.allow_cidrs?.[0] === '10.1.0.0/16',
  'PG Settings did not save the instance policy using revision CAS');
  const fromNodeB = await apiGet(`${NODE_B_URL}/api/v1/admin/relay-policy`);
  assertThat(fromNodeB.status === 200 && fromNodeB.payload?.revision === 1 &&
    fromNodeB.payload?.policy?.enabled === true &&
    JSON.stringify(fromNodeB.payload?.policy?.allow_cidrs) === JSON.stringify(['10.1.0.0/16']) &&
    JSON.stringify(fromNodeB.payload?.policy?.allow_ports) === JSON.stringify([22]),
  'PG node B did not observe the policy saved from the Web UI on node A');
  report('instance_policy_saved_cross_node', true);
}

async function exerciseGroupUi(targetUserId) {
  setStage('wait for server-managed groups card');
  await waitFor(() => hasVisibleSemanticText('Server-managed access groups'));
  setStage('scroll Settings to PostgreSQL server-managed groups');
  await page.mouse.move(1100, 850);
  for (let step = 0; step < 18; step += 1) {
    await page.mouse.wheel(0, 700);
    await page.waitForTimeout(45);
  }
  setStage('load PostgreSQL server-managed groups from Settings');
  const start = relayAdminResponses.length;
  await click('Load server-managed groups');
  const loaded = await waitForResponse(start, (entry) =>
    entry.path === '/api/v1/admin/relay-groups' && entry.method === 'GET');
  const initial = await loaded.payload;
  assertThat(loaded.status === 200 && loaded.hasBearer &&
    Array.isArray(initial?.groups) && initial.groups.length === 0,
  'PG Settings did not load the empty server-managed groups state');
  await waitFor(() => hasVisibleSemanticText('No server-managed groups yet.'));

  setStage('enter new server-managed group name');
  await fill('New server group name', GROUP_NAME);
  setStage('create server-managed group from Settings');
  const createStart = relayAdminResponses.length;
  await click('Create group');
  const created = await waitForResponse(createStart, (entry) =>
    entry.path === '/api/v1/admin/relay-groups' && entry.method === 'POST');
  const createdPayload = await created.payload;
  const groupId = createdPayload?.group?.group_id;
  assertThat(created.status === 201 && created.hasBearer &&
    createdPayload?.group?.name === GROUP_NAME && typeof groupId === 'string',
  'PG Settings did not create the server-managed group');
  setStage('wait for created group details');
  await waitFor(() => hasVisibleSemanticText('Selected server-managed group'));

  setStage('enter server-managed group policy');
  await fill('Allowed CIDR networks', '10.1.1.0/24');
  await fill('Allowed ports', '22');
  setStage('save server-managed group policy from Settings');
  const policyStart = relayAdminResponses.length;
  await click('Save group override');
  const policy = await waitForResponse(policyStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupId}/relay-policy` &&
    entry.method === 'PUT');
  const policyPayload = await policy.payload;
  assertThat(policy.status === 200 && policy.hasBearer &&
    policy.body?.expected_revision === 0 &&
    Number.isInteger(policy.body?.expected_instance_policy_revision) &&
    policy.body?.expected_instance_policy_revision === 1 &&
    policy.body?.enabled === true &&
    JSON.stringify(policy.body?.allow_cidrs) === JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(policy.body?.allow_ports) === JSON.stringify([22]) &&
    policyPayload?.policy?.revision === 1,
  'PG Settings did not save the group Relay override with both CAS revisions');
  const detail = await apiGet(`${NODE_B_URL}/api/v1/admin/relay-groups/${groupId}`);
  assertThat(detail.status === 200 && detail.payload?.group?.name === GROUP_NAME &&
    detail.payload?.policy?.policy?.enabled === true &&
    JSON.stringify(detail.payload?.policy?.policy?.allow_cidrs) ===
      JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(detail.payload?.policy?.policy?.allow_ports) === JSON.stringify([22]),
  'PG node B did not observe the group and override saved through Web node A');
  report('group_policy_saved_cross_node', true);

  setStage('load accounts and add the invited member through PG Settings');
  const accountStart = relayAdminResponses.length;
  await click('Load accounts to add members');
  const accountRead = await waitForResponse(accountStart, (entry) =>
    entry.path === '/api/v1/admin/accounts' && entry.method === 'GET');
  const accountPage = await accountRead.payload;
  const targetAccount = accountPage?.accounts?.find((account) =>
    account.user_id === targetUserId && account.username === TARGET_USERNAME &&
    account.status === 'active');
  const ownerAccount = accountPage?.accounts?.find((account) =>
    account.user_id !== targetUserId && account.status === 'active');
  assertThat(accountRead.status === 200 && accountRead.hasBearer &&
    accountPage?.total === 2 && targetAccount && ownerAccount &&
    accountPage.accounts.length === 2,
  'PG Settings member picker did not load the invited target and administrator');
  await chooseDropdownOption('Active account on current page', TARGET_USERNAME);
  await click('Add');
  const membershipStart = relayAdminResponses.length;
  await click('Save membership');
  const membership = await waitForResponse(membershipStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupId}/members` &&
    entry.method === 'PUT');
  const membershipPayload = await membership.payload;
  assertThat(membership.status === 200 && membership.hasBearer &&
    membership.body?.expected_revision === 0 &&
    JSON.stringify(membership.body?.user_ids) === JSON.stringify([targetUserId]) &&
    membershipPayload?.members?.revision === 1 &&
    membershipPayload?.members?.items?.length === 1 &&
    membershipPayload.members.items[0]?.user_id === targetUserId &&
    membershipPayload.members.items[0]?.username === TARGET_USERNAME,
  'PG Settings did not save the complete invited-member set with membership CAS');

  const groupPath = `/api/v1/admin/relay-groups/${groupId}`;
  const groupFromNodeB = await apiGet(`${NODE_B_URL}${groupPath}`);
  assertThat(groupFromNodeB.status === 200 &&
    groupFromNodeB.payload?.members?.revision === 1 &&
    groupFromNodeB.payload?.members?.items?.length === 1 &&
    groupFromNodeB.payload.members.items[0]?.user_id === targetUserId &&
    groupFromNodeB.payload.members.items[0]?.username === TARGET_USERNAME,
  'PG node B did not observe the group membership saved from Web node A');
  const effectiveFromNodeB = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-policy/users/${targetUserId}`,
  );
  validateUserPolicy(effectiveFromNodeB.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.0.0/16'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  report('target_membership_saved_cross_node', true);

  const memberRemoveButton = page.getByRole('button', {
    name: `Remove ${TARGET_USERNAME} from group draft`, exact: true,
  }).last();
  await memberRemoveButton.waitFor({ state: 'visible', timeout: 10000 });
  await memberRemoveButton.click();
  setStage('create a concurrent PG group membership revision');
  const concurrentMembership = await apiSend(`${NODE_B_URL}${groupPath}/members`, 'PUT', {
    expected_revision: 1,
    user_ids: [targetUserId, ownerAccount.user_id].sort(),
  });
  assertThat(concurrentMembership.status === 200 &&
    concurrentMembership.payload?.members?.revision === 2 &&
    concurrentMembership.payload?.members?.items?.length === 2,
  'node B concurrent group membership fixture failed');

  setStage('verify stale group membership CAS preserves the Web draft');
  const staleMembershipStart = relayAdminResponses.length;
  await click('Save membership');
  const staleMembership = await waitForResponse(staleMembershipStart, (entry) =>
    entry.path === `${groupPath}/members` && entry.method === 'PUT');
  const staleMembershipPayload = await staleMembership.payload;
  assertThat(staleMembership.status === 409 && staleMembership.hasBearer &&
    staleMembership.body?.expected_revision === 1 &&
    Array.isArray(staleMembership.body?.user_ids) && staleMembership.body.user_ids.length === 0 &&
    staleMembershipPayload?.error?.code === 'RELAY_GROUP_MEMBERSHIP_CONFLICT',
  'stale group membership save did not return the expected membership CAS conflict');
  await waitFor(() => hasVisibleSemanticText('Reload latest group, keep drafts'));
  assertThat(await hasVisibleSemanticText(`Restore ${TARGET_USERNAME} in group draft`),
    'stale group conflict discarded the removed-member draft');

  setStage('reload the latest PG membership snapshot while keeping the Web draft');
  const reloadStart = relayAdminResponses.length;
  await click('Reload latest group, keep drafts');
  const reloadedGroup = await waitForResponse(reloadStart, (entry) =>
    entry.path === groupPath && entry.method === 'GET');
  const reloadedMembership = (await reloadedGroup.payload)?.members;
  assertThat(reloadedGroup.status === 200 && reloadedGroup.hasBearer &&
    reloadedMembership?.revision === 2 && reloadedMembership?.items?.length === 2 &&
    reloadedMembership.items.some((item) => item.user_id === targetUserId) &&
    reloadedMembership.items.some((item) => item.user_id === ownerAccount.user_id),
  'Web conflict reload did not read the concurrent full group membership set');
  await waitFor(() => hasVisibleSemanticText('membership revision 2'));
  assertThat(await hasVisibleSemanticText(`Restore ${TARGET_USERNAME} in group draft`),
    'PG conflict reload replaced the removed-member draft');

  await chooseDropdownOption('Active account on current page', TARGET_USERNAME);
  await click('Add');
  const retryStart = relayAdminResponses.length;
  await click('Save membership');
  const membershipRetry = await waitForResponse(retryStart, (entry) =>
    entry.path === `${groupPath}/members` && entry.method === 'PUT' && entry.status === 200);
  const membershipRetryPayload = await membershipRetry.payload;
  assertThat(membershipRetry.body?.expected_revision === 2 &&
    JSON.stringify(membershipRetry.body?.user_ids) === JSON.stringify([targetUserId]) &&
    membershipRetryPayload?.members?.revision === 3 &&
    membershipRetryPayload?.members?.items?.length === 1 &&
    membershipRetryPayload.members.items[0]?.user_id === targetUserId,
  'group membership retry did not save the preserved full member set at the latest revision');
  report('group_membership_cas_conflict_kept_draft', true);

  const finalRemoveButton = page.getByRole('button', {
    name: `Remove ${TARGET_USERNAME} from group draft`, exact: true,
  }).last();
  await finalRemoveButton.waitFor({ state: 'visible', timeout: 10000 });
  await finalRemoveButton.click();
  const removeStart = relayAdminResponses.length;
  await click('Save membership');
  const removedMembership = await waitForResponse(removeStart, (entry) =>
    entry.path === `${groupPath}/members` && entry.method === 'PUT' && entry.status === 200);
  const removedPayload = await removedMembership.payload;
  assertThat(removedMembership.body?.expected_revision === 3 &&
    Array.isArray(removedMembership.body?.user_ids) && removedMembership.body.user_ids.length === 0 &&
    removedPayload?.members?.revision === 4 && removedPayload?.members?.items?.length === 0,
  'PG Settings did not save the invited-member removal with the latest membership revision');
  const afterRemovalNodeB = await apiGet(`${NODE_B_URL}${groupPath}`);
  assertThat(afterRemovalNodeB.status === 200 &&
    afterRemovalNodeB.payload?.members?.revision === 4 &&
    afterRemovalNodeB.payload?.members?.items?.length === 0,
  'PG node B did not observe the saved group-member removal');
  const afterRemovalPolicy = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-policy/users/${targetUserId}`,
  );
  validateUserPolicy(afterRemovalPolicy.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.0.0/16'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.0.0/16'], ports: [22] },
  });
  report('target_membership_removed_cross_node', true);

  setStage('re-add the invited member to the first group');
  await chooseDropdownOption('Active account on current page', TARGET_USERNAME);
  await click('Add');
  const firstReaddStart = relayAdminResponses.length;
  await click('Save membership');
  const firstReadd = await waitForResponse(firstReaddStart, (entry) =>
    entry.path === `${groupPath}/members` && entry.method === 'PUT');
  assertThat(firstReadd.status === 200 && firstReadd.hasBearer &&
    firstReadd.body?.expected_revision === 4 &&
    JSON.stringify(firstReadd.body?.user_ids) === JSON.stringify([targetUserId]) &&
    (await firstReadd.payload)?.members?.revision === 5,
  'PG Settings did not re-add the invited member to the first group');

  setStage('create a second PostgreSQL server-managed group');
  await fill('New server group name', SECOND_GROUP_NAME);
  const secondCreateStart = relayAdminResponses.length;
  await click('Create group');
  const secondCreated = await waitForResponse(secondCreateStart, (entry) =>
    entry.path === '/api/v1/admin/relay-groups' && entry.method === 'POST');
  const secondCreatedPayload = await secondCreated.payload;
  const secondGroupId = secondCreatedPayload?.group?.group_id;
  assertThat(secondCreated.status === 201 && secondCreated.hasBearer &&
    secondCreatedPayload?.group?.name === SECOND_GROUP_NAME &&
    typeof secondGroupId === 'string',
  'PG Settings did not create the second server-managed group');
  const secondGroupDetail = await waitForResponse(secondCreateStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${secondGroupId}` &&
    entry.method === 'GET' && entry.status === 200);
  assertThat((await secondGroupDetail.payload)?.group?.name === SECOND_GROUP_NAME,
    'PG Settings did not load the newly created group before editing its policy');
  setStage('wait for second group selection');
  await waitFor(() => hasVisibleSemanticText(
    'Group revision 1 · membership revision 0 · policy revision 0'));

  setStage('save the second group restriction and add the invited member');
  await fill('Allowed CIDR networks', '10.1.1.0/24');
  await fill('Allowed ports', '22');
  const secondPolicyStart = relayAdminResponses.length;
  await click('Save group override');
  const secondPolicy = await waitForResponse(secondPolicyStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${secondGroupId}/relay-policy` &&
    entry.method === 'PUT');
  assertThat(secondPolicy.status === 200 && secondPolicy.hasBearer &&
    secondPolicy.body?.expected_revision === 0 &&
    secondPolicy.body?.expected_instance_policy_revision === 1 &&
    JSON.stringify(secondPolicy.body?.allow_cidrs) === JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(secondPolicy.body?.allow_ports) === JSON.stringify([22]) &&
    (await secondPolicy.payload)?.policy?.revision === 1,
  'PG Settings did not save the second group Relay restriction');

  setStage('refresh invited account page for second group');
  const secondAccountRefreshStart = relayAdminResponses.length;
  await click('Refresh admin accounts');
  const secondAccountRefresh = await waitForResponse(secondAccountRefreshStart, (entry) =>
    entry.path === '/api/v1/admin/accounts' && entry.method === 'GET');
  const refreshedAccounts = await secondAccountRefresh.payload;
  assertThat(secondAccountRefresh.status === 200 &&
    refreshedAccounts?.accounts?.some((account) =>
      account.user_id === targetUserId && account.username === TARGET_USERNAME &&
      account.status === 'active'),
  'refreshed PG Settings account page did not contain the active invited member');

  setStage('select invited member for second group');
  await chooseDropdownOption('Active account on current page', TARGET_USERNAME);
  setStage('add invited member to second group draft');
  await click('Add');
  setStage('save second group membership');
  const secondMembershipStart = relayAdminResponses.length;
  await click('Save membership');
  const secondMembership = await waitForResponse(secondMembershipStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${secondGroupId}/members` &&
    entry.method === 'PUT');
  const secondMembershipPayload = await secondMembership.payload;
  assertThat(secondMembership.status === 200 && secondMembership.hasBearer &&
    secondMembership.body?.expected_revision === 0 &&
    JSON.stringify(secondMembership.body?.user_ids) === JSON.stringify([targetUserId]) &&
    secondMembershipPayload?.members?.revision === 1 &&
    secondMembershipPayload?.members?.items?.length === 1 &&
    secondMembershipPayload.members.items[0]?.user_id === targetUserId,
  'PG Settings did not add the invited member to the second group');
  const secondGroupFromNodeB = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${secondGroupId}`,
  );
  assertThat(secondGroupFromNodeB.status === 200 &&
    secondGroupFromNodeB.payload?.members?.revision === 1 &&
    secondGroupFromNodeB.payload?.members?.items?.some((member) =>
      member.user_id === targetUserId) === true,
  'PG node B did not observe the invited member in the second group');
  const multiGroupPolicy = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-policy/users/${targetUserId}`,
  );
  validateUserPolicy(multiGroupPolicy.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.0.0/16'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  report('target_member_in_two_groups_cross_node', true);
  return { groupId, secondGroupId };
}

async function exerciseUserPolicyUi(targetUserId, targetDeviceId, targetAccessToken, groupIds) {
  setStage('load invited account from PostgreSQL Settings directory');
  await page.mouse.move(900, 850);
  for (let step = 0; step < 30; step += 1) {
    await page.mouse.wheel(0, 1200);
    await page.waitForTimeout(40);
  }
  const accountListStart = relayAdminResponses.length;
  // The group membership editor loads this shared account page first. The
  // account card therefore exposes its refresh action instead of its empty
  // state load action by the time this per-user policy flow runs.
  await click('Refresh admin accounts');
  const accountListEvent = await waitForResponse(accountListStart, (entry) =>
    entry.path === '/api/v1/admin/accounts' && entry.method === 'GET');
  const accountList = await accountListEvent.payload;
  const target = accountList?.accounts?.find((account) => account.user_id === targetUserId);
  assertThat(accountListEvent.status === 200 && accountListEvent.hasBearer &&
    accountList?.total === 2 && accountList.accounts.length === 2 &&
    target?.username === TARGET_USERNAME && target.status === 'active',
  'PG Settings account directory did not show the active invited target');
  await waitFor(() => hasVisibleSemanticText(TARGET_USERNAME));
  const relayButton = page.getByRole('button', { name: 'Relay policy', exact: true });
  assertThat(await relayButton.count() === 1 && await relayButton.isVisible(),
    'the active non-current account did not expose exactly one Relay policy control');

  const policyPath = `/api/v1/admin/relay-policy/users/${targetUserId}`;
  const initialReads = relayAdminResponses.filter((entry) =>
    entry.path === policyPath && entry.method === 'GET').length;
  assertThat(initialReads === 0, 'account policy was fetched before the account card expanded');
  setStage('expand invited account and read inherited policy snapshots');
  const expandStart = relayAdminResponses.length;
  await relayButton.click();
  const userRead = await waitForResponse(expandStart, (entry) =>
    entry.path === policyPath && entry.method === 'GET');
  const instanceRead = await waitForResponse(expandStart, (entry) =>
    entry.path === '/api/v1/admin/relay-policy' && entry.method === 'GET');
  const inherited = await userRead.payload;
  const instance = await instanceRead.payload;
  assertThat(userRead.status === 200 && userRead.hasBearer &&
    instanceRead.status === 200 && instanceRead.hasBearer && instance?.revision === 1,
  'expanded account did not load both PG policy snapshots');
  validateUserPolicy(inherited, {
    userId: targetUserId,
    inherited: true,
    revision: 0,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.0.0/16'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  await waitFor(() => hasVisibleSemanticText('Selection: inherited from the instance policy'));
  report('account_policy_ui_inherited_read', true);

  const enabled = page.getByRole('checkbox', {
    name: 'Enable Relay for this account', exact: true,
  });
  const cidrFields = page.getByRole('textbox', { name: /^Allowed CIDR networks/ });
  assertThat(await cidrFields.count() >= 2,
    'expected account and selected group CIDR fields in Settings');
  const cidrs = cidrFields.first();
  const portFields = page.getByRole('textbox', { name: /^Allowed ports/ });
  assertThat(await portFields.count() >= 3,
    'expected instance, account, and selected group port fields in Settings');
  // Select the port input between this account's CIDR input and the selected
  // group's CIDR input. Flutter semantics locator order is not guaranteed to
  // follow the visible order after an offscreen account card expands.
  const accountCidrBox = await cidrs.boundingBox();
  const groupCidrBox = await cidrFields.nth(1).boundingBox();
  const portCandidates = await Promise.all(
    Array.from({ length: await portFields.count() }, async (_, index) => ({
      locator: portFields.nth(index),
      box: await portFields.nth(index).boundingBox(),
    })),
  );
  const accountPortCandidates = portCandidates.filter(({ box }) =>
    box && accountCidrBox && groupCidrBox &&
    box.y > accountCidrBox.y && box.y < groupCidrBox.y);
  assertThat(accountPortCandidates.length === 1,
    'could not identify the account port field between the account and group cards');
  const ports = accountPortCandidates[0].locator;
  const readAccountDraft = async () => {
    await page.waitForTimeout(150);
    const enabledValue = await enabled.isChecked();
    await cidrs.click();
    await page.waitForTimeout(150);
    const cidrValue = await cidrs.inputValue();
    await ports.click();
    await page.waitForTimeout(150);
    const portValue = await ports.inputValue();
    return { enabled: enabledValue, cidrs: cidrValue, ports: portValue };
  };
  const fillLocator = async (locator, value) => {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await locator.click();
      await page.waitForTimeout(120);
      await locator.press('Control+A');
      await locator.pressSequentially(value, { delay: 35 });
      await page.waitForTimeout(180);
      if (await locator.inputValue().catch(() => '') !== value) continue;
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue().catch(() => '') === value) return;
    }
    throw new Error('account policy draft field did not retain input');
  };
  setStage('edit the invited account Relay policy draft');
  await fillLocator(cidrs, '10.1.1.0/24');
  const intendedDraft = await readAccountDraft();
  report('inherited_account_draft_enabled', intendedDraft.enabled);
  report('edited_account_cidr_retained', intendedDraft.cidrs === '10.1.1.0/24');
  report('inherited_account_port_retained', intendedDraft.ports === '22');
  assertThat(intendedDraft.enabled && intendedDraft.cidrs === '10.1.1.0/24' &&
    intendedDraft.ports === '22', 'account override draft was not seeded and edited as expected');

  setStage('create a competing user revision on PostgreSQL node B');
  const competingUser = await apiSend(`${NODE_B_URL}${policyPath}`, 'PUT', {
    expected_revision: 0,
    expected_instance_policy_revision: 1,
    enabled: false,
    allow_cidrs: ['10.1.1.0/24'],
    allow_ports: [],
  });
  validateUserPolicy(competingUser.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 1,
    instanceRevision: 1,
    policy: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
    effective: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
  });
  assertThat(competingUser.status === 200, 'node B competing user policy write failed');

  setStage('verify stale account CAS preserves the Web draft');
  const staleUserStart = relayAdminResponses.length;
  await click('Save override');
  const staleUser = await waitForResponse(staleUserStart, (entry) =>
    entry.path === policyPath && entry.method === 'PUT');
  const staleUserPayload = await staleUser.payload;
  assertThat(staleUser.status === 409 && staleUser.hasBearer &&
    staleUser.body?.expected_revision === 0 &&
    staleUser.body?.expected_instance_policy_revision === 1 &&
    staleUser.body?.enabled === true &&
    JSON.stringify(staleUser.body?.allow_cidrs) === JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(staleUser.body?.allow_ports) === JSON.stringify([22]) &&
    staleUserPayload?.error?.code === 'RELAY_USER_POLICY_CONFLICT',
  'stale account CAS did not return the expected conflict for the Web draft');
  await waitFor(() => page.getByRole('button', {
    name: 'Reload latest policy, keep draft', exact: true,
  }).isVisible());
  const preservedAfterUserConflict = await readAccountDraft();
  assertThat(preservedAfterUserConflict.enabled &&
    preservedAfterUserConflict.cidrs === '10.1.1.0/24' &&
    preservedAfterUserConflict.ports === '22',
  'stale account CAS discarded the edited Web draft');
  const nodeBUserAfterRace = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(nodeBUserAfterRace.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 1,
    instanceRevision: 1,
    policy: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
    effective: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
  });
  report('account_policy_user_cas_conflict_kept_draft', true);

  setStage('reload the latest account snapshot while keeping the draft');
  const userReloadStart = relayAdminResponses.length;
  await click('Reload latest policy, keep draft');
  const userReload = await waitForResponse(userReloadStart, (entry) =>
    entry.path === policyPath && entry.method === 'GET');
  const instanceReload = await waitForResponse(userReloadStart, (entry) =>
    entry.path === '/api/v1/admin/relay-policy' && entry.method === 'GET');
  validateUserPolicy(await userReload.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 1,
    instanceRevision: 1,
    policy: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
    effective: { enabled: false, cidrs: ['10.1.1.0/24'], ports: [] },
  });
  assertThat((await instanceReload.payload)?.revision === 1,
    'account conflict reload did not refresh the instance snapshot');
  const preservedAfterReload = await readAccountDraft();
  assertThat(preservedAfterReload.enabled && preservedAfterReload.cidrs === '10.1.1.0/24' &&
    preservedAfterReload.ports === '22', 'latest account reload discarded the draft');

  setStage('save account override through PG Web Settings');
  const saveStart = relayAdminResponses.length;
  await click('Save override');
  const saved = await waitForResponse(saveStart, (entry) =>
    entry.path === policyPath && entry.method === 'PUT');
  const savedPayload = await saved.payload;
  assertThat(saved.status === 200 && saved.hasBearer &&
    saved.body?.expected_revision === 1 &&
    saved.body?.expected_instance_policy_revision === 1 &&
    saved.body?.enabled === true &&
    JSON.stringify(saved.body?.allow_cidrs) === JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(saved.body?.allow_ports) === JSON.stringify([22]),
  'Web Settings did not submit the account override with both revision CAS values');
  validateUserPolicy(savedPayload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  const nodeBUserAfterWebSave = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(nodeBUserAfterWebSave.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  report('account_policy_ui_save_cross_node', true);

  setStage('issue a target ticket under the simultaneous group and user policies');
  const beforeGroupMutationTicket = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.100', 22,
  );
  assertThat(beforeGroupMutationTicket.status === 200 &&
    /^[A-Za-z0-9_-]{43}$/.test(beforeGroupMutationTicket.payload?.ticket || '') &&
    beforeGroupMutationTicket.payload?.connect_path === '/relay/v1/connect' &&
    typeof beforeGroupMutationTicket.payload?.expires_at === 'string',
  'the invited member could not receive a ticket before the second-group policy mutation');

  setStage('narrow the second group policy from PostgreSQL node B');
  const groupPolicyMutation = await apiSend(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${groupIds.secondGroupId}/relay-policy`,
    'PUT',
    {
      expected_revision: 1,
      expected_instance_policy_revision: 1,
      enabled: true,
      allow_cidrs: ['10.1.1.128/25'],
      allow_ports: [22],
    },
  );
  assertThat(groupPolicyMutation.status === 200 &&
    groupPolicyMutation.payload?.policy?.revision === 2 &&
    JSON.stringify(groupPolicyMutation.payload?.policy?.policy?.allow_cidrs) ===
      JSON.stringify(['10.1.1.128/25']),
  'node B could not mutate the second group policy while the user override was active');
  const mutatedUserPolicy = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(mutatedUserPolicy.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  const mutatedGroupFromNodeB = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${groupIds.secondGroupId}`,
  );
  assertThat(mutatedGroupFromNodeB.status === 200 &&
    mutatedGroupFromNodeB.payload?.policy?.revision === 2 &&
    JSON.stringify(mutatedGroupFromNodeB.payload?.policy?.policy?.allow_cidrs) ===
      JSON.stringify(['10.1.1.128/25']),
  'PG node B did not retain its second-group policy mutation');

  setStage('review the effective policy from the server-managed group UI');
  const previewStart = relayAdminResponses.length;
  await chooseDropdownOption('Preview member effective Relay access', TARGET_USERNAME);
  const previewResponse = await waitForResponse(previewStart, (entry) =>
    entry.path === policyPath && entry.method === 'GET');
  validateUserPolicy(await previewResponse.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instanceRevision: 1,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  assertThat(previewResponse.status === 200 && previewResponse.hasBearer &&
    await hasVisibleSemanticText(
      'Member effective Relay access: enabled · CIDRs: 10.1.1.128/25 · ports: 22',
    ),
  'group member effective-policy preview did not show the intersected user and group policy');
  const allowAfterGroupMutation = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.200', 22,
  );
  const denyAfterGroupMutation = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.100', 22,
  );
  assertThat(allowAfterGroupMutation.status === 200 &&
    /^[A-Za-z0-9_-]{43}$/.test(allowAfterGroupMutation.payload?.ticket || '') &&
    denyAfterGroupMutation.status === 403 &&
    denyAfterGroupMutation.payload?.error?.code === 'TARGET_DENIED',
  'PG Relay tickets did not follow the narrowed /25 group intersection');
  report('multi_group_user_override_effective_preview', true);

  setStage('create a competing instance revision on PostgreSQL node B');
  await fillLocator(cidrs, '10.1.2.0/24');
  const competingInstance = await apiSend(`${NODE_B_URL}/api/v1/admin/relay-policy`, 'PUT', {
    expected_revision: 1,
    enabled: true,
    allow_cidrs: ['10.1.0.0/17'],
    allow_ports: [22],
  });
  assertThat(competingInstance.status === 200 && competingInstance.payload?.revision === 2,
    'node B competing instance policy write failed');

  setStage('verify stale instance CAS preserves the Web draft');
  const staleInstanceStart = relayAdminResponses.length;
  await click('Save override');
  const staleInstance = await waitForResponse(staleInstanceStart, (entry) =>
    entry.path === policyPath && entry.method === 'PUT');
  const staleInstancePayload = await staleInstance.payload;
  assertThat(staleInstance.status === 409 && staleInstance.hasBearer &&
    staleInstance.body?.expected_revision === 2 &&
    staleInstance.body?.expected_instance_policy_revision === 1 &&
    staleInstance.body?.enabled === true &&
    JSON.stringify(staleInstance.body?.allow_cidrs) === JSON.stringify(['10.1.2.0/24']) &&
    JSON.stringify(staleInstance.body?.allow_ports) === JSON.stringify([22]) &&
    staleInstancePayload?.error?.code === 'RELAY_USER_POLICY_CONFLICT',
  'stale instance CAS did not return the expected conflict for the Web draft');
  await waitFor(() => page.getByRole('button', {
    name: 'Reload latest policy, keep draft', exact: true,
  }).isVisible());
  const preservedAfterInstanceConflict = await readAccountDraft();
  assertThat(preservedAfterInstanceConflict.enabled &&
    preservedAfterInstanceConflict.cidrs === '10.1.2.0/24' &&
    preservedAfterInstanceConflict.ports === '22',
  'stale instance CAS discarded the edited Web draft');
  report('account_policy_instance_cas_conflict_kept_draft', true);

  setStage('reload current policy versions and reset the account to inherit');
  const latestStart = relayAdminResponses.length;
  await click('Reload latest policy, keep draft');
  const latestUser = await waitForResponse(latestStart, (entry) =>
    entry.path === policyPath && entry.method === 'GET');
  const latestInstance = await waitForResponse(latestStart, (entry) =>
    entry.path === '/api/v1/admin/relay-policy' && entry.method === 'GET');
  validateUserPolicy(await latestUser.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 2,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  assertThat((await latestInstance.payload)?.revision === 2,
    'latest account reload did not observe the node B instance revision');
  const preservedAfterLatest = await readAccountDraft();
  assertThat(preservedAfterLatest.enabled && preservedAfterLatest.cidrs === '10.1.2.0/24' &&
    preservedAfterLatest.ports === '22', 'latest policy reload discarded the account draft');
  const resetStart = relayAdminResponses.length;
  await click('Reset to inherit');
  const reset = await waitForResponse(resetStart, (entry) =>
    entry.path === policyPath && entry.method === 'DELETE');
  const resetPayload = await reset.payload;
  assertThat(reset.status === 200 && reset.hasBearer &&
    exactKeys(reset.body, ['expected_revision']) && reset.body.expected_revision === 2,
  'Web Settings did not reset the account policy using the latest account revision');
  validateUserPolicy(resetPayload, {
    userId: targetUserId,
    inherited: true,
    revision: 3,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.0.0/17'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  await waitFor(() => hasVisibleSemanticText('Selection: inherited from the instance policy'));
  const inheritedDraft = await readAccountDraft();
  assertThat(inheritedDraft.enabled && inheritedDraft.cidrs === '10.1.0.0/17' &&
    inheritedDraft.ports === '22', 'reset did not restore the inherited policy in Settings');
  const nodeBFinal = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(nodeBFinal.payload, {
    userId: targetUserId,
    inherited: true,
    revision: 3,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.0.0/17'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  report('account_policy_reset_cross_node', true);

  setStage('restore an explicit user override before the group lifecycle checks');
  await fillLocator(cidrs, '10.1.1.0/24');
  const restoreUserOverrideStart = relayAdminResponses.length;
  await click('Save override');
  const restoredUserOverride = await waitForResponse(restoreUserOverrideStart, (entry) =>
    entry.path === policyPath && entry.method === 'PUT');
  const restoredUserPayload = await restoredUserOverride.payload;
  assertThat(restoredUserOverride.status === 200 && restoredUserOverride.hasBearer &&
    exactKeys(restoredUserOverride.body, [
      'expected_revision', 'expected_instance_policy_revision',
      'enabled', 'allow_cidrs', 'allow_ports',
    ]) && restoredUserOverride.body.expected_revision === 3 &&
    restoredUserOverride.body.expected_instance_policy_revision === 2 &&
    restoredUserOverride.body.enabled === true &&
    JSON.stringify(restoredUserOverride.body.allow_cidrs) === JSON.stringify(['10.1.1.0/24']) &&
    JSON.stringify(restoredUserOverride.body.allow_ports) === JSON.stringify([22]) &&
    restoredUserPayload?.revision === 4,
  'Web Settings did not restore the explicit account override before group policy checks');
  const nodeBRestoredOverride = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(nodeBRestoredOverride.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 4,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.128/25'], ports: [22] },
  });
  report('account_policy_override_restored_cross_node', true);

  setStage('refresh Group B revision and reset its override to inherit');
  const reloadGroupStart = relayAdminResponses.length;
  await click('Reload group and instance policies, keep drafts');
  const reloadedGroup = await waitForResponse(reloadGroupStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupIds.secondGroupId}` &&
    entry.method === 'GET');
  const reloadedGroupPayload = await reloadedGroup.payload;
  assertThat(reloadedGroup.status === 200 && reloadedGroup.hasBearer &&
    reloadedGroupPayload?.policy?.revision === 2 &&
    JSON.stringify(reloadedGroupPayload?.policy?.policy?.allow_cidrs) ===
      JSON.stringify(['10.1.1.128/25']) &&
    reloadedGroupPayload?.members?.items?.some((member) =>
      member.user_id === targetUserId) === true,
  'Web Settings did not reload Group B policy and membership after the node B update');
  const groupResetButtons = page.getByRole('button', {
    name: 'Reset to inherit', exact: true,
  });
  assertThat(await groupResetButtons.count() === 2,
    'expected the account reset and selected-group reset controls together');
  const groupResetStart = relayAdminResponses.length;
  await groupResetButtons.last().click();
  const groupReset = await waitForResponse(groupResetStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupIds.secondGroupId}/relay-policy` &&
    entry.method === 'DELETE');
  const groupResetPayload = await groupReset.payload;
  assertThat(groupReset.status === 200 && groupReset.hasBearer &&
    exactKeys(groupReset.body, ['expected_revision']) &&
    groupReset.body.expected_revision === 2 &&
    groupResetPayload?.policy?.inherited === true &&
    groupResetPayload?.policy?.revision === 3 &&
    groupResetPayload?.members?.revision === 1 &&
    groupResetPayload?.members?.items?.some((member) =>
      member.user_id === targetUserId) === true &&
    JSON.stringify(groupResetPayload?.policy?.effective_policy?.allow_cidrs) ===
      JSON.stringify(['10.1.0.0/17']),
  'Web Settings did not reset Group B to its inherited instance Relay policy');
  await waitFor(() => hasVisibleSemanticText(
    'Selection: inherited from the instance Relay policy',
  ));
  const groupResetNodeB = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${groupIds.secondGroupId}`,
  );
  assertThat(groupResetNodeB.status === 200 &&
    groupResetNodeB.payload?.policy?.inherited === true &&
    groupResetNodeB.payload?.policy?.revision === 3 &&
    groupResetNodeB.payload?.members?.revision === 1 &&
    groupResetNodeB.payload?.members?.items?.some((member) =>
      member.user_id === targetUserId) === true,
  'PG node B did not observe Group B reset while its member remained assigned');
  const userAfterGroupReset = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(userAfterGroupReset.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 4,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  const allowAfterGroupReset = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.100', 22,
  );
  const denyAfterGroupReset = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.2.10', 22,
  );
  assertThat(allowAfterGroupReset.status === 200 &&
    /^[A-Za-z0-9_-]{43}$/.test(allowAfterGroupReset.payload?.ticket || '') &&
    denyAfterGroupReset.status === 403 &&
    denyAfterGroupReset.payload?.error?.code === 'TARGET_DENIED',
  'Relay ticket authorization did not follow Group B reset-to-inherit');
  report('group_policy_reset_to_inherit_cross_node', true);
  report('group_policy_reset_ticket_allow_deny', true);

  setStage('restore Group B restriction to observe deletion effective-policy change');
  const groupCidrs = cidrFields.nth(1);
  await fillLocator(groupCidrs, '10.1.1.128/25');
  const restoreGroupStart = relayAdminResponses.length;
  await click('Save group override');
  const restoredGroupPolicy = await waitForResponse(restoreGroupStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupIds.secondGroupId}/relay-policy` &&
    entry.method === 'PUT');
  assertThat(restoredGroupPolicy.status === 200 && restoredGroupPolicy.hasBearer &&
    restoredGroupPolicy.body?.expected_revision === 3 &&
    restoredGroupPolicy.body?.expected_instance_policy_revision === 2 &&
    JSON.stringify(restoredGroupPolicy.body?.allow_cidrs) ===
      JSON.stringify(['10.1.1.128/25']) &&
    (await restoredGroupPolicy.payload)?.policy?.revision === 4,
  'Web Settings could not save Group B restriction again after resetting it to inherit');
  const groupBBeforeDelete = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${groupIds.secondGroupId}`,
  );
  assertThat(groupBBeforeDelete.status === 200 &&
    groupBBeforeDelete.payload?.members?.revision === 1 &&
    groupBBeforeDelete.payload?.members?.items?.some((member) =>
      member.user_id === targetUserId) === true &&
    groupBBeforeDelete.payload?.policy?.revision === 4 &&
    JSON.stringify(groupBBeforeDelete.payload?.policy?.policy?.allow_cidrs) ===
      JSON.stringify(['10.1.1.128/25']),
  'Group B lost its invited member or narrowed policy before deletion');
  const allowBeforeGroupDelete = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.200', 22,
  );
  const denyBeforeGroupDelete = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.100', 22,
  );
  assertThat(allowBeforeGroupDelete.status === 200 &&
    /^[A-Za-z0-9_-]{43}$/.test(allowBeforeGroupDelete.payload?.ticket || '') &&
    denyBeforeGroupDelete.status === 403 &&
    denyBeforeGroupDelete.payload?.error?.code === 'TARGET_DENIED',
  'Relay ticket authorization did not return to the Group B /25 restriction before deletion');

  setStage('review and confirm deletion of Group B with its member');
  const deleteButton = page.getByRole('button', {
    name: 'Delete server-managed group', exact: true,
  });
  assertThat(await deleteButton.count() === 1 && await deleteButton.isVisible(),
    'selected Group B did not expose its delete control');
  await deleteButton.click();
  await waitFor(() => hasVisibleSemanticText('Delete server-managed group?'), 10000);
  const cancelDeleteButtons = page.getByRole('button', { name: 'Cancel', exact: true });
  const confirmDeleteButtons = page.getByRole('button', {
    name: 'Delete group', exact: true,
  });
  assertThat(await hasVisibleSemanticText(SECOND_GROUP_NAME) &&
    await hasVisibleSemanticText('Unused Relay tickets for its members will be revoked') &&
    await cancelDeleteButtons.count() === 1 && await cancelDeleteButtons.isVisible() &&
    await confirmDeleteButtons.count() === 1 && await confirmDeleteButtons.isVisible(),
  'Group B deletion confirmation did not show the group identity, revocation warning, and actions');
  report('group_delete_confirmation_reviewed', true);
  const deleteStart = relayAdminResponses.length;
  await confirmDeleteButtons.click();
  const deletedGroup = await waitForResponse(deleteStart, (entry) =>
    entry.path === `/api/v1/admin/relay-groups/${groupIds.secondGroupId}` &&
    entry.method === 'DELETE');
  assertThat(deletedGroup.status === 204 && deletedGroup.hasBearer &&
    exactKeys(deletedGroup.body, [
      'expected_revision', 'expected_membership_revision', 'expected_policy_revision',
    ]) && deletedGroup.body.expected_revision === 1 &&
    deletedGroup.body.expected_membership_revision === 1 &&
    deletedGroup.body.expected_policy_revision === 4,
  'Web Settings did not delete Group B with its current three-way revision preconditions');
  await waitFor(() => hasVisibleSemanticText('Server-managed access group deleted.'));
  const nodeBGroupList = await apiGet(`${NODE_B_URL}/api/v1/admin/relay-groups`);
  const deletedGroupRead = await apiGet(
    `${NODE_B_URL}/api/v1/admin/relay-groups/${groupIds.secondGroupId}`,
  );
  assertThat(nodeBGroupList.status === 200 &&
    nodeBGroupList.payload?.groups?.length === 1 &&
    nodeBGroupList.payload.groups[0]?.group_id === groupIds.groupId &&
    nodeBGroupList.payload.groups[0]?.member_count === 1 &&
    deletedGroupRead.status === 404 &&
    deletedGroupRead.payload?.error?.code === 'RELAY_GROUP_NOT_FOUND',
  'PG node B did not observe deletion and membership cascade for Group B');
  const userAfterGroupDelete = await apiGet(`${NODE_B_URL}${policyPath}`);
  validateUserPolicy(userAfterGroupDelete.payload, {
    userId: targetUserId,
    inherited: false,
    revision: 4,
    instanceRevision: 2,
    policy: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
    effective: { enabled: true, cidrs: ['10.1.1.0/24'], ports: [22] },
  });
  const allowAfterGroupDelete = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.1.100', 22,
  );
  const denyAfterGroupDelete = await requestTargetTicket(
    targetAccessToken, targetDeviceId, '10.1.2.10', 22,
  );
  assertThat(allowAfterGroupDelete.status === 200 &&
    /^[A-Za-z0-9_-]{43}$/.test(allowAfterGroupDelete.payload?.ticket || '') &&
    denyAfterGroupDelete.status === 403 &&
    denyAfterGroupDelete.payload?.error?.code === 'TARGET_DENIED',
  'Relay ticket authorization did not widen to the remaining /24 policy after Group B deletion');
  const consumedAfterDelete = await consumeTargetTicket(allowAfterGroupDelete.payload.ticket);
  assertThat(consumedAfterDelete.upgraded && consumedAfterDelete.sent,
    'post-delete allowed Relay ticket did not reach the one-use WebSocket flow');
  report('group_delete_revoked_ticket_hash', crypto.createHash('sha256')
    .update(allowBeforeGroupDelete.payload.ticket).digest('hex'));
  report('group_delete_consumed_ticket_hash', crypto.createHash('sha256')
    .update(allowAfterGroupDelete.payload.ticket).digest('hex'));
  const relayAudit = await apiGet(`${BASE_URL}/api/v1/admin/audit?limit=100`);
  const serializedRelayAudit = JSON.stringify(relayAudit.payload?.events || []);
  assertThat(relayAudit.status === 200 &&
    serializedRelayAudit.includes('admin.relay_group_policy_reset') &&
    serializedRelayAudit.includes('admin.relay_group_deleted') &&
    !serializedRelayAudit.includes(SECOND_GROUP_NAME) &&
    !serializedRelayAudit.includes(TARGET_USERNAME) &&
    !serializedRelayAudit.includes('10.1.1.128/25'),
  'Relay audit history omitted lifecycle actions or exposed private group/account/policy values');
  report('group_deleted_with_member_cross_node', true);
  report('group_delete_ticket_allow_deny_revocation', true);
}

async function main() {
  assertThat(BASE_URL && NODE_B_URL && USERNAME && PASSWORD && BOOTSTRAP_TOKEN &&
    TARGET_USERNAME && TARGET_PASSWORD,
    'PG Relay browser acceptance environment is incomplete');
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'current Flutter Web bundle is incomplete');
  }
  try {
    setStage('launch isolated Chromium context');
    const options = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) options.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(options);
    context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    page = await context.newPage();
    page.on('pageerror', () => { pageErrors += 1; });
    page.on('requestfailed', () => { requestFailures += 1; });
    watchResponses(page, true);

    await configureAndRegisterAdmin();
    setStage('open PG-backed instance Relay Settings');
    await click('Settings');
    report('settings_button_clicked', true);
    // The Settings shell does not expose a stable "Workspace settings" label in
    // every Flutter semantics layout. The Relay section is the observable
    // destination and the next helper waits for its rendered heading.
    await exerciseInstancePolicyUi();
    const targetAccount = await registerInvitedTarget();
    report('target_account_invited', true);
    const groupIds = await exerciseGroupUi(targetAccount.targetUserId);
    await exerciseUserPolicyUi(
      targetAccount.targetUserId,
      targetAccount.targetDeviceId,
      targetAccount.targetAccessToken,
      groupIds,
    );

    const secretsAbsent = await inspectBrowserSecrets();
    assertThat(secretsAbsent, 'raw password, bootstrap token or access token appeared in browser storage');
    assertThat(pageErrors === 0 && requestFailures === 0 && externalRequests === 0,
      'PG Relay Settings browser reported a page, request or external-network error');
    report('browser_secrets_absent', true);
    report('page_errors', pageErrors);
    report('request_failures', requestFailures);
    report('external_requests', externalRequests);
    setStage('passed');
  } catch (error) {
    let failure = String(error?.message || error?.name || 'Error').split(/\r?\n/, 1)[0];
    for (const secret of [...secrets, USERNAME, accessToken]) {
      if (typeof secret === 'string' && secret.length > 0) failure = failure.replaceAll(secret, '[redacted]');
    }
    console.error(`PG Relay Settings browser acceptance failed at ${stage}: ${failure.slice(0, 320)}`);
    const visibleHeadings = {};
    for (const label of ['Workspace settings', 'SSH relay policy', 'Server-managed access groups']) {
      visibleHeadings[label] = await hasVisibleSemanticText(label).catch(() => false);
    }
    report('safe_diagnostics', JSON.stringify({
      stage,
      pageErrors,
      requestFailures,
      externalRequests,
      relayResponses: relayAdminResponses.map(({ path, method, status }) => ({ path, method, status })),
      visibleHeadings,
      pagePath: (() => { try { return new URL(page.url()).pathname; } catch (_) { return 'unknown'; } })(),
    }));
    process.exitCode = 1;
  } finally {
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
    report('browser_cleanup_complete', true);
  }
}

main().catch((error) => {
  console.error(`PG Relay Settings browser acceptance failed before cleanup: ${error?.name || 'Error'}`);
  process.exitCode = 1;
});
