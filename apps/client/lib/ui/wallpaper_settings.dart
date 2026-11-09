import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../storage/wallpaper_store.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'wallpaper.dart';

/// Returns the picked image content, or null when the user cancelled.
typedef WallpaperImagePicker = Future<Uint8List?> Function();

/// Opens the platform picker for PNG/JPEG/WebP. Only the content is used and
/// the path is never stored or logged. Nothing is loaded eagerly: browsers
/// hand over a lazy blob-slice stream, native platforms a path.
Future<Uint8List?> pickWallpaperImageBytes() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: wallpaperAllowedExtensions,
    allowMultiple: false,
    withData: false,
    withReadStream: kIsWeb,
  );
  final files = result?.files ?? const <PlatformFile>[];
  if (files.isEmpty) return null;
  if (files.length != 1) {
    throw const WallpaperImageException(WallpaperImageError.unsupported);
  }
  return readPickedWallpaperFile(files.single);
}

/// Reads a picked file within [maxBytes]: the reported size is checked
/// before any content is requested, and the content read itself stops at
/// the bound (a source that grows or under-reports its size is cut off).
@visibleForTesting
Future<Uint8List> readPickedWallpaperFile(
  PlatformFile file, {
  int maxBytes = wallpaperMaxEncodedBytes,
}) async {
  const tooLarge = WallpaperImageException(WallpaperImageError.tooLarge);
  if (file.size > maxBytes) throw tooLarge;
  try {
    if (file.readStream case final stream?) {
      return await readBoundedWallpaperBytes(stream, maxBytes: maxBytes);
    }
    if (file.bytes case final bytes?) {
      if (bytes.length > maxBytes) throw tooLarge;
      return bytes;
    }
    final path = kIsWeb ? null : file.path;
    if (path == null) {
      throw const WallpaperImageException(WallpaperImageError.corrupt);
    }
    return await readWallpaperSourceFile(path, maxBytes: maxBytes);
  } on WallpaperSourceTooLargeException {
    throw tooLarge;
  } on WallpaperImageException {
    rethrow;
  } on Object {
    throw const WallpaperImageException(WallpaperImageError.storage);
  }
}

String wallpaperErrorText(AppLocalizations l10n, WallpaperImageError error) =>
    switch (error) {
      WallpaperImageError.tooLarge => l10n.wallpaperErrorTooLarge(
        wallpaperMaxEncodedBytes ~/ (1024 * 1024),
      ),
      WallpaperImageError.unsupported => l10n.wallpaperErrorUnsupported,
      WallpaperImageError.corrupt => l10n.wallpaperErrorCorrupt,
      WallpaperImageError.dimensions => l10n.wallpaperErrorDimensions(
        wallpaperMaxSourceSide,
      ),
      WallpaperImageError.storage => l10n.wallpaperErrorStorage,
    };

/// Theme settings card: preview, choose/replace, remove, layout mode, blur.
class WallpaperSettings extends StatefulWidget {
  const WallpaperSettings({this.controller, this.pickImage, super.key});

  final WallpaperController? controller;
  final WallpaperImagePicker? pickImage;

  @override
  State<WallpaperSettings> createState() => _WallpaperSettingsState();
}

class _WallpaperSettingsState extends State<WallpaperSettings> {
  WallpaperImageError? _pickError;
  bool _picking = false;

  WallpaperController get _wallpapers =>
      widget.controller ?? WallpaperController.of(context);

