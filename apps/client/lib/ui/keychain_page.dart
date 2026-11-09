import 'app_menu.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../ssh/openssh_certificate.dart';
import 'app_theme.dart';

/// Upper bound for an imported private key / certificate file.
const int keychainMaxImportBytes = 256 * 1024;

/// Public view of one Keychain credential. Never carries a password, private
/// key or passphrase; only the key fingerprint and the (public) certificate.
@immutable
class KeychainEntry {
  const KeychainEntry({
    required this.id,
    required this.name,
    required this.username,
    required this.kind,
    this.keyFingerprint,
    this.certificate,
    this.usedBy = const [],
  });

  final String id;
  final String name;
  final String username;
  final AuthKind kind;
  final String? keyFingerprint;
  final String? certificate;

  /// Localized "Host “x”" / "Group “y”" labels of records referencing it.
  final List<String> usedBy;
}

enum KeychainFilter { all, passwords, keys, certificates }

/// Certificate facts for display; `null` for absent/unparseable text.
OpenSshCertificate? tryParseCertificate(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    return OpenSshCertificate.parse(text);
  } on OpenSshCertificateException {
    return null;
  }
}

String certificateProblemLabel(
  AppLocalizations l10n,
  OpenSshCertificateProblem problem,
) => switch (problem) {
  OpenSshCertificateProblem.malformed => l10n.r7NavCertMalformed,
  OpenSshCertificateProblem.unsupportedAlgorithm => l10n.r7NavCertUnsupported,
  OpenSshCertificateProblem.notUserCertificate => l10n.r7NavCertNotUser,
  OpenSshCertificateProblem.keyMismatch => l10n.r7NavCertKeyMismatch,
  OpenSshCertificateProblem.privateKeyUnreadable => l10n.r7NavCertKeyUnreadable,
};

final _date = DateFormat('yyyy-MM-dd HH:mm');

/// Short validity text: "Valid until …", "Expired …", "Not valid before …".
String certificateValidityLabel(
  AppLocalizations l10n,
  OpenSshCertificate certificate, [
  DateTime? now,
]) {
  final at = now ?? DateTime.now();
  if (certificate.isExpiredAt(at)) {
    return l10n.r7NavCertExpired(_date.format(certificate.validBefore!.toLocal()));
  }
  if (certificate.isNotYetValidAt(at)) {
    return l10n.r7NavCertNotYetValid(
      _date.format(certificate.validAfter!.toLocal()),
    );
  }
  final before = certificate.validBefore;
  return before == null
      ? l10n.r7NavCertValidForever
      : l10n.r7NavCertValidUntil(_date.format(before.toLocal()));
}

