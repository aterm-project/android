/// Small browser Storage API boundary used by the storage status UI.
///
/// Keeping browser calls behind this interface lets Flutter tests exercise
/// denied grants, stale grant responses, missing estimates, and API failures
/// without depending on a particular browser's eviction policy.
abstract interface class BrowserStorageClient {
  bool get canReadPersistence;
  bool get canRequestPersistence;
  bool get canEstimate;

  Future<bool> persisted();
  Future<bool> requestPersistence();
  Future<BrowserStorageEstimate> estimate();
}

class BrowserStorageEstimate {
  const BrowserStorageEstimate({
    required this.usageBytes,
    required this.quotaBytes,
  });

  final int usageBytes;
  final int quotaBytes;
}
