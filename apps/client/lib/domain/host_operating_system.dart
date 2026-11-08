/// Untrusted, informational observations from an authenticated SSH endpoint.
/// These values never participate in host-key trust or authentication.
enum HostOperatingSystemFamily {
  linux,
  windows,
  macos,
  freebsd,
  openbsd,
  netbsd,
  dragonfly,
  solaris,
  aix,
  unix,
}

const hostOperatingSystemManifestKey = 'host_os_v1';

class HostOperatingSystem {
  HostOperatingSystem({
    required this.family,
    required this.displayName,
    required this.detectedAt,
    this.distributionId,
    this.version,
  }) {
    if (!_safeText(displayName, 128) ||
        (version != null && !_safeText(version!, 128)) ||
        (distributionId != null &&
            !RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$')
                .hasMatch(distributionId!)) ||
        detectedAt.millisecondsSinceEpoch <= 0) {
      throw const FormatException('Invalid operating system observation');
    }
  }

  final HostOperatingSystemFamily family;
  final String displayName;
  final String? distributionId;
  final String? version;
  final DateTime detectedAt;

  bool sameSystem(HostOperatingSystem other) =>
      family == other.family &&
      displayName == other.displayName &&
      distributionId == other.distributionId &&
      version == other.version;

  Map<String, Object?> toJson() => {
    'version': 1,
    'family': family.name,
    'display_name': displayName,
    if (distributionId != null) 'distribution_id': distributionId,
    if (version != null) 'system_version': version,
    'detected_at_ms': detectedAt.toUtc().millisecondsSinceEpoch,
  };

  static HostOperatingSystem? read(Map<String, Object?>? manifest) {
    try {
      final raw = manifest?[hostOperatingSystemManifestKey];
      if (raw is! Map || raw['version'] != 1) return null;
      return HostOperatingSystem(
        family: HostOperatingSystemFamily.values.firstWhere(
          (v) => v.name == raw['family'],
        ),
        displayName: raw['display_name'] as String,
        distributionId: raw['distribution_id'] as String?,
        version: raw['system_version'] as String?,
        detectedAt: DateTime.fromMillisecondsSinceEpoch(
          raw['detected_at_ms'] as int,
          isUtc: true,
        ),
      );
    } on Object {
      return null;
    }
  }
}

bool _safeText(String text, int limit) =>
    text.isNotEmpty &&
    text.length <= limit &&
    text == text.trim() &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text);
