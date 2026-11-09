import 'dart:async';

import 'package:web/web.dart' as web;
import 'dart:js_interop';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/drop_limits.dart';
import 'src/web_drop_collector.dart';

/// A web implementation of the DesktopDrop plugin.
///
/// Atermius local change: drops are collected by the DOM-free
/// [collectWebDrop] under [DesktopDropWebLimits]. With the default limits the
/// result matches upstream 0.8.4 (folders expanded, no item limit), except that
/// non-file items and null entries are skipped instead of throwing.
class DesktopDropWeb {
  final MethodChannel channel;

  DesktopDropWeb._private(this.channel);

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'desktop_drop',
      const StandardMethodCodec(),
      registrar,
    );

    final pluginInstance = DesktopDropWeb._private(channel);
    channel.setMethodCallHandler(pluginInstance.handleMethodCall);
    pluginInstance._registerEvents();
  }

  void _registerEvents() {
    web.window.ondrop = ((web.DragEvent event) {
      event.preventDefault();
      final transfer = event.dataTransfer;
      if (transfer == null) {
        channel.invokeMethod('performOperation_web_rejected', {
          'reason': 'failed',
          'count': 0,
        });
        return;
      }
      final list = transfer.items;
      // Only the item count is read before the limit check: no entry, File
      // or object URL is touched for an oversized drop.
      final count = list.length;
      final maxItems = DesktopDropWebLimits.maxItems;
      if (maxItems != null && count > maxItems) {
        channel.invokeMethod('performOperation_web_rejected', {
          'reason': 'tooManyItems',
          'count': count,
        });
        return;
      }
      final items = List<WebDropSourceItem>.generate(
        count,
        (index) => _DomItem(list[index]),
      );
      collectWebDrop(
        items,
        maxItems: maxItems,
        expandDirectories: DesktopDropWebLimits.expandDirectories,
        createFileUrl: (file) =>
            web.URL.createObjectURL((file as _DomFile).file),
        createDirectoryUrl: () =>
            web.URL.createObjectURL(web.Blob().slice(0, 0, 'directory')),
        // A closure: tear-offs of external interop members don't compile.
        revokeUrl: (url) => web.URL.revokeObjectURL(url),
      ).then((result) {
        switch (result) {
          case WebDropAccepted(:final items, :final skipped):
            channel.invokeMethod('performOperation_web_bounded', {
              'items': items.map((e) => e.toJson()).toList(),
              'skipped': skipped,
            });
          case WebDropRejected(:final reason, :final itemCount):
            channel.invokeMethod('performOperation_web_rejected', {
              'reason': reason.name,
              'count': itemCount,
            });
        }
      }).catchError((Object e, StackTrace s) {
        debugPrint('desktop_drop_web: $e $s');
      });
    }.toJS);

    web.window.ondragenter = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('entered', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);

    web.window.ondragover = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('updated', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);

    web.window.ondragleave = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('exited', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    throw PlatformException(
      code: 'Unimplemented',
      details: 'desktop_drop for web doesn\'t implement \'${call.method}\'',
    );
  }
}

class _DomItem implements WebDropSourceItem {
  _DomItem(this.item);

  final web.DataTransferItem item;

  @override
  String get kind => item.kind;

  @override
  WebDropSourceEntry? getAsEntry() {
    final entry = item.webkitGetAsEntry();
    return entry == null ? null : _DomEntry(entry);
  }
}

class _DomEntry implements WebDropSourceEntry {
  _DomEntry(this.entry);

  final web.FileSystemEntry entry;

  @override
  bool get isDirectory => entry.isDirectory;

  @override
  String get name => entry.name;

  @override
  String get fullPath => entry.fullPath;

  @override
  Future<WebDropSourceFile> file() {
    final completer = Completer<WebDropSourceFile>();
    (entry as web.FileSystemFileEntry).file(
      ((web.File file) => completer.complete(_DomFile(file))).toJS,
      ((web.DOMException error) => completer.completeError(error)).toJS,
    );
    return completer.future;
  }

  // The FileSystemDirectoryReader.readEntries() Web API returns at most 100
  // entries per call by spec, so read until an empty batch.
  @override
  Future<List<WebDropSourceEntry>> readAllChildren() async {
    final reader = (entry as web.FileSystemDirectoryEntry).createReader();
    final all = <WebDropSourceEntry>[];
    while (true) {
      final completer = Completer<List<web.FileSystemEntry>>();
      reader.readEntries(
        ((JSArray<web.FileSystemEntry> batch) =>
            completer.complete(batch.toDart)).toJS,
        ((web.DOMException error) => completer.completeError(error)).toJS,
      );
      final batch = await completer.future;
      if (batch.isEmpty) break;
      all.addAll(batch.map(_DomEntry.new));
    }
    return all;
  }
}

class _DomFile implements WebDropSourceFile {
  _DomFile(this.file);

  final web.File file;

  @override
  String get name => file.name;

  @override
  int get size => file.size;

  @override
  String get type => file.type;

  @override
  int get lastModified => file.lastModified;
}

extension DataTransferItemListExt on web.DataTransferItemList {
  external web.DataTransferItem operator [](int index);
}
