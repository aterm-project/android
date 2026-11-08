import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('xterm OSC parser', () {
    test('keeps title and icon OSC 0, 1 and 2 behavior', () {
      final titles = <String>[];
      final icons = <String>[];
      final terminal = Terminal(
        onTitleChange: titles.add,
        onIconChange: icons.add,
      );

      terminal.write('\u001b]0;window title\u0007');
      terminal.write('\u001b]1;app icon\u001b');
      terminal.write('\\');
      terminal.write('\u001b]2;document title\u0007');

      expect(titles, ['window title', 'document title']);
      expect(icons, ['window title', 'app icon']);
    });

    test(
      'forwards private OSC fields, empty fields, and Unicode after splits',
      () {
        final events = <(String, List<String>)>[];
        final terminal = Terminal(
          onPrivateOSC: (code, args) => events.add((code, args)),
        );
        const frame = '\u001b]777;atermius;v1;;tab-😀;;start;café\u001b\\';

        // Feed one Unicode scalar at a time, including separate ESC/ST writes.
        for (final codePoint in frame.runes) {
          terminal.write(String.fromCharCode(codePoint));
        }

        expect(events.map((event) => event.$1).toList(), ['777']);
        expect(events.single.$2, [
          'atermius',
          'v1',
          '',
          'tab-😀',
          '',
          'start',
          'café',
        ]);
      },
    );

    test('preserves malformed ESC and CAN/SUB compatibility', () {
      final events = <(String, List<String>)>[];
      final terminal = Terminal(
        onPrivateOSC: (code, args) => events.add((code, args)),
      );

      // ESC followed by a non-backslash aborts the OSC, consumes that rune,
      // and dispatches only fields already closed by a semicolon.
      terminal.write('\u001b]777;closed;unfinished\u001bXtail');
      terminal.write('\u001b]778;before\u0018middle\u001aafter\u0007');

      expect(events.map((event) => event.$1).toList(), ['777', '778']);
      expect(events[0].$2, ['closed']);
      expect(events[1].$2, ['before\u0018middle\u001aafter']);
      expect(terminal.buffer.getText(), contains('tail'));
    });

    test(
      'accepts a frame exactly at the code-point cap and drops the next',
      () {
        final events = <(String, List<String>)>[];
        final terminal = Terminal(
          onPrivateOSC: (code, args) => events.add((code, args)),
        );
        const prefix = '777;';
        final exactPayload = List.filled(
          maxOscSequenceCodePoints - prefix.runes.length,
          'x',
        ).join();
        final overLimitPayload = '$exactPayload😀';

        terminal.write('\u001b]$prefix$exactPayload\u0007');
        terminal.write('\u001b]$prefix$overLimitPayload\u0007');

        expect(events, hasLength(1));
        expect(events.single.$1, '777');
        expect(events.single.$2.single, exactPayload);
      },
    );

    test('bounds fields, including empty fields', () {
      final events = <(String, List<String>)>[];
      final terminal = Terminal(
        onPrivateOSC: (code, args) => events.add((code, args)),
      );
      final accepted = [
        '777',
        ...List<String>.filled(maxOscParameterCount - 1, ''),
      ].join(';');
      final rejected = '$accepted;extra';

      terminal.write('\u001b]$accepted\u0007');
      terminal.write('\u001b]$rejected\u0007');

      expect(events, hasLength(1));
      expect(events.single.$1, '777');
      expect(
        events.single.$2,
        List<String>.filled(maxOscParameterCount - 1, ''),
      );
    });

    test(
      'discards an oversized split frame through BEL and resumes cleanly',
      () {
        final events = <(String, List<String>)>[];
        final titles = <String>[];
        final terminal = Terminal(
          onPrivateOSC: (code, args) => events.add((code, args)),
          onTitleChange: titles.add,
        );
        terminal.write('visible-before ');
        terminal.write('\u001b]777;');
        for (var remaining = maxOscSequenceCodePoints; remaining > 0;) {
          final count = remaining < 8192 ? remaining : 8192;
          terminal.write(List<String>.filled(count, 'x').join());
          remaining -= count;
        }
        // The oversized tail remains data even when it resembles terminal
        // controls. ESC followed by an ordinary rune cannot end discard mode.
        terminal.write('\u001b[2J\u001b]0;fake title');
        terminal.write('\u001b');
        terminal.write('Qstill-hidden\u0007visible-after');
        terminal.write('\u001b]777;recovered\u0007');

        expect(events.map((event) => event.$1).toList(), ['777']);
        expect(events.single.$2, ['recovered']);
        expect(titles, isEmpty);
        final screen = terminal.buffer.getText();
        expect(screen, contains('visible-before'));
        expect(screen, contains('visible-after'));
        expect(screen, isNot(contains('still-hidden')));
      },
    );

    test('discards through ST split across writes and resumes private OSC', () {
      final events = <(String, List<String>)>[];
      final terminal = Terminal(
        onPrivateOSC: (code, args) => events.add((code, args)),
      );
      terminal.write('\u001b]777;');
      for (var remaining = maxOscSequenceCodePoints; remaining > 0;) {
        final count = remaining < 4096 ? remaining : 4096;
        terminal.write(List<String>.filled(count, 'y').join());
        remaining -= count;
      }
      terminal.write('\u001b');
      terminal.write('\\after-ST\u001b]779;recovered\u0007');

      expect(events.map((event) => event.$1).toList(), ['779']);
      expect(events.single.$2, ['recovered']);
      expect(terminal.buffer.getText(), contains('after-ST'));
    });
  });
}
