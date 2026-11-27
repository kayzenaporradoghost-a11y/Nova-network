import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_webview_flutter/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/agent_orchestrator.dart';
import '../core/agent_performance.dart';
import '../core/network_runtime.dart';

const _panel = Color(0xFF101010), _line = Color(0xFF252525), _muted = Color(0xFF929292), _accent = Color(0xFFB6F36B);

class _WorkspacePage extends StatelessWidget {
  const _WorkspacePage({required this.title, required this.description, required this.child});
  final String title, description; final Widget child;
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.fromLTRB(20,22,20,16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('NETWORK / CENTRAL DE CONTROLE', style: TextStyle(fontSize:9,color:_accent,fontWeight:FontWeight.w800,letterSpacing:1.6)),
      const SizedBox(height:7), Text(title,style:const TextStyle(fontSize:24,fontWeight:FontWeight.w800)),
      const SizedBox(height:5), Text(description,style:const TextStyle(fontSize:11,color:_muted,height:1.45)),
    ])), const Divider(height:1,color:_line), Expanded(child:child),
  ]);
}

class AgentsWorkspace extends StatefulWidget { const AgentsWorkspace({super.key}); @override State<AgentsWorkspace> createState()=>_AgentsWorkspaceState(); }
class _AgentsWorkspaceState extends State<AgentsWorkspace> {
  final _search=TextEditingController(); String _domain='todos';
  @override void dispose(){_search.dispose();super.dispose();}
  @override Widget build(BuildContext context) {
    final domains=<String,List<SpecialistProfile>>{};
    for(final p in AgentOrchestrator.all){domains.putIfAbsent(p.domain,()=>[]).add(p);}
    final q=_search.text.trim().toLowerCase();
    final visible=AgentOrchestrator.all.where((p)=>(_domain=='todos'||p.domain==_domain)&&(q.isEmpty||p.name.toLowerCase().contains(q)||p.id.contains(q)||p.guidance.toLowerCase().contains(q))).toList();
    return _WorkspacePage(title:'130 especialistas',description:'Catálogo completo dos especialistas que a IA principal pode consultar. A delegação continua sob decisão do agente principal.',child:Column(children:[
      Padding(padding:const EdgeInsets.all(14),child:Column(children:[
        Row(children:[Expanded(child:TextField(controller:_search,onChanged:(_)=>setState((){}),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Buscar especialista ou habilidade'))),const SizedBox(width:8),Text(visible.length.toString()+'/130',style:const TextStyle(fontSize:11,fontWeight:FontWeight.w700))]),
        const SizedBox(height:10),
        DropdownButtonFormField<String>(value:_domain,decoration:const InputDecoration(labelText:'Filtrar por área'),items:[
          const DropdownMenuItem(value:'todos',child:Text('Todas as áreas')),
          ...domains.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.key.toUpperCase()+' · '+e.value.length.toString()+' especialistas'))),
        ],onChanged:(v)=>setState(()=>_domain=v??'todos')),
      ])),
      Expanded(child:ListView.builder(itemCount:visible.length,itemBuilder:(context,i){
        final p=visible[i];
        return ListTile(leading:const Icon(Icons.psychology_alt_outlined,color:_accent),
          title:Text(p.name,style:const TextStyle(fontSize:11,fontWeight:FontWeight.w600)),
          subtitle:Text(p.id,style:const TextStyle(fontSize:9,color:_muted)),
          trailing:const Icon(Icons.chevron_right,size:18,color:_muted),
          onTap:()=>showModalBottomSheet<void>(context:context,backgroundColor:_panel,builder:(c)=>SafeArea(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(p.name,style:const TextStyle(fontSize:17,fontWeight:FontWeight.w700)),const SizedBox(height:8),
            SelectableText(p.id,style:const TextStyle(fontSize:10,color:_accent)),const SizedBox(height:14),
            Text(p.guidance,style:const TextStyle(fontSize:12,height:1.5)),const SizedBox(height:12),
            Text('Palavras-chave: '+p.keywords.join(', '),style:const TextStyle(fontSize:10,color:_muted)),
          ])))),
        );
      })),
    ]));
  }
}

