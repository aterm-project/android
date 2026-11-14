// Clipboard handling for Credential visibility v1 secrets: the one-time
// escrow recovery code and the credentials an admin reveals in the viewer.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies a secret to the system clipboard and removes it again after
/// [clearAfter] and when the owner (a dialog) calls [clear] or [dispose].
///
/// Where the clipboard can be read back without asking the user (Android,
/// Windows, Linux), it is cleared only while it still holds exactly the
/// copied value, so something copied afterwards is never wiped. If it cannot
/// be read (Android denies reads while the app is in the background), the
/// value is kept and the clear is retried later. Where a read would prompt
/// the user (iOS, macOS, web), it is cleared without reading.
///
/// The platform clipboard history or a clipboard manager may still keep a
/// copy; that is outside the app's control.
class SensitiveClipboard {
  SensitiveClipboard({
    this.clearAfter = const Duration(minutes: 1),
    @visibleForTesting Future<void> Function(String text)? write,
    @visibleForTesting Future<String?> Function()? read,
    @visibleForTesting bool? readBack,
  }) : _write = write ?? _systemWrite,
       _read = read ?? _systemRead,
       _readBack = readBack ?? _platformAllowsReadBack;

  final Duration clearAfter;
  final Future<void> Function(String text) _write;
  final Future<String?> Function() _read;
  final bool _readBack;
  String? _copied;
  Timer? _timer;
  bool _disposed = false;

  static Future<void> _systemWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static Future<String?> _systemRead() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static bool get _platformAllowsReadBack =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => false,
        _ => true,
      };

  /// True while a copied value may still be on the clipboard.
  bool get holdsValue => _copied != null;

  Future<void> copy(String text) async {
    if (_disposed) return;
    _timer?.cancel();
    await _write(text);
    _copied = text;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = _disposed ? null : Timer(clearAfter, () => unawaited(clear()));
  }

  /// Removes the copied value if it is still on the clipboard. Never throws.
  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    final copied = _copied;
    if (copied == null) return;
    _copied = null;
    try {
      if (_readBack) {
        final current = await _read();
        if (current == null) {
          // Unreadable (or empty): try again later unless replaced meanwhile.
          if (_copied == null && !_disposed) {
            _copied = copied;
            _arm();
          }
          return;
        }
        if (current != copied) return;
      }
      await _write('');
    } on Object {
      // Best effort: a failing clipboard must not break the dialog.
    }
  }

  /// Clears once more and stops the timer. The owner calls this on close.
  void dispose() {
    final pending = clear();
    _disposed = true;
    unawaited(pending);
  }
}
