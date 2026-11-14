import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../desktop/desktop_session.dart' show DesktopSession;
import '../desktop/direct/rdp.dart' show rdpEngineFeatures;
import '../desktop/desktop_resolution.dart';
import '../desktop/rdp_features.dart';
import '../desktop/rdp_folder_picker.dart';
import '../desktop/rdp_local_drives.dart';
import '../desktop/rdp_settings.dart';
import '../desktop/rdp_settings_editor.dart';
import '../domain/models.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';
import '../telnet/telnet_ui.dart';

const _uuid = Uuid();

/// One selectable Keychain credential (public facts only) for a Host.
@immutable
class HostKeychainChoice {
  const HostKeychainChoice({required this.id, required this.label});
  final String id;
  final String label;
}

const _sourceOwn = 'own';
const _sourceInherit = 'inherit';
String _sourceKeychain(String id) => 'k:$id';

Future<HostRecord?> showHostEditorPanel(
  BuildContext context, {
  HostRecord? existing,
  HostRecord? initialDraft,
  String? submitLabel,
  HostProtocol initialProtocol = HostProtocol.ssh,
  required List<GroupRecord> groups,
  required List<HostRecord> hosts,
  CredentialRecord? initialCredential,
  List<HostKeychainChoice> keychain = const [],
  String? Function(HostRecord)? onValidate,
  bool canEdit = true,
  String keyPrefix = 'host_editor',
}) => showAppDialog<HostRecord>(
  context: context,
  motion: AppDialogMotion.sideSheet,
  builder: (_) => HostEditorPanel(
    existing: existing,
    initialDraft: initialDraft,
    submitLabel: submitLabel,
    initialProtocol: initialProtocol,
    groups: groups,
    hosts: hosts,
    initialCredential: initialCredential,
    keychain: keychain,
    onValidate: onValidate,
    canEdit: canEdit,
    keyPrefix: keyPrefix,
  ),
);

class HostEditorPanel extends StatefulWidget {
  const HostEditorPanel({
    super.key,
    required this.groups,
    required this.hosts,
    this.existing,
    this.initialDraft,
    this.submitLabel,
    this.initialProtocol = HostProtocol.ssh,
    this.initialCredential,
    this.keychain = const [],
    this.onValidate,
    this.canEdit = true,
    this.keyPrefix = 'host_editor',
    this.rdpFeaturesForTesting,
  });
  final List<GroupRecord> groups;
  final List<HostRecord> hosts;

  /// The credential the Host currently resolves to (its own inline sign-in,
  /// a referenced Keychain item, or the group default).
  final CredentialRecord? initialCredential;

  /// Keychain items the Host may reference instead of its own sign-in.
  final List<HostKeychainChoice> keychain;
  final String? Function(HostRecord)? onValidate;
  final bool canEdit;
  final String keyPrefix;
  final HostRecord? existing;
  final HostRecord? initialDraft;
  final String? submitLabel;
  final HostProtocol initialProtocol;

  /// Replaces the installed engine's capabilities in widget tests.
  @visibleForTesting
  final RdpFeatures? rdpFeaturesForTesting;

  @override
  State<HostEditorPanel> createState() => _HostEditorPanelState();
}

class _HostEditorPanelState extends State<HostEditorPanel> {
  late final TextEditingController _rdpFingerprint;
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _username;
  late final TextEditingController _port;
  late final TextEditingController _tags;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late AuthKind _kind;
  late HostProtocol _protocol;
  late String? _groupId;
  late String? _jumpHostId;
  String? _formError;
  bool _editingPrivateKey = false;

  /// Sign-in source: own inline login, inherited group default, or a
  /// referenced Keychain item. Referenced/inherited credentials are never
  /// silently copied into the Host (no relink, certificates preserved).
  late String _source;
  late final String _initialSource;
  late RdpSettings _rdpSettings;
  late VncSettings _vncSettings;

  /// Device-local "Map local disks" choice (on by default, never synced).
  late bool _mapLocalDisks;

