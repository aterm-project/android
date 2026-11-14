/// Native key codes reported by the "atermius/keyboard_capture" channel,
/// mapped to the X11 keysyms shared by the RDP engine and VNC.
///
/// Non-character keys are looked up first; printable keys then use the
/// unmodified base character of the current local layout ("char"), and only
/// fall back to the US layout below when the runner reported no character.
library;

const _shiftL = 0xffe1, _shiftR = 0xffe2;
const _controlL = 0xffe3, _controlR = 0xffe4;
const _altL = 0xffe9, _altR = 0xffea;
const _superL = 0xffeb, _superR = 0xffec;
const _backspace = 0xff08, _tab = 0xff09, _clear = 0xff0b, _enter = 0xff0d;
const _pause = 0xff13, _scrollLock = 0xff14, _escape = 0xff1b;
const _home = 0xff50, _left = 0xff51, _up = 0xff52, _right = 0xff53;
const _down = 0xff54, _pageUp = 0xff55, _pageDown = 0xff56, _end = 0xff57;
const _print = 0xff61, _insert = 0xff63, _menu = 0xff67, _help = 0xff6a;
const _numLock = 0xff7f, _capsLock = 0xffe5, _delete = 0xffff;
const _kpEnter = 0xff8d, _kpMultiply = 0xffaa, _kpAdd = 0xffab;
const _kpSeparator = 0xffac, _kpSubtract = 0xffad, _kpDecimal = 0xffae;
const _kpDivide = 0xffaf, _kp0 = 0xffb0, _kpEqual = 0xffbd;
const _f1 = 0xffbe;
const _kanji = 0xff21, _muhenkan = 0xff22, _henkan = 0xff23;
const _hiraganaKatakana = 0xff27, _zenkakuHankaku = 0xff2a;
const _eisuToggle = 0xff30, _hangul = 0xff31, _hangulHanja = 0xff34;
const _space = 0x20;

/// XF86 vendor keysyms (XF86keysym.h) for media, browser and launch keys.
const _xf86AudioLowerVolume = 0x1008ff11, _xf86AudioMute = 0x1008ff12;
const _xf86AudioRaiseVolume = 0x1008ff13, _xf86AudioPlay = 0x1008ff14;
const _xf86AudioStop = 0x1008ff15, _xf86AudioPrev = 0x1008ff16;
const _xf86AudioNext = 0x1008ff17, _xf86HomePage = 0x1008ff18;
const _xf86Mail = 0x1008ff19, _xf86Search = 0x1008ff1b;
const _xf86Calculator = 0x1008ff1d, _xf86Back = 0x1008ff26;
const _xf86Forward = 0x1008ff27, _xf86Stop = 0x1008ff28;
const _xf86Refresh = 0x1008ff29, _xf86Sleep = 0x1008ff2f;
const _xf86Favorites = 0x1008ff30, _xf86AudioMedia = 0x1008ff32;
const _xf86MyComputer = 0x1008ff33;

/// Windows virtual-key codes (VK_*). Low-level hooks report left/right
/// specific modifiers; the generic ones are resolved with [extended]/scan.
const _windowsSpecial = <int, int>{
  0x03: _pause, // VK_CANCEL (Ctrl+Pause): the remote sees Ctrl+Pause
  0x08: _backspace,
  0x09: _tab,
  0x0c: _clear,
  0x13: _pause,
  0x14: _capsLock,
  0x1b: _escape,
  0x1c: _henkan, // VK_CONVERT
  0x1d: _muhenkan, // VK_NONCONVERT
  0x20: _space,
  0x21: _pageUp,
  0x22: _pageDown,
  0x23: _end,
  0x24: _home,
  0x25: _left,
  0x26: _up,
  0x27: _right,
  0x28: _down,
  0x2c: _print, // VK_SNAPSHOT
  0x2d: _insert,
  0x2e: _delete,
  0x2f: _help,
  0x5b: _superL,
  0x5c: _superR,
  0x5d: _menu, // VK_APPS
  0x5f: _xf86Sleep, // VK_SLEEP
  0x6a: _kpMultiply,
  0x6b: _kpAdd,
  0x6c: _kpSeparator,
  0x6d: _kpSubtract,
  0x6e: _kpDecimal,
  0x6f: _kpDivide,
  0x90: _numLock,
  0x91: _scrollLock,
  0xa0: _shiftL,
  0xa1: _shiftR,
  0xa2: _controlL,
  0xa3: _controlR,
  0xa4: _altL,
  0xa5: _altR,
  0xa6: _xf86Back, // VK_BROWSER_BACK
  0xa7: _xf86Forward,
  0xa8: _xf86Refresh,
  0xa9: _xf86Stop,
  0xaa: _xf86Search,
  0xab: _xf86Favorites,
  0xac: _xf86HomePage, // VK_BROWSER_HOME
  0xad: _xf86AudioMute, // VK_VOLUME_MUTE
  0xae: _xf86AudioLowerVolume,
  0xaf: _xf86AudioRaiseVolume,
  0xb0: _xf86AudioNext, // VK_MEDIA_NEXT_TRACK
  0xb1: _xf86AudioPrev,
  0xb2: _xf86AudioStop,
  0xb3: _xf86AudioPlay, // VK_MEDIA_PLAY_PAUSE
  0xb4: _xf86Mail, // VK_LAUNCH_MAIL
  0xb5: _xf86AudioMedia, // VK_LAUNCH_MEDIA_SELECT
  0xb6: _xf86MyComputer, // VK_LAUNCH_APP1
  0xb7: _xf86Calculator, // VK_LAUNCH_APP2
  // Japanese 106/109 keyboard: 英数 (Caps Lock position) and the
  // カタカナ/ひらがな key (Shift and Alt variants of the same key).
  0xf0: _eisuToggle, // VK_DBE_ALPHANUMERIC
  0xf1: _hiraganaKatakana, // VK_DBE_KATAKANA
  0xf2: _hiraganaKatakana, // VK_DBE_HIRAGANA
  0xf3: _zenkakuHankaku, // VK_OEM_AUTO
  0xf4: _zenkakuHankaku, // VK_OEM_ENLW
};

