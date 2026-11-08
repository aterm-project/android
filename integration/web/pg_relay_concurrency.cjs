/*
 * PG-RELAY-02: race PostgreSQL-backed Relay ticket redemption and connection
 * admission across two server nodes. Tickets are issued by node A, while
 * WebSocket connections are deliberately spread across both nodes. It starts
 * its own isolated SSHD target and never prints credentials, tickets, or
 * target addresses.
 */

'use strict';

const crypto = require('node:crypto');
const net = require('node:net');
const http = require('node:http');
const { startSshFixture } = require('./ssh_fixture.cjs');

const NODE_A = process.env.ATERMIUS_PG_RELAY_NODE_A_URL;
const NODE_B = process.env.ATERMIUS_PG_RELAY_NODE_B_URL;
const ORIGIN = process.env.ATERMIUS_PG_RELAY_PUBLIC_ORIGIN;
const ACCESS_TOKEN = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
const DEVICE_ID = process.env.ATERMIUS_PG_RELAY_DEVICE_ID;
const TARGET_HOST = process.env.ATERMIUS_PG_RELAY_TARGET_HOST;
const TARGET_PORT = Number(process.env.ATERMIUS_PG_RELAY_TARGET_PORT);
const EXPECTED_USER_CAP = 4;
const TIMEOUT_MS = 10000;
const SSH_BANNER = Buffer.from('SSH-2.0-', 'ascii');
let stage = 'preflight';

function assertThat(value, message) {
  if (!value) throw new Error(message);
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

function withTimeout(promise, timeoutMs, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), timeoutMs);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); },
    );
  });
}

