import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../rdp_settings.dart';

// Local Windows and macOS facilities used by RDP redirection. Read-only except
// for the user-initiated clipboard write of downloaded file paths. No system
// settings are changed.

bool get supportsFileClipboardInterop => Platform.isWindows || Platform.isMacOS;

typedef _MacStringGetterNative = Pointer<Utf8> Function();
typedef _MacStringGetter = Pointer<Utf8> Function();
typedef _MacFreeStringNative = Void Function(Pointer<Utf8>);
typedef _MacFreeString = void Function(Pointer<Utf8>);
typedef _MacWriteClipboardNative = Int32 Function(Pointer<Utf8>);
typedef _MacWriteClipboard = int Function(Pointer<Utf8>);

String? _callMacRunnerString(String symbol) {
  try {
    final lib = DynamicLibrary.executable();
    if (!lib.providesSymbol(symbol) ||
        !lib.providesSymbol('aterm_macos_free_string')) {
      return null;
    }
    final getter = lib.lookupFunction<_MacStringGetterNative, _MacStringGetter>(
      symbol,
    );
    final releaser = lib.lookupFunction<_MacFreeStringNative, _MacFreeString>(
      'aterm_macos_free_string',
    );
    final ptr = getter();
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      releaser(ptr);
    }
  } catch (_) {
    return null;
  }
}

final List<RdpMonitorLayout> _found = [];

int _monitor(int hMonitor, int hdc, Pointer rect, int data) {
  final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
  try {
    if (GetMonitorInfo(hMonitor, info) != 0) {
      final r = info.ref.rcMonitor;
      _found.add(
        RdpMonitorLayout(
          x: r.left,
          y: r.top,
          width: r.right - r.left,
          height: r.bottom - r.top,
          primary: info.ref.dwFlags & MONITORINFOF_PRIMARY != 0,
        ),
      );
    }
  } finally {
    calloc.free(info);
  }
  return _found.length < 16 ? 1 : 0;
}

/// Monitor rectangles in virtual-screen pixels (the runner is per-monitor DPI
/// aware, so these are physical pixels).
List<RdpMonitorLayout> localMonitorLayout() {
  if (Platform.isMacOS) {
    final raw = _callMacRunnerString('aterm_macos_monitor_layout');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded.take(16))
          if (item is Map &&
              item['x'] is int &&
              item['y'] is int &&
              item['width'] is int &&
              item['height'] is int)
            RdpMonitorLayout(
              x: item['x'] as int,
              y: item['y'] as int,
              width: item['width'] as int,
              height: item['height'] as int,
              primary: item['primary'] == true,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }
  if (!Platform.isWindows) return const [];
  _found.clear();
  final callback = Pointer.fromFunction<MONITORENUMPROC>(_monitor, 0);
  EnumDisplayMonitors(NULL, nullptr, callback, 0);
  final result = List<RdpMonitorLayout>.unmodifiable(_found);
  _found.clear();
  return result;
}

String? localDefaultPrinterName() {
  if (Platform.isMacOS) {
    final name = _callMacRunnerString('aterm_macos_default_printer');
    return (name == null || name.isEmpty || name.length > 1024) ? null : name;
  }
  if (!Platform.isWindows) return null;
  final size = calloc<Uint32>()..value = 0;
  try {
    GetDefaultPrinter(nullptr, size);
    if (size.value == 0 || size.value > 1024) return null;
    final buffer = wsalloc(size.value);
    try {
      if (GetDefaultPrinter(buffer, size) == 0) return null;
      return buffer.toDartString();
    } finally {
      free(buffer);
    }
  } finally {
    calloc.free(size);
  }
}

/// Paths currently copied in Explorer (CF_HDROP) or Finder (NSPasteboard), or empty.
List<String> readClipboardFilePaths() {
  if (Platform.isMacOS) {
    final raw = _callMacRunnerString('aterm_macos_read_clipboard_files');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded.take(4096))
          if (item is String && item.isNotEmpty && item.length <= 32767) item,
      ];
    } catch (_) {
      return const [];
    }
  }
  if (!Platform.isWindows) return const [];
  if (OpenClipboard(NULL) == 0) return const [];
  try {
    final drop = GetClipboardData(CF_HDROP);
    if (drop == 0) return const [];
    final count = DragQueryFile(drop, 0xffffffff, nullptr, 0);
    final paths = <String>[];
    for (var i = 0; i < count && i < 4096; i++) {
      final length = DragQueryFile(drop, i, nullptr, 0);
      if (length <= 0 || length > 32767) continue;
      final buffer = wsalloc(length + 1);
      try {
        if (DragQueryFile(drop, i, buffer, length + 1) > 0) {
          paths.add(buffer.toDartString());
        }
      } finally {
        free(buffer);
      }
    }
    return paths;
  } finally {
    CloseClipboard();
  }
}

/// Place downloaded files on the local OS clipboard so Explorer/Finder can paste them.
bool writeClipboardFilePaths(List<String> paths) {
  if (paths.isEmpty) return false;
  if (Platform.isMacOS) {
    try {
      final lib = DynamicLibrary.executable();
      if (!lib.providesSymbol('aterm_macos_write_clipboard_files')) {
        return false;
      }
      final writer = lib
          .lookupFunction<_MacWriteClipboardNative, _MacWriteClipboard>(
            'aterm_macos_write_clipboard_files',
          );
      final encoded = jsonEncode(paths).toNativeUtf8();
      try {
        return writer(encoded) == 1;
      } finally {
        calloc.free(encoded);
      }
    } catch (_) {
      return false;
    }
  }
  if (!Platform.isWindows) return false;
  final units = <int>[
    for (final p in paths) ...[...p.codeUnits, 0],
    0,
  ];
  final header = sizeOf<DROPFILES>();
  final bytes = header + units.length * 2;
  final memory = GlobalAlloc(GHND, bytes);
  if (memory == nullptr) return false;
  final locked = GlobalLock(memory);
  if (locked == nullptr) {
    GlobalFree(memory);
    return false;
  }
  final drop = locked.cast<DROPFILES>();
  drop.ref
    ..pFiles = header
    ..fWide = 1;
  final list = Pointer<Uint16>.fromAddress(locked.address + header);
  for (var i = 0; i < units.length; i++) {
    list[i] = units[i];
  }
  GlobalUnlock(memory);
  if (OpenClipboard(NULL) == 0) {
    GlobalFree(memory);
    return false;
  }
  try {
    EmptyClipboard();
    if (SetClipboardData(CF_HDROP, memory.address) == 0) {
      GlobalFree(memory);
      return false;
    }
    return true; // ownership moved to the clipboard
  } finally {
    CloseClipboard();
  }
}
