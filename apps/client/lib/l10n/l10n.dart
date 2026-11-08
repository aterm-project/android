import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart' as intl_dates;

import '../storage/app_language_store.dart';
import 'app_localizations.dart';

export 'app_localizations.dart';

/// The display languages Atermius ships complete catalogs for, plus `system`.
///
/// [code] is the stable persisted value; never rename it.
enum AppLanguage {
  system('system'),
  english('en'),
  chinese('zh'),
  japanese('ja'),
  russian('ru');

  const AppLanguage(this.code);
  final String code;

  Locale? get locale => this == system ? null : Locale(code);

  /// Native name of the language, shown identically in every UI language so
  /// users can always find their own language.
  String nativeName(AppLocalizations l10n) => switch (this) {
    system => l10n.languageSystemDefault,
    english => 'English',
    chinese => '简体中文',
    japanese => '日本語',
    russian => 'Русский',
  };
}

AppLanguage parseAppLanguage(String? value) {
  final normalized = value?.trim().toLowerCase();
  for (final language in AppLanguage.values) {
    if (language.code == normalized) return language;
  }
  return AppLanguage.system;
}

const fallbackAppLocale = Locale('en');

/// Locales with a shipped catalog, in fallback-preference order.
const supportedAppLocales = <Locale>[
  Locale('en'),
  Locale('zh'),
  Locale('ja'),
  Locale('ru'),
];

/// Resolves the effective UI locale.
///
/// An explicit choice always wins. `system` walks the platform's preferred
/// languages in order and picks the first with a shipped catalog (any `zh`
/// region or script maps to the Simplified Chinese catalog); otherwise English.
Locale resolveAppLocale(AppLanguage preference, List<Locale> systemLocales) {
  final explicit = preference.locale;
  if (explicit != null) return explicit;
  for (final locale in systemLocales) {
    for (final supported in supportedAppLocales) {
      if (supported.languageCode == locale.languageCode) return supported;
    }
  }
  return fallbackAppLocale;
}

final _byLanguage = <String, AppLocalizations>{};
var _dateDataReady = false;

/// Date/number symbols for every shipped locale. MaterialApp's global
/// delegates also load them, but controller and service messages can be
/// formatted before (or without) any MaterialApp, so load them up front. The
/// local symbol tables are installed synchronously.
void _ensureDateData() {
  if (_dateDataReady) return;
  _dateDataReady = true;
  unawaited(intl_dates.initializeDateFormatting());
}

/// Returns the catalog for [locale], falling back to English when the
/// language has no catalog.
AppLocalizations appLocalizationsFor(Locale locale) {
  _ensureDateData();
  final code =
      supportedAppLocales.any(
        (supported) => supported.languageCode == locale.languageCode,
      )
      ? locale.languageCode
      : fallbackAppLocale.languageCode;
  return _byLanguage[code] ??= lookupAppLocalizations(Locale(code));
}

AppLocalizations _current = appLocalizationsFor(fallbackAppLocale);

/// Catalog for code that has no [BuildContext] (controllers, services and
/// domain validation). Updated synchronously by [AppLanguageController] before
/// the widget tree rebuilds. Messages already stored in controller state keep
/// the language they were produced in until they are replaced.
AppLocalizations get currentL10n => _current;

@visibleForTesting
set debugCurrentL10n(AppLocalizations value) => _current = value;

extension AppLocalizationsContext on BuildContext {
  /// Catalog for the nearest [Localizations] scope.
  ///
  /// This intentionally does not register an inherited dependency, so it is
  /// safe in `initState`, callbacks and after async gaps. Runtime language
  /// switches rebuild the whole tree through [AppLanguageHost].
  AppLocalizations get l10n {
    if (!mounted) return _current;
    try {
      final scope = findAncestorWidgetOfExactType<Localizations>();
      final locale = scope?.locale;
      if (locale == null) return _current;
      // A scope without the app catalog (e.g. a bare MaterialApp in tests or
      // embedders) follows the process-wide app language instead of the
      // platform default, so the whole UI always speaks one language.
      final hasCatalog = scope!.delegates.any(
        (delegate) => delegate.type == AppLocalizations,
      );
      return hasCatalog ? appLocalizationsFor(locale) : _current;
    } on Object {
      return _current;
    }
  }
}

/// Owns the persisted display-language preference and the resolved locale.
class AppLanguageController extends ChangeNotifier {
  AppLanguageController({List<Locale> Function()? systemLocales})
    : _systemLocales =
          systemLocales ??
          (() => WidgetsBinding.instance.platformDispatcher.locales) {
    _resolve();
  }

