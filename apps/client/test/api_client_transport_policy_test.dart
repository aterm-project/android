import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('rejects remote HTTP URLs before the transport receives a request', () {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    addTearDown(transport.close);

    for (final url in [
      'http://sync.example.test/api',
      'http://192.168.1.20:8080/tenant',
      'http://10.24.0.7:8080/tenant',
    ]) {
      expect(
        () => ApiClient(baseUrl: url, client: transport),
        throwsFormatException,
        reason: 'plain HTTP must be rejected for $url',
      );
    }

    expect(requests, isEmpty);
  });

  test('HTTPS accepts arbitrary remote and private hosts', () async {
    for (final baseUrl in [
      'https://sync.example.test/tenant',
      'https://192.168.1.20:8443/tenant',
    ]) {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: baseUrl,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);

      await api.get('/probe', authenticated: false);

      expect(requests, hasLength(1), reason: 'HTTPS should work: $baseUrl');
      expect(requests.single.url.scheme, 'https');
      expect(requests.single.url.path, '/tenant/probe');
    }
  });

  test('loopback HTTP remains available for local development', () async {
    for (final url in [
      'http://localhost:8080/tenant',
      'http://127.0.0.1:8080/tenant',
      'http://[::1]:8080/tenant',
    ]) {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: url,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);

      await api.get('/probe', authenticated: false);

      expect(requests, hasLength(1), reason: 'loopback URL should work: $url');
      expect(requests.single.url.scheme, 'http');
      expect(requests.single.url.path, '/tenant/probe');
    }
  });

  test('JSON and byte requests do not follow redirects', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    )..accessToken = 'access-token';
    addTearDown(api.close);

    await api.post('/auth/login', {'verifier': 'login-material'});
    await api.putBytes('/objects/blob-id', [1, 2, 3]);

    expect(requests, hasLength(2));
    expect(
      requests.map((request) => request.followRedirects),
      everyElement(isFalse),
    );
    expect(
      requests.map((request) => request.headers['authorization']),
      everyElement('Bearer access-token'),
    );
  });

  test('late logout response does not clear a newer session token', () async {
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final api = ApiClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/logout');
        expect(request.headers['authorization'], 'Bearer old-session-token');
        requestStarted.complete();
        return response.future;
      }),
    )..accessToken = 'old-session-token';
    addTearDown(api.close);

    final logout = api.logout();
    await requestStarted.future;
    api.accessToken = 'new-session-token';
    response.complete(http.Response('{}', 200));
    await logout;

    expect(api.accessToken, 'new-session-token');
  });
}
