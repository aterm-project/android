import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/app_language_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingStore implements AppLanguageStore {
  _ThrowingStore({this.readThrows = false, this.writeThrows = false});
  final bool readThrows;
  final bool writeThrows;

  @override
  Future<String?> read() async {
    if (readThrows) throw const FileSystemException('denied');
    return 'ja';
  }

  @override
  Future<void> write(String code) async {
    if (writeThrows) throw const FileSystemException('read-only');
  }
}


/// Store whose writes can be held open and made to fail individually, to
/// reproduce out-of-order completion of preference writes.
class _GatedStore implements AppLanguageStore {
  String? stored;
  final attempts = <String>[];
  final gates = <int, Completer<void>>{};
  final entered = <int, Completer<void>>{};
  final failOn = <int>{};

  Completer<void> gate(int write) => gates.putIfAbsent(write, Completer.new);
  Future<void> enteredWrite(int write) =>
      entered.putIfAbsent(write, Completer.new).future;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String code) async {
    final index = attempts.length + 1;
    attempts.add(code);
    entered.putIfAbsent(index, Completer.new).complete();
    final g = gates[index];
    if (g != null) await g.future;
    if (failOn.contains(index)) throw const FileSystemException('busy');
    stored = code;
  }
}

Map<String, dynamic> _arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
        as Map<String, dynamic>;

