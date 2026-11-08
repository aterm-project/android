/*
 * One deterministic loopback S3 fake shared by the Web and Python object-store
 * acceptance runners. It implements only Atermius' opaque-object Put/Head/Get
 * (single Range) /Delete calls, not a complete S3 service. Every S3 operation
 * is checked with a canonical-request and HMAC SigV4 verifier.
 *
 * The optional standalone mode exposes a separate, loopback-only, token-gated
 * control API so Python tests can spawn this exact fake instead of maintaining
 * a second protocol implementation. The S3 endpoint itself accepts only the
 * configured access-key ID and never logs request headers or payloads.
 */

'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const { once } = require('node:events');

const CONTROL_PATH = '/__atermius_fixture__/control';
const MAX_OBJECT_BYTES = 64 * 1024 * 1024;
const CONTROL_BODY_LIMIT = 2 * 1024 * 1024;
const SINGLE_RANGE = /^bytes=(\d*)-(\d*)$/i;

function assertSafeKey(key) {
  if (typeof key !== 'string' || !key || key.startsWith('/') ||
      key.split('/').some((part) => part === '' || part === '.' || part === '..')) {
    throw new Error('fixture object key is invalid');
  }
}

function parseRange(value, size) {
  const match = SINGLE_RANGE.exec(String(value || '').trim());
  if (!match || String(value).includes(',') || size <= 0) return null;
  const [, first, last] = match;
  if (!first) {
    const suffix = Number(last);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    return [Math.max(0, size - suffix), size - 1];
  }
  const start = Number(first);
  const end = last ? Number(last) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || start >= size || end < start) return null;
  return [start, Math.min(end, size - 1)];
}

async function readBoundedBody(request, limit) {
  const lengthText = request.headers['content-length'];
  const chunked = /(?:^|,)\s*chunked\s*(?:,|$)/i.test(
    String(request.headers['transfer-encoding'] || ''),
  );
  if (!chunked && !/^\d+$/.test(String(lengthText || ''))) {
    throw new Error('missing content length');
  }
  const length = chunked ? null : Number(lengthText);
  if (length !== null && (!Number.isSafeInteger(length) || length <= 0 || length > limit)) {
    throw new Error('body length outside fixture limit');
  }
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > limit) throw new Error('body exceeds fixture limit');
    chunks.push(chunk);
  }
  if (total === 0 || (length !== null && total !== length)) {
    throw new Error('truncated request body');
  }
  return Buffer.concat(chunks, total);
}

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function awsEncode(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
}

function canonicalPathname(pathname) {
  return pathname.split('/').map((part) => {
    let decoded;
    try {
      decoded = decodeURIComponent(part);
    } catch (_) {
      return null;
    }
    return awsEncode(decoded);
  }).join('/');
}

function canonicalQuery(searchParams) {
  const pairs = [...searchParams.entries()].map(([name, value]) =>
    [awsEncode(name), awsEncode(value)]);
  pairs.sort(([nameA, valueA], [nameB, valueB]) =>
    (nameA < nameB ? -1 : nameA > nameB ? 1 :
      valueA < valueB ? -1 : valueA > valueB ? 1 : 0));
  return pairs.map(([name, value]) => `${name}=${value}`).join('&');
}

function hmac(key, value, encoding) {
  const result = crypto.createHmac('sha256', key).update(value).digest();
  return encoding === 'hex' ? result.toString('hex') : result;
}

