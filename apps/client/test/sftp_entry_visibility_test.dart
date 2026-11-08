import 'package:aterm_client/domain/sftp_entries.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

SftpName _entry(String filename) =>
    SftpName(filename: filename, longname: filename, attr: SftpFileAttrs());

void main() {
  test('hides navigation entries and unsafe remote basenames', () {
    final entries = [
      _entry('.'),
      _entry('..'),
      _entry(''),
      _entry('subdir/escape'),
      _entry(r'subdir\escape'),
      _entry('nul\u0000name'),
      _entry('line\nbreak'),
      _entry('tab\tname'),
      _entry('c1\u0085name'),
      _entry('.ssh'),
      _entry('deploy.tar'),
    ];

    expect(visibleSftpEntries(entries).map((entry) => entry.filename), [
      '.ssh',
      'deploy.tar',
    ]);
  });

  test('treats a listing with only invalid names as empty', () {
    expect(
      visibleSftpEntries([
        _entry('.'),
        _entry('..'),
        _entry(''),
        _entry('../secret'),
        _entry(r'..\secret'),
        _entry('nul\u0000name'),
        _entry('line\nbreak'),
        _entry('c1\u0085name'),
      ]),
      isEmpty,
    );
  });

  test('joins a safe basename under the selected remote directory', () {
    expect(sftpChildPath('/', 'file.txt'), '/file.txt');
    expect(sftpChildPath('/var/log/', 'file.txt'), '/var/log/file.txt');
    expect(sftpChildPath('', 'file.txt'), '/file.txt');
  });

  test('refuses path-like basenames for every file action', () {
    for (final name in [
      '',
      '.',
      '..',
      '../secret',
      r'..\secret',
      'a/b',
      'a\u0000b',
      'line\nbreak',
      'tab\tname',
      'c1\u0085name',
    ]) {
      expect(() => sftpChildPath('/selected', name), throwsFormatException);
    }
  });

  test('refuses explicit parent paths containing control characters', () {
    for (final parent in [
      '/tmp/line\nbreak',
      '/tmp/tab\tname',
      '/tmp/c1\u0085',
    ]) {
      expect(() => sftpChildPath(parent, 'file.txt'), throwsFormatException);
    }
  });
}