  @override
  void initState() {
    super.initState();
    final item = widget.existing ?? widget.initialDraft;
    _protocol = item?.protocol ?? widget.initialProtocol;
    _rdpSettings = item == null ? RdpSettings.defaults : RdpSettings.of(item);
    _vncSettings = item == null ? VncSettings.defaults : VncSettings.of(item);
    _mapLocalDisks = RdpLocalDrivesController.instance.enabled(
      widget.existing?.id,
    );
    _rdpFingerprint = TextEditingController(
      text: item?.rdpCertificateSha256 ?? '',
    );
    _name = TextEditingController(text: item?.name ?? '');
    _address = TextEditingController(text: item?.address ?? '');
    _username = TextEditingController(text: item?.username ?? '');
    _port = TextEditingController(
      text: '${item?.port ?? _protocol.defaultPort}',
    );
    _tags = TextEditingController(text: item?.tags.join(', ') ?? '');
    final credential = widget.initialCredential;
    final referenceId = item?.credentialId;
    _source = item?.login != null
        ? _sourceOwn
        : referenceId != null
        ? _sourceKeychain(referenceId)
        : credential != null && item != null
        ? _sourceInherit
        : _sourceOwn;
    _initialSource = _source;
    _kind =
        item?.login?.kind ??
        credential?.kind ??
        item?.authKind ??
        AuthKind.password;
    // Only the Host's own login is shown in its fields.
    _password = TextEditingController(text: item?.login?.password ?? '');
    _privateKey = TextEditingController(text: item?.login?.privateKey ?? '');
    _passphrase = TextEditingController(text: item?.login?.passphrase ?? '');
    if (_username.text.isEmpty) _username.text = credential?.username ?? '';
    _groupId = item?.groupId;
    _jumpHostId = item?.jumpHostId;
  }

