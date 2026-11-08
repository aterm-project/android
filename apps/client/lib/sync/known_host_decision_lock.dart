import 'known_host_decision_lock_contract.dart';
import 'known_host_decision_lock_native.dart'
    if (dart.library.js_interop) 'known_host_decision_lock_web.dart'
    as platform;

export 'known_host_decision_lock_contract.dart';
export 'known_host_decision_lock_native.dart'
    if (dart.library.js_interop) 'known_host_decision_lock_web.dart';

KnownHostDecisionLock createKnownHostDecisionLock() =>
    platform.createKnownHostDecisionLock();
