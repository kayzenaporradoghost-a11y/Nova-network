import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:micro_apk/core/app_knowledge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppKnowledgeStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppKnowledgeStore();
  });

  test('only verified app workflows are stored', () async {
    await expectLater(
      store.save(
        packageName: 'com.whatsapp',
        appName: 'WhatsApp',
        task: 'Open a conversation',
        steps: ['Open WhatsApp', 'Select the named contact'],
        verified: false,
      ),
      throwsStateError,
    );
    expect(await store.list(), isEmpty);
  });

  test('learned workflows are isolated by package and searchable', () async {
    await store.save(
      packageName: 'com.whatsapp',
      appName: 'WhatsApp',
      task: 'Find a conversation',
      steps: ['Use the search field', 'Open the exact matching conversation'],
      verified: true,
    );
    final matches = await store.search(
      packageName: 'com.whatsapp',
      task: 'search conversation',
    );
    expect(matches, hasLength(1));
    expect(matches.single['verified'], isTrue);
    expect(await store.search(
      packageName: 'com.instagram.android',
      task: 'search conversation',
    ), isEmpty);
  });

  test('repeated verified workflow updates success count instead of duplicating', () async {
    final first = await store.save(
      packageName: 'com.whatsapp',
      appName: 'WhatsApp',
      task: 'Find contact',
      steps: ['Search by exact name'],
      verified: true,
    );
    final second = await store.save(
      packageName: 'com.whatsapp',
      appName: 'WhatsApp',
      task: 'Find contact',
      steps: ['Search by exact name', 'Verify the contact header'],
      verified: true,
    );
    expect(first['successCount'], 1);
    expect(second['successCount'], 2);
    expect(await store.list(), hasLength(1));
  });
}
