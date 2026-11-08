import '../app_controller.dart';
import '../domain/models.dart';
import '../storage/local_host_repository.dart';
import 'desktop_resolution.dart';
import 'rdp_settings.dart';
import '../l10n/l10n.dart';

/// Trust belongs to the encrypted Host, with revision checks to preserve edits.
class RdpCertificatePersistence {
  static HostRecord _updated(
    HostRecord? current,
    HostRecord reviewed,
    String pin,
  ) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pin) ||
        current == null ||
        current.revisionId == null ||
        current.id != reviewed.id ||
        current.protocol != HostProtocol.rdp ||
        current.address != reviewed.address ||
        current.port != reviewed.port ||
        current.username != reviewed.username ||
        (current.rdpCertificateSha256 != reviewed.rdpCertificateSha256 &&
            current.rdpCertificateSha256 != pin)) {
      throw StateError(currentL10n.theHostOrCertificateTrustChanged);
    }
    return current.copyWith(rdpCertificateSha256: pin);
  }

  static Future<HostRecord> saveLocal({
    required LocalHostRepository repository,
    required HostRecord reviewed,
    required String pin,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    final current = await repository.getHost(reviewed.id);
    final updated = _updated(current, reviewed, pin);
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    return repository.updateHost(
      host: updated,
      baseRevisionId: current!.revisionId!,
    );
  }

  static Future<HostRecord> saveCloud({
    required AppController controller,
    required HostRecord reviewed,
    required String pin,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    final current = controller.hosts
        .where((h) => h.id == reviewed.id)
        .firstOrNull;
    final updated = _updated(current, reviewed, pin);
    await controller.saveHostAtRevision(
      updated,
      expectedRevisionId: current!.revisionId!,
      isCurrentContext: isCurrent,
    );
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    final saved = controller.hosts
        .where((h) => h.id == reviewed.id)
        .firstOrNull;
    if (saved?.rdpCertificateSha256 != pin) throw StateError(currentL10n.couldntSaveTheCertificate);
    return saved!;
  }
}

/// Persists an in-session display change on top of the *current* Host
/// revision. Only the display fields a session can change (remote resolution
/// mode/size and local scaling) are taken from the session; every other field
/// — redirection (drives, clipboard, audio/mic, printers, smart cards,
/// cameras, USB), scale and multi-monitor — comes from the latest saved
/// settings, so a session started before a Host edit can never re-enable a
/// redirection the user has since turned off. A deleted/changed Host, or a
/// settings entry written by a newer version, is refused rather than
/// overwritten.
class DesktopDisplayPersistence {
  static HostRecord _merged(HostRecord? current, HostRecord updated) {
    if (current == null ||
        current.revisionId == null ||
        current.id != updated.id ||
        current.protocol != updated.protocol ||
        current.address != updated.address ||
        current.port != updated.port) {
      throw StateError(currentL10n.theHostChangedTheResolutionSetting);
    }
    final Map<String, Object?>? manifest;
    switch (current.protocol) {
      case HostProtocol.rdp:
        if (RdpSettings.unreadable(current)) {
          throw StateError(currentL10n.theHostsRdpOptionsWereSaved);
        }
        final wanted = RdpSettings.of(updated);
        manifest = RdpSettings.of(current)
            .copyWith(
              resolution: wanted.resolution,
              width: wanted.width,
              height: wanted.height,
              scaling: wanted.scaling,
            )
            .applyTo(current.manifest);
      case HostProtocol.vnc:
        final raw = current.manifest?[vncSettingsManifestKey];
        if (raw != null) {
          try {
            VncSettings.fromJson(raw);
          } on FormatException {
            throw StateError(currentL10n.theHostsVncDisplaySettingsWere);
          }
        }
        // Every VNC setting is a display setting.
        manifest = VncSettings.of(updated).applyTo(current.manifest);
      case HostProtocol.ssh:
        throw StateError(currentL10n.sshHostsDontHaveRemoteDesktop);
    }
    return current.copyWith(manifest: manifest, clearManifest: manifest == null);
  }

  static Future<HostRecord> saveLocal({
    required LocalHostRepository repository,
    required HostRecord updated,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    final current = await repository.getHost(updated.id);
    final merged = _merged(current, updated);
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    return repository.updateHost(
      host: merged,
      baseRevisionId: current!.revisionId!,
    );
  }

  static Future<HostRecord> saveCloud({
    required AppController controller,
    required HostRecord updated,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    final current = controller.hosts.where((h) => h.id == updated.id).firstOrNull;
    final merged = _merged(current, updated);
    await controller.saveHostAtRevision(
      merged,
      expectedRevisionId: current!.revisionId!,
      isCurrentContext: isCurrent,
    );
    if (!isCurrent()) throw StateError(currentL10n.theWorkspaceChanged);
    return controller.hosts.firstWhere((h) => h.id == updated.id);
  }
}
