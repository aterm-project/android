'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const { chromium } = require('playwright');
const { buildIdbWriteFailureWorkerPrelude } = require('./idb_write_failure_worker.cjs');

const channelName = `atermius-idb-probe-${process.pid}-${Date.now()}`;

async function main() {
  let browser;
  let server;
  let context;
  try {
    server = http.createServer((request, response) => {
      if (request.url === '/drift_worker.js') {
        response.writeHead(200, { 'content-type': 'text/javascript' });
        response.end(`${buildIdbWriteFailureWorkerPrelude(channelName)}
          self.onconnect = (event) => {
            for (const port of event.ports) {
              port.onmessage = (message) => {
                if (message.data?.type !== 'write') return;
                const open = indexedDB.open('atermius_vault', 1);
                open.onupgradeneeded = () => open.result.createObjectStore('blocks');
                open.onsuccess = () => {
                  const database = open.result;
                  const transaction = database.transaction(['blocks'], 'readwrite');
                  transaction.addEventListener('complete', () => database.close(), {once: true});
                  transaction.addEventListener('abort', () => database.close(), {once: true});
                  transaction.objectStore('blocks').put(
                    new ArrayBuffer(8), message.data.key || [1, 0]);
                  transaction.commit();
                };
              };
              port.start();
            }
          };
        `);
        return;
      }
      response.writeHead(200, { 'content-type': 'text/html' });
      response.end('<!doctype html><html><body>IndexedDB worker probe</body></html>');
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const { port } = server.address();
    browser = await chromium.launch({
      headless: true,
      ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
        ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE }
        : {}),
    });
    context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/`);
    const result = await page.evaluate(async (workerChannelName) => {
      const events = [];
      let database;
      let worker;
      const channel = new BroadcastChannel(workerChannelName);
      const listeners = new Set();
      channel.onmessage = (message) => {
        if (typeof message.data?.type !== 'string') return;
        events.push(message.data.type);
        for (const listener of [...listeners]) listener(message.data.type);
      };
      const waitFor = (type) => {
        if (events.includes(type)) return Promise.resolve();
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            listeners.delete(onEvent);
            reject(new Error(`missing-${type}`));
          }, 3000);
          const onEvent = (observed) => {
            if (observed !== type) return;
            clearTimeout(timer);
            listeners.delete(onEvent);
            resolve();
          };
          listeners.add(onEvent);
        });
      };
      const countEvents = (type) =>
        events.filter((observed) => observed === type).length;
      const waitForCount = (type, minimumCount) => {
        if (countEvents(type) >= minimumCount) return Promise.resolve();
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            listeners.delete(onEvent);
            reject(new Error(`missing-${type}`));
          }, 3000);
          const onEvent = (observed) => {
            if (observed !== type || countEvents(type) < minimumCount) return;
            clearTimeout(timer);
            listeners.delete(onEvent);
            resolve();
          };
          listeners.add(onEvent);
        });
      };
      let persisted = null;
      let unrelatedWritePersisted = null;
      let checkpointWritePersisted = null;
      let failedAt = null;
      try {
        worker = new SharedWorker('/drift_worker.js');
        worker.port.start();
        await waitFor('worker-route-loaded');
        channel.postMessage({ type: 'arm', deferAbortForConcurrentRead: true });
        await waitFor('armed');
        worker.port.postMessage({ type: 'write' });
        await waitFor('write-transaction-targeted');
        await waitFor('write-transaction-commit-held');
        channel.postMessage({ type: 'continue-abort' });
        await waitFor('write-transaction-abort-requested');
        await waitFor('write-transaction-abort-event');
        const open = indexedDB.open('atermius_vault', 1);
        database = await new Promise((resolve, reject) => {
          open.onsuccess = () => resolve(open.result);
          open.onerror = () => reject(open.error);
        });
        const read = database.transaction(['blocks'], 'readonly')
          .objectStore('blocks').get([1, 0]);
        persisted = await new Promise((resolve, reject) => {
          read.onsuccess = () => resolve(read.result !== undefined);
          read.onerror = () => reject(read.error);
        });

        const readKey = async (key) => {
          const request = database.transaction(['blocks'], 'readonly')
            .objectStore('blocks').get(key);
          return new Promise((resolve, reject) => {
            request.onsuccess = () => resolve(request.result !== undefined);
            request.onerror = () => reject(request.error);
          });
        };
        const armedCountBeforeCheckpoint = countEvents('armed');
        channel.postMessage({
          type: 'arm',
          requireCheckpointWrite: true,
        });
        await waitForCount('armed', armedCountBeforeCheckpoint + 1);
        const skippedCountBeforeWrite =
          countEvents('write-transaction-skipped-before-checkpoint-sql');
        worker.port.postMessage([0, [], [3, 2,
          'INSERT INTO encrypted_records (record_id) VALUES (?)', [], null]]);
        worker.port.postMessage({ type: 'write', key: [1, 1] });
        await waitForCount('write-transaction-skipped-before-checkpoint-sql',
          skippedCountBeforeWrite + 1);
        unrelatedWritePersisted = await readKey([1, 1]);
        const checkpointSqlCountBefore =
          countEvents('checkpoint-write-sql-observed');
        worker.port.postMessage([0, [], [3, 2,
          'INSERT OR REPLACE INTO sync_checkpoints (vault_id,cursor) VALUES (?,?)',
          [], null]]);
        await waitForCount('checkpoint-write-sql-observed',
          checkpointSqlCountBefore + 1);
        const targetedCountBefore = countEvents('write-transaction-targeted');
        const abortRequestedCountBefore =
          countEvents('write-transaction-abort-requested');
        const abortEventCountBefore = countEvents('write-transaction-abort-event');
        worker.port.postMessage({ type: 'write', key: [1, 2] });
        await waitForCount('write-transaction-targeted', targetedCountBefore + 1);
        await waitForCount('write-transaction-abort-requested',
          abortRequestedCountBefore + 1);
        await waitForCount('write-transaction-abort-event', abortEventCountBefore + 1);
        checkpointWritePersisted = await readKey([1, 2]);
      } catch (error) {
        failedAt = error?.message?.match(/^missing-([a-z-]+)$/)?.[1] || 'runtime-error';
      } finally {
        worker?.port.close();
        channel.close();
        database?.close();
      }
      return {
        events,
        persisted,
        unrelatedWritePersisted,
        checkpointWritePersisted,
        failedAt,
      };
    }, channelName);
    if (result.failedAt) {
      console.error('IndexedDB SharedWorker fault probe safe diagnostic', JSON.stringify({
        failedAt: result.failedAt,
        events: result.events,
        durableReadbackContainsRow: result.persisted,
      }));
    }
    assert.equal(result.persisted, false, 'aborted transaction left its row in IndexedDB');
    assert.equal(result.unrelatedWritePersisted, true,
      'checkpoint-only fault aborted a non-checkpoint blocks transaction');
    assert.equal(result.checkpointWritePersisted, false,
      'checkpoint-targeted fault left its row in IndexedDB');
    assert.equal(result.events.filter((type) =>
      type === 'write-transaction-targeted').length, 2);
    assert.equal(result.events.filter((type) =>
      type === 'write-transaction-abort-requested').length, 2);
    assert.equal(result.events.filter((type) =>
      type === 'write-transaction-abort-event').length, 2);
    assert.equal(result.events.filter((type) =>
      type === 'checkpoint-write-sql-observed').length, 1);
    for (const expected of [
      'worker-route-loaded',
      'armed',
      'blocks-put-observed',
      'blocks-write-observed',
      'blocks-write-vault-database',
      'write-transaction-targeted',
      'write-transaction-abort-deferred',
      'write-transaction-commit-held',
      'write-transaction-abort-release-received',
      'write-transaction-abort-requested',
      'write-transaction-abort-event',
      'checkpoint-write-sql-observed',
      'write-transaction-skipped-before-checkpoint-sql',
    ]) {
      assert.ok(result.events.includes(expected), `probe event missing: ${expected}`);
    }
    assert.equal(result.events.includes('write-transaction-abort-failed'), false);
    console.log('IndexedDB SharedWorker fault probe passed', JSON.stringify({
      events: result.events,
      transactionAborted: true,
      durableReadbackContainsRow: result.persisted,
      unrelatedWriteCommitted: result.unrelatedWritePersisted,
      checkpointWriteAborted: !result.checkpointWritePersisted,
    }));
  } catch (error) {
    console.error('IndexedDB SharedWorker fault probe failed', error?.message || 'runtime-error');
    process.exitCode = 1;
  } finally {
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
    if (server) await new Promise((resolve) => server.close(resolve));
  }
}

main();
