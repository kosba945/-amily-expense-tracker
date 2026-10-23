import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await FinanceDatabase.open();
  final repository = FinanceRepository(database);
  final authRepository = AuthRepository(database);
  LocalUser? user;
  try {
    user = await authRepository.restoreSession();
  } catch (_) {
    user = null;
  }
  final hasAccount = user != null || await authRepository.hasAccount();
  runApp(
    MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => FinanceCubit(repository)..load(DateTime.now()),
        ),
        BlocProvider(
          create: (_) =>
              AuthCubit(authRepository, user: user, hasAccount: hasAccount),
        ),
      ],
      child: ExpenseApp(hasAccount: hasAccount),
    ),
  );
}

int? parsePiastres(String input) {
  final normalized = input
      .trim()
      .replaceAll('٫', '.')
      .replaceAll('،', '.')
      .replaceAll('٠', '0')
      .replaceAll('١', '1')
      .replaceAll('٢', '2')
      .replaceAll('٣', '3')
      .replaceAll('٤', '4')
      .replaceAll('٥', '5')
      .replaceAll('٦', '6')
      .replaceAll('٧', '7')
      .replaceAll('٨', '8')
      .replaceAll('٩', '9')
      .replaceAll('۰', '0')
      .replaceAll('۱', '1')
      .replaceAll('۲', '2')
      .replaceAll('۳', '3')
      .replaceAll('۴', '4')
      .replaceAll('۵', '5')
      .replaceAll('۶', '6')
      .replaceAll('۷', '7')
      .replaceAll('۸', '8')
      .replaceAll('۹', '9');
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(normalized);
  if (match == null) return null;
  final pounds = int.tryParse(match.group(1)!);
  if (pounds == null || pounds > 90000000000000) return null;
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  return pounds * 100 + (fraction.isEmpty ? 0 : int.parse(fraction));
}

class FinanceDatabase {
  FinanceDatabase._(this.db);
  final Database db;
  static const categories = <String>[
    'أكل وشرب',
    'سوبرماركت ومصاريف منزلية',
    'فواتير - كهرباء / مياه / غاز / نت',
    'صيانات',
    'بنزين ومواصلات',
    'دواء ودكاترة',
    'خروجات وفسح',
    'لبس',
    'مصاريف أبناء وتحويلات ودراسة',
    'تبرعات',
    'أخرى',
  ];
  static const colors = <String>[
    '#E76F51',
    '#2A9D8F',
    '#457B9D',
    '#E9C46A',
    '#F4A261',
    '#9B5DE5',
    '#F15BB5',
    '#00BBF9',
    '#80B918',
    '#6C757D',
    '#495057',
  ];
  static Future<FinanceDatabase> open({String? databasePath}) async {
    final resolvedPath =
        databasePath ??
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'family_expenses.db',
        );
    final db = await openDatabase(
      resolvedPath,
      version: 3,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, iconCode INTEGER NOT NULL, colorHex TEXT NOT NULL, isSystem INTEGER NOT NULL, isActive INTEGER NOT NULL DEFAULT 1, createdAt TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE wallets(id INTEGER PRIMARY KEY AUTOINCREMENT, monthYear TEXT NOT NULL UNIQUE, initialIncome INTEGER NOT NULL CHECK(initialIncome>=0), createdAt TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE transactions(id TEXT PRIMARY KEY, monthYear TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN (\'expense\',\'extra_income\',\'borrow\',\'repay_debt\')), amount INTEGER NOT NULL CHECK(amount>0), categoryId INTEGER, notes TEXT NOT NULL, transactionDate TEXT NOT NULL, createdAt TEXT NOT NULL, deletedAt TEXT, operationId TEXT UNIQUE, FOREIGN KEY(categoryId) REFERENCES categories(id))',
        );
        await db.execute(
          'CREATE INDEX idx_tx_month ON transactions(monthYear, deletedAt, transactionDate)',
        );
        await db.execute(
          'CREATE TABLE debts(id TEXT PRIMARY KEY, borrowTransactionId TEXT NOT NULL UNIQUE, originalAmount INTEGER NOT NULL, FOREIGN KEY(borrowTransactionId) REFERENCES transactions(id))',
        );
        await db.execute(
          'CREATE TABLE repayments(id TEXT PRIMARY KEY, repaymentTransactionId TEXT NOT NULL, debtId TEXT NOT NULL, allocatedAmount INTEGER NOT NULL, FOREIGN KEY(repaymentTransactionId) REFERENCES transactions(id), FOREIGN KEY(debtId) REFERENCES debts(id))',
        );
        await db.execute(
          'CREATE TABLE audit(id TEXT PRIMARY KEY, actionType TEXT NOT NULL, transactionId TEXT NOT NULL, beforeSnapshot TEXT, afterSnapshot TEXT, createdAt TEXT NOT NULL, undoneAt TEXT)',
        );
        await db.execute(
          'CREATE TABLE users(id TEXT PRIMARY KEY, name TEXT NOT NULL, username TEXT NOT NULL UNIQUE COLLATE NOCASE, passwordHash TEXT NOT NULL, passwordSalt TEXT NOT NULL, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL)',
        );
        for (var i = 0; i < categories.length; i++) {
          await db.insert('categories', {
            'name': categories[i],
            'iconCode': Icons.category.codePoint,
            'colorHex': colors[i],
            'isSystem': 1,
            'createdAt': DateTime.now().toIso8601String(),
          });
        }
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE transactions ADD COLUMN operationId TEXT',
          );
          await db.execute(
            'CREATE UNIQUE INDEX idx_transactions_operation_id ON transactions(operationId)',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'CREATE TABLE users(id TEXT PRIMARY KEY, name TEXT NOT NULL, username TEXT NOT NULL UNIQUE COLLATE NOCASE, passwordHash TEXT NOT NULL, passwordSalt TEXT NOT NULL, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL)',
          );
        }
      },
    );
    return FinanceDatabase._(db);
  }
}

