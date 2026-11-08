import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'settings separate categories and preserve drafts across navigation and resize',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var secondaryBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SettingsScaffold(
              sections: [
                SettingsSection(
                  id: 'workspace',
                  title: 'Workspace',
                  icon: Icons.dashboard,
                  description: '工作区说明',
                  builder: (_) => const TextField(key: ValueKey('draft')),
                ),
                SettingsSection(
                  id: 'security',
                  title: 'Account security',
                  icon: Icons.shield,
                  description: '安全说明',
                  builder: (_) {
                    secondaryBuilds++;
                    return const Text('安全内容');
                  },
                ),
              ],
            ),
          ),
        ),
      );
      expect(secondaryBuilds, 0);
      final navigation = find.byKey(
        const ValueKey('settings_category_navigation'),
      );
      expect(
        tester.getRect(navigation).right,
        lessThan(tester.getRect(find.byKey(const ValueKey('draft'))).left),
      );
      await tester.enterText(find.byKey(const ValueKey('draft')), '保留草稿');
      await tester.tap(
        find.byKey(const ValueKey('settings_category_security')),
      );
      await tester.pumpAndSettle();
      expect(find.text('安全内容'), findsOneWidget);
      expect(find.byKey(const ValueKey('draft')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('settings_category_workspace')),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留草稿'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pumpAndSettle();
      expect(find.text('保留草稿'), findsOneWidget);
      expect(navigation, findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account security').last);
      await tester.pumpAndSettle();
      expect(find.text('安全内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
