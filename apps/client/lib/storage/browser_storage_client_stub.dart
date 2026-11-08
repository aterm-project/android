import 'browser_storage_client.dart';

BrowserStorageClient createBrowserStorageClient() =>
    const _UnavailableBrowserStorageClient();

class _UnavailableBrowserStorageClient implements BrowserStorageClient {
  const _UnavailableBrowserStorageClient();

  @override
  bool get canEstimate => false;

  @override
  bool get canReadPersistence => false;

  @override
  bool get canRequestPersistence => false;

  @override
  Future<BrowserStorageEstimate> estimate() async =>
      throw UnsupportedError('Browser storage is unavailable.');

  @override
  Future<bool> persisted() async =>
      throw UnsupportedError('Browser storage is unavailable.');

  @override
  Future<bool> requestPersistence() async =>
      throw UnsupportedError('Browser storage is unavailable.');
}
