import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/api_client.dart';
import '../domain/models.dart';
import '../ssh/ssh_transport.dart' as transport;
import 'desktop_display.dart';
import 'direct/connection.dart';
import 'direct/rfb.dart';
import 'direct/rdp.dart';
import 'guacamole_protocol.dart';
import 'desktop_resolution.dart';
import 'local/local_desktop.dart';
import 'rdp_features.dart';
import 'rdp_settings.dart';
import '../l10n/l10n.dart';

class RdpCertificateRequest {
  RdpCertificateRequest({required this.host, required this.sha256});
  final HostRecord host;
  final String sha256;
  bool get changed => host.rdpCertificateSha256 != null;
}

class DesktopSession extends ChangeNotifier {
  DesktopSession({
    this.onErrorForTesting,
    this.saveRdpCertificate,
    this.directConnectionForTesting,
    this.saveDisplaySettings,
    this.reconnectAllowed,
  });

  /// Persists in-session display changes to the Host (optional). Must apply
  /// revision checks like certificate persistence; failures keep the change
  /// for this session only.
  final Future<HostRecord> Function(HostRecord updated)? saveDisplaySettings;
  final Future<HostRecord> Function(HostRecord host, String sha256)?
  saveRdpCertificate;
  @visibleForTesting
  final DirectDesktopConnection Function(HostRecord host)?
  directConnectionForTesting;

  /// Whether this client connects to [protocol] Hosts itself (no gateway).
  /// Android is direct-only: desktops never go through a local or server
  /// gateway there. RDP uses the engine packaged in the APK, and
  /// [connectLocal] reports plainly when an APK was built without it.
  static bool supportsDirect(HostProtocol protocol) =>
      !kIsWeb &&
      (protocol == HostProtocol.vnc ||
          (protocol == HostProtocol.rdp &&
              (bundledRdpAvailable ||
                  defaultTargetPlatform == TargetPlatform.android)));
  @visibleForTesting
  final void Function(Object)? onErrorForTesting;
  final display = DesktopDisplay();
  WebSocketChannel? _channel;
  void Function(List<int>)? _write;
  Future<void> Function()? _closeTransport;
  StreamSubscription<List<String>>? _subscription;
  Timer? _setupTimeout;
  bool _closed = false;
  bool _disposed = false, _reconnecting = false;
  Future<void>? _closing;
  Future<void> Function()? _reconnect;
  final bool Function()? reconnectAllowed;
  bool get canReconnect =>
      !_disposed && _reconnect != null && (reconnectAllowed?.call() ?? true);

  Future<void> reconnect() async {
    if (!canReconnect || _reconnecting || state != 'disconnected') return;
    _reconnecting = true;
    try {
      await close();
      if (!canReconnect) return;
      _closed = false;
      _closing = null;
      error = null;
      state = 'connecting';
      displayGeneration++;
      notifyListeners();
      await _reconnect!();
    } finally {
      _reconnecting = false;
    }
  }

  DirectDesktopConnection? _direct;
  StreamSubscription<DesktopEvent>? _directSubscription;
  final Queue<DesktopFrame> _pendingFrames = Queue();
  final _frameUpdates = StreamController<DesktopFrame>.broadcast(sync: true);
  bool _painting = false;

  /// Applied framebuffer updates, in order, after they reach [display].
  /// Detached windows mirror the session from this stream.
  Stream<DesktopFrame> get frameUpdates => _frameUpdates.stream;

  /// Native options used for the current RDP attempt (null for VNC/gateway).
  RdpNativeConfig? rdpConfig;

  /// Files the remote clipboard currently offers (empty when none).
  DesktopRemoteFiles? remoteFiles;

  /// Latest clipboard file download progress; null when idle.
  DesktopFileTransfer? transfer;

  /// Called with top-level paths after a download finishes.
  ValueChanged<List<String>>? onFilesSaved;
  bool _clipboardText = true;
  HostRecord? _host;
  RdpSettings _rdp = RdpSettings.defaults;
  VncSettings _vnc = VncSettings.defaults;

  /// Null until the server reports whether it can change resolution.
  bool? serverResize;
  DesktopResizeResult? lastResize;

  /// Bumped when the resize policy changes so views re-send their size.
  int displayGeneration = 0;
  HostProtocol? get protocol => _host?.protocol;
  RdpSettings get rdpSettings => _rdp;
  VncSettings get vncSettings => _vnc;
  DesktopLocalScaling get localScaling =>
      _host?.protocol == HostProtocol.vnc ? _vnc.scaling : _rdp.scaling;

