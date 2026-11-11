import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatify/owner_dashboards.dart';

void main() {
  testWidgets('school owner dashboard shows metrics for an owned school',
      (tester) async {
    Future<Map<String, dynamic>> api(String method, String path) async {
      if (path == '/api/schools') {
        return {
          'schools': [
            {'id': 'school-1', 'name': 'Lakeview Community School', 'code': 'LCS', 'role': 'admin', 'isOwner': true}
          ]
        };
      }
      if (path.contains('/students')) return {'total': 6};
      if (path.contains('/attendance')) return {'total': 12};
      if (path.contains('/members')) return {'total': 3};
      if (path.contains('/fee-balances')) return {'total': 6};
      return {};
    }

    await tester.pumpWidget(MaterialApp(
      home: SchoolOwnerDashboard(
        apiCall: api,
        currentUserId: 'owner-1',
        onManage: () {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('School owner dashboard'), findsOneWidget);
    expect(find.text('Lakeview Community School'), findsOneWidget);
    expect(find.text('Students'), findsOneWidget);
    expect(find.text('Attendance records'), findsOneWidget);
    expect(find.text('Manage school workspace'), findsOneWidget);
  });

  testWidgets('school dashboard does not present staff workspace as owner data',
      (tester) async {
    Future<Map<String, dynamic>> api(String method, String path) async => {
      'schools': [
        {'id': 'school-2', 'name': 'Another School', 'role': 'staff', 'isOwner': false}
      ]
    };

    await tester.pumpWidget(MaterialApp(
      home: SchoolOwnerDashboard(
        apiCall: api,
        currentUserId: 'staff-1',
        onManage: () {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No school owned by this account'), findsOneWidget);
    expect(find.text('Another School'), findsNothing);
    expect(find.text('Open school workspace'), findsOneWidget);
  });

  testWidgets('business owner dashboard uses only organizations owned by user',
      (tester) async {
    Future<Map<String, dynamic>> api(String method, String path) async {
      if (path == '/api/business/organizations') {
        return {
          'organizations': [
            {'_id': 'business-1', 'ownerId': 'owner-1', 'name': "Makena's Market", 'industry': 'retail', 'currency': 'KES', 'branches': [{}, {}]},
            {'_id': 'business-2', 'ownerId': 'someone-else', 'name': 'Private Other Business'}
          ]
        };
      }
      if (path.endsWith('/dashboard')) {
        return {
          'metrics': {
            'customers': 8,
            'activeCatalogItems': 5,
            'documents': 4,
            'openTasks': 2,
            'openCases': 1,
            'lowStockItems': [],
            'briefing': 'Two tasks need attention.'
          }
        };
      }
      return {};
    }

    await tester.pumpWidget(MaterialApp(
      home: BusinessOwnerDashboard(
        apiCall: api,
        currentUserId: 'owner-1',
        onManage: () {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Business owner dashboard'), findsOneWidget);
    expect(find.text("Makena's Market"), findsOneWidget);
    expect(find.text('Customers'), findsOneWidget);
    expect(find.text('Private Other Business'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('Manage business workspace'), findsOneWidget);
  });

  testWidgets('school owner can switch between owned school dashboards',
      (tester) async {
    Future<Map<String, dynamic>> api(String method, String path) async {
      if (path == '/api/schools') {
        return {
          'schools': [
            {'id': 'school-1', 'name': 'First School', 'code': 'ONE', 'role': 'admin', 'isOwner': true},
            {'id': 'school-2', 'name': 'Second School', 'code': 'TWO', 'role': 'admin', 'isOwner': true}
          ]
        };
      }
      if (path.contains('/students')) return {'total': path.contains('school-2') ? 22 : 11};
      if (path.contains('/attendance')) return {'total': 1};
      if (path.contains('/members')) return {'total': 1};
      if (path.contains('/fee-balances')) return {'total': 1};
      return {};
    }

    await tester.pumpWidget(MaterialApp(
      home: SchoolOwnerDashboard(apiCall: api, currentUserId: 'owner-1', onManage: () {}),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First School'), findsWidgets);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second School').last);
    await tester.pumpAndSettle();

    expect(find.text('Second School'), findsWidgets);
    expect(find.text('22'), findsOneWidget);
  });

  testWidgets('business owner can switch between owned organizations',
      (tester) async {
    Future<Map<String, dynamic>> api(String method, String path) async {
      if (path == '/api/business/organizations') {
        return {
          'organizations': [
            {'_id': 'business-1', 'ownerId': 'owner-1', 'name': 'First Business', 'branches': []},
            {'_id': 'business-2', 'ownerId': 'owner-1', 'name': 'Second Business', 'branches': []}
          ]
        };
      }
      if (path.endsWith('/dashboard')) {
        return {'metrics': {'customers': path.contains('business-2') ? 44 : 33}};
      }
      return {};
    }

    await tester.pumpWidget(MaterialApp(
      home: BusinessOwnerDashboard(apiCall: api, currentUserId: 'owner-1', onManage: () {}),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First Business'), findsWidgets);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Business').last);
    await tester.pumpAndSettle();

    expect(find.text('Second Business'), findsWidgets);
    expect(find.text('44'), findsOneWidget);
  });
}
