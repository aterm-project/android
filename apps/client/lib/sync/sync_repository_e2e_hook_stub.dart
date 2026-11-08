Future<void> beforeReplaceMergedOperationForE2eTesting() async {}

Future<void> beforeStorePulledEventForE2eTesting({
  required String recordId,
  required String revisionId,
  required String commitSeq,
  required int observedPendingOperationCount,
}) async {}

Future<void> beforeSaveInboundCheckpointForE2eTesting({
  required String? expectedCursor,
  required String? nextCursor,
  required String serverGeneration,
  required int pageEventCount,
}) async {}

Future<void> beforeHostJumpGraphCommitForE2eTesting({
  required String recordId,
  required String? jumpHostId,
  required int attempt,
}) async {}
