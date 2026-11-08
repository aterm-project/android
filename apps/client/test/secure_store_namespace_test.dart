import 'package:aterm_client/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'secure storage scopes credentials by canonical scheme, host, port and path',
    () {
      final tenantA = secureStorageNamespace(
        'HTTPS://Example.Test:443/tenant-a/',
      );
      expect(tenantA, secureStorageNamespace('https://example.test/tenant-a'));
      expect(tenantA, isNot(secureStorageNamespace('https://example.test')));
      expect(
        tenantA,
        isNot(secureStorageNamespace('https://example.test/tenant-b')),
      );
      expect(
        tenantA,
        isNot(secureStorageNamespace('https://example.test:8443/tenant-a')),
      );
      expect(
        tenantA,
        isNot(secureStorageNamespace('http://example.test/tenant-a')),
      );
      expect(
        secureStorageNamespace('https://example.test/Tenant-A'),
        isNot(tenantA),
      );
    },
  );
}