final _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)[,}]');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppLanguageController.debugInstance = null;
    debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
  });

  group('locale resolution', () {
    test('explicit choice wins over the platform list', () {
      expect(
        resolveAppLocale(AppLanguage.russian, const [Locale('zh', 'CN')]),
        const Locale('ru'),
      );
    });

    test('system follows the first supported preferred language', () {
      expect(
        resolveAppLocale(AppLanguage.system, const [
          Locale('fr', 'FR'),
          Locale('ja', 'JP'),
          Locale('en', 'US'),
        ]),
        const Locale('ja'),
      );
      expect(
        resolveAppLocale(AppLanguage.system, const [
          Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ]),
        const Locale('zh'),
      );
    });

    test('unsupported or empty platform languages fall back to English', () {
      expect(
        resolveAppLocale(AppLanguage.system, const [Locale('de', 'DE')]),
        const Locale('en'),
      );
      expect(resolveAppLocale(AppLanguage.system, const []), fallbackAppLocale);
      expect(
        appLocalizationsFor(const Locale('fr')).localeName,
        lookupAppLocalizations(const Locale('en')).localeName,
      );
    });

    test('persisted codes are stable and unknown values mean system', () {
      expect(AppLanguage.values.map((l) => l.code), [
        'system',
        'en',
        'zh',
        'ja',
        'ru',
      ]);
      expect(parseAppLanguage(' JA '), AppLanguage.japanese);
      expect(parseAppLanguage('klingon'), AppLanguage.system);
      expect(parseAppLanguage(null), AppLanguage.system);
    });
  });

  group('AppLanguageController', () {
    test('loads, applies and persists the device preference', () async {
      final store = MemoryAppLanguageStore('ru');
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en', 'US')],
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.load(store);
      expect(controller.preference, AppLanguage.russian);
      expect(controller.locale, const Locale('ru'));
      expect(currentL10n.localeName, 'ru');
      expect(notifications, 1);

      await controller.setPreference(AppLanguage.japanese);
      expect(store.value, 'ja');
      expect(controller.locale, const Locale('ja'));
      expect(currentL10n.languageSettingTitle, '言語');

      await controller.setPreference(AppLanguage.system);
      expect(store.value, 'system');
      expect(controller.locale, const Locale('en'));
    });

    test('read failures keep the system default', () async {
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('zh', 'CN')],
      );
      await controller.load(_ThrowingStore(readThrows: true));
      expect(controller.preference, AppLanguage.system);
      expect(controller.locale, const Locale('zh'));
    });

    test('write failures still apply the choice and are reported', () async {
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await controller.load(_ThrowingStore(writeThrows: true));
      expect(controller.locale, const Locale('ja'));
      await controller.setPreference(AppLanguage.russian);
      expect(controller.locale, const Locale('ru'));
      expect(controller.writeFailed, isTrue);
    });


    test('latest choice survives an earlier delayed write (root repro)', () async {
      final store = _GatedStore();
      store.gate(1);
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await controller.load(store);
      final earlier = controller.setPreference(AppLanguage.japanese);
      await store.enteredWrite(1);
      final latest = controller.setPreference(AppLanguage.russian);
      await Future<void>.delayed(Duration.zero);
      expect(controller.preference, AppLanguage.russian);
      expect(controller.locale, const Locale('ru'), reason: 'applied at once');
      store.gate(1).complete();
      await Future.wait([earlier, latest]);
      expect(store.stored, 'ru');
      final restarted = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await restarted.load(store);
      expect(restarted.preference, AppLanguage.russian);
      controller.dispose();
    });

    test('a rapid burst coalesces to the final choice in order', () async {
      final store = _GatedStore();
      store.gate(1);
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await controller.load(store);
      final first = controller.setPreference(AppLanguage.japanese);
      await store.enteredWrite(1);
      final rest = [
        controller.setPreference(AppLanguage.chinese),
        controller.setPreference(AppLanguage.russian),
        controller.setPreference(AppLanguage.english),
      ];
      store.gate(1).complete();
      await Future.wait([first, ...rest]);
      expect(store.attempts, ['ja', 'en'], reason: 'superseded writes skipped');
      expect(store.stored, 'en');
      expect(controller.preference, AppLanguage.english);
    });

    test('a stale failure cannot mask the latest successful write', () async {
      final store = _GatedStore()..failOn.add(1);
      store.gate(1);
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await controller.load(store);
      final earlier = controller.setPreference(AppLanguage.japanese);
      await store.enteredWrite(1);
      final latest = controller.setPreference(AppLanguage.russian);
      store.gate(1).complete();
      await Future.wait([earlier, latest]);
      expect(controller.writeFailed, isFalse);
      expect(store.stored, 'ru');
    });

    test('a failure of the latest write is reported after earlier success', () async {
      final store = _GatedStore()..failOn.add(2);
      store.gate(1);
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      await controller.load(store);
      final earlier = controller.setPreference(AppLanguage.japanese);
      await store.enteredWrite(1);
      final latest = controller.setPreference(AppLanguage.russian);
      store.gate(1).complete();
      await Future.wait([earlier, latest]);
      expect(controller.writeFailed, isTrue);
      expect(controller.locale, const Locale('ru'), reason: 'still applied');
      await controller.setPreference(AppLanguage.chinese);
      expect(controller.writeFailed, isFalse);
      expect(store.stored, 'zh');
    });

    test('platform locale changes only matter for the system choice', () async {
      var platform = const [Locale('en')];
      final controller = AppLanguageController(systemLocales: () => platform);
      await controller.load(MemoryAppLanguageStore());
      platform = const [Locale('ja')];
      controller.systemLocalesChanged();
      expect(controller.locale, const Locale('ja'));
      await controller.setPreference(AppLanguage.english);
      platform = const [Locale('ru')];
      controller.systemLocalesChanged();
      expect(controller.locale, const Locale('en'));
    });
  });

  group('catalog completeness', () {
    final en = _arb('en');
    final keys = en.keys.where((k) => !k.startsWith('@')).toSet();

    test('all four catalogs define exactly the same messages', () {
      expect(keys.length, greaterThan(2500));
      for (final locale in ['zh', 'ja', 'ru']) {
        final arb = _arb(locale);
        final other = arb.keys.where((k) => !k.startsWith('@')).toSet();
        expect(other, keys, reason: 'app_$locale.arb keys');
        expect(arb['@@locale'], locale);
      }
    });

    test('no empty messages and no raw keys shown as text', () {
      for (final locale in ['en', 'zh', 'ja', 'ru']) {
        final arb = _arb(locale);
        for (final key in keys) {
          if (key == '@@locale') continue;
          final value = arb[key] as String;
          expect(value.trim(), isNotEmpty, reason: '$locale.$key');
          expect(value, isNot(key), reason: '$locale.$key');
        }
      }
    });

    test('every translation keeps the same placeholders', () {
      for (final key in keys) {
        if (key == '@@locale') continue;
        final expected = _placeholder
            .allMatches(en[key] as String)
            .map((m) => m.group(1))
            .toSet();
        for (final locale in ['zh', 'ja', 'ru']) {
          final got = _placeholder
              .allMatches(_arb(locale)[key] as String)
              .map((m) => m.group(1))
              .toSet();
          expect(got, expected, reason: '$locale.$key');
        }
      }
    });

    test('catalogs are real translations, not copies of English', () {
      for (final locale in ['zh', 'ja', 'ru']) {
        final arb = _arb(locale);
        var identical = 0;
        for (final key in keys) {
          if (key == '@@locale') continue;
          if (arb[key] == en[key]) identical++;
        }
        // Only protocol tokens, product names and pure formats may match.
        expect(identical, lessThan(keys.length * 0.02), reason: locale);
      }
    });

    test('Chinese and Japanese catalogs are in their own scripts', () {
      final kana = RegExp(r'[぀-ヿ]');
      final cyrillic = RegExp(r'[Ѐ-ӿ]');
      final ja = _arb('ja');
      final ru = _arb('ru');
      final zh = _arb('zh');
      var jaKana = 0, ruCyr = 0, zhKana = 0;
      for (final key in keys) {
        if (key == '@@locale') continue;
        if (kana.hasMatch(ja[key] as String)) jaKana++;
        if (cyrillic.hasMatch(ru[key] as String)) ruCyr++;
        if (kana.hasMatch(zh[key] as String)) zhKana++;
      }
      expect(jaKana, greaterThan(keys.length * 0.9));
      expect(ruCyr, greaterThan(keys.length * 0.9));
      expect(zhKana, 0);
    });
  });

  group('interpolation, plurals and dates', () {
    AppLocalizations l(String code) => appLocalizationsFor(Locale(code));

    test('English and Russian plural forms', () {
      expect(l('en').countHosts(1), '1 host');
      expect(l('en').countHosts(3), '3 hosts');
      expect(l('ru').countHosts(1), '1 хост');
      expect(l('ru').countHosts(3), '3 хоста');
      expect(l('ru').countHosts(5), '5 хостов');
      expect(l('ru').countHosts(21), '21 хост');
      expect(l('zh').countHosts(3), '3 台主机');
      expect(l('ja').countHosts(3), '3 台のホスト');
    });

    test('parameters are placed by each language grammar', () {
      expect(l('en').closeTitle('prod-db'), 'Close prod-db');
      expect(l('ja').closeTitle('prod-db'), 'prod-db を閉じる');
      expect(l('ru').closeTitle('prod-db'), 'Закрыть prod-db');
      expect(l('zh').closeTitle('prod-db'), '关闭 prod-db');
    });

    test('owner recycle-bin consent paragraph is one localized message', () {
      const legacy =
          'Automatic purge consent: Enabled. Consent applies to this exact '
          'tombstone. When enabled, bounded Maintenance may purge it after its '
          'restore deadline and other required checks. Enabling consent does '
          'not purge it immediately; offline device copies and exports are not '
          'removed.';
      final en = l('en');
      final consent = en.automaticPurgeConsentValuevalue(en.purgeConsentEnabled);
      expect(en.recycleBinPurgeConsentLineOwner(consent), legacy);
      expect(en.recycleBinPurgeConsentLine(consent), '$consent.');
      for (final code in ['zh', 'ja', 'ru']) {
        final c = l(code).automaticPurgeConsentValuevalue(
          l(code).purgeConsentEnabled,
        );
        final line = l(code).recycleBinPurgeConsentLineOwner(c);
        expect(line, startsWith(c), reason: code);
        expect(line, isNot(contains('Consent applies')), reason: code);
      }
    });

    test('dates are formatted for the locale, not raw ISO text', () {
      final at = DateTime(2026, 11, 7, 21, 40);
      for (final code in ['en', 'zh', 'ja', 'ru']) {
        final text = l(code).mfaChallengeTotp(at);
        expect(text, isNot(contains('2026-11-07')), reason: code);
        expect(text, contains('2026'), reason: code);
      }
      expect(l('en').mfaChallengeTotp(at), contains('Nov 7, 2026'));
    });
  });
}
