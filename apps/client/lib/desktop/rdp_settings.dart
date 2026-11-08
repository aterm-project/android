import '../domain/models.dart';
import 'desktop_resolution.dart';
import 'rdp_features.dart';
import '../l10n/l10n.dart';

/// Per-Host RDP connection settings. Stored in the Host manifest so they are
/// encrypted, exported and synchronized with the Host record. Never contains
/// credentials; passwords remain in [HostLogin].
const rdpSettingsManifestKey = 'rdp_settings_v1';

enum RdpAudioMode { local, remote, off }

enum RdpPrinterMode { off, defaultPrinter, all }

enum RdpResolutionMode { fitWindow, fixed }

class RdpDriveRedirect {
  const RdpDriveRedirect({required this.name, required this.path});
  final String name;
  final String path;

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _-]{0,30}$');

  String? validate() {
    if (!_name.hasMatch(name)) {
      return currentL10n.driveNameMustBe131;
    }
    if (!isSafeLocalPath(path)) return currentL10n.driveFolderMustBeAnAbsolute;
    return null;
  }

  Map<String, Object?> toJson() => {'name': name, 'path': path};

  @override
  bool operator ==(Object other) =>
      other is RdpDriveRedirect && other.name == name && other.path == path;
  @override
  int get hashCode => Object.hash(name, path);
}

/// Absolute local path without control characters or the native config
/// separators. Windows (`C:\x`, `\\server\share`) and POSIX forms accepted.
bool isSafeLocalPath(String path) {
  if (path.isEmpty || path.length > 1024 || path != path.trim()) return false;
  if (path.runes.any((r) => r < 32 || r == 0x7f)) return false;
  if (path.contains('|')) return false;
  final windows = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
      RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+').hasMatch(path);
  final posix = path.startsWith('/');
  if (!windows && !posix) return false;
  final parts = path.split(RegExp(r'[\\/]'));
  return !parts.contains('..');
}

class RdpMonitorSelection {
  const RdpMonitorSelection._(this.all, this.indices);
  static const allMonitors = RdpMonitorSelection._(true, []);
  factory RdpMonitorSelection.only(List<int> indices) {
    final unique = indices.toSet().toList()..sort();
    if (unique.isEmpty ||
        unique.length > 16 ||
        unique.any((i) => i < 0 || i > 15)) {
      throw const FormatException('Invalid monitor selection');
    }
    return RdpMonitorSelection._(false, List.unmodifiable(unique));
  }
  final bool all;
  final List<int> indices;
  Object toJson() => all ? 'all' : indices;
  @override
  bool operator ==(Object other) =>
      other is RdpMonitorSelection &&
      other.all == all &&
      other.indices.length == indices.length &&
      Iterable.generate(indices.length).every(
        (i) => other.indices[i] == indices[i],
      );
  @override
  int get hashCode => Object.hash(all, Object.hashAll(indices));
}

class RdpSettings {
  const RdpSettings({
    this.resolution = RdpResolutionMode.fitWindow,
    this.width = 1280,
    this.height = 800,
    this.scalePercent = 100,
    this.multiMonitor = false,
    this.monitors = RdpMonitorSelection.allMonitors,
    this.clipboardText = true,
    this.clipboardFiles = false,
    this.drives = const [],
    this.audio = RdpAudioMode.local,
    this.microphone = false,
    this.printers = RdpPrinterMode.off,
    this.smartCards = false,
    this.cameras = false,
    this.usbDevices = const [],
    this.scaling = DesktopLocalScaling.fit,
  });

  static const defaults = RdpSettings();
  static const maxDrives = 8;
  static const maxUsbDevices = 16;
  static const scales = [100, 125, 150, 175, 200, 250, 300];

  final RdpResolutionMode resolution;
  final int width, height;
  final int scalePercent;
  final bool multiMonitor;
  final RdpMonitorSelection monitors;
  final bool clipboardText;
  final bool clipboardFiles;
  final List<RdpDriveRedirect> drives;
  final RdpAudioMode audio;
  final bool microphone;
  final RdpPrinterMode printers;
  final bool smartCards;
  final bool cameras;

  /// USB devices by `vvvv:pppp` (hex vendor:product). Only devices already
  /// bound to a libusb-compatible driver (WinUSB) can be opened; no driver is
  /// installed or replaced by Atermius.
  final List<String> usbDevices;

  /// Local view mapping; never changes the remote resolution.
  final DesktopLocalScaling scaling;

