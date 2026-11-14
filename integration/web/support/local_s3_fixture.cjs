'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

async function readRequestBody(request, maxBytes = 256 * 1024 * 1024) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > maxBytes) throw new Error('fixture body exceeded its bounded size');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}

async function startLocalS3Fixture({ bucket, accessKeyId, controlToken }) {
  const objects = new Map();
  const multipartUploads = new Map();
  let raceFirstConditionalMultipartCompletion = true;
  let nextBucketHeadDelayMs = 0;
  const stats = {
    httpRequestCount: 0,
    clientErrorCount: 0,
    headCount: 0,
    bucketHeadCount: 0,
    putCount: 0,
    servicePutCount: 0,
    conditionalServicePutCount: 0,
    unconditionalServicePutCount: 0,
    existingKeyPreconditionCount: 0,
    fixtureProbePutCount: 0,
    lostInitialPutAckCount: 0,
    getCount: 0,
    wrongBucketCount: 0,
    unauthorizedRequestCount: 0,
    malformedUploadCount: 0,
    multipartCreateCount: 0,
    multipartPartCount: 0,
    multipartCompleteCount: 0,
    conditionalMultipartCompleteCount: 0,
    unconditionalMultipartCompleteCount: 0,
    conditionalMultipartConflictCount: 0,
    multipartAbortCount: 0,
  };
  const server = http.createServer((request, response) => {
    stats.httpRequestCount += 1;
    void (async () => {
      const parsed = new URL(request.url || '/', 'http://127.0.0.1');
      const pathname = parsed.pathname;
      if (pathname === '/__fixture/stats') {
        const suppliedToken = Buffer.from(String(request.headers['x-fixture-control-token'] || ''));
        const expectedToken = Buffer.from(String(controlToken || ''));
        const authorized = expectedToken.length > 0
          && suppliedToken.length === expectedToken.length
          && crypto.timingSafeEqual(suppliedToken, expectedToken);
        if (!authorized || request.method !== 'GET') {
          request.resume();
          response.writeHead(404, { 'content-length': '0' });
          response.end();
          return;
        }
        const body = JSON.stringify(stats);
        response.writeHead(200, {
          'content-type': 'application/json',
          'content-length': String(Buffer.byteLength(body)),
        });
        response.end(body);
        return;
      }
      if (pathname === '/__fixture/object') {
        const suppliedToken = Buffer.from(String(request.headers['x-fixture-control-token'] || ''));
        const expectedToken = Buffer.from(String(controlToken || ''));
        const authorized = expectedToken.length > 0
          && suppliedToken.length === expectedToken.length
          && crypto.timingSafeEqual(suppliedToken, expectedToken);
        const key = parsed.searchParams.get('key');
        if (!authorized || !key) {
          request.resume();
          response.writeHead(404, { 'content-length': '0' });
          response.end();
          return;
        }
        if (request.method === 'DELETE') {
          const deleted = objects.delete(key);
          response.writeHead(deleted ? 204 : 404, { 'content-length': '0' });
          response.end();
          return;
        }
        if (request.method === 'PUT') {
          const bytes = await readRequestBody(request);
          if (bytes.length === 0) {
            response.writeHead(400, { 'content-length': '0' });
            response.end();
            return;
          }
          objects.set(key, {
            bytes,
            sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
            md5: crypto.createHash('md5').update(bytes).digest('hex'),
          });
          response.writeHead(204, { 'content-length': '0' });
          response.end();
          return;
        }
        if (request.method === 'PATCH') {
          request.resume();
          const existing = objects.get(key);
          if (!existing || existing.bytes.length === 0) {
            response.writeHead(404, { 'content-length': '0' });
            response.end();
            return;
          }
          const bytes = Buffer.from(existing.bytes);
          bytes[0] ^= 0x01;
          // Keep the original HEAD metadata to model remote content tampering
          // after replication success; GET must still be checked byte-for-byte.
          objects.set(key, { ...existing, bytes });
          response.writeHead(204, { 'content-length': '0' });
          response.end();
          return;
        }
        request.resume();
        response.writeHead(404, { 'content-length': '0' });
        response.end();
        return;
      }
      const authorization = request.headers.authorization || '';
      if (!authorization.includes(`Credential=${accessKeyId}/`)) {
        stats.unauthorizedRequestCount += 1;
      }
      const bucketPrefix = `/${bucket}/`;
      if (request.method === 'HEAD' &&
          (pathname === `/${bucket}` || pathname === `/${bucket}/`)) {
        stats.bucketHeadCount += 1;
        if (!authorization.includes(`Credential=${accessKeyId}/`)) {
          response.writeHead(403, {
            'content-length': '0',
            'x-amz-error-code': 'AccessDenied',
          });
          response.end();
          return;
        }
        const delayMs = nextBucketHeadDelayMs;
        nextBucketHeadDelayMs = 0;
        if (delayMs > 0) {
          await new Promise((resolve) => setTimeout(resolve, delayMs));
        }
        response.writeHead(200, { 'content-length': '0' });
        response.end();
        return;
      }
      if (!pathname.startsWith(bucketPrefix)) {
        stats.wrongBucketCount += 1;
        response.writeHead(404, { 'content-length': '0' });
        response.end();
        return;
      }
      const key = pathname.slice(bucketPrefix.length);
      const existing = objects.get(key);
      const uploadId = parsed.searchParams.get('uploadId');
      if (request.method === 'GET' && parsed.searchParams.has('uploads')) {
        const requestedPrefix = parsed.searchParams.get('prefix') || '';
        const uploadEntries = [...multipartUploads.entries()]
          .filter(([, upload]) => upload.key.startsWith(requestedPrefix))
          .map(([id, upload]) => `<Upload><Key>${upload.key}</Key>` +
            `<UploadId>${id}</UploadId><Initiated>2026-01-01T00:00:00.000Z</Initiated>` +
            `<StorageClass>STANDARD</StorageClass></Upload>`)
          .join('');
        const body = `<ListMultipartUploadsResult><Bucket>${bucket}</Bucket>` +
          `<KeyMarker></KeyMarker><UploadIdMarker></UploadIdMarker>` +
          `<NextKeyMarker></NextKeyMarker><NextUploadIdMarker></NextUploadIdMarker>` +
          `<MaxUploads>1000</MaxUploads><IsTruncated>false</IsTruncated>` +
          `<Prefix>${requestedPrefix}</Prefix>${uploadEntries}</ListMultipartUploadsResult>`;
        response.writeHead(200, {
          'content-type': 'application/xml',
          'content-length': String(Buffer.byteLength(body)),
        });
        response.end(body);
        return;
      }
      if (request.method === 'POST' && parsed.searchParams.has('uploads')) {
        stats.multipartCreateCount += 1;
        const id = `fixture-${crypto.randomUUID()}`;
        multipartUploads.set(id, {
          key,
          expectedSha256: String(
            request.headers['x-amz-meta-atermius-sha256'] || '',
          ),
          parts: new Map(),
        });
        const body = `<InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">` +
          `<Bucket>${bucket}</Bucket><Key>${key}</Key><UploadId>${id}</UploadId>` +
          `</InitiateMultipartUploadResult>`;
        response.writeHead(200, {
          'content-type': 'application/xml',
          'content-length': String(Buffer.byteLength(body)),
        });
        response.end(body);
        return;
      }
      if (request.method === 'POST' && uploadId) {
        stats.multipartCompleteCount += 1;
        if (request.headers['if-none-match'] === '*') {
          stats.conditionalMultipartCompleteCount += 1;
        } else {
          stats.unconditionalMultipartCompleteCount += 1;
        }
        const upload = multipartUploads.get(uploadId);
        if (!upload || upload.key !== key) {
          response.writeHead(404, {
            'content-length': '0',
            'x-amz-error-code': 'NoSuchUpload',
          });
          response.end();
          return;
        }
        if (existing) {
          stats.existingKeyPreconditionCount += 1;
          request.resume();
          const errorBody = '<Error><Code>PreconditionFailed</Code></Error>';
          response.writeHead(412, {
            'content-type': 'application/xml',
            'content-length': String(Buffer.byteLength(errorBody)),
            'x-amz-error-code': 'PreconditionFailed',
          });
          response.end(errorBody);
          return;
        }
        await readRequestBody(request);
        const orderedParts = [...upload.parts.entries()]
          .sort(([left], [right]) => Number(left) - Number(right))
          .map(([, bytes]) => bytes);
        const bytes = Buffer.concat(orderedParts);
        const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
        if (bytes.length === 0 || sha256 !== upload.expectedSha256) {
          stats.malformedUploadCount += 1;
          response.writeHead(400, {
            'content-length': '0',
            'x-amz-error-code': 'InvalidDigest',
          });
          response.end();
          return;
        }
        const md5 = crypto.createHash('md5').update(bytes).digest('hex');
        if (raceFirstConditionalMultipartCompletion &&
            request.headers['if-none-match'] === '*') {
          // Model another conditional writer winning the same archive key
          // between multipart upload and completion. The server must handle
          // the real 412 by verifying that the competing object's digest and
          // bytes match before marking replication complete.
          raceFirstConditionalMultipartCompletion = false;
          stats.conditionalMultipartConflictCount += 1;
          objects.set(key, { bytes, sha256, md5 });
          const errorBody = '<Error><Code>PreconditionFailed</Code></Error>';
          response.writeHead(412, {
            'content-type': 'application/xml',
            'content-length': String(Buffer.byteLength(errorBody)),
            'x-amz-error-code': 'PreconditionFailed',
          });
          response.end(errorBody);
          return;
        }
        objects.set(key, { bytes, sha256, md5 });
        multipartUploads.delete(uploadId);
        const body = `<CompleteMultipartUploadResult><Location>fixture</Location>` +
          `<Bucket>${bucket}</Bucket><Key>${key}</Key><ETag>&quot;${md5}&quot;</ETag>` +
          `</CompleteMultipartUploadResult>`;
        response.writeHead(200, {
          'content-type': 'application/xml',
          'content-length': String(Buffer.byteLength(body)),
        });
        response.end(body);
        return;
      }
      if (request.method === 'DELETE' && uploadId) {
        stats.multipartAbortCount += 1;
        multipartUploads.delete(uploadId);
        response.writeHead(204, { 'content-length': '0' });
        response.end();
        return;
      }
      if (request.method === 'HEAD') {
        stats.headCount += 1;
        if (!existing) {
          response.writeHead(404, {
            'content-length': '0',
            'x-amz-error-code': 'NoSuchKey',
            'x-amz-request-id': 'loopback-fixture',
          });
          response.end();
          return;
        }
        response.writeHead(200, {
          'content-length': String(existing.bytes.length),
          'content-type': 'application/octet-stream',
          'etag': `"${existing.md5}"`,
          'x-amz-meta-atermius-sha256': existing.sha256,
        });
        response.end();
        return;
      }
      if (request.method === 'PUT') {
        const partNumber = parsed.searchParams.get('partNumber');
        if (uploadId && partNumber) {
          stats.multipartPartCount += 1;
          const upload = multipartUploads.get(uploadId);
          if (!upload || upload.key !== key || !/^\d+$/.test(partNumber)) {
            request.resume();
            response.writeHead(404, {
              'content-length': '0',
              'x-amz-error-code': 'NoSuchUpload',
            });
            response.end();
            return;
          }
          const bytes = await readRequestBody(request);
          const md5 = crypto.createHash('md5').update(bytes).digest('hex');
          upload.parts.set(partNumber, bytes);
          response.writeHead(200, {
            'content-length': '0',
            'etag': `"${md5}"`,
          });
          response.end();
          return;
        }
        stats.putCount += 1;
        const isFixtureProbe = request.headers['x-replication-fixture-probe'] === 'yes';
        if (isFixtureProbe) {
          stats.fixtureProbePutCount += 1;
        } else {
          stats.servicePutCount += 1;
          if (request.headers['if-none-match'] === '*') {
            stats.conditionalServicePutCount += 1;
          } else {
            stats.unconditionalServicePutCount += 1;
          }
        }
        if (existing) {
          // S3 conditional object creation must never replace an existing
          // object, even when the retried bytes happen to have the same hash.
          stats.existingKeyPreconditionCount += 1;
          request.resume();
          const errorBody = '<Error><Code>PreconditionFailed</Code></Error>';
          response.writeHead(412, {
            'content-type': 'application/xml',
            'content-length': String(Buffer.byteLength(errorBody)),
            'x-amz-error-code': 'PreconditionFailed',
          });
          response.end(errorBody);
          return;
        }
        const bytes = await readRequestBody(request);
        const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
        const declared = String(request.headers['x-amz-meta-atermius-sha256'] || '');
        if (declared !== sha256 || bytes.length === 0) {
          stats.malformedUploadCount += 1;
          response.writeHead(400, {
            'content-length': '0',
            'x-amz-error-code': 'InvalidDigest',
          });
          response.end();
          return;
        }
        const md5 = crypto.createHash('md5').update(bytes).digest('hex');
        objects.set(key, { bytes, sha256, md5 });
        if (!isFixtureProbe && stats.lostInitialPutAckCount === 0) {
          // Model an uncertain completion: the remote write is durable but
          // the first response is lost. A retry must validate the same object
          // instead of overwriting it.
          stats.lostInitialPutAckCount += 1;
          const errorBody = '<Error><Code>InternalError</Code></Error>';
          response.writeHead(500, {
            'content-type': 'application/xml',
            'content-length': String(Buffer.byteLength(errorBody)),
          });
          response.end(errorBody);
          return;
        }
        response.writeHead(200, {
          'content-length': '0',
          'etag': `"${md5}"`,
        });
        response.end();
        return;
      }
      if (request.method === 'GET') {
        stats.getCount += 1;
        if (!existing) {
          response.writeHead(404, {
            'content-length': '0',
            'x-amz-error-code': 'NoSuchKey',
          });
          response.end();
          return;
        }
        response.writeHead(200, {
          'content-length': String(existing.bytes.length),
          'content-type': 'application/octet-stream',
          'etag': `"${existing.md5}"`,
          'x-amz-meta-atermius-sha256': existing.sha256,
        });
        response.end(existing.bytes);
        return;
      }
      response.writeHead(501, { 'content-length': '0' });
      response.end();
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500, { 'content-length': '0' });
      response.end();
    });
  });
  server.on('clientError', (_error, socket) => {
    stats.clientErrorCount += 1;
    socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assertThat(address && typeof address === 'object', 'loopback S3 fixture did not bind');
  return {
    server,
    objects,
    stats,
    endpointUrl: `http://127.0.0.1:${address.port}`,
    async conditionalPutProbe(key, bytes, sha256) {
      const objectUrl = new URL(`/${bucket}/${key}`, this.endpointUrl);
      const response = await fetch(objectUrl, {
        method: 'PUT',
        headers: {
          authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/fixture/s3/aws4_request`,
          'if-none-match': '*',
          'x-amz-meta-atermius-sha256': sha256,
          'x-replication-fixture-probe': 'yes',
        },
        body: bytes,
        signal: AbortSignal.timeout(10000),
      });
      await response.arrayBuffer();
      return response.status;
    },
    delayNextBucketHead(delayMs) {
      assertThat(Number.isInteger(delayMs) && delayMs >= 0 && delayMs <= 25000,
        'bucket Head delay must be an integer within the fixture bound');
      nextBucketHeadDelayMs = delayMs;
    },
    async close() {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(() => resolve()));
      objects.clear();
      multipartUploads.clear();
    },
  };
}


module.exports = { startLocalS3Fixture };
