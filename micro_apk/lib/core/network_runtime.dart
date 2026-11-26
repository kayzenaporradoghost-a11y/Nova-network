import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'agent_web_tools.dart';
import 'agent_orchestrator.dart';
import 'agent_performance.dart';

class VpsTarget {
  const VpsTarget({required this.name, required this.host, required this.username, this.port = 22});
  final String name, host, username;
  final int port;
  Map<String,dynamic> toJson() => {'name':name,'host':host,'username':username,'port':port};
  factory VpsTarget.fromJson(Map<String,dynamic> j) => VpsTarget(name:j['name'],host:j['host'],username:j['username'],port:(j['port'] as num?)?.toInt() ?? 22);
}

class SshManager {
  static const _secure = FlutterSecureStorage();
  static const _targetsKey = 'network_v2_ssh_targets';
  final Map<String,SSHClient> _clients = {};
  final Map<String,SSHSession> _shells = {};

  Future<List<VpsTarget>> targets() async {
    final raw = (await SharedPreferences.getInstance()).getString(_targetsKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) => VpsTarget.fromJson(Map<String,dynamic>.from(e as Map))).toList();
  }
  Future<void> saveTarget(VpsTarget target,{String? password,String? privateKey}) async {
    final list = await targets();
    list.removeWhere((e) => e.name == target.name);
    list.add(target);
    await (await SharedPreferences.getInstance()).setString(_targetsKey,jsonEncode(list.map((e)=>e.toJson()).toList()));
    if (password != null && password.isNotEmpty) await _secure.write(key:'network_v2_ssh_'+target.name+'_password',value:password);
    if (privateKey != null && privateKey.isNotEmpty) await _secure.write(key:'network_v2_ssh_'+target.name+'_key',value:privateKey);
  }
  Future<void> removeTarget(String name) async {
    await disconnect(name);
    final list = await targets()..removeWhere((e)=>e.name==name);
    await (await SharedPreferences.getInstance()).setString(_targetsKey,jsonEncode(list.map((e)=>e.toJson()).toList()));
    await _secure.delete(key:'network_v2_ssh_'+name+'_password');
    await _secure.delete(key:'network_v2_ssh_'+name+'_key');
  }
  Future<String> connect(String name) async {
    final active = _clients[name];
    if (active != null && !active.isClosed) return 'Já conectado: '+name;
    VpsTarget? target;
    for (final item in await targets()) { if (item.name == name) { target = item; break; } }
    if (target == null) throw StateError('Servidor não cadastrado: '+name);
    final host = target.host.replaceAll('[','').replaceAll(']','').trim();
    final password = await _secure.read(key:'network_v2_ssh_'+name+'_password');
    final pem = await _secure.read(key:'network_v2_ssh_'+name+'_key');
    if ((password ?? '').isEmpty && (pem ?? '').isEmpty) throw StateError('Cadastre senha ou chave SSH para '+name);
    final socket = await SSHSocket.connect(host,target.port).timeout(const Duration(seconds:20));
    final prefs = await SharedPreferences.getInstance();
    const knownHostsKey = 'network_v2_ssh_known_hosts';
    final rawKnown = prefs.getString(knownHostsKey);
    final known = rawKnown == null ? <String,dynamic>{} : Map<String,dynamic>.from(jsonDecode(rawKnown) as Map);
    final hostKey = host+':'+target.port.toString();
    String? presentedFingerprint;
    final client = SSHClient(socket,username:target.username,
      onPasswordRequest:password == null ? null : ()=>password,
      identities:pem == null ? const [] : SSHKeyPair.fromPem(pem),
      onVerifyHostKey:(type,fingerprint) {
        presentedFingerprint = base64Encode(fingerprint);
        final pinned = known[hostKey];
        return pinned == null || pinned == presentedFingerprint;
      });
    try {
      await client.authenticated.timeout(const Duration(seconds:25));
      if (presentedFingerprint != null && known[hostKey] == null) {
        known[hostKey] = presentedFingerprint;
        await prefs.setString(knownHostsKey,jsonEncode(known));
      }
      _clients[name] = client;
      client.done.whenComplete(()=>_clients.remove(name));
      return 'Conectado à '+name;
    } catch (_) { client.close(); rethrow; }
  }
  Future<Map<String,dynamic>> executeWithStatus(String name,String command) async {
    var client = _clients[name];
    if (client == null || client.isClosed) { await connect(name); client = _clients[name]; }
    if (client == null || client.isClosed) throw StateError('Sessão SSH indisponível');
    final result = await client.runWithResult(command);
    return {'exitCode':result.exitCode,'stdout':utf8.decode(result.stdout,allowMalformed:true),'stderr':utf8.decode(result.stderr,allowMalformed:true)};
  }
  Future<String> execute(String name,String command) async {
    final r = await executeWithStatus(name,command);
    return (r['stdout'] as String)+(r['stderr'] as String);
  }
  Future<void> openShell(String name) async {
    final c = _clients[name];
    if (c == null || c.isClosed) throw StateError('Conecte a VPS primeiro');
    _shells[name] ??= await c.shell();
  }
  Stream<String> shellStdout(String name) => _shells[name]!.stdout.cast<List<int>>().transform(utf8.decoder);
  Stream<String> shellStderr(String name) => _shells[name]!.stderr.cast<List<int>>().transform(utf8.decoder);
  void writeShell(String name,String input) => _shells[name]!.stdin.add(Uint8List.fromList(utf8.encode(input)));
  bool hasShell(String name) => _shells.containsKey(name);
  List<String> get connected => _clients.keys.toList();
  Future<void> closeShell(String name) async { _shells.remove(name)?.close(); }
  Future<void> disconnect(String name) async { await closeShell(name); _clients.remove(name)?.close(); }
  Future<void> disconnectAll() async { for (final n in _clients.keys.toList()) { await disconnect(n); } }
}

class GithubService {
  static const _secure = FlutterSecureStorage();
  static const _key = 'network_v2_github_token';
  final http.Client _http = http.Client();
  Future<bool> get isConfigured async => (await _secure.read(key:_key))?.isNotEmpty == true;
  Future<void> configureToken(String token) async {
    if (token.trim().isEmpty) throw ArgumentError('Token vazio');
    await _secure.write(key:_key,value:token.trim());
  }
  Future<Map<String,String>> get _headers async {
    final token = await _secure.read(key:_key);
    if (token == null || token.isEmpty) throw StateError('GitHub não conectado');
    return {'Accept':'application/vnd.github+json','Authorization':'Bearer '+token,'X-GitHub-Api-Version':'2022-11-28'};
  }
  Future<String> authenticatedUsername() async {
    final r = await _http.get(Uri.https('api.github.com','/user'),headers:await _headers);
    if (r.statusCode != 200) throw HttpException('GitHub HTTP '+r.statusCode.toString());
    return (jsonDecode(r.body) as Map<String,dynamic>)['login']?.toString() ?? 'GitHub';
  }
  Future<void> authorizeInBrowser() async { throw UnsupportedError('Use o campo de token GitHub nas configurações de conectores.'); }
  Future<void> disconnect() async => _secure.delete(key:_key);
  Future<List<Map<String,dynamic>>> repositories() async {
    final r = await _http.get(Uri.https('api.github.com','/user/repos',{'per_page':'100','sort':'updated'}),headers:await _headers);
    if (r.statusCode != 200) throw HttpException('GitHub HTTP '+r.statusCode.toString());
    return (jsonDecode(r.body) as List).cast<Map<String,dynamic>>();
  }
}

class BlackChatService {
  static const _secure = FlutterSecureStorage();
  static const endpointKey = 'network_v2_ai_endpoint';
  static const modelKey = 'network_v2_ai_model';
  static const tokenKey = 'network_v2_ai_token';
  static const promptKey = 'network_v2_ai_prompt';
  static const defaultBaseUrl = 'https://ai-gateway.kilo.ai/api/v1';
  static const defaultModel = 'nvidia/nemotron-3.5-super-vl:free';
  Future<void> saveConfig({required String apiKey,required String endpoint,required String modelName,required String prompt}) async {
    final u = Uri.tryParse(endpoint.trim());
    if (u == null || u.scheme != 'https' || u.host.isEmpty || modelName.trim().isEmpty) throw FormatException('Endpoint HTTPS e modelo são obrigatórios');
    await _secure.write(key:endpointKey,value:endpoint.trim().replaceAll(RegExp(r'/+$'),''));
    await _secure.write(key:modelKey,value:modelName.trim());
    if (apiKey.trim().isEmpty) { await _secure.delete(key:tokenKey); } else { await _secure.write(key:tokenKey,value:apiKey.trim()); }
    await _secure.write(key:promptKey,value:prompt.trim());
  }
  Future<String> get endpoint async => await _secure.read(key:endpointKey) ?? defaultBaseUrl;
  Future<String> get model async => await _secure.read(key:modelKey) ?? defaultModel;
  Future<String> get apiKey async => await _secure.read(key:tokenKey) ?? '';
  Future<String> get systemPrompt async => await _secure.read(key:promptKey) ?? 'Você é NETWORK, uma IA agente autônoma de uso geral. Você decide como cumprir cada pedido, quais ferramentas usar, em que ordem, quando observar novamente a tela, quando mudar de estratégia e quando a tarefa está realmente concluída. NÃO monte planos fechados antecipadamente nem delegue decisões a regras fixas do executor. Para Android, todas as ações que alteram a interface devem ser executadas por phone_batch, em uma chamada com até 10 passos mecânicos previsíveis. Não use ferramentas individuais de abrir, tocar, focar, digitar, rolar ou voltar. Use nova inferência apenas para ler uma tela nova, quando o resultado mudar a decisão, surgir ambiguidade, houver erro ou for necessária confirmação sensível. Não tente adivinhar alvos que não foram observados. A phone_batch para no primeiro erro e devolve a tela atual; então reavalie. Nunca agrupe envio/publicação, pagamentos, exclusões, permissões, confirmações ou efeitos irreversíveis. Pode executar várias chamadas independentes juntas quando forem realmente independentes. Se uma ação falhar, analise o erro e o estado atual, escolha outra estratégia e continue sem repetir ações já concluídas. Não invente sucesso: verifique o efeito real. Responda em português brasileiro. Para automação Android, observe a tela com acessibilidade/OCR, interprete os elementos e escolha ações com base no estado atual. Nunca espere o aplicativo carregar por completo se os elementos necessários já estiverem disponíveis. PERCEPÇÃO ANDROID OBRIGATÓRIA: antes de automação, consulte phone_android_sensitivity e phone_list_apps quando o estado/permissões/aplicativos forem relevantes. Cruze permissões concedidas/negadas/especiais, capacidade de captura de tela (autorização temporária), serviço de Acessibilidade, app ativo e inventário de aplicativos. Use nomes humanos ou pacote ao abrir; nunca invente pacote. Se nome ambíguo, mostre candidatos e não abra um aleatório. Depois de abrir, leia phone_screen_read; se elementos estiverem ausentes/incompletos, solicite phone_screen_ocr_capture somente quando a captura autorizada estiver disponível, e verifique eventos/tela após cada ação. Observe novamente após mudanças de tela e confirme o efeito real. Não alegue visão de telas protegidas ou dados que o Android não expõe. Para controlar o celular, a Acessibilidade do NETWORK precisa estar ativada. Quando o usuário pedir explicitamente para enviar uma mensagem e destinatário e texto estiverem claros, execute sem pedir confirmação redundante. Pergunte apenas se destinatário ou texto estiverem ambíguos. Nunca envie mensagens que não foram solicitadas.';
  Future<void> stop() async {}
}

