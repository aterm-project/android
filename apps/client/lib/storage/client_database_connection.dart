import 'package:drift/drift.dart';

import 'client_database_connection_native.dart'
    if (dart.library.js_interop) 'client_database_connection_web.dart'
    as platform;

Future<DatabaseConnection> openClientDatabaseConnection({
  required String name,
}) => platform.openClientDatabaseConnection(name: name);
