import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';
import 'responsive_layout.dart';
import '../l10n/l10n.dart';

@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.description,
    required this.builder,
  });

  final String id;
  final String title;
  final IconData icon;
  final String description;
  final WidgetBuilder builder;
}

/// Categories are built on first visit. Visited forms keep their drafts and
/// scroll positions while navigating within settings.
class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({required this.sections, super.key});

  final List<SettingsSection> sections;

  /// Selects another category of the enclosing settings page, for example a
  /// cross-link from Account to Account security. Returns false when
  /// [context] is not inside a settings page or the category is not offered.
  static bool selectSection(BuildContext context, String id) {
    final state = context.findAncestorStateOfType<_SettingsScaffoldState>();
    if (state == null || !state.widget.sections.any((s) => s.id == id)) {
      return false;
    }
    state._select(id);
    return true;
  }

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final _contentKey = GlobalKey();
  final _visited = <String>{};
  String? _selectedId;

  void _select(String id) {
    if (_selectedId == id) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedId = id;
      _visited.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    if (sections.isEmpty) return const SizedBox.shrink();
    final ids = sections.map((section) => section.id).toSet();
    _visited.removeWhere((id) => !ids.contains(id));
    if (!ids.contains(_selectedId)) _selectedId = sections.first.id;
    _visited.add(_selectedId!);
    final selected = sections.indexWhere((s) => s.id == _selectedId);
    final density = AppDensity.of(context);
    final touch = isTouchPlatform(Theme.of(context).platform);
    // Padding follows the width this scaffold actually gets (not the window),
    // so it always agrees with the picker/navigation choice below, e.g. on a
    // tablet beside the Home rail or in Android split-screen.
    Widget content(bool narrow) => KeyedSubtree(
      key: _contentKey,
      child: IndexedStack(
        index: selected,
        sizing: StackFit.expand,
        children: [
          for (final section in sections)
            TickerMode(
              key: ValueKey('settings_page_${section.id}'),
              enabled: section.id == _selectedId,
              child: !_visited.contains(section.id)
                  ? const SizedBox.shrink()
                  : SingleChildScrollView(
                      key: PageStorageKey('settings_scroll_${section.id}'),
                      primary: false,
                      // Touch: dragging the page hides the soft keyboard, as
                      // Android users expect, instead of leaving it covering
                      // the form.
                      // Desktop keeps the inherited scroll behaviour.
                      keyboardDismissBehavior: touch
                          ? ScrollViewKeyboardDismissBehavior.onDrag
                          : null,
                      padding: narrow
                          ? const EdgeInsets.all(12)
                          : density.pagePadding,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: density.dialogXl,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                section.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              SizedBox(height: density.space3),
                              Text(
                                section.description,
                                style: TextStyle(
                                  color: context.palette.muted,
                                  height: 1.5,
                                ),
                              ),
                              SizedBox(height: density.space7),
                              section.builder(context),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppBreakpoints.settingsNavigation) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: DropdownButtonFormField<String>(
                  key: ValueKey('settings_category_picker_$_selectedId'),
                  initialValue: _selectedId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.settingsCategories,
                  ),
                  items: [
                    for (final section in sections)
                      DropdownMenuItem(
                        value: section.id,
                        child: Text(section.title),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) _select(id);
                  },
                ),
              ),
              Expanded(child: content(true)),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: density.isCompact ? 200 : 220,
              child: Material(
                color: context.palette.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        density.space7,
                        density.space7,
                        density.space7,
                        density.space5,
                      ),
                      child: Text(
                        context.l10n.settings,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('settings_category_navigation'),
                        padding: EdgeInsets.fromLTRB(
                          density.space4,
                          0,
                          density.space4,
                          density.space7,
                        ),
                        children: [
                          for (final section in sections)
                            Padding(
                              padding: EdgeInsets.only(bottom: density.space1),
                              child: ListTile(
                                key: ValueKey(
                                  'settings_category_${section.id}',
                                ),
                                selected: section.id == _selectedId,
                                selectedColor: context.palette.lime,
                                selectedTileColor: context.palette.lime
                                    .withValues(alpha: .09),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    density.radiusMd,
                                  ),
                                ),
                                leading: Icon(
                                  section.icon,
                                  size: density.iconMd,
                                ),
                                minLeadingWidth: density.iconMd,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: density.space5,
                                ),
                                title: Text(
                                  section.title,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                onTap: () => _select(section.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, color: context.palette.line),
            Expanded(child: content(false)),
          ],
        );
      },
    );
  }
}

/// Keeps individual settings visually separate without nesting scroll views.
class SettingsCards extends StatelessWidget {
  const SettingsCards({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: AppDensity.of(context).space5),
        children[i],
      ],
    ],
  );
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    required this.child,
    this.semanticContainer = true,
    super.key,
  });
  final Widget child;

  /// Passed to [Card.semanticContainer]. Keep the default for read-only cards
  /// (they are announced as one block). Pass false for cards that hold
  /// interactive controls such as text fields: otherwise a field that does not
  /// form its own semantics boundary is merged into the card node, so Android
  /// accessibility and UI automation report the field with the whole card's
  /// bounds and all of the card's text as its label.
  final bool semanticContainer;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    semanticContainer: semanticContainer,
    child: Padding(
      padding: EdgeInsets.all(AppDensity.of(context).space6),
      child: child,
    ),
  );
}