class ToolAgentService {
  ToolAgentService(this.ai,this.ssh,this.github);
  final BlackChatService ai;
  final SshManager ssh;
  final GithubService github;
  final NetworkWebTools _web = NetworkWebTools();
  http.Client _sessionClient = http.Client();
  http.Client? _activeClient;
  final Set<http.Client> _specialistClients = <http.Client>{};
  bool _stopped = false;
  String _activeUserPrompt = '';
  bool get _userExplicitlyRequestedSend => RegExp(r'\b(envi\w*|mand\w*|dispar\w*|public\w*|post\w*|send)\b',caseSensitive:false).hasMatch(_activeUserPrompt);
  bool _isSendActionLabel(String value) => RegExp(r'\b(enviar|send|publicar|postar|submit)\b',caseSensitive:false).hasMatch(value);
  static const _pendingTaskKey = 'network_agent_pending_task_v1';
  static const _channel = MethodChannel('micro/runtime');
  static const EventChannel _screenEvents = EventChannel('micro/screen_events');
  StreamSubscription<dynamic>? _screenSubscription;
  int _screenRevision = 0;
  int _lastScreenRevisionSent = 0;
  Map<String,dynamic>? _latestScreenEvent;
  Completer<int>? _screenChangeSignal;

  Future<Map<String,dynamic>?> pendingTask() async {
    final raw = (await SharedPreferences.getInstance()).getString(_pendingTaskKey);
    if (raw == null || raw.isEmpty) return null;
    try { return Map<String,dynamic>.from(jsonDecode(raw) as Map); } catch (_) { return null; }
  }

