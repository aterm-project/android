import 'dart:convert';

enum FilesWindowWorkspace { local, cloud }

enum FilesWindowProtocol { sftp, scp }

/// A navigation request, never an authorization or a credential container.
/// The receiver must resolve exactly this scope/Host through its normal unlock,
/// credential and host-key checks before opening a new SSH connection.
class FilesWindowLaunch {
  FilesWindowLaunch({
    required this.workspace,
    required this.scopeId,
    required this.hostId,
    required this.protocol,
    this.serverNamespace,
    this.accountId,
    this.initialPath = '.',
  }) {
    if (!_validId(scopeId) ||
        !_validId(hostId) ||
        initialPath.isEmpty ||
        utf8.encode(initialPath).length > 4096 ||
        initialPath.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
      throw const FormatException('Invalid file window request.');
    }
    if (workspace == FilesWindowWorkspace.cloud) {
      final uri = Uri.tryParse(serverNamespace ?? '');
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          serverNamespace!.length > 2048 ||
          !_validId(accountId ?? '') ||
          serverNamespace!.contains(RegExp(r'[\x00-\x20\x7f-\x9f]'))) {
        throw const FormatException('Invalid file window scope.');
      }
    } else if (serverNamespace != null || accountId != null) {
      throw const FormatException('Invalid file window scope.');
    }
  }

  final FilesWindowWorkspace workspace;

  /// Local profile ID, or cloud vault ID. Never select a different scope.
  final String scopeId;
  final String hostId;
  final FilesWindowProtocol protocol;
  final String initialPath;

  /// Use secureStorageNamespace(baseUrl), including its tenant path binding.
  final String? serverNamespace;
  final String? accountId;

  static const argument = '--files-window';
  static const maxEncodedLength = 12288;

  Map<String, Object?> toJson() => {
    'v': 1,
    'workspace': workspace.name,
    'scope': scopeId,
    'host': hostId,
    'protocol': protocol.name,
    'path': initialPath,
    'server': serverNamespace,
    'account': accountId,
  };
  factory FilesWindowLaunch.fromJson(Map<String, Object?> value) =>
      detectFilesWindow([
        argument,
        base64Url.encode(utf8.encode(jsonEncode(value))),
      ])!;

  List<String> toArguments() => [
    '--new-window',
    argument,
    base64Url.encode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'workspace': workspace.name,
          'scope': scopeId,
          'host': hostId,
          'protocol': protocol.name,
          'path': initialPath,
          'server': serverNamespace,
          'account': accountId,
        }),
      ),
    ),
  ];

  bool matchesScope(
    FilesWindowWorkspace workspace,
    String scopeId, {
    String? serverNamespace,
    String? accountId,
  }) =>
      this.workspace == workspace &&
      this.scopeId == scopeId &&
      this.serverNamespace == serverNamespace &&
      this.accountId == accountId;

  static bool _validId(String value) =>
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,255}$').firstMatch(value)?.end ==
      value.length;
}

/// Missing requests return null; malformed requests fail closed.
FilesWindowLaunch? detectFilesWindow(List<String> arguments) {
  final indices = <int>[
    for (var i = 0; i < arguments.length; i++)
      if (arguments[i] == FilesWindowLaunch.argument) i,
  ];
  if (indices.isEmpty) return null;
  if (indices.length != 1 || indices.single + 1 >= arguments.length) {
    throw const FormatException('Invalid file window request.');
  }
  final encoded = arguments[indices.single + 1];
  if (encoded.length > FilesWindowLaunch.maxEncodedLength ||
      RegExp(r'^[A-Za-z0-9_=-]+$').firstMatch(encoded)?.end != encoded.length) {
    throw const FormatException('Invalid file window request.');
  }
  try {
    final data = jsonDecode(utf8.decode(base64Url.decode(encoded)));
    const keys = {
      'v',
      'workspace',
      'scope',
      'host',
      'protocol',
      'path',
      'server',
      'account',
    };
    if (data is! Map<String, dynamic> ||
        data.length != keys.length ||
        !data.keys.every(keys.contains) ||
        data['v'] != 1 ||
        data['scope'] is! String ||
        data['host'] is! String ||
        data['path'] is! String) {
      throw const FormatException();
    }
    return FilesWindowLaunch(
      workspace: FilesWindowWorkspace.values.byName(
        data['workspace'] as String,
      ),
      scopeId: data['scope'] as String,
      hostId: data['host'] as String,
      protocol: FilesWindowProtocol.values.byName(data['protocol'] as String),
      initialPath: data['path'] as String,
      serverNamespace: data['server'] as String?,
      accountId: data['account'] as String?,
    );
  } catch (_) {
    throw const FormatException('Invalid file window request.');
  }
}
