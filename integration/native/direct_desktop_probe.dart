// Run with dart --packages=apps/client/.dart_tool/package_config.json.
// Test configuration is a private JSON file; no credentials in process arguments.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../apps/client/lib/desktop/direct/connection.dart';
import '../../apps/client/lib/desktop/direct/rdp.dart';
import '../../apps/client/lib/desktop/direct/rfb.dart';

Future<void> main(List<String> args) async {
  final config = jsonDecode(await File(args.single).readAsString()) as Map<String, dynamic>;
  final protocol = config['protocol'];
  final connection = protocol == 'rdp'
      ? RdpConnection.connect(config['host'], config['port'], config['username'], config['password'], config['pin'])
      : RfbConnection.connect(config['host'], config['port'], config['password']);
  final first = Completer<void>(), changed = Completer<void>();
  Uint8List? initial;
  int frameCount = 0;
  bool disconnected = false;
  final subscription = connection.events.listen((event) {
    if (event is DesktopFrame) {
      frameCount++;
      if (initial == null) {
        initial = event.bgra;
        first.complete();
      } else if (!changed.isCompleted && _different(initial!, event.bgra)) {
        changed.complete();
      }
      final out = config['frame_path'];
      if (out != null) {
        File(out).writeAsBytesSync(event.bgra);
        File('$out.json').writeAsStringSync(jsonEncode({'width':event.width, 'height':event.height}));
      }
      event.onConsumed?.call();
    }
  }, onError: (Object error) {
    if (!first.isCompleted) first.completeError(error);
    else { disconnected = true; stderr.writeln(error); }
  }, onDone: () { disconnected = true; });
  try {
    await first.future.timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    connection.send(['mouse',100,100,1]);
    connection.send(['mouse',100,100,0]);
    final marker = config['marker'] as String;
    if (!RegExp(r'^[a-z0-9_]{1,60}$').hasMatch(marker)) throw StateError('Invalid test marker');
    for (final rune in 'echo $marker > /tmp/$marker'.runes) {
      connection.send(['key', rune, 1]); connection.send(['key', rune, 0]);
    }
    connection.send(['key',0xff0d,1]); connection.send(['key',0xff0d,0]);
    await changed.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (disconnected) throw StateError('Session disconnected during input test');
    stdout.writeln(jsonEncode({'protocol':protocol,'frame_count':frameCount,'frame_changed':true}));
  } finally {
    await connection.close(); await subscription.cancel();
  }
}
bool _different(Uint8List a, Uint8List b) {
  if (a.length != b.length) return true;
  for (var i=0;i<a.length;i++) {if(a[i]!=b[i]) return true;}
  return false;
}