  @override
  void dispose() {
    _rdpFingerprint.dispose();
    _name.dispose();
    _address.dispose();
    _username.dispose();
    _port.dispose();
    _tags.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = widget.canEdit;
    final hostsById = {for (final host in widget.hosts) host.id: host};
    final eligibleJumpHosts = widget.hosts
        .where((host) => _isEligibleJumpHost(host, hostsById))
        .toList(growable: false);
    final hasEligibleJumpHost = eligibleJumpHosts.any(
      (host) => host.id == _jumpHostId,
    );
    final unavailableJumpHost = _jumpHostId != null && !hasEligibleJumpHost;
    final density = AppDensity.of(context);
    final fieldGap = SizedBox(height: density.space4 + density.space1);
    return Dialog(
      insetPadding: EdgeInsets.zero,
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: density.dialogMd + density.space7,
        height: double.infinity,
        child: Padding(
          padding: density.dialogPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.existing == null
                          ? context.l10n.addAHost
                          : context.l10n.editHost,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              SizedBox(height: density.space5),
              Expanded(
                child: SizedBox(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<HostProtocol>(
                          isExpanded: true,
                          key: ValueKey('${widget.keyPrefix}_protocol'),
                          initialValue: _protocol,
                          decoration: InputDecoration(
                            labelText: context.l10n.protocol,
                          ),
                          items: HostProtocol.values
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(p.label),
                                ),
                              )
                              .toList(),
                          onChanged: canEdit
                              ? (value) => setState(() {
                                  if (value == null) return;
                                  if (_port.text ==
                                      '${_protocol.defaultPort}') {
                                    _port.text = '${value.defaultPort}';
                                  }
                                  _protocol = value;
                                  if (value != HostProtocol.ssh) {
                                    _kind = AuthKind.password;
                                    _jumpHostId = null;
                                  }
                                })
                              : null,
                        ),
                        fieldGap,
                        _field(
                          _name,
                          context.l10n.displayName,
                          id: 'name',
                          icon: Icons.computer_rounded,
                        ),
                        fieldGap,
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _field(
                                _address,
                                context.l10n.hostnameOrIp,
                                id: 'address',
                                icon: Icons.language_rounded,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _field(
                                _port,
                                context.l10n.port2,
                                id: 'port',
                                keyboard: TextInputType.number,
                              ),
                            ),
                          ],
                        ),
                        fieldGap,
                        // Telnet login is interactive; no user name is stored
                        // or sent automatically.
                        if (_protocol != HostProtocol.telnet) ...[
                          _field(
                            _username,
                            _protocol == HostProtocol.ssh
                                ? context.l10n.sshUsername
                                : context.l10n.usernameOptional,
                            id: 'username',
                            icon: Icons.person_outline,
                          ),
                          fieldGap,
                        ],
                        TextField(
                          key: ValueKey('${widget.keyPrefix}_tags'),
                          controller: _tags,
                          decoration: InputDecoration(
                            labelText: context.l10n.tags,
                            helperText: context.l10n.separateTagsWithCommas,
                            prefixIcon: const Icon(Icons.sell_outlined),
                          ),
                        ),
                        fieldGap,
                        if (_protocol == HostProtocol.rdp) ...[
                          TextField(
                            key: ValueKey(
                              '${widget.keyPrefix}_rdp_fingerprint',
                            ),
                            controller: _rdpFingerprint,
                            decoration: InputDecoration(
                              labelText:
                                  context.l10n.rdpCertificateSha256Optional,
                              helperText: context
                                  .l10n
                                  .pinTheCertificateFingerprintSuppliedBy,
                            ),
                          ),
                          fieldGap,
                          RdpSettingsEditor(
                            keyPrefix: widget.keyPrefix,
                            initial: _rdpSettings,
                            unreadable:
                                widget.existing != null &&
                                RdpSettings.unreadable(widget.existing!),
                            features:
                                widget.rdpFeaturesForTesting ??
                                rdpEngineFeatures(),
                            pickFolder: pickRdpRedirectFolder,
                            pickDisk: rdpDiskPickerAvailable
                                ? pickRdpRedirectDisk
                                : null,
                            onChanged: (value) => _rdpSettings = value,
                            localVolumes:
                                RdpLocalDrivesController.instance.source,
                            localDrives: RdpLocalDrivesController.instance,
                            mapLocalDisks: _mapLocalDisks,
                            onMapLocalDisksChanged: _setMapLocalDisks,
                          ),
                          fieldGap,
                        ],
                        if (_protocol == HostProtocol.vnc) ...[
                          VncSettingsEditor(
                            keyPrefix: widget.keyPrefix,
                            initial: _vncSettings,
                            onChanged: (value) => _vncSettings = value,
                          ),
                          fieldGap,
                        ],
                        if (_protocol == HostProtocol.ssh &&
                            (widget.keychain.isNotEmpty ||
                                _initialSource != _sourceOwn)) ...[
                          DropdownButtonFormField<String>(
                            key: ValueKey('${widget.keyPrefix}_sign_in_source'),
                            initialValue: _source,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: context.l10n.r7NavSignInSource,
                            ),
                            items: _sourceItems(context),
                            onChanged: canEdit
                                ? (value) =>
                                      setState(() => _selectSource(value!))
                                : null,
                          ),
                          if (_source != _sourceOwn)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _source == _sourceInherit
                                    ? context.l10n.r7NavSignInInheritedNote
                                    : context.l10n.r7NavSignInKeychainNote,
                                key: ValueKey(
                                  '${widget.keyPrefix}_sign_in_note',
                                ),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          const SizedBox(height: 11),
                        ],
                        if (_protocol == HostProtocol.ssh &&
                            _source == _sourceOwn)
                          DropdownButtonFormField<AuthKind>(
                            isExpanded: true,
                            key: ValueKey('${widget.keyPrefix}_kind'),
                            initialValue: _kind,
                            decoration: InputDecoration(
                              labelText: context.l10n.authentication,
                            ),
                            items: [
                              DropdownMenuItem(
                                value: AuthKind.password,
                                child: Text(context.l10n.password),
                              ),
                              DropdownMenuItem(
                                value: AuthKind.privateKey,
                                child: Text(context.l10n.privateKey),
                              ),
                            ],
                            onChanged: canEdit
                                ? (value) => setState(() => _kind = value!)
                                : null,
                          ),
                        fieldGap,
                        if (_protocol == HostProtocol.telnet)
                          const TelnetPlaintextNotice()
                        else if (_protocol == HostProtocol.ssh &&
                            _source != _sourceOwn)
                          const SizedBox.shrink()
                        else if (_kind == AuthKind.password)
                          _secretField(
                            _password,
                            _protocol == HostProtocol.ssh
                                ? context.l10n.sshPasswordLabel
                                : context.l10n.passwordOptionalLabel,
                            'host_login_password',
                          )
                        else ...[
                          _secretField(
                            _privateKey,
                            context.l10n.sshPrivateKey,
                            'host_login_private_key',
                          ),
                          fieldGap,
                          _secretField(
                            _passphrase,
                            context.l10n.keyPassphraseOptional,
                            'host_login_passphrase',
                          ),
                        ],
                        SizedBox(height: density.space3),
                        Text(
                          _protocol == HostProtocol.ssh
                              ? context.l10n.loginDetailsBelongToThisHost
                              : _protocol == HostProtocol.telnet
                              ? context.l10n.telnetLoginInteractiveHint
                              // Direct desktops (Android VNC/RDP, Windows) have
                              // no gateway; the gateway notice stays for web
                              // and gateway-routed clients.
                              : DesktopSession.supportsDirect(_protocol)
                              ? context.l10n.directDesktopSignInHint
                              : context.l10n.signInDetailsAreStoredEncrypted,
                          style: const TextStyle(fontSize: 12),
                        ),
                        fieldGap,
                        if (_protocol == HostProtocol.ssh)
                          DropdownButtonFormField<String?>(
                            key: ValueKey('${widget.keyPrefix}_jump_host'),
                            initialValue: _jumpHostId,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: context.l10n.jumpHost,
                              helperText: unavailableJumpHost
                                  ? context.l10n.thisSavedJumpHostIsUnavailable
                                  : context.l10n.routeThroughUpTo8Hosts,
                            ),
                            items: [
                              DropdownMenuItem<String?>(
                                value: null,
                                child: Text(context.l10n.directConnection),
                              ),
                              if (unavailableJumpHost)
                                DropdownMenuItem<String?>(
                                  value: _jumpHostId,
                                  enabled: false,
                                  child: Text(context.l10n.unavailableJumpHost),
                                ),
                              ...eligibleJumpHosts.map(
                                (host) => DropdownMenuItem<String?>(
                                  value: host.id,
                                  child: Semantics(
                                    container: true,
                                    identifier:
                                        'ssh-jump-host-option-${host.id}',
                                    label: '${host.name} · ${host.endpoint}',
                                    child: ExcludeSemantics(
                                      child: Text(
                                        '${host.name} · ${host.endpoint}',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            onChanged: canEdit
                                ? (value) => setState(() => _jumpHostId = value)
                                : null,
                          ),
                        if (_groupId != null || widget.groups.isNotEmpty) ...[
                          fieldGap,
                          DropdownButtonFormField<String?>(
                            isExpanded: true,
                            key: ValueKey('${widget.keyPrefix}_group'),
                            initialValue: _groupId,
                            decoration: InputDecoration(
                              labelText: context.l10n.group,
                              helperText:
                                  _groupId != null &&
                                      !widget.groups.any(
                                        (group) => group.id == _groupId,
                                      )
                                  ? context
                                        .l10n
                                        .thisSavedGroupIsUnavailableChoose
                                  : null,
                            ),
                            items: [
                              DropdownMenuItem<String?>(
                                value: null,
                                child: Text(context.l10n.noGroup),
                              ),
                              if (_groupId != null &&
                                  !widget.groups.any(
                                    (group) => group.id == _groupId,
                                  ))
                                DropdownMenuItem<String?>(
                                  value: _groupId,
                                  enabled: false,
                                  child: Text(context.l10n.unavailableGroup),
                                ),
                              ...widget.groups.map(
                                (group) => DropdownMenuItem(
                                  value: group.id,
                                  child: Text(group.name),
                                ),
                              ),
                            ],
                            onChanged: canEdit
                                ? (value) => setState(() => _groupId = value)
                                : null,
                          ),
                        ],
                        if (_formError != null)
                          Padding(
                            padding: EdgeInsets.only(top: density.space5),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _formError!,
                                style: TextStyle(color: context.palette.red),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: density.space5),
              Wrap(
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.l10n.cancel2),
                  ),
                  FilledButton(
                    key: ValueKey('${widget.keyPrefix}_save'),
                    onPressed: canEdit ? _save : null,
                    child: Text(
                      widget.submitLabel ?? context.l10n.saveEncryptedHost,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isEligibleJumpHost(
    HostRecord candidate,
    Map<String, HostRecord> hostsById,
  ) {
    final currentHostId = widget.existing?.id;
    if (candidate.protocol != HostProtocol.ssh || candidate.id == currentHostId)
      return false;

    final seen = <String>{?currentHostId};
    var host = candidate;
    var routeLength = 1;
    while (true) {
      if (!seen.add(host.id)) return false;
      final jumpHostId = host.jumpHostId;
      if (jumpHostId == null) return true;
      if (routeLength == maxJumpHostHops) return false;
      final next = hostsById[jumpHostId];
      if (next == null) return false;
      host = next;
      routeLength++;
    }
  }

  List<DropdownMenuItem<String>> _sourceItems(BuildContext context) {
    final l10n = context.l10n;
    final items = <String, String>{
      _sourceOwn: l10n.r7NavSignInOwn,
      if (_initialSource == _sourceInherit)
        _sourceInherit: l10n.r7NavSignInInherited,
      for (final choice in widget.keychain)
        _sourceKeychain(choice.id): l10n.r7NavSignInKeychainItem(choice.label),
    };
    if (_initialSource.startsWith('k:') && !items.containsKey(_initialSource)) {
      items[_initialSource] = l10n.r7NavSignInKeychainItem(
        widget.initialCredential?.name ?? l10n.r7NavKeychain,
      );
    }
    return [
      for (final entry in items.entries)
        DropdownMenuItem(
          value: entry.key,
          child: Text(entry.value, overflow: TextOverflow.ellipsis),
        ),
    ];
  }

  void _selectSource(String value) {
    _source = value;
    if (value == _sourceOwn &&
        _password.text.isEmpty &&
        _privateKey.text.isEmpty) {
      // Explicit user choice: start the Host's own sign-in from the
      // credential it used so far (certificates are Keychain-only).
      final credential = widget.initialCredential;
      if (credential != null) {
        _kind = credential.kind;
        _password.text = credential.secret ?? '';
        _privateKey.text = credential.privateKey ?? '';
        _passphrase.text = credential.passphrase ?? '';
      }
    }
  }

  Widget _secretField(
    TextEditingController controller,
    String label,
    String key,
  ) {
    if (key == 'host_login_private_key') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_editingPrivateKey)
            TextField(
              key: ValueKey(
                '${widget.keyPrefix}_${key == 'host_login_password'
                    ? 'password'
                    : key == 'host_login_private_key'
                    ? 'private_key'
                    : 'passphrase'}',
              ),
              controller: controller,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(labelText: label),
            )
          else
            InputDecorator(
              decoration: InputDecoration(labelText: label),
              child: Text(
                controller.text.isEmpty
                    ? context.l10n.noKeyEntered
                    : '••••••••',
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _editingPrivateKey = !_editingPrivateKey),
              icon: Icon(
                _editingPrivateKey
                    ? Icons.visibility_off_outlined
                    : Icons.edit_outlined,
                size: 16,
              ),
              label: Text(
                _editingPrivateKey
                    ? context.l10n.hidePrivateKey
                    : context.l10n.editPrivateKey,
              ),
            ),
          ),
        ],
      );
    }
    return TextField(
      key: ValueKey(
        '${widget.keyPrefix}_${key == 'host_login_password'
            ? 'password'
            : key == 'host_login_private_key'
            ? 'private_key'
            : 'passphrase'}',
      ),
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(labelText: label),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    // Stable widget identity; never derived from the (localized) label.
    required String id,
    IconData? icon,
    TextInputType? keyboard,
  }) => TextField(
    key: ValueKey('${widget.keyPrefix}_$id'),
    controller: controller,
    keyboardType: keyboard,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: icon == null ? null : Icon(icon),
    ),
  );

  /// A saved Host applies the device-local choice at once, even where the
  /// Host itself is read-only; a new Host keeps it until it is saved.
  void _setMapLocalDisks(bool value) {
    _mapLocalDisks = value;
    final id = widget.existing?.id;
    if (id != null) {
      unawaited(RdpLocalDrivesController.instance.setEnabled(id, value));
    }
  }

  void _save() {
    final port = int.tryParse(_port.text.trim());
    final host = HostRecord(
      id: widget.existing?.id ?? _uuid.v4(),
      name: _name.text.trim(),
      address: _address.text.trim(),
      port: port ?? 0,
      protocol: _protocol,
      rdpCertificateSha256:
          _protocol == HostProtocol.rdp &&
              _rdpFingerprint.text.trim().isNotEmpty
          ? _rdpFingerprint.text.trim().replaceAll(':', '').toLowerCase()
          : null,
      username: _protocol == HostProtocol.telnet ? '' : _username.text.trim(),
      groupId: _groupId,
      credentialId: _protocol == HostProtocol.ssh && _source.startsWith('k:')
          ? _source.substring(2)
          : null,
      login:
          _protocol == HostProtocol.telnet ||
              (_protocol == HostProtocol.ssh && _source != _sourceOwn) ||
              (_kind == AuthKind.password
                  ? _password.text.isEmpty
                  : _privateKey.text.isEmpty)
          ? null
          : HostLogin(
              kind: _kind,
              password: _kind == AuthKind.password ? _password.text : null,
              privateKey: _kind == AuthKind.privateKey
                  ? _privateKey.text
                  : null,
              passphrase:
                  _kind == AuthKind.privateKey && _passphrase.text.isNotEmpty
                  ? _passphrase.text
                  : null,
            ),
      jumpHostId: _jumpHostId,
      authKind: _protocol == HostProtocol.ssh && _source != _sourceOwn
          ? widget.existing?.authKind ?? _kind
          : _kind,
      color: widget.existing?.color ?? 0,
      tags: parseHostTags(_tags.text),
      portForwardProfiles: _protocol == HostProtocol.ssh
          ? widget.existing?.portForwardProfiles ?? const []
          : const [],
      isFavorite: widget.existing?.isFavorite ?? false,
      lastConnected: widget.existing?.lastConnected,
      revisionId: widget.existing?.revisionId,
      baseRevisionId: widget.existing?.baseRevisionId,
      online: widget.existing?.online ?? false,
      manifest:
          (_protocol == HostProtocol.vnc ? _vncSettings : VncSettings.defaults)
              .applyTo(
                (_protocol == HostProtocol.rdp
                        ? _rdpSettings
                        : RdpSettings.defaults)
                    .applyTo(widget.existing?.manifest),
              ),
    );
    final issue =
        (_protocol == HostProtocol.rdp ? _rdpSettings.validate() : null) ??
        (_protocol == HostProtocol.vnc ? _vncSettings.validate() : null) ??
        host.validate();
    if (issue != null) {
      setState(() => _formError = issue);
      return;
    }
    final referenceIssue = widget.onValidate?.call(host);
    if (referenceIssue != null) {
      setState(() => _formError = referenceIssue);
      return;
    }
    // Device-local only. A saved Host applied a change already when the
    // switch moved; re-applying the value shown would turn mapping off for
    // good if the stored choices could not be read when the editor opened.
    if (_protocol == HostProtocol.rdp && widget.existing == null) {
      unawaited(
        RdpLocalDrivesController.instance.setEnabled(host.id, _mapLocalDisks),
      );
    }
    Navigator.pop(context, host);
  }
}
