import 'dart:async';

import 'package:flutter/foundation.dart';

/// Finds a newer self-hosted Web bundle and waits for a user initiated reload.
///
/// The monitor never applies an update itself. The caller owns readiness checks
/// such as active SSH sessions and unsynchronized Vault operations.
class WebAppUpdateMonitor extends ChangeNotifier {
  WebAppUpdateMonitor({
    required this.currentBuildId,
    required Future<String> Function() probeBuildId,
    required Future<void> Function() reload,
    this.checkInterval = const Duration(minutes: 5),
  }) : _probeBuildId = probeBuildId,
       _reload = reload;

  final String currentBuildId;
  final Future<String> Function() _probeBuildId;
  final Future<void> Function() _reload;
  final Duration checkInterval;

  Timer? _timer;
  bool _disposed = false;
  bool _checking = false;
  bool _lastCheckSucceeded = false;
  String? _availableBuildId;

  bool get checking => _checking;
  bool get lastCheckSucceeded => _lastCheckSucceeded;
  bool get hasUpdate => _availableBuildId != null;
  String? get availableBuildId => _availableBuildId;

  /// Begins a best-effort probe and checks periodically while the page is open.
  Future<void> start() async {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(checkInterval, (_) => unawaited(checkNow()));
    await checkNow();
  }

  Future<void> checkNow() async {
    if (_disposed || _checking) return;
    _setChecking(true);
    try {
      final candidate = (await _probeBuildId()).trim();
      _lastCheckSucceeded = true;
      _availableBuildId = candidate.isNotEmpty && candidate != currentBuildId
          ? candidate
          : null;
    } catch (_) {
      // Keep the update UI free of network, origin, and server error details.
      _lastCheckSucceeded = false;
      _availableBuildId = null;
    } finally {
      _setChecking(false);
    }
  }

  /// Reloads only after the UI has confirmed a currently available update.
  Future<void> applyUpdate() async {
    if (_disposed || !hasUpdate) return;
    await _reload();
  }

  void _setChecking(bool value) {
    if (_disposed || _checking == value) return;
    _checking = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