  static final _usbId = RegExp(r'^[0-9a-f]{4}:[0-9a-f]{4}$');

  String? validate() {
    if (resolution == RdpResolutionMode.fixed) {
      final issue = validateDesktopSize(width, height);
      if (issue != null) return issue;
    }
    if (!scales.contains(scalePercent)) return currentL10n.unsupportedRdpDisplayScale;
    if (drives.length > maxDrives) {
      return currentL10n.atMostMaxdrivesRedirectedFolders(maxDrives);
    }
    final names = <String>{};
    for (final drive in drives) {
      final issue = drive.validate();
      if (issue != null) return issue;
      if (!names.add(drive.name.toLowerCase())) {
        return currentL10n.redirectedFolderNamesMustBeUnique;
      }
    }
    if (usbDevices.length > maxUsbDevices) {
      return currentL10n.atMostMaxusbdevicesUsbDevices(maxUsbDevices);
    }
    if (usbDevices.any((id) => !_usbId.hasMatch(id)) ||
        usbDevices.toSet().length != usbDevices.length) {
      return currentL10n.usbDevicesMustBeUniqueVendor;
    }
    return null;
  }

  RdpSettings copyWith({
    RdpResolutionMode? resolution,
    int? width,
    int? height,
    int? scalePercent,
    bool? multiMonitor,
    RdpMonitorSelection? monitors,
    bool? clipboardText,
    bool? clipboardFiles,
    List<RdpDriveRedirect>? drives,
    RdpAudioMode? audio,
    bool? microphone,
    RdpPrinterMode? printers,
    bool? smartCards,
    bool? cameras,
    List<String>? usbDevices,
    DesktopLocalScaling? scaling,
  }) => RdpSettings(
    resolution: resolution ?? this.resolution,
    width: width ?? this.width,
    height: height ?? this.height,
    scalePercent: scalePercent ?? this.scalePercent,
    multiMonitor: multiMonitor ?? this.multiMonitor,
    monitors: monitors ?? this.monitors,
    clipboardText: clipboardText ?? this.clipboardText,
    clipboardFiles: clipboardFiles ?? this.clipboardFiles,
    drives: drives ?? this.drives,
    audio: audio ?? this.audio,
    microphone: microphone ?? this.microphone,
    printers: printers ?? this.printers,
    smartCards: smartCards ?? this.smartCards,
    cameras: cameras ?? this.cameras,
    usbDevices: usbDevices ?? this.usbDevices,
    scaling: scaling ?? this.scaling,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'resolution': resolution.name,
    if (resolution == RdpResolutionMode.fixed) 'width': width,
    if (resolution == RdpResolutionMode.fixed) 'height': height,
    'scale': scalePercent,
    'multimon': multiMonitor,
    if (multiMonitor) 'monitors': monitors.toJson(),
    'clipboard_text': clipboardText,
    'clipboard_files': clipboardFiles,
    'drives': [for (final d in drives) d.toJson()],
    'audio': audio.name,
    'microphone': microphone,
    'printers': printers.name,
    'smart_cards': smartCards,
    'cameras': cameras,
    'usb_devices': usbDevices,
    'scaling': scaling.name,
  };

