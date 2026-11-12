import '../import/termius_transfer.dart';

enum TermiusLocalImportFailure {
  notInstalled,
  keyNotFound,
  keyRejected,
  unsupportedCipher,
  emptyDatabase,
  readFailed,
}

class TermiusLocalImportException implements Exception {
  const TermiusLocalImportException(this.failure, [this.detail]);

  final TermiusLocalImportFailure failure;
  final String? detail;

  @override
  String toString() => 'TermiusLocalImportException(${failure.name}, $detail)';
}

bool hasLocalTermiusInstallation() => false;

Future<({TermiusImportDocument document, String sourceLabel})>
loadLocalTermiusAppDocument({String? customDataDir}) =>
    Future.error(
      const TermiusLocalImportException(TermiusLocalImportFailure.notInstalled),
    );
