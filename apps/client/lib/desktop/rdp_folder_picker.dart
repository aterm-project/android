import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'rdp_storage.dart';
import 'rdp_storage_stub.dart' if (dart.library.io) 'rdp_storage_io.dart';

/// Folder chooser for RDP drive redirection; unavailable on the web.
Future<String?> pickRdpRedirectFolder() async {
  if (kIsWeb) return null;
  await requestRdpStorageAccess();
  return FilePicker.platform.getDirectoryPath(
    dialogTitle: currentL10n.addFolder,
  );
}

bool get rdpDiskPickerAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows);

Future<String?> pickRdpRedirectDisk(BuildContext context) async {
  await requestRdpStorageAccess();
  final roots = await localRdpStorageRoots();
  if (!context.mounted) return null;
  if (roots.isEmpty)
    throw const RdpStorageException(RdpStorageIssue.unavailable);
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(context.l10n.rdpChooseDisk),
      children: [
        for (final root in roots)
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(
              root.label.isEmpty ? context.l10n.rdpLocalStorage : root.label,
            ),
            subtitle: Text(root.path),
            onTap: () => Navigator.pop(context, root.path),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
      ],
    ),
  );
}
