import 'dart:typed_data';

import '../../l10n/l10n.dart';

sealed class DesktopEvent {}

class DesktopFrame extends DesktopEvent {
  /// [bgra] covers the region ([x], [y], [regionWidth], [regionHeight]) of a
  /// [width]×[height] desktop. Without a region it is the full desktop.
  DesktopFrame(
    this.width,
    this.height,
    this.bgra, {
    this.onConsumed,
    this.x = 0,
    this.y = 0,
    int? regionWidth,
    int? regionHeight,
  }) : regionWidth = regionWidth ?? width,
       regionHeight = regionHeight ?? height;
  final void Function()? onConsumed;
  final int width, height;
  final int x, y, regionWidth, regionHeight;
  final Uint8List bgra;
  bool get full =>
      x == 0 && y == 0 && regionWidth == width && regionHeight == height;
}

enum DesktopResizeResult {
  applied,
  prohibited,
  outOfResources,
  invalidLayout,
  unsupported,
}

/// Server-side resize capability and, for explicit requests, the outcome.
/// [serverResize] false means only local scaling is possible.
class DesktopResizeStatus extends DesktopEvent {
  DesktopResizeStatus({required this.serverResize, this.result});
  final bool serverResize;
  final DesktopResizeResult? result;
}

/// Files currently offered by the remote clipboard (empty when none).
class DesktopRemoteFiles extends DesktopEvent {
  DesktopRemoteFiles(this.names, this.fileCount, this.totalBytes);
  final List<String> names;
  final int fileCount, totalBytes;
}

class DesktopFileTransfer extends DesktopEvent {
  DesktopFileTransfer({
    required this.done,
    required this.total,
    required this.bytes,
    this.savedPaths,
    this.error,
  });
  final int done, total, bytes;

  /// Top-level paths created by a finished download.
  final List<String>? savedPaths;
  final String? error;
  bool get finished => savedPaths != null || error != null;
}

class DesktopClipboard extends DesktopEvent {
  DesktopClipboard(this.text);
  final String text;
}

class DesktopReady extends DesktopEvent {}

enum DesktopCursorKind { defaultArrow, hidden, image }

/// Shape and hotspot are supplied by RDP/RFB; position follows local input.
class DesktopCursor extends DesktopEvent {
  DesktopCursor(
    this.kind, {
    this.width = 0,
    this.height = 0,
    this.hotX = 0,
    this.hotY = 0,
    this.bgra,
  });
  final DesktopCursorKind kind;
  final int width, height, hotX, hotY;
  final Uint8List? bgra;
}

class DesktopPointerPosition extends DesktopEvent {
  DesktopPointerPosition(this.x, this.y);
  final int x, y;
}

class DesktopNotice extends DesktopEvent {
  DesktopNotice(this.text);
  final String text;
}

/// A TLS certificate was rejected before authentication. Approval must retry
/// with this exact leaf pin; it must never disable certificate verification.
class RdpCertificateException implements Exception {
  RdpCertificateException(this.sha256) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid RDP certificate fingerprint');
    }
  }
  final String sha256;
  @override
  String toString() => currentL10n.theRdpCertificateIsntTrustedYet;
}

abstract interface class DirectDesktopConnection {
  Stream<DesktopEvent> get events;
  void send(List<Object> command);
  void paste(String text);
  Future<void> close();
}
