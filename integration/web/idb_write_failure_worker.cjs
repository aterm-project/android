'use strict';

function buildIdbWriteFailureWorkerPrelude(channelName) {
  return `(() => {
    if (typeof SharedWorkerGlobalScope === 'undefined' ||
        !(self instanceof SharedWorkerGlobalScope) ||
        !self.indexedDB) return;
    const channel = new BroadcastChannel(${JSON.stringify(channelName)});
    channel.postMessage({type: 'worker-route-loaded'});
    let deferredAbort;
    let deferredCompletionCallbacks;
    let armed = false;
    let holdCommittedCallback = false;
    let deferAbortForConcurrentRead = false;
    let requireCheckpointWrite = false;
    let checkpointWriteStatementsObserved = 0;
    let faultAbortObserved = false;
    const deferredTransactions = new WeakSet();
    const committedTargetTransactions = new WeakSet();
    const completionHeldTransactions = new WeakSet();
    const abortedTransactions = new WeakSet();
    const monitoredTransactions = new WeakSet();
    const crossTabQueryRequestIds = new WeakMap();
    const crossTabQueryRequestOwners = new Map();
    const connectionOrdinals = new WeakMap();
    const portOrdinals = new WeakMap();
    let nextConnectionOrdinal = 0;
    const associateDatabasePort = (clientPort, event) => {
      const message = event?.data;
      if (message?.type !== 'ServeDriftDatabase') return;
      const databasePort = message.payload?.port;
      const ordinal = connectionOrdinals.get(clientPort);
      if (databasePort && ordinal) {
        portOrdinals.set(databasePort, ordinal);
        notify(ordinal <= 3
          ? 'drift-database-port-associated-' + ordinal
          : 'drift-database-port-associated-other');
      }
    };
    self.addEventListener('connect', (event) => {
      for (const clientPort of event.ports || []) {
        nextConnectionOrdinal += 1;
        connectionOrdinals.set(clientPort, nextConnectionOrdinal);
        notify(nextConnectionOrdinal <= 3
          ? 'drift-connect-client-ordinal-' + nextConnectionOrdinal
          : 'drift-connect-client-ordinal-other');
      }
    });
    const nativeAddEventListener = MessagePort.prototype.addEventListener;
    MessagePort.prototype.addEventListener = function(type, listener, options) {
      if (type !== 'message' || typeof listener !== 'function') {
        return nativeAddEventListener.call(this, type, listener, options);
      }
      const port = this;
      const wrappedListener = function(event) {
        associateDatabasePort(port, event);
        return listener.call(this, event);
      };
      return nativeAddEventListener.call(this, type, wrappedListener, options);
    };
    const notify = (type) => channel.postMessage({type});
    channel.onmessage = (event) => {
      if (event.data?.type === 'continue-committed-completion') {
        notify('write-transaction-completion-release-received');
        const callbacks = deferredCompletionCallbacks || [];
        deferredCompletionCallbacks = undefined;
        // Arm before releasing the Dart/Drift callback so the next write
        // transaction cannot race past the runner's next snapshot check.
        if (event.data.rearm === true) {
          holdCommittedCallback = true;
          armed = true;
          notify('armed');
        }
        for (const invoke of callbacks) {
          try { invoke(); } catch (_) {
            notify('write-transaction-completion-callback-error');
          }
        }
        return;
      }
      if (event.data?.type === 'continue-abort') {
        notify('write-transaction-abort-release-received');
        deferredAbort?.();
        return;
      }
      if (event.data?.type !== 'arm' || armed) return;
      armed = true;
      holdCommittedCallback = event.data.holdCommittedCallback === true;
      deferAbortForConcurrentRead = event.data.deferAbortForConcurrentRead === true;
      requireCheckpointWrite = event.data.requireCheckpointWrite === true;
      checkpointWriteStatementsObserved = 0;
      notify('armed');
    };

    // The checkpoint-failure acceptance classifies the SQL request locally so
    // it can target the following VFS flush. Never retain or publish SQL text,
    // bound values, record identifiers, or credentials.
    const isCheckpointWriteStatement = (sql) => {
      if (typeof sql !== 'string') return false;
      const normalized = sql.toLowerCase()
        .replaceAll('"', '')
        .replaceAll(String.fromCharCode(96), '')
        .replaceAll('[', '')
        .replaceAll(']', '');
      return /^\\s*(?:insert(?:\\s+or\\s+\\w+)?\\s+into|replace\\s+into|update|delete\\s+from)\\s+sync_checkpoints\\b/i.test(normalized);
    };
    const observeCheckpointWriteRequest = (requestType, payload) => {
      if (!armed || !requireCheckpointWrite) return;
      let matches = false;
      if (requestType === 3 && Array.isArray(payload)) {
        // ExecuteQuery payload: [tag, method, sql, args, executorId].
        matches = isCheckpointWriteStatement(payload[2]);
      } else if (requestType === 4 && Array.isArray(payload)) {
        // Batched statements payload: [tag, sql[], ...bound-argument groups].
        matches = Array.isArray(payload[1]) &&
          payload[1].some(isCheckpointWriteStatement);
      }
      if (matches) {
        checkpointWriteStatementsObserved += 1;
        notify('checkpoint-write-sql-observed');
      }
    };

    // For the crash-recovery scenario, hold the library's completion callback
    // only after IndexedDB has dispatched complete (the transaction is
    // durable). This leaves the awaiting Drift operation unresolved while the
    // runner independently inspects the committed files/blocks snapshot.
    const completionListenerWrappers = new WeakMap();
    const wrapCompletionListener = (transaction, listener) => {
      if (typeof listener !== 'function') return listener;
      let wrappers = completionListenerWrappers.get(transaction);
      if (!wrappers) {
        wrappers = new WeakMap();
        completionListenerWrappers.set(transaction, wrappers);
      }
      const existing = wrappers.get(listener);
      if (existing) return existing;
      const wrapped = function(event) {
        if (!holdCommittedCallback ||
            !committedTargetTransactions.has(transaction)) {
          return listener.call(this, event);
        }
        if (!completionHeldTransactions.has(transaction)) {
          completionHeldTransactions.add(transaction);
          deferredCompletionCallbacks = [];
          notify('write-transaction-completion-callback-held');
        }
        deferredCompletionCallbacks.push(() => listener.call(this, event));
      };
      wrappers.set(listener, wrapped);
      return wrapped;
    };
    const transactionProto = IDBTransaction.prototype;
    const nativeTransactionAddEventListener = transactionProto.addEventListener;
    const nativeTransactionRemoveEventListener = transactionProto.removeEventListener;
    const wrappedTransactionListeners = new WeakMap();
    transactionProto.addEventListener = function(type, listener, options) {
      if (type !== 'complete' || !listener) {
        return nativeTransactionAddEventListener.call(this, type, listener, options);
      }
      let listeners = wrappedTransactionListeners.get(this);
      if (!listeners) {
        listeners = new WeakMap();
        wrappedTransactionListeners.set(this, listeners);
      }
      let wrapped = listeners.get(listener);
      if (!wrapped) {
        wrapped = wrapCompletionListener(this, listener);
        listeners.set(listener, wrapped);
      }
      return nativeTransactionAddEventListener.call(this, type, wrapped, options);
    };
    transactionProto.removeEventListener = function(type, listener, options) {
      const wrapped = type === 'complete'
        ? wrappedTransactionListeners.get(this)?.get(listener)
        : undefined;
      return nativeTransactionRemoveEventListener.call(
        this, type, wrapped || listener, options);
    };
    let completionDescriptorOwner = transactionProto;
    let completionDescriptor;
    while (completionDescriptorOwner && !completionDescriptor) {
      completionDescriptor = Object.getOwnPropertyDescriptor(
        completionDescriptorOwner, 'oncomplete');
      if (!completionDescriptor) {
        completionDescriptorOwner = Object.getPrototypeOf(completionDescriptorOwner);
      }
    }
    if (completionDescriptor?.set && completionDescriptorOwner) {
      try {
        Object.defineProperty(completionDescriptorOwner, 'oncomplete', {
          configurable: true,
          enumerable: completionDescriptor.enumerable,
          get: completionDescriptor.get,
          set(listener) {
            completionDescriptor.set.call(
              this, wrapCompletionListener(this, listener));
          },
        });
      } catch (_) {
        notify('write-transaction-completion-probe-unavailable');
      }
    } else {
      notify('write-transaction-completion-probe-unavailable');
    }
    const monitorTransaction = (tx) => {
      if (!tx || monitoredTransactions.has(tx)) return;
      monitoredTransactions.add(tx);
      tx.addEventListener('complete', () => notify('write-transaction-complete'),
        {once: true});
      tx.addEventListener('abort', () => {
        faultAbortObserved = true;
        notify('write-transaction-abort-event');
      }, {once: true});
    };
    const abortAfterBlockMutation = (store, tx) => {
      if (!armed || !tx || store?.name !== 'blocks') return;
      if (requireCheckpointWrite && checkpointWriteStatementsObserved === 0) {
        notify('write-transaction-skipped-before-checkpoint-sql');
        return;
      }
      notify('blocks-write-observed');
      if (tx.db?.name !== 'atermius_vault') {
        notify('blocks-write-other-database');
        return;
      }
      notify('blocks-write-vault-database');
      if (tx.mode !== 'readwrite' || abortedTransactions.has(tx)) return;
      if (holdCommittedCallback) {
        armed = false;
        committedTargetTransactions.add(tx);
        notify('write-transaction-targeted');
        // This observer must run even though the completion callback installed
        // by the VFS is held. Native registration bypasses our wrapper.
        nativeTransactionAddEventListener.call(tx, 'complete', () => {
          notify('write-transaction-durable-complete');
        }, {once: true});
        nativeTransactionAddEventListener.call(tx, 'abort', () => {
          notify('write-transaction-abort-event');
        }, {once: true});
        return;
      }
      monitorTransaction(tx);
      abortedTransactions.add(tx);
      armed = false;
      notify('write-transaction-targeted');
      const requestAbort = () => {
        deferredTransactions.delete(tx);
        try {
          tx.abort();
          notify('write-transaction-abort-requested');
        } catch (_) {
          notify('write-transaction-abort-failed');
        }
      };
      if (!deferAbortForConcurrentRead) {
        requestAbort();
        return;
      }

      // Keep this readwrite transaction active while the runner sends a
      // second-tab sync request. That request must wait behind the shared
      // delegate's durability gate, then fail closed when this transaction
      // aborts. The repeated harmless reads never expose record or block data.
      notify('write-transaction-abort-deferred');
      deferredTransactions.add(tx);
      let keepAlive = true;
      const issueKeepAliveRead = () => {
        if (!keepAlive) return;
        try {
          const request = tx.objectStore('blocks').count();
          request.onsuccess = () => issueKeepAliveRead();
          request.onerror = () => {
            keepAlive = false;
            notify('write-transaction-keepalive-request-failed');
          };
        } catch (_) {
          keepAlive = false;
          notify('write-transaction-keepalive-request-failed');
        }
      };
      issueKeepAliveRead();
      deferredAbort = () => {
        if (!keepAlive) return;
        keepAlive = false;
        requestAbort();
        deferredAbort = undefined;
      };
    };

    // Drift explicitly calls IDBTransaction.commit() when the VFS write batch
    // finishes. Hold that call only for the one targeted vault transaction so
    // the acceptance can issue its cross-tab request during the async flush,
    // then release the transaction by injecting the abort.
    const nativeCommit = IDBTransaction.prototype.commit;
    IDBTransaction.prototype.commit = function(...args) {
      if (deferredTransactions.has(this)) {
        notify('write-transaction-commit-held');
        return;
      }
      return nativeCommit.apply(this, args);
    };

    // Observe only fixed quarantine marker presence in serialized Drift error
    // responses. Never retain or emit the payload, query, values, or message.
    const containsMarker = (value, marker, seen = new WeakSet(), budget = 64) => {
      if (typeof value === 'string') return value.includes(marker);
      if (value == null || typeof value !== 'object' || budget <= 0) return false;
      if (seen.has(value)) return false;
      seen.add(value);
      const children = Array.isArray(value) ? value : Object.values(value);
      return children.slice(0, budget).some((child) =>
        containsMarker(child, marker, seen, budget - 1));
    };
    const nativePortPostMessage = MessagePort.prototype.postMessage;
    MessagePort.prototype.postMessage = function(message, ...args) {
      const trackedIds = crossTabQueryRequestIds.get(this);
      const responseTag = Array.isArray(message) ? message[0] : null;
      const responsePayload = message[1];
      const responseId = Number.isSafeInteger(responsePayload)
        ? responsePayload
        : responseTag === 1
          ? responsePayload?.i
          : responseTag === 2 || responseTag === 4
            ? responsePayload?.[0]
            : responseTag === 3 ? responsePayload : null;
      const isTrackedCrossTabQuery = trackedIds?.has(responseId) === true;
      if (Array.isArray(message) && message[0] === 2) {
        if (containsMarker(message, 'ATERMIUS_INDEXEDDB_PERSISTENCE_FAILURE')) {
          notify('drift-error-response-persistence-marker');
          if (isTrackedCrossTabQuery) {
            notify('cross-tab-query-persistence-failure-response');
          }
        } else if (containsMarker(message, 'ATERMIUS_INDEXEDDB_DATABASE_QUARANTINED')) {
          notify('drift-error-response-quarantine-marker');
          if (isTrackedCrossTabQuery) {
            notify('cross-tab-query-quarantine-response');
          }
        } else {
          notify('drift-error-response-other');
          if (isTrackedCrossTabQuery) {
            notify('cross-tab-query-other-error-response');
          }
        }
      } else if (Array.isArray(message) && message[0] === 4) {
        notify('drift-sqlite-error-response');
        if (isTrackedCrossTabQuery) {
          notify('cross-tab-query-sqlite-error-response');
        }
      } else if (isTrackedCrossTabQuery && responseTag === 1) {
        notify('cross-tab-query-success-response');
      } else if (isTrackedCrossTabQuery && responseTag === 3) {
        notify('cross-tab-query-cancelled-response');
      }
      if (isTrackedCrossTabQuery) {
        trackedIds.delete(responseId);
        const owners = crossTabQueryRequestOwners.get(responseId);
        owners?.delete(this);
        if (owners?.size === 0) crossTabQueryRequestOwners.delete(responseId);
      }
      return nativePortPostMessage.call(this, message, ...args);
    };

    // The current Drift protocol uses MessagePort.onmessage for each remote
    // DB connection. Count request messages without retaining or inspecting
    // their SQL, arguments, or row values so the runner can prove a second
    // port reached the SharedWorker while the IDB flush was held open.
    let messagePortProto = MessagePort.prototype;
    let onmessageDescriptor;
    let onmessageOwner;
    while (messagePortProto && !onmessageDescriptor) {
      onmessageDescriptor = Object.getOwnPropertyDescriptor(messagePortProto, 'onmessage');
      if (onmessageDescriptor) {
        onmessageOwner = messagePortProto;
      } else {
        messagePortProto = Object.getPrototypeOf(messagePortProto);
      }
    }
    if (onmessageDescriptor?.set && onmessageOwner) {
      try {
        Object.defineProperty(onmessageOwner, 'onmessage', {
          configurable: true,
          enumerable: onmessageDescriptor.enumerable,
          get: onmessageDescriptor.get,
          set(listener) {
            if (typeof listener !== 'function') {
              onmessageDescriptor.set.call(this, listener);
              return;
            }
            const wrapped = function(event) {
              const message = event?.data;
              associateDatabasePort(this, event);
              const requestPayload = Array.isArray(message) && message[0] === 0
                ? Array.isArray(message[1])
                  ? message[2]
                  : message[1]?.p
                : null;
              const requestId = Number.isSafeInteger(message?.[1])
                ? message[1] : message?.[1]?.i;
              const requestType = Array.isArray(requestPayload)
                ? requestPayload[0] : null;
              observeCheckpointWriteRequest(requestType, requestPayload);
              if (deferredAbort && requestType === 3) {
                if (!crossTabQueryRequestIds.has(this)) {
                  crossTabQueryRequestIds.set(this, new Set());
                }
                crossTabQueryRequestIds.get(this).add(requestId);
                if (!crossTabQueryRequestOwners.has(requestId)) {
                  crossTabQueryRequestOwners.set(requestId, new Set());
                }
                crossTabQueryRequestOwners.get(requestId).add(this);
                notify('drift-query-request-observed');
                const ordinal = portOrdinals.get(this);
                notify(ordinal && ordinal <= 3
                  ? 'drift-query-request-port-' + ordinal
                  : 'drift-query-request-port-other');
                if (requestPayload[1] === 3) {
                  notify(ordinal === 2
                    ? 'drift-select-request-port-2'
                    : ordinal === 1
                      ? 'drift-select-request-port-1'
                      : 'drift-select-request-port-other');
                }
              }
              if (faultAbortObserved && requestType === 12) {
                const owners = crossTabQueryRequestOwners.get(requestPayload?.[1]);
                if (owners?.size) {
                  notify('cross-tab-query-cancellation-request-observed');
                  if (!owners.has(this)) {
                    notify('cross-tab-query-cancellation-from-other-port');
                  }
                  const currentOrdinal = portOrdinals.get(this);
                  if (currentOrdinal === 1) {
                    notify('cross-tab-query-cancellation-from-primary-port');
                  }
                }
              }
              if (faultAbortObserved && [3, 4, 6].includes(requestType)) {
                notify('drift-database-request-after-abort-observed');
              }
              return listener.call(this, event);
            };
            onmessageDescriptor.set.call(this, wrapped);
          },
        });
        notify('drift-port-observer-installed');
      } catch (_) {
        notify('drift-port-observer-unavailable');
      }
    } else {
      notify('drift-port-observer-unavailable');
    }
    const nativePut = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function(...args) {
      const result = nativePut.apply(this, args);
      if (armed && this.name === 'blocks') notify('blocks-put-observed');
      abortAfterBlockMutation(this, this.transaction);
      return result;
    };
    const nativeUpdate = IDBCursor.prototype.update;
    IDBCursor.prototype.update = function(...args) {
      const result = nativeUpdate.apply(this, args);
      if (armed && this.source?.name === 'blocks') notify('blocks-update-observed');
      abortAfterBlockMutation(this.source, this.source?.transaction);
      return result;
    };
  })();\n`;
}

module.exports = { buildIdbWriteFailureWorkerPrelude };