class AgentPerformanceWorkspace extends StatefulWidget {
  const AgentPerformanceWorkspace({super.key});
  @override State<AgentPerformanceWorkspace> createState() => _AgentPerformanceWorkspaceState();
}

class _AgentPerformanceWorkspaceState extends State<AgentPerformanceWorkspace> {
  Map<String, dynamic> _snapshot = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    await AgentPerformanceMetrics.initialize();
    await AgentPerformanceMetrics.flush();
    if (!mounted) return;
    setState(() {
      _snapshot = AgentPerformanceMetrics.snapshot();
      _loading = false;
    });
  }

  String _ms(dynamic n) => (n is num ? n : 0).toStringAsFixed(2);

  Widget _card(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _panel, border: Border.all(color: _line), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 8, color: _muted)),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ]),
    ),
  );

  Future<void> _showTrace() async {
    final trace = await AgentPerformanceMetrics.exportJsonl();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rastreamento P0 · JSONL'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(trace, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, height: 1.4)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: trace));
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rastreamento copiado.')));
            },
            child: const Text('COPIAR'),
          ),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('FECHAR')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = Map<String, dynamic>.from(_snapshot['metrics'] as Map? ?? {});
    final enabled = AgentPerformanceMetrics.traceEnabled;
    return _WorkspacePage(
      title: 'Desempenho real',
      description: 'P0: coleta observacional por operação. Não altera a sequência de automação nem executa envios de teste.',
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: _panel, border: Border.all(color: _line), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(enabled ? Icons.fiber_manual_record : Icons.pause_circle_outline, size: 15, color: enabled ? _accent : _muted),
              const SizedBox(width: 8),
              Expanded(child: Text(
                enabled ? 'PERF_TRACE ATIVO · JSONL persistente' : 'PERF_TRACE DESATIVADO · somente métricas em memória',
                style: const TextStyle(fontSize: 9, color: _muted, fontWeight: FontWeight.w700),
              )),
              IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh, size: 18)),
            ]),
          ),
        ),
        Padding(padding: const EdgeInsets.all(14), child: Row(children: [
          _card('EXECUÇÕES', (_snapshot['runCount'] ?? 0).toString()),
          const SizedBox(width: 7),
          _card('AMOSTRAS', (_snapshot['sampleCount'] ?? 0).toString()),
          const SizedBox(width: 7),
          _card('MÉTRICAS', metrics.length.toString()),
        ])),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            const Expanded(child: Text('LATÊNCIA POR OPERAÇÃO', style: TextStyle(fontSize: 9, color: _muted, letterSpacing: 1.2))),
            TextButton.icon(onPressed: _showTrace, icon: const Icon(Icons.data_object, size: 15), label: const Text('JSONL', style: TextStyle(fontSize: 9))),
          ]),
        ),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : metrics.isEmpty
            ? const Center(child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ainda não há amostras. Execute tarefas no NETWORK e atualize este painel.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: _muted)),
              ))
            : ListView(children: metrics.entries.map((entry) {
                final value = Map<String, dynamic>.from(entry.value as Map);
                return ListTile(
                  title: Text(entry.key, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${value['count'] ?? 0} amostras · min ${_ms(value['minMs'])} ms · max ${_ms(value['maxMs'])} ms',
                    style: const TextStyle(fontSize: 9, color: _muted),
                  ),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('p50 ${_ms(value['p50Ms'])} ms', style: const TextStyle(fontSize: 10, color: _accent, fontWeight: FontWeight.w700)),
                    Text('p95 ${_ms(value['p95Ms'])} · p99 ${_ms(value['p99Ms'])}', style: const TextStyle(fontSize: 9, color: _muted)),
                  ]),
                );
              }).toList()),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${_snapshot['note'] ?? 'Métricas observadas neste processo.'}\nArquivo: ${_snapshot['traceFile'] ?? 'não inicializado'}${_snapshot['traceWriteError'] == null ? '' : '\nFalha ao gravar: ${_snapshot['traceWriteError']}'}',
            style: const TextStyle(fontSize: 9, color: _muted),
          ),
        ),
      ]),
    );
  }
}

