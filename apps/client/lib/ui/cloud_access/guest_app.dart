// Guest Web flow for `/s/<slug>#s1.<secret>`. Runs as its own small app: it
// never opens account storage, never signs in and never auto-connects.
// Redemption and connection each require an explicit click.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';

import '../../api/api_client.dart' show ApiException;
import '../../cloud/cloud_access_api.dart';
import '../../cloud/cloud_access_crypto.dart';
import '../../desktop/desktop_session.dart';
import '../../desktop/desktop_view.dart';
import '../../l10n/l10n.dart';
import '../app_theme.dart';
import '../app_theme_mode.dart';
import 'cloud_access_common.dart';
import 'guest_display_store.dart';

/// Extracts the slug from `/s/<slug>`; null for any other path.
String? guestSlugFromPath(String path) {
  final match = RegExp(r'^/s/([a-z0-9][a-z0-9-]{1,46}[a-z0-9])/?$')
      .firstMatch(path);
  return match?.group(1);
}

class GuestApp extends StatelessWidget {
  const GuestApp({
    required this.slug,
    required this.secret,
    required this.api,
    required this.sodium,
    super.key,
  });
  final String slug;
  final ShareLinkSecret? secret;
  final GuestApi api;
  final Future<SodiumSumo> Function() sodium;

  @override
  Widget build(BuildContext context) => AppThemeModeBuilder(
    builder: (context, themeMode) => AppLanguageHost(
      builder: (context, locale) => MaterialApp(
        onGenerateTitle: (context) => context.l10n.cloudAccessGuestWindowTitle,
        debugShowCheckedModeBanner: false,
        locale: locale,
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(locale: locale, brightness: Brightness.light),
        darkTheme: buildAppTheme(locale: locale),
        themeMode: themeMode,
        home: GuestPage(slug: slug, secret: secret, api: api, sodium: sodium),
      ),
    ),
  );
}

enum _GuestStage { landing, loading, ready, connected, unavailable }

class GuestPage extends StatefulWidget {
  const GuestPage({
    required this.slug,
    required this.secret,
    required this.api,
    required this.sodium,
    super.key,
  });
  final String slug;
  final ShareLinkSecret? secret;
  final GuestApi api;
  final Future<SodiumSumo> Function() sodium;

  @override
  State<GuestPage> createState() => _GuestPageState();
}

class _GuestPageState extends State<GuestPage> {
  _GuestStage stage = _GuestStage.loading;
  Map<String, dynamic>? view;
  ShareDisplay? display;
  String? error;
  DesktopSession? session;
  String? closedReason;
  String? notice;

  @override
  void initState() {
    super.initState();
    // A fresh link shows only a neutral landing page until the visitor
    // clicks; a refresh without a fragment tries to resume the session.
    if (widget.secret != null) {
      stage = _GuestStage.landing;
    } else {
      unawaited(_resume());
    }
  }

  @override
  void dispose() {
    session?.dispose();
    widget.secret?.wipe();
    super.dispose();
  }

  Future<void> _decryptDisplay(
    Map<String, dynamic> value, {
    Uint8List? key,
  }) async {
    final linkId = value['link_id'] as String;
    final version = value['secret_version'] as int;
    final displayKey = key ?? GuestDisplayStore.read(linkId, version);
    if (displayKey == null) return;
    try {
      final sodium = await widget.sodium();
      display = openShareDisplay(
        sodium,
        displayKey,
        linkId,
        version,
        value['display_envelope'] as String,
      );
      GuestDisplayStore.write(linkId, version, displayKey);
    } catch (_) {
      display = null;
    }
  }

  /// Never display (or later connect to) another link under this address.
  void _requireThisAddress(Map<String, dynamic> value) {
    if (value['slug'] != widget.slug) {
      throw const ApiException(
        statusCode: 404,
        code: 'SHARE_LINK_UNAVAILABLE',
        message: 'link address mismatch',
      );
    }
  }

  Future<void> _resume() async {
    try {
      final value = await widget.api.session(widget.slug);
      _requireThisAddress(value);
      await _decryptDisplay(value);
      if (mounted)
        setState(() {
          view = value;
          stage = _GuestStage.ready;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = cloudAccessErrorText(context, e);
          stage = _GuestStage.unavailable;
        });
    }
  }

  Future<void> _redeem() async {
    final secret = widget.secret;
    if (secret == null) return;
    setState(() => stage = _GuestStage.loading);
    try {
      final value = await widget.api.redeem(
        widget.slug,
        await secret.redeemToken(),
      );
      _requireThisAddress(value);
      final key = await secret.displayKey(
        value['link_id'] as String,
        value['secret_version'] as int,
      );
      await _decryptDisplay(value, key: key);
      secret.wipe();
      if (mounted)
        setState(() {
          view = value;
          stage = _GuestStage.ready;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = cloudAccessErrorText(context, e);
          stage = _GuestStage.unavailable;
        });
    }
  }

