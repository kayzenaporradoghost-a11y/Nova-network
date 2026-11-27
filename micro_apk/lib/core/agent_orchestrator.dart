/// Registry of 130 lightweight specialist profiles. Specialist inference is opt-in
/// per task; the main NETWORK agent remains the sole action coordinator.
class SpecialistProfile {
  const SpecialistProfile({required this.id, required this.name, required this.domain, required this.keywords, required this.guidance});
  final String id;
  final String name;
  final String domain;
  final List<String> keywords;
  final String guidance;
}

class AgentOrchestrator {
  AgentOrchestrator._();

  static const List<Map<String, dynamic>> _domains = [{'id':"android",'label':"Android",'keywords':["android","celular","telefone","app","aplicativo","acessibilidade","tela","toque","janela","permissao","samsung","whatsapp","notificacao"],'guidance':"Especialista em Android nativo, ciclo de vida, APIs do sistema, Acessibilidade, janelas e interação segura.",'roles':["Acessibilidade","Navegação de aplicativos","Estado de interface","Gestos e entrada","Permissões Android","Multijanela","Notificações","Compatibilidade de dispositivos","Automação móvel","Desempenho móvel"]},{'id':"messaging",'label':"Mensagens e redes sociais",'keywords':["whatsapp","telegram","mensagem","contato","conversa","chat","grupo","instagram","facebook","social","enviar"],'guidance':"Especialista em fluxos de mensagens e redes sociais, validação de destinatário e confirmação de efeitos.",'roles':["Contatos e destinatários","WhatsApp","Telegram","Redação de mensagens","Navegação de conversas","Mídia e anexos","Grupos e canais","Contas comerciais","Privacidade social","Verificação de entrega"]},{'id':"browser",'label':"Navegador",'keywords':["navegador","browser","chrome","site","aba","formulario","download","url","pagina","pesquisa web"],'guidance':"Especialista em navegação web, interação com páginas e extração segura de conteúdo.",'roles':["Navegação web","Formulários","Abas e sessões","Downloads","Busca no navegador","Extração de páginas","Acessibilidade web","Automação de navegador","Privacidade web","Depuração de páginas"]},{'id':"research",'label':"Pesquisa e conhecimento",'keywords':["pesquisar","pesquisa","pesquise","web","internet","fontes","documentacao","noticia","comparar","informacao","fatos"],'guidance':"Especialista em pesquisa, validação cruzada, fontes primárias e síntese verificável.",'roles':["Descoberta de fontes","Checagem de fatos","Documentação técnica","Notícias atuais","Comparação de opções","Citações e evidências","Pesquisa aprofundada","Pesquisa de produtos","Pesquisa local","Síntese de conhecimento"]},{'id':"coding",'label':"Engenharia de software",'keywords':["codigo","programar","programacao","flutter","dart","kotlin","python","javascript","bug","erro","app","api","teste","refatorar"],'guidance':"Especialista em engenharia de software, arquitetura, implementação, testes e depuração.",'roles':["Arquitetura de software","Flutter e Dart","Kotlin e Android","Python","JavaScript e TypeScript","Testes automatizados","Depuração","Refatoração","Otimização de código","Integração de APIs"]},{'id':"devops",'label':"Infraestrutura e DevOps",'keywords':["vps","servidor","linux","debian","ssh","docker","deploy","ci","cd","rede","ipv6","terminal","systemd"],'guidance':"Especialista em Linux, servidores, rede, implantação e confiabilidade operacional.",'roles':["Administração Linux","SSH e acesso remoto","Docker e containers","Redes e IPv6","Implantação","CI e CD","Observabilidade","Armazenamento","Backups e recuperação","Resposta a incidentes"]},{'id':"github",'label':"GitHub",'keywords':["github","repositorio","commit","branch","pull request","actions","workflow","issue","release","git"],'guidance':"Especialista em Git e GitHub, histórico, automação, revisão e integridade de repositórios.",'roles':["Análise de repositório","Busca de código","Commits e histórico","Branches e merges","GitHub Actions","Pull requests","Issues e projetos","Releases e artefatos","Segurança do repositório","Automação GitHub"]},{'id':"files",'label':"Arquivos e documentos",'keywords':["arquivo","pasta","pdf","docx","xlsx","planilha","documento","imagem","zip","anexo","biblioteca"],'guidance':"Especialista em leitura, edição, conversão e organização de arquivos.",'roles':["Sistemas de arquivos","PDF","Documentos de texto","Planilhas","Apresentações","Imagens","Arquivos compactados","Busca documental","Conversão de formatos","Organização de arquivos"]},{'id':"data",'label':"Dados e análise",'keywords':["dados","csv","json","sql","banco","analise","estatistica","grafico","relatorio","dataset","medir","metricas"],'guidance':"Especialista em processamento, qualidade, análise e visualização de dados.",'roles':["Extração de dados","Limpeza de dados","SQL e bancos","Estatística","Visualização","Aprendizado de máquina","Pipelines de dados","Validação de dados","Relatórios","Otimização analítica"]},{'id':"security",'label':"Segurança e privacidade",'keywords':["seguranca","security","privacidade","token","senha","permissao","criptografia","auditoria","vulnerabilidade","risco","autenticacao"],'guidance':"Especialista em modelagem de ameaças, proteção de credenciais e segurança de aplicações.",'roles':["Modelagem de ameaças","Segredos e credenciais","Permissões e privilégios","Segurança de rede","Segurança Android","Auditoria de dependências","Código seguro","Privacidade de dados","Controle de acesso","Resposta a incidentes"]},{'id':"planning",'label':"Planejamento e produto",'keywords':["planejar","plano","projeto","requisito","prioridade","arquitetura","estrategia","decisao","roadmap","processo"],'guidance':"Especialista em decomposição de objetivos, prioridades, riscos e desenho de processos.",'roles':["Levantamento de requisitos","Estratégia de produto","Planejamento de projetos","Priorização","Estimativas","Desenho de processos","Análise de riscos","Apoio à decisão","Pesquisa de mercado","Garantia de qualidade"]},{'id':"writing",'label':"Comunicação e linguagem",'keywords':["escrever","texto","email","e-mail","traduzir","traducao","resumir","resumo","revisar","portugues","mensagem","tom"],'guidance':"Especialista em comunicação clara, escrita, tradução e revisão linguística.",'roles':["Português brasileiro","Tradução","Redação","Edição e revisão","Resumo","Tom e estilo","E-mails","Conteúdo social","Conversação","Clareza e acessibilidade"]},{'id':"productivity",'label':"Produtividade e assistente",'keywords':["tarefa","agenda","lembrete","memoria","rotina","organizar","produtividade","automacao","workflow","acompanhar"],'guidance':"Especialista em organização, memória operacional, automação de rotinas e continuidade.",'roles':["Gestão de tarefas","Agendamento","Notas e memória","Automação pessoal","Fluxos de trabalho","Foco e execução","Lembretes","Assistência pessoal","Continuidade de tarefas","Acompanhamento de resultados"]}];

