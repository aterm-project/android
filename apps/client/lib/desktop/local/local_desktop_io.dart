import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../rdp_settings.dart';

// Local Windows facilities used by RDP redirection. Read-only except for the
// user-initiated clipboard write of downloaded file paths. No system settings
// are changed.

bool get supportsFileClipboardInterop => Platform.isWindows;

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
  if (!Platform.isWindows) return const [];
  _found.clear();
  final callback = Pointer.fromFunction<MONITORENUMPROC>(_monitor, 0);
  EnumDisplayMonitors(NULL, nullptr, callback, 0);
  final result = List<RdpMonitorLayout>.unmodifiable(_found);
  _found.clear();
  return result;
}

String? localDefaultPrinterName() {
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

/// Paths currently copied in Explorer (CF_HDROP), or empty.
List<String> readClipboardFilePaths() {
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

/// Place downloaded files on the Windows clipboard so Explorer can paste them.
bool writeClipboardFilePaths(List<String> paths) {
  if (!Platform.isWindows || paths.isEmpty) return false;
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
