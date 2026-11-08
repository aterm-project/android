import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'app_theme.dart';
import 'app_menu.dart';

/// Device-local display language picker (System default, English, 简体中文,
/// 日本語, Русский). Switching applies immediately without recreating the
/// workspace, its sessions or form drafts.
class AppLanguageSettings extends StatelessWidget {
  const AppLanguageSettings({this.controller, this.dense = false, super.key});

  final AppLanguageController? controller;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final languages = controller ?? AppLanguageController.instance;
    return ListenableBuilder(
      listenable: languages,
      builder: (context, _) {
        final l10n = context.l10n;
        final current = languages.preference;
        final resolvedName = AppLanguage.values
            .firstWhere(
              (language) =>
                  language.locale?.languageCode ==
                  languages.systemLocale.languageCode,
              orElse: () => AppLanguage.english,
            )
            .nativeName(l10n);
        return Column(
          key: const ValueKey('app_language_settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.translate, size: 20, color: AppColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.languageSettingTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!dense) ...[
              const SizedBox(height: 6),
              Text(
                l10n.languageSettingDescription,
                style: const TextStyle(color: AppColors.muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 8),
            for (final language in AppLanguage.values)
              _LanguageOption(
                language: language,
                selected: language == current,
                label: language.nativeName(l10n),
                subtitle: language == AppLanguage.system
                    ? l10n.languageSettingSystemResolved(resolvedName)
                    : null,
                onSelected: () => selectAppLanguage(language, using: languages),
              ),
            const SizedBox(height: 6),
            Text(
              languages.writeFailed
                  ? l10n.languageSettingSaveFailed
                  : l10n.languageSettingDevicePreference,
              key: const ValueKey('app_language_storage_note'),
              style: TextStyle(
                color: languages.writeFailed
                    ? AppColors.orange
                    : AppColors.muted,
                fontSize: 12,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.language,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.onSelected,
  });

  final AppLanguage language;
  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    inMutuallyExclusiveGroup: true,
    checked: selected,
    child: ListTile(
      key: ValueKey('app_language_${language.code}'),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: selected,
      selectedTileColor: AppColors.accent.withValues(alpha: 0.16),
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? AppColors.accentText : AppColors.muted,
        size: 20,
      ),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: onSelected,
    ),
  );
}

/// Compact language menu for screens shown before a workspace is open.
class AppLanguageMenuButton extends StatelessWidget {
  const AppLanguageMenuButton({this.controller, super.key});

  final AppLanguageController? controller;

  @override
  Widget build(BuildContext context) {
    final languages = controller ?? AppLanguageController.instance;
    final l10n = context.l10n;
    return PopupMenuButton<AppLanguage>(
      key: const ValueKey('app_language_menu'),
      tooltip: l10n.languageSettingTitle,
      icon: const Icon(Icons.translate),
      initialValue: languages.preference,
      onSelected: (language) => selectAppLanguage(language, using: languages),
      itemBuilder: (context) => [
        for (final language in AppLanguage.values)
          CheckedPopupMenuItem<AppLanguage>(
            height: appMenuItemHeight(context),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            key: ValueKey('app_language_menu_${language.code}'),
            value: language,
            checked: language == languages.preference,
            child: Text(language.nativeName(l10n)),
          ),
      ],
    );
  }
}
