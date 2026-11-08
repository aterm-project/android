// Independent repro by Sol review (forwarding-review-sol-20261107), kept
// verbatim as a regression except for the import path.
import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'support/ssh_port_forward_fakes.dart';
class Handle implements SshPortForwardHandle {
  Handle(this.profileId,{this.gate});
  final Completer<void>? gate;
  @override final String profileId;
  @override bool isClosed=false;
  @override int get listeningPort=>12345;
  @override int get activeConnections=>0;
  @override int get totalConnections=>0;
  @override String? get lastConnectionError=>null;
  @override set onChanged(void Function()? callback){}
  @override Future<void> close() async {isClosed=true;await gate?.future;}
}
class Platform implements SshPortForwardPlatform {
  final gate=Completer<void>();
  final handles=<Handle>[];
  @override bool get isSupported=>true;
  @override String? get unsupportedReason=>null;
  @override Future<SshPortForwardHandle> start(SSHClient _,SshPortForwardProfile p) async {
    final h=Handle(p.id,gate:handles.isEmpty?gate:null);handles.add(h);return h;
  }
}
void main(){test('finishing old Stop must not untrack a restarted listener',() async {
  final platform=Platform();
  final manager=SshPortForwardManager(FakeForwardingSshClient(),platform:platform);
  const p=SshPortForwardProfile(id:'p',name:'p',type:SshPortForwardType.dynamic,bindAddress:'127.0.0.1',bindPort:0);
  await manager.start(p);
  final stopping=manager.stop(p.id);
  final newHandle=await manager.start(p);
  platform.gate.complete();
  await stopping;
  print('new listener open=${!newHandle.isClosed}, manager running=${manager.runningCount}');
  expect(manager.activeProfileIds,contains(p.id));
  await manager.closeAll();
  expect(newHandle.isClosed,isTrue);
});}
