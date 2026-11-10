import 'package:flutter/material.dart';

import 'desktop_resolution.dart';
import 'desktop_resolution_picker.dart';
import 'rdp_features.dart';
import 'rdp_settings.dart';
import 'rdp_storage.dart';
import '../l10n/l10n.dart';

typedef RdpFolderPicker = Future<String?> Function();

/// Host editor section for per-Host RDP options. Purely presentational: the
/// caller stores the result in the Host manifest via [RdpSettings.applyTo].
class RdpSettingsEditor extends StatefulWidget {
  const RdpSettingsEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.features,
    this.pickFolder,
    this.pickDisk,
    this.keyPrefix = 'host',
    this.unreadable = false,
  });
  final RdpSettings initial;
  final ValueChanged<RdpSettings> onChanged;
  final RdpFeatures features;
  final RdpFolderPicker? pickFolder;
  final Future<String?> Function(BuildContext)? pickDisk;
  final String keyPrefix;

  /// The stored entry was written by a newer version; saving replaces it.
  final bool unreadable;
  @override
  State<RdpSettingsEditor> createState() => _RdpSettingsEditorState();
}

enum _RdpEditorError { settings, invalidFolder }

class _RdpSettingsEditorState extends State<RdpSettingsEditor> {
  late RdpSettings _value = widget.initial;
  late final _usb = TextEditingController(
    text: widget.initial.usbDevices.join(', '),
  );
  _RdpEditorError? _error;
  String? _pickerError;
  bool _picking = false;

  @override
  void dispose() {
    _usb.dispose();
    super.dispose();
  }

  void _set(RdpSettings next) {
    setState(() {
      _value = next;
      _error = _RdpEditorError.settings;
    });
    widget.onChanged(next);
  }

  Key _k(String name) => ValueKey('${widget.keyPrefix}_rdp_$name');

  String? _unavailable(int flag) => widget.features.has(flag)
      ? null
      : context.l10n.desktopRdpEngineFeatureUnavailable;

  Widget _switch(
    String name,
    String title,
    bool value,
    ValueChanged<bool> changed, {
    int? feature,
    String? subtitle,
  }) {
    final missing = feature == null ? null : _unavailable(feature);
    return SwitchListTile(
      key: _k(name),
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: missing != null || subtitle != null
          ? Text(missing ?? subtitle!)
          : null,
      value: missing == null && value,
      onChanged: missing == null ? changed : null,
    );
  }

  Future<void> _addDrive() async {
    final picker = widget.pickFolder;
    if (picker == null) return;
    await _pickDrive(picker);
  }

