export 'external_edit_platform_contract.dart';
export 'external_edit_platform_stub.dart'
    if (dart.library.io) 'external_edit_platform_io.dart'
    show createDefaultExternalEditPlatform;