  Future<void> _saveCheckpoint(String prompt, List<Map<String,dynamic>> messages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTaskKey, jsonEncode({'prompt':prompt,'messages':messages,'updatedAt':DateTime.now().toIso8601String()}));
  }

  Future<void> _clearCheckpoint() async {
    await (await SharedPreferences.getInstance()).remove(_pendingTaskKey);
  }

  Future<void> stop() async {
    _stopped = true;
    for (final client in _specialistClients.toList()) { client.close(); }
    _specialistClients.clear();
    await _clearCheckpoint();
    try { await _channel.invokeMethod('agent_keep_alive_stop'); } catch (_) {}
    _activeClient?.close();
    _activeClient = null;
    _sessionClient = http.Client();
    await _screenSubscription?.cancel();
    _screenSubscription = null;
    try { await _channel.invokeMethod<bool>('phone_cancel_pending'); } catch (_) {}
  }

  List<Map<String,dynamic>> _availableTools(String context) {
    final tools = [
    {'type':'function','function':{'name':'media_generate_video','description':'Abre o estúdio de geração de vídeo integrado ao NETWORK com o prompt já preenchido e inicia a geração usando Puter.js. Não exige chave de desenvolvedor; Puter pode solicitar autenticação e usa a cota/cobrança da conta do usuário. Use para pedidos de vídeo ou animação.','parameters':{'type':'object','properties':{'prompt':{'type':'string','description':'Descrição completa do vídeo e movimentos desejados.'}},'required':['prompt']}}},
    {'type':'function','function':{'name':'media_generate_image','description':'Gera uma imagem real a partir de texto. Tenta primeiro AI Horde anônimo; se falhar, alterna para Vexa AI (gateway público de imagem). Baixa e salva o arquivo no armazenamento local do NETWORK. Nenhum dos dois exige chave pessoal; disponibilidade e limites variam. Use quando o usuário pedir para criar/desenhar/gerar uma imagem.','parameters':{'type':'object','properties':{'prompt':{'type':'string','description':'Descrição detalhada da imagem.'},'width':{'type':'integer','enum':[256,384,512]},'height':{'type':'integer','enum':[256,384,512]}},'required':['prompt']}}},
    {'type':'function','function':{'name':'agent_consult','description':'Consulta em paralelo até 2 especialistas do catálogo de 130. Use somente quando a tarefa for complexa e opiniões técnicas independentes melhorarem a resposta. Os especialistas analisam e recomendam; não executam ações. Você continua responsável pela decisão final. Escolha os IDs exibidos no catálogo contextual.','parameters':{'type':'object','properties':{'specialists':{'type':'array','minItems':1,'maxItems':2,'items':{'type':'string'}},'task':{'type':'string'},'context':{'type':'string'}},'required':['specialists','task']}}},
    {'type':'function','function':{'name':'agent_performance_report','description':'Retorna métricas de latência p50/p95 coletadas neste processo: eventos de Acessibilidade, inferência, especialistas e ferramentas.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'memory_list','description':'Lista as notas persistentes do usuário no NETWORK. Consulte antes de repetir decisões ou iniciar trabalhos em andamento.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'memory_search','description':'Busca contexto, decisões e histórico nas notas persistentes do NETWORK.','parameters':{'type':'object','properties':{'query':{'type':'string'}},'required':['query']}}},
    {'type':'function','function':{'name':'memory_save','description':'Salva uma decisão, preferência técnica ou estado importante para continuar em conversas futuras. Nunca salve senhas, tokens ou segredos.','parameters':{'type':'object','properties':{'title':{'type':'string'},'content':{'type':'string'}},'required':['title','content']}}},
    {'type':'function','function':{'name':'web_search','description':'Pesquisa na web em tempo real. Retorna títulos, URLs e trechos de fontes públicas. Use para fatos atuais, documentação, comparação e investigação.','parameters':{'type':'object','properties':{'query':{'type':'string','description':'Consulta de pesquisa objetiva e completa.'}},'required':['query']}}},
    {'type':'function','function':{'name':'web_open','description':'Abre uma página pública HTTP/HTTPS, extrai título e conteúdo textual para leitura e análise.','parameters':{'type':'object','properties':{'url':{'type':'string','description':'URL pública completa.'}},'required':['url']}}},
    {'type':'function','function':{'name':'ssh_list','description':'Lista servidores VPS cadastrados e informa quais estão conectados.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'ssh_exec','description':'Executa comandos reais em uma VPS para administrar, instalar, editar, compilar, testar e verificar projetos.','parameters':{'type':'object','properties':{'server':{'type':'string'},'command':{'type':'string'}},'required':['server','command']}}},
    {'type':'function','function':{'name':'local_shell_exec','description':'Executa comandos no Termux do celular para acessar arquivos, scripts, Git, Python e ferramentas locais.','parameters':{'type':'object','properties':{'command':{'type':'string'},'workdir':{'type':'string'}},'required':['command']}}},
    {'type':'function','function':{'name':'open_feature','description':'Abre uma seção do NETWORK: projects, terminal, vps, settings, memory, mcp ou browser.','parameters':{'type':'object','properties':{'feature':{'type':'string'}},'required':['feature']}}},
    {'type':'function','function':{'name':'github_repositories','description':'Lista repositórios GitHub da conta conectada.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_open_app_and_read','description':'Dispara a abertura do aplicativo e retorna sem esperar carregamento. Depois use phone_tap_text ou phone_wait_for_text: elas observam eventos de Acessibilidade e agem assim que o elemento necessário aparecer.','parameters':{'type':'object','properties':{'package':{'type':'string'}},'required':['package']}}},
    {'type':'function','function':{'name':'phone_browser_search','description':'Dispara imediatamente a pesquisa no navegador padrão, sem esperar carregamento completo. Acompanhe a tela pelos eventos de Acessibilidade e interaja assim que o elemento necessário aparecer.','parameters':{'type':'object','properties':{'query':{'type':'string'}},'required':['query']}}},
    {'type':'function','function':{'name':'phone_batch','description':'Executa de 1 a 10 ações Android sequenciais dentro de UMA chamada, evitando uma nova inferência do modelo entre cada toque/digitação. PREFIRA esta ferramenta para sequências previsíveis (ex.: abrir app, aguardar um rótulo, tocar, focar e digitar); use wait_for_text somente quando o elemento ainda não estiver presente. Agrupe ações com dependências claras usando os rótulos observados; não faça uma chamada separada do modelo para cada passo mecânico. A execução para no primeiro erro e retorna a tela atual ao final. Envio/publicação é permitido quando o usuário solicitou explicitamente e destinatário/conteúdo estão claros; não peça confirmação redundante. Pagamentos, transferências, compras, exclusões e concessões de permissões exigem autorização específica e nunca entram no lote.','parameters':{'type':'object','properties':{'actions':{'type':'array','minItems':1,'maxItems':10,'items':{'type':'object','properties':{'tool':{'type':'string','enum':['tap_text','wait_for_text','type_text','focus_input','scroll','press_back','read_screen','open_app','browser_search','open_app_window','list_windows','window_read','window_tap_text','window_type_text','window_scroll']},'args':{'type':'object'}},'required':['tool','args']}}},'required':['actions']}}},
    {'type':'function','function':{'name':'phone_open_app','description':'Abre um aplicativo Android pelo pacote. WhatsApp: com.whatsapp; WhatsApp Business: com.whatsapp.w4b.','parameters':{'type':'object','properties':{'package':{'type':'string'}},'required':['package']}}},
    {'type':'function','function':{'name':'phone_open_app_window','description':'Abre apps em janela independente. Em Samsung, inicia o app e abre Recentes para a IA tocar no ícone do cartão e selecionar \'Abrir na exibição pop-up\'; depois confirme a janela com phone_window_list. Em outros Androids, solicita freeform/multijanela quando disponível. Nunca declare sucesso sem confirmar a janela.','parameters':{'type':'object','properties':{'package':{'type':'string'}},'required':['package']}}},
    {'type':'function','function':{'name':'phone_list_apps','description':'Inventário de aplicativos instalados: nome humano, pacote e se possui lançador. Use para resolver nomes antes de abrir apps; não adivinhe pacotes.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_android_sensitivity','description':'Auditoria de permissões e capacidades do Android: permissões runtime do NETWORK, acessibilidade, sobreposição, notificações, acesso de uso, captura de tela temporária, versão Android e limitações. Consulta somente; não concede permissões.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_screen_read','description':'Lê a tela atual do Android por Acessibilidade, incluindo textos, campos e controles.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_screen_ocr_capture','description':'Solicita captura de tela autorizada pelo Android e extrai texto por OCR quando Acessibilidade não expõe o conteúdo.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_wait_for_text','description':'Aguarda eventos reais de Acessibilidade até o texto aparecer, sem prazo artificial; interrompível pelo usuário. Aceita alternativas separadas por |.','parameters':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}}},
    {'type':'function','function':{'name':'phone_tap_text','description':'Localiza o texto pela Acessibilidade e toca imediatamente no evento em que aparecer. Sem prazo artificial; interrompível pelo usuário. Aceita alternativas separadas por |.','parameters':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}}},
    {'type':'function','function':{'name':'phone_tap','description':'Toca na tela usando coordenadas x e y lidas da tela.','parameters':{'type':'object','properties':{'x':{'type':'number'},'y':{'type':'number'}},'required':['x','y']}}},
    {'type':'function','function':{'name':'phone_long_press','description':'Pressiona e segura a tela nas coordenadas x e y.','parameters':{'type':'object','properties':{'x':{'type':'number'},'y':{'type':'number'},'duration':{'type':'integer'}},'required':['x','y']}}},
    {'type':'function','function':{'name':'phone_swipe','description':'Desliza a tela de x1,y1 até x2,y2.','parameters':{'type':'object','properties':{'x1':{'type':'number'},'y1':{'type':'number'},'x2':{'type':'number'},'y2':{'type':'number'},'duration':{'type':'integer'}},'required':['x1','y1','x2','y2']}}},
    {'type':'function','function':{'name':'phone_focus_input','description':'Foca imediatamente o campo editável visível; se ainda não existir, aguarda eventos até aparecer. Sem prazo artificial; interrompível pelo usuário.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_type_text','description':'Digita texto no campo atualmente focado no Android.','parameters':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}}},
    {'type':'function','function':{'name':'phone_scroll','description':'Rola a tela para cima ou para baixo.','parameters':{'type':'object','properties':{'direction':{'type':'string','enum':['up','down']}},'required':['direction']}}},
    {'type':'function','function':{'name':'phone_press_back','description':'Executa a ação Voltar do Android.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_window_list','description':'Lista todas as janelas de aplicativos que o serviço de Acessibilidade consegue enxergar, incluindo pacote, ID, foco e limites. Use para confirmar quais apps realmente estão em janelas independentes.','parameters':{'type':'object','properties':{}}}},
    {'type':'function','function':{'name':'phone_window_read','description':'Lê os elementos da janela independente de um aplicativo pelo pacote, sem mudar o foco nem tocar na tela principal.','parameters':{'type':'object','properties':{'package':{'type':'string'},'window_id':{'type':'integer'}},'required':['package']}}},
    {'type':'function','function':{'name':'phone_window_tap_text','description':'Aciona um elemento pelo texto dentro da janela do pacote informado usando ACTION_CLICK da Acessibilidade. Nunca envia toque global nem gestos na tela que o usuário está usando.','parameters':{'type':'object','properties':{'package':{'type':'string'},'window_id':{'type':'integer'},'text':{'type':'string'}},'required':['package','text']}}},
    {'type':'function','function':{'name':'phone_window_type_text','description':'Define texto diretamente em um campo editável da janela informada usando ACTION_SET_TEXT, sem teclado global ou digitação por toques.','parameters':{'type':'object','properties':{'package':{'type':'string'},'window_id':{'type':'integer'},'text':{'type':'string'}},'required':['package','text']}}},
    {'type':'function','function':{'name':'phone_window_scroll','description':'Rola um contêiner dentro da janela informada usando ações semânticas de Acessibilidade. Não usa swipe global.','parameters':{'type':'object','properties':{'package':{'type':'string'},'window_id':{'type':'integer'},'direction':{'type':'string','enum':['up','down']}},'required':['package','direction']}}}
    ,{'type':'function','function':{'name':'phone_window_capabilities','description':'Verifica suporte do Android a multijanela, sobreposição e limitações de memória.','parameters':{'type':'object','properties':{}}}}
    ];
    // Expose Android mutations only through phone_batch to avoid a model round-trip per tap/type.
    const individualPhoneActions = <String>{
      'phone_open_app_and_read', 'phone_browser_search', 'phone_open_app',
      'phone_open_app_window', 'phone_tap_text', 'phone_tap',
      'phone_long_press', 'phone_swipe', 'phone_wait_for_text',
      'phone_focus_input', 'phone_type_text', 'phone_scroll',
      'phone_press_back', 'phone_window_tap_text',
      'phone_window_type_text', 'phone_window_scroll',
    };
    tools.removeWhere((tool) {
      final function = (tool['function'] as Map?) ?? const {};
      return individualPhoneActions.contains(function['name']);
    });

    // Send only the tool schemas relevant to this request and recent context.
    // Large unrelated schemas increase prompt tokens and slow every model turn.
    final normalized = context.toLowerCase();
    final wantsAndroid = RegExp(r'android|celular|telefone|smartphone|app|whatsapp|telegram|notifica|permiss[aã]o|acessibilidade|tela|aplicativo|abrir app|toque|digitar|clicar|janela flutuante|pop.?up|aparelho|mobile').hasMatch(normalized);
    final wantsInfra = RegExp(r'vps|servidor|ssh|terminal|linux|debian|docker|deploy|instalar|compilar|apk|build|github|reposit[oó]rio|bot|site|projeto|c[oó]digo|programar|script|arquivo').hasMatch(normalized);
    final wantsGithub = RegExp(r'github|reposit[oó]rio|commit|branch|pull request|actions|workflow|release|apk|build').hasMatch(normalized);
    final wantsWeb = RegExp(r'pesquis|internet|site|url|link|documenta[cç][aã]o|not[ií]cia|atual|pre[cç]o|compar|web|navegador|browser|busca').hasMatch(normalized);
    final wantsMedia = RegExp(r'gerar imagem|criar imagem|desenhar|imagem|foto|ilustra[cç][aã]o|v[ií]deo|anima[cç][aã]o').hasMatch(normalized);
    tools.removeWhere((tool) {
      final function = (tool['function'] as Map?) ?? const {};
      final name = function['name']?.toString() ?? '';
      if (name.startsWith('phone_')) return !wantsAndroid;
      if (name == 'ssh_list' || name == 'ssh_exec' || name == 'local_shell_exec') return !wantsInfra;
      if (name == 'github_repositories') return !wantsGithub;
      if (name == 'web_search' || name == 'web_open') return !wantsWeb;
      if (name == 'media_generate_image' || name == 'media_generate_video') return !wantsMedia;
      return false;
    });
    return tools;
  }

  Future<Map<String,dynamic>> _streamTurn({
    required String endpoint, required String model, required String token,
    required List<Map<String,dynamic>> messages, required List<Map<String,dynamic>> tools,
    required void Function(String) onTextChunk,
    http.Client? requestClient,
  }) async {
    final client = requestClient ?? _sessionClient;
    final latency = Stopwatch()..start();
    var firstTokenRecorded = false;
    void recordFirstToken() {
      if (firstTokenRecorded) return;
      firstTokenRecorded = true;
      AgentPerformanceMetrics.record(
        requestClient == null ? 'model.time_to_first_token' : 'specialist.time_to_first_token',
        latency.elapsed,
      );
    }
    if (endpoint == 'https://vexa-ai.pages.dev') {
      if (requestClient == null) _activeClient = client;
      try {
        final request = http.Request('POST',Uri.parse('$endpoint/chat'))
          ..headers.addAll({'Content-Type':'application/json','Accept':'text/event-stream'})
          ..body = jsonEncode({'model':model,'messages':messages});
        final response = await client.send(request).timeout(const Duration(seconds:20));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.stream.bytesToString().timeout(const Duration(seconds:20));
          throw HttpException('Vexa AI chat HTTP ${response.statusCode}: $body');
        }
        final content = StringBuffer();
        await for (final line in response.stream.timeout(const Duration(seconds:20)).transform(utf8.decoder).transform(const LineSplitter())) {
          if (_stopped) throw StateError('Execução interrompida');
          if (!line.startsWith('data:')) continue;
          final eventText = line.substring(5).trim();
          if (eventText.isEmpty || eventText == '[DONE]') continue;
          final event = jsonDecode(eventText) as Map<String,dynamic>;
          if (event['error'] != null) throw StateError('Vexa AI: ${event['error']}');
          final choices = event['choices'] as List? ?? const [];
          if (choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'];
          final part = delta is Map ? delta['content'] : null;
          if (part is String && part.isNotEmpty) {
            recordFirstToken();
            content.write(part);
            onTextChunk(part);
          }
        }
        return {'role':'assistant','content':content.toString()};
      } finally {
        AgentPerformanceMetrics.record(requestClient == null ? 'model.inference' : 'specialist.inference',latency.elapsed);
        if (requestClient == null && identical(_activeClient,client)) _activeClient = null;
      }
    }
    if (requestClient == null) _activeClient = client;
    try {
      final payload = <String,dynamic>{'model':model,'messages':messages,'stream':true,'max_tokens':4096};
      if (tools.isNotEmpty) {
        payload['tools'] = tools;
        payload['tool_choice'] = 'auto';
        payload['parallel_tool_calls'] = true;
      }
      final request = http.Request('POST',Uri.parse(endpoint+'/chat/completions'))
        ..headers.addAll({'Content-Type':'application/json','Accept':'text/event-stream, application/json'})
        ..body = jsonEncode(payload);
      if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer '+token;
      final response = await client.send(request).timeout(const Duration(seconds:10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString().timeout(const Duration(seconds:20));
        final retryAfter = response.headers['retry-after'];
        final requestId = response.headers['x-request-id'];
        final retryHint = retryAfter == null ? '' : ' Aguarde pelo menos $retryAfter antes de tentar novamente.';
        final requestHint = requestId == null ? '' : ' ID da solicitação: $requestId.';
        throw HttpException('IA HTTP '+response.statusCode.toString()+': '+body+retryHint+requestHint);
      }
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('text/event-stream')) {
        final body = await response.stream.bytesToString().timeout(const Duration(seconds:20));
        final data = jsonDecode(body) as Map<String,dynamic>;
        final choice = (data['choices'] as List).first as Map<String,dynamic>;
        final message = Map<String,dynamic>.from(choice['message'] as Map);
        final content = message['content']?.toString() ?? '';
        if (content.isNotEmpty) { recordFirstToken(); onTextChunk(content); }
        return message;
      }
      final content = StringBuffer();
      final toolCalls = <int,Map<String,dynamic>>{};
      await for (final line in response.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(seconds:20))) {
        if (_stopped) throw StateError('Execução interrompida');
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        final event = jsonDecode(payload) as Map<String,dynamic>;
        final choices = event['choices'] as List? ?? const [];
        if (choices.isEmpty) continue;
        final delta = Map<String,dynamic>.from((choices.first as Map)['delta'] as Map? ?? const {});
        final part = delta['content'];
        if ((part is String && part.isNotEmpty) || ((delta['tool_calls'] as List?)?.isNotEmpty ?? false)) recordFirstToken();
        if (part is String && part.isNotEmpty) {
          content.write(part);
          onTextChunk(part);
        }
        for (final raw in (delta['tool_calls'] as List? ?? const [])) {
          final item = Map<String,dynamic>.from(raw as Map);
          final index = (item['index'] as num?)?.toInt() ?? 0;
          final current = toolCalls.putIfAbsent(index,()=>{'id':'','type':'function','function':{'name':'','arguments':''}});
          if (item['id'] != null) current['id'] = item['id'];
          final fn = Map<String,dynamic>.from(current['function'] as Map);
          final incoming = Map<String,dynamic>.from(item['function'] as Map? ?? const {});
          if (incoming['name'] != null) fn['name'] = fn['name'].toString()+incoming['name'].toString();
          if (incoming['arguments'] != null) fn['arguments'] = fn['arguments'].toString()+incoming['arguments'].toString();
          current['function'] = fn;
        }
      }
      final message = <String,dynamic>{'role':'assistant','content':content.toString()};
      if (toolCalls.isNotEmpty) {
        final sorted = toolCalls.entries.toList()..sort((a,b)=>a.key.compareTo(b.key));
        message['tool_calls'] = sorted.map((e)=>e.value).toList();
      }
      return message;
    } finally {
      AgentPerformanceMetrics.record(requestClient == null ? 'model.inference' : 'specialist.inference', latency.elapsed);
      if (requestClient == null && identical(_activeClient,client)) _activeClient = null;
    }
  }

  Future<Map<String,dynamic>> _streamTurnWithRetry({
    required String endpoint,
    required String model,
    required String token,
    required List<Map<String,dynamic>> messages,
    required List<Map<String,dynamic>> tools,
    required void Function(String) onTextChunk,
    required void Function(String) onProgress,
  }) async {
    // Nunca encaminhe silenciosamente conversas, arquivos ou dados do usuário
    // para um provedor terceiro que não foi escolhido nas configurações.
    // O endpoint/modelo configurados são a única origem de inferência.
    if (_stopped) throw StateError('Execução interrompida pelo usuário.');
    try {
      return await _streamTurn(
        endpoint: endpoint,
        model: model,
        token: token,
        messages: messages,
        tools: tools,
        onTextChunk: onTextChunk,
      ).timeout(const Duration(seconds: 90));
    } catch (error) {
      if (_stopped) rethrow;
      final errorText = error.toString();
      final match = RegExp(r'IA HTTP (\d{3})').firstMatch(errorText);
      final status = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
      String explanation;
      switch (status) {
        case 400:
        case 404:
          explanation = 'modelo ou formato de solicitação não aceito; confira o ID do modelo e os recursos de ferramentas';
          break;
        case 401:
        case 403:
          explanation = 'chave/API sem autorização para este provedor ou modelo';
          break;
        case 402:
          explanation = 'saldo/créditos insuficientes no provedor';
          break;
        case 413:
          explanation = 'solicitação grande demais; reduza anexos ou histórico';
          break;
        case 429:
          explanation = 'limite de requisições atingido; aguarde o Retry-After informado pelo provedor';
          break;
        case 500:
        case 502:
        case 503:
          explanation = 'o provedor ou a infraestrutura upstream está temporariamente indisponível';
          break;
        default:
          explanation = error is TimeoutException
              ? 'o provedor excedeu o limite de 90 segundos'
              : 'falha de conexão ou resposta do provedor';
      }
      if (error is TimeoutException || error is SocketException ||
          error is http.ClientException || error is HandshakeException ||
          error is TlsException) {
        final previousClient = _sessionClient;
        _sessionClient = http.Client();
        if (identical(_activeClient, previousClient)) _activeClient = null;
        previousClient.close();
      }
      onProgress('Falha no provedor configurado: $explanation');
      throw StateError('IA indisponível: $explanation. Nenhum provedor alternativo recebeu sua conversa. Detalhe técnico: $error');
    }
  }

  Future<Directory> _memoryDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/NETWORK/Memory');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<List<Map<String,dynamic>>> _searchMemory(String query) async {
    final directory = await _memoryDirectory();
    // Keep automatic memory retrieval bounded: a huge note folder must not
    // turn every short chat message into a slow filesystem scan/context dump.
    final files = directory.listSync(followLinks:false).whereType<File>().take(200).toList();
    final terms = query.toLowerCase().split(RegExp(r'[^a-z0-9À-ÿ]+')).where((e) => e.length > 2).toSet();
    final matches = <Map<String,dynamic>>[];
    for (final file in files) {
      try {
        final content = await file.readAsString();
        final lower = content.toLowerCase();
        final score = terms.fold<int>(0, (sum, term) => sum + (lower.split(term).length - 1));
        if (query.trim().isEmpty || score > 0) {
          matches.add({'file':file.uri.pathSegments.last,'score':score,'content':content});
        }
      } catch (_) { continue; }
    }
    matches.sort((a,b) {
      final byScore = (b['score'] as int).compareTo(a['score'] as int);
      return byScore != 0 ? byScore : (b['file'] as String).compareTo(a['file'] as String);
    });
    return matches.take(4).map((item) {
      final content = item['content'] as String;
      return {...item,'content':content.length > 1800 ? content.substring(0,1800) : content};
    }).toList();
  }

  Future<Map<String,dynamic>> _saveMemory(String title, String content) async {
    if (title.trim().isEmpty || content.trim().isEmpty) throw ArgumentError('Título e conteúdo são obrigatórios.');
    final directory = await _memoryDirectory();
    final slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    final name = '${DateTime.now().millisecondsSinceEpoch}-${slug.isEmpty ? 'nota' : slug}.txt';
    final file = File('${directory.path}/$name');
    await file.writeAsString('TÍTULO: ${title.trim()}\nDATA: ${DateTime.now().toIso8601String()}\n\n${content.trim()}');
    return {'saved':true,'file':name,'path':file.path};
  }

  static const Set<String> _readOnlyTools = {'agent_consult','agent_performance_report','ssh_list','github_repositories','web_search','web_open','memory_list','memory_search','phone_list_apps','phone_android_sensitivity','phone_screen_read','phone_screen_ocr_capture','phone_window_capabilities','phone_window_list','phone_window_read','phone_wait_for_text'};

  static Future<Map<String,dynamic>> readCurrentScreenOcr() async {
    final service = ToolAgentService._screenOcrFactory();
    return service;
  }

  static Future<Map<String,dynamic>> _screenOcrFactory() async {
    final channel = const MethodChannel('micro/runtime');
    final path = await channel.invokeMethod<String>('phone_screen_ocr_capture');
    if (path == null || path.trim().isEmpty) throw StateError('O Android não retornou o arquivo da captura de tela.');
    final file = File(path);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(path));
      return {'success':true,'source':'android_media_projection_plus_mlkit_ocr','text':result.text,'blocks':result.blocks.map((b)=>{'text':b.text,'bounds':{'left':b.boundingBox.left,'top':b.boundingBox.top,'right':b.boundingBox.right,'bottom':b.boundingBox.bottom}}).toList()};
    } finally { await recognizer.close(); try { if (await file.exists()) await file.delete(); } catch (_) {} }
  }

  Future<Map<String,dynamic>> _captureAndReadScreen() async {
    final path = await _channel.invokeMethod<String>('phone_screen_ocr_capture');
    if (path == null || path.trim().isEmpty) {
      throw StateError('O Android não retornou o arquivo da captura de tela.');
    }
    final file = File(path);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final image = InputImage.fromFilePath(path);
      final result = await recognizer.processImage(image);
      final blocks = result.blocks.map((block) {
        final rect = block.boundingBox;
        return <String,dynamic>{
          'text': block.text,
          'bounds': {'left':rect.left,'top':rect.top,'right':rect.right,'bottom':rect.bottom},
          'lines': block.lines.map((line) {
            final lineRect = line.boundingBox;
            return <String,dynamic>{
              'text':line.text,
              'bounds': {'left':lineRect.left,'top':lineRect.top,'right':lineRect.right,'bottom':lineRect.bottom},
            };
          }).toList(),
        };
      }).toList();
      return {
        'success': true,
        'source': 'android_media_projection_plus_mlkit_ocr',
        'text': result.text,
        'blocks': blocks,
        'message': result.text.trim().isEmpty
            ? 'A captura foi feita, mas nenhum texto foi reconhecido. Use acessibilidade ou tente outra estratégia visual.'
            : 'Captura e OCR concluídos.',
      };
    } finally {
      await recognizer.close();
      try { if (await file.exists()) await file.delete(); } catch (_) {}
    }
  }

  Future<Map<String,dynamic>> _executePhoneBatch(List<dynamic> actions) async {
    if (actions.isEmpty) {
      throw ArgumentError('phone_batch precisa conter ao menos uma ação.');
    }
    if (actions.length > 10) {
      throw ArgumentError('Use no máximo dez ações sequenciais por lote.');
    }
    final completed = <Map<String,dynamic>>[];
    var success = true;
    for (var index = 0; index < actions.length; index++) {
      if (_stopped) throw StateError('Execução interrompida pelo usuário.');
      final raw = actions[index];
      if (raw is! Map) throw FormatException('Ação ${index + 1} inválida.');
      final step = Map<String,dynamic>.from(raw);
      final name = step['tool']?.toString() ?? '';
      final args = Map<String,dynamic>.from((step['args'] as Map?) ?? const {});
      dynamic result;
      try {
        switch (name) {
          case 'tap_text':
            final target = args['text']?.toString() ?? '';
            if (_isSendActionLabel(target) && !_userExplicitlyRequestedSend) {
              throw StateError('Envio bloqueado: o pedido original não autorizou enviar/publicar.');
            }
            if (RegExp(r'\b(pagar|pay|transferir|excluir|apagar|delete|comprar|purchase|permitir|allow|autorizar|authorize|checkout)\b',caseSensitive:false).hasMatch(target)) {
              throw StateError('Ação crítica retirada do lote. Observe a tela e decida/autorize separadamente.');
            }
            // Um elemento ausente nunca pode deixar a automação pendurada.
            result = await _channel.invokeMethod<dynamic>('phone_tap_text',{'text':target,'timeoutMs':1800})
                .timeout(const Duration(milliseconds:2500));
            break;
          case 'wait_for_text':
            result = await _channel.invokeMethod<dynamic>('phone_wait_for_text',{'text':args['text']?.toString() ?? '', 'timeoutMs':2500})
                .timeout(const Duration(seconds:3));
            break;
          case 'type_text':
            result = await _channel.invokeMethod<dynamic>('phone_type_text',{'text':args['text']?.toString() ?? ''});
            break;
          case 'focus_input':
            result = await _channel.invokeMethod<dynamic>('phone_focus_input',{'timeoutMs':1200})
                .timeout(const Duration(seconds:2));
            break;
          case 'scroll':
            result = await _channel.invokeMethod<dynamic>('phone_scroll',{'direction':args['direction']?.toString() ?? 'down'});
            break;
          case 'press_back':
            result = await _channel.invokeMethod<dynamic>('phone_press_back');
            break;
          case 'read_screen':
            result = await _channel.invokeMethod<dynamic>('phone_screen_read');
            break;
          case 'open_app':
            final app = (args['app'] ?? args['package'] ?? '').toString();
            result = await _channel.invokeMethod<dynamic>('open_app_resolved',{'app':app});
            break;
          case 'browser_search':
            result = await _channel.invokeMethod<dynamic>('phone_browser_search',{'query':args['query']?.toString() ?? ''});
            break;
          case 'open_app_window':
            result = await _channel.invokeMethod<dynamic>('phone_open_app_window',{'package':args['package']?.toString() ?? ''});
            break;
          case 'list_windows':
            result = await _channel.invokeMethod<dynamic>('phone_window_list');
            break;
          case 'window_read':
            result = await _channel.invokeMethod<dynamic>('phone_window_read',{'package':args['package']?.toString() ?? '', 'window_id':args['window_id']});
            break;
          case 'window_tap_text':
            final target = args['text']?.toString() ?? '';
            if (_isSendActionLabel(target) && !_userExplicitlyRequestedSend) {
              throw StateError('Envio bloqueado: o pedido original não autorizou enviar/publicar.');
            }
            result = await _channel.invokeMethod<dynamic>('phone_window_tap_text',{'package':args['package']?.toString() ?? '', 'window_id':args['window_id'], 'text':args['text']?.toString() ?? ''});
            break;
          case 'window_type_text':
            result = await _channel.invokeMethod<dynamic>('phone_window_type_text',{'package':args['package']?.toString() ?? '', 'window_id':args['window_id'], 'text':args['text']?.toString() ?? ''});
            break;
          case 'window_scroll':
            result = await _channel.invokeMethod<dynamic>('phone_window_scroll',{'package':args['package']?.toString() ?? '', 'window_id':args['window_id'], 'direction':args['direction']?.toString() ?? 'down'});
            break;
          default:
            throw ArgumentError('Ação não permitida no lote: $name');
        }
      } catch (error) {
        completed.add({'step':index + 1,'tool':name,'success':false,'error':error.toString()});
        success = false;
        break;
      }
      final failed = result == false ||
          (result is Map && result['success'] == false) ||
          (result is String && (result.startsWith('ERRO:') || result.startsWith('APP_NAO_DISPONIBILIZOU_JANELA') || result.startsWith('JANELA_NAO_ENCONTRADA') || result.startsWith('JANELA_FLUTUANTE_NAO_SUPORTADA')));
      completed.add({'step':index + 1,'tool':name,'success':!failed,'result':result});
      if (failed) { success = false; break; }
    }
    dynamic screen;
    try { screen = await _channel.invokeMethod<dynamic>('phone_screen_read'); }
    catch (error) { screen = {'error':error.toString()}; }
    return {'success':success && completed.length == actions.length,'completed_steps':completed,'screen':screen};
  }
  
  Future<Map<String,dynamic>> _generateVexaImage(String prompt,{String model='flux'}) async {
    final response = await http.post(
      Uri.parse('https://vexa-ai.pages.dev/image'),
      headers: {'Content-Type':'application/json','Accept':'application/json'},
      body: jsonEncode({'prompt':prompt.trim(),'model':model}),
    ).timeout(const Duration(seconds:90));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Vexa AI imagem HTTP ${response.statusCode}: ${response.body}');
    }
    final payload = jsonDecode(response.body) as Map<String,dynamic>;
    if (payload['success'] != true) throw StateError('Vexa AI não concluiu a imagem: ${payload['error'] ?? 'resposta inválida'}');
    final imageUrl = payload['proxy_url']?.toString();
    if (imageUrl == null || imageUrl.isEmpty) throw StateError('Vexa AI não retornou a URL da imagem.');
    final image = await http.get(Uri.parse(imageUrl)).timeout(const Duration(seconds:45));
    if (image.statusCode != 200 || image.bodyBytes.isEmpty) throw HttpException('Falha ao baixar imagem Vexa (HTTP ${image.statusCode}).');
    final docs = await getApplicationDocumentsDirectory();
    final directory = Directory('${docs.path}/NETWORK/Generated');
    if (!await directory.exists()) await directory.create(recursive:true);
    final mime = (image.headers['content-type'] ?? '').toLowerCase();
    final extension = mime.contains('webp') ? 'webp' : mime.contains('jpeg') || mime.contains('jpg') ? 'jpg' : 'png';
    final file = File('${directory.path}/image-vexa-${DateTime.now().millisecondsSinceEpoch}.$extension');
    await file.writeAsBytes(image.bodyBytes,flush:true);
    return {'success':true,'provider':'Vexa AI · gateway público','model':payload['model']?.toString() ?? model,'imageUrl':imageUrl,'savedPath':file.path,'bytes':image.bodyBytes.length,'note':'Gateway comunitário sujeito a limites por IP e disponibilidade do provedor upstream.'};
  }

  Future<Map<String,dynamic>> _generateVexaImageWithFailover(String prompt) async {
    final failures = <String>[];
    for (final model in const ['flux','turbo-img','kontext','seedream','nanobanana','hd']) {
      try {
        return await _generateVexaImage(prompt,model:model);
      } catch (error) {
        failures.add('$model: $error');
      }
    }
    throw StateError('Todos os modelos Vexa falharam: ${failures.join(' | ')}');
  }

  Future<Map<String,dynamic>> _generateNetworkImage(String prompt,{int width=512,int height=512}) async {
    try {
      return await _generateHordeImage(prompt,width:width,height:height);
    } catch (hordeError) {
      try {
        return await _generateVexaImageWithFailover(prompt);
      } catch (vexaError) {
        throw StateError('Falha nos dois geradores públicos. AI Horde: $hordeError. Vexa AI: $vexaError');
      }
    }
  }

  Future<Map<String,dynamic>> _generateHordeImage(String prompt,{int width=512,int height=512}) async {
    if (prompt.trim().isEmpty) throw ArgumentError('Descreva a imagem que deseja gerar.');
    if (prompt.length > 2000) throw ArgumentError('O prompt da imagem excede 2000 caracteres.');
    final base = 'https://aihorde.net/api/v2';
    final headers = {'apikey':'0000000000','Client-Agent':'NETWORK:3.2.1:android','Content-Type':'application/json'};
    final submit = await http.post(Uri.parse('$base/generate/async'),headers:headers,body:jsonEncode({
      'prompt':prompt.trim(),
      'params':{'n':1,'width':width.clamp(256,512),'height':height.clamp(256,512),'steps':20,'sampler_name':'k_euler_a'},
      'nsfw':false,'censor_nsfw':true,
    })).timeout(const Duration(seconds:30));
    if (submit.statusCode != 202 && submit.statusCode != 200) {
      throw HttpException('AI Horde não aceitou a imagem (HTTP ${submit.statusCode}): ${submit.body}');
    }
    final requestId = (jsonDecode(submit.body) as Map<String,dynamic>)['id']?.toString();
    if (requestId == null || requestId.isEmpty) throw StateError('AI Horde não retornou ID da geração.');
    final deadline = DateTime.now().add(const Duration(minutes:4));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds:2));
      final check = await http.get(Uri.parse('$base/generate/check/$requestId'),headers:headers).timeout(const Duration(seconds:20));
      if (check.statusCode != 200) throw HttpException('AI Horde status HTTP ${check.statusCode}: ${check.body}');
      final state = jsonDecode(check.body) as Map<String,dynamic>;
      if (state['faulted'] == true) throw StateError('AI Horde marcou a geração como falha.');
      if (state['done'] == true) {
        final result = await http.get(Uri.parse('$base/generate/status/$requestId'),headers:headers).timeout(const Duration(seconds:30));
        if (result.statusCode != 200) throw HttpException('AI Horde resultado HTTP ${result.statusCode}.');
        final payload = jsonDecode(result.body) as Map<String,dynamic>;
        final generations = (payload['generations'] as List?) ?? const [];
        if (generations.isEmpty || generations.first is! Map) throw StateError('AI Horde concluiu sem retornar imagem.');
        final imageUrl = (generations.first as Map)['img']?.toString();
        if (imageUrl == null || imageUrl.isEmpty) throw StateError('AI Horde não retornou URL da imagem.');
        final imageResponse = await http.get(Uri.parse(imageUrl)).timeout(const Duration(seconds:45));
        if (imageResponse.statusCode != 200 || imageResponse.bodyBytes.isEmpty) throw HttpException('Falha ao baixar imagem gerada (HTTP ${imageResponse.statusCode}).');
        final docs = await getApplicationDocumentsDirectory();
        final directory = Directory('${docs.path}/NETWORK/Generated');
        if (!await directory.exists()) await directory.create(recursive:true);
        final rawExtension = Uri.parse(imageUrl).path.split('.').last.toLowerCase();
        final extension = const {'png','webp','jpg','jpeg'}.contains(rawExtension) ? rawExtension : 'png';
        final file = File('${directory.path}/image-${DateTime.now().millisecondsSinceEpoch}.$extension');
        await file.writeAsBytes(imageResponse.bodyBytes,flush:true);
        return {'success':true,'provider':'AI Horde (anônimo)','requestId':requestId,'model':(generations.first as Map)['model']?.toString(),'imageUrl':imageUrl,'savedPath':file.path,'bytes':imageResponse.bodyBytes.length,'note':'Fila comunitária: tempo e disponibilidade dependem de GPUs voluntárias.'};
      }
    }
    throw TimeoutException('A fila pública do AI Horde não concluiu a imagem em 4 minutos. ID: $requestId');
  }

  Future<dynamic> _executeTool(String name,Map<String,dynamic> args,{
    required String accessMode,
    required Future<bool> Function(String) confirmDangerous,
    required Future<String> Function(String) openAppFeature,
    bool modeAlreadyConfirmed = false,
  }) async {
    final isReadOnly = _readOnlyTools.contains(name);
    if (accessMode == 'readOnly' && !isReadOnly) return 'Ação bloqueada: o modo atual permite apenas leitura.';
    final confirmedForMode = accessMode == 'confirm' && !isReadOnly && !modeAlreadyConfirmed
        ? await confirmDangerous('Executar ferramenta $name com argumentos ${jsonEncode(args)}?')
        : modeAlreadyConfirmed;
    if (accessMode == 'confirm' && !isReadOnly && !confirmedForMode) return 'Ação cancelada pelo usuário.';
    final dangerous = RegExp(r'\b(rm\s+-rf|mkfs|shutdown|reboot|DROP\s+DATABASE)\b',caseSensitive:false);
    if (name == 'media_generate_image') return _generateNetworkImage(args['prompt'] as String,width:(args['width'] as num?)?.toInt() ?? 512,height:(args['height'] as num?)?.toInt() ?? 512);
    if (name == 'media_generate_video') { final prompt=(args['prompt'] as String).trim(); if(prompt.isEmpty) throw ArgumentError('Descreva o vídeo.'); await (await SharedPreferences.getInstance()).setString('network_pending_video_prompt',prompt); return await openAppFeature('video'); }
    if (name == 'memory_list') return _searchMemory('');
    if (name == 'memory_search') return _searchMemory(args['query'] as String);
    if (name == 'memory_save') return _saveMemory(args['title'] as String,args['content'] as String);
    if (name == 'web_search') return _web.search(args['query'] as String);
    if (name == 'web_open') return _web.open(args['url'] as String);
    if (name == 'ssh_list') {
      return (await ssh.targets()).map((t)=>{'name':t.name,'host':t.host,'connected':ssh.connected.contains(t.name)}).toList();
    }
    if (name == 'ssh_exec' || name == 'local_shell_exec') {
      final command = args['command'] as String;
      if (dangerous.hasMatch(command) && !confirmedForMode && !await confirmDangerous('Comando de alto risco: $command')) return 'Ação bloqueada pelo controle de segurança';
      if (name == 'ssh_exec') return ssh.executeWithStatus(args['server'] as String,command);
      return await _channel.invokeMethod<dynamic>('local_shell_exec',{'command':command,'workdir':args['workdir']?.toString() ?? ''}) ?? 'Termux não retornou saída.';
    }
    if (name == 'open_feature') return openAppFeature(args['feature'] as String);
    if (name == 'github_repositories') return github.repositories();
    if (name == 'phone_batch') return _executePhoneBatch(List<dynamic>.from(args['actions'] as List));
    if (name == 'phone_open_app_and_read') return _channel.invokeMethod<dynamic>('phone_open_app_and_read',{'package':args['package']});
    if (name == 'phone_browser_search') return _channel.invokeMethod<dynamic>('phone_browser_search',{'query':args['query']});
    if (name == 'phone_open_app') {
      final opened = await _channel.invokeMethod<bool>('launch_app',{'package':args['package']}) ?? false;
      return opened ? 'Aplicativo aberto.' : 'Aplicativo não instalado ou não foi possível abri-lo.';
    }
    if (name == 'phone_open_app_window') return _channel.invokeMethod<dynamic>('phone_open_app_window',{'package':args['package']});
    if (name == 'phone_list_apps') return _channel.invokeMethod<dynamic>('phone_list_apps');
    if (name == 'phone_android_sensitivity') return _channel.invokeMethod<dynamic>('phone_android_sensitivity');
    if (name == 'phone_screen_read') return _channel.invokeMethod<dynamic>('phone_screen_read');
    if (name == 'phone_screen_ocr_capture') return _captureAndReadScreen();
    if (name == 'phone_tap_text') return _channel.invokeMethod<dynamic>('phone_tap_text',{'text':args['text'],'timeoutMs':args['timeoutMs'] ?? 5000}).timeout(const Duration(seconds:7));
    if (name == 'phone_tap') return _channel.invokeMethod<dynamic>('phone_tap',{'x':args['x'],'y':args['y']});
    if (name == 'phone_long_press') return _channel.invokeMethod<dynamic>('phone_long_press',{'x':args['x'],'y':args['y'],'duration':args['duration'] ?? 900});
    if (name == 'phone_swipe') return _channel.invokeMethod<dynamic>('phone_swipe',{'x1':args['x1'],'y1':args['y1'],'x2':args['x2'],'y2':args['y2'],'duration':args['duration'] ?? 350});
    if (name == 'phone_wait_for_text') return _channel.invokeMethod<dynamic>('phone_wait_for_text',{'text':args['text'],'timeoutMs':args['timeoutMs'] ?? 8000}).timeout(const Duration(seconds:10));
    if (name == 'phone_focus_input') return _channel.invokeMethod<dynamic>('phone_focus_input',{'timeoutMs':args['timeoutMs'] ?? 4000}).timeout(const Duration(seconds:6));
    if (name == 'phone_type_text') return _channel.invokeMethod<dynamic>('phone_type_text',{'text':args['text']});
    if (name == 'phone_scroll') return _channel.invokeMethod<dynamic>('phone_scroll',{'direction':args['direction']});
    if (name == 'phone_press_back') return _channel.invokeMethod<dynamic>('phone_press_back');
    if (name == 'phone_window_capabilities') return _channel.invokeMethod<dynamic>('phone_window_capabilities');
    if (name == 'phone_window_list') return _channel.invokeMethod<dynamic>('phone_window_list');
    if (name == 'phone_window_read') return _channel.invokeMethod<dynamic>('phone_window_read',{'package':args['package'],'window_id':args['window_id']});
    if (name == 'phone_window_tap_text') return _channel.invokeMethod<dynamic>('phone_window_tap_text',{'package':args['package'],'window_id':args['window_id'],'text':args['text']});
    if (name == 'phone_window_type_text') return _channel.invokeMethod<dynamic>('phone_window_type_text',{'package':args['package'],'window_id':args['window_id'],'text':args['text']});
    if (name == 'phone_window_scroll') return _channel.invokeMethod<dynamic>('phone_window_scroll',{'package':args['package'],'window_id':args['window_id'],'direction':args['direction']});
    return 'Ferramenta desconhecida: '+name;
  }

  // Resolve asynchronous values recursively before passing tool results to JSON.
  // Some Android platform-channel responses may contain nested Future objects.
  Future<dynamic> _resolveJsonValue(dynamic value) async {
    if (value is Future) return _resolveJsonValue(await value);
    if (value is Map) {
      final resolved = <String, dynamic>{};
      for (final entry in value.entries) {
        resolved[entry.key.toString()] = await _resolveJsonValue(entry.value);
      }
      return resolved;
    }
    if (value is Uint8List) return base64Encode(value);
    if (value is Iterable) {
      final resolved = <dynamic>[];
      for (final item in value) {
        resolved.add(await _resolveJsonValue(item));
      }
      return resolved;
    }
    if (value == null || value is String || value is num || value is bool) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is Uri) return value.toString();
    throw StateError('Resultado de ferramenta contém tipo não serializável: ${value.runtimeType}');
  }

  Future<Map<String,dynamic>> _consultSpecialists(Map<String,dynamic> args, void Function(String) onProgress) async {
    final ids = (args['specialists'] as List? ?? const []).map((value) => value.toString()).toSet().toList();
    if (ids.isEmpty || ids.length > 2) throw ArgumentError('Escolha de 1 a 2 especialistas distintos.');
    final profiles = ids.map(AgentOrchestrator.find).toList();
    if (profiles.any((profile) => profile == null)) {
      final invalid = ids.where((id) => AgentOrchestrator.find(id) == null).join(', ');
      throw ArgumentError('Especialista não encontrado no catálogo: $invalid');
    }
    final task = args['task']?.toString().trim() ?? '';
    if (task.isEmpty || task.length > 12000) throw ArgumentError('Tarefa do especialista vazia ou muito longa.');
    final context = args['context']?.toString() ?? '';
    final endpoint = await ai.endpoint, model = await ai.model, token = await ai.apiKey;
    onProgress('Consultando ${profiles.length} especialistas em paralelo');
    final results = await Future.wait(profiles.map((profile) async {
      final specialist = profile!;
      final client = http.Client();
      _specialistClients.add(client);
      final elapsed = Stopwatch()..start();
      try {
        final specialistMessages = [
          {'role':'system','content':'Você é o especialista ${specialist.name}. ${specialist.guidance}\nAnalise somente a tarefa e o contexto fornecidos. Não execute ferramentas, não invente verificações e não assuma controle do usuário. Retorne riscos, fatos que precisam ser validados e uma recomendação objetiva em português.'},
          {'role':'user','content':'TAREFA:\n$task\n\nCONTEXTO DISPONÍVEL:\n${context.length > 12000 ? context.substring(0,12000) : context}'},
        ];
        // Especialistas usam o provedor configurado pelo usuário. Não percorra
        // provedores públicos em cascata: isso triplica a latência e pode enviar
        // contexto privado a serviços que não foram configurados.
        final response = await _streamTurn(
          endpoint:endpoint,model:model,token:token,
          messages:specialistMessages,tools:const [],onTextChunk:(_) {},requestClient:client,
        ).timeout(const Duration(seconds:28), onTimeout:() {
          client.close();
          throw TimeoutException('Especialista excedeu 28 segundos.');
        });
        return {'id':specialist.id,'name':specialist.name,'elapsedMs':elapsed.elapsedMicroseconds / 1000.0,'analysis':response['content']?.toString() ?? ''};
      } catch (error) {
        return {'id':specialist.id,'name':specialist.name,'elapsedMs':elapsed.elapsedMicroseconds / 1000.0,'error':error.toString()};
      } finally {
        AgentPerformanceMetrics.record('specialist.${specialist.domain}', elapsed.elapsed);
        _specialistClients.remove(client);
        client.close();
      }
    }));
    return {'requested':ids.length,'completed':results.where((r) => r['analysis'] != null).length,'maxConcurrency':2,'results':results};
  }

  Future<Map<String,dynamic>> _runToolCall(
    dynamic raw, {
    required String accessMode,
    required Future<bool> Function(String) confirmDangerous,
    required void Function(String) onProgress,
    required Future<String> Function(String) openAppFeature,
  }) async {
    final call = Map<String,dynamic>.from(raw as Map);
    final id = call['id']?.toString();
    final fn = Map<String,dynamic>.from(call['function'] as Map);
    final name = fn['name']?.toString() ?? 'unknown';
    final latency = Stopwatch()..start();
    try {
      final rawArguments = fn['arguments'];
      final decoded = jsonDecode(rawArguments is String ? rawArguments : '{}');
      if (decoded is! Map) throw FormatException('Argumentos da ferramenta precisam ser um objeto JSON.');
      final args = Map<String,dynamic>.from(decoded);
      final output = name == 'agent_consult'
          ? await _consultSpecialists(args,onProgress)
          : name == 'agent_performance_report'
              ? AgentPerformanceMetrics.snapshot()
              : await _executeTool(name,args,accessMode:accessMode,confirmDangerous:confirmDangerous,openAppFeature:openAppFeature);
      final safeOutput = await _resolveJsonValue(output);
      return {'role':'tool','tool_call_id':id ?? '', 'content':jsonEncode(safeOutput)};
    } catch (error) {
      return {'role':'tool','tool_call_id':id ?? '', 'content':jsonEncode({'error':error.toString(),'tool':name})};
    } finally {
      AgentPerformanceMetrics.record('tool.$name', latency.elapsed);
    }
  }

  Future<String> run({
    required String prompt, required String executionMode, required String accessMode,
    required List<Map<String,String>> history, required List<Map<String,String>> images,
    List<Map<String,dynamic>>? resumeMessages,
    required Future<bool> Function(String) confirmDangerous,
    required void Function(String) onProgress, required void Function(String) onTextChunk,
    required Future<String> Function(String) openAppFeature,
  }) async {
    _stopped = false;
    _activeUserPrompt = prompt;
    final taskLatency = Stopwatch()..start();
    AgentPerformanceMetrics.beginRun();
    await _screenSubscription?.cancel();
    _screenRevision = 0;
    _lastScreenRevisionSent = 0;
    _latestScreenEvent = null;
    _screenChangeSignal = null;
    try { await _channel.invokeMethod('agent_keep_alive_start'); } catch (_) {}
    _screenSubscription = _screenEvents.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final ingestLatency = Stopwatch()..start();
        _latestScreenEvent = Map<String,dynamic>.from(event);
        AgentPerformanceMetrics.recordMilliseconds('accessibility.event_age', (event['eventAgeMs'] as num?) ?? 0);
        AgentPerformanceMetrics.recordMilliseconds('accessibility.snapshot_build', (event['snapshotBuildMs'] as num?) ?? 0);
        _screenRevision++;
        AgentPerformanceMetrics.record('accessibility.dart_ingest', ingestLatency.elapsed);
        final signal = _screenChangeSignal;
        if (signal != null && !signal.isCompleted) signal.complete(_screenRevision);
      }
    }, onError: (_) {});
    final endpoint = await ai.endpoint, model = await ai.model, token = await ai.apiKey;
    final system = (await ai.systemPrompt)+
      '\nVocê é o agente executor do NETWORK. Cumpra o pedido diretamente, sem planos longos nem perguntas desnecessárias. Use ferramentas quando forem necessárias e verifique o resultado real; nunca invente sucesso.'+
      '\nDecida a próxima ação com base no resultado mais recente. Não repita ações concluídas. Para tarefas simples, aja sem consultar especialistas; consulte no máximo 1 a 2 somente quando isso realmente reduzir risco ou melhorar uma tarefa complexa.'+
      '\nPERCEPÇÃO ANDROID: comece pela ação solicitada usando phone_batch e a resolução de nome/pacote já disponível. NÃO faça auditoria de permissões nem inventário completo em toda tarefa. Consulte phone_list_apps somente se o nome do app for desconhecido/ambíguo ou se o usuário pedir a lista; consulte phone_android_sensitivity na primeira configuração, quando uma ação falhar por permissão ou quando o usuário pedir auditoria. Use a tela que phone_batch já retorna; só chame phone_screen_read novamente se o resultado não trouxer tela útil ou houver ambiguidade. Use OCR autorizado apenas quando a Acessibilidade não expuser o conteúdo necessário. Observe eventos e aja sobre os elementos atuais. Se faltar permissão, explique qual capacidade falta e peça ao usuário para habilitar; nunca tente conceder automaticamente. Nunca diga que viu conteúdo protegido ou inacessível.'+
      '\nAndroid: use exclusivamente phone_batch para ações que alteram a interface. NÃO espere o aplicativo terminar de carregar. Abra e tente imediatamente os elementos que já estiverem visíveis. Toque por texto usando a árvore de Acessibilidade atual; se o alvo ainda não existir, aguarde apenas o evento desse elemento por até 1,8 segundo e então releia a tela. Campo de entrada: tente foco imediato; se ainda não existir, não fique esperando vários segundos — releia o estado e continue quando aparecer. Agrupe passos mecânicos em uma chamada, sem uma nova inferência entre cada toque. A tela pode continuar carregando enquanto você trabalha; use o primeiro estado útil. Ações explicitamente solicitadas pelo usuário, como enviar uma mensagem com destinatário e texto claros, estão autorizadas e não devem gerar pedido de confirmação redundante. Nunca envie mensagem não solicitada. Para pagamentos, transferências, compras, exclusões e concessões de permissões, pare e peça autorização específica. Nunca opere um app em segundo plano com toques globais.'+
      '\nSamsung pop-up: confirme a janela independente com phone_window_list e opere somente pelas ferramentas phone_window_*; não use gestos globais para janela em segundo plano.'+
      '\nWeb, VPS, GitHub e arquivos: escolha a ferramenta adequada, execute o necessário e confira a saída. Ações destrutivas exigem confirmação. Respeite o modo de acesso.'+
      '\nResponda em português brasileiro, de forma direta. Modo de execução: '+executionMode+'. Modo de acesso: '+accessMode+'.';
    final messages = resumeMessages != null
        ? resumeMessages.map((m) => Map<String,dynamic>.from(m)).toList()
        : <Map<String,dynamic>>[
            {'role':'system','content':system},
            ...history.map((m)=>{'role':m['role'],'content':m['content']}),
            {'role':'user','content':images.isEmpty ? prompt : <Map<String,dynamic>>[{'type':'text','text':prompt}, ...images.map((image)=>{'type':'image_url','image_url':{'url':'data:'+image['mime']!+';base64,'+image['base64']!}})]}
          ];
    if (resumeMessages == null) {
      final relevantMemory = await _searchMemory(prompt);
      if (relevantMemory.isNotEmpty) {
        messages.insert(1, {'role':'system','content':'MEMÓRIA PERSISTENTE RELEVANTE (contexto salvo anteriormente; use apenas quando pertinente):\n'+jsonEncode(relevantMemory)});
      }
    } else if (messages.isNotEmpty && messages.last['role'] == 'assistant' && messages.last['tool_calls'] is List) {
      // A process may die after a UI action but before its result is checkpointed.
      // Never replay an uncertain side effect blindly: ask the model to inspect state.
      final pendingCalls = List<dynamic>.from(messages.last['tool_calls'] as List);
      for (final pending in pendingCalls) {
        final call = Map<String,dynamic>.from(pending as Map);
        messages.add({
          'role':'tool',
          'tool_call_id':call['id']?.toString() ?? '',
          'content':jsonEncode({'interrupted':true,'instruction':'O processo foi interrompido durante esta ação e o resultado é desconhecido. NÃO repita a ação automaticamente. Inspecione o estado atual e confirme se ela já aconteceu; só então continue o objetivo original.'})
        });
      }
    }
    if (_stopped) throw StateError('Execução interrompida');
    onProgress('CONSULTANDO AGENTE');
    final recentContext = messages.where((message) => message['role'] == 'user' || message['role'] == 'assistant')
        .toList().reversed.take(8).map((message) {
          final value = message['content'];
          return value is String ? value.substring(0, value.length > 1200 ? 1200 : value.length) : '';
        }).join('\n');
    final availableTools = _availableTools('$prompt\n$recentContext');
    final specialistRoutingLatency = Stopwatch()..start();
    final specialistDirectory = AgentOrchestrator.directoryFor(prompt, limit:8);
    AgentPerformanceMetrics.record('agents.local_routing', specialistRoutingLatency.elapsed);
    messages.add({'role':'system','content':'CATÁLOGO CONTEXTUAL DE ESPECIALISTAS (130 perfis registrados; candidatos locais mais relevantes para esta tarefa):\n$specialistDirectory\nVocê escolhe se precisa delegar. Para tarefas simples ou urgentes, não delegue. Para tarefas complexas, pode chamar agent_consult com 1 a 2 especialistas independentes, em uma única chamada; eles apenas analisam, não executam ferramentas. Você integra as opiniões e permanece como único coordenador das ações. Se o usuário pedir métricas de desempenho, consulte agent_performance_report e apresente amostras e p50/p95 reais; nunca invente medições nem prometa 10 ms ponta a ponta.'});
    messages.add({'role':'system','content':'REGRA ANDROID: phone_batch é a única ferramenta para alterar a interface. Agrupe até 10 passos mecânicos previsíveis. Abrir aplicativos, navegar, focar campos e digitar não exigem confirmação extra. Se o usuário solicitou explicitamente uma mensagem e o destinatário/texto estão claros, enviar essa mensagem faz parte da autorização dada pelo usuário: não peça uma segunda confirmação. Não envie conteúdo diferente nem para outro destinatário. Pagamentos, transferências, compras, exclusões e permissões sempre exigem autorização específica.'});
    var inferenceRounds = 0;
    while (true) {
      if (_stopped) throw StateError('Execução interrompida pelo usuário.');
      inferenceRounds++;
      if (inferenceRounds > 16) {
        await _screenSubscription?.cancel();
        _screenSubscription = null;
        await _clearCheckpoint();
        try { await _channel.invokeMethod('agent_keep_alive_stop'); } catch (_) {}
        AgentPerformanceMetrics.record('task.total', taskLatency.elapsed);
        return 'Parei com segurança após 16 rodadas de decisão da IA para evitar um ciclo interminável. As ações já concluídas foram preservadas. Diga “continue” para retomar a partir do estado atual.';
      }
      onProgress('A IA está analisando o estado atual');
      // Eventos de tela atualizam o contexto, mas não cancelam HTTP em andamento:
      // cancelar a inferência desperdiça tokens, conexões e limites do provedor.
      if (_latestScreenEvent != null && _lastScreenRevisionSent != _screenRevision) {
        final event = _latestScreenEvent!;
        messages.add({'role':'system','content':'ATUALIZAÇÃO EM TEMPO REAL DA ACESSIBILIDADE (revisão $_screenRevision): pacote=${event['package'] ?? 'desconhecido'}; evento_origem=${event['event_source_package'] ?? ''}; tela=${event['screen'] ?? 'sem snapshot'}; janelas=${jsonEncode(event['windows'] ?? const [])}. Use este estado mais recente.'});
        _lastScreenRevisionSent = _screenRevision;
      }
      final screenRevisionAtStart = _screenRevision;
      final packageAtInferenceStart = _latestScreenEvent?['package']?.toString();
      final message = await _streamTurnWithRetry(
        endpoint:endpoint,model:model,token:token,messages:messages,
        tools:availableTools,onTextChunk:onTextChunk,onProgress:onProgress,
      );
      // O checkpoint será gravado uma vez com a resposta do modelo; evita serializar
      // novamente o mesmo histórico antes de acrescentar a mensagem recebida.
      if (_stopped) throw StateError('Execução interrompida pelo usuário.');
      final returnedCalls = (message['tool_calls'] as List?) ?? const [];
      final effectiveCalls = returnedCalls;
      final latestScreenPackage = _latestScreenEvent?['package']?.toString();
      final packageChangedDuringInference = packageAtInferenceStart != null &&
          latestScreenPackage != null &&
          packageAtInferenceStart != latestScreenPackage;
      final hasCoordinatePhoneAction = effectiveCalls.any((raw) {
        try {
          final call = Map<String,dynamic>.from(raw as Map);
          final function = Map<String,dynamic>.from(call['function'] as Map);
          final name = function['name']?.toString();
          if (name == 'phone_tap' || name == 'phone_long_press' || name == 'phone_swipe') return true;
          if (name != 'phone_batch') return false;
          final rawArgs = function['arguments'];
          final args = jsonDecode(rawArgs is String ? rawArgs : '{}');
          final actions = args is Map ? (args['actions'] as List? ?? const []) : const [];
          return actions.any((item) {
            if (item is! Map) return false;
            final action = item['tool']?.toString();
            return action == 'tap' || action == 'long_press' || action == 'swipe';
          });
        } catch (_) {
          return true;
        }
      });
      // Texto/foco são resolvidos contra a árvore atual no instante da ação.
      // Mudanças de conteúdo não devem desperdiçar outra inferência. Só
      // descartamos coordenadas antigas ou ações quando o app ativo mudou.
      if (returnedCalls.isNotEmpty &&
          (packageChangedDuringInference ||
           (_screenRevision != screenRevisionAtStart && hasCoordinatePhoneAction))) {
        final latest = _latestScreenEvent;
        messages.add({'role':'system','content':'O app ativo mudou ou a tela mudou durante uma ação por coordenadas. A ação potencialmente obsoleta foi descartada. Estado mais recente: pacote=${latest?['package'] ?? 'desconhecido'}; ${latest?['screen'] ?? 'tela alterada; leia novamente com phone_screen_read'}. Reavalie somente o alvo necessário.'});
        _lastScreenRevisionSent = _screenRevision;
        onProgress('App mudou ou coordenadas ficaram obsoletas; reavaliando alvo');
        continue;
      }
      // Preserve todas as chamadas do mesmo turno. São executadas em ordem; assim a IA
      // não precisa consumir uma nova chamada de inferência para cada ação já decidida.
      messages.add(message);
      await _saveCheckpoint(prompt, messages);
      final calls = (message['tool_calls'] as List?) ?? const [];
      if (calls.isEmpty) {
        await _screenSubscription?.cancel();
        _screenSubscription = null;
        await _clearCheckpoint();
        try { await _channel.invokeMethod('agent_keep_alive_stop'); } catch (_) {}
        AgentPerformanceMetrics.record('task.total', taskLatency.elapsed);
        return message['content']?.toString().trim() ?? '';
      }

      // Leituras independentes de rede/memória podem ocorrer juntas.
      // Ferramentas Android, SSH mutável, shell e qualquer ação com efeito
      // permanecem serializadas para não disputar estado nem repetir efeitos.
      bool canRunInParallel(dynamic raw) {
        try {
          final call = Map<String,dynamic>.from(raw as Map);
          final function = Map<String,dynamic>.from(call['function'] as Map);
          const safeIndependentReads = {
            'memory_list', 'memory_search', 'web_search', 'web_open',
            'ssh_list', 'github_repositories',
          };
          return safeIndependentReads.contains(function['name']);
        } catch (_) {
          return false;
        }
      }

      var callIndex = 0;
      while (callIndex < calls.length) {
        if (_stopped) throw StateError('Execução interrompida pelo usuário.');
        if (canRunInParallel(calls[callIndex])) {
          final batch = <dynamic>[];
          while (callIndex < calls.length && canRunInParallel(calls[callIndex])) {
            batch.add(calls[callIndex]);
            callIndex++;
          }
          onProgress('Executando ${batch.length} consultas independentes em paralelo');
          final results = await Future.wait(batch.map((raw) => _runToolCall(
            raw,
            accessMode: accessMode,
            confirmDangerous: confirmDangerous,
            onProgress: onProgress,
            openAppFeature: openAppFeature,
          )));
          if (_stopped) throw StateError('Execução interrompida pelo usuário.');
          messages.addAll(results);
          await _saveCheckpoint(prompt, messages);
          continue;
        }

        final raw = calls[callIndex++];
        final call = Map<String,dynamic>.from(raw as Map);
        final function = Map<String,dynamic>.from(call['function'] as Map);
        final toolName = function['name']?.toString() ?? 'ferramenta';
        onProgress('IA decidiu executar: '+toolName);
        final toolResult = await _runToolCall(
          raw,
          accessMode:accessMode,
          confirmDangerous:confirmDangerous,
          onProgress:onProgress,
          openAppFeature:openAppFeature,
        );
        if (_stopped) throw StateError('Execução interrompida pelo usuário');
        messages.add(toolResult);
        await _saveCheckpoint(prompt, messages);
      }
    }
  }
}