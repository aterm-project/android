import 'dart:async';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/app_language_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedFirstWrite implements AppLanguageStore {
  final firstEntered = Completer<void>();
  final releaseFirst = Completer<void>();
  String? stored;
  int writes = 0;
  @override
  Future<String?> read() async => stored;
  @override
  Future<void> write(String code) async {
    if (++writes == 1) {
      firstEntered.complete();
      await releaseFirst.future;
    }
    stored = code;
  }
}

void main() {
  test('latest language choice survives an earlier delayed preference write', () async {
    final store = DelayedFirstWrite();
    final controller = AppLanguageController(systemLocales: () => [const Locale('en')]);
    await controller.load(store);
    final earlier = controller.setPreference(AppLanguage.japanese);
    await store.firstEntered.future;
    final latest = controller.setPreference(AppLanguage.russian);
    await Future<void>.delayed(Duration.zero);
    expect(controller.preference, AppLanguage.russian);
    store.releaseFirst.complete();
    await Future.wait([earlier, latest]);
    expect(store.stored, 'ru', reason: 'Restart must retain the final visible choice');
    controller.dispose();
  });
}
