import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'mcp_access_policy.dart';
import 'mcp_access_policy_store.dart';

/// One small JSON file per scope in the application-support directory. The
/// file name is a hash so account/profile identifiers do not appear in
/// directory listings; the scope is also stored inside and verified on read.
class FileMcpAccessPolicyStore implements McpAccessPolicyStore {
  FileMcpAccessPolicyStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file(String scope) async {
    if (scope.isEmpty || scope.length > mcpAccessPolicyMaxScopeLength) {
      throw const McpAccessPolicyStoreUnavailable();
    }
    final name = sha256.convert(utf8.encode(scope)).toString();
    final root = await _directory();
    return File('${root.path}/mcp-access-v1/$name.json');
  }

  @override
  Future<McpAccessPolicy?> read(String scope) async {
    final file = await _file(scope);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        await file.length() > mcpAccessPolicyMaxStoredBytes) {
      throw const McpAccessPolicyFormatException();
    }
    return McpAccessPolicy.decode(await file.readAsString(), scope);
  }

  @override
  Future<void> write(String scope, McpAccessPolicy policy) async {
    final file = await _file(scope);
    final encoded = policy.encode(scope);
    if (encoded.length > mcpAccessPolicyMaxStoredBytes) {
      throw const McpAccessPolicyFormatException();
    }
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.mcp-access-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(encoded, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

McpAccessPolicyStore createStore() => FileMcpAccessPolicyStore();
