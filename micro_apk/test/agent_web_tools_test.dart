import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:micro_apk/core/agent_web_tools.dart';

void main() {
  test('web search returns structured public results', () async {
    final client = MockClient((request) async => http.Response(
      '<div class="result"><a class="result__a" href="https://example.org/docs">Docs</a><div class="result__snippet">Official documentation</div></div>',
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    ));
    final web = NetworkWebTools(client: client, lookup: (_) async => [InternetAddress('93.184.216.34')]);
    final result = await web.search('NETWORK documentation');
    expect(result['count'], 1);
    expect((result['results'] as List).first['url'], 'https://example.org/docs');
    web.close();
  });

  test('page reader extracts content and removes scripts', () async {
    final client = MockClient((request) async => http.Response(
      '<html><head><title>Example</title><script>secret()</script></head><body><nav>Menu</nav><main>Hello <b>NETWORK</b></main></body></html>',
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    ));
    final web = NetworkWebTools(client: client);
    final result = await web.open('https://example.org/page');
    expect(result['title'], 'Example');
    expect(result['text'], contains('Hello NETWORK'));
    expect(result['text'], isNot(contains('secret')));
    expect(result['text'], isNot(contains('Menu')));
    web.close();
  });

  test('page reader rejects local network destinations', () async {
    final web = NetworkWebTools(client: MockClient((request) async =>
      http.Response('should not be requested', 200)), lookup: (_) async => [InternetAddress('93.184.216.34')]);
    expect(() => web.open('http://127.0.0.1/admin'), throwsArgumentError);
    web.close();
  });
}
