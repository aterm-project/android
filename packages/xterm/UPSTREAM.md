# xterm.dart upstream and local patch

- Upstream: [TerminalStudio/xterm.dart](https://github.com/TerminalStudio/xterm.dart)
- Base release: `xterm` 4.0.0 from the pub.dev hosted package
- Upstream license: MIT; the original `LICENSE` is retained in this directory
- Vendored scope: upstream `lib/` plus package metadata and README
- Local change: `lib/src/terminal_view.dart` maps both `TextInputAction.newline`
  and `TextInputAction.done` to one `TerminalKey.enter` event. Flutter Web
  reports a physical Enter through the TextInput client as `newline`; upstream
  4.0.0 only handled `done`, so the browser terminal silently dropped Enter.
- Local change: `lib/src/core/escape/parser.dart` incrementally consumes OSC
  frames across writes, retains at most 64 Ki Unicode code points and 256
  semicolon-delimited fields, and discards oversized frames through BEL/ST
  before resuming. This bounds cumulative unterminated OSC parser state; one
  oversized `Terminal.write()` call is still copied into the input rune queue
  before parsing. OSC 0/1/2 and unknown-OSC callback routing remain covered by
  `apps/client/test/xterm_osc_parser_test.dart`.
- Lifecycle boundary: the parser has no public reset for an in-progress OSC.
  If a consumer reuses the same `Terminal` across transport/session boundaries
  while an oversized OSC is pending, it will keep discarding input until BEL/ST.
  Atermius closes and replaces the terminal when starting a new connection; a
  generic xterm consumer should likewise dispose/recreate it at that boundary.
  Incomplete CSI accumulation and one-shot large-write input allocation are
  outside this patch.
- Local input fixes: cursor keys follow DECCKM independently of application
  keypad mode; Alt letters retain lowercase (Shift+Alt emits uppercase), and
  non-Apple clipboard/select-all shortcuts use Ctrl+Shift so Ctrl+A and Ctrl+V
  reach the remote terminal. Apple Command shortcuts remain unchanged. Covered
  by `apps/client/test/terminal_key_mapping_test.dart`.

When updating xterm, compare this fork with the selected upstream release, keep
these behaviors covered by `apps/client/test/terminal_input_focus_test.dart` and
`apps/client/test/xterm_osc_parser_test.dart`, and record any additional local
changes here. The application selects this package through the path override in
`apps/client/pubspec.yaml`.

- Native text input configuration includes the hosting Flutter view ID. This fixes
  Windows `TextInput.setClient` rejection (`view ID is null`) on multi-view engines;
  widget focus alone could previously appear active while native text input failed.
- Native layout memory: the glyph LRU is capped at 2,048 entries; replacement,
  eviction and clear explicitly dispose Paragraphs. RenderTerminal clears layouts
  on detach/dispose and disposes temporary IME paragraphs after drawing. Session
  scrollback remains intact when a view is unmounted. Covered by
  `apps/client/test/terminal_memory_test.dart`; the opt-in
  `terminal_memory_benchmark_test.dart` records native process RSS under glyph
  cache pressure. See `docs/MEMORY-PERFORMANCE.md` in the repository root.
