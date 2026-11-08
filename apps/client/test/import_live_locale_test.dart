import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/ansible_inventory_import.dart';
import 'package:aterm_client/import/ansible_inventory_refresh.dart';
import 'package:aterm_client/import/openssh_config_import.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugCurrentL10n = appLocalizationsFor(const Locale('en')));
  tearDown(() => debugCurrentL10n = appLocalizationsFor(const Locale('en')));

  test('stored parser findings reformat without reparsing or leaking source values', () {
    const secret = 'DO_NOT_SHOW_IMPORT_SECRET';
    final inventory = AnsibleInventoryImporter.parse('''
[web]
node ansible_user=deploy ansible_password=$secret ansible_connection=winrm
''');
    final ssh = OpenSshConfigImporter.parse('''
Include /private/$secret
Host target
  User deploy
  IdentityFile /private/$secret
  Port invalid
''');
    final findings = [
      ...inventory.issues,
      ...inventory.hosts.expand((host) => host.issues),
    ];
    expect(
      findings.any((issue) => issue.code == 'unsupported_connection'),
      isTrue,
    );
    expect(ssh.blocksWholeFile, isTrue);
    final issueSnapshot = ssh.issues
        .map((issue) => (issue.line, issue.directive, issue.blocking))
        .toList();
    for (final code in ['en', 'zh', 'ja', 'ru']) {
      final l10n = appLocalizationsFor(Locale(code));
      debugCurrentL10n = l10n;
      expect(
        findings
            .firstWhere((issue) => issue.code == 'unsupported_connection')
            .message,
        l10n.inventoryUnsupportedConnection,
      );
      expect(ssh.issues.first.message, l10n.sshImportInclude);
      expect(
        ssh.hosts.single.issues
            .firstWhere((issue) => issue.directive == 'Port')
            .message,
        l10n.thisValueIsInvalidOrUnsupported,
      );
      expect(
        ssh.issues
            .map((issue) => (issue.line, issue.directive, issue.blocking))
            .toList(),
        issueSnapshot,
      );
      expect(
        [
          ...findings.map((issue) => issue.message),
          ...ssh.issues.map((issue) => issue.message),
          ...ssh.hosts
              .expand((host) => host.issues)
              .map((issue) => issue.message),
        ].join(' '),
        isNot(contains(secret)),
      );
    }
  });

  test('stored refresh notes, reasons and conflict labels follow locale without replanning', () {
    final parsed = AnsibleInventoryImporter.parse(
      '[web]\nnode ansible_user=deploy',
    );
    final created = planAnsibleInventoryRefresh(
      parsed: parsed,
      savedHosts: [],
      sourceId: '11111111-1111-4111-8111-111111111111',
      sourceLabel: 'User label',
      createHostId: () => '22222222-2222-4222-8222-222222222222',
    );
    final saved = created.rows.single.plannedHost!.copyWith(
      revisionId: '33333333-3333-4333-8333-333333333333',
      address: 'manual.example',
    );
    final updated = planAnsibleInventoryRefresh(
      parsed: AnsibleInventoryImporter.parse(
        '[web]\nnode ansible_user=deploy ansible_host=new.example',
      ),
      savedHosts: [saved],
      sourceId: '11111111-1111-4111-8111-111111111111',
      sourceLabel: 'User label',
    );
    final conflict = updated.rows.single;
    expect(conflict.hasConflict, isTrue);
    final resolved = updated.resolveConflicts(
      useInventoryFieldsByHostId: {
        '22222222-2222-4222-8222-222222222222': {'address'},
      },
    );
    final payload = jsonEncode(resolved.rows.single.plannedHost!.toJson());
    final skipped = planAnsibleInventoryRefresh(
      parsed: parsed,
      savedHosts: [
        const HostRecord(
          id: '44444444-4444-4444-8444-444444444444',
          name: 'node',
          address: 'other.example',
          username: 'user',
          port: 22,
        ),
      ],
      sourceId: '11111111-1111-4111-8111-111111111111',
      sourceLabel: 'User label',
    );
    final empty = planAnsibleInventoryRefresh(
      parsed: AnsibleInventoryImporter.parse(''),
      savedHosts: [],
      sourceId: '11111111-1111-4111-8111-111111111111',
      sourceLabel: 'User label',
    );
    for (final code in ['en', 'zh', 'ja', 'ru']) {
      final l10n = appLocalizationsFor(Locale(code));
      debugCurrentL10n = l10n;
      expect(skipped.rows.single.note, l10n.inventoryKeepOtherSource);
      expect(empty.staleMarkingReason, l10n.inventoryEmptySource);
      expect(
        empty.resolveConflicts().staleMarkingReason,
        l10n.inventoryEmptySource,
      );
      expect(
        conflict.fields.firstWhere((field) => field.key == 'address').label,
        l10n.address,
      );
      expect(
        resolved.rows.single.fields
            .firstWhere((field) => field.key == 'address')
            .label,
        l10n.address,
      );
      expect(jsonEncode(resolved.rows.single.plannedHost!.toJson()), payload);
      expect(resolved.rows.single.plannedHost!.address, 'new.example');
      expect(resolved.sourceLabel, 'User label');
    }
  });
}
