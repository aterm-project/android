// Telnet wire protocol: streaming parser, RFC 1143 option negotiation and
// NVT input encoding. Pure Dart (no dart:io), so it compiles for Web too.
//
// References:
//  * RFC 854  Telnet Protocol Specification (NVT, IAC commands, CR NUL/CR LF)
//  * RFC 855  Telnet Option Specifications (WILL/WONT/DO/DONT, SB ... SE)
//  * RFC 856  BINARY, RFC 857 ECHO, RFC 858 SUPPRESS-GO-AHEAD
//  * RFC 1073 NAWS, RFC 1091 TERMINAL-TYPE
//  * RFC 1143 The Q Method of Implementing TELNET Option Negotiation
import 'dart:typed_data';

/// Telnet command bytes (RFC 854).
abstract final class TelnetCommand {
  static const int se = 240;
  static const int nop = 241;
  static const int dataMark = 242;
  static const int brk = 243;
  static const int ip = 244;
  static const int ao = 245;
  static const int ayt = 246;
  static const int ec = 247;
  static const int el = 248;
  static const int ga = 249;
  static const int sb = 250;
  static const int will = 251;
  static const int wont = 252;
  static const int doOption = 253;
  static const int dont = 254;
  static const int iac = 255;
}

/// Option codes this client understands.
abstract final class TelnetOption {
  static const int binary = 0; // RFC 856
  static const int echo = 1; // RFC 857
  static const int suppressGoAhead = 3; // RFC 858
  static const int terminalType = 24; // RFC 1091
  static const int naws = 31; // RFC 1073
}

/// RFC 1091 TERMINAL-TYPE subcommands.
const int _ttypeIs = 0;
const int _ttypeSend = 1;

/// Largest accepted subnegotiation payload. Every option this client
/// understands needs far less; longer payloads are discarded (the parser still
/// consumes them up to IAC SE so the data stream stays in sync).
const int maxTelnetSubnegotiationBytes = 512;

/// Upper bound for negotiation replies the peer can trigger without sending
/// any terminal data. RFC 1143 already prevents a negotiation loop between two
/// compliant ends; this bounds a hostile peer that keeps toggling options.
const int maxTelnetNegotiationRepliesWithoutData = 4096;

/// Upper bound for one terminal input write (after encoding).
const int maxTelnetInputBytes = 1024 * 1024;

class TelnetProtocolException implements Exception {
  const TelnetProtocolException(this.reason);
  final String reason;
  @override
  String toString() => 'TelnetProtocolException: $reason';
}

/// One parsed unit of the inbound stream.
sealed class TelnetEvent {
  const TelnetEvent();
}

/// Application data with IAC IAC unescaped. NVT CR NUL translation is NOT
/// applied here: option changes earlier in the same chunk must take effect
/// first, so the session applies [TelnetNvtReceiveFilter] while consuming
/// events in order.
final class TelnetDataEvent extends TelnetEvent {
  const TelnetDataEvent(this.bytes);
  final Uint8List bytes;
}

/// A two-byte command such as NOP, GA, AYT or DM.
final class TelnetCommandEvent extends TelnetEvent {
  const TelnetCommandEvent(this.command);
  final int command;
}

/// WILL/WONT/DO/DONT [option].
final class TelnetNegotiationEvent extends TelnetEvent {
  const TelnetNegotiationEvent(this.verb, this.option);
  final int verb;
  final int option;
}

/// IAC SB [option] payload IAC SE. [overflowed] is true when the payload was
/// longer than [maxTelnetSubnegotiationBytes]; its bytes were discarded.
final class TelnetSubnegotiationEvent extends TelnetEvent {
  const TelnetSubnegotiationEvent(
    this.option,
    this.payload, {
    this.overflowed = false,
  });
  final int option;
  final Uint8List payload;
  final bool overflowed;
}

enum _ParseState { data, iac, negotiate, sbOption, sbData, sbIac }

/// Incremental Telnet stream parser. Every byte sequence may be split at any
/// boundary between [parse] calls (including inside IAC sequences, between CR
/// and NUL and inside subnegotiations).
class TelnetParser {
  TelnetParser({this.maxSubnegotiationBytes = maxTelnetSubnegotiationBytes});

  final int maxSubnegotiationBytes;

