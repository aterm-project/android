/// Capabilities compiled into the loaded RDP engine, as reported by the
/// native `aterm_rdp_features` export. A switch whose backend is absent is
/// shown as unavailable, never as a working feature.
class RdpFeatures {
  const RdpFeatures(this.bits);
  static const none = RdpFeatures(0);
  static const configV1 = 1 << 0;
  static const drive = 1 << 1;
  static const printer = 1 << 2;
  static const smartcard = 1 << 3;
  static const audioOut = 1 << 4;
  static const audioIn = 1 << 5;
  static const multimon = 1 << 6;
  static const fileClipboard = 1 << 7;
  static const camera = 1 << 8;
  static const usb = 1 << 9;
  static const nativeTouch = 1 << 10;

  final int bits;
  bool has(int flag) => bits & configV1 != 0 && bits & flag == flag;

  @override
  bool operator ==(Object other) => other is RdpFeatures && other.bits == bits;
  @override
  int get hashCode => bits.hashCode;
}
