import '../l10n/l10n.dart';

class RdpStorageRoot {
  const RdpStorageRoot({
    required this.path,
    this.label = '',
    this.primary = false,
  });
  final String path, label;
  final bool primary;
}

enum RdpStorageIssue { permission, unavailable, picker }

class RdpStorageException implements Exception {
  const RdpStorageException(this.issue, [this.name = '']);
  final RdpStorageIssue issue;
  final String name;
  String get message => switch (issue) {
    RdpStorageIssue.permission => currentL10n.rdpStoragePermissionRequired,
    RdpStorageIssue.unavailable => currentL10n.rdpStorageFolderUnavailable(
      name,
    ),
    RdpStorageIssue.picker => currentL10n.rdpStoragePickerFailed,
  };
  @override
  String toString() => message;
}
