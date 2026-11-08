Future<T> withLocalProfileBootstrapLock<T>(Future<T> Function() action) =>
    action();
