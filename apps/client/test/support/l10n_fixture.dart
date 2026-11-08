import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs the enclosing test file with an explicit app language.
///
/// Used by legacy behavioural tests whose assertions were written against the
/// Simplified Chinese messages; they now exercise the zh catalog explicitly
/// (controller/service messages via [currentL10n], and full-app roots via a
/// process controller whose platform language is [languageCode]) instead of
/// relying on hard-coded strings. No preference store is attached, so no
/// asynchronous writes are created outside a widget test's FakeAsync zone.
void useAppLocaleFixture(String languageCode) {
  setUp(() {
    AppLanguageController.debugInstance = AppLanguageController(
      systemLocales: () => [Locale(languageCode)],
    );
    debugCurrentL10n = appLocalizationsFor(Locale(languageCode));
  });
  tearDown(() {
    AppLanguageController.debugInstance = null;
    debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
  });
}
