enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  // Wheel buttons 4..7 are reported as 64 + (button - 4). Adding 4 instead
  // would set the Shift modifier bit (Cb + 4), so applications such as tmux
  // and vim would see Shift+wheel.
  wheelUp(id: 64 + 0, isWheel: true),

  wheelDown(id: 64 + 1, isWheel: true),

  wheelLeft(id: 64 + 2, isWheel: true),

  wheelRight(id: 64 + 3, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Mouse wheel up / down use button IDs 4 = 0100 (binary) and 5 = 0101 (binary).
  /// The bits three and four of the button are transposed by 64 and 128
  /// respectively, when reporting the id of the button and have have to be
  /// adjusted correspondingly.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
