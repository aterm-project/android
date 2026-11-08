// Independent repro by Sol review (forwarding-closeall-review-sol-20261107), kept
// verbatim as a regression.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
class Client extends Fake implements SSHClient { final end=Completer<void>(); @override Future<void> get done=>end.future; }
class Handle implements SshPortForwardHandle {
  @override String get profileId=>'p';
  @override int get listeningPort=>12345;
  @override bool isClosed=false;
  @override int get activeConnections=>0;
  @override int get totalConnections=>0;
  @override String? get lastConnectionError=>null;
  @override set onChanged(void Function()? callback){}
  final gate=Completer<void>();
  bool finished=false;
  @override Future<void> close() async {isClosed=true;await gate.future;finished=true;}
}
class Platform implements SshPortForwardPlatform {
  @override bool get isSupported=>true;
  @override String? get unsupportedReason=>null;
  final handle=Handle();
  Completer<SshPortForwardHandle>? startGate;
  @override Future<SshPortForwardHandle> start(SSHClient client,SshPortForwardProfile profile) async=>startGate==null?handle:await startGate!.future;
}
const profile=SshPortForwardProfile(id:'p',name:'p',type:SshPortForwardType.dynamic,bindAddress:'127.0.0.1',bindPort:0);
Future<void> turn() => Future<void>.delayed(Duration.zero);
void main(){
  test('closeAll awaits a handle already being stopped',() async {
    final platform=Platform(); final manager=SshPortForwardManager(Client(),platform:platform);
    await manager.start(profile);
    final stopping=manager.stop('p');
    var returned=false;
    final closing=manager.closeAll().then((_){returned=true;});
    await turn();
    final returnedBeforeRelease=returned;
    print('closeAll returned while stopping handle unfinished: $returnedBeforeRelease');
    platform.handle.gate.complete(); await stopping; await closing;
    expect(returnedBeforeRelease,isFalse);
  });
  test('closeAll awaits cancelled pending start and its eventual handle teardown',() async {
    final platform=Platform()..startGate=Completer<SshPortForwardHandle>();
    final manager=SshPortForwardManager(Client(),platform:platform);
    final starting=manager.start(profile).then<void>((_) {},onError:(Object _){});
    var returned=false;
    final closing=manager.closeAll().then((_){returned=true;});
    await turn();
    final returnedBeforeStart=returned;
    platform.startGate!.complete(platform.handle); await turn();
    final returnedBeforeClose=returned;
    print('closeAll returned before pending start=$returnedBeforeStart and late close=$returnedBeforeClose');
    platform.handle.gate.complete(); await starting; await closing;
    expect(returnedBeforeStart,isFalse);
    expect(returnedBeforeClose,isFalse);
    expect(platform.handle.finished,isTrue);
  });
  test('closeAll joins every overlapping stop after same-profile restarts',() async {
    final platform=MultiPlatform();final manager=SshPortForwardManager(Client(),platform:platform);
    final first=await manager.start(profile) as Handle;
    final stopFirst=manager.stop('p');
    final second=await manager.start(profile) as Handle;
    final stopSecond=manager.stop('p');
    var returned=false;final closing=manager.closeAll().then((_){returned=true;});
    second.gate.complete();await stopSecond;await turn();
    final returnedBeforeFirst=returned;
    print('closeAll returned while earlier overwritten stop unfinished: $returnedBeforeFirst');
    first.gate.complete();await stopFirst;await closing;
    expect(returnedBeforeFirst,isFalse);
  });

}

class MultiPlatform implements SshPortForwardPlatform {
  @override bool get isSupported=>true;
  @override String? get unsupportedReason=>null;
  @override Future<SshPortForwardHandle> start(SSHClient client,SshPortForwardProfile profile) async=>Handle();
}
