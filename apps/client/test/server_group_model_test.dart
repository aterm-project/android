import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _revision = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _credentialId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Map<String, dynamic> _validGroup() => {
  'id': _id,
  'type': 'group',
  'name': 'Operations',
  'color': 0x4fc3f7,
  'parent_id': null,
};

void main() {
  test('decodes strict Group payload and repository metadata', () {
    final group = GroupRecord.fromJson({
      ..._validGroup(),
      '_record_id': _id,
      '_revision_id': _revision,
      '_manifest': {'source': 'server'},
    });

    expect(group.id, _id);
    expect(group.name, 'Operations');
    expect(group.color, 0x4fc3f7);
    expect(group.parentId, isNull);
    expect(group.toJson(), containsPair('_manifest', {'source': 'server'}));
    expect(group.toJson(), isNot(contains('_record_id')));
    expect(group.toJson(), isNot(contains('_revision_id')));
  });

  test('old Group JSON defaults to no inherited credential', () {
    final group = GroupRecord.fromJson(_validGroup());

    expect(group.defaultCredentialId, isNull);
    expect(group.toJson().containsKey('default_credential_id'), isFalse);
  });

  test('round-trips a valid Group default credential', () {
    final group = GroupRecord.fromJson({
      ..._validGroup(),
      'default_credential_id': _credentialId,
    });

    expect(group.defaultCredentialId, _credentialId);
    expect(group.toJson()['default_credential_id'], _credentialId);
  });

  test('rejects malformed Group schema with FormatException', () {
    final malformed = <Map<String, dynamic>>[
      {..._validGroup(), 'id': 'not-a-uuid'},
      {..._validGroup(), 'type': 'host'},
      {..._validGroup(), 'name': 42},
      {..._validGroup(), 'name': '  '},
      {..._validGroup(), 'color': 1.5},
      {..._validGroup(), 'color': -1},
      {..._validGroup(), 'parent_id': 'bad-parent'},
      {..._validGroup(), '_record_id': _revision},
      {..._validGroup(), '_revision_id': 'bad-revision'},
      {..._validGroup(), 'default_credential_id': 'bad-credential'},
      {..._validGroup(), '_manifest': 'not-an-object'},
      {..._validGroup(), 'unexpected': true},
    ];

    for (final row in malformed) {
      expect(() => GroupRecord.fromJson(row), throwsA(isA<FormatException>()));
    }
  });
}
