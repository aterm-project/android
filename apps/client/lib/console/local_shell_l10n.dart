import '../l10n/app_localizations.dart';
import 'local_shell.dart';

String localShellKindLabel(AppLocalizations l10n, LocalShellKind kind) =>
    switch (kind) {
      LocalShellKind.system => l10n.shellLocalKindSystem,
      LocalShellKind.cmd => l10n.shellLocalKindCmd,
      LocalShellKind.powershell => l10n.shellLocalKindPowershell,
      LocalShellKind.pwsh => l10n.shellLocalKindPwsh,
      LocalShellKind.bash => l10n.shellLocalKindBash,
      LocalShellKind.zsh => l10n.shellLocalKindZsh,
      LocalShellKind.fish => l10n.shellLocalKindFish,
      LocalShellKind.sh => l10n.shellLocalKindSh,
    };

String localShellIssueMessage(AppLocalizations l10n, LocalShellIssue issue) =>
    switch (issue) {
      LocalShellIssue.unsupportedPlatform => l10n.shellLocalUnavailableDetail,
      LocalShellIssue.shellNotInstalled => l10n.shellLocalNotInstalled,
      LocalShellIssue.invalidWorkingDirectory =>
        l10n.shellLocalInvalidWorkingDirectory,
      LocalShellIssue.workingDirectoryNotFound =>
        l10n.shellLocalWorkingDirectoryNotFound,
    };

/// Tab title for a console launch; system default keeps the legacy title.
String localShellTabTitle(AppLocalizations l10n, LocalShellLaunch launch) =>
    launch.kind == LocalShellKind.system
    ? l10n.localConsole
    : l10n.shellLocalTabTitle(localShellKindLabel(l10n, launch.kind));
