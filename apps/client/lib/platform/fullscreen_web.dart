import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

final _changes = StreamController<bool>.broadcast();
final _listener = ((web.Event _) {
  _changes.add(web.document.fullscreenElement != null);
}).toJS;
bool _listening = false;

Stream<bool> get fullscreenChanges {
  if (!_listening) {
    _listening = true;
    web.document.addEventListener('fullscreenchange', _listener);
  }
  return _changes.stream;
}

Future<bool?> readFullscreen() async => web.document.fullscreenElement != null;

Future<bool> applyFullscreen(bool enabled) async {
  if (enabled) {
    await web.document.documentElement!.requestFullscreen().toDart;
  } else if (web.document.fullscreenElement != null) {
    await web.document.exitFullscreen().toDart;
  }
  return web.document.fullscreenElement != null;
}
