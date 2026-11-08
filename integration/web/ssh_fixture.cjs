/*
 * Small, isolated OpenSSH fixture for current-bundle Web acceptance tests.
 *
 * startSshFixture({ bindAddress, ports }) provisions one run-specific Unix
 * account and starts one independent sshd per requested port. All daemons use
 * the same generated password, but each has its own host key, private config,
 * log, and chroot. The returned password is intended for the test's password
 * Credential; it is never written to a file or emitted in diagnostics.
 *
 * This fixture is Linux/root-only and deliberately requires OpenSSH, account
 * management tools, /run/sshd, and a non-root interactive shell. Its private
 * chroots contain only the shell, its shared-library dependencies, `id`, and
 * minimal passwd/group files. Tests may request the `stty` binary to inspect
 * the fixture PTY size. SSH forwarding, agent forwarding, X11, root
 * login, public-key auth, and keyboard-interactive auth are disabled.
 *
 * startPublicKeySshFixture() is a separate opt-in mode for tests that need to
 * exercise a private-key Credential. It binds only to IPv4 loopback on an OS
 * selected ephemeral port, uses one run-specific ed25519 key, and enables no
 * password or keyboard-interactive authentication.
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const SSHD = process.env.SSHD_PATH || '/usr/sbin/sshd';
const SSH_KEYGEN = process.env.SSH_KEYGEN_PATH || '/usr/bin/ssh-keygen';
const TMUX = process.env.TMUX_PATH || '/usr/bin/tmux';
const SHELL = '/bin/bash';
const SESSION_WAIT_MS = 10000;

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

function run(command, args, { input, timeout = 15000 } = {}) {
  const result = spawnSync(command, args, {
    input,
    encoding: 'utf8',
    timeout,
    maxBuffer: 2 * 1024 * 1024,
    env: process.env,
  });
  if (result.error || result.status !== 0) {
    // Do not include command output. chpasswd's stdin and sshd diagnostics can
    // contain fixture identifiers and are not useful as public test output.
    throw new Error(`isolated SSH fixture setup failed (${path.basename(command)})`);
  }
  return result.stdout || '';
}

function isRfc1918Ipv4(address) {
  if (!net.isIPv4(address)) return false;
  const octets = address.split('.').map(Number);
  return octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
}

function requireEnvironment({ tmux = false } = {}) {
  if (typeof process.getuid !== 'function' || process.getuid() !== 0) {
    throw new Error('isolated SSH fixture requires root to provision and remove its temporary account');
  }
  if (!fs.existsSync(SSHD) || !fs.existsSync(SSH_KEYGEN)) {
    throw new Error('isolated SSH fixture requires OpenSSH sshd and ssh-keygen');
  }
  const runtimeDirectory = '/run/sshd';
  if (!fs.existsSync(runtimeDirectory) || !fs.statSync(runtimeDirectory).isDirectory()) {
    throw new Error('isolated SSH fixture requires an existing /run/sshd directory');
  }
  for (const directory of ['/run', runtimeDirectory]) {
    const stat = fs.statSync(directory);
    if (stat.uid !== 0 || (stat.mode & 0o022) !== 0) {
      throw new Error('isolated SSH fixture requires root-owned, non-writable OpenSSH runtime directories');
    }
  }
  if (!fs.existsSync(SHELL) || !fs.statSync(SHELL).isFile()) {
    throw new Error('isolated SSH fixture requires /bin/bash');
  }
  const requiredCommands = [
    'useradd', 'userdel', 'groupdel', 'getent', 'chpasswd', 'openssl', 'ldd',
    ...(tmux ? ['runuser'] : []),
  ];
  const missing = requiredCommands.filter((name) => !executableOnPath(name));
  if (missing.length) {
    throw new Error(`isolated SSH fixture is missing required account/runtime tools: ${missing.join(', ')}`);
  }
  if (tmux) {
    if (!fs.existsSync(TMUX) || !fs.statSync(TMUX).isFile()) {
      throw new Error('tmux SSH fixture requires the configured tmux binary');
    }
    const version = spawnSync(TMUX, ['-V'], {
      encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (version.error || version.status !== 0 ||
        !/^tmux\s+\d+(?:\.\d+)?/i.test((version.stdout || '').trim())) {
      throw new Error('tmux SSH fixture could not verify the configured tmux binary');
    }
  }
}

function secureFixtureTempParent() {
  // Modern OpenSSH checks every component of ChrootDirectory. A fixture
  // chroot under /tmp is rejected because /tmp is writable, even when sticky.
  // /run is commonly mounted noexec. /var/lib is root-managed, executable,
  // and traversable by the isolated tmux account when its fixture dir is 0711.
  // This helper already requires root and validates /run/sshd separately.
  const parent = fs.realpathSync('/var/lib');
  const stat = fs.statSync(parent);
  if (!stat.isDirectory() || stat.uid !== 0 || (stat.mode & 0o022) !== 0) {
    throw new Error('SSH fixtures require a root-owned, non-writable /var/lib directory');
  }
  return parent;
}

function stickyFixtureTempParent() {
  // tmux fixtures are not chrooted, so the system temporary directory is
  // suitable as long as it is root-owned and either private or sticky.
  const parent = fs.realpathSync(os.tmpdir());
  const stat = fs.statSync(parent);
  if (!stat.isDirectory() || stat.uid !== 0 ||
      ((stat.mode & 0o022) !== 0 && (stat.mode & 0o1000) === 0)) {
    throw new Error('tmux SSH fixture requires a root-owned private or sticky temporary directory');
  }
  return parent;
}

function validateOptions(options) {
  if (!options || typeof options !== 'object') throw new Error('fixture options are required');
  const bindAddressIsLocal = Object.values(os.networkInterfaces())
    .flatMap((entries) => entries || [])
    .some((entry) => entry.family === 'IPv4' && entry.address === options.bindAddress);
  if (!isRfc1918Ipv4(options.bindAddress) || !bindAddressIsLocal) {
    throw new Error('bindAddress must be an assigned RFC1918 private IPv4 address');
  }
  if (!Array.isArray(options.ports) || options.ports.length < 1 || options.ports.length > 8) {
    throw new Error('ports must contain between one and eight requested TCP ports');
  }
  const seen = new Set();
  for (const port of options.ports) {
    if (!Number.isInteger(port) || port < 1 || port > 65535 || seen.has(port)) {
      throw new Error('ports must be distinct integers between 1 and 65535');
    }
    seen.add(port);
  }
  const username = options.username || `atermius-ws-${crypto.randomBytes(8).toString('hex')}`;
  if (!/^atermius-ws-[a-f0-9]{16}$/.test(username)) {
    throw new Error('username must use the run-specific fixture account format');
  }
  const password = options.password || crypto.randomBytes(32).toString('base64url');
  // chpasswd takes name:password records on stdin. Restrict the password to
  // printable, non-whitespace ASCII and reject its record delimiter.
  if (typeof password !== 'string' || !/^[\x21-\x39\x3b-\x7e]{16,128}$/.test(password)) {
    throw new Error('password must be 16–128 printable ASCII characters without whitespace or colon');
  }
  return {
    bindAddress: options.bindAddress,
    ports: [...options.ports],
    username,
    password,
    includeStty: options.includeStty === true,
  };
}

function reserveLoopbackPort() {
  return new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen({ host: '127.0.0.1', port: 0, exclusive: true }, () => {
      const address = listener.address();
      if (!address || typeof address === 'string' || !Number.isInteger(address.port)) {
        listener.close(() => reject(new Error('could not reserve an ephemeral loopback SSH port')));
        return;
      }
      listener.close((error) => error
        ? reject(new Error('could not release the ephemeral loopback SSH reservation'))
        : resolve(address.port));
    });
  });
}

function getent(kind, name) {
  const result = spawnSync('getent', [kind, name], { encoding: 'utf8', timeout: 5000 });
  if (result.error || (result.status !== 0 && result.status !== 2)) {
    throw new Error('could not safely inspect the temporary SSH account database entry');
  }
  return result.status === 0 ? (result.stdout || '').trim() : '';
}

function fixtureUidRange() {
  let definitions = '';
  try { definitions = fs.readFileSync('/etc/login.defs', 'utf8'); } catch (_) {}
  const configured = (key, fallback) => {
    const match = definitions.match(new RegExp(`^\\s*${key}\\s+(\\d+)`, 'm'));
    return match ? Number(match[1]) : fallback;
  };
  // Keep fixture accounts away from low service UIDs (including container
  // runtime identities), even when UID_MIN is configured below 10000.
  const minimum = Math.max(10000, configured('UID_MIN', 1000));
  const maximum = Math.min(59999, configured('UID_MAX', 60000));
  if (!Number.isInteger(minimum) || !Number.isInteger(maximum) || maximum < minimum) {
    throw new Error('no safe high UID range is available for the temporary SSH account');
  }
  return { minimum, maximum };
}

function allocatedUids() {
  const used = new Set();
  const passwd = spawnSync('getent', ['passwd'], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 8 * 1024 * 1024,
  });
  if (passwd.error || passwd.status !== 0) {
    throw new Error('could not safely inspect allocated Unix account IDs');
  }
  for (const line of (passwd.stdout || '').split(/\r?\n/)) {
    const uid = Number(line.split(':')[2]);
    if (Number.isInteger(uid) && uid >= 0) used.add(uid);
  }

  // Account databases can omit a container or transient service identity.
  // Reserve every UID with a live process too, so fixture teardown can only
  // signal processes created under its own unique account.
  let entries = [];
  try { entries = fs.readdirSync('/proc'); } catch (_) {
    throw new Error('could not safely inspect live process account IDs');
  }
  for (const entry of entries) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const status = fs.readFileSync(`/proc/${entry}/status`, 'utf8');
      const uid = Number(status.match(/^Uid:\s+(\d+)/m)?.[1]);
      if (Number.isInteger(uid) && uid >= 0) used.add(uid);
    } catch (_) {}
  }
  return used;
}

function chooseFixtureUid() {
  const { minimum, maximum } = fixtureUidRange();
  const used = allocatedUids();
  // A bounded random search avoids a deterministic low-UID choice and fails
  // closed if account creation is racing another allocator.
  for (let attempt = 0; attempt < 512; attempt += 1) {
    const uid = crypto.randomInt(minimum, maximum + 1);
    if (!used.has(uid)) return uid;
  }
  throw new Error('could not find an unallocated high UID for the temporary SSH account');
}

function createAccount(username, password, state, { homePath } = {}) {
  const home = homePath || `/home/${username}`;
  if (!path.isAbsolute(home)) {
    throw new Error('temporary SSH fixture home must be an absolute path');
  }
  if (getent('passwd', username) || getent('group', username) || fs.existsSync(home)) {
    throw new Error('run-specific SSH fixture identity already exists; refusing to reuse it');
  }

  // Mark the exact random identity before useradd so cleanup can safely remove
  // a partially created account if any later setup step fails.
  const requestedUid = chooseFixtureUid();
  state.account = { username, home, uid: requestedUid, gid: null, shell: SHELL };
  const useradd = executableOnPath('useradd');
  const useraddArgs = [
    '--uid', String(requestedUid), '--user-group', '--no-create-home', '--home-dir', home,
    '--shell', SHELL,
  ];
  useraddArgs.push(username);
  run(useradd, useraddArgs);

  const passwdLine = getent('passwd', username);
  const fields = passwdLine.split(':');
  const uid = Number(fields[2]);
  const gid = Number(fields[3]);
  if (fields.length < 7 || fields[0] !== username || fields[5] !== home || fields[6] !== SHELL ||
      !Number.isInteger(uid) || uid <= 0 || !Number.isInteger(gid) || gid <= 0) {
    throw new Error('temporary SSH account did not resolve to its expected non-root identity');
  }
  if (uid !== requestedUid) {
    throw new Error('temporary SSH account allocator changed its reserved high UID');
  }
  state.account.uid = uid;
  state.account.gid = gid;

  const passwordBytes = Buffer.from(`${password}\n`, 'utf8');
  let hash;
  try {
    const hashed = spawnSync(executableOnPath('openssl'), ['passwd', '-6', '-stdin'], {
      input: passwordBytes,
      encoding: 'utf8',
      timeout: 5000,
    });
    if (hashed.error || hashed.status !== 0 || !/^\$6\$[^\r\n]+$/.test((hashed.stdout || '').trim())) {
      throw new Error('could not initialize the temporary SSH account password state');
    }
    hash = hashed.stdout.trim();
  } finally {
    passwordBytes.fill(0);
  }

  const credentialLine = Buffer.from(`${username}:${hash}\n`, 'utf8');
  try {
    const changed = spawnSync(executableOnPath('chpasswd'), ['--encrypted'], {
      input: credentialLine,
      encoding: 'utf8',
      timeout: 5000,
    });
    if (changed.error || changed.status !== 0) {
      throw new Error('could not initialize the temporary SSH account password state');
    }
  } finally {
    credentialLine.fill(0);
  }
}

function copyRuntimeDependencies(binaryPath, jailRoot) {
  const result = spawnSync(executableOnPath('ldd'), [binaryPath], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0 || /=>\s+not found/.test(result.stdout || '')) {
    throw new Error(`could not resolve runtime files for isolated shell executable ${path.basename(binaryPath)}`);
  }
  const dependencies = new Set();
  for (const line of (result.stdout || '').split('\n')) {
    const mapped = line.match(/=>\s+(\/\S+)/);
    const loader = line.match(/^\s*(\/\S+)\s+\(/);
    const dependency = mapped?.[1] || loader?.[1];
    if (dependency && fs.existsSync(dependency)) dependencies.add(dependency);
  }
  for (const dependency of dependencies) copyFileIntoJail(dependency, jailRoot, dependency);
}

function copyFileIntoJail(source, jailRoot, jailPath = source) {
  const realSource = fs.realpathSync(source);
  const destination = path.join(jailRoot, jailPath.replace(/^\/+/, ''));
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
  fs.copyFileSync(realSource, destination);
  fs.chmodSync(destination, fs.statSync(realSource).mode & 0o755);
}

function createJail(serverRoot, account, { includeStty = false } = {}) {
  const jailRoot = path.join(serverRoot, 'jail');
  fs.mkdirSync(jailRoot, { mode: 0o755 });
  fs.chmodSync(jailRoot, 0o755);
  const etcRoot = path.join(jailRoot, 'etc');
  const homeRoot = path.join(jailRoot, account.home.replace(/^\/+/, ''));
  const tmpRoot = path.join(jailRoot, 'tmp');
  fs.mkdirSync(etcRoot, { mode: 0o755 });
  fs.chmodSync(etcRoot, 0o755);
  // The account must be able to traverse /home before entering its private
  // directory. Recursive creation with 0700 would make /home root-only.
  fs.mkdirSync(path.dirname(homeRoot), { recursive: true, mode: 0o755 });
  fs.chmodSync(path.dirname(homeRoot), 0o755);
  fs.mkdirSync(homeRoot, { recursive: true, mode: 0o700 });
  fs.mkdirSync(tmpRoot, { mode: 0o1777 });
  fs.chmodSync(tmpRoot, 0o1777);

  copyFileIntoJail(SHELL, jailRoot, SHELL);
  copyRuntimeDependencies(fs.realpathSync(SHELL), jailRoot);
  const idPath = executableOnPath('id');
  if (!idPath) throw new Error('isolated SSH fixture requires the id command');
  copyFileIntoJail(idPath, jailRoot, idPath);
  copyRuntimeDependencies(fs.realpathSync(idPath), jailRoot);
  if (includeStty) {
    const sttyPath = executableOnPath('stty');
    if (!sttyPath) {
      throw new Error('PTY size inspection requires stty');
    }
    copyFileIntoJail(sttyPath, jailRoot, sttyPath);
    copyRuntimeDependencies(fs.realpathSync(sttyPath), jailRoot);
  }

  fs.writeFileSync(
    path.join(etcRoot, 'passwd'),
    `${account.username}:x:${account.uid}:${account.gid}:SSH fixture:${account.home}:${SHELL}\n`,
    { mode: 0o444 },
  );
  fs.writeFileSync(path.join(etcRoot, 'group'), `${account.username}:x:${account.gid}:\n`, { mode: 0o444 });
  fs.writeFileSync(path.join(etcRoot, 'nsswitch.conf'), 'passwd: files\ngroup: files\nhosts: files\n', { mode: 0o444 });
  fs.chownSync(homeRoot, account.uid, account.gid);
  fs.chmodSync(homeRoot, 0o700);
  return jailRoot;
}

function generateHostKey(serverRoot) {
  const privateKey = path.join(serverRoot, 'host_ed25519');
  run(SSH_KEYGEN, ['-q', '-t', 'ed25519', '-N', '', '-f', privateKey]);
  fs.chmodSync(privateKey, 0o600);
  const publicKey = fs.readFileSync(`${privateKey}.pub`, 'utf8').trim();
  const fingerprintOutput = run(SSH_KEYGEN, ['-lf', `${privateKey}.pub`]);
  const fingerprint = fingerprintOutput.match(/\bSHA256:[A-Za-z0-9+/]+/);
  if (!publicKey.startsWith('ssh-ed25519 ') || !fingerprint) {
    throw new Error('could not read the temporary OpenSSH host key fingerprint');
  }
  return { privateKey, publicKey, fingerprint: fingerprint[0] };
}

function configFor({ serverRoot, bindAddress, port, username, hostKey, jailRoot }) {
  const configPath = path.join(serverRoot, 'sshd.config');
  const lines = [
    `Port ${port}`,
    `ListenAddress ${bindAddress}`,
    `HostKey ${hostKey}`,
    `PidFile ${path.join(serverRoot, 'sshd.pid')}`,
    'Protocol 2',
    'PubkeyAuthentication no',
    'AuthenticationMethods password',
    'PasswordAuthentication yes',
    'KbdInteractiveAuthentication no',
    'PermitRootLogin no',
    `ChrootDirectory ${jailRoot}`,
    `AllowUsers ${username}`,
    'StrictModes no',
    'UsePAM no',
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'PermitUserRC no',
    'AllowAgentForwarding no',
    'AllowTcpForwarding no',
    'X11Forwarding no',
    'PermitTunnel no',
    'GatewayPorts no',
    'PermitTTY yes',
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 3',
    'LoginGraceTime 60',
    'ClientAliveInterval 15',
    'ClientAliveCountMax 2',
    'LogLevel DEBUG3',
    'Subsystem sftp internal-sftp',
  ];
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  run(SSHD, ['-t', '-f', configPath]);
  const effective = run(SSHD, ['-T', '-f', configPath]).split(/\r?\n/);
  const required = [
    `listenaddress ${bindAddress}:${port}`,
    `hostkey ${hostKey}`,
    'passwordauthentication yes',
    'authenticationmethods password',
    'pubkeyauthentication no',
    'kbdinteractiveauthentication no',
    'permitrootlogin no',
    `chrootdirectory ${jailRoot}`,
    `allowusers ${username}`,
    'allowtcpforwarding no',
    'allowagentforwarding no',
    'x11forwarding no',
    'usepam no',
  ];
  if (required.some((line) => !effective.includes(line))) {
    throw new Error('effective sshd configuration did not preserve the fixture isolation policy');
  }
  return configPath;
}

function configForTmux({ serverRoot, bindAddress, port, username, hostKey, tmuxTmpDir }) {
  const configPath = path.join(serverRoot, 'sshd.config');
  const lines = [
    `Port ${port}`,
    `ListenAddress ${bindAddress}`,
    `HostKey ${hostKey}`,
    `PidFile ${path.join(serverRoot, 'sshd.pid')}`,
    'Protocol 2',
    'PubkeyAuthentication no',
    'AuthenticationMethods password',
    'PasswordAuthentication yes',
    'KbdInteractiveAuthentication no',
    'PermitRootLogin no',
    `AllowUsers ${username}`,
    'StrictModes yes',
    'UsePAM no',
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'PermitUserRC no',
    'AllowAgentForwarding no',
    'AllowTcpForwarding no',
    'AllowStreamLocalForwarding no',
    'X11Forwarding no',
    'PermitTunnel no',
    'GatewayPorts no',
    'PermitTTY yes',
    `SetEnv TMUX_TMPDIR=${tmuxTmpDir}`,
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 3',
    'LoginGraceTime 60',
    'ClientAliveInterval 15',
    'ClientAliveCountMax 2',
    'LogLevel DEBUG3',
    'Subsystem sftp internal-sftp',
  ];
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  run(SSHD, ['-t', '-f', configPath]);
  const effective = run(SSHD, ['-T', '-f', configPath]).split(/\r?\n/);
  const required = [
    `listenaddress ${bindAddress}:${port}`,
    `hostkey ${hostKey}`,
    'passwordauthentication yes',
    'authenticationmethods password',
    'pubkeyauthentication no',
    'kbdinteractiveauthentication no',
    'permitrootlogin no',
    `allowusers ${username}`,
    'allowtcpforwarding no',
    'allowstreamlocalforwarding no',
    'allowagentforwarding no',
    'x11forwarding no',
    'usepam no',
    `setenv TMUX_TMPDIR=${tmuxTmpDir}`,
    'chrootdirectory none',
  ];
  if (required.some((line) => !effective.includes(line))) {
    throw new Error('effective tmux SSHD configuration did not preserve the fixture isolation policy');
  }
  return configPath;
}

function configForPublicKey({ serverRoot, port, username, hostKey }) {
  const configPath = path.join(serverRoot, 'sshd.config');
  const lines = [
    `Port ${port}`,
    'ListenAddress 127.0.0.1',
    `HostKey ${hostKey}`,
    `PidFile ${path.join(serverRoot, 'sshd.pid')}`,
    'Protocol 2',
    'PubkeyAuthentication yes',
    'AuthenticationMethods publickey',
    'PasswordAuthentication no',
    'KbdInteractiveAuthentication no',
    'PermitRootLogin no',
    'AuthorizedKeysFile .ssh/authorized_keys',
    `AllowUsers ${username}`,
    'StrictModes yes',
    'UsePAM no',
    'UseDNS no',
    'PermitEmptyPasswords no',
    'PermitUserEnvironment no',
    'PermitUserRC no',
    'AllowAgentForwarding no',
    'AllowTcpForwarding no',
    'AllowStreamLocalForwarding no',
    'X11Forwarding no',
    'PermitTunnel no',
    'GatewayPorts no',
    'PermitTTY yes',
    'PrintMotd no',
    'PrintLastLog no',
    'MaxAuthTries 3',
    'LoginGraceTime 60',
    'ClientAliveInterval 15',
    'ClientAliveCountMax 2',
    'LogLevel DEBUG3',
    'Subsystem sftp internal-sftp',
  ];
  fs.writeFileSync(configPath, `${lines.join('\n')}\n`, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
  run(SSHD, ['-t', '-f', configPath]);
  const effective = run(SSHD, ['-T', '-f', configPath]).split(/\r?\n/);
  const required = [
    `listenaddress 127.0.0.1:${port}`,
    `hostkey ${hostKey}`,
    'passwordauthentication no',
    'authenticationmethods publickey',
    'pubkeyauthentication yes',
    'kbdinteractiveauthentication no',
    'permitrootlogin no',
    'authorizedkeysfile .ssh/authorized_keys',
    `allowusers ${username}`,
    'allowtcpforwarding no',
    'allowstreamlocalforwarding no',
    'allowagentforwarding no',
    'x11forwarding no',
    'usepam no',
    'chrootdirectory none',
  ];
  if (required.some((line) => !effective.includes(line))) {
    throw new Error('effective public-key SSHD configuration did not preserve the fixture isolation policy');
  }
  return configPath;
}

function countMatches(lines, expression) {
  return lines.filter((line) => expression.test(line)).length;
}

function connectionPortSet(lines, expression) {
  const ports = new Set();
  for (const line of lines) {
    const match = line.match(expression);
    if (match) ports.add(match[1]);
  }
  return ports;
}

function summarizeConnections(lines) {
  const byRemoteEndpoint = new Map();
  const getConnection = (address, port) => {
    const key = `${address}:${port}`;
    let connection = byRemoteEndpoint.get(key);
    if (!connection) {
      connection = {
        accepted: false,
        closed: false,
        passwordAccepted: 0,
        passwordRejected: 0,
        shellSessions: 0,
      };
      byRemoteEndpoint.set(key, connection);
    }
    return connection;
  };

  for (const line of lines) {
    const accepted = line.match(/\bConnection from (\S+) port (\d+) on /i);
    if (accepted) getConnection(accepted[1], accepted[2]).accepted = true;

    const passwordAccepted = line.match(/\bAccepted password for \S+ from (\S+) port (\d+)\b/i);
    if (passwordAccepted) getConnection(passwordAccepted[1], passwordAccepted[2]).passwordAccepted++;

    const passwordRejected = line.match(/\bFailed password for \S+ from (\S+) port (\d+)\b/i);
    if (passwordRejected) getConnection(passwordRejected[1], passwordRejected[2]).passwordRejected++;

    const shellSession = line.match(/\bStarting session: shell(?: on \S+)? for \S+ from (\S+) port (\d+)\b/i);
    if (shellSession) getConnection(shellSession[1], shellSession[2]).shellSessions++;

    const closed = line.match(/\bConnection closed by .*?(\S+) port (\d+)\b/i);
    if (closed) getConnection(closed[1], closed[2]).closed = true;
  }

  return [...byRemoteEndpoint.values()]
    .filter((connection) => connection.accepted)
    .map((connection) => ({ ...connection }));
}

function countOpenTcpConnections(port) {
  const portHex = Number(port).toString(16).toUpperCase().padStart(4, '0');
  try {
    return fs.readFileSync('/proc/net/tcp', 'utf8').split(/\r?\n/).slice(1)
      .filter((line) => {
        const fields = line.trim().split(/\s+/);
        const localPort = fields[1]?.split(':')[1]?.toUpperCase();
        return localPort === portHex && fields[3] === '01';
      }).length;
  } catch (_) {
    return 0;
  }
}

function summarizeServer(server) {
  let lines = [];
  let logBytes = 0;
  try {
    const stats = fs.statSync(server.logPath);
    logBytes = stats.size;
    lines = fs.readFileSync(server.logPath, 'utf8').split(/\r?\n/);
  } catch (_) {}
  const passwordAccepted = countMatches(lines, /Accepted password for /i);
  const tcpConnectionsAccepted = connectionPortSet(lines,
    /\bConnection from \S+ port (\d+) on /i).size;
  const tcpConnectionsClosed = connectionPortSet(lines,
    /\bConnection closed by .* port (\d+)\b/i).size;
  return {
    running: !server.spawnFailed && server.child.exitCode === null && server.child.signalCode === null,
    stopped: server.stopped,
    exitCode: server.child.exitCode,
    signal: server.child.signalCode,
    logPresent: logBytes > 0,
    logBytes,
    listenerStarts: countMatches(lines, /Server listening on /i),
    tcpConnectionsAccepted,
    tcpConnectionsClosed,
    tcpConnectionsOpen: countOpenTcpConnections(server.port),
    connections: summarizeConnections(lines),
    serverBannerEmitted: countMatches(lines, /Local version string SSH-/i),
    clientBannerReceived: countMatches(lines, /Remote protocol version /i),
    keyExchangeStarted: countMatches(lines, /SSH2_MSG_KEXINIT|kex: algorithm:/i),
    passwordAccepted,
    passwordRejected: countMatches(lines, /Failed password|authentication failure/i),
    publicKeyAccepted: countMatches(lines, /Accepted publickey/i),
    // OpenSSH records the requested command in its DEBUG3 audit entry on a
    // separate line from "Starting session: command". Count only this
    // fixture's random marker command, not arbitrary remote commands.
    markerCommands: server.markerToken
      ? countMatches(lines, new RegExp(`mm_audit_run_command entering command [^\\r\\n]*${server.markerToken}`))
      : 0,
    sessionStarts: countMatches(lines, /Starting session:/i),
    shellSessions: countMatches(lines, /Starting session: shell(?: on \S+)? for /i),
    commandSessions: countMatches(lines, /Starting session: command(?: on \S+)? for /i),
    sftpRequests: countMatches(lines, /subsystem request for sftp/i),
    sftpSessions: countMatches(lines, /Starting session: subsystem ['"]sftp['"]/i),
    forwardingRequests: countMatches(lines, /direct-tcpip|forwarded-tcpip|tcpip-forward/i),
  };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForListener(server, address, port) {
  const deadline = Date.now() + SESSION_WAIT_MS;
  while (Date.now() < deadline) {
    if (server.spawnFailed || server.child.exitCode !== null || server.child.signalCode !== null) {
      throw new Error('temporary sshd exited before it began listening');
    }
    try {
      const log = fs.readFileSync(server.logPath, 'utf8');
      if (log.includes(`Server listening on ${address} port ${port}`)) return;
    } catch (_) {}
    await delay(50);
  }
  throw new Error('temporary sshd did not become ready on its requested address and port');
}

function waitForChild(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      child.removeListener('close', finish);
      resolve();
    };
    child.once('close', finish);
    const timer = setTimeout(finish, timeoutMs);
    if (child.exitCode !== null || child.signalCode !== null) finish();
  });
}

async function stopChild(server) {
  if (server.spawnFailed) return;
  const child = server.child;
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {
    try { child.kill('SIGTERM'); } catch (_) {}
  }
  await waitForChild(child, 2000);
  if (child.exitCode === null && child.signalCode === null) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {
      try { child.kill('SIGKILL'); } catch (_) {}
    }
    await waitForChild(child, 2000);
  }
  if (child.exitCode === null && child.signalCode === null) {
    throw new Error('temporary sshd process did not exit');
  }
}

function processIdsForUid(uid) {
  const result = [];
  let entries;
  try { entries = fs.readdirSync('/proc'); } catch (_) { return result; }
  for (const entry of entries) {
    if (!/^\d+$/.test(entry)) continue;
    const pid = Number(entry);
    if (pid === process.pid) continue;
    try {
      const status = fs.readFileSync(`/proc/${entry}/status`, 'utf8');
      const processUid = Number(status.match(/^Uid:\s+(\d+)/m)?.[1]);
      const state = status.match(/^State:\s+(\w+)/m)?.[1];
      if (processUid === uid && state !== 'Z' && state !== 'X') result.push(pid);
    } catch (_) {}
  }
  return result;
}

async function stopAccountProcesses(uid) {
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    for (const pid of processIdsForUid(uid)) {
      try { process.kill(pid, signal); } catch (_) {}
    }
    const deadline = Date.now() + (signal === 'SIGTERM' ? 700 : 1500);
    while (processIdsForUid(uid).length && Date.now() < deadline) await delay(50);
    if (!processIdsForUid(uid).length) return;
  }
  if (processIdsForUid(uid).length) {
    throw new Error('temporary SSH account still has a live process after daemon shutdown');
  }
}

function cleanupAccount(state) {
  const account = state.account;
  if (!account) return;
  const passwdEntry = getent('passwd', account.username);
  let gid = account.gid;
  if (passwdEntry) {
    const fields = passwdEntry.split(':');
    const uid = Number(fields[2]);
    gid = Number(fields[3]);
    if (fields[0] !== account.username || fields[5] !== account.home || fields[6] !== account.shell ||
        !Number.isInteger(uid) || uid <= 0 || !Number.isInteger(gid) || gid <= 0 ||
        (account.uid !== null && uid !== account.uid) || (account.gid !== null && gid !== account.gid)) {
      throw new Error('refusing to remove a temporary SSH account whose identity changed');
    }
    return stopAccountProcesses(uid).then(() => {
      const deleted = spawnSync(executableOnPath('userdel'), [account.username], {
        encoding: 'utf8', timeout: 10000,
      });
      if (deleted.error || deleted.status !== 0) {
        throw new Error('could not remove the temporary SSH account');
      }
      cleanupGroup(account.username, gid);
    });
  }
  return cleanupGroup(account.username, gid);
}

function cleanupGroup(username, expectedGid) {
  const entry = getent('group', username);
  if (!entry) return;
  const fields = entry.split(':');
  const gid = Number(fields[2]);
  const members = (fields[3] || '').split(',').filter(Boolean);
  if (fields[0] !== username || !Number.isInteger(gid) || gid <= 0 ||
      (expectedGid !== null && expectedGid !== undefined && gid !== expectedGid) || members.length !== 0) {
    throw new Error('refusing to remove a temporary SSH group whose identity or membership changed');
  }
  const deleted = spawnSync(executableOnPath('groupdel'), [username], {
    encoding: 'utf8', timeout: 10000,
  });
  if (deleted.error || deleted.status !== 0) throw new Error('could not remove the temporary SSH group');
}

async function startOneServer({ index, port, bindAddress, username, account, root, servers, includeStty }) {
  const serverRoot = path.join(root, `server-${index}`);
  fs.mkdirSync(serverRoot, { mode: 0o700 });
  fs.chmodSync(serverRoot, 0o700);
  const jailRoot = createJail(serverRoot, account, { includeStty });
  const hostKey = generateHostKey(serverRoot);
  const configPath = configFor({
    serverRoot, bindAddress, port, username, hostKey: hostKey.privateKey, jailRoot,
  });
  const logPath = path.join(serverRoot, 'sshd.log');
  const logFd = fs.openSync(logPath, 'a', 0o600);
  let child;
  try {
    child = spawn(SSHD, ['-D', '-e', '-f', configPath], {
      cwd: serverRoot,
      env: process.env,
      stdio: ['ignore', logFd, logFd],
      detached: true,
    });
  } catch (_) {
    fs.closeSync(logFd);
    throw new Error('could not start the isolated temporary sshd');
  }
  let logClosed = false;
  let spawnFailed = false;
  const closeLog = () => {
    if (logClosed) return;
    logClosed = true;
    try { fs.closeSync(logFd); } catch (_) {}
  };
  child.once('error', () => { spawnFailed = true; closeLog(); });
  child.once('close', closeLog);
  const server = {
    address: bindAddress,
    port,
    hostPublicKey: hostKey.publicKey,
    hostFingerprint: hostKey.fingerprint,
    logPath,
    child,
    stopped: false,
    get spawnFailed() { return spawnFailed; },
    summary() { return summarizeServer(server); },
  };
  servers.push(server);
  await waitForListener(server, bindAddress, port);
  return server;
}

async function startOneTmuxServer({ port, bindAddress, username, account, root, tmuxTmpDir }) {
  const serverRoot = path.join(root, 'server');
  fs.mkdirSync(serverRoot, { mode: 0o700 });
  fs.chmodSync(serverRoot, 0o700);
  const hostKey = generateHostKey(serverRoot);
  const configPath = configForTmux({
    serverRoot,
    bindAddress,
    port,
    username,
    hostKey: hostKey.privateKey,
    tmuxTmpDir,
  });
  const logPath = path.join(serverRoot, 'sshd.log');
  const logFd = fs.openSync(logPath, 'a', 0o600);
  let child;
  try {
    child = spawn(SSHD, ['-D', '-e', '-f', configPath], {
      cwd: serverRoot,
      env: process.env,
      stdio: ['ignore', logFd, logFd],
      detached: true,
    });
  } catch (_) {
    fs.closeSync(logFd);
    throw new Error('could not start the isolated tmux SSHD');
  }
  let logClosed = false;
  let spawnFailed = false;
  const closeLog = () => {
    if (logClosed) return;
    logClosed = true;
    try { fs.closeSync(logFd); } catch (_) {}
  };
  child.once('error', () => { spawnFailed = true; closeLog(); });
  child.once('close', closeLog);
  const tmuxSocketPath = path.join(
    tmuxTmpDir,
    `tmux-${account.uid}`,
    'default',
  );
  const server = {
    address: bindAddress,
    port,
    username,
    uid: account.uid,
    gid: account.gid,
    home: account.home,
    tmuxTmpDir,
    tmuxSocketPath,
    hostPublicKey: hostKey.publicKey,
    hostFingerprint: hostKey.fingerprint,
    logPath,
    child,
    stopped: false,
    get spawnFailed() { return spawnFailed; },
    summary() { return summarizeServer(server); },
    tmuxSnapshot() { return tmuxSnapshot(server); },
  };
  try {
    await waitForListener(server, bindAddress, port);
  } catch (error) {
    try { await stopChild(server); } catch (_) {}
    throw error;
  }
  return server;
}

function installAuthorizedKeyLine({ authorizedKeyLine, account }) {
  const homePath = account.home;
  const sshDirectoryPath = path.join(homePath, '.ssh');
  const authorizedKeysPath = path.join(sshDirectoryPath, 'authorized_keys');
  fs.mkdirSync(homePath, { mode: 0o700 });
  fs.chownSync(homePath, account.uid, account.gid);
  fs.chmodSync(homePath, 0o700);
  fs.mkdirSync(sshDirectoryPath, { mode: 0o700 });
  fs.chownSync(sshDirectoryPath, account.uid, account.gid);
  fs.chmodSync(sshDirectoryPath, 0o700);
  fs.writeFileSync(authorizedKeysPath, `${authorizedKeyLine}\n`, { mode: 0o600 });
  fs.chownSync(authorizedKeysPath, account.uid, account.gid);
  fs.chmodSync(authorizedKeysPath, 0o600);
  const parsed = spawnSync(SSH_KEYGEN, ['-lf', authorizedKeysPath], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (parsed.error || parsed.status !== 0 ||
      !/^256 SHA256:[A-Za-z0-9+/]+(?:=)?(?: |$)/.test((parsed.stdout || '').trim())) {
    throw new Error('authorized public key is not a valid ECDSA P-256 identity');
  }
  return { homePath, sshDirectoryPath, authorizedKeysPath };
}

async function startOnePublicKeyServer({ port, username, root, markerToken, servers }) {
  const serverRoot = path.join(root, 'server');
  fs.mkdirSync(serverRoot, { mode: 0o700 });
  fs.chmodSync(serverRoot, 0o700);
  const hostKey = generateHostKey(serverRoot);
  const configPath = configForPublicKey({
    serverRoot,
    port,
    username,
    hostKey: hostKey.privateKey,
  });
  const logPath = path.join(serverRoot, 'sshd.log');
  const logFd = fs.openSync(logPath, 'a', 0o600);
  let child;
  try {
    child = spawn(SSHD, ['-D', '-e', '-f', configPath], {
      cwd: serverRoot,
      env: process.env,
      stdio: ['ignore', logFd, logFd],
      detached: true,
    });
  } catch (_) {
    fs.closeSync(logFd);
    throw new Error('could not start the isolated public-key SSHD');
  }
  let logClosed = false;
  let spawnFailed = false;
  const closeLog = () => {
    if (logClosed) return;
    logClosed = true;
    try { fs.closeSync(logFd); } catch (_) {}
  };
  child.once('error', () => { spawnFailed = true; closeLog(); });
  child.once('close', closeLog);
  const server = {
    address: '127.0.0.1',
    port,
    username,
    hostPublicKey: hostKey.publicKey,
    hostFingerprint: hostKey.fingerprint,
    markerToken,
    logPath,
    child,
    stopped: false,
    get spawnFailed() { return spawnFailed; },
    summary() { return summarizeServer(server); },
  };
  servers.push(server);
  await waitForListener(server, '127.0.0.1', port);
  return server;
}

function tmuxSnapshot(server) {
  if (!server || typeof server.tmuxSocketPath !== 'string' ||
      !path.isAbsolute(server.tmuxSocketPath)) {
    throw new Error('tmux state probe requires a tmux SSH fixture server');
  }
  if (!fs.existsSync(server.tmuxSocketPath)) {
    return {
      serverRunning: false,
      sessionCount: 0,
      clientCount: 0,
      sessions: [],
      clients: [],
    };
  }
  const runuser = executableOnPath('runuser');
  if (!runuser || !fs.existsSync(TMUX)) {
    throw new Error('tmux state probe runtime is unavailable');
  }
  const env = { ...process.env, TMUX_TMPDIR: server.tmuxTmpDir };
  delete env.TMUX;
  const runTmux = (args) => spawnSync(runuser, [
    '-u', server.username,
    '--',
    TMUX,
    '-S', server.tmuxSocketPath,
    ...args,
  ], {
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    env,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const sessionResult = runTmux([
    'list-sessions', '-F',
    '#{session_id}\t#{session_name}\t#{session_attached}\t#{session_created}',
  ]);
  if (sessionResult.error || sessionResult.status !== 0) {
    throw new Error('tmux state probe could not enumerate fixture sessions');
  }
  const clientResult = runTmux([
    'list-clients', '-F',
    '#{client_session}\t#{client_pid}',
  ]);
  if (clientResult.error || clientResult.status !== 0) {
    throw new Error('tmux state probe could not enumerate fixture clients');
  }
  const sessions = (sessionResult.stdout || '').split(/\r?\n/).filter(Boolean)
    .map((line) => {
      const [sessionId, name, attached, created] = line.split('\t');
      return {
        sessionId,
        name,
        attachedClientCount: Number(attached),
        createdAt: Number(created),
      };
    });
  const clients = (clientResult.stdout || '').split(/\r?\n/).filter(Boolean)
    .map((line) => {
      const [sessionName, processId] = line.split('\t');
      const session = sessions.find((item) => item.name === sessionName);
      return {
        sessionName,
        sessionId: session?.sessionId,
        processId: Number(processId),
      };
    });
  if (sessions.some((session) => !session.sessionId || !session.name ||
      !Number.isInteger(session.attachedClientCount) ||
      !Number.isInteger(session.createdAt)) ||
      clients.some((client) => !client.sessionName || !client.sessionId ||
        !Number.isInteger(client.processId) || client.processId <= 0)) {
    throw new Error('tmux state probe returned malformed fixture state');
  }
  return {
    serverRunning: true,
    sessionCount: sessions.length,
    clientCount: clients.length,
    sessions,
    clients,
  };
}

function tmuxPrivacyMarkerSnapshot(server, sessionName, commandMarker, outputMarker) {
  if (!server || typeof server.tmuxSocketPath !== 'string' ||
      !path.isAbsolute(server.tmuxSocketPath) ||
      typeof sessionName !== 'string' || !/^atermius_[0-9a-f]{32}$/.test(sessionName) ||
      typeof commandMarker !== 'string' ||
      !/^tmux-command-marker-[0-9a-f-]{36}$/.test(commandMarker) ||
      typeof outputMarker !== 'string' ||
      !/^tmux-output-marker-[0-9a-f-]{36}$/.test(outputMarker)) {
    throw new Error('tmux marker probe requires a fixture session and run-scoped marker');
  }
  if (!fs.existsSync(server.tmuxSocketPath)) {
    throw new Error('tmux marker probe requires an active fixture session');
  }
  const runuser = executableOnPath('runuser');
  if (!runuser || !fs.existsSync(TMUX)) {
    throw new Error('tmux marker probe runtime is unavailable');
  }
  const env = { ...process.env, TMUX_TMPDIR: server.tmuxTmpDir };
  delete env.TMUX;
  const paneList = spawnSync(runuser, [
    '-u', server.username,
    '--',
    TMUX,
    '-S', server.tmuxSocketPath,
    'list-panes', '-s', '-t', `=${sessionName}`, '-F', '#{pane_id}',
  ], {
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    env,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const paneIds = (paneList.stdout || '').trim().split(/\r?\n/).filter(Boolean);
  if (paneList.error || paneList.status !== 0 || paneIds.length !== 1 ||
      !/^%\d+$/.test(paneIds[0])) {
    throw new Error('tmux privacy marker pane could not be resolved');
  }
  // Both strings have strict safe alphabets. The command's shape is fixed so
  // the fixture cannot turn this probe into an arbitrary remote command.
  const command = `printf '%s\\n' '${outputMarker}' # ${commandMarker}`;
  // send-keys and capture-pane require a pane target. Resolve its ID from the
  // exact session so a system tmux base-index setting cannot break the probe.
  const paneTarget = paneIds[0];
  const send = spawnSync(runuser, [
    '-u', server.username,
    '--',
    TMUX,
    '-S', server.tmuxSocketPath,
    'send-keys', '-t', paneTarget, command, 'Enter',
  ], {
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    env,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  if (send.error || send.status !== 0) {
    throw new Error('tmux privacy marker could not be sent to the fixture session');
  }
  const capture = spawnSync(runuser, [
    '-u', server.username,
    '--',
    TMUX,
    '-S', server.tmuxSocketPath,
    // Include recent scrollback because the echoed command may wrap and leave
    // the visible screen before the corresponding output canary is captured.
    'capture-pane', '-J', '-p', '-S', '-1000', '-t', paneTarget,
  ], {
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    env,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (capture.error || capture.status !== 0) {
    throw new Error('tmux privacy marker state could not be inspected');
  }
  return {
    commandMarkerVisible: (capture.stdout || '').includes(commandMarker),
    outputMarkerVisible: (capture.stdout || '').includes(outputMarker),
  };
}

async function startTmuxSshFixture(options) {
  if (!options || !Number.isInteger(options.port)) {
    throw new Error('tmux SSH fixture requires one reserved TCP port');
  }
  const validated = validateOptions({
    bindAddress: options.bindAddress,
    ports: [options.port],
    username: options.username,
    password: options.password,
  });
  requireEnvironment({ tmux: true });
  const tempParent = stickyFixtureTempParent();
  const root = fs.mkdtempSync(path.join(tempParent, 'atermius-workspace-tmux-'));
  fs.chmodSync(root, 0o711);
  const tmuxTmpDir = path.join(root, 'tmux');
  fs.mkdirSync(tmuxTmpDir, { mode: 0o1777 });
  fs.chmodSync(tmuxTmpDir, 0o1777);
  const accountHome = `/home/${validated.username}`;
  const state = { account: null };
  let server = null;
  let closePromise = null;
  let cleanupPromise = null;
  let closed = false;
  let cleaned = false;

  async function close() {
    if (closed) return;
    if (closePromise) return closePromise;
    closePromise = (async () => {
      const errors = [];
      if (server) {
        try {
          await stopChild(server);
          server.stopped = true;
        } catch (_) {
          errors.push('tmux SSHD stop failed');
        }
      }
      if (server && !server.spawnFailed && server.child.exitCode === null &&
          server.child.signalCode === null) {
        throw new Error('tmux SSHD remains live; fixture teardown stopped safely');
      }
      if (state.account?.uid !== null && state.account?.uid !== undefined) {
        try { await stopAccountProcesses(state.account.uid); } catch (_) {
          errors.push('tmux fixture process cleanup failed');
        }
      }
      if (errors.length) throw new Error(errors.join('; '));
      closed = true;
    })();
    try { await closePromise; } catch (error) {
      closePromise = null;
      throw error;
    }
  }

  async function cleanup() {
    if (cleaned) return;
    if (cleanupPromise) return cleanupPromise;
    cleanupPromise = (async () => {
      await close();
      const errors = [];
      let accountCleaned = false;
      try {
        await cleanupAccount(state);
        accountCleaned = true;
      } catch (_) {
        errors.push('tmux fixture account cleanup failed');
      }
      try {
        if (accountCleaned && accountHome === `/home/${validated.username}` &&
            fs.existsSync(accountHome)) {
          fs.rmSync(accountHome, { recursive: true, force: true });
        }
      } catch (_) {
        errors.push('tmux fixture account home cleanup failed');
      }
      try {
        const expectedPrefix = path.join(tempParent, 'atermius-workspace-tmux-');
        if (!root.startsWith(expectedPrefix) || path.dirname(root) !== tempParent) {
          throw new Error('refusing to remove a path outside the private tmux fixture namespace');
        }
        fs.rmSync(root, { recursive: true, force: true });
      } catch (_) {
        errors.push('tmux fixture temporary directory cleanup failed');
      }
      if (errors.length) throw new Error(errors.join('; '));
      cleaned = true;
      process.removeListener('SIGINT', onSigint);
      process.removeListener('SIGTERM', onSigterm);
    })();
    try { await cleanupPromise; } catch (error) {
      cleanupPromise = null;
      throw error;
    }
  }

  let terminationSignal = null;
  const handleTermination = (signal) => {
    if (terminationSignal) return;
    terminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    void cleanup().catch(() => {
      process.exitCode = 1;
      process.stderr.write('tmux SSH fixture cleanup failed during signal handling\n');
    });
  };
  const onSigint = () => handleTermination('SIGINT');
  const onSigterm = () => handleTermination('SIGTERM');
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);

  try {
    createAccount(validated.username, validated.password, state, {
      homePath: accountHome,
    });
    fs.mkdirSync(accountHome, { mode: 0o700 });
    fs.chownSync(accountHome, state.account.uid, state.account.gid);
    fs.chmodSync(accountHome, 0o700);
    server = await startOneTmuxServer({
      port: validated.ports[0],
      bindAddress: validated.bindAddress,
      username: validated.username,
      account: state.account,
      root,
      tmuxTmpDir,
    });
    assertTmuxSocketClear(server);
  } catch (error) {
    try { await cleanup(); } catch (_) {
      throw new Error(`${error.message}; tmux fixture cleanup also failed`);
    }
    throw error;
  }

  return {
    bindAddress: validated.bindAddress,
    port: validated.ports[0],
    username: validated.username,
    password: validated.password,
    server,
    status() { return { closed, cleaned }; },
    tmuxSnapshot() { return tmuxSnapshot(server); },
    tmuxPrivacyMarkerSnapshot(sessionName, commandMarker, outputMarker) {
      return tmuxPrivacyMarkerSnapshot(
        server, sessionName, commandMarker, outputMarker,
      );
    },
    close,
    cleanup,
  };
}

function assertTmuxSocketClear(server) {
  if (fs.existsSync(server.tmuxSocketPath)) {
    throw new Error('tmux SSH fixture unexpectedly reused an existing tmux socket');
  }
}

async function startSshFixture(options) {
  const validated = validateOptions(options);
  requireEnvironment();
  const tempParent = secureFixtureTempParent();
  const root = fs.mkdtempSync(path.join(tempParent, 'atermius-workspace-ssh-'));
  fs.chmodSync(root, 0o700);
  const state = { account: null };
  const servers = [];
  let closePromise = null;
  let cleanupPromise = null;
  let closed = false;
  let cleaned = false;

  async function close() {
    if (closed) return;
    if (closePromise) return closePromise;
    closePromise = (async () => {
      const errors = [];
      for (const server of [...servers].reverse()) {
        try {
          await stopChild(server);
          server.stopped = true;
        } catch (_) { errors.push('sshd stop failed'); }
      }
      if (servers.some((server) => !server.spawnFailed && server.child.exitCode === null && server.child.signalCode === null)) {
        throw new Error('temporary sshd processes remain live; fixture teardown stopped safely');
      }
      if (state.account?.uid !== null && state.account?.uid !== undefined) {
        try { await stopAccountProcesses(state.account.uid); } catch (_) { errors.push('fixture process cleanup failed'); }
      }
      if (errors.length) throw new Error(errors.join('; '));
      closed = true;
    })();
    try { await closePromise; } catch (error) { closePromise = null; throw error; }
  }

  async function cleanup() {
    if (cleaned) return;
    if (cleanupPromise) return cleanupPromise;
    cleanupPromise = (async () => {
      await close();
      const errors = [];
      try { await cleanupAccount(state); } catch (_) { errors.push('fixture account cleanup failed'); }
      try {
        const expectedPrefix = path.join(tempParent, 'atermius-workspace-ssh-');
        if (!root.startsWith(expectedPrefix) || path.dirname(root) !== tempParent) {
          throw new Error('refusing to remove a path outside the private fixture namespace');
        }
        fs.rmSync(root, { recursive: true, force: true });
      } catch (_) { errors.push('fixture temporary directory cleanup failed'); }
      if (errors.length) throw new Error(errors.join('; '));
      cleaned = true;
      process.removeListener('SIGINT', onSigint);
      process.removeListener('SIGTERM', onSigterm);
    })();
    try { await cleanupPromise; } catch (error) { cleanupPromise = null; throw error; }
  }

  let terminationSignal = null;
  const handleTermination = (signal) => {
    if (terminationSignal) return;
    terminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    void cleanup().catch(() => {
      process.exitCode = 1;
      process.stderr.write('isolated SSH fixture cleanup failed during signal handling\n');
    });
  };
  const onSigint = () => handleTermination('SIGINT');
  const onSigterm = () => handleTermination('SIGTERM');
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);

  try {
    createAccount(validated.username, validated.password, state);
    for (let index = 0; index < validated.ports.length; index += 1) {
      const account = state.account;
      await startOneServer({
        index: index + 1,
        port: validated.ports[index],
        bindAddress: validated.bindAddress,
        username: validated.username,
        account,
        root,
        servers,
        includeStty: validated.includeStty,
      });
    }
  } catch (error) {
    try {
      await cleanup();
    } catch (_) {
      throw new Error(`${error.message}; temporary SSH fixture cleanup also failed`);
    }
    throw error;
  }

  return {
    bindAddress: validated.bindAddress,
    ports: [...validated.ports],
    username: validated.username,
    password: validated.password,
    servers,
    status() { return { closed, cleaned }; },
    close,
    cleanup,
  };
}

async function startPublicKeySshFixture(options = {}) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new Error('public-key SSH fixture options must be an object');
  }
  if (options.bindAddress !== undefined && options.bindAddress !== '127.0.0.1') {
    throw new Error('public-key SSH fixture can bind only to 127.0.0.1');
  }
  const allowedOptions = new Set(['bindAddress', 'username', 'authorizedKeyLine']);
  if (Object.keys(options).some((key) => !allowedOptions.has(key))) {
    throw new Error('public-key SSH fixture accepts only bindAddress, username, and authorizedKeyLine options');
  }
  const authorizedKeyLine = options.authorizedKeyLine;
  if (typeof authorizedKeyLine !== 'string' || authorizedKeyLine.includes('\n') ||
      authorizedKeyLine.includes('\r') ||
      !/^ecdsa-sha2-nistp256 [A-Za-z0-9+/]+={0,2}(?: [^\s]{1,128})?$/.test(authorizedKeyLine)) {
    throw new Error('authorizedKeyLine must contain one ECDSA P-256 public key line');
  }
  const username = options.username || `atermius-ws-${crypto.randomBytes(8).toString('hex')}`;
  if (typeof username !== 'string' || !/^atermius-ws-[a-f0-9]{16}$/.test(username)) {
    throw new Error('username must use the run-specific fixture account format');
  }
  requireEnvironment();
  const port = await reserveLoopbackPort();
  const tempParent = secureFixtureTempParent();
  const root = fs.mkdtempSync(path.join(tempParent, 'atermius-workspace-ssh-key-'));
  fs.chmodSync(root, 0o700);
  const accountHome = `/home/${username}`;
  const state = { account: null };
  const servers = [];
  const markerToken = `atermius-key-marker-${crypto.randomBytes(16).toString('hex')}`;
  let credentialPaths = null;
  let closePromise = null;
  let cleanupPromise = null;
  let closed = false;
  let cleaned = false;

  async function close() {
    if (closed) return;
    if (closePromise) return closePromise;
    closePromise = (async () => {
      const errors = [];
      for (const server of [...servers].reverse()) {
        try {
          await stopChild(server);
          server.stopped = true;
        } catch (_) { errors.push('public-key SSHD stop failed'); }
      }
      if (servers.some((server) => !server.spawnFailed &&
          server.child.exitCode === null && server.child.signalCode === null)) {
        throw new Error('public-key SSHD remains live; fixture teardown stopped safely');
      }
      if (state.account?.uid !== null && state.account?.uid !== undefined) {
        try { await stopAccountProcesses(state.account.uid); } catch (_) {
          errors.push('public-key fixture process cleanup failed');
        }
      }
      if (errors.length) throw new Error(errors.join('; '));
      closed = true;
    })();
    try { await closePromise; } catch (error) {
      closePromise = null;
      throw error;
    }
  }

  async function cleanup() {
    if (cleaned) return;
    if (cleanupPromise) return cleanupPromise;
    cleanupPromise = (async () => {
      await close();
      const errors = [];
      let accountCleaned = false;
      try {
        await cleanupAccount(state);
        accountCleaned = true;
      } catch (_) { errors.push('public-key fixture account cleanup failed'); }
      try {
        if (accountCleaned && accountHome === `/home/${username}` &&
            fs.existsSync(accountHome)) {
          fs.rmSync(accountHome, { recursive: true, force: true });
        }
      } catch (_) { errors.push('public-key fixture account home cleanup failed'); }
      try {
        const expectedPrefix = path.join(tempParent, 'atermius-workspace-ssh-key-');
        if (!root.startsWith(expectedPrefix) || path.dirname(root) !== tempParent) {
          throw new Error('refusing to remove a path outside the public-key fixture namespace');
        }
        fs.rmSync(root, { recursive: true, force: true });
      } catch (_) { errors.push('public-key fixture temporary directory cleanup failed'); }
      if (errors.length) throw new Error(errors.join('; '));
      cleaned = true;
      process.removeListener('SIGINT', onSigint);
      process.removeListener('SIGTERM', onSigterm);
    })();
    try { await cleanupPromise; } catch (error) {
      cleanupPromise = null;
      throw error;
    }
  }

  let terminationSignal = null;
  const handleTermination = (signal) => {
    if (terminationSignal) return;
    terminationSignal = signal;
    process.exitCode = signal === 'SIGINT' ? 130 : 143;
    void cleanup().catch(() => {
      process.exitCode = 1;
      process.stderr.write('public-key SSH fixture cleanup failed during signal handling\n');
    });
  };
  const onSigint = () => handleTermination('SIGINT');
  const onSigterm = () => handleTermination('SIGTERM');
  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);

  try {
    // OpenSSH classifies a Unix account with a locked (!) password as invalid
    // for public-key login on some Linux builds when UsePAM is disabled. Keep
    // a random throwaway password hash in the system account database while
    // making the daemon's only configured authentication method publickey.
    const unexposedAccountPassword = crypto.randomBytes(48).toString('base64url');
    createAccount(username, unexposedAccountPassword, state, { homePath: accountHome });
    credentialPaths = installAuthorizedKeyLine({ authorizedKeyLine, account: state.account });
    await startOnePublicKeyServer({ port, username, root, markerToken, servers });
  } catch (error) {
    try { await cleanup(); } catch (_) {
      throw new Error(`${error.message}; public-key fixture cleanup also failed`);
    }
    throw error;
  }

  const server = servers[0];
  return {
    authMode: 'publickey',
    bindAddress: '127.0.0.1',
    port,
    username,
    hostFingerprint: server.hostFingerprint,
    homePath: credentialPaths.homePath,
    sshDirectoryPath: credentialPaths.sshDirectoryPath,
    authorizedKeysPath: credentialPaths.authorizedKeysPath,
    tempRoot: root,
    markerToken,
    server,
    summary() { return server.summary(); },
    status() { return { closed, cleaned }; },
    close,
    cleanup,
  };
}

module.exports = {
  startSshFixture,
  startPublicKeySshFixture,
  startTmuxSshFixture,
  tmuxSnapshot,
  tmuxPrivacyMarkerSnapshot,
};
