// ignore_for_file: depend_on_referenced_packages

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/device_redaction_capability_publisher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseUrl = 'https://sync.example.test/tenant';
  const instanceId = '11111111-1111-4111-8111-111111111111';
  const serverSpaceId = '22222222-2222-4222-8222-222222222222';
  const accountId = '33333333-3333-4333-8333-333333333333';
  const deviceId = '44444444-4444-4444-8444-444444444444';

  late ClientSecureStore secureStore;
  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    secureStore = ClientSecureStore(const FlutterSecureStorage());
  });

  DeviceRedactionCapabilityPublisher publisher({
    required RedactionCapabilityReportSender send,
    required List<int> builtRevisions,
  }) => DeviceRedactionCapabilityPublisher(
    secureStore: secureStore,
    baseUrl: baseUrl,
    instanceId: instanceId,
    serverSpaceId: serverSpaceId,
    accountId: accountId,
    deviceId: deviceId,
    buildReport: ({required revision, required syncRedactionVersion}) {
      builtRevisions.add(revision);
      return {
        'format': 'atermius-sync-redaction-capability-v1',
        'account_id': accountId,
        'device_id': deviceId,
        'revision': revision,
        'sync_redaction_version': syncRedactionVersion,
        'signature': 'signed-$revision',
      };
    },
    sendReport: send,
  );

  test(
    'explicit revision conflict advances and persists before retry',
    () async {
      final built = <int>[];
      final sent = <int>[];
      final client = publisher(
        builtRevisions: built,
        send: (report) async {
          final revision = report['revision']! as int;
          sent.add(revision);
          if (revision == 1) {
            throw const ApiException(
              statusCode: 409,
              code: 'DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT',
              message: 'conflict',
            );
          }
          return const {'accepted': true};
        },
      );

      await client.publish();
      expect(built, [1, 2]);
      expect(sent, [1, 2]);
      final state = await secureStore.redactionCapabilityReportState(
        baseUrl: baseUrl,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        accountId: accountId,
        deviceId: deviceId,
      );
      expect(state.highestRevision, 2);
      expect(state.pendingRevision, isNull);
    },
  );

  test(
    'ambiguous failure retains exact revision for process-restart retry',
    () async {
      final builtFirst = <int>[];
      final failed = publisher(
        builtRevisions: builtFirst,
        send: (_) async => throw StateError('ambiguous transport failure'),
      );
      await expectLater(failed.publish(), throwsStateError);
      final pending = await secureStore.redactionCapabilityReportState(
        baseUrl: baseUrl,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        accountId: accountId,
        deviceId: deviceId,
      );
      expect(pending.highestRevision, 1);
      expect(pending.pendingRevision, 1);
      expect(pending.pendingSyncRedactionVersion, 1);

      final builtAfterRestart = <int>[];
      final retry = publisher(
        builtRevisions: builtAfterRestart,
        send: (report) async {
          expect(report['revision'], 1);
          return const {'accepted': true};
        },
      );
      await retry.publish();
      expect(builtFirst, [1]);
      expect(builtAfterRestart, [1]);
      final completed = await secureStore.redactionCapabilityReportState(
        baseUrl: baseUrl,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        accountId: accountId,
        deviceId: deviceId,
      );
      expect(completed.highestRevision, 1);
      expect(completed.pendingRevision, isNull);
    },
  );
}
