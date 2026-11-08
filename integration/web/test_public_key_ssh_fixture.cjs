#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { startPublicKeySshFixture } = require('./ssh_fixture.cjs');

const SSH = process.env.SSH_PATH || '/usr/bin/ssh';
const SSH_AGENT = process.env.SSH_AGENT_PATH || '/usr/bin/ssh-agent';
const SSH_ADD = process.env.SSH_ADD_PATH || '/usr/bin/ssh-add';

function requireBinary(file) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    throw new Error('required public-key SSH fixture test runtime is unavailable');
  }
}

function sshString(value) {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(bytes.length);
  return Buffer.concat([length, bytes]);
}

function makeInMemoryEcdsaIdentity() {
  const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = pair.publicKey.export({ format: 'jwk' });
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  assert.equal(x.length, 32, 'P-256 x coordinate should be 32 bytes');
  assert.equal(y.length, 32, 'P-256 y coordinate should be 32 bytes');
  const point = Buffer.concat([Buffer.from([0x04]), x, y]);
  const blob = Buffer.concat([
    sshString('ecdsa-sha2-nistp256'),
    sshString('nistp256'),
    sshString(point),
  ]);
  return {
    privateKeyPem: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }),
    authorizedKeyLine: `ecdsa-sha2-nistp256 ${blob.toString('base64')} fixture-acceptance`,
  };
}

