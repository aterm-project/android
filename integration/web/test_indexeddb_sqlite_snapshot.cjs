'use strict';

const assert = require('node:assert/strict');
const { reconstructSqliteFile } = require('./indexeddb_sqlite_snapshot.cjs');

const first = Buffer.alloc(4096, 0x41);
const final = Buffer.alloc(4096, 0x42);
const result = reconstructSqliteFile({
  fileId: 7,
  name: '/database',
  length: 4100,
  blocks: [
    { offset: 0, bytes: first },
    { offset: 4096, bytes: final },
  ],
});

assert.equal(result.length, 4100);
assert.equal(result.subarray(0, 4096).every((byte) => byte === 0x41), true);
assert.equal(result.subarray(4096).every((byte) => byte === 0x42), true);

const withMissingBlock = reconstructSqliteFile({
  fileId: 8,
  name: '/database',
  length: 8192,
  blocks: [{ offset: 4096, bytes: final }],
});
assert.equal(withMissingBlock.subarray(0, 4096).every((byte) => byte === 0), true);
assert.equal(withMissingBlock.subarray(4096).every((byte) => byte === 0x42), true);

assert.throws(() => reconstructSqliteFile({
  fileId: 9,
  name: '/database',
  length: 1,
  blocks: [
    { offset: 0, bytes: first },
    { offset: 0, bytes: first },
  ],
}), /invalid SQLite block offset/);

assert.throws(() => reconstructSqliteFile({
  fileId: 9,
  name: '/database',
  length: 1,
  blocks: [{ offset: 0, bytes: Buffer.alloc(12) }],
}), /invalid SQLite block length/);

console.log('IndexedDB SQLite block snapshot reconstruction passed');
