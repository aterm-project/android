import 'models.dart';
import '../l10n/l10n.dart';

enum QuickConnectKind { ssh, rdp, vnc, console, serial }

class QuickConnectRequest {
  const QuickConnectRequest(
    this.kind, {
    this.address = '',
    this.username = '',
    this.port = 0,
    this.baudRate = 115200,
  });
  final QuickConnectKind kind;
  final String address, username;
  final int port, baudRate;
  bool get isConsole =>
      kind == QuickConnectKind.console || kind == QuickConnectKind.serial;
  HostProtocol get protocol => switch (kind) {
    QuickConnectKind.rdp => HostProtocol.rdp,
    QuickConnectKind.vnc => HostProtocol.vnc,
    _ => HostProtocol.ssh,
  };
  String get label => switch (kind) {
    QuickConnectKind.console => currentL10n.openLocalConsole,
    QuickConnectKind.serial => currentL10n.connectAddressBaudrateBaud8n1(
      address,
      baudRate,
    ),
    _ =>
      '${kind.name.toUpperCase()} ${username.isEmpty ? '' : '$username@'}$address:$port',
  };
  bool matches(HostRecord host) =>
      !isConsole &&
      host.protocol == protocol &&
      host.address.toLowerCase() == address.toLowerCase() &&
      host.port == port &&
      (username.isEmpty || host.username == username);
  HostRecord draft(String id) => HostRecord(
    id: id,
    name: address,
    address: address,
    username: username,
    port: port,
    protocol: protocol,
  );

  /// A small connection grammar, never a shell command. Unknown plain text
  /// remains a search query; recognized commands with errors explain syntax.
  static QuickConnectRequest? parse(String input) {
    final words = input.trim().split(RegExp(r'\s+'));
    final verb = words.first.toLowerCase();
    if (!const ['ssh', 'rdp', 'vnc', 'console', 'tty'].contains(verb))
      return null;
    if (verb == 'console' && words.length == 1)
      return const QuickConnectRequest(QuickConnectKind.console);
    if (verb == 'console' || verb == 'tty') {
      var args = words.skip(1).toList();
      if (args.isNotEmpty && args.first.toLowerCase() == 'tty')
        args = args.skip(1).toList();
      if (args.isEmpty) {
        throw FormatException(currentL10n.serialFormatConsoleTtyCom3B);
      }
      final device = args
          .removeAt(0)
          .replaceFirst(RegExp(r'^@'), '')
          .toUpperCase();
      if (!RegExp(r'^COM[1-9][0-9]{0,3}$').hasMatch(device)) {
        throw FormatException(currentL10n.enterAValidSerialPortFor);
      }
      var baud = 115200;
      if (args.isNotEmpty) {
        if (args.length != 2 || !const ['-b', '--baud'].contains(args[0])) {
          throw FormatException(currentL10n.baudRateFormatB115200);
        }
        baud = int.tryParse(args[1]) ?? 0;
      }
      if (baud < 50 || baud > 4000000) {
        throw FormatException(currentL10n.baudRateMustBe504000000);
      }
      return QuickConnectRequest(
        QuickConnectKind.serial,
        address: device,
        baudRate: baud,
      );
    }
    String? target;
    int? port;
    for (var i = 1; i < words.length; i++) {
      final word = words[i];
      if (word == '-p' ||
          word == '--port' ||
          word.startsWith('-p') && word.length > 2 ||
          word.startsWith('--port=')) {
        if (port != null) {
          throw FormatException(currentL10n.thePortCanOnlyBeSpecified);
        }
        String value;
        if (word == '-p' || word == '--port') {
          if (++i >= words.length) {
            throw FormatException(currentL10n.aPortNumberIsRequiredAfter);
          }
          value = words[i];
        } else {
          value = word.startsWith('--port=')
              ? word.substring(7)
              : word.substring(2);
        }
        port = int.tryParse(value) ?? 0;
      } else {
        if (word.startsWith('-') || target != null) {
          throw FormatException(currentL10n.onlyUserHostAndPPort);
        }
        target = word;
      }
    }
    if (target == null || target.isEmpty) {
      throw FormatException(
        currentL10n.formatVerbValuevalueHostPValuevalue2(
          verb,
          verb == 'ssh' ? 'root@' : '',
          verb == 'rdp'
              ? 3389
              : verb == 'vnc'
              ? 5900
              : 22,
        ),
      );
    }
    var username = '';
    final at = target.lastIndexOf('@');
    if (at >= 0) {
      username = target.substring(0, at);
      target = target.substring(at + 1);
      if (username.isEmpty) {
        throw FormatException(currentL10n.aUserNameIsRequiredBefore);
      }
    }
    final withPort = RegExp(r'^\[([0-9a-fA-F:.]+)\](?::([0-9]+))?$')
        .firstMatch(target);
    String address;
    String? endpointPort;
    if (withPort != null) {
      address = withPort[1]!;
      endpointPort = withPort[2];
    } else {
      final colon = target.indexOf(':');
      if (colon >= 0 && colon == target.lastIndexOf(':')) {
        address = target.substring(0, colon);
        endpointPort = target.substring(colon + 1);
      } else {
        address = target;
      }
    }
    if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(address) ||
        address.startsWith('-') ||
        username.contains(RegExp(r'[\x00-\x20;|&<>`$]'))) {
      throw FormatException(currentL10n.invalidHostOrUserNameFormat);
    }
    if (endpointPort != null) {
      if (port != null) {
        throw FormatException(currentL10n.dontSpecifyThePortBothIn);
      }
      port = int.tryParse(endpointPort) ?? 0;
    }
    port ??= verb == 'rdp'
        ? 3389
        : verb == 'vnc'
        ? 5900
        : 22;
    if (port < 1 || port > 65535) {
      throw FormatException(currentL10n.portMustBe165535);
    }
    return QuickConnectRequest(
      QuickConnectKind.values.byName(verb),
      address: address,
      username: username,
      port: port,
    );
  }
}