  /// Strict decoding: unknown versions or invalid values raise
  /// [FormatException]. Callers decide whether to fall back to defaults.
  factory RdpSettings.fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('Unsupported RDP settings');
    }
    T pick<T>(String key, T fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! T) throw FormatException('Invalid RDP setting $key');
      return value;
    }

    E enumValue<E extends Enum>(List<E> values, String key, E fallback) {
      final name = pick<String?>(key, null);
      if (name == null) return fallback;
      return values.firstWhere(
        (v) => v.name == name,
        orElse: () => throw FormatException('Invalid RDP setting $key'),
      );
    }

    final monitorsRaw = raw['monitors'];
    final RdpMonitorSelection monitors;
    if (monitorsRaw == null || monitorsRaw == 'all') {
      monitors = RdpMonitorSelection.allMonitors;
    } else if (monitorsRaw is List && monitorsRaw.every((v) => v is int)) {
      monitors = RdpMonitorSelection.only(monitorsRaw.cast<int>());
    } else {
      throw const FormatException('Invalid RDP setting monitors');
    }
    final drivesRaw = pick<List>('drives', const []);
    final drives = [
      for (final d in drivesRaw)
        if (d is Map && d['name'] is String && d['path'] is String)
          RdpDriveRedirect(name: d['name'] as String, path: d['path'] as String)
        else
          throw const FormatException('Invalid RDP setting drives'),
    ];
    final usbRaw = pick<List>('usb_devices', const []);
    if (usbRaw.any((v) => v is! String)) {
      throw const FormatException('Invalid RDP setting usb_devices');
    }
    final settings = RdpSettings(
      resolution: enumValue(
        RdpResolutionMode.values,
        'resolution',
        RdpResolutionMode.fitWindow,
      ),
      width: pick<int>('width', 1280),
      height: pick<int>('height', 800),
      scalePercent: pick<int>('scale', 100),
      multiMonitor: pick<bool>('multimon', false),
      monitors: monitors,
      clipboardText: pick<bool>('clipboard_text', true),
      clipboardFiles: pick<bool>('clipboard_files', false),
      drives: List.unmodifiable(drives),
      audio: enumValue(RdpAudioMode.values, 'audio', RdpAudioMode.local),
      microphone: pick<bool>('microphone', false),
      printers: enumValue(RdpPrinterMode.values, 'printers', RdpPrinterMode.off),
      smartCards: pick<bool>('smart_cards', false),
      cameras: pick<bool>('cameras', false),
      usbDevices: List.unmodifiable(usbRaw.cast<String>()),
      scaling: enumValue(
        DesktopLocalScaling.values,
        'scaling',
        DesktopLocalScaling.fit,
      ),
    );
    final issue = settings.validate();
    if (issue != null) throw FormatException(issue);
    return settings;
  }

  /// Read from a Host. A missing entry yields defaults. A corrupt or future
  /// entry also yields defaults, which keep every redirection off except text
  /// clipboard and local audio, so the connection never widens device access.
  static RdpSettings of(HostRecord host) {
    final raw = host.manifest?[rdpSettingsManifestKey];
    if (raw == null) return defaults;
    try {
      return RdpSettings.fromJson(raw);
    } on FormatException {
      return defaults;
    }
  }

  /// Whether the stored entry exists but cannot be decoded by this version.
  static bool unreadable(HostRecord host) {
    final raw = host.manifest?[rdpSettingsManifestKey];
    if (raw == null) return false;
    try {
      RdpSettings.fromJson(raw);
      return false;
    } on FormatException {
      return true;
    }
  }

  /// Returns a manifest with these settings, or with the key removed when the
  /// settings equal the defaults (keeps old records byte-identical).
  Map<String, Object?>? applyTo(Map<String, Object?>? manifest) {
    final next = {...?manifest};
    if (this == defaults) {
      next.remove(rdpSettingsManifestKey);
    } else {
      next[rdpSettingsManifestKey] = toJson();
    }
    return next.isEmpty ? null : next;
  }

  /// Bounded `key=value` lines for `aterm_rdp_create_ex`. Values are validated
  /// first, so no newline/`|` can reach the native parser. Requested resources
  /// the engine cannot provide are omitted and named in
  /// [RdpNativeConfig.unavailable] so the UI can say so instead of pretending.
  RdpNativeConfig toNativeConfig({
    required RdpFeatures features,
    required int initialWidth,
    required int initialHeight,
    List<RdpMonitorLayout> monitorLayout = const [],
    String? defaultPrinterName,
  }) {
    final issue = validate();
    if (issue != null) throw FormatException(issue);
    final unavailable = <String>[];
    bool want(bool requested, int feature, String label) {
      if (!requested) return false;
      if (features.has(feature)) return true;
      unavailable.add(label);
      return false;
    }

    final monitors = want(multiMonitor, RdpFeatures.multimon, 'multiple monitors')
        ? RdpMonitorLayout.normalize(monitorLayout)
        : const <RdpMonitorLayout>[];
    final files = want(clipboardFiles, RdpFeatures.fileClipboard, 'clipboard files');
    final playLocal = audio == RdpAudioMode.local &&
        want(true, RdpFeatures.audioOut, 'audio playback');
    final mic = want(microphone, RdpFeatures.audioIn, 'microphone');
    final cards = want(smartCards, RdpFeatures.smartcard, 'smart cards');
    final camera = want(cameras, RdpFeatures.camera, 'cameras');
    final folders = want(drives.isNotEmpty, RdpFeatures.drive, 'folders')
        ? drives
        : const <RdpDriveRedirect>[];
    final usb = want(usbDevices.isNotEmpty, RdpFeatures.usb, 'USB devices')
        ? usbDevices
        : const <String>[];
    var printerMode = 0;
    String? printerName;
    if (want(printers != RdpPrinterMode.off, RdpFeatures.printer, 'printers')) {
      if (printers == RdpPrinterMode.all) {
        printerMode = 2;
      } else {
        final name = defaultPrinterName;
        if (name != null &&
            name.isNotEmpty &&
            name.length <= 256 &&
            !name.contains('|') &&
            !name.runes.any((r) => r < 32 || r == 0x7f)) {
          printerMode = 1;
          printerName = name;
        } else {
          unavailable.add('default printer');
        }
      }
    }
    final fixed = resolution == RdpResolutionMode.fixed;
    final lines = <String>[
      'version=1',
      'width=${(fixed ? width : initialWidth).clamp(200, 8192)}',
      'height=${(fixed ? height : initialHeight).clamp(200, 8192)}',
      'dynamic_resolution=${!fixed && monitors.isEmpty ? 1 : 0}',
      'scale=$scalePercent',
      'clipboard=${clipboardText || files ? 1 : 0}',
      'clipboard_files=${files ? 1 : 0}',
      'audio=${playLocal ? 0 : audio == RdpAudioMode.remote ? 1 : 2}',
      'microphone=${mic ? 1 : 0}',
      'printers=$printerMode',
      if (printerName != null) 'printer_name=$printerName',
      'smartcards=${cards ? 1 : 0}',
      'cameras=${camera ? 1 : 0}',
      for (final d in folders) 'drive=${d.name}|${d.path}',
      for (final id in usb) 'usb=$id',
      for (final m in monitors)
        'monitor=${m.x}|${m.y}|${m.width}|${m.height}|${m.primary ? 1 : 0}',
    ];
    return RdpNativeConfig('${lines.join('\n')}\n', unavailable, monitors);
  }

  @override
  bool operator ==(Object other) =>
      other is RdpSettings &&
      other.resolution == resolution &&
      (resolution == RdpResolutionMode.fitWindow ||
          (other.width == width && other.height == height)) &&
      other.scalePercent == scalePercent &&
      other.multiMonitor == multiMonitor &&
      (!multiMonitor || other.monitors == monitors) &&
      other.clipboardText == clipboardText &&
      other.clipboardFiles == clipboardFiles &&
      _listEquals(other.drives, drives) &&
      other.audio == audio &&
      other.microphone == microphone &&
      other.printers == printers &&
      other.smartCards == smartCards &&
      other.cameras == cameras &&
      _listEquals(other.usbDevices, usbDevices) &&
      other.scaling == scaling;

  @override
  int get hashCode => Object.hash(
    resolution,
    scalePercent,
    multiMonitor,
    clipboardText,
    clipboardFiles,
    Object.hashAll(drives),
    audio,
    microphone,
    printers,
    smartCards,
    cameras,
    Object.hashAll(usbDevices),
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Local monitor geometry in physical pixels, relative to the virtual desktop.
class RdpMonitorLayout {
  const RdpMonitorLayout({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primary,
  });
  final int x, y, width, height;
  final bool primary;

  /// Normalize to MS-RDPBCGR rules: the primary monitor is at (0,0), at most
  /// 16 monitors, each at least 200 px, combined span at most 32766 px.
  static List<RdpMonitorLayout> normalize(List<RdpMonitorLayout> input) {
    if (input.isEmpty) return const [];
    final monitors = input.take(16).toList();
    final primary = monitors.firstWhere(
      (m) => m.primary,
      orElse: () => monitors.first,
    );
    final shifted = [
      for (final m in monitors)
        RdpMonitorLayout(
          x: m.x - primary.x,
          y: m.y - primary.y,
          width: m.width.clamp(200, 8192),
          height: m.height.clamp(200, 8192),
          primary: identical(m, primary),
        ),
    ];
    final left = shifted.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final top = shifted.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final right = shifted
        .map((m) => m.x + m.width)
        .reduce((a, b) => a > b ? a : b);
    final bottom = shifted
        .map((m) => m.y + m.height)
        .reduce((a, b) => a > b ? a : b);
    if (right - left > 32766 || bottom - top > 32766) {
      throw FormatException(currentL10n.monitorLayoutExceedsRdpLimits);
    }
    return List.unmodifiable(shifted);
  }
}

class RdpNativeConfig {
  const RdpNativeConfig(this.text, this.unavailable, this.monitors);
  final String text;

  /// Human-readable resources that were requested but not provided.
  final List<String> unavailable;

  /// Normalized monitor layout sent to the server (empty: single display).
  final List<RdpMonitorLayout> monitors;
}
