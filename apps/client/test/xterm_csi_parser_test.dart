import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('xterm CSI parser', () {
    test('remote window-size requests cannot resize the terminal or PTY', () {
      final resizeEvents = <(int, int)>[];
      final terminal = Terminal(
        onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
      );
      final initialSize = (terminal.viewWidth, terminal.viewHeight);

      terminal.write('\u001b[8;500;500tAFTER-REMOTE-RESIZE');

      expect(resizeEvents, isEmpty);
      expect((terminal.viewWidth, terminal.viewHeight), initialSize);
      expect(terminal.buffer.getText(), contains('AFTER-REMOTE-RESIZE'));
    });

    test(
      'keeps a split CSI bounded and ignores the completed resize request',
      () {
        final resizeEvents = <(int, int)>[];
        final terminal = Terminal(
          onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
        );

        terminal.write('\u001b[8;');
        expect(resizeEvents, isEmpty);
        terminal.write('240;160tAFTER-SPLIT-CSI');

        expect(resizeEvents, isEmpty);
        expect(terminal.buffer.getText(), contains('AFTER-SPLIT-CSI'));
      },
    );

    test('cancels an incomplete CSI and resumes following terminal text', () {
      final resizeEvents = <(int, int)>[];
      final terminal = Terminal(
        onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
      );

      terminal.write('\u001b[8;500');
      expect(resizeEvents, isEmpty);
      terminal.write('\u0018AFTER-CANCELLED-CSI');

      expect(resizeEvents, isEmpty);
      expect(terminal.buffer.getText(), contains('AFTER-CANCELLED-CSI'));
    });

    test(
      'drops CSI with too many code points and resumes after its final byte',
      () {
        final resizeEvents = <(int, int)>[];
        final terminal = Terminal(
          onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
        );
        final overlongIntermediates = List<String>.filled(
          maxCsiSequenceCodePoints + 1,
          ' ',
        ).join();

        terminal.write(
          '\u001b[$overlongIntermediates' + '8;500;500tAFTER-OVERLONG-CSI',
        );

        expect(resizeEvents, isEmpty);
        expect(terminal.buffer.getText(), contains('AFTER-OVERLONG-CSI'));
      },
    );

    test(
      'keeps discarding an overlong CSI across writes until its final byte',
      () {
        final resizeEvents = <(int, int)>[];
        final terminal = Terminal(
          onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
        );
        final overlongPrefix = List<String>.filled(
          maxCsiSequenceCodePoints + 1,
          ' ',
        ).join();

        terminal.write('\u001b[$overlongPrefix');
        expect(resizeEvents, isEmpty);

        terminal.write('8;500;500');
        expect(resizeEvents, isEmpty);

        terminal.write('tAFTER-SPLIT-OVERLONG-CSI');

        expect(resizeEvents, isEmpty);
        expect(terminal.buffer.getText(), contains('AFTER-SPLIT-OVERLONG-CSI'));
      },
    );

    test(
      'drops CSI with too many parameters and resumes after its final byte',
      () {
        final resizeEvents = <(int, int)>[];
        final terminal = Terminal(
          onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
        );
        final overLimitParameters = List<String>.filled(
          maxCsiParameterCount + 1,
          '8',
        ).join(';');

        terminal.write(
          '\u001b[$overLimitParameters' + 'tAFTER-TOO-MANY-PARAMETERS',
        );

        expect(resizeEvents, isEmpty);
        expect(
          terminal.buffer.getText(),
          contains('AFTER-TOO-MANY-PARAMETERS'),
        );
      },
    );

    test(
      'drops overflowing numeric parameters and resumes after the final byte',
      () {
        final resizeEvents = <(int, int)>[];
        final terminal = Terminal(
          onResize: (columns, rows, _, _) => resizeEvents.add((columns, rows)),
        );
        final oversizedNumber = '${maxCsiParameterValue}0';

        terminal.write('\u001b[8;$oversizedNumber;500tAFTER-OVERFLOW');

        expect(resizeEvents, isEmpty);
        expect(terminal.buffer.getText(), contains('AFTER-OVERFLOW'));
      },
    );

    test(
      'keeps ordinary CSI cursor operations working after bounded parsing',
      () {
        final terminal = Terminal();

        terminal.write('\u001b[2;3HOK');

        expect(terminal.buffer.getText(), contains('OK'));
        expect(terminal.buffer.cursorX, 4);
        expect(terminal.buffer.cursorY, 1);
      },
    );

    test('processes Unicode intact across bounded parser input chunks', () {
      final terminal = Terminal(maxLines: 1000);
      final beforeBoundary = List<String>.filled(
        maxParserInputChunkCodePoints - 1,
        'a',
      ).join();

      terminal.write('${beforeBoundary}😀AFTER-INPUT-CHUNK');

      expect(terminal.buffer.getText(), contains('😀AFTER-INPUT-CHUNK'));
    });
  });
}
