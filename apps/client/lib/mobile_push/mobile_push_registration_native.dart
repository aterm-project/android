import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import 'mobile_push_registration.dart';

const _apiKey = String.fromEnvironment('ATERMIUS_FCM_API_KEY');
const _projectId = String.fromEnvironment('ATERMIUS_FCM_PROJECT_ID');
const _senderId = String.fromEnvironment('ATERMIUS_FCM_SENDER_ID');
const _androidAppId = String.fromEnvironment('ATERMIUS_FCM_ANDROID_APP_ID');
const _iosAppId = String.fromEnvironment('ATERMIUS_FCM_IOS_APP_ID');
const _iosBundleId = String.fromEnvironment('ATERMIUS_FCM_IOS_BUNDLE_ID');

class NativeMobilePushRegistration implements MobilePushRegistration {
  const NativeMobilePushRegistration();

  bool get _isMobile =>
      Platform.isAndroid ||
      Platform.isIOS ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get supported => _isMobile;

  @override
  bool get configured =>
      supported &&
      _apiKey.isNotEmpty &&
      _projectId.isNotEmpty &&
      _senderId.isNotEmpty &&
      (Platform.isAndroid
          ? _androidAppId.isNotEmpty
          : Platform.isIOS && _iosAppId.isNotEmpty && _iosBundleId.isNotEmpty);

  FirebaseOptions get _options {
    if (!configured) {
      throw StateError('FCM is not configured for this mobile build.');
    }
    return FirebaseOptions(
      apiKey: _apiKey,
      appId: Platform.isAndroid ? _androidAppId : _iosAppId,
      messagingSenderId: _senderId,
      projectId: _projectId,
      iosBundleId: Platform.isIOS ? _iosBundleId : null,
    );
  }

  Future<FirebaseMessaging> _messaging() async {
    final options = _options;
    FirebaseApp app;
    try {
      app = Firebase.app();
      if (app.options.projectId != options.projectId ||
          app.options.appId != options.appId) {
        throw StateError(
          'The initialized Firebase app does not match this build.',
        );
      }
    } on FirebaseException catch (error) {
      if (error.code != 'no-app') rethrow;
      app = await Firebase.initializeApp(options: options);
    }
    return FirebaseMessaging.instance;
  }

  @override
  Future<MobilePushToken?> requestPermissionAndGetToken() async {
    if (!supported || !configured) return null;
    final messaging = await _messaging();
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    if (!_authorized(settings.authorizationStatus)) return null;
    return _preferredToken(messaging);
  }

  @override
  Future<MobilePushToken?> getTokenIfAuthorized() async {
    if (!supported || !configured) return null;
    final messaging = await _messaging();
    final settings = await messaging.getNotificationSettings();
    if (!_authorized(settings.authorizationStatus)) return null;
    return _preferredToken(messaging);
  }

  @override
  Future<MobilePushAuthorizationStatus>
  notificationAuthorizationStatus() async {
    if (!supported || !configured) {
      return MobilePushAuthorizationStatus.unknown;
    }
    final messaging = await _messaging();
    final settings = await messaging.getNotificationSettings();
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized || AuthorizationStatus.provisional =>
        MobilePushAuthorizationStatus.authorized,
      AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently =>
        MobilePushAuthorizationStatus.denied,
      AuthorizationStatus.notDetermined =>
        MobilePushAuthorizationStatus.unknown,
    };
  }

  @override
  Future<String?> getFcmFallbackToken() async {
    if (!supported || !configured) return null;
    return (await _messaging()).getToken();
  }

  @override
  Future<Stream<MobilePushToken>> tokenRefreshes() async {
    if (!supported || !configured) return const Stream.empty();
    final messaging = await _messaging();
    return _tokenRefreshes(messaging);
  }

  @override
  Future<Stream<Map<String, dynamic>>> incomingMessages() async {
    if (!supported || !configured) return const Stream.empty();
    await _messaging();
    return FirebaseMessaging.onMessage.map(
      (message) => Map<String, dynamic>.unmodifiable(message.data),
    );
  }

  Stream<MobilePushToken> _tokenRefreshes(FirebaseMessaging messaging) async* {
    await for (final refreshedFcmToken in messaging.onTokenRefresh) {
      final token = await _preferredToken(
        messaging,
        refreshedFcmToken: refreshedFcmToken,
      );
      if (token != null) yield token;
    }
  }

  Future<MobilePushToken?> _preferredToken(
    FirebaseMessaging messaging, {
    String? refreshedFcmToken,
  }) async {
    if (Platform.isIOS) {
      final apnsToken = await messaging.getAPNSToken();
      if (apnsToken != null && apnsToken.isNotEmpty) {
        return MobilePushToken(
          provider: MobilePushToken.apnsProvider,
          value: apnsToken,
        );
      }
    }
    final fcmToken = refreshedFcmToken ?? await messaging.getToken();
    if (fcmToken == null || fcmToken.isEmpty) return null;
    return MobilePushToken(
      provider: MobilePushToken.fcmProvider,
      value: fcmToken,
    );
  }

  bool _authorized(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;
}

MobilePushRegistration createMobilePushRegistration() =>
    const NativeMobilePushRegistration();