function httpJson(urlValue, { method = 'GET', headers = {}, body } = {}) {
  const url = new URL(urlValue);
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: url.hostname,
      port: Number(url.port || 80),
      method,
      path: `${url.pathname}${url.search}`,
      headers,
      timeout: TIMEOUT_MS,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (_) {}
        resolve({ status: response.statusCode || 0, json: parsed });
      });
    });
    request.on('timeout', () => request.destroy(new Error('Relay ticket request timed out')));
    request.on('error', () => reject(new Error('Relay ticket request failed')));
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
    this.waiters = [];
    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.wake();
    });
    socket.on('end', () => { this.ended = true; this.wake(); });
    socket.on('close', () => { this.ended = true; this.wake(); });
    socket.on('error', () => { this.ended = true; this.wake(); });
  }

  wake() {
    for (const resolve of this.waiters.splice(0)) resolve();
  }

  async waitForData(deadline) {
    if (this.ended) throw new Error('Relay WebSocket closed');
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('Relay response timed out');
    await new Promise((resolve, reject) => {
      let onData;
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter !== onData);
        reject(new Error('Relay response timed out'));
      }, remaining);
      onData = () => { clearTimeout(timer); resolve(); };
      this.waiters.push(onData);
    });
  }

  async readExact(size, timeoutMs = TIMEOUT_MS) {
    const deadline = Date.now() + timeoutMs;
    while (this.buffer.length < size) await this.waitForData(deadline);
    const value = this.buffer.subarray(0, size);
    this.buffer = this.buffer.subarray(size);
    return value;
  }

  async readHeaders(timeoutMs = TIMEOUT_MS) {
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

  async readFrame(timeoutMs = TIMEOUT_MS) {
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
    if (size > 1024 * 1024) throw new Error('Relay frame exceeded the acceptance bound');
    const mask = masked ? await this.readExact(4, timeoutMs) : null;
    const payload = Buffer.from(await this.readExact(size, timeoutMs));
    if (mask) {
      for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
    }
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

async function openRelay(ticket, nodeUrl) {
  const upstream = parseLoopbackHttp(nodeUrl);
  assertThat(upstream !== null, 'Relay node must be a loopback HTTP endpoint');
  const socket = net.createConnection({ host: upstream.hostname, port: upstream.port });
  const reader = new SocketReader(socket);
  try {
    await withTimeout(new Promise((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('error', reject);
    }), TIMEOUT_MS, 'Relay node connection timed out');
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
    assertThat(/^HTTP\/1\.1 101\b/.test(headers.split('\r\n', 1)[0]),
      'Relay node did not upgrade the exact WebSocket route');
    const normalized = Object.fromEntries(headers.split('\r\n').slice(1)
      .filter(Boolean).map((line) => {
        const separator = line.indexOf(':');
        return [line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim()];
      }));
    const expectedAccept = crypto.createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    assertThat(normalized['sec-websocket-accept'] === expectedAccept,
      'Relay node returned an invalid WebSocket handshake');
    sendFrame(socket, 1, Buffer.from(ticket, 'ascii'));
    return { socket, reader };
  } catch (error) {
    socket.destroy();
    if (error instanceof Error && /Relay node did not upgrade|invalid WebSocket/.test(error.message)) {
      throw error;
    }
    throw new Error('Relay WebSocket connection or handshake failed');
  }
}

async function observeOutcome(connection) {
  let frame;
  try {
    frame = await connection.reader.readFrame(TIMEOUT_MS);
  } catch (error) {
    if (connection.reader.ended || connection.socket.destroyed) return 'rejected';
    throw error;
  }
  if (frame.opcode === 8) return 'rejected';
  if (frame.opcode === 2 && frame.payload.subarray(0, SSH_BANNER.length).equals(SSH_BANNER)) {
    return 'ssh';
  }
  throw new Error('Relay returned an unexpected first data frame');
}

async function closeRelay(connection) {
  if (!connection) return;
  if (connection.socket.destroyed) return;
  try { sendFrame(connection.socket, 8, Buffer.from([0x03, 0xe8])); } catch (_) {}
  await Promise.race([
    new Promise((resolve) => connection.socket.once('close', resolve)),
    new Promise((resolve) => setTimeout(resolve, 750)),
  ]);
  connection.socket.destroy();
}

async function openRelays(tickets, nodes, connections) {
  const results = await Promise.allSettled(tickets.map((ticket, index) =>
    openRelay(ticket, nodes[index])));
  for (const result of results) {
    if (result.status === 'fulfilled') connections.push(result.value);
  }
  if (results.some((result) => result.status === 'rejected')) {
    throw new Error('one or more Relay WebSocket handshakes failed');
  }
  return results.map((result) => result.value);
}

async function assertExactlyOne(values, expected, label) {
  const outcomes = await Promise.all(values.map((connection) => observeOutcome(connection)));
  const accepted = outcomes.filter((value) => value === 'ssh').length;
  const rejected = outcomes.filter((value) => value === 'rejected').length;
  assertThat(accepted === expected && rejected === values.length - expected,
    `${label} did not produce the exact expected SSH admissions`);
  return { accepted, rejected };
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
  assertThat(EXPECTED_USER_CAP === 4,
    'PG Relay concurrency acceptance requires the default per-user cap of four');

  const connections = [];
  let sshFixture = null;
  let redemptionPassed = false;
  let admissionPassed = false;
  let cleanupPassed = false;
  try {
    stage = 'isolated OpenSSH target setup';
    sshFixture = await startSshFixture({
      bindAddress: TARGET_HOST,
      ports: [TARGET_PORT],
      username: `atermius-ws-${crypto.randomBytes(8).toString('hex')}`,
      password: crypto.randomBytes(32).toString('base64url'),
    });
    assertThat(sshFixture.servers.length === 1 && sshFixture.servers[0].summary().running,
      'isolated OpenSSH target did not start');

    stage = 'simultaneous cross-node ticket redemption';
    const sharedTicket = await requestTicket();
    const redemption = await openRelays([sharedTicket, sharedTicket], [NODE_A, NODE_B], connections);
    const redemptionResult = await assertExactlyOne(redemption, 1, 'simultaneous ticket redemption');
    assertThat(redemptionResult.accepted === 1 && redemptionResult.rejected === 1,
      'simultaneous ticket redemption did not have one winner and one replay rejection');
    await Promise.all(redemption.map((connection) => closeRelay(connection)));
    await new Promise((resolve) => setTimeout(resolve, 500));
    redemptionPassed = true;

    stage = 'simultaneous cross-node per-user cap admission';
    const tickets = await Promise.all(Array.from({ length: EXPECTED_USER_CAP + 1 }, () => requestTicket()));
    const nodes = [NODE_A, NODE_B, NODE_A, NODE_B, NODE_A];
    const admissionConnections = await openRelays(tickets, nodes, connections);
    const admissionResult = await assertExactlyOne(
      admissionConnections, EXPECTED_USER_CAP, 'simultaneous per-user admission cap',
    );
    assertThat(admissionResult.accepted === 4 && admissionResult.rejected === 1,
      'five simultaneous cross-node sockets did not admit exactly four SSH sessions');
    admissionPassed = true;
  } finally {
    await Promise.all(connections.map((connection) => closeRelay(connection)));
    await new Promise((resolve) => setTimeout(resolve, 200));
    let sshCleanupPassed = sshFixture === null;
    if (sshFixture) {
      try {
        await sshFixture.cleanup();
        const status = sshFixture.status();
        const stopped = sshFixture.servers.every((server) =>
          server.child.exitCode !== null || server.child.signalCode !== null);
        sshCleanupPassed = status.closed && status.cleaned && stopped;
      } catch (_) {
        sshCleanupPassed = false;
      }
    }
    cleanupPassed = connections.every((connection) => connection.socket.destroyed) && sshCleanupPassed;
    assertThat(cleanupPassed, 'PG Relay concurrency runner socket cleanup did not complete');
  }

  assertThat(redemptionPassed && admissionPassed && cleanupPassed,
    'PG Relay concurrency acceptance did not complete every phase');
  console.log('assert: pg_relay_cross_node_ticket_race=true');
  console.log('assert: pg_relay_cross_node_admission_cap=true');
  console.log('assert: pg_relay_concurrency_cleanup_complete=true');
}

runAcceptance().then(() => {
  console.log('PG-RELAY-02 passed: simultaneous cross-node redemption and admission cap verified.');
}).catch((error) => {
  console.error(`PG-RELAY-02 failed at ${stage}`);
  process.exitCode = 1;
});