/// US-layout VK_OEM_* characters, used only without a reported character.
const _windowsPrintable = <int, int>{
  0xba: 0x3b, // ;
  0xbb: 0x3d, // =
  0xbc: 0x2c, // ,
  0xbd: 0x2d, // -
  0xbe: 0x2e, // .
  0xbf: 0x2f, // /
  0xc0: 0x60, // `
  0xdb: 0x5b, // [
  0xdc: 0x5c, // backslash
  0xdd: 0x5d, // ]
  0xde: 0x27, // '
  0xe2: 0x3c, // < (ISO key)
};

int? _windowsKeysym(int code, bool extended, int scan) {
  switch (code) {
    case 0x0d: // VK_RETURN: the numeric keypad Enter is extended.
      return extended ? _kpEnter : _enter;
    case 0x10: // VK_SHIFT
      return scan == 0x36 ? _shiftR : _shiftL;
    case 0x11: // VK_CONTROL
      return extended ? _controlR : _controlL;
    case 0x12: // VK_MENU
      return extended ? _altR : _altL;
    case 0x15: // VK_HANGUL (Korean Han/Yeong); VK_KANA on the Japanese key
      return scan == 0x70 ? _hiraganaKatakana : _hangul;
    case 0x19: // VK_HANJA (Korean); VK_KANJI from the 半角/全角 key
      return scan == 0x29 ? _kanji : _hangulHanja;
  }
  if (code >= 0x60 && code <= 0x69) return _kp0 + code - 0x60; // VK_NUMPAD0-9
  if (code >= 0x70 && code <= 0x87) return _f1 + code - 0x70; // VK_F1-F24
  return _windowsSpecial[code];
}

int? _windowsFallback(int code) {
  if (code >= 0x30 && code <= 0x39) return code; // 0-9
  if (code >= 0x41 && code <= 0x5a) return code + 0x20; // a-z
  return _windowsPrintable[code];
}

/// macOS virtual key codes (kVK_* from HIToolbox/Events.h).
const _macSpecial = <int, int>{
  0x24: _enter, // kVK_Return
  0x30: _tab,
  0x31: _space,
  0x33: _backspace, // kVK_Delete
  0x35: _escape,
  0x36: _superR, // kVK_RightCommand
  0x37: _superL, // kVK_Command
  0x38: _shiftL,
  0x39: _capsLock,
  0x3a: _altL, // kVK_Option
  0x3b: _controlL,
  0x3c: _shiftR,
  0x3d: _altR,
  0x3e: _controlR,
  0x40: _f1 + 16, // F17
  0x41: _kpDecimal,
  0x43: _kpMultiply,
  0x45: _kpAdd,
  0x47: _numLock, // kVK_ANSI_KeypadClear
  0x4b: _kpDivide,
  0x4c: _kpEnter,
  0x4e: _kpSubtract,
  0x4f: _f1 + 17, // F18
  0x50: _f1 + 18, // F19
  0x51: _kpEqual,
  0x52: _kp0,
  0x53: _kp0 + 1,
  0x54: _kp0 + 2,
  0x55: _kp0 + 3,
  0x56: _kp0 + 4,
  0x57: _kp0 + 5,
  0x58: _kp0 + 6,
  0x59: _kp0 + 7,
  0x5a: _f1 + 19, // F20
  0x5b: _kp0 + 8,
  0x5c: _kp0 + 9,
  0x5f: _kpSeparator, // kVK_JIS_KeypadComma
  0x60: _f1 + 4, // F5
  0x61: _f1 + 5, // F6
  0x62: _f1 + 6, // F7
  0x63: _f1 + 2, // F3
  0x64: _f1 + 7, // F8
  0x65: _f1 + 8, // F9
  0x67: _f1 + 10, // F11
  0x69: _f1 + 12, // F13
  0x6a: _f1 + 15, // F16
  0x6b: _f1 + 13, // F14
  0x6d: _f1 + 9, // F10
  0x6e: _menu, // kVK_ContextualMenu
  0x6f: _f1 + 11, // F12
  0x71: _f1 + 14, // F15
  0x72: _insert, // kVK_Help sits where PC keyboards have Insert
  0x73: _home,
  0x74: _pageUp,
  0x75: _delete, // kVK_ForwardDelete
  0x76: _f1 + 3, // F4
  0x77: _end,
  0x78: _f1 + 1, // F2
  0x79: _pageDown,
  0x7a: _f1, // F1
  0x7b: _left,
  0x7c: _right,
  0x7d: _down,
  0x7e: _up,
};