function startAgent() {
  const started = spawnSync(SSH_AGENT, ['-s'], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  const socket = (started.stdout || '').match(/SSH_AUTH_SOCK=([^;\s]+)/)?.[1];
  const pid = (started.stdout || '').match(/SSH_AGENT_PID=(\d+)/)?.[1];
  if (started.error || started.status !== 0 || !socket || !pid) {
    throw new Error('could not start the transient in-memory SSH agent');
  }
  return { socket, pid, env: { ...process.env, SSH_AUTH_SOCK: socket, SSH_AGENT_PID: pid } };
}

function stopAgent(agent) {
  if (!agent) return;
  const stopped = spawnSync(SSH_AGENT, ['-k'], {
    encoding: 'utf8', timeout: 5000, env: agent.env,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  if (stopped.error || stopped.status !== 0) {
    try { process.kill(Number(agent.pid), 'SIGTERM'); } catch (_) {}
  }
}

function runSsh(fixture, agent, command, { authentication = 'publickey', input = '' } = {}) {
  return spawnSync(SSH, [
    '-T',
    '-p', String(fixture.port),
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=4',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'PreferredAuthentications=' + authentication,
    '-o', 'PubkeyAuthentication=' + (authentication === 'publickey' ? 'yes' : 'no'),
    '-o', 'PasswordAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    `${fixture.username}@${fixture.bindAddress}`,
    ...(command === null ? [] : [command]),
  ], {
    encoding: 'utf8',
    input,
    timeout: 10000,
    maxBuffer: 1024 * 1024,
    env: { ...agent.env, TERM: 'xterm-256color' },
    stdio: ['pipe', 'pipe', 'ignore'],
  });
}

function mode(file) {
  return fs.statSync(file).mode & 0o777;
}

function ownedBy(file, uid, gid) {
  const stat = fs.statSync(file);
  return stat.uid === uid && stat.gid === gid;
}

function filesBelow(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const child = path.join(directory, entry.name);
    return entry.isDirectory() ? filesBelow(child) : [child];
  });
}

async function waitForSummary(fixture, predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const summary = fixture.summary();
    if (predicate(summary)) return summary;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const summary = fixture.summary();
  throw new Error(`public-key fixture counters did not reach the expected values (${JSON.stringify({
    publicKeyAccepted: summary.publicKeyAccepted,
    shellSessions: summary.shellSessions,
    commandSessions: summary.commandSessions,
    markerCommands: summary.markerCommands,
  })})`);
}

async function main() {
  for (const file of [SSH, SSH_AGENT, SSH_ADD]) requireBinary(file);
  const identity = makeInMemoryEcdsaIdentity();
  let fixture;
  let agent;
  let failure;
  let finalCounters = null;
  const report = {
    loopbackEphemeralListener: false,
    effectivePublicKeyOnlyPolicy: false,
    clientPrivateKeyStayedInMemory: false,
    privateFilePermissions: false,
    authorizedKeyOwnership: false,
    passwordAuthenticationRejected: false,
    publicKeyAuthenticationAccepted: false,
    markerCommandObserved: false,
    shellSessionObserved: false,
    cleanupCompleted: false,
  };

  try {
    agent = startAgent();
    const added = spawnSync(SSH_ADD, ['-'], {
      input: identity.privateKeyPem,
      encoding: 'utf8',
      timeout: 5000,
      maxBuffer: 1024 * 1024,
      env: agent.env,
      stdio: ['pipe', 'ignore', 'ignore'],
    });
    assert.equal(added.status, 0, 'in-memory ECDSA key should load into the transient agent');

    fixture = await startPublicKeySshFixture({
      authorizedKeyLine: identity.authorizedKeyLine,
    });
    report.loopbackEphemeralListener = fixture.bindAddress === '127.0.0.1' &&
      Number.isInteger(fixture.port) && fixture.port > 0 && fixture.port < 65536 &&
      /^SHA256:[A-Za-z0-9+/]+$/.test(fixture.hostFingerprint);
    assert.equal(report.loopbackEphemeralListener, true);

    const account = spawnSync('getent', ['passwd', fixture.username], { encoding: 'utf8' });
    assert.equal(account.status, 0, 'fixture account should exist during the test');
    const fields = account.stdout.trim().split(':');
    const uid = Number(fields[2]);
    const gid = Number(fields[3]);
    report.effectivePublicKeyOnlyPolicy = fixture.authMode === 'publickey' &&
      fixture.summary().running && !fixture.server.summary().passwordAccepted;
    assert.equal(report.effectivePublicKeyOnlyPolicy, true);

    report.privateFilePermissions = mode(fixture.tempRoot) === 0o700 &&
      mode(path.join(fixture.tempRoot, 'server')) === 0o700 &&
      mode(path.join(fixture.tempRoot, 'server', 'host_ed25519')) === 0o600 &&
      mode(path.join(fixture.tempRoot, 'server', 'sshd.config')) === 0o600 &&
      mode(path.join(fixture.tempRoot, 'server', 'sshd.log')) === 0o600;
    report.authorizedKeyOwnership = mode(fixture.homePath) === 0o700 &&
      mode(fixture.sshDirectoryPath) === 0o700 &&
      mode(fixture.authorizedKeysPath) === 0o600 &&
      ownedBy(fixture.homePath, uid, gid) &&
      ownedBy(fixture.sshDirectoryPath, uid, gid) &&
      ownedBy(fixture.authorizedKeysPath, uid, gid) &&
      fs.readFileSync(fixture.authorizedKeysPath, 'utf8').trim() === identity.authorizedKeyLine;
    assert.equal(report.privateFilePermissions, true);
    assert.equal(report.authorizedKeyOwnership, true);

    const fixtureFiles = filesBelow(fixture.tempRoot);
    report.clientPrivateKeyStayedInMemory =
      !Object.hasOwn(fixture, 'clientPrivateKeyPath') &&
      !fixtureFiles.some((file) => fs.readFileSync(file).includes(identity.privateKeyPem.trim()));
    assert.equal(report.clientPrivateKeyStayedInMemory, true);

    const denied = runSsh(fixture, agent, 'true', { authentication: 'password' });
    report.passwordAuthenticationRejected = denied.status !== 0 &&
      fixture.summary().publicKeyAccepted === 0;
    assert.equal(report.passwordAuthenticationRejected, true);

    const command = `printf '%s\\n' '${fixture.markerToken}'`;
    const executed = runSsh(fixture, agent, command);
    assert.equal(executed.status, 0, 'authorized ECDSA key should execute a remote command');
    assert.equal((executed.stdout || '').trim(), fixture.markerToken);
    const commandSummary = await waitForSummary(fixture, (summary) =>
      summary.publicKeyAccepted === 1 && summary.commandSessions === 1 &&
      summary.markerCommands === 1);
    report.publicKeyAuthenticationAccepted = commandSummary.publicKeyAccepted === 1;
    report.markerCommandObserved = commandSummary.markerCommands === 1;

    const shell = runSsh(fixture, agent, null, { input: 'exit\n' });
    assert.equal(shell.status, 0, 'authorized ECDSA key should open a shell session');
    const shellSummary = await waitForSummary(fixture, (summary) =>
      summary.publicKeyAccepted === 2 && summary.shellSessions === 1);
    report.shellSessionObserved = shellSummary.shellSessions === 1;
    finalCounters = shellSummary;
  } catch (error) {
    failure = error;
  } finally {
    if (fixture) {
      try {
        await fixture.cleanup();
        const passwdAfterCleanup = spawnSync('getent', ['passwd', fixture.username], { encoding: 'utf8' });
        const groupAfterCleanup = spawnSync('getent', ['group', fixture.username], { encoding: 'utf8' });
        report.cleanupCompleted = fixture.status().closed && fixture.status().cleaned &&
          !fs.existsSync(fixture.tempRoot) && !fs.existsSync(fixture.homePath) &&
          passwdAfterCleanup.status === 2 && groupAfterCleanup.status === 2;
      } catch (_) {}
    }
    stopAgent(agent);
  }

  if (failure) throw new Error(`public-key SSH fixture acceptance failed: ${failure.message}`);
  assert.equal(report.cleanupCompleted, true, 'fixture account and private root should be removed');
  process.stdout.write(`${JSON.stringify({
    result: 'passed',
    port: fixture.port,
    counters: finalCounters,
    checks: report,
  })}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