  static AppLanguageController? _instance;

  /// Process-wide controller used by the app roots.
  static AppLanguageController get instance =>
      _instance ??= AppLanguageController();

  @visibleForTesting
  static set debugInstance(AppLanguageController? controller) =>
      _instance = controller;

  AppLanguageStore? _store;
  final List<Locale> Function() _systemLocales;
  AppLanguage _preference = AppLanguage.system;
  Locale _locale = fallbackAppLocale;
  Locale _systemLocale = fallbackAppLocale;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  bool _disposed = false;

  AppLanguage get preference => _preference;
  Locale get locale => _locale;

  /// Language the System option would use, independent of an explicit choice.
  Locale get systemLocale => _systemLocale;

  /// Whether the last attempt to persist a choice failed. The choice still
  /// applies for this run.
  bool get writeFailed => _writeFailed;

  /// Reads the stored preference. Failures keep the system default.
  Future<void> load(AppLanguageStore store) async {
    _store = store;
    try {
      final stored = await store.read().timeout(const Duration(seconds: 2));
      _preference = parseAppLanguage(stored);
    } on Object {
      _preference = AppLanguage.system;
    }
    _apply();
  }

  /// Applies [language] immediately and persists it as a device preference.
  ///
  /// The UI switches synchronously. Store writes are serialized in selection
  /// order and coalesced: a write that has been superseded by a newer choice
  /// is skipped, and only the latest choice may update [writeFailed], so a
  /// slow earlier write can never overwrite the final selection on disk.
  /// The returned future completes once this selection (or a newer one that
  /// superseded it) has been handled.
  Future<void> setPreference(AppLanguage language) {
    final changed = language != _preference;
    _preference = language;
    if (changed) _apply();
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final code = language.code;
    final next = _writeChain.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write(code);
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      _writeFailed = failed;
      notifyListeners();
    });
    _writeChain = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Re-resolves after the platform's preferred languages changed.
  void systemLocalesChanged() {
    _apply();
  }

  void _resolve() {
    List<Locale> system;
    try {
      system = _systemLocales();
    } on Object {
      system = const [];
    }
    _systemLocale = resolveAppLocale(AppLanguage.system, system);
    _locale = _preference.locale ?? _systemLocale;
    _current = appLocalizationsFor(_locale);
  }

  void _apply() {
    final previous = _locale;
    final previousSystem = _systemLocale;
    _resolve();
    if (previous != _locale || previousSystem != _systemLocale) {
      notifyListeners();
    }
  }
}

/// Rebuilds its subtree in place when the display language changes.
///
/// Every element is marked dirty instead of being recreated, so State objects
/// (terminal sessions, SFTP panes, text field input, focus and scroll) keep
/// their identity across a runtime language switch.
class AppLanguageHost extends StatefulWidget {
  const AppLanguageHost({required this.builder, this.controller, super.key});

  final Widget Function(BuildContext context, Locale locale) builder;
  final AppLanguageController? controller;

  @override
  State<AppLanguageHost> createState() => _AppLanguageHostState();
}

class _AppLanguageHostState extends State<AppLanguageHost>
    with WidgetsBindingObserver {
  late AppLanguageController _controller;
  late Locale _locale;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AppLanguageController.instance;
    _locale = _controller.locale;
    _controller.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(AppLanguageHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.controller ?? AppLanguageController.instance;
    if (!identical(next, _controller)) {
      _controller.removeListener(_changed);
      _controller = next..addListener(_changed);
      _locale = _controller.locale;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) =>
      _controller.systemLocalesChanged();

  void _changed() {
    if (!mounted || _controller.locale == _locale) return;
    setState(() => _locale = _controller.locale);
    void markDirty(Element element) {
      element.markNeedsBuild();
      element.visitChildren(markDirty);
    }

    (context as Element).visitChildren(markDirty);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _locale);
}

/// Shared `MaterialApp` localization arguments.
abstract final class AppLocalizationSetup {
  static const delegates = AppLocalizations.localizationsDelegates;
  static const locales = AppLocalizations.supportedLocales;
}

/// Unawaited-safe helper for persisting a language choice from UI callbacks.
void selectAppLanguage(AppLanguage language, {AppLanguageController? using}) =>
    unawaited(
      (using ?? AppLanguageController.instance).setPreference(language),
    );
