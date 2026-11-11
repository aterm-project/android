import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';

/// Plain text surrounding a terminal selection, used by the compact preview
/// shown while a touch selection is being dragged.
///
/// Only a bounded window of the buffer is ever read: at most [contextCells]
/// cells on each side, crossing soft-wrapped rows of the same logical line but
/// never hard line breaks, and only the head and tail of a long selection. A
/// selection spanning the whole scrollback therefore costs the same as a
/// one-word selection.
@immutable
class TerminalSelectionContext {
  const TerminalSelectionContext({
    required this.before,
    required this.selected,
    required this.after,
    this.truncatedBefore = false,
    this.truncatedAfter = false,
    this.selectedElided = false,
  });

  /// Text of the same logical line immediately before the selection.
  final String before;

  /// The selected text, with only its head and tail when [selectedElided].
  final String selected;

  /// Text of the same logical line immediately after the selection.
  final String after;

  /// True when the logical line continues before [before].
  final bool truncatedBefore;

  /// True when the logical line continues after [after].
  final bool truncatedAfter;

  /// True when the middle of [selected] was replaced by an ellipsis.
  final bool selectedElided;

  static const ellipsis = '…';

  /// One-line display form: hard line breaks inside the selection become a
  /// visible return symbol so the preview never grows vertically.
  static String displayText(String text) =>
      text.replaceAll('\r', '').replaceAll('\n', ' ⏎ ');

  /// The preview as one string, for accessibility and tests.
  String get plainText =>
      '${truncatedBefore ? ellipsis : ''}$before${displayText(selected)}'
      '$after${truncatedAfter ? ellipsis : ''}';

  /// Describes [range] in [buffer]. A collapsed [range] yields the text
  /// around a single position with an empty [selected].
  static TerminalSelectionContext? describe(
    Buffer buffer,
    BufferRange range, {
    int contextCells = 20,
    int maxSelectedCharacters = 24,
  }) {
    final lines = buffer.lines;
    final height = lines.length;
    if (height == 0) return null;

    CellOffset clampOffset(CellOffset offset) {
      final y = offset.y.clamp(0, height - 1);
      return CellOffset(offset.x.clamp(0, lines[y].length), y);
    }

    final normalized = range.normalized;
    final begin = clampOffset(normalized.begin);
    final end = clampOffset(normalized.end);

    // Preceding context, following soft wraps backwards.
    var bx = begin.x;
    var by = begin.y;
    var remaining = contextCells;
    while (true) {
      final take = math.min(bx, remaining);
      bx -= take;
      remaining -= take;
      if (remaining > 0 && bx == 0 && by > 0 && lines[by].isWrapped) {
        by--;
        bx = lines[by].length;
        continue;
      }
      break;
    }
    final before = buffer.getText(
      BufferRangeLine(CellOffset(bx, by), begin),
    );
    final truncatedBefore =
        (bx > 0 && lines[by].getText(0, bx).trim().isNotEmpty) ||
            (bx == 0 && by > 0 && lines[by].isWrapped);

    // Following context, following soft wraps forwards.
    var ax = end.x;
    var ay = end.y;
    remaining = contextCells;
    while (true) {
      final lineLength = lines[ay].length;
      final take = math.min(math.max(lineLength - ax, 0), remaining);
      ax += take;
      remaining -= take;
      if (remaining > 0 &&
          ax >= lineLength &&
          ay + 1 < height &&
          lines[ay + 1].isWrapped) {
        ay++;
        ax = 0;
        continue;
      }
      break;
    }
    final after =
        buffer.getText(BufferRangeLine(end, CellOffset(ax, ay))).trimRight();
    final truncatedAfter = (ax < lines[ay].length &&
            lines[ay].getText(ax).trim().isNotEmpty) ||
        (ax >= lines[ay].length && ay + 1 < height && lines[ay + 1].isWrapped);

    // Selected text: read everything only when it is small; otherwise read a
    // bounded head and tail so huge selections stay cheap.
    final width = math.max(buffer.viewWidth, 1);
    final half = math.max(maxSelectedCharacters ~/ 2, 1);
    final spanCells = (end.y - begin.y) * width + (end.x - begin.x);
    String selected;
    var elided = false;
    if (spanCells <= maxSelectedCharacters * 4) {
      selected = buffer.getText(BufferRangeLine(begin, end));
    } else {
      selected = '';
      elided = true;
    }
    if (elided || selected.characters.length > maxSelectedCharacters) {
      final windowCells = half * 2 + 2;
      final headEnd = _advance(begin, windowCells, width, end);
      final tailStart = _retreat(end, windowCells, width, begin);
      final head = buffer
          .getText(BufferRangeLine(begin, headEnd))
          .characters
          .take(half)
          .toString();
      final tail = buffer
          .getText(BufferRangeLine(tailStart, end))
          .characters
          .takeLast(half)
          .toString();
      selected = '$head$ellipsis$tail';
      elided = true;
    }

    return TerminalSelectionContext(
      before: before,
      selected: selected,
      after: after,
      truncatedBefore: truncatedBefore,
      truncatedAfter: truncatedAfter,
      selectedElided: elided,
    );
  }

