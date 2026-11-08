import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/local_shell_menu.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(void Function(BuildContext) onBuild, {Locale? locale}) =>
    MaterialApp(
      locale: locale ?? const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          onBuild(context);
          return const Scaffold(body: SizedBox());
        },
      ),
    );

void main() {
  testWidgets('desktop: one entry per installed shell plus options', (
    tester,
  ) async {
    late List<WorkspaceAction> actions;
    final launched = <LocalShellLaunch>[];
    await tester.pumpWidget(
      _host(
        (context) => actions = localShellWorkspaceActions(
          context,
          idPrefix: 'cloud',
          onLaunch: launched.add,
          supportedOverride: true,
          kindsOverride: const [
            LocalShellKind.system,
            LocalShellKind.cmd,
            LocalShellKind.powershell,
            LocalShellKind.pwsh,
          ],
        ),
      ),
    );
    expect(actions.map((a) => a.id), [
      'cloud_new_console',
      'cloud_new_shell_cmd',
      'cloud_new_shell_powershell',
      'cloud_new_shell_pwsh',
      'cloud_shell_options',
    ]);
    expect(actions[3].label, 'New PowerShell 7 (pwsh)');
    await actions[0].run();
    await actions[2].run();
    expect(launched, [
      LocalShellLaunch.systemDefault,
      const LocalShellLaunch(kind: LocalShellKind.powershell),
    ]);

    // Options dialog: syntax-checked cwd, chosen kind, no free-form command.
    final pending = actions.last.run();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('local_shell_options_dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('local_shell_working_directory')),
      'relative/path',
    );
    await tester.tap(find.byKey(const ValueKey('local_shell_start')));
    await tester.pump();
    expect(find.text('Enter an absolute folder path or ~/folder.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local_shell_kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PowerShell 7 (pwsh)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_shell_working_directory')),
      r'D:\work',
    );
    await tester.tap(find.byKey(const ValueKey('local_shell_start')));
    await tester.pumpAndSettle();
    await pending;
    expect(
      launched.last,
      const LocalShellLaunch(
        kind: LocalShellKind.pwsh,
        workingDirectory: r'D:\work',
      ),
    );
  });

  testWidgets('web/mobile: explains unavailability and never launches', (
    tester,
  ) async {
    for (final locale in const [
      Locale('en'),
      Locale('zh'),
      Locale('ja'),
      Locale('ru'),
    ]) {
      late List<WorkspaceAction> actions;
      final launched = <LocalShellLaunch>[];
      await tester.pumpWidget(
        _host(
          (context) => actions = localShellWorkspaceActions(
            context,
            idPrefix: 'local',
            onLaunch: launched.add,
            supportedOverride: false,
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      expect(actions.map((a) => a.id), ['local_console_unavailable']);
      final l10n = lookupAppLocalizations(locale);
      expect(actions.single.label, l10n.shellLocalUnavailable);
      final shown = actions.single.run();
      await tester.pumpAndSettle();
      expect(find.text(l10n.shellLocalUnavailableDetail), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      await shown;
      expect(launched, isEmpty);
    }
  });
}
