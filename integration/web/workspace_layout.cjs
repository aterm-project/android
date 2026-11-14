/*
 * WEB-WORKSPACE-LAYOUT-01: exercise saved Workspace layouts through two
 * independently enrolled Chromium profiles. Ordinary fixtures use synthetic
 * documentation Hosts. The two-pane Relay baseline uses isolated TCP sinks;
 * recursive three-pane leaves use isolated temporary OpenSSH servers. Every
 * target binds to this runner's RFC1918 eth0 address and a random port. The
 * server database, SSH account/keys and browser state are removed on exit.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { startSshFixture, startTmuxSshFixture } = require('./ssh_fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = path.join(SERVER_TARGET_DIR, 'debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const RUN_ID = crypto.randomUUID();
const USERNAME = `workspace-web-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `WorkspaceE2e${crypto.randomBytes(20).toString('hex')}9`;
const SSH_USERNAME = `atermius-ws-${RUN_ID.replaceAll('-', '').slice(0, 16)}`;
const TMUX_SSH_USERNAME = `atermius-ws-${crypto.randomBytes(8).toString('hex')}`;
const CREDENTIAL_NAME = `layout-credential-${RUN_ID.slice(0, 8)}`;
const CREDENTIAL_SECRET = `credential-marker-${crypto.randomBytes(24).toString('hex')}`;
const TMUX_CREDENTIAL_NAME = `layout-tmux-credential-${RUN_ID.slice(0, 8)}`;
const TMUX_CREDENTIAL_SECRET = `tmux-credential-marker-${crypto.randomBytes(24).toString('hex')}`;
const MAX_PANES_ONLY = process.env.WORKSPACE_LAYOUT_MAX_PANES_ONLY === '1';
const RENAME_SYNC_ONLY = process.env.WORKSPACE_LAYOUT_RENAME_SYNC_ONLY === '1';
const TMUX_PROCESS_RESTART_ONLY =
  process.env.WORKSPACE_LAYOUT_TMUX_PROCESS_RESTART_ONLY === '1';
const FOCUSED_WORKSPACE_ONLY = MAX_PANES_ONLY || RENAME_SYNC_ONLY ||
  TMUX_PROCESS_RESTART_ONLY;
const HOST_A_NAME = `layout-host-a-${RUN_ID.slice(0, 8)}`;
const HOST_B_NAME = `layout-host-b-${RUN_ID.slice(0, 8)}`;
const HOST_C_NAME = `layout-host-c-${RUN_ID.slice(0, 8)}`;
const HOST_D_NAME = `layout-host-d-${RUN_ID.slice(0, 8)}`;
const HOST_SPLIT_NAME = `layout-host-split-${RUN_ID.slice(0, 8)}`;
const HOST_TMUX_NAME = `layout-host-tmux-${RUN_ID.slice(0, 8)}`;
const HOST_A_ADDRESS = '198.51.100.21';
const HOST_B_ADDRESS = '203.0.113.33';
const HOST_C_ADDRESS = '192.0.2.44';
const HOST_D_ADDRESS = '192.0.2.55';
const WORKSPACE_NAME = `workspace-layout-${RUN_ID.slice(0, 8)}`;
const SPLIT_WORKSPACE_NAME = `workspace-split-${RUN_ID.slice(0, 8)}`;
const NESTED_SPLIT_WORKSPACE_NAME = `workspace-nested-split-${RUN_ID.slice(0, 8)}`;
const MAX_PANES_WORKSPACE_NAME = `workspace-max-panes-${RUN_ID.slice(0, 8)}`;
const RENAME_SYNC_OLD_NAME = `workspace-rename-before-${RUN_ID.slice(0, 8)}`;
const RENAME_SYNC_NEW_NAME = `workspace-rename-after-${RUN_ID.slice(0, 8)}`;
const TMUX_WORKSPACE_NAME = `workspace-tmux-${RUN_ID.slice(0, 8)}`;
const WORKSPACE_BRANCH_B_COPY_NAME = `workspace-branch-b-copy-${RUN_ID.slice(0, 8)}`;
const TERMINAL_OUTPUT_CANARY = `terminal-output-marker-${RUN_ID}`;
const TMUX_COMMAND_MARKER = `tmux-command-marker-${RUN_ID}`;
const TMUX_OUTPUT_MARKER = `tmux-output-marker-${RUN_ID}`;
const SYNC_BUTTON_LABEL = /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Rebuilding snapshot|Key update needed|Read-only|Sign in needed|Device revoked|Vault deletion pending · read-only|Sync now)$/;
const PRIVACY_MARKERS = [
  WORKSPACE_NAME,
  HOST_A_NAME,
  HOST_B_NAME,
  HOST_C_NAME,
  HOST_D_NAME,
  HOST_SPLIT_NAME,
  HOST_TMUX_NAME,
  HOST_A_ADDRESS,
  HOST_B_ADDRESS,
  HOST_C_ADDRESS,
  HOST_D_ADDRESS,
  SPLIT_WORKSPACE_NAME,
  NESTED_SPLIT_WORKSPACE_NAME,
  MAX_PANES_WORKSPACE_NAME,
  RENAME_SYNC_OLD_NAME,
  RENAME_SYNC_NEW_NAME,
  TMUX_WORKSPACE_NAME,
  WORKSPACE_BRANCH_B_COPY_NAME,
  CREDENTIAL_NAME,
  CREDENTIAL_SECRET,
  SSH_USERNAME,
  TMUX_CREDENTIAL_NAME,
  TMUX_CREDENTIAL_SECRET,
  TMUX_SSH_USERNAME,
  TERMINAL_OUTPUT_CANARY,
  TMUX_COMMAND_MARKER,
  TMUX_OUTPUT_MARKER,
  'split_ratio_basis_points',
  'horizontal',
  'vertical',
];

let stage = 'preflight';

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function safeRuntimeCategory(value) {
  const message = String(value || '').toLowerCase();
  if (message.includes('content security policy') || message.includes('csp')) return 'csp';
  if (message.includes('webassembly') || message.includes('wasm')) return 'wasm';
  if (message.includes('canvaskit') || message.includes('canvas')) return 'canvaskit';
  if (message.includes('sodium')) return 'sodium';
  if (message.includes('flutter')) return 'flutter-bootstrap';
  if (message.includes('failed to load resource')) return 'resource-load';
  if (message.includes('networkerror') || message.includes('network error')) return 'network';
  return 'browser-runtime';
}

function staticResourceName(rawUrl) {
  try {
    const name = new URL(rawUrl).pathname.split('/').at(-1);
    return /\.(?:js|mjs|wasm|json|css|png|ttf|otf|svg)$/i.test(name) ? name : null;
  } catch (_) {
    return null;
  }
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: options.capture ? ['ignore', 'pipe', 'pipe'] : 'ignore',
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${path.basename(command)} exited unsuccessfully`);
  }
  return result.stdout || '';
}

function directPasswordSshAttempt({ address, port, password, command }) {
  const result = spawnSync(process.env.SSHPASS_PATH || 'sshpass', [
    '-e',
    process.env.SSH_PATH || 'ssh',
    '-p', String(port),
    '-o', 'BatchMode=no',
    '-o', 'ConnectTimeout=5',
    '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'NumberOfPasswordPrompts=1',
    '-o', 'PasswordAuthentication=yes',
    '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    `${SSH_USERNAME}@${address}`,
    command,
  ], {
    cwd: ROOT,
    env: { ...process.env, SSHPASS: password },
    encoding: 'utf8',
    timeout: 20000,
    maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error || result.signal) {
    throw new Error('direct OpenSSH password-authentication probe did not complete');
  }
  return {
    status: result.status,
    stdout: result.stdout || '',
  };
}

async function acceptFirstUseSshHostKey(page, hostName, expectedFingerprint) {
  stage = 'wait for visible first-use SSH host-key trust action';
  const trustButton = page.getByRole('button', {
    name: 'Trust after verification', exact: true,
  });
  try {
    await trustButton.waitFor({ state: 'visible', timeout: 20000 });
  } catch (error) {
    const ui = await page.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
          node.textContent || ''].join(' ').replace(/\s+/g, ' ').trim());
      const joined = labels.join(' ');
      const dialogs = [...document.querySelectorAll('[role="dialog"], [role="alertdialog"]')]
        .filter(visible);
      const alerts = [...document.querySelectorAll('[role="alert"], [aria-live]')]
        .filter(visible);
      const alertText = alerts.map((node) => [
        node.getAttribute('aria-label') || '',
        node.innerText || '',
        node.textContent || '',
      ].join(' ')).join(' ').replace(/\s+/g, ' ').toLowerCase();
      return {
        verifyHostKeyPromptVisible: joined.includes('Verify SSH host key'),
        trustActionVisible: joined.includes('Trust after verification'),
        queueApprovalActionVisible: joined.includes('Queue approval and stop'),
        rejectActionVisible: joined.includes('Reject'),
        changedKeyOrConflictNoticeVisible:
          /host key.{0,30}(changed|conflict)|conflicting ssh keys/i.test(joined),
        authenticationOrNetworkNoticeVisible:
          /authentication failed|credential|password rejected|network error|connection failed/i.test(joined),
        knownHostApprovalSyncNoticeVisible:
          /vault sync did not confirm|vault changed while ssh host-key approval|ssh host-key approval.*sync|审批.*同步确认/i.test(alertText),
        authenticationFailureAlertVisible:
          /authentication failed|password rejected|credential is unavailable|credentials unavailable/i.test(alertText),
        relayOrNetworkFailureAlertVisible:
          /relay.*(failed|unavailable|ticket)|network error|connection failed|request.*failed/i.test(alertText),
        visibleDialogCount: dialogs.length,
        visibleAlertCount: alerts.length,
      };
    }).catch(() => ({ snapshotAvailable: false }));
    stage = `first-use SSH trust action unavailable (${JSON.stringify({
      ...ui,
      errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
    })})`;
    throw error;
  }
  const trustButtonCount = await trustButton.count().catch(() => 0);
  assertThat(trustButtonCount === 1,
    `first-use host-key trust action was not unique for ${hostName}`);
  stage = 'compare displayed first-use SSH fingerprint with the temporary SSHD key';
  const fingerprintDeadline = Date.now() + 10000;
  let fingerprintEvidence = null;
  while (Date.now() < fingerprintDeadline) {
    fingerprintEvidence = await page.locator('flt-semantics').evaluateAll(
      (nodes, expected) => {
        const allSemanticText = nodes.flatMap((node) => [
          node.getAttribute('aria-label') || '',
          node.innerText || '',
          node.textContent || '',
        ]).join('\n');
        const accessibleFingerprintNodes = [...document.querySelectorAll(
          '[aria-label], [aria-description], [aria-valuetext], [title], [alt]',
        )].flatMap((node) => {
          const style = getComputedStyle(node);
          const bounds = node.getBoundingClientRect();
          const attributes = [...node.attributes].filter((attribute) =>
            ['aria-label', 'aria-description', 'aria-valuetext', 'title', 'alt']
              .includes(attribute.name) && attribute.value.includes(expected));
          if (!attributes.length) return [];
          return [{
            visible: style.display !== 'none' && style.visibility !== 'hidden' &&
              bounds.width > 0 && bounds.height > 0 && bounds.bottom > 0 &&
              bounds.right > 0 && bounds.top < innerHeight && bounds.left < innerWidth,
            attributeNames: attributes.map((attribute) => attribute.name),
            text: attributes.map((attribute) => attribute.value).join('\n'),
          }];
        });
        const accessibleFingerprints = [...new Set(accessibleFingerprintNodes
          .filter((item) => item.visible)
          .flatMap((item) => item.text.match(/SHA256:[A-Za-z0-9+/=]+/g) || []))];
        const visibleText = nodes.flatMap((node) => {
          const style = getComputedStyle(node);
          const bounds = node.getBoundingClientRect();
          if (style.display === 'none' || style.visibility === 'hidden' ||
              bounds.width <= 0 || bounds.height <= 0 ||
              bounds.bottom <= 0 || bounds.right <= 0 ||
              bounds.top >= innerHeight || bounds.left >= innerWidth) return [];
          return [`${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`];
        }).join('\n');
        const fingerprints = [...new Set(
          visibleText.match(/SHA256:[A-Za-z0-9+/=]+/g) || [],
        )];
        const semanticFingerprints = [...new Set(
          allSemanticText.match(/SHA256:[A-Za-z0-9+/=]+/g) || [],
        )];
        return {
          trustPromptVisible: visibleText.includes('Verify SSH host key') &&
            visibleText.includes('Trust after verification'),
          expectedFingerprintVisible: visibleText.includes(expected),
          expectedFingerprintInSemantics: allSemanticText.includes(expected),
          semanticFingerprintLabelCount: semanticFingerprints.length,
          visibleFingerprintCount: fingerprints.length,
          expectedFingerprintInVisibleAccessibleAttribute:
            accessibleFingerprints.length === 1 &&
            accessibleFingerprints[0] === expected,
          exactAccessibleFingerprintMatch: accessibleFingerprints.length === 1 &&
            accessibleFingerprints[0] === expected,
          visibleAccessibleFingerprintCount: accessibleFingerprints.length,
          accessibleAttributeNames: [...new Set(accessibleFingerprintNodes
            .flatMap((item) => item.attributeNames))],
          visibleSemanticNodeCount: nodes.filter((node) => {
            const bounds = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return style.display !== 'none' && style.visibility !== 'hidden' &&
              bounds.width > 0 && bounds.height > 0 && bounds.bottom > 0 &&
              bounds.right > 0 && bounds.top < innerHeight && bounds.left < innerWidth;
          }).length,
          bodyTextContainsExpectedFingerprint:
            (document.body.innerText || '').includes(expected),
          domAttributeContainsExpectedFingerprint: [...document.querySelectorAll('*')]
            .some((node) => [...node.attributes].some((attribute) =>
              attribute.value.includes(expected))),
        };
      }, expectedFingerprint,
    ).catch(() => null);
    if (fingerprintEvidence?.trustPromptVisible &&
        fingerprintEvidence.expectedFingerprintInVisibleAccessibleAttribute &&
        fingerprintEvidence.visibleAccessibleFingerprintCount === 1) break;
    await page.waitForTimeout(100);
  }
  if (!(fingerprintEvidence?.trustPromptVisible &&
      fingerprintEvidence.expectedFingerprintInVisibleAccessibleAttribute &&
      fingerprintEvidence.visibleAccessibleFingerprintCount === 1)) {
    stage = `first-use SSH fingerprint semantic check (${JSON.stringify({
      trustPromptVisible: fingerprintEvidence?.trustPromptVisible === true,
      expectedFingerprintVisible: fingerprintEvidence?.expectedFingerprintVisible === true,
      expectedFingerprintInSemantics:
        fingerprintEvidence?.expectedFingerprintInSemantics === true,
      semanticFingerprintLabelCount:
        fingerprintEvidence?.semanticFingerprintLabelCount ?? 0,
      expectedFingerprintInVisibleAccessibleAttribute:
        fingerprintEvidence?.expectedFingerprintInVisibleAccessibleAttribute === true,
      visibleAccessibleFingerprintCount:
        fingerprintEvidence?.visibleAccessibleFingerprintCount ?? 0,
      accessibleAttributeNames: fingerprintEvidence?.accessibleAttributeNames || [],
      visibleFingerprintCount: fingerprintEvidence?.visibleFingerprintCount ?? 0,
      visibleSemanticNodeCount: fingerprintEvidence?.visibleSemanticNodeCount ?? 0,
      bodyTextContainsExpectedFingerprint:
        fingerprintEvidence?.bodyTextContainsExpectedFingerprint === true,
      domAttributeContainsExpectedFingerprint:
        fingerprintEvidence?.domAttributeContainsExpectedFingerprint === true,
    })})`;
  }
  assertThat(fingerprintEvidence?.trustPromptVisible &&
    fingerprintEvidence.expectedFingerprintInVisibleAccessibleAttribute &&
    fingerprintEvidence.visibleAccessibleFingerprintCount === 1,
    `first-use host-key fingerprint did not match the fixture for ${hostName}`);
  stage = 'approve the verified first-use SSH host key';
  await trustButton.click();
  const deadline = Date.now() + 30000;
  let connected = null;
  let latestRuntime = null;
  while (Date.now() < deadline) {
    const snapshot = await workspaceTerminalRuntimeSnapshot(page, [hostName]);
    latestRuntime = snapshot[0] || null;
    if (snapshot[0]?.count === 1 && snapshot[0]?.connectedCount === 1 &&
        snapshot[0]?.failedCount === 0) {
      connected = snapshot[0];
      break;
    }
    await page.waitForTimeout(100);
  }
  if (!connected) {
    const uiState = await page.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
          node.textContent || ''].join(' ').replace(/\s+/g, ' ').trim());
      const joined = labels.join(' ');
      return {
        verifyHostKeyPromptVisible: joined.includes('Verify SSH host key'),
        trustActionVisible: joined.includes('Trust after verification'),
        queueApprovalActionVisible: joined.includes('Queue approval and stop'),
        changedKeyOrConflictNoticeVisible:
          /host key.{0,30}(changed|conflict)|conflicting ssh keys/i.test(joined),
        credentialNoticeVisible: /credential|password authentication/i.test(joined),
        networkNoticeVisible: /network|relay|ticket|connection failed/i.test(joined),
        visibleFailureAlertCount: [...document.querySelectorAll(
          '[role="alert"], [aria-live]',
        )].filter(visible).length,
      };
    }).catch(() => ({ snapshotAvailable: false }));
    stage = `SSH runtime after verified host-key approval (${JSON.stringify({
      runtimeCount: latestRuntime?.count ?? 0,
      connectingCount: latestRuntime?.connectingCount ?? 0,
      connectedCount: latestRuntime?.connectedCount ?? 0,
      failedCount: latestRuntime?.failedCount ?? 0,
      uiState,
    })})`;
  }
  assertThat(connected,
    `real SSH session did not connect after first-use trust for ${hostName}`);
  return {
    trustActionUnique: trustButtonCount === 1,
    fingerprintMatchesFixture:
      fingerprintEvidence.expectedFingerprintInVisibleAccessibleAttribute &&
      fingerprintEvidence.visibleAccessibleFingerprintCount === 1,
    runtimeConnected: connected.connectedCount === 1,
  };
}

async function completeWorkspaceSshAuthentication(
  page, paneNumber, hostName, server, baseline, relay,
) {
  let relayBaseline = {
    tickets: 0,
    sockets: 0,
    socketCloses: 0,
    activeSockets: 0,
    syncApiEvents: 0,
  };
  let relayBaselineAvailable = false;
  let phase = 'initialize pane Relay counters';
  stage = 'SSH authentication helper entered';
  try {
    relayBaseline = {
      tickets: relay.attempts.B.length,
      sockets: relay.webSockets.B,
      socketCloses: relay.closes.B,
      activeSockets: relay.activeSockets.B.size,
      syncApiEvents: relay.syncApiEvents.B.length,
    };
    relayBaselineAvailable = true;
    phase = 'host-key prompt and fingerprint verification';
    stage = 'SSH authentication helper waiting for host-key trust';
    const trust = await acceptFirstUseSshHostKey(
      page, hostName, server.hostFingerprint);
    phase = 'OpenSSH password authentication and shell session';
    const authenticated = await waitForCaptured(() => {
      const summary = server.summary();
      return summary.passwordAccepted === baseline.passwordAccepted + 1 &&
        summary.shellSessions === baseline.shellSessions + 1 ? summary : null;
    }, `OpenSSH password authentication and shell session for ${hostName}`, 20000);
    phase = 'verify OpenSSH handshake and authenticated shell counters';
    assertThat(authenticated.keyExchangeStarted > baseline.keyExchangeStarted &&
      authenticated.clientBannerReceived > baseline.clientBannerReceived &&
      authenticated.serverBannerEmitted > baseline.serverBannerEmitted,
    `real SSH banner exchange and key exchange were not recorded for ${hostName}`);
    return {
      firstUseHostKeyTrustAction: trust.trustActionUnique,
      displayedFingerprintMatchesSshd: trust.fingerprintMatchesFixture,
      terminalRuntimeConnected: trust.runtimeConnected,
      sshdPasswordAcceptedDelta:
        authenticated.passwordAccepted - baseline.passwordAccepted,
      sshdPasswordRejectedDelta:
        authenticated.passwordRejected - baseline.passwordRejected,
      sshdShellSessionDelta:
        authenticated.shellSessions - baseline.shellSessions,
      sshdKeyExchangeDelta:
        authenticated.keyExchangeStarted - baseline.keyExchangeStarted,
      sshdClientBannerDelta:
        authenticated.clientBannerReceived - baseline.clientBannerReceived,
    };
  } catch (error) {
    const innerStage = stage;
    // Preserve safe evidence even if a follow-up diagnostic itself encounters
    // a closed page or fixture error. The outer runner intentionally omits raw
    // exception text because it can contain user supplied terminal data.
    stage = `SSH first-use/authentication phase failed (${JSON.stringify({
      phase,
      innerStage,
      errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
      diagnostics: 'pending',
    })})`;
    let summary = null;
    let runtime = null;
    let paneUi = null;
    let summaryAvailable = false;
    let runtimeSnapshotAvailable = false;
    try {
      summary = server.summary();
      summaryAvailable = true;
    } catch (_) {}
    try {
      runtime = await workspaceTerminalRuntimeSnapshot(page, [hostName]);
      runtimeSnapshotAvailable = true;
    } catch (_) {}
    try {
      paneUi = await nestedPaneConnectionUiSnapshot(page, paneNumber, hostName);
    } catch (_) {}
    const tickets = (relay.attempts.B || []).slice(relayBaseline.tickets);
    const syncApiEvents = (relay.syncApiEvents.B || [])
      .slice(relayBaseline.syncApiEvents);
    const expectedTargetFlag = hostName === HOST_SPLIT_NAME
      ? 'targetMatchesFirstSplitHost'
      : hostName === HOST_C_NAME
        ? 'targetMatchesThirdSplitHost'
        : 'targetMatchesSecondSplitHost';
    stage = `SSH first-use/authentication phase failed (${JSON.stringify({
      phase,
      innerStage,
      errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
      summaryAvailable,
      runtimeSnapshotAvailable,
      paneUi: paneUi ? {
        uniquePaneHostPair: paneUi.uniquePaneHostPair,
        connectActionCount: paneUi.connectActionCount,
        focusActionCount: paneUi.focusActionCount,
        visibleAlertNodeCount: paneUi.visibleAlertNodeCount,
        visibleFailureNodeCount: paneUi.visibleFailureNodeCount,
        alertCategory: paneUi.alertCategory,
      } : null,
      syncApiEvents: syncApiEvents.slice(-8),
      relayBaselineAvailable,
      retryTicketCount: tickets.length,
      completedRetryTicketCount: tickets.filter((ticket) => ticket.status !== null).length,
      retryTicketStatus200Count: tickets.filter((ticket) => ticket.status === 200).length,
      retryTicketExpectedTargetMatchCount: tickets.filter((ticket) =>
        ticket[expectedTargetFlag] === true).length,
      relayWebSocketDelta: relay.webSockets.B - relayBaseline.sockets,
      relayWebSocketCloseDelta:
        relay.closes.B - relayBaseline.socketCloses,
      activeRelayWebSocketDelta:
        relay.activeSockets.B.size - relayBaseline.activeSockets,
      runtime: runtime?.[0] || null,
      bannerDelta: summary
        ? summary.serverBannerEmitted - baseline.serverBannerEmitted : null,
      clientBannerDelta:
        summary ? summary.clientBannerReceived - baseline.clientBannerReceived : null,
      keyExchangeDelta:
        summary ? summary.keyExchangeStarted - baseline.keyExchangeStarted : null,
      passwordAcceptedDelta:
        summary ? summary.passwordAccepted - baseline.passwordAccepted : null,
      passwordRejectedDelta:
        summary ? summary.passwordRejected - baseline.passwordRejected : null,
      shellSessionDelta:
        summary ? summary.shellSessions - baseline.shellSessions : null,
      tcpConnectionsOpen: summary?.tcpConnectionsOpen ?? null,
      tcpConnectionsClosedDelta:
        summary ? summary.tcpConnectionsClosed - baseline.tcpConnectionsClosed : null,
    })})`;
    throw error;
  }
}

async function unusedPort(address = '127.0.0.1') {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, address, resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => {
    listener.close((error) => error ? reject(error) : resolve());
  });
  return port;
}

function localEth0Address() {
  const result = spawnSync('ip', [
    '-o', '-4', 'addr', 'show', 'dev', 'eth0', 'scope', 'global',
  ], { encoding: 'utf8', timeout: 5000 });
  const address = (result.stdout || '').match(/\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\//)?.[1];
  const octets = address?.split('.').map(Number);
  const isPrivateRfc1918 = octets?.length === 4 && octets.every((octet) =>
    Number.isInteger(octet) && octet >= 0 && octet <= 255) && (
      octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168));
  if (result.status !== 0 || !address || !isPrivateRfc1918 ||
      [HOST_A_ADDRESS, HOST_B_ADDRESS, HOST_C_ADDRESS, HOST_D_ADDRESS]
        .includes(address)) return null;
  return address;
}

async function startIsolatedSink(address, port) {
  const acceptedSockets = new Set();
  let totalAccepted = 0;
  const server = net.createServer((socket) => {
    acceptedSockets.add(socket);
    totalAccepted++;
    socket.once('close', () => acceptedSockets.delete(socket));
    socket.on('error', () => {});
    // Consume client-side identification and KEX bytes so a synthetic sink
    // cannot block or keep the TCP stream open due to a full readable buffer.
    socket.resume();
    // The Relay half-closes its TCP write side when the client disconnects.
    // Mirror that FIN so the synthetic upstream socket reaches close promptly.
    socket.once('end', () => socket.end());
    // This synthetic SSH identification string lets transport setup advance;
    // the sink does not authenticate users or execute commands.
    socket.write('SSH-2.0-AtermiusAcceptanceSink\r\n');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, address, resolve);
  });
  return {
    server,
    port: server.address().port,
    get acceptedCount() { return totalAccepted; },
    get activeCount() { return acceptedSockets.size; },
    closeSockets() {
      for (const socket of acceptedSockets) socket.destroy();
    },
  };
}

async function waitForCaptured(predicate, label, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Workspace acceptance capture timed out: ${label}`);
}

function tmuxFixtureProbeErrorCategory(error) {
  const message = String(error?.message || '').toLowerCase();
  if (message.includes('enumerate fixture sessions')) {
    return 'session-enumeration-failed';
  }
  if (message.includes('enumerate fixture clients')) {
    return 'client-enumeration-failed';
  }
  if (message.includes('runtime is unavailable')) {
    return 'probe-runtime-unavailable';
  }
  if (message.includes('malformed fixture state')) {
    return 'malformed-state';
  }
  if (message.includes('requires a tmux ssh fixture server')) {
    return 'invalid-fixture';
  }
  return 'probe-error';
}

async function waitForTmuxState(fixture, predicate, label, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let probeCount = 0;
  let probeErrorCount = 0;
  let lastProbeErrorCategory = null;
  while (Date.now() < deadline) {
    probeCount += 1;
    try {
      const snapshot = fixture.tmuxSnapshot();
      if (predicate(snapshot)) {
        return {
          ...snapshot,
          fixtureProbeDiagnostics: {
            probeCount,
            probeErrorCount,
            lastProbeErrorCategory,
          },
        };
      }
    } catch (error) {
      probeErrorCount += 1;
      lastProbeErrorCategory = tmuxFixtureProbeErrorCategory(error);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const error = new Error(`tmux fixture state did not reach ${label}`);
  error.name = 'TmuxFixtureStateWaitError';
  error.probeCount = probeCount;
  error.probeErrorCount = probeErrorCount;
  error.lastProbeErrorCategory = lastProbeErrorCategory;
  throw error;
}

function chromiumProfileProcessIdentity(profileDir) {
  assertThat(fs.existsSync('/proc'),
    'tmux process-restart acceptance requires Linux /proc');
  const expectedArg = `--user-data-dir=${profileDir}`;
  const matches = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8')
        .split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      matches.push({
        pid: Number(entry),
        processGroup: Number(fields[2]),
        startTimeTicks: fields[19],
      });
    } catch (_) {
      // Chromium may exit while /proc is being sampled.
    }
  }
  assertThat(matches.length === 1 && matches[0].processGroup === matches[0].pid,
    'isolated persistent Chromium process was not uniquely identified');
  return matches[0];
}

function chromiumProfileHasLiveProcesses(profileDir) {
  if (!profileDir || !fs.existsSync('/proc')) return false;
  const expectedArg = `--user-data-dir=${profileDir}`;
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const args = fs.readFileSync(`/proc/${entry}/cmdline`).toString('utf8')
        .split('\0');
      if (!args.includes(expectedArg)) continue;
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (fields[0] !== 'Z' && fields[0] !== 'X') return true;
    } catch (_) {
      // Chromium may exit while /proc is being sampled.
    }
  }
  return false;
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

async function waitForProcessGroupExit(groupId, timeoutMs = 5000) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  while (Date.now() < deadline) {
    if (!processGroupHasLiveMembers(groupId)) {
      return { exited: true, elapsedMs: Date.now() - startedAt };
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return {
    exited: !processGroupHasLiveMembers(groupId),
    elapsedMs: Date.now() - startedAt,
  };
}

function localStorageLevelDbFingerprint(profileDir) {
  const directory = path.join(profileDir, 'Default', 'Local Storage', 'leveldb');
  try {
    return fs.readdirSync(directory).map((name) => {
      const stat = fs.statSync(path.join(directory, name));
      const kind = name.endsWith('.log') ? 'log'
        : name.endsWith('.ldb') || name.endsWith('.sst') ? 'table'
          : name.startsWith('MANIFEST-') ? 'manifest'
            : name === 'CURRENT' ? 'current' : 'metadata';
      return `${kind}:${stat.size}:${Math.trunc(stat.mtimeMs)}`;
    }).sort().join('|');
  } catch (_) {
    return 'missing';
  }
}

async function waitForLocalStorageLevelDbStable(profileDir, previousFingerprint,
    timeoutMs = 5000) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let previous = previousFingerprint;
  let stableSamples = 0;
  let changed = false;
  while (Date.now() < deadline) {
    const current = localStorageLevelDbFingerprint(profileDir);
    changed ||= current !== previousFingerprint;
    if (current === previous) stableSamples++;
    else stableSamples = 0;
    if (stableSamples >= 2) {
      return { changed, stable: true, elapsedMs: Date.now() - startedAt };
    }
    previous = current;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return { changed, stable: false, elapsedMs: Date.now() - startedAt };
}

async function safeSecureStorePresence(page, expectedOrigin) {
  return page.evaluate((origin) => {
    const inspect = (storage) => {
      const found = new Set();
      const deviceEntries = [];
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index) || '';
        if (key.endsWith('.device')) {
          found.add('device');
          deviceEntries.push([key, storage.getItem(key) || '']);
        }
        else if (key.includes('.session.')) found.add('session');
        else if (key.includes('.refresh.')) found.add('refresh');
        else if (key === 'FlutterSecureStorage') found.add('secure-store-key');
        else if (key.startsWith('FlutterSecureStorage.')) found.add('other-secure-store');
        else found.add('other');
      }
      return { kinds: [...found].sort(), deviceEntries };
    };
    const local = inspect(window.localStorage);
    const session = inspect(window.sessionStorage);
    const deviceEntries = [...local.deviceEntries, ...session.deviceEntries]
      .sort((left, right) => left[0].localeCompare(right[0]));
    const digestBytes = new TextEncoder().encode(JSON.stringify(deviceEntries));
    return crypto.subtle.digest('SHA-256', digestBytes).then((digest) => ({
      expectedOrigin: window.location.origin === origin,
      localStorageKinds: local.kinds,
      sessionStorageKinds: session.kinds,
      deviceRecordPresent: deviceEntries.length > 0,
      deviceStoreFingerprint: [...new Uint8Array(digest)]
        .map((value) => value.toString(16).padStart(2, '0')).join(''),
    }));
  }, new URL(expectedOrigin).origin).catch(() => ({ diagnosticUnavailable: true }));
}

async function waitReady(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Poll the isolated loopback server while it starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('server readiness timed out');
}

function markerScan(value, additionalMarkers = []) {
  const text = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  return [...PRIVACY_MARKERS, ...additionalMarkers]
    .filter((marker) => typeof marker === 'string' && marker.length > 0)
    .every((marker) => !text.includes(marker)) &&
    !/atermius_[0-9a-f]{32}/i.test(text);
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function waitForText(page, text, timeoutMs = 20000) {
  return page.getByText(text, { exact: false }).first().waitFor({
    state: 'visible',
    timeout: timeoutMs,
  });
}

async function encryptedCredentialSaveSnapshot(page, {
  expectedName,
  expectedUsername,
  expectedPassword,
  pageErrorCount,
}) {
  const saveButton = page.getByRole('button', {
    name: 'Save encrypted credential', exact: true,
  });
  const saveButtonCount = await saveButton.count().catch(() => 0);
  let visibleSaveButtonCount = 0;
  let enabledSaveButtonCount = 0;
  for (let index = 0; index < saveButtonCount; index += 1) {
    const candidate = saveButton.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    visibleSaveButtonCount++;
    if (await candidate.isEnabled().catch(() => false)) enabledSaveButtonCount++;
  }
  const formSnapshot = await page.evaluate(({ name, username, password }) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const fields = (label) => [...document.querySelectorAll('input, textarea')]
      .filter((node) => (node.getAttribute('aria-label') || '').includes(label));
    const nameFields = fields('Credential name');
    const usernameFields = fields('SSH username');
    const passwordFields = fields('Password');
    const visibleFeedback = [...document.querySelectorAll(
      '[role="alert"], [aria-live="polite"], [aria-live="assertive"]',
    )].filter(visible);
    const classify = (text) => {
      const value = text.toLowerCase();
      if (/credential|password|凭据|密码/.test(value)) return 'credential';
      if (/vault|unlock|key|密钥|保险库/.test(value)) return 'vault';
      if (/network|fetch|server|网络|服务器/.test(value)) return 'network';
      if (/required|invalid|format|必填|无效|格式/.test(value)) return 'validation';
      if (/saved|success|已保存|成功/.test(value)) return 'success';
      if (/error|failed|could not|unable|失败|错误|无法/.test(value)) return 'save-error';
      return 'other';
    };
    const feedbackText = visibleFeedback.map((node) =>
      node.getAttribute('aria-label') || node.innerText || node.textContent || '');
    const bodyText = document.body?.innerText || '';
    const visibleSemanticNodes = [...document.querySelectorAll('flt-semantics')]
      .filter(visible);
    const labelOf = (node) => [node.getAttribute('aria-label') || '',
      node.innerText || '', node.textContent || ''].join(' ');
    const visibleSemanticContainsName = visibleSemanticNodes
      .some((node) => labelOf(node).includes(name));
    const visibleSemanticContainsUsername = visibleSemanticNodes
      .some((node) => labelOf(node).includes(username));
    const credentialSemanticNodes = visibleSemanticNodes.filter((node) =>
      labelOf(node).includes('Credential:'));
    const knownPageLabels = new Set([
      'SSH credentials', 'Saved hosts', 'Saved workspaces', 'Your server fleet',
      'Hosts', 'Credentials', 'Workspaces', 'Add credential', 'Create credential',
      'Save encrypted credential', 'Edit credential', 'Close', 'Sync now',
      'Sign in and unlock', 'Unlock',
    ]);
    const visiblePageLabels = visibleSemanticNodes.map((node) =>
      (node.getAttribute('aria-label') || node.innerText || '').trim())
      .filter((label) => knownPageLabels.has(label));
    const visibleActionLabels = [...document.querySelectorAll(
      'flt-semantics[role="button"]',
    )].filter(visible).map((node) =>
      (node.getAttribute('aria-label') || node.innerText || '').trim())
      .filter((label) => knownPageLabels.has(label));
    const credentialIdentifierNodes = [...document.querySelectorAll(
      '[id^="ssh-credential-"], [identifier^="ssh-credential-"], ' +
      '[data-semantics-identifier^="ssh-credential-"]',
    )];
    const dialogVisible = [...document.querySelectorAll('[role="dialog"]')]
      .some(visible);
    return {
      credentialNameFieldCount: nameFields.length,
      credentialNameVisibleCount: nameFields.filter(visible).length,
      credentialNameMatches: nameFields.some((node) => node.value === name),
      usernameFieldCount: usernameFields.length,
      usernameVisibleCount: usernameFields.filter(visible).length,
      usernameMatches: usernameFields.some((node) => node.value === username),
      passwordFieldCount: passwordFields.length,
      passwordVisibleCount: passwordFields.filter(visible).length,
      passwordMatches: passwordFields.some((node) => node.value === password),
      passwordLength: passwordFields[0]?.value?.length || 0,
      savedCredentialNameInBody: bodyText.includes(name),
      savedCredentialNameInVisibleSemantics: visibleSemanticContainsName,
      savedCredentialUsernameInVisibleSemantics: visibleSemanticContainsUsername,
      visibleCredentialSemanticNodeCount: credentialSemanticNodes.length,
      sshCredentialIdentifierNodeCount: credentialIdentifierNodes.length,
      credentialPageVisible: visiblePageLabels.includes('SSH credentials'),
      safeVisiblePageLabels: [...new Set(visiblePageLabels)],
      safeVisibleActionLabels: [...new Set(visibleActionLabels)],
      dialogVisible,
      visibleAlertCount: visibleFeedback.length,
      safeAlertCategories: [...new Set(feedbackText.map(classify))],
    };
  }, {
    name: expectedName,
    username: expectedUsername,
    password: expectedPassword,
  }).catch(() => ({ pageProbeAvailable: false }));
  return {
    saveButtonCount,
    visibleSaveButtonCount,
    enabledSaveButtonCount,
    pageErrorCount,
    ...formSnapshot,
  };
}

async function observeWorkspaceSaveFeedback(page, workspaceName) {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    const feedback = await page.evaluate((name) => {
      const body = document.body?.innerText || '';
      if (body.includes(name)) return 'workspace-name-rendered';
      if (body.includes('Workspace saved encrypted to this Vault.') ||
          body.includes('工作区已加密保存')) return 'save-success-notice';
      if (body.includes('请先打开至少一个终端标签')) return 'no-terminal-tabs';
      if (body.includes('终端引用的主机已不在当前 Vault')) return 'stale-terminal-host';
      if (body.includes('工作区只能新增引用当前 Vault 中现有的主机')) return 'missing-active-host';
      const visibleAlert = [...document.querySelectorAll('[role="alert"]')]
        .some((node) => {
          const rect = node.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        });
      if (visibleAlert) return 'alert-visible';
      return 'no-feedback';
    }, workspaceName).catch(() => 'page-unavailable');
    if (feedback !== 'no-feedback') return feedback;
    await page.waitForTimeout(100);
  }
  return 'no-feedback';
}

async function visibleButton(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      const item = matches.nth(index);
      if (await item.isVisible().catch(() => false)) return item;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`visible button unavailable: ${label}`);
}

async function workspaceUiFlags(page) {
  return page.evaluate(() => {
    const labels = [...document.querySelectorAll('flt-semantics')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      })
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
    return {
      workspacePreview: labels.some((label) => label.includes('Preview disconnected layout')),
      missingHostRepair: labels.some((label) => label.includes('Replace Host')),
      workspaceNavigation: labels.includes('Workspaces'),
      hostNavigation: labels.includes('Hosts'),
      hostEditor: labels.some((label) => label.includes('Add host')),
      saveTabsAction: labels.some((label) => label.includes('Save current tabs')),
      savedHostsHeading: labels.some((label) => label.includes('Saved hosts')),
      savedWorkspacesHeading: labels.some((label) => label.includes('Saved workspaces')),
      syncControl: labels.some((label) => /^(Idle|Pending|Syncing|Read-only|Sync now)$/.test(label)),
    };
  }).catch(() => ({ pageUnavailable: true }));
}

async function workspaceSplitCreatorSnapshot(page) {
  return page.evaluate(() => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none';
    };
    const semanticNodes = [...document.querySelectorAll('flt-semantics')]
      .filter(visible);
    const byLabel = (label) => semanticNodes.filter((node) =>
      (node.getAttribute('aria-label') || node.innerText || '').trim() === label);
    const createButtons = semanticNodes.filter((node) =>
      node.getAttribute('role') === 'button' &&
      (node.getAttribute('aria-label') || node.innerText || '').trim() ===
        'Create split Workspace');
    const hostCards = semanticNodes.filter((node) =>
      node.getAttribute('role') === 'group' &&
      (node.getAttribute('aria-label') || '').startsWith('Host: '));
    const workspacesNav = byLabel('Workspaces');
    const hostsNav = byLabel('Hosts');
    const createHostButtons = byLabel('Add host');
    return {
      workspacesNavigationCount: workspacesNav.length,
      workspacesNavigationState: workspacesNav.map((node) => ({
        pressed: node.getAttribute('aria-pressed'),
        current: node.getAttribute('aria-current'),
      })),
      hostsNavigationCount: hostsNav.length,
      hostsNavigationState: hostsNav.map((node) => ({
        pressed: node.getAttribute('aria-pressed'),
        current: node.getAttribute('aria-current'),
      })),
      splitCreatorVisibleCount: createButtons.length,
      splitCreatorEnabledCount: createButtons.filter((node) =>
        node.getAttribute('aria-disabled') !== 'true').length,
      visibleHostCardCount: hostCards.length,
      addHostButtonVisibleCount: createHostButtons.length,
      savedWorkspacesHeadingVisible: byLabel('Saved workspaces').length > 0,
      hostFleetHeadingVisible: byLabel('Your server fleet').length > 0,
      savedHostsHeadingVisible: byLabel('Saved hosts').length > 0,
    };
  }).catch(() => ({ pageUnavailable: true }));
}

async function splitCreatorAccessibleSnapshot(page) {
  const matches = page.getByRole('button', {
    name: 'Create split Workspace', exact: true,
  });
  const count = await matches.count().catch(() => 0);
  let visibleCount = 0;
  let enabledCount = 0;
  for (let index = 0; index < count; index += 1) {
    const candidate = matches.nth(index);
    if (await candidate.isVisible().catch(() => false)) {
      visibleCount += 1;
      if (await candidate.isEnabled().catch(() => false)) enabledCount += 1;
    }
  }
  return { accessibleCount: count, visibleCount, enabledCount };
}

async function splitWorkspaceSaveSnapshot(page, splitName) {
  const button = page.getByRole('button', {
    name: 'Save split Workspace', exact: true,
  });
  const buttonCount = await button.count().catch(() => 0);
  let visibleButtonCount = 0;
  let enabledButtonCount = 0;
  let viewportIntersecting = false;
  for (let index = 0; index < buttonCount; index += 1) {
    const candidate = button.nth(index);
    if (await candidate.isVisible().catch(() => false)) {
      visibleButtonCount += 1;
      if (await candidate.isEnabled().catch(() => false)) enabledButtonCount += 1;
      const bounds = await candidate.boundingBox().catch(() => null);
      if (bounds) {
        const viewport = await page.evaluate(() => ({
          width: window.innerWidth,
          height: window.innerHeight,
        })).catch(() => ({ width: 0, height: 0 }));
        viewportIntersecting = viewportIntersecting ||
          (bounds.x < viewport.width && bounds.y < viewport.height &&
            bounds.x + bounds.width > 0 && bounds.y + bounds.height > 0);
      }
    }
  }
  const pageState = await page.evaluate(() => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const dialogVisible = [...document.querySelectorAll('[role="dialog"]')]
      .some(visible);
    const visibleText = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((node) => `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`)
      .join(' ');
    const invalidFields = [...document.querySelectorAll('[aria-invalid="true"]')]
      .filter(visible).length;
    const alertNodes = [...document.querySelectorAll(
      '[role="alert"], [aria-live="polite"], [aria-live="assertive"]',
    )].filter(visible);
    const alertRoleNodes = alertNodes.filter((node) => node.getAttribute('role') === 'alert');
    const liveRegionNodes = alertNodes.filter((node) => node.hasAttribute('aria-live'));
    const semanticNodes = [...document.querySelectorAll('flt-semantics')].filter(visible);
    const feedbackCandidates = [...alertNodes, ...semanticNodes];
    const feedbackNodes = feedbackCandidates.filter((node, index) =>
      feedbackCandidates.indexOf(node) === index && (
        node.getAttribute('role') === 'alert' || node.hasAttribute('aria-live') ||
        `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
          .includes('Split Workspace saved encrypted') || [
        'The Vault or one of the selected Hosts is no longer available.',
        'Split workspaces require exactly two Hosts.',
        'Workspace could not be saved',
        'Split Workspace could not be saved',
        '工作区只能新增引用当前 Vault 中现有的主机。',
        '此 Vault 正处于删除宽限期',
        '此记录在另一设备上已更新',
      ].some((prefix) =>
        `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
          .includes(prefix))));
    const feedbackText = (node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`;
    const successSnackbarCount = feedbackNodes.filter((node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || node.textContent || ''}`
        .includes('Split Workspace saved encrypted')).length;
    const nonSuccessFeedback = feedbackNodes.filter((node) =>
      !feedbackText(node).includes('Split Workspace saved encrypted'));
    const classifyError = (text) => {
      if (text.includes('selected Hosts is no longer') ||
          text.includes('工作区只能新增引用')) return 'host-reference';
      if (text.includes('Vault') || text.includes('vault') ||
          text.includes('请先选择一个 Vault')) return 'vault-context';
      if (text.includes('REVISION_CONFLICT') || text.includes('另一设备上已更新')) {
        return 'revision';
      }
      if (text.includes('split_ratio_basis_points') ||
          text.includes('exactly two Hosts') || text.includes('Workspace name must')) {
        return 'format';
      }
      if (/\b(?:FormatException|invalid argument)\b/i.test(text)) return 'format-error';
      if (/\b(?:StateError|Bad state|Null check operator)\b/i.test(text)) return 'state-error';
      if (/\b(?:SodiumException|crypto|decrypt|signature)\b/i.test(text)) return 'crypto-error';
      if (/\b(?:DatabaseException|sqlite|database)\b/i.test(text)) return 'database-error';
      if (/\b(?:failed to fetch|network error|networkerror|connection refused)\b/i.test(text)) {
        return 'network';
      }
      if (/\b(?:ApiException|\([A-Z][A-Z0-9_]{2,}\))/.test(text)) return 'api-error';
      return 'other';
    };
    return {
      dialogVisible,
      previewAxisVisible: visibleText.includes('Stacked'),
      previewRatioVisible: visibleText.includes('63/37'),
      formValidationErrorCount: invalidFields,
      savedWorkspacesHeadingVisible: visibleText.includes('Saved workspaces'),
      noSavedWorkspacesEmptyStateVisible: visibleText.includes('No saved workspaces'),
      successSnackbarCount,
      nonSuccessAlertOrLiveRegionCount: nonSuccessFeedback.length,
      visibleAlertRoleCount: alertRoleNodes.length,
      visibleLiveRegionCount: liveRegionNodes.length,
      nonAlertLiveRegionCount: liveRegionNodes.filter(
        (node) => node.getAttribute('role') !== 'alert',
      ).length,
      nonSuccessAlertOrLiveRegionCategory: nonSuccessFeedback.length > 0
        ? classifyError(feedbackText(nonSuccessFeedback[0])) : 'none',
    };
  }).catch(() => ({
    dialogVisible: false,
    previewAxisVisible: false,
    previewRatioVisible: false,
    formValidationErrorCount: 0,
    savedWorkspacesHeadingVisible: false,
    noSavedWorkspacesEmptyStateVisible: false,
    successSnackbarCount: 0,
    nonSuccessAlertOrLiveRegionCount: 0,
    visibleAlertRoleCount: 0,
    visibleLiveRegionCount: 0,
    nonAlertLiveRegionCount: 0,
    nonSuccessAlertOrLiveRegionCategory: 'none',
  }));
  const targetWorkspace = page.getByText(splitName, { exact: true });
  const targetWorkspaceCount = await targetWorkspace.count().catch(() => 0);
  const visiblePreviewCardCount = await visibleWorkspacePreviewCardCount(page);
  const targetWorkspaceSemanticVisible =
    await visibleSemanticTextMatch(page, splitName);
  let targetWorkspaceVisibleCount = 0;
  for (let index = 0; index < targetWorkspaceCount; index += 1) {
    if (await targetWorkspace.nth(index).isVisible().catch(() => false)) {
      targetWorkspaceVisibleCount += 1;
    }
  }
  return {
    dialogVisible: pageState.dialogVisible,
    saveButtonCount: buttonCount,
    saveButtonVisibleCount: visibleButtonCount,
    saveButtonEnabledCount: enabledButtonCount,
    saveButtonViewportIntersecting: viewportIntersecting,
    previewAxisVisible: pageState.previewAxisVisible,
    previewRatioVisible: pageState.previewRatioVisible,
    formValidationErrorCount: pageState.formValidationErrorCount,
    savedWorkspacesHeadingVisible: pageState.savedWorkspacesHeadingVisible,
    noSavedWorkspacesEmptyStateVisible: pageState.noSavedWorkspacesEmptyStateVisible,
    successSnackbarVisible: pageState.successSnackbarCount > 0,
    successSnackbarCount: pageState.successSnackbarCount,
    nonSuccessAlertOrLiveRegionVisible: pageState.nonSuccessAlertOrLiveRegionCount > 0,
    nonSuccessAlertOrLiveRegionCount: pageState.nonSuccessAlertOrLiveRegionCount,
    nonSuccessAlertOrLiveRegionCategory: pageState.nonSuccessAlertOrLiveRegionCategory,
    visibleAlertRoleCount: pageState.visibleAlertRoleCount,
    visibleLiveRegionCount: pageState.visibleLiveRegionCount,
    nonAlertLiveRegionCount: pageState.nonAlertLiveRegionCount,
    visibleWorkspacePreviewCardCount: visiblePreviewCardCount,
    targetWorkspaceExactTextCount: targetWorkspaceCount,
    targetWorkspaceExactTextVisibleCount: targetWorkspaceVisibleCount,
    targetWorkspaceVisibleSemanticText: targetWorkspaceSemanticVisible,
  };
}

async function visibleWorkspacePreviewCardCount(page) {
  const previews = page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  });
  const count = await previews.count().catch(() => 0);
  let visibleCount = 0;
  for (let index = 0; index < count; index += 1) {
    if (await previews.nth(index).isVisible().catch(() => false)) visibleCount++;
  }
  return visibleCount;
}

async function visibleSyncPendingSnapshot(page) {
  return page.evaluate(() => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const labels = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '')
        .replace(/\s+/g, ' ').trim())
      .filter((label) => /^(?:Idle|Pending|Syncing|Retry queued|Offline|Sync error|Read-only|Sync now|\d+ pending)$/.test(label));
    const label = labels[0] || null;
    const numeric = label?.match(/^(\d+) pending$/);
    return {
      controlCount: labels.length,
      label,
      pendingCount: numeric ? Number(numeric[1]) : label === 'Idle' ? 0 : null,
    };
  }).catch(() => ({ controlCount: 0, label: null, pendingCount: null }));
}

async function encryptedWorkspaceSaveUiSnapshot(page, workspaceName) {
  const domState = await page.evaluate((expectedName) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
    const labelOf = (node) => [node.getAttribute('aria-label') || '',
      node.innerText || '', node.textContent || ''].join(' ').replace(/\s+/g, ' ').trim();
    const labels = semantics.map(labelOf);
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible).map(labelOf);
    const knownSyncStates = new Set([
      'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
      'Snapshot needed', 'Rebuilding snapshot', 'Key update needed', 'Read-only',
      'Sign in needed', 'Device revoked', 'Vault deletion pending · read-only',
      'Sync now',
    ]);
    const syncStates = buttons.map((label) => {
      const normalized = label.split('\n')[0].trim();
      if (knownSyncStates.has(normalized)) return normalized;
      return /^\d+ pending$/.test(normalized) ? 'Pending' : null;
    }).filter(Boolean);
    const inputs = [...document.querySelectorAll('input, textarea')];
    const nameInputPresent = inputs.some((node) =>
      (node.getAttribute('aria-label') || '').includes('Workspace name'));
    const nameInputValueMatches = inputs.some((node) =>
      (node.getAttribute('aria-label') || '').includes('Workspace name') &&
      node.value === expectedName);
    const textboxSemantics = semantics.filter((node) =>
      node.getAttribute('role') === 'textbox');
    const nameTextboxPresent = textboxSemantics.some((node) =>
      labelOf(node).includes('Workspace name'));
    const exactNameSemanticCount = labels.filter((label) =>
      label === expectedName).length;
    const nameSemanticCandidates = semantics.filter((node) =>
      labelOf(node).includes(expectedName)).map((node) => {
      const rect = node.getBoundingClientRect();
      return {
        role: node.getAttribute('role') || '',
        exactName: labelOf(node) === expectedName,
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        x: Math.round(rect.x),
        y: Math.round(rect.y),
      };
    });
    const nameSemanticContainsExpected = nameSemanticCandidates.length > 0;
    const visibleAlerts = [...document.querySelectorAll(
      '[role="alert"], [aria-live="polite"], [aria-live="assertive"]',
    )].filter(visible);
    const feedbackCategory = visibleAlerts.length === 0 ? 'none' :
      visibleAlerts.some((node) => /saved|success|保存|成功/i.test(labelOf(node)))
        ? 'success' :
      visibleAlerts.some((node) => /vault|保险库/i.test(labelOf(node)))
        ? 'vault' :
      visibleAlerts.some((node) => /host|主机|reference|引用/i.test(labelOf(node)))
        ? 'host-reference' :
      visibleAlerts.some((node) => /required|invalid|format|必填|无效|格式/i.test(labelOf(node)))
        ? 'validation' :
      visibleAlerts.some((node) => /error|failed|could not|unable|失败|错误|无法/i.test(labelOf(node)))
        ? 'save-error' : 'other';
    const saveButtonCount = buttons.filter((label) => label === 'Save').length;
    const cancelButtonCount = buttons.filter((label) => label === 'Cancel').length;
    const workspaceDialogOpen = [...document.querySelectorAll('[role="dialog"]')]
      .some(visible) || nameInputPresent || nameTextboxPresent ||
      (saveButtonCount > 0 && cancelButtonCount > 0);
    return {
      pageReady: document.readyState === 'complete',
      workspaceDialogOpen,
      nameInputPresent,
      nameInputValueMatches,
      nameTextboxPresent,
      exactNameSemanticCount,
      nameSemanticContainsExpected,
      nameSemanticMatchCount: nameSemanticCandidates.length,
      nameSemanticCandidates,
      savedWorkspacesHeadingVisible: labels.some((label) =>
        label.includes('Saved workspaces')),
      saveButtonVisibleCount: saveButtonCount,
      cancelButtonVisibleCount: cancelButtonCount,
      visibleAlertCount: visibleAlerts.length,
      feedbackCategory,
      syncStates,
      saveCurrentTabsActionVisible: buttons.includes('Save current tabs'),
    };
  }, workspaceName).catch(() => ({
    pageReady: false,
    workspaceDialogOpen: false,
    nameInputPresent: false,
    nameInputValueMatches: false,
    nameTextboxPresent: false,
    exactNameSemanticCount: 0,
    nameSemanticContainsExpected: false,
    nameSemanticMatchCount: 0,
    nameSemanticCandidates: [],
    savedWorkspacesHeadingVisible: false,
    saveButtonVisibleCount: 0,
    cancelButtonVisibleCount: 0,
    visibleAlertCount: 0,
    feedbackCategory: 'unavailable',
    syncStates: [],
    saveCurrentTabsActionVisible: false,
  }));
  const exactNameText = page.getByText(workspaceName, { exact: true });
  const exactNameTextCount = await exactNameText.count().catch(() => 0);
  let exactNameTextVisibleCount = 0;
  for (let index = 0; index < exactNameTextCount; index += 1) {
    if (await exactNameText.nth(index).isVisible().catch(() => false)) {
      exactNameTextVisibleCount += 1;
    }
  }
  return {
    ...domState,
    exactNameTextCount,
    exactNameTextVisibleCount,
    visibleWorkspacePreviewCardCount: await visibleWorkspacePreviewCardCount(page)
      .catch(() => 0),
    pageClosed: page.isClosed(),
  };
}

async function totalWorkspacePreviewCardCount(page) {
  return page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  }).count().catch(() => 0);
}

async function workspaceScrollContainerSnapshot(page) {
  return page.evaluate(() => {
    const scrollable = [...document.querySelectorAll('*')]
      .filter((node) => node.clientHeight > 40 &&
        node.scrollHeight > node.clientHeight + 2)
      .map((node) => ({
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
        scrollTop: node.scrollTop,
        maxScrollTop: Math.max(0, node.scrollHeight - node.clientHeight),
      }))
      .sort((left, right) => right.maxScrollTop - left.maxScrollTop);
    return {
      viewportHeight: window.innerHeight,
      documentScrollHeight: document.documentElement?.scrollHeight || 0,
      windowScrollTop: window.scrollY,
      scrollableContainerCount: scrollable.length,
      largestContainer: scrollable[0] || null,
    };
  }).catch(() => ({ available: false }));
}

async function splitWorkspacePullUiSnapshot(page, {
  address,
  firstPort,
  secondPort,
}) {
  const previewButtons = page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  });
  const splitNameTexts = page.getByText(SPLIT_WORKSPACE_NAME, { exact: true });
  const missingHostTexts = page.getByText('Missing Host', { exact: false });
  const scrollBefore = await workspaceScrollContainerSnapshot(page);
  const splitNameTextCountBeforeScroll = await splitNameTexts.count().catch(() => 0);
  let nameScrollAttempted = false;
  let previewScrollAttempted = false;
  for (let index = 0; index < splitNameTextCountBeforeScroll; index += 1) {
    const candidate = splitNameTexts.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    nameScrollAttempted = true;
    await candidate.scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {});
    break;
  }
  if (!nameScrollAttempted) {
    await page.evaluate(() => {
      const scrollable = [...document.querySelectorAll('*')]
        .filter((node) => node.clientHeight > 40 &&
          node.scrollHeight > node.clientHeight + 2)
        .sort((left, right) =>
          (right.scrollHeight - right.clientHeight) -
          (left.scrollHeight - left.clientHeight));
      const target = scrollable[0];
      if (target) target.scrollTop = target.scrollHeight;
      window.scrollTo(0, document.documentElement?.scrollHeight || 0);
    }).catch(() => {});
  }
  const orderedNames = [WORKSPACE_NAME, WORKSPACE_BRANCH_B_COPY_NAME,
    SPLIT_WORKSPACE_NAME].sort((left, right) =>
    left.toLowerCase().localeCompare(right.toLowerCase()));
  const splitPreviewIndex = orderedNames.indexOf(SPLIT_WORKSPACE_NAME);
  if (splitPreviewIndex >= 0 &&
      await previewButtons.count().catch(() => 0) > splitPreviewIndex) {
    previewScrollAttempted = true;
    await previewButtons.nth(splitPreviewIndex)
      .scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {});
  }
  await page.waitForTimeout(250);
  const countVisible = async (locator) => {
    const count = await locator.count().catch(() => 0);
    let visibleCount = 0;
    for (let index = 0; index < count; index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) visibleCount++;
    }
    return { count, visibleCount };
  };
  const [previewButtonsState, splitNameState, missingHostState] = await Promise.all([
    countVisible(previewButtons),
    countVisible(splitNameTexts),
    countVisible(missingHostTexts),
  ]);
  const titleProbe = await page.evaluate((expectedName) => {
    const isVisible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const allSemanticNodes = [...document.querySelectorAll('flt-semantics')];
    const visibleSemanticNodes = allSemanticNodes.filter(isVisible);
    const semanticText = (node) => [node.getAttribute('aria-label') || '',
      node.innerText || '', node.textContent || ''];
    const allSemanticText = allSemanticNodes.flatMap(semanticText);
    const visibleSemanticText = visibleSemanticNodes.flatMap(semanticText);
    const normalized = (value) => value.trim();
    const casefold = (value) => value.trim().toLocaleLowerCase();
    const bodyText = document.body?.innerText || '';
    const unavailableMatch = bodyText.match(
      /(\d+) encrypted record\(s\) could not be verified/,
    );
    const splitBadgeCount = (nodes) => nodes.filter((node) =>
      semanticText(node).some((label) => /^Split\s*[·]/.test(normalized(label)))
    ).length;
    const bodyNormalized = normalized(bodyText);
    const bodyCasefolded = casefold(bodyText);
    const matches = (labels) => ({
      exact: labels.some((label) => normalized(label) === expectedName),
      trimmedCasefoldExact: labels.some((label) =>
        casefold(label) === casefold(expectedName)),
      contains: labels.some((label) => label.includes(expectedName)),
      trimmedCasefoldContains: labels.some((label) =>
        casefold(label).includes(casefold(expectedName))),
    });
    return {
      bodyTextExact: bodyText === expectedName,
      bodyTextTrimmedExact: bodyNormalized === expectedName,
      bodyTextCasefoldExact: casefold(bodyText) === casefold(expectedName),
      bodyTextContainsExpected: bodyText.includes(expectedName),
      bodyTextCasefoldContainsExpected: bodyCasefolded.includes(casefold(expectedName)),
      visibleSemanticNameMatches: matches(visibleSemanticText),
      allSemanticNameMatches: matches(allSemanticText),
      splitWorkspaceRecordCount: splitBadgeCount(allSemanticNodes),
      visibleSplitWorkspaceRecordCount: splitBadgeCount(visibleSemanticNodes),
      unavailableWarningVisible: unavailableMatch !== null,
      unavailableRecordCount: unavailableMatch ? Number(unavailableMatch[1]) : null,
    };
  }, SPLIT_WORKSPACE_NAME).catch(() => ({ probeAvailable: false }));
  const ratioVisible = await visibleSemanticTextMatch(page, 'Split · 63/37');
  const axisVisible = await visibleSemanticTextMatch(page, 'Stacked');
  const paneOneHostRendered = await visibleSemanticTextMatch(page,
    `Pane 1 · ${HOST_SPLIT_NAME} · ${address}:${firstPort}`);
  const paneTwoHostRendered = await visibleSemanticTextMatch(page,
    `Pane 2 · ${HOST_A_NAME} · ${address}:${secondPort}`);
  const targetPreviewActionVisible = splitPreviewIndex >= 0 &&
    splitPreviewIndex < previewButtonsState.count &&
    await previewButtons.nth(splitPreviewIndex).isVisible().catch(() => false);
  const splitNameVisibleSemanticContainsExpected =
    titleProbe?.visibleSemanticNameMatches?.contains === true;
  const splitNameAllSemanticContainsExpected =
    titleProbe?.allSemanticNameMatches?.contains === true;
  const splitCardFullyRendered = splitNameVisibleSemanticContainsExpected &&
    splitNameAllSemanticContainsExpected && ratioVisible &&
    axisVisible && paneOneHostRendered && paneTwoHostRendered &&
    targetPreviewActionVisible;
  return {
    scrollBefore,
    scrollAfter: await workspaceScrollContainerSnapshot(page),
    nameScrollAttempted,
    previewScrollAttempted,
    splitNameTextCountBeforeScroll,
    previewButtonCount: previewButtonsState.count,
    visiblePreviewButtonCount: previewButtonsState.visibleCount,
    splitNameTextCount: splitNameState.count,
    visibleSplitNameTextCount: splitNameState.visibleCount,
    titleProbe,
    splitNameVisibleSemanticContainsExpected,
    splitNameAllSemanticContainsExpected,
    splitPreviewIndex,
    ratioVisible,
    axisVisible,
    paneOneHostRendered,
    paneTwoHostRendered,
    targetPreviewActionVisible,
    splitCardFullyRendered,
    missingHostMarkerCount: missingHostState.count,
    visibleMissingHostMarkerCount: missingHostState.visibleCount,
  };
}

async function waitForSplitWorkspaceCardRendered(page, options, timeout = 15000) {
  const deadline = Date.now() + timeout;
  let snapshot = null;
  while (Date.now() < deadline) {
    snapshot = await splitWorkspacePullUiSnapshot(page, options);
    if (snapshot.splitCardFullyRendered) return snapshot;
    await page.waitForTimeout(200);
  }
  return snapshot;
}

async function installSplitSaveFeedbackProbe(page) {
  await page.evaluate(() => {
    const property = '__workspaceSplitSaveFeedbackProbe';
    window[property]?.observer?.disconnect();
    const state = {
      observedAlertRoleCount: 0,
      observedLiveRegionCount: 0,
      observedSuccessFeedback: false,
      observedErrorFeedbackCount: 0,
      observedErrorCategories: [],
      unclassifiedLiveRegionCount: 0,
      syncStatusRegionCount: 0,
    };
    const observedNodes = new WeakSet();
    const observedErrorNodes = new WeakSet();
    const observedUnclassifiedNodes = new WeakSet();
    const observedStatusNodes = new WeakSet();
    const errorCategories = new Set();
    const isVisible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const classify = (text) => {
      if (/selected Hosts is no longer|工作区只能新增引用/i.test(text)) return 'host-reference';
      if (/Vault|vault|请先选择一个 Vault/i.test(text)) return 'vault-context';
      if (/REVISION_CONFLICT|另一设备上已更新/i.test(text)) return 'revision';
      if (/split_ratio_basis_points|exactly two Hosts|Workspace name must/i.test(text)) return 'format';
      if (/FormatException|invalid argument/i.test(text)) return 'format-error';
      if (/StateError|Bad state|Null check operator/i.test(text)) return 'state-error';
      if (/SodiumException|crypto|decrypt|signature/i.test(text)) return 'crypto-error';
      if (/DatabaseException|sqlite|database/i.test(text)) return 'database-error';
      if (/failed to fetch|network error|networkerror|connection refused/i.test(text)) return 'network';
      if (/ApiException|\([A-Z][A-Z0-9_]{2,}\)/.test(text)) return 'api-error';
      return 'other';
    };
    const inspect = (root) => {
      if (!(root instanceof Element)) return;
      const candidates = [];
      if (root.matches('[role="alert"], [aria-live], flt-semantics')) candidates.push(root);
      candidates.push(...root.querySelectorAll('[role="alert"], [aria-live], flt-semantics'));
      for (const node of candidates) {
        if (!isVisible(node)) continue;
        const roleAlert = node.getAttribute('role') === 'alert';
        const liveRegion = node.hasAttribute('aria-live');
        const text = (node.getAttribute('aria-label') || node.innerText || node.textContent || '')
          .trim();
        const success = text.includes('Split Workspace saved encrypted');
        const knownFeedback = success || [
          'The Vault or one of the selected Hosts is no longer available.',
          'Split workspaces require exactly two Hosts.',
          'Workspace could not be saved',
          'Split Workspace could not be saved',
          '工作区只能新增引用当前 Vault 中现有的主机。',
          '此 Vault 正处于删除宽限期',
          '此记录在另一设备上已更新',
        ].some((prefix) => text.includes(prefix));
        if (!roleAlert && !liveRegion && !knownFeedback) continue;
        if (!observedNodes.has(node)) {
          observedNodes.add(node);
          if (roleAlert) state.observedAlertRoleCount++;
          if (liveRegion) state.observedLiveRegionCount++;
        }
        if (success) state.observedSuccessFeedback = true;
        const isSyncStatus = /^(?:Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Snapshot needed|Rebuilding snapshot|Key update needed|Read-only|Sign in needed|Device revoked|Vault deletion pending · read-only|Sync now)$/.test(text);
        const looksLikeError = /error|failed|cannot|could not|conflict|not available|exception|bad state|失败|错误|不可|无法|冲突|已更新/i.test(text);
        if (isSyncStatus && !observedStatusNodes.has(node)) {
          observedStatusNodes.add(node);
          state.syncStatusRegionCount++;
        } else if (!success && looksLikeError && !observedErrorNodes.has(node)) {
          observedErrorNodes.add(node);
          state.observedErrorFeedbackCount++;
          errorCategories.add(classify(text));
        } else if (!success && liveRegion && !observedUnclassifiedNodes.has(node)) {
          observedUnclassifiedNodes.add(node);
          state.unclassifiedLiveRegionCount++;
        }
      }
      state.observedErrorCategories = [...errorCategories];
    };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        if (record.target instanceof Element) inspect(record.target);
        else if (record.target instanceof Node && record.target.parentElement) {
          inspect(record.target.parentElement);
        }
        for (const node of record.addedNodes) inspect(node);
      }
    });
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      characterData: true,
      attributeFilter: ['role', 'aria-live', 'aria-label'],
    });
    inspect(document.body);
    window[property] = { state, observer };
  });
}

async function readSplitSaveFeedbackProbe(page) {
  return page.evaluate(() => {
    const state = window.__workspaceSplitSaveFeedbackProbe?.state;
    return state ? {
      observedAlertRoleCount: state.observedAlertRoleCount,
      observedLiveRegionCount: state.observedLiveRegionCount,
      observedSuccessFeedback: state.observedSuccessFeedback,
      observedErrorFeedbackCount: state.observedErrorFeedbackCount,
      observedErrorCategories: state.observedErrorCategories,
      unclassifiedLiveRegionCount: state.unclassifiedLiveRegionCount,
      syncStatusRegionCount: state.syncStatusRegionCount,
    } : { probeAvailable: false };
  }).catch(() => ({ probeAvailable: false }));
}

async function stopSplitSaveFeedbackProbe(page) {
  await page.evaluate(() => {
    window.__workspaceSplitSaveFeedbackProbe?.observer?.disconnect();
  }).catch(() => {});
}

async function click(page, label) {
  await (await visibleButton(page, label)).click();
}

async function visibleSidebarConnectButtons(page) {
  const buttons = page.getByRole('button', { name: 'Connect', exact: true });
  const count = await buttons.count().catch(() => 0);
  const sidebarIndices = [];
  // The acceptance viewport is 1440px, so the wide 238px global navigation,
  // 17px Terminal-page inset, and 250px connections column place its right
  // edge at x=505. Leave a 5px boundary margin; live-tree Connect controls
  // start in the center surface to the right of the 13px gutter (x=518).
  const sidebarRightEdge = 510;
  const focusRects = [];
  const focusButtons = page.getByRole('button', { name: 'Focus', exact: true });
  const focusCount = await focusButtons.count().catch(() => 0);
  for (let index = 0; index < focusCount; index += 1) {
    const candidate = focusButtons.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    const bounds = await candidate.boundingBox().catch(() => null);
    if (bounds && bounds.x + bounds.width <= sidebarRightEdge) focusRects.push(bounds);
  }
  for (let index = 0; index < count; index += 1) {
    const candidate = buttons.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    const bounds = await candidate.boundingBox().catch(() => null);
    // The fixed 250px left sidebar holds the explicit staged-pane actions.
    // The live terminal surface can expose a second Connect for the same leaf;
    // keep those center-pane controls out of DFS preview selection.
    const shadowsConnectedFocus = bounds && focusRects.some((focus) =>
      Math.abs((bounds.x + bounds.width / 2) -
        (focus.x + focus.width / 2)) <= 8 &&
      Math.abs((bounds.y + bounds.height / 2) -
        (focus.y + focus.height / 2)) <= 6);
    if (bounds && bounds.x + bounds.width <= sidebarRightEdge &&
        !shadowsConnectedFocus) {
      sidebarIndices.push(index);
    }
  }
  return { buttons, indices: sidebarIndices };
}

async function visibleSidebarTextBounds(page, expectedText) {
  return page.evaluate((expected) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const textValues = (node) => [
      node.getAttribute('aria-label') || '',
      node.innerText || '',
      node.textContent || '',
    ].map((text) => text.replace(/\s+/g, ' ').trim()).filter(Boolean);
    const rightEdge = 510;
    const points = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((node) => {
        const rect = node.getBoundingClientRect();
        const values = textValues(node);
        return {
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
          centerX: rect.left + rect.width / 2,
          centerY: rect.top + rect.height / 2,
          area: rect.width * rect.height,
          exact: values.some((text) => text === expected),
          contains: values.some((text) => text.includes(expected)),
        };
      })
      .filter((rect) => rect.right <= rightEdge && rect.contains)
      .sort((left, right) => Number(right.exact) - Number(left.exact) ||
        left.area - right.area);
    return points.filter((point, index) => points.findIndex((candidate) =>
      Math.abs(candidate.centerX - point.centerX) < 2 &&
      Math.abs(candidate.centerY - point.centerY) < 2) === index);
  }, expectedText).catch(() => []);
}

async function visibleSidebarConnectButtonForPane(page, paneNumber, hostName) {
  const paneLabel = `Pane ${paneNumber}`;
  const paneBounds = await visibleSidebarTextBounds(page, paneLabel);
  const hostBounds = await visibleSidebarTextBounds(page, hostName);
  const buttons = await visibleSidebarConnectButtons(page);
  const buttonBounds = [];
  for (const index of buttons.indices) {
    const bounds = await buttons.buttons.nth(index).boundingBox().catch(() => null);
    if (!bounds) continue;
    buttonBounds.push({
      index,
      x: bounds.x,
      y: bounds.y,
      width: bounds.width,
      height: bounds.height,
      centerX: bounds.x + bounds.width / 2,
      centerY: bounds.y + bounds.height / 2,
    });
  }

  // Match the visible exact Pane and Host labels to the one Connect button in
  // the same sidebar preview card. The Host list above the preview repeats
  // names, so the paired Pane label and vertical proximity disambiguate it.
  const paneHostPairs = [];
  for (const pane of paneBounds) {
    for (const host of hostBounds) {
      const verticalDistance = Math.abs(pane.centerY - host.centerY);
      const horizontalDistance = Math.abs(pane.centerX - host.centerX);
      if (verticalDistance <= 45 && horizontalDistance <= 180) {
        paneHostPairs.push({ pane, host, score: verticalDistance + horizontalDistance / 20 });
      }
    }
  }
  paneHostPairs.sort((left, right) => left.score - right.score);
  const targetPair = paneHostPairs[0];
  const diagnostics = {
    paneLabelMatchCount: paneBounds.length,
    hostLabelMatchCount: hostBounds.length,
    paneHostPairCount: paneHostPairs.length,
    sidebarConnectButtonCount: buttonBounds.length,
    nearButtonCount: 0,
    nearestButtonScore: null,
    secondButtonScore: null,
    uniqueNearestButton: false,
    paneLabelCenter: null,
    hostLabelCenter: null,
    nearestButtonRect: null,
  };
  const roundedCenter = (rect) => rect ? {
    x: Math.round(rect.centerX),
    y: Math.round(rect.centerY),
  } : null;
  if (!targetPair || (paneHostPairs.length > 1 &&
      paneHostPairs[1].score - targetPair.score < 4)) {
    return { buttons: buttons.buttons, index: null, matchingCount: 0, diagnostics };
  }
  diagnostics.paneLabelCenter = roundedCenter(targetPair.pane);
  diagnostics.hostLabelCenter = roundedCenter(targetPair.host);

  const matching = buttonBounds.map((button) => ({
    ...button,
    distance: Math.abs(button.centerY - targetPair.host.centerY) +
      Math.abs(button.centerX - targetPair.host.centerX) / 5,
  })).filter((button) => button.distance <= 55)
    .sort((left, right) => left.distance - right.distance);
  diagnostics.nearButtonCount = matching.length;
  diagnostics.nearestButtonScore = matching.length > 0
    ? Math.round(matching[0].distance * 10) / 10 : null;
  diagnostics.secondButtonScore = matching.length > 1
    ? Math.round(matching[1].distance * 10) / 10 : null;
  diagnostics.nearestButtonRect = matching.length > 0 ? {
    x: Math.round(matching[0].x),
    y: Math.round(matching[0].y),
    width: Math.round(matching[0].width),
    height: Math.round(matching[0].height),
  } : null;
  const uniqueNearest = matching.length === 1 ||
    (matching.length > 1 && matching[1].distance - matching[0].distance >= 8);
  diagnostics.uniqueNearestButton = uniqueNearest;
  if (!uniqueNearest || matching.length === 0 || matching[0].distance > 35) {
    return {
      buttons: buttons.buttons,
      index: null,
      matchingCount: uniqueNearest ? 1 : matching.length,
      diagnostics,
    };
  }
  return {
    buttons: buttons.buttons,
    index: matching[0].index,
    matchingCount: 1,
    diagnostics,
  };
}

async function locateNestedSidebarConnectAction(page, paneNumber, hostName) {
  const located = await visibleSidebarConnectButtonForPane(
    page, paneNumber, hostName,
  );
  const candidate = located.index === null
    ? null : located.buttons.nth(located.index);
  const buttonVisible = candidate
    ? await candidate.isVisible().catch(() => false) : false;
  const buttonEnabled = candidate
    ? await candidate.isEnabled().catch(() => false) : false;
  const bounds = candidate
    ? await candidate.boundingBox().catch(() => null) : null;
  const diagnostic = {
    paneNumber,
    ...located.diagnostics,
    uniqueActionCount: located.matchingCount === 1 ? 1 : 0,
    buttonVisible,
    buttonEnabled,
    clickedButtonCenter: bounds ? {
      x: Math.round(bounds.x + bounds.width / 2),
      y: Math.round(bounds.y + bounds.height / 2),
    } : null,
  };
  console.log('WEB-WORKSPACE-NESTED-CONNECT-LOCATOR', JSON.stringify(diagnostic));
  assertThat(candidate !== null && located.matchingCount === 1 &&
    buttonVisible && buttonEnabled,
  `nested Pane ${paneNumber} sidebar Connect action was not uniquely visible and enabled`);
  return { ...located, candidate, diagnostic, paneNumber, hostName };
}

async function clickNestedSidebarConnectAction(page, action) {
  // Flutter rebuilds the semantics tree after each leaf connects. Resolve the
  // same pane/Host again immediately before clicking, then verify that the
  // candidate stayed at the originally selected sidebar coordinates.
  const current = await visibleSidebarConnectButtonForPane(
    page, action.paneNumber, action.hostName,
  );
  const candidate = current.index === null
    ? null : current.buttons.nth(current.index);
  const buttonVisible = candidate
    ? await candidate.isVisible().catch(() => false) : false;
  const buttonEnabled = candidate
    ? await candidate.isEnabled().catch(() => false) : false;
  const bounds = candidate
    ? await candidate.boundingBox().catch(() => null) : null;
  const original = action.diagnostic.nearestButtonRect;
  const geometryUnchanged = Boolean(bounds && original &&
    Math.abs(bounds.x - original.x) <= 2 &&
    Math.abs(bounds.y - original.y) <= 2 &&
    Math.abs(bounds.width - original.width) <= 2 &&
    Math.abs(bounds.height - original.height) <= 2);
  const point = bounds ? {
    x: bounds.x + bounds.width / 2,
    y: bounds.y + bounds.height / 2,
  } : null;
  const hitState = point ? await page.evaluate(({ x, y }) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 &&
        style.visibility !== 'hidden' && style.display !== 'none' &&
        Number(style.opacity || 1) > 0;
    };
    const labels = (node) => [
      node.getAttribute('aria-label') || '',
      node.getAttribute('title') || '',
      node.innerText || '',
      node.textContent || '',
    ].map((value) => value.replace(/\s+/g, ' ').trim()).filter(Boolean);
    const connects = [...document.querySelectorAll(
      'flt-semantics[role="button"]',
    )].filter((node) => {
      if (!visible(node) || !labels(node).some((value) => value === 'Connect')) {
        return false;
      }
      const rect = node.getBoundingClientRect();
      return x >= rect.left && x <= rect.right &&
        y >= rect.top && y <= rect.bottom;
    });
    const hit = document.elementFromPoint(x, y);
    return {
      connectNodesAtPoint: connects.length,
      elementFromPointHitsConnect: Boolean(hit && connects.some((node) =>
        node === hit || node.contains(hit))),
    };
  }, point).catch(() => ({
    connectNodesAtPoint: 0,
    elementFromPointHitsConnect: false,
  })) : { connectNodesAtPoint: 0, elementFromPointHitsConnect: false };
  const guard = {
    paneNumber: action.paneNumber,
    uniqueCurrentMatch: current.matchingCount === 1,
    buttonVisible,
    buttonEnabled,
    geometryUnchanged,
    connectNodesAtPoint: hitState.connectNodesAtPoint,
    elementFromPointHitsConnect: hitState.elementFromPointHitsConnect,
    point: point ? { x: Math.round(point.x), y: Math.round(point.y) } : null,
  };
  console.log('WEB-WORKSPACE-NESTED-CONNECT-CLICK-GUARD', JSON.stringify(guard));
  assertThat(guard.uniqueCurrentMatch && buttonVisible && buttonEnabled &&
    geometryUnchanged && hitState.connectNodesAtPoint === 1 &&
    hitState.elementFromPointHitsConnect,
  `nested Pane ${action.paneNumber} Connect click guard rejected the target`);
  await page.mouse.click(point.x, point.y);
  return guard;
}

async function clickConflictInbox(page) {
  const navigation = page.getByRole('button', {
    name: /^Sync & conflicts(?:\s+\d+)?$/,
  });
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await navigation.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = navigation.nth(index);
      if (await candidate.isVisible().catch(() => false)) {
        await candidate.click();
        return;
      }
    }
    await page.waitForTimeout(100);
  }
  throw new Error('visible Sync & conflicts navigation button not found');
}

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  );
  await selectServerModeIfChooser(page, locator);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const visible = [];
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (await candidate.isVisible().catch(() => false)) visible.push(candidate);
    }
    assertThat(visible.length <= 1, `multiple visible fields matched: ${label}`);
    if (visible.length === 1) return visible[0];
    await page.waitForTimeout(100);
  }
  throw new Error(`visible field unavailable: ${label}`);
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(120);
    await locator.press('Control+A');
    await locator.pressSequentially(value, { delay: 15 });
    await page.waitForTimeout(120);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(80);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`field did not retain input: ${label}`);
}

async function splitWorkspaceNameProbe(page, expectedName) {
  return page.evaluate(({ expected, label }) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const inputs = [...document.querySelectorAll('input, textarea')].filter((node) =>
      (node.getAttribute('aria-label') || '').includes(label));
    const values = inputs.map((node) => String(node.value || ''));
    const semanticText = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((node) => `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`);
    const bodyText = document.body?.innerText || '';
    const exactCount = (values, value) => values.filter((item) => item === value).length;
    return {
      matchingEditorCount: inputs.length,
      visibleMatchingEditorCount: inputs.filter(visible).length,
      exactEditorValueMatchCount: exactCount(values, expected),
      caseInsensitiveEditorValueMatchCount: values.filter((value) =>
        value.toLowerCase() === expected.toLowerCase()).length,
      visibleSemanticExactNameMatchCount: exactCount(semanticText, expected),
      visibleSemanticContainsNameCount: semanticText.filter((value) =>
        value.includes(expected)).length,
      bodyTextExactNameMatch: bodyText.includes(expected),
      bodyTextCaseInsensitiveNameMatch: bodyText.toLowerCase().includes(expected.toLowerCase()),
    };
  }, { expected: expectedName, label: 'Workspace name' })
    .catch(() => ({ pageProbeAvailable: false }));
}

async function visibleTextMatch(page, locator) {
  const count = await locator.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) return true;
  }
  return false;
}

async function visibleSemanticTextMatch(page, expectedText) {
  return page.evaluate((expected) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    return [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .some((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
        node.textContent || ''].some((text) => text.includes(expected)));
  }, expectedText).catch(() => false);
}

async function waitForVisibleSemanticText(page, expectedText, label, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await visibleSemanticTextMatch(page, expectedText)) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`visible semantic text unavailable: ${label}`);
}

async function waitForSavedSplitWorkspaceCard(page, expectedName,
  minimumCardCount = 1, timeout = 20000, countMode = 'total') {
  const saveButton = page.getByRole('button', {
    name: 'Save split Workspace', exact: true,
  });
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    let visibleSaveButtonCount = 0;
    const saveButtonCount = await saveButton.count().catch(() => 0);
    for (let index = 0; index < saveButtonCount; index += 1) {
      if (await saveButton.nth(index).isVisible().catch(() => false)) {
        visibleSaveButtonCount++;
      }
    }
    const cardCount = countMode === 'total'
      ? await totalWorkspacePreviewCardCount(page)
      : await visibleWorkspacePreviewCardCount(page);
    const expectedNameVisible = await visibleSemanticTextMatch(page, expectedName);
    // Flutter's virtualized Workspace list can mount existing cards after the
    // split editor closes. The unique, run-scoped name plus a rendered card is
    // stable; an exact before/after count is not.
    if (visibleSaveButtonCount === 0 && cardCount >= minimumCardCount &&
        expectedNameVisible) {
      return;
    }
    await page.waitForTimeout(100);
  }
  throw new Error('split Workspace save did not close the form and render one new card');
}

async function waitForSplitSyncReady(page, hasCapturedOperation, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (hasCapturedOperation()) return;
    const statuses = await page.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      return [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
        .filter((label) => /^(?:Idle|Pending|Syncing|Retry queued|Offline|Sync error|Read-only|Sync now|\d+ pending)$/.test(label));
    }).catch(() => []);
    if (statuses.some((label) => ['Pending', 'Syncing', 'Retry queued'].includes(label) ||
        /^\d+ pending$/.test(label))) return;
    await page.waitForTimeout(100);
  }
  throw new Error('split Workspace outbox did not start sync or expose a pending state');
}

async function workspaceNameVariantStatus(page, expectedName) {
  const capitalizedName = expectedName.length > 0
    ? `${expectedName[0].toUpperCase()}${expectedName.slice(1)}` : expectedName;
  const locatorStatus = {
    exactExpectedVisible: await visibleTextMatch(page,
      page.getByText(expectedName, { exact: true })),
    firstLetterCapitalizedExpectedVisible: await visibleTextMatch(page,
      page.getByText(capitalizedName, { exact: true })),
    caseInsensitiveExpectedVisible: await visibleTextMatch(page,
      page.getByText(new RegExp(`^${escapeRegExp(expectedName)}$`, 'i'))),
  };
  const semanticStatus = await page.evaluate((expected) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const labels = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .flatMap((node) => [node.getAttribute('aria-label') || '', node.innerText || '',
        node.textContent || '']);
    const bodyText = document.body?.innerText || '';
    return {
      visibleSemanticsExactNameMatchCount: labels.filter((label) => label.trim() === expected).length,
      visibleSemanticsContainsExpectedNameCount: labels.filter((label) => label.includes(expected)).length,
      visibleSemanticsCaseInsensitiveNameCount: labels.filter((label) =>
        label.toLowerCase().includes(expected.toLowerCase())).length,
      bodyTextContainsExpectedName: bodyText.includes(expected),
      bodyTextContainsExpectedNameCaseInsensitive:
        bodyText.toLowerCase().includes(expected.toLowerCase()),
    };
  }, expectedName).catch(() => ({ semanticsProbeAvailable: false }));
  return { ...locatorStatus, ...semanticStatus };
}

async function chooseWorkspaceFormOption(page, fieldLabel, optionLabel) {
  const fieldPattern = new RegExp(`^${escapeRegExp(fieldLabel)}(?:\\s|$)`, 'i');
  const controls = page.getByRole('button', { name: fieldPattern });
  const inspectSelection = () => page.evaluate(({ field, expected }) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const labelOf = (node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
        .replace(/\s+/g, ' ').trim();
    const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
    const fieldControls = semantics.filter((node) => node.getAttribute('role') === 'button' &&
      labelOf(node).toLowerCase().startsWith(field.toLowerCase()));
    const fieldBounds = fieldControls.map((node) => {
      const rect = node.getBoundingClientRect();
      return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
    });
    const fieldFound = fieldControls.length > 0;
    const selectedMatched = fieldControls.some((node) =>
      labelOf(node).toLowerCase().includes(expected.toLowerCase()));
    const menuNodes = semantics.filter((node) =>
      ['menuitem', 'option'].includes(node.getAttribute('role')));
    const targetMenuNodes = menuNodes.filter((node) =>
      labelOf(node).toLowerCase().includes(expected.toLowerCase()));
    const isFieldControl = (node) => {
      if (fieldControls.some((fieldNode) =>
        fieldNode === node || fieldNode.contains(node) || node.contains(fieldNode))) return true;
      const rect = node.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      return fieldBounds.some((bounds) => x >= bounds.left && x <= bounds.right &&
        y >= bounds.top && y <= bounds.bottom);
    };
    const targetSemantics = semantics.filter((node) => !isFieldControl(node) &&
      labelOf(node).toLowerCase().includes(expected.toLowerCase()));
    const targetNodes = targetMenuNodes.length > 0 ? targetMenuNodes : targetSemantics;
    const candidates = targetNodes.map((node, index) => {
      const rect = node.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const inViewport = rect.left >= 0 && rect.top >= 0 &&
        rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
      const hit = inViewport ? document.elementFromPoint(x, y) : null;
      const hitVerified = Boolean(hit &&
        (hit === node || node.contains(hit) || hit.contains(node)));
      const zIndex = Number.parseInt(getComputedStyle(node).zIndex, 10);
      return { x, y, hitVerified, zIndex: Number.isFinite(zIndex) ? zIndex : 0, index };
    }).filter((item) => item.hitVerified);
    const highestZ = candidates.length > 0
      ? Math.max(...candidates.map((item) => item.zIndex)) : null;
    const topmost = highestZ === null ? [] : candidates.filter((item) =>
      item.zIndex === highestZ);
    const distinctTargets = topmost.filter((item, index) => topmost.findIndex((candidate) =>
      Math.abs(candidate.x - item.x) < 2 && Math.abs(candidate.y - item.y) < 2) === index);
    const overlayClosed = menuNodes.length === 0;
    return {
      point: distinctTargets.length === 1
        ? { x: distinctTargets[0].x, y: distinctTargets[0].y } : null,
      fieldFound,
      menuOptionCount: menuNodes.length,
      distinctTargetCount: distinctTargets.length,
      selectedMatched,
      overlayClosed,
    };
  }, { field: fieldLabel, expected: optionLabel }).catch(() => ({
    point: null,
    fieldFound: false,
    menuOptionCount: 0,
    distinctTargetCount: 0,
    selectedMatched: false,
    overlayClosed: false,
  }));
  const safeState = (state) => ({
    fieldFound: state.fieldFound,
    menuOptionCount: state.menuOptionCount,
    distinctTargetCount: state.distinctTargetCount,
    selectedMatched: state.selectedMatched,
    overlayClosed: state.overlayClosed,
  });
  let state = await inspectSelection();
  if (state.fieldFound && state.selectedMatched) return;

  let control = null;
  for (let index = await controls.count() - 1; index >= 0; index -= 1) {
    const candidate = controls.nth(index);
    if (await candidate.isVisible().catch(() => false)) {
      control = candidate;
      break;
    }
  }
  if (control) {
    await control.click();
  } else {
    const fieldPoint = await page.evaluate((label) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const matches = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .filter((node) => `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
          .trim().toLowerCase().startsWith(label.toLowerCase()));
      const node = matches.at(-1);
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    }, fieldLabel);
    if (!fieldPoint) {
      stage = `${stage} (${JSON.stringify(safeState(state))})`;
      throw new Error('split Workspace dropdown control was unavailable');
    }
    await page.mouse.click(fieldPoint.x, fieldPoint.y);
  }

  const optionDeadline = Date.now() + 5000;
  while (Date.now() < optionDeadline) {
    state = await inspectSelection();
    if (state.point) break;
    await page.waitForTimeout(100);
  }
  if (!state.point) {
    stage = `${stage} (${JSON.stringify(safeState(state))})`;
    throw new Error('split Workspace popup option was unavailable');
  }
  await page.mouse.click(state.point.x, state.point.y);

  const selectedDeadline = Date.now() + 5000;
  let selectedStableSince = null;
  while (Date.now() < selectedDeadline) {
    state = await inspectSelection();
    if (state.fieldFound && state.selectedMatched && state.overlayClosed) {
      if (selectedStableSince === null) selectedStableSince = Date.now();
      if (Date.now() - selectedStableSince >= 200) return;
    } else {
      selectedStableSince = null;
    }
    await page.waitForTimeout(100);
  }
  stage = `${stage} (${JSON.stringify(safeState(state))})`;
  throw new Error('split Workspace selected field did not settle');
}

async function createSplitWorkspace(
  page,
  splitName,
  readSaveCaptureCounts = () => ({}),
  profileBPage = null,
) {
  stage = 'Profile A open split Workspace creator';
  const visiblePreviewCardCountABeforeSave = await visibleWorkspacePreviewCardCount(page);
  let visiblePreviewCardCountBBeforeSave = null;
  let totalPreviewCardCountBBeforeSave = null;
  if (profileBPage) {
    await click(profileBPage, 'Workspaces');
    visiblePreviewCardCountBBeforeSave = await visibleWorkspacePreviewCardCount(profileBPage);
    totalPreviewCardCountBBeforeSave = await totalWorkspacePreviewCardCount(profileBPage);
  }
  let createButton;
  try {
    createButton = await visibleButton(page, 'Create split Workspace');
  } catch (error) {
    const [state, accessible] = await Promise.all([
      workspaceSplitCreatorSnapshot(page),
      splitCreatorAccessibleSnapshot(page),
    ]);
    const category = accessible.accessibleCount === 0 ? 'no accessible semantic node' :
      accessible.visibleCount === 0 ? 'accessible node hidden' :
      accessible.enabledCount === 0 ? 'visible button disabled' :
      'visible enabled button but lookup failed';
    stage = `Profile A split Workspace creator lookup failed: ${category} (${error.name}; ${JSON.stringify({ ...state, ...accessible })})`;
    throw error;
  }
  const createButtonEnabled = await createButton.isEnabled().catch(() => false);
  if (!createButtonEnabled) {
    const state = await page.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
      const splitButtons = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .filter((node) => (node.getAttribute('aria-label') || node.innerText || '')
          .includes('Create split Workspace'));
      const hostCards = [...document.querySelectorAll('flt-semantics[role="group"]')]
        .filter(visible)
        .filter((node) => (node.getAttribute('aria-label') || '').startsWith('Host: '));
      return {
        savedWorkspacesHeadingVisible: labels.includes('Saved workspaces'),
        hostFleetHeadingVisible: labels.includes('Your server fleet'),
        hostsNavigationVisible: labels.includes('Hosts'),
        workspacesNavigationVisible: labels.includes('Workspaces'),
        splitCreatorButtonCount: splitButtons.length,
        splitCreatorDisabledCount: splitButtons.filter((node) =>
          node.getAttribute('aria-disabled') === 'true').length,
        visibleHostCardCount: hostCards.length,
        addHostFormVisible: labels.some((label) => label.includes('Add a host')),
      };
    }).catch(() => ({ pageUnavailable: true }));
    stage = `Profile A split Workspace creator is disabled (visible=${createButtonEnabled}; ${JSON.stringify(state)})`;
    throw new Error('split Workspace creator is disabled');
  }
  try {
    await createButton.click();
  } catch (error) {
    const state = await page.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
      const splitButtons = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .filter((node) => (node.getAttribute('aria-label') || node.innerText || '')
          .includes('Create split Workspace'));
      const hostCards = [...document.querySelectorAll('flt-semantics[role="group"]')]
        .filter(visible)
        .filter((node) => (node.getAttribute('aria-label') || '').startsWith('Host: '));
      return {
        savedWorkspacesHeadingVisible: labels.includes('Saved workspaces'),
        hostFleetHeadingVisible: labels.includes('Your server fleet'),
        hostsNavigationVisible: labels.includes('Hosts'),
        workspacesNavigationVisible: labels.includes('Workspaces'),
        splitCreatorButtonCount: splitButtons.length,
        splitCreatorDisabledCount: splitButtons.filter((node) =>
          node.getAttribute('aria-disabled') === 'true').length,
        visibleHostCardCount: hostCards.length,
        addHostFormVisible: labels.some((label) => label.includes('Add a host')),
      };
    }).catch(() => ({ pageUnavailable: true }));
    stage = `Profile A split Workspace creator click failed (${error.name}; ${JSON.stringify(state)})`;
    throw error;
  }
  stage = 'Profile A verify split creator ratio field';
  await field(page, 'First child (%)');
  stage = 'Profile A fill split Workspace name';
  await fill(page, 'Workspace name', splitName);
  const splitNameCheckpoints = {};
  splitNameCheckpoints.afterInitialFill = await splitWorkspaceNameProbe(page, splitName);
  stage = 'Profile A choose ordered split Hosts';
  stage = 'Profile A choose first split Host';
  await chooseWorkspaceFormOption(page, 'Host · Pane 1', HOST_SPLIT_NAME);
  splitNameCheckpoints.afterFirstHostSelection = await splitWorkspaceNameProbe(page, splitName);
  stage = 'Profile A choose second split Host';
  await chooseWorkspaceFormOption(page, 'Host · Pane 2', HOST_A_NAME);
  splitNameCheckpoints.afterSecondHostSelection = await splitWorkspaceNameProbe(page, splitName);
  stage = 'Profile A choose split axis';
  await chooseWorkspaceFormOption(page, 'Direction', 'Stacked (top/bottom)');
  splitNameCheckpoints.afterAxisSelection = await splitWorkspaceNameProbe(page, splitName);
  stage = 'Profile A fill split Workspace ratio';
  await fill(page, 'First child (%)', '63');
  splitNameCheckpoints.afterRatioFill = await splitWorkspaceNameProbe(page, splitName);
  const nameInputMatchesBeforeSubmit = await splitWorkspaceNameProbe(page, splitName);
  await installSplitSaveFeedbackProbe(page);
  stage = 'Profile A click split save button';
  await click(page, 'Save split Workspace');
  stage = 'Profile A wait for saved split Workspace card';
  try {
    await waitForSavedSplitWorkspaceCard(
      page, splitName, 1, 20000, 'total',
    );
    await stopSplitSaveFeedbackProbe(page);
  } catch (error) {
    const [initialState, captureCountsBeforeRecovery, saveFeedback] = await Promise.all([
      splitWorkspaceSaveSnapshot(page, splitName),
      Promise.resolve(readSaveCaptureCounts()),
      readSplitSaveFeedbackProbe(page),
    ]);
    const nameVariantsAAfterSave = await workspaceNameVariantStatus(page, splitName);
    const recovery = {
      forcePullAttempted: true,
      forcePullSucceeded: false,
      targetWorkspaceVisibleAfterPull: false,
      targetWorkspaceVisibleCountAfterPull: 0,
      visiblePreviewCardCountAfterPull: 0,
      savedWorkspacesHeadingVisibleAfterPull: false,
      noSavedWorkspacesEmptyStateVisibleAfterPull: false,
    };
    try {
      await syncNow(page, 'split Workspace save recovery pull', { forcePull: true });
      recovery.forcePullSucceeded = true;
    } catch (_) {
      // Keep only whether the bounded, explicit recovery pull completed.
    }
    recovery.targetWorkspaceVisibleAfterPull = await visibleSemanticTextMatch(page, splitName);
    if (!recovery.targetWorkspaceVisibleAfterPull && recovery.forcePullSucceeded) {
      await waitForVisibleSemanticText(page, splitName, 'split Workspace after recovery pull', 5000)
        .then(() => { recovery.targetWorkspaceVisibleAfterPull = true; })
        .catch(() => {});
    }
    const [postRecoveryState, captureCountsAfterRecovery] = await Promise.all([
      splitWorkspaceSaveSnapshot(page, splitName),
      Promise.resolve(readSaveCaptureCounts()),
    ]);
    const nameVariantsAAfterPull = await workspaceNameVariantStatus(page, splitName);
    recovery.targetWorkspaceVisibleCountAfterPull =
      postRecoveryState.targetWorkspaceExactTextVisibleCount;
    recovery.visiblePreviewCardCountAfterPull =
      postRecoveryState.visibleWorkspacePreviewCardCount;
    recovery.savedWorkspacesHeadingVisibleAfterPull =
      postRecoveryState.savedWorkspacesHeadingVisible;
    recovery.noSavedWorkspacesEmptyStateVisibleAfterPull =
      postRecoveryState.noSavedWorkspacesEmptyStateVisible;
    const profileBRecovery = {
      attempted: profileBPage != null,
      workspacesNavigationSucceeded: false,
      visiblePreviewCardCountBeforePull: 0,
      forcePullSucceeded: false,
      exactExpectedWorkspaceNameVisibleAfterPull: false,
      exactExpectedWorkspaceNameVisibleCountAfterPull: 0,
      visiblePreviewCardCountAfterPull: 0,
    };
    if (profileBPage) {
      try {
        await click(profileBPage, 'Workspaces');
        profileBRecovery.workspacesNavigationSucceeded = true;
        profileBRecovery.visiblePreviewCardCountBeforePull =
          await visibleWorkspacePreviewCardCount(profileBPage);
        await syncNow(profileBPage, 'Profile B split Workspace recovery pull', {
          forcePull: true,
        });
        profileBRecovery.forcePullSucceeded = true;
        const targetOnB = profileBPage.getByText(splitName, { exact: true });
        profileBRecovery.exactExpectedWorkspaceNameVisibleCountAfterPull =
          await targetOnB.count().catch(() => 0);
        profileBRecovery.exactExpectedWorkspaceNameVisibleAfterPull =
          await visibleSemanticTextMatch(profileBPage, splitName);
        profileBRecovery.nameVariantsAfterPull =
          await workspaceNameVariantStatus(profileBPage, splitName);
        profileBRecovery.visiblePreviewCardCountAfterPull =
          await visibleWorkspacePreviewCardCount(profileBPage);
      } catch (_) {
        // Keep only whether navigation, pull, and client-side decryption succeeded.
      }
    }
    await stopSplitSaveFeedbackProbe(page);
    stage = `Profile A wait for saved split Workspace card (${error.name}; ${JSON.stringify({
      initialState,
      nameInputMatchesBeforeSubmit,
      splitNameCheckpoints,
      nameVariantsAAfterSave,
      nameVariantsAAfterPull,
      visiblePreviewCardCountABeforeSave,
      visiblePreviewCardCountBBeforeSave,
      captureCountsBeforeRecovery,
      saveFeedback,
      recovery,
      profileBRecovery,
      postRecoveryState,
      captureCountsAfterRecovery,
    })})`;
    throw error;
  }
  return { totalPreviewCardCountBBeforeSave };
}

async function stageSplitWorkspacePreview(page, splitName, {
  existingWorkspaceNames = [WORKSPACE_NAME, WORKSPACE_BRANCH_B_COPY_NAME],
  expectedHosts = [HOST_SPLIT_NAME, HOST_A_NAME],
  connectedHosts = [],
} = {}) {
  const orderedNames = [...existingWorkspaceNames, splitName]
    .sort((left, right) => left.toLowerCase().localeCompare(right.toLowerCase()));
  const index = orderedNames.indexOf(splitName);
  assertThat(index >= 0, 'split Workspace was not in the known saved-name set');
  const previews = page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  });
  const deadline = Date.now() + 15000;
  let previewCount = 0;
  stage = 'Profile B wait for all saved Workspace preview cards';
  while (Date.now() < deadline && previewCount !== orderedNames.length) {
    previewCount = await previews.count();
    if (previewCount !== orderedNames.length) await page.waitForTimeout(100);
  }
  assertThat(previewCount === orderedNames.length,
    'Profile B did not show every saved Workspace before split preview');
  stage = 'Profile B select the named split Workspace preview';
  await previews.nth(index).click();
  stage = 'Profile B verify disconnected split preview status';
  if (connectedHosts.length === 0) {
    await waitForText(page, 'Connect panes explicitly', 15000);
  } else {
    await waitForVisibleSemanticText(page,
      `${connectedHosts.length}/${expectedHosts.length} live`,
      'partially connected split preview status', 15000);
  }
  stage = `Profile B verify ${expectedHosts.length} split preview pane actions`;
  for (const [index, hostName] of expectedHosts.entries()) {
    await waitForVisibleSemanticText(page, `Pane ${index + 1}`,
      `staged split pane ${index + 1}`, 10000);
    await waitForVisibleSemanticText(page, hostName,
      `staged split Host ${index + 1}`, 10000);
  }
  const connectButtons = page.getByRole('button', { name: 'Connect', exact: true });
  const focusButtons = page.getByRole('button', { name: 'Focus', exact: true });
  const disconnectedPaneCount = expectedHosts.length - connectedHosts.length;
  // A partially live split renders one Connect in the staged sidebar and one
  // in the corresponding disconnected leaf of the live split. A fully
  // disconnected preview renders only the sidebar action because the live
  // split subtree is not mounted yet.
  const expectedConnectActionCount = disconnectedPaneCount *
      (connectedHosts.length > 0 ? 2 : 1);
  assertThat(await connectButtons.count() === expectedConnectActionCount &&
    await focusButtons.count() === connectedHosts.length,
  'staged split Workspace did not expose the expected per-pane Focus/Connect actions');
  return connectButtons;
}

async function stageSingleWorkspacePreview(page, workspaceName, {
  existingWorkspaceNames = [],
  hostName,
  profile = 'B',
} = {}) {
  const orderedNames = [...existingWorkspaceNames, workspaceName]
    .sort((left, right) => left.toLowerCase().localeCompare(right.toLowerCase()));
  const index = orderedNames.indexOf(workspaceName);
  assertThat(index >= 0, 'single-tab Workspace was not in the known saved-name set');
  const previews = page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  });
  const deadline = Date.now() + 15000;
  let previewCount = 0;
  stage = `Profile ${profile} wait for saved one-tab Workspace cards`;
  while (Date.now() < deadline && previewCount !== orderedNames.length) {
    previewCount = await previews.count();
    if (previewCount !== orderedNames.length) await page.waitForTimeout(100);
  }
  const buttonCount = await previews.count().catch(() => 0);
  const locatorRows = [];
  for (let locatorIndex = 0; locatorIndex < buttonCount; locatorIndex += 1) {
    const button = previews.nth(locatorIndex);
    const visible = await button.isVisible().catch(() => false);
    const bounds = visible ? await button.boundingBox().catch(() => null) : null;
    locatorRows.push({
      locatorIndex,
      visible,
      bounds: bounds ? {
        x: Math.round(bounds.x), y: Math.round(bounds.y),
        width: Math.round(bounds.width), height: Math.round(bounds.height),
      } : null,
    });
  }
  const titleAndGroupRects = await page.evaluate((knownNames) => {
    const normalize = (value) => value.replace(/\s+/g, ' ').trim();
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const rectOf = (node) => {
      const rect = node.getBoundingClientRect();
      return {
        x: Math.round(rect.x), y: Math.round(rect.y),
        width: Math.round(rect.width), height: Math.round(rect.height),
      };
    };
    const nodes = [...document.querySelectorAll('flt-semantics')];
    return knownNames.map((_, workspaceIndex) => {
      const matches = nodes.flatMap((node) => {
        const text = normalize([
          node.getAttribute('aria-label') || '',
          node.innerText || '',
          node.textContent || '',
        ].filter(Boolean).join(' '));
        const workspaceName = knownNames[workspaceIndex];
        if (!text.includes(workspaceName)) return [];
        const rect = node.getBoundingClientRect();
        let ariaHiddenAncestor = false;
        let inertAncestor = false;
        for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
          if ((ancestor.getAttribute('aria-hidden') || '').toLowerCase() === 'true') {
            ariaHiddenAncestor = true;
          }
          if (ancestor.hasAttribute('inert')) inertAncestor = true;
        }
        return [{
          workspaceIndex,
          role: node.getAttribute('role') || '',
          visible: visible(node),
          ariaHiddenAncestor,
          inertAncestor,
          exactName: text === workspaceName,
          bounds: rectOf(node),
          area: rect.width * rect.height,
        }];
      });
      return {
        workspaceIndex,
        candidateCount: matches.length,
        candidates: matches.sort((left, right) =>
          Number(right.exactName) - Number(left.exactName) ||
          Number(right.role === 'group') - Number(left.role === 'group') ||
          left.area - right.area).slice(0, 3),
      };
    });
  }, orderedNames).catch(() => orderedNames.map((_, workspaceIndex) => ({
    workspaceIndex, candidateCount: 0, candidates: [], snapshotAvailable: false,
  })));
  const viewport = page.viewportSize() || { width: 1440, height: 1000 };
  const actionRows = locatorRows.map((row) => {
    if (!row.bounds) return {
      ...row,
      inViewport: false,
      matchedWorkspaceIndexes: [],
      targetWorkspaceMatch: false,
    };
    const centerX = row.bounds.x + row.bounds.width / 2;
    const centerY = row.bounds.y + row.bounds.height / 2;
    const containingGroups = titleAndGroupRects.flatMap((workspace) =>
      workspace.candidates.some((candidate) => {
        const bounds = candidate.bounds;
        return candidate.visible && !candidate.ariaHiddenAncestor &&
          !candidate.inertAncestor && centerX >= bounds.x &&
          centerX <= bounds.x + bounds.width && centerY >= bounds.y &&
          centerY <= bounds.y + bounds.height;
      }) ? [workspace.workspaceIndex] : []);
    const inViewport = row.bounds.y >= 0 &&
      row.bounds.y + row.bounds.height <= viewport.height;
    return {
      ...row,
      inViewport,
      matchedWorkspaceIndexes: containingGroups,
      targetWorkspaceMatch: containingGroups.includes(index),
    };
  });
  const uiSnapshot = await page.evaluate(({ knownNames, targetName }) => {
    const body = document.body?.innerText || '';
    const normalize = (value) => value.replace(/\s+/g, ' ').trim();
    const titleMatches = [...document.querySelectorAll('flt-semantics')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none' &&
          Number(style.opacity || 1) > 0;
      })
      .flatMap((node) => {
        const text = normalize([
          node.getAttribute('aria-label') || '',
          node.innerText || '',
          node.textContent || '',
        ].filter(Boolean).join(' '));
        return knownNames.flatMap((name, workspaceIndex) =>
          text.includes(name) ? [workspaceIndex] : []);
      });
    return {
      savedWorkspacesHeadingVisible: body.includes('Saved workspaces'),
      disconnectedPreviewStatusVisible:
        body.includes('Disconnected · connect tabs explicitly'),
      tabOneVisible: /\bTab 1\b/.test(body),
      targetWorkspaceNameVisible: body.includes(targetName),
      visibleKnownWorkspaceSemanticIndexes: [...new Set(titleMatches)],
    };
  }, { knownNames: orderedNames, targetName: workspaceName })
    .catch(() => ({ snapshotAvailable: false }));
  const workspacePreviewEvidence = {
    expectedCardCount: orderedNames.length,
    observedCardCount: previewCount,
    locatorCount: buttonCount,
    targetWorkspaceIndex: index,
    targetMappedActionCount: actionRows.filter((row) =>
      row.targetWorkspaceMatch).length,
    actionRows,
    titleAndGroupRects: titleAndGroupRects.map((workspace) => ({
      workspaceIndex: workspace.workspaceIndex,
      candidateCount: workspace.candidateCount,
      candidates: workspace.candidates.map((candidate) => ({
        role: candidate.role,
        visible: candidate.visible,
        ariaHiddenAncestor: candidate.ariaHiddenAncestor,
        inertAncestor: candidate.inertAncestor,
        exactName: candidate.exactName,
        bounds: candidate.bounds,
      })),
    })),
    uiSnapshot,
  };
  console.log(`WEB-WORKSPACE-ONE-TAB-PREVIEW-MAP-${profile} ${JSON.stringify(workspacePreviewEvidence)}`);
  const targetAction = actionRows.filter((row) => row.targetWorkspaceMatch);
  let wheelSteps = 0;
  let finalPreviewBounds = null;
  let targetIsInViewport = false;
  const screenshotOnPreviewFailure = async (phase, error) => {
    const screenshotPath = `/tmp/atermius_workspace_tmux_e2e_${profile.toLowerCase()}_preview_${phase.replace(/[^a-z0-9]+/gi, '_').toLowerCase()}.png`;
    let screenshotSaved = false;
    try {
      await page.screenshot({ path: screenshotPath, fullPage: true, timeout: 5000 });
      screenshotSaved = true;
    } catch (_) {}
    const currentUi = await workspaceNavigationButtonSnapshot(page, 'Workspaces')
      .catch(() => ({ snapshotAvailable: false }));
    const currentCount = await previews.count().catch(() => 0);
    console.error(`WEB-WORKSPACE-ONE-TAB-PREVIEW-FAILURE-${profile} ${JSON.stringify({
      phase,
      errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
      expectedCardCount: orderedNames.length,
      currentPreviewActionCount: currentCount,
      targetWorkspaceIndex: index,
      targetActionLocatorIndex: targetAction[0]?.locatorIndex ?? null,
      targetMappedActionCount: targetAction.length,
      targetIsInViewport,
      targetBounds: finalPreviewBounds,
      wheelSteps,
      currentUi,
      screenshotSaved,
      screenshotPath: screenshotSaved ? screenshotPath : null,
    })}`);
  };
  stage = `Profile ${profile} verify saved one-tab Workspace card count (${JSON.stringify({
    expected: orderedNames.length, observed: previewCount, locatorCount: buttonCount,
  })})`;
  if (previewCount !== orderedNames.length || buttonCount !== orderedNames.length) {
    const error = new Error('saved Workspace preview action count mismatch');
    await screenshotOnPreviewFailure('card_count', error);
    stage = `Profile ${profile} one-tab Workspace card count mismatch`;
    throw error;
  }
  stage = `Profile ${profile} locate preview action by Workspace title group (${JSON.stringify({
    targetWorkspaceIndex: index, mappedTargetActionCount: targetAction.length,
  })})`;
  if (targetAction.length !== 1) {
    const error = new Error('one-tab Workspace title did not map to one unique Preview action');
    await screenshotOnPreviewFailure('title_action_mapping', error);
    stage = `Profile ${profile} one-tab Workspace title action mapping failed`;
    throw error;
  }
  const targetPreview = previews.nth(targetAction[0].locatorIndex);
  stage = `Profile ${profile} bring named one-tab Workspace preview into view`;
  let previewBounds;
  try {
    await targetPreview.scrollIntoViewIfNeeded({ timeout: 3000 });
    previewBounds = await targetPreview.boundingBox().catch(() => null);
    while (previewBounds && wheelSteps < 5) {
      const currentSnapshot = await page.evaluate(() => ({
        width: innerWidth, height: innerHeight,
      })).catch(() => ({ width: viewport.width, height: viewport.height }));
      const top = previewBounds.y;
      const bottom = top + previewBounds.height;
      if (top >= 0 && bottom <= currentSnapshot.height) break;
      const delta = top < 0
        ? Math.max(-700, top - 80)
        : Math.min(700, bottom - currentSnapshot.height + 80);
      await page.mouse.move(Math.max(520, currentSnapshot.width - 80),
        Math.max(80, currentSnapshot.height - 120));
      await page.mouse.wheel(0, delta);
      wheelSteps += 1;
      await page.waitForTimeout(150);
      previewBounds = await targetPreview.boundingBox().catch(() => null);
    }
  } catch (error) {
    await screenshotOnPreviewFailure('scroll', error);
    stage = `Profile ${profile} bring mapped preview into viewport failed`;
    throw error;
  }
  finalPreviewBounds = previewBounds ? {
    x: Math.round(previewBounds.x), y: Math.round(previewBounds.y),
    width: Math.round(previewBounds.width), height: Math.round(previewBounds.height),
  } : null;
  const finalViewport = page.viewportSize() || viewport;
  targetIsInViewport = finalPreviewBounds !== null &&
    finalPreviewBounds.y >= 0 &&
    finalPreviewBounds.y + finalPreviewBounds.height <= finalViewport.height;
  stage = `Profile ${profile} assert mapped one-tab Workspace Preview is visible (${JSON.stringify({
    targetWorkspaceIndex: index,
    targetActionLocatorIndex: targetAction[0].locatorIndex,
    targetIsInViewport,
    wheelSteps,
    bounds: finalPreviewBounds,
  })})`;
  if (!await targetPreview.isVisible().catch(() => false) || !targetIsInViewport) {
    const error = new Error('mapped one-tab Workspace Preview action is out of viewport');
    await screenshotOnPreviewFailure('viewport', error);
    stage = `Profile ${profile} mapped Workspace Preview remains out of viewport`;
    throw error;
  }
  stage = `Profile ${profile} click preview action mapped by Workspace title`;
  try {
    await targetPreview.click({ timeout: 5000 });
  } catch (error) {
    await screenshotOnPreviewFailure('click', error);
    stage = `Profile ${profile} click mapped one-tab Workspace preview failed`;
    throw error;
  }
  stage = `Profile ${profile} wait for disconnected one-tab Workspace status`;
  try {
    await waitForVisibleSemanticText(page, 'Disconnected · connect tabs explicitly',
      'one-tab disconnected Workspace preview', 10000);
  } catch (error) {
    await screenshotOnPreviewFailure('disconnected_status', error);
    stage = `Profile ${profile} disconnected Workspace status wait failed`;
    throw error;
  }
  stage = `Profile ${profile} wait for one-tab Workspace Tab 1 label`;
  try {
    await waitForVisibleSemanticText(page, 'Tab 1', 'one-tab Workspace pane label', 10000);
  } catch (error) {
    await screenshotOnPreviewFailure('tab_1', error);
    stage = `Profile ${profile} Tab 1 label wait failed`;
    throw error;
  }
  stage = `Profile ${profile} wait for exact one-tab Workspace Host reference`;
  try {
    await waitForVisibleSemanticText(page, hostName,
      'one-tab Workspace Host reference', 10000);
  } catch (error) {
    await screenshotOnPreviewFailure('host_reference', error);
    stage = `Profile ${profile} Host reference wait failed`;
    throw error;
  }
  const workspacePaneConnectAction = page.getByRole('button', {
    name: `Tab 1 · ${hostName}`,
    exact: true,
  });
  const focusButtons = page.getByRole('button', { name: 'Focus', exact: true });
  const genericConnectButtons = page.getByRole('button', {
    name: 'Connect', exact: true,
  });
  const [workspacePaneConnectActionCount, focusActionCount,
    genericConnectActionCount] = await Promise.all([
    workspacePaneConnectAction.count().catch(() => 0),
    focusButtons.count().catch(() => 0),
    genericConnectButtons.count().catch(() => 0),
  ]);
  const workspacePaneConnectActionVisible =
    workspacePaneConnectActionCount === 1 &&
    await workspacePaneConnectAction.first().isVisible().catch(() => false);
  const workspacePaneConnectActionEnabled =
    workspacePaneConnectActionCount === 1 &&
    await workspacePaneConnectAction.first().isEnabled().catch(() => false);
  const workspacePaneConnectActionBounds = workspacePaneConnectActionCount === 1
    ? await workspacePaneConnectAction.first().boundingBox().catch(() => null)
    : null;
  console.log(`WEB-WORKSPACE-ONE-TAB-CONNECT-ACTION-${profile} ${JSON.stringify({
    exactWorkspacePaneActionCount: workspacePaneConnectActionCount,
    actionNameMatchesHostReference: workspacePaneConnectActionCount === 1,
    visible: workspacePaneConnectActionVisible,
    enabled: workspacePaneConnectActionEnabled,
    bounds: workspacePaneConnectActionBounds ? {
      x: Math.round(workspacePaneConnectActionBounds.x),
      y: Math.round(workspacePaneConnectActionBounds.y),
      width: Math.round(workspacePaneConnectActionBounds.width),
      height: Math.round(workspacePaneConnectActionBounds.height),
    } : null,
    focusActionCount,
    genericConnectActionCount,
  })}`);
  stage = `Profile ${profile} assert exact one-tab Workspace pane Connect action`;
  if (!(workspacePaneConnectActionCount === 1 &&
      workspacePaneConnectActionVisible && workspacePaneConnectActionEnabled &&
      focusActionCount === 0 && genericConnectActionCount === 0)) {
    const screenshotPath = `/tmp/atermius_workspace_tmux_e2e_${profile.toLowerCase()}_preview_connect_action_failure.png`;
    let screenshotSaved = false;
    try {
      await page.screenshot({ path: screenshotPath, fullPage: true, timeout: 5000 });
      screenshotSaved = true;
    } catch (_) {}
    stage = `Profile ${profile} one-tab Workspace Connect action unavailable (${JSON.stringify({
      exactWorkspacePaneActionCount: workspacePaneConnectActionCount,
      visible: workspacePaneConnectActionVisible,
      enabled: workspacePaneConnectActionEnabled,
      focusActionCount,
      genericConnectActionCount,
      screenshotSaved,
      screenshotPath: screenshotSaved ? screenshotPath : null,
    })})`;
    throw new Error('one-tab Workspace did not expose its exact pane Connect action');
  }
  return workspacePaneConnectAction;
}

async function createNestedSplitWorkspace(page, workspaceName) {
  stage = 'Profile A wait for nested Workspace creator page';
  await waitForVisibleSemanticText(page, 'Saved workspaces',
    'Profile A Workspaces page before nested Workspace creation', 15000);
  stage = 'Profile A wait for nested split Workspace creator readiness';
  const creators = page.getByRole('button', {
    name: 'Create split Workspace', exact: true,
  });
  const readinessDeadline = Date.now() + 15000;
  let creator = null;
  let lastAccessibleCount = 0;
  let lastVisibleCount = 0;
  let lastEnabledCount = 0;
  while (!creator && Date.now() < readinessDeadline) {
    lastAccessibleCount = await creators.count().catch(() => 0);
    lastVisibleCount = 0;
    lastEnabledCount = 0;
    let enabledCandidate = null;
    for (let index = 0; index < lastAccessibleCount; index += 1) {
      const candidate = creators.nth(index);
      if (!await candidate.isVisible().catch(() => false)) continue;
      lastVisibleCount += 1;
      if (await candidate.isEnabled().catch(() => false)) {
        lastEnabledCount += 1;
        enabledCandidate = candidate;
      }
    }
    if (lastVisibleCount === 1 && lastEnabledCount === 1) {
      creator = enabledCandidate;
      break;
    }
    await page.waitForTimeout(100).catch(() => {});
  }
  if (!creator) {
    const [state, accessible, flags, syncStates] = await Promise.all([
      workspaceSplitCreatorSnapshot(page),
      splitCreatorAccessibleSnapshot(page),
      workspaceUiFlags(page),
      page.evaluate(() => {
        const allowed = new Set([
          'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
          'Snapshot needed', 'Rebuilding snapshot', 'Key update needed', 'Read-only',
          'Sign in needed', 'Device revoked', 'Vault deletion pending · read-only',
          'Sync now',
        ]);
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
            style.display !== 'none';
        };
        return [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter(visible)
          .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
          .map((label) => allowed.has(label) ? label :
            /^\d+ pending$/.test(label) ? 'Pending' : null)
          .filter((label, index, values) => label && values.indexOf(label) === index);
      }).catch(() => ['page-unavailable']),
    ]);
    stage = `Profile A nested Workspace creator readiness timed out (${JSON.stringify({
      timeoutMs: 15000,
      lastAccessibleCount,
      lastVisibleCount,
      lastEnabledCount,
      ...state,
      ...accessible,
      pageFlags: flags,
      visibleSyncStates: syncStates,
    })})`;
    throw new Error('nested split Workspace creator did not become enabled within 15 seconds');
  }
  await creator.click();

  stage = 'Profile A fill nested split Workspace name and initial Hosts';
  await field(page, 'Workspace name');
  await fill(page, 'Workspace name', workspaceName);
  await chooseWorkspaceFormOption(page, 'Host · Pane 1', HOST_SPLIT_NAME);
  await chooseWorkspaceFormOption(page, 'Host · Pane 2', HOST_A_NAME);

  stage = 'Profile A configure the root split ratio and nested vertical split';
  await fill(page, 'First child (%)', '63');
  await chooseWorkspaceFormOption(page, 'New split', 'New split: stacked');
  await fill(page, 'New first child (%)', '57');

  stage = 'Profile A split Pane 1 to add the nested third Host leaf';
  const paneOne = page.getByRole('button', { name: 'Pane 1', exact: true });
  assertThat(await paneOne.count() === 1,
    'nested split creator did not expose a unique Pane 1 selector');
  await paneOne.click();
  await click(page, 'Split selected pane');
  await chooseWorkspaceFormOption(page, 'Host · Pane 2', HOST_C_NAME);
  await chooseWorkspaceFormOption(page, 'Active pane', `Pane 2 · ${HOST_C_NAME}`);

  stage = 'Profile A verify nested leaf and active-pane selections before save';
  for (const text of [
    'Pane 1', HOST_SPLIT_NAME,
    'Pane 2', HOST_C_NAME,
    'Pane 3', HOST_A_NAME,
  ]) {
    await waitForVisibleSemanticText(page, text, `nested draft content: ${text}`, 10000);
  }
  await installSplitSaveFeedbackProbe(page);
  stage = 'Profile A save the recursive mixed-axis Workspace';
  await click(page, 'Save split Workspace');
  await waitForSavedSplitWorkspaceCard(
    page, workspaceName, 1, 20000, 'total',
  );
  await stopSplitSaveFeedbackProbe(page);
}

async function createMaximumPaneWorkspace(page, workspaceName) {
  stage = 'Profile A open the eight-pane Workspace creator';
  await click(page, 'Create split Workspace');
  await fill(page, 'Workspace name', workspaceName);
  await waitForVisibleSemanticText(page, 'Terminal panes · 2/8',
    'split creator opened with two panes', 5000);
  console.log('WEB-WORKSPACE-MAX-PANES-CREATOR-CHECKPOINT', JSON.stringify({
    creatorOpen: true,
    initialPaneCount: 2,
  }));

  stage = 'Profile A choose deterministic initial Host references';
  await chooseWorkspaceFormOption(page, 'Host · Pane 1', HOST_A_NAME);
  await chooseWorkspaceFormOption(page, 'Host · Pane 2', HOST_B_NAME);

  // Alternate between both root branches, then their children. This keeps the
  // eight-leaf preview balanced so every Host remains visible in Profile B.
  const splitTargets = [1, 3, 1, 4, 3, 7];
  for (const [index, targetPane] of splitTargets.entries()) {
    stage = `Profile A grow the split tree to ${index + 3}/8 panes`;
    await click(page, `Pane ${targetPane}`);
    await click(page, 'Split selected pane');
  }

  const expectedHosts = [
    HOST_A_NAME, HOST_B_NAME, HOST_B_NAME, HOST_A_NAME,
    HOST_B_NAME, HOST_A_NAME, HOST_A_NAME, HOST_B_NAME,
  ];
  await waitForVisibleSemanticText(page, 'Terminal panes · 8/8',
    'creator reached the eight-pane boundary before removal', 5000);
  console.log('WEB-WORKSPACE-MAX-PANES-BOUNDARY-CHECKPOINT', JSON.stringify({
    paneCount: 8,
    expectedOrderedHosts: true,
  }));

  stage = 'Profile A remove and restore the eighth pane';
  await click(page, 'Pane 8');
  const removeLastPane = page.getByRole('button', {
    name: 'Remove Pane 8', exact: true,
  });
  assertThat(await removeLastPane.count() === 1 &&
    await removeLastPane.isEnabled(),
  'the eighth pane did not expose an enabled remove control');
  await removeLastPane.click();
  await waitForVisibleSemanticText(page, 'Terminal panes · 7/8',
    'seven-pane state after removing the eighth leaf', 5000);
  await click(page, 'Pane 7');
  await click(page, 'Split selected pane');
  await waitForVisibleSemanticText(page, 'Terminal panes · 8/8',
    'restored eight-pane state', 5000);

  stage = 'Profile A verify the maximum split action is disabled';
  const addPane = page.getByRole('button', {
    name: 'Split selected pane', exact: true,
  });
  assertThat(await addPane.count() === 1 && !await addPane.isEnabled(),
    'the split creator allowed adding a ninth pane');
  const activePaneControl = page.getByRole('button', {
    name: /^Active pane(?:\s|$)/i,
  }).last();
  await activePaneControl.scrollIntoViewIfNeeded();
  await chooseWorkspaceFormOption(page, 'Active pane',
    `Pane 8 · ${expectedHosts[7]}`);

  stage = 'Profile A verify eight selected Host dropdown values before save';
  const selectedHostAssignments = await page.evaluate((hosts) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 &&
        style.visibility !== 'hidden' && style.display !== 'none' &&
        Number(style.opacity || 1) > 0;
    };
    const labelOf = (node) =>
      `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
        .replace(/\s+/g, ' ').trim();
    const semantics = [...document.querySelectorAll('flt-semantics')]
      .filter(visible);
    return hosts.map((host, index) => {
      const prefix = `Host · Pane ${index + 1}`.toLowerCase();
      const fields = semantics.filter((node) =>
        node.getAttribute('role') === 'button' &&
        labelOf(node).toLowerCase().startsWith(prefix));
      return {
        fieldCount: fields.length,
        selectedMatch: fields.some((node) =>
          labelOf(node).toLowerCase().includes(host.toLowerCase())),
      };
    });
  }, expectedHosts).catch(() => []);
  assertThat(selectedHostAssignments.length === 8 &&
    selectedHostAssignments.every((field) =>
      field.fieldCount === 1 && field.selectedMatch),
  'the eight-pane creator did not retain the expected ordered Host selections');
  console.log('WEB-WORKSPACE-MAX-PANES-HOST-MAP-CHECKPOINT', JSON.stringify({
    paneCount: selectedHostAssignments.length,
    orderedHostAssignments: true,
    activePane: 8,
  }));
  return expectedHosts;
}

async function createRenameSyncWorkspace(page, workspaceName) {
  stage = 'Profile A open the two-pane Workspace creator for rename sync';
  await click(page, 'Create split Workspace');
  await fill(page, 'Workspace name', workspaceName);
  await waitForVisibleSemanticText(page, 'Terminal panes · 2/8',
    'rename-sync creator opened with two panes', 5000);
  await chooseWorkspaceFormOption(page, 'Host · Pane 1', HOST_A_NAME);
  await chooseWorkspaceFormOption(page, 'Host · Pane 2', HOST_B_NAME);
  await chooseWorkspaceFormOption(page, 'Active pane', `Pane 2 · ${HOST_B_NAME}`);
  for (const label of [
    `Host · Pane 1`, HOST_A_NAME,
    `Host · Pane 2`, HOST_B_NAME,
    `Active pane`, `Pane 2 · ${HOST_B_NAME}`,
  ]) {
    await waitForVisibleSemanticText(page, label,
      `rename-sync draft selection: ${label}`, 10000);
  }
  await installSplitSaveFeedbackProbe(page);
  stage = 'Profile A save the initial two-pane Workspace for rename sync';
  await click(page, 'Save split Workspace');
  await waitForSavedSplitWorkspaceCard(page, workspaceName, 1, 20000, 'total');
  await stopSplitSaveFeedbackProbe(page);
}

async function workspaceTerminalRuntimeSnapshot(page, hostNames) {
  return page.evaluate((names) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none';
    };
    const labels = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '')
        .replace(/\s+/g, ' ').trim());
    return names.map((hostName) => {
      const matching = labels.filter((label) =>
        label.startsWith(`${hostName} terminal tab,`));
      return {
        count: matching.length,
        connectingCount: matching.filter((label) =>
          label.includes('terminal tab, connecting,')).length,
        connectedCount: matching.filter((label) =>
          label.includes('terminal tab, connected,')).length,
        failedCount: matching.filter((label) =>
          label.includes('terminal tab, failed,')).length,
      };
    });
  }, hostNames).catch(() => hostNames.map(() => ({
    count: 0, connectingCount: 0, connectedCount: 0, failedCount: 0,
  })));
}

async function workspaceTerminalTabDiagnosticSnapshot(page, hostName) {
  const ui = await page.evaluate((expectedHostName) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none';
    };
    const labels = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
    const tabs = labels.map((label) => {
      const match = label.match(/^(.+?) terminal tab, (connected|disconnected|connecting|failed), (active|inactive)$/i);
      return match ? {
        hostMatchesExpected: match[1] === expectedHostName,
        state: match[2].toLowerCase(),
        active: match[3] === 'active',
      } : null;
    }).filter((item) => item !== null);
    const body = document.body?.innerText || '';
    return {
      terminalTitleVisible: body.includes('Terminal workspace'),
      hostsHeadingVisible: body.includes('Your server fleet'),
      workspacesHeadingVisible: body.includes('Saved workspaces'),
      disconnectedTerminalSurfaceVisible: body.includes('SSH terminal · disconnected'),
      visibleTerminalTabCount: tabs.length,
      expectedHostTabMatchCount: tabs.filter((tab) => tab.hostMatchesExpected).length,
      expectedHostTabConnectedCount: tabs.filter((tab) =>
        tab.hostMatchesExpected && tab.state === 'connected').length,
      expectedHostTabDisconnectedCount: tabs.filter((tab) =>
        tab.hostMatchesExpected && tab.state === 'disconnected').length,
      expectedHostTabConnectingCount: tabs.filter((tab) =>
        tab.hostMatchesExpected && tab.state === 'connecting').length,
      expectedHostTabActiveCount: tabs.filter((tab) =>
        tab.hostMatchesExpected && tab.active).length,
      closeSavedPreviewVisible: labels.includes('Close saved layout preview'),
      closeTerminalSearchVisible: labels.includes('Close terminal search'),
      closeTabActionCount: labels.filter((label) => /^Close .+$/.test(label) &&
        label !== 'Close saved layout preview' &&
        label !== 'Close terminal search').length,
    };
  }, hostName).catch(() => ({ diagnosticsUnavailable: true }));
  const runtimes = await workspaceTerminalRuntimeSnapshot(page, [hostName]);
  return {
    ...ui,
    matchingRuntimeCount: runtimes[0]?.count ?? 0,
    matchingRuntimeConnectedCount: runtimes[0]?.connectedCount ?? 0,
    matchingRuntimeConnectingCount: runtimes[0]?.connectingCount ?? 0,
    matchingRuntimeFailedCount: runtimes[0]?.failedCount ?? 0,
  };
}

async function workspaceNavigationButtonSnapshot(page, expectedName) {
  const locator = page.getByRole('button', { name: expectedName, exact: true });
  const locatorCount = await locator.count().catch(() => 0);
  const locatorMatches = [];
  for (let index = 0; index < locatorCount; index += 1) {
    const candidate = locator.nth(index);
    const visible = await candidate.isVisible().catch(() => false);
    const bounds = visible ? await candidate.boundingBox().catch(() => null) : null;
    locatorMatches.push({
      visible,
      bounds: bounds ? {
        x: Math.round(bounds.x), y: Math.round(bounds.y),
        width: Math.round(bounds.width), height: Math.round(bounds.height),
      } : null,
    });
  }
  const semanticMatches = await page.evaluate((expected) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none' && Number(style.opacity || 1) > 0;
    };
    const normalize = (value) => value.replace(/\s+/g, ' ').trim();
    return [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter((node) => {
        const name = normalize(node.getAttribute('aria-label') ||
          node.innerText || node.textContent || '');
        return name === expected;
      })
      .map((node) => {
        const rect = node.getBoundingClientRect();
        let ariaHiddenAncestor = false;
        let inertAncestor = false;
        for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
          if ((ancestor.getAttribute('aria-hidden') || '').toLowerCase() === 'true') {
            ariaHiddenAncestor = true;
          }
          if (ancestor.hasAttribute('inert')) inertAncestor = true;
        }
        return {
          role: node.getAttribute('role') || '',
          visible: visible(node),
          ariaHiddenAncestor,
          inertAncestor,
          bounds: {
            x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.width), height: Math.round(rect.height),
          },
        };
      });
  }, expectedName).catch(() => []);
  const bodySnapshot = await page.evaluate(() => {
    const body = document.body?.innerText || '';
    return {
      terminalTitleVisible: body.includes('Terminal workspace'),
      hostsHeadingVisible: body.includes('Your server fleet'),
      workspacesHeadingVisible: body.includes('Saved workspaces'),
      savedWorkspaceCardVisible: body.includes('Preview disconnected layout'),
    };
  }).catch(() => ({
    terminalTitleVisible: false,
    hostsHeadingVisible: false,
    workspacesHeadingVisible: false,
    savedWorkspaceCardVisible: false,
  }));
  return {
    expectedName,
    locatorCount,
    visibleLocatorCount: locatorMatches.filter((match) => match.visible).length,
    locatorMatches,
    semanticMatchCount: semanticMatches.length,
    semanticMatches,
    ...bodySnapshot,
  };
}

async function waitForWorkspaceTerminalRuntimes(page, hostNames, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let snapshot = await workspaceTerminalRuntimeSnapshot(page, hostNames);
  while (Date.now() < deadline) {
    if (snapshot.every((item) => item.count === 1 && item.failedCount === 0 &&
        item.connectingCount + item.connectedCount === 1)) return snapshot;
    await page.waitForTimeout(100);
    snapshot = await workspaceTerminalRuntimeSnapshot(page, hostNames);
  }
  return snapshot;
}

async function waitForWorkspaceTerminalRuntimeRemoval(page, hostNames, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let snapshot = await workspaceTerminalRuntimeSnapshot(page, hostNames);
  while (Date.now() < deadline) {
    if (snapshot.every((item) => item.count === 0)) return snapshot;
    await page.waitForTimeout(100);
    snapshot = await workspaceTerminalRuntimeSnapshot(page, hostNames);
  }
  throw new Error('workspace terminal runtime removal did not become visible');
}

async function nestedPaneConnectionUiSnapshot(page, paneNumber, hostName) {
  const paneBounds = await visibleSidebarTextBounds(page, `Pane ${paneNumber}`);
  const hostBounds = await visibleSidebarTextBounds(page, hostName);
  const pairs = [];
  for (const pane of paneBounds) {
    for (const host of hostBounds) {
      const verticalDistance = Math.abs(pane.centerY - host.centerY);
      const horizontalDistance = Math.abs(pane.centerX - host.centerX);
      if (verticalDistance <= 45 && horizontalDistance <= 180) {
        pairs.push({ pane, host, score: verticalDistance + horizontalDistance / 20 });
      }
    }
  }
  pairs.sort((left, right) => left.score - right.score);
  const pair = pairs[0];
  const nearbyActionCount = async (label) => {
    if (!pair) return 0;
    const locator = page.getByRole('button', { name: label, exact: true });
    let matching = 0;
    const count = await locator.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      const candidate = locator.nth(index);
      if (!await candidate.isVisible().catch(() => false)) continue;
      const bounds = await candidate.boundingBox().catch(() => null);
      if (bounds && bounds.x + bounds.width <= 510 &&
          Math.abs(bounds.y + bounds.height / 2 - pair.host.centerY) <= 45 &&
          Math.abs(bounds.x + bounds.width / 2 - pair.host.centerX) <= 180) {
        matching += 1;
      }
    }
    return matching;
  };
  const [connectActionCount, focusActionCount, runtime, alertState] =
    await Promise.all([
      nearbyActionCount('Connect'),
      nearbyActionCount('Focus'),
      workspaceTerminalRuntimeSnapshot(page, [hostName]),
      page.evaluate(() => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none' &&
            Number(style.opacity || 1) > 0;
        };
        const alertNodes = [...document.querySelectorAll(
          '[role="alert"], [aria-live]',
        )].filter(visible);
        const semanticNodes = [...document.querySelectorAll('flt-semantics')]
          .filter(visible);
        let failureNodeCount = 0;
        const readLabel = (node) => [
          node.getAttribute('aria-label') || '',
          node.innerText || '',
          node.textContent || '',
        ].join(' ').replace(/\s+/g, ' ').trim();
        const alertLabels = alertNodes.map(readLabel).filter(Boolean);
        for (const node of semanticNodes) {
          const label = [
            node.getAttribute('aria-label') || '',
            node.innerText || '',
            node.textContent || '',
          ].join(' ').replace(/\s+/g, ' ').trim();
          if (/error|failed|unable|unavailable|not found|invalid|credential|凭据|认证|错误|失败|不可用/i
            .test(label)) failureNodeCount += 1;
        }
        const combined = alertLabels.join(' ').toLowerCase();
        return {
          visibleAlertNodeCount: alertNodes.length,
          visibleFailureNodeCount: failureNodeCount,
          hostKeyPromptVisible: semanticNodes.some((node) =>
            readLabel(node).includes('Verify SSH host key')),
          trustActionVisible: semanticNodes.some((node) =>
            readLabel(node).includes('Trust after verification')),
          alertCategory: /credential|凭据|认证/.test(combined) ? 'credential' :
            /host reference|host.*missing|主机.*不存在|主机.*不可用/.test(combined)
              ? 'host-reference' :
              /relay|ticket|中继/.test(combined) ? 'relay' :
                /network|timeout|连接失败|网络/.test(combined) ? 'network' :
                  failureNodeCount > 0 ? 'other-error' :
                    alertLabels.length > 0 ? 'unclassified-alert' : 'none',
        };
      }).catch(() => ({
        visibleAlertNodeCount: 0,
        visibleFailureNodeCount: 0,
        hostKeyPromptVisible: false,
        trustActionVisible: false,
        alertCategory: 'snapshot-unavailable',
      })),
    ]);
  return {
    paneHostPairCount: pairs.length,
    uniquePaneHostPair: Boolean(pair &&
      (pairs.length === 1 || pairs[1].score - pair.score >= 4)),
    connectActionCount,
    focusActionCount,
    terminalRuntime: runtime[0],
    visibleAlertNodeCount: alertState.visibleAlertNodeCount,
    visibleFailureNodeCount: alertState.visibleFailureNodeCount,
    hostKeyPromptVisible: alertState.hostKeyPromptVisible,
    trustActionVisible: alertState.trustActionVisible,
    alertCategory: alertState.alertCategory,
  };
}

async function monitorNestedPaneConnectionUi(page, paneNumber, hostName, shouldContinue) {
  let sampleCount = 0;
  let maxVisibleAlertNodeCount = 0;
  let maxVisibleFailureNodeCount = 0;
  const alertCategories = new Set();
  let latest = null;
  while (shouldContinue()) {
    latest = await nestedPaneConnectionUiSnapshot(page, paneNumber, hostName);
    sampleCount += 1;
    maxVisibleAlertNodeCount = Math.max(maxVisibleAlertNodeCount,
      latest.visibleAlertNodeCount);
    maxVisibleFailureNodeCount = Math.max(maxVisibleFailureNodeCount,
      latest.visibleFailureNodeCount);
    alertCategories.add(latest.alertCategory);
    await page.waitForTimeout(250);
  }
  return {
    sampleCount,
    maxVisibleAlertNodeCount,
    maxVisibleFailureNodeCount,
    alertCategories: [...alertCategories].sort(),
    latest,
  };
}

async function paste(page, label, value) {
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(300);
    if (await locator.inputValue() === value) return;
  }
  await locator.fill(value);
  await page.waitForTimeout(100);
  assertThat(await locator.inputValue() === value, `paste did not populate field: ${label}`);
}

async function enableSemantics(page, label = 'Flutter', diagnostics = []) {
  try {
    const deadline = Date.now() + 30000;
    let sodiumReady = false;
    while (Date.now() < deadline) {
      const state = await page.evaluate(() => ({
        sodiumReady: typeof window.sodium?.ready?.then === 'function',
        hasPlaceholder: Boolean(document.querySelector('flt-semantics-placeholder')),
        hasSemantics: document.querySelectorAll('flt-semantics').length > 0,
      }));
      sodiumReady = state.sodiumReady;
      if (state.sodiumReady && (state.hasPlaceholder || state.hasSemantics)) break;
      await page.waitForTimeout(100);
    }
    if (!sodiumReady) throw new Error('Flutter crypto runtime did not initialize');
    await page.evaluate(async () => window.sodium?.ready);
    const semanticDeadline = Date.now() + 15000;
    let clickedPlaceholder = false;
    while (Date.now() < semanticDeadline) {
      if (await page.locator('flt-semantics').count() > 0) return;
      const placeholder = page.locator('flt-semantics-placeholder');
      if (!clickedPlaceholder && await placeholder.count() > 0) {
        await placeholder.first().evaluate((node) => node.click());
        clickedPlaceholder = true;
      }
      await page.waitForTimeout(100);
    }
    throw new Error('Flutter semantics tree unavailable');
  } catch (error) {
    const state = await page.evaluate(() => ({
      readyState: document.readyState,
      sodiumPresent: Boolean(window.sodium),
      sodiumReadyType: typeof window.sodium?.ready,
      sodiumReadyThenable: typeof window.sodium?.ready?.then === 'function',
      sodiumScriptCount: [...document.scripts].filter((script) =>
        (script.src || '').endsWith('/sodium.js')).length,
      semanticsPlaceholderCount: document.querySelectorAll('flt-semantics-placeholder').length,
      semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      flutterViewCount: document.querySelectorAll('flutter-view').length,
      canvasCount: document.querySelectorAll('canvas').length,
      scriptBasenames: [...document.scripts].map((script) => {
        try { return new URL(script.src).pathname.split('/').at(-1); } catch (_) { return ''; }
      }).filter(Boolean),
    })).catch(() => ({ documentUnavailable: true }));
    const reason = error.message === 'Flutter crypto runtime did not initialize'
      ? 'crypto-runtime-unavailable'
      : error.message === 'Flutter semantics tree unavailable'
        ? 'semantics-tree-unavailable'
        : error.name;
    const resources = diagnostics.filter((item) => item.kind === 'resource')
      .map(({ name, status, failureCategory }) => ({ name, status, failureCategory }));
    const runtimeErrors = diagnostics.filter((item) => item.kind === 'runtime')
      .map((item) => item.category);
    stage = `${label} semantics initialization failed (${reason}; ${JSON.stringify({
      ...state,
      resources,
      runtimeErrorCategories: runtimeErrors,
    })})`;
    throw error;
  }
}

async function connectSecurely(page, baseUrl) {
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

async function waitForWorkspace(page) {
  await visibleButton(page, 'Add host');
}

async function restoreWorkspaceAfterReload(page, profile, baseUrl) {
  try {
    return await restoreWorkspaceAfterReloadCore(page, profile, baseUrl);
  } catch (error) {
    const innerStage = stage;
    const state = await page.evaluate(() => ({
      readyState: document.readyState,
      semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      semanticsPlaceholderCount: document.querySelectorAll('flt-semantics-placeholder').length,
      connectScreen: (document.body?.innerText || '').includes('Connect to your server'),
      loginScreen: (document.body?.innerText || '').includes('Unlock your workspace'),
      registrationScreen: (document.body?.innerText || '').includes('Set up your private vault'),
      serverUrlField: [...document.querySelectorAll('input')]
        .some((node) => (node.getAttribute('aria-label') || '').includes('Server URL')),
      loginField: [...document.querySelectorAll('input')]
        .some((node) => (node.getAttribute('aria-label') || '').includes('Email or username')),
      masterPasswordField: [...document.querySelectorAll('input')]
        .some((node) => (node.getAttribute('aria-label') || '').includes('Master password')),
    })).catch(() => ({ documentUnavailable: true }));
    const safeMessages = new Map([
      ['visible field unavailable: Email or username', 'login-email-field-unavailable'],
      ['field did not retain input: Email or username', 'login-email-input-not-retained'],
      ['visible field unavailable: Master password', 'master-password-field-unavailable'],
      ['field did not retain input: Master password', 'master-password-input-not-retained'],
      ['visible button unavailable: Sign in and unlock', 'sign-in-button-unavailable'],
    ]);
    const reason = safeMessages.get(error.message) ||
      (/multiple visible fields matched: Email or username/i.test(error.message)
        ? 'duplicate-login-email-fields'
        : /multiple visible fields matched: Master password/i.test(error.message)
          ? 'duplicate-master-password-fields'
          : /Target page, context or browser has been closed/i.test(error.message)
            ? 'target-closed'
            : /Execution context was destroyed/i.test(error.message)
              ? 'document-reloaded-during-action'
              : /not attached to the DOM/i.test(error.message)
                ? 'control-rebuilt-during-action'
                : error.name);
    stage = `Profile ${profile} reload recovery interrupted (${reason}; innerStage=${innerStage}; ${JSON.stringify({
      pageClosed: page.isClosed(),
      state,
    })})`;
    throw error;
  }
}

async function restoreWorkspaceAfterReloadCore(page, profile, baseUrl) {
  stage = `Profile ${profile} reload Web application document`;
  await page.reload({ waitUntil: 'domcontentloaded' });
  stage = `Profile ${profile} restore Flutter semantics after reload`;
  try {
    await enableSemantics(page);
  } catch (error) {
    const state = await page.evaluate(() => ({
      readyState: document.readyState,
      sodiumPresent: Boolean(window.sodium),
      sodiumReadyType: typeof window.sodium?.ready,
      semanticsPlaceholderCount: document.querySelectorAll('flt-semantics-placeholder').length,
      semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      flutterViewCount: document.querySelectorAll('flutter-view').length,
      canvasCount: document.querySelectorAll('canvas').length,
    })).catch(() => ({ documentUnavailable: true }));
    const reason = error.message === 'Flutter crypto runtime did not initialize'
      ? 'crypto-runtime-unavailable'
      : error.message === 'Flutter semantics tree unavailable'
        ? 'semantics-tree-unavailable'
        : error.name;
    stage = `Profile ${profile} restore Flutter semantics failed (${reason}; ${JSON.stringify(state)})`;
    throw error;
  }
  stage = `Profile ${profile} wait for authenticated Workspace shell after reload`;
  let deadline = Date.now() + 30000;
  let connected = false;
  let submittedLogin = false;
  let submittedUnlock = false;
  while (Date.now() < deadline) {
    if (await page.getByRole('button', { name: 'Add host', exact: true })
      .isVisible().catch(() => false)) {
      stage = `Profile ${profile} authenticated Workspace shell restored`;
      return { connected, submittedLogin, submittedUnlock };
    }
    const continueButton = page.getByRole('button', {
      name: 'Continue', exact: true,
    }).last();
    if (await continueButton.isVisible().catch(() => false) &&
        await continueButton.isEnabled().catch(() => false)) {
      stage = `Profile ${profile} continue Web server setup after reload`;
      await continueButton.click().catch(() => {});
      await page.waitForTimeout(120);
      deadline = Date.now() + 30000;
      continue;
    }
    const connectButton = page.getByRole('button', {
      name: 'Connect securely', exact: true,
    }).first();
    if (!connected && await connectButton.isVisible().catch(() => false) &&
        await connectButton.isEnabled().catch(() => false)) {
      stage = `Profile ${profile} reconnect Web server after reload`;
      const savedServerField = page.locator('input[aria-label*="Server URL"]');
      try {
        if (await savedServerField.isVisible().catch(() => false) &&
            await savedServerField.inputValue().catch(() => '') !== baseUrl) {
          await fill(page, 'Server URL', baseUrl);
        }
        await connectButton.click();
      } catch (error) {
        const state = {
          serverFieldVisible: await savedServerField.isVisible().catch(() => false),
          serverValueMatches: await savedServerField.inputValue().then((value) =>
            value === baseUrl).catch(() => false),
          connectButtonVisible: await connectButton.isVisible().catch(() => false),
          loginEmailVisible: await page.locator('input[aria-label*="Email or username"]')
            .isVisible().catch(() => false),
          masterPasswordVisible: await page.locator('input[aria-label*="Master password"]')
            .isVisible().catch(() => false),
          workspaceVisible: await page.getByRole('button', {
            name: 'Add host', exact: true,
          }).isVisible().catch(() => false),
        };
        if (state.loginEmailVisible || state.masterPasswordVisible || state.workspaceVisible ||
            (!state.serverFieldVisible && !state.connectButtonVisible)) {
          connected = true;
        } else {
          const reason = error.message === 'visible field unavailable: Server URL'
            ? 'server-field-unavailable'
            : error.message === 'field did not retain input: Server URL'
              ? 'server-url-not-retained'
              : error.name;
          stage = `Profile ${profile} reconnect Web server failed (${reason}; ${JSON.stringify(state)})`;
          throw error;
        }
      }
      connected = true;
      await page.waitForTimeout(150);
      stage = `Profile ${profile} restore semantic controls after reconnect`;
      await enableSemantics(page);
      stage = `Profile ${profile} wait for authenticated Workspace shell after reload`;
      deadline = Date.now() + 30000;
      continue;
    }
    const emailInput = page.locator('input[aria-label*="Email or username"]');
    const passwordInput = page.locator('input[aria-label*="Master password"]');
    if (!submittedLogin && await emailInput.isVisible().catch(() => false) &&
        await passwordInput.isVisible().catch(() => false)) {
      stage = `Profile ${profile} reauthenticate after Web reload`;
      await fill(page, 'Email or username', USERNAME);
      await fill(page, 'Master password', MASTER_PASSWORD);
      submittedLogin = true;
      await click(page, 'Sign in and unlock').catch(() => {});
      await page.waitForTimeout(150);
      deadline = Date.now() + 30000;
      continue;
    }
    const unlockButton = page.getByRole('button', { name: 'Unlock', exact: true });
    if (!submittedUnlock && await passwordInput.isVisible().catch(() => false) &&
        await unlockButton.isVisible().catch(() => false)) {
      stage = `Profile ${profile} unlock after Web reload`;
      await fill(page, 'Master password', MASTER_PASSWORD);
      submittedUnlock = true;
      await unlockButton.click().catch(() => {});
      await page.waitForTimeout(150);
      deadline = Date.now() + 30000;
      continue;
    }
    stage = `Profile ${profile} wait for login or Workspace after reload`;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const controls = await workspaceUiFlags(page);
  const surface = await page.evaluate(() => {
    const body = document.body?.innerText || '';
    const safeLabels = new Set([
      'Server URL', 'Connect securely', 'Continue', 'Email or username',
      'Master password', 'Sign in and unlock', 'Unlock', 'Add host',
      'Hosts', 'Workspaces', 'Sync & conflicts', 'Import approval',
      'Generate request', 'Create owner account', 'Retry', 'Cancel',
    ]);
    const visibleLabels = [...document.querySelectorAll('flt-semantics')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      })
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
      .filter((label) => safeLabels.has(label));
    const visibleInput = (part) => [...document.querySelectorAll('input')].some((node) => {
      if (!(node.getAttribute('aria-label') || '').includes(part)) return false;
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none';
    });
    return {
      connectScreen: body.includes('Connect to your server'),
      loginScreen: body.includes('Unlock your workspace'),
      registrationScreen: body.includes('Set up your private vault'),
      serverChooserScreen: body.includes('Choose a workspace'),
      visibleLabels,
      visibleServerUrlField: visibleInput('Server URL'),
      visibleLoginField: visibleInput('Email or username'),
      visibleMasterPasswordField: visibleInput('Master password'),
      connectButton: [...document.querySelectorAll('flt-semantics')]
        .some((node) => (node.getAttribute('aria-label') || node.innerText || '')
          .trim() === 'Connect securely'),
      addHostButton: [...document.querySelectorAll('flt-semantics')]
        .some((node) => (node.getAttribute('aria-label') || node.innerText || '')
          .trim() === 'Add host'),
    };
    }).catch(() => ({ documentUnavailable: true }));
  stage = `Profile ${profile} reload did not restore workspace (${JSON.stringify({
    connected,
    submittedLogin,
    submittedUnlock,
    controls,
    surface,
    pageClosed: page.isClosed(),
  })})`;
  throw new Error('reloaded Web profile did not return to the workspace');
}

async function syncNow(page, syncLabel = 'encrypted sync', {
  forcePull = false,
  allowSettledPending = false,
} = {}) {
  stage = `locate ${syncLabel} sync control`;
  const statuses = page.getByRole('button', { name: SYNC_BUTTON_LABEL });
  const deadline = Date.now() + 20000;
  let status = null;
  while (!status && Date.now() < deadline) {
    const count = await statuses.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = statuses.nth(index);
      if (await candidate.isVisible()) {
        status = candidate;
        break;
      }
    }
    if (!status) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!status) {
    const allowed = new Set([
      'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
      'Snapshot needed', 'Rebuilding snapshot', 'Key update needed', 'Read-only',
      'Sign in needed', 'Device revoked', 'Vault deletion pending · read-only',
      'Sync now',
    ]);
    const safeLabels = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
        .filter(Boolean),
    ).catch(() => []);
    const safeState = safeLabels.find((label) => allowed.has(label) || /^\d+ pending$/.test(label)) || 'unrecognized';
    stage = `locate ${syncLabel} sync control (${safeState})`;
    throw new Error(`Sync control unavailable for ${syncLabel}`);
  }
  let label = (await status.getAttribute('aria-label') || await status.innerText()).trim();
  if (label === 'Syncing') {
    // A pass already in flight can have started before a newly written outbox
    // row existed. Let it settle, then re-read the status and explicitly start
    // another pass if it left work Pending. For forced pulls this also ensures
    // the response waiter is attached before the request we intend to observe.
    status = null;
    const settleDeadline = Date.now() + 45000;
    while (!status && Date.now() < settleDeadline) {
      const count = await statuses.count();
      for (let index = 0; index < count; index += 1) {
        const candidate = statuses.nth(index);
        if (!await candidate.isVisible().catch(() => false)) continue;
        const candidateLabel = (await candidate.getAttribute('aria-label') ||
          await candidate.innerText().catch(() => '')).trim();
        if (candidateLabel === 'Syncing') continue;
        status = candidate;
        label = candidateLabel;
        break;
      }
      if (!status) await page.waitForTimeout(100);
    }
    if (!status) throw new Error(`Sync control unavailable after settling ${syncLabel}`);
  }
  const changesResponse = forcePull
    ? page.waitForResponse((response) => {
        const url = new URL(response.url());
        return response.request().method() === 'GET' && url.pathname.endsWith('/changes');
      }, { timeout: 45000 })
    : null;
  let changesPageSummary = null;
  stage = `trigger ${syncLabel} sync`;
  if (label !== 'Syncing') {
    await status.click();
  }
  if (changesResponse) {
    const response = await changesResponse;
    assertThat(response.status() === 200,
      `${syncLabel} changes request did not succeed`);
    const body = await response.json().catch(() => null);
    const events = Array.isArray(body?.events) ? body.events : [];
    changesPageSummary = {
      httpStatus: response.status(),
      eventCount: events.length,
      createEventCount: events.filter((event) => event?.event_type === 'create').length,
      updateEventCount: events.filter((event) => event?.event_type === 'update').length,
      seenRecordIds: events.map((event) => event?.record_id)
        .filter((recordId) => typeof recordId === 'string'),
      seenOperationKinds: events.map((event) => event?.event_type || 'unknown'),
      responsePlaintextMarkersAbsent: markerScan(body),
    };
  }
  stage = `wait for ${syncLabel} sync to settle`;
  const safeVisibleSyncStates = async () => page.evaluate(() => {
    const known = new Set([
      'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
      'Snapshot needed', 'Rebuilding snapshot', 'Key update needed', 'Read-only',
      'Sign in needed', 'Device revoked', 'Vault deletion pending · read-only',
      'Sync now',
    ]);
    return [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      })
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
      .map((label) => known.has(label) ? label : /^\d+ pending$/.test(label) ? 'Pending' : null)
      .filter(Boolean);
  });
  const settleDeadline = Date.now() + 45000;
  let settled = false;
  let safeState = 'unrecognized';
  while (!settled && Date.now() < settleDeadline) {
    let visibleStates;
    try {
      visibleStates = await safeVisibleSyncStates();
    } catch (_) {
      stage = `wait for ${syncLabel} sync to settle (${safeState}; page unavailable)`;
      throw new Error(`Sync status unavailable for ${syncLabel}`);
    }
    safeState = visibleStates[0] || 'unrecognized';
    const settledStatus = visibleStates.some((state) => state === 'Idle' ||
      state === 'Read-only' || (allowSettledPending && state === 'Pending'));
    let controlEnabled = false;
    const statusCount = await statuses.count();
    for (let index = 0; index < statusCount; index += 1) {
      const candidate = statuses.nth(index);
      if (await candidate.isVisible().catch(() => false) &&
          await candidate.isEnabled().catch(() => false)) {
        controlEnabled = true;
        break;
      }
    }
    stage = `wait for ${syncLabel} sync to settle (${safeState}; control=${controlEnabled ? 'ready' : 'busy'})`;
    settled = settledStatus && controlEnabled;
    if (!settled) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!settled) {
    stage = `wait for ${syncLabel} sync to settle (${safeState})`;
    throw new Error(`Sync did not settle for ${syncLabel}`);
  }
  return changesPageSummary;
}

async function addCredential(page, getPageErrorCount = () => 0, {
  name = CREDENTIAL_NAME,
  username = SSH_USERNAME,
  password = CREDENTIAL_SECRET,
} = {}) {
  stage = 'open credential editor';
  await click(page, 'Credentials');
  await waitForText(page, 'SSH credentials');
  await click(page, 'Add credential');
  stage = 'fill encrypted credential';
  await fill(page, 'Credential name', name);
  await fill(page, 'SSH username', username);
  await fill(page, 'Password', password);
  const logSafeFailure = async (phase, error) => {
    const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
    const snapshot = await encryptedCredentialSaveSnapshot(page, {
      expectedName: name,
      expectedUsername: username,
      expectedPassword: password,
      pageErrorCount: getPageErrorCount(),
    });
    console.error(`WEB-WORKSPACE-CREDENTIAL-SAVE-CHECKPOINT ${JSON.stringify({
      phase,
      errorClass,
      ...snapshot,
    })}`);
    stage = `${phase} failed (${errorClass})`;
  };
  stage = 'locate Save encrypted credential button';
  let saveButton;
  try {
    saveButton = await visibleButton(page, 'Save encrypted credential');
  } catch (error) {
    await logSafeFailure('locate Save encrypted credential button', error);
    throw error;
  }
  stage = 'click Save encrypted credential button';
  try {
    await saveButton.click();
  } catch (error) {
    await logSafeFailure('click Save encrypted credential button', error);
    throw error;
  }
  stage = 'wait for saved credential card';
  try {
    await waitForText(page, name);
  } catch (error) {
    await logSafeFailure('wait for saved credential card', error);
    throw error;
  }
}

async function chooseWorkspaceHostCredential(page, hostLabel, {
  credentialName = CREDENTIAL_NAME,
  sshUsername = SSH_USERNAME,
} = {}) {
  const fieldName = 'SSH credential override';
  const expected = `${credentialName} · ${sshUsername}`;
  stage = `open SSH credential override for Host ${hostLabel}`;
  const controls = page.getByRole('button', { name: /SSH credential override/i });
  let control;
  for (let index = await controls.count() - 1; index >= 0; index -= 1) {
    const candidate = controls.nth(index);
    if (await candidate.isVisible().catch(() => false)) {
      control = candidate;
      break;
    }
  }
  if (control) {
    await control.click();
  } else {
    const point = await page.evaluate((label) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const matches = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter((node) => visible(node) &&
          `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
            .toLowerCase().includes(label.toLowerCase()));
      const target = matches.at(-1);
      if (!target) return null;
      const rect = target.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    }, fieldName);
    if (!point) throw new Error('SSH credential override field was unavailable');
    await page.mouse.click(point.x, point.y);
  }

  stage = `locate exact encrypted credential option for Host ${hostLabel}`;
  const deadline = Date.now() + 10000;
  let optionPoint = null;
  let clickedByRole = false;
  while (!clickedByRole && !optionPoint && Date.now() < deadline) {
    // Prefer Flutter's exact accessible option. The semantics overlay can lag
    // its visual menu during rebuilds, so retry the role locator until it is
    // uniquely visible before falling back to a hit-tested point.
    for (const role of ['menuitem', 'option']) {
      const candidate = page.getByRole(role, { name: expected, exact: true });
      if (await candidate.count().catch(() => 0) !== 1 ||
          !await candidate.isVisible().catch(() => false)) continue;
      try {
        await candidate.click({ timeout: 1500 });
        clickedByRole = true;
        break;
      } catch (_) {
        // Keep polling for the overlay's stable semantics hit target below.
      }
    }
    if (clickedByRole) break;
    optionPoint = await page.evaluate((choice) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const nodes = [...document.querySelectorAll(
        'flt-semantics[role="menuitem"], flt-semantics[role="option"]',
      )].filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity || 1) > 0 &&
          normalize(`${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`)
            .includes(choice);
      });
      const candidates = nodes.map((node) => {
        const rect = node.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const inViewport = rect.left >= 0 && rect.top >= 0 &&
          rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
        const hit = inViewport ? document.elementFromPoint(x, y) : null;
        const hitVerified = Boolean(hit &&
          (hit === node || node.contains(hit) || hit.contains(node)));
        return { x, y, inViewport, hitVerified };
      }).filter((item) => item.inViewport && item.hitVerified);
      const uniquePoints = new Map(candidates.map((item) =>
        [`${Math.round(item.x)}:${Math.round(item.y)}`, item]));
      if (uniquePoints.size !== 1) return null;
      const target = [...uniquePoints.values()][0];
      return { x: target.x, y: target.y };
    }, expected).catch(() => null);
    if (!optionPoint) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!clickedByRole && !optionPoint) {
    const exactMenuItemCount = await page.getByRole('menuitem', {
      name: expected, exact: true,
    }).count().catch(() => 0);
    const exactOptionCount = await page.getByRole('option', {
      name: expected, exact: true,
    }).count().catch(() => 0);
    const visibleChoiceSemantics = await page.evaluate(({
      choice, credentialName, sshUsername,
    }) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      const normalize = (node) =>
        `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
          .replace(/\s+/g, ' ').trim();
      const nodes = [...document.querySelectorAll('flt-semantics')].filter(visible);
      const normalizedLabels = nodes.map(normalize);
      return {
        visibleMenuRoleCount: nodes.filter((node) =>
          ['menuitem', 'option'].includes(node.getAttribute('role'))).length,
        exactChoiceSemanticCount: normalizedLabels.filter((label) =>
          label === choice).length,
        credentialNameVisible: normalizedLabels.some((label) =>
          label.includes(credentialName)),
        sshUsernameVisible: normalizedLabels.some((label) =>
          label.includes(sshUsername)),
        expectedChoiceIdentifierCount: [...document.querySelectorAll(
          '[identifier], [data-semantics-identifier], [aria-label]',
        )].filter((node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            [...node.attributes].some((attribute) =>
              attribute.value.startsWith('ssh-host-credential-override-'));
        }).length,
        visibleSemanticNodeCount: nodes.length,
      };
    }, {
      choice: expected,
      credentialName,
      sshUsername,
    }).catch(() => ({ visibleMenuRoleCount: 0, exactChoiceSemanticCount: 0 }));
    stage = `${stage} (${JSON.stringify({
      exactMenuItemCount,
      exactOptionCount,
      ...visibleChoiceSemantics,
      hitTestedOptionPoint: false,
    })})`;
    throw new Error('SSH credential override option was unavailable');
  }
  if (!clickedByRole) await page.mouse.click(optionPoint.x, optionPoint.y);

  stage = `verify encrypted credential selection for Host ${hostLabel}`;
  const selectionDeadline = Date.now() + 3000;
  let selected = false;
  let selectionSnapshot = null;
  while (!selected && Date.now() < selectionDeadline) {
    selectionSnapshot = await page.evaluate(({ field, choice }) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity || 1) > 0;
      };
      const normalize = (node) =>
        `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
          .replace(/\s+/g, ' ').trim();
      const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
      const fieldButtons = semantics.filter((node) =>
        node.getAttribute('role') === 'button' &&
        normalize(node).toLowerCase().includes(field.toLowerCase()));
      const choices = semantics.filter((node) =>
        !['menuitem', 'option'].includes(node.getAttribute('role')) &&
        normalize(node).includes(choice));
      const sameControlMatch = fieldButtons.some((node) => normalize(node).includes(choice));
      const overlapsField = fieldButtons.some((button) => {
        const buttonRect = button.getBoundingClientRect();
        return choices.some((choiceNode) => {
          if (button.contains(choiceNode) || choiceNode.contains(button)) return true;
          const choiceRect = choiceNode.getBoundingClientRect();
          return choiceRect.left < buttonRect.right &&
            choiceRect.right > buttonRect.left &&
            choiceRect.top < buttonRect.bottom &&
            choiceRect.bottom > buttonRect.top;
        });
      });
      const openChoiceCount = semantics.filter((node) =>
        ['menuitem', 'option'].includes(node.getAttribute('role')) &&
        normalize(node).includes(choice)).length;
      return {
        selected: sameControlMatch || overlapsField,
        fieldControlCount: fieldButtons.length,
        selectedLabelCount: choices.length,
        sameControlMatch,
        overlapsField,
        openChoiceCount,
      };
    }, { field: fieldName, choice: expected }).catch(() => ({
      selected: false,
      fieldControlCount: 0,
      selectedLabelCount: 0,
      sameControlMatch: false,
      overlapsField: false,
      openChoiceCount: 0,
    }));
    selected = selectionSnapshot.selected;
    if (!selected) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!selected && selectionSnapshot?.openChoiceCount > 0) {
    // Retry once only while the exact option is still open. A closed menu with
    // no selected value in Flutter semantics is resolved by the persisted
    // Host reference check after Save below.
    const openMenuItem = page.getByRole('menuitem', { name: expected, exact: true });
    const openOption = page.getByRole('option', { name: expected, exact: true });
    let retried = false;
    for (const candidate of [openMenuItem, openOption]) {
      if (await candidate.count().catch(() => 0) !== 1 ||
          !await candidate.isVisible().catch(() => false)) continue;
      try {
        await candidate.click({ timeout: 5000 });
        retried = true;
      } catch (_) {
        if (optionPoint) {
          await page.mouse.click(optionPoint.x, optionPoint.y);
          retried = true;
        }
      }
      break;
    }
    if (!retried && optionPoint) {
      await page.mouse.click(optionPoint.x, optionPoint.y);
      retried = true;
    }
    if (retried) {
      const retryDeadline = Date.now() + 3000;
      while (!selected && Date.now() < retryDeadline) {
        selectionSnapshot = await page.evaluate(({ field, choice }) => {
          const visible = (node) => {
            const rect = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
              style.visibility !== 'hidden' && Number(style.opacity || 1) > 0;
          };
          const normalize = (node) =>
            `${node.getAttribute('aria-label') || ''} ${node.innerText || ''} ${node.textContent || ''}`
              .replace(/\s+/g, ' ').trim();
          const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
          const fieldButtons = semantics.filter((node) =>
            node.getAttribute('role') === 'button' &&
            normalize(node).toLowerCase().includes(field.toLowerCase()));
          const choices = semantics.filter((node) =>
            !['menuitem', 'option'].includes(node.getAttribute('role')) &&
            normalize(node).includes(choice));
          const sameControlMatch = fieldButtons.some((node) => normalize(node).includes(choice));
          const overlapsField = fieldButtons.some((button) => {
            const buttonRect = button.getBoundingClientRect();
            return choices.some((choiceNode) => {
              if (button.contains(choiceNode) || choiceNode.contains(button)) return true;
              const choiceRect = choiceNode.getBoundingClientRect();
              return choiceRect.left < buttonRect.right &&
                choiceRect.right > buttonRect.left &&
                choiceRect.top < buttonRect.bottom &&
                choiceRect.bottom > buttonRect.top;
            });
          });
          const openChoiceCount = semantics.filter((node) =>
            ['menuitem', 'option'].includes(node.getAttribute('role')) &&
            normalize(node).includes(choice)).length;
          return {
            selected: sameControlMatch || overlapsField,
            fieldControlCount: fieldButtons.length,
            selectedLabelCount: choices.length,
            sameControlMatch,
            overlapsField,
            openChoiceCount,
          };
        }, { field: fieldName, choice: expected }).catch(() => null);
        selected = selectionSnapshot?.selected === true;
        if (!selected) await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
  }
  if (!selected && selectionSnapshot?.openChoiceCount > 0) {
    stage = `${stage} (${JSON.stringify({
      fieldControlCount: selectionSnapshot?.fieldControlCount ?? 0,
      selectedLabelCount: selectionSnapshot?.selectedLabelCount ?? 0,
      sameControlMatch: selectionSnapshot?.sameControlMatch ?? false,
      overlapsField: selectionSnapshot?.overlapsField ?? false,
      openChoiceCount: selectionSnapshot?.openChoiceCount ?? 0,
    })})`;
    throw new Error('SSH credential override option remained open after selection');
  }
}

async function addHost(page, name, address, {
  attachCredential = true,
  port = 22,
  sshUsername = SSH_USERNAME,
  credentialName = CREDENTIAL_NAME,
} = {}) {
  const hostLabel = name === HOST_A_NAME ? 'A'
    : name === HOST_B_NAME ? 'B'
    : name === HOST_C_NAME ? 'C'
    : name === HOST_D_NAME ? 'D'
      : name === HOST_TMUX_NAME ? 'tmux'
        : 'split';
  stage = `navigate to Hosts for Host ${hostLabel}`;
  await click(page, 'Hosts');
  await waitForText(page, 'Your server fleet');
  stage = `open Host form ${hostLabel}`;
  await click(page, 'Add host');
  stage = `wait for Host form ${hostLabel}`;
  await waitForText(page, 'Add a host');
  stage = `fill Host name ${hostLabel}`;
  await fill(page, 'Display name', name);
  stage = `fill Host address ${hostLabel}`;
  await fill(page, 'Hostname or IP', address);
  stage = `fill Host port ${hostLabel}`;
  await fill(page, 'Port', String(port));
  stage = `fill Host username ${hostLabel}`;
  await fill(page, 'SSH username', sshUsername);
  if (attachCredential) {
    await chooseWorkspaceHostCredential(page, hostLabel, {
      credentialName,
      sshUsername,
    });
  }
  stage = `save Host ${hostLabel}`;
  await click(page, 'Save encrypted host');
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const savedHost = page.getByRole('group', {
    name: new RegExp(`^Host: ${escapedName}; `),
  }).first();
  await savedHost.waitFor({ state: 'visible', timeout: 15000 });
  if (attachCredential) {
    stage = `verify saved Host credential reference for Host ${hostLabel}`;
    await savedHost.getByRole('button', { name: 'Edit host', exact: true }).click();
    await waitForText(page, 'Edit host');
    const expectedReference = `Host override: ${credentialName} · ${sshUsername}`;
    const referenceDeadline = Date.now() + 10000;
    let resolvedReference = false;
    let unavailableReference = false;
    while (!resolvedReference && !unavailableReference && Date.now() < referenceDeadline) {
      resolvedReference = await visibleSemanticTextMatch(page, expectedReference);
      unavailableReference = await visibleSemanticTextMatch(
        page, 'Host override is unavailable.',
      );
      if (!resolvedReference && !unavailableReference) await page.waitForTimeout(100);
    }
    if (!resolvedReference) {
      stage = `saved Host credential reference unresolved for Host ${hostLabel} (${JSON.stringify({
        resolvedReferenceVisible: false,
        unavailableReferenceVisible: unavailableReference,
      })})`;
      throw new Error('saved Host did not resolve to the selected encrypted Credential');
    }
    await click(page, 'Cancel');
  }
}

async function editHostTarget(page, name, address, port, {
  originalAddress = HOST_A_ADDRESS,
  originalPort = 22,
  attachCredential = false,
} = {}) {
  stage = `open saved Host editor for ${name}`;
  const card = page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)}; `),
  }).first();
  await card.waitFor({ state: 'visible', timeout: 15000 });
  const currentLabel = await card.getAttribute('aria-label');
  assertThat(currentLabel?.includes(`${SSH_USERNAME}@${originalAddress}:${originalPort}`),
    `Host ${name} did not resolve to the expected original synced target`);
  await card.getByRole('button', { name: 'Edit host', exact: true }).click();
  await waitForText(page, 'Edit host');

  stage = `update exact isolated SSH target for ${name}`;
  await fill(page, 'Hostname or IP', address);
  await fill(page, 'Port', String(port));
  if (attachCredential) {
    const hostLabel = name === HOST_C_NAME ? 'C'
      : name === HOST_D_NAME ? 'D'
        : name === HOST_B_NAME ? 'B' : 'A';
    await chooseWorkspaceHostCredential(page, hostLabel);
  }
  await click(page, 'Save encrypted host');

  stage = `verify saved isolated SSH target for ${name}`;
  const updatedCard = page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)}; `),
  }).first();
  const originalEndpoint = `${SSH_USERNAME}@${originalAddress}:${originalPort}`;
  const expectedEndpoint = `${SSH_USERNAME}@${address}:${port}`;
  const deadline = Date.now() + 15000;
  let label = null;
  while (Date.now() < deadline) {
    if (await updatedCard.isVisible().catch(() => false)) {
      label = await updatedCard.getAttribute('aria-label').catch(() => null);
      if (label?.includes(expectedEndpoint)) break;
    }
    await page.waitForTimeout(100);
  }
  const exactTargetVisible = label?.includes(expectedEndpoint) === true;
  if (!exactTargetVisible) {
    const saveButtons = page.getByRole('button', {
      name: 'Save encrypted host', exact: true,
    });
    const diagnostic = {
      hostCardCount: await page.getByRole('group', {
        name: new RegExp(`^Host: ${escapeRegExp(name)}; `),
      }).count().catch(() => 0),
      oldEndpointPresent: label?.includes(originalEndpoint) === true,
      newEndpointPresent: false,
      hostEditorVisible: await page.getByText('Edit host', { exact: true })
        .first().isVisible().catch(() => false),
      saveButtonVisible: await saveButtons.first().isVisible().catch(() => false),
    };
    console.log('WEB-WORKSPACE-HOST-TARGET-UPDATE-DIAGNOSTIC', JSON.stringify(diagnostic));
  }
  assertThat(exactTargetVisible,
    `Host ${name} did not render the exact isolated target address and port after save`);
  if (attachCredential) {
    stage = `verify encrypted credential reference for Host ${name === HOST_C_NAME ? 'C' : 'target'}`;
    await updatedCard.getByRole('button', { name: 'Edit host', exact: true }).click();
    await waitForText(page, 'Edit host');
    const expectedReference = `Host override: ${CREDENTIAL_NAME} · ${SSH_USERNAME}`;
    const referenceDeadline = Date.now() + 10000;
    let resolvedReference = false;
    let unavailableReference = false;
    while (!resolvedReference && !unavailableReference &&
        Date.now() < referenceDeadline) {
      resolvedReference = await visibleSemanticTextMatch(page, expectedReference);
      unavailableReference = await visibleSemanticTextMatch(
        page, 'Host override is unavailable.',
      );
      if (!resolvedReference && !unavailableReference) {
        await page.waitForTimeout(100);
      }
    }
    await click(page, 'Cancel');
    assertThat(resolvedReference && !unavailableReference,
      `Host ${name} did not resolve to the selected encrypted Credential`);
  }
}

async function openHostTab(page, name) {
  const hostLabel = name === HOST_A_NAME ? 'A'
    : name === HOST_B_NAME ? 'B'
      : name === HOST_TMUX_NAME ? 'tmux' : 'other';
  stage = `locate Host ${hostLabel} card for a disconnected terminal tab`;
  const card = page.getByRole('group', {
    name: new RegExp(`^Host: ${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}; `),
  }).first();
  await card.waitFor({ state: 'visible', timeout: 15000 });
  stage = `open disconnected terminal tab for Host ${hostLabel}`;
  await card.getByRole('button', { name: 'Connect', exact: true }).click();
  stage = `wait for disconnected terminal surface for Host ${hostLabel}`;
  await waitForText(page, 'SSH terminal · disconnected', 20000);
  stage = `wait for Host ${hostLabel} terminal tab semantics`;
  const terminalTab = page.getByRole('button', {
    name: new RegExp(`^${escapeRegExp(name)} terminal tab,`),
  });
  try {
    await terminalTab.waitFor({ state: 'visible', timeout: 10000 });
  } catch (_) {
    const [locatorCount, locatorVisible, snapshot] = await Promise.all([
      terminalTab.count().catch(() => 0),
      terminalTab.first().isVisible().catch(() => false),
      workspaceTerminalTabDiagnosticSnapshot(page, name),
    ]);
    stage = `Host ${hostLabel} terminal tab missing (${JSON.stringify({
      roleLocatorCount: locatorCount,
      roleLocatorVisible: locatorVisible,
      terminalTitleVisible: snapshot.terminalTitleVisible ?? false,
      hostsHeadingVisible: snapshot.hostsHeadingVisible ?? false,
      disconnectedTerminalSurfaceVisible:
        snapshot.disconnectedTerminalSurfaceVisible ?? false,
      visibleTerminalTabCount: snapshot.visibleTerminalTabCount ?? 0,
      expectedHostTabMatchCount: snapshot.expectedHostTabMatchCount ?? 0,
      expectedHostTabDisconnectedCount:
        snapshot.expectedHostTabDisconnectedCount ?? 0,
      expectedHostTabActiveCount: snapshot.expectedHostTabActiveCount ?? 0,
      matchingRuntimeCount: snapshot.matchingRuntimeCount ?? 0,
      pageEvaluationAvailable: snapshot.diagnosticsUnavailable !== true,
    })})`;
    throw new Error('Open Host did not produce a visible terminal tab');
  }
}

async function closeOtherTerminalTabs(page, keepHostName) {
  stage = `Profile A isolate the one-pane tmux Workspace tab`;
  const deadline = Date.now() + 10000;
  let closeButtonClickCount = 0;
  let savedPreviewCloseClickCount = 0;
  const fixtureHostKinds = [
    ['A', HOST_A_NAME], ['B', HOST_B_NAME], ['C', HOST_C_NAME],
    ['D', HOST_D_NAME], ['split', HOST_SPLIT_NAME], ['tmux', HOST_TMUX_NAME],
  ];
  const fixtureHostKindForName = (name) =>
    fixtureHostKinds.find(([, hostName]) => hostName === name)?.[0] || 'unknown';
  const closeControlSemanticsSnapshot = async (expectedHostName) =>
    page.evaluate(({ expected, knownHosts }) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none';
      };
      const kindForName = (name) => knownHosts.find(([, hostName]) =>
        hostName === name)?.[0] || (name === 'terminal' ? 'terminal' : 'unknown');
      const closeNodes = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .map((node) => {
          const ariaLabel = node.getAttribute('aria-label') || '';
          const innerText = (node.innerText || '').trim();
          const textContent = (node.textContent || '').trim();
          const semanticName = ariaLabel || innerText || textContent;
          if (!/^Close .+$/.test(semanticName) ||
              semanticName === 'Close saved layout preview' ||
              semanticName === 'Close terminal search') return null;
          let ariaHiddenAncestor = false;
          let inertAncestor = false;
          for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
            if ((ancestor.getAttribute('aria-hidden') || '').toLowerCase() === 'true') {
              ariaHiddenAncestor = true;
            }
            if (ancestor.hasAttribute('inert')) inertAncestor = true;
          }
          const namedHost = semanticName.slice('Close '.length);
          const rect = node.getBoundingClientRect();
          return {
            semanticRole: node.getAttribute('role') || 'unlabeled',
            semanticNameHostKind: kindForName(namedHost),
            ariaLabelPresent: ariaLabel.length > 0,
            ariaLabelMatchesCandidate: ariaLabel === expected,
            innerTextMatchesCandidate: innerText === expected,
            textContentMatchesCandidate: textContent === expected,
            semanticNameMatchesCandidate: semanticName === expected,
            ariaHiddenAncestor,
            inertAncestor,
            visible: visible(node),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          };
        })
        .filter((node) => node !== null);
      return {
        candidateHostKind: kindForName(expected.slice('Close '.length)),
        closeSemanticNodeCount: closeNodes.length,
        candidateAccessibleNameMatchCount:
          closeNodes.filter((node) => node.semanticNameMatchesCandidate).length,
        candidateAriaLabelMatchCount:
          closeNodes.filter((node) => node.ariaLabelMatchesCandidate).length,
        candidateInnerTextMatchCount:
          closeNodes.filter((node) => node.innerTextMatchesCandidate).length,
        closeNodes,
      };
    }, {
      expected: `Close ${expectedHostName}`,
      knownHosts: fixtureHostKinds,
    }).catch(() => ({ snapshotAvailable: false }));
  const terminalTabSnapshot = async () => page.evaluate((knownHosts) => {
    const visible = (node) => {
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
        style.display !== 'none';
    };
    const tabs = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
      .map((label) => {
        const match = label.match(/^(.+?) terminal tab, (connected|disconnected|connecting|failed), (active|inactive)$/i);
        return match ? { name: match[1], state: match[2].toLowerCase(), active: match[3] === 'active' } : null;
      })
      .filter((tab) => tab !== null);
    const closeTabControlLabels = [...document.querySelectorAll(
      'flt-semantics[role="button"]',
    )]
      .filter(visible)
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
      .filter((label) => /^Close .+$/.test(label) &&
        label !== 'Close saved layout preview' &&
        label !== 'Close terminal search');
    const body = document.body?.innerText || '';
    return {
      tabs,
      closeTabControlLabels,
      fixtureHostKindCounts: Object.fromEntries([
        ...knownHosts.map(([kind, name]) => [kind,
          tabs.filter((tab) => tab.name === name).length]),
        ['unknown', tabs.filter((tab) =>
          !knownHosts.some(([, name]) => name === tab.name)).length],
      ]),
      terminalTitleVisible: body.includes('Terminal workspace'),
      hostsHeadingVisible: body.includes('Your server fleet'),
      workspacesHeadingVisible: body.includes('Saved workspaces'),
      disconnectedTerminalSurfaceVisible: body.includes('SSH terminal · disconnected'),
    };
  }, fixtureHostKinds).catch(() => ({
    tabs: [], closeTabControlLabels: [], fixtureHostKindCounts: {},
    terminalTitleVisible: false, hostsHeadingVisible: false,
    workspacesHeadingVisible: false, disconnectedTerminalSurfaceVisible: false,
  }));
  const safeTabCounts = (snapshot, runtimeCount, otherHostName = null) => ({
    visibleTerminalTabSemanticsCount: snapshot.tabs.length,
    fixtureHostKindCounts: snapshot.fixtureHostKindCounts || {},
    fixtureHostCloseControlCounts: Object.fromEntries([
      ...fixtureHostKinds.map(([kind, hostName]) => [kind,
        (snapshot.closeTabControlLabels || []).filter((label) =>
          label === `Close ${hostName}`).length]),
      ['terminal', (snapshot.closeTabControlLabels || [])
        .filter((label) => label === 'Close terminal').length],
    ]),
    otherHostKind: otherHostName === null
      ? null : fixtureHostKindForName(otherHostName),
    keepTabMatchCount: snapshot.tabs.filter((tab) => tab.name === keepHostName).length,
    keepTabConnectedCount: snapshot.tabs.filter((tab) =>
      tab.name === keepHostName && tab.state === 'connected').length,
    keepTabDisconnectedCount: snapshot.tabs.filter((tab) =>
      tab.name === keepHostName && tab.state === 'disconnected').length,
    keepTabConnectingCount: snapshot.tabs.filter((tab) =>
      tab.name === keepHostName && tab.state === 'connecting').length,
    otherTerminalTabCount: snapshot.tabs.filter((tab) => tab.name !== keepHostName).length,
    terminalTitleVisible: snapshot.terminalTitleVisible,
    hostsHeadingVisible: snapshot.hostsHeadingVisible,
    workspacesHeadingVisible: snapshot.workspacesHeadingVisible,
    disconnectedTerminalSurfaceVisible: snapshot.disconnectedTerminalSurfaceVisible,
    closeButtonClickCount,
    savedPreviewCloseClickCount,
    runtimeCount,
  });

  const savedPreviewClose = page.getByRole('button', {
    name: 'Close saved layout preview', exact: true,
  });
  if (await savedPreviewClose.count().catch(() => 0) > 0 &&
      await savedPreviewClose.first().isVisible().catch(() => false)) {
    try {
      await savedPreviewClose.first().click({ timeout: 5000 });
      savedPreviewCloseClickCount += 1;
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      const snapshot = await terminalTabSnapshot();
      const runtimes = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
      const diagnostics = safeTabCounts(snapshot, runtimes[0]?.count ?? 0);
      console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
        isolated: false,
        phase: 'close-saved-preview',
        errorClass,
        ...diagnostics,
      }));
      stage = `Profile A isolate the one-pane tmux Workspace tab failed (${JSON.stringify({
        phase: 'close-saved-preview', errorClass, ...diagnostics,
      })})`;
      throw new Error('could not close the saved preview before tmux Workspace creation');
    }
  }

  const initialSnapshot = await terminalTabSnapshot();
  const initialKeepTabMatchCount = initialSnapshot.tabs.filter((tab) =>
    tab.name === keepHostName).length;
  const initialRuntime = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
  const initialDiagnostics = safeTabCounts(initialSnapshot, initialRuntime[0]?.count ?? 0);
  console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
    phase: 'before-closing-other-tabs',
    isolated: null,
    ...initialDiagnostics,
  }));
  if (!initialSnapshot.terminalTitleVisible || initialKeepTabMatchCount !== 1) {
    stage = `Profile A tmux terminal tab unavailable before isolation (${JSON.stringify(initialDiagnostics)})`;
    throw new Error('the tmux Host tab was not uniquely visible before isolation');
  }

  while (Date.now() < deadline) {
    const snapshot = await terminalTabSnapshot();
    const other = snapshot.tabs.find((tab) => tab.name !== keepHostName)?.name;
    const keepTabMatchCount = snapshot.tabs.filter((tab) =>
      tab.name === keepHostName).length;
    if (!other && keepTabMatchCount === 1) {
      const runtimes = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
      if (runtimes[0]?.count !== 1 || !snapshot.terminalTitleVisible) {
        const diagnostics = safeTabCounts(snapshot, runtimes[0]?.count ?? 0);
        console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
          isolated: false,
          ...diagnostics,
        }));
        stage = `Profile A isolate the one-pane tmux Workspace tab failed (${JSON.stringify({
          ...diagnostics,
        })})`;
        throw new Error('the tmux Host tab did not remain as the sole terminal tab');
      }
      console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
        isolated: true,
        ...safeTabCounts(snapshot, 1),
      }));
      return;
    }

    if (!other) {
      if (!snapshot.terminalTitleVisible) {
        const runtimes = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
        const diagnostics = safeTabCounts(snapshot, runtimes[0]?.count ?? 0);
        stage = `Profile A Terminal page missing during tmux tab isolation (${JSON.stringify(diagnostics)})`;
        throw new Error('Terminal navigation changed during tab isolation');
      }
      await page.waitForTimeout(100);
      continue;
    }
    const button = page.getByRole('button', { name: `Close ${other}`, exact: true });
    const roleCloseButtonCount = await button.count().catch(() => 0);
    const ariaLabelCloseButton = page.locator(
      `flt-semantics[role="button"][aria-label=${JSON.stringify(`Close ${other}`)}]`,
    );
    const ariaLabelCloseButtonCount = await ariaLabelCloseButton.count()
      .catch(() => 0);
    const exactCloseNamePattern = new RegExp(
      `^${escapeRegExp(`Close ${other}`)}$`,
    );
    const innerTextCloseButton = page.locator('flt-semantics[role="button"]')
      .filter({ hasText: exactCloseNamePattern });
    const innerTextCloseButtonCount = await innerTextCloseButton.count()
      .catch(() => 0);
    const [workspaceDiagnostics, iterationRuntime, semanticCloseDiagnostics] = await Promise.all([
      workspaceTerminalTabDiagnosticSnapshot(page, keepHostName)
        .catch(() => ({ snapshotAvailable: false })),
      workspaceTerminalRuntimeSnapshot(page, [keepHostName])
        .catch(() => [{ count: 0 }]),
      closeControlSemanticsSnapshot(other),
    ]);
    const exactCloseButtonCount = roleCloseButtonCount > 0
      ? roleCloseButtonCount : ariaLabelCloseButtonCount > 0
        ? ariaLabelCloseButtonCount : innerTextCloseButtonCount;
    const iterationDiagnostics = {
      iteration: closeButtonClickCount + 1,
      expectedHostTabMatchCount: keepTabMatchCount,
      otherHostTabCount: snapshot.tabs.filter((tab) =>
        tab.name !== keepHostName).length,
      otherHostIsKnownFixtureHost: [
        HOST_A_NAME, HOST_B_NAME, HOST_C_NAME, HOST_D_NAME,
        HOST_SPLIT_NAME, HOST_TMUX_NAME,
      ].includes(other),
      exactCloseButtonCount,
      roleCloseButtonCount,
      ariaLabelCloseButtonCount,
      innerTextCloseButtonCount,
      ...safeTabCounts(snapshot, iterationRuntime[0]?.count ?? 0, other),
      workspaceTerminalDiagnostics: workspaceDiagnostics,
      semanticCloseDiagnostics,
    };
    console.log('WEB-WORKSPACE-TMUX-TAB-CLOSE-ATTEMPT-CHECKPOINT',
      JSON.stringify(iterationDiagnostics));
    if (exactCloseButtonCount === 0) {
      stage = `Profile A exact close control unavailable during tmux tab isolation (${JSON.stringify({
        iteration: iterationDiagnostics.iteration,
        expectedHostTabMatchCount: iterationDiagnostics.expectedHostTabMatchCount,
        otherHostTabCount: iterationDiagnostics.otherHostTabCount,
        otherHostIsKnownFixtureHost:
          iterationDiagnostics.otherHostIsKnownFixtureHost,
        exactCloseButtonCount,
        roleCloseButtonCount,
        ariaLabelCloseButtonCount,
        innerTextCloseButtonCount,
        visibleTerminalTabSemanticsCount:
          workspaceDiagnostics.visibleTerminalTabCount ?? null,
        closeTabActionCount: workspaceDiagnostics.closeTabActionCount ?? null,
        expectedHostTabConnectedCount:
          workspaceDiagnostics.expectedHostTabConnectedCount ?? null,
        matchingRuntimeCount: workspaceDiagnostics.matchingRuntimeCount ?? null,
        candidateAccessibleNameMatchCount:
          semanticCloseDiagnostics.candidateAccessibleNameMatchCount ?? null,
        candidateAriaLabelMatchCount:
          semanticCloseDiagnostics.candidateAriaLabelMatchCount ?? null,
        candidateInnerTextMatchCount:
          semanticCloseDiagnostics.candidateInnerTextMatchCount ?? null,
      })})`;
      throw new Error('the remaining terminal tab had no exact Close control');
    }
    try {
      if (roleCloseButtonCount > 0) {
        await button.first().click({ timeout: 5000 });
      } else if (ariaLabelCloseButtonCount > 0) {
        assertThat(ariaLabelCloseButtonCount === 1 &&
          await ariaLabelCloseButton.first().isVisible().catch(() => false),
        'the DOM close control fallback was not a unique visible semantic button');
        await ariaLabelCloseButton.first().click({ timeout: 5000 });
      } else {
        const exactVisibleInnerTextNodes =
          (semanticCloseDiagnostics.closeNodes || []).filter((node) =>
            node.semanticRole === 'button' && node.semanticNameMatchesCandidate &&
            node.visible && node.width > 0 && node.height > 0 &&
            !node.ariaHiddenAncestor && !node.inertAncestor);
        assertThat(innerTextCloseButtonCount === 1 &&
          await innerTextCloseButton.first().isVisible().catch(() => false) &&
          exactVisibleInnerTextNodes.length === 1,
        'the DOM innerText close fallback was not a unique visible semantic button');
        await innerTextCloseButton.first().click({ timeout: 5000 });
      }
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      const latestSnapshot = await terminalTabSnapshot();
      const runtimes = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
      const closeFailureSemantics = await closeControlSemanticsSnapshot(other);
      const diagnostics = safeTabCounts(latestSnapshot, runtimes[0]?.count ?? 0);
      console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
        isolated: false,
        phase: 'close-action-failed',
        errorClass,
        roleCloseButtonCount,
        ariaLabelCloseButtonCount,
        closeFailureSemantics,
        ...diagnostics,
      }));
      stage = `Profile A isolate the one-pane tmux Workspace tab action failed (${errorClass}; ${JSON.stringify({
        roleCloseButtonCount,
        ariaLabelCloseButtonCount,
        closeFailureSemantics,
        ...diagnostics,
      })})`;
      throw new Error('could not close a non-tmux terminal tab');
    }
    closeButtonClickCount += 1;
    if (other === 'Close saved layout preview') savedPreviewCloseClickCount += 1;
    await page.waitForTimeout(80);
    const afterCloseSnapshot = await terminalTabSnapshot();
    const afterCloseKeepTabMatchCount = afterCloseSnapshot.tabs.filter((tab) =>
      tab.name === keepHostName).length;
    const afterCloseOtherTabCount = afterCloseSnapshot.tabs.filter((tab) =>
      tab.name !== keepHostName).length;
    const expectedOtherTabCountAfterClick = iterationDiagnostics.otherHostTabCount - 1;
    if (!afterCloseSnapshot.terminalTitleVisible ||
        afterCloseKeepTabMatchCount !== 1 ||
        afterCloseOtherTabCount !== expectedOtherTabCountAfterClick) {
      const runtimes = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
      const diagnostics = safeTabCounts(
        afterCloseSnapshot,
        runtimes[0]?.count ?? 0,
      );
      console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
        phase: 'after-closing-one-other-tab',
        isolated: false,
        expectedOtherTabCountAfterClick,
        afterCloseOtherTabCount,
        ...diagnostics,
      }));
      stage = `Profile A closing an unrelated tab removed the tmux tab (${JSON.stringify(diagnostics)})`;
      throw new Error('closing another terminal tab removed or hid the tmux Host tab');
    }
  }
  const terminalRuntime = await workspaceTerminalRuntimeSnapshot(page, [keepHostName]);
  const snapshot = await terminalTabSnapshot();
  const diagnostics = safeTabCounts(snapshot, terminalRuntime[0]?.count ?? 0);
  console.log('WEB-WORKSPACE-TMUX-TAB-ISOLATION-CHECKPOINT', JSON.stringify({
    isolated: false,
    ...diagnostics,
  }));
  stage = `Profile A isolate the one-pane tmux Workspace tab timed out (${JSON.stringify({
    ...diagnostics,
  })})`;
  throw new Error('could not isolate the tmux Host terminal tab');
}

async function replaceFirstMissingWorkspacePane(page, hostName, profile) {
  stage = `Profile ${profile} open first missing Workspace pane replacement`;
  const replaceButtons = page.getByRole('button', { name: 'Replace Host', exact: true });
  assertThat(await replaceButtons.count() === 2,
    `Profile ${profile} did not have two missing Workspace panes`);
  await replaceButtons.first().click();
  await waitForText(page, 'Choose a Host from the active Vault.');
  stage = `Profile ${profile} select distinct replacement Host`;
  const hostChoicePoint = await page.evaluate((name) => {
    const candidates = [...document.querySelectorAll('flt-semantics')]
      .map((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        const label = (node.getAttribute('aria-label') || node.innerText || '').replace(/\s+/g, ' ').trim();
        return { node, rect, style, label };
      })
      .filter(({ rect, style, label }) => rect.width > 0 && rect.height > 0 &&
        style.visibility !== 'hidden' && style.display !== 'none' &&
        (label === name || label.startsWith(`${name} `) || label.startsWith(`${name}\n`)))
      .sort((left, right) =>
        left.rect.width * left.rect.height - right.rect.width * right.rect.height);
    const match = candidates[0];
    const target = match?.node;
    if (!target) return null;
    return {
      x: match.rect.left + match.rect.width / 2,
      y: match.rect.top + match.rect.height / 2,
      label: match.label,
      role: target.getAttribute('role'),
    };
  }, hostName).catch(() => null);
  assertThat(hostChoicePoint,
    `Profile ${profile} replacement Host was absent from visible Flutter semantics`);
  await page.mouse.click(hostChoicePoint.x, hostChoicePoint.y);
  stage = `Profile ${profile} wait for replacement pane update`;
  const deadline = Date.now() + 10000;
  let remainingMissingPanes = 2;
  while (Date.now() < deadline && remainingMissingPanes !== 1) {
    remainingMissingPanes = await replaceButtons.count();
    if (remainingMissingPanes !== 1) await page.waitForTimeout(100);
  }
  if (remainingMissingPanes !== 1) {
    const paneLabels = await page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
      .filter((node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      })
      .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim())
      .filter((label) => label.includes('Tab 1') || label.includes('Missing Host') ||
        label.includes(hostName))).catch(() => []);
    stage = `Profile ${profile} replacement Host selection did not update pane (remainingMissing=${remainingMissingPanes}; clicked=${JSON.stringify({ label: hostChoicePoint.label, role: hostChoicePoint.role })}; paneLabels=${JSON.stringify(paneLabels)})`;
    throw new Error('Workspace pane did not accept replacement Host');
  }
}

async function previewNamedWorkspace(page, workspaceName, expectedFirstHost, profile) {
  const orderedNames = [WORKSPACE_NAME, WORKSPACE_BRANCH_B_COPY_NAME]
    .sort((left, right) => left.toLowerCase().localeCompare(right.toLowerCase()));
  const index = orderedNames.indexOf(workspaceName);
  stage = `Profile ${profile} locate both decrypted Workspace previews`;
  assertThat(index >= 0, 'Workspace preview was not in the expected sorted name set');
  const previews = page.getByRole('button', {
    name: 'Preview disconnected layout', exact: true,
  });
  const previewDeadline = Date.now() + 10000;
  let previewCount = 0;
  while (Date.now() < previewDeadline && previewCount !== 2) {
    previewCount = await previews.count();
    if (previewCount !== 2) await page.waitForTimeout(100);
  }
  if (previewCount !== 2) {
    const flags = await workspaceUiFlags(page);
    const surface = await page.evaluate(() => {
      const body = document.body?.innerText || '';
      return {
        emptyWorkspaceState: body.includes('No saved workspaces'),
        workspaceListTitle: body.includes('Saved workspaces'),
        workspacePageSubtitle: body.includes('加密同步有序终端标签和 Host 引用'),
        hostFleetPage: body.includes('Your server fleet'),
        conflictInboxPage: body.includes('跨设备冲突收件箱'),
      };
    }).catch(() => ({ pageUnavailable: true }));
    stage = `Profile ${profile} locate both decrypted Workspace previews (${previewCount} actions; ${JSON.stringify({ flags, surface })})`;
  } else {
    stage = `Profile ${profile} locate both decrypted Workspace previews (${previewCount} actions)`;
  }
  assertThat(previewCount === 2,
    'both original and copied Workspace cards were not visible');
  stage = `Profile ${profile} open the expected saved Workspace preview`;
  await previews.nth(index).click();
  stage = `Profile ${profile} wait for the decrypted Workspace preview title`;
  await waitForText(page, workspaceName);
  stage = `Profile ${profile} wait for the expected first Host pane`;
  await page.getByRole('button', {
    name: `Tab 1 · ${expectedFirstHost}`,
    exact: true,
  }).waitFor({ state: 'visible', timeout: 10000 });
  stage = `Profile ${profile} wait for the missing second Host pane`;
  const missingSecondPane = page.getByRole('button', {
    name: 'Tab 2 · Missing Host', exact: true,
  });
  await missingSecondPane.waitFor({ state: 'visible', timeout: 10000 });
  stage = `Profile ${profile} verify missing Host pane is disabled`;
  assertThat(await missingSecondPane.isDisabled(),
    'a missing second Workspace pane exposed an enabled Connect action');
  const closePreview = page.getByRole('button', {
    name: 'Close saved layout preview', exact: true,
  });
  stage = `Profile ${profile} close the decrypted Workspace preview`;
  await closePreview.click();
  await click(page, 'Workspaces');
  return true;
}

function serverVaultSnapshot(databasePath) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "rows=db.execute(\"SELECT v.vault_id,COALESCE(vc.last_committed_seq,0),COALESCE(vc.last_conflict_seq,0) FROM users u JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' JOIN vaults v ON v.vault_id=vm.vault_id LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE u.username=? AND v.state='active' ORDER BY v.vault_id\",(sys.argv[2],)).fetchall()",
    "print(json.dumps({'vaults':[{'vaultId':r[0],'commitSeq':str(r[1]),'conflictSeq':str(r[2])} for r in rows]}))",
  ].join(';'), databasePath, USERNAME], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server Vault snapshot query failed');
  return JSON.parse(result.stdout);
}

function serverCommitDelta(databasePath, vaultId, lower, upper) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "rows=db.execute('SELECT commit_seq,event_type,record_id,revision_id FROM change_events WHERE vault_id=? AND CAST(commit_seq AS INTEGER)>? AND CAST(commit_seq AS INTEGER)<=? ORDER BY commit_seq',(sys.argv[2],int(sys.argv[3]),int(sys.argv[4]))).fetchall()",
    "print(json.dumps({'eventCount':len(rows),'distinctCommitCount':len(set(row[0] for row in rows)),'events':[{'commitSeq':str(row[0]),'operation':row[1],'recordId':row[2],'revisionId':row[3]} for row in rows]}))",
  ].join(';'), databasePath, vaultId, lower, upper], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'server change-event query failed');
  return JSON.parse(result.stdout);
}

function serverWorkspaceHead(databasePath, vaultId, recordId) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=5)",
    "row=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(sys.argv[2],sys.argv[3])).fetchone()",
    "print(json.dumps({'revisionId':row[0] if row else None,'deleted':bool(row[1]) if row else None,'commitSeq':str(row[2]) if row else None}))",
  ].join(';'), databasePath, vaultId, recordId], {
    encoding: 'utf8',
    timeout: 8000,
  });
  assertThat(result.status === 0, 'Workspace record-head query failed');
  return JSON.parse(result.stdout);
}

function serverWorkspaceRecordSnapshot(databasePath, vaultId, recordId, markers) {
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,record,markers_json=sys.argv[2:]',
    'markers=json.loads(markers_json)',
    'versions=[]',
    "for revision,operation,envelope_text,seq in db.execute('SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall():",
    '    try: envelope=json.loads(envelope_text)',
    '    except Exception: envelope={}',
    "    header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
    "    valid=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and all(isinstance(envelope.get(key),str) and envelope[key] and all(char.isalnum() or char in '-_' for char in envelope[key]) for key in ('nonce','ciphertext','signature'))",
    "    versions.append({'revisionId':revision,'operation':operation,'commitSeq':str(seq),'recordId':header.get('record_id'),'headerOperation':header.get('operation'),'headerRevisionId':header.get('revision_id'),'opId':header.get('op_id'),'envelopeSha256':hashlib.sha256(json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest(),'validEnvelope':bool(valid),'markersAbsent':not any(marker in envelope_text for marker in markers)})",
    "events=[{'revisionId':r[0],'operation':r[1],'commitSeq':str(r[2])} for r in db.execute('SELECT revision_id,event_type,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()]",
    "head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    'receipts=[]',
    'for version in versions:',
    "    if not version['opId']: continue",
    "    rows=db.execute('SELECT record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,version['opId'])).fetchall()",
    "    receipts.extend([{'opId':version['opId'],'recordId':r[0],'revisionId':r[1],'commitSeq':str(r[2])} for r in rows])",
    "print(json.dumps({'versions':versions,'events':events,'headRevisionId':head[0] if head else None,'headDeleted':bool(head[1]) if head else None,'headCommitSeq':str(head[2]) if head else None,'receipts':receipts}))",
  ].join('\n'), databasePath, vaultId, recordId, JSON.stringify(markers)], {
    encoding: 'utf8',
    timeout: 12000,
  });
  assertThat(result.status === 0, 'Workspace record server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Workspace record server-state inspection returned invalid data');
  }
}

function serverWorkspaceConflictSnapshot(databasePath, vaultId, originalRecordId, copyRecordId, branch) {
  assertThat(typeof vaultId === 'string' && typeof originalRecordId === 'string' &&
    typeof copyRecordId === 'string' && typeof branch?.opId === 'string',
  'Workspace conflict snapshot is missing record or operation identity');
  const result = spawnSync('python3', ['-c', [
    'import hashlib,json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=8)",
    'vault,original,copy,branch_json=sys.argv[2:]',
    'branch=json.loads(branch_json)',
    "counter=db.execute('SELECT last_committed_seq,last_conflict_seq FROM vault_counters WHERE vault_id=?',(vault,)).fetchone()",
    "conflicts=db.execute('SELECT conflict_id,record_id,base_revision_id,envelope,device_id,op_id,resolved_revision_id,conflict_seq,resolution_seq,resolution_at FROM conflicts WHERE vault_id=? AND op_id=?',(vault,branch['opId'])).fetchall()",
    "allowed_header={'wire_version','server_space_id','vault_id','record_id','revision_id','base_revision_id','op_id','device_id','device_seq','key_epoch','membership_version','record_schema','operation','crypto_suite','kdf_salt','object_refs'}",
    'def inspect_record(record):',
    "    versions=db.execute('SELECT revision_id,operation,envelope,commit_seq FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "    events=db.execute('SELECT revision_id,event_type,commit_seq FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq',(vault,record)).fetchall()",
    "    head=db.execute('SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=? AND record_id=?',(vault,record)).fetchone()",
    '    inspected=[]',
    '    for revision,operation,envelope_text,seq in versions:',
    '        try: envelope=json.loads(envelope_text)',
    '        except Exception: envelope={}',
    "        header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
    "        fields_valid=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(envelope.get(key),str) and envelope[key] and all(char.isalnum() or char in '-_' for char in envelope[key]) for key in ('nonce','ciphertext','signature'))",
    "        inspected.append({'revisionId':revision,'operation':operation,'commitSeq':str(seq),'opId':header.get('op_id'),'headerOperation':header.get('operation'),'validEnvelope':bool(fields_valid),'markersAbsent':not any(marker in envelope_text for marker in branch['markers'])})",
    "    receipts=[]",
    "    for operation in branch['committedOperations']:",
    "        if operation['recordId'] != record: continue",
    "        rows=db.execute('SELECT record_id,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,operation['opId'])).fetchall()",
    "        receipts.append({'opId':operation['opId'],'count':len(rows),'matches':len(rows)==1 and rows[0][0]==operation['recordId'] and rows[0][1]==operation['revisionId'],'commitSeq':str(rows[0][2]) if rows else None})",
    "    return {'recordId':record,'versions':inspected,'events':[{'revisionId':r[0],'operation':r[1],'commitSeq':str(r[2])} for r in events],'headRevisionId':head[0] if head else None,'headDeleted':bool(head[1]) if head else None,'headCommitSeq':str(head[2]) if head else None,'receipts':receipts}",
    "stale_receipt_count=db.execute('SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?',(vault,branch['opId'])).fetchone()[0]",
    "stale_version_count=db.execute('SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,original,branch.get('revisionId'))).fetchone()[0]",
    "stale_event_count=db.execute('SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=? AND revision_id=?',(vault,original,branch.get('revisionId'))).fetchone()[0]",
    'conflict_summaries=[]',
    'for conflict_id,record_id,base_revision,envelope_text,device_id,op_id,resolved_revision,seq,resolution_seq,resolution_at in conflicts:',
    '    try: envelope=json.loads(envelope_text)',
    '    except Exception: envelope={}',
    "    header=envelope.get('header',{}) if isinstance(envelope,dict) else {}",
    "    shape_valid=isinstance(envelope,dict) and set(envelope)=={'header','nonce','ciphertext','signature'} and isinstance(header,dict) and set(header).issubset(allowed_header) and all(isinstance(envelope.get(key),str) and envelope[key] and all(char.isalnum() or char in '-_' for char in envelope[key]) for key in ('nonce','ciphertext','signature'))",
    "    canonical=json.dumps(envelope,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()",
    "    conflict_summaries.append({'conflictId':conflict_id,'recordId':record_id,'baseRevisionId':base_revision,'deviceId':device_id,'opId':op_id,'revisionId':header.get('revision_id'),'resolvedRevisionId':resolved_revision,'conflictSeq':str(seq),'resolutionSeq':str(resolution_seq) if resolution_seq is not None else None,'resolutionAt':resolution_at,'validEnvelope':bool(shape_valid),'envelopeSha256':hashlib.sha256(canonical).hexdigest(),'markersAbsent':not any(marker in envelope_text for marker in branch['markers'])})",
    "print(json.dumps({'commitSeq':str(counter[0]) if counter else None,'conflictSeq':str(counter[1]) if counter else None,'staleReceiptCount':stale_receipt_count,'staleVersionCount':stale_version_count,'staleEventCount':stale_event_count,'original':inspect_record(original),'copy':inspect_record(copy),'conflicts':conflict_summaries}))",
  ].join('\n'), databasePath, vaultId, originalRecordId, copyRecordId, JSON.stringify(branch)], {
    encoding: 'utf8',
    timeout: 12000,
  });
  assertThat(result.status === 0, 'Workspace conflict server-state inspection failed');
  try {
    return JSON.parse(result.stdout);
  } catch (_) {
    throw new Error('Workspace conflict server-state inspection returned invalid data');
  }
}

function serverPlaintextMarkers(databasePath) {
  const files = [databasePath, `${databasePath}-wal`, `${databasePath}-shm`];
  return PRIVACY_MARKERS.filter((marker) => files.some((file) =>
    fs.existsSync(file) && fs.readFileSync(file).includes(Buffer.from(marker))));
}

let workspaceTerminationSignal = null;

function assertWorkspaceRunnerNotInterrupted() {
  if (workspaceTerminationSignal) {
    const error = new Error(`Workspace acceptance interrupted by ${workspaceTerminationSignal}`);
    error.name = 'AbortError';
    throw error;
  }
}

async function main() {
  const runnerRevision = crypto.createHash('sha256')
    .update(fs.readFileSync(__filename)).digest('hex').slice(0, 12);
  console.log(`WEB-WORKSPACE-RUNNER revision=${runnerRevision}`);
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')) &&
    fs.existsSync(path.join(WEB_ROOT, 'main.dart.js')),
  'compiled Web release is missing; build the client first');
  runChecked('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST]);
  assertThat(fs.existsSync(SERVER_BINARY), 'server binary is unavailable');
  const splitTargetAddress = localEth0Address();
  assertThat(splitTargetAddress,
    'an isolated non-loopback eth0 IPv4 target is required for the split Relay check');
  if (TMUX_PROCESS_RESTART_ONLY) PRIVACY_MARKERS.push(splitTargetAddress);
  const splitEnvelopeMarkers = [...PRIVACY_MARKERS, splitTargetAddress];
  let splitSink = null;
  let splitSecondSink = null;
  let splitThirdSink = null;
  let sshFixture = null;
  let tmuxSshFixture = null;
  let sshFixturePorts = [];
  let nestedSshServers = [];
  let directFailureAttempt = null;
  let directPasswordProbes = [];
  let distinctSshHostKeys = false;
  let tmuxFixturePort = null;
  let tempRoot = null;
  let tmuxRestartProfileDir = null;
  let serverLog = null;
  let serverProcess = null;
  let browser = null;
  let contextA = null;
  let contextB = null;
  let bootstrapToken;
  let captureWorkspaceSave = false;
  let captureWorkspaceConflict = false;
  let captureWorkspaceSplit = false;
  let cleanupPromise = null;
  let cleanupPassNumber = 0;
  const closedContexts = new WeakSet();
  const closedBrowsers = new WeakSet();
  const waitForChildExit = (child, timeoutMs) => new Promise((resolve) => {
    if (!child || child.exitCode !== null || child.signalCode !== null) {
      resolve(true);
      return;
    }
    let settled = false;
    const finish = (exited) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeListener('exit', onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMs);
    child.once('exit', onExit);
    if (child.exitCode !== null || child.signalCode !== null) finish(true);
  });
  const cleanupPass = async (trigger) => {
    cleanupPassNumber++;
    const failures = [];
    let tmuxRestartGroupBeforeClose = null;
    if (tmuxRestartProfileDir && chromiumProfileHasLiveProcesses(tmuxRestartProfileDir)) {
      try {
        tmuxRestartGroupBeforeClose =
          chromiumProfileProcessIdentity(tmuxRestartProfileDir).processGroup;
      } catch (_) {}
    }
    const closeContext = async (context, label) => {
      if (!context || closedContexts.has(context)) return true;
      try {
        await context.close();
        closedContexts.add(context);
        return true;
      } catch (_) {
        failures.push(label);
        return false;
      }
    };
    let contextAClosed = await closeContext(contextA, 'context_a');
    const contextBClosed = await closeContext(contextB, 'context_b');
    let browserClosed = !browser || closedBrowsers.has(browser);
    if (browser && !browserClosed) {
      try {
        await browser.close();
        closedBrowsers.add(browser);
        browserClosed = true;
      } catch (_) {
        failures.push('browser');
      }
    }
    let tmuxRestartBrowserProcessStopped = true;
    let tmuxRestartProcessGroupExited = true;
    let tmuxRestartProcessGroupCheckFailed = false;
    const tmuxRestartProcessGroupExitChecks = new Map();
    const stopTmuxRestartProcessGroup = async (groupId) => {
      let exit = await waitForProcessGroupExit(groupId, 2500);
      if (!exit.exited) {
        try { process.kill(-groupId, 'SIGTERM'); } catch (_) {}
        exit = await waitForProcessGroupExit(groupId, 2500);
      }
      if (!exit.exited) {
        try { process.kill(-groupId, 'SIGKILL'); } catch (_) {}
        exit = await waitForProcessGroupExit(groupId, 2500);
      }
      tmuxRestartProcessGroupExitChecks.set(groupId, exit.exited);
      return exit.exited;
    };
    if (tmuxRestartGroupBeforeClose !== null) {
      try {
        tmuxRestartProcessGroupExited =
          await stopTmuxRestartProcessGroup(tmuxRestartGroupBeforeClose);
      } catch (_) {
        tmuxRestartProcessGroupCheckFailed = true;
        tmuxRestartProcessGroupExited = false;
      }
    }
    if (tmuxRestartProfileDir && chromiumProfileHasLiveProcesses(tmuxRestartProfileDir)) {
      try {
        const identity = chromiumProfileProcessIdentity(tmuxRestartProfileDir);
        const exitVerified = await stopTmuxRestartProcessGroup(identity.processGroup);
        tmuxRestartProcessGroupExited = [...tmuxRestartProcessGroupExitChecks.values()]
          .every(Boolean);
        tmuxRestartBrowserProcessStopped = exitVerified &&
          !chromiumProfileHasLiveProcesses(tmuxRestartProfileDir);
      } catch (_) {
        tmuxRestartBrowserProcessStopped = false;
        tmuxRestartProcessGroupExited = false;
        tmuxRestartProcessGroupCheckFailed = true;
      }
    }
    tmuxRestartProcessGroupExited =
      !tmuxRestartProcessGroupCheckFailed &&
      [...tmuxRestartProcessGroupExitChecks.values()].every(Boolean);
    tmuxRestartBrowserProcessStopped = tmuxRestartBrowserProcessStopped &&
      (!tmuxRestartProfileDir || !chromiumProfileHasLiveProcesses(tmuxRestartProfileDir));
    const tmuxRestartContextExitVerified = Boolean(TMUX_PROCESS_RESTART_ONLY &&
      tmuxRestartProfileDir && tmuxRestartProcessGroupExited &&
      !chromiumProfileHasLiveProcesses(tmuxRestartProfileDir));
    if (!contextAClosed && tmuxRestartContextExitVerified) {
      contextAClosed = true;
      if (contextA) closedContexts.add(contextA);
      const contextFailureIndex = failures.indexOf('context_a');
      if (contextFailureIndex >= 0) failures.splice(contextFailureIndex, 1);
    }
    const tmuxRestartProfileSafeToRemove = !TMUX_PROCESS_RESTART_ONLY ||
      (!tmuxRestartProfileDir || ((contextAClosed || tmuxRestartContextExitVerified) &&
        tmuxRestartBrowserProcessStopped &&
        tmuxRestartProcessGroupExited));
    if (!tmuxRestartBrowserProcessStopped || !tmuxRestartProcessGroupExited) {
      failures.push('tmux_restart_browser_process');
    }

    if (serverProcess && serverProcess.exitCode === null &&
        serverProcess.signalCode === null) {
      try { serverProcess.kill('SIGTERM'); } catch (_) {}
      if (!await waitForChildExit(serverProcess, 5000)) {
        try { serverProcess.kill('SIGKILL'); } catch (_) {}
        await waitForChildExit(serverProcess, 2000);
      }
    }
    const serverStopped = !serverProcess || serverProcess.exitCode !== null ||
      serverProcess.signalCode !== null;
    if (!serverStopped) failures.push('server');

    const closeSink = async (sink, label) => {
      if (!sink) return true;
      try { sink.closeSockets(); } catch (_) {}
      if (sink.server.listening) {
        try {
          await new Promise((resolve, reject) => sink.server.close((error) =>
            error ? reject(error) : resolve()));
        } catch (_) {
          failures.push(label);
          return false;
        }
      }
      if (sink.server.listening) {
        failures.push(label);
        return false;
      }
      return true;
    };
    const splitSinkClosed = await closeSink(splitSink, 'split_sink');
    const splitSecondSinkClosed = await closeSink(splitSecondSink, 'split_second_sink');
    const splitThirdSinkClosed = await closeSink(splitThirdSink, 'split_third_sink');

    let sshFixtureClosed = !sshFixture;
    let sshFixtureCleaned = !sshFixture;
    if (sshFixture) {
      try {
        await sshFixture.cleanup();
        const status = sshFixture.status();
        sshFixtureClosed = status.closed;
        sshFixtureCleaned = status.cleaned;
        if (!sshFixtureClosed || !sshFixtureCleaned) failures.push('ssh_fixture');
      } catch (_) {
        failures.push('ssh_fixture');
      }
    }
    let tmuxFixtureClosed = !tmuxSshFixture;
    let tmuxFixtureCleaned = !tmuxSshFixture;
    if (tmuxSshFixture) {
      try {
        await tmuxSshFixture.cleanup();
        const status = tmuxSshFixture.status();
        tmuxFixtureClosed = status.closed;
        tmuxFixtureCleaned = status.cleaned;
        if (!tmuxFixtureClosed || !tmuxFixtureCleaned) failures.push('tmux_fixture');
      } catch (_) {
        failures.push('tmux_fixture');
      }
    }

    let serverLogClosed = serverLog === null;
    if (serverLog !== null) {
      try {
        fs.closeSync(serverLog);
        serverLog = null;
        serverLogClosed = true;
      } catch (_) {
        failures.push('server_log');
      }
    }
    const tempRootSafeToRemove = (contextAClosed || tmuxRestartContextExitVerified) &&
      contextBClosed && browserClosed &&
      tmuxRestartProfileSafeToRemove && serverStopped && splitSinkClosed &&
      splitSecondSinkClosed && splitThirdSinkClosed && sshFixtureClosed &&
      sshFixtureCleaned && tmuxFixtureClosed && tmuxFixtureCleaned &&
      serverLogClosed;
    let tempRootRemoved = tempRoot === null;
    if (tempRoot !== null) {
      const ownedRoot = path.resolve(tempRoot);
      const expectedParent = path.resolve(os.tmpdir());
      const exactOwnedRoot = path.dirname(ownedRoot) === expectedParent &&
        path.basename(ownedRoot).startsWith('atermius-workspace-web-');
      if (!exactOwnedRoot) {
        failures.push('temp_root_namespace');
      } else if (!tempRootSafeToRemove) {
        failures.push('temp_root_preserved_cleanup_incomplete');
      } else {
        try {
          fs.rmSync(ownedRoot, { recursive: true, force: true });
          tempRootRemoved = !fs.existsSync(ownedRoot);
          if (tempRootRemoved) tempRoot = null;
          else failures.push('temp_root');
        } catch (_) {
          failures.push('temp_root');
        }
      }
    }

    const complete = failures.length === 0 &&
      (contextAClosed || tmuxRestartContextExitVerified) && contextBClosed &&
      browserClosed && serverStopped && splitSinkClosed && splitSecondSinkClosed &&
      splitThirdSinkClosed && sshFixtureClosed && sshFixtureCleaned &&
      tmuxFixtureClosed && tmuxFixtureCleaned && serverLogClosed && tempRootRemoved &&
      tmuxRestartBrowserProcessStopped;
    const receipt = {
      trigger,
      pass: cleanupPassNumber,
      contextAClosed,
      contextBClosed,
      browserClosed,
      tmuxRestartBrowserProcessStopped,
      tmuxRestartProcessGroupExited,
      tmuxRestartContextExitVerified,
      tmuxRestartProfileSafeToRemove,
      tempRootSafeToRemove,
      serverStopped,
      splitSinkClosed,
      splitSecondSinkClosed,
      splitThirdSinkClosed,
      sshFixtureClosed,
      sshFixtureCleaned,
      tmuxFixtureClosed,
      tmuxFixtureCleaned,
      serverLogClosed,
      tempRootRemoved,
      complete,
      failureKinds: failures,
    };
    console.log(`WEB-WORKSPACE-CLEANUP ${JSON.stringify(receipt)}`);
    if (!complete) {
      process.exitCode = 1;
      throw new Error('Workspace acceptance cleanup did not complete');
    }
    return receipt;
  };
  const cleanupResources = async (trigger) => {
    if (cleanupPromise) {
      const pendingCleanup = cleanupPromise;
      try { await pendingCleanup; } catch (_) {}
      // A signal cleanup can race an awaited startup operation. The finally
      // caller makes a second pass after that operation unwinds.
      if (cleanupPromise === null) return cleanupResources(trigger);
      return pendingCleanup;
    }
    const activeCleanup = cleanupPass(trigger);
    cleanupPromise = activeCleanup;
    try {
      return await activeCleanup;
    } finally {
      if (cleanupPromise === activeCleanup) cleanupPromise = null;
    }
  };
  const handleTermination = (signal) => {
    if (workspaceTerminationSignal) return;
    workspaceTerminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    void cleanupResources(`signal:${signal}`).catch(() => {
      process.exitCode = 1;
    });
  };
  const onSigint = () => handleTermination('SIGINT');
  const onSigterm = () => handleTermination('SIGTERM');
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);

  if (process.env.WORKSPACE_LAYOUT_CLEANUP_SMOKE === '1') {
    try {
      tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-workspace-web-cleanup-smoke-'));
      fs.mkdirSync(path.join(tempRoot, 'data'));
      fs.writeFileSync(path.join(tempRoot, 'data', 'smoke.db-wal'), 'cleanup-smoke');
      serverLog = fs.openSync(path.join(tempRoot, 'server.log'), 'a');
      contextA = { close: async () => {} };
      contextB = { close: async () => {} };
      browser = { close: async () => {} };
      serverProcess = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
        stdio: 'ignore',
      });
      const smokeSink = async () => {
        const server = net.createServer();
        await new Promise((resolve, reject) => {
          server.once('error', reject);
          server.listen(0, '127.0.0.1', resolve);
        });
        return { server, closeSockets() {} };
      };
      splitSink = await smokeSink();
      splitSecondSink = await smokeSink();
      splitThirdSink = await smokeSink();
      const fakeFixture = () => {
        let cleaned = false;
        return {
          async cleanup() { cleaned = true; },
          status() { return { closed: cleaned, cleaned }; },
        };
      };
      sshFixture = fakeFixture();
      tmuxSshFixture = fakeFixture();
      process.emit('SIGINT');
      const signalCleanup = cleanupPromise;
      const receipt = await signalCleanup;
      assertThat(receipt?.complete === true && receipt.tempRootRemoved === true &&
        !tempRoot && serverProcess.signalCode !== null,
      'signal cleanup smoke did not close resources and remove the exact temporary root');
      process.exitCode = 0;
      console.log('WEB-WORKSPACE-CLEANUP-SMOKE passed');
    } finally {
      try {
        await cleanupResources('cleanup-smoke-finally');
      } finally {
        process.removeListener('SIGINT', onSigint);
        process.removeListener('SIGTERM', onSigterm);
      }
    }
    return;
  }

  try {
  stage = 'start isolated synthetic sinks for the two-pane baseline';
  splitSink = await startIsolatedSink(splitTargetAddress);
  assertWorkspaceRunnerNotInterrupted();
  const splitTargetPort = splitSink.port;
  splitSecondSink = await startIsolatedSink(splitTargetAddress);
  assertWorkspaceRunnerNotInterrupted();
  const splitSecondTargetPort = splitSecondSink.port;
  splitThirdSink = await startIsolatedSink(splitTargetAddress);
  assertWorkspaceRunnerNotInterrupted();
  const splitThirdTargetPort = splitThirdSink.port;
  const splitSinks = [splitSink, splitSecondSink, splitThirdSink];
  let splitRelayTargetPorts = {
    first: splitTargetPort,
    second: splitSecondTargetPort,
    third: splitThirdTargetPort,
  };

  if (!FOCUSED_WORKSPACE_ONLY) {
  while (sshFixturePorts.length < 3) {
    const candidate = await unusedPort(splitTargetAddress);
    if (![splitTargetPort, splitSecondTargetPort, splitThirdTargetPort,
      ...sshFixturePorts].includes(candidate)) sshFixturePorts.push(candidate);
  }
  stage = 'start three isolated password-auth OpenSSH targets';
  sshFixture = await startSshFixture({
    bindAddress: splitTargetAddress,
    ports: sshFixturePorts,
    username: SSH_USERNAME,
    password: CREDENTIAL_SECRET,
  });
  assertWorkspaceRunnerNotInterrupted();
  nestedSshServers = sshFixture.servers;
  assertThat(Array.isArray(nestedSshServers) && nestedSshServers.length === 3 &&
    nestedSshServers.every((server, index) =>
      server.address === splitTargetAddress && server.port === sshFixturePorts[index]),
  'three isolated password-auth SSHD fixtures did not start on their reserved endpoints');
  distinctSshHostKeys = new Set(nestedSshServers.map((server) =>
    server.hostFingerprint)).size === nestedSshServers.length;
  assertThat(distinctSshHostKeys,
    'nested Workspace SSHD fixtures reused a host key instead of isolating host trust');

  stage = 'start one independent unchrooted tmux SSHD target';
  tmuxFixturePort = await unusedPort(splitTargetAddress);
  tmuxSshFixture = await startTmuxSshFixture({
    bindAddress: splitTargetAddress,
    port: tmuxFixturePort,
    username: TMUX_SSH_USERNAME,
    password: TMUX_CREDENTIAL_SECRET,
  });
  assertWorkspaceRunnerNotInterrupted();
  const initialTmuxFixtureState = tmuxSshFixture.tmuxSnapshot();
  assertThat(tmuxSshFixture.server.address === splitTargetAddress &&
    tmuxSshFixture.server.port === tmuxFixturePort &&
    tmuxSshFixture.server.summary().running &&
    !initialTmuxFixtureState.serverRunning &&
    initialTmuxFixtureState.sessionCount === 0 &&
    initialTmuxFixtureState.clientCount === 0,
  'independent tmux SSHD did not start with an empty session/client state');
  console.log('WEB-WORKSPACE-TMUX-FIXTURE-CHECKPOINT', JSON.stringify({
    separateTarget: true,
    separateAccount: tmuxSshFixture.username !== SSH_USERNAME,
    sessionCountBeforeProfileA: initialTmuxFixtureState.sessionCount,
    clientCountBeforeProfileA: initialTmuxFixtureState.clientCount,
  }));

  stage = 'direct OpenSSH rejection probe with an invalid password';
  const directFailureMarker = `direct-ssh-denied-${RUN_ID}`;
  directFailureAttempt = directPasswordSshAttempt({
    address: splitTargetAddress,
    port: nestedSshServers[0].port,
    password: `invalid-${crypto.randomBytes(24).toString('hex')}`,
    command: `printf '%s\\n' '${directFailureMarker}'`,
  });
  assertThat(directFailureAttempt.status !== 0 &&
    !directFailureAttempt.stdout.includes(directFailureMarker),
  'direct OpenSSH fixture accepted an invalid password');
  stage = 'direct OpenSSH accepted-password and remote-command probes';
  directPasswordProbes = nestedSshServers.map((server, index) => {
    const marker = `direct-ssh-${index + 1}-${RUN_ID}`;
    const attempt = directPasswordSshAttempt({
      address: splitTargetAddress,
      port: server.port,
      password: CREDENTIAL_SECRET,
      command: `printf '%s\\n' '${marker}'`,
    });
    assertThat(attempt.status === 0 && attempt.stdout.includes(marker),
      `direct OpenSSH password authentication and command probe failed for fixture ${index + 1}`);
    return { status: attempt.status, commandMarkerObserved: attempt.stdout.includes(marker) };
  });
  const sshFixtureSnapshot = () => nestedSshServers.map((server) => server.summary());
  const directSshFixtureSummary = sshFixtureSnapshot();
  assertThat(directSshFixtureSummary[0].passwordRejected >= 1 &&
    directSshFixtureSummary.every((summary) =>
      summary.passwordAccepted >= 1 && summary.keyExchangeStarted >= 1 &&
      summary.commandSessions >= 1),
  'direct OpenSSH probes did not record rejected/accepted password auth, KEX, and remote command sessions');
  console.log('WEB-WORKSPACE-SSH-DIRECT-PREFLIGHT', JSON.stringify({
    targetCount: nestedSshServers.length,
    invalidPasswordRejected: directSshFixtureSummary[0].passwordRejected >= 1,
    directPasswordCommandsSucceeded: directPasswordProbes.every((item) =>
      item.commandMarkerObserved),
    serverSummaries: directSshFixtureSummary.map((summary) => ({
      tcpConnectionsAccepted: summary.tcpConnectionsAccepted,
      keyExchangeStarted: summary.keyExchangeStarted,
      passwordAccepted: summary.passwordAccepted,
      passwordRejected: summary.passwordRejected,
      commandSessions: summary.commandSessions,
    })),
  }));
  assertWorkspaceRunnerNotInterrupted();
  }

  if (TMUX_PROCESS_RESTART_ONLY) {
    stage = 'start isolated tmux SSHD target for same-profile process restart';
    tmuxFixturePort = await unusedPort(splitTargetAddress);
    tmuxSshFixture = await startTmuxSshFixture({
      bindAddress: splitTargetAddress,
      port: tmuxFixturePort,
      username: TMUX_SSH_USERNAME,
      password: TMUX_CREDENTIAL_SECRET,
    });
    assertWorkspaceRunnerNotInterrupted();
    const initialTmuxFixtureState = tmuxSshFixture.tmuxSnapshot();
    assertThat(tmuxSshFixture.server.address === splitTargetAddress &&
      tmuxSshFixture.server.port === tmuxFixturePort &&
      tmuxSshFixture.server.summary().running &&
      !initialTmuxFixtureState.serverRunning &&
      initialTmuxFixtureState.sessionCount === 0 &&
      initialTmuxFixtureState.clientCount === 0,
    'focused tmux SSHD fixture did not start with an empty session/client state');
    console.log('WEB-WORKSPACE-TMUX-RESTART-FIXTURE-CHECKPOINT', JSON.stringify({
      isolatedTmuxSshd: true,
      sessionCountBeforeProfileA: initialTmuxFixtureState.sessionCount,
      clientCountBeforeProfileA: initialTmuxFixtureState.clientCount,
    }));
  }

  const sshFixtureSnapshot = () => nestedSshServers.map((server) => server.summary());

  const relaySinkSnapshot = () => splitSinks.map((sink) => ({
    accepted: sink.acceptedCount,
    active: sink.activeCount,
  }));

  const relaySinkDeltas = (before) => relaySinkSnapshot().map((sink, index) => ({
    accepted: sink.accepted - before[index].accepted,
    active: sink.active - before[index].active,
  }));

  tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-workspace-web-'));
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dataDir, 0o700);
  const databasePath = path.join(dataDir, 'atermius.db');
  let vaultId = null;
  let hostARecordId = null;
  let hostCRecordId = null;
  let splitHostRecordId = null;
  let splitWorkspaceRecordId = null;
  serverLog = fs.openSync(path.join(tempRoot, 'server.log'), 'a');
  const port = await unusedPort();
  assertWorkspaceRunnerNotInterrupted();
  const baseUrl = `http://127.0.0.1:${port}`;
  const serverEnv = {
    ...process.env,
    ATERMIUS_BIND: `127.0.0.1:${port}`,
    ATERMIUS_DATA_DIR: dataDir,
    ATERMIUS_DATABASE_URL: `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`,
    ATERMIUS_WEB_DIR: WEB_ROOT,
    ATERMIUS_PUBLIC_ORIGIN: baseUrl,
    ATERMIUS_REGISTRATION_OPEN: 'false',
    ATERMIUS_RELAY_ENABLED: 'true',
    ATERMIUS_RELAY_ALLOW_CIDRS: `${splitTargetAddress}/32`,
    ATERMIUS_RELAY_ALLOW_PORTS:
      [splitTargetPort, splitSecondTargetPort, splitThirdTargetPort,
        ...sshFixturePorts, tmuxFixturePort].filter(Boolean).join(','),
    RUST_LOG: process.env.RUST_LOG || 'warn',
  };
  let workspaceRecordId = null;
  let workspaceHostReferenceMarkers = [];
  let encryptedWorkspacePrivacyRecordId = null;
  const relayAttempts = { A: [], B: [] };
  const vaultSyncApiEvents = { A: [], B: [] };
  const vaultChangesPages = { A: [], B: [] };
  const vaultSyncRequestByHandle = new WeakMap();
  const apiPrivacyChecks = [];
  const workspaceSavePushes = [];
  const workspaceSavePushResponses = [];
  const workspaceSplitPushes = [];
  const workspaceSplitPushResponses = [];
  const splitPullChangePages = [];
  const workspaceSplitPushRequests = new WeakSet();
  const workspaceConflictPushes = [];
  const workspaceConflictPushResponses = [];
  const workspaceConflictUploads = [];
  const workspaceConflictUploadResponses = [];
  const workspaceConflictFeedEvents = [];
  const workspaceConflictResolutionRequests = [];
  const workspaceConflictResolutionResponses = [];
  const workspaceConflictCaptureCounts = () => ({
    syncPushRequestCount: workspaceConflictPushes.length,
    syncPushResponseCount: workspaceConflictPushResponses.length,
    conflictUploadRequestCount: workspaceConflictUploads.length,
    conflictUploadResponseCount: workspaceConflictUploadResponses.length,
    conflictFeedEventCount: workspaceConflictFeedEvents.length,
    conflictResolutionRequestCount: workspaceConflictResolutionRequests.length,
    conflictResolutionResponseCount: workspaceConflictResolutionResponses.length,
  });
  const pageErrors = [];
  const startupDiagnostics = { A: [], B: [] };
  const relayWebSockets = { A: 0, B: 0 };
  const activeRelayWebSockets = { A: new Set(), B: new Set() };
  const relayWebSocketCloses = { A: 0, B: 0 };
  const relayRequestByHandle = new WeakMap();

  const attachDiagnostics = (page, profile) => {
    page.on('pageerror', (error) => {
      pageErrors.push(profile);
      startupDiagnostics[profile].push({
        kind: 'runtime',
        category: safeRuntimeCategory(error?.message),
      });
    });
    page.on('console', (message) => {
      if (message.type() === 'error') {
        startupDiagnostics[profile].push({
          kind: 'runtime',
          category: safeRuntimeCategory(message.text()),
        });
      }
    });
    page.on('requestfailed', (request) => {
      const syncEvent = vaultSyncRequestByHandle.get(request);
      if (syncEvent) syncEvent.failed = true;
      const name = staticResourceName(request.url());
      if (!name) return;
      const errorText = request.failure()?.errorText || '';
      startupDiagnostics[profile].push({
        kind: 'resource',
        name,
        status: null,
        failureCategory: safeRuntimeCategory(errorText),
      });
    });
    page.on('request', (request) => {
      let url;
      try { url = new URL(request.url()); } catch (_) { return; }
      if (request.method() === 'POST' && url.pathname === '/api/v1/relay/tickets') {
        let parsed = {};
        try { parsed = request.postDataJSON(); } catch (_) {}
        const item = {
          status: null,
          targetHost: typeof parsed?.target_host === 'string'
            ? parsed.target_host : null,
          targetPort: Number.isInteger(parsed?.target_port)
            ? parsed.target_port : null,
          targetMatchesFirstSplitHost: parsed?.target_host === splitTargetAddress &&
            parsed?.target_port === splitRelayTargetPorts.first,
          targetMatchesSecondSplitHost: parsed?.target_host === splitTargetAddress &&
            parsed?.target_port === splitRelayTargetPorts.second,
          targetMatchesThirdSplitHost: parsed?.target_host === splitTargetAddress &&
            parsed?.target_port === splitRelayTargetPorts.third,
        };
        relayAttempts[profile].push(item);
        relayRequestByHandle.set(request, item);
      }
      if (url.pathname.endsWith('/sync/push') || url.pathname.endsWith('/changes')) {
        const item = {
          endpoint: url.pathname.endsWith('/sync/push') ? 'push' : 'changes',
          method: request.method(),
          status: null,
          failed: false,
        };
        vaultSyncApiEvents[profile].push(item);
        vaultSyncRequestByHandle.set(request, item);
      }
      if (url.pathname.endsWith('/sync/push') || url.pathname.endsWith('/changes') ||
          url.pathname.endsWith('/snapshots') || url.pathname.endsWith('/conflicts') ||
          url.pathname.endsWith('/conflict-changes') || url.pathname.includes('/conflicts/')) {
        const body = request.postData() || '';
        apiPrivacyChecks.push({ profile, direction: 'request', markersAbsent: markerScan(body) });
        if (captureWorkspaceConflict && request.method() === 'POST' &&
            /\/conflicts\/[0-9a-f-]+\/resolve$/.test(url.pathname)) {
          let parsed;
          try { parsed = request.postDataJSON(); } catch (_) { parsed = {}; }
          workspaceConflictResolutionRequests.push({
            profile,
            conflictId: url.pathname.match(/\/conflicts\/([0-9a-f-]+)\/resolve$/)?.[1] || null,
            resolvedRevisionId: parsed?.resolved_revision_id || null,
            requestBodyPlaintextMarkersAbsent: markerScan(body),
          });
        }
        if (captureWorkspaceConflict && profile === 'B' && request.method() === 'POST' &&
            url.pathname.endsWith('/conflicts')) {
          try {
            const parsed = request.postDataJSON();
            const envelope = parsed?.envelope;
            const header = envelope?.header || {};
            workspaceConflictUploads.push({
              operation: header.operation || null,
              recordId: header.record_id || null,
              revisionId: header.revision_id || null,
              baseRevisionId: header.base_revision_id || null,
              opId: header.op_id || null,
              deviceId: header.device_id || null,
              envelopeSha256: crypto.createHash('sha256')
                .update(stableJson(envelope || {}))
                .digest('hex'),
              requestBodyPlaintextMarkersAbsent: markerScan(body),
              envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
                'ciphertext,header,nonce,signature' &&
                ['nonce', 'ciphertext', 'signature'].every((key) =>
                  typeof envelope?.[key] === 'string' && /^[A-Za-z0-9_-]+$/.test(envelope[key])),
            });
          } catch (_) {
            workspaceConflictUploads.push({ recordId: null, requestBodyPlaintextMarkersAbsent: false });
          }
        }
        if (captureWorkspaceSave && profile === 'A' &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          try {
            const parsed = request.postDataJSON();
            workspaceSavePushes.push({
              operations: (Array.isArray(parsed?.operations) ? parsed.operations : [])
                .map((item) => ({
                  operation: item?.header?.operation || null,
                  recordId: item?.header?.record_id || null,
                  revisionId: item?.header?.revision_id || null,
                  opId: item?.header?.op_id || null,
                })),
            });
          } catch (_) {
            workspaceSavePushes.push({ operations: [] });
          }
        }
        if (captureWorkspaceSplit && profile === 'A' &&
            request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
          workspaceSplitPushRequests.add(request);
          try {
            const parsed = request.postDataJSON();
            const operations = (Array.isArray(parsed?.operations) ? parsed.operations : [])
            .map((item) => {
                // /sync/push carries each signed envelope directly in the
                // operations array; there is no nested `envelope` property.
                const envelope = item || {};
                const header = envelope.header || {};
                return {
                  operation: header.operation || null,
                  recordId: header.record_id || null,
                  revisionId: header.revision_id || null,
                  opId: header.op_id || null,
                  deviceId: header.device_id || null,
                  envelopeSha256: crypto.createHash('sha256')
                    .update(stableJson(envelope || {})).digest('hex'),
                  envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
                    'ciphertext,header,nonce,signature' &&
                    ['nonce', 'ciphertext', 'signature'].every((key) =>
                      typeof envelope?.[key] === 'string' &&
                      /^[A-Za-z0-9_-]+$/.test(envelope[key])),
                  hostReferenceMarkersAbsent: markerScan(
                    envelope, workspaceHostReferenceMarkers,
                  ),
                };
              });
            if (operations.length === 1 &&
                operations[0].operation === 'create' && operations[0].recordId) {
              // Notification-driven pulls can consume the new record before
              // the main flow has awaited its push receipt. Capture the exact
              // opaque Workspace record ID as soon as its request is observed.
              encryptedWorkspacePrivacyRecordId = operations[0].recordId;
            }
            workspaceSplitPushes.push({
              operations,
              requestBodyPlaintextMarkersAbsent: markerScan(request.postData() || ''),
              encryptedWorkspaceHostReferenceMarkersAbsent:
                operations.length === 1 &&
                operations[0].hostReferenceMarkersAbsent === true,
            });
          } catch (_) {
            workspaceSplitPushes.push({ operations: [], requestBodyPlaintextMarkersAbsent: false });
          }
        }
        if (captureWorkspaceConflict && request.method() === 'POST' &&
            url.pathname.endsWith('/sync/push')) {
          try {
            const parsed = request.postDataJSON();
            const operations = (Array.isArray(parsed?.operations) ? parsed.operations : [])
              .map((item) => ({
                operation: item?.header?.operation || null,
                recordId: item?.header?.record_id || null,
                revisionId: item?.header?.revision_id || null,
                baseRevisionId: item?.header?.base_revision_id || null,
                opId: item?.header?.op_id || null,
                deviceId: item?.header?.device_id || null,
              }));
            workspaceConflictPushes.push({
              profile,
              operations,
              requestBodyPlaintextMarkersAbsent: markerScan(request.postData() || ''),
            });
          } catch (_) {
            workspaceConflictPushes.push({ profile, operations: [], requestBodyPlaintextMarkersAbsent: false });
          }
        }
      }
    });
    page.on('response', (response) => {
      void (async () => {
        const request = response.request();
        const syncEvent = vaultSyncRequestByHandle.get(request);
        if (syncEvent) syncEvent.status = response.status();
        const isCapturedWorkspaceSplitPush =
          profile === 'A' && workspaceSplitPushRequests.has(request);
        let url;
        try { url = new URL(response.url()); } catch (_) { return; }
        const resourceName = staticResourceName(response.url());
        if (resourceName) {
          startupDiagnostics[profile].push({
            kind: 'resource',
            name: resourceName,
            status: response.status(),
            failureCategory: null,
          });
        }
        if (url.pathname.endsWith('/sync/push') || url.pathname.endsWith('/changes') ||
            url.pathname.endsWith('/snapshots') || url.pathname.endsWith('/conflicts') ||
            url.pathname.endsWith('/conflict-changes') || url.pathname.includes('/conflicts/')) {
          const body = await response.text().catch(() => '');
          apiPrivacyChecks.push({ profile, direction: 'response', markersAbsent: markerScan(body) });
          if (request.method() === 'GET' && url.pathname.endsWith('/changes')) {
            try {
              const parsed = JSON.parse(body);
              const events = Array.isArray(parsed?.events) ? parsed.events : [];
              vaultChangesPages[profile].push({
                httpStatus: response.status(),
                responsePlaintextMarkersAbsent: markerScan(body),
                eventCount: events.length,
                createEventCount: events.filter((event) =>
                  event?.event_type === 'create').length,
                updateEventCount: events.filter((event) =>
                  event?.event_type === 'update').length,
                seenRecordIds: events.map((event) => event?.record_id)
                  .filter((recordId) => typeof recordId === 'string'),
                seenOperationKinds: events.map((event) => event?.event_type || 'unknown'),
              });
            } catch (_) {
              vaultChangesPages[profile].push({
                httpStatus: response.status(),
                responsePlaintextMarkersAbsent: markerScan(body),
                eventCount: null,
                parseFailed: true,
              });
            }
          }
          if (captureWorkspaceSplit && profile === 'B' && request.method() === 'GET' &&
              url.pathname.endsWith('/changes')) {
            try {
              const parsed = JSON.parse(body);
              const events = Array.isArray(parsed?.events) ? parsed.events : [];
              splitPullChangePages.push({
                httpStatus: response.status(),
                responsePlaintextMarkersAbsent: markerScan(body),
                eventCount: events.length,
                createEventCount: events.filter((event) =>
                  event?.event_type === 'create').length,
                updateEventCount: events.filter((event) =>
                  event?.event_type === 'update').length,
                seenRecordIds: events.map((event) => event?.record_id)
                  .filter((recordId) => typeof recordId === 'string'),
                seenOperationKinds: events.map((event) => event?.event_type || 'unknown'),
                workspaceEnvelopeHostReferenceChecks: events
                  .filter((event) => event?.record_id === encryptedWorkspacePrivacyRecordId)
                  .map((event) => {
                    const envelope = event?.envelope || {};
                    const header = envelope.header || {};
                    return {
                      recordIdMatchesWorkspace: true,
                      eventType: event?.event_type || null,
                      revisionId: event?.revision_id || null,
                      commitSeq: event?.commit_seq || null,
                      envelopePresent: Boolean(event?.envelope &&
                        typeof event.envelope === 'object'),
                      envelopeSha256: crypto.createHash('sha256')
                        .update(stableJson(envelope)).digest('hex'),
                      headerRecordId: header.record_id || null,
                      headerOperation: header.operation || null,
                      headerRevisionId: header.revision_id || null,
                      headerOpId: header.op_id || null,
                      envelopeShapeValid: Object.keys(envelope || {}).sort().join(',') ===
                        'ciphertext,header,nonce,signature' &&
                        ['nonce', 'ciphertext', 'signature'].every((key) =>
                          typeof envelope?.[key] === 'string' &&
                          /^[A-Za-z0-9_-]+$/.test(envelope[key])),
                      hostReferenceMarkersAbsent: markerScan(
                        envelope, workspaceHostReferenceMarkers,
                      ),
                    };
                  }),
              });
            } catch (_) {
              splitPullChangePages.push({
                httpStatus: response.status(),
                responsePlaintextMarkersAbsent: markerScan(body),
                eventCount: null,
                parseFailed: true,
              });
            }
          }
          if (captureWorkspaceConflict && profile === 'B' &&
              request.method() === 'POST' && url.pathname.endsWith('/conflicts')) {
            let conflictId = null;
            try { conflictId = JSON.parse(body)?.conflict_id || null; } catch (_) {}
            workspaceConflictUploadResponses.push({ status: response.status(), conflictId });
          }
          if (captureWorkspaceConflict && request.method() === 'POST' &&
              /\/conflicts\/[0-9a-f-]+\/resolve$/.test(url.pathname)) {
            let summary = {};
            try {
              const parsed = JSON.parse(body);
              summary = {
                status: parsed?.status || null,
                resolvedRevisionId: parsed?.resolved_revision_id || null,
                resolutionSeq: parsed?.resolution_seq || null,
                alreadyResolved: parsed?.already_resolved === true,
              };
            } catch (_) {}
            workspaceConflictResolutionResponses.push({
              profile,
              conflictId: url.pathname.match(/\/conflicts\/([0-9a-f-]+)\/resolve$/)?.[1] || null,
              httpStatus: response.status(),
              ...summary,
            });
          }
          if (captureWorkspaceSave && profile === 'A' &&
              request.method() === 'POST' && url.pathname.endsWith('/sync/push')) {
            let results = [];
            try {
              const parsed = JSON.parse(body);
              results = (Array.isArray(parsed?.results) ? parsed.results : []).map((item) => ({
                commitSeq: item?.commit_seq || null,
                alreadyCommitted: item?.already_committed === true,
              }));
            } catch (_) {}
            workspaceSavePushResponses.push({ status: response.status(), results });
          }
          if (isCapturedWorkspaceSplitPush && request.method() === 'POST' &&
              url.pathname.endsWith('/sync/push')) {
            let results = [];
            try {
              const parsed = JSON.parse(body);
              results = (Array.isArray(parsed?.results) ? parsed.results : []).map((item) => ({
                opId: item?.op_id || null,
                revisionId: item?.revision_id || null,
                commitSeq: item?.commit_seq || null,
                alreadyCommitted: item?.already_committed === true,
              }));
            } catch (_) {}
            workspaceSplitPushResponses.push({
              status: response.status(),
              results,
              encryptedWorkspaceHostReferenceMarkersAbsent:
                markerScan(body, workspaceHostReferenceMarkers),
            });
          }
          if (captureWorkspaceConflict && request.method() === 'POST' &&
              url.pathname.endsWith('/sync/push')) {
            let results = [];
            try {
              const parsed = JSON.parse(body);
              results = (Array.isArray(parsed?.results) ? parsed.results : []).map((item) => ({
                opId: item?.op_id || null,
                recordId: item?.record_id || null,
                revisionId: item?.revision_id || null,
                commitSeq: item?.commit_seq || null,
                alreadyCommitted: item?.already_committed === true,
              }));
            } catch (_) {}
            workspaceConflictPushResponses.push({ profile, status: response.status(), results });
          }
          if (captureWorkspaceConflict && url.pathname.endsWith('/conflict-changes')) {
            try {
              const parsed = JSON.parse(body);
              for (const event of Array.isArray(parsed?.events) ? parsed.events : []) {
                const envelope = event?.envelope;
                workspaceConflictFeedEvents.push({
                  profile,
                  type: event?.type || null,
                  sequence: event?.seq || null,
                  conflictId: event?.conflict_id || null,
                  recordId: event?.record_id || null,
                  hasEnvelope: Object.hasOwn(event || {}, 'envelope'),
                  resolvedRevisionId: event?.resolved_revision_id || null,
                  envelopeSha256: envelope
                    ? crypto.createHash('sha256').update(stableJson(envelope)).digest('hex')
                    : null,
                  envelopePlaintextMarkersAbsent: markerScan(envelope || {}),
                });
              }
            } catch (_) {}
          }
        }
        const relayAttempt = relayRequestByHandle.get(request);
        if (relayAttempt) relayAttempt.status = response.status();
      })().catch(() => {});
    });
    page.on('websocket', (websocket) => {
      try {
        if (new URL(websocket.url()).pathname === '/relay/v1/connect') {
          relayWebSockets[profile]++;
          activeRelayWebSockets[profile].add(websocket);
          websocket.on('close', () => {
            activeRelayWebSockets[profile].delete(websocket);
            relayWebSocketCloses[profile]++;
          });
        }
      } catch (_) {}
    });
  };

    stage = 'start isolated server';
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      stdio: ['ignore', serverLog, serverLog],
    });
    await waitReady(baseUrl, serverProcess);
    assertWorkspaceRunnerNotInterrupted();
    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 30000,
      maxBuffer: 4096,
    });
    assertThat(bootstrap.status === 0, 'temporary bootstrap failed');
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    assertThat(typeof bootstrapToken === 'string' && bootstrapToken.length >= 40,
      'temporary bootstrap token unavailable');

    stage = 'launch independent browser profiles';
    const launchOptions = {
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
    };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    if (TMUX_PROCESS_RESTART_ONLY) {
      tmuxRestartProfileDir = path.join(tempRoot, 'profiles', 'profile-a');
      fs.mkdirSync(tmuxRestartProfileDir, { recursive: true, mode: 0o700 });
      fs.chmodSync(path.dirname(tmuxRestartProfileDir), 0o700);
      fs.chmodSync(tmuxRestartProfileDir, 0o700);
      contextA = await chromium.launchPersistentContext(
        tmuxRestartProfileDir, launchOptions,
      );
    } else {
      browser = await chromium.launch(launchOptions);
      assertWorkspaceRunnerNotInterrupted();
      contextA = await browser.newContext({
        locale: 'en-US', viewport: { width: 1440, height: 1000 },
      });
      assertWorkspaceRunnerNotInterrupted();
      contextB = await browser.newContext({
        locale: 'en-US', viewport: { width: 1440, height: 1000 },
      });
    }
    assertWorkspaceRunnerNotInterrupted();
    await Promise.all([contextA, contextB].filter(Boolean).map((context) =>
      context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl })));
    assertWorkspaceRunnerNotInterrupted();
    let pageA = TMUX_PROCESS_RESTART_ONLY
      ? (contextA.pages()[0] || await contextA.newPage())
      : await contextA.newPage();
    let pageB = contextB ? await contextB.newPage() : null;
    attachDiagnostics(pageA, 'A');
    if (pageB) attachDiagnostics(pageB, 'B');
    stage = 'navigate profile A to server enrollment UI';
    await pageA.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    if (pageB) {
      stage = 'navigate profile B to server enrollment UI';
      await pageB.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    }
    stage = 'initialize profile A Flutter semantics';
    await enableSemantics(pageA, 'Profile A', startupDiagnostics.A);
    if (pageB) {
      stage = 'initialize profile B Flutter semantics';
      await enableSemantics(pageB, 'Profile B', startupDiagnostics.B);
    }
    await pageA.evaluate(() => localStorage.setItem('workspace-layout-profile-marker', 'A'));
    if (pageB) {
      const profileStateLeaked = await pageB.evaluate(() =>
        localStorage.getItem('workspace-layout-profile-marker') !== null);
      assertThat(!profileStateLeaked, 'the two Chromium profiles shared browser storage');
    }
    stage = 'connect profile A to the server';
    await connectSecurely(pageA, baseUrl);

    stage = 'profile A registration';
    await field(pageA, 'Owner email');
    await fill(pageA, 'Owner email', USERNAME);
    await fill(pageA, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(pageA, 'Confirm master password', MASTER_PASSWORD);
    await fill(pageA, 'One-time bootstrap token', bootstrapToken);
    await fill(pageA, 'Device name', 'Workspace profile A');
    await fill(pageA, 'First Vault', 'Workspace layout acceptance');
    await click(pageA, 'Create owner account');
    bootstrapToken = undefined;
    await waitForWorkspace(pageA);

    if (TMUX_PROCESS_RESTART_ONLY) {
      const origin = new URL(baseUrl).origin;
      const activeVault = () => serverVaultSnapshot(databasePath).vaults[0] || null;
      const requireVault = (label) => {
        const snapshot = activeVault();
        assertThat(snapshot, `${label} did not find the active Vault`);
        vaultId = snapshot.vaultId;
        return snapshot;
      };
      const waitForWorkspacePush = async (pushBaseline, predicate, label) =>
        waitForCaptured(() => workspaceSplitPushes.slice(pushBaseline)
          .flatMap((push) => push.operations || []).find(predicate), label);
      const waitForWorkspaceReceipt = async (responseBaseline, operation, label) =>
        waitForCaptured(() => workspaceSplitPushResponses.slice(responseBaseline)
          .find((response) => response.status === 200 &&
            response.results.some((result) => result.opId === operation.opId &&
              result.revisionId === operation.revisionId && result.commitSeq &&
              !result.alreadyCommitted)), label);

      stage = 'Profile A create tmux Credential and sync it';
      requireVault('tmux Credential create');
      await addCredential(pageA, () => pageErrors.length, {
        name: TMUX_CREDENTIAL_NAME,
        username: TMUX_SSH_USERNAME,
        password: TMUX_CREDENTIAL_SECRET,
      });
      await syncNow(pageA, 'tmux process-restart Credential sync');
      const credentialVault = requireVault('tmux Credential receipt');
      const credentialCreate = serverCommitDelta(
        databasePath, vaultId, '0', credentialVault.commitSeq,
      ).events.find((event) => event.operation === 'create');
      assertThat(credentialCreate?.recordId,
        'tmux process-restart Credential did not commit an opaque record');

      stage = 'Profile A create the isolated tmux Host and sync it';
      const beforeHost = requireVault('tmux Host create baseline');
      await addHost(pageA, HOST_TMUX_NAME, splitTargetAddress, {
        port: tmuxFixturePort,
        sshUsername: TMUX_SSH_USERNAME,
        credentialName: TMUX_CREDENTIAL_NAME,
      });
      await syncNow(pageA, 'tmux process-restart Host sync');
      const afterHost = requireVault('tmux Host receipt');
      const hostCommit = serverCommitDelta(
        databasePath, vaultId, beforeHost.commitSeq, afterHost.commitSeq,
      );
      assertThat(hostCommit.eventCount === 1 &&
        hostCommit.events[0]?.operation === 'create',
      'tmux process-restart Host did not commit exactly one encrypted record');
      const hostRecordId = hostCommit.events[0].recordId;
      workspaceHostReferenceMarkers = [credentialCreate.recordId, hostRecordId];

      stage = 'Profile A preapprove the tmux Host key before Workspace Connect';
      const preflightSshBaseline = tmuxSshFixture.server.summary();
      const preflightRelayBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        closes: relayWebSocketCloses.A,
        activeWebSockets: activeRelayWebSockets.A.size,
      };
      const knownHostPushBaseline = workspaceSplitPushes.length;
      const knownHostPushResponseBaseline = workspaceSplitPushResponses.length;
      const knownHostApiBaseline = vaultSyncApiEvents.A.length;
      captureWorkspaceSplit = true;
      await openHostTab(pageA, HOST_TMUX_NAME);
      const firstPreflightTicket = await waitForCaptured(() => {
        const ticket = relayAttempts.A[preflightRelayBaseline.tickets];
        return ticket?.status !== null && ticket ? ticket : null;
      }, 'Profile A first tmux Host preflight Relay ticket');
      const preflightFirstAttempt = await waitForCaptured(() => {
        const ssh = tmuxSshFixture.server.summary();
        return ssh.clientBannerReceived >=
            preflightSshBaseline.clientBannerReceived + 1 &&
          ssh.keyExchangeStarted >=
            preflightSshBaseline.keyExchangeStarted + 1 ? ssh : null;
      }, 'Profile A untrusted tmux Host preflight handshake');
      assertThat(firstPreflightTicket.status === 200 &&
        firstPreflightTicket.targetHost === splitTargetAddress &&
        firstPreflightTicket.targetPort === tmuxFixturePort &&
        preflightFirstAttempt.passwordAccepted ===
          preflightSshBaseline.passwordAccepted &&
        preflightFirstAttempt.shellSessions ===
          preflightSshBaseline.shellSessions,
      'first-use tmux Host preflight did not stop before host-key approval');
      stage = 'Profile A approve the exact first-use tmux SSH host key';
      const hostKeyTrust = await acceptFirstUseSshHostKey(
        pageA, HOST_TMUX_NAME, tmuxSshFixture.server.hostFingerprint,
      );
      const preflightAuthenticated = await waitForCaptured(() => {
        const ssh = tmuxSshFixture.server.summary();
        return ssh.passwordAccepted === preflightSshBaseline.passwordAccepted + 1 &&
          ssh.shellSessions === preflightSshBaseline.shellSessions + 1 ? ssh : null;
      }, 'Profile A preflight SSH authentication');
      const preflightRetryTicket = await waitForCaptured(() => {
        const tickets = relayAttempts.A.slice(preflightRelayBaseline.tickets);
        return tickets.length === 2 && tickets[1].status !== null
          ? tickets[1] : null;
      }, 'Profile A post-approval tmux Host preflight Relay ticket');
      const preflightTickets = relayAttempts.A.slice(preflightRelayBaseline.tickets);
      await waitForCaptured(() =>
        activeRelayWebSockets.A.size === preflightRelayBaseline.activeWebSockets + 1 &&
          relayWebSockets.A === preflightRelayBaseline.webSockets + 2 &&
          relayWebSocketCloses.A === preflightRelayBaseline.closes + 1 &&
          preflightTickets.length === 2 &&
          preflightTickets.every((ticket) => ticket.status !== null),
      'Profile A first tmux Host preflight Relay WebSocket');
      assertThat(hostKeyTrust.fingerprintMatchesFixture &&
        preflightAuthenticated.keyExchangeStarted >
          preflightSshBaseline.keyExchangeStarted &&
        preflightAuthenticated.passwordAccepted ===
          preflightSshBaseline.passwordAccepted + 1 &&
        preflightAuthenticated.shellSessions ===
          preflightSshBaseline.shellSessions + 1 &&
        preflightTickets.length === 2 &&
        preflightTickets.every((ticket) => ticket.status === 200 &&
          ticket.targetHost === splitTargetAddress &&
          ticket.targetPort === tmuxFixturePort) &&
        preflightRetryTicket.status === 200 &&
        preflightRetryTicket.targetHost === splitTargetAddress &&
        preflightRetryTicket.targetPort === tmuxFixturePort,
      'tmux Host trust preflight did not authenticate against the exact fixture');
      await syncNow(pageA, 'Profile A tmux KnownHost approval sync');
      const knownHostOperation = await waitForWorkspacePush(
        knownHostPushBaseline,
        (operation) => operation.operation === 'create' && operation.recordId &&
          operation.opId && operation.revisionId && operation.deviceId,
        'Profile A encrypted KnownHost approval operation',
      );
      const knownHostReceipt = await waitForWorkspaceReceipt(
        knownHostPushResponseBaseline,
        knownHostOperation,
        'Profile A KnownHost approval push receipt',
      );
      const afterKnownHostApproval = requireVault('KnownHost approval commit');
      const knownHostCommit = serverCommitDelta(
        databasePath, vaultId, afterHost.commitSeq,
        afterKnownHostApproval.commitSeq,
      );
      const knownHostApprovalApiEvents = vaultSyncApiEvents.A.slice(
        knownHostApiBaseline,
      );
      assertThat(knownHostCommit.eventCount === 1 &&
        knownHostCommit.distinctCommitCount === 1 &&
        knownHostCommit.events[0]?.operation === 'create' &&
        knownHostCommit.events[0]?.recordId === knownHostOperation.recordId &&
        knownHostReceipt.results.filter((item) =>
          item.opId === knownHostOperation.opId &&
          item.revisionId === knownHostOperation.revisionId &&
          !item.alreadyCommitted).length === 1 &&
        knownHostApprovalApiEvents.some((item) => item.endpoint === 'push' &&
          item.method === 'POST' && item.status === 200) &&
        knownHostApprovalApiEvents.some((item) => item.endpoint === 'changes' &&
          item.method === 'GET' && item.status === 200) &&
        workspaceSplitPushes.slice(knownHostPushBaseline)
          .flatMap((push) => push.operations || [])
          .some((operation) => operation.recordId === knownHostOperation.recordId),
      'KnownHost approval did not produce one exact encrypted commit and successful sync receipt');

      stage = 'Profile A force-pull committed KnownHost approval';
      const knownHostPullApiBaseline = vaultSyncApiEvents.A.length;
      await syncNow(pageA, 'Profile A forced pull of committed KnownHost approval', {
        forcePull: true,
      });
      const knownHostPullApiEvents = vaultSyncApiEvents.A.slice(
        knownHostPullApiBaseline,
      );
      assertThat(knownHostPullApiEvents.some((item) => item.endpoint === 'changes' &&
        item.method === 'GET' && item.status === 200),
      'Profile A forced pull did not receive a successful Vault changes response');
      stage = 'Profile A navigate to Settings for KnownHost projection';
      await click(pageA, 'Settings');
      stage = 'Profile A wait for Settings KnownHost trust panel';
      await waitForVisibleSemanticText(pageA, 'SSH host-key trust',
        'Profile A Settings KnownHost trust panel');
      stage = 'Profile A inspect decrypted KnownHost trust projection';
      const knownHostProjection = await pageA.evaluate((expectedEndpoint) => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
            style.display !== 'none';
        };
        const body = document.body?.innerText || '';
        const statusCategory = (text) => {
          if (/QUEUED\s*[—-]\s*NOT TRUSTED/.test(text)) return 'QUEUED';
          if (/CONFLICT\s*[—-]\s*CONNECTIONS BLOCKED/.test(text)) return 'CONFLICT';
          if (/\bREVOKED\b/.test(text)) return 'REVOKED';
          if (/\bTRUSTED\b/.test(text)) return 'TRUSTED';
          return null;
        };
        const visibleStatusCategories = [...document.querySelectorAll('flt-semantics')]
          .filter(visible)
          .map((node) => statusCategory([
            node.getAttribute('aria-label') || '',
            node.innerText || '',
            node.textContent || '',
          ].join(' ')))
          .filter(Boolean);
        const endpointOffset = body.indexOf(expectedEndpoint);
        const endpointContext = endpointOffset < 0 ? ''
          : body.slice(endpointOffset, endpointOffset + 600);
        const endpointStatus = statusCategory(endpointContext);
        return {
          probeAvailable: true,
          panelVisible: body.includes('SSH host-key trust'),
          expectedEndpointVisible: endpointOffset >= 0,
          endpointStatus,
          trustedStatusCount: visibleStatusCategories.filter((status) =>
            status === 'TRUSTED').length,
          revokedStatusCount: visibleStatusCategories.filter((status) =>
            status === 'REVOKED').length,
          queuedStatusCount: visibleStatusCategories.filter((status) =>
            status === 'QUEUED').length,
          conflictedStatusCount: visibleStatusCategories.filter((status) =>
            status === 'CONFLICT').length,
          visibleKnownHostRowLabels: visibleStatusCategories,
        };
      }, `${splitTargetAddress}:${tmuxFixturePort}`).catch(() => ({
        probeAvailable: false,
        panelVisible: false,
        expectedEndpointVisible: false,
        endpointStatus: null,
        trustedStatusCount: 0,
        revokedStatusCount: 0,
        queuedStatusCount: 0,
        conflictedStatusCount: 0,
        visibleKnownHostRowLabels: [],
      }));
      const knownHostProjectionValid = knownHostProjection.probeAvailable &&
        knownHostProjection.panelVisible &&
        knownHostProjection.expectedEndpointVisible &&
        knownHostProjection.trustedStatusCount >= 1 &&
        knownHostProjection.visibleKnownHostRowLabels.length >= 1 &&
        knownHostProjection.visibleKnownHostRowLabels.every((status) =>
          status === 'TRUSTED') &&
        knownHostProjection.revokedStatusCount === 0 &&
        knownHostProjection.queuedStatusCount === 0 &&
        knownHostProjection.conflictedStatusCount === 0;
      if (!knownHostProjectionValid) {
        stage = `Profile A KnownHost trust projection mismatch (${JSON.stringify(
          knownHostProjection,
        )})`;
        throw new Error('Profile A did not decrypt the committed KnownHost approval as trusted');
      }
      stage = 'Profile A return to Workspaces with verified KnownHost approval';
      await click(pageA, 'Workspaces');
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A Workspaces page after KnownHost verification');

      stage = 'Profile A navigate to Workspaces before tmux Workspace create';
      await click(pageA, 'Workspaces');
      stage = 'Profile A wait for Workspaces before tmux Workspace create';
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A Workspaces page before process-restart create');
      const beforeWorkspace = requireVault('tmux Workspace create baseline');
      const createPushBaseline = workspaceSplitPushes.length;
      const createResponseBaseline = workspaceSplitPushResponses.length;
      captureWorkspaceSplit = true;
      stage = 'Profile A open Save current tabs for tmux Workspace create';
      await click(pageA, 'Save current tabs');
      stage = 'Profile A name tmux process-restart Workspace';
      await fill(pageA, 'Workspace name', TMUX_WORKSPACE_NAME);
      stage = 'Profile A submit tmux process-restart Workspace';
      await click(pageA, 'Save');
      stage = 'Profile A wait for saved tmux process-restart Workspace card';
      await waitForVisibleSemanticText(pageA, TMUX_WORKSPACE_NAME,
        'Profile A saved tmux Workspace card');
      await syncNow(pageA, 'Profile A tmux process-restart Workspace create');
      const createOperation = await waitForWorkspacePush(
        createPushBaseline,
        (operation) => operation.operation === 'create' &&
          operation.recordId && operation.opId && operation.revisionId,
        'Profile A tmux Workspace create operation',
      );
      const workspaceRecordId = createOperation.recordId;
      encryptedWorkspacePrivacyRecordId = workspaceRecordId;
      const createReceipt = await waitForWorkspaceReceipt(
        createResponseBaseline, createOperation,
        'Profile A tmux Workspace create receipt',
      );
      const afterWorkspaceCreate = requireVault('tmux Workspace create commit');
      const createCommit = serverCommitDelta(
        databasePath, vaultId, beforeWorkspace.commitSeq,
        afterWorkspaceCreate.commitSeq,
      );
      const createState = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      assertThat(createCommit.eventCount === 1 &&
        createCommit.distinctCommitCount === 1 &&
        createCommit.events[0]?.operation === 'create' &&
        createCommit.events[0]?.recordId === workspaceRecordId &&
        createReceipt.results.filter((item) => item.opId === createOperation.opId &&
          item.revisionId === createOperation.revisionId).length === 1 &&
        createState.versions.length === 1 && createState.events.length === 1 &&
        createState.receipts.length === 1 && createState.versions[0]?.markersAbsent,
      'tmux Workspace create did not produce one opaque version/event/receipt/head');

      stage = 'Profile A open Terminal to close the Host preflight tab';
      await click(pageA, 'Terminal');
      stage = 'Profile A close authenticated Host preflight tab';
      await click(pageA, 'Disconnect');
      stage = 'Profile A wait for preflight SSH and Relay transport to close';
      const preflightDisconnected = await waitForCaptured(() => {
        const ssh = tmuxSshFixture.server.summary();
        return ssh.tcpConnectionsOpen === preflightSshBaseline.tcpConnectionsOpen &&
          activeRelayWebSockets.A.size === preflightRelayBaseline.activeWebSockets
          ? ssh : null;
      }, 'Profile A tmux Host preflight disconnect');
      assertThat(preflightDisconnected.tcpConnectionsOpen ===
        preflightSshBaseline.tcpConnectionsOpen,
      'preflight SSH transport did not disconnect before Workspace preview');
      stage = 'Profile A return to Workspaces for saved tmux preview';
      await click(pageA, 'Workspaces');
      stage = 'Profile A wait for saved tmux Workspace preview page';
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A Workspaces page before process-restart preview');

      stage = 'Profile A preview saved tmux Workspace without connecting';
      const previewBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        activeWebSockets: activeRelayWebSockets.A.size,
        ssh: tmuxSshFixture.server.summary(),
        tmux: tmuxSshFixture.tmuxSnapshot(),
      };
      const tmuxConnectButtons = await stageSingleWorkspacePreview(
        pageA, TMUX_WORKSPACE_NAME, {
          existingWorkspaceNames: [],
          hostName: HOST_TMUX_NAME,
          profile: 'A',
        },
      );
      assertThat(await tmuxConnectButtons.count() === 1,
        'Profile A preview did not expose one explicit Host Connect action');
      const previewSsh = tmuxSshFixture.server.summary();
      const previewTmux = tmuxSshFixture.tmuxSnapshot();
      assertThat(previewTmux.sessionCount === 0 && previewTmux.clientCount === 0 &&
        previewSsh.tcpConnectionsAccepted ===
          previewBaseline.ssh.tcpConnectionsAccepted &&
        previewSsh.tcpConnectionsOpen === previewBaseline.ssh.tcpConnectionsOpen &&
        relayAttempts.A.length === previewBaseline.tickets &&
        relayWebSockets.A === previewBaseline.webSockets &&
        activeRelayWebSockets.A.size === previewBaseline.activeWebSockets &&
        previewTmux.sessionCount === previewBaseline.tmux.sessionCount &&
        previewTmux.clientCount === previewBaseline.tmux.clientCount,
      'Workspace preview created an SSH/Relay transport or tmux session');

      stage = 'Profile A explicitly Connect to the saved tmux Host';
      const connectSshBaseline = tmuxSshFixture.server.summary();
      const connectRelayBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        closes: relayWebSocketCloses.A,
        activeWebSockets: activeRelayWebSockets.A.size,
      };
      const previewConnectSafeDiagnostic = async () => {
        const ssh = tmuxSshFixture.server.summary();
        const tickets = relayAttempts.A.slice(connectRelayBaseline.tickets);
        const tmux = tmuxSshFixture.tmuxSnapshot();
        const tab = await workspaceTerminalTabDiagnosticSnapshot(
          pageA, HOST_TMUX_NAME,
        );
        const promptState = await pageA.evaluate(() => {
          const visible = (node) => {
            const rect = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none';
          };
          const semantics = [...document.querySelectorAll('flt-semantics')]
            .filter(visible)
            .map((node) => [node.getAttribute('aria-label') || '',
              node.innerText || '', node.textContent || ''].join(' '))
            .join(' ');
          const visibleAlertOrSnackbar = [...document.querySelectorAll(
            '[role="alert"], [role="status"], flt-semantics[role="alert"], flt-semantics[role="status"]',
          )].some(visible);
          return {
            hostKeyPromptVisible: /verify ssh host key|trust after verification/i.test(semantics),
            credentialPromptVisible: /select credential|choose credential|password required|password authentication/i.test(semantics),
            hostKeyConflictVisible: /host key.{0,30}(changed|conflict)/i.test(semantics),
            authenticationFailureVisible: /authentication failed|password rejected|credential unavailable/i.test(semantics),
            visibleAlertOrSnackbar,
          };
        }).catch(() => ({
          hostKeyPromptVisible: false,
          credentialPromptVisible: false,
          hostKeyConflictVisible: false,
          authenticationFailureVisible: false,
          visibleAlertOrSnackbar: false,
          promptProbeAvailable: false,
        }));
        const delta = (key) => ssh[key] - connectSshBaseline[key];
        return {
          relayTicketStatuses: tickets.map((ticket) => ticket.status),
          relayTicketsTargetExact: tickets.length === 2 && tickets.every((ticket) =>
            ticket.targetHost === splitTargetAddress &&
            ticket.targetPort === tmuxFixturePort),
          relayTicketDelta: tickets.length,
          relayWebSocketDelta: relayWebSockets.A - connectRelayBaseline.webSockets,
          relayCloseDelta: relayWebSocketCloses.A - connectRelayBaseline.closes,
          activeRelayWebSocketDelta: activeRelayWebSockets.A.size -
            connectRelayBaseline.activeWebSockets,
          sshPhaseDeltas: {
            tcpAccepted: delta('tcpConnectionsAccepted'),
            tcpClosed: delta('tcpConnectionsClosed'),
            tcpOpen: delta('tcpConnectionsOpen'),
            serverBanner: delta('serverBannerEmitted'),
            clientBanner: delta('clientBannerReceived'),
            keyExchange: delta('keyExchangeStarted'),
            passwordAccepted: delta('passwordAccepted'),
            passwordRejected: delta('passwordRejected'),
            shell: delta('shellSessions'),
            commandSessions: delta('commandSessions'),
          },
          tmuxSessionCount: tmux.sessionCount,
          tmuxClientCount: tmux.clientCount,
          terminal: {
            titleVisible: tab.terminalTitleVisible ?? false,
            tabCount: tab.visibleTerminalTabCount ?? 0,
            expectedHostTabCount: tab.expectedHostTabMatchCount ?? 0,
            expectedHostTabConnectedCount:
              tab.expectedHostTabConnectedCount ?? 0,
            expectedHostTabConnectingCount:
              tab.expectedHostTabConnectingCount ?? 0,
            expectedHostTabFailedCount: tab.expectedHostTabFailedCount ?? 0,
            runtimeCount: tab.matchingRuntimeCount ?? 0,
            runtimeConnectedCount: tab.matchingRuntimeConnectedCount ?? 0,
            runtimeConnectingCount: tab.matchingRuntimeConnectingCount ?? 0,
          },
          ...promptState,
        };
      };
      stage = 'Profile A click saved tmux preview Connect action';
      try {
        await tmuxConnectButtons.first().click();
      } catch (_) {
        stage = `Profile A click saved tmux preview Connect action (${JSON.stringify(
          await previewConnectSafeDiagnostic(),
        )})`;
        throw new Error('saved Workspace Connect action failed');
      }
      stage = 'Profile A wait for the second explicit Workspace Connect Relay ticket';
      let connectTickets;
      try {
        connectTickets = await waitForCaptured(() => {
          const tickets = relayAttempts.A.slice(connectRelayBaseline.tickets);
          return tickets.length >= 2 && tickets.every((ticket) =>
            ticket.status !== null) ? tickets : null;
        }, 'Profile A second Workspace explicit Connect Relay ticket');
      } catch (_) {
        stage = `Profile A wait for second Workspace Connect Relay ticket (${JSON.stringify(
          await previewConnectSafeDiagnostic(),
        )})`;
        throw new Error('Workspace Connect did not complete both Relay phases');
      }
      stage = 'Profile A wait for explicit Workspace Connect SSH transport';
      let connectedSsh;
      try {
        connectedSsh = await waitForCaptured(() => {
          const ssh = tmuxSshFixture.server.summary();
          const connections = ssh.connections || [];
          return connections.length >= connectSshBaseline.connections.length + 2 &&
            ssh.tcpConnectionsAccepted ===
              connectSshBaseline.tcpConnectionsAccepted + 2 &&
            ssh.passwordAccepted === connectSshBaseline.passwordAccepted + 1 &&
            ssh.shellSessions === connectSshBaseline.shellSessions + 1 &&
            activeRelayWebSockets.A.size === connectRelayBaseline.activeWebSockets + 1
            ? ssh : null;
        }, 'Profile A Workspace explicit Connect SSH transport');
      } catch (_) {
        stage = `Profile A wait for explicit Workspace Connect SSH transport (${JSON.stringify(
          await previewConnectSafeDiagnostic(),
        )})`;
        throw new Error('Workspace Connect did not reach authenticated SSH');
      }
      const connectAttemptPhases = connectedSsh.connections
        .slice(connectSshBaseline.connections.length);
      await waitForCaptured(() =>
        activeRelayWebSockets.A.size === connectRelayBaseline.activeWebSockets + 1 &&
          relayWebSockets.A === connectRelayBaseline.webSockets + 2 &&
          relayWebSocketCloses.A === connectRelayBaseline.closes + 1 &&
          connectTickets.length === 2 &&
          connectTickets.every((ticket) => ticket.status !== null),
      'Profile A two Workspace Relay WebSockets, one closed preflight socket, one active socket');
      const connectedTmuxBeforeStart = tmuxSshFixture.tmuxSnapshot();
      stage = 'Profile A verify exact two-phase Workspace Connect Relay targets';
      const exactWorkspaceConnectTickets = connectTickets.length === 2 &&
        connectTickets.every((ticket) => ticket.status === 200 &&
          ticket.targetHost === splitTargetAddress &&
          ticket.targetPort === tmuxFixturePort);
      if (!exactWorkspaceConnectTickets) {
        stage = `Profile A Workspace Connect Relay ticket targets invalid (${JSON.stringify(
          await previewConnectSafeDiagnostic(),
        )})`;
        throw new Error('Workspace Connect Relay targets did not match the fixture');
      }
      stage = 'Profile A validate exact two-phase SSH and Relay deltas';
      const explicitConnectAccepted = connectedSsh.keyExchangeStarted >
          connectSshBaseline.keyExchangeStarted &&
        connectedSsh.tcpConnectionsAccepted ===
          connectSshBaseline.tcpConnectionsAccepted + 2 &&
        connectedSsh.tcpConnectionsClosed ===
          connectSshBaseline.tcpConnectionsClosed + 1 &&
        connectedSsh.tcpConnectionsOpen ===
          connectSshBaseline.tcpConnectionsOpen + 1 &&
        connectedSsh.serverBannerEmitted ===
          connectSshBaseline.serverBannerEmitted + 2 &&
        connectedSsh.clientBannerReceived ===
          connectSshBaseline.clientBannerReceived + 2 &&
        connectedSsh.passwordAccepted === connectSshBaseline.passwordAccepted + 1 &&
        connectedSsh.passwordRejected === connectSshBaseline.passwordRejected &&
        connectedSsh.shellSessions === connectSshBaseline.shellSessions + 1 &&
        connectAttemptPhases.length === 2 &&
        connectAttemptPhases[0].accepted && connectAttemptPhases[0].closed &&
        connectAttemptPhases[0].passwordAccepted === 0 &&
        connectAttemptPhases[0].passwordRejected === 0 &&
        connectAttemptPhases[0].shellSessions === 0 &&
        connectAttemptPhases[1].accepted && !connectAttemptPhases[1].closed &&
        connectAttemptPhases[1].passwordAccepted === 1 &&
        connectAttemptPhases[1].passwordRejected === 0 &&
        connectAttemptPhases[1].shellSessions === 1 &&
        relayAttempts.A.length === connectRelayBaseline.tickets + 2 &&
        relayWebSockets.A === connectRelayBaseline.webSockets + 2 &&
        relayWebSocketCloses.A === connectRelayBaseline.closes + 1 &&
        activeRelayWebSockets.A.size === connectRelayBaseline.activeWebSockets + 1 &&
        connectedTmuxBeforeStart.sessionCount === 0 &&
        connectedTmuxBeforeStart.clientCount === 0;
      if (!explicitConnectAccepted) {
        stage = `Profile A validate two-phase Workspace Connect deltas (${JSON.stringify(
          await previewConnectSafeDiagnostic(),
        )})`;
        throw new Error('explicit Workspace Connect transport deltas were unexpected');
      }
      stage = 'Profile A assert no HostKey, credential or authentication prompt after Workspace Connect';
      const connectPromptState = await pageA.evaluate(() => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none' &&
            Number(style.opacity || 1) > 0;
        };
        const text = [...document.querySelectorAll('flt-semantics')]
          .filter(visible)
          .map((node) => [node.getAttribute('aria-label') || '',
            node.innerText || '', node.textContent || ''].join(' '))
          .join(' ');
        return {
          hostKeyPrompt: /verify ssh host key|trust after verification/i.test(text),
          credentialPrompt: /select credential|choose credential|password required|password authentication/i.test(text),
          hostKeyConflict: /host key.{0,30}(changed|conflict)/i.test(text),
          authenticationFailure: /authentication failed|password rejected|credential unavailable/i.test(text),
          visiblePasswordInputCount:
            [...document.querySelectorAll('input[type="password"]')].filter(visible).length,
        };
      });
      const trustPromptCount = await pageA.getByRole('button', {
        name: 'Trust after verification', exact: true,
      }).count();
      if (trustPromptCount !== 0 || connectPromptState.hostKeyPrompt ||
          connectPromptState.credentialPrompt || connectPromptState.hostKeyConflict ||
          connectPromptState.authenticationFailure ||
          connectPromptState.visiblePasswordInputCount !== 0) {
        stage = `Profile A Workspace Connect left a trust/credential/auth prompt (${JSON.stringify({
          trustPromptCount,
          ...connectPromptState,
        })})`;
        throw new Error('Workspace Connect left a trust or authentication prompt visible');
      }
      stage = 'Profile A verify one connected Workspace terminal runtime';
      const connectedRuntimeSnapshot = await workspaceTerminalRuntimeSnapshot(
        pageA, [HOST_TMUX_NAME],
      );
      assertThat(connectedRuntimeSnapshot.length === 1 &&
        connectedRuntimeSnapshot[0]?.count === 1 &&
        connectedRuntimeSnapshot[0]?.connectedCount === 1 &&
        connectedRuntimeSnapshot[0]?.connectingCount === 0 &&
        connectedRuntimeSnapshot[0]?.failedCount === 0,
      'Workspace Connect did not leave exactly one connected tmux terminal runtime');
      stage = 'Profile A sync known Host after Workspace Connect';
      await syncNow(pageA, 'Profile A tmux KnownHost approval after Workspace Connect');

      stage = 'Profile A explicitly Start tmux and sync the encrypted descriptor';
      const startAction = pageA.getByRole('button', {
        name: 'Start resumable session', exact: true,
      });
      assertThat(await startAction.count() === 1 && await startAction.isVisible(),
        'connected Workspace pane did not expose exactly one tmux Start action');
      await startAction.click();
      await waitForText(pageA, 'Start resumable tmux session?');
      const tmuxStartVault = requireVault('tmux descriptor update baseline');
      const updatePushBaseline = workspaceSplitPushes.length;
      const updateResponseBaseline = workspaceSplitPushResponses.length;
      await click(pageA, 'Start session');
      const tmuxStarted = await waitForTmuxState(
        tmuxSshFixture,
        (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 1 &&
          snapshot.sessions[0]?.attachedClientCount === 1,
        'one tmux session attached to Profile A',
        20000,
      );
      const tmuxSessionId = tmuxStarted.sessions[0]?.sessionId;
      const tmuxSessionName = tmuxStarted.sessions[0]?.name;
      assertThat(typeof tmuxSessionId === 'string' &&
        /^atermius_[0-9a-f]{32}$/.test(tmuxSessionName),
      'Profile A Start did not create the expected fixed-format tmux session');
      PRIVACY_MARKERS.push(tmuxSessionName);
      const canaryBeforeRestart = tmuxSshFixture.tmuxPrivacyMarkerSnapshot(
        tmuxSessionName, TMUX_COMMAND_MARKER, TMUX_OUTPUT_MARKER,
      );
      assertThat(canaryBeforeRestart.commandMarkerVisible &&
        canaryBeforeRestart.outputMarkerVisible,
      'tmux session did not retain the run-scoped command/output canary');
      await waitForVisibleSemanticText(pageA, 'Resume tmux session',
        'Profile A saved tmux descriptor Resume action');
      await syncNow(pageA, 'Profile A tmux encrypted descriptor update');
      const updateOperation = await waitForWorkspacePush(
        updatePushBaseline,
        (operation) => operation.operation === 'update' &&
          operation.recordId === workspaceRecordId && operation.opId &&
          operation.revisionId,
        'Profile A tmux descriptor update operation',
      );
      const updateReceipt = await waitForWorkspaceReceipt(
        updateResponseBaseline, updateOperation,
        'Profile A tmux descriptor update receipt',
      );
      const afterDescriptor = requireVault('tmux descriptor update commit');
      const workspaceCommit = serverCommitDelta(
        databasePath, vaultId, beforeWorkspace.commitSeq,
        afterDescriptor.commitSeq,
      );
      const workspaceStateBeforeRestart = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      assertThat(workspaceCommit.eventCount === 2 &&
        workspaceCommit.distinctCommitCount === 2 &&
        workspaceCommit.events.map((item) => item.operation).join(',') === 'create,update' &&
        workspaceCommit.events.every((item) => item.recordId === workspaceRecordId) &&
        workspaceStateBeforeRestart.versions.length === 2 &&
        workspaceStateBeforeRestart.events.length === 2 &&
        workspaceStateBeforeRestart.receipts.length === 2 &&
        workspaceStateBeforeRestart.headRevisionId === updateOperation.revisionId &&
        workspaceStateBeforeRestart.versions.every((item) => item.markersAbsent) &&
        createOperation.deviceId &&
        createOperation.deviceId === updateOperation.deviceId &&
        updateReceipt.results.some((item) => item.opId === updateOperation.opId &&
          item.revisionId === updateOperation.revisionId),
      'tmux Workspace create/descriptor did not form one same-device encrypted ledger');
      const committedPushCountBeforeRestart = workspaceSplitPushes.length;
      const secureStoreBeforeKill = await safeSecureStorePresence(pageA, baseUrl);
      const pendingBeforeKill = await visibleSyncPendingSnapshot(pageA);
      assertThat(secureStoreBeforeKill.expectedOrigin &&
        secureStoreBeforeKill.deviceRecordPresent &&
        secureStoreBeforeKill.deviceStoreFingerprint &&
        pendingBeforeKill.pendingCount === 0,
      'same-profile pre-kill device identity or durable outbox baseline was unavailable');

      stage = 'settle and release the tmux Workspace app storage binding';
      await pageA.waitForTimeout(15000);
      const localStorageBeforeUnbind = localStorageLevelDbFingerprint(
        tmuxRestartProfileDir,
      );
      await pageA.goto('about:blank', { waitUntil: 'load', timeout: 10000 });
      const appUnbind = await waitForLocalStorageLevelDbStable(
        tmuxRestartProfileDir, localStorageBeforeUnbind,
      );
      const detachedTmux = await waitForTmuxState(
        tmuxSshFixture,
        (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 0 &&
          snapshot.sessions[0]?.sessionId === tmuxSessionId,
        'the original tmux session detached from Profile A',
        15000,
      );
      await waitForCaptured(() =>
        activeRelayWebSockets.A.size === 0 &&
          tmuxSshFixture.server.summary().tcpConnectionsOpen === 0
          ? true : null,
      'Profile A transport closed at app-page unbind');
      assertThat(pageA.url() === 'about:blank' && appUnbind.stable &&
        detachedTmux.sessionCount === 1 && detachedTmux.clientCount === 0,
      'same-origin storage unbind did not leave the tmux session alive and detached');
      console.log('WEB-WORKSPACE-TMUX-RESTART-STORAGE-UNBIND', JSON.stringify({
        navigatedToBlank: true,
        changed: appUnbind.changed,
        stable: appUnbind.stable,
        deviceRecordPresentBeforeKill: true,
        tmuxSessionPreserved: detachedTmux.sessionCount === 1,
        tmuxClientCountAfterUnbind: detachedTmux.clientCount,
      }));

      stage = 'confirm same-origin secure-store/device identity before SIGKILL';
      const storageProbe = await contextA.newPage();
      await storageProbe.goto(`${baseUrl}/health/ready`, {
        waitUntil: 'domcontentloaded', timeout: 10000,
      });
      const secureStoreAfterUnbind = await safeSecureStorePresence(storageProbe, baseUrl);
      assertThat(secureStoreAfterUnbind.expectedOrigin &&
        secureStoreAfterUnbind.deviceRecordPresent &&
        secureStoreAfterUnbind.deviceStoreFingerprint ===
          secureStoreBeforeKill.deviceStoreFingerprint,
      'same-origin storage unbind changed or lost the Profile A device key');
      const probeFingerprint = localStorageLevelDbFingerprint(tmuxRestartProfileDir);
      await storageProbe.goto('about:blank', { waitUntil: 'load', timeout: 10000 });
      const probeUnbind = await waitForLocalStorageLevelDbStable(
        tmuxRestartProfileDir, probeFingerprint,
      );
      assertThat(probeUnbind.stable,
        'same-origin secure-store probe did not release its LevelDB binding');

      const serverBeforeRestart = requireVault('pre-SIGKILL server ledger');
      const workspaceBeforeRestart = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      assertThat(serverBeforeRestart.commitSeq === afterDescriptor.commitSeq &&
        stableJson(workspaceBeforeRestart) === stableJson(workspaceStateBeforeRestart) &&
        workspaceSplitPushes.length === committedPushCountBeforeRestart,
      'server Workspace ledger or pending pushes changed before Chromium SIGKILL');
      const oldChromiumIdentity = chromiumProfileProcessIdentity(tmuxRestartProfileDir);
      stage = 'SIGKILL isolated persistent Profile A Chromium process group';
      process.kill(-oldChromiumIdentity.processGroup, 'SIGKILL');
      const oldProcessGroupExit = await waitForProcessGroupExit(
        oldChromiumIdentity.processGroup, 5000,
      );
      const oldProfileChromiumProcessesClearedAfterSigkill =
        !chromiumProfileHasLiveProcesses(tmuxRestartProfileDir);
      assertThat(oldProcessGroupExit.exited &&
        oldProfileChromiumProcessesClearedAfterSigkill,
      'SIGKILL did not stop the entire isolated Profile A Chromium process tree');
      const oldPersistentContext = contextA;
      closedContexts.add(oldPersistentContext);
      contextA = null;
      pageA = null;
      const restartNoAutoBaseline = {
        relayTickets: relayAttempts.A.length,
        relayWebSockets: relayWebSockets.A,
        relayCloses: relayWebSocketCloses.A,
        ssh: tmuxSshFixture.server.summary(),
        tmux: tmuxSshFixture.tmuxSnapshot(),
        pushCount: workspaceSplitPushes.length,
        vault: requireVault('server ledger at process exit'),
      };
      assertThat(restartNoAutoBaseline.tmux.sessionCount === 1 &&
        restartNoAutoBaseline.tmux.clientCount === 0 &&
        restartNoAutoBaseline.tmux.sessions[0]?.sessionId === tmuxSessionId &&
        restartNoAutoBaseline.ssh.tcpConnectionsOpen === 0,
      'hard Chromium termination did not preserve the detached remote tmux session');

      stage = 'relaunch persistent Profile A at the exact same profile directory';
      const restartOptions = {
        headless: true,
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
        locale: 'en-US',
        viewport: { width: 1440, height: 1000 },
      };
      if (CHROMIUM_EXECUTABLE) restartOptions.executablePath = CHROMIUM_EXECUTABLE;
      contextA = await chromium.launchPersistentContext(
        tmuxRestartProfileDir, restartOptions,
      );
      await contextA.grantPermissions(['clipboard-read', 'clipboard-write'], {
        origin: baseUrl,
      });
      const restartedChromiumIdentity = chromiumProfileProcessIdentity(
        tmuxRestartProfileDir,
      );
      assertThat(restartedChromiumIdentity.pid !== oldChromiumIdentity.pid &&
        restartedChromiumIdentity.startTimeTicks !== oldChromiumIdentity.startTimeTicks,
      'persistent profile restart reused the terminated Chromium process');
      pageA = contextA.pages()[0] || await contextA.newPage();
      attachDiagnostics(pageA, 'A');
      await pageA.goto(baseUrl, { waitUntil: 'domcontentloaded' });
      const storageOnRestartDocument = await safeSecureStorePresence(pageA, baseUrl);
      assertThat(storageOnRestartDocument.expectedOrigin &&
        storageOnRestartDocument.deviceRecordPresent &&
        storageOnRestartDocument.deviceStoreFingerprint ===
          secureStoreBeforeKill.deviceStoreFingerprint,
      'same-profile Web startup did not retain the original device identity');
      stage = 'Profile A reauthenticate/unlock after Chromium process restart';
      const reauth = await restoreWorkspaceAfterReload(pageA, 'A', baseUrl);
      const storageAfterReauth = await safeSecureStorePresence(pageA, baseUrl);
      assertThat((reauth.submittedLogin || reauth.submittedUnlock) &&
        storageAfterReauth.deviceRecordPresent &&
        storageAfterReauth.deviceStoreFingerprint ===
          secureStoreBeforeKill.deviceStoreFingerprint,
      'Profile A did not reauthenticate with its original stored device identity');
      const pendingAfterReauth = await visibleSyncPendingSnapshot(pageA);
      const ledgerAfterReauth = requireVault('post-reauth Workspace ledger');
      const workspaceAfterReauth = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      const tmuxAfterReauth = tmuxSshFixture.tmuxSnapshot();
      assertThat(ledgerAfterReauth.commitSeq === afterDescriptor.commitSeq &&
        stableJson(workspaceAfterReauth) === stableJson(workspaceStateBeforeRestart) &&
        workspaceSplitPushes.length === restartNoAutoBaseline.pushCount &&
        pendingAfterReauth.pendingCount === 0 &&
        tmuxAfterReauth.sessionCount === 1 && tmuxAfterReauth.clientCount === 0 &&
        tmuxAfterReauth.sessions[0]?.sessionId === tmuxSessionId &&
        relayAttempts.A.length === restartNoAutoBaseline.relayTickets &&
        relayWebSockets.A === restartNoAutoBaseline.relayWebSockets &&
        activeRelayWebSockets.A.size === 0 &&
        tmuxSshFixture.server.summary().tcpConnectionsAccepted ===
          restartNoAutoBaseline.ssh.tcpConnectionsAccepted &&
        tmuxSshFixture.server.summary().keyExchangeStarted ===
          restartNoAutoBaseline.ssh.keyExchangeStarted &&
        tmuxSshFixture.server.summary().passwordAccepted ===
          restartNoAutoBaseline.ssh.passwordAccepted &&
        tmuxSshFixture.server.summary().shellSessions ===
          restartNoAutoBaseline.ssh.shellSessions,
      'same-profile reauth caused a duplicate push or automatic SSH/Relay/tmux attach');

      stage = 'Profile A reopen the saved Workspace preview without auto-connect';
      await click(pageA, 'Workspaces');
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A saved Workspace list after process restart');
      const restartPreviewRelayBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        activeWebSockets: activeRelayWebSockets.A.size,
        ssh: tmuxSshFixture.server.summary(),
      };
      const restartConnectButtons = await stageSingleWorkspacePreview(
        pageA, TMUX_WORKSPACE_NAME, {
          existingWorkspaceNames: [],
          hostName: HOST_TMUX_NAME,
          profile: 'A-restarted',
        },
      );
      const tmuxBeforeRestartConnect = tmuxSshFixture.tmuxSnapshot();
      let restartPendingBeforeConnect = await visibleSyncPendingSnapshot(pageA);
      const restartPendingDeadline = Date.now() + 10000;
      while (restartPendingBeforeConnect.pendingCount !== 0 &&
          Date.now() < restartPendingDeadline) {
        await pageA.waitForTimeout(200);
        restartPendingBeforeConnect = await visibleSyncPendingSnapshot(pageA);
      }
      const restartPreviewAfterStage = {
        connectActionCount: await restartConnectButtons.count(),
        tmux: tmuxBeforeRestartConnect,
        pendingCount: restartPendingBeforeConnect.pendingCount,
        pendingControlCount: restartPendingBeforeConnect.controlCount,
        pendingLabel: restartPendingBeforeConnect.label,
        relayTicketDelta: relayAttempts.A.length - restartPreviewRelayBaseline.tickets,
        relayWebSocketDelta: relayWebSockets.A - restartPreviewRelayBaseline.webSockets,
        activeRelayWebSocketDelta: activeRelayWebSockets.A.size -
          restartPreviewRelayBaseline.activeWebSockets,
        ssh: tmuxSshFixture.server.summary(),
        pushDelta: workspaceSplitPushes.length - restartNoAutoBaseline.pushCount,
      };
      restartPreviewAfterStage.noAutoAttachOrPush =
        restartPreviewAfterStage.connectActionCount === 1 &&
        tmuxBeforeRestartConnect.sessionCount === 1 &&
        tmuxBeforeRestartConnect.clientCount === 0 &&
        tmuxBeforeRestartConnect.sessions[0]?.sessionId === tmuxSessionId &&
        restartPendingBeforeConnect.pendingCount === 0 &&
        relayAttempts.A.length === restartPreviewRelayBaseline.tickets &&
        relayWebSockets.A === restartPreviewRelayBaseline.webSockets &&
        activeRelayWebSockets.A.size === restartPreviewRelayBaseline.activeWebSockets &&
        tmuxSshFixture.server.summary().tcpConnectionsAccepted ===
          restartPreviewRelayBaseline.ssh.tcpConnectionsAccepted &&
        tmuxSshFixture.server.summary().tcpConnectionsOpen ===
          restartPreviewRelayBaseline.ssh.tcpConnectionsOpen &&
        tmuxSshFixture.server.summary().keyExchangeStarted ===
          restartPreviewRelayBaseline.ssh.keyExchangeStarted &&
        tmuxSshFixture.server.summary().passwordAccepted ===
          restartPreviewRelayBaseline.ssh.passwordAccepted &&
        tmuxSshFixture.server.summary().shellSessions ===
          restartPreviewRelayBaseline.ssh.shellSessions &&
        workspaceSplitPushes.length === restartNoAutoBaseline.pushCount;
      console.log('WEB-WORKSPACE-TMUX-RESTART-PREVIEW-NO-AUTO', JSON.stringify({
        ...restartPreviewAfterStage,
        pendingCount: restartPreviewAfterStage.pendingCount,
        pendingControlCount: restartPreviewAfterStage.pendingControlCount,
        pendingLabel: restartPreviewAfterStage.pendingLabel,
        tmux: {
          sessionCount: restartPreviewAfterStage.tmux.sessionCount,
          clientCount: restartPreviewAfterStage.tmux.clientCount,
          sameSession: restartPreviewAfterStage.tmux.sessions[0]?.sessionId ===
            tmuxSessionId,
        },
        ssh: {
          tcpConnectionsAccepted: restartPreviewAfterStage.ssh.tcpConnectionsAccepted -
            restartPreviewRelayBaseline.ssh.tcpConnectionsAccepted,
          tcpConnectionsOpen: restartPreviewAfterStage.ssh.tcpConnectionsOpen -
            restartPreviewRelayBaseline.ssh.tcpConnectionsOpen,
          keyExchangeStarted: restartPreviewAfterStage.ssh.keyExchangeStarted -
            restartPreviewRelayBaseline.ssh.keyExchangeStarted,
          passwordAccepted: restartPreviewAfterStage.ssh.passwordAccepted -
            restartPreviewRelayBaseline.ssh.passwordAccepted,
          shellSessions: restartPreviewAfterStage.ssh.shellSessions -
            restartPreviewRelayBaseline.ssh.shellSessions,
        },
      }));
      stage = `Profile A-restarted assert Workspace preview has no automatic attach (${JSON.stringify({
        connectActionCount: restartPreviewAfterStage.connectActionCount,
        pendingCount: restartPreviewAfterStage.pendingCount,
        pendingControlCount: restartPreviewAfterStage.pendingControlCount,
        pendingLabel: restartPreviewAfterStage.pendingLabel,
        relayTicketDelta: restartPreviewAfterStage.relayTicketDelta,
        relayWebSocketDelta: restartPreviewAfterStage.relayWebSocketDelta,
        activeRelayWebSocketDelta: restartPreviewAfterStage.activeRelayWebSocketDelta,
        ssh: {
          tcpConnectionsAccepted: restartPreviewAfterStage.ssh.tcpConnectionsAccepted -
            restartPreviewRelayBaseline.ssh.tcpConnectionsAccepted,
          tcpConnectionsOpen: restartPreviewAfterStage.ssh.tcpConnectionsOpen -
            restartPreviewRelayBaseline.ssh.tcpConnectionsOpen,
          keyExchangeStarted: restartPreviewAfterStage.ssh.keyExchangeStarted -
            restartPreviewRelayBaseline.ssh.keyExchangeStarted,
          passwordAccepted: restartPreviewAfterStage.ssh.passwordAccepted -
            restartPreviewRelayBaseline.ssh.passwordAccepted,
          shellSessions: restartPreviewAfterStage.ssh.shellSessions -
            restartPreviewRelayBaseline.ssh.shellSessions,
        },
        tmux: {
          sessionCount: restartPreviewAfterStage.tmux.sessionCount,
          clientCount: restartPreviewAfterStage.tmux.clientCount,
          sameSession: restartPreviewAfterStage.tmux.sessions[0]?.sessionId ===
            tmuxSessionId,
        },
        pushDelta: restartPreviewAfterStage.pushDelta,
      })})`;
      assertThat(restartPreviewAfterStage.noAutoAttachOrPush,
      'saved Workspace preview attached to SSH/tmux or generated a sync push');

      stage = 'Profile A explicitly Connect to the restored tmux Workspace';
      const restartConnectSshBaseline = tmuxSshFixture.server.summary();
      const restartConnectTransportBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        closes: relayWebSocketCloses.A,
        activeWebSockets: activeRelayWebSockets.A.size,
      };
      const restartConnectFailureDiagnostic = async (phase, error) => {
        const ssh = tmuxSshFixture.server.summary();
        const tickets = relayAttempts.A.slice(restartConnectTransportBaseline.tickets);
        const [runtime, promptState] = await Promise.all([
          workspaceTerminalRuntimeSnapshot(pageA, [HOST_TMUX_NAME])
            .catch(() => []),
          pageA.evaluate(() => {
            const visible = (node) => {
              const rect = node.getBoundingClientRect();
              const style = getComputedStyle(node);
              return rect.width > 0 && rect.height > 0 &&
                style.visibility !== 'hidden' && style.display !== 'none' &&
                Number(style.opacity || 1) > 0;
            };
            const text = [...document.querySelectorAll('flt-semantics')]
              .filter(visible)
              .map((node) => [node.getAttribute('aria-label') || '',
                node.innerText || '', node.textContent || ''].join(' '))
              .join(' ');
            return {
              trustPromptVisible: /verify ssh host key|trust after verification/i.test(text),
              credentialPromptVisible:
                /select credential|choose credential|password required|password authentication/i.test(text),
              visiblePasswordInputCount:
                [...document.querySelectorAll('input[type="password"]')].filter(visible).length,
              hostKeyConflictVisible: /host key.{0,30}(changed|conflict)/i.test(text),
              authenticationFailureVisible:
                /authentication failed|password rejected|credential unavailable/i.test(text),
              visibleAlertCount: [...document.querySelectorAll('[role="alert"], [aria-live]')]
                .filter(visible).length,
            };
          }).catch(() => ({ snapshotAvailable: false })),
        ]);
        const tmux = tmuxSshFixture.tmuxSnapshot();
        console.error(`WEB-WORKSPACE-TMUX-RESTART-CONNECT-FAILURE ${JSON.stringify({
          phase,
          errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
          relay: {
            ticketCount: tickets.length,
            tickets: tickets.map((ticket) => ({
              status: ticket.status,
              exactFixtureTarget: ticket.targetHost === splitTargetAddress &&
                ticket.targetPort === tmuxFixturePort,
            })),
            webSocketDelta: relayWebSockets.A - restartConnectTransportBaseline.webSockets,
            closeDelta: relayWebSocketCloses.A - restartConnectTransportBaseline.closes,
            activeWebSocketDelta: activeRelayWebSockets.A.size -
              restartConnectTransportBaseline.activeWebSockets,
          },
          ssh: {
            tcpAcceptedDelta: ssh.tcpConnectionsAccepted -
              restartConnectSshBaseline.tcpConnectionsAccepted,
            tcpClosedDelta: ssh.tcpConnectionsClosed -
              restartConnectSshBaseline.tcpConnectionsClosed,
            tcpOpenDelta: ssh.tcpConnectionsOpen -
              restartConnectSshBaseline.tcpConnectionsOpen,
            serverBannerDelta: ssh.serverBannerEmitted -
              restartConnectSshBaseline.serverBannerEmitted,
            clientBannerDelta: ssh.clientBannerReceived -
              restartConnectSshBaseline.clientBannerReceived,
            keyExchangeDelta: ssh.keyExchangeStarted -
              restartConnectSshBaseline.keyExchangeStarted,
            passwordAcceptedDelta: ssh.passwordAccepted -
              restartConnectSshBaseline.passwordAccepted,
            passwordRejectedDelta: ssh.passwordRejected -
              restartConnectSshBaseline.passwordRejected,
            shellSessionDelta: ssh.shellSessions -
              restartConnectSshBaseline.shellSessions,
            commandSessionDelta: ssh.commandSessions -
              restartConnectSshBaseline.commandSessions,
            connectionPhases: (ssh.connections || [])
              .slice(restartConnectSshBaseline.connections?.length || 0)
              .map((connection) => ({
                accepted: connection.accepted,
                closed: connection.closed,
                passwordAccepted: connection.passwordAccepted,
                passwordRejected: connection.passwordRejected,
                shellSessions: connection.shellSessions,
              })),
          },
          tmux: {
            sessionCount: tmux.sessionCount,
            clientCount: tmux.clientCount,
            sameSession: tmux.sessions[0]?.sessionId === tmuxSessionId,
          },
          runtime: runtime[0] || { count: 0, connectingCount: 0,
            connectedCount: 0, failedCount: 0 },
          promptState,
        })}`);
      };
      await restartConnectButtons.first().click();
      stage = 'Profile A-restarted wait for first explicit Workspace Connect Relay ticket';
      let restartFirstConnectTicket;
      try {
        restartFirstConnectTicket = await waitForCaptured(() => {
          const ticket = relayAttempts.A[restartConnectTransportBaseline.tickets];
          return ticket?.status !== null ? ticket : null;
        }, 'restarted Profile A first explicit Connect Relay ticket');
      } catch (error) {
        await restartConnectFailureDiagnostic('first_relay_ticket', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for first host-key-only SSH connection';
      let restartHostKeyOnlyConnection;
      try {
        restartHostKeyOnlyConnection = await waitForCaptured(() => {
          const connections = tmuxSshFixture.server.summary().connections || [];
          const attempts = connections.slice(restartConnectSshBaseline.connections.length);
          return attempts[0]?.accepted && attempts[0]?.closed ? attempts[0] : null;
        }, 'restarted Profile A closed host-key-only SSH connection');
      } catch (error) {
        await restartConnectFailureDiagnostic('hostkey_only_connection', error);
        throw error;
      }
      assertThat(restartFirstConnectTicket.status === 200 &&
        restartFirstConnectTicket.targetHost === splitTargetAddress &&
        restartFirstConnectTicket.targetPort === tmuxFixturePort &&
        restartHostKeyOnlyConnection.passwordAccepted === 0 &&
        restartHostKeyOnlyConnection.passwordRejected === 0 &&
        restartHostKeyOnlyConnection.shellSessions === 0,
      'restart Workspace Connect first phase did not end after host-key proof');
      stage = 'Profile A-restarted wait for second explicit Workspace Connect Relay ticket';
      let restartConnectTickets;
      try {
        restartConnectTickets = await waitForCaptured(() => {
          const tickets = relayAttempts.A.slice(restartConnectTransportBaseline.tickets);
          return tickets.length >= 2 && tickets.every((ticket) => ticket.status !== null)
            ? tickets : null;
        }, 'restarted Profile A second explicit Connect Relay ticket');
      } catch (error) {
        await restartConnectFailureDiagnostic('second_relay_ticket', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for authenticated Workspace SSH';
      let restartConnectedSsh;
      try {
        restartConnectedSsh = await waitForCaptured(() => {
          const ssh = tmuxSshFixture.server.summary();
          const connections = (ssh.connections || [])
            .slice(restartConnectSshBaseline.connections.length);
          return connections.length >= 2 &&
            ssh.passwordAccepted === restartConnectSshBaseline.passwordAccepted + 1 &&
            ssh.shellSessions === restartConnectSshBaseline.shellSessions + 1
            ? ssh : null;
        }, 'restarted Profile A authenticated Workspace SSH');
      } catch (error) {
        await restartConnectFailureDiagnostic('ssh_auth', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for two Workspace Relay sockets';
      try {
        await waitForCaptured(() => relayWebSockets.A ===
          restartConnectTransportBaseline.webSockets + 2 &&
          relayWebSocketCloses.A === restartConnectTransportBaseline.closes + 1 &&
          activeRelayWebSockets.A.size ===
            restartConnectTransportBaseline.activeWebSockets + 1,
        'restarted Profile A two Relay sockets, one close, one active');
      } catch (error) {
        await restartConnectFailureDiagnostic('relay_websocket', error);
        throw error;
      }
      const restartConnectPhases = restartConnectedSsh.connections
        .slice(restartConnectSshBaseline.connections.length);
      const tmuxBeforeResume = tmuxSshFixture.tmuxSnapshot();
      const restartConnectExactTransport = restartConnectTickets.length === 2 &&
        restartConnectTickets.every((ticket) => ticket.status === 200 &&
          ticket.targetHost === splitTargetAddress && ticket.targetPort === tmuxFixturePort) &&
        restartConnectedSsh.keyExchangeStarted >
          restartConnectSshBaseline.keyExchangeStarted &&
        restartConnectedSsh.tcpConnectionsAccepted ===
          restartConnectSshBaseline.tcpConnectionsAccepted + 2 &&
        restartConnectedSsh.tcpConnectionsClosed ===
          restartConnectSshBaseline.tcpConnectionsClosed + 1 &&
        restartConnectedSsh.tcpConnectionsOpen ===
          restartConnectSshBaseline.tcpConnectionsOpen + 1 &&
        restartConnectedSsh.serverBannerEmitted ===
          restartConnectSshBaseline.serverBannerEmitted + 2 &&
        restartConnectedSsh.clientBannerReceived ===
          restartConnectSshBaseline.clientBannerReceived + 2 &&
        restartConnectedSsh.passwordAccepted ===
          restartConnectSshBaseline.passwordAccepted + 1 &&
        restartConnectedSsh.passwordRejected ===
          restartConnectSshBaseline.passwordRejected &&
        restartConnectedSsh.shellSessions ===
          restartConnectSshBaseline.shellSessions + 1 &&
        restartConnectPhases.length === 2 &&
        restartConnectPhases[0].accepted && restartConnectPhases[0].closed &&
        restartConnectPhases[0].passwordAccepted === 0 &&
        restartConnectPhases[0].passwordRejected === 0 &&
        restartConnectPhases[0].shellSessions === 0 &&
        restartConnectPhases[1].accepted && !restartConnectPhases[1].closed &&
        restartConnectPhases[1].passwordAccepted === 1 &&
        restartConnectPhases[1].passwordRejected === 0 &&
        restartConnectPhases[1].shellSessions === 1 &&
        relayWebSockets.A === restartConnectTransportBaseline.webSockets + 2 &&
        relayWebSocketCloses.A === restartConnectTransportBaseline.closes + 1 &&
        activeRelayWebSockets.A.size ===
          restartConnectTransportBaseline.activeWebSockets + 1;
      const restartConnectPromptState = await pageA.evaluate(() => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none' &&
            Number(style.opacity || 1) > 0;
        };
        const text = [...document.querySelectorAll('flt-semantics')]
          .filter(visible)
          .map((node) => [node.getAttribute('aria-label') || '',
            node.innerText || '', node.textContent || ''].join(' '))
          .join(' ');
        return {
          trustPromptVisible: /verify ssh host key|trust after verification/i.test(text),
          credentialPromptVisible:
            /select credential|choose credential|password required|password authentication/i.test(text),
          visiblePasswordInputCount:
            [...document.querySelectorAll('input[type="password"]')].filter(visible).length,
          hostKeyConflictVisible: /host key.{0,30}(changed|conflict)/i.test(text),
          authenticationFailureVisible:
            /authentication failed|password rejected|credential unavailable/i.test(text),
        };
      });
      stage = 'Profile A-restarted assert two-phase Workspace SSH transport';
      assertThat(restartConnectExactTransport &&
        tmuxBeforeResume.sessionCount === 1 && tmuxBeforeResume.clientCount === 0 &&
        tmuxBeforeResume.sessions[0]?.sessionId === tmuxSessionId &&
        workspaceSplitPushes.length === restartNoAutoBaseline.pushCount,
      'restart Workspace Connect did not establish exactly one SSH transport before Resume');
      stage = 'Profile A-restarted assert no trust or auth prompt after Connect';
      assertThat(await pageA.getByRole('button', {
        name: 'Trust after verification', exact: true,
      }).count() === 0 && !restartConnectPromptState.trustPromptVisible &&
        !restartConnectPromptState.credentialPromptVisible &&
        restartConnectPromptState.visiblePasswordInputCount === 0 &&
        !restartConnectPromptState.hostKeyConflictVisible &&
        !restartConnectPromptState.authenticationFailureVisible,
      'restart Workspace Connect exposed a trust, credential, password, or failure prompt');
      stage = 'Profile A-restarted assert exactly one connected terminal runtime';
      const restartConnectedRuntimes = await workspaceTerminalRuntimeSnapshot(
        pageA, [HOST_TMUX_NAME],
      );
      assertThat(restartConnectedRuntimes.length === 1 &&
        restartConnectedRuntimes[0].count === 1 &&
        restartConnectedRuntimes[0].connectingCount === 0 &&
        restartConnectedRuntimes[0].connectedCount === 1 &&
        restartConnectedRuntimes[0].failedCount === 0,
      'restart Workspace Connect did not leave exactly one connected tmux terminal runtime');
      const restartVaultAfterConnect = requireVault('post-restart Connect ledger');
      const restartWorkspaceAfterConnect = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      stage = 'Profile A-restarted assert Connect added no sync mutations';
      assertThat(restartVaultAfterConnect.commitSeq === afterDescriptor.commitSeq &&
        stableJson(restartWorkspaceAfterConnect) ===
          stableJson(workspaceStateBeforeRestart),
      'restart Workspace Connect added duplicate Vault or Workspace ledger mutations');
      stage = 'Profile A-restarted forced pull of previously committed KnownHost';
      const restartPullApiBaseline = vaultSyncApiEvents.A.length;
      const restartPullPushBaseline = workspaceSplitPushes.length;
      const restartPullPushResponseBaseline = workspaceSplitPushResponses.length;
      let restartPullSummary;
      try {
        restartPullSummary = await syncNow(
          pageA, 'Profile A forced pull of committed tmux KnownHost', {
            forcePull: true,
          },
        );
      } catch (error) {
        console.error('WEB-WORKSPACE-TMUX-RESTART-KNOWNHOST-PULL-FAILURE',
          JSON.stringify({
            errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
            errorMessageCategory: /did not settle/i.test(error?.message || '')
              ? 'sync-did-not-settle'
              : /changes request/i.test(error?.message || '')
                ? 'changes-read-failed'
                : 'sync-read-failed',
            apiEventDelta: vaultSyncApiEvents.A.length - restartPullApiBaseline,
            pushOperationDelta: workspaceSplitPushes.length - restartPullPushBaseline,
            pushResponseDelta:
              workspaceSplitPushResponses.length - restartPullPushResponseBaseline,
          }));
        throw error;
      }
      const restartPullApiEvents = vaultSyncApiEvents.A.slice(restartPullApiBaseline);
      const restartPullVault = requireVault('post-restart KnownHost pull ledger');
      const restartPullWorkspace = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      const restartPullPending = await visibleSyncPendingSnapshot(pageA);
      stage = 'Profile A-restarted assert forced pull was read-only';
      assertThat(restartPullSummary?.httpStatus === 200 &&
        restartPullApiEvents.some((event) => event.endpoint === 'changes' &&
          event.method === 'GET' && event.status === 200) &&
        restartPullApiEvents.every((event) => event.method === 'GET') &&
        !restartPullApiEvents.some((event) => event.endpoint === 'push' &&
          event.method === 'POST') &&
        workspaceSplitPushes.length === restartPullPushBaseline &&
        workspaceSplitPushResponses.length === restartPullPushResponseBaseline &&
        restartPullVault.commitSeq === afterDescriptor.commitSeq &&
        stableJson(restartPullWorkspace) === stableJson(workspaceStateBeforeRestart) &&
        restartPullPending.pendingCount === 0,
      'KnownHost recheck was not a read-only pull or changed pending/commit state');
      stage = 'Profile A-restarted inspect restored Resume action';
      const resumeAction = pageA.getByRole('button', {
        name: 'Resume tmux session', exact: true,
      });
      const [resumeActionCount, resumeActionVisible, resumeActionEnabled] =
        await Promise.all([
          resumeAction.count().catch(() => 0),
          resumeAction.isVisible().catch(() => false),
          resumeAction.isEnabled().catch(() => false),
        ]);
      console.log('WEB-WORKSPACE-TMUX-RESTART-RESUME-ACTION', JSON.stringify({
        count: resumeActionCount,
        visible: resumeActionVisible,
        enabled: resumeActionEnabled,
        pendingCount: restartPullPending.pendingCount,
        pendingLabel: restartPullPending.label,
        pullStatus: restartPullSummary?.httpStatus ?? null,
        changesReadCount: restartPullApiEvents.filter((event) =>
          event.endpoint === 'changes' && event.method === 'GET' &&
          event.status === 200).length,
        pushRequestCount: restartPullApiEvents.filter((event) =>
          event.endpoint === 'push' && event.method === 'POST').length,
      }));
      stage = `Profile A-restarted assert restored Resume action (${JSON.stringify({
        count: resumeActionCount,
        visible: resumeActionVisible,
        enabled: resumeActionEnabled,
      })})`;
      assertThat(resumeActionCount === 1 && resumeActionVisible &&
        resumeActionEnabled,
        'same-profile restart did not restore the explicit Resume action');
      const restartResumeUiDiagnostic = async (phase, error) => {
        const [ui, tmux] = await Promise.all([
          pageA.evaluate(() => {
            const visible = (node) => {
              const rect = node.getBoundingClientRect();
              const style = getComputedStyle(node);
              return rect.width > 0 && rect.height > 0 &&
                style.visibility !== 'hidden' && style.display !== 'none' &&
                Number(style.opacity || 1) > 0;
            };
            const labels = [...document.querySelectorAll('flt-semantics')]
              .filter(visible)
              .map((node) => [node.getAttribute('aria-label') || '',
                node.innerText || '', node.textContent || ''].join(' '));
            return {
              resumeDialogVisible: labels.some((label) =>
                label.includes('Resume tmux session?')),
              resumeConfirmVisible: labels.some((label) =>
                label.includes('Resume session')),
              alertDialogVisible: [...document.querySelectorAll(
                '[role="dialog"], [role="alertdialog"]',
              )].some(visible),
              resumeActionVisible: labels.some((label) =>
                label.includes('Resume tmux session')),
              terminalTitleVisible: labels.some((label) =>
                label.includes('Terminal workspace')),
            };
          }).catch(() => ({ snapshotAvailable: false })),
          Promise.resolve(tmuxSshFixture.tmuxSnapshot()).catch(() => null),
        ]);
        const ssh = tmuxSshFixture.server.summary();
        console.error(`WEB-WORKSPACE-TMUX-RESTART-RESUME-FAILURE ${JSON.stringify({
          phase,
          errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
          ui,
          tmux: tmux ? {
            sessionCount: tmux.sessionCount,
            clientCount: tmux.clientCount,
            sameSession: tmux.sessions[0]?.sessionId === tmuxSessionId,
            attachedClientCount: tmux.sessions[0]?.attachedClientCount ?? null,
          } : { snapshotAvailable: false },
          relay: {
            ticketDelta: relayAttempts.A.length - resumeTransportBaseline.tickets,
            webSocketDelta: relayWebSockets.A - resumeTransportBaseline.webSockets,
            activeWebSocketDelta: activeRelayWebSockets.A.size -
              resumeTransportBaseline.activeWebSockets,
          },
          ssh: {
            commandSessionsDelta: ssh.commandSessions -
              resumeTransportBaseline.ssh.commandSessions,
            sessionStartsDelta: ssh.sessionStarts -
              resumeTransportBaseline.ssh.sessionStarts,
            shellSessionsDelta: ssh.shellSessions -
              resumeTransportBaseline.ssh.shellSessions,
            tcpAcceptedDelta: ssh.tcpConnectionsAccepted -
              resumeTransportBaseline.ssh.tcpConnectionsAccepted,
            tcpClosedDelta: ssh.tcpConnectionsClosed -
              resumeTransportBaseline.ssh.tcpConnectionsClosed,
            tcpOpenDelta: ssh.tcpConnectionsOpen -
              resumeTransportBaseline.ssh.tcpConnectionsOpen,
            keyExchangeDelta: ssh.keyExchangeStarted -
              resumeTransportBaseline.ssh.keyExchangeStarted,
            passwordAcceptedDelta: ssh.passwordAccepted -
              resumeTransportBaseline.ssh.passwordAccepted,
          },
        })}`);
      };
      const resumeTransportBaseline = {
        tickets: relayAttempts.A.length,
        webSockets: relayWebSockets.A,
        closes: relayWebSocketCloses.A,
        activeWebSockets: activeRelayWebSockets.A.size,
        ssh: tmuxSshFixture.server.summary(),
      };
      stage = 'Profile A-restarted click explicit Resume action';
      try {
        await resumeAction.click();
      } catch (error) {
        await restartResumeUiDiagnostic('resume_action_click', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for Resume confirmation dialog';
      try {
        await waitForText(pageA, 'Resume tmux session?');
      } catch (error) {
        await restartResumeUiDiagnostic('resume_confirmation_dialog', error);
        throw error;
      }
      stage = 'Profile A-restarted verify no tmux attach before confirmation';
      const tmuxBeforeResumeConfirmation = tmuxSshFixture.tmuxSnapshot();
      assertThat(tmuxBeforeResumeConfirmation.sessionCount === 1 &&
        tmuxBeforeResumeConfirmation.clientCount === 0 &&
        tmuxBeforeResumeConfirmation.sessions[0]?.sessionId === tmuxSessionId,
      'tmux attached before explicit Resume confirmation');
      stage = 'Profile A-restarted click Resume confirmation';
      try {
        await click(pageA, 'Resume session');
      } catch (error) {
        await restartResumeUiDiagnostic('resume_confirm_click', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for tmux client attach';
      let resumedTmux;
      try {
        resumedTmux = await waitForTmuxState(
          tmuxSshFixture,
          (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 1 &&
            snapshot.sessions[0]?.sessionId === tmuxSessionId &&
            snapshot.sessions[0]?.attachedClientCount === 1,
          'the same tmux session reattached to restarted Profile A',
          20000,
        );
      } catch (error) {
        await restartResumeUiDiagnostic('tmux_attach', error);
        throw error;
      }
      stage = 'Profile A-restarted wait for the single tmux SSH command channel';
      let resumedSsh;
      try {
        resumedSsh = await waitForCaptured(() => {
          const ssh = tmuxSshFixture.server.summary();
          return ssh.commandSessions >=
            resumeTransportBaseline.ssh.commandSessions + 4 ? ssh : null;
        }, 'restarted Profile A tmux Resume command channels');
      } catch (error) {
        await restartResumeUiDiagnostic('ssh_attach_command_channel', error);
        throw error;
      }
      const canaryAfterResume = tmuxSshFixture.tmuxPrivacyMarkerSnapshot(
        tmuxSessionName, TMUX_COMMAND_MARKER, TMUX_OUTPUT_MARKER,
      );
      const finalWorkspaceVault = requireVault('final Workspace ledger');
      const finalWorkspaceState = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, workspaceRecordId, PRIVACY_MARKERS,
      );
      const finalPending = await visibleSyncPendingSnapshot(pageA);
      const apiMarkerLeaks = apiPrivacyChecks.filter((item) =>
        !item.markersAbsent).length;
      const databaseMarkers = serverPlaintextMarkers(databasePath);
      const serverLogMarkersAbsent = markerScan(
        fs.readFileSync(path.join(tempRoot, 'server.log'), 'utf8'),
      );
      const restartResumeSshDeltas = {
        commandSessions: resumedSsh.commandSessions -
          resumeTransportBaseline.ssh.commandSessions,
        sessionStarts: resumedSsh.sessionStarts -
          resumeTransportBaseline.ssh.sessionStarts,
        shellSessions: resumedSsh.shellSessions -
          resumeTransportBaseline.ssh.shellSessions,
        tcpAccepted: resumedSsh.tcpConnectionsAccepted -
          resumeTransportBaseline.ssh.tcpConnectionsAccepted,
        tcpClosed: resumedSsh.tcpConnectionsClosed -
          resumeTransportBaseline.ssh.tcpConnectionsClosed,
        tcpOpen: resumedSsh.tcpConnectionsOpen -
          resumeTransportBaseline.ssh.tcpConnectionsOpen,
        keyExchange: resumedSsh.keyExchangeStarted -
          resumeTransportBaseline.ssh.keyExchangeStarted,
        passwordAccepted: resumedSsh.passwordAccepted -
          resumeTransportBaseline.ssh.passwordAccepted,
      };
      console.log('WEB-WORKSPACE-TMUX-RESTART-RESUME-SSH-CHANNELS',
        JSON.stringify(restartResumeSshDeltas));
      stage = 'Profile A-restarted assert Resume changed only tmux attach channel';
      assertThat(resumedTmux.sessions[0]?.sessionId === tmuxSessionId &&
        resumedTmux.clientCount === 1 &&
        restartResumeSshDeltas.commandSessions === 4 &&
        restartResumeSshDeltas.sessionStarts === 4 &&
        restartResumeSshDeltas.shellSessions === 0 &&
        restartResumeSshDeltas.tcpAccepted === 0 &&
        restartResumeSshDeltas.tcpClosed === 0 &&
        restartResumeSshDeltas.tcpOpen === 0 &&
        restartResumeSshDeltas.keyExchange === 0 &&
        restartResumeSshDeltas.passwordAccepted === 0 &&
        resumedSsh.tcpConnectionsAccepted ===
          resumeTransportBaseline.ssh.tcpConnectionsAccepted &&
        resumedSsh.tcpConnectionsOpen ===
          resumeTransportBaseline.ssh.tcpConnectionsOpen &&
        resumedSsh.keyExchangeStarted === resumeTransportBaseline.ssh.keyExchangeStarted &&
        resumedSsh.passwordAccepted === resumeTransportBaseline.ssh.passwordAccepted &&
        resumedSsh.shellSessions === resumeTransportBaseline.ssh.shellSessions &&
        relayAttempts.A.length === resumeTransportBaseline.tickets &&
        relayWebSockets.A === resumeTransportBaseline.webSockets &&
        relayWebSocketCloses.A === resumeTransportBaseline.closes &&
        activeRelayWebSockets.A.size === resumeTransportBaseline.activeWebSockets &&
        canaryAfterResume.commandMarkerVisible && canaryAfterResume.outputMarkerVisible &&
        finalWorkspaceVault.commitSeq === afterDescriptor.commitSeq &&
        stableJson(finalWorkspaceState) === stableJson(workspaceStateBeforeRestart) &&
        workspaceSplitPushes.length === restartNoAutoBaseline.pushCount &&
        finalPending.pendingCount === 0 && apiPrivacyChecks.length > 0 &&
        apiMarkerLeaks === 0 && databaseMarkers.length === 0 &&
        serverLogMarkersAbsent && pageErrors.length === 0,
      'Resume changed the transport, duplicated Workspace ledger work, lost the tmux session, or leaked markers');
      console.log('WEB-WORKSPACE-TMUX-PROCESS-RESTART-01 passed', JSON.stringify({
        persistentProfileReused: true,
        actualChromiumProcessGroupSigkill: oldProcessGroupExit.exited,
        oldProfileChromiumProcessesClearedAfterSigkill,
        restartedChromiumIdentityChanged:
          restartedChromiumIdentity.pid !== oldChromiumIdentity.pid &&
          restartedChromiumIdentity.startTimeTicks !== oldChromiumIdentity.startTimeTicks,
        sameDeviceStoreFingerprintAfterReauth:
          storageAfterReauth.deviceStoreFingerprint ===
            secureStoreBeforeKill.deviceStoreFingerprint,
        reauthenticatedOrUnlocked: reauth.submittedLogin || reauth.submittedUnlock,
        zeroAutomaticRelayOrSshBeforeConnect: true,
        tmuxSessionPreservedAcrossRestart: true,
        tmuxClientsBeforeResumeConfirmation: tmuxBeforeResumeConfirmation.clientCount,
        connectRelayTicketCount: restartConnectTickets.length,
        connectRelayTicketDelta: relayAttempts.A.length -
          restartPreviewRelayBaseline.tickets,
        connectWebSocketDelta: relayWebSockets.A -
          restartPreviewRelayBaseline.webSockets,
        connectWebSocketCloseDelta: relayWebSocketCloses.A -
          restartConnectTransportBaseline.closes,
        connectActiveWebSocketDelta: activeRelayWebSockets.A.size -
          restartPreviewRelayBaseline.activeWebSockets,
        connectTcpDelta: restartConnectedSsh.tcpConnectionsAccepted -
          restartConnectSshBaseline.tcpConnectionsAccepted,
        connectTcpClosedDelta: restartConnectedSsh.tcpConnectionsClosed -
          restartConnectSshBaseline.tcpConnectionsClosed,
        connectTcpOpenDelta: restartConnectedSsh.tcpConnectionsOpen -
          restartConnectSshBaseline.tcpConnectionsOpen,
        connectServerBannerDelta: restartConnectedSsh.serverBannerEmitted -
          restartConnectSshBaseline.serverBannerEmitted,
        connectClientBannerDelta: restartConnectedSsh.clientBannerReceived -
          restartConnectSshBaseline.clientBannerReceived,
        connectKexDelta: restartConnectedSsh.keyExchangeStarted -
          restartConnectSshBaseline.keyExchangeStarted,
        connectHostKeyOnlyPhaseStoppedBeforeAuth: restartConnectPhases[0].closed &&
          restartConnectPhases[0].passwordAccepted === 0 &&
          restartConnectPhases[0].shellSessions === 0,
        connectAuthDelta: restartConnectedSsh.passwordAccepted -
          restartConnectSshBaseline.passwordAccepted,
        connectShellDelta: restartConnectedSsh.shellSessions -
          restartConnectSshBaseline.shellSessions,
        knownHostForcedPullStatus: restartPullSummary?.httpStatus ?? null,
        knownHostForcedPullChangesReadCount: restartPullApiEvents.filter((event) =>
          event.endpoint === 'changes' && event.method === 'GET' &&
          event.status === 200).length,
        knownHostForcedPullPushCount: restartPullApiEvents.filter((event) =>
          event.endpoint === 'push' && event.method === 'POST').length,
        resumeWebSocketCloseDelta: relayWebSocketCloses.A -
          resumeTransportBaseline.closes,
        resumeRelayOrTransportDelta: 0,
        resumeAttachCommandDelta: resumedSsh.commandSessions -
          resumeTransportBaseline.ssh.commandSessions,
        resumeSessionStartDelta: resumedSsh.sessionStarts -
          resumeTransportBaseline.ssh.sessionStarts,
        resumeShellSessionDelta: resumedSsh.shellSessions -
          resumeTransportBaseline.ssh.shellSessions,
        resumeTmuxClientCount: resumedTmux.clientCount,
        workspaceVersionsEventsReceipts: [
          finalWorkspaceState.versions.length,
          finalWorkspaceState.events.length,
          finalWorkspaceState.receipts.length,
        ],
        workspaceHeadUnchangedAfterRestart: stableJson(finalWorkspaceState) ===
          stableJson(workspaceStateBeforeRestart),
        syncPushesAfterDescriptorCommit:
          workspaceSplitPushes.length - restartNoAutoBaseline.pushCount,
        apiPlaintextMarkerLeaks: apiMarkerLeaks,
        databasePlaintextMarkerCount: databaseMarkers.length,
        serverLogMarkersAbsent,
        pageErrorCount: pageErrors.length,
      }));
      return;
    }

    stage = 'connect profile B after initial server setup';
    await connectSecurely(pageB, baseUrl);
    stage = 'open profile B login form';
    await field(pageB, 'Email or username');
    stage = 'open profile B device enrollment form';
    await click(pageB, 'Add this device');
    stage = 'wait for profile B enrollment form';
    await waitForText(pageB, 'Request this device');
    stage = 'create profile B enrollment request';
    await fill(pageB, 'Account email', USERNAME);
    await fill(pageB, 'Device name', 'Workspace profile B');
    await click(pageB, 'Generate request');
    await field(pageB, 'Copy this enrollment JSON');
    stage = 'copy profile B enrollment request';
    await click(pageB, 'Copy');
    const enrollment = await pageB.evaluate(() => navigator.clipboard.readText());
    assertThat(JSON.parse(enrollment).format === 'atermius-device-enrollment-v1',
      'profile B enrollment request format was invalid');
    await click(pageB, 'Close');
    stage = 'Profile A open Devices for profile B enrollment';
    await click(pageA, 'Devices');
    stage = 'Profile A open enrollment approval form';
    await click(pageA, 'Approve enrollment');
    stage = 'Profile A verify enrollment approval dialog';
    await waitForText(pageA, 'Paste the public request from the new browser', 5000);
    const enrollmentDialogSnapshot = await pageA.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none' && Number(style.opacity || 1) > 0;
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => `${node.getAttribute('aria-label') || ''} ${node.innerText || ''}`
          .replace(/\s+/g, ' ').trim())
        .filter((label) => /enrollment|review keys|approve & seal keys|cancel/i.test(label));
      const fields = [...document.querySelectorAll('input, textarea')]
        .filter(visible)
        .map((node) => node.getAttribute('aria-label') || 'unlabeled input');
      const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter(visible).length;
      return { dialogs, enrollmentControls: labels, visibleFieldLabels: fields };
    }).catch(() => ({ probeAvailable: false }));
    console.log('WEB-WORKSPACE-ENROLLMENT-DIALOG-CHECKPOINT',
      JSON.stringify(enrollmentDialogSnapshot));
    stage = 'Profile A fill enrollment approval request';
    await paste(pageA, 'Enrollment JSON', enrollment);
    stage = 'Profile A review enrollment approval keys';
    await click(pageA, 'Review keys');
    stage = 'Profile A approve and seal profile B device keys';
    await click(pageA, 'Approve & seal keys');
    stage = 'Profile A wait for profile B approval copy action';
    await visibleButton(pageA, 'Copy');
    await click(pageA, 'Copy');
    const approval = await pageA.evaluate(() => navigator.clipboard.readText());
    assertThat(approval.includes('atermius-device-approval-v1'),
      'profile A device approval format was invalid');
    await click(pageA, 'Done');
    await click(pageA, 'Hosts');
    await waitForWorkspace(pageA);
    stage = 'open profile B approval import';
    await click(pageB, 'Import approval');
    stage = 'paste profile B approval';
    await paste(pageB, 'Paste approval JSON', approval);
    stage = 'import profile B device keys';
    await click(pageB, 'Import device keys');
    stage = 'unlock profile B';
    await fill(pageB, 'Email or username', USERNAME);
    await fill(pageB, 'Master password', MASTER_PASSWORD);
    await click(pageB, 'Sign in and unlock');
    await waitForWorkspace(pageB);

    stage = 'create encrypted credential and Host references';
    await addCredential(pageA, () => pageErrors.length);
    await syncNow(pageA, 'Credential sync');
    stage = 'capture pre-Host-A Vault commit sequence';
    const beforeHostA = serverVaultSnapshot(databasePath).vaults[0];
    assertThat(beforeHostA, 'Host A create did not find the active Vault');
    await addHost(pageA, HOST_A_NAME, HOST_A_ADDRESS);
    await syncNow(pageA, 'Host A sync');
    stage = 'capture post-Host-A Vault commit sequence';
    const afterHostA = serverVaultSnapshot(databasePath).vaults[0];
    stage = 'validate exact Host A encrypted create event';
    const hostACreate = serverCommitDelta(
      databasePath, beforeHostA.vaultId, beforeHostA.commitSeq, afterHostA.commitSeq,
    );
    console.log('WEB-WORKSPACE-HOST-A-CREATE-CHECKPOINT', JSON.stringify({
      commitDelta: Number(BigInt(afterHostA.commitSeq) - BigInt(beforeHostA.commitSeq)),
      changeEventDelta: hostACreate.eventCount,
      distinctCommitDelta: hostACreate.distinctCommitCount,
      operationKinds: hostACreate.events.map((event) => event.operation),
      opaqueRecordIdPresent: hostACreate.events.every((event) =>
        typeof event.recordId === 'string' && event.recordId.length > 0),
    }));
    assertThat(hostACreate.eventCount === 1 &&
      hostACreate.events[0].operation === 'create' &&
      hostACreate.distinctCommitCount === 1,
    'Host A did not create exactly one encrypted Host record');
    vaultId = afterHostA.vaultId;
    hostARecordId = hostACreate.events[0].recordId;
    assertThat(typeof hostARecordId === 'string' && hostARecordId.length > 0,
      'Host A create did not expose its opaque synced record ID');
    const beforeHostB = serverVaultSnapshot(databasePath).vaults[0];
    assertThat(beforeHostB?.vaultId === vaultId,
      'Host B create did not find the active Vault');
    await addHost(pageA, HOST_B_NAME, HOST_B_ADDRESS);
    await syncNow(pageA, 'Host B sync');
    if (RENAME_SYNC_ONLY) {
      stage = 'validate exact Host B encrypted create event for rename sync';
      const afterHostB = serverVaultSnapshot(databasePath).vaults[0];
      const hostBCreate = serverCommitDelta(
        databasePath, vaultId, beforeHostB.commitSeq, afterHostB.commitSeq,
      );
      assertThat(hostBCreate.eventCount === 1 &&
        hostBCreate.events[0].operation === 'create' &&
        hostBCreate.distinctCommitCount === 1,
      'Host B did not create exactly one encrypted Host record for rename sync');
      const hostBRecordId = hostBCreate.events[0].recordId;
      workspaceHostReferenceMarkers = [hostARecordId, hostBRecordId];
      assertThat(workspaceHostReferenceMarkers.every((recordId) =>
        typeof recordId === 'string' && recordId.length > 0) &&
        new Set(workspaceHostReferenceMarkers).size === 2,
      'rename-sync Host reference privacy check did not capture distinct Host IDs');

      stage = 'Profile B synchronize the two Hosts before Workspace acceptance';
      await syncNow(pageB, 'Profile B Host references force pull', { forcePull: true });
      const hostPullPending = await visibleSyncPendingSnapshot(pageB);
      assertThat(hostPullPending.pendingCount === 0,
        'Profile B had pending local work before the Workspace rename flow');
      stage = 'open Workspaces for both profiles before creating the split';
      await click(pageA, 'Workspaces');
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A Workspaces page before rename-sync create', 15000);
      await click(pageB, 'Workspaces');
      await waitForVisibleSemanticText(pageB, 'Saved workspaces',
        'Profile B Workspaces page before rename-sync create', 15000);

      const workspaceBaseline = serverVaultSnapshot(databasePath).vaults[0];
      assertThat(workspaceBaseline?.vaultId === vaultId &&
        workspaceBaseline.commitSeq === afterHostB.commitSeq,
      'Workspace create baseline changed after the Host reference setup');
      const createPushBaseline = workspaceSplitPushes.length;
      const createPushResponseBaseline = workspaceSplitPushResponses.length;
      const createPullBaseline = splitPullChangePages.length;
      const createApiPrivacyBaseline = apiPrivacyChecks.length;
      const profileBSyncPushBaseline = vaultSyncApiEvents.B.length;
      const relayBaseline = {
        ticketsA: relayAttempts.A.length,
        ticketsB: relayAttempts.B.length,
        socketsA: relayWebSockets.A,
        socketsB: relayWebSockets.B,
        activeA: activeRelayWebSockets.A.size,
        activeB: activeRelayWebSockets.B.size,
        sinks: relaySinkSnapshot(),
      };
      captureWorkspaceSplit = true;
      stage = 'Profile A create the named two-pane split Workspace';
      await createRenameSyncWorkspace(pageA, RENAME_SYNC_OLD_NAME);

      stage = 'Profile A synchronize one encrypted Workspace create';
      await syncNow(pageA, 'rename-sync Workspace create');
      const createOperation = await waitForCaptured(() =>
        workspaceSplitPushes.slice(createPushBaseline)
          .flatMap((push) => push.operations)
          .find((operation) => operation.operation === 'create' &&
            operation.recordId && operation.revisionId && operation.opId),
      'rename-sync Workspace encrypted create');
      const createPushes = workspaceSplitPushes.slice(createPushBaseline);
      const matchingCreatePush = createPushes.find((push) =>
        push.operations.includes(createOperation));
      assertThat(createPushes.length === 1 &&
        matchingCreatePush?.operations.length === 1 &&
        matchingCreatePush.requestBodyPlaintextMarkersAbsent === true &&
        matchingCreatePush.encryptedWorkspaceHostReferenceMarkersAbsent === true &&
        createOperation.envelopeShapeValid === true,
      'rename-sync Workspace create was not one private encrypted operation');
      const createReceipt = await waitForCaptured(() =>
        workspaceSplitPushResponses.slice(createPushResponseBaseline).find((response) =>
          response.status === 200 && response.results.length === 1 &&
          response.results[0].opId === createOperation.opId &&
          response.results[0].revisionId === createOperation.revisionId &&
          response.results[0].commitSeq && !response.results[0].alreadyCommitted),
      'rename-sync Workspace create first-commit receipt');
      encryptedWorkspacePrivacyRecordId = createOperation.recordId;
      assertThat(createReceipt.encryptedWorkspaceHostReferenceMarkersAbsent === true,
        'rename-sync Workspace create receipt exposed Host record references');
      const afterCreate = serverVaultSnapshot(databasePath).vaults[0];
      const createCommit = serverCommitDelta(
        databasePath, vaultId, workspaceBaseline.commitSeq, afterCreate.commitSeq,
      );
      const createState = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, createOperation.recordId,
        [...splitEnvelopeMarkers, ...workspaceHostReferenceMarkers],
      );
      const createVersion = createState.versions[0];
      assertThat(BigInt(afterCreate.commitSeq) ===
        BigInt(workspaceBaseline.commitSeq) + 1n &&
        createCommit.eventCount === 1 && createCommit.distinctCommitCount === 1 &&
        createState.versions.length === 1 && createVersion.operation === 'create' &&
        createVersion.headerRevisionId === createOperation.revisionId &&
        createVersion.opId === createOperation.opId &&
        createVersion.envelopeSha256 === createOperation.envelopeSha256 &&
        createVersion.validEnvelope && createVersion.markersAbsent &&
        createState.events.length === 1 && createState.events[0].operation === 'create' &&
        createState.headRevisionId === createVersion.revisionId &&
        !createState.headDeleted && createState.headCommitSeq === createVersion.commitSeq &&
        createState.receipts.length === 1 &&
        createState.receipts[0].recordId === createOperation.recordId &&
        createState.receipts[0].revisionId === createOperation.revisionId &&
        createState.receipts[0].commitSeq === createVersion.commitSeq &&
        createReceipt.results[0].commitSeq === createVersion.commitSeq,
      'rename-sync Workspace create, receipt, event and record head did not link');

      stage = 'Profile B pull the initial encrypted two-pane Workspace';
      const bCreatePendingBefore = await visibleSyncPendingSnapshot(pageB);
      const bCreateResponse = await syncNow(pageB,
        'Profile B initial Workspace force pull', { forcePull: true });
      const createPageEvidence = () => splitPullChangePages
        .slice(createPullBaseline)
        .flatMap((page) => (page.workspaceEnvelopeHostReferenceChecks || [])
          .filter((check) => check.recordIdMatchesWorkspace)
          .map((check) => ({ page, check })))
        .filter(({ page, check }) => page.httpStatus === 200 &&
          page.responsePlaintextMarkersAbsent === true &&
          check.eventType === 'create' && check.envelopePresent &&
          check.headerRecordId === createOperation.recordId &&
          check.headerOperation === 'create' &&
          check.headerRevisionId === createOperation.revisionId &&
          check.headerOpId === createOperation.opId &&
          check.envelopeSha256 === createOperation.envelopeSha256 &&
          check.envelopeShapeValid && check.hostReferenceMarkersAbsent);
      const capturedCreateEvent = await waitForCaptured(() =>
        createPageEvidence().length === 1 ? createPageEvidence()[0] : null,
      'Profile B exact encrypted Workspace create event');
      const bCreatePendingAfter = await visibleSyncPendingSnapshot(pageB);
      const bCreatedCardCount = await visibleWorkspacePreviewCardCount(pageB);
      await waitForVisibleSemanticText(pageB, RENAME_SYNC_OLD_NAME,
        'Profile B decrypted initial Workspace name', 15000);
      await waitForVisibleSemanticText(pageB, 'Active Pane 2',
        'Profile B decrypted initial Active Pane 2 metadata', 10000);
      for (const hostName of [HOST_A_NAME, HOST_B_NAME]) {
        await waitForVisibleSemanticText(pageB, hostName,
          `Profile B decrypted Host reference ${hostName}`, 10000);
      }
      const bCreatePushCount = vaultSyncApiEvents.B
        .slice(profileBSyncPushBaseline)
        .filter((event) => event.endpoint === 'push' && event.method === 'POST').length;
      assertThat(bCreateResponse?.httpStatus === 200 &&
        bCreateResponse.responsePlaintextMarkersAbsent === true &&
        bCreatePendingBefore.pendingCount === 0 && bCreatePendingAfter.pendingCount === 0 &&
        bCreatedCardCount === 1 && bCreatePushCount === 0 &&
        capturedCreateEvent.check.envelopeSha256 === createOperation.envelopeSha256,
      'Profile B did not decrypt the exact private initial Workspace create without pushing');

      const updatePushBaseline = workspaceSplitPushes.length;
      const updatePushResponseBaseline = workspaceSplitPushResponses.length;
      const updatePullBaseline = splitPullChangePages.length;
      const bUpdatePushBaseline = vaultSyncApiEvents.B.length;
      const beforeRename = serverVaultSnapshot(databasePath).vaults[0];
      const preRenameState = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, createOperation.recordId,
        [...splitEnvelopeMarkers, ...workspaceHostReferenceMarkers],
      );
      assertThat(beforeRename?.commitSeq === afterCreate.commitSeq &&
        preRenameState.versions.length === 1 && preRenameState.receipts.length === 1,
      'Workspace record changed before the visible Rename action');

      stage = 'Profile A open visible Workspace actions and choose Rename';
      const workspaceActions = pageA.getByRole('button', {
        name: 'Workspace actions', exact: true,
      });
      assertThat(await workspaceActions.count() === 1 &&
        await workspaceActions.isVisible(),
      'Profile A did not expose a unique visible Workspace actions control');
      await workspaceActions.click();
      await pageA.getByRole('menuitem', { name: 'Rename', exact: true }).click();
      await waitForText(pageA, 'Rename workspace');
      await fill(pageA, 'Workspace name', RENAME_SYNC_NEW_NAME);
      await click(pageA, 'Save');
      await waitForVisibleSemanticText(pageA, RENAME_SYNC_NEW_NAME,
        'Profile A renamed Workspace card', 10000);
      assertThat(!await visibleSemanticTextMatch(pageA, RENAME_SYNC_OLD_NAME),
        'Profile A kept the old Workspace name visible after Rename');

      stage = 'Profile A commit exactly one encrypted Workspace rename update';
      await syncNow(pageA, 'rename-sync Workspace update');
      const updateOperation = await waitForCaptured(() =>
        workspaceSplitPushes.slice(updatePushBaseline)
          .flatMap((push) => push.operations)
          .find((operation) => operation.operation === 'update' &&
            operation.recordId === createOperation.recordId &&
            operation.revisionId && operation.opId),
      'same-record Workspace rename update');
      const updatePushes = workspaceSplitPushes.slice(updatePushBaseline);
      const matchingUpdatePush = updatePushes.find((push) =>
        push.operations.includes(updateOperation));
      assertThat(updatePushes.length === 1 &&
        matchingUpdatePush?.operations.length === 1 &&
        updateOperation.recordId === createOperation.recordId &&
        matchingUpdatePush.requestBodyPlaintextMarkersAbsent === true &&
        matchingUpdatePush.encryptedWorkspaceHostReferenceMarkersAbsent === true &&
        updateOperation.envelopeShapeValid === true,
      'Workspace Rename did not send exactly one private update for the same record');
      const updateReceipt = await waitForCaptured(() =>
        workspaceSplitPushResponses.slice(updatePushResponseBaseline).find((response) =>
          response.status === 200 && response.results.length === 1 &&
          response.results[0].opId === updateOperation.opId &&
          response.results[0].revisionId === updateOperation.revisionId &&
          response.results[0].commitSeq && !response.results[0].alreadyCommitted),
      'Workspace rename first-commit receipt');
      assertThat(updateReceipt.encryptedWorkspaceHostReferenceMarkersAbsent === true,
        'Workspace rename receipt exposed Host record references');

      const afterRename = serverVaultSnapshot(databasePath).vaults[0];
      const updateCommit = serverCommitDelta(
        databasePath, vaultId, beforeRename.commitSeq, afterRename.commitSeq,
      );
      const renamedState = serverWorkspaceRecordSnapshot(
        databasePath, vaultId, createOperation.recordId,
        [...splitEnvelopeMarkers, ...workspaceHostReferenceMarkers],
      );
      const updateVersion = renamedState.versions.find((version) =>
        version.revisionId === updateOperation.revisionId);
      const updateEvent = renamedState.events.find((event) =>
        event.revisionId === updateOperation.revisionId);
      const updateDbReceipt = renamedState.receipts.find((receipt) =>
        receipt.opId === updateOperation.opId);
      assertThat(BigInt(afterRename.commitSeq) === BigInt(beforeRename.commitSeq) + 1n &&
        updateCommit.eventCount === 1 && updateCommit.distinctCommitCount === 1 &&
        updateCommit.events.length === 1 && updateCommit.events[0].operation === 'update' &&
        updateCommit.events[0].recordId === createOperation.recordId &&
        updateCommit.events[0].revisionId === updateOperation.revisionId &&
        renamedState.versions.length === 2 && renamedState.events.length === 2 &&
        renamedState.receipts.length === 2 && updateVersion?.operation === 'update' &&
        updateVersion.headerOperation === 'update' &&
        updateVersion.headerRevisionId === updateOperation.revisionId &&
        updateVersion.opId === updateOperation.opId &&
        updateVersion.envelopeSha256 === updateOperation.envelopeSha256 &&
        updateVersion.validEnvelope && updateVersion.markersAbsent &&
        updateEvent?.operation === 'update' &&
        updateEvent.commitSeq === updateVersion.commitSeq &&
        renamedState.headRevisionId === updateOperation.revisionId &&
        !renamedState.headDeleted &&
        renamedState.headCommitSeq === updateVersion.commitSeq &&
        updateDbReceipt?.recordId === createOperation.recordId &&
        updateDbReceipt.revisionId === updateOperation.revisionId &&
        updateDbReceipt.commitSeq === updateVersion.commitSeq &&
        updateReceipt.results[0].commitSeq === updateVersion.commitSeq,
      'Workspace rename update, receipt, event and record head did not link exactly once');

      stage = 'Profile B pull and decrypt the exact encrypted Workspace rename update';
      const bPendingBeforeUpdatePull = await visibleSyncPendingSnapshot(pageB);
      const bUpdateResponse = await syncNow(pageB,
        'Profile B renamed Workspace force pull', { forcePull: true });
      const updatePageEvidence = () => splitPullChangePages
        .slice(updatePullBaseline)
        .flatMap((page) => (page.workspaceEnvelopeHostReferenceChecks || [])
          .filter((check) => check.recordIdMatchesWorkspace)
          .map((check) => ({ page, check })))
        .filter(({ page, check }) => page.httpStatus === 200 &&
          page.responsePlaintextMarkersAbsent === true &&
          check.eventType === 'update' && check.envelopePresent &&
          check.headerRecordId === createOperation.recordId &&
          check.headerOperation === 'update' &&
          check.headerRevisionId === updateOperation.revisionId &&
          check.headerOpId === updateOperation.opId &&
          check.revisionId === updateOperation.revisionId &&
          check.envelopeSha256 === updateOperation.envelopeSha256 &&
          check.envelopeShapeValid && check.hostReferenceMarkersAbsent);
      const capturedUpdateEvent = await waitForCaptured(() =>
        updatePageEvidence().length === 1 ? updatePageEvidence()[0] : null,
      'Profile B exact encrypted Workspace update event and envelope');
      const bPendingAfterUpdatePull = await visibleSyncPendingSnapshot(pageB);
      const bUpdatePushCount = vaultSyncApiEvents.B
        .slice(bUpdatePushBaseline)
        .filter((event) => event.endpoint === 'push' && event.method === 'POST').length;
      const profileBCommitSeqUnchanged =
        serverVaultSnapshot(databasePath).vaults[0]?.commitSeq === afterRename.commitSeq;
      await waitForVisibleSemanticText(pageB, RENAME_SYNC_NEW_NAME,
        'Profile B decrypted renamed Workspace card', 15000);
      const bOldNameVisible = await visibleSemanticTextMatch(
        pageB, RENAME_SYNC_OLD_NAME,
      );
      const bNewNameVisible = await visibleSemanticTextMatch(
        pageB, RENAME_SYNC_NEW_NAME,
      );
      await waitForVisibleSemanticText(pageB, 'Active Pane 2',
        'Profile B renamed Workspace Active Pane 2 metadata', 10000);
      const orderedPaneHosts = [HOST_A_NAME, HOST_B_NAME];
      for (const [index, hostName] of orderedPaneHosts.entries()) {
        await waitForVisibleSemanticText(pageB, `Pane ${index + 1} · ${hostName}`,
          `Profile B renamed Workspace Pane ${index + 1} Host reference`, 10000);
      }
      const paneCardOrder = await pageB.evaluate((hosts) => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
            style.display !== 'none' && Number(style.opacity || 1) > 0;
        };
        const text = [...document.querySelectorAll('flt-semantics')]
          .filter(visible)
          .map((node) => (node.getAttribute('aria-label') || node.innerText ||
            node.textContent || '').replace(/\s+/g, ' ').trim()).join('\n');
        return hosts.map((hostName, index) =>
          text.indexOf(`Pane ${index + 1} · ${hostName}`));
      }, orderedPaneHosts).catch(() => []);
      const bRenamedCardCount = await visibleWorkspacePreviewCardCount(pageB);
      const bUpdatePushCountAfter = vaultSyncApiEvents.B
        .slice(bUpdatePushBaseline)
        .filter((event) => event.endpoint === 'push' && event.method === 'POST').length;
      const bRenameEvidence = {
        forcePullResponseStatus200: bUpdateResponse?.httpStatus === 200,
        forcePullResponseMarkersAbsent:
          bUpdateResponse?.responsePlaintextMarkersAbsent === true,
        capturedExactPrivateUpdateEvent: capturedUpdateEvent.check.envelopeSha256 ===
          updateOperation.envelopeSha256,
        changesPageCountAfterBaseline:
          splitPullChangePages.length - updatePullBaseline,
        beforePending: bPendingBeforeUpdatePull.pendingCount,
        afterPending: bPendingAfterUpdatePull.pendingCount,
        bPushRequests: bUpdatePushCountAfter,
        serverCommitSequenceUnchanged: profileBCommitSeqUnchanged,
        oldNameVisible: bOldNameVisible,
        renamedNameVisible: bNewNameVisible,
        visibleWorkspaceCardCount: bRenamedCardCount,
        orderedPaneHostCount: paneCardOrder.length,
        paneOrderPreserved: paneCardOrder.length === 2 &&
          paneCardOrder[0] >= 0 && paneCardOrder[1] > paneCardOrder[0],
        activePaneTwoVisible: await visibleSemanticTextMatch(pageB, 'Active Pane 2'),
      };
      stage = `Profile B rename pull evidence (${JSON.stringify(bRenameEvidence)})`;
      console.log('WEB-WORKSPACE-RENAME-SYNC-PULL-CHECKPOINT',
        JSON.stringify(bRenameEvidence));
      assertThat(bUpdateResponse?.httpStatus === 200 &&
        bUpdateResponse.responsePlaintextMarkersAbsent === true &&
        capturedUpdateEvent.check.envelopeSha256 === updateOperation.envelopeSha256 &&
        bPendingBeforeUpdatePull.pendingCount === 0 &&
        bPendingAfterUpdatePull.pendingCount === 0 && bUpdatePushCount === 0 &&
        bUpdatePushCountAfter === 0 && profileBCommitSeqUnchanged &&
        !bOldNameVisible && bNewNameVisible && bRenamedCardCount === 1 &&
        paneCardOrder.length === 2 && paneCardOrder[0] >= 0 &&
        paneCardOrder[1] > paneCardOrder[0] &&
        bRenameEvidence.activePaneTwoVisible,
      'Profile B did not receive and decrypt only the renamed private Workspace update');

      const apiPlaintextMarkerLeaks = apiPrivacyChecks
        .slice(createApiPrivacyBaseline)
        .filter((check) => !check.markersAbsent).length;
      const databaseMarkers = serverPlaintextMarkers(databasePath);
      const serverLogMarkersAbsent = markerScan(
        fs.readFileSync(path.join(tempRoot, 'server.log'), 'utf8'),
        workspaceHostReferenceMarkers,
      );
      const finalRelaySinks = relaySinkSnapshot();
      const relayDeltaZero = relayAttempts.A.length === relayBaseline.ticketsA &&
        relayAttempts.B.length === relayBaseline.ticketsB &&
        relayWebSockets.A === relayBaseline.socketsA &&
        relayWebSockets.B === relayBaseline.socketsB &&
        activeRelayWebSockets.A.size === relayBaseline.activeA &&
        activeRelayWebSockets.B.size === relayBaseline.activeB &&
        finalRelaySinks.every((sink, index) =>
          sink.accepted === relayBaseline.sinks[index].accepted &&
          sink.active === relayBaseline.sinks[index].active);
      assertThat(apiPrivacyChecks.length > createApiPrivacyBaseline &&
        apiPlaintextMarkerLeaks === 0 && databaseMarkers.length === 0 &&
        serverLogMarkersAbsent,
      'Workspace name or Host reference marker appeared in API, SQLite/WAL/SHM or logs');
      assertThat(relayDeltaZero,
        'Workspace create, rename or sync unexpectedly used SSH Relay');
      assertThat(pageErrors.length === 0,
        'a browser profile reported a page error during Workspace rename sync');
      console.log('WEB-WORKSPACE-RENAME-SYNC-01 passed', JSON.stringify({
        visibleActionsRename: true,
        sameOpaqueWorkspaceRecord: updateOperation.recordId === createOperation.recordId,
        oneAUpdateRequest: updatePushes.length === 1 &&
          updatePushes[0].operations.length === 1,
        oneAUpdateReceipt: renamedState.receipts.length === 2 &&
          updateDbReceipt?.opId === updateOperation.opId,
        oneUpdateEventAndHead: updateCommit.eventCount === 1 &&
          renamedState.headRevisionId === updateOperation.revisionId,
        profileBCapturedExactUpdateEnvelope: true,
        profileBShowsOnlyRenamedCard: !bOldNameVisible && bNewNameVisible &&
          bRenamedCardCount === 1,
        orderedPaneHosts: paneCardOrder.length,
        activePane: 2,
        profileBPushRequests: bUpdatePushCountAfter,
        apiPlaintextMarkerLeaks,
        databaseMarkerCount: databaseMarkers.length,
        serverLogMarkersAbsent,
        relayDelta: relayDeltaZero ? 0 : null,
        pageErrorCount: pageErrors.length,
      }));
      return;
    }
    if (MAX_PANES_ONLY) {
      stage = 'validate exact Host B encrypted create event';
      const afterHostB = serverVaultSnapshot(databasePath).vaults[0];
      const hostBCreate = serverCommitDelta(
        databasePath, vaultId, beforeHostB.commitSeq, afterHostB.commitSeq,
      );
      assertThat(hostBCreate.eventCount === 1 &&
        hostBCreate.events[0].operation === 'create' &&
        hostBCreate.distinctCommitCount === 1,
      'Host B did not create exactly one encrypted Host record');
      const hostBRecordId = hostBCreate.events[0].recordId;
      workspaceHostReferenceMarkers = [hostARecordId, hostBRecordId];
      assertThat(workspaceHostReferenceMarkers.every((recordId) =>
        typeof recordId === 'string' && recordId.length > 0) &&
        new Set(workspaceHostReferenceMarkers).size === 2,
      'maximum-pane Host reference privacy check did not capture distinct Host IDs');

      stage = 'Profile A navigate to Workspaces before maximum-pane creation';
      await click(pageA, 'Workspaces');
      await waitForVisibleSemanticText(pageA, 'Saved workspaces',
        'Profile A saved Workspaces page before max-pane creation', 15000);
      const splitBaseline = serverVaultSnapshot(databasePath).vaults[0];
      const splitPushBaseline = workspaceSplitPushes.length;
      const splitPushResponseBaseline = workspaceSplitPushResponses.length;
      const splitPullBaseline = splitPullChangePages.length;
      const apiPrivacyBaseline = apiPrivacyChecks.length;
      const profileBSyncPushBaseline = vaultSyncApiEvents.B.length;
      const relayBaseline = {
        ticketsA: relayAttempts.A.length,
        ticketsB: relayAttempts.B.length,
        socketsA: relayWebSockets.A,
        socketsB: relayWebSockets.B,
        activeA: activeRelayWebSockets.A.size,
        activeB: activeRelayWebSockets.B.size,
        sinks: relaySinkSnapshot(),
      };
      captureWorkspaceSplit = true;
      stage = 'Profile A create the eight-pane recursive Workspace';
      const expectedHosts = await createMaximumPaneWorkspace(
        pageA, MAX_PANES_WORKSPACE_NAME,
      );
      await installSplitSaveFeedbackProbe(pageA);
      await click(pageA, 'Save split Workspace');
      await waitForSavedSplitWorkspaceCard(
        pageA, MAX_PANES_WORKSPACE_NAME, 1, 20000, 'total',
      );
      await stopSplitSaveFeedbackProbe(pageA);

      stage = 'Profile A commit the eight-pane Workspace exactly once';
      await syncNow(pageA, 'maximum-pane Workspace encrypted save');
      const splitOperation = await waitForCaptured(() =>
        workspaceSplitPushes.slice(splitPushBaseline)
          .flatMap((push) => push.operations)
          .find((operation) => operation.operation === 'create' &&
            operation.recordId && operation.revisionId && operation.opId),
      'maximum-pane Workspace encrypted create envelope');
      const splitPushes = workspaceSplitPushes.slice(splitPushBaseline);
      const matchingSplitPush = splitPushes.find((push) =>
        push.operations.includes(splitOperation));
      assertThat(splitPushes.length === 1 &&
        matchingSplitPush?.operations.length === 1 &&
        matchingSplitPush.requestBodyPlaintextMarkersAbsent === true &&
        matchingSplitPush.encryptedWorkspaceHostReferenceMarkersAbsent === true &&
        splitOperation.envelopeShapeValid === true,
      'maximum-pane Workspace was not one opaque encrypted create operation');
      const splitReceipt = await waitForCaptured(() =>
        workspaceSplitPushResponses.slice(splitPushResponseBaseline).find((response) =>
          response.status === 200 && response.results.length === 1 &&
          response.results[0].opId === splitOperation.opId &&
          response.results[0].revisionId === splitOperation.revisionId &&
          response.results[0].commitSeq &&
          !response.results[0].alreadyCommitted),
      'maximum-pane Workspace first-commit receipt');
      encryptedWorkspacePrivacyRecordId = splitOperation.recordId;
      assertThat(splitReceipt.encryptedWorkspaceHostReferenceMarkersAbsent === true,
        'maximum-pane Workspace push response exposed Host record IDs');

      const afterSplit = serverVaultSnapshot(databasePath).vaults[0];
      assertThat(afterSplit &&
        BigInt(afterSplit.commitSeq) === BigInt(splitBaseline.commitSeq) + 1n,
      'one maximum-pane Workspace save did not create exactly one Vault commit');
      const splitCommit = serverCommitDelta(
        databasePath, vaultId, splitBaseline.commitSeq, afterSplit.commitSeq,
      );
      const splitState = serverWorkspaceRecordSnapshot(
        databasePath,
        vaultId,
        splitOperation.recordId,
        [...splitEnvelopeMarkers, ...workspaceHostReferenceMarkers],
      );
      const splitVersion = splitState.versions[0];
      const splitEvent = splitState.events[0];
      const splitDbReceipt = splitState.receipts[0];
      assertThat(splitCommit.eventCount === 1 &&
        splitCommit.distinctCommitCount === 1 &&
        splitState.versions.length === 1 && splitVersion.operation === 'create' &&
        splitVersion.headerRevisionId === splitOperation.revisionId &&
        splitVersion.opId === splitOperation.opId &&
        splitVersion.envelopeSha256 === splitOperation.envelopeSha256 &&
        splitVersion.validEnvelope && splitVersion.markersAbsent &&
        splitState.events.length === 1 && splitEvent.operation === 'create' &&
        splitEvent.revisionId === splitVersion.revisionId &&
        splitEvent.commitSeq === splitVersion.commitSeq &&
        splitState.headRevisionId === splitVersion.revisionId &&
        !splitState.headDeleted && splitState.headCommitSeq === splitVersion.commitSeq &&
        splitState.receipts.length === 1 &&
        splitDbReceipt?.recordId === splitOperation.recordId &&
        splitDbReceipt.revisionId === splitOperation.revisionId &&
        splitDbReceipt.commitSeq === splitVersion.commitSeq &&
        splitReceipt.results[0].commitSeq === splitVersion.commitSeq,
      'maximum-pane Workspace encrypted create, event, head, and receipt did not link');

      stage = 'Profile B pull the encrypted eight-pane Workspace';
      await click(pageB, 'Workspaces');
      await waitForVisibleSemanticText(pageB, 'Saved workspaces',
        'Profile B Workspaces page before max-pane pull', 15000);
      const bPendingBeforePull = await visibleSyncPendingSnapshot(pageB);
      const bWorkspaceCardVisibleBeforePull = await visibleSemanticTextMatch(
        pageB, MAX_PANES_WORKSPACE_NAME,
      );
      const bPreviewCardCountBeforePull = await visibleWorkspacePreviewCardCount(pageB);
      const bChangePage = await syncNow(pageB,
        'Profile B maximum-pane Workspace force pull', { forcePull: true });
      const profileBWorkspacePullEvidence = () => {
        const pages = splitPullChangePages.slice(splitPullBaseline);
        const pageEvidence = pages.map((page) => {
          const matchingIndexes = (page.seenRecordIds || [])
            .flatMap((recordId, index) => recordId === splitOperation.recordId
              ? [index] : []);
          const envelopeChecks = page.workspaceEnvelopeHostReferenceChecks || [];
          const matchingEnvelope = envelopeChecks.find((check) =>
            check.recordIdMatchesWorkspace && check.envelopePresent);
          const exactCreate = matchingIndexes.length === 1 &&
            page.seenOperationKinds?.[matchingIndexes[0]] === 'create';
          return {
            page,
            exactCreate,
            matchingEnvelope,
            exactPrivateCreate: page.httpStatus === 200 &&
              page.responsePlaintextMarkersAbsent === true && exactCreate &&
              matchingEnvelope?.hostReferenceMarkersAbsent === true,
          };
        });
        return {
          pages,
          pageEvidence,
          exactPrivatePage: pageEvidence.find((item) => item.exactPrivateCreate) || null,
        };
      };
      const profileBWorkspaceCaptureSummary = () => {
        const evidence = profileBWorkspacePullEvidence();
        return {
          changesPagesAfterBaseline: evidence.pages.length,
          successfulChangesPages: evidence.pages.filter((page) =>
            page.httpStatus === 200).length,
          markerPrivateChangesPages: evidence.pages.filter((page) =>
            page.responsePlaintextMarkersAbsent === true).length,
          pagesWithWorkspaceRecord: evidence.pageEvidence.filter((item) =>
            (item.page.seenRecordIds || []).includes(splitOperation.recordId)).length,
          pagesWithWorkspaceCreate: evidence.pageEvidence.filter((item) =>
            item.exactCreate).length,
          matchingWorkspaceEnvelopeChecks: evidence.pageEvidence.filter((item) =>
            item.matchingEnvelope !== undefined).length,
          privateWorkspaceEnvelopeChecks: evidence.pageEvidence.filter((item) =>
            item.matchingEnvelope?.hostReferenceMarkersAbsent === true).length,
          exactPrivateWorkspaceCreatePages: evidence.pageEvidence.filter((item) =>
            item.exactPrivateCreate).length,
        };
      };
      stage = 'Profile B wait for captured maximum-pane Workspace event and envelope';
      let capturedWorkspacePull = null;
      try {
        capturedWorkspacePull = await waitForCaptured(() =>
          profileBWorkspacePullEvidence().exactPrivatePage,
        'Profile B maximum-pane Workspace exact create event and private envelope');
      } catch (_) {
        const safePageSummary = profileBWorkspacePullEvidence().pageEvidence;
        const bPendingAfterPull = await visibleSyncPendingSnapshot(pageB);
        const bWorkspaceCardVisibleAfterPull = await visibleSemanticTextMatch(
          pageB, MAX_PANES_WORKSPACE_NAME,
        );
        stage = `Profile B maximum-pane pull capture timed out (${JSON.stringify({
          forcePullResponseStatus200: bChangePage?.httpStatus === 200,
          forcePullResponseContainsWorkspaceRecord:
            bChangePage?.seenRecordIds?.includes(splitOperation.recordId) === true,
          forcePullResponseMarkersAbsent:
            bChangePage?.responsePlaintextMarkersAbsent === true,
          forcePullResponseCreateEvent:
            bChangePage?.seenOperationKinds?.[bChangePage?.seenRecordIds?.indexOf(
              splitOperation.recordId,
            )] === 'create',
          ...profileBWorkspaceCaptureSummary(),
          pagesWithWorkspaceEnvelopePresent: safePageSummary.filter((item) =>
            item.matchingEnvelope?.envelopePresent === true).length,
          pagesWithHostReferenceMarkersAbsent: safePageSummary.filter((item) =>
            item.matchingEnvelope?.hostReferenceMarkersAbsent === true).length,
          workspaceCardVisibleBeforeForcePull: bWorkspaceCardVisibleBeforePull,
          workspaceCardVisibleAfterForcePull: bWorkspaceCardVisibleAfterPull,
          previewCardCountBeforeForcePull: bPreviewCardCountBeforePull,
          localPendingBeforeForcePull: bPendingBeforePull.pendingCount,
          localPendingAfterForcePull: bPendingAfterPull.pendingCount,
        })})`;
        throw new Error('Profile B did not capture the exact private Workspace create event');
      }
      const bPendingAfterPull = await visibleSyncPendingSnapshot(pageB);
      const bWorkspaceCardVisibleAfterPull = await visibleSemanticTextMatch(
        pageB, MAX_PANES_WORKSPACE_NAME,
      );
      const profileBPushCount = vaultSyncApiEvents.B
        .slice(profileBSyncPushBaseline)
        .filter((event) => event.endpoint === 'push' && event.method === 'POST').length;
      const profileBCommitSeqUnchanged =
        serverVaultSnapshot(databasePath).vaults[0]?.commitSeq === afterSplit.commitSeq;
      const bPullEvidenceCheckpoint = {
        forcePullResponseStatus200: bChangePage?.httpStatus === 200,
        forcePullResponseContainsWorkspaceRecord:
          bChangePage?.seenRecordIds?.includes(splitOperation.recordId) === true,
        forcePullResponseMarkersAbsent:
          bChangePage?.responsePlaintextMarkersAbsent === true,
        forcePullResponseCreateEvent:
          bChangePage?.seenOperationKinds?.[bChangePage?.seenRecordIds?.indexOf(
            splitOperation.recordId,
          )] === 'create',
        ...profileBWorkspaceCaptureSummary(),
        exactPrivateWorkspaceCreateCaptured:
          capturedWorkspacePull?.exactPrivateCreate === true,
        workspaceCardVisibleBeforeForcePull: bWorkspaceCardVisibleBeforePull,
        workspaceCardVisibleAfterForcePull: bWorkspaceCardVisibleAfterPull,
        previewCardCountBeforeForcePull: bPreviewCardCountBeforePull,
        localPendingBeforeForcePull: bPendingBeforePull.pendingCount,
        localPendingAfterForcePull: bPendingAfterPull.pendingCount,
        profileBPushRequestsAfterBaseline: profileBPushCount,
        serverCommitSeqUnchangedByProfileB: profileBCommitSeqUnchanged,
      };
      stage = `Profile B maximum-pane pull evidence (${JSON.stringify(bPullEvidenceCheckpoint)})`;
      console.log('WEB-WORKSPACE-MAX-PANES-PULL-CHECKPOINT',
        JSON.stringify(bPullEvidenceCheckpoint));
      assertThat(bChangePage?.httpStatus === 200 &&
        bChangePage.responsePlaintextMarkersAbsent === true &&
        capturedWorkspacePull?.exactPrivateCreate === true &&
        bPendingBeforePull.pendingCount === 0 &&
        bPendingAfterPull.pendingCount === 0 && profileBPushCount === 0 &&
        profileBCommitSeqUnchanged,
      'Profile B did not capture the exact private Workspace create with an empty local outbox and read-only pull');

      stage = 'Profile B decrypt the ordered eight-pane Workspace preview';
      await waitForVisibleSemanticText(pageB, MAX_PANES_WORKSPACE_NAME,
        'Profile B decrypted maximum-pane Workspace card', 15000);
      await waitForVisibleSemanticText(pageB, 'Active Pane 8',
        'Profile B active Pane 8 card metadata', 10000);
      const activePaneEightVisibleOnCard = await visibleSemanticTextMatch(
        pageB, 'Active Pane 8',
      );
      assertThat(activePaneEightVisibleOnCard,
        'Profile B decrypted Workspace card did not show Active Pane 8');
      for (const [index, hostName] of expectedHosts.entries()) {
        await waitForVisibleSemanticText(pageB,
          `Pane ${index + 1} · ${hostName}`,
          `Profile B ordered Pane ${index + 1} Host reference`, 10000);
      }
      const paneCardOrder = await pageB.evaluate((hosts) => {
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none';
        };
        const text = [...document.querySelectorAll('flt-semantics')]
          .filter(visible)
          .map((node) => (node.getAttribute('aria-label') || node.innerText ||
            node.textContent || '').replace(/\s+/g, ' ').trim()).join('\n');
        return hosts.map((host, index) =>
          text.indexOf(`Pane ${index + 1} · ${host}`));
      }, expectedHosts).catch(() => []);
      assertThat(paneCardOrder.length === 8 &&
        paneCardOrder.every((position, index) => position >= 0 &&
          (index === 0 || position > paneCardOrder[index - 1])),
        'Profile B did not render all eight ordered Host references');

      const previewButtons = pageB.getByRole('button', {
        name: 'Preview disconnected layout', exact: true,
      });
      assertThat(await previewButtons.count() === 1,
        'Profile B did not expose exactly one saved max-pane Workspace preview');
      await stageSplitWorkspacePreview(pageB, MAX_PANES_WORKSPACE_NAME, {
        existingWorkspaceNames: [],
        expectedHosts,
      });
      assertThat(await pageB.getByRole('button', {
        name: 'Close saved layout preview', exact: true,
      }).count() === 1,
      'Profile B could not reopen and close the saved eight-pane layout preview');
      await click(pageB, 'Close saved layout preview');
      console.log('WEB-WORKSPACE-MAX-PANES-RECEIVED-CHECKPOINT', JSON.stringify({
        exactPrivateWorkspaceCreateCaptured:
          capturedWorkspacePull?.exactPrivateCreate === true,
        workspaceCardVisibleAfterPull: bWorkspaceCardVisibleAfterPull ||
          await visibleSemanticTextMatch(pageB, MAX_PANES_WORKSPACE_NAME),
        orderedPaneCount: paneCardOrder.length,
        orderedHostReferences: paneCardOrder.length === 8 &&
          paneCardOrder.every((position, index) => position >= 0 &&
            (index === 0 || position > paneCardOrder[index - 1])),
        activePaneEightVisible: activePaneEightVisibleOnCard,
        previewOpenedAndClosed: true,
      }));

      const finalRelaySinks = relaySinkSnapshot();
      const apiPlaintextMarkerLeaks = apiPrivacyChecks.slice(apiPrivacyBaseline)
        .filter((check) => !check.markersAbsent).length;
      const databaseMarkers = serverPlaintextMarkers(databasePath);
      const serverLogText = fs.readFileSync(path.join(tempRoot, 'server.log'), 'utf8');
      const serverLogMarkersAbsent = markerScan(serverLogText);
      assertThat(apiPrivacyChecks.length > apiPrivacyBaseline &&
        apiPlaintextMarkerLeaks === 0 && databaseMarkers.length === 0 &&
        serverLogMarkersAbsent,
      'Workspace synthetic marker appeared in sync APIs, SQLite, WAL, SHM, or server logs');
      assertThat(relayAttempts.A.length === relayBaseline.ticketsA &&
        relayAttempts.B.length === relayBaseline.ticketsB &&
        relayWebSockets.A === relayBaseline.socketsA &&
        relayWebSockets.B === relayBaseline.socketsB &&
        activeRelayWebSockets.A.size === relayBaseline.activeA &&
        activeRelayWebSockets.B.size === relayBaseline.activeB &&
        finalRelaySinks.every((sink, index) =>
          sink.accepted === relayBaseline.sinks[index].accepted &&
          sink.active === relayBaseline.sinks[index].active),
      'maximum-pane create/pull/preview unexpectedly used SSH Relay');
      assertThat(pageErrors.length === 0,
        'a browser profile reported a Flutter page error during maximum-pane acceptance');

      console.log('WEB-WORKSPACE-MAX-PANES-01 passed', JSON.stringify({
        paneLimit: 8,
        addDisabledAtLimit: true,
        removeThenAddRestoredLimit: true,
        oneEncryptedWorkspaceCreate: splitPushes.length === 1 &&
          splitPushes[0].operations.length === 1,
        oneFirstCommitReceipt: splitState.receipts.length === 1,
        profileBPulledAndReopened: true,
        orderedHostReferences: paneCardOrder.length,
        activePane: 8,
        workspaceHostIdsAbsentFromPushPullAndStoredEnvelope: true,
        apiPlaintextMarkerLeakChecks: apiPlaintextMarkerLeaks,
        databaseMarkerCount: databaseMarkers.length,
        serverLogMarkersAbsent,
        relayDelta: 0,
        pageErrorCount: pageErrors.length,
      }));
      return;
    }
    stage = 'return to Hosts after Host B sync';
    await click(pageA, 'Hosts');
    await openHostTab(pageA, HOST_B_NAME);
    stage = 'return to Hosts before opening the second Host B terminal tab';
    await click(pageA, 'Hosts');
    await openHostTab(pageA, HOST_B_NAME);
    stage = 'navigate to Workspaces after opening two Host B terminal tabs';
    await click(pageA, 'Workspaces');
    await syncNow(pageA, 'workspace page baseline sync');

    stage = 'read baseline Vault commit count before workspace save';
    const beforeSave = serverVaultSnapshot(databasePath);
    assertThat(beforeSave.vaults.length === 1, 'acceptance expected one active Vault');
    assertThat(beforeSave.vaults[0].vaultId === vaultId,
      'active Vault changed after Host A record capture');
    const baselineCommitSeq = beforeSave.vaults[0].commitSeq;
    captureWorkspaceSave = true;
    let saveFeedback = 'unobserved';
    stage = 'open Save current tabs dialog';
    await click(pageA, 'Save current tabs');
    stage = 'fill Workspace name';
    await fill(pageA, 'Workspace name', WORKSPACE_NAME);
    stage = 'submit Workspace save';
    await click(pageA, 'Save');
    saveFeedback = await observeWorkspaceSaveFeedback(pageA, WORKSPACE_NAME);
    stage = 'wait for saved Workspace card';
    try {
      await visibleButton(pageA, 'Preview disconnected layout');
    } catch (error) {
      const outcome = await pageA.evaluate((workspaceName) => {
        const body = document.body?.innerText || '';
        if (body.includes(workspaceName)) return 'workspace-name-visible';
        if (body.includes('加密同步有序终端标签和 Host 引用')) return 'workspace-page-visible';
        if (body.includes('请先打开至少一个终端标签')) return 'no-terminal-tabs';
        if (body.includes('终端引用的主机已不在当前 Vault')) return 'stale-terminal-host';
        if (body.includes('工作区只能新增引用当前 Vault 中现有的主机')) return 'missing-active-host';
        if (body.includes('Workspace saved encrypted to this Vault.')) return 'save-handler-returned';
        if (body.includes('工作区已加密保存')) return 'save-handler-returned';
        if (body.includes('Save workspace')) return 'save-dialog-still-open';
        if (body.includes('No saved workspaces')) return 'empty-workspace-list';
        if (body.includes('Terminal workspace')) return 'terminal-page-visible';
        if (body.includes('Host groups')) return 'groups-page-visible';
        if (body.includes('Command snippets')) return 'snippets-page-visible';
        if (body.includes('Sync & conflicts')) return 'sync-page-visible';
        if (/failed|error|cannot|could not|请先|无法|不能|不可|只读|失败/i.test(body)) return 'visible-error-message';
        if (body.includes('Saved workspaces')) return 'workspace-list-open';
        return 'unclassified';
      }, WORKSPACE_NAME).catch(() => 'page-unavailable');
      const savedOperations = workspaceSavePushes.flatMap((item) => item.operations);
      const createOperations = savedOperations.filter((item) => item.operation === 'create').length;
      const successfulPushReceipts = workspaceSavePushResponses
        .filter((item) => item.status === 200)
        .flatMap((item) => item.results).length;
      let commitDelta = 'unavailable';
      let unsupportedRecordVisible = false;
      let syncPageOpened = false;
      try {
        const current = serverVaultSnapshot(databasePath).vaults
          .find((item) => item.vaultId === vaultId);
        if (current) commitDelta = (BigInt(current.commitSeq) - BigInt(baselineCommitSeq)).toString();
      } catch (_) {}
      try {
        await click(pageA, 'Sync & conflicts');
        await waitForText(pageA, 'Offline-first, ciphertext-only', 5000);
        syncPageOpened = true;
        unsupportedRecordVisible = await pageA.getByText(
          /encrypted record\(s\) could not be verified/i,
        ).count() > 0;
      } catch (_) {}
      stage = `wait for saved Workspace card (${outcome}; feedback=${saveFeedback}; creates=${createOperations}; receipts=${successfulPushReceipts}; commits=${commitDelta}; syncPage=${syncPageOpened}; unsupported=${unsupportedRecordVisible}; pageErrors=${pageErrors.length})`;
      throw error;
    }
    stage = 'sync saved Workspace create';
    await syncNow(pageA, 'workspace save sync');
    stage = 'wait for Workspace create sync settle';
    await pageA.waitForTimeout(250);
    captureWorkspaceSave = false;
    const afterSave = serverVaultSnapshot(databasePath);
    const afterSaveVault = afterSave.vaults.find((item) => item.vaultId === vaultId);
    assertThat(afterSaveVault &&
      BigInt(afterSaveVault.commitSeq) === BigInt(baselineCommitSeq) + 1n,
    'one workspace save did not create exactly one Vault commit');
    const saveDelta = serverCommitDelta(
      databasePath,
      vaultId,
      baselineCommitSeq,
      afterSaveVault.commitSeq,
    );
    const savedOperations = workspaceSavePushes.flatMap((item) => item.operations);
    const savedOperationIds = new Set(savedOperations.map((item) => item.opId).filter(Boolean));
    assertThat(saveDelta.eventCount === 1 && saveDelta.distinctCommitCount === 1 &&
      savedOperations.length === 1 && savedOperationIds.size === 1 &&
      savedOperations[0].operation === 'create' &&
      savedOperationIds.values().next().value === savedOperations[0].opId,
    'workspace save was not a single encrypted create operation and commit');
    const successfulSaveReceipts = workspaceSavePushResponses
      .filter((item) => item.status === 200)
      .flatMap((item) => item.results);
    assertThat(successfulSaveReceipts.length === 1 &&
      successfulSaveReceipts[0].commitSeq === afterSaveVault.commitSeq &&
      !successfulSaveReceipts[0].alreadyCommitted,
    'workspace save did not receive one first-commit sync receipt');
    workspaceRecordId = savedOperations[0].recordId;

    stage = 'Profile B pulls the saved Workspace into its independent profile';
    await click(pageB, 'Workspaces');
    await syncNow(pageB, 'profile B workspace pull', { forcePull: true });
    await visibleButton(pageB, 'Preview disconnected layout');

    stage = 'delete referenced Host B to prepare two missing Workspace panes';
    await click(pageA, 'Hosts');
    const hostBCardForConflict = pageA.getByRole('group', {
      name: new RegExp(`^Host: ${escapeRegExp(HOST_B_NAME)}; `),
    }).first();
    await hostBCardForConflict.getByRole('button', {
      name: 'More actions', exact: true,
    }).click();
    await pageA.getByRole('menuitem', { name: 'Delete', exact: true }).click();
    await waitForText(pageA, 'Delete this item?');
    await pageA.getByRole('button', { name: 'Delete', exact: true }).last().click();
    await waitForText(pageA, 'Saved hosts');
    await syncNow(pageA, 'delete shared Host B before Workspace race');
    await syncNow(pageB, 'Profile B pulls both missing Host references', { forcePull: true });
    stage = 'return Profile A to Workspaces after both Host deletions';
    await click(pageA, 'Workspaces');

    stage = 'create and synchronize two replacement Hosts for divergent offline layouts';
    const beforeHostCCreate = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(beforeHostCCreate, 'Host C creation did not find the active Vault');
    await addHost(pageA, HOST_C_NAME, HOST_C_ADDRESS, { attachCredential: false });
    await syncNow(pageA, 'Host C sync for Workspace conflict');
    const afterHostCCreate = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(afterHostCCreate, 'Host C creation lost the active Vault');
    const hostCCreateDelta = serverCommitDelta(
      databasePath, vaultId, beforeHostCCreate.commitSeq, afterHostCCreate.commitSeq,
    );
    assertThat(hostCCreateDelta.eventCount === 1 &&
      hostCCreateDelta.events[0].operation === 'create',
    'Host C did not create one synced Host record');
    hostCRecordId = hostCCreateDelta.events[0].recordId;
    assertThat(typeof hostCRecordId === 'string' && hostCRecordId.length > 0,
      'Host C create did not expose an opaque synced record ID');
    await addHost(pageA, HOST_D_NAME, HOST_D_ADDRESS, { attachCredential: false });
    await syncNow(pageA, 'Host D sync for Workspace conflict');
    await syncNow(pageB, 'Profile B pulls replacement Hosts', { forcePull: true });
    await click(pageA, 'Workspaces');
    await click(pageB, 'Workspaces');
    stage = 'verify both profiles show two repairable missing Workspace panes';
    const bothProfilesHaveTwoMissingPanes =
      await pageA.getByRole('button', {
      name: 'Replace Host', exact: true,
      }).count() === 2 && await pageB.getByRole('button', {
      name: 'Replace Host', exact: true,
      }).count() === 2;
    assertThat(bothProfilesHaveTwoMissingPanes,
    'both profiles did not share the same repairable Workspace base');

    const beforeConflictVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const baseWorkspaceHead = serverWorkspaceHead(databasePath, vaultId, workspaceRecordId);
    assertThat(beforeConflictVault && baseWorkspaceHead.revisionId &&
      !baseWorkspaceHead.deleted,
    'Workspace conflict fixture did not start from a committed active revision');
    const relayBeforeWorkspaceConflict = {
      A: relayAttempts.A.length,
      B: relayAttempts.B.length,
      socketsA: relayWebSockets.A,
      socketsB: relayWebSockets.B,
    };
    captureWorkspaceConflict = true;
    await Promise.all([contextA.setOffline(true), contextB.setOffline(true)]);
    stage = 'save distinct offline Host layouts from the shared Workspace revision';
    await replaceFirstMissingWorkspacePane(pageA, HOST_D_NAME, 'A');
    await replaceFirstMissingWorkspacePane(pageB, HOST_C_NAME, 'B');

    stage = 'commit Profile A Workspace branch before Profile B';
    await contextA.setOffline(false);
    await syncNow(pageA, 'Profile A Workspace branch commit');
    const waitForWorkspaceCapture = async (predicate, label, page = pageB) => {
      const deadline = Date.now() + 45000;
      while (Date.now() < deadline) {
        const value = predicate();
        if (value) return value;
        await page.waitForTimeout(100);
      }
      throw new Error(`Workspace conflict capture timed out: ${label}`);
    };
    const branchAOperation = await waitForWorkspaceCapture(() =>
      workspaceConflictPushes.flatMap((item) => item.operations.map((operation) => ({
        ...operation,
        profile: item.profile,
        requestBodyPlaintextMarkersAbsent: item.requestBodyPlaintextMarkersAbsent,
      }))).find((item) => item.profile === 'A' &&
        item.recordId === workspaceRecordId && item.operation === 'update'),
    'A update');
    const branchAResponse = await waitForWorkspaceCapture(() =>
      workspaceConflictPushResponses.find((item) => item.profile === 'A' &&
        item.status === 200 && item.results.some((result) =>
          result.opId === branchAOperation.opId && result.commitSeq &&
          !result.alreadyCommitted)),
    'A update receipt', pageA);
    assertThat(branchAOperation.baseRevisionId === baseWorkspaceHead.revisionId &&
      branchAOperation.requestBodyPlaintextMarkersAbsent &&
      branchAResponse.status === 200,
    'Profile A Workspace edit did not commit from the common encrypted base');
    const branchAReceipt = branchAResponse.results.find((result) =>
      result.opId === branchAOperation.opId && result.commitSeq &&
      !result.alreadyCommitted);
    assertThat(branchAReceipt, 'Profile A Workspace update has no first-commit receipt');

    stage = 'Profile B wait for POST /conflicts response registration';
    const conflictPostResponse = pageB.waitForResponse((response) => {
      const url = new URL(response.url());
      return response.request().method() === 'POST' && url.pathname.endsWith('/conflicts');
    }, { timeout: 45000 });
    stage = 'Profile B return online for stale Workspace conflict upload';
    await contextB.setOffline(false);
    stage = 'Profile B explicit post-reconnect sync of stale Workspace branch';
    await syncNow(pageB, 'Profile B publishes stale Workspace branch', {
      allowSettledPending: true,
    });
    stage = 'Profile B await stale Workspace POST /conflicts response';
    let conflictPost;
    try {
      conflictPost = await conflictPostResponse;
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      console.error(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
        phase: 'post-response',
        postReconnectSync: 'explicit',
        errorClass,
        ...workspaceConflictCaptureCounts(),
      })}`);
      stage = `Profile B POST /conflicts response wait failed (${errorClass})`;
      throw error;
    }
    console.log(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
      phase: 'post-response',
      postReconnectSync: 'explicit',
      httpStatus: conflictPost.status(),
      ...workspaceConflictCaptureCounts(),
    })}`);
    assertThat(conflictPost.status() === 200 || conflictPost.status() === 201,
      `Profile B Workspace conflict returned HTTP ${conflictPost.status()}`);
    stage = 'Profile B wait for captured stale Workspace conflict envelope';
    let branchBUpload;
    try {
      branchBUpload = await waitForWorkspaceCapture(() =>
        workspaceConflictUploads.find((item) => item.recordId === workspaceRecordId &&
          item.operation === 'update'),
      'B stale conflict envelope');
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      console.error(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
        phase: 'envelope-capture',
        errorClass,
        ...workspaceConflictCaptureCounts(),
      })}`);
      stage = `Profile B stale Workspace conflict envelope capture failed (${errorClass})`;
      throw error;
    }
    console.log(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
      phase: 'envelope-capture',
      ...workspaceConflictCaptureCounts(),
    })}`);
    stage = 'Profile B wait for captured Workspace conflict ID';
    let conflictId;
    try {
      conflictId = await waitForWorkspaceCapture(() =>
        workspaceConflictUploadResponses.find((item) =>
          (item.status === 200 || item.status === 201) && item.conflictId)?.conflictId,
      'conflict ID');
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      console.error(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
        phase: 'conflict-id-capture',
        errorClass,
        ...workspaceConflictCaptureCounts(),
      })}`);
      stage = `Profile B conflict ID capture failed (${errorClass})`;
      throw error;
    }
    console.log(`WEB-WORKSPACE-CONFLICT-UPLOAD-CHECKPOINT ${JSON.stringify({
      phase: 'conflict-id-capture',
      ...workspaceConflictCaptureCounts(),
    })}`);
    assertThat(branchBUpload.baseRevisionId === baseWorkspaceHead.revisionId &&
      branchBUpload.opId !== branchAOperation.opId &&
      branchBUpload.revisionId !== branchAOperation.revisionId &&
      branchBUpload.envelopeShapeValid &&
      branchBUpload.requestBodyPlaintextMarkersAbsent,
    'Profile B did not preserve its distinct encrypted stale Workspace branch');

    stage = 'Profile A receives opaque Workspace conflict feed';
    await syncNow(pageA, 'Profile A pulls Workspace conflict feed', { forcePull: true });
    stage = 'Profile A opens Sync & conflicts with any unread badge';
    await clickConflictInbox(pageA);
    stage = 'Profile A sees Workspace conflict inbox';
    await waitForText(pageA, '跨设备冲突收件箱');
    await waitForWorkspaceCapture(() => workspaceConflictFeedEvents.find((item) =>
      item.profile === 'A' && item.type === 'created' &&
      item.conflictId === conflictId && item.recordId === workspaceRecordId),
    'A conflict-created event', pageA);
    stage = 'Profile B opens Workspace conflict inbox';
    await clickConflictInbox(pageB);
    await waitForText(pageB, '跨设备冲突收件箱');
    stage = 'Profile B locates the local Workspace conflict copy action';
    let copyBranchButton;
    try {
      copyBranchButton = await visibleButton(pageB, 'Save local layout as named copy');
    } catch (error) {
      const conflictUi = await pageB.evaluate((workspaceName) => {
        const labels = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((node) => {
            const rect = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
              style.display !== 'none';
          })
          .map((node) => (node.getAttribute('aria-label') || node.innerText || '').trim());
        const body = document.body?.innerText || '';
        return {
          saveCopyAction: labels.some((label) => label.includes('Save local layout as named copy')),
          localKeepAction: labels.some((label) => label.includes('Keep this device version')),
          localUseSyncedAction: labels.some((label) => label.includes('Use synced version')),
          conflictBranchesHeading: body.includes('Conflict branches'),
          noOpenLocalConflicts: body.includes('No open conflicts'),
          workspaceRecordVisible: body.includes(workspaceName),
          actionLabelCount: labels.filter((label) => /conflict|layout|version/i.test(label)).length,
        };
      }, WORKSPACE_NAME).catch(() => ({ diagnosticUnavailable: true }));
      stage = `Profile B local Workspace conflict action missing (${JSON.stringify(conflictUi)})`;
      throw error;
    }
    await copyBranchButton.click();
    await waitForText(pageB, 'Save conflict branch as workspace copy');
    await fill(pageB, 'Workspace name', WORKSPACE_BRANCH_B_COPY_NAME);
    await click(pageB, 'Save');
    stage = 'save the B conflict branch as a new encrypted Workspace';
    // The original unresolved conflict remains in the local outbox as a
    // conflict-status operation until the explicit resolution below. The UI
    // therefore reports a settled "1 pending" badge even after the independent
    // named-copy create has received its server receipt.
    await syncNow(pageB, 'Workspace conflict named copy create', {
      allowSettledPending: true,
    });
    const copyOperation = await waitForWorkspaceCapture(() =>
      workspaceConflictPushes.flatMap((item) => item.operations.map((operation) => ({
        ...operation,
        profile: item.profile,
        requestBodyPlaintextMarkersAbsent: item.requestBodyPlaintextMarkersAbsent,
      }))).find((item) => item.profile === 'B' && item.operation === 'create' &&
        item.recordId !== workspaceRecordId),
    'B named copy create operation');
    const copyReceipt = await waitForWorkspaceCapture(() =>
      workspaceConflictPushResponses.find((item) => item.profile === 'B' &&
        item.status === 200 && item.results.some((result) =>
          result.opId === copyOperation.opId && result.commitSeq &&
          !result.alreadyCommitted)),
    'B named copy create receipt');
    const namedCopyReceipt = copyReceipt.results.find((result) =>
      result.opId === copyOperation.opId && result.commitSeq &&
      !result.alreadyCommitted);
    assertThat(copyOperation.requestBodyPlaintextMarkersAbsent &&
      copyReceipt.status === 200 && namedCopyReceipt,
      'named Workspace copy was not committed as a ciphertext-only create');
    const openConflictCopyAction = pageB.getByRole('button', {
      name: 'Save local layout as named copy', exact: true,
    });
    const openConflictResolutionAction = pageB.getByRole('button', {
      name: 'Use synced version', exact: true,
    });
    await openConflictCopyAction.waitFor({ state: 'visible', timeout: 10000 });
    await openConflictResolutionAction.waitFor({ state: 'visible', timeout: 10000 });

    const afterNamedCopyVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const namedCopyPushCount = () => workspaceConflictPushes
      .filter((item) => item.profile === 'B')
      .flatMap((item) => item.operations)
      .filter((operation) => operation.opId === copyOperation.opId).length;
    assertThat(afterNamedCopyVault &&
      BigInt(afterNamedCopyVault.commitSeq) === BigInt(beforeConflictVault.commitSeq) + 2n &&
      BigInt(afterNamedCopyVault.conflictSeq) === BigInt(beforeConflictVault.conflictSeq) + 1n &&
      namedCopyReceipt.commitSeq === afterNamedCopyVault.commitSeq &&
      namedCopyPushCount() === 1,
    'named copy did not produce exactly one new Vault commit and conflict sequence');

    stage = 'Profile B restore browser profile after Web reload';
    let reloadRecovery;
    try {
      reloadRecovery = await restoreWorkspaceAfterReload(pageB, 'B', baseUrl);
    } catch (error) {
      stage = `Profile B reload restoration call failed (${error.name}; innerStage=${stage})`;
      throw error;
    }
    const profileBReauthenticatedAfterReload =
      reloadRecovery.submittedLogin || reloadRecovery.submittedUnlock;
    assertThat(profileBReauthenticatedAfterReload,
      'Profile B reload did not require and complete authentication/unlock');
    stage = 'Profile B navigate to Workspaces after Web reload';
    await click(pageB, 'Workspaces');
    await syncNow(pageB, 'Profile B post-reload Workspace conflict pull', {
      forcePull: true,
      allowSettledPending: true,
    });
    const afterReloadPullVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const postReloadPullHadNoDuplicateWork = afterReloadPullVault &&
      afterReloadPullVault.commitSeq === afterNamedCopyVault.commitSeq &&
      afterReloadPullVault.conflictSeq === afterNamedCopyVault.conflictSeq &&
      namedCopyPushCount() === 1;
    assertThat(postReloadPullHadNoDuplicateWork,
    'post-reload pull repeated a Workspace copy push or created a server commit/conflict event');

    stage = 'verify Profile B retained the decrypted named copy after Web reload';
    const profileBCopySurvivedReload = await previewNamedWorkspace(
      pageB,
      WORKSPACE_BRANCH_B_COPY_NAME,
      HOST_C_NAME,
      'B after reload',
    );
    assertThat(profileBCopySurvivedReload,
      'Profile B did not retain its decrypted named Workspace copy after reload');
    await clickConflictInbox(pageB);
    await waitForText(pageB, '跨设备冲突收件箱');
    const reloadedConflictCopyAction = pageB.getByRole('button', {
      name: 'Save local layout as named copy', exact: true,
    });
    const reloadedConflictResolutionAction = pageB.getByRole('button', {
      name: 'Use synced version', exact: true,
    });
    await reloadedConflictCopyAction.waitFor({ state: 'visible', timeout: 10000 });
    await reloadedConflictResolutionAction.waitFor({ state: 'visible', timeout: 10000 });
    const localConflictActionsPersistedAfterReload =
      await reloadedConflictCopyAction.count() === 1 &&
      await reloadedConflictResolutionAction.count() === 1;
    assertThat(localConflictActionsPersistedAfterReload,
      'Profile B did not retain exactly one set of actions for its local Workspace conflict');

    stage = 'explicitly resolve original Workspace to the synced A branch';
    await reloadedConflictResolutionAction.click();
    await waitForText(pageB, 'Use the synced version?');
    await click(pageB, 'Create resolution');
    await syncNow(pageB, 'Workspace conflict resolution update');
    const resolutionRequest = await waitForWorkspaceCapture(() =>
      workspaceConflictResolutionRequests.find((item) => item.profile === 'B' &&
        item.conflictId === conflictId && item.resolvedRevisionId),
    'resolution request');
    const resolutionResponse = await waitForWorkspaceCapture(() =>
      workspaceConflictResolutionResponses.find((item) => item.profile === 'B' &&
        item.conflictId === conflictId && item.httpStatus === 200 &&
        item.status === 'resolved'),
    'resolution response');
    assertThat(resolutionResponse.resolvedRevisionId === resolutionRequest.resolvedRevisionId &&
      resolutionResponse.resolutionSeq && !resolutionResponse.alreadyResolved,
    'original Workspace conflict did not receive one successful explicit resolution');
    await pageB.getByRole('button', { name: 'Use synced version', exact: true }).waitFor({
      state: 'detached',
      timeout: 30000,
    });

    stage = 'pull resolved Workspace copy and original into Profile A';
    await click(pageA, 'Workspaces');
    await syncNow(pageA, 'Profile A Workspace conflict resolution pull', { forcePull: true });
    await waitForWorkspaceCapture(() => workspaceConflictFeedEvents.find((item) =>
      item.profile === 'A' && item.type === 'resolved' &&
      item.conflictId === conflictId &&
      item.resolvedRevisionId === resolutionResponse.resolvedRevisionId),
    'A conflict-resolved event', pageA);
    await click(pageA, 'Hosts');
    await click(pageA, 'Workspaces');
    await click(pageB, 'Workspaces');
    stage = 'inspect Profile A resolved and copied decrypted Workspace panes';
    const profileASeesBBranchCopy = await previewNamedWorkspace(
      pageA,
      WORKSPACE_BRANCH_B_COPY_NAME,
      HOST_C_NAME,
      'A',
    );
    const profileASeesSyncedABranch = await previewNamedWorkspace(
      pageA,
      WORKSPACE_NAME,
      HOST_D_NAME,
      'A',
    );
    stage = 'inspect Profile B resolved and copied decrypted Workspace panes';
    const profileBSeesBBranchCopy = await previewNamedWorkspace(
      pageB,
      WORKSPACE_BRANCH_B_COPY_NAME,
      HOST_C_NAME,
      'B',
    );
    const profileBSeesSyncedABranch = await previewNamedWorkspace(
      pageB,
      WORKSPACE_NAME,
      HOST_D_NAME,
      'B',
    );
    const profilesConverged = profileASeesBBranchCopy &&
      profileASeesSyncedABranch && profileBSeesBBranchCopy &&
      profileBSeesSyncedABranch;
    assertThat(profilesConverged,
      'Profile A/B did not decrypt the expected B-copy and resolved A layouts');

    stage = 'verify exact Workspace CAS, branch, receipt, and resolution state';
    const afterConflictVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const resolutionOperation = workspaceConflictPushes.flatMap((item) =>
      item.operations.map((operation) => ({
        ...operation,
        profile: item.profile,
        requestBodyPlaintextMarkersAbsent: item.requestBodyPlaintextMarkersAbsent,
      }))).find((item) => item.profile === 'B' &&
      item.recordId === workspaceRecordId && item.operation === 'update' &&
        item.revisionId === resolutionResponse.resolvedRevisionId);
    assertThat(resolutionOperation,
      'original Workspace resolution did not produce a captured update operation');
    const resolutionPushResponse = await waitForWorkspaceCapture(() =>
      workspaceConflictPushResponses.find((item) => item.profile === 'B' &&
        item.status === 200 && item.results.some((result) =>
          result.opId === resolutionOperation?.opId && result.commitSeq &&
          !result.alreadyCommitted)),
    'B original Workspace resolution update receipt');
    assertThat(namedCopyPushCount() === 1,
      'Profile B retried the named Workspace copy during original conflict resolution');
    const namedCopyStayedSinglePushThroughResolution = namedCopyPushCount() === 1;
    const resolutionReceipt = resolutionPushResponse.results.find((result) =>
      result.opId === resolutionOperation.opId && result.commitSeq &&
      !result.alreadyCommitted);
    stage = 'verify exact Workspace commit and conflict sequence deltas';
    assertThat(afterConflictVault && resolutionOperation &&
      resolutionReceipt &&
      BigInt(afterConflictVault.commitSeq) === BigInt(beforeConflictVault.commitSeq) + 3n &&
      BigInt(afterConflictVault.conflictSeq) === BigInt(beforeConflictVault.conflictSeq) + 2n,
    'Workspace conflict flow produced unexpected commit or conflict-feed sequence deltas');
    const conflictCommitDelta = serverCommitDelta(
      databasePath,
      vaultId,
      beforeConflictVault.commitSeq,
      afterConflictVault.commitSeq,
    );
    const committedOperations = [
      { ...branchAOperation, operation: 'update', commitSeq: branchAReceipt.commitSeq },
      { ...copyOperation, operation: 'create', commitSeq: namedCopyReceipt.commitSeq },
      { ...resolutionOperation, operation: 'update', commitSeq: resolutionReceipt.commitSeq },
    ].map((item) => ({
      recordId: item.recordId,
      revisionId: item.revisionId,
      opId: item.opId,
      operation: item.operation,
      commitSeq: String(item.commitSeq),
    }));
    const conflictSnapshot = serverWorkspaceConflictSnapshot(
      databasePath,
      vaultId,
      workspaceRecordId,
      copyOperation.recordId,
      {
        opId: branchBUpload.opId,
        revisionId: branchBUpload.revisionId,
        markers: PRIVACY_MARKERS,
        committedOperations,
      },
    );
    const conflictRow = conflictSnapshot.conflicts[0];
    const createdFeedEvents = workspaceConflictFeedEvents.filter((item) =>
      item.conflictId === conflictId && item.type === 'created');
    const resolvedFeedEvents = workspaceConflictFeedEvents.filter((item) =>
      item.conflictId === conflictId && item.type === 'resolved');
    const createdSequence = String(BigInt(beforeConflictVault.conflictSeq) + 1n);
    const resolvedSequence = String(BigInt(beforeConflictVault.conflictSeq) + 2n);
    const eachProfileSawExpectedConflictEvents = ['A', 'B'].every((profile) => {
      const created = createdFeedEvents.filter((item) => item.profile === profile);
      const resolved = resolvedFeedEvents.filter((item) => item.profile === profile);
      return created.length > 0 && created.every((item) =>
        item.sequence === createdSequence && item.hasEnvelope &&
        item.envelopePlaintextMarkersAbsent &&
        item.envelopeSha256 === branchBUpload.envelopeSha256) &&
        resolved.length > 0 && resolved.every((item) =>
          item.sequence === resolvedSequence && !item.hasEnvelope &&
          item.resolvedRevisionId === resolutionResponse.resolvedRevisionId);
    });
    const committedDatabaseEvidenceMatches = committedOperations.every((item) => {
      const record = item.recordId === workspaceRecordId
        ? conflictSnapshot.original
        : conflictSnapshot.copy;
      const version = record.versions.find((entry) =>
        entry.revisionId === item.revisionId && entry.opId === item.opId);
      const event = record.events.find((entry) =>
        entry.revisionId === item.revisionId);
      const receipt = record.receipts.find((entry) => item.opId === entry.opId);
      return version && version.headerOperation === item.operation &&
        version.commitSeq === item.commitSeq && event &&
        event.operation === item.operation && event.commitSeq === item.commitSeq &&
        receipt && receipt.count === 1 && receipt.matches &&
        receipt.commitSeq === item.commitSeq;
    });
    const exactCommitDelta = conflictCommitDelta.events.length === committedOperations.length &&
      conflictCommitDelta.events.every((event, index) => {
        const expected = committedOperations[index];
      return event.operation === expected.operation &&
        event.recordId === expected.recordId &&
        event.revisionId === expected.revisionId &&
        event.commitSeq === expected.commitSeq;
      });
    stage = 'verify Workspace commit receipt, version, event, and stale-branch links';
    assertThat(conflictCommitDelta.eventCount === 3 &&
      conflictCommitDelta.distinctCommitCount === 3 &&
      exactCommitDelta && committedDatabaseEvidenceMatches &&
      conflictSnapshot.staleReceiptCount === 0 &&
      conflictSnapshot.staleVersionCount === 0 && conflictSnapshot.staleEventCount === 0 &&
      conflictSnapshot.original.receipts.length === 2 &&
      conflictSnapshot.original.receipts.every((item) => item.count === 1 && item.matches) &&
      conflictSnapshot.copy.receipts.length === 1 &&
      conflictSnapshot.copy.receipts.every((item) => item.count === 1 && item.matches),
    'Workspace commit associations or stale-branch non-commit evidence were incomplete');
    stage = 'verify stored conflict and encrypted named-copy state';
    assertThat(conflictSnapshot.conflicts.length === 1 && conflictRow &&
      conflictRow.conflictId === conflictId &&
      conflictRow.recordId === workspaceRecordId &&
      conflictRow.baseRevisionId === baseWorkspaceHead.revisionId &&
      conflictRow.opId === branchBUpload.opId &&
      conflictRow.revisionId === branchBUpload.revisionId &&
      conflictRow.conflictSeq === createdSequence,
    'stored conflict row identity or creation sequence did not match the stale branch');
    stage = 'verify stored encrypted stale conflict envelope';
    assertThat(conflictRow.validEnvelope && conflictRow.markersAbsent &&
      conflictRow.envelopeSha256 === branchBUpload.envelopeSha256,
    'stored conflict envelope was malformed, plaintext, or changed in transit');
    stage = 'verify explicit Workspace conflict resolution';
    assertThat(
      conflictRow.resolvedRevisionId === resolutionResponse.resolvedRevisionId &&
      String(conflictRow.resolutionSeq) === String(resolutionResponse.resolutionSeq) &&
      conflictRow.resolutionSeq === resolvedSequence &&
      conflictRow.resolutionAt && conflictSnapshot.original.headRevisionId ===
        resolutionResponse.resolvedRevisionId && !conflictSnapshot.original.headDeleted,
    'server conflict resolution or resolved Workspace head did not match the explicit request');
    stage = 'verify encrypted named Workspace copy head and event';
    assertThat(
      conflictSnapshot.copy.versions.length === 1 &&
      conflictSnapshot.copy.versions[0].operation === 'create' &&
      conflictSnapshot.copy.headRevisionId === copyOperation.revisionId &&
      conflictSnapshot.copy.events.length === 1,
    'encrypted named copy did not match its single committed create head/event');
    stage = 'verify resolved Workspace event history';
    assertThat(conflictSnapshot.original.events.length === 3 &&
      conflictSnapshot.original.events[0].operation === 'create' &&
      conflictSnapshot.original.events[1].operation === 'update' &&
      conflictSnapshot.original.events[1].revisionId === branchAOperation.revisionId &&
      conflictSnapshot.original.events[2].operation === 'update' &&
      conflictSnapshot.original.events[2].revisionId === resolutionOperation.revisionId,
    'original Workspace create, winning branch, and resolution event history was incomplete');
    stage = 'verify both profiles observed created and resolved conflict feed sequences';
    assertThat(eachProfileSawExpectedConflictEvents,
      'one profile did not observe the exact conflict creation and resolution events');
    assertThat(relayAttempts.A.length === relayBeforeWorkspaceConflict.A &&
      relayAttempts.B.length === relayBeforeWorkspaceConflict.B &&
      relayWebSockets.A === relayBeforeWorkspaceConflict.socketsA &&
      relayWebSockets.B === relayBeforeWorkspaceConflict.socketsB,
    'Workspace conflict copy or resolution opened an SSH/Relay connection');
    captureWorkspaceConflict = false;

    stage = 'create and synchronize isolated split-pane Host';
    await click(pageA, 'Hosts');
    stage = 'capture pre-Pane-2 Host target-update Vault sequence';
    const beforeHostATargetUpdate = serverVaultSnapshot(databasePath).vaults[0];
    assertThat(beforeHostATargetUpdate,
      'Pane 2 Host target update did not find the active Vault before edit');
    await editHostTarget(pageA, HOST_A_NAME, splitTargetAddress, splitSecondTargetPort);
    await syncNow(pageA, 'isolated Pane 2 Host target sync');
    stage = 'capture post-Pane-2 Host target-update Vault sequence';
    const afterHostATargetUpdate = serverVaultSnapshot(databasePath).vaults[0];
    assertThat(afterHostATargetUpdate && afterHostATargetUpdate.vaultId === vaultId,
      'Pane 2 Host target update did not retain the active Vault');
    stage = 'inspect exact Pane 2 Host target-update change events';
    const hostATargetUpdate = serverCommitDelta(
      databasePath,
      vaultId,
      beforeHostATargetUpdate.commitSeq,
      afterHostATargetUpdate.commitSeq,
    );
    const hostARecordIdMatchesTargetUpdate = hostATargetUpdate.events.length === 1 &&
      hostATargetUpdate.events[0].recordId === hostARecordId;
    console.log('WEB-WORKSPACE-HOST-A-TARGET-UPDATE-CHECKPOINT', JSON.stringify({
      beforeCommitSeq: beforeHostATargetUpdate.commitSeq,
      afterCommitSeq: afterHostATargetUpdate.commitSeq,
      commitDelta: Number(BigInt(afterHostATargetUpdate.commitSeq) -
        BigInt(beforeHostATargetUpdate.commitSeq)),
      eventCount: hostATargetUpdate.eventCount,
      distinctCommitCount: hostATargetUpdate.distinctCommitCount,
      operationKinds: hostATargetUpdate.events.map((event) => event.operation),
      recordIdMatchesHostA: hostARecordIdMatchesTargetUpdate,
    }));
    stage = 'validate exact Pane 2 Host target update preserved Host A record ID';
    assertThat(hostATargetUpdate.eventCount === 1 &&
      hostATargetUpdate.events[0].operation === 'update' &&
      hostARecordIdMatchesTargetUpdate,
    'Pane 2 target update did not preserve Host A record identity');

    const beforeSplitHostCreate = serverVaultSnapshot(databasePath).vaults[0];
    await addHost(pageA, HOST_SPLIT_NAME, splitTargetAddress, {
      port: splitTargetPort,
    });
    await syncNow(pageA, 'isolated split-pane Host sync');
    const afterSplitHostCreate = serverVaultSnapshot(databasePath).vaults[0];
    const splitHostCreate = serverCommitDelta(
      databasePath,
      vaultId,
      beforeSplitHostCreate.commitSeq,
      afterSplitHostCreate.commitSeq,
    );
    assertThat(splitHostCreate.eventCount === 1 &&
      splitHostCreate.events[0].operation === 'create' &&
      splitHostCreate.distinctCommitCount === 1,
    'Pane 1 did not create exactly one encrypted Host record');
    splitHostRecordId = splitHostCreate.events[0].recordId;
    assertThat(typeof splitHostRecordId === 'string' && splitHostRecordId.length > 0 &&
      splitHostRecordId !== hostARecordId,
    'split Workspace panes do not reference two distinct synced Host record IDs');
    await click(pageA, 'Workspaces');
    const splitUiAfterNavigation = await workspaceSplitCreatorSnapshot(pageA);
    console.log(`WEB-WORKSPACE-SPLIT-UI-AFTER-NAV ${JSON.stringify(splitUiAfterNavigation)}`);
    await syncNow(pageB, 'Profile B isolated split Host pull', { forcePull: true });
    stage = 'record Profile A split Workspace creator after Host sync';
    const splitUiCheckpoint = await workspaceSplitCreatorSnapshot(pageA);
    console.log(`WEB-WORKSPACE-SPLIT-UI-CHECKPOINT ${JSON.stringify(splitUiCheckpoint)}`);

    stage = 'capture Profile A split Workspace encrypted create';
    const beforeSplitVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(beforeSplitVault, 'split Workspace fixture did not find the active Vault');
    const splitPullChangePageBaseline = splitPullChangePages.length;
    captureWorkspaceSplit = true;
    const splitCreationBaseline = await createSplitWorkspace(pageA, SPLIT_WORKSPACE_NAME, () => {
      const operations = workspaceSplitPushes.flatMap((push) => push.operations);
      const createOperations = operations.filter((operation) =>
        operation.operation === 'create' && operation.recordId && operation.opId);
      const responseRevisionLink = createOperations.some((operation) =>
        workspaceSplitPushResponses.some((response) => response.status === 200 &&
          response.results.some((result) => result.opId === operation.opId &&
            result.revisionId === operation.revisionId)));
      const firstCommitResponseLink = createOperations.some((operation) =>
        workspaceSplitPushResponses.some((response) => response.status === 200 &&
          response.results.some((result) => result.opId === operation.opId &&
            result.revisionId === operation.revisionId && result.commitSeq &&
            !result.alreadyCommitted)));
      let serverRecordPresent = false;
      let serverRecordVersionCount = 0;
      let serverHeadPresent = false;
      let serverRecordSnapshotReadable = false;
      let serverVersionMatchesCreateLink = false;
      let serverReceiptMatchesCreateLink = false;
      const capturedRecordId = createOperations.length === 1
        ? createOperations[0].recordId : null;
      if (capturedRecordId) {
        try {
          const snapshot = serverWorkspaceRecordSnapshot(
            databasePath, vaultId, capturedRecordId, [],
          );
          serverRecordVersionCount = snapshot.versions.length;
          serverRecordPresent = serverRecordVersionCount > 0;
          serverHeadPresent = Boolean(snapshot.headRevisionId);
          serverRecordSnapshotReadable = true;
          const operation = createOperations[0];
          const version = snapshot.versions.find((item) =>
            item.recordId === operation.recordId &&
            item.revisionId === operation.revisionId &&
            item.opId === operation.opId && item.operation === 'create');
          serverVersionMatchesCreateLink = Boolean(version);
          serverReceiptMatchesCreateLink = Boolean(version &&
            snapshot.receipts.some((receipt) => receipt.opId === operation.opId &&
              receipt.recordId === operation.recordId &&
              receipt.revisionId === operation.revisionId &&
              receipt.commitSeq === version.commitSeq));
        } catch (_) {
          // Report only that the read-only check could not obtain a snapshot.
        }
      }
      return {
        splitCreateRequestCaptureCount: workspaceSplitPushes.length,
        splitCreateOperationCaptureCount: operations.length,
        splitCreateOperationCount: createOperations.length,
        splitReceiptCaptureCount: workspaceSplitPushResponses.length,
        splitReceiptHttp200Count: workspaceSplitPushResponses.filter(
          (response) => response.status === 200,
        ).length,
        splitReceiptResultCount: workspaceSplitPushResponses.reduce(
          (count, response) => count + response.results.length, 0,
        ),
        splitCreateReceiptOpRevisionLink: responseRevisionLink,
        splitCreateFirstCommitReceiptLink: firstCommitResponseLink,
        splitServerRecordSnapshotReadable: serverRecordSnapshotReadable,
        splitServerRecordPresent: serverRecordPresent,
        splitServerRecordVersionCount: serverRecordVersionCount,
        splitServerHeadPresent: serverHeadPresent,
        splitServerVersionMatchesCreateLink: serverVersionMatchesCreateLink,
        splitServerReceiptMatchesCreateLink: serverReceiptMatchesCreateLink,
      };
    }, pageB);
    stage = 'wait for split Workspace outbox to enter sync';
    await waitForSplitSyncReady(pageA, () => workspaceSplitPushes.some((push) =>
      push.operations.length > 0));
    const splitCaptureSummary = () => {
      const operations = workspaceSplitPushes.flatMap((push) => push.operations || []);
      const createOperations = operations.filter((operation) =>
        operation.operation === 'create');
      return {
        pushRequestCount: workspaceSplitPushes.length,
        pushResponseCount: workspaceSplitPushResponses.length,
        capturedOperationCount: operations.length,
        createOperationCount: createOperations.length,
        completeCreateOperationCount: createOperations.filter((operation) =>
          Boolean(operation.recordId && operation.revisionId && operation.opId)).length,
        validEnvelopeShapeCount: createOperations.filter((operation) =>
          operation.envelopeShapeValid).length,
        serverCommitDelta: (() => {
          try {
            const latestVault = serverVaultSnapshot(databasePath).vaults
              .find((item) => item.vaultId === vaultId);
            return latestVault
              ? String(BigInt(latestVault.commitSeq) - BigInt(beforeSplitVault.commitSeq))
              : null;
          } catch (_) {
            return null;
          }
        })(),
      };
    };
    let splitOperation;
    try {
      stage = 'Profile A explicit split Workspace sync pass';
      await syncNow(pageA, 'split Workspace encrypted save');
      stage = 'Profile A split Workspace sync pass returned';
      await pageA.waitForTimeout(250);
      console.log(`WEB-WORKSPACE-SPLIT-SYNC-CAPTURE ${JSON.stringify(splitCaptureSummary())}`);
      stage = 'capture Profile A split Workspace create envelope';
      splitOperation = await waitForCaptured(() =>
        workspaceSplitPushes.flatMap((push) => push.operations).find((operation) =>
          operation.operation === 'create' && operation.recordId && operation.revisionId &&
          operation.opId), 'Profile A split Workspace create envelope');
    } catch (error) {
      const phase = stage;
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      stage = `split sync/capture diagnostic entered (${errorClass})`;
      console.error(`WEB-WORKSPACE-SPLIT-SYNC-DIAGNOSTIC-ENTER ${JSON.stringify({ phase, errorClass })}`);
      let diagnostic = { phase, errorClass, summaryAvailable: false };
      try { diagnostic = { phase, errorClass, summaryAvailable: true, ...splitCaptureSummary() }; }
      catch (_) {}
      console.error(`WEB-WORKSPACE-SPLIT-SYNC-FAILURE ${JSON.stringify(diagnostic)}`);
      stage = `Profile A split Workspace sync/capture failed (${diagnostic.phase}; ${diagnostic.errorClass})`;
      throw error;
    }
    splitWorkspaceRecordId = splitOperation.recordId;
    stage = 'validate captured split Workspace encrypted create';
    const splitPush = workspaceSplitPushes.find((push) =>
      push.operations.includes(splitOperation));
    const splitCreateValidation = {
      onePushRequest: workspaceSplitPushes.length === 1,
      matchingPushFound: Boolean(splitPush),
      oneOperationInPush: splitPush?.operations.length === 1,
      plaintextMarkersAbsent: splitPush?.requestBodyPlaintextMarkersAbsent === true,
      encryptedEnvelopeShapeValid: splitOperation.envelopeShapeValid === true,
    };
    if (!Object.values(splitCreateValidation).every(Boolean)) {
      console.error(`WEB-WORKSPACE-SPLIT-CREATE-VALIDATION ${JSON.stringify(splitCreateValidation)}`);
    }
    assertThat(Object.values(splitCreateValidation).every(Boolean),
      'split Workspace save was not one plaintext-free encrypted create operation');
    stage = 'wait for Profile A split Workspace first-commit receipt';
    const splitReceiptResponse = await waitForCaptured(() =>
      workspaceSplitPushResponses.find((response) => response.status === 200 &&
        response.results.length === 1 &&
        response.results[0].opId === splitOperation.opId &&
        response.results[0].revisionId === splitOperation.revisionId &&
        response.results[0].commitSeq && !response.results[0].alreadyCommitted),
    'Profile A split Workspace first-commit receipt');
    stage = 'verify Profile A split Workspace one-commit delta';
    const afterSplitVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(afterSplitVault &&
      BigInt(afterSplitVault.commitSeq) === BigInt(beforeSplitVault.commitSeq) + 1n,
    'one split Workspace save did not create exactly one Vault commit');
    const splitCommitDelta = serverCommitDelta(
      databasePath,
      vaultId,
      beforeSplitVault.commitSeq,
      afterSplitVault.commitSeq,
    );
    const splitRecordState = serverWorkspaceRecordSnapshot(
      databasePath,
      vaultId,
      splitOperation.recordId,
      splitEnvelopeMarkers,
    );
    const splitVersion = splitRecordState.versions[0];
    const splitEvent = splitRecordState.events[0];
    const splitDbReceipt = splitRecordState.receipts[0];
    assertThat(splitCommitDelta.eventCount === 1 &&
      splitCommitDelta.distinctCommitCount === 1 &&
      splitCommitDelta.events[0].operation === 'create' &&
      splitCommitDelta.events[0].recordId === splitOperation.recordId &&
      splitCommitDelta.events[0].revisionId === splitOperation.revisionId &&
      splitVersion && splitRecordState.versions.length === 1 &&
      splitVersion.operation === 'create' && splitVersion.recordId === splitOperation.recordId &&
      splitVersion.headerOperation === 'create' &&
      splitVersion.headerRevisionId === splitOperation.revisionId &&
      splitVersion.opId === splitOperation.opId &&
      splitVersion.commitSeq === splitReceiptResponse.results[0].commitSeq &&
      splitVersion.envelopeSha256 === splitOperation.envelopeSha256 &&
      splitVersion.validEnvelope && splitVersion.markersAbsent &&
      splitEvent && splitRecordState.events.length === 1 &&
      splitEvent.operation === 'create' && splitEvent.revisionId === splitOperation.revisionId &&
      splitEvent.commitSeq === splitVersion.commitSeq &&
      splitRecordState.headRevisionId === splitOperation.revisionId &&
      !splitRecordState.headDeleted && splitRecordState.headCommitSeq === splitVersion.commitSeq &&
      splitDbReceipt && splitRecordState.receipts.length === 1 &&
      splitDbReceipt.recordId === splitOperation.recordId &&
      splitDbReceipt.revisionId === splitOperation.revisionId &&
      splitDbReceipt.commitSeq === splitVersion.commitSeq,
    'split Workspace encrypted envelope, version, event, head, receipt, and commit links diverged');

    stage = 'Profile B force-pulls and decrypts split Workspace';
    await click(pageB, 'Workspaces');
    const totalPreviewCardCountBBeforeSplitSync =
      await totalWorkspacePreviewCardCount(pageB);
    const splitPullChangesBefore = splitPullChangePages.length;
    await syncNow(pageB, 'Profile B split Workspace force pull', { forcePull: true });
    const explicitProfileBSplitChangePages = await waitForCaptured(() =>
      splitPullChangePages.length > splitPullChangesBefore
        ? splitPullChangePages.slice(splitPullChangesBefore)
        : null,
    'Profile B split Workspace changes response diagnostics', 10000);
    const safeChangePageSummary = (page) => ({
      httpStatus: page.httpStatus,
      eventCount: page.eventCount,
      createEventCount: page.createEventCount,
      updateEventCount: page.updateEventCount,
      splitWorkspaceRecordPresent: page.seenRecordIds?.includes(splitWorkspaceRecordId) === true,
      splitWorkspaceOperationKinds: page.seenRecordIds?.map((recordId, index) =>
        recordId === splitWorkspaceRecordId ? page.seenOperationKinds[index] : null)
        .filter(Boolean) || [],
      paneOneHostRecordPresent: page.seenRecordIds?.includes(splitHostRecordId) === true,
      paneTwoHostRecordPresent: page.seenRecordIds?.includes(hostARecordId) === true,
    });
    const profileBSplitChangeSummary = {
      sinceSplitWorkspaceCreate: splitPullChangePages
        .slice(splitPullChangePageBaseline).map(safeChangePageSummary),
      duringExplicitPull: explicitProfileBSplitChangePages.map(safeChangePageSummary),
    };
    const profileBSplitPullCheckpoint = await workspaceSplitCreatorSnapshot(pageB);
    const profileBSplitPullUi = await waitForSplitWorkspaceCardRendered(pageB, {
      address: splitTargetAddress,
      firstPort: splitTargetPort,
      secondPort: splitSecondTargetPort,
    });
    const profileBScreenshotSaved = await pageB.screenshot({
      path: '/tmp/atermius-workspace-layout-profile-b.png',
      fullPage: true,
    }).then(() => true).catch(() => false);
    console.log(`WEB-WORKSPACE-SPLIT-PULL-CHECKPOINT ${JSON.stringify({
      previewCardCountBeforeSplitCreate:
        splitCreationBaseline?.totalPreviewCardCountBBeforeSave ?? null,
      totalPreviewCardCountBeforePull: totalPreviewCardCountBBeforeSplitSync,
      changePages: profileBSplitChangeSummary,
      uiAfterPull: profileBSplitPullUi,
      splitWorkspaceUi: profileBSplitPullCheckpoint,
      profileBScreenshotSaved,
    })}`);
    stage = 'verify Profile B split Workspace title semantics and contents after scroll';
    assertThat(profileBSplitPullUi?.splitCardFullyRendered === true,
      'Profile B did not render the split Workspace title and full card after pull and scroll');
    const assertSplitWorkspaceCard = async () => {
      await waitForVisibleSemanticText(pageB, 'Split · 63/37', 'split ratio label', 10000);
      await waitForVisibleSemanticText(pageB, 'Stacked', 'split axis label', 10000);
      const firstPane = await visibleSemanticTextMatch(pageB,
        `Pane 1 · ${HOST_SPLIT_NAME} ·`);
      const secondPane = await visibleSemanticTextMatch(pageB,
        `Pane 2 · ${HOST_A_NAME} ·`);
      return firstPane && secondPane;
    };
    const profileBDecryptsSplitCard = await assertSplitWorkspaceCard();
    assertThat(profileBDecryptsSplitCard,
      'Profile B did not render the split direction, bounded ratio, and ordered Host panes');

    stage = 'reload Profile B and force-pull the persisted split Workspace';
    await restoreWorkspaceAfterReload(pageB, 'B', baseUrl);
    await click(pageB, 'Workspaces');
    await syncNow(pageB, 'Profile B post-reload split Workspace pull', { forcePull: true });
    const profileBDecryptsSplitAfterReload = await assertSplitWorkspaceCard();
    assertThat(profileBDecryptsSplitAfterReload,
      'Profile B did not decrypt the split Workspace after a Web reload and force pull');

    const noRelayBeforeConnect = {
      ticketsA: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      socketsA: relayWebSockets.A,
      socketsB: relayWebSockets.B,
      activeSocketsA: activeRelayWebSockets.A.size,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      firstSinkConnections: splitSink.acceptedCount,
      firstSinkActive: splitSink.activeCount,
      secondSinkConnections: splitSecondSink.acceptedCount,
      secondSinkActive: splitSecondSink.activeCount,
    };
    stage = 'Profile B stage split preview without connecting either pane';
    const splitConnectButtons = await stageSplitWorkspacePreview(pageB, SPLIT_WORKSPACE_NAME);
    await pageB.waitForTimeout(250);
    assertThat(relayAttempts.A.length === noRelayBeforeConnect.ticketsA &&
      relayAttempts.B.length === noRelayBeforeConnect.ticketsB &&
      relayWebSockets.A === noRelayBeforeConnect.socketsA &&
      relayWebSockets.B === noRelayBeforeConnect.socketsB &&
      activeRelayWebSockets.A.size === noRelayBeforeConnect.activeSocketsA &&
      activeRelayWebSockets.B.size === noRelayBeforeConnect.activeSocketsB &&
      splitSink.acceptedCount === noRelayBeforeConnect.firstSinkConnections &&
      splitSink.activeCount === noRelayBeforeConnect.firstSinkActive &&
      splitSecondSink.acceptedCount === noRelayBeforeConnect.secondSinkConnections &&
      splitSecondSink.activeCount === noRelayBeforeConnect.secondSinkActive,
    'split creation, synchronization, reload, or staging reached the Relay sink');

    stage = 'Profile B prepare exact two-pane Relay baseline';
    const splitTicketBaseline = {
      ticketsA: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      socketsA: relayWebSockets.A,
      socketsB: relayWebSockets.B,
      activeSocketsA: activeRelayWebSockets.A.size,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      firstSinkConnections: splitSink.acceptedCount,
      firstSinkActive: splitSink.activeCount,
      secondSinkConnections: splitSecondSink.acceptedCount,
      secondSinkActive: splitSecondSink.activeCount,
    };
    stage = 'Profile B click first split pane Connect';
    await splitConnectButtons.nth(0).click();
    stage = 'Profile B wait for exact Pane 1 Relay ticket';
    const firstSplitTicket = await waitForCaptured(() => {
      const issued = relayAttempts.B.slice(splitTicketBaseline.ticketsB);
      return issued.length === 1 && issued[0].status !== null ? issued[0] : null;
    }, 'Profile B explicit Pane 1 Relay ticket', 20000);
    stage = 'Profile B wait for Pane 1 Relay WebSocket and exact synthetic sink';
    await waitForCaptured(() =>
      activeRelayWebSockets.B.size === splitTicketBaseline.activeSocketsB + 1 &&
      splitSink.activeCount === splitTicketBaseline.firstSinkActive + 1,
    'Pane 1 active Relay WebSocket and synthetic SSH sink', 15000);
    assertThat(firstSplitTicket.status === 200 &&
      firstSplitTicket.targetMatchesFirstSplitHost &&
      splitSink.acceptedCount === splitTicketBaseline.firstSinkConnections + 1 &&
      splitSecondSink.acceptedCount === splitTicketBaseline.secondSinkConnections,
    'Pane 1 Relay ticket did not bind to its exact synthetic Host address and port');

    stage = 'Profile B click distinct second split pane Connect';
    await splitConnectButtons.nth(1).click();
    stage = 'Profile B wait for exact Pane 2 Relay ticket';
    const secondSplitTicket = await waitForCaptured(() => {
      const issued = relayAttempts.B.slice(splitTicketBaseline.ticketsB);
      return issued.length === 2 && issued[1].status !== null ? issued[1] : null;
    }, 'Profile B explicit Pane 2 Relay ticket', 20000);
    stage = 'Profile B wait for both distinct Relay WebSockets and SSH sinks';
    await waitForCaptured(() =>
      relayWebSockets.B - splitTicketBaseline.socketsB === 2 &&
      activeRelayWebSockets.B.size === splitTicketBaseline.activeSocketsB + 2 &&
      splitSink.activeCount === splitTicketBaseline.firstSinkActive + 1 &&
      splitSecondSink.activeCount === splitTicketBaseline.secondSinkActive + 1,
    'two active Relay WebSockets and both exact synthetic SSH sinks', 15000);
    stage = 'verify independent split terminal runtime records';
    const splitRuntimeSnapshot = await waitForWorkspaceTerminalRuntimes(pageB,
      [HOST_SPLIT_NAME, HOST_A_NAME]);
    const splitRuntimesPresent = splitRuntimeSnapshot.every((item) =>
      item.count === 1 && item.failedCount === 0 &&
      item.connectingCount + item.connectedCount === 1);
    const splitTickets = relayAttempts.B.slice(splitTicketBaseline.ticketsB);
    const exactTwoPaneRelayEvidence = relayAttempts.A.length === splitTicketBaseline.ticketsA &&
      splitTickets.length === 2 && firstSplitTicket.status === 200 &&
      secondSplitTicket.status === 200 &&
      firstSplitTicket.targetMatchesFirstSplitHost &&
      secondSplitTicket.targetMatchesSecondSplitHost &&
      splitSink.acceptedCount === splitTicketBaseline.firstSinkConnections + 1 &&
      splitSecondSink.acceptedCount === splitTicketBaseline.secondSinkConnections + 1;
    assertThat(exactTwoPaneRelayEvidence && splitRuntimesPresent,
    'two distinct Workspace panes did not create one runtime, exact ticket, WebSocket, and sink connection each');
    console.log('WEB-WORKSPACE-DUAL-LIVE-CHECKPOINT', JSON.stringify({
      relayTicketDelta: splitTickets.length,
      paneOneTicketStatus: firstSplitTicket.status,
      paneTwoTicketStatus: secondSplitTicket.status,
      paneOneTargetMatch: firstSplitTicket.targetMatchesFirstSplitHost,
      paneTwoTargetMatch: secondSplitTicket.targetMatchesSecondSplitHost,
      relayWebSocketOpenDelta: relayWebSockets.B - splitTicketBaseline.socketsB,
      activeRelayWebSocketDelta: activeRelayWebSockets.B.size -
        splitTicketBaseline.activeSocketsB,
      paneOneSinkAcceptedDelta: splitSink.acceptedCount -
        splitTicketBaseline.firstSinkConnections,
      paneOneSinkActiveDelta: splitSink.activeCount - splitTicketBaseline.firstSinkActive,
      paneTwoSinkAcceptedDelta: splitSecondSink.acceptedCount -
        splitTicketBaseline.secondSinkConnections,
      paneTwoSinkActiveDelta: splitSecondSink.activeCount - splitTicketBaseline.secondSinkActive,
      terminalRuntimeStates: splitRuntimeSnapshot.map((item) =>
        item.connectedCount === 1 ? 'connected' : 'connecting'),
    }));

    stage = 'Profile B explicitly disconnect Pane 1 terminal runtime';
    const paneOneTab = pageB.getByRole('button', {
      name: new RegExp(`^${escapeRegExp(HOST_SPLIT_NAME)} terminal tab,`),
    });
    assertThat(await paneOneTab.count() === 1,
      'Pane 1 terminal tab was not uniquely selectable for disconnect');
    await paneOneTab.click();
    await click(pageB, 'Disconnect');
    stage = 'Profile B wait for Pane 1 Relay and sink closure while Pane 2 stays live';
    let paneOneDisconnectClosedOnlyItsTransport = false;
    try {
      await waitForCaptured(() =>
        activeRelayWebSockets.B.size === splitTicketBaseline.activeSocketsB + 1 &&
        relayWebSocketCloses.B === splitTicketBaseline.closedSocketsB + 1 &&
        splitSink.activeCount === splitTicketBaseline.firstSinkActive &&
        splitSecondSink.activeCount === splitTicketBaseline.secondSinkActive + 1,
      'one split-pane disconnect closes only its Relay WebSocket and SSH sink', 15000);
      paneOneDisconnectClosedOnlyItsTransport = true;
    } catch (_) {
      const runtimeSnapshot = await workspaceTerminalRuntimeSnapshot(pageB,
        [HOST_SPLIT_NAME, HOST_A_NAME]);
      console.log('WEB-WORKSPACE-DUAL-DISCONNECT-DIAGNOSTIC', JSON.stringify({
        paneOneDisconnectClosedOnlyItsTransport: false,
        relayTicketDelta: relayAttempts.B.length - splitTicketBaseline.ticketsB,
        relayWebSocketOpenDelta: relayWebSockets.B - splitTicketBaseline.socketsB,
        relayWebSocketCloseDelta: relayWebSocketCloses.B -
          splitTicketBaseline.closedSocketsB,
        activeRelayWebSocketDelta: activeRelayWebSockets.B.size -
          splitTicketBaseline.activeSocketsB,
        paneOneSinkAcceptedDelta: splitSink.acceptedCount -
          splitTicketBaseline.firstSinkConnections,
        paneOneSinkActiveDelta: splitSink.activeCount - splitTicketBaseline.firstSinkActive,
        paneTwoSinkAcceptedDelta: splitSecondSink.acceptedCount -
          splitTicketBaseline.secondSinkConnections,
        paneTwoSinkActiveDelta: splitSecondSink.activeCount - splitTicketBaseline.secondSinkActive,
        paneOneRuntimeCount: runtimeSnapshot[0].count,
        paneOneRuntimeConnectingCount: runtimeSnapshot[0].connectingCount,
        paneOneRuntimeConnectedCount: runtimeSnapshot[0].connectedCount,
        paneOneRuntimeFailedCount: runtimeSnapshot[0].failedCount,
        paneTwoRuntimeCount: runtimeSnapshot[1].count,
        paneTwoRuntimeConnectingCount: runtimeSnapshot[1].connectingCount,
        paneTwoRuntimeConnectedCount: runtimeSnapshot[1].connectedCount,
        paneTwoRuntimeFailedCount: runtimeSnapshot[1].failedCount,
      }));
      throw new Error('Pane 1 Disconnect did not close only its Relay and synthetic sink transport');
    }
    await pageB.waitForTimeout(500);
    const splitRuntimeSnapshotAfterDisconnect =
      await workspaceTerminalRuntimeSnapshot(pageB, [HOST_SPLIT_NAME, HOST_A_NAME]);
    const paneIsolatedDisconnect = splitRuntimeSnapshotAfterDisconnect[0].count === 0 &&
      splitRuntimeSnapshotAfterDisconnect[1].count === 1 &&
      splitRuntimeSnapshotAfterDisconnect[1].failedCount === 0 &&
      splitRuntimeSnapshotAfterDisconnect[1].connectingCount +
        splitRuntimeSnapshotAfterDisconnect[1].connectedCount === 1 &&
      activeRelayWebSockets.B.size === splitTicketBaseline.activeSocketsB + 1 &&
      splitSecondSink.activeCount === splitTicketBaseline.secondSinkActive + 1 &&
      relayAttempts.B.length === splitTicketBaseline.ticketsB + 2 &&
      relayWebSockets.B === splitTicketBaseline.socketsB + 2;
    assertThat(paneIsolatedDisconnect,
      'disconnecting Pane 1 also removed, failed, or replaced Pane 2 runtime/transport');
    console.log('WEB-WORKSPACE-DUAL-DISCONNECT-CHECKPOINT', JSON.stringify({
      paneOneDisconnectClosedOnlyItsTransport,
      relayWebSocketCloseDelta: relayWebSocketCloses.B -
        splitTicketBaseline.closedSocketsB,
      activeRelayWebSocketDelta: activeRelayWebSockets.B.size -
        splitTicketBaseline.activeSocketsB,
      paneOneSinkActiveDelta: splitSink.activeCount - splitTicketBaseline.firstSinkActive,
      paneTwoSinkActiveDelta: splitSecondSink.activeCount - splitTicketBaseline.secondSinkActive,
      paneOneRuntimeCount: splitRuntimeSnapshotAfterDisconnect[0].count,
      paneTwoRuntimeCount: splitRuntimeSnapshotAfterDisconnect[1].count,
    }));

    const splitRelayTicketDelta = relayAttempts.B.length - splitTicketBaseline.ticketsB;
    const splitRelayWebSocketDelta = relayWebSockets.B - splitTicketBaseline.socketsB;
    const splitRelayWebSocketCloseDelta = relayWebSocketCloses.B -
      splitTicketBaseline.closedSocketsB;
    const splitRelaySinkDelta =
      splitSink.acceptedCount - splitTicketBaseline.firstSinkConnections +
      splitSecondSink.acceptedCount - splitTicketBaseline.secondSinkConnections;
    const splitWorkspaceRelayEvidence = {
      noRelayBeforeConnect: true,
      explicitPaneConnectTicketCount: splitRelayTicketDelta,
      paneOneTicketHttpStatus: firstSplitTicket.status,
      paneTwoTicketHttpStatus: secondSplitTicket.status,
      paneOneTicketTargetMatchesExactHostAndPort:
        firstSplitTicket.targetMatchesFirstSplitHost,
      paneTwoTicketTargetMatchesExactHostAndPort:
        secondSplitTicket.targetMatchesSecondSplitHost,
      relayWebSocketCount: splitRelayWebSocketDelta,
      relayWebSocketCloseCountAfterPaneOneDisconnect: splitRelayWebSocketCloseDelta,
      localSinkConnectionCount: splitRelaySinkDelta,
      activeRelayWebSocketCountAfterPaneOneDisconnect:
        activeRelayWebSockets.B.size - splitTicketBaseline.activeSocketsB,
      activePaneOneSinkCountAfterDisconnect: splitSink.activeCount -
        splitTicketBaseline.firstSinkActive,
      activePaneTwoSinkCountAfterPaneOneDisconnect: splitSecondSink.activeCount -
        splitTicketBaseline.secondSinkActive,
      distinctTerminalTabRuntimes: splitRuntimesPresent,
      terminalRuntimeStatesAfterBothConnects: splitRuntimeSnapshot.map((item) =>
        item.connectedCount === 1 ? 'connected' : 'connecting'),
      paneTwoRuntimeStateAfterPaneOneDisconnect:
        splitRuntimeSnapshotAfterDisconnect[1].connectedCount === 1
          ? 'connected' : 'connecting',
      syntheticSinkCompletedSshHandshake: false,
      realSshUserAuthenticationClaimed: false,
      decryptedAfterReload: profileBDecryptsSplitAfterReload,
      oneEncryptedCommit: splitCommitDelta.eventCount === 1,
    };
    captureWorkspaceSplit = false;

    stage = 'Profile B disconnect the remaining two-pane Relay runtime';
    const remainingTwoPaneTab = pageB.getByRole('button', {
      name: new RegExp(`^${escapeRegExp(HOST_A_NAME)} terminal tab,`),
    });
    assertThat(await remainingTwoPaneTab.count() === 1,
      'the remaining two-pane terminal tab was not uniquely selectable');
    await remainingTwoPaneTab.click();
    await click(pageB, 'Disconnect');
    await waitForCaptured(() =>
      activeRelayWebSockets.B.size === splitTicketBaseline.activeSocketsB &&
      relayWebSocketCloses.B === splitTicketBaseline.closedSocketsB + 2 &&
      splitSink.activeCount === splitTicketBaseline.firstSinkActive &&
      splitSecondSink.activeCount === splitTicketBaseline.secondSinkActive,
    'both two-pane Relay transports closed before the nested Workspace case', 15000);

    const nestedRelayBaseline = {
      ticketsA: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      socketsA: relayWebSockets.A,
      socketsB: relayWebSockets.B,
      activeSocketsA: activeRelayWebSockets.A.size,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsA: relayWebSocketCloses.A,
      closedSocketsB: relayWebSocketCloses.B,
      sinks: relaySinkSnapshot(),
      sshd: sshFixtureSnapshot(),
    };

    stage = 'Profile A retarget nested Workspace Hosts to three isolated OpenSSH targets';
    await click(pageA, 'Hosts');
    await editHostTarget(pageA, HOST_SPLIT_NAME, splitTargetAddress,
      nestedSshServers[0].port, {
        originalAddress: splitTargetAddress,
        originalPort: splitTargetPort,
      });
    await syncNow(pageA, 'nested Pane 1 Host target update to real SSHD');
    await editHostTarget(pageA, HOST_A_NAME, splitTargetAddress,
      nestedSshServers[1].port, {
        originalAddress: splitTargetAddress,
        originalPort: splitSecondTargetPort,
      });
    await syncNow(pageA, 'nested Pane 3 Host target update to real SSHD');
    const beforeHostCUpdate = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(beforeHostCUpdate, 'Host C update did not find the active Vault');
    await editHostTarget(pageA, HOST_C_NAME, splitTargetAddress, nestedSshServers[2].port, {
      originalAddress: HOST_C_ADDRESS,
      attachCredential: true,
    });
    await syncNow(pageA, 'nested Pane 2 Host credential and real SSHD target sync');
    splitRelayTargetPorts = {
      first: nestedSshServers[0].port,
      second: nestedSshServers[1].port,
      third: nestedSshServers[2].port,
    };
    const afterHostCUpdate = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(afterHostCUpdate, 'Host C update lost the active Vault');
    const hostCUpdateDelta = serverCommitDelta(
      databasePath, vaultId, beforeHostCUpdate.commitSeq, afterHostCUpdate.commitSeq,
    );
    const hostCServerState = serverWorkspaceRecordSnapshot(
      databasePath,
      vaultId,
      hostCRecordId,
      [...PRIVACY_MARKERS, CREDENTIAL_SECRET, SSH_USERNAME],
    );
    const latestHostCVersion = hostCServerState.versions.at(-1);
    const latestHostCEvent = hostCServerState.events.at(-1);
    const hostCCredentialUpdateReadback = hostCUpdateDelta.eventCount === 1 &&
      hostCUpdateDelta.distinctCommitCount === 1 &&
      hostCUpdateDelta.events[0].operation === 'update' &&
      hostCUpdateDelta.events[0].recordId === hostCRecordId &&
      hostCServerState.events.length === 2 &&
      latestHostCEvent?.operation === 'update' &&
      latestHostCEvent.commitSeq === afterHostCUpdate.commitSeq &&
      hostCServerState.versions.length === 2 &&
      latestHostCVersion?.operation === 'update' &&
      latestHostCVersion.validEnvelope && latestHostCVersion.markersAbsent &&
      hostCServerState.headCommitSeq === latestHostCVersion.commitSeq &&
      !hostCServerState.headDeleted;
    console.log('WEB-WORKSPACE-HOST-C-CREDENTIAL-UPDATE-CHECKPOINT', JSON.stringify({
      oneEncryptedUpdateCommit: hostCUpdateDelta.eventCount === 1 &&
        hostCUpdateDelta.distinctCommitCount === 1,
      sameOpaqueHostRecordUpdated: hostCUpdateDelta.events[0]?.recordId === hostCRecordId,
      resolvedCredentialReferenceVisibleInProfileAEditor: true,
      encryptedServerHeadReadbackValid: Boolean(latestHostCVersion?.validEnvelope),
      serverPlaintextMarkersAbsent: Boolean(latestHostCVersion?.markersAbsent),
      headMatchesUpdateEvent: hostCServerState.headCommitSeq ===
        latestHostCVersion?.commitSeq && latestHostCEvent?.commitSeq ===
        latestHostCVersion?.commitSeq,
    }));
    assertThat(hostCCredentialUpdateReadback,
      'Host C credential and target update did not persist as one encrypted Host update');
    await click(pageA, 'Workspaces');

    const beforeNestedVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(beforeNestedVault, 'nested Workspace save did not find the active Vault');
    const nestedPushBaseline = workspaceSplitPushes.length;
    const nestedPushResponseBaseline = workspaceSplitPushResponses.length;
    const nestedPullChangesBeforeSave = splitPullChangePages.length;
    workspaceHostReferenceMarkers = [
      hostARecordId,
      hostCRecordId,
      splitHostRecordId,
    ];
    assertThat(workspaceHostReferenceMarkers.every((recordId) =>
      typeof recordId === 'string' && recordId.length > 0) &&
      new Set(workspaceHostReferenceMarkers).size === 3,
    'nested Workspace Host reference privacy check did not capture three distinct synced Host IDs');
    captureWorkspaceSplit = true;
    stage = 'Profile A create the nested mixed-axis Workspace';
    await createNestedSplitWorkspace(pageA, NESTED_SPLIT_WORKSPACE_NAME);
    stage = 'Profile A synchronize the encrypted nested Workspace';
    await syncNow(pageA, 'nested split Workspace encrypted save');
    await pageA.waitForTimeout(250);

    const nestedOperation = await waitForCaptured(() =>
      workspaceSplitPushes.slice(nestedPushBaseline)
        .flatMap((push) => push.operations)
        .find((operation) => operation.operation === 'create' &&
          operation.recordId && operation.revisionId && operation.opId),
    'Profile A nested Workspace encrypted create envelope');
    const nestedPushes = workspaceSplitPushes.slice(nestedPushBaseline);
    const nestedMatchingPush = nestedPushes.find((push) =>
      push.operations.includes(nestedOperation));
    const nestedCreateIsOpaque = nestedPushes.length === 1 &&
      nestedMatchingPush?.operations.length === 1 &&
      nestedMatchingPush?.requestBodyPlaintextMarkersAbsent === true &&
      nestedMatchingPush?.encryptedWorkspaceHostReferenceMarkersAbsent === true &&
      nestedOperation.envelopeShapeValid === true;
    assertThat(nestedCreateIsOpaque,
      'nested Workspace save was not one plaintext-free encrypted create operation');

    const nestedReceiptResponse = await waitForCaptured(() =>
      workspaceSplitPushResponses.slice(nestedPushResponseBaseline).find((response) =>
        response.status === 200 && response.results.length === 1 &&
        response.results[0].opId === nestedOperation.opId &&
        response.results[0].revisionId === nestedOperation.revisionId &&
        response.results[0].commitSeq && !response.results[0].alreadyCommitted),
    'Profile A nested Workspace first-commit receipt');
    encryptedWorkspacePrivacyRecordId = nestedOperation.recordId;
    assertThat(nestedReceiptResponse.encryptedWorkspaceHostReferenceMarkersAbsent === true,
      'Workspace sync response exposed a referenced Host record ID');
    const afterNestedVault = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(afterNestedVault &&
      BigInt(afterNestedVault.commitSeq) === BigInt(beforeNestedVault.commitSeq) + 1n,
    'one nested Workspace save did not create exactly one Vault commit');
    const nestedCommitDelta = serverCommitDelta(
      databasePath,
      vaultId,
      beforeNestedVault.commitSeq,
      afterNestedVault.commitSeq,
    );
    const nestedRecordState = serverWorkspaceRecordSnapshot(
      databasePath,
      vaultId,
      nestedOperation.recordId,
      [...splitEnvelopeMarkers, ...workspaceHostReferenceMarkers],
    );
    const nestedVersion = nestedRecordState.versions[0];
    const nestedEvent = nestedRecordState.events[0];
    const nestedDbReceipt = nestedRecordState.receipts[0];
    assertThat(nestedCommitDelta.eventCount === 1 &&
      nestedCommitDelta.distinctCommitCount === 1 &&
      nestedRecordState.events.length === 1 &&
      nestedEvent?.operation === 'create' &&
      nestedEvent.revisionId === nestedOperation.revisionId &&
      nestedEvent.commitSeq === nestedVersion?.commitSeq &&
      nestedRecordState.versions.length === 1 &&
      nestedVersion?.operation === 'create' &&
      nestedVersion.headerRevisionId === nestedOperation.revisionId &&
      nestedVersion.opId === nestedOperation.opId &&
      nestedVersion.envelopeSha256 === nestedOperation.envelopeSha256 &&
      nestedVersion.validEnvelope && nestedVersion.markersAbsent &&
      nestedRecordState.headRevisionId === nestedOperation.revisionId &&
      !nestedRecordState.headDeleted &&
      nestedRecordState.headCommitSeq === nestedVersion.commitSeq &&
      nestedRecordState.receipts.length === 1 &&
      nestedDbReceipt?.recordId === nestedOperation.recordId &&
      nestedDbReceipt.revisionId === nestedOperation.revisionId &&
      nestedDbReceipt.commitSeq === nestedVersion.commitSeq &&
      nestedReceiptResponse.results[0].commitSeq === nestedVersion.commitSeq,
    'nested Workspace envelope, event, head, and commit receipt did not link exactly');
    const nestedWorkspaceRecordId = nestedOperation.recordId;

    stage = 'Profile B pull the nested Workspace and decrypt its recursive layout';
    await click(pageB, 'Workspaces');
    const nestedProfileBChangePages = [];
    let nestedCapturedChangePageCount = 0;
    const appendCapturedNestedChangePages = () => {
      const captured = splitPullChangePages.slice(nestedPullChangesBeforeSave);
      nestedProfileBChangePages.push(
        ...captured.slice(nestedCapturedChangePageCount),
      );
      nestedCapturedChangePageCount = captured.length;
    };
    const nestedCreateEventObserved = () => nestedProfileBChangePages.some((item) =>
      item.httpStatus === 200 && item.responsePlaintextMarkersAbsent === true &&
        item.seenRecordIds?.includes(nestedWorkspaceRecordId) &&
        item.workspaceEnvelopeHostReferenceChecks?.some((check) =>
          check.recordIdMatchesWorkspace && check.envelopePresent &&
          check.hostReferenceMarkersAbsent));
    let nestedWorkspaceChangeObserved = false;
    for (let attempt = 1; attempt <= 3 && !nestedWorkspaceChangeObserved; attempt += 1) {
      const syncLabel = attempt === 1
        ? 'Profile B nested Workspace force pull'
        : `Profile B nested Workspace force pull retry ${attempt}`;
      const directChangePage = await syncNow(pageB, syncLabel, { forcePull: true });
      if (directChangePage) nestedProfileBChangePages.push(directChangePage);
      stage = `observe Profile B nested create change page (attempt ${attempt})`;
      appendCapturedNestedChangePages();
      nestedWorkspaceChangeObserved = nestedCreateEventObserved();
      if (!nestedWorkspaceChangeObserved) {
        await waitForCaptured(() => {
          appendCapturedNestedChangePages();
          return nestedCreateEventObserved() ? true : null;
        }, 'Profile B nested Workspace create event', 3000).catch(() => null);
        nestedWorkspaceChangeObserved = nestedCreateEventObserved();
      }
    }
    stage = `verify Profile B observed nested create change (${nestedProfileBChangePages.length} pages; observed=${nestedWorkspaceChangeObserved})`;
    const nestedWorkspaceApiEnvelopeChecks = nestedProfileBChangePages
      .flatMap((page) => page.workspaceEnvelopeHostReferenceChecks || []);
    console.log('WEB-WORKSPACE-HOSTREF-PRIVACY-CHECKPOINT', JSON.stringify({
      hostReferenceMarkerCount: workspaceHostReferenceMarkers.length,
      workspaceChangeObserved: nestedWorkspaceChangeObserved,
      matchingWorkspaceEnvelopeCount: nestedWorkspaceApiEnvelopeChecks.length,
      matchingEnvelopesPresent: nestedWorkspaceApiEnvelopeChecks.filter((check) =>
        check.envelopePresent).length,
      matchingEnvelopesWithoutHostReferenceIds:
        nestedWorkspaceApiEnvelopeChecks.filter((check) =>
          check.envelopePresent && check.hostReferenceMarkersAbsent).length,
      storedWorkspaceEnvelopeWithoutHostReferenceIds: nestedVersion.markersAbsent,
    }));
    assertThat(nestedWorkspaceChangeObserved,
      'Profile B pull did not observe the encrypted nested Workspace envelope with Host refs private');
    const nestedWorkspaceApiHostReferencePrivacy = nestedWorkspaceApiEnvelopeChecks
      .some((check) => check.recordIdMatchesWorkspace && check.envelopePresent &&
        check.hostReferenceMarkersAbsent);
    assertThat(nestedWorkspaceApiHostReferencePrivacy,
      'nested Workspace API response exposed one or more Host record IDs in its envelope');

    const verifyNestedWorkspaceCard = async (label) => {
      stage = `${label} verify nested Workspace card semantics`;
      await waitForVisibleSemanticText(pageB, NESTED_SPLIT_WORKSPACE_NAME,
        `${label} nested Workspace name`, 15000);
      for (const text of [
        'Split 1 · Side by side · 63/37',
        'Split 2 · Stacked · 57/43',
        'Active Pane 2',
        `Pane 1 · ${HOST_SPLIT_NAME}`,
        `Pane 2 · ${HOST_C_NAME}`,
        `Pane 3 · ${HOST_A_NAME}`,
      ]) {
        await waitForVisibleSemanticText(pageB, text,
          `${label} nested Workspace card: ${text}`, 10000);
      }
      return true;
    };
    const profileBDecryptsNestedCard = await verifyNestedWorkspaceCard(
      'Profile B after force pull',
    );
    assertThat(profileBDecryptsNestedCard,
      'Profile B did not decrypt the mixed-axis tree, three Host refs, and active Pane 2');

    stage = 'reload Profile B and force-pull the nested Workspace';
    await restoreWorkspaceAfterReload(pageB, 'B', baseUrl);
    await click(pageB, 'Workspaces');
    await syncNow(pageB, 'Profile B post-reload nested Workspace pull', { forcePull: true });
    const profileBDecryptsNestedAfterReload = await verifyNestedWorkspaceCard(
      'Profile B after reload and force pull',
    );
    assertThat(profileBDecryptsNestedAfterReload,
      'Profile B did not restore the nested topology, active pane, and Host refs after reload');
    const verifyProfileBHostCredentialReference = async (hostName) => {
      const card = pageB.getByRole('group', {
        name: new RegExp(`^Host: ${escapeRegExp(hostName)}; `),
      }).first();
      await card.waitFor({ state: 'visible', timeout: 15000 });
      await card.getByRole('button', { name: 'Edit host', exact: true }).click();
      await waitForText(pageB, 'Edit host');
      const expectedReference =
        `Host override: ${CREDENTIAL_NAME} · ${SSH_USERNAME}`;
      const deadline = Date.now() + 10000;
      let resolved = false;
      let unavailable = false;
      while (!resolved && !unavailable && Date.now() < deadline) {
        resolved = await visibleSemanticTextMatch(pageB, expectedReference);
        unavailable = await visibleSemanticTextMatch(
          pageB, 'Host override is unavailable.',
        );
        if (!resolved && !unavailable) await pageB.waitForTimeout(100);
      }
      await click(pageB, 'Cancel');
      return { resolved, unavailable };
    };
    stage = 'Profile B verify synchronized Host A credential reference after reload';
    await click(pageB, 'Hosts');
    const profileBHostACredential =
      await verifyProfileBHostCredentialReference(HOST_A_NAME);
    console.log('WEB-WORKSPACE-HOST-A-CREDENTIAL-REPLICA-CHECKPOINT', JSON.stringify({
      profileBResolvedCredentialReference: profileBHostACredential.resolved,
      profileBReportsCredentialUnavailable: profileBHostACredential.unavailable,
    }));
    assertThat(profileBHostACredential.resolved &&
      !profileBHostACredential.unavailable,
    'Profile B did not resolve Host A credential reference after reload');
    stage = 'Profile B verify synchronized Host C credential reference after reload';
    const profileBHostCCredential =
      await verifyProfileBHostCredentialReference(HOST_C_NAME);
    console.log('WEB-WORKSPACE-HOST-C-CREDENTIAL-REPLICA-CHECKPOINT', JSON.stringify({
      profileBResolvedCredentialReference: profileBHostCCredential.resolved,
      profileBReportsCredentialUnavailable: profileBHostCCredential.unavailable,
      profileBNestedWorkspaceReloaded: profileBDecryptsNestedAfterReload,
    }));
    assertThat(profileBHostCCredential.resolved &&
      !profileBHostCCredential.unavailable,
    'Profile B did not pull and resolve Host C credential reference after reload');
    await click(pageB, 'Workspaces');
    captureWorkspaceSplit = false;

    stage = 'Profile B preview the nested Workspace without connecting leaves';
    await stageSplitWorkspacePreview(
      pageB,
      NESTED_SPLIT_WORKSPACE_NAME,
      {
        existingWorkspaceNames: [
          WORKSPACE_NAME,
          WORKSPACE_BRANCH_B_COPY_NAME,
          SPLIT_WORKSPACE_NAME,
        ],
        expectedHosts: [HOST_SPLIT_NAME, HOST_C_NAME, HOST_A_NAME],
      },
    );
    const nestedPaneHostMatches = await Promise.all([
      visibleSidebarConnectButtonForPane(pageB, 1, HOST_SPLIT_NAME),
      visibleSidebarConnectButtonForPane(pageB, 2, HOST_C_NAME),
      visibleSidebarConnectButtonForPane(pageB, 3, HOST_A_NAME),
    ]);
    const nestedPaneHostMapMatchesExpected = Object.fromEntries(
      nestedPaneHostMatches.map((match, index) => [`pane${index + 1}`,
        match.matchingCount === 1 &&
        match.diagnostics.paneLabelMatchCount === 1 &&
        match.diagnostics.paneHostPairCount === 1]),
    );
    console.log('WEB-WORKSPACE-NESTED-PANE-HOST-MAP-CHECKPOINT',
      JSON.stringify(nestedPaneHostMapMatchesExpected));
    assertThat(Object.values(nestedPaneHostMapMatchesExpected).every(Boolean),
      'nested pane ordinals did not map to the expected decrypted Host references');
    await pageB.waitForTimeout(250);
    const nestedSinksBeforeConnect = relaySinkSnapshot();
    const nestedSinkDeltasBeforeConnect = relaySinkDeltas(nestedRelayBaseline.sinks);
    const nestedSshBeforeConnect = sshFixtureSnapshot();
    const nestedSshTargetsStayedIdle = nestedSshBeforeConnect.every((summary, index) =>
      summary.tcpConnectionsAccepted === nestedRelayBaseline.sshd[index].tcpConnectionsAccepted &&
      summary.keyExchangeStarted === nestedRelayBaseline.sshd[index].keyExchangeStarted &&
      summary.passwordAccepted === nestedRelayBaseline.sshd[index].passwordAccepted &&
      summary.shellSessions === nestedRelayBaseline.sshd[index].shellSessions);
    const nestedNoRelayBeforeConnect =
      relayAttempts.A.length === nestedRelayBaseline.ticketsA &&
      relayAttempts.B.length === nestedRelayBaseline.ticketsB &&
      relayWebSockets.A === nestedRelayBaseline.socketsA &&
      relayWebSockets.B === nestedRelayBaseline.socketsB &&
      activeRelayWebSockets.A.size === nestedRelayBaseline.activeSocketsA &&
      activeRelayWebSockets.B.size === nestedRelayBaseline.activeSocketsB &&
      nestedSinksBeforeConnect.length === nestedRelayBaseline.sinks.length &&
      nestedSinkDeltasBeforeConnect.every((sink) =>
        sink.accepted === 0 && sink.active === 0) && nestedSshTargetsStayedIdle;
    assertThat(nestedNoRelayBeforeConnect,
      'nested Workspace save, sync, reload, or preview reached Relay before explicit Connect');

    const nestedTicketBaseline = {
      ticketsA: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      socketsA: relayWebSockets.A,
      socketsB: relayWebSockets.B,
      activeSocketsA: activeRelayWebSockets.A.size,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      sinks: relaySinkSnapshot(),
      sshd: sshFixtureSnapshot(),
    };
    const nestedRelayMonitor = {
      attempts: relayAttempts,
      webSockets: relayWebSockets,
      closes: relayWebSocketCloses,
      activeSockets: activeRelayWebSockets,
      syncApiEvents: vaultSyncApiEvents,
    };
    const nestedSshTrustEvidence = [];
    const nestedPageErrorBaseline = pageErrors.length;
    stage = 'Profile B explicitly connect nested Pane 1';
    const initialNestedSidebarConnectButtons =
      await visibleSidebarConnectButtons(pageB);
    stage = `Profile B nested Pane 1 sidebar action count (${initialNestedSidebarConnectButtons.indices.length})`;
    assertThat(initialNestedSidebarConnectButtons.indices.length === 3,
      'nested split preview did not expose one sidebar Connect action per leaf');
    const nestedPaneOneSidebarAction = await locateNestedSidebarConnectAction(
      pageB, 1, HOST_SPLIT_NAME,
    );
    try {
      await clickNestedSidebarConnectAction(pageB, nestedPaneOneSidebarAction);
    } catch (error) {
      stage = `Profile B nested Pane 1 sidebar Connect click failed (${error?.name || 'Error'})`;
      throw error;
    }
    const nestedPaneOneRelaySnapshot = () => {
      const tickets = relayAttempts.B.slice(nestedTicketBaseline.ticketsB);
      const sinks = relaySinkDeltas(nestedTicketBaseline.sinks);
      const sshd = sshFixtureSnapshot();
      return {
        sidebarActionCount: initialNestedSidebarConnectButtons.indices.length,
        relayTicketDelta: tickets.length,
        completedTicketCount: tickets.filter((item) => item.status !== null).length,
        relaySocketDelta: relayWebSockets.B - nestedTicketBaseline.socketsB,
        activeSocketDelta: activeRelayWebSockets.B.size -
          nestedTicketBaseline.activeSocketsB,
        firstSinkAcceptedDelta: sinks[0]?.accepted ?? 0,
        secondSinkAcceptedDelta: sinks[1]?.accepted ?? 0,
        thirdSinkAcceptedDelta: sinks[2]?.accepted ?? 0,
        firstSinkActiveDelta: sinks[0]?.active ?? 0,
        secondSinkActiveDelta: sinks[1]?.active ?? 0,
        thirdSinkActiveDelta: sinks[2]?.active ?? 0,
        paneOneSshBannerDelta: sshd[0].serverBannerEmitted -
          nestedTicketBaseline.sshd[0].serverBannerEmitted,
        paneOnePasswordAcceptedDelta: sshd[0].passwordAccepted -
          nestedTicketBaseline.sshd[0].passwordAccepted,
      };
    };
    let nestedPaneOneTicket;
    try {
      nestedPaneOneTicket = await waitForCaptured(() => {
        const issued = relayAttempts.B.slice(nestedTicketBaseline.ticketsB);
        return issued.length === 1 && issued[0].status !== null ? issued[0] : null;
      }, 'Profile B nested Pane 1 Relay ticket', 20000);
    } catch (error) {
      stage = `Profile B nested Pane 1 Relay ticket wait failed (${JSON.stringify(nestedPaneOneRelaySnapshot())})`;
      throw error;
    }
    try {
      await waitForCaptured(() =>
        activeRelayWebSockets.B.size === nestedTicketBaseline.activeSocketsB + 1 &&
        sshFixtureSnapshot()[0].serverBannerEmitted ===
          nestedTicketBaseline.sshd[0].serverBannerEmitted + 1 &&
        sshFixtureSnapshot()[0].clientBannerReceived ===
          nestedTicketBaseline.sshd[0].clientBannerReceived + 1 &&
        splitSecondSink.activeCount === nestedTicketBaseline.sinks[1].active &&
        splitThirdSink.activeCount === nestedTicketBaseline.sinks[2].active,
      'nested Pane 1 reaches its exact real SSHD through Relay', 15000);
    } catch (error) {
      stage = `Profile B nested Pane 1 Relay socket/SSHD wait failed (${JSON.stringify(nestedPaneOneRelaySnapshot())})`;
      throw error;
    }
    stage = `Profile B verify nested Pane 1 exact Relay target (${JSON.stringify({
      ...nestedPaneOneRelaySnapshot(),
      http200: nestedPaneOneTicket.status === 200,
      exactTarget: nestedPaneOneTicket.targetMatchesFirstSplitHost,
    })})`;
    assertThat(nestedPaneOneTicket.status === 200 &&
      nestedPaneOneTicket.targetMatchesFirstSplitHost &&
      sshFixtureSnapshot()[0].serverBannerEmitted ===
        nestedTicketBaseline.sshd[0].serverBannerEmitted + 1 &&
      splitSecondSink.acceptedCount === nestedTicketBaseline.sinks[1].accepted &&
      splitThirdSink.acceptedCount === nestedTicketBaseline.sinks[2].accepted,
    'nested Pane 1 Relay ticket did not target only its exact real SSH Host and port');
    stage = 'Profile B trust Pane 1 first-use SSH host key and authenticate password';
    nestedSshTrustEvidence.push(await completeWorkspaceSshAuthentication(
      pageB, 1, HOST_SPLIT_NAME, nestedSshServers[0], nestedTicketBaseline.sshd[0],
      nestedRelayMonitor,
    ));
    const nestedPaneOneRetryTicket = await waitForCaptured(() => {
      const issued = relayAttempts.B.slice(nestedTicketBaseline.ticketsB);
      return issued.length === 2 && issued[1].status !== null ? issued[1] : null;
    }, 'Profile B nested Pane 1 post-approval reconnect ticket', 20000);
    await waitForCaptured(() =>
      relayWebSockets.B - nestedTicketBaseline.socketsB === 2 &&
      relayWebSocketCloses.B === nestedTicketBaseline.closedSocketsB + 1 &&
      activeRelayWebSockets.B.size === nestedTicketBaseline.activeSocketsB + 1 &&
      sshFixtureSnapshot()[0].serverBannerEmitted ===
        nestedTicketBaseline.sshd[0].serverBannerEmitted + 2 &&
      sshFixtureSnapshot()[0].passwordAccepted ===
        nestedTicketBaseline.sshd[0].passwordAccepted + 1 &&
      sshFixtureSnapshot()[0].shellSessions ===
        nestedTicketBaseline.sshd[0].shellSessions + 1,
    'nested Pane 1 closes the untrusted handshake and reconnects after encrypted trust', 15000);
    const nestedPaneOneTrustRetryMatches =
      nestedPaneOneTicket.status === 200 &&
      nestedPaneOneTicket.targetMatchesFirstSplitHost &&
      nestedPaneOneRetryTicket.status === 200 &&
      nestedPaneOneRetryTicket.targetMatchesFirstSplitHost &&
      nestedSshTrustEvidence[0].displayedFingerprintMatchesSshd;
    assertThat(nestedPaneOneTrustRetryMatches,
      'nested Pane 1 did not retry the exact SSHD target after verifying its fingerprint');
    console.log('WEB-WORKSPACE-SSH-PANE-AUTH-CHECKPOINT', JSON.stringify({
      paneNumber: 1,
      exactTargetOnInitialAndPostTrustTickets: true,
      displayedFingerprintMatchesSshd: nestedSshTrustEvidence[0]
        .displayedFingerprintMatchesSshd,
      passwordAcceptedDelta: nestedSshTrustEvidence[0].sshdPasswordAcceptedDelta,
      passwordRejectedDelta: nestedSshTrustEvidence[0].sshdPasswordRejectedDelta,
      shellSessionDelta: nestedSshTrustEvidence[0].sshdShellSessionDelta,
      finalRelaySocketActive: activeRelayWebSockets.B.size ===
        nestedTicketBaseline.activeSocketsB + 1,
    }));
    const nestedPaneTwoBaseline = {
      ticketsB: relayAttempts.B.length,
      socketsB: relayWebSockets.B,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      sinks: relaySinkSnapshot(),
      sshd: sshFixtureSnapshot(),
    };
    stage = 'Profile B explicitly connect nested Pane 2';
    const nestedPaneTwoSidebarAction = await locateNestedSidebarConnectAction(
      pageB, 2, HOST_C_NAME,
    );
    stage = 'Profile B click nested Pane 2 sidebar Connect';
    let nestedPaneTwoClickGuard = null;
    try {
      nestedPaneTwoClickGuard = await clickNestedSidebarConnectAction(
        pageB, nestedPaneTwoSidebarAction,
      );
    } catch (error) {
      stage = `Profile B nested Pane 2 Connect click failed (${error?.name || 'Error'})`;
      throw error;
    }
    stage = 'Profile B wait for nested Pane 2 Relay ticket';
    let continuePaneTwoUiSampling = true;
    const nestedPaneTwoUiMonitorPromise = monitorNestedPaneConnectionUi(
      pageB, 2, HOST_C_NAME, () => continuePaneTwoUiSampling,
    );
    let nestedPaneTwoTicket;
    let nestedPaneTwoTicketError = null;
    try {
      nestedPaneTwoTicket = await waitForCaptured(() => {
        const issued = relayAttempts.B.slice(nestedPaneTwoBaseline.ticketsB);
        return issued.length === 1 && issued[0].status !== null ? issued[0] : null;
      }, 'Profile B nested Pane 2 Relay ticket', 20000);
    } catch (error) {
      nestedPaneTwoTicketError = error;
    } finally {
      continuePaneTwoUiSampling = false;
    }
    const nestedPaneTwoUiMonitor = await nestedPaneTwoUiMonitorPromise;
    if (nestedPaneTwoTicketError) {
      const issued = relayAttempts.B.slice(nestedPaneTwoBaseline.ticketsB);
      stage = `Profile B nested Pane 2 Relay ticket wait failed (${JSON.stringify({
        ticketCount: issued.length,
        completedTicketCount: issued.filter((item) => item.status !== null).length,
        firstTicketStatus200: issued[0]?.status === 200,
        firstTicketMatchesPaneTwoTarget: issued[0]?.targetMatchesThirdSplitHost === true,
        relaySocketDelta: relayWebSockets.B - nestedPaneTwoBaseline.socketsB,
        activeSocketDelta: activeRelayWebSockets.B.size -
          nestedPaneTwoBaseline.activeSocketsB,
        sinkDeltas: relaySinkDeltas(nestedPaneTwoBaseline.sinks),
        pageErrorDelta: pageErrors.length - nestedPageErrorBaseline,
        paneTwoClickGuard: nestedPaneTwoClickGuard,
        paneTwoUiMonitor: nestedPaneTwoUiMonitor,
        locator: nestedPaneTwoSidebarAction.diagnostic,
      })})`;
      throw nestedPaneTwoTicketError;
    }
    stage = 'Profile B verify nested Pane 2 exact Relay ticket target';
    stage = `Profile B verify nested Pane 2 exact Relay ticket target (${JSON.stringify({
      status200: nestedPaneTwoTicket.status === 200,
      expectedTarget: nestedPaneTwoTicket.targetMatchesThirdSplitHost,
      targetMatchesPaneOne: nestedPaneTwoTicket.targetMatchesFirstSplitHost,
      targetMatchesPaneThree: nestedPaneTwoTicket.targetMatchesSecondSplitHost,
      targetPort: nestedPaneTwoTicket.targetPort,
    })})`;
    assertThat(nestedPaneTwoTicket.status === 200 &&
      nestedPaneTwoTicket.targetMatchesThirdSplitHost,
    'nested Pane 2 Relay ticket did not target its exact real SSH Host and port');
    stage = 'Profile B wait for nested Pane 2 first-use SSH key exchange';
    try {
      await waitForCaptured(() =>
        sshFixtureSnapshot()[2].serverBannerEmitted ===
          nestedPaneTwoBaseline.sshd[2].serverBannerEmitted + 1 &&
        sshFixtureSnapshot()[2].clientBannerReceived ===
          nestedPaneTwoBaseline.sshd[2].clientBannerReceived + 1 &&
        sshFixtureSnapshot()[2].keyExchangeStarted >
          nestedPaneTwoBaseline.sshd[2].keyExchangeStarted &&
        sshFixtureSnapshot()[0].serverBannerEmitted ===
          nestedPaneTwoBaseline.sshd[0].serverBannerEmitted &&
        sshFixtureSnapshot()[1].serverBannerEmitted ===
          nestedPaneTwoBaseline.sshd[1].serverBannerEmitted &&
        splitSink.activeCount === nestedPaneTwoBaseline.sinks[0].active &&
        splitSecondSink.activeCount === nestedPaneTwoBaseline.sinks[1].active &&
        splitThirdSink.activeCount === nestedPaneTwoBaseline.sinks[2].active,
      'nested Pane 2 reaches SSH key exchange on only its exact real SSHD', 15000);
    } catch (error) {
      const issued = relayAttempts.B.slice(nestedPaneTwoBaseline.ticketsB);
      const runtime = await workspaceTerminalRuntimeSnapshot(pageB,
        [HOST_SPLIT_NAME, HOST_C_NAME]);
      stage = `Profile B nested Pane 2 SSH key exchange wait failed (${JSON.stringify({
        ticketCount: issued.length,
        completedTicketCount: issued.filter((item) => item.status !== null).length,
        ticketStatuses200: issued.map((item) => item.status === 200),
        ticketTargetsMatch: issued.map((item) => ({
          paneOne: item.targetMatchesFirstSplitHost === true,
          paneTwo: item.targetMatchesThirdSplitHost === true,
        })),
        relaySocketDelta: relayWebSockets.B - nestedPaneTwoBaseline.socketsB,
        activeSocketDelta: activeRelayWebSockets.B.size -
          nestedPaneTwoBaseline.activeSocketsB,
        sshdDeltas: sshFixtureSnapshot().map((summary, index) => ({
          banner: summary.serverBannerEmitted -
            nestedPaneTwoBaseline.sshd[index].serverBannerEmitted,
          clientBanner: summary.clientBannerReceived -
            nestedPaneTwoBaseline.sshd[index].clientBannerReceived,
          keyExchange: summary.keyExchangeStarted -
            nestedPaneTwoBaseline.sshd[index].keyExchangeStarted,
          accepted: summary.passwordAccepted -
            nestedPaneTwoBaseline.sshd[index].passwordAccepted,
          rejected: summary.passwordRejected -
            nestedPaneTwoBaseline.sshd[index].passwordRejected,
          shells: summary.shellSessions -
            nestedPaneTwoBaseline.sshd[index].shellSessions,
          openTcp: summary.tcpConnectionsOpen,
          closedTcpDelta: summary.tcpConnectionsClosed -
            nestedPaneTwoBaseline.sshd[index].tcpConnectionsClosed,
        })),
        sinkDeltas: relaySinkDeltas(nestedPaneTwoBaseline.sinks),
        runtime,
        ticketUiMonitor: nestedPaneTwoUiMonitor,
      })})`;
      throw error;
    }
    assertThat(relayAttempts.A.length === nestedTicketBaseline.ticketsA &&
      nestedPaneTwoTicket.status === 200 &&
      nestedPaneTwoTicket.targetMatchesThirdSplitHost &&
      sshFixtureSnapshot()[0].serverBannerEmitted ===
        nestedPaneTwoBaseline.sshd[0].serverBannerEmitted &&
      splitSecondSink.acceptedCount === nestedPaneTwoBaseline.sinks[1].accepted &&
      sshFixtureSnapshot()[2].serverBannerEmitted ===
        nestedPaneTwoBaseline.sshd[2].serverBannerEmitted + 1,
    'nested Pane 2 first-use key exchange did not reach its exact SSHD target');
    stage = 'Profile B trust Pane 2 first-use SSH host key and authenticate password';
    nestedSshTrustEvidence.push(await completeWorkspaceSshAuthentication(
      pageB, 2, HOST_C_NAME, nestedSshServers[2], nestedPaneTwoBaseline.sshd[2],
      nestedRelayMonitor,
    ));
    const nestedPaneTwoRetryTicket = await waitForCaptured(() => {
      const issued = relayAttempts.B.slice(nestedPaneTwoBaseline.ticketsB);
      return issued.length === 2 && issued[1].status !== null ? issued[1] : null;
    }, 'Profile B nested Pane 2 post-approval reconnect ticket', 20000);
    await waitForCaptured(() =>
      relayWebSockets.B - nestedPaneTwoBaseline.socketsB === 2 &&
      relayWebSocketCloses.B === nestedPaneTwoBaseline.closedSocketsB + 1 &&
      activeRelayWebSockets.B.size === nestedPaneTwoBaseline.activeSocketsB + 1 &&
      sshFixtureSnapshot()[2].serverBannerEmitted ===
        nestedPaneTwoBaseline.sshd[2].serverBannerEmitted + 2 &&
      sshFixtureSnapshot()[2].passwordAccepted ===
        nestedPaneTwoBaseline.sshd[2].passwordAccepted + 1 &&
      sshFixtureSnapshot()[2].shellSessions ===
        nestedPaneTwoBaseline.sshd[2].shellSessions + 1,
    'nested Pane 2 closes the untrusted handshake and reconnects after encrypted trust', 15000);
    const nestedPaneTwoTrustRetryMatches =
      nestedPaneTwoTicket.status === 200 &&
      nestedPaneTwoTicket.targetMatchesThirdSplitHost &&
      nestedPaneTwoRetryTicket.status === 200 &&
      nestedPaneTwoRetryTicket.targetMatchesThirdSplitHost &&
      nestedSshTrustEvidence[1].displayedFingerprintMatchesSshd;
    assertThat(nestedPaneTwoTrustRetryMatches,
      'nested Pane 2 did not retry the exact SSHD target after verifying its fingerprint');
    console.log('WEB-WORKSPACE-SSH-PANE-AUTH-CHECKPOINT', JSON.stringify({
      paneNumber: 2,
      exactTargetOnInitialAndPostTrustTickets: true,
      displayedFingerprintMatchesSshd: nestedSshTrustEvidence[1]
        .displayedFingerprintMatchesSshd,
      passwordAcceptedDelta: nestedSshTrustEvidence[1].sshdPasswordAcceptedDelta,
      passwordRejectedDelta: nestedSshTrustEvidence[1].sshdPasswordRejectedDelta,
      shellSessionDelta: nestedSshTrustEvidence[1].sshdShellSessionDelta,
      finalRelaySocketActive: activeRelayWebSockets.B.size ===
        nestedPaneTwoBaseline.activeSocketsB + 1,
    }));
    const nestedRuntimeSnapshot = await waitForWorkspaceTerminalRuntimes(pageB,
      [HOST_SPLIT_NAME, HOST_C_NAME]);
    const nestedRuntimesPresent = nestedRuntimeSnapshot.every((item) =>
      item.count === 1 && item.failedCount === 0 &&
      item.connectingCount + item.connectedCount === 1);
    assertThat(nestedRuntimesPresent,
      'nested Pane 1 and Pane 2 did not preserve independent authenticated runtimes');
    const nestedPaneThreeBaseline = {
      ticketsB: relayAttempts.B.length,
      socketsB: relayWebSockets.B,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      sinks: relaySinkSnapshot(),
      sshd: sshFixtureSnapshot(),
    };
    stage = 'Profile B explicitly connect nested Pane 3 to verify its Relay target';
    const nestedPaneThreeSidebarAction = await locateNestedSidebarConnectAction(
      pageB, 3, HOST_A_NAME,
    );
    const nestedPaneThreeClickGuard = await clickNestedSidebarConnectAction(
      pageB, nestedPaneThreeSidebarAction,
    );
    let continuePaneThreeUiSampling = true;
    const nestedPaneThreeUiMonitorPromise = monitorNestedPaneConnectionUi(
      pageB, 3, HOST_A_NAME, () => continuePaneThreeUiSampling,
    );
    let nestedPaneThreeTicket;
    let nestedPaneThreeTicketError = null;
    try {
      nestedPaneThreeTicket = await waitForCaptured(() => {
        const issued = relayAttempts.B.slice(nestedPaneThreeBaseline.ticketsB);
        return issued.length === 1 && issued[0].status !== null ? issued[0] : null;
      }, 'Profile B nested Pane 3 Relay ticket', 20000);
    } catch (error) {
      nestedPaneThreeTicketError = error;
    } finally {
      continuePaneThreeUiSampling = false;
    }
    const nestedPaneThreeUiMonitor = await nestedPaneThreeUiMonitorPromise;
    if (nestedPaneThreeTicketError) {
      const issued = relayAttempts.B.slice(nestedPaneThreeBaseline.ticketsB);
      stage = `Profile B nested Pane 3 Relay ticket wait failed (${JSON.stringify({
        ticketRequestCount: issued.length,
        completedTicketCount: issued.filter((item) => item.status !== null).length,
        ticketStatus: issued[0]?.status ?? null,
        exactHostAndPortMatch: issued[0]?.targetMatchesSecondSplitHost === true,
        relaySocketDelta: relayWebSockets.B - nestedPaneThreeBaseline.socketsB,
        activeSocketDelta: activeRelayWebSockets.B.size -
          nestedPaneThreeBaseline.activeSocketsB,
        sinkDeltas: relaySinkDeltas(nestedPaneThreeBaseline.sinks),
        pageErrorDelta: pageErrors.length - nestedPageErrorBaseline,
        clickGuard: nestedPaneThreeClickGuard,
        uiMonitor: nestedPaneThreeUiMonitor,
        locator: nestedPaneThreeSidebarAction.diagnostic,
      })})`;
      throw new Error('nested Pane 3 did not issue its Relay ticket');
    }
    stage = `Profile B verify nested Pane 3 exact Relay ticket target (${JSON.stringify({
      status200: nestedPaneThreeTicket.status === 200,
      expectedTarget: nestedPaneThreeTicket.targetMatchesSecondSplitHost,
      targetMatchesPaneOne: nestedPaneThreeTicket.targetMatchesFirstSplitHost,
      targetMatchesPaneTwo: nestedPaneThreeTicket.targetMatchesThirdSplitHost,
      targetPort: nestedPaneThreeTicket.targetPort,
    })})`;
    assertThat(nestedPaneThreeTicket.status === 200 &&
      nestedPaneThreeTicket.targetMatchesSecondSplitHost,
    'nested Pane 3 Relay ticket did not target its exact real SSH Host and port');
    stage = 'Profile B wait for nested Pane 3 first-use SSH key exchange';
    try {
      await waitForCaptured(() =>
        sshFixtureSnapshot()[1].serverBannerEmitted ===
          nestedPaneThreeBaseline.sshd[1].serverBannerEmitted + 1 &&
        sshFixtureSnapshot()[1].clientBannerReceived ===
          nestedPaneThreeBaseline.sshd[1].clientBannerReceived + 1 &&
        sshFixtureSnapshot()[1].keyExchangeStarted >
          nestedPaneThreeBaseline.sshd[1].keyExchangeStarted &&
        sshFixtureSnapshot()[0].serverBannerEmitted ===
          nestedPaneThreeBaseline.sshd[0].serverBannerEmitted &&
        sshFixtureSnapshot()[2].serverBannerEmitted ===
          nestedPaneThreeBaseline.sshd[2].serverBannerEmitted &&
        splitSink.activeCount === nestedPaneThreeBaseline.sinks[0].active &&
        splitSecondSink.activeCount === nestedPaneThreeBaseline.sinks[1].active &&
        splitThirdSink.activeCount === nestedPaneThreeBaseline.sinks[2].active,
      'nested Pane 3 reaches SSH key exchange on only its exact real SSHD', 15000);
    } catch (_) {
      const issued = relayAttempts.B.slice(nestedPaneThreeBaseline.ticketsB);
      const runtime = await workspaceTerminalRuntimeSnapshot(pageB,
        [HOST_SPLIT_NAME, HOST_C_NAME, HOST_A_NAME]);
      stage = `Profile B nested Pane 3 SSH key exchange wait failed (${JSON.stringify({
        ticketRequestCount: issued.length,
        completedTicketCount: issued.filter((item) => item.status !== null).length,
        paneThreeStatus200: nestedPaneThreeTicket.status === 200,
        exactHostAndPortMatch: nestedPaneThreeTicket.targetMatchesSecondSplitHost,
        relaySocketDelta: relayWebSockets.B - nestedPaneThreeBaseline.socketsB,
        activeSocketDelta: activeRelayWebSockets.B.size -
          nestedPaneThreeBaseline.activeSocketsB,
        sinkDeltas: relaySinkDeltas(nestedPaneThreeBaseline.sinks),
        runtime,
        pageErrorDelta: pageErrors.length - nestedPageErrorBaseline,
      })})`;
      throw new Error('nested Pane 3 did not establish its exact Relay socket and sink');
    }
    const nestedPaneThreeRelayCheckpoint = {
      ticketRequestCount: relayAttempts.B.length - nestedPaneThreeBaseline.ticketsB,
      ticketStatus200: nestedPaneThreeTicket.status === 200,
      exactHostAndPortMatch: nestedPaneThreeTicket.targetMatchesSecondSplitHost,
      relaySocketDelta: relayWebSockets.B - nestedPaneThreeBaseline.socketsB,
      activeSocketDelta: activeRelayWebSockets.B.size -
        nestedPaneThreeBaseline.activeSocketsB,
      sinkDeltas: relaySinkDeltas(nestedPaneThreeBaseline.sinks),
    };
    console.log('WEB-WORKSPACE-NESTED-PANE3-RELAY-CHECKPOINT',
      JSON.stringify(nestedPaneThreeRelayCheckpoint));
    stage = 'Profile B trust Pane 3 first-use SSH host key and authenticate password';
    nestedSshTrustEvidence.push(await completeWorkspaceSshAuthentication(
      pageB, 3, HOST_A_NAME, nestedSshServers[1], nestedPaneThreeBaseline.sshd[1],
      nestedRelayMonitor,
    ));
    const nestedPaneThreeRetryTicket = await waitForCaptured(() => {
      const issued = relayAttempts.B.slice(nestedPaneThreeBaseline.ticketsB);
      return issued.length === 2 && issued[1].status !== null ? issued[1] : null;
    }, 'Profile B nested Pane 3 post-approval reconnect ticket', 20000);
    await waitForCaptured(() =>
      relayWebSockets.B - nestedPaneThreeBaseline.socketsB === 2 &&
      relayWebSocketCloses.B === nestedPaneThreeBaseline.closedSocketsB + 1 &&
      activeRelayWebSockets.B.size === nestedPaneThreeBaseline.activeSocketsB + 1 &&
      sshFixtureSnapshot()[1].serverBannerEmitted ===
        nestedPaneThreeBaseline.sshd[1].serverBannerEmitted + 2 &&
      sshFixtureSnapshot()[1].passwordAccepted ===
        nestedPaneThreeBaseline.sshd[1].passwordAccepted + 1 &&
      sshFixtureSnapshot()[1].shellSessions ===
        nestedPaneThreeBaseline.sshd[1].shellSessions + 1,
    'nested Pane 3 closes the untrusted handshake and reconnects after encrypted trust', 15000);
    const nestedPaneThreeTrustRetryMatches =
      nestedPaneThreeTicket.status === 200 &&
      nestedPaneThreeTicket.targetMatchesSecondSplitHost &&
      nestedPaneThreeRetryTicket.status === 200 &&
      nestedPaneThreeRetryTicket.targetMatchesSecondSplitHost &&
      nestedSshTrustEvidence[2].displayedFingerprintMatchesSshd;
    assertThat(nestedPaneThreeTrustRetryMatches,
      'nested Pane 3 did not retry the exact SSHD target after verifying its fingerprint');
    console.log('WEB-WORKSPACE-SSH-PANE-AUTH-CHECKPOINT', JSON.stringify({
      paneNumber: 3,
      exactTargetOnInitialAndPostTrustTickets: true,
      displayedFingerprintMatchesSshd: nestedSshTrustEvidence[2]
        .displayedFingerprintMatchesSshd,
      passwordAcceptedDelta: nestedSshTrustEvidence[2].sshdPasswordAcceptedDelta,
      passwordRejectedDelta: nestedSshTrustEvidence[2].sshdPasswordRejectedDelta,
      shellSessionDelta: nestedSshTrustEvidence[2].sshdShellSessionDelta,
      finalRelaySocketActive: activeRelayWebSockets.B.size ===
        nestedPaneThreeBaseline.activeSocketsB + 1,
    }));
    stage = 'Profile B verify three nested SSH runtimes are connected';
    const nestedAllRuntimeSnapshot = await waitForWorkspaceTerminalRuntimes(pageB,
      [HOST_SPLIT_NAME, HOST_C_NAME, HOST_A_NAME]);
    const nestedAllRuntimesPresent = nestedAllRuntimeSnapshot.every((item) =>
      item.count === 1 && item.connectedCount === 1 &&
      item.connectingCount === 0 && item.failedCount === 0);
    console.log('WEB-WORKSPACE-NESTED-SSH-RUNTIME-CHECKPOINT', JSON.stringify({
      paneRuntimeCount: nestedAllRuntimeSnapshot.length,
      exactlyOneConnectedRuntimePerPane: nestedAllRuntimesPresent,
      connectingRuntimeCount: nestedAllRuntimeSnapshot.filter((item) =>
        item.connectingCount === 1).length,
      connectedRuntimeCount: nestedAllRuntimeSnapshot.filter((item) =>
        item.connectedCount === 1).length,
      failedRuntimeCount: nestedAllRuntimeSnapshot.reduce((total, item) =>
        total + item.failedCount, 0),
      realOpenSshPasswordAuthentication: true,
      independentPaneHostKeyTrustAndAuth: nestedSshTrustEvidence.length === 3,
    }));
    assertThat(nestedAllRuntimesPresent,
      'the three nested Relay routes did not complete independent OpenSSH sessions');
    assertThat(relayAttempts.A.length === nestedTicketBaseline.ticketsA &&
      nestedPaneThreeTicket.status === 200 &&
      nestedPaneThreeTicket.targetMatchesSecondSplitHost &&
      sshFixtureSnapshot()[0].passwordAccepted ===
        nestedTicketBaseline.sshd[0].passwordAccepted + 1 &&
      sshFixtureSnapshot()[2].passwordAccepted ===
        nestedTicketBaseline.sshd[2].passwordAccepted + 1 &&
      sshFixtureSnapshot()[1].passwordAccepted ===
        nestedTicketBaseline.sshd[1].passwordAccepted + 1 &&
      nestedSshTrustEvidence.every((item) =>
        item.displayedFingerprintMatchesSshd &&
        item.sshdPasswordAcceptedDelta === 1 &&
        item.sshdShellSessionDelta === 1) &&
      relayAttempts.B.length === nestedTicketBaseline.ticketsB + 6 &&
      relayWebSockets.B === nestedTicketBaseline.socketsB + 6 &&
      relayWebSocketCloses.B === nestedTicketBaseline.closedSocketsB + 3 &&
      nestedAllRuntimesPresent,
    'all three nested leaves did not authenticate independently at their exact Relay targets');

    stage = 'capture Relay and OpenSSH baselines before pane-scoped SFTP';
    const nestedWorkspaceSftpBaseline = {
      ticketsB: relayAttempts.B.length,
      socketsB: relayWebSockets.B,
      activeSocketsB: activeRelayWebSockets.B.size,
      closedSocketsB: relayWebSocketCloses.B,
      sshd: sshFixtureSnapshot(),
    };
    const nestedWorkspaceSftpDirectoryName =
      `workspace-sftp-${RUN_ID.slice(0, 8)}`;
    const nestedWorkspaceSftpDirectory = path.join(
      path.dirname(nestedSshServers[2].logPath),
      'jail', 'tmp', nestedWorkspaceSftpDirectoryName,
    );
    stage = 'Profile B open Files from connected nested Pane 2';
    const nestedPaneSftpUiSnapshot = await pageB.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none';
      };
      const buttonLabels = [...document.querySelectorAll(
        'flt-semantics[role="button"]',
      )].filter(visible).map((node) =>
        (node.getAttribute('aria-label') || node.innerText || '')
          .replace(/\s+/g, ' ').trim());
      const visibleSemantics = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => ({
          role: node.getAttribute('role') || '',
          label: (node.getAttribute('aria-label') || node.innerText ||
            node.textContent || '').replace(/\s+/g, ' ').trim(),
          rect: node.getBoundingClientRect().toJSON(),
        }))
        .filter((item) => /Pane [1-3]|Browse files|SSH terminal input|Workspace|Terminal|Files|Search/i
          .test(item.label))
        .slice(0, 60);
      return {
        livePaneLabels: visibleSemantics.map((item) => item.label)
          .filter((label) => /^Pane [1-3] · /.test(label)),
        filesLabels: buttonLabels.filter((label) => /Browse files on /.test(label)),
        terminalTabLabels: buttonLabels.filter((label) => / terminal tab, /.test(label)),
        terminalNavigationPresent: buttonLabels.includes('Terminal'),
        sftpHeadingVisible: [...document.querySelectorAll('flt-semantics')]
          .filter(visible).some((node) =>
            (node.getAttribute('aria-label') || node.innerText || '')
              .includes('SFTP file browser')),
        semanticsSample: visibleSemantics,
      };
    });
    console.log('WEB-WORKSPACE-PANE-SFTP-UI-CHECKPOINT',
      JSON.stringify(nestedPaneSftpUiSnapshot));
    await click(pageB, `Browse files on ${HOST_C_NAME}`);
    await waitForVisibleSemanticText(pageB, 'SFTP file browser',
      'nested Pane 2 SFTP page');
    await waitForVisibleSemanticText(pageB, 'Remote path: /',
      'nested Pane 2 initial SFTP path');
    stage = 'Profile B navigate nested Pane 2 SFTP to /tmp';
    await click(pageB, 'Go to path');
    await waitForVisibleSemanticText(pageB, 'Go to remote path',
      'nested Pane 2 SFTP path dialog');
    await fill(pageB, 'Remote path', '/tmp');
    await click(pageB, 'Go');
    await waitForVisibleSemanticText(pageB, 'Remote path: /tmp',
      'nested Pane 2 /tmp path');
    stage = 'Profile B create a run-scoped directory over Pane 2 SFTP';
    await click(pageB, 'New folder');
    await waitForVisibleSemanticText(pageB, 'Create remote folder',
      'nested Pane 2 create-directory dialog');
    await fill(pageB, 'Folder name', nestedWorkspaceSftpDirectoryName);
    const nestedWorkspaceSftpCreateButton = pageB.getByRole('button', {
      name: 'Create', exact: true,
    }).last();
    await nestedWorkspaceSftpCreateButton.waitFor({
      state: 'visible', timeout: 15000,
    });
    assertThat(await nestedWorkspaceSftpCreateButton.isEnabled(),
      'nested Pane 2 SFTP create-directory action remained disabled');
    await nestedWorkspaceSftpCreateButton.click();
    await waitForVisibleSemanticText(pageB, nestedWorkspaceSftpDirectoryName,
      'nested Pane 2 created SFTP directory');
    const nestedWorkspacePaneTwoSftpCreated = await waitForCaptured(() => {
      const summaries = sshFixtureSnapshot();
      return summaries[2].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[2].sftpRequests + 1 &&
        summaries[2].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[2].sftpSessions + 1 &&
        summaries[0].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[0].sftpRequests &&
        summaries[0].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[0].sftpSessions &&
        summaries[1].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[1].sftpRequests &&
        summaries[1].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[1].sftpSessions &&
        fs.existsSync(nestedWorkspaceSftpDirectory) &&
        fs.statSync(nestedWorkspaceSftpDirectory).isDirectory();
    }, 'nested Pane 2 SFTP directory on its exact OpenSSH chroot', 15000);
    assertThat(nestedWorkspacePaneTwoSftpCreated === true &&
      relayAttempts.B.length === nestedWorkspaceSftpBaseline.ticketsB &&
      relayWebSockets.B === nestedWorkspaceSftpBaseline.socketsB &&
      relayWebSocketCloses.B === nestedWorkspaceSftpBaseline.closedSocketsB &&
      activeRelayWebSockets.B.size ===
        nestedWorkspaceSftpBaseline.activeSocketsB,
    'Pane 2 SFTP did not create its directory only on the exact SSHD over the existing Relay session');

    stage = 'reopen nested Pane 2 Files and verify its remote path is retained';
    await click(pageB, 'Terminal');
    await click(pageB, `Browse files on ${HOST_C_NAME}`);
    await waitForVisibleSemanticText(pageB,
      'Remote path: /tmp',
      'nested Pane 2 retained SFTP path after reopening');
    const nestedWorkspacePaneTwoSftpReopened =
      relayAttempts.B.length === nestedWorkspaceSftpBaseline.ticketsB &&
      relayWebSockets.B === nestedWorkspaceSftpBaseline.socketsB &&
      relayWebSocketCloses.B === nestedWorkspaceSftpBaseline.closedSocketsB &&
      activeRelayWebSockets.B.size ===
        nestedWorkspaceSftpBaseline.activeSocketsB &&
      sshFixtureSnapshot()[2].sftpRequests ===
        nestedWorkspaceSftpBaseline.sshd[2].sftpRequests + 1 &&
      sshFixtureSnapshot()[2].sftpSessions ===
        nestedWorkspaceSftpBaseline.sshd[2].sftpSessions + 1;
    assertThat(nestedWorkspacePaneTwoSftpReopened,
      'reopening Pane 2 Files did not retain its path on the same SSH session');

    stage = 'open Files from a different connected nested Workspace pane';
    await click(pageB, 'Terminal');
    await click(pageB, `Browse files on ${HOST_A_NAME}`);
    await waitForVisibleSemanticText(pageB, 'SFTP file browser',
      'nested Pane 3 SFTP page');
    await waitForVisibleSemanticText(pageB, 'Remote path: /',
      'nested Pane 3 independent initial SFTP path');
    const nestedWorkspacePaneThreeSftpIsolated = await waitForCaptured(() => {
      const summaries = sshFixtureSnapshot();
      return summaries[1].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[1].sftpRequests + 1 &&
        summaries[1].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[1].sftpSessions + 1 &&
        summaries[0].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[0].sftpRequests &&
        summaries[0].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[0].sftpSessions &&
        summaries[2].sftpRequests ===
          nestedWorkspaceSftpBaseline.sshd[2].sftpRequests + 1 &&
        summaries[2].sftpSessions ===
          nestedWorkspaceSftpBaseline.sshd[2].sftpSessions + 1 &&
        relayAttempts.B.length === nestedWorkspaceSftpBaseline.ticketsB &&
        relayWebSockets.B === nestedWorkspaceSftpBaseline.socketsB &&
        relayWebSocketCloses.B === nestedWorkspaceSftpBaseline.closedSocketsB &&
        activeRelayWebSockets.B.size ===
          nestedWorkspaceSftpBaseline.activeSocketsB;
    }, 'nested Pane 3 SFTP uses only its own path/session without Relay reconnect', 15000);
    assertThat(nestedWorkspacePaneThreeSftpIsolated === true,
      'opening Pane 3 Files reused Pane 2 SFTP state or changed Relay transports');
    stage = 'return from pane-scoped SFTP to the live nested Workspace terminals';
    await click(pageB, 'Terminal');
    await waitForVisibleSemanticText(pageB, `Pane 1 · ${HOST_SPLIT_NAME}`,
      'nested Workspace terminal panes after SFTP');
    const nestedWorkspaceSftpEvidence = {
      paneTwoFilesActionBoundToExactHost: true,
      paneTwoDirectoryCreatedAtExactFixtureChroot: true,
      paneTwoSftpRequestDelta: sshFixtureSnapshot()[2].sftpRequests -
        nestedWorkspaceSftpBaseline.sshd[2].sftpRequests,
      paneTwoSftpSessionDelta: sshFixtureSnapshot()[2].sftpSessions -
        nestedWorkspaceSftpBaseline.sshd[2].sftpSessions,
      paneOneAndThreeSftpRequestsUnchangedDuringPaneTwoOperation:
        nestedWorkspacePaneTwoSftpCreated === true,
      paneTwoPathRetainedAfterReopen: nestedWorkspacePaneTwoSftpReopened,
      paneThreeStartsAtIndependentRoot: true,
      paneThreeSftpRequestDelta: sshFixtureSnapshot()[1].sftpRequests -
        nestedWorkspaceSftpBaseline.sshd[1].sftpRequests,
      noRelayTicketOrWebSocketChange: relayAttempts.B.length ===
          nestedWorkspaceSftpBaseline.ticketsB &&
        relayWebSockets.B === nestedWorkspaceSftpBaseline.socketsB &&
        relayWebSocketCloses.B === nestedWorkspaceSftpBaseline.closedSocketsB &&
        activeRelayWebSockets.B.size ===
          nestedWorkspaceSftpBaseline.activeSocketsB,
    };
    console.log('WEB-WORKSPACE-PANE-SFTP-CHECKPOINT',
      JSON.stringify(nestedWorkspaceSftpEvidence));

    stage = 'Profile B disconnect nested Pane 1 while Pane 2 and 3 Relay transports stay open';
    const nestedPaneOneTab = pageB.getByRole('button', {
      name: new RegExp(`^${escapeRegExp(HOST_SPLIT_NAME)} terminal tab,`),
    });
    assertThat(await nestedPaneOneTab.count() === 1,
      'nested Pane 1 terminal tab was not uniquely selectable for disconnect');
    await nestedPaneOneTab.click();
    await click(pageB, 'Disconnect');
    await waitForCaptured(() =>
      activeRelayWebSockets.B.size === nestedTicketBaseline.activeSocketsB + 2 &&
      relayWebSocketCloses.B === nestedTicketBaseline.closedSocketsB + 4 &&
      sshFixtureSnapshot()[0].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[0].tcpConnectionsOpen &&
      sshFixtureSnapshot()[1].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[1].tcpConnectionsOpen + 1 &&
      sshFixtureSnapshot()[2].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[2].tcpConnectionsOpen + 1 &&
      splitSink.activeCount === nestedTicketBaseline.sinks[0].active &&
      splitSecondSink.activeCount === nestedTicketBaseline.sinks[1].active &&
      splitThirdSink.activeCount === nestedTicketBaseline.sinks[2].active,
    'nested Pane 1 disconnect closes only its real SSHD and Relay transport', 15000);
    const removedPaneOneRuntime = await waitForWorkspaceTerminalRuntimeRemoval(
      pageB, [HOST_SPLIT_NAME],
    );
    const nestedRuntimeAfterDisconnect = await workspaceTerminalRuntimeSnapshot(pageB,
      [HOST_SPLIT_NAME, HOST_C_NAME, HOST_A_NAME]);
    const nestedSshAfterDisconnect = sshFixtureSnapshot();
    const nestedPaneIsolatedDisconnect =
      nestedRuntimeAfterDisconnect[0].count === 0 &&
      nestedRuntimeAfterDisconnect[1].count === 1 &&
      nestedRuntimeAfterDisconnect[1].failedCount === 0 &&
      nestedRuntimeAfterDisconnect[1].connectingCount === 0 &&
      nestedRuntimeAfterDisconnect[1].connectedCount === 1 &&
      nestedRuntimeAfterDisconnect[2].count === 1 &&
      nestedRuntimeAfterDisconnect[2].failedCount === 0 &&
      nestedRuntimeAfterDisconnect[2].connectingCount === 0 &&
      nestedRuntimeAfterDisconnect[2].connectedCount === 1 &&
      removedPaneOneRuntime[0].count === 0 &&
      relayAttempts.B.length === nestedTicketBaseline.ticketsB + 6 &&
      relayWebSockets.B === nestedTicketBaseline.socketsB + 6 &&
      activeRelayWebSockets.B.size === nestedTicketBaseline.activeSocketsB + 2 &&
      nestedSshAfterDisconnect[0].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[0].tcpConnectionsOpen &&
      nestedSshAfterDisconnect[1].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[1].tcpConnectionsOpen + 1 &&
      nestedSshAfterDisconnect[2].tcpConnectionsOpen ===
        nestedTicketBaseline.sshd[2].tcpConnectionsOpen + 1;
    assertThat(nestedPaneIsolatedDisconnect,
      'disconnecting nested Pane 1 also removed or changed another real SSH runtime/transport');

    // Closing Pane 1 can select an unrelated older tab depending on tab order.
    // Activate a known surviving Workspace tab so the live recursive split,
    // including Pane 1's disconnected card, is the surface under assertion.
    stage = 'activate surviving nested Pane 2 after local disconnect';
    const nestedPaneTwoTabAfterDisconnect = pageB.getByRole('button', {
      name: new RegExp(`^${escapeRegExp(HOST_C_NAME)} terminal tab,`),
    });
    assertThat(await nestedPaneTwoTabAfterDisconnect.count() === 1,
      'nested Pane 2 terminal tab was not uniquely available after Pane 1 disconnect');
    await nestedPaneTwoTabAfterDisconnect.click();

    stage = 'return to the saved nested Workspace preview after local disconnect';
    await click(pageB, 'Workspaces');
    await waitForVisibleSemanticText(pageB, 'Saved workspaces',
      'Workspaces page after local pane disconnect', 15000);
    await stageSplitWorkspacePreview(pageB, NESTED_SPLIT_WORKSPACE_NAME, {
      existingWorkspaceNames: [
        WORKSPACE_NAME,
        WORKSPACE_BRANCH_B_COPY_NAME,
        SPLIT_WORKSPACE_NAME,
      ],
      expectedHosts: [HOST_SPLIT_NAME, HOST_C_NAME, HOST_A_NAME],
      connectedHosts: [HOST_C_NAME, HOST_A_NAME],
    });

    stage = 'verify nested pane preview and reconnect action after local disconnect [map sidebar panes]';
    const disconnectedPaneHostMaps = await Promise.all([
      visibleSidebarConnectButtonForPane(pageB, 1, HOST_SPLIT_NAME),
      visibleSidebarConnectButtonForPane(pageB, 2, HOST_C_NAME),
      visibleSidebarConnectButtonForPane(pageB, 3, HOST_A_NAME),
    ]);
    const disconnectedPaneTreePreserved = disconnectedPaneHostMaps.every((match) =>
      match.diagnostics.paneLabelMatchCount === 1 &&
      match.diagnostics.paneHostPairCount === 1);
    stage = 'verify nested pane preview and reconnect action after local disconnect [locate pane one Connect]';
    const nestedPaneOneReconnect = await locateNestedSidebarConnectAction(
      pageB, 1, HOST_SPLIT_NAME,
    );
    const sidebarReconnectButtonCount = nestedPaneOneReconnect.matchingCount;
    stage = 'verify nested pane preview and reconnect action after local disconnect [snapshot pane one]';
    const nestedPaneOneSidebarState = await nestedPaneConnectionUiSnapshot(
      pageB, 1, HOST_SPLIT_NAME,
    );
    const nestedPaneTwoSidebarState = await nestedPaneConnectionUiSnapshot(
      pageB, 2, HOST_C_NAME,
    );
    const nestedPaneThreeSidebarState = await nestedPaneConnectionUiSnapshot(
      pageB, 3, HOST_A_NAME,
    );
    const nestedDisconnectUiPreserved = disconnectedPaneTreePreserved &&
      sidebarReconnectButtonCount === 1 &&
      nestedPaneOneReconnect.diagnostic.buttonVisible &&
      nestedPaneOneReconnect.diagnostic.buttonEnabled &&
      nestedPaneOneSidebarState.uniquePaneHostPair &&
      nestedPaneOneSidebarState.terminalRuntime.count === 0 &&
      nestedPaneTwoSidebarState.uniquePaneHostPair &&
      nestedPaneThreeSidebarState.uniquePaneHostPair &&
      nestedPaneTwoSidebarState.terminalRuntime.connectedCount === 1 &&
      nestedPaneThreeSidebarState.terminalRuntime.connectedCount === 1;
    console.log('WEB-WORKSPACE-NESTED-DISCONNECT-UI-CHECKPOINT', JSON.stringify({
      paneOneRuntimeRemoved: removedPaneOneRuntime[0].count === 0,
      paneOneSidebarPaneHostPairUnique:
        nestedPaneOneSidebarState.uniquePaneHostPair,
      paneOneReconnectMatchCount: sidebarReconnectButtonCount,
      paneTwoSidebarFocusCount: nestedPaneTwoSidebarState.focusActionCount,
      paneTwoSidebarConnectCount: nestedPaneTwoSidebarState.connectActionCount,
      paneThreeSidebarFocusCount: nestedPaneThreeSidebarState.focusActionCount,
      paneThreeSidebarConnectCount: nestedPaneThreeSidebarState.connectActionCount,
      paneOneSidebarFocusCount: nestedPaneOneSidebarState.focusActionCount,
      paneOneRuntimeCountAfterDisconnect:
        nestedPaneOneSidebarState.terminalRuntime.count,
      paneOneConnectActionVisible:
        nestedPaneOneReconnect.diagnostic.buttonVisible,
      paneTwoAndThreeRuntimesPreserved:
        nestedRuntimeAfterDisconnect[1].count === 1 &&
        nestedRuntimeAfterDisconnect[2].count === 1,
      remainingRealSshdConnections:
        nestedSshAfterDisconnect[1].tcpConnectionsOpen +
        nestedSshAfterDisconnect[2].tcpConnectionsOpen,
    }));
    assertThat(nestedDisconnectUiPreserved,
      'pane-local disconnect did not preserve all pane previews and the reconnect action');
    const nestedWorkspaceRelayEvidence = {
      schemaVersion: 3,
      mixedAxisTopologyAfterReload: profileBDecryptsNestedAfterReload,
      nestedAxis: 'vertical',
      nestedRatioBasisPoints: 5700,
      rootAxis: 'horizontal',
      rootRatioBasisPoints: 6300,
      activePane: 2,
      threeDistinctHostRefsDecryptedAfterReload: true,
      hostReferenceIdsAbsentFromWorkspacePushEnvelope:
        nestedMatchingPush.encryptedWorkspaceHostReferenceMarkersAbsent,
      hostReferenceIdsAbsentFromProfileBPulledWorkspaceEnvelope:
        nestedWorkspaceApiHostReferencePrivacy,
      hostReferenceIdsAbsentFromPersistedWorkspaceEnvelope:
        nestedVersion.markersAbsent,
      profileBObservedCreateChange: nestedWorkspaceChangeObserved,
      encryptedCreateRecordIdPresent: Boolean(nestedWorkspaceRecordId),
      oneEncryptedCreateCommitAndReceipt: true,
      noRelayBeforeExplicitConnect: nestedNoRelayBeforeConnect,
      explicitConnectTicketCount: relayAttempts.B.length - nestedTicketBaseline.ticketsB,
      paneOneExactTarget: nestedPaneOneTicket.targetMatchesFirstSplitHost,
      paneTwoExactTarget: nestedPaneTwoTicket.targetMatchesThirdSplitHost,
      paneThreeExactTarget: nestedPaneThreeTicket.targetMatchesSecondSplitHost,
      postTrustReconnectTicketsExactlyOnePerPane:
        [nestedPaneOneRetryTicket, nestedPaneTwoRetryTicket,
          nestedPaneThreeRetryTicket].length === 3,
      eachDisplayedFingerprintMatchedTheExactSshdKey:
        nestedSshTrustEvidence.every((item) => item.displayedFingerprintMatchesSshd),
      allLeavesHaveIndependentRuntimes: nestedAllRuntimesPresent,
      disconnectIsPaneLocal: nestedPaneIsolatedDisconnect,
      paneTreeAndSiblingPreviewsRemainVisibleAfterDisconnect:
        nestedDisconnectUiPreserved,
      disconnectedPaneHasReconnectAction: sidebarReconnectButtonCount === 1,
      activeRemainingOpenSshConnections:
        nestedSshAfterDisconnect[1].tcpConnectionsOpen +
        nestedSshAfterDisconnect[2].tcpConnectionsOpen,
      threePaneHostKeyAndPasswordAuthEvidence: nestedSshTrustEvidence,
    };
    captureWorkspaceSplit = false;

    stage = 'Profile A add a separate encrypted tmux Credential';
    const tmuxBChangesPageBaseline = vaultChangesPages.B.length;
    const tmuxCredentialVaultBefore = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(tmuxCredentialVaultBefore,
      'tmux Credential creation did not find the active Vault');
    await addCredential(pageA, () => pageErrors.length, {
      name: TMUX_CREDENTIAL_NAME,
      username: TMUX_SSH_USERNAME,
      password: TMUX_CREDENTIAL_SECRET,
    });
    await syncNow(pageA, 'tmux fixture Credential sync');
    const tmuxCredentialVaultAfter = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(tmuxCredentialVaultAfter,
      'tmux Credential sync did not find the active Vault afterward');
    const tmuxCredentialCreate = serverCommitDelta(
      databasePath,
      vaultId,
      tmuxCredentialVaultBefore.commitSeq,
      tmuxCredentialVaultAfter.commitSeq,
    );
    assertThat(tmuxCredentialCreate.eventCount === 1 &&
      tmuxCredentialCreate.distinctCommitCount === 1 &&
      tmuxCredentialCreate.events[0]?.operation === 'create',
    'the independent tmux Credential did not sync as exactly one encrypted record');
    const tmuxCredentialRecordId = tmuxCredentialCreate.events[0].recordId;
    assertThat(typeof tmuxCredentialRecordId === 'string' &&
      tmuxCredentialRecordId.length > 0,
    'the independent tmux Credential did not expose its opaque record ID');
    stage = 'Profile A create the independent tmux Host';
    const beforeTmuxHost = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(beforeTmuxHost, 'tmux Host creation did not find the active Vault');
    await addHost(pageA, HOST_TMUX_NAME, splitTargetAddress, {
      port: tmuxFixturePort,
      sshUsername: TMUX_SSH_USERNAME,
      credentialName: TMUX_CREDENTIAL_NAME,
    });
    await syncNow(pageA, 'tmux fixture Host sync');
    const afterTmuxHost = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const tmuxHostCreate = serverCommitDelta(
      databasePath, vaultId, beforeTmuxHost.commitSeq, afterTmuxHost.commitSeq,
    );
    assertThat(tmuxHostCreate.eventCount === 1 &&
      tmuxHostCreate.distinctCommitCount === 1 &&
      tmuxHostCreate.events[0]?.operation === 'create',
    'the independent tmux Host did not sync as exactly one encrypted record');
    const tmuxHostRecordId = tmuxHostCreate.events[0].recordId;
    assertThat(typeof tmuxHostRecordId === 'string' && tmuxHostRecordId.length > 0,
      'the independent tmux Host did not expose its opaque record ID');
    workspaceHostReferenceMarkers = [...new Set([
      ...workspaceHostReferenceMarkers,
      tmuxHostRecordId,
      tmuxCredentialRecordId,
    ])];

    stage = 'Profile B pull the tmux Credential and Host before Workspace creation';
    await click(pageB, 'Hosts');
    const tmuxHostSyncApiBaseline = vaultSyncApiEvents.B.length;
    const tmuxHostChangesPageBaseline = tmuxBChangesPageBaseline;
    const tmuxHostPullPages = [];
    let tmuxCapturedPageCount = 0;
    const appendCapturedTmuxHostPages = () => {
      const captured = vaultChangesPages.B.slice(tmuxHostChangesPageBaseline);
      tmuxHostPullPages.push(...captured.slice(tmuxCapturedPageCount));
      tmuxCapturedPageCount = captured.length;
    };
    const tmuxRefsObservedOnB = () => {
      const pages = tmuxHostPullPages.filter((item) => item.httpStatus === 200);
      const hostObserved = pages.some((item) =>
        item.seenRecordIds?.includes(tmuxHostRecordId));
      const credentialObserved = pages.some((item) =>
        item.seenRecordIds?.includes(tmuxCredentialRecordId));
      return { hostObserved, credentialObserved, pages };
    };
    let tmuxHostPullSummary = null;
    let tmuxHostPullState = tmuxRefsObservedOnB();
    for (let attempt = 1; attempt <= 3 &&
        !(tmuxHostPullState.hostObserved && tmuxHostPullState.credentialObserved);
        attempt += 1) {
      const syncLabel = attempt === 1
        ? 'Profile B tmux Host and Credential pull'
        : `Profile B tmux Host and Credential pull retry ${attempt}`;
      const pageCountBeforeAttempt = vaultChangesPages.B.length;
      tmuxHostPullSummary = await syncNow(pageB, syncLabel, { forcePull: true });
      if (vaultChangesPages.B.length <= pageCountBeforeAttempt) {
        await waitForCaptured(() => vaultChangesPages.B.length > pageCountBeforeAttempt
          ? true : null,
        `${syncLabel} response summary`, 5000).catch(() => null);
      }
      appendCapturedTmuxHostPages();
      tmuxHostPullState = tmuxRefsObservedOnB();
      if (!(tmuxHostPullState.hostObserved && tmuxHostPullState.credentialObserved)) {
        await waitForCaptured(() => {
          appendCapturedTmuxHostPages();
          tmuxHostPullState = tmuxRefsObservedOnB();
          return tmuxHostPullState.hostObserved &&
            tmuxHostPullState.credentialObserved ? true : null;
        }, 'Profile B tmux Host and Credential change pages', 2000).catch(() => null);
        appendCapturedTmuxHostPages();
        tmuxHostPullState = tmuxRefsObservedOnB();
      }
    }
    stage = 'Profile B inspect tmux Host and Credential pull response and Host list';
    const tmuxHostCardLocator = pageB.getByRole('group', {
      name: new RegExp(`^Host: ${escapeRegExp(HOST_TMUX_NAME)}; `),
    });
    const tmuxHostCardMatches = await tmuxHostCardLocator.count().catch(() => 0);
    const tmuxHostPageFlags = await workspaceUiFlags(pageB);
    const tmuxHostLabelVisible = await visibleSemanticTextMatch(pageB, HOST_TMUX_NAME);
    const tmuxHostApiPullEvents = vaultSyncApiEvents.B.slice(tmuxHostSyncApiBaseline);
    const tmuxHostPullHasRecord = tmuxHostPullState.hostObserved;
    const tmuxCredentialPullHasRecord = tmuxHostPullState.credentialObserved;
    const tmuxHostCredentialCardCount = await pageB.getByRole('group', {
      name: /^Credential: /,
    }).count().catch(() => 0);
    const tmuxHostCardVisibleCount = await tmuxHostCardLocator.count().then(async (count) => {
      let visible = 0;
      for (let index = 0; index < count; index += 1) {
        if (await tmuxHostCardLocator.nth(index).isVisible().catch(() => false)) visible++;
      }
      return visible;
    }).catch(() => 0);
    console.log('WEB-WORKSPACE-TMUX-HOST-PULL-CHECKPOINT', JSON.stringify({
      pullHttpStatus: tmuxHostPullSummary?.httpStatus ?? null,
      pullResponseCount: tmuxHostPullState.pages.length,
      expectedHostRecordObserved: tmuxHostPullHasRecord,
      expectedCredentialRecordObserved: tmuxCredentialPullHasRecord,
      hostRecordResponseCount: tmuxHostPullState.pages.filter((item) =>
        item.seenRecordIds?.includes(tmuxHostRecordId)).length,
      credentialRecordResponseCount: tmuxHostPullState.pages.filter((item) =>
        item.seenRecordIds?.includes(tmuxCredentialRecordId)).length,
      pullEventCount: tmuxHostPullPages.reduce((count, item) =>
        count + (Number.isInteger(item.eventCount) ? item.eventCount : 0), 0),
      pullContainsTmuxHostRecord: tmuxHostPullHasRecord,
      pullContainsTmuxCredentialRecord: tmuxCredentialPullHasRecord,
      pullResponsePlaintextMarkersAbsent:
        tmuxHostPullPages.every((item) => item.responsePlaintextMarkersAbsent === true),
      pullApiChangesEventCount: tmuxHostApiPullEvents.filter((item) =>
        item.endpoint === 'changes' && item.status === 200).length,
      hostCardMatchCount: tmuxHostCardMatches,
      visibleHostCardMatchCount: tmuxHostCardVisibleCount,
      credentialCardMatchCount: tmuxHostCredentialCardCount,
      hostNameVisibleInSemantics: tmuxHostLabelVisible,
      hostsPageVisible: tmuxHostPageFlags.hostNavigation,
      savedHostsHeadingVisible: tmuxHostPageFlags.savedHostsHeading,
    }));
    const tmuxHostCardB = pageB.getByRole('group', {
      name: new RegExp(`^Host: ${escapeRegExp(HOST_TMUX_NAME)}; `),
    }).first();
    stage = 'Profile B wait for synchronized tmux Host card after force pull';
    try {
      await tmuxHostCardB.waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      stage = `Profile B synchronized tmux Host card unavailable (${JSON.stringify({
        pullHttpStatus: tmuxHostPullSummary?.httpStatus ?? null,
        pullContainsTmuxHostRecord: tmuxHostPullHasRecord,
        pullContainsTmuxCredentialRecord: tmuxCredentialPullHasRecord,
        pullResponsePlaintextMarkersAbsent:
          tmuxHostPullSummary?.responsePlaintextMarkersAbsent === true,
        hostCardMatchCount: tmuxHostCardMatches,
        visibleHostCardMatchCount: tmuxHostCardVisibleCount,
        hostNameVisibleInSemantics: tmuxHostLabelVisible,
        hostsPageVisible: tmuxHostPageFlags.hostNavigation,
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
      })})`;
      throw error;
    }
    stage = 'Profile B open synchronized tmux Host editor';
    await tmuxHostCardB.getByRole('button', { name: 'Edit host', exact: true }).click();
    stage = 'Profile B resolve synchronized tmux Credential reference';
    await waitForText(pageB, 'Edit host');
    const tmuxCredentialReferenceDeadline = Date.now() + 10000;
    let tmuxCredentialReferenceVisible = false;
    let tmuxCredentialUnavailableVisible = false;
    while (!tmuxCredentialReferenceVisible && !tmuxCredentialUnavailableVisible &&
        Date.now() < tmuxCredentialReferenceDeadline) {
      tmuxCredentialReferenceVisible = await visibleSemanticTextMatch(
        pageB, `Host override: ${TMUX_CREDENTIAL_NAME} · ${TMUX_SSH_USERNAME}`,
      );
      tmuxCredentialUnavailableVisible = await visibleSemanticTextMatch(
        pageB, 'Host override is unavailable.',
      );
      if (!tmuxCredentialReferenceVisible && !tmuxCredentialUnavailableVisible) {
        await pageB.waitForTimeout(100);
      }
    }
    const tmuxHostEditorDiagnostics = await pageB.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      };
      const visibleNodes = [...document.querySelectorAll('flt-semantics')].filter(visible);
      const roleCounts = {};
      for (const node of visibleNodes) {
        const role = node.getAttribute('role') || 'unlabeled';
        roleCounts[role] = (roleCounts[role] || 0) + 1;
      }
      const buttons = visibleNodes.filter((node) => node.getAttribute('role') === 'button');
      const labels = buttons.map((node) =>
        (node.getAttribute('aria-label') || node.innerText || '').trim());
      return {
        visibleRoleCounts: roleCounts,
        safeButtonNameCounts: {
          cancel: labels.filter((label) => label === 'Cancel').length,
          saveEncryptedHost: labels.filter((label) => label === 'Save encrypted host').length,
          editHost: labels.filter((label) => label === 'Edit host').length,
          addHost: labels.filter((label) => label === 'Add host').length,
          credentialActions: labels.filter((label) => /credential/i.test(label)).length,
          other: labels.filter((label) => ![
            'Cancel', 'Save encrypted host', 'Edit host', 'Add host',
          ].includes(label) && !/credential/i.test(label)).length,
        },
        visibleTextFieldCount: visibleNodes.filter((node) =>
          node.getAttribute('role') === 'textbox').length,
      };
    }).catch(() => ({ diagnosticsUnavailable: true }));
    console.log('WEB-WORKSPACE-TMUX-HOST-REFERENCE-CHECKPOINT', JSON.stringify({
      hostCardVisible: true,
      credentialReferenceResolved: tmuxCredentialReferenceVisible,
      credentialUnavailableVisible: tmuxCredentialUnavailableVisible,
      expectedHostRecordObservedOnProfileB: tmuxHostPullHasRecord,
      expectedCredentialRecordObservedOnProfileB: tmuxCredentialPullHasRecord,
      hostCardMatchCount: tmuxHostCardMatches,
      credentialCardMatchCount: tmuxHostCredentialCardCount,
      ...tmuxHostEditorDiagnostics,
      hostApiChangesResponseCount: tmuxHostApiPullEvents.filter((item) =>
        item.endpoint === 'changes' && item.status === 200).length,
    }));
    if (!tmuxCredentialReferenceVisible) {
      stage = `Profile B tmux Credential reference unresolved (${JSON.stringify({
        credentialUnavailableVisible: tmuxCredentialUnavailableVisible,
        expectedHostRecordObservedOnProfileB: tmuxHostPullHasRecord,
        expectedCredentialRecordObservedOnProfileB: tmuxCredentialPullHasRecord,
        hostCardMatchCount: tmuxHostCardMatches,
        credentialCardMatchCount: tmuxHostCredentialCardCount,
        safeButtonNameCounts: tmuxHostEditorDiagnostics.safeButtonNameCounts || null,
        visibleRoleCounts: tmuxHostEditorDiagnostics.visibleRoleCounts || null,
      })})`;
      throw new Error('Profile B did not resolve its synchronized tmux Credential');
    }
    stage = 'Profile B close synchronized tmux Host editor';
    try {
      await click(pageB, 'Cancel');
    } catch (error) {
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
      stage = `Profile B close synchronized tmux Host editor (${errorClass}; ${JSON.stringify({
        credentialReferenceResolved: tmuxCredentialReferenceVisible,
        safeButtonNameCounts: tmuxHostEditorDiagnostics.safeButtonNameCounts || null,
        visibleRoleCounts: tmuxHostEditorDiagnostics.visibleRoleCounts || null,
      })})`;
      throw error;
    }

    const tmuxAHostConnectBaseline = {
      tickets: relayAttempts.A.length,
      webSockets: relayWebSockets.A,
      closes: relayWebSocketCloses.A,
      activeWebSockets: activeRelayWebSockets.A.size,
      ssh: tmuxSshFixture.server.summary(),
    };
    stage = 'Profile A explicitly Connect to the tmux Host for first-use approval';
    await openHostTab(pageA, HOST_TMUX_NAME);
    const tmuxAHostTicket = await waitForCaptured(() => {
      const ticket = relayAttempts.A[tmuxAHostConnectBaseline.tickets];
      return ticket?.status !== null && ticket ? ticket : null;
    }, 'Profile A first tmux Host Relay ticket');
    assertThat(tmuxAHostTicket.status === 200 &&
      tmuxAHostTicket.targetHost === splitTargetAddress &&
      tmuxAHostTicket.targetPort === tmuxFixturePort,
    'Profile A first tmux Host Connect used the wrong target');
    const tmuxAHostFirstAttemptSsh = await waitForCaptured(() => {
      const summary = tmuxSshFixture.server.summary();
      return summary.clientBannerReceived >=
          tmuxAHostConnectBaseline.ssh.clientBannerReceived + 1 &&
        summary.keyExchangeStarted >=
          tmuxAHostConnectBaseline.ssh.keyExchangeStarted + 1
        ? summary : null;
    }, 'Profile A untrusted tmux SSH handshake before TOFU approval');
    assertThat(tmuxAHostFirstAttemptSsh.passwordAccepted ===
        tmuxAHostConnectBaseline.ssh.passwordAccepted &&
      tmuxAHostFirstAttemptSsh.shellSessions ===
        tmuxAHostConnectBaseline.ssh.shellSessions,
    'Profile A untrusted SSH handshake authenticated before host-key approval');
    stage = 'Profile A approve the exact first-use tmux SSH host key';
    const tmuxAHostTrust = await acceptFirstUseSshHostKey(
      pageA, HOST_TMUX_NAME, tmuxSshFixture.server.hostFingerprint,
    );
    const tmuxAHostAuthenticated = await waitForCaptured(() => {
      const summary = tmuxSshFixture.server.summary();
      return summary.passwordAccepted ===
          tmuxAHostConnectBaseline.ssh.passwordAccepted + 1 &&
        summary.shellSessions === tmuxAHostConnectBaseline.ssh.shellSessions + 1
        ? summary : null;
    }, 'Profile A first tmux Host password authentication and shell');
    const tmuxAHostTickets = relayAttempts.A.slice(
      tmuxAHostConnectBaseline.tickets,
    );
    const tmuxAHostRetryTicket = await waitForCaptured(() =>
      tmuxAHostTickets.length === 2 && tmuxAHostTickets[1].status !== null
        ? tmuxAHostTickets[1] : null,
    'Profile A post-approval tmux Host Relay ticket');
    await waitForCaptured(() =>
      activeRelayWebSockets.A.size ===
        tmuxAHostConnectBaseline.activeWebSockets + 1 &&
      relayWebSockets.A === tmuxAHostConnectBaseline.webSockets + 2 &&
      relayWebSocketCloses.A === tmuxAHostConnectBaseline.closes + 1 &&
      tmuxAHostTickets.length === 2 &&
      tmuxAHostTickets.every((ticket) => ticket.status !== null),
    'Profile A first tmux Host Relay WebSocket');
    assertThat(tmuxAHostTrust.fingerprintMatchesFixture &&
      tmuxAHostAuthenticated.keyExchangeStarted >
        tmuxAHostConnectBaseline.ssh.keyExchangeStarted &&
      tmuxAHostAuthenticated.passwordAccepted ===
        tmuxAHostConnectBaseline.ssh.passwordAccepted + 1 &&
      tmuxAHostAuthenticated.shellSessions ===
        tmuxAHostConnectBaseline.ssh.shellSessions + 1 &&
      tmuxAHostTickets.length === 2 &&
      tmuxAHostTickets.every((ticket) => ticket.status === 200 &&
        ticket.targetHost === splitTargetAddress &&
        ticket.targetPort === tmuxFixturePort) &&
      tmuxAHostRetryTicket.status === 200 &&
      tmuxAHostRetryTicket.targetHost === splitTargetAddress &&
      tmuxAHostRetryTicket.targetPort === tmuxFixturePort,
    'Profile A first tmux Host connection did not authenticate against the exact fixture');
    const tmuxBeforeStartPreflight = tmuxSshFixture.tmuxSnapshot();
    assertThat(tmuxBeforeStartPreflight.sessionCount === 0 &&
      tmuxBeforeStartPreflight.clientCount === 0,
    'ordinary Profile A Connect created or attached a tmux session');
    console.log('WEB-WORKSPACE-TMUX-PROFILE-A-TOFU-CHECKPOINT', JSON.stringify({
      fingerprintMatchesFixture: tmuxAHostTrust.fingerprintMatchesFixture,
      relayTicketCount: tmuxAHostTickets.length,
      bothRelayTargetsMatchFixture: tmuxAHostTickets.every((ticket) =>
        ticket.status === 200 && ticket.targetHost === splitTargetAddress &&
        ticket.targetPort === tmuxFixturePort),
      firstAttemptPasswordAcceptedDelta:
        tmuxAHostFirstAttemptSsh.passwordAccepted -
          tmuxAHostConnectBaseline.ssh.passwordAccepted,
      firstAttemptShellSessionDelta: tmuxAHostFirstAttemptSsh.shellSessions -
        tmuxAHostConnectBaseline.ssh.shellSessions,
      sshPasswordAcceptedDelta: tmuxAHostAuthenticated.passwordAccepted -
        tmuxAHostConnectBaseline.ssh.passwordAccepted,
      sshShellSessionDelta: tmuxAHostAuthenticated.shellSessions -
        tmuxAHostConnectBaseline.ssh.shellSessions,
      tmuxSessionCountBeforeStart: tmuxBeforeStartPreflight.sessionCount,
      tmuxClientCountBeforeStart: tmuxBeforeStartPreflight.clientCount,
    }));
    await syncNow(pageA, 'Profile A tmux Host key trust approval sync');

    stage = 'Profile A capture tmux tab before Terminal navigation';
    const tmuxTabBeforeTerminalNavigation =
      await workspaceTerminalTabDiagnosticSnapshot(pageA, HOST_TMUX_NAME);
    stage = 'Profile A explicitly navigate to Terminal before tab isolation';
    await click(pageA, 'Terminal');
    const tmuxTabAfterTerminalNavigation =
      await workspaceTerminalTabDiagnosticSnapshot(pageA, HOST_TMUX_NAME);
    console.log('WEB-WORKSPACE-TMUX-TERMINAL-NAV-CHECKPOINT', JSON.stringify({
      beforeTerminalNavigation: tmuxTabBeforeTerminalNavigation,
      afterTerminalNavigation: tmuxTabAfterTerminalNavigation,
    }));
    if (tmuxTabBeforeTerminalNavigation.expectedHostTabMatchCount !== 1 ||
        tmuxTabBeforeTerminalNavigation.expectedHostTabConnectedCount !== 1 ||
        tmuxTabBeforeTerminalNavigation.matchingRuntimeCount !== 1) {
      stage = `Profile A tmux Host tab/runtime missing before Terminal navigation (${JSON.stringify(
        tmuxTabBeforeTerminalNavigation,
      )})`;
      throw new Error('openHostTab did not produce exactly one tmux Host terminal tab/runtime');
    }
    if (!tmuxTabAfterTerminalNavigation.terminalTitleVisible ||
        tmuxTabAfterTerminalNavigation.expectedHostTabMatchCount !==
          tmuxTabBeforeTerminalNavigation.expectedHostTabMatchCount ||
        tmuxTabAfterTerminalNavigation.expectedHostTabConnectedCount !== 1 ||
        tmuxTabAfterTerminalNavigation.matchingRuntimeCount !==
          tmuxTabBeforeTerminalNavigation.matchingRuntimeCount) {
      stage = `Profile A Terminal navigation changed tmux tab/runtime presence (${JSON.stringify({
        beforeTerminalNavigation: tmuxTabBeforeTerminalNavigation,
        afterTerminalNavigation: tmuxTabAfterTerminalNavigation,
      })})`;
      throw new Error('Terminal navigation changed the tmux Host tab/runtime state');
    }
    await closeOtherTerminalTabs(pageA, HOST_TMUX_NAME);
    await click(pageA, 'Workspaces');
    await waitForVisibleSemanticText(pageA, 'Saved workspaces',
      'Profile A Workspaces page for tmux save');
    const tmuxWorkspaceVaultBeforeSave = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(tmuxWorkspaceVaultBeforeSave,
      'tmux Workspace fixture did not find the active Vault before save');
    const tmuxWorkspacePreviewBaseline = await visibleWorkspacePreviewCardCount(pageA);
    const tmuxCreatePushBaseline = workspaceSplitPushes.length;
    const tmuxCreateResponseBaseline = workspaceSplitPushResponses.length;
    const tmuxCreateApiBaseline = vaultSyncApiEvents.A.length;
    const tmuxCreatePrivacyBaseline = apiPrivacyChecks.length;
    captureWorkspaceSplit = true;
    const tmuxWorkspaceSaveFailureDiagnostic = async (phase, error) => {
      let ui = null;
      let currentVault = null;
      let diagnosticFailureClass = null;
      try {
        ui = await encryptedWorkspaceSaveUiSnapshot(pageA, TMUX_WORKSPACE_NAME);
      } catch (diagnosticError) {
        diagnosticFailureClass = diagnosticError?.name || 'Error';
      }
      try {
        currentVault = serverVaultSnapshot(databasePath).vaults
          .find((item) => item.vaultId === vaultId) || null;
      } catch (diagnosticError) {
        diagnosticFailureClass = diagnosticFailureClass ||
          diagnosticError?.name || 'Error';
      }
      let commitDelta = null;
      if (currentVault) {
        try {
          commitDelta = serverCommitDelta(databasePath, vaultId,
            tmuxWorkspaceVaultBeforeSave.commitSeq, currentVault.commitSeq);
        } catch (_) {
          commitDelta = null;
        }
      }
      const capturedPushes = workspaceSplitPushes.slice(tmuxCreatePushBaseline);
      const capturedResponses = workspaceSplitPushResponses
        .slice(tmuxCreateResponseBaseline);
      const apiEvents = vaultSyncApiEvents.A.slice(tmuxCreateApiBaseline)
        .map((event) => ({
          endpoint: event.endpoint,
          method: event.method,
          status: event.status,
          failed: event.failed,
        }));
      const privacyEvents = apiPrivacyChecks.slice(tmuxCreatePrivacyBaseline);
      const screenshotPath = '/tmp/atermius_workspace_tmux_e2e_final12_save_failure.png';
      let screenshotSaved = false;
      try {
        await pageA.screenshot({ path: screenshotPath, fullPage: true, timeout: 5000 });
        screenshotSaved = true;
      } catch (_) {}
      console.error(`WEB-WORKSPACE-TMUX-WORKSPACE-SAVE-DIAGNOSTIC ${JSON.stringify({
        phase,
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        diagnosticFailureClass,
        ui,
        previewCardBaseline: tmuxWorkspacePreviewBaseline,
        createPushRequestDelta: capturedPushes.length,
        createPushOperationSummaries: capturedPushes.map((push) => ({
          operationCount: push.operations?.length || 0,
          operationKinds: (push.operations || []).map((operation) => operation.operation),
          recordIdPresent: (push.operations || []).every((operation) =>
            Boolean(operation.recordId)),
          revisionAndOpIdsPresent: (push.operations || []).every((operation) =>
            Boolean(operation.revisionId && operation.opId)),
          envelopeShapesValid: (push.operations || []).every((operation) =>
            operation.envelopeShapeValid === true),
          requestPlaintextMarkersAbsent: push.requestBodyPlaintextMarkersAbsent === true,
          workspaceHostReferenceMarkersAbsent:
            push.encryptedWorkspaceHostReferenceMarkersAbsent === true,
        })),
        createPushResponseDelta: capturedResponses.length,
        createPushResponseSummaries: capturedResponses.map((response) => ({
          status: response.status,
          resultCount: response.results?.length || 0,
          committedResultCount: (response.results || []).filter((result) =>
            Boolean(result.commitSeq) && !result.alreadyCommitted).length,
        })),
        syncApiEventDelta: apiEvents,
        privacyRequestResponseDelta: {
          eventCount: privacyEvents.length,
          allMarkersAbsent: privacyEvents.every((event) => event.markersAbsent),
        },
        vaultCommitSeqBefore: tmuxWorkspaceVaultBeforeSave.commitSeq,
        vaultCommitSeqAfter: currentVault?.commitSeq || null,
        serverCommitEventCount: commitDelta?.eventCount ?? null,
        serverCommitOperationKinds: commitDelta?.events?.map((event) =>
          event.operation) || [],
        serverCommitContainsCapturedWorkspaceRecord: Boolean(
          encryptedWorkspacePrivacyRecordId && commitDelta?.events?.some((event) =>
            event.recordId === encryptedWorkspacePrivacyRecordId)),
        screenshotSaved,
        screenshotPath: screenshotSaved ? screenshotPath : null,
      })}`);
    };
    stage = 'Profile A save the one-pane tmux Workspace';
    await click(pageA, 'Save current tabs');
    await fill(pageA, 'Workspace name', TMUX_WORKSPACE_NAME);
    await click(pageA, 'Save');
    stage = 'Profile A verify saved tmux Workspace card after save dialog closes';
    const tmuxSaveUiDeadline = Date.now() + 20000;
    let tmuxWorkspaceSavedUi = null;
    while (Date.now() < tmuxSaveUiDeadline) {
      tmuxWorkspaceSavedUi = await encryptedWorkspaceSaveUiSnapshot(
        pageA, TMUX_WORKSPACE_NAME);
      if (!tmuxWorkspaceSavedUi.workspaceDialogOpen &&
          !tmuxWorkspaceSavedUi.nameInputPresent &&
          !tmuxWorkspaceSavedUi.nameTextboxPresent &&
          tmuxWorkspaceSavedUi.savedWorkspacesHeadingVisible &&
          tmuxWorkspaceSavedUi.nameSemanticContainsExpected &&
          tmuxWorkspaceSavedUi.visibleWorkspacePreviewCardCount >=
            tmuxWorkspacePreviewBaseline + 1) {
        break;
      }
      await pageA.waitForTimeout(100);
    }
    console.log(`WEB-WORKSPACE-TMUX-WORKSPACE-SAVED-CARD-CHECKPOINT ${JSON.stringify({
      ...tmuxWorkspaceSavedUi,
      previewCardBaseline: tmuxWorkspacePreviewBaseline,
      savedCardAppeared: Boolean(tmuxWorkspaceSavedUi &&
        !tmuxWorkspaceSavedUi.workspaceDialogOpen &&
        !tmuxWorkspaceSavedUi.nameInputPresent &&
        !tmuxWorkspaceSavedUi.nameTextboxPresent &&
        tmuxWorkspaceSavedUi.savedWorkspacesHeadingVisible &&
        tmuxWorkspaceSavedUi.nameSemanticContainsExpected &&
        tmuxWorkspaceSavedUi.visibleWorkspacePreviewCardCount >=
          tmuxWorkspacePreviewBaseline + 1),
    })}`);
    if (!tmuxWorkspaceSavedUi || tmuxWorkspaceSavedUi.workspaceDialogOpen ||
        tmuxWorkspaceSavedUi.nameInputPresent ||
        tmuxWorkspaceSavedUi.nameTextboxPresent ||
        !tmuxWorkspaceSavedUi.savedWorkspacesHeadingVisible ||
        !tmuxWorkspaceSavedUi.nameSemanticContainsExpected ||
        tmuxWorkspaceSavedUi.visibleWorkspacePreviewCardCount <
          tmuxWorkspacePreviewBaseline + 1) {
      const error = new Error('tmux Workspace save dialog did not resolve to a new saved card');
      await tmuxWorkspaceSaveFailureDiagnostic('saved-card-verification', error);
      stage = 'Profile A tmux Workspace save failed before sync';
      throw error;
    }
    try {
      stage = 'Profile A explicit tmux Workspace encrypted create sync pass';
      await syncNow(pageA, 'tmux Workspace encrypted create');
    } catch (error) {
      await tmuxWorkspaceSaveFailureDiagnostic('sync-pass', error);
      stage = 'Profile A tmux Workspace encrypted sync failed';
      throw error;
    }
    console.log(`WEB-WORKSPACE-TMUX-WORKSPACE-SYNC-CHECKPOINT ${JSON.stringify({
      ui: await encryptedWorkspaceSaveUiSnapshot(pageA, TMUX_WORKSPACE_NAME),
      syncApiEventDelta: vaultSyncApiEvents.A.slice(tmuxCreateApiBaseline).map((event) => ({
        endpoint: event.endpoint,
        method: event.method,
        status: event.status,
        failed: event.failed,
      })),
      pushRequestDelta: workspaceSplitPushes.length - tmuxCreatePushBaseline,
      pushResponseDelta: workspaceSplitPushResponses.length - tmuxCreateResponseBaseline,
    })}`);
    const tmuxCreateCaptureProbe = workspaceSplitPushes.slice(tmuxCreatePushBaseline)
      .flatMap((push) => push.operations || []);
    const tmuxCreateResponseProbe = workspaceSplitPushResponses
      .slice(tmuxCreateResponseBaseline);
    console.log(`WEB-WORKSPACE-TMUX-WORKSPACE-CREATE-CAPTURE-PROBE ${JSON.stringify({
      operationCount: tmuxCreateCaptureProbe.length,
      operations: tmuxCreateCaptureProbe.map((operation) => ({
        kind: operation.operation,
        recordIdPresent: Boolean(operation.recordId),
        revisionIdPresent: Boolean(operation.revisionId),
        opIdPresent: Boolean(operation.opId),
        envelopeShapeValid: operation.envelopeShapeValid === true,
      })),
      pushes: workspaceSplitPushes.slice(tmuxCreatePushBaseline).map((push) => ({
        operationCount: Array.isArray(push.operations) ? push.operations.length : 0,
        requestPlaintextMarkersAbsent: push.requestBodyPlaintextMarkersAbsent === true,
        workspaceHostReferenceMarkersAbsent:
          push.encryptedWorkspaceHostReferenceMarkersAbsent === true,
      })),
      responseCount: tmuxCreateResponseProbe.length,
      responses: tmuxCreateResponseProbe.map((response) => ({
        status: response.status,
        resultCount: response.results?.length || 0,
        anyResultLinksToCapturedOperation: (response.results || []).some((result) =>
          tmuxCreateCaptureProbe.some((operation) => operation.opId === result.opId &&
            operation.revisionId === result.revisionId)),
        matchingCommittedResultCount: (response.results || []).filter((result) =>
          response.status === 200 && tmuxCreateCaptureProbe.some((operation) =>
            result.opId === operation.opId && result.revisionId === operation.revisionId &&
            result.commitSeq && !result.alreadyCommitted)).length,
        committedResultCount: (response.results || []).filter((result) =>
          Boolean(result.commitSeq) && !result.alreadyCommitted).length,
      })),
    })}`);
    stage = 'Profile A capture tmux Workspace encrypted create envelope';
    let tmuxCreateOperation;
    try {
      tmuxCreateOperation = await waitForCaptured(() =>
        workspaceSplitPushes.slice(tmuxCreatePushBaseline)
          .flatMap((push) => push.operations)
          .find((operation) => operation.operation === 'create' &&
            operation.recordId && operation.revisionId && operation.opId),
      'Profile A tmux Workspace create envelope');
    } catch (error) {
      try {
        await tmuxWorkspaceSaveFailureDiagnostic('create-envelope-capture', error);
      } catch (diagnosticError) {
        console.error(`WEB-WORKSPACE-TMUX-WORKSPACE-SAVE-DIAGNOSTIC-FAIL ${JSON.stringify({
          phase: 'create-envelope-capture',
          errorClass: diagnosticError?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        })}`);
      }
      stage = `Profile A tmux Workspace create envelope capture failed (${error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error'})`;
      throw error;
    }
    const tmuxWorkspaceRecordId = tmuxCreateOperation.recordId;
    stage = 'Profile A associate tmux Workspace create envelope with push request';
    const tmuxCreatePushMatches = workspaceSplitPushes.slice(tmuxCreatePushBaseline)
      .filter((push) => Array.isArray(push.operations) &&
        push.operations.includes(tmuxCreateOperation));
    assertThat(tmuxCreatePushMatches.length === 1,
      'tmux Workspace create envelope did not map to exactly one push request');
    const tmuxCreatePush = tmuxCreatePushMatches[0];
    stage = 'Profile A capture tmux Workspace encrypted create commit receipt';
    let tmuxCreateReceipt;
    try {
      tmuxCreateReceipt = await waitForCaptured(() =>
        workspaceSplitPushResponses.slice(tmuxCreateResponseBaseline)
          .find((response) => response.status === 200 &&
            response.results.some((result) => result.opId === tmuxCreateOperation.opId &&
              result.revisionId === tmuxCreateOperation.revisionId &&
              result.commitSeq && !result.alreadyCommitted)),
      'Profile A tmux Workspace create receipt');
    } catch (error) {
      try {
        await tmuxWorkspaceSaveFailureDiagnostic('create-receipt-capture', error);
      } catch (diagnosticError) {
        console.error(`WEB-WORKSPACE-TMUX-WORKSPACE-SAVE-DIAGNOSTIC-FAIL ${JSON.stringify({
          phase: 'create-receipt-capture',
          errorClass: diagnosticError?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        })}`);
      }
      stage = `Profile A tmux Workspace create receipt capture failed (${error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error'})`;
      throw error;
    }
    stage = 'Profile A read tmux Workspace create commit from Vault';
    const tmuxWorkspaceCreateVaultAfter = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    assertThat(tmuxWorkspaceCreateVaultAfter,
      'tmux Workspace create receipt had no active server Vault');
    stage = 'Profile A verify tmux Workspace single create commit event';
    const tmuxWorkspaceCreateCommit = serverCommitDelta(
      databasePath,
      vaultId,
      tmuxWorkspaceVaultBeforeSave.commitSeq,
      tmuxWorkspaceCreateVaultAfter.commitSeq,
    );
    console.log(`WEB-WORKSPACE-TMUX-WORKSPACE-COMMIT-CHECKPOINT ${JSON.stringify({
      commitSeqBefore: tmuxWorkspaceVaultBeforeSave.commitSeq,
      commitSeqAfter: tmuxWorkspaceCreateVaultAfter.commitSeq,
      eventCount: tmuxWorkspaceCreateCommit.eventCount,
      distinctCommitCount: tmuxWorkspaceCreateCommit.distinctCommitCount,
      operationKinds: tmuxWorkspaceCreateCommit.events.map((event) => event.operation),
      eventMatchesCapturedWorkspaceId: tmuxWorkspaceCreateCommit.events.some((event) =>
        event.recordId === tmuxWorkspaceRecordId),
      receiptResults: tmuxCreateReceipt.results.length,
      receiptLinksToCapturedOperation: tmuxCreateReceipt.results.some((result) =>
        result.opId === tmuxCreateOperation.opId &&
        result.revisionId === tmuxCreateOperation.revisionId && result.commitSeq),
    })}`);
    stage = 'Profile A inspect tmux Workspace encrypted record and receipt state';
    const tmuxWorkspaceCreateState = serverWorkspaceRecordSnapshot(
      databasePath,
      vaultId,
      tmuxWorkspaceRecordId,
      PRIVACY_MARKERS,
    );
    const tmuxCreateValidation = {
      onePushRequest: workspaceSplitPushes.length === tmuxCreatePushBaseline + 1,
      oneOperationInPush: Array.isArray(tmuxCreatePush.operations) &&
        tmuxCreatePush.operations.length === 1,
      requestPlaintextMarkersAbsent:
        tmuxCreatePush.requestBodyPlaintextMarkersAbsent === true,
      envelopeShapeValid: tmuxCreateOperation.envelopeShapeValid === true,
      workspaceHostReferenceMarkersAbsent:
        tmuxCreatePush.encryptedWorkspaceHostReferenceMarkersAbsent === true,
      onePushResponseResult: tmuxCreateReceipt.results.length === 1,
      oneCommitEvent: tmuxWorkspaceCreateCommit.eventCount === 1,
      eventMatchesCapturedWorkspaceId:
        tmuxWorkspaceCreateCommit.events[0]?.recordId === tmuxWorkspaceRecordId,
      oneEncryptedVersion: tmuxWorkspaceCreateState.versions.length === 1,
      storedEnvelopeMarkersAbsent:
        tmuxWorkspaceCreateState.versions[0]?.markersAbsent === true,
      storedEnvelopeShapeValid:
        tmuxWorkspaceCreateState.versions[0]?.validEnvelope === true,
      oneStoredOperationReceipt: tmuxWorkspaceCreateState.receipts.length === 1,
      storedReceiptLinksToCapturedOperation:
        tmuxWorkspaceCreateState.receipts[0]?.opId === tmuxCreateOperation.opId &&
        tmuxWorkspaceCreateState.receipts[0]?.recordId === tmuxWorkspaceRecordId &&
        tmuxWorkspaceCreateState.receipts[0]?.revisionId === tmuxCreateOperation.revisionId,
    };
    console.log(`WEB-WORKSPACE-TMUX-WORKSPACE-VALIDATION ${JSON.stringify(tmuxCreateValidation)}`);
    stage = 'Profile A assert tmux Workspace single encrypted create';
    assertThat(Object.values(tmuxCreateValidation).every(Boolean),
      'tmux Workspace did not sync as one plaintext-free encrypted create');

    stage = 'Profile A inspect Terminal navigation target before preflight cleanup';
    const tmuxTerminalNavTarget = await workspaceNavigationButtonSnapshot(
      pageA, 'Terminal');
    const tmuxTerminalBeforeNav =
      await workspaceTerminalTabDiagnosticSnapshot(pageA, HOST_TMUX_NAME);
    console.log(`WEB-WORKSPACE-TMUX-PREFLIGHT-NAV-BEFORE ${JSON.stringify({
      navigationTarget: tmuxTerminalNavTarget,
      terminalState: {
        terminalTitleVisible: tmuxTerminalBeforeNav.terminalTitleVisible,
        workspacesHeadingVisible: tmuxTerminalBeforeNav.workspacesHeadingVisible,
        visibleTerminalTabCount: tmuxTerminalBeforeNav.visibleTerminalTabCount,
        expectedHostTabMatchCount: tmuxTerminalBeforeNav.expectedHostTabMatchCount,
        expectedHostTabConnectedCount:
          tmuxTerminalBeforeNav.expectedHostTabConnectedCount,
        matchingRuntimeCount: tmuxTerminalBeforeNav.matchingRuntimeCount,
      },
      sshdOpenConnections: tmuxSshFixture.server.summary().tcpConnectionsOpen,
      relayActiveWebSocketCount: activeRelayWebSockets.A.size,
    })}`);
    stage = 'Profile A validate unique visible Terminal navigation target';
    assertThat(tmuxTerminalNavTarget.visibleLocatorCount === 1,
      'Terminal navigation target was not uniquely visible before preflight cleanup');
    stage = 'Profile A click Terminal navigation target for preflight cleanup';
    const tmuxTerminalNavLocator = pageA.getByRole('button', {
      name: 'Terminal', exact: true,
    });
    let tmuxTerminalNavVisibleIndex = -1;
    for (let index = 0; index < tmuxTerminalNavTarget.locatorMatches.length; index += 1) {
      if (tmuxTerminalNavTarget.locatorMatches[index].visible) {
        tmuxTerminalNavVisibleIndex = index;
        break;
      }
    }
    await tmuxTerminalNavLocator.nth(tmuxTerminalNavVisibleIndex)
      .click({ timeout: 5000 });
    stage = 'Profile A wait for connected tmux terminal after navigation';
    const tmuxTerminalNavDeadline = Date.now() + 15000;
    let tmuxAConnectedPreflightTab = null;
    while (Date.now() < tmuxTerminalNavDeadline) {
      const current = await workspaceTerminalTabDiagnosticSnapshot(
        pageA, HOST_TMUX_NAME);
      if (current.terminalTitleVisible &&
          current.expectedHostTabMatchCount === 1 &&
          current.expectedHostTabConnectedCount === 1 &&
          current.matchingRuntimeCount === 1) {
        tmuxAConnectedPreflightTab = current;
        break;
      }
      tmuxAConnectedPreflightTab = current;
      await pageA.waitForTimeout(150);
    }
    const tmuxTerminalNavAfter =
      await workspaceNavigationButtonSnapshot(pageA, 'Terminal');
    const tmuxTerminalNavScreenshotPath =
      '/tmp/atermius_workspace_tmux_e2e_final15_preflight_navigation_failure.png';
    let tmuxTerminalNavScreenshotSaved = false;
    if (!(tmuxAConnectedPreflightTab?.terminalTitleVisible &&
        tmuxAConnectedPreflightTab.expectedHostTabMatchCount === 1 &&
        tmuxAConnectedPreflightTab.expectedHostTabConnectedCount === 1 &&
        tmuxAConnectedPreflightTab.matchingRuntimeCount === 1)) {
      try {
        await pageA.screenshot({
          path: tmuxTerminalNavScreenshotPath, fullPage: true, timeout: 5000,
        });
        tmuxTerminalNavScreenshotSaved = true;
      } catch (_) {}
    }
    console.log(`WEB-WORKSPACE-TMUX-PREFLIGHT-NAV-AFTER ${JSON.stringify({
      terminalState: tmuxAConnectedPreflightTab,
      navigationTarget: tmuxTerminalNavAfter,
      sshdOpenConnections: tmuxSshFixture.server.summary().tcpConnectionsOpen,
      relayActiveWebSocketCount: activeRelayWebSockets.A.size,
      screenshotSaved: tmuxTerminalNavScreenshotSaved,
      screenshotPath: tmuxTerminalNavScreenshotSaved
        ? tmuxTerminalNavScreenshotPath : null,
    })}`);
    stage = `Profile A assert connected preflight tab is available (${JSON.stringify({
      terminalTitleVisible: tmuxAConnectedPreflightTab?.terminalTitleVisible === true,
      visibleTerminalTabCount:
        tmuxAConnectedPreflightTab?.visibleTerminalTabCount ?? 0,
      expectedHostTabMatchCount:
        tmuxAConnectedPreflightTab?.expectedHostTabMatchCount ?? 0,
      expectedHostTabConnectedCount:
        tmuxAConnectedPreflightTab?.expectedHostTabConnectedCount ?? 0,
      matchingRuntimeCount: tmuxAConnectedPreflightTab?.matchingRuntimeCount ?? 0,
    })})`;
    assertThat(tmuxAConnectedPreflightTab?.terminalTitleVisible === true &&
      tmuxAConnectedPreflightTab.expectedHostTabMatchCount === 1 &&
      tmuxAConnectedPreflightTab.expectedHostTabConnectedCount === 1 &&
      tmuxAConnectedPreflightTab.matchingRuntimeCount === 1,
    'Profile A preflight connection was unavailable before cleanup');
    const tmuxPreflightCloseName = `Close ${HOST_TMUX_NAME}`;
    const tmuxPreflightRoleClose = pageA.getByRole('button', {
      name: tmuxPreflightCloseName, exact: true,
    });
    const tmuxPreflightRoleCloseCount = await tmuxPreflightRoleClose.count()
      .catch(() => 0);
    const tmuxPreflightAriaClose = pageA.locator(
      `flt-semantics[role="button"][aria-label=${JSON.stringify(tmuxPreflightCloseName)}]`,
    );
    const tmuxPreflightAriaCloseCount = await tmuxPreflightAriaClose.count()
      .catch(() => 0);
    const tmuxPreflightInnerTextClose = pageA.locator('flt-semantics[role="button"]')
      .filter({ hasText: new RegExp(`^${escapeRegExp(tmuxPreflightCloseName)}$`) });
    const tmuxPreflightInnerTextCloseCount = await tmuxPreflightInnerTextClose.count()
      .catch(() => 0);
    const tmuxPreflightCloseDom = await pageA.evaluate((expected) => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' &&
          style.display !== 'none';
      };
      const candidates = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .map((node) => {
          const ariaLabel = node.getAttribute('aria-label') || '';
          const innerText = (node.innerText || '').trim();
          const textContent = (node.textContent || '').trim();
          const semanticName = ariaLabel || innerText || textContent;
          if (semanticName !== expected) return null;
          let ariaHiddenAncestor = false;
          let inertAncestor = false;
          for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
            if ((ancestor.getAttribute('aria-hidden') || '').toLowerCase() === 'true') {
              ariaHiddenAncestor = true;
            }
            if (ancestor.hasAttribute('inert')) inertAncestor = true;
          }
          const rect = node.getBoundingClientRect();
          return {
            role: node.getAttribute('role') || '',
            ariaLabelPresent: ariaLabel.length > 0,
            innerTextExact: innerText === expected,
            textContentExact: textContent === expected,
            semanticNameExact: semanticName === expected,
            visible: visible(node),
            ariaHiddenAncestor,
            inertAncestor,
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          };
        }).filter(Boolean);
      return candidates;
    }, tmuxPreflightCloseName).catch(() => []);
    console.log(`WEB-WORKSPACE-TMUX-PREFLIGHT-CLOSE-LOCATOR ${JSON.stringify({
      roleLocatorCount: tmuxPreflightRoleCloseCount,
      ariaLabelLocatorCount: tmuxPreflightAriaCloseCount,
      innerTextLocatorCount: tmuxPreflightInnerTextCloseCount,
      domCandidates: tmuxPreflightCloseDom,
    })}`);
    stage = 'Profile A validate unique visible tmux preflight Close control';
    if (tmuxPreflightRoleCloseCount > 0) {
      assertThat(tmuxPreflightRoleCloseCount === 1 &&
        await tmuxPreflightRoleClose.first().isVisible().catch(() => false),
      'tmux preflight role Close control was not unique and visible');
    } else if (tmuxPreflightAriaCloseCount > 0) {
      assertThat(tmuxPreflightAriaCloseCount === 1 &&
        await tmuxPreflightAriaClose.first().isVisible().catch(() => false) &&
        tmuxPreflightCloseDom.filter((node) => node.role === 'button' &&
          node.semanticNameExact && node.visible && node.width > 0 && node.height > 0 &&
          !node.ariaHiddenAncestor && !node.inertAncestor).length === 1,
      'tmux preflight aria-label Close fallback was not unique and visible');
    } else {
      assertThat(tmuxPreflightInnerTextCloseCount === 1 &&
        await tmuxPreflightInnerTextClose.first().isVisible().catch(() => false) &&
        tmuxPreflightCloseDom.filter((node) => node.role === 'button' &&
          node.innerTextExact && node.semanticNameExact && node.visible &&
          node.width > 0 && node.height > 0 && !node.ariaHiddenAncestor &&
          !node.inertAncestor).length === 1,
      'tmux preflight innerText Close fallback was not unique and visible');
    }
    stage = 'Profile A click exact tmux preflight Close control';
    try {
      if (tmuxPreflightRoleCloseCount > 0) {
        await tmuxPreflightRoleClose.first().click({ timeout: 5000 });
      } else if (tmuxPreflightAriaCloseCount > 0) {
        await tmuxPreflightAriaClose.first().click({ timeout: 5000 });
      } else {
        await tmuxPreflightInnerTextClose.first().click({ timeout: 5000 });
      }
    } catch (error) {
      const screenshotPath = '/tmp/atermius_workspace_tmux_e2e_final14_preflight_close_failure.png';
      let screenshotSaved = false;
      try {
        await pageA.screenshot({ path: screenshotPath, fullPage: true, timeout: 5000 });
        screenshotSaved = true;
      } catch (_) {}
      const postClickFailureSnapshot = await workspaceTerminalTabDiagnosticSnapshot(
        pageA, HOST_TMUX_NAME).catch(() => ({ snapshotAvailable: false }));
      console.error(`WEB-WORKSPACE-TMUX-PREFLIGHT-CLOSE-FAILURE ${JSON.stringify({
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        roleLocatorCount: tmuxPreflightRoleCloseCount,
        ariaLabelLocatorCount: tmuxPreflightAriaCloseCount,
        innerTextLocatorCount: tmuxPreflightInnerTextCloseCount,
        domCandidateCount: tmuxPreflightCloseDom.length,
        postClickFailureSnapshot,
        sshdOpenConnections: tmuxSshFixture.server.summary().tcpConnectionsOpen,
        relayActiveWebSocketCount: activeRelayWebSockets.A.size,
        screenshotSaved,
        screenshotPath: screenshotSaved ? screenshotPath : null,
      })}`);
      throw error;
    }
    stage = 'Profile A wait for tmux preflight SSH and Relay disconnect';
    const tmuxAAfterPreflightCloseDeadline = Date.now() + 15000;
    let tmuxAAfterPreflightClose = null;
    while (!tmuxAAfterPreflightClose &&
        Date.now() < tmuxAAfterPreflightCloseDeadline) {
      const ssh = tmuxSshFixture.server.summary();
      const runtime = await workspaceTerminalRuntimeSnapshot(pageA, [HOST_TMUX_NAME]);
      if (ssh.tcpConnectionsOpen ===
            tmuxAHostConnectBaseline.ssh.tcpConnectionsOpen &&
          runtime[0]?.count === 0 &&
          activeRelayWebSockets.A.size ===
            tmuxAHostConnectBaseline.activeWebSockets) {
        tmuxAAfterPreflightClose = { ssh, runtime };
        break;
      }
      await pageA.waitForTimeout(100);
    }
    const tmuxAAfterPreflightCloseObserved = tmuxAAfterPreflightClose || {
      ssh: tmuxSshFixture.server.summary(),
      runtime: await workspaceTerminalRuntimeSnapshot(pageA, [HOST_TMUX_NAME])
        .catch(() => [{ count: null }]),
    };
    console.log(`WEB-WORKSPACE-TMUX-PREFLIGHT-CLOSE-POLL ${JSON.stringify({
      closed: tmuxAAfterPreflightClose !== null,
      sshdConnectionsBefore: tmuxAHostConnectBaseline.ssh.tcpConnectionsOpen,
      sshdConnectionsAfter: tmuxAAfterPreflightCloseObserved.ssh.tcpConnectionsOpen,
      sshdOpenConnectionsAfter: tmuxAAfterPreflightCloseObserved.ssh.tcpConnectionsOpen,
      runtimeCountAfter: tmuxAAfterPreflightCloseObserved.runtime[0]?.count ?? null,
      activeRelayWebSocketsBefore: tmuxAHostConnectBaseline.activeWebSockets,
      activeRelayWebSocketsAfter: activeRelayWebSockets.A.size,
      relayTicketDelta: relayAttempts.A.length - tmuxAHostConnectBaseline.tickets,
      relayWebSocketDelta: relayWebSockets.A - tmuxAHostConnectBaseline.webSockets,
      relayCloseDelta: relayWebSocketCloses.A - tmuxAHostConnectBaseline.closes,
    })}`);
    stage = 'Profile A assert tmux preflight SSH and Relay closed';
    assertThat(tmuxAAfterPreflightClose !== null,
      'Profile A preflight SSH/Relay connection did not close cleanly');
    stage = 'Profile A assert tmux preflight ticket, WebSocket and SSH counters';
    assertThat(relayAttempts.A.length === tmuxAHostConnectBaseline.tickets + 2 &&
      relayWebSockets.A === tmuxAHostConnectBaseline.webSockets + 2 &&
      relayWebSocketCloses.A === tmuxAHostConnectBaseline.closes + 2 &&
      tmuxAAfterPreflightClose.ssh.tcpConnectionsOpen ===
        tmuxAHostConnectBaseline.ssh.tcpConnectionsOpen,
    'Profile A preflight connection did not close cleanly before Workspace Connect');
    console.log('WEB-WORKSPACE-TMUX-PREFLIGHT-CLEANUP-CHECKPOINT', JSON.stringify({
      workspaceRecordAlreadySaved: true,
      terminalRuntimeCountAfterClose:
        tmuxAAfterPreflightClose.runtime[0]?.count ?? 0,
      sshdOpenConnectionCountAfterClose:
        tmuxAAfterPreflightClose.ssh.tcpConnectionsOpen,
      sshdOpenConnectionCountBeforePreflight:
        tmuxAHostConnectBaseline.ssh.tcpConnectionsOpen,
      relayTicketDelta: relayAttempts.A.length - tmuxAHostConnectBaseline.tickets,
      relayWebSocketDelta: relayWebSockets.A - tmuxAHostConnectBaseline.webSockets,
      relayCloseDelta: relayWebSocketCloses.A - tmuxAHostConnectBaseline.closes,
    }));
    const knownWorkspaceNames = [
      WORKSPACE_NAME,
      WORKSPACE_BRANCH_B_COPY_NAME,
      SPLIT_WORKSPACE_NAME,
      NESTED_SPLIT_WORKSPACE_NAME,
      TMUX_WORKSPACE_NAME,
    ];
    const existingTmuxWorkspaceNames = knownWorkspaceNames.filter((name) =>
      name !== TMUX_WORKSPACE_NAME);

    stage = 'Profile A inspect Workspaces navigation after preflight cleanup';
    const tmuxWorkspacesNavBeforePreview =
      await workspaceNavigationButtonSnapshot(pageA, 'Workspaces');
    const tmuxTerminalStateBeforePreview =
      await workspaceTerminalTabDiagnosticSnapshot(pageA, HOST_TMUX_NAME);
    console.log('WEB-WORKSPACE-TMUX-PREVIEW-NAV-BEFORE', JSON.stringify({
      navigationTarget: tmuxWorkspacesNavBeforePreview,
      terminalTitleVisible: tmuxTerminalStateBeforePreview.terminalTitleVisible,
      workspacesHeadingVisible:
        tmuxTerminalStateBeforePreview.workspacesHeadingVisible,
      visibleTerminalTabCount:
        tmuxTerminalStateBeforePreview.visibleTerminalTabCount,
      expectedHostTabMatchCount:
        tmuxTerminalStateBeforePreview.expectedHostTabMatchCount,
      runtimeCount: tmuxTerminalStateBeforePreview.matchingRuntimeCount,
    }));
    if (!tmuxWorkspacesNavBeforePreview.workspacesHeadingVisible) {
      stage = 'Profile A validate unique visible Workspaces navigation target';
      assertThat(tmuxWorkspacesNavBeforePreview.visibleLocatorCount === 1,
        'Workspaces navigation target was not uniquely visible after preflight cleanup');
      stage = 'Profile A click Workspaces navigation after preflight cleanup';
      const tmuxWorkspacesNavLocator = pageA.getByRole('button', {
        name: 'Workspaces', exact: true,
      });
      let tmuxWorkspacesNavVisibleIndex = -1;
      for (let index = 0; index <
          tmuxWorkspacesNavBeforePreview.locatorMatches.length; index += 1) {
        if (tmuxWorkspacesNavBeforePreview.locatorMatches[index].visible) {
          tmuxWorkspacesNavVisibleIndex = index;
          break;
        }
      }
      await tmuxWorkspacesNavLocator.nth(tmuxWorkspacesNavVisibleIndex)
        .click({ timeout: 5000 });
    }
    stage = 'Profile A wait for Saved workspaces before tmux preview';
    await waitForVisibleSemanticText(pageA, 'Saved workspaces',
      'Profile A Workspaces page after preflight cleanup', 15000);
    stage = 'Profile A verify saved one-tab Workspace preview actions';
    const tmuxPreviewActionCountBeforeStage = await pageA.getByRole('button', {
      name: 'Preview disconnected layout', exact: true,
    }).count().catch(() => 0);
    const tmuxWorkspaceListSnapshot =
    await workspaceNavigationButtonSnapshot(pageA, 'Workspaces');
    console.log('WEB-WORKSPACE-TMUX-PREVIEW-CARDS-BEFORE', JSON.stringify({
      expectedPreviewActionCount: knownWorkspaceNames.length,
      previewActionCount: tmuxPreviewActionCountBeforeStage,
      workspacesHeadingVisible: tmuxWorkspaceListSnapshot.workspacesHeadingVisible,
      savedWorkspaceCardVisible: tmuxWorkspaceListSnapshot.savedWorkspaceCardVisible,
    }));
    const tmuxAWorkspacePreviewBaseline = {
      tickets: relayAttempts.A.length,
      webSockets: relayWebSockets.A,
      closes: relayWebSocketCloses.A,
      activeWebSockets: activeRelayWebSockets.A.size,
      ssh: tmuxSshFixture.server.summary(),
    };
    stage = 'Profile A preview the tmux Workspace without connecting';
    const tmuxConnectButtonsA = await stageSingleWorkspacePreview(
      pageA,
      TMUX_WORKSPACE_NAME,
      {
        existingWorkspaceNames: existingTmuxWorkspaceNames,
        hostName: HOST_TMUX_NAME,
        profile: 'A',
      },
    );
    const tmuxAAfterPreview = tmuxSshFixture.server.summary();
    const tmuxAAfterPreviewState = tmuxSshFixture.tmuxSnapshot();
    assertThat(relayAttempts.A.length === tmuxAWorkspacePreviewBaseline.tickets &&
      relayWebSockets.A === tmuxAWorkspacePreviewBaseline.webSockets &&
      relayWebSocketCloses.A === tmuxAWorkspacePreviewBaseline.closes &&
      activeRelayWebSockets.A.size ===
        tmuxAWorkspacePreviewBaseline.activeWebSockets &&
      tmuxAAfterPreview.tcpConnectionsAccepted ===
        tmuxAWorkspacePreviewBaseline.ssh.tcpConnectionsAccepted &&
      tmuxAAfterPreview.tcpConnectionsClosed ===
        tmuxAWorkspacePreviewBaseline.ssh.tcpConnectionsClosed &&
      tmuxAAfterPreview.keyExchangeStarted ===
        tmuxAWorkspacePreviewBaseline.ssh.keyExchangeStarted &&
      tmuxAAfterPreview.passwordAccepted ===
        tmuxAWorkspacePreviewBaseline.ssh.passwordAccepted &&
      tmuxAAfterPreviewState.sessionCount === 0 &&
      tmuxAAfterPreviewState.clientCount === 0,
    'Profile A Workspace preview created Relay, SSHD, or tmux activity');
    const tmuxAConnectBaseline = {
      tickets: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      webSockets: relayWebSockets.A,
      closes: relayWebSocketCloses.A,
      activeWebSockets: activeRelayWebSockets.A.size,
      syncApiEventsA: vaultSyncApiEvents.A.length,
      syncApiEventsB: vaultSyncApiEvents.B.length,
      startupDiagnosticsA: startupDiagnostics.A.length,
      startupDiagnosticsB: startupDiagnostics.B.length,
      ssh: tmuxSshFixture.server.summary(),
    };
    assertThat(tmuxSshFixture.tmuxSnapshot().sessionCount === 0 &&
      tmuxSshFixture.tmuxSnapshot().clientCount === 0,
    'previewing the new tmux Workspace unexpectedly started a remote session');
    const tmuxAWorkspaceConnectFailureDiagnostic = async (phase, error) => {
      const ssh = tmuxSshFixture.server.summary();
      const tickets = relayAttempts.A.slice(tmuxAConnectBaseline.tickets);
      const [runtime, terminalUi, browserUi] = await Promise.all([
        workspaceTerminalRuntimeSnapshot(pageA, [HOST_TMUX_NAME])
          .catch(() => [{ count: 0, connectingCount: 0, connectedCount: 0, failedCount: 0 }]),
        workspaceTerminalTabDiagnosticSnapshot(pageA, HOST_TMUX_NAME)
          .catch(() => ({ snapshotAvailable: false })),
        pageA.evaluate(() => {
          const visible = (node) => {
            const rect = node.getBoundingClientRect();
            const style = getComputedStyle(node);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none' &&
              Number(style.opacity || 1) > 0;
          };
          const text = [...document.querySelectorAll('flt-semantics')]
            .filter(visible)
            .map((node) => [node.getAttribute('aria-label') || '',
              node.innerText || '', node.textContent || ''].join(' '))
            .join(' ');
          return {
            terminalTitleVisible: text.includes('Terminal workspace'),
            trustPromptVisible: text.includes('Verify SSH host key'),
            trustActionVisible: text.includes('Trust after verification'),
            credentialPromptVisible:
              /select credential|choose credential|password required|password authentication/i.test(text),
            passwordInputCount:
              document.querySelectorAll('input[type="password"]').length,
            passwordFieldLabelVisible: /\bPassword\b/i.test(text),
            hostKeyChangeNoticeVisible: /host key.{0,30}(changed|conflict)/i.test(text),
            authenticationFailureVisible:
              /authentication failed|password rejected|credential unavailable/i.test(text),
            networkFailureVisible: /network error|connection failed|relay failed/i.test(text),
            visibleAlertCount: [...document.querySelectorAll('[role="alert"], [aria-live]')]
              .filter(visible).length,
          };
        }).catch(() => ({ snapshotAvailable: false })),
      ]);
      const screenshotPath =
        `/tmp/atermius_workspace_tmux_e2e_final21_workspace_connect_${phase}.png`;
      let screenshotSaved = false;
      try {
        await pageA.screenshot({ path: screenshotPath, fullPage: true, timeout: 5000 });
        screenshotSaved = true;
      } catch (_) {}
      console.error(`WEB-WORKSPACE-TMUX-WORKSPACE-CONNECT-FAILURE ${JSON.stringify({
        phase,
        errorClass: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        relay: {
          ticketCount: tickets.length,
          tickets: tickets.map((ticket) => ({
            status: ticket.status,
            exactFixtureTarget: ticket.targetHost === splitTargetAddress &&
              ticket.targetPort === tmuxFixturePort,
          })),
          webSocketDelta: relayWebSockets.A - tmuxAConnectBaseline.webSockets,
          activeWebSocketCount: activeRelayWebSockets.A.size,
          activeWebSocketDelta:
            activeRelayWebSockets.A.size - tmuxAConnectBaseline.activeWebSockets,
          closeDelta: relayWebSocketCloses.A - tmuxAConnectBaseline.closes,
        },
        ssh: {
          running: ssh.running,
          openConnections: ssh.tcpConnectionsOpen,
          tcpAcceptedDelta: ssh.tcpConnectionsAccepted -
            tmuxAConnectBaseline.ssh.tcpConnectionsAccepted,
          tcpClosedDelta: ssh.tcpConnectionsClosed -
            tmuxAConnectBaseline.ssh.tcpConnectionsClosed,
          serverBannerDelta: ssh.serverBannerEmitted -
            tmuxAConnectBaseline.ssh.serverBannerEmitted,
          clientBannerDelta: ssh.clientBannerReceived -
            tmuxAConnectBaseline.ssh.clientBannerReceived,
          keyExchangeDelta: ssh.keyExchangeStarted -
            tmuxAConnectBaseline.ssh.keyExchangeStarted,
          passwordAcceptedDelta: ssh.passwordAccepted -
            tmuxAConnectBaseline.ssh.passwordAccepted,
          passwordRejectedDelta: ssh.passwordRejected -
            tmuxAConnectBaseline.ssh.passwordRejected,
          shellSessionDelta: ssh.shellSessions -
            tmuxAConnectBaseline.ssh.shellSessions,
          connectionPhases: (ssh.connections || [])
            .slice(tmuxAConnectBaseline.ssh.connections?.length || 0)
            .map((connection) => ({
              accepted: connection.accepted,
              closed: connection.closed,
              passwordAccepted: connection.passwordAccepted,
              passwordRejected: connection.passwordRejected,
              shellSessions: connection.shellSessions,
            })),
        },
        runtime: runtime[0],
        terminalUi,
        browserUi,
        screenshotSaved,
        screenshotPath: screenshotSaved ? screenshotPath : null,
      })}`);
    };
    stage = 'Profile A explicitly Connect to the tmux Workspace pane';
    await tmuxConnectButtonsA.first().click();
    stage = 'Profile A wait for the first tmux Workspace Connect Relay ticket';
    let tmuxAFirstTicket;
    try {
      tmuxAFirstTicket = await waitForCaptured(() => {
        const ticket = relayAttempts.A[tmuxAConnectBaseline.tickets];
        return ticket && ticket.status !== null ? ticket : null;
      }, 'Profile A first explicit tmux Host Relay ticket');
    } catch (error) {
      await tmuxAWorkspaceConnectFailureDiagnostic('first_relay_ticket', error);
      stage = 'Profile A first Workspace Connect Relay ticket wait failed';
      throw error;
    }
    const tmuxAFirstTicketEvidence = {
      ticketCountDeltaA: relayAttempts.A.length - tmuxAConnectBaseline.tickets,
      ticketCountDeltaB: relayAttempts.B.length - tmuxAConnectBaseline.ticketsB,
      firstTicketStatus: tmuxAFirstTicket.status,
      firstTicketStatusCategory: tmuxAFirstTicket.status === 200
        ? 'success'
        : tmuxAFirstTicket.status >= 500
          ? 'relay-server-error'
          : tmuxAFirstTicket.status >= 400
            ? 'relay-client-error'
            : 'unknown',
      firstTicketHostExact: tmuxAFirstTicket.targetHost === splitTargetAddress,
      firstTicketHostLoopback: /^127\./.test(tmuxAFirstTicket.targetHost || ''),
      firstTicketHostIsPrivateFixture: tmuxAFirstTicket.targetHost === splitTargetAddress,
      firstTicketPortExact: tmuxAFirstTicket.targetPort === tmuxFixturePort,
      firstTicketPortIsAnyFixture: [
        ...sshFixturePorts,
        splitTargetPort,
        splitSecondTargetPort,
        splitThirdTargetPort,
        tmuxFixturePort,
      ].includes(tmuxAFirstTicket.targetPort),
      ticketsSinceProfileBaseline: relayAttempts.A
        .slice(tmuxAConnectBaseline.tickets)
        .map((ticket) => ({
          status: ticket.status,
          statusCategory: ticket.status === 200
            ? 'success'
            : ticket.status >= 500
              ? 'relay-server-error'
              : ticket.status >= 400
                ? 'relay-client-error'
                : 'unknown',
          exactTmuxFixtureTarget: ticket.targetHost === splitTargetAddress &&
            ticket.targetPort === tmuxFixturePort,
          hostIsLoopback: /^127\./.test(ticket.targetHost || ''),
          hostIsPrivateFixture: ticket.targetHost === splitTargetAddress,
          portIsTmuxFixture: ticket.targetPort === tmuxFixturePort,
          portIsAnyFixture: [
            ...sshFixturePorts,
            splitTargetPort,
            splitSecondTargetPort,
            splitThirdTargetPort,
            tmuxFixturePort,
          ].includes(ticket.targetPort),
        })),
      syncApiErrorsA: vaultSyncApiEvents.A
        .slice(tmuxAConnectBaseline.syncApiEventsA)
        .map((event) => ({
          endpoint: event.endpoint,
          method: event.method,
          status: event.status,
          failed: event.failed,
          errorCategory: event.status === null
            ? event.failed ? 'request-failed' : 'pending'
            : event.status >= 500
              ? 'server-error'
              : event.status >= 400
                ? 'client-error'
                : 'none',
        })),
      syncApiErrorsB: vaultSyncApiEvents.B
        .slice(tmuxAConnectBaseline.syncApiEventsB)
        .map((event) => ({
          endpoint: event.endpoint,
          method: event.method,
          status: event.status,
          failed: event.failed,
          errorCategory: event.status === null
            ? event.failed ? 'request-failed' : 'pending'
            : event.status >= 500
              ? 'server-error'
              : event.status >= 400
                ? 'client-error'
                : 'none',
        })),
      startupDiagnosticCategoriesA: startupDiagnostics.A
        .slice(tmuxAConnectBaseline.startupDiagnosticsA)
        .map((entry) => entry.category),
      startupDiagnosticCategoriesB: startupDiagnostics.B
        .slice(tmuxAConnectBaseline.startupDiagnosticsB)
        .map((entry) => entry.category),
    };
    console.log('WEB-WORKSPACE-TMUX-FIRST-RELAY-TICKET-CHECKPOINT',
      JSON.stringify(tmuxAFirstTicketEvidence));
    stage = 'Profile A verify first tmux Workspace Connect Relay ticket status';
    assertThat(tmuxAFirstTicket.status === 200,
      'Profile A first tmux pane Relay ticket did not return HTTP 200');
    stage = 'Profile A verify first tmux Workspace Connect Relay exact target';
    assertThat(tmuxAFirstTicketEvidence.firstTicketHostExact &&
      tmuxAFirstTicketEvidence.firstTicketPortExact,
    'Profile A first tmux pane Relay ticket targeted another Host or port');
    stage = 'Profile A verify first HostKey-only tmux SSH connection';
    let tmuxAHostKeyOnlyConnection;
    try {
      tmuxAHostKeyOnlyConnection = await waitForCaptured(() => {
        const connections = tmuxSshFixture.server.summary().connections || [];
        const attempts = connections.slice(tmuxAConnectBaseline.ssh.connections.length);
        return attempts[0]?.accepted && attempts[0]?.closed ? attempts[0] : null;
      }, 'Profile A closed tmux SSH HostKey-only connection');
    } catch (error) {
      await tmuxAWorkspaceConnectFailureDiagnostic('hostkey_only_connection', error);
      stage = 'Profile A HostKey-only tmux SSH connection wait failed';
      throw error;
    }
    assertThat(tmuxAHostKeyOnlyConnection.passwordAccepted === 0 &&
      tmuxAHostKeyOnlyConnection.passwordRejected === 0 &&
      tmuxAHostKeyOnlyConnection.shellSessions === 0,
    'Profile A first tmux SSH HostKey-only connection performed authentication or opened a shell');
    stage = 'Profile A wait for the second tmux Workspace Connect Relay ticket';
    let tmuxATickets;
    try {
      tmuxATickets = await waitForCaptured(() => {
        const tickets = relayAttempts.A.slice(tmuxAConnectBaseline.tickets);
        return tickets.length >= 2 && tickets.every((ticket) => ticket.status !== null)
          ? tickets : null;
      }, 'Profile A second explicit tmux Host Relay ticket');
    } catch (error) {
      await tmuxAWorkspaceConnectFailureDiagnostic('second_relay_ticket', error);
      stage = 'Profile A second Workspace Connect Relay ticket wait failed';
      throw error;
    }
    stage = 'Profile A verify both exact tmux Workspace Connect Relay targets';
    assertThat(tmuxATickets.length === 2 && tmuxATickets.every((ticket) =>
      ticket.status === 200 && ticket.targetHost === splitTargetAddress &&
      ticket.targetPort === tmuxFixturePort),
    'Profile A tmux pane did not use exactly two successful Relay tickets for the fixture Host');
    stage = 'Profile A wait for the second Workspace-owned tmux SSH password and shell';
    let tmuxAAuthenticated;
    try {
      tmuxAAuthenticated = await waitForCaptured(() => {
        const summary = tmuxSshFixture.server.summary();
        const connections = (summary.connections || [])
          .slice(tmuxAConnectBaseline.ssh.connections.length);
        return connections.length >= 2 &&
          summary.passwordAccepted === tmuxAConnectBaseline.ssh.passwordAccepted + 1 &&
          summary.shellSessions === tmuxAConnectBaseline.ssh.shellSessions + 1
          ? summary : null;
      }, 'Profile A tmux SSH password authentication and shell');
    } catch (error) {
      await tmuxAWorkspaceConnectFailureDiagnostic('ssh_auth', error);
      stage = 'Profile A Workspace-owned tmux SSH password/shell wait failed';
      throw error;
    }
    const tmuxAConnectionPhases = tmuxAAuthenticated.connections
      .slice(tmuxAConnectBaseline.ssh.connections.length);
    stage = 'Profile A wait for two tmux Workspace Relay WebSockets and one active socket';
    try {
      await waitForCaptured(() => activeRelayWebSockets.A.size ===
        tmuxAConnectBaseline.activeWebSockets + 1 &&
        relayWebSockets.A === tmuxAConnectBaseline.webSockets + 2 &&
        relayWebSocketCloses.A === tmuxAConnectBaseline.closes + 1 &&
        tmuxATickets.length === 2 &&
        tmuxATickets.every((ticket) => ticket.status !== null),
      'Profile A two tmux Relay WebSockets, one preflight close, and one active socket');
    } catch (error) {
      await tmuxAWorkspaceConnectFailureDiagnostic('relay_websocket', error);
      stage = 'Profile A tmux Workspace Relay WebSocket phase wait failed';
      throw error;
    }
    stage = 'Profile A validate the two-phase exact tmux SSH and Relay connection';
    assertThat(tmuxAAuthenticated.keyExchangeStarted >
        tmuxAConnectBaseline.ssh.keyExchangeStarted &&
      tmuxAAuthenticated.tcpConnectionsAccepted ===
        tmuxAConnectBaseline.ssh.tcpConnectionsAccepted + 2 &&
      tmuxAAuthenticated.tcpConnectionsClosed ===
        tmuxAConnectBaseline.ssh.tcpConnectionsClosed + 1 &&
      tmuxAAuthenticated.tcpConnectionsOpen ===
        tmuxAConnectBaseline.ssh.tcpConnectionsOpen + 1 &&
      tmuxAAuthenticated.serverBannerEmitted ===
        tmuxAConnectBaseline.ssh.serverBannerEmitted + 2 &&
      tmuxAAuthenticated.clientBannerReceived ===
        tmuxAConnectBaseline.ssh.clientBannerReceived + 2 &&
      tmuxAAuthenticated.passwordAccepted ===
        tmuxAConnectBaseline.ssh.passwordAccepted + 1 &&
      tmuxAAuthenticated.passwordRejected ===
        tmuxAConnectBaseline.ssh.passwordRejected &&
      tmuxAAuthenticated.shellSessions ===
        tmuxAConnectBaseline.ssh.shellSessions + 1 &&
      tmuxAConnectionPhases.length === 2 &&
      tmuxAConnectionPhases[0].accepted &&
      tmuxAConnectionPhases[0].closed &&
      tmuxAConnectionPhases[0].passwordAccepted === 0 &&
      tmuxAConnectionPhases[0].passwordRejected === 0 &&
      tmuxAConnectionPhases[0].shellSessions === 0 &&
      tmuxAConnectionPhases[1].accepted &&
      !tmuxAConnectionPhases[1].closed &&
      tmuxAConnectionPhases[1].passwordAccepted === 1 &&
      tmuxAConnectionPhases[1].passwordRejected === 0 &&
      tmuxAConnectionPhases[1].shellSessions === 1 &&
      relayWebSockets.A === tmuxAConnectBaseline.webSockets + 2 &&
      relayWebSocketCloses.A === tmuxAConnectBaseline.closes + 1 &&
      activeRelayWebSockets.A.size === tmuxAConnectBaseline.activeWebSockets + 1 &&
      tmuxATickets.length === 2 && tmuxATickets.every((ticket) =>
        ticket.status === 200 && ticket.targetHost === splitTargetAddress &&
        ticket.targetPort === tmuxFixturePort),
    'Profile A did not establish the exact two-phase real SSH tmux connection');
    assertThat(await pageA.getByRole('button', {
      name: 'Trust after verification', exact: true,
    }).count() === 0,
    'Workspace Connect unexpectedly exposed a first-use host-key approval prompt');
    const tmuxAConnectPromptState = await pageA.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none' &&
          Number(style.opacity || 1) > 0;
      };
      const text = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => [node.getAttribute('aria-label') || '',
          node.innerText || '', node.textContent || ''].join(' '))
        .join(' ');
      return {
        hostKeyPrompt: /verify ssh host key|trust after verification/i.test(text),
        credentialPrompt:
          /select credential|choose credential|password required|password authentication/i.test(text),
        visiblePasswordInputCount:
          [...document.querySelectorAll('input[type="password"]')].filter(visible).length,
        hostKeyConflict: /host key.{0,30}(changed|conflict)/i.test(text),
        authenticationFailure:
          /authentication failed|password rejected|credential unavailable/i.test(text),
      };
    });
    assertThat(!tmuxAConnectPromptState.hostKeyPrompt &&
      !tmuxAConnectPromptState.credentialPrompt &&
      tmuxAConnectPromptState.visiblePasswordInputCount === 0 &&
      !tmuxAConnectPromptState.hostKeyConflict &&
      !tmuxAConnectPromptState.authenticationFailure,
    'Workspace Connect left an SSH trust, credential, password, or failure prompt visible');
    const tmuxAConnectedRuntimes = await workspaceTerminalRuntimeSnapshot(
      pageA, [HOST_TMUX_NAME],
    );
    assertThat(tmuxAConnectedRuntimes.length === 1 &&
      tmuxAConnectedRuntimes[0].count === 1 &&
      tmuxAConnectedRuntimes[0].connectingCount === 0 &&
      tmuxAConnectedRuntimes[0].connectedCount === 1 &&
      tmuxAConnectedRuntimes[0].failedCount === 0,
    'Workspace Connect did not leave exactly one connected tmux terminal runtime');
    const tmuxAConnectedBeforeStart = tmuxSshFixture.tmuxSnapshot();
    assertThat(tmuxAConnectedBeforeStart.sessionCount === 0 &&
      tmuxAConnectedBeforeStart.clientCount === 0,
    'ordinary Profile A Workspace Connect created or attached tmux');
    const safeTmuxStartUiState = async () => pageA.evaluate(() => {
      const visible = (node) => {
        const rect = node.getBoundingClientRect();
        const style = getComputedStyle(node);
        return rect.width > 0 && rect.height > 0 &&
          style.visibility !== 'hidden' && style.display !== 'none' &&
          Number(style.opacity || 1) > 0;
      };
      const labels = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((node) => [node.getAttribute('aria-label') || '',
          node.innerText || '', node.textContent || ''].join(' ').toLowerCase());
      const allText = labels.join(' ');
      const has = (pattern) => pattern.test(allText);
      const feedbackSelector = [
        '[role="alert"]', '[aria-live="polite"]', '[aria-live="assertive"]',
        '[role="dialog"]', '[role="alertdialog"]',
        'flt-semantics[role="alert"]', 'flt-semantics[role="dialog"]',
        'flt-semantics[role="alertdialog"]',
      ].join(',');
      const feedbackNodes = [...new Set(
        document.querySelectorAll(feedbackSelector),
      )].filter(visible);
      const feedbackCategories = new Set();
      for (const node of feedbackNodes) {
        const text = [node.getAttribute('aria-label') || '',
          node.innerText || '', node.textContent || ''].join(' ').toLowerCase();
        if (/当前主机没有可用的 tmux|no available tmux/.test(text)) {
          feedbackCategories.add('tmux-unavailable');
        } else if (/无法创建新的 tmux 会话|tmux.*create.*failed/.test(text)) {
          feedbackCategories.add('tmux-create-failed');
        } else if (/无法确认 tmux 会话已启动/.test(text)) {
          feedbackCategories.add('tmux-create-unconfirmed');
        } else if (/tmux 操作超时|tmux operation timed out/.test(text)) {
          feedbackCategories.add('tmux-timeout');
        } else if (/请先连接此工作区窗格的主机/.test(text)) {
          feedbackCategories.add('pane-not-connected');
        } else if (/vault 或 ssh 连接已变化/.test(text)) {
          feedbackCategories.add('workspace-connection-changed');
        } else if (/ssh 连接已关闭/.test(text)) {
          feedbackCategories.add('ssh-closed');
        } else if (/无法完成 tmux 会话操作/.test(text)) {
          feedbackCategories.add('tmux-operation-failed');
        } else if (/timed out|超时/.test(text)) {
          feedbackCategories.add('timeout');
        }
      }
      return {
        terminalTitleVisible: has(/terminal workspace/),
        startToolbarVisible: has(/start resumable session/),
        resumeToolbarVisible: has(/resume tmux session/),
        startConfirmationVisible: has(/start resumable tmux session\?/),
        startConfirmActionVisible: has(/start session/),
        visibleAlertCount: feedbackNodes.filter((node) =>
          node.matches('[role="alert"], [aria-live="polite"], [aria-live="assertive"]'),
        ).length,
        visibleDialogCount: feedbackNodes.filter((node) =>
          node.matches('[role="dialog"], [role="alertdialog"]'),
        ).length,
        visibleFeedbackCategories: [...feedbackCategories].sort(),
      };
    }).catch(() => ({ pageAvailable: false }));
    const safeTmuxStartState = () => {
      const baseline = tmuxAStartTransportBaseline;
      const relay = {
        ticketDelta: relayAttempts.A.length - baseline.tickets,
        webSocketDelta: relayWebSockets.A - baseline.webSockets,
        closeDelta: relayWebSocketCloses.A - baseline.closes,
        activeWebSocketDelta: activeRelayWebSockets.A.size -
          baseline.activeWebSockets,
      };
      let tmux = null;
      let tmuxProbe = {
        fixtureStateAvailable: false,
        fixtureProbeExceptionClass: null,
        fixtureProbeErrorCategory: null,
      };
      try {
        const state = tmuxSshFixture.tmuxSnapshot();
        tmux = {
          serverRunning: state.serverRunning,
          sessionCount: state.sessionCount,
          clientCount: state.clientCount,
          attachedClientCounts: state.sessions.map((session) =>
            session.attachedClientCount),
          validRandomSessionNameCount: state.sessions.filter((session) =>
            /^atermius_[0-9a-f]{32}$/.test(session.name)).length,
        };
        tmuxProbe = {
          fixtureStateAvailable: true,
          fixtureProbeExceptionClass: null,
          fixtureProbeErrorCategory: null,
        };
      } catch (error) {
        tmuxProbe = {
          fixtureStateAvailable: false,
          fixtureProbeExceptionClass: error?.name || 'Error',
          fixtureProbeErrorCategory: tmuxFixtureProbeErrorCategory(error),
        };
      }
      let sshState;
      try {
        const ssh = tmuxSshFixture.server.summary();
        sshState = {
          sshStateAvailable: true,
          ssh: {
            running: ssh.running,
            tcpConnectionsAccepted: ssh.tcpConnectionsAccepted,
            tcpConnectionsClosed: ssh.tcpConnectionsClosed,
            tcpConnectionsOpen: ssh.tcpConnectionsOpen,
            keyExchangeStarted: ssh.keyExchangeStarted,
            passwordAccepted: ssh.passwordAccepted,
            passwordRejected: ssh.passwordRejected,
            shellSessions: ssh.shellSessions,
            commandSessions: ssh.commandSessions,
            tcpAcceptedDelta: ssh.tcpConnectionsAccepted -
              baseline.ssh.tcpConnectionsAccepted,
            tcpClosedDelta: ssh.tcpConnectionsClosed -
              baseline.ssh.tcpConnectionsClosed,
            keyExchangeDelta: ssh.keyExchangeStarted -
              baseline.ssh.keyExchangeStarted,
            passwordAcceptedDelta: ssh.passwordAccepted -
              baseline.ssh.passwordAccepted,
            passwordRejectedDelta: ssh.passwordRejected -
              baseline.ssh.passwordRejected,
            shellSessionDelta: ssh.shellSessions - baseline.ssh.shellSessions,
            commandSessionDelta: ssh.commandSessions -
              baseline.ssh.commandSessions,
          },
          sshProbeExceptionClass: null,
          sshProbeErrorCategory: null,
        };
      } catch (error) {
        sshState = {
          sshStateAvailable: false,
          ssh: null,
          sshProbeExceptionClass: error?.name || 'Error',
          sshProbeErrorCategory: 'sshd-summary-unavailable',
        };
      }
      return {
        ...tmuxProbe,
        ...(tmux === null ? {} : { tmux }),
        ...sshState,
        relay,
        syncApi: vaultSyncApiEvents.A.slice(tmuxStartApiBaseline).map((event) => ({
          endpoint: event.endpoint,
          method: event.method,
          status: event.status,
          failed: event.failed,
        })),
      };
    };
    const tmuxStartErrorCategory = (error) => {
      if (error?.name === 'TimeoutError') return 'timeout';
      const message = String(error?.message || '').toLowerCase();
      if (message.includes('workspace acceptance capture timed out')) {
        return 'capture-timeout';
      }
      if (message.includes('tmux fixture state did not reach')) {
        return 'tmux-state-timeout';
      }
      if (message.includes('strict mode violation')) return 'locator-ambiguous';
      if (message.includes('not visible')) return 'locator-not-visible';
      if (message.includes('not enabled')) return 'locator-disabled';
      if (message.includes('timed out')) return 'timeout';
      if (message.startsWith('profile a')) return 'runner-assertion';
      return 'other-error';
    };
    const tmuxStartCheckpoint = async (phase, error = null, extra = {}) => {
      let state;
      try {
        state = safeTmuxStartState();
      } catch (probeError) {
        state = {
          fixtureStateAvailable: false,
          fixtureProbeExceptionClass: probeError?.name || 'Error',
          fixtureProbeErrorCategory: 'checkpoint-probe-error',
        };
      }
      const ui = await safeTmuxStartUiState();
      const receipt = {
        phase,
        outcome: error === null ? 'passed' : 'failed',
        ...(error === null ? {} : {
          errorClass: ['TimeoutError', 'TmuxFixtureStateWaitError']
            .includes(error?.name) ? error.name : 'Error',
          errorCategory: tmuxStartErrorCategory(error),
          ...(Number.isInteger(error?.probeCount) ? {
            fixtureProbeCount: error.probeCount,
          } : {}),
          ...(Number.isInteger(error?.probeErrorCount) ? {
            fixtureProbeErrorCount: error.probeErrorCount,
          } : {}),
          ...(error?.lastProbeErrorCategory ? {
            lastProbeErrorCategory: error.lastProbeErrorCategory,
          } : {}),
        }),
        ...state,
        ui,
        ...extra,
      };
      console.log('WEB-WORKSPACE-TMUX-START-CHECKPOINT', JSON.stringify(receipt));
    };
    const runTmuxStartPhase = async (phase, operation) => {
      stage = `Profile A tmux Start ${phase}`;
      try {
        const result = await operation();
        await tmuxStartCheckpoint(phase);
        return result;
      } catch (error) {
        await tmuxStartCheckpoint(phase, error);
        throw error;
      }
    };
    stage = 'Profile A tmux Start toolbar action count';
    const tmuxStartAction = pageA.getByRole('button', {
      name: 'Start resumable session', exact: true,
    });
    const tmuxStartActionCount = await tmuxStartAction.count();
    assertThat(tmuxStartActionCount === 1,
      'connected Profile A tmux pane did not expose the Start action');
    const tmuxAStartTransportBaseline = {
      tickets: relayAttempts.A.length,
      webSockets: relayWebSockets.A,
      closes: relayWebSocketCloses.A,
      activeWebSockets: activeRelayWebSockets.A.size,
      ssh: tmuxSshFixture.server.summary(),
    };
    const tmuxWorkspaceVaultBeforeDescriptor = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const tmuxUpdatePushBaseline = workspaceSplitPushes.length;
    const tmuxUpdateResponseBaseline = workspaceSplitPushResponses.length;
    const tmuxStartApiBaseline = vaultSyncApiEvents.A.length;
    console.log('WEB-WORKSPACE-TMUX-START-READY', JSON.stringify({
      startActionCount: tmuxStartActionCount,
      ...safeTmuxStartState(),
    }));
    await runTmuxStartPhase('toolbar-click', () => tmuxStartAction.click());
    await runTmuxStartPhase('wait-confirmation-dialog', () =>
      waitForText(pageA, 'Start resumable tmux session?'));
    const tmuxStartConfirmationCount = await pageA.getByRole('button', {
      name: 'Start session', exact: true,
    }).count();
    await tmuxStartCheckpoint('confirmation-button-count', null, {
      startConfirmationButtonCount: tmuxStartConfirmationCount,
    });
    assertThat(tmuxStartConfirmationCount === 1,
      'Profile A Start confirmation did not expose exactly one confirmation button');
    await runTmuxStartPhase('confirmation-click', () =>
      click(pageA, 'Start session'));
    const tmuxStartCommandBaseline = tmuxAStartTransportBaseline.ssh.commandSessions;
    const tmuxStartCommandReceipt = await runTmuxStartPhase(
      'wait-first-SSH-exec-request',
      () => waitForCaptured(() => {
        const ssh = tmuxSshFixture.server.summary();
        return ssh.commandSessions > tmuxStartCommandBaseline ? ssh : null;
      }, 'Profile A tmux Start SSH exec request', 15000),
    );
    await tmuxStartCheckpoint('first-SSH-exec-request-observed', null, {
      commandSessionDelta: tmuxStartCommandReceipt.commandSessions -
        tmuxStartCommandBaseline,
    });
    const tmuxStarted = await runTmuxStartPhase('wait-created-and-attached-session',
      () => waitForTmuxState(
        tmuxSshFixture,
        (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 1 &&
          snapshot.sessions[0]?.attachedClientCount === 1,
        'one started and attached session',
        20000,
      ));
    await tmuxStartCheckpoint('created-and-attached-session-observed', null, {
      commandSessionDelta: tmuxStarted ?
        tmuxSshFixture.server.summary().commandSessions - tmuxStartCommandBaseline : null,
      fixtureProbeDiagnostics: tmuxStarted.fixtureProbeDiagnostics,
    });
    const tmuxSessionName = tmuxStarted.sessions[0].name;
    const tmuxSessionId = tmuxStarted.sessions[0].sessionId;
    const tmuxSessionNameFormatValid = /^atermius_[0-9a-f]{32}$/.test(tmuxSessionName);
    await tmuxStartCheckpoint('session-name-format-validation', null, {
      sessionNameFormatValid: tmuxSessionNameFormatValid,
    });
    assertThat(tmuxSessionNameFormatValid,
      'Start created a tmux session outside the fixed random-name format');
    PRIVACY_MARKERS.push(tmuxSessionName, splitTargetAddress);
    const tmuxCanaryState = await runTmuxStartPhase('wait-privacy-canary', () =>
      waitForCaptured(() => {
      const snapshot = tmuxSshFixture.tmuxPrivacyMarkerSnapshot(
        tmuxSessionName, TMUX_COMMAND_MARKER, TMUX_OUTPUT_MARKER,
      );
      return snapshot.commandMarkerVisible && snapshot.outputMarkerVisible
        ? snapshot : null;
      }, 'tmux command and output privacy canaries', 10000));
    await tmuxStartCheckpoint('privacy-canary-observed', null, {
      commandMarkerVisible: tmuxCanaryState.commandMarkerVisible,
      outputMarkerVisible: tmuxCanaryState.outputMarkerVisible,
    });
    await runTmuxStartPhase('wait-resume-toolbar-state', () =>
      waitForVisibleSemanticText(pageA, 'Resume tmux session',
        'Profile A saved tmux descriptor toolbar state', 15000));
    await runTmuxStartPhase('sync-encrypted-descriptor-update', () =>
      syncNow(pageA, 'Profile A encrypted tmux descriptor update'));
    await tmuxStartCheckpoint('descriptor-sync-response-observed', null, {
      pushRequestDelta: workspaceSplitPushes.length - tmuxUpdatePushBaseline,
      pushResponseDelta: workspaceSplitPushResponses.length - tmuxUpdateResponseBaseline,
      syncApiEvents: vaultSyncApiEvents.A.slice(tmuxStartApiBaseline).map((event) => ({
        endpoint: event.endpoint,
        method: event.method,
        status: event.status,
        failed: event.failed,
      })),
    });
    const tmuxUpdateOperation = await runTmuxStartPhase(
      'capture-descriptor-update-operation',
      () => waitForCaptured(() =>
      workspaceSplitPushes.slice(tmuxUpdatePushBaseline)
        .flatMap((push) => push.operations)
        .find((operation) => operation.operation === 'update' &&
          operation.recordId === tmuxWorkspaceRecordId &&
          operation.revisionId && operation.opId),
      'Profile A encrypted tmux Workspace descriptor update'),
    );
    const tmuxUpdatePush = workspaceSplitPushes.slice(tmuxUpdatePushBaseline)
      .find((push) => push.operations.includes(tmuxUpdateOperation));
    const tmuxUpdateReceipt = await runTmuxStartPhase(
      'capture-descriptor-update-receipt',
      () => waitForCaptured(() =>
      workspaceSplitPushResponses.slice(tmuxUpdateResponseBaseline)
        .find((response) => response.status === 200 &&
          response.results.some((result) => result.opId === tmuxUpdateOperation.opId &&
            result.revisionId === tmuxUpdateOperation.revisionId &&
            result.commitSeq && !result.alreadyCommitted)),
      'Profile A encrypted tmux Workspace update receipt'),
    );
    await tmuxStartCheckpoint('descriptor-update-push-receipt-summary', null, {
      pushRequestDelta: workspaceSplitPushes.length - tmuxUpdatePushBaseline,
      pushResponseDelta: workspaceSplitPushResponses.length - tmuxUpdateResponseBaseline,
      operationCaptured: tmuxUpdateOperation.operation === 'update',
      operationEnvelopeShapeValid: tmuxUpdateOperation.envelopeShapeValid === true,
      requestPlaintextMarkersAbsent:
        tmuxUpdatePush?.requestBodyPlaintextMarkersAbsent === true,
      workspaceHostReferenceMarkersAbsent:
        tmuxUpdatePush?.encryptedWorkspaceHostReferenceMarkersAbsent === true,
      responseStatus: tmuxUpdateReceipt.status,
      responseResultCount: tmuxUpdateReceipt.results.length,
      receiptLinksToCapturedOperation: tmuxUpdateReceipt.results.some((result) =>
        result.opId === tmuxUpdateOperation.opId &&
        result.revisionId === tmuxUpdateOperation.revisionId),
    });
    stage = 'Profile A tmux Start read encrypted descriptor database commit and head';
    const tmuxWorkspaceVaultAfterDescriptor = serverVaultSnapshot(databasePath).vaults
      .find((item) => item.vaultId === vaultId);
    const tmuxDescriptorCommit = serverCommitDelta(
      databasePath,
      vaultId,
      tmuxWorkspaceVaultBeforeDescriptor.commitSeq,
      tmuxWorkspaceVaultAfterDescriptor.commitSeq,
    );
    const tmuxDescriptorState = serverWorkspaceRecordSnapshot(
      databasePath,
      vaultId,
      tmuxWorkspaceRecordId,
      PRIVACY_MARKERS,
    );
    const tmuxDescriptorValidation = {
      onePushRequest: workspaceSplitPushes.length === tmuxUpdatePushBaseline + 1,
      oneUpdateOperation: tmuxUpdatePush?.operations.length === 1 &&
        tmuxUpdateOperation.operation === 'update',
      requestPlaintextMarkersAbsent: tmuxUpdatePush?.requestBodyPlaintextMarkersAbsent === true,
      workspaceHostReferenceMarkersAbsent:
        tmuxUpdatePush?.encryptedWorkspaceHostReferenceMarkersAbsent === true,
      envelopeShapeValid: tmuxUpdateOperation.envelopeShapeValid === true,
      oneSuccessfulReceipt: tmuxUpdateReceipt.status === 200 &&
        tmuxUpdateReceipt.results.length === 1,
      oneCommitEvent: tmuxDescriptorCommit.eventCount === 1 &&
        tmuxDescriptorCommit.distinctCommitCount === 1,
      eventIsUpdateForCapturedWorkspace:
        tmuxDescriptorCommit.events[0]?.operation === 'update' &&
        tmuxDescriptorCommit.events[0]?.recordId === tmuxWorkspaceRecordId,
      encryptedVersionCount: tmuxDescriptorState.versions.length,
      updatedVersionMarkersAbsent: tmuxDescriptorState.versions[1]?.markersAbsent === true,
      updatedVersionEnvelopeValid: tmuxDescriptorState.versions[1]?.validEnvelope === true,
      headMatchesCapturedRevision:
        tmuxDescriptorState.headRevisionId === tmuxUpdateOperation.revisionId,
      receiptCount: tmuxDescriptorState.receipts.length,
    };
    await tmuxStartCheckpoint('descriptor-database-commit-and-head-observed', null, {
      commitSeqBefore: tmuxWorkspaceVaultBeforeDescriptor.commitSeq,
      commitSeqAfter: tmuxWorkspaceVaultAfterDescriptor.commitSeq,
      commitEventCount: tmuxDescriptorCommit.eventCount,
      distinctCommitCount: tmuxDescriptorCommit.distinctCommitCount,
      operationKinds: tmuxDescriptorCommit.events.map((event) => event.operation),
      ...tmuxDescriptorValidation,
    });
    stage = 'Profile A tmux Start validate encrypted descriptor update';
    assertThat(tmuxDescriptorValidation.onePushRequest &&
      tmuxDescriptorValidation.oneUpdateOperation &&
      tmuxDescriptorValidation.requestPlaintextMarkersAbsent &&
      tmuxDescriptorValidation.workspaceHostReferenceMarkersAbsent &&
      tmuxDescriptorValidation.envelopeShapeValid &&
      tmuxDescriptorValidation.oneSuccessfulReceipt &&
      tmuxDescriptorValidation.oneCommitEvent &&
      tmuxDescriptorValidation.eventIsUpdateForCapturedWorkspace &&
      tmuxDescriptorValidation.encryptedVersionCount === 2 &&
      tmuxDescriptorValidation.updatedVersionMarkersAbsent &&
      tmuxDescriptorValidation.updatedVersionEnvelopeValid &&
      tmuxDescriptorValidation.headMatchesCapturedRevision &&
      tmuxDescriptorValidation.receiptCount === 2,
    'tmux session descriptor was not synced as one plaintext-free encrypted Workspace update');
    const tmuxAStartTransportAfter = tmuxSshFixture.server.summary();
    const tmuxStartTransportInvariant = relayAttempts.A.length === tmuxAStartTransportBaseline.tickets &&
      relayWebSockets.A === tmuxAStartTransportBaseline.webSockets &&
      relayWebSocketCloses.A === tmuxAStartTransportBaseline.closes &&
      activeRelayWebSockets.A.size === tmuxAStartTransportBaseline.activeWebSockets &&
      tmuxAStartTransportAfter.tcpConnectionsAccepted ===
        tmuxAStartTransportBaseline.ssh.tcpConnectionsAccepted &&
      tmuxAStartTransportAfter.tcpConnectionsClosed ===
        tmuxAStartTransportBaseline.ssh.tcpConnectionsClosed &&
      tmuxAStartTransportAfter.tcpConnectionsOpen ===
        tmuxAStartTransportBaseline.ssh.tcpConnectionsOpen &&
      tmuxAStartTransportAfter.keyExchangeStarted ===
        tmuxAStartTransportBaseline.ssh.keyExchangeStarted &&
      tmuxAStartTransportAfter.passwordAccepted ===
        tmuxAStartTransportBaseline.ssh.passwordAccepted &&
      tmuxCanaryState.commandMarkerVisible && tmuxCanaryState.outputMarkerVisible;
    await tmuxStartCheckpoint('start-transport-invariant', null, {
      invariantHolds: tmuxStartTransportInvariant,
      tmuxCommandSessionDelta: tmuxAStartTransportAfter.commandSessions -
        tmuxAStartTransportBaseline.ssh.commandSessions,
    });
    assertThat(tmuxStartTransportInvariant,
      'Profile A Start created a second SSH/Relay transport or lost its privacy canary');

    stage = 'Profile B reload, pull, and preview the encrypted tmux descriptor';
    const tmuxBBeforeLoad = {
      ticketsA: relayAttempts.A.length,
      ticketsB: relayAttempts.B.length,
      webSocketsA: relayWebSockets.A,
      webSocketsB: relayWebSockets.B,
      closesA: relayWebSocketCloses.A,
      closesB: relayWebSocketCloses.B,
      activeA: activeRelayWebSockets.A.size,
      activeB: activeRelayWebSockets.B.size,
      ssh: tmuxSshFixture.server.summary(),
      tmux: tmuxSshFixture.tmuxSnapshot(),
    };
    await restoreWorkspaceAfterReload(pageB, 'B', baseUrl);
    await click(pageB, 'Workspaces');
    const tmuxPullChangeBaseline = splitPullChangePages.length;
    await syncNow(pageB, 'Profile B tmux Workspace descriptor force pull', {
      forcePull: true,
    });
    const tmuxPullPages = splitPullChangePages.slice(tmuxPullChangeBaseline);
    const tmuxPullPageHasRecord = tmuxPullPages.some((item) =>
      item.httpStatus === 200 && item.responsePlaintextMarkersAbsent &&
      item.seenRecordIds?.includes(tmuxWorkspaceRecordId));
    const tmuxConnectButtonsB = await stageSingleWorkspacePreview(
      pageB,
      TMUX_WORKSPACE_NAME,
      {
        existingWorkspaceNames: existingTmuxWorkspaceNames,
        hostName: HOST_TMUX_NAME,
        profile: 'B',
      },
    );
    stage = 'Profile B sample SSH and tmux fixture after descriptor preview';
    await pageB.waitForTimeout(250);
    const tmuxBPreviewSsh = tmuxSshFixture.server.summary();
    const tmuxBPreviewState = tmuxSshFixture.tmuxSnapshot();
    const tmuxBPreviewDeltas = {
      relayTicketDeltaA: relayAttempts.A.length - tmuxBBeforeLoad.ticketsA,
      relayTicketDeltaB: relayAttempts.B.length - tmuxBBeforeLoad.ticketsB,
      relayWebSocketOpenDeltaA: relayWebSockets.A - tmuxBBeforeLoad.webSocketsA,
      relayWebSocketOpenDeltaB: relayWebSockets.B - tmuxBBeforeLoad.webSocketsB,
      relayWebSocketCloseDeltaA: relayWebSocketCloses.A - tmuxBBeforeLoad.closesA,
      relayWebSocketCloseDeltaB: relayWebSocketCloses.B - tmuxBBeforeLoad.closesB,
      activeRelayWebSocketDeltaA:
        activeRelayWebSockets.A.size - tmuxBBeforeLoad.activeA,
      activeRelayWebSocketDeltaB:
        activeRelayWebSockets.B.size - tmuxBBeforeLoad.activeB,
      sshAcceptedDelta: tmuxBPreviewSsh.tcpConnectionsAccepted -
        tmuxBBeforeLoad.ssh.tcpConnectionsAccepted,
      sshClosedDelta: tmuxBPreviewSsh.tcpConnectionsClosed -
        tmuxBBeforeLoad.ssh.tcpConnectionsClosed,
      sshKeyExchangeDelta: tmuxBPreviewSsh.keyExchangeStarted -
        tmuxBBeforeLoad.ssh.keyExchangeStarted,
      sshPasswordAcceptedDelta: tmuxBPreviewSsh.passwordAccepted -
        tmuxBBeforeLoad.ssh.passwordAccepted,
      tmuxSessionCount: tmuxBPreviewState.sessionCount,
      tmuxClientCount: tmuxBPreviewState.clientCount,
      originalTmuxSessionPreserved:
        tmuxBPreviewState.sessions[0]?.sessionId === tmuxSessionId,
    };
    console.log('WEB-WORKSPACE-TMUX-PROFILE-B-PREVIEW-CHECKPOINT', JSON.stringify({
      ...tmuxBPreviewDeltas,
      noNewRelayActivity: tmuxBPreviewDeltas.relayTicketDeltaA === 0 &&
        tmuxBPreviewDeltas.relayTicketDeltaB === 0 &&
        tmuxBPreviewDeltas.relayWebSocketOpenDeltaA === 0 &&
        tmuxBPreviewDeltas.relayWebSocketOpenDeltaB === 0,
      noSshdActivity: tmuxBPreviewDeltas.sshAcceptedDelta === 0 &&
        tmuxBPreviewDeltas.sshClosedDelta === 0 &&
        tmuxBPreviewDeltas.sshKeyExchangeDelta === 0 &&
        tmuxBPreviewDeltas.sshPasswordAcceptedDelta === 0,
      originalTmuxClientPreserved: tmuxBPreviewState.sessionCount === 1 &&
        tmuxBPreviewState.clientCount === 1 &&
        tmuxBPreviewDeltas.originalTmuxSessionPreserved,
    }));
    // Existing idle WebSockets may close while this long acceptance run is
    // loading and previewing on Profile B. Only new tickets or opens show that
    // preview itself attempted a Relay connection.
    stage = 'Profile B assert preview creates no Relay ticket or WebSocket';
    assertThat(tmuxBPreviewDeltas.relayTicketDeltaA === 0 &&
      tmuxBPreviewDeltas.relayTicketDeltaB === 0 &&
      tmuxBPreviewDeltas.relayWebSocketOpenDeltaA === 0 &&
      tmuxBPreviewDeltas.relayWebSocketOpenDeltaB === 0,
    'Profile B tmux descriptor preview created a Relay ticket or WebSocket');
    stage = 'Profile B assert preview creates no SSHD activity';
    assertThat(tmuxBPreviewDeltas.sshAcceptedDelta === 0 &&
      tmuxBPreviewDeltas.sshClosedDelta === 0 &&
      tmuxBPreviewDeltas.sshKeyExchangeDelta === 0 &&
      tmuxBPreviewDeltas.sshPasswordAcceptedDelta === 0,
    'Profile B tmux descriptor preview created SSHD activity');
    stage = 'Profile B assert preview preserves the original tmux session/client';
    assertThat(tmuxBPreviewState.sessionCount === 1 &&
      tmuxBPreviewState.clientCount === 1 &&
      tmuxBPreviewDeltas.originalTmuxSessionPreserved,
    'Profile B tmux descriptor preview resumed or replaced the existing session');

    stage = 'Profile B explicitly Connect to the tmux Host without resuming';
    const tmuxBConnectBaseline = {
      tickets: relayAttempts.B.length,
      webSockets: relayWebSockets.B,
      closes: relayWebSocketCloses.B,
      activeWebSockets: activeRelayWebSockets.B.size,
      ssh: tmuxSshFixture.server.summary(),
    };
    await tmuxConnectButtonsB.first().click();
    const tmuxBConnectTicket = await waitForCaptured(() => {
      const ticket = relayAttempts.B[tmuxBConnectBaseline.tickets];
      return ticket?.status !== null && ticket ? ticket : null;
    }, 'Profile B explicit tmux Host Relay ticket');
    assertThat(tmuxBConnectTicket.status === 200 &&
      tmuxBConnectTicket.targetHost === splitTargetAddress &&
      tmuxBConnectTicket.targetPort === tmuxFixturePort,
    'Profile B Connect did not use the exact synchronized tmux Host');
    const trustButtonB = pageB.getByRole('button', {
      name: 'Trust after verification', exact: true,
    });
    const bTrustDeadline = Date.now() + 15000;
    let tmuxBTrusted = false;
    let tmuxBRuntimeConnected = false;
    while (Date.now() < bTrustDeadline && !tmuxBRuntimeConnected) {
      if (await trustButtonB.isVisible().catch(() => false)) {
        const trust = await acceptFirstUseSshHostKey(
          pageB, HOST_TMUX_NAME, tmuxSshFixture.server.hostFingerprint,
        );
        tmuxBTrusted = trust.fingerprintMatchesFixture;
        break;
      }
      const runtime = await workspaceTerminalRuntimeSnapshot(pageB, [HOST_TMUX_NAME]);
      tmuxBRuntimeConnected = runtime[0]?.connectedCount === 1 &&
        runtime[0]?.failedCount === 0;
      if (!tmuxBRuntimeConnected) await pageB.waitForTimeout(100);
    }
    await waitForCaptured(() => {
      const summary = tmuxSshFixture.server.summary();
      return summary.passwordAccepted === tmuxBConnectBaseline.ssh.passwordAccepted + 1 &&
        summary.shellSessions === tmuxBConnectBaseline.ssh.shellSessions + 1 &&
        activeRelayWebSockets.B.size === tmuxBConnectBaseline.activeWebSockets + 1
        ? summary : null;
    }, 'Profile B ordinary SSH Connect without tmux attach', 20000);
    const tmuxBConnectedSnapshot = tmuxSshFixture.tmuxSnapshot();
    assertThat((tmuxBTrusted || tmuxBRuntimeConnected ||
      (await workspaceTerminalRuntimeSnapshot(pageB, [HOST_TMUX_NAME]))[0]?.connectedCount === 1) &&
      tmuxBConnectedSnapshot.sessionCount === 1 &&
      tmuxBConnectedSnapshot.clientCount === 1 &&
      tmuxBConnectedSnapshot.sessions[0]?.sessionId === tmuxSessionId,
    'Profile B ordinary Connect created or attached tmux instead of leaving its one A client');
    const resumeButtonB = pageB.getByRole('button', {
      name: 'Resume tmux session', exact: true,
    });
    assertThat(await resumeButtonB.count() === 1 &&
      await resumeButtonB.isVisible(),
    'Profile B did not decrypt the saved descriptor into the explicit Resume action');

    stage = 'Profile B explicitly Resume on its existing SSH transport';
    const tmuxBResumeTransportBaseline = {
      tickets: relayAttempts.B.length,
      webSockets: relayWebSockets.B,
      closes: relayWebSocketCloses.B,
      activeWebSockets: activeRelayWebSockets.B.size,
      ssh: tmuxSshFixture.server.summary(),
    };
    await resumeButtonB.click();
    await waitForText(pageB, 'Resume tmux session?');
    await click(pageB, 'Resume session');
    const tmuxResumed = await waitForTmuxState(
      tmuxSshFixture,
      (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 2 &&
        snapshot.sessions[0]?.sessionId === tmuxSessionId &&
        snapshot.sessions[0]?.attachedClientCount === 2,
      'the same session with two attached clients',
      20000,
    );
    const tmuxBResumeTransportAfter = tmuxSshFixture.server.summary();
    const tmuxBResumeTransportUnchanged =
      relayAttempts.B.length === tmuxBResumeTransportBaseline.tickets &&
      relayWebSockets.B === tmuxBResumeTransportBaseline.webSockets &&
      relayWebSocketCloses.B === tmuxBResumeTransportBaseline.closes &&
      activeRelayWebSockets.B.size === tmuxBResumeTransportBaseline.activeWebSockets &&
      tmuxBResumeTransportAfter.tcpConnectionsAccepted ===
        tmuxBResumeTransportBaseline.ssh.tcpConnectionsAccepted &&
      tmuxBResumeTransportAfter.tcpConnectionsClosed ===
        tmuxBResumeTransportBaseline.ssh.tcpConnectionsClosed &&
      tmuxBResumeTransportAfter.tcpConnectionsOpen ===
        tmuxBResumeTransportBaseline.ssh.tcpConnectionsOpen &&
      tmuxBResumeTransportAfter.keyExchangeStarted ===
        tmuxBResumeTransportBaseline.ssh.keyExchangeStarted &&
      tmuxBResumeTransportAfter.passwordAccepted ===
        tmuxBResumeTransportBaseline.ssh.passwordAccepted;
    assertThat(tmuxBResumeTransportUnchanged &&
      tmuxResumed.clients.length === 2 &&
      tmuxResumed.clients.every((client) => client.sessionId === tmuxSessionId),
    'explicit Resume created a Relay/SSH transport instead of a second tmux client');

    stage = 'Profile B Disconnect its tmux client while preserving A and the session';
    await click(pageB, 'Disconnect');
    const tmuxAfterBDisconnect = await waitForTmuxState(
      tmuxSshFixture,
      (snapshot) => snapshot.sessionCount === 1 && snapshot.clientCount === 1 &&
        snapshot.sessions[0]?.sessionId === tmuxSessionId &&
        snapshot.sessions[0]?.attachedClientCount === 1,
      'B detach with one A client and the session preserved',
      15000,
    );
    const tmuxBAfterDisconnectSsh = tmuxSshFixture.server.summary();
    await waitForCaptured(() => activeRelayWebSockets.B.size ===
      tmuxBConnectBaseline.activeWebSockets &&
      relayWebSocketCloses.B === tmuxBConnectBaseline.closes +
        (relayWebSockets.B - tmuxBConnectBaseline.webSockets),
    'Profile B tmux SSH Relay transport disconnect', 15000);
    assertThat(tmuxBAfterDisconnectSsh.tcpConnectionsOpen ===
      tmuxBConnectBaseline.ssh.tcpConnectionsOpen &&
      tmuxAfterBDisconnect.sessionCount === 1 && tmuxAfterBDisconnect.clientCount === 1 &&
      tmuxAfterBDisconnect.sessions[0]?.name === tmuxSessionName,
    'Profile B disconnect killed the session, lost A attachment, or kept SSH open');

    console.log('WEB-WORKSPACE-TMUX-RESUME-01 passed', JSON.stringify({
      separateUnchrootedTmuxSshd: true,
      encryptedCredentialAndHostSyncedToProfileB: true,
      onePaneWorkspaceEncryptedCreate: true,
      descriptorEncryptedUpdate: true,
      profileALeadedWorkspaceCreateAndStartExplicitly: true,
      profileBReloadSyncPreviewRelayAndSshdDelta: 0,
      profileBExplicitConnectKeptTmuxClientCount: tmuxBConnectedSnapshot.clientCount,
      profileBResumeRequiredSeparateConfirmation: true,
      sameTmuxSessionIdAcrossProfiles: true,
      tmuxClientCountAfterResume: tmuxResumed.clientCount,
      resumeRelayAndTransportDelta: 0,
      profileBDisconnectClientCount: tmuxAfterBDisconnect.clientCount,
      sessionSurvivedProfileBDisconnect: true,
      randomSessionNameAndCredentialCommandOutputMarkersPrivate: true,
      tmuxCommandMarkerVisibleOnlyOnFixture: tmuxCanaryState.commandMarkerVisible,
      tmuxOutputMarkerVisibleOnlyOnFixture: tmuxCanaryState.outputMarkerVisible,
    }));

    stage = 'plaintext and isolation checks';
    await pageB.waitForTimeout(300);
    const apiPlaintextMarkerLeakChecks = apiPrivacyChecks
      .filter((item) => !item.markersAbsent).length;
    const databasePlaintextMarkers = serverPlaintextMarkers(databasePath);
    assertThat(apiPrivacyChecks.length > 0 &&
      apiPlaintextMarkerLeakChecks === 0,
    'sync API request or response contained a synthetic plaintext marker');
    assertThat(databasePlaintextMarkers.length === 0,
      'workspace/Host/credential marker appeared in SQLite, WAL, or SHM');
    assertThat(pageErrors.length === 0, 'a browser profile reported a Flutter page error');

    console.log('WEB-WORKSPACE-SPLIT-RELAY-01 passed', JSON.stringify({
      schemaVersion: 3,
      paneCount: 2,
      splitAxis: 'vertical',
      splitRatioBasisPoints: 6300,
      orderedPaneHostsDecryptedAfterReload: profileBDecryptsSplitAfterReload,
      encryptedCreateCommitEventHeadReceiptLinked: true,
      apiSyncPlaintextMarkerLeakChecks: apiPlaintextMarkerLeakChecks,
      databasePlaintextMarkerCount: databasePlaintextMarkers.length,
      zeroTicketsSocketsAndSinkConnectionsBeforeExplicitConnect: true,
      explicitConnectTicketCount: splitRelayTicketDelta,
      exactPaneOneHostAndEphemeralPortMatch:
        firstSplitTicket.targetMatchesFirstSplitHost,
      exactPaneTwoHostAndEphemeralPortMatch:
        secondSplitTicket.targetMatchesSecondSplitHost,
      relayWebSocketOpenCount: splitRelayWebSocketDelta,
      relayWebSocketCloseCountAfterDisconnect: splitRelayWebSocketCloseDelta,
      activeRelayWebSocketCountAfterDisconnect:
        activeRelayWebSockets.B.size - splitTicketBaseline.activeSocketsB,
      acceptedSyntheticSinkConnections: splitRelaySinkDelta,
      paneOneSinkActiveCountAfterDisconnect: splitSink.activeCount -
        splitTicketBaseline.firstSinkActive,
      paneTwoSinkActiveCountAfterDisconnect: splitSecondSink.activeCount -
        splitTicketBaseline.secondSinkActive,
      independentTerminalRuntimes: splitRuntimesPresent,
      paneIsolatedDisconnect,
      syntheticSinkCompletedSshHandshake: false,
      realSshUserAuthenticationClaimed: false,
    }));

    console.log('WEB-WORKSPACE-NESTED-SPLIT-RELAY-01 passed', JSON.stringify({
      schemaVersion: 3,
      workspaceRecordIdPresent: Boolean(nestedWorkspaceRecordId),
      rootAxis: 'horizontal',
      rootRatioBasisPoints: 6300,
      nestedAxis: 'vertical',
      nestedRatioBasisPoints: 5700,
      activePane: 2,
      paneHostMapMatchesExpected: nestedPaneHostMapMatchesExpected,
      topologyHostRefsAndActivePaneAfterReload: profileBDecryptsNestedAfterReload,
      encryptedHostReferenceIdsAbsentFromPushPullAndStoredWorkspaceEnvelope:
        nestedMatchingPush.encryptedWorkspaceHostReferenceMarkersAbsent &&
        nestedWorkspaceApiHostReferencePrivacy && nestedVersion.markersAbsent,
      encryptedCreateCommitEventHeadReceiptLinked: true,
      zeroTicketsSocketsAndSshdConnectionsBeforeExplicitConnect:
        nestedNoRelayBeforeConnect,
      explicitConnectTicketCount:
        relayAttempts.B.length - nestedTicketBaseline.ticketsB,
      paneOneExactHostAndPortMatch: nestedPaneOneTicket.targetMatchesFirstSplitHost,
      paneTwoExactHostAndPortMatch: nestedPaneTwoTicket.targetMatchesThirdSplitHost,
      paneThreeExactHostAndPortMatch: nestedPaneThreeTicket.targetMatchesSecondSplitHost,
      allThreeLeavesHaveIndependentTerminalRuntimes: nestedAllRuntimesPresent,
      allThreeOpenSshPasswordAuthenticationsAndShellsSucceeded:
        nestedSshTrustEvidence.length === 3 && nestedSshTrustEvidence.every((item) =>
          item.sshdPasswordAcceptedDelta === 1 && item.sshdShellSessionDelta === 1),
      firstUseHostKeyTrustAcceptedInEveryPane:
        nestedSshTrustEvidence.every((item) => item.firstUseHostKeyTrustAction),
      allThreeOpenSshKeyExchangesCompleted:
        nestedSshTrustEvidence.every((item) => item.sshdKeyExchangeDelta > 0),
      selectedLeavesHaveIndependentTerminalRuntimes: nestedRuntimesPresent,
      paneLocalDisconnect: nestedPaneIsolatedDisconnect,
      paneScopedSftp: nestedWorkspaceSftpEvidence,
      apiPlaintextMarkerLeakChecks,
      databasePlaintextMarkerCount: databasePlaintextMarkers.length,
      directInvalidPasswordRejected: directFailureAttempt.status !== 0,
      directPasswordAuthCommandProbeCount: directPasswordProbes.length,
      directPasswordAuthCommandProbesAllSucceeded: directPasswordProbes.every((item) =>
        item.commandMarkerObserved),
      nestedTargetHostKeysDistinct: distinctSshHostKeys,
      nestedTargetsSftpSubsystemConfigured: true,
    }));

    console.log('WEB-WORKSPACE-CONFLICT-COPY-01 passed', JSON.stringify({
      concurrentProfiles: 2,
      commonBaseRevision: baseWorkspaceHead.revisionId,
      staleBranchKeptAsConflict: conflictSnapshot.conflicts.length === 1,
      staleBranchHasNoCommitReceipt: conflictSnapshot.staleReceiptCount === 0 &&
        conflictSnapshot.staleVersionCount === 0 && conflictSnapshot.staleEventCount === 0,
      savedLocalBranchAsEncryptedCopy: conflictSnapshot.copy.versions.length === 1 &&
        conflictSnapshot.copy.receipts.every((item) => item.count === 1 && item.matches),
      profileBReauthenticatedAfterReload,
      postReloadPullHadNoDuplicateWork,
      localConflictActionsPersistedAfterReload,
      namedCopyRemainedVisibleAfterReload: profileBCopySurvivedReload,
      namedCopyStayedSinglePushThroughResolution,
      originalResolvedToSyncedBranch: conflictRow.resolvedRevisionId ===
        resolutionResponse.resolvedRevisionId,
      exactVaultCommitDelta: conflictCommitDelta.eventCount,
      exactConflictSequenceDelta: Number(BigInt(afterConflictVault.conflictSeq) -
        BigInt(beforeConflictVault.conflictSeq)),
      profilesConverged,
      relayDelta: 0,
      apiPrivacyChecks: apiPrivacyChecks.length,
      databaseMarkerCount: 0,
      pageErrorCount: pageErrors.length,
    }));
    console.log('WEB-WORKSPACE-LAYOUT-01 passed', JSON.stringify({
      independentProfiles: true,
      workspaceSyncedInSecondProfile: true,
      schemaV3TwoLeafWorkspaceSyncedAndDecrypted: true,
      splitAxis: 'vertical',
      splitRatioBasisPoints: 6300,
      splitPaneHostOrderVerified: true,
      splitEncryptedCreateCommitEvidence: true,
      bothProfilesHaveTwoMissingPanes,
      oneSaveOneCommit: true,
      divergentBranchesPreservedByHostPane: profilesConverged,
      resolvedLayoutsConvergedOnBothProfiles: profilesConverged,
      splitWorkspaceRelayEvidence,
      schemaV3NestedWorkspaceSyncedAndDecrypted: true,
      nestedWorkspaceRelayEvidence,
      apiPrivacyChecks: apiPrivacyChecks.length,
      databaseMarkerCount: 0,
      pageErrorCount: pageErrors.length,
    }));
  } finally {
    captureWorkspaceSave = false;
    captureWorkspaceSplit = false;
    bootstrapToken = undefined;
    await cleanupResources(workspaceTerminationSignal
      ? `finally:${workspaceTerminationSignal}` : 'finally');
    process.removeListener('SIGINT', onSigint);
    process.removeListener('SIGTERM', onSigterm);
  }
}

main().catch((error) => {
  if (workspaceTerminationSignal) {
    if (process.exitCode !== 1) {
      process.exitCode = workspaceTerminationSignal === 'SIGINT' ? 130 : 143;
    }
    const cleanupState = process.exitCode === 1 ? 'fixture cleanup failed' : 'fixture cleanup completed';
    console.error(`WEB-WORKSPACE-LAYOUT-01 interrupted by ${workspaceTerminationSignal}; ${cleanupState}`);
    return;
  }
      const errorClass = error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
  console.error(`WEB-WORKSPACE-LAYOUT-01 failed at ${stage} (${errorClass}); sensitive diagnostics omitted`);
  process.exitCode = 1;
});
