import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/window_geometry.dart';
import '../../ui/window_caption.dart';
import '../desktop_view.dart';
import 'desktop_window.dart';
import '../../l10n/l10n.dart';

/// A desktop-only child process: no profile, database, account, credentials
/// or protocol connection. It renders the parent's session.
class DesktopWindowPage extends StatefulWidget {
  const DesktopWindowPage({super.key, required this.launch, this.geometry});
  final DesktopWindowLaunch launch;
  final WindowGeometry? geometry;
  @override
  State<DesktopWindowPage> createState() => _DesktopWindowPageState();
}

class _DesktopWindowPageState extends State<DesktopWindowPage> {
  late final Future<MirroredDesktopSession> _connecting;
  MirroredDesktopSession? _session;
  bool _covering = false;
  final _view = GlobalKey<DesktopViewState>();

  WindowGeometry get _geometry => widget.geometry ?? WindowGeometry.instance;

  @override
  void initState() {
    super.initState();
    _connecting = connectDesktopWindow(widget.launch).then((session) async {
      if (!mounted) {
        unawaited(session.close());
        return session;
      }
      _session = session;
      final cover = session.coverMonitor;
      if (cover != null) {
        // Monitor windows fill their local monitor; failure keeps a normal
        // captioned window (for example after a display was disconnected).
        final covered = await _geometry.coverMonitor(cover);
        if (mounted) setState(() => _covering = covered);
      }
      return session;
    });
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MirroredDesktopSession>(
    future: _connecting,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _standby(Text(context.l10n.couldntOpenTheRemoteDesktopWindow));
      }
      final session = snapshot.data;
      if (session == null) return _standby(const CircularProgressIndicator());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) session.confirmReady();
      });
      final view = DesktopView(
        key: _view,
        session: session,
        viewport: session.viewport,
        // Captioned windows keep one navigation row: the menu sits in the
        // caption next to the window controls instead of over the desktop.
        embeddedMenu: _covering,
      );
      if (_covering) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(child: view),
              Positioned(
                top: 4,
                right: 48,
                child: IconButton(
                  key: const ValueKey('desktop_window_close'),
                  tooltip: context.l10n.closeThisMonitorWindow,
                  icon: const Icon(Icons.close),
                  // Close the native window through the guarded close path
                  // (mirror close → process exit), exactly like the caption
                  // close button; the parent session stays connected.
                  onPressed: () =>
                      unawaited(WindowChromeScope.of(context).close()),
                ),
              ),
            ],
          ),
        );
      }
      return Scaffold(
        body: Column(
          children: [
            WindowCaption(
              controller: WindowChromeScope.of(context),
              title: session.title,
              actions: [
                AnimatedBuilder(
                  animation: session,
                  builder: (context, _) {
                    final state = _view.currentState;
                    if (state == null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _view.currentState != null) {
                          setState(() {});
                        }
                      });
                      return const SizedBox(width: 40);
                    }
                    return state.menuButton();
                  },
                ),
              ],
            ),
            Expanded(child: view),
          ],
        ),
      );
    },
  );

  Widget _standby(Widget child) => Scaffold(
    body: Column(
      children: [
        WindowCaption(
          controller: WindowChromeScope.of(context),
          title: context.l10n.remoteDesktop,
        ),
        Expanded(child: Center(child: child)),
      ],
    ),
  );
}
