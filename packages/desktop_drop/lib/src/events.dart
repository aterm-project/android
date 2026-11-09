import 'package:desktop_drop/src/drop_item.dart';
import 'package:flutter/painting.dart';

abstract class DropEvent {
  Offset location;

  DropEvent(this.location);

  @override
  String toString() {
    return '$runtimeType($location)';
  }
}

class DropEnterEvent extends DropEvent {
  DropEnterEvent({required Offset location}) : super(location);
}

class DropExitEvent extends DropEvent {
  DropExitEvent({required Offset location}) : super(location);
}

class DropUpdateEvent extends DropEvent {
  DropUpdateEvent({required Offset location}) : super(location);
}

class DropDoneEvent extends DropEvent {
  final List<DropItem> files;

  /// The raw text payload from the drag operation.
  ///
  /// Format: one URI per line for `text/uri-list` drops, or a single
  /// transfer key when the drop was negotiated as
  /// `application/vnd.portal.filetransfer`. GTK delivers one or the
  /// other, never both mixed.
  ///
  /// URI payload example:
  /// ```
  /// file:///home/user/Documents/file.txt
  /// file:///home/user/Pictures/photo.png
  /// ```
  ///
  /// Portal payload example (Flatpak source app):
  /// ```
  /// f2c1ee0e-0547-4ea6-9c15-a9cf7dbfef98
  /// ```
  ///
  /// The portal key is a token WITHOUT a URI scheme. It can be passed to
  /// `org.freedesktop.portal.FileTransfer.RetrieveFiles` to obtain
  /// sandbox-accessible paths. Lines with a scheme like `file://`,
  /// `smb://`, or `http://` are URIs, not keys — distinguish by parsing
  /// each line and checking `Uri.hasScheme`.
  ///
  /// Is `null` on platforms where raw text isn't exposed (Windows,
  /// macOS, or when the platform channel doesn't provide it).
  final String? rawText;

  /// Atermius local change: browser items that were skipped because they
  /// weren't files or had no readable entry. Always 0 on native platforms.
  final int skippedItems;

  DropDoneEvent({
    required Offset location,
    required this.files,
    this.rawText,
    this.skippedItems = 0,
  }) : super(location);

  @override
  String toString() {
    return '$runtimeType($location, $files, rawText: ${rawText != null ? 'present' : 'null'})';
  }
}

/// Atermius local change: why a browser drop was rejected as a whole.
enum DropRejectedReason {
  /// More top-level items than `DesktopDropWebLimits.maxItems`; nothing was
  /// read and no object URL was created.
  tooManyItems,

  /// Reading the dropped items failed; any object URL already created was
  /// revoked.
  failed,
}

/// Atermius local change: a drop that was rejected before files were
/// delivered (currently only emitted by the bounded web implementation).
class DropRejectedEvent extends DropEvent {
  DropRejectedEvent({
    required Offset location,
    required this.reason,
    required this.itemCount,
  }) : super(location);

  final DropRejectedReason reason;
  final int itemCount;

  @override
  String toString() => '$runtimeType($location, $reason, $itemCount)';
}