  _ParseState _state = _ParseState.data;
  int _verb = 0;
  int _sbOption = 0;
  final BytesBuilder _sb = BytesBuilder(copy: false);
  int _sbLength = 0;
  bool _sbOverflow = false;

  /// True while a partial IAC sequence or subnegotiation is buffered.
  bool get midSequence => _state != _ParseState.data;

  List<TelnetEvent> parse(List<int> chunk) {
    final events = <TelnetEvent>[];
    final data = BytesBuilder(copy: false);
    final pending = <int>[];

    void flushData() {
      if (pending.isNotEmpty) {
        data.add(Uint8List.fromList(pending));
        pending.clear();
      }
      if (data.length > 0) events.add(TelnetDataEvent(data.takeBytes()));
    }

    void addData(int byte) {
      pending.add(byte);
      if (pending.length >= 4096) {
        data.add(Uint8List.fromList(pending));
        pending.clear();
      }
    }

    for (final raw in chunk) {
      final byte = raw & 0xff;
      switch (_state) {
        case _ParseState.data:
          if (byte == TelnetCommand.iac) {
            _state = _ParseState.iac;
          } else {
            addData(byte);
          }
        case _ParseState.iac:
          switch (byte) {
            case TelnetCommand.iac:
              _state = _ParseState.data;
              addData(TelnetCommand.iac);
            case TelnetCommand.will ||
                TelnetCommand.wont ||
                TelnetCommand.doOption ||
                TelnetCommand.dont:
              _verb = byte;
              _state = _ParseState.negotiate;
            case TelnetCommand.sb:
              _state = _ParseState.sbOption;
            default:
              // NOP, GA, DM, AYT, ... and a stray SE are two-byte commands.
              _state = _ParseState.data;
              flushData();
              events.add(TelnetCommandEvent(byte));
          }
        case _ParseState.negotiate:
          _state = _ParseState.data;
          flushData();
          events.add(TelnetNegotiationEvent(_verb, byte));
        case _ParseState.sbOption:
          _sbOption = byte;
          _sb.clear();
          _sbLength = 0;
          _sbOverflow = false;
          _state = _ParseState.sbData;
        case _ParseState.sbData:
          if (byte == TelnetCommand.iac) {
            _state = _ParseState.sbIac;
          } else {
            _appendSb(byte);
          }
        case _ParseState.sbIac:
          if (byte == TelnetCommand.iac) {
            _appendSb(TelnetCommand.iac);
            _state = _ParseState.sbData;
          } else if (byte == TelnetCommand.se) {
            _state = _ParseState.data;
            flushData();
            events.add(
              TelnetSubnegotiationEvent(
                _sbOption,
                _sbOverflow ? Uint8List(0) : _sb.takeBytes(),
                overflowed: _sbOverflow,
              ),
            );
            _sb.clear();
            _sbLength = 0;
            _sbOverflow = false;
          } else {
            // RFC 855 permits no other IAC command inside SB. Treat it as an
            // abnormal end of the subnegotiation (as BSD telnet does) and
            // process the command normally so the stream resynchronizes.
            _sb.clear();
            _sbLength = 0;
            _sbOverflow = false;
            _state = _ParseState.iac;
            // Re-dispatch this byte in IAC state.
            switch (byte) {
              case TelnetCommand.will ||
                  TelnetCommand.wont ||
                  TelnetCommand.doOption ||
                  TelnetCommand.dont:
                _verb = byte;
                _state = _ParseState.negotiate;
              case TelnetCommand.sb:
                _state = _ParseState.sbOption;
              default:
                _state = _ParseState.data;
                flushData();
                events.add(TelnetCommandEvent(byte));
            }
          }
      }
    }
    flushData();
    return events;
  }

  void _appendSb(int byte) {
    if (_sbOverflow) return;
    if (_sbLength >= maxSubnegotiationBytes) {
      _sbOverflow = true;
      _sb.clear();
      return;
    }
    _sb.addByte(byte);
    _sbLength++;
  }

  void reset() {
    _state = _ParseState.data;
    _sb.clear();
    _sbLength = 0;
    _sbOverflow = false;
  }
}

/// Receive-side NVT translation (RFC 854): while the peer is not sending in
/// BINARY mode, CR NUL represents a bare CR and the NUL is dropped. State is
/// carried across data events, so a CR at the end of one chunk and a NUL at
/// the start of the next still translate. Changing [binary] resets it.
class TelnetNvtReceiveFilter {
  bool _binary = false;
  bool _lastWasCr = false;