  static CellOffset _advance(
    CellOffset from,
    int cells,
    int width,
    CellOffset limit,
  ) {
    var x = from.x + cells;
    var y = from.y;
    while (x > width && y < limit.y) {
      x -= width;
      y++;
    }
    final result = CellOffset(math.min(x, width), y);
    return result.isAfter(limit) ? limit : result;
  }

  static CellOffset _retreat(
    CellOffset from,
    int cells,
    int width,
    CellOffset limit,
  ) {
    var x = from.x - cells;
    var y = from.y;
    while (x < 0 && y > limit.y) {
      x += width;
      y--;
    }
    final result = CellOffset(math.max(x, 0), y);
    return result.isBefore(limit) ? limit : result;
  }
}

/// Touch selection chrome for [TerminalView]: the platform magnifier and a
/// compact context preview while a long-press selection is dragged, and the
/// platform-adaptive Copy/Paste toolbar after the finger is released.
///
/// The gesture handler drives this through [TerminalTouchSelectionState]; the
/// widget itself never consumes pointer events on the terminal surface, so
/// desktop mouse selection, scrolling and hardware keyboard input are not
/// affected.
class TerminalTouchSelection extends StatefulWidget {
  const TerminalTouchSelection({
    super.key,
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.renderTerminal,
    required this.textStyle,
    required this.readOnly,
    required this.onPaste,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final FocusNode focusNode;

  final ScrollController scrollController;

  /// Returns the laid-out terminal render object, or null when unavailable.
  final RenderTerminal? Function() renderTerminal;

  final TerminalStyle textStyle;

  /// Paste is offered only while this is false.
  final bool readOnly;

  /// Sends pasted clipboard text to the terminal.
  final ValueChanged<String> onPaste;

  final Widget child;

  @override
  State<TerminalTouchSelection> createState() => TerminalTouchSelectionState();
}

enum _TouchSelectionPhase { idle, dragging, toolbar }

class TerminalTouchSelectionState extends State<TerminalTouchSelection> {
  final _portal = OverlayPortalController();

  final _magnifierController = MagnifierController();

  final _magnifierInfo = ValueNotifier<MagnifierInfo>(MagnifierInfo.empty);

  var _phase = _TouchSelectionPhase.idle;

  /// Latest finger position of the active drag, in global coordinates.
  Offset? _dragGlobal;

  /// Buffer cell the paste-only toolbar is anchored to.
  CellOffset? _pasteCell;

  /// Whether the visible toolbar was opened for a selection (Copy) rather
  /// than for an empty long press (Paste only).
  var _toolbarForSelection = false;

  var _magnifierShown = false;

  var _refreshScheduled = false;

  var _hadFocus = false;

  /// True while the long-press selection is being dragged.
  bool get isDragging => _phase == _TouchSelectionPhase.dragging;

  /// True while the Copy/Paste toolbar is requested.
  bool get isToolbarVisible => _phase == _TouchSelectionPhase.toolbar;

  /// The platform magnifier geometry most recently published during a drag.
  @visibleForTesting
  MagnifierInfo get magnifierInfo => _magnifierInfo.value;

  /// True while the platform magnifier is inserted in the overlay.
  @visibleForTesting
  bool get isMagnifierShown => _magnifierShown;

  @override
  void initState() {
    super.initState();
    _attach(widget);
    _hadFocus = widget.focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(TerminalTouchSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final terminalChanged = !identical(oldWidget.terminal, widget.terminal);
    final controllerChanged =
        !identical(oldWidget.controller, widget.controller);
    if (terminalChanged ||
        controllerChanged ||
        !identical(oldWidget.focusNode, widget.focusNode) ||
        !identical(oldWidget.scrollController, widget.scrollController)) {
      _detach(oldWidget);
      _attach(widget);
      _hadFocus = widget.focusNode.hasFocus;
    }
    if (terminalChanged || controllerChanged) {
      // The session behind this view was replaced: its selection chrome no
      // longer describes anything on screen.
      _dismiss(syncPortalNow: false);
      if (terminalChanged && !controllerChanged) {
        final controller = widget.controller;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              identical(widget.controller, controller) &&
              controller.selection != null) {
            controller.clearSelection();
          }
        });
      }
    } else if (oldWidget.readOnly != widget.readOnly &&
        widget.readOnly &&
        isToolbarVisible &&
        !_toolbarForSelection) {
      // A paste-only toolbar has nothing left to offer.
      _dismiss(syncPortalNow: false);
    }
  }