class AndroidControlWorkspace extends StatefulWidget { const AndroidControlWorkspace({super.key}); @override State<AndroidControlWorkspace> createState()=>_AndroidControlWorkspaceState(); }
class _AndroidControlWorkspaceState extends State<AndroidControlWorkspace>{
  static const _channel=MethodChannel('micro/runtime'); final _package=TextEditingController(),_text=TextEditingController(); bool _busy=false; bool? _accessibility;
  String _output='Selecione uma ação para consultar o estado do Android.';
  Future<void> _call(String method,{Map<String,dynamic>? args})async{
    setState(()=>_busy=true);
    try{final result=await _channel.invokeMethod<dynamic>(method,args);if(mounted)setState(()=>_output=const JsonEncoder.withIndent('  ').convert(result));}
    catch(e){if(mounted)setState(()=>_output='Falha em '+method+':\n'+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _readOcr()async{setState(()=>_busy=true);try{final result=await ToolAgentService.readCurrentScreenOcr();if(mounted)setState(()=>_output=const JsonEncoder.withIndent('  ').convert(result));}catch(e){if(mounted)setState(()=>_output='Falha no OCR: '+e.toString());}finally{if(mounted)setState(()=>_busy=false);}}
  Future<void> _check()async{try{final v=await _channel.invokeMethod<bool>('isAccessibilityEnabled')??false;if(mounted)setState(()=>_accessibility=v);}catch(e){if(mounted)setState(()=>_output=e.toString());}}
  @override void initState(){super.initState();_check();}
  @override void dispose(){_package.dispose();_text.dispose();super.dispose();}
  Widget _action(String label,IconData icon,VoidCallback action)=>OutlinedButton.icon(onPressed:_busy?null:action,icon:Icon(icon,size:15),label:Text(label,style:const TextStyle(fontSize:10)));
  @override Widget build(BuildContext context)=>_WorkspacePage(title:'Central Android',description:'Consulte aplicativos, tela, OCR, Acessibilidade e janelas independentes. Ações que alteram outros aplicativos continuam sob controle do agente e das permissões do Android.',child:ListView(padding:const EdgeInsets.all(14),children:[
    Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:_panel,border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),child:Row(children:[
      Icon(Icons.accessibility_new,color:_accessibility==true?_accent:Colors.orangeAccent),const SizedBox(width:10),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Serviço de Acessibilidade',style:TextStyle(fontSize:12,fontWeight:FontWeight.w700)),Text(_accessibility==null?'Verificando…':_accessibility!?'Ativado':'Desativado — automação limitada',style:const TextStyle(fontSize:10,color:_muted))])),
      TextButton(onPressed:()=>_channel.invokeMethod('openAccessibilitySettings'),child:const Text('CONFIGURAR')),
    ])),
    const SizedBox(height:12),
    Wrap(spacing:7,runSpacing:7,children:[
      _action('Atualizar estado',Icons.refresh,_check),
      _action('Aplicativos instalados',Icons.apps,()=>_call('phone_list_apps')),
      _action('Ler tela atual',Icons.document_scanner_outlined,()=>_call('phone_screen_read')),
      _action('Capturar tela + OCR',Icons.text_fields,()=>_readOcr()),
      _action('Capacidades de janelas',Icons.web_asset,()=>_call('phone_window_capabilities')),
      _action('Listar janelas',Icons.view_quilt_outlined,()=>_call('phone_window_list')),
    ]),
    const SizedBox(height:14),
    TextField(controller:_package,decoration:const InputDecoration(labelText:'Pacote Android',hintText:'com.whatsapp')),
    const SizedBox(height:8),
    Wrap(spacing:7,runSpacing:7,children:[
      _action('Abrir aplicativo',Icons.open_in_new,()=>_call('launch_app',args:{'package':_package.text.trim()})),
      _action('Abrir em janela',Icons.picture_in_picture_alt,()=>_call('phone_open_app_window',args:{'package':_package.text.trim()})),
    ]),
    const SizedBox(height:8),
    TextField(controller:_text,decoration:const InputDecoration(labelText:'Texto alvo / texto para digitar',hintText:'Texto do botão ou mensagem')),
    const SizedBox(height:8),
    Wrap(spacing:7,runSpacing:7,children:[
      _action('Tocar no texto',Icons.ads_click,()=>_call('phone_tap_text',args:{'text':_text.text,'timeoutMs':0})),
      _action('Digitar texto',Icons.keyboard,()=>_call('phone_type_text',args:{'text':_text.text})),
      _action('Focar campo',Icons.input,()=>_call('phone_focus_input',args:{'timeoutMs':0})),
      _action('Esperar texto',Icons.hourglass_bottom,()=>_call('phone_wait_for_text',args:{'text':_text.text,'timeoutMs':5000})),
      _action('Rolar para baixo',Icons.south,()=>_call('phone_scroll',args:{'direction':'down'})),
      _action('Voltar',Icons.arrow_back,()=>_call('phone_press_back')),
    ]),
    const SizedBox(height:14),
    Container(width:double.infinity,constraints:const BoxConstraints(minHeight:180),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:const Color(0xFF070707),border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),child:SelectableText(_busy?'Consultando Android…':_output,style:const TextStyle(fontFamily:'monospace',fontSize:10,height:1.5))),
    const SizedBox(height:10),
    const Text('A disponibilidade de janelas flutuantes, leitura e gestos depende da versão do Android, permissões e suporte do aplicativo alvo.',style:TextStyle(fontSize:10,color:_muted,height:1.5)),
  ]));
}

