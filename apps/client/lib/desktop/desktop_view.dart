import '../ui/app_menu.dart';
import '../ui/fullscreen_menu.dart';
import '../platform/fullscreen.dart';
import '../domain/models.dart';
import 'desktop_mobile_controls.dart';
import 'desktop_touch_input.dart';
import '../ui/app_motion.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_display.dart';
import 'desktop_resolution.dart';
import 'desktop_resolution_dialog.dart';
import 'desktop_session.dart';
import 'local/local_desktop.dart';
import '../l10n/l10n.dart';
import '../ui/app_density.dart';

class DesktopView extends StatefulWidget {
  const DesktopView({
    required this.session,
    super.key,
    this.onDetach,
    this.onOpenMonitorWindows,
    this.viewport,
    this.embeddedMenu = true,
  });
  final DesktopSession session;

  /// Move this session into its own window (provided by the hosting page).
  final VoidCallback? onDetach;

  /// Open one window per remote monitor (multi-monitor sessions only).
  final VoidCallback? onOpenMonitorWindows;

  /// Show only this rectangle of the remote desktop (a monitor window).
  final Rect? viewport;

  /// False when the host places [DesktopViewState.menuButton] elsewhere.
  final bool embeddedMenu;
  @override
  State<DesktopView> createState() => DesktopViewState();
}

class DesktopViewState extends State<DesktopView> with WidgetsBindingObserver {
  final _mobile = GlobalKey<DesktopMobileControlsState>();
  bool _keyboardOpen = false;
  late final DesktopTouchInput _touch;
  bool get _mobilePlatform =>
      Theme.of(context).platform == TargetPlatform.android;
  void _sendMouse(Offset point, int buttons) {
    _buttons = buttons;
    session.display.movePointer(point);
    session.send(['mouse', point.dx.round(), point.dy.round(), buttons]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _touch.reset();
      _release();
    }
  }

  final _focus = FocusNode();
  final Map<PhysicalKeyboardKey, int> _pressed = {};
  int _buttons = 0;
  Size? _lastSize;
  int _generation = -1;
  Offset _panLimit = Offset.zero;
  Size _panArea = Size.zero;

  Widget _panBar(Axis axis, {double bottomInset = 0}) {
    final horizontal = axis == Axis.horizontal;
    final limit = horizontal ? _panLimit.dx : _panLimit.dy;
    final extent = horizontal ? _panArea.width : _panArea.height;
    if (limit <= 0 || extent <= 0) {
      // Must stay positioned: a non-positioned child would size the Stack.
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
    final thumb = math.max(32.0, extent * extent / (extent + limit));
    final position =
        (horizontal ? _pan.dx : _pan.dy) / limit * (extent - thumb);
    final color = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.45);
    return Positioned(
      left: horizontal ? position : null,
      top: horizontal ? null : position,
      right: horizontal ? null : 2,
      bottom: horizontal ? 2 + bottomInset : null,
      child: GestureDetector(
        key: ValueKey('desktop_pan_${axis.name}'),
        onPanUpdate: (d) => setState(() {
          final delta =
              (horizontal ? d.delta.dx : d.delta.dy) /
              math.max(1, extent - thumb) *
              limit;
          _pan += horizontal ? Offset(delta, 0) : Offset(0, delta);
        }),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            width: horizontal ? thumb : 8,
            height: horizontal ? 8 : thumb,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }

  Offset _pan = Offset.zero;
  Timer? _resizeTimer;
  DialogRoute<void>? _certificateDialog;
  DesktopSession get session => widget.session;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _touch = DesktopTouchInput(
      pointer: () => session.display.pointer,
      send: _sendMouse,
    );
    _focus.addListener(_focusChanged);
    session.onNotice = _showNotice;
    session.onFilesSaved = _filesSaved;
    session.addListener(_certificateChanged);
    _certificateChanged();
  }

  void _filesSaved(List<String> paths) {
    final copied = writeClipboardFilePaths(paths);
    _showNotice(
      copied
          ? context.l10n.savedCountItemsAndPlacedThem(paths.length)
          : context.l10n.savedCountItems(paths.length),
    );
  }

  Future<void> _sendCopiedFiles() async {
    final paths = readClipboardFilePaths();
    if (paths.isEmpty) {
      _showNotice(context.l10n.thereAreNoCopiedFilesOn);
      return;
    }
    session.offerLocalFiles(paths);
  }

  Future<void> _pickFilesToSend() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = [
      for (final file in result?.files ?? const <PlatformFile>[])
        if (file.path != null) file.path!,
    ];
    if (paths.isNotEmpty && mounted) session.offerLocalFiles(paths);
  }