  /// Whether the view should request the remote size to follow the window.
  bool get followsWindowSize => switch (_host?.protocol) {
    HostProtocol.rdp =>
      _rdp.resolution == RdpResolutionMode.fitWindow &&
          (rdpConfig?.monitors.isEmpty ?? true),
    HostProtocol.vnc =>
      _vnc.resolution == VncResolutionMode.fitWindow && serverResize == true,
    _ => _direct == null, // gateway sessions keep their original behavior
  };

  /// Change the resolution for this session, and persist it when possible.
  /// [width]/[height] null selects automatic (fit window); [server] selects
  /// the VNC server-chosen size.
  Future<void> changeResolution({
    int? width,
    int? height,
    bool server = false,
  }) async {
    final host = _host;
    if (host == null || _closed) return;
    final fixed = width != null && height != null;
    if (fixed) {
      final issue = validateDesktopSize(width, height);
      if (issue != null) throw FormatException(issue);
    }
    if (host.protocol == HostProtocol.rdp) {
      if ((rdpConfig?.monitors.length ?? 0) > 1) {
        onNotice?.call(currentL10n.inAMultiMonitorSessionThe);
        return;
      }
      _rdp = fixed
          ? _rdp.copyWith(
              resolution: RdpResolutionMode.fixed,
              width: width,
              height: height,
            )
          : _rdp.copyWith(resolution: RdpResolutionMode.fitWindow);
      if (fixed) {
        if (serverResize == true) {
          send(['size', width, height, true]);
        } else {
          onNotice?.call(currentL10n.theServerDoesntOfferDynamicResolution);
        }
      }
    } else {
      _vnc = server
          ? _vnc.copyWith(resolution: VncResolutionMode.server)
          : fixed
          ? _vnc.copyWith(
              resolution: VncResolutionMode.fixed,
              width: width,
              height: height,
            )
          : _vnc.copyWith(resolution: VncResolutionMode.fitWindow);
      if (serverResize != true && !server) {
        onNotice?.call(currentL10n.thisVncServerDoesntSupportResizing);
      } else if (fixed) {
        send(['size', width, height, true]);
      } else if (server) {
        onNotice?.call(currentL10n.stoppedRequestingAResizeTheServer);
      }
    }
    displayGeneration++;
    notifyListeners();
    await _persistDisplay();
  }

  Future<void> setLocalScaling(DesktopLocalScaling scaling) async {
    if (_host == null || _closed) return;
    if (_host!.protocol == HostProtocol.vnc) {
      _vnc = _vnc.copyWith(scaling: scaling);
    } else {
      _rdp = _rdp.copyWith(scaling: scaling);
    }
    notifyListeners();
    await _persistDisplay();
  }

  Future<void> _persistDisplay() async {
    final host = _host, save = saveDisplaySettings;
    if (host == null || save == null) return;
    final manifest = host.protocol == HostProtocol.vnc
        ? _vnc.applyTo(host.manifest)
        : _rdp.applyTo(host.manifest);
    try {
      final saved = await save(
        host.copyWith(manifest: manifest, clearManifest: manifest == null),
      );
      if (!_closed && saved.id == host.id) _host = saved;
    } catch (_) {
      onNotice?.call(currentL10n.theResolutionSettingAppliesToThis);
    }
  }

  bool get fileClipboardEnabled =>
      rdpConfig?.text.contains('\nclipboard_files=1\n') == true;
  bool get isDirect => _direct != null;
  String state = 'connecting';
  String? error;
  ValueChanged<String>? onNotice;
  RdpCertificateRequest? certificateRequest;
  bool savingCertificate = false;
  int _directAttempt = 0;

