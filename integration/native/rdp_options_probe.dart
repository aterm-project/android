// Isolated-fixture probe for the extended RDP engine (per-Host options).
// Run with: dart --packages=apps/client/.dart_tool/package_config.json \
//   integration/native/rdp_options_probe.dart <private-config.json>
// Config (never pass credentials in argv): {"host","port","username",
// "password","pin","drive_path"?,"width"?,"height"?,"resize_to"?:[w,h]}.
// Never point this at the user's own RDP session.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../apps/client/lib/desktop/direct/connection.dart';
import '../../apps/client/lib/desktop/direct/rdp.dart';
import '../../apps/client/lib/desktop/rdp_settings.dart';

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(await File(args.single).readAsString()) as Map<String, dynamic>;
  final features = rdpEngineFeatures();
  final drive = config['drive_path'] as String?;
  final settings = RdpSettings(
    resolution: config['width'] == null
        ? RdpResolutionMode.fitWindow
        : RdpResolutionMode.fixed,
    width: (config['width'] as int?) ?? 1280,
    height: (config['height'] as int?) ?? 800,
    clipboardFiles: true,
    audio: RdpAudioMode.off,
    drives: [
      if (drive != null) RdpDriveRedirect(name: 'Probe', path: drive),
    ],
  );
  final native = settings.toNativeConfig(
    features: features,
    initialWidth: 1280,
    initialHeight: 800,
  );
  final result = <String, Object?>{
    'features': features.bits,
    'unavailable': native.unavailable,
  };
  final connection = RdpConnection.connect(
    config['host'] as String,
    config['port'] as int,
    config['username'] as String,
    config['password'] as String,
    (config['pin'] as String?) ?? '',
    config: native.text,
  );
  config.remove('password');
  var frames = 0, partial = 0;
  final sizes = <String>{};
  final done = Completer<void>();
  final resize = config['resize_to'] as List?;
  var requested = false;
  connection.events.listen(
    (event) {
      if (event is DesktopFrame) {
        frames++;
        if (!event.full) partial++;
        sizes.add('${event.width}x${event.height}');
        event.onConsumed?.call();
        if (frames == 2) {
          for (final r in 'echo atermius_options_probe'.runes) {
            connection.send(['key', r, 1]);
            connection.send(['key', r, 0]);
          }
          connection.send(['key', 0xff0d, 1]);
          connection.send(['key', 0xff0d, 0]);
        }
      } else if (event is DesktopResizeStatus) {
        result['server_resize'] = event.serverResize;
        if (event.result != null) result['resize_result'] = event.result!.name;
        if (event.serverResize && resize != null && !requested) {
          requested = true;
          connection.send(['size', resize[0] as int, resize[1] as int, true]);
        }
      } else if (event is DesktopRemoteFiles) {
        result['remote_files'] = event.names;
      }
    },
    onError: (Object error) {
      result['error'] = error is RdpCertificateException
          ? 'certificate:${error.sha256}'
          : '$error';
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 15))]);
  result.addAll({
    'frames': frames,
    'partial_frames': partial,
    'sizes': sizes.toList(),
  });
  await connection.close();
  stdout.writeln(jsonEncode(result));
  exit(result.containsKey('error') ? 1 : 0);
}
