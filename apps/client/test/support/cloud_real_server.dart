// Shared harness: the real AppController against the real server binary.
import 'dart:async';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/cloud/cloud_access_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

final realServerBinary = Platform.environment['ATERMIUS_TEST_SERVER_BINARY'];
const _uuid = Uuid();
const realServerPassword = 'correct horse battery staple';

/// Records every request and can hold one matching request until released,
/// either before it is sent ([holdWhen]) or after the server has fully
/// answered it ([holdResponseWhen]: the server already committed, the caller
/// has not resumed yet).
class RecordingClient extends http.BaseClient {
  final _inner = http.Client();
  final List<String> requests = [];
  bool Function(http.BaseRequest request)? holdWhen;
  Completer<void>? held;
  Completer<void>? release;

  bool Function(http.BaseRequest request)? holdResponseWhen;
  Completer<void>? responseHeld;
  Completer<void>? responseRelease;
  int? heldResponseStatus;
  String? heldRequestBody;

  /// Arms [holdResponseWhen] for the next matching request.
  void holdResponse(bool Function(http.BaseRequest request) when) {
    holdResponseWhen = when;
    responseHeld = Completer<void>();
    responseRelease = Completer<void>();
    heldResponseStatus = null;
    heldRequestBody = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // One connection per request: holding answers and switching sessions
    // must not make a later POST reuse a pooled socket the server closed
    // (dart:io does not retry that), which is not what these tests measure.
    request.persistentConnection = false;
    requests.add('${request.method} ${request.url.path}');
    final hold = holdWhen;
    if (hold != null && hold(request)) {
      holdWhen = null;
      held?.complete();
      await release!.future;
    }
    final holdResponse = holdResponseWhen;
    if (holdResponse != null && holdResponse(request)) {
      holdResponseWhen = null;
      if (request is http.Request) heldRequestBody = request.body;
      final response = await _inner.send(request);
      // Read the whole answer: the server has finished handling the request.
      final bytes = await response.stream.toBytes();
      heldResponseStatus = response.statusCode;
      responseHeld!.complete();
      await responseRelease!.future;
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        request: response.request,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return _inner.send(request);
  }

  bool sent(String method, Pattern path) => requests.any(
    (r) =>
        r.startsWith('$method ') &&
        r.substring(method.length + 1).contains(path),
  );
}

class TestServer {
  TestServer._(this.process, this.baseUrl, this.env, this.dir);
  final Process process;
  final String baseUrl;
  final Map<String, String> env;
  final Directory dir;

  static Future<TestServer> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final tmp = Platform.environment['TMPDIR'] ?? Directory.systemTemp.path;
    final dir = await Directory(tmp).createTemp('cloud-real-server-');
    final data = Directory('${dir.path}/data')..createSync();
    Process.runSync('chmod', ['700', data.path]);
    Directory('${dir.path}/gw').createSync();
    final env = {
      ...Platform.environment,
      'ATERMIUS_BIND': '127.0.0.1:$port',
      'ATERMIUS_DATA_DIR': data.path,
      'ATERMIUS_DATABASE_URL': 'sqlite://${data.path}/atermius.db?mode=rwc',
      'ATERMIUS_REGISTRATION_OPEN': 'false',
      'ATERMIUS_PUBLIC_ORIGIN': 'http://127.0.0.1:$port',
      'ATERMIUS_GUACD_ADDRESS': '127.0.0.1:9',
      'ATERMIUS_SHARE_LINKS_ENABLED': 'true',
      'ATERMIUS_SHARE_GATEWAY_KEY_FILE': '${dir.path}/gw/share-gateway.key',
      'ATERMIUS_SHARE_ALLOW_CIDRS': '10.0.0.0/8',
      'ATERMIUS_SHARE_ALLOW_PORTS': '22,3389',
      'ATERMIUS_ORG_CREATION': 'any',
    };
    final process = await Process.start(realServerBinary!, ['serve'], environment: env);
    final logPath = Platform.environment['ATERMIUS_TEST_SERVER_LOG'];
    if (logPath == null) {
      process.stdout.drain<void>();
      process.stderr.drain<void>();
    } else {
      final sink = File(logPath).openWrite(mode: FileMode.append);
      process.stdout.listen(sink.add);
      process.stderr.listen(sink.add);
    }
    final baseUrl = 'http://127.0.0.1:$port';
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      try {
        final response = await http.get(Uri.parse('$baseUrl/health/ready'));
        if (response.statusCode == 200) break;
      } catch (_) {}
      if (DateTime.now().isAfter(deadline))
        throw StateError('server did not start');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return TestServer._(process, baseUrl, env, dir);
  }

  String _token(ProcessResult result) {
    final match = RegExp(
      r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])',
    ).allMatches('${result.stdout}').lastOrNull;
    if (result.exitCode != 0 || match == null)
      throw StateError('server CLI failed');
    return match.group(0)!;
  }

  String bootstrapToken() =>
      _token(Process.runSync(realServerBinary!, ['bootstrap'], environment: env));

  String accountInvitation(String username) => _token(
    Process.runSync(realServerBinary!, [
      'create-account-invite',
      '--username',
      username,
    ], environment: env),
  );

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    await dir.delete(recursive: true);
  }
}

/// Per-device key prefix, so several test devices share the mock storage
/// without sharing secrets.
class PrefixedStorage extends FlutterSecureStorage {
  const PrefixedStorage(this.prefix);
  final String prefix;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => super.write(key: '$prefix$key', value: value);

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => super.read(key: '$prefix$key');

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => super.containsKey(key: '$prefix$key');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => super.delete(key: '$prefix$key');
}

class Party {
  Party(this.app, this.client, this.service);
  final AppController app;
  final RecordingClient client;
  final CloudAccessService service;
}

Future<void> idle(AppController app) async {
  for (var i = 0; i < 400 && (app.syncing || app.busy); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<Party> party(
  SodiumSumo sodium,
  String url, {
  required String username,
  String? bootstrap,
  String? invitation,
  String storagePrefix = '',
}) async {
  final client = RecordingClient();
  final app = AppController(
    sodium: sodium,
    database: ClientDatabase.forTesting(NativeDatabase.memory()),
    secureStore: ClientSecureStore(PrefixedStorage(storagePrefix)),
    apiClientFactoryForTesting: (baseUrl) =>
        ApiClient(baseUrl: baseUrl, client: client),
  );
  await app.configureServer(url);
  await app.register(
    username: username,
    password: realServerPassword,
    bootstrapToken: bootstrap,
    instanceInvitationToken: invitation,
  );
  await idle(app);
  return Party(app, client, CloudAccessService(app));
}

HostRecord testHost(
  String name, {
  HostProtocol protocol = HostProtocol.ssh,
  String? cert,
}) => HostRecord(
  id: _uuid.v4(),
  name: name,
  address: '10.1.2.${name.length}',
  port: protocol == HostProtocol.rdp ? 3389 : 22,
  protocol: protocol,
  rdpCertificateSha256: cert,
  username: 'ops',
  login: HostLogin(kind: AuthKind.password, password: 'SENTINEL-$name'),
);

Future<List<HostRecord>> hostsIn(AppController app, String vaultId) async {
  await app.selectVault(vaultId);
  expect(app.activeVault?.id, vaultId);
  await app.synchronize();
  await idle(app);
  return List.of(app.hosts);
}