  Future<bool> trustCertificate(RdpCertificateRequest request) async {
    if (_closed ||
        savingCertificate ||
        !identical(request, certificateRequest)) {
      return false;
    }
    savingCertificate = true;
    error = null;
    notifyListeners();
    try {
      final save = saveRdpCertificate;
      if (save == null)
        throw StateError(currentL10n.thisHostCantSaveCertificates);
      final saved = await save(request.host, request.sha256);
      if (_closed || !identical(request, certificateRequest)) return false;
      if (saved.id != request.host.id ||
          saved.address != request.host.address ||
          saved.port != request.host.port ||
          saved.protocol != HostProtocol.rdp ||
          saved.rdpCertificateSha256 != request.sha256) {
        throw StateError(currentL10n.theHostSettingsChangedReconnect);
      }
      _directAttempt++;
      final subscription = _directSubscription, connection = _direct;
      _directSubscription = null;
      _direct = null;
      await subscription?.cancel();
      await connection?.close();
      if (_closed) return false;
      certificateRequest = null;
      state = 'connecting';
      await connectLocal(saved);
      return true;
    } catch (_) {
      if (!_closed) error = currentL10n.theCertificateCouldntBeSavedThe;
      return false;
    } finally {
      savingCertificate = false;
      if (!_closed) notifyListeners();
    }
  }

  void rejectCertificate(RdpCertificateRequest request) {
    if (_closed || savingCertificate || !identical(request, certificateRequest))
      return;
    certificateRequest = null;
    _fail(currentL10n.thisRdpCertificateWasntTrustedThe);
  }

  Future<void> connect(ApiClient api, String deviceId, HostRecord host) async {
    _reconnect = () => connect(api, deviceId, host);
    try {
      if (host.protocol.isTerminal || host.validate() != null)
        throw const FormatException('Invalid desktop Host');
      final ticket = await api.createRelayTicket(
        deviceId: deviceId,
        targetHost: host.address,
        targetPort: host.port,
      );
      if (_closed) return;
      final relay = api.relayUri();
      final segments = relay.pathSegments.toList();
      segments[segments.length - 3] = 'desktop';
      final channel = WebSocketChannel.connect(
        relay.replace(pathSegments: segments),
      );
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      channel.sink.add(ticket.value);
      channel.sink.add(
        jsonEncode({
          'protocol': host.protocol.name,
          if (host.rdpCertificateSha256 != null)
            'certificate_sha256': host.rdpCertificateSha256,
          'username': host.username,
          'password': host.login?.password ?? '',
          'width': 1280,
          'height': 800,
        }),
      );
      _write = channel.sink.add;
      _closeTransport = () => channel.sink.close();
      _listen(
        channel.stream.map((event) {
          if (event is! List<int>)
            throw const FormatException('Invalid desktop frame');
          return event;
        }),
      );
    } catch (_) {
      _fail(currentL10n.unableToConnectCheckTheDesktop);
    }
  }

  /// Close code/reason of a gateway connection (e.g. 4403 revoked).
  int? gatewayCloseCode;
  String? gatewayCloseReason;

