/// Own-window placement intent. Normal bounds survive maximization; minimized
/// state, native handles, process IDs and display/session content are excluded.
class SavedWindowPlacement {
  SavedWindowPlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.maximized = false,
  }) {
    if (x < -32766 ||
        x > 32766 ||
        y < -32766 ||
        y > 32766 ||
        width < 200 ||
        width > 32766 ||
        height < 150 ||
        height > 32766) {
      throw const FormatException('Saved window bounds are out of range.');
    }
  }
  final int x, y, width, height;
  final bool maximized;
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'maximized': maximized,
  };
  factory SavedWindowPlacement.fromJson(Map<String, Object?> value) {
    if (value.length != 5 ||
        !value.keys.toSet().containsAll({
          'x',
          'y',
          'width',
          'height',
          'maximized',
        }) ||
        value['x'] is! int ||
        value['y'] is! int ||
        value['width'] is! int ||
        value['height'] is! int ||
        value['maximized'] is! bool) {
      throw const FormatException('Saved window placement is invalid.');
    }
    return SavedWindowPlacement(
      x: value['x'] as int,
      y: value['y'] as int,
      width: value['width'] as int,
      height: value['height'] as int,
      maximized: value['maximized'] as bool,
    );
  }
}
