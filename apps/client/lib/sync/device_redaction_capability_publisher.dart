import '../api/api_client.dart';
import '../storage/secure_store.dart';

typedef RedactionCapabilityReportBuilder =
    Map<String, Object?> Function({
      required int revision,
      required int syncRedactionVersion,
    });
typedef RedactionCapabilityReportSender =
    Future<Map<String, dynamic>> Function(Map<String, Object?> report);

/// Publishes the device's signed v1 redaction capability with a durable,
/// monotonic report revision. Ambiguous failures reuse the same pending report;
/// only an explicit server revision conflict advances the persisted revision.
class DeviceRedactionCapabilityPublisher {
  DeviceRedactionCapabilityPublisher({
    required ClientSecureStore secureStore,
    required this.baseUrl,
    required this.instanceId,
    required this.serverSpaceId,
    required this.accountId,
    required this.deviceId,
    required RedactionCapabilityReportBuilder buildReport,
    required RedactionCapabilityReportSender sendReport,
    this.maxRevisionConflictRetries = 4,
  }) : _secureStore = secureStore,
       _buildReport = buildReport,
       _sendReport = sendReport {
    if (maxRevisionConflictRetries < 0) {
      throw ArgumentError.value(
        maxRevisionConflictRetries,
        'maxRevisionConflictRetries',
      );
    }
  }

  static const int syncRedactionVersion = 1;

  final ClientSecureStore _secureStore;
  final String baseUrl;
  final String instanceId;
  final String serverSpaceId;
  final String accountId;
  final String deviceId;
  final RedactionCapabilityReportBuilder _buildReport;
  final RedactionCapabilityReportSender _sendReport;
  final int maxRevisionConflictRetries;
  Future<void>? _inFlight;

  Future<void> publish() {
    final active = _inFlight;
    if (active != null) return active;
    late final Future<void> guarded;
    guarded = _publish().whenComplete(() {
      if (identical(_inFlight, guarded)) _inFlight = null;
    });
    _inFlight = guarded;
    return guarded;
  }

  Future<void> _publish() async {
    for (var attempt = 0; ; attempt++) {
      final state = await _secureStore.reserveRedactionCapabilityReport(
        baseUrl: baseUrl,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        accountId: accountId,
        deviceId: deviceId,
        syncRedactionVersion: syncRedactionVersion,
      );
      final revision = state.pendingRevision;
      final version = state.pendingSyncRedactionVersion;
      if (revision == null || version == null) {
        throw StateError(
          'A redaction capability report revision was not reserved.',
        );
      }
      if (version != syncRedactionVersion) {
        throw StateError(
          'A pending redaction capability report uses an unsupported version.',
        );
      }
      final report = _buildReport(
        revision: revision,
        syncRedactionVersion: version,
      );
      try {
        await _sendReport(report);
        await _secureStore.completeRedactionCapabilityReport(
          baseUrl: baseUrl,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          accountId: accountId,
          deviceId: deviceId,
          acceptedRevision: revision,
        );
        return;
      } on ApiException catch (error) {
        if (error.code != 'DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT') {
          rethrow;
        }
        await _secureStore.advanceRedactionCapabilityReportAfterConflict(
          baseUrl: baseUrl,
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
          accountId: accountId,
          deviceId: deviceId,
          rejectedRevision: revision,
          syncRedactionVersion: version,
        );
        if (attempt >= maxRevisionConflictRetries) rethrow;
      }
    }
  }
}