  @override
  void dispose() {
    _detach(widget);
    // Without an animation controller this removes the entry synchronously.
    _magnifierController.hide();
    _magnifierInfo.dispose();
    super.dispose();
  }

  void _attach(TerminalTouchSelection target) {
    target.controller.addListener(_onControllerChanged);
    target.terminal.addListener(_onGeometryChanged);
    target.scrollController.addListener(_onGeometryChanged);
    target.focusNode.addListener(_onFocusChanged);
  }

  void _detach(TerminalTouchSelection target) {
    target.controller.removeListener(_onControllerChanged);
    target.terminal.removeListener(_onGeometryChanged);
    target.scrollController.removeListener(_onGeometryChanged);
    target.focusNode.removeListener(_onFocusChanged);
  }

  // ---------------------------------------------------------------------------
  // Gesture entry points (called by the terminal gesture handler).

  /// A touch long press started at [globalPosition]; the selection has
  /// already been updated by the caller.
  void beginDrag(Offset globalPosition) {
    _phase = _TouchSelectionPhase.dragging;
    _dragGlobal = globalPosition;
    _pasteCell = null;
    _updateMagnifier(globalPosition, show: true);
    _syncPortal();
    _markNeedsBuild();
  }

  /// The long press moved to [globalPosition]; the selection has already
  /// been extended by the caller.
  void updateDrag(Offset globalPosition) {
    if (!isDragging) return;
    _dragGlobal = globalPosition;
    _updateMagnifier(globalPosition);
    _markNeedsBuild();
  }

  /// The finger was lifted: hide drag chrome and offer Copy (and Paste when
  /// writable) for the selection, or Paste alone after an empty long press.
  void endDrag([Offset? globalPosition]) {
    if (!isDragging) return;
    final position = globalPosition ?? _dragGlobal;
    _hideMagnifier();
    _dragGlobal = null;
    if (widget.controller.selection != null) {
      _showToolbar(forSelection: true);
    } else if (!widget.readOnly && position != null) {
      final render = _render();
      _pasteCell = render?.getCellOffset(render.globalToLocal(position));
      if (_pasteCell != null) {
        _showToolbar(forSelection: false);
      } else {
        _dismiss();
      }
    } else {
      _dismiss();
    }
  }

  /// The long press was cancelled by the platform; keep any selection but
  /// show no toolbar.
  void cancelDrag() {
    if (!isDragging) return;
    _dismiss();
  }

  /// Shows the toolbar for an existing selection made by touch (for example a
  /// double tap on a word).
  void showToolbarForSelection() {
    if (widget.controller.selection == null) return;
    _hideMagnifier();
    _showToolbar(forSelection: true);
  }

  /// Hides the magnifier, the preview and the toolbar. The selection itself
  /// is left untouched.
  void hide() => _dismiss();

  // ---------------------------------------------------------------------------

