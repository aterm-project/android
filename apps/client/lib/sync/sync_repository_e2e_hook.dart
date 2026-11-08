import 'sync_repository_e2e_hook_stub.dart'
    if (dart.library.js_interop) 'sync_repository_e2e_hook_web.dart'
    as platform;

/// Optional browser acceptance barrier at the last point before a prepared
/// automatic merge is atomically installed in the shared outbox.
///
/// The Web implementation is a no-op unless the bundle was explicitly built
/// with `ATERMIUS_WEB_SYNC_E2E_HOOKS=true`. Native targets always use the stub.
Future<void> beforeReplaceMergedOperationForE2eTesting() =>
    platform.beforeReplaceMergedOperationForE2eTesting();

/// Optional browser acceptance barrier after a pull reads an empty outbox and
/// before the conditional remote-head transaction. Native targets use a no-op.
Future<void> beforeStorePulledEventForE2eTesting({
  required String recordId,
  required String revisionId,
  required String commitSeq,
  required int observedPendingOperationCount,
}) => platform.beforeStorePulledEventForE2eTesting(
  recordId: recordId,
  revisionId: revisionId,
  commitSeq: commitSeq,
  observedPendingOperationCount: observedPendingOperationCount,
);

/// Optional browser acceptance barrier after a changes page has been applied
/// and immediately before its durable checkpoint CAS. Native targets use a
/// no-op; the Web callback is enabled only in an opt-in test bundle.
Future<void> beforeSaveInboundCheckpointForE2eTesting({
  required String? expectedCursor,
  required String? nextCursor,
  required String serverGeneration,
  required int pageEventCount,
}) => platform.beforeSaveInboundCheckpointForE2eTesting(
  expectedCursor: expectedCursor,
  nextCursor: nextCursor,
  serverGeneration: serverGeneration,
  pageEventCount: pageEventCount,
);

/// Optional browser barrier after Host Jump Host graph validation and before
/// the encrypted Host/outbox write. Native targets always use the no-op stub.
Future<void> beforeHostJumpGraphCommitForE2eTesting({
  required String recordId,
  required String? jumpHostId,
  required int attempt,
}) => platform.beforeHostJumpGraphCommitForE2eTesting(
  recordId: recordId,
  jumpHostId: jumpHostId,
  attempt: attempt,
);
