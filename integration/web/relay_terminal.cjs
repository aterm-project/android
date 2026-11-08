/*
 * WEB-RELAY-01: sign in through the real Web UI, create distinct encrypted
 * bastion/target SSH credentials and Hosts, trust temporary SSHD host keys,
 * exercise both one-hop and Bastion A -> Bastion B -> loopback Target routes,
 * disconnect, then reject independently changed host keys at every hop.
 *
 * Safety boundary: both bastions bind only the container's eth0 IPv4 address;
 * all target SSHDs bind only 127.0.0.1. Bastion A may forward only to its
 * explicitly listed fixture endpoints and Bastion B only to its exact target
 * port. Relay's allowlist contains only Bastion A's /32 and port.
 * All user keys, host keys, configs, and synthetic files are temporary.
 * sshd runs as root only for privilege separation; root login is disabled and
 * every shell session is a non-root chroot fixture. No external host is used,
 * and this script never reads or modifies system SSH configuration/keys.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { createKeyboardInteractivePamFixture } = require('./keyboard_interactive_pam_fixture.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = path.join(SERVER_TARGET_DIR, 'debug/atermius-server');
const SSHD = process.env.SSHD_PATH || '/usr/sbin/sshd';
const SSH_KEYGEN = process.env.SSH_KEYGEN_PATH || '/usr/bin/ssh-keygen';
const RUN_ID = crypto.randomUUID();
const USERNAME = `relay-web-${RUN_ID.slice(0, 8)}@example.test`;
const MASTER_PASSWORD = `RelayE2e${crypto.randomBytes(20).toString('hex')}9`;
let safeRunStage = 'setup';
let activeTerminationSignal = null;
let sshLoginAccount = null;
let needsEphemeralSshAccount = false;
let ephemeralSshAccountFixture = null;
let secondJumpPrivateKey;
let multiHopTargetPrivateKey;
let thirdJumpPrivateKey;
let fourthJumpPrivateKey;
let maxDepthJumpPrivateKeys = [];

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function redact(text, ...secrets) {
  let value = String(text || '');
  for (const secret of secrets) {
    if (!secret) continue;
    const candidates = [String(secret), JSON.stringify(String(secret)).slice(1, -1)];
    for (const candidate of candidates) {
      if (candidate) value = value.split(candidate).join('[REDACTED]');
    }
  }
  return value
    .replace(/-----BEGIN [^\r\n]*PRIVATE KEY-----[\s\S]*?-----END [^\r\n]*PRIVATE KEY-----/gi, '[REDACTED_PRIVATE_KEY]')
    .replace(/\bBearer\s+[^\s,;"'}]+/gi, 'Bearer [REDACTED]')
    .replace(/\b(?:authorization|access_token|refresh_token|bootstrap_token|instance_invitation_token|ticket)\b\s*["']?\s*[:=]\s*["']?[^\s,"'}]+/gi, '[REDACTED_FIELD]')
    .replace(/[A-Za-z0-9_-]{40,}/g, '[REDACTED_LONG_SECRET]')
    .replaceAll(USERNAME, '[TEST_USERNAME]')
    .replaceAll(MASTER_PASSWORD, '[REDACTED_PASSWORD]');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 180000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${path.basename(command)} failed (${result.status})`);
  }
  return result.stdout || '';
}

function environmentSkip(reason, testName = 'WEB-RELAY-01') {
  console.log(`${testName} skipped: ${reason}`);
  process.exitCode = 2;
}

function localEth0Address() {
  const ip = spawnSync('ip', ['-o', '-4', 'addr', 'show', 'dev', 'eth0', 'scope', 'global'], {
    encoding: 'utf8', timeout: 5000,
  });
  const match = (ip.stdout || '').match(/\binet\s+(\d{1,3}(?:\.\d{1,3}){3})\//);
  if (ip.status !== 0 || !match || /^127\.|^169\.254\./.test(match[1])) return null;
  return match[1];
}

function readSshLoginAccount(name) {
  if (!/^[A-Za-z_][A-Za-z0-9_.-]*$/.test(name)) return null;
  const result = spawnSync('getent', ['passwd', name], {
    encoding: 'utf8', timeout: 3000,
  });
  if (result.status !== 0 || !result.stdout.trim()) return null;
  const fields = result.stdout.trim().split(':');
  if (fields.length < 7 || fields[0] !== name) return null;
  const uid = Number(fields[2]);
  const gid = Number(fields[3]);
  const shell = fields[6];
  const allowedShells = new Set(['/bin/bash', '/bin/sh', '/bin/dash', '/usr/bin/bash']);
  if (!Number.isInteger(uid) || uid <= 0 || !Number.isInteger(gid) || gid <= 0) return null;
  if (!allowedShells.has(shell) || !fs.existsSync(shell)) return null;
  const passwordStatus = spawnSync('passwd', ['-S', name], {
    encoding: 'utf8', timeout: 3000,
  });
  const statusFields = (passwordStatus.stdout || '').trim().split(/\s+/);
  // OpenSSH commonly rejects locked (`L`) and passwordless (`NP`) accounts
  // before public-key authentication. Reuse only accounts with an unlocked
  // password record; password auth remains disabled in the isolated sshd.
  if (passwordStatus.status !== 0 || statusFields[0] !== name || statusFields[1] !== 'P') {
    return null;
  }
  return { name, uid, gid, shell, home: fields[5] || '/' };
}

function resolveSshLoginAccount() {
  const configured = process.env.WEB_RELAY_SSH_USER;
  const candidates = configured ? [configured] : ['nobody', 'postgres', 'sonicbuild'];
  for (const name of candidates) {
    const account = readSshLoginAccount(name);
    if (account) return account;
  }
  return null;
}

function executableOnPath(name) {
  for (const directory of (process.env.PATH || '').split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch (_) {}
  }
  return null;
}

function preflight() {
  if (!fs.existsSync(path.join(WEB_ROOT, 'index.html')) ||
      !fs.existsSync(path.join(WEB_ROOT, 'main.dart.js'))) {
    return 'compiled Flutter Web bundle is missing';
  }
  if (process.env.WEB_RELAY_PEM_PREFLIGHT_ONLY === '1') return null;
  if (!fs.existsSync(SSHD) || !fs.existsSync(SSH_KEYGEN)) return 'OpenSSH sshd/ssh-keygen are unavailable';
  if (process.argv.includes('--keyboard-interactive-only')) {
    if (!executableOnPath('cc')) return 'C compiler cc is unavailable for the PAM fixture';
    if (!fs.existsSync('/etc/pam.d') ||
        !fs.existsSync('/usr/include/security/pam_appl.h') ||
        !fs.existsSync('/usr/include/security/pam_modules.h')) {
      return 'Linux-PAM service directory or development headers are unavailable';
    }
  }
  if (process.getuid && process.getuid() !== 0) return 'run this isolated sshd acceptance as root';
  if (!fs.existsSync('/run/sshd') || !fs.statSync('/run/sshd').isDirectory()) {
    return '/run/sshd is unavailable; the harness will not create or modify it';
  }
  if (!fs.existsSync('/root') || !fs.statSync('/root').isDirectory()) {
    return '/root is unavailable as a private executable chroot fixture parent';
  }
  for (const directory of ['/run', '/run/sshd']) {
    const stat = fs.statSync(directory);
    if (stat.uid !== 0 || (stat.mode & 0o022) !== 0) {
      return `${directory} must be root-owned and not group/world-writable for an OpenSSH chroot`;
    }
  }
  const rootHomeStat = fs.statSync('/root');
  if (rootHomeStat.uid !== 0 || (rootHomeStat.mode & 0o022) !== 0) {
    return '/root must be root-owned and not group/world-writable for an OpenSSH chroot';
  }
  if (!localEth0Address()) return 'a non-loopback eth0 IPv4 address is unavailable';
  const ssh = executableOnPath('ssh');
  if (!ssh) return 'OpenSSH ssh client is unavailable for the isolated login preflight';
  if (!executableOnPath('id') || !executableOnPath('ldd') ||
      !executableOnPath('getent') || !executableOnPath('mknod')) {
    return 'id, ldd, getent and mknod are required to construct the isolated SSH chroot';
  }
  sshLoginAccount = resolveSshLoginAccount();
  if (!sshLoginAccount) {
    if (process.env.WEB_RELAY_SSH_USER) {
      return 'WEB_RELAY_SSH_USER must name an unlocked non-root account with an interactive shell; it will not fall back to another identity';
    }
    const missing = ['useradd', 'userdel', 'groupdel', 'chpasswd', 'openssl', 'passwd', 'bash']
      .filter((name) => !executableOnPath(name));
    if (missing.length) {
      return `no usable existing non-root SSH account; temporary-account fixture prerequisites are missing: ${missing.join(', ')}`;
    }
    needsEphemeralSshAccount = true;
  }
  return null;
}

function createEphemeralSshLoginAccount(tempRoot) {
  // Keep the generated login under common 32-character account-name limits,
  // while retaining 64 random bits so a pre-existing account collision is
  // practically impossible. Still check the account and group databases before
  // mutating them, and verify their fixture-owned fields again during cleanup.
  const name = `atermius-relay-${RUN_ID.replaceAll('-', '').slice(0, 16)}`;
  const home = path.join(tempRoot, 'ssh-login-home');
  const useradd = executableOnPath('useradd');
  const openssl = executableOnPath('openssl');
  const chpasswd = executableOnPath('chpasswd');
  if (!useradd || !openssl || !chpasswd) {
    throw new Error('temporary non-root SSH account tools became unavailable');
  }

  const existingUser = spawnSync('getent', ['passwd', name], {
    encoding: 'utf8', timeout: 3000,
  });
  const existingGroup = spawnSync('getent', ['group', name], {
    encoding: 'utf8', timeout: 3000,
  });
  const userNameIsFree = existingUser.status === 2 && !existingUser.stdout.trim();
  const groupNameIsFree = existingGroup.status === 2 && !existingGroup.stdout.trim();
  if (existingUser.error || existingGroup.error || !userNameIsFree || !groupNameIsFree) {
    throw new Error('temporary SSH account name is already present or account lookup failed; refusing to reuse it');
  }

  // Set the cleanup marker before the first system mutation. If useradd fails
  // partway through, cleanup will only remove an account whose home and shell
  // still match this run's private fixture values.
  ephemeralSshAccountFixture = { name, home, uid: null, gid: null };
  run(useradd, [
    '--system', '--user-group', '--no-create-home', '--home-dir', home,
    '--shell', '/bin/bash', name,
  ], { timeout: 10000 });

  const randomPassword = crypto.randomBytes(48);
  const passwordLine = Buffer.from(`${randomPassword.toString('base64url')}\n`);
  randomPassword.fill(0);
  let hashResult;
  try {
    hashResult = spawnSync(openssl, ['passwd', '-6', '-stdin'], {
      input: passwordLine,
      encoding: 'utf8',
      timeout: 5000,
    });
  } finally {
    passwordLine.fill(0);
  }
  if (hashResult.error || hashResult.status !== 0 || !/^\$6\$/.test((hashResult.stdout || '').trim())) {
    throw new Error('could not provision an inaccessible random password hash for the temporary SSH account');
  }

  const credentialLine = Buffer.from(`${name}:${hashResult.stdout.trim()}\n`);
  let passwordSet;
  try {
    passwordSet = spawnSync(chpasswd, ['--encrypted'], {
      input: credentialLine,
      encoding: 'utf8',
      timeout: 5000,
    });
  } finally {
    credentialLine.fill(0);
  }
  if (passwordSet.error || passwordSet.status !== 0) {
    throw new Error('could not initialize the temporary SSH account password state');
  }

  const account = readSshLoginAccount(name);
  if (!account || account.uid === 0 || account.home !== home) {
    throw new Error('temporary SSH account did not resolve to the expected non-root identity');
  }
  ephemeralSshAccountFixture.uid = account.uid;
  ephemeralSshAccountFixture.gid = account.gid;
  fs.mkdirSync(home, { mode: 0o700 });
  fs.chmodSync(home, 0o700);
  fs.chownSync(home, account.uid, account.gid);
  return { ...account, ephemeral: true };
}

function cleanupEphemeralSshLoginAccount() {
  const fixture = ephemeralSshAccountFixture;
  if (!fixture) return;
  const { name, home } = fixture;
  if (!name.startsWith('atermius-relay-') || name.length > 32 ||
      !path.isAbsolute(home) || path.basename(home) !== 'ssh-login-home') {
    throw new Error('refusing to remove an SSH account outside the fixture namespace');
  }
  const lookup = spawnSync('getent', ['passwd', name], {
    encoding: 'utf8', timeout: 3000,
  });
  if (lookup.error || (lookup.status !== 0 && lookup.status !== 2)) {
    throw new Error('could not safely determine whether the temporary SSH account remains');
  }
  let gid = null;
  if (lookup.status === 0 && lookup.stdout.trim()) {
    const accountFields = lookup.stdout.trim().split(':');
    const uid = Number(accountFields[2]);
    gid = Number(accountFields[3]);
    if (accountFields[0] !== name || accountFields[5] !== home || accountFields[6] !== '/bin/bash' ||
        !Number.isInteger(uid) || uid <= 0 || !Number.isInteger(gid) || gid <= 0 ||
        (fixture.uid !== null && fixture.uid !== uid) ||
        (fixture.gid !== null && fixture.gid !== gid)) {
      throw new Error('refusing to clean up a temporary SSH account whose fixture identity changed');
    }

    // Chrooted SSH shells can become session leaders outside sshd's process
    // group. This UID is unique to this fixture, so terminate only its processes
    // before userdel removes the account and its private home directory.
    for (let attempt = 0; attempt < 3; attempt++) {
      for (const entry of fs.readdirSync('/proc')) {
        if (!/^\d+$/.test(entry)) continue;
        const pid = Number(entry);
        if (pid === process.pid) continue;
        let status;
        try {
          status = fs.readFileSync(`/proc/${entry}/status`, 'utf8');
        } catch (_) {
          continue;
        }
        const uidLine = status.match(/^Uid:\s+(\d+)/m);
        const state = status.match(/^State:\s+(\w+)/m)?.[1];
        if (!uidLine || Number(uidLine[1]) !== uid || state === 'Z' || state === 'X') continue;
        try { process.kill(pid, 'SIGKILL'); } catch (_) {}
      }
      const live = fs.readdirSync('/proc').some((entry) => {
        if (!/^\d+$/.test(entry)) return false;
        try {
          const status = fs.readFileSync(`/proc/${entry}/status`, 'utf8');
          const state = status.match(/^State:\s+(\w+)/m)?.[1];
          return Number(status.match(/^Uid:\s+(\d+)/m)?.[1]) === uid &&
            state !== 'Z' && state !== 'X';
        } catch (_) {
          return false;
        }
      });
      if (!live) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }

    const remaining = fs.readdirSync('/proc').some((entry) => {
      if (!/^\d+$/.test(entry)) return false;
      try {
        const status = fs.readFileSync(`/proc/${entry}/status`, 'utf8');
        const state = status.match(/^State:\s+(\w+)/m)?.[1];
        return Number(status.match(/^Uid:\s+(\d+)/m)?.[1]) === uid &&
          state !== 'Z' && state !== 'X';
      } catch (_) {
        return false;
      }
    });
    if (remaining) throw new Error('temporary SSH account still has a live process');

    const userdel = executableOnPath('userdel');
    if (!userdel) throw new Error('userdel is unavailable; temporary SSH account remains');
    const removed = spawnSync(userdel, ['--remove', name], {
      encoding: 'utf8', timeout: 10000,
    });
    if (removed.error || removed.status !== 0) {
      throw new Error('could not remove temporary SSH account and home directory');
    }
    const after = spawnSync('getent', ['passwd', name], {
      encoding: 'utf8', timeout: 3000,
    });
    if (after.error || (after.status !== 0 && after.status !== 2)) {
      throw new Error('could not verify temporary SSH account removal');
    }
    if (after.status === 0 && after.stdout.trim()) {
      throw new Error('temporary SSH account remains after userdel');
    }
  }

  const group = spawnSync('getent', ['group', name], {
    encoding: 'utf8', timeout: 3000,
  });
  if (group.error || (group.status !== 0 && group.status !== 2)) {
    throw new Error('could not safely determine whether the temporary SSH account group remains');
  }
  if (group.status === 0 && group.stdout.trim()) {
    const groupFields = group.stdout.trim().split(':');
    const groupGid = Number(groupFields[2]);
    const members = (groupFields[3] || '').split(',').filter(Boolean);
    if (gid === null || groupFields[0] !== name || groupGid !== gid || members.length !== 0) {
      throw new Error('temporary SSH account group has unexpected ownership or members');
    }
    const groupdel = executableOnPath('groupdel');
    if (!groupdel) throw new Error('groupdel is unavailable; temporary SSH group remains');
    const removedGroup = spawnSync(groupdel, [name], {
      encoding: 'utf8', timeout: 10000,
    });
    if (removedGroup.error || removedGroup.status !== 0) {
      throw new Error('could not remove temporary SSH account group');
    }
  }
  ephemeralSshAccountFixture = null;
}

function copyRuntimeDependencies(binaryPath, jailRoot) {
  const result = spawnSync('ldd', [binaryPath], {
    encoding: 'utf8', timeout: 5000,
  });
  if (result.status !== 0 || /=>\s+not found/.test(result.stdout || '')) {
    throw new Error(`could not resolve chroot runtime dependencies for ${path.basename(binaryPath)}`);
  }
  const dependencies = new Set();
  for (const line of (result.stdout || '').split('\n')) {
    const mapped = line.match(/=>\s+(\/\S+)/);
    const loader = line.match(/^\s*(\/\S+)\s+\(/);
    const dependency = mapped?.[1] || loader?.[1];
    if (dependency && fs.existsSync(dependency)) dependencies.add(dependency);
  }
  for (const dependency of dependencies) {
    const destination = path.join(jailRoot, dependency.slice(1));
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
    fs.copyFileSync(dependency, destination);
    fs.chmodSync(destination, fs.statSync(dependency).mode & 0o755);
  }
}

function copyBinaryToJail(binaryPath, jailRoot) {
  const destination = path.join(jailRoot, binaryPath.replace(/^\/+/, ''));
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
  fs.copyFileSync(binaryPath, destination);
  fs.chmodSync(destination, fs.statSync(binaryPath).mode & 0o755);
  copyRuntimeDependencies(binaryPath, jailRoot);
}

function createCharacterDeviceInJail(jailRoot, relativePath, major, minor) {
  const destination = path.join(jailRoot, relativePath);
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
  const mknod = executableOnPath('mknod');
  if (!mknod) throw new Error('mknod became unavailable while creating the SSH fixture');
  const result = spawnSync(mknod, [destination, 'c', String(major), String(minor)], {
    encoding: 'utf8',
    timeout: 5000,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`could not create required SSH fixture device /${relativePath}`);
  }
  const stat = fs.statSync(destination);
  if (!stat.isCharacterDevice() || stat.rdev !== ((major << 8) | minor)) {
    throw new Error(`created SSH fixture device has the wrong type: /${relativePath}`);
  }
  fs.chmodSync(destination, 0o666);
}

function createSshdJail(jailBase, account) {
  const jailRoot = path.join(jailBase, 'root');
  const remoteRoot = path.join(jailRoot, 'tmp', 'remote');
  fs.mkdirSync(jailRoot, { recursive: true, mode: 0o755 });
  fs.chmodSync(jailRoot, 0o755);
  createCharacterDeviceInJail(jailRoot, 'dev/null', 1, 3);
  createCharacterDeviceInJail(jailRoot, 'dev/tty', 5, 0);
  fs.mkdirSync(path.join(jailRoot, 'tmp'), { recursive: true, mode: 0o1777 });
  fs.chmodSync(path.join(jailRoot, 'tmp'), 0o1777);

  const shellDestination = path.join(jailRoot, account.shell.slice(1));
  fs.mkdirSync(path.dirname(shellDestination), { recursive: true, mode: 0o755 });
  fs.copyFileSync(fs.realpathSync(account.shell), shellDestination);
  fs.chmodSync(shellDestination, 0o755);
  copyRuntimeDependencies(fs.realpathSync(account.shell), jailRoot);
  copyBinaryToJail(executableOnPath('id'), jailRoot);
  for (const utility of ['cat', 'base64', 'tr']) {
    const binaryPath = executableOnPath(utility);
    if (!binaryPath) {
      throw new Error(`required shell integration utility is unavailable: ${utility}`);
    }
    copyBinaryToJail(binaryPath, jailRoot);
  }

  const homeRelative = path.posix.normalize(account.home.replace(/^\/+/, ''));
  if (homeRelative === '..' || homeRelative.startsWith('../')) {
    throw new Error('non-root SSH fixture account has an unsafe home path');
  }
  const homeInJail = path.join(jailRoot, homeRelative);
  fs.mkdirSync(homeInJail, { recursive: true, mode: 0o755 });
  fs.chmodSync(homeInJail, 0o755);
  const etcRoot = path.join(jailRoot, 'etc');
  fs.mkdirSync(etcRoot, { recursive: true, mode: 0o755 });
  fs.writeFileSync(
    path.join(etcRoot, 'passwd'),
    `${account.name}:x:${account.uid}:${account.gid}:Relay fixture:${account.home}:${account.shell}\n`,
    { mode: 0o444 },
  );
  fs.writeFileSync(
    path.join(etcRoot, 'group'),
    `relay-fixture:x:${account.gid}:\n`,
    { mode: 0o444 },
  );
  fs.writeFileSync(
    path.join(etcRoot, 'nsswitch.conf'),
    'passwd: files\ngroup: files\nhosts: files\n',
    { mode: 0o444 },
  );

  fs.mkdirSync(remoteRoot, { recursive: true, mode: 0o700 });
  fs.chmodSync(remoteRoot, 0o700);
  fs.chownSync(remoteRoot, account.uid, account.gid);
  return { jailRoot, remoteRoot };
}

function unusedPort(address) {
  return new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen(0, address, () => {
      const port = listener.address().port;
      listener.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

async function waitReady(baseUrl, processHandle, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'no response';
  while (Date.now() < deadline) {
    if (processHandle.exitCode !== null) throw new Error(`server exited early (${processHandle.exitCode})`);
    try {
      const response = await fetch(`${baseUrl}/health/ready`, { signal: AbortSignal.timeout(1200) });
      if (response.status === 200) return;
      last = `readiness HTTP ${response.status}`;
    } catch (error) { last = error.name || 'network error'; }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`server readiness timed out (${last})`);
}

async function waitForPort(address, port, processHandle, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (processHandle && processHandle.exitCode !== null) {
      throw new Error(`temporary sshd exited early (${processHandle.exitCode})`);
    }
    try {
      await new Promise((resolve, reject) => {
        const conn = net.createConnection({ host: address, port });
        conn.once('connect', () => { conn.destroy(); resolve(); });
        conn.once('error', reject);
        conn.setTimeout(500, () => conn.destroy(new Error('connect timeout')));
      });
      return;
    } catch (_) { await new Promise((resolve) => setTimeout(resolve, 150)); }
  }
  throw new Error('temporary sshd did not begin listening on its configured fixture address');
}

function verifyNonRootSshLogin({ address, port, keyPath, account }) {
  const ssh = process.env.SSH_PATH || '/usr/bin/ssh';
  const result = spawnSync(ssh, [
    '-F', '/dev/null', '-p', String(port),
    '-i', keyPath,
    '-o', 'BatchMode=yes',
    '-o', 'PreferredAuthentications=publickey',
    '-o', 'PasswordAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=5',
    `${account.name}@${address}`,
    'id -u',
  ], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 8000,
    maxBuffer: 4096,
    env: process.env,
  });
  const remoteUid = (result.stdout || '').trim();
  const safeSshDiagnostic = {
    sshErrorCode: result.error?.code || null,
    sshSignal: result.signal || null,
    sshExitStatus: Number.isInteger(result.status) ? result.status : null,
    sshTimedOut: result.error?.code === 'ETIMEDOUT',
    remoteCommandReturnedExpectedUid: remoteUid === String(account.uid),
    remoteCommandReturnedNumericUid: /^\d+$/.test(remoteUid),
    expectedUidIsNonRoot: account.uid > 0,
  };
  if (result.error || result.status !== 0) {
    const stderr = result.stderr || '';
    let stderrCategory = 'other';
    if (/permission denied \(publickey\)/i.test(stderr)) stderrCategory = 'public_key_auth_rejected';
    else if (/could not chdir|home directory.*permission denied/i.test(stderr)) stderrCategory = 'remote_home_directory_unavailable';
    else if (/bash:.*permission denied/i.test(stderr)) stderrCategory = 'remote_bash_permission_denied';
    else if (/(?:^|\/)id:.*permission denied/i.test(stderr)) stderrCategory = 'remote_id_permission_denied';
    else if (/permission denied/i.test(stderr)) stderrCategory = 'remote_command_permission_denied';
    else if (/connection (?:closed|reset)|broken pipe/i.test(stderr)) stderrCategory = 'connection_closed';
    else if (/could not resolve|name or service not known/i.test(stderr)) stderrCategory = 'name_resolution';
    else if (/host key verification failed/i.test(stderr)) stderrCategory = 'host_key_verification';
    else if (/no such file|failed to execute|exec request failed/i.test(stderr)) stderrCategory = 'missing_remote_runtime';
    else if (/connection timed out|operation timed out/i.test(stderr)) stderrCategory = 'connection_timeout';
    const diagnostic = {
      ...safeSshDiagnostic,
      sshStderrCategory: stderrCategory,
    };
    const error = new Error('isolated SSHD public-key login or jailed command preflight failed');
    error.safePreflightDiagnostic = diagnostic;
    throw error;
  }
  if (remoteUid !== String(account.uid) || account.uid === 0) {
    const error = new Error('isolated SSH preflight did not execute as the expected non-root UID');
    error.safePreflightDiagnostic = safeSshDiagnostic;
    throw error;
  }
}

function safeChrootCommandSummary(jailRoot, account) {
  const chroot = executableOnPath('chroot');
  if (!chroot) return { available: false };
  const result = spawnSync(chroot, [
    '--userspec', `${account.uid}:${account.gid}`, jailRoot,
    account.shell, '-c', '/usr/bin/id -u',
  ], { encoding: 'utf8', timeout: 5000, maxBuffer: 4096 });
  const uid = (result.stdout || '').trim();
  const stderr = result.stderr || '';
  let stderrCategory = 'none';
  if (result.error) stderrCategory = result.error.code || 'spawn_error';
  else if (/(?:^|\/)id:.*permission denied/i.test(stderr)) stderrCategory = 'id_permission_denied';
  else if (/bash:.*permission denied/i.test(stderr)) stderrCategory = 'bash_permission_denied';
  else if (/permission denied/i.test(stderr)) stderrCategory = 'permission_denied';
  else if (/no such file|not found/i.test(stderr)) stderrCategory = 'missing_runtime';
  return {
    available: true,
    exitStatus: Number.isInteger(result.status) ? result.status : null,
    uidMatchesExpected: uid === String(account.uid),
    uidIsNumeric: /^\d+$/.test(uid),
    stderrCategory,
  };
}

function waitForBrowserDownload(context, page, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const observedPages = new Map();
    let timer;
    const finish = (error, download) => {
      if (timer) clearTimeout(timer);
      context.off('page', observePage);
      context.off('close', onContextClose);
      for (const [candidate, handler] of observedPages) {
        candidate.off('download', handler);
      }
      observedPages.clear();
      if (error) reject(error);
      else resolve(download);
    };
    const observePage = (candidate) => {
      if (observedPages.has(candidate)) return;
      const handler = (download) => finish(null, download);
      observedPages.set(candidate, handler);
      candidate.on('download', handler);
    };
    const onContextClose = () => finish(new Error('browser context closed before download'));
    observePage(page);
    context.on('page', observePage);
    context.on('close', onContextClose);
    timer = setTimeout(() => finish(new Error('UI did not produce a browser download')), timeoutMs);
  });
}

async function readTemporarySshBanner(address, port, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host: address, port });
    let bytes = Buffer.alloc(0);
    let finished = false;
    const finish = (matched) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      resolve(matched);
    };
    socket.setTimeout(timeoutMs, () => finish(false));
    socket.once('error', () => finish(false));
    socket.on('data', (chunk) => {
      if (bytes.length + chunk.length > 512) return finish(false);
      bytes = Buffer.concat([bytes, chunk]);
      const lineEnd = bytes.indexOf(0x0a);
      if (lineEnd >= 0) {
        const line = bytes.subarray(0, lineEnd).toString('ascii').replace(/\r$/, '');
        finish(line.startsWith('SSH-2.0-'));
      }
    });
  });
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
      const state = fields[0];
      const processGroup = Number(fields[2]);
      if (processGroup === groupId && state !== 'Z' && state !== 'X') return true;
    }
    return false;
  } catch (error) {
    // `/proc` is available in the Linux sshd environment. If it is not
    // readable, conservatively treat a signalable process group as alive.
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
    if (error.code !== 'ESRCH') throw new Error(`could not send ${signal} to child process group`);
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

async function stopGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  throw new Error('child process group remained alive after bounded TERM/KILL cleanup');
}

async function terminalShareTitleEvidence(page, title) {
  return page.evaluate((expected) => {
    const labels = [...document.querySelectorAll('[aria-label]')]
      .map((element) => element.getAttribute('aria-label') || '')
      .filter((label) => label.includes(expected));
    return {
      count: labels.length,
      visible: labels.length > 0 && (document.body.innerText || '').includes(expected),
    };
  }, title).catch(() => ({ count: 0, visible: false }));
}

async function waitText(page, text, timeout = 15000) {
  if (text === 'Shared terminal · read only') {
    await page.getByRole('button', {
      name: 'Leave shared terminal', exact: true,
    }).waitFor({ state: 'visible', timeout });
    return;
  }
  if (text === 'Shared terminal · host-approved control') {
    await page.getByRole('textbox', {
      name: 'Host-approved terminal input', exact: true,
    }).waitFor({ state: 'visible', timeout });
    return;
  }
  await page.getByText(text, { exact: false }).first().waitFor({ state: 'visible', timeout });
}

async function syncNow(page, actor = 'browser') {
  const syncButton = page.getByRole('button', {
    name: /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error|Read-only)$/,
  }).first();
  await syncButton.waitFor({ state: 'visible', timeout: 15000 });
  const currentLabel = await syncButton.getAttribute('aria-label') ||
    (await syncButton.innerText()).trim();
  console.log('manual sync requested', JSON.stringify({ actor, currentLabel }));
  let syncResponseStatus = null;
  if (currentLabel !== 'Syncing') {
    const changesResponse = page.waitForResponse((response) => {
      try {
        return new URL(response.url()).pathname.endsWith('/changes');
      } catch (_) {
        return false;
      }
    }, { timeout: 45000 }).catch(() => null);
    await syncButton.click();
    const response = await changesResponse;
    assertThat(response && response.status() === 200,
      `${actor} manual sync did not complete an HTTP 200 changes request`);
    syncResponseStatus = response.status();
  }
  await page.getByRole('button', { name: 'Idle', exact: true }).waitFor({
    state: 'visible',
    timeout: 45000,
  });
  console.log('manual sync completed', JSON.stringify({ actor, syncResponseStatus }));
}

async function waitForLocatorAttribute(locator, attribute, expected, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let observed = null;
  while (Date.now() < deadline) {
    observed = await locator.getAttribute(attribute).catch(() => null);
    if (observed === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`switch did not reach ${attribute}=${expected} (observed ${observed})`);
}

function fixtureFileSequenceEvidence(filePath, expectedLines) {
  let bytes;
  try {
    bytes = fs.readFileSync(filePath);
    const lines = bytes.toString('utf8').split(/\r?\n/);
    if (lines.at(-1) === '') lines.pop();
    return {
      exists: true,
      lineCount: lines.length,
      expectedSequenceMatches: lines.length === expectedLines.length &&
        lines.every((line, index) => line === expectedLines[index]),
      expectedLineOccurrences: expectedLines.map((expected) =>
        lines.filter((line) => line === expected).length),
      byteLength: bytes.length,
    };
  } catch (_) {
    return {
      exists: false,
      lineCount: 0,
      expectedSequenceMatches: false,
      expectedLineOccurrences: expectedLines.map(() => 0),
      byteLength: null,
    };
  } finally {
    bytes?.fill(0);
  }
}

async function terminalTabButton(page, hostName, state) {
  const locator = page.getByRole('button', {
    name: `${hostName} terminal tab, connected, ${state}`,
    exact: true,
  });
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  assertThat(await locator.count() === 1, 'terminal tab semantics were ambiguous');
  return locator;
}

async function safeTerminalTabStateDiagnostics(page, firstHostName, secondHostName) {
  const count = async (hostName, state) => page.getByRole('button', {
    name: `${hostName} terminal tab, connected, ${state}`,
    exact: true,
  }).count().catch(() => null);
  const [firstActive, firstInactive, secondActive, secondInactive, connectedTabs] =
    await Promise.all([
      count(firstHostName, 'active'),
      count(firstHostName, 'inactive'),
      count(secondHostName, 'active'),
      count(secondHostName, 'inactive'),
      page.getByRole('button', {
        name: / terminal tab, connected, (?:active|inactive)$/,
      }).count().catch(() => null),
    ]);
  return { firstActive, firstInactive, secondActive, secondInactive, connectedTabs };
}

async function safeTerminalTabLifecycleDiagnostics(page, firstHostName, secondHostName) {
  const states = ['connecting', 'connected', 'disconnected', 'failed'];
  const count = async (hostName, tabState, activityState) => page.getByRole('button', {
    name: `${hostName} terminal tab, ${tabState}, ${activityState}`,
    exact: true,
  }).count().catch(() => null);
  const stateCounts = async (hostName) => Object.fromEntries(await Promise.all(
    states.map(async (tabState) => {
      const [active, inactive] = await Promise.all([
        count(hostName, tabState, 'active'),
        count(hostName, tabState, 'inactive'),
      ]);
      return [tabState, { active, inactive }];
    }),
  ));
  const [firstStates, secondStates, totalTabs] = await Promise.all([
    stateCounts(firstHostName),
    stateCounts(secondHostName),
    page.getByRole('button', {
      name: / terminal tab, (?:connecting|connected|disconnected|failed), (?:active|inactive)$/,
    }).count().catch(() => null),
  ]);
  const connectedValues = [
    firstStates.connected.active,
    firstStates.connected.inactive,
    secondStates.connected.active,
    secondStates.connected.inactive,
  ];
  const connectedTabs = connectedValues.every(Number.isInteger)
    ? connectedValues.reduce((sum, value) => sum + value, 0)
    : null;
  return {
    firstActive: firstStates.connected.active,
    firstInactive: firstStates.connected.inactive,
    secondActive: secondStates.connected.active,
    secondInactive: secondStates.connected.inactive,
    connectedTabs,
    firstStates,
    secondStates,
    totalTabs,
  };
}

async function safeBrowserRelayCloseMetadata(page) {
  return page.evaluate(() => (window.__relaySocketCloseMetadata || [])
    .slice(-8)
    .map((item) => ({
      code: Number.isInteger(item.code) ? item.code : null,
      category: [
        'normal', 'protocol_error', 'policy_rejection', 'server_error',
        'abnormal_transport', 'other',
      ].includes(item.category) ? item.category : 'other',
      wasClean: typeof item.wasClean === 'boolean' ? item.wasClean : null,
      reasonLength: Number.isInteger(item.reasonLength)
        ? Math.max(0, Math.min(512, item.reasonLength))
        : null,
    })));
}

function safeSshDiagnosticSummary(entries) {
  const categories = entries.slice(-20).map((entry) => {
    const value = String(entry || '').toLowerCase();
    if (/host.?key|fingerprint|known.?host/.test(value)) return 'host_key';
    if (/forward|jump.?host|direct.?tcp/.test(value)) return 'forwarding';
    if (/auth|public.?key|password/.test(value)) return 'authentication';
    if (/relay|websocket|socket/.test(value)) return 'relay_transport';
    if (/timeout|deadline/.test(value)) return 'timeout';
    if (/channel|session/.test(value)) return 'ssh_channel';
    return 'other';
  });
  return { totalEntries: entries.length, recentCategories: categories };
}

async function safeTerminalRouteInputDiagnostics(
  page,
  { activeHostName = null, inactiveHostName = null } = {},
) {
  const routeHeading = page.getByText('Terminal workspace', { exact: true });
  const terminalInput = page.getByRole('textbox', {
    name: 'SSH terminal input',
    exact: true,
  });
  const [routeHeadingCount, routeHeadingVisible, inputCount, inputVisible,
    inputFocusedAttribute, activeTabCount, inactiveTabCount] = await Promise.all([
    routeHeading.count().catch(() => null),
    routeHeading.isVisible().catch(() => false),
    terminalInput.count().catch(() => null),
    terminalInput.isVisible().catch(() => false),
    terminalInput.getAttribute('aria-focused').catch(() => null),
    activeHostName == null ? Promise.resolve(null) : page.getByRole('button', {
      name: `${activeHostName} terminal tab, connected, active`, exact: true,
    }).count().catch(() => null),
    inactiveHostName == null ? Promise.resolve(null) : page.getByRole('button', {
      name: `${inactiveHostName} terminal tab, connected, inactive`, exact: true,
    }).count().catch(() => null),
  ]);
  return {
    routeHeadingCount,
    routeHeadingVisible,
    activeTabCount,
    inactiveTabCount,
    terminalInputSemanticCount: inputCount,
    terminalInputSemanticVisible: inputVisible,
    terminalInputSemanticFocused: inputFocusedAttribute === 'true'
      ? true
      : inputFocusedAttribute === 'false' ? false : null,
  };
}

async function waitForTerminalRouteInputReady(
  page,
  expected = {},
  timeoutMs = 15000,
) {
  const deadline = Date.now() + timeoutMs;
  let evidence = null;
  while (Date.now() < deadline) {
    evidence = await safeTerminalRouteInputDiagnostics(page, expected);
    const routeReady = evidence.routeHeadingVisible &&
      evidence.routeHeadingCount === 1;
    const activeTabReady = expected.activeHostName == null ||
      evidence.activeTabCount === 1;
    const inactiveTabReady = expected.inactiveHostName == null ||
      evidence.inactiveTabCount === 1;
    const inputReady = evidence.terminalInputSemanticCount === 1 &&
      evidence.terminalInputSemanticVisible;
    if (routeReady && activeTabReady && inactiveTabReady && inputReady) {
      return evidence;
    }
    await page.waitForTimeout(100);
  }
  evidence = await safeTerminalRouteInputDiagnostics(page, expected);
  console.log('terminal route/input prerequisite timeout safe diagnostic', JSON.stringify({
    expectedActiveTab: Boolean(expected.activeHostName),
    expectedInactiveTab: Boolean(expected.inactiveHostName),
    ...evidence,
  }));
  throw new Error('Terminal workspace route, expected tab state, or SSH terminal input semantics did not become ready');
}

async function installSafePageInputCounters(page) {
  await page.evaluate(() => {
    const cap = 10000;
    const counters = {
      keydown: 0,
      beforeinput: 0,
      input: 0,
      beforeinputDataUtf16Units: 0,
      inputTargetKinds: { input: 0, textarea: 0, other: 0 },
    };
    const increment = (name) => {
      counters[name] = Math.min(cap, counters[name] + 1);
    };
    const handlers = {
      keydown: () => increment('keydown'),
      beforeinput: (event) => {
        increment('beforeinput');
        counters.beforeinputDataUtf16Units = Math.min(
          cap,
          counters.beforeinputDataUtf16Units +
            (typeof event.data === 'string' ? event.data.length : 0),
        );
      },
      input: (event) => {
        increment('input');
        const tag = String(event.target?.tagName || '').toLowerCase();
        const kind = tag === 'input' ? 'input' : tag === 'textarea' ? 'textarea' : 'other';
        counters.inputTargetKinds[kind] = Math.min(
          cap,
          counters.inputTargetKinds[kind] + 1,
        );
      },
    };
    document.addEventListener('keydown', handlers.keydown, true);
    document.addEventListener('beforeinput', handlers.beforeinput, true);
    document.addEventListener('input', handlers.input, true);
    window.__webRelaySafeInputCounters = { counters, handlers };
  });
}

async function readAndRemoveSafePageInputCounters(page) {
  return page.evaluate(() => {
    const state = window.__webRelaySafeInputCounters;
    if (!state) return { available: false };
    document.removeEventListener('keydown', state.handlers.keydown, true);
    document.removeEventListener('beforeinput', state.handlers.beforeinput, true);
    document.removeEventListener('input', state.handlers.input, true);
    delete window.__webRelaySafeInputCounters;
    return { available: true, ...state.counters };
  }).catch(() => ({ available: false }));
}

async function safePageInputFocusState(page) {
  return page.evaluate(() => {
    let element = document.activeElement;
    for (let depth = 0; depth < 8 && element?.shadowRoot?.activeElement; depth++) {
      element = element.shadowRoot.activeElement;
    }
    const tag = String(element?.tagName || '').toUpperCase();
    const role = element?.getAttribute?.('role') || '';
    const ariaLabel = element?.getAttribute?.('aria-label') || '';
    const inputType = tag === 'INPUT'
      ? String(element?.getAttribute?.('type') || 'text').toLowerCase()
      : tag === 'TEXTAREA' ? 'textarea' : 'other';
    const visibleInputs = [];
    const roots = [document];
    for (let index = 0; index < roots.length && index < 32; index++) {
      const root = roots[index];
      for (const candidate of root.querySelectorAll('input,textarea')) {
        if (candidate.getClientRects().length > 0) visibleInputs.push(candidate);
      }
      for (const candidate of root.querySelectorAll('*')) {
        if (candidate.shadowRoot) roots.push(candidate.shadowRoot);
      }
    }
    return {
      pageFocused: document.hasFocus(),
      activeTag: ['BODY', 'CANVAS', 'INPUT', 'TEXTAREA'].includes(tag) ? tag : 'OTHER',
      activeIsInput: tag === 'INPUT',
      activeIsTextarea: tag === 'TEXTAREA',
      activeIsCanvas: tag === 'CANVAS',
      activeInputType: ['text', 'search', 'password', 'email', 'url', 'number', 'textarea', 'other'].includes(inputType)
        ? inputType : 'other',
      activeLabelIsTerminalInput: ariaLabel === 'SSH terminal input',
      activeLabelIsControllerInput:
        ariaLabel === 'Host-approved terminal input',
      activeElementHasId: Boolean(element?.id),
      activeRole: ['textbox', 'application', ''].includes(role) ? (role || 'none') : 'other',
      activeElementFocused: Boolean(element && element === document.activeElement),
      canvasCount: Math.min(1000, document.querySelectorAll('canvas').length),
      visibleInputCount: Math.min(1000, visibleInputs.length),
    };
  }).catch(() => ({ available: false }));
}

function safeRelayFrameCounts(socket) {
  const summarize = (frames) => {
    const counts = { total: frames?.length || 0, text: 0, binary: 0, other: 0 };
    for (const frame of frames || []) {
      if (frame?.kind === 'text') counts.text += 1;
      else if (frame?.kind === 'binary') counts.binary += 1;
      else counts.other += 1;
    }
    return counts;
  };
  return {
    opened: Boolean(socket?.opened),
    closed: Boolean(socket?.closed),
    sent: summarize(socket?.sentFrames),
    received: summarize(socket?.receivedFrames),
  };
}

function safeXtermEventCounts(entries) {
  const counts = {
    key: 0,
    keyHandled: 0,
    action: 0,
    actionHandled: 0,
    connectionClosed: 0,
    restoreScheduled: 0,
    restoreRun: 0,
  };
  for (const entry of entries || []) {
    if (entry.startsWith('ATERMIUS_XTERM_KEY_HANDLED:')) counts.keyHandled += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_KEY:')) counts.key += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_ACTION_HANDLED:')) counts.actionHandled += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_ACTION:')) counts.action += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_CONNECTION_CLOSED:')) counts.connectionClosed += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_RESTORE_SCHEDULED:')) counts.restoreScheduled += 1;
    else if (entry.startsWith('ATERMIUS_XTERM_RESTORE_RUN:')) counts.restoreRun += 1;
  }
  return counts;
}

function safeCounterDelta(before, after, keys) {
  const delta = {};
  for (const key of keys) delta[key] = (after?.[key] || 0) - (before?.[key] || 0);
  return delta;
}

async function waitForTerminalConnectionOrTrust(page, hostName, timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  const escapedHostName = hostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const connectedTab = page.getByRole('button', {
    name: `${hostName} terminal tab, connected, active`,
    exact: true,
  });
  const failedTab = page.getByRole('button', {
    name: new RegExp(`^${escapedHostName} terminal tab, failed, (?:active|inactive)$`),
  });
  const disconnectedTab = page.getByRole('button', {
    name: new RegExp(`^${escapedHostName} terminal tab, disconnected, (?:active|inactive)$`),
  });
  const trustButton = page.getByRole('button', {
    name: 'Trust after verification',
    exact: true,
  });
  while (Date.now() < deadline) {
    if (await trustButton.isVisible().catch(() => false)) return 'trust_prompt';
    if (await connectedTab.isVisible().catch(() => false)) return 'connected';
    if (await failedTab.count().catch(() => 0) > 0) return 'failed';
    if (await disconnectedTab.count().catch(() => 0) > 0) return 'disconnected';
    const signal = await page.evaluate(() => {
      const text = document.body.innerText || '';
      if (text.includes('SSH 主机密钥与已保存指纹不同，连接已拒绝')) return 'host_key_rejected';
      if (/TimeoutException/i.test(text) || text.includes('SSH 中继连接超时。')) return 'timeout_exception';
      if (text.includes('无法建立 SSH 中继 WebSocket。')) return 'relay_transport_error';
      if (text.includes('SSH 中继票据已失效')) return 'relay_ticket_error';
      return null;
    });
    if (signal) return signal;
    await page.waitForTimeout(100);
  }
  return 'deadline_without_connection';
}

async function waitForRemoteMarker(filePath, marker, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (fs.readFileSync(filePath, 'utf8').trimEnd() === marker) return true;
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

function fileTreeContainsMarkers(roots, markers) {
  const needles = markers.map((marker) => Buffer.from(marker, 'utf8'));
  const pending = [...roots];
  try {
    while (pending.length) {
      const current = pending.pop();
      if (!current || !fs.existsSync(current)) continue;
      const stat = fs.lstatSync(current);
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) {
        for (const name of fs.readdirSync(current)) pending.push(path.join(current, name));
        continue;
      }
      if (!stat.isFile() || stat.size > 128 * 1024 * 1024) continue;
      const bytes = fs.readFileSync(current);
      try {
        if (needles.some((needle) => bytes.includes(needle))) return true;
      } finally {
        bytes.fill(0);
      }
    }
    return false;
  } finally {
    for (const needle of needles) needle.fill(0);
  }
}

async function browserStorageContainsMarkers(page, markers) {
  return page.evaluate(async (needles) => {
    const fragments = [];
    const maxRecords = 5000;
    let scannedRecords = 0;
    const add = (value) => {
      if (typeof value === 'string') fragments.push(value);
      else if (value instanceof ArrayBuffer) {
        fragments.push(new TextDecoder().decode(new Uint8Array(value)));
      } else if (ArrayBuffer.isView(value)) {
        fragments.push(new TextDecoder().decode(
          new Uint8Array(value.buffer, value.byteOffset, value.byteLength),
        ));
      }
    };
    const visit = async (value, seen = new WeakSet(), depth = 0) => {
      if (depth > 12 || value == null) return;
      add(value);
      if (typeof value !== 'object') return;
      if (value instanceof Blob) {
        add(await value.text().catch(() => ''));
        return;
      }
      if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return;
      if (seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) {
        for (const item of value) await visit(item, seen, depth + 1);
      } else {
        for (const [key, item] of Object.entries(value)) {
          add(key);
          await visit(item, seen, depth + 1);
        }
      }
    };
    const requestValue = (request) => new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('IndexedDB read failed'));
    });

    fragments.push(document.body?.innerText || '');
    for (const element of document.querySelectorAll('input,textarea')) {
      add(element.value || '');
    }
    for (const storage of [window.localStorage, window.sessionStorage]) {
      for (let index = 0; index < storage.length; index += 1) {
        const key = storage.key(index);
        add(key || '');
        add(key == null ? '' : storage.getItem(key) || '');
      }
    }

    let indexedDbNames = 0;
    if (typeof indexedDB.databases === 'function') {
      const databases = await indexedDB.databases();
      indexedDbNames = databases.length;
      for (const info of databases) {
        if (!info.name || scannedRecords >= maxRecords) continue;
        let database;
        try {
          database = await new Promise((resolve, reject) => {
            const request = indexedDB.open(info.name);
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error || new Error('IndexedDB open failed'));
            request.onblocked = () => reject(new Error('IndexedDB open blocked'));
          });
          const storeNames = [...database.objectStoreNames];
          for (const storeName of storeNames) {
            if (scannedRecords >= maxRecords) break;
            const transaction = database.transaction([storeName], 'readonly');
            const store = transaction.objectStore(storeName);
            const valuesRequest = store.getAll();
            const keysRequest = store.getAllKeys();
            const [values, keys] = await Promise.all([
              requestValue(valuesRequest), requestValue(keysRequest),
            ]);
            for (const value of values) {
              if (scannedRecords++ >= maxRecords) break;
              await visit(value);
            }
            for (const key of keys) {
              if (scannedRecords++ >= maxRecords) break;
              await visit(key);
            }
          }
          database.close();
        } catch (_) {
          database?.close();
          return { complete: false, found: [], indexedDbNames, scannedRecords };
        }
      }
    } else {
      return { complete: false, found: [], indexedDbNames, scannedRecords };
    }
    const serialized = fragments.join('\n');
    return {
      complete: true,
      found: needles.map((needle, index) =>
        serialized.includes(needle) ? index : -1).filter((index) => index >= 0),
      indexedDbNames,
      scannedRecords,
    };
  }, markers);
}

async function waitForRelayOutputFrame(page, socket, baseline, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (socket && socket.receivedFrames.length > baseline) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function waitForRelaySocketQuiet(page, socket, quietMs = 500, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let observedReceivedCount = socket?.receivedFrames.length ?? 0;
  let observedSentCount = socket?.sentFrames.length ?? 0;
  let quietSince = Date.now();
  while (Date.now() < deadline) {
    await page.waitForTimeout(100);
    const currentReceivedCount = socket?.receivedFrames.length ?? 0;
    const currentSentCount = socket?.sentFrames.length ?? 0;
    if (currentReceivedCount !== observedReceivedCount ||
        currentSentCount !== observedSentCount) {
      observedReceivedCount = currentReceivedCount;
      observedSentCount = currentSentCount;
      quietSince = Date.now();
    } else if (Date.now() - quietSince >= quietMs) {
      return true;
    }
  }
  return false;
}

async function focusActiveTerminalForInput(
  page,
  user,
  address,
  expectedTerminalState = {},
) {
  await waitForTerminalRouteInputReady(page, expectedTerminalState, 10000);
  const header = page.getByText(`${user}@${address}`, { exact: true }).first();
  await header.waitFor({ state: 'visible', timeout: 15000 });
  const headerBox = await header.boundingBox();
  const viewport = page.viewportSize() || { width: 1440, height: 1000 };
  assertThat(headerBox, 'active terminal header was not measurable');
  const top = Math.ceil(headerBox.y + headerBox.height + 8);
  const width = Math.max(0, Math.round(viewport.width - headerBox.x - 16));
  const height = Math.max(0, Math.round(viewport.height - top - 48));
  assertThat(width > 100 && height > 100, 'active terminal surface has no usable bounds');
  await page.mouse.click(
    Math.round(headerBox.x + width / 2),
    Math.round(top + height / 2),
  );
  await page.waitForTimeout(300);
  const routeInputAfterClick = await safeTerminalRouteInputDiagnostics(
    page,
    expectedTerminalState,
  );
  const focusState = await safePageInputFocusState(page);
  const terminalInput = page.getByRole('textbox', {
    name: 'SSH terminal input', exact: true,
  });
  const terminalInputSemanticsFocused = await terminalInput
    .getAttribute('aria-focused')
    .then((value) => value === 'true')
    .catch(() => false);
  console.log('terminal surface click focus safe evidence', JSON.stringify({
    routeInputAfterClick,
    expectedActiveTabPresent: expectedTerminalState.activeHostName != null,
    expectedInactiveTabPresent: expectedTerminalState.inactiveHostName != null,
    terminalInputSemanticsFocused,
    ...focusState,
  }));
  assertThat(routeInputAfterClick.routeHeadingVisible &&
    routeInputAfterClick.terminalInputSemanticCount === 1 &&
    routeInputAfterClick.terminalInputSemanticVisible,
  'terminal command blocked because the route or SSH terminal input semantics disappeared after surface focus');
  assertThat(terminalInputSemanticsFocused ||
    ((focusState.activeIsInput || focusState.activeIsTextarea) &&
      focusState.activeLabelIsTerminalInput),
  'terminal command blocked because focus is not on the SSH terminal input');
}

async function sendCommandToActiveTerminal(
  page,
  user,
  address,
  command,
  expectedTerminalState = {},
) {
  await focusActiveTerminalForInput(page, user, address, expectedTerminalState);
  await page.keyboard.type(command, { delay: 5 });
  await page.keyboard.press('Enter');
}

async function pasteClipboardToActiveTerminal(
  page,
  user,
  address,
  expectedTerminalState = {},
) {
  await focusActiveTerminalForInput(page, user, address, expectedTerminalState);
  await page.keyboard.press('Control+V');
}

const terminalFingerprintEvidenceByPage = new WeakMap();
let terminalFingerprintLatestSafeEvidence = null;
const terminalFingerprintErrorCodes = new Set([
  'unstable', 'bounds', 'unchanged', 'other',
]);

function safeTerminalFingerprintEvidence(page, error) {
  const candidate = error?.terminalFingerprintEvidence ||
    terminalFingerprintEvidenceByPage.get(page);
  if (!candidate || typeof candidate !== 'object') return null;
  const boundedCount = (value) => Number.isInteger(value)
    ? Math.max(0, Math.min(10000, value))
    : null;
  const safeHash = (value) => typeof value === 'string' &&
      /^[a-f0-9]{64}$/i.test(value)
    ? value.toLowerCase()
    : null;
  const errorCode = terminalFingerprintErrorCodes.has(candidate.errorCode)
    ? candidate.errorCode
    : null;
  return {
    ...(errorCode == null ? {} : { errorCode }),
    sampleCount: boundedCount(candidate.sampleCount),
    hashTransitionCount: boundedCount(candidate.hashTransitionCount),
    firstSha256: safeHash(candidate.firstSha256),
    lastSha256: safeHash(candidate.lastSha256),
  };
}

function terminalFingerprintErrorCode(error, sampleEvidence) {
  if (sampleEvidence?.errorCode &&
      terminalFingerprintErrorCodes.has(sampleEvidence.errorCode)) {
    return sampleEvidence.errorCode;
  }
  const message = String(error?.message || '');
  if (message === 'terminal surface did not reach a stable visual state') {
    return 'unstable';
  }
  if (message === 'terminal surface did not display changed output') {
    return 'unchanged';
  }
  if (message === 'active terminal header was not measurable' ||
      message === 'active terminal surface has no usable screenshot bounds') {
    return 'bounds';
  }
  if (message === 'the remaining active terminal did not display its new output') {
    return 'unchanged';
  }
  return 'other';
}

async function stableTerminalVisualFingerprint(
  page,
  user,
  address,
  timeoutMs = 6000,
  differentFromFingerprint = null,
  anchorText = null,
) {
  const sampleEvidence = {
    sampleCount: 0,
    hashTransitionCount: 0,
    firstSha256: null,
    lastSha256: null,
  };
  terminalFingerprintEvidenceByPage.set(page, sampleEvidence);
  terminalFingerprintLatestSafeEvidence = {
    expectedDifferentFromSha256: typeof differentFromFingerprint === 'string' &&
        /^[a-f0-9]{64}$/i.test(differentFromFingerprint)
      ? differentFromFingerprint.toLowerCase()
      : null,
    sampleCount: 0,
    hashTransitionCount: 0,
    firstSha256: null,
    lastSha256: null,
  };
  const collaborationDialog = [
    'Shared terminal · read only',
    'Shared terminal · host-approved control',
  ].includes(anchorText);
  const header = collaborationDialog
    ? page.getByRole('dialog').last()
    : page.getByText(anchorText || `${user}@${address}`, {
      exact: true,
    }).first();
  await header.waitFor({ state: 'visible', timeout: 15000 });
  const headerBox = await header.boundingBox();
  const viewport = page.viewportSize() || { width: 1440, height: 1000 };
  assertThat(headerBox, 'active terminal header was not measurable');
  const clip = collaborationDialog
    ? {
      x: Math.max(0, Math.round(headerBox.x + 12)),
      y: Math.max(0, Math.round(headerBox.y + 48)),
      width: Math.max(0, Math.round(headerBox.width - 24)),
      height: Math.max(0, Math.round(headerBox.height - 96)),
    }
    : (() => {
      const top = Math.ceil(headerBox.y + headerBox.height + 8);
      return {
        x: Math.max(0, Math.round(headerBox.x)),
        y: Math.max(0, top),
        width: Math.max(0, Math.round(viewport.width - headerBox.x - 16)),
        height: Math.max(0, Math.round(viewport.height - top - 48)),
      };
    })();
  assertThat(clip.width > 100 && clip.height > 100,
    'active terminal surface has no usable screenshot bounds');
  const deadline = Date.now() + timeoutMs;
  let previous = null;
  let stableSamples = 0;
  while (Date.now() < deadline) {
    const screenshot = await page.screenshot({
      clip,
      type: 'jpeg',
      quality: 40,
      animations: 'disabled',
      caret: 'hide',
    });
    const current = crypto.createHash('sha256').update(screenshot).digest('hex');
    sampleEvidence.sampleCount = Math.min(10000, sampleEvidence.sampleCount + 1);
    if (sampleEvidence.firstSha256 == null) {
      sampleEvidence.firstSha256 = current;
    }
    if (sampleEvidence.lastSha256 != null &&
        sampleEvidence.lastSha256 !== current) {
      sampleEvidence.hashTransitionCount = Math.min(
        10000,
        sampleEvidence.hashTransitionCount + 1,
      );
    }
    sampleEvidence.lastSha256 = current;
    terminalFingerprintLatestSafeEvidence = {
      expectedDifferentFromSha256: typeof differentFromFingerprint === 'string' &&
          /^[a-f0-9]{64}$/i.test(differentFromFingerprint)
        ? differentFromFingerprint.toLowerCase()
        : null,
      ...sampleEvidence,
    };
    if (current === previous) {
      stableSamples += 1;
      if (stableSamples >= 2 &&
          (differentFromFingerprint == null ||
            current !== differentFromFingerprint)) {
        return current;
      }
    } else {
      previous = current;
      stableSamples = 0;
    }
    await page.waitForTimeout(120);
  }
  const changedFingerprintRequired = differentFromFingerprint != null;
  const error = new Error(changedFingerprintRequired
    ? 'terminal surface did not display changed output'
    : 'terminal surface did not reach a stable visual state');
  error.terminalFingerprintEvidence = {
    errorCode: changedFingerprintRequired ? 'unchanged' : 'unstable',
    ...sampleEvidence,
  };
  throw error;
}

async function waitForSemanticText(page, expectedText, present = true, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await pageSemanticsContainsText(page, expectedText) === present) return;
    await page.waitForTimeout(100);
  }
  throw new Error(`semantic text did not become ${present ? 'present' : 'absent'}`);
}

async function waitForSnippetResult(
  page,
  timeoutMs = 30000,
  redactVisibleText = (text) => text,
) {
  const deadline = Date.now() + timeoutMs;
  let safeEvidence = null;
  while (Date.now() < deadline) {
    safeEvidence = await page.evaluate(() => {
      const visibleDialogs = [...document.querySelectorAll(
        'flt-semantics[role="dialog"], [role="dialog"], [role="alertdialog"]')]
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        });
      // Flutter keeps old semantics nodes in the DOM after a dialog closes.
      // Read only the top visible dialog so a previous Exit code cannot satisfy
      // the current invocation's result wait.
      const activeDialog = visibleDialogs.at(-1) || null;
      const visibleText = activeDialog
        ? (activeDialog.innerText || activeDialog.textContent || '')
        : '';
      const exitCodes = [...new Set(
        [...visibleText.matchAll(/Exit code:\s*(-?\d+)/g)]
          .map((match) => Number(match[1])),
      )];
      const exitSignals = [...new Set(
        [...visibleText.matchAll(/SSH process ended by signal ([A-Z0-9]{1,24})\./g)]
          .map((match) => match[1]),
      )];
      return {
        exitCodes,
        exitSignals,
        activeDialogIsExecutionResult:
          visibleText.includes('Bash non-interactive execution') &&
          !visibleText.includes('Confirm and run') &&
          !visibleText.includes('Cancel execution') &&
          !visibleText.includes('Running once through a non-PTY SSH exec channel.'),
        bashUnavailable: visibleText.includes(
          'Bash is unavailable on this target'),
        cancelled: visibleText.includes(
          'Canceled. Remote completion status is unknown; the command was not retried.'),
        timedOut: visibleText.includes(
          'Remote completion status is unknown; the command was not retried.') &&
          visibleText.toLowerCase().includes('timed out'),
        outputTruncated: visibleText.includes(
          'Output exceeded the 64 KiB limit.'),
        sshEndedWithoutExit: visibleText.includes(
          'SSH ended without reporting an exit status.'),
        sshEndedBySignal: exitSignals.length > 0,
        runningMessage: visibleText.includes(
          'Running once through a non-PTY SSH exec channel.'),
        closeButtonCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => (element.getAttribute('aria-label') || element.innerText || '')
            .trim() === 'Close').length,
        cancelButtonCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => (element.getAttribute('aria-label') || element.innerText || '')
            .trim() === 'Cancel execution').length,
        visibleDialogCount: visibleDialogs.length,
        combinedTextLength: visibleText.length,
        visibleText,
      };
    });
    if ((safeEvidence.activeDialogIsExecutionResult &&
         safeEvidence.exitCodes.length) || safeEvidence.bashUnavailable ||
        safeEvidence.cancelled || safeEvidence.timedOut ||
        safeEvidence.outputTruncated || safeEvidence.sshEndedWithoutExit ||
        safeEvidence.sshEndedBySignal) {
      safeEvidence.safeTextTail = redactVisibleText(safeEvidence.visibleText).slice(-1200);
      delete safeEvidence.visibleText;
      return safeEvidence;
    }
    await page.waitForTimeout(200);
  }
  if (safeEvidence) {
    safeEvidence.safeTextTail = redactVisibleText(safeEvidence.visibleText).slice(-1200);
    delete safeEvidence.visibleText;
  }
  return safeEvidence;
}

async function waitForFilesystemState(filePath, expected, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    let exists = false;
    try {
      fs.accessSync(filePath, fs.constants.F_OK);
      exists = true;
    } catch (_) {}
    if (exists === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`isolated SFTP filesystem state did not become ${expected ? 'present' : 'absent'}`);
}

async function scrollToText(page, text, maxSteps = 96) {
  // Flutter's canvas semantics layer often exposes row labels through
  // aria-label rather than a text node, so include that surface directly.
  const escapedAttribute = text.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  const semanticLabel = page.locator(`flt-semantics[aria-label*="${escapedAttribute}"]`).first();
  if (await semanticLabel.count() > 0) {
    await semanticLabel.evaluate((element) => element.scrollIntoView({ block: 'center' }));
    const box = await semanticLabel.boundingBox().catch(() => null);
    const viewport = page.viewportSize() || { width: 1280, height: 800 };
    if (box && box.y < viewport.height && box.y + box.height > 0) return semanticLabel;
  }
  const locatorCandidates = [
    page.getByText(text, { exact: true }).first(),
    page.getByRole('button', { name: new RegExp(`\\b${text}\\b`, 'i') }).first(),
  ];
  const viewport = page.viewportSize() || { width: 1280, height: 800 };
  for (let step = 0; step < maxSteps; step++) {
    for (const locator of locatorCandidates) {
      if (await locator.count() > 0) {
        await locator.scrollIntoViewIfNeeded();
        if (await locator.isVisible().catch(() => false)) return locator;
      }
    }
    await page.mouse.move(Math.round(viewport.width * 0.78), Math.round(viewport.height * 0.72));
    await page.mouse.wheel(0, Math.round(viewport.height * 0.55));
    await page.waitForTimeout(100);
  }
  const listingDiagnostic = await page.evaluate((target) => {
    const text = document.body.innerText || '';
    const semanticNodes = [...document.querySelectorAll('flt-semantics')];
    const semanticLabels = semanticNodes.map((element) =>
      `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`);
    const remotePath = semanticLabels.some((label) => /(?:^|\n)\/tmp(?:\n|$)/.test(label.trim()))
      ? 'tmp'
      : semanticLabels.some((label) => /(?:^|\n)\/(?:\n|$)/.test(label.trim()))
      ? 'root'
      : 'unknown';
    return {
      targetInPageText: text.includes(target),
      targetInSemantics: semanticLabels.some((label) => label.includes(target)),
      visibleButtonCount: document.querySelectorAll('flt-semantics[role="button"]').length,
      sftpHeadingVisible: text.includes('SFTP file browser'),
      currentSftpPath: remotePath,
      loadingIndicatorCount: document.querySelectorAll(
        'flt-semantics[role="progressbar"], [role="progressbar"]',
      ).length,
      scrollableElementCount: [...document.querySelectorAll('*')].filter((element) =>
        element.scrollHeight > element.clientHeight + 40 &&
        ['auto', 'scroll'].includes(getComputedStyle(element).overflowY)).length,
    };
  }, text);
  console.log('SFTP list-entry lookup diagnostic', JSON.stringify(listingDiagnostic));
  throw new Error('SFTP list entry did not become visible after scrolling');
}

async function terminalInteractionSummary(page, terminalPoint = null) {
  return page.evaluate(({ point }) => {
    const summarizeElement = (element) => {
      if (!(element instanceof Element)) return null;
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return {
        tag: element.tagName.toLowerCase(),
        id: element.id || null,
        role: element.getAttribute('role') || null,
        type: element instanceof HTMLInputElement ? element.type : null,
        ariaLabel: element.getAttribute('aria-label'),
        ariaDisabled: element.getAttribute('aria-disabled'),
        disabled: element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
          ? element.disabled
          : null,
        tabIndex: element.tabIndex,
        dataSemanticsRole: element.getAttribute('data-semantics-role'),
        ariaMultiline: element.getAttribute('aria-multiline') === 'true',
        contentEditable: element.getAttribute('contenteditable') === 'true',
        visible: rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none',
        pointerEvents: style.pointerEvents,
        opacity: style.opacity,
        rect: {
          x: Math.round(rect.x), y: Math.round(rect.y),
          width: Math.round(rect.width), height: Math.round(rect.height),
        },
      };
    };
    const active = document.activeElement;
    const hit = point ? document.elementFromPoint(point.x, point.y) : null;
    const shadowRoots = [];
    const editableHosts = [];
    const isDeepActive = (element) => {
      let current = document.activeElement;
      for (let depth = 0; current instanceof Element && depth < 6; depth++) {
        if (current === element) return true;
        current = current.shadowRoot?.activeElement || null;
      }
      return false;
    };
    const visitRoot = (root) => {
      for (const element of root.querySelectorAll('*')) {
        if (element.shadowRoot) {
          shadowRoots.push(element.tagName.toLowerCase());
          visitRoot(element.shadowRoot);
        }
        const tag = element.tagName.toLowerCase();
        if (tag === 'flt-text-editing-host' || tag === 'input' || tag === 'textarea' ||
            element.getAttribute('contenteditable') === 'true') {
          const summary = summarizeElement(element);
          if (summary) {
            summary.focused = isDeepActive(element);
            summary.parentTag = element.parentElement?.tagName.toLowerCase() || null;
            editableHosts.push(summary);
          }
        }
      }
    };
    visitRoot(document);
    const pointerStack = point
      ? document.elementsFromPoint(point.x, point.y).slice(0, 5).map(summarizeElement)
      : [];
    const terminalInput = document.querySelector(
      'input[aria-label="SSH terminal input"],textarea[aria-label="SSH terminal input"]',
    );
    const terminalSemanticNodeSet = new Set([active, hit, terminalInput?.parentElement]);
    const terminalSemanticNodes = [...terminalSemanticNodeSet]
      .filter((element) => element instanceof Element && element.tagName.toLowerCase() === 'flt-semantics')
      .map((element) => ({
        ...summarizeElement(element),
        text: (element.textContent || '').slice(0, 80),
        editableChildren: [...element.querySelectorAll('input,textarea,[contenteditable="true"]')]
          .map(summarizeElement),
      }));
    const activeElementChain = [];
    let nestedActive = active;
    while (nestedActive instanceof Element && activeElementChain.length < 6) {
      activeElementChain.push(summarizeElement(nestedActive));
      nestedActive = nestedActive.shadowRoot?.activeElement || null;
    }
    const bodyText = document.body.innerText || '';
    const canvases = [...document.querySelectorAll('canvas')]
      .map((canvas) => {
        const rect = canvas.getBoundingClientRect();
        const style = getComputedStyle(canvas);
        return {
          visible: rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none',
          rect: {
            x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.width), height: Math.round(rect.height),
          },
        };
      })
      .filter((canvas) => canvas.visible)
      .slice(0, 8);
    return {
      viewport: { width: window.innerWidth, height: window.innerHeight },
      activeElement: summarizeElement(active),
      activeElementChain,
      shadowRootHosts: shadowRoots.slice(0, 12),
      textInputHosts: editableHosts.slice(0, 12),
      terminalHitElement: summarizeElement(hit),
      pointerStack,
      terminalSemanticNodes,
      connectedLabelVisible: bodyText.includes('CONNECTED'),
      terminalCanvases: canvases,
    };
  }, { point: terminalPoint });
}

async function installTerminalInputProbe(page) {
  await page.evaluate(() => {
    const counts = {
      keydown: { printable: 0, enter: 0, modifier: 0, other: 0 },
      beforeinput: { events: 0, insertedCharacters: 0, other: 0 },
      input: 0,
      terminalInput: {
        keydown: { printable: 0, enter: 0, modifier: 0, other: 0 },
        beforeinput: { events: 0, insertedCharacters: 0, other: 0 },
        input: 0,
      },
      enterEvents: [],
      focusEvents: [],
      semanticInputMutations: [],
    };
    window.__relayTerminalInputCounts = counts;
    const semanticInputTokens = new WeakMap();
    let nextSemanticInputToken = 1;
    const inputToken = (element) => {
      if (!semanticInputTokens.has(element)) {
        semanticInputTokens.set(element, nextSemanticInputToken++);
      }
      return semanticInputTokens.get(element);
    };
    const terminalInputsIn = (node) => {
      if (!(node instanceof Element)) return [];
      const matches = [];
      if (node.matches('input[aria-label="SSH terminal input"]')) matches.push(node);
      matches.push(...node.querySelectorAll('input[aria-label="SSH terminal input"]'));
      return matches;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        for (const [action, nodes] of [['removed', record.removedNodes], ['added', record.addedNodes]]) {
          for (const node of nodes) {
            for (const element of terminalInputsIn(node)) {
              if (counts.semanticInputMutations.length < 24) {
                counts.semanticInputMutations.push({
                  action,
                  token: inputToken(element),
                  focused: document.activeElement === element,
                  connected: element.isConnected,
                  timeMs: Math.round(performance.now()),
                });
              }
            }
          }
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    const recordTerminalFocus = (phase, event) => {
      const target = event.target instanceof Element ? event.target : null;
      if (target?.getAttribute('aria-label') !== 'SSH terminal input') return;
      if (counts.focusEvents.length < 16) {
        const related = event.relatedTarget instanceof Element ? event.relatedTarget : null;
        counts.focusEvents.push({
          phase,
          targetTag: target.tagName.toLowerCase(),
          targetToken: inputToken(target),
          relatedTag: related?.tagName?.toLowerCase() || null,
          activeTag: document.activeElement?.tagName?.toLowerCase() || null,
          timeMs: Math.round(performance.now()),
        });
      }
    };
    document.addEventListener('focusin', (event) => recordTerminalFocus('focusin', event), true);
    document.addEventListener('focusout', (event) => recordTerminalFocus('focusout', event), true);
    document.addEventListener('keydown', (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const terminalTarget =
        target?.getAttribute('aria-label') === 'SSH terminal input';
      if (event.key === 'Enter') {
        counts.keydown.enter++;
        if (terminalTarget) counts.terminalInput.keydown.enter++;
        if (counts.enterEvents.length < 8) {
          const target = event.target instanceof Element ? event.target : null;
          counts.enterEvents.push({
            phase: 'capture',
            key: event.key,
            code: event.code || null,
            keyCode: event.keyCode || 0,
            defaultPrevented: event.defaultPrevented,
            targetTag: target?.tagName?.toLowerCase() || null,
            targetType: target instanceof HTMLInputElement ? target.type : null,
            targetLabel: target?.getAttribute('aria-label') || null,
            targetRole: target?.getAttribute('data-semantics-role') || null,
            targetInsideForm: Boolean(target?.closest('form')),
            activeTag: document.activeElement?.tagName?.toLowerCase() || null,
          });
        }
      }
      else if (event.key === 'Shift' || event.key === 'Control' || event.key === 'Alt' || event.key === 'Meta') {
        counts.keydown.modifier++;
        if (terminalTarget) counts.terminalInput.keydown.modifier++;
      } else if (typeof event.key === 'string' && event.key.length === 1) {
        counts.keydown.printable++;
        if (terminalTarget) counts.terminalInput.keydown.printable++;
      } else {
        counts.keydown.other++;
        if (terminalTarget) counts.terminalInput.keydown.other++;
      }
    }, true);
    document.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter' || counts.enterEvents.length >= 8) return;
      const target = event.target instanceof Element ? event.target : null;
      counts.enterEvents.push({
        phase: 'bubble',
        key: event.key,
        code: event.code || null,
        keyCode: event.keyCode || 0,
        defaultPrevented: event.defaultPrevented,
        targetTag: target?.tagName?.toLowerCase() || null,
        targetType: target instanceof HTMLInputElement ? target.type : null,
        targetLabel: target?.getAttribute('aria-label') || null,
        targetRole: target?.getAttribute('data-semantics-role') || null,
        targetInsideForm: Boolean(target?.closest('form')),
        activeTag: document.activeElement?.tagName?.toLowerCase() || null,
      });
    }, false);
    document.addEventListener('beforeinput', (event) => {
      counts.beforeinput.events++;
      const target = event.target instanceof Element ? event.target : null;
      const terminalTarget =
        target?.getAttribute('aria-label') === 'SSH terminal input';
      if (terminalTarget) counts.terminalInput.beforeinput.events++;
      if (event.inputType === 'insertText' || event.inputType === 'insertCompositionText') {
        const insertedCharacters =
          typeof event.data === 'string' ? event.data.length : 0;
        counts.beforeinput.insertedCharacters += insertedCharacters;
        if (terminalTarget) {
          counts.terminalInput.beforeinput.insertedCharacters += insertedCharacters;
        }
      } else {
        counts.beforeinput.other++;
        if (terminalTarget) counts.terminalInput.beforeinput.other++;
      }
    }, true);
    document.addEventListener('input', (event) => {
      counts.input++;
      const target = event.target instanceof Element ? event.target : null;
      if (target?.getAttribute('aria-label') === 'SSH terminal input') {
        counts.terminalInput.input++;
      }
    }, true);
  });
}

async function readTerminalInputCounts(page) {
  return page.evaluate(() => {
    const counts = window.__relayTerminalInputCounts;
    if (!counts) return null;
    return {
      keydown: { ...counts.keydown },
      beforeinput: { ...counts.beforeinput },
      input: counts.input,
      terminalInput: {
        keydown: { ...counts.terminalInput.keydown },
        beforeinput: { ...counts.terminalInput.beforeinput },
        input: counts.terminalInput.input,
      },
      enterEvents: counts.enterEvents.map((event) => ({ ...event })),
      focusEvents: counts.focusEvents.map((event) => ({ ...event })),
      semanticInputMutations: counts.semanticInputMutations.map((event) => ({ ...event })),
    };
  });
}

async function waitForSshTrustOrError(page, timeoutMs = 15000, expectedHostName = null) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (expectedHostName) {
      const escapedHostName = expectedHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      for (const state of ['connected', 'failed', 'disconnected']) {
        const hostTabs = page.getByRole('button', {
          name: new RegExp(`^${escapedHostName} terminal tab, ${state}, (?:active|inactive)$`),
        });
        if (await hostTabs.count().catch(() => 0) > 0) {
          return `terminal_${state}`;
        }
      }
    }
    const trustButtons = page.getByRole('button', {
      name: 'Trust after verification',
      exact: true,
    });
    const trustButtonCount = await trustButtons.count().catch(() => 0);
    for (let index = 0; index < trustButtonCount; index += 1) {
      if (await trustButtons.nth(index).isVisible().catch(() => false)) {
        return 'host_key_prompt';
      }
    }
    const signal = await page.evaluate(() => {
      const visible = (element) => {
        let rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0 || rect.bottom <= 0 ||
            rect.right <= 0 || rect.top >= window.innerHeight ||
            rect.left >= window.innerWidth) return false;
        for (let parent = element; parent instanceof Element;
            parent = parent.parentElement) {
          const style = getComputedStyle(parent);
          if (style.display === 'none' || style.visibility === 'hidden' ||
              Number(style.opacity) === 0 ||
              parent.getAttribute('aria-hidden') === 'true' ||
              parent.hasAttribute('inert')) return false;
          if (parent === document.body) continue;
          const clip = parent.getBoundingClientRect();
          if (['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowX)) {
            rect = { ...rect, left: Math.max(rect.left, clip.left),
              right: Math.min(rect.right, clip.right) };
          }
          if (['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowY)) {
            rect = { ...rect, top: Math.max(rect.top, clip.top),
              bottom: Math.min(rect.bottom, clip.bottom) };
          }
          if (rect.right <= rect.left || rect.bottom <= rect.top) return false;
        }
        return true;
      };
      const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`)
        .join('\n');
      const text = visibleSemanticText;
      if (text.includes('Verify SSH host key')) return 'host_key_prompt';
      if (/最多同时打开\s*\d+\s*个 SSH 终端标签/.test(text)) return 'terminal_capacity_error';
      if (text.includes('Jump Host 链不能形成循环。')) return 'jump_route_cycle_error';
      if (/Jump Host 链最多支持\s*\d+\s*层/.test(text)) return 'jump_route_depth_error';
      if (text.includes('Jump Host 链包含已不存在的主机')) return 'jump_route_missing_host_error';
      if (/Jump Host .*SSH 凭据无法解析/.test(text)) return 'jump_credential_resolution_error';
      if (/effective SSH credential is unavailable|No SSH credential is configured|Group inheritance chain is unavailable/i.test(text)) {
        return 'credential_resolution_error';
      }
      if (/主机或 Jump Host 路由在连接准备期间发生变化|Jump Host 路由或凭据在连接准备期间发生变化/.test(text)) {
        return 'route_snapshot_changed_error';
      }
      if (text.includes('请先解锁 Vault')) return 'vault_locked_error';
      if (text.includes('请先配置服务端地址')) return 'server_configuration_error';
      if (/TimeoutException/i.test(text) || text.includes('SSH 中继连接超时。')) return 'timeout_exception';
      if (text.includes('无法建立 SSH 中继 WebSocket。')) return 'relay_transport_error';
      if (text.includes('SSH 中继票据已失效')) return 'relay_ticket_error';
      if (text.includes('SSH 主机密钥验证失败')) return 'ssh_hostkey_verification_error';
      if (text.includes('已拒绝尚未信任的 SSH 主机密钥')) return 'host_key_rejected';
      if (text.includes('SSH 连接在身份验证完成前中断')) return 'ssh_auth_abort';
      if (/authentication failed|public.?key authentication failed|认证失败|身份验证失败/i.test(text)) {
        return 'ssh_auth_error';
      }
      if (/SSH.{0,24}(protocol|handshake|identification|kex)|SSH.{0,24}(协议|握手)/i.test(text)) {
        return 'ssh_protocol_error';
      }
      return null;
    });
    if (signal) return signal;
    await page.waitForTimeout(100);
  }
  return 'deadline_without_visible_signal';
}

async function sshTrustPromptToken(page) {
  const promptText = await page.evaluate(() => {
    // Called only after Playwright sees the exact trust action. Hash the active
    // semantics in memory so each hop advances without returning/logging prompt
    // text, endpoint details, or fingerprints.
    const text = [...document.querySelectorAll('flt-semantics')]
      .map((element) => `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`)
      .join('\n');
    return text.includes('Trust after verification') ? text : null;
  }).catch(() => null);
  if (!promptText) return null;
  return crypto.createHash('sha256').update(promptText).digest('hex');
}

async function visibleSshTrustPromptMatchesEndpoint(page, expectedEndpoint) {
  return page.evaluate((expected) => {
    const text = [...document.querySelectorAll('flt-semantics')]
      .map((element) => `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`)
      .join('\n');
    return text.includes(`This SSH key is not trusted for ${expected}.`);
  }, expectedEndpoint).catch(() => false);
}

async function visibleSshTrustPromptShowsFingerprint(page, fingerprint) {
  return page.evaluate((expected) => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity || 1) > 0;
    };
    const entries = [...document.querySelectorAll('flt-semantics')]
      .filter(visible)
      .map((element) => [
          element.getAttribute('aria-label'),
          element.innerText,
          element.textContent,
        ].filter(Boolean).join('\n'));
    const fingerprintLabels = entries.filter((text) =>
      /SSH host key fingerprint:/i.test(text));
    const allElements = [...document.querySelectorAll('*')];
    const bodyText = document.body?.innerText || '';
    const accessibleLabels = [...document.querySelectorAll('[aria-label]')]
      .map((element) => element.getAttribute('aria-label') || '');
    const textLeaves = allElements.filter((element) =>
      element.children.length === 0 && (element.textContent || '').includes(expected));
    return {
      visibleFingerprintLabelCount: fingerprintLabels.length,
      visibleSemanticFingerprintMatch: entries.some((text) =>
        text.includes(`SSH host key fingerprint: ${expected}`) ||
        text.trim() === expected),
      bodyTextHasFingerprintLabel: /SSH host key fingerprint:/i.test(bodyText),
      bodyTextHasExpectedFingerprint: bodyText.includes(expected),
      accessibleFingerprintLabelCount: accessibleLabels.filter((text) =>
        /SSH host key fingerprint:/i.test(text)).length,
      accessibleExpectedFingerprintCount: accessibleLabels.filter((text) =>
        text.includes(expected)).length,
      textLeafExpectedFingerprintCount: textLeaves.length,
      exactFingerprintVisible: entries.some((text) =>
        text.includes(`SSH host key fingerprint: ${expected}`) ||
        text.trim() === expected) ||
        bodyText.includes(expected) ||
        accessibleLabels.some((text) => text.includes(expected)) ||
        textLeaves.length > 0,
    };
  }, fingerprint).catch(() => ({
    visibleFingerprintLabelCount: 0,
    visibleSemanticFingerprintMatch: false,
    bodyTextHasFingerprintLabel: false,
    bodyTextHasExpectedFingerprint: false,
    accessibleFingerprintLabelCount: 0,
    accessibleExpectedFingerprintCount: 0,
    textLeafExpectedFingerprintCount: 0,
    exactFingerprintVisible: false,
  }));
}

async function waitForSshTrustPromptAdvance(page, previousToken, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const currentToken = await sshTrustPromptToken(page);
    if (currentToken !== previousToken) return;
    await page.waitForTimeout(100);
  }
  throw new Error('SSH host-key trust prompt did not advance after approval');
}

async function button(page, label) {
  const matches = page.getByRole('button', { name: label, exact: true });
  await selectServerModeIfChooser(page, matches);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      const candidate = matches.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button not found: ${label}`);
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function clickSftpEntryAction(page, filename, action) {
  await scrollToText(page, filename);
  const rowMenu = page.getByRole('button', {
    name: `Actions for ${filename}`,
    exact: true,
  }).last();
  await rowMenu.waitFor({ state: 'visible', timeout: 15000 });
  await rowMenu.click();

  const escapedAction = action.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  const candidates = [
    page.getByRole('menuitem', { name: action, exact: true }).last(),
    page.getByText(action, { exact: true }).last(),
    page.locator(`flt-semantics[aria-label*="${escapedAction}"]`).last(),
  ];
  let actionItem = null;
  const actionDeadline = Date.now() + 5000;
  while (!actionItem && Date.now() < actionDeadline) {
    for (const candidate of candidates) {
      if (await candidate.count() > 0 && await candidate.isVisible().catch(() => false)) {
        actionItem = candidate;
        break;
      }
    }
    if (!actionItem) await page.waitForTimeout(100);
  }
  if (!actionItem) {
    const menuEvidence = await page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
      .map((element) => ({
        role: element.getAttribute('role') || '',
        label: element.getAttribute('aria-label') || '',
        text: element.innerText || '',
      }))
      .filter((item) => /Download|Edit text|Delete/.test(`${item.label} ${item.text}`))
      .slice(-8));
    console.log('SFTP row action lookup diagnostic', JSON.stringify({
      requestedActionFound: false,
      menuEvidence,
    }));
    throw new Error('SFTP row action was not exposed after opening its menu');
  }
  await actionItem.click();
}

async function openSftpEntryAction(page, filename, action) {
  await clickSftpEntryAction(page, filename, action);
  if (action === 'Edit text') {
    await page.getByText('Edit remote text file', { exact: true }).last()
      .waitFor({ state: 'visible', timeout: 15000 });
    const editorText = page.locator('textarea[aria-label="Remote file contents"]').last();
    await editorText.waitFor({ state: 'visible', timeout: 15000 });
  }
}

async function fixtureFileMatches(filePath, expectedBytes) {
  let actualBytes;
  try {
    actualBytes = fs.readFileSync(filePath);
    return actualBytes.equals(expectedBytes);
  } catch (_) {
    return false;
  } finally {
    actualBytes?.fill(0);
  }
}

function fixtureFileLineEvidence(filePath, expectedLine) {
  let bytes;
  try {
    bytes = fs.readFileSync(filePath);
    const contents = bytes.toString('utf8');
    const lines = contents.split(/\r?\n/);
    if (lines.at(-1) === '') lines.pop();
    return {
      exists: true,
      lineCount: lines.length,
      exactExpectedValueOnce: lines.length === 1 && lines[0] === expectedLine,
      byteLength: bytes.length,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    };
  } catch (_) {
    return {
      exists: false,
      lineCount: 0,
      exactExpectedValueOnce: false,
      byteLength: null,
      sha256: null,
    };
  } finally {
    bytes?.fill(0);
  }
}

function fileMarkerAbsenceEvidence(filePaths, marker) {
  const markerBytes = Buffer.from(marker, 'utf8');
  let scannedFiles = 0;
  let markerFound = false;
  try {
    for (const filePath of filePaths) {
      if (!fs.existsSync(filePath)) continue;
      let bytes;
      try {
        bytes = fs.readFileSync(filePath);
        scannedFiles += 1;
        markerFound ||= bytes.includes(markerBytes);
      } finally {
        bytes?.fill(0);
      }
    }
    return { scannedFiles, plaintextMarkerAbsent: !markerFound };
  } finally {
    markerBytes.fill(0);
  }
}

async function waitForFixtureFileBytes(filePath, expectedBytes, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await fixtureFileMatches(filePath, expectedBytes)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('isolated SFTP file bytes did not match the expected fixture');
}

async function pageSemanticsContainsText(page, expectedText) {
  return page.evaluate((needle) => {
    const semanticText = [...document.querySelectorAll('flt-semantics')]
      .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
      .join('\n');
    return semanticText.includes(needle) || (document.body.innerText || '').includes(needle);
  }, expectedText);
}

async function visibleSemanticsContainsText(page, expectedText) {
  return page.evaluate((needle) => {
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
    };
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      isVisible(element) &&
      `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`
        .includes(needle));
  }, expectedText).catch(() => false);
}

async function waitForVisibleSemanticsText(page, expectedText, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await visibleSemanticsContainsText(page, expectedText)) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected terminal search status was not exposed by visible semantics');
}

async function visibleSemanticsMatchesPattern(page, pattern) {
  const expression = { source: pattern.source, flags: pattern.flags };
  return page.evaluate((spec) => {
    const regex = new RegExp(spec.source, spec.flags);
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
    };
    return [...document.querySelectorAll('flt-semantics')].some((element) =>
      isVisible(element) && regex.test(
        `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`));
  }, expression).catch(() => false);
}

async function waitForVisibleSemanticsPattern(page, pattern, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await visibleSemanticsMatchesPattern(page, pattern)) return;
    await page.waitForTimeout(100);
  }
  throw new Error('expected text was not exposed by visible Web semantics');
}

async function clickUntilVisibleSemanticsText(page, label, expectedText, timeoutMs = 5000) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const buttonLocator = page.getByRole('button', { name: label, exact: true });
    const candidateCount = await buttonLocator.count().catch(() => 0);
    const visibleCount = await buttonLocator.evaluateAll((elements) =>
      elements.filter((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0;
      }).length).catch(() => 0);
    console.log('Terminal search navigation control safe evidence', JSON.stringify({
      buttonLabelLength: label.length,
      candidateCount,
      visibleCount,
      attempt: attempt + 1,
    }));
    try {
      await click(page, label);
    } catch (error) {
      console.log('Terminal search navigation click safe failure', JSON.stringify({
        buttonLabelLength: label.length,
        candidateCount,
        visibleCount,
        errorType: error?.name || 'Error',
      }));
      throw error;
    }
    try {
      await waitForVisibleSemanticsText(page, expectedText, timeoutMs);
      return;
    } catch (_) {
      if (attempt === 2) break;
      console.log('Terminal search navigation safe recovery', JSON.stringify({
        button: label,
        retryCount: attempt + 1,
        expectedStatusLength: expectedText.length,
        expectedStatusVisible: false,
      }));
    }
  }
  throw new Error('terminal search navigation did not reach the requested match');
}

function quoteBashPreviewWord(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

async function field(page, label) {
  const searchInputSelector =
    'input[data-semantics-role="text-field"][aria-label*="Search terminal scrollback"],' +
    'input[data-semantics-role="text-field"][aria-description*="Search this terminal scrollback"],' +
    'textarea[data-semantics-role="text-field"][aria-label*="Search terminal scrollback"],' +
    'textarea[data-semantics-role="text-field"][aria-description*="Search this terminal scrollback"]';
  const candidates = label === 'Search terminal scrollback'
    ? page.locator(searchInputSelector)
    : page.locator(`input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`);
  await selectServerModeIfChooser(page, candidates.first());
  const escaped = JSON.stringify(label);
  if (label === 'Search terminal scrollback') {
    const roleTextboxes = page.getByRole('textbox', {
      name: /Search.*terminal scrollback/i,
    });
    const roleTextboxCount = await roleTextboxes.count().catch(() => 0);
    for (let index = roleTextboxCount - 1; index >= 0; index -= 1) {
      const candidate = roleTextboxes.nth(index);
      if (await candidate.isVisible().catch(() => false)) {
        const info = await candidate.evaluate((element) => ({
          tagName: element.tagName,
          isContentEditable: Boolean(element.isContentEditable),
          ariaLabelLength: (element.getAttribute('aria-label') || '').length,
          ariaDescriptionLength: (element.getAttribute('aria-description') || '').length,
          semanticRole: element.getAttribute('data-semantics-role'),
          placeholderLength: (element.getAttribute('placeholder') || '').length,
          disabled: Boolean(element.disabled),
        }));
        console.log('Terminal search textbox selected safe evidence', JSON.stringify(info));
        return candidate;
      }
    }
    // Flutter Web does not consistently stamp the platform text input with
    // `data-semantics-role`. When the search bar exposes exactly one visible
    // text input and its visible Flutter semantics node names the scrollback
    // search, use that unambiguous control instead of waiting for the optional
    // test-only attribute.
    const visibleTextInputs = page.locator('input:visible,textarea:visible');
    const visibleTextInputCount = await visibleTextInputs.count().catch(() => 0);
    const visibleSearchContext = await page.evaluate(() => {
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0;
      };
      return [...document.querySelectorAll('flt-semantics')].some((element) => {
        if (!isVisible(element)) return false;
        const text = `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`;
        return /Search(?: this)? terminal scrollback/i.test(text);
      });
    }).catch(() => false);
    if (visibleTextInputCount === 1 && visibleSearchContext) {
      const candidate = visibleTextInputs.first();
      const info = await candidate.evaluate((element) => ({
        tagName: element.tagName,
        isContentEditable: Boolean(element.isContentEditable),
        ariaLabelLength: (element.getAttribute('aria-label') || '').length,
        ariaDescriptionLength: (element.getAttribute('aria-description') || '').length,
        semanticRole: element.getAttribute('data-semantics-role'),
        placeholderLength: (element.getAttribute('placeholder') || '').length,
        disabled: Boolean(element.disabled),
      }));
      console.log('Terminal search visible input selected safe evidence', JSON.stringify(info));
      return candidate;
    }
  }
  if (label === 'PEM private key') {
    const textarea = page.locator(`textarea[aria-label*=${escaped}]`).first();
    try {
      // The private-key segment replaces Flutter's password EditableText with
      // a multiline EditableText. Let that keyed DOM control settle before
      // deciding whether the browser exposed a safe multiline target.
      await textarea.waitFor({ state: 'visible', timeout: 15000 });
      const rows = await textarea.evaluate((element) =>
        element instanceof HTMLTextAreaElement ? element.rows : 0);
      if (rows >= 2) return textarea;
    } catch (_) {
      // Continue to the structural fallbacks and emit the same value-free
      // diagnostics if the multiline control did not become available.
    }
    const roleTextbox = page.getByRole('textbox', { name: /PEM private key/i }).first();
    const roleTextboxCount = await roleTextbox.count();
    if (roleTextboxCount) {
      const roleInfo = await roleTextbox.evaluate((element) => ({
        tag: element.tagName,
        rows: element instanceof HTMLTextAreaElement ? element.rows : 0,
      }));
      if (roleInfo.tag === 'TEXTAREA' && roleInfo.rows >= 2 && await roleTextbox.isVisible()) {
        return roleTextbox;
      }
    }
    const allTextareas = page.locator('textarea');
    const visibleTextareas = [];
    for (let index = 0; index < await allTextareas.count(); index += 1) {
      const candidate = allTextareas.nth(index);
      if (await candidate.isVisible() && await candidate.evaluate((element) => element.rows >= 2)) {
        visibleTextareas.push(candidate);
      }
    }
    if (visibleTextareas.length === 1) return visibleTextareas[0];
    const labelledInput = page.locator('input[aria-label*="PEM private key"]').first();
    const labelledInputCount = await labelledInput.count();
    const labelledInputInfo = labelledInputCount
      ? await labelledInput.evaluate((element) => {
        const style = getComputedStyle(element);
        return {
          tagName: element.tagName,
          type: element.type || null,
          role: element.getAttribute('role'),
          ariaLabel: element.getAttribute('aria-label'),
          visible: element.getClientRects().length > 0 && style.visibility !== 'hidden' && style.display !== 'none',
        };
      })
      : null;
    console.log('PEM input candidate diagnostics', JSON.stringify({
      labelledInputCount,
      labelledInputInfo,
      visibleTextareaCount: visibleTextareas.length,
      roleTextboxCount,
    }));
    throw new Error('no visible textarea is exposed for the multiline PEM credential field');
  }
  for (let index = await candidates.count() - 1; index >= 0; index -= 1) {
    const candidate = candidates.nth(index);
    if (await candidate.isVisible().catch(() => false)) {
      const info = await candidate.evaluate((element) => ({
        tagName: element.tagName,
        ariaLabelLength: (element.getAttribute('aria-label') || '').length,
        rows: element instanceof HTMLTextAreaElement ? element.rows : null,
        disabled: Boolean(element.disabled),
        valueLength: typeof element.value === 'string' ? element.value.length : null,
      }));
      console.log('Field selector selected safe evidence', JSON.stringify({
        field: label,
        ...info,
      }));
      return candidate;
    }
  }
  const evidence = await candidates.evaluateAll((elements) => elements.map((element) => ({
    tagName: element.tagName,
    ariaLabelLength: (element.getAttribute('aria-label') || '').length,
    visible: element.getClientRects().length > 0,
    disabled: Boolean(element.disabled),
    readOnly: Boolean(element.readOnly),
    rows: element instanceof HTMLTextAreaElement ? element.rows : null,
  }))).catch(() => []);
  console.log('Field selector safe evidence', JSON.stringify({
    field: label,
    candidateCount: await candidates.count().catch(() => null),
    candidates: evidence,
  }));
  if (label === 'Search terminal scrollback') {
    const terminalSearchUi = await page.evaluate(() => {
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0;
      };
      const searchSemantics = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const text = `${element.getAttribute('aria-label') || ''}\\n${element.innerText || ''}`;
          return /Search(?: this)? terminal scrollback/i.test(text);
        });
      const editables = [...document.querySelectorAll(
        'input,textarea,[contenteditable="true"],flt-semantics[role="textbox"]',
      )];
      return {
        searchSemanticsCount: searchSemantics.length,
        visibleSearchSemanticsCount: searchSemantics.filter(isVisible).length,
        textboxCount: document.querySelectorAll('[role="textbox"]').length,
        editableCount: editables.length,
        editables: editables.slice(0, 8).map((element) => ({
          tagName: element.tagName,
          role: element.getAttribute('role'),
          ariaLabelLength: (element.getAttribute('aria-label') || '').length,
          placeholderLength: (element.getAttribute('placeholder') || '').length,
          inputType: element instanceof HTMLInputElement ? element.type : null,
          visible: isVisible(element),
          disabled: Boolean(element.disabled),
          isContentEditable: Boolean(element.isContentEditable),
        })),
      };
    }).catch(() => ({ diagnosticUnavailable: true }));
    console.log('Terminal search field UI safe diagnostic', JSON.stringify(terminalSearchUi));
  }
  const first = candidates.first();
  await first.waitFor({ state: 'visible', timeout: 15000 });
  return first;
}

async function fill(page, label, value) {
  safeRunStage = `${label} field fill`;
  const labelText = page.getByText(label, { exact: true }).last();
  const reportFillFailure = (phase, error) => {
    console.log('Text field interaction safe failure', JSON.stringify({
      field: label,
      fieldLabelLength: label.length,
      phase,
      errorType: error?.name || 'Error',
    }));
  };
  const labelCount = await labelText.count().catch(() => 0);
  await labelText.scrollIntoViewIfNeeded({ timeout: 3000 }).catch((error) => {
    reportFillFailure('label-scroll', error);
  });
  let locator;
  try {
    locator = await field(page, label);
  } catch (error) {
    reportFillFailure('field-resolution', error);
    throw error;
  }
  const readFieldEvidence = async () => locator.evaluate((element, expected) => {
    const ariaLabel = element.getAttribute('aria-label') || '';
    const ariaDescription = element.getAttribute('aria-description') || '';
    const style = getComputedStyle(element);
    const searchHintMatchesField = expected.fieldLabel ===
        'Search terminal scrollback' &&
      (/search/i.test(ariaLabel) ||
        /search this terminal scrollback/i.test(ariaDescription));
    return {
      tagName: element.tagName,
      ariaLabelLength: ariaLabel.length,
      ariaDescriptionLength: ariaDescription.length,
      semanticRole: element.getAttribute('data-semantics-role'),
      ariaLabelMatchesField: ariaLabel.toLowerCase().includes(
        expected.fieldLabel.toLowerCase()) || searchHintMatchesField,
      rows: element instanceof HTMLTextAreaElement ? element.rows : null,
      disabled: Boolean(element.disabled),
      readOnly: Boolean(element.readOnly),
      visible: element.getClientRects().length > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden',
      valueLength: typeof element.value === 'string' ? element.value.length : null,
      exactValue: element.value === expected.value,
    };
  }, { value, fieldLabel: label }, { timeout: 3000 });
  if (process.env.WEB_RELAY_PEM_PREFLIGHT_ONLY === '1') {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await locator.click();
      await page.waitForTimeout(150);
      await locator.press('Control+A');
      await page.waitForTimeout(50);
      await locator.pressSequentially(value, { delay: 60 });
      await page.waitForTimeout(200);
      await locator.press('Tab').catch(() => {});
      await page.waitForTimeout(100);
      const evidence = await readFieldEvidence();
      console.log('Text field preflight safe evidence', JSON.stringify({
        field: label,
        phase: `attempt-${attempt + 1}`,
        requestedValueLength: value.length,
        ...evidence,
      }));
      if (!evidence.exactValue) {
        throw new Error('text field preflight did not retain the exact requested value');
      }
    }
    return;
  }
  let initialEvidence;
  try {
    initialEvidence = await readFieldEvidence();
  } catch (error) {
    reportFillFailure('read-before-fill', error);
    throw error;
  }
  if (!initialEvidence.visible || !initialEvidence.ariaLabelMatchesField ||
      initialEvidence.disabled || initialEvidence.readOnly) {
    console.log('Text field form identity safe evidence', JSON.stringify({
      field: label,
      phase: 'before-fill',
      ...initialEvidence,
    }));
    throw new Error('requested text field is not available in the current form');
  }
  if (initialEvidence.exactValue) return;
  // Flutter web textareas can time out or lose characters during key-by-key
  // sequences even for medium-sized JSON. Use Playwright's textarea fill
  // operation for every textarea, retry at most three times, and accept an
  // attempt only after an exact full-value comparison. Evidence contains
  // lengths and booleans only.
  let directInputPrefillApplied = false;
  if (initialEvidence.tagName === 'INPUT') {
    safeRunStage = `${label} direct input fill`;
    let directFillError = null;
    try {
      await locator.fill(value, { timeout: 5000 });
      await page.waitForTimeout(100);
    } catch (error) {
      directFillError = error;
      reportFillFailure('direct-fill', error);
    }
    let directEvidence;
    try {
      directEvidence = await readFieldEvidence();
    } catch (error) {
      reportFillFailure('read-after-direct-fill', error);
      throw error;
    }
    console.log('Text field direct fill safe evidence', JSON.stringify({
      field: label,
      requestedValueLength: value.length,
      operationErrorType: directFillError?.name || null,
      ...directEvidence,
    }));
    // The semantics input can show the requested value before Flutter's form
    // state receives the corresponding key events. Always follow with the
    // bounded keyboard path and use the remote fixture/UI action as the final
    // state proof.
    directInputPrefillApplied = directEvidence.exactValue;
  }
  if (initialEvidence.tagName === 'TEXTAREA') {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      safeRunStage = `${label} long textarea fill attempt ${attempt + 1}`;
      let before;
      try {
        before = await readFieldEvidence();
      } catch (error) {
        reportFillFailure(`read-before-long-fill-${attempt + 1}`, error);
        throw error;
      }
      if (!before.visible || !before.ariaLabelMatchesField ||
          before.disabled || before.readOnly) {
        console.log('Text field form identity safe evidence', JSON.stringify({
          field: label,
          phase: `long-fill-attempt-${attempt + 1}`,
          ...before,
        }));
        throw new Error('requested long text field left the current form');
      }
      if (before.exactValue) return;

      let fillError = null;
      try {
        await locator.fill(value, { timeout: 10000 });
        await page.waitForTimeout(100);
      } catch (error) {
        fillError = error;
        reportFillFailure(`long-fill-${attempt + 1}`, error);
      }

      let after;
      try {
        after = await readFieldEvidence();
      } catch (error) {
        reportFillFailure(`read-after-long-fill-${attempt + 1}`, error);
        throw error;
      }
      console.log('Text field long fill safe evidence', JSON.stringify({
        field: label,
        phase: `attempt-${attempt + 1}`,
        method: 'fill',
        requestedValueLength: value.length,
        operationErrorType: fillError?.name || null,
        ...after,
      }));
      if (after.exactValue) return;
      if (attempt < 2) await page.waitForTimeout(150 * (attempt + 1));
    }
    let details;
    try {
      details = await readFieldEvidence();
    } catch (error) {
      reportFillFailure('read-after-long-fill-retries', error);
      throw error;
    }
    throw new Error(`textarea did not retain exact input (requested length=${value.length}; current length=${details.valueLength}; exact=${details.exactValue})`);
  }
  try {
    await locator.click({ timeout: 5000 });
  } catch (error) {
    reportFillFailure('focus-before-fill', error);
    throw error;
  }
  for (let attempt = 0; attempt < 3; attempt += 1) {
    safeRunStage = `${label} field fill attempt ${attempt + 1}`;
    let before;
    try {
      before = await readFieldEvidence();
    } catch (error) {
      reportFillFailure(`read-before-fill-${attempt + 1}`, error);
      throw error;
    }
    if (!before.visible || !before.ariaLabelMatchesField ||
        before.disabled || before.readOnly) {
      console.log('Text field form identity safe evidence', JSON.stringify({
        field: label,
        phase: `attempt-${attempt + 1}`,
        ...before,
      }));
      throw new Error('requested text field left the current form');
    }
    if (before.exactValue && !directInputPrefillApplied) return;
    try {
      // Replace any direct DOM prefill through actual key events so Flutter's
      // FormField state receives the same value the browser currently shows.
      await locator.press('Control+A', { timeout: 5000 });
      await locator.pressSequentially(value, { delay: 15, timeout: 10000 });
      await page.waitForTimeout(200);
      await locator.press('Tab', { timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(100);
    } catch (error) {
      reportFillFailure(`type-${attempt + 1}`, error);
      let afterFailure;
      try {
        afterFailure = await readFieldEvidence();
      } catch (readError) {
        reportFillFailure(`read-after-type-failure-${attempt + 1}`, readError);
        try {
          // Flutter Web can replace its platform input while processing a
          // keystroke. Re-resolve the uniquely labelled visible control
          // before deciding that the field lost the value.
          locator = await field(page, label);
          afterFailure = await readFieldEvidence();
          console.log('Text field locator recovery safe evidence', JSON.stringify({
            field: label,
            phase: `type-${attempt + 1}`,
            requestedValueLength: value.length,
            locatorReResolved: true,
            ...afterFailure,
          }));
        } catch (resolveError) {
          reportFillFailure(`reResolve-after-type-failure-${attempt + 1}`, resolveError);
          if (attempt === 2) {
            throw new Error('text field locator did not recover after bounded input attempts');
          }
          await page.waitForTimeout(150 * (attempt + 1));
          continue;
        }
      }
      console.log('Text field recovery safe evidence', JSON.stringify({
        field: label,
        phase: `type-${attempt + 1}`,
        requestedValueLength: value.length,
        ...afterFailure,
      }));
      if (afterFailure.exactValue) return;
      if (attempt === 2) throw new Error('text field value did not settle after bounded input attempts');
      continue;
    }
    let afterFill;
    try {
      afterFill = await readFieldEvidence();
    } catch (error) {
      reportFillFailure(`read-after-fill-${attempt + 1}`, error);
      throw error;
    }
    console.log('Text field fill safe evidence', JSON.stringify({
      field: label,
      phase: `type-${attempt + 1}`,
      requestedValueLength: value.length,
      ...afterFill,
    }));
    if (afterFill.exactValue) return;
  }
  let details;
  try {
    details = await readFieldEvidence();
  } catch (error) {
    reportFillFailure('read-after-retries', error);
    throw error;
  }
  throw new Error(`visible field '${label}' did not retain input (label matches=${labelCount}; requested length=${value.length}; ${JSON.stringify(details)})`);
}

async function safeServerUrlInputEvidence(locator, expected) {
  try {
    return await locator.evaluate((element, value) => {
      const actual = typeof element.value === 'string' ? element.value : '';
      const exactMatch = actual === value;
      return {
        available: true,
        valueLength: actual.length,
        exactMatch,
        mismatch: !exactMatch,
        expectedPrefixMatchesCurrentValue: !exactMatch &&
          actual.length < value.length && value.startsWith(actual),
        expectedSuffixMatchesCurrentValue: !exactMatch &&
          actual.length < value.length && value.endsWith(actual),
      };
    }, expected);
  } catch (_) {
    return {
      available: false,
      valueLength: null,
      exactMatch: false,
      mismatch: true,
      expectedPrefixMatchesCurrentValue: false,
      expectedSuffixMatchesCurrentValue: false,
    };
  }
}

function findSingleMissingCharacterIndex(expected, actual) {
  if (typeof actual !== 'string' || expected.length !== actual.length + 1) return -1;
  let expectedIndex = 0;
  let actualIndex = 0;
  let missingIndex = -1;
  while (expectedIndex < expected.length && actualIndex < actual.length) {
    if (expected[expectedIndex] === actual[actualIndex]) {
      expectedIndex += 1;
      actualIndex += 1;
      continue;
    }
    if (missingIndex !== -1) return -1;
    missingIndex = expectedIndex;
    expectedIndex += 1;
  }
  if (expectedIndex < expected.length) {
    if (missingIndex !== -1 || expectedIndex !== expected.length - 1) return -1;
    missingIndex = expectedIndex;
  }
  return missingIndex;
}

async function enterExactServerUrlWithKeyboard(page, locator, expected, profile) {
  let evidence = null;
  let missingCharacterRepairApplied = false;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await locator.click();
    await locator.press('Control+A');
    await locator.pressSequentially(expected, { delay: 60 });
    await page.waitForTimeout(150);
    evidence = await safeServerUrlInputEvidence(locator, expected);
    if (!evidence.exactMatch) {
      const actualValue = await locator.inputValue().catch(() => '');
      const missingIndex = findSingleMissingCharacterIndex(expected, actualValue);
      if (missingIndex >= 0) {
        await locator.press('Home');
        for (let position = 0; position < missingIndex; position += 1) {
          await locator.press('ArrowRight');
        }
        await locator.pressSequentially(expected[missingIndex], { delay: 80 });
        missingCharacterRepairApplied = true;
        await page.waitForTimeout(150);
        evidence = await safeServerUrlInputEvidence(locator, expected);
      }
    }
    console.log(`${profile} server URL keyboard re-entry safe evidence`,
      JSON.stringify({ attempt, missingCharacterRepairApplied, ...evidence }));
    if (evidence.exactMatch) break;
  }
  if (!evidence?.exactMatch) {
    throw new Error(`${profile} server URL did not retain the exact value after keyboard entry`);
  }
  await locator.press('Tab').catch(() => {});
  evidence = await safeServerUrlInputEvidence(locator, expected);
  if (!evidence.exactMatch) {
    throw new Error(`${profile} server URL changed before connection submission`);
  }
  console.log(`${profile} server URL keyboard re-entry safe evidence`,
    JSON.stringify({ phase: 'ready-to-submit', ...evidence }));
  return evidence;
}

async function paste(page, label, value) {
  const locator = await field(page, label);
  const inputInfo = await locator.evaluate((element) => ({
    tagName: element.tagName,
    type: element.type || null,
    rows: element.rows || null,
    multiline: element instanceof HTMLTextAreaElement,
    ariaLabel: element.getAttribute('aria-label'),
  }));
  const attempts = [];
  const noteAttempt = async (method, text) => {
    attempts.push({ method, ...inspectPrivateKey(text, value) });
  };
  await page.evaluate(async (text) => navigator.clipboard.writeText(text), value);
  await locator.click();
  await locator.press('Control+A');
  await locator.press('Control+V');
  await page.waitForTimeout(250);
  let actual = await locator.inputValue();
  await noteAttempt('clipboard paste', actual);
  if (actual !== value) {
    await locator.press('Control+A');
    await locator.press('Control+V');
    await page.waitForTimeout(250);
    actual = await locator.inputValue();
    await noteAttempt('clipboard paste retry', actual);
  }
  if (actual !== value) {
    await locator.click();
    await locator.press('Control+A');
    await page.keyboard.insertText(value);
    await page.waitForTimeout(150);
    actual = await locator.inputValue();
    await noteAttempt('keyboard insertText', actual);
  }
  const sameText = (left, right) =>
    left === right || left.replace(/\r\n?/g, '\n') === right.replace(/\r\n?/g, '\n');
  if (!sameText(actual, value)) {
    await locator.fill(value);
    actual = await locator.inputValue();
    await noteAttempt('locator fill', actual);
  }
  await locator.press('Tab').catch(() => {});
  return { actual, inputInfo, attempts };
}

async function readClipboard(page) {
  return page.evaluate(() => navigator.clipboard.readText());
}

async function savePrivateKeyCredential(page, {
  name,
  username,
  keyPath,
  verifyDecryptedRoundTrip = true,
}) {
  await click(page, 'Credentials');
  await click(page, 'Add credential');
  await fill(page, 'Credential name', name);
  await fill(page, 'SSH username', username);
  await click(page, 'Private key');
  let expected = fs.readFileSync(keyPath, 'utf8').replace(/[\r\n]+$/, '');
  let actual;
  try {
    actual = (await paste(page, 'PEM private key', expected)).actual;
    if (!inspectPrivateKey(actual, expected).publicKeyDerEqual) {
      throw new Error('private-key field did not retain the generated fixture key');
    }
    await click(page, 'Save encrypted credential');
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const savedCredentialCard = page.getByRole('group', {
      name: new RegExp(escapedName),
    }).first();
    await savedCredentialCard.waitFor({ state: 'visible', timeout: 15000 });
    const identifier = await savedCredentialCard.getAttribute(
      'flt-semantics-identifier',
    );
    const prefix = 'ssh-credential-';
    if (!identifier?.startsWith(prefix) || identifier.length <= prefix.length) {
      throw new Error('saved SSH credential semantic identifier was unavailable');
    }
    const credentialId = identifier.slice(prefix.length);
    if (!verifyDecryptedRoundTrip) {
      console.log('encrypted SSH Credential saved for end-to-end authentication',
        JSON.stringify({ decryptedReadbackSkipped: true }));
      return credentialId;
    }
    const actions = savedCredentialCard.getByRole('button');
    assertThat(await actions.count() === 1,
      'saved SSH credential did not expose one edit action');
    await actions.click();
    await page.getByRole('menuitem', { name: 'Edit', exact: true })
      .click({ timeout: 10000 });
    await waitText(page, 'Edit credential');
    const savedKeyField = await field(page, 'PEM private key');
    await savedKeyField.click();
    await page.waitForTimeout(150);
    const decryptedKey = await savedKeyField.inputValue();
    const keyRoundTrip = inspectPrivateKey(decryptedKey, expected);
    console.log('encrypted SSH Credential decrypt round-trip safe evidence', JSON.stringify({
      privateKeyParsed: keyRoundTrip.actualPrivateKeyParsed,
      publicKeyMatchesFixture: keyRoundTrip.publicKeyDerEqual,
      savedPrivateKeyLengthMatches: decryptedKey.length === expected.length,
    }));
    assertThat(keyRoundTrip.actualPrivateKeyParsed && keyRoundTrip.publicKeyDerEqual,
      'saved encrypted SSH credential did not decrypt to the fixture public key');
    await click(page, 'Cancel');
    return credentialId;
  } finally {
    expected = undefined;
    actual = undefined;
  }
}

async function savePasswordCredential(page, { name, username, secret }) {
  let secretValue = secret;
  await click(page, 'Credentials');
  await click(page, 'Add credential');
  await fill(page, 'Credential name', name);
  await fill(page, 'SSH username', username);
  await click(page, 'Password');
  try {
    await fill(page, 'Password', secretValue);
    await click(page, 'Save encrypted credential');
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const savedCredentialCard = page.getByRole('group', {
      name: new RegExp(escapedName),
    }).first();
    await savedCredentialCard.waitFor({ state: 'visible', timeout: 15000 });
    const identifier = await savedCredentialCard.getAttribute(
      'flt-semantics-identifier',
    );
    const prefix = 'ssh-credential-';
    if (!identifier?.startsWith(prefix) || identifier.length <= prefix.length) {
      throw new Error('saved SSH credential semantic identifier was unavailable');
    }
    return identifier.slice(prefix.length);
  } finally {
    secretValue = undefined;
  }
}

async function selectFormOption(page, fieldName, optionName, optionIdentifier = null) {
  const fieldText = page.getByText(fieldName, { exact: true }).last();
  await fieldText.scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {});
  const escapedField = fieldName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const fieldPattern = new RegExp(escapedField, 'i');
  const controls = page.getByRole('button', { name: fieldPattern });
  const findVisibleFieldControl = async () => {
    for (let index = await controls.count() - 1; index >= 0; index -= 1) {
      const candidate = controls.nth(index);
      if (await candidate.isVisible().catch(() => false)) return candidate;
    }
    return null;
  };
  const clickFieldControl = async () => {
    const fieldControl = await findVisibleFieldControl();
    if (fieldControl) {
      await fieldControl.click();
      return true;
    }
    const fieldPoint = await page.evaluate((label) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const matches = [...document.querySelectorAll(
        'flt-semantics[role="button"], flt-semantics[role="combobox"]',
      )].filter((element) => visible(element) &&
        `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
          .toLowerCase().includes(label.toLowerCase()));
      const element = matches.at(-1);
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    }, fieldName);
    if (!fieldPoint) return false;
    await page.mouse.click(fieldPoint.x, fieldPoint.y);
    return true;
  };
  if (!await clickFieldControl()) {
    safeRunStage = `${fieldName} field unavailable`;
    throw new Error('visible form dropdown was unavailable');
  }

  safeRunStage = `${fieldName} option lookup`;
  const optionRoleCounts = await Promise.all([
    page.locator('flt-semantics[role="menuitem"]').count().catch(() => null),
    page.locator('flt-semantics[role="option"]').count().catch(() => null),
  ]);
  console.log('Form dropdown opened', JSON.stringify({
    field: fieldName,
    menuItemSemanticsCount: optionRoleCounts[0],
    optionSemanticsCount: optionRoleCounts[1],
  }));
  if (fieldName === 'Jump Host' && optionIdentifier != null) {
    const identifier = `ssh-jump-host-option-${optionIdentifier}`;
    const option = page.locator(
      `flt-semantics[flt-semantics-identifier="${identifier}"]`,
    );
    let optionCount = 0;
    let optionVisible = false;
    try {
      await option.waitFor({ state: 'attached', timeout: 5000 });
      optionCount = await option.count();
      if (optionCount === 1) {
        await option.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
        optionVisible = await option.isVisible().catch(() => false);
      }
    } catch (_) {
      optionCount = await option.count().catch(() => 0);
    }
    let dropdownReopenedForRetry = false;
    let anyJumpHostOptionCount = await page.locator(
      'flt-semantics[flt-semantics-identifier^="ssh-jump-host-option-"]',
    ).count().catch(() => 0);
    if (optionCount === 0 && anyJumpHostOptionCount === 0) {
      dropdownReopenedForRetry = await clickFieldControl();
      if (dropdownReopenedForRetry) {
        try {
          await option.waitFor({ state: 'attached', timeout: 5000 });
          optionCount = await option.count();
          if (optionCount === 1) {
            await option.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
            optionVisible = await option.isVisible().catch(() => false);
          }
        } catch (_) {
          optionCount = await option.count().catch(() => 0);
        }
        anyJumpHostOptionCount = await page.locator(
          'flt-semantics[flt-semantics-identifier^="ssh-jump-host-option-"]',
        ).count().catch(() => 0);
      }
    }
    const directConnectionOption = page.getByText('Direct connection', {
      exact: true,
    }).last();
    let directConnectionVisible = await directConnectionOption.isVisible()
      .catch(() => false);
    const evidence = await option.evaluate((element, expectedLabel) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const label = normalize([
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].join(' '));
      const rect = element.getBoundingClientRect();
      return {
        labelLength: label.length,
        visible: rect.width > 0 && rect.height > 0,
        inViewport: rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth,
        scrollIntoViewSucceeded: true,
        expectedIdentityVisible: label.includes(normalize(expectedLabel)),
      };
    }, optionName).catch(() => ({
      labelLength: null,
      visible: false,
      inViewport: false,
      scrollIntoViewSucceeded: optionVisible,
      expectedIdentityVisible: false,
    }));
    const matchingMenuLabelCount = await page.evaluate((expectedLabel) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      return [...document.querySelectorAll('flt-semantics')].filter((element) => {
        const rect = element.getBoundingClientRect();
        const label = normalize([
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].join(' '));
        return rect.width > 0 && rect.height > 0 && label.includes(normalize(expectedLabel));
      }).length;
    }, optionName).catch(() => 0);
    console.log('Jump Host option stable identifier evidence', JSON.stringify({
      identifierLength: identifier.length,
      optionCount,
      optionVisible,
      matchingMenuLabelCount,
      directConnectionVisible,
      anyJumpHostOptionCount,
      dropdownReopenedForRetry,
      ...evidence,
    }));
    if (optionCount !== 1 || !optionVisible || !evidence.visible ||
        !evidence.expectedIdentityVisible) {
      safeRunStage = 'Jump Host option stable identifier mismatch';
      throw new Error('Jump Host option identifier did not match the expected Host');
    }
    await option.click({ timeout: 5000 });
    console.log('Jump Host option selected by stable identifier', JSON.stringify({
      exactIdentityVerified: true,
      hitCheckedClick: true,
    }));
    return;
  }
  const exactRoleMatches = [];
  for (const role of ['menuitem', 'option']) {
    const exact = page.getByRole(role, { name: optionName, exact: true });
    const count = await exact.count().catch(() => 0);
    if (count === 1 && await exact.isVisible().catch(() => false)) {
      exactRoleMatches.push({ role, locator: exact });
    }
  }
  if (exactRoleMatches.length === 1) {
    const exactMatch = exactRoleMatches[0];
    await exactMatch.locator.click({ timeout: 5000 });
    console.log('Form dropdown exact semantic option selected', JSON.stringify({
      field: fieldName,
      role: exactMatch.role,
      exactMatchCount: 1,
      selected: true,
    }));
    return;
  }
  console.log('Form dropdown exact semantic option evidence', JSON.stringify({
    field: fieldName,
    uniqueVisibleExactRoleMatchCount: exactRoleMatches.length,
  }));
  let optionEvaluationErrorClass = null;
  const optionEvaluationErrorCounts = {};
  let optionPoint = null;
  const classifyEvaluationError = (error) => {
    const message = String(error?.message || error || '').toLowerCase();
    if (/execution context.*destroyed|cannot find context|context was destroyed/.test(message)) {
      return 'execution_context_destroyed';
    }
    if (/frame was detached|frame detached/.test(message)) return 'frame_detached';
    if (/target.*closed|page.*closed|browser.*closed/.test(message)) return 'target_closed';
    if (/timeout|timed out/.test(message)) return 'timeout';
    return 'other';
  };
  const popupEvidence = async () => page.evaluate(({ expected, fieldName }) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0 &&
        rect.top < window.innerHeight && rect.left < window.innerWidth &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity || 1) > 0;
    };
    const namePart = String(expected).split(' · ')[0];
    const stableStem = namePart.split(/\s+/).slice(0,
      fieldName === 'Jump Host' ? 2 : 3).join(' ');
    const semantics = [...document.querySelectorAll('flt-semantics')];
    const visibleSemantics = semantics.filter(visible);
    const labels = visibleSemantics.map((element) => normalize([
      element.getAttribute('aria-label'), element.innerText,
      element.textContent, element.getAttribute('title'),
    ].join(' ')));
    const exactOptionMatchCount = labels.filter((label) => label.includes(expected)).length;
    const nameMatchCount = labels.filter((label) => label.includes(namePart)).length;
    const stableStemMatchCount = labels.filter((label) => label.includes(stableStem)).length;
    const roleCounts = {};
    for (const element of semantics) {
      const role = element.getAttribute('role') || 'unlabeled';
      if (['menu', 'menuitem', 'listbox', 'option'].includes(role)) {
        roleCounts[role] = (roleCounts[role] || 0) + 1;
      }
    }
    const expandedFieldCount = visibleSemantics.filter((element) =>
      (element.getAttribute('aria-label') || '').toLowerCase().includes(fieldName.toLowerCase()) &&
      element.getAttribute('aria-expanded') === 'true').length;
    return {
      readyState: document.readyState,
      semanticsCount: semantics.length,
      visibleSemanticsCount: visibleSemantics.length,
      roleCounts,
      expandedFieldCount,
      exactOptionMatchCount,
      nameMatchCount,
      stableStemMatchCount,
      popupOpenEvidence: expandedFieldCount > 0 ||
        Object.values(roleCounts).some((count) => count > 0) || exactOptionMatchCount > 0,
    };
  }, { expected: optionName, fieldName }).catch((error) => ({
    diagnosticUnavailable: true,
    errorCategory: classifyEvaluationError(error),
  }));
  const findOptionPoint = async (timeoutMs) => {
    const deadline = Date.now() + timeoutMs;
    let candidate = null;
    while (!candidate && Date.now() < deadline) {
      candidate = await page.evaluate(({ expected, fieldName }) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    };
    const options = [...document.querySelectorAll('flt-semantics')].flatMap((element) => {
      if (!visible(element)) return [];
      const label = normalize([
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].join(' '));
      const rect = element.getBoundingClientRect();
      return [{ label, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }];
    });
    const contains = (label, needle) =>
      label.toLowerCase().includes(String(needle).toLowerCase());
    const matching = options.filter((item) => contains(item.label, expected))
      .sort((left, right) => left.label.length - right.label.length);
    if (matching.length) return matching[0];
    const namePart = String(expected).split(' · ')[0];
    const uniqueNameMatches = options.filter((item) => contains(item.label, namePart));
    if (uniqueNameMatches.length === 1) return uniqueNameMatches[0];
      const wordCount = fieldName === 'Jump Host' ? 2 : 3;
    const stableStem = namePart.split(/\s+/).slice(0, wordCount).join(' ');
    const uniqueStemMatches = options.filter((item) => contains(item.label, stableStem));
    return uniqueStemMatches.length === 1 ? uniqueStemMatches[0] : null;
      }, { expected: optionName, fieldName }).catch((error) => {
        optionEvaluationErrorClass = error?.name || 'error';
        const category = classifyEvaluationError(error);
        optionEvaluationErrorCounts[category] = (optionEvaluationErrorCounts[category] || 0) + 1;
        return null;
      });
      if (!candidate) await page.waitForTimeout(100);
    }
    return candidate;
  };
  optionPoint = await findOptionPoint(fieldName === 'Jump Host' ? 15000 : 5000);
  if (!optionPoint && fieldName === 'Jump Host') {
    // Flutter can rebuild the Host editor immediately after the dropdown is
    // opened. Reacquire the visible control after closing the overlay, then
    // repeat the exact visible-label match. Failure still rejects the Host save.
    console.log('Form dropdown retry after empty Jump Host option list',
      JSON.stringify({
        field: fieldName,
        retry: 1,
        evaluationErrorCounts: optionEvaluationErrorCounts,
        beforeRetry: await popupEvidence(),
      }));
    await page.keyboard.press('Escape').catch(() => {});
    await page.waitForTimeout(150);
    fieldControl = await findVisibleFieldControl();
    if (fieldControl) await fieldControl.click();
    else {
      console.log('Form dropdown retry control unavailable', JSON.stringify({
        field: fieldName,
        visibleControlCount: await controls.count().catch(() => null),
      }));
    }
    optionPoint = await findOptionPoint(10000);
  }
  if (optionPoint) {
    console.log('Form dropdown option candidate', JSON.stringify({
      field: fieldName,
      labelLength: optionPoint.label.length,
    }));
    await page.mouse.click(optionPoint.x, optionPoint.y);
    console.log('Form dropdown option clicked', JSON.stringify({ field: fieldName }));
    return;
  }
  for (const role of ['menuitem', 'option']) {
    const candidate = page.getByRole(role, { name: optionName, exact: true }).last();
    if (await candidate.isVisible().catch(() => false)) {
      await candidate.click();
      console.log('Form dropdown role fallback clicked', JSON.stringify({ field: fieldName }));
      return;
    }
  }
  const textOption = page.getByText(optionName, { exact: true }).last();
  if (await textOption.isVisible().catch(() => false)) {
    await textOption.click();
    console.log('Form dropdown text fallback clicked', JSON.stringify({ field: fieldName }));
    return;
  }
  if (!optionPoint) {
    let diagnosticEvaluationErrorClass = null;
    let diagnosticEvaluationErrorCategory = null;
    const evidence = await page.evaluate(({ expected, fieldName }) => {
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const namePart = String(expected).split(' · ')[0];
      const usernamePart = String(expected).split(' · ')[1] || '';
      const fieldLabel = fieldName;
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const matchingFields = [...document.querySelectorAll(
        'flt-semantics[role="button"], flt-semantics[role="combobox"]',
      )].filter(visible).map((element) => {
        const label = normalize([
          element.getAttribute('aria-label'), element.innerText, element.textContent,
        ].join(' '));
        return {
          role: element.getAttribute('role') || '',
          ariaLabelLength: (element.getAttribute('aria-label') || '').length,
          textLength: (element.innerText || '').length,
          containsRequestedField: label.toLowerCase().includes(fieldLabel.toLowerCase()),
        };
      }).filter((item) => item.containsRequestedField);
      const nodes = [...document.querySelectorAll('flt-semantics')]
        .filter(visible).map((element) => {
        const label = normalize([
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].join(' '));
        const lower = label.toLowerCase();
        let category = 'other';
        if (lower.includes('relay bastion key')) category = 'bastion_credential';
        else if (lower.includes('relay target key')) category = 'target_credential';
        else if (label.includes(expected)) category = 'full_match';
        else if (label.includes(namePart)) category = 'record_name';
        else if (usernamePart && label.includes(usernamePart)) category = 'username';
        else if (lower.includes('no credential')) category = 'no_credential';
        else if (lower.includes('inherit')) category = 'inherit';
        else if (lower.includes('direct connection')) category = 'direct_connection';
        return {
          role: element.getAttribute('role') || '',
          labelLength: label.length,
          category,
        };
      });
      const categories = {};
      for (const item of nodes) categories[item.category] = (categories[item.category] || 0) + 1;
      return {
        requestedNameVisibleInRenderedText: (document.body.innerText || '')
          .toLowerCase().includes(namePart.toLowerCase()),
        requestedNameSemanticMatchCount: nodes.filter((item) =>
          item.label.toLowerCase().includes(namePart.toLowerCase())).length,
        visibleOptionCount: nodes.length,
        matchingFieldCount: matchingFields.length,
        matchingFieldRoles: [...new Set(matchingFields.map((item) => item.role))],
        matchingFieldLabelLengths: matchingFields.map((item) => ({
          ariaLabelLength: item.ariaLabelLength,
          textLength: item.textLength,
        })),
        optionRoleCount: nodes.filter((item) => item.role === 'option').length,
        menuItemRoleCount: nodes.filter((item) => item.role === 'menuitem').length,
        optionCategories: categories,
      };
    }, { expected: optionName, fieldName }).catch((error) => {
      diagnosticEvaluationErrorClass = error?.name || 'error';
      diagnosticEvaluationErrorCategory = safeErrorSummary(error).category;
      return { diagnosticUnavailable: true };
    });
    const fallbackPageState = await page.evaluate(() => {
      const semantics = [...document.querySelectorAll('flt-semantics')];
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity || 1) > 0;
      };
      const visibleSemantics = semantics.filter(visible);
      const menuRoleCounts = {};
      for (const element of semantics) {
        const role = element.getAttribute('role') || 'unlabeled';
        if (role === 'menuitem' || role === 'option' || role === 'listbox' || role === 'menu') {
          menuRoleCounts[role] = (menuRoleCounts[role] || 0) + 1;
        }
      }
      return {
        readyState: document.readyState,
        semanticsCount: semantics.length,
        visibleSemanticsCount: visibleSemantics.length,
        menuRoleCounts,
        bodyTextLength: (document.body?.innerText || '').length,
        visibleJumpHostFieldCount: visibleSemantics.filter((element) =>
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`
            .toLowerCase().includes('jump host')).length,
      };
    }).catch((error) => ({
      diagnosticUnavailable: true,
      errorType: error?.name || 'Error',
      errorCategory: safeErrorSummary(error).category,
    }));
    console.log('Form dropdown safe evidence', JSON.stringify({
      field: fieldName,
      requestedOptionLabelLength: optionName.length,
      optionEvaluationErrorClass,
      optionEvaluationErrorCounts,
      finalPopupState: await popupEvidence(),
      diagnosticEvaluationErrorClass,
      diagnosticEvaluationErrorCategory,
      ...evidence,
      fallbackPageState,
    }));
    safeRunStage = `${fieldName} option unavailable`;
    throw new Error('visible form option was unavailable');
  }
  await page.mouse.click(optionPoint.x, optionPoint.y);
}

async function selectExactHostCredentialOverride(page, expectedIdentity, credentialId) {
  const fieldName = 'SSH credential override';
  if (typeof credentialId !== 'string' || credentialId.length === 0) {
    throw new Error('SSH credential override target identifier was unavailable');
  }
  const expectedIdentifier = `ssh-host-credential-override-${credentialId}`;
  const fieldLabel = page.getByText(fieldName, { exact: true }).last();
  await fieldLabel.scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {});
  const visibleCredentialControlCount = () => page.evaluate(() => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    return [...document.querySelectorAll(
      'flt-semantics[role="button"], flt-semantics[role="combobox"]',
    )].filter((element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        normalize([
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].join(' ')).toLowerCase().includes(fieldName.toLowerCase());
    }).length;
  }).catch(() => 0);
  let credentialControlCount = await visibleCredentialControlCount();
  for (let attempt = 0; credentialControlCount === 0 && attempt < 4; attempt += 1) {
    const jumpAnchor = await page.evaluate(() => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden';
      };
      const matches = [...document.querySelectorAll(
        'flt-semantics[role="button"], flt-semantics[role="combobox"]',
      )].filter((element) => visible(element) && normalize([
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].join(' ')).toLowerCase().includes('jump host'));
      const element = matches.length === 1 ? matches[0] : null;
      if (!element) return {
        matchCount: matches.length,
        role: null,
        hitVerified: false,
        point: null,
      };
      const rect = element.getBoundingClientRect();
      const inViewport = rect.left >= 0 && rect.top >= 0 &&
        rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const hit = inViewport ? document.elementFromPoint(x, y) : null;
      const hitVerified = Boolean(hit && (hit === element || element.contains(hit)));
      return {
        matchCount: matches.length,
        role: element.getAttribute('role') || '',
        hitVerified,
        point: inViewport && hitVerified ? { x, y } : null,
      };
    }).catch(() => null);
    if (!jumpAnchor?.point || !jumpAnchor.hitVerified) {
      console.log('SSH credential override scroll anchor evidence', JSON.stringify({
        attempt: attempt + 1,
        credentialControlCount,
        jumpHostAnchorCount: jumpAnchor?.matchCount || 0,
        role: jumpAnchor?.role || null,
        hitVerified: jumpAnchor?.hitVerified === true,
        scrolled: false,
      }));
      break;
    }
    await page.mouse.move(jumpAnchor.point.x, jumpAnchor.point.y);
    await page.mouse.wheel(0, 360);
    await page.waitForTimeout(120);
    credentialControlCount = await visibleCredentialControlCount();
    console.log('SSH credential override scroll anchor evidence', JSON.stringify({
      attempt: attempt + 1,
      credentialControlCount,
      jumpHostAnchorCount: jumpAnchor.matchCount,
      role: jumpAnchor.role,
      hitVerified: true,
      scrolled: true,
    }));
  }
  const saveButtons = page.getByRole('button', {
    name: 'Save encrypted host', exact: true,
  });
  const visibleSaveButtons = [];
  for (let index = 0; index < await saveButtons.count(); index += 1) {
    const candidate = saveButtons.nth(index);
    if (await candidate.isVisible().catch(() => false)) visibleSaveButtons.push(candidate);
  }
  if (visibleSaveButtons.length !== 1) {
    console.log('SSH credential override editor scope evidence', JSON.stringify({
      visibleSaveHostCount: visibleSaveButtons.length,
      currentEditorScoped: false,
    }));
    throw new Error('SSH credential override editor scope was ambiguous');
  }
  const saveBox = await visibleSaveButtons[0].boundingBox().catch(() => null);
  if (!saveBox) throw new Error('SSH credential override save control was unavailable');
  const controlPoint = await page.evaluate(({ expectedField, saveRect }) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden';
    };
    const candidates = [...document.querySelectorAll(
      'flt-semantics[role="button"], flt-semantics[role="combobox"]',
    )].filter((element) => {
      if (!visible(element)) return false;
      const label = normalize([
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].join(' ')).toLowerCase();
      if (!label.includes(expectedField.toLowerCase())) return false;
      const rect = element.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const sameEditorColumn = centerX >= saveRect.x - 450 &&
        centerX <= saveRect.x + saveRect.width + 450;
      const aboveSaveAction = rect.bottom <= saveRect.y;
      return sameEditorColumn && aboveSaveAction;
    });
    const checked = candidates.map((element) => {
      const rect = element.getBoundingClientRect();
      const inViewport = rect.left >= 0 && rect.top >= 0 &&
        rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const hit = inViewport ? document.elementFromPoint(x, y) : null;
      return {
        element,
        role: element.getAttribute('role') || '',
        rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
        x,
        y,
        inViewport,
        hitVerified: Boolean(hit && (hit === element || element.contains(hit))),
      };
    });
    const selected = candidates.length === 1 && checked.length === 1 &&
      checked[0].inViewport && checked[0].hitVerified ? checked[0] : null;
    return {
      candidateCount: candidates.length,
      viewportHitMatchCount: checked.filter((item) =>
        item.inViewport && item.hitVerified).length,
      roles: [...new Set(candidates.map((element) => element.getAttribute('role') || ''))],
      selectedRole: selected?.role || null,
      inViewport: selected?.inViewport === true,
      hitVerified: selected?.hitVerified === true,
      semanticId: selected?.element.getAttribute('id') || null,
      point: selected ? { x: selected.x, y: selected.y } : null,
      rect: selected?.rect || null,
    };
  }, {
    expectedField: fieldName,
    saveRect: { x: saveBox.x, y: saveBox.y, width: saveBox.width, height: saveBox.height },
  }).catch(() => null);
  console.log('SSH credential override editor scope evidence', JSON.stringify({
    visibleSaveHostCount: visibleSaveButtons.length,
    semanticCandidateCount: controlPoint?.candidateCount || 0,
    viewportHitMatchCount: controlPoint?.viewportHitMatchCount || 0,
    roles: controlPoint?.roles || [],
    hitVerified: controlPoint?.hitVerified === true,
    currentEditorScoped: Boolean(controlPoint?.point),
  }));
  if (!controlPoint?.point || !controlPoint.hitVerified || !controlPoint.rect) {
    throw new Error('SSH credential override control could not be verified in the active editor');
  }
  const markerBeforeOpen = await page.evaluate(({ identifier, expected }) => {
    const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
    const candidates = [...document.querySelectorAll(
      'flt-semantics[flt-semantics-identifier]',
    )].filter((element) =>
      element.getAttribute('flt-semantics-identifier') === identifier);
    const exactLabel = (element) => [
      element.getAttribute('aria-label'), element.innerText,
      element.textContent, element.getAttribute('title'),
    ].map(normalize).some((label) => label === expected);
    const menuOwnedCount = candidates.filter((element) => {
      const item = element.closest('flt-semantics[role="menuitem"]');
      const itemId = item?.getAttribute('id');
      if (!itemId) return false;
      return [...document.querySelectorAll('flt-semantics[role="menu"]')]
        .some((menu) => (menu.getAttribute('aria-owns') || '')
          .split(/\s+/).includes(itemId));
    }).length;
    return {
      markerCount: candidates.length,
      exactLabelMatchCount: candidates.filter(exactLabel).length,
      menuOwnedCount,
    };
  }, { identifier: expectedIdentifier, expected: expectedIdentity })
    .catch(() => ({ markerCount: -1, exactLabelMatchCount: 0, menuOwnedCount: -1 }));
  console.log('SSH credential override popup baseline evidence', JSON.stringify({
    targetMarkerCount: markerBeforeOpen.markerCount,
    exactLabelMatchCount: markerBeforeOpen.exactLabelMatchCount,
    menuOwnedCount: markerBeforeOpen.menuOwnedCount,
  }));
  if (markerBeforeOpen.markerCount > 1 || markerBeforeOpen.markerCount < 0 ||
      (markerBeforeOpen.markerCount === 1 &&
        (markerBeforeOpen.exactLabelMatchCount !== 1 ||
          markerBeforeOpen.menuOwnedCount !== 0)) || !controlPoint.semanticId) {
    throw new Error('SSH credential override target or anchor identity was ambiguous');
  }
  const anchor = controlPoint.rect;
  await page.mouse.click(controlPoint.point.x, controlPoint.point.y);

  let popupEvidence = null;
  let menuScrollAttempts = 0;
  const popupDeadline = Date.now() + 5000;
  while (Date.now() < popupDeadline) {
    popupEvidence = await page.evaluate(({
      expected,
      identifier,
      anchorRect,
      anchorSemanticId,
    }) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity || 1) > 0;
      };
      const intersects = (rect, other) =>
        rect.left < other.x + other.width && rect.right > other.x &&
        rect.top < other.y + other.height && rect.bottom > other.y;
      const exactLabel = (element) => [
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].map(normalize).some((label) => label === expected);
      const candidates = [...document.querySelectorAll(
        'flt-semantics[flt-semantics-identifier]',
      )].filter((element) =>
        element.getAttribute('flt-semantics-identifier') === identifier);
      const checked = candidates.map((element) => {
        const rect = element.getBoundingClientRect();
        let menuItem = element.closest('flt-semantics[role="menuitem"]');
        if (!menuItem) {
          let parent = element.parentElement;
          while (parent && !menuItem) {
            if (parent.matches?.('flt-semantics[role="menuitem"]')) {
              menuItem = parent;
            }
            parent = parent.parentElement;
          }
        }
        const itemRect = menuItem?.getBoundingClientRect();
        const markerInViewport = rect.left >= 0 && rect.top >= 0 &&
          rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
        const itemInViewport = Boolean(itemRect && itemRect.left >= 0 && itemRect.top >= 0 &&
            itemRect.right <= window.innerWidth &&
            itemRect.bottom <= window.innerHeight);
        const outsideAnchor = !intersects(rect, anchorRect) && Boolean(itemRect) &&
          !intersects(itemRect, anchorRect);
        const itemX = itemRect ? itemRect.left + itemRect.width / 2 : 0;
        const itemY = itemRect ? itemRect.top + itemRect.height / 2 : 0;
        const hit = itemInViewport ? document.elementFromPoint(itemX, itemY) : null;
        const hitVerified = Boolean(hit && menuItem &&
          (hit === menuItem || menuItem.contains(hit)));
        const itemId = menuItem?.getAttribute('id') || '';
        const owningMenus = itemId ? [...document.querySelectorAll(
          'flt-semantics[role="menu"]',
        )].filter((menu) => visible(menu) &&
          (menu.getAttribute('aria-owns') || '').split(/\s+/).includes(itemId)) : [];
        return {
          labelExact: exactLabel(element),
          candidateVisible: visible(element),
          menuItemRole: menuItem?.getAttribute('role') || '',
          menuItemNameExact: Boolean(menuItem && exactLabel(menuItem)),
          itemIsNotAnchor: Boolean(menuItem && menuItem !== element &&
            menuItem.getAttribute('id') !== anchorSemanticId &&
            element.getAttribute('id') !== anchorSemanticId),
          markerInViewport,
          itemInViewport,
          outsideAnchor,
          hitVerified,
          owningMenuCount: owningMenus.length,
          owningMenuRoles: [...new Set(owningMenus.map((menu) =>
            menu.getAttribute('role') || ''))],
          point: hitVerified ? { x: itemX, y: itemY } : null,
        };
      });
      const accepted = checked.filter((item) => item.labelExact &&
        item.candidateVisible && item.menuItemRole === 'menuitem' &&
        item.menuItemNameExact && item.itemIsNotAnchor && item.itemInViewport &&
        item.hitVerified && item.owningMenuCount === 1);
      return {
        markerCount: candidates.length,
        exactLabelMatchCount: checked.filter((item) => item.labelExact).length,
        menuItemRoleMatchCount: checked.filter((item) =>
          item.menuItemRole === 'menuitem' && item.menuItemNameExact).length,
        owningMenuCount: checked.length === 1 ? checked[0].owningMenuCount : 0,
        roles: [...new Set(checked.map((item) => item.menuItemRole).filter(Boolean))],
        inViewport: checked.length === 1 && checked[0].itemInViewport,
        markerInViewport: checked.length === 1 && checked[0].markerInViewport,
        outsideAnchor: accepted.length === 1 && accepted[0].outsideAnchor,
        hitVerified: accepted.length === 1 && accepted[0].hitVerified,
        selectedCandidateCount: accepted.length,
        point: accepted.length === 1 ? accepted[0].point : null,
      };
    }, {
      expected: expectedIdentity,
      identifier: expectedIdentifier,
      anchorRect: { x: anchor.x, y: anchor.y, width: anchor.width, height: anchor.height },
      anchorSemanticId: controlPoint.semanticId,
    }).catch(() => null);
    if (popupEvidence?.selectedCandidateCount === 1 && popupEvidence.point) break;
    if (popupEvidence?.markerCount === 1 &&
        popupEvidence.exactLabelMatchCount === 1 &&
        popupEvidence.menuItemRoleMatchCount === 1 &&
        popupEvidence.owningMenuCount === 1 &&
        popupEvidence.inViewport === false) {
      const scrollEvidence = await page.evaluate(({ identifier, expected, anchorSemanticId }) => {
        const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
        const exactLabel = (element) => [
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].map(normalize).some((label) => label === expected);
        const candidates = [...document.querySelectorAll(
          'flt-semantics[flt-semantics-identifier]',
        )].filter((element) =>
          element.getAttribute('flt-semantics-identifier') === identifier &&
          exactLabel(element));
        if (candidates.length !== 1) return { scrolled: false, count: candidates.length };
        const element = candidates[0];
        let menuItem = element.closest('flt-semantics[role="menuitem"]');
        if (!menuItem) {
          let parent = element.parentElement;
          while (parent && !menuItem) {
            if (parent.matches?.('flt-semantics[role="menuitem"]')) menuItem = parent;
            parent = parent.parentElement;
          }
        }
        if (!menuItem || menuItem.getAttribute('id') === anchorSemanticId ||
            !exactLabel(menuItem)) return { scrolled: false, count: 1 };
        const itemId = menuItem.getAttribute('id');
        const visible = (node) => {
          const rect = node.getBoundingClientRect();
          const style = getComputedStyle(node);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity || 1) > 0;
        };
        const owners = [...document.querySelectorAll('flt-semantics[role="menu"]')]
          .filter((menu) => visible(menu) &&
            (menu.getAttribute('aria-owns') || '').split(/\s+/).includes(itemId));
        if (owners.length !== 1) return { scrolled: false, count: 1 };
        const owner = owners[0];
        const rect = owner.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const inViewport = rect.left >= 0 && rect.top >= 0 &&
          rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
        const hit = inViewport ? document.elementFromPoint(x, y) : null;
        const hitVerified = Boolean(hit && (hit === owner || owner.contains(hit)));
        return {
          scrolled: false,
          count: 1,
          menuRect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
          menuItemRect: (() => {
            const itemRect = menuItem.getBoundingClientRect();
            return { x: itemRect.left, y: itemRect.top, width: itemRect.width, height: itemRect.height };
          })(),
          scrollPoint: inViewport && hitVerified ? { x, y } : null,
          hitVerified,
        };
      }, {
        identifier: expectedIdentifier,
        expected: expectedIdentity,
        anchorSemanticId: controlPoint.semanticId,
      }).catch(() => ({ scrolled: false, count: 0 }));
      if (scrollEvidence.scrollPoint && menuScrollAttempts < 6) {
        menuScrollAttempts += 1;
        await page.mouse.move(scrollEvidence.scrollPoint.x, scrollEvidence.scrollPoint.y);
        await page.mouse.wheel(0, 420);
        await page.waitForTimeout(120);
      }
      if (menuScrollAttempts === 1 || !scrollEvidence.scrollPoint) {
        console.log('SSH credential override exact menu scroll evidence', JSON.stringify({
          ...scrollEvidence,
          attempt: menuScrollAttempts,
        }));
      }
    }
    await page.waitForTimeout(100);
  }
  console.log('SSH credential override popup candidate evidence', JSON.stringify({
    markerCount: popupEvidence?.markerCount || 0,
    exactLabelMatchCount: popupEvidence?.exactLabelMatchCount || 0,
    menuItemRoleMatchCount: popupEvidence?.menuItemRoleMatchCount || 0,
    owningMenuCount: popupEvidence?.owningMenuCount || 0,
    roles: popupEvidence?.roles || [],
    outsideAnchor: popupEvidence?.outsideAnchor === true,
    inViewport: popupEvidence?.inViewport === true,
    hitVerified: popupEvidence?.hitVerified === true,
    selectedCandidateCount: popupEvidence?.selectedCandidateCount || 0,
  }));
  if (popupEvidence?.selectedCandidateCount !== 1 || !popupEvidence.point) {
    throw new Error('SSH credential override exact popup option was unavailable');
  }
  await page.mouse.click(popupEvidence.point.x, popupEvidence.point.y);
  console.log('SSH credential override popup selection', JSON.stringify({
    exactMatchCount: 1,
    menuBoundaryVerified: true,
    hitVerified: true,
    selected: true,
  }));
}

async function waitForHostCredentialResolution(page, {
  credentialName,
  username,
  phase,
  dialogTitle,
  required = true,
  timeoutMs = 10000,
}) {
  const expectedIdentity = `${credentialName} · ${username}`;
  const expectedResolution = `Host override: ${expectedIdentity}`;
  const deadline = Date.now() + timeoutMs;
  let evidence = null;
  while (Date.now() < deadline) {
    evidence = await page.evaluate(({ expected, expectedDialogTitle }) => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden';
      };
      const dialogs = [...document.querySelectorAll(
        'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
      )].filter(visible);
      const activeDialog = dialogs.filter((element) => {
        const label = normalize([
          element.getAttribute('aria-label'), element.innerText,
          element.textContent, element.getAttribute('title'),
        ].join(' '));
        return label.includes(expectedDialogTitle);
      }).at(-1) || null;
      const nodes = activeDialog
        ? [activeDialog, ...activeDialog.querySelectorAll('flt-semantics')]
          .filter(visible).map((element) => ({
          role: element.getAttribute('role') || '',
          sources: [
            element.getAttribute('aria-label'), element.innerText,
            element.textContent, element.getAttribute('title'),
          ].map(normalize).filter(Boolean),
          label: normalize([
            element.getAttribute('aria-label'), element.innerText,
            element.textContent, element.getAttribute('title'),
          ].join(' ')),
          }))
        : [];
      const resolutions = nodes.filter((item) =>
        /host override:|inherited from |credential is unavailable|host override is unavailable|group default is unavailable/i.test(item.label));
      const credentialControls = nodes.filter((item) =>
        /ssh credential override/i.test(item.label));
      return {
        activeDialogFound: activeDialog !== null,
        matchingVisibleDialogCount: dialogs.filter((element) => {
          const label = normalize([
            element.getAttribute('aria-label'), element.innerText,
            element.textContent, element.getAttribute('title'),
          ].join(' '));
          return label.includes(expectedDialogTitle);
        }).length,
        expectedIdentityVisible: nodes.some((item) => item.label.includes(expected)),
        expectedEffectiveTextVisible: nodes.some((item) =>
          item.sources.includes(`Host override: ${expected}`)),
        effectiveResolutionNodeCount: resolutions.length,
        effectiveResolutionHasExpectedIdentity: resolutions.some((item) =>
          item.label.includes(expected)),
        effectiveResolutionKinds: [...new Set(resolutions.map((item) => {
          if (/^host override:/i.test(item.label)) return 'host_override';
          if (/^inherited from /i.test(item.label)) return 'group_default';
          return 'unavailable';
        }))],
        credentialControlCount: credentialControls.length,
        credentialControlShowsExpectedIdentity: credentialControls.some((item) =>
          item.label.includes(expected)),
        credentialControlShowsTargetBCategory: credentialControls.some((item) =>
          /relay target key b/i.test(item.label)),
        credentialControlShowsBastionCategory: credentialControls.some((item) =>
          /relay bastion key/i.test(item.label)),
      };
    }, { expected: expectedIdentity, expectedDialogTitle: dialogTitle }).catch(() => ({ available: false }));
    if (evidence.expectedEffectiveTextVisible) return evidence;
    await page.waitForTimeout(100);
  }
  console.log('SSH Host credential resolution safe diagnostic', JSON.stringify({
    phase,
    dialogTitleLength: dialogTitle.length,
    ...evidence,
  }));
  if (!required) return evidence;
  throw new Error('Host effective credential did not match the selected SSH credential');
}

async function waitForHostEditorDialogClose(page, timeoutMs = 2500) {
  try {
    await page.waitForFunction(() => {
      const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          style.display !== 'none' && style.visibility !== 'hidden';
      };
      return ![...document.querySelectorAll(
        'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
      )].filter(visible).some((element) => normalize([
        element.getAttribute('aria-label'), element.innerText,
        element.textContent, element.getAttribute('title'),
      ].join(' ')).includes('Edit host'));
    }, null, { timeout: timeoutMs });
    return true;
  } catch (_) {
    return false;
  }
}

async function createSshHost(page, {
  name,
  address,
  port,
  username,
  credentialName,
  credentialId,
  jumpHostChoice = null,
  jumpHostIdentifier = null,
  knownJumpHostNames = [],
  verifySavedCredentialOverride = false,
  verifySavedCredentialAfterSave = verifySavedCredentialOverride,
}) {
  safeRunStage = 'SSH Host editor: navigate to Hosts';
  await click(page, 'Hosts');
  if (jumpHostChoice && !jumpHostIdentifier) {
    const jumpHostName = jumpHostChoice.split(' · ')[0];
    const escapedJumpHostName = jumpHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const jumpHostCard = page.getByRole('group', {
      name: new RegExp(escapedJumpHostName),
    }).first();
    safeRunStage = 'SSH Host Jump Host candidate card readiness';
    await jumpHostCard.waitFor({ state: 'visible', timeout: 15000 });
  }
  safeRunStage = 'SSH Host editor: open Add host';
  await openSshHostEditor(page);
  safeRunStage = 'SSH Host editor: wait for Add a host dialog';
  await waitText(page, 'Add a host');
  safeRunStage = 'SSH Host editor: fill Display name';
  await fill(page, 'Display name', name);
  safeRunStage = 'SSH Host editor: fill Hostname or IP';
  await fill(page, 'Hostname or IP', address);
  safeRunStage = 'SSH Host editor: fill Port';
  await fill(page, 'Port', String(port));
  safeRunStage = 'SSH Host editor: fill SSH username';
  await fill(page, 'SSH username', username);
  if (jumpHostChoice) {
    safeRunStage = 'SSH Host Jump Host selection';
    await selectFormOption(page, 'Jump Host', jumpHostChoice, jumpHostIdentifier);
  }
  // Route selection can rebuild the Host form. Choose the endpoint credential
  // last so the state verified below is exactly the state being saved. The
  // KBI cancellation case retains a saved password credential so the server
  // can advertise password as a later factor; cancellation must not use it.
  let exactOverrideVerified = !verifySavedCredentialOverride;
  if (credentialName != null) {
    safeRunStage = 'SSH Host credential selection';
    const expectedCredentialIdentity = `${credentialName} · ${username}`;
    try {
      if (verifySavedCredentialOverride) {
      let exactReadback = false;
      for (let attempt = 0; attempt < 2; attempt += 1) {
        safeRunStage = `SSH Host credential exact selection attempt ${attempt + 1}`;
        await selectExactHostCredentialOverride(
          page, expectedCredentialIdentity, credentialId,
        );
        const resolution = await waitForHostCredentialResolution(page, {
          credentialName,
          username,
          phase: `before_save_attempt_${attempt + 1}`,
          dialogTitle: 'Add a host',
          required: false,
          timeoutMs: 5000,
        });
        exactReadback = resolution.expectedEffectiveTextVisible === true;
        console.log('SSH Host credential exact readback', JSON.stringify({
          attempt: attempt + 1,
          exactEffectiveMatch: exactReadback,
          credentialControlShowsExpectedIdentity:
            resolution.credentialControlShowsExpectedIdentity === true,
          effectiveResolutionKinds: resolution.effectiveResolutionKinds || [],
        }));
        if (exactReadback) break;
        if (attempt === 0) {
          console.log('SSH Host credential exact reselection scheduled', JSON.stringify({
            attempt: 1,
            exactEffectiveMatch: false,
            reopeningDropdown: true,
          }));
        }
      }
      if (!exactReadback) {
        safeRunStage = 'SSH Host effective credential before save';
        throw new Error('Host effective credential did not match the selected SSH credential');
      }
      exactOverrideVerified = exactReadback;
      } else {
        await selectFormOption(
          page, 'SSH credential override', expectedCredentialIdentity,
        );
      }
    } catch (error) {
      const hostKind = address === '127.0.0.1' ? 'target' : 'bastion';
      safeRunStage = `SSH Host ${hostKind} credential selection`;
      console.log('SSH Host credential selection failed', JSON.stringify({ hostKind }));
      throw error;
    }
    if (verifySavedCredentialOverride) {
      safeRunStage = 'SSH Host effective credential before save';
      assertThat(exactOverrideVerified,
        'Host effective credential exact readback was required before save');
    }
  }
  safeRunStage = 'SSH Host save readiness';
  const saveHostButton = page.getByRole('button', {
    name: 'Save encrypted host', exact: true,
  });
  await saveHostButton.waitFor({ state: 'visible', timeout: 15000 });
  const saveReadinessDeadline = Date.now() + 15000;
  let enabledSamples = 0;
  while (Date.now() < saveReadinessDeadline && enabledSamples < 2) {
    enabledSamples = await saveHostButton.isEnabled().catch(() => false)
      ? enabledSamples + 1 : 0;
    if (enabledSamples < 2) await page.waitForTimeout(100);
  }
  if (enabledSamples < 2) {
    console.log('SSH Host save readiness safe evidence', JSON.stringify({
      visible: await saveHostButton.isVisible().catch(() => false),
      enabled: await saveHostButton.isEnabled().catch(() => false),
      effectiveCredentialWasVerified: verifySavedCredentialOverride,
      displayNameLength: name.length,
      addressLength: address.length,
      portValid: Number.isInteger(Number(port)) && Number(port) > 0,
      usernameLength: username.length,
      hasJumpHost: Boolean(jumpHostChoice),
    }));
    throw new Error('SSH Host save action did not become enabled');
  }
  console.log('SSH Host save readiness safe evidence', JSON.stringify({
    visible: true,
    enabled: true,
    stableEnabledSamples: enabledSamples,
    effectiveCredentialWasVerified: verifySavedCredentialOverride,
  }));
  safeRunStage = 'SSH Host save action';
  await saveHostButton.click();
  safeRunStage = 'SSH Host card visible after save';
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const hostCard = page.getByRole('group', { name: new RegExp(escapedName) }).first();
  await hostCard.waitFor({ state: 'visible', timeout: 15000 });
  if (jumpHostChoice) {
    const jumpHostName = jumpHostChoice.split(' · ')[0];
    safeRunStage = 'SSH Host saved Jump Host route label';
    const cardLabel = await hostCard.getAttribute('aria-label').catch(() => null);
    const semanticRouteLabelVisible = typeof cardLabel === 'string' &&
      cardLabel.includes(`Via Jump Host: ${jumpHostName}`);
    const visibleRouteLabel = hostCard.getByText(
      `Via Jump Host: ${jumpHostName}`, { exact: true },
    );
    const visibleRouteLabelCount = await visibleRouteLabel.count().catch(() => 0);
    const visibleRouteTextMatch = visibleRouteLabelCount === 1 &&
      await visibleRouteLabel.isVisible().catch(() => false);
    const expectedRouteVisible = semanticRouteLabelVisible || visibleRouteTextMatch;
    const knownParentMatches = knownJumpHostNames.map((candidateName, index) => ({
      candidateIndex: index,
      semanticMatch: typeof cardLabel === 'string' && cardLabel.includes(
        `Via Jump Host: ${candidateName}`),
    }));
    const expectedParentCandidateIndex = knownJumpHostNames.findIndex((candidateName) =>
      candidateName === jumpHostName);
    console.log('SSH Host saved Jump Host route safe diagnostic', JSON.stringify({
      expectedJumpHostNameLength: jumpHostName.length,
      expectedParentCandidateIndex,
      cardLabelAvailable: typeof cardLabel === 'string',
      cardLabelLength: typeof cardLabel === 'string' ? cardLabel.length : null,
      routeLabelPrefixPresent: typeof cardLabel === 'string' &&
        cardLabel.includes('Via Jump Host:'),
      semanticRouteLabelVisible,
      visibleRouteLabelCount,
      visibleRouteTextMatch,
      knownParentMatches,
      expectedRouteVisible,
    }));
    assertThat(expectedRouteVisible,
      'saved SSH Host did not expose its exact Jump Host route');
    console.log('SSH Host route display safe evidence', JSON.stringify({
      hasJumpHost: true,
      exactExpectedJumpHostVisible: true,
    }));
  }
  if (verifySavedCredentialOverride && verifySavedCredentialAfterSave) {
    safeRunStage = 'SSH Host saved credential open edit';
    await hostCard.getByRole('button', {
      name: 'Edit host', exact: true,
    }).click();
    safeRunStage = 'SSH Host saved credential resolve';
    const savedCredentialResolution = await waitForHostCredentialResolution(page, {
      credentialName,
      username,
      phase: 'after_save',
      dialogTitle: 'Edit host',
    });
    console.log('SSH Host saved credential safe evidence', JSON.stringify({
      exactExpectedEffectiveCredentialVisible:
        savedCredentialResolution.expectedEffectiveTextVisible === true,
      credentialSecretInspected: false,
    }));
    safeRunStage = 'SSH Host saved credential close edit';
    const cancelEdit = page.getByText('Cancel', { exact: true }).last();
    const cancelCount = await page.getByText('Cancel', { exact: true })
      .count().catch(() => 0);
    const cancelVisible = cancelCount > 0 &&
      await cancelEdit.isVisible().catch(() => false);
    console.log('SSH Host edit close safe evidence', JSON.stringify({
      exactCancelTextCount: cancelCount,
      lastCancelTextVisible: cancelVisible,
    }));
    assertThat(cancelVisible, 'Edit host Cancel text was unavailable');
    await cancelEdit.click({ force: true });
    let editDialogClosed = await waitForHostEditorDialogClose(page);
    let keyboardFallbackUsed = false;
    if (!editDialogClosed) {
      keyboardFallbackUsed = true;
      await page.keyboard.press('Escape');
      editDialogClosed = await waitForHostEditorDialogClose(page);
    }
    console.log('SSH Host edit close result safe evidence', JSON.stringify({
      editDialogClosed,
      keyboardFallbackUsed,
    }));
    assertThat(editDialogClosed, 'Edit host dialog did not close after Cancel');
    await page.waitForTimeout(200);
  }
  return hostCard;
}

async function sshHostRecordIdentifier(hostCard) {
  const identifier = await hostCard.getAttribute('flt-semantics-identifier');
  const prefix = 'ssh-host-';
  if (!identifier?.startsWith(prefix) || identifier.length <= prefix.length) {
    throw new Error('saved SSH Host semantic identifier was unavailable');
  }
  return identifier.slice(prefix.length);
}

async function openSshHostEditor(page) {
  const dialogHeading = page.getByText('Add a host', { exact: true }).first();
  const addHostButtons = page.getByRole('button', {
    name: 'Add host', exact: true,
  });
  const dialogVisible = () => dialogHeading.isVisible().catch(() => false);
  let lastClickError = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (await dialogVisible()) return;
    const buttonCount = await addHostButtons.count().catch(() => 0);
    let candidate = null;
    for (let index = 0; index < buttonCount; index += 1) {
      const current = addHostButtons.nth(index);
      if (await current.isVisible().catch(() => false)) {
        candidate = current;
        break;
      }
    }
    if (!candidate) {
      console.log('SSH Host Add host readiness safe evidence', JSON.stringify({
        attempt: attempt + 1,
        buttonCount,
        visibleButtonCount: 0,
        dialogVisible: false,
        hostsNavigationCount: await page.getByRole('button', {
          name: 'Hosts', exact: true,
        }).count().catch(() => 0),
      }));
      if (attempt < 2) {
        await click(page, 'Hosts').catch(() => {});
        await page.waitForTimeout(500);
      }
      continue;
    }
    try {
      await candidate.click({ timeout: attempt === 0 ? 8000 : 5000 });
    } catch (error) {
      lastClickError = error;
      if (await dialogVisible()) return;
      console.log('SSH Host Add host click safe recovery', JSON.stringify({
        attempt: attempt + 1,
        buttonCount,
        visibleButtonCount: 1,
        errorType: error?.name || 'Error',
        dialogVisible: false,
      }));
      const hit = await page.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            rect.bottom > 0 && rect.right > 0 &&
            rect.top < window.innerHeight && rect.left < window.innerWidth &&
            style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0;
        };
        const candidates = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => visible(element) &&
            (element.getAttribute('aria-label') || element.innerText || '').trim() ===
              'Add host');
        if (candidates.length !== 1) return { candidateCount: candidates.length };
        const target = candidates[0];
        const rect = target.getBoundingClientRect();
        const x = Math.round(rect.left + rect.width / 2);
        const y = Math.round(rect.top + rect.height / 2);
        const hit = document.elementFromPoint(x, y);
        const hitLabel = (element) => element ? {
          tag: element.tagName,
          role: element.getAttribute('role'),
          labelLength: (element.getAttribute('aria-label') || '').length,
          textLength: (element.innerText || '').trim().length,
        } : null;
        return {
          candidateCount: 1,
          x,
          y,
          buttonRect: {
            left: Math.round(rect.left),
            top: Math.round(rect.top),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          },
          viewport: { width: window.innerWidth, height: window.innerHeight },
          scrollY: Math.round(window.scrollY),
          ariaDisabled: target.getAttribute('aria-disabled'),
          hitIsTarget: Boolean(hit && (hit === target || target.contains(hit) ||
            hit.contains(target))),
          hitElement: hitLabel(hit),
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      console.log('SSH Host Add host hit safe evidence', JSON.stringify({
        attempt: attempt + 1,
        ...hit,
      }));
      if (hit.hitIsTarget) {
        await page.mouse.click(hit.x, hit.y);
        const deadline = Date.now() + 4000;
        while (Date.now() < deadline && !await dialogVisible()) {
          await page.waitForTimeout(100);
        }
        if (await dialogVisible()) return;
      }
      // Flutter can replace a semantics node between Playwright's hit test
      // and the browser-side DOM probe. The role locator still identifies the
      // visible Add host control; retry that exact control with a forced
      // pointer event, then require the editor heading as the success signal.
      const forcedClick = { attempted: false, openedDialog: false, errorType: null };
      if (await candidate.isVisible().catch(() => false) &&
          await candidate.isEnabled().catch(() => false)) {
        forcedClick.attempted = true;
        try {
          await candidate.click({ force: true, timeout: 3000 });
          const forceDeadline = Date.now() + 4000;
          while (Date.now() < forceDeadline && !await dialogVisible()) {
            await page.waitForTimeout(100);
          }
          forcedClick.openedDialog = await dialogVisible();
        } catch (forceError) {
          forcedClick.errorType = forceError?.name || 'Error';
        }
      }
      console.log('SSH Host Add host forced safe recovery', JSON.stringify({
        attempt: attempt + 1,
        candidateVisible: await candidate.isVisible().catch(() => false),
        candidateEnabled: await candidate.isEnabled().catch(() => false),
        ...forcedClick,
      }));
      if (forcedClick.openedDialog) return;
    }
    const deadline = Date.now() + 2500;
    while (Date.now() < deadline && !await dialogVisible()) {
      await page.waitForTimeout(100);
    }
    if (await dialogVisible()) return;
    if (attempt < 2) await click(page, 'Hosts').catch(() => {});
  }
  const finalState = await page.evaluate(() => {
    const isVisible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0;
    };
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')];
    const addButtons = buttons.filter((element) =>
      (element.getAttribute('aria-label') || element.innerText || '').trim() === 'Add host');
    const describeButton = (element) => {
      const rect = element.getBoundingClientRect();
      const x = Math.round(rect.left + rect.width / 2);
      const y = Math.round(rect.top + rect.height / 2);
      const hit = document.elementFromPoint(x, y);
      return {
        role: element.getAttribute('role'),
        labelLength: (element.getAttribute('aria-label') || '').length,
        textLength: (element.innerText || '').trim().length,
        ariaDisabled: element.getAttribute('aria-disabled'),
        rect: {
          left: Math.round(rect.left),
          top: Math.round(rect.top),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        },
        centerHitTag: hit?.tagName || null,
        centerHitRole: hit?.getAttribute('role') || null,
      };
    };
    return {
      addHostSemanticButtonCount: addButtons.length,
      visibleAddHostSemanticButtonCount: addButtons.filter(isVisible).length,
      visibleAddHostDisabledStates: addButtons.filter(isVisible).map((element) =>
        element.getAttribute('aria-disabled')),
      addHostButtons: addButtons.map(describeButton),
      hostCardCount: document.querySelectorAll(
        'flt-semantics[flt-semantics-identifier^="ssh-host-"]').length,
      visibleDialogHeadingCount: [...document.querySelectorAll('flt-semantics')]
        .filter((element) => isVisible(element) &&
          (element.getAttribute('aria-label') || element.innerText || '').trim() ===
            'Add a host').length,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      scrollY: Math.round(window.scrollY),
      documentHeight: document.documentElement.scrollHeight,
    };
  }).catch(() => ({ diagnosticUnavailable: true }));
  console.log('SSH Host Add host final safe evidence', JSON.stringify(finalState));
  if (lastClickError) throw lastClickError;
  throw new Error('SSH Host Add host action did not open the editor');
}

async function installFlutterProbe(context) {
  await context.addInitScript(() => {
    window.__relayProbe = { initializer: false, engine: false, runApp: false, errorClass: null };
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
        let callback;
        Object.defineProperty(loader, 'didCreateEngineInitializer', {
          configurable: true,
          get: () => callback,
          set: (next) => {
            callback = function (engineInitializer) {
              window.__relayProbe.initializer = true;
              const initialize = engineInitializer.initializeEngine.bind(engineInitializer);
              engineInitializer.initializeEngine = (...args) => initialize(...args).then((runner) => {
                window.__relayProbe.engine = true;
                const runApp = runner.runApp.bind(runner);
                runner.runApp = (...runArgs) => Promise.resolve(runApp(...runArgs)).then((result) => {
                  window.__relayProbe.runApp = true;
                  return result;
                }, (error) => {
                  window.__relayProbe.errorClass = error?.name || 'Error';
                  throw error;
                });
                return runner;
              });
              return next(engineInitializer);
            };
          },
        });
      },
    });
  });
}

async function installRelayCloseObserver(context) {
  await context.addInitScript(() => {
    const OriginalWebSocket = window.WebSocket;
    const closeMetadata = [];
    const collaborationCloseMetadata = [];
    let collaborationSocketSequence = 0;
    Object.defineProperty(window, '__relaySocketCloseMetadata', {
      configurable: false,
      enumerable: false,
      writable: false,
      value: closeMetadata,
    });
    Object.defineProperty(window, '__terminalCollaborationSocketCloseMetadata', {
      configurable: false,
      enumerable: false,
      writable: false,
      value: collaborationCloseMetadata,
    });
    window.WebSocket = new Proxy(OriginalWebSocket, {
      construct(target, args) {
        const socket = Reflect.construct(target, args, target);
        try {
          const endpoint = new URL(String(args[0]), window.location.href);
          if (endpoint.pathname.endsWith('/relay/v1/connect') ||
              endpoint.pathname === '/collaboration/v1/connect') {
            const isCollaboration =
              endpoint.pathname === '/collaboration/v1/connect';
            const socketIndex = isCollaboration
              ? ++collaborationSocketSequence : null;
            const socketOpenedAt = isCollaboration ? performance.now() : null;
            socket.addEventListener('close', (event) => {
              const category = event.code === 1000
                ? 'normal'
                : event.code === 1002
                ? 'protocol_error'
                : event.code === 1008
                ? 'policy_rejection'
                : event.code === 1011
                ? 'server_error'
                : event.code === 1006
                ? 'abnormal_transport'
                : 'other';
              const close = {
                ...(isCollaboration ? {
                  socketIndex,
                  ageMs: Math.max(0, Math.round(performance.now() - socketOpenedAt)),
                } : {}),
                code: event.code,
                category,
                wasClean: event.wasClean,
                reasonLength: String(event.reason || '').length,
                reasonCategory: event.reason === 'SESSION_ENDED'
                  ? 'session_ended' : String(event.reason || '') === ''
                  ? 'empty' : 'other',
              };
              (isCollaboration ? collaborationCloseMetadata : closeMetadata)
                .push(close);
            });
          }
        } catch (_) {
          // Diagnostics only: preserve the native WebSocket construction path.
        }
        return socket;
      },
    });
  });
}

async function installBrowserDownloadProbe(context) {
  await context.addInitScript(() => {
    const state = {
      blobUrlsCreated: 0,
      blobUrlsRevoked: 0,
      downloadAnchorsClicked: [],
    };
    Object.defineProperty(window, '__atermiusDownloadProbe', {
      configurable: false,
      enumerable: false,
      writable: false,
      value: state,
    });
    try {
      const create = URL.createObjectURL.bind(URL);
      URL.createObjectURL = (...args) => {
        const result = create(...args);
        state.blobUrlsCreated += 1;
        return result;
      };
      const revoke = URL.revokeObjectURL.bind(URL);
      URL.revokeObjectURL = (...args) => {
        state.blobUrlsRevoked += 1;
        return revoke(...args);
      };
    } catch (_) {
      // Diagnostics only. Never change the browser's Blob URL implementation.
    }
    document.addEventListener('click', (event) => {
      const target = event.target;
      if (!(target instanceof Element)) return;
      const anchor = target.closest('a[download]');
      if (!anchor) return;
      state.downloadAnchorsClicked.push({
        hasBlobUrl: anchor.href.startsWith('blob:'),
        connectedAtClick: anchor.isConnected,
        trustedEvent: event.isTrusted,
        userActivationActive: window.navigator.userActivation?.isActive ?? null,
        suggestedNameLength: anchor.download.length,
      });
    }, true);
  });
}

async function browserDownloadProbeSummary(page) {
  return page.evaluate(() => {
    const state = window.__atermiusDownloadProbe;
    const text = document.body.innerText || '';
    return {
      blobUrlsCreated: state?.blobUrlsCreated ?? null,
      blobUrlsRevoked: state?.blobUrlsRevoked ?? null,
      downloadAnchorsClicked: state?.downloadAnchorsClicked ?? [],
      sftpPageVisible: /SFTP file browser/.test(text),
      fileErrorVisible: /(?:download|transfer).{0,40}(?:failed|error)|(?:下载|传输).{0,20}(?:失败|错误)|(?:exception|denied|no such file|无权限|无效)/i.test(text),
    };
  });
}

async function installFilePickerProbe(page) {
  await page.evaluate(() => {
    const state = {
      fileInputsAdded: 0,
      fileInputsRemoved: 0,
      fileInputClicks: [],
      fileInputEvents: [],
      windowFocusEvents: 0,
    };
    window.__relayFilePickerProbe = state;
    const isFileInput = (node) => node instanceof HTMLInputElement && node.type === 'file';
    const fileInputsIn = (node) => {
      if (!(node instanceof Element)) return [];
      const matches = [];
      if (isFileInput(node)) matches.push(node);
      matches.push(...node.querySelectorAll('input[type="file"]'));
      return matches;
    };
    new MutationObserver((records) => {
      for (const record of records) {
        for (const [action, nodes] of [['added', record.addedNodes], ['removed', record.removedNodes]]) {
          for (const node of nodes) {
            const matches = fileInputsIn(node);
            if (action === 'added') state.fileInputsAdded += matches.length;
            else state.fileInputsRemoved += matches.length;
          }
        }
      }
    }).observe(document.body, { childList: true, subtree: true });
    document.addEventListener('click', (event) => {
      const target = event.target;
      if (!isFileInput(target)) return;
      state.fileInputClicks.push({
        trustedEvent: event.isTrusted,
        connectedAtClick: target.isConnected,
        userActivationActive: navigator.userActivation?.isActive ?? null,
        inputHasFilesBeforeSelection: Boolean(target.files?.length),
      });
    }, true);
    for (const type of ['input', 'change']) {
      document.addEventListener(type, (event) => {
        const target = event.target;
        if (!isFileInput(target)) return;
        const files = target.files;
        let fileByteLength = 0;
        if (files) {
          for (let index = 0; index < files.length; index++) {
            fileByteLength += files.item(index)?.size || 0;
          }
        }
        state.fileInputEvents.push({
          type,
          trustedEvent: event.isTrusted,
          connectedAtEvent: target.isConnected,
          userActivationActive: navigator.userActivation?.isActive ?? null,
          fileCount: files?.length || 0,
          fileByteLength,
        });
      }, true);
    }
    window.addEventListener('focus', () => { state.windowFocusEvents += 1; });
  });
}

async function filePickerProbeSummary(page) {
  return page.evaluate(() => {
    const state = window.__relayFilePickerProbe;
    const text = document.body.innerText || '';
    return {
      fileInputsAdded: state?.fileInputsAdded ?? null,
      fileInputsRemoved: state?.fileInputsRemoved ?? null,
      fileInputClicks: state?.fileInputClicks ?? [],
      fileInputEvents: state?.fileInputEvents ?? [],
      documentObservedFileInputChange: Boolean(
        state?.fileInputEvents?.some((event) => event.type === 'change')),
      windowFocusEvents: state?.windowFocusEvents ?? null,
      sftpPageVisible: /SFTP file browser/.test(text),
      errorOrUnsupportedMessageVisible: /(?:error|failed|unsupported|denied|不支持|失败|错误|权限)/i.test(text),
    };
  });
}

async function fileChooserElementSummary(chooser, page) {
  const element = await chooser.element();
  const elementDetails = await element.evaluate((node) => {
    const root = node.getRootNode();
    const rootKind = root === node.ownerDocument
      ? 'document'
      : root instanceof ShadowRoot
        ? 'shadow_root'
        : root === node
          ? 'detached_element'
          : 'other';
    return {
      tagName: node.tagName,
      type: node instanceof HTMLInputElement ? node.type : null,
      isConnected: node.isConnected,
      accept: node instanceof HTMLInputElement ? node.accept : null,
      multiple: node instanceof HTMLInputElement ? node.multiple : null,
      rootKind,
      rootHostTag: root instanceof ShadowRoot ? root.host.tagName : null,
      ownerFrameIsMain: node.ownerDocument.defaultView === node.ownerDocument.defaultView?.top,
      userActivationActiveAtInspection:
        node.ownerDocument.defaultView?.navigator.userActivation?.isActive ?? null,
    };
  });
  const clickProbe = await filePickerProbeSummary(page).catch(() => null);
  const lastInputClick = clickProbe?.fileInputClicks?.at(-1) || null;
  return {
    ...elementDetails,
    clickEventObservedByPageProbe: Boolean(lastInputClick),
    clickEventIsTrusted: lastInputClick?.trustedEvent ?? null,
    userActivationActiveAtClick: lastInputClick?.userActivationActive ?? null,
  };
}

async function enableSemantics(page) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const ready = await page.evaluate(() =>
      typeof window.sodium?.ready?.then === 'function' &&
      window.__relayProbe?.runApp === true &&
      Boolean(document.querySelector('flt-semantics-placeholder')));
    if (ready) break;
    await page.waitForTimeout(100);
  }
  const startup = await page.evaluate(() => ({
    runApp: window.__relayProbe?.runApp === true,
    errorClass: window.__relayProbe?.errorClass || null,
    sodium: typeof window.sodium?.ready?.then === 'function',
    placeholder: Boolean(document.querySelector('flt-semantics-placeholder')),
  }));
  assertThat(startup.runApp && startup.sodium && startup.placeholder,
    `Flutter Web did not reach runApp/accessibility startup (${JSON.stringify(startup)})`);
  const sodium = await page.evaluate(() => Promise.race([
    window.sodium.ready.then(() => 'resolved', () => 'rejected'),
    new Promise((resolve) => setTimeout(() => resolve('timeout'), 10000)),
  ]));
  assertThat(sodium === 'resolved', `sodium initialization state was ${sodium}`);
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await page.locator('flt-semantics').first().waitFor({ state: 'attached', timeout: 15000 });
}

async function uiSummary(page) {
  try {
    const pageSummary = await page.evaluate(() => {
      const visible = (element) => {
        let rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0 || rect.bottom <= 0 ||
            rect.right <= 0 || rect.top >= window.innerHeight ||
            rect.left >= window.innerWidth) return false;
        for (let parent = element; parent instanceof Element;
            parent = parent.parentElement) {
          const style = getComputedStyle(parent);
          if (style.display === 'none' || style.visibility === 'hidden' ||
              Number(style.opacity) === 0 ||
              parent.getAttribute('aria-hidden') === 'true' ||
              parent.hasAttribute('inert')) return false;
          if (parent === document.body) continue;
          const clip = parent.getBoundingClientRect();
          if (['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowX)) {
            rect = { ...rect, left: Math.max(rect.left, clip.left),
              right: Math.min(rect.right, clip.right) };
          }
          if (['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowY)) {
            rect = { ...rect, top: Math.max(rect.top, clip.top),
              bottom: Math.min(rect.bottom, clip.bottom) };
          }
          if (rect.right <= rect.left || rect.bottom <= rect.top) return false;
        }
        return true;
      };
      const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
        .filter(visible)
        .map((element) => `${element.getAttribute('aria-label') || ''}\n${element.innerText || ''}`)
        .join('\n');
      const text = visibleSemanticText;
      const terminalTabStates = [...document.querySelectorAll('flt-semantics[role="button"]')]
        .filter(visible)
        .map((element) => element.getAttribute('aria-label') || '')
        .map((label) => label.match(/ terminal tab, (connecting|connected|disconnected|failed), (active|inactive)$/))
        .filter(Boolean)
        .map((match) => ({ state: match[1], active: match[2] === 'active' }));
      let connectionFailureCategory = null;
      if (text.includes('SSH connection failed')) {
        if (text.includes('SSH 握手失败')) connectionFailureCategory = 'ssh_handshake';
        else if (text.includes('SSH 身份验证失败')) connectionFailureCategory = 'ssh_authentication';
        else if (text.includes('SSH 网络连接已中断')) connectionFailureCategory = 'ssh_network';
        else if (text.includes('SSH 已验证身份，但无法打开终端会话')) connectionFailureCategory = 'ssh_session';
        else if (text.includes('SSH 主机密钥验证失败')) connectionFailureCategory = 'host_key_verification';
        else if (text.includes('已拒绝尚未信任的 SSH 主机密钥')) connectionFailureCategory = 'host_key_rejected';
        else if (text.includes('SSH 主机密钥与已保存指纹不同')) connectionFailureCategory = 'host_key_changed';
        else if (text.includes('无法建立 SSH 中继 WebSocket')) connectionFailureCategory = 'relay_transport';
        else if (text.includes('SSH 中继票据已失效')) connectionFailureCategory = 'relay_ticket';
        else if (text.includes('Bad state:') && text.includes('SSH')) connectionFailureCategory = 'ssh_controller_state';
        else if (text.includes('TimeoutException') || text.includes('超时')) connectionFailureCategory = 'timeout';
        else if (text.includes('Vault') || text.includes('vault') || text.includes('同步')) connectionFailureCategory = 'vault_sync_or_state';
        else if (text.includes('SSH') || text.includes('ssh')) connectionFailureCategory = 'ssh_other';
        else connectionFailureCategory = 'other';
      }
      const connectionFailureHints = connectionFailureCategory == null ? null : {
        badState: text.includes('Bad state:'),
        timeout: text.includes('TimeoutException') || text.includes('超时'),
        vault: text.includes('Vault') || text.includes('vault'),
        knownHost: /KnownHost|host.key|主机密钥/i.test(text),
        approval: /approval|approved|reviewed|审批|信任已在/i.test(text),
        proof: /proof|信任证明|审批证明/i.test(text),
        sync: /sync|同步|readback/i.test(text),
        transition: /transition|membership|snapshot|成员关系|状态切换/i.test(text),
        changed: /changed|stale|changed|发生变化|已变化/i.test(text),
        authentication: /auth|身份验证|认证/i.test(text),
        protocol: /protocol|handshake|握手|协议/i.test(text),
      };
      const roleCounts = {};
      for (const element of document.querySelectorAll('flt-semantics')) {
        const role = element.getAttribute('role') || 'unlabeled';
        roleCounts[role] = (roleCounts[role] || 0) + 1;
      }
      return {
        urlPath: location.pathname,
        bodyTextLength: text.length,
        semanticNodeCount: document.querySelectorAll('flt-semantics').length,
        semanticRoleCounts: roleCounts,
        terminalTabStates,
        connectionFailureCategory,
        connectionFailureHints,
        visibleUiSignals: {
          hostKeyPrompt: text.includes('Verify SSH host key'),
          trustAction: text.includes('Trust after verification'),
          connected: /\bCONNECTED\b/.test(text),
          timeoutException: /TimeoutException/i.test(text) || text.includes('SSH 中继连接超时。'),
          relayTransportError: text.includes('无法建立 SSH 中继 WebSocket。'),
          relayTicketError: text.includes('SSH 中继票据已失效'),
          hostKeyVerificationError: text.includes('SSH 主机密钥验证失败'),
          hostKeyRejected: text.includes('已拒绝尚未信任的 SSH 主机密钥'),
          hostKeyChanged: text.includes('SSH 主机密钥与已保存指纹不同'),
          sshAuthError: /authentication failed|public.?key authentication failed|认证失败|身份验证失败/i.test(text),
          sshProtocolError: /SSH.{0,24}(protocol|handshake|identification|kex)|SSH.{0,24}(协议|握手)/i.test(text),
        },
      };
    });
    const inputs = await page.locator('input,textarea').evaluateAll((elements) => elements.map((element) => ({
      tagName: element.tagName,
      type: element.type || null,
      rows: element.rows || null,
      valueLength: element.value?.length || 0,
      disabled: Boolean(element.disabled),
      visible: element.getClientRects().length > 0,
    })));
    const trustButtons = page.getByRole('button', {
      name: 'Trust after verification',
      exact: true,
    });
    const trustButtonCount = await trustButtons.count().catch(() => 0);
    let visibleTrustActionButtonCount = 0;
    for (let index = 0; index < trustButtonCount; index += 1) {
      if (await trustButtons.nth(index).isVisible().catch(() => false)) {
        visibleTrustActionButtonCount += 1;
      }
    }
    return { ...pageSummary, visibleTrustActionButtonCount, inputs };
  } catch (_) {
    return { summaryUnavailable: true };
  }
}

function logFileSummary(filePath) {
  try {
    const stats = fs.statSync(filePath);
    return { present: true, bytes: stats.size };
  } catch (_) {
    return { present: false };
  }
}

function sshdRuntimeSummary(filePath) {
  try {
    const stats = fs.statSync(filePath);
    const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
    const count = (pattern) => lines.filter((line) => pattern.test(line)).length;
    return {
      present: true,
      bytes: stats.size,
      lineCount: lines.filter(Boolean).length,
      listenerStarts: count(/Server listening on /i),
      tcpConnectionsAccepted: count(/Connection from /i),
      connectionsClosed: count(/Connection closed by /i),
      serverSshBannerEmitted: count(/Local version string SSH-/i),
      clientSshBannerReceived: count(/Remote protocol version /i),
      keyExchangeStarted: count(/SSH2_MSG_KEXINIT|kex: algorithm:/i),
      keyExchangeErrors: count(/kex_exchange_identification|Unable to negotiate|Bad protocol version/i),
      publicKeyAccepted: count(/Accepted publickey/i),
      publicKeyRejected: count(/Failed publickey|userauth_pubkey.*failed/i),
      publicKeyLogMentions: count(/public.?key/i),
      authorizedKeysLogMentions: count(/authorized[_ ]keys/i),
      authorizedKeysFileLookups: count(/trying public key file/i),
      authorizedKeysMatches: count(/matching key found/i),
      authorizedKeysUnavailable: count(/(?:could not|unable to|failed to).{0,50}authorized_keys|authorized_keys.{0,60}(?:no such file|permission denied|failed)/i),
      permissionDenialLogMentions: count(/permission denied|access denied/i),
      authorizedKeysRefusedByMode: count(/authentication refused:.*(?:owner|mode)|bad ownership or modes/i),
      keysNotAllowed: count(/key is not allowed|key .* is not allowed/i),
      signatureAlgorithmMentions: count(/signature algorithm/i),
      authorizedKeyOptionMentions: count(/key options:|authorized.?keys.{0,50}option/i),
      authorizedKeyOptionRejections: count(/(?:invalid|unsupported|not allowed).{0,40}key option|key option.{0,40}(?:invalid|unsupported|not allowed)/i),
      accountPolicyDenials: count(/invalid user|not allowed because|account is locked|account disabled/i),
      validUserPublicKeyChecks: count(/userauth_pubkey: valid user/i),
      invalidUserPublicKeyChecks: count(/userauth_pubkey: invalid user/i),
      signedPublicKeyAttempts: count(/userauth_pubkey:.*(?:signature|signed)/i),
      publicKeyProbeAttempts: count(/userauth_pubkey:.*(?:test|query)/i),
      keyAlgorithmRefusals: count(/not in PubkeyAcceptedAlgorithms|key type .* not allowed/i),
      authenticationFailures: count(/authentication failure|failed publickey|userauth_pubkey.*failed/i),
      sessionOpenRequests: count(/subsystem request|shell request|exec request/i),
      sessionStarts: count(/starting session:/i),
      commandSessionStarts: count(/starting session: command for/i),
      remoteExecFailures: count(/failed to execute|exec request failed|could not execute/i),
      homeDirectoryErrors: count(/could not chdir to home directory|failed to chdir|home directory.*(?:missing|not found)/i),
      commandNotFoundErrors: count(/command not found|no such file or directory.*(?:bash|id)/i),
      chrootFailures: count(/bad ownership or modes|chroot.*(?:failed|error|not found)|(?:failed|error).{0,40}chroot/i),
      missingRuntimeFiles: count(/no such file or directory/i),
      preauthDisconnects: count(/preauth/i),
      sftpSubsystemRequests: count(/subsystem request for sftp/i),
      sftpSubsystemStarts: count(/starting session: subsystem ['"]sftp['"]/i),
      sftpSubsystemErrors: count(/(?:sftp.{0,40}(?:error|failed)|(?:error|failed).{0,40}sftp)/i),
    };
  } catch (_) {
    return { present: false };
  }
}

function sshForwardingRequestCount(filePaths) {
  let count = 0;
  for (const filePath of filePaths) {
    try {
      const contents = fs.readFileSync(filePath, 'utf8');
      count += contents.split(/\r?\n/).filter((line) =>
        /direct-tcpip|forwarded-tcpip|tcpip-forward|port forwarding request/i.test(line),
      ).length;
    } catch (_) {}
  }
  return count;
}

async function loopbackTcpListenerEvidence(port, timeoutMs = 750) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let finished = false;
    const finish = (result, error) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      if (error) reject(error);
      else resolve(result);
    };
    socket.setTimeout(timeoutMs, () => finish(null,
      new Error('loopback listener probe timed out')));
    socket.once('connect', () => finish({ listening: true }));
    socket.once('error', (error) => {
      if (error.code === 'ECONNREFUSED') {
        finish({ listening: false });
      } else {
        finish(null, new Error('loopback listener probe failed'));
      }
    });
  });
}

function sshdDiagnosticDelta(before, after) {
  const result = {};
  for (const key of [
    'lineCount', 'listenerStarts', 'tcpConnectionsAccepted',
      'connectionsClosed', 'serverSshBannerEmitted', 'clientSshBannerReceived',
      'keyExchangeStarted', 'keyExchangeErrors', 'publicKeyAccepted',
      'publicKeyRejected', 'preauthDisconnects', 'sftpSubsystemRequests',
      'sftpSubsystemStarts', 'sftpSubsystemErrors',
      'authorizedKeysFileLookups', 'authorizedKeysMatches',
      'authorizedKeysUnavailable', 'permissionDenialLogMentions',
      'publicKeyLogMentions', 'authorizedKeysLogMentions',
      'authorizedKeysRefusedByMode', 'keysNotAllowed',
      'signatureAlgorithmMentions', 'authorizedKeyOptionMentions',
      'authorizedKeyOptionRejections', 'accountPolicyDenials',
      'validUserPublicKeyChecks', 'invalidUserPublicKeyChecks',
    'signedPublicKeyAttempts', 'publicKeyProbeAttempts',
    'keyAlgorithmRefusals', 'authenticationFailures',
    'sessionOpenRequests', 'sessionStarts', 'commandSessionStarts',
  ]) {
    result[key] = (after[key] || 0) - (before?.[key] || 0);
  }
  return result;
}

function safeErrorSummary(error) {
  const message = String(error?.message || error || '');
  const name = ['TimeoutError', 'TargetClosedError', 'Error'].includes(error?.name)
    ? error.name
    : 'Error';
  let category = 'other';
  if (/timeout|timed out/i.test(message)) category = 'timeout';
  else if (/closed|detached|destroyed/i.test(message)) category = 'browser_target_closed';
  else if (/not visible|not attached|intercepts pointer|outside of the viewport/i.test(message)) {
    category = 'locator_unavailable';
  } else if (/strict mode violation/i.test(message)) category = 'locator_ambiguous';
  return { name, category };
}

function safeBrowserConsoleName(message) {
  const text = String(message || '');
  const match = text.match(/\b(TypeError|ReferenceError|RangeError|SyntaxError|AssertionError|StateError|UnsupportedError|DartError)\b/);
  return match?.[1] || 'Error';
}

function safeBrowserStage(stage) {
  const details = safeBrowserConsoleDetails('', stage);
  return {
    stageCategory: details.stageCategory,
    stageOperation: details.stageOperation,
    stageDetail: details.stageDetail,
  };
}

const SAFE_BROWSER_HTTP_METHODS = new Set([
  'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS',
]);

function safeBrowserHttpMethod(method) {
  const normalized = String(method || '').toUpperCase();
  return SAFE_BROWSER_HTTP_METHODS.has(normalized) ? normalized : 'OTHER';
}

function safeBrowserConsoleApiCorrelations(
  consoleEvents,
  consoleCaptureTimes,
  responseEvents,
  requestFailureEvents,
  windowMs = 2000,
) {
  const safeWindowMs = Number.isSafeInteger(windowMs)
    ? Math.max(0, Math.min(10000, windowMs)) : 2000;
  return consoleEvents
    .filter((event) => typeof event.sourceApiPath === 'string')
    .map((event) => {
      const route = event.sourceApiPath;
      const capturedAtMs = consoleCaptureTimes.get(event.sequence);
      const routeIsSpecific = [
        '/api/v1/auth/recovery/contexts',
        '/api/v1/notifications/tickets',
        '/api/v1/vaults/{id}/presence',
      ].includes(route);
      const withinWindow = (candidateTime) =>
        Number.isFinite(capturedAtMs) && Number.isFinite(candidateTime) &&
        Math.abs(candidateTime - capturedAtMs) <= safeWindowMs;
      const nearbyResponses = routeIsSpecific
        ? responseEvents
          .filter((candidate) => candidate.path === route &&
            candidate.profile === event.profile &&
            withinWindow(candidate.capturedAtMs))
          .map((candidate) => ({
            profile: candidate.profile === 'B' ? 'B' : 'A',
            method: safeBrowserHttpMethod(candidate.method),
            httpStatus: Number.isSafeInteger(candidate.status) &&
                candidate.status >= 100 && candidate.status <= 599
              ? candidate.status : null,
            deltaMs: Math.round(candidate.capturedAtMs - capturedAtMs),
          }))
          .sort((a, b) => Math.abs(a.deltaMs) - Math.abs(b.deltaMs))
          .slice(0, 5)
        : [];
      const nearbyFailures = routeIsSpecific
        ? requestFailureEvents
          .filter((candidate) => candidate.path === route &&
            candidate.profile === event.profile &&
            withinWindow(candidate.capturedAtMs))
          .map((candidate) => ({
            profile: candidate.profile === 'B' ? 'B' : 'A',
            method: safeBrowserHttpMethod(candidate.method),
            failureCategory: candidate.failureCategory,
            failureCode: candidate.failureCode,
            requestElapsedMs: Number.isSafeInteger(candidate.requestElapsedMs)
              ? candidate.requestElapsedMs : null,
            requestStartStageCategory: candidate.requestStartStageCategory,
            requestStartStageOperation: candidate.requestStartStageOperation,
            requestStartStageDetail: candidate.requestStartStageDetail,
            failureStageCategory: candidate.stageCategory,
            failureStageOperation: candidate.stageOperation,
            failureStageDetail: candidate.stageDetail,
            deltaMs: Math.round(candidate.capturedAtMs - capturedAtMs),
          }))
          .sort((a, b) => Math.abs(a.deltaMs) - Math.abs(b.deltaMs))
          .slice(0, 5)
        : [];
      const nearbyPresenceUnauthorized = route === '/api/v1/vaults/{id}/presence'
        ? responseEvents.find((candidate) => candidate.path === route &&
          candidate.profile === event.profile && candidate.status === 401 &&
          withinWindow(candidate.capturedAtMs))
        : null;
      const nearbyUnauthorizedTicket = route === '/api/v1/notifications/tickets'
        ? responseEvents.find((candidate) => candidate.path === route &&
          candidate.profile === event.profile && candidate.status === 401 &&
          withinWindow(candidate.capturedAtMs))
        : null;
      const authLifecycleAnchor = nearbyPresenceUnauthorized ||
        nearbyUnauthorizedTicket;
      const nearbyAuthLifecycleResponses = authLifecycleAnchor
        ? responseEvents
          .filter((candidate) =>
            ['/api/v1/auth/refresh', '/api/v1/notifications/tickets']
              .includes(candidate.path) &&
            candidate.profile === event.profile &&
            Number.isFinite(candidate.capturedAtMs) &&
            Math.abs(candidate.capturedAtMs - authLifecycleAnchor.capturedAtMs) <= 5000)
          .map((candidate) => ({
            profile: candidate.profile === 'B' ? 'B' : 'A',
            routeCategory: candidate.path === '/api/v1/auth/refresh'
              ? 'auth_refresh' : 'notification_ticket',
            method: safeBrowserHttpMethod(candidate.method),
            httpStatus: Number.isSafeInteger(candidate.status) &&
                candidate.status >= 100 && candidate.status <= 599
              ? candidate.status : null,
            deltaFromUnauthorizedMs: Math.round(
              candidate.capturedAtMs - authLifecycleAnchor.capturedAtMs,
            ),
          }))
          .sort((a, b) => Math.abs(a.deltaFromUnauthorizedMs) -
            Math.abs(b.deltaFromUnauthorizedMs))
          .slice(0, 5)
        : [];
      return {
        consoleSequence: Number.isSafeInteger(event.sequence) ? event.sequence : null,
        profile: event.profile === 'B' ? 'B' : 'A',
        sourceApiPath: route,
        correlationWindowMs: safeWindowMs,
        correlationStatus: routeIsSpecific
          ? nearbyResponses.length > 0 || nearbyFailures.length > 0
            ? 'nearby_route_event'
            : 'no_nearby_route_event'
          : 'route_not_specific',
        nearbyResponses,
        nearbyFailedRequests: nearbyFailures,
        nearbyAuthLifecycleResponses,
      };
    });
}

function safeBrowserConsoleDetails(message, stage) {
  const text = String(message || '');
  const stageText = String(stage || '').toLowerCase();
  let stageCategory = 'other';
  if (stageText.includes('sftp')) stageCategory = 'sftp';
  else if (stageText.includes('non-zero') || stageText.includes('nonzero')) {
    stageCategory = 'snippet_nonzero';
  } else if (stageText.includes('cancellation') || stageText.includes('cancel')) {
    stageCategory = 'snippet_cancel';
  } else if (stageText.includes('snippet') || stageText.includes('batch')) {
    stageCategory = 'snippet';
  }
  else if (stageText.includes('terminal') || stageText.includes('ssh') ||
      stageText.includes('relay')) stageCategory = 'ssh_terminal';
  else if (stageText.includes('sync') || stageText.includes('vault')) stageCategory = 'sync_vault';
  else if (stageText.includes('host')) stageCategory = 'host_setup';
  const signals = [];
  const patterns = [
    ['host_key', /host[ -]?key|fingerprint|known_hosts?/i],
    ['sftp', /sftp|ssh_fx/i],
    ['relay_websocket', /relay|websocket|web socket/i],
    ['credential_auth', /credential|authentication|password|private key/i],
    ['resource_load', /failed to load resource|net::err_/i],
    ['network', /network|socket|connection|http|fetch/i],
    ['size_limit', /file size|too large|size limit|exceeds? .*bytes/i],
    ['conflict', /conflict|stale|changed remotely/i],
    ['browser_policy', /permission|blocked|not allowed|securityerror/i],
    ['storage', /indexeddb|quota|database|storage/i],
    ['flutter_framework', /flutter|framework|renderobject/i],
    ['javascript_exception', /uncaught|unhandled|typeerror|referenceerror|exception/i],
    ['deprecation', /deprecated|will be removed|obsolete/i],
  ];
  for (const [label, pattern] of patterns) {
    if (pattern.test(text)) signals.push(label);
  }
  const messageCategory = signals[0] || 'unclassified';
  let stageOperation = 'other';
  if (stageText.includes('non-zero') || stageText.includes('nonzero')) {
    stageOperation = 'snippet_nonzero_result';
  } else if (stageText.includes('cancel')) {
    stageOperation = 'snippet_cancellation';
  } else if (stageText.includes('batch')) {
    stageOperation = 'snippet_batch';
  } else if (stageText.includes('snippet') && stageText.includes('sync')) {
    stageOperation = 'snippet_sync';
  } else if (stageText.includes('snippet') && stageText.includes('preview')) {
    stageOperation = 'snippet_preview';
  } else if (stageText.includes('snippet') && stageText.includes('result')) {
    stageOperation = 'snippet_result';
  } else if (stageText.includes('snippet') && stageText.includes('save')) {
    stageOperation = 'snippet_save';
  } else if (stageText.includes('snippet')) {
    stageOperation = 'snippet_execution';
  }
  let stageDetail = 'other';
  if (stageText.includes('batch')) {
    if (stageText.includes('chooser') || stageText.includes('target selection')) {
      stageDetail = 'batch_target_selection';
    } else if (stageText.includes('review')) {
      stageDetail = 'batch_review';
    } else if (stageText.includes('single confirmation')) {
      stageDetail = 'batch_confirmation';
    } else if (stageText.includes('wait for both host outcomes')) {
      stageDetail = 'batch_execution_wait';
    } else if (stageText.includes('inspect both host outcomes') ||
        stageText.includes('assert both host outcomes')) {
      stageDetail = 'batch_result';
    } else if (stageText.includes('verify exactly-once')) {
      stageDetail = 'batch_postcondition';
    } else if (stageText.includes('result closes')) {
      stageDetail = 'batch_result_close';
    } else if (stageText.includes('navigates back') ||
        stageText.includes('waits for terminal')) {
      stageDetail = 'batch_return_to_terminal';
    } else {
      stageDetail = 'batch_other';
    }
  }
  return { stageCategory, stageOperation, stageDetail, messageCategory, signals };
}

function safeBrowserConsoleSource(message) {
  try {
    const location = message.location();
    const sourceUrl = String(location.url || '');
    if (!sourceUrl) {
      return {
        sourceCategory: 'no_location',
        sourceHasLocation: false,
        lineNumber: null,
        columnNumber: null,
      };
    }
    const parsed = new URL(sourceUrl);
    const pathname = parsed.pathname;
    const basename = pathname.split('/').filter(Boolean).at(-1) || '';
    let sourceApiPath = null;
    if (pathname === '/api/v1/auth/recovery/contexts') {
      sourceApiPath = '/api/v1/auth/recovery/contexts';
    } else if (pathname === '/api/v1/notifications/tickets') {
      sourceApiPath = '/api/v1/notifications/tickets';
    } else if (/^\/api\/v1\/vaults\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/presence$/i
      .test(pathname)) {
      sourceApiPath = '/api/v1/vaults/{id}/presence';
    } else if (pathname.startsWith('/api/v1/')) {
      sourceApiPath = '/api/v1/{other}';
    }
    let sourceCategory = 'other';
    if (parsed.protocol === 'dart:') sourceCategory = 'flutter_dart_runtime';
    else if (parsed.protocol === 'blob:') sourceCategory = 'blob_script';
    else if (parsed.protocol === 'chrome-extension:') sourceCategory = 'browser_extension';
    else if (parsed.protocol === 'devtools:') sourceCategory = 'browser_internal';
    else if (basename === 'main.dart.js') sourceCategory = 'flutter_main_bundle';
    else if (basename === 'flutter.js' || basename === 'flutter_bootstrap.js') {
      sourceCategory = 'flutter_loader';
    } else if (basename === 'index.html') sourceCategory = 'web_document';
    else if (/\.m?js$/i.test(basename)) sourceCategory = 'other_javascript_bundle';
    else if (/\.wasm$/i.test(basename)) sourceCategory = 'wasm_module';
    const lineNumber = Number.isSafeInteger(location.lineNumber) &&
        location.lineNumber > 0
      ? location.lineNumber
      : null;
    const columnNumber = Number.isSafeInteger(location.columnNumber) &&
        location.columnNumber > 0
      ? location.columnNumber
      : null;
    return {
      sourceCategory,
      sourceApiPath,
      sourceHasLocation: true,
      lineNumber,
      columnNumber,
    };
  } catch (_) {
    return {
      sourceCategory: 'invalid_location',
      sourceApiPath: null,
      sourceHasLocation: false,
      lineNumber: null,
      columnNumber: null,
    };
  }
}

function consoleClassifierSelfTest() {
  const marker = 'console-classifier-secret-marker';
  const details = safeBrowserConsoleDetails(
    `Deprecated operation ${marker} will be removed`,
    'batch structured Snippet result closes',
  );
  assertThat(details.stageOperation === 'snippet_batch',
    'safe console classifier missed the batch Snippet stage');
  assertThat(details.stageDetail === 'batch_result_close',
    'safe console classifier missed the batch result-close substage');
  assertThat(details.messageCategory === 'deprecation' &&
    details.signals.includes('deprecation'),
  'safe console classifier missed a deprecation signal');
  assertThat(!JSON.stringify(details).includes(marker),
    'safe console classifier returned raw console text');
  const unknown = safeBrowserConsoleDetails(
    `unclassified ${marker}`,
    'batch structured Snippet chooser alertdialog role',
  );
  assertThat(unknown.messageCategory === 'unclassified' &&
    unknown.stageDetail === 'batch_target_selection' &&
    !JSON.stringify(unknown).includes(marker),
  'unknown console text was not safely classified');
  const source = safeBrowserConsoleSource({
    location: () => ({
      url: 'https://fixture.invalid/assets/main.dart.js',
      lineNumber: 7,
      columnNumber: 11,
    }),
  });
  assertThat(source.sourceCategory === 'flutter_main_bundle' &&
    source.sourceHasLocation && source.lineNumber === 7 &&
    source.columnNumber === 11 &&
    !JSON.stringify(source).includes('fixture.invalid'),
  'safe console source classification exposed a URL or lost its bundle category');
  const presenceSource = safeBrowserConsoleSource({
    location: () => ({
      url: 'https://fixture.invalid/api/v1/vaults/00000000-0000-4000-8000-000000000001/presence?token=do-not-log',
      lineNumber: 0,
    }),
  });
  assertThat(presenceSource.sourceApiPath === '/api/v1/vaults/{id}/presence' &&
    presenceSource.sourceCategory === 'other' &&
    !JSON.stringify(presenceSource).includes('00000000') &&
    !JSON.stringify(presenceSource).includes('fixture.invalid') &&
    !JSON.stringify(presenceSource).includes('do-not-log'),
  'console source route evidence retained an ID, origin or query string');
  const recoverySource = safeBrowserConsoleSource({
    location: () => ({
      url: 'http://127.0.0.1:12345/api/v1/auth/recovery/contexts?token=do-not-log',
      lineNumber: 0,
    }),
  });
  assertThat(recoverySource.sourceApiPath === '/api/v1/auth/recovery/contexts' &&
    !JSON.stringify(recoverySource).includes('127.0.0.1') &&
    !JSON.stringify(recoverySource).includes('do-not-log'),
  'console source did not retain the safe Recovery route family');
  const notificationTicketSource = safeBrowserConsoleSource({
    location: () => ({
      url: 'http://127.0.0.1:12345/api/v1/notifications/tickets?token=do-not-log',
      lineNumber: 0,
    }),
  });
  assertThat(notificationTicketSource.sourceApiPath ===
      '/api/v1/notifications/tickets' &&
    !JSON.stringify(notificationTicketSource).includes('127.0.0.1') &&
    !JSON.stringify(notificationTicketSource).includes('do-not-log'),
  'console source did not retain the safe notification-ticket route family');
  const missingSource = safeBrowserConsoleSource({
    location: () => ({ url: '', lineNumber: 0 }),
  });
  assertThat(missingSource.sourceCategory === 'no_location' &&
    !missingSource.sourceHasLocation && missingSource.lineNumber === null,
  'safe console source classifier did not identify a missing source location');
  const resourceFailure = safeBrowserConsoleDetails(
    `Failed to load resource: net::ERR_ABORTED ${marker}`,
    'batch structured Snippet result closes',
  );
  assertThat(resourceFailure.messageCategory === 'resource_load' &&
    !JSON.stringify(resourceFailure).includes(marker),
  'resource-load console errors were not classified without exposing message text');
  assertThat(safeBrowserConsoleName(`Uncaught TypeError: ${marker}`) === 'TypeError' &&
    safeBrowserConsoleName(`Uncaught ${marker}`) === 'Error',
  'console error name classifier returned an unapproved value');
  const requestFailure = safeBrowserRequestFailure({
    url: () => 'http://127.0.0.1:43210/api/v1/vaults/00000000-0000-4000-8000-000000000001/sync/push?token=do-not-log',
    method: () => 'POST',
    resourceType: () => 'fetch',
    isNavigationRequest: () => false,
    failure: () => ({ errorText: `net::ERR_ABORTED ${marker}` }),
  }, 'http://127.0.0.1:43210',
  'batch structured Snippet wait for both Host outcomes', 9, {
    startedAt: performance.now() - 25,
    ...safeBrowserStage('profile B syncs the shared Vault'),
  });
  assertThat(requestFailure.path === '/api/v1/vaults/{id}/sync/push' &&
    requestFailure.failureCode === 'ERR_ABORTED' &&
    requestFailure.failureCategory === 'aborted' &&
    requestFailure.httpStatus === null &&
    requestFailure.responseReceived === false &&
    requestFailure.sequence === 9 &&
    requestFailure.stageOperation === 'snippet_batch' &&
    requestFailure.requestStartStageCategory === 'sync_vault' &&
    requestFailure.requestElapsedMs >= 0 &&
    requestFailure.requestElapsedMs < 10000 &&
    !JSON.stringify(requestFailure).includes(marker) &&
    !JSON.stringify(requestFailure).includes('do-not-log') &&
    !JSON.stringify(requestFailure).includes('127.0.0.1'),
  'request failure summary lost safe route/lifecycle fields or exposed URL/query/error text');
  const externalRequestFailure = safeBrowserRequestFailure({
    url: () => `https://private.example/${marker}/asset.js?token=do-not-log`,
    method: () => 'GET',
    resourceType: () => 'script',
    isNavigationRequest: () => false,
    failure: () => null,
  }, 'http://127.0.0.1:43210', 'batch structured Snippet result closes', 10);
  assertThat(externalRequestFailure.path === '/{external}' &&
    externalRequestFailure.originCategory === 'external_origin' &&
    externalRequestFailure.failureCategory === 'unknown' &&
    externalRequestFailure.failureCode === 'unavailable' &&
    !JSON.stringify(externalRequestFailure).includes(marker) &&
    !JSON.stringify(externalRequestFailure).includes('private.example') &&
    !JSON.stringify(externalRequestFailure).includes('do-not-log'),
  'external request failure summary exposed URL data or lost its safe origin category');
  const correlationMarker = 'correlation-private-marker';
  const consoleEvent = {
    sequence: 11,
    profile: 'A',
    sourceApiPath: '/api/v1/vaults/{id}/presence',
  };
  const correlation = safeBrowserConsoleApiCorrelations(
    [consoleEvent],
    new Map([[11, 1000]]),
    [{
      profile: 'A',
      path: '/api/v1/vaults/{id}/presence',
      method: 'POST',
      status: 429,
      capturedAtMs: 1007,
      body: correlationMarker,
      url: `http://127.0.0.1/private?token=${correlationMarker}`,
    }],
    [{
      profile: 'A',
      path: '/api/v1/vaults/{id}/presence',
      method: 'POST',
      failureCategory: 'aborted',
      failureCode: 'ERR_ABORTED',
      requestElapsedMs: 7,
      requestStartStageCategory: 'snippet',
      requestStartStageOperation: 'snippet_batch',
      requestStartStageDetail: 'batch_execution_wait',
      stageCategory: 'snippet',
      stageOperation: 'snippet_batch',
      stageDetail: 'batch_execution_wait',
      capturedAtMs: 1004,
      requestBody: correlationMarker,
    }],
  );
  const serializedCorrelation = JSON.stringify(correlation);
  assertThat(correlation.length === 1 &&
    correlation[0].correlationStatus === 'nearby_route_event' &&
    correlation[0].nearbyResponses[0]?.httpStatus === 429 &&
    correlation[0].nearbyResponses[0]?.method === 'POST' &&
    correlation[0].nearbyFailedRequests[0]?.failureCode === 'ERR_ABORTED' &&
    correlation[0].nearbyFailedRequests[0]?.deltaMs === 4 &&
    !serializedCorrelation.includes(correlationMarker) &&
    !serializedCorrelation.includes('127.0.0.1') &&
    !serializedCorrelation.includes('requestBody') &&
    safeBrowserConsoleApiCorrelations(
      [{ ...consoleEvent, sourceApiPath: '/api/v1/{other}' }],
      new Map([[11, 1000]]),
      [{ profile: 'A', path: '/api/v1/{other}', method: 'POST', status: 500,
        capturedAtMs: 1001 }],
      [],
    )[0].correlationStatus === 'route_not_specific',
  'console/API route correlation retained private fields or trusted an imprecise route');
  const refreshCorrelation = safeBrowserConsoleApiCorrelations(
    [consoleEvent],
    new Map([[11, 1000]]),
    [
      { profile: 'A', path: '/api/v1/vaults/{id}/presence', method: 'POST',
        status: 401, capturedAtMs: 1001 },
      { profile: 'A', path: '/api/v1/auth/refresh', method: 'POST',
        status: 200, capturedAtMs: 1019, body: correlationMarker },
      { profile: 'B', path: '/api/v1/auth/refresh', method: 'POST',
        status: 200, capturedAtMs: 1005, url: `http://127.0.0.1/${correlationMarker}` },
      { profile: 'A', path: '/api/v1/notifications/tickets', method: 'POST',
        status: 401, capturedAtMs: 1009 },
    ],
    [],
  );
  const serializedRefreshCorrelation = JSON.stringify(refreshCorrelation);
  assertThat(refreshCorrelation[0]?.nearbyAuthLifecycleResponses.length === 2 &&
    refreshCorrelation[0]?.nearbyAuthLifecycleResponses[0]?.routeCategory ===
      'notification_ticket' &&
    refreshCorrelation[0]?.nearbyAuthLifecycleResponses[1]?.routeCategory ===
      'auth_refresh' &&
    refreshCorrelation[0]?.nearbyAuthLifecycleResponses[1]?.httpStatus === 200 &&
    refreshCorrelation[0]?.nearbyAuthLifecycleResponses[1]?.deltaFromUnauthorizedMs === 18 &&
    !serializedRefreshCorrelation.includes(correlationMarker) &&
    !serializedRefreshCorrelation.includes('127.0.0.1') &&
    !serializedRefreshCorrelation.includes('body') &&
    !serializedRefreshCorrelation.includes('url'),
  'same-profile auth lifecycle correlation lost status/timing or leaked private fields');
  const ticketCorrelation = safeBrowserConsoleApiCorrelations(
    [{ sequence: 12, profile: 'A',
      sourceApiPath: '/api/v1/notifications/tickets' }],
    new Map([[12, 2000]]),
    [{ profile: 'A', path: '/api/v1/notifications/tickets', method: 'POST',
      status: 401, capturedAtMs: 2001,
    }, { profile: 'A', path: '/api/v1/auth/refresh', method: 'POST',
      status: 200, capturedAtMs: 2019,
    }, { profile: 'A', path: '/api/v1/notifications/tickets', method: 'POST',
      status: 200, capturedAtMs: 3000,
    }],
    [],
  );
  assertThat(ticketCorrelation[0]?.correlationStatus === 'nearby_route_event' &&
    ticketCorrelation[0]?.nearbyResponses[0]?.httpStatus === 401 &&
    ticketCorrelation[0]?.nearbyResponses[0]?.method === 'POST' &&
    ticketCorrelation[0]?.nearbyAuthLifecycleResponses.find((response) =>
      response.routeCategory === 'auth_refresh')?.httpStatus === 200 &&
    ticketCorrelation[0]?.nearbyAuthLifecycleResponses.find((response) =>
      response.routeCategory === 'notification_ticket')?.httpStatus === 200 &&
    ticketCorrelation[0]?.nearbyAuthLifecycleResponses.find((response) =>
      response.routeCategory === 'notification_ticket')?.deltaFromUnauthorizedMs >
      ticketCorrelation[0]?.nearbyAuthLifecycleResponses.find((response) =>
        response.routeCategory === 'auth_refresh')?.deltaFromUnauthorizedMs,
  'notification-ticket console errors lost exact route/status or refresh/retry ordering');
  console.log('WEB-RELAY-CONSOLE-CLASSIFIER-01 passed: console/API correlation retains allowlisted route, method, status and bounded timing without raw message text, URLs or bodies.');
}

function safeNetworkFailureCategory(errorText) {
  const text = String(errorText || '');
  if (/ERR_NAME_NOT_RESOLVED|ENOTFOUND/i.test(text)) return 'dns_failure';
  if (/ERR_CONNECTION_REFUSED|ECONNREFUSED/i.test(text)) return 'connection_refused';
  if (/ERR_TIMED_OUT|ETIMEDOUT|ERR_CONNECTION_TIMED_OUT/i.test(text)) return 'timeout';
  if (/ERR_ABORTED|aborted/i.test(text)) return 'aborted';
  if (/CORS|ERR_BLOCKED_BY_(?:RESPONSE|CLIENT)/i.test(text)) return 'blocked_by_browser_policy';
  if (/ERR_CERT_|certificate/i.test(text)) return 'tls_certificate';
  if (/ERR_SSL_|TLS handshake/i.test(text)) return 'tls_handshake';
  if (/ERR_INTERNET_DISCONNECTED|offline/i.test(text)) return 'offline';
  if (/ERR_PROXY_|proxy/i.test(text)) return 'proxy_failure';
  if (/ERR_ADDRESS_UNREACHABLE|ERR_NETWORK_UNREACHABLE/i.test(text)) return 'unreachable';
  if (/ERR_FAILED/i.test(text)) return 'generic_network_failure';
  if (!text) return 'unknown';
  return 'other';
}

function safeNetworkFailureCode(errorText) {
  const text = String(errorText || '');
  const codes = [
    ['ERR_NAME_NOT_RESOLVED|ENOTFOUND', 'DNS_FAILURE'],
    ['ERR_CONNECTION_REFUSED|ECONNREFUSED', 'CONNECTION_REFUSED'],
    ['ERR_TIMED_OUT|ETIMEDOUT|ERR_CONNECTION_TIMED_OUT', 'TIMEOUT'],
    ['ERR_ABORTED|aborted', 'ERR_ABORTED'],
    ['ERR_BLOCKED_BY_RESPONSE', 'ERR_BLOCKED_BY_RESPONSE'],
    ['ERR_BLOCKED_BY_CLIENT', 'ERR_BLOCKED_BY_CLIENT'],
    ['ERR_CERT_[A-Z_]+', 'TLS_CERTIFICATE_ERROR'],
    ['ERR_SSL_[A-Z_]+', 'TLS_HANDSHAKE_ERROR'],
    ['ERR_INTERNET_DISCONNECTED', 'OFFLINE'],
    ['ERR_PROXY_[A-Z_]+', 'PROXY_ERROR'],
    ['ERR_ADDRESS_UNREACHABLE|ERR_NETWORK_UNREACHABLE', 'UNREACHABLE'],
    ['ERR_FAILED', 'ERR_FAILED'],
  ];
  for (const [pattern, code] of codes) {
    if (new RegExp(pattern, 'i').test(text)) return code;
  }
  return text ? 'unclassified' : 'unavailable';
}

function safeRequestPath(url, sameOrigin) {
  if (!sameOrigin) return '/{external}';
  const pathname = url.pathname;
  if (pathname.startsWith('/api/v1/')) return safeApiRoute(pathname);
  if (pathname === '/' || pathname === '/index.html') return pathname;
  if ([
    '/main.dart.js', '/flutter.js', '/flutter_bootstrap.js',
    '/favicon.png', '/manifest.json',
    '/relay/v1/connect', '/collaboration/v1/connect',
  ].includes(pathname)) return pathname;
  if (pathname.startsWith('/assets/')) return '/assets/{asset}';
  return '/{other}';
}

function safeBrowserRequestStart(stage) {
  return {
    startedAt: performance.now(),
    ...safeBrowserStage(stage),
  };
}

function safeBrowserRequestFailure(
  request, expectedOrigin, stage, sequence, started = null,
) {
  let url;
  try { url = new URL(request.url()); } catch (_) {}
  const failure = request.failure?.();
  const errorText = typeof failure?.errorText === 'string' ? failure.errorText : '';
  let originCategory = 'invalid_url';
  let sameOrigin = false;
  if (url) {
    try {
      sameOrigin = url.origin === new URL(expectedOrigin).origin;
      originCategory = sameOrigin ? 'same_origin' : 'external_origin';
    } catch (_) {}
  }
  const method = String(request.method?.() || '').toUpperCase();
  const safeMethod = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'].includes(method)
    ? method : 'OTHER';
  const resourceType = String(request.resourceType?.() || 'other');
  const safeResourceTypes = new Set([
    'document', 'stylesheet', 'image', 'media', 'font', 'script',
    'texttrack', 'xhr', 'fetch', 'eventsource', 'websocket', 'manifest', 'other',
  ]);
  let navigation = null;
  try { navigation = Boolean(request.isNavigationRequest?.()); } catch (_) {}
  const elapsedMs = Number.isFinite(started?.startedAt)
    ? Math.max(0, Math.min(2147483647,
      Math.round(performance.now() - started.startedAt)))
    : null;
  return {
    sequence,
    requestElapsedMs: elapsedMs,
    requestStartStageCategory: started?.stageCategory || 'unknown',
    requestStartStageOperation: started?.stageOperation || 'other',
    requestStartStageDetail: started?.stageDetail || 'other',
    ...(url ? { path: safeRequestPath(url, sameOrigin) } : { path: '/{unavailable}' }),
    originCategory,
    method: safeMethod,
    resourceType: safeResourceTypes.has(resourceType) ? resourceType : 'other',
    navigation,
    responseReceived: false,
    httpStatus: null,
    failurePhase: 'before_http_response',
    failureDetailsAvailable: Boolean(errorText),
    failureCategory: safeNetworkFailureCategory(errorText),
    failureCode: safeNetworkFailureCode(errorText),
    ...safeBrowserStage(stage),
  };
}

function readRelayDatabaseSummary(dbPath) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    'db=sqlite3.connect(sys.argv[1])',
    "sessions=[{'accessActive':bool(a),'refreshActive':bool(r),'revoked':bool(v),'accountActive':u=='active','deviceActive':d=='active'} for a,r,v,u,d in db.execute(\"select julianday(s.access_expires_at)>julianday('now'),julianday(s.refresh_expires_at)>julianday('now'),s.revoked_at is not null,u.status,d.status from sessions s join users u on u.user_id=s.user_id join devices d on d.device_id=s.device_id order by s.created_at\").fetchall()]",
    "tickets=[{'consumed':bool(c),'targetCleared':bool(i),'unexpired':bool(e)} for c,i,e in db.execute(\"select consumed_at is not null,target_ip='' and target_port=0,julianday(expires_at)>julianday('now') from relay_tickets order by created_at desc limit 4\").fetchall()]",
    "print(json.dumps({'relay_connected_events':db.execute(\"select count(*) from audit_events where action='relay.connected'\").fetchone()[0], 'consumed_tickets':db.execute('select count(*) from relay_tickets where consumed_at is not null').fetchone()[0], 'consumed_targets_cleared':db.execute(\"select count(*) from relay_tickets where consumed_at is not null and target_ip='' and target_port=0\").fetchone()[0], 'session_states':sessions,'latest_tickets':tickets}))",
  ].join(';'), dbPath], { encoding: 'utf8', timeout: 3000 });
  if (result.status !== 0) return { available: false };
  try {
    const summary = JSON.parse(result.stdout);
    return {
      available: true,
      relayConnectedEvents: summary.relay_connected_events,
      consumedTickets: summary.consumed_tickets,
      consumedTargetsCleared: summary.consumed_targets_cleared,
      sessionStates: summary.session_states,
      latestTickets: summary.latest_tickets,
    };
  } catch (_) {
    return { available: false };
  }
}

function readSyncLedgerSummary(dbPath) {
  const result = spawnSync('python3', ['-c', [
    'import json,sqlite3,sys',
    "db=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)",
    "tables=['op_receipts','batch_receipts','record_versions','record_heads','change_events']",
    "counts={name:db.execute('select count(*) from '+name).fetchone()[0] for name in tables}",
    "counter=db.execute('select coalesce(sum(last_committed_seq),0) from vault_counters').fetchone()[0]",
    "print(json.dumps({'counts':counts,'committedSeqTotal':counter}))",
  ].join(';'), dbPath], { encoding: 'utf8', timeout: 3000 });
  if (result.status !== 0) return { available: false };
  try {
    const summary = JSON.parse(result.stdout);
    return {
      available: true,
      counts: summary.counts,
      committedSeqTotal: summary.committedSeqTotal,
    };
  } catch (_) {
    return { available: false };
  }
}

function safeRelayServerLogSummary(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    return { available: false };
  }
  const eventCounts = {
    sessionCheckFailed: (text.match(/event="relay_session_state_check_failed"/g) || []).length,
    sessionCheckTimedOut: (text.match(/event="relay_session_state_check_timed_out"/g) || []).length,
    sessionInactiveClosed: (text.match(/event="relay_connection_closed" reason="session_inactive"/g) || []).length,
  };
  return { available: true, eventCounts };
}

async function relayFailureDiagnostic({
  page,
  error,
  phase,
  apiEvents,
  requestFailures,
  browserConsoleEvents,
  sshDiagnostics,
  xtermInputDiagnostics,
  relaySockets,
  pageErrors,
  relayTicketTargetChecks,
  sshdBeforeRelay,
  sshdLogPath,
  jumpSshdBeforeRelay,
  jumpSshdLogPath,
  dbPath,
  serverProcess,
  sshdProcess,
  jumpSshdProcess,
}) {
  let closeMetadata = [];
  try {
    closeMetadata = await page.evaluate(() =>
      (window.__relaySocketCloseMetadata || []).map((item) => ({ ...item })));
  } catch (_) {}
  const sshdAfterRelay = sshdRuntimeSummary(sshdLogPath);
  const jumpSshdAfterRelay = sshdRuntimeSummary(jumpSshdLogPath);
  return {
    phase,
    browserError: safeErrorSummary(error),
    ui: await uiSummary(page),
    api: apiEvents,
    requestFailures,
    browserConsoleEvents,
    sshDiagnostics: sshDiagnostics.slice(-100),
    xtermInputDiagnostics,
    relaySockets: relaySockets.map((socket) => ({
      path: socket.path,
      opened: socket.opened,
      closed: socket.closed,
      sentFrameCount: socket.sentFrames.length,
      sentFrames: socket.sentFrames.slice(-12),
      receivedFrameCount: socket.receivedFrames.length,
      receivedFrames: socket.receivedFrames.slice(-12),
      socketError: socket.socketError,
    })),
    browserWebSocketCloseMetadata: closeMetadata,
    pageErrors,
    relayTicketTargetMatchedFixture:
      relayTicketTargetChecks.length > 0 && relayTicketTargetChecks.every(Boolean),
    sshd: {
      beforeRelay: sshdBeforeRelay,
      afterRelay: sshdAfterRelay,
      delta: sshdDiagnosticDelta(sshdBeforeRelay, sshdAfterRelay),
    },
    jumpSshd: {
      beforeRelay: jumpSshdBeforeRelay,
      afterRelay: jumpSshdAfterRelay,
      delta: sshdDiagnosticDelta(jumpSshdBeforeRelay, jumpSshdAfterRelay),
    },
    relayDatabase: readRelayDatabaseSummary(dbPath),
    childProcesses: {
      serverRunning: serverProcess?.exitCode === null,
      serverExitCode: serverProcess?.exitCode ?? null,
      sshdRunning: sshdProcess?.exitCode === null,
      sshdExitCode: sshdProcess?.exitCode ?? null,
      jumpSshdRunning: jumpSshdProcess?.exitCode === null,
      jumpSshdExitCode: jumpSshdProcess?.exitCode ?? null,
    },
  };
}

function safeApiRoute(pathname) {
  return pathname.replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\/|$)/gi, '/{id}');
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function snippetSyncOperation(envelope) {
  const header = envelope?.header || {};
  return {
    opId: header.op_id,
    recordId: header.record_id,
    revisionId: header.revision_id,
    operation: header.operation,
    envelopeSha256: crypto.createHash('sha256')
      .update(stableJson(envelope)).digest('hex'),
  };
}

function createKeyPair(tempRoot, name) {
  const privateKey = path.join(tempRoot, name);
  run(SSH_KEYGEN, ['-q', '-t', 'ecdsa', '-b', '256', '-m', 'PEM', '-N', '', '-f', privateKey], { timeout: 30000 });
  fs.chmodSync(privateKey, 0o600);
  return { privateKey, publicKey: fs.readFileSync(`${privateKey}.pub`, 'utf8').trim() };
}

function sshKeyFingerprint(hostKeyPath) {
  const result = run(SSH_KEYGEN, ['-lf', `${hostKeyPath}.pub`, '-E', 'sha256'], {
    timeout: 10000,
  }).trim().split(/\s+/);
  if (!/^SHA256:[A-Za-z0-9+/]+={0,2}$/.test(result[1] || '')) {
    throw new Error('temporary SSHD host-key fingerprint was unavailable');
  }
  return result[1];
}

function sshKeyFingerprintMatchSummary(clientPublicKeyPath, authorizedKeysPath) {
  const fingerprint = (filePath) => {
    const result = spawnSync(SSH_KEYGEN, ['-lf', filePath], {
      encoding: 'utf8', timeout: 5000,
    });
    if (result.error || result.status !== 0) return null;
    return (result.stdout || '').match(/\bSHA256:[A-Za-z0-9+/=]+/)?.[0] || null;
  };
  const client = fingerprint(clientPublicKeyPath);
  const authorized = fingerprint(authorizedKeysPath);
  return {
    clientKeyParsed: client !== null,
    authorizedKeyParsed: authorized !== null,
    fingerprintsMatch: client !== null && authorized !== null && client === authorized,
  };
}

function inspectPrivateKey(actualPem, expectedPem) {
  const normalizeNewlines = (value) => value.replace(/\r\n?/g, '\n');
  const expectedLines = expectedPem.split(/\r?\n/);
  const expectedHeader = expectedLines[0];
  const expectedFooter = expectedLines.at(-1);
  const pemBody = (value) => value
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s/g, '');
  const diagnostics = {
    expectedLength: expectedPem.length,
    actualLength: actualPem.length,
    exactTextMatch: actualPem === expectedPem,
    normalizedTextMatch: normalizeNewlines(actualPem) === normalizeNewlines(expectedPem),
    expectedLineCount: expectedPem.split(/\r?\n/).length,
    actualLineCount: actualPem.split(/\r?\n/).length,
    expectedCrlfCount: (expectedPem.match(/\r\n/g) || []).length,
    actualCrlfCount: (actualPem.match(/\r\n/g) || []).length,
    expectedWhitespaceCount: (expectedPem.match(/\s/g) || []).length,
    actualWhitespaceCount: (actualPem.match(/\s/g) || []).length,
    expectedBodyChars: pemBody(expectedPem).length,
    actualBodyChars: pemBody(actualPem).length,
    bodyTextEqual: pemBody(actualPem) === pemBody(expectedPem),
    expectedHeaderPresent: expectedPem.startsWith(expectedHeader),
    actualHeaderPresent: actualPem.startsWith(expectedHeader),
    expectedFooterPresent: expectedPem.endsWith(expectedFooter),
    actualFooterPresent: actualPem.endsWith(expectedFooter),
    actualPrivateKeyParsed: false,
    publicKeyDerEqual: false,
  };
  try {
    const actualPublicDer = crypto.createPublicKey(crypto.createPrivateKey(actualPem))
      .export({ type: 'spki', format: 'der' });
    diagnostics.actualPrivateKeyParsed = true;
    const expectedPublicDer = crypto.createPublicKey(crypto.createPrivateKey(expectedPem))
      .export({ type: 'spki', format: 'der' });
    diagnostics.publicKeyDerEqual = actualPublicDer.equals(expectedPublicDer);
  } catch (_) {
    // Deliberately omit parser errors: they can include input fragments.
  }
  return diagnostics;
}

function writeSshdConfig({
  tempRoot,
  address,
  port,
  hostKey,
  authorizedKeys,
  user,
  jailRoot,
  instance = 'sshd',
  configName = instance,
  allowTcpForwarding = 'no',
  permitOpen = null,
}) {
  const configPath = path.join(tempRoot, `${configName}.config`);
  const pidPath = path.join(tempRoot, `${instance}.pid`);
  const lines = [
    `Port ${port}`,
    `ListenAddress ${address}`,
    `HostKey ${hostKey}`,
    `PidFile ${pidPath}`,
    'Protocol 2',
    'PubkeyAuthentication yes',
    'AuthenticationMethods publickey',
    'PasswordAuthentication no',
    'KbdInteractiveAuthentication no',
    'PermitRootLogin no',
    `ChrootDirectory ${jailRoot}`,
    `AuthorizedKeysFile ${authorizedKeys}`,
    `AllowUsers ${user}`,
    'StrictModes no',
    'UsePAM no',
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'AllowAgentForwarding no',
    `AllowTcpForwarding ${allowTcpForwarding}`,
    ...(permitOpen
      ? [`PermitOpen ${Array.isArray(permitOpen) ? permitOpen.join(' ') : permitOpen}`]
      : []),
    'X11Forwarding no',
    'PermitTunnel no',
    'PermitTTY yes',
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 3',
    // The client must pull the current Vault before it can show a first-use
    // host-key prompt (bounded to 45 seconds), so use OpenSSH's ordinary
    // login grace window instead of terminating this intentional handshake.
    'LoginGraceTime 120',
    'ClientAliveInterval 15',
    'ClientAliveCountMax 2',
    'LogLevel DEBUG3',
    'Subsystem sftp internal-sftp',
  ];
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  run(SSHD, ['-t', '-f', configPath], { timeout: 10000 });
  const effective = run(SSHD, ['-T', '-f', configPath], { timeout: 10000 });
  assertThat(effective.split('\n').includes('permitrootlogin no'),
    'temporary sshd must explicitly disable root login');
  assertThat(effective.split('\n').includes(`chrootdirectory ${jailRoot}`),
    'temporary sshd must confine the non-root login to the fixture chroot');
  assertThat(effective.split('\n').includes(`allowusers ${user}`),
    'temporary sshd must allow only the isolated non-root fixture account');
  const configuredHosts = effective.split('\n')
    .filter((line) => line.startsWith('hostkey '))
    .map((line) => line.slice('hostkey '.length));
  assertThat(configuredHosts.length === 1 && configuredHosts[0] === hostKey,
    'temporary sshd did not select only the temporary host key');
  assertThat(effective.split('\n').includes(`allowtcpforwarding ${allowTcpForwarding}`),
    'temporary sshd forwarding policy did not match the requested fixture policy');
  const listenAddresses = effective.split('\n')
    .filter((line) => line.startsWith('listenaddress '));
  assertThat(listenAddresses.length === 1 &&
    listenAddresses[0] === `listenaddress ${address}:${port}`,
  'temporary SSHD must bind only its explicitly configured fixture address');
  if (permitOpen) {
    const effectivePermitOpen = Array.isArray(permitOpen)
      ? permitOpen.join(' ')
      : permitOpen;
    assertThat(effective.split('\n').includes(`permitopen ${effectivePermitOpen}`),
      'temporary bastion did not enforce its exact permitted target endpoints');
  }
  return configPath;
}

function writeKeyboardInteractiveSshdConfig({
  tempRoot,
  address,
  port,
  hostKey,
  user,
  jailRoot,
  serviceName,
  authenticationMethods,
  passwordAuthentication,
  configName,
}) {
  const configPath = path.join(tempRoot, `${configName}.config`);
  const pidPath = path.join(tempRoot, `${configName}.pid`);
  const lines = [
    `Port ${port}`,
    `ListenAddress ${address}`,
    `HostKey ${hostKey}`,
    `PidFile ${pidPath}`,
    'Protocol 2',
    'PubkeyAuthentication no',
    `AuthenticationMethods ${authenticationMethods}`,
    `PasswordAuthentication ${passwordAuthentication}`,
    'KbdInteractiveAuthentication yes',
    'PermitRootLogin no',
    `ChrootDirectory ${jailRoot}`,
    'AuthorizedKeysFile none',
    `AllowUsers ${user}`,
    'StrictModes no',
    'UsePAM yes',
    `PAMServiceName ${serviceName}`,
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'AllowAgentForwarding no',
    'AllowTcpForwarding no',
    'X11Forwarding no',
    'PermitTunnel no',
    'PermitTTY yes',
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 3',
    'LoginGraceTime 120',
    'LogLevel DEBUG3',
  ];
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  run(SSHD, ['-t', '-f', configPath], { timeout: 10000 });
  const effective = run(SSHD, ['-T', '-f', configPath], { timeout: 10000 });
  const required = [
    'pubkeyauthentication no',
    `authenticationmethods ${authenticationMethods}`,
    `passwordauthentication ${passwordAuthentication}`,
    'kbdinteractiveauthentication yes',
    'usepam yes',
    `pamservicename ${serviceName}`,
    `allowusers ${user}`,
    `chrootdirectory ${jailRoot}`,
  ];
  assertThat(required.every((setting) => effective.split('\n').includes(setting)),
    'temporary keyboard-interactive SSHD effective settings did not match the fixture policy');
  assertThat(effective.split('\n').includes(`listenaddress ${address}:${port}`),
    'keyboard-interactive SSHD did not bind only its fixture address and port');
  return configPath;
}

function startSshd(configPath, tempRoot, label = 'sshd') {
  const log = fs.openSync(path.join(tempRoot, `${label}.log`), 'a', 0o600);
  const closeLog = () => { try { fs.closeSync(log); } catch (_) {} };
  let child;
  try {
    child = spawn(SSHD, ['-D', '-e', '-f', configPath], {
      cwd: tempRoot,
      env: process.env,
      stdio: ['ignore', log, log],
      detached: true,
    });
  } catch (error) {
    closeLog();
    throw error;
  }
  child.once('error', closeLog);
  child.once('close', closeLog);
  return child;
}

async function collectWebStartupState(page) {
  return page.evaluate(async () => {
    const settle = async (value, timeoutMs = 1200) => Promise.race([
      Promise.resolve(value).catch(() => null),
      new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs)),
    ]);
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== 'none' && style.visibility !== 'hidden';
    };
    const bodyText = document.body.innerText || '';
    const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
      .filter(visible)
      .map((element) => (element.getAttribute('aria-label') ||
        element.innerText || '').trim())
      .filter(Boolean);
    const loader = globalThis._flutter?.loader;
    let databaseState = null;
    if (typeof indexedDB.databases === 'function') {
      const databases = await settle(indexedDB.databases());
      databaseState = Array.isArray(databases)
        ? databases.map(({ name, version }) => ({ name: name || '', version: version ?? null }))
        : null;
    }
    let lockState = null;
    if (typeof navigator.locks?.query === 'function') {
      const locks = await settle(navigator.locks.query());
      lockState = locks ? {
        held: (locks.held || []).map((lock) => lock.name || ''),
        pending: (locks.pending || []).map((lock) => lock.name || ''),
      } : null;
    }
    let storageEstimate = null;
    if (typeof navigator.storage?.estimate === 'function') {
      const estimate = await settle(navigator.storage.estimate());
      storageEstimate = estimate ? {
        usage: Number.isFinite(estimate.usage) ? estimate.usage : null,
        quota: Number.isFinite(estimate.quota) ? estimate.quota : null,
      } : null;
    }
    const storageKeys = (storage) => {
      try { return Array.from({ length: storage.length }, (_, i) => storage.key(i) || '').sort(); }
      catch (_) { return null; }
    };
    return {
      path: location.pathname,
      title: document.title,
      readyState: document.readyState,
      bodyText: bodyText.slice(0, 1200),
      navigationType: performance.getEntriesByType('navigation')[0]?.type ?? null,
      currentBuildId: globalThis.atermiusWebBuildId ?? null,
      flutterProbe: globalThis.__relayProbe ?? null,
      flutterLoader: {
        present: Boolean(loader),
        scriptLoaded: typeof loader?._scriptLoaded === 'boolean'
          ? loader._scriptLoaded : null,
        buildConfigPresent: Boolean(globalThis._flutter?.buildConfig),
      },
      canvasCount: document.querySelectorAll('canvas').length,
      flutterViewCount: document.querySelectorAll('flutter-view, flt-glass-pane').length,
      semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
      settingsVisible: bodyText.includes('Settings'),
      terminalConnectedVisible: bodyText.includes('CONNECTED'),
      updateNoticeVisible: bodyText.includes('A new version is available'),
      activeTerminalBlockVisible: bodyText.includes('active terminal') ||
        bodyText.includes('Close the active terminal'),
      visibleButtons: buttons.slice(-20),
      visibleDialogCount: [...document.querySelectorAll(
        'flt-semantics[role="dialog"], [role="dialog"], [role="alertdialog"]')]
        .filter(visible).length,
      scriptPaths: [...document.scripts].map((script) => {
        try { return new URL(script.src).pathname; } catch (_) { return ''; }
      }).filter(Boolean),
      sharedWorkerSupported: typeof SharedWorker === 'function',
      workerResourcePaths: performance.getEntriesByType('resource')
        .map((entry) => {
          try { return new URL(entry.name).pathname; } catch (_) { return ''; }
        })
        .filter((pathname) => /worker/i.test(pathname)).slice(-20),
      indexedDb: databaseState,
      webLocks: lockState,
      storageEstimate,
      localStorageKeys: storageKeys(localStorage),
      sessionStorageKeys: storageKeys(sessionStorage),
    };
  });
}

async function runWebUpdateLifecycleAcceptance({
  page,
  tempRoot,
  hostName,
  createPendingMutation,
  relaySockets,
  pageErrors,
  redact,
  webLoadEvents,
  setStage,
}) {
  setStage('Web update discovery preserves the active SSH terminal');
  const currentBuildId = await page.evaluate(() =>
    globalThis.atermiusWebBuildId ?? null,
  );
  assertThat(typeof currentBuildId === 'string' && currentBuildId.length > 0,
    'Web bootstrap did not publish a bundle identifier');
  let bootstrapProbePatched = false;
  await page.route(/flutter_bootstrap\.js\?atermius_update_probe=/, async (route) => {
    const response = await route.fetch();
    const body = await response.text();
    const patched = body.replace(
      /globalThis\.atermiusWebBuildId\s*=\s*["']([A-Za-z0-9_-]{1,64})["']/,
      'globalThis.atermiusWebBuildId = "atermius-test-new-build"',
    );
    assertThat(patched !== body,
      'Web update probe response did not contain the build identifier');
    bootstrapProbePatched = true;
    await route.fulfill({ response, body: patched });
  });
  const beforeProbe = await page.evaluate(() => ({
    timeOrigin: performance.timeOrigin,
    navigationType: performance.getEntriesByType('navigation')[0]?.type ?? null,
  }));
  setStage('Web update opens Settings for a manual bundle check');
  await click(page, 'Settings');
  setStage('Web update requests the synthetic newer bundle');
  await page.getByRole('button', { name: 'Check for updates', exact: true }).click();
  const reviewUpdate = page.getByRole('button', {
    name: 'Review update', exact: true,
  });
  setStage('Web update notice appears without closing the active terminal');
  await reviewUpdate.waitFor({ state: 'visible', timeout: 15000 });
  assertThat(bootstrapProbePatched,
    'manual update check did not probe the self-hosted bootstrap bundle');
  assertThat(await reviewUpdate.isDisabled(),
    'update review stayed enabled with an active SSH terminal');
  const activeRelayBeforeClose = relaySockets().some((socket) =>
    socket.opened && !socket.closed,
  );
  const blockedPageState = await page.evaluate(async () => {
    const serviceWorker = navigator.serviceWorker;
    return {
      timeOrigin: performance.timeOrigin,
      navigationType: performance.getEntriesByType('navigation')[0]?.type ?? null,
      serviceWorkerSupported: Boolean(serviceWorker),
      serviceWorkerRegistrations: serviceWorker
        ? (await serviceWorker.getRegistrations()).length : null,
      serviceWorkerControllingPage: Boolean(serviceWorker?.controller),
      flutterOfflineCache: 'caches' in window
        ? await caches.has('flutter-app-cache') : false,
    };
  });
  assertThat(activeRelayBeforeClose &&
    blockedPageState.timeOrigin === beforeProbe.timeOrigin &&
    blockedPageState.navigationType === beforeProbe.navigationType,
  'checking for an update navigated the page or closed its SSH Relay');
  assertThat(!blockedPageState.serviceWorkerControllingPage &&
    (blockedPageState.serviceWorkerRegistrations === null ||
      blockedPageState.serviceWorkerRegistrations === 0) &&
    !blockedPageState.flutterOfflineCache,
  'the Web build registered a Flutter worker or retained its offline cache');

  setStage('Web update opens the Terminal page to close the active session');
  await click(page, 'Terminal');
  setStage('Web update locates the active terminal close control');
  const closeTerminal = page.getByRole('button', {
    name: `Close ${hostName}`, exact: true,
  });
  await closeTerminal.waitFor({ state: 'visible', timeout: 10000 });
  setStage('Web update closes the terminal after user action');
  await closeTerminal.click();
  setStage('Web update waits for the user-closed SSH Relay socket');
  const relayCloseDeadline = Date.now() + 10000;
  while (Date.now() < relayCloseDeadline &&
      relaySockets().some((socket) => socket.opened && !socket.closed)) {
    await page.waitForTimeout(100);
  }
  assertThat(!relaySockets().some((socket) => socket.opened && !socket.closed),
    'manually closing the SSH terminal did not close its Relay socket');

  setStage('Web update becomes ready after the active terminal closes');
  const reviewEnableAfterCloseDeadline = Date.now() + 10000;
  while (Date.now() < reviewEnableAfterCloseDeadline &&
      !await reviewUpdate.isEnabled().catch(() => false)) {
    await page.waitForTimeout(100);
  }
  assertThat(await reviewUpdate.isEnabled(),
    'update review did not become ready after the active SSH terminal closed');

  setStage('Web update blocks pending encrypted outbox pushes');
  const pendingPushRoute = /\/api\/v1\/vaults\/[^/]+\/sync\/push(?:\?.*)?$/;
  let heldPendingPushRequests = 0;
  let pendingPushAttempts = 0;
  await page.route(pendingPushRoute, async (route) => {
    if (route.request().method() !== 'POST') {
      await route.continue();
      return;
    }
    pendingPushAttempts += 1;
    try {
      await route.abort();
    } finally {
      heldPendingPushRequests += 1;
    }
  });
  const pendingMutationName = `Web update pending ${Date.now()}`;
  await createPendingMutation(pendingMutationName);
  await click(page, 'Sync pending changes');
  const heldPushDeadline = Date.now() + 15000;
  const readPendingCount = async () => {
    const visibleText = await page.locator('body').innerText();
    const matches = [...visibleText.matchAll(/Pending sync\s+(\d+)/gi)];
    assertThat(matches.length === 1,
      `pending outbox indicator exposed ${matches.length} visible counts`);
    return Number(matches[0][1]);
  };
  let pendingBeforeArchive = null;
  let previousPendingCount = null;
  let stablePendingCountSamples = 0;
  while (Date.now() < heldPushDeadline &&
      (heldPendingPushRequests === 0 || stablePendingCountSamples < 2)) {
    if (heldPendingPushRequests > 0) {
      const pendingCount = await readPendingCount();
      if (pendingCount === previousPendingCount) {
        stablePendingCountSamples += 1;
      } else {
        stablePendingCountSamples = 1;
        previousPendingCount = pendingCount;
      }
      pendingBeforeArchive = pendingCount;
    }
    await page.waitForTimeout(100);
  }
  assertThat(pendingBeforeArchive !== null && pendingBeforeArchive > 0 &&
    heldPendingPushRequests > 0 && pendingPushAttempts > 0 &&
    stablePendingCountSamples >= 2,
    'update-gate fixture did not retain an unsent local mutation');
  await click(page, 'Settings');
  await page.getByRole('button', { name: 'Export archive', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
  setStage('Web update remains blocked until an archive covers pending outbox');
  await reviewUpdate.waitFor({ state: 'visible', timeout: 10000 });
  assertThat(await reviewUpdate.isDisabled(),
    'pending encrypted outbox did not disable update review');
  const pendingBlockerDeadline = Date.now() + 10000;
  let pendingBlockerBodyText = '';
  let pendingBlockerSemanticLabels = [];
  const pendingBlockerText =
    'encrypted outbox operation(s) need to sync or be included in a new encrypted Vault archive.';
  while (Date.now() < pendingBlockerDeadline) {
    pendingBlockerBodyText = await page.locator('body').innerText();
    pendingBlockerSemanticLabels = await page.locator('flt-semantics[aria-label]')
      .evaluateAll((nodes) => nodes.map((node) =>
        node.getAttribute('aria-label') || '',
      ).filter((label) => /outbox|active SSH|synchronization|recovery/i.test(label)));
    if (pendingBlockerBodyText.includes(pendingBlockerText) ||
        pendingBlockerSemanticLabels.some((label) =>
          label.includes(pendingBlockerText))) break;
    await page.waitForTimeout(100);
  }
  const pendingBlockerCombinedText = [pendingBlockerBodyText,
    ...pendingBlockerSemanticLabels].join('\n');
  const pendingBlockerMatch = pendingBlockerCombinedText.match(
    /(\d+) encrypted outbox operation\(s\) need to sync or be included in a new encrypted Vault archive\./,
  );
  const visibleBlockerCategories = pendingBlockerBodyText.split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /pending|outbox|active SSH|synchronization|recovery/i.test(line))
    .map((line) => line.slice(0, 180));
  assertThat(pendingBlockerMatch !== null &&
    Number(pendingBlockerMatch[1]) === pendingBeforeArchive,
  `update review was disabled without the expected pending-outbox blocker (pending=${pendingBeforeArchive}, visible=${pendingBlockerMatch?.[1] ?? 'none'}, categories=${JSON.stringify(visibleBlockerCategories)}, semanticBlockerLabelCount=${pendingBlockerSemanticLabels.length})`);

  const syncPendingButton = page.getByRole('button', {
    name: 'Sync pending changes', exact: true,
  });
  const archiveIdleDeadline = Date.now() + 15000;
  let stableIdleSamples = 0;
  let previousPushCount = heldPendingPushRequests;
  while (Date.now() < archiveIdleDeadline && stableIdleSamples < 8) {
    if (await syncPendingButton.isEnabled().catch(() => false) &&
        heldPendingPushRequests === previousPushCount) {
      stableIdleSamples += 1;
    } else {
      stableIdleSamples = 0;
      previousPushCount = heldPendingPushRequests;
    }
    await page.waitForTimeout(250);
  }
  assertThat(stableIdleSamples >= 8 &&
    await syncPendingButton.isEnabled() &&
    heldPendingPushRequests === previousPushCount,
  'pending outbox sync did not settle before encrypted archive export');

  setStage('Web update exports a current-state encrypted Vault archive');
  const archiveDownloadPromise = page.waitForEvent('download', { timeout: 120000 });
  await click(page, 'Export archive');
  const archivePassword = 'WebUpdateArchive2026!';
  await fill(page, 'New archive password', archivePassword);
  await fill(page, 'Confirm archive password', archivePassword);
  await click(page, 'Continue');
  const archiveDownload = await archiveDownloadPromise;
  assertThat(await archiveDownload.failure() === null,
    'pending outbox archive export did not produce a downloadable file');
  const archivePath = path.join(tempRoot, 'web-update-pending-outbox.atvlt');
  await archiveDownload.saveAs(archivePath);
  const archiveBytes = fs.readFileSync(archivePath);
  const archiveMagicMatches = archiveBytes.length >= 12 &&
    archiveBytes.toString('ascii', 0, 8) === 'ATVLTAR1';
  assertThat(archiveMagicMatches,
    'pending outbox export did not use the encrypted Vault archive container');
  const archiveHeaderLength = archiveBytes.readUInt32BE(8);
  const archiveHeaderEnd = 12 + archiveHeaderLength;
  assertThat(archiveHeaderLength > 0 && archiveHeaderLength <= 64 * 1024 &&
    archiveHeaderEnd <= archiveBytes.length,
  'pending outbox archive header was outside its size boundary');
  const archiveHeader = JSON.parse(
    archiveBytes.subarray(12, archiveHeaderEnd).toString('utf8'),
  );
  const archivePayloadLength = archiveHeader.payload_length;
  const archiveChunkSize = archiveHeader.chunk_size;
  const archiveChunkCount = archiveHeader.chunk_count;
  assertThat(archiveHeader.format === 'atermius-vault-archive' &&
    archiveHeader.version === 1 &&
    archiveHeader.cipher_suite === 'xchacha20-poly1305-ietf' &&
    archiveHeader.kdf?.algorithm === 'argon2id13' &&
    archiveHeader.kdf?.memory_kib === 65536 &&
    archiveHeader.kdf?.iterations === 3 &&
    archiveChunkSize === 1024 * 1024 &&
    Number.isSafeInteger(archivePayloadLength) && archivePayloadLength > 0 &&
    Number.isSafeInteger(archiveChunkCount) &&
    archiveChunkCount === Math.ceil(archivePayloadLength / archiveChunkSize),
  'pending outbox archive did not expose the expected authenticated-encryption metadata');
  let archiveOffset = archiveHeaderEnd;
  let archivedClearLength = 0;
  let observedArchiveChunks = 0;
  let archiveChunkLayoutValid = true;
  while (observedArchiveChunks < archiveChunkCount) {
    if (archiveOffset + 28 > archiveBytes.length) {
      archiveChunkLayoutValid = false;
      break;
    }
    const chunkClearLength = archiveBytes.readUInt32BE(archiveOffset);
    const expectedChunkLength = Math.min(
      archiveChunkSize, archivePayloadLength - archivedClearLength,
    );
    if (chunkClearLength !== expectedChunkLength || chunkClearLength <= 0 ||
        archiveOffset + 4 + 24 + chunkClearLength + 16 > archiveBytes.length) {
      archiveChunkLayoutValid = false;
      break;
    }
    archiveOffset += 4 + 24 + chunkClearLength + 16;
    archivedClearLength += chunkClearLength;
    observedArchiveChunks += 1;
  }
  archiveChunkLayoutValid = archiveChunkLayoutValid &&
    observedArchiveChunks === archiveChunkCount &&
    archivedClearLength === archivePayloadLength &&
    archiveOffset === archiveBytes.length;
  assertThat(archiveChunkLayoutValid,
    'pending outbox archive encrypted chunk layout was invalid');
  assertThat(!archiveBytes.includes(Buffer.from(pendingMutationName)),
    'pending Host display name appeared in plaintext in the encrypted Vault archive');
  console.log('Web update pending archive safe evidence', JSON.stringify({
    archiveMagicMatches,
    authenticatedCipherSuite: archiveHeader.cipher_suite,
    passwordKdf: archiveHeader.kdf.algorithm,
    encryptedChunkCount: observedArchiveChunks,
    encryptedPayloadLength: archivePayloadLength,
    pendingHostMarkerAbsent: true,
  }));
  await waitText(page, 'Encrypted Vault archive saved.');
  await click(page, 'Hosts');
  await page.getByRole('button', { name: 'Add host', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
  assertThat(await readPendingCount() === pendingBeforeArchive,
    'exporting the archive unexpectedly removed or synced the local outbox');
  await click(page, 'Settings');
  await page.getByRole('button', { name: 'Export archive', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });

  setStage('Web update becomes ready after an archive covers the pending state');
  const reviewEnableDeadline = Date.now() + 10000;
  while (Date.now() < reviewEnableDeadline &&
      !await reviewUpdate.isEnabled().catch(() => false)) {
    await page.waitForTimeout(100);
  }
  assertThat(await reviewUpdate.isEnabled(),
    'update review did not enable after exporting a current-state archive');

  setStage('Web update confirmation reports the archived pending count');
  const pageUrlBeforeCancel = page.url();
  const timeOriginBeforeCancel = await page.evaluate(() => performance.timeOrigin);
  await reviewUpdate.click();
  await page.getByRole('button', {
    name: 'Update and reload', exact: true,
  }).waitFor({ state: 'visible' });
  await page.getByText(
    `An encrypted Vault archive covering ${pendingBeforeArchive} pending operation(s) was exported recently. The outbox remains stored locally and will sync after reload.`,
    { exact: true },
  ).waitFor({ state: 'visible' });

  setStage('Web update cancellation leaves archived pending outbox intact');
  await page.getByRole('button', { name: 'Cancel', exact: true }).last().click();
  await page.getByRole('button', {
    name: 'Update and reload', exact: true,
  }).waitFor({ state: 'detached' });
  await page.waitForTimeout(250);
  assertThat(page.url() === pageUrlBeforeCancel &&
    await page.evaluate(() => performance.timeOrigin) === timeOriginBeforeCancel,
  'canceling the update confirmation reloaded the page');
  await click(page, 'Hosts');
  await page.getByRole('button', { name: 'Add host', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
  assertThat(await readPendingCount() === pendingBeforeArchive &&
    heldPendingPushRequests > 0,
  'canceling the update confirmation changed or lost the pending encrypted outbox');
  const escapedPendingMutationName = pendingMutationName
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pendingMutationHostCard = page.getByRole('group', {
    name: new RegExp(escapedPendingMutationName),
  }).first();
  await pendingMutationHostCard.waitFor({ state: 'visible', timeout: 15000 });
  await click(page, 'Settings');
  await page.getByRole('button', { name: 'Export archive', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });

  await page.unroute(/flutter_bootstrap\.js\?atermius_update_probe=/);
  const bundleBBuildId = 'atermius-test-bundle-b';
  const bundleBMarker = 'atermius-test-bundle-b-loaded';
  const bundleBResponses = { bootstrap: 0, mainScript: 0 };
  const bundleBBootstrapRoute = /\/flutter_bootstrap\.js(?:\?.*)?$/;
  const bundleBMainScriptRoute = /\/main\.dart\.js(?:\?.*)?$/;
  await page.route(bundleBBootstrapRoute, async (route) => {
    const response = await route.fetch();
    const body = await response.text();
    const patched = body.replace(
      /globalThis\.atermiusWebBuildId\s*=\s*["']([A-Za-z0-9_-]{1,64})["']/,
      `globalThis.atermiusWebBuildId = "${bundleBBuildId}"`,
    );
    assertThat(patched !== body,
      'synthetic bundle B bootstrap did not contain a build identifier');
    bundleBResponses.bootstrap++;
    await route.fulfill({ response, body: patched });
  });
  await page.route(bundleBMainScriptRoute, async (route) => {
    const response = await route.fetch();
    const body = await response.text();
    assertThat(body.length > 1000,
      'synthetic bundle B main.dart.js response was unexpectedly small');
    bundleBResponses.mainScript++;
    await route.fulfill({
      response,
      body: `${body}\n;globalThis.__atermiusTestBundleMarker = ${JSON.stringify(bundleBMarker)};\n`,
    });
  });
  setStage('Web update reloads after explicit user confirmation');
  const reloadNavigation = page.waitForNavigation({
    waitUntil: 'domcontentloaded', timeout: 30000,
  });
  await reviewUpdate.click();
  await page.getByRole('button', {
    name: 'Update and reload', exact: true,
  }).click();
  await reloadNavigation;
  const postReloadSnapshot = await collectWebStartupState(page);
  console.log('Web update post-confirm reload page snapshot', JSON.stringify({
    ...postReloadSnapshot,
    bodyText: typeof redact === 'function'
      ? redact(postReloadSnapshot.bodyText) : '[redactor unavailable]',
    localStorageKeys: (postReloadSnapshot.localStorageKeys || [])
      .map((key) => typeof redact === 'function' ? redact(key) : '[redacted]'),
    sessionStorageKeys: (postReloadSnapshot.sessionStorageKeys || [])
      .map((key) => typeof redact === 'function' ? redact(key) : '[redacted]'),
    bootstrapEvents: (webLoadEvents || []).slice(-20),
  }));
  setStage('Web update waits for Flutter and accessible UI after reload');
  await enableSemantics(page);
  setStage('Web update unlocks Profile A after the confirmed reload');
  await fill(page, 'Email or username', USERNAME);
  await fill(page, 'Master password', MASTER_PASSWORD);
  await click(page, 'Sign in and unlock');
  setStage('Web update waits for the unlocked workspace after reload');
  await page.getByRole('button', { name: 'Settings', exact: true })
    .waitFor({ state: 'visible', timeout: 30000 });
  await click(page, 'Hosts');
  await page.getByRole('button', { name: 'Add host', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
  const pendingAfterReload = await readPendingCount();
  assertThat(pendingAfterReload === pendingBeforeArchive,
    'confirmed bundle reload did not preserve the local encrypted outbox count');
  await page.getByRole('group', {
    name: new RegExp(escapedPendingMutationName),
  }).first().waitFor({ state: 'visible', timeout: 15000 });
  setStage('Web update opens Settings after confirmed reload');
  await click(page, 'Settings');
  await page.getByRole('button', { name: 'Check for updates', exact: true })
    .waitFor({ state: 'visible', timeout: 10000 });
  const checkForUpdates = page.getByRole('button', {
    name: 'Check for updates', exact: true,
  });
  await checkForUpdates.waitFor({ state: 'visible', timeout: 15000 });
  const reloadedReview = page.getByRole('button', {
    name: 'Review update', exact: true,
  });
  assertThat(await reloadedReview.count() === 0,
    'confirmed reload did not clear the pending update notice for the current bundle');
  const afterConfirmedReload = await page.evaluate(async () => {
    const serviceWorker = navigator.serviceWorker;
    return {
      navigationType: performance.getEntriesByType('navigation')[0]?.type ?? null,
      buildId: globalThis.atermiusWebBuildId ?? null,
      bundleMarker: globalThis.__atermiusTestBundleMarker ?? null,
      serviceWorkerRegistrations: serviceWorker
        ? (await serviceWorker.getRegistrations()).length : null,
      serviceWorkerControllingPage: Boolean(serviceWorker?.controller),
      flutterOfflineCache: 'caches' in window
        ? await caches.has('flutter-app-cache') : false,
    };
  });
  assertThat(afterConfirmedReload.navigationType === 'reload' &&
    afterConfirmedReload.buildId === bundleBBuildId &&
    afterConfirmedReload.bundleMarker === bundleBMarker &&
    bundleBResponses.bootstrap >= 1 && bundleBResponses.mainScript >= 1,
  'explicit confirmation did not load the synthetic bundle B bootstrap and main script');
  await page.unroute(bundleBBootstrapRoute);
  await page.unroute(bundleBMainScriptRoute);
  assertThat(!afterConfirmedReload.serviceWorkerControllingPage &&
    (afterConfirmedReload.serviceWorkerRegistrations === null ||
      afterConfirmedReload.serviceWorkerRegistrations === 0) &&
    !afterConfirmedReload.flutterOfflineCache,
  'confirmed update left a Flutter service worker or offline cache');
  assertThat(pageErrors.length === 0,
    'Web update lifecycle produced browser page errors');
  console.log('WEB-APP-UPDATE-01 passed: a synthetic newer build was discovered without navigating the active SSH page; update remained disabled until the user closed the terminal; cancel kept the page open; explicit confirmation loaded route-served bundle B bootstrap and main.dart.js, verified its build ID and harmless marker, and cleared the pending notice. No Flutter worker/cache was present. Bundle B is derived from the current release assets with a test marker; this does not certify a production CDN or deployment rollout.');
}

async function runWebUpdateLifecycleWithDiagnostics(options) {
  const webLoadEvents = [];
  options.page.on('response', (response) => {
    try {
      const url = new URL(response.url());
      if (/\/(?:flutter_bootstrap\.js|main\.dart\.js|flutter\.js)$/.test(url.pathname)) {
        webLoadEvents.push({ path: url.pathname, status: response.status() });
      }
    } catch (_) {}
  });
  options.page.on('requestfailed', (request) => {
    try {
      const url = new URL(request.url());
      if (/\/(?:flutter_bootstrap\.js|main\.dart\.js|flutter\.js)$/.test(url.pathname)) {
        webLoadEvents.push({
          path: url.pathname,
          failed: true,
          errorText: request.failure()?.errorText?.slice(0, 80) || 'unknown',
        });
      }
    } catch (_) {}
  });
  options.webLoadEvents = webLoadEvents;
  try {
    await runWebUpdateLifecycleAcceptance(options);
  } catch (error) {
    const page = options.page;
    let ui = { available: false };
    try {
      ui = await collectWebStartupState(page);
    } catch (_) {}
    const redact = typeof options.redact === 'function'
      ? options.redact : (value) => String(value ?? '');
    let activeRelaySocket = null;
    try {
      activeRelaySocket = options.relaySockets().some((socket) =>
        socket.opened && !socket.closed);
    } catch (_) {}
    const safeErrorText = (value) => {
      try { return redact(String(value ?? '')).slice(0, 1200); }
      catch (_) { return '[redaction unavailable]'; }
    };
    console.log('Web update lifecycle original failure', safeErrorText(error?.name || 'Error'),
      safeErrorText(error?.message || error), safeErrorText(error?.stack || '').split('\n').slice(0, 6).join(' | '));
    try {
      console.log('Web update lifecycle post-failure UI', JSON.stringify({
        ...ui,
        bodyText: safeErrorText(ui.bodyText || ''),
        localStorageKeys: (ui.localStorageKeys || []).map(safeErrorText),
        sessionStorageKeys: (ui.sessionStorageKeys || []).map(safeErrorText),
      }));
    } catch (diagnosticError) {
      console.log('Web update lifecycle UI diagnostic failed', String(
        diagnosticError?.message || diagnosticError).slice(0, 500));
    }
    try {
      console.log('Web update lifecycle bootstrap events', JSON.stringify(webLoadEvents.slice(-20)));
    } catch (diagnosticError) {
      console.log('Web update lifecycle asset diagnostic failed', String(
        diagnosticError?.message || diagnosticError).slice(0, 500));
    }
    console.log('Web update lifecycle side-state', JSON.stringify({
      pageErrorCount: options.pageErrors?.length ?? null,
      pageErrors: options.pageErrors?.slice(-10) ?? [],
      browserConsoleEvents: options.browserConsoleEvents?.slice(-10) ?? [],
      requestFailures: options.requestFailures?.slice(-10) ?? [],
      activeRelaySocket,
    }));
    throw error;
  }
}

async function main() {
  const webUpdateOnly = process.argv.includes('--web-update-only');
  const shellCompletionOnly = process.argv.includes('--shell-completion-only');
  const keyboardInteractiveOnly = process.argv.includes('--keyboard-interactive-only');
  const collaborationOnly = webUpdateOnly || process.argv.includes('--collaboration-only') ||
    process.env.WEB_RELAY_COLLABORATION_ONLY === '1';
  const portForwardOnly = process.env.WEB_RELAY_PORT_FORWARD_ONLY === '1' ||
    process.argv.includes('--port-forward-only');
  const threeHopOnly = process.env.WEB_RELAY_THREE_HOP_ONLY === '1';
  const fourHopOnly = process.env.WEB_RELAY_FOUR_HOP_ONLY === '1';
  const maxDepthHopOnly = process.env.WEB_RELAY_MAX_DEPTH_ONLY === '1';
  const extendedHopOnly = fourHopOnly || maxDepthHopOnly;
  const deepHopOnly = threeHopOnly || extendedHopOnly;
  const focusedOneHopOnly = portForwardOnly || collaborationOnly || shellCompletionOnly ||
    keyboardInteractiveOnly;
  const testName = webUpdateOnly
    ? 'WEB-APP-UPDATE-01'
    : collaborationOnly ? 'WEB-TERMINAL-COLLABORATION-01'
    : keyboardInteractiveOnly ? 'WEB-RELAY-KBDINT-01'
    : shellCompletionOnly ? 'WEB-SHELL-COMPLETION-01'
    : portForwardOnly ? 'WEB-PORT-FORWARD-01'
    : maxDepthHopOnly ? 'WEB-RELAY-MAX-DEPTH-01'
    : fourHopOnly ? 'WEB-RELAY-FOUR-HOP-01'
    : threeHopOnly ? 'WEB-RELAY-THREE-HOP-01' : 'WEB-RELAY-01';
  const skip = preflight();
  if (skip) return environmentSkip(skip, testName);
  const pemDiagnosticOnly = process.env.WEB_RELAY_PEM_PREFLIGHT_ONLY === '1';
  const multihopOnly = process.env.WEB_RELAY_MULTIHOP_ONLY === '1' || deepHopOnly;
  const address = pemDiagnosticOnly ? null : localEth0Address();
  const targetAddress = '127.0.0.1';
  const cargo = process.env.CARGO || 'cargo';
  run(cargo, ['build', '--locked', '--manifest-path', SERVER_MANIFEST], { timeout: 240000 });
  assertThat(fs.existsSync(SERVER_BINARY), 'compiled isolated server binary is missing');

  let tempRoot;
  let sshdFixtureRoot;
  let authorizedKeysFixtureRoot;
  let authorizedKeysPath;
  let secondTargetAuthorizedKeysPath;
  let multiHopTargetAuthorizedKeysPath;
  let jumpAuthorizedKeysPath;
  let secondJumpAuthorizedKeysPath;
  let thirdJumpAuthorizedKeysPath;
  let fourthJumpAuthorizedKeysPath;
  const maxDepthBastionAuthorizedKeysPaths = [];
  let serverLog = null;
  let serverProcess;
  let sshdProcess;
  let secondTargetSshdProcess;
  let jumpSshdProcess;
  let secondJumpSshdProcess;
  let multiHopTargetSshdProcess;
  let thirdJumpSshdProcess;
  let fourthJumpSshdProcess;
  let maxDepthJumpSshdProcesses = [];
  let browser;
  let context;
  let secondContext;
  let secondPage;
  let secondPageCrashCount = 0;
  let bootstrapToken;
  let bootstrapTokenForRedaction;
  let userPrivateKey;
  let jumpPrivateKey;
  let expectedPrivateKey;
  let snippetCredentialSecret;
  let sshdBeforePortProbe;
  let sshdAfterPortProbe;
  let sshdAfterBannerProbe;
  let sshdBeforeRelay;
  let jumpSshdBeforeRelay;
  let secondTargetSshdBeforeRelay;
  let sshBannerPreflightPassed = false;
  let keyboardInteractivePamFixture = null;
  let keyboardInteractiveCode = null;
  let keyboardInteractiveOtp = null;
  let keyboardInteractiveShellMarker = null;
  let keyboardInteractiveUnusedPassword = null;
  let keyboardInteractiveHostKey = null;
  let keyboardInteractiveCancelHostKey = null;
  const apiEvents = [];
  const apiRequests = [];
  const secondApiEvents = [];
  const secondApiRequests = [];
  const secondRequestFailures = [];
  const apiResponseDiagnostics = [];
  const requestFailureDiagnostics = [];
  const browserConsoleCaptureTimes = new Map();
  const apiRequestByRequest = new WeakMap();
  const requestStartByRequest = new WeakMap();
  const snippetRelaySync = {
    active: false,
    titleMarker: null,
    secretMarker: null,
    expected: null,
    pushes: [],
    pushStatuses: [],
    pullResponses: [],
  };
  const secretSyncPrivacy = {
    active: false,
    marker: null,
    additionalMarkers: [],
    checks: [],
  };
  const secretSyncPrivacyMarkers = () => [
    secretSyncPrivacy.marker,
    ...secretSyncPrivacy.additionalMarkers,
  ].filter((marker) => typeof marker === 'string' && marker.length > 0)
    .flatMap((marker) => [marker, JSON.stringify(marker).slice(1, -1)])
    .filter((marker, index, all) => all.indexOf(marker) === index);
  const secretSyncPrivacyBodyIsSafe = (body) => body !== null &&
    secretSyncPrivacyMarkers().every((marker) => !body.includes(marker));
  const portForwardSyncPrivacy = {
    active: false,
    marker: null,
    checks: [],
  };
  let portForwardAExecutionBaseline = null;
  let portForwardAUiEvidence = null;
  const terminalCollaborationPrivacy = {
    active: false,
    markers: [],
    checks: [],
    protocolVersions: [],
  };
  const requestFailures = [];
  const browserConsoleEvents = [];
  let browserDiagnosticSequence = 0;
  const sshDiagnostics = [];
  const xtermInputDiagnostics = [];
  const sftpDiagnostics = [];
  const relaySockets = [];
  const relaySocketsByPage = new Map();
  const terminalCollaborationSockets = [];
  const terminalCollaborationSocketsByPage = new Map();
  const terminalCollaborationContextsByPage = new Map();
  const terminalCollaborationActiveSessionByPage = new Map();
  const terminalCollaborationGrantByPage = new Map();
  const safeCollaborationFrameSummary = (frame) => ({
    type: frame.messageType,
    frameKind: frame.frameKind,
    ...(frame.authentication == null
      ? {} : { authentication: frame.authentication }),
  });
  const bearerTokensByPage = new Map();
  const pageErrors = [];
  const relayTicketTargetChecks = [];
  const relayTicketTargetChecksByPage = new Map();
  const recordRelayTicketTargetCheck = (sourcePage, targetsBastionA) => {
    relayTicketTargetChecks.push(targetsBastionA);
    const pageChecks = relayTicketTargetChecksByPage.get(sourcePage) ?? [];
    pageChecks.push(targetsBastionA);
    relayTicketTargetChecksByPage.set(sourcePage, pageChecks);
  };
  const relayTicketChecksForPage = (sourcePage) => {
    let pageChecks = relayTicketTargetChecksByPage.get(sourcePage);
    if (!pageChecks) {
      pageChecks = [];
      relayTicketTargetChecksByPage.set(sourcePage, pageChecks);
    }
    return pageChecks;
  };
  const relaySocketsForPage = (sourcePage) => {
    let pageSockets = relaySocketsByPage.get(sourcePage);
    if (!pageSockets) {
      pageSockets = [];
      relaySocketsByPage.set(sourcePage, pageSockets);
    }
    return pageSockets;
  };
  const terminalCollaborationSocketsForPage = (sourcePage) => {
    let pageSockets = terminalCollaborationSocketsByPage.get(sourcePage);
    if (!pageSockets) {
      pageSockets = [];
      terminalCollaborationSocketsByPage.set(sourcePage, pageSockets);
    }
    return pageSockets;
  };
  const payloadHasSensitivePlaintext = (payload) => {
    const bytes = Buffer.isBuffer(payload)
      ? payload
      : Buffer.from(payload instanceof ArrayBuffer
        ? new Uint8Array(payload)
        : String(payload ?? ''), 'utf8');
    try {
      for (const marker of terminalCollaborationPrivacy.markers) {
        if (!marker) continue;
        const probe = Buffer.from(marker, 'utf8');
        let found;
        try { found = bytes.includes(probe); } finally { probe.fill(0); }
        if (found) return true;
      }
      return false;
    } finally {
      if (!Buffer.isBuffer(payload)) bytes.fill(0);
    }
  };
  const recordTerminalCollaborationHttp = (direction, actor, request, body) => {
    if (!terminalCollaborationPrivacy.active) return;
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    if (!pathname.includes('/terminal-sessions')) return;
    const serialized = String(body ?? '');
    terminalCollaborationPrivacy.checks.push({
      direction,
      actor,
      method: request.method(),
      route: safeApiRoute(pathname),
      plaintextAbsent: !payloadHasSensitivePlaintext(serialized),
    });
  };
  const captureTerminalCollaborationRequestContext = (sourcePage, request) => {
    const authorization = request.headers()['authorization'];
    if (typeof authorization === 'string' && /^Bearer\s+\S+$/.test(authorization)) {
      bearerTokensByPage.set(sourcePage, authorization);
    }
    let pathname;
    try { pathname = new URL(request.url()).pathname; } catch (_) { return; }
    const match = pathname.match(/^\/api\/v1\/vaults\/([0-9a-f-]{36})\/terminal-sessions$/i);
    if (!match || request.method() !== 'POST') return;
    try {
      const body = JSON.parse(request.postData() || '{}');
      if (typeof body.session_id !== 'string') return;
      terminalCollaborationContextsByPage.set(sourcePage, {
        vaultId: match[1],
        sessionId: body.session_id,
      });
      terminalCollaborationActiveSessionByPage.set(sourcePage, body.session_id);
      if ([1, 2].includes(body.protocol_version)) {
        terminalCollaborationPrivacy.protocolVersions.push(body.protocol_version);
      }
    } catch (_) {}
  };
  const trackTerminalCollaborationSocket = (sourcePage, websocket) => {
    const pageSockets = terminalCollaborationSocketsForPage(sourcePage);
    const event = {
      path: '/collaboration/v1/connect',
      page: sourcePage,
      socketIndex: pageSockets.length + 1,
      opened: true,
      closed: false,
      sentFrames: [],
      receivedFrames: [],
      socketError: false,
      plaintextPresent: false,
      websocketRef: websocket,
    };
    terminalCollaborationSockets.push(event);
    pageSockets.push(event);
    const summarizeFrame = (payload) => {
      event.plaintextPresent ||= payloadHasSensitivePlaintext(payload);
      let messageType = 'other';
      let frameKind = null;
      let safeAuthentication = null;
      if (typeof payload === 'string') {
        try {
          const decoded = JSON.parse(payload);
          if (['authenticate', 'authenticated', 'frame', 'input',
            'controller_lease_granted', 'controller_lease_ended']
            .includes(decoded?.type)) {
            messageType = decoded.type;
          }
          if (decoded?.type === 'authenticated') {
            const activeSession =
              terminalCollaborationActiveSessionByPage.get(sourcePage);
            const priorGrant = terminalCollaborationGrantByPage.get(sourcePage);
            safeAuthentication = {
              fieldNames: Object.keys(decoded).sort(),
              roleIsController: decoded.role === 'controller',
              sessionMatchesActiveSession: typeof activeSession === 'string' &&
                decoded.session_id === activeSession,
              leaseEpochMatchesPreviouslyGranted: priorGrant != null &&
                decoded.lease_id === priorGrant.leaseId &&
                decoded.control_epoch === priorGrant.controlEpoch,
            };
          } else if (decoded?.type === 'controller_lease_granted' &&
              typeof decoded.lease_id === 'string' &&
              Number.isSafeInteger(decoded.control_epoch)) {
            terminalCollaborationGrantByPage.set(sourcePage, {
              leaseId: decoded.lease_id,
              controlEpoch: decoded.control_epoch,
            });
          } else if (decoded?.type === 'controller_lease_ended' &&
              terminalCollaborationGrantByPage.get(sourcePage)?.leaseId ===
                decoded.lease_id) {
            terminalCollaborationGrantByPage.delete(sourcePage);
          }
          if (decoded?.type === 'frame' &&
              ['output', 'resize'].includes(decoded?.frame?.kind)) {
            frameKind = decoded.frame.kind;
          } else if (decoded?.type === 'input' &&
              decoded?.frame?.kind === 'input') {
            frameKind = 'input';
          }
        } catch (_) {
          // Keep malformed or binary payload details out of the test log.
        }
      }
      return {
        kind: typeof payload === 'string' ? 'text' : 'binary',
        messageType,
        frameKind,
        ...(safeAuthentication == null
          ? {} : { authentication: safeAuthentication }),
        bytes: typeof payload === 'string'
          ? Buffer.byteLength(payload) : payload.length,
      };
    };
    websocket.on('framesent', ({ payload }) =>
      event.sentFrames.push(summarizeFrame(payload)));
    websocket.on('framereceived', ({ payload }) =>
      event.receivedFrames.push(summarizeFrame(payload)));
    websocket.on('socketerror', () => { event.socketError = true; });
    websocket.on('close', () => { event.closed = true; });
    return event;
  };
  const snapshotRelayPage = (sourcePage) => {
    const sockets = relaySocketsForPage(sourcePage);
    return {
      page: sourcePage,
      ticketCount: relayTicketChecksForPage(sourcePage).length,
      socketCount: sockets.length,
      openSockets: sockets.filter((socket) => socket.opened && !socket.closed),
    };
  };
  const assertRelayPageUnchanged = (snapshot, operation) => {
    const tickets = relayTicketChecksForPage(snapshot.page);
    const sockets = relaySocketsForPage(snapshot.page);
    assertThat(tickets.length === snapshot.ticketCount,
      `${operation} created an unexpected Relay ticket on the other profile`);
    assertThat(sockets.length === snapshot.socketCount &&
      snapshot.openSockets.every((socket) => sockets.includes(socket) &&
        socket.opened && !socket.closed) &&
      sockets.filter((socket) => socket.opened && !socket.closed).length ===
        snapshot.openSockets.length,
    `${operation} changed the other profile's Relay WebSocket set`);
  };
  const handleTermination = (signal) => {
    if (activeTerminationSignal) return;
    activeTerminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    // Detached children are not signalled with the parent. The main finally
    // block performs bounded escalation and removes the private fixture.
    for (const child of [
      sshdProcess,
      secondTargetSshdProcess,
      jumpSshdProcess,
      secondJumpSshdProcess,
      multiHopTargetSshdProcess,
      thirdJumpSshdProcess,
      fourthJumpSshdProcess,
      ...maxDepthJumpSshdProcesses,
      serverProcess,
    ]) {
      if (!child || !Number.isInteger(child.pid)) continue;
      try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
    }
    if (context) void context.close().catch(() => {});
    if (secondContext) void secondContext.close().catch(() => {});
    if (browser) void browser.close().catch(() => {});
  };
  process.once('SIGINT', handleTermination);
  process.once('SIGTERM', handleTermination);
  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-relay-web-'));
    fs.chmodSync(tempRoot, 0o700);
    if (!pemDiagnosticOnly && needsEphemeralSshAccount) {
      safeRunStage = 'temporary non-root SSH account provisioning';
      sshLoginAccount = createEphemeralSshLoginAccount(tempRoot);
    }
    if (!pemDiagnosticOnly) {
      // OpenSSH rejects a chroot nested beneath world-writable /tmp. `/run`
      // is also mounted noexec in common containers, so keep the jail on the
      // root-owned executable filesystem under `/root`.
      sshdFixtureRoot = fs.mkdtempSync(path.join('/root', 'atermius-relay-jail-'));
      fs.chmodSync(sshdFixtureRoot, 0o700);
      // The sshd pre-auth monitor is unprivileged and cannot traverse the
      // private mode-0700 tempRoot. Stage only this synthetic public key in a
      // separate root-owned, read-only-to-others fixture directory.
      authorizedKeysFixtureRoot = fs.mkdtempSync(path.join('/run/sshd', 'atermius-relay-keys-'));
      fs.chmodSync(authorizedKeysFixtureRoot, 0o755);
      authorizedKeysPath = path.join(authorizedKeysFixtureRoot, 'authorized_keys');
      secondTargetAuthorizedKeysPath = path.join(
        authorizedKeysFixtureRoot,
        'second_target_authorized_keys',
      );
      multiHopTargetAuthorizedKeysPath = path.join(
        authorizedKeysFixtureRoot,
        'multihop_target_authorized_keys',
      );
      jumpAuthorizedKeysPath = path.join(authorizedKeysFixtureRoot, 'jump_authorized_keys');
      secondJumpAuthorizedKeysPath = path.join(
        authorizedKeysFixtureRoot,
        'second_jump_authorized_keys',
      );
      thirdJumpAuthorizedKeysPath = path.join(
        authorizedKeysFixtureRoot,
        'third_jump_authorized_keys',
      );
      fourthJumpAuthorizedKeysPath = path.join(
        authorizedKeysFixtureRoot,
        'fourth_jump_authorized_keys',
      );
      for (let index = 0; index < 4; index++) {
        maxDepthBastionAuthorizedKeysPaths.push(path.join(
          authorizedKeysFixtureRoot,
          `max_depth_bastion_${index + 1}_authorized_keys`,
        ));
      }
    }
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const serverLogPath = path.join(tempRoot, 'server.log');
    serverLog = fs.openSync(serverLogPath, 'a', 0o600);
    const serverPort = await unusedPort('127.0.0.1');
    const sshPort = pemDiagnosticOnly ? null : await unusedPort(targetAddress);
    let sshPort2 = pemDiagnosticOnly ? null : await unusedPort(targetAddress);
    while (!pemDiagnosticOnly && sshPort2 === sshPort) {
      sshPort2 = await unusedPort(targetAddress);
    }
    assertThat(pemDiagnosticOnly || sshPort2 !== sshPort,
      'batch target SSHD endpoints must use distinct loopback ports');
    let multiHopTargetPort = pemDiagnosticOnly ? null : await unusedPort(targetAddress);
    while (!pemDiagnosticOnly && [sshPort, sshPort2].includes(multiHopTargetPort)) {
      multiHopTargetPort = await unusedPort(targetAddress);
    }
    const bastionPort = pemDiagnosticOnly ? null : await unusedPort(address);
    let secondBastionPort = pemDiagnosticOnly ? null : await unusedPort(address);
    while (!pemDiagnosticOnly && secondBastionPort === bastionPort) {
      secondBastionPort = await unusedPort(address);
    }
    let thirdBastionPort = pemDiagnosticOnly ? null : await unusedPort(address);
    while (!pemDiagnosticOnly && [bastionPort, secondBastionPort].includes(thirdBastionPort)) {
      thirdBastionPort = await unusedPort(address);
    }
    let fourthBastionPort = pemDiagnosticOnly ? null : await unusedPort(address);
    while (!pemDiagnosticOnly && [bastionPort, secondBastionPort, thirdBastionPort]
      .includes(fourthBastionPort)) {
      fourthBastionPort = await unusedPort(address);
    }
    const maxDepthBastionPorts = [];
    if (maxDepthHopOnly) {
      const usedBastionPorts = new Set([
        bastionPort, secondBastionPort, thirdBastionPort, fourthBastionPort,
      ]);
      for (let index = 0; index < 4; index++) {
        let port = await unusedPort(address);
        while (usedBastionPorts.has(port)) port = await unusedPort(address);
        maxDepthBastionPorts.push(port);
        usedBastionPorts.add(port);
      }
    }
    const allowedRelayPorts = keyboardInteractiveOnly
      ? [bastionPort, secondBastionPort]
      : [bastionPort];
    const baseUrl = `http://127.0.0.1:${serverPort}`;
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${serverPort}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${path.join(dataDir, 'atermius.db')}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: pemDiagnosticOnly ? 'false' : 'true',
      ATERMIUS_RELAY_ALLOW_CIDRS: pemDiagnosticOnly ? '' : `${address}/32`,
      ATERMIUS_RELAY_ALLOW_PORTS: pemDiagnosticOnly ? '' : allowedRelayPorts.join(','),
      ATERMIUS_TERMINAL_COLLABORATION_ENABLED: collaborationOnly ? 'true' :
        (process.env.ATERMIUS_TERMINAL_COLLABORATION_ENABLED || 'false'),
      RUST_LOG: process.env.RUST_LOG || 'warn',
    };
    let user = pemDiagnosticOnly ? '' : sshLoginAccount.name;
    let jailRoot;
    let remoteRoot;
    let secondRemoteRoot;
    let multiHopRemoteRoot;
    let thirdJumpRemoteRoot;
    let fourthJumpRemoteRoot;
    const maxDepthJumpRemoteRoots = [];
    const redactCurrentSecrets = (text) => redact(
      text,
      bootstrapToken,
      bootstrapTokenForRedaction,
      expectedPrivateKey,
      userPrivateKey,
      jumpPrivateKey,
      secondJumpPrivateKey,
      multiHopTargetPrivateKey,
      thirdJumpPrivateKey,
      fourthJumpPrivateKey,
      ...maxDepthJumpPrivateKeys,
      snippetCredentialSecret,
      keyboardInteractiveCode,
      keyboardInteractiveOtp,
      keyboardInteractiveShellMarker,
      keyboardInteractiveUnusedPassword,
      ...secretSyncPrivacy.additionalMarkers,
      user,
      address,
    );
    let userKey;
    let secondTargetUserKey;
    let jumpUserKey;
    let secondJumpUserKey;
    let multiHopTargetUserKey;
    let thirdJumpUserKey;
    let fourthJumpUserKey;
    const maxDepthJumpUserKeys = [];
    const maxDepthJumpHostKeys = [];
    const maxDepthJumpConfigPaths = [];
    const maxDepthJumpAuthorizedKeyLines = [];
    const maxDepthBastionNames = ['E', 'F', 'G', 'H'];
    let configPath;
    let secondTargetConfigPath;
    let initialHostKey;
    let secondTargetHostKey;
    let jumpHostKey;
    let secondJumpHostKey;
    let multiHopTargetHostKey;
    let thirdJumpHostKey;
    let fourthJumpHostKey;
    let jumpConfigPath;
    let secondJumpConfigPath;
    let multiHopTargetConfigPath;
    let thirdJumpConfigPath;
    let fourthJumpConfigPath;
    if (!pemDiagnosticOnly) {
      const jail = createSshdJail(sshdFixtureRoot, sshLoginAccount);
      jailRoot = jail.jailRoot;
      remoteRoot = jail.remoteRoot;
      userKey = createKeyPair(tempRoot, 'client_ecdsa');
      fs.writeFileSync(authorizedKeysPath, `${userKey.publicKey}\n`, { mode: 0o644 });
      fs.chmodSync(authorizedKeysPath, 0o644);
      initialHostKey = path.join(tempRoot, 'sshd_host_ed25519');
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', initialHostKey], { timeout: 30000 });
      fs.chmodSync(initialHostKey, 0o600);
      configPath = writeSshdConfig({
        tempRoot, address: targetAddress, port: sshPort, hostKey: initialHostKey,
        authorizedKeys: authorizedKeysPath, user, jailRoot,
      });
    }

    const bootstrap = spawnSync(SERVER_BINARY, ['bootstrap'], {
      cwd: ROOT, env: serverEnv, encoding: 'utf8', timeout: 30000,
    });
    assertThat(bootstrap.status === 0, `isolated server bootstrap failed (${bootstrap.status})`);
    bootstrapToken = (bootstrap.stdout || '').trim().split(/\s+/).at(-1);
    bootstrapTokenForRedaction = bootstrapToken;
    assertThat(bootstrapToken && bootstrapToken.length >= 40, 'isolated server did not issue setup token');

    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT, env: serverEnv, stdio: ['ignore', serverLog, serverLog], detached: true,
    });
    await waitReady(baseUrl, serverProcess);
    safeRunStage = 'server ready';

    if (collaborationOnly) {
      const instanceProbeResponse = await fetch(`${baseUrl}/api/v1/instance`);
      const instanceProbe = await instanceProbeResponse.json();
      const capabilities = Array.isArray(instanceProbe.capabilities)
        ? instanceProbe.capabilities.filter((value) => typeof value === 'string')
        : [];
      console.log('collaboration instance capability safe evidence', JSON.stringify({
        status: instanceProbeResponse.status,
        terminalCollaboration: capabilities.includes('terminal_collaboration'),
        publicOriginCapabilityPresent: capabilities.includes('notifications'),
        capabilityCount: capabilities.length,
        setupRequired: instanceProbe.setup_required === true,
      }));
      assertThat(instanceProbeResponse.ok &&
        capabilities.includes('terminal_collaboration'),
      'isolated collaboration server did not advertise terminal_collaboration');
    }

    if (!pemDiagnosticOnly) {
      safeRunStage = 'temporary SSHD launch';
      sshdProcess = startSshd(configPath, tempRoot);
      sshdBeforePortProbe = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      safeRunStage = 'temporary SSHD port readiness';
      await waitForPort(targetAddress, sshPort, sshdProcess);
      sshdAfterPortProbe = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      safeRunStage = 'temporary SSHD banner preflight';
      sshBannerPreflightPassed = await readTemporarySshBanner(targetAddress, sshPort);
      assertThat(sshBannerPreflightPassed,
        'loopback-only target SSHD did not emit an SSH-2.0 banner during preflight');
      sshdAfterBannerProbe = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      console.log('stage: loopback target SSHD banner preflight passed',
        JSON.stringify({ bannerStartsWithSsh20: sshBannerPreflightPassed }));
      safeRunStage = 'non-root chroot SSH login preflight';
      try {
        verifyNonRootSshLogin({
          address: targetAddress,
          port: sshPort,
          keyPath: path.join(tempRoot, 'client_ecdsa'),
          account: sshLoginAccount,
        });
      } catch (error) {
        if (sshLoginAccount.ephemeral || process.env.WEB_RELAY_SSH_USER) {
          console.log('stage: non-root SSH login preflight failed; sanitized diagnosis',
            JSON.stringify({
              ...error?.safePreflightDiagnostic,
              sshKeyFingerprints: sshKeyFingerprintMatchSummary(
                path.join(tempRoot, 'client_ecdsa.pub'), authorizedKeysPath),
              authorizedKeysReadableByPreauth: (() => {
                const parent = fs.statSync(path.dirname(authorizedKeysPath));
                const file = fs.statSync(authorizedKeysPath);
                return parent.uid === 0 && (parent.mode & 0o005) === 0o005 &&
                  file.uid === 0 && (file.mode & 0o004) !== 0;
              })(),
              directChrootCommand: safeChrootCommandSummary(jailRoot, sshLoginAccount),
              sshd: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
              chrootRuntime: {
                rootOwned: fs.statSync(jailRoot).uid === 0,
                rootModeSafe: (fs.statSync(jailRoot).mode & 0o022) === 0,
                shellPresent: fs.existsSync(path.join(jailRoot, sshLoginAccount.shell.slice(1))),
                idPresent: fs.existsSync(path.join(jailRoot, 'usr/bin/id')) ||
                  fs.existsSync(path.join(jailRoot, 'bin/id')),
                passwdEntryPresent: fs.existsSync(path.join(jailRoot, 'etc/passwd')),
              },
            }));
          throw new Error(
            'isolated SSH public-key login failed for the configured non-root fixture identity',
          );
        }
        console.log('stage: existing non-root account rejected SSH key; switching to a disposable fixture account');
        await stopGroup(sshdProcess);
        sshdProcess = null;
        sshLoginAccount = createEphemeralSshLoginAccount(tempRoot);
        user = sshLoginAccount.name;
        const jail = createSshdJail(sshdFixtureRoot, sshLoginAccount);
        jailRoot = jail.jailRoot;
        remoteRoot = jail.remoteRoot;
        configPath = writeSshdConfig({
          tempRoot,
          address: targetAddress,
          port: sshPort,
          hostKey: initialHostKey,
          authorizedKeys: authorizedKeysPath,
          user,
          jailRoot,
        });
        sshdProcess = startSshd(configPath, tempRoot);
        await waitForPort(targetAddress, sshPort, sshdProcess);
        const fallbackBanner = await readTemporarySshBanner(targetAddress, sshPort);
        assertThat(fallbackBanner, 'temporary account SSHD did not emit an SSH-2.0 banner');
        try {
          verifyNonRootSshLogin({
            address: targetAddress,
            port: sshPort,
            keyPath: path.join(tempRoot, 'client_ecdsa'),
            account: sshLoginAccount,
          });
        } catch (_) {
          console.log('stage: disposable non-root SSH login preflight failed; sanitized diagnosis',
            JSON.stringify({
              sshKeyFingerprints: sshKeyFingerprintMatchSummary(
                path.join(tempRoot, 'client_ecdsa.pub'), authorizedKeysPath),
              authorizedKeysReadableByPreauth: (() => {
                const parent = fs.statSync(path.dirname(authorizedKeysPath));
                const file = fs.statSync(authorizedKeysPath);
                return parent.uid === 0 && (parent.mode & 0o005) === 0o005 &&
                  file.uid === 0 && (file.mode & 0o004) !== 0;
              })(),
              directChrootCommand: safeChrootCommandSummary(jailRoot, sshLoginAccount),
              sshd: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
              chrootRuntime: {
                rootOwned: fs.statSync(jailRoot).uid === 0,
                rootModeSafe: (fs.statSync(jailRoot).mode & 0o022) === 0,
                shellPresent: fs.existsSync(path.join(jailRoot, sshLoginAccount.shell.slice(1))),
                idPresent: fs.existsSync(path.join(jailRoot, 'usr/bin/id')) ||
                  fs.existsSync(path.join(jailRoot, 'bin/id')),
                passwdEntryPresent: fs.existsSync(path.join(jailRoot, 'etc/passwd')),
              },
            }));
          throw new Error(
            'disposable non-root SSH account could not authenticate its key or start inside the chroot',
          );
        }
      }
      console.log('stage: public-key SSH login ran as a non-root UID inside the fixture chroot',
        JSON.stringify({ uid: sshLoginAccount.uid, ephemeralAccount: Boolean(sshLoginAccount.ephemeral) }));
      safeRunStage = 'isolated second target SSHD fixture';
      const secondTargetJail = createSshdJail(
        path.join(sshdFixtureRoot, 'target-b'),
        sshLoginAccount,
      );
      secondRemoteRoot = secondTargetJail.remoteRoot;
      secondTargetUserKey = createKeyPair(tempRoot, 'second_target_client_ecdsa');
      fs.writeFileSync(
        secondTargetAuthorizedKeysPath,
        `${secondTargetUserKey.publicKey}\n`,
        { mode: 0o644 },
      );
      fs.chmodSync(secondTargetAuthorizedKeysPath, 0o644);
      secondTargetHostKey = path.join(tempRoot, 'sshd_second_target_host_ed25519');
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', secondTargetHostKey], {
        timeout: 30000,
      });
      fs.chmodSync(secondTargetHostKey, 0o600);
      secondTargetConfigPath = writeSshdConfig({
        tempRoot,
        address: targetAddress,
        port: sshPort2,
        hostKey: secondTargetHostKey,
        authorizedKeys: secondTargetAuthorizedKeysPath,
        user,
        jailRoot: secondTargetJail.jailRoot,
        instance: 'sshd-target-b',
      });
      secondTargetSshdProcess = startSshd(
        secondTargetConfigPath,
        tempRoot,
        'sshd-target-b',
      );
      await waitForPort(targetAddress, sshPort2, secondTargetSshdProcess);
      assertThat(await readTemporarySshBanner(targetAddress, sshPort2),
        'second loopback-only target SSHD did not emit an SSH-2.0 banner');
      verifyNonRootSshLogin({
        address: targetAddress,
        port: sshPort2,
        keyPath: path.join(tempRoot, 'second_target_client_ecdsa'),
        account: sshLoginAccount,
      });
      assertThat(secondTargetJail.remoteRoot !== remoteRoot &&
        fs.statSync(secondTargetJail.jailRoot).uid === 0 &&
        (fs.statSync(secondTargetJail.jailRoot).mode & 0o022) === 0,
      'second target does not have an independent root-owned chroot and remote directory');
      console.log('stage: two isolated loopback target SSHDs passed non-root login preflight',
        JSON.stringify({ distinctTargetPorts: true, independentChroots: true }));
      safeRunStage = 'isolated multi-hop loopback target SSHD fixture';
      const multiHopTargetJail = createSshdJail(
        path.join(sshdFixtureRoot, 'target-multihop'),
        sshLoginAccount,
      );
      multiHopRemoteRoot = multiHopTargetJail.remoteRoot;
      multiHopTargetUserKey = createKeyPair(tempRoot, 'multihop_target_client_ecdsa');
      fs.writeFileSync(
        multiHopTargetAuthorizedKeysPath,
        `${multiHopTargetUserKey.publicKey}\n`,
        { mode: 0o644 },
      );
      fs.chmodSync(multiHopTargetAuthorizedKeysPath, 0o644);
      multiHopTargetHostKey = path.join(tempRoot, 'sshd_multihop_target_host_ed25519');
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', multiHopTargetHostKey], {
        timeout: 30000,
      });
      fs.chmodSync(multiHopTargetHostKey, 0o600);
      multiHopTargetConfigPath = writeSshdConfig({
        tempRoot,
        address: targetAddress,
        port: multiHopTargetPort,
        hostKey: multiHopTargetHostKey,
        authorizedKeys: multiHopTargetAuthorizedKeysPath,
        user,
        jailRoot: multiHopTargetJail.jailRoot,
        instance: 'sshd-multihop-target',
      });
      multiHopTargetSshdProcess = startSshd(
        multiHopTargetConfigPath,
        tempRoot,
        'sshd-multihop-target',
      );
      await waitForPort(targetAddress, multiHopTargetPort, multiHopTargetSshdProcess);
      assertThat(await readTemporarySshBanner(targetAddress, multiHopTargetPort),
        'multi-hop loopback target SSHD did not emit an SSH-2.0 banner');
      verifyNonRootSshLogin({
        address: targetAddress,
        port: multiHopTargetPort,
        keyPath: path.join(tempRoot, 'multihop_target_client_ecdsa'),
        account: sshLoginAccount,
      });
      assertThat(multiHopTargetJail.remoteRoot !== remoteRoot &&
        multiHopTargetJail.remoteRoot !== secondRemoteRoot &&
        fs.statSync(multiHopTargetJail.jailRoot).uid === 0 &&
        (fs.statSync(multiHopTargetJail.jailRoot).mode & 0o022) === 0,
      'multi-hop target does not have an independent root-owned chroot and remote directory');
      console.log('stage: independent loopback multi-hop target passed non-root login preflight',
        JSON.stringify({ loopbackOnly: true, independentChroot: true }));

      let thirdJumpAuthorizedKeyLine = null;
      if (deepHopOnly) {
        safeRunStage = 'restricted third bastion SSHD configuration';
        thirdJumpUserKey = createKeyPair(tempRoot, 'third_jump_client_ecdsa');
        const cPermitOpen = extendedHopOnly
          ? `${address}:${fourthBastionPort}`
          : `${targetAddress}:${multiHopTargetPort}`;
        thirdJumpAuthorizedKeyLine =
          `restrict,port-forwarding,permitopen="${cPermitOpen}" ${thirdJumpUserKey.publicKey}`;
        fs.writeFileSync(thirdJumpAuthorizedKeysPath,
          `${thirdJumpAuthorizedKeyLine}\n`, { mode: 0o644 });
        fs.chmodSync(thirdJumpAuthorizedKeysPath, 0o644);
        thirdJumpHostKey = path.join(tempRoot, 'bastion_c_host_ed25519');
        run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', thirdJumpHostKey], {
          timeout: 30000,
        });
        fs.chmodSync(thirdJumpHostKey, 0o600);
        const thirdJumpJail = createSshdJail(
          path.join(sshdFixtureRoot, 'bastion-c'),
          sshLoginAccount,
        );
        thirdJumpRemoteRoot = thirdJumpJail.remoteRoot;
        thirdJumpConfigPath = writeSshdConfig({
          tempRoot,
          address,
          port: thirdBastionPort,
          hostKey: thirdJumpHostKey,
          authorizedKeys: thirdJumpAuthorizedKeysPath,
          user,
          jailRoot: thirdJumpJail.jailRoot,
          instance: 'third-jump-sshd',
          allowTcpForwarding: 'local',
          permitOpen: cPermitOpen,
        });
        thirdJumpSshdProcess = startSshd(
          thirdJumpConfigPath,
          tempRoot,
          'third-jump-sshd',
        );
        await waitForPort(address, thirdBastionPort, thirdJumpSshdProcess);
        assertThat(await readTemporarySshBanner(address, thirdBastionPort),
          'Bastion C SSHD did not emit an SSH-2.0 banner during preflight');
        verifyNonRootSshLogin({
          address,
          port: thirdBastionPort,
          keyPath: path.join(tempRoot, 'third_jump_client_ecdsa'),
          account: sshLoginAccount,
        });
        assertThat(thirdJumpJail.remoteRoot !== remoteRoot &&
          thirdJumpJail.remoteRoot !== secondRemoteRoot &&
          thirdJumpJail.remoteRoot !== multiHopRemoteRoot &&
          fs.statSync(thirdJumpJail.jailRoot).uid === 0 &&
          (fs.statSync(thirdJumpJail.jailRoot).mode & 0o022) === 0,
        'Bastion C does not have an independent root-owned chroot');

        if (extendedHopOnly) {
          safeRunStage = 'restricted fourth bastion SSHD configuration';
          fourthJumpUserKey = createKeyPair(tempRoot, 'fourth_jump_client_ecdsa');
          const fourthJumpNextHop = maxDepthHopOnly
            ? `${address}:${maxDepthBastionPorts[0]}`
            : `${targetAddress}:${multiHopTargetPort}`;
          const fourthJumpAuthorizedKeyLine =
            `restrict,port-forwarding,permitopen="${fourthJumpNextHop}" ${fourthJumpUserKey.publicKey}`;
          fs.writeFileSync(fourthJumpAuthorizedKeysPath,
            `${fourthJumpAuthorizedKeyLine}\n`, { mode: 0o644 });
          fs.chmodSync(fourthJumpAuthorizedKeysPath, 0o644);
          fourthJumpHostKey = path.join(tempRoot, 'bastion_d_host_ed25519');
          run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', fourthJumpHostKey], {
            timeout: 30000,
          });
          fs.chmodSync(fourthJumpHostKey, 0o600);
          const fourthJumpJail = createSshdJail(
            path.join(sshdFixtureRoot, 'bastion-d'),
            sshLoginAccount,
          );
          fourthJumpRemoteRoot = fourthJumpJail.remoteRoot;
          fourthJumpConfigPath = writeSshdConfig({
            tempRoot,
            address,
            port: fourthBastionPort,
            hostKey: fourthJumpHostKey,
            authorizedKeys: fourthJumpAuthorizedKeysPath,
            user,
            jailRoot: fourthJumpJail.jailRoot,
            instance: 'fourth-jump-sshd',
            allowTcpForwarding: 'local',
            permitOpen: fourthJumpNextHop,
          });
          fourthJumpSshdProcess = startSshd(
            fourthJumpConfigPath,
            tempRoot,
            'fourth-jump-sshd',
          );
          await waitForPort(address, fourthBastionPort, fourthJumpSshdProcess);
          assertThat(await readTemporarySshBanner(address, fourthBastionPort),
            'Bastion D SSHD did not emit an SSH-2.0 banner during preflight');
          verifyNonRootSshLogin({
            address,
            port: fourthBastionPort,
            keyPath: path.join(tempRoot, 'fourth_jump_client_ecdsa'),
            account: sshLoginAccount,
          });
          assertThat(fourthJumpJail.remoteRoot !== remoteRoot &&
            fourthJumpJail.remoteRoot !== secondRemoteRoot &&
            fourthJumpJail.remoteRoot !== multiHopRemoteRoot &&
            fourthJumpJail.remoteRoot !== thirdJumpRemoteRoot &&
            fs.statSync(fourthJumpJail.jailRoot).uid === 0 &&
            (fs.statSync(fourthJumpJail.jailRoot).mode & 0o022) === 0,
          'Bastion D does not have an independent root-owned chroot');
        }

        if (maxDepthHopOnly) {
          for (let index = 0; index < maxDepthBastionNames.length; index++) {
            const letter = maxDepthBastionNames[index];
            const nextHop = index + 1 < maxDepthBastionNames.length
              ? `${address}:${maxDepthBastionPorts[index + 1]}`
              : `${targetAddress}:${multiHopTargetPort}`;
            const key = createKeyPair(tempRoot, `max_depth_${letter.toLowerCase()}_client_ecdsa`);
            const authorizedKeysPath = maxDepthBastionAuthorizedKeysPaths[index];
            const authorizedKeyLine =
              `restrict,port-forwarding,permitopen="${nextHop}" ${key.publicKey}`;
            fs.writeFileSync(authorizedKeysPath, `${authorizedKeyLine}\n`, { mode: 0o644 });
            fs.chmodSync(authorizedKeysPath, 0o644);
            const hostKey = path.join(tempRoot, `bastion_${letter.toLowerCase()}_host_ed25519`);
            run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', hostKey], {
              timeout: 30000,
            });
            fs.chmodSync(hostKey, 0o600);
            const jail = createSshdJail(
              path.join(sshdFixtureRoot, `bastion-${letter.toLowerCase()}`),
              sshLoginAccount,
            );
            const configPath = writeSshdConfig({
              tempRoot,
              address,
              port: maxDepthBastionPorts[index],
              hostKey,
              authorizedKeys: authorizedKeysPath,
              user,
              jailRoot: jail.jailRoot,
              instance: `max-depth-${letter.toLowerCase()}-sshd`,
              allowTcpForwarding: 'local',
              permitOpen: nextHop,
            });
            const sshdProcess = startSshd(
              configPath,
              tempRoot,
              `max-depth-${letter.toLowerCase()}-sshd`,
            );
            maxDepthJumpSshdProcesses.push(sshdProcess);
            maxDepthJumpRemoteRoots.push(jail.remoteRoot);
            maxDepthJumpUserKeys.push(key);
            maxDepthJumpHostKeys.push(hostKey);
            maxDepthJumpConfigPaths.push(configPath);
            maxDepthJumpAuthorizedKeyLines.push(authorizedKeyLine);
            await waitForPort(address, maxDepthBastionPorts[index], sshdProcess);
            assertThat(await readTemporarySshBanner(address, maxDepthBastionPorts[index]),
              `Bastion ${letter} SSHD did not emit an SSH-2.0 banner during preflight`);
            verifyNonRootSshLogin({
              address,
              port: maxDepthBastionPorts[index],
              keyPath: key.privateKey,
              account: sshLoginAccount,
            });
            assertThat(jail.remoteRoot !== remoteRoot &&
              jail.remoteRoot !== secondRemoteRoot &&
              jail.remoteRoot !== multiHopRemoteRoot &&
              jail.remoteRoot !== thirdJumpRemoteRoot &&
              jail.remoteRoot !== fourthJumpRemoteRoot &&
              maxDepthJumpRemoteRoots.slice(0, index).every((root) => root !== jail.remoteRoot) &&
              fs.statSync(jail.jailRoot).uid === 0 &&
              (fs.statSync(jail.jailRoot).mode & 0o022) === 0,
            `Bastion ${letter} does not have an independent root-owned chroot`);
          }
        }
      }

      if (keyboardInteractiveOnly) {
        safeRunStage = 'temporary PAM challenge fixture setup';
        keyboardInteractiveCode = `WEB_KBD_CODE_${RUN_ID.replaceAll('-', '').slice(0, 16).toUpperCase()}`;
        keyboardInteractiveOtp = String(crypto.randomInt(100000, 1000000));
        keyboardInteractiveShellMarker = `WEB_KBD_SHELL_${RUN_ID.replaceAll('-', '').slice(0, 18).toUpperCase()}`;
        keyboardInteractivePamFixture = createKeyboardInteractivePamFixture({
          tempRoot,
          expectedCode: keyboardInteractiveCode,
          expectedOtp: keyboardInteractiveOtp,
        });

        keyboardInteractiveHostKey = path.join(tempRoot, 'kbdint_host_ed25519');
        keyboardInteractiveCancelHostKey = path.join(tempRoot, 'kbdint_cancel_host_ed25519');
        for (const hostKey of [keyboardInteractiveHostKey, keyboardInteractiveCancelHostKey]) {
          run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', hostKey], {
            timeout: 30000,
          });
          fs.chmodSync(hostKey, 0o600);
        }

        const keyboardInteractiveConfig = writeKeyboardInteractiveSshdConfig({
          tempRoot,
          address,
          port: bastionPort,
          hostKey: keyboardInteractiveHostKey,
          user,
          jailRoot,
          serviceName: keyboardInteractivePamFixture.serviceName,
          authenticationMethods: 'keyboard-interactive',
          passwordAuthentication: 'no',
          configName: 'kbdint-only-sshd',
        });
        jumpSshdProcess = startSshd(
          keyboardInteractiveConfig,
          tempRoot,
          'kbdint-only-sshd',
        );
        await waitForPort(address, bastionPort, jumpSshdProcess);
        assertThat(await readTemporarySshBanner(address, bastionPort),
          'keyboard-interactive-only SSHD did not emit an SSH banner');

        const cancelConfig = writeKeyboardInteractiveSshdConfig({
          tempRoot,
          address,
          port: secondBastionPort,
          hostKey: keyboardInteractiveCancelHostKey,
          user,
          jailRoot,
          serviceName: keyboardInteractivePamFixture.serviceName,
          authenticationMethods: 'keyboard-interactive,password',
          passwordAuthentication: 'yes',
          configName: 'kbdint-password-sshd',
        });
        secondJumpSshdProcess = startSshd(
          cancelConfig,
          tempRoot,
          'kbdint-password-sshd',
        );
        await waitForPort(address, secondBastionPort, secondJumpSshdProcess);
        assertThat(await readTemporarySshBanner(address, secondBastionPort),
          'keyboard-interactive/password SSHD did not emit an SSH banner');
        console.log('stage: isolated PAM SSHD fixtures are ready',
          JSON.stringify({ onlyKbdint: true, cancelChainHasPasswordFactor: true,
            distinctHostKeys: true, relayTargetsAreAllowlisted: true }));
        // relay_signal_cleanup.cjs uses this stable boundary to verify SIGINT cleanup.
        console.log('stage: isolated bastion and target SSHDs are ready');
        safeRunStage = 'isolated SSHD banner preflight passed';
      } else {
      safeRunStage = 'restricted second bastion SSHD configuration';
      secondJumpUserKey = createKeyPair(tempRoot, 'second_jump_client_ecdsa');
      const secondJumpPermittedEndpoints = extendedHopOnly
        ? [`${address}:${thirdBastionPort}`]
        : [
          `${targetAddress}:${multiHopTargetPort}`,
          ...(deepHopOnly ? [`${address}:${thirdBastionPort}`] : []),
        ];
      const secondJumpAuthorizedKeyLine = `restrict,port-forwarding,${secondJumpPermittedEndpoints
        .map((endpoint) => `permitopen="${endpoint}"`)
        .join(',')} ${secondJumpUserKey.publicKey}`;
      fs.writeFileSync(secondJumpAuthorizedKeysPath,
        `${secondJumpAuthorizedKeyLine}\n`, { mode: 0o644 });
      fs.chmodSync(secondJumpAuthorizedKeysPath, 0o644);
      secondJumpHostKey = path.join(tempRoot, 'bastion_b_host_ed25519');
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', secondJumpHostKey], {
        timeout: 30000,
      });
      fs.chmodSync(secondJumpHostKey, 0o600);
      assertThat(fs.readFileSync(`${secondJumpHostKey}.pub`, 'utf8').trim() !==
        fs.readFileSync(`${multiHopTargetHostKey}.pub`, 'utf8').trim(),
      'Bastion B and multi-hop target SSH host keys must be independent');
      const secondJumpJail = createSshdJail(
        path.join(sshdFixtureRoot, 'bastion-b'),
        sshLoginAccount,
      );
      secondJumpConfigPath = writeSshdConfig({
        tempRoot,
        address,
        port: secondBastionPort,
        hostKey: secondJumpHostKey,
        authorizedKeys: secondJumpAuthorizedKeysPath,
        user,
        jailRoot: secondJumpJail.jailRoot,
        instance: 'second-jump-sshd',
        allowTcpForwarding: 'local',
        permitOpen: secondJumpPermittedEndpoints,
      });
      secondJumpSshdProcess = startSshd(
        secondJumpConfigPath,
        tempRoot,
        'second-jump-sshd',
      );
      await waitForPort(address, secondBastionPort, secondJumpSshdProcess);
      assertThat(await readTemporarySshBanner(address, secondBastionPort),
        'Bastion B SSHD did not emit an SSH-2.0 banner during preflight');
      verifyNonRootSshLogin({
        address,
        port: secondBastionPort,
        keyPath: path.join(tempRoot, 'second_jump_client_ecdsa'),
        account: sshLoginAccount,
      });
      assertThat(secondJumpJail.remoteRoot !== multiHopTargetJail.remoteRoot &&
        fs.statSync(secondJumpJail.jailRoot).uid === 0 &&
        (fs.statSync(secondJumpJail.jailRoot).mode & 0o022) === 0,
      'Bastion B does not have an independent root-owned chroot');

      safeRunStage = 'restricted first bastion SSHD configuration';
      const targetAuthorizedKey = userKey.publicKey;
      const secondTargetAuthorizedKey = secondTargetUserKey.publicKey;
      jumpUserKey = createKeyPair(tempRoot, 'jump_client_ecdsa');
      const secondJumpAuthorizedKey = secondJumpUserKey.publicKey;
      assertThat(new Set([
        jumpUserKey.publicKey,
        secondJumpAuthorizedKey,
        ...(deepHopOnly ? [thirdJumpUserKey.publicKey] : []),
        ...(extendedHopOnly ? [fourthJumpUserKey.publicKey] : []),
        ...maxDepthJumpUserKeys.map((key) => key.publicKey),
        targetAuthorizedKey,
        secondTargetAuthorizedKey,
        multiHopTargetUserKey.publicKey,
      ]).size === (maxDepthHopOnly ? 11 : extendedHopOnly ? 7 : deepHopOnly ? 6 : 5),
      'both bastions and all target fixture credentials must be distinct');
      const permittedTargetEndpoints = extendedHopOnly
        ? [`${address}:${secondBastionPort}`]
        : [
          `${targetAddress}:${sshPort}`,
          `${targetAddress}:${sshPort2}`,
          `${address}:${secondBastionPort}`,
        ];
      const jumpAuthorizedKeyLine = `restrict,port-forwarding,${permittedTargetEndpoints
        .map((endpoint) => `permitopen="${endpoint}"`)
        .join(',')} ${jumpUserKey.publicKey}`;
      fs.writeFileSync(jumpAuthorizedKeysPath, `${jumpAuthorizedKeyLine}\n`, { mode: 0o644 });
      fs.chmodSync(jumpAuthorizedKeysPath, 0o644);
      const targetAuthorizedKeyFile = fs.readFileSync(authorizedKeysPath, 'utf8').trim();
      const secondTargetAuthorizedKeyFile = fs.readFileSync(
        secondTargetAuthorizedKeysPath,
        'utf8',
      ).trim();
      const multiHopTargetAuthorizedKeyFile = fs.readFileSync(
        multiHopTargetAuthorizedKeysPath,
        'utf8',
      ).trim();
      const secondJumpAuthorizedKeyFile = fs.readFileSync(
        secondJumpAuthorizedKeysPath,
        'utf8',
      ).trim();
      const thirdJumpAuthorizedKeyFile = deepHopOnly
        ? fs.readFileSync(thirdJumpAuthorizedKeysPath, 'utf8').trim()
        : null;
      const fourthJumpAuthorizedKeyFile = extendedHopOnly
        ? fs.readFileSync(fourthJumpAuthorizedKeysPath, 'utf8').trim()
        : null;
      const maxDepthAuthorizedKeyFiles = maxDepthHopOnly
        ? maxDepthBastionAuthorizedKeysPaths.map((filePath) =>
          fs.readFileSync(filePath, 'utf8').trim())
        : [];
      const bastionAuthorizedKeyFile = fs.readFileSync(jumpAuthorizedKeysPath, 'utf8').trim();
      assertThat(targetAuthorizedKeyFile === targetAuthorizedKey &&
        secondTargetAuthorizedKeyFile === secondTargetAuthorizedKey &&
        multiHopTargetAuthorizedKeyFile === multiHopTargetUserKey.publicKey &&
        secondJumpAuthorizedKeyFile === secondJumpAuthorizedKeyLine &&
        (!deepHopOnly || thirdJumpAuthorizedKeyFile === thirdJumpAuthorizedKeyLine) &&
        (!extendedHopOnly || fourthJumpAuthorizedKeyFile ===
          `restrict,port-forwarding,permitopen="${maxDepthHopOnly
            ? `${address}:${maxDepthBastionPorts[0]}`
            : `${targetAddress}:${multiHopTargetPort}`}" ${fourthJumpUserKey.publicKey}`) &&
        (!maxDepthHopOnly || maxDepthAuthorizedKeyFiles.every((line, index) =>
          line === maxDepthJumpAuthorizedKeyLines[index])) &&
        !targetAuthorizedKeyFile.includes(jumpUserKey.publicKey) &&
        !secondTargetAuthorizedKeyFile.includes(jumpUserKey.publicKey) &&
        !multiHopTargetAuthorizedKeyFile.includes(secondJumpAuthorizedKey) &&
        !multiHopTargetAuthorizedKeyFile.includes(jumpUserKey.publicKey) &&
        !secondJumpAuthorizedKeyFile.includes(multiHopTargetUserKey.publicKey) &&
        !secondJumpAuthorizedKeyFile.includes(jumpUserKey.publicKey) &&
        (!deepHopOnly || (!thirdJumpAuthorizedKeyFile.includes(secondJumpAuthorizedKey) &&
          !thirdJumpAuthorizedKeyFile.includes(jumpUserKey.publicKey))) &&
        (!extendedHopOnly || (!fourthJumpAuthorizedKeyFile.includes(secondJumpAuthorizedKey) &&
          !fourthJumpAuthorizedKeyFile.includes(thirdJumpUserKey.publicKey) &&
          !fourthJumpAuthorizedKeyFile.includes(jumpUserKey.publicKey))) &&
        (!maxDepthHopOnly || maxDepthAuthorizedKeyFiles.every((line) =>
          !line.includes(jumpUserKey.publicKey) &&
          !line.includes(secondJumpAuthorizedKey) &&
          !line.includes(thirdJumpUserKey.publicKey) &&
          !line.includes(fourthJumpUserKey.publicKey))) &&
        bastionAuthorizedKeyFile.includes(jumpUserKey.publicKey) &&
        !bastionAuthorizedKeyFile.includes(targetAuthorizedKey) &&
        !bastionAuthorizedKeyFile.includes(secondTargetAuthorizedKey) &&
        !bastionAuthorizedKeyFile.includes(secondJumpAuthorizedKey) &&
        (!extendedHopOnly || !bastionAuthorizedKeyFile.includes(fourthJumpUserKey.publicKey)) &&
        (!maxDepthHopOnly || maxDepthJumpUserKeys.every((key) =>
          !bastionAuthorizedKeyFile.includes(key.publicKey))) &&
        bastionAuthorizedKeyFile ===
          `restrict,port-forwarding,${permittedTargetEndpoints
            .map((endpoint) => `permitopen="${endpoint}"`)
            .join(',')} ${jumpUserKey.publicKey}`,
      'bastion and target authorized-key fixtures are not isolated and restricted');
      jumpHostKey = path.join(tempRoot, 'bastion_host_ed25519');
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', jumpHostKey], { timeout: 30000 });
      fs.chmodSync(jumpHostKey, 0o600);
      assertThat(fs.readFileSync(`${jumpHostKey}.pub`, 'utf8').trim() !==
        fs.readFileSync(`${initialHostKey}.pub`, 'utf8').trim(),
      'bastion and target SSH host keys must be independent');
      assertThat(new Set([
        fs.readFileSync(`${jumpHostKey}.pub`, 'utf8').trim(),
        fs.readFileSync(`${secondJumpHostKey}.pub`, 'utf8').trim(),
        ...(deepHopOnly ? [fs.readFileSync(`${thirdJumpHostKey}.pub`, 'utf8').trim()] : []),
        ...(extendedHopOnly ? [fs.readFileSync(`${fourthJumpHostKey}.pub`, 'utf8').trim()] : []),
        ...maxDepthJumpHostKeys.map((hostKey) =>
          fs.readFileSync(`${hostKey}.pub`, 'utf8').trim()),
        fs.readFileSync(`${initialHostKey}.pub`, 'utf8').trim(),
        fs.readFileSync(`${secondTargetHostKey}.pub`, 'utf8').trim(),
        fs.readFileSync(`${multiHopTargetHostKey}.pub`, 'utf8').trim(),
      ]).size === (maxDepthHopOnly ? 11 : extendedHopOnly ? 7 : deepHopOnly ? 6 : 5),
      'all bastion and target SSH host keys must be pairwise distinct');
      jumpConfigPath = writeSshdConfig({
        tempRoot,
        address,
        port: bastionPort,
        hostKey: jumpHostKey,
        authorizedKeys: jumpAuthorizedKeysPath,
        user,
        jailRoot,
        instance: 'jump-sshd',
        allowTcpForwarding: 'local',
        permitOpen: permittedTargetEndpoints,
      });
      safeRunStage = 'restricted bastion SSHD launch';
      jumpSshdProcess = startSshd(jumpConfigPath, tempRoot, 'jump-sshd');
      await waitForPort(address, bastionPort, jumpSshdProcess);
      assertThat(await readTemporarySshBanner(address, bastionPort),
        'bastion SSHD did not emit an SSH-2.0 banner during preflight');
      safeRunStage = 'non-root bastion public-key login preflight';
      try {
        verifyNonRootSshLogin({
          address,
          port: bastionPort,
          keyPath: path.join(tempRoot, 'jump_client_ecdsa'),
          account: sshLoginAccount,
        });
      } catch (error) {
        console.log('bastion public-key preflight safe evidence', JSON.stringify(
          error?.safePreflightDiagnostic || { completed: false },
        ));
        throw error;
      }
      console.log('stage: restricted bastion key authenticated as non-root',
        JSON.stringify({ uid: sshLoginAccount.uid, ephemeralAccount: Boolean(sshLoginAccount.ephemeral) }));
      console.log('stage: both restricted bastions and isolated target SSHDs are ready',
        JSON.stringify({ targetLoopbackOnly: true, relayFirstHopOnly: true,
          firstBastionForwardingRuleCount: permittedTargetEndpoints.length,
          secondBastionForwardingRuleCount: 1, credentialsDistinct: true }));
      // relay_signal_cleanup.cjs uses this stable boundary to verify SIGINT cleanup.
      console.log('stage: isolated bastion and target SSHDs are ready');
      safeRunStage = 'isolated SSHD banner preflight passed';
      }
    }

    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) {
      launchOptions.executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
    }
    safeRunStage = 'Playwright Chromium launch';
    try {
      browser = await chromium.launch(launchOptions);
    } catch (error) {
      console.log('Playwright launch safe diagnostic', JSON.stringify({
        errorType: error?.name || 'Error',
        message: redactCurrentSecrets(error?.message || '').slice(0, 1200),
      }));
      throw error;
    }
    safeRunStage = 'profile A browser context setup';
    context = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    });
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    safeRunStage = 'profile A Flutter probe registration';
    await installFlutterProbe(context);
    safeRunStage = 'profile A Relay close observer registration';
    await installRelayCloseObserver(context);
    safeRunStage = 'profile A download probe registration';
    await installBrowserDownloadProbe(context);
    safeRunStage = 'profile A browser page creation';
    let page;
    try {
      page = await context.newPage();
    } catch (error) {
      console.log('Profile A page creation safe diagnostic', JSON.stringify({
        errorType: error?.name || 'Error',
        message: redactCurrentSecrets(error?.message || '').slice(0, 1200),
      }));
      throw error;
    }
    page.on('pageerror', (error) => pageErrors.push(safeErrorSummary(error)));
    page.on('response', async (response) => {
      try {
        const url = new URL(response.url());
        if (terminalCollaborationPrivacy.active &&
            url.pathname.includes('/terminal-sessions')) {
          const body = await response.text().catch(() => null);
          recordTerminalCollaborationHttp(
            'response', 'A', response.request(), body,
          );
        }
        if (!url.pathname.startsWith('/api/v1/')) return;
        const matchingRequest = apiRequestByRequest.get(response.request());
        if (matchingRequest) {
          matchingRequest.completed = true;
          matchingRequest.status = response.status();
        }
        const event = {
          path: safeApiRoute(url.pathname),
          method: safeBrowserHttpMethod(response.request().method()),
          status: response.status(),
        };
        apiResponseDiagnostics.push({
          profile: 'A',
          path: event.path,
          method: event.method,
          status: event.status,
          capturedAtMs: performance.now(),
        });
        if (collaborationOnly && url.pathname === '/api/v1/instance' &&
            response.status() === 200) {
          try {
            const body = await response.json();
            const capabilities = Array.isArray(body?.capabilities)
              ? body.capabilities.filter((value) => typeof value === 'string')
              : [];
            event.terminalCollaborationAdvertised =
              capabilities.includes('terminal_collaboration');
            event.capabilityCount = capabilities.length;
          } catch (_) {
            event.terminalCollaborationAdvertised = null;
          }
        }
        if (collaborationOnly && response.status() === 200 &&
            /^\/api\/v1\/vaults\/[^/]+\/(?:devices|members)$/.test(url.pathname)) {
          try {
            const body = await response.json();
            if (url.pathname.endsWith('/devices')) {
              const devices = Array.isArray(body?.devices) ? body.devices : [];
              event.vaultDeviceCount = devices.length;
              event.activeVaultDeviceCount = devices.filter((row) =>
                row?.status === 'active' && row?.membership_status === 'active').length;
              event.activeDeviceKeyShapeCount = devices.filter((row) =>
                row?.status === 'active' && row?.membership_status === 'active' &&
                typeof row?.encryption_public_key === 'string' &&
                row.encryption_public_key.length >= 40).length;
              event.activeDeviceKey32ByteCount = devices.filter((row) => {
                if (row?.status !== 'active' || row?.membership_status !== 'active' ||
                    typeof row?.encryption_public_key !== 'string') return false;
                const decoded = Buffer.from(row.encryption_public_key, 'base64url');
                return decoded.length === 32 &&
                  decoded.toString('base64url') === row.encryption_public_key;
              }).length;
              event.activeDeviceNameMatchesExpectedCount = devices.filter((row) =>
                row?.status === 'active' && row?.membership_status === 'active' &&
                row?.name === profileBDeviceName).length;
            } else {
              const members = Array.isArray(body?.members) ? body.members : [];
              event.vaultMemberCount = members.length;
              event.activeVaultMemberCount = members.filter((row) =>
                row?.state === 'active' || row?.status === 'active').length;
            }
          } catch (_) {
            event.vaultDirectorySummaryAvailable = false;
          }
        }
        if (response.status() >= 400) {
          try {
            const body = await response.json();
            const code = body?.error?.code;
            if (typeof code === 'string' && /^[A-Z0-9_]{1,80}$/.test(code)) {
              event.errorCode = code;
            }
          } catch (_) {}
        }
        apiEvents.push(event);
        if (secretSyncPrivacy.active) {
          const method = response.request().method();
          const kind = method === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : method === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = await response.text().catch(() => null);
            secretSyncPrivacy.checks.push({
              profile: 'A',
              direction: 'response',
              kind,
              markerAbsent: secretSyncPrivacyBodyIsSafe(body),
            });
          }
        }
        if (portForwardSyncPrivacy.active) {
          const method = response.request().method();
          const kind = method === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : method === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = await response.text().catch(() => null);
            let eventCount = null;
            try {
              const decoded = JSON.parse(body);
              if (Array.isArray(decoded?.events)) eventCount = decoded.events.length;
            } catch (_) {}
            portForwardSyncPrivacy.checks.push({
              profile: 'A',
              direction: 'response',
              kind,
              status: response.status(),
              markerAbsent: body !== null && !body.includes(portForwardSyncPrivacy.marker),
              eventCount,
            });
          }
        }
        if (snippetRelaySync.active && response.request().method() === 'POST' &&
            url.pathname.endsWith('/sync/push')) {
          snippetRelaySync.pushStatuses.push(response.status());
        }
      } catch (_) {
        apiEvents.push({ path: '/api/v1/{unavailable}', status: null });
      }
    });
    page.on('requestfailed', (request) => {
      try {
        const failure = safeBrowserRequestFailure(
          request, baseUrl, safeRunStage, ++browserDiagnosticSequence,
          requestStartByRequest.get(request),
        );
        requestFailures.push(failure);
        requestFailureDiagnostics.push({
          profile: 'A',
          ...failure,
          capturedAtMs: performance.now(),
        });
      } catch (_) {
        const failure = {
          sequence: ++browserDiagnosticSequence,
          path: '/{unavailable}',
          originCategory: 'invalid_url',
          method: 'OTHER',
          resourceType: 'other',
          navigation: null,
          responseReceived: false,
          httpStatus: null,
          failurePhase: 'before_http_response',
          failureDetailsAvailable: false,
          failureCategory: 'unknown',
          failureCode: 'unavailable',
          ...safeBrowserStage(safeRunStage),
        };
        requestFailures.push(failure);
        requestFailureDiagnostics.push({
          profile: 'A',
          ...failure,
          capturedAtMs: performance.now(),
        });
      }
    });
    page.on('console', (message) => {
      const text = message.text();
      if (/^ATERMIUS_SSH_DIAG:[A-Za-z0-9_.-]+$/.test(text)) {
        sshDiagnostics.push(text.slice('ATERMIUS_SSH_DIAG:'.length));
        return;
      }
      if (/^ATERMIUS_XTERM_(?:KEY|KEY_HANDLED|ACTION|ACTION_HANDLED|CONNECTION_CLOSED|RESTORE_SCHEDULED|RESTORE_RUN):[A-Za-z0-9_.-]+$/.test(text)) {
        xtermInputDiagnostics.push(text);
        return;
      }
      if (/^ATERMIUS_SFTP_(?:CLIENT_OPENED|HANDSHAKE_COMPLETED|LISTDIR_STARTED|LISTDIR_COMPLETED:\d+)$/.test(text)) {
        sftpDiagnostics.push(text);
        return;
      }
      if (!['error', 'warning'].includes(message.type())) return;
      const sequence = ++browserDiagnosticSequence;
      const event = {
        sequence,
        profile: 'A',
        type: message.type(),
        ...safeErrorSummary({
          name: safeBrowserConsoleName(text),
          message: text,
        }),
        ...safeBrowserConsoleDetails(text, safeRunStage),
        ...safeBrowserConsoleSource(message),
      };
      browserConsoleCaptureTimes.set(sequence, performance.now());
      browserConsoleEvents.push(event);
    });
    page.on('request', (request) => {
      try {
        requestStartByRequest.set(request, safeBrowserRequestStart(safeRunStage));
        const url = new URL(request.url());
        captureTerminalCollaborationRequestContext(page, request);
        recordTerminalCollaborationHttp(
          'request', 'A', request, request.postData(),
        );
        if (url.pathname.startsWith('/api/v1/')) {
          const apiRequest = {
            path: safeApiRoute(url.pathname),
            method: request.method(),
            completed: false,
            status: null,
          };
          apiRequests.push(apiRequest);
          apiRequestByRequest.set(request, apiRequest);
        }
        if (url.pathname === '/api/v1/relay/tickets') {
          const body = JSON.parse(request.postData() || '{}');
          recordRelayTicketTargetCheck(page,
            body.target_host === address && allowedRelayPorts.includes(body.target_port),
          );
          return;
        }
        if (secretSyncPrivacy.active) {
          const kind = request.method() === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : request.method() === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = kind === 'push' ? request.postData() : request.url();
            secretSyncPrivacy.checks.push({
              profile: 'A',
              direction: 'request',
              kind,
              markerAbsent: secretSyncPrivacyBodyIsSafe(body),
            });
          }
        }
        if (portForwardSyncPrivacy.active) {
          const kind = request.method() === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : request.method() === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = kind === 'push' ? request.postData() : request.url();
            portForwardSyncPrivacy.checks.push({
              profile: 'A',
              direction: 'request',
              kind,
              markerAbsent: body !== null && !body.includes(portForwardSyncPrivacy.marker),
            });
          }
          if (url.origin !== new URL(baseUrl).origin) {
            portForwardSyncPrivacy.checks.push({
              profile: 'A',
              direction: 'request',
              kind: 'cross_origin',
              markerAbsent: true,
            });
          }
        }
        if (snippetRelaySync.active && request.method() === 'POST' &&
            url.pathname.endsWith('/sync/push')) {
          const body = request.postDataJSON();
          const serialized = stableJson(body);
          snippetRelaySync.pushes.push({
            vaultId: body?.vault_id,
            sensitiveMarkersAbsent: [
              snippetRelaySync.titleMarker,
              snippetRelaySync.secretMarker,
            ].filter(Boolean).every((marker) => !serialized.includes(marker)),
            operations: (Array.isArray(body?.operations) ? body.operations : [])
              .map(snippetSyncOperation),
          });
        }
      } catch (_) {
        if (request.url().includes('/api/v1/relay/tickets')) {
          recordRelayTicketTargetCheck(page, false);
        }
      }
    });
    page.on('websocket', (websocket) => {
      const url = new URL(websocket.url());
      if (url.pathname === '/collaboration/v1/connect') {
        trackTerminalCollaborationSocket(page, websocket);
        return;
      }
      if (url.pathname !== '/relay/v1/connect') return;
      const event = { path: url.pathname, page, opened: true, closed: false, sentFrames: [], receivedFrames: [], socketError: false, websocketRef: websocket };
      relaySockets.push(event);
      relaySocketsForPage(page).push(event);
      const summarizeFrame = (payload) => ({
        kind: typeof payload === 'string' ? 'text' : 'binary',
        bytes: typeof payload === 'string' ? Buffer.byteLength(payload) : payload.length,
      });
      websocket.on('framesent', ({ payload }) => event.sentFrames.push(summarizeFrame(payload)));
      websocket.on('framereceived', ({ payload }) => event.receivedFrames.push(summarizeFrame(payload)));
      websocket.on('socketerror', () => { event.socketError = true; });
      websocket.on('close', () => { event.closed = true; });
    });

    safeRunStage = 'profile A Web root navigation';
    const rootResponse = await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    assertThat(rootResponse && rootResponse.status() === 200, 'Web root did not return HTTP 200');
    safeRunStage = 'profile A Flutter semantics setup';
    await enableSemantics(page);
    safeRunStage = 'owner registration form';
    await fill(page, 'Server URL', baseUrl);
    const ownerServerUrlField = await field(page, 'Server URL');
    console.log('Owner server URL after fill safe evidence',
      JSON.stringify(await safeServerUrlInputEvidence(ownerServerUrlField, baseUrl)));
    safeRunStage = 'owner server connection submit';
    const connectOwnerButton = await button(page, 'Connect securely');
    assertThat(await connectOwnerButton.isEnabled(),
      'owner server connection form did not enable Connect securely');
    const requestsBeforeOwnerConnect = apiRequests.length;
    let ownerConnectAttempts = 0;
    while (ownerConnectAttempts < 3) {
      if (ownerConnectAttempts > 0 &&
          (apiRequests.length !== requestsBeforeOwnerConnect ||
            !await connectOwnerButton.isEnabled().catch(() => false))) {
        break;
      }
      await connectOwnerButton.click();
      ownerConnectAttempts += 1;
      await page.waitForTimeout(500);
      console.log('Owner server URL after button attempt safe evidence', JSON.stringify({
        attempt: ownerConnectAttempts,
        ...await safeServerUrlInputEvidence(ownerServerUrlField, baseUrl),
      }));
      if (apiRequests.length !== requestsBeforeOwnerConnect) break;
      if (ownerConnectAttempts < 3 &&
          await connectOwnerButton.isEnabled().catch(() => false)) {
        console.log('Owner connection tap safe recovery', JSON.stringify({
          retryCount: ownerConnectAttempts,
          apiRequestsStarted: false,
          buttonStillEnabled: true,
        }));
      }
    }
    if (apiRequests.length === requestsBeforeOwnerConnect &&
        await connectOwnerButton.isEnabled().catch(() => false)) {
      safeRunStage = 'owner server URL keyboard recovery';
      await enterExactServerUrlWithKeyboard(page, ownerServerUrlField, baseUrl, 'Owner');
      await connectOwnerButton.click();
      const submitDeadline = Date.now() + 10000;
      while (Date.now() < submitDeadline &&
          apiRequests.length === requestsBeforeOwnerConnect) {
        await page.waitForTimeout(100);
      }
      if (apiRequests.length === requestsBeforeOwnerConnect) {
        await ownerServerUrlField.focus().catch(() => {});
        await ownerServerUrlField.press('Enter').catch(() => {});
        const enterDeadline = Date.now() + 5000;
        while (Date.now() < enterDeadline &&
            apiRequests.length === requestsBeforeOwnerConnect) {
          await page.waitForTimeout(100);
        }
      }
    }
    safeRunStage = 'owner registration form transition';
    safeRunStage = 'owner registration email field';
    try {
      await field(page, 'Owner email');
    } catch (error) {
      const formEvidence = await page.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        };
        const body = document.body.innerText || '';
        const labels = [...document.querySelectorAll('input, textarea')]
          .filter(visible).map((element) =>
            (element.getAttribute('aria-label') || '').toLowerCase());
        const visibleInputs = [...document.querySelectorAll('input, textarea')]
          .filter(visible);
        const connectButtons = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => visible(element) &&
            /Connect securely/i.test(`${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`));
        return {
          visibleControlCount: labels.length,
          serverUrlVisible: labels.some((label) => label.includes('server url')),
          serverUrlHasValue: visibleInputs.some((element) =>
            (element.getAttribute('aria-label') || '').toLowerCase().includes('server url') &&
            typeof element.value === 'string' && element.value.trim().length > 0),
          ownerEmailVisible: labels.some((label) => label.includes('owner email')),
          loginEmailVisible: labels.some((label) => label.includes('email or username')),
          setupErrorVisible: /无法连接到服务端|server.*unavailable|invalid server|服务器/i.test(body),
          emptyServerUrlValidationVisible: /请输入服务端地址/.test(body),
          instanceIdentityMessageVisible: /实例签名|签名身份|instance identity|signing key/i.test(body),
          bootstrapMessageVisible: /bootstrap|初始化|一次性/i.test(body),
          validationMessageVisible: /请输入|invalid|failed|失败|错误/i.test(body),
          busyTextVisible: /connecting|连接中/i.test(body),
          progressIndicatorVisible: [...document.querySelectorAll(
            'flt-semantics[role="progressbar"], [role="progressbar"]',
          )].some(visible),
          connectButtonVisible: connectButtons.length > 0,
          visibleConnectButtonCount: connectButtons.length,
          enabledConnectButtonCount: connectButtons
            .filter((element) => element.getAttribute('aria-disabled') !== 'true')
            .length,
          connectButtonDisabled: connectButtons
            .some((element) => element.getAttribute('aria-disabled') === 'true'),
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      console.log('Owner server connection safe evidence', JSON.stringify({
        ...formEvidence,
        apiRequests: apiRequests.slice(-6),
        apiEvents: apiEvents.slice(-6),
        requestFailureCategories: requestFailures.slice(-6).map((failure) =>
          failure.failureCategory || 'unknown'),
        browserPageErrorCount: pageErrors.length,
      }));
      throw error;
    }
    await fill(page, 'Owner email', USERNAME);
    await fill(page, 'Master password · 12+ characters', MASTER_PASSWORD);
    await fill(page, 'Confirm master password', MASTER_PASSWORD);
    await fill(page, 'One-time bootstrap token', bootstrapToken);
    await fill(page, 'Device name', 'Relay terminal test');
    await fill(page, 'First Vault', 'Relay terminal test vault');
    safeRunStage = 'owner registration readiness';
    const createOwnerButton = page.getByRole('button', {
      name: 'Create owner account', exact: true,
    }).last();
    await createOwnerButton.waitFor({ state: 'visible', timeout: 10000 });
    const readinessDeadline = Date.now() + 5000;
    let createOwnerEnabled = false;
    while (Date.now() < readinessDeadline) {
      createOwnerEnabled = await createOwnerButton.isEnabled().catch(() => false);
      if (createOwnerEnabled) break;
      await page.waitForTimeout(100);
    }
    console.log('Owner registration readiness safe evidence', JSON.stringify({
      createButtonCount: await createOwnerButton.count().catch(() => 0),
      createButtonEnabled: createOwnerEnabled,
      fieldsWereVerifiedExact: true,
    }));
    assertThat(createOwnerEnabled,
      'owner registration form did not accept the verified field values');
    await click(page, 'Create owner account');
    bootstrapToken = undefined;
    safeRunStage = 'owner account created';
    try {
      await click(page, 'Hosts');
      await button(page, 'Add host');
    } catch (error) {
      const transitionEvidence = await page.evaluate(() => {
        const visibleText = [
          document.body.innerText || '',
          ...[...document.querySelectorAll('flt-semantics')]
            .map((element) => element.innerText || element.textContent || ''),
        ].join('\n');
        const createButton = [...document.querySelectorAll(
          'flt-semantics[role="button"],button',
        )].filter((element) => {
          const label = element.getAttribute('aria-label') || element.innerText || '';
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return label.trim() === 'Create owner account' && rect.width > 0 &&
            rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
        });
        const buttonCount = (name) => [...document.querySelectorAll(
          'flt-semantics[role="button"],button',
        )].filter((element) => {
          const label = element.getAttribute('aria-label') || element.innerText || '';
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return label.trim() === name && rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        }).length;
        const lower = visibleText.toLowerCase();
        return {
          registrationFormVisible: visibleText.includes('Owner email') &&
            visibleText.includes('Create owner account'),
          hostsWorkspaceVisible: visibleText.includes('Hosts') &&
            visibleText.includes('Add host'),
          registrationFormDialogCount: [...document.querySelectorAll(
            '[role="dialog"],flt-semantics[role="dialog"]',
          )].filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.display !== 'none' && style.visibility !== 'hidden';
          }).length,
          createButtonCount: createButton.length,
          createButtonDisabled: createButton.length
            ? Boolean(createButton[0].disabled ||
              createButton[0].getAttribute('aria-disabled') === 'true')
            : null,
          hostsButtonCount: buttonCount('Hosts'),
          addHostButtonCount: buttonCount('Add host'),
          errorCategories: {
            required: lower.includes('required'),
            email: lower.includes('email') || lower.includes('valid address'),
            password: lower.includes('password'),
            bootstrap: lower.includes('bootstrap') || lower.includes('token'),
            serverConnection: lower.includes('server') &&
              (lower.includes('connect') || lower.includes('unavailable')),
            conflict: lower.includes('already exists') || lower.includes('already registered'),
            generic: lower.includes('something went wrong') || lower.includes('request failed'),
          },
        };
      });
      console.log('Owner creation transition safe evidence', JSON.stringify({
        errorType: error?.name || 'Error',
        ...transitionEvidence,
      }));
      throw error;
    }
    safeRunStage = 'Hosts workspace';
    console.log('stage: owner account created; Hosts workspace visible');

    if (pemDiagnosticOnly) {
      await click(page, 'Credentials');
      await click(page, 'Add credential');
      safeRunStage = 'New SSH credential dialog';
      const privateKeySegment = page.getByRole('button', { name: 'Private key', exact: true }).first();
      await privateKeySegment.click();
      safeRunStage = 'Private key segment selected';
      await page.waitForTimeout(300);
      const segmentState = await privateKeySegment.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        const label = element.getAttribute('aria-label') || '';
        return {
          tag: element.tagName,
          role: element.getAttribute('role') || '',
          ariaLabelLength: label.length,
          visible: rect.width > 0 && rect.height > 0,
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          focused: element === document.activeElement,
          ariaSelected: element.getAttribute('aria-selected'),
          ariaPressed: element.getAttribute('aria-pressed'),
          ariaChecked: element.getAttribute('aria-checked'),
          ariaExpanded: element.getAttribute('aria-expanded'),
        };
      });
      const diagnostic = await page.evaluate(() => {
        const semantics = [...document.querySelectorAll('flt-semantics')];
        const aria = (element) => element.getAttribute('aria-label') || '';
        const hasTitle = semantics.some((element) =>
          /New SSH credential/.test(aria(element)));
        const pemLabelPresent = semantics.some((element) =>
          /PEM private key/.test(aria(element)));
        const roleCounts = {};
        for (const element of semantics) {
          const role = element.getAttribute('role') || 'unlabeled';
          roleCounts[role] = (roleCounts[role] || 0) + 1;
        }
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none';
        };
        const controls = [...document.querySelectorAll('input,textarea')].map((element) => {
          const rect = element.getBoundingClientRect();
          const label = aria(element);
          return {
            tag: element.tagName,
            role: element.getAttribute('role') || '',
            ariaLabel: label,
            type: element.getAttribute('type') || '',
            visible: visible(element),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            rows: element instanceof HTMLTextAreaElement ? element.rows : null,
            focused: element === document.activeElement,
          };
        });
        const dialogRoleCount = semantics.filter((element) =>
          element.getAttribute('role') === 'dialog').length;
        const titleRoleCount = semantics.filter((element) =>
          element.getAttribute('role') === 'heading').length;
        return {
          credentialTitleAriaPresent: hasTitle,
          pemLabelPresentInSemantics: pemLabelPresent,
          credentialFormStructurallyPresent: controls.some((item) =>
            /Credential name/.test(item.ariaLabel)) && controls.some((item) =>
            /SSH username/.test(item.ariaLabel)),
          dialogRoleCount,
          headingRoleCount: titleRoleCount,
          counts: {
            buttons: semantics.filter((element) => element.getAttribute('role') === 'button').length,
            inputs: document.querySelectorAll('input').length,
            textareas: document.querySelectorAll('textarea').length,
          },
          roleCounts,
          controls,
        };
      });
      console.log('PEM UI safe preflight', JSON.stringify({ ...diagnostic, privateKeySegment: segmentState }));
      return;
    }

    const bastionCredentialName = `Relay bastion key ${RUN_ID.slice(0, 6)}`;
    const credentialName = `Relay target key ${RUN_ID.slice(0, 6)}`;
    const secondBastionCredentialName = `Relay bastion B key ${RUN_ID.slice(0, 6)}`;
    const thirdBastionCredentialName = `Relay bastion C key ${RUN_ID.slice(0, 6)}`;
    const fourthBastionCredentialName = `Relay bastion D key ${RUN_ID.slice(0, 6)}`;
    const maxDepthBastionCredentialNames = maxDepthBastionNames.map((letter) =>
      `Relay bastion ${letter} key ${RUN_ID.slice(0, 6)}`);
    const maxDepthBastionHostNames = maxDepthBastionNames.map((letter) =>
      `Relay bastion ${letter} ${RUN_ID.slice(0, 6)}`);
    const multiHopTargetCredentialName = `Relay two-hop target key ${RUN_ID.slice(0, 6)}`;
    const snippetCredentialName = `Relay Snippet secret ${RUN_ID.slice(0, 6)}`;
    const bastionHostName = `Relay bastion ${RUN_ID.slice(0, 6)}`;
    const secondBastionHostName = `Relay bastion B ${RUN_ID.slice(0, 6)}`;
    const thirdBastionHostName = `Relay bastion C ${RUN_ID.slice(0, 6)}`;
    const fourthBastionHostName = `Relay bastion D ${RUN_ID.slice(0, 6)}`;
    const hostName = `Local relay SSH ${RUN_ID.slice(0, 6)}`;
    const multiHopHostName = `Local relay two-hop SSH ${RUN_ID.slice(0, 6)}`;
    const threeHopHostName = `Local relay three-hop SSH ${RUN_ID.slice(0, 6)}`;
    const fourHopHostName = `Local relay four-hop SSH ${RUN_ID.slice(0, 6)}`;
    const maxDepthHostName = `Local relay eight-hop SSH ${RUN_ID.slice(0, 6)}`;
    const profileBDeviceName = `Relay profile B ${RUN_ID.slice(0, 6)}`;
    let portForwardProfileName = null;
    let portForwardBindPort = null;
    const credentialSubstitutionMarker =
      `WEB_RELAY_SECRET_${RUN_ID.replaceAll('-', '').toUpperCase()}_EXPANDED`;
    snippetCredentialSecret =
      `$(touch /tmp/remote/${credentialSubstitutionMarker})_SECRET_${RUN_ID}`;
    secretSyncPrivacy.active = true;
    secretSyncPrivacy.marker = snippetCredentialSecret;
    secretSyncPrivacy.additionalMarkers = deepHopOnly ? [
      userKey.privateKey,
      jumpUserKey.privateKey,
      secondJumpUserKey.privateKey,
      thirdJumpUserKey.privateKey,
      ...(extendedHopOnly ? [fourthJumpUserKey.privateKey] : []),
      ...maxDepthJumpUserKeys.map((key) => key.privateKey),
      multiHopTargetUserKey.privateKey,
    ].map((privateKeyPath) => fs.readFileSync(privateKeyPath, 'utf8')
      .replace(/[\r\n]+$/, '')) : [];
    if (keyboardInteractiveOnly) {
      safeRunStage = 'keyboard-interactive browser privacy markers';
      secretSyncPrivacy.marker = keyboardInteractiveCode;
      const kbdCredentialName = `KBD interactive test ${RUN_ID.slice(0, 6)}`;
      keyboardInteractiveUnusedPassword = `WEB_KBD_UNUSED_PASSWORD_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      secretSyncPrivacy.additionalMarkers = [
        keyboardInteractiveOtp,
        keyboardInteractiveUnusedPassword,
        keyboardInteractiveShellMarker,
      ];
      const kbdHostName = `KBD interactive host ${RUN_ID.slice(0, 6)}`;
      const cancelHostName = `KBD cancel host ${RUN_ID.slice(0, 6)}`;
      const kbdCredentialId = await savePasswordCredential(page, {
        name: kbdCredentialName,
        username: user,
        secret: keyboardInteractiveUnusedPassword,
      });
      const kbdHostCard = await createSshHost(page, {
        name: kbdHostName,
        address,
        port: bastionPort,
        username: user,
        credentialName: kbdCredentialName,
        credentialId: kbdCredentialId,
        verifySavedCredentialOverride: true,
      });
      const cancelHostCard = await createSshHost(page, {
        name: cancelHostName,
        address,
        port: secondBastionPort,
        username: user,
        credentialName: kbdCredentialName,
        credentialId: kbdCredentialId,
        verifySavedCredentialOverride: true,
      });

      const expectChallengeForHost = async ({
        hostName: expectedHostName,
        port: expectedPort,
        fingerprint,
      }) => {
        const tickets = relayTicketChecksForPage(page);
        const ticketBaseline = tickets.length;
        // A completed SSH connection moves the workspace to Terminal. Reopen
        // Hosts and resolve the card from the current semantics tree so the
        // cancellation case never clicks a stale/off-route card locator.
        safeRunStage = `${expectedHostName} Hosts route before Connect`;
        await click(page, 'Hosts');
        const escapedHostName = expectedHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const currentHostCard = page.getByRole('group', {
          name: new RegExp(escapedHostName),
        }).first();
        safeRunStage = `${expectedHostName} Host card readiness`;
        await currentHostCard.waitFor({ state: 'visible', timeout: 15000 });
        const connectButton = currentHostCard.getByRole('button', {
          name: 'Connect', exact: true,
        });
        const connectButtonCount = await connectButton.count();
        const connectButtonVisible = await connectButton.isVisible().catch(() => false);
        const connectButtonEnabled = await connectButton.isEnabled().catch(() => false);
        console.log('keyboard-interactive Host Connect readiness safe evidence',
          JSON.stringify({
            hostCardVisible: await currentHostCard.isVisible().catch(() => false),
            connectButtonCount,
            connectButtonVisible,
            connectButtonEnabled,
          }));
        assertThat(connectButtonCount === 1 && connectButtonVisible &&
          connectButtonEnabled,
        'keyboard-interactive Host Connect action was not uniquely visible and enabled');
        safeRunStage = `${expectedHostName} Connect action`;
        await connectButton.click();
        safeRunStage = `${expectedHostName} first-use SSH host key prompt`;
        const trustState = await waitForSshTrustOrError(page, 60000, expectedHostName);
        const trustEndpointVisible = await visibleSshTrustPromptMatchesEndpoint(
          page, `${address}:${expectedPort}`,
        );
        if (trustState !== 'host_key_prompt' || !trustEndpointVisible) {
          const visibleFailure = await page.evaluate(() => {
            const text = document.body?.innerText || '';
            return {
              relayErrorVisible: /Relay|中继/i.test(text),
              hostKeyTextVisible: /host key|fingerprint|主机密钥|指纹/i.test(text),
              authErrorVisible: /authentication|认证|身份验证/i.test(text),
              connectionErrorVisible: /failed|failure|错误|失败/i.test(text),
              connectedVisible: text.includes('CONNECTED'),
            };
          }).catch(() => ({}));
          console.log('keyboard-interactive trust safe diagnostic', JSON.stringify({
            state: trustState,
            expectedEndpointVisible: trustEndpointVisible,
            visibleFailure,
            ticketCount: tickets.length - ticketBaseline,
            ticketTargetsAllowed: tickets.slice(ticketBaseline).every(Boolean),
            relaySocketCount: relaySocketsForPage(page).length,
            openRelaySockets: relaySocketsForPage(page)
              .filter((socket) => socket.opened && !socket.closed).length,
            requestFailureCount: requestFailures.length,
            recentRequestFailureCategories: requestFailures.slice(-4)
              .map((failure) => failure.failureCategory),
            sshd: sshdRuntimeSummary(path.join(tempRoot, expectedPort === bastionPort
              ? 'kbdint-only-sshd.log' : 'kbdint-password-sshd.log')),
            sshDiagnostics: safeSshDiagnosticSummary(sshDiagnostics),
          }));
        }
        assertThat(trustState === 'host_key_prompt' &&
          trustEndpointVisible,
        'keyboard-interactive fixture did not present the expected first-use Host key prompt');
        const fingerprintEvidence = await visibleSshTrustPromptShowsFingerprint(
          page, fingerprint,
        );
        console.log('keyboard-interactive trust fingerprint safe evidence', JSON.stringify({
          trustPromptVisible: trustState === 'host_key_prompt',
          endpointMatches: trustEndpointVisible,
          ...fingerprintEvidence,
          fingerprintVisible: fingerprintEvidence.exactFingerprintVisible,
          expectedFingerprintLength: fingerprint.length,
        }));
        if (!fingerprintEvidence.exactFingerprintVisible) {
          const trustScreenshotPath = path.join(tempRoot,
            'kbdint-host-key-trust-debug.png');
          await page.screenshot({ path: trustScreenshotPath, fullPage: true });
          console.log('keyboard-interactive trust screenshot safely staged', JSON.stringify({
            path: trustScreenshotPath,
          }));
          await page.waitForTimeout(12000);
        }
        assertThat(fingerprintEvidence.exactFingerprintVisible,
          'Web Host trust prompt fingerprint did not match the generated SSHD key');
        const promptToken = await sshTrustPromptToken(page);
        safeRunStage = `${expectedHostName} explicit SSH host key approval`;
        await click(page, 'Trust after verification');
        await waitForSshTrustPromptAdvance(page, promptToken, 60000);

        safeRunStage = `${expectedHostName} keyboard-interactive challenge dialog`;
        try {
          await page.getByText('SSH authentication challenge', {
            exact: true,
          }).waitFor({ state: 'visible', timeout: 30000 });
        } catch (_) {
          const challengeState = await page.evaluate(() => {
            const bodyText = document.body?.innerText || '';
            const semanticText = [...document.querySelectorAll('flt-semantics')]
              .map((element) => [
                element.getAttribute('aria-label'),
                element.innerText,
                element.textContent,
              ].filter(Boolean).join('\n')).join('\n');
            const text = `${bodyText}\n${semanticText}`;
            const visible = (element) => {
              const rect = element.getBoundingClientRect();
              const style = getComputedStyle(element);
              return rect.width > 0 && rect.height > 0 &&
                style.display !== 'none' && style.visibility !== 'hidden' &&
                Number(style.opacity || 1) > 0;
            };
            const visibleDialogs = [...document.querySelectorAll(
              '[role="dialog"], [role="alertdialog"], flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
            )].filter(visible);
            const visibleInputs = [...document.querySelectorAll('input,textarea')]
              .filter(visible);
            const inputEvidence = visibleInputs.map((element) => ({
              type: element instanceof HTMLInputElement ? element.type : 'textarea',
              ariaLabel: element.getAttribute('aria-label') || '',
              ariaDescription: element.getAttribute('aria-description') || '',
            }));
            return {
              challengeTitleVisible: text.includes('SSH authentication challenge'),
              accountPromptVisible: text.includes('Account code:'),
              otpPromptVisible: text.includes('One-time code:'),
              responseOnePromptVisible: /Response\s*1/i.test(text),
              responseTwoPromptVisible: /Response\s*2/i.test(text),
              noResponseMessageVisible: text.includes('The server did not request a response.'),
              promptLimitMessageVisible: text.includes('The SSH server requested too many responses.'),
              hostKeyPromptVisible: text.includes('Verify SSH host key'),
              trustActionVisible: text.includes('Trust after verification'),
              authenticationErrorVisible: /authentication failed|身份验证失败|认证失败/i.test(text),
              relayErrorVisible: /无法建立 SSH 中继|SSH 中继连接超时|Relay ticket/i.test(text),
              terminalConnectedVisible: text.includes('CONNECTED'),
              visibleDialogCount: visibleDialogs.length,
              visibleInputCount: visibleInputs.length,
              visibleTextInputCount: inputEvidence.filter((item) =>
                item.type !== 'password').length,
              visiblePasswordInputCount: inputEvidence.filter((item) =>
                item.type === 'password').length,
              accountLabelInputCount: inputEvidence.filter((item) =>
                item.ariaLabel.includes('Account code:') ||
                item.ariaDescription.includes('Account code:')).length,
              otpLabelInputCount: inputEvidence.filter((item) =>
                item.ariaLabel.includes('One-time code:') ||
                item.ariaDescription.includes('One-time code:')).length,
              connectedTabCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
                .filter(visible).filter((element) => /terminal tab, connected,/i.test(
                  element.getAttribute('aria-label') || element.innerText || '',
                )).length,
              failedTabCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
                .filter(visible).filter((element) => /terminal tab, failed,/i.test(
                  element.getAttribute('aria-label') || element.innerText || '',
                )).length,
            };
          }).catch(() => ({ inspectionAvailable: false }));
          const sshdLogPath = path.join(tempRoot, 'kbdint-only-sshd.log');
          let authMethodCounts = {};
          let keyboardInteractiveLogLineCount = 0;
          let pamLogLineCount = 0;
          try {
            const lines = fs.readFileSync(sshdLogPath, 'utf8').split(/\r?\n/);
            authMethodCounts = Object.fromEntries(['keyboard-interactive', 'password', 'none']
              .map((method) => [method, lines.filter((line) =>
                new RegExp(`userauth-request for user .* method ${method}`, 'i').test(line),
              ).length]));
            keyboardInteractiveLogLineCount = lines.filter((line) =>
              /keyboard-interactive|userauth_kbdint|kbdint/i.test(line)).length;
            pamLogLineCount = lines.filter((line) => /PAM:/i.test(line)).length;
          } catch (_) {}
          console.log('keyboard-interactive challenge safe diagnostic', JSON.stringify({
            browser: challengeState,
            sshd: sshdRuntimeSummary(sshdLogPath),
            authMethodCounts,
            keyboardInteractiveLogLineCount,
            pamLogLineCount,
            relayTicketCount: relayTicketChecksForPage(page).length,
            relayTicketsAllowlisted: relayTicketChecksForPage(page).every(Boolean),
            relaySocketCount: relaySocketsForPage(page).length,
            openRelaySocketCount: relaySocketsForPage(page)
              .filter((socket) => socket.opened && !socket.closed).length,
            sshDiagnosticCategories: safeSshDiagnosticSummary(sshDiagnostics),
            requestFailureCount: requestFailures.length,
            recentRequestFailureCategories: requestFailures.slice(-4)
              .map((failure) => failure.failureCategory),
          }));
          throw new Error('keyboard-interactive challenge dialog did not appear after Host approval');
        }
        const expectedContext = `${expectedHostName} · ${address}:${expectedPort}`;
        const challengeTitleVisible = await page.getByText(
          'SSH authentication challenge', { exact: true },
        ).isVisible().catch(() => false);
        const contextVisible = await page.getByText(expectedContext, { exact: true })
          .isVisible().catch(() => false);
        // Flutter Web exposes TextField labels as the input's accessible name;
        // the floating label is not necessarily a standalone DOM text node.
        const accountPromptInput = await field(page, 'Account code:');
        const accountPromptInputType = await accountPromptInput.getAttribute('type');
        const accountPromptInputCount = await page.locator(
          'input[aria-label*="Account code:"]:visible',
        ).count();
        const otpPromptInputCount = await page.locator(
          'input[aria-label*="One-time code:"]:visible',
        ).count();
        const challengeDomEvidence = await page.evaluate(() => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.display !== 'none' && style.visibility !== 'hidden' &&
              Number(style.opacity || 1) > 0;
          };
          const bodyText = document.body?.innerText || '';
          const semanticText = [...document.querySelectorAll('flt-semantics')]
            .filter(visible)
            .map((element) => [
              element.getAttribute('aria-label'), element.innerText,
              element.textContent,
            ].filter(Boolean).join('\n')).join('\n');
          const text = `${bodyText}\n${semanticText}`;
          const visibleInputs = [...document.querySelectorAll('input,textarea')]
            .filter(visible).map((element) => ({
              type: element instanceof HTMLInputElement ? element.type : 'textarea',
              ariaLabel: element.getAttribute('aria-label') || '',
              ariaDescription: element.getAttribute('aria-description') || '',
            }));
          const promptLabel = /Account code:/i;
          return {
            promptTextVisibleInBody: {
              accountCode: bodyText.includes('Account code:'),
              oneTimeCode: bodyText.includes('One-time code:'),
              responseOne: /Response\s*1/i.test(text),
              responseTwo: /Response\s*2/i.test(text),
              noResponse: text.includes('The server did not request a response.'),
              tooManyResponses: text.includes('The SSH server requested too many responses.'),
            },
            visibleInputCount: visibleInputs.length,
            visibleTextInputCount: visibleInputs.filter((item) =>
              item.type !== 'password').length,
            visiblePasswordInputCount: visibleInputs.filter((item) =>
              item.type === 'password').length,
            inputAriaLabelsMatchAccountPrompt: visibleInputs.filter((item) =>
              promptLabel.test(item.ariaLabel) || promptLabel.test(item.ariaDescription)).length,
            inputAriaLabelsMatchOtpPrompt: visibleInputs.filter((item) =>
              /One-time code:/i.test(item.ariaLabel) ||
              /One-time code:/i.test(item.ariaDescription)).length,
            semanticAccountPromptVisible: /Account code:/i.test(semanticText),
            semanticOtpPromptVisible: /One-time code:/i.test(semanticText),
          };
        }).catch(() => ({ inspectionAvailable: false }));
        const challengePresentationEvidence = {
          challengeTitleVisible,
          exactHostContextVisible: contextVisible,
          accountPromptInputCount,
          accountPromptEchoOn: accountPromptInputType !== 'password',
          otpPromptInputCount,
          ...challengeDomEvidence,
          relayTicketsAdded: tickets.length - ticketBaseline,
          relayTicketsAllAllowlisted: tickets.slice(ticketBaseline).every(Boolean),
        };
        console.log('keyboard-interactive first challenge round safe evidence',
          JSON.stringify(challengePresentationEvidence));
        assertThat(contextVisible,
          'keyboard-interactive dialog did not identify the challenged Host and endpoint');
        assertThat(accountPromptInputCount === 1 && otpPromptInputCount === 0 &&
          accountPromptInputType !== 'password',
        'first PAM challenge round did not expose one echo-on account-code field');
        assertThat(tickets.length > ticketBaseline &&
          tickets.slice(ticketBaseline).every(Boolean),
        'keyboard-interactive Relay ticket was not restricted to the two fixture endpoints');
      };

      const firstSocketBaseline = relaySocketsForPage(page).length;
      await expectChallengeForHost({
        hostName: kbdHostName,
        port: bastionPort,
        fingerprint: sshKeyFingerprint(keyboardInteractiveHostKey),
      });
      const codeInput = await field(page, 'Account code:');
      const codeInputType = await codeInput.getAttribute('type');
      assertThat(codeInputType !== 'password',
        'echo-on keyboard-interactive account code was unexpectedly obscured');
      await fill(page, 'Account code:', keyboardInteractiveCode);
      safeRunStage = 'keyboard-interactive challenge response submit';
      await click(page, 'Send responses');
      safeRunStage = 'keyboard-interactive second challenge round';
      await page.getByText('SSH authentication challenge', {
        exact: true,
      }).waitFor({ state: 'visible', timeout: 30000 });
      const otpInput = await field(page, 'One-time code:');
      const otpInputType = await otpInput.getAttribute('type');
      const accountPromptInputCountAfterFirstResponse = await page.locator(
        'input[aria-label*="Account code:"]:visible',
      ).count();
      const otpPromptInputCount = await page.locator(
        'input[aria-label*="One-time code:"]:visible',
      ).count();
      console.log('keyboard-interactive second challenge round safe evidence',
        JSON.stringify({
          challengeTitleVisible: true,
          exactHostContextVisible: await page.getByText(
            `${kbdHostName} · ${address}:${bastionPort}`, { exact: true },
          ).isVisible().catch(() => false),
          accountPromptInputCount: accountPromptInputCountAfterFirstResponse,
          otpPromptInputCount,
          echoOffMasked: otpInputType === 'password',
        }));
      assertThat(accountPromptInputCountAfterFirstResponse === 0 &&
        otpPromptInputCount === 1 && otpInputType === 'password',
      'second PAM challenge round did not expose exactly one obscured one-time-code field');
      await fill(page, 'One-time code:', keyboardInteractiveOtp);
      const echoInputTypes = [codeInputType, otpInputType];
      safeRunStage = 'keyboard-interactive second challenge response submit';
      await click(page, 'Send responses');
      safeRunStage = 'keyboard-interactive-only SSH terminal connection';
      const connected = await waitForTerminalConnectionOrTrust(page, kbdHostName, 45000);
      assertThat(connected === 'connected',
        'correct keyboard-interactive responses did not open a Web SSH terminal');
      await terminalTabButton(page, kbdHostName, 'active');
      const firstActiveSockets = relaySocketsForPage(page).filter((socket) =>
        socket.opened && !socket.closed);
      assertThat(firstActiveSockets.length === 1 &&
        relaySocketsForPage(page).length > firstSocketBaseline,
      'successful keyboard-interactive login did not leave exactly one Relay WebSocket open');
      const firstRelaySocket = firstActiveSockets[0];
      const firstOutputBaseline = firstRelaySocket.receivedFrames.length;
      const shellMarkerPath = path.join(remoteRoot, keyboardInteractiveShellMarker);
      safeRunStage = 'keyboard-interactive authenticated shell marker';
      await sendCommandToActiveTerminal(page, user, address,
        `printf '%s\\n' '${keyboardInteractiveShellMarker}' > /tmp/remote/${keyboardInteractiveShellMarker}; printf '%s\\n' '${keyboardInteractiveShellMarker}'`,
        { activeHostName: kbdHostName });
      assertThat(await waitForRemoteMarker(shellMarkerPath,
        keyboardInteractiveShellMarker, 20000),
      'keyboard-interactive login did not execute a command inside the SSH fixture chroot');
      assertThat(await waitForRelayOutputFrame(page, firstRelaySocket,
        firstOutputBaseline, 20000),
      'keyboard-interactive shell command produced no Relay output frame');
      const firstSshd = sshdRuntimeSummary(path.join(tempRoot, 'kbdint-only-sshd.log'));
      assertThat(firstSshd.sessionStarts >= 1,
        'keyboard-interactive-only SSHD did not start an authenticated shell session');

      safeRunStage = 'keyboard-interactive cancellation challenge';
      await expectChallengeForHost({
        hostName: cancelHostName,
        port: secondBastionPort,
        fingerprint: sshKeyFingerprint(keyboardInteractiveCancelHostKey),
      });
      safeRunStage = 'keyboard-interactive challenge cancellation';
      await click(page, 'Cancel');
      await page.waitForTimeout(1500);
      assertThat(await page.getByText('SSH authentication challenge', {
        exact: true,
      }).count() === 0,
      'cancelled keyboard-interactive challenge remained visible');
      const cancelLogPath = path.join(tempRoot, 'kbdint-password-sshd.log');
      const cancelLog = fs.readFileSync(cancelLogPath, 'utf8');
      const authMethods = [...cancelLog.matchAll(
        /userauth-request for user .* method ([a-z0-9-]+)/gi,
      )].map((match) => match[1].toLowerCase());
      const firstKbdintMethod = authMethods.indexOf('keyboard-interactive');
      const postChallengePasswordAttempts = firstKbdintMethod < 0
        ? -1
        : authMethods.slice(firstKbdintMethod + 1)
          .filter((method) => method === 'password').length;
      const cancelSshd = sshdRuntimeSummary(cancelLogPath);
      assertThat(firstKbdintMethod >= 0 && postChallengePasswordAttempts === 0,
        'cancelled keyboard-interactive auth fell through to the configured password factor');
      assertThat(cancelSshd.sessionStarts === 0,
        'cancelled keyboard-interactive authentication unexpectedly started an SSH session');
      const finalOpenSockets = relaySocketsForPage(page).filter((socket) =>
        socket.opened && !socket.closed);
      assertThat(finalOpenSockets.length === 1 &&
        finalOpenSockets[0] === firstRelaySocket && !firstRelaySocket.closed,
      'cancelling the second Host closed or duplicated the first authenticated Relay session');
      assertThat(relayTicketChecksForPage(page).every(Boolean),
        'one or more keyboard-interactive Relay tickets escaped the fixture allowlist');

      safeRunStage = 'keyboard-interactive response privacy audit';
      const sensitiveMarkers = [
        keyboardInteractiveCode,
        keyboardInteractiveOtp,
        keyboardInteractiveUnusedPassword,
      ];
      const browserStorageAudit = await browserStorageContainsMarkers(page, sensitiveMarkers);
      assertThat(browserStorageAudit.complete && browserStorageAudit.found.length === 0,
        'keyboard-interactive answers appeared in browser storage');
      assertThat(secretSyncPrivacy.checks.length > 0 &&
        secretSyncPrivacy.checks.every((check) => check.markerAbsent),
      'keyboard-interactive answers appeared in a Vault sync request or response');
      assertThat(!fileTreeContainsMarkers([
        dataDir,
        serverLogPath,
        path.join(tempRoot, 'kbdint-only-sshd.log'),
        cancelLogPath,
      ], [...sensitiveMarkers, keyboardInteractiveShellMarker]),
      'keyboard-interactive answer or shell canary appeared in server/database/SSHD files');
      const answerValuesRemainInPage = await page.evaluate((needles) => {
        const body = document.body?.innerText || '';
        const inputValues = [...document.querySelectorAll('input,textarea')]
          .map((element) => element.value || '').join('\\n');
        return needles.some((needle) => body.includes(needle) || inputValues.includes(needle));
      }, sensitiveMarkers);
      assertThat(!answerValuesRemainInPage,
        'keyboard-interactive answer remained in the Web page after submit/cancel');
      console.log('keyboard-interactive browser acceptance evidence', JSON.stringify({
        hostContextChecks: 2,
        exactHostKeyFingerprintChecks: 2,
        echoOnVisible: echoInputTypes[0] !== 'password',
        echoOffMasked: echoInputTypes[1] === 'password',
        successfulShellSessions: firstSshd.sessionStarts,
        cancelledSessions: cancelSshd.sessionStarts,
        postChallengePasswordAttempts,
        activeRelaySocketsAfterCancel: finalOpenSockets.length,
        relayTicketsAllowed: relayTicketChecksForPage(page).length,
        syncPrivacyChecks: secretSyncPrivacy.checks.length,
        indexedDbNamesScanned: browserStorageAudit.indexedDbNames,
        indexedDbRecordsScanned: browserStorageAudit.scannedRecords,
        answerMarkersAbsentFromStorageSyncDbAndLogs: true,
      }));
      assertThat(pageErrors.length === 0,
        'keyboard-interactive Web journey recorded browser page errors');
      console.log('WEB-RELAY-KBDINT-01 passed: real two-round OpenSSH/PAM authentication, Web echo masking, Host context, shell command, cancellation without password fallback, and answer privacy verified.');
      return;
    }
    jumpPrivateKey = fs.readFileSync(jumpUserKey.privateKey, 'utf8').replace(/[\r\n]+$/, '');
    let bastionCredentialId;
    try {
      bastionCredentialId = await savePrivateKeyCredential(page, {
        name: bastionCredentialName,
        username: user,
        keyPath: jumpUserKey.privateKey,
      });
    } finally {
      jumpPrivateKey = undefined;
    }
    expectedPrivateKey = fs.readFileSync(userKey.privateKey, 'utf8').replace(/[\r\n]+$/, '');
    let credentialId;
    try {
    credentialId = await savePrivateKeyCredential(page, {
      name: credentialName,
      username: user,
      keyPath: userKey.privateKey,
    });
    } finally {
      expectedPrivateKey = undefined;
    }
    let secondBastionCredentialId;
    let thirdBastionCredentialId;
    let fourthBastionCredentialId;
    const maxDepthBastionCredentialIds = [];
    let multiHopTargetCredentialId;
    if (!focusedOneHopOnly) {
      secondJumpPrivateKey = fs.readFileSync(secondJumpUserKey.privateKey, 'utf8').replace(/[\r\n]+$/, '');
      try {
      secondBastionCredentialId = await savePrivateKeyCredential(page, {
        name: secondBastionCredentialName,
        username: user,
        keyPath: secondJumpUserKey.privateKey,
        verifyDecryptedRoundTrip: !maxDepthHopOnly,
      });
      } finally {
        secondJumpPrivateKey = undefined;
      }
      if (deepHopOnly) {
        thirdJumpPrivateKey = fs.readFileSync(
          thirdJumpUserKey.privateKey,
          'utf8',
        ).replace(/[\r\n]+$/, '');
        try {
          thirdBastionCredentialId = await savePrivateKeyCredential(page, {
            name: thirdBastionCredentialName,
            username: user,
            keyPath: thirdJumpUserKey.privateKey,
            verifyDecryptedRoundTrip: !maxDepthHopOnly,
          });
        } finally {
          thirdJumpPrivateKey = undefined;
        }
      }
      if (extendedHopOnly) {
        fourthJumpPrivateKey = fs.readFileSync(
          fourthJumpUserKey.privateKey,
          'utf8',
        ).replace(/[\r\n]+$/, '');
        try {
          fourthBastionCredentialId = await savePrivateKeyCredential(page, {
            name: fourthBastionCredentialName,
            username: user,
            keyPath: fourthJumpUserKey.privateKey,
            verifyDecryptedRoundTrip: !maxDepthHopOnly,
          });
        } finally {
          fourthJumpPrivateKey = undefined;
        }
      }
      if (maxDepthHopOnly) {
        for (let index = 0; index < maxDepthJumpUserKeys.length; index++) {
          const keyPath = maxDepthJumpUserKeys[index].privateKey;
          maxDepthJumpPrivateKeys.push(
            fs.readFileSync(keyPath, 'utf8').replace(/[\r\n]+$/, ''),
          );
          const credentialId = await savePrivateKeyCredential(page, {
            name: maxDepthBastionCredentialNames[index],
            username: user,
            keyPath,
            verifyDecryptedRoundTrip: false,
          });
          maxDepthBastionCredentialIds.push(credentialId);
        }
      }
      multiHopTargetPrivateKey = fs.readFileSync(
        multiHopTargetUserKey.privateKey,
        'utf8',
      ).replace(/[\r\n]+$/, '');
      try {
        multiHopTargetCredentialId = await savePrivateKeyCredential(page, {
          name: multiHopTargetCredentialName,
          username: user,
          keyPath: multiHopTargetUserKey.privateKey,
        });
      } finally {
        multiHopTargetPrivateKey = undefined;
      }
      await savePasswordCredential(page, {
        name: snippetCredentialName,
        username: user,
        secret: snippetCredentialSecret,
      });
    }
    console.log(focusedOneHopOnly
      ? 'stage: encrypted one-hop bastion and target credentials saved'
      : 'stage: distinct encrypted bastion and target credentials saved');

    const bastionHostCard = await createSshHost(page, {
      name: bastionHostName,
      address,
      port: bastionPort,
      username: user,
      credentialName: bastionCredentialName,
      credentialId: bastionCredentialId,
      verifySavedCredentialOverride: true,
      verifySavedCredentialAfterSave: true,
    });
    const bastionHostIdentifier = await sshHostRecordIdentifier(bastionHostCard);
    const jumpHostChoice = `${bastionHostName} · ${address}:${bastionPort}`;
    const hostCard = await createSshHost(page, {
      name: hostName,
      address: targetAddress,
      port: sshPort,
      username: user,
      credentialName,
      credentialId,
      jumpHostChoice,
      jumpHostIdentifier: bastionHostIdentifier,
      knownJumpHostNames: [bastionHostName],
      verifySavedCredentialOverride: true,
      verifySavedCredentialAfterSave: true,
    });
    let secondBastionHostCard = null;
    let multiHopHostCard = null;
    let thirdBastionHostCard = null;
    let threeHopHostCard = null;
    let fourthBastionHostCard = null;
    let fourHopHostCard = null;
    const maxDepthBastionHostCards = [];
    if (!focusedOneHopOnly) {
      secondBastionHostCard = await createSshHost(page, {
        name: secondBastionHostName,
        address,
        port: secondBastionPort,
        username: user,
        credentialName: secondBastionCredentialName,
        credentialId: secondBastionCredentialId,
        jumpHostChoice,
        jumpHostIdentifier: bastionHostIdentifier,
        knownJumpHostNames: [bastionHostName],
        verifySavedCredentialOverride: true,
        verifySavedCredentialAfterSave: true,
      });
      const secondBastionHostIdentifier = await sshHostRecordIdentifier(secondBastionHostCard);
      const secondJumpHostChoice = `${secondBastionHostName} · ${address}:${secondBastionPort}`;
      multiHopHostCard = await createSshHost(page, {
        name: multiHopHostName,
        address: targetAddress,
        port: multiHopTargetPort,
        username: user,
        credentialName: multiHopTargetCredentialName,
        credentialId: multiHopTargetCredentialId,
        jumpHostChoice: secondJumpHostChoice,
        jumpHostIdentifier: secondBastionHostIdentifier,
        knownJumpHostNames: [bastionHostName, secondBastionHostName],
        verifySavedCredentialOverride: true,
        verifySavedCredentialAfterSave: true,
      });
      if (deepHopOnly) {
        thirdBastionHostCard = await createSshHost(page, {
          name: thirdBastionHostName,
          address,
          port: thirdBastionPort,
          username: user,
          credentialName: thirdBastionCredentialName,
          credentialId: thirdBastionCredentialId,
          jumpHostChoice: secondJumpHostChoice,
          jumpHostIdentifier: secondBastionHostIdentifier,
          knownJumpHostNames: [bastionHostName, secondBastionHostName],
          verifySavedCredentialOverride: true,
          verifySavedCredentialAfterSave: true,
        });
        const thirdBastionHostIdentifier = await sshHostRecordIdentifier(thirdBastionHostCard);
        const thirdJumpHostChoice = `${thirdBastionHostName} · ${address}:${thirdBastionPort}`;
        if (threeHopOnly) {
          threeHopHostCard = await createSshHost(page, {
            name: threeHopHostName,
            address: targetAddress,
            port: multiHopTargetPort,
            username: user,
            credentialName: multiHopTargetCredentialName,
            credentialId: multiHopTargetCredentialId,
            jumpHostChoice: thirdJumpHostChoice,
            jumpHostIdentifier: thirdBastionHostIdentifier,
            knownJumpHostNames: [bastionHostName, secondBastionHostName,
              thirdBastionHostName],
            verifySavedCredentialOverride: true,
            verifySavedCredentialAfterSave: true,
          });
        }
        let fourthJumpHostChoice = null;
        if (extendedHopOnly) {
          fourthBastionHostCard = await createSshHost(page, {
            name: fourthBastionHostName,
            address,
            port: fourthBastionPort,
            username: user,
            credentialName: fourthBastionCredentialName,
            credentialId: fourthBastionCredentialId,
            jumpHostChoice: thirdJumpHostChoice,
            jumpHostIdentifier: thirdBastionHostIdentifier,
            knownJumpHostNames: [bastionHostName, secondBastionHostName,
              thirdBastionHostName],
            verifySavedCredentialOverride: true,
            verifySavedCredentialAfterSave: true,
          });
          const fourthBastionHostIdentifier = await sshHostRecordIdentifier(fourthBastionHostCard);
          fourthJumpHostChoice = `${fourthBastionHostName} · ${address}:${fourthBastionPort}`;
          if (fourHopOnly) {
          fourHopHostCard = await createSshHost(page, {
            name: fourHopHostName,
            address: targetAddress,
            port: multiHopTargetPort,
            username: user,
            credentialName: multiHopTargetCredentialName,
            credentialId: multiHopTargetCredentialId,
            jumpHostChoice: fourthJumpHostChoice,
            jumpHostIdentifier: fourthBastionHostIdentifier,
            verifySavedCredentialOverride: true,
          });
          }
        }
        if (maxDepthHopOnly) {
          let previousHostChoice = fourthJumpHostChoice;
          let previousHostIdentifier = await sshHostRecordIdentifier(fourthBastionHostCard);
          for (let index = 0; index < maxDepthBastionNames.length; index++) {
            const hostCard = await createSshHost(page, {
              name: maxDepthBastionHostNames[index],
              address,
              port: maxDepthBastionPorts[index],
              username: user,
              credentialName: maxDepthBastionCredentialNames[index],
              credentialId: maxDepthBastionCredentialIds[index],
              jumpHostChoice: previousHostChoice,
              jumpHostIdentifier: previousHostIdentifier,
              knownJumpHostNames: [bastionHostName, secondBastionHostName,
                thirdBastionHostName, fourthBastionHostName,
                ...maxDepthBastionHostNames.slice(0, index)],
              verifySavedCredentialOverride: true,
              verifySavedCredentialAfterSave: true,
            });
            maxDepthBastionHostCards.push(hostCard);
            previousHostIdentifier = await sshHostRecordIdentifier(hostCard);
            previousHostChoice = `${maxDepthBastionHostNames[index]} · ${address}:${maxDepthBastionPorts[index]}`;
          }
          await createSshHost(page, {
            name: maxDepthHostName,
            address: targetAddress,
            port: multiHopTargetPort,
            username: user,
            credentialName: multiHopTargetCredentialName,
            credentialId: multiHopTargetCredentialId,
            jumpHostChoice: previousHostChoice,
            jumpHostIdentifier: previousHostIdentifier,
            knownJumpHostNames: [bastionHostName, secondBastionHostName,
              thirdBastionHostName, fourthBastionHostName,
                ...maxDepthBastionHostNames],
            verifySavedCredentialOverride: true,
            verifySavedCredentialAfterSave: true,
          });
        }
      }
    }

    const verifyWebPortForwardDialog = async (targetPage, actor, alreadyOpen = false) => {
      safeRunStage = `${actor} opens SSH port forwarding profile manager`;
      if (!alreadyOpen) await click(targetPage, 'SSH port forwarding');
      safeRunStage = `${actor} forwarding profile manager title is visible`;
      await waitForVisibleSemanticsText(targetPage, 'SSH port forwarding');
      safeRunStage = `${actor} forwarding manager explains that Web cannot open TCP listeners`;
      const unsupportedRuntimeCopy =
        'This browser cannot open the local TCP listeners required to run port forwarding.';
      await waitForVisibleSemanticsText(targetPage, unsupportedRuntimeCopy);
      safeRunStage = `${actor} forwarding profile displays unavailable Web runtime state`;
      await waitForVisibleSemanticsText(targetPage, 'Unavailable in Web');
      const profileDescription =
        `Dynamic SOCKS5 · 127.0.0.1:${portForwardBindPort}`;
      const visibleTextPattern = (value) => new RegExp(
        value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
      safeRunStage = `${actor} sees the synchronized forwarding profile name`;
      await waitForVisibleSemanticsPattern(targetPage,
        visibleTextPattern(portForwardProfileName));
      safeRunStage = `${actor} sees the synchronized dynamic profile description`;
      await waitForVisibleSemanticsPattern(targetPage,
        visibleTextPattern(profileDescription));
      const safeDialogEvidence = {
        managerTitleVisible: await visibleSemanticsContainsText(
          targetPage, 'SSH port forwarding'),
        browserRuntimeUnavailableCopyVisible: await visibleSemanticsContainsText(
          targetPage, unsupportedRuntimeCopy),
        profileUnavailableLabelVisible: await visibleSemanticsContainsText(
          targetPage, 'Unavailable in Web'),
        profileNameVisible: await visibleSemanticsMatchesPattern(
          targetPage, visibleTextPattern(portForwardProfileName)),
        profileDescriptionVisible: await visibleSemanticsMatchesPattern(
          targetPage, visibleTextPattern(profileDescription)),
        emptyProfileStateVisible: await visibleSemanticsContainsText(
          targetPage, 'No forwarding profiles saved for this Host.'),
        editorVisible: await visibleSemanticsContainsText(
          targetPage, 'Add forwarding profile'),
        saveErrorVisible: await visibleSemanticsMatchesPattern(targetPage,
          /Could not save forwarding settings|Host is no longer available|A Host can have at most/),
      };
      assertThat(safeDialogEvidence.managerTitleVisible &&
        safeDialogEvidence.browserRuntimeUnavailableCopyVisible &&
        safeDialogEvidence.profileUnavailableLabelVisible &&
        safeDialogEvidence.profileNameVisible &&
        safeDialogEvidence.profileDescriptionVisible &&
        !safeDialogEvidence.emptyProfileStateVisible &&
        !safeDialogEvidence.editorVisible &&
        !safeDialogEvidence.saveErrorVisible,
      `${actor} Web manager DOM evidence did not match the visible unsupported-profile state`);
      console.log(`${actor} forwarding manager visible DOM evidence`,
        JSON.stringify(safeDialogEvidence));
      const startActions = targetPage.getByRole('button', {
        name: /Start forwarding|Stop forwarding/i,
      });
      const startActionCount = await startActions.count().catch(() => -1);
      assertThat(startActionCount === 0,
        `${actor} exposed a forwarding start/stop action in Web`);
      return {
        ...safeDialogEvidence,
        startActionCount,
      };
    };

    // Each endpoint in a new route setup first aborts once for its scoped
    // KnownHost decision. A control-plane/Vault refresh may invalidate an
    // earlier route proof, so allow additional bounded revalidation attempts.
    const relayAttemptsForSuccessfulRoute = (endpointCount) => endpointCount + 1;
    const maxRelayAttemptsForRoute = (endpointCount) => (endpointCount * 2) + 1;
    const relayAttemptCountIsBounded = (count, minimum, endpointCount) =>
      count >= minimum && count <= maxRelayAttemptsForRoute(endpointCount);
    const oneJumpRouteRelayAttempts = relayAttemptsForSuccessfulRoute(2);
    const aToBToTargetRelayAttempts = relayAttemptsForSuccessfulRoute(3);
    const relayAttemptsThroughRejectedHop = (authenticatedEarlierHopCount) =>
      authenticatedEarlierHopCount + 1;

    const runFocusedTwoHopSftpAcceptance = async ({
      routePage,
      browserContext,
      relaySocket,
      ticketBaseline,
      socketBaseline,
      otherPageSnapshot,
    }) => {
      const routeTicketChecks = relayTicketChecksForPage(routePage);
      const routeSockets = relaySocketsForPage(routePage);
      const expectedRelayAttemptCount =
        routeTicketChecks.length - ticketBaseline;
      assertThat(relayAttemptCountIsBounded(
        expectedRelayAttemptCount,
        aToBToTargetRelayAttempts,
        3,
      ), 'two-hop SFTP started without a successful route inside the SSH retry budget');
      safeRunStage = 'two-hop SFTP subsystem and remote folder creation';
      const multiHopSftpFolder =
        `WEB_RELAY_MULTIHOP_SFTP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const multiHopSftpRoot = path.join(multiHopRemoteRoot, multiHopSftpFolder);
      const multiHopBinaryName = `payload-${RUN_ID.slice(0, 8)}.bin`;
      const multiHopTextName = `source-${RUN_ID.slice(0, 8)}.txt`;
      const multiHopRenamedTextName = `renamed-${RUN_ID.slice(0, 8)}.txt`;
      const multiHopBinaryPath = path.join(multiHopSftpRoot, multiHopBinaryName);
      const multiHopTextPath = path.join(multiHopSftpRoot, multiHopTextName);
      const multiHopRenamedTextPath = path.join(multiHopSftpRoot, multiHopRenamedTextName);
      const multiHopBinaryPayload = crypto.randomBytes(263);
      const multiHopTextPayload = Buffer.from(
        `A→B→Target UTF-8 fixture ${RUN_ID}: café — 東京\n`, 'utf8',
      );
      const multiHopSftpTargetLog = path.join(tempRoot, 'sshd-multihop-target.log');
      const multiHopSftpBefore = sshdRuntimeSummary(multiHopSftpTargetLog);
      const multiHopRelayFramesBefore = safeRelayFrameCounts(relaySocket);
      const assertMultiHopRelayStable = (operation) => {
        const routeTicketAttempts = routeTicketChecks.slice(ticketBaseline);
        assertThat(routeTicketAttempts.length === expectedRelayAttemptCount &&
          routeTicketAttempts.every(Boolean),
        `two-hop SFTP ${operation} added or retargeted a Relay ticket`);
        assertThat(routeSockets.length === socketBaseline + expectedRelayAttemptCount &&
          routeSockets.at(-1) === relaySocket && relaySocket.opened && !relaySocket.closed,
        `two-hop SFTP ${operation} replaced or closed its Relay WebSocket`);
        assertRelayPageUnchanged(otherPageSnapshot,
          `two-hop SFTP ${operation}`);
      };
      await click(routePage, 'SFTP');
      await waitText(routePage, 'SFTP file browser', 15000);
      await click(routePage, 'Go to path');
      await waitText(routePage, 'Go to remote path', 15000);
      await fill(routePage, 'Remote path', '/tmp/remote');
      await click(routePage, 'Go');
      await click(routePage, 'New folder');
      await waitText(routePage, 'Create remote folder', 15000);
      await fill(routePage, 'Folder name', multiHopSftpFolder);
      const createMultiHopSftpFolder = routePage.getByRole('button', {
        name: 'Create', exact: true,
      }).last();
      await createMultiHopSftpFolder.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(await createMultiHopSftpFolder.isEnabled(),
        'two-hop SFTP did not enable remote folder creation');
      await createMultiHopSftpFolder.click();
      await waitForFilesystemState(multiHopSftpRoot, true, 10000);
      assertMultiHopRelayStable('folder creation');
      await click(routePage, 'Go to path');
      await waitText(routePage, 'Go to remote path', 15000);
      await fill(routePage, 'Remote path', `/tmp/remote/${multiHopSftpFolder}`);
      await click(routePage, 'Go');

      const uploadMultiHopFixture = async (name, mimeType, payload, remotePath) => {
        const chooserPromise = routePage.waitForEvent('filechooser', { timeout: 15000 });
        await click(routePage, 'Upload');
        const chooser = await chooserPromise;
        await chooser.setFiles({ name, mimeType, buffer: payload });
        await waitForFilesystemState(remotePath, true, 30000);
        const uploadedPayload = fs.readFileSync(remotePath);
        let uploadedBytesMatch;
        try {
          uploadedBytesMatch = uploadedPayload.equals(payload);
        } finally {
          uploadedPayload.fill(0);
        }
        assertThat(uploadedBytesMatch,
          `two-hop SFTP upload bytes did not match fixture ${name}`);
        assertMultiHopRelayStable(`upload ${name}`);
      };

      const deleteMultiHopRemoteFile = async (name, remotePath) => {
        await clickSftpEntryAction(routePage, name, 'Delete');
        await waitText(routePage, 'Delete this item?', 15000);
        const confirmDelete = routePage.getByRole('button', {
          name: 'Delete', exact: true,
        }).last();
        await confirmDelete.waitFor({ state: 'visible', timeout: 15000 });
        await confirmDelete.click();
        await waitForFilesystemState(remotePath, false, 15000);
        assertMultiHopRelayStable(`delete ${name}`);
      };

      safeRunStage = 'two-hop SFTP binary and UTF-8 uploads';
      try {
        await uploadMultiHopFixture(
          multiHopBinaryName, 'application/octet-stream',
          multiHopBinaryPayload, multiHopBinaryPath,
        );
        await uploadMultiHopFixture(
          multiHopTextName, 'text/plain', multiHopTextPayload, multiHopTextPath,
        );
        console.log('stage: two-hop SFTP uploads matched isolated loopback Target bytes',
          JSON.stringify({ binaryUploadBytesMatch: true,
            binaryBytes: multiHopBinaryPayload.length, utf8UploadBytesMatch: true,
            utf8Bytes: multiHopTextPayload.length }));

        safeRunStage = 'two-hop SFTP browser download byte comparison';
        const downloadPromise = waitForBrowserDownload(browserContext, routePage, 30000);
        await clickSftpEntryAction(routePage, multiHopBinaryName, 'Download');
        const download = await downloadPromise;
        assertThat(download.suggestedFilename() === multiHopBinaryName,
          'two-hop SFTP download filename did not match uploaded fixture');
        const downloadedPath = path.join(tempRoot, `multihop-${RUN_ID.slice(0, 8)}.bin`);
        await download.saveAs(downloadedPath);
        const downloadedPayload = fs.readFileSync(downloadedPath);
        let downloadedBytesMatch;
        try {
          downloadedBytesMatch = downloadedPayload.equals(multiHopBinaryPayload);
        } finally {
          downloadedPayload.fill(0);
          fs.rmSync(downloadedPath, { force: true });
        }
        assertThat(downloadedBytesMatch,
          'two-hop SFTP download bytes did not exactly match uploaded fixture');
        assertMultiHopRelayStable('download');
        console.log('stage: two-hop SFTP browser download matched uploaded bytes',
          JSON.stringify({ downloadBytesMatch: true, bytes: multiHopBinaryPayload.length }));

        safeRunStage = 'two-hop SFTP UI rename workflow';
        assertThat(!fs.existsSync(multiHopRenamedTextPath),
          'two-hop SFTP rename target unexpectedly existed before Save as');
        await openSftpEntryAction(routePage, multiHopTextName, 'Edit text');
        const multiHopEditorTitle = routePage.getByText(
          'Edit remote text file', { exact: true },
        ).last();
        const multiHopEditor = routePage.locator(
          'textarea[aria-label="Remote file contents"]',
        ).last();
        await multiHopEditorTitle.waitFor({ state: 'visible', timeout: 15000 });
        await multiHopEditor.waitFor({ state: 'visible', timeout: 15000 });
        assertThat(await multiHopEditor.inputValue() === multiHopTextPayload.toString('utf8'),
          'two-hop SFTP editor did not load the uploaded UTF-8 bytes');
        await click(routePage, 'Save as');
        await routePage.getByText('Save remote file as', { exact: true }).last()
          .waitFor({ state: 'visible', timeout: 15000 });
        await fill(routePage, 'File name', multiHopRenamedTextName);
        const renameSaveButton = routePage.getByRole('button', {
          name: 'Save as', exact: true,
        }).last();
        await renameSaveButton.waitFor({ state: 'visible', timeout: 15000 });
        await renameSaveButton.click();
        await waitForFixtureFileBytes(multiHopRenamedTextPath, multiHopTextPayload);
        await multiHopEditorTitle.waitFor({ state: 'hidden', timeout: 15000 });
        await waitForSemanticText(routePage, multiHopRenamedTextName);
        assertThat(await fixtureFileMatches(multiHopTextPath, multiHopTextPayload),
          'two-hop SFTP Save as changed the source before deletion');
        assertThat(await fixtureFileMatches(multiHopRenamedTextPath, multiHopTextPayload),
          'two-hop SFTP Save as did not preserve exact UTF-8 bytes');
        assertMultiHopRelayStable('Save as rename');
        await deleteMultiHopRemoteFile(multiHopTextName, multiHopTextPath);
        assertThat(!fs.existsSync(multiHopTextPath) &&
          await fixtureFileMatches(multiHopRenamedTextPath, multiHopTextPayload),
        'two-hop SFTP Save as did not leave only the exact renamed file');
        console.log('stage: two-hop SFTP Save as rename preserved bytes and removed the source',
          JSON.stringify({ renamedBySaveAsAndDelete: true, atomicSshFxpRenameClaimed: false,
            renamedBytesMatch: true, sourceDeleted: true }));

        safeRunStage = 'two-hop SFTP remote file deletion';
        await deleteMultiHopRemoteFile(multiHopBinaryName, multiHopBinaryPath);
        assertThat(!fs.existsSync(multiHopBinaryPath),
          'two-hop SFTP Delete left the uploaded binary fixture on Target');
        assertMultiHopRelayStable('completed file operations');
      } finally {
        multiHopBinaryPayload.fill(0);
        multiHopTextPayload.fill(0);
      }

      const multiHopSftpAfter = sshdRuntimeSummary(multiHopSftpTargetLog);
      const multiHopSftpDelta = sshdDiagnosticDelta(multiHopSftpBefore, multiHopSftpAfter);
      assertThat(multiHopSftpDelta.sftpSubsystemRequests > 0 &&
        multiHopSftpDelta.sftpSubsystemStarts > 0,
      'two-hop SFTP file operations did not start a subsystem on loopback Target');
      const multiHopRelayFramesAfter = safeRelayFrameCounts(relaySocket);
      assertThat(multiHopRelayFramesAfter.sent.total > multiHopRelayFramesBefore.sent.total &&
        multiHopRelayFramesAfter.received.total > multiHopRelayFramesBefore.received.total,
      'two-hop SFTP operations did not exchange frames on the existing Relay WebSocket');
      assertMultiHopRelayStable('complete operation set');
      await click(routePage, 'Terminal');
      await waitText(routePage, 'CONNECTED', 15000);
      await terminalTabButton(routePage, multiHopHostName, 'active');
      console.log('stage: two-hop SFTP upload, exact-byte download, Save as rename, and delete passed over the existing Relay route',
        JSON.stringify({ targetFolderCreated: true, binaryUploadBytesMatch: true,
          downloadBytesMatch: true, renamedBySaveAsAndDelete: true,
          atomicSshFxpRenameClaimed: false, sourceDeleted: true, binaryDeleted: true,
          sftpSubsystemRequests: multiHopSftpDelta.sftpSubsystemRequests,
          sftpSubsystemStarts: multiHopSftpDelta.sftpSubsystemStarts,
          relaySentFrameDelta: multiHopRelayFramesAfter.sent.total -
            multiHopRelayFramesBefore.sent.total,
          relayReceivedFrameDelta: multiHopRelayFramesAfter.received.total -
            multiHopRelayFramesBefore.received.total,
          relayTicketAttempts: expectedRelayAttemptCount,
          relaySocketAttempts: expectedRelayAttemptCount,
          activeRelaySockets: 1, sshRelayRemainedOpen: true }));
    };

    const runFocusedMultiHopAcceptance = async (routePage, routeHostCard) => {
      safeRunStage = 'focused two-hop route preflight';
      const routeTicketChecks = relayTicketChecksForPage(routePage);
      const routeSockets = relaySocketsForPage(routePage);
      const ticketBaseline = routeTicketChecks.length;
      const socketBaseline = routeSockets.length;
      const otherPage = routePage === page ? secondPage : page;
      const otherPageSnapshot = snapshotRelayPage(otherPage);
      assertThat(otherPageSnapshot.openSockets.length > 0,
        'focused two-hop route requires an independent active Relay socket on the other profile');
      const aBefore = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const bBefore = sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log'));
      const targetBefore = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-multihop-target.log'),
      );
      safeRunStage = 'focused two-hop route Connect action';
      await routeHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
      let trustSignal = null;
      let trustPrompts = 0;
      while (trustPrompts < 3) {
        safeRunStage = 'focused two-hop route wait for SSH trust or terminal state';
        trustSignal = await waitForSshTrustOrError(routePage, 60000, multiHopHostName);
        console.log('focused two-hop route progress safe evidence', JSON.stringify({
          trustPrompts,
          trustSignal,
          relayTicketDelta: routeTicketChecks.length - ticketBaseline,
          relaySocketDelta: routeSockets.length - socketBaseline,
        }));
        if (trustSignal !== 'host_key_prompt') break;
        const promptToken = await sshTrustPromptToken(routePage);
        safeRunStage = 'focused two-hop route accept verified SSH host key';
        await click(routePage, 'Trust after verification');
        trustPrompts += 1;
        safeRunStage = 'focused two-hop route wait for SSH trust prompt transition';
        await waitForSshTrustPromptAdvance(routePage, promptToken, 60000);
      }
      const aAtTrustDecision = sshdDiagnosticDelta(aBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')));
      const bAtTrustDecision = sshdDiagnosticDelta(bBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log')));
      const targetAtTrustDecision = sshdDiagnosticDelta(targetBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'sshd-multihop-target.log')));
      console.log('focused two-hop trust decision safe evidence', JSON.stringify({
        trustPrompts,
        trustSignal,
        relayTicketDelta: routeTicketChecks.length - ticketBaseline,
        relayTicketLatestAllowlisted: routeTicketChecks.at(-1) ?? null,
        relaySocketDelta: routeSockets.length - socketBaseline,
        hopAuthenticationDeltas: {
          bastionA: aAtTrustDecision,
          bastionB: bAtTrustDecision,
          target: targetAtTrustDecision,
        },
      }));
      safeRunStage = 'focused two-hop trust prompt count assertion';
      assertThat(trustPrompts === 2,
        `two-hop route should first trust Bastion B and Target (${trustPrompts})`);
      safeRunStage = 'focused two-hop route connection state assertion';
      assertThat(trustSignal === 'terminal_connected' ||
        trustSignal === 'deadline_without_visible_signal',
        `two-hop route did not reach connected state (${trustSignal})`);
      safeRunStage = 'focused two-hop route wait for CONNECTED';
      await waitText(routePage, 'CONNECTED', 45000);
      safeRunStage = 'focused two-hop route select active terminal tab';
      await terminalTabButton(routePage, multiHopHostName, 'active');
      safeRunStage = 'focused two-hop Relay ticket validation';
      const routeTicketAttempts = routeTicketChecks.slice(ticketBaseline);
      assertThat(relayAttemptCountIsBounded(
        routeTicketAttempts.length,
        aToBToTargetRelayAttempts,
        3,
      ) &&
        routeTicketAttempts.every(Boolean),
      'focused A -> B -> Target route did not keep every Relay ticket on Bastion A');
      safeRunStage = 'focused two-hop Relay WebSocket validation';
      assertThat(routeSockets.length === socketBaseline + routeTicketAttempts.length &&
        routeSockets.at(-1)?.opened && !routeSockets.at(-1)?.closed,
      'focused A -> B -> Target route did not leave its final Relay WebSocket active');
      assertRelayPageUnchanged(otherPageSnapshot,
        'focused A -> B -> Target connection');
      const aAfter = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const bAfter = sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log'));
      const targetAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-multihop-target.log'),
      );
      safeRunStage = 'focused two-hop independent hop credential validation';
      assertThat(sshdDiagnosticDelta(aBefore, aAfter).publicKeyAccepted > 0 &&
        sshdDiagnosticDelta(bBefore, bAfter).publicKeyAccepted > 0 &&
        sshdDiagnosticDelta(targetBefore, targetAfter).publicKeyAccepted > 0,
      'Bastion A, Bastion B, and Target did not accept their distinct synced credentials');

      safeRunStage = 'focused two-hop shell marker and Relay frame IO';
      const marker = `WEB_RELAY_MULTIHOP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const markerPath = path.join(multiHopRemoteRoot, marker);
      await sendCommandToActiveTerminal(routePage, user, targetAddress,
        `printf '%s\\n' '${marker}' > /tmp/remote/${marker}`, {
          activeHostName: multiHopHostName,
        });
      assertThat(await waitForRemoteMarker(markerPath, marker, 20000),
        'focused two-hop shell did not execute on the isolated loopback Target');
      const relaySocket = routeSockets.at(-1);
      const frameDeadline = Date.now() + 10000;
      while (Date.now() < frameDeadline &&
          (!relaySocket.sentFrames.length || !relaySocket.receivedFrames.length)) {
        await routePage.waitForTimeout(100);
      }
      assertThat(relaySocket.sentFrames.length > 0 && relaySocket.receivedFrames.length > 0,
        'focused two-hop terminal did not exchange Relay WebSocket frames');

      await runFocusedTwoHopSftpAcceptance({
        routePage,
        browserContext: secondContext,
        relaySocket,
        ticketBaseline,
        socketBaseline,
        otherPageSnapshot,
      });

      safeRunStage = 'focused two-hop Relay disconnect';
      await click(routePage, 'Disconnect');
      await waitText(routePage, 'SSH terminal · disconnected', 15000);
      const closeDeadline = Date.now() + 5000;
      while (Date.now() < closeDeadline && !relaySocket.closed) {
        await routePage.waitForTimeout(100);
      }
      assertThat(relaySocket.closed,
        'focused two-hop disconnect did not close its Relay WebSocket');
      assertRelayPageUnchanged(otherPageSnapshot,
        'focused two-hop disconnect');

      const logPaths = {
        bastionA: path.join(tempRoot, 'jump-sshd.log'),
        bastionB: path.join(tempRoot, 'second-jump-sshd.log'),
        target: path.join(tempRoot, 'sshd-multihop-target.log'),
      };
      const readAuth = () => Object.fromEntries(Object.entries(logPaths)
        .map(([hop, logPath]) => [hop, sshdRuntimeSummary(logPath)]));
      const launchChangedSshd = async ({ changedKeyPath, originalKeyPath,
        bindAddress, port, authorizedKeys, root, instance, logLabel, configName,
        permitOpen }) => {
        run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedKeyPath], {
          timeout: 30000,
        });
        fs.chmodSync(changedKeyPath, 0o600);
        assertThat(fs.readFileSync(`${changedKeyPath}.pub`, 'utf8').trim() !==
          fs.readFileSync(`${originalKeyPath}.pub`, 'utf8').trim(),
        `${configName} rotation fixture did not generate a changed key`);
        const changedConfig = writeSshdConfig({
          tempRoot,
          address: bindAddress,
          port,
          hostKey: changedKeyPath,
          authorizedKeys,
          user,
          jailRoot: root,
          instance,
          configName,
          allowTcpForwarding: 'local',
          permitOpen,
        });
        const changedProcess = startSshd(changedConfig, tempRoot, logLabel);
        await waitForPort(bindAddress, port, changedProcess);
        return changedProcess;
      };
      const rejectChangedKey = async ({ label, install, restore,
        mustAuthenticate, mustNotAuthenticate }) => {
        safeRunStage = `focused two-hop ${label} changed-key rejection`;
        const before = readAuth();
        const ticketBefore = routeTicketChecks.length;
        const socketBefore = routeSockets.length;
        const apiEventBefore = secondApiEvents.length;
        const apiRequestBefore = secondApiRequests.length;
          const requestFailureBefore = secondRequestFailures.length;
          const pageErrorBefore = pageErrors.length;
        let phase = 'install_changed_key';
        let socketAssertionEvidence = null;
        try {
          await install();
          phase = 'open_hosts';
          await click(routePage, 'Hosts');
          const card = routePage.getByRole('group', {
            name: new RegExp(multiHopHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
          }).first();
          const changedKeyRejection = routePage.getByText(
            'SSH 主机密钥与已保存指纹不同，连接已拒绝', { exact: false },
          ).first();
          phase = 'wait_previous_rejection_to_hide';
          await changedKeyRejection.waitFor({ state: 'hidden', timeout: 15000 });
          phase = 'click_connect';
          await card.getByRole('button', { name: 'Connect', exact: true }).click();
          phase = 'wait_fresh_changed_key_rejection';
          await changedKeyRejection.waitFor({ state: 'visible', timeout: 30000 });
          phase = 'assert_rejected_without_connected_status';
          assertThat(!(await routePage.getByText('CONNECTED', { exact: true }).count()),
            `client connected after ${label} host key changed`);
          const expectedRelayAttempts = relayAttemptsThroughRejectedHop(
            mustAuthenticate.length,
          );
          phase = 'assert_relay_ticket_attempts_through_rejected_hop';
          const ticketAttempts = routeTicketChecks.slice(ticketBefore);
          assertThat(relayAttemptCountIsBounded(
            ticketAttempts.length,
            expectedRelayAttempts,
            3,
          ) &&
            ticketAttempts.every(Boolean),
          `${label} rejection exceeded the bounded Relay ticket route budget or left Bastion A`);
          phase = 'wait_relay_sockets_through_rejected_hop';
          const expectedSocketCountAfter = socketBefore + ticketAttempts.length;
          const socketEventDeadline = Date.now() + 5000;
          while (routeSockets.length < expectedSocketCountAfter &&
              Date.now() < socketEventDeadline) {
            await routePage.waitForTimeout(50);
          }
          if (routeSockets.length >= expectedSocketCountAfter) {
            await routePage.waitForTimeout(250);
          }
          phase = 'assert_relay_sockets_through_rejected_hop';
          const socketCountAfter = routeSockets.length;
          const latestSocket = routeSockets.at(-1);
          socketAssertionEvidence = {
            countBefore: socketBefore,
            countAfter: socketCountAfter,
            expectedCountAfter: expectedSocketCountAfter,
            expectedAttemptCount: ticketAttempts.length,
            exactAttemptCount: socketCountAfter === expectedSocketCountAfter,
            latestSocketPresent: Boolean(latestSocket),
            latestSocketOpened: latestSocket?.opened === true,
            latestSocketClosed: latestSocket?.closed === true,
          };
          assertThat(socketAssertionEvidence.exactAttemptCount &&
            socketAssertionEvidence.latestSocketOpened,
          `${label} rejection did not create one Relay WebSocket per handshake attempt`);
          assertRelayPageUnchanged(otherPageSnapshot,
            `focused changed ${label} Host Key rejection`);
          phase = 'wait_earlier_hop_authentication';
          const authenticationDeadline = Date.now() + 5000;
          let after = readAuth();
          const earlierHopAuthenticated = () => mustAuthenticate.every((hop) =>
            sshdDiagnosticDelta(before[hop], after[hop]).publicKeyAccepted > 0);
          while (!earlierHopAuthenticated() && Date.now() < authenticationDeadline) {
            await routePage.waitForTimeout(50);
            after = readAuth();
          }
          phase = 'assert_per_hop_authentication_boundary';
          for (const hop of mustAuthenticate) {
            assertThat(sshdDiagnosticDelta(before[hop], after[hop]).publicKeyAccepted > 0,
              `${label} rejection did not authenticate earlier ${hop}`);
          }
          for (const hop of mustNotAuthenticate) {
            assertThat(sshdDiagnosticDelta(before[hop], after[hop]).publicKeyAccepted === 0,
              `${label} changed key was not rejected before ${hop} authentication`);
          }
          console.log(`stage: focused changed ${label} key was independently rejected`,
            JSON.stringify({ relayTicketTarget: 'Bastion A',
              relayTicketAttempts: expectedRelayAttempts,
              relaySocketAttempts: expectedRelayAttempts,
              earlierHopsAuthenticated: mustAuthenticate,
              laterHopsNotAuthenticated: mustNotAuthenticate }));
        } catch (error) {
          const after = readAuth();
          const uiFlags = await routePage.evaluate(() => {
            const text = document.body.innerText || '';
            return {
              changedKeyRejectedVisible: text.includes(
                'SSH 主机密钥与已保存指纹不同，连接已拒绝'),
              trustPromptVisible: text.includes('Trust after verification'),
              connectedTextVisible: text.includes('CONNECTED'),
              disconnectedTextVisible: text.includes('SSH terminal · disconnected'),
              relayTransportErrorVisible: text.includes('无法建立 SSH 中继 WebSocket。'),
              relayTicketErrorVisible: text.includes('SSH 中继票据已失效'),
              visibleDialogCount: document.querySelectorAll(
                'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
              ).length,
            };
          }).catch(() => ({ available: false }));
          const recentSocket = routeSockets.at(-1);
          console.log('focused two-hop changed-key safe diagnostic', JSON.stringify({
            hop: label,
            phase,
            error: safeErrorSummary(error),
            ui: uiFlags,
            apiRequests: secondApiRequests.slice(apiRequestBefore).slice(-10),
            apiResponses: secondApiEvents.slice(apiEventBefore).slice(-10),
            requestFailures: secondRequestFailures.slice(requestFailureBefore).slice(-10),
            pageErrors: pageErrors.slice(pageErrorBefore).slice(-5),
            ticketCountDelta: routeTicketChecks.length - ticketBefore,
            latestTicketTargetsBastionA: routeTicketChecks.at(-1) ?? null,
            socketCountDelta: routeSockets.length - socketBefore,
            socketAssertionEvidence,
            latestSocketOpened: Boolean(recentSocket?.opened),
            latestSocketClosed: Boolean(recentSocket?.closed),
            authBefore: before,
            authAfter: after,
            authDeltas: Object.fromEntries(Object.keys(before).map((hopName) => [
              hopName,
              safeCounterDelta(before[hopName], after[hopName], [
                'tcpConnectionsAccepted', 'connectionsClosed',
                'publicKeyAccepted', 'publicKeyRejected',
                'keyExchangeErrors', 'sessionOpenRequests', 'sessionStarts',
              ]),
            ])),
          }));
          throw error;
        } finally {
          await restore();
        }
      };

      await rejectChangedKey({
        label: 'loopback Target',
        install: async () => {
          await stopGroup(multiHopTargetSshdProcess);
          multiHopTargetSshdProcess = await launchChangedSshd({
            changedKeyPath: path.join(tempRoot, 'multihop_target_host_changed'),
            originalKeyPath: multiHopTargetHostKey,
            bindAddress: targetAddress,
            port: multiHopTargetPort,
            authorizedKeys: multiHopTargetAuthorizedKeysPath,
            root: path.join(sshdFixtureRoot, 'target-multihop', 'root'),
            instance: 'sshd-multihop-target',
            logLabel: 'sshd-multihop-target',
            configName: 'sshd-multihop-target-changed',
            permitOpen: null,
          });
        },
        restore: async () => {
          await stopGroup(multiHopTargetSshdProcess);
          multiHopTargetSshdProcess = startSshd(
            multiHopTargetConfigPath, tempRoot, 'sshd-multihop-target');
          await waitForPort(targetAddress, multiHopTargetPort, multiHopTargetSshdProcess);
        },
        mustAuthenticate: ['bastionA', 'bastionB'],
        mustNotAuthenticate: ['target'],
      });
      await rejectChangedKey({
        label: 'Bastion B',
        install: async () => {
          await stopGroup(secondJumpSshdProcess);
          secondJumpSshdProcess = await launchChangedSshd({
            changedKeyPath: path.join(tempRoot, 'bastion_b_host_changed'),
            originalKeyPath: secondJumpHostKey,
            bindAddress: address,
            port: secondBastionPort,
            authorizedKeys: secondJumpAuthorizedKeysPath,
            root: path.join(sshdFixtureRoot, 'bastion-b', 'root'),
            instance: 'second-jump-sshd',
            logLabel: 'second-jump-sshd',
            configName: 'second-jump-sshd-changed',
            permitOpen: `${targetAddress}:${multiHopTargetPort}`,
          });
        },
        restore: async () => {
          await stopGroup(secondJumpSshdProcess);
          secondJumpSshdProcess = startSshd(
            secondJumpConfigPath, tempRoot, 'second-jump-sshd');
          await waitForPort(address, secondBastionPort, secondJumpSshdProcess);
        },
        mustAuthenticate: ['bastionA'],
        mustNotAuthenticate: ['bastionB', 'target'],
      });
      await rejectChangedKey({
        label: 'Bastion A',
        install: async () => {
          await stopGroup(jumpSshdProcess);
          jumpSshdProcess = await launchChangedSshd({
            changedKeyPath: path.join(tempRoot, 'bastion_a_multihop_host_changed'),
            originalKeyPath: jumpHostKey,
            bindAddress: address,
            port: bastionPort,
            authorizedKeys: jumpAuthorizedKeysPath,
            root: jailRoot,
            instance: 'jump-sshd',
            logLabel: 'jump-sshd',
            configName: 'jump-sshd-multihop-changed',
            permitOpen: [
              `${targetAddress}:${sshPort}`,
              `${targetAddress}:${sshPort2}`,
              `${address}:${secondBastionPort}`,
            ],
          });
        },
        restore: async () => {
          await stopGroup(jumpSshdProcess);
          jumpSshdProcess = startSshd(jumpConfigPath, tempRoot, 'jump-sshd');
          await waitForPort(address, bastionPort, jumpSshdProcess);
        },
        mustAuthenticate: [],
        mustNotAuthenticate: ['bastionA', 'bastionB', 'target'],
      });
      assertThat(relayTicketTargetChecks.length > 0 && relayTicketTargetChecks.every(Boolean),
        'a focused Relay ticket targeted Bastion B or a loopback Target');
      console.log('stage: focused changed-key rejection passed at Bastion A, Bastion B, and Target');
      assertThat(pageErrors.length === 0,
        'focused multihop journey recorded browser page errors');
    };
    const runFocusedDeepHopAcceptance = async (routePage, routeHostCard, routeDepth) => {
      const routeLabel = `${routeDepth}-hop`;
      const routeHostName = routeDepth === 8
        ? maxDepthHostName
        : routeDepth === 4 ? fourHopHostName : threeHopHostName;
      safeRunStage = `focused ${routeLabel} synced Host preflight`;
      const routeTicketChecks = relayTicketChecksForPage(routePage);
      const routeSockets = relaySocketsForPage(routePage);
      const ticketBaseline = routeTicketChecks.length;
      const socketBaseline = routeSockets.length;
      const otherPage = routePage === page ? secondPage : page;
      const otherPageSnapshot = snapshotRelayPage(otherPage);
      const routeHopDefinitions = [
        {
          hop: 'bastionA', endpoint: `${address}:${bastionPort}`,
          logPath: path.join(tempRoot, 'jump-sshd.log'),
          hostKey: jumpHostKey, authorizedKeys: jumpAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'bastion-a', 'root'),
          instance: 'jump-sshd', configPath: jumpConfigPath,
          permitOpen: extendedHopOnly
            ? `${address}:${secondBastionPort}`
            : `${address}:${secondBastionPort}`,
          originalProcess: () => jumpSshdProcess,
          setProcess: (process) => { jumpSshdProcess = process; },
        },
        {
          hop: 'bastionB', endpoint: `${address}:${secondBastionPort}`,
          logPath: path.join(tempRoot, 'second-jump-sshd.log'),
          hostKey: secondJumpHostKey, authorizedKeys: secondJumpAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'bastion-b', 'root'),
          instance: 'second-jump-sshd', configPath: secondJumpConfigPath,
          permitOpen: `${address}:${thirdBastionPort}`,
          originalProcess: () => secondJumpSshdProcess,
          setProcess: (process) => { secondJumpSshdProcess = process; },
        },
        {
          hop: 'bastionC', endpoint: `${address}:${thirdBastionPort}`,
          logPath: path.join(tempRoot, 'third-jump-sshd.log'),
          hostKey: thirdJumpHostKey, authorizedKeys: thirdJumpAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'bastion-c', 'root'),
          instance: 'third-jump-sshd', configPath: thirdJumpConfigPath,
          permitOpen: extendedHopOnly
            ? `${address}:${fourthBastionPort}`
            : `${targetAddress}:${multiHopTargetPort}`,
          originalProcess: () => thirdJumpSshdProcess,
          setProcess: (process) => { thirdJumpSshdProcess = process; },
        },
        ...(extendedHopOnly ? [{
          hop: 'bastionD', endpoint: `${address}:${fourthBastionPort}`,
          logPath: path.join(tempRoot, 'fourth-jump-sshd.log'),
          hostKey: fourthJumpHostKey, authorizedKeys: fourthJumpAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'bastion-d', 'root'),
          instance: 'fourth-jump-sshd', configPath: fourthJumpConfigPath,
          permitOpen: maxDepthHopOnly
            ? `${address}:${maxDepthBastionPorts[0]}`
            : `${targetAddress}:${multiHopTargetPort}`,
          originalProcess: () => fourthJumpSshdProcess,
          setProcess: (process) => { fourthJumpSshdProcess = process; },
        }] : []),
        ...(maxDepthHopOnly ? maxDepthBastionNames.map((letter, index) => ({
          hop: `bastion${letter}`,
          endpoint: `${address}:${maxDepthBastionPorts[index]}`,
          logPath: path.join(tempRoot, `max-depth-${letter.toLowerCase()}-sshd.log`),
          hostKey: maxDepthJumpHostKeys[index],
          authorizedKeys: maxDepthBastionAuthorizedKeysPaths[index],
          jailRoot: path.join(sshdFixtureRoot, `bastion-${letter.toLowerCase()}`, 'root'),
          instance: `max-depth-${letter.toLowerCase()}-sshd`,
          configPath: maxDepthJumpConfigPaths[index],
          permitOpen: index + 1 < maxDepthBastionNames.length
            ? `${address}:${maxDepthBastionPorts[index + 1]}`
            : `${targetAddress}:${multiHopTargetPort}`,
          originalProcess: () => maxDepthJumpSshdProcesses[index],
          setProcess: (process) => { maxDepthJumpSshdProcesses[index] = process; },
        })) : []),
      ].slice(0, routeDepth);
      const routeHopKeys = routeHopDefinitions.map((definition) => definition.hop);
      const logPaths = Object.fromEntries([
        ...routeHopDefinitions.map(({ hop, logPath }) => [hop, logPath]),
        ['target', path.join(tempRoot, 'sshd-multihop-target.log')],
      ]);
      const readAuth = () => Object.fromEntries(Object.entries(logPaths)
        .map(([hop, logPath]) => [hop, sshdRuntimeSummary(logPath)]));
      const authBefore = readAuth();
      const expectedTrustOrder = [
        ...routeHopDefinitions.map((definition, index) => ({
          hop: definition.hop,
          endpoint: definition.endpoint,
          authenticated: routeHopKeys.slice(0, index),
          unauthenticated: [...routeHopKeys.slice(index), 'target'],
        })),
        {
          hop: 'target', endpoint: `${targetAddress}:${multiHopTargetPort}`,
          authenticated: routeHopKeys, unauthenticated: ['target'],
        },
      ];
      const trustEvidence = [];
      safeRunStage = `focused ${routeLabel} route Connect action`;
      await routeHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
      let trustSignal = null;
      let trustPrompts = 0;
      const trustWaitMs = routeDepth === 8 ? 120000 : 60000;
      while (trustPrompts <= expectedTrustOrder.length) {
        safeRunStage = `focused ${routeLabel} wait for SSH trust or terminal state`;
        try {
          trustSignal = await waitForSshTrustOrError(routePage, trustWaitMs, routeHostName);
        } catch (error) {
          const routeUiState = await routePage.evaluate((expectedHostName) => {
            const text = [...document.querySelectorAll('flt-semantics')]
              .map((element) => element.getAttribute('aria-label') || '')
              .join('\n');
            const lower = text.toLowerCase();
            return {
              readyState: document.readyState,
              trustActionVisible: [...document.querySelectorAll('flt-semantics[role="button"]')]
                .some((element) => (element.getAttribute('aria-label') || '') ===
                  'Trust after verification'),
              connectedTextVisible: text.includes('CONNECTED'),
              terminalFailedTabVisible: text.includes(`${expectedHostName} terminal tab, failed`),
              visibleFailureCategories: {
                relayTimeout: text.includes('SSH 中继连接超时。'),
                relayTransport: text.includes('无法建立 SSH 中继 WebSocket。'),
                relayTicket: text.includes('SSH 中继票据已失效'),
                hostKeyVerification: text.includes('SSH 主机密钥验证失败'),
                hostKeyChanged: text.includes('SSH 主机密钥与已保存指纹不同'),
                hostKeyApprovalRejected: text.includes('已拒绝尚未信任的 SSH 主机密钥'),
                hostKeyApprovalSync: text.includes('Vault sync did not confirm') ||
                  text.includes('Vault 密钥状态仍未能验证'),
                credentialParse: text.includes('SSH 私钥无法解析或口令不正确'),
                authentication: /authentication failed|public.?key authentication failed|认证失败|身份验证失败/i.test(text),
                sshAuthenticationFriendly: text.includes('SSH 身份验证失败'),
                sshHandshakeFriendly: text.includes('SSH 握手失败'),
                sshSessionFriendly: text.includes('无法打开终端会话'),
                routeHostKeyRestartLimit: text.includes('Too many SSH host-key checks'),
                sshProtocol: /SSH.{0,24}(protocol|handshake|identification|kex)|SSH.{0,24}(协议|握手)/i.test(text),
                routeDepth: /Jump Host 链最多支持/.test(text),
                credentialResolution: /SSH 凭据无法解析|effective SSH credential is unavailable/i.test(text),
                genericFailure: /failed|failure|错误|失败/.test(lower),
              },
              semanticsCount: document.querySelectorAll('flt-semantics').length,
            };
          }, routeHostName).catch(() => ({ pageClosedOrUnresponsive: true }));
          const authAtWaitError = readAuth();
          const sshdAtWaitError = Object.fromEntries([
            ...routeHopDefinitions.map((definition) => definition.hop), 'target',
          ].map((hop) => [hop, sshdDiagnosticDelta(authBefore[hop], authAtWaitError[hop])]));
          console.log(`${routeLabel} SSH state wait safe diagnostic`, JSON.stringify({
            errorType: error?.name || 'Error',
            errorCategory: safeErrorSummary(error).category,
            trustPrompts,
            routeUiState,
            sshdAtWaitError,
            sshDiagnosticCategories: safeSshDiagnosticSummary(sshDiagnostics),
            requestFailureCategories: requestFailures.slice(-8).map((failure) =>
              failure.failureCategory),
            pageErrorCount: pageErrors.length,
            browserConsoleErrorCount: browserConsoleEvents.filter((event) =>
              event.type === 'error').length,
            relayTicketAttemptCount: routeTicketChecks.length - ticketBaseline,
            relayTicketsTargetAllowed: routeTicketChecks.slice(ticketBaseline).every(Boolean),
            relaySocketCount: routeSockets.length - socketBaseline,
            openRelaySocketCount: routeSockets.slice(socketBaseline)
              .filter((socket) => socket.opened && !socket.closed).length,
          }));
          throw error;
        }
        if (trustSignal !== 'host_key_prompt') break;
        const expected = expectedTrustOrder[trustPrompts];
        const endpointMatches = expected != null && await visibleSshTrustPromptMatchesEndpoint(
          routePage, expected.endpoint);
        const authAtDecision = readAuth();
        const deltasAtDecision = Object.fromEntries(Object.keys(authBefore).map((hop) => [
          hop,
          sshdDiagnosticDelta(authBefore[hop], authAtDecision[hop]).publicKeyAccepted,
        ]));
        console.log(`${routeLabel} trust decision safe evidence`, JSON.stringify({
          promptIndex: trustPrompts + 1,
          expectedHop: expected?.hop || 'unexpected',
          expectedEndpoint: expected?.endpoint || null,
          endpointMatches,
          authenticatedCounts: deltasAtDecision,
        }));
        assertThat(expected != null && endpointMatches,
        `${routeLabel} route presented an unexpected KnownHost prompt at position ${trustPrompts + 1}`);
        for (const hop of expected.authenticated) {
          assertThat(deltasAtDecision[hop] > 0,
            `${routeLabel} ${expected.hop} trust prompt appeared before ${hop} authentication`);
        }
        for (const hop of expected.unauthenticated) {
          assertThat(deltasAtDecision[hop] === 0,
            `${routeLabel} ${expected.hop} trust prompt arrived after ${hop} authentication`);
        }
        trustEvidence.push({ hop: expected.hop, authDeltas: deltasAtDecision });
        const promptToken = await sshTrustPromptToken(routePage);
        safeRunStage = `focused ${routeLabel} trust approval at ${expected.hop}`;
        await click(routePage, 'Trust after verification');
        trustPrompts += 1;
        safeRunStage = `focused ${routeLabel} wait after ${expected.hop} trust approval`;
        await waitForSshTrustPromptAdvance(routePage, promptToken, 60000);
      }
      if (trustSignal !== 'host_key_prompt' && trustPrompts < expectedTrustOrder.length) {
        const authAtWaitResult = readAuth();
        const sshdAtWaitResult = Object.fromEntries([
          ...routeHopDefinitions.map((definition) => definition.hop), 'target',
        ].map((hop) => [hop, sshdDiagnosticDelta(authBefore[hop], authAtWaitResult[hop])]));
        const waitResultUiState = await routePage.evaluate(() => {
          const text = [...document.querySelectorAll('flt-semantics')]
            .map((element) => element.getAttribute('aria-label') || '')
            .join('\n');
          const lower = text.toLowerCase();
          return {
            connectedTextVisible: text.includes('CONNECTED'),
            terminalFailedTabVisible: text.includes('terminal tab, failed'),
            terminalDisconnectedTabVisible: text.includes('terminal tab, disconnected'),
            visibleFailureCategories: {
              relayTimeout: text.includes('SSH 中继连接超时。'),
              relayTransport: text.includes('无法建立 SSH 中继 WebSocket。'),
              relayTicket: text.includes('SSH 中继票据已失效'),
              hostKeyVerification: text.includes('SSH 主机密钥验证失败'),
              hostKeyChanged: text.includes('SSH 主机密钥与已保存指纹不同'),
              hostKeyApprovalRejected: text.includes('已拒绝尚未信任的 SSH 主机密钥'),
              hostKeyApprovalSync: text.includes('Vault sync did not confirm') ||
                text.includes('Vault 密钥状态仍未能验证'),
              credentialParse: text.includes('SSH 私钥无法解析或口令不正确'),
              authentication: /authentication failed|public.?key authentication failed|认证失败|身份验证失败/i.test(text),
              sshAuthenticationFriendly: text.includes('SSH 身份验证失败'),
              sshHandshakeFriendly: text.includes('SSH 握手失败'),
              sshSessionFriendly: text.includes('无法打开终端会话'),
              routeHostKeyRestartLimit: text.includes('Too many SSH host-key checks'),
              sshProtocol: /SSH.{0,24}(protocol|handshake|identification|kex)|SSH.{0,24}(协议|握手)/i.test(text),
              routeDepth: /Jump Host 链最多支持/.test(text),
              credentialResolution: /SSH 凭据无法解析|effective SSH credential is unavailable/i.test(text),
              genericFailure: /failed|failure|错误|失败/.test(lower),
            },
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        console.log(`${routeLabel} SSH wait result safe diagnostic`, JSON.stringify({
          trustSignal,
          trustPrompts,
          expectedTrustPrompts: expectedTrustOrder.length,
          waitMs: trustWaitMs,
          waitResultUiState,
          sshdAtWaitResult,
          sshDiagnosticCategories: safeSshDiagnosticSummary(sshDiagnostics),
          requestFailureCategories: requestFailures.slice(-8).map((failure) =>
            failure.failureCategory),
          relayTicketAttemptCount: routeTicketChecks.length - ticketBaseline,
          relayTicketsTargetAllowed: routeTicketChecks.slice(ticketBaseline).every(Boolean),
          relaySocketCount: routeSockets.length - socketBaseline,
          openRelaySocketCount: routeSockets.slice(socketBaseline)
            .filter((socket) => socket.opened && !socket.closed).length,
        }));
      }
      if (trustSignal === 'deadline_without_visible_signal') {
        const authAtDeadline = readAuth();
        const routeSshDiagnostics = Object.fromEntries(routeHopDefinitions.map((definition) => {
          const delta = sshdDiagnosticDelta(
            authBefore[definition.hop], authAtDeadline[definition.hop]);
          return [definition.hop, {
            tcpConnectionsAccepted: delta.tcpConnectionsAccepted,
            clientSshBannerReceived: delta.clientSshBannerReceived,
            keyExchangeStarted: delta.keyExchangeStarted,
            keyExchangeErrors: delta.keyExchangeErrors,
            publicKeyAccepted: delta.publicKeyAccepted,
            publicKeyRejected: delta.publicKeyRejected,
            authorizedKeysMatches: delta.authorizedKeysMatches,
            authorizedKeysUnavailable: delta.authorizedKeysUnavailable,
            permissionDenialLogMentions: delta.permissionDenialLogMentions,
          }];
        }));
        const targetSshDiagnostics = sshdDiagnosticDelta(
          authBefore.target, authAtDeadline.target);
        console.log(`${routeLabel} SSH route deadline diagnostics`, JSON.stringify({
          trustPrompts,
          expectedTrustPrompts: expectedTrustOrder.length,
          waitMs: trustWaitMs,
          routeSshDiagnostics,
          targetSshDiagnostics: {
            tcpConnectionsAccepted: targetSshDiagnostics.tcpConnectionsAccepted,
            clientSshBannerReceived: targetSshDiagnostics.clientSshBannerReceived,
            keyExchangeStarted: targetSshDiagnostics.keyExchangeStarted,
            keyExchangeErrors: targetSshDiagnostics.keyExchangeErrors,
            publicKeyAccepted: targetSshDiagnostics.publicKeyAccepted,
            publicKeyRejected: targetSshDiagnostics.publicKeyRejected,
          },
        }));
      }
      assertThat(trustPrompts === expectedTrustOrder.length,
        `${routeLabel} route expected ${expectedTrustOrder.length} first-use KnownHost approvals (${trustPrompts})`);
      console.log(`${routeLabel} trust completion safe evidence`, JSON.stringify({
        trustSignal,
        trustPrompts,
        expectedTrustPrompts: expectedTrustOrder.length,
        connectedTabVisible: await routePage.getByRole('button', {
          name: new RegExp(`^${routeHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} terminal tab, connected, (?:active|inactive)$`),
        }).count().catch(() => 0) > 0,
      }));
      assertThat(trustSignal === 'terminal_connected' ||
        trustSignal === 'deadline_without_visible_signal',
      `${routeLabel} route did not reach connected state (${trustSignal})`);
      await waitText(routePage, 'CONNECTED', 45000);
      await terminalTabButton(routePage, routeHostName, 'active');

      safeRunStage = `focused ${routeLabel} Relay ticket and WebSocket validation`;
      const ticketAttempts = routeTicketChecks.slice(ticketBaseline);
      const successfulRouteMinimum = routeDepth + 2;
      const successfulRouteMaximum = (2 * (routeDepth + 1)) + 1;
      assertThat(ticketAttempts.length >= successfulRouteMinimum &&
        ticketAttempts.length <= successfulRouteMaximum && ticketAttempts.every(Boolean),
      `${routeLabel} route did not keep bounded Relay ticket attempts on Bastion A`);
      const routeAttemptSockets = routeSockets.slice(socketBaseline);
      assertThat(routeAttemptSockets.length === ticketAttempts.length &&
        routeAttemptSockets.at(-1)?.opened && !routeAttemptSockets.at(-1)?.closed &&
        routeAttemptSockets.filter((socket) => socket.opened && !socket.closed).length === 1,
      `${routeLabel} route did not leave one active Relay WebSocket per handshake on the route page`);
      assertRelayPageUnchanged(otherPageSnapshot, `focused ${routeLabel} connection`);
      const authAfter = readAuth();
      const authDeltas = Object.fromEntries(Object.keys(authBefore).map((hop) => [
        hop,
        sshdDiagnosticDelta(authBefore[hop], authAfter[hop]),
      ]));
      assertThat(Object.values(authDeltas).every((delta) => delta.publicKeyAccepted > 0),
        'one or more independently keyed SSH hops did not authenticate');
      console.log(`focused ${routeLabel} per-hop trust safe evidence`, JSON.stringify({
        trustPrompts,
        trustOrder: trustEvidence.map((entry) => entry.hop),
        trustDecisionPublicKeyAcceptDeltas: trustEvidence.map((entry) => ({
          hop: entry.hop,
          authDeltas: entry.authDeltas,
        })),
        finalAuthenticationDeltas: Object.fromEntries(Object.entries(authDeltas)
          .map(([hop, delta]) => [hop, delta.publicKeyAccepted])),
        relayTicketAttempts: ticketAttempts.length,
        everyTicketTargetsBastionA: ticketAttempts.every(Boolean),
        relaySocketAttempts: routeSockets.length - socketBaseline,
        finalRelaySocketOpen: routeSockets.at(-1)?.opened === true &&
          routeSockets.at(-1)?.closed === false,
      }));

      const runFocusedDeepHopSftpAcceptance = async ({
        routePage,
        browserContext,
        relaySocket,
        ticketBaseline,
        socketBaseline,
        otherPageSnapshot,
      }) => {
        const routeTicketChecks = relayTicketChecksForPage(routePage);
        const routeSockets = relaySocketsForPage(routePage);
        const expectedRelayAttemptCount = routeTicketChecks.length - ticketBaseline;
        assertThat(relayAttemptCountIsBounded(
          expectedRelayAttemptCount,
          relayAttemptsForSuccessfulRoute(routeDepth + 1),
          routeDepth + 1,
        ), `${routeLabel} SFTP started without a successful route inside the SSH retry budget`);

        safeRunStage = `${routeLabel} SFTP fixture setup`;
        const folderName =
          `WEB_RELAY_${routeDepth}HOP_SFTP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
        const remoteFolder = path.join(multiHopRemoteRoot, folderName);
        const binaryName = `${routeDepth}-hop-${RUN_ID.slice(0, 8)}.bin`;
        const textName = `${routeDepth}-hop-${RUN_ID.slice(0, 8)}.txt`;
        const binaryPath = path.join(remoteFolder, binaryName);
        const textPath = path.join(remoteFolder, textName);
        const binaryPayload = crypto.randomBytes(521);
        const textPayload = Buffer.from(
          `${routeDepth}-hop SSH route UTF-8 fixture ${RUN_ID}: café — 東京\n`, 'utf8',
        );
        const targetLog = path.join(tempRoot, 'sshd-multihop-target.log');
        const bastionLogs = routeHopDefinitions.map(({ logPath }) => logPath);
        const targetSftpBefore = sshdRuntimeSummary(targetLog);
        const bastionSftpBefore = bastionLogs.map(sshdRuntimeSummary);
        const relayFramesBefore = safeRelayFrameCounts(relaySocket);
        const assertRelayRouteStable = (operation) => {
          const ticketAttempts = routeTicketChecks.slice(ticketBaseline);
          assertThat(ticketAttempts.length === expectedRelayAttemptCount &&
            ticketAttempts.every(Boolean),
          `${routeLabel} SFTP ${operation} added or retargeted a Relay ticket`);
          assertThat(routeSockets.length === socketBaseline + expectedRelayAttemptCount &&
            routeSockets.at(-1) === relaySocket &&
            relaySocket.opened && !relaySocket.closed &&
            routeSockets.filter((socket) => socket.opened && !socket.closed).length === 1,
          `${routeLabel} SFTP ${operation} replaced or closed the first-Bastion Relay socket`);
          assertRelayPageUnchanged(otherPageSnapshot, `${routeLabel} SFTP ${operation}`);
        };

        const uploadFixture = async (name, mimeType, payload, remotePath) => {
          const chooserPromise = routePage.waitForEvent('filechooser', { timeout: 15000 });
          await click(routePage, 'Upload');
          const chooser = await chooserPromise;
          await chooser.setFiles({ name, mimeType, buffer: payload });
          await waitForFixtureFileBytes(remotePath, payload);
          assertRelayRouteStable(`upload ${name}`);
        };

        const downloadFixture = async (name, expectedName, payload) => {
          safeRunStage = `${routeLabel} SFTP exact-byte download ${name}`;
          const downloadPromise = waitForBrowserDownload(browserContext, routePage, 30000);
          await clickSftpEntryAction(routePage, name, 'Download');
          const download = await downloadPromise;
          assertThat(download.suggestedFilename() === expectedName,
            `${routeLabel} SFTP download filename did not match ${expectedName}`);
          const downloadedPath = path.join(tempRoot, `${routeDepth}hop-${RUN_ID.slice(0, 8)}-${expectedName}`);
          try {
            await download.saveAs(downloadedPath);
            const downloadedPayload = fs.readFileSync(downloadedPath);
            let bytesMatch;
            try {
              bytesMatch = downloadedPayload.equals(payload);
            } finally {
              downloadedPayload.fill(0);
            }
            assertThat(bytesMatch,
              `${routeLabel} SFTP download bytes did not exactly match ${expectedName}`);
          } finally {
            fs.rmSync(downloadedPath, { force: true });
          }
          assertRelayRouteStable(`download ${name}`);
        };

        const deleteFixture = async (name, remotePath) => {
          await clickSftpEntryAction(routePage, name, 'Delete');
          await waitText(routePage, 'Delete this item?', 15000);
          const confirmDelete = routePage.getByRole('button', {
            name: 'Delete', exact: true,
          }).last();
          await confirmDelete.waitFor({ state: 'visible', timeout: 15000 });
          await confirmDelete.click();
          await waitForFilesystemState(remotePath, false, 15000);
          assertRelayRouteStable(`delete ${name}`);
        };

        try {
          safeRunStage = `${routeLabel} SFTP opens target subsystem`;
          await click(routePage, 'SFTP');
          await waitText(routePage, 'SFTP file browser', 15000);
          await click(routePage, 'Go to path');
          await waitText(routePage, 'Go to remote path', 15000);
          await fill(routePage, 'Remote path', '/tmp/remote');
          await click(routePage, 'Go');
          await click(routePage, 'New folder');
          await waitText(routePage, 'Create remote folder', 15000);
          await fill(routePage, 'Folder name', folderName);
          const createButton = routePage.getByRole('button', {
            name: 'Create', exact: true,
          }).last();
          await createButton.waitFor({ state: 'visible', timeout: 15000 });
          assertThat(await createButton.isEnabled(),
            `${routeLabel} SFTP did not enable remote folder creation`);
          await createButton.click();
          await waitForFilesystemState(remoteFolder, true, 10000);
          assertRelayRouteStable('folder creation');

          await click(routePage, 'Go to path');
          await waitText(routePage, 'Go to remote path', 15000);
          await fill(routePage, 'Remote path', `/tmp/remote/${folderName}`);
          await click(routePage, 'Go');
          safeRunStage = `${routeLabel} SFTP binary and UTF-8 uploads`;
          await uploadFixture(binaryName, 'application/octet-stream', binaryPayload, binaryPath);
          await uploadFixture(textName, 'text/plain', textPayload, textPath);
          assertThat(await fixtureFileMatches(binaryPath, binaryPayload) &&
            await fixtureFileMatches(textPath, textPayload),
          `${routeLabel} SFTP uploaded content did not match the fixture bytes`);
          console.log(`stage: ${routeLabel} SFTP binary and UTF-8 uploads matched Target bytes`,
            JSON.stringify({ binaryBytes: binaryPayload.length,
              binaryUploadBytesMatch: true, utf8Bytes: textPayload.length,
              utf8UploadBytesMatch: true }));

          await downloadFixture(binaryName, binaryName, binaryPayload);
          await downloadFixture(textName, textName, textPayload);

          safeRunStage = `${routeLabel} SFTP remote file cleanup`;
          await deleteFixture(textName, textPath);
          await deleteFixture(binaryName, binaryPath);
          assertThat(!fs.existsSync(textPath) && !fs.existsSync(binaryPath),
            `${routeLabel} SFTP left an uploaded file on the Target`);
          await click(routePage, 'Go to path');
          await waitText(routePage, 'Go to remote path', 15000);
          await fill(routePage, 'Remote path', '/tmp/remote');
          await click(routePage, 'Go');
          await deleteFixture(folderName, remoteFolder);
          assertThat(!fs.existsSync(remoteFolder),
            `${routeLabel} SFTP left its temporary folder on the Target`);
        } finally {
          binaryPayload.fill(0);
          textPayload.fill(0);
        }

        const targetSftpAfter = sshdRuntimeSummary(targetLog);
        const targetSftpDelta = sshdDiagnosticDelta(targetSftpBefore, targetSftpAfter);
        const bastionSftpDeltas = bastionLogs.map((logPath, index) =>
          sshdDiagnosticDelta(bastionSftpBefore[index], sshdRuntimeSummary(logPath)));
        assertThat(targetSftpDelta.sftpSubsystemRequests > 0 &&
          targetSftpDelta.sftpSubsystemStarts > 0,
          `${routeLabel} SFTP did not start its subsystem on the loopback Target`);
        assertThat(bastionSftpDeltas.every((delta) => delta.sftpSubsystemRequests === 0 &&
          delta.sftpSubsystemStarts === 0),
          `${routeLabel} SFTP unexpectedly started an SFTP subsystem on a Bastion`);
        const relayFramesAfter = safeRelayFrameCounts(relaySocket);
        assertThat(relayFramesAfter.sent.total > relayFramesBefore.sent.total &&
          relayFramesAfter.received.total > relayFramesBefore.received.total,
          `${routeLabel} SFTP did not exchange data over the existing Relay WebSocket`);
        assertRelayRouteStable('complete operation set');
        await click(routePage, 'Terminal');
        await waitText(routePage, 'CONNECTED', 15000);
        await terminalTabButton(routePage, routeHostName, 'active');
        console.log(`stage: ${routeLabel} SFTP create, binary/UTF-8 upload, byte-exact download, and cleanup passed over the existing Relay route`,
          JSON.stringify({ targetFolderCreatedAndRemoved: true,
            binaryUploadBytesMatch: true, utf8UploadBytesMatch: true,
            binaryDownloadBytesMatch: true, utf8DownloadBytesMatch: true,
            remoteFilesRemoved: true, targetSftpSubsystemRequests:
              targetSftpDelta.sftpSubsystemRequests,
            targetSftpSubsystemStarts: targetSftpDelta.sftpSubsystemStarts,
            bastionSftpSubsystemRequests: bastionSftpDeltas.map((delta) =>
              delta.sftpSubsystemRequests),
            relaySentFrameDelta: relayFramesAfter.sent.total - relayFramesBefore.sent.total,
            relayReceivedFrameDelta: relayFramesAfter.received.total -
              relayFramesBefore.received.total,
            relayTicketAttempts: expectedRelayAttemptCount,
            relaySocketAttempts: expectedRelayAttemptCount,
            activeRelaySockets: 1, sshRelayRemainedOpen: true }));
      };

      safeRunStage = `focused ${routeLabel} shell command and destination check`;
      const marker = `WEB_RELAY_${routeDepth}HOP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const markerPath = path.join(multiHopRemoteRoot, marker);
      await sendCommandToActiveTerminal(routePage, user, targetAddress,
        `printf '%s\\n' '${marker}' > /tmp/remote/${marker}`, {
          activeHostName: routeHostName,
        });
      assertThat(await waitForRemoteMarker(markerPath, marker, 20000),
        `${routeLabel} shell command did not execute in the isolated Target chroot`);
      const intermediateRemoteRoots = [
        remoteRoot, secondRemoteRoot, thirdJumpRemoteRoot,
        ...(extendedHopOnly ? [fourthJumpRemoteRoot] : []),
        ...maxDepthJumpRemoteRoots,
      ];
      assertThat(intermediateRemoteRoots.every((root) =>
        !fs.existsSync(path.join(root, marker))),
      `${routeLabel} shell marker appeared in an intermediate SSH chroot`);
      const routeSocket = routeSockets.at(-1);
      const frameDeadline = Date.now() + 10000;
      while (Date.now() < frameDeadline &&
          (!routeSocket.sentFrames.length || !routeSocket.receivedFrames.length)) {
        await routePage.waitForTimeout(100);
      }
      assertThat(routeSocket.sentFrames.length > 0 && routeSocket.receivedFrames.length > 0,
        `${routeLabel} terminal did not exchange Relay WebSocket frames`);
      await runFocusedDeepHopSftpAcceptance({
        routePage,
        browserContext: secondContext,
        relaySocket: routeSocket,
        ticketBaseline,
        socketBaseline,
        otherPageSnapshot,
      });
      await click(routePage, 'Disconnect');
      await waitText(routePage, 'SSH terminal · disconnected', 15000);
      const closeDeadline = Date.now() + 5000;
      while (Date.now() < closeDeadline && !routeSocket.closed) {
        await routePage.waitForTimeout(100);
      }
      assertThat(routeSocket.closed && routeAttemptSockets.every((socket) => socket.closed),
        `${routeLabel} disconnect did not close every Relay WebSocket from the successful route`);
      assertRelayPageUnchanged(otherPageSnapshot, `focused ${routeLabel} disconnect`);

        const pageErrorCountBeforeChangedKey = pageErrors.length;
      const consoleErrorsBeforeChangedKey = browserConsoleEvents.filter((event) =>
        event.type === 'error').length;
      const consoleErrorEventsBeforeChangedKey = browserConsoleEvents.filter((event) =>
        event.type === 'error');
      safeRunStage = `focused ${routeLabel} changed intermediate key rejection`;
      const authBeforeChangedKey = readAuth();
      const ticketBeforeChangedKey = routeTicketChecks.length;
      const socketBeforeChangedKey = routeSockets.length;
      const rejectionText = 'SSH 主机密钥与已保存指纹不同，连接已拒绝';
      const changedKeyRejection = routePage.getByText(rejectionText, { exact: false }).first();
      const changedHopDefinition = routeHopDefinitions.at(-1);
      const changedHop = {
        ...changedHopDefinition,
        label: `Bastion ${routeDepth === 3 ? 'C' : routeDepth === 4 ? 'D' : 'H'}`,
        key: changedHopDefinition.hop,
        port: Number(changedHopDefinition.endpoint.split(':').at(-1)),
        originalProcess: changedHopDefinition.originalProcess(),
      };
      let changedHopProcess = null;
      try {
        safeRunStage = `focused ${routeLabel} stop ${changedHop.label} before key rotation`;
        await stopGroup(changedHop.originalProcess);
        safeRunStage = `focused ${routeLabel} generate changed ${changedHop.label} host key`;
        const changedKeyPath = path.join(tempRoot,
          `bastion_${routeDepth === 3 ? 'c' : routeDepth === 4 ? 'd' : 'h'}_host_changed`);
        run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedKeyPath], {
          timeout: 30000,
        });
        fs.chmodSync(changedKeyPath, 0o600);
        assertThat(fs.readFileSync(`${changedKeyPath}.pub`, 'utf8').trim() !==
          fs.readFileSync(`${changedHop.hostKey}.pub`, 'utf8').trim(),
        `${changedHop.label} changed-key fixture did not rotate its public host key`);
        const changedConfigPath = writeSshdConfig({
          tempRoot,
          address,
          port: changedHop.port,
          hostKey: changedKeyPath,
          authorizedKeys: changedHop.authorizedKeys,
          user,
          jailRoot: changedHop.jailRoot,
          instance: changedHop.instance,
          configName: `${changedHop.instance}-changed`,
          allowTcpForwarding: 'local',
          permitOpen: changedHop.permitOpen,
        });
        safeRunStage = `focused ${routeLabel} restart ${changedHop.label} with changed host key`;
        changedHopProcess = startSshd(changedConfigPath, tempRoot, changedHop.instance);
        changedHop.setProcess(changedHopProcess);
        safeRunStage = `focused ${routeLabel} wait for changed ${changedHop.label} SSHD`;
        await waitForPort(address, changedHop.port, changedHopProcess);
        safeRunStage = `focused ${routeLabel} open Hosts after ${changedHop.label} key rotation`;
        await click(routePage, 'Hosts');
        safeRunStage = `focused ${routeLabel} locate synced Host after ${changedHop.label} key rotation`;
        const card = routePage.getByRole('group', {
          name: new RegExp(routeHostName),
        }).first();
        safeRunStage = `focused ${routeLabel} clear previous host-key notice`;
        await changedKeyRejection.waitFor({ state: 'hidden', timeout: 15000 });
        safeRunStage = `focused ${routeLabel} click Connect after ${changedHop.label} key rotation`;
        await card.getByRole('button', { name: 'Connect', exact: true }).click();
        safeRunStage = `focused ${routeLabel} observe changed ${changedHop.label} key rejection`;
        const changedKeyRejectionTimeoutMs = routeDepth === 8 ? 120000 : 30000;
        try {
          await changedKeyRejection.waitFor({
            state: 'visible', timeout: changedKeyRejectionTimeoutMs,
          });
        } catch (error) {
          const rejectedUiEvidence = await routePage.evaluate((expectedText) => {
            const body = document.body.innerText || '';
            const visible = (element) => {
              const rect = element.getBoundingClientRect();
              const style = getComputedStyle(element);
              return rect.width > 0 && rect.height > 0 &&
                style.display !== 'none' && style.visibility !== 'hidden' &&
                Number(style.opacity) !== 0;
            };
            const alerts = [...document.querySelectorAll(
              'flt-semantics[role="alert"], [role="alert"]',
            )].filter(visible);
            return {
              expectedRejectionVisible: body.includes(expectedText),
              changedKeyLanguageVisible: /主机密钥|指纹/.test(body),
              connectedLabelVisible: /\bCONNECTED\b/.test(body),
              disconnectedLabelVisible: /\bDISCONNECTED\b|disconnected/.test(body),
              visibleAlertCount: alerts.length,
              visibleAlertHasKeyLanguage: alerts.some((element) =>
                /主机密钥|指纹/.test(element.innerText || '')),
              connectButtonCount: [...document.querySelectorAll(
                'flt-semantics[role="button"]',
              )].filter((element) => visible(element) &&
                (element.getAttribute('aria-label') || element.innerText || '')
                  .trim() === 'Connect').length,
            };
          }, 'SSH 主机密钥与已保存指纹不同，连接已拒绝')
            .catch(() => ({ diagnosticUnavailable: true }));
          const authAtChangedKeyTimeout = readAuth();
          const sshdDeltasAtChangedKeyTimeout = Object.fromEntries(
            Object.keys(authBeforeChangedKey).map((hop) => [hop,
              sshdDiagnosticDelta(authBeforeChangedKey[hop], authAtChangedKeyTimeout[hop])]),
          );
          console.log(`focused ${routeLabel} changed ${changedHop.label} rejection timeout safe evidence`,
            JSON.stringify({
              ui: rejectedUiEvidence,
              relayTicketDelta: routeTicketChecks.length - ticketBeforeChangedKey,
              relayTicketsTargetedBastionA: routeTicketChecks
                .slice(ticketBeforeChangedKey).every(Boolean),
              relaySocketDelta: routeSockets.length - socketBeforeChangedKey,
              relaySockets: routeSockets.slice(socketBeforeChangedKey).map((socket) => ({
                opened: socket.opened,
                closed: socket.closed,
                socketError: socket.socketError,
              })),
              sshdDeltas: Object.fromEntries(Object.entries(sshdDeltasAtChangedKeyTimeout)
                .map(([hop, delta]) => [hop, {
                  tcpConnectionsAccepted: delta.tcpConnectionsAccepted,
                  serverSshBannerEmitted: delta.serverSshBannerEmitted,
                  keyExchangeStarted: delta.keyExchangeStarted,
                  publicKeyAccepted: delta.publicKeyAccepted,
                  publicKeyRejected: delta.publicKeyRejected,
                  preauthDisconnects: delta.preauthDisconnects,
                }])),
              timeoutCategory: safeErrorSummary(error).category,
            }));
          throw error;
        }
        safeRunStage = `focused ${routeLabel} assert changed ${changedHop.label} did not connect`;
        assertThat(!(await routePage.getByText('CONNECTED', { exact: true }).count()),
          `client connected after ${changedHop.label} host key changed`);
        safeRunStage = `focused ${routeLabel} assert changed ${changedHop.label} Relay retry budget`;
        const ticketAttempts = routeTicketChecks.slice(ticketBeforeChangedKey);
        const expectedFailedRouteAttempts = 3;
        assertThat(ticketAttempts.length >= expectedFailedRouteAttempts &&
          ticketAttempts.length <= routeDepth + 6 && ticketAttempts.every(Boolean),
        `changed ${changedHop.label} route exceeded its Relay retry budget or targeted a non-A host`);
        const expectedSocketCount = socketBeforeChangedKey + ticketAttempts.length;
        safeRunStage = `focused ${routeLabel} wait changed ${changedHop.label} Relay sockets`;
        const socketDeadline = Date.now() + 5000;
        while (routeSockets.length < expectedSocketCount && Date.now() < socketDeadline) {
          await routePage.waitForTimeout(50);
        }
        assertThat(routeSockets.length === expectedSocketCount &&
          routeSockets.slice(socketBeforeChangedKey).every((socket) => socket.opened),
        `changed ${changedHop.label} route did not create one Relay WebSocket per ticket attempt`);
        safeRunStage = `focused ${routeLabel} assert other Profile page after ${changedHop.label} rejection`;
        assertRelayPageUnchanged(otherPageSnapshot,
          `focused changed ${changedHop.label} key rejection`);
        safeRunStage = `focused ${routeLabel} assert ${changedHop.label} authentication boundary`;
        const authAfterChangedKey = readAuth();
        const changedKeyDeltas = Object.fromEntries(Object.keys(authBeforeChangedKey).map((hop) => [
          hop,
          sshdDiagnosticDelta(authBeforeChangedKey[hop], authAfterChangedKey[hop])
            .publicKeyAccepted,
        ]));
        const earlierHops = routeHopKeys.slice(0, -1);
      const laterHops = ['target'];
        assertThat(earlierHops.every((hop) => changedKeyDeltas[hop] > 0) &&
          changedKeyDeltas[changedHop.key] === 0 &&
          laterHops.every((hop) => changedKeyDeltas[hop] === 0),
        `changed ${changedHop.label} host key was not rejected before its authentication or later hops`);
        safeRunStage = `focused ${routeLabel} assert browser errors after ${changedHop.label} rejection`;
        const changedKeyConsoleErrorCorrelations = safeBrowserConsoleApiCorrelations(
          consoleErrorEventsBeforeChangedKey,
          browserConsoleCaptureTimes,
          apiResponseDiagnostics,
          requestFailureDiagnostics,
        );
        const preExistingConsoleErrorsRecoveredByAuthRefresh =
          consoleErrorEventsBeforeChangedKey.length === 0 ||
          (changedKeyConsoleErrorCorrelations.length ===
              consoleErrorEventsBeforeChangedKey.length &&
            consoleErrorEventsBeforeChangedKey.every((event) =>
              event.profile === 'A' &&
              event.messageCategory === 'resource_load' &&
              ['/api/v1/vaults/{id}/presence',
                '/api/v1/notifications/tickets'].includes(event.sourceApiPath)) &&
            changedKeyConsoleErrorCorrelations.every((correlation) => {
              if (correlation.profile !== 'A' ||
                  !correlation.nearbyResponses.some((response) =>
                    response.method === 'POST' && response.httpStatus === 401)) {
                return false;
              }
              if (!['/api/v1/notifications/tickets',
                '/api/v1/vaults/{id}/presence']
                .includes(correlation.sourceApiPath)) return false;
              const refresh = correlation.nearbyAuthLifecycleResponses.find(
                (response) => response.routeCategory === 'auth_refresh' &&
                  response.method === 'POST' && response.httpStatus === 200);
              const ticketRetry = correlation.nearbyAuthLifecycleResponses.find(
                (response) => response.routeCategory === 'notification_ticket' &&
                  response.method === 'POST' && response.httpStatus === 200);
              return Boolean(refresh && ticketRetry &&
                ticketRetry.deltaFromUnauthorizedMs > refresh.deltaFromUnauthorizedMs);
            }));
        console.log(`focused ${routeLabel} changed-key browser error safe evidence`,
          JSON.stringify({
            pageErrorCountBeforeChangedKey,
            pageErrorCountAfterChangedKey: pageErrors.length,
            pageErrors: pageErrors.slice(-8),
            consoleErrorCountBeforeChangedKey: consoleErrorsBeforeChangedKey,
            consoleErrorCountAfterChangedKey: browserConsoleEvents.filter((event) =>
              event.type === 'error').length,
            preExistingConsoleErrorsRecoveredByAuthRefresh,
            consoleErrors: browserConsoleEvents.filter((event) =>
              event.type === 'error').slice(-8),
            consoleErrorApiCorrelations: changedKeyConsoleErrorCorrelations,
          }));
        assertThat(pageErrors.length === 0 &&
          browserConsoleEvents.filter((event) => event.type === 'error').length ===
            consoleErrorsBeforeChangedKey &&
          preExistingConsoleErrorsRecoveredByAuthRefresh,
        `${routeLabel} changed-key rejection emitted a new browser error or left an unexpected prior console error`);
        console.log(`stage: changed ${changedHop.label} key failed closed before authentication at that hop`,
          JSON.stringify({ relayTicketAttempts: ticketAttempts.length,
            everyTicketTargetsBastionA: ticketAttempts.every(Boolean),
            relaySocketAttempts: ticketAttempts.length,
            authenticatedEarlierHops: earlierHops,
            changedAndLaterHopsUnauthenticated: [changedHop.key, ...laterHops],
            browserPageErrors: pageErrors.length,
            browserConsoleErrorsBeforeChangedKey: consoleErrorsBeforeChangedKey,
            newBrowserConsoleErrors: browserConsoleEvents.filter((event) =>
              event.type === 'error').length - consoleErrorsBeforeChangedKey }));
      } finally {
        if (changedHopProcess) await stopGroup(changedHopProcess);
        const originalProcess = startSshd(
          changedHop.configPath,
          tempRoot,
          changedHop.instance,
        );
        changedHop.setProcess(originalProcess);
        await waitForPort(address, changedHop.port, originalProcess);
      }

      safeRunStage = `focused ${routeLabel} sync payload and encrypted storage privacy scan`;
      const profileBHostSyncEvidence = secretSyncPrivacy.checks.filter((check) =>
        check.profile === 'B' && check.direction === 'response' &&
        check.kind === 'changes');
      const privacyMarkers = secretSyncPrivacyMarkers();
      const serverStorageFiles = [
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
      ];
      const serverStorageScans = privacyMarkers.map((marker) =>
        fileMarkerAbsenceEvidence(serverStorageFiles, marker));
      const unsafeSyncChecks = secretSyncPrivacy.checks.filter((check) => !check.markerAbsent);
      console.log(`${routeLabel} privacy scan safe diagnostic`, JSON.stringify({
        profileBChangesResponses: profileBHostSyncEvidence.length,
        profileBChangesUnsafeCount: profileBHostSyncEvidence.filter((check) =>
          !check.markerAbsent).length,
        totalSyncChecks: secretSyncPrivacy.checks.length,
        unsafeSyncCheckCount: unsafeSyncChecks.length,
        unsafeSyncCheckKinds: unsafeSyncChecks.map((check) => ({
          profile: check.profile,
          direction: check.direction,
          kind: check.kind,
        })),
        markerScanCount: serverStorageScans.length,
        markerScanResults: serverStorageScans.map((scan, markerIndex) => ({
          markerIndex,
          scannedFiles: scan.scannedFiles,
          markerAbsent: scan.plaintextMarkerAbsent,
        })),
      }));
      assertThat(profileBHostSyncEvidence.length > 0 &&
        profileBHostSyncEvidence.every((check) => check.markerAbsent),
      'profile B SSH-record sync response exposed a private-key or Credential-secret marker');
      assertThat(secretSyncPrivacy.checks.length > 0 &&
        secretSyncPrivacy.checks.every((check) => check.markerAbsent),
      'an SSH Credential private-key or secret marker appeared in a sync request or response');
      assertThat(serverStorageScans.length >= 5 &&
        serverStorageScans.every((scan) => scan.scannedFiles > 0 &&
          scan.plaintextMarkerAbsent),
      'SSH private-key or Credential-secret plaintext appeared in server SQLite storage');
      assertThat(pageErrors.length === 0 &&
        browserConsoleEvents.filter((event) => event.type === 'error').length ===
          consoleErrorsBeforeChangedKey,
      `${routeLabel} acceptance emitted a new browser page or console error`);
      console.log(`stage: ${routeLabel} SSH records stayed encrypted across profile sync and server storage`,
        JSON.stringify({ profileBChangesResponses: profileBHostSyncEvidence.length,
          totalSyncPrivacyChecks: secretSyncPrivacy.checks.length,
          allSensitiveMarkersAbsent: true,
          serverStorageMarkerScans: serverStorageScans.length,
          sqliteFilesScannedPerMarker: serverStorageScans[0]?.scannedFiles ?? 0,
          browserPageErrors: pageErrors.length,
          browserConsoleErrorsBeforeChangedKey: consoleErrorsBeforeChangedKey,
          newBrowserConsoleErrorsSinceChangedKey: browserConsoleEvents.filter((event) =>
            event.type === 'error').length - consoleErrorsBeforeChangedKey }));
      assertRelayPageUnchanged(otherPageSnapshot, `complete ${routeLabel} acceptance`);
    };
    console.log(focusedOneHopOnly
      ? 'stage: encrypted one-hop bastion and Target Hosts saved'
      : 'stage: encrypted one-hop and two-hop Hosts saved with distinct credentials',
    JSON.stringify({ bastionBReferencesA: true, targetReferencesB: true }));
    let firstRelaySocket = null;
    if (!deepHopOnly) {
    sshdBeforeRelay = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
    jumpSshdBeforeRelay = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    secondTargetSshdBeforeRelay = sshdRuntimeSummary(
      path.join(tempRoot, 'sshd-target-b.log'),
    );
    safeRunStage = 'relay SSH host-key verification';
    const relayDiagnosticInputs = {
      page,
      apiEvents,
      requestFailures,
      browserConsoleEvents,
      sshDiagnostics,
      xtermInputDiagnostics,
      relaySockets,
      pageErrors,
      relayTicketTargetChecks,
      sshdBeforeRelay,
      sshdLogPath: path.join(tempRoot, 'sshd.log'),
      jumpSshdBeforeRelay,
      jumpSshdLogPath: path.join(tempRoot, 'jump-sshd.log'),
      dbPath: path.join(dataDir, 'atermius.db'),
      serverProcess,
      sshdProcess,
      jumpSshdProcess,
    };
    try {
      await hostCard.getByRole('button', { name: 'Connect', exact: true }).click({ timeout: 15000 });
    } catch (error) {
      const diagnostic = await relayFailureDiagnostic({
        ...relayDiagnosticInputs,
        error,
        phase: 'connect_button_click_failed',
      });
      console.log('SSH Connect click diagnostic', redactCurrentSecrets(JSON.stringify(diagnostic, null, 2)));
      throw new Error('SSH Connect action failed before host-key signal');
    }

    let sshTrustSignal = null;
    let approvedHostKeyPrompts = 0;
    try {
      while (approvedHostKeyPrompts < 2) {
        sshTrustSignal = await waitForSshTrustOrError(page, 60000);
        if (sshTrustSignal !== 'host_key_prompt') break;
        const expectedPromptEndpoint = approvedHostKeyPrompts === 0
          ? `${address}:${bastionPort}`
          : `${targetAddress}:${sshPort}`;
        const promptMatchesExpectedHop = await visibleSshTrustPromptMatchesEndpoint(
          page,
          expectedPromptEndpoint,
        );
        console.log('SSH host-key prompt hop safe evidence', JSON.stringify({
          promptIndex: approvedHostKeyPrompts,
          expectedBastionPrompt: approvedHostKeyPrompts === 0,
          expectedTargetPrompt: approvedHostKeyPrompts === 1,
          promptMatchesExpectedHop,
        }));
        assertThat(promptMatchesExpectedHop,
          'SSH host-key prompt endpoint did not match the expected route hop');
        const promptToken = await sshTrustPromptToken(page);
        await click(page, 'Trust after verification');
        approvedHostKeyPrompts += 1;
        await waitForSshTrustPromptAdvance(page, promptToken, 60000);
      }
    } catch (error) {
      const diagnostic = await relayFailureDiagnostic({
        ...relayDiagnosticInputs,
        error,
        phase: 'ssh_trust_signal_poll_failed',
      });
      console.log('SSH trust polling diagnostic', redactCurrentSecrets(JSON.stringify(diagnostic, null, 2)));
      throw new Error('SSH trust signal polling failed');
    }
    if (approvedHostKeyPrompts !== 2) {
      const diagnostic = {
        sshUiSignal: sshTrustSignal,
        approvedHostKeyPrompts,
        sshdPreflight: {
          bannerStartsWithSsh20: sshBannerPreflightPassed,
          readinessProbe: sshdDiagnosticDelta(sshdBeforePortProbe, sshdAfterPortProbe),
          bannerProbe: sshdDiagnosticDelta(sshdAfterPortProbe, sshdAfterBannerProbe),
        },
        ...(await relayFailureDiagnostic({
          ...relayDiagnosticInputs,
          error: null,
          phase: 'host_key_prompt_not_visible',
        })),
      };
      console.log('SSH host trust diagnostic', redactCurrentSecrets(JSON.stringify(diagnostic, null, 2)));
      throw new Error('independent bastion and target SSH host-key prompts were not both visible');
    }
    safeRunStage = 'relay SSH terminal connected state';
    try {
      const terminalOutcome = await waitForTerminalConnectionOrTrust(page, hostName, 100000);
      assertThat(terminalOutcome === 'connected',
        `relay SSH terminal ended in ${terminalOutcome} state before CONNECTED`);
      await waitText(page, `${user}@${targetAddress}`);
    } catch (error) {
      const diagnostic = await relayFailureDiagnostic({
        ...relayDiagnosticInputs,
        error,
        phase: 'connected_terminal_ui_wait_failed',
      });
      console.log('SSH connected UI diagnostic', redactCurrentSecrets(JSON.stringify(diagnostic, null, 2)));
      throw new Error('SSH connected terminal did not become visible');
    }
    assertThat(apiEvents.some((event) => event.status === 200), 'Web UI did not receive a Relay ticket');
    assertThat(relayTicketTargetChecks.length > 0 && relayTicketTargetChecks.every(Boolean),
      'Relay ticket request targeted anything other than the allowlisted bastion endpoint');
    const targetSshdAfterFirstConnection = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
    const jumpSshdAfterFirstConnection = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    assertThat(sshdDiagnosticDelta(sshdBeforeRelay, targetSshdAfterFirstConnection).publicKeyAccepted > 0 &&
      sshdDiagnosticDelta(jumpSshdBeforeRelay, jumpSshdAfterFirstConnection).publicKeyAccepted > 0,
    'the target and bastion did not independently accept their configured SSH keys');
    firstRelaySocket = relaySockets.at(-1);
    assertThat(firstRelaySocket?.opened && !firstRelaySocket.closed,
      'first Relay terminal socket was not active');
    console.log('stage: encrypted bastion/target Hosts saved and both independent host keys trusted');
    }

    if (webUpdateOnly) {
      await runWebUpdateLifecycleWithDiagnostics({
        page,
        tempRoot,
        hostName,
        createPendingMutation: async (name) => createSshHost(page, {
          name,
          address: '203.0.113.88',
          port: sshPort,
          username: user,
          credentialName,
          credentialId,
        }),
        relaySockets: () => relaySocketsForPage(page),
        pageErrors,
        browserConsoleEvents,
        requestFailures,
        redact: redactCurrentSecrets,
        setStage: (stage) => { safeRunStage = stage; },
      });
      return;
    }

    if (portForwardOnly) {
      safeRunStage = 'profile A keeps its SSH connection active before saving a forwarding profile';
      await terminalTabButton(page, hostName, 'active');
      await waitText(page, 'CONNECTED');
      portForwardProfileName =
        `WEB_PORT_FORWARD_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      portForwardBindPort = await unusedPort();
      const listenerBeforeSave = await loopbackTcpListenerEvidence(portForwardBindPort);
      assertThat(!listenerBeforeSave.listening,
        'chosen loopback profile port unexpectedly had a listener before the test');
      portForwardSyncPrivacy.active = true;
      portForwardSyncPrivacy.marker = portForwardProfileName;
      portForwardAExecutionBaseline = {
        relayTickets: relayTicketTargetChecks.length,
        relaySockets: relaySockets.length,
        apiRequests: apiRequests.length,
        targetSshd: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
        bastionSshd: sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
        sshForwardingRequests: sshForwardingRequestCount([
          path.join(tempRoot, 'sshd.log'),
          path.join(tempRoot, 'jump-sshd.log'),
        ]),
      };
      safeRunStage = 'profile A opens the connected Host forwarding profile manager';
      await click(page, 'SSH port forwarding');
      await waitText(page, 'SSH port forwarding');
      await waitText(page,
        'This browser cannot open the local TCP listeners required to run port forwarding.');
      safeRunStage = 'profile A creates a dynamic Host forwarding profile';
      await click(page, 'Add profile');
      await waitText(page, 'Add forwarding profile');
      await fill(page, 'Profile name', portForwardProfileName);
      await selectFormOption(page, 'Forward type', 'Dynamic SOCKS5');
      await fill(page, 'Port', String(portForwardBindPort));
      await waitForVisibleSemanticsText(page,
        'SOCKS5 CONNECT only, no SOCKS user authentication.');
      await click(page, 'Save encrypted profile');
      portForwardAUiEvidence = await verifyWebPortForwardDialog(page, 'profile A', true);
      await waitForVisibleSemanticsText(page,
        'Dynamic forwarding is a loopback-only SOCKS5 CONNECT proxy without SOCKS authentication.');
      safeRunStage = 'profile A closes the profile manager without starting forwarding';
      await click(page, 'Close');
      await waitText(page, 'CONNECTED');
      const listenerAfterSave = await loopbackTcpListenerEvidence(portForwardBindPort);
      assertThat(!listenerAfterSave.listening,
        'profile A Web save unexpectedly opened its loopback listener');
      console.log('stage: connected profile A saved an encrypted dynamic Host profile while Web showed runtime unavailable',
        JSON.stringify({ ...portForwardAUiEvidence, listenerOpened: false }));
    }

    safeRunStage = 'sync Relay Host, Credential, and KnownHost records before enrolling profile B';
    await syncNow(page);
    if (portForwardOnly) {
      safeRunStage = 'profile A verifies encrypted forwarding profile sync payloads';
      await page.waitForTimeout(250);
      const aPushRequests = portForwardSyncPrivacy.checks.filter((check) =>
        check.profile === 'A' && check.direction === 'request' && check.kind === 'push');
      const aPushResponses = portForwardSyncPrivacy.checks.filter((check) =>
        check.profile === 'A' && check.direction === 'response' && check.kind === 'push');
      assertThat(aPushRequests.length > 0 && aPushRequests.every((check) => check.markerAbsent),
        'profile A sync push request exposed the forwarding profile plaintext marker');
      assertThat(aPushResponses.some((check) => check.status === 200 && check.markerAbsent),
        'profile A sync push response did not safely accept the encrypted Host update');
      const storageEvidence = fileMarkerAbsenceEvidence([
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
      ], portForwardProfileName);
      assertThat(storageEvidence.scannedFiles > 0 && storageEvidence.plaintextMarkerAbsent,
        'server SQLite storage or sidecars contain the forwarding profile plaintext marker');
      const targetAfterProfileSync = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const bastionAfterProfileSync = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const targetDelta = safeCounterDelta(portForwardAExecutionBaseline.targetSshd,
        targetAfterProfileSync, ['tcpConnectionsAccepted', 'publicKeyAccepted',
          'sessionOpenRequests', 'sessionStarts']);
      const bastionDelta = safeCounterDelta(portForwardAExecutionBaseline.bastionSshd,
        bastionAfterProfileSync, ['tcpConnectionsAccepted', 'publicKeyAccepted',
          'sessionOpenRequests', 'sessionStarts']);
      const unexpectedApiRequests = apiRequests
        .slice(portForwardAExecutionBaseline.apiRequests)
        .filter((request) => /relay\/tickets|forward|tunnel/i.test(request.path));
      assertThat(relayTicketTargetChecks.length === portForwardAExecutionBaseline.relayTickets &&
        relaySockets.length === portForwardAExecutionBaseline.relaySockets &&
        unexpectedApiRequests.length === 0 &&
        Object.values(targetDelta).every((value) => value === 0) &&
        Object.values(bastionDelta).every((value) => value === 0) &&
        sshForwardingRequestCount([
          path.join(tempRoot, 'sshd.log'),
          path.join(tempRoot, 'jump-sshd.log'),
        ]) === portForwardAExecutionBaseline.sshForwardingRequests,
      'profile A save or sync issued an SSH/Relay forwarding execution request');
      console.log('stage: profile A Host profile pushed only as opaque encrypted sync data',
        JSON.stringify({
          pushRequestCount: aPushRequests.length,
          acceptedPushResponse: aPushResponses.some((check) => check.status === 200),
          serverStorageMarkerAbsent: storageEvidence.plaintextMarkerAbsent,
          relayTicketDelta: relayTicketTargetChecks.length -
            portForwardAExecutionBaseline.relayTickets,
          relayWebSocketDelta: relaySockets.length - portForwardAExecutionBaseline.relaySockets,
          sshForwardingRequestDelta: sshForwardingRequestCount([
            path.join(tempRoot, 'sshd.log'),
            path.join(tempRoot, 'jump-sshd.log'),
          ]) - portForwardAExecutionBaseline.sshForwardingRequests,
        }));
    }
    secondContext = await browser.newContext({
      locale: 'en-US',
      viewport: { width: 1440, height: 1000 },
      acceptDownloads: true,
    });
    await secondContext.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
    await installFlutterProbe(secondContext);
    await installRelayCloseObserver(secondContext);
    secondPage = await secondContext.newPage();
    await secondPage.addInitScript(() => {
      const NativeWebSocket = window.WebSocket;
      window.__atermiusTestCollaborationSockets = [];
      window.WebSocket = new Proxy(NativeWebSocket, {
        construct(target, args, newTarget) {
          const socket = Reflect.construct(target, args, newTarget);
          try {
            const path = new URL(String(args[0]), window.location.href).pathname;
            if (path === '/collaboration/v1/connect') {
              window.__atermiusTestCollaborationSockets.push(socket);
            }
          } catch (_) {}
          return socket;
        },
      });
    });
    secondPage.on('pageerror', (error) => pageErrors.push(safeErrorSummary(error)));
    secondPage.on('crash', () => { secondPageCrashCount += 1; });
    secondPage.on('response', async (response) => {
      try {
        const url = new URL(response.url());
        if (terminalCollaborationPrivacy.active &&
            url.pathname.includes('/terminal-sessions')) {
          const body = await response.text().catch(() => null);
          recordTerminalCollaborationHttp(
            'response', 'B', response.request(), body,
          );
        }
        if (!url.pathname.startsWith('/api/v1/')) return;
        const event = {
          path: safeApiRoute(url.pathname),
          method: safeBrowserHttpMethod(response.request().method()),
          status: response.status(),
        };
        apiResponseDiagnostics.push({
          profile: 'B',
          path: event.path,
          method: event.method,
          status: event.status,
          capturedAtMs: performance.now(),
        });
        if (response.status() >= 400) {
          try {
            const body = await response.json();
            const code = body?.error?.code;
            if (typeof code === 'string' && /^[A-Z0-9_]{1,80}$/.test(code)) {
              event.errorCode = code;
            }
          } catch (_) {}
        }
        secondApiEvents.push(event);
        if (secretSyncPrivacy.active) {
          const method = response.request().method();
          const kind = method === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : method === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const bodyText = await response.text().catch(() => null);
            secretSyncPrivacy.checks.push({
              profile: 'B',
              direction: 'response',
              kind,
              markerAbsent: secretSyncPrivacyBodyIsSafe(bodyText),
            });
          }
        }
        if (portForwardSyncPrivacy.active) {
          const method = response.request().method();
          const kind = method === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : method === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = await response.text().catch(() => null);
            let eventCount = null;
            try {
              const decoded = JSON.parse(body);
              if (Array.isArray(decoded?.events)) eventCount = decoded.events.length;
            } catch (_) {}
            portForwardSyncPrivacy.checks.push({
              profile: 'B',
              direction: 'response',
              kind,
              status: response.status(),
              markerAbsent: body !== null && !body.includes(portForwardSyncPrivacy.marker),
              eventCount,
            });
          }
        }
        if (snippetRelaySync.active && response.status() === 200 &&
            response.request().method() === 'GET' &&
            url.pathname.endsWith('/changes')) {
          try {
            const body = await response.json();
            const serialized = stableJson(body);
            const plaintextMarkersAbsent = [
              snippetRelaySync.titleMarker,
              snippetRelaySync.secretMarker,
            ].filter(Boolean).every((marker) => !serialized.includes(marker));
            const pulledOperations = [];
            for (const item of body?.events || []) {
              const envelope = item?.envelope;
              const header = envelope?.header || {};
              if (typeof header.op_id !== 'string' ||
                  typeof header.record_id !== 'string' ||
                  typeof header.revision_id !== 'string') continue;
              pulledOperations.push({
                ...snippetSyncOperation(envelope),
                vaultId: header.vault_id,
                plaintextMarkersAbsent,
              });
            }
            snippetRelaySync.pullResponses.push({
              vaultIdInPath: url.pathname.split('/').at(-2),
              plaintextMarkersAbsent,
              eventCount: Array.isArray(body?.events) ? body.events.length : 0,
              pulledOperations,
            });
          } catch (_) {}
        }
      } catch (_) {}
    });
    secondPage.on('request', (request) => {
      try {
        const url = new URL(request.url());
        captureTerminalCollaborationRequestContext(secondPage, request);
        recordTerminalCollaborationHttp(
          'request', 'B', request, request.postData(),
        );
        if (url.pathname.startsWith('/api/v1/')) {
          secondApiRequests.push({
            path: safeApiRoute(url.pathname),
            method: request.method(),
          });
        }
        if (secretSyncPrivacy.active) {
          const kind = request.method() === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : request.method() === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = kind === 'push' ? request.postData() : request.url();
            secretSyncPrivacy.checks.push({
              profile: 'B',
              direction: 'request',
              kind,
              markerAbsent: secretSyncPrivacyBodyIsSafe(body),
            });
          }
        }
        if (portForwardSyncPrivacy.active) {
          const kind = request.method() === 'POST' && url.pathname.endsWith('/sync/push')
            ? 'push'
            : request.method() === 'GET' && url.pathname.endsWith('/changes')
              ? 'changes'
              : null;
          if (kind) {
            const body = kind === 'push' ? request.postData() : request.url();
            portForwardSyncPrivacy.checks.push({
              profile: 'B',
              direction: 'request',
              kind,
              markerAbsent: body !== null && !body.includes(portForwardSyncPrivacy.marker),
            });
          }
          if (url.origin !== new URL(baseUrl).origin) {
            portForwardSyncPrivacy.checks.push({
              profile: 'B',
              direction: 'request',
              kind: 'cross_origin',
              markerAbsent: true,
            });
          }
        }
        if (url.pathname === '/api/v1/relay/tickets') {
          const body = JSON.parse(request.postData() || '{}');
          recordRelayTicketTargetCheck(secondPage,
            body.target_host === address && body.target_port === bastionPort,
          );
        }
      } catch (_) {
        if (request.url().includes('/api/v1/relay/tickets')) {
          recordRelayTicketTargetCheck(secondPage, false);
        }
      }
    });
    secondPage.on('request', (request) => {
      requestStartByRequest.set(request, safeBrowserRequestStart(safeRunStage));
    });
    secondPage.on('requestfailed', (request) => {
      try {
        const failure = safeBrowserRequestFailure(
          request, baseUrl, safeRunStage, ++browserDiagnosticSequence,
          requestStartByRequest.get(request),
        );
        secondRequestFailures.push(failure);
        requestFailureDiagnostics.push({
          profile: 'B',
          ...failure,
          capturedAtMs: performance.now(),
        });
      } catch (_) {
        const failure = {
          sequence: ++browserDiagnosticSequence,
          path: '/{unavailable}',
          originCategory: 'invalid_url',
          method: 'OTHER',
          resourceType: 'other',
          navigation: null,
          responseReceived: false,
          httpStatus: null,
          failurePhase: 'before_http_response',
          failureDetailsAvailable: false,
          failureCategory: 'unknown',
          failureCode: 'unavailable',
          ...safeBrowserStage(safeRunStage),
        };
        secondRequestFailures.push(failure);
        requestFailureDiagnostics.push({
          profile: 'B',
          ...failure,
          capturedAtMs: performance.now(),
        });
      }
    });
    secondPage.on('websocket', (websocket) => {
      const url = new URL(websocket.url());
      if (url.pathname === '/collaboration/v1/connect') {
        trackTerminalCollaborationSocket(secondPage, websocket);
        return;
      }
      if (url.pathname !== '/relay/v1/connect') return;
      const event = { path: url.pathname, page: secondPage, opened: true, closed: false, sentFrames: [], receivedFrames: [], socketError: false, websocketRef: websocket };
      relaySockets.push(event);
      relaySocketsForPage(secondPage).push(event);
      const summarizeFrame = (payload) => ({
        kind: typeof payload === 'string' ? 'text' : 'binary',
        bytes: typeof payload === 'string' ? Buffer.byteLength(payload) : payload.length,
      });
      websocket.on('framesent', ({ payload }) => event.sentFrames.push(summarizeFrame(payload)));
      websocket.on('framereceived', ({ payload }) => event.receivedFrames.push(summarizeFrame(payload)));
      websocket.on('socketerror', () => { event.socketError = true; });
      websocket.on('close', () => { event.closed = true; });
    });
    const secondRootResponse = await secondPage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
    assertThat(secondRootResponse && secondRootResponse.status() === 200,
      'second browser profile root navigation failed');
    await enableSemantics(secondPage);
    safeRunStage = 'profile B Server URL field';
    await fill(secondPage, 'Server URL', baseUrl);
    const secondServerUrlField = await field(secondPage, 'Server URL');
    console.log('Profile B server URL after fill safe evidence',
      JSON.stringify(await safeServerUrlInputEvidence(secondServerUrlField, baseUrl)));
    safeRunStage = 'profile B secure server connection';
    const connectSecondButton = await button(secondPage, 'Connect securely');
    const requestsBeforeSecondConnect = secondApiRequests.length;
    await secondPage.evaluate(() => {
      window.__atermiusConnectClick = null;
      document.addEventListener('click', (event) => {
        const target = event.target instanceof Element
          ? event.target.closest('flt-semantics[role="button"]')
          : null;
        if (target?.innerText?.includes('Connect securely')) {
          window.__atermiusConnectClick = {
            trusted: event.isTrusted,
            defaultPrevented: event.defaultPrevented,
            ariaLabel: target.getAttribute('aria-label'),
            ariaDisabled: target.getAttribute('aria-disabled'),
            pointerEvents: getComputedStyle(target).pointerEvents,
          };
        }
      }, true);
    });
    let secondConnectAttempts = 0;
    while (secondConnectAttempts < 3) {
      if (secondConnectAttempts > 0 &&
          (secondApiRequests.length !== requestsBeforeSecondConnect ||
            !await connectSecondButton.isEnabled().catch(() => false))) {
        break;
      }
      await connectSecondButton.click();
      secondConnectAttempts += 1;
      await secondPage.waitForTimeout(500);
      console.log('Profile B server URL after button attempt safe evidence', JSON.stringify({
        attempt: secondConnectAttempts,
        ...await safeServerUrlInputEvidence(secondServerUrlField, baseUrl),
      }));
      if (secondApiRequests.length !== requestsBeforeSecondConnect) break;
      if (secondConnectAttempts < 3 &&
          await connectSecondButton.isEnabled().catch(() => false)) {
        console.log('Profile B connection tap safe recovery', JSON.stringify({
          retryCount: secondConnectAttempts,
          apiRequestsStarted: false,
          buttonStillEnabled: true,
        }));
      }
    }
    let secondConnectHitEvidence = null;
    let secondConnectFallback = null;
    let serverUrlSubmitFallback = false;
    if (secondApiRequests.length === requestsBeforeSecondConnect &&
        await connectSecondButton.isEnabled().catch(() => false)) {
      secondConnectHitEvidence = await secondPage.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            rect.bottom > 0 && rect.right > 0 &&
            rect.top < window.innerHeight && rect.left < window.innerWidth &&
            style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0;
        };
        const candidates = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => visible(element) &&
            (element.getAttribute('aria-label') || element.innerText || '')
              .includes('Connect securely'));
        if (candidates.length !== 1) return { candidateCount: candidates.length };
        const target = candidates[0];
        const rect = target.getBoundingClientRect();
        const x = Math.round(rect.left + rect.width / 2);
        const y = Math.round(rect.top + rect.height / 2);
        const hit = document.elementFromPoint(x, y);
        const hitButton = hit?.closest('flt-semantics[role="button"]') || null;
        return {
          candidateCount: 1,
          centerVisible: true,
          hitIsTarget: Boolean(hit && (
            hit === target || target.contains(hit) || hit.contains(target)
          )),
          hitClassification: hitButton ? 'button-semantics' :
            hit?.closest('flt-semantics') ? 'other-semantics' :
            hit ? 'other-dom' : 'no-element',
          x,
          y,
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      if (secondConnectHitEvidence.hitIsTarget === true) {
        await secondPage.mouse.click(
          secondConnectHitEvidence.x,
          secondConnectHitEvidence.y,
        );
        secondConnectFallback = 'pointer-center';
        await secondPage.waitForTimeout(500);
      }
      if (secondApiRequests.length === requestsBeforeSecondConnect &&
          await connectSecondButton.isEnabled().catch(() => false)) {
        await connectSecondButton.focus().catch(() => {});
        await connectSecondButton.press('Enter').catch(() => {});
        secondConnectFallback = secondConnectFallback
          ? `${secondConnectFallback}+enter`
          : 'enter';
        const submitDeadline = Date.now() + 3000;
        while (Date.now() < submitDeadline &&
            secondApiRequests.length === requestsBeforeSecondConnect) {
          await secondPage.waitForTimeout(100);
        }
      }
      // The URL TextField's Enter handler invokes the same secure configure
      // path as its sibling button. Use it as a final real-input fallback for
      // intermittent Flutter Web semantics clicks that reach the DOM but do
      // not dispatch the widget callback.
      if (secondApiRequests.length === requestsBeforeSecondConnect) {
        await enterExactServerUrlWithKeyboard(
          secondPage,
          secondServerUrlField,
          baseUrl,
          'Profile B',
        );
        await connectSecondButton.click();
        const submitDeadline = Date.now() + 10000;
        while (Date.now() < submitDeadline &&
            secondApiRequests.length === requestsBeforeSecondConnect) {
          await secondPage.waitForTimeout(100);
        }
        if (secondApiRequests.length === requestsBeforeSecondConnect) {
          await serverUrlField.focus().catch(() => {});
          await serverUrlField.press('Enter').catch(() => {});
          serverUrlSubmitFallback = true;
          const enterDeadline = Date.now() + 5000;
          while (Date.now() < enterDeadline &&
              secondApiRequests.length === requestsBeforeSecondConnect) {
            await secondPage.waitForTimeout(100);
          }
        }
      }
    }
    console.log('Profile B connection safe evidence', JSON.stringify({
      attempts: secondConnectAttempts,
      apiRequestsStarted: secondApiRequests.length !== requestsBeforeSecondConnect,
      buttonStillEnabled: await connectSecondButton.isEnabled().catch(() => false),
      clickEvidence: await secondPage.evaluate(() => window.__atermiusConnectClick)
        .catch(() => null),
      hitEvidence: secondConnectHitEvidence,
      fallback: secondConnectFallback,
      serverUrlSubmitFallback,
      connectButtonAriaDisabled: await connectSecondButton.getAttribute('aria-disabled')
        .catch(() => null),
      recentApiRoutes: secondApiRequests.slice(-3).map((request) => request.path),
      recentApiStatuses: secondApiEvents.slice(-3).map((event) => event.status),
    }));
    safeRunStage = 'profile B sign-in email field';
    try {
      await field(secondPage, 'Email or username');
    } catch (error) {
      const pageUrlEvidence = (() => {
        try {
          const actual = new URL(secondPage.url());
          const expectedOrigin = new URL(baseUrl).origin;
          const path = actual.pathname.startsWith('/api/v1/')
            ? safeApiRoute(actual.pathname)
            : actual.pathname === '/' ? '/' : '/other';
          return {
            origin: actual.origin === expectedOrigin ? 'same_origin' : 'other_origin',
            path,
          };
        } catch (_) {
          return { origin: 'unavailable', path: 'unavailable' };
        }
      })();
      const formEvidence = secondPage.isClosed()
        ? { diagnosticUnavailable: true, diagnosticErrorType: 'PageClosed' }
        : await secondPage.evaluate(() => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.display !== 'none' && style.visibility !== 'hidden';
          };
          const fieldLabels = [...document.querySelectorAll('input, textarea')]
            .filter(visible).map((element) =>
              (element.getAttribute('aria-label') || '').toLowerCase());
          const knownFields = [
            ['email_or_username', 'email or username'],
            ['owner_email', 'owner email'],
            ['server_url', 'server url'],
            ['master_password', 'master password'],
            ['password', 'password'],
          ];
          const visibleFieldCategories = knownFields
            .filter(([, label]) => fieldLabels.some((candidate) => candidate.includes(label)))
            .map(([category]) => category);
          const buttonLabels = [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter(visible).map((element) =>
              (element.getAttribute('aria-label') || element.innerText || '').toLowerCase());
          const knownButtons = [
            ['connect_securely', 'connect securely'],
            ['sign_in', 'sign in'],
            ['add_this_device', 'add this device'],
            ['create_account', 'create account'],
          ];
          const visibleButtonCategories = knownButtons
            .filter(([, label]) => buttonLabels.some((candidate) => candidate.includes(label)))
            .map(([category]) => category);
          return {
            diagnosticAvailable: true,
            visibleFieldCategories,
            visibleButtonCategories,
            visibleFieldCount: fieldLabels.length,
            visibleButtonCount: buttonLabels.length,
          };
        }).catch((diagnosticError) => ({
          diagnosticUnavailable: true,
          diagnosticErrorType: diagnosticError?.name || 'Error',
        }));
      const recentApiRequests = secondApiRequests.slice(-8).map((request) => ({
        kind: 'request',
        method: safeBrowserHttpMethod(request.method),
        path: safeApiRoute(request.path),
        status: null,
        errorCode: null,
      }));
      const recentApiResponses = secondApiEvents.slice(-8).map((event) => ({
        kind: 'response',
        method: safeBrowserHttpMethod(event.method),
        path: safeApiRoute(event.path),
        status: Number.isInteger(event.status) ? event.status : null,
        errorCode: typeof event.errorCode === 'string' && /^[A-Z0-9_]{1,80}$/.test(event.errorCode)
          ? event.errorCode
          : null,
      }));
      console.log('Profile B connection transition safe evidence', JSON.stringify({
        ...formEvidence,
        pageClosed: secondPage.isClosed(),
        pageCrashCount: secondPageCrashCount,
        pageUrl: pageUrlEvidence,
        browserConnected: browser?.isConnected() ?? false,
        recentApiRequests,
        recentApiResponses,
        browserPageErrorCount: pageErrors.length,
        fieldErrorType: error?.name || 'Error',
      }));
      throw error;
    }
    await click(secondPage, 'Add this device');
    safeRunStage = 'profile B device enrollment request';
    await waitText(secondPage, 'Request this device');
    await fill(secondPage, 'Account email', USERNAME);
      await fill(secondPage, 'Device name', profileBDeviceName);
    safeRunStage = 'profile B enrollment request copy control';
    await click(secondPage, 'Generate request');
    const enrollmentCopyButton = secondPage.getByRole('button', {
      name: 'Copy', exact: true,
    }).first();
    await enrollmentCopyButton.waitFor({ state: 'visible', timeout: 15000 });
    await enrollmentCopyButton.click();
    const enrollmentJson = await readClipboard(secondPage);
    let enrollmentFormat = null;
    try { enrollmentFormat = JSON.parse(enrollmentJson).format || null; } catch (_) {}
    assertThat(enrollmentFormat === 'atermius-device-enrollment-v1',
      'profile B did not produce a valid device enrollment request');
    await click(secondPage, 'Close');

    safeRunStage = 'profile A opens the Devices page for enrollment approval';
    await click(page, 'Devices');
    safeRunStage = 'profile A opens the enrollment review dialog';
    await click(page, 'Approve enrollment');
    safeRunStage = 'profile A imports the enrollment request';
    const enrollmentPaste = await paste(page, 'Enrollment JSON', enrollmentJson);
    assertThat(enrollmentPaste.actual === enrollmentJson,
      'profile A did not retain the copied enrollment request exactly');
    await click(page, 'Review keys');
    const approveButton = await button(page, 'Approve & seal keys');
    const approveEnabled = await approveButton.isEnabled().catch(() => false);
    const approveControl = await approveButton.evaluate((element) => ({
      tag: element.tagName,
      role: element.getAttribute('role'),
      disabled: element.getAttribute('aria-disabled'),
      visible: element.getBoundingClientRect().width > 0 &&
        element.getBoundingClientRect().height > 0,
    }));
    if (!approveEnabled) {
      console.log('profile A approval disabled safe diagnostic', JSON.stringify({
        enrollmentPasteExact: true,
        approveControl,
        apiErrorStatuses: apiEvents.filter((event) => event.status >= 400)
          .slice(-5).map((event) => event.status),
      }));
      throw new Error('profile A approval action stayed disabled after reviewing the request');
    }
    await page.evaluate(() => {
      window.__atermiusApproveClickSeen = false;
      document.addEventListener('click', (event) => {
        const target = event.target.closest('flt-semantics[role="button"]');
        if (target?.innerText?.includes('Approve & seal keys')) {
          window.__atermiusApproveClickSeen = true;
        }
      }, true);
    });
    const approvalCopy = page.getByRole('button', { name: 'Copy', exact: true }).first();
    safeRunStage = 'profile A seals device keys for profile B';
    const approvalApiRequestStart = apiRequests.length;
    let approveClickError = null;
    try {
      await approveButton.click({ timeout: 5000 });
    } catch (error) {
      approveClickError = error;
    }
    if (approveClickError) {
      const completionDeadline = Date.now() + 10000;
      while (Date.now() < completionDeadline &&
          !await approvalCopy.isVisible().catch(() => false)) {
        await page.waitForTimeout(100);
      }
      if (await approvalCopy.isVisible().catch(() => false)) {
        approveClickError = null;
      } else {
        const hitEvidence = await page.evaluate(() => {
          const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')];
          const approve = buttons.find((element) =>
            (element.getAttribute('aria-label') || element.innerText || '')
              .trim() === 'Approve & seal keys');
          if (!approve) return { approveButtonStillVisible: false };
          const rect = approve.getBoundingClientRect();
          const hit = document.elementFromPoint(
            rect.left + rect.width / 2,
            rect.top + rect.height / 2,
          );
          const hitButton = hit?.closest('flt-semantics[role="button"]') || null;
          const hitDialog = hit?.closest('[role="dialog"],flt-semantics[role="dialog"]') || null;
          return {
            approveButtonStillVisible: rect.width > 0 && rect.height > 0,
            centerVisible: rect.width > 0 && rect.height > 0 &&
              rect.bottom > 0 && rect.right > 0 &&
              rect.top < window.innerHeight && rect.left < window.innerWidth,
            hitIsTarget: Boolean(hit && (
              hit === approve || approve.contains(hit) || hit.contains(approve)
            )),
            hitClassification: hitDialog ? 'dialog-overlay' :
              hitButton ? 'other-button' :
              hit?.closest('flt-semantics') ? 'other-semantics' :
              hit ? 'other-dom' : 'no-element',
            x: Math.round(rect.left + rect.width / 2),
            y: Math.round(rect.top + rect.height / 2),
          };
        });
        console.log('profile A approval click safe diagnostic', JSON.stringify({
          approveEnabled,
          clickErrorType: approveClickError.name || 'Error',
          approvalCopyVisible: false,
          clickSeen: await page.evaluate(() => window.__atermiusApproveClickSeen === true)
            .catch(() => false),
          hitEvidence,
        }));
        if (hitEvidence.centerVisible && hitEvidence.hitIsTarget) {
          await page.mouse.click(hitEvidence.x, hitEvidence.y);
        } else {
          throw approveClickError;
        }
      }
    }
    let approvalReady = false;
    let approvalErrorVisible = false;
    const approvalDeadline = Date.now() + 10000;
    while (Date.now() < approvalDeadline) {
      await page.waitForTimeout(200);
      approvalReady = await approvalCopy.isVisible().catch(() => false);
      approvalErrorVisible = await page.evaluate(() => {
        const text = document.body.innerText || '';
        return /Bad state:|FormatException:|epoch.*不在本设备|failed|失败/i.test(text);
      }).catch(() => false);
      if (approvalReady || approvalErrorVisible) break;
    }
    let approvalPointerFallback = null;
    const approvalRequestsAfterSemanticClick = apiRequests.slice(approvalApiRequestStart)
      .filter((request) => request.method === 'POST' && request.path === '/api/v1/devices');
    if (!approvalReady && !approvalErrorVisible &&
        approvalRequestsAfterSemanticClick.length === 0) {
      const hitEvidence = await page.evaluate(() => {
        const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) =>
            (element.getAttribute('aria-label') || element.innerText || '').trim() ===
              'Approve & seal keys');
        if (buttons.length !== 1) return { candidateCount: buttons.length };
        const target = buttons[0];
        const rect = target.getBoundingClientRect();
        const visible = rect.width > 0 && rect.height > 0 && rect.bottom > 0 &&
          rect.right > 0 && rect.top < window.innerHeight &&
          rect.left < window.innerWidth && getComputedStyle(target).visibility !== 'hidden';
        if (!visible) return { candidateCount: 1, centerVisible: false };
        const x = Math.round(rect.left + rect.width / 2);
        const y = Math.round(rect.top + rect.height / 2);
        const hit = document.elementFromPoint(x, y);
        return {
          candidateCount: 1,
          centerVisible: true,
          hitIsTarget: Boolean(hit && (hit === target || target.contains(hit) || hit.contains(target))),
          hitClassification: hit?.closest('flt-semantics[role="button"]')
            ? 'button-semantics'
            : hit?.closest('flt-semantics') ? 'other-semantics'
              : hit ? 'other-dom' : 'no-element',
          x,
          y,
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      if (hitEvidence.centerVisible && hitEvidence.hitIsTarget) {
        approvalPointerFallback = 'pointer-center';
        await page.mouse.click(hitEvidence.x, hitEvidence.y);
        const fallbackDeadline = Date.now() + 15000;
        while (Date.now() < fallbackDeadline) {
          await page.waitForTimeout(200);
          approvalReady = await approvalCopy.isVisible().catch(() => false);
          approvalErrorVisible = await page.evaluate(() => {
            const text = document.body.innerText || '';
            return /Bad state:|FormatException:|epoch.*不在本设备|failed|失败/i.test(text);
          }).catch(() => false);
          const approvalRequestStarted = apiRequests.slice(approvalApiRequestStart)
            .some((request) => request.method === 'POST' && request.path === '/api/v1/devices');
          if (approvalReady || approvalErrorVisible || approvalRequestStarted) break;
        }
        if (!approvalReady && !approvalErrorVisible) {
          const responseDeadline = Date.now() + 10000;
          while (Date.now() < responseDeadline) {
            const request = apiRequests.slice(approvalApiRequestStart).find((item) =>
              item.method === 'POST' && item.path === '/api/v1/devices');
            if (!request || request.completed) break;
            await page.waitForTimeout(100);
          }
          approvalReady = await approvalCopy.isVisible().catch(() => false);
        }
      }
      const safeApprovalUi = await page.evaluate(() => {
        const body = document.body.innerText || '';
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 && style.display !== 'none' &&
            style.visibility !== 'hidden';
        };
        const texts = [...document.querySelectorAll('flt-semantics[role="alert"], [role="alert"]')]
          .filter(visible).map((element) => element.innerText || '').join('\n');
        const errorText = `${body}\n${texts}`;
        const errorCategory = /epoch.{0,100}不在本设备/i.test(errorText)
          ? 'missing-current-vault-epoch'
          : /没有所有 Vault 的密钥|epoch.{0,100}密钥缺失/i.test(errorText)
            ? 'missing-vault-key'
            : /删除宽限期/i.test(errorText)
              ? 'vault-deletion-pending'
              : /enrollment.{0,60}(invalid|another account)|申请格式错误/i.test(errorText)
                ? 'invalid-enrollment'
                : /server|服务端/i.test(errorText) && /unavailable|failed|错误|失败/i.test(errorText)
                  ? 'server-error'
                  : /failed|失败|错误|error/i.test(texts) ? 'other-visible-error' : 'none';
        return {
          approvalReviewStillVisible: body.includes('Approve & seal keys'),
          approvedConfirmationVisible: body.includes('Device approved'),
          errorCategory,
          visibleAlertCount: [...document.querySelectorAll('flt-semantics[role="alert"], [role="alert"]')]
            .filter(visible).length,
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      console.log('profile A approval no-transition safe diagnostic', JSON.stringify({
        pointerFallback: approvalPointerFallback,
        hitEvidence,
        ui: safeApprovalUi,
        newApiRoutes: apiRequests.slice(approvalApiRequestStart).map((request) => ({
          method: request.method,
          path: request.path,
          completed: request.completed,
          status: request.status,
        })),
      }));
    }
    if (!approvalReady) {
      const clickSeen = await page.evaluate(() => window.__atermiusApproveClickSeen === true)
        .catch(() => false);
      console.log('profile A approval safe diagnostic', JSON.stringify({
        approveControl,
        clickSeen,
        approvalErrorVisible,
        recentApiStatuses: apiEvents.slice(-12).map((event) => event.status),
        newApiRoutes: apiRequests.slice(approvalApiRequestStart).map((request) => ({
          method: request.method,
          path: request.path,
          completed: request.completed,
          status: request.status,
        })),
        pageErrorCount: pageErrors.length,
      }));
      throw new Error('profile A did not produce the second-device approval response');
    }
    const approvalApiRequests = apiRequests.slice(approvalApiRequestStart).filter((request) =>
      request.method === 'POST' && request.path === '/api/v1/devices');
    assertThat(approvalApiRequests.length === 1 && approvalApiRequests[0].completed &&
      approvalApiRequests[0].status >= 200 && approvalApiRequests[0].status < 300,
    'profile A approval did not produce exactly one successful device registration response');
    console.log('profile A sealed the profile B device keys', JSON.stringify({
      approvalCopyVisible: true,
      approvalButtonEnabledBeforeClick: approveEnabled,
    }));
    safeRunStage = 'profile A copies sealed device approval';
    await approvalCopy.click();
    safeRunStage = 'profile A reads sealed device approval from clipboard';
    const approvalJson = await readClipboard(page);
    safeRunStage = 'profile A validates sealed device approval format';
    assertThat(approvalJson.includes('atermius-device-approval-v1'),
      'profile A did not generate a valid approval for profile B');
    safeRunStage = 'profile A closes device approval dialog';
    await click(page, 'Done');
    safeRunStage = 'profile A returns to Hosts';
    await click(page, 'Hosts');
    safeRunStage = 'profile A Hosts page is visible';
    await button(page, 'Add host');
    safeRunStage = 'profile A reactivates its connected terminal tab';
    await click(page, 'Terminal');
    if (!deepHopOnly) {
      const activeProfileATab = page.getByRole('button', {
        name: `${hostName} terminal tab, connected, active`, exact: true,
      });
      const inactiveProfileATab = page.getByRole('button', {
        name: `${hostName} terminal tab, connected, inactive`, exact: true,
      });
      const tabDeadline = Date.now() + 30000;
      let activeProfileATabCount = 0;
      let inactiveProfileATabCount = 0;
      while (Date.now() < tabDeadline &&
          activeProfileATabCount + inactiveProfileATabCount === 0) {
        [activeProfileATabCount, inactiveProfileATabCount] = await Promise.all([
          activeProfileATab.count(), inactiveProfileATab.count(),
        ]);
        if (activeProfileATabCount + inactiveProfileATabCount === 0) {
          await page.waitForTimeout(200);
        }
      }
      assertThat(activeProfileATabCount + inactiveProfileATabCount === 1,
        'profile A connected terminal tab semantics were ambiguous');
      if (inactiveProfileATabCount === 1) await inactiveProfileATab.click();
      await terminalTabButton(page, hostName, 'active');
      await waitText(page, 'CONNECTED', 15000);
    }

    safeRunStage = 'profile B opens the approval import form';
    await click(secondPage, 'Import approval');
    safeRunStage = 'profile B imports the sealed device approval';
    const approvalPaste = await paste(secondPage, 'Paste approval JSON', approvalJson);
    assertThat(approvalPaste.actual === approvalJson,
      'profile B did not retain the sealed approval exactly');
    safeRunStage = 'profile B installs the approved device keys';
    await click(secondPage, 'Import device keys');
    safeRunStage = 'profile B fills the approved account identity';
    await fill(secondPage, 'Email or username', USERNAME);
    safeRunStage = 'profile B fills the master password';
    await fill(secondPage, 'Master password', MASTER_PASSWORD);
    safeRunStage = 'profile B signs in and unlocks the shared Vault';
    const signInButton = await button(secondPage, 'Sign in and unlock');
    let signInClickError = null;
    try {
      await signInButton.click({ timeout: 5000 });
    } catch (error) {
      signInClickError = error;
    }
    const workspaceAddHost = secondPage.getByRole('button', {
      name: 'Add host', exact: true,
    }).first();
    await workspaceAddHost.waitFor({ state: 'visible', timeout: 30000 });
    if (signInClickError) {
      console.log('profile B sign-in transitioned despite click timeout', JSON.stringify({
        errorType: signInClickError.name || 'Error',
        workspaceVisible: true,
      }));
    }
    safeRunStage = 'profile B opens synced Hosts';
    await button(secondPage, 'Add host');
    await click(secondPage, 'Hosts');
    safeRunStage = 'profile B syncs Hosts, Credentials, and KnownHosts';
    await syncNow(secondPage, 'profile B SSH records');
    safeRunStage = 'profile B resolves the synced Host accessibility group';
    const escapedHostName = hostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const secondDeviceSyncedHostCard = secondPage.getByRole('group', {
      name: new RegExp(escapedHostName),
    }).first();
    await secondDeviceSyncedHostCard.waitFor({ state: 'visible', timeout: 30000 });
    if (deepHopOnly) {
      const routeDepth = maxDepthHopOnly ? 8 : fourHopOnly ? 4 : 3;
      const routeHostName = maxDepthHopOnly
        ? maxDepthHostName
        : fourHopOnly ? fourHopHostName : threeHopHostName;
      safeRunStage = `profile B resolves synced ${routeDepth}-hop Host`;
      const escapedThreeHopHostName = routeHostName
        .replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const secondDeviceThreeHopHostCard = secondPage.getByRole('group', {
        name: new RegExp(escapedThreeHopHostName),
      }).first();
      await secondDeviceThreeHopHostCard.waitFor({ state: 'visible', timeout: 30000 });
      const profileBHostSyncEvidence = secretSyncPrivacy.checks.filter((check) =>
        check.profile === 'B' && check.direction === 'response' &&
        check.kind === 'changes');
      assertThat(profileBHostSyncEvidence.length > 0 &&
        profileBHostSyncEvidence.every((check) => check.markerAbsent),
      'profile B SSH-record sync response exposed a private-key or Credential-secret marker');
      console.log(`stage: profile B resolved the encrypted ${routeDepth}-hop Host chain`,
        JSON.stringify({ routeHostVisible: true,
          profileBEncryptedChangesResponses: profileBHostSyncEvidence.length,
          privateKeyAndCredentialMarkersAbsent: true }));
      await runFocusedDeepHopAcceptance(secondPage, secondDeviceThreeHopHostCard, routeDepth);
      if (maxDepthHopOnly) {
        console.log('WEB-RELAY-MAX-DEPTH-01 passed: profile B synchronized and connected an eight-Jump-Host A -> B -> C -> D -> E -> F -> G -> H -> Target route; independently approved all nine KnownHosts in order; verified every hop credential and next-hop-only forwarding ACL, A-only Relay tickets, exact Target shell placement, Target SFTP binary and UTF-8 byte matches/cleanup, disconnect, changed-H-key rejection before H/Target authentication, privacy scans, zero browser page errors, and no new console errors. Any pre-existing startup resource-load error must map to a same-profile presence or notification-ticket 401 followed by successful auth refresh and notification-ticket retry.');
      } else if (fourHopOnly) {
        console.log('WEB-RELAY-FOUR-HOP-01 passed: profile B synchronized and connected a real A -> B -> C -> D -> Target SSH route; independently approved A, B, C, D and Target KnownHosts; verified each hop credential, least-privilege forwarding, A-only Relay tickets/sockets, exact Target shell placement, Target SFTP binary and UTF-8 byte matches/cleanup, disconnect, changed-D-key rejection before D/Target authentication, privacy scans, and zero browser errors.');
      } else {
        console.log('WEB-RELAY-THREE-HOP-01 passed: profile B synchronized and connected a real A -> B -> C -> Target SSH route; independently approved A, B, C, and Target KnownHosts; verified each hop credential, A-only Relay tickets and sockets, exact Target shell placement, Target SFTP folder creation, binary and UTF-8 upload/download byte matches, remote cleanup over the unchanged Relay route, disconnect, changed-C-key rejection before C/Target authentication, privacy scans, and zero browser errors.');
      }
      return;
    }
    if (collaborationOnly) {
      safeRunStage = 'Profile A returns to the active SSH terminal';
      await terminalTabButton(page, hostName, 'active');
      const collaborationTabEvidence = await safeTerminalTabLifecycleDiagnostics(
        page, hostName, `${hostName} observer`,
      );
      const collaborationControlEvidence = await page.evaluate(() => ({
        connectedLabelVisible: (document.body.innerText || '').includes('CONNECTED'),
        shareButtonCount: [...document.querySelectorAll('[role="button"]')]
          .filter((element) => (element.getAttribute('aria-label') || '') ===
            'Share this terminal').length,
        joinButtonCount: [...document.querySelectorAll('[role="button"]')]
          .filter((element) => (element.getAttribute('aria-label') || '') ===
            'Join a shared terminal').length,
      })).catch(() => ({ diagnosticUnavailable: true }));
      console.log('Profile A pre-share safe UI evidence', JSON.stringify({
        tabs: collaborationTabEvidence,
        controls: collaborationControlEvidence,
        instance: apiEvents.filter((event) => event.path === '/api/v1/instance')
          .at(-1) || null,
      }));
      safeRunStage = 'Profile A locates the live-share control';
      const shareStart = page.getByRole('button', {
        name: 'Share this terminal', exact: true,
      });
      await shareStart.waitFor({ state: 'visible', timeout: 15000 });
      const sshdBeforeCollaboration = {
        target: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
        bastion: sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
      };
      const aRelayTicketBaseline = relayTicketChecksForPage(page).length;
      const aRelaySocketBaseline = relaySocketsForPage(page).length;
      const aRelaySocketsBeforeCollaboration =
        relaySocketsForPage(page).slice();
      const aOpenRelaySocketsBeforeCollaboration =
        aRelaySocketsBeforeCollaboration.filter((socket) =>
          socket.opened && !socket.closed);
      const bRelayTicketBaseline = relayTicketChecksForPage(secondPage).length;
      const bRelaySocketBaseline = relaySocketsForPage(secondPage).length;
      const aCollaborationSocketBaseline =
        terminalCollaborationSocketsForPage(page).length;
      const bCollaborationSocketBaseline =
        terminalCollaborationSocketsForPage(secondPage).length;
      let targetPrivateKey = fs.readFileSync(userKey.privateKey, 'utf8')
        .replace(/[\r\n]+$/, '');
      let bastionPrivateKey = fs.readFileSync(jumpUserKey.privateKey, 'utf8')
        .replace(/[\r\n]+$/, '');
      const terminalShareMarker =
        `WEB_TERMINAL_COLLAB_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const privateKeyHeader = '-----BEGIN EC PRIVATE KEY-----';
      terminalCollaborationPrivacy.active = true;
      terminalCollaborationPrivacy.markers = [
        terminalShareMarker, targetPrivateKey, bastionPrivateKey,
        privateKeyHeader,
      ];

      safeRunStage = 'Profile A opens the approved-device picker';
      const aApiEventBaseline = apiEvents.length;
      await shareStart.click();
      safeRunStage = 'Profile A waits for the approved-device picker';
      try {
        await waitText(page, 'Choose active Vault devices', 15000);
      } catch (error) {
        const pickerEvidence = await page.evaluate(() => {
          const text = document.body.innerText || '';
          return {
            sharePickerDescriptionVisible: text.includes('Choose active Vault devices'),
            noEligibleDeviceNoticeVisible: text.includes(
              'No other active Vault devices can receive this terminal share.',
            ),
            startSharingActionVisible: text.includes('Start sharing'),
            dialogRoleCount: document.querySelectorAll('[role="dialog"]').length,
            snackbarRoleCount: document.querySelectorAll('[role="alert"], [role="status"]').length,
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        console.log('Profile A device-picker safe failure evidence', JSON.stringify({
          picker: pickerEvidence,
          api: apiEvents.slice(aApiEventBaseline).map((event) => ({
            path: event.path,
            status: event.status,
            errorCode: event.errorCode,
            vaultDeviceCount: event.vaultDeviceCount,
            activeVaultDeviceCount: event.activeVaultDeviceCount,
            activeDeviceKeyShapeCount: event.activeDeviceKeyShapeCount,
            activeDeviceKey32ByteCount: event.activeDeviceKey32ByteCount,
            vaultMemberCount: event.vaultMemberCount,
            activeVaultMemberCount: event.activeVaultMemberCount,
          })),
        }));
        throw error;
      }
      assertThat(await page.getByRole('checkbox', {
        name: 'Enable host-approved input control', exact: false,
      }).getAttribute('aria-checked') === 'false',
      'existing terminal sharing did not default to the v1 read-only room');
      const profileBDeviceChoice = page.getByRole('checkbox', {
        name: new RegExp(profileBDeviceName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
      }).last();
      safeRunStage = 'Profile A locates the approved Profile B device';
      const directoryEvidence = () => apiEvents.slice(aApiEventBaseline).map((event) => ({
        path: event.path,
        status: event.status,
        errorCode: event.errorCode,
        vaultDeviceCount: event.vaultDeviceCount,
        activeVaultDeviceCount: event.activeVaultDeviceCount,
        activeDeviceKey32ByteCount: event.activeDeviceKey32ByteCount,
        activeDeviceNameMatchesExpectedCount: event.activeDeviceNameMatchesExpectedCount,
        vaultMemberCount: event.vaultMemberCount,
        activeVaultMemberCount: event.activeVaultMemberCount,
      }));
      try {
        await profileBDeviceChoice.waitFor({ state: 'visible', timeout: 15000 });
      } catch (error) {
        const expectedDeviceName = profileBDeviceName;
        const matchEvidence = await page.getByRole('checkbox').evaluateAll(
          (elements, expectedName) => ({
            choiceCount: elements.length,
            expectedDeviceNameMatchCount: elements.filter((element) => {
              const label = element.getAttribute('aria-label') ||
                element.getAttribute('aria-roledescription') || '';
              return label.includes(expectedName);
            }).length,
            visibleCount: elements.filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none';
            }).length,
          }), expectedDeviceName,
        ).catch(() => ({ diagnosticUnavailable: true }));
        console.log('Profile A approved-device safe failure evidence', JSON.stringify({
          pickerDescriptionVisible: await page.getByText(
            'Choose active Vault devices', { exact: false },
          ).count().then((count) => count > 0).catch(() => false),
          profileBDevice: matchEvidence,
          directory: directoryEvidence(),
        }));
        throw error;
      }
      console.log('Profile A approved-device picker safe evidence', JSON.stringify({
        profileBDeviceChoiceCount: await profileBDeviceChoice.count(),
        directory: directoryEvidence(),
      }));
      safeRunStage = 'Profile A selects the approved Profile B device';
      await profileBDeviceChoice.click();
      const waitForShareChoiceChecked = async (timeoutMs) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
          if (await profileBDeviceChoice.getAttribute('aria-checked') === 'true') {
            return true;
          }
          await page.waitForTimeout(100);
        }
        return await profileBDeviceChoice.getAttribute('aria-checked') === 'true';
      };
      let profileBDeviceSelected = await waitForShareChoiceChecked(1200);
      if (!profileBDeviceSelected) {
        await profileBDeviceChoice.focus();
        await profileBDeviceChoice.press('Space');
        profileBDeviceSelected = await waitForShareChoiceChecked(5000);
      }
      console.log('Profile A observer selection safe evidence', JSON.stringify({
        selected: profileBDeviceSelected,
        ariaChecked: await profileBDeviceChoice.getAttribute('aria-checked'),
        startShareVisible: await page.getByRole('button', {
          name: 'Start sharing', exact: true,
        }).last().isVisible().catch(() => false),
      }));
      assertThat(profileBDeviceSelected,
        'selecting Profile B did not update the device checkbox');
      safeRunStage = 'Profile A confirms the selected observer device';
      const startShareConfirm = page.getByRole('button', {
        name: 'Start sharing', exact: true,
      }).last();
      await startShareConfirm.waitFor({ state: 'visible', timeout: 10000 });
      const confirmDeadline = Date.now() + 5000;
      while (Date.now() < confirmDeadline && !await startShareConfirm.isEnabled()) {
        await page.waitForTimeout(100);
      }
      assertThat(await startShareConfirm.isEnabled(),
        'selecting Profile B active device did not enable host sharing');
      await startShareConfirm.click();
      await waitText(page, 'Terminal share active', 20000);
      const createRequests = apiRequests.filter((request) =>
        request.method === 'POST' &&
        request.path.endsWith('/terminal-sessions'));
      assertThat(createRequests.length === 1 && createRequests[0].completed &&
        createRequests[0].status >= 200 && createRequests[0].status < 300,
      'Profile A did not create exactly one collaboration session successfully');
      assertThat(terminalCollaborationPrivacy.protocolVersions.length === 1 &&
        terminalCollaborationPrivacy.protocolVersions[0] === 1,
      'the default read-only share unexpectedly opted in to protocol v2');
      await page.getByRole('button', {
        name: 'Copy terminal share ID', exact: true,
      }).click();
      const terminalShareSessionId = (await readClipboard(page)).trim();
      assertThat(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        .test(terminalShareSessionId),
      'active host share did not expose a canonical UUID for the observer');
      const hostCollaborationSocket =
        terminalCollaborationSocketsForPage(page).at(-1);
      assertThat(terminalCollaborationSocketsForPage(page).length ===
        aCollaborationSocketBaseline + 1 && hostCollaborationSocket?.opened,
      'Profile A did not establish the collaboration WebSocket');
      await page.waitForFunction(() => {
        const socket = window.__terminalCollaborationSocketCloseMetadata;
        return Array.isArray(socket);
      });

      safeRunStage = 'Profile B joins the shared terminal before opening SSH';
      await click(secondPage, 'Terminal');
      const joinOpen = secondPage.getByRole('button', {
        name: 'Join a shared terminal', exact: true,
      });
      await joinOpen.waitFor({ state: 'visible', timeout: 15000 });
      await joinOpen.click();
      await waitText(secondPage, 'Enter the session UUID provided by the host.', 10000);
      safeRunStage = 'Profile B types the host share session ID';
      const sessionIdField = await field(secondPage, 'Session ID');
      await sessionIdField.click({ timeout: 5000 });
      await sessionIdField.pressSequentially(terminalShareSessionId, {
        delay: 15,
        timeout: 10000,
      });
      const sessionIdEvidence = await sessionIdField.evaluate((element, expected) => ({
        visible: element.getClientRects().length > 0,
        valueLength: typeof element.value === 'string' ? element.value.length : null,
        exactExpectedValue: element.value === expected,
      }), terminalShareSessionId);
      console.log('Profile B session ID input safe evidence', JSON.stringify({
        ...sessionIdEvidence,
        sessionIdInspected: false,
      }));
      assertThat(sessionIdEvidence.exactExpectedValue,
        'Profile B session ID input did not retain the host value');
      safeRunStage = 'Profile B submits the host share session ID';
      const joinShareButton = secondPage.getByRole('button', {
        name: 'Join', exact: true,
      }).last();
      await joinShareButton.waitFor({ state: 'visible', timeout: 10000 });
      assertThat(await joinShareButton.isEnabled(),
        'Profile B session ID did not enable the Join action');
      const bJoinApiEventBaseline = secondApiEvents.length;
      await joinShareButton.click();
      safeRunStage = 'Profile B waits for the read-only observer terminal';
      try {
        await waitText(secondPage, 'Shared terminal · read only', 20000);
      } catch (error) {
        const observerJoinEvidence = await secondPage.evaluate(() => {
          const text = document.body.innerText || '';
          const ariaLabels = [...document.querySelectorAll('[aria-label]')]
            .map((element) => element.getAttribute('aria-label') || '');
          const expectedUiText = [
            'Shared terminal · read only',
            'Observer connected',
            'Join a shared terminal',
            'Enter the session UUID provided by the host.',
            'Could not join. Check the session ID and Vault access.',
            'Leave shared terminal',
            'Stop terminal sharing',
          ];
          return {
            observerViewVisible: text.includes('Shared terminal · read only'),
            joinDialogVisible: text.includes('Enter the session UUID provided by the host.'),
            joinErrorVisible: text.includes(
              'Could not join. Check the session ID and Vault access.',
            ),
            observerConnectedVisible: text.includes('Observer connected'),
            joinActionStillVisible: [...document.querySelectorAll('[role="button"]')]
              .some((element) => (element.getAttribute('aria-label') || '') === 'Join'),
            dialogRoleCount: document.querySelectorAll('[role="dialog"]').length,
            semanticsNodeCount: document.querySelectorAll('flt-semantics').length,
            observerTitleAriaLabelCount: ariaLabels.filter((label) =>
              label.includes('Shared terminal')).length,
            observerStatusAriaLabelCount: ariaLabels.filter((label) =>
              label.startsWith('Observer ')).length,
            dialogDetails: [...document.querySelectorAll('[role="dialog"]')]
              .map((element) => {
                const dialogText = element.innerText || '';
                return {
                  visible: element.getBoundingClientRect().width > 0 &&
                    element.getBoundingClientRect().height > 0,
                  ariaLabelPresent: Boolean(element.getAttribute('aria-label')),
                  childCount: element.childElementCount,
                  knownTextMatches: expectedUiText.filter((known) =>
                    dialogText.includes(known)),
                };
              }),
            workspaceScreenHint: [
              'Hosts', 'Connect', 'Terminal', 'Settings', 'Sign in',
              'Welcome', 'Vaults',
            ].filter((known) => text.includes(known)),
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        const observerTitle = await terminalShareTitleEvidence(
          secondPage, 'Shared terminal · read only',
        );
        const observerTextLocators = {
          titleAriaLabelCount: observerTitle.count,
          titleAriaLabelVisible: observerTitle.visible,
          connectedCount: await secondPage.getByText(
            'Observer connected', { exact: true },
          ).count().catch(() => null),
          dialogCount: await secondPage.getByRole('dialog').count().catch(() => null),
        };
        console.log('Profile B observer join safe failure evidence', JSON.stringify({
          ui: observerJoinEvidence,
          textLocators: observerTextLocators,
          recentPageErrorKinds: pageErrors.slice(-5).map((event) => ({
            name: event.name,
            category: event.category,
          })),
          recentBrowserConsoleKinds: browserConsoleEvents.slice(-8).map((event) => ({
            type: event.type,
            name: event.name,
            category: event.category,
          })),
          api: secondApiEvents.slice(bJoinApiEventBaseline).map((event) => ({
            path: event.path,
            status: event.status,
            errorCode: event.errorCode,
          })),
          sockets: terminalCollaborationSocketsForPage(secondPage).map((socket) => ({
            socketIndex: socket.socketIndex,
            opened: socket.opened,
            closed: socket.closed,
            sentFrameCount: socket.sentFrames.length,
            sentMessageTypes: socket.sentFrames.slice(-6)
              .map(safeCollaborationFrameSummary),
            receivedFrameCount: socket.receivedFrames.length,
            receivedMessageTypes: socket.receivedFrames.slice(-6)
              .map(safeCollaborationFrameSummary),
            socketError: socket.socketError,
            plaintextPresent: socket.plaintextPresent,
          })),
        }));
        await secondPage.screenshot({
          path: '/home/atermius-terminal-observer-ui-failure.png',
          fullPage: false,
        }).catch(() => {});
        throw error;
      }
      safeRunStage = 'Profile B waits for the observer WebSocket authentication';
      await waitText(secondPage, 'Observer connected', 20000);
      const observerDialog = secondPage.getByRole('dialog').last();
      const leaveObserverButton = secondPage.getByRole('button', {
        name: 'Leave shared terminal', exact: true,
      });
      safeRunStage = 'Profile B verifies the observer dialog';
      const observerTitleEvidence = await terminalShareTitleEvidence(
        secondPage, 'Shared terminal · read only',
      );
      console.log('Profile B observer title accessibility safe evidence',
        JSON.stringify(observerTitleEvidence));
      assertThat(await observerDialog.isVisible() &&
        await leaveObserverButton.isVisible(),
      'Profile B read-only observer dialog did not become visible');
      const observerSshInputCount = await secondPage.getByRole('textbox', {
        name: 'SSH terminal input', exact: true,
      }).count();
      const preGrantControlActionCount = await secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      }).count();
      let observerCollaborationSocket =
        terminalCollaborationSocketsForPage(secondPage).at(-1);
      const observerSocketEvidence = terminalCollaborationSocketsForPage(secondPage)
        .map((socket) => ({
          opened: socket.opened,
          closed: socket.closed,
          sentFrameCount: socket.sentFrames.length,
          sentFrameKinds: socket.sentFrames.map((frame) => frame.kind),
          receivedFrameCount: socket.receivedFrames.length,
          socketError: socket.socketError,
          plaintextPresent: socket.plaintextPresent,
        }));
      console.log('Profile B observer live UI safe evidence', JSON.stringify({
        dialogVisible: await observerDialog.isVisible(),
        leaveActionVisible: await leaveObserverButton.isVisible(),
        preGrantControlActionCount,
        connectedVisible: await secondPage.getByText(
          'Observer connected', { exact: true },
        ).isVisible().catch(() => false),
        observerSshInputCount,
        socketCount: observerSocketEvidence.length,
        sockets: observerSocketEvidence,
      }));
      safeRunStage = 'Profile B verifies the observer has no SSH input control';
      assertThat(observerSshInputCount === 0,
      'Profile B observer exposed an SSH terminal input control');
      assertThat(preGrantControlActionCount === 0,
      'v1 read-only observer exposed host-granted input controls');
      safeRunStage = 'Profile B verifies observer transport frames';
      assertThat(terminalCollaborationSocketsForPage(secondPage).length ===
        bCollaborationSocketBaseline + 1 &&
        observerCollaborationSocket?.opened &&
        observerCollaborationSocket.receivedFrames.length > 0,
      'Profile B observer did not authenticate and receive the collaboration stream');
      assertThat(observerCollaborationSocket.sentFrames.every((frame) =>
        frame.kind === 'text') && observerCollaborationSocket.sentFrames.length === 1,
      'Profile B observer emitted an application frame beyond its initial text authentication');
      safeRunStage = 'Profile B observer terminal stable fingerprint baseline';
      const observerFingerprintBeforeOutput =
        await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 6000, null,
          'Shared terminal · read only',
        );

      safeRunStage = 'Profile A sends unique marker through the existing SSH shell';
      const hostFramesBeforeOutput = hostCollaborationSocket.sentFrames.length;
      const observerFramesBeforeOutput =
        observerCollaborationSocket.receivedFrames.length;
      await sendCommandToActiveTerminal(page, user, targetAddress,
        `printf '%s\\n' '${terminalShareMarker}'`, {
          activeHostName: hostName,
        });
      const outputDeadline = Date.now() + 10000;
      while (Date.now() < outputDeadline &&
          (hostCollaborationSocket.sentFrames.length <= hostFramesBeforeOutput ||
            observerCollaborationSocket.receivedFrames.length <=
              observerFramesBeforeOutput)) {
        await secondPage.waitForTimeout(100);
      }
      const collaborationHttpDeadline = Date.now() + 5000;
      while (Date.now() < collaborationHttpDeadline &&
          terminalCollaborationPrivacy.checks.length < 4) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(hostCollaborationSocket.sentFrames.length >
          hostFramesBeforeOutput &&
        observerCollaborationSocket.receivedFrames.length >
          observerFramesBeforeOutput &&
        observerCollaborationSocket.sentFrames.length === 1 &&
        !hostCollaborationSocket.plaintextPresent &&
        !observerCollaborationSocket.plaintextPresent,
      'collaboration WebSocket frames exposed plaintext marker or SSH key material');
      safeRunStage = 'Profile B observer terminal stable fingerprint updated';
      const observerFingerprintAfterOutput =
        await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 10000,
          observerFingerprintBeforeOutput,
          'Shared terminal · read only',
        );
      assertThat(observerFingerprintAfterOutput !==
        observerFingerprintBeforeOutput,
      'Profile B terminal viewport did not paint the encrypted live output');
      assertThat(terminalCollaborationPrivacy.checks.length >= 4 &&
        terminalCollaborationPrivacy.checks.every((check) => check.plaintextAbsent),
      'a collaboration HTTP request or response exposed plaintext marker or SSH key material');

      safeRunStage = 'Profile B loses the observer transport while the host room stays active';
      const disconnectedObserverSocket = observerCollaborationSocket;
      const socketClosedByProbe = await secondPage.evaluate(() => {
        const sockets = window.__atermiusTestCollaborationSockets || [];
        const socket = [...sockets].reverse().find((candidate) =>
          candidate.readyState === WebSocket.OPEN);
        if (!socket) return false;
        socket.close(4001, 'test transport interruption');
        return true;
      });
      assertThat(socketClosedByProbe,
        'Profile B test probe could not close the observer transport');
      const observerDisconnectDeadline = Date.now() + 5000;
      while (Date.now() < observerDisconnectDeadline &&
          !disconnectedObserverSocket.closed) {
        await secondPage.waitForTimeout(50);
      }
      assertThat(disconnectedObserverSocket.closed &&
        !hostCollaborationSocket.closed,
      'observer transport loss also closed the host-owned room');
      const reconnectObserverButton = secondPage.getByRole('button', {
        name: 'Reconnect observer', exact: true,
      });
      await reconnectObserverButton.waitFor({ state: 'visible', timeout: 10000 });

      const outputWhileObserverWasAway =
        `WEB_TERMINAL_GAP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      terminalCollaborationPrivacy.markers.push(outputWhileObserverWasAway);
      safeRunStage = 'Profile A sends output while Profile B is disconnected';
      await sendCommandToActiveTerminal(page, user, targetAddress,
        `printf '%s\\n' '${outputWhileObserverWasAway}'`, {
          activeHostName: hostName,
        });
      await secondPage.waitForTimeout(250);

      safeRunStage = 'Profile B explicitly rejoins the still-active host room';
      const reconnectSocketCountBefore =
        terminalCollaborationSocketsForPage(secondPage).length;
      const observerTicketCount = () => secondApiEvents.filter((event) =>
        event.path.includes('/terminal-sessions/') &&
        event.path.endsWith('/ticket')).length;
      const reconnectTicketCountBefore = observerTicketCount();
      await reconnectObserverButton.click();
      await waitText(secondPage, 'Observer connected', 20000);
      const reconnectDeadline = Date.now() + 5000;
      while (Date.now() < reconnectDeadline &&
          terminalCollaborationSocketsForPage(secondPage).length <=
            reconnectSocketCountBefore) {
        await secondPage.waitForTimeout(50);
      }
      assertThat(terminalCollaborationSocketsForPage(secondPage).length ===
          reconnectSocketCountBefore + 1 &&
        observerTicketCount() === reconnectTicketCountBefore + 1,
      'observer rejoin did not create exactly one fresh ticket and socket');
      observerCollaborationSocket =
        terminalCollaborationSocketsForPage(secondPage).at(-1);
      assertThat(observerCollaborationSocket?.opened &&
        !observerCollaborationSocket.closed &&
        observerCollaborationSocket.sentFrames.length === 1 &&
        observerCollaborationSocket.sentFrames.every((frame) =>
          frame.kind === 'text') &&
        !observerCollaborationSocket.receivedFrames.some((frame) =>
          frame.frameKind === 'output'),
      'observer rejoin replayed output or sent application data');
      assertThat(await secondPage.getByRole('button', {
          name: 'Join host-granted control', exact: true,
        }).count() === 0,
      'observer rejoin restored an old host control grant');
      const gapMarkerStorageEvidence = fileMarkerAbsenceEvidence([
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
        serverLogPath,
      ], outputWhileObserverWasAway);
      assertThat(gapMarkerStorageEvidence.scannedFiles >= 2 &&
        gapMarkerStorageEvidence.plaintextMarkerAbsent,
      'server storage or logs contained output produced during observer loss');

      const afterRejoinMarker =
        `WEB_TERMINAL_AFTER_REJOIN_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      terminalCollaborationPrivacy.markers.push(afterRejoinMarker);
      const receivedBeforeAfterRejoin =
        observerCollaborationSocket.receivedFrames.length;
      safeRunStage = 'Profile A sends fresh output after observer rejoin';
      await sendCommandToActiveTerminal(page, user, targetAddress,
        `printf '%s\\n' '${afterRejoinMarker}'`, {
          activeHostName: hostName,
        });
      const afterRejoinOutputDeadline = Date.now() + 10000;
      while (Date.now() < afterRejoinOutputDeadline &&
          !observerCollaborationSocket.receivedFrames
            .slice(receivedBeforeAfterRejoin)
            .some((frame) => frame.frameKind === 'output')) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(observerCollaborationSocket.receivedFrames
          .slice(receivedBeforeAfterRejoin)
          .some((frame) => frame.frameKind === 'output') &&
        !observerCollaborationSocket.plaintextPresent &&
        !hostCollaborationSocket.closed,
      'the rejoined observer did not receive new encrypted output');

      const collaborationStorageFiles = [
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
        serverLogPath,
      ];
      const markerStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, terminalShareMarker,
      );
      const afterRejoinStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, afterRejoinMarker,
      );
      const targetKeyStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, targetPrivateKey,
      );
      const bastionKeyStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, bastionPrivateKey,
      );
      assertThat(markerStorageEvidence.scannedFiles >= 2 &&
        markerStorageEvidence.plaintextMarkerAbsent &&
        afterRejoinStorageEvidence.plaintextMarkerAbsent &&
        targetKeyStorageEvidence.plaintextMarkerAbsent &&
        bastionKeyStorageEvidence.plaintextMarkerAbsent,
      'server database, sidecars, or logs contained plaintext terminal output or private-key material');

      const bRelayTicketsAfterObserver =
        relayTicketChecksForPage(secondPage).length;
      const bRelaySocketsAfterObserver =
        relaySocketsForPage(secondPage).length;
      const sshdAfterObserverOutput = {
        target: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
        bastion: sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
      };
      const observerSshdDeltas = {
        target: safeCounterDelta(sshdBeforeCollaboration.target,
          sshdAfterObserverOutput.target, [
            'tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionOpenRequests',
            'sessionStarts', 'commandSessionStarts',
          ]),
        bastion: safeCounterDelta(sshdBeforeCollaboration.bastion,
          sshdAfterObserverOutput.bastion, [
            'tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionOpenRequests',
            'sessionStarts', 'commandSessionStarts',
          ]),
      };
      assertThat(bRelayTicketsAfterObserver === bRelayTicketBaseline &&
        bRelaySocketsAfterObserver === bRelaySocketBaseline &&
        Object.values(observerSshdDeltas).every((delta) =>
          Object.values(delta).every((value) => value === 0)),
      'Profile B observer created an SSH Relay ticket, socket, or SSHD session');

      safeRunStage = 'Profile A stops sharing and observer transport closes';
      const aStopApiEventBaseline = apiEvents.length;
      await page.getByRole('button', {
        name: 'Stop terminal sharing', exact: true,
      }).click();
      const closeDeadline = Date.now() + 10000;
      while (Date.now() < closeDeadline &&
          (!observerCollaborationSocket.closed ||
            !hostCollaborationSocket.closed)) {
        await secondPage.waitForTimeout(100);
      }
      const stopApiEvidence = apiEvents.slice(aStopApiEventBaseline).map((event) => ({
        path: event.path,
        method: event.method,
        status: event.status,
        completed: event.completed,
        errorCode: event.errorCode,
      }));
      const hostCloseMetadata = await page.evaluate(() => {
        const values = window.__terminalCollaborationSocketCloseMetadata || [];
        return values.slice(-1).map((entry) => ({
          code: entry.code,
          reasonCategory: entry.reasonCategory,
          wasClean: entry.wasClean,
        }));
      }).catch(() => []);
      const observerCloseMetadataAfterStop = await secondPage.evaluate(() => {
        const values = window.__terminalCollaborationSocketCloseMetadata || [];
        return values.slice(-1).map((entry) => ({
          code: entry.code,
          reasonCategory: entry.reasonCategory,
          wasClean: entry.wasClean,
        }));
      }).catch(() => []);
      console.log('Profile A stop and collaboration close safe evidence', JSON.stringify({
        hostSocket: {
          opened: hostCollaborationSocket.opened,
          closed: hostCollaborationSocket.closed,
          sentFrameCount: hostCollaborationSocket.sentFrames.length,
          receivedFrameCount: hostCollaborationSocket.receivedFrames.length,
          socketError: hostCollaborationSocket.socketError,
        },
        observerSocket: {
          opened: observerCollaborationSocket.opened,
          closed: observerCollaborationSocket.closed,
          sentFrameCount: observerCollaborationSocket.sentFrames.length,
          receivedFrameCount: observerCollaborationSocket.receivedFrames.length,
          socketError: observerCollaborationSocket.socketError,
        },
        stopApiEvidence,
        hostCloseMetadata,
        observerCloseMetadataAfterStop,
        relayEvidence: {
          ticketCountBefore: aRelayTicketBaseline,
          ticketCountAfter: relayTicketChecksForPage(page).length,
          socketCountBefore: aRelaySocketBaseline,
          socketCountAfter: relaySocketsForPage(page).length,
          openSocketCountBefore: aOpenRelaySocketsBeforeCollaboration.length,
          openSocketCountAfter: relaySocketsForPage(page).filter((socket) =>
            socket.opened && !socket.closed).length,
          originalOpenSocketsRemainOpen:
            aOpenRelaySocketsBeforeCollaboration.every((socket) =>
              relaySocketsForPage(page).includes(socket) &&
              socket.opened && !socket.closed),
        },
      }));
      assertThat(observerCollaborationSocket.closed && hostCollaborationSocket.closed,
        'stopping the host share did not close both collaboration sockets');
      assertThat(observerCollaborationSocket.sentFrames.length === 1 &&
        observerCollaborationSocket.sentFrames[0].kind === 'text',
      'Profile B observer sent terminal data during the read-only live session');
      const observerCloseEvidence = await secondPage.evaluate(() => {
        const values = window.__terminalCollaborationSocketCloseMetadata || [];
        return values.slice(-1).map((entry) => ({
          code: entry.code,
          reasonCategory: entry.reasonCategory,
          wasClean: entry.wasClean,
        }));
      });
      assertThat(observerCloseEvidence.length === 1 &&
        observerCloseEvidence[0].code === 1000 &&
        observerCloseEvidence[0].reasonCategory === 'session_ended',
      'host stop did not close Profile B WebSocket with SESSION_ENDED');
      assertThat(relayTicketChecksForPage(page).length === aRelayTicketBaseline &&
        relaySocketsForPage(page).length === aRelaySocketBaseline &&
        aOpenRelaySocketsBeforeCollaboration.length > 0 &&
        aOpenRelaySocketsBeforeCollaboration.every((socket) =>
          relaySocketsForPage(page).includes(socket) &&
          socket.opened && !socket.closed),
      'terminal sharing replaced or closed Profile A active SSH Relay transport');

      safeRunStage = 'Profile B rejoin of stopped session is rejected';
      await secondPage.getByRole('button', {
        name: 'Leave shared terminal', exact: true,
      }).click();
      await joinOpen.waitFor({ state: 'visible', timeout: 10000 });
      const collaborationSocketCountBeforeRejoin =
        terminalCollaborationSocketsForPage(secondPage).length;
      await joinOpen.click();
      await fill(secondPage, 'Session ID', terminalShareSessionId);
      await secondPage.getByRole('button', {
        name: 'Join', exact: true,
      }).last().click();
      await waitText(secondPage,
        'Could not join. Check the session ID and Vault access.', 15000);
      const rejectedJoinDeadline = Date.now() + 5000;
      while (Date.now() < rejectedJoinDeadline &&
          !secondApiEvents.some((event) =>
            event.path.endsWith('/ticket') && event.status >= 400 &&
            event.status < 500)) {
        await secondPage.waitForTimeout(100);
      }
      const rejectedJoinResponses = secondApiEvents.filter((event) =>
        event.path.endsWith('/ticket') && event.status >= 400 &&
        event.status < 500);
      assertThat(rejectedJoinResponses.length > 0 &&
        terminalCollaborationSocketsForPage(secondPage).length ===
          collaborationSocketCountBeforeRejoin &&
        relayTicketChecksForPage(secondPage).length === bRelayTicketBaseline &&
        relaySocketsForPage(secondPage).length === bRelaySocketBaseline,
      'a stopped collaboration session was rejoinable or opened a fallback SSH Relay');
      await secondPage.getByRole('button', { name: 'Cancel', exact: true })
        .last().click();

      safeRunStage = 'Profile A SSH remains usable after collaboration stop';
      const postStopMarker =
        `WEB_TERMINAL_COLLAB_AFTER_STOP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      terminalCollaborationPrivacy.markers.push(postStopMarker);
      safeRunStage = 'Profile A post-stop terminal stable fingerprint baseline';
      const hostFingerprintBeforePostStop =
        await stableTerminalVisualFingerprint(page, user, targetAddress);
      safeRunStage = 'Profile A sends output after observer shutdown';
      await sendCommandToActiveTerminal(page, user, targetAddress,
        `printf '%s\\n' '${postStopMarker}'`, {
          activeHostName: hostName,
        });
      safeRunStage = 'Profile A post-stop terminal stable fingerprint updated';
      const hostFingerprintAfterPostStop =
        await stableTerminalVisualFingerprint(
          page, user, targetAddress, 10000, hostFingerprintBeforePostStop,
        );
      assertThat(hostFingerprintAfterPostStop !== hostFingerprintBeforePostStop,
        'Profile A terminal viewport did not paint output after observer shutdown');

      const controllerCommandMarker =
        `WEB_TERMINAL_CONTROL_INPUT_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const controllerOutputMarker =
        `WEB_TERMINAL_CONTROL_OUTPUT_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      const controllerResultFilename =
        `terminal-control-${RUN_ID.replaceAll('-', '')}.txt`;
      const controllerResultPath = path.join(remoteRoot, controllerResultFilename);
      const controllerCommand =
        `printf '%s\\n' '${controllerOutputMarker}' > /tmp/remote/${controllerResultFilename}; printf '%s\\n' '${controllerOutputMarker}'; # ${controllerCommandMarker}`;
      terminalCollaborationPrivacy.markers.push(
        controllerCommandMarker,
        controllerOutputMarker,
      );
      safeRunStage = 'Profile A starts a v2 host-approved input share';
      const v2CreateRequestBaseline = apiRequests.length;
      await shareStart.click();
      await waitText(page, 'Choose active Vault devices', 15000);
      const v2DeviceChoice = page.getByRole('checkbox', {
        name: new RegExp(profileBDeviceName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
      }).last();
      await v2DeviceChoice.waitFor({ state: 'visible', timeout: 15000 });
      await v2DeviceChoice.click();
      const v2InputOptIn = page.getByRole('checkbox', {
        name: 'Enable host-approved input control', exact: false,
      });
      await v2InputOptIn.click();
      assertThat(await v2InputOptIn.getAttribute('aria-checked') === 'true',
        'Profile A v2 input-control opt-in did not become selected');
      await page.getByRole('button', {
        name: 'Start sharing', exact: true,
      }).last().click();
      await waitText(page, 'Terminal share active', 20000);
      const v2CreateRequests = apiRequests.slice(v2CreateRequestBaseline)
        .filter((request) => request.method === 'POST' &&
          request.path.endsWith('/terminal-sessions'));
      assertThat(v2CreateRequests.length === 1 && v2CreateRequests[0].completed &&
        v2CreateRequests[0].status >= 200 && v2CreateRequests[0].status < 300 &&
        terminalCollaborationPrivacy.protocolVersions.length === 2 &&
        terminalCollaborationPrivacy.protocolVersions[1] === 2,
      'Profile A did not create exactly one explicitly opted-in protocol v2 room');
      await page.getByRole('button', {
        name: 'Copy terminal share ID', exact: true,
      }).click();
      const v2SessionId = (await readClipboard(page)).trim();
      terminalCollaborationActiveSessionByPage.set(page, v2SessionId);
      terminalCollaborationActiveSessionByPage.set(secondPage, v2SessionId);
      const v2Context = terminalCollaborationContextsByPage.get(page);
      const v2HostSocketBaseline = terminalCollaborationSocketsForPage(page).length;
      const v2ObserverSocketBaseline =
        terminalCollaborationSocketsForPage(secondPage).length;
      const v2HostSocket = terminalCollaborationSocketsForPage(page).at(-1);

      safeRunStage = 'Profile B joins v2 as a read-only observer before grant';
      await joinOpen.click();
      await fill(secondPage, 'Session ID', v2SessionId);
      await secondPage.getByRole('button', { name: 'Join', exact: true })
        .last().click();
      await waitText(secondPage, 'Shared terminal · read only', 20000);
      const v2ObserverDialog = secondPage.getByRole('dialog').last();
      const joinControlBeforeGrant = await secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      }).count();
      const editableInputBeforeGrant = await secondPage.getByRole('textbox', {
        name: 'Host-approved terminal input', exact: true,
      }).count();
      assertThat(joinControlBeforeGrant === 0 && editableInputBeforeGrant === 0,
        'Profile B exposed controller join or input UI before a host grant event');
      assertThat(terminalCollaborationSocketsForPage(secondPage).length ===
        v2ObserverSocketBaseline + 1 &&
        terminalCollaborationSocketsForPage(secondPage).at(-1)?.opened,
      'Profile B did not join the v2 room as its existing read-only observer');

      safeRunStage = 'Profile A grants the approved Profile B device';
      const grantInputControl = page.getByRole('button', {
        name: 'Grant input control', exact: true,
      });
      const grantControlButtonCount = await grantInputControl.count();
      const grantControlUiEvidence = await page.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none' &&
            Number(style.opacity) !== 0;
        };
        const controls = [...document.querySelectorAll(
          'flt-semantics[role="button"]',
        )].filter(visible).map((element) => ({
          label: element.getAttribute('aria-label') || '',
          title: element.getAttribute('title') || '',
          key: element.getAttribute('data-key') || '',
        })).filter((element) => /share|control|terminal/i.test(
          `${element.label} ${element.title} ${element.key}`,
        ));
        const shareStatusLabels = [...document.querySelectorAll(
          'flt-semantics[aria-label], flt-semantics[role="status"], flt-semantics[role="text"]',
        )].filter(visible).map((element) => ({
          label: element.getAttribute('aria-label') || '',
          role: element.getAttribute('role') || '',
        })).filter((element) => /terminal share|input control/i.test(element.label));
        const selectedTabCount = document.querySelectorAll(
          'flt-semantics[role="tab"][aria-selected="true"], [role="tab"][aria-selected="true"]',
        ).length;
        return {
          visibleShareControlCount: controls.length,
          visibleShareControls: controls,
          shareStatusLabels,
          selectedTabCount,
          hostTerminalInputCount: document.querySelectorAll(
            '[aria-label="SSH terminal input"]',
          ).length,
          pageTitle: document.title,
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      console.log('Profile A v2 grant action safe UI evidence', JSON.stringify({
        grantControlButtonCount,
        grantControlVisible: await grantInputControl.isVisible().catch(() => false),
        grantControlEnabled: await grantInputControl.isEnabled().catch(() => false),
        browserPageErrorCount: pageErrors.length,
        recentPageErrorKinds: pageErrors.slice(-5).map((event) => ({
          name: event.name,
          category: event.category,
        })),
        ...grantControlUiEvidence,
      }));
      if (grantControlButtonCount !== 1 ||
          !await grantInputControl.isVisible().catch(() => false)) {
        await page.screenshot({
          path: '/home/atermius-v2-host-grant-action-failure.png',
          fullPage: false,
        }).catch(() => {});
      }
      assertThat(grantControlButtonCount === 1 &&
        await grantInputControl.isVisible().catch(() => false),
      'Profile A did not expose the host input-control grant action after creating v2 room');
      await grantInputControl.click();
      safeRunStage = 'Profile A chooses Profile B in the controller grant dialog';
      const controllerDeviceRadio = page.getByRole('radio', {
        name: new RegExp(profileBDeviceName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
      });
      console.log('Profile A controller picker safe UI evidence', JSON.stringify({
        dialogCount: await page.getByRole('dialog').count(),
        radioCount: await page.getByRole('radio').count(),
        approvedDeviceRadioCount: await controllerDeviceRadio.count(),
        confirmCount: await page.getByRole('button', {
          name: 'Grant for 5 minutes', exact: true,
        }).count(),
        visibleRadioCount: await page.getByRole('radio').evaluateAll((elements) =>
          elements.filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none';
          }).length,
        ).catch(() => -1),
      }));
      await controllerDeviceRadio.waitFor({ state: 'visible', timeout: 10000 });
      await controllerDeviceRadio.click();
      const waitForControllerRadioChecked = async (timeoutMs) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
          if (await controllerDeviceRadio.getAttribute('aria-checked') === 'true') {
            return true;
          }
          await page.waitForTimeout(100);
        }
        return await controllerDeviceRadio.getAttribute('aria-checked') === 'true';
      };
      let controllerRadioSelected = await waitForControllerRadioChecked(1200);
      if (!controllerRadioSelected) {
        await controllerDeviceRadio.focus().catch(() => {});
        await controllerDeviceRadio.press('Space').catch(() => {});
        controllerRadioSelected = await waitForControllerRadioChecked(5000);
      }
      const controllerGrantConfirm = page.getByRole('button', {
        name: 'Grant for 5 minutes', exact: true,
      });
      const controllerGrantTextFallback = page.getByText(
        'Grant for 5 minutes', { exact: true },
      ).last();
      console.log('Profile A controller grant selection safe UI evidence', JSON.stringify({
        controllerRadioSelected,
        radioAriaChecked: await controllerDeviceRadio.getAttribute('aria-checked')
          .catch(() => null),
        confirmRoleCount: await controllerGrantConfirm.count(),
        confirmRoleVisible: await controllerGrantConfirm.isVisible().catch(() => false),
        confirmRoleEnabled: await controllerGrantConfirm.isEnabled().catch(() => false),
        confirmTextCount: await controllerGrantTextFallback.count(),
        confirmTextVisible: await controllerGrantTextFallback.isVisible().catch(() => false),
      }));
      assertThat(controllerRadioSelected,
        'Profile A controller device radio did not become selected');
      assertThat(await controllerGrantConfirm.isVisible().catch(() => false) &&
        await controllerGrantConfirm.isEnabled().catch(() => false),
      'Profile A controller grant confirmation was not enabled after selecting the approved device');
      safeRunStage = 'Profile A clicks the controller grant confirmation';
      const grantApiRequestBaseline = apiRequests.length;
      const safeGrantApiEvidence = () => apiRequests
        .slice(grantApiRequestBaseline)
        .filter((request) => request.path.includes('controller-lease'))
        .map((request) => ({
          route: request.path.endsWith('/ticket')
            ? 'controller_lease_ticket'
            : 'controller_lease',
          method: request.method,
          status: request.status,
          completed: request.completed,
        }));
      if (await controllerGrantConfirm.count() === 1) {
        try {
          await controllerGrantConfirm.click({ timeout: 5000 });
        } catch (error) {
          const modalStillVisible =
            await controllerGrantConfirm.isVisible().catch(() => false);
          const grantApiStarted = safeGrantApiEvidence().length > 0;
          const exactTextCount = await controllerGrantTextFallback.count()
            .catch(() => 0);
          console.log('Profile A controller confirm click safe failure evidence',
            JSON.stringify({
              errorType: error?.name || 'Error',
              modalStillVisible,
              grantApiStarted,
              exactTextCount,
              grantApi: safeGrantApiEvidence(),
            }));
          if (!grantApiStarted && modalStillVisible && exactTextCount === 1 &&
              await controllerGrantTextFallback.isVisible().catch(() => false)) {
            await controllerGrantTextFallback.click({ timeout: 5000 });
          } else {
            throw error;
          }
        }
      } else {
        assertThat(await controllerGrantTextFallback.count() === 1,
          'controller grant confirmation has no exact accessible role or text');
        await controllerGrantTextFallback.click({ timeout: 5000 });
      }
      safeRunStage = 'Profile A host controller lease status updates';
      const hostRevokeController = page.getByRole('button', {
        name: 'Revoke input control', exact: true,
      });
      try {
        await hostRevokeController.waitFor({ state: 'visible', timeout: 10000 });
        const successfulGrantRequest = safeGrantApiEvidence().find((request) =>
          request.route === 'controller_lease' && request.method === 'POST' &&
          request.completed && request.status >= 200 && request.status < 300);
        assertThat(successfulGrantRequest != null,
          'the host revoke action appeared without a successful controller lease POST');
      } catch (error) {
        console.log('Profile A controller grant post-click safe UI evidence',
          JSON.stringify({
            revokeActionCount: await hostRevokeController.count().catch(() => -1),
            revokeActionVisible: await hostRevokeController.isVisible().catch(() => false),
            hostGrantButtonCount: await page.getByRole('button', {
              name: 'Grant input control', exact: true,
            }).count().catch(() => -1),
            hostRevokeButtonCount: await page.getByRole('button', {
              name: 'Revoke input control', exact: true,
            }).count().catch(() => -1),
            hostGrantApi: safeGrantApiEvidence(),
            hostSocket: v2HostSocket ? {
              opened: v2HostSocket.opened,
              closed: v2HostSocket.closed,
              sentFrames: v2HostSocket.sentFrames.length,
              receivedFrames: v2HostSocket.receivedFrames.length,
              socketError: v2HostSocket.socketError,
            } : null,
            pageErrorCount: pageErrors.length,
            errorType: error?.name || 'Error',
          }));
        throw error;
      }
      safeRunStage = 'Profile B receives the host controller grant event';
      const joinGrantedControl = secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      });
      try {
        await joinGrantedControl.waitFor({ state: 'visible', timeout: 10000 });
      } catch (error) {
        const observerSocketAfterGrant =
          terminalCollaborationSocketsForPage(secondPage).at(-1);
        const controllerTicketEvents = secondApiEvents
          .filter((event) => event.path.includes('controller-lease'))
          .slice(-4)
          .map((event) => ({
            route: event.path.endsWith('/ticket')
              ? 'controller_lease_ticket'
              : 'controller_lease',
            method: event.method,
            status: event.status,
            completed: event.completed,
          }));
        const readOnlyTitleEvidence = await terminalShareTitleEvidence(
          secondPage, 'Shared terminal · read only',
        );
        const controllerTitleEvidence = await terminalShareTitleEvidence(
          secondPage, 'Shared terminal · host-approved control',
        );
        console.log('Profile B controller grant event safe UI/transport evidence',
          JSON.stringify({
            joinButtonCount: await joinGrantedControl.count().catch(() => -1),
            joinButtonVisible: await joinGrantedControl.isVisible().catch(() => false),
            readOnlyTitleCount: readOnlyTitleEvidence.count,
            readOnlyTitleVisible: readOnlyTitleEvidence.visible,
            controllerTitleCount: controllerTitleEvidence.count,
            controllerTitleVisible: controllerTitleEvidence.visible,
            observerConnectedCount: await secondPage.getByText(
              'Observer connected', { exact: true },
            ).count().catch(() => -1),
            observerFailedCount: await secondPage.getByText(
              'Observer failed', { exact: true },
            ).count().catch(() => -1),
            observerSocket: observerSocketAfterGrant ? {
              socketIndex: observerSocketAfterGrant.socketIndex,
              opened: observerSocketAfterGrant.opened,
              closed: observerSocketAfterGrant.closed,
              sentFrames: observerSocketAfterGrant.sentFrames.length,
              receivedFrames: observerSocketAfterGrant.receivedFrames.length,
              receivedMessageTypes: observerSocketAfterGrant.receivedFrames
                .slice(-8).map(safeCollaborationFrameSummary),
              socketError: observerSocketAfterGrant.socketError,
              plaintextPresent: observerSocketAfterGrant.plaintextPresent,
            } : null,
            hostGrantApi: safeGrantApiEvidence(),
            controllerTicketEvents,
            pageErrorCount: pageErrors.length,
            recentPageErrorKinds: pageErrors.slice(-5).map((event) => ({
              name: event.name,
              category: event.category,
            })),
            errorType: error?.name || 'Error',
          }));
        throw error;
      }
      assertThat(await secondPage.getByRole('textbox', {
        name: 'Host-approved terminal input', exact: true,
      }).count() === 0,
      'Profile B received editable input before explicitly joining its host grant');

      safeRunStage = 'Profile B transport loss revokes the old controller grant';
      const firstGrantedObserverSocket =
        terminalCollaborationSocketsForPage(secondPage).at(-1);
      const observerSocketClosedByProbe = await secondPage.evaluate((socketIndex) => {
        const socket = (window.__atermiusTestCollaborationSockets || [])[
          socketIndex - 1
        ];
        if (!socket || socket.readyState !== WebSocket.OPEN) return false;
        socket.close(4001, 'test observer transport loss');
        return true;
      }, firstGrantedObserverSocket?.socketIndex ?? 0);
      assertThat(observerSocketClosedByProbe,
        'Profile B could not close its approved observer transport');
      const observerCloseDeadline = Date.now() + 5000;
      while (Date.now() < observerCloseDeadline &&
          !firstGrantedObserverSocket?.closed) {
        await secondPage.waitForTimeout(50);
      }
      const reconnectObserverAfterGrant = secondPage.getByRole('button', {
        name: 'Reconnect observer', exact: true,
      });
      await reconnectObserverAfterGrant.waitFor({
        state: 'visible', timeout: 10000,
      });
      await grantInputControl.waitFor({ state: 'visible', timeout: 10000 });
      assertThat(!await hostRevokeController.isVisible().catch(() => false),
        'the host still showed an active control lease after observer disconnect');
      console.log('Profile B observer disconnect lease invalidation safe evidence',
        JSON.stringify({
          previousObserverSocketClosed: firstGrantedObserverSocket?.closed === true,
          reconnectActionVisible: await reconnectObserverAfterGrant.isVisible()
            .catch(() => false),
          hostGrantActionVisible: await grantInputControl.isVisible()
            .catch(() => false),
          hostRevokeActionVisible: await hostRevokeController.isVisible()
            .catch(() => false),
          hostReceivedLeaseEnded: v2HostSocket?.receivedFrames.some((frame) =>
            frame.messageType === 'controller_lease_ended') ?? false,
        }));

      safeRunStage = 'Profile B verifies the disconnected controller lease is invalid';
      const bIdentityTokenAfterDisconnect = bearerTokensByPage.get(secondPage);
      assertThat(typeof bIdentityTokenAfterDisconnect === 'string' &&
        v2Context?.vaultId && v2Context.sessionId === v2SessionId,
      'Profile B controller-ticket identity context was unavailable');
      const staleControllerTicketStatus = await secondPage.evaluate(async ({
        requestUrl,
        authorization,
      }) => {
        const response = await fetch(requestUrl, {
          method: 'POST',
          headers: { authorization },
        });
        return response.status;
      }, {
        requestUrl: new URL(
          `/api/v1/vaults/${v2Context.vaultId}/terminal-sessions/${v2SessionId}/controller-lease/ticket`,
          baseUrl,
        ).toString(),
        authorization: bIdentityTokenAfterDisconnect,
      });
      assertThat(staleControllerTicketStatus === 404,
        'Profile B could still mint a controller ticket from the old grant');

      safeRunStage = 'Profile B explicitly rejoins after active control was revoked';
      const v2ReconnectSocketCountBefore =
        terminalCollaborationSocketsForPage(secondPage).length;
      const v2ReconnectTicketCountBefore = observerTicketCount();
      await reconnectObserverAfterGrant.click();
      await waitText(secondPage, 'Observer connected', 20000);
      const v2ReconnectDeadline = Date.now() + 5000;
      while (Date.now() < v2ReconnectDeadline &&
          terminalCollaborationSocketsForPage(secondPage).length <=
            v2ReconnectSocketCountBefore) {
        await secondPage.waitForTimeout(50);
      }
      const rejoinedObserverSocket =
        terminalCollaborationSocketsForPage(secondPage).at(-1);
      const staleControlActionCount = await secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      }).count();
      const staleControllerInputCount = await secondPage.getByRole('textbox', {
        name: 'Host-approved terminal input', exact: true,
      }).count();
      assertThat(terminalCollaborationSocketsForPage(secondPage).length ===
          v2ReconnectSocketCountBefore + 1 &&
        observerTicketCount() === v2ReconnectTicketCountBefore + 1 &&
        rejoinedObserverSocket?.opened &&
        !rejoinedObserverSocket.closed &&
        rejoinedObserverSocket.sentFrames.length === 1 &&
        !rejoinedObserverSocket.receivedFrames.some((frame) =>
          frame.frameKind === 'output') &&
        staleControlActionCount === 0 && staleControllerInputCount === 0,
      'observer rejoin replayed output or restored control without fresh host approval');
      console.log('Profile B v2 observer reconnect safe evidence', JSON.stringify({
        previousObserverSocketClosed: firstGrantedObserverSocket?.closed === true,
        hostControlLeaseRevoked: await grantInputControl.isVisible()
          .catch(() => false),
        staleControllerTicketStatus,
        freshObserverTicketDelta: observerTicketCount() - v2ReconnectTicketCountBefore,
        freshObserverSocketConnected: rejoinedObserverSocket?.opened === true &&
          rejoinedObserverSocket?.closed === false,
        outputFramesReplayed: rejoinedObserverSocket?.receivedFrames.filter(
          (frame) => frame.frameKind === 'output').length ?? -1,
        controllerJoinActionBeforeFreshGrant: staleControlActionCount,
        controllerInputBeforeFreshGrant: staleControllerInputCount,
      }));

      safeRunStage = 'Profile A issues a fresh controller grant after observer rejoin';
      await grantInputControl.click();
      await controllerDeviceRadio.waitFor({ state: 'visible', timeout: 10000 });
      await controllerDeviceRadio.click();
      const regrantRadioSelected = await waitForControllerRadioChecked(5000);
      assertThat(regrantRadioSelected &&
        await controllerGrantConfirm.isEnabled().catch(() => false),
      'Profile A could not select Profile B for the fresh controller grant');
      await controllerGrantConfirm.click();
      await hostRevokeController.waitFor({ state: 'visible', timeout: 10000 });
      const lateJoinControllerAction = secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      });
      await lateJoinControllerAction.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(firstGrantedObserverSocket?.closed &&
        terminalCollaborationSocketsForPage(secondPage).length ===
          v2ObserverSocketBaseline + 2,
      'the observer did not reconnect before receiving a fresh host grant');

      safeRunStage = 'a different device cannot redeem Profile B control lease';
      const hostIdentityToken = bearerTokensByPage.get(page);
      assertThat(typeof hostIdentityToken === 'string' && v2Context?.vaultId &&
        v2Context.sessionId === v2SessionId,
      'the v2 host request identity context was not captured for the wrong-device check');
      const wrongDeviceTicketStatus = await page.evaluate(async ({
        requestUrl,
        authorization,
      }) => {
        const response = await fetch(requestUrl, {
          method: 'POST',
          headers: { authorization },
        });
        return response.status;
      }, {
        requestUrl: new URL(
          `/api/v1/vaults/${v2Context.vaultId}/terminal-sessions/${v2SessionId}/controller-lease/ticket`,
          baseUrl,
        ).toString(),
        authorization: hostIdentityToken,
      });
      assertThat(wrongDeviceTicketStatus >= 400,
        'the host device redeemed a controller lease granted to another device');

      safeRunStage = 'Profile B joins the exact host-approved controller lease';
      const exactLeaseJoinAction = secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      });
      const controllerInput = secondPage.getByRole('textbox', {
        name: 'Host-approved terminal input', exact: true,
      });
      try {
        await exactLeaseJoinAction.click();
        await controllerInput.waitFor({ state: 'visible', timeout: 10000 });
      } catch (error) {
        const controllerLeaseTicketEvents = secondApiEvents
          .filter((event) => event.path.includes('controller-lease'))
          .slice(-6)
          .map((event) => ({
            route: event.path.endsWith('/ticket')
              ? 'controller_lease_ticket' : 'controller_lease',
            method: event.method,
            status: event.status,
            completed: event.completed,
          }));
        const targetSockets = terminalCollaborationSocketsForPage(secondPage)
          .slice(v2ObserverSocketBaseline)
          .map((socket) => ({
            socketIndex: socket.socketIndex,
            opened: socket.opened,
            closed: socket.closed,
            sentMessageTypes: socket.sentFrames.slice(-6)
              .map((frame) => frame.messageType),
            receivedMessageTypes: socket.receivedFrames
              .slice(-6).map(safeCollaborationFrameSummary),
            socketError: socket.socketError,
            plaintextPresent: socket.plaintextPresent,
          }));
        const safeCloseEvents = await secondPage.evaluate(() =>
          (window.__terminalCollaborationSocketCloseMetadata || []).slice(-4)
            .map((event) => ({
              socketIndex: event.socketIndex,
              ageMs: event.ageMs,
              code: event.code,
              category: event.category,
              reasonCategory: event.reasonCategory,
              wasClean: event.wasClean,
            })),
        ).catch(() => []);
        const safeObserverStatus = await secondPage.evaluate(() =>
          [...document.querySelectorAll('[aria-label]')]
            .map((element) => element.getAttribute('aria-label') || '')
            .filter((label) => label.startsWith('Observer ') ||
              label.includes('输入控制') || label.includes('授权'))
            .map((label) => ({ category: label.startsWith('Observer ')
              ? label : 'control_status', length: label.length })),
        ).catch(() => []);
        const pagePathname = await secondPage.evaluate(() =>
          window.location.pathname,
        ).catch(() => null);
        const visibleDialogCount = await secondPage.getByRole('dialog')
          .evaluateAll((elements) => elements.filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.visibility !== 'hidden' && style.display !== 'none' &&
              Number(style.opacity) !== 0;
          }).length).catch(() => -1);
        const readOnlyTitle = await terminalShareTitleEvidence(
          secondPage, 'Shared terminal · read only',
        );
        const controllerTitle = await terminalShareTitleEvidence(
          secondPage, 'Shared terminal · host-approved control',
        );
        const leaveShareAction = secondPage.getByRole('button', {
          name: 'Leave shared terminal', exact: true,
        });
        const inputAriaLabel = await controllerInput.getAttribute('aria-label')
          .catch(() => null);
        const safeInputLabel = inputAriaLabel === 'Host-approved terminal input'
          ? 'Host-approved terminal input'
          : inputAriaLabel == null ? 'missing' : 'other';
        console.log('Profile B controller join safe failure evidence', JSON.stringify({
          pathname: pagePathname,
          visibleDialogCount,
          knownShareUi: {
            hostApprovedTitleVisible: controllerTitle.visible,
            readOnlyTitleVisible: readOnlyTitle.visible,
            joinActionVisible: await exactLeaseJoinAction.isVisible()
              .catch(() => false),
            leaveActionVisible: await leaveShareAction.isVisible()
              .catch(() => false),
          },
          titleSemantics: {
            hostApprovedTitleAriaLabelCount: controllerTitle.count,
            hostApprovedTitleAriaLabelPresent: controllerTitle.visible,
            readOnlyTitleAriaLabelCount: readOnlyTitle.count,
            readOnlyTitleAriaLabelPresent: readOnlyTitle.visible,
          },
          controllerInputUi: {
            label: safeInputLabel,
            visible: await controllerInput.isVisible().catch(() => false),
          },
          joinActionCount: await exactLeaseJoinAction.count().catch(() => -1),
          joinActionVisible: await exactLeaseJoinAction.isVisible().catch(() => false),
          controllerTitleCount: controllerTitle.count,
          controllerInputCount: await controllerInput.count().catch(() => -1),
          readOnlyTitleCount: readOnlyTitle.count,
          observerStatus: safeObserverStatus,
          controllerLeaseTicketEvents,
          targetSockets,
          safeCloseEvents,
          pageErrorCount: pageErrors.length,
          recentPageErrorKinds: pageErrors.slice(-5).map((event) => ({
            name: event.name,
            category: event.category,
          })),
          errorType: error?.name || 'Error',
        }));
        throw error;
      }
      const inputBox = secondPage.getByRole('textbox', {
        name: 'Host-approved terminal input', exact: true,
      });
      await inputBox.waitFor({ state: 'visible', timeout: 10000 });
      const controllerSocket = terminalCollaborationSocketsForPage(secondPage).at(-1);
      assertThat(terminalCollaborationSocketsForPage(secondPage).length ===
        v2ObserverSocketBaseline + 3 && controllerSocket?.opened,
      'Profile B did not establish the separate encrypted controller input socket');
      const observerSocketForV2 = terminalCollaborationSocketsForPage(secondPage)
        .slice(v2ObserverSocketBaseline)
        .filter((socket) => socket.receivedFrames.some((frame) =>
          frame.messageType === 'authenticated' &&
          frame.authentication?.roleIsController === false))
        .at(-1);
      assertThat(observerSocketForV2 != null &&
        observerSocketForV2.socketIndex !== controllerSocket.socketIndex,
      'Profile B read-only observer and controller did not use distinct sockets');
      const hostRelayTicketBaselineAfterGrant = relayTicketChecksForPage(page).length;
      const hostRelaySocketBaselineAfterGrant = relaySocketsForPage(page).length;
      const bRelayTicketBaselineAfterGrant = relayTicketChecksForPage(secondPage).length;
      const bRelaySocketBaselineAfterGrant = relaySocketsForPage(secondPage).length;
      const targetSshdBeforeInput = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const bastionSshdBeforeInput = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const hostReceivedBeforeInput = v2HostSocket?.receivedFrames.length ?? 0;
      const hostSentBeforeInput = v2HostSocket?.sentFrames.length ?? 0;
      const observerReceivedBeforeInput = observerSocketForV2?.receivedFrames.length ?? 0;
      const observerFingerprintBeforeInput =
        await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 6000, null,
          'Shared terminal · host-approved control',
        );

      safeRunStage = 'Profile B types a command through encrypted input';
      const controllerInputBox = await inputBox.boundingBox();
      assertThat(controllerInputBox && controllerInputBox.width > 100 &&
        controllerInputBox.height > 100,
      'Profile B host-approved terminal input semantics were not measurable');
      await secondPage.mouse.click(
        Math.round(controllerInputBox.x + controllerInputBox.width / 2),
        Math.round(controllerInputBox.y + controllerInputBox.height / 2),
      );
      await secondPage.waitForTimeout(300);
      const controllerInputSemanticsFocused = await inputBox
        .getAttribute('aria-focused')
        .then((value) => value === 'true')
        .catch(() => false);
      const controllerFocusState = await safePageInputFocusState(secondPage);
      console.log('Profile B controller terminal focus safe evidence',
        JSON.stringify({ controllerInputSemanticsFocused, ...controllerFocusState }));
      assertThat(await inputBox.isVisible().catch(() => false) &&
        controllerFocusState.pageFocused,
      'Profile B terminal input was unavailable or the browser page lacked focus');
      await installSafePageInputCounters(secondPage);
      await secondPage.keyboard.type(controllerCommand, { delay: 5 });
      await secondPage.keyboard.press('Enter');
      const v2OutputDeadline = Date.now() + 15000;
      let observerOutputArrived = false;
      let controllerCommandExecuted = false;
      while (Date.now() < v2OutputDeadline) {
        observerOutputArrived = (observerSocketForV2?.receivedFrames.length ?? 0) >
            observerReceivedBeforeInput &&
          (v2HostSocket?.receivedFrames.length ?? 0) > hostReceivedBeforeInput;
        controllerCommandExecuted = fs.existsSync(controllerResultPath) &&
          fs.readFileSync(controllerResultPath, 'utf8').trim() ===
            controllerOutputMarker;
        if (observerOutputArrived && controllerCommandExecuted) break;
        await secondPage.waitForTimeout(100);
      }
      console.log('Profile B controller command safe input evidence', JSON.stringify({
        inputVisible: await inputBox.isVisible().catch(() => false),
        inputFocus: await safePageInputFocusState(secondPage),
        pageInputEvents: await readAndRemoveSafePageInputCounters(secondPage),
        controllerCommandUtf8Length: Buffer.byteLength(controllerCommand, 'utf8'),
        controllerSocket: {
          opened: controllerSocket.opened,
          closed: controllerSocket.closed,
          sentFrameCount: controllerSocket.sentFrames.length,
          sentMessageTypes: controllerSocket.sentFrames.slice(-6)
            .map(safeCollaborationFrameSummary),
          receivedFrameCount: controllerSocket.receivedFrames.length,
          socketError: controllerSocket.socketError,
          plaintextPresent: controllerSocket.plaintextPresent,
        },
        hostReceivedMessageTypes: v2HostSocket.receivedFrames.slice(-6)
          .map(safeCollaborationFrameSummary),
        hostSentFrameCount: v2HostSocket.sentFrames.length,
        hostSentFrameDelta: v2HostSocket.sentFrames.length - hostSentBeforeInput,
        hostSentMessageTypes: v2HostSocket.sentFrames.slice(-12)
          .map(safeCollaborationFrameSummary),
        hostReceivedInputFrameCount: v2HostSocket.receivedFrames
          .filter((frame) => frame.messageType === 'input').length,
        hostSocketClosed: v2HostSocket.closed,
        hostSocketError: v2HostSocket.socketError,
        observerReceivedMessageTypes: observerSocketForV2.receivedFrames
          .slice(-6).map(safeCollaborationFrameSummary),
        observerReceivedOutputFrameCount: observerSocketForV2.receivedFrames
          .filter((frame) => frame.messageType === 'frame' &&
            frame.frameKind === 'output').length,
        observerSocketClosed: observerSocketForV2.closed,
        observerSocketError: observerSocketForV2.socketError,
        closeMetadata: await secondPage.evaluate((socketIndexes) =>
          (window.__terminalCollaborationSocketCloseMetadata || [])
            .filter((entry) => socketIndexes.includes(entry.socketIndex))
            .map((entry) => ({
              socketIndex: entry.socketIndex,
              ageMs: entry.ageMs,
              code: entry.code,
              category: entry.category,
              wasClean: entry.wasClean,
              reasonCategory: entry.reasonCategory,
            })), [controllerSocket.socketIndex, observerSocketForV2.socketIndex]),
        hostCloseMetadata: await page.evaluate((socketIndex) =>
          (window.__terminalCollaborationSocketCloseMetadata || [])
            .filter((entry) => entry.socketIndex === socketIndex)
            .map((entry) => ({
              socketIndex: entry.socketIndex,
              ageMs: entry.ageMs,
              code: entry.code,
              category: entry.category,
              wasClean: entry.wasClean,
              reasonCategory: entry.reasonCategory,
            })), v2HostSocket.socketIndex),
        serverControllerFrameRejectReasons: [...fs.readFileSync(
          serverLogPath, 'utf8',
        ).matchAll(/event="terminal_controller_frame_rejected" reason="([a-z_]+)"/g)]
          .map((match) => match[1]),
        controllerCommandExecuted,
        resultFilePresent: fs.existsSync(controllerResultPath),
        observerOutputArrived,
      }));
      const targetSshdAfterInput = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const bastionSshdAfterInput = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      let observerOutputFingerprint;
      try {
        observerOutputFingerprint = await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 10000, observerFingerprintBeforeInput,
          'Shared terminal · host-approved control',
        );
      } catch (error) {
        console.log('Profile B controller output safe visual failure evidence',
          JSON.stringify({
            fingerprint: safeTerminalFingerprintEvidence(secondPage, error),
            controllerCommandExecuted,
            resultFilePresent: fs.existsSync(controllerResultPath),
            observerOutputArrived,
            controllerSentFrameCount: controllerSocket.sentFrames.length,
            controllerReceivedMessageTypes: controllerSocket.receivedFrames
              .slice(-6).map(safeCollaborationFrameSummary),
            hostReceivedMessageTypes: v2HostSocket.receivedFrames
              .slice(-6).map(safeCollaborationFrameSummary),
            observerReceivedMessageTypes: observerSocketForV2.receivedFrames
              .slice(-6).map(safeCollaborationFrameSummary),
          }));
        await secondPage.screenshot({
          path: '/home/atermius-terminal-controller-output-failure.png',
          fullPage: false,
        }).catch(() => {});
        throw error;
      }
      assertThat(observerOutputArrived && controllerCommandExecuted &&
        observerOutputFingerprint !== observerFingerprintBeforeInput &&
        controllerSocket.sentFrames.length > 1 &&
        !controllerSocket.plaintextPresent &&
        !observerSocketForV2?.plaintextPresent &&
        !v2HostSocket?.plaintextPresent,
      'v2 input or resulting host output was missing or appeared in plaintext on a server WebSocket');
      assertThat(relayTicketChecksForPage(page).length === hostRelayTicketBaselineAfterGrant &&
        relaySocketsForPage(page).length === hostRelaySocketBaselineAfterGrant &&
        relayTicketChecksForPage(secondPage).length === bRelayTicketBaselineAfterGrant &&
        relaySocketsForPage(secondPage).length === bRelaySocketBaselineAfterGrant,
      'controller input created a separate SSH Relay ticket or socket');
      assertThat(safeCounterDelta(targetSshdBeforeInput, targetSshdAfterInput,
        ['tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionStarts'])
        .sessionStarts === 0 &&
        safeCounterDelta(bastionSshdBeforeInput, bastionSshdAfterInput,
          ['tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionStarts'])
          .sessionStarts === 0,
      'controller input opened a new SSH session instead of using Profile A’s live shell');

      safeRunStage = 'Profile A revokes the controller while SSH room stays live';
      const controllerSocketSentBeforeRevoke = controllerSocket.sentFrames.length;
      await page.getByRole('button', { name: 'Revoke input control', exact: true })
        .click();
      await controllerInput.waitFor({ state: 'detached', timeout: 10000 });
      await secondPage.getByRole('button', {
        name: 'Join host-granted control', exact: true,
      }).waitFor({ state: 'detached', timeout: 10000 });
      const controllerClosedDeadline = Date.now() + 10000;
      while (Date.now() < controllerClosedDeadline && !controllerSocket.closed) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(controllerSocket.closed &&
        controllerSocket.sentFrames.length === controllerSocketSentBeforeRevoke &&
        !v2HostSocket.closed && !observerSocketForV2.closed,
      'host revocation did not close only the controller socket and restore read-only observation');
      const revokedTicketStatus = await secondPage.evaluate(async ({
        requestUrl,
        authorization,
      }) => {
        const response = await fetch(requestUrl, {
          method: 'POST',
          headers: { authorization },
        });
        return response.status;
      }, {
        requestUrl: new URL(
          `/api/v1/vaults/${v2Context.vaultId}/terminal-sessions/${v2SessionId}/controller-lease/ticket`,
          baseUrl,
        ).toString(),
        authorization: bearerTokensByPage.get(secondPage),
      });
      assertThat(revokedTicketStatus >= 400,
        'the exact target device redeemed a revoked controller lease');

      const afterRevokeMarker =
        `WEB_TERMINAL_CONTROL_AFTER_REVOKE_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
      terminalCollaborationPrivacy.markers.push(afterRevokeMarker);
      const observerFramesAfterRevoke = observerSocketForV2.receivedFrames.length;
      const hostFingerprintBeforeRevokeOutput =
        await stableTerminalVisualFingerprint(page, user, targetAddress);
      const observerFingerprintBeforeRevokeOutput =
        await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 6000, null,
          'Shared terminal · read only',
        );
      await sendCommandToActiveTerminal(page, user, targetAddress,
        `printf '%s\\n' '${afterRevokeMarker}'`, { activeHostName: hostName });
      const observerPostRevokeDeadline = Date.now() + 10000;
      while (Date.now() < observerPostRevokeDeadline &&
          observerSocketForV2.receivedFrames.length === observerFramesAfterRevoke) {
        await secondPage.waitForTimeout(100);
      }
      const hostFingerprintAfterRevokeOutput =
        await stableTerminalVisualFingerprint(
          page, user, targetAddress, 10000, hostFingerprintBeforeRevokeOutput,
        );
      const observerFingerprintAfterRevokeOutput =
        await stableTerminalVisualFingerprint(
          secondPage, user, targetAddress, 10000,
          observerFingerprintBeforeRevokeOutput,
          'Shared terminal · read only',
        );
      assertThat(observerSocketForV2.receivedFrames.length > observerFramesAfterRevoke &&
        hostFingerprintAfterRevokeOutput !== hostFingerprintBeforeRevokeOutput &&
        observerFingerprintAfterRevokeOutput !== observerFingerprintBeforeRevokeOutput &&
        !v2HostSocket.closed && !observerSocketForV2.closed &&
        relaySocketsForPage(page).some((socket) => socket.opened && !socket.closed),
      'SSH/output observation stopped when the host revoked only input control');

      const markerAfterStopStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, postStopMarker,
      );
      const controllerInputStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, controllerCommandMarker,
      );
      const controllerOutputStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, controllerOutputMarker,
      );
      const afterRevokeStorageEvidence = fileMarkerAbsenceEvidence(
        collaborationStorageFiles, afterRevokeMarker,
      );
      const finalStoragePrivacyEvidence = terminalCollaborationPrivacy.markers
        .map((marker) => fileMarkerAbsenceEvidence(collaborationStorageFiles, marker));
      assertThat(finalStoragePrivacyEvidence.every((evidence) =>
          evidence.plaintextMarkerAbsent) &&
        markerAfterStopStorageEvidence.plaintextMarkerAbsent &&
        controllerInputStorageEvidence.plaintextMarkerAbsent &&
        controllerOutputStorageEvidence.plaintextMarkerAbsent &&
        afterRevokeStorageEvidence.plaintextMarkerAbsent &&
        relayTicketChecksForPage(page).length === aRelayTicketBaseline &&
        relaySocketsForPage(page).length === aRelaySocketBaseline &&
        aOpenRelaySocketsBeforeCollaboration.length > 0 &&
        aOpenRelaySocketsBeforeCollaboration.every((socket) =>
          relaySocketsForPage(page).includes(socket) &&
          socket.opened && !socket.closed),
      'Profile A SSH stopped working after collaboration control or leaked plaintext to server storage');
      const finalSshd = {
        target: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
        bastion: sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
      };
      const hostSshdDeltas = {
        target: safeCounterDelta(sshdBeforeCollaboration.target, finalSshd.target,
          ['tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionStarts']),
        bastion: safeCounterDelta(sshdBeforeCollaboration.bastion, finalSshd.bastion,
          ['tcpConnectionsAccepted', 'publicKeyAccepted', 'sessionStarts']),
      };
      const finalCollaborationHttpDeadline = Date.now() + 5000;
      while (Date.now() < finalCollaborationHttpDeadline &&
          terminalCollaborationPrivacy.checks.length < 8) {
        await page.waitForTimeout(100);
      }
      assertThat(terminalCollaborationPrivacy.checks.length >= 8 &&
        terminalCollaborationPrivacy.checks.every((check) =>
          check.plaintextAbsent),
      'collaboration create, join, grant, revoke, stop, or denied-ticket HTTP traffic was not fully checked for plaintext');
      assertThat(Object.values(hostSshdDeltas).every((delta) =>
        Object.values(delta).every((value) => value === 0)),
      'terminal sharing opened a new SSHD session instead of using the existing host shell');
      await page.getByRole('button', { name: 'Stop terminal sharing', exact: true })
        .click();
      const v2CloseDeadline = Date.now() + 10000;
      while (Date.now() < v2CloseDeadline &&
          (!v2HostSocket.closed || !observerSocketForV2.closed)) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(v2HostSocket.closed && observerSocketForV2.closed,
        'stopping the v2 room did not close its host and observer output sockets');
      console.log('WEB-TERMINAL-COLLABORATION-01 passed: Profile A verified the default v1 read-only share and explicitly enabled a v2 share for one registered Profile B device. The target had no controller action before the validated grant event, joined only its own lease, encrypted terminal input to the existing host SSH shell, and saw continuing encrypted stdout; the server never saw the command plaintext. A wrong device could not redeem the lease. Host revoke immediately closed the controller socket and removed target input while the host SSH and observer output channel remained live. Both v1 and v2 payloads, server storage/logs, and collaboration WebSocket traffic contained no output marker, input command, or SSH private-key plaintext.',
        JSON.stringify({
          hostCreateStatus: createRequests[0].status,
          v1ProtocolVersion: terminalCollaborationPrivacy.protocolVersions[0],
          v2ProtocolVersion: terminalCollaborationPrivacy.protocolVersions[1],
          observerJoinStatus: secondApiEvents.find((event) =>
            event.path.endsWith('/ticket') && event.status >= 200 &&
            event.status < 300)?.status ?? null,
          rejoinDenied: true,
          observerClose: observerCloseEvidence[0],
          bRelayTicketDelta: bRelayTicketsAfterObserver - bRelayTicketBaseline,
          bRelaySocketDelta: bRelaySocketsAfterObserver - bRelaySocketBaseline,
          observerSshdDeltas,
          markerStorageAbsent: markerStorageEvidence.plaintextMarkerAbsent &&
            markerAfterStopStorageEvidence.plaintextMarkerAbsent &&
            finalStoragePrivacyEvidence.every((evidence) =>
              evidence.plaintextMarkerAbsent),
          sshPrivateKeysAbsentFromServer: targetKeyStorageEvidence.plaintextMarkerAbsent &&
            bastionKeyStorageEvidence.plaintextMarkerAbsent,
          collaborationHttpPlaintextAbsent: terminalCollaborationPrivacy.checks
            .every((check) => check.plaintextAbsent),
          collaborationFramePlaintextAbsent: !hostCollaborationSocket.plaintextPresent &&
            !observerCollaborationSocket.plaintextPresent &&
            !controllerSocket.plaintextPresent &&
            !observerSocketForV2.plaintextPresent &&
            !v2HostSocket.plaintextPresent,
          observerViewportChangedAfterEncryptedOutput:
            observerFingerprintAfterOutput !== observerFingerprintBeforeOutput,
          v2GrantAppearedOnlyAfterHostApproval: joinControlBeforeGrant === 0 &&
            editableInputBeforeGrant === 0,
          controllerCommandExecutedInExistingShell: controllerCommandExecuted,
          controllerStdoutReachedObserver: observerOutputArrived &&
            observerOutputFingerprint !== observerFingerprintBeforeInput,
          wrongDeviceTicketStatus,
          revokedTicketStatus,
          controllerSocketClosedOnRevoke: controllerSocket.closed,
          observerOutputContinuedAfterRevoke:
            observerFingerprintAfterRevokeOutput !== observerFingerprintBeforeRevokeOutput,
          v2ControllerSocketClosedOnSessionStop: v2HostSocket.closed &&
            observerSocketForV2.closed,
          hostSshdDeltas,
        }));
      targetPrivateKey = '';
      bastionPrivateKey = '';
      terminalCollaborationPrivacy.markers = [];
      terminalCollaborationPrivacy.active = false;
      return;
    }
    if (multihopOnly) {
      safeRunStage = 'profile B resolves synced two-hop Host';
      const escapedMultiHopHostName = multiHopHostName
        .replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const secondDeviceMultiHopHostCard = secondPage.getByRole('group', {
        name: new RegExp(escapedMultiHopHostName),
      }).first();
      await secondDeviceMultiHopHostCard.waitFor({ state: 'visible', timeout: 30000 });
      const profileBHostSyncEvidence = secretSyncPrivacy.checks.filter((check) =>
        check.profile === 'B' && check.direction === 'response' &&
        check.kind === 'changes');
      assertThat(profileBHostSyncEvidence.length > 0 &&
        profileBHostSyncEvidence.every((check) => check.markerAbsent),
      'profile B SSH-record sync response exposed the Credential secret');
      console.log('stage: profile B synced the two-hop Host without plaintext Credential secret',
        JSON.stringify({ twoHopHostVisible: true,
          profileBEncryptedChangesResponses: profileBHostSyncEvidence.length,
          credentialSecretAbsent: true }));
      await runFocusedMultiHopAcceptance(secondPage, secondDeviceMultiHopHostCard);
      console.log('WEB-RELAY-01 focused multi-hop passed: synced A -> B -> loopback Target route, four first-hop-targeted Relay handshake attempts with the final WebSocket active, distinct hop credentials, shell IO, disconnect, and independent changed-key rejection at Target, Bastion B, and Bastion A.');
      return;
    }
    const secondDeviceTicketBaseline = relayTicketTargetChecks.length;
    safeRunStage = 'profile B connects to the synced Host over the isolated SSH Relay';
    await secondDeviceSyncedHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
    let secondConnectionState = await waitForTerminalConnectionOrTrust(secondPage, hostName, 45000);
    let secondDeviceTrustPrompts = 0;
    while (secondConnectionState === 'trust_prompt' && secondDeviceTrustPrompts < 2) {
      await click(secondPage, 'Trust after verification');
      secondDeviceTrustPrompts += 1;
      secondConnectionState = await waitForTerminalConnectionOrTrust(secondPage, hostName, 45000);
    }
    assertThat(secondConnectionState === 'connected',
      'profile B did not connect to its synced Host through the isolated Relay');
    await waitText(secondPage, 'CONNECTED', 15000);
    assertThat(relayTicketTargetChecks.length > secondDeviceTicketBaseline &&
      relayTicketTargetChecks.slice(secondDeviceTicketBaseline).every(Boolean),
    'profile B Relay ticket did not target only the allowlisted bastion');
    const secondDeviceRelaySocket = relaySockets.at(-1);
    assertThat(secondDeviceRelaySocket?.opened && !secondDeviceRelaySocket.closed,
      'profile B Relay WebSocket was not active after SSH connection');
    console.log('stage: independently approved profile B pulled encrypted SSH records and connected through the same isolated Relay fixture',
      JSON.stringify({ secondDeviceTrustPrompts, secondDeviceRelayTicketCount: relayTicketTargetChecks.length - secondDeviceTicketBaseline }));

    if (portForwardOnly) {
      safeRunStage = 'profile B verifies the pulled forwarding profile and unsupported Web runtime';
      await terminalTabButton(secondPage, hostName, 'active');
      await waitText(secondPage, 'CONNECTED');
      const bExecutionBaseline = {
        relayTickets: relayTicketTargetChecks.length,
        relaySockets: relaySockets.length,
        apiRequests: secondApiRequests.length,
        targetSshd: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
        bastionSshd: sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
        sshForwardingRequests: sshForwardingRequestCount([
          path.join(tempRoot, 'sshd.log'),
          path.join(tempRoot, 'jump-sshd.log'),
        ]),
      };
      const listenerBeforeBDialog = await loopbackTcpListenerEvidence(portForwardBindPort);
      assertThat(!listenerBeforeBDialog.listening,
        'forward profile listener was already open before profile B opened the Web manager');
      const profileBUiEvidence = await verifyWebPortForwardDialog(secondPage, 'profile B');
      await waitForVisibleSemanticsText(secondPage,
        'Dynamic forwarding is a loopback-only SOCKS5 CONNECT proxy without SOCKS authentication.');
      await click(secondPage, 'Close');
      await waitText(secondPage, 'CONNECTED');
      const listenerAfterBDialog = await loopbackTcpListenerEvidence(portForwardBindPort);
      assertThat(!listenerAfterBDialog.listening,
        'profile B Web manager unexpectedly opened the synchronized loopback listener');
      await secondPage.waitForTimeout(250);
      const bChangeResponses = portForwardSyncPrivacy.checks.filter((check) =>
        check.profile === 'B' && check.direction === 'response' && check.kind === 'changes');
      assertThat(bChangeResponses.some((check) => check.status === 200 &&
        check.markerAbsent && Number.isInteger(check.eventCount) && check.eventCount > 0),
      'independently approved profile B did not pull opaque Vault changes');
      assertThat(portForwardSyncPrivacy.checks.length > 0 &&
        portForwardSyncPrivacy.checks.every((check) => check.markerAbsent),
      'a profile A/B sync request or response exposed the forwarding profile name');
      const crossOriginRequests = portForwardSyncPrivacy.checks.filter((check) =>
        check.kind === 'cross_origin');
      assertThat(crossOriginRequests.length === 0,
        'port-forward profile workflows issued a cross-origin browser request');
      const storageEvidence = fileMarkerAbsenceEvidence([
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
      ], portForwardProfileName);
      assertThat(storageEvidence.scannedFiles > 0 && storageEvidence.plaintextMarkerAbsent,
        'server SQLite storage or sidecars contain the synced forwarding profile plaintext marker');
      const targetAfterBDialog = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const bastionAfterBDialog = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const targetDelta = safeCounterDelta(bExecutionBaseline.targetSshd,
        targetAfterBDialog, ['tcpConnectionsAccepted', 'publicKeyAccepted',
          'sessionOpenRequests', 'sessionStarts']);
      const bastionDelta = safeCounterDelta(bExecutionBaseline.bastionSshd,
        bastionAfterBDialog, ['tcpConnectionsAccepted', 'publicKeyAccepted',
          'sessionOpenRequests', 'sessionStarts']);
      const unexpectedApiRequests = secondApiRequests
        .slice(bExecutionBaseline.apiRequests)
        .filter((request) => /relay\/tickets|forward|tunnel/i.test(request.path));
      const forwardingRequestCount = sshForwardingRequestCount([
        path.join(tempRoot, 'sshd.log'),
        path.join(tempRoot, 'jump-sshd.log'),
      ]);
      assertThat(relayTicketTargetChecks.length === bExecutionBaseline.relayTickets &&
        relaySockets.length === bExecutionBaseline.relaySockets &&
        unexpectedApiRequests.length === 0 &&
        Object.values(targetDelta).every((value) => value === 0) &&
        Object.values(bastionDelta).every((value) => value === 0) &&
        forwardingRequestCount === bExecutionBaseline.sshForwardingRequests,
      'profile B Web profile display issued an SSH/Relay forwarding execution request');
      console.log('WEB-PORT-FORWARD-01 passed: encrypted local-device SOCKS profile synced from the connected owner to independently approved profile B; both Web managers showed Unavailable in Web with no forwarding action; no plaintext marker, listener, Relay ticket/socket, SSH session, or SSH forwarding request was observed.',
        JSON.stringify({
          profileAUi: portForwardAUiEvidence,
          profileBUi: profileBUiEvidence,
          profileBChangesResponseCount: bChangeResponses.length,
          profileBChangesEventCount: Math.max(...bChangeResponses
            .map((check) => check.eventCount || 0)),
          serverStorageMarkerAbsent: storageEvidence.plaintextMarkerAbsent,
          loopbackListenerOpen: false,
          relayTicketDelta: relayTicketTargetChecks.length -
            bExecutionBaseline.relayTickets,
          relayWebSocketDelta: relaySockets.length - bExecutionBaseline.relaySockets,
          sshForwardingRequestDelta: forwardingRequestCount -
            bExecutionBaseline.sshForwardingRequests,
        }));
      portForwardSyncPrivacy.active = false;
      portForwardSyncPrivacy.marker = null;
      return;
    }

    const markerValue = `WEB_RELAY_SHELL_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const markerPath = path.join(remoteRoot, 'shell-marker');
    const remoteMarkerPath = '/tmp/remote/shell-marker';
    const shellCommand = `i=0; while [ "$i" -lt 80 ]; do i=$((i+1)); printf 'SCROLL_${markerValue}_%s\\n' "$i"; done; printf '%s\\n' '${markerValue}' > '${remoteMarkerPath}'; printf '%s\\n' '${markerValue}'; printf '\\033[?25l'`;
    safeRunStage = 'relay SSH shell-marker execution';
    let headerBox = null;
    let terminalRect = null;
    let terminalPoint = null;
    const terminalInteraction = {};
    const relayFrameCounts = () => relaySockets.map((event) => ({
      sent: event.sentFrames.length,
      received: event.receivedFrames.length,
    }));
    const firstOutputFrameBaseline = firstRelaySocket.receivedFrames.length;
    let markerObserved = false;
    try {
      const header = page.getByText(`${user}@${targetAddress}`, { exact: true }).first();
      headerBox = await header.boundingBox();
      assertThat(headerBox, 'connected terminal header is not visible');
      const viewport = await page.evaluate(() => ({
        width: window.innerWidth,
        height: window.innerHeight,
      }));
      const terminalTop = Math.ceil(headerBox.y + headerBox.height + 8);
      terminalRect = {
        x: Math.round(headerBox.x),
        y: terminalTop,
        width: Math.max(0, Math.round(viewport.width - headerBox.x - 16)),
        height: Math.max(0, Math.round(viewport.height - terminalTop - 16)),
      };
      assertThat(terminalRect.width > 100 && terminalRect.height > 100,
        'terminal content area has no usable visible bounds');
      terminalPoint = {
        x: Math.round(terminalRect.x + terminalRect.width / 2),
        y: Math.round(terminalRect.y + terminalRect.height / 2),
      };
      await installTerminalInputProbe(page);
      terminalInteraction.beforePointerClick = await terminalInteractionSummary(page, terminalPoint);
      terminalInteraction.inputCountsBeforePointerClick = await readTerminalInputCounts(page);
      terminalInteraction.frameCountsBeforePointerClick = relayFrameCounts();
      await page.mouse.click(terminalPoint.x, terminalPoint.y);
      terminalInteraction.pointerClickPerformed = true;
      await page.waitForTimeout(400);
      terminalInteraction.afterPointerClick = await terminalInteractionSummary(page, terminalPoint);
      terminalInteraction.inputCountsAfterPointerClick = await readTerminalInputCounts(page);
      terminalInteraction.frameCountsAfterPointerClick = relayFrameCounts();
      await page.keyboard.type(shellCommand, { delay: 5 });
      await page.waitForTimeout(250);
      terminalInteraction.afterTyping = await terminalInteractionSummary(page, terminalPoint);
      terminalInteraction.inputCountsAfterTyping = await readTerminalInputCounts(page);
      terminalInteraction.frameCountsAfterTyping = relayFrameCounts();
      await page.keyboard.press('Enter');
      terminalInteraction.afterEnter = await terminalInteractionSummary(page, terminalPoint);
      terminalInteraction.inputCountsAfterEnter = await readTerminalInputCounts(page);
      terminalInteraction.frameCountsAfterEnter = relayFrameCounts();
      const markerDeadline = Date.now() + 20000;
      while (Date.now() < markerDeadline) {
        try {
          markerObserved = fs.readFileSync(markerPath, 'utf8').trim() === markerValue;
        } catch (_) { markerObserved = false; }
        if (markerObserved) break;
        await page.waitForTimeout(200);
      }
      assertThat(markerObserved, 'terminal command did not create the temporary SSH shell marker');
      assertThat(await waitForRelayOutputFrame(
        page, firstRelaySocket, firstOutputFrameBaseline),
      'first terminal did not receive its shell output');
    } catch (error) {
      const diagnostic = await relayFailureDiagnostic({
        ...relayDiagnosticInputs,
        error,
        phase: 'terminal_shell_marker_failed',
      });
      let markerBytes = null;
      try { markerBytes = fs.statSync(markerPath).size; } catch (_) {}
      diagnostic.terminal = {
        connectedHeaderVisible: Boolean(headerBox),
        terminalRect,
        terminalPoint,
        interactions: terminalInteraction,
        finalFrameCounts: relayFrameCounts(),
        markerFilePresent: markerBytes !== null,
        markerFileBytes: markerBytes,
      };
      console.log('SSH shell marker diagnostic', redactCurrentSecrets(JSON.stringify(diagnostic, null, 2)));
      throw new Error('SSH terminal shell marker phase failed');
    }
    const outputDeadline = Date.now() + 2500;
    let terminalOutputVisible = false;
    while (Date.now() < outputDeadline) {
      const output = page.getByText(markerValue, { exact: true }).first();
      terminalOutputVisible = await output.count() > 0 && await output.isVisible().catch(() => false);
      if (terminalOutputVisible) break;
      await page.waitForTimeout(100);
    }
    if (terminalOutputVisible) {
      assertThat(await page.getByText(markerValue, { exact: true }).first().isVisible(),
        'terminal output marker was found but is not visible');
      console.log('stage: shell marker file and terminal output are verified through browser semantics');
    } else {
      console.log('stage: shell marker file verified; terminal output text is not exposed by the browser semantics tree');
    }

    safeRunStage = 'Bash shell history opens the explicit opt-in dialog';
    const historyOptInButton = page.getByRole('button', {
      name: 'Enable Bash command history', exact: true,
    });
    await historyOptInButton.waitFor({ state: 'visible', timeout: 10000 });
    await historyOptInButton.click();
    await waitText(page, 'Enable Bash integration');
    await page.waitForTimeout(200);
    const historyInputActivity = (counts) => JSON.stringify(
      counts?.terminalInput || null,
    );
    const beforeHistoryCopyInput = await readTerminalInputCounts(page);
    const beforeHistoryCopyFrames = firstRelaySocket.sentFrames.length;
    safeRunStage = 'Bash shell history copies the setup command without sending';
    await click(page, 'Enable and copy');
    await waitText(page, 'Copied. Paste this command into the terminal:');
    const copiedHistoryBootstrap = await readClipboard(page).catch(() => null);
    const afterHistoryCopyInput = await readTerminalInputCounts(page);
    const relayFramesAfterHistoryCopy = firstRelaySocket.sentFrames
      .slice(beforeHistoryCopyFrames)
      .map(({ kind, bytes }) => ({ kind, bytes }));
    const relayFrameBytesAfterHistoryCopy = relayFramesAfterHistoryCopy
      .reduce((total, frame) => total + frame.bytes, 0);
    const historyBootstrapEvidence = {
      copied: typeof copiedHistoryBootstrap === 'string',
      length: typeof copiedHistoryBootstrap === 'string'
        ? copiedHistoryBootstrap.length : null,
      interactiveTtyGuard: typeof copiedHistoryBootstrap === 'string' &&
        copiedHistoryBootstrap.startsWith(
          'if [[ $- == *i* && -t 0 && -t 1 ]]',
        ),
      promptHook: typeof copiedHistoryBootstrap === 'string' &&
        copiedHistoryBootstrap.includes('__atermius_prompt()'),
      offFunction: typeof copiedHistoryBootstrap === 'string' &&
        copiedHistoryBootstrap.includes('atermius_off()'),
    };
    console.log('Bash shell history clipboard safe evidence',
      JSON.stringify(historyBootstrapEvidence));
    console.log('Bash shell history no-send safe evidence', JSON.stringify({
      terminalInputBefore: beforeHistoryCopyInput?.terminalInput || null,
      terminalInputAfter: afterHistoryCopyInput?.terminalInput || null,
      relayFramesAfter: relayFramesAfterHistoryCopy,
    }));
    assertThat(typeof copiedHistoryBootstrap === 'string' &&
      copiedHistoryBootstrap.length > 500 &&
      historyBootstrapEvidence.interactiveTtyGuard &&
      copiedHistoryBootstrap.includes('__atermius_prompt()') &&
      copiedHistoryBootstrap.includes('atermius_off()'),
    'Bash history opt-in did not copy the expected explicit bootstrap command');
    assertThat(historyInputActivity(beforeHistoryCopyInput) ===
      historyInputActivity(afterHistoryCopyInput) &&
      typeof copiedHistoryBootstrap === 'string' &&
      relayFrameBytesAfterHistoryCopy < copiedHistoryBootstrap.length / 2,
    'copying Bash history setup changed terminal input or sent the setup command');
    console.log('Bash shell history setup safe evidence', JSON.stringify({
      integrationDialogOpened: true,
      setupCommandCopied: true,
      setupCommandLength: copiedHistoryBootstrap.length,
      setupCommandWasNotAutoSent: true,
    }));

    safeRunStage = 'Bash shell history setup is explicitly pasted into the SSH terminal';
    await click(page, 'Close');
    const pasteSentFrameBaseline = firstRelaySocket.sentFrames.length;
    await pasteClipboardToActiveTerminal(page, user, targetAddress, {
      activeHostName: hostName,
    });
    const pasteFrameDeadline = Date.now() + 10000;
    while (Date.now() < pasteFrameDeadline &&
        firstRelaySocket.sentFrames.length <= pasteSentFrameBaseline) {
      await page.waitForTimeout(100);
    }
    assertThat(firstRelaySocket.sentFrames.length > pasteSentFrameBaseline,
      'explicit clipboard paste did not reach the active Relay terminal');
    const historyOutputFrameBaseline = firstRelaySocket.receivedFrames.length;
    safeRunStage = 'Bash shell history setup is explicitly submitted with Enter';
    await page.keyboard.press('Enter');
    assertThat(await waitForRelayOutputFrame(
      page, firstRelaySocket, historyOutputFrameBaseline, 15000),
    'Bash shell history setup did not return output to the active terminal');

    const historyMarker =
      `WEB_RELAY_HISTORY_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const historyCommand = `printf '%s\\n' '${historyMarker}'`;
    assertThat(!historyCommand.includes('>') &&
      !historyCommand.includes('$(') && !historyCommand.includes(';'),
    'Bash history acceptance command is not the expected side-effect-free printf');
    const historyOutputFrameBeforeCommand = firstRelaySocket.receivedFrames.length;
    safeRunStage = 'Bash shell history executes the safe remote command';
    await sendCommandToActiveTerminal(page, user, targetAddress, historyCommand, {
      activeHostName: hostName,
    });
    assertThat(await waitForRelayOutputFrame(
      page, firstRelaySocket, historyOutputFrameBeforeCommand, 15000),
    'safe Bash history command produced no SSH terminal output');
    await waitForRelaySocketQuiet(page, firstRelaySocket, 500, 8000);

    safeRunStage = 'Bash shell history displays the command and exit status';
    const commandHistoryButton = page.getByRole('button', {
      name: 'View command history', exact: true,
    });
    const enableHistoryButton = page.getByRole('button', {
      name: 'Enable Bash command history', exact: true,
    });
    const connectedTargetTab = page.getByRole('button', {
      name: `${hostName} terminal tab, connected, active`, exact: true,
    });
    console.log('Bash shell history capture state safe evidence', JSON.stringify({
      viewHistoryButtonCount: await commandHistoryButton.count(),
      viewHistoryButtonVisible: await commandHistoryButton.isVisible().catch(() => false),
      viewHistoryButtonEnabled: await commandHistoryButton.isEnabled().catch(() => false),
      viewHistoryButtonBox: await commandHistoryButton.boundingBox().catch(() => null),
      enableHistoryButtonCount: await enableHistoryButton.count(),
      connectedTargetTabCount: await connectedTargetTab.count(),
      outputFramesAfterSafeCommand:
        firstRelaySocket.receivedFrames.length - historyOutputFrameBeforeCommand,
    }));
    try {
      await click(page, 'View command history');
    } catch (error) {
      const box = await commandHistoryButton.boundingBox().catch(() => null);
      const hit = box ? await page.evaluate(({ x, y }) => {
        const element = document.elementFromPoint(x, y);
        return {
          tagName: element?.tagName?.toLowerCase() || null,
          role: element?.getAttribute('role') || null,
          ariaLabelMatchesExpected: element?.getAttribute('aria-label') ===
            'View command history',
          ariaLabelLength: element?.getAttribute('aria-label')?.length || 0,
        };
      }, { x: box.x + box.width / 2, y: box.y + box.height / 2 }).catch(() => null) : null;
      console.log('Bash shell history button click safe diagnostic', JSON.stringify({
        errorType: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        viewHistoryButtonVisible: await commandHistoryButton.isVisible().catch(() => false),
        viewHistoryButtonEnabled: await commandHistoryButton.isEnabled().catch(() => false),
        hit,
      }));
      await page.screenshot({ path: '/tmp/atermius-shell-history-debug.png' })
        .catch(() => {});
      throw error;
    }
    console.log('Bash shell history view button activated', JSON.stringify({ activated: true }));
    const historyDialogClose = page.getByRole('button', {
      name: 'Close', exact: true,
    }).last();
    try {
      await historyDialogClose.waitFor({ state: 'visible', timeout: 10000 });
    } catch (error) {
      console.log('Bash shell history dialog open safe diagnostic', JSON.stringify({
        errorType: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        dialogCount: await page.getByRole('dialog').count().catch(() => 0),
        closeButtonCount: await page.getByRole('button', {
          name: 'Close', exact: true,
        }).count().catch(() => 0),
        historyTitleCount: await page.getByText(
          'Command history', { exact: true },
        ).count().catch(() => 0),
      }));
      await page.screenshot({ path: '/tmp/atermius-shell-history-debug.png' })
        .catch(() => {});
      throw error;
    }
    const historyCommandEntry = page.getByRole('group', {
      name: historyCommand, exact: true,
    });
    const historyExitEntry = page.getByRole('group', {
      name: /^Exit 0 ·/,
    }).first();
    const historyEmptyNotice = page.getByRole('group', {
      name: /No command events received yet/,
    });
    console.log('Bash shell history dialog safe evidence', JSON.stringify({
      commandGroupCount: await historyCommandEntry.count().catch(() => 0),
      emptyNoticeGroupCount: await historyEmptyNotice.count().catch(() => 0),
      exitStatusGroupCount: await page.getByRole('group', { name: /^Exit -?\d+ ·/ })
        .count().catch(() => 0),
      titleHeadingCount: await page.getByRole('heading', {
        name: 'Command history', exact: true,
      }).count().catch(() => 0),
    }));
    try {
      await historyCommandEntry.waitFor({ state: 'visible', timeout: 15000 });
      await historyExitEntry.waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      await page.screenshot({ path: '/tmp/atermius-shell-history-debug.png' })
        .catch(() => {});
      console.log('Bash shell history entry safe diagnostic', JSON.stringify({
        errorType: error?.name === 'TimeoutError' ? 'TimeoutError' : 'Error',
        commandGroupCount: await historyCommandEntry.count().catch(() => 0),
        emptyNoticeGroupCount: await historyEmptyNotice.count().catch(() => 0),
        closeButtonCount: await page.getByRole('button', {
          name: 'Close', exact: true,
        }).count().catch(() => 0),
        outputFramesAfterSafeCommand:
          firstRelaySocket.receivedFrames.length - historyOutputFrameBeforeCommand,
      }));
      throw error;
    }
    assertThat(await historyCommandEntry.count() === 1 &&
      await page.getByRole('group', { name: /^Exit -?\d+ ·/ }).count() === 1,
    'Bash command history did not show exactly one command with its exit status');
    console.log('Bash shell history command safe evidence', JSON.stringify({
      commandDisplayed: true,
      exitStatusDisplayed: true,
      exitStatus: 0,
      noRemoteFileCreated: true,
    }));

    safeRunStage = 'Bash shell history explicitly opts into encrypted Vault sync';
    secretSyncPrivacy.additionalMarkers.push(historyCommand, historyMarker);
    const historyVaultSyncSwitchByRole = page.getByRole('switch', {
      name: /Sync command history to Vault/,
    });
    const shellHistorySwitchSemantics = page.locator(
      'flt-semantics[aria-label*="Sync command history to Vault"]',
    );
    const historyVaultSyncSwitch =
      await historyVaultSyncSwitchByRole.count().catch(() => 0) > 0
        ? historyVaultSyncSwitchByRole
        : shellHistorySwitchSemantics.first();
    console.log('Bash shell history Vault switch safe evidence', JSON.stringify({
      roleSwitchCount: await historyVaultSyncSwitchByRole.count().catch(() => 0),
      semanticsCount: await shellHistorySwitchSemantics.count().catch(() => 0),
      semantics: await shellHistorySwitchSemantics.evaluateAll((elements) =>
        elements.slice(0, 4).map((element) => ({
          role: element.getAttribute('role'),
          ariaChecked: element.getAttribute('aria-checked'),
          disabled: element.getAttribute('aria-disabled') === 'true',
          labelLength: (element.getAttribute('aria-label') || '').length,
        })),
      ).catch(() => []),
    }));
    safeRunStage = 'Bash shell history waits for the Vault sync switch';
    await historyVaultSyncSwitch.waitFor({ state: 'visible', timeout: 10000 });
    assertThat(await historyVaultSyncSwitch.getAttribute('aria-checked') === 'false',
      'Bash shell history Vault sync was not off by default');
    safeRunStage = 'Bash shell history clicks the Vault sync switch';
    await historyVaultSyncSwitch.click();
    safeRunStage = 'Bash shell history waits for opt-in confirmation';
    await waitText(page, 'Sync command history to this Vault?');
    safeRunStage = 'Bash shell history confirms encrypted Vault sync';
    await click(page, 'Enable Vault sync');
    safeRunStage = 'Bash shell history waits for enabled switch state';
    await waitForLocatorAttribute(historyVaultSyncSwitch, 'aria-checked', 'true');
    await click(page, 'Close');
    await syncNow(page, 'profile A encrypted shell history backfill');

    safeRunStage = 'profile B keeps upload disabled and decrypts synchronized shell history';
    const secondHistoryOptIn = secondPage.getByRole('button', {
      name: 'Enable Bash command history', exact: true,
    });
    await secondHistoryOptIn.waitFor({ state: 'visible', timeout: 10000 });
    await secondHistoryOptIn.click();
    await waitText(secondPage, 'Enable Bash integration');
    const secondHistorySyncSwitchByRole = secondPage.getByRole('switch', {
      name: /Sync command history to Vault/,
    });
    const secondHistorySyncSwitchSemantics = secondPage.locator(
      'flt-semantics[aria-label*="Sync command history to Vault"]',
    );
    const secondHistorySyncSwitch =
      await secondHistorySyncSwitchByRole.count().catch(() => 0) > 0
        ? secondHistorySyncSwitchByRole
        : secondHistorySyncSwitchSemantics.first();
    await secondHistorySyncSwitch.waitFor({ state: 'visible', timeout: 10000 });
    assertThat(await secondHistorySyncSwitch.getAttribute('aria-checked') === 'false',
      'Profile B shell history upload preference was not off by default');
    await click(secondPage, 'Close');
    await syncNow(secondPage, 'profile B receives encrypted shell history while upload is disabled');
    await secondPage.getByRole('button', {
      name: 'Enable Bash command history', exact: true,
    }).click();
    await waitText(secondPage, 'Enable Bash integration');
    assertThat(await secondHistorySyncSwitch.getAttribute('aria-checked') === 'false',
      'Profile B upload preference changed while receiving Vault history');
    const synchronizedHistoryCommand = secondPage.getByRole('group', {
      name: historyCommand, exact: true,
    });
    const synchronizedHistoryExit = secondPage.getByRole('group', {
      name: /^Exit 0 ·/,
    }).first();
    await synchronizedHistoryCommand.waitFor({ state: 'visible', timeout: 15000 });
    await synchronizedHistoryExit.waitFor({ state: 'visible', timeout: 15000 });
    const historyPrivacyEvidence = secretSyncPrivacy.checks.filter((check) =>
      check.kind === 'push' || check.kind === 'changes');
    assertThat(historyPrivacyEvidence.length > 0 &&
      historyPrivacyEvidence.every((check) => check.markerAbsent),
    'Vault sync request or response exposed the shell command plaintext');
    const historyServerStorageEvidence = fileMarkerAbsenceEvidence([
      path.join(dataDir, 'atermius.db'),
      path.join(dataDir, 'atermius.db-wal'),
      path.join(dataDir, 'atermius.db-shm'),
    ], historyCommand);
    assertThat(historyServerStorageEvidence.scannedFiles > 0 &&
      historyServerStorageEvidence.plaintextMarkerAbsent,
    'server SQLite storage or sidecars contain shell command plaintext');
    console.log('Bash shell history Vault sync safe evidence', JSON.stringify({
      profileAExplicitOptIn: true,
      profileBUploadPreferenceRemainedOff: true,
      profileBCommandDecrypted: true,
      profileBExitStatusVisible: true,
      encryptedSyncRequestResponseChecks: historyPrivacyEvidence.length,
      commandPlaintextAbsentFromSyncBodies: true,
      commandPlaintextAbsentFromServerStorage: true,
    }));

    if (shellCompletionOnly) {
      safeRunStage = 'profile B verifies the synchronized history before local capture setup';
      assertThat(await synchronizedHistoryCommand.count() === 1,
        'profile B did not begin with exactly one synchronized history event');
      const profileBHistoryBootstrapBaseline = secondDeviceRelaySocket.sentFrames.length;
      safeRunStage = 'profile B copies Bash history setup without sending it';
      await click(secondPage, 'Enable and copy');
      await waitText(secondPage, 'Copied. Paste this command into the terminal:');
      const profileBHistoryBootstrap = await readClipboard(secondPage).catch(() => null);
      assertThat(typeof profileBHistoryBootstrap === 'string' &&
        profileBHistoryBootstrap.length > 500 &&
        profileBHistoryBootstrap.startsWith(
          'if [[ $- == *i* && -t 0 && -t 1 ]]',
        ) && profileBHistoryBootstrap.includes('atermius_off'),
      'profile B Bash history setup clipboard did not contain the guarded hook');
      assertThat(secondDeviceRelaySocket.sentFrames.length ===
        profileBHistoryBootstrapBaseline,
      'copying profile B Bash history setup sent terminal input');
      safeRunStage = 'profile B explicitly installs local Bash history capture';
      await click(secondPage, 'Close');
      const profileBPasteBaseline = secondDeviceRelaySocket.sentFrames.length;
      await pasteClipboardToActiveTerminal(secondPage, user, targetAddress, {
        activeHostName: hostName,
      });
      const profileBPasteDeadline = Date.now() + 10000;
      while (Date.now() < profileBPasteDeadline &&
          secondDeviceRelaySocket.sentFrames.length <= profileBPasteBaseline) {
        await secondPage.waitForTimeout(100);
      }
      assertThat(secondDeviceRelaySocket.sentFrames.length > profileBPasteBaseline,
        'explicit profile B history setup paste did not reach its terminal');
      const profileBSetupOutputBaseline = secondDeviceRelaySocket.receivedFrames.length;
      await secondPage.keyboard.press('Enter');
      assertThat(await waitForRelayOutputFrame(secondPage, secondDeviceRelaySocket,
        profileBSetupOutputBaseline, 15000),
      'profile B history setup did not return terminal output');
      const profileBViewHistoryButton = secondPage.getByRole('button', {
        name: 'View command history', exact: true,
      });
      await profileBViewHistoryButton.waitFor({ state: 'visible', timeout: 10000 });
      await profileBViewHistoryButton.click();
      const profileBHistoryEntry = secondPage.getByRole('group', {
        name: historyCommand, exact: true,
      });
      await profileBHistoryEntry.waitFor({ state: 'visible', timeout: 10000 });
      assertThat(await profileBHistoryEntry.count() === 1,
        'profile B history changed before the suggestion was selected');
      const profileBHistoryEntryCountBeforeSuggestions =
        await profileBHistoryEntry.count();
      const profileBExitCountBeforeSuggestions = await secondPage.getByRole('group', {
        name: /^Exit -?\d+ ·/,
      }).count();
      const profileBSuccessfulExitCountBeforeSuggestions =
        await secondPage.getByRole('group', { name: /^Exit 0 ·/ }).count();
      const profileBHistorySyncSwitch = secondPage.getByRole('switch', {
        name: /Sync command history to Vault/,
      });
      assertThat(await profileBHistorySyncSwitch.getAttribute('aria-checked') === 'false',
        'profile B history upload preference was not off before suggestion use');
      await click(secondPage, 'Close');

      safeRunStage = 'profile A stops local history capture and removes the remote hook';
      await click(page, 'View command history');
      await click(page, 'Stop local capture');
      await click(page, 'Close');
      await sendCommandToActiveTerminal(page, user, targetAddress, 'atermius_off', {
        activeHostName: hostName,
      });
      await waitForRelaySocketQuiet(page, firstRelaySocket, 500, 8000);

      const syncLedgerBeforeSuggestion = readSyncLedgerSummary(
        path.join(dataDir, 'atermius.db'),
      );
      assertThat(syncLedgerBeforeSuggestion.available,
        'server sync ledger snapshot was unavailable before suggestions');
      const profileBPushCount = () => secondApiRequests.filter((request) =>
        request.method === 'POST' && request.path.endsWith('/sync/push')).length;
      const profileBPushBaseline = profileBPushCount();

      safeRunStage = 'profile B selects a local dictionary command without executing it';
      const dictionaryRelayTicketBaseline = relayTicketChecksForPage(secondPage).length;
      const dictionaryRelaySocketBaseline = relaySocketsForPage(secondPage).length;
      const dictionarySentFramesBeforeSelection =
        secondDeviceRelaySocket.sentFrames.length;
      const dictionaryOutputFramesBeforeSelection =
        secondDeviceRelaySocket.receivedFrames.length;
      const dictionarySshBeforeSelection = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd.log'),
      );
      await secondPage.getByRole('button', {
        name: 'Command suggestions', exact: true,
      }).click();
      const dictionaryQuery = secondPage.getByRole('textbox', {
        name: 'Filter commands', exact: true,
      });
      await dictionaryQuery.fill('true');
      const trueSuggestion = secondPage.getByRole('button', {
        name: 'true', exact: true,
      });
      await trueSuggestion.waitFor({ state: 'visible', timeout: 10000 });
      await trueSuggestion.click();
      await waitForRelaySocketQuiet(secondPage, secondDeviceRelaySocket, 500, 8000);
      // Relay WebSocket frames carry the opaque SSH byte stream, so the test
      // records only a safe sent-frame count, never raw frame contents.
      const dictionarySentFrameDeltaAfterSelection =
        secondDeviceRelaySocket.sentFrames.length -
        dictionarySentFramesBeforeSelection;
      const dictionaryRelayOutputFrameDeltaBeforeEnter =
        secondDeviceRelaySocket.receivedFrames.length -
        dictionaryOutputFramesBeforeSelection;
      const dictionarySshAfterSelection = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd.log'),
      );
      const dictionarySshDelta = sshdDiagnosticDelta(
        dictionarySshBeforeSelection,
        dictionarySshAfterSelection,
      );
      console.log('local dictionary selection safe evidence', JSON.stringify({
        relaySentFrameDelta: dictionarySentFrameDeltaAfterSelection,
        sshSessionOpenDelta: dictionarySshDelta.sessionOpenRequests,
        shellSessionStartDelta: dictionarySshDelta.sessionStarts,
        commandSessionStartDelta: dictionarySshDelta.commandSessionStarts,
        relayTicketDelta: relayTicketChecksForPage(secondPage).length -
          dictionaryRelayTicketBaseline,
        relaySocketDelta: relaySocketsForPage(secondPage).length -
          dictionaryRelaySocketBaseline,
        outputFrameDelta: dictionaryRelayOutputFrameDeltaBeforeEnter,
      }));
      assertThat(dictionarySentFrameDeltaAfterSelection > 0 &&
        dictionarySshDelta.sessionOpenRequests === 0 &&
        dictionarySshDelta.sessionStarts === 0 &&
        dictionarySshDelta.commandSessionStarts === 0 &&
        relayTicketChecksForPage(secondPage).length === dictionaryRelayTicketBaseline &&
        relaySocketsForPage(secondPage).length === dictionaryRelaySocketBaseline,
      'selecting the local dictionary command executed or reconnected the terminal');
      await profileBViewHistoryButton.click();
      const dictionaryHistoryHeading = secondPage.getByRole('heading', {
        name: 'Command history', exact: true,
      });
      await dictionaryHistoryHeading.waitFor({ state: 'visible', timeout: 10000 });
      const trueHistoryEntry = secondPage.getByRole('group', {
        name: 'true', exact: true,
      });
      const trueHistoryCountBeforeEnter = await trueHistoryEntry.count();
      assertThat(await profileBHistoryEntry.count() ===
          profileBHistoryEntryCountBeforeSuggestions &&
        await secondPage.getByRole('group', { name: /^Exit -?\d+ ·/ }).count() ===
          profileBExitCountBeforeSuggestions &&
        await secondPage.getByRole('group', { name: /^Exit 0 ·/ }).count() ===
          profileBSuccessfulExitCountBeforeSuggestions &&
        await trueHistoryEntry.count() === trueHistoryCountBeforeEnter,
      'selecting the local dictionary command committed a shell history event');
      const dictionaryHistoryDeltaBeforeEnter = await trueHistoryEntry.count() -
        trueHistoryCountBeforeEnter;
      const dictionarySuccessfulExitDeltaBeforeEnter =
        await secondPage.getByRole('group', { name: /^Exit 0 ·/ }).count() -
          profileBSuccessfulExitCountBeforeSuggestions;
      await click(secondPage, 'Close');

      safeRunStage = 'profile B executes the dictionary command only after Enter';
      const dictionarySentFramesBeforeEnter =
        secondDeviceRelaySocket.sentFrames.length;
      const dictionaryOutputFramesBeforeEnter =
        secondDeviceRelaySocket.receivedFrames.length;
      await focusActiveTerminalForInput(secondPage, user, targetAddress, {
        activeHostName: hostName,
      });
      await secondPage.keyboard.press('Enter');
      assertThat(await waitForRelayOutputFrame(secondPage, secondDeviceRelaySocket,
        dictionaryOutputFramesBeforeEnter, 15000),
      'explicit Enter after selecting the local dictionary command produced no output');
      await waitForRelaySocketQuiet(secondPage, secondDeviceRelaySocket, 500, 8000);
      await profileBViewHistoryButton.click();
      await dictionaryHistoryHeading.waitFor({ state: 'visible', timeout: 10000 });
      const dictionarySentFrameDeltaAfterEnter =
        secondDeviceRelaySocket.sentFrames.length -
        dictionarySentFramesBeforeEnter;
      const trueHistoryCountAfterEnter = await trueHistoryEntry.count();
      const profileBExitCountAfterDictionaryEnter = await secondPage.getByRole('group', {
        name: /^Exit -?\d+ ·/,
      }).count();
      const profileBSuccessfulExitCountAfterDictionaryEnter =
        await secondPage.getByRole('group', { name: /^Exit 0 ·/ }).count();
      assertThat(dictionarySentFrameDeltaAfterEnter > 0 &&
        trueHistoryCountAfterEnter === trueHistoryCountBeforeEnter + 1 &&
        await profileBHistoryEntry.count() ===
          profileBHistoryEntryCountBeforeSuggestions &&
        profileBExitCountAfterDictionaryEnter ===
          profileBExitCountBeforeSuggestions + 1 &&
        profileBSuccessfulExitCountAfterDictionaryEnter ===
          profileBSuccessfulExitCountBeforeSuggestions + 1 &&
        relayTicketChecksForPage(secondPage).length === dictionaryRelayTicketBaseline &&
        relaySocketsForPage(secondPage).length === dictionaryRelaySocketBaseline,
      'explicit Enter did not execute exactly one local dictionary suggestion');
      console.log('Profile B local dictionary suggestion safe evidence', JSON.stringify({
        dictionaryCandidateAvailable: true,
        selectionSentInputTextWithoutSubmitting: true,
        relayOutputFramesBeforeEnter: dictionaryRelayOutputFrameDeltaBeforeEnter,
        sessionOpenRequestsBeforeEnter: dictionarySshDelta.sessionOpenRequests,
        shellSessionStartsBeforeEnter: dictionarySshDelta.sessionStarts,
        commandSessionStartsBeforeEnter: dictionarySshDelta.commandSessionStarts,
        commandHistoryDeltaBeforeEnter: dictionaryHistoryDeltaBeforeEnter,
        explicitEnterRelaySentFrameDelta: dictionarySentFrameDeltaAfterEnter,
        historyEventDeltaAfterEnter: trueHistoryCountAfterEnter -
          trueHistoryCountBeforeEnter,
        successfulExitDeltaAfterEnter: profileBSuccessfulExitCountAfterDictionaryEnter -
          profileBSuccessfulExitCountBeforeSuggestions,
        successfulExitDeltaBeforeEnter: dictionarySuccessfulExitDeltaBeforeEnter,
        relayTicketDelta: relayTicketChecksForPage(secondPage).length -
          dictionaryRelayTicketBaseline,
        relaySocketDelta: relaySocketsForPage(secondPage).length -
          dictionaryRelaySocketBaseline,
      }));
      await click(secondPage, 'Close');

      safeRunStage = 'profile B filters synchronized Host history suggestions';
      await secondPage.getByRole('button', {
        name: 'Command suggestions', exact: true,
      }).click();
      const suggestionQuery = secondPage.getByRole('textbox', {
        name: 'Filter commands', exact: true,
      });
      await suggestionQuery.fill(historyMarker);
      const synchronizedSuggestion = secondPage.getByRole('button', {
        name: historyCommand, exact: true,
      });
      await synchronizedSuggestion.waitFor({ state: 'visible', timeout: 10000 });
      const profileBRelaySentBeforeSelection = secondDeviceRelaySocket.sentFrames.length;
      await synchronizedSuggestion.click();
      await waitForRelaySocketQuiet(secondPage, secondDeviceRelaySocket, 500, 8000);
      assertThat(secondDeviceRelaySocket.sentFrames.length >
        profileBRelaySentBeforeSelection,
      'selecting the synchronized history suggestion did not type into the terminal');
      await profileBViewHistoryButton.click();
      await profileBHistoryEntry.waitFor({ state: 'visible', timeout: 10000 });
      const historyCommandCountBeforeEnter = await profileBHistoryEntry.count();
      const historyExitCountBeforeEnter = await secondPage.getByRole('group', {
        name: /^Exit 0 ·/,
      }).count();
      assertThat(historyCommandCountBeforeEnter === 1 &&
        historyExitCountBeforeEnter === profileBExitCountAfterDictionaryEnter,
        'selecting a profile B suggestion executed the command before Enter');
      assertThat(await secondApiRequests.filter((request) =>
        request.method === 'POST' && request.path.endsWith('/sync/push')).length ===
          profileBPushBaseline,
      'selecting a profile B suggestion caused a sync push');
      await click(secondPage, 'Close');

      safeRunStage = 'profile B executes the selected history suggestion only after Enter';
      const outputFramesBeforeExplicitEnter =
        secondDeviceRelaySocket.receivedFrames.length;
      const sentFramesBeforeExplicitEnter = secondDeviceRelaySocket.sentFrames.length;
      safeRunStage = 'profile B focuses the SSH terminal before explicit Enter';
      await focusActiveTerminalForInput(secondPage, user, targetAddress, {
        activeHostName: hostName,
      });
      safeRunStage = 'profile B waits for SSH output after explicit Enter';
      await secondPage.keyboard.press('Enter');
      assertThat(await waitForRelayOutputFrame(secondPage, secondDeviceRelaySocket,
        outputFramesBeforeExplicitEnter, 15000),
      'explicit Enter after a history suggestion produced no SSH output');
      safeRunStage = 'profile B waits for command completion after explicit Enter';
      await waitForRelaySocketQuiet(secondPage, secondDeviceRelaySocket, 500, 8000);
      safeRunStage = 'profile B opens history after explicit Enter';
      await profileBViewHistoryButton.click();
      const profileBHistoryHeading = secondPage.getByRole('heading', {
        name: 'Command history', exact: true,
      });
      await profileBHistoryHeading.waitFor({ state: 'visible', timeout: 10000 });
      await profileBHistoryEntry.first().waitFor({ state: 'visible', timeout: 10000 });
      safeRunStage = 'profile B counts history state immediately after explicit Enter';
      const immediateCommandCount = await profileBHistoryEntry.count();
      const immediateExitCount = await secondPage.getByRole('group', {
        name: /^Exit 0 ·/,
      }).count();
      console.log('profile B explicit Enter immediate safe evidence', JSON.stringify({
        preEnterCommandGroupCount: historyCommandCountBeforeEnter,
        preEnterSuccessfulExitGroupCount: historyExitCountBeforeEnter,
        completedCommandGroupCount: immediateCommandCount,
        successfulExitGroupCount: immediateExitCount,
        historyHeadingVisible: await profileBHistoryHeading.isVisible(),
        relayInputFrameDelta: secondDeviceRelaySocket.sentFrames.length -
          sentFramesBeforeExplicitEnter,
        relayOutputFrameDelta: secondDeviceRelaySocket.receivedFrames.length -
          outputFramesBeforeExplicitEnter,
      }));
      assertThat(immediateCommandCount >= historyCommandCountBeforeEnter &&
        immediateCommandCount <= historyCommandCountBeforeEnter + 1 &&
        immediateExitCount >= historyExitCountBeforeEnter &&
        immediateExitCount <= historyExitCountBeforeEnter + 1,
      'profile B history changed by more than one completion after explicit Enter');
      safeRunStage = 'profile B waits for one new command-completion event';
      let completionGroupAppeared = false;
      const completionWaitStartedAt = Date.now();
      try {
        await profileBHistoryEntry.nth(1).waitFor({ state: 'visible', timeout: 10000 });
        completionGroupAppeared = true;
      } catch (_) {
        console.log('profile B completion wait timeout safe evidence', JSON.stringify({
          completionWaitMs: Date.now() - completionWaitStartedAt,
          preEnterCommandGroupCount: historyCommandCountBeforeEnter,
          preEnterSuccessfulExitGroupCount: historyExitCountBeforeEnter,
          completedCommandGroupCount: await profileBHistoryEntry.count().catch(() => null),
          successfulExitGroupCount: await secondPage.getByRole('group', {
            name: /^Exit 0 ·/,
          }).count().catch(() => null),
          historyHeadingVisible: await profileBHistoryHeading.isVisible().catch(() => false),
          emptyHistoryMessageVisible: await secondPage.getByText(
            'No command events received yet. Paste the copied setup command into the terminal and press Enter.',
            { exact: true },
          ).isVisible().catch(() => false),
          relayInputFrameDelta: secondDeviceRelaySocket.sentFrames.length -
            sentFramesBeforeExplicitEnter,
          relayOutputFrameDelta: secondDeviceRelaySocket.receivedFrames.length -
            outputFramesBeforeExplicitEnter,
        }));
      }
      assertThat(completionGroupAppeared,
        'profile B did not receive a second command-completion group after explicit Enter');
      safeRunStage = 'profile B verifies exactly one completion from explicit Enter';
      const exitStatusCountAfterEnter = await secondPage.getByRole('group', {
        name: /^Exit 0 ·/,
      }).count();
      const historyCommandCountAfterEnter = await profileBHistoryEntry.count();
      const enterFrameDelta = secondDeviceRelaySocket.sentFrames.length -
        sentFramesBeforeExplicitEnter;
      const outputFrameDeltaAfterEnter = secondDeviceRelaySocket.receivedFrames.length -
        outputFramesBeforeExplicitEnter;
      console.log('profile B explicit Enter safe evidence', JSON.stringify({
        preEnterCommandGroupCount: historyCommandCountBeforeEnter,
        preEnterSuccessfulExitGroupCount: historyExitCountBeforeEnter,
        completedCommandGroupCount: historyCommandCountAfterEnter,
        successfulExitGroupCount: exitStatusCountAfterEnter,
        relayInputFrameDelta: enterFrameDelta,
        relayOutputFrameDelta: outputFrameDeltaAfterEnter,
      }));
      assertThat(historyCommandCountAfterEnter === historyCommandCountBeforeEnter + 1 &&
        exitStatusCountAfterEnter === historyExitCountBeforeEnter + 1 &&
        enterFrameDelta > 0 && outputFrameDeltaAfterEnter > 0,
      'explicit Enter did not create exactly one completed history event');
      assertThat(await profileBHistorySyncSwitch.getAttribute('aria-checked') === 'false',
        'profile B history upload preference changed during suggestion use');
      await click(secondPage, 'Close');
      await sendCommandToActiveTerminal(secondPage, user, targetAddress,
        'atermius_off', { activeHostName: hostName });
      await waitForRelaySocketQuiet(secondPage, secondDeviceRelaySocket, 500, 8000);
      await secondPage.waitForTimeout(1000);

      const syncLedgerAfterSuggestion = readSyncLedgerSummary(
        path.join(dataDir, 'atermius.db'),
      );
      const profileBPushAfterSuggestion = profileBPushCount();
      assertThat(syncLedgerAfterSuggestion.available &&
        JSON.stringify(syncLedgerAfterSuggestion) ===
          JSON.stringify(syncLedgerBeforeSuggestion) &&
        profileBPushAfterSuggestion === profileBPushBaseline,
      'profile B suggestion use added a sync push, receipt, version, head, event, or committed sequence');
      const historyServerStorageEvidence = [
        ...[path.join(dataDir, 'atermius.db'),
          path.join(dataDir, 'atermius.db-wal'),
          path.join(dataDir, 'atermius.db-shm')],
      ].map((filePath) => fileMarkerAbsenceEvidence([filePath], historyMarker));
      const historyServerLogEvidence = fileMarkerAbsenceEvidence(
        [serverLogPath], historyMarker,
      );
      const historyPrivacyEvidence = secretSyncPrivacy.checks.filter((check) =>
        check.kind === 'push' || check.kind === 'changes');
      assertThat(historyPrivacyEvidence.length > 0 &&
        historyPrivacyEvidence.every((check) => check.markerAbsent) &&
        historyServerStorageEvidence.some((evidence) => evidence.scannedFiles > 0) &&
        historyServerStorageEvidence.every((evidence) =>
          evidence.plaintextMarkerAbsent) &&
        historyServerLogEvidence.scannedFiles > 0 &&
        historyServerLogEvidence.plaintextMarkerAbsent,
      'shell history marker appeared in sync traffic, server storage, or server logs');
      console.log('WEB-SHELL-COMPLETION-01 passed', JSON.stringify({
        profileBUploadedHistoryPreferenceRemainedOff: true,
        synchronizedHistorySuggestionAvailable: true,
        selectingSuggestionDidNotCompleteCommand: true,
        explicitEnterProducedExactlyOneCompletedHistoryEvent: true,
        sshOutputFrameDeltaAfterEnter:
          secondDeviceRelaySocket.receivedFrames.length - outputFramesBeforeExplicitEnter,
        profileBPushDelta: profileBPushAfterSuggestion - profileBPushBaseline,
        syncLedgerUnchanged: true,
        commandPlaintextAbsentFromSyncStorageAndLog: true,
        fixtureCleanup: 'handled by isolated runner finally block',
      }));
      secretSyncPrivacy.active = false;
      return;
    }

    await click(secondPage, 'Close');

    safeRunStage = 'Bash shell history reopens the command history dialog';
    await click(page, 'View command history');
    await page.getByRole('group', {
      name: historyCommand, exact: true,
    }).waitFor({ state: 'visible', timeout: 10000 });
    safeRunStage = 'Bash shell history stops local capture';
    await click(page, 'Stop local capture');
    safeRunStage = 'Bash shell history closes after local capture stops';
    await click(page, 'Close');
    const ignoredHistoryCommand =
      `printf '%s\\n' 'WEB_RELAY_HISTORY_AFTER_STOP_${RUN_ID.replaceAll('-', '').toUpperCase()}'`;
    const ignoredHistoryOutputBaseline = firstRelaySocket.receivedFrames.length;
    safeRunStage = 'Bash shell history ignores the next command after local stop';
    await sendCommandToActiveTerminal(page, user, targetAddress,
      ignoredHistoryCommand, { activeHostName: hostName });
    assertThat(await waitForRelayOutputFrame(
      page, firstRelaySocket, ignoredHistoryOutputBaseline, 15000),
    'post-stop safe Bash command produced no SSH terminal output');
    assertThat(await waitForRelaySocketQuiet(page, firstRelaySocket, 500, 8000),
      'post-stop Bash command did not finish before history was inspected');
    const stoppedHistoryButton = page.getByRole('button', {
      name: 'Enable Bash command history', exact: true,
    });
    await stoppedHistoryButton.waitFor({ state: 'visible', timeout: 10000 });
    await stoppedHistoryButton.click();
    const stoppedHistoryDialogClose = page.getByRole('button', {
      name: 'Close', exact: true,
    }).last();
    await stoppedHistoryDialogClose.waitFor({ state: 'visible', timeout: 10000 });
    const retainedHistoryCommand = page.getByRole('group', {
      name: historyCommand, exact: true,
    });
    await retainedHistoryCommand.waitFor({ state: 'visible', timeout: 10000 });
    assertThat(await retainedHistoryCommand.count() === 1 &&
      await page.getByRole('group', {
        name: ignoredHistoryCommand, exact: true,
      }).count() === 0 &&
      await page.getByRole('group', { name: /^Exit -?\d+ ·/ }).count() === 1,
    'stopping local Bash history capture displayed a later remote command');
    await click(page, 'Close');

    safeRunStage = 'Bash shell history remote in-memory hook cleanup';
    await sendCommandToActiveTerminal(page, user, targetAddress, 'atermius_off', {
      activeHostName: hostName,
    });
    await waitForRelaySocketQuiet(page, firstRelaySocket, 500, 8000);
    console.log('WEB-RELAY-SHELL-HISTORY-01 passed: opt-in setup was copied without auto-send, explicitly pasted and submitted, Profile A explicitly synced the encrypted command, Profile B remained opted out of uploads while decrypting it, HTTP/SQLite contained no command plaintext, Stop local capture hid later events, and the remote in-memory hook was removed before fixture teardown.');

    safeRunStage = 'terminal scrollback search and SSH input isolation';
    const searchMarkerValue = `WEB_RELAY_SEARCH_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const searchMarkerPath = path.join(remoteRoot, 'terminal-search-marker');
    const searchMarkerRemotePath = '/tmp/remote/terminal-search-marker';
    const searchMarkerCommand = `printf '%s\\n' '${searchMarkerValue}' > '${searchMarkerRemotePath}'; printf '%s\\n' '${searchMarkerValue}'`;
    await sendCommandToActiveTerminal(page, user, targetAddress, searchMarkerCommand, {
      activeHostName: hostName,
    });
    assertThat(await waitForRemoteMarker(searchMarkerPath, searchMarkerValue),
      'the isolated Relay shell did not create the terminal-search marker');
    assertThat(await waitForRelaySocketQuiet(page, firstRelaySocket),
      'the isolated Relay socket did not become quiet after the marker output');
    let searchTextObservedInRelay = false;
    const searchTextProbe = Buffer.from(searchMarkerValue, 'utf8');
    const inspectSearchRelayFrame = ({ payload }) => {
      try {
        const frameBytes = Buffer.isBuffer(payload)
          ? payload
          : Buffer.from(payload);
        if (frameBytes.includes(searchTextProbe)) {
          searchTextObservedInRelay = true;
        }
      } catch (_) {}
    };
    firstRelaySocket.websocketRef.on('framesent', inspectSearchRelayFrame);
    await click(page, 'Search terminal scrollback');
    assertThat(await waitForRelaySocketQuiet(page, firstRelaySocket),
      'the isolated Relay socket did not become quiet after opening terminal search');
    const searchRelaySentBaseline = firstRelaySocket.sentFrames.length;
    await fill(page, 'Search terminal scrollback', searchMarkerValue);
    await page.waitForTimeout(150);
    const searchStatusLabels = await page.evaluate(() => {
      const isVisible = (element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 &&
          rect.bottom > 0 && rect.right > 0 &&
          rect.top < window.innerHeight && rect.left < window.innerWidth &&
          style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity) !== 0;
      };
      return [...document.querySelectorAll('flt-semantics')]
        .filter(isVisible)
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .flatMap((label) => label.match(/\d+ of \d+ matches|\d+ matches/gi) || []);
    }).catch(() => []);
    console.log('Terminal search status safe evidence', JSON.stringify({
      statusLabels: searchStatusLabels,
    }));
    // Scrollback search counts matching terminal lines. The marker appears in
    // the echoed command line and the command's output line.
    safeRunStage = 'terminal search initial match count';
    await waitForVisibleSemanticsText(page, '1 of 2 matches');
    safeRunStage = 'terminal search next match navigation';
    await clickUntilVisibleSemanticsText(page, 'Next match', '2 of 2 matches');
    safeRunStage = 'terminal search previous match navigation';
    await clickUntilVisibleSemanticsText(page, 'Previous match', '1 of 2 matches');
    assertThat(await waitForRelaySocketQuiet(page, firstRelaySocket),
      'the isolated Relay socket did not become quiet after local terminal search');
    firstRelaySocket.websocketRef.off('framesent', inspectSearchRelayFrame);
    const searchSentFramesAfterQuery = firstRelaySocket.sentFrames.length;
    console.log('Terminal search Relay isolation safe evidence', JSON.stringify({
      sentFrameBaseline: searchRelaySentBaseline,
      sentFrameCountAfterSearch: searchSentFramesAfterQuery,
      sentFrameDelta: searchSentFramesAfterQuery - searchRelaySentBaseline,
      newFrameSizes: firstRelaySocket.sentFrames
        .slice(searchRelaySentBaseline).map((frame) => frame.bytes),
      searchTextObservedInRelay: searchTextObservedInRelay,
    }));
    assertThat(!searchTextObservedInRelay,
      'terminal scrollback search text appeared in an SSH Relay frame');
    safeRunStage = 'terminal search close';
    await click(page, 'Close terminal search');
    assertThat(!firstRelaySocket.closed,
      'closing terminal search closed the active SSH Relay socket');
    console.log('stage: terminal scrollback search found and navigated the synthetic marker without sending search text to the SSH Relay socket',
      JSON.stringify({
        searchHits: 2,
        searchRelaySentBaseline,
        searchSentFramesAfterQuery,
        searchTextObservedInRelay,
      }));

    safeRunStage = 'structured Bash snippet over the connected Relay target';
    const snippetMarker = `WEB_RELAY_SNIPPET_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const substitutionMarker = `${snippetMarker}_EXPANDED`;
    const substitutionPath = `/tmp/remote/${substitutionMarker}`;
    const invocationFilename = `${snippetMarker}_INVOCATIONS`;
    const invocationPath = path.join(remoteRoot, invocationFilename);
    const remoteInvocationPath = `/tmp/remote/${invocationFilename}`;
    const snippetPayload = `$(touch ${substitutionPath})_${snippetMarker}`;
    const snippetInvocationValue = `${snippetPayload}|${snippetCredentialSecret}`;
    const credentialPreview = '[Credential secret hidden: token]';
    const snippetScript = `printf '%s|%s\\n' "$1" "$2" >> '${remoteInvocationPath}'; printf '%s\\n' "$1"; printf '%s\\n' "$2" >&2`;
    const maskedSnippetCredentialSecret = '*'.repeat(snippetCredentialSecret.length);
    const snippetTitle = `Relay text argv ${RUN_ID.slice(0, 8)}`;
    await click(page, 'Snippets');
    await click(page, 'New snippet');
    await fill(page, 'Title', snippetTitle);
    safeRunStage = 'structured Bash snippet execution mode selection';
    await selectFormOption(page, 'Execution mode', 'Structured Bash command');
    console.log('stage: structured Bash execution mode selected');
    safeRunStage = 'structured Bash snippet Program field';
    await fill(page, 'Program', '/bin/bash');
    safeRunStage = 'structured Bash snippet parameter definitions';
    await fill(page, 'Parameter definitions (JSON array)',
      JSON.stringify([{ name: 'payload', type: 'text' }]));
    safeRunStage = 'structured Bash snippet selects encrypted password Credential';
    await click(page, 'Add Credential secret parameter');
    await fill(page, 'Parameter name', 'token');
    // This isolated fixture has exactly one password Credential (the other
    // synced Credential is an SSH key and is intentionally ineligible), so
    // the prompt's deterministic initial selection is the expected secret.
    // The Flutter widget test covers changing the selection explicitly.
    safeRunStage = 'structured Bash snippet adds the selected Credential parameter';
    await click(page, 'Add parameter');
    safeRunStage = 'structured Bash snippet arguments';
    await fill(page, 'Arguments (JSON array)',
      JSON.stringify([
        { kind: 'literal', value: '-c' },
        { kind: 'literal', value: snippetScript },
        { kind: 'literal', value: 'snippet' },
        { kind: 'parameter', name: 'payload' },
        { kind: 'parameter', name: 'token' },
      ]));
    safeRunStage = 'structured Bash snippet save action';
    snippetRelaySync.active = true;
    snippetRelaySync.titleMarker = snippetTitle;
    snippetRelaySync.secretMarker = snippetCredentialSecret;
    await click(page, 'Save snippet');
    safeRunStage = 'structured Bash snippet saved card review action';
    const structuredSnippetCard = page.getByRole('group', {
      name: `Snippet: ${snippetTitle}`,
      exact: true,
    });
    await structuredSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
    const reviewButtons = structuredSnippetCard.getByRole('button', {
      name: 'Review and run', exact: true,
    });
    try {
      await reviewButtons.last().waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      const evidence = await page.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.visibility !== 'hidden' && style.display !== 'none';
        };
        const controls = [...document.querySelectorAll('input, textarea')]
          .filter(visible).map((element) => ({
            tagName: element.tagName,
            ariaLabelLength: (element.getAttribute('aria-label') || '').length,
            valueLength: typeof element.value === 'string' ? element.value.length : null,
            rows: element instanceof HTMLTextAreaElement ? element.rows : null,
          }));
        const phrases = [...document.querySelectorAll('flt-semantics')]
          .filter(visible).map((element) =>
            `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`.toLowerCase());
        const validationCategories = [
          'json', 'array', 'argument', 'program', 'parameter', 'title',
          'required', 'invalid', 'too long', 'too many', 'credential',
          'expected', 'unsupported', 'format', 'script',
        ].filter((category) => phrases.some((phrase) => phrase.includes(category)));
        return {
          visibleDialogCount: [...document.querySelectorAll('flt-semantics[role="dialog"], [role="dialog"], [role="alertdialog"]')].filter(visible).length,
          visibleControlCount: controls.length,
          controls,
          visibleSaveButtonCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter((element) => visible(element) && /Save snippet/i.test(`${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`)).length,
          visibleReviewButtonCount: [...document.querySelectorAll('flt-semantics[role="button"]')]
            .filter((element) => visible(element) && /Review and run/i.test(`${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`)).length,
          validationCategories,
        };
      }).catch(() => ({ diagnosticUnavailable: true }));
      console.log('Snippet save safe diagnostic', JSON.stringify({
        errorType: error?.name || 'Error',
        ...evidence,
      }));
      throw error;
    }
    await reviewButtons.last().click();
    safeRunStage = 'structured Bash snippet text parameter entry';
    await fill(page, 'payload', snippetPayload);
    safeRunStage = 'structured Bash snippet execution dialog title';
    await waitText(page, 'Bash non-interactive execution');
    safeRunStage = 'structured Bash snippet target confirmation';
    await waitText(page, `Target: ${hostName} · ${targetAddress}:${sshPort}`);
    safeRunStage = 'structured Bash snippet execution preview heading';
    await waitText(page, 'Execution preview');
    safeRunStage = 'structured Bash snippet command confirmation';
    const expectedPreview = [
      '/bin/bash', '-c', snippetScript, 'snippet', snippetPayload,
      credentialPreview,
    ].map(quoteBashPreviewWord).join(' ');
    const previewLabel = page.getByLabel(expectedPreview, { exact: true });
    const previewText = page.getByText(expectedPreview, { exact: true });
    const expectedPreviewTokens = [
      { category: 'program', value: quoteBashPreviewWord('/bin/bash') },
      { category: 'static_flag', value: quoteBashPreviewWord('-c') },
      { category: 'script', value: quoteBashPreviewWord(snippetScript) },
      { category: 'argv0', value: quoteBashPreviewWord('snippet') },
      { category: 'text_parameter', value: quoteBashPreviewWord(snippetPayload) },
      { category: 'credential_placeholder', value: quoteBashPreviewWord(credentialPreview) },
    ];
    try {
      await previewText.waitFor({ state: 'visible', timeout: 15000 });
      const exactTextCount = await previewText.count();
      assertThat(exactTextCount === 1,
        'structured Bash command preview text was not unique');
      console.log('Snippet execution preview exact visible text verified', JSON.stringify({
        stage: safeRunStage,
        expectedTextLength: expectedPreview.length,
        expectedTextSha256: crypto.createHash('sha256')
          .update(expectedPreview).digest('hex'),
        exactVisibleTextCount: exactTextCount,
        exactAriaLabelCount: await previewLabel.count().catch(() => 0),
      }));
    } catch (_) {
      const expectedPreviewSha256 = crypto.createHash('sha256')
        .update(expectedPreview).digest('hex');
      const domEvidence = await page.evaluate(({ expected, tokens }) => {
        const normalize = (value) => value.replace(/\s+/g, ' ').trim();
        const prefixLength = (left, right) => {
          const limit = Math.min(left.length, right.length);
          let index = 0;
          while (index < limit && left[index] === right[index]) index += 1;
          return index;
        };
        const ariaElements = [...document.querySelectorAll('[aria-label]')];
        const semanticsElements = [...document.querySelectorAll('flt-semantics')];
        const labelsAndText = [
          ...ariaElements.map((element) => element.getAttribute('aria-label') || ''),
          ...semanticsElements.map((element) => element.textContent || ''),
        ];
        const errorCategories = {
          requiredValue: false,
          credentialSecretUnsupported: false,
          tooLong: false,
          controlCharacters: false,
          unexpectedParameterValue: false,
          fallback: false,
        };
        for (const value of labelsAndText) {
          const lower = value.toLowerCase();
          errorCategories.requiredValue ||= lower.includes('value required for parameter');
          errorCategories.credentialSecretUnsupported ||= lower.includes(
            'credential secret parameters are not supported for execution yet');
          errorCategories.tooLong ||= lower.includes('too long');
          errorCategories.controlCharacters ||= lower.includes('control characters');
          errorCategories.unexpectedParameterValue ||= lower.includes(
            'unexpected snippet parameter value');
          errorCategories.fallback ||= value === 'Enter required values to preview.';
        }
        return {
          ariaElementCount: ariaElements.length,
          ariaLabelEvidence: ariaElements.map((element) => {
            const label = element.getAttribute('aria-label') || '';
            return {
              tagName: element.tagName,
              role: element.getAttribute('role') || '',
              labelLength: label.length,
              exactExpectedLabel: label === expected,
              containsExpectedLabel: label.includes(expected),
              labelContainedInExpected: expected.includes(label),
            };
          }),
          semanticsElementCount: semanticsElements.length,
          semanticsEvidence: semanticsElements.map((element) => {
            const ariaLabel = element.getAttribute('aria-label') || '';
            const textContent = element.textContent || '';
            const innerText = element.innerText || '';
            const normalizedText = normalize(textContent);
            const candidate = normalizedText.length >= normalize(innerText).length
              ? normalizedText
              : normalize(innerText);
            return {
              tagName: element.tagName,
              role: element.getAttribute('role') || '',
              ariaLabelLength: ariaLabel.length,
              textContentLength: textContent.length,
              innerTextLength: innerText.length,
              textContentExactExpected: textContent === expected,
              textContentNormalizedExactExpected: normalizedText === normalize(expected),
              textContentContainsExpected: textContent.includes(expected),
              candidateLength: candidate.length,
              candidateTextForHash: candidate,
              candidateLongestCommonPrefixLength: prefixLength(expected, candidate),
              tokenContains: Object.fromEntries(tokens.map((token) =>
                [token.category, candidate.includes(token.value)])),
            };
          }),
          errorCategories,
        };
      }, { expected: expectedPreview, tokens: expectedPreviewTokens });
      for (const record of domEvidence.semanticsEvidence) {
        record.candidateSha256 = crypto.createHash('sha256')
          .update(record.candidateTextForHash).digest('hex');
        delete record.candidateTextForHash;
      }
      const confirmButton = page.getByRole('button', {
        name: 'Confirm and run', exact: true,
      });
      console.log('Snippet execution preview label safe diagnostic', JSON.stringify({
        stage: safeRunStage,
        expectedLabelLength: expectedPreview.length,
        expectedLabelSha256: expectedPreviewSha256,
        exactLabelMatchCount: await previewLabel.count().catch(() => 0),
        ...domEvidence,
        confirmButtonCount: await confirmButton.count().catch(() => 0),
        confirmButtonDisabled: await confirmButton.isDisabled().catch(() => null),
      }));
      throw new Error('structured Bash command preview text did not match the expected preview');
    }
    const reviewedBodyText = await page.locator('body').innerText();
    assertThat(!reviewedBodyText.includes(snippetCredentialSecret),
      'Credential secret appeared in the Web execution preview');
    safeRunStage = 'structured Bash snippet confirmed exec';
    await click(page, 'Confirm and run');
    safeRunStage = 'structured Bash snippet exit result';
    const snippetResultEvidence = await waitForSnippetResult(
      page,
      30000,
      redactCurrentSecrets,
    );
    const rawInvocationEvidence = fixtureFileLineEvidence(
      invocationPath,
      snippetInvocationValue,
    );
    const invocationEvidence = {
      exists: rawInvocationEvidence.exists,
      lineCount: rawInvocationEvidence.lineCount,
      exactExpectedValueOnce: rawInvocationEvidence.exactExpectedValueOnce,
      byteLength: rawInvocationEvidence.byteLength,
    };
    const substitutionPathExists = fs.existsSync(path.join(remoteRoot, substitutionMarker));
    console.log('Snippet execution result safe diagnostic', JSON.stringify({
      stage: safeRunStage,
      ...snippetResultEvidence,
      invocationEvidence,
      substitutionPathExists,
    }));
    assertThat(snippetResultEvidence.exitCodes.includes(0),
      'structured Bash snippet did not report exit code zero');
    const exactExitStatus = page.getByText('Exit code: 0', { exact: true });
    const exactExitStatusCount = await exactExitStatus.count();
    assertThat(exactExitStatusCount > 0 &&
      await exactExitStatus.first().isVisible(),
    'structured Bash exit code was not visible as exact text');
    assertThat(snippetResultEvidence.closeButtonCount > 0,
      'structured Bash result dialog did not expose its Close action');
    const firstSnippetResultText = await page.locator('body').innerText();
    assertThat(!firstSnippetResultText.includes(snippetCredentialSecret) &&
      firstSnippetResultText.includes(maskedSnippetCredentialSecret),
    'structured Bash result output exposed the Credential secret instead of masking it');
    safeRunStage = 'structured Bash snippet stdout literal check';
    const expectedOutputBlock =
      `stdout: ${snippetPayload} stderr: ${maskedSnippetCredentialSecret}`;
    const snippetOutputEvidence = await page.evaluate(({ expected, maskedSecret }) => {
      const candidates = [...document.querySelectorAll('flt-semantics')]
        .map((element) => element.textContent || '')
        .filter((text) =>
        text.includes('stdout:') && text.includes(expected))
        .sort((left, right) => left.length - right.length);
      const selected = candidates[0] || '';
      const normalize = (text) => text.replace(/\s+/g, ' ').trim();
      const outputBlock = `stdout: ${expected} stderr: ${maskedSecret}`;
      return {
        stdoutCandidateCount: candidates.length,
        selectedSourceLength: selected.length,
        outputBlockMatches: normalize(selected) === normalize(outputBlock),
        expectedParameterPresent: selected.includes(expected),
        expectedParameterOccurrenceCount: selected.split(expected).length - 1,
        redactedSecretPresent: selected.includes(maskedSecret),
      };
    }, { expected: snippetPayload, maskedSecret: maskedSnippetCredentialSecret });
    console.log('Snippet stdout safe diagnostic', JSON.stringify({
      stage: safeRunStage,
      expectedOutputLength: expectedOutputBlock.length,
      ...snippetOutputEvidence,
      exactExitStatusCount,
    }));
    assertThat(snippetOutputEvidence.outputBlockMatches &&
      snippetOutputEvidence.redactedSecretPresent,
    'structured Bash output did not preserve literal stdout and mask echoed Credential data');
    assertThat(snippetOutputEvidence.expectedParameterOccurrenceCount === 1,
      'structured Bash text parameter did not appear exactly once on stdout');
    safeRunStage = 'structured Bash snippet invocation fixture';
    assertThat(await waitForRemoteMarker(invocationPath, snippetInvocationValue),
      'structured Bash command did not create its remote invocation evidence');
    safeRunStage = 'structured Bash snippet invocation exactness';
    assertThat(invocationEvidence.exactExpectedValueOnce,
      'structured Bash snippet did not append the text and Credential parameters exactly once');
    safeRunStage = 'structured Bash text and Credential shell literal check';
    assertThat(!fs.existsSync(path.join(remoteRoot, substitutionMarker)) &&
      !fs.existsSync(path.join(remoteRoot, credentialSubstitutionMarker)),
    'shell syntax inside a Snippet parameter was evaluated on the target');
    await click(page, 'Close');

    safeRunStage = 'sync structured Snippet from profile A';
    await syncNow(page, 'profile A Snippet');
    const pushCaptureDeadline = Date.now() + 30000;
    while (Date.now() < pushCaptureDeadline &&
        (snippetRelaySync.pushes.length === 0 ||
          snippetRelaySync.pushStatuses.length === 0)) {
      await page.waitForTimeout(100);
    }
    const capturedSnippetOperations = snippetRelaySync.pushes
      .flatMap((push) => push.operations);
    const uniqueSnippetOperations = new Map();
    for (const operation of capturedSnippetOperations) {
      const previous = uniqueSnippetOperations.get(operation.opId);
      if (previous) {
        assertThat(previous.envelopeSha256 === operation.envelopeSha256 &&
          previous.recordId === operation.recordId &&
          previous.revisionId === operation.revisionId,
        'A Snippet sync retry changed the encrypted operation');
      } else {
        uniqueSnippetOperations.set(operation.opId, operation);
      }
    }
    assertThat(uniqueSnippetOperations.size === 1 &&
      snippetRelaySync.pushes.every((push) => push.sensitiveMarkersAbsent) &&
      snippetRelaySync.pushStatuses.includes(200),
    'profile A did not push exactly one opaque Snippet operation successfully');
    const [snippetOperation] = uniqueSnippetOperations.values();
    assertThat(snippetOperation.operation === 'create' &&
      snippetOperation.opId && snippetOperation.recordId &&
      snippetOperation.revisionId,
    'profile A Snippet push was not a complete create operation');
    snippetRelaySync.expected = {
      ...snippetOperation,
      vaultId: snippetRelaySync.pushes[0].vaultId,
    };
    console.log('profile A Snippet push safe evidence', JSON.stringify({
      uniqueCreateOperationCount: uniqueSnippetOperations.size,
      successfulPushResponse: true,
      titlePlaintextAbsent: true,
      envelopeSha256: snippetOperation.envelopeSha256,
    }));
    safeRunStage = 'sync structured Snippet from profile A to independently approved profile B';
    const matchingBPushes = () => snippetRelaySync.pullResponses.flatMap((response) =>
      response.pulledOperations
        .filter((operation) => operation.opId === snippetRelaySync.expected.opId &&
          operation.recordId === snippetRelaySync.expected.recordId &&
          operation.revisionId === snippetRelaySync.expected.revisionId)
        .map((operation) => ({
          ...operation,
          vaultIdMatches: response.vaultIdInPath === snippetRelaySync.expected.vaultId,
          plaintextMarkersAbsent: operation.plaintextMarkersAbsent &&
            response.plaintextMarkersAbsent,
          envelopeHashMatches: operation.envelopeSha256 ===
            snippetRelaySync.expected.envelopeSha256,
        })));
    for (let attempt = 1; attempt <= 3 && matchingBPushes().length === 0; attempt += 1) {
      safeRunStage = `profile B pulls encrypted Snippet (attempt ${attempt})`;
      await syncNow(secondPage, `profile B Snippet ${attempt}`);
      const pullAttemptDeadline = Date.now() + 5000;
      while (Date.now() < pullAttemptDeadline && matchingBPushes().length === 0) {
        await secondPage.waitForTimeout(100);
      }
    }
    const exactSnippetPulls = matchingBPushes();
    if (exactSnippetPulls.length === 0) {
      console.log('profile B encrypted Snippet pull safe diagnostic', JSON.stringify({
        successfulChangesResponseCount: snippetRelaySync.pullResponses.length,
        changesResponses: snippetRelaySync.pullResponses.map((response) => ({
          eventCount: response.eventCount,
          operationCount: response.pulledOperations.length,
          expectedOperationPresent: response.pulledOperations.some((operation) =>
            operation.opId === snippetRelaySync.expected.opId &&
            operation.recordId === snippetRelaySync.expected.recordId &&
            operation.revisionId === snippetRelaySync.expected.revisionId),
        })),
      }));
    }
    assertThat(exactSnippetPulls.length > 0 &&
      exactSnippetPulls.every((pull) => pull.vaultIdMatches &&
          pull.plaintextMarkersAbsent && pull.envelopeHashMatches),
    'profile B did not pull A exact encrypted Snippet operation');
    console.log('profile B Snippet pull safe evidence', JSON.stringify({
      matchingEncryptedOperationCount: exactSnippetPulls.length,
      exactEnvelopeHashMatches: true,
      titlePlaintextAbsent: true,
    }));
    snippetRelaySync.active = false;
    safeRunStage = 'profile B finishes Snippet decryption and workspace projection';
    await syncNow(secondPage, 'profile B Snippet projection');
    safeRunStage = 'profile B opens synced Snippets workspace';
    await click(secondPage, 'Snippets');
    safeRunStage = 'profile B Snippets workspace is visible';
    await waitText(secondPage, 'Command snippets', 20000);
    const secondDeviceReviewButtons = secondPage.getByRole('button', {
      name: 'Review and run', exact: true,
    });
    await secondDeviceReviewButtons.last().waitFor({ state: 'visible', timeout: 15000 });
    const syncedSnippetCard = secondPage.getByRole('group', {
      name: `Snippet: ${snippetTitle}`, exact: true,
    });
    await syncedSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
    assertThat(await syncedSnippetCard.count() === 1 &&
      await secondDeviceReviewButtons.count() === 1,
    'profile B did not render exactly one synced Snippet card with Review and run');
    await secondDeviceReviewButtons.last().click();
    const secondDeviceSnippetPayload =
      `$(touch /tmp/remote/${substitutionMarker}_PROFILE_B)_${snippetMarker}_PROFILE_B`;
    await fill(secondPage, 'payload', secondDeviceSnippetPayload);
    await waitText(secondPage, 'Bash non-interactive execution');
    await waitText(secondPage, `Target: ${hostName} · ${targetAddress}:${sshPort}`);
    await waitText(secondPage, 'Execution preview');
    const secondDeviceExpectedPreview = [
      '/bin/bash', '-c', snippetScript, 'snippet', secondDeviceSnippetPayload,
      credentialPreview,
    ].map(quoteBashPreviewWord).join(' ');
    const secondDevicePreview = secondPage.getByText(secondDeviceExpectedPreview, { exact: true });
    await secondDevicePreview.waitFor({ state: 'visible', timeout: 15000 });
    assertThat(await secondDevicePreview.count() === 1,
      'profile B did not show the exact confirmed preview for the synced structured Snippet');
    const profileBReviewText = await secondPage.locator('body').innerText();
    assertThat(!profileBReviewText.includes(snippetCredentialSecret),
      'profile B execution preview exposed the synced Credential secret');
    const preConfirmationInvocation = fixtureFileSequenceEvidence(
      invocationPath,
      [snippetInvocationValue],
    );
    assertThat(preConfirmationInvocation.expectedSequenceMatches,
      'profile B ran the synced Snippet before its exact preview was confirmed');
    console.log('Cross-profile Snippet review safe evidence', JSON.stringify({
      profileBHasSyncedSnippet: true,
      targetMatchesSyncedHost: true,
      exactPreviewVisible: true,
      previewLength: secondDeviceExpectedPreview.length,
      previewSha256: crypto.createHash('sha256')
        .update(secondDeviceExpectedPreview).digest('hex'),
      invocationLineCountBeforeConfirmation: preConfirmationInvocation.lineCount,
      commandSentBeforeConfirmation: false,
    }));
    safeRunStage = 'profile B confirms and executes the synced structured Snippet through SSH Relay';
    await click(secondPage, 'Confirm and run');
    const secondDeviceSnippetResult = await waitForSnippetResult(
      secondPage,
      30000,
      redactCurrentSecrets,
    );
    const secondDeviceResultText = await secondPage.locator('body').innerText();
    assertThat(!secondDeviceResultText.includes(snippetCredentialSecret) &&
      secondDeviceResultText.includes(maskedSnippetCredentialSecret),
    'profile B execution output exposed the synced Credential secret instead of masking it');
    const secondDeviceInvocation = fixtureFileSequenceEvidence(invocationPath, [
      snippetInvocationValue,
      `${secondDeviceSnippetPayload}|${snippetCredentialSecret}`,
    ]);
    assertThat(secondDeviceSnippetResult.exitCodes.includes(0),
      'profile B Snippet execution did not report exit code zero');
    assertThat(secondDeviceInvocation.expectedSequenceMatches &&
      secondDeviceInvocation.expectedLineOccurrences[1] === 1,
    'profile B did not execute the synced Snippet exactly once after confirmation');
    assertThat(!fs.existsSync(path.join(remoteRoot, `${substitutionMarker}_PROFILE_B`)),
      'shell syntax in profile B text parameter was evaluated on the SSH target');
    assertThat(!fs.existsSync(path.join(remoteRoot, credentialSubstitutionMarker)),
      'shell syntax in the synced Credential secret was evaluated on the SSH target');
    const serverSecretStorageEvidence = fileMarkerAbsenceEvidence(
      [
        path.join(dataDir, 'atermius.db'),
        path.join(dataDir, 'atermius.db-wal'),
        path.join(dataDir, 'atermius.db-shm'),
      ],
      snippetCredentialSecret,
    );
    assertThat(serverSecretStorageEvidence.scannedFiles > 0 &&
      serverSecretStorageEvidence.plaintextMarkerAbsent,
    'Credential secret appeared in the server SQLite database or sidecars');
    await page.waitForTimeout(250);
    const secretSyncKinds = new Set(secretSyncPrivacy.checks.map((check) =>
      `${check.profile}:${check.direction}:${check.kind}`));
    const secretSyncBodiesAreSafe = secretSyncPrivacy.checks.length > 0 &&
      secretSyncPrivacy.checks.every((check) => check.markerAbsent);
    assertThat(secretSyncBodiesAreSafe &&
      secretSyncKinds.has('A:request:push') &&
      secretSyncKinds.has('A:response:push') &&
      secretSyncKinds.has('B:response:changes'),
    'Credential secret marker appeared in a captured sync request/response body');
    console.log('Cross-profile Snippet execution safe evidence', JSON.stringify({
      profileBExitCodes: secondDeviceSnippetResult.exitCodes,
      invocationLineCountAfterConfirmation: secondDeviceInvocation.lineCount,
      exactSecondDeviceInvocationOnce: true,
      shellSyntaxInTextParameterStayedLiteral: true,
      shellSyntaxInCredentialParameterStayedLiteral: true,
      secretMaskedFromAAndBExecutionOutput: true,
      syncPrivacyCheckCount: secretSyncPrivacy.checks.length,
      secretAbsentFromAllCapturedSyncBodies: true,
      credentialSecretAbsentFromServerDatabase: true,
      profileBRelayTicketTargetsAllowlistedBastion: true,
    }));
    await click(secondPage, 'Close');

    safeRunStage = 'structured Bash non-zero exit status';
    await click(page, 'Snippets');
    await click(page, 'New snippet');
    await fill(page, 'Title', `Relay nonzero ${RUN_ID.slice(0, 8)}`);
    await selectFormOption(page, 'Execution mode', 'Structured Bash command');
    await fill(page, 'Program', 'false');
    await fill(page, 'Parameter definitions (JSON array)', '[]');
    await fill(page, 'Arguments (JSON array)', '[]');
    safeRunStage = 'structured Bash non-zero snippet save';
    await click(page, 'Save snippet');
    safeRunStage = 'structured Bash non-zero snippet Review and run appears';
    const nonzeroSnippetCard = page.getByRole('group', {
      name: `Snippet: Relay nonzero ${RUN_ID.slice(0, 8)}`,
      exact: true,
    });
    await nonzeroSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
    const nonzeroReview = nonzeroSnippetCard.getByRole('button', {
      name: 'Review and run', exact: true,
    });
    await nonzeroReview.waitFor({ state: 'visible', timeout: 15000 });
    const expectedNonzeroPreview = quoteBashPreviewWord('false');
    const nonzeroPreview = page.getByText(expectedNonzeroPreview, { exact: true });
    const nonzeroPreviewUiEvidence = async () => {
      const [buttonCount, visibleButtonCount, enabledButtonCount, previewCount,
        visiblePreviewCount, dialogEvidence] = await Promise.all([
        nonzeroReview.count().catch(() => 0),
        nonzeroReview.isVisible().then((visible) => visible ? 1 : 0).catch(() => 0),
        nonzeroReview.isEnabled().then((enabled) => enabled ? 1 : 0).catch(() => 0),
        nonzeroPreview.count().catch(() => 0),
        nonzeroPreview.evaluateAll((elements) => elements.filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        }).length).catch(() => 0),
        page.evaluate(() => {
          const visibleDialogs = [...document.querySelectorAll(
            'flt-semantics[role="dialog"], [role="dialog"], [role="alertdialog"]')]
            .filter((element) => {
              const rect = element.getBoundingClientRect();
              const style = getComputedStyle(element);
              return rect.width > 0 && rect.height > 0 &&
                style.display !== 'none' && style.visibility !== 'hidden';
            });
          const labels = visibleDialogs.map((element) =>
            `${element.getAttribute('aria-label') || ''} ${element.innerText || element.textContent || ''}`
              .trim().toLowerCase());
          const titleKinds = [...new Set(labels.map((label) => {
            if (/review/.test(label)) return 'review';
            if (/confirm/.test(label)) return 'confirm';
            if (/execution result|bash non-interactive execution/.test(label)) return 'execution-result';
            return 'other';
          }))];
          return { visibleDialogCount: visibleDialogs.length, titleKinds };
        }).catch(() => ({ visibleDialogCount: 0, titleKinds: [] })),
      ]);
      return {
        reviewButtonCount: buttonCount,
        reviewButtonVisibleCount: visibleButtonCount,
        reviewButtonEnabledCount: enabledButtonCount,
        expectedPreviewPresent: previewCount > 0,
        expectedPreviewCount: previewCount,
        visibleSnippetPreviewCount: visiblePreviewCount,
        ...dialogEvidence,
      };
    };
    safeRunStage = 'structured Bash non-zero snippet preview click';
    try {
      await nonzeroReview.click();
    } catch (error) {
      console.log('Structured Bash non-zero preview click safe evidence', JSON.stringify({
        ...await nonzeroPreviewUiEvidence(),
        errorType: error?.name || 'Error',
      }));
      throw error;
    }
    safeRunStage = 'structured Bash non-zero snippet preview appears';
    try {
      await nonzeroPreview.waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      console.log('Structured Bash non-zero preview wait safe evidence', JSON.stringify({
        ...await nonzeroPreviewUiEvidence(),
        errorType: error?.name || 'Error',
      }));
      throw error;
    }
    assertThat(await nonzeroPreview.count() === 1,
      'non-zero snippet preview did not match the exact false command');
    safeRunStage = 'structured Bash non-zero snippet confirms';
    await click(page, 'Confirm and run');
    safeRunStage = 'structured Bash non-zero snippet exits';
    const nonzeroResult = await waitForSnippetResult(
      page,
      30000,
      redactCurrentSecrets,
    );
    console.log('Structured Bash non-zero result safe evidence', JSON.stringify({
      exitCodes: nonzeroResult.exitCodes,
      exitSignals: nonzeroResult.exitSignals,
      bashUnavailable: nonzeroResult.bashUnavailable,
      cancelled: nonzeroResult.cancelled,
      timedOut: nonzeroResult.timedOut,
      outputTruncated: nonzeroResult.outputTruncated,
      sshEndedWithoutExit: nonzeroResult.sshEndedWithoutExit,
      sshEndedBySignal: nonzeroResult.sshEndedBySignal,
      runningMessage: nonzeroResult.runningMessage,
      closeButtonCount: nonzeroResult.closeButtonCount,
      cancelButtonCount: nonzeroResult.cancelButtonCount,
      activeDialogIsExecutionResult: nonzeroResult.activeDialogIsExecutionResult,
      visibleDialogCount: nonzeroResult.visibleDialogCount,
      combinedTextLength: nonzeroResult.combinedTextLength,
      safeTextTail: nonzeroResult.safeTextTail,
    }));
    assertThat(nonzeroResult.exitCodes.includes(1),
      'structured Bash non-zero snippet did not report exit code one');
    safeRunStage = 'structured Bash non-zero snippet result closes';
    await click(page, 'Close');

    safeRunStage = 'structured Bash cancellation and terminal preservation';
    const canceledCommandPath = path.join(remoteRoot, 'c');
    await click(page, 'Snippets');
    await click(page, 'New snippet');
    const cancelSnippetTitle = `Relay cancel ${RUN_ID.slice(0, 8)}`;
    await fill(page, 'Title', cancelSnippetTitle);
    await selectFormOption(page, 'Execution mode', 'Structured Bash command');
    await fill(page, 'Program', '/bin/bash');
    await fill(page, 'Parameter definitions (JSON array)', '[]');
    await fill(page, 'Arguments (JSON array)',
      JSON.stringify([
        { kind: 'literal', value: '-c' },
        { kind: 'literal', value: 's=$SECONDS;while ((SECONDS<s+20));do :;done;: >/tmp/remote/c' },
        { kind: 'literal', value: 'snippet' },
      ]));
    safeRunStage = 'structured Bash cancellation snippet save';
    await click(page, 'Save snippet');
    safeRunStage = 'structured Bash cancellation snippet Review and run appears';
    const cancelSnippetCard = page.getByRole('group', {
      name: `Snippet: ${cancelSnippetTitle}`,
      exact: true,
    });
    await cancelSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
    const cancelReview = cancelSnippetCard.getByRole('button', {
      name: 'Review and run', exact: true,
    });
    await cancelReview.waitFor({ state: 'visible', timeout: 15000 });
    safeRunStage = 'structured Bash cancellation snippet opens preview';
    await cancelReview.click();
    safeRunStage = 'structured Bash cancellation snippet preview visible';
    await waitText(page, 'Bash non-interactive execution');
    safeRunStage = 'structured Bash cancellation snippet confirms';
    await click(page, 'Confirm and run');
    safeRunStage = 'structured Bash cancellation button appears';
    const cancelExecutionButton = page.getByRole('button', {
      name: 'Cancel execution', exact: true,
    });
    try {
      await cancelExecutionButton.waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      const cancelWaitUi = await page.evaluate(() => {
        const visibleDialogs = [...document.querySelectorAll(
          'flt-semantics[role="dialog"], [role="dialog"], [role="alertdialog"]')]
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              style.display !== 'none' && style.visibility !== 'hidden';
          });
        const activeDialog = visibleDialogs.at(-1) || null;
        const visibleText = activeDialog
          ? (activeDialog.innerText || activeDialog.textContent || '')
          : '';
        const visibleButtons = [...document.querySelectorAll(
          'flt-semantics[role="button"]')]
          .filter((element) => element.getClientRects().length > 0)
          .map((element) => (element.getAttribute('aria-label') ||
            element.innerText || '').trim());
        return {
          visibleDialogCount: visibleDialogs.length,
          activeDialogTextLength: visibleText.length,
          executionHeadingVisible: visibleText.includes(
            'Bash non-interactive execution'),
          runningMessageVisible: visibleText.includes(
            'Running once through a non-PTY SSH exec channel.'),
          cancellationRequestedVisible: visibleText.includes(
            'Cancellation requested.'),
          cancelButtonVisible: visibleButtons.includes('Cancel execution'),
          cancelingButtonVisible: visibleButtons.includes('Canceling…'),
          closeButtonVisible: visibleButtons.includes('Close'),
          canceledResultVisible: visibleText.includes(
            'Canceled. Remote completion status is unknown; the command was not retried.'),
          openPendingResultVisible: visibleText.includes(
            'SSH exec request has not replied'),
          timeoutResultVisible: visibleText.toLowerCase().includes('timed out'),
          errorDialogVisible: visibleText.includes('error') ||
            visibleText.includes('Error'),
        };
      }).catch(() => ({ available: false }));
      const cancelWaitSocket = safeRelayFrameCounts(firstRelaySocket);
      console.log('structured Bash cancellation wait safe diagnostic', JSON.stringify({
        error: safeErrorSummary(error),
        ui: cancelWaitUi,
        remoteCommandFinishedMarkerPresent: fs.existsSync(canceledCommandPath),
        relaySocket: {
          sent: cancelWaitSocket.sent,
          received: cancelWaitSocket.received,
        },
      }));
      throw error;
    }
    safeRunStage = 'structured Bash cancellation action';
    const cancelActionSocketBefore = safeRelayFrameCounts(firstRelaySocket);
    const cancelActionTargetBefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
    const cancelActionPageErrorBaseline = pageErrors.length;
    try {
      await cancelExecutionButton.click();
    } catch (error) {
      const cancelActionUi = await page.evaluate(() => {
        const text = document.body.innerText || '';
        const visibleButtons = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => element.getClientRects().length > 0)
          .map((element) => (element.getAttribute('aria-label') || element.innerText || '').trim());
        const cancellationRequestedText =
          'Cancellation requested. The command may already have started; it will not be retried.';
        const cancellationResultText =
          'Canceled. Remote completion status is unknown; the command was not retried.';
        return {
          cancellationPromptVisible: text.includes('Cancel execution') ||
            visibleButtons.includes('Cancel execution'),
          cancelingButtonVisible: visibleButtons.includes('Canceling…') ||
            visibleButtons.includes('Canceling...'),
          cancellationRequestedVisible: text.includes(cancellationRequestedText),
          cancellationResultVisible: text.includes(cancellationResultText),
          executionPreviewVisible: text.includes('Bash non-interactive execution'),
          connectedStatusVisible: text.includes('CONNECTED'),
          visibleCancelButtonCount: visibleButtons.filter((label) =>
            label === 'Cancel execution').length,
        };
      }).catch(() => ({ available: false }));
      const cancelActionSocketAfter = safeRelayFrameCounts(firstRelaySocket);
      const cancelActionTargetAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      console.log('structured Bash cancellation click safe diagnostic', JSON.stringify({
        error: safeErrorSummary(error),
        ui: cancelActionUi,
        remoteCommandFinishedMarkerPresent: fs.existsSync(canceledCommandPath),
        relaySocket: {
          before: cancelActionSocketBefore,
          sentDelta: safeCounterDelta(cancelActionSocketBefore.sent,
            cancelActionSocketAfter.sent, ['total', 'text', 'binary', 'other']),
          receivedDelta: safeCounterDelta(cancelActionSocketBefore.received,
            cancelActionSocketAfter.received, ['total', 'text', 'binary', 'other']),
        },
        targetASshdDelta: safeCounterDelta(cancelActionTargetBefore,
          cancelActionTargetAfter, [
            'tcpConnectionsAccepted', 'connectionsClosed', 'sessionOpenRequests',
            'sessionStarts', 'commandSessionStarts', 'remoteExecFailures',
          ]),
        pageErrorsSinceAction: pageErrors.slice(cancelActionPageErrorBaseline).slice(-5),
      }));
      const cancellationWasDispatched = cancelActionUi.cancellationRequestedVisible ||
        cancelActionUi.cancelingButtonVisible || cancelActionUi.cancellationResultVisible;
      if (!cancellationWasDispatched) throw error;
      console.log('structured Bash cancellation UI confirmed the dispatched action after the control changed state',
        JSON.stringify({ cancellationWasDispatched: true,
          cancelingButtonVisible: cancelActionUi.cancelingButtonVisible,
          cancellationRequestedVisible: cancelActionUi.cancellationRequestedVisible,
          cancellationResultVisible: cancelActionUi.cancellationResultVisible }));
    }
    safeRunStage = 'structured Bash cancellation result visible';
    await waitText(page,
      'Canceled. Remote completion status is unknown; the command was not retried.', 15000);
    safeRunStage = 'structured Bash cancellation result closes';
    await click(page, 'Close');
    safeRunStage = 'structured Bash cancellation stops remote process';
    await page.waitForTimeout(4500);
    assertThat(!fs.existsSync(canceledCommandPath),
      'the remote command continued after its exec channel was canceled');
    safeRunStage = 'structured Bash cancellation returns to terminal workspace';
    await click(page, 'Terminal');
    safeRunStage = 'structured Bash cancellation retains terminal connection';
    await waitText(page, 'CONNECTED', 15000);
    const afterCancelMarker = `WEB_RELAY_AFTER_CANCEL_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const afterCancelMarkerPath = path.join(remoteRoot, 'after-cancel-marker');
    safeRunStage = 'structured Bash cancellation reuses terminal connection';
    await sendCommandToActiveTerminal(page, user, targetAddress,
      `printf '%s\\n' '${afterCancelMarker}' > '/tmp/remote/after-cancel-marker'; printf '%s\\n' '${afterCancelMarker}'`, {
        activeHostName: hostName,
      });
    safeRunStage = 'structured Bash cancellation terminal marker verified';
    assertThat(await waitForRemoteMarker(afterCancelMarkerPath, afterCancelMarker),
      'canceling snippet execution closed the shared interactive SSH connection');
    console.log('stage: structured text argv, literal shell metacharacters, exit status, cancel, and terminal reuse verified through the Relay target');

    const firstTerminalFingerprint = await stableTerminalVisualFingerprint(page, user, targetAddress);
    const secondHostName = `Local relay SSH second ${RUN_ID.slice(0, 6)}`;
    const secondTargetCredentialName = `Relay target key B ${RUN_ID.slice(0, 6)}`;
    safeRunStage = 'second SSH Host creation';
    expectedPrivateKey = fs.readFileSync(
      path.join(tempRoot, 'second_target_client_ecdsa'),
      'utf8',
    ).replace(/[\r\n]+$/, '');
    let secondTargetCredentialId;
    try {
      secondTargetCredentialId = await savePrivateKeyCredential(page, {
        name: secondTargetCredentialName,
        username: user,
        keyPath: path.join(tempRoot, 'second_target_client_ecdsa'),
      });
    } finally {
      expectedPrivateKey = undefined;
    }
    const secondHostCard = await createSshHost(page, {
      name: secondHostName,
      address: targetAddress,
      port: sshPort2,
      username: user,
      credentialName: secondTargetCredentialName,
      credentialId: secondTargetCredentialId,
      jumpHostChoice,
      verifySavedCredentialOverride: true,
    });

    const relayTicketBaseline = relayTicketChecksForPage(page).length;
    const secondRelaySocketBaseline = relaySocketsForPage(page).length;
    const secondTargetConnectionBefore = sshdRuntimeSummary(
      path.join(tempRoot, 'sshd-target-b.log'),
    );
    const secondJumpAConnectionBefore = sshdRuntimeSummary(
      path.join(tempRoot, 'jump-sshd.log'),
    );
    const secondJumpBConnectionBefore = sshdRuntimeSummary(
      path.join(tempRoot, 'second-jump-sshd.log'),
    );
    const secondConnectionPageErrorBaseline = pageErrors.length;
    let secondConnectionSignal = null;
    let secondConnectClickCompleted = false;
    let secondTrustPromptSeen = false;
    let secondTrustPromptCount = 0;
    let secondRelaySocket = null;
    try {
      safeRunStage = 'second SSH terminal Connect click';
      await secondHostCard.getByRole('button', {
        name: 'Connect', exact: true,
      }).click();
      secondConnectClickCompleted = true;

      safeRunStage = 'second SSH terminal trust/connected signal';
      for (let trustAttempt = 0; trustAttempt < 2; trustAttempt += 1) {
        secondConnectionSignal = await waitForTerminalConnectionOrTrust(
          page,
          secondHostName,
        );
        if (secondConnectionSignal !== 'trust_prompt') break;
        secondTrustPromptSeen = true;
        secondTrustPromptCount += 1;
        const promptToken = await sshTrustPromptToken(page);
        safeRunStage = 'second SSH terminal host-key trust confirmation';
        await click(page, 'Trust after verification');
        await waitForSshTrustPromptAdvance(page, promptToken, 60000);
      }
      safeRunStage = 'second SSH terminal connected signal assertion';
      assertThat(secondConnectionSignal === 'connected',
        'second SSH terminal did not complete the connection after host-key trust');
      assertThat(secondTrustPromptCount === 1,
        `second SSH terminal should require exactly one new Target trust prompt (${secondTrustPromptCount})`);

      safeRunStage = 'second SSH terminal first-tab inactive semantics';
      await terminalTabButton(page, hostName, 'inactive');
      safeRunStage = 'second SSH terminal second-tab active semantics';
      await terminalTabButton(page, secondHostName, 'active');

      safeRunStage = 'second SSH terminal CONNECTED status';
      await waitText(page, 'CONNECTED', 40000);
      safeRunStage = 'second SSH terminal connected header';
      await waitText(page, `${user}@${targetAddress}`);

      safeRunStage = 'second SSH terminal Relay socket assertion';
      const secondTerminalSocketAttempts = relaySocketsForPage(page)
        .slice(secondRelaySocketBaseline);
      secondRelaySocket = secondTerminalSocketAttempts.at(-1);
      assertThat(firstRelaySocket.opened && !firstRelaySocket.closed &&
        secondRelaySocket && secondRelaySocket !== firstRelaySocket &&
        secondRelaySocket.opened && !secondRelaySocket.closed,
      'two simultaneously live Hosts did not retain separate Relay sockets');
      safeRunStage = 'second SSH terminal Relay ticket assertion';
      const secondTerminalTicketAttempts = relayTicketChecksForPage(page).slice(
        relayTicketBaseline,
      );
      assertThat(relayAttemptCountIsBounded(
        secondTerminalTicketAttempts.length,
        oneJumpRouteRelayAttempts,
        2,
      ) && secondTerminalSocketAttempts.length ===
        secondTerminalTicketAttempts.length &&
        secondTerminalTicketAttempts.every(Boolean),
      'second terminal exceeded the bounded Relay retry budget or sent a ticket outside the first hop');
      console.log('second SSH terminal Relay retry safe evidence', JSON.stringify({
        ticketAttempts: secondTerminalTicketAttempts.length,
        socketAttempts: secondTerminalSocketAttempts.length,
        allTicketsTargetedAtFirstHop: secondTerminalTicketAttempts.every(Boolean),
        retryBudgetMaximum: maxRelayAttemptsForRoute(2),
      }));
      const secondTargetConnectionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'),
      );
      const secondJumpAConnectionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'jump-sshd.log'),
      );
      const secondTargetAuthDelta = safeCounterDelta(
        secondTargetConnectionBefore,
        secondTargetConnectionAfter,
        ['tcpConnectionsAccepted', 'publicKeyAccepted', 'publicKeyRejected',
          'sessionOpenRequests', 'sessionStarts'],
      );
      const secondJumpAAuthDelta = safeCounterDelta(
        secondJumpAConnectionBefore,
        secondJumpAConnectionAfter,
        ['tcpConnectionsAccepted', 'publicKeyAccepted', 'publicKeyRejected'],
      );
      console.log('second SSH terminal independent hop credential safe evidence',
        JSON.stringify({
          targetBPublicKeyAccepted: secondTargetAuthDelta.publicKeyAccepted > 0,
          bastionAPublicKeyAccepted: secondJumpAAuthDelta.publicKeyAccepted > 0,
          targetBAuthDelta: secondTargetAuthDelta,
          bastionAAuthDelta: secondJumpAAuthDelta,
          credentialSecretInspected: false,
        }));
      assertThat(secondTargetAuthDelta.publicKeyAccepted > 0 &&
        secondTargetAuthDelta.sessionStarts > 0 &&
        secondJumpAAuthDelta.publicKeyAccepted > 0,
      'the saved second Host and its Jump Host did not authenticate with their independent SSH keys');
    } catch (error) {
      const expectedTabState = await safeTerminalRouteInputDiagnostics(page, {
        activeHostName: secondHostName,
        inactiveHostName: hostName,
      });
      const connectedStatus = page.getByText('CONNECTED', { exact: true });
      const connectedHeader = page.getByText(`${user}@${targetAddress}`, {
        exact: true,
      });
      const [connectedStatusCount, connectedStatusVisible,
        connectedHeaderCount, connectedHeaderVisible] = await Promise.all([
        connectedStatus.count().catch(() => null),
        connectedStatus.isVisible().catch(() => false),
        connectedHeader.count().catch(() => null),
        connectedHeader.isVisible().catch(() => false),
      ]);
      const secondTargetConnectionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'),
      );
      const secondJumpAConnectionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'jump-sshd.log'),
      );
      const secondJumpBConnectionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'second-jump-sshd.log'),
      );
      const secondConnectionSockets = relaySockets
        .slice(secondRelaySocketBaseline)
        .slice(-3)
        .map((socket) => safeRelayFrameCounts(socket));
      console.log('second SSH terminal connection safe diagnostic', JSON.stringify({
        phase: safeRunStage,
        error: safeErrorSummary(error),
        connectClickCompleted: secondConnectClickCompleted,
        trustPromptSeen: secondTrustPromptSeen,
        trustPromptCount: secondTrustPromptCount,
        connectionSignal: [
          'trust_prompt', 'trusted', 'connected', 'host_key_rejected',
          'timeout_exception', 'relay_transport_error', 'relay_ticket_error',
          'deadline_without_connection', 'deadline_without_visible_signal',
        ].includes(secondConnectionSignal) ? secondConnectionSignal : 'unavailable',
        expectedTabState,
        terminalLifecycle: await safeTerminalTabLifecycleDiagnostics(
          page, hostName, secondHostName),
        connectedStatusCount,
        connectedStatusVisible,
        connectedHeaderCount,
        connectedHeaderVisible,
        relayTicketCountBefore: relayTicketBaseline,
        relayTicketCountAfter: relayTicketChecksForPage(page).length,
        relayTicketCountDelta: relayTicketChecksForPage(page).length -
          relayTicketBaseline,
        latestRelayTicketTargetAllowlisted:
          relayTicketChecksForPage(page).length > relayTicketBaseline
            ? relayTicketChecksForPage(page).at(-1) === true
            : null,
        firstRelaySocket: {
          opened: Boolean(firstRelaySocket?.opened),
          closed: Boolean(firstRelaySocket?.closed),
        },
        secondRelaySocketCountDelta: relaySocketsForPage(page).length -
          secondRelaySocketBaseline,
        secondRelaySockets: secondConnectionSockets.map((socket) => ({
          opened: socket.opened,
          closed: socket.closed,
          sentFrameCount: socket.sent.total,
          receivedFrameCount: socket.received.total,
          socketError: socket.socketError,
        })),
        browserRelayCloseMetadata: await safeBrowserRelayCloseMetadata(page)
          .catch(() => []),
        sshDiagnosticSummary: safeSshDiagnosticSummary(sshDiagnostics),
        relayDatabase: readRelayDatabaseSummary(path.join(dataDir, 'atermius.db')),
        relayServerLog: safeRelayServerLogSummary(serverLogPath),
        jumpASshdDelta: safeCounterDelta(
          secondJumpAConnectionBefore,
          secondJumpAConnectionAfter,
          [
            'tcpConnectionsAccepted', 'connectionsClosed',
            'serverSshBannerEmitted', 'clientSshBannerReceived',
            'keyExchangeStarted', 'keyExchangeErrors', 'publicKeyAccepted',
            'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
          ],
        ),
        jumpBSshdDelta: safeCounterDelta(
          secondJumpBConnectionBefore,
          secondJumpBConnectionAfter,
          [
            'tcpConnectionsAccepted', 'connectionsClosed',
            'serverSshBannerEmitted', 'clientSshBannerReceived',
            'keyExchangeStarted', 'keyExchangeErrors', 'publicKeyAccepted',
            'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
          ],
        ),
        targetBSshdDelta: safeCounterDelta(
          secondTargetConnectionBefore,
          secondTargetConnectionAfter,
          [
            'tcpConnectionsAccepted', 'connectionsClosed',
            'serverSshBannerEmitted', 'clientSshBannerReceived',
            'keyExchangeStarted', 'keyExchangeErrors', 'publicKeyAccepted',
            'publicKeyRejected', 'authorizedKeysFileLookups',
            'authorizedKeysMatches', 'authorizedKeysUnavailable',
            'permissionDenialLogMentions', 'authorizedKeysRefusedByMode',
            'keysNotAllowed', 'signatureAlgorithmMentions',
            'authorizedKeyOptionMentions', 'authorizedKeyOptionRejections',
            'accountPolicyDenials', 'validUserPublicKeyChecks',
            'invalidUserPublicKeyChecks', 'signedPublicKeyAttempts',
            'publicKeyProbeAttempts', 'keyAlgorithmRefusals',
            'authenticationFailures', 'sessionOpenRequests', 'sessionStarts',
            'commandSessionStarts', 'remoteExecFailures',
          ],
        ),
        pageErrorCountDelta: Math.max(0, pageErrors.length -
          secondConnectionPageErrorBaseline),
        recentPageErrorCategories: pageErrors.slice(
          secondConnectionPageErrorBaseline,
        ).slice(-5),
      }));
      throw error;
    }

    safeRunStage = 'batch structured Snippet target selection and single confirmation';
    await click(page, 'Snippets');
    const batchSnippetCard = page.getByRole('group', {
      name: `Snippet: ${snippetTitle}`,
      exact: true,
    });
    await batchSnippetCard.waitFor({ state: 'visible', timeout: 15000 });
    const batchReviewButton = batchSnippetCard.getByRole('button', {
      name: 'Review on 2 connected Hosts',
      exact: true,
    });
    await batchReviewButton.waitFor({ state: 'visible', timeout: 15000 });
    await batchReviewButton.click();
    safeRunStage = 'batch structured Snippet chooser title';
    await waitText(page, 'Choose connected Hosts');
    safeRunStage = 'batch structured Snippet chooser alertdialog role';
    const chooser = page.getByRole('alertdialog').last();
    await chooser.waitFor({ state: 'visible', timeout: 15000 });
    safeRunStage = 'batch structured Snippet chooser target checkboxes';
    const targetChoices = chooser.getByRole('checkbox');
    assertThat(await targetChoices.count() === 2,
      'batch chooser did not list the two distinct connected Hosts');
    await targetChoices.last().click();
    safeRunStage = 'batch structured Snippet review button enabled';
    const reviewBothTargets = chooser.getByRole('button', {
      name: 'Review 2 Hosts',
      exact: true,
    });
    const reviewDeadline = Date.now() + 15000;
    let reviewButtonStableSamples = 0;
    let selectedTargets = [false, false];
    let reviewButtonEnabled = false;
    while (Date.now() < reviewDeadline && reviewButtonStableSamples < 2) {
      selectedTargets = await Promise.all([
        targetChoices.nth(0).isChecked().catch(() => false),
        targetChoices.nth(1).isChecked().catch(() => false),
      ]);
      reviewButtonEnabled = await reviewBothTargets.isEnabled().catch(() => false);
      reviewButtonStableSamples = reviewButtonEnabled
        ? reviewButtonStableSamples + 1
        : 0;
      if (reviewButtonStableSamples < 2) await page.waitForTimeout(150);
    }
    assertThat(reviewButtonEnabled && reviewButtonStableSamples >= 2,
      'batch chooser did not enable review after both Hosts were selected');
    console.log('batch target selection safe evidence', JSON.stringify({
      targetCount: await targetChoices.count(),
      checkedStates: selectedTargets,
      reviewButtonVisible: await reviewBothTargets.isVisible().catch(() => false),
      reviewButtonEnabled,
      stableEnabledSamples: reviewButtonStableSamples,
    }));
    safeRunStage = 'batch structured Snippet open review for both targets';
    await reviewBothTargets.click({ timeout: 15000 });
    safeRunStage = 'batch structured Snippet review dialog title';
    const batchReviewDialog = page.getByRole('alertdialog').last();
    try {
      await batchReviewDialog.waitFor({ state: 'visible', timeout: 15000 });
      await batchReviewDialog.getByText('Review batch command', {
        exact: true,
      }).waitFor({ state: 'visible', timeout: 15000 });
    } catch (error) {
      const transitionEvidence = await page.evaluate(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden' &&
            rect.bottom > 0 && rect.right > 0 &&
            rect.top < window.innerHeight && rect.left < window.innerWidth;
        };
        const semantics = [...document.querySelectorAll('flt-semantics')]
          .filter(visible);
        const text = [document.body.innerText || '', ...semantics.map((element) =>
          `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`)]
          .join('\n');
        const labels = semantics.map((element) =>
          element.getAttribute('aria-label') || element.innerText || '');
        return {
          visibleAlertDialogCount: semantics.filter((element) =>
            element.getAttribute('role') === 'alertdialog').length,
          visibleDialogCount: semantics.filter((element) =>
            element.getAttribute('role') === 'dialog').length,
          chooserStillVisible: text.includes('Choose connected Hosts'),
          batchReviewVisible: text.includes('Review batch command'),
          connectedTerminalTabCount: new Set(labels.filter((label) =>
            / terminal tab, connected, (?:active|inactive)$/.test(label))).size,
          credentialUnavailable: /effective SSH credential is unavailable|Credential reference .* unavailable|unavailable Credential/i.test(text),
          hostKeyTrustChanged: /SSH host-key trust changed|主机密钥.*变化/i.test(text),
          unresolvedExecRequest: /unresolved SSH exec request/i.test(text),
          routeOrHostChanged: /selected Host, connection, or Snippet changed/i.test(text),
          connectionRequired: /please connect|请先连接 SSH 主机/i.test(text),
          genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(text),
        };
      }).catch(() => ({ available: false }));
      console.log('batch Snippet review transition safe evidence', JSON.stringify({
        ...transitionEvidence,
        pageErrorCount: pageErrors.length,
        browserConsoleErrorCount: browserConsoleEvents.length,
        failedRequestCount: requestFailures.length,
        errorType: error?.name || 'Error',
      }));
      throw error;
    }
    safeRunStage = 'batch structured Snippet review target one';
    await waitText(page, `Target 1: ${secondHostName} · ${targetAddress}:${sshPort2}`);
    safeRunStage = 'batch structured Snippet review target two';
    await waitText(page, `Target 2: ${hostName} · ${targetAddress}:${sshPort}`);
    const batchSnippetPayload =
      `$(touch /tmp/remote/${substitutionMarker}_BATCH)_${snippetMarker}_BATCH`;
    const batchInvocationValue = `${batchSnippetPayload}|${snippetCredentialSecret}`;
    await fill(page, 'payload', batchSnippetPayload);
    const batchExpectedPreview = [
      '/bin/bash', '-c', snippetScript, 'snippet', batchSnippetPayload,
      credentialPreview,
    ].map(quoteBashPreviewWord).join(' ');
    const batchPreviewText = page.getByText(batchExpectedPreview, { exact: true });
    await batchPreviewText.first().waitFor({ state: 'visible', timeout: 15000 });
    assertThat(await batchPreviewText.count() === 2,
      'batch review did not show the exact command preview once per target');
    const batchReviewText = await page.locator('body').innerText();
    assertThat(!batchReviewText.includes(snippetCredentialSecret),
      'batch review exposed the referenced Credential secret');
    const firstTargetBeforeBatch = fixtureFileSequenceEvidence(invocationPath, [
      snippetInvocationValue,
      `${secondDeviceSnippetPayload}|${snippetCredentialSecret}`,
    ]);
    const secondTargetInvocationPath = path.join(
      secondRemoteRoot,
      invocationFilename,
    );
    assertThat(firstTargetBeforeBatch.expectedSequenceMatches &&
      !fs.existsSync(secondTargetInvocationPath) &&
      !fs.existsSync(path.join(remoteRoot, `${substitutionMarker}_BATCH`)) &&
      !fs.existsSync(path.join(secondRemoteRoot, `${substitutionMarker}_BATCH`)),
    'a target ran the batch Snippet before the single confirmation');
    console.log('batch Snippet review safe evidence', JSON.stringify({
      distinctConnectedHosts: 2,
      targetAEndpoint: `${targetAddress}:${sshPort}`,
      targetBEndpoint: `${targetAddress}:${sshPort2}`,
      exactPerTargetPreviewCount: 2,
      noDispatchBeforeConfirmation: true,
      credentialSecretHidden: true,
    }));
    safeRunStage = 'batch structured Snippet single confirmation';
    await click(page, 'Confirm and run on 2 Hosts');
    safeRunStage = 'batch structured Snippet wait for both Host outcomes';
    await waitText(page, '2 target(s) reported a known result; 0 remote completion unknown;', 30000);
    const batchResult = await waitForSnippetResult(page, 30000, redactCurrentSecrets);
    safeRunStage = 'batch structured Snippet inspect both Host outcomes';
    const batchResultText = await page.locator('body').innerText();
    const batchOutcomeEvidence = {
      exitCodes: batchResult.exitCodes,
      targetAVisible: batchResultText.includes(`${hostName} · ${targetAddress}:${sshPort}`),
      targetBVisible: batchResultText.includes(`${secondHostName} · ${targetAddress}:${sshPort2}`),
      visibleStatuses: batchResultText.match(/Exit code:\s*-?\d+|Remote completion unknown · not retried|Not started|Bash is unavailable on this target[^\n]*/g) || [],
      summaryVisible: batchResultText.includes('2 target(s) reported a known result; 0 remote completion unknown;'),
      secretAbsent: !batchResultText.includes(snippetCredentialSecret),
    };
    console.log('batch Snippet outcomes safe evidence', JSON.stringify(batchOutcomeEvidence));
    safeRunStage = 'batch structured Snippet assert both Host outcomes';
    assertThat(batchOutcomeEvidence.exitCodes.includes(0) &&
      batchOutcomeEvidence.targetAVisible && batchOutcomeEvidence.targetBVisible &&
      batchOutcomeEvidence.visibleStatuses.filter((status) => status === 'Exit code: 0').length === 2 &&
      batchOutcomeEvidence.secretAbsent,
    'batch Snippet did not report one successful outcome for each reviewed Host');
    safeRunStage = 'batch structured Snippet verify exactly-once target files';
    const firstTargetAfterBatch = fixtureFileSequenceEvidence(invocationPath, [
      snippetInvocationValue,
      `${secondDeviceSnippetPayload}|${snippetCredentialSecret}`,
      batchInvocationValue,
    ]);
    const secondTargetAfterBatch = fixtureFileSequenceEvidence(
      secondTargetInvocationPath,
      [batchInvocationValue],
    );
    assertThat(firstTargetAfterBatch.expectedSequenceMatches &&
      firstTargetAfterBatch.expectedLineOccurrences.at(-1) === 1 &&
      secondTargetAfterBatch.expectedSequenceMatches &&
      secondTargetAfterBatch.expectedLineOccurrences[0] === 1 &&
      !fs.existsSync(path.join(remoteRoot, `${substitutionMarker}_BATCH`)) &&
      !fs.existsSync(path.join(secondRemoteRoot, `${substitutionMarker}_BATCH`)),
    'the batch did not create exactly one literal invocation in each isolated target');
    console.log('batch Snippet execution safe evidence', JSON.stringify({
      profile: 'A',
      distinctTargetInvocationFiles: 2,
      targetAInvocationCount: firstTargetAfterBatch.lineCount,
      targetBInvocationCount: secondTargetAfterBatch.lineCount,
      eachTargetRanExactlyOnce: true,
      bothExitCodesZero: true,
      shellSyntaxInTextParameterStayedLiteral: true,
      noRetry: true,
    }));
    safeRunStage = 'batch structured Snippet result closes';
    await click(page, 'Close');
    safeRunStage = 'batch structured Snippet navigates back to Terminal';
    await click(page, 'Terminal');
    safeRunStage = 'batch structured Snippet waits for Terminal route and input semantics';
    await waitForTerminalRouteInputReady(page, {
      activeHostName: secondHostName,
      inactiveHostName: hostName,
    }, 15000);
    await waitText(page, 'CONNECTED', 15000);

    safeRunStage = 'second SSH terminal marker and scrollback';
    const secondMarkerValue = `WEB_RELAY_TAB_B_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const secondMarkerPath = path.join(secondRemoteRoot, 'terminal-tab-b-marker');
    const secondRemoteMarkerPath = '/tmp/remote/terminal-tab-b-marker';
    const secondShellCommand = `i=0; while [ "$i" -lt 80 ]; do i=$((i+1)); printf 'SCROLL_${secondMarkerValue}_%s\\n' "$i"; done; printf '%s\\n' '${secondMarkerValue}' > '${secondRemoteMarkerPath}'; printf '%s\\n' '${secondMarkerValue}'; printf '\\033[?25l'`;
    const secondOutputFrameBaseline = secondRelaySocket.receivedFrames.length;
    await sendCommandToActiveTerminal(page, user, targetAddress, secondShellCommand, {
      activeHostName: secondHostName,
      inactiveHostName: hostName,
    });
    const secondMarkerCreated = await waitForRemoteMarker(secondMarkerPath, secondMarkerValue);
    assertThat(secondMarkerCreated, 'second active terminal did not create its isolated shell marker');
    assertThat(await waitForRelayOutputFrame(page, secondRelaySocket, secondOutputFrameBaseline),
      'second terminal did not receive shell output');
    const secondTerminalFingerprint = await stableTerminalVisualFingerprint(
      page, user, targetAddress, 15000, firstTerminalFingerprint);
    const terminalBuffersDiffer = firstTerminalFingerprint !== secondTerminalFingerprint;
    assertThat(terminalBuffersDiffer,
      'the two active SSH terminal buffers rendered the same screen');

    safeRunStage = 'first SSH terminal tab restoration';
    await (await terminalTabButton(page, hostName, 'inactive')).click();
    await terminalTabButton(page, hostName, 'active');
    await terminalTabButton(page, secondHostName, 'inactive');
    await waitText(page, 'CONNECTED');
    const firstRestoredFingerprint = await stableTerminalVisualFingerprint(
      page, user, targetAddress, 15000, secondTerminalFingerprint);
    const firstTerminalRestored = firstRestoredFingerprint === firstTerminalFingerprint;
    assertThat(firstTerminalRestored,
      'switching back did not restore the first terminal screen and scrollback');

    safeRunStage = 'active first terminal input routing';
    const firstActiveMarker = `WEB_RELAY_TAB_A_ACTIVE_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const firstActiveMarkerPath = path.join(remoteRoot, 'terminal-tab-a-active-marker');
    const firstActiveRemotePath = '/tmp/remote/terminal-tab-a-active-marker';
    const firstActiveCommand = `i=0; while [ "$i" -lt 80 ]; do i=$((i+1)); printf 'SCROLL_${firstActiveMarker}_%s\\n' "$i"; done; printf '%s\\n' '${firstActiveMarker}' > '${firstActiveRemotePath}'; printf '%s\\n' '${firstActiveMarker}'; printf '\\033[?25l'`;
    const firstActiveOutputBaseline = firstRelaySocket.receivedFrames.length;
    const firstActiveFirstFrameBefore = safeRelayFrameCounts(firstRelaySocket);
    const firstActiveSecondFrameBefore = safeRelayFrameCounts(secondRelaySocket);
    const firstActiveXtermBefore = safeXtermEventCounts(xtermInputDiagnostics);
    const firstActiveTargetBefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
    const firstActiveTargetBBefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'));
    const firstActiveBastionBefore = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    const firstActiveTabsBefore = await safeTerminalTabStateDiagnostics(page, hostName, secondHostName);
    const firstActivePageErrorBaseline = pageErrors.length;
    const firstActiveFocusBefore = await safePageInputFocusState(page);
    await installSafePageInputCounters(page);
    safeRunStage = 'active first SSH terminal command dispatch';
    await sendCommandToActiveTerminal(page, user, targetAddress, firstActiveCommand, {
      activeHostName: hostName,
      inactiveHostName: secondHostName,
    });
    safeRunStage = 'active first SSH terminal marker observation';
    const firstActiveMarkerCreated = await waitForRemoteMarker(
      firstActiveMarkerPath, firstActiveMarker);
    safeRunStage = 'active first SSH terminal output frame observation';
    const firstActiveOutputObserved = firstActiveMarkerCreated &&
      await waitForRelayOutputFrame(page, firstRelaySocket, firstActiveOutputBaseline);
    const firstActivePageEvents = await readAndRemoveSafePageInputCounters(page);
    if (!firstActiveMarkerCreated || !firstActiveOutputObserved) {
      const firstActiveFirstFrameAfter = safeRelayFrameCounts(firstRelaySocket);
      const firstActiveSecondFrameAfter = safeRelayFrameCounts(secondRelaySocket);
      const firstActiveXtermAfter = safeXtermEventCounts(xtermInputDiagnostics);
      const firstActiveTargetAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const firstActiveTargetBAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'));
      const firstActiveBastionAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'jump-sshd.log'));
      console.log('active first SSH terminal input safe diagnostic', JSON.stringify({
        phase: safeRunStage,
        commandDispatched: true,
        tabsBefore: firstActiveTabsBefore,
        tabsAtFailure: await safeTerminalTabLifecycleDiagnostics(
          page, hostName, secondHostName),
        pageBefore: firstActiveFocusBefore,
        pageAfter: await safePageInputFocusState(page),
        pageEventCounts: firstActivePageEvents,
        firstSocket: {
          before: firstActiveFirstFrameBefore,
          opened: Boolean(firstRelaySocket?.opened),
          closed: Boolean(firstRelaySocket?.closed),
          socketError: Boolean(firstRelaySocket?.socketError),
          delta: {
            sent: safeCounterDelta(firstActiveFirstFrameBefore.sent,
              firstActiveFirstFrameAfter.sent, ['total', 'text', 'binary', 'other']),
            received: safeCounterDelta(firstActiveFirstFrameBefore.received,
              firstActiveFirstFrameAfter.received, ['total', 'text', 'binary', 'other']),
          },
        },
        secondSocket: {
          before: firstActiveSecondFrameBefore,
          delta: {
            sent: safeCounterDelta(firstActiveSecondFrameBefore.sent,
              firstActiveSecondFrameAfter.sent, ['total', 'text', 'binary', 'other']),
            received: safeCounterDelta(firstActiveSecondFrameBefore.received,
              firstActiveSecondFrameAfter.received, ['total', 'text', 'binary', 'other']),
          },
        },
        xtermEventDelta: safeCounterDelta(firstActiveXtermBefore, firstActiveXtermAfter,
          Object.keys(firstActiveXtermBefore)),
        targetASshdDelta: safeCounterDelta(firstActiveTargetBefore, firstActiveTargetAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed',
          'serverSshBannerEmitted', 'clientSshBannerReceived',
          'keyExchangeErrors', 'publicKeyAccepted', 'publicKeyRejected',
          'sessionOpenRequests', 'sessionStarts', 'commandSessionStarts',
          'remoteExecFailures', 'shellRequestMentions',
        ]),
        targetBSshdDelta: safeCounterDelta(firstActiveTargetBBefore,
          firstActiveTargetBAfter, [
            'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
            'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
            'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
            'commandSessionStarts', 'remoteExecFailures',
          ]),
        bastionASshdDelta: safeCounterDelta(firstActiveBastionBefore,
          firstActiveBastionAfter, [
            'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
            'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
            'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
          ]),
        targetMarkerPresent: logFileSummary(firstActiveMarkerPath).present,
        targetMarkerBytes: logFileSummary(firstActiveMarkerPath).bytes ?? null,
        markerObserved: firstActiveMarkerCreated,
        outputFrameObserved: Boolean(firstActiveOutputObserved),
        browserRelayCloseMetadata: await safeBrowserRelayCloseMetadata(page)
          .catch(() => []),
        activeTabs: await safeTerminalTabStateDiagnostics(page, hostName, secondHostName),
        pageErrorCountDelta: Math.max(0, pageErrors.length - firstActivePageErrorBaseline),
        recentPageErrorCategories: pageErrors.slice(firstActivePageErrorBaseline).slice(-5),
      }));
    }
    assertThat(firstActiveMarkerCreated,
      'input on the selected first tab did not create its remote fixture marker');
    assertThat(firstActiveOutputObserved,
      'selected first terminal did not receive shell output');
    safeRunStage = 'active first SSH terminal stable fingerprint';
    const firstUpdatedFingerprint = await stableTerminalVisualFingerprint(
      page, user, targetAddress, 15000, firstTerminalFingerprint);
    assertThat(firstUpdatedFingerprint !== secondTerminalFingerprint,
      'input on the first tab changed the wrong visible terminal buffer');

    const secondRestoreEvidence = {
      phase: 'before_restore',
      statesBefore: await safeTerminalTabStateDiagnostics(page, hostName, secondHostName),
      firstSocketBefore: safeRelayFrameCounts(firstRelaySocket),
      secondSocketBefore: safeRelayFrameCounts(secondRelaySocket),
      xtermBefore: safeXtermEventCounts(xtermInputDiagnostics),
      targetABefore: sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
      targetBBefore: sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log')),
      pageErrorCountBefore: pageErrors.length,
      connectedIndicatorObserved: false,
      fingerprintCompared: false,
      fingerprintMatchesExpected: null,
    };
    try {
      safeRunStage = 'second SSH terminal tab restore second inactive lookup';
      await (await terminalTabButton(page, secondHostName, 'inactive')).click();
      secondRestoreEvidence.phase = 'second_tab_selected';
      safeRunStage = 'second SSH terminal tab restore active state';
      await terminalTabButton(page, secondHostName, 'active');
      secondRestoreEvidence.phase = 'second_active_confirmed';
      safeRunStage = 'second SSH terminal tab restore first inactive lookup';
      await terminalTabButton(page, hostName, 'inactive');
      secondRestoreEvidence.phase = 'first_inactive_confirmed';
      safeRunStage = 'second SSH terminal tab restore connected indicator';
      await waitText(page, 'CONNECTED');
      secondRestoreEvidence.connectedIndicatorObserved = true;
      secondRestoreEvidence.phase = 'connected_indicator_observed';
      safeRunStage = 'second SSH terminal tab restore stable fingerprint';
      const secondRestoredFingerprint = await stableTerminalVisualFingerprint(
        page, user, targetAddress, 15000, firstUpdatedFingerprint);
      secondRestoreEvidence.fingerprintCompared = true;
      secondRestoreEvidence.fingerprintMatchesExpected =
        secondRestoredFingerprint === secondTerminalFingerprint;
      secondRestoreEvidence.phase = 'fingerprint_compared';
      assertThat(secondRestoreEvidence.fingerprintMatchesExpected,
        'switching tabs displayed the other terminal scrollback');
    } catch (error) {
      const targetAAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const targetBAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'));
      const xtermAfter = safeXtermEventCounts(xtermInputDiagnostics);
      console.log('second SSH terminal tab restoration safe diagnostic', JSON.stringify({
        phase: secondRestoreEvidence.phase,
        statesBefore: secondRestoreEvidence.statesBefore,
        statesAtFailure: await safeTerminalTabStateDiagnostics(page, hostName, secondHostName),
        firstSocketBefore: secondRestoreEvidence.firstSocketBefore,
        firstSocketAtFailure: safeRelayFrameCounts(firstRelaySocket),
        secondSocketBefore: secondRestoreEvidence.secondSocketBefore,
        secondSocketAtFailure: safeRelayFrameCounts(secondRelaySocket),
        xtermEventDelta: safeCounterDelta(secondRestoreEvidence.xtermBefore, xtermAfter,
          Object.keys(secondRestoreEvidence.xtermBefore)),
        targetADelta: safeCounterDelta(secondRestoreEvidence.targetABefore, targetAAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
          'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
          'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
        ]),
        targetBDelta: safeCounterDelta(secondRestoreEvidence.targetBBefore, targetBAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
          'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
          'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
        ]),
        connectedIndicatorObserved: secondRestoreEvidence.connectedIndicatorObserved,
        fingerprintCompared: secondRestoreEvidence.fingerprintCompared,
        fingerprintMatchesExpected: secondRestoreEvidence.fingerprintMatchesExpected,
        pageErrorCountDelta: Math.max(0, pageErrors.length -
          secondRestoreEvidence.pageErrorCountBefore),
        recentPageErrorCategories: pageErrors.slice(
          secondRestoreEvidence.pageErrorCountBefore).slice(-5),
        error: safeErrorSummary(error),
      }));
      throw error;
    }

    safeRunStage = 'first SSH terminal tab active input persistence';
    await (await terminalTabButton(page, hostName, 'inactive')).click();
    await terminalTabButton(page, hostName, 'active');
    await terminalTabButton(page, secondHostName, 'inactive');
    const firstUpdatedRestoredFingerprint = await stableTerminalVisualFingerprint(
      page, user, targetAddress, 15000, secondTerminalFingerprint);
    assertThat(firstUpdatedRestoredFingerprint === firstUpdatedFingerprint,
      'the first terminal did not retain its active-tab output');

    safeRunStage = 'close first SSH terminal tab';
    const closeStartedAt = Date.now();
    let secondAfterCloseFingerprint = null;
    const closeEvidence = {
      phase: 'before_close',
      firstSocketClosedBefore: firstRelaySocket.closed,
      secondSocketClosedBefore: secondRelaySocket.closed,
      statesBefore: null,
      closeControlCountBeforeClick: null,
      closeControlVisible: null,
      closeControlEnabled: null,
      closeClickStarted: false,
      closeClickCompleted: false,
      statesAfterClick: null,
      socketCloseWaitMs: null,
      statesAfterSocketWait: null,
      remainingConnectedTabCount: null,
      survivorFingerprintMatches: null,
    };
    const closePageErrorBaseline = pageErrors.length;
    const closeConsoleErrorBaseline = browserConsoleEvents.length;
    const closeXtermBefore = safeXtermEventCounts(xtermInputDiagnostics);
    const closeTargetABefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
    const closeTargetBBefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'));
    const closeBastionABefore = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    let closeFirstTab;
    try {
      closeEvidence.statesBefore = await safeTerminalTabLifecycleDiagnostics(
        page, hostName, secondHostName);
      closeEvidence.phase = 'activate_surviving_tab';
      await (await terminalTabButton(page, secondHostName, 'inactive')).click();
      await terminalTabButton(page, secondHostName, 'active');
      closeEvidence.phase = 'resolve_close_control';
      closeFirstTab = page.getByRole('button', {
        name: `Close ${hostName}`,
        exact: true,
      });
      closeEvidence.closeControlCountBeforeClick =
        await closeFirstTab.count().catch(() => null);
      closeEvidence.closeControlVisible = await closeFirstTab.isVisible().catch(() => false);
      closeEvidence.closeControlEnabled = await closeFirstTab.isEnabled().catch(() => false);
      await closeFirstTab.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(closeEvidence.closeControlCountBeforeClick === 1 &&
        closeEvidence.closeControlEnabled,
        'first terminal close action was not uniquely available');

      closeEvidence.phase = 'click_close_control';
      closeEvidence.closeClickStarted = true;
      await closeFirstTab.click();
      closeEvidence.closeClickCompleted = true;
      closeEvidence.statesAfterClick = await safeTerminalTabLifecycleDiagnostics(
        page, hostName, secondHostName);

      closeEvidence.phase = 'wait_tab_close_postcondition';
      const socketWaitStartedAt = Date.now();
      const postconditionDeadline = socketWaitStartedAt + 3000;
      let postcondition = null;
      while (Date.now() < postconditionDeadline) {
        const states = await safeTerminalTabLifecycleDiagnostics(
          page, hostName, secondHostName);
        postcondition = {
          firstSocketClosed: Boolean(firstRelaySocket.closed),
          secondSocketOpen: !secondRelaySocket.closed,
          firstTabRemoved: states.firstStates.connected.active === 0 &&
            states.firstStates.connected.inactive === 0 &&
            states.firstStates.connecting.active === 0 &&
            states.firstStates.connecting.inactive === 0 &&
            states.firstStates.disconnected.active === 0 &&
            states.firstStates.disconnected.inactive === 0 &&
            states.firstStates.failed.active === 0 &&
            states.firstStates.failed.inactive === 0,
          secondActive: states.secondActive === 1,
          exactlyOneConnectedTab: states.connectedTabs === 1,
          exactlyOneTab: states.totalTabs === 1,
          totalTabs: states.totalTabs,
          states,
        };
        if (postcondition.firstSocketClosed &&
            postcondition.secondSocketOpen &&
            postcondition.firstTabRemoved &&
            postcondition.secondActive &&
            postcondition.exactlyOneConnectedTab &&
            postcondition.exactlyOneTab) {
          break;
        }
        await page.waitForTimeout(100);
      }
      closeEvidence.socketCloseWaitMs = Date.now() - socketWaitStartedAt;
      closeEvidence.statesAfterSocketWait = await safeTerminalTabLifecycleDiagnostics(
        page, hostName, secondHostName);
      closeEvidence.postcondition = postcondition;
      assertThat(firstRelaySocket.closed && !secondRelaySocket.closed,
        'closing one tab did not close only its Relay socket');
      assertThat(postcondition?.firstTabRemoved && postcondition?.exactlyOneTab,
        'closing the first terminal tab did not remove only that tab');

      closeEvidence.phase = 'verify_remaining_tab';
      await terminalTabButton(page, secondHostName, 'active');
      const remainingTerminalTabs = page.getByRole('button', {
        name: / terminal tab, connected, (?:active|inactive)$/,
      });
      closeEvidence.remainingConnectedTabCount = await remainingTerminalTabs.count();
      assertThat(closeEvidence.remainingConnectedTabCount === 1,
        'closing the first tab did not leave exactly one connected terminal tab');

      closeEvidence.phase = 'verify_survivor_buffer';
      secondAfterCloseFingerprint = await stableTerminalVisualFingerprint(
        page, user, targetAddress, 15000, firstUpdatedFingerprint);
      closeEvidence.survivorFingerprintMatches =
        secondAfterCloseFingerprint === secondTerminalFingerprint;
      assertThat(closeEvidence.survivorFingerprintMatches,
        'closing the first tab changed the surviving terminal buffer');
      closeEvidence.phase = 'complete';
    } catch (error) {
      const count = async (locator) => locator ? locator.count().catch(() => null) : null;
      const visible = async (locator) => locator ? locator.isVisible().catch(() => false) : false;
      const enabled = async (locator) => locator ? locator.isEnabled().catch(() => false) : false;
      const errorClass = ['TimeoutError', 'AssertionError', 'Error'].includes(error?.name)
        ? error.name
        : 'OtherError';
      const closeUiFlags = await page.evaluate(() => {
        const text = document.body.innerText || '';
        const connectedTabPattern = / terminal tab, connected, (?:active|inactive)$/;
        const disconnectedTabPattern = / terminal tab, disconnected, (?:active|inactive)$/;
        const buttons = [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((element) => element.getClientRects().length > 0);
        return {
          connectedTextVisible: text.includes('CONNECTED'),
          disconnectedTextVisible: text.includes('SSH terminal · disconnected'),
          sshErrorTextVisible: /SSH.{0,30}(?:error|closed|failed|timeout)|SSH.{0,30}(?:错误|关闭|失败|超时)/i.test(text),
          visibleConnectedTabCount: buttons.filter((element) =>
            connectedTabPattern.test(element.getAttribute('aria-label') || '')).length,
          visibleDisconnectedTabCount: buttons.filter((element) =>
            disconnectedTabPattern.test(element.getAttribute('aria-label') || '')).length,
          visibleDialogCount: document.querySelectorAll(
            'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
          ).length,
          visibleButtonCount: buttons.length,
        };
      }).catch(() => ({ available: false }));
      const closeTargetAAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd.log'));
      const closeTargetBAfter = sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'));
      const closeBastionAAfter = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
      const closeXtermAfter = safeXtermEventCounts(xtermInputDiagnostics);
      console.log('SSH terminal close safe diagnostic', JSON.stringify({
        phase: closeEvidence.phase,
        errorClass,
        elapsedMs: Date.now() - closeStartedAt,
        ...closeEvidence,
        currentStates: await safeTerminalTabLifecycleDiagnostics(
          page, hostName, secondHostName),
        closeControlCountAtFailure: await count(closeFirstTab),
        closeControlVisible: await visible(closeFirstTab),
        closeControlEnabled: await enabled(closeFirstTab),
        firstSocketOpened: Boolean(firstRelaySocket.opened),
        firstSocketClosed: Boolean(firstRelaySocket.closed),
        secondSocketOpened: Boolean(secondRelaySocket.opened),
        secondSocketClosed: Boolean(secondRelaySocket.closed),
        connectedStatusVisible: await page.getByText('CONNECTED', { exact: true })
          .first().isVisible().catch(() => false),
        uiFlags: closeUiFlags,
        pageErrorsSinceCloseStart: pageErrors.slice(closePageErrorBaseline).slice(-8),
        browserConsoleErrorsSinceCloseStart: browserConsoleEvents
          .slice(closeConsoleErrorBaseline).slice(-8),
        browserRelayCloseMetadata: await safeBrowserRelayCloseMetadata(page)
          .catch(() => []),
        xtermEventDelta: safeCounterDelta(closeXtermBefore, closeXtermAfter,
          Object.keys(closeXtermBefore)),
        targetASshdDelta: safeCounterDelta(closeTargetABefore, closeTargetAAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
          'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
          'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
        ]),
        targetBSshdDelta: safeCounterDelta(closeTargetBBefore, closeTargetBAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
          'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
          'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
        ]),
        bastionASshdDelta: safeCounterDelta(closeBastionABefore, closeBastionAAfter, [
          'tcpConnectionsAccepted', 'connectionsClosed', 'serverSshBannerEmitted',
          'clientSshBannerReceived', 'keyExchangeErrors', 'publicKeyAccepted',
          'publicKeyRejected', 'sessionOpenRequests', 'sessionStarts',
        ]),
      }));
      throw new Error('terminal tab close phase failed');
    }

    safeRunStage = 'surviving SSH terminal input routing';
    const survivingMarker = `WEB_RELAY_TAB_B_SURVIVES_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    const survivingMarkerPath = path.join(secondRemoteRoot, 'terminal-tab-b-survives-marker');
    const survivingRemotePath = '/tmp/remote/terminal-tab-b-survives-marker';
    const survivingCommand = `printf '%s\\n' '${survivingMarker}' > '${survivingRemotePath}'; printf '%s\\n' '${survivingMarker}'; printf '\\033[?25l'`;
    const survivingOutputBaseline = secondRelaySocket.receivedFrames.length;
    const survivingFirstFrameBefore = safeRelayFrameCounts(firstRelaySocket);
    const survivingSecondFrameBefore = safeRelayFrameCounts(secondRelaySocket);
    const survivingXtermBefore = safeXtermEventCounts(xtermInputDiagnostics);
    const survivingTargetBBefore = sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'));
    const survivingFocusBefore = await safePageInputFocusState(page);
    const survivingTabsBefore = await safeTerminalTabStateDiagnostics(page, hostName, secondHostName);
    const survivingPageErrorBaseline = pageErrors.length;
    let survivingCommandDispatched = false;
    let survivingMarkerCreated = false;
    let survivingOutputObserved = false;
    let survivingScrollbackSearchConfirmed = false;
    let survivingSearchRelaySentBaseline = null;
    let survivingSearchRelaySentAfter = null;
    let survivingSearchFrameObserver = null;
    let survivingSearchTextObservedInRelay = false;
    let survivingPageEvents = null;
    await installSafePageInputCounters(page);
    const logSurvivingInputDiagnostic = async (error) => {
      const survivingFirstFrameAfter = safeRelayFrameCounts(firstRelaySocket);
      const survivingSecondFrameAfter = safeRelayFrameCounts(secondRelaySocket);
      const survivingXtermAfter = safeXtermEventCounts(xtermInputDiagnostics);
      const survivingTargetBAfter = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'),
      );
      const pageEvents = survivingPageEvents || await readAndRemoveSafePageInputCounters(page);
      const survivingMarkerSemantics = page.getByText(survivingMarker, { exact: true });
      const survivingMarkerSemanticCount = await survivingMarkerSemantics.count().catch(() => 0);
      const survivingMarkerVisibleCount = await survivingMarkerSemantics.evaluateAll((elements) =>
        elements.filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden' &&
            rect.bottom > 0 && rect.right > 0 &&
            rect.top < window.innerHeight && rect.left < window.innerWidth;
        }).length).catch(() => 0);
      console.log('surviving SSH terminal input safe diagnostic', JSON.stringify({
        phase: safeRunStage,
        error: safeErrorSummary(error),
        commandDispatched: survivingCommandDispatched,
        markerObserved: survivingMarkerCreated,
        outputFrameObserved: survivingOutputObserved,
        scrollbackSearchConfirmed: survivingScrollbackSearchConfirmed,
        searchRelaySentBaseline: survivingSearchRelaySentBaseline,
        searchRelaySentAfter: survivingSearchRelaySentAfter,
        searchRelaySentDelta: survivingSearchRelaySentBaseline === null ||
            survivingSearchRelaySentAfter === null
          ? null
          : survivingSearchRelaySentAfter - survivingSearchRelaySentBaseline,
        syntheticMarkerSemanticCount: survivingMarkerSemanticCount,
        syntheticMarkerVisibleSemanticCount: survivingMarkerVisibleCount,
        markerFilePresent: logFileSummary(survivingMarkerPath).present,
        markerFileBytes: logFileSummary(survivingMarkerPath).bytes ?? null,
        tabsBefore: survivingTabsBefore,
        tabsAtFailure: await safeTerminalTabStateDiagnostics(page, hostName, secondHostName),
        pageBefore: survivingFocusBefore,
        pageAfter: await safePageInputFocusState(page),
        pageEventCounts: pageEvents,
        firstSocket: {
          before: survivingFirstFrameBefore,
          atFailure: survivingFirstFrameAfter,
          delta: {
            sent: safeCounterDelta(survivingFirstFrameBefore.sent,
              survivingFirstFrameAfter.sent, ['total', 'text', 'binary', 'other']),
            received: safeCounterDelta(survivingFirstFrameBefore.received,
              survivingFirstFrameAfter.received, ['total', 'text', 'binary', 'other']),
          },
        },
        secondSocket: {
          before: survivingSecondFrameBefore,
          atFailure: survivingSecondFrameAfter,
          delta: {
            sent: safeCounterDelta(survivingSecondFrameBefore.sent,
              survivingSecondFrameAfter.sent, ['total', 'text', 'binary', 'other']),
            received: safeCounterDelta(survivingSecondFrameBefore.received,
              survivingSecondFrameAfter.received, ['total', 'text', 'binary', 'other']),
          },
        },
        xtermEventDelta: safeCounterDelta(survivingXtermBefore, survivingXtermAfter,
          Object.keys(survivingXtermBefore)),
        targetBSessionDelta: safeCounterDelta(survivingTargetBBefore, survivingTargetBAfter, [
          'tcpConnectionsAccepted', 'serverSshBannerEmitted', 'clientSshBannerReceived',
          'keyExchangeErrors', 'publicKeyAccepted', 'publicKeyRejected',
          'sessionOpenRequests', 'sessionStarts', 'commandSessionStarts',
          'remoteExecFailures', 'shellRequestMentions',
        ]),
        pageErrorCountDelta: Math.max(0, pageErrors.length - survivingPageErrorBaseline),
        recentPageErrorCategories: pageErrors.slice(survivingPageErrorBaseline).slice(-5),
      }));
    };
    try {
      safeRunStage = 'surviving SSH terminal command dispatch';
      await sendCommandToActiveTerminal(page, user, targetAddress, survivingCommand, {
        activeHostName: secondHostName,
      });
      survivingCommandDispatched = true;
      safeRunStage = 'surviving SSH terminal remote marker observation';
      survivingMarkerCreated = await waitForRemoteMarker(survivingMarkerPath, survivingMarker);
      safeRunStage = 'surviving SSH terminal Relay output observation';
      survivingOutputObserved = survivingMarkerCreated &&
        await waitForRelayOutputFrame(page, secondRelaySocket, survivingOutputBaseline);
      survivingPageEvents = await readAndRemoveSafePageInputCounters(page);
      assertThat(survivingMarkerCreated,
        'the remaining active terminal could not create its remote fixture marker');
      assertThat(survivingOutputObserved,
        'the remaining terminal did not receive shell output');
      safeRunStage = 'surviving SSH terminal scrollback search';
      await click(page, 'Search terminal scrollback');
      await page.waitForTimeout(250);
      assertThat(await waitForRelaySocketQuiet(page, secondRelaySocket),
        'the surviving SSH Relay socket did not become quiet after opening terminal search');
      survivingSearchRelaySentBaseline = secondRelaySocket.sentFrames.length;
      const survivingSearchProbe = Buffer.from(survivingMarker, 'utf8');
      let survivingSearchRelayTail = Buffer.alloc(0);
      survivingSearchFrameObserver = ({ payload }) => {
        try {
          const frameBytes = Buffer.isBuffer(payload)
            ? payload : Buffer.from(payload);
          const combined = Buffer.concat([survivingSearchRelayTail, frameBytes]);
          if (combined.includes(survivingSearchProbe)) {
            survivingSearchTextObservedInRelay = true;
          }
          survivingSearchRelayTail = combined.subarray(
            Math.max(0, combined.length - survivingSearchProbe.length + 1),
          );
        } catch (_) {}
      };
      secondRelaySocket.websocketRef.on('framesent', survivingSearchFrameObserver);
      const survivingSearchFields = page.getByRole('textbox', {
        name: /Search.*terminal scrollback/i,
      });
      const survivingSearchFieldCount = await survivingSearchFields.count();
      let survivingSearchField = null;
      for (let index = survivingSearchFieldCount - 1; index >= 0; index -= 1) {
        const candidate = survivingSearchFields.nth(index);
        if (await candidate.isVisible().catch(() => false)) {
          survivingSearchField = candidate;
          break;
        }
      }
      assertThat(survivingSearchField,
        'the surviving terminal scrollback search textbox was not visible');
      const visibleSurvivingSearchFieldCount = await survivingSearchFields
        .evaluateAll((elements) => elements.filter((element) => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        }).length).catch(() => 0);
      assertThat(visibleSurvivingSearchFieldCount === 1,
        'the surviving terminal did not have exactly one visible scrollback search field');
      await survivingSearchField.click({ timeout: 5000 });
      await survivingSearchField.fill(survivingMarker, { timeout: 5000 });
      await page.waitForTimeout(150);
      // Playwright fill updates the DOM value, while Flutter's TextField
      // search controller consumes the corresponding keyboard path. Send the
      // query as actual key input after confirming the semantic field focus.
      await survivingSearchField.press('Control+A', { timeout: 5000 });
      await survivingSearchField.pressSequentially(survivingMarker, {
        delay: 25,
        timeout: 10000,
      });
      await page.waitForTimeout(200);
      const survivingSearchFieldEvidence = await survivingSearchField.evaluate((element, value) => ({
        tagName: element.tagName,
        ariaLabelLength: (element.getAttribute('aria-label') || '').length,
        ariaDescriptionLength: (element.getAttribute('aria-description') || '').length,
        valueLength: typeof element.value === 'string' ? element.value.length : null,
        exactValue: element.value === value,
        focused: document.activeElement === element,
      }), survivingMarker);
      console.log('surviving SSH terminal search field safe evidence', JSON.stringify({
        visibleCandidateCount: visibleSurvivingSearchFieldCount,
        ...survivingSearchFieldEvidence,
      }));
      assertThat(survivingSearchFieldEvidence.exactValue,
        'the surviving terminal scrollback search field did not retain its query');
      const survivingSearchStatusDeadline = Date.now() + 10000;
      let survivingSearchStatusLabels = [];
      let survivingSearchMatchCount = 0;
      while (Date.now() < survivingSearchStatusDeadline &&
          survivingSearchMatchCount === 0) {
        survivingSearchStatusLabels = await page.evaluate(() => {
          const isVisible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 &&
              rect.bottom > 0 && rect.right > 0 &&
              rect.top < window.innerHeight && rect.left < window.innerWidth &&
              style.display !== 'none' && style.visibility !== 'hidden' &&
              Number(style.opacity) !== 0;
          };
          return [...document.querySelectorAll('flt-semantics')]
            .filter(isVisible)
            .map((element) =>
              element.getAttribute('aria-label') || element.innerText || '')
            .flatMap((label) =>
              label.match(/\d+ of \d+ matches|\d+ matches/gi) || []);
        }).catch(() => []);
        for (const status of survivingSearchStatusLabels) {
          const statusMatch = status.match(
            /^\s*1\s+of\s+(\d+)\s+matches(?:\s+·\s+results limited)?\s*$/i,
          );
          if (!statusMatch) continue;
          const reportedMatches = Number(statusMatch[1]);
          if (reportedMatches > survivingSearchMatchCount) {
            survivingSearchMatchCount = reportedMatches;
          }
        }
        if (survivingSearchMatchCount === 0) await page.waitForTimeout(100);
      }
      console.log('surviving SSH terminal search status safe evidence', JSON.stringify({
        visibleStatusLabelCount: survivingSearchStatusLabels.length,
        statusLabels: survivingSearchStatusLabels,
        positiveMatchCount: survivingSearchMatchCount,
      }));
      assertThat(survivingSearchMatchCount > 0,
        'the surviving terminal scrollback search did not find its remote marker');
      assertThat(await waitForRelaySocketQuiet(page, secondRelaySocket),
        'the surviving SSH Relay socket did not become quiet after local terminal search');
      secondRelaySocket.websocketRef.off('framesent', survivingSearchFrameObserver);
      survivingSearchFrameObserver = null;
      survivingSearchRelaySentAfter = secondRelaySocket.sentFrames.length;
      assertThat(!survivingSearchTextObservedInRelay,
        'surviving terminal scrollback search text was sent through SSH Relay');
      survivingScrollbackSearchConfirmed = true;
      await click(page, 'Close terminal search');
      assertThat(!secondRelaySocket.closed,
        'closing surviving terminal search closed the active SSH Relay socket');
      console.log('surviving SSH terminal scrollback search safe evidence', JSON.stringify({
        positiveMatchCount: survivingSearchMatchCount,
        searchRelaySentBaseline: survivingSearchRelaySentBaseline,
        searchRelaySentAfter: survivingSearchRelaySentAfter,
        searchRelaySentDelta:
          survivingSearchRelaySentAfter - survivingSearchRelaySentBaseline,
        searchTextObservedInRelay: survivingSearchTextObservedInRelay,
        socketRemainedOpen: !secondRelaySocket.closed,
      }));
    } catch (error) {
      if (survivingSearchFrameObserver) {
        secondRelaySocket.websocketRef.off('framesent', survivingSearchFrameObserver);
        survivingSearchFrameObserver = null;
      }
      const safeErrorName = ['TimeoutError', 'TargetClosedError', 'Error'].includes(
        error?.name,
      ) ? error.name : 'OtherError';
      process.stderr.write(`surviving SSH terminal raw safe diagnostic ${JSON.stringify({
        phase: safeRunStage,
        errorName: safeErrorName,
        errorCode: terminalFingerprintErrorCode(error, null),
        fingerprintEvidence: terminalFingerprintLatestSafeEvidence,
      })}\n`);
      const screenshotSampleEvidence = safeTerminalFingerprintEvidence(page, error);
      console.log('surviving SSH terminal primary safe diagnostic', JSON.stringify({
        phase: safeRunStage,
        errorCategory: safeErrorSummary(error).category,
        errorCode: terminalFingerprintErrorCode(error, screenshotSampleEvidence),
        screenshotSampleEvidence,
      }));
      try {
        await logSurvivingInputDiagnostic(error);
      } catch (diagnosticError) {
        console.log('surviving SSH terminal detailed diagnostic collector failure',
          JSON.stringify({
            phase: 'surviving_input_diagnostic_collection',
            errorCategory: safeErrorSummary(diagnosticError).category,
          }));
      }
      throw error;
    }
    safeRunStage = 'two isolated SSH terminal summary';
    console.log('stage: two isolated SSH terminal tabs verified', JSON.stringify({
      twoLiveSockets: true,
      distinctBuffers: terminalBuffersDiffer,
      firstTabRestored: firstTerminalRestored,
      secondTabRestored: secondRestoreEvidence.fingerprintMatchesExpected === true,
      activeInputRouted: firstActiveMarkerCreated && survivingMarkerCreated,
      closedTabSocketClosed: firstRelaySocket.closed,
      survivingTabSocketOpen: !secondRelaySocket.closed,
      survivingInputRouted: survivingMarkerCreated,
    }));

    const sftpDirectoryName = `relay-sftp-${RUN_ID.slice(0, 8)}`;
    const sftpFileName = `relay-sftp-${RUN_ID.slice(0, 8)}.bin`;
    const sftpTextFileName = `a-relay-text-${RUN_ID.slice(0, 8)}.txt`;
    const sftpTextOriginal = Buffer.from('初始远端文本：hello 世界', 'utf8');
    const sftpTextSaved = Buffer.from('已保存的更新：café — 東京', 'utf8');
    const sftpTextDraft = Buffer.from('未保存草稿：draft must stay local', 'utf8');
    const sftpTextLatest = Buffer.from('最新远端版本：由另一会话更新', 'utf8');
    const sftpTextSaveAs = Buffer.from('另存为的新 UTF-8 文件：保存成功', 'utf8');
    const sftpTextOverwriteLatest = Buffer.from('确认过的当前远端版本：允许覆盖', 'utf8');
    const sftpTextOverwriteDraft = Buffer.from('用户明确选择覆盖后的内容：saved', 'utf8');
    const sftpFixtureDirectoryName = 'sftp-fixture';
    safeRunStage = 'SFTP fixture directory creation';
    fs.mkdirSync(path.join(secondRemoteRoot, sftpFixtureDirectoryName), { mode: 0o700 });
    safeRunStage = 'SFTP fixture directory ownership';
    fs.chownSync(path.join(secondRemoteRoot, sftpFixtureDirectoryName),
      sshLoginAccount.uid, sshLoginAccount.gid);
    const sftpPayload = crypto.randomBytes(257);
    try {
      safeRunStage = 'isolated OpenSSH SFTP probe';
      const sftpCli = spawnSync(process.env.SFTP_PATH || '/usr/bin/sftp', [
        '-F', '/dev/null', '-b', '-', '-P', String(sshPort2),
        '-i', path.join(tempRoot, 'second_target_client_ecdsa'),
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
        '-o', `User=${user}`, targetAddress,
      ], {
        input: 'pwd\nls /\nquit\n',
        encoding: 'utf8',
        timeout: 8000,
        maxBuffer: 1024 * 1024,
      });
      const sftpCliOutput = `${sftpCli.stdout || ''}\n${sftpCli.stderr || ''}`;
      console.log('stage: isolated OpenSSH SFTP server probe', JSON.stringify({
        exitCode: sftpCli.status,
        timedOut: sftpCli.error?.code === 'ETIMEDOUT',
        rootTmpListed: (sftpCli.stdout || '').includes('/tmp'),
        outputBytes: Buffer.byteLength(sftpCliOutput),
        permissionDenied: /permission denied|access denied/i.test(sftpCliOutput),
        subsystemFailure: /subsystem.{0,24}(failed|error|unavailable)/i.test(sftpCliOutput),
        sanitizedMessage: redactCurrentSecrets(
          sftpCliOutput.replaceAll(tempRoot, '<fixture>').trim().slice(0, 300),
        ),
      }));
      assertThat(sftpCli.status === 0, 'isolated OpenSSH SFTP probe failed');

      safeRunStage = 'SFTP navigation button';
      await click(page, 'SFTP');
      safeRunStage = 'SFTP browser heading';
      await waitText(page, 'SFTP file browser');
      safeRunStage = 'SFTP Go-to-path button';
      await click(page, 'Go to path');
      safeRunStage = 'SFTP Go-to-path dialog';
      await waitText(page, 'Go to remote path');
      const sftpFixturePath = `/tmp/remote/${sftpFixtureDirectoryName}`;
      safeRunStage = 'SFTP remote-path field';
      await fill(page, 'Remote path', sftpFixturePath);
      safeRunStage = 'SFTP Go-to-path submit';
      await click(page, 'Go');
      safeRunStage = 'SFTP path navigation completion';
      safeRunStage = 'SFTP destination path and folder creation';

      await click(page, 'New folder');
      await waitText(page, 'Create remote folder');
      await fill(page, 'Folder name', sftpDirectoryName);
      safeRunStage = 'SFTP folder create submit';
      const createFolderButton = page.getByRole('button', {
        name: 'Create', exact: true,
      }).last();
      await createFolderButton.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(await createFolderButton.isEnabled(),
        'SFTP folder creation form did not enable Create');
      await createFolderButton.click();
      safeRunStage = 'SFTP remote folder mkdir verification';
      const sftpDestination = path.join(secondRemoteRoot, sftpFixtureDirectoryName);
      const sftpRemoteDirectory = path.join(sftpDestination, sftpDirectoryName);
      const sftpRemotePath = `/tmp/remote/${sftpFixtureDirectoryName}/${sftpDirectoryName}`;
      try {
        await waitForFilesystemState(sftpRemoteDirectory, true, 10000);
      } catch (error) {
        const existingNames = fs.readdirSync(secondRemoteRoot, { withFileTypes: true });
        const wrongLocationFolderExists = existingNames.some((entry) =>
          entry.isDirectory() && entry.name === sftpDirectoryName);
        const safeErrorFlags = await page.evaluate(() => {
          const text = [document.body.innerText || '',
            ...[...document.querySelectorAll('flt-semantics')]
              .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)]
            .join('\n').toLowerCase();
          return {
            permissionDenied: text.includes('permission denied'),
            pathNotFound: text.includes('no such file') || text.includes('not found'),
            sftpErrorVisible: text.includes('sftp') &&
              (text.includes('error') || text.includes('failed')),
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        console.log('SFTP folder creation safe evidence', JSON.stringify({
          destinationExists: fs.existsSync(sftpRemoteDirectory),
          parentExists: fs.existsSync(sftpDestination),
          similarlyNamedFolderAtRemoteRoot: wrongLocationFolderExists,
          parentEntriesAreDirectories: existingNames
            .filter((entry) => entry.isDirectory()).length,
          ...safeErrorFlags,
        }));
        throw error;
      }
      const sftpTextFilePath = path.join(sftpRemoteDirectory, sftpTextFileName);
      safeRunStage = 'SFTP local fixture file creation';
      fs.writeFileSync(sftpTextFilePath, sftpTextOriginal, { mode: 0o600 });
      safeRunStage = 'SFTP local fixture ownership setup';
      fs.chownSync(sftpTextFilePath, sshLoginAccount.uid, sshLoginAccount.gid);
      console.log('stage: SFTP path navigation and folder creation verified on isolated sshd',
        JSON.stringify({ createdAtDestination: true }));

      safeRunStage = 'SFTP directory navigation';
      await click(page, 'Go to path');
      await waitText(page, 'Go to remote path');
      await fill(page, 'Remote path', sftpRemotePath);
      await click(page, 'Go');
      console.log('stage: SFTP nested destination selected through the browser path dialog',
        JSON.stringify({ selected: true }));

      safeRunStage = 'SFTP remote text editor UTF-8 save';
      await openSftpEntryAction(page, sftpTextFileName, 'Edit text');
      const editorTitle = page.getByText('Edit remote text file', { exact: true }).last();
      await editorTitle.waitFor({ state: 'visible', timeout: 15000 });
      const remoteTextEditor = page.locator('textarea[aria-label="Remote file contents"]').last();
      await remoteTextEditor.waitFor({ state: 'visible', timeout: 15000 });
      const initialEditorTextMatches =
        await remoteTextEditor.inputValue() === sftpTextOriginal.toString('utf8');
      assertThat(initialEditorTextMatches,
        'remote text editor did not load the UTF-8 fixture content');
      await button(page, 'Save');
      await button(page, 'Save as');
      await button(page, 'Cancel');
      await fill(page, 'Remote file contents', sftpTextSaved.toString('utf8'));
      const editedTextMatches =
        await remoteTextEditor.inputValue() === sftpTextSaved.toString('utf8');
      assertThat(editedTextMatches,
        'remote text editor did not retain the edited UTF-8 content');
      await click(page, 'Save');
      try {
        await waitForFixtureFileBytes(sftpTextFilePath, sftpTextSaved);
      } catch (error) {
        const errorCandidates = await page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
          .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
          .filter((line) => /error|exception|fail|cannot|could not|not support|unsupported|no such|permission|invalid|SFTP|remote file|changed|失败|无法|权限|不支持|异常/i.test(line))
          .slice(-8));
        const messageFlags = await page.evaluate(() => {
          const semanticText = [...document.querySelectorAll('flt-semantics')]
            .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)
            .join('\n');
          const text = `${semanticText}\n${document.body.innerText || ''}`;
          return {
            unsupportedAtomicReplace: /atomic replacement|原子替换|安全的原子/i.test(text),
            permissionFailure: /permission denied|权限不足|没有写入权限/i.test(text),
            remoteVersionConflict: /remote file changed|远端文件已更改/i.test(text),
            invalidTextOrSize: /not valid UTF-8|exceeds the 10 MiB limit|不是有效的 UTF-8|超过 10 MiB/i.test(text),
            unsupportedFileType: /Only regular remote files|不是普通文件/i.test(text),
            genericErrorVisible: /error|exception|失败|无法/i.test(text),
            liveRegionCount: document.querySelectorAll('flt-semantics[aria-live]').length,
          };
        });
        console.log('SFTP text editor save failure diagnostic', JSON.stringify({
          remoteStillOriginal: await fixtureFileMatches(sftpTextFilePath, sftpTextOriginal),
          remoteMatchesDraft: await fixtureFileMatches(sftpTextFilePath, sftpTextSaved),
          stagingFilesRemain: fs.readdirSync(sftpRemoteDirectory)
            .filter((name) => name.includes('.atermius-')).length,
          editorStillOpen: await editorTitle.isVisible().catch(() => false),
          sanitizedVisibleErrors: errorCandidates.map((line) => redactCurrentSecrets(line)
            .replaceAll(tempRoot, '<fixture>')
            .replaceAll(sftpRemotePath, '<remote-fixture>')
            .replaceAll(sftpTextFileName, '<fixture-file>')
            .replaceAll(sftpTextOriginal.toString('utf8'), '<original-text>')
            .replaceAll(sftpTextSaved.toString('utf8'), '<draft-text>')
            .slice(0, 160)),
          messageFlags,
        }));
        throw error;
      }
      await editorTitle.waitFor({ state: 'hidden', timeout: 15000 });
      console.log('stage: SFTP remote text editor UTF-8 save verified against isolated sshd',
        JSON.stringify({ saved: true, utf8BytesMatch: true }));

      safeRunStage = 'SFTP remote text editor stale-save conflict';
      await openSftpEntryAction(page, sftpTextFileName, 'Edit text');
      await editorTitle.waitFor({ state: 'visible', timeout: 15000 });
      await remoteTextEditor.waitFor({ state: 'visible', timeout: 15000 });
      const reloadedTextMatches =
        await remoteTextEditor.inputValue() === sftpTextSaved.toString('utf8');
      assertThat(reloadedTextMatches,
        'remote text editor did not reload the saved UTF-8 content');
      await fill(page, 'Remote file contents', sftpTextDraft.toString('utf8'));
      fs.writeFileSync(sftpTextFilePath, sftpTextLatest, { mode: 0o600 });
      fs.chownSync(sftpTextFilePath, sshLoginAccount.uid, sshLoginAccount.gid);
      await click(page, 'Save');
      const conflictTitle = page.getByText('Remote file changed', { exact: true }).last();
      await conflictTitle.waitFor({ state: 'visible', timeout: 15000 });
      await button(page, 'Compare');
      const conflictSaveAs = page.getByRole('button', { name: 'Save as', exact: true }).last();
      await conflictSaveAs.waitFor({ state: 'visible', timeout: 15000 });
      await button(page, 'Overwrite remote file');
      const cancelActions = page.getByRole('button', { name: 'Cancel', exact: true });
      await cancelActions.last().waitFor({ state: 'visible', timeout: 15000 });
      await click(page, 'Compare');
      await waitForSemanticText(page, 'Original');
      await waitForSemanticText(page, 'Latest remote');
      await waitForSemanticText(page, 'Your draft');
      await button(page, 'Back to conflict');
      const latestComparisonTextFound = await pageSemanticsContainsText(
        page,
        sftpTextLatest.toString('utf8'),
      );
      assertThat(latestComparisonTextFound,
        'remote text comparison did not visibly expose the latest remote text');
      await click(page, 'Back to conflict');
      await conflictTitle.waitFor({ state: 'visible', timeout: 15000 });
      const latestRemainsBeforeChoice = await fixtureFileMatches(sftpTextFilePath, sftpTextLatest);
      assertThat(latestRemainsBeforeChoice,
        'stale Save overwrote remote bytes before an explicit conflict choice');
      await page.getByRole('button', { name: 'Cancel', exact: true }).last().click();
      await conflictTitle.waitFor({ state: 'hidden', timeout: 15000 });
      if (await editorTitle.isVisible().catch(() => false)) {
        await page.getByRole('button', { name: 'Cancel', exact: true }).last().click();
      }
      await editorTitle.waitFor({ state: 'hidden', timeout: 15000 });
      assertThat(await fixtureFileMatches(sftpTextFilePath, sftpTextLatest),
        'cancelling stale-save conflict changed the latest remote bytes');
      console.log('stage: stale remote text edit was blocked until explicit choice',
        JSON.stringify({ conflictShown: true, compareShown: true, latestVisible: true,
          unchangedBeforeChoice: true, cancelKeptLatest: true }));

      safeRunStage = 'SFTP remote text editor Save as success';
      const sftpTextSaveAsFileName = `b-relay-text-saveas-${RUN_ID.slice(0, 8)}.txt`;
      const sftpTextSaveAsPath = path.join(sftpRemoteDirectory, sftpTextSaveAsFileName);
      assertThat(!fs.existsSync(sftpTextSaveAsPath),
        'unique Save as fixture unexpectedly existed before the editor action');
      await openSftpEntryAction(page, sftpTextFileName, 'Edit text');
      await editorTitle.waitFor({ state: 'visible', timeout: 15000 });
      await remoteTextEditor.waitFor({ state: 'visible', timeout: 15000 });
      const saveAsBaselineMatches =
        await remoteTextEditor.inputValue() === sftpTextLatest.toString('utf8');
      assertThat(saveAsBaselineMatches,
        'Save as editor did not load the latest source file bytes');
      await fill(page, 'Remote file contents', sftpTextSaveAs.toString('utf8'));
      assertThat(await remoteTextEditor.inputValue() === sftpTextSaveAs.toString('utf8'),
        'Save as editor did not retain its UTF-8 draft');
      await click(page, 'Save as');
      safeRunStage = 'SFTP Save as prompt title';
      await page.getByText('Save remote file as', { exact: true }).last()
        .waitFor({ state: 'visible', timeout: 15000 });
      safeRunStage = 'SFTP Save as filename field';
      await fill(page, 'File name', sftpTextSaveAsFileName);
      const saveAsFilenameField = await field(page, 'File name');
      const saveAsFilenameFieldMatchesRequested = await saveAsFilenameField
        .inputValue()
        .then((value) => value === sftpTextSaveAsFileName)
        .catch(() => false);
      const readSaveAsUiState = async () => {
        const visible = await page.evaluate(() => {
          const lines = [document.body.innerText || ''];
          for (const element of document.querySelectorAll('flt-semantics')) {
            const text = `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`;
            if (text.trim()) lines.push(text);
          }
          const dialogs = [...document.querySelectorAll(
            'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
          )];
          const editorDialog = dialogs.find((element) =>
            (element.innerText || '').includes('Edit remote text file')) || null;
          const errorNodes = editorDialog
            ? [...editorDialog.querySelectorAll('[aria-live], [role="alert"]')]
            : [];
          if (editorDialog?.matches('[aria-live], [role="alert"]')) {
            errorNodes.push(editorDialog);
          }
          return {
            text: lines.join('\n').slice(-12000),
            dialogCount: dialogs.length,
            editorErrorNodes: errorNodes.map((element) =>
              `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`
                .trim().slice(0, 600)),
          };
        }).catch(() => ({ text: '', dialogCount: null, editorErrorNodes: [] }));
        const text = visible.text || '';
        const liveRegionCandidates = (visible.editorErrorNodes || [])
          .map((candidate) => candidate.trim())
          .filter((candidate) => candidate.length > 0 &&
            /already exists|sftp|permission|denied|invalid|failed|error|exception|closed|失败|错误|无法|权限/i
              .test(candidate));
        const friendlyErrorText = liveRegionCandidates
          .sort((left, right) => left.length - right.length)[0] || '';
        let friendlyErrorCategory = 'none';
        if (/SFTP file already exists|already exists|file exists|已存在/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'sftp_text_file_already_exists';
        } else if (/could not remove staged|temp.*cleanup|cleanup.*failed|清理.*失败/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'sftp_temp_cleanup_failure';
        } else if (/SSH.*session.*closed|session.*closed|SSH 会话已关闭/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'ssh_session_closed';
        } else if (/SftpStatusError|SFTP status/i.test(friendlyErrorText)) {
          if (/permission denied|access denied|权限不足|没有写入权限/i.test(friendlyErrorText)) {
            friendlyErrorCategory = 'sftp_status_permission_denied';
          } else if (/no such file|not found|不存在/i.test(friendlyErrorText)) {
            friendlyErrorCategory = 'sftp_status_no_such_file';
          } else if (/failure|SSH_FX_FAILURE|code 4/i.test(friendlyErrorText)) {
            friendlyErrorCategory = 'sftp_status_failure';
          } else {
            friendlyErrorCategory = 'sftp_status_error_other';
          }
        } else if (/permission denied|access denied|权限不足|没有写入权限/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'permission_denied';
        } else if (/invalid|not a regular file|名称无效|路径无效|不是普通文件/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'invalid_remote_path_or_type';
        } else if (/unsupported|not supported|不支持/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'unsupported_sftp_operation';
        } else if (/failed|error|exception|失败|错误|无法/i.test(friendlyErrorText)) {
          friendlyErrorCategory = 'generic_save_error';
        }
        let errorCategory = 'none';
        if (/already exists|file exists|已存在/i.test(text)) {
          errorCategory = 'remote_target_already_exists';
        } else if (/permission denied|access denied|权限不足|没有写入权限/i.test(text)) {
          errorCategory = 'permission_denied';
        } else if (/remote file changed|远端文件已更改/i.test(text)) {
          errorCategory = 'remote_version_conflict';
        } else if (/invalid (?:file )?name|invalid path|名称无效|路径无效/i.test(text)) {
          errorCategory = 'invalid_remote_name_or_path';
        } else if (/session (?:is )?closed|SSH 会话已关闭/i.test(text)) {
          errorCategory = 'ssh_session_closed';
        } else if (/sftp.*(?:status|failure|unsupported)|(?:status|failure|unsupported).*sftp/i.test(text)) {
          errorCategory = 'sftp_status_or_capability_error';
        } else if (/failed|error|exception|失败|错误|无法/i.test(text)) {
          errorCategory = 'generic_save_error';
        }
        return {
          errorCategory,
          friendlyErrorCategory,
          friendlyErrorNodeFound: Boolean(friendlyErrorText),
          friendlyErrorMentionsRequestedBasename:
            friendlyErrorText.includes(sftpTextSaveAsFileName),
          friendlyErrorMentionsOriginalSourceBasename:
            friendlyErrorText.includes(sftpTextFileName),
          dialogCount: visible.dialogCount,
          saveAsPromptVisible: text.includes('Save remote file as'),
          editorVisible: text.includes('Edit remote text file'),
          sftpBrowserVisible: text.includes('SFTP file browser'),
          errorMentionsRequestedBasename:
            friendlyErrorText.includes(sftpTextSaveAsFileName),
          errorMentionsOriginalSourceBasename:
            friendlyErrorText.includes(sftpTextFileName),
        };
      };
      const saveAsUiBeforeSubmit = await readSaveAsUiState();
      safeRunStage = 'SFTP Save as prompt submit';
      await page.getByRole('button', { name: 'Save as', exact: true }).last().click();
      const saveAsUiImmediatelyAfterSubmit = await readSaveAsUiState();
      safeRunStage = 'SFTP Save as remote bytes check';
      try {
        await waitForFixtureFileBytes(sftpTextSaveAsPath, sftpTextSaveAs);
      } catch (error) {
        let actualBytes;
        let targetEvidence;
        try {
          actualBytes = fs.readFileSync(sftpTextSaveAsPath);
          const actualHash = crypto.createHash('sha256').update(actualBytes).digest();
          const expectedHash = crypto.createHash('sha256').update(sftpTextSaveAs).digest();
          targetEvidence = {
            exists: true,
            byteLength: actualBytes.length,
            expectedByteLength: sftpTextSaveAs.length,
            exactBytes: actualBytes.equals(sftpTextSaveAs),
            contentHashMatchesExpected: actualHash.equals(expectedHash),
          };
          actualHash.fill(0);
          expectedHash.fill(0);
        } catch (_) {
          targetEvidence = { exists: false };
        } finally {
          actualBytes?.fill(0);
        }
        const sourceUnchanged = await fixtureFileMatches(
          sftpTextFilePath,
          sftpTextLatest,
        );
        const hasBasenameUnderRoot = (root, basename, maxEntries = 50000) => {
          const pending = [{ directory: root, depth: 0 }];
          let visited = 0;
          while (pending.length && visited < maxEntries) {
            const current = pending.pop();
            let entries;
            try {
              entries = fs.readdirSync(current.directory, { withFileTypes: true });
            } catch (_) {
              continue;
            }
            for (const entry of entries) {
              visited += 1;
              if (visited >= maxEntries) break;
              if (entry.isFile() && entry.name === basename) return { exists: true, scanComplete: true };
              if (entry.isDirectory() && current.depth < 24) {
                pending.push({
                  directory: path.join(current.directory, entry.name),
                  depth: current.depth + 1,
                });
              }
            }
          }
          return { exists: false, scanComplete: pending.length === 0 || visited < maxEntries };
        };
        const isolatedChrootRoot = path.resolve(secondRemoteRoot, '..', '..');
        const requestedBasenameUnderChroot = hasBasenameUnderRoot(
          isolatedChrootRoot,
          sftpTextSaveAsFileName,
        );
        const originalBasenameUnderChroot = hasBasenameUnderRoot(
          isolatedChrootRoot,
          sftpTextFileName,
        );
        const saveAsUiAfterFailure = await readSaveAsUiState();
        const saveAsUiEvidence = await page.evaluate(() => {
          const text = [document.body.innerText || '',
            ...[...document.querySelectorAll('flt-semantics')]
              .map((element) => `${element.innerText || ''} ${element.getAttribute('aria-label') || ''}`)]
            .join('\n');
          return {
            saveAsPromptVisible: text.includes('Save remote file as'),
            editorVisible: text.includes('Edit remote text file'),
            sftpBrowserVisible: text.includes('SFTP file browser'),
            dialogCount: document.querySelectorAll(
              'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
            ).length,
            permissionDenied: /permission denied|权限不足|没有写入权限/i.test(text),
            pathOrNameRejected: /invalid (?:file )?name|invalid path|名称无效|路径无效/i.test(text),
            versionConflict: /remote file changed|远端文件已更改/i.test(text),
            genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(text),
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        console.log('SFTP Save as byte-check safe evidence', JSON.stringify({
          errorType: error?.name || 'Error',
          targetFilenameIsFixtureSafe: path.basename(sftpTextSaveAsPath) ===
            sftpTextSaveAsFileName && /^[A-Za-z0-9._-]+$/.test(sftpTextSaveAsFileName),
          targetBasenameMatchesRequestedName: path.basename(sftpTextSaveAsPath) ===
            sftpTextSaveAsFileName,
          requestedNameDiffersFromSourceName: sftpTextSaveAsFileName !== sftpTextFileName,
          filenameFieldMatchesRequestedName: saveAsFilenameFieldMatchesRequested,
          actualRemoteNameEvidence: {
            requestedBasenameMentionedByUi: saveAsUiAfterFailure.errorMentionsRequestedBasename,
            sourceBasenameMentionedByUi: saveAsUiAfterFailure.errorMentionsOriginalSourceBasename,
            requestedBasenameFoundUnderIsolatedChroot: requestedBasenameUnderChroot,
            sourceBasenameFoundUnderIsolatedChroot: originalBasenameUnderChroot,
          },
          errorStateComparison: {
            beforeSubmit: saveAsUiBeforeSubmit,
            immediatelyAfterSubmit: saveAsUiImmediatelyAfterSubmit,
            afterByteCheckFailure: saveAsUiAfterFailure,
          },
          target: targetEvidence,
          sourceStillMatchesLatest: sourceUnchanged,
          ui: saveAsUiEvidence,
          recentSftpSignals: sftpDiagnostics.slice(-16),
          browserSftpErrors: browserConsoleEvents.slice(-8),
          targetBSshdDelta: sshdDiagnosticDelta(
            secondTargetSshdBeforeRelay,
            sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log')),
          ),
        }));
        throw error;
      }
      safeRunStage = 'SFTP Save as editor close';
      await editorTitle.waitFor({ state: 'hidden', timeout: 15000 });
      safeRunStage = 'SFTP Save as listing refresh';
      await waitForSemanticText(page, sftpTextSaveAsFileName);
      assertThat(await fixtureFileMatches(sftpTextFilePath, sftpTextLatest),
        'Save as changed the source remote file');
      // Remove the verified Save as target from the fixture and refresh the
      // listing so the remaining row menu in later steps is unambiguous.
      fs.unlinkSync(sftpTextSaveAsPath);
      await click(page, 'Refresh');
      await waitForSemanticText(page, sftpTextSaveAsFileName, false);
      console.log('stage: SFTP Save as created a unique UTF-8 remote file',
        JSON.stringify({ uniqueTargetCreated: true, savedBytesMatch: true, sourceUnchanged: true }));

      safeRunStage = 'SFTP remote text editor explicit overwrite success';
      await openSftpEntryAction(page, sftpTextFileName, 'Edit text');
      await editorTitle.waitFor({ state: 'visible', timeout: 15000 });
      await remoteTextEditor.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(await remoteTextEditor.inputValue() === sftpTextLatest.toString('utf8'),
        'overwrite editor did not load the current source content');
      await fill(page, 'Remote file contents', sftpTextOverwriteDraft.toString('utf8'));
      fs.writeFileSync(sftpTextFilePath, sftpTextOverwriteLatest, { mode: 0o600 });
      fs.chownSync(sftpTextFilePath, sshLoginAccount.uid, sshLoginAccount.gid);
      await click(page, 'Save');
      await conflictTitle.waitFor({ state: 'visible', timeout: 15000 });
      await click(page, 'Compare');
      await waitText(page, 'Latest remote');
      assertThat(await pageSemanticsContainsText(page, sftpTextOverwriteLatest.toString('utf8')),
        'overwrite flow did not show the current remote version for confirmation');
      await click(page, 'Back to conflict');
      await conflictTitle.waitFor({ state: 'visible', timeout: 15000 });
      assertThat(await fixtureFileMatches(sftpTextFilePath, sftpTextOverwriteLatest),
        'remote bytes changed before the explicit overwrite choice');
      await click(page, 'Overwrite remote file');
      await waitForFixtureFileBytes(sftpTextFilePath, sftpTextOverwriteDraft);
      await editorTitle.waitFor({ state: 'hidden', timeout: 15000 });
      console.log('stage: explicit stale-edit overwrite saved after confirming latest remote text',
        JSON.stringify({ latestConfirmedInCompare: true, explicitOverwriteSelected: true,
          overwrittenBytesMatch: true }));

      safeRunStage = 'SFTP remote text editor 10 MiB limit';
      const oversizedTextFileName = `00-relay-oversized-${RUN_ID.slice(0, 8)}.txt`;
      const oversizedTextFilePath = path.join(sftpRemoteDirectory, oversizedTextFileName);
      const oversizedTextFileBytes = 10 * 1024 * 1024 + 1;
      const oversizedDescriptor = fs.openSync(oversizedTextFilePath, 'wx', 0o600);
      try {
        fs.ftruncateSync(oversizedDescriptor, oversizedTextFileBytes);
      } finally {
        fs.closeSync(oversizedDescriptor);
      }
      fs.chownSync(oversizedTextFilePath, sshLoginAccount.uid, sshLoginAccount.gid);
      await click(page, 'Refresh');
      await waitForSemanticText(page, oversizedTextFileName);
      await clickSftpEntryAction(page, oversizedTextFileName, 'Edit text');
      try {
        await waitText(page, '10 MiB limit', 60000);
      } catch (error) {
        const ui = await page.evaluate(() => {
          const text = document.body.innerText || '';
          const semanticText = [...document.querySelectorAll('flt-semantics')]
            .map((element) => [
              element.innerText || '',
              element.getAttribute('aria-label') || '',
            ].join(' ')).join(' ');
          return {
            bodyTextLength: text.length,
            sizeLimitVisible: text.includes('10 MiB limit') ||
              semanticText.includes('10 MiB limit'),
            editorTitleVisible: text.includes('Edit remote text file'),
            sftpBrowserVisible: text.includes('SFTP file browser'),
            errorVisible: /failed|error|exception|失败|错误|无法/i.test(semanticText),
            dialogCount: document.querySelectorAll(
              'flt-semantics[role="dialog"], flt-semantics[role="alertdialog"]',
            ).length,
          };
        }).catch(() => ({ diagnosticUnavailable: true }));
        console.log('SFTP oversized-text rejection safe diagnostics', JSON.stringify({
          errorClass: error?.name || 'error',
          ui,
          recentSftpSignals: sftpDiagnostics.slice(-16),
          targetSshdDelta: sshdDiagnosticDelta(
            sshdBeforeRelay,
            sshdRuntimeSummary(path.join(tempRoot, 'sshd.log')),
          ),
          bastionSshdDelta: sshdDiagnosticDelta(
            jumpSshdBeforeRelay,
            sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log')),
          ),
        }));
        throw error;
      }
      assertThat(fs.statSync(oversizedTextFilePath).size === oversizedTextFileBytes,
        'oversized text editor rejection changed the remote fixture size');
      console.log('stage: oversized remote text file was rejected with the visible size limit',
        JSON.stringify({ rejected: true, limitMessageVisible: true, fixtureSizePreserved: true }));

      safeRunStage = 'SFTP synthetic file selection';
      let chooser;
      let chooserPromise;
      let setFilesAttempted = false;
      let chooserElementDetails;
      try {
        await installFilePickerProbe(page);
        chooserPromise = page.waitForEvent('filechooser', { timeout: 15000 });
        await click(page, 'Upload');
        chooser = await chooserPromise;
        chooserElementDetails = await fileChooserElementSummary(chooser, page);
        setFilesAttempted = true;
        await chooser.setFiles({
          name: sftpFileName,
          mimeType: 'application/octet-stream',
          buffer: sftpPayload,
        });
        await page.waitForTimeout(300);
      } catch (error) {
        if (chooserPromise) await chooserPromise.catch(() => {});
        const diagnostic = await filePickerProbeSummary(page).catch(() => null);
        console.log('SFTP file picker diagnostic', JSON.stringify({
          chooserObserved: Boolean(chooser),
          setFilesAttempted,
          chooserElement: chooserElementDetails || null,
          errorClass: error?.name || 'Error',
          probe: diagnostic,
        }));
        throw error;
      }
      const fileSelectionProbe = await filePickerProbeSummary(page).catch(() => null);
      const sftpRemoteFile = path.join(sftpRemoteDirectory, sftpFileName);
      try {
        safeRunStage = 'SFTP browser upload transfer';
        await waitForFilesystemState(sftpRemoteFile, true, 30000);
        const uploadedPayload = fs.readFileSync(sftpRemoteFile);
        let uploadedBytesMatch;
        try {
          uploadedBytesMatch = uploadedPayload.equals(sftpPayload);
        } finally {
          uploadedPayload.fill(0);
        }
        assertThat(uploadedBytesMatch, 'SFTP uploaded bytes did not match the selected synthetic file');
        console.log('stage: SFTP synthetic upload bytes verified on isolated sshd',
          JSON.stringify({ uploaded: true, bytesMatch: uploadedBytesMatch, bytes: sftpPayload.length }));
      } catch (error) {
        const remoteFileExists = fs.existsSync(sftpRemoteFile);
        const hasFileNamedInTree = (root, fileName, depth = 0) => {
          if (depth > 5) return false;
          let entries;
          try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_) { return false; }
          for (const entry of entries) {
            const candidate = path.join(root, entry.name);
            if (entry.isFile() && entry.name === fileName) return true;
            if (entry.isDirectory() && hasFileNamedInTree(candidate, fileName, depth + 1)) return true;
          }
          return false;
        };
        let remoteFileBytes = null;
        if (remoteFileExists) {
          try { remoteFileBytes = fs.statSync(sftpRemoteFile).size; } catch (_) {}
        }
        const visibleUiText = await page.evaluate(() => document.body.innerText || '').catch(() => '');
        console.log('SFTP browser upload diagnostic', JSON.stringify({
          errorClass: error?.name || 'Error',
          remoteFileExists,
          remoteFileBytes,
          remoteDirectoryEntryCount: fs.readdirSync(sftpRemoteDirectory).length,
          fileFoundUnderRemoteRoot: hasFileNamedInTree(secondRemoteRoot, sftpFileName),
          fileFoundUnderJailRoot: hasFileNamedInTree(jailRoot, sftpFileName),
          fileInputsAdded: fileSelectionProbe?.fileInputsAdded ?? null,
          fileInputClicks: fileSelectionProbe?.fileInputClicks ?? [],
          fileInputEvents: fileSelectionProbe?.fileInputEvents ?? [],
          documentObservedFileInputChange: fileSelectionProbe?.documentObservedFileInputChange ?? false,
          pageErrorCategoryTail: pageErrors.slice(-8),
          errorOrUnsupportedMessageVisible: /(?:error|failed|unsupported|denied|不支持|失败|错误|权限)/i.test(visibleUiText),
          selectedNameAppearedInUi: visibleUiText.includes(sftpFileName),
        }));
        throw error;
      }

      safeRunStage = 'SFTP browser download';
      const downloadPromise = waitForBrowserDownload(context, page, 30000);
      try {
        await clickSftpEntryAction(page, sftpFileName, 'Download');
        await downloadPromise;
      } catch (error) {
        const diagnostics = await browserDownloadProbeSummary(page).catch(() => null);
        console.log('stage: SFTP download trigger diagnostics', JSON.stringify(diagnostics));
        throw error;
      }
      const download = await downloadPromise;
      assertThat(download.suggestedFilename() === sftpFileName,
        'SFTP download filename did not match the selected synthetic file');
      const downloadedPath = path.join(tempRoot, 'sftp-download.bin');
      await download.saveAs(downloadedPath);
      const downloadedPayload = fs.readFileSync(downloadedPath);
      let downloadedBytesMatch;
      try {
        downloadedBytesMatch = downloadedPayload.equals(sftpPayload);
      } finally {
        downloadedPayload.fill(0);
      }
      assertThat(downloadedBytesMatch, 'SFTP downloaded bytes did not match the synthetic upload');
      console.log('stage: SFTP browser download bytes verified',
        JSON.stringify({ bytes: sftpPayload.length, bytesMatch: downloadedBytesMatch }));

      safeRunStage = 'SFTP remote file deletion';
      let sftpDeletePhase = 'open_row_action';
      const sftpDeleteSocketBefore = safeRelayFrameCounts(secondRelaySocket);
      const sftpDeleteTargetBefore = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'),
      );
      try {
        await clickSftpEntryAction(page, sftpFileName, 'Delete');
        sftpDeletePhase = 'confirmation_prompt';
        await waitText(page, 'Delete this item?');
        const confirmDelete = page.getByRole('button', { name: 'Delete', exact: true }).last();
        sftpDeletePhase = 'confirmation_button';
        await confirmDelete.waitFor({ state: 'visible', timeout: 15000 });
        sftpDeletePhase = 'confirm_delete_click';
        await confirmDelete.click();
        sftpDeletePhase = 'remote_absence';
        await waitForFilesystemState(sftpRemoteFile, false, 15000);
      } catch (error) {
        const sftpDeleteUi = await page.evaluate(() => {
          const text = document.body.innerText || '';
          const semantics = [...document.querySelectorAll('flt-semantics')];
          const visible = (element) => element.getClientRects().length > 0;
          const visibleButtons = semantics.filter((element) =>
            element.getAttribute('role') === 'button' && visible(element));
          const visibleDialogs = semantics.filter((element) =>
            ['dialog', 'alertdialog'].includes(element.getAttribute('role')) && visible(element));
          const hasExactAction = (action) => visibleButtons.some((element) =>
            (element.getAttribute('aria-label') || element.innerText || '').trim() === action);
          return {
            sftpBrowserVisible: text.includes('SFTP file browser'),
            deletePromptVisible: text.includes('Delete this item?'),
            genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(text),
            deletedStatusVisible: /deleted|removed|已删除/i.test(text),
            visibleDialogCount: visibleDialogs.length,
            visibleButtonCount: visibleButtons.length,
            exactDeleteActionVisible: hasExactAction('Delete'),
            exactCancelActionVisible: hasExactAction('Cancel'),
          };
        }).catch(() => ({ available: false }));
        const sftpDeleteSocketAfter = safeRelayFrameCounts(secondRelaySocket);
        const sftpDeleteTargetAfter = sshdRuntimeSummary(
          path.join(tempRoot, 'sshd-target-b.log'),
        );
        console.log('SFTP deletion safe diagnostic', JSON.stringify({
          phase: sftpDeletePhase,
          error: safeErrorSummary(error),
          remoteFile: logFileSummary(sftpRemoteFile),
          ui: sftpDeleteUi,
          relaySocketDelta: {
            sent: safeCounterDelta(sftpDeleteSocketBefore.sent,
              sftpDeleteSocketAfter.sent, ['total', 'text', 'binary', 'other']),
            received: safeCounterDelta(sftpDeleteSocketBefore.received,
              sftpDeleteSocketAfter.received, ['total', 'text', 'binary', 'other']),
          },
          targetBSshdDelta: safeCounterDelta(sftpDeleteTargetBefore, sftpDeleteTargetAfter, [
            'tcpConnectionsAccepted', 'publicKeyAccepted', 'publicKeyRejected',
            'sessionOpenRequests', 'sessionStarts', 'sftpSubsystemRequests',
            'sftpSubsystemStarts', 'sftpSubsystemErrors',
          ]),
          recentSftpSignals: sftpDiagnostics.slice(-16),
        }));
        throw error;
      }
      console.log('stage: SFTP delete verified against isolated sshd state',
        JSON.stringify({ deleted: true, absentFromRemote: true }));

      safeRunStage = 'SFTP parent directory navigation';
      await click(page, 'Up one directory');
      await click(page, 'New folder');
      await waitText(page, 'Create remote folder');
      const parentCheckFolderName = `${sftpDirectoryName}-parent-check`;
      const parentCheckFolderPath = path.join(sftpDestination, parentCheckFolderName);
      await fill(page, 'Folder name', `${sftpDirectoryName}-parent-check`);
      const parentCreateButton = page.getByRole('button', {
        name: 'Create', exact: true,
      }).last();
      safeRunStage = 'SFTP parent folder create submit readiness';
      await parentCreateButton.waitFor({ state: 'visible', timeout: 15000 });
      const parentCreateEnabled = await parentCreateButton.isEnabled().catch(() => false);
      assertThat(parentCreateEnabled,
        'SFTP parent folder creation form did not enable Create');
      const parentFolderTargetBefore = sshdRuntimeSummary(
        path.join(tempRoot, 'sshd-target-b.log'),
      );
      safeRunStage = 'SFTP parent folder create submit';
      try {
        await parentCreateButton.click();
      } catch (error) {
        const ui = await page.evaluate((folderName) => {
          const body = document.body.innerText || '';
          const visible = (element) => element.getClientRects().length > 0;
          const semantics = [...document.querySelectorAll('flt-semantics')];
          const buttons = semantics.filter((element) =>
            element.getAttribute('role') === 'button' && visible(element));
          return {
            createDialogVisible: body.includes('Create remote folder'),
            expectedEntryVisible: body.includes(folderName),
            genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(body),
            permissionErrorVisible: /permission denied|权限不足|没有写入权限/i.test(body),
            existingEntryErrorVisible: /already exists|已存在/i.test(body),
            visibleDialogCount: semantics.filter((element) =>
              ['dialog', 'alertdialog'].includes(element.getAttribute('role')) &&
              visible(element)).length,
            exactCreateButtonVisible: buttons.some((element) =>
              (element.getAttribute('aria-label') || element.innerText || '').trim() === 'Create'),
          };
        }, parentCheckFolderName).catch(() => ({ available: false }));
        console.log('SFTP parent folder submit safe diagnostic', JSON.stringify({
          error: safeErrorSummary(error),
          createButtonEnabledBeforeClick: parentCreateEnabled,
          ui,
          expectedEntryExists: fs.existsSync(parentCheckFolderPath),
          parentDirectoryExists: fs.existsSync(sftpDestination),
          targetBSshdDelta: sshdDiagnosticDelta(parentFolderTargetBefore,
            sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'))),
          recentSftpSignals: sftpDiagnostics.slice(-16),
        }));
        throw error;
      }
      safeRunStage = 'SFTP parent folder mkdir verification';
      try {
        await waitForFilesystemState(parentCheckFolderPath, true, 10000);
      } catch (error) {
        const ui = await page.evaluate((folderName) => {
          const body = document.body.innerText || '';
          const visible = (element) => element.getClientRects().length > 0;
          const semantics = [...document.querySelectorAll('flt-semantics')];
          const buttons = semantics.filter((element) =>
            element.getAttribute('role') === 'button' && visible(element));
          return {
            createDialogVisible: body.includes('Create remote folder'),
            expectedEntryVisible: body.includes(folderName),
            genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(body),
            permissionErrorVisible: /permission denied|权限不足|没有写入权限/i.test(body),
            existingEntryErrorVisible: /already exists|已存在/i.test(body),
            visibleDialogCount: semantics.filter((element) =>
              ['dialog', 'alertdialog'].includes(element.getAttribute('role')) &&
              visible(element)).length,
            exactCreateButtonVisible: buttons.some((element) =>
              (element.getAttribute('aria-label') || element.innerText || '').trim() === 'Create'),
          };
        }, parentCheckFolderName).catch(() => ({ available: false }));
        const parentDirectoryEntries = (() => {
          try { return fs.readdirSync(sftpDestination, { withFileTypes: true }); }
          catch (_) { return null; }
        })();
        const expectedEntry = parentDirectoryEntries?.find((entry) =>
          entry.name === parentCheckFolderName);
        console.log('SFTP parent folder mkdir safe diagnostic', JSON.stringify({
          error: safeErrorSummary(error),
          createButtonEnabledBeforeClick: parentCreateEnabled,
          ui,
          filesystem: {
            parentDirectoryExists: parentDirectoryEntries !== null,
            parentEntryCount: parentDirectoryEntries?.length ?? null,
            expectedEntryExists: Boolean(expectedEntry),
            expectedEntryIsDirectory: expectedEntry?.isDirectory() ?? false,
            expectedEntryCount: parentDirectoryEntries
              ? parentDirectoryEntries.filter((entry) =>
                entry.name === parentCheckFolderName).length
              : null,
          },
          targetBSshdDelta: sshdDiagnosticDelta(parentFolderTargetBefore,
            sshdRuntimeSummary(path.join(tempRoot, 'sshd-target-b.log'))),
          recentSftpSignals: sftpDiagnostics.slice(-16),
        }));
        throw error;
      }
      console.log('stage: SFTP parent navigation verified',
        JSON.stringify({ returnedToParent: true }));
    } finally {
      sftpPayload.fill(0);
      sftpTextOriginal.fill(0);
      sftpTextSaved.fill(0);
      sftpTextDraft.fill(0);
      sftpTextLatest.fill(0);
      sftpTextSaveAs.fill(0);
      sftpTextOverwriteLatest.fill(0);
      sftpTextOverwriteDraft.fill(0);
    }

    await click(page, 'Terminal');
    await waitText(page, 'CONNECTED', 15000);

    safeRunStage = 'relay WebSocket disconnect: click';
    assertThat(!secondRelaySocket.closed,
      'surviving terminal Relay socket closed before the disconnect action');
    await click(page, 'Disconnect');
    safeRunStage = 'relay WebSocket disconnect: wait for disconnected UI';
    await waitText(page, 'SSH terminal · disconnected');
    safeRunStage = 'relay WebSocket disconnect: wait for transport close';
    const closeDeadline = Date.now() + 5000;
    while (Date.now() < closeDeadline && !secondRelaySocket.closed) {
      await page.waitForTimeout(100);
    }
    assertThat(secondRelaySocket.opened && secondRelaySocket.closed && firstRelaySocket.closed,
      'Disconnect did not close the surviving terminal Relay socket');
    console.log('stage: UI disconnect closed the Relay WebSocket');

    await stopGroup(sshdProcess);
    sshdProcess = null;
    const changedTargetHostKey = path.join(tempRoot, 'target_host_changed');
    run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedTargetHostKey], { timeout: 30000 });
    fs.chmodSync(changedTargetHostKey, 0o600);
    assertThat(fs.readFileSync(`${changedTargetHostKey}.pub`, 'utf8').trim() !==
      fs.readFileSync(`${initialHostKey}.pub`, 'utf8').trim(),
    'target host-key rotation fixture did not generate a changed key');
    const changedTargetConfig = writeSshdConfig({
      tempRoot, address: targetAddress, port: sshPort, hostKey: changedTargetHostKey,
      configName: 'sshd-target-changed',
      authorizedKeys: authorizedKeysPath, user, jailRoot,
    });
    sshdProcess = startSshd(changedTargetConfig, tempRoot);
    await waitForPort(targetAddress, sshPort, sshdProcess);

    await click(page, 'Hosts');
    const changedHostCard = page.getByRole('group', {
      name: new RegExp(hostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
    }).first();
    const targetChangedTicketBaseline = relayTicketTargetChecks.length;
    await changedHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
    await waitText(page, 'SSH 主机密钥与已保存指纹不同，连接已拒绝', 20000);
    assertThat(!(await page.getByText('CONNECTED', { exact: true }).count()),
      'client connected after the target SSH host key changed');
    const targetChangedTicketAttempts = relayTicketTargetChecks.slice(
      targetChangedTicketBaseline,
    );
    assertThat(targetChangedTicketAttempts.length ===
        relayAttemptsThroughRejectedHop(1) && targetChangedTicketAttempts.every(Boolean),
    'target host-key rejection did not keep both first-hop Relay attempts on the bastion');
    console.log('stage: changed target SSH host key was rejected against its saved fingerprint');

    await stopGroup(sshdProcess);
    sshdProcess = startSshd(configPath, tempRoot);
    await waitForPort(targetAddress, sshPort, sshdProcess);
    await stopGroup(jumpSshdProcess);
    jumpSshdProcess = null;
    const changedBastionHostKey = path.join(tempRoot, 'bastion_host_changed');
    run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedBastionHostKey], { timeout: 30000 });
    fs.chmodSync(changedBastionHostKey, 0o600);
    assertThat(fs.readFileSync(`${changedBastionHostKey}.pub`, 'utf8').trim() !==
      fs.readFileSync(`${jumpHostKey}.pub`, 'utf8').trim(),
    'bastion host-key rotation fixture did not generate a changed key');
    const changedBastionConfig = writeSshdConfig({
      tempRoot,
      address,
      port: bastionPort,
      hostKey: changedBastionHostKey,
      authorizedKeys: jumpAuthorizedKeysPath,
      user,
      jailRoot,
      instance: 'jump-sshd',
      configName: 'jump-sshd-changed',
      allowTcpForwarding: 'local',
      permitOpen: [
        `${targetAddress}:${sshPort}`,
        `${targetAddress}:${sshPort2}`,
      ],
    });
    jumpSshdProcess = startSshd(changedBastionConfig, tempRoot, 'jump-sshd');
    await waitForPort(address, bastionPort, jumpSshdProcess);
    await click(page, 'Hosts');
    const bastionChangedTicketBaseline = relayTicketTargetChecks.length;
    await changedHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
    await waitText(page, 'SSH 主机密钥与已保存指纹不同，连接已拒绝', 20000);
    assertThat(!(await page.getByText('CONNECTED', { exact: true }).count()),
      'client connected after the bastion SSH host key changed');
    const bastionChangedTicketAttempts = relayTicketTargetChecks.slice(
      bastionChangedTicketBaseline,
    );
    assertThat(bastionChangedTicketAttempts.length ===
        relayAttemptsThroughRejectedHop(0) && bastionChangedTicketAttempts.every(Boolean),
    'bastion host-key rejection did not target its initial Relay ticket at Bastion A');
    assertThat(relayTicketTargetChecks.length > 0 && relayTicketTargetChecks.every(Boolean),
      'one or more Relay tickets targeted the loopback target instead of the bastion');
    console.log('stage: changed bastion SSH host key was independently rejected; all Relay tickets targeted only bastion');

    safeRunStage = 'restore Bastion A before the two-hop acceptance';
    await stopGroup(jumpSshdProcess);
    jumpSshdProcess = null;
    jumpSshdProcess = startSshd(jumpConfigPath, tempRoot, 'jump-sshd');
    await waitForPort(address, bastionPort, jumpSshdProcess);

    safeRunStage = 'close prior Profile A terminal tabs before the isolated two-hop route';
    await click(page, 'Terminal');
    const closePriorTerminalTabButtons = page.getByRole('button', {
      name: /^Close .+$/,
    });
    for (let attempt = 0; attempt < 8; attempt++) {
      const closeCount = await closePriorTerminalTabButtons.count();
      if (closeCount === 0) break;
      await closePriorTerminalTabButtons.first().click();
      const closeDeadline = Date.now() + 5000;
      while (Date.now() < closeDeadline &&
          await closePriorTerminalTabButtons.count() >= closeCount) {
        await page.waitForTimeout(50);
      }
      assertThat(await closePriorTerminalTabButtons.count() < closeCount,
        'a prior Profile A terminal tab did not close before the two-hop route');
    }
    const priorTerminalTabCount = await closePriorTerminalTabButtons.count();
    const priorActiveProfileASocketCount = relaySocketsForPage(page)
      .filter((socket) => socket.opened && !socket.closed).length;
    assertThat(priorTerminalTabCount === 0 && priorActiveProfileASocketCount === 0,
      'Profile A still had a terminal tab or active Relay WebSocket before the two-hop route');
    console.log('stage: prior Profile A terminal tabs and Relay sockets closed before the isolated two-hop route',
      JSON.stringify({ priorTerminalTabCount, priorActiveProfileASocketCount }));

    safeRunStage = 'two-hop route preflight through Bastion A and Bastion B';
    const multiHopPageTicketChecks = relayTicketChecksForPage(page);
    const multiHopPageSockets = relaySocketsForPage(page);
    const multiHopRelayTicketBaseline = multiHopPageTicketChecks.length;
    const multiHopRelaySocketBaseline = multiHopPageSockets.length;
    const multiHopProfileBSnapshot = snapshotRelayPage(secondPage);
    assertThat(multiHopProfileBSnapshot.openSockets.length > 0,
      'profile B must have an active Relay WebSocket before profile A starts the two-hop route');
    // The cross-profile isolation baseline intentionally contains Profile B's
    // already-connected route. Profile A was asserted empty immediately
    // above, so disconnect must leave Profile A empty while preserving B.
    const multiHopPreexistingOpenRelaySockets = relaySockets.filter(
      (socket) => socket.opened && !socket.closed,
    );
    const multiHopConnectedTabBaseline = await page.getByRole('button', {
      name: / terminal tab, connected, (?:active|inactive)$/,
    }).count();
    const multiHopActiveConnectedTabBaseline = await page.getByRole('button', {
      name: / terminal tab, connected, active$/,
    }).count();
    const multiHopAAuthBefore = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    const multiHopBAuthBefore = sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log'));
    const multiHopTargetAuthBefore = sshdRuntimeSummary(
      path.join(tempRoot, 'sshd-multihop-target.log'),
    );
    const multiHopApiEventBaseline = apiEvents.length;
    const multiHopApiRequestBaseline = apiRequests.length;
    safeRunStage = 'two-hop route open Hosts';
    await click(page, 'Hosts');
    const multiHopTotalTabCountBefore = await page.getByRole('button', {
      name: / terminal tab, (?:connecting|connected|disconnected|failed), (?:active|inactive)$/,
    }).count().catch(() => null);
    const multiHopRouteCardBefore = await page.evaluate((expectedJumpName) => {
      const visible = (element) => element.getClientRects().length > 0;
      const groups = [...document.querySelectorAll('flt-semantics[role="group"]')]
        .filter(visible)
        .map((element) => `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`);
      const expectedRouteLabel = `Via Jump Host: ${expectedJumpName}`;
      return {
        routeCardCount: groups.filter((label) => label.includes(expectedJumpName)).length,
        expectedJumpHostLabelVisible: groups.some((label) => label.includes(expectedRouteLabel)),
      };
    }, secondBastionHostName).catch(() => ({ available: false }));
    console.log('two-hop route pre-connect safe evidence', JSON.stringify({
      totalTerminalTabCount: multiHopTotalTabCountBefore,
      hostCard: multiHopRouteCardBefore,
      connectButtonCount: await multiHopHostCard.getByRole('button', {
        name: 'Connect', exact: true,
      }).count().catch(() => null),
      connectButtonVisible: await multiHopHostCard.getByRole('button', {
        name: 'Connect', exact: true,
      }).isVisible().catch(() => false),
      connectButtonEnabled: await multiHopHostCard.getByRole('button', {
        name: 'Connect', exact: true,
      }).isEnabled().catch(() => false),
    }));
    safeRunStage = 'two-hop route Connect action';
    await multiHopHostCard.getByRole('button', { name: 'Connect', exact: true }).click();
    let multiHopTrustSignal = null;
    let multiHopTrustPrompts = 0;
    while (multiHopTrustPrompts < 3) {
      safeRunStage = 'two-hop route wait for SSH trust or connection state';
      multiHopTrustSignal = await waitForSshTrustOrError(page, 60000, multiHopHostName);
      if (multiHopTrustSignal !== 'host_key_prompt') break;
      const promptToken = await sshTrustPromptToken(page);
      safeRunStage = 'two-hop route accept verified SSH host key';
      await click(page, 'Trust after verification');
      multiHopTrustPrompts += 1;
      safeRunStage = 'two-hop route wait for SSH trust prompt transition';
      await waitForSshTrustPromptAdvance(page, promptToken, 60000);
    }
    const multiHopAuthAtTrustDecision = {
      bastionA: sshdDiagnosticDelta(multiHopAAuthBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'))),
      bastionB: sshdDiagnosticDelta(multiHopBAuthBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log'))),
      target: sshdDiagnosticDelta(multiHopTargetAuthBefore,
        sshdRuntimeSummary(path.join(tempRoot, 'sshd-multihop-target.log'))),
    };
    console.log('two-hop SSH trust progression safe evidence', JSON.stringify({
      trustPrompts: multiHopTrustPrompts,
      trustSignal: multiHopTrustSignal,
      relayTicketDelta: multiHopPageTicketChecks.length - multiHopRelayTicketBaseline,
      relaySocketDelta: multiHopPageSockets.length - multiHopRelaySocketBaseline,
      hopAuthenticationDeltas: multiHopAuthAtTrustDecision,
    }));
    const multiHopUiEvidence = await page.evaluate((hostName) => {
      const visible = (element) => element.getClientRects().length > 0;
      const semantics = [...document.querySelectorAll('flt-semantics')].filter(visible);
      const labels = semantics.map((element) =>
        `${element.getAttribute('aria-label') || ''} ${element.innerText || ''}`.trim());
      const terminalTabLabels = semantics
        .filter((element) => element.getAttribute('role') === 'button')
        .map((element) => element.getAttribute('aria-label') || element.innerText || '')
        .filter((label) => / terminal tab, (?:connecting|connected|failed|disconnected), (?:active|inactive)$/.test(label));
      const routeTabPrefix = `${hostName} terminal tab, `;
      const routeTabLabels = labels.filter((label) => label.startsWith(routeTabPrefix));
      const body = document.body.innerText || '';
      const semanticText = labels.join('\n');
      const visibleText = `${body}\n${semanticText}`;
      return {
        totalTerminalTabCount: new Set(terminalTabLabels).size,
        terminalTabStateCounts: Object.fromEntries(
          ['connecting', 'connected', 'failed', 'disconnected'].map((state) => [
            state,
            new Set(terminalTabLabels.filter((label) =>
              label.includes(` terminal tab, ${state},`))).size,
          ]),
        ),
        routeTerminalTabCounts: Object.fromEntries(
          ['connecting', 'connected', 'failed', 'disconnected'].map((state) => [
            state,
            routeTabLabels.filter((label) => label.includes(`terminal tab, ${state},`)).length,
          ]),
        ),
        terminalCapacityWarningVisible: /最多同时打开\s*\d+\s*个 SSH 终端标签/.test(visibleText),
        jumpRouteResolutionErrorVisible: /Jump Host.*(?:无法解析|已不存在|循环|超过)/.test(visibleText),
        routeSnapshotChangedErrorVisible: /主机或 Jump Host 路由在连接准备期间发生变化|Jump Host 路由在连接准备期间发生变化/.test(visibleText),
        credentialResolutionErrorVisible: /SSH 凭据.*无法解析|凭据在连接准备期间发生变化/.test(visibleText),
        knownHostErrorVisible: /SSH 主机密钥|SSH host key/i.test(visibleText),
        relayErrorVisible: /SSH 中继|Relay WebSocket|Relay ticket/i.test(visibleText),
        genericErrorVisible: /failed|error|exception|失败|错误|无法/i.test(visibleText),
        visibleDialogCount: semantics.filter((element) =>
          ['dialog', 'alertdialog'].includes(element.getAttribute('role'))).length,
      };
    }, multiHopHostName).catch(() => ({ available: false }));
    const multiHopConnectButton = multiHopHostCard.getByRole('button', {
      name: 'Connect', exact: true,
    });
    const multiHopConnectControlEvidence = {
      count: await multiHopConnectButton.count().catch(() => 0),
      visible: await multiHopConnectButton.isVisible().catch(() => false),
      enabled: await multiHopConnectButton.isEnabled().catch(() => false),
    };
    console.log('two-hop route UI and request safe evidence', JSON.stringify({
      ui: multiHopUiEvidence,
      connectControl: multiHopConnectControlEvidence,
      apiRequests: apiRequests.slice(multiHopApiRequestBaseline)
        .map(({ path: route, method, completed, status }) => ({ route, method, completed, status })),
      apiResponses: apiEvents.slice(multiHopApiEventBaseline)
        .map(({ path: route, status, errorCode }) => ({ route, status, errorCode })),
      browserPageErrorCount: pageErrors.length,
      browserConsoleErrorCount: browserConsoleEvents.length,
      failedRequestCount: requestFailures.length,
    }));
    safeRunStage = 'two-hop route trust prompt count assertion';
    assertThat(multiHopTrustPrompts === 2,
      `two-hop route should request first-use trust for Bastion B and Target only (${multiHopTrustPrompts})`);
    safeRunStage = 'two-hop route wait for CONNECTED';
    safeRunStage = 'two-hop route connection state assertion';
    assertThat(multiHopTrustSignal === 'terminal_connected',
      `two-hop route did not reach its connected terminal state (${multiHopTrustSignal})`);
    safeRunStage = 'two-hop route wait for CONNECTED';
    await waitText(page, 'CONNECTED', 45000);
    safeRunStage = 'two-hop route select active terminal tab';
    await terminalTabButton(page, multiHopHostName, 'active');
    safeRunStage = 'two-hop route Relay ticket validation';
    const multiHopTicketAttempts = multiHopPageTicketChecks.slice(
      multiHopRelayTicketBaseline,
    );
    assertThat(relayAttemptCountIsBounded(
      multiHopTicketAttempts.length,
      aToBToTargetRelayAttempts,
      3,
    ) &&
      multiHopTicketAttempts.every(Boolean),
    'A -> B -> Target route exceeded the bounded Relay ticket budget or targeted outside Bastion A');
    safeRunStage = 'two-hop route Relay WebSocket validation';
    assertThat(multiHopPageSockets.length ===
        multiHopRelaySocketBaseline + multiHopTicketAttempts.length &&
      multiHopPageSockets.at(-1)?.opened && !multiHopPageSockets.at(-1)?.closed,
    'A -> B -> Target route did not leave its final Relay WebSocket active');
    assertRelayPageUnchanged(multiHopProfileBSnapshot,
      'profile A two-hop connection');
    const multiHopAAuthAfter = sshdRuntimeSummary(path.join(tempRoot, 'jump-sshd.log'));
    const multiHopBAuthAfter = sshdRuntimeSummary(path.join(tempRoot, 'second-jump-sshd.log'));
    const multiHopTargetAuthAfter = sshdRuntimeSummary(
      path.join(tempRoot, 'sshd-multihop-target.log'),
    );
    safeRunStage = 'two-hop route independent hop credential validation';
    assertThat(sshdDiagnosticDelta(multiHopAAuthBefore, multiHopAAuthAfter).publicKeyAccepted > 0 &&
      sshdDiagnosticDelta(multiHopBAuthBefore, multiHopBAuthAfter).publicKeyAccepted > 0 &&
      sshdDiagnosticDelta(multiHopTargetAuthBefore, multiHopTargetAuthAfter).publicKeyAccepted > 0,
    'Bastion A, Bastion B, and loopback Target did not each accept their independent SSH credential');

    const multiHopMarker = `WEB_RELAY_MULTIHOP_${RUN_ID.replaceAll('-', '').toUpperCase()}`;
    await sendCommandToActiveTerminal(page, user, targetAddress,
      `printf '%s\\n' '${multiHopMarker}' > /tmp/remote/${multiHopMarker}`, {
        activeHostName: multiHopHostName,
      });
    assertThat(await waitForRemoteMarker(
      path.join(multiHopRemoteRoot, multiHopMarker),
      multiHopMarker,
      20000,
    ), 'two-hop shell command did not execute on the isolated loopback Target');
    const multiHopSocket = multiHopPageSockets.at(-1);
    const frameDeadline = Date.now() + 10000;
    while (Date.now() < frameDeadline &&
        (!multiHopSocket.sentFrames.length || !multiHopSocket.receivedFrames.length)) {
      await page.waitForTimeout(100);
    }
    assertThat(multiHopSocket.sentFrames.length > 0 && multiHopSocket.receivedFrames.length > 0,
      'two-hop terminal command did not traverse Relay WebSocket data frames');
    console.log('stage: Bastion A -> Bastion B -> loopback Target shell succeeded; all Relay attempts targeted Bastion A and the final WebSocket remained active',
      JSON.stringify({ trustPrompts: multiHopTrustPrompts, distinctHopCredentialsAccepted: true,
        markerOnLoopbackTarget: true,
        relayTicketAttempts: multiHopTicketAttempts.length,
        relaySocketAttempts: multiHopTicketAttempts.length,
        activeRelaySockets: 1 }));

    await runFocusedTwoHopSftpAcceptance({
      routePage: page,
      browserContext: context,
      relaySocket: multiHopSocket,
      ticketBaseline: multiHopRelayTicketBaseline,
      socketBaseline: multiHopRelaySocketBaseline,
      otherPageSnapshot: multiHopProfileBSnapshot,
    });

    safeRunStage = 'two-hop route Disconnect action';
    const multiHopTicketCountBeforeDisconnect =
      relayTicketChecksForPage(page).length;
    const multiHopSocketHistoryCountBeforeDisconnect =
      relaySocketsForPage(page).length;
    await click(page, 'Disconnect');
    console.log('stage: two-hop route Disconnect action accepted');
    safeRunStage = 'two-hop route removes only its terminal tab';
    const escapedMultiHopHostName = multiHopHostName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const multiHopTerminalTabs = page.getByRole('button', {
      name: new RegExp(`^${escapedMultiHopHostName} terminal tab, (?:connecting|connected|disconnected|failed), (?:active|inactive)$`),
    });
    const connectedTerminalTabs = page.getByRole('button', {
      name: / terminal tab, connected, (?:active|inactive)$/,
    });
    const activeConnectedTerminalTabs = page.getByRole('button', {
      name: / terminal tab, connected, active$/,
    });
    const openRelaySocketCount = () => relaySockets.filter(
      (socket) => socket.opened && !socket.closed,
    ).length;
    const multiHopCloseDeadline = Date.now() + 5000;
    while (Date.now() < multiHopCloseDeadline &&
        (!multiHopSocket.closed || await multiHopTerminalTabs.count() !== 0 ||
          await connectedTerminalTabs.count() !== multiHopConnectedTabBaseline ||
          await activeConnectedTerminalTabs.count() !== multiHopActiveConnectedTabBaseline ||
          multiHopPreexistingOpenRelaySockets.length === 0 ||
          multiHopPreexistingOpenRelaySockets.some((socket) => socket.closed) ||
          openRelaySocketCount() !== multiHopPreexistingOpenRelaySockets.length)) {
      await page.waitForTimeout(100);
    }
    assertRelayPageUnchanged(multiHopProfileBSnapshot,
      'profile A two-hop disconnect');
    const multiHopCloseEvidence = {
      multiHopSocketClosed: multiHopSocket.closed,
      profileBRelayTicketsUnchanged:
        relayTicketChecksForPage(secondPage).length ===
          multiHopProfileBSnapshot.ticketCount,
      profileBRelaySocketsRemainUnchanged:
        relaySocketsForPage(secondPage).length === multiHopProfileBSnapshot.socketCount &&
        multiHopProfileBSnapshot.openSockets.length > 0 &&
        multiHopProfileBSnapshot.openSockets.every((socket) =>
          relaySocketsForPage(secondPage).includes(socket) &&
          socket.opened && !socket.closed),
      profileBRelaySocketCount: multiHopProfileBSnapshot.openSockets.length,
      preexistingOpenRelaySocketCount: multiHopPreexistingOpenRelaySockets.length,
      preexistingRelaySocketsRemainOpen: multiHopPreexistingOpenRelaySockets.length > 0 &&
        multiHopPreexistingOpenRelaySockets.every((socket) => !socket.closed),
      openRelaySocketCountAfterClose: openRelaySocketCount(),
      profileATicketsUnchanged:
        relayTicketChecksForPage(page).length ===
          multiHopTicketCountBeforeDisconnect,
      profileASocketHistoryUnchanged:
        relaySocketsForPage(page).length ===
          multiHopSocketHistoryCountBeforeDisconnect,
      connectedTabBaseline: multiHopConnectedTabBaseline,
      activeConnectedTabBaseline: multiHopActiveConnectedTabBaseline,
      multiHopTabCount: await multiHopTerminalTabs.count(),
      connectedTabCount: await connectedTerminalTabs.count(),
      activeConnectedTabCount: await activeConnectedTerminalTabs.count(),
    };
    console.log('two-hop disconnect terminal lifecycle safe evidence',
      JSON.stringify(multiHopCloseEvidence));
    assertThat(multiHopCloseEvidence.multiHopSocketClosed &&
      multiHopCloseEvidence.profileBRelaySocketsRemainUnchanged &&
      multiHopCloseEvidence.profileATicketsUnchanged &&
      multiHopCloseEvidence.profileASocketHistoryUnchanged &&
      multiHopCloseEvidence.preexistingRelaySocketsRemainOpen &&
      multiHopCloseEvidence.openRelaySocketCountAfterClose ===
        multiHopCloseEvidence.preexistingOpenRelaySocketCount &&
      multiHopCloseEvidence.multiHopTabCount === 0 &&
      multiHopCloseEvidence.connectedTabCount ===
        multiHopCloseEvidence.connectedTabBaseline &&
      multiHopCloseEvidence.activeConnectedTabCount ===
        multiHopCloseEvidence.activeConnectedTabBaseline,
    'disconnect did not close the two-hop tab while preserving prior Profile A and Profile B states');
    console.log('stage: two-hop disconnect closed its Profile A Relay socket, restored Profile A baseline, and preserved Profile B socket');

    const multihopLogPaths = {
      bastionA: path.join(tempRoot, 'jump-sshd.log'),
      bastionB: path.join(tempRoot, 'second-jump-sshd.log'),
      target: path.join(tempRoot, 'sshd-multihop-target.log'),
    };
    const readMultihopAuth = () => Object.fromEntries(Object.entries(multihopLogPaths)
      .map(([hop, logPath]) => [hop, sshdRuntimeSummary(logPath)]));
    const rejectChangedHopKey = async ({ label, installChanged, restoreOriginal,
      mustAuthenticate, mustNotAuthenticate }) => {
      safeRunStage = `two-hop ${label} host-key rotation rejection`;
      const before = readMultihopAuth();
      const ticketBaseline = multiHopPageTicketChecks.length;
      const socketBaseline = multiHopPageSockets.length;
      const failedTab = page.getByRole('button', {
        name: new RegExp(`^${escapedMultiHopHostName} terminal tab, failed, (?:active|inactive)$`),
      });
      const failedTabBaseline = await failedTab.count();
      await installChanged();
      try {
        // A previous changed-key rejection can still be visible in the global
        // Snackbar or its failed terminal tab. Wait for that old notification
        // to leave before using the same copy as proof of this attempt's result.
        safeRunStage = `two-hop ${label} previous host-key notice cleanup`;
        const priorChangedKeyNotice = page.getByText(
          'SSH 主机密钥与已保存指纹不同，连接已拒绝',
          { exact: false },
        ).first();
        if (await priorChangedKeyNotice.isVisible().catch(() => false)) {
          await priorChangedKeyNotice.waitFor({ state: 'hidden', timeout: 10000 });
        }
        safeRunStage = `two-hop ${label} Host navigation`;
        await click(page, 'Hosts');
        safeRunStage = `two-hop ${label} Connect action`;
        await multiHopHostCard.getByRole('button', { name: 'Connect', exact: true }).click();

        safeRunStage = `two-hop ${label} failed-tab observation`;
        const failureDeadline = Date.now() + 30000;
        while (Date.now() < failureDeadline && await failedTab.count() <= failedTabBaseline) {
          await page.waitForTimeout(100);
        }
        assertThat(await failedTab.count() === failedTabBaseline + 1,
          `${label} changed key did not produce a new failed terminal tab`);
        safeRunStage = `two-hop ${label} rejection message observation`;
        await waitText(page, 'SSH 主机密钥与已保存指纹不同，连接已拒绝', 30000);
        assertThat(!(await page.getByText('CONNECTED', { exact: true }).count()),
          `client connected after ${label} SSH host key changed`);
        const expectedRelayAttempts = relayAttemptsThroughRejectedHop(
          mustAuthenticate.length,
        );
        const ticketAttempts = multiHopPageTicketChecks.slice(ticketBaseline);
        assertThat(relayAttemptCountIsBounded(
          ticketAttempts.length,
          expectedRelayAttempts,
          3,
        ) &&
          ticketAttempts.every(Boolean),
        `${label} rejection exceeded the bounded Relay ticket route budget or left Bastion A`);
        const socketCountAfter = multiHopPageSockets.length;
        assertThat(socketCountAfter === socketBaseline + ticketAttempts.length &&
          multiHopPageSockets.at(-1)?.opened,
        `${label} rejection did not create one Relay WebSocket per handshake attempt`);
        assertRelayPageUnchanged(multiHopProfileBSnapshot,
          `two-hop ${label} Host Key rejection`);
        const after = readMultihopAuth();
        for (const hop of mustAuthenticate) {
          assertThat(sshdDiagnosticDelta(before[hop], after[hop]).publicKeyAccepted > 0,
            `${label} key rejection did not authenticate the route's earlier ${hop} hop`);
        }
        for (const hop of mustNotAuthenticate) {
          assertThat(sshdDiagnosticDelta(before[hop], after[hop]).publicKeyAccepted === 0,
            `${label} changed key was not rejected before ${hop} credential authentication`);
        }
        // Failed tabs intentionally retain their friendly error until the user
        // closes them. Remove this verified rejection before checking the next
        // hop so the next attempt cannot mistake the prior tab's text for its
        // own result.
        safeRunStage = `two-hop ${label} failed terminal tab cleanup`;
        await click(page, 'Terminal');
        await page.getByRole('button', {
          name: `Close ${multiHopHostName}`,
          exact: true,
        }).click();
        const failedTabCloseDeadline = Date.now() + 5000;
        while (Date.now() < failedTabCloseDeadline &&
            await failedTab.count() !== failedTabBaseline) {
          await page.waitForTimeout(100);
        }
        const failedAttemptSockets = multiHopPageSockets.slice(socketBaseline);
        const quietWindowMs = 750;
        const ticketCountAtClose = multiHopPageTicketChecks.length;
        const socketCountAtClose = multiHopPageSockets.length;
        const authAtClose = readMultihopAuth();
        const quietDeadline = Date.now() + quietWindowMs;
        while (Date.now() < quietDeadline) await page.waitForTimeout(100);
        const ticketsStableAfterClose = multiHopPageTicketChecks.length === ticketCountAtClose;
        const socketsStableAfterClose = multiHopPageSockets.length === socketCountAtClose;
        const authAfterClose = readMultihopAuth();
        const forbiddenHopAuthDelta = Object.fromEntries(mustNotAuthenticate.map((hop) => [
          hop,
          sshdDiagnosticDelta(authAtClose[hop], authAfterClose[hop]).publicKeyAccepted,
        ]));
        const remainingFailedAttemptSockets = multiHopPageSockets.slice(socketBaseline)
          .filter((socket) => !socket.closed).length;
        assertThat(await failedTab.count() === failedTabBaseline &&
          remainingFailedAttemptSockets === 0 && ticketsStableAfterClose &&
          socketsStableAfterClose &&
          Object.values(forbiddenHopAuthDelta).every((delta) => delta === 0),
        `${label} rejection cleanup allowed a late tab, Relay attempt, open socket, or later-hop authentication`);
        console.log(`stage: closed the verified ${label} rejection tab and its Relay WebSocket`,
          JSON.stringify({ failedTabRemoved: true,
            failedAttemptSocketCount: failedAttemptSockets.length,
            remainingFailedAttemptSocketCount: remainingFailedAttemptSockets,
            quietWindowMs,
            ticketsStableAfterClose,
            socketsStableAfterClose,
            forbiddenHopAuthDelta }));
        console.log(`stage: changed ${label} SSH host key was rejected at that hop`,
          JSON.stringify({ relayTicketTarget: 'Bastion A',
            relayTicketAttempts: ticketAttempts.length,
            relaySocketAttempts: socketCountAfter - socketBaseline,
            earlierHopsAuthenticated: mustAuthenticate,
            laterHopsNotAuthenticated: mustNotAuthenticate }));
      } finally {
        await restoreOriginal();
      }
    };

    const startChangedSshd = async ({ changedKeyPath, originalKeyPath, address: bindAddress,
      port, authorizedKeys, jailRoot, instance, logLabel, configName, permitOpen }) => {
      run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', changedKeyPath], {
        timeout: 30000,
      });
      fs.chmodSync(changedKeyPath, 0o600);
      assertThat(fs.readFileSync(`${changedKeyPath}.pub`, 'utf8').trim() !==
        fs.readFileSync(`${originalKeyPath}.pub`, 'utf8').trim(),
      `${configName} rotation fixture did not generate a changed key`);
      const changedConfig = writeSshdConfig({
        tempRoot,
        address: bindAddress,
        port,
        hostKey: changedKeyPath,
        authorizedKeys,
        user,
        jailRoot,
        instance,
        configName,
        allowTcpForwarding: 'local',
        permitOpen,
      });
      const changedProcess = startSshd(changedConfig, tempRoot, logLabel);
      await waitForPort(bindAddress, port, changedProcess);
      return changedProcess;
    };

    await rejectChangedHopKey({
      label: 'loopback Target',
      installChanged: async () => {
        await stopGroup(multiHopTargetSshdProcess);
        multiHopTargetSshdProcess = null;
        multiHopTargetSshdProcess = await startChangedSshd({
          changedKeyPath: path.join(tempRoot, 'multihop_target_host_changed'),
          originalKeyPath: multiHopTargetHostKey,
          address: targetAddress,
          port: multiHopTargetPort,
          authorizedKeys: multiHopTargetAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'target-multihop', 'root'),
          instance: 'sshd-multihop-target',
          logLabel: 'sshd-multihop-target',
          configName: 'sshd-multihop-target-changed',
          permitOpen: null,
        });
      },
      restoreOriginal: async () => {
        await stopGroup(multiHopTargetSshdProcess);
        multiHopTargetSshdProcess = startSshd(
          multiHopTargetConfigPath,
          tempRoot,
          'sshd-multihop-target',
        );
        await waitForPort(targetAddress, multiHopTargetPort, multiHopTargetSshdProcess);
      },
      mustAuthenticate: ['bastionA', 'bastionB'],
      mustNotAuthenticate: ['target'],
    });

    await rejectChangedHopKey({
      label: 'Bastion B',
      installChanged: async () => {
        await stopGroup(secondJumpSshdProcess);
        secondJumpSshdProcess = null;
        secondJumpSshdProcess = await startChangedSshd({
          changedKeyPath: path.join(tempRoot, 'bastion_b_host_changed'),
          originalKeyPath: secondJumpHostKey,
          address,
          port: secondBastionPort,
          authorizedKeys: secondJumpAuthorizedKeysPath,
          jailRoot: path.join(sshdFixtureRoot, 'bastion-b', 'root'),
          instance: 'second-jump-sshd',
          logLabel: 'second-jump-sshd',
          configName: 'second-jump-sshd-changed',
          permitOpen: `${targetAddress}:${multiHopTargetPort}`,
        });
      },
      restoreOriginal: async () => {
        await stopGroup(secondJumpSshdProcess);
        secondJumpSshdProcess = startSshd(
          secondJumpConfigPath,
          tempRoot,
          'second-jump-sshd',
        );
        await waitForPort(address, secondBastionPort, secondJumpSshdProcess);
      },
      mustAuthenticate: ['bastionA'],
      mustNotAuthenticate: ['bastionB', 'target'],
    });

    await rejectChangedHopKey({
      label: 'Bastion A',
      installChanged: async () => {
        await stopGroup(jumpSshdProcess);
        jumpSshdProcess = null;
        jumpSshdProcess = await startChangedSshd({
          changedKeyPath: path.join(tempRoot, 'bastion_a_multihop_host_changed'),
          originalKeyPath: jumpHostKey,
          address,
          port: bastionPort,
          authorizedKeys: jumpAuthorizedKeysPath,
          jailRoot,
          instance: 'jump-sshd',
          logLabel: 'jump-sshd',
          configName: 'jump-sshd-multihop-changed',
          permitOpen: [
            `${targetAddress}:${sshPort}`,
            `${targetAddress}:${sshPort2}`,
            `${address}:${secondBastionPort}`,
          ],
        });
      },
      restoreOriginal: async () => {
        await stopGroup(jumpSshdProcess);
        jumpSshdProcess = startSshd(jumpConfigPath, tempRoot, 'jump-sshd');
        await waitForPort(address, bastionPort, jumpSshdProcess);
      },
      mustAuthenticate: [],
      mustNotAuthenticate: ['bastionA', 'bastionB', 'target'],
    });

    assertThat(relayTicketTargetChecks.length > 0 && relayTicketTargetChecks.every(Boolean),
      'one or more Relay tickets targeted Bastion B or a loopback Target instead of Bastion A');
    console.log('stage: changed host keys were independently rejected at Bastion A, Bastion B, and Target; every Relay ticket targeted only Bastion A');

    console.log('browser console warning/error safe summary', JSON.stringify({
      eventCount: browserConsoleEvents.length,
      events: browserConsoleEvents.map(({
        sequence, type, name, category, stageCategory, stageOperation, stageDetail,
        messageCategory, sourceCategory, sourceHasLocation, lineNumber,
        sourceApiPath, columnNumber, signals,
      }) => ({
        sequence, type, name, category, stageCategory, stageOperation, stageDetail,
        messageCategory, sourceCategory, sourceHasLocation, lineNumber,
        sourceApiPath, columnNumber, signals,
      })),
      categories: browserConsoleEvents.reduce((counts, event) => {
        const key = `${event.type}:${event.category}:${event.stageCategory}`;
        counts[key] = (counts[key] || 0) + 1;
        return counts;
      }, {}),
      failedRequestCount: requestFailures.length + secondRequestFailures.length,
      failedRequests: [
        ...requestFailures.map((failure) => ({ profile: 'A', ...failure })),
        ...secondRequestFailures.map((failure) => ({ profile: 'B', ...failure })),
      ].slice(-20),
      apiCorrelations: safeBrowserConsoleApiCorrelations(
        browserConsoleEvents,
        browserConsoleCaptureTimes,
        apiResponseDiagnostics,
        requestFailureDiagnostics,
      ),
    }));
    assertThat(pageErrors.length === 0, 'browser page errors were detected');
    console.log('WEB-RELAY-01 passed: one-hop and Bastion A -> Bastion B -> loopback Target routes, distinct hop credentials and trust, first-hop-targeted Relay handshake attempts with the final WebSocket active, independent changed-key rejection at Bastion A/B/Target, independently approved second-device sync and structured Snippet execution with encrypted Credential-secret parameters, terminal tabs, SSH shell, SFTP navigation/transfer, UTF-8 remote editing, conflict compare/cancel/overwrite, Save as, 10 MiB limit, and disconnect verified.');
  } finally {
    process.removeListener('SIGINT', handleTermination);
    process.removeListener('SIGTERM', handleTermination);
    const cleanupFailures = [];
    if (secondContext) {
      try { await secondContext.close(); } catch (_) { cleanupFailures.push('second browser context close'); }
    }
    if (context) {
      try { await context.close(); } catch (_) { cleanupFailures.push('browser context close'); }
    }
    if (browser) {
      try { await browser.close(); } catch (_) { cleanupFailures.push('browser close'); }
    }
    bootstrapToken = undefined;
    bootstrapTokenForRedaction = undefined;
    expectedPrivateKey = undefined;
    userPrivateKey = undefined;
    jumpPrivateKey = undefined;
    secondJumpPrivateKey = undefined;
    multiHopTargetPrivateKey = undefined;
    thirdJumpPrivateKey = undefined;
    fourthJumpPrivateKey = undefined;
    maxDepthJumpPrivateKeys = [];
    snippetCredentialSecret = undefined;
    keyboardInteractiveCode = undefined;
    keyboardInteractiveOtp = undefined;
    keyboardInteractiveShellMarker = undefined;
    keyboardInteractiveUnusedPassword = undefined;
    secretSyncPrivacy.active = false;
    secretSyncPrivacy.marker = null;
    secretSyncPrivacy.additionalMarkers = [];
    snippetRelaySync.secretMarker = null;
    portForwardSyncPrivacy.active = false;
    portForwardSyncPrivacy.marker = null;
    terminalCollaborationPrivacy.active = false;
    terminalCollaborationPrivacy.markers = [];
    try { await stopGroup(sshdProcess); } catch (_) { cleanupFailures.push('target sshd process group'); }
    try { await stopGroup(secondTargetSshdProcess); } catch (_) {
      cleanupFailures.push('second target sshd process group');
    }
    try { await stopGroup(jumpSshdProcess); } catch (_) { cleanupFailures.push('bastion sshd process group'); }
    try { await stopGroup(secondJumpSshdProcess); } catch (_) {
      cleanupFailures.push('second bastion sshd process group');
    }
    try { await stopGroup(multiHopTargetSshdProcess); } catch (_) {
      cleanupFailures.push('multi-hop target sshd process group');
    }
    try { await stopGroup(thirdJumpSshdProcess); } catch (_) {
      cleanupFailures.push('third bastion sshd process group');
    }
    try { await stopGroup(fourthJumpSshdProcess); } catch (_) {
      cleanupFailures.push('fourth bastion sshd process group');
    }
    for (const process of maxDepthJumpSshdProcesses) {
      try { await stopGroup(process); } catch (_) {
        cleanupFailures.push('max-depth bastion sshd process group');
      }
    }
    maxDepthJumpSshdProcesses = [];
    try { keyboardInteractivePamFixture?.cleanup(); } catch (_) {
      cleanupFailures.push('temporary PAM service cleanup');
    }
    try { await stopGroup(serverProcess); } catch (_) { cleanupFailures.push('server process group'); }
    try { cleanupEphemeralSshLoginAccount(); } catch (_) {
      cleanupFailures.push('temporary SSH account/group/home cleanup');
    }
    if (sshdFixtureRoot) {
      try {
        fs.rmSync(sshdFixtureRoot, { recursive: true, force: true });
        if (fs.existsSync(sshdFixtureRoot)) cleanupFailures.push('sshd chroot fixture removal');
      } catch (_) {
        cleanupFailures.push('sshd chroot fixture removal');
      }
    }
    if (authorizedKeysFixtureRoot) {
      try {
        fs.rmSync(authorizedKeysFixtureRoot, { recursive: true, force: true });
        if (fs.existsSync(authorizedKeysFixtureRoot)) cleanupFailures.push('authorized-key fixture removal');
      } catch (_) {
        cleanupFailures.push('authorized-key fixture removal');
      }
    }
    if (serverLog !== null) {
      try { fs.closeSync(serverLog); } catch (_) { cleanupFailures.push('server log descriptor'); }
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupFailures.push('temporary directory removal');
      } catch (_) {
        cleanupFailures.push('temporary directory removal');
      }
    }
    if (cleanupFailures.length) throw new Error(`cleanup failed (${cleanupFailures.join(', ')})`);
    if (portForwardOnly) {
      console.log('WEB-PORT-FORWARD-01 cleanup passed: isolated SSHD, server, browser, account and temporary data fixtures removed.');
    }
    if (collaborationOnly) {
      console.log(webUpdateOnly
        ? 'WEB-APP-UPDATE-01 cleanup passed: isolated SSHD, server, browser, account and temporary data fixtures removed.'
        : 'WEB-TERMINAL-COLLABORATION-01 cleanup passed: isolated SSHD, server, browser, account and temporary data fixtures removed.');
    }
    if (deepHopOnly) {
      console.log(maxDepthHopOnly
        ? 'WEB-RELAY-MAX-DEPTH-01 cleanup passed: Bastion A/B/C/D/E/F/G/H, target, server, browser profiles, temporary SSH account, and private fixture directories removed.'
        : fourHopOnly
        ? 'WEB-RELAY-FOUR-HOP-01 cleanup passed: Bastion A/B/C/D, target, server, browser profiles, temporary SSH account, and private fixture directories removed.'
        : 'WEB-RELAY-THREE-HOP-01 cleanup passed: Bastion A/B/C, target, server, browser profiles, temporary SSH account, and private fixture directories removed.');
    }
    if (shellCompletionOnly) {
      console.log('WEB-SHELL-COMPLETION-01 cleanup passed: isolated SSHD, server, browser profiles, account and temporary data fixtures removed.');
    }
    if (keyboardInteractiveOnly) {
      console.log('WEB-RELAY-KBDINT-01 cleanup passed: PAM service, isolated SSHDs, server, browser, account and temporary fixture data removed.');
    }
  }
}

async function cleanupSelfTest() {
  let child;
  let scratch;
  try {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-relay-cleanup-'));
    fs.chmodSync(scratch, 0o700);
    const childScript = [
      "const {spawn}=require('node:child_process')",
      "const worker=spawn(process.execPath,['-e','setInterval(()=>{},60000)'],{stdio:'ignore'})",
      "worker.once('spawn',()=>setTimeout(()=>process.exit(0),100))",
    ].join(';');
    child = spawn(process.execPath, ['-e', childScript], {
      cwd: scratch,
      stdio: 'ignore',
      detached: true,
    });
    await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', resolve);
    });
    assertThat(processGroupHasLiveMembers(child.pid), 'self-check did not retain a child after its group leader exited');
    await stopGroup(child);
    assertThat(!processGroupHasLiveMembers(child.pid), 'self-check left a live process in the child group');
  } finally {
    let cleanupFailed = false;
    if (child) {
      try { await stopGroup(child); } catch (_) { cleanupFailed = true; }
    }
    if (scratch) {
      try {
        fs.rmSync(scratch, { recursive: true, force: true });
        if (fs.existsSync(scratch)) cleanupFailed = true;
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (cleanupFailed) throw new Error('self-check cleanup failed');
  }
}

if (process.argv.includes('--console-classifier-self-test')) {
  try {
    consoleClassifierSelfTest();
  } catch (_) {
    console.error('WEB-RELAY-CONSOLE-CLASSIFIER-01 failed');
    process.exitCode = 1;
  }
} else if (process.argv.includes('--self-test-cleanup')) {
  cleanupSelfTest().then(() => {
    console.log('relay cleanup self-check passed');
  }).catch(() => {
    console.error('relay cleanup self-check failed');
    process.exitCode = 1;
  });
} else {
  main().catch((error) => {
    if (activeTerminationSignal && !String(error?.message || '').startsWith('cleanup failed')) return;
    const errorType = error && error.name === 'TimeoutError' ? 'TimeoutError' : 'Error';
    const failureTestName = process.argv.includes('--web-update-only')
      ? 'WEB-APP-UPDATE-01'
      : process.env.WEB_RELAY_MAX_DEPTH_ONLY === '1'
        ? 'WEB-RELAY-MAX-DEPTH-01'
      : process.env.WEB_RELAY_FOUR_HOP_ONLY === '1'
        ? 'WEB-RELAY-FOUR-HOP-01'
      : process.argv.includes('--collaboration-only') ||
          process.env.WEB_RELAY_COLLABORATION_ONLY === '1'
        ? 'WEB-TERMINAL-COLLABORATION-01'
        : process.argv.includes('--shell-completion-only')
          ? 'WEB-SHELL-COMPLETION-01'
        : process.argv.includes('--keyboard-interactive-only')
          ? 'WEB-RELAY-KBDINT-01'
        : process.env.WEB_RELAY_PORT_FORWARD_ONLY === '1' ||
            process.argv.includes('--port-forward-only')
          ? 'WEB-PORT-FORWARD-01' : 'WEB-RELAY-01';
    if (safeRunStage.includes('terminal stable fingerprint')) {
      console.error('terminal fingerprint final safe diagnostic', JSON.stringify({
        phase: safeRunStage,
        errorName: ['TimeoutError', 'TargetClosedError', 'Error'].includes(error?.name)
          ? error.name : 'OtherError',
        errorCategory: safeErrorSummary(error).category,
        errorCode: terminalFingerprintErrorCode(error, null),
        evidence: terminalFingerprintLatestSafeEvidence,
      }));
    }
    console.error(`${failureTestName} failed at ${safeRunStage} (${errorType})`);
    process.exitCode = 1;
  });
}
