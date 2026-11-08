import 'mobile_push_registration_stub.dart'
    if (dart.library.io) 'mobile_push_registration_native.dart'
    as platform;

/// Platform boundary for the optional current-device FCM registration.
///
/// Implementations must never log or persist the provider token. The caller
/// keeps it only long enough to send it to the authenticated server endpoint.
abstract interface class MobilePushRegistration {
  bool get supported;

  /// False until the app is built with Firebase options for the matching
  /// Android or iOS app. This is intentionally a build-time opt-in.
  bool get configured;

  /// Called only from an explicit user action. This is the only method allowed
  /// to display the operating system notification permission prompt.
  Future<MobilePushToken?> requestPermissionAndGetToken();

  /// Retrieves a token only when notification authorization is already
  /// granted. Used to resume a previously opted-in current device without
  /// prompting again.
  Future<MobilePushToken?> getTokenIfAuthorized();

  /// Reads the current OS authorization without displaying a permission prompt.
  /// Unknown means the platform could not safely determine the state.
  Future<MobilePushAuthorizationStatus> notificationAuthorizationStatus();

  /// Gets FCM specifically, without prompting. Used only if an iOS server has
  /// explicitly disabled APNs endpoint delivery.
  Future<String?> getFcmFallbackToken();

  /// Token refresh notifications. Obtain this stream only after opt-in.
  Future<Stream<MobilePushToken>> tokenRefreshes();

  /// Foreground data messages only. Subscribe only for the opted-in current
  /// account/device, and discard the payload immediately after validation.
  Future<Stream<Map<String, dynamic>>> incomingMessages();
}

enum MobilePushAuthorizationStatus { authorized, denied, unknown }

class MobilePushToken {
  const MobilePushToken({required this.provider, required this.value});

  static const fcmProvider = 'fcm_v1';
  static const apnsProvider = 'apns';

  final String provider;
  final String value;
}

MobilePushRegistration createPlatformMobilePushRegistration() =>
    platform.createMobilePushRegistration();