  void _showToolbar({required bool forSelection}) {
    _toolbarForSelection = forSelection;
    _phase = _TouchSelectionPhase.toolbar;
    _syncPortal();
    _markNeedsBuild();
  }

  void _dismiss({bool syncPortalNow = true}) {
    _hideMagnifier();
    final wasIdle = _phase == _TouchSelectionPhase.idle;
    _phase = _TouchSelectionPhase.idle;
    _dragGlobal = null;
    _pasteCell = null;
    if (wasIdle) return;
    if (syncPortalNow) {
      _syncPortal();
      _markNeedsBuild();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPortal();
      });
    }
  }

  void _syncPortal() {
    final wantsPortal = _phase != _TouchSelectionPhase.idle;
    if (wantsPortal == _portal.isShowing) return;
    if (wantsPortal) {
      if (Overlay.maybeOf(context, rootOverlay: true) == null) return;
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  void _markNeedsBuild() {
    if (mounted) setState(() {});
  }

  RenderTerminal? _render() {
    final render = widget.renderTerminal();
    if (render == null || !render.attached || !render.hasSize) return null;
    return render;
  }

  void _onControllerChanged() {
    if (isToolbarVisible &&
        (widget.controller.selection != null) != _toolbarForSelection) {
      // The selection was cleared (tap, copy, keyboard, scrolled out of the
      // scrollback) or a different kind of selection replaced it.
      _dismiss();
      return;
    }
    _onGeometryChanged();
  }

  void _onGeometryChanged() {
    if (_phase == _TouchSelectionPhase.idle || _refreshScheduled) return;
    // Wait for the terminal to lay out with the new content or scroll offset
    // before re-anchoring the chrome to it.
    _refreshScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted || _phase == _TouchSelectionPhase.idle) return;
      final drag = _dragGlobal;
      if (isDragging && drag != null) _updateMagnifier(drag);
      _markNeedsBuild();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _onFocusChanged() {
    final hasFocus = widget.focusNode.hasFocus;
    if (_hadFocus && !hasFocus && isToolbarVisible) {
      _dismiss();
    }
    _hadFocus = hasFocus;
  }

  void _onTapOutside(PointerDownEvent event) {
    if (isToolbarVisible) _dismiss();
  }

  // ---------------------------------------------------------------------------
  // Magnifier

  MagnifierInfo? _magnifierInfoFor(Offset globalPosition) {
    final render = _render();
    if (render == null) return null;
    final origin = render.localToGlobal(Offset.zero);
    final cell = render.getCellOffset(render.globalToLocal(globalPosition));
    return MagnifierInfo(
      globalGesturePosition: globalPosition,
      caretRect: render.cellRect(cell).shift(origin),
      fieldBounds: origin & render.size,
      currentLineBoundaries: render.rowRect(cell.y).shift(origin),
    );
  }

  void _updateMagnifier(Offset globalPosition, {bool show = false}) {
    final info = _magnifierInfoFor(globalPosition);
    if (info == null) return;
    _magnifierInfo.value = info;
    if (!show || _magnifierShown) return;
    if (Overlay.maybeOf(context, rootOverlay: true) == null) return;
    final magnifier = TextMagnifier.adaptiveMagnifierConfiguration
        .magnifierBuilder(context, _magnifierController, _magnifierInfo);
    if (magnifier == null) return;
    _magnifierShown = true;
    _magnifierController.show(
      context: context,
      builder: (_) => magnifier,
    );
  }

  void _hideMagnifier() {
    if (!_magnifierShown) return;
    _magnifierShown = false;
    _magnifierController.hide();
  }

  // ---------------------------------------------------------------------------
  // Clipboard actions

  Future<void> _copy() async {
    final selection = widget.controller.selection;
    if (selection == null) {
      _dismiss();
      return;
    }
    final text = widget.terminal.buffer.getText(selection);
    _dismiss();
    widget.controller.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _paste() async {
    final terminal = widget.terminal;
    _dismiss();
    if (widget.readOnly) return;
    if (widget.controller.selection != null) {
      widget.controller.clearSelection();
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    // The view may have become read-only or been bound to another session
    // while the platform clipboard was read.
    if (!mounted ||
        widget.readOnly ||
        !identical(widget.terminal, terminal) ||
        text == null ||
        text.isEmpty) {
      return;
    }
    widget.onPaste(text);
  }

  // ---------------------------------------------------------------------------
  // Geometry

  /// The part of the terminal that is actually visible: the render box
  /// intersected with the view minus system padding and the on-screen
  /// keyboard. Global coordinates.
  Rect? _visibleRect(RenderTerminal render) {
    final origin = render.localToGlobal(Offset.zero);
    final box = origin & render.size;
    final view = View.maybeOf(context);
    if (view == null) return box;
    final media = MediaQueryData.fromView(view);
    final screen = EdgeInsets.fromLTRB(
      media.padding.left,
      media.padding.top,
      media.padding.right,
      math.max(media.padding.bottom, media.viewInsets.bottom),
    ).deflateRect(Offset.zero & media.size);
    final visible = box.intersect(screen);
    if (visible.isEmpty || visible.width <= 0 || visible.height <= 0) {
      return null;
    }
    return visible;
  }

  Offset _overlayOrigin() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final box = overlay?.context.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.localToGlobal(Offset.zero);
    return Offset.zero;
  }

  TextSelectionToolbarAnchors? _toolbarAnchors(RenderTerminal render) {
    final visible = _visibleRect(render);
    if (visible == null) return null;
    final origin = render.localToGlobal(Offset.zero);
    if (_toolbarForSelection) {
      final selection = widget.controller.selection?.normalized;
      if (selection == null) return null;
      final top = render.rowRect(selection.begin.y).shift(origin);
      final bottom = render.rowRect(selection.end.y).shift(origin);
      if (bottom.bottom <= visible.top || top.top >= visible.bottom) {
        // Scrolled out of view: hide until it is scrolled back.
        return null;
      }
      double x;
      if (selection.begin.y == selection.end.y) {
        x = origin.dx +
            (render.cellRect(selection.begin).left +
                    render.cellRect(selection.end).left) /
                2;
      } else {
        x = visible.center.dx;
      }
      x = x.clamp(visible.left, visible.right);
      return TextSelectionToolbarAnchors(
        primaryAnchor: Offset(x, math.max(top.top, visible.top)),
        secondaryAnchor: Offset(x, math.min(bottom.bottom, visible.bottom)),
      );
    }
    final cell = _pasteCell;
    if (cell == null) return null;
    final rect = render.cellRect(cell).shift(origin);
    if (rect.bottom <= visible.top || rect.top >= visible.bottom) return null;
    final x = rect.center.dx.clamp(visible.left, visible.right);
    return TextSelectionToolbarAnchors(
      primaryAnchor: Offset(x, math.max(rect.top, visible.top)),
      secondaryAnchor: Offset(x, math.min(rect.bottom, visible.bottom)),
    );
  }

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: this,
      onTapOutside: _onTapOutside,
      child: OverlayPortal(
        controller: _portal,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: _buildOverlay,
        child: widget.child,
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final render = _render();
    if (render == null) return const SizedBox.shrink();
    switch (_phase) {
      case _TouchSelectionPhase.idle:
        return const SizedBox.shrink();
      case _TouchSelectionPhase.dragging:
        return _buildPreview(context, render) ?? const SizedBox.shrink();
      case _TouchSelectionPhase.toolbar:
        return _buildToolbar(context, render) ?? const SizedBox.shrink();
    }
  }

  Widget? _buildToolbar(BuildContext context, RenderTerminal render) {
    final items = <ContextMenuButtonItem>[
      if (_toolbarForSelection && widget.controller.selection != null)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: _copy,
        ),
      if (!widget.readOnly)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: _paste,
        ),
    ];
    if (items.isEmpty) return null;
    final anchors = _toolbarAnchors(render);
    if (anchors == null) return null;
    return TapRegion(
      groupId: this,
      child: AdaptiveTextSelectionToolbar.buttonItems(
        key: const ValueKey('terminal-touch-selection-toolbar'),
        anchors: anchors,
        buttonItems: items,
      ),
    );
  }

  Widget? _buildPreview(BuildContext context, RenderTerminal render) {
    final drag = _dragGlobal;
    if (drag == null) return null;
    final visible = _visibleRect(render);
    if (visible == null) return null;
    final origin = render.localToGlobal(Offset.zero);
    final cell = render.getCellOffset(render.globalToLocal(drag));
    final selection = widget.controller.selection;
    final description = TerminalSelectionContext.describe(
      widget.terminal.buffer,
      selection ?? BufferRangeLine.collapsed(cell),
    );
    if (description == null) return null;
    final row = render.rowRect(cell.y).shift(origin);
    final overlayOrigin = _overlayOrigin();

    // Keep clear of the platform magnifier, which floats just above the
    // dragged row, and of the finger below it.
    final aboveGap = _magnifierShown
        ? math.max(
            8.0,
            Magnifier.kDefaultMagnifierSize.height +
                Magnifier.kStandardVerticalFocalPointShift +
                8 -
                row.height / 2,
          )
        : 24.0;

    return IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _PreviewLayoutDelegate(
          row: row.shift(-overlayOrigin),
          visible: visible.shift(-overlayOrigin),
          focusX: drag.dx - overlayOrigin.dx,
          aboveGap: aboveGap,
          belowGap: 40,
        ),
        child: _SelectionPreview(
          key: const ValueKey('terminal-touch-selection-preview'),
          description: description,
          textStyle: widget.textStyle,
        ),
      ),
    );
  }
}

