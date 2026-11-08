import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_system_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const host = HostRecord(
    id: 'host',
    name: 'Ubuntu Windows macOS',
    address: 'windows.example',
    username: 'demo',
  );
  testWidgets(
    'unknown hosts use server icon without guessing from name or address',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HostSystemIcon(host: host)),
        ),
      );
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      expect(find.byTooltip('Operating system not identified yet'), findsOneWidget);
    },
  );
  testWidgets(
    'all observed families paint locally and expose actual version text',
    (tester) async {
      for (final family in HostOperatingSystemFamily.values) {
        final observed = host.copyWithDetectedOperatingSystem(
          HostOperatingSystem(
            family: family,
            displayName: 'Observed ${family.name}',
            version: '12.3',
            detectedAt: DateTime.utc(2026, 11, 6),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: HostSystemIcon(host: observed, size: 20)),
          ),
        );
        expect(
          find.byTooltip('Observed ${family.name} · 12.3'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