  bool get binary => _binary;
  set binary(bool value) {
    if (value == _binary) return;
    _binary = value;
    _lastWasCr = false;
  }

  Uint8List filter(Uint8List data) {
    if (_binary) return data;
    final out = BytesBuilder(copy: false);
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      final byte = data[i];
      if (_lastWasCr && byte == 0) {
        if (i > start) out.add(Uint8List.sublistView(data, start, i));
        start = i + 1;
        _lastWasCr = false;
        continue;
      }
      _lastWasCr = byte == 13;
    }
    if (start == 0) return data;
    if (start < data.length) out.add(Uint8List.sublistView(data, start));
    return out.takeBytes();
  }
}

/// RFC 1143 option state.
enum TelnetQState { no, yes, wantNo, wantYes }

/// RFC 1143 queue bit.
enum TelnetQueue { empty, opposite }

class _OptionSide {
  TelnetQState state = TelnetQState.no;
  TelnetQueue queue = TelnetQueue.empty;
}

/// Callback-free RFC 1143 negotiator. Each call returns the bytes to send (if
/// any). [onLocalChanged] / [onRemoteChanged] report option enablement
/// transitions so the session can react (send NAWS, switch BINARY ...).
class TelnetOptionNegotiator {
  TelnetOptionNegotiator({
    Set<int> acceptLocal = const {
      TelnetOption.binary,
      TelnetOption.suppressGoAhead,
      TelnetOption.terminalType,
      TelnetOption.naws,
    },
    Set<int> acceptRemote = const {
      TelnetOption.binary,
      TelnetOption.echo,
      TelnetOption.suppressGoAhead,
    },
  }) : _acceptLocal = Set.unmodifiable(acceptLocal),
       _acceptRemote = Set.unmodifiable(acceptRemote);

  final Set<int> _acceptLocal;
  final Set<int> _acceptRemote;
  final Map<int, _OptionSide> _us = {};
  final Map<int, _OptionSide> _him = {};

  void Function(int option, bool enabled)? onLocalChanged;
  void Function(int option, bool enabled)? onRemoteChanged;

  _OptionSide _usSide(int option) => _us.putIfAbsent(option, _OptionSide.new);
  _OptionSide _himSide(int option) => _him.putIfAbsent(option, _OptionSide.new);

  /// Whether we perform [option] (we sent/acknowledged WILL).
  bool localEnabled(int option) => _us[option]?.state == TelnetQState.yes;

  /// Whether the peer performs [option] (we sent/acknowledged DO).
  bool remoteEnabled(int option) => _him[option]?.state == TelnetQState.yes;

  TelnetQState localState(int option) =>
      _us[option]?.state ?? TelnetQState.no;
  TelnetQState remoteState(int option) =>
      _him[option]?.state ?? TelnetQState.no;

  static Uint8List _cmd(int verb, int option) =>
      Uint8List.fromList([TelnetCommand.iac, verb, option]);

  /// Handles an inbound WILL/WONT/DO/DONT and returns the reply (possibly
  /// empty). Implements RFC 1143 section 7 exactly.
  Uint8List? receive(int verb, int option) {
    switch (verb) {
      case TelnetCommand.will:
        return _receiveWill(option);
      case TelnetCommand.wont:
        return _receiveWont(option);
      case TelnetCommand.doOption:
        return _receiveDo(option);
      case TelnetCommand.dont:
        return _receiveDont(option);
    }
    return null;
  }

  Uint8List? _receiveWill(int option) {
    final him = _himSide(option);
    switch (him.state) {
      case TelnetQState.no:
        if (_acceptRemote.contains(option)) {
          him.state = TelnetQState.yes;
          onRemoteChanged?.call(option, true);
          return _cmd(TelnetCommand.doOption, option);
        }
        return _cmd(TelnetCommand.dont, option);
      case TelnetQState.yes:
        return null;
      case TelnetQState.wantNo:
        // Error: DONT answered by WILL.
        if (him.queue == TelnetQueue.empty) {
          him.state = TelnetQState.no;
        } else {
          him.state = TelnetQState.yes;
          him.queue = TelnetQueue.empty;
          onRemoteChanged?.call(option, true);
        }
        return null;
      case TelnetQState.wantYes:
        if (him.queue == TelnetQueue.empty) {
          him.state = TelnetQState.yes;
          onRemoteChanged?.call(option, true);
          return null;
        }
        him.state = TelnetQState.wantNo;
        him.queue = TelnetQueue.empty;
        return _cmd(TelnetCommand.dont, option);
    }
  }

