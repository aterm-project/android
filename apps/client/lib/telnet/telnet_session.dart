import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'telnet_errors.dart';
import 'telnet_protocol.dart';
import 'telnet_transport.dart';

/// Terminal types offered through TERMINAL-TYPE (RFC 1091), in preference
/// order. The last entry is repeated to mark the end of the list.
const List<String> defaultTelnetTerminalTypes = [
  'XTERM-256COLOR',
  'XTERM',
  'VT100',
];

/// Outcome of [TelnetSession.input].
enum TelnetInputResult { sent, tooLarge, closed }

/// Cancels a pending [TelnetSession.connect]. Idempotent.
class TelnetConnectCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Read-only snapshot of negotiated options, for diagnostics and tests.
class TelnetOptionStatus {
  const TelnetOptionStatus({
    required this.remoteEcho,
    required this.suppressGoAhead,
    required this.localBinary,
    required this.remoteBinary,
    required this.naws,
    required this.terminalType,
  });
  final bool remoteEcho;
  final bool suppressGoAhead;
  final bool localBinary;
  final bool remoteBinary;
  final bool naws;
  final bool terminalType;
}

/// One interactive Telnet session over a [TelnetByteChannel].
///
/// * Output is decoded as UTF-8 (malformed sequences become U+FFFD) across
///   arbitrary chunk boundaries.
/// * Login is always interactive in the terminal. This class has no
///   credential parameters and never parses login prompts.
/// * [close] is idempotent and safe to call during connect, from a stream
///   callback, or after the peer has closed.
class TelnetSession {
  TelnetSession.attach(
    TelnetByteChannel channel, {
    int columns = 80,
    int rows = 24,
    List<String> terminalTypes = defaultTelnetTerminalTypes,
  }) : _channel = channel,
       _columns = columns.clamp(1, 65535),
       _rows = rows.clamp(1, 65535),
       _terminalTypes = terminalTypes.isEmpty
           ? defaultTelnetTerminalTypes
           : List.unmodifiable(terminalTypes) {
    _negotiator
      ..onLocalChanged = _localOptionChanged
      ..onRemoteChanged = _remoteOptionChanged;
    _text = StreamController<String>(
      onListen: _start,
      onCancel: () {
        // The terminal stopped listening; treat as a local close.
        unawaited(close());
      },
    );
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TextSink(_text));
  }

  /// Connects with [connector] and returns an attached session. Honors
  /// [cancellation] and [timeout]; a channel that arrives after either is
  /// closed immediately and never returned.
  static Future<TelnetSession> connect({
    required String host,
    required int port,
    required TelnetChannelConnector connector,
    TelnetConnectCancellation? cancellation,
    Duration timeout = const Duration(seconds: 20),
    int columns = 80,
    int rows = 24,
    List<String> terminalTypes = defaultTelnetTerminalTypes,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const TelnetException(TelnetFailure.cancelled);
    }
    final result = Completer<TelnetByteChannel>();
    var abandoned = false;
    Timer? timer;
    void abandon(TelnetFailure failure) {
      if (result.isCompleted) return;
      abandoned = true;
      result.completeError(TelnetException(failure));
    }

    timer = Timer(timeout, () => abandon(TelnetFailure.timeout));
    unawaited(
      cancellation?.whenCancelled.then((_) => abandon(TelnetFailure.cancelled)),
    );
    unawaited(
      Future<TelnetByteChannel>.sync(() => connector(host, port)).then(
        (channel) {
          if (abandoned || result.isCompleted) {
            unawaited(channel.close().catchError((Object _) {}));
            return;
          }
          result.complete(channel);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (result.isCompleted) return;
          result.completeError(
            error is TelnetException
                ? error
                : const TelnetException(TelnetFailure.unreachable),
            stackTrace,
          );
        },
      ),
    );
    try {
      final channel = await result.future;
      return TelnetSession.attach(
        channel,
        columns: columns,
        rows: rows,
        terminalTypes: terminalTypes,
      );
    } finally {
      timer.cancel();
    }
  }

  final TelnetByteChannel _channel;
  final TelnetParser _parser = TelnetParser();
  final TelnetNvtReceiveFilter _nvt = TelnetNvtReceiveFilter();
  final TelnetOptionNegotiator _negotiator = TelnetOptionNegotiator();
  final TelnetInputEncoder _encoder = TelnetInputEncoder();
  final List<String> _terminalTypes;
  late final StreamController<String> _text;
  late final ByteConversionSink _decoder;
  final Completer<void> _done = Completer<void>();
  StreamSubscription<Uint8List>? _subscription;
  int _columns;
  int _rows;
  int? _sentColumns;
  int? _sentRows;
  int _terminalTypeIndex = 0;
  int _repliesWithoutData = 0;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closing;

  /// Decoded terminal output. Single subscription; listening starts I/O.
  Stream<String> get output => _text.stream;

  /// Completes when the connection ends for any reason.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  TelnetOptionStatus get options => TelnetOptionStatus(
    remoteEcho: _negotiator.remoteEnabled(TelnetOption.echo),
    suppressGoAhead: _negotiator.remoteEnabled(TelnetOption.suppressGoAhead),
    localBinary: _negotiator.localEnabled(TelnetOption.binary),
    remoteBinary: _negotiator.remoteEnabled(TelnetOption.binary),
    naws: _negotiator.localEnabled(TelnetOption.naws),
    terminalType: _negotiator.localEnabled(TelnetOption.terminalType),
  );

  void _start() {
    if (_started || _closed) return;
    _started = true;
    _subscription = _channel.stream.listen(
      _receive,
      onError: (Object _) => _finish(
        error: const TelnetException(TelnetFailure.connectionLost),
      ),
      onDone: _finish,
      cancelOnError: true,
    );
    // Proactively offer window size and ask the server to suppress GA and to
    // echo (character-at-a-time mode). Servers may refuse any of these;
    // RFC 1143 keeps the exchange loop-free either way.
    _send(_negotiator.requestLocal(TelnetOption.naws, true));
    _send(_negotiator.requestRemote(TelnetOption.suppressGoAhead, true));
    _send(_negotiator.requestRemote(TelnetOption.echo, true));
  }

  void _receive(Uint8List chunk) {
    if (_closed) return;
    final List<TelnetEvent> events;
    try {
      events = _parser.parse(chunk);
    } catch (_) {
      _fail();
      return;
    }
    for (final event in events) {
      if (_closed) return;
      switch (event) {
        case TelnetDataEvent(:final bytes):
          _repliesWithoutData = 0;
          // Applied in stream order, after any BINARY change that preceded
          // these bytes in the same chunk.
          final data = _nvt.filter(bytes);
          if (data.isNotEmpty) _decoder.add(data);
        case TelnetNegotiationEvent(:final verb, :final option):
          final reply = _negotiator.receive(verb, option);
          if (reply != null && !_countReply()) return;
          _send(reply);
        case TelnetSubnegotiationEvent():
          _handleSubnegotiation(event);
        case TelnetCommandEvent():
          // NOP, GA, DM, AYT ... carry no terminal output for this client.
          break;
      }
    }
  }

  bool _countReply() {
    if (++_repliesWithoutData > maxTelnetNegotiationRepliesWithoutData) {
      _fail();
      return false;
    }
    return true;
  }

  void _handleSubnegotiation(TelnetSubnegotiationEvent event) {
    if (event.overflowed) return; // Bounded: oversized payloads are ignored.
    if (event.option == TelnetOption.terminalType &&
        _negotiator.localEnabled(TelnetOption.terminalType) &&
        isTelnetTerminalTypeSend(event.payload)) {
      if (!_countReply()) return;
      // RFC 1091: send the next type; repeat the last one to signal the end
      // of the list, then start over.
      final index = _terminalTypeIndex;
      final name = _terminalTypes[index.clamp(0, _terminalTypes.length - 1)];
      _terminalTypeIndex = index >= _terminalTypes.length ? 0 : index + 1;
      _send(encodeTelnetTerminalType(name));
    }
  }

  void _localOptionChanged(int option, bool enabled) {
    switch (option) {
      case TelnetOption.binary:
        _encoder.binary = enabled;
      case TelnetOption.naws:
        if (enabled) {
          _sentColumns = null;
          _sentRows = null;
          // Deferred so it follows the WILL reply that enabled it.
          scheduleMicrotask(_sendNaws);
        }
      case TelnetOption.terminalType:
        if (enabled) _terminalTypeIndex = 0;
    }
  }

  void _remoteOptionChanged(int option, bool enabled) {
    if (option == TelnetOption.binary) _nvt.binary = enabled;
  }

  void _sendNaws() {
    if (_closed || !_negotiator.localEnabled(TelnetOption.naws)) return;
    if (_sentColumns == _columns && _sentRows == _rows) return;
    _sentColumns = _columns;
    _sentRows = _rows;
    _send(encodeTelnetNaws(_columns, _rows));
  }

  /// Writes to the transport. A synchronous sink failure (for example a
  /// Relay socket closing between checks) ends the session with a sanitized
  /// error instead of throwing into terminal key handling.
  bool _send(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty || _closed) return false;
    try {
      _channel.add(bytes);
      return true;
    } catch (_) {
      _finish(error: const TelnetException(TelnetFailure.connectionLost));
      unawaited(close());
      return false;
    }
  }

  /// Sends terminal input. Line endings follow NVT rules unless BINARY was
  /// negotiated for our direction; IAC bytes are always escaped.
  ///
  /// Sends nothing when the session is closed, and rejects the whole input
  /// when its encoded form would exceed [maxTelnetInputBytes], so no
  /// truncated, partially executable command reaches the server. Never
  /// throws.
  TelnetInputResult input(String text) {
    if (_closed) return TelnetInputResult.closed;
    if (text.isEmpty) return TelnetInputResult.sent;
    // UTF-8 is never shorter than UTF-16 code units: reject a huge paste
    // before allocating its encoded copy.
    if (text.length > maxTelnetInputBytes) return TelnetInputResult.tooLarge;
    final bytes = utf8.encode(text);
    final encoded = _encoder.encodeBounded(bytes, maxTelnetInputBytes);
    // Safe: [encoded] is a fresh buffer that never aliases [bytes].
    bytes.fillRange(0, bytes.length, 0);
    if (encoded == null) return TelnetInputResult.tooLarge;
    // Do not wipe [encoded] after sending: transport sinks may still hold
    // this buffer until their asynchronous write completes.
    return _send(encoded)
        ? TelnetInputResult.sent
        : TelnetInputResult.closed;
  }

  /// Records the terminal size and reports it through NAWS when the server
  /// enabled that option.
  void resize(int columns, int rows) {
    if (_closed || columns < 1 || rows < 1) return;
    _columns = columns.clamp(1, 65535);
    _rows = rows.clamp(1, 65535);
    _sendNaws();
  }

  void _fail() {
    _finish(error: const TelnetException(TelnetFailure.protocol));
    unawaited(close());
  }

  void _finish({Object? error}) {
    if (_done.isCompleted) return;
    _closed = true;
    try {
      _decoder.close();
    } catch (_) {}
    if (error != null && !_text.isClosed && _text.hasListener) {
      _text.addError(error);
    }
    if (!_text.isClosed) unawaited(_text.close());
    _done.complete();
    unawaited(_channel.close().catchError((Object _) {}));
  }

  /// Closes the connection. Idempotent and never throws.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await _channel.close();
    } catch (_) {}
    _finish();
  }
}

class _TextSink implements Sink<String> {
  _TextSink(this._controller);
  final StreamController<String> _controller;

  @override
  void add(String data) {
    if (data.isEmpty || _controller.isClosed) return;
    _controller.add(data);
  }

  @override
  void close() {}
}
