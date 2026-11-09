import 'package:desktop_drop/web_drop_collector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every access so tests can prove what the collector never touched.
class _Log {
  int entryReads = 0;
  int fileReads = 0;
  int directoryReads = 0;
  final created = <String>[];
  final revoked = <String>[];
}

class _Item implements WebDropSourceItem {
  _Item(this.log, this.entry, {this.kind = 'file'});
  final _Log log;
  final WebDropSourceEntry? entry;
  @override
  final String kind;
  @override
  WebDropSourceEntry? getAsEntry() {
    log.entryReads++;
    return entry;
  }
}

class _File implements WebDropSourceFile {
  _File(this.name, this.size);
  @override
  final String name;
  @override
  final int size;
  @override
  String get type => 'text/plain';
  @override
  int get lastModified => 0;
}

class _Entry implements WebDropSourceEntry {
  _Entry(
    this.log,
    this.name, {
    this.isDirectory = false,
    this.children = const [],
    this.failFile = false,
  });
  final _Log log;
  @override
  final String name;
  @override
  final bool isDirectory;
  final List<WebDropSourceEntry> children;
  final bool failFile;
  @override
  String get fullPath => '/$name';
  @override
  Future<WebDropSourceFile> file() async {
    log.fileReads++;
    if (failFile) throw StateError('NotReadableError');
    return _File(name, 3);
  }

  @override
  Future<List<WebDropSourceEntry>> readAllChildren() async {
    log.directoryReads++;
    return children;
  }
}

Future<WebDropCollection> _collect(
  _Log log,
  List<WebDropSourceItem> items, {
  int? maxItems = 64,
  bool expandDirectories = false,
}) {
  var next = 0;
  return collectWebDrop(
    items,
    maxItems: maxItems,
    expandDirectories: expandDirectories,
    createFileUrl: (file) {
      final url = 'blob:file-${next++}';
      log.created.add(url);
      return url;
    },
    createDirectoryUrl: () {
      final url = 'blob:dir-${next++}';
      log.created.add(url);
      return url;
    },
    revokeUrl: log.revoked.add,
  );
}

void main() {
  test('an oversized drop is rejected before any entry or URL', () async {
    final log = _Log();
    final items = [for (var i = 0; i < 65; i++) _Item(log, _Entry(log, 'f$i'))];
    final result = await _collect(log, items);
    expect(result, isA<WebDropRejected>());
    final rejected = result as WebDropRejected;
    expect(rejected.reason, WebDropRejection.tooManyItems);
    expect(rejected.itemCount, 65);
    expect(log.entryReads, 0);
    expect(log.fileReads, 0);
    expect(log.created, isEmpty);
  });

  test('a dropped folder is reported without traversal or a URL', () async {
    final log = _Log();
    final folder = _Entry(
      log,
      'photos',
      isDirectory: true,
      children: [for (var i = 0; i < 10000; i++) _Entry(log, 'p$i')],
    );
    final result = await _collect(log, [
      _Item(log, folder),
      _Item(log, _Entry(log, 'a.txt')),
    ]);
    final accepted = result as WebDropAccepted;
    expect(log.directoryReads, 0, reason: 'directory reader never called');
    expect(log.created, ['blob:file-0'], reason: 'URL only for the file');
    expect(accepted.items.map((e) => e.type), ['directory', 'text/plain']);
    expect(accepted.items.first.uri, isEmpty);
    expect(accepted.items.first.children, isEmpty);
    expect(
      accepted.items.first.toDropItem().runtimeType.toString(),
      'DropItemDirectory',
    );
  });

  test('non-file items and null entries are skipped and counted', () async {
    final log = _Log();
    final result = await _collect(log, [
      _Item(log, _Entry(log, 'text'), kind: 'string'),
      _Item(log, null),
      _Item(log, _Entry(log, 'a.txt')),
    ]);
    final accepted = result as WebDropAccepted;
    expect(accepted.skipped, 2);
    expect(accepted.items.single.name, 'a.txt');
    expect(log.entryReads, 2, reason: 'string items are not asked for entries');
  });

  test('a failure revokes every URL already created', () async {
    final log = _Log();
    final result = await _collect(log, [
      _Item(log, _Entry(log, 'a.txt')),
      _Item(log, _Entry(log, 'b.txt')),
      _Item(log, _Entry(log, 'c.txt', failFile: true)),
      _Item(log, _Entry(log, 'd.txt')),
    ]);
    expect((result as WebDropRejected).reason, WebDropRejection.failed);
    expect(log.created, ['blob:file-0', 'blob:file-1']);
    expect(log.revoked, log.created);
    expect(log.fileReads, 3, reason: 'stops at the failing file');
  });

  test('default limits keep upstream folder expansion', () async {
    final log = _Log();
    final folder = _Entry(
      log,
      'docs',
      isDirectory: true,
      children: [_Entry(log, 'x.txt'), _Entry(log, '.DS_Store')],
    );
    final result = await _collect(
      log,
      [_Item(log, folder)],
      maxItems: null,
      expandDirectories: true,
    );
    final item = (result as WebDropAccepted).items.single;
    expect(log.directoryReads, 1);
    expect(item.type, 'directory');
    expect(item.children.map((e) => e.name), ['x.txt', '.DS_Store']);
    expect(log.created.length, 3);
  });
}