  Future<void> _saveRemoteFiles() async {
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.l10n.saveRemoteClipboardFiles,
    );
    if (folder != null && mounted) session.saveRemoteFiles(folder);
  }

  void _certificateChanged() {
    if (!mounted ||
        session.certificateRequest == null ||
        _certificateDialog != null)
      return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _certificateDialog != null) return;
      final reviewedSession = session;
      final request = reviewedSession.certificateRequest;
      if (request == null) return;
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = AppDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: reviewedSession,
          // The live dialog context shadows State.context: the owner can be
          // deactivated (pane closed) while this route is still animating out.
          builder: (context, _) => PopScope(
            canPop: !reviewedSession.savingCertificate,
            child: AlertDialog(
              key: const ValueKey('rdp_certificate_dialog'),
              title: Text(
                request.changed
                    ? context.l10n.rdpCertificateFingerprintChanged
                    : context.l10n.trustThisRdpCertificate,
              ),
              content: SizedBox(
                width: appDialogWidth(context, 520),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${request.host.address}:${request.host.port}'),
                      const SizedBox(height: 12),
                      Text(
                        request.changed
                            ? context.l10n.theServerCertificateDiffersFromThe
                            : context.l10n.thisCertificateIsntTrustedYetVerify,
                      ),
                      if (request.changed) ...[
                        const SizedBox(height: 16),
                        Text(context.l10n.savedSha256),
                        SelectableText(request.host.rdpCertificateSha256!),
                      ],
                      const SizedBox(height: 16),
                      Text(context.l10n.currentCertificateSha256),
                      SelectableText(request.sha256),
                      if (reviewedSession.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          reviewedSession.error!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: reviewedSession.savingCertificate
                      ? null
                      : () {
                          reviewedSession.rejectCertificate(request);
                          Navigator.of(dialogContext).pop();
                        },
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  key: const ValueKey('rdp_certificate_accept'),
                  onPressed: reviewedSession.savingCertificate
                      ? null
                      : () async {
                          final accepted = await reviewedSession
                              .trustCertificate(request);
                          if (accepted && dialogContext.mounted)
                            Navigator.of(dialogContext).pop();
                        },
                  child: Text(
                    reviewedSession.savingCertificate
                        ? context.l10n.saving
                        : request.changed
                        ? context.l10n.updateAndConnect
                        : context.l10n.trustAndSave,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      _certificateDialog = route;
      unawaited(
        navigator.push(route).whenComplete(() {
          if (identical(_certificateDialog, route)) _certificateDialog = null;
          if (!mounted) return;
          reviewedSession.rejectCertificate(request);
          _certificateChanged();
        }),
      );
    });
  }

  void _removeCertificateDialog() {
    final route = _certificateDialog;
    _certificateDialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  void _showNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void didUpdateWidget(covariant DesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, session)) {
      _mobile.currentState?.releaseInput(notify: false);
      _keyboardOpen = false;
      _release(oldWidget.session);
      oldWidget.session.removeListener(_certificateChanged);
      _removeCertificateDialog();
      if (oldWidget.session.onNotice == _showNotice)
        oldWidget.session.onNotice = null;
      if (oldWidget.session.onFilesSaved == _filesSaved) {
        oldWidget.session.onFilesSaved = null;
      }
      session.onNotice = _showNotice;
      session.onFilesSaved = _filesSaved;
      session.addListener(_certificateChanged);
      _certificateChanged();
    }
  }

  void _focusAfterActivation() {
    _focus.requestFocus();
    // Pane selection removes ExcludeFocus on the next build. A single click
    // must focus the newly active desktop after that update has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _focusChanged() {
    if (!_focus.hasFocus) {
      _touch.reset();
      _release();
    }
  }

  void _release([DesktopSession? target]) {
    final receiver = target ?? session;
    for (final key in _pressed.values) {
      receiver.send(['key', key, 0]);
    }
    _pressed.clear();
    _buttons = 0;
    receiver.send([
      'mouse',
      receiver.display.pointer.dx.round(),
      receiver.display.pointer.dy.round(),
      0,
    ]);
  }

  @override
  void dispose() {
    session.removeListener(_certificateChanged);
    _removeCertificateDialog();
    if (session.onNotice == _showNotice) session.onNotice = null;
    if (session.onFilesSaved == _filesSaved) session.onFilesSaved = null;
    WidgetsBinding.instance.removeObserver(this);
    _touch.dispose();
    _release();
    _resizeTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  final _menu = GlobalKey<PopupMenuButtonState<String>>();

  /// Ctrl+Alt+Home is kept local (as in the Windows Remote Desktop client) so
  /// the session menu is reachable from the keyboard while every other key
  /// goes to the remote computer.
  bool _isMenuShortcut(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.home &&
        keys.isControlPressed &&
        keys.isAltPressed;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_isMenuShortcut(event)) {
      // Release the modifiers already sent so the remote does not see them
      // held while the local menu is open.
      _release();
      _menu.currentState?.showButtonMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home &&
        event is! KeyUpEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.handled; // repeat of the menu shortcut
    }
    final mapped = desktopKeysym(event);
    if (event is KeyUpEvent) {
      final sym = _pressed.remove(event.physicalKey);
      if (sym != null) {
        session.send(['key', sym, 0]);
        if (!const {
          0xffe1,
          0xffe2,
          0xffe3,
          0xffe4,
          0xffe9,
          0xffea,
          0xffeb,
          0xffec,
        }.contains(sym)) {
          _mobile.currentState?.consumeModifiers();
        }
      }
    } else if (mapped != null) {
      _pressed[event.physicalKey] = mapped;
      session.send(['key', mapped, 1]);
    }
    return mapped == null ? KeyEventResult.ignored : KeyEventResult.handled;
  }

  void _resize(Size size) {
    // Monitor windows show a fixed region; fixed or server-chosen sizes are
    // never replaced by the widget bounds.
    if (session.state != 'connected' ||
        widget.viewport != null ||
        !session.followsWindowSize) {
      return;
    }
    if (_generation != session.displayGeneration) {
      _generation = session.displayGeneration;
      _lastSize = null;
    }
    final requested = Size(
      size.width.clamp(320, 4096).floorToDouble(),
      size.height.clamp(200, 4096).floorToDouble(),
    );
    if (_lastSize == requested) return;
    _lastSize = requested;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(
      const Duration(milliseconds: 250),
      () => session.send([
        'size',
        requested.width.toInt(),
        requested.height.toInt(),
      ]),
    );
  }

  /// The session menu. Embedded in the desktop corner by default; a child
  /// window places it in its caption row instead (one navigation row).
  Widget menuButton() {
    return PopupMenuButton<String>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      key: _menu,
      tooltip: context.l10n.remoteDesktopMenu,
      icon: const Icon(Icons.more_horiz),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) async {
        if (value == 'fullscreen') {
          await toggleAppFullscreen(context);
        } else if (value == 'cad') {
          for (final key in [65507, 65513, 65535]) {
            session.send(['key', key, 1]);
          }
          for (final key in [65535, 65513, 65507]) {
            session.send(['key', key, 0]);
          }
        } else if (value == 'paste') {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (!mounted || data?.text == null) return;
          try {
            session.paste(data!.text!);
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  error is FormatException
                      ? error.message
                      : context.l10n.couldntSendClipboardText,
                ),
              ),
            );
          }
        } else if (value == 'copy') {
          await Clipboard.setData(
            ClipboardData(text: session.display.clipboard),
          );
        } else if (value == 'send_copied_files') {
          await _sendCopiedFiles();
        } else if (value == 'send_files') {
          await _pickFilesToSend();
        } else if (value == 'save_files') {
          await _saveRemoteFiles();
        } else if (value == 'display') {
          if (mounted) await showDesktopResolutionDialog(context, session);
        } else if (value == 'detach') {
          widget.onDetach?.call();
        } else if (value == 'monitors') {
          widget.onOpenMonitorWindows?.call();
        }
        if (mounted) _focus.requestFocus();
      },
      onOpened: () => unawaited(FullscreenController.instance.refresh()),
      itemBuilder: (_) => [
        if (FullscreenController.instance.supported)
          appMenuItem(
            context,
            key: const ValueKey('desktop_fullscreen_menu'),
            value: 'fullscreen',
            enabled: !FullscreenController.instance.busy,
            child: Text(
              FullscreenController.instance.enabled
                  ? context.l10n.exitFullscreen
                  : context.l10n.enterFullscreen,
            ),
          ),
        appMenuItem(
          context,
          value: 'cad',
          enabled: session.state == 'connected',
          child: Text(context.l10n.sendCtrlAltDelete),
        ),
        const PopupMenuDivider(height: 8),
        appMenuItem(
          context,
          value: 'paste',
          enabled: session.state == 'connected',
          child: Text(context.l10n.pasteLocalClipboardText),
        ),
        appMenuItem(
          context,
          value: 'copy',
          child: Text(context.l10n.copyRemoteClipboardText),
        ),
        if (session.protocol != null) const PopupMenuDivider(height: 8),
        if (session.protocol != null)
          appMenuItem(
            context,
            key: const ValueKey('desktop_display_menu'),
            value: 'display',
            enabled: session.state == 'connected',
            child: Text(context.l10n.resolutionAndScaling2),
          ),
        if (session.fileClipboardEnabled) ...[
          const PopupMenuDivider(height: 8),
          if (supportsFileClipboardInterop)
            appMenuItem(
              context,
              value: 'send_copied_files',
              enabled: session.state == 'connected',
              child: Text(context.l10n.sendLocallyCopiedFiles),
            ),
          appMenuItem(
            context,
            value: 'send_files',
            enabled: session.state == 'connected',
            child: Text(context.l10n.chooseFilesForTheRemoteClipboard),
          ),
          appMenuItem(
            context,
            key: const ValueKey('rdp_save_remote_files'),
            value: 'save_files',
            enabled:
                session.state == 'connected' &&
                session.remoteFiles != null &&
                session.transfer == null,
            child: Text(
              session.remoteFiles == null
                  ? context.l10n.saveRemoteClipboardFiles2
                  : context.l10n.saveRemoteClipboardFilesFilecountFiles(
                      session.remoteFiles!.fileCount,
                      formatTransferBytes(session.remoteFiles!.totalBytes),
                    ),
            ),
          ),
        ],
        if (widget.onDetach != null || widget.onOpenMonitorWindows != null)
          const PopupMenuDivider(height: 8),
        if (widget.onDetach != null)
          appMenuItem(
            context,
            value: 'detach',
            child: Text(context.l10n.openInNewWindow),
          ),
        if (widget.onOpenMonitorWindows != null &&
            (session.rdpConfig?.monitors.length ?? 0) > 1)
          appMenuItem(
            context,
            value: 'monitors',
            child: Text(context.l10n.oneWindowPerMonitor),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, pane) {
      final keybarHeight = _mobilePlatform && _keyboardOpen
          ? (pane.maxHeight >= 280 ? 96.0 : 48.0)
          : 0.0;
      return AnimatedBuilder(
        animation: Listenable.merge([
          session,
          session.display,
          FullscreenController.instance,
        ]),
        builder: (context, _) => Stack(
          children: [
            Positioned.fill(
              bottom: keybarHeight,
              child: LayoutBuilder(
                key: const ValueKey('desktop_remote_surface'),
                builder: (context, constraints) {
                  final area = constraints.biggest;
                  _resize(area);
                  final viewport = widget.viewport;
                  final origin = viewport?.topLeft ?? Offset.zero;
                  final size = viewport?.size ?? session.display.size;
                  final actual =
                      viewport == null &&
                      session.localScaling == DesktopLocalScaling.actualSize;
                  final double scale = actual
                      ? 1.0
                      : math.min(
                          area.width / math.max(1, size.width),
                          area.height / math.max(1, size.height),
                        );
                  final maxPan = Offset(
                    math.max(0, size.width - area.width),
                    math.max(0, size.height - area.height),
                  );
                  _pan = actual
                      ? Offset(
                          _pan.dx.clamp(0, maxPan.dx),
                          _pan.dy.clamp(0, maxPan.dy),
                        )
                      : Offset.zero;
                  final offset = actual
                      ? Offset(
                          maxPan.dx > 0
                              ? -_pan.dx
                              : (area.width - size.width) / 2,
                          maxPan.dy > 0
                              ? -_pan.dy
                              : (area.height - size.height) / 2,
                        )
                      : Offset(
                          (area.width - size.width * scale) / 2,
                          (area.height - size.height * scale) / 2,
                        );
                  void mouse(PointerEvent event, {int? wheel}) {
                    if (_mobilePlatform &&
                        _touch.trackpad &&
                        event.kind == PointerDeviceKind.touch) {
                      if (event is PointerDownEvent) _focusAfterActivation();
                      _touch.handle(event, bounds: origin & size, scale: scale);
                      return;
                    }
                    final point =
                        origin +
                        Offset(
                          ((event.localPosition.dx - offset.dx) / scale).clamp(
                            0,
                            math.max(0, size.width - 1),
                          ),
                          ((event.localPosition.dy - offset.dy) / scale).clamp(
                            0,
                            math.max(0, size.height - 1),
                          ),
                        );
                    if (event is PointerDownEvent) _focusAfterActivation();
                    _buttons =
                        (event.buttons & kPrimaryButton != 0 ? 1 : 0) |
                        (event.buttons & kSecondaryButton != 0 ? 4 : 0) |
                        (event.buttons & kMiddleMouseButton != 0 ? 2 : 0);
                    session.display.movePointer(point);
                    session.send([
                      'mouse',
                      point.dx.round(),
                      point.dy.round(),
                      _buttons | (wheel ?? 0),
                    ]);
                    if (wheel != null)
                      session.send([
                        'mouse',
                        point.dx.round(),
                        point.dy.round(),
                        _buttons,
                      ]);
                  }

                  final limit = actual ? maxPan : Offset.zero;
                  if (limit != _panLimit || area != _panArea) {
                    // Pan bars live outside this LayoutBuilder; refresh them once
                    // layout has produced the new bounds.
                    _panLimit = limit;
                    _panArea = area;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() {});
                    });
                  }
                  return Focus(
                    focusNode: _focus,
                    autofocus: true,
                    onKeyEvent: _key,
                    child: MouseRegion(
                      cursor: session.isDirect
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.none,
                      child: Listener(
                        onPointerDown: mouse,
                        onPointerUp: mouse,
                        onPointerMove: mouse,
                        onPointerHover: mouse,
                        onPointerCancel: (_) {
                          _touch.reset();
                          _release();
                        },
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            GestureBinding.instance.pointerSignalResolver
                                .register(
                                  e,
                                  (_) => mouse(
                                    e,
                                    wheel: e.scrollDelta.dy < 0 ? 8 : 16,
                                  ),
                                );
                          }
                        },
                        child: ClipRect(
                          child: CustomPaint(
                            size: area,
                            painter: _DesktopPainter(
                              session.display,
                              scale,
                              offset - origin * scale,
                              clip: viewport == null
                                  ? null
                                  : offset & (size * scale),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            _panBar(Axis.horizontal, bottomInset: keybarHeight),
            _panBar(Axis.vertical),
            if (session.error != null && session.certificateRequest == null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.l10n.connectionLost,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          session.error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        if (session.state == 'disconnected' &&
                            session.canReconnect) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            key: const ValueKey('desktop_restore_connection'),
                            onPressed: session.reconnect,
                            icon: const Icon(Icons.refresh),
                            label: Text(context.l10n.restoreConnection),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            if (session.state == 'connecting')
              const Center(child: CircularProgressIndicator()),
            if (session.transfer != null)
              Positioned(
                left: 12,
                right: 56,
                top: 8,
                child: Material(
                  key: const ValueKey('rdp_file_transfer'),
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.savingRemoteFilesDoneTotal(
                                  session.transfer!.done,
                                  session.transfer!.total,
                                ),
                              ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: session.transfer!.total == 0
                                    ? null
                                    : session.transfer!.done /
                                          session.transfer!.total,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: context.l10n.cancel,
                          icon: const Icon(Icons.close),
                          onPressed: session.cancelFileTransfer,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_mobilePlatform)
              Positioned.fill(
                child: DesktopMobileControls(
                  key: _mobile,
                  focus: _focus,
                  unicodeText: session.protocol != HostProtocol.vnc,
                  onActivate: _focusAfterActivation,
                  send: session.send,
                  connected: session.state == 'connected',
                  trackpad: _touch.trackpad,
                  keybarHeight: keybarHeight,
                  menu: widget.embeddedMenu ? menuButton() : null,
                  onKeyboardChanged: (value) {
                    if (mounted && _keyboardOpen != value)
                      setState(() => _keyboardOpen = value);
                  },
                  onTogglePointer: () {
                    _focusAfterActivation();
                    _touch.reset();
                    _release();
                    setState(() => _touch.trackpad = !_touch.trackpad);
                  },
                ),
              ),
            if (widget.embeddedMenu && !_mobilePlatform)
              Positioned(
                top: 4,
                right: 4,
                // A translucent backing keeps the control visible over any remote
                // content (light or dark desktops).
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh
                      .withValues(alpha: 0.78),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: menuButton(),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _DesktopPainter extends CustomPainter {
  _DesktopPainter(this.display, this.scale, this.offset, {this.clip})
    : super(repaint: display);
  final DesktopDisplay display;
  final double scale;
  final Offset offset;
  final Rect? clip;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.black, BlendMode.src);
    canvas.save();
    if (clip != null) canvas.clipRect(clip!);
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    display.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DesktopPainter old) =>
      old.scale != scale ||
      old.offset != offset ||
      old.clip != clip ||
      old.display != display;
}

/// X11 keysyms are shared by the Guacamole RDP and VNC clients.
int? desktopKeysym(KeyEvent event) {
  final key = event.logicalKey;
  final special = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.backspace: 0xff08,
    LogicalKeyboardKey.tab: 0xff09,
    LogicalKeyboardKey.enter: 0xff0d,
    LogicalKeyboardKey.numpadEnter: 0xff8d,
    LogicalKeyboardKey.escape: 0xff1b,
    LogicalKeyboardKey.delete: 0xffff,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.arrowLeft: 0xff51,
    LogicalKeyboardKey.arrowUp: 0xff52,
    LogicalKeyboardKey.arrowRight: 0xff53,
    LogicalKeyboardKey.arrowDown: 0xff54,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.shiftLeft: 0xffe1,
    LogicalKeyboardKey.shiftRight: 0xffe2,
    LogicalKeyboardKey.controlLeft: 0xffe3,
    LogicalKeyboardKey.controlRight: 0xffe4,
    LogicalKeyboardKey.altLeft: 0xffe9,
    LogicalKeyboardKey.altRight: 0xffea,
    LogicalKeyboardKey.metaLeft: 0xffeb,
    LogicalKeyboardKey.metaRight: 0xffec,
    LogicalKeyboardKey.capsLock: 0xffe5,
    LogicalKeyboardKey.numLock: 0xff7f,
    LogicalKeyboardKey.f1: 0xffbe,
    LogicalKeyboardKey.f2: 0xffbf,
    LogicalKeyboardKey.f3: 0xffc0,
    LogicalKeyboardKey.f4: 0xffc1,
    LogicalKeyboardKey.f5: 0xffc2,
    LogicalKeyboardKey.f6: 0xffc3,
    LogicalKeyboardKey.f7: 0xffc4,
    LogicalKeyboardKey.f8: 0xffc5,
    LogicalKeyboardKey.f9: 0xffc6,
    LogicalKeyboardKey.f10: 0xffc7,
    LogicalKeyboardKey.f11: 0xffc8,
    LogicalKeyboardKey.f12: 0xffc9,
  };
  if (special.containsKey(key)) return special[key];
  final char = event.character;
  if (char != null && char.runes.length == 1 && char.runes.first >= 32) {
    final rune = char.runes.first;
    return rune <= 255 ? rune : 0x01000000 | rune;
  }
  if (key.keyLabel.runes.length == 1)
    return key.keyLabel.toLowerCase().runes.first;
  return null;
}

/// Compact byte count for consent labels (B, KB, MB, GB, TB).
String formatTransferBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes B'
      : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