class LocalUser {
  const LocalUser({
    required this.id,
    required this.name,
    required this.username,
  });
  final String id;
  final String name;
  final String username;
}

abstract interface class SessionStore {
  Future<String?> readUserId();
  Future<void> saveUserId(String id);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();
  static const _key = 'family_expenses_session_user';
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> readUserId() => _storage.read(key: _key);
  @override
  Future<void> saveUserId(String id) => _storage.write(key: _key, value: id);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

List<int> _pbkdf2(String password, List<int> salt) {
  const iterations = 120000;
  final hmac = crypto.Hmac(crypto.sha256, utf8.encode(password));
  final block = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
  block[block.length - 1] = 1;
  var u = hmac.convert(block).bytes;
  final derived = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < derived.length; j++) {
      derived[j] ^= u[j];
    }
  }
  return derived;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
List<int> _unhex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

class AuthRepository {
  AuthRepository(this.database, {SessionStore? sessionStore})
    : session = sessionStore ?? const SecureSessionStore();
  final FinanceDatabase database;
  final SessionStore session;

  Future<bool> hasAccount() async =>
      (Sqflite.firstIntValue(
            await database.db.rawQuery('SELECT COUNT(*) FROM users'),
          ) ??
          0) >
      0;

  Future<LocalUser> register({
    required String name,
    required String username,
    required String password,
  }) async {
    final cleanName = name.trim();
    final cleanUsername = username.trim();
    if (cleanName.isEmpty || cleanUsername.length < 3 || password.length < 8) {
      throw ArgumentError(
        'أدخل الاسم واسم مستخدم من 3 أحرف وكلمة مرور من 8 أحرف على الأقل',
      );
    }
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final hash = await Isolate.run(() => _pbkdf2(password, salt));
    final user = LocalUser(
      id: const Uuid().v4(),
      name: cleanName,
      username: cleanUsername,
    );
    await database.db.transaction((txn) async {
      final count =
          Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COUNT(*) FROM users'),
          ) ??
          0;
      if (count > 0) {
        throw StateError('تم إنشاء حساب محلي بالفعل على هذا الجهاز');
      }
      await txn.insert('users', {
        'id': user.id,
        'name': user.name,
        'username': user.username,
        'passwordHash': _hex(hash),
        'passwordSalt': _hex(salt),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
    });
    await session.saveUserId(user.id);
    return user;
  }

  Future<LocalUser> login({
    required String username,
    required String password,
  }) async {
    final rows = await database.db.query(
      'users',
      where: 'username=?',
      whereArgs: [username.trim()],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError('اسم المستخدم أو كلمة المرور غير صحيحة');
    }
    final row = rows.single;
    final salt = _unhex(row['passwordSalt'] as String);
    final candidate = await Isolate.run(() => _pbkdf2(password, salt));
    final expected = _unhex(row['passwordHash'] as String);
    var difference = candidate.length ^ expected.length;
    for (var i = 0; i < candidate.length && i < expected.length; i++) {
      difference |= candidate[i] ^ expected[i];
    }
    if (difference != 0) {
      throw ArgumentError('اسم المستخدم أو كلمة المرور غير صحيحة');
    }
    await session.saveUserId(row['id'] as String);
    return LocalUser(
      id: row['id'] as String,
      name: row['name'] as String,
      username: row['username'] as String,
    );
  }

  Future<LocalUser?> restoreSession() async {
    final id = await session.readUserId();
    if (id == null) return null;
    final rows = await database.db.query(
      'users',
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      await session.clear();
      return null;
    }
    final row = rows.single;
    return LocalUser(
      id: id,
      name: row['name'] as String,
      username: row['username'] as String,
    );
  }

  Future<void> logout() => session.clear();
}

class AuthState {
  const AuthState({
    this.user,
    this.loading = false,
    this.error,
    this.hasAccount = false,
  });
  final LocalUser? user;
  final bool loading;
  final String? error;
  final bool hasAccount;
}

class AuthCubit extends Cubit<AuthState> {
  AuthCubit(this.repository, {LocalUser? user, bool hasAccount = false})
    : super(AuthState(user: user, hasAccount: hasAccount || user != null));
  final AuthRepository repository;
  Future<void> register({
    required String name,
    required String username,
    required String password,
  }) async {
    final hasAccount = state.hasAccount;
    emit(AuthState(loading: true, hasAccount: hasAccount));
    try {
      emit(
        AuthState(
          user: await repository.register(
            name: name,
            username: username,
            password: password,
          ),
          hasAccount: true,
        ),
      );
    } catch (error) {
      emit(AuthState(error: error.toString(), hasAccount: hasAccount));
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final hasAccount = state.hasAccount;
    emit(AuthState(loading: true, hasAccount: hasAccount));
    try {
      emit(
        AuthState(
          user: await repository.login(username: username, password: password),
          hasAccount: true,
        ),
      );
    } catch (error) {
      emit(AuthState(error: error.toString(), hasAccount: hasAccount));
    }
  }

  Future<void> logout() async {
    await repository.logout();
    emit(AuthState(hasAccount: state.hasAccount));
  }
}

class MonthSummary {
  const MonthSummary({
    required this.income,
    required this.extra,
    required this.borrowed,
    required this.expenses,
    required this.repaid,
    required this.balance,
    required this.debt,
  });
  final int income, extra, borrowed, expenses, repaid, balance, debt;
}

class FinanceRepository {
  FinanceRepository(this.db);
  final FinanceDatabase db;
  Database get sql => db.db;
  String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  Future<void> ensureMonth(DateTime date, int? income) async {
    final k = key(date);
    if ((await sql.query(
          'wallets',
          where: 'monthYear=?',
          whereArgs: [k],
        )).isEmpty &&
        income != null) {
      await sql.insert('wallets', {
        'monthYear': k,
        'initialIncome': income,
        'createdAt': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<List<Map<String, Object?>>> transactions(
    DateTime date,
  ) async => sql.rawQuery(
    'SELECT t.*, c.name categoryName FROM transactions t LEFT JOIN categories c ON c.id=t.categoryId WHERE t.monthYear=? AND t.deletedAt IS NULL ORDER BY t.transactionDate DESC, t.createdAt DESC',
    [key(date)],
  );
  Future<List<Map<String, Object?>>> categories() =>
      sql.query('categories', where: 'isActive=1', orderBy: 'id');
  Future<List<Map<String, Object?>>> categorySpending(
    DateTime date,
  ) => sql.rawQuery(
    "SELECT c.name, c.colorHex, SUM(t.amount) total FROM transactions t JOIN categories c ON c.id=t.categoryId WHERE t.monthYear=? AND t.type='expense' AND t.deletedAt IS NULL GROUP BY c.id ORDER BY total DESC",
    [key(date)],
  );
  Future<MonthSummary> summary(DateTime date) async {
    final k = key(date);
    final wallet = await sql.query(
      'wallets',
      where: 'monthYear=?',
      whereArgs: [k],
    );
    final rows = await sql.rawQuery(
      "SELECT type, COALESCE(SUM(amount),0) total FROM transactions WHERE monthYear=? AND deletedAt IS NULL GROUP BY type",
      [k],
    );
    int sum(String type) => rows
        .where((r) => r['type'] == type)
        .fold<int>(0, (a, r) => a + (r['total'] as int));
    final debtRows = await sql.rawQuery(
      'SELECT (SELECT COALESCE(SUM(originalAmount),0) FROM debts d JOIN transactions b ON b.id=d.borrowTransactionId WHERE b.deletedAt IS NULL) - (SELECT COALESCE(SUM(r.allocatedAmount),0) FROM repayments r JOIN transactions t ON t.id=r.repaymentTransactionId WHERE t.deletedAt IS NULL) AS outstanding',
    );
    final income = wallet.isEmpty ? 0 : wallet.first['initialIncome'] as int;
    final extra = sum('extra_income'),
        borrowed = sum('borrow'),
        expenses = sum('expense'),
        repaid = sum('repay_debt');
    return MonthSummary(
      income: income,
      extra: extra,
      borrowed: borrowed,
      expenses: expenses,
      repaid: repaid,
      balance: income + extra + borrowed - expenses - repaid,
      debt: debtRows.first['outstanding'] as int,
    );
  }

  Future<void> setIncome(DateTime date, int amount) async {
    if (amount < 0) throw ArgumentError('لا يمكن أن يكون الدخل الأساسي سالباً');
    final k = key(date);
    await sql.insert('wallets', {
      'monthYear': k,
      'initialIncome': amount,
      'createdAt': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> add({
    required DateTime month,
    required String type,
    required int amount,
    required String notes,
    int? categoryId,
    String? operationId,
    DateTime? transactionDate,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('يجب أن يكون المبلغ أكبر من صفر');
    }
    if (type == 'expense' && (categoryId == null || notes.trim().isEmpty)) {
      throw ArgumentError('أدخل الفئة وتفاصيل الصرف');
    }
    if (type == 'repay_debt' && notes.trim().isEmpty) {
      throw ArgumentError('أدخل تفاصيل السداد');
    }
    await sql.transaction((txn) async {
      final id = const Uuid().v4();
      final now = DateTime.now().toIso8601String();
      final effectiveDate =
          transactionDate ??
          (key(DateTime.now()) == key(month)
              ? DateTime.now()
              : DateTime(month.year, month.month, 1));
      if (key(effectiveDate) != key(month)) {
        throw ArgumentError('تاريخ المعاملة يجب أن يكون ضمن الشهر المحدد');
      }
      await txn.insert('transactions', {
        'id': id,
        'monthYear': key(month),
        'type': type,
        'amount': amount,
        'notes': notes.trim(),
        'transactionDate': effectiveDate.toIso8601String(),
        'createdAt': now,
        'operationId': operationId,
      });
      if (type == 'borrow') {
        await txn.insert('debts', {
          'id': const Uuid().v4(),
          'borrowTransactionId': id,
          'originalAmount': amount,
        });
      }
      await _recalculateDebtAllocations(txn);
      final after = (await txn.query(
        'transactions',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      await txn.insert('audit', {
        'id': const Uuid().v4(),
        'actionType': 'create',
        'transactionId': id,
        'afterSnapshot': jsonEncode(after),
        'createdAt': now,
      });
    });
  }

  Future<void> delete(String id) async => sql.transaction((txn) async {
    final row = (await txn.query(
      'transactions',
      where: 'id=? AND deletedAt IS NULL',
      whereArgs: [id],
    )).first;
    if (row['type'] == 'borrow') {
      final debt = (await txn.query(
        'debts',
        where: 'borrowTransactionId=?',
        whereArgs: [id],
      ));
      if (debt.isNotEmpty) {
        final uses = await txn.rawQuery(
          'SELECT COUNT(*) n FROM repayments WHERE debtId=? AND EXISTS(SELECT 1 FROM transactions t WHERE t.id=repayments.repaymentTransactionId AND t.deletedAt IS NULL)',
          [debt.first['id']],
        );
        if (uses.first['n'] != 0) {
          throw ArgumentError('لا يمكن حذف استلاف له مبالغ مسددة نشطة');
        }
      }
    }
    await txn.update(
      'transactions',
      {'deletedAt': DateTime.now().toIso8601String()},
      where: 'id=?',
      whereArgs: [id],
    );
    await _recalculateDebtAllocations(txn);
    final after = (await txn.query(
      'transactions',
      where: 'id=?',
      whereArgs: [id],
    )).single;
    await txn.insert('audit', {
      'id': const Uuid().v4(),
      'actionType': 'delete',
      'transactionId': id,
      'beforeSnapshot': jsonEncode(row),
      'afterSnapshot': jsonEncode(after),
      'createdAt': DateTime.now().toIso8601String(),
    });
  });

  Future<void> edit({
    required String id,
    required String type,
    required int amount,
    required String notes,
    int? categoryId,
    DateTime? date,
  }) async {
    if (amount <= 0) throw ArgumentError('يجب أن يكون المبلغ أكبر من صفر');
    if (type == 'expense' && (categoryId == null || notes.trim().isEmpty)) {
      throw ArgumentError('أدخل الفئة وتفاصيل الصرف');
    }
    if (type == 'repay_debt' && notes.trim().isEmpty) {
      throw ArgumentError('أدخل تفاصيل السداد');
    }
    await sql.transaction((txn) async {
      final before = (await txn.query(
        'transactions',
        where: 'id=? AND deletedAt IS NULL',
        whereArgs: [id],
      )).single;
      if (before['type'] != type) {
        throw ArgumentError('لا يمكن تغيير نوع المعاملة أثناء التعديل');
      }
      await txn.update(
        'transactions',
        {
          'amount': amount,
          'notes': notes.trim(),
          'categoryId': type == 'expense' ? categoryId : null,
          if (date != null) 'monthYear': key(date),
          if (date != null) 'transactionDate': date.toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      if (type == 'borrow') {
        await txn.update(
          'debts',
          {'originalAmount': amount},
          where: 'borrowTransactionId=?',
          whereArgs: [id],
        );
      }
      await _recalculateDebtAllocations(txn);
      final after = (await txn.query(
        'transactions',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      await txn.insert('audit', {
        'id': const Uuid().v4(),
        'actionType': 'edit',
        'transactionId': id,
        'beforeSnapshot': jsonEncode(before),
        'afterSnapshot': jsonEncode(after),
        'createdAt': DateTime.now().toIso8601String(),
      });
    });
  }

  Future<void> undoLast() async {
    await sql.transaction((txn) async {
      final actions = await txn.query(
        'audit',
        where: 'undoneAt IS NULL',
        orderBy: 'createdAt DESC, rowid DESC',
        limit: 1,
      );
      if (actions.isEmpty) throw StateError('لا توجد عملية للتراجع عنها');
      final action = actions.single;
      final id = action['transactionId'] as String;
      final actionType = action['actionType'] as String;
      final beforeJson = action['beforeSnapshot'] as String?;
      final expected = Map<String, Object?>.from(
        jsonDecode(action['afterSnapshot'] as String) as Map,
      );
      final current = (await txn.query(
        'transactions',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (!expected.entries.every(
        (entry) => current[entry.key] == entry.value,
      )) {
        throw StateError('تعذر التراجع بسبب تعديل لاحق على المعاملة');
      }
      if (actionType == 'create') {
        await txn.update(
          'transactions',
          {'deletedAt': DateTime.now().toIso8601String()},
          where: 'id=?',
          whereArgs: [id],
        );
      } else if (beforeJson != null) {
        final before = Map<String, Object?>.from(jsonDecode(beforeJson) as Map);
        await txn.update(
          'transactions',
          before,
          where: 'id=?',
          whereArgs: [id],
        );
        if (before['type'] == 'borrow') {
          await txn.update(
            'debts',
            {'originalAmount': before['amount']},
            where: 'borrowTransactionId=?',
            whereArgs: [id],
          );
        }
      } else {
        throw StateError('سجل التراجع غير مكتمل');
      }
      await _recalculateDebtAllocations(txn);
      await txn.update(
        'audit',
        {'undoneAt': DateTime.now().toIso8601String()},
        where: 'id=?',
        whereArgs: [action['id']],
      );
    });
  }

  Future<void> _recalculateDebtAllocations(DatabaseExecutor txn) async {
    final rows = await txn.rawQuery(
      "SELECT t.id, t.type, t.amount, t.transactionDate, t.createdAt, d.id debtId FROM transactions t LEFT JOIN debts d ON d.borrowTransactionId=t.id WHERE t.deletedAt IS NULL AND t.type IN ('borrow','repay_debt') ORDER BY t.transactionDate ASC, t.createdAt ASC, CASE t.type WHEN 'borrow' THEN 0 ELSE 1 END ASC",
    );
    final outstanding = <String, int>{};
    await txn.delete('repayments');
    for (final row in rows) {
      if (row['type'] == 'borrow') {
        final debtId = row['debtId'] as String?;
        if (debtId == null) throw StateError('سجل الاستلاف غير مكتمل');
        outstanding[debtId] = row['amount'] as int;
      } else {
        var remaining = row['amount'] as int;
        for (final debtId in outstanding.keys.toList()) {
          if (remaining == 0) break;
          final available = outstanding[debtId]!;
          final allocated = available < remaining ? available : remaining;
          if (allocated > 0) {
            await txn.insert('repayments', {
              'id': const Uuid().v4(),
              'repaymentTransactionId': row['id'],
              'debtId': debtId,
              'allocatedAmount': allocated,
            });
            outstanding[debtId] = available - allocated;
            remaining -= allocated;
          }
        }
        if (remaining > 0) {
          throw ArgumentError(
            'قيمة السداد تتجاوز الدين المتاح في تاريخ العملية',
          );
        }
      }
    }
  }

  Future<List<Map<String, Object?>>> history() =>
      sql.query('wallets', orderBy: 'monthYear DESC');

  Future<Uint8List> excelWorkbook(DateTime month) async {
    final workbook = Excel.createExcel();
    workbook.rename('Sheet1', 'ملخص الشهر');
    final summarySheet = workbook['ملخص الشهر'];
    final detailSheet = workbook['سجل العمليات بالتفصيل'];
    final totals = await summary(month);
    summarySheet.appendRow([TextCellValue('الشهر'), TextCellValue(key(month))]);
    summarySheet.appendRow([
      TextCellValue('الدخل الشهري الأساسي (قرش)'),
      IntCellValue(totals.income),
    ]);
    summarySheet.appendRow([
      TextCellValue('الدخل الإضافي (قرش)'),
      IntCellValue(totals.extra),
    ]);
    summarySheet.appendRow([
      TextCellValue('الاستلاف (قرش)'),
      IntCellValue(totals.borrowed),
    ]);
    summarySheet.appendRow([
      TextCellValue('المصروفات (قرش)'),
      IntCellValue(totals.expenses),
    ]);
    summarySheet.appendRow([
      TextCellValue('سداد الديون (قرش)'),
      IntCellValue(totals.repaid),
    ]);
    summarySheet.appendRow([
      TextCellValue('الرصيد المتاح (قرش)'),
      IntCellValue(totals.balance),
    ]);
    summarySheet.appendRow([
      TextCellValue('إجمالي الدين القائم (قرش)'),
      IntCellValue(totals.debt),
    ]);
    summarySheet.appendRow([TextCellValue('إجمالي المصروف حسب الفئة'), null]);
    final byCategory = await sql.rawQuery(
      "SELECT COALESCE(c.name,'غير مصنف') name, SUM(t.amount) total FROM transactions t LEFT JOIN categories c ON c.id=t.categoryId WHERE t.monthYear=? AND t.type='expense' AND t.deletedAt IS NULL GROUP BY c.id ORDER BY total DESC",
      [key(month)],
    );
    for (final row in byCategory) {
      summarySheet.appendRow([
        TextCellValue(row['name'] as String),
        IntCellValue(row['total'] as int),
      ]);
    }
    detailSheet.appendRow([
      TextCellValue('المعرف'),
      TextCellValue('النوع'),
      TextCellValue('التاريخ'),
      TextCellValue('الفئة'),
      TextCellValue('الوصف'),
      TextCellValue('المبلغ (قرش)'),
    ]);
    final rows = await transactions(month);
    for (final row in rows) {
      detailSheet.appendRow([
        TextCellValue(row['id'] as String),
        TextCellValue(row['type'] as String),
        TextCellValue(row['transactionDate'] as String),
        TextCellValue((row['categoryName'] as String?) ?? ''),
        TextCellValue(row['notes'] as String),
        IntCellValue(row['amount'] as int),
      ]);
    }
    final bytes = workbook.save();
    if (bytes == null) throw StateError('تعذر إنشاء ملف Excel');
    return Uint8List.fromList(bytes);
  }

  Future<String> backupJson() async {
    return sql.transaction((txn) async {
      final data = <String, Object?>{
        'format': 'family_expenses_backup',
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'tables': <String, Object?>{
          'categories': await txn.query('categories', orderBy: 'id'),
          'wallets': await txn.query('wallets', orderBy: 'monthYear'),
          'transactions': await txn.query('transactions', orderBy: 'createdAt'),
          'debts': await txn.query('debts', orderBy: 'rowid'),
          'repayments': await txn.query('repayments', orderBy: 'rowid'),
          'audit': await txn.query('audit', orderBy: 'createdAt'),
        },
      };
      return const JsonEncoder.withIndent('  ').convert(data);
    });
  }

  Future<void> restoreBackup(String source) async {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'family_expenses_backup' ||
        decoded['version'] != 1 ||
        decoded['tables'] is! Map<String, dynamic>) {
      throw const FormatException(
        'ملف النسخة الاحتياطية غير صالح أو غير مدعوم',
      );
    }
    final tables = decoded['tables'] as Map<String, dynamic>;
    const requiredTables = [
      'categories',
      'wallets',
      'transactions',
      'debts',
      'repayments',
      'audit',
    ];
    for (final table in requiredTables) {
      if (tables[table] is! List) {
        throw const FormatException('بيانات النسخة الاحتياطية غير مكتملة');
      }
    }
    await sql.transaction((txn) async {
      for (final table in [
        'wallets',
        'transactions',
        'debts',
        'repayments',
        'audit',
      ]) {
        final count =
            Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM $table'),
            ) ??
            0;
        if (count != 0) {
          throw StateError(
            'لا يمكن الاستعادة فوق بيانات موجودة؛ صدّر نسخة حالية أولاً',
          );
        }
      }
      await txn.delete('categories');
      for (final category in tables['categories'] as List) {
        await txn.insert(
          'categories',
          Map<String, Object?>.from(category as Map),
        );
      }
      for (final table in [
        'wallets',
        'transactions',
        'debts',
        'repayments',
        'audit',
      ]) {
        for (final row in tables[table] as List) {
          await txn.insert(table, Map<String, Object?>.from(row as Map));
        }
      }
      final fkProblems = await txn.rawQuery('PRAGMA foreign_key_check');
      if (fkProblems.isNotEmpty) {
        throw const FormatException(
          'العلاقات المرجعية في النسخة الاحتياطية غير سليمة',
        );
      }
      final archivedAllocations = await txn.rawQuery(
        'SELECT repaymentTransactionId, debtId, SUM(allocatedAmount) amount FROM repayments GROUP BY repaymentTransactionId, debtId ORDER BY repaymentTransactionId, debtId',
      );
      await _recalculateDebtAllocations(txn);
      final recalculatedAllocations = await txn.rawQuery(
        'SELECT repaymentTransactionId, debtId, SUM(allocatedAmount) amount FROM repayments GROUP BY repaymentTransactionId, debtId ORDER BY repaymentTransactionId, debtId',
      );
      if (jsonEncode(archivedAllocations) !=
          jsonEncode(recalculatedAllocations)) {
        throw const FormatException('تخصيصات الديون لا تطابق سجل العمليات');
      }
      final invalidRepayments = await txn.rawQuery(
        "SELECT t.id FROM transactions t LEFT JOIN repayments r ON r.repaymentTransactionId=t.id WHERE t.type='repay_debt' AND t.deletedAt IS NULL GROUP BY t.id,t.amount HAVING COALESCE(SUM(r.allocatedAmount),0) != t.amount",
      );
      if (invalidRepayments.isNotEmpty) {
        throw const FormatException(
          'تخصيصات سداد الديون في النسخة الاحتياطية غير متوازنة',
        );
      }
    });
  }
}

class FinanceState {
  const FinanceState({
    this.date,
    this.summary,
    this.transactions = const [],
    this.categories = const [],
    this.categoryTotals = const [],
    this.months = const [],
    this.loading = true,
    this.error,
  });
  final DateTime? date;
  final MonthSummary? summary;
  final List<Map<String, Object?>> transactions,
      categories,
      months,
      categoryTotals;
  final bool loading;
  final String? error;
}

class FinanceCubit extends Cubit<FinanceState> {
  FinanceCubit(this.repo) : super(const FinanceState());
  final FinanceRepository repo;
  Future<void> load(DateTime date, {int? initialIncome}) async {
    emit(FinanceState(date: date, loading: true));
    try {
      await repo.ensureMonth(date, initialIncome);
      final result = await Future.wait([
        repo.transactions(date),
        repo.categories(),
        repo.categorySpending(date),
        repo.history(),
        repo.summary(date),
      ]);
      emit(
        FinanceState(
          date: date,
          transactions: result[0] as List<Map<String, Object?>>,
          categories: result[1] as List<Map<String, Object?>>,
          categoryTotals: result[2] as List<Map<String, Object?>>,
          months: result[3] as List<Map<String, Object?>>,
          summary: result[4] as MonthSummary,
          loading: false,
        ),
      );
    } catch (e) {
      emit(FinanceState(date: date, loading: false, error: e.toString()));
    }
  }

  Future<void> refresh() => load(state.date ?? DateTime.now());
}

class ExpenseApp extends StatelessWidget {
  const ExpenseApp({super.key, required this.hasAccount});
  final bool hasAccount;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'مصروفات الأسرة',
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087f75)),
      useMaterial3: true,
      fontFamily: 'Arial',
      scaffoldBackgroundColor: const Color(0xfff5f7f6),
    ),
    home: AuthGate(hasAccount: hasAccount),
  );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.hasAccount});
  final bool hasAccount;
  @override
  Widget build(BuildContext context) => BlocBuilder<AuthCubit, AuthState>(
    builder: (context, state) => state.user == null
        ? AuthScreen(hasAccount: hasAccount || state.hasAccount)
        : const Dashboard(),
  );
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.hasAccount});
  final bool hasAccount;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late bool _registering = !widget.hasAccount;
  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: ui.TextDirection.rtl,
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: BlocBuilder<AuthCubit, AuthState>(
                builder: (context, state) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _form,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 48,
                            color: Color(0xff087f75),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _registering
                                ? 'إنشاء الحساب المحلي'
                                : 'تسجيل الدخول',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (_registering)
                            TextFormField(
                              controller: _name,
                              decoration: const InputDecoration(
                                labelText: 'الاسم',
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'أدخل الاسم'
                                  : null,
                            ),
                          TextFormField(
                            controller: _username,
                            decoration: const InputDecoration(
                              labelText: 'اسم المستخدم',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (v) => (v == null || v.trim().length < 3)
                                ? 'اسم المستخدم يجب أن يكون 3 أحرف على الأقل'
                                : null,
                          ),
                          TextFormField(
                            controller: _password,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'كلمة المرور',
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                            validator: (v) => (v == null || v.length < 8)
                                ? 'كلمة المرور يجب أن تكون 8 أحرف على الأقل'
                                : null,
                          ),
                          if (state.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                state.error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: state.loading
                                  ? null
                                  : () async {
                                      if (!_form.currentState!.validate()) {
                                        return;
                                      }
                                      final auth = context.read<AuthCubit>();
                                      if (_registering) {
                                        await auth.register(
                                          name: _name.text,
                                          username: _username.text,
                                          password: _password.text,
                                        );
                                      } else {
                                        await auth.login(
                                          username: _username.text,
                                          password: _password.text,
                                        );
                                      }
                                    },
                              child: state.loading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      _registering ? 'إنشاء الحساب' : 'دخول',
                                    ),
                            ),
                          ),
                          if (!widget.hasAccount)
                            TextButton(
                              onPressed: state.loading
                                  ? null
                                  : () => setState(
                                      () => _registering = !_registering,
                                    ),
                              child: Text(
                                _registering
                                    ? 'لدي حساب بالفعل'
                                    : 'إنشاء حساب محلي',
                              ),
                            ),
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'تُحفظ بياناتك على هذا الجهاز فقط',
                              style: TextStyle(color: Colors.black54),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({super.key});
  String money(int piastres) =>
      '${NumberFormat('#,##0.00', 'ar').format(piastres / 100)} ج.م';
  @override
  Widget build(BuildContext context) => BlocBuilder<FinanceCubit, FinanceState>(
    builder: (context, s) {
      if (s.loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final c = context.read<FinanceCubit>();
      final sum = s.summary;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (sum != null &&
            sum.income == 0 &&
            s.transactions.isEmpty &&
            s.months
                .where((m) => m['monthYear'] == c.repo.key(s.date!))
                .isEmpty) {
          _incomeDialog(context, s.date!);
        }
      });
      return Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: const Text(
              'مصروفات الأسرة',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              IconButton(
                tooltip: 'الشهر السابق',
                icon: const Icon(Icons.chevron_right),
                onPressed: () =>
                    c.load(DateTime(s.date!.year, s.date!.month - 1)),
              ),
              Center(child: Text(DateFormat('MM-yyyy', 'ar').format(s.date!))),
              IconButton(
                tooltip: 'الشهر التالي',
                icon: const Icon(Icons.chevron_left),
                onPressed: () =>
                    c.load(DateTime(s.date!.year, s.date!.month + 1)),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'income') unawaited(_incomeDialog(context, s.date!));
                  if (v == 'history') unawaited(_history(context, s.months));
                  if (v == 'excel') {
                    unawaited(_exportExcel(context, c, s.date!));
                  }
                  if (v == 'backup') unawaited(_exportBackup(context, c));
                  if (v == 'restore') {
                    unawaited(_restoreBackup(context, c, s.date!));
                  }
                  if (v == 'logout') {
                    unawaited(context.read<AuthCubit>().logout());
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'income',
                    child: Text('تعديل الدخل الأساسي'),
                  ),
                  PopupMenuItem(
                    value: 'history',
                    child: Text('الأرشيف الشهري'),
                  ),
                  PopupMenuItem(value: 'excel', child: Text('تصدير Excel')),
                  PopupMenuItem(value: 'backup', child: Text('نسخة احتياطية')),
                  PopupMenuItem(value: 'restore', child: Text('استعادة نسخة')),
                  PopupMenuItem(value: 'logout', child: Text('تسجيل الخروج')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addDialog(context, s),
            icon: const Icon(Icons.add),
            label: const Text('معاملة جديدة'),
          ),
          body: sum == null
              ? const Center(child: Text('لا توجد بيانات'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: const Color(0xff087f75),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'الرصيد المتاح',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              money(sum.balance),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 30,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 20,
                              runSpacing: 10,
                              children: [
                                _metric('الدخل الأساسي', sum.income),
                                _metric('دخل إضافي', sum.extra),
                                _metric('المصروفات', sum.expenses),
                                _metric('الاستلاف', sum.borrowed),
                                _metric('سداد الديون', sum.repaid),
                                _metric('الدين القائم', sum.debt),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (s.categoryTotals.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'توزيع المصروفات حسب الفئة',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                              SizedBox(
                                height: 220,
                                child: PieChart(
                                  PieChartData(
                                    sectionsSpace: 2,
                                    centerSpaceRadius: 34,
                                    sections: s.categoryTotals.map((row) {
                                      final color = Color(
                                        int.parse(
                                          'FF${(row['colorHex'] as String).replaceFirst('#', '')}',
                                          radix: 16,
                                        ),
                                      );
                                      return PieChartSectionData(
                                        value: (row['total'] as int).toDouble(),
                                        color: color,
                                        radius: 64,
                                        title: '',
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: s.categoryTotals.map((row) {
                                  final color = Color(
                                    int.parse(
                                      'FF${(row['colorHex'] as String).replaceFirst('#', '')}',
                                      radix: 16,
                                    ),
                                  );
                                  return Chip(
                                    avatar: CircleAvatar(
                                      backgroundColor: color,
                                      radius: 7,
                                    ),
                                    label: Text(
                                      '${row['name']} · ${money(row['total'] as int)}',
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'المعاملات',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (s.transactions.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Center(
                            child: Text('لا توجد معاملات لهذا الشهر'),
                          ),
                        ),
                      ),
                    ...s.transactions.map(
                      (t) => Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(_icon(t['type'] as String)),
                          ),
                          title: Text(
                            (t['type'] == 'expense'
                                    ? (t['categoryName'] ?? 'مصروف')
                                    : _typeName(t['type'] as String))
                                .toString(),
                          ),
                          subtitle: Text(
                            '${t['notes']} • ${DateFormat('dd/MM/yyyy', 'ar').format(DateTime.parse(t['transactionDate'] as String))}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                money(t['amount'] as int),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                tooltip: 'تعديل المعاملة',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => unawaited(
                                  _addDialog(context, s, existing: t),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (d) => AlertDialog(
                                      title: const Text('حذف المعاملة؟'),
                                      content: const Text(
                                        'سيتم أرشفتها وإعادة حساب الأرصدة.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('إلغاء'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text('حذف'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    try {
                                      await c.repo.delete(t['id'] as String);
                                      await c.refresh();
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                          ..hideCurrentSnackBar()
                                          ..showSnackBar(
                                            SnackBar(
                                              content: const Text(
                                                'تم حذف المعاملة',
                                              ),
                                              action: SnackBarAction(
                                                label: 'تراجع',
                                                onPressed: () async {
                                                  await c.repo.undoLast();
                                                  await c.refresh();
                                                },
                                              ),
                                            ),
                                          );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text(e.toString())),
                                        );
                                      }
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
  Widget _metric(String label, int value) => SizedBox(
    width: 135,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        Text(
          money(value),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
  IconData _icon(String t) => switch (t) {
    'expense' => Icons.shopping_bag_outlined,
    'extra_income' => Icons.add_circle_outline,
    'borrow' => Icons.call_received,
    'repay_debt' => Icons.payments_outlined,
    _ => Icons.receipt_long,
  };
  static String _typeName(String type) => switch (type) {
    'extra_income' => 'دخل إضافي',
    'borrow' => 'استلاف',
    'repay_debt' => 'سداد دين',
    _ => 'مصروف',
  };

  Future<void> _incomeDialog(BuildContext context, DateTime date) async {
    final controller = TextEditingController();
    final value = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('الدخل الشهري الأساسي'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'المبلغ بالجنيه',
            prefixIcon: Icon(Icons.account_balance_wallet),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              final v = _parse(controller.text);
              if (v == null || v < 0) {
                ScaffoldMessenger.of(d).showSnackBar(
                  const SnackBar(content: Text('أدخل مبلغاً صحيحاً')),
                );
                return;
              }
              Navigator.pop(d, v);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (value != null && context.mounted) {
      final cubit = context.read<FinanceCubit>();
      await cubit.repo.setIncome(date, value);
      if (context.mounted) await cubit.refresh();
    }
  }

  int? _parse(String value) => parsePiastres(value);

  Future<void> _addDialog(
    BuildContext context,
    FinanceState state, {
    Map<String, Object?>? existing,
  }) async {
    final form = GlobalKey<FormState>();
    final amount = TextEditingController(
      text: existing == null
          ? ''
          : ((existing['amount'] as int) / 100).toStringAsFixed(2),
    );
    final notes = TextEditingController(
      text: existing?['notes'] as String? ?? '',
    );
    String type = existing?['type'] as String? ?? 'expense';
    int? category = existing?['categoryId'] as int?;
    bool submitting = false;
    final operationId = const Uuid().v4();
    final cubit = context.read<FinanceCubit>();
    final monthStart = DateTime(state.date!.year, state.date!.month);
    final monthEnd = DateTime(state.date!.year, state.date!.month + 1, 0);
    final today = DateTime.now();
    DateTime transactionDate = existing == null
        ? (cubit.repo.key(today) == cubit.repo.key(state.date!)
              ? today
              : monthStart)
        : DateTime.parse(existing['transactionDate'] as String);
    if (transactionDate.isBefore(monthStart) ||
        transactionDate.isAfter(monthEnd)) {
      transactionDate = monthStart;
    }
    final parsedCategories = state.categories;
    final res = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(existing == null ? 'إضافة معاملة' : 'تعديل المعاملة'),
          content: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: 'نوع المعاملة',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'expense', child: Text('مصروف')),
                      DropdownMenuItem(
                        value: 'extra_income',
                        child: Text('دخل إضافي'),
                      ),
                      DropdownMenuItem(value: 'borrow', child: Text('استلاف')),
                      DropdownMenuItem(
                        value: 'repay_debt',
                        child: Text('سداد دين'),
                      ),
                    ],
                    onChanged: existing == null
                        ? (v) => setState(() => type = v!)
                        : null,
                  ),
                  if (type == 'expense')
                    DropdownButtonFormField<int>(
                      initialValue: category,
                      decoration: const InputDecoration(labelText: 'الفئة'),
                      items: parsedCategories
                          .map(
                            (x) => DropdownMenuItem(
                              value: x['id'] as int,
                              child: Text(x['name'] as String),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => category = v,
                      validator: (v) =>
                          type == 'expense' && v == null ? 'اختر الفئة' : null,
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: const Text('تاريخ المعاملة'),
                    subtitle: Text(
                      DateFormat('dd/MM/yyyy', 'ar').format(transactionDate),
                    ),
                    onTap: () async {
                      final selected = await showDatePicker(
                        context: d,
                        initialDate: transactionDate,
                        firstDate: monthStart,
                        lastDate: monthEnd,
                        locale: const Locale('ar'),
                      );
                      if (selected != null) {
                        setState(() => transactionDate = selected);
                      }
                    },
                  ),
                  TextFormField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'المبلغ بالجنيه',
                    ),
                    validator: (v) {
                      final n = _parse(v ?? '');
                      return n == null || n <= 0
                          ? 'أدخل مبلغاً أكبر من صفر'
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: notes,
                    decoration: InputDecoration(
                      labelText: type == 'expense' ? 'تفاصيل الصرف' : 'الوصف',
                    ),
                    validator: (v) =>
                        (type == 'expense' || type == 'repay_debt') &&
                            (v == null || v.trim().isEmpty)
                        ? 'هذا الحقل مطلوب'
                        : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                if (submitting) return;
                if (!form.currentState!.validate()) return;
                setState(() => submitting = true);
                try {
                  if (existing == null) {
                    await cubit.repo.add(
                      month: state.date!,
                      type: type,
                      amount: _parse(amount.text)!,
                      notes: notes.text,
                      categoryId: category,
                      operationId: operationId,
                      transactionDate: transactionDate,
                    );
                  } else {
                    await cubit.repo.edit(
                      id: existing['id'] as String,
                      type: type,
                      amount: _parse(amount.text)!,
                      notes: notes.text,
                      categoryId: category,
                      date: transactionDate,
                    );
                  }
                  if (d.mounted) Navigator.pop(d, true);
                } catch (e) {
                  if (d.mounted) {
                    setState(() => submitting = false);
                    ScaffoldMessenger.of(
                      d,
                    ).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              child: Text(existing == null ? 'حفظ' : 'حفظ التعديل'),
            ),
          ],
        ),
      ),
    );
    if (res == true && context.mounted) {
      await cubit.refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                existing == null ? 'تمت إضافة المعاملة' : 'تم تعديل المعاملة',
              ),
              action: SnackBarAction(
                label: 'تراجع',
                onPressed: () async {
                  await cubit.repo.undoLast();
                  await cubit.refresh();
                },
              ),
            ),
          );
      }
    }
  }

  Future<void> _history(
    BuildContext context,
    List<Map<String, Object?>> months,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (d) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                'الأرشيف الشهري',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ...months.map(
              (m) => ListTile(
                title: Text(m['monthYear'] as String),
                subtitle: Text(
                  'الدخل الأساسي: ${money(m['initialIncome'] as int)}',
                ),
                onTap: () {
                  final parts = (m['monthYear'] as String).split('-');
                  context.read<FinanceCubit>().load(
                    DateTime(int.parse(parts[0]), int.parse(parts[1])),
                  );
                  Navigator.pop(d);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportExcel(
    BuildContext context,
    FinanceCubit cubit,
    DateTime date,
  ) async {
    try {
      final bytes = await cubit.repo.excelWorkbook(date);
      final uri = await FilePicker.saveFile(
        fileName: 'مصروفات-${cubit.repo.key(date)}.xlsx',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        dialogTitle: 'حفظ تقرير المصروفات',
      );
      if (uri != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حفظ التقرير')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _exportBackup(BuildContext context, FinanceCubit cubit) async {
    try {
      final data = await cubit.repo.backupJson();
      final uri = await FilePicker.saveFile(
        fileName:
            'نسخة-مصروفات-${DateTime.now().toIso8601String().substring(0, 10)}.json',
        bytes: Uint8List.fromList(utf8.encode(data)),
        type: FileType.custom,
        allowedExtensions: ['json'],
        mimeType: 'application/json',
        dialogTitle: 'حفظ النسخة الاحتياطية',
      );
      if (uri != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ النسخة الاحتياطية')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _restoreBackup(
    BuildContext context,
    FinanceCubit cubit,
    DateTime date,
  ) async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked.isEmpty) return;
      final selected = picked.first;
      final bytes = await selected.readAsBytes();
      await cubit.repo.restoreBackup(utf8.decode(bytes));
      await cubit.load(date);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تمت استعادة النسخة الاحتياطية')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}