/// US-layout kVK_ANSI_* characters, used only without a reported character.
const _macPrintable = <int, int>{
  0x00: 0x61, // a
  0x01: 0x73, // s
  0x02: 0x64, // d
  0x03: 0x66, // f
  0x04: 0x68, // h
  0x05: 0x67, // g
  0x06: 0x7a, // z
  0x07: 0x78, // x
  0x08: 0x63, // c
  0x09: 0x76, // v
  0x0a: 0xa7, // § (kVK_ISO_Section)
  0x0b: 0x62, // b
  0x0c: 0x71, // q
  0x0d: 0x77, // w
  0x0e: 0x65, // e
  0x0f: 0x72, // r
  0x10: 0x79, // y
  0x11: 0x74, // t
  0x12: 0x31, // 1
  0x13: 0x32, // 2
  0x14: 0x33, // 3
  0x15: 0x34, // 4
  0x16: 0x36, // 6
  0x17: 0x35, // 5
  0x18: 0x3d, // =
  0x19: 0x39, // 9
  0x1a: 0x37, // 7
  0x1b: 0x2d, // -
  0x1c: 0x38, // 8
  0x1d: 0x30, // 0
  0x1e: 0x5d, // ]
  0x1f: 0x6f, // o
  0x20: 0x75, // u
  0x21: 0x5b, // [
  0x22: 0x69, // i
  0x23: 0x70, // p
  0x25: 0x6c, // l
  0x26: 0x6a, // j
  0x27: 0x27, // '
  0x28: 0x6b, // k
  0x29: 0x3b, // ;
  0x2a: 0x5c, // backslash
  0x2b: 0x2c, // ,
  0x2c: 0x2f, // /
  0x2d: 0x6e, // n
  0x2e: 0x6d, // m
  0x2f: 0x2e, // .
  0x32: 0x60, // `
};

/// iOS UIKeyboardHIDUsage (USB HID keyboard usage page 0x07).
const _iosSpecial = <int, int>{
  0x28: _enter,
  0x29: _escape,
  0x2a: _backspace,
  0x2b: _tab,
  0x2c: _space,
  0x39: _capsLock,
  0x46: _print,
  0x47: _scrollLock,
  0x48: _pause,
  0x49: _insert,
  0x4a: _home,
  0x4b: _pageUp,
  0x4c: _delete,
  0x4d: _end,
  0x4e: _pageDown,
  0x4f: _right,
  0x50: _left,
  0x51: _down,
  0x52: _up,
  0x53: _numLock,
  0x54: _kpDivide,
  0x55: _kpMultiply,
  0x56: _kpSubtract,
  0x57: _kpAdd,
  0x58: _kpEnter,
  0x62: _kp0,
  0x63: _kpDecimal,
  0x65: _menu, // keyboardApplication
  0x67: _kpEqual,
  0x75: _help,
  0x76: _menu,
  0x85: _kpSeparator, // keypadComma
  0x8a: _henkan, // keyboardInternational4
  0x8b: _muhenkan, // keyboardInternational5
  0xe0: _controlL,
  0xe1: _shiftL,
  0xe2: _altL,
  0xe3: _superL,
  0xe4: _controlR,
  0xe5: _shiftR,
  0xe6: _altR,
  0xe7: _superR,
};

