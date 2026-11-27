/// Conservative intent routing for actions that do not require model reasoning.
/// Only a plain, standalone request to open one app is routed directly.
class AgentIntentRouter {
  AgentIntentRouter._();

  static String? simpleOpenApp(String input) {
    final prompt = input.trim();
    if (prompt.isEmpty || prompt.length > 80 || prompt.contains('\n')) return null;
    final match = RegExp(
      r'^(?:abre|abrir|abra|open|launch|inicie|iniciar)\s+(?:(?:o|a)\s+)?(?:(?:app|aplicativo|aplicação)\s+(?:do|da|de)?\s*)?(.+?)(?:\s+por favor)?[.!?]*$',
      caseSensitive: false,
    ).firstMatch(prompt);
    if (match == null) return null;
    var app = (match.group(1) ?? '').trim().replaceAll(RegExp(r'[.!?]+$'), '');
    if (app.isEmpty || app.length > 50) return null;
    if ({'app','apps','aplicativo','aplicativos','aplicação','aplicações'}.contains(app.toLowerCase())) return null;
    // Reject multi-action or task-bearing requests; those need the model loop.
    if (RegExp(r'\b(e|depois|então|mas|manda|enviar|envia|pesquisa|pesquisar|procura|buscar|busca|digita|escreve|abre|fecha|apaga|exclui|compra|paga|transfere|instala|configura|cria|faz|executa|vai)\b', caseSensitive: false).hasMatch(app)) return null;
    return app;
  }
}
