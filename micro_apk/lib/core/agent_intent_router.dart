/// Conservative intent routing for direct actions and Android task classification.
class AgentIntentRouter {
  AgentIntentRouter._();

  static bool isAndroidExecutionTask(String input) => RegExp(
    r'android|celular|telefone|smartphone|app|whatsapp|telegram|instagram|facebook|messenger|tiktok|youtube|notifica|permiss[aã]o|acessibilidade|tela|aplicativo|abrir app|toque|digitar|clicar|janela flutuante|pop.?up|aparelho|mobile|mensagem|conversa|manda|enviar|envia|ligar|chamada|verifica|checa|abre|abrir|fecha|navega|pesquisa no celular',
    caseSensitive: false,
  ).hasMatch(input);

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
    if (RegExp(r'\b(e|depois|então|mas|manda|enviar|envia|pesquisa|pesquisar|procura|buscar|busca|digita|escreve|abre|fecha|apaga|exclui|compra|paga|transfere|instala|configura|cria|faz|executa|vai|mensagem|conversa|verifica|checa)\b', caseSensitive: false).hasMatch(app)) return null;
    return app;
  }
}