  static String _slug(String value) => value.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  static String _normalize(String value) => value.toLowerCase()
      .replaceAll('á','a').replaceAll('à','a').replaceAll('ã','a').replaceAll('â','a')
      .replaceAll('é','e').replaceAll('ê','e').replaceAll('í','i')
      .replaceAll('ó','o').replaceAll('ô','o').replaceAll('õ','o')
      .replaceAll('ú','u').replaceAll('ç','c');

  static final List<SpecialistProfile> all = List<SpecialistProfile>.unmodifiable([
    for (final domain in _domains)
      for (final role in (domain['roles'] as List<String>))
        SpecialistProfile(
          id: '${domain['id']}_${_slug(role)}',
          name: '${domain['label']} — $role',
          domain: domain['id'] as String,
          keywords: List<String>.unmodifiable([
            ...(domain['keywords'] as List<String>),
            ...role.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((part) => part.length > 2),
          ]),
          guidance: '${domain['guidance']} Foco específico: $role. Trabalhe somente como consultor de análise; não execute ações nem presuma resultados.',
        ),
  ]);

  static SpecialistProfile? find(String id) {
    for (final profile in all) { if (profile.id == id) return profile; }
    return null;
  }

  /// Fast local routing; no model call, network request, or UI wait.
  static List<SpecialistProfile> route(String task, {int limit = 12}) {
    final normalized = _normalize(task);
    final tokens = normalized.split(RegExp(r'[^a-z0-9]+')).where((t) => t.length > 2).toSet();
    final scored = <({SpecialistProfile profile, int score})>[];
    for (final profile in all) {
      var score = 0;
      for (final keyword in profile.keywords) {
        final term = _normalize(keyword);
        if (term.length > 2 && (normalized.contains(term) || tokens.contains(term))) {
          score += term.contains(' ') ? 4 : 2;
        }
      }
      if (score > 0) scored.add((profile: profile, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.profile.id.compareTo(b.profile.id);
    });
    if (scored.isEmpty) {
      return all.where((p) => p.domain == 'planning' || p.domain == 'productivity').take(limit).toList();
    }
    final selected = <SpecialistProfile>[];
    final domains = <String>{};
    // Prefer domain diversity first, then fill remaining slots by relevance.
    for (final item in scored) {
      if (domains.add(item.profile.domain)) selected.add(item.profile);
      if (selected.length == limit) return selected;
    }
    for (final item in scored) {
      if (!selected.any((p) => p.id == item.profile.id)) selected.add(item.profile);
      if (selected.length == limit) break;
    }
    return selected;
  }

  static String directoryFor(String task, {int limit = 12}) => route(task, limit: limit)
      .map((p) => '- ${p.id}: ${p.name}')
      .join('\n');
}
