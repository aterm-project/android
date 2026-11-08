import 'mobile_push_registration.dart';

MobilePushRegistration createMobilePushRegistration() =>
    const _UnsupportedMobilePushRegistration();

class _UnsupportedMobilePushRegistration implements MobilePushRegistration {
  const _UnsupportedMobilePushRegistration();

  @override
  bool get supported => false;

  @override
  bool get configured => false;

  @override
  Future<MobilePushToken?> requestPermissionAndGetToken() async => null;

  @override
  Future<MobilePushToken?> getTokenIfAuthorized() async => null;

  @override
  Future<MobilePushAuthorizationStatus>
  notificationAuthorizationStatus() async =>
      MobilePushAuthorizationStatus.unknown;

  @override
  Future<String?> getFcmFallbackToken() async => null;

  @override
  Future<Stream<MobilePushToken>> tokenRefreshes() async =>
      const Stream.empty();

  @override
  Future<Stream<Map<String, dynamic>>> incomingMessages() async =>
      const Stream.empty();
}