  /// Guest connection through the server's trusted share gateway. The
  /// gateway (not this client) chooses the target and holds the login; this
  /// session only renders the Guacamole stream and sends input, which the
  /// gateway filters by the link's permissions.
  Future<void> connectGateway({
    required Uri socketUri,
    required String ticket,
    int width = 1280,
    int height = 800,
    void Function(Map<String, dynamic> frame)? onControl,
  }) async {
    try {
      final channel = WebSocketChannel.connect(socketUri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      channel.sink.add(jsonEncode({'type': 'authenticate', 'ticket': ticket}));
      var opened = false;
      _write = channel.sink.add;
      _closeTransport = () => channel.sink.close();
      final stream = channel.stream.transform(
        StreamTransformer<dynamic, dynamic>.fromHandlers(
          handleDone: (sink) {
            gatewayCloseCode = channel.closeCode;
            gatewayCloseReason = channel.closeReason;
            sink.close();
          },
        ),
      );
      _listen(
        stream
            .where((event) {
              if (event is String) {
                final frame = jsonDecode(event);
                if (frame is Map<String, dynamic>) {
                  if (frame['type'] == 'authenticated' && !opened) {
                    opened = true;
                    channel.sink.add(
                      jsonEncode({
                        'type': 'open',
                        'width': width,
                        'height': height,
                      }),
                    );
                  }
                  onControl?.call(frame);
                }
                return false;
              }
              return true;
            })
            .map((event) {
              if (event is! List<int>) {
                throw const FormatException('Invalid gateway frame');
              }
              return event;
            }),
      );
    } catch (_) {
      _fail(currentL10n.unableToConnectCheckTheDesktop);
    }
  }

  Future<void> connectLocal(HostRecord host, {int? guacdPort}) async {
    _reconnect = () => connectLocal(_host ?? host, guacdPort: guacdPort);
    // An explicit port remains available to the gateway integration tests and
    // existing Linux installations. Native UI sessions use direct transports.
    if (directConnectionForTesting == null &&
        guacdPort == null &&
        host.protocol == HostProtocol.rdp &&
        !bundledRdpAvailable) {
      // Android cannot host a local guacd: RDP there uses only the engine
      // packaged in the APK, and an APK without it reports that plainly.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        _fail(currentL10n.couldntStartTheRdpEngineCheck);
        return;
      }
      await _connectLocalGateway(host, 4822);
      return;
    }
    if (guacdPort == null) {
      if (_closed) return;
      if (host.protocol.isTerminal || host.validate() != null) {
        _fail(currentL10n.invalidRemoteDesktopHostSettings);
        return;
      }
      final attempt = ++_directAttempt;
      // Redirection/security settings always come from the Host being
      // connected (the latest saved revision). Only an in-session display
      // choice survives a reconnect of the same Host (for example after
      // certificate approval).
      final sameHost = _host?.id == host.id && _host?.protocol == host.protocol;
      final rdp = host.protocol == HostProtocol.rdp
          ? RdpSettings.of(host)
          : RdpSettings.defaults;
      _rdp = sameHost
          ? rdp.copyWith(
              resolution: _rdp.resolution,
              width: _rdp.width,
              height: _rdp.height,
              scaling: _rdp.scaling,
            )
          : rdp;
      if (!sameHost) {
        _vnc = host.protocol == HostProtocol.vnc
            ? VncSettings.of(host)
            : VncSettings.defaults;
      }
      _host = host;
      serverResize = null;
      lastResize = null;
      String config = '';
      if (host.protocol == HostProtocol.rdp &&
          directConnectionForTesting == null) {
        try {
          config = _rdpConfigFor(host);
        } on FormatException catch (e) {
          _fail(currentL10n.invalidRdpOptionsMessage(e.message));
          return;
        }
      } else if (host.protocol == HostProtocol.rdp) {
        _rdpConfigFor(host, features: rdpFeaturesForTesting);
      }
      _direct =
          directConnectionForTesting?.call(host) ??
          (host.protocol == HostProtocol.vnc
              ? RfbConnection.connect(
                  host.address,
                  host.port,
                  host.login?.password ?? '',
                )
              : RdpConnection.connect(
                  host.address,
                  host.port,
                  host.username,
                  host.login?.password ?? '',
                  host.rdpCertificateSha256 ?? '',
                  config: config,
                ));
      _setupTimeout = Timer(
        const Duration(seconds: 35),
        () => _fail(currentL10n.theRemoteDesktopConnectionTimedOut),
      );
      _directSubscription = _direct!.events.listen(
        (event) {
          if (_closed || attempt != _directAttempt) {
            if (event is DesktopFrame) event.onConsumed?.call();
            return;
          }
          if (event is DesktopFrame) {
            if (event.full) {
              // A full frame supersedes every queued update.
              for (final frame in _pendingFrames) {
                frame.onConsumed?.call();
              }
              _pendingFrames.clear();
            }
            _pendingFrames.add(event);
            unawaited(_paintDirect());
          } else if (event is DesktopClipboard) {
            if (_clipboardText) display.clipboard = event.text;
          } else if (event is DesktopResizeStatus) {
            final first = serverResize != true && event.serverResize;
            serverResize = event.serverResize;
            if (event.result != null) {
              lastResize = event.result;
              final message = switch (event.result!) {
                DesktopResizeResult.applied => null,
                DesktopResizeResult.prohibited =>
                  currentL10n.theServerRefusedTheResize,
                DesktopResizeResult.outOfResources =>
                  currentL10n.theServerLacksTheResourcesFor,
                DesktopResizeResult.invalidLayout =>
                  currentL10n.theServerDoesntAcceptThisResolution,
                DesktopResizeResult.unsupported =>
                  currentL10n.theServerDoesntSupportResizingOnly2,
              };
              if (message != null) onNotice?.call(message);
            }
            if (first &&
                host.protocol == HostProtocol.vnc &&
                _vnc.resolution == VncResolutionMode.fixed) {
              send(['size', _vnc.width, _vnc.height, true]);
            }
            displayGeneration++;
            notifyListeners();
          } else if (event is DesktopRemoteFiles) {
            remoteFiles = event.names.isEmpty ? null : event;
            notifyListeners();
          } else if (event is DesktopFileTransfer) {
            transfer = event.finished ? null : event;
            if (event.error != null)
              onNotice?.call(
                currentL10n.couldntSaveRemoteFilesError('${event.error}'),
              );
            final saved = event.savedPaths;
            if (saved != null) onFilesSaved?.call(saved);
            notifyListeners();
          } else if (event is DesktopNotice) {
            onNotice?.call(event.text);
          }
        },
        onError: (Object error) {
          if (_closed || attempt != _directAttempt) return;
          onErrorForTesting?.call(error);
          if (error is RdpCertificateException &&
              host.protocol == HostProtocol.rdp) {
            _setupTimeout?.cancel();
            certificateRequest = RdpCertificateRequest(
              host: host,
              sha256: error.sha256,
            );
            state = 'certificate';
            this.error = null;
            notifyListeners();
            return;
          }
          _fail(
            error is FormatException
                ? error.message
                : error is StateError
                ? error.message.toString()
                : currentL10n.theRemoteDesktopConnectionFailed,
          );
        },
        onDone: () {
          if (attempt == _directAttempt && certificateRequest == null) {
            _fail(currentL10n.theRemoteDesktopConnectionClosed);
          }
        },
      );
      return;
    }
    await _connectLocalGateway(host, guacdPort);
  }

