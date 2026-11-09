import 'cloud_access_crypto.dart';
import 'share_fragment.dart';

/// Holds secrets taken once from the address bar by web/share-bootstrap.js.
/// Values live only in memory for this page load.
class PendingCloudLink {
  PendingCloudLink._();

  static String? _joinToken;
  static String? _shareFragment;
  static bool _captured = false;

  /// Takes the fragment from the bootstrap (once) and sorts it by purpose.
  static void capture() {
    if (_captured) return;
    _captured = true;
    final fragment = takeShareFragment();
    if (fragment == null) return;
    if (fragment.startsWith(orgJoinFragmentPrefix)) {
      _joinToken = fragment.substring(orgJoinFragmentPrefix.length);
    } else if (fragment.startsWith(shareFragmentPrefix)) {
      _shareFragment = fragment;
    }
  }

  static bool get hasJoinToken => _joinToken != null;

  static String? takeJoinToken() {
    final value = _joinToken;
    _joinToken = null;
    return value;
  }

  static String? takeLinkFragment() {
    final value = _shareFragment;
    _shareFragment = null;
    return value;
  }
}
