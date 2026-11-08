import '../domain/window_placement.dart';
import '../platform/file_window_tracking_contract.dart';

import 'package:web/web.dart' as web;

import '../platform/files_window_launch.dart';
import '../l10n/l10n.dart';

Future<void> openFilesWindow(
  FilesWindowLaunch launch, {
  Object? trackingOwner,
}) async {
  throw UnsupportedError(currentL10n.independentFileWindowsRequireADesktop);
}

bool get supportsNewWindow => true;
bool get supportsFilesWindows => false;

Future<void> openNewWindow() async {
  web.window.open(web.window.location.href, '_blank', 'noopener');
}

Future<TrackedFileWindowHandle> openTrackedFilesWindow(
  FilesWindowLaunch launch, {
  required Object owner,
  SavedWindowPlacement? placement,
  bool Function()? isCurrent,
}) async => throw UnsupportedError(currentL10n.fileWindowsRequireADesktop);
