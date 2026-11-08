import '../platform/file_window_tracking.dart';
import '../domain/window_placement.dart';
import '../platform/window_launch_environment.dart';

import 'dart:io';

import '../platform/files_window_launch.dart';
import '../l10n/l10n.dart';

bool get supportsNewWindow =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
bool get supportsFilesWindows => supportsNewWindow;

Future<void> openNewWindow() => _open(const ['--new-window']);

Future<void> openFilesWindow(
  FilesWindowLaunch launch, {
  Object? trackingOwner,
}) async {
  if (trackingOwner != null) {
    await openTrackedFilesWindow(launch, owner: trackingOwner);
    return;
  }
  await _open(launch.toArguments());
}

Future<TrackedFileWindowHandle> openTrackedFilesWindow(
  FilesWindowLaunch launch, {
  required Object owner,
  SavedWindowPlacement? placement,
  bool Function()? isCurrent,
}) => TrackedFilesWindows.instance.open(
  owner: owner,
  launch: launch,
  placement: placement,
  isCurrent: isCurrent,
);

Future<void> _open(List<String> arguments) async {
  if (!supportsNewWindow) {
    throw UnsupportedError(currentL10n.newWindowsRequireADesktop);
  }
  final executable = File(Platform.resolvedExecutable);
  await Process.start(
    executable.path,
    arguments,
    workingDirectory: executable.parent.path,
    mode: ProcessStartMode.detached,
    includeParentEnvironment: false,
    environment: windowLaunchEnvironment(Platform.environment),
  );
}
