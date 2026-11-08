import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/group_session_layout.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const group = GroupRecord(
    id: 'group',
    name: 'Production',
    manifest: {'future': 'preserve'},
  );
  test('encrypted group payload roundtrips geometry, active pane and host references only', () {
    final source = SessionWorkspaceSplit(
      axis: Axis.horizontal,
      ratio: .31,
      first: const SessionWorkspacePane('runtime-secret-1'),
      second: SessionWorkspaceSplit(
        axis: Axis.vertical,
        ratio: .72,
        first: const SessionWorkspacePane('runtime-secret-2'),
        second: const SessionWorkspacePane('unrelated'),
      ),
    );
    final layout = GroupSessionLayout.capture(
      root: source,
      hostIdsBySession: {
        'runtime-secret-1': 'host-a',
        'runtime-secret-2': 'host-b',
      },
      selectedSessionId: 'runtime-secret-2',
    );
    final saved = layout.writeTo(group);
    final encoded = jsonEncode(saved.toJson());
    expect(encoded, isNot(contains('runtime-secret')));
    expect(encoded, isNot(contains('unrelated')));
    expect(saved.manifest?['future'], 'preserve');
    final decoded = GroupSessionLayout.read(saved)!;
    final controller = SessionWorkspaceController();
    expect(
      decoded.apply(
        controller,
        sessionIdsByPane: {
          decoded.panes[0].paneId: 'new-a',
          decoded.panes[1].paneId: 'new-b',
        },
      ),
      isTrue,
    );
    expect(controller.sessionIds, ['new-a', 'new-b']);
    expect(controller.selectedId, 'new-b');
    expect((controller.root as SessionWorkspaceSplit).ratio, .31);
    expect(GroupSessionLayout.read(GroupSessionLayout.clear(saved)), isNull);
    expect(GroupSessionLayout.clear(saved).manifest, {'future': 'preserve'});
    controller.dispose();
  });
  test(
    'partial failure collapses panes without borrowing old active session',
    () {
      final layout = GroupSessionLayout.forHosts(['a', 'b', 'c']);
      final controller = SessionWorkspaceController()..activate('unrelated');
      expect(layout.apply(controller, sessionIdsByPane: {}), isFalse);
      expect(controller.sessionIds, ['unrelated']);
      expect(
        layout.apply(
          controller,
          sessionIdsByPane: {layout.panes[1].paneId: 'connected-b'},
        ),
        isTrue,
      );
      expect(controller.sessionIds, ['connected-b']);
      expect(controller.selectedId, 'connected-b');
      expect(
        () => layout.apply(
          controller,
          sessionIdsByPane: {
            layout.panes[0].paneId: 'same',
            layout.panes[1].paneId: 'same',
          },
        ),
        throwsFormatException,
      );
      expect(controller.sessionIds, ['connected-b']);
      controller.dispose();
    },
  );
  test('malformed manifests and oversized layouts fail closed', () {
    final saved = GroupSessionLayout.forHosts(['a', 'b']).writeTo(group);
    final raw = jsonDecode(jsonEncode(saved.manifest)) as Map<String, dynamic>;
    final layout = raw['group_session_layout_v1'] as Map<String, dynamic>;
    (layout['root'] as Map<String, dynamic>)['ratio'] = 999999;
    expect(
      () => GroupSessionLayout.read(
        GroupRecord(id: 'group', name: 'test', manifest: raw),
      ),
      throwsFormatException,
    );
    expect(
      () => GroupSessionLayout.forHosts(List.generate(33, (i) => 'host-$i')),
      throwsFormatException,
    );
    expect(
      () => GroupSessionLayout.forHosts(['host\ninvalid']),
      throwsFormatException,
    );
  });
  test(
    'default tree balances thirty-two panes and restores without aliasing',
    () {
      final layout = GroupSessionLayout.forHosts(
        List.generate(32, (i) => 'host-$i'),
      );
      final controller = SessionWorkspaceController();
      final mapping = {
        for (final pane in layout.panes) pane.paneId: pane.hostId,
      };
      layout.apply(controller, sessionIdsByPane: mapping);
      expect(controller.sessionIds, hasLength(32));
      controller.resize(controller.root as SessionWorkspaceSplit, .8);
      layout.apply(controller, sessionIdsByPane: mapping);
      expect((controller.root as SessionWorkspaceSplit).ratio, .5);
      controller.dispose();
    },
  );
  test(
    'group membership includes descendants once and excludes other protocols',
    () {
      HostRecord host(
        String id,
        String groupId, {
        HostProtocol protocol = HostProtocol.ssh,
      }) => HostRecord(
        id: id,
        name: id,
        address: 'example.invalid',
        username: 'user',
        groupId: groupId,
        protocol: protocol,
      );
      final hosts = [
        host('a', 'group'),
        host('b', 'child'),
        host('c', 'other'),
      ];
      final result = GroupSessionLayout.groupHosts(group, [
        group,
        const GroupRecord(id: 'child', name: 'child', parentId: 'group'),
        const GroupRecord(id: 'group', name: 'cycle', parentId: 'child'),
      ], hosts);
      expect(result.map((h) => h.id), ['a', 'b']);
    },
  );
}
