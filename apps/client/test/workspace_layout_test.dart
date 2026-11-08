import 'dart:convert';

import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:flutter_test/flutter_test.dart';

const _workspaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _workspaceId2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _revisionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _paneA = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _paneB = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _paneC = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const _paneD = '99999999-9999-4999-8999-999999999999';
const _hostA = '11111111-1111-4111-8111-111111111111';
const _hostB = '22222222-2222-4222-8222-222222222222';
const _hostC = '33333333-3333-4333-8333-333333333333';
const _hostD = '44444444-4444-4444-8444-444444444444';
const _tmuxNameA = 'atermius_0123456789abcdef0123456789abcdef';
const _tmuxNameB = 'atermius_abcdef0123456789abcdef0123456789';

void main() {
  group('WorkspaceRecord', () {
    test('builds the strict v1 terminal-tabs payload from Host IDs', () {
      final record = WorkspaceRecord.fromHostIds(
        id: _workspaceId,
        name: '  Release workspace  ',
        hostIds: const [_hostB, _hostA, _hostB],
        activeIndex: 1,
        paneIds: const [_paneA, _paneB, 'ffffffff-ffff-4fff-8fff-ffffffffffff'],
      );

      expect(record.name, 'Release workspace');
      expect(record.layoutKind, WorkspaceLayoutKind.terminalTabs);
      expect(record.splitAxis, isNull);
      expect(record.splitRatioBasisPoints, isNull);
      expect(record.activeIndex, 1);
      expect(record.activePaneId, _paneB);
      expect(record.hostIds, const [_hostB, _hostA, _hostB]);
      expect(record.hostRefs, const [_hostA, _hostB]);
      expect(record.toJson(), {
        'schema_version': workspaceLayoutSchemaVersion,
        'id': _workspaceId,
        'type': 'workspace',
        'name': 'Release workspace',
        'layout_tree': {
          'kind': 'terminal_tabs',
          'active_pane_id': _paneB,
          'panes': const [
            {'kind': 'terminal', 'pane_id': _paneA, 'host_id': _hostB},
            {'kind': 'terminal', 'pane_id': _paneB, 'host_id': _hostA},
            {
              'kind': 'terminal',
              'pane_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
              'host_id': _hostB,
            },
          ],
        },
        'host_refs': const [_hostA, _hostB],
      });
    });

    test('generates UUIDv4 IDs and enforces active-index bounds', () {
      final record = WorkspaceRecord.fromHostIds(
        name: 'Terminal',
        hostIds: const [_hostA],
      );
      expect(record.id, matches(_uuidV4));
      expect(record.panes.single.paneId, matches(_uuidV4));
      expect(record.activeIndex, 0);
      expect(
        () => WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Terminal',
          hostIds: const [_hostA],
          activeIndex: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'round-trips canonical JSON and accepts validated repository metadata',
      () {
        final payload = WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Workspace',
          hostIds: const [_hostB, _hostA],
          activeIndex: 1,
          paneIds: const [_paneA, _paneB],
          revisionId: _revisionId,
          manifest: const {
            'object_refs': [_hostA, _hostB],
            'extension_version': 1,
          },
        ).toJson();
        final decoded = WorkspaceRecord.fromJson({
          ...Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map),
          '_record_id': _workspaceId,
          '_revision_id': _revisionId,
        });

        expect(decoded.id, _workspaceId);
        expect(decoded.revisionId, _revisionId);
        expect(decoded.toJson(), payload);
        expect(jsonEncode(decoded.toJson()), jsonEncode(payload));
      },
    );

    test('keeps v1 tab payloads readable and serialized as v1', () {
      final decoded = WorkspaceRecord.fromJson(_payload());

      expect(decoded.layoutKind, WorkspaceLayoutKind.terminalTabs);
      expect(decoded.splitAxis, isNull);
      expect(decoded.splitRatioBasisPoints, isNull);
      expect(decoded.toJson(), _payload());
      expect(decoded.toJson()['schema_version'], workspaceLayoutSchemaVersion);
    });

    test('builds and round-trips strict v2 two-pane split payloads', () {
      final record = WorkspaceRecord.fromSplitHostIds(
        id: _workspaceId,
        name: '  Split workspace  ',
        hostIds: const [_hostB, _hostA],
        axis: WorkspaceSplitAxis.horizontal,
        splitRatioBasisPoints: 6250,
        activeIndex: 1,
        paneIds: const [_paneA, _paneB],
        revisionId: _revisionId,
        manifest: const {
          'object_refs': [_hostA, _hostB],
          'extension_version': 1,
        },
      );
      final payload = record.toJson();
      final decoded = WorkspaceRecord.fromJson({
        ...Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map),
        '_record_id': _workspaceId,
        '_revision_id': _revisionId,
      });

      expect(record.name, 'Split workspace');
      expect(record.layoutKind, WorkspaceLayoutKind.split);
      expect(record.splitAxis, WorkspaceSplitAxis.horizontal);
      expect(record.splitRatioBasisPoints, 6250);
      expect(record.hostIds, const [_hostB, _hostA]);
      expect(record.activePaneId, _paneB);
      expect(payload, {
        'schema_version': workspaceSplitLayoutSchemaVersion,
        'id': _workspaceId,
        'type': 'workspace',
        'name': 'Split workspace',
        'layout_tree': {
          'kind': 'split',
          'axis': 'horizontal',
          'split_ratio_basis_points': 6250,
          'active_pane_id': _paneB,
          'panes': const [
            {'kind': 'terminal', 'pane_id': _paneA, 'host_id': _hostB},
            {'kind': 'terminal', 'pane_id': _paneB, 'host_id': _hostA},
          ],
        },
        'host_refs': const [_hostA, _hostB],
        '_manifest': const {
          'object_refs': [_hostA, _hostB],
          'extension_version': 1,
        },
      });
      expect(decoded.layoutKind, WorkspaceLayoutKind.split);
      expect(decoded.splitAxis, WorkspaceSplitAxis.horizontal);
      expect(decoded.splitRatioBasisPoints, 6250);
      expect(decoded.revisionId, _revisionId);
      expect(decoded.toJson(), payload);
      expect(jsonEncode(decoded.toJson()), jsonEncode(payload));
    });

    test('builds and round-trips a mixed recursive v3 split tree', () {
      final tree = WorkspaceSplitNode(
        axis: WorkspaceSplitAxis.horizontal,
        splitRatioBasisPoints: 6000,
        first: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.vertical,
          splitRatioBasisPoints: 4000,
          first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
          second: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
        ),
        second: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.vertical,
          splitRatioBasisPoints: 5500,
          first: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
          second: WorkspaceTerminalNode(paneId: _paneD, hostId: _hostD),
        ),
      );
      final record = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Nested workspace',
        layoutTree: tree,
        activePaneId: _paneC,
        revisionId: _revisionId,
      );
      final payload = record.toJson();
      final decoded = WorkspaceRecord.fromJson({
        ...Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map),
        '_record_id': _workspaceId,
        '_revision_id': _revisionId,
      });

      expect(record.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
      expect(record.panes.map((pane) => pane.paneId), [
        _paneA,
        _paneB,
        _paneC,
        _paneD,
      ]);
      expect(record.hostIds, const [_hostA, _hostB, _hostC, _hostD]);
      expect(record.hostRefs, const [_hostA, _hostB, _hostC, _hostD]);
      expect(record.activePaneId, _paneC);
      expect(record.splitAxis, WorkspaceSplitAxis.horizontal);
      expect(record.splitRatioBasisPoints, 6000);
      expect(payload['layout_tree'], {
        'kind': 'split',
        'axis': 'horizontal',
        'split_ratio_basis_points': 6000,
        'active_pane_id': _paneC,
        'panes': [
          {
            'kind': 'split',
            'axis': 'vertical',
            'split_ratio_basis_points': 4000,
            'panes': [
              {'kind': 'terminal', 'pane_id': _paneA, 'host_id': _hostA},
              {'kind': 'terminal', 'pane_id': _paneB, 'host_id': _hostB},
            ],
          },
          {
            'kind': 'split',
            'axis': 'vertical',
            'split_ratio_basis_points': 5500,
            'panes': [
              {'kind': 'terminal', 'pane_id': _paneC, 'host_id': _hostC},
              {'kind': 'terminal', 'pane_id': _paneD, 'host_id': _hostD},
            ],
          },
        ],
      });
      expect(decoded.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
      expect(decoded.layoutTree, isA<WorkspaceSplitNode>());
      expect(decoded.revisionId, _revisionId);
      expect(decoded.toJson(), payload);
      expect(jsonEncode(decoded.toJson()), jsonEncode(payload));
    });

    test(
      'stores pane-bound tmux descriptors in the versioned manifest namespace',
      () {
        final v1 = WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Tabs',
          hostIds: const [_hostA, _hostB],
          paneIds: const [_paneA, _paneB],
          manifest: const {'custom_extension': 'keep'},
        );
        final v2 = WorkspaceRecord.fromSplitHostIds(
          id: _workspaceId,
          name: 'Split',
          hostIds: const [_hostA, _hostB],
          paneIds: const [_paneA, _paneB],
          axis: WorkspaceSplitAxis.horizontal,
        );
        final v3 = WorkspaceRecord.fromSplitTree(
          id: _workspaceId,
          name: 'Nested',
          layoutTree: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.horizontal,
            splitRatioBasisPoints: 5000,
            first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
            second: WorkspaceSplitNode(
              axis: WorkspaceSplitAxis.vertical,
              splitRatioBasisPoints: 4500,
              first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
              second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
            ),
          ),
          activePaneId: _paneB,
        );

        for (final record in [v1, v2, v3]) {
          final legacyPayload = record.toJson();
          final withSession = record.withSessionDescriptor(
            WorkspaceSessionDescriptor(
              paneId: record.panes.first.paneId,
              hostId: record.panes.first.hostId,
              tmuxSessionName: _tmuxNameA,
            ),
          );
          final payload = withSession.toJson();
          final encodedManifest = payload['_manifest'] as Map;
          final storedDescriptors =
              encodedManifest[workspaceSessionDescriptorsManifestKey] as List;

          expect(withSession.schemaVersion, record.schemaVersion);
          expect(payload['schema_version'], legacyPayload['schema_version']);
          expect(payload['layout_tree'], legacyPayload['layout_tree']);
          expect(payload['host_refs'], legacyPayload['host_refs']);
          expect(payload.containsKey('session_descriptors'), isFalse);
          expect(storedDescriptors, [
            {
              'pane_id': record.panes.first.paneId,
              'host_id': record.panes.first.hostId,
              'tmux_session_name': _tmuxNameA,
            },
          ]);

          final decoded = WorkspaceRecord.fromJson(payload);
          expect(decoded.schemaVersion, record.schemaVersion);
          expect(
            decoded.sessionDescriptors.single.paneId,
            record.panes.first.paneId,
          );
          expect(jsonEncode(decoded.toJson()), jsonEncode(payload));
        }

        final generated = WorkspaceSessionDescriptor.createForPane(
          paneId: _paneA,
          hostId: _hostA,
        );
        expect(
          generated.tmuxSessionName,
          matches(RegExp(r'^atermius_[0-9a-f]{32}$')),
        );
      },
    );

    test('rejects malformed tmux descriptors and drops stale pane bindings', () {
      final base = WorkspaceRecord.fromHostIds(
        id: _workspaceId,
        name: 'Workspace',
        hostIds: const [_hostA, _hostB],
        paneIds: const [_paneA, _paneB],
      ).toJson();
      final validA = {
        'pane_id': _paneA,
        'host_id': _hostA,
        'tmux_session_name': _tmuxNameA,
      };
      final validB = {
        'pane_id': _paneB,
        'host_id': _hostB,
        'tmux_session_name': _tmuxNameB,
      };
      final invalidManifests = <Object?>[
        'not-a-list',
        [
          {...validA, 'future': true},
        ],
        [
          {...validA, 'pane_id': 'bad-pane-id'},
        ],
        [
          {...validA, 'host_id': 'bad-host-id'},
        ],
        [
          {...validA, 'tmux_session_name': 'existing-user-session'},
        ],
        [
          {...validA, 'tmux_session_name': 'atermius_${'A' * 32}'},
        ],
        [validA, validA],
        [
          validA,
          {...validB, 'host_id': _hostA, 'tmux_session_name': _tmuxNameA},
        ],
        List<Map<String, String>>.generate(
          maxWorkspacePanes + 1,
          (index) => {
            'pane_id':
                '70000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            'host_id': _hostA,
            'tmux_session_name':
                'atermius_${index.toRadixString(16).padLeft(32, '0')}',
          },
        ),
      ];
      for (final descriptors in invalidManifests) {
        expect(
          () => WorkspaceRecord.fromJson({
            ...base,
            '_manifest': {workspaceSessionDescriptorsManifestKey: descriptors},
          }),
          throwsA(isA<FormatException>()),
          reason:
              'Expected invalid descriptor data to be rejected: $descriptors',
        );
      }

      final staleAndValid = WorkspaceRecord.fromJson({
        ...base,
        '_manifest': {
          'custom_extension': 'keep',
          workspaceSessionDescriptorsManifestKey: [
            {...validA, 'host_id': _hostB}, // pane exists, Host changed
            {...validA, 'pane_id': _paneC}, // pane was removed
            validB,
          ],
        },
      });
      expect(staleAndValid.sessionDescriptors.map((item) => item.paneId), [
        _paneB,
      ]);
      final cleanedManifest = staleAndValid.toJson()['_manifest'] as Map;
      expect(cleanedManifest['custom_extension'], 'keep');
      expect(cleanedManifest[workspaceSessionDescriptorsManifestKey], [validB]);
    });

    test(
      'rename retains descriptors while Host replacement clears the pane',
      () {
        final original = WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Workspace',
          hostIds: const [_hostA, _hostB],
          paneIds: const [_paneA, _paneB],
          sessionDescriptors: [
            WorkspaceSessionDescriptor(
              paneId: _paneA,
              hostId: _hostA,
              tmuxSessionName: _tmuxNameA,
            ),
            WorkspaceSessionDescriptor(
              paneId: _paneB,
              hostId: _hostB,
              tmuxSessionName: _tmuxNameB,
            ),
          ],
          manifest: const {
            'object_refs': [_hostA, _hostB],
          },
        );

        final renamed = original.copyWith(name: 'Renamed');
        expect(renamed.sessionDescriptors, hasLength(2));
        expect(renamed.manifest!['object_refs'], const [_hostA, _hostB]);

        final hostChanged = renamed.copyWith(hostIds: const [_hostC, _hostB]);
        expect(hostChanged.panes.first.paneId, _paneA);
        expect(hostChanged.panes.first.hostId, _hostC);
        expect(hostChanged.sessionDescriptors.map((item) => item.paneId), [
          _paneB,
        ]);
        expect(
          (hostChanged.manifest![workspaceSessionDescriptorsManifestKey]
                  as List)
              .single['pane_id'],
          _paneB,
        );
      },
    );

    test('duplicate drops tmux refs and pane removal cleans dangling refs', () {
      final original = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Workspace',
        layoutTree: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 5000,
          first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
          second: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.vertical,
            splitRatioBasisPoints: 5000,
            first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
            second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
          ),
        ),
        activePaneId: _paneA,
        sessionDescriptors: [
          WorkspaceSessionDescriptor(
            paneId: _paneA,
            hostId: _hostA,
            tmuxSessionName: _tmuxNameA,
          ),
          WorkspaceSessionDescriptor(
            paneId: _paneB,
            hostId: _hostB,
            tmuxSessionName: _tmuxNameB,
          ),
          WorkspaceSessionDescriptor(
            paneId: _paneC,
            hostId: _hostC,
            tmuxSessionName: 'atermius_00112233445566778899aabbccddeeff',
          ),
        ],
        manifest: const {'custom_extension': 'keep'},
      );

      final duplicate = original.duplicateWithNewIdentity(name: 'Duplicate');
      expect(duplicate.sessionDescriptors, isEmpty);
      expect(duplicate.manifest, const {'custom_extension': 'keep'});
      expect(
        duplicate.panes.map((pane) => pane.paneId),
        everyElement(isNot(anyOf(_paneA, _paneB, _paneC))),
      );

      final removed = original.withoutPane(_paneB);
      expect(removed.panes.map((pane) => pane.paneId), [_paneA, _paneC]);
      expect(removed.sessionDescriptors.map((item) => item.paneId), [
        _paneA,
        _paneC,
      ]);
      expect(
        (removed.manifest![workspaceSessionDescriptorsManifestKey] as List).map(
          (entry) => (entry as Map)['pane_id'],
        ),
        [_paneA, _paneC],
      );
    });

    test('nested Host repair keeps tree and pane identities stable', () {
      final record = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Nested workspace',
        layoutTree: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 5000,
          first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
          second: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.vertical,
            splitRatioBasisPoints: 3500,
            first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
            second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
          ),
        ),
        activePaneId: _paneB,
      );

      final repaired = record.copyWith(
        hostIds: const [_hostD, _hostC, _hostA],
        activeIndex: 1,
      );

      expect(repaired.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
      expect(repaired.panes.map((pane) => pane.paneId), [
        _paneA,
        _paneB,
        _paneC,
      ]);
      expect(repaired.hostIds, const [_hostD, _hostC, _hostA]);
      expect(repaired.hostRefs, const [_hostA, _hostC, _hostD]);
      expect(repaired.activePaneId, _paneB);
      final root = repaired.layoutTree!;
      expect(root.first, isA<WorkspaceTerminalNode>());
      expect(root.second, isA<WorkspaceSplitNode>());
      expect(
        repaired.toJson()['schema_version'],
        workspaceNestedSplitLayoutSchemaVersion,
      );
    });

    test(
      'nested pane removal collapses splits and keeps surviving identities',
      () {
        final record = WorkspaceRecord.fromSplitTree(
          id: _workspaceId,
          name: 'Nested workspace',
          layoutTree: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.horizontal,
            splitRatioBasisPoints: 5500,
            first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
            second: WorkspaceSplitNode(
              axis: WorkspaceSplitAxis.vertical,
              splitRatioBasisPoints: 4000,
              first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
              second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
            ),
          ),
          activePaneId: _paneB,
        );

        final twoPanes = record.withoutPane(_paneB);
        expect(twoPanes.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
        expect(twoPanes.panes.map((pane) => pane.paneId), [_paneA, _paneC]);
        expect(twoPanes.activePaneId, _paneC);
        expect(twoPanes.layoutTree!.second, isA<WorkspaceTerminalNode>());
        expect(twoPanes.hostRefs, const [_hostA, _hostC]);

        final onePane = twoPanes.withoutPane(_paneA);
        expect(onePane.schemaVersion, workspaceLayoutSchemaVersion);
        expect(onePane.panes.single.paneId, _paneC);
        expect(onePane.activePaneId, _paneC);
        expect(onePane.hostRefs, const [_hostC]);
        expect(() => onePane.withoutPane(_paneC), throwsFormatException);
      },
    );

    test(
      'copyWith preserves split fields for two panes and converts to v1 tabs otherwise',
      () {
        final split = WorkspaceRecord.fromSplitHostIds(
          id: _workspaceId,
          name: 'Split',
          hostIds: const [_hostA, _hostB],
          axis: WorkspaceSplitAxis.vertical,
          splitRatioBasisPoints: 4000,
          paneIds: const [_paneA, _paneB],
        );

        final twoPaneEdit = split.copyWith(
          name: 'Updated split',
          hostIds: const [_hostB, _hostA],
          activeIndex: 1,
        );
        expect(twoPaneEdit.layoutKind, WorkspaceLayoutKind.split);
        expect(twoPaneEdit.splitAxis, WorkspaceSplitAxis.vertical);
        expect(twoPaneEdit.splitRatioBasisPoints, 4000);
        expect(twoPaneEdit.panes.map((pane) => pane.paneId), [_paneA, _paneB]);
        expect(twoPaneEdit.activePaneId, _paneB);
        expect(
          twoPaneEdit.toJson()['schema_version'],
          workspaceSplitLayoutSchemaVersion,
        );

        final onePane = split.copyWith(hostIds: const [_hostA], activeIndex: 0);
        expect(onePane.layoutKind, WorkspaceLayoutKind.terminalTabs);
        expect(onePane.splitAxis, isNull);
        expect(onePane.splitRatioBasisPoints, isNull);
        expect(
          onePane.toJson()['schema_version'],
          workspaceLayoutSchemaVersion,
        );
        expect(
          (onePane.toJson()['layout_tree'] as Map)['kind'],
          'terminal_tabs',
        );

        final threePanes = split.copyWith(
          hostIds: const [_hostA, _hostB, _hostA],
          activeIndex: 2,
        );
        expect(threePanes.layoutKind, WorkspaceLayoutKind.terminalTabs);
        expect(threePanes.panes, hasLength(3));
        expect(threePanes.splitAxis, isNull);
        expect(threePanes.splitRatioBasisPoints, isNull);
        expect(
          threePanes.toJson()['schema_version'],
          workspaceLayoutSchemaVersion,
        );
      },
    );

    test(
      'copyWith preserves identity and pane IDs while validating changes',
      () {
        final original = WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Workspace',
          hostIds: const [_hostA, _hostB],
          activeIndex: 0,
          paneIds: const [_paneA, _paneB],
          revisionId: _revisionId,
        );
        final updated = original.copyWith(
          name: '  Updated  ',
          hostIds: const [_hostB, _hostA, _hostB],
          activeIndex: 2,
        );

        expect(updated.id, _workspaceId);
        expect(updated.name, 'Updated');
        expect(updated.panes.map((pane) => pane.paneId), [
          _paneA,
          _paneB,
          isNot(_paneA),
        ]);
        expect(updated.activeIndex, 2);
        expect(updated.revisionId, _revisionId);
        expect(updated.copyWith(clearRevisionId: true).revisionId, isNull);
        expect(
          () => original.copyWith(hostIds: const [_hostA], activeIndex: 1),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('keeps pane arrays immutable and rejects invalid construction', () {
      final record = WorkspaceRecord.fromHostIds(
        id: _workspaceId,
        name: 'Workspace',
        hostIds: const [_hostA],
      );
      expect(
        () => record.panes.add(record.panes.single),
        throwsUnsupportedError,
      );
      expect(() => record.hostRefs.add(_hostB), throwsUnsupportedError);

      final invalidHostSets = <List<String>>[
        const [],
        List<String>.filled(maxWorkspacePanes + 1, _hostA),
        const ['not-a-uuid'],
      ];
      for (final hostIds in invalidHostSets) {
        expect(
          () => WorkspaceRecord.fromHostIds(
            id: _workspaceId,
            name: 'Workspace',
            hostIds: hostIds,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        () => WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: 'Workspace',
          hostIds: const [_hostA],
          paneIds: const [_paneA, _paneB],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects incomplete, unknown, or noncanonical top-level fields', () {
      final base = _payload();
      final invalid = <Map<String, dynamic>>[
        {...base}..remove('schema_version'),
        {...base, 'schema_version': 1.0},
        {...base, 'schema_version': '1'},
        {...base, 'schema_version': workspaceSplitLayoutSchemaVersion + 1},
        {...base}..remove('host_refs'),
        {...base, 'future_field': true},
        {...base, 'type': 'preference'},
        {...base, 'id': _workspaceId.toUpperCase()},
        {...base, 'id': 'legacy-id'},
        {...base, 'name': ' Workspace '},
        {...base, 'name': 'Line\nBreak'},
        {...base, 'name': 'x' * (maxWorkspaceNameUtf8Bytes + 1)},
      ];
      for (final json in invalid) {
        expect(
          () => WorkspaceRecord.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid payload to be rejected: $json',
        );
      }
      expect(
        WorkspaceRecord.fromHostIds(
          id: _workspaceId,
          name: '  Trim me  ',
          hostIds: const [_hostA],
        ).name,
        'Trim me',
      );
    });

    test('rejects invalid pane trees, IDs, active pane, and Host references', () {
      final base = _payload();
      final tree = Map<String, dynamic>.from(base['layout_tree'] as Map);
      final originalPanes = (tree['panes'] as List)
          .map((pane) => Map<String, dynamic>.from(pane as Map))
          .toList();
      final invalidTrees = <Map<String, dynamic>>[
        {...tree, 'extra': true},
        {...tree, 'kind': 'split'},
        {...tree, 'active_pane_id': _workspaceId2},
        {...tree, 'panes': const []},
        {
          ...tree,
          'panes': List<Map<String, dynamic>>.generate(
            maxWorkspacePanes + 1,
            (index) => {
              'kind': 'terminal',
              'pane_id':
                  '30000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
              'host_id': _hostA,
            },
          ),
        },
        {
          ...tree,
          'panes': [originalPanes.first, originalPanes.first],
        },
        {
          ...tree,
          'panes': [
            {...originalPanes.first, 'kind': 'sftp'},
          ],
        },
        {
          ...tree,
          'panes': [
            {...originalPanes.first, 'unknown': true},
          ],
        },
        {
          ...tree,
          'panes': [
            {...originalPanes.first, 'host_id': 'bad-host-id'},
          ],
        },
      ];
      for (final layoutTree in invalidTrees) {
        expect(
          () => WorkspaceRecord.fromJson({...base, 'layout_tree': layoutTree}),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        () =>
            WorkspaceRecord.fromJson({...base, 'layout_tree': 'not-an-object'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkspaceRecord.fromJson({
          ...base,
          'layout_tree': {...tree, 'panes': 'bad'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed schema-v2 split fields and geometry', () {
      final valid = WorkspaceRecord.fromSplitHostIds(
        id: _workspaceId,
        name: 'Split',
        hostIds: const [_hostA, _hostB],
        axis: WorkspaceSplitAxis.horizontal,
        paneIds: const [_paneA, _paneB],
      ).toJson();
      final tree = Map<String, dynamic>.from(valid['layout_tree'] as Map);
      final panes = (tree['panes'] as List).cast<Map<String, dynamic>>();
      final invalid = <Map<String, dynamic>>[
        {...valid, 'schema_version': workspaceLayoutSchemaVersion},
        {...valid, 'schema_version': 4},
        {...valid, 'future_field': true},
        {...valid, 'type': 'preference'},
        {...valid, '_extra_repository_field': true},
        {
          ...valid,
          'layout_tree': {...tree, 'unknown': true},
        },
        {
          ...valid,
          'layout_tree': {...tree}..remove('axis'),
        },
        {
          ...valid,
          'layout_tree': {...tree}..remove('split_ratio_basis_points'),
        },
        {
          ...valid,
          'layout_tree': {...tree, 'kind': 'terminal_tabs'},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'axis': 'diagonal'},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'axis': 'Horizontal'},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'split_ratio_basis_points': 2499},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'split_ratio_basis_points': 7501},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'split_ratio_basis_points': 5000.0},
        },
        {
          ...valid,
          'layout_tree': {...tree, 'split_ratio_basis_points': '5000'},
        },
        {
          ...valid,
          'layout_tree': {
            ...tree,
            'panes': [panes.first],
          },
        },
        {
          ...valid,
          'layout_tree': {
            ...tree,
            'panes': [...panes, panes.first],
          },
        },
      ];
      for (final json in invalid) {
        expect(
          () => WorkspaceRecord.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid split payload to be rejected: $json',
        );
      }
    });

    test('split factory requires two panes and bounded ratio', () {
      WorkspaceRecord build(List<String> hosts, {int ratio = 5000}) =>
          WorkspaceRecord.fromSplitHostIds(
            id: _workspaceId,
            name: 'Split',
            hostIds: hosts,
            axis: WorkspaceSplitAxis.vertical,
            splitRatioBasisPoints: ratio,
          );

      expect(build(const [_hostA, _hostB]).splitRatioBasisPoints, 5000);
      expect(
        build(const [_hostA, _hostB], ratio: 2500).splitRatioBasisPoints,
        2500,
      );
      expect(
        build(const [_hostA, _hostB], ratio: 7500).splitRatioBasisPoints,
        7500,
      );
      expect(() => build(const [_hostA]), throwsA(isA<FormatException>()));
      expect(
        () => build(const [_hostA, _hostB, _hostA]),
        throwsA(isA<FormatException>()),
      );
      for (final ratio in [2499, 7501]) {
        expect(
          () => build(const [_hostA, _hostB], ratio: ratio),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('strictly validates recursive split nodes, limits, IDs, and refs', () {
      WorkspaceLayoutNode treeForLeaves(int count, int offset) {
        if (count == 1) {
          final suffix = (offset + 1).toString().padLeft(12, '0');
          return WorkspaceTerminalNode(
            paneId: '50000000-0000-4000-8000-$suffix',
            hostId: '60000000-0000-4000-8000-$suffix',
          );
        }
        final leftCount = count ~/ 2;
        return WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 5000,
          first: treeForLeaves(leftCount, offset),
          second: treeForLeaves(count - leftCount, offset + leftCount),
        );
      }

      WorkspaceLayoutNode deepChain(int splitLevels, int offset) {
        if (splitLevels == 0) return treeForLeaves(1, offset);
        return WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.vertical,
          splitRatioBasisPoints: 5000,
          first: treeForLeaves(1, offset),
          second: deepChain(splitLevels - 1, offset + 1),
        );
      }

      Map<String, Object?> encodeNode(WorkspaceLayoutNode node) =>
          switch (node) {
            WorkspaceTerminalNode(:final paneId, :final hostId) => {
              'kind': 'terminal',
              'pane_id': paneId,
              'host_id': hostId,
            },
            WorkspaceSplitNode(
              :final axis,
              :final splitRatioBasisPoints,
              :final first,
              :final second,
            ) =>
              {
                'kind': 'split',
                'axis': axis.name,
                'split_ratio_basis_points': splitRatioBasisPoints,
                'panes': [encodeNode(first), encodeNode(second)],
              },
          };

      Map<String, Object?> payloadForUntrustedTree(WorkspaceLayoutNode tree) {
        final hostRefs = <String>{};
        String? firstPaneId;
        void collect(WorkspaceLayoutNode node) {
          switch (node) {
            case WorkspaceTerminalNode(:final paneId, :final hostId):
              firstPaneId ??= paneId;
              hostRefs.add(hostId);
            case WorkspaceSplitNode(:final first, :final second):
              collect(first);
              collect(second);
          }
        }

        collect(tree);
        final encodedTree = encodeNode(tree)..['active_pane_id'] = firstPaneId;
        return {
          'schema_version': workspaceNestedSplitLayoutSchemaVersion,
          'id': _workspaceId,
          'type': 'workspace',
          'name': 'Untrusted tree',
          'layout_tree': encodedTree,
          'host_refs': hostRefs.toList()..sort(),
        };
      }

      final eightLeaves = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Eight panes',
        layoutTree: treeForLeaves(maxWorkspacePanes, 0),
        activePaneId: '50000000-0000-4000-8000-000000000001',
      );
      expect(eightLeaves.panes, hasLength(maxWorkspacePanes));
      expect(
        WorkspaceRecord.fromJson(eightLeaves.toJson()).toJson(),
        eightLeaves.toJson(),
      );
      final deepestAllowed = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Deepest allowed',
        layoutTree: deepChain(maxWorkspaceSplitDepth, 0),
        activePaneId: '50000000-0000-4000-8000-000000000001',
      );
      expect(deepestAllowed.panes, hasLength(maxWorkspacePanes));
      expect(
        WorkspaceRecord.fromJson(deepestAllowed.toJson()).toJson(),
        deepestAllowed.toJson(),
      );

      expect(
        () => WorkspaceRecord.fromSplitTree(
          id: _workspaceId,
          name: 'Nine panes',
          layoutTree: treeForLeaves(maxWorkspacePanes + 1, 0),
          activePaneId: '50000000-0000-4000-8000-000000000001',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkspaceRecord.fromSplitTree(
          id: _workspaceId,
          name: 'Too deep',
          layoutTree: deepChain(maxWorkspaceSplitDepth + 1, 0),
          activePaneId: '50000000-0000-4000-8000-000000000001',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkspaceRecord.fromJson(
          payloadForUntrustedTree(treeForLeaves(maxWorkspacePanes + 1, 0)),
        ),
        throwsA(isA<FormatException>()),
        reason: 'wire decoder must reject a ninth terminal leaf',
      );
      expect(
        () => WorkspaceRecord.fromJson(
          payloadForUntrustedTree(deepChain(maxWorkspaceSplitDepth + 1, 0)),
        ),
        throwsA(isA<FormatException>()),
        reason: 'wire decoder must reject a split depth of eight',
      );

      final nested = WorkspaceRecord.fromSplitTree(
        id: _workspaceId,
        name: 'Nested',
        layoutTree: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 5000,
          first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
          second: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.vertical,
            splitRatioBasisPoints: 4000,
            first: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
            second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
          ),
        ),
        activePaneId: _paneB,
      ).toJson();
      final root = Map<String, dynamic>.from(nested['layout_tree'] as Map);
      final children = (root['panes'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      final childSplit = Map<String, dynamic>.from(children[1]);
      final childLeaves = (childSplit['panes'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      final invalid = <Map<String, dynamic>>[
        {...nested, 'schema_version': 4},
        {...nested, 'schema_version': workspaceSplitLayoutSchemaVersion},
        {
          ...nested,
          'layout_tree': {...root, 'unknown': true},
        },
        {
          ...nested,
          'layout_tree': {...root, 'axis': 'diagonal'},
        },
        {
          ...nested,
          'layout_tree': {...root, 'split_ratio_basis_points': 7501},
        },
        {
          ...nested,
          'layout_tree': {...root, 'active_pane_id': _workspaceId2},
        },
        {
          ...nested,
          'layout_tree': {
            ...root,
            'panes': [
              children.first,
              {...childSplit, 'future': true},
            ],
          },
        },
        {
          ...nested,
          'layout_tree': {
            ...root,
            'panes': [
              children.first,
              {...childSplit, 'split_ratio_basis_points': 2499},
            ],
          },
        },
        {
          ...nested,
          'layout_tree': {
            ...root,
            'panes': [
              children.first,
              {
                ...childSplit,
                'panes': [childLeaves.first],
              },
            ],
          },
        },
        {
          ...nested,
          'layout_tree': {
            ...root,
            'panes': [
              children.first,
              {
                ...childSplit,
                'panes': [childLeaves.first, childLeaves.first],
              },
            ],
          },
        },
        {
          ...nested,
          'layout_tree': {
            ...root,
            'panes': [
              children.first,
              {
                ...childSplit,
                'panes': [
                  {...childLeaves.first, 'private_data': 'must reject'},
                  childLeaves.last,
                ],
              },
            ],
          },
        },
        {
          ...nested,
          'host_refs': const [_hostA, _hostB],
        },
      ];
      for (final payload in invalid) {
        expect(
          () => WorkspaceRecord.fromJson(payload),
          throwsA(isA<FormatException>()),
          reason: 'Expected invalid nested layout to be rejected: $payload',
        );
      }
    });

    test(
      'requires sorted unique host_refs to equal pane-derived references',
      () {
        final base = _payload();
        for (final refs in [
          const [_hostB, _hostA],
          const [_hostA, _hostA],
          const [_hostA],
          const [_hostA, _hostB, _workspaceId2],
          const ['not-a-uuid'],
          'not-a-list',
        ]) {
          expect(
            () => WorkspaceRecord.fromJson({...base, 'host_refs': refs}),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test('validates repository metadata and JSON manifest structure', () {
      final base = _payload();
      final invalid = <Map<String, dynamic>>[
        {...base, '_record_id': _workspaceId2},
        {...base, '_record_id': 'not-a-uuid'},
        {...base, '_revision_id': 'not-a-uuid'},
        {...base, '_unexpected_metadata': true},
        {...base, '_manifest': 'not-an-object'},
        {
          ...base,
          '_manifest': {1: 'non-string key'},
        },
        {
          ...base,
          '_manifest': {'not_json': Object()},
        },
      ];
      for (final json in invalid) {
        expect(
          () => WorkspaceRecord.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        WorkspaceRecord.fromJson({...base, '_revision_id': null}).revisionId,
        isNull,
      );
    });
  });
}

Map<String, dynamic> _payload() => {
  'schema_version': workspaceLayoutSchemaVersion,
  'id': _workspaceId,
  'type': 'workspace',
  'name': 'Workspace',
  'layout_tree': {
    'kind': 'terminal_tabs',
    'active_pane_id': _paneA,
    'panes': [
      {'kind': 'terminal', 'pane_id': _paneA, 'host_id': _hostB},
      {'kind': 'terminal', 'pane_id': _paneB, 'host_id': _hostA},
    ],
  },
  'host_refs': const [_hostA, _hostB],
};

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
