import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../apps/client/lib/desktop/direct/rdp.dart';

Future<void> main(List<String> args) async {
  final c=jsonDecode(await File(args.single).readAsString()) as Map<String,dynamic>;
  for(final pin in [List.filled(64,'0').join(), '']) {
    final connection=RdpConnection.connect(c['host'],c['port'],c['username'],c['password'],pin);
    final result=Completer<void>();
    var errorSeen=false, frameSeen=false;
    final sub=connection.events.listen((_) {frameSeen=true;}, onError:(Object error){
      errorSeen=true;if(!result.isCompleted)result.complete();
    }, onDone:(){if(!result.isCompleted)result.complete();});
    try {
      await result.future.timeout(const Duration(seconds:20));
      if(!errorSeen || frameSeen)throw StateError('Untrusted certificate was not rejected');
    } finally {await connection.close();await sub.cancel();}
  }
  stdout.writeln(jsonEncode({'wrong_pin_rejected':true,'untrusted_without_pin_rejected':true}));
}
