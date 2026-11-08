import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openSettingsCategory(
  WidgetTester tester,
  String id, {
  bool ifAvailable = false,
}) async {
  final item = find.byKey(ValueKey('settings_category_$id'));
  final navigation = find.byKey(const ValueKey('settings_category_navigation'));
  if (navigation.evaluate().isNotEmpty) {
    final navScrollable = find.descendant(
      of: navigation,
      matching: find.byType(Scrollable),
    );
    if (item.evaluate().isEmpty) {
      await tester.drag(navigation, const Offset(0, 2000));
      await tester.pump();
      if (ifAvailable && item.evaluate().isEmpty) {
        final sections = tester
            .widget<SettingsScaffold>(find.byType(SettingsScaffold))
            .sections;
        if (!sections.any((section) => section.id == id)) return;
      }
      await tester.scrollUntilVisible(item, 150, scrollable: navScrollable);
    }
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(item);
  } else {
    final picker = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.key.toString().contains('settings_category_picker_'),
    );
    if (ifAvailable && picker.evaluate().isEmpty) return;
    final field = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: picker,
        matching: find.byType(DropdownButton<String>),
      ),
    );
    if (ifAvailable && !field.items!.any((item) => item.value == id)) return;
    final option = field.items!.singleWhere((item) => item.value == id);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text((option.child as Text).data!).last);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