  Uint8List? _receiveWont(int option) {
    final him = _himSide(option);
    switch (him.state) {
      case TelnetQState.no:
        return null;
      case TelnetQState.yes:
        him.state = TelnetQState.no;
        onRemoteChanged?.call(option, false);
        return _cmd(TelnetCommand.dont, option);
      case TelnetQState.wantNo:
        if (him.queue == TelnetQueue.empty) {
          him.state = TelnetQState.no;
          onRemoteChanged?.call(option, false);
          return null;
        }
        him.state = TelnetQState.wantYes;
        him.queue = TelnetQueue.empty;
        return _cmd(TelnetCommand.doOption, option);
      case TelnetQState.wantYes:
        him.state = TelnetQState.no;
        him.queue = TelnetQueue.empty;
        return null;
    }
  }

  Uint8List? _receiveDo(int option) {
    final us = _usSide(option);
    switch (us.state) {
      case TelnetQState.no:
        if (_acceptLocal.contains(option)) {
          us.state = TelnetQState.yes;
          onLocalChanged?.call(option, true);
          return _cmd(TelnetCommand.will, option);
        }
        return _cmd(TelnetCommand.wont, option);
      case TelnetQState.yes:
        return null;
      case TelnetQState.wantNo:
        if (us.queue == TelnetQueue.empty) {
          us.state = TelnetQState.no;
        } else {
          us.state = TelnetQState.yes;
          us.queue = TelnetQueue.empty;
          onLocalChanged?.call(option, true);
        }
        return null;
      case TelnetQState.wantYes:
        if (us.queue == TelnetQueue.empty) {
          us.state = TelnetQState.yes;
          onLocalChanged?.call(option, true);
          return null;
        }
        us.state = TelnetQState.wantNo;
        us.queue = TelnetQueue.empty;
        return _cmd(TelnetCommand.wont, option);
    }
  }

  Uint8List? _receiveDont(int option) {
    final us = _usSide(option);
    switch (us.state) {
      case TelnetQState.no:
        return null;
      case TelnetQState.yes:
        us.state = TelnetQState.no;
        onLocalChanged?.call(option, false);
        return _cmd(TelnetCommand.wont, option);
      case TelnetQState.wantNo:
        if (us.queue == TelnetQueue.empty) {
          us.state = TelnetQState.no;
          onLocalChanged?.call(option, false);
          return null;
        }
        us.state = TelnetQState.wantYes;
        us.queue = TelnetQueue.empty;
        return _cmd(TelnetCommand.will, option);
      case TelnetQState.wantYes:
        us.state = TelnetQState.no;
        us.queue = TelnetQueue.empty;
        return null;
    }
  }

  /// Ask to enable a local option (send WILL). RFC 1143 section 7.
  Uint8List? requestLocal(int option, bool enable) {
    final us = _usSide(option);
    return _request(
      us,
      enable,
      enableVerb: TelnetCommand.will,
      disableVerb: TelnetCommand.wont,
      option: option,
      onChanged: (enabled) => onLocalChanged?.call(option, enabled),
    );
  }

  /// Ask the peer to enable a remote option (send DO).
  Uint8List? requestRemote(int option, bool enable) {
    final him = _himSide(option);
    return _request(
      him,
      enable,
      enableVerb: TelnetCommand.doOption,
      disableVerb: TelnetCommand.dont,
      option: option,
      onChanged: (enabled) => onRemoteChanged?.call(option, enabled),
    );
  }