class AiConfigurationWorkspace extends StatefulWidget { const AiConfigurationWorkspace({super.key,required this.ai}); final BlackChatService ai; @override State<AiConfigurationWorkspace> createState()=>_AiConfigurationWorkspaceState(); }
class _AiConfigurationWorkspaceState extends State<AiConfigurationWorkspace>{
  final _endpoint=TextEditingController(),_model=TextEditingController(),_token=TextEditingController(),_prompt=TextEditingController();
  bool _loading=true,_saving=false,_showToken=false;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{_endpoint.text=await widget.ai.endpoint;_model.text=await widget.ai.model;_token.text=await widget.ai.apiKey;_prompt.text=await widget.ai.systemPrompt;if(mounted)setState(()=>_loading=false);}
  Future<void> _save()async{setState(()=>_saving=true);try{await widget.ai.saveConfig(apiKey:_token.text,endpoint:_endpoint.text,modelName:_model.text,prompt:_prompt.text);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Configuração da IA salva no armazenamento seguro.')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Falha ao salvar: '+e.toString())));}finally{if(mounted)setState(()=>_saving=false);}}
  @override void dispose(){_endpoint.dispose();_model.dispose();_token.dispose();_prompt.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>_WorkspacePage(title:'Configuração da IA',description:'Configure o provedor e o modelo usados pelo agente. O NETWORK mantém a inferência no endpoint escolhido e não encaminha suas conversas automaticamente para serviços terceiros.',child:_loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(16),children:[
    TextField(controller:_endpoint,onChanged:(_)=>setState((){}),keyboardType:TextInputType.url,decoration:const InputDecoration(labelText:'Endpoint HTTPS',hintText:'https://api.exemplo.com/v1')),
    const SizedBox(height:12),TextField(controller:_model,onChanged:(_)=>setState((){}),decoration:const InputDecoration(labelText:'Identificador do modelo')),
    const SizedBox(height:12),TextField(controller:_token,obscureText:!_showToken,decoration:InputDecoration(labelText:'API key / token',suffixIcon:IconButton(onPressed:()=>setState(()=>_showToken=!_showToken),icon:Icon(_showToken?Icons.visibility_off:Icons.visibility)))),

    const SizedBox(height:18),const Text('ROTEAMENTO DO MODELO',style:TextStyle(fontSize:12,fontWeight:FontWeight.bold,letterSpacing:1.1)),
    const SizedBox(height:6),const Text('Somente o endpoint e o modelo configurados recebem solicitações. Em caso de falha, o NETWORK informa o erro em vez de transferir seu histórico para outro provedor.',style:TextStyle(fontSize:10,color:_muted,height:1.5)),
    if(_endpoint.text.contains('ai-gateway.kilo.ai') && _model.text.startsWith('nvidia/')) ...[
      const SizedBox(height:10),
      Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:Colors.orange.withValues(alpha:.08),border:Border.all(color:Colors.orange.withValues(alpha:.35)),borderRadius:BorderRadius.circular(8)),child:const Text('AVISO DE PRIVACIDADE: o modelo NVIDIA gratuito do Kilo é classificado como endpoint de teste. Não envie dados pessoais, senhas, tokens, documentos privados ou informações confidenciais por essa configuração.',style:TextStyle(fontSize:10,color:Colors.orangeAccent,height:1.5))),
    ],
    const SizedBox(height:12),TextField(controller:_prompt,minLines:7,maxLines:14,decoration:const InputDecoration(labelText:'Instruções principais da IA',alignLabelWithHint:true)),
    const SizedBox(height:16),FilledButton.icon(onPressed:_saving?null:_save,icon:const Icon(Icons.save_outlined),label:Text(_saving?'SALVANDO…':'SALVAR CONFIGURAÇÃO')),
    const SizedBox(height:10),const Text('O endpoint precisa usar HTTPS. Deixe a chave vazia somente se o provedor não exigir autenticação.',style:TextStyle(fontSize:10,color:_muted,height:1.5)),
  ]));
}

