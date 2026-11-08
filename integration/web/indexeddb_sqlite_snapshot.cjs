'use strict';

const SQLITE_BLOCK_SIZE = 4096;
const MAX_SQLITE_FILE_BYTES = 64 * 1024 * 1024;

/**
 * Reconstruct one sqlite3/wasm IndexedDbFileSystem file from the on-disk
 * IndexedDB `files` row and its 4096-byte `blocks` records. `blocks` is an
 * array of `{ offset, bytes }`; offsets are byte offsets and block aligned.
 */
function reconstructSqliteFile({ fileId, name, length, blocks }) {
  if (!Number.isSafeInteger(fileId) || fileId <= 0 ||
      typeof name !== 'string' ||
      !Number.isSafeInteger(length) || length < 0 ||
      length > MAX_SQLITE_FILE_BYTES || !Array.isArray(blocks)) {
    throw new TypeError('invalid SQLite file metadata');
  }

  const file = Buffer.alloc(length);
  const seenOffsets = new Set();
  for (const block of blocks) {
    if (!block || !Number.isSafeInteger(block.offset) ||
        block.offset < 0 || block.offset % SQLITE_BLOCK_SIZE !== 0 ||
        block.offset >= length || seenOffsets.has(block.offset)) {
      throw new TypeError('invalid SQLite block offset');
    }
    const bytes = Buffer.from(block.bytes);
    if (bytes.length !== SQLITE_BLOCK_SIZE) {
      throw new TypeError('invalid SQLite block length');
    }
    const copyLength = Math.min(SQLITE_BLOCK_SIZE, length - block.offset);
    bytes.copy(file, block.offset, 0, copyLength);
    seenOffsets.add(block.offset);
  }

  return file;
}

module.exports = {
  MAX_SQLITE_FILE_BYTES,
  SQLITE_BLOCK_SIZE,
  reconstructSqliteFile,
};
