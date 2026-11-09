# desktop_drop upstream and local patch

- Upstream: [MixinNetwork/flutter-plugins `packages/desktop_drop`](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop)
- Base release: `desktop_drop` 0.8.4 from pub.dev
  (archive sha256 `47ded09c85909edfed644fd4cbb5051b040d0aed5c79e7e062ea4b3b7156dbe4`,
  https://pub.dev/api/archives/desktop_drop-0.8.4.tar.gz, root-verified, see
  `DROP_DEPENDENCIES.json` in the files report)
- Upstream license: Apache-2.0; the original `LICENSE` is retained in this directory
- Vendored scope: `lib/`, `android/`, `linux/`, `macos/`, `windows/`,
  `pubspec.yaml`, README, CHANGELOG, LICENSE (example and test aren't vendored)
- Native code (`android/`, `linux/`, `macos/`, `windows/`) is verbatim upstream.

## Local changes (Dart only)
Purpose: a browser drop must not enumerate dropped folders or create object
URLs for an unbounded number of items before the app can reject the drop.
Upstream `desktop_drop_web.dart` recursively read every dropped folder
(`_readAllEntries` + recursive `Future.wait`) and created an object URL for
every descendant before Dart saw the event.

- `pubspec.yaml`: removed `resolution: workspace` (upstream monorepo
  setting; it isn't valid for a path dependency outside that workspace).
- `lib/src/drop_limits.dart` (new, no imports): `DesktopDropWebLimits.maxItems`
  (default `null` = unlimited) and `expandDirectories` (default `true`).
  Defaults keep upstream behaviour; it is exported from `desktop_drop.dart`.
- `lib/src/web_drop_collector.dart` (new, DOM-free) + `lib/web_drop_collector.dart`
  (public export): `collectWebDrop` rejects a drop with more than `maxItems`
  top-level items before reading any entry. When `expandDirectories` is false
  it returns folders as childless `directory` items with no object URL and
  never calls their reader. It skips and counts non-file items and null
  `webkitGetAsEntry()` results (upstream threw on `!`). On any failure it
  revokes every object URL already created.
- `lib/desktop_drop_web.dart`: `ondrop` checks `dataTransfer.items.length`
  against `maxItems` before building item adapters. It adapts DOM objects to
  the collector and sends `performOperation_web_bounded` (`items`, `skipped`)
  or `performOperation_web_rejected` (`reason`, `count`).
- `lib/src/events.dart`: `DropDoneEvent.skippedItems` (default 0), new
  `DropRejectedReason` and `DropRejectedEvent`.
- `lib/src/channel.dart`: handles the two new web methods. All existing
  methods are unchanged.
- `lib/src/drop_target.dart`: `DropDoneDetails.skippedItems` (default 0),
  new `DropRejectedDetails` and optional `DropTarget.onDragRejected`.

Every new parameter is optional with an upstream-equivalent default, so
existing `DropTarget`/`DesktopDrop` callers compile and behave as before on
native platforms. The app (`apps/client/lib/platform/file_drop_region.dart`)
sets `maxItems = 64` and `expandDirectories = false`. Coverage:
`apps/client/test/web_drop_collector_test.dart`.