class _PreviewLayoutDelegate extends SingleChildLayoutDelegate {
  _PreviewLayoutDelegate({
    required this.row,
    required this.visible,
    required this.focusX,
    required this.aboveGap,
    required this.belowGap,
  });

  static const _margin = 6.0;

  static const _maxWidth = 420.0;

  final Rect row;

  final Rect visible;

  final double focusX;

  final double aboveGap;

  final double belowGap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.max(
      0.0,
      math.min(visible.width - _margin * 2, _maxWidth),
    );
    final height = math.max(0.0, visible.height - _margin * 2);
    return BoxConstraints(maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = visible.left + _margin;
    final maxX = math.max(minX, visible.right - _margin - childSize.width);
    final x = (focusX - childSize.width / 2).clamp(minX, maxX);

    final minY = visible.top + _margin;
    final maxY = math.max(minY, visible.bottom - _margin - childSize.height);
    var y = row.top - aboveGap - childSize.height;
    if (y < minY) {
      // No room above the magnifier: drop below the finger instead.
      y = row.bottom + belowGap;
    }
    return Offset(x, y.clamp(minY, maxY));
  }

  @override
  bool shouldRelayout(_PreviewLayoutDelegate oldDelegate) {
    return row != oldDelegate.row ||
        visible != oldDelegate.visible ||
        focusX != oldDelegate.focusX ||
        aboveGap != oldDelegate.aboveGap ||
        belowGap != oldDelegate.belowGap;
  }
}

