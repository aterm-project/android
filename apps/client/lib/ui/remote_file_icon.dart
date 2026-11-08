import 'package:flutter/material.dart';

/// Local vector glyphs; names from a server never become asset paths or URLs.
IconData remoteFileIcon(
  String name, {
  bool directory = false,
  bool link = false,
}) {
  if (directory) return Icons.folder_rounded;
  if (link) return Icons.link_rounded;
  final lower = name.toLowerCase();
  final extension = lower.contains('.') ? lower.split('.').last : '';
  if (const {'dockerfile', 'makefile', 'cmakelists.txt'}.contains(lower)) {
    return Icons.code_rounded;
  }
  if (lower == '.env' || lower.startsWith('.env.')) return Icons.tune_rounded;
  return switch (extension) {
    'dart' ||
    'py' ||
    'js' ||
    'ts' ||
    'tsx' ||
    'jsx' ||
    'rs' ||
    'go' ||
    'java' ||
    'kt' ||
    'swift' ||
    'c' ||
    'cpp' ||
    'h' ||
    'hpp' ||
    'cs' ||
    'php' ||
    'rb' ||
    'html' ||
    'css' ||
    'scss' ||
    'vue' => Icons.code_rounded,
    'sh' ||
    'bash' ||
    'zsh' ||
    'fish' ||
    'ps1' ||
    'bat' ||
    'cmd' => Icons.terminal_rounded,
    'json' ||
    'yaml' ||
    'yml' ||
    'toml' ||
    'ini' ||
    'conf' ||
    'cfg' ||
    'xml' ||
    'properties' => Icons.tune_rounded,
    'zip' ||
    'gz' ||
    'bz2' ||
    'xz' ||
    '7z' ||
    'rar' ||
    'tar' ||
    'tgz' ||
    'zst' => Icons.archive_rounded,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'svg' ||
    'bmp' ||
    'ico' ||
    'avif' ||
    'heic' => Icons.image_outlined,
    'mp4' || 'mkv' || 'mov' || 'webm' || 'avi' => Icons.movie_outlined,
    'mp3' ||
    'wav' ||
    'flac' ||
    'aac' ||
    'ogg' ||
    'm4a' => Icons.audio_file_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'csv' || 'xls' || 'xlsx' || 'ods' => Icons.table_chart_outlined,
    'db' || 'sqlite' || 'sqlite3' || 'sql' => Icons.storage_rounded,
    'pem' || 'key' || 'crt' || 'cer' || 'p12' || 'pfx' => Icons.key_rounded,
    'exe' ||
    'msi' ||
    'apk' ||
    'deb' ||
    'rpm' ||
    'dmg' => Icons.inventory_2_outlined,
    'txt' ||
    'md' ||
    'rst' ||
    'log' ||
    'doc' ||
    'docx' ||
    'rtf' => Icons.description_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
