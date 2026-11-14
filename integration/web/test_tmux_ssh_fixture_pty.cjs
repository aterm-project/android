#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const { spawn, spawnSync } = require('node:child_process');
const { startTmuxSshFixture } = require('./ssh_fixture.cjs');

const SSH = process.env.SSH_PATH || '/usr/bin/ssh';
const SSHPASS = process.env.SSHPASS_PATH || '/usr/bin/sshpass';
const TMUX = process.env.TMUX_PATH || '/usr/bin/tmux';
const RUNUSER = process.env.RUNUSER_PATH || '/usr/sbin/runuser';

function requireBinary(file) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    throw new Error('required fixture test runtime is unavailable');
  }
}

function privateIpv4(address) {
  const octets = address.split('.').map(Number);
  return octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
}

function fixtureAddress() {
  return Object.values(os.networkInterfaces())
    .flatMap((entries) => entries || [])
    .find((entry) => entry.family === 'IPv4' && !entry.internal &&
      privateIpv4(entry.address))?.address;
}

function reservePort(address) {
  return new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen(0, address, () => {
      const port = listener.address().port;
      listener.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function sshArguments({ address, port, username, command, forcePty = false }) {
  return [
    ...(forcePty ? ['-tt'] : []),
    '-p', String(port),
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no',
    '-o', 'LogLevel=ERROR',
    '-o', 'ConnectTimeout=5',
    `${username}@${address}`,
    command,
  ];
}

function runRemote(fixture, address, port, command, forcePty = false) {
  return spawnSync(SSHPASS, [
    '-e', SSH,
    ...sshArguments({
      address,
      port,
      username: fixture.username,
      command,
      forcePty,
    }),
  ], {
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
    timeout: 12000,
    env: {
      ...process.env,
      TERM: process.env.TERM && process.env.TERM !== 'dumb'
        ? process.env.TERM
        : 'xterm-256color',
      SSHPASS: fixture.password,
    },
    stdio: ['ignore', 'pipe', 'ignore'],
  });
}

function waitForExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve(true);
  }
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), timeoutMs);
    child.once('close', () => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function stopProcessGroup(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (_) {
    try { child.kill('SIGTERM'); } catch (_) {}
  }
}

async function waitForSnapshot(fixture, predicate, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let probeCount = 0;
  let probeErrorCount = 0;
  while (Date.now() < deadline) {
    probeCount += 1;
    try {
      const snapshot = fixture.tmuxSnapshot();
      if (predicate(snapshot)) return { snapshot, probeCount, probeErrorCount };
    } catch (_) {
      probeErrorCount += 1;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('fixture tmux state did not reach the expected state');
}

async function main() {
  const report = {
    versionExitZero: false,
    absentSessionExitOne: false,
    createExitZero: false,
    attachedSessionVerified: false,
    attachedClientVerified: false,
    privacyCommandMarkerObserved: false,
    privacyOutputMarkerObserved: false,
    detachExitZero: false,
    clientCountAfterDetachZero: false,
    killExitZero: false,
    absentSessionAfterKillExitOne: false,
  };
  let stage = 'runtime';
  let fixture;
  let attachProcess;
  let sessionName;
  const attachStdout = [];
  const attachStderr = [];

  try {
    for (const file of [SSH, SSHPASS, TMUX, RUNUSER]) requireBinary(file);
    const address = fixtureAddress();
    if (!address) throw new Error('private fixture address is unavailable');
    const port = await reservePort(address);

    stage = 'fixture-start';
    fixture = await startTmuxSshFixture({ bindAddress: address, port });
    sessionName = `atermius_${crypto.randomBytes(16).toString('hex')}`;

    stage = 'remote-version';
    const version = runRemote(fixture, address, port, 'tmux -V');
    report.versionExitZero = version.status === 0 &&
      /^tmux\s+\d/.test((version.stdout || '').trim());
    if (!report.versionExitZero) throw new Error('remote tmux version probe failed');

    stage = 'remote-absent-session';
    const absent = runRemote(fixture, address, port,
      `tmux has-session -t =${sessionName}`);
    report.absentSessionExitOne = absent.status === 1;
    if (!report.absentSessionExitOne) throw new Error('absent session probe failed');

    stage = 'remote-create-session';
    const create = runRemote(fixture, address, port,
      `tmux new-session -d -s ${sessionName}`);
    report.createExitZero = create.status === 0;
    if (!report.createExitZero) throw new Error('tmux session creation failed');

    stage = 'wait-created-session';
    const created = await waitForSnapshot(fixture, (snapshot) =>
      snapshot.sessionCount === 1 && snapshot.clientCount === 0 &&
      snapshot.sessions[0]?.name === sessionName);
    report.createdSessionCount = created.snapshot.sessionCount;
    report.createdClientCount = created.snapshot.clientCount;

    stage = 'probe-pty-terminal';
    const terminalProbe = runRemote(
      fixture,
      address,
      port,
      `printf 'TERM=%s\\n' "$TERM"; if command -v infocmp >/dev/null 2>&1 && infocmp "$TERM" >/dev/null 2>&1; then printf 'TERMINFO=yes\\n'; else printf 'TERMINFO=no\\n'; fi`,
      true,
    );
    report.terminalProbe = {
      exitCode: terminalProbe.status,
      output: (terminalProbe.stdout || '').replace(/\r/g, '').trim().split('\n').slice(-2),
    };

    stage = 'attach-pty';
    attachProcess = spawn(SSHPASS, [
      '-e', SSH,
      ...sshArguments({
        address,
        port,
        username: fixture.username,
        command: `tmux attach-session -t =${sessionName}`,
        forcePty: true,
      }),
    ], {
      detached: true,
      env: {
        ...process.env,
        TERM: process.env.TERM && process.env.TERM !== 'dumb'
          ? process.env.TERM
          : 'xterm-256color',
        SSHPASS: fixture.password,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    attachProcess.stdout.on('data', (chunk) => {
      if (Buffer.concat(attachStdout).length < 65536) attachStdout.push(chunk);
    });
    attachProcess.stderr.on('data', (chunk) => {
      if (Buffer.concat(attachStderr).length < 65536) attachStderr.push(chunk);
    });
    const attached = await waitForSnapshot(fixture, (snapshot) =>
      snapshot.sessionCount === 1 && snapshot.clientCount === 1 &&
      snapshot.sessions[0]?.name === sessionName &&
      snapshot.sessions[0]?.attachedClientCount === 1 &&
      snapshot.clients[0]?.sessionName === sessionName &&
      snapshot.clients[0]?.sessionId === snapshot.sessions[0]?.sessionId &&
      Number.isInteger(snapshot.clients[0]?.processId) &&
      snapshot.clients[0].processId > 0);
    report.attachedSessionVerified =
      attached.snapshot.sessions[0].attachedClientCount === 1;
    report.attachedClientVerified =
      attached.snapshot.clients[0].sessionName === sessionName &&
      attached.snapshot.clients[0].sessionId ===
        attached.snapshot.sessions[0].sessionId &&
      Number.isInteger(attached.snapshot.clients[0].processId) &&
      attached.snapshot.clients[0].processId > 0;
    report.attachProbeErrorCount = attached.probeErrorCount;
    report.attachedState = {
      sessionCount: attached.snapshot.sessionCount,
      clientCount: attached.snapshot.clientCount,
      attachedClientCount: attached.snapshot.sessions[0].attachedClientCount,
      clientSessionNameMatches: attached.snapshot.clients[0].sessionName === sessionName,
      clientSessionIdMatches: attached.snapshot.clients[0].sessionId ===
        attached.snapshot.sessions[0].sessionId,
      clientPidPositive: attached.snapshot.clients[0].processId > 0,
    };

    stage = 'privacy-marker-probe';
    const commandMarker = `tmux-command-marker-${crypto.randomUUID()}`;
    const outputMarker = `tmux-output-marker-${crypto.randomUUID()}`;
    const markerDeadline = Date.now() + 5000;
    let markerProbeCount = 0;
    let markerState = null;
    while (Date.now() < markerDeadline) {
      markerProbeCount += 1;
      markerState = fixture.tmuxPrivacyMarkerSnapshot(
        sessionName, commandMarker, outputMarker,
      );
      report.privacyCommandMarkerObserved = markerState.commandMarkerVisible;
      report.privacyOutputMarkerObserved = markerState.outputMarkerVisible;
      if (report.privacyCommandMarkerObserved &&
          report.privacyOutputMarkerObserved) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    report.privacyMarkerProbeCount = markerProbeCount;
    if (!report.privacyCommandMarkerObserved ||
        !report.privacyOutputMarkerObserved) {
      throw new Error('tmux privacy markers were not visible in the fixture session');
    }

    stage = 'detach-pty';
    attachProcess.stdin.write('\x02');
    await new Promise((resolve) => setTimeout(resolve, 150));
    attachProcess.stdin.write('d');
    attachProcess.stdin.end();
    const detached = await waitForExit(attachProcess, 5000);
    if (!detached) {
      stopProcessGroup(attachProcess);
      await waitForExit(attachProcess, 1000);
    }
    report.detachExitZero = detached && attachProcess.exitCode === 0;

    stage = 'verify-detach';
    const afterDetach = await waitForSnapshot(fixture, (snapshot) =>
      snapshot.sessionCount === 1 && snapshot.clientCount === 0 &&
      snapshot.sessions[0]?.name === sessionName);
    report.clientCountAfterDetachZero = afterDetach.snapshot.clientCount === 0;

    stage = 'remote-kill-session';
    const kill = runRemote(fixture, address, port,
      `tmux kill-session -t =${sessionName}`);
    report.killExitZero = kill.status === 0;
    if (!report.killExitZero) throw new Error('tmux session removal failed');

    stage = 'verify-killed-session';
    const absentAfterKill = runRemote(fixture, address, port,
      `tmux has-session -t =${sessionName}`);
    report.absentSessionAfterKillExitOne = absentAfterKill.status === 1;
    if (!report.absentSessionAfterKillExitOne) {
      throw new Error('session remained available after removal');
    }
    report.sshdCommandSessionCount = fixture.server.summary().commandSessions;
    report.stage = 'passed';
  } catch (error) {
    report.stage = stage;
    report.failureClass = error?.name || 'Error';
    if (error?.safeDiagnostics) report.failureDiagnostics = error.safeDiagnostics;
    if (fixture) {
      const summary = fixture.server.summary();
      report.sshdSummary = {
        running: summary.running,
        tcpConnectionsAccepted: summary.tcpConnectionsAccepted,
        passwordAccepted: summary.passwordAccepted,
        sessionStarts: summary.sessionStarts,
        shellSessions: summary.shellSessions,
        commandSessions: summary.commandSessions,
      };
      try {
        const root = require('node:path').dirname(
          require('node:path').dirname(fixture.server.logPath),
        );
        report.sshdEvents = fs.readFileSync(fixture.server.logPath, 'utf8')
          .split(/\r?\n/)
          .filter((line) => /pty|session|auth|error|fatal|closed|child/i.test(line))
          .slice(-10)
          .map((line) => line
            .replaceAll(fixture.username, '[fixture-user]')
            .replaceAll(fixture.bindAddress, '[fixture-address]')
            .replaceAll(fixture.password, '[redacted]')
            .replaceAll(root, '[fixture-path]'));
      } catch (_) {}
    }
    if (attachProcess) {
      report.attachProcess = {
        exitCode: attachProcess.exitCode,
        signal: attachProcess.signalCode,
        stdoutBytes: attachStdout.reduce((sum, chunk) => sum + chunk.length, 0),
        stderrBytes: attachStderr.reduce((sum, chunk) => sum + chunk.length, 0),
      };
      if (fixture) {
        report.attachProcess.outputLines = Buffer.concat(attachStdout)
          .toString('utf8').replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
          .split(/\r?\n/)
          .map((line) => line
            .replaceAll(fixture.username, '[fixture-user]')
            .replaceAll(fixture.bindAddress, '[fixture-address]')
            .replaceAll(fixture.password, '[redacted]')
            .replaceAll(sessionName || '[fixture-session]', '[fixture-session]'))
          .filter(Boolean)
          .slice(-8);
        report.attachProcess.errorLines = Buffer.concat(attachStderr)
          .toString('utf8').split(/\r?\n/)
          .filter((line) => /tmux|socket|error|failed|permission|session|pty/i.test(line))
          .slice(-8)
          .map((line) => line
            .replaceAll(fixture.username, '[fixture-user]')
            .replaceAll(fixture.bindAddress, '[fixture-address]')
            .replaceAll(fixture.password, '[redacted]')
            .replaceAll(sessionName || '', '[fixture-session]'));
      }
    }
  } finally {
    if (attachProcess && attachProcess.exitCode === null &&
        attachProcess.signalCode === null) {
      stopProcessGroup(attachProcess);
      await waitForExit(attachProcess, 1000);
    }
    const cleanup = { closed: false, cleaned: false };
    if (fixture) {
      try {
        await fixture.cleanup();
        Object.assign(cleanup, fixture.status());
      } catch (_) {}
    }
    process.stdout.write(`TMUX-SSH-FIXTURE-PTY-TEST ${JSON.stringify(report)}\n`);
    process.stdout.write(`TMUX-SSH-FIXTURE-PTY-CLEANUP ${JSON.stringify(cleanup)}\n`);
    if (report.stage !== 'passed' || !cleanup.closed || !cleanup.cleaned) {
      process.exitCode = 1;
    }
  }
}

main().catch(() => {
  process.stdout.write('TMUX-SSH-FIXTURE-PTY-TEST {"stage":"unhandled","failureClass":"Error"}\n');
  process.exitCode = 1;
});
