@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:aterm_client/attachments/attachment_file_saver_model.dart';
import 'package:aterm_client/attachments/attachment_file_saver_web.dart'
    as attachment_saver;
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

@JS('Object')
external JSObject _newObject();

@JS('Promise.resolve')
external JSPromise<JSAny?> _resolved(JSAny? value);

@JS('Promise.reject')
external JSPromise<JSAny?> _rejected(JSAny? value);

void main() {
  final hadOriginalPicker = web.window
      .hasProperty('showSaveFilePicker'.toJS)
      .toDart;
  final originalPicker = hadOriginalPicker
      ? web.window.getProperty<JSAny?>('showSaveFilePicker'.toJS)
      : null;

  tearDown(() {
    if (hadOriginalPicker) {
      web.window.setProperty('showSaveFilePicker'.toJS, originalPicker);
    } else {
      web.window.delete('showSaveFilePicker'.toJS);
    }
  });

  test(
    'opens picker synchronously, writes plaintext, and closes on commit',
    () async {
      final writes = <Uint8List>[];
      final lifecycle = <String>[];
      final writable = _fakeWritable(writes: writes, lifecycle: lifecycle);
      final handle = _fakeHandle(writable);
      final pickerNames = <String>[];
      _installPicker((options) {
        pickerNames.add(
          (options as JSObject)
              .getProperty<JSString>('suggestedName'.toJS)
              .toDart,
        );
        return _resolved(handle);
      });

      final pendingWriter = attachment_saver.openStreamingSave(
        fileName: 'verified-output.bin',
        mediaType: 'application/octet-stream',
      );
      // The browser must see showSaveFilePicker in the same turn as the UI click.
      expect(pickerNames, ['verified-output.bin']);

      final AttachmentStreamingSaveWriter? writer = await pendingWriter;
      expect(writer, isNotNull);
      final saveWriter = writer!;
      final first = Uint8List.fromList([0, 0x41, 0xff, 0x10]);
      final second = Uint8List.fromList([0x7f, 0x00, 0x80]);
      await saveWriter.write(first);
      await saveWriter.write(second);
      await saveWriter.commit();
      await saveWriter.commit();

      expect(writes.expand((chunk) => chunk).toList(), [
        0,
        0x41,
        0xff,
        0x10,
        0x7f,
        0,
        0x80,
      ]);
      expect(lifecycle, ['write:4', 'write:3', 'close']);
    },
  );

  test(
    'aborts an uncommitted destination and prevents further writes',
    () async {
      final writes = <Uint8List>[];
      final lifecycle = <String>[];
      final writable = _fakeWritable(writes: writes, lifecycle: lifecycle);
      _installPicker((_) => _resolved(_fakeHandle(writable)));

      final writer = await attachment_saver.openStreamingSave(
        fileName: 'discarded.bin',
        mediaType: 'application/octet-stream',
      );
      expect(writer, isNotNull);
      await writer!.write(Uint8List.fromList([1, 2, 3]));
      await writer.abort();
      await writer.abort();
      await expectLater(
        writer.write(Uint8List.fromList([4])),
        throwsStateError,
      );

      expect(writes.expand((chunk) => chunk).toList(), [1, 2, 3]);
      expect(lifecycle, ['write:3', 'abort']);
    },
  );

  test('returns null when the user cancels the picker', () async {
    var createWritableCalls = 0;
    final handle = _newObject()
      ..setProperty(
        'createWritable'.toJS,
        (() {
          createWritableCalls += 1;
          return _resolved(_newObject());
        }).toJS,
      );
    final abortError = _newObject()
      ..setProperty('name'.toJS, 'AbortError'.toJS);
    _installPicker((_) => _rejected(abortError));

    final writer = await attachment_saver.openStreamingSave(
      fileName: 'cancelled.bin',
      mediaType: 'application/octet-stream',
    );

    expect(writer, isNull);
    expect(createWritableCalls, 0);
  });
}

void _installPicker(JSPromise<JSAny?> Function(JSAny? options) picker) {
  web.window.setProperty('showSaveFilePicker'.toJS, picker.toJS);
}

JSObject _fakeHandle(JSObject writable) =>
    _newObject()
      ..setProperty('createWritable'.toJS, (() => _resolved(writable)).toJS);

JSObject _fakeWritable({
  required List<Uint8List> writes,
  required List<String> lifecycle,
}) => _newObject()
  ..setProperty(
    'write'.toJS,
    ((JSAny? data) {
      final bytes = Uint8List.fromList((data as JSUint8Array).toDart);
      writes.add(bytes);
      lifecycle.add('write:${bytes.length}');
      return _resolved(null);
    }).toJS,
  )
  ..setProperty(
    'close'.toJS,
    (() {
      lifecycle.add('close');
      return _resolved(null);
    }).toJS,
  )
  ..setProperty(
    'abort'.toJS,
    (() {
      lifecycle.add('abort');
      return _resolved(null);
    }).toJS,
  );
