// Atermius local change: DOM-free, bounded browser drop collection.
//
// `desktop_drop_web.dart` adapts DOM DataTransfer objects to these small
// interfaces; keeping the logic here lets it be unit tested on the Dart VM.
import 'web_drop_item.dart';

/// One `DataTransferItem`.
abstract interface class WebDropSourceItem {
  /// `DataTransferItem.kind` ('file' for files and folders).
  String get kind;

  /// `webkitGetAsEntry()`; only valid synchronously during the drop event.
  WebDropSourceEntry? getAsEntry();
}

/// One `FileSystemEntry`.
abstract interface class WebDropSourceEntry {
  bool get isDirectory;
  String get name;
  String get fullPath;

  /// Resolves the `File` of a file entry.
  Future<WebDropSourceFile> file();

  /// Reads every child of a folder entry (only used when expanding folders).
  Future<List<WebDropSourceEntry>> readAllChildren();
}

/// The metadata of a browser `File`.
abstract interface class WebDropSourceFile {
  String get name;
  int get size;
  String get type;
  int get lastModified;
}

enum WebDropRejection { tooManyItems, failed }

sealed class WebDropCollection {
  const WebDropCollection();
}

final class WebDropAccepted extends WebDropCollection {
  const WebDropAccepted(this.items, this.skipped);

  final List<WebDropItem> items;

  /// Non-file items and items without a readable entry, which were skipped.
  final int skipped;
}

final class WebDropRejected extends WebDropCollection {
  const WebDropRejected(this.reason, this.itemCount);

  final WebDropRejection reason;
  final int itemCount;
}

/// Collects a browser drop.
///
/// With [maxItems] set, a drop holding more top-level items is rejected
/// before any entry is read or any URL is created. With [expandDirectories]
/// `false`, folders are returned as childless `directory` items without an
/// object URL and without touching their reader. Non-file items and null
/// entries are skipped and counted instead of throwing. If anything fails,
/// every object URL created so far is revoked and the drop is rejected.
Future<WebDropCollection> collectWebDrop(
  List<WebDropSourceItem> items, {
  required int? maxItems,
  required bool expandDirectories,
  required String Function(WebDropSourceFile file) createFileUrl,
  required String Function() createDirectoryUrl,
  required void Function(String url) revokeUrl,
}) async {
  if (maxItems != null && items.length > maxItems) {
    return WebDropRejected(WebDropRejection.tooManyItems, items.length);
  }
  // Entries must be read synchronously, before the first await.
  final entries = <WebDropSourceEntry>[];
  var skipped = 0;
  for (final item in items) {
    WebDropSourceEntry? entry;
    try {
      entry = item.kind == 'file' ? item.getAsEntry() : null;
    } catch (_) {
      entry = null;
    }
    if (entry == null) {
      skipped++;
    } else {
      entries.add(entry);
    }
  }
  final created = <String>[];
  String track(String url) {
    created.add(url);
    return url;
  }

  Future<WebDropItem> convert(WebDropSourceEntry entry) async {
    if (entry.isDirectory) {
      if (!expandDirectories) {
        return WebDropItem(
          uri: '',
          name: entry.name,
          size: 0,
          lastModified: DateTime.now(),
          relativePath: entry.fullPath,
          type: 'directory',
          children: const [],
        );
      }
      final children = <WebDropItem>[];
      for (final child in await entry.readAllChildren()) {
        final item = await convert(child);
        if (item.name == '.DS_Store' && item.type == '') continue;
        children.add(item);
      }
      return WebDropItem(
        uri: track(createDirectoryUrl()),
        name: entry.name,
        size: 0,
        lastModified: DateTime.now(),
        relativePath: entry.fullPath,
        type: 'directory',
        children: children,
      );
    }
    final file = await entry.file();
    return WebDropItem(
      uri: track(createFileUrl(file)),
      name: file.name,
      size: file.size,
      lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      relativePath: entry.fullPath,
      type: file.type,
      children: const [],
    );
  }

  try {
    final result = <WebDropItem>[];
    for (final entry in entries) {
      result.add(await convert(entry));
    }
    return WebDropAccepted(result, skipped);
  } catch (_) {
    for (final url in created) {
      try {
        revokeUrl(url);
      } catch (_) {}
    }
    return WebDropRejected(WebDropRejection.failed, items.length);
  }
}
