import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../ssh/file_workspace_controller.dart'
    show LocalUploadSource, fileManagerMaxDroppedFiles;
import 'file_drop_probe.dart';

/// OS/browser file drops are delivered by the maintained `desktop_drop`
/// plugin on Windows, Linux, macOS and the web. Android's plugin hands over
/// `content://` URIs after releasing their read permission, so Android keeps
/// the explicit "Upload file" picker instead of a drop target.
bool get fileDropSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// App-startup hook (idempotent): call once from `main()` right after
/// `WidgetsFlutterBinding.ensureInitialized()`, before any root is run.
///
/// desktop_drop's web implementation installs global `window` drop handlers
/// when plugins are registered, before any file tab exists. This applies the
/// bounded browser policy (no folder traversal, batch limit before any entry
/// or object URL) and installs the single central listener that releases
/// every drop no [FileDropRegion] claims. No region needs to exist.
void initializeFileDrop() {
  DesktopDropWebLimits.maxItems = fileManagerMaxDroppedFiles;
  DesktopDropWebLimits.expandDirectories = false;
  _DropLease.ensureListening();
}

/// Test seam replacing the local path probe (real IO) in widget tests.
@visibleForTesting
Future<bool> Function(String path)? debugDroppedFileProbe;

/// Test seam observing dropped-item release (browser object URL revocation).
@visibleForTesting
void Function(String path)? debugDroppedFileRelease;

/// Shared ownership of one drop's resources (browser object URLs).
///
/// desktop_drop broadcasts every drop to every registered target and hands
/// them the same `files` list, so the lease is keyed on that list. Exactly one
/// accepted (topmost) region may [tryClaim] it, synchronously while the
/// broadcast runs; that region releases it once its whole async `onDrop`
/// future has completed. A drop nobody claimed (hidden tabs only, outside
/// every region, disabled regions) is released once by a microtask that runs
/// after the synchronous broadcast. Non-consumers never release anything.
class _DropLease {
  _DropLease._(this._items) {
    scheduleMicrotask(() {
      if (!_claimed) release();
    });
  }

  static final _leases = Expando<_DropLease>();
  static bool _listening = false;

  /// Sees every drop exactly once, even when no region accepts it.
  static void ensureListening() {
    if (_listening) return;
    _listening = true;
    DesktopDrop.instance.init();
    DesktopDrop.instance.addRawDropEventListener((event) {
      if (event is DropDoneEvent) of(event.files);
    });
  }

  static _DropLease of(List<DropItem> items) =>
      _leases[items] ??= _DropLease._(items);

  final List<DropItem> _items;
  bool _claimed = false;
  bool _released = false;

  bool tryClaim() {
    if (_claimed || _released) return false;
    _claimed = true;
    return true;
  }

  void release() {
    if (_released) return;
    _released = true;
    final releaseItem = debugDroppedFileRelease ?? releaseDroppedFile;
    for (final item in _items) {
      try {
        releaseItem(item.path);
      } catch (_) {}
    }
  }
}

class FileDropResult {
  const FileDropResult(
    this.files,
    this.rejected, {
    this.tooMany = false,
    this.failed = false,
  });

  /// Regular files, streamed lazily on upload.
  final List<LocalUploadSource> files;

  /// Folders, non-file URIs and unreadable items that were not accepted.
  final int rejected;

  /// The drop held more than [FileDropRegion.maxFiles] items; the whole batch
  /// was rejected before any item was inspected.
  final bool tooMany;

  /// Inspecting the dropped items failed unexpectedly; nothing was accepted.
  final bool failed;
}

