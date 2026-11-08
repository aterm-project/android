import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_csv.dart';
import 'package:aterm_client/import/termius_openssh.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

// Synthetic-only values. None of these are real credentials.
const _header = 'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password';

int _ids = 0;
String _id() =>
    '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

TermiusCatalog _empty() => TermiusCatalog(hosts: const [], groups: const []);

List<TermiusIssueCode> _codes(Iterable<TermiusIssue> issues) =>
    issues.map((issue) => issue.code).toList();

void main() {
  useAppLocaleFixture('en');

  group('TermiusCsv codec', () {
    test('BOM, CRLF, quoted commas, newlines and doubled quotes', () {
      final records = TermiusCsv.parse(
        '﻿a,b,c\r\n"x, y","line1\r\nline2","say ""hi"""\r\n',
      );
      expect(records, hasLength(2));
      expect(records[0].fields, ['a', 'b', 'c']);
      expect(records[1].fields, ['x, y', 'line1\r\nline2', 'say "hi"']);
      expect(records[1].line, 2);
    });

    test('LF, lone CR and a missing final newline', () {
      final records = TermiusCsv.parse('a,b\nc,d\re,f');
      expect(records.map((r) => r.fields).toList(), [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ]);
    });

    test('structural errors report positions, never values', () {
      for (final (source, code) in [
        ('a,b\n"unterminated,x', TermiusCsvErrorCode.unterminatedQuote),
        ('a,b\nab"c,d', TermiusCsvErrorCode.strayQuote),
        ('a,b\n"ab"c,d', TermiusCsvErrorCode.strayQuote),
        ('a\u0000b', TermiusCsvErrorCode.nulCharacter),
      ]) {
        expect(
          () => TermiusCsv.parse(source),
          throwsA(
            isA<TermiusCsvException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.toString(), 'text', isNot(contains('ab'))),
          ),
        );
      }
    });

    test('byte cap counts UTF-8 bytes, not UTF-16 units', () {
      // 3-byte characters: just below and just above the cap.
      const perChar = '界';
      final under = perChar * (maxTermiusCsvBytes ~/ 3);
      final over = '$under界';
      expect(utf8EncodedLength(under), utf8.encode(under).length);
      expect(utf8EncodedLength(under), lessThanOrEqualTo(maxTermiusCsvBytes));
      expect(utf8EncodedLength(over), greaterThan(maxTermiusCsvBytes));
      expect(over.length, lessThan(maxTermiusCsvBytes));
      expect(
        () => TermiusCsv.parse(over),
        throwsA(
          isA<TermiusCsvException>().having(
            (e) => e.code,
            'code',
            TermiusCsvErrorCode.tooLarge,
          ),
        ),
      );
      final document = TermiusCsvImporter.parse(over);
      expect(_codes(document.fileIssues), [TermiusIssueCode.fileTooLarge]);
      // Surrogate pairs are 4 bytes.
      expect(utf8EncodedLength('😀'), 4);
      expect(utf8EncodedLength('aé世😀'), utf8.encode('aé世😀').length);
    });

    test('encode quotes exactly what needs quoting and round-trips', () {
      final rows = [
        ['plain', 'a,b', 'q"uote', 'multi\nline', ' lead', 'trail ', ''],
      ];
      final text = TermiusCsv.encode(rows);
      expect(text.startsWith('﻿'), isTrue);
      expect(text, contains('plain,"a,b","q""uote","multi\nline"," lead","trail ",\r\n'));
      expect(TermiusCsv.parse(text).single.fields, rows.single);
    });
  });

  group('Termius CSV schema', () {
    test('root synthetic fixture matches the installed-parser oracle', () {
      final bytes = File(
        'test/fixtures/termius/root_unicode_quoted_synthetic.csv',
      ).readAsBytesSync();
      final document = TermiusCsvImporter.parseBytes(bytes);
      expect(document.blocksWholeFile, isFalse);
      expect(document.fileIssues, isEmpty);
      expect(document.rows, hasLength(3));
      final first = document.rows[0];
      expect(first.groupPath, ['项目', '开发']);
      expect(first.label, '主机, "甲"\n第二行');
      expect(first.tags, ['dev', '测试']);
      expect(first.address, 'example.invalid');
      expect(first.port, 2222);
      expect(first.username, 'fixture_user');
      // Exact bytes, including leading spaces and the embedded CRLF.
      expect(first.password, ' @=fixture, "password"\r\n ');
      final second = document.rows[1];
      expect(second.groupPath, isEmpty);
      expect(second.label, 'Empty port');
      expect(second.port, 22);
      expect(second.password, isNull);
      final third = document.rows[2];
      expect(third.groupPath, ['Prod', 'Edge']);
      expect(third.address, '2001:db8::1');
      expect(third.tags, ['x', 'y']);
      expect(third.password, '=synthetic-only');
      expect(document.rows.every((row) => !row.blocked), isTrue);
    });

    test('unknown, duplicate and missing headers are reported', () {
      final unknown = TermiusCsvImporter.parse(
        '$_header,Notes\n,web,,web.example,ssh,22,u,,hello\n',
      );
      expect(_codes(unknown.fileIssues), [
        TermiusIssueCode.headerOrderNotTermius,
        TermiusIssueCode.unknownHeader,
      ]);
      expect(unknown.fileIssues.last.detail, 'Notes');
      expect(
        _codes(unknown.rows.single.issues),
        contains(TermiusIssueCode.unknownColumnValue),
      );
      expect(unknown.rows.single.blocked, isFalse);

      final duplicate = TermiusCsvImporter.parse('Label,Label,Hostname/IP\n');
      expect(duplicate.blocksWholeFile, isTrue);
      expect(_codes(duplicate.fileIssues), [TermiusIssueCode.duplicateHeader]);

      final noHost = TermiusCsvImporter.parse('Groups,Label\nA,B\n');
      expect(_codes(noHost.fileIssues), [
        TermiusIssueCode.missingHostnameColumn,
      ]);
      final noHeader = TermiusCsvImporter.parse('web,1.2.3.4,22\n');
      expect(_codes(noHeader.fileIssues), [TermiusIssueCode.noTemplateHeader]);
      final empty = TermiusCsvImporter.parse('﻿\r\n\r\n');
      expect(_codes(empty.fileIssues), [TermiusIssueCode.emptyFile]);
      final notUtf8 = TermiusCsvImporter.parseBytes([0xff, 0xfe, 0x00]);
      expect(_codes(notUtf8.fileIssues), [TermiusIssueCode.fileNotUtf8]);
    });

    test('row validation: protocol, port, username, address, tags, groups', () {
      final document = TermiusCsvImporter.parse(
        [
          _header,
          ',telnet,,t.example,telnet,23,u,',
          ',mosh,,m.example,mosh,60000,u,',
          ',badport,,p.example,ssh,70000,u,',
          ',nouser,,n.example,ssh,22,,',
          ',space,,"bad host",ssh,22,u,',
          ',rdp,,r.example,rdp,,,',
          '"a//b/ ",tags,"x, X ,y,,",g.example,SSH,,u,',
          ',noaddr,,,ssh,22,u,',
        ].join('\n'),
      );
      final rows = document.rows;
      expect(_codes(rows[0].issues), [TermiusIssueCode.unsupportedProtocol]);
      expect(rows[0].blocked, isTrue);
      expect(rows[1].protocol, HostProtocol.ssh);
      expect(_codes(rows[1].issues), [TermiusIssueCode.moshImportedAsSsh]);
      expect(rows[1].blocked, isFalse);
      expect(_codes(rows[2].issues), [TermiusIssueCode.invalidPort]);
      expect(_codes(rows[3].issues), [TermiusIssueCode.missingUsername]);
      expect(_codes(rows[4].issues), [TermiusIssueCode.invalidAddress]);
      expect(rows[5].protocol, HostProtocol.rdp);
      expect(rows[5].port, 3389);
      expect(_codes(rows[5].issues), [TermiusIssueCode.extensionProtocol]);
      expect(rows[6].groupPath, ['a', 'b']);
      expect(rows[6].tags, ['x', 'y']);
      expect(_codes(rows[6].issues), [
        TermiusIssueCode.emptyGroupSegment,
        TermiusIssueCode.duplicateTagDropped,
      ]);
      expect(rows[6].protocol, HostProtocol.ssh);
      expect(_codes(rows[7].issues), [TermiusIssueCode.missingAddress]);
    });

    test('SSH_KEY: inline key accepted, references reported, never opened', () {
      const key =
          '-----BEGIN OPENSSH PRIVATE KEY-----\r\nc3ludGhldGlj\r\n-----END OPENSSH PRIVATE KEY-----';
      final document = TermiusCsvImporter.parse(
        [
          '$_header,SSH_KEY',
          ',k,,k.example,ssh,22,u,,"$key"',
          ',both,,b.example,ssh,22,u,pw,"$key"',
          ',ref,,r.example,ssh,22,u,pw,~/.ssh/id_ed25519',
        ].join('\n'),
      );
      expect(_codes(document.fileIssues), [
        TermiusIssueCode.nonTemplateColumn,
        TermiusIssueCode.headerOrderNotTermius,
      ]);
      expect(
        document.rows[0].privateKey,
        '-----BEGIN OPENSSH PRIVATE KEY-----\nc3ludGhldGlj\n-----END OPENSSH PRIVATE KEY-----\n',
      );
      expect(document.rows[1].password, isNull);
      expect(_codes(document.rows[1].issues), [
        TermiusIssueCode.passwordDroppedForKey,
      ]);
      expect(document.rows[2].privateKey, isNull);
      expect(document.rows[2].password, 'pw');
      expect(_codes(document.rows[2].issues), [
        TermiusIssueCode.sshKeyNotInline,
      ]);
      // Diagnostics never carry secret material.
      for (final row in document.rows) {
        expect(row.toString(), isNot(contains('c3ludGhldGlj')));
        expect(row.toString(), isNot(contains('pw')));
        for (final issue in row.issues) {
          expect(issue.toString(), isNot(contains('c3ludGhldGlj')));
        }
      }
    });

    test('too many rows is a whole-file failure', () {
      final rows = [
        _header,
        for (var i = 0; i <= maxTermiusImportRows; i++) ',h$i,,h$i.example,ssh,22,u,',
      ];
      final document = TermiusCsvImporter.parse(rows.join('\n'));
      expect(document.blocksWholeFile, isTrue);
      expect(document.rows, isEmpty);
    });
  });

  group('planner', () {
    test('nested groups reuse existing ones and credentials stay on their host', () {
      const existingRoot = GroupRecord(
        id: '10000000-0000-4000-8000-000000000001',
        name: 'Project',
      );
      final catalog = TermiusCatalog(hosts: const [], groups: const [existingRoot]);
      final document = TermiusCsvImporter.parse(
        [
          _header,
          'project/Dev,web,a,w.example,ssh,22,alice,"  spaced pw  "',
          'Project/dev/Inner,db,,d.example,ssh,2200,bob,',
          'Other,x,,x.example,ssh,22,carol,secret-x',
        ].join('\r\n'),
      );
      final plan = TermiusImportPlanner.plan(document, catalog, newId: _id);
      expect(plan.canApply, isTrue);
      expect(plan.createCount, 3);
      // Project reused (case-insensitive); Dev, Inner, Other created once.
      expect(plan.newGroups.map((g) => g.name), ['Dev', 'Inner', 'Other']);
      final dev = plan.newGroups[0];
      expect(dev.parentId, existingRoot.id);
      expect(plan.newGroups[1].parentId, dev.id);
      final hosts = plan.hostsToCreate;
      expect(hosts[0].groupId, dev.id);
      expect(hosts[0].login?.password, '  spaced pw  ');
      expect(hosts[0].authKind, AuthKind.password);
      expect(hosts[1].groupId, plan.newGroups[1].id);
      expect(hosts[1].login, isNull);
      expect(hosts[2].login?.password, 'secret-x');
      expect(plan.secretCount, 2);
      for (final host in hosts) {
        expect(host.validate(), isNull);
      }
    });

    test('duplicates: in-file, existing (skip or import), name collision', () {
      final existing = HostRecord(
        id: _id(),
        name: 'web',
        address: 'w.example',
        username: 'alice',
      );
      final other = HostRecord(
        id: _id(),
        name: 'api',
        address: 'other.example',
        username: 'alice',
      );
      final catalog = TermiusCatalog(hosts: [existing, other], groups: const []);
      final document = TermiusCsvImporter.parse(
        [
          _header,
          ',web,,w.example,ssh,22,alice,',
          ',api,,api.example,ssh,22,alice,',
          ',new,,n.example,ssh,22,alice,',
          ',NEW,,n.example,ssh,22,alice,',
        ].join('\n'),
      );
      final plan = TermiusImportPlanner.plan(document, catalog, newId: _id);
      expect(plan.rows.map((r) => r.disposition).toList(), [
        TermiusRowDisposition.skippedExisting,
        TermiusRowDisposition.create,
        TermiusRowDisposition.create,
        TermiusRowDisposition.skippedDuplicate,
      ]);
      expect(_codes(plan.rows[1].issues), [TermiusIssueCode.nameAlreadyUsed]);
      expect(plan.rows[3].issues.last.row, 3);

      final asNew = TermiusImportPlanner.plan(
        document,
        catalog,
        duplicates: TermiusDuplicatePolicy.importAsNew,
        newId: _id,
      );
      expect(asNew.createCount, 3);

      final excluded = TermiusImportPlanner.plan(
        document,
        catalog,
        excludedRows: {2, 3, 4},
        newId: _id,
      );
      expect(excluded.createCount, 0);
      expect(excluded.canApply, isFalse);
    });

    test('groups are only created for hosts that will be created', () {
      final document = TermiusCsvImporter.parse(
        [_header, 'Lonely,x,,x.example,ssh,22,u,', 'Kept,y,,y.example,ssh,22,u,'].join('\n'),
      );
      final plan = TermiusImportPlanner.plan(
        document,
        _empty(),
        excludedRows: {1},
        newId: _id,
      );
      expect(plan.newGroups.map((g) => g.name), ['Kept']);
    });

    test('catalog fingerprint changes when records change', () {
      final host = HostRecord(id: _id(), name: 'a', address: 'a', username: 'u');
      final a = TermiusCatalog(hosts: [host], groups: const []);
      final b = TermiusCatalog(hosts: [host], groups: const []);
      final c = TermiusCatalog(
        hosts: [host.copyWith(address: 'b')],
        groups: const [],
      );
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint, isNot(c.fingerprint));
      // Inherited sign-in inputs are covered (metadata only, never secrets).
      final credential = CredentialRecord(
        id: _id(),
        name: 'k',
        username: 'svc',
        secret: 'synthetic-secret',
      );
      final groupA = GroupRecord(id: _id(), name: 'g');
      final withDefault = TermiusCatalog(
        hosts: [host],
        groups: [GroupRecord(id: groupA.id, name: 'g', defaultCredentialId: credential.id)],
        credentials: [credential],
      );
      final withoutDefault = TermiusCatalog(
        hosts: [host],
        groups: [groupA],
        credentials: [credential],
      );
      expect(withDefault.fingerprint, isNot(withoutDefault.fingerprint));
      final renamedUser = TermiusCatalog(
        hosts: [host],
        groups: [GroupRecord(id: groupA.id, name: 'g', defaultCredentialId: credential.id)],
        credentials: [
          CredentialRecord(
            id: credential.id,
            name: 'k',
            username: 'other',
            secret: 'synthetic-secret',
          ),
        ],
      );
      expect(withDefault.fingerprint, isNot(renamedUser.fingerprint));
      final secretOnly = TermiusCatalog(
        hosts: [host],
        groups: [GroupRecord(id: groupA.id, name: 'g', defaultCredentialId: credential.id)],
        credentials: [
          CredentialRecord(
            id: credential.id,
            name: 'k',
            username: 'svc',
            secret: 'different-secret',
          ),
        ],
      );
      // Secret bytes are not part of the digest (a revision change is).
      expect(withDefault.fingerprint, secretOnly.fingerprint);
    });
  });

  group('export', () {
    final groupRoot = GroupRecord(id: _id(), name: '项目');
    final groupChild = GroupRecord(id: _id(), name: 'Dev', parentId: groupRoot.id);
    final sharedCredential = CredentialRecord(
      id: _id(),
      name: 'shared',
      username: 'svc',
      secret: 'shared-synthetic',
    );
    List<HostRecord> hosts() => [
      HostRecord(
        id: '20000000-0000-4000-8000-000000000001',
        name: '主机, "甲"\n第二行',
        address: 'example.invalid',
        port: 2222,
        username: 'fixture_user',
        groupId: groupChild.id,
        tags: const ['dev', '测试'],
        login: const HostLogin(
          kind: AuthKind.password,
          password: ' @=fixture, "password"\r\n ',
        ),
      ),
      const HostRecord(
        id: '20000000-0000-4000-8000-000000000002',
        name: '=SUM(A1)',
        address: '192.0.2.10',
        username: 'u',
        login: HostLogin(
          kind: AuthKind.privateKey,
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----\n',
        ),
        jumpHostId: '20000000-0000-4000-8000-000000000001',
      ),
      HostRecord(
        id: '20000000-0000-4000-8000-000000000003',
        name: 'shared-user',
        address: 'svc.example',
        username: 'svc',
        credentialId: sharedCredential.id,
        tags: const ['a,b'],
      ),
      const HostRecord(
        id: '20000000-0000-4000-8000-000000000004',
        name: 'desktop',
        address: 'rdp.example',
        protocol: HostProtocol.rdp,
      ),
    ];
    TermiusCatalog catalog() => TermiusCatalog(
      hosts: hosts(),
      groups: [groupRoot, groupChild],
      credentials: [sharedCredential],
    );

    test('CSV has exactly the template header and no secrets by default', () {
      final result = TermiusExporter.csv(catalog());
      final records = TermiusCsv.parse(result.text);
      expect(records.first.fields, TermiusCsvColumn.template);
      expect(result.exportedHosts, 3);
      expect(result.containsSecrets, isFalse);
      expect(result.text, isNot(contains('fixture, ')));
      expect(result.text, isNot(contains('shared-synthetic')));
      expect(result.text, isNot(contains('PRIVATE KEY')));
      for (final record in records.skip(1)) {
        expect(record.fields, hasLength(8));
        expect(record.fields[7], isEmpty);
      }
      expect(
        _codes(result.issues),
        containsAll([
          TermiusIssueCode.exportSkippedProtocol,
          TermiusIssueCode.exportJumpNotRepresented,
          TermiusIssueCode.exportKeysNotRepresented,
          TermiusIssueCode.exportSecretsOmitted,
          TermiusIssueCode.exportFormulaRisk,
          TermiusIssueCode.exportTagComma,
        ]),
      );
    });

    test('opt-in passwords are verbatim and re-import losslessly', () {
      final result = TermiusExporter.csv(
        catalog(),
        options: const TermiusExportOptions(includePasswords: true),
      );
      expect(result.containsSecrets, isTrue);
      // Values are never formula-escaped.
      expect(result.text, contains('"=SUM(A1)"'.replaceAll('"', '')));
      expect(result.text, isNot(contains("'=SUM")));
      final document = TermiusCsvImporter.parse(result.text);
      expect(document.fileIssues, isEmpty);
      final byLabel = {for (final row in document.rows) row.label: row};
      final first = byLabel['主机, "甲"\n第二行']!;
      expect(first.groupPath, ['项目', 'Dev']);
      expect(first.tags, ['dev', '测试']);
      expect(first.password, ' @=fixture, "password"\r\n ');
      expect(first.port, 2222);
      expect(byLabel['=SUM(A1)']!.password, isNull);
      expect(byLabel['shared-user']!.password, 'shared-synthetic');
      // The comma tag cannot survive Termius' separator and is disclosed.
      expect(byLabel['shared-user']!.tags, ['a', 'b']);
    });

    test('OpenSSH export carries no secrets and re-imports', () {
      final result = TermiusExporter.openSsh(catalog());
      expect(result.containsSecrets, isFalse);
      expect(result.text, isNot(contains('PRIVATE')));
      expect(result.text, isNot(contains(RegExp(r'^\s*IdentityFile', multiLine: true))));
      expect(result.text, isNot(contains('synthetic')));
      expect(
        _codes(result.issues),
        containsAll([
          TermiusIssueCode.exportAliasRewritten,
          TermiusIssueCode.exportKeysOmitted,
          TermiusIssueCode.exportPasswordsNotRepresented,
          TermiusIssueCode.exportSkippedProtocol,
        ]),
      );
      final document = TermiusOpenSshImporter.parse(result.text);
      expect(document.blocksWholeFile, isFalse);
      final plan = TermiusImportPlanner.plan(document, _empty(), newId: _id);
      expect(plan.createCount, 3);
      final jumper = plan.hostsToCreate.firstWhere(
        (host) => host.address == '192.0.2.10',
      );
      final target = plan.hostsToCreate.firstWhere(
        (host) => host.address == 'example.invalid',
      );
      expect(jumper.jumpHostId, target.id);
      expect(target.port, 2222);
    });

    test('writer fixture is stable (root oracle input)', () {
      final result = TermiusExporter.csv(
        catalog(),
        options: const TermiusExportOptions(includePasswords: true),
        now: DateTime.utc(2026, 11, 8),
      );
      final file = File('test/fixtures/termius/writer_export_synthetic.csv');
      final bytes = utf8.encode(result.text);
      if (Platform.environment['TERMIUS_WRITE_FIXTURES'] == '1') {
        file.writeAsBytesSync(bytes);
      }
      expect(bytes, file.readAsBytesSync());
    });
  });

  group('OpenSSH (termius-cli and ~/.ssh styles)', () {
    test('termius export-ssh-config output imports with explicit warnings', () {
      const config = '''
Host web
    HostName 192.0.2.5
    User deploy
    Port 2201
    IdentityFile ~/.termius/ssh_keys/web-key

Host db
    HostName db.example
    User admin
    ServerAliveInterval 30
    StrictHostKeyChecking no
    LocalForward 15432 127.0.0.1:5432
    RemoteForward 8080 10.0.0.5:80
    DynamicForward 1080
    ProxyJump web
''';
      final document = TermiusOpenSshImporter.parse(config);
      expect(document.blocksWholeFile, isFalse);
      final web = document.rows.firstWhere((row) => row.label == 'web');
      expect(web.port, 2201);
      expect(
        web.issues.any((i) => i.code == TermiusIssueCode.sshParserFinding),
        isTrue,
      );
      expect(web.blocked, isFalse);
      final db = document.rows.firstWhere((row) => row.label == 'db');
      expect(_codes(db.issues), [
        TermiusIssueCode.sshOptionIgnored,
        TermiusIssueCode.sshHostKeyPolicyIgnored,
        TermiusIssueCode.sshForwardBlocked,
      ]);
      expect(db.forwards.map((f) => f.type), [
        SshPortForwardType.local,
        SshPortForwardType.dynamic,
      ]);
      expect(db.forwards.first.bindAddress, '127.0.0.1');
      expect(db.forwards.first.destinationPort, 5432);
      final plan = TermiusImportPlanner.plan(document, _empty(), newId: _id);
      expect(plan.createCount, 2);
      final dbHost = plan.hostsToCreate.firstWhere((h) => h.name == 'db');
      final webHost = plan.hostsToCreate.firstWhere((h) => h.name == 'web');
      expect(dbHost.jumpHostId, webHost.id);
      expect(dbHost.portForwardProfiles, hasLength(2));
      expect(dbHost.validate(), isNull);
    });

    test('command directives and includes stay blocked; nothing executes', () {
      final proxy = TermiusOpenSshImporter.parse(
        'Host a\n  HostName a.example\n  User u\n  ProxyCommand nc %h %p\n',
      );
      expect(proxy.rows.single.blocked, isTrue);
      final include = TermiusOpenSshImporter.parse('Include ~/.ssh/other\n');
      expect(include.blocksWholeFile, isTrue);
      final jumpMissing = TermiusOpenSshImporter.parse(
        'Host a\n  HostName a.example\n  User u\n  ProxyJump nowhere\n',
      );
      final plan = TermiusImportPlanner.plan(jumpMissing, _empty(), newId: _id);
      expect(plan.createCount, 0);
      expect(_codes(plan.rows.single.issues), contains(TermiusIssueCode.sshJumpMissing));
    });
  });
}