  Future<void> _pickDrive(RdpFolderPicker picker) async {
    if (_picking) return;
    // Do not restore a host/password field's IME when system storage Settings
    // or the directory chooser returns to this form.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _picking = true;
      _pickerError = null;
    });
    String? path;
    try {
      path = await picker();
    } catch (error) {
      if (mounted)
        setState(
          () => _pickerError = error is RdpStorageException
              ? error.message
              : context.l10n.rdpStoragePickerFailed,
        );
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (path == null || !mounted) return;
    if (!isSafeLocalPath(path)) {
      setState(() => _error = _RdpEditorError.invalidFolder);
      return;
    }
    final diskLetter = RegExp(r'^([A-Za-z]):[\\/]*$').firstMatch(path);
    final base =
        (diskLetter != null
                ? 'Drive ${diskLetter[1]!.toUpperCase()}'
                : RegExp(r'^/storage/emulated/[0-9]+/?$').hasMatch(path)
                ? 'Local Storage'
                : path
                      .split(RegExp(r'[\\/]'))
                      .lastWhere((p) => p.isNotEmpty, orElse: () => 'Folder'))
            .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_');
    final safeBase = base.isEmpty || !RegExp('^[A-Za-z0-9]').hasMatch(base)
        ? 'Folder'
        : base.substring(0, base.length.clamp(0, 24));
    var name = safeBase;
    final used = _value.drives.map((d) => d.name.toLowerCase()).toSet();
    for (var i = 2; used.contains(name.toLowerCase()); i++) {
      name = '$safeBase $i';
    }
    _set(
      _value.copyWith(
        drives: [
          ..._value.drives,
          RdpDriveRedirect(name: name, path: path),
        ],
      ),
    );
  }

  Future<void> _renameDrive(RdpDriveRedirect drive) async {
    final controller = TextEditingController(text: drive.name);
    String? error;
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(context.l10n.rdpRenameMapping),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 31,
            decoration: InputDecoration(
              labelText: context.l10n.rdpMappingName,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                final issue =
                    RdpDriveRedirect(
                      name: value,
                      path: drive.path,
                    ).validate() ??
                    (_value.drives.any(
                          (other) =>
                              other != drive &&
                              other.name.toLowerCase() == value.toLowerCase(),
                        )
                        ? context.l10n.redirectedFolderNamesMustBeUnique
                        : null);
                if (issue != null) {
                  update(() => error = issue);
                  return;
                }
                Navigator.pop(context, value);
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    final name = await Navigator.of(context, rootNavigator: true).push(route);
    // Dispose after the route actually releases its TextField.
    await route.completed;
    controller.dispose();
    if (!mounted || name == null) return;
    _set(
      _value.copyWith(
        drives: [
          for (final other in _value.drives)
            other == drive
                ? RdpDriveRedirect(name: name, path: drive.path)
                : other,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _value;
    final error = switch (_error) {
      _RdpEditorError.invalidFolder =>
        context.l10n.desktopChooseAbsoluteLocalFolder,
      _RdpEditorError.settings =>
        (v.resolution == RdpResolutionMode.fixed
                ? validateDesktopSize(v.width, v.height, l10n: context.l10n)
                : null) ??
            v.validate(),
      null => null,
    };
    return ExpansionTile(
      key: _k('options'),
      tilePadding: EdgeInsets.zero,
      // Top inset keeps the first field's floating label clear of the header.
      childrenPadding: const EdgeInsets.only(top: 10, bottom: 8),
      title: Text(context.l10n.rdpOptions),
      subtitle: Text(context.l10n.displayClipboardAndLocalResources),
      children: [
        if (widget.unreadable)
          Text(
            context.l10n.savedRdpOptionsWereWrittenBy,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        DesktopResolutionPicker(
          keyPrefix: '${widget.keyPrefix}_rdp',
          value: DesktopResolutionValue(
            v.resolution == RdpResolutionMode.fixed
                ? DesktopResolutionKind.fixed
                : DesktopResolutionKind.auto,
            width: v.width,
            height: v.height,
          ),
          helper: v.multiMonitor
              ? context.l10n.desktopRdpMultimonResolutionHelp
              : context.l10n.desktopRdpAutomaticResolutionHelp,
          onChanged: (r) => _set(
            r.kind == DesktopResolutionKind.fixed
                ? v.copyWith(
                    resolution: RdpResolutionMode.fixed,
                    width: r.width,
                    height: r.height,
                  )
                : v.copyWith(resolution: RdpResolutionMode.fitWindow),
          ),
          scaling: v.scaling,
          onScalingChanged: (scaling) => _set(v.copyWith(scaling: scaling)),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          isExpanded: true,
          key: _k('scale'),
          initialValue: v.scalePercent,
          decoration: InputDecoration(
            labelText: context.l10n.remoteDisplayScale,
          ),
          items: [
            for (final s in RdpSettings.scales)
              DropdownMenuItem(value: s, child: Text('$s%')),
          ],
          onChanged: (s) => _set(v.copyWith(scalePercent: s)),
        ),
        _switch(
          'multimon',
          context.l10n.desktopUseAllLocalMonitors,
          v.multiMonitor,
          (on) => _set(v.copyWith(multiMonitor: on)),
          feature: RdpFeatures.multimon,
          subtitle: context.l10n.eachMonitorCanBeOpenedIn,
        ),
        _switch(
          'clipboard_text',
          context.l10n.desktopClipboardText,
          v.clipboardText,
          (on) => _set(v.copyWith(clipboardText: on)),
        ),
        _switch(
          'clipboard_files',
          context.l10n.desktopClipboardFiles,
          v.clipboardFiles,
          (on) => _set(v.copyWith(clipboardFiles: on)),
          feature: RdpFeatures.fileClipboard,
        ),
        DropdownButtonFormField<RdpAudioMode>(
          isExpanded: true,
          key: _k('audio'),
          initialValue: widget.features.has(RdpFeatures.audioOut)
              ? v.audio
              : RdpAudioMode.remote,
          decoration: InputDecoration(
            labelText: context.l10n.remoteAudio,
            helperText: _unavailable(RdpFeatures.audioOut),
          ),
          items: [
            DropdownMenuItem(
              value: RdpAudioMode.local,
              child: Text(context.l10n.playOnThisComputer),
            ),
            DropdownMenuItem(
              value: RdpAudioMode.remote,
              child: Text(context.l10n.leaveOnRemoteComputer),
            ),
            DropdownMenuItem(
              value: RdpAudioMode.off,
              child: Text(context.l10n.doNotPlay),
            ),
          ],
          onChanged: widget.features.has(RdpFeatures.audioOut)
              ? (mode) => _set(v.copyWith(audio: mode))
              : null,
        ),
        _switch(
          'microphone',
          context.l10n.desktopMicrophone,
          v.microphone,
          (on) => _set(v.copyWith(microphone: on)),
          feature: RdpFeatures.audioIn,
        ),
        DropdownButtonFormField<RdpPrinterMode>(
          isExpanded: true,
          key: _k('printers'),
          initialValue: widget.features.has(RdpFeatures.printer)
              ? v.printers
              : RdpPrinterMode.off,
          decoration: InputDecoration(
            labelText: context.l10n.printers,
            helperText:
                _unavailable(RdpFeatures.printer) ??
                context.l10n.requiresAMatchingPrinterDriverOn,
            helperMaxLines: 2,
          ),
          items: [
            DropdownMenuItem(
              value: RdpPrinterMode.off,
              child: Text(context.l10n.off2),
            ),
            DropdownMenuItem(
              value: RdpPrinterMode.defaultPrinter,
              child: Text(context.l10n.defaultPrinter),
            ),
            DropdownMenuItem(
              value: RdpPrinterMode.all,
              child: Text(context.l10n.allPrinters),
            ),
          ],
          onChanged: widget.features.has(RdpFeatures.printer)
              ? (mode) => _set(v.copyWith(printers: mode))
              : null,
        ),
        _switch(
          'smart_cards',
          context.l10n.desktopSmartCards,
          v.smartCards,
          (on) => _set(v.copyWith(smartCards: on)),
          feature: RdpFeatures.smartcard,
        ),
        _switch(
          'cameras',
          context.l10n.desktopCameras,
          v.cameras,
          (on) => _set(v.copyWith(cameras: on)),
          feature: RdpFeatures.camera,
          subtitle: context.l10n.requiresCameraRedirectionSupportOnThe,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(context.l10n.redirectedFolders),
            if (widget.pickDisk != null)
              TextButton.icon(
                key: _k('add_disk'),
                onPressed:
                    widget.features.has(RdpFeatures.drive) &&
                        !_picking &&
                        v.drives.length < RdpSettings.maxDrives
                    ? () => _pickDrive(() => widget.pickDisk!(context))
                    : null,
                icon: const Icon(Icons.storage_outlined),
                label: Text(context.l10n.rdpAddDisk),
              ),
            TextButton.icon(
              key: _k('add_drive'),
              onPressed:
                  widget.features.has(RdpFeatures.drive) &&
                      widget.pickFolder != null &&
                      !_picking &&
                      v.drives.length < RdpSettings.maxDrives
                  ? _addDrive
                  : null,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(context.l10n.addFolder),
            ),
          ],
        ),
        if (_pickerError != null)
          Text(_pickerError!, style: TextStyle(color: theme.colorScheme.error)),
        if (widget.features.has(RdpFeatures.drive))
          Text(
            context.l10n.rdpDriveMappingHelp,
            style: theme.textTheme.bodySmall,
          ),
        if (!widget.features.has(RdpFeatures.drive))
          Text(
            _unavailable(RdpFeatures.drive)!,
            style: theme.textTheme.bodySmall,
          ),
        for (final drive in v.drives)
          ListTile(
            key: _k('drive_${drive.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(drive.name),
            subtitle: Text(drive.path),
            onTap: () => _renameDrive(drive),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.l10n.rdpRenameMapping,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _renameDrive(drive),
                ),
                IconButton(
                  tooltip: context.l10n.removeFolder,
                  icon: const Icon(Icons.close),
                  onPressed: () => _set(
                    v.copyWith(
                      drives: [
                        for (final d in v.drives)
                          if (d != drive) d,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        TextField(
          key: _k('usb'),
          controller: _usb,
          enabled: widget.features.has(RdpFeatures.usb),
          decoration: InputDecoration(
            labelText: context.l10n.usbDevicesVendorProduct,
            helperText:
                _unavailable(RdpFeatures.usb) ??
                context.l10n.onlyDevicesAlreadyUsingTheWinusb,
            helperMaxLines: 2,
          ),
          onChanged: (t) => _set(
            v.copyWith(
              usbDevices: [
                for (final id in t.split(RegExp(r'[,\s]+')))
                  if (id.isNotEmpty) id.toLowerCase(),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error,
            key: _k('error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

/// Host editor section for VNC display preferences.
class VncSettingsEditor extends StatefulWidget {
  const VncSettingsEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.keyPrefix = 'host',
  });
  final VncSettings initial;
  final ValueChanged<VncSettings> onChanged;
  final String keyPrefix;
  @override
  State<VncSettingsEditor> createState() => _VncSettingsEditorState();
}

class _VncSettingsEditorState extends State<VncSettingsEditor> {
  late VncSettings _value = widget.initial;

  void _set(VncSettings next) {
    setState(() => _value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    return ExpansionTile(
      key: ValueKey('${widget.keyPrefix}_vnc_options'),
      tilePadding: EdgeInsets.zero,
      // Top inset keeps the first field's floating label clear of the header.
      childrenPadding: const EdgeInsets.only(top: 10, bottom: 8),
      title: Text(context.l10n.vncDisplay),
      subtitle: Text(context.l10n.resolutionAndLocalScaling),
      children: [
        DesktopResolutionPicker(
          keyPrefix: '${widget.keyPrefix}_vnc',
          allowServer: true,
          value: DesktopResolutionValue(
            switch (v.resolution) {
              VncResolutionMode.server => DesktopResolutionKind.server,
              VncResolutionMode.fitWindow => DesktopResolutionKind.auto,
              VncResolutionMode.fixed => DesktopResolutionKind.fixed,
            },
            width: v.width,
            height: v.height,
          ),
          helper: context.l10n.desktopVncResizeHelp,
          onChanged: (r) => _set(switch (r.kind) {
            DesktopResolutionKind.server => v.copyWith(
              resolution: VncResolutionMode.server,
            ),
            DesktopResolutionKind.auto => v.copyWith(
              resolution: VncResolutionMode.fitWindow,
            ),
            DesktopResolutionKind.fixed => v.copyWith(
              resolution: VncResolutionMode.fixed,
              width: r.width,
              height: r.height,
            ),
          }),
          scaling: v.scaling,
          onScalingChanged: (scaling) => _set(v.copyWith(scaling: scaling)),
        ),
      ],
    );
  }
}
