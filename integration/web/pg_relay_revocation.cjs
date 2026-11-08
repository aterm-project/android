/*
 * PG-RELAY-02: prove a live cross-node SSH Relay socket observes logout.
 *
 * Node A issues the one-use ticket and performs the logout. Node B consumes
 * the ticket into a real, isolated OpenSSH target and must close the upgraded
 * WebSocket after its shared-session check notices the revocation. Credentials
 * and the ticket are used only in memory and are never emitted.
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
const RUN_ID = crypto.randomBytes(8).toString('hex');
const SENSITIVE = [ACCESS_TOKEN].filter(Boolean);

function assertThat(value, message) {
  if (!value) throw new Error(message);
}

function parseLoopbackHttp(value) {
  let url;
  try { url = new URL(value); } catch (_) { return null; }
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port) return null;
  return { hostname: url.hostname, port: Number(url.port), origin: url.origin };
}

function isExactOrigin(value) {
  try {
    const url = new URL(value);
    return url.origin === value;
  } catch (_) { return false; }
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
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > 64 * 1024) {
          response.destroy(new Error('HTTP response exceeded the acceptance bound'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        let json = null;
        try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (_) {}
        resolve({ status: response.statusCode || 0, json });
      });
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('HTTP request timed out')));
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
  const ticket = response.json?.ticket;
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
    this.error = null;
    this.waiters = [];
    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.wake();
    });
    socket.on('end', () => { this.ended = true; this.wake(); });
    socket.on('close', () => { this.ended = true; this.wake(); });
    socket.on('error', () => { this.error = true; this.ended = true; this.wake(); });
  }

  wake() {
    for (const resolve of this.waiters.splice(0)) resolve();
  }

  async waitForData(deadline) {
    if (this.error) throw new Error('Relay WebSocket transport ended');
    if (this.ended) throw new Error('Relay WebSocket ended');
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

  async readExact(size, deadline) {
    while (this.buffer.length < size) await this.waitForData(deadline);
    const result = this.buffer.subarray(0, size);
    this.buffer = this.buffer.subarray(size);
    return result;
  }

  async readHeaders(timeoutMs = 8000) {
    const delimiter = Buffer.from('\r\n\r\n');
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const index = this.buffer.indexOf(delimiter);
      if (index >= 0) {
        const result = this.buffer.subarray(0, index + delimiter.length).toString('latin1');
        this.buffer = this.buffer.subarray(index + delimiter.length);
        return result;
      }
      if (this.buffer.length > 16 * 1024) throw new Error('Relay response headers exceeded the bound');
      await this.waitForData(deadline);
    }
  }

  async readFrame(deadline) {
    const first = await this.readExact(2, deadline);
    const opcode = first[0] & 0x0f;
    const masked = Boolean(first[1] & 0x80);
    let size = first[1] & 0x7f;
    if (size === 126) size = (await this.readExact(2, deadline)).readUInt16BE(0);
    else if (size === 127) {
      const wide = (await this.readExact(8, deadline)).readBigUInt64BE(0);
      if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Relay frame exceeded the bound');
      size = Number(wide);
    }
    if (size > 1024 * 1024) throw new Error('Relay frame exceeded the acceptance bound');
    const mask = masked ? await this.readExact(4, deadline) : null;
    const payload = Buffer.from(await this.readExact(size, deadline));
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
      'GET /relay/v1/connect HTTP/1.1\r\n' +
      `Host: ${upstream.hostname}:${upstream.port}\r\n` +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Key: ${key}\r\n` +
      'Sec-WebSocket-Version: 13\r\n' +
      `Origin: ${ORIGIN}\r\n\r\n`,
    );
    const headers = await reader.readHeaders();
    const statusLine = headers.split('\r\n', 1)[0];
    assertThat(/^HTTP\/1\.1 101\b/.test(statusLine),
      'node B did not upgrade the exact Relay WebSocket route');
    const parsedHeaders = Object.fromEntries(headers.split('\r\n').slice(1)
      .filter(Boolean).map((line) => {
        const separator = line.indexOf(':');
        return [line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim()];
      }));
    const expectedAccept = crypto.createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    assertThat(parsedHeaders['sec-websocket-accept'] === expectedAccept,
      'node B returned an invalid Relay WebSocket handshake');
    sendFrame(socket, 1, Buffer.from(ticket, 'ascii'));
    return { socket, reader };
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

async function confirmSshBanner(connection) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const frame = await connection.reader.readFrame(deadline);
    if (frame.opcode === 9) {
      sendFrame(connection.socket, 10, frame.payload);
      continue;
    }
    assertThat(frame.opcode === 2 && frame.payload.subarray(0, 8).toString('ascii') === 'SSH-2.0-',
      'node B Relay did not deliver the target SSH banner');
    return;
  }
  throw new Error('target SSH banner did not arrive before the bound');
}

async function logoutSession() {
  const response = await httpJson(`${NODE_A}/api/v1/auth/logout`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${ACCESS_TOKEN}`,
      Accept: 'application/json',
    },
  });
  assertThat(response.status === 200 && response.json?.status === 'logged_out',
    'node A did not revoke the active session through the logout API');
}

async function assertRelayClosedAfterLogout(connection) {
  const deadline = Date.now() + 8000;
  while (!connection.reader.ended && Date.now() < deadline) {
    let frame;
    try {
      frame = await connection.reader.readFrame(deadline);
    } catch (error) {
      if (connection.reader.ended) return;
      throw error;
    }
    if (frame.opcode === 9) {
      sendFrame(connection.socket, 10, frame.payload);
      continue;
    }
    if (frame.opcode === 8) {
      sendFrame(connection.socket, 8, frame.payload);
      await new Promise((resolve, reject) => {
        if (connection.reader.ended) { resolve(); return; }
        const remaining = Math.min(2000, Math.max(1, deadline - Date.now()));
        const timer = setTimeout(() => reject(new Error('Relay close handshake timed out')), remaining);
        connection.socket.once('close', () => { clearTimeout(timer); resolve(); });
        connection.socket.once('end', () => { clearTimeout(timer); resolve(); });
      });
      return;
    }
    if (frame.opcode !== 2) throw new Error('unexpected frame while waiting for Relay revocation');
  }
  assertThat(connection.reader.ended,
    'node B kept the live Relay WebSocket open after cross-node logout');
}

async function closeRelay(connection) {
  if (!connection || connection.socket.destroyed) return;
  try { sendFrame(connection.socket, 8, Buffer.from([0x03, 0xe8])); } catch (_) {}
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 200);
    connection.socket.once('close', () => { clearTimeout(timer); resolve(); });
    connection.socket.end();
  });
  connection.socket.destroy();
}

async function runAcceptance() {
  assertThat(parseLoopbackHttp(NODE_A) && parseLoopbackHttp(NODE_B),
    'both PG Relay nodes must be loopback HTTP URLs');
  assertThat(isExactOrigin(ORIGIN), 'PG Relay public origin must be an exact URL origin');
  assertThat(typeof ACCESS_TOKEN === 'string' && ACCESS_TOKEN.length > 32 &&
    typeof DEVICE_ID === 'string' && /^[0-9a-f-]{36}$/i.test(DEVICE_ID),
  'PG Relay actor credentials are missing');
  assertThat(net.isIPv4(TARGET_HOST) && Number.isInteger(TARGET_PORT) &&
    TARGET_PORT > 0 && TARGET_PORT <= 65535,
  'PG Relay target must be the fixture IPv4 address and configured TCP port');
  assertThat(typeof process.getuid === 'function' && process.getuid() === 0,
    'isolated OpenSSH Relay target requires a Linux root acceptance worker');
  assertThat(fs.existsSync(process.env.SSHD_PATH || '/usr/sbin/sshd'),
    'isolated OpenSSH Relay target requires sshd');

  let sshFixture = null;
  let connection = null;
  let assertionComplete = false;
  let stage = 'OpenSSH fixture setup';
  try {
    const username = `atermius-ws-${RUN_ID}`;
    const password = crypto.randomBytes(32).toString('base64url');
    const inheritedToken = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    delete process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
    try {
      sshFixture = await startSshFixture({
        bindAddress: TARGET_HOST,
        ports: [TARGET_PORT],
        username,
        password,
      });
    } finally {
      if (inheritedToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = inheritedToken;
    }

    stage = 'ticket issue and cross-node WebSocket connection';
    const ticket = await requestTicket();
    connection = await openRelay(ticket);
    await confirmSshBanner(connection);

    stage = 'cross-node session logout';
    await logoutSession();
    stage = 'live Relay socket closure';
    await assertRelayClosedAfterLogout(connection);
    assertionComplete = true;
    console.log('assert: pg_relay_live_socket_cross_node_revocation=true');
  } finally {
    const cleanupErrors = [];
    if (connection) {
      try { await closeRelay(connection); } catch (_) { cleanupErrors.push('Relay socket cleanup failed'); }
    }
    if (sshFixture) {
      const inheritedToken = process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
      delete process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN;
      try {
        await sshFixture.cleanup();
        const status = sshFixture.status();
        const stopped = sshFixture.servers.every((server) =>
          server.child.exitCode !== null || server.child.signalCode !== null);
        const rootPath = sshFixture.servers[0]
          ? path.dirname(path.dirname(sshFixture.servers[0].logPath)) : null;
        const userLookup = spawnSync('getent', ['passwd', sshFixture.username], {
          encoding: 'utf8', timeout: 5000,
        });
        if (!(status.closed && status.cleaned && stopped && userLookup.status === 2 &&
            (!rootPath || !fs.existsSync(rootPath)))) {
          cleanupErrors.push('OpenSSH fixture cleanup incomplete');
        }
      } catch (_) {
        cleanupErrors.push('OpenSSH fixture cleanup failed');
      } finally {
        if (inheritedToken) process.env.ATERMIUS_PG_RELAY_ACCESS_TOKEN = inheritedToken;
      }
    }
    assertThat(cleanupErrors.length === 0, cleanupErrors[0] || 'acceptance cleanup failed');
    if (assertionComplete) console.log('assert: pg_relay_revocation_cleanup_complete=true');
  }
}

runAcceptance().catch((error) => {
  // Error text is deliberately fixed by the assertion sites. Never print
  // request bodies, tokens, tickets, or fixture credentials.
  const message = error instanceof Error ? error.message : 'unknown failure';
  const safeMessage = SENSITIVE.reduce((text, secret) => text.replaceAll(secret, '[redacted]'), message);
  process.stderr.write(`PG Relay revocation acceptance failed: ${safeMessage}\n`);
  process.exitCode = 1;
});
