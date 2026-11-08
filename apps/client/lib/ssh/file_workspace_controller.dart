import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;

import '../domain/sftp_entries.dart';
import 'local_profile_sftp_controller.dart';
import 'scp_transfer_types.dart';
import 'ssh_service.dart';
import '../l10n/l10n.dart';

/// A file tab owns its browsing state and SFTP channel, never its SSH owner.
final class FileWorkspaceController extends ChangeNotifier {
  FileWorkspaceController({
    required this.connection,
    required this.protocol,
    String initialPath = '/',
    LocalProfileSftpTransportFactory? transportFactory,
  }) : _path = _absolutePath('/', initialPath),
       sftp = LocalProfileSftpController(
         connection: connection,
         transportFactory: transportFactory,
       );

  final SshConnection connection;
  final SshTransferProtocol protocol;
  final LocalProfileSftpController sftp;
  String _path;
  String get path => _path;
  List<SftpName> entries = const [];
  SftpName? selected;
  bool loading = false;
  String? error;
  bool _closed = false;
  Future<void>? _closing;
  int _generation = 0;
  bool get isClosed => _closed;

  Future<void> navigate(String path) async {
    if (_closed) return;
    final generation = ++_generation;
    loading = true;
    error = null;
    selected = null;
    notifyListeners();
    try {
      final target = _absolutePath(_path, path);
      final result = await sftp.listDirectory(target);
      if (_closed || generation != _generation) return;
      _path = target;
      entries = result;
    } catch (failure) {
      if (_closed || generation != _generation) return;
      error = protocol == SshTransferProtocol.scp
          ? currentL10n.scpFileListingRequiresTheSftp
          : fileWorkspaceErrorText(failure);
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() => navigate(_path);

  Future<void> enter(SftpName entry) {
    if (entry.attr.isDirectory != true) return Future.value();
    return navigate(sftpChildPath(_path, entry.filename));
  }

  Future<void> up() => navigate(paths.posix.dirname(_path));

  static String _absolutePath(String parent, String path) {
    if (path.isEmpty ||
        path.length > 4096 ||
        containsSftpControlCharacters(path)) {
      throw FormatException(currentL10n.invalidRemoteFolderPath);
    }
    return paths.posix.normalize(paths.posix.join(parent, path));
  }

  void select(SftpName? entry) {
    if (_closed) return;
    selected = entry;
    notifyListeners();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _generation++;
    await sftp.close();
  }

  @override
  void dispose() {
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}

String fileWorkspaceErrorText(Object error) => error is FormatException
    ? error.message
    : currentL10n.theFileActionFailedCheckThe;
