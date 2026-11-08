import 'package:flutter/material.dart';

import 'desktop_resolution.dart';
import '../l10n/l10n.dart';

enum DesktopResolutionKind { server, auto, fixed }

class DesktopResolutionValue {
  const DesktopResolutionValue(
    this.kind, {
    this.width = 1920,
    this.height = 1080,
  });
  final DesktopResolutionKind kind;
  final int width, height;
  String? validate({AppLocalizations? l10n}) =>
      kind == DesktopResolutionKind.fixed
      ? validateDesktopSize(width, height, l10n: l10n)
      : null;
}

/// Compact resolution selector: automatic, fixed presets, custom size and
/// (VNC only) the server-chosen size. Local scaling is a separate control so
/// it is never mistaken for a remote resolution change.
class DesktopResolutionPicker extends StatefulWidget {
  const DesktopResolutionPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.scaling,
    required this.onScalingChanged,
    this.allowServer = false,
    this.autoLabel,
    this.helper,
    this.enabled = true,
    this.keyPrefix = 'desktop',
    this.chinese = false,
  });

  /// Legacy compatibility option; labels follow the surrounding locale.
  final bool chinese;
  final DesktopResolutionValue value;
  final ValueChanged<DesktopResolutionValue> onChanged;
  final DesktopLocalScaling scaling;
  final ValueChanged<DesktopLocalScaling> onScalingChanged;
  final bool allowServer;
  final String? autoLabel;
  final String? helper;
  final bool enabled;
  final String keyPrefix;
  @override
  State<DesktopResolutionPicker> createState() =>
      _DesktopResolutionPickerState();
}

class _DesktopResolutionPickerState extends State<DesktopResolutionPicker> {
  static const _server = 'server', _auto = 'auto', _custom = 'custom';
  late final _width = TextEditingController(text: '${widget.value.width}');
  late final _height = TextEditingController(text: '${widget.value.height}');
  late bool _customSelected = _selection(widget.value) == _custom;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  static String _presetKey(DesktopResolutionPreset p) =>
      '${p.width}x${p.height}';

  String _selection(DesktopResolutionValue v) {
    switch (v.kind) {
      case DesktopResolutionKind.server:
        return _server;
      case DesktopResolutionKind.auto:
        return _auto;
      case DesktopResolutionKind.fixed:
        for (final p in desktopResolutionPresets) {
          if (p.width == v.width && p.height == v.height) return _presetKey(p);
        }
        return _custom;
    }
  }

  void _select(String? key) {
    if (key == null) return;
    setState(() => _customSelected = key == _custom);
    if (key == _server) {
      widget.onChanged(
        const DesktopResolutionValue(DesktopResolutionKind.server),
      );
    } else if (key == _auto) {
      widget.onChanged(
        const DesktopResolutionValue(DesktopResolutionKind.auto),
      );
    } else if (key == _custom) {
      _applyCustom();
    } else {
      final preset = desktopResolutionPresets.firstWhere(
        (p) => _presetKey(p) == key,
      );
      _width.text = '${preset.width}';
      _height.text = '${preset.height}';
      widget.onChanged(
        DesktopResolutionValue(
          DesktopResolutionKind.fixed,
          width: preset.width,
          height: preset.height,
        ),
      );
    }
  }

  void _applyCustom() => widget.onChanged(
    DesktopResolutionValue(
      DesktopResolutionKind.fixed,
      width: int.tryParse(_width.text.trim()) ?? 0,
      height: int.tryParse(_height.text.trim()) ?? 0,
    ),
  );

  Key _k(String name) => ValueKey('${widget.keyPrefix}_resolution_$name');

  @override
  Widget build(BuildContext context) {
    final selection = _customSelected ? _custom : _selection(widget.value);
    final error = widget.value.validate(l10n: context.l10n);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: _k('mode'),
          initialValue: selection,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.l10n.remoteResolution,
            helperText: widget.helper,
            helperMaxLines: 3,
          ),
          items: [
            if (widget.allowServer)
              DropdownMenuItem(
                value: _server,
                child: Text(context.l10n.serverDefaultDontRequestAResize),
              ),
            DropdownMenuItem(
              value: _auto,
              child: Text(
                widget.autoLabel ?? context.l10n.desktopAutomaticFitWindow,
              ),
            ),
            for (final p in desktopResolutionPresets)
              DropdownMenuItem(
                value: _presetKey(p),
                child: Text('${p.size}  ·  ${p.label}'),
              ),
            DropdownMenuItem(value: _custom, child: Text(context.l10n.custom)),
          ],
          onChanged: widget.enabled ? _select : null,
        ),
        if (selection == _custom)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: _k('width'),
                    controller: _width,
                    enabled: widget.enabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.l10n.width),
                    onChanged: (_) => _applyCustom(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: _k('height'),
                    controller: _height,
                    enabled: widget.enabled,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.l10n.height),
                    onChanged: (_) => _applyCustom(),
                  ),
                ),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              key: _k('error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 14),
        DropdownButtonFormField<DesktopLocalScaling>(
          key: _k('scaling'),
          initialValue: widget.scaling,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.l10n.localDisplay,
            helperText: context.l10n.scalesThisWindowOnlyTheRemote,
            helperMaxLines: 2,
          ),
          items: [
            DropdownMenuItem(
              value: DesktopLocalScaling.fit,
              child: Text(context.l10n.fitToWindow),
            ),
            DropdownMenuItem(
              value: DesktopLocalScaling.actualSize,
              child: Text(context.l10n.actualSize11Scrollable),
            ),
          ],
          onChanged: widget.enabled
              ? (v) {
                  if (v != null) widget.onScalingChanged(v);
                }
              : null,
        ),
      ],
    );
  }
}
