// ignore_for_file: depend_on_referenced_packages
import 'package:aterm_client/auth/session_startup.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> values;
  late ClientSecureStore store;
  setUp(() {
    values = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      values,
    );
    store = ClientSecureStore(const FlutterSecureStorage());
  });
  const hint = SessionResumeHint(
    username: ' Alice ',
    accountId: 'account-a',
    deviceId: 'device-a',
  );
  test(
    'resume identity is scoped to server tenant and stores no bearer or key',
    () async {
      await store.saveSessionResumeHint('https://example.test/a', hint);
      expect(
        (await store.sessionResumeHint(
          'https://EXAMPLE.test:443/a/',
        ))?.username,
        'alice',
      );
      expect(await store.sessionResumeHint('https://example.test/b'), isNull);
      expect(await store.sessionResumeHint('https://other.test/a'), isNull);
      expect(values.values.single, isNot(contains('password')));
      expect(values.values.single, isNot(contains('token')));
      expect(values.values.single, isNot(contains('key')));
    },
  );
  test(
    'logout only clears a matching account and device resume hint',
    () async {
      await store.saveSessionResumeHint('https://example.test/a', hint);
      await store.clearSessionResumeHint(
        'https://example.test/a',
        accountId: 'another-account',
        deviceId: 'device-a',
      );
      expect(
        await store.sessionResumeHint('https://example.test/a'),
        isNotNull,
      );
      await store.clearSessionResumeHint(
        'https://example.test/a',
        accountId: 'account-a',
        deviceId: 'device-a',
      );
      expect(await store.sessionResumeHint('https://example.test/a'), isNull);
    },
  );
  test('malformed, incomplete and oversized resume identities are ignored', () {
    for (final value in [
      null,
      '',
      '{',
      '{}',
      '{"username":"a","account_id":"a"}',
      'x' * 4097,
    ]) {
      expect(SessionResumeHint.decode(value), isNull);
    }
  });
}
