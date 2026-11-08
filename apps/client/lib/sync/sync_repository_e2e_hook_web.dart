import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const _enabled = bool.fromEnvironment('ATERMIUS_WEB_SYNC_E2E_HOOKS');

Future<void> beforeReplaceMergedOperationForE2eTesting() async {
  if (!_enabled) return;

  final global = web.window as JSObject;
  const hooksName = '__atermiusSyncE2eHooks';
  if (!global.hasProperty(hooksName.toJS).toDart) return;
  final hooks = global.getProperty<JSAny?>(hooksName.toJS);
  if (hooks == null || hooks.isUndefinedOrNull) return;
  final hooksObject = hooks as JSObject;
  const callbackName = 'beforeReplaceMergedOperation';
  if (!hooksObject.hasProperty(callbackName.toJS).toDart) return;
  final callback = hooksObject.getProperty<JSAny?>(callbackName.toJS);
  if (callback == null ||
      callback.isUndefinedOrNull ||
      !callback.typeofEquals('function')) {
    return;
  }

  final result = (callback as JSFunction).callAsFunction(hooks);
  if (result != null && !result.isUndefinedOrNull) {
    await (result as JSPromise<JSAny?>).toDart;
  }
}

Future<void> beforeStorePulledEventForE2eTesting({
  required String recordId,
  required String revisionId,
  required String commitSeq,
  required int observedPendingOperationCount,
}) async {
  if (!_enabled) return;

  final global = web.window as JSObject;
  const hooksName = '__atermiusSyncE2eHooks';
  if (!global.hasProperty(hooksName.toJS).toDart) return;
  final hooks = global.getProperty<JSAny?>(hooksName.toJS);
  if (hooks == null || hooks.isUndefinedOrNull) return;
  final hooksObject = hooks as JSObject;
  const callbackName = 'beforeStorePulledEvent';
  if (!hooksObject.hasProperty(callbackName.toJS).toDart) return;
  final callback = hooksObject.getProperty<JSAny?>(callbackName.toJS);
  if (callback == null ||
      callback.isUndefinedOrNull ||
      !callback.typeofEquals('function')) {
    return;
  }

  final payload = JSObject()
    ..setProperty('recordId'.toJS, recordId.toJS)
    ..setProperty('revisionId'.toJS, revisionId.toJS)
    ..setProperty('commitSeq'.toJS, commitSeq.toJS)
    ..setProperty(
      'observedPendingOperationCount'.toJS,
      observedPendingOperationCount.toJS,
    );
  final result = (callback as JSFunction).callAsFunction(hooks, payload);
  if (result != null && !result.isUndefinedOrNull) {
    await (result as JSPromise<JSAny?>).toDart;
  }
}

Future<void> beforeSaveInboundCheckpointForE2eTesting({
  required String? expectedCursor,
  required String? nextCursor,
  required String serverGeneration,
  required int pageEventCount,
}) async {
  if (!_enabled) return;

  final global = web.window as JSObject;
  const hooksName = '__atermiusSyncE2eHooks';
  if (!global.hasProperty(hooksName.toJS).toDart) return;
  final hooks = global.getProperty<JSAny?>(hooksName.toJS);
  if (hooks == null || hooks.isUndefinedOrNull) return;
  final hooksObject = hooks as JSObject;
  const callbackName = 'beforeSaveInboundCheckpoint';
  if (!hooksObject.hasProperty(callbackName.toJS).toDart) return;
  final callback = hooksObject.getProperty<JSAny?>(callbackName.toJS);
  if (callback == null ||
      callback.isUndefinedOrNull ||
      !callback.typeofEquals('function')) {
    return;
  }

  final payload = JSObject()
    ..setProperty('expectedCursor'.toJS, expectedCursor?.toJS)
    ..setProperty('nextCursor'.toJS, nextCursor?.toJS)
    ..setProperty('serverGeneration'.toJS, serverGeneration.toJS)
    ..setProperty('pageEventCount'.toJS, pageEventCount.toJS);
  final result = (callback as JSFunction).callAsFunction(hooks, payload);
  if (result != null && !result.isUndefinedOrNull) {
    await (result as JSPromise<JSAny?>).toDart;
  }
}

Future<void> beforeHostJumpGraphCommitForE2eTesting({
  required String recordId,
  required String? jumpHostId,
  required int attempt,
}) async {
  if (!_enabled) return;

  final global = web.window as JSObject;
  const hooksName = '__atermiusSyncE2eHooks';
  if (!global.hasProperty(hooksName.toJS).toDart) return;
  final hooks = global.getProperty<JSAny?>(hooksName.toJS);
  if (hooks == null || hooks.isUndefinedOrNull) return;
  final hooksObject = hooks as JSObject;
  const callbackName = 'beforeHostJumpGraphCommit';
  if (!hooksObject.hasProperty(callbackName.toJS).toDart) return;
  final callback = hooksObject.getProperty<JSAny?>(callbackName.toJS);
  if (callback == null ||
      callback.isUndefinedOrNull ||
      !callback.typeofEquals('function')) {
    return;
  }

  final payload = JSObject()
    ..setProperty('recordId'.toJS, recordId.toJS)
    ..setProperty('jumpHostId'.toJS, jumpHostId?.toJS)
    ..setProperty('attempt'.toJS, attempt.toJS);
  final result = (callback as JSFunction).callAsFunction(hooks, payload);
  if (result != null && !result.isUndefinedOrNull) {
    await (result as JSPromise<JSAny?>).toDart;
  }
}
