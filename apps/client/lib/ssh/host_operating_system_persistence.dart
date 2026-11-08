import '../app_controller.dart';
import '../domain/host_operating_system.dart';
import '../domain/models.dart';
import '../storage/local_host_repository.dart';

/// Best-effort encrypted metadata updates. Callers capture their connection,
/// workspace generation, and profile/account scope in [isCurrentConnection].
/// Re-read the current Host and use revision CAS so a delayed probe cannot
/// overwrite edits, resurrect a deleted Host, or cross workspace boundaries.
class HostOperatingSystemPersistence {
  static bool _sameEndpoint(HostRecord current, HostRecord connected) =>
      current.id == connected.id &&
      current.protocol == HostProtocol.ssh &&
      current.address == connected.address &&
      current.port == connected.port &&
      current.username == connected.username &&
      current.jumpHostId == connected.jumpHostId;

  static bool _keepExisting(
    HostOperatingSystem? current,
    HostOperatingSystem observation,
  ) =>
      current != null &&
      (current.sameSystem(observation) ||
          (current.family == observation.family &&
              current.distributionId != null &&
              observation.distributionId == null));

  static Future<HostRecord?> saveLocal({
    required LocalHostRepository repository,
    required HostRecord connectedHost,
    required HostOperatingSystem? observation,
    required bool Function() isCurrentConnection,
  }) async {
    if (observation == null || !isCurrentConnection()) return null;
    try {
      final current = await repository.getHost(connectedHost.id);
      if (current == null ||
          current.revisionId == null ||
          !_sameEndpoint(current, connectedHost) ||
          !isCurrentConnection()) {
        return null;
      }
      if (_keepExisting(current.detectedOperatingSystem, observation)) {
        return current;
      }
      return await repository.updateHost(
        host: current.copyWithDetectedOperatingSystem(observation),
        baseRevisionId: current.revisionId!,
      );
    } on Object {
      return null;
    }
  }

  static Future<HostRecord?> saveCloud({
    required AppController controller,
    required HostRecord connectedHost,
    required HostOperatingSystem? observation,
    required String vaultId,
    required bool Function() isCurrentConnection,
  }) async {
    if (observation == null ||
        !isCurrentConnection() ||
        controller.activeVault?.id != vaultId) {
      return null;
    }
    try {
      final accountId = controller.session?.accountId;
      final deviceId = controller.identity?.deviceId;
      final current = controller.hosts
          .where((h) => h.id == connectedHost.id)
          .firstOrNull;
      if (accountId == null ||
          deviceId == null ||
          current == null ||
          current.revisionId == null ||
          !_sameEndpoint(current, connectedHost) ||
          !isCurrentConnection()) {
        return null;
      }
      if (_keepExisting(current.detectedOperatingSystem, observation)) {
        return current;
      }
      // saveHostAtRevision also checks the cached head inside its serialized
      // mutation before encrypting, preserving concurrent editor changes.
      if (controller.activeVault?.id != vaultId ||
          controller.session?.accountId != accountId ||
          controller.identity?.deviceId != deviceId ||
          !isCurrentConnection()) {
        return null;
      }
      await controller.saveHostAtRevision(
        current.copyWithDetectedOperatingSystem(observation),
        expectedRevisionId: current.revisionId!,
        isCurrentContext: () =>
            isCurrentConnection() &&
            controller.activeVault?.id == vaultId &&
            controller.session?.accountId == accountId &&
            controller.identity?.deviceId == deviceId,
      );
      if (controller.activeVault?.id != vaultId ||
          controller.session?.accountId != accountId ||
          controller.identity?.deviceId != deviceId ||
          !isCurrentConnection()) {
        return null;
      }
      return controller.hosts
          .where((h) => h.id == connectedHost.id)
          .firstOrNull;
    } on Object {
      return null;
    }
  }
}
