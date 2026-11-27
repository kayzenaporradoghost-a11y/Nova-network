import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:micro_apk/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => '/tmp/network_test');
  });

  testWidgets('NETWORK opens the rebuilt operations workspace', (tester) async {
    await tester.pumpWidget(const MicroApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('NET work'), findsOneWidget);
    expect(find.text('Como posso ajudar?'), findsOneWidget);
    expect(find.text('Faça qualquer coisa'), findsOneWidget);
  });
}
