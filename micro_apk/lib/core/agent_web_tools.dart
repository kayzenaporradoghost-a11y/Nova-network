import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

/// Real web retrieval for the NETWORK agent. Only public HTTP(S) destinations
/// are accepted; redirects are revalidated to prevent access to local services.
class NetworkWebTools {
  NetworkWebTools({http.Client? client, Future<List<InternetAddress>> Function(String)? lookup})
      : _client = client ?? http.Client(),
        _lookup = lookup ?? ((host) => InternetAddress.lookup(host));

  final http.Client _client;
  final Future<List<InternetAddress>> Function(String) _lookup;
  static const _userAgent = 'NETWORK-Agent/1.0 (web research)';
  static const _maxPageBytes = 2 * 1024 * 1024;

  bool _isPublic(Uri uri) {
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') ||
        host.endsWith('.local') || host == 'metadata.google.internal') return false;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return true;
    final addressBytes = ip.rawAddress;
    final isUnspecified = addressBytes.every((byte) => byte == 0);
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast || isUnspecified) return false;
    if (ip.type == InternetAddressType.IPv4) {
      final p = ip.rawAddress;
      if (p[0] == 10 || p[0] == 127 ||
          (p[0] == 172 && p[1] >= 16 && p[1] <= 31) ||
          (p[0] == 192 && p[1] == 168) ||
          (p[0] == 169 && p[1] == 254) ||
          (p[0] == 100 && p[1] >= 64 && p[1] <= 127)) return false;
    } else {
      final p = ip.rawAddress;
      if ((p[0] & 0xfe) == 0xfc) return false;
    }
    return true;
  }

  Future<void> _validatePublicDestination(Uri uri) async {
    if (!_isPublic(uri)) throw ArgumentError('URL não pública ou protocolo não permitido.');
    final addresses = await _lookup(uri.host).timeout(const Duration(seconds: 8));
    if (addresses.isEmpty || addresses.any((address) =>
        !_isPublic(Uri(scheme: uri.scheme, host: address.address)))) {
      throw ArgumentError('O domínio resolve para um endereço de rede privada.');
    }
  }

  Future<http.Response> _get(Uri initial) async {
    var uri = initial;
    for (var redirect = 0; redirect <= 5; redirect++) {
      await _validatePublicDestination(uri);
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
        });
      final streamed = await _client.send(request).timeout(const Duration(seconds: 25));
      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        final location = streamed.headers['location'];
        await streamed.stream.drain<void>();
        if (location == null) throw HttpException('Redirecionamento sem destino.');
        uri = uri.resolve(location);
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(const Duration(seconds: 25))) {
        if (bytes.length + chunk.length > _maxPageBytes) {
          throw const HttpException('Página excede o limite de leitura de 2 MB.');
        }
        bytes.add(chunk);
      }
      return http.Response.bytes(bytes.takeBytes(), streamed.statusCode,
          headers: streamed.headers, request: request);
    }
    throw const HttpException('A página excedeu 5 redirecionamentos.');
  }

  Future<Map<String, dynamic>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) throw ArgumentError('Informe o que deseja pesquisar.');
    final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': q});
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw HttpException('Pesquisa web retornou HTTP ${response.statusCode}.');
    }
    final document = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
    final results = <Map<String, String>>[];
    for (final item in document.querySelectorAll('.result')) {
      final anchor = item.querySelector('.result__a');
      final rawHref = anchor?.attributes['href'];
      if (anchor == null || rawHref == null) continue;
      var resultUri = Uri.tryParse(rawHref);
      if (resultUri != null && resultUri.host.contains('duckduckgo.com')) {
        final target = resultUri.queryParameters['uddg'];
        if (target != null) resultUri = Uri.tryParse(target);
      }
      if (resultUri == null || !_isPublic(resultUri)) continue;
      results.add({
        'title': anchor.text.trim(),
        'url': resultUri.toString(),
        'snippet': (item.querySelector('.result__snippet')?.text ?? '').trim(),
      });
      if (results.length == 8) break;
    }
    return {'query': q, 'results': results, 'count': results.length};
  }

  Future<Map<String, dynamic>> open(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !_isPublic(uri)) {
      throw ArgumentError('Informe uma URL pública HTTP ou HTTPS válida.');
    }
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Página retornou HTTP ${response.statusCode}.');
    }
    final contentType = response.headers['content-type'] ?? '';
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (contentType.contains('application/pdf') || uri.path.toLowerCase().endsWith('.pdf')) {
      return {'url': uri.toString(), 'content_type': contentType,
        'message': 'O endereço aponta para PDF; use o leitor de arquivos do NETWORK.'};
    }
    final document = html_parser.parse(body);
    for (final selector in ['script', 'style', 'noscript', 'svg', 'nav', 'footer', 'header']) {
      document.querySelectorAll(selector).forEach((element) => element.remove());
    }
    final title = document.querySelector('title')?.text.trim() ?? '';
    final text = (document.body?.text ?? document.documentElement?.text ?? '')
        .replaceAll(RegExp(r'[\\t\\r\\n ]+'), ' ').trim();
    return {
      'url': uri.toString(),
      'title': title,
      'content_type': contentType,
      'text': text.length > 18000 ? text.substring(0, 18000) : text,
      'truncated': text.length > 18000,
    };
  }

  void close() => _client.close();
}
