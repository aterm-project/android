/// Atermius local change: opt-in bounds for browser drops.
///
/// The defaults keep upstream desktop_drop 0.8.4 behaviour (no item limit,
/// dropped folders are recursively expanded). An app that only accepts a
/// bounded number of top-level files can tighten them before a drop, e.g.
/// `DesktopDropWebLimits.maxItems = 64; DesktopDropWebLimits.expandDirectories
/// = false;`. Native (Windows/Linux/macOS/Android) drops are not affected.
/// This file has no imports so it can be used on every platform.
abstract final class DesktopDropWebLimits {
  /// Maximum top-level items in one browser drop, or `null` for no limit.
  /// A larger drop is reported as a rejected drop before any entry is read
  /// or any object URL is created.
  static int? maxItems;

  /// Whether dropped browser folders are traversed. When `false`, a folder
  /// is reported as a `DropItemDirectory` with no children and no object URL,
  /// and its directory reader is never used.
  static bool expandDirectories = true;
}