  Future<void> _choose() async {
    if (_picking || _wallpapers.busy) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    try {
      final bytes = await (widget.pickImage ?? pickWallpaperImageBytes)();
      if (bytes == null || !mounted) return;
      await _wallpapers.setImageBytes(bytes);
    } on WallpaperImageException catch (error) {
      if (mounted) setState(() => _pickError = error.error);
    } on Object {
      if (mounted) setState(() => _pickError = WallpaperImageError.storage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallpapers = _wallpapers;
    return ListenableBuilder(
      listenable: wallpapers,
      builder: (context, _) {
        final l10n = context.l10n;
        final palette = context.palette;
        final density = AppDensity.of(context);
        final busy = _picking || wallpapers.busy;
        final error = _pickError ?? wallpapers.lastError;
        final missing =
            wallpapers.status == WallpaperStatus.missing ||
            wallpapers.status == WallpaperStatus.failed;
        return Column(
          key: const ValueKey('wallpaper_settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.wallpaper_outlined, size: 20, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.wallpaperSettingTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.wallpaperSettingDescription,
              style: TextStyle(color: palette.muted, height: 1.4),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _Preview(
                  controller: wallpapers,
                  radius: density.radiusMd,
                  label: wallpapers.active
                      ? null
                      : wallpapers.status == WallpaperStatus.loading
                      ? l10n.wallpaperLoading
                      : l10n.wallpaperNoImage,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('wallpaper_choose'),
                  onPressed: busy ? null : () => unawaited(_choose()),
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_outlined, size: 18),
                  label: Text(
                    wallpapers.hasImage
                        ? l10n.wallpaperReplaceImage
                        : l10n.wallpaperChooseImage,
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('wallpaper_reset'),
                  onPressed: busy || !wallpapers.hasImage
                      ? null
                      : () {
                          setState(() => _pickError = null);
                          unawaited(wallpapers.reset());
                        },
                  icon: const Icon(Icons.hide_image_outlined, size: 18),
                  label: Text(l10n.wallpaperReset),
                ),
              ],
            ),
            if (error != null || missing) ...[
              const SizedBox(height: 8),
              Text(
                error != null
                    ? wallpaperErrorText(l10n, error)
                    : l10n.wallpaperMissing,
                key: const ValueKey('wallpaper_error'),
                style: TextStyle(color: palette.red, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              l10n.wallpaperModeTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Semantics(
              container: true,
              label: l10n.wallpaperModeTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final mode in WallpaperLayoutMode.values)
                    _ModeOption(
                      mode: mode,
                      selected: wallpapers.mode == mode,
                      onSelected: () => wallpapers.setMode(mode),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.wallpaperBlurValue(wallpapers.blur.toStringAsFixed(1)),
              key: const ValueKey('wallpaper_blur_value'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Slider(
              key: const ValueKey('wallpaper_blur'),
              value: wallpapers.blur,
              max: wallpaperMaxBlur,
              divisions: (wallpaperMaxBlur * 2).round(),
              label: wallpapers.blur.toStringAsFixed(1),
              onChanged: (value) => wallpapers.setBlur(value, persist: false),
              onChangeEnd: (value) => wallpapers.setBlur(value),
            ),
            Text(
              wallpapers.writeFailed
                  ? l10n.wallpaperSaveFailed
                  : l10n.wallpaperDeviceNote,
              key: const ValueKey('wallpaper_storage_note'),
              style: TextStyle(
                color: wallpapers.writeFailed ? palette.orange : palette.muted,
                fontSize: 12,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.controller,
    required this.radius,
    required this.label,
  });

  final WallpaperController controller;
  final double radius;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      key: const ValueKey('wallpaper_preview'),
      image: true,
      label: context.l10n.wallpaperPreviewLabel,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceSoft,
            border: Border.all(color: palette.line),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: label == null
                ? WallpaperImageLayer(controller: controller, scrim: true)
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        label!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.onSelected,
  });

  final WallpaperLayoutMode mode;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final (title, subtitle, icon) = switch (mode) {
      WallpaperLayoutMode.window => (
        l10n.wallpaperModeWindow,
        l10n.wallpaperModeWindowHint,
        Icons.crop_landscape_outlined,
      ),
      WallpaperLayoutMode.panes => (
        l10n.wallpaperModePanes,
        l10n.wallpaperModePanesHint,
        Icons.vertical_split_outlined,
      ),
    };
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListTile(
        key: ValueKey('wallpaper_mode_${mode.code}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedColor: palette.accentText,
        selectedTileColor: palette.accent.withValues(alpha: 0.12),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? palette.accentText : palette.muted,
          size: 20,
        ),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: Icon(icon, size: 18, color: palette.muted),
        onTap: onSelected,
      ),
    );
  }
}