function verifySigV4(request, parsed, body, {
  accessKeyId, secretAccessKey, region, sessionToken,
}) {
  const authorization = request.headers.authorization || '';
  const match = /^AWS4-HMAC-SHA256 Credential=([^/]+)\/(\d{8})\/([^/]+)\/s3\/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$/i.exec(authorization);
  if (!match || match[1] !== accessKeyId || match[3] !== region) return false;

  const [, credentialId, scopeDate, scopeRegion, signedHeaderText, signature] = match;
  void credentialId;
  void scopeRegion;
  const requestDate = request.headers['x-amz-date'];
  if (!/^\d{8}T\d{6}Z$/.test(String(requestDate || '')) ||
      requestDate.slice(0, 8) !== scopeDate) return false;
  const year = requestDate.slice(0, 4);
  const month = requestDate.slice(4, 6);
  const day = requestDate.slice(6, 8);
  const hour = requestDate.slice(9, 11);
  const minute = requestDate.slice(11, 13);
  const second = requestDate.slice(13, 15);
  const timestamp = Date.parse(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
  if (!Number.isFinite(timestamp) || Math.abs(Date.now() - timestamp) > 15 * 60 * 1000) return false;

  const signedHeaders = signedHeaderText.split(';');
  if (!signedHeaders.length || signedHeaders.join(';') !== [...signedHeaders].sort().join(';') ||
      !signedHeaders.includes('host') || !signedHeaders.includes('x-amz-date') ||
      !signedHeaders.includes('x-amz-content-sha256')) return false;
  const requestSessionToken = request.headers['x-amz-security-token'];
  if (sessionToken) {
    if (requestSessionToken !== sessionToken ||
        !signedHeaders.includes('x-amz-security-token')) return false;
  } else if (requestSessionToken !== undefined ||
      signedHeaders.includes('x-amz-security-token')) {
    return false;
  }
  const payloadHash = String(request.headers['x-amz-content-sha256'] || '');
  const actualPayloadHash = crypto.createHash('sha256').update(body).digest('hex');
  if (payloadHash !== 'UNSIGNED-PAYLOAD' && payloadHash !== actualPayloadHash) return false;
  if (!/^(UNSIGNED-PAYLOAD|[0-9a-f]{64})$/i.test(payloadHash)) return false;

  const canonicalHeaders = [];
  for (const name of signedHeaders) {
    const headerValue = name === 'host' ? request.headers.host : request.headers[name];
    if (headerValue === undefined) return false;
    const normalized = (Array.isArray(headerValue) ? headerValue.join(',') : String(headerValue))
      .trim().replace(/\s+/g, ' ');
    canonicalHeaders.push(`${name}:${normalized}\n`);
  }
  const path = canonicalPathname(parsed.pathname);
  if (path === null) return false;
  const canonicalRequest = [
    request.method,
    path,
    canonicalQuery(parsed.searchParams),
    canonicalHeaders.join(''),
    signedHeaderText,
    payloadHash,
  ].join('\n');
  const requestHash = crypto.createHash('sha256').update(canonicalRequest).digest('hex');
  const scope = `${scopeDate}/${scopeRegion}/s3/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${requestDate}\n${scope}\n${requestHash}`;
  const dateKey = hmac(`AWS4${secretAccessKey}`, scopeDate);
  const regionKey = hmac(dateKey, scopeRegion);
  const serviceKey = hmac(regionKey, 's3');
  const signingKey = hmac(serviceKey, 'aws4_request');
  const expectedSignature = hmac(signingKey, stringToSign, 'hex');
  return safeEqual(expectedSignature, signature);
}

async function startOpaqueObjectStoreFixture({
  bucket = 'atermius-objects-fixture',
  region = 'us-east-1',
  accessKeyId = 'fixture-access-key',
  secretAccessKey = 'fixture-secret-key-not-for-production',
  sessionToken = null,
  maxObjectBytes = MAX_OBJECT_BYTES,
  controlToken = crypto.randomBytes(32).toString('base64url'),
} = {}) {
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket)) {
    throw new Error('fixture bucket name is invalid');
  }
  if (!accessKeyId || !secretAccessKey || !region ||
      (sessionToken !== null && (typeof sessionToken !== 'string' || !sessionToken)) ||
      !Number.isInteger(maxObjectBytes) || maxObjectBytes < 1 ||
      maxObjectBytes > MAX_OBJECT_BYTES) {
    throw new Error('fixture settings are invalid');
  }

  const objects = new Map();
  const requests = [];
  const faults = [];
  const stats = {
    httpRequests: 0,
    unauthorized: 0,
    wrongBucketOrKey: 0,
    head: 0,
    put: 0,
    conditionalPut: 0,
    unconditionalPut: 0,
    preconditionConflict: 0,
    get: 0,
    rangeGet: 0,
    delete: 0,
    putBeforeCommitFailures: 0,
    putCommitThenError: 0,
    getUnavailableFailures: 0,
    corruptGetResponses: 0,
    deleteBeforeFailures: 0,
  };
  const server = http.createServer({ maxHeaderSize: 16 * 1024 }, (request, response) => {
    stats.httpRequests += 1;
    response.shouldKeepAlive = false;
    void dispatch(request, response).catch(() => {
      if (!response.headersSent) send(response, 500, errorXml('InternalError'));
      else response.destroy();
    });
  });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;

  function send(response, status, body = Buffer.alloc(0), headers = {}, contentLength = body.length) {
    response.writeHead(status, {
      ...headers,
      'content-length': String(contentLength),
      connection: 'close',
    });
    if (body.length) response.end(body);
    else response.end();
  }

  function errorXml(code) {
    return Buffer.from(
      `<?xml version="1.0" encoding="UTF-8"?><Error><Code>${code}</Code>` +
      '<Message>fixture response</Message><RequestId>loopback</RequestId></Error>',
    );
  }

  function record(request, key, status) {
    requests.push({
      method: request.method,
      key,
      status,
      range: request.headers.range || null,
      conditional: request.headers['if-none-match'] === '*',
    });
  }

  function takeFault(operation, key) {
    const index = faults.findIndex((fault) =>
      fault.operation === operation && (fault.key === null || fault.key === key));
    if (index < 0) return null;
    const [fault] = faults.splice(index, 1);
    return fault.mode;
  }

  function s3Path(request) {
    let parsed;
    try {
      parsed = new URL(request.url || '/', 'http://127.0.0.1');
    } catch (_) {
      return { bucketName: null, key: '' };
    }
    const parts = parsed.pathname.split('/');
    if (parts.length < 3 || !parts[1]) return { bucketName: null, key: '' };
    try {
      return {
        bucketName: decodeURIComponent(parts[1]),
        key: decodeURIComponent(parts.slice(2).join('/')),
      };
    } catch (_) {
      return { bucketName: null, key: '' };
    }
  }

  function metadataHeaders(stored) {
    const etag = crypto.createHash('md5').update(stored.bytes).digest('hex');
    return {
      'content-type': 'application/octet-stream',
      etag: `"${etag}"`,
      'x-amz-meta-atermius-sha256': stored.sha256,
    };
  }

  async function dispatch(request, response) {
    const parsed = new URL(request.url || '/', 'http://127.0.0.1');
    const peer = request.socket.remoteAddress;
    if (parsed.pathname === CONTROL_PATH) {
      await dispatchControl(request, response, peer);
      return;
    }

    let requestBody = Buffer.alloc(0);
    if (request.method === 'PUT') {
      try {
        requestBody = await readBoundedBody(request, maxObjectBytes);
      } catch (_) {
        send(response, 400, errorXml('InvalidRequest'), {
          'x-amz-error-code': 'InvalidRequest',
          'content-type': 'application/xml',
        });
        record(request, '', 400);
        return;
      }
    }
    if (!verifySigV4(request, parsed, requestBody, {
      accessKeyId, secretAccessKey, region, sessionToken,
    })) {
      stats.unauthorized += 1;
      const body = errorXml('AccessDenied');
      send(response, 403, request.method === 'HEAD' ? Buffer.alloc(0) : body, {
        'x-amz-error-code': 'AccessDenied',
        'x-amz-request-id': 'loopback-fixture',
        'content-type': 'application/xml',
      });
      record(request, '', 403);
      return;
    }

    const { bucketName, key } = s3Path(request);
    if (bucketName !== bucket || !key ||
        key.split('/').some((part) => part === '.' || part === '..')) {
      stats.wrongBucketOrKey += 1;
      const body = errorXml('NoSuchKey');
      send(response, 404, request.method === 'HEAD' ? Buffer.alloc(0) : body, {
        'x-amz-error-code': 'NoSuchKey',
        'x-amz-request-id': 'loopback-fixture',
        'content-type': 'application/xml',
      });
      record(request, key, 404);
      return;
    }

    const existing = objects.get(key) || null;
    if (request.method === 'HEAD') {
      stats.head += 1;
      if (!existing) {
        const body = errorXml('NoSuchKey');
        send(response, 404, Buffer.alloc(0), {
          'x-amz-error-code': 'NoSuchKey',
          'x-amz-request-id': 'loopback-fixture',
          'content-type': 'application/xml',
        });
      } else {
        send(response, 200, Buffer.alloc(0), metadataHeaders(existing), existing.bytes.length);
      }
      record(request, key, existing ? 200 : 404);
      return;
    }

    if (request.method === 'PUT') {
      stats.put += 1;
      const mode = takeFault('put', key);
      if (mode === 'before_commit') {
        stats.putBeforeCommitFailures += 1;
        send(response, 503, errorXml('ServiceUnavailable'), {
          'x-amz-error-code': 'ServiceUnavailable',
          'content-type': 'application/xml',
        });
        record(request, key, 503);
        return;
      }
      const bytes = requestBody;
      const digest = crypto.createHash('sha256').update(bytes).digest('hex');
      if (String(request.headers['x-amz-meta-atermius-sha256'] || '').toLowerCase() !== digest) {
        send(response, 400, errorXml('InvalidDigest'), {
          'x-amz-error-code': 'InvalidDigest',
          'content-type': 'application/xml',
        });
        record(request, key, 400);
        return;
      }
      const checksum = request.headers['x-amz-checksum-sha256'];
      const digestBase64 = crypto.createHash('sha256').update(bytes).digest('base64');
      if (checksum !== undefined && checksum !== digestBase64) {
        send(response, 400, errorXml('BadDigest'), {
          'x-amz-error-code': 'BadDigest',
          'content-type': 'application/xml',
        });
        record(request, key, 400);
        return;
      }
      const conditional = request.headers['if-none-match'] === '*';
      if (conditional) stats.conditionalPut += 1;
      else stats.unconditionalPut += 1;
      if (conditional && existing) {
        stats.preconditionConflict += 1;
        send(response, 412, errorXml('PreconditionFailed'), {
          'x-amz-error-code': 'PreconditionFailed',
          'content-type': 'application/xml',
        });
        record(request, key, 412);
        return;
      }
      objects.set(key, { bytes: Buffer.from(bytes), sha256: digest });
      if (mode === 'commit_then_error') {
        stats.putCommitThenError += 1;
        send(response, 500, errorXml('InternalError'), {
          'x-amz-error-code': 'InternalError',
          'content-type': 'application/xml',
        });
        record(request, key, 500);
        return;
      }
      send(response, 200, Buffer.alloc(0), metadataHeaders({ bytes, sha256: digest }));
      record(request, key, 200);
      return;
    }

    if (request.method === 'GET') {
      stats.get += 1;
      const mode = takeFault('get', key);
      if (mode === 'unavailable') {
        stats.getUnavailableFailures += 1;
        send(response, 503, errorXml('ServiceUnavailable'), {
          'x-amz-error-code': 'ServiceUnavailable',
          'content-type': 'application/xml',
        });
        record(request, key, 503);
        return;
      }
      if (!existing) {
        send(response, 404, errorXml('NoSuchKey'), {
          'x-amz-error-code': 'NoSuchKey',
          'content-type': 'application/xml',
        });
        record(request, key, 404);
        return;
      }
      let bytes = Buffer.from(existing.bytes);
      const headers = metadataHeaders(existing);
      let status = 200;
      if (request.headers.range) {
        const selected = parseRange(request.headers.range, bytes.length);
        if (!selected) {
          send(response, 416, Buffer.alloc(0), {
            ...headers,
            'content-range': `bytes */${bytes.length}`,
          });
          record(request, key, 416);
          return;
        }
        const [start, end] = selected;
        bytes = bytes.subarray(start, end + 1);
        headers['content-range'] = `bytes ${start}-${end}/${existing.bytes.length}`;
        status = 206;
        stats.rangeGet += 1;
      }
      if (mode === 'corrupt_response' && bytes.length) {
        bytes = Buffer.from(bytes);
        bytes[0] ^= 0x01;
        stats.corruptGetResponses += 1;
      }
      send(response, status, bytes, headers);
      record(request, key, status);
      return;
    }

    if (request.method === 'DELETE') {
      stats.delete += 1;
      const mode = takeFault('delete', key);
      if (mode === 'before_delete') {
        stats.deleteBeforeFailures += 1;
        send(response, 503, errorXml('ServiceUnavailable'), {
          'x-amz-error-code': 'ServiceUnavailable',
          'content-type': 'application/xml',
        });
        record(request, key, 503);
        return;
      }
      const expectedEtag = existing ? metadataHeaders(existing).etag : null;
      if (request.headers['if-match'] !== undefined &&
          (!expectedEtag || request.headers['if-match'] !== expectedEtag)) {
        send(response, 412, errorXml('PreconditionFailed'), {
          'x-amz-error-code': 'PreconditionFailed',
          'content-type': 'application/xml',
        });
        record(request, key, 412);
        return;
      }
      objects.delete(key);
      send(response, 204);
      record(request, key, 204);
      return;
    }

    send(response, 501, errorXml('NotImplemented'), {
      'x-amz-error-code': 'NotImplemented',
      'content-type': 'application/xml',
    });
    record(request, key, 501);
  }

  async function readControlBody(request) {
    const chunks = [];
    let total = 0;
    for await (const chunk of request) {
      total += chunk.length;
      if (total > CONTROL_BODY_LIMIT) throw new Error('control body too large');
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks, total).toString('utf8') || '{}');
  }

  function isLoopback(peer) {
    return peer === '127.0.0.1' || peer === '::1' || peer === '::ffff:127.0.0.1';
  }

  async function dispatchControl(request, response, peer) {
    if (!isLoopback(peer) || request.method !== 'POST' ||
        !safeEqual(request.headers['x-atermius-fixture-token'], controlToken)) {
      send(response, 404);
      return;
    }
    let command;
    try {
      command = await readControlBody(request);
    } catch (_) {
      send(response, 400, Buffer.from('{"error":"invalid control request"}'), {
        'content-type': 'application/json',
      });
      return;
    }
    try {
      let result = {};
      if (command.action === 'stats') {
        result = {
          stats: { ...stats },
          requests: requests.map((item) => ({ ...item })),
          keys: [...objects.keys()],
        };
      } else if (command.action === 'request_count') {
        result = {
          count: requests.filter((item) => item.method === command.method &&
            (command.key === undefined || item.key === command.key)).length,
        };
      } else if (command.action === 'get_object') {
        assertSafeKey(command.key);
        const object = objects.get(command.key);
        result = object ? {
          exists: true,
          size: object.bytes.length,
          sha256: object.sha256,
          body_sha256: crypto.createHash('sha256').update(object.bytes).digest('hex'),
        } : { exists: false };
      } else if (command.action === 'seed_object') {
        assertSafeKey(command.key);
        const bytes = Buffer.from(String(command.body_base64 || ''), 'base64');
        if (!bytes.length || bytes.length > maxObjectBytes) throw new Error('seed size invalid');
        const sha256 = command.sha256 || crypto.createHash('sha256').update(bytes).digest('hex');
        objects.set(command.key, { bytes, sha256 });
        result = { seeded: true };
      } else if (command.action === 'corrupt_object') {
        assertSafeKey(command.key);
        const object = objects.get(command.key);
        if (!object || !object.bytes.length) throw new Error('object unavailable');
        const bytes = Buffer.from(object.bytes);
        bytes[0] ^= 0x80;
        objects.set(command.key, { bytes, sha256: object.sha256 });
        result = { corrupted: true };
      } else if (command.action === 'remove_object') {
        assertSafeKey(command.key);
        result = { removed: objects.delete(command.key) };
      } else if (command.action === 'inject_fault') {
        const allowed = {
          put: ['before_commit', 'commit_then_error'],
          get: ['unavailable', 'corrupt_response'],
          delete: ['before_delete'],
        };
        if (!allowed[command.operation]?.includes(command.mode)) throw new Error('fault invalid');
        if (command.key !== undefined) assertSafeKey(command.key);
        const count = command.count === undefined ? 1 : command.count;
        if (!Number.isInteger(count) || count < 1 || count > 16) throw new Error('fault count invalid');
        for (let index = 0; index < count; index += 1) {
          faults.push({
            operation: command.operation,
            mode: command.mode,
            key: command.key === undefined ? null : command.key,
          });
        }
        result = { injected: true, count };
      } else if (command.action === 'shutdown') {
        result = { stopping: true };
        send(response, 200, Buffer.from(JSON.stringify(result)), {
          'content-type': 'application/json',
        });
        setImmediate(() => { void close(); });
        return;
      } else {
        throw new Error('action invalid');
      }
      send(response, 200, Buffer.from(JSON.stringify(result)), {
        'content-type': 'application/json',
      });
    } catch (_) {
      send(response, 400, Buffer.from('{"error":"invalid control request"}'), {
        'content-type': 'application/json',
      });
    }
  }

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (!address || typeof address === 'string' || address.address !== '127.0.0.1') {
    server.close();
    throw new Error('fixture failed to bind IPv4 loopback');
  }
  const endpointUrl = `http://127.0.0.1:${address.port}`;
  const controlUrl = endpointUrl + CONTROL_PATH;
  let closed = false;

  function addFault({ operation, mode, key = null, count = 1 }) {
    const allowed = {
      put: ['before_commit', 'commit_then_error'],
      get: ['unavailable', 'corrupt_response'],
      delete: ['before_delete'],
    };
    if (!allowed[operation]?.includes(mode)) throw new Error('fixture fault is invalid');
    if (!Number.isInteger(count) || count < 1 || count > 16) throw new Error('fixture fault count is invalid');
    if (key !== null) assertSafeKey(key);
    for (let index = 0; index < count; index += 1) faults.push({ operation, mode, key });
  }

  function seedObject(key, bytes, { sha256 } = {}) {
    assertSafeKey(key);
    const body = Buffer.from(bytes);
    if (!body.length || body.length > maxObjectBytes) throw new Error('fixture object size is invalid');
    const digest = sha256 || crypto.createHash('sha256').update(body).digest('hex');
    objects.set(key, { bytes: body, sha256: digest });
  }

  function corruptObject(key) {
    assertSafeKey(key);
    const stored = objects.get(key);
    if (!stored || !stored.bytes.length) throw new Error('fixture object is unavailable');
    const bytes = Buffer.from(stored.bytes);
    bytes[0] ^= 0x80;
    objects.set(key, { bytes, sha256: stored.sha256 });
  }

  function removeObject(key) {
    assertSafeKey(key);
    return objects.delete(key);
  }

  function getObject(key) {
    assertSafeKey(key);
    const stored = objects.get(key);
    if (!stored) return null;
    return { bytes: Buffer.from(stored.bytes), sha256: stored.sha256 };
  }

  function requestCount(method, { key } = {}) {
    return requests.filter((item) => item.method === method &&
      (key === undefined || item.key === key)).length;
  }

  async function close() {
    if (closed) return;
    closed = true;
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(() => resolve()));
    objects.clear();
    requests.length = 0;
    faults.length = 0;
  }

  return {
    server,
    endpointUrl,
    controlUrl,
    controlToken,
    bucket,
    accessKeyId,
    secretAccessKey,
    objects,
    stats,
    requests,
    injectFault: addFault,
    seedObject,
    corruptObject,
    removeObject,
    getObject,
    requestCount,
    close,
  };
}

