import 'dart:io';

bool get needsSshBackgroundKeepalive => Platform.isAndroid;
