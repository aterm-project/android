import 'package:flutter/foundation.dart';
import 'scp_transfer_types.dart';

final sshTransferActivity = SshTransferActivity();

/// Observable real transfer bytes for application status bars.
class SshTransferActivity extends ChangeNotifier {
  final _jobs = <Object, (SshTransferCancellation, SshTransferProgress)>{};
  int get activeCount => _jobs.length;
  double? get progressFraction {
    final total = _jobs.values.fold<int>(0, (n, job) => n + job.$2.total);
    if (total == 0) return null;
    return _jobs.values.fold<int>(0, (n, job) => n + job.$2.transferred) /
        total;
  }

  String get summary => activeCount == 0
      ? 'No active transfers'
      : '$activeCount transfer${activeCount == 1 ? '' : 's'}${progressFraction == null ? '' : ' · ${(progressFraction! * 100).floor()}%'}';
  Object begin(SshTransferCancellation cancellation) {
    final id = Object();
    _jobs[id] = (
      cancellation,
      const SshTransferProgress(0, 0, SshTransferPhase.transferring),
    );
    notifyListeners();
    return id;
  }

  void update(Object id, SshTransferProgress progress) {
    final previous = _jobs[id];
    if (previous == null) return;
    _jobs[id] = (previous.$1, progress);
    notifyListeners();
  }

  void end(Object id) {
    if (_jobs.remove(id) != null) notifyListeners();
  }

  void cancelAll() {
    for (final job in _jobs.values.toList()) {
      job.$1.cancel();
    }
  }
}
