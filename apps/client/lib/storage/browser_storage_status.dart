import 'browser_storage_client.dart';
import 'browser_storage_client_stub.dart'
    if (dart.library.js_interop) 'browser_storage_client_web.dart'
    as platform;

class BrowserStorageStatus {
  const BrowserStorageStatus({
    required this.supported,
    required this.persisted,
    required this.usageBytes,
    required this.quotaBytes,
    required this.canRequestPersistence,
  });

  const BrowserStorageStatus.unsupported()
    : supported = false,
      persisted = null,
      usageBytes = null,
      quotaBytes = null,
      canRequestPersistence = false;

  final bool supported;
  final bool? persisted;
  final int? usageBytes;
  final int? quotaBytes;
  final bool canRequestPersistence;

  bool get hasEstimate => usageBytes != null && quotaBytes != null;
}

/// Reads current origin storage state and requests browser persistence.
///
/// A successful [requestPersistence] result is not treated as the resulting
/// state. Callers must read [read] again because browser decisions can vary
/// and the request result may not reflect the current bucket state.
class BrowserStorageStatusService {
  BrowserStorageStatusService({BrowserStorageClient? client})
    : _client = client ?? platform.createBrowserStorageClient();

  final BrowserStorageClient _client;

  bool get supported =>
      _client.canReadPersistence ||
      _client.canEstimate ||
      _client.canRequestPersistence;

  Future<BrowserStorageStatus> read() async {
    if (!supported) return const BrowserStorageStatus.unsupported();

    bool? persisted;
    if (_client.canReadPersistence) {
      try {
        persisted = await _client.persisted();
      } on Object {
        // Unknown stays distinct from false: a failed read is not a denial.
      }
    }

    int? usageBytes;
    int? quotaBytes;
    if (_client.canEstimate) {
      try {
        final estimate = await _client.estimate();
        if (estimate.usageBytes >= 0 && estimate.quotaBytes >= 0) {
          usageBytes = estimate.usageBytes;
          quotaBytes = estimate.quotaBytes;
        }
      } on Object {
        // Quota estimates are advisory and may be unavailable independently.
      }
    }

    return BrowserStorageStatus(
      supported: true,
      persisted: persisted,
      usageBytes: usageBytes,
      quotaBytes: quotaBytes,
      canRequestPersistence: _client.canRequestPersistence,
    );
  }

  Future<bool?> requestPersistence() async {
    if (!_client.canRequestPersistence) return null;
    try {
      return await _client.requestPersistence();
    } on Object {
      return null;
    }
  }
}