  Uint8List? _request(
    _OptionSide side,
    bool enable, {
    required int enableVerb,
    required int disableVerb,
    required int option,
    required void Function(bool enabled) onChanged,
  }) {
    if (enable) {
      switch (side.state) {
        case TelnetQState.no:
          side.state = TelnetQState.wantYes;
          return _cmd(enableVerb, option);
        case TelnetQState.yes:
          return null;
        case TelnetQState.wantNo:
          if (side.queue == TelnetQueue.empty) {
            side.queue = TelnetQueue.opposite;
          }
          return null;
        case TelnetQState.wantYes:
          if (side.queue == TelnetQueue.opposite) {
            side.queue = TelnetQueue.empty;
          }
          return null;
      }
    }
    switch (side.state) {
      case TelnetQState.no:
        return null;
      case TelnetQState.yes:
        side.state = TelnetQState.wantNo;
        onChanged(false);
        return _cmd(disableVerb, option);
      case TelnetQState.wantNo:
        if (side.queue == TelnetQueue.opposite) {
          side.queue = TelnetQueue.empty;
        }
        return null;
      case TelnetQState.wantYes:
        if (side.queue == TelnetQueue.empty) {
          side.queue = TelnetQueue.opposite;
        }
        return null;
    }
  }
}

/// Encodes one NAWS subnegotiation (RFC 1073). Width/height are clamped to
/// 1..65535 and any 255 byte is doubled.
Uint8List encodeTelnetNaws(int columns, int rows) {
  final width = columns.clamp(1, 65535);
  final height = rows.clamp(1, 65535);
  final out = <int>[TelnetCommand.iac, TelnetCommand.sb, TelnetOption.naws];
  for (final byte in [width >> 8, width & 0xff, height >> 8, height & 0xff]) {
    out.add(byte);
    if (byte == TelnetCommand.iac) out.add(TelnetCommand.iac);
  }
  out.addAll([TelnetCommand.iac, TelnetCommand.se]);
  return Uint8List.fromList(out);
}

/// Encodes IAC SB TERMINAL-TYPE IS [name] IAC SE (RFC 1091). [name] is
/// restricted to printable ASCII and at most 40 characters.
Uint8List encodeTelnetTerminalType(String name) {
  final bytes = <int>[];
  for (final unit in name.codeUnits) {
    if (bytes.length >= 40) break;
    if (unit >= 0x21 && unit <= 0x7e) bytes.add(unit);
  }
  return Uint8List.fromList([
    TelnetCommand.iac,
    TelnetCommand.sb,
    TelnetOption.terminalType,
    _ttypeIs,
    ...bytes,
    TelnetCommand.iac,
    TelnetCommand.se,
  ]);
}

/// True when [payload] is a TERMINAL-TYPE SEND request.
bool isTelnetTerminalTypeSend(Uint8List payload) =>
    payload.length == 1 && payload[0] == _ttypeSend;

/// Encodes terminal input for the wire.
///
/// IAC (0xff) is always doubled. Unless we transmit in BINARY mode, every line
/// ending (CR, LF or CR LF) becomes the NVT newline CR LF (RFC 854), so a
/// lone CR never reaches the wire unpaired. [lastWasCr] carries state between
/// calls so a CR at the end of one write and an LF at the start of the next
/// still produce a single CR LF.
class TelnetInputEncoder {
  bool binary = false;
  bool _lastWasCr = false;

  /// Encodes [input] unless the encoded result would exceed [maxBytes]; then
  /// returns null and leaves the encoder state unchanged, so nothing (not even
  /// a truncated prefix of a command) is transmitted.
  Uint8List? encodeBounded(List<int> input, int maxBytes) {
    if (input.length > maxBytes) return null;
    final saved = _lastWasCr;
    final encoded = encode(input);
    if (encoded.length > maxBytes) {
      _lastWasCr = saved;
      encoded.fillRange(0, encoded.length, 0);
      return null;
    }
    return encoded;
  }

  Uint8List encode(List<int> input) {
    final out = BytesBuilder(copy: false);
    final buffer = <int>[];
    for (final raw in input) {
      final byte = raw & 0xff;
      if (!binary) {
        if (byte == 13) {
          buffer
            ..add(13)
            ..add(10);
          _lastWasCr = true;
          continue;
        }
        if (byte == 10) {
          if (!_lastWasCr) {
            buffer
              ..add(13)
              ..add(10);
          }
          _lastWasCr = false;
          continue;
        }
      }
      _lastWasCr = false;
      buffer.add(byte);
      if (byte == TelnetCommand.iac) buffer.add(TelnetCommand.iac);
      if (buffer.length >= 4096) {
        out.add(Uint8List.fromList(buffer));
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) out.add(Uint8List.fromList(buffer));
    return out.takeBytes();
  }
}
