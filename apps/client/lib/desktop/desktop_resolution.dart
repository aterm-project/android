import '../domain/models.dart';
import '../l10n/l10n.dart';

/// Shared desktop resolution vocabulary for RDP and VNC Hosts.
class DesktopResolutionPreset {
  const DesktopResolutionPreset(this.width, this.height, this.label);
  final int width, height;
  final String label;
  String get size => '$width × $height';
}

const desktopResolutionPresets = [
  DesktopResolutionPreset(1280, 720, 'HD'),
  DesktopResolutionPreset(1366, 768, 'WXGA'),
  DesktopResolutionPreset(1600, 900, 'HD+'),
  DesktopResolutionPreset(1920, 1080, 'Full HD'),
  DesktopResolutionPreset(1920, 1200, 'WUXGA'),
  DesktopResolutionPreset(2560, 1440, 'QHD'),
  DesktopResolutionPreset(3840, 2160, '4K UHD'),
];

/// Bounds shared with the native engine and the framebuffer decoder:
/// at most 8192 px per side and 32 Mi pixels (128 MiB BGRA).
const minDesktopSide = 200;
const maxDesktopSide = 8192;
const maxDesktopPixels = 8192 * 4096;

String? validateDesktopSize(int width, int height, {AppLocalizations? l10n}) {
  final messages = l10n ?? currentL10n;
  if (width < minDesktopSide ||
      height < minDesktopSide ||
      width > maxDesktopSide ||
      height > maxDesktopSide) {
    return messages.desktopResolutionSideBounds(minDesktopSide, maxDesktopSide);
  }
  if (width * height > maxDesktopPixels) {
    return messages.desktopResolutionPixelLimit(
      maxDesktopPixels ~/ (1024 * 1024),
    );
  }
  return null;
}

/// How the local view maps the remote framebuffer. This never changes the
/// remote resolution.
enum DesktopLocalScaling { fit, actualSize }

/// VNC display preference. `server` keeps the server-chosen framebuffer.
/// `fitWindow` and `fixed` request a size with RFB SetDesktopSize, which only
/// works when the server negotiates the ExtendedDesktopSize extension.
enum VncResolutionMode { server, fitWindow, fixed }

const vncSettingsManifestKey = 'vnc_settings_v1';

class VncSettings {
  const VncSettings({
    this.resolution = VncResolutionMode.server,
    this.width = 1920,
    this.height = 1080,
    this.scaling = DesktopLocalScaling.fit,
  });
  static const defaults = VncSettings();
  final VncResolutionMode resolution;
  final int width, height;
  final DesktopLocalScaling scaling;

  String? validate() => resolution == VncResolutionMode.fixed
      ? validateDesktopSize(width, height)
      : null;

  VncSettings copyWith({
    VncResolutionMode? resolution,
    int? width,
    int? height,
    DesktopLocalScaling? scaling,
  }) => VncSettings(
    resolution: resolution ?? this.resolution,
    width: width ?? this.width,
    height: height ?? this.height,
    scaling: scaling ?? this.scaling,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'resolution': resolution.name,
    if (resolution == VncResolutionMode.fixed) 'width': width,
    if (resolution == VncResolutionMode.fixed) 'height': height,
    'scaling': scaling.name,
  };

  factory VncSettings.fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('Unsupported VNC settings');
    }
    E pick<E extends Enum>(List<E> values, String key, E fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      return values.firstWhere(
        (v) => v.name == value,
        orElse: () => throw FormatException('Invalid VNC setting $key'),
      );
    }

    int number(String key, int fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! int) throw FormatException('Invalid VNC setting $key');
      return value;
    }

    final settings = VncSettings(
      resolution: pick(
        VncResolutionMode.values,
        'resolution',
        VncResolutionMode.server,
      ),
      width: number('width', 1920),
      height: number('height', 1080),
      scaling: pick(
        DesktopLocalScaling.values,
        'scaling',
        DesktopLocalScaling.fit,
      ),
    );
    final issue = settings.validate();
    if (issue != null) throw FormatException(issue);
    return settings;
  }

  static VncSettings of(HostRecord host) {
    final raw = host.manifest?[vncSettingsManifestKey];
    if (raw == null) return defaults;
    try {
      return VncSettings.fromJson(raw);
    } on FormatException {
      return defaults;
    }
  }

  Map<String, Object?>? applyTo(Map<String, Object?>? manifest) {
    final next = {...?manifest};
    if (this == defaults) {
      next.remove(vncSettingsManifestKey);
    } else {
      next[vncSettingsManifestKey] = toJson();
    }
    return next.isEmpty ? null : next;
  }

  @override
  bool operator ==(Object other) =>
      other is VncSettings &&
      other.resolution == resolution &&
      other.scaling == scaling &&
      (resolution != VncResolutionMode.fixed ||
          (other.width == width && other.height == height));
  @override
  int get hashCode => Object.hash(resolution, scaling);
}
