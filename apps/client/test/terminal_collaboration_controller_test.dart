import 'package:flutter_test/flutter_test.dart';

import 'package:aterm_client/app_controller.dart';

void main() {
  group('TerminalTabSession output fanout', () {
    test('shares output without replacing the existing UI listener', () {
      final tab = TerminalTabSession(id: 'tab-1', host: null);
      final visibleOutput = <String>[];
      final observerOutput = <String>[];
      tab.outputListener = visibleOutput.add;
      final token = tab.addOutputFanout(observerOutput.add);

      tab.outputListener?.call('prompt> ');
      tab.publishOutputToFanout('prompt> ');

      expect(visibleOutput, ['prompt> ']);
      expect(observerOutput, ['prompt> ']);

      tab.removeOutputFanout(token);
      tab.publishOutputToFanout('next');
      expect(visibleOutput, ['prompt> ']);
      expect(observerOutput, ['prompt> ']);
    });

    test('a failed observer listener does not block remaining listeners', () {
      final tab = TerminalTabSession(id: 'tab-2', host: null);
      final delivered = <String>[];
      tab.addOutputFanout((_) => throw StateError('observer transport failed'));
      tab.addOutputFanout(delivered.add);

      tab.publishOutputToFanout('still delivered');

      expect(delivered, ['still delivered']);
    });
  });
}