  Future<void> _paintDirect() async {
    if (_painting) return;
    _painting = true;
    try {
      while (!_closed && _pendingFrames.isNotEmpty) {
        final frame = _pendingFrames.removeFirst();
        try {
          await display.frame(
            frame.width,
            frame.height,
            frame.bgra,
            x: frame.x,
            y: frame.y,
            regionWidth: frame.regionWidth,
            regionHeight: frame.regionHeight,
          );
          if (!_closed) _frameUpdates.add(frame);
          if (!_closed && state != 'connected') {
            _setupTimeout?.cancel();
            state = 'connected';
            notifyListeners();
          }
        } finally {
          frame.onConsumed?.call();
        }
      }
    } catch (_) {
      _fail(currentL10n.invalidRemoteDesktopImage);
    } finally {
      _painting = false;
    }
  }

  Future<void> _connectLocalGateway(HostRecord host, int guacdPort) async {
    try {
      if (host.protocol.isTerminal || host.validate() != null)
        throw const FormatException('Invalid desktop Host');
      final socket = await transport
          .connectDirect('127.0.0.1', guacdPort)
          .timeout(const Duration(seconds: 10));
      if (_closed) {
        await socket.close();
        return;
      }
      _write = socket.sink.add;
      _closeTransport = socket.close;
      _listen(socket.stream, localHost: host);
      send(['select', host.protocol.name]);
    } catch (_) {
      _fail(currentL10n.couldntConnectToTheLocalGuacd);
    }
  }

  void _listen(Stream<List<int>> bytes, {HostRecord? localHost}) {
    display.send = send;
    _setupTimeout = Timer(
      const Duration(seconds: 30),
      () => _fail(currentL10n.remoteDesktopSetupTimedOutCheck),
    );
    var handshakePending = localHost != null;
    _subscription = decodeGuacamole(bytes)
        .asyncMap((v) async {
          if (handshakePending) {
            if (v.first != 'args')
              throw const FormatException('Invalid guacd handshake');
            if (localHost!.rdpCertificateSha256 != null &&
                !v.contains('cert-fingerprints'))
              throw const FormatException(
                'guacd does not support certificate pinning',
              );
            handshakePending = false;
            send(['size', 1280, 800, 96]);
            send(['audio']);
            send(['video']);
            send(['image', 'image/png', 'image/jpeg']);
            final options = <String, String>{
              'hostname': localHost.address,
              'port': '${localHost.port}',
              'username': localHost.username,
              'password': localHost.login?.password ?? '',
              'width': '1280',
              'height': '800',
              'dpi': '96',
              'security': 'any',
              'resize-method': 'display-update',
              'force-lossless': 'true',
              'disable-audio': 'true',
              'disable-gfx': 'true',
              'ignore-cert': 'false',
              if (localHost.rdpCertificateSha256 != null)
                'cert-fingerprints':
                    'sha256:${RegExp(r"..").allMatches(localHost.rdpCertificateSha256!).map((m) => m[0]).join(":")}',
              'enable-drive': 'false',
              'enable-printing': 'false',
              'enable-sftp': 'false',
            };
            send([
              'connect',
              ...v
                  .skip(1)
                  .map(
                    (key) => key.startsWith('VERSION_')
                        ? 'VERSION_1_0_0'
                        : options[key] ?? '',
                  ),
            ]);
            options.clear();
          } else {
            await display.instruction(v);
          }
          if (v.first == 'sync' &&
              display.size.width > 1 &&
              display.size.height > 1 &&
              !_closed &&
              state != 'connected') {
            _setupTimeout?.cancel();
            state = 'connected';
            notifyListeners();
          }
          return v;
        })
        .listen(
          (_) {},
          onError: (Object e) {
            onErrorForTesting?.call(e);
            _fail(
              e is StateError
                  ? e.message.toString()
                  : currentL10n.remoteDesktopStreamFailed,
            );
          },
          onDone: () => _fail(currentL10n.remoteDesktopConnectionClosed),
        );
  }