class LocalTerminalWorkspace extends StatefulWidget { const LocalTerminalWorkspace({super.key}); @override State<LocalTerminalWorkspace> createState()=>_LocalTerminalWorkspaceState(); }
class _LocalTerminalWorkspaceState extends State<LocalTerminalWorkspace>{
  static const _channel=MethodChannel('micro/runtime'); final _command=TextEditingController(); final _output=StringBuffer('NETWORK LOCAL TERMINAL\nComandos executados pelo canal local disponível no Android/Termux.\n\n'); bool _busy=false;
  Future<void> _run()async{final command=_command.text.trim();if(command.isEmpty||_busy)return;setState(()=>_busy=true);_output.writeln('\$ '+command);_command.clear();try{final r=await _channel.invokeMethod<dynamic>('local_shell_exec',{'command':command,'workdir':''});if(r is Map){_output.writeln(r['stdout']??'');if((r['stderr']??'').toString().isNotEmpty)_output.writeln('STDERR: '+r['stderr'].toString());if(r['exitCode']!=null)_output.writeln('[exit '+r['exitCode'].toString()+']');}else{_output.writeln(r?.toString()??'Sem saída.');}}catch(e){_output.writeln('ERRO: '+e.toString());}finally{if(mounted)setState(()=>_busy=false);}}
  @override void dispose(){_command.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>_WorkspacePage(title:'Terminal local',description:'Execute comandos pelo canal local do NETWORK. Comandos podem alterar arquivos e configurações.',child:Padding(padding:const EdgeInsets.all(14),child:Column(children:[
    Expanded(child:Container(width:double.infinity,padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFF050505),border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),child:SingleChildScrollView(child:SelectableText(_output.toString(),style:const TextStyle(fontFamily:'monospace',fontSize:10,height:1.5))))),
    const SizedBox(height:10),Row(children:[Expanded(child:TextField(controller:_command,enabled:!_busy,onSubmitted:(_)=>_run(),style:const TextStyle(fontFamily:'monospace',fontSize:11),decoration:const InputDecoration(hintText:'Digite um comando…'))),const SizedBox(width:8),IconButton.filled(onPressed:_busy?null:_run,icon:const Icon(Icons.play_arrow))]),
  ])));
}

