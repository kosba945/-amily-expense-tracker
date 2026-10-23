import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:family_expense_tracker/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:excel/excel.dart';

class MemorySessionStore implements SessionStore {
  String? userId;
  @override
  Future<void> clear() async => userId = null;
  @override
  Future<String?> readUserId() async => userId;
  @override
  Future<void> saveUserId(String id) async => userId = id;
}

void main() {
  late Directory tempDir;
  late FinanceDatabase database;
  late FinanceRepository repository;
  final month = DateTime(2026, 10, 1);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('family-finance-test-');
    database = await FinanceDatabase.open(
      databasePath: '${tempDir.path}/ledger.db',
    );
    repository = FinanceRepository(database);
    await repository.ensureMonth(month, 1_000_000);
  });

  tearDown(() async {
    await database.db.close();
    await tempDir.delete(recursive: true);
  });

  Future<int> categoryId() async =>
      (await repository.categories()).first['id'] as int;

  test('seeds all required Arabic categories exactly once', () async {
    expect(FinanceDatabase.categories, hasLength(11));
    expect(FinanceDatabase.categories.toSet(), hasLength(11));
    expect(
      (await repository.categories()).map((r) => r['name']),
      FinanceDatabase.categories,
    );
  });

  test('initial income and expense use integer piastres', () async {
    await repository.add(
      month: month,
      type: 'expense',
      amount: 12_550,
      categoryId: await categoryId(),
      notes: 'مشتريات',
    );
    final summary = await repository.summary(month);
    expect(summary.income, 1_000_000);
    expect(summary.expenses, 12_550);
    expect(summary.balance, 987_450);
  });

  test('decimal and Arabic numeral inputs convert exactly to piastres', () {
    expect(parsePiastres('125.50'), 12_550);
    expect(parsePiastres('١٢٥٫٥'), 12_550);
    expect(parsePiastres('1.234'), isNull);
    expect(parsePiastres('-1'), isNull);
  });

  test('extra income increases the selected month wallet', () async {
    await repository.add(
      month: month,
      type: 'extra_income',
      amount: 50_025,
      notes: 'مكافأة',
    );
    expect((await repository.summary(month)).balance, 1_050_025);
  });

  test(
    'database-derived integration sequence matches the wallet equations',
    () async {
      await repository.add(
        month: month,
        type: 'expense',
        amount: 50_000,
        categoryId: await categoryId(),
        notes: 'فاتورة',
      );
      await repository.add(
        month: month,
        type: 'extra_income',
        amount: 100_000,
        notes: 'دخل إضافي',
      );
      await repository.add(
        month: month,
        type: 'borrow',
        amount: 200_000,
        notes: 'استلاف',
      );
      await repository.add(
        month: month,
        type: 'repay_debt',
        amount: 50_000,
        notes: 'سداد',
      );
      var totals = await repository.summary(month);
      expect(totals.balance, 1_200_000);
      expect(totals.debt, 150_000);
      final expense = (await repository.transactions(
        month,
      )).singleWhere((r) => r['type'] == 'expense');
      await repository.edit(
        id: expense['id'] as String,
        type: 'expense',
        amount: 60_000,
        categoryId: await categoryId(),
        notes: 'تعديل',
      );
      await repository.undoLast();
      await repository.delete(expense['id'] as String);
      await repository.undoLast();
      await database.db.close();
      database = await FinanceDatabase.open(
        databasePath: '${tempDir.path}/ledger.db',
      );
      repository = FinanceRepository(database);
      totals = await repository.summary(month);
      expect(totals.expenses, 50_000);
      expect(totals.balance, 1_200_000);
      expect(totals.debt, 150_000);
    },
  );

  test('borrowing increases cash and debt, repayment reduces both', () async {
    await repository.add(
      month: month,
      type: 'borrow',
      amount: 200_000,
      notes: 'استلاف',
    );
    await repository.add(
      month: month,
      type: 'repay_debt',
      amount: 50_000,
      notes: 'سداد',
    );
    final summary = await repository.summary(month);
    expect(summary.balance, 1_150_000);
    expect(summary.debt, 150_000);
  });

  test('allocates repayments oldest first across months', () async {
    final previous = DateTime(2026, 9, 1);
    await repository.ensureMonth(previous, 0);
    await repository.add(
      month: previous,
      type: 'borrow',
      amount: 30_000,
      notes: 'دين أقدم',
    );
    await repository.add(
      month: month,
      type: 'borrow',
      amount: 40_000,
      notes: 'دين أحدث',
    );
    await repository.add(
      month: month,
      type: 'repay_debt',
      amount: 50_000,
      notes: 'سداد',
    );
    final allocations = await database.db.rawQuery(
      'SELECT d.originalAmount, r.allocatedAmount FROM repayments r JOIN debts d ON d.id=r.debtId ORDER BY d.rowid',
    );
    expect(allocations.map((r) => r['allocatedAmount']), [30_000, 20_000]);
    expect((await repository.summary(month)).debt, 20_000);
  });

  test('overpayment rolls back without adding a repayment', () async {
    await repository.add(
      month: month,
      type: 'borrow',
      amount: 10_000,
      notes: 'دين',
    );
    await expectLater(
      repository.add(
        month: month,
        type: 'repay_debt',
        amount: 10_001,
        notes: 'سداد',
      ),
      throwsArgumentError,
    );
    expect(
      (await repository.transactions(
        month,
      )).where((r) => r['type'] == 'repay_debt'),
      isEmpty,
    );
    expect((await repository.summary(month)).debt, 10_000);
  });

  test('editing an expense changes its authoritative total', () async {
    await repository.add(
      month: month,
      type: 'expense',
      amount: 10_000,
      categoryId: await categoryId(),
      notes: 'قبل',
    );
    final row = (await repository.transactions(month)).single;
    await repository.edit(
      id: row['id'] as String,
      type: 'expense',
      amount: 15_500,
      categoryId: await categoryId(),
      notes: 'بعد',
    );
    expect((await repository.summary(month)).expenses, 15_500);
  });

  test(
    'editing borrowing below already repaid amount fails atomically',
    () async {
      await repository.add(
        month: month,
        type: 'borrow',
        amount: 20_000,
        notes: 'دين',
      );
      final borrow = (await repository.transactions(month)).single;
      await repository.add(
        month: month,
        type: 'repay_debt',
        amount: 15_000,
        notes: 'سداد',
      );
      await expectLater(
        repository.edit(
          id: borrow['id'] as String,
          type: 'borrow',
          amount: 10_000,
          notes: 'دين',
        ),
        throwsArgumentError,
      );
      expect((await repository.summary(month)).debt, 5_000);
      expect(
        (await database.db.query('debts')).single['originalAmount'],
        20_000,
      );
    },
  );

  test('deleting a borrowing with dependent repayments is rejected', () async {
    await repository.add(
      month: month,
      type: 'borrow',
      amount: 20_000,
      notes: 'دين',
    );
    final borrow = (await repository.transactions(month)).single;
    await repository.add(
      month: month,
      type: 'repay_debt',
      amount: 2_000,
      notes: 'سداد',
    );
    await expectLater(
      repository.delete(borrow['id'] as String),
      throwsArgumentError,
    );
    expect((await repository.summary(month)).debt, 18_000);
  });

  test('deleting a repayment recalculates outstanding debt', () async {
    await repository.add(
      month: month,
      type: 'borrow',
      amount: 20_000,
      notes: 'دين',
    );
    await repository.add(
      month: month,
      type: 'repay_debt',
      amount: 2_000,
      notes: 'سداد',
    );
    final repayment = (await repository.transactions(
      month,
    )).singleWhere((r) => r['type'] == 'repay_debt');
    await repository.delete(repayment['id'] as String);
    expect((await repository.summary(month)).debt, 20_000);
  });

  test('undo creation, deletion, and edit restores prior state', () async {
    await repository.add(
      month: month,
      type: 'expense',
      amount: 1_250,
      categoryId: await categoryId(),
      notes: 'أصل',
    );
    var expense = (await repository.transactions(month)).single;
    await repository.edit(
      id: expense['id'] as String,
      type: 'expense',
      amount: 2_500,
      categoryId: await categoryId(),
      notes: 'معدل',
    );
    await repository.undoLast();
    expect((await repository.summary(month)).expenses, 1_250);
    await repository.delete(expense['id'] as String);
    await repository.undoLast();
    expect((await repository.summary(month)).expenses, 1_250);
    await repository.undoLast();
    expect((await repository.summary(month)).expenses, 0);
  });

  test('undo audit survives closing and reopening the database', () async {
    await repository.add(
      month: month,
      type: 'extra_income',
      amount: 1_500,
      notes: 'دخل',
    );
    await database.db.close();
    database = await FinanceDatabase.open(
      databasePath: '${tempDir.path}/ledger.db',
    );
    repository = FinanceRepository(database);
    await repository.undoLast();
    expect((await repository.summary(month)).extra, 0);
  });

  test(
    'duplicate operation identifiers are rejected without duplicate money',
    () async {
      await repository.add(
        month: month,
        type: 'extra_income',
        amount: 1_500,
        notes: 'دخل',
        operationId: 'retry-token',
      );
      await expectLater(
        repository.add(
          month: month,
          type: 'extra_income',
          amount: 1_500,
          notes: 'دخل',
          operationId: 'retry-token',
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await repository.summary(month)).extra, 1_500);
    },
  );

  test('empty month has zero financial analytics', () async {
    final emptyMonth = DateTime(2026, 11, 1);
    final summary = await repository.summary(emptyMonth);
    expect(summary.balance, 0);
    expect(summary.expenses, 0);
    expect(summary.debt, 0);
    expect(await repository.categorySpending(emptyMonth), isEmpty);
  });

  test(
    'Excel export has both Arabic sheets and actual ledger content',
    () async {
      await repository.add(
        month: month,
        type: 'expense',
        amount: 12_550,
        categoryId: await categoryId(),
        notes: 'وجبة الأسرة',
      );
      await repository.add(
        month: month,
        type: 'expense',
        amount: 5_000,
        categoryId: await categoryId(),
        notes: 'مصروف محذوف',
      );
      final deleted = (await repository.transactions(
        month,
      )).singleWhere((r) => r['notes'] == 'مصروف محذوف');
      await repository.delete(deleted['id'] as String);
      final workbook = Excel.decodeBytes(await repository.excelWorkbook(month));
      expect(
        workbook.tables.keys,
        containsAll(['ملخص الشهر', 'سجل العمليات بالتفصيل']),
      );
      final summaryRows = workbook.tables['ملخص الشهر']!.rows;
      expect(
        summaryRows.any(
          (row) => row.any((cell) => cell?.value.toString() == '12550'),
        ),
        isTrue,
      );
      final detailRows = workbook.tables['سجل العمليات بالتفصيل']!.rows;
      expect(
        detailRows.any(
          (row) => row.any((cell) => cell?.value.toString() == 'وجبة الأسرة'),
        ),
        isTrue,
      );
      expect(
        detailRows.any(
          (row) => row.any((cell) => cell?.value.toString() == 'مصروف محذوف'),
        ),
        isFalse,
      );
    },
  );

  test(
    'backup restores wallets, transactions, debt allocations, and audit',
    () async {
      await repository.add(
        month: month,
        type: 'borrow',
        amount: 30_000,
        notes: 'دين الأسرة',
      );
      await repository.add(
        month: month,
        type: 'repay_debt',
        amount: 5_000,
        notes: 'سداد جزئي',
      );
      final backup = await repository.backupJson();
      final restored = await FinanceDatabase.open(
        databasePath: '${tempDir.path}/restored.db',
      );
      try {
        final restoredRepository = FinanceRepository(restored);
        await restoredRepository.restoreBackup(backup);
        final totals = await restoredRepository.summary(month);
        expect(totals.income, 1_000_000);
        expect(totals.borrowed, 30_000);
        expect(totals.repaid, 5_000);
        expect(totals.debt, 25_000);
        expect(
          await restored.db.rawQuery('SELECT * FROM repayments'),
          hasLength(1),
        );
        expect(await restored.db.query('audit'), hasLength(2));
      } finally {
        await restored.db.close();
      }
    },
  );

  test('restore refuses to replace any existing financial data', () async {
    final backup = await repository.backupJson();
    await repository.add(
      month: month,
      type: 'extra_income',
      amount: 100,
      notes: 'موجود',
    );
    await expectLater(repository.restoreBackup(backup), throwsStateError);
    expect((await repository.summary(month)).extra, 100);
  });

  test(
    'offline registration, login, password hashing, session, and logout',
    () async {
      final session = MemorySessionStore();
      final auth = AuthRepository(database, sessionStore: session);
      final user = await auth.register(
        name: 'Khaled',
        username: 'khaled',
        password: 'strong-pass-1',
      );
      final stored = (await database.db.query('users')).single;
      expect(stored['passwordHash'], isNot('strong-pass-1'));
      expect(stored['passwordSalt'], isNotEmpty);
      expect(session.userId, user.id);
      await expectLater(
        auth.register(
          name: 'Other',
          username: 'other',
          password: 'strong-pass-2',
        ),
        throwsStateError,
      );
      await expectLater(
        auth.login(username: 'khaled', password: 'wrong-pass'),
        throwsArgumentError,
      );
      final loggedIn = await auth.login(
        username: 'KHALED',
        password: 'strong-pass-1',
      );
      expect(loggedIn.id, user.id);
      final restored = await AuthRepository(
        database,
        sessionStore: session,
      ).restoreSession();
      expect(restored?.username, 'khaled');
      await auth.logout();
      expect(await auth.restoreSession(), isNull);
    },
  );

  test(
    'registration generates a unique salt for each local account database',
    () async {
      final other = await FinanceDatabase.open(
        databasePath: '${tempDir.path}/other.db',
      );
      try {
        await AuthRepository(
          database,
          sessionStore: MemorySessionStore(),
        ).register(name: 'One', username: 'one', password: 'strong-pass-1');
        await AuthRepository(
          other,
          sessionStore: MemorySessionStore(),
        ).register(name: 'Two', username: 'two', password: 'strong-pass-1');
        final firstSalt = (await database.db.query(
          'users',
        )).single['passwordSalt'];
        final secondSalt = (await other.db.query(
          'users',
        )).single['passwordSalt'];
        expect(firstSalt, isNot(secondSalt));
      } finally {
        await other.db.close();
      }
    },
  );

  testWidgets(
    'authentication screen renders right-to-left and switches forms',
    (tester) async {
      final auth = AuthCubit(
        AuthRepository(database, sessionStore: MemorySessionStore()),
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: auth,
          child: const MaterialApp(home: AuthScreen(hasAccount: false)),
        ),
      );
      expect(
        Directionality.of(tester.element(find.byType(Scaffold))),
        TextDirection.rtl,
      );
      expect(find.text('إنشاء الحساب المحلي'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(3));
      await tester.tap(find.text('لدي حساب بالفعل'));
      await tester.pumpAndSettle();
      expect(find.text('تسجيل الدخول'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      await auth.close();
    },
  );
}
