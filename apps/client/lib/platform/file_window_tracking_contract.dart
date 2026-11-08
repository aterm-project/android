import '../domain/window_placement.dart';
import 'files_window_launch.dart';
import '../l10n/l10n.dart';

/// All IDs/capabilities here are runtime-only and never belong in a recipe.
class FileTrackingLaunch {
  FileTrackingLaunch({
    required this.port,
    required this.id,
    required this.capability,
  }) {
    if (port < 1 ||
        port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(capability))
      throw const FormatException('Invalid file geometry launch.');
  }
  final int port;
  final String id, capability;
  List<String> toArguments() => [
    '--file-geometry-port=$port',
    '--file-geometry-id=$id',
  ];
}

class FileWindowSnapshot {
  const FileWindowSnapshot({
    required this.windowId,
    required this.launch,
    required this.placement,
  });
  final String windowId;
  final FilesWindowLaunch launch;
  final SavedWindowPlacement? placement;
}

class TrackedFileWindowHandle {
  const TrackedFileWindowHandle({
    required this.id,
    required this.ready,
    required this.initialPlacementApplied,
    required this.closed,
    required this.stopTracking,
  });
  final String id;
  final Future<bool> ready, initialPlacementApplied;
  final Future<void> closed;

  /// Metadata revocation only; never terminates the independently owned app.
  final Future<void> Function() stopTracking;
}

class FileWindowCaptureUnavailable implements Exception {
  const FileWindowCaptureUnavailable();
  static String get message => currentL10n.someFileWindowsArentUnlockedAre;
  @override
  String toString() => message;
}