  void send(List<Object> values) {
    if (_direct != null) {
      if (!_closed) _direct!.send(values);
      return;
    }
    if (!_closed)
      _write?.call(
        Uint8List.fromList(utf8.encode(guacamoleInstruction(values))),
      );
  }

  @visibleForTesting
  RdpFeatures? rdpFeaturesForTesting;

  String _rdpConfigFor(HostRecord host, {RdpFeatures? features}) {
    final settings = _rdp;
    _clipboardText = settings.clipboardText;
    final engine = features ?? rdpEngineFeatures();
    if (!engine.has(RdpFeatures.configV1)) {
      rdpConfig = null;
      if (settings != RdpSettings.defaults || RdpSettings.unreadable(host)) {
        onNotice?.call(currentL10n.theInstalledRdpEngineDoesntSupport);
      }
      return '';
    }
    final config = settings.toNativeConfig(
      features: engine,
      initialWidth: 1280,
      initialHeight: 800,
      monitorLayout: settings.multiMonitor ? localMonitorLayout() : const [],
      defaultPrinterName: settings.printers == RdpPrinterMode.defaultPrinter
          ? localDefaultPrinterName()
          : null,
    );
    rdpConfig = config;
    if (config.unavailable.isNotEmpty) {
      onNotice?.call(
        currentL10n.thisClientCantProvideJoinThe(config.unavailable.join('、')),
      );
    }
    return config.text;
  }

  /// Offer local files/folders on the remote clipboard (user action).
  void offerLocalFiles(List<String> paths) {
    if (_direct == null || paths.isEmpty || !fileClipboardEnabled) return;
    send(['offerFiles', List<String>.of(paths)]);
  }

  /// Download the remote clipboard files into [folder] (user action).
  void saveRemoteFiles(String folder) {
    if (_direct == null || remoteFiles == null || transfer != null) return;
    send(['downloadFiles', folder]);
  }

  void cancelFileTransfer() {
    if (_direct != null) send(['cancelDownload']);
  }

  void paste(String text) {
    if (_direct != null && !_clipboardText) {
      throw FormatException(currentL10n.clipboardTextIsTurnedOffFor);
    }
    final bytes = utf8.encode(text);
    if (bytes.length > 65536) {
      throw FormatException(currentL10n.clipboardIsLimitedTo64Kib);
    }
    if (_direct != null) {
      _direct!.paste(text);
      return;
    }
    send(['clipboard', 0, 'text/plain']);
    for (var i = 0; i < bytes.length; i += 12000) {
      send([
        'blob',
        0,
        base64Encode(bytes.sublist(i, (i + 12000).clamp(0, bytes.length))),
      ]);
    }
    send(['end', 0]);
  }

  void _fail(String message) {
    if (_closed) return;
    state = 'disconnected';
    error = message;
    notifyListeners();
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      send(['disconnect']);
    } catch (_) {}
    _closed = true;
    _directAttempt++;
    certificateRequest = null;
    for (final frame in _pendingFrames) {
      frame.onConsumed?.call();
    }
    _pendingFrames.clear();
    remoteFiles = null;
    transfer = null;
    await _directSubscription?.cancel();
    await _direct?.close();
    _setupTimeout?.cancel();
    display.send = null;
    await _subscription?.cancel();
    try {
      await _closeTransport?.call().timeout(const Duration(seconds: 2));
      await _channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _channel = null;
    _write = null;
    _closeTransport = null;
  }

  @override
  void dispose() {
    _disposed = true;
    onNotice = null;
    onFilesSaved = null;
    unawaited(_frameUpdates.close());
    unawaited(close());
    display.dispose();
    super.dispose();
  }
}
