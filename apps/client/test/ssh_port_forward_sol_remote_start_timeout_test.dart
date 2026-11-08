// Independent repro by Sol review (forwarding-review-sol-20261107), kept
// verbatim as a regression except for the import path.
import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'support/ssh_port_forward_fakes.dart';
class DelayedRemote extends FakeForwardingSshClient {
  final delayed=Completer<SSHRemoteForward?>();
  @override Future<SSHRemoteForward?> forwardRemote({String? host,int? port,SSHRemoteConnectionFilter? filter})=>delayed.future;
}
void main(){
  test('timed-out remote start cannot leave an untracked remote listener',(){
    fakeAsync((clock){
      final client=DelayedRemote();
      final manager=SshPortForwardManager(client);
      const profile=SshPortForwardProfile(id:'remote',name:'Remote',type:SshPortForwardType.remote,bindAddress:'127.0.0.1',bindPort:22001,destinationAddress:'127.0.0.1',destinationPort:80);
      Object? error;
      manager.start(profile).then<void>((_) {},onError:(Object e){error=e;});
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds:21));
      clock.flushMicrotasks();
      expect(error,isNotNull);
      final lateListener=FakeRemoteForward('127.0.0.1',22001);
      client.delayed.complete(lateListener);
      clock.flushMicrotasks();
      print('status=${manager.statusOf(profile.id).state}, listener closed=${lateListener.closed}, transport closes=${client.closeCount}, cancellations=${client.remoteCancelCount}');
      expect(manager.runningCount,0);
      expect(lateListener.closed || client.closeCount>0 || client.remoteCancelCount>0,isTrue);
      manager.dispose();
      clock.flushMicrotasks();
    });
  });
}
