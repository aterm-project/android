import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

Future<DatabaseConnection> openClientDatabaseConnection({
  required String name,
}) async => driftDatabase(name: name);