/// Accepts native file drops only when this region is the topmost visible
/// hit target at the drop point, so hidden tabs, inactive split panes and
/// content under dialogs never receive a drop meant for something else.
class FileDropRegion extends StatefulWidget {
  const FileDropRegion({
    required this.child,
    required this.onDrop,
    required this.maxFiles,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final bool enabled;

  /// Larger batches are rejected whole before any item is stat'ed or read.
  final int maxFiles;

  /// Called exactly once per accepted drop with its result. The callback
  /// current when the drop arrived is used even if the widget is rebuilt with
  /// another callback while local files are inspected, so the callback can
  /// close over (and re-validate) its own destination. The dropped items
  /// (browser object URLs) stay valid until the returned future completes and
  /// are then released exactly once.
  final Future<void> Function(FileDropResult result) onDrop;

  @override
  State<FileDropRegion> createState() => _FileDropRegionState();
}

class _FileDropRegionState extends State<FileDropRegion> {
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _configureWebLimits();
    // Normally already done by initializeFileDrop() at startup; idempotent.
    _DropLease.ensureListening();
  }

  @override
  void didUpdateWidget(FileDropRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureWebLimits();
  }

  /// Browser drops: reject oversized batches before any entry is read or
  /// object URL is created, and never traverse dropped folders (they are
  /// rejected anyway). Native drops are unaffected.
  void _configureWebLimits() {
    DesktopDropWebLimits.maxItems = widget.maxFiles;
    DesktopDropWebLimits.expandDirectories = false;
  }

  Future<void> _rejected(DropRejectedDetails details) async {
    final onDrop = widget.onDrop;
    try {
      final accepted = widget.enabled && _isTopmost(details.globalPosition);
      if (mounted && _hovering) setState(() => _hovering = false);
      if (!accepted) return;
      await onDrop(
        FileDropResult(
          const [],
          details.itemCount,
          tooMany: details.reason == DropRejectedReason.tooManyItems,
          failed: details.reason != DropRejectedReason.tooManyItems,
        ),
      );
    } catch (_) {}
  }

  bool _isTopmost(Offset global) {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    return result.path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          identical((entry.target as RenderMetaData).metaData, this),
    );
  }

  void _hover(Offset global) {
    final hovering = widget.enabled && _isTopmost(global);
    if (hovering != _hovering && mounted) {
      setState(() => _hovering = hovering);
    }
  }

  /// Runs synchronously inside desktop_drop's broadcast to every target.
  void _onDragDone(DropDoneDetails details) {
    final lease = _DropLease.of(details.files);
    final accepted = widget.enabled && _isTopmost(details.globalPosition);
    if (mounted && _hovering) setState(() => _hovering = false);
    // Hidden tabs, other split panes and covered regions neither consume nor
    // release the drop; only the single claiming region owns its lifetime.
    if (!accepted || !lease.tryClaim()) return;
    // Capture before any await: the region may be rebuilt for another tab,
    // controller or folder while local files are inspected.
    final onDrop = widget.onDrop;
    final maxFiles = widget.maxFiles;
    unawaited(_consume(details, onDrop, maxFiles).whenComplete(lease.release));
  }

  /// Inspects and delivers a claimed drop. Its future completes only after
  /// [onDrop]'s future (inspection, upload) completed, so the items stay valid
  /// until then. Never throws.
  Future<void> _consume(
    DropDoneDetails details,
    Future<void> Function(FileDropResult result) onDrop,
    int maxFiles,
  ) async {
    final items = details.files;
    try {
      if (items.length > maxFiles) {
        await onDrop(FileDropResult(const [], items.length, tooMany: true));
        return;
      }
      final files = <LocalUploadSource>[];
      // Browser items that weren't files (or had no entry) count as rejected.
      var rejected = details.skippedItems;
      for (final item in items) {
        if (item is DropItemDirectory ||
            !await (debugDroppedFileProbe ?? isDroppedRegularFile)(item.path)) {
          rejected++;
          continue;
        }
        final int length;
        try {
          length = await item.length();
        } catch (_) {
          rejected++;
          continue;
        }
        files.add(
          LocalUploadSource(
            name: item.name,
            length: length,
            open: () => _chunked(item, length),
          ),
        );
      }
      await onDrop(FileDropResult(files, rejected));
    } catch (_) {
      // Never leave an unhandled error from this unawaited drop handler;
      // report a safe failure to the initiating callback instead.
      try {
        await onDrop(const FileDropResult([], 0, failed: true));
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return DropTarget(
      enable: widget.enabled && fileDropSupported,
      onDragEntered: (details) => _hover(details.globalPosition),
      onDragUpdated: (details) => _hover(details.globalPosition),
      onDragExited: (_) {
        if (_hovering && mounted) setState(() => _hovering = false);
      },
      onDragDone: _onDragDone,
      onDragRejected: (details) => unawaited(_rejected(details)),
      child: MetaData(
        metaData: this,
        behavior: HitTestBehavior.translucent,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_hovering)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('file_drop_highlight'),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: .06),
                      border: Border.all(color: primary, width: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Streams a dropped file without reading it whole. Browser files are sliced
/// in 1 MiB windows because cross_file's web `openRead` materializes the
/// requested range.
Stream<Uint8List> _chunked(DropItem file, int length) async* {
  if (!kIsWeb) {
    yield* file.openRead();
    return;
  }
  const window = 1024 * 1024;
  for (var offset = 0; offset < length; offset += window) {
    yield* file.openRead(offset, math.min(length, offset + window));
  }
}
