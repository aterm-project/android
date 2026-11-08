import 'package:aterm_client/storage/browser_storage_client.dart';
import 'package:aterm_client/storage/browser_storage_status.dart';
import 'package:aterm_client/ui/browser_storage_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'displays refreshed persisted state instead of trusting request result',
    (tester) async {
      final client = _FakeBrowserStorageClient(
        persistedValues: [false, false, true],
        requestResult: true,
        estimateValue: const BrowserStorageEstimate(
          usageBytes: 12 * 1024 * 1024,
          quotaBytes: 128 * 1024 * 1024,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserStorageStatusCard(
              service: BrowserStorageStatusService(client: client),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Persistent storage is not enabled'), findsOneWidget);
      expect(
        find.text('Estimated usage: 12 MiB of 128 MiB for this site'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('browser_storage_request')));
      await tester.pumpAndSettle();

      expect(client.requestCalls, 1);
      expect(client.persistedCalls, 2);
      expect(find.text('Persistent storage is not enabled'), findsOneWidget);
      expect(
        find.text(
          'The request returned success, but the browser still reports storage is not persistent.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('browser_storage_refresh')));
      await tester.pumpAndSettle();

      expect(find.text('Persistent storage is enabled'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('browser_storage_request')),
        findsNothing,
      );
      expect(client.persistedCalls, 3);
    },
  );

  testWidgets('failed browser reads remain unknown, not falsely denied', (
    tester,
  ) async {
    final client = _FakeBrowserStorageClient(
      failPersisted: true,
      failEstimate: true,
      requestResult: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserStorageStatusCard(
            service: BrowserStorageStatusService(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Persistent storage status is unavailable'),
      findsOneWidget,
    );
    expect(find.text('Persistent storage is not enabled'), findsNothing);
    expect(find.text('Storage usage estimate is unavailable'), findsOneWidget);
  });

  testWidgets('explains that pending encrypted changes live in this browser', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserStorageStatusCard(
            pendingCount: 2,
            service: BrowserStorageStatusService(
              client: _FakeBrowserStorageClient(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        '2 encrypted changes are waiting in this browser’s local outbox. The server has not acknowledged them; clearing this site’s browser data before sync removes them from this browser.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('browser_storage_pending_outbox_warning')),
      findsOneWidget,
    );
  });

  testWidgets('request-only browser APIs still render the request action', (
    tester,
  ) async {
    final client = _FakeBrowserStorageClient(
      supportsPersistenceRead: false,
      supportsEstimate: false,
      requestResult: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserStorageStatusCard(
            service: BrowserStorageStatusService(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Persistent storage status is unavailable'),
      findsOneWidget,
    );
    final requestButton = find.byKey(const ValueKey('browser_storage_request'));
    expect(requestButton, findsOneWidget);
    await tester.tap(requestButton);
    await tester.pumpAndSettle();
    expect(client.requestCalls, 1);
    expect(
      find.text(
        'The request returned success, but the current persistence status could not be verified.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not render on platforms without browser storage APIs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserStorageStatusCard(
            service: BrowserStorageStatusService(
              client: _FakeBrowserStorageClient.unavailable(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('browser_storage_status_card')),
      findsNothing,
    );
    expect(find.text('Browser storage'), findsNothing);
  });
}

class _FakeBrowserStorageClient implements BrowserStorageClient {
  _FakeBrowserStorageClient({
    List<bool>? persistedValues,
    this.requestResult = false,
    this.supportsPersistenceRead = true,
    this.supportsEstimate = true,
    this.estimateValue = const BrowserStorageEstimate(
      usageBytes: 1024,
      quotaBytes: 4096,
    ),
    this.failPersisted = false,
    this.failEstimate = false,
  }) : _persistedValues = persistedValues ?? [false],
       _available = true;

  _FakeBrowserStorageClient.unavailable()
    : _persistedValues = const [],
      requestResult = false,
      supportsPersistenceRead = false,
      supportsEstimate = false,
      estimateValue = const BrowserStorageEstimate(
        usageBytes: 0,
        quotaBytes: 0,
      ),
      failPersisted = false,
      failEstimate = false,
      _available = false;

  final List<bool> _persistedValues;
  final bool _available;
  final bool requestResult;
  final bool supportsPersistenceRead;
  final bool supportsEstimate;
  final BrowserStorageEstimate estimateValue;
  final bool failPersisted;
  final bool failEstimate;
  int persistedCalls = 0;
  int requestCalls = 0;

  @override
  bool get canEstimate => _available && supportsEstimate;

  @override
  bool get canReadPersistence => _available && supportsPersistenceRead;

  @override
  bool get canRequestPersistence => _available;

  @override
  Future<BrowserStorageEstimate> estimate() async {
    if (failEstimate) throw StateError('synthetic estimate failure');
    return estimateValue;
  }

  @override
  Future<bool> persisted() async {
    persistedCalls++;
    if (failPersisted) throw StateError('synthetic persisted failure');
    return _persistedValues[persistedCalls - 1 < _persistedValues.length
        ? persistedCalls - 1
        : _persistedValues.length - 1];
  }

  @override
  Future<bool> requestPersistence() async {
    requestCalls++;
    return requestResult;
  }
}