class TaskStatusWorkspace extends StatefulWidget { const TaskStatusWorkspace({super.key,required this.agent,required this.running,required this.activity,required this.onStop}); final ToolAgentService agent; final bool running; final String activity; final Future<void> Function() onStop; @override State<TaskStatusWorkspace> createState()=>_TaskStatusWorkspaceState(); }
class _TaskStatusWorkspaceState extends State<TaskStatusWorkspace>{
  Map<String,dynamic>? _pending;bool _loading=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{final p=await widget.agent.pendingTask();if(mounted)setState(()=>_pending=p);_loading=false;if(mounted)setState((){});}
  @override Widget build(BuildContext context)=>_WorkspacePage(title:'Tarefas e execução',description:'Acompanhe a execução atual e o checkpoint persistido que pode ser retomado após reiniciar o aplicativo.',child:ListView(padding:const EdgeInsets.all(16),children:[
    Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:_panel,border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),child:Row(children:[
      Icon(widget.running?Icons.sync:Icons.check_circle_outline,color:widget.running?_accent:_muted),const SizedBox(width:10),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(widget.running?'EXECUTANDO':'SEM EXECUÇÃO ATIVA',style:const TextStyle(fontSize:11,fontWeight:FontWeight.w800)),const SizedBox(height:4),Text(widget.running?widget.activity:'O agente está aguardando uma nova tarefa.',style:const TextStyle(fontSize:10,color:_muted))])),
      if(widget.running)IconButton(onPressed:widget.onStop,tooltip:'Interromper agente',icon:const Icon(Icons.stop_circle_outlined,color:Colors.orangeAccent)),
    ])),
    const SizedBox(height:14),const Text('CHECKPOINT PERSISTIDO',style:TextStyle(fontSize:9,color:_muted,letterSpacing:1.2,fontWeight:FontWeight.w700)),const SizedBox(height:8),
    if(_loading)const Center(child:CircularProgressIndicator())else if(_pending==null)const Text('Nenhuma tarefa pendente salva.',style:TextStyle(fontSize:11,color:_muted))else Container(padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:_panel,border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      SelectableText(_pending!['prompt']?.toString()??'Tarefa sem descrição',style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600)),const SizedBox(height:8),
      Text('Atualizada: '+(_pending!['updatedAt']?.toString()??'data indisponível'),style:const TextStyle(fontSize:9,color:_muted)),const SizedBox(height:10),
      const Text('O NETWORK tentará retomar esse checkpoint ao iniciar o aplicativo.',style:TextStyle(fontSize:10,color:_muted)),
    ])),
    const SizedBox(height:12),OutlinedButton.icon(onPressed:_load,icon:const Icon(Icons.refresh,size:15),label:const Text('ATUALIZAR ESTADO')),
  ]));
}


