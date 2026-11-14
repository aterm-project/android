import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'keyboard_capture.dart';

/// "Full keyboard mapping": when system shortcuts go to the remote computer.
class KeyboardCaptureSettings extends StatefulWidget {
  const KeyboardCaptureSettings({super.key});
  @override
  State<KeyboardCaptureSettings> createState() =>
      _KeyboardCaptureSettingsState();
}

class _KeyboardCaptureSettingsState extends State<KeyboardCaptureSettings>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(KeyboardCaptureController.instance.refreshState());
  }

  /// Accessibility access is granted in System Settings, outside the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(KeyboardCaptureController.instance.refreshState());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: KeyboardCaptureController.instance,
    builder: (context, _) {
      final controller = KeyboardCaptureController.instance;
      final l10n = context.l10n;
      // Each runner captures a different set of keys (iOS only re-routes
      // Tab, Space and arrow combinations), so each platform says what it does.
      final description = switch (Theme.of(context).platform) {
        TargetPlatform.windows => l10n.keyboardCaptureWindowsDescription,
        TargetPlatform.macOS => l10n.keyboardCaptureMacDescription,
        TargetPlatform.iOS => l10n.keyboardCaptureIosDescription,
        _ => l10n.keyboardCaptureAndroidDescription,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.keyboardCaptureTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<KeyboardCaptureMode>(
            key: const ValueKey('keyboard_capture_mode'),
            initialValue: controller.mode,
            isExpanded: true,
            decoration: InputDecoration(labelText: l10n.keyboardCaptureTitle),
            items: [
              DropdownMenuItem(
                value: KeyboardCaptureMode.off,
                child: Text(l10n.keyboardCaptureOff),
              ),
              DropdownMenuItem(
                value: KeyboardCaptureMode.fullscreen,
                child: Text(l10n.keyboardCaptureFullscreen),
              ),
              DropdownMenuItem(
                value: KeyboardCaptureMode.focused,
                child: Text(l10n.keyboardCaptureFocused),
              ),
            ],
            onChanged: (value) {
              if (value != null) unawaited(controller.select(value));
            },
          ),
          const SizedBox(height: 8),
          Text(description),
          const SizedBox(height: 4),
          Text(l10n.keyboardCaptureCtrlAltDelete),
          if (controller.permission == KeyboardCapturePermission.required) ...[
            const SizedBox(height: 12),
            Text(l10n.keyboardCapturePermissionRequired),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                key: const ValueKey('keyboard_capture_permission'),
                onPressed: () => unawaited(controller.requestPermission()),
                child: Text(l10n.keyboardCaptureGrantPermission),
              ),
            ),
          ],
          if (controller.supported == false) ...[
            const SizedBox(height: 8),
            Text(l10n.keyboardCaptureUnsupported),
          ],
          if (controller.writeFailed) Text(l10n.desktopKeyboardSaveFailed),
        ],
      );
    },
  );
}
