import 'package:flutter/foundation.dart';

import '../domain/window_placement.dart';
import 'file_window_tracking_contract.dart';
import 'files_window_launch.dart';
import '../l10n/l10n.dart';

class TrackedFilesWindows extends ChangeNotifier {
  static final instance = TrackedFilesWindows();
  int readyWindowCount(Object owner) => 0;
  int ownedWindowCount(Object owner) => 0;
  bool hasWindows(Object owner) => false;
  Future<List<FileWindowSnapshot>> capture(Object owner) async => const [];
  Future<TrackedFileWindowHandle> open({
    required Object owner,
    required FilesWindowLaunch launch,
    SavedWindowPlacement? placement,
    bool Function()? isCurrent,
  }) async => throw UnsupportedError(currentL10n.fileWindowsRequireADesktop);
  Future<void> releaseOwner(Object owner) async {}
}

VoidCallback registerTrackedFileProvider(
  FilesWindowLaunch? Function() provider, {
  Object? Function()? scopeEpoch,
}) => () {};
void validateFileTrackingArguments(
  List<String> arguments,
  FilesWindowLaunch? expected,
) {}
Future<void> startFileWindowTracking(
  List<String> arguments,
  FilesWindowLaunch? expected,
) async {}

void validateTrackedFileScope(
  FilesWindowWorkspace workspace,
  String scopeId, {
  String? serverNamespace,
  String? accountId,
}) {}