async function runStandalone() {
  const options = {
    bucket: process.env.ATERMIUS_S3_FIXTURE_BUCKET,
    region: process.env.ATERMIUS_S3_FIXTURE_REGION || 'us-east-1',
    accessKeyId: process.env.ATERMIUS_S3_FIXTURE_ACCESS_KEY_ID,
    secretAccessKey: process.env.ATERMIUS_S3_FIXTURE_SECRET_ACCESS_KEY,
    sessionToken: process.env.ATERMIUS_S3_FIXTURE_SESSION_TOKEN || null,
    maxObjectBytes: Number(process.env.ATERMIUS_S3_FIXTURE_MAX_OBJECT_BYTES || MAX_OBJECT_BYTES),
    controlToken: process.env.ATERMIUS_S3_FIXTURE_CONTROL_TOKEN,
  };
  if (!options.bucket || !options.accessKeyId || !options.secretAccessKey || !options.controlToken) {
    process.stderr.write('fixture standalone settings are incomplete\n');
    process.exitCode = 2;
    return;
  }
  const fixture = await startOpaqueObjectStoreFixture(options);
  process.stdout.write(`${JSON.stringify({
    ready: true,
    endpointUrl: fixture.endpointUrl,
    controlUrl: fixture.controlUrl,
  })}\n`);
  const stop = async () => {
    await fixture.close();
    process.exit(0);
  };
  process.once('SIGINT', () => { void stop(); });
  process.once('SIGTERM', () => { void stop(); });
  await once(fixture.server, 'close');
}

if (require.main === module && process.argv.includes('--standalone')) {
  void runStandalone().catch(() => {
    process.stderr.write('fixture failed to start\n');
    process.exitCode = 1;
  });
}

module.exports = {
  CONTROL_PATH,
  MAX_OBJECT_BYTES,
  startOpaqueObjectStoreFixture,
};
