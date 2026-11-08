const windowCapabilityEnvironmentKeys = {
  'ATERMIUS_TERMINAL_WINDOW_CAPABILITY',
  'ATERMIUS_DESKTOP_WINDOW_CAPABILITY',
  'ATERMIUS_FILE_WINDOW_CAPABILITY',
};
Map<String, String> windowLaunchEnvironment(
  Map<String, String> inherited, {
  Map<String, String> capability = const {},
}) => {
  for (final entry in inherited.entries)
    if (!windowCapabilityEnvironmentKeys.contains(entry.key.toUpperCase()))
      entry.key: entry.value,
  ...capability,
};