class _SelectionPreview extends StatelessWidget {
  const _SelectionPreview({
    super.key,
    required this.description,
    required this.textStyle,
  });

  final TerminalSelectionContext description;

  final TerminalStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context).clamp(
      minScaleFactor: 1,
      maxScaleFactor: 2,
    );
    const ellipsis = TerminalSelectionContext.ellipsis;
    final selected = TerminalSelectionContext.displayText(
      description.selected,
    );
    return Semantics(
      container: true,
      label: description.plainText,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${description.truncatedBefore ? ellipsis : ''}'
                        '${description.before}',
                  ),
                  if (selected.isEmpty)
                    TextSpan(
                      text: '│',
                      style: TextStyle(color: scheme.primary),
                    )
                  else
                    TextSpan(
                      text: selected,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        backgroundColor: scheme.primaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  TextSpan(
                    text: '${description.after}'
                        '${description.truncatedAfter ? ellipsis : ''}',
                  ),
                ],
              ),
              key: const ValueKey('terminal-touch-selection-preview-text'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              softWrap: true,
              textScaler: textScaler,
              style: TextStyle(
                color: scheme.onSurface,
                fontFamily: textStyle.fontFamily,
                fontFamilyFallback: textStyle.fontFamilyFallback,
                fontSize: 13,
                height: 1.25,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