/// US-layout HID characters, used only without a reported character.
const _iosPrintable = <int, int>{
  0x2d: 0x2d, // -
  0x2e: 0x3d, // =
  0x2f: 0x5b, // [
  0x30: 0x5d, // ]
  0x31: 0x5c, // backslash
  0x32: 0x23, // # (non-US)
  0x33: 0x3b, // ;
  0x34: 0x27, // '
  0x35: 0x60, // `
  0x36: 0x2c, // ,
  0x37: 0x2e, // .
  0x38: 0x2f, // /
  0x64: 0x3c, // < (non-US backslash)
};

int? _iosKeysym(int code) {
  if (code >= 0x3a && code <= 0x45) return _f1 + code - 0x3a; // F1-F12
  if (code >= 0x68 && code <= 0x73) return _f1 + 12 + code - 0x68; // F13-F24
  if (code >= 0x59 && code <= 0x61) return _kp0 + 1 + code - 0x59; // KP 1-9
  return _iosSpecial[code];
}

int? _iosFallback(int code) {
  if (code >= 0x04 && code <= 0x1d) return 0x61 + code - 0x04; // a-z
  if (code >= 0x1e && code <= 0x26) return 0x31 + code - 0x1e; // 1-9
  if (code == 0x27) return 0x30; // 0
  return _iosPrintable[code];
}

/// Android KeyEvent.KEYCODE_* values.
const _androidSpecial = <int, int>{
  19: _up, // DPAD_UP
  20: _down,
  21: _left,
  22: _right,
  57: _altL,
  58: _altR,
  59: _shiftL,
  60: _shiftR,
  61: _tab,
  62: _space,
  66: _enter,
  67: _backspace, // KEYCODE_DEL
  82: _menu,
  92: _pageUp,
  93: _pageDown,
  111: _escape,
  112: _delete, // KEYCODE_FORWARD_DEL
  113: _controlL,
  114: _controlR,
  115: _capsLock,
  116: _scrollLock,
  117: _superL, // META_LEFT
  118: _superR,
  120: _print, // SYSRQ
  121: _pause, // BREAK
  122: _home, // MOVE_HOME
  123: _end, // MOVE_END
  124: _insert,
  143: _numLock,
  154: _kpDivide,
  155: _kpMultiply,
  156: _kpSubtract,
  157: _kpAdd,
  158: _kpDecimal,
  159: _kpSeparator,
  160: _kpEnter,
  161: _kpEqual,
  211: _zenkakuHankaku,
  213: _muhenkan,
  214: _henkan,
};

/// US-layout Android characters, used only without a reported character.
const _androidPrintable = <int, int>{
  17: 0x2a, // *
  18: 0x23, // #
  55: 0x2c, // ,
  56: 0x2e, // .
  68: 0x60, // `
  69: 0x2d, // -
  70: 0x3d, // =
  71: 0x5b, // [
  72: 0x5d, // ]
  73: 0x5c, // backslash
  74: 0x3b, // ;
  75: 0x27, // '
  76: 0x2f, // /
  77: 0x40, // @
  81: 0x2b, // +
};

int? _androidKeysym(int code) {
  if (code >= 131 && code <= 142) return _f1 + code - 131; // F1-F12
  if (code >= 144 && code <= 153) return _kp0 + code - 144; // NUMPAD_0-9
  return _androidSpecial[code];
}

int? _androidFallback(int code) {
  if (code >= 7 && code <= 16) return 0x30 + code - 7; // 0-9
  if (code >= 29 && code <= 54) return 0x61 + code - 29; // a-z
  return _androidPrintable[code];
}

/// The X11 keysym for a key swallowed by the native runner, or null when the
/// key has no remote equivalent (it is then dropped).
int? keyboardCaptureKeysym({
  required String platform,
  required int code,
  String char = '',
  bool extended = false,
  int scan = 0,
}) {
  final int? special;
  final int? Function(int) fallback;
  switch (platform) {
    case 'windows':
      special = _windowsKeysym(code, extended, scan);
      fallback = _windowsFallback;
    case 'macos':
      special = _macSpecial[code];
      fallback = (code) => _macPrintable[code];
    case 'ios':
      special = _iosKeysym(code);
      fallback = _iosFallback;
    case 'android':
      special = _androidKeysym(code);
      fallback = _androidFallback;
    default:
      return null;
  }
  if (special != null) return special;
  final character = _characterKeysym(char);
  return character ?? fallback(code);
}

/// Same character rule as desktopKeysym(): Latin-1 maps directly, any other
/// code point uses the Unicode keysym range.
int? _characterKeysym(String char) {
  if (char.runes.length != 1) return null;
  final lower = char.toLowerCase();
  final rune = (lower.runes.length == 1 ? lower : char).runes.first;
  if (rune < 32 || rune == 0x7f) return null;
  // Function-key/private-use code points (for example macOS arrow keys) are
  // never typed characters.
  if (rune >= 0xe000 && rune <= 0xf8ff) return null;
  return rune <= 255 ? rune : 0x01000000 | rune;
}
