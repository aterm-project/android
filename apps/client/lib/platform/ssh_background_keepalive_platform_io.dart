import 'dart:io';

bool get needsSshBackgroundKeepalive => Platform.isAndroid || Platform.isIOS;
