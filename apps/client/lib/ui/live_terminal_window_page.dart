import 'app_menu.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';
import '../terminal/live_terminal_window.dart';
import 'app_motion.dart';
import 'terminal_palette.dart';
import 'terminal_keybar.dart';
import 'wallpaper.dart';
import 'window_caption.dart';
import '../l10n/l10n.dart';

/// A terminal-only child process: no profile, database, account or SSH keys.
class LiveTerminalWindowPage extends StatefulWidget {
  const LiveTerminalWindowPage({super.key, required this.launch});
  final LiveTerminalWindowLaunch launch;
  @override
  State<LiveTerminalWindowPage> createState() => _LiveTerminalWindowPageState();
}

class _LiveTerminalWindowPageState extends State<LiveTerminalWindowPage> {
  late final Future<LiveTerminalWindowClient> _connecting;
  LiveTerminalWindowClient? _client;
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    _connecting = connectLiveTerminalWindow(widget.launch).then((client) {
      if (!mounted) {
        unawaited(client.close());
        return client;
      }
      _client = client;
      return client;
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    final client = _client;
    if (client != null) unawaited(client.close());
    super.dispose();
  }

  // Standby → live is a single fade (no movement, so the caption buttons stay
  // put). The terminal view is mounted once; later frames are untouched.
  @override
  Widget build(BuildContext context) => FutureBuilder<LiveTerminalWindowClient>(
    future: _connecting,
    builder: (context, snapshot) => MotionEntrance(
      key: const ValueKey('live_terminal_window_motion'),
      trigger: snapshot.hasError
          ? 'error'
          : snapshot.data == null
          ? 'standby'
          : 'live',
      duration: MotionDurations.standard,
      offset: Offset.zero,
      child: _phase(context, snapshot),
    ),
  );

  Widget _phase(
    BuildContext context,
    AsyncSnapshot<LiveTerminalWindowClient> snapshot,
  ) {
    if (snapshot.hasError) {
      return _standby(Text(context.l10n.couldntOpenTheTerminalWindowGo));
    }
    final client = snapshot.data;
    if (client == null) {
      return _standby(const CircularProgressIndicator());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && client.connected) client.confirmReady();
    });
    return AnimatedBuilder(
      animation: client,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: ListenableBuilder(
                    listenable: WindowChromeScope.of(context),
                    builder: (context, row) => SizedBox(
                      height: WindowBarMetrics.of(
                        context,
                        WindowChromeScope.of(context),
                      ).height,
                      child: row,
                    ),
                    child: Row(
                      children: [
                        ListenableBuilder(
                          listenable: WindowChromeScope.of(context),
                          builder: (context, _) {
                            final inset = WindowChromeScope.of(
                              context,
                            ).state.leadingInset;
                            return SizedBox(width: inset > 0 ? inset : 12);
                          },
                        ),
                        const Icon(Icons.terminal, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: WindowDragArea(
                            controller: WindowChromeScope.of(context),
                            child: Text(
                              client.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            client.connected
                                ? context.l10n.originalSshSessionLive
                                : context.l10n.connectionLostReturnToTheOriginal,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        PopupMenuButton<String>(
                          popUpAnimationStyle: AppMotion.menuStyle(context),
                          tooltip: context.l10n.tools,
                          onSelected: (value) {
                            if (value == 'files') {
                              client.openFiles();
                            }
                            if (value == 'properties') {
                              showAppDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(context.l10n.terminalProperties),
                                  content: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(client.title),
                                      const SizedBox(height: 12),
                                      Text(
                                        client.connected
                                            ? context
                                                  .l10n
                                                  .originalSshSessionConnected
                                            : context.l10n.connectionLost,
                                      ),
                                      Text(
                                        context
                                            .l10n
                                            .thisWindowKeepsUsingTheOriginal,
                                      ),
                                    ],
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text(context.l10n.close2),
                                    ),
                                  ],
                                ),
                              );
                            }
                          },
                          itemBuilder: (_) => [
                            appMenuItem(context,
                              value: 'files',
                              child: Text(context.l10n.filesSftpScp),
                            ),
                            appMenuItem(context,
                              value: 'properties',
                              child: Text(context.l10n.properties),
                            ),
                          ],
                        ),
                        if (client.historyTruncated)
                          Tooltip(
                            message: context
                                .l10n
                                .earlierOutputExceedsThisWindowsDisplay,
                            child: const Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: const Icon(Icons.history, size: 18),
                            ),
                          ),
                        WindowCaptionControls(
                          controller: WindowChromeScope.of(context),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: WallpaperPaneBackdrop(
                    child: TerminalView(
                    client.terminal,
                    // Credential-free child window: no Vault preference is
                    // available, so it uses this device's palette overlay or
                    // the default (grass-green text) palette.
                    theme: terminalColorThemeOf(
                      context,
                      VaultPreferenceRecord.defaultTerminalTheme,
                    ),
                    autofocus: true,
                    focusNode: _focus,
                    readOnly: !client.connected,
                    hardwareKeyboardOnly: false,
                    showKeyboardOnTap: !terminalTouchKeyboardOnDemand,
                    padding: const EdgeInsets.all(12),
                    backgroundOpacity:
                        wallpaperTerminalBackgroundOpacity(context),
                    textStyle: const TerminalStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
                  ),
                ),
                TerminalKeybar(
                  terminal: client.terminal,
                  focusNode: _focus,
                  readOnly: !client.connected,
                  availablePaneHeight: constraints.maxHeight - 48,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _standby(Widget child) => Scaffold(
    body: Column(
      children: [
        WindowCaption(
          controller: WindowChromeScope.of(context),
          title: context.l10n.terminal,
        ),
        Expanded(child: Center(child: child)),
      ],
    ),
  );
}
