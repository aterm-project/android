/// Resolves only an authenticated session for the requested host. A cancelled
/// connection must never fall back to a previously selected, unrelated tab.
Future<T?> resolveHostFileSession<T>({
  required String hostId,
  required Iterable<T> Function() sessions,
  required String Function(T) sessionId,
  required String? Function(T) sessionHostId,
  required bool Function(T) isConnected,
  required Future<void> Function() connect,
}) async {
  final before = sessions().toList();
  for (final session in before) {
    if (sessionHostId(session) == hostId && isConnected(session)) {
      return session;
    }
  }
  final previousIds = before.map(sessionId).toSet();
  await connect();
  for (final session in sessions()) {
    if (!previousIds.contains(sessionId(session)) &&
        sessionHostId(session) == hostId &&
        isConnected(session)) {
      return session;
    }
  }
  return null;
}