  Future<void> _connect(Map target) async {
    setState(() {
      closedReason = null;
      notice = null;
    });
    try {
      final ticket = await widget.api.connection(
        widget.slug,
        target['target_id'] as String,
      );
      final desktop = DesktopSession();
      desktop.addListener(() {
        if (!mounted) return;
        if (desktop.state == 'disconnected') {
          setState(() {
            closedReason = _closeText(
              desktop.gatewayCloseCode,
              desktop.gatewayCloseReason,
            );
            stage = _GuestStage.ready;
          });
        } else {
          setState(() {});
        }
      });
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      setState(() {
        session?.dispose();
        session = desktop;
        stage = _GuestStage.connected;
      });
      await desktop.connectGateway(
        socketUri: widget.api.gatewaySocketUri(
          ticket['connect_path'] as String,
        ),
        ticket: ticket['ticket'] as String,
        width: size.width.clamp(320, 4096).toInt(),
        height: (size.height - 48).clamp(200, 4096).toInt(),
        onControl: (frame) {
          if (frame['type'] == 'notice' &&
              frame['code'] == 'SESSION_EXPIRING' &&
              mounted) {
            setState(() => notice = context.l10n.cloudAccessGuestExpiringSoon);
          }
        },
      );
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  String _closeText(int? code, String? reason) {
    final l10n = context.l10n;
    return switch (code) {
      4403 => l10n.cloudAccessGuestClosedRevoked,
      4408 => l10n.cloudAccessGuestClosedExpired,
      4429 => l10n.cloudAccessGuestBusy,
      4502 => l10n.cloudAccessGuestClosedTarget,
      4400 => l10n.cloudAccessGuestClosedProtocol,
      _ => l10n.cloudAccessGuestClosed,
    };
  }

  Future<void> _leave() async {
    session?.dispose();
    session = null;
    try {
      await widget.api.logout();
    } catch (_) {}
    final linkId = view?['link_id'] as String?;
    if (linkId != null) GuestDisplayStore.clear(linkId);
    if (mounted)
      setState(() {
        view = null;
        stage = _GuestStage.unavailable;
        error = context.l10n.cloudAccessGuestLeft;
      });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    if (stage == _GuestStage.connected && session != null) {
      return Scaffold(
        body: Column(
          children: [
            Container(
              height: 48,
              color: palette.surfaceRaised,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.link, size: 18, color: palette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      display?.title ?? l10n.cloudAccessGuestHeading,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (notice != null)
                    Text(
                      notice!,
                      style: TextStyle(color: palette.orange, fontSize: 12),
                    ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      session?.dispose();
                      setState(() {
                        session = null;
                        stage = _GuestStage.ready;
                      });
                    },
                    icon: const Icon(Icons.link_off, size: 18),
                    label: Text(l10n.cloudAccessGuestDisconnect),
                  ),
                ],
              ),
            ),
            Expanded(child: DesktopView(session: session!)),
          ],
        ),
      );
    }
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (stage) {
              _GuestStage.loading => const CircularProgressIndicator(),
              _GuestStage.landing => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link, size: 44, color: palette.accent),
                  const SizedBox(height: 12),
                  Text(
                    l10n.cloudAccessGuestLanding,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.cloudAccessGuestLandingHelp,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    key: const ValueKey('cloud-access-guest-continue'),
                    onPressed: _redeem,
                    child: Text(l10n.cloudAccessGuestContinue),
                  ),
                ],
              ),
              _GuestStage.unavailable => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link_off, size: 44, color: palette.muted),
                  const SizedBox(height: 12),
                  Text(
                    error ?? l10n.cloudAccessGuestUnavailable,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.cloudAccessGuestAskOwner,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted),
                  ),
                ],
              ),
              _ => _ReadyView(
                view: view!,
                display: display,
                closedReason: closedReason,
                error: error,
                onConnect: _connect,
                onLeave: _leave,
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _ReadyView extends StatelessWidget {
  const _ReadyView({
    required this.view,
    required this.display,
    required this.closedReason,
    required this.error,
    required this.onConnect,
    required this.onLeave,
  });
  final Map<String, dynamic> view;
  final ShareDisplay? display;
  final String? closedReason;
  final String? error;
  final ValueChanged<Map> onConnect;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final perms = Map<String, dynamic>.from(view['permissions'] as Map);
    final targets = (view['targets'] as List).cast<Map>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          display?.title ?? l10n.cloudAccessGuestHeading,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.cloudAccessGuestValidUntil(
            cloudAccessShortTime(
              context,
              view['session_expires_at'] as String?,
            ),
          ),
          style: TextStyle(color: palette.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 4),
        Text(
          [
            perms['view_only'] == true
                ? l10n.cloudAccessGuestViewOnly
                : l10n.cloudAccessGuestInteractive,
            perms['clipboard_to_remote'] == true ||
                    perms['clipboard_from_remote'] == true
                ? l10n.cloudAccessGuestClipboardOn
                : l10n.cloudAccessGuestClipboardOff,
          ].join(' · '),
          style: TextStyle(color: palette.muted, fontSize: 12.5),
        ),
        if (closedReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(closedReason!, style: TextStyle(color: palette.orange)),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(error!, style: TextStyle(color: palette.red)),
          ),
        const SizedBox(height: 12),
        for (final target in targets)
          Card(
            child: ListTile(
              leading: Icon(
                target['protocol'] == 'ssh'
                    ? Icons.terminal
                    : Icons.desktop_windows_outlined,
                color: target['protocol'] == 'ssh'
                    ? palette.teal
                    : palette.hostBlue,
              ),
              title: Text(
                display?.targets[target['target_id']] ??
                    '${target['protocol']}'.toUpperCase(),
              ),
              subtitle: Text('${target['protocol']}'.toUpperCase()),
              trailing: FilledButton(
                onPressed: target['available'] == true
                    ? () => onConnect(target)
                    : null,
                child: Text(l10n.cloudAccessGuestConnect),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          l10n.cloudAccessGuestTrustNote,
          style: TextStyle(color: palette.muted, fontSize: 11.5),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onLeave,
            child: Text(l10n.cloudAccessGuestLeave),
          ),
        ),
      ],
    );
  }
}