/// Reads a small text file chosen by the user (private key / certificate).
/// Bytes are zeroed after decoding. Returns `null` when cancelled.
Future<String?> pickKeychainTextFile({
  Future<Uint8List?> Function()? pickBytesForTesting,
}) async {
  Uint8List? bytes;
  if (pickBytesForTesting != null) {
    bytes = await pickBytesForTesting();
  } else {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    bytes = file.bytes;
    if (file.size > keychainMaxImportBytes) {
      bytes?.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.r7NavImportFileTooLarge);
    }
  }
  if (bytes == null) return null;
  try {
    if (bytes.length > keychainMaxImportBytes) {
      throw FormatException(currentL10n.r7NavImportFileTooLarge);
    }
    return utf8.decode(bytes);
  } on FormatException catch (error) {
    if (error.message == currentL10n.r7NavImportFileTooLarge) rethrow;
    throw FormatException(currentL10n.r7NavImportFileNotText);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Result of validating the key/certificate fields of a credential editor.
/// [fingerprint] is the SHA256 fingerprint of the private key's public half.
typedef KeychainKeyCheck = ({
  String? error,
  String? fingerprint,
  String? certificate,
});

/// Validates a key credential before saving. A certificate must be an OpenSSH
/// *user* certificate certifying exactly this key; otherwise saving is refused
/// so a non-working certificate login is never stored as usable.
KeychainKeyCheck checkKeychainKey({
  required String privateKey,
  String? passphrase,
  String? certificateText,
}) {
  final l10n = currentL10n;
  final described = describePrivateKey(privateKey, passphrase: passphrase);
  final cert = certificateText?.trim() ?? '';
  if (cert.isEmpty) {
    // Unreadable (for example passphrase-protected without passphrase) keys
    // keep the previous behaviour: saved, verified at connect time.
    return (error: null, fingerprint: described?.fingerprint, certificate: null);
  }
  if (OpenSshCertificate.looksLikeCertificate(privateKey)) {
    return (error: l10n.r7NavCertInKeyField, fingerprint: null, certificate: null);
  }
  try {
    final parsed = validateUserCertificateForPrivateKey(
      certificateText: cert,
      privateKey: privateKey,
      passphrase: passphrase,
    );
    return (
      error: null,
      fingerprint: described?.fingerprint,
      certificate: parsed.canonicalLine,
    );
  } on OpenSshCertificateException catch (error) {
    return (
      error: certificateProblemLabel(l10n, error.problem),
      fingerprint: null,
      certificate: null,
    );
  }
}

/// Certificate input used by both credential editors: paste or import a
/// `*-cert.pub` file, with live structural status (no secret involved).
class KeychainCertificateField extends StatefulWidget {
  const KeychainCertificateField({
    super.key,
    required this.controller,
    this.pickBytesForTesting,
  });

  final TextEditingController controller;
  final Future<Uint8List?> Function()? pickBytesForTesting;

  @override
  State<KeychainCertificateField> createState() =>
      _KeychainCertificateFieldState();
}

class _KeychainCertificateFieldState extends State<KeychainCertificateField> {
  String? _importError;

  Future<void> _import() async {
    try {
      final text = await pickKeychainTextFile(
        pickBytesForTesting: widget.pickBytesForTesting,
      );
      if (text == null || !mounted) return;
      setState(() {
        _importError = null;
        widget.controller.text = text.trim();
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _importError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final text = value.text.trim();
        String? status;
        var bad = false;
        if (text.isNotEmpty) {
          try {
            final cert = OpenSshCertificate.parse(text);
            if (!cert.isUserCertificate) {
              status = l10n.r7NavCertNotUser;
              bad = true;
            } else {
              status = [
                cert.keyType,
                if (cert.keyId.isNotEmpty) 'ID ${cert.keyId}',
                cert.principals.isEmpty
                    ? l10n.r7NavCertAnyPrincipal
                    : l10n.r7NavCertPrincipals(cert.principals.join(', ')),
                certificateValidityLabel(l10n, cert),
              ].join(' · ');
              bad = !cert.isValidAt(DateTime.now());
            }
          } on OpenSshCertificateException catch (error) {
            status = certificateProblemLabel(l10n, error.problem);
            bad = true;
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('keychain_certificate'),
              controller: widget.controller,
              minLines: 1,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.r7NavCertificateOptional,
                helperText: l10n.r7NavCertificateHelper,
                helperMaxLines: 3,
                alignLabelWithHint: true,
                suffixIcon: IconButton(
                  key: const ValueKey('keychain_certificate_import'),
                  tooltip: l10n.r7NavImportCertificateFile,
                  onPressed: _import,
                  icon: const Icon(Icons.upload_file_outlined),
                ),
              ),
            ),
            if (status != null || _importError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _importError ?? status!,
                  key: const ValueKey('keychain_certificate_status'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: _importError != null || bad
                        ? context.palette.orange
                        : context.palette.accentText,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Small "Import key file" button for private key fields.
class KeychainKeyFileButton extends StatelessWidget {
  const KeychainKeyFileButton({
    super.key,
    required this.onLoaded,
    this.onError,
    this.pickBytesForTesting,
  });

  final ValueChanged<String> onLoaded;
  final ValueChanged<String>? onError;
  final Future<Uint8List?> Function()? pickBytesForTesting;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('keychain_private_key_import'),
    onPressed: () async {
      try {
        final text = await pickKeychainTextFile(
          pickBytesForTesting: pickBytesForTesting,
        );
        if (text == null) return;
        if (OpenSshCertificate.looksLikeCertificate(text) ||
            !text.contains('PRIVATE KEY')) {
          onError?.call(currentL10n.r7NavNotAPrivateKey);
          return;
        }
        onLoaded(text);
      } on FormatException catch (error) {
        onError?.call(error.message);
      }
    },
    icon: const Icon(Icons.file_open_outlined, size: 18),
    label: Text(context.l10n.r7NavImportKeyFile),
  );
}

/// Home "Keychain" destination shared by Local and cloud workspaces.
class KeychainPage extends StatefulWidget {
  const KeychainPage({
    super.key,
    required this.entries,
    required this.canWrite,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    this.addButtonKey,
    this.emptyText,
    this.rowKeyPrefix = 'keychain_entry_',
    this.busy = false,
    this.error,
    this.onRetry,
    this.scopeLabel,
    this.footer,
  });

  final List<KeychainEntry> entries;
  final bool canWrite;
  final bool busy;
  final String? error;
  final VoidCallback? onRetry;
  /// Opens the credential editor (kind is chosen inside the editor).
  final VoidCallback onAdd;
  final Key? addButtonKey;
  final String? emptyText;

  /// Row (ListTile) key prefix; the local Profile keeps `local_credential_`.
  final String rowKeyPrefix;
  final ValueChanged<KeychainEntry> onEdit;
  final ValueChanged<KeychainEntry> onDelete;
  final String? scopeLabel;
  final Widget? footer;

  @override
  State<KeychainPage> createState() => _KeychainPageState();
}

class _KeychainPageState extends State<KeychainPage> {
  final _search = TextEditingController();
  KeychainFilter _filter = KeychainFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(KeychainEntry entry) {
    final ok = switch (_filter) {
      KeychainFilter.all => true,
      KeychainFilter.passwords => entry.kind == AuthKind.password,
      KeychainFilter.keys => entry.kind == AuthKind.privateKey,
      KeychainFilter.certificates => entry.certificate != null,
    };
    if (!ok) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return entry.name.toLowerCase().contains(q) ||
        entry.username.toLowerCase().contains(q) ||
        (entry.keyFingerprint?.toLowerCase().contains(q) ?? false) ||
        entry.usedBy.any((label) => label.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rows = widget.entries.where(_matches).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Column(
      key: const ValueKey('keychain_page'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.r7NavKeychain,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      widget.scopeLabel ?? l10n.r7NavKeychainSubtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: widget.addButtonKey ?? const ValueKey('keychain_add'),
                onPressed: widget.canWrite && !widget.busy
                    ? widget.onAdd
                    : null,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.r7NavAdd),
              ),
            ],
          ),
        ),
        if (widget.busy) const LinearProgressIndicator(),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.error!,
                    key: const ValueKey('keychain_error'),
                    style: TextStyle(color: context.palette.orange),
                  ),
                ),
                if (widget.onRetry != null)
                  IconButton(
                    tooltip: l10n.retryRefresh,
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: TextField(
            key: const ValueKey('keychain_search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: l10n.r7NavKeychainSearchHint,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final filter in KeychainFilter.values)
                  ChoiceChip(
                    key: ValueKey('keychain_filter_${filter.name}'),
                    label: Text(switch (filter) {
                      KeychainFilter.all => l10n.r7NavLogFilterAll,
                      KeychainFilter.passwords => l10n.r7NavFilterPasswords,
                      KeychainFilter.keys => l10n.r7NavFilterKeys,
                      KeychainFilter.certificates =>
                        l10n.r7NavFilterCertificates,
                    }),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.entries.isEmpty
                          ? widget.emptyText ?? l10n.r7NavKeychainEmpty
                          : l10n.r7NavLogNoMatches,
                      key: const ValueKey('keychain_empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.muted),
                    ),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('keychain_list'),
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _KeychainRow(
                    rowKeyPrefix: widget.rowKeyPrefix,
                    entry: rows[index],
                    enabled: widget.canWrite && !widget.busy,
                    onEdit: () => widget.onEdit(rows[index]),
                    onDelete: () => widget.onDelete(rows[index]),
                  ),
                ),
        ),
        ?widget.footer,
      ],
    );
  }
}

class _KeychainRow extends StatelessWidget {
  const _KeychainRow({
    required this.entry,
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
    required this.rowKeyPrefix,
  });

  final KeychainEntry entry;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final String rowKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cert = tryParseCertificate(entry.certificate);
    final kindLabel = entry.kind == AuthKind.password
        ? l10n.r7NavKindPassword
        : cert != null
        ? l10n.r7NavKindKeyWithCertificate
        : l10n.r7NavKindPrivateKey;
    final referenced = entry.usedBy.isNotEmpty;
    final certOk = cert != null && cert.isValidAt(DateTime.now());
    final muted = TextStyle(fontSize: 12, color: context.palette.muted);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: ValueKey('$rowKeyPrefix${entry.id}'),
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        onTap: enabled ? onEdit : null,
        leading: Icon(
          entry.kind == AuthKind.password
              ? Icons.password_rounded
              : cert != null
              ? Icons.workspace_premium_outlined
              : Icons.key_rounded,
          size: 20,
          color: context.palette.accentText,
        ),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${entry.username} · $kindLabel', style: muted),
            if (entry.keyFingerprint != null)
              Text(
                entry.keyFingerprint!,
                style: muted.copyWith(fontFamily: 'monospace', fontSize: 11),
              ),
            if (cert != null)
              Text(
                [
                  if (cert.keyId.isNotEmpty) 'ID ${cert.keyId}',
                  cert.principals.isEmpty
                      ? l10n.r7NavCertAnyPrincipal
                      : l10n.r7NavCertPrincipals(cert.principals.join(', ')),
                  certificateValidityLabel(l10n, cert),
                  l10n.r7NavCertCa(cert.caFingerprint),
                ].join(' · '),
                key: ValueKey('keychain_cert_${entry.id}'),
                style: muted.copyWith(
                  fontSize: 11.5,
                  color: certOk ? context.palette.muted : context.palette.orange,
                ),
              ),
            Text(
              referenced
                  ? l10n.r7NavUsedBy(
                      entry.usedBy.length,
                      entry.usedBy.take(3).join(', '),
                    )
                  : l10n.r7NavNotUsed,
              key: ValueKey('keychain_usage_${entry.id}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: muted.copyWith(fontSize: 11.5),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          key: ValueKey('keychain_actions_${entry.id}'),
          enabled: enabled,
          tooltip: l10n.credentialActions,
          onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => [
            appMenuItem(context,value: 'edit', child: Text(l10n.editCredential)),
            // Deleting a referenced item is refused by the repository with a
            // notice naming the references (never a silent relink).
            appMenuItem(context,
              value: 'delete',
              child: Text(
                l10n.deleteCredential,
                style: referenced
                    ? TextStyle(color: context.palette.muted)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
