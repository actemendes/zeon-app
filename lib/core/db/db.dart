import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:hiddify/core/db/converters/duration_converter.dart';
import 'package:hiddify/core/db/db.steps.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/custom_loggers.dart';

part 'db.g.dart';

@DriftDatabase(
  tables: [
    ProfileEntries,
    AppProxyEntries,
    RemoteNotificationEntries,
    NotificationReceiptEntries,
    NotificationSyncStateEntries,
  ],
)
class Db extends _$Db with InfraLogger {
  Db([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 6;

  static QueryExecutor _openConnection() {
    return LazyDatabase(
      () => driftDatabase(
        name: "db",
        native: const DriftNativeOptions(databaseDirectory: AppDirectories.getDatabaseDirectory),
        web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
      ),
    );
  }

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: stepByStep(
        from1To2: (m, schema) async {
          await m.alterTable(
            TableMigration(
              schema.profileEntries,
              columnTransformer: {schema.profileEntries.type: const Constant<String>("remote")},
              newColumns: [schema.profileEntries.type],
            ),
          );
        },
        from2To3: (m, schema) async {
          await m.createTable(schema.geoAssetEntries);
        },
        from3To4: (m, schema) async {
          final testUrlExists = await _columnExists(
            schema.profileEntries.actualTableName,
            schema.profileEntries.testUrl.name,
          );
          if (!testUrlExists) {
            await m.addColumn(schema.profileEntries, schema.profileEntries.testUrl);
          }
        },
        from4To5: (m, schema) async {
          await m.deleteTable('geo_asset_entries');
          await m.renameColumn(schema.profileEntries, 'test_url', schema.profileEntries.profileOverride);

          final userOverrideExists = await _columnExists(
            schema.profileEntries.actualTableName,
            schema.profileEntries.userOverride.name,
          );
          if (!userOverrideExists) {
            await m.addColumn(schema.profileEntries, schema.profileEntries.userOverride);
          }

          final populatedHeadersExists = await _columnExists(
            schema.profileEntries.actualTableName,
            schema.profileEntries.populatedHeaders.name,
          );
          if (!populatedHeadersExists) {
            await m.addColumn(schema.profileEntries, schema.profileEntries.populatedHeaders);
          }

          await m.createTable(schema.appProxyEntries);
        },
        from5To6: (m, schema) async {
          await m.createTable(remoteNotificationEntries);
          await m.createTable(notificationReceiptEntries);
          await m.createTable(notificationSyncStateEntries);
        },
      ),
    );
  }

  Future<bool> _columnExists(String table, String column) async {
    final result = await customSelect('PRAGMA table_info($table);').get();
    return result.any((row) => row.data['name'] == column);
  }
}

@DataClassName('ProfileEntry')
class ProfileEntries extends Table {
  TextColumn get id => text()();
  TextColumn get type => textEnum<ProfileType>()();
  BoolColumn get active => boolean()();
  TextColumn get name => text().withLength(min: 1)();
  TextColumn get url => text().nullable()();
  DateTimeColumn get lastUpdate => dateTime()();
  IntColumn get updateInterval => integer().nullable().map(DurationTypeConverter())();
  IntColumn get upload => integer().nullable()();
  IntColumn get download => integer().nullable()();
  IntColumn get total => integer().nullable()();
  DateTimeColumn get expire => dateTime().nullable()();
  TextColumn get webPageUrl => text().nullable()();
  TextColumn get supportUrl => text().nullable()();
  TextColumn get populatedHeaders => text().nullable()();
  TextColumn get profileOverride => text().nullable()();
  TextColumn get userOverride => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AppProxyEntry')
class AppProxyEntries extends Table {
  TextColumn get mode => textEnum<AppProxyMode>()();
  TextColumn get pkgName => text()();
  IntColumn get flags => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {mode, pkgName};
}

@DataClassName('StoredNotificationEntry')
class RemoteNotificationEntries extends Table {
  TextColumn get id => text()();
  TextColumn get category => text()();
  TextColumn get priority => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get actionUrl => text().nullable()();
  DateTimeColumn get publishedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get displayedAt => dateTime().nullable()();
  DateTimeColumn get openedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NotificationReceiptEntry')
class NotificationReceiptEntries extends Table {
  IntColumn get localId => integer().autoIncrement()();
  TextColumn get notificationId => text()();
  TextColumn get event => text()();
  DateTimeColumn get occurredAt => dateTime()();
  TextColumn get errorCode => text().nullable()();
}

@DataClassName('NotificationSyncStateEntry')
class NotificationSyncStateEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}
