/*
 * PostgreSQL Relay lease recovery after a serving-node hard crash.
 *
 * The harness supplies node A's direct server PID. This runner establishes
 * four real SSH byte streams through node A (the configured per-user limit),
 * kills that process without graceful lease release, waits beyond the lease
 * TTL, then proves node B can admit the fifth stream after stale-lease cleanup.
 * Tickets, credentials, and fixture passwords are never emitted.
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { startSshFixture } = require('./ssh_fixture.cjs');

const NODE_A = process.env.ATERMIUS_PG_RELAY_NODE_A_URL;
const NODE_B = process.env.ATERMIUS_PG_RELAY_NODE_B_URL;
const ORIGIN = process.env.ATERMIUS_PG_RELAY_PUBLIC_ORIGIN;
const ACCESS_TOKEN = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
const DEVICE_ID = process.env.ATERMIUS_PG_RELAY_DEVICE_ID;
const TARGET_HOST = process.env.ATERMIUS_PG_RELAY_TARGET_HOST;
const TARGET_PORT = Number(process.env.ATERMIUS_PG_RELAY_TARGET_PORT);
const NODE_A_PID = Number(process.env.ATERMIUS_PG_RELAY_NODE_A_PID);
const RUN_ID = crypto.randomBytes(8).toString('hex');
const CONNECTION_LIMIT = 4;
const LEASE_TTL_MS = 10_000;
const LEASE_SAFETY_MS = 2_500;
let stage = 'preflight';

function assertThat(value, message) {
  if (!value) throw new Error(message);
}

function parseLoopbackHttp(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port) return null;
    return { hostname: url.hostname, port: Number(url.port), origin: url.origin };
  } catch (_) {
    return null;
  }
}

function parseOrigin(value) {
  try {
    const url = new URL(value);
    return url.origin === value ? value : null;
  } catch (_) {
    return null;
  }
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
        let json = null;
        try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (_) {}
        resolve({ status: response.statusCode || 0, json });
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
  const fields = Object.keys(response.json || {}).sort().join(',');
  assertThat(response.status === 200 && fields === 'connect_path,expires_at,ticket' &&
    response.json.connect_path === '/relay/v1/connect' &&
    Number.isFinite(expiry) && expiry > Date.now() && expiry <= Date.now() + 60_000 &&
    typeof ticket === 'string' && /^[A-Za-z0-9_-]{43}$/.test(ticket),
  'node A did not issue a valid one-use Relay ticket');
  return { ticket, expiry };
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
      const onData = () => { clearTimeout(timer); resolve(); };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter !== onData);
        reject(new Error('Relay WebSocket response timed out'));
      }, remaining);
      this.waiters.push(onData);
    });
  }

  async readExact(size, timeoutMs = 10_000) {
    const deadline = Date.now() + timeoutMs;
    while (this.buffer.length < size) await this.waitForData(deadline);
    const value = this.buffer.subarray(0, size);
    this.buffer = this.buffer.subarray(size);
    return value;
  }

  async readHeaders(timeoutMs = 10_000) {
    const delimiter = Buffer.from('\r\n\r\n');
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const index = this.buffer.indexOf(delimiter);
      if (index >= 0) {
        const value = this.buffer.subarray(0, index + delimiter.length).toString('latin1');
        this.buffer = this.buffer.subarray(index + delimiter.length);
        return value;
      }
      if (this.buffer.length > 16_384) throw new Error('Relay WebSocket headers exceeded the bound');
      await this.waitForData(deadline);
    }
  }

  async readFrame(timeoutMs = 10_000) {
    const first = await this.readExact(2, timeoutMs);
    const opcode = first[0] & 0x0f;
    const masked = Boolean(first[1] & 0x80);
    let size = first[1] & 0x7f;
    if (size === 126) size = (await this.readExact(2, timeoutMs)).readUInt16BE(0);
    else if (size === 127) {
      const wide = (await this.readExact(8, timeoutMs)).readBigUInt64BE(0);
      if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Relay frame exceeded the bound');
      size = Number(wide);
    }
    if (size > 1024 * 1024) throw new Error('Relay frame exceeded the bound');
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
  if (bytes.length < 126) {
    length = Buffer.from([0x80 | bytes.length]);
  } else if (bytes.length <= 0xffff) {
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

async function openRelay(nodeUrl, ticket) {
  const upstream = parseLoopbackHttp(nodeUrl);
  assertThat(upstream !== null, 'Relay node must be a loopback HTTP endpoint');
  const socket = net.createConnection({ host: upstream.hostname, port: upstream.port });
  const reader = new SocketReader(socket);
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('Relay node connection timed out'));
      }, 8000);
      socket.once('connect', () => { clearTimeout(timer); resolve(); });
      socket.once('error', () => {
        clearTimeout(timer);
        reject(new Error('could not connect to Relay node'));
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
    assertThat(/^HTTP\/1\.1 101\b/.test(firstLine), 'Relay node did not upgrade its exact WebSocket route');
    const normalized = Object.fromEntries(headers.split('\r\n').slice(1)
      .filter(Boolean).map((line) => {
        const separator = line.indexOf(':');
        return [line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim()];
      }));
    const accept = crypto.createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    assertThat(normalized['sec-websocket-accept'] === accept,
      'Relay node returned an invalid WebSocket handshake');
    sendFrame(socket, 1, Buffer.from(ticket, 'ascii'));
    return { socket, reader };
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

async function readSshBanner(connection) {
  const deadline = Date.now() + 10_000;
  let received = Buffer.alloc(0);
  while (Date.now() < deadline) {
    const frame = await connection.reader.readFrame(Math.max(1, deadline - Date.now()));
    assertThat(frame.opcode === 2, 'Relay did not carry the SSH server stream as binary data');
    received = Buffer.concat([received, frame.payload]);
    const lineEnd = received.indexOf('\r\n');
    if (lineEnd >= 0) {
      const banner = received.subarray(0, lineEnd).toString('ascii');
      // RFC 4253 permits spaces in the software version/comment portion.
      assertThat(/^SSH-2\.0-[\x20-\x7e]{1,200}$/.test(banner),
        'Relay target did not return a valid SSH identification banner');
      return banner;
    }
    assertThat(received.length <= 4096, 'SSH identification data exceeded the bound');
  }
  throw new Error('SSH identification banner timed out');
}

async function closeRelay(connection) {
  if (!connection || connection.socket.destroyed) return;
  try { sendFrame(connection.socket, 8, Buffer.from([0x03, 0xe8])); } catch (_) {}
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 150);
    connection.socket.once('close', () => { clearTimeout(timer); resolve(); });
    connection.socket.end();
  });
  connection.socket.destroy();
}

function processState(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const close = stat.lastIndexOf(')');
    return close < 0 ? null : stat.slice(close + 2, close + 3);
  } catch (_) {
    return null;
  }
}

async function waitForProcessExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = processState(pid);
    if (state === null || state === 'Z') return true;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return false;
}

function validateCrashTarget() {
  assertThat(Number.isSafeInteger(NODE_A_PID) && NODE_A_PID > 2 &&
    NODE_A_PID !== process.pid && NODE_A_PID !== process.ppid,
  'the harness must provide node A direct server PID');
  const state = processState(NODE_A_PID);
  assertThat(state !== null && state !== 'Z', 'node A process is not alive');
  let commandLine = '';
  try { commandLine = fs.readFileSync(`/proc/${NODE_A_PID}/cmdline`, 'utf8'); } catch (_) {}
  const args = commandLine.split('\0').filter(Boolean);
  assertThat(args.slice(1).includes('serve'), 'supplied node A PID is not a direct server process');
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
  validateCrashTarget();

  let sshFixture = null;
  const liveConnections = [];
  let killedNodeA = false;
  let success = false;
  try {
    stage = 'temporary OpenSSH target setup';
    const username = `atermius-ws-${RUN_ID}`;
    const password = crypto.randomBytes(32).toString('base64url');
    const accessToken = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    delete process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    try {
      sshFixture = await startSshFixture({
        bindAddress: TARGET_HOST,
        ports: [TARGET_PORT],
        username,
        password,
      });
    } finally {
      if (accessToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = accessToken;
    }

    stage = 'issue five node A tickets';
    const tickets = [];
    for (let index = 0; index < CONNECTION_LIMIT + 1; index += 1) {
      tickets.push(await requestTicket());
    }

    stage = 'establish live node A SSH Relay sockets';
    for (let index = 0; index < CONNECTION_LIMIT; index += 1) {
      stage = `open node A SSH Relay socket ${index + 1}/${CONNECTION_LIMIT}`;
      const connection = await openRelay(NODE_A, tickets[index].ticket);
      liveConnections.push(connection);
      stage = `read node A SSH banner ${index + 1}/${CONNECTION_LIMIT}`;
      await readSshBanner(connection);
    }
    const targetSummary = sshFixture.servers[0].summary();
    assertThat(targetSummary.tcpConnectionsAccepted >= CONNECTION_LIMIT &&
      targetSummary.serverBannerEmitted >= CONNECTION_LIMIT,
    'the OpenSSH fixture did not confirm four active SSH transports');

    stage = 'hard kill node A';
    process.kill(NODE_A_PID, 'SIGKILL');
    assertThat(await waitForProcessExit(NODE_A_PID, 5000),
      'node A did not exit after SIGKILL');
    killedNodeA = true;

    stage = 'wait for PostgreSQL connection lease expiry';
    await new Promise((resolve) => setTimeout(resolve, LEASE_TTL_MS + LEASE_SAFETY_MS));
    assertThat(tickets[CONNECTION_LIMIT].expiry > Date.now() + 1000,
      'the fifth Relay ticket expired before stale-lease recovery could be checked');

    stage = 'admit fifth Relay connection on node B';
    const recovered = await openRelay(NODE_B, tickets[CONNECTION_LIMIT].ticket);
    liveConnections.push(recovered);
    await readSshBanner(recovered);
    success = true;
    console.log('assert: pg_relay_stale_lease_after_node_crash=true');
  } finally {
    await Promise.all(liveConnections.map((connection) => closeRelay(connection)));
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
          cleanupErrors.push('temporary SSH fixture cleanup incomplete');
        }
      } catch (_) {
        cleanupErrors.push('temporary SSH fixture cleanup failed');
      } finally {
        if (accessToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = accessToken;
      }
    }
    if (!killedNodeA && processState(NODE_A_PID) === 'Z') {
      // The direct child is expected to be reaped by the Python fixture after
      // this process exits; a zombie here still proves SIGKILL took effect.
      killedNodeA = true;
    }
    assertThat(cleanupErrors.length === 0, 'PG Relay crash fixture cleanup did not complete');
    assertThat(!success || killedNodeA, 'PG Relay crash recovery ran without killing node A');
  }
}

runAcceptance().then(() => {
  process.stdout.write('assert: pg_relay_crash_cleanup_complete=true\n');
  process.stdout.write('PG Relay stale-lease crash acceptance passed.\n');
}).catch((error) => {
  const detail = error instanceof Error ? error.message.slice(0, 240) : 'unknown failure';
  process.stderr.write(`PG Relay stale-lease crash acceptance failed at ${stage}: ${detail}.\n`);
  process.exitCode = 1;
});
