import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/browser_storage_status.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';

/// Shows origin-wide browser persistence and quota estimates.
///
/// The estimate is advisory, and browser persistence only reduces automatic
/// eviction risk; neither should be presented as a backup guarantee.
class BrowserStorageStatusCard extends StatefulWidget {
  const BrowserStorageStatusCard({
    this.service,
    this.pendingCount = 0,
    super.key,
  });

  final BrowserStorageStatusService? service;
  final int pendingCount;

  @override
  State<BrowserStorageStatusCard> createState() =>
      _BrowserStorageStatusCardState();
}

class _BrowserStorageStatusCardState extends State<BrowserStorageStatusCard> {
  late final BrowserStorageStatusService _service;
  BrowserStorageStatus? _status;
  bool _loading = true;
  bool _requesting = false;
  String? _requestMessage;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BrowserStorageStatusService();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    BrowserStorageStatus status;
    try {
      status = await _service.read();
    } on Object {
      status = BrowserStorageStatus(
        supported: _service.supported,
        persisted: null,
        usageBytes: null,
        quotaBytes: null,
        canRequestPersistence: false,
      );
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
      _requestMessage = null;
    });
  }

  Future<void> _requestPersistence() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _requestMessage = null;
    });
    var status = _status;
    var message = context.l10n.theBrowserCouldNotConfirmPersistent;
    try {
      final accepted = await _service.requestPersistence();
      // Re-read persisted() rather than treating persist()'s return as current
      // state. Some browsers can decline, defer, or change bucket policy.
      status = await _service.read();
      message = switch (status.persisted) {
        true => currentL10n.theBrowserCurrentlyReportsPersistentStorage,
        false when accepted == true =>
          currentL10n.theRequestReturnedSuccessButThe,
        false => currentL10n.theBrowserDidNotEnablePersistent,
        null when accepted == true =>
          currentL10n.theRequestReturnedSuccessButThe2,
        null => currentL10n.theBrowserCouldNotConfirmPersistent,
      };
    } on Object {
      status = BrowserStorageStatus(
        supported: _service.supported,
        persisted: null,
        usageBytes: null,
        quotaBytes: null,
        canRequestPersistence: false,
      );
      message = currentL10n.theBrowserCouldNotConfirmPersistent;
    } finally {
      if (mounted) {
        setState(() {
          _status = status;
          _requesting = false;
          _requestMessage = message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (!_service.supported || status?.supported == false) {
      return const SizedBox.shrink();
    }

    final persistenceText = switch (status?.persisted) {
      true => context.l10n.persistentStorageIsEnabled,
      false => context.l10n.persistentStorageIsNotEnabled,
      null =>
        _loading
            ? context.l10n.checkingPersistentStorage
            : context.l10n.persistentStorageStatusIsUnavailable,
    };
    final usageText = status?.hasEstimate == true
        ? context.l10n.estimatedUsageFormatbytesOfFormatbytes2For(_formatBytes(status!.usageBytes!), _formatBytes(status.quotaBytes!))
        : _loading
        ? context.l10n.checkingStorageUsageEstimate
        : context.l10n.storageUsageEstimateIsUnavailable;

    return Card(
      key: const ValueKey('browser_storage_status_card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.browserStorage,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                persistenceText,
                key: const ValueKey('browser_storage_persisted_state'),
                style: TextStyle(
                  color: status?.persisted == true
                      ? context.palette.teal
                      : context.palette.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              usageText,
              key: const ValueKey('browser_storage_estimate'),
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              context.l10n.persistentStorageCanReduceAutomaticEviction,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (widget.pendingCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.pendingcountEncryptedChangeSAreWaiting(widget.pendingCount),
                key: const ValueKey('browser_storage_pending_outbox_warning'),
                style: TextStyle(
                  color: context.palette.orange,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            if (_requestMessage case final message?) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  key: const ValueKey('browser_storage_request_result'),
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: const ValueKey('browser_storage_refresh'),
                  onPressed: _loading || _requesting ? null : _refresh,
                  child: Text(context.l10n.checkAgain),
                ),
                if (status?.canRequestPersistence == true &&
                    status?.persisted != true)
                  FilledButton(
                    key: const ValueKey('browser_storage_request'),
                    onPressed: _loading || _requesting
                        ? null
                        : _requestPersistence,
                    child: Text(
                      _requesting
                          ? 'Requesting…'
                          : context.l10n.requestPersistentStorage,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kibibytes = bytes / 1024;
    if (kibibytes < 1024) return context.l10n.roundKib(kibibytes.round());
    final mebibytes = kibibytes / 1024;
    if (mebibytes < 1024) return context.l10n.roundMib(mebibytes.round());
    return context.l10n.roundGib((mebibytes / 1024).round());
  }
}
