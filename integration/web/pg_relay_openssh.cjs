/*
 * PG-RELAY-01: exercise the PostgreSQL-backed Relay data plane across nodes.
 *
 * Node A issues every short-lived ticket. Node B consumes it on the exact
 * WebSocket route, which is bridged to the OpenSSH client as a byte stream.
 * The disposable SSHD is bound to one private address and one configured
 * port. The harness performs an actual shell command and an SFTP upload /
 * download, then verifies a consumed ticket cannot be replayed on node B.
 * No credentials or ticket values are emitted.
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { startSshFixture } = require('./ssh_fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const NODE_A = process.env.ATERMIUS_PG_RELAY_NODE_A_URL;
const NODE_B = process.env.ATERMIUS_PG_RELAY_NODE_B_URL;
const ORIGIN = process.env.ATERMIUS_PG_RELAY_PUBLIC_ORIGIN;
const ACCESS_TOKEN = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
const DEVICE_ID = process.env.ATERMIUS_PG_RELAY_DEVICE_ID;
const TARGET_HOST = process.env.ATERMIUS_PG_RELAY_TARGET_HOST;
const TARGET_PORT = Number(process.env.ATERMIUS_PG_RELAY_TARGET_PORT);
const SSH = process.env.SSH_PATH || '/usr/bin/ssh';
const SFTP = process.env.SFTP_PATH || '/usr/bin/sftp';
const RUN_ID = crypto.randomBytes(8).toString('hex');
const PROXY_DIAGNOSTICS = process.env.ATERMIUS_PG_RELAY_PROXY_DIAGNOSTICS === '1';
const SSH_LOG_LEVEL = PROXY_DIAGNOSTICS ? 'DEBUG2' : 'ERROR';
const SENSITIVE = [ACCESS_TOKEN].filter(Boolean);
let stage = 'preflight';
let failureDetails = null;

function assertThat(value, message) {
  if (!value) throw new Error(message);
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function parseLoopbackHttp(value) {
  let url;
  try { url = new URL(value); } catch (_) { return null; }
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port) return null;
  return { hostname: url.hostname, port: Number(url.port), origin: url.origin };
}

function parseOrigin(value) {
  try {
    const url = new URL(value);
    return url.origin === value ? value : null;
  } catch (_) { return null; }
}

function httpJson(urlValue, { method = 'GET', headers = {}, body } = {}) {
  const url = new URL(urlValue);
  return new Promise((resolve, reject) => {
    const request = require('node:http').request({
      hostname: url.hostname,
      port: Number(url.port || 80),
      method,
      path: `${url.pathname}${url.search}`,
      headers,
      timeout: 8000,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (_) {}
        resolve({ status: response.statusCode || 0, json: parsed });
      });
    });
    request.on('timeout', () => request.destroy(new Error('timeout')));
    request.on('error', reject);
    if (body) request.write(body);
    request.end();
  });
}

async function requestTicket() {
  const response = await httpJson(`${NODE_A}/api/v1/relay/tickets`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${ACCESS_TOKEN}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      device_id: DEVICE_ID,
      target_host: TARGET_HOST,
      target_port: TARGET_PORT,
    }),
  });
  const ticket = response.json && response.json.ticket;
  const expiry = Date.parse(response.json?.expires_at || '');
  const ticketFields = Object.keys(response.json || {}).sort().join(',');
  assertThat(response.status === 200 &&
    ticketFields === 'connect_path,expires_at,ticket' &&
    response.json.connect_path === '/relay/v1/connect' &&
    Number.isFinite(expiry) && expiry > Date.now() && expiry <= Date.now() + 60000 &&
    typeof ticket === 'string' && /^[A-Za-z0-9_-]{43}$/.test(ticket),
  'node A did not issue a valid short-lived Relay ticket');
  return ticket;
}

class SocketReader {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.ended = false;
    this.error = null;
    this.waiters = [];
    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.wake();
    });
    socket.on('end', () => { this.ended = true; this.wake(); });
    socket.on('close', () => { this.ended = true; this.wake(); });
    socket.on('error', (error) => { this.error = error; this.ended = true; this.wake(); });
  }

  wake() {
    for (const resolve of this.waiters.splice(0)) resolve();
  }

  async waitForData(deadline) {
    if (this.error) throw new Error('Relay WebSocket transport failed');
    if (this.ended) throw new Error('Relay WebSocket closed');
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('Relay WebSocket response timed out');
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter !== onData);
        reject(new Error('Relay WebSocket response timed out'));
      }, remaining);
      const onData = () => { clearTimeout(timer); resolve(); };
      this.waiters.push(onData);
    });
  }

  async readExact(size, timeoutMs = 10000) {
    const deadline = Date.now() + timeoutMs;
    while (this.buffer.length < size) await this.waitForData(deadline);
    const value = this.buffer.subarray(0, size);
    this.buffer = this.buffer.subarray(size);
    return value;
  }

  async readHeaders(timeoutMs = 10000) {
    const delimiter = Buffer.from('\r\n\r\n');
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const index = this.buffer.indexOf(delimiter);
      if (index >= 0) {
        const value = this.buffer.subarray(0, index + delimiter.length).toString('latin1');
        this.buffer = this.buffer.subarray(index + delimiter.length);
        return value;
      }
      if (this.buffer.length > 16384) throw new Error('Relay WebSocket headers exceeded the bound');
      await this.waitForData(deadline);
    }
  }

  async readFrame(timeoutMs = 10000) {
    const first = (await this.readExact(2, timeoutMs));
    const opcode = first[0] & 0x0f;
    const masked = Boolean(first[1] & 0x80);
    let size = first[1] & 0x7f;
    if (size === 126) size = (await this.readExact(2, timeoutMs)).readUInt16BE(0);
    else if (size === 127) {
      const wide = (await this.readExact(8, timeoutMs)).readBigUInt64BE(0);
      if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Relay frame exceeded the bound');
      size = Number(wide);
    }
    if (size > 1024 * 1024) throw new Error('Relay frame exceeded the acceptance bound');
    const mask = masked ? await this.readExact(4, timeoutMs) : null;
    const payload = Buffer.from(await this.readExact(size, timeoutMs));
    if (mask) for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
    return { opcode, payload };
  }
}

function sendFrame(socket, opcode, payload) {
  const bytes = Buffer.from(payload);
  const mask = crypto.randomBytes(4);
  const first = Buffer.from([0x80 | opcode]);
  let length;
  if (bytes.length < 126) length = Buffer.from([0x80 | bytes.length]);
  else if (bytes.length <= 0xffff) {
    // `first` already contains the FIN/opcode byte, so this header starts
    // with the masked-length byte followed by the two-byte extended length.
    length = Buffer.alloc(3);
    length[0] = 0x80 | 126;
    length.writeUInt16BE(bytes.length, 1);
  } else {
    length = Buffer.alloc(9);
    length[0] = 0x80 | 127;
    length.writeBigUInt64BE(BigInt(bytes.length), 1);
  }
  const masked = Buffer.alloc(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) masked[index] = bytes[index] ^ mask[index % 4];
  socket.write(Buffer.concat([first, length, mask, masked]));
}

async function openRelay(ticket) {
  const upstream = parseLoopbackHttp(NODE_B);
  assertThat(upstream !== null, 'node B must be a loopback HTTP endpoint');
  const socket = net.createConnection({ host: upstream.hostname, port: upstream.port });
  const reader = new SocketReader(socket);
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('node B connection timed out'));
      }, 8000);
      socket.once('connect', () => { clearTimeout(timer); resolve(); });
      socket.once('error', () => {
        clearTimeout(timer);
        reject(new Error('could not connect to node B'));
      });
    });
    const key = crypto.randomBytes(16).toString('base64');
    socket.write(
      `GET /relay/v1/connect HTTP/1.1\r\n` +
      `Host: ${upstream.hostname}:${upstream.port}\r\n` +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Key: ${key}\r\n` +
      'Sec-WebSocket-Version: 13\r\n' +
      `Origin: ${ORIGIN}\r\n\r\n`,
    );
    const headers = await reader.readHeaders();
    const firstLine = headers.split('\r\n', 1)[0];
    assertThat(/^HTTP\/1\.1 101\b/.test(firstLine), 'node B did not upgrade the exact Relay WebSocket route');
    const normalizedHeaders = Object.fromEntries(headers.split('\r\n').slice(1)
      .filter(Boolean).map((line) => {
        const separator = line.indexOf(':');
        return [line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim()];
      }));
    const expectedAccept = crypto.createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    assertThat(normalizedHeaders['sec-websocket-accept'] === expectedAccept,
      'node B returned an invalid Relay WebSocket handshake');
    sendFrame(socket, 1, Buffer.from(ticket, 'ascii'));
    return { socket, reader };
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

async function closeRelay(connection) {
  if (!connection || connection.socket.destroyed) return;
  try { sendFrame(connection.socket, 8, Buffer.from([0x03, 0xe8])); } catch (_) {}
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 100);
    connection.socket.once('close', () => { clearTimeout(timer); resolve(); });
    connection.socket.end();
  });
  connection.socket.destroy();
}

async function assertCrossNodeConsumptionAndReplayDenial() {
  const ticket = await requestTicket();
  const first = await openRelay(ticket);
  try {
    const banner = await first.reader.readFrame(10000);
    assertThat(banner.opcode === 2 && banner.payload.subarray(0, 8).toString('ascii') === 'SSH-2.0-',
      'node B did not consume node A ticket into the isolated OpenSSH target');
  } finally {
    await closeRelay(first);
  }

  const replay = await openRelay(ticket);
  let replayRejected = false;
  try {
    const frame = await replay.reader.readFrame(5000);
    replayRejected = frame.opcode === 8;
  } catch (_) {
    replayRejected = replay.socket.destroyed || replay.reader.ended;
  } finally {
    await closeRelay(replay);
  }
  assertThat(replayRejected, 'node B accepted a consumed cross-node Relay ticket replay');
}

function runOpenSsh(command, args, env, input) {
  const result = spawnSync(command, args, {
    cwd: ROOT,
    env,
    input,
    encoding: null,
    timeout: 90000,
    maxBuffer: 4 * 1024 * 1024,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  return {
    status: result.status,
    error: result.error,
    stdout: result.stdout || Buffer.alloc(0),
    stderr: result.stderr || Buffer.alloc(0),
  };
}

function sshArgs(fixture, proxyCommand, remoteCommand) {
  return [
    '-T', '-p', String(TARGET_PORT),
    '-o', `ProxyCommand=${proxyCommand}`,
    '-o', 'BatchMode=no',
    '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'NumberOfPasswordPrompts=1',
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=20',
    '-o', `LogLevel=${SSH_LOG_LEVEL}`,
    `${fixture.username}@${TARGET_HOST}`,
    remoteCommand,
  ];
}

async function runAcceptance() {
  assertThat(parseLoopbackHttp(NODE_A) && parseLoopbackHttp(NODE_B),
    'both PG Relay nodes must be loopback HTTP URLs');
  assertThat(parseOrigin(ORIGIN), 'PG Relay public origin must be an exact URL origin');
  assertThat(typeof ACCESS_TOKEN === 'string' && ACCESS_TOKEN.length > 32 &&
    typeof DEVICE_ID === 'string' && /^[0-9a-f-]{36}$/i.test(DEVICE_ID),
  'PG Relay actor credentials are missing');
  assertThat(net.isIPv4(TARGET_HOST) && Number.isInteger(TARGET_PORT) &&
    TARGET_PORT > 0 && TARGET_PORT <= 65535,
  'PG Relay target must be the fixture IPv4 address and configured TCP port');
  assertThat(fs.existsSync(SSH) && fs.existsSync(SFTP),
    'OpenSSH ssh and sftp clients are required');

  let tempRoot = null;
  let sshFixture = null;
  let fixtureSummary = null;
  let cleanupComplete = false;
  try {
    stage = 'temporary OpenSSH target setup';
    const fixtureUser = `atermius-ws-${RUN_ID}`;
    const sshPassword = crypto.randomBytes(32).toString('base64url');
    const accessToken = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    delete process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    try {
      sshFixture = await startSshFixture({
        bindAddress: TARGET_HOST,
        ports: [TARGET_PORT],
        username: fixtureUser,
        password: sshPassword,
      });
    } finally {
      if (accessToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = accessToken;
    }
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-pg-relay-'));
    fs.chmodSync(tempRoot, 0o700);
    const askpassPath = path.join(tempRoot, 'askpass');
    fs.writeFileSync(askpassPath,
      '#!/bin/sh\nprintf "%s\\n" "$ATERMIUS_PG_RELAY_SSH_PASSWORD"\n',
      { mode: 0o700 });
    fs.chmodSync(askpassPath, 0o700);
    const env = {
      ...process.env,
      SSH_ASKPASS: askpassPath,
      SSH_ASKPASS_REQUIRE: 'force',
      DISPLAY: 'atermius-pg-relay-acceptance',
      ATERMIUS_PG_RELAY_SSH_PASSWORD: sshPassword,
    };
    const proxyCommand = `${shellQuote(process.execPath)} ${shellQuote(__filename)} --proxy`;

    stage = 'cross-node ticket consume and replay denial';
    await assertCrossNodeConsumptionAndReplayDenial();

    const shellMarker = `pg-relay-shell-${RUN_ID}`;
    stage = 'OpenSSH shell through node A ticket and node B Relay';
    const shell = runOpenSsh(SSH,
      sshArgs(sshFixture, proxyCommand,
        `id -u; printf '%s\\n' '${shellMarker}'`),
      env);
    const shellOutput = Buffer.concat([shell.stdout, shell.stderr]).toString('utf8');
    const shellStdout = shell.stdout.toString('utf8');
    failureDetails = {
      shell: {
        status: shell.status,
        spawnErrorCode: shell.error?.code || null,
        stdoutBytes: shell.stdout.length,
        stderrBytes: shell.stderr.length,
        proxyDiagnostics: shell.stderr.toString('utf8').split(/\r?\n/)
          .filter((line) => line.startsWith('PG Relay proxy '))
          .slice(-5),
        sshDiagnostics: shell.stderr.toString('utf8').split(/\r?\n/)
          .filter((line) => /proxy|banner|kex|connection closed|error:|disconnect|packet|remote protocol/i.test(line))
          .slice(-18)
          .map((line) => line
            .replaceAll(sshFixture.username, '[fixture-user]')
            .replaceAll(TARGET_HOST, '[fixture-target]')
            .replaceAll(sshPassword, '[redacted]')),
        nonRootUidObserved: /(?:^|\n)[1-9][0-9]*\n/.test(shellStdout),
        markerObserved: shellStdout.includes(shellMarker),
      },
      target: sshFixture.servers.map((server) => {
        const summary = server.summary();
        let events = [];
        try {
          const root = path.dirname(path.dirname(server.logPath));
          events = fs.readFileSync(server.logPath, 'utf8').split(/\r?\n/)
            .filter((line) => /kex|packet|disconnect|closed|session|permission|error|fatal|banner/i.test(line))
            .slice(-12)
            .map((line) => line
              .replaceAll(sshFixture.username, '[fixture-user]')
              .replaceAll(TARGET_HOST, '[fixture-target]')
              .replaceAll(sshPassword, '[redacted]')
              .replaceAll(root, '[fixture-path]'));
        } catch (_) {}
        return {
          running: summary.running,
          listenerStarts: summary.listenerStarts,
          tcpConnectionsAccepted: summary.tcpConnectionsAccepted,
          serverBannerEmitted: summary.serverBannerEmitted,
          clientBannerReceived: summary.clientBannerReceived,
          keyExchangeStarted: summary.keyExchangeStarted,
          passwordAccepted: summary.passwordAccepted,
          passwordRejected: summary.passwordRejected,
          sessionStarts: summary.sessionStarts,
          commandSessions: summary.commandSessions,
          forwardingRequests: summary.forwardingRequests,
          events,
        };
      }),
    };
    assertThat(shell.status === 0 && !shell.error &&
      new RegExp(`(?:^|\\n)[1-9][0-9]*\\n${shellMarker}(?:\\n|$)`).test(shellStdout) &&
      !SENSITIVE.some((secret) => shellOutput.includes(secret)) &&
      !shellOutput.includes(sshPassword),
    'OpenSSH shell did not complete safely through the cross-node Relay');

    stage = 'OpenSSH SFTP through node A ticket and node B Relay';
    const localUpload = path.join(tempRoot, `upload-${RUN_ID}.bin`);
    const localDownload = path.join(tempRoot, `download-${RUN_ID}.bin`);
    const uploadBytes = Buffer.concat([
      Buffer.from(`pg-relay-sftp-${RUN_ID}\0`, 'utf8'),
      crypto.randomBytes(257),
      Buffer.from('\nfixture-end\n', 'utf8'),
    ]);
    fs.writeFileSync(localUpload, uploadBytes, { mode: 0o600 });
    const remoteSftpPath = `/tmp/pg-relay-sftp-${RUN_ID}.bin`;
    const sftpArgs = [
      '-P', String(TARGET_PORT),
      '-o', `ProxyCommand=${proxyCommand}`,
      '-o', 'BatchMode=no',
      '-o', 'PreferredAuthentications=password',
      '-o', 'PubkeyAuthentication=no',
      '-o', 'KbdInteractiveAuthentication=no',
      '-o', 'NumberOfPasswordPrompts=1',
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'ConnectTimeout=20',
      '-o', `LogLevel=${SSH_LOG_LEVEL}`,
      `${sshFixture.username}@${TARGET_HOST}`,
    ];
    const sftp = runOpenSsh(SFTP, sftpArgs,
      env,
      Buffer.from(`put ${localUpload} ${remoteSftpPath}\nget ${remoteSftpPath} ${localDownload}\nrm ${remoteSftpPath}\n`, 'utf8'));
    const sftpOutput = Buffer.concat([sftp.stdout, sftp.stderr]).toString('utf8');
    const sftpRoundTrip = fs.existsSync(localDownload) &&
      fs.readFileSync(localDownload).equals(uploadBytes);
    failureDetails = {
      sftp: {
        status: sftp.status,
        spawnErrorCode: sftp.error?.code || null,
        stdoutBytes: sftp.stdout.length,
        stderrBytes: sftp.stderr.length,
        downloadPresent: fs.existsSync(localDownload),
        roundTripMatched: sftpRoundTrip,
        sshDiagnostics: sftp.stderr.toString('utf8').split(/\r?\n/)
          .filter((line) => /sftp|subsystem|auth|password|permission|connection closed|error:|disconnect|packet|remote protocol|proxy/i.test(line))
          .slice(-32)
          .map((line) => line
            .replaceAll(sshFixture.username, '[fixture-user]')
            .replaceAll(TARGET_HOST, '[fixture-target]')
            .replaceAll(sshPassword, '[redacted]')),
        target: sshFixture.servers.map((server) => {
          const summary = server.summary();
          return {
            tcpConnectionsAccepted: summary.tcpConnectionsAccepted,
            passwordAccepted: summary.passwordAccepted,
            sftpRequests: summary.sftpRequests,
            sftpSessions: summary.sftpSessions,
            sessionStarts: summary.sessionStarts,
          };
        }),
      },
    };
    assertThat(sftp.status === 0 && !sftp.error && fs.existsSync(localDownload) &&
      sftpRoundTrip &&
      !SENSITIVE.some((secret) => sftpOutput.includes(secret)) &&
      !sftpOutput.includes(sshPassword),
    'SFTP upload/download bytes did not round-trip through the cross-node Relay');

    const summary = sshFixture.servers[0].summary();
    assertThat(summary.stopped === false && summary.tcpConnectionsAccepted >= 3 &&
      summary.commandSessions >= 1 && summary.sftpSessions >= 1 &&
      summary.forwardingRequests === 0,
    'isolated OpenSSH logs did not confirm shell and SFTP sessions without forwarding');
    fixtureSummary = {
      shell: true,
      sftp: true,
      replayDenied: true,
      shellSessions: summary.commandSessions,
      sftpSessions: summary.sftpSessions,
    };
    console.log('assert: pg_relay_ticket_node_a_to_b=true');
    console.log('assert: pg_relay_one_use_replay_denied=true');
    console.log('assert: pg_relay_ssh_shell_non_root=true');
    console.log('assert: pg_relay_sftp_round_trip=true');
  } finally {
    const cleanupErrors = [];
    if (sshFixture) {
      const accessToken = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
      delete process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
      try {
        await sshFixture.cleanup();
        const status = sshFixture.status();
        const serverStopped = sshFixture.servers.every((server) =>
          server.child.exitCode !== null || server.child.signalCode !== null);
        const serverRoot = sshFixture.servers[0]
          ? path.dirname(path.dirname(sshFixture.servers[0].logPath))
          : null;
        const userLookup = spawnSync('getent', ['passwd', sshFixture.username], {
          encoding: 'utf8', timeout: 5000,
        });
        if (!(status.closed && status.cleaned && serverStopped &&
            userLookup.status === 2 && (!serverRoot || !fs.existsSync(serverRoot)))) {
          cleanupErrors.push('temporary SSHD/account/private fixture cleanup incomplete');
        }
      } catch (_) {
        cleanupErrors.push('temporary SSHD/account/private fixture cleanup failed');
      } finally {
        if (accessToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = accessToken;
      }
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupErrors.push('private runner directory cleanup incomplete');
      } catch (_) {
        cleanupErrors.push('private runner directory cleanup failed');
      }
    }
    cleanupComplete = cleanupErrors.length === 0;
    assertThat(cleanupComplete, 'PG Relay fixture cleanup did not complete');
    if (fixtureSummary) {
      console.log('assert: pg_relay_cleanup_complete=true');
    }
  }
}

async function proxyMode() {
  let connection;
  let proxyStage = 'ticket request';
  let proxyCloseReason = 'unknown';
  let proxyInputEnded = false;
  try {
    const ticket = await requestTicket();
    proxyStage = 'WebSocket upgrade';
    connection = await openRelay(ticket);
    proxyStage = 'SSH byte stream';
    const input = process.stdin;
    input.on('data', (chunk) => {
      if (!connection.socket.destroyed) sendFrame(connection.socket, 2, chunk);
    });
    input.on('end', () => {
      proxyInputEnded = true;
      try { sendFrame(connection.socket, 8, Buffer.from([0x03, 0xe8])); } catch (_) {}
      connection.socket.end();
    });
    input.resume();
    while (!connection.socket.destroyed) {
      let frame;
      try { frame = await connection.reader.readFrame(120000); }
      catch (error) {
        proxyCloseReason = error instanceof Error ? error.message : 'Relay read failed';
        break;
      }
      if (frame.opcode === 2) {
        if (!process.stdout.write(frame.payload)) {
          await new Promise((resolve) => process.stdout.once('drain', resolve));
        }
      } else if (frame.opcode === 9) {
        sendFrame(connection.socket, 10, frame.payload);
      } else if (frame.opcode === 8) {
        proxyCloseReason = 'Relay sent a WebSocket close frame';
        break;
      } else {
        proxyCloseReason = `Relay sent unexpected WebSocket opcode ${frame.opcode}`;
        break;
      }
    }
    if (connection.socket.destroyed && proxyCloseReason === 'unknown') {
      proxyCloseReason = 'Relay socket was destroyed';
    }
    process.exitCode = 0;
  } catch (error) {
    proxyCloseReason = error instanceof Error ? error.message : 'proxy error';
    if (PROXY_DIAGNOSTICS) {
      process.stderr.write(`PG Relay proxy failed during ${proxyStage}: ${proxyCloseReason}\n`);
    } else {
      process.stderr.write('PG Relay SSH proxy failed\n');
    }
    process.exitCode = 1;
  } finally {
    if (PROXY_DIAGNOSTICS && process.exitCode === 0) {
      process.stderr.write(
        `PG Relay proxy ended during ${proxyStage}: ${proxyCloseReason}; inputEnded=${proxyInputEnded}\n`,
      );
    }
    if (connection) {
      try { connection.socket.destroy(); } catch (_) {}
    }
    process.stdin.pause();
    process.stdout.end();
  }
}

if (process.argv.includes('--proxy')) {
  proxyMode();
} else {
  runAcceptance().then(() => {
    console.log('PG-RELAY-01 passed: cross-node one-use tickets, OpenSSH shell, SFTP and cleanup verified.');
  }).catch(() => {
    const details = failureDetails ? ` ${JSON.stringify(failureDetails)}` : '';
    console.error(`PG-RELAY-01 failed at ${stage}${details}`);
    process.exitCode = 1;
  });
}
