import 'dart:async';

import '../domain/window_placement.dart';
import 'window_geometry.dart';

/// Geometry RPC rides an already authenticated, single-use window socket.
/// One outstanding request per child; no launch tokens or native handles here.
class WindowGeometryRpcOwner {
  WindowGeometryRpcOwner({this.timeout = const Duration(seconds: 2)});
  final Duration timeout;
  Completer<Map<String, Object?>?>? _pending;
  int _serial = 0;
  bool _closed = false;
  Future<Map<String, Object?>?> _request(
    void Function(Map<String, Object?>) send,
    String action, {
    SavedWindowPlacement? placement,
  }) async {
    if (_closed || _pending != null) return null;
    final pending = Completer<Map<String, Object?>?>();
    _pending = pending;
    final id = ++_serial;
    try {
      send({
        'type': 'window_geometry_request',
        'request': id,
        'action': action,
        if (placement != null) 'placement': placement.toJson(),
      });
      return await pending.future.timeout(timeout, onTimeout: () => null);
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<SavedWindowPlacement?> capture(
    void Function(Map<String, Object?>) send,
  ) async {
    final reply = await _request(send, 'get');
    return reply?['placement'] is Map
        ? SavedWindowPlacement.fromJson(
            Map<String, Object?>.from(reply!['placement'] as Map),
          )
        : null;
  }

  Future<bool> apply(
    void Function(Map<String, Object?>) send,
    SavedWindowPlacement value,
  ) async =>
      (await _request(send, 'apply', placement: value))?['applied'] == true;
  bool receive(Map<String, dynamic> data) {
    if (data['type'] != 'window_geometry_reply' ||
        data.length != 4 ||
        !data.keys.toSet().containsAll({
          'type',
          'request',
          'placement',
          'applied',
        }) ||
        data['request'] is! int ||
        data['request'] < 1 ||
        data['request'] > 0x7fffffff ||
        data['applied'] is! bool ||
        (data['placement'] != null && data['placement'] is! Map))
      return false;
    if (data['placement'] is Map)
      SavedWindowPlacement.fromJson(
        Map<String, Object?>.from(data['placement'] as Map),
      );
    if (data['request'] == _serial && _pending?.isCompleted == false)
      _pending!.complete(Map<String, Object?>.from(data));
    return true; // A well-formed late reply after timeout is harmless.
  }

  void close() {
    _closed = true;
    if (_pending?.isCompleted == false) _pending!.complete(null);
    _pending = null;
  }
}

Future<Map<String, Object?>> handleWindowGeometryRequest(
  Map<String, dynamic> data, {
  WindowGeometry? geometry,
}) async {
  final request = data['request'], action = data['action'];
  if (data['type'] != 'window_geometry_request' ||
      request is! int ||
      request < 1 ||
      request > 0x7fffffff ||
      !{'get', 'apply'}.contains(action) ||
      (action == 'get'
          ? (data.length != 3 ||
                !data.keys.toSet().containsAll({'type', 'request', 'action'}))
          : (data.length != 4 ||
                !data.keys.toSet().containsAll({
                  'type',
                  'request',
                  'action',
                  'placement',
                }) ||
                data['placement'] is! Map))) {
    throw const FormatException('Invalid own-window geometry request.');
  }
  final service = geometry ?? WindowGeometry.instance;
  final placement = action == 'get' ? await service.capturePlacement() : null;
  final applied = action == 'apply'
      ? await service.restorePlacement(
          SavedWindowPlacement.fromJson(
            Map<String, Object?>.from(data['placement'] as Map),
          ),
        )
      : false;
  return {
    'type': 'window_geometry_reply',
    'request': request,
    'placement': placement?.toJson(),
    'applied': applied,
  };
}
