import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/vault_preference.dart';

void main() {
  const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const revisionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  group('VaultPreferenceRecord', () {
    test('creates the supported workspace default section payload', () {
      final record = VaultPreferenceRecord.defaultWorkspaceSection(
        id: id,
        value: 'snippets',
      );

      expect(record.id, id);
      expect(record.scope, 'workspace');
      expect(record.key, 'defaultSection');
      expect(record.value, 'snippets');
      expect(record.platformFamily, 'all');
      expect(record.revisionId, isNull);
      expect(record.toJson(), {
        'id': id,
        'type': 'preference',
        'scope': 'workspace',
        'key': 'defaultSection',
        'value': 'snippets',
        'platform_family': 'all',
      });
      expect(record.toJson().keys, isNot(contains('_revision_id')));
      expect(record.toJson().keys, isNot(contains('_record_id')));
      expect(record.toJson().keys, isNot(contains('_manifest')));
    });

    test('generates a UUIDv4 and accepts every supported value', () {
      for (final value in VaultPreferenceRecord.supportedDefaultSectionValues) {
        final record = VaultPreferenceRecord.defaultWorkspaceSection(
          value: value,
        );
        expect(record.id, matches(_uuidV4));
        expect(record.value, value);
        expect(
          VaultPreferenceRecord.isSupportedDefaultSectionValue(value),
          isTrue,
        );
      }
      expect(
        VaultPreferenceRecord.isSupportedDefaultSectionValue('preferences'),
        isFalse,
      );
    });

    test('creates and decodes a supported terminal font-size preference', () {
      for (final fontSize in VaultPreferenceRecord.supportedTerminalFontSizes) {
        final record = VaultPreferenceRecord.terminalFontSize(
          id: id,
          fontSize: fontSize,
        );
        expect(record.id, id);
        expect(record.isTerminalFontSize, isTrue);
        expect(record.terminalFontSizeValue, fontSize);
        expect(record.toJson(), {
          'id': id,
          'type': 'preference',
          'scope': 'workspace',
          'key': 'terminalFontSize',
          'value': '$fontSize',
          'platform_family': 'all',
        });

        final decoded = VaultPreferenceRecord.fromJson(record.toJson());
        expect(decoded, isA<VaultPreferenceRecord>());
        expect(decoded.terminalFontSizeValue, fontSize);
      }
      expect(
        () => VaultPreferenceRecord.terminalFontSize(fontSize: 15),
        throwsA(isA<FormatException>()),
      );
    });

    test('creates and decodes only the allowlisted terminal themes', () {
      for (final theme in VaultTerminalThemeChoice.values) {
        final record = VaultPreferenceRecord.terminalTheme(
          id: id,
          theme: theme,
        );
        expect(record.isTerminalTheme, isTrue);
        expect(record.terminalThemeValue, theme);
        expect(record.toJson(), {
          'id': id,
          'type': 'preference',
          'scope': 'workspace',
          'key': 'terminalTheme',
          'value': theme.value,
          'platform_family': 'all',
        });
        expect(
          VaultPreferenceRecord.fromJson(record.toJson()).terminalThemeValue,
          theme,
        );
      }
      expect(
        VaultPreferenceRecord.defaultTerminalTheme,
        VaultTerminalThemeChoice.atermDark,
      );
      expect(
        () => VaultTerminalThemeChoice.fromValue('custom-css'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => VaultPreferenceRecord.fromJson({
          ..._payload(),
          'key': 'terminalTheme',
          'value': 'custom-css',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('round trips strict versioned semantic terminal shortcuts', () {
      final bindings = TerminalShortcutBindings.fromBindings({
        TerminalShortcutAction.search: 'Shift+Mod+E',
        TerminalShortcutAction.searchNext: 'MOD+ALT+G',
        TerminalShortcutAction.searchPrevious: 'Shift+mod+alt+g',
        TerminalShortcutAction.disconnect: 'MOD+ALT+SHIFT+D',
      });
      expect(bindings.chordFor(TerminalShortcutAction.search), 'mod+shift+e');
      expect(bindings.chordFor(TerminalShortcutAction.searchNext), 'mod+alt+g');

      final record = VaultPreferenceRecord.terminalShortcuts(
        id: id,
        bindings: bindings,
      );
      expect(record.isTerminalShortcuts, isTrue);
      expect(record.terminalShortcutBindings, bindings);
      expect(record.toJson(), {
        'id': id,
        'type': 'preference',
        'scope': 'workspace',
        'key': 'terminalShortcuts',
        'value': bindings.toValue(),
        'platform_family': 'all',
      });
      expect(
        VaultPreferenceRecord.fromJson(
          record.toJson(),
        ).terminalShortcutBindings,
        bindings,
      );
      expect(
        VaultPreferenceRecord.defaultTerminalShortcuts.toValue(),
        isNotEmpty,
      );
    });

    test('rejects unknown actions, duplicate and invalid chords', () {
      const defaults = TerminalShortcutBindings.defaultValues;
      expect(
        () => TerminalShortcutBindings.fromBindings({
          ...defaults,
          TerminalShortcutAction.searchNext:
              defaults[TerminalShortcutAction.search]!,
        }),
        throwsA(isA<FormatException>()),
      );
      for (final chord in [
        'f',
        'shift+f',
        'ctrl+f',
        'mod+ctrl+f',
        'mod+shift+unknown',
        'mod+mod+f',
        'mod+f+g',
        'mod+shift+f+g',
      ]) {
        expect(
          () => TerminalShortcutBindings.normalizeChord(chord),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid shortcut chord to be rejected: $chord',
        );
      }
      for (final chord in [
        'mod+w',
        'mod+q',
        'mod+r',
        'mod+t',
        'mod+l',
        'mod+f',
        'mod+shift+j',
        'mod+shift+i',
        'mod+alt+c',
        'alt+f4',
        'mod+f12',
      ]) {
        expect(
          () => TerminalShortcutBindings.normalizeChord(chord),
          throwsA(isA<FormatException>()),
          reason: 'Expected reserved shortcut chord to be rejected: $chord',
        );
      }
      final unknownAction = jsonEncode({
        'version': TerminalShortcutBindings.version,
        'bindings': {
          ...{
            for (final action in TerminalShortcutAction.values)
              action.id: defaults[action],
          },
          'terminal.execute': 'mod+e',
        }..remove(TerminalShortcutAction.search.id),
      });
      expect(
        () => TerminalShortcutBindings.fromValue(unknownAction),
        throwsA(isA<FormatException>()),
      );
    });

    test('strictly decodes canonical shortcut values and record tuple', () {
      final defaultValue = TerminalShortcutBindings.defaults.toValue();
      final validPayload = {
        ..._payload(),
        'key': 'terminalShortcuts',
        'value': defaultValue,
      };
      expect(
        VaultPreferenceRecord.fromJson(validPayload).terminalShortcutBindings,
        TerminalShortcutBindings.defaults,
      );
      final invalidValues = [
        '{broken',
        jsonEncode({
          'version': 2,
          'bindings': jsonDecode(defaultValue)['bindings'],
        }),
        jsonEncode({
          'version': 1,
          'bindings': {'terminal.search': 'mod+f'},
        }),
        jsonEncode({
          'version': 1,
          'bindings': {
            for (final action in TerminalShortcutAction.values)
              action.id: 'mod+f',
          },
        }),
        jsonEncode({
          'version': 1,
          'bindings': {
            for (final action in TerminalShortcutAction.values)
              action.id: defaultValue == '' ? 'mod+f' : 'MOD+F',
          },
        }),
        '$defaultValue ',
      ];
      for (final value in invalidValues) {
        expect(
          () =>
              VaultPreferenceRecord.fromJson({...validPayload, 'value': value}),
          throwsA(isA<FormatException>()),
          reason: 'Expected malformed shortcut payload to fail: $value',
        );
      }
    });

    test('copyWith retains and validates the terminal-theme tuple', () {
      final record = VaultPreferenceRecord.terminalTheme(
        id: id,
        theme: VaultTerminalThemeChoice.atermDark,
      ).copyWith(revisionId: revisionId);
      final changed = record.copyWith(value: 'light');
      expect(changed.id, id);
      expect(changed.key, 'terminalTheme');
      expect(changed.terminalThemeValue, VaultTerminalThemeChoice.light);
      expect(changed.revisionId, revisionId);
      expect(
        () => record.copyWith(value: 'custom-css'),
        throwsA(isA<FormatException>()),
      );
    });

    test('keeps default-section wire shape and tuple validation strict', () {
      expect(
        VaultPreferenceRecord.defaultWorkspaceSection(
          id: id,
          value: 'groups',
        ).toJson(),
        _payload(value: 'groups'),
      );

      final invalid = <Map<String, dynamic>>[
        {..._payload(), 'key': 'terminalFontSize', 'value': '15'},
        {..._payload(), 'key': 'terminalFontSize', 'value': '013'},
        {..._payload(), 'key': 'terminalFontSize', 'scope': 'terminal'},
        {..._payload(), 'key': 'terminalFontSize', 'platform_family': 'linux'},
        {..._payload(), 'key': 'unknownPreference'},
        {..._payload(), 'key': 'defaultSection', 'value': '13'},
      ];
      for (final json in invalid) {
        expect(
          () => VaultPreferenceRecord.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid preference payload to be rejected: $json',
        );
      }
    });

    test('copyWith retains the font-size tuple and validates its value', () {
      final record = VaultPreferenceRecord.terminalFontSize(
        id: id,
        fontSize: 13,
      ).copyWith(revisionId: revisionId);
      final changed = record.copyWith(value: '16');
      expect(changed.id, id);
      expect(changed.key, 'terminalFontSize');
      expect(changed.terminalFontSizeValue, 16);
      expect(changed.revisionId, revisionId);
      expect(
        () => record.copyWith(value: '15'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodes repository metadata but never serializes it', () {
      final manifest = {'object_refs': <Object?>[], 'extension_version': 1};
      final record = VaultPreferenceRecord.fromJson({
        ..._payload(value: 'groups'),
        '_record_id': id,
        '_revision_id': revisionId,
        '_manifest': manifest,
      });

      expect(record.revisionId, revisionId);
      expect(record.value, 'groups');
      expect(record.toJson(), _payload(value: 'groups'));
    });

    test(
      'copyWith preserves ID and tuple while validating value and revision',
      () {
        final original = VaultPreferenceRecord.defaultWorkspaceSection(
          id: id,
          value: 'hosts',
        ).copyWith(revisionId: revisionId);
        final changed = original.copyWith(value: 'credentials');

        expect(changed.id, id);
        expect(changed.scope, 'workspace');
        expect(changed.key, 'defaultSection');
        expect(changed.platformFamily, 'all');
        expect(changed.value, 'credentials');
        expect(changed.revisionId, revisionId);
        expect(
          () => original.copyWith(value: 'preferences'),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => original.copyWith(revisionId: 'not-a-uuid'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'rejects incomplete, extra, wrong-version, and wrong-type payloads',
      () {
        final invalid = <Map<String, dynamic>>[
          {..._payload()..remove('key')},
          {..._payload(), 'unknown': 'field'},
          {..._payload(), 'type': 'host'},
          {..._payload(), 'scope': 'device'},
          {..._payload(), 'key': 'theme'},
          {..._payload(), 'platform_family': 'linux'},
          {..._payload(), 'value': 'preferences'},
          {..._payload(), 'value': null},
        ];

        for (final json in invalid) {
          expect(
            () => VaultPreferenceRecord.fromJson(json),
            throwsA(isA<FormatException>()),
            reason: 'Expected invalid payload to be rejected: $json',
          );
        }
      },
    );

    test('requires canonical UUIDv4 IDs and valid repository revisions', () {
      final invalid = <Map<String, dynamic>>[
        {..._payload(), 'id': 'preference-1'},
        {..._payload(), 'id': id.toUpperCase()},
        {..._payload(), '_record_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        {..._payload(), '_record_id': 'bad-id'},
        {..._payload(), '_revision_id': 'bad-revision'},
        {..._payload(), '_revision_id': 17},
      ];

      for (final json in invalid) {
        expect(
          () => VaultPreferenceRecord.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid UUID metadata to be rejected: $json',
        );
      }
      expect(
        () => VaultPreferenceRecord.defaultWorkspaceSection(
          id: 'bad-id',
          value: 'hosts',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('validates optional manifest metadata when present', () {
      expect(
        () => VaultPreferenceRecord.fromJson({
          ..._payload(),
          '_manifest': 'not an object',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => VaultPreferenceRecord.fromJson({
          ..._payload(),
          '_manifest': {1: 'non-string key'},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Map<String, dynamic> _payload({String value = 'hosts'}) => {
  'id': id,
  'type': 'preference',
  'scope': 'workspace',
  'key': 'defaultSection',
  'value': value,
  'platform_family': 'all',
};

const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _uuidV4 =
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