class VideoGenerationWorkspace extends StatefulWidget {
  const VideoGenerationWorkspace({super.key});
  @override State<VideoGenerationWorkspace> createState()=>_VideoGenerationWorkspaceState();
}
class _VideoGenerationWorkspaceState extends State<VideoGenerationWorkspace> {
  final _prompt=TextEditingController();
  String _model='auto';
  InAppWebViewController? _web;
  bool _ready=false,_busy=false,_auto=false;
  String _status='Preparando gerador de vídeo Puter.';
  @override void initState(){super.initState();_loadPrompt();}
  Future<void> _loadPrompt()async{
    final prefs=await SharedPreferences.getInstance();
    final pending=prefs.getString('network_pending_video_prompt');
    if(pending!=null&&pending.trim().isNotEmpty){
      _prompt.text=pending;
      await prefs.remove('network_pending_video_prompt');
      _auto=true;
      if(_ready) _generate();
    }
  }
  Future<void> _generate()async{
    final prompt=_prompt.text.trim();
    if(prompt.isEmpty||_web==null||!_ready||_busy)return;
    setState(()=>_busy=true);
    setState(()=>_status='Enviando pedido ao Puter. A geração pode levar alguns minutos.');
    final encoded=jsonEncode(prompt);
    final encodedModel=jsonEncode(_model);
    await _web!.evaluateJavascript(source:"window.generateNetworkVideo($encoded,$encodedModel);");
  }
  @override void dispose(){_prompt.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>_WorkspacePage(
    title:'Geração de vídeo IA',
    description:'Puter.js · escolha entre roteamento automático, OpenAI Sora 2 e Google Veo 3 Fast. Não exige chave de desenvolvedor; a geração usa a cota/créditos da conta Puter e pode ter cobrança.',
    child:Column(children:[
      Padding(padding:const EdgeInsets.all(14),child:Column(children:[
        TextField(controller:_prompt,minLines:2,maxLines:4,decoration:const InputDecoration(labelText:'Descreva o vídeo',hintText:'Cena, movimento da câmera, estilo, iluminação e duração.')),
        const SizedBox(height:8),
        DropdownButtonFormField<String>(
          value:_model,
          decoration:const InputDecoration(labelText:'Modelo de vídeo'),
          items:const [
            DropdownMenuItem(value:'auto',child:Text('Automático · Puter')),
            DropdownMenuItem(value:'sora-2',child:Text('OpenAI Sora 2')),
            DropdownMenuItem(value:'veo-3.0-fast',child:Text('Google Veo 3 Fast')),
            DropdownMenuItem(value:'vidu/vidu-q3',child:Text('Vidu Q3 · 1080p + áudio')),
            DropdownMenuItem(value:'vidu/vidu-q3-turbo',child:Text('Vidu Q3 Turbo · rápido')),
            DropdownMenuItem(value:'vidu/vidu-q1',child:Text('Vidu Q1')),
          ],
          onChanged:_busy?null:(value){if(value!=null)setState(()=>_model=value);},
        ),
        const SizedBox(height:8),
        Row(children:[
          Expanded(child:Text(_status,style:const TextStyle(fontSize:10,color:_muted))),
          FilledButton.icon(onPressed:(!_ready||_busy)?null:_generate,icon:Icon(_busy?Icons.hourglass_top:Icons.movie_creation_outlined,size:16),label:Text(_busy?'GERANDO…':'GERAR VÍDEO')),
        ]),
      ])),
      const Divider(height:1,color:_line),
      Expanded(child:InAppWebView(
        initialData:InAppWebViewInitialData(data:'''<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{margin:0;background:#080808;color:#eee;font:14px sans-serif}#status{padding:16px;color:#aaa}video{width:100%;max-height:65vh;background:#000}a{color:#b6f36b}</style><script src="https://js.puter.com/v2/"></script></head><body><div id="status">Conectando ao serviço de vídeo…</div><div id="result"></div><script>window.generateNetworkVideo=async function(prompt,model){const s=document.getElementById('status');const r=document.getElementById('result');s.textContent='Gerando vídeo com IA. Aguarde…';r.innerHTML='';try{const video=await (model&&model!=='auto'?puter.ai.txt2vid(prompt,{model:model}):puter.ai.txt2vid(prompt));video.controls=true;video.playsInline=true;video.style.width='100%';video.style.maxHeight='65vh';r.appendChild(video);s.textContent='Vídeo concluído. Use os controles para assistir.';window.flutter_inappwebview?.callHandler('networkVideoStatus','Vídeo concluído.');}catch(e){s.textContent='Falha: '+(e?.message||String(e));window.flutter_inappwebview?.callHandler('networkVideoStatus','Falha: '+(e?.message||String(e)));}};</script></body></html>'''),
        initialSettings:InAppWebViewSettings(javaScriptEnabled:true,domStorageEnabled:true,mediaPlaybackRequiresUserGesture:true,thirdPartyCookiesEnabled:true),
        onWebViewCreated:(controller){_web=controller;controller.addJavaScriptHandler(handlerName:'networkVideoStatus',callback:(args){if(mounted)setState(() { _status=args.isEmpty?'':args.first.toString(); _busy=false; });return null;});},
        onLoadStop:(controller,url)async{if(!mounted)return;setState(()=>_ready=true);if(_auto){_auto=false;await _generate();}else{setState(()=>_status='Gerador pronto. O Puter pode solicitar login para usar a cota da conta.');}},
        onReceivedError:(controller,request,error){if(mounted)setState(() { _status='Falha ao carregar o gerador: ${error.description}'; _busy=false; });},
      )),
    ]),
  );
}
