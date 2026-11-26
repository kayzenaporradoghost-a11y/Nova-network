import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import 'design/void_design_system.dart';
import 'core/network_runtime.dart';
import 'core/agent_orchestrator.dart';
import 'core/agent_performance.dart';
import 'workspaces/advanced_workspaces.dart';

void main() => runApp(const NetworkApplication());

class MicroApp extends NetworkApplication { const MicroApp({super.key}); }

class NetworkApplication extends StatelessWidget {
  const NetworkApplication({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([VoidDesignSystem.appName, VoidDesignSystem.accent, VoidDesignSystem.skin, VoidDesignSystem.motion]),
    builder: (context, _) => MaterialApp(
      title: 'NET work',
      debugShowCheckedModeBanner: false,
      theme: VoidDesignSystem.theme,
      home: const NetworkWorkspace(),
    ),
  );
}

enum WorkspaceSection { chat, projects, servers, terminal, browser, memory, settings, connectors, agents, android, performance, aiSettings, localTerminal, tasks, video, focus }

class NetworkWorkspace extends StatefulWidget {
  const NetworkWorkspace({super.key});
  @override State<NetworkWorkspace> createState() => _NetworkWorkspaceState();
}

class _NetworkWorkspaceState extends State<NetworkWorkspace> with WidgetsBindingObserver {
  final BlackChatService _ai = BlackChatService();
  final SshManager _ssh = SshManager();
  final GithubService _github = GithubService();
  late final ToolAgentService _agent = ToolAgentService(_ai, _ssh, _github);
  WorkspaceSection _section = WorkspaceSection.chat;
  String _executionMode = 'automatic';
  String _accessMode = 'full';
  bool _running = false;
  bool _drawerOpen = false;
  String _activity = 'SISTEMA PRONTO';
  final TextEditingController _composer = TextEditingController();
  final SpeechToText _speech = SpeechToText();
  final AudioPlayer _voicePlayer = AudioPlayer();
  sherpa.OfflineTts? _voiceTts;
  Future<void>? _voiceTtsLoading;
  bool _speechReady = false, _listening = false;
  bool _autoSendVoice = false, _voiceAutoSendScheduled = false;
  StreamSubscription<dynamic>? _voiceCommandSubscription;
  final ScrollController _chatScroll = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  final List<PlatformFile> _attachments = [];
  static const _historyKey = 'network_void_conversations_v1';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voiceCommandSubscription = const EventChannel('micro/voice_events').receiveBroadcastStream().listen(_handleVoiceCommand, onError: (_) {});
    _restoreConversation();
    _voiceTtsLoading = _initializeVoiceModel();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestFirstLaunchPermissions());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verifyAccessibilitySetup();
      _ensureFloatingBubble();
    }
  }

  Future<void> _requestFirstLaunchPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    const runtimePermissionKey = 'network_runtime_permissions_requested_v1';
    if (prefs.getBool(runtimePermissionKey) != true) {
      // Solicita as permissões comuns declaradas no manifesto no primeiro acesso.
      await <Permission>[
        Permission.camera,
        Permission.microphone,
        Permission.contacts,
        Permission.storage,
        Permission.photos,
        Permission.videos,
        Permission.notification,
      ].request();
      await prefs.setBool(runtimePermissionKey, true);
    }

    // Sobreposição exige autorização especial nas configurações do Android.
    if (!mounted) return;
    const channel = MethodChannel('micro/runtime');
    final hasOverlay = await channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
    if (!hasOverlay && mounted) {
      final shouldOpenSettings = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Permitir janela flutuante'),
          content: const Text('O NETWORK precisa da permissão de sobreposição para exibir o assistente flutuante. Toque em continuar e habilite “Permitir sobreposição a outros apps”.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('DEPOIS')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('CONTINUAR')),
          ],
        ),
      ) ?? false;
      if (shouldOpenSettings) await channel.invokeMethod('requestOverlayPermission');
    }

    await _verifyAccessibilitySetup(showPrompt: true);
    await _ensureFloatingBubble();
  }

  Future<void> _ensureFloatingBubble() async {
    if (!mounted || await Permission.microphone.status != PermissionStatus.granted) return;
    const channel = MethodChannel('micro/runtime');
    try {
      final hasOverlay = await channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
      if (hasOverlay) await channel.invokeMethod<bool>('startFloatingBubble');
    } catch (_) {}
  }

  void _handleVoiceCommand(dynamic event) {
    if (event == 'toggle' && mounted) _toggleVoiceInput(autoSend: true);
  }

  Future<void> _setFloatingBubbleState(String state) async {
    try { await const MethodChannel('micro/runtime').invokeMethod('setBubbleState', {'state': state}); } catch (_) {}
  }

  Future<void> _verifyAccessibilitySetup({bool showPrompt = false}) async {
    if (!mounted) return;
    final channel = const MethodChannel('micro/runtime');
    final enabled = await channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    final prefs = await SharedPreferences.getInstance();
    if (enabled) {
      await prefs.setBool('network_accessibility_setup_complete_v2', true);
      return;
    }
    if (!showPrompt || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Configure o NETWORK'),
        content: const Text('Para a IA enxergar os aplicativos e controlá-los por janelas independentes, ative o serviço de Acessibilidade do NETWORK. O Android abrirá as configurações; selecione NETWORK e habilite o serviço. Essa autorização é necessária para automação, não para a bolha flutuante.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('DEPOIS'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await channel.invokeMethod('openAccessibilitySettings');
            },
            child: const Text('ATIVAR AGORA'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreConversation() async {
    final prefs = await SharedPreferences.getInstance();
    _accessMode = prefs.getString('network_agent_access_mode_v1') ?? 'full';
    final raw = prefs.getString(_historyKey);
    if (raw != null) {
      try {
        final items = (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)).toList();
        if (mounted) setState(() => _messages.addAll(items));
      } catch (_) {}
    }
    final pending = await _agent.pendingTask();
    if (pending != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resumePendingTask(pending));
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resumePendingTask(Map<String,dynamic> pending) async {
    if (!mounted || _running) return;
    final prompt = pending['prompt']?.toString() ?? '';
    final rawMessages = pending['messages'];
    if (prompt.isEmpty || rawMessages is! List) return;
    final resumeMessages = rawMessages.map((e) => Map<String,dynamic>.from(e as Map)).toList();
    setState(() {
      if (_messages.isEmpty || _messages.last['role'] != 'assistant') {
        _messages.add({'role':'assistant','content':''});
      }
      _running = true;
      _activity = 'RETOMANDO TAREFA SALVA';
    });
    var lastStreamPersist = DateTime.fromMillisecondsSinceEpoch(0);
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final liveResponse = StringBuffer(_messages.isNotEmpty ? _messages.last['content']?.toString() ?? '' : '');
    try {
      final result = await _agent.run(
        prompt: prompt,
        executionMode: _executionMode,
        accessMode: _accessMode,
        history: const [],
        images: const [],
        resumeMessages: resumeMessages,
        confirmDangerous: _confirmDangerous,
        onProgress: (value) {
          if (mounted) setState(() => _activity = value.toUpperCase());
        },
        onTextChunk: (chunk) {
          if (!mounted || _messages.isEmpty) return;
          liveResponse.write(chunk);
          final now = DateTime.now();
          if (now.difference(lastUiUpdate) >= const Duration(milliseconds:50)) {
            lastUiUpdate = now;
            setState(() => _messages.last['content'] = liveResponse.toString());
            _scrollToEnd();
          }
          if (now.difference(lastStreamPersist) >= const Duration(seconds:1)) {
            lastStreamPersist = now;
            _persist();
          }
        },
        openAppFeature: _openFeature,
      );
      if (mounted) setState(() => _messages.last['content'] = result);
    } catch (error) {
      if (mounted) setState(() {
        final previous = _messages.isNotEmpty ? (_messages.last['content']?.toString() ?? '') : '';
        final failure = 'TAREFA PAUSADA — será retomada quando você iniciar novamente.\\n\\n$error';
        _messages.last['content'] = previous.trim().isEmpty
            ? failure
            : previous.contains(error.toString())
                ? previous
                : '$previous\\n\\n$failure';
      });
    } finally {
      if (mounted) setState(() { _running = false; _activity = 'SISTEMA PRONTO'; });
      await _persist();
      _scrollToEnd();
    }
  }

  Future<void> _toggleVoiceInput({bool autoSend = false}) async {
    if (_listening) {
      if (autoSend) _autoSendVoice = true;
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      if (_autoSendVoice) _scheduleVoiceAutoSend();
      return;
    }
    _autoSendVoice = autoSend;
    _voiceAutoSendScheduled = false;
    try {
      _speechReady = await _speech.initialize(
        onStatus: (status) {
          final isListening = status == 'listening';
          if (mounted) setState(() => _listening = isListening);
          if (isListening) {
            _setFloatingBubbleState('listening');
          } else if (_autoSendVoice) {
            _scheduleVoiceAutoSend();
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
          if (_autoSendVoice) _scheduleVoiceAutoSend();
          else _setFloatingBubbleState('error');
        },
      );
      if (!_speechReady) {
        _autoSendVoice = false;
        await _setFloatingBubbleState('error');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reconhecimento de voz indisponível neste aparelho.')));
        return;
      }
      await _speech.listen(
        localeId: 'pt_BR',
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 4),
        onResult: (result) {
          if (!mounted) return;
          setState(() => _composer.text = result.recognizedWords);
          if (result.finalResult && _autoSendVoice) _scheduleVoiceAutoSend();
        },
      );
      if (mounted) setState(() => _listening = true);
      if (autoSend) await _setFloatingBubbleState('listening');
    } catch (e) {
      _autoSendVoice = false;
      await _setFloatingBubbleState('error');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Voz: $e')));
    }
  }

  void _scheduleVoiceAutoSend() {
    if (!_autoSendVoice || _voiceAutoSendScheduled) return;
    _voiceAutoSendScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 650), () async {
      _voiceAutoSendScheduled = false;
      if (!_autoSendVoice) return;
      _autoSendVoice = false;
      if (!mounted || _composer.text.trim().isEmpty) {
        await _setFloatingBubbleState('idle');
        return;
      }
      await _setFloatingBubbleState('working');
      const acknowledgements = <String>[
        'Entendi. Estou enviando sua mensagem agora.',
        'Certo, já passei seu pedido para a IA.',
        'Beleza, vou processar o que você falou.',
        'Recebi sua voz. Já estou cuidando disso.',
        'Pronto, sua mensagem está seguindo para o NETWORK.',
        'Pode deixar, estou encaminhando seu pedido.',
      ];
      final phraseIndex = DateTime.now().microsecondsSinceEpoch % acknowledgements.length;
      await _speakNetworkText(acknowledgements[phraseIndex]);
      await _send(speakResponse: true);
      await _setFloatingBubbleState('idle');
    });
  }

  Future<void> _initializeVoiceModel() async {
    try {
      final support = await getApplicationSupportDirectory();
      final voiceDir = Directory('${support.path}/network_voice');
      final modelFile = File('${voiceDir.path}/dii_pt-BR.onnx');
      final tokensFile = File('${voiceDir.path}/tokens.txt');
      final espeakDir = Directory('${voiceDir.path}/espeak-ng-data');
      if (!await modelFile.exists() || !await tokensFile.exists() || !await espeakDir.exists()) {
        await voiceDir.create(recursive: true);
        final manifest = jsonDecode(await rootBundle.loadString('AssetManifest.json')) as Map<String, dynamic>;
        final paths = manifest.keys.where((path) => path.startsWith('assets/network_voice/')).toList();
        for (final assetPath in paths) {
          final relative = assetPath.substring('assets/network_voice/'.length);
          final target = File('${voiceDir.path}/$relative');
          await target.parent.create(recursive: true);
          final data = await rootBundle.load(assetPath);
          await target.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: false);
        }
      }
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(model: modelFile.path, tokens: tokensFile.path, dataDir: espeakDir.path),
          numThreads: 2, debug: false, provider: 'cpu',
        ),
        maxNumSenetences: 1,
      );
      _voiceTts = sherpa.OfflineTts(config);
    } catch (_) { _voiceTts = null; }
  }

  Future<void> _speakNetworkText(String text) async {
    final clean = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ').replaceAll(RegExp(r'[#*_>`]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return;
    try {
      _voiceTtsLoading ??= _initializeVoiceModel();
      await _voiceTtsLoading;
      final tts = _voiceTts;
      if (tts == null) return;
      final spoken = clean.length > 1200 ? clean.substring(0, 1200) : clean;
      final audio = tts.generate(text: spoken, sid: 0, speed: 1.08);
      final temp = await getTemporaryDirectory();
      final wav = '${temp.path}/network_voice_reply.wav';
      sherpa.writeWave(filename: wav, samples: audio.samples, sampleRate: audio.sampleRate);
      await _voicePlayer.stop();
      await _voicePlayer.play(DeviceFileSource(wav));
    } catch (_) {}
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_messages));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceCommandSubscription?.cancel();
    _speech.stop();
    _voiceTts?.free();
    _voicePlayer.dispose();
    _composer.dispose();
    _chatScroll.dispose();
    // Keep the agent alive when the chat view is disposed; resume from checkpoint after process death.
    super.dispose();
  }

  void _navigate(WorkspaceSection section) {
    setState(() { _section = section; _drawerOpen = false; });
  }

  Future<void> _newConversation() async {
    if (_running) await _stopAgent();
    setState(() { _messages.clear(); _attachments.clear(); _section = WorkspaceSection.chat; });
    await _persist();
  }

  Future<void> _send({bool speakResponse = false}) async {
    final prompt = _composer.text.trim();
    if (_running || (prompt.isEmpty && _attachments.isEmpty)) return;
    final files = List<PlatformFile>.from(_attachments);
    // Keep the prompt context bounded: resending the entire chat on every tool turn
    // makes inference progressively slower as the conversation grows.
    final conversationHistory = _messages.where((m) => m['role'] == 'user' || m['role'] == 'assistant')
      .map((m) {
        final content = m['content'].toString();
        return <String, String>{
          'role': m['role'].toString(),
          'content': content.length > 2400 ? content.substring(content.length - 2400) : content,
        };
      }).toList();
    final history = conversationHistory.length > 8
      ? conversationHistory.sublist(conversationHistory.length - 8)
      : conversationHistory;
    final imageParts = <Map<String, String>>[];
    for (final file in files) {
      final ext = (file.extension ?? '').toLowerCase();
      if ({'png', 'jpg', 'jpeg', 'webp'}.contains(ext) && file.path != null && file.size <= 12 * 1024 * 1024) {
        final bytes = await File(file.path!).readAsBytes();
        imageParts.add({
          'mime': ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg',
          'base64': base64Encode(bytes),
        });
      }
    }
    final request = prompt.isEmpty ? 'Analise os arquivos anexados.' : prompt;
    setState(() {
      _messages.add({'role': 'user', 'content': request + (files.isEmpty ? '' : '\n\nAnexos: ${files.map((f) => f.name).join(', ')}')});
      _messages.add({'role': 'assistant', 'content': ''});
      _composer.clear();
      _attachments.clear();
      _running = true;
      _activity = 'PREPARANDO EXECUÇÃO';
    });
    await _persist();
    _scrollToEnd();
    var lastStreamPersist = DateTime.fromMillisecondsSinceEpoch(0);
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final liveResponse = StringBuffer();
    try {
      final result = await _agent.run(
        prompt: request,
        executionMode: _executionMode,
        accessMode: _accessMode,
        history: history,
        images: imageParts,
        confirmDangerous: _confirmDangerous,
        onProgress: (value) {
          if (mounted) setState(() => _activity = value.toUpperCase());
        },
        onTextChunk: (chunk) {
          if (!mounted || _messages.isEmpty) return;
          liveResponse.write(chunk);
          final now = DateTime.now();
          if (now.difference(lastUiUpdate) >= const Duration(milliseconds:50)) {
            lastUiUpdate = now;
            setState(() => _messages.last['content'] = liveResponse.toString());
            _scrollToEnd();
          }
          if (now.difference(lastStreamPersist) >= const Duration(seconds:1)) {
            lastStreamPersist = now;
            _persist();
          }
        },
        openAppFeature: _openFeature,
      );
      if (mounted) setState(() => _messages.last['content'] = result);
      if (speakResponse) await _speakNetworkText(result);
    } catch (error) {
      if (mounted) setState(() {
        final previous = _messages.isNotEmpty ? (_messages.last['content']?.toString() ?? '') : '';
        final failure = 'FALHA NA EXECUÇÃO\\n\\n$error';
        _messages.last['content'] = previous.trim().isEmpty
            ? failure
            : previous.contains(error.toString())
                ? previous
                : '$previous\\n\\n$f​ailure'.replaceAll('f​ailure', 'failure');
      });
    } finally {
      if (mounted) setState(() { _running = false; _activity = 'SISTEMA PRONTO'; });
      await _persist();
      _scrollToEnd();
    }
  }

  Future<String> _openFeature(String feature) async {
    const routes = {
      'projects': WorkspaceSection.projects, 'terminal': WorkspaceSection.terminal,
      'vps': WorkspaceSection.servers, 'settings': WorkspaceSection.settings,
      'memory': WorkspaceSection.memory, 'mcp': WorkspaceSection.connectors, 'browser': WorkspaceSection.browser,
      'agents': WorkspaceSection.agents, 'android': WorkspaceSection.android,
      'performance': WorkspaceSection.performance, 'ai_settings': WorkspaceSection.aiSettings,
      'local_terminal': WorkspaceSection.localTerminal, 'tasks': WorkspaceSection.tasks, 'video': WorkspaceSection.video, 'focus': WorkspaceSection.focus,
    };
    final target = routes[feature];
    if (target != null && mounted) _navigate(target);
    return target == null ? 'Recurso $feature não possui painel próprio nesta versão.' : 'Painel $feature aberto.';
  }

  Future<bool> _confirmDangerous(String command) async {
    return await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('CONFIRMAR AÇÃO'),
      content: SelectableText('O agente solicitou executar a seguinte ação:\n\n$command\n\nDeseja permitir?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('BLOQUEAR')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('PERMITIR')),
      ],
    )) ?? false;
  }

  Future<void> _stopAgent() async {
    await _agent.stop();
    if (mounted) setState(() { _running = false; _activity = 'EXECUÇÃO INTERROMPIDA'; });
    await _persist();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (result == null) return;
    setState(() => _attachments.addAll(result.files));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    drawer: _navigationDrawer(),
    body: SafeArea(
      child: Column(children: [
        _topBar(),
        Expanded(child: _section == WorkspaceSection.chat ? _chatView() : _sectionView()),
      ]),
    ),
  );

  Widget _topBar() => Container(
    height: 52, padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(color: Colors.black, border: Border(bottom: BorderSide(color: Color(0xFF181818)))),
    child: Row(children: [
      Builder(builder: (context) => _squareControl(Icons.menu, 'Abrir menu', () => Scaffold.of(context).openDrawer())),
      const SizedBox(width: 8),
      Text(VoidDesignSystem.appName.value.split(RegExp(r'\s+')).first, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -.6)),
      if (VoidDesignSystem.appName.value.trim().split(RegExp(r'\s+')).length > 1) ...[
        const SizedBox(width: 4), Text(VoidDesignSystem.appName.value.trim().split(RegExp(r'\s+')).skip(1).join(' '), style: TextStyle(fontSize: 14, color: Color(0xFF929292), fontWeight: FontWeight.w500)),
      ],
      const Spacer(),
      _squareControl(Icons.add_comment_outlined, 'Nova tarefa', _newConversation),
      _squareControl(Icons.more_horiz, 'Mais ações', _showActions),
    ]),
  );

  Widget _squareControl(IconData icon, String tooltip, VoidCallback action) => IconButton(
    onPressed: action, tooltip: tooltip, icon: Icon(icon, size: 18, color: const Color(0xFFB5B5B5)),
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(backgroundColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
  );

  Widget _navigationDrawer() => Drawer(
    width: 276, backgroundColor: const Color(0xFF030303),
    child: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 13, 12, 15), child: Row(children: [
        const Expanded(child: Text('NET work', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -.6))),
        _squareControl(Icons.search, 'Buscar tarefas', _showConversationSearch),
        _squareControl(Icons.close, 'Fechar menu', () => Navigator.pop(context)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: SizedBox(width: double.infinity, height: 36,
        child: TextButton.icon(onPressed: () { Navigator.pop(context); _newConversation(); },
          icon: const Icon(Icons.edit_outlined, size: 15), label: const Align(alignment: Alignment.centerLeft, child: Text('Nova tarefa', style: TextStyle(fontSize: 12))),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: const Color(0xFFE4E4E4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)))))),
      _navGroup('Projects', [
        _navItem(Icons.add, 'Novo projeto', WorkspaceSection.projects),
      ]),
      Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _navGroup('Agentes e sistema', [
        _navItem(Icons.hub_outlined, '130 especialistas', WorkspaceSection.agents),
        _navItem(Icons.smartphone, 'Central Android', WorkspaceSection.android),
        _navItem(Icons.speed, 'Desempenho e métricas', WorkspaceSection.performance),
        _navItem(Icons.tune, 'Configuração da IA', WorkspaceSection.aiSettings),
        _navItem(Icons.terminal, 'Terminal local', WorkspaceSection.localTerminal),
        _navItem(Icons.pending_actions, 'Tarefas e execução', WorkspaceSection.tasks),
        _navItem(Icons.timer_outlined, 'Foco e produtividade', WorkspaceSection.focus),
      ]),
      _navGroup('Tarefas', [
        _navItem(Icons.chat_bubble_outline, 'Conversas', WorkspaceSection.chat),
        _navItem(Icons.memory_outlined, 'Memória', WorkspaceSection.memory),
        _navItem(Icons.dns_outlined, 'Servidores / VPS', WorkspaceSection.servers),
        _navItem(Icons.terminal, 'Terminal SSH', WorkspaceSection.terminal),
        _navItem(Icons.language, 'Navegador', WorkspaceSection.browser),
        _navItem(Icons.extension_outlined, 'Conectores', WorkspaceSection.connectors),
      ]),
      ]))),
      Container(height: 1, color: const Color(0xFF151515)),
      _navItem(Icons.tune, 'Personalizar', WorkspaceSection.settings),
      Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 14), child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: _running ? VoidDesignSystem.neon : const Color(0xFF70BB91), shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(_running ? _activity : 'AGENTE DISPONÍVEL', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9, color: Color(0xFF777777), letterSpacing: .7))),
      ])),
    ])),
  );

  void _showConversationSearch() {
    final controller = TextEditingController();
    showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Buscar tarefas'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Digite para filtrar o histórico')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('FECHAR')),
        FilledButton(onPressed: () {
          final query = controller.text.toLowerCase();
          final found = _messages.indexWhere((m) => m['role'] == 'user' && (m['content']?.toString().toLowerCase().contains(query) ?? false));
          Navigator.pop(dialogContext);
          if (found >= 0) { _navigate(WorkspaceSection.chat); _scrollToEnd(); }
          else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nenhuma tarefa encontrada no histórico carregado.')));
        }, child: const Text('BUSCAR')),
      ],
    )).whenComplete(controller.dispose);
  }

  Widget _navGroup(String title, List<Widget> items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.fromLTRB(18, 22, 12, 6), child: Text(title, style: const TextStyle(fontSize: 10, color: Color(0xFF707070), fontWeight: FontWeight.w500))),
    ...items,
  ]);

  Widget _navItem(IconData icon, String label, WorkspaceSection section) {
    final selected = _section == section;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1), child: SizedBox(height: 32, child: TextButton(
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 8),
        backgroundColor: selected ? const Color(0xFF1D1D1D) : Colors.transparent,
        foregroundColor: selected ? const Color(0xFFF7F7F7) : const Color(0xFFDBDBDB),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      onPressed: () { Navigator.pop(context); _navigate(section); },
      child: Row(children: [
        Icon(icon, size: 15, color: selected ? VoidDesignSystem.neon : const Color(0xFF888888)),
        const SizedBox(width: 9), Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500))),
      ]),
    )));
  }

  Widget _chatView() => Column(children: [
    Expanded(child: _messages.isEmpty ? _emptyState() : ListView.builder(
      controller: _chatScroll, padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      itemCount: _messages.length, itemBuilder: (context, index) => _messageTile(_messages[index]),
    )),
    if (_running) _activityStrip(),
    _composerPanel(),
  ]);

  Widget _emptyState() => Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 560), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('NET work', style: TextStyle(color: VoidDesignSystem.neon, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
      const SizedBox(height: 18),
      const Text('Como posso ajudar?', style: TextStyle(fontSize: 27, height: 1.12, fontWeight: FontWeight.w600, letterSpacing: -.8)),
      const SizedBox(height: 12),
      const Text('Descreva o que precisa. O NETWORK pode planejar, executar ferramentas e verificar o resultado.', style: TextStyle(color: Color(0xFF828282), height: 1.55, fontSize: 12)),
      const SizedBox(height: 22),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _promptChip(Icons.code, 'Criar um aplicativo'), _promptChip(Icons.bug_report_outlined, 'Investigar um erro'),
        _promptChip(Icons.dns_outlined, 'Administrar uma VPS'), _promptChip(Icons.web, 'Construir um site'),
      ]),
    ]),
  )));

  Widget _promptChip(IconData icon, String label) => ActionChip(
    onPressed: _running ? null : () { _composer.text = label; _send(); },
    avatar: Icon(icon, size: 14, color: const Color(0xFF888888)),
    label: Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFFE5E5E5))),
    backgroundColor: const Color(0xFF101010), side: const BorderSide(color: Color(0xFF252525)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  Widget _messageTile(Map<String, dynamic> message) {
    final user = message['role'] == 'user';
    final content = message['content']?.toString() ?? '';
    if (user) return Padding(padding: const EdgeInsets.only(bottom: 12, top: 7), child: Align(
      alignment: Alignment.centerRight, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(decoration: BoxDecoration(color: const Color(0xFF121212), borderRadius: BorderRadius.circular(11)),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: SelectableText(content, style: const TextStyle(fontSize: 12, height: 1.6, color: Color(0xFFE5E5E5))))))));
    return Padding(padding: const EdgeInsets.only(bottom: 18, top: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.circle_outlined, size: 15, color: Color(0xFFD4D4D4))),
      const SizedBox(width: 10),
      Expanded(child: SelectionArea(child: GptMarkdown(content.isEmpty ? ' ' : content,
        styleSheet: const GptMarkdownStyleSheet(
          inlineCode: InlineCodeStyle(fontFamily: 'monospace'),
          codeBlock: CodeBlockStyle(borderRadius: Radius.circular(6), showCopyButton: true),
          table: TableStyle(cellPadding: EdgeInsets.all(7)),
        )))),
    ]));
  }

  Widget _activityStrip() => Container(
    width: double.infinity, padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF181818)))),
    child: Row(children: [
      const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: VoidDesignSystem.neon)),
      const SizedBox(width: 9),
      Expanded(child: Text(_activity, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Color(0xFF828282), letterSpacing: .8))),
      TextButton(onPressed: _stopAgent, child: const Text('PARAR', style: TextStyle(fontSize: 10, color: VoidDesignSystem.neon, letterSpacing: .7))),
    ]),
  );

  Widget _composerPanel() => Container(
    width: double.infinity, padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    color: Colors.black,
    child: Column(children: [
      if (_attachments.isNotEmpty) SizedBox(height: 34, child: ListView(scrollDirection: Axis.horizontal, children: _attachments.map((f) =>
        Padding(padding: const EdgeInsets.only(right: 6), child: InputChip(
          label: Text(f.name, style: const TextStyle(fontSize: 10)), onDeleted: () => setState(() => _attachments.remove(f)),
          backgroundColor: const Color(0xFF171717), side: const BorderSide(color: Color(0xFF292929)),
        ))).toList())),
      Container(decoration: BoxDecoration(color: const Color(0xFF0C0C0E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF202020))),
        child: Column(children: [
          TextField(controller: _composer, enabled: !_running, minLines: 1, maxLines: 5,
            style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFEEEEEE)),
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Faça qualquer coisa', border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, fillColor: Colors.transparent, contentPadding: EdgeInsets.fromLTRB(13, 12, 13, 6))),
          Padding(padding: const EdgeInsets.fromLTRB(7, 0, 7, 6), child: Row(children: [
            _composerAction(Icons.add, 'Adicionar anexo', _running ? null : _pickFiles),
            _composerAction(_listening ? Icons.mic : Icons.mic_none, _listening ? 'Parar ditado' : 'Ditado em português', _running ? null : _toggleVoiceInput),
            const Spacer(),
            SizedBox(width: 30, height: 30, child: FilledButton(
              onPressed: _running ? _stopAgent : _send,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEEEEEE), foregroundColor: const Color(0xFF171717), padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
              child: Icon(_running ? Icons.stop_rounded : Icons.arrow_upward, size: 16))),
          ])),
      ])),
      const SizedBox(height: 5),
      Row(children: [
        _smallSelect(Icons.computer_outlined, _executionMode == 'automatic' ? 'Local' : _executionMode.toUpperCase(), _chooseExecutionMode),
        const Spacer(),
        _smallSelect(Icons.shield_outlined, _accessMode == 'full' ? 'Acesso total' : _accessMode == 'confirm' ? 'Perguntar sempre' : 'Somente leitura', _chooseAccessMode),
      ]),
      const SizedBox(height: 4),
      const Text('A IA pode cometer erros. Confira informações importantes.', style: TextStyle(fontSize: 9, color: Color(0xFF555555))),
    ]),
  );

  Widget _smallSelect(IconData icon, String label, VoidCallback action) => TextButton(
    onPressed: action, style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3), foregroundColor: const Color(0xFFBDBDBD), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13), const SizedBox(width: 5),
      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 115), child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10))),
      const SizedBox(width: 3), const Icon(Icons.keyboard_arrow_down, size: 12, color: Color(0xFF777777)),
    ]),
  );

  Future<void> _chooseAccessMode() async {
    const modes = {'full':'Acesso total', 'confirm':'Perguntar sempre', 'readOnly':'Somente leitura'};
    final selected = await showModalBottomSheet<String>(context: context, backgroundColor: const Color(0xFF101010), builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      for (final entry in modes.entries)
        ListTile(title: Text(entry.value, style: const TextStyle(fontSize: 12)), trailing: _accessMode == entry.key ? const Icon(Icons.check, color: VoidDesignSystem.neon) : null, onTap: () => Navigator.pop(c, entry.key)),
    ])));
    if (selected == null || !mounted) return;
    setState(() => _accessMode = selected);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('network_agent_access_mode_v1', selected);
  }

  Widget _composerAction(IconData icon, String tooltip, VoidCallback? action) => IconButton(
    onPressed: action, tooltip: tooltip, icon: Icon(icon, size: 18, color: const Color(0xFFDDDDDD)),
    visualDensity: VisualDensity.compact,
  );

  Future<void> _chooseExecutionMode() async {
    const modes = {'automatic': 'Local', 'vps': 'VPS / SSH', 'github': 'GitHub', 'browser': 'Nuvem / navegador', 'plugins': 'Conectores'};
    final selected = await showModalBottomSheet<String>(context: context, backgroundColor: const Color(0xFF101010),
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: modes.entries.map((entry) =>
        ListTile(title: Text(entry.value, style: const TextStyle(fontSize: 12)), trailing: _executionMode == entry.key ? const Icon(Icons.check, color: VoidDesignSystem.neon) : null,
          onTap: () => Navigator.pop(context, entry.key))).toList())));
    if (selected != null) setState(() => _executionMode = selected);
  }

  Future<void> _showActions() async {
    await showModalBottomSheet(context: context, backgroundColor: const Color(0xFF101010), builder: (context) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.add_comment), title: const Text('Nova tarefa'), onTap: () { Navigator.pop(context); _newConversation(); }),
        ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Apagar conversa atual'), onTap: () { Navigator.pop(context); _newConversation(); }),
        ListTile(leading: const Icon(Icons.tune), title: const Text('Personalizar'), onTap: () { Navigator.pop(context); _navigate(WorkspaceSection.settings); }),
      ],
    )));
  }



  Widget _sectionView() {
    switch (_section) {
      case WorkspaceSection.projects: return const ProjectsWorkspace();
      case WorkspaceSection.servers: return ServersWorkspace(manager: _ssh);
      case WorkspaceSection.terminal: return TerminalWorkspace(manager: _ssh);
      case WorkspaceSection.browser: return const BrowserWorkspace();
      case WorkspaceSection.memory: return const MemoryWorkspace();
      case WorkspaceSection.settings: return SettingsWorkspace(onModeChanged: (v) => setState(() => _executionMode = v), mode: _executionMode);
      case WorkspaceSection.connectors: return ConnectorsWorkspace(github: _github);
      case WorkspaceSection.agents: return const AgentsWorkspace();
      case WorkspaceSection.android: return const AndroidControlWorkspace();
      case WorkspaceSection.performance: return const AgentPerformanceWorkspace();
      case WorkspaceSection.aiSettings: return AiConfigurationWorkspace(ai: _ai);
      case WorkspaceSection.localTerminal: return const LocalTerminalWorkspace();
      case WorkspaceSection.tasks: return TaskStatusWorkspace(agent: _agent, running: _running, activity: _activity, onStop: _stopAgent);
      case WorkspaceSection.video: return const VideoGenerationWorkspace();
      case WorkspaceSection.focus: return const FocusWorkspace();
      case WorkspaceSection.chat: return _chatView();
    }
  }
}

class SectionFrame extends StatelessWidget {
  const SectionFrame({super.key, required this.kicker, required this.title, required this.description, required this.child});
  final String kicker, title, description;
  final Widget child;
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.fromLTRB(20, 25, 20, 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(kicker, style: const TextStyle(fontSize: 9, color: VoidDesignSystem.neon, fontWeight: FontWeight.w900, letterSpacing: 2)),
      const SizedBox(height: 9), Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.8)),
      const SizedBox(height: 7), Text(description, style: const TextStyle(fontSize: 12, color: VoidDesignSystem.muted, height: 1.5)),
    ])),
    const Divider(height: 1),
    Expanded(child: child),
  ]);
}


class FocusWorkspace extends StatefulWidget {
  const FocusWorkspace({super.key});
  @override State<FocusWorkspace> createState() => _FocusWorkspaceState();
}
class _FocusWorkspaceState extends State<FocusWorkspace> {
  Timer? _timer;
  int _seconds = 25 * 60, _completed = 0;
  bool _running = false, _breakMode = false;
  static const _completedKey = 'network_focus_completed_v1';
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _completed = prefs.getInt(_completedKey) ?? 0);
  }
  String get _clock => '${(_seconds ~/ 60).toString().padLeft(2, '0')}:${(_seconds % 60).toString().padLeft(2, '0')}';
  void _start() {
    if (_running) return;
    setState(() => _running = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_seconds <= 1) {
        timer.cancel();
        setState(() { _running = false; _seconds = 0; });
        _finishSession();
      } else { setState(() => _seconds--); }
    });
  }
  Future<void> _finishSession() async {
    if (!_breakMode) {
      _completed++;
      await (await SharedPreferences.getInstance()).setInt(_completedKey, _completed);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_breakMode ? 'Pausa concluída. Hora de voltar!' : 'Sessão concluída. Faça uma pausa!')));
  }
  void _pause() { _timer?.cancel(); setState(() => _running = false); }
  void _reset() { _timer?.cancel(); setState(() { _running = false; _breakMode = false; _seconds = 25 * 60; }); }
  void _setMode(bool pause) {
    _timer?.cancel();
    setState(() { _running = false; _breakMode = pause; _seconds = (pause ? 5 : 25) * 60; });
  }
  @override void dispose() { _timer?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) => SectionFrame(
    kicker: 'PRODUCTIVITY / FOCUS', title: 'Foco e produtividade',
    description: 'Ciclos de concentração e pausa que funcionam localmente, sem conta ou serviço externo.',
    child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF101010), border: Border.all(color: const Color(0xFF252525)), borderRadius: BorderRadius.circular(9)),
          child: Row(children: [
            Expanded(child: TextButton(onPressed: _running ? null : () => _setMode(false), child: Text('FOCO 25 MIN', style: TextStyle(fontSize: 10, color: !_breakMode ? VoidDesignSystem.neon : const Color(0xFF929292))))),
            Expanded(child: TextButton(onPressed: _running ? null : () => _setMode(true), child: Text('PAUSA 5 MIN', style: TextStyle(fontSize: 10, color: _breakMode ? VoidDesignSystem.neon : const Color(0xFF929292))))),
          ])),
        const SizedBox(height: 34),
        SizedBox(width: 230, height: 230, child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CircularProgressIndicator(value: _seconds / ((_breakMode ? 5 : 25) * 60), strokeWidth: 7, backgroundColor: const Color(0xFF252525), color: VoidDesignSystem.neon)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_clock, style: const TextStyle(fontSize: 49, fontWeight: FontWeight.w300)),
            const SizedBox(height: 5), Text(_breakMode ? 'PAUSA' : 'CONCENTRAÇÃO', style: const TextStyle(fontSize: 9, letterSpacing: 2, color: Color(0xFF929292))),
          ]),
        ])),
        const SizedBox(height: 28),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh, size: 16), label: const Text('REINICIAR')),
          const SizedBox(width: 10),
          FilledButton.icon(onPressed: _running ? _pause : _start, icon: Icon(_running ? Icons.pause : Icons.play_arrow, size: 17), label: Text(_running ? 'PAUSAR' : 'INICIAR')),
        ]),
        const SizedBox(height: 24),
        Text('$_completed sessões de foco concluídas', style: const TextStyle(fontSize: 11, color: Color(0xFF929292))),
      ]),
    ))),
  );
}

class ProjectsWorkspace extends StatefulWidget {
  const ProjectsWorkspace({super.key});
  @override State<ProjectsWorkspace> createState() => _ProjectsWorkspaceState();
}
class _ProjectsWorkspaceState extends State<ProjectsWorkspace> {
  List<Directory> _projects = [];
  bool _loading = true;
  @override void initState() { super.initState(); _refresh(); }
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/NETWORK/Projects');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }
  Future<void> _refresh() async {
    final root = await _root();
    final items = root.listSync().whereType<Directory>().toList();
    if (mounted) setState(() { _projects = items; _loading = false; });
  }
  Future<void> _create() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Novo projeto'), content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Nome do projeto')),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Criar'))]));
    final name = controller.text.trim().replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '').replaceAll(' ', '_');
    controller.dispose();
    if (ok == true && name.isNotEmpty) { final root = await _root(); await Directory('${root.path}/$name').create(recursive: true); await _refresh(); }
  }
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'WORKSPACE / FILE SYSTEM', title: 'Projetos', description: 'Diretórios de trabalho locais do NETWORK.', child: _loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
    Padding(padding: const EdgeInsets.all(16), child: Row(children: [
      Text('${_projects.length} PROJETOS', style: const TextStyle(fontSize: 9, color: VoidDesignSystem.muted, letterSpacing: 1.4)),
      const Spacer(), FilledButton.icon(onPressed: _create, icon: const Icon(Icons.create_new_folder_outlined, size: 16), label: const Text('NOVO PROJETO', style: TextStyle(fontSize: 9))),
    ])),
    Expanded(child: _projects.isEmpty ? const Center(child: Text('Nenhum projeto criado.', style: TextStyle(color: VoidDesignSystem.muted))) : ListView.separated(
      itemCount: _projects.length, separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) => ListTile(leading: const Icon(Icons.folder_outlined, color: VoidDesignSystem.neon),
        title: Text(_projects[i].path.split('/').last, style: const TextStyle(fontSize: 12)),
        subtitle: Text(_projects[i].path, style: const TextStyle(fontSize: 9, color: VoidDesignSystem.muted)),
        trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () async { await _projects[i].delete(recursive: true); await _refresh(); })),
    )),
  ]));
}

class ServersWorkspace extends StatefulWidget {
  const ServersWorkspace({super.key, required this.manager});
  final SshManager manager;
  @override State<ServersWorkspace> createState() => _ServersWorkspaceState();
}
class _ServersWorkspaceState extends State<ServersWorkspace> {
  List<VpsTarget> _targets = [];
  bool _busy = false;
  @override void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async { final list = await widget.manager.targets(); if (mounted) setState(() => _targets = list); }
  Future<void> _add() async {
    final name = TextEditingController(), host = TextEditingController(), user = TextEditingController(), pass = TextEditingController(), key = TextEditingController();
    final port = TextEditingController(text: '22');
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Cadastrar servidor'),
      content: SingleChildScrollView(child: Column(children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Identificador (vpsb1)')),
        TextField(controller: host, decoration: const InputDecoration(labelText: 'Host ou IPv6')),
        TextField(controller: user, decoration: const InputDecoration(labelText: 'Usuário SSH')),
        TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Porta')),
        TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Senha (opcional)')),
        TextField(controller: key, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Chave privada (opcional)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Salvar'))]));
    if (ok == true && name.text.trim().isNotEmpty && host.text.trim().isNotEmpty && user.text.trim().isNotEmpty) {
      await widget.manager.saveTarget(VpsTarget(name: name.text.trim(), host: host.text.trim(), username: user.text.trim(), port: int.tryParse(port.text) ?? 22), password: pass.text, privateKey: key.text);
      await _refresh();
    }
    for (final c in [name, host, user, pass, key, port]) { c.dispose(); }
  }
  Future<void> _connect(String name) async {
    setState(() => _busy = true);
    try { final msg = await widget.manager.connect(name); if (mounted) _notice(msg); }
    catch (e) { if (mounted) _notice('Falha SSH: $e'); }
    finally { if (mounted) setState(() => _busy = false); await _refresh(); }
  }
  void _notice(String value) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'INFRASTRUCTURE / SSH', title: 'Servidores', description: 'Gerencie destinos SSH e conexões ativas.', child: Column(children: [
    Padding(padding: const EdgeInsets.all(16), child: Row(children: [
      Text('${_targets.length} DESTINOS', style: const TextStyle(fontSize: 9, color: VoidDesignSystem.muted, letterSpacing: 1.4)),
      const Spacer(), FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 16), label: const Text('ADICIONAR', style: TextStyle(fontSize: 9))),
    ])),
    if (_busy) const LinearProgressIndicator(),
    Expanded(child: _targets.isEmpty ? const Center(child: Text('Nenhum servidor cadastrado.', style: TextStyle(color: VoidDesignSystem.muted))) : ListView.separated(
      itemCount: _targets.length, separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final t = _targets[i]; final active = widget.manager.connected.contains(t.name);
        return ListTile(
          leading: Icon(Icons.dns_outlined, color: active ? const Color(0xFF78B58A) : VoidDesignSystem.muted),
          title: Text(t.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          subtitle: Text('${t.username}@${t.host}:${t.port}', style: const TextStyle(fontSize: 10, color: VoidDesignSystem.muted)),
          trailing: PopupMenuButton<String>(onSelected: (v) async {
            if (v == 'connect') await _connect(t.name);
            if (v == 'disconnect') { await widget.manager.disconnect(t.name); await _refresh(); }
            if (v == 'remove') { await widget.manager.removeTarget(t.name); await _refresh(); }
          }, itemBuilder: (_) => [
            if (!active) const PopupMenuItem(value: 'connect', child: Text('Conectar')),
            if (active) const PopupMenuItem(value: 'disconnect', child: Text('Desconectar')),
            const PopupMenuItem(value: 'remove', child: Text('Remover')),
          ]),
        );
      },
    )),
  ]));
}

class TerminalWorkspace extends StatefulWidget {
  const TerminalWorkspace({super.key, required this.manager});
  final SshManager manager;
  @override State<TerminalWorkspace> createState() => _TerminalWorkspaceState();
}
class _TerminalWorkspaceState extends State<TerminalWorkspace> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<VpsTarget> _targets = [];
  String? _selected;
  String _output = 'NETWORK REMOTE TERMINAL\nSelecione um servidor conectado.\n';
  StreamSubscription<String>? _out, _err;
  bool _busy = false;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _targets = await widget.manager.targets();
    _selected ??= widget.manager.connected.isNotEmpty ? widget.manager.connected.first : (_targets.isNotEmpty ? _targets.first.name : null);
    if (mounted) setState(() {});
  }
  void _append(String value) {
    if (!mounted) return;
    setState(() => _output += value);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent); });
  }
  Future<void> _connect() async {
    final name = _selected; if (name == null) return;
    setState(() => _busy = true);
    try {
      if (!widget.manager.connected.contains(name)) _append('${await widget.manager.connect(name)}\n');
      await widget.manager.openShell(name);
      await _out?.cancel(); await _err?.cancel();
      _out = widget.manager.shellStdout(name).listen(_append);
      _err = widget.manager.shellStderr(name).listen((s) => _append(s));
      _append('Shell pronto: $name\n');
    } catch (e) { _append('ERRO: $e\n'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _send() async {
    final value = _input.text, name = _selected;
    if (value.isEmpty || name == null || _busy) return;
    if (!widget.manager.hasShell(name)) { _append('Abra a sessão SSH primeiro.\n'); return; }
    widget.manager.writeShell(name, '$value\n'); _input.clear();
  }
  @override void dispose() { _out?.cancel(); _err?.cancel(); _input.dispose(); _scroll.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'REMOTE OPERATIONS / LIVE SHELL', title: 'Terminal', description: 'Sessão SSH interativa com saída em tempo real.', child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
    Row(children: [
      Expanded(child: DropdownButtonFormField<String>(value: _targets.any((t) => t.name == _selected) ? _selected : null,
        decoration: const InputDecoration(labelText: 'Servidor'), items: _targets.map((t) => DropdownMenuItem(value: t.name, child: Text(t.name))).toList(),
        onChanged: (v) => setState(() => _selected = v))),
      const SizedBox(width: 8), IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      FilledButton(onPressed: _busy ? null : _connect, child: const Text('CONECTAR')),
    ]),
    const SizedBox(height: 12),
    Expanded(child: Container(width: double.infinity, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF050505), border: Border.all(color: VoidDesignSystem.line), borderRadius: BorderRadius.circular(8)),
      child: SingleChildScrollView(controller: _scroll, child: SelectableText(_output, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.5))))),
    const SizedBox(height: 9),
    Row(children: [
      Expanded(child: TextField(controller: _input, enabled: !_busy, onSubmitted: (_) => _send(), style: const TextStyle(fontFamily: 'monospace', fontSize: 12), decoration: const InputDecoration(hintText: 'Comando SSH...'))),
      const SizedBox(width: 7), IconButton.filled(onPressed: _send, icon: const Icon(Icons.arrow_upward)),
    ]),
  ])));
}

class BrowserWorkspace extends StatefulWidget {
  const BrowserWorkspace({super.key});
  @override State<BrowserWorkspace> createState() => _BrowserWorkspaceState();
}
class _BrowserWorkspaceState extends State<BrowserWorkspace> {
  final TextEditingController _address = TextEditingController();
  final List<String> _recent = [];
  bool _opening = false;
  Future<void> _open([String? value]) async {
    var raw = (value ?? _address.text).trim();
    if (raw.isEmpty) return;
    if (!raw.contains('://')) raw = raw.contains(' ') ? 'https://www.google.com/search?q='+Uri.encodeQueryComponent(raw) : 'https://'+raw;
    final uri = Uri.tryParse(raw);
    if (uri == null || !{'http','https'}.contains(uri.scheme)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Endereço inválido.')));
      return;
    }
    setState(() => _opening = true);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw StateError('Nenhum navegador disponível para abrir o endereço.');
      _address.text = uri.toString();
      setState(() { _recent.remove(uri.toString()); _recent.insert(0, uri.toString()); if (_recent.length > 12) _recent.removeLast(); });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Navegador: $e')));
    } finally { if (mounted) setState(() => _opening = false); }
  }
  @override void dispose() { _address.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'WEB / RESEARCH', title: 'Navegador', description: 'Abra páginas e pesquisas no navegador instalado no Android.', child: Column(children: [
    Padding(padding: const EdgeInsets.all(15), child: Container(
      decoration: BoxDecoration(color: VoidDesignSystem.panel, borderRadius: BorderRadius.circular(9), border: Border.all(color: VoidDesignSystem.line)),
      child: Row(children: [
        const Padding(padding: EdgeInsets.only(left: 12), child: Icon(Icons.lock_outline, size: 16, color: VoidDesignSystem.muted)),
        Expanded(child: TextField(controller: _address, onSubmitted: (_) => _open(), decoration: const InputDecoration(hintText: 'URL ou pesquisa...', border: InputBorder.none, fillColor: Colors.transparent))),
        IconButton(onPressed: _opening ? null : _open, icon: Icon(Icons.arrow_forward, color: VoidDesignSystem.neon)),
      ]),
    )),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
      const Text('ACESSO RÁPIDO', style: TextStyle(fontSize: 9, color: VoidDesignSystem.muted, letterSpacing: 1.5)),
      const Spacer(), if (_opening) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
    ])),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: [
      _BrowserShortcut(label: 'Google', url: 'https://www.google.com', onOpen: _open),
      _BrowserShortcut(label: 'GitHub', url: 'https://github.com', onOpen: _open),
      _BrowserShortcut(label: 'Documentação Flutter', url: 'https://docs.flutter.dev', onOpen: _open),
    ]),
    const Divider(height: 28),
    const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Align(alignment: Alignment.centerLeft, child: Text('RECENTES', style: TextStyle(fontSize: 9, color: VoidDesignSystem.muted, letterSpacing: 1.5)))),
    Expanded(child: _recent.isEmpty ? const Center(child: Text('Nenhuma página aberta nesta sessão.', style: TextStyle(fontSize: 12, color: VoidDesignSystem.muted))) : ListView.builder(
      itemCount: _recent.length,
      itemBuilder: (c,i) => ListTile(leading: const Icon(Icons.language, size: 18, color: VoidDesignSystem.muted),
        title: Text(_recent[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        onTap: () => _open(_recent[i])),
    )),
  ]));
}
class _BrowserShortcut extends StatelessWidget {
  const _BrowserShortcut({required this.label, required this.url, required this.onOpen});
  final String label, url; final ValueChanged<String> onOpen;
  @override Widget build(BuildContext context) => ActionChip(
    onPressed: () => onOpen(url), label: Text(label, style: const TextStyle(fontSize: 11)),
    backgroundColor: VoidDesignSystem.panel, side: const BorderSide(color: VoidDesignSystem.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );
}

class MemoryWorkspace extends StatefulWidget {
  const MemoryWorkspace({super.key});
  @override State<MemoryWorkspace> createState() => _MemoryWorkspaceState();
}
class _MemoryWorkspaceState extends State<MemoryWorkspace> {
  final TextEditingController _note = TextEditingController();
  List<File> _files = [];
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/NETWORK/Memory');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
  Future<void> _refresh() async { final d = await _root(); if (mounted) setState(() => _files = d.listSync().whereType<File>().toList()); }
  Future<void> _save() async {
    if (_note.text.trim().isEmpty) return;
    final d = await _root(); await File('${d.path}/${DateTime.now().millisecondsSinceEpoch}.txt').writeAsString(_note.text.trim());
    _note.clear(); await _refresh();
  }
  @override void initState() { super.initState(); _refresh(); }
  @override void dispose() { _note.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'LOCAL CONTEXT / NOTES', title: 'Memória', description: 'Notas persistentes armazenadas neste aparelho.', child: Column(children: [
    Padding(padding: const EdgeInsets.all(15), child: Column(children: [
      TextField(controller: _note, minLines: 2, maxLines: 4, decoration: const InputDecoration(hintText: 'Registrar decisão, contexto ou lembrete...')),
      const SizedBox(height: 8), Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _save, child: const Text('SALVAR NOTA'))),
    ])),
    const Divider(height: 1),
    Expanded(child: _files.isEmpty ? const Center(child: Text('Nenhuma nota salva.', style: TextStyle(color: VoidDesignSystem.muted))) : ListView.builder(
      itemCount: _files.length, itemBuilder: (c, i) => FutureBuilder<String>(future: _files[i].readAsString(), builder: (c, s) =>
        ListTile(title: Text(_files[i].path.split('/').last, style: const TextStyle(fontSize: 11)), subtitle: Text(s.data ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: VoidDesignSystem.muted)),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await _files[i].delete(); await _refresh(); }))),
    )),
  ]));
}

class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({super.key, required this.mode, required this.onModeChanged});
  final String mode;
  final ValueChanged<String> onModeChanged;
  @override State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}
class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  late final TextEditingController _appName = TextEditingController(text: 'NET work');
  bool _loading = true, _saving = false;
  static const _appearanceKey = 'network_void_appearance_v1';
  static const _colors = [VoidDesignSystem.neon, Color(0xFFE4E4E4), Color(0xFF8790A0), Color(0xFFC5A779)];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_appearanceKey);
    if (raw != null) {
      try {
        final data = Map<String,dynamic>.from(jsonDecode(raw) as Map);
        _appName.text = data['appName']?.toString() ?? 'NET work';
        VoidDesignSystem.appName.value = _appName.text;
        final color = int.tryParse(data['accent']?.toString() ?? '');
        if (color != null) VoidDesignSystem.accent.value = color == 0xFFD63A42 || color == 0xFFE53935 ? VoidDesignSystem.neon : Color(color);
        final skin = data['skin']?.toString();
        if (['void','graphite'].contains(skin)) VoidDesignSystem.skin.value = skin!; else if (skin == 'red') VoidDesignSystem.skin.value = 'void';
        VoidDesignSystem.motion.value = data['motion'] != false;
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }
  Future<void> _saveAppearance() async {
    VoidDesignSystem.appName.value = _appName.text.trim().isEmpty ? 'NET work' : _appName.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceKey, jsonEncode({
      'appName': _appName.text.trim().isEmpty ? 'NET work' : _appName.text.trim(),
      'accent': VoidDesignSystem.accent.value.value,
      'skin': VoidDesignSystem.skin.value,
      'motion': VoidDesignSystem.motion.value,
    }));
  }
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _saveAppearance();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configurações salvas com segurança.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao salvar: $e')));
    } finally { if (mounted) setState(() => _saving = false); }
  }
  @override void dispose() { _appName.dispose(); super.dispose(); }

  Widget _sectionTitle(String title, String number) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: Row(children: [
      Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFECECEC))),
      const Spacer(), Text(number, style: const TextStyle(fontSize: 10, color: Color(0xFF575757), fontFamily: 'monospace')),
    ]),
  );
  Widget _fieldLabel(String value) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 6), child: Text(value, style: const TextStyle(fontSize: 10, color: Color(0xFF969696))));
  Widget _palette(String id, String label, Color color) => Expanded(child: InkWell(
    onTap: () { setState(() => VoidDesignSystem.skin.value = id); _saveAppearance(); },
    borderRadius: BorderRadius.circular(6),
    child: Container(height: 61, padding: const EdgeInsets.all(7), decoration: BoxDecoration(
      color: const Color(0xFF101010), border: Border.all(color: VoidDesignSystem.skin.value == id ? VoidDesignSystem.accent.value : const Color(0xFF242424)), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Container(height: 25, width: double.infinity, decoration: BoxDecoration(color: color, border: Border.all(color: const Color(0xFF292929)), borderRadius: BorderRadius.circular(3))),
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFFBBBBBB))),
      ]),
    ),
  ));
  @override Widget build(BuildContext context) => _loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 14), child: Row(children: [
      const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('NET WORK', style: TextStyle(fontSize: 9, color: VoidDesignSystem.neon, fontWeight: FontWeight.w700, letterSpacing: 1.7)),
        SizedBox(height: 5), Text('Personalizar', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ])),
      IconButton(onPressed: _save, icon: const Icon(Icons.check, size: 18), tooltip: 'Salvar configurações'),
    ])),
    const Divider(height: 1),
    Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(22, 4, 22, 24), children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Identidade', '01'),
        _fieldLabel('Nome do app'),
        TextField(controller: _appName, maxLength: 24, onChanged: (v) => VoidDesignSystem.appName.value = v.trim().isEmpty ? 'NET work' : v.trim(), decoration: const InputDecoration(counterText: '', hintText: 'NET work')),
      ])),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Aparência', '02'),
        Row(children: [
          _palette('void', 'VOID', Colors.black), const SizedBox(width: 8),
          _palette('graphite', 'Graphite', const Color(0xFF202020)), const SizedBox(width: 8),
        ]),
        _fieldLabel('Cor de destaque'),
        Wrap(spacing: 15, children: _colors.map((color) => InkWell(
          onTap: () { setState(() => VoidDesignSystem.accent.value = color); _saveAppearance(); },
          child: Container(width: 20, height: 20, decoration: BoxDecoration(color: color, shape: BoxShape.circle,
            border: Border.all(color: VoidDesignSystem.accent.value == color ? Colors.white : Colors.transparent, width: 2))),
        )).toList()),
        const SizedBox(height: 15),
        OutlinedButton.icon(onPressed: () async {
          final selected = await showDialog<Color>(context: context, builder: (c) => AlertDialog(
            title: const Text('Escolher cor'), content: Wrap(spacing: 12, runSpacing: 12, children: _colors.map((color) => InkWell(
              onTap: () => Navigator.pop(c, color), child: Container(width: 34, height: 34, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            )).toList()),
          ));
          if (selected != null) { setState(() => VoidDesignSystem.accent.value = selected); _saveAppearance(); }
        }, icon: const Icon(Icons.color_lens_outlined, size: 15), label: const Text('Escolher cor')),
      ])),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Movimento', '03'),
        SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('Animações', style: TextStyle(fontSize: 11)),
          subtitle: const Text('Transições sutis na interface', style: TextStyle(fontSize: 9, color: Color(0xFF777777))),
          value: VoidDesignSystem.motion.value, onChanged: (v) { setState(() => VoidDesignSystem.motion.value = v); _saveAppearance(); }),
      ])),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Ambiente padrão', '04'),
        ...{'automatic': 'Local', 'vps': 'VPS / SSH', 'github': 'GitHub', 'browser': 'Nuvem / navegador', 'plugins': 'Conectores'}.entries.map((e) => RadioListTile<String>(
          value: e.key, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onModeChanged(v); },
          title: Text(e.value, style: const TextStyle(fontSize: 11)), activeColor: VoidDesignSystem.accent.value, contentPadding: EdgeInsets.zero,
        )),
      ])),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: _saving ? null : _save,
        child: Text(_saving ? 'SALVANDO…' : 'SALVAR ALTERAÇÕES', style: const TextStyle(fontSize: 10, letterSpacing: .8)))),
    ])),
  ]);
}

class ConnectorsWorkspace extends StatefulWidget {
  const ConnectorsWorkspace({super.key, required this.github});
  final GithubService github;
  @override State<ConnectorsWorkspace> createState() => _ConnectorsWorkspaceState();
}
class _ConnectorsWorkspaceState extends State<ConnectorsWorkspace> {
  bool _connected = false, _busy = false;
  String _account = '';
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final ok = await widget.github.isConfigured; if (mounted) setState(() => _connected = ok); if (ok) { final name = await widget.github.authenticatedUsername(); if (mounted) setState(() => _account = name); } } catch (_) {}
  }
  Future<void> _connect() async {
    final token = TextEditingController();
    final accepted = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Conectar GitHub'),
      content: TextField(controller: token, obscureText: true, decoration: const InputDecoration(labelText: 'Personal access token', hintText: 'ghp_…')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Conectar')),
      ],
    ));
    if (accepted != true || token.text.trim().isEmpty) { token.dispose(); return; }
    setState(() => _busy = true);
    try { await widget.github.configureToken(token.text.trim()); await _load(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('GitHub: $e'))); }
    finally { token.dispose(); if (mounted) setState(() => _busy = false); }
  }
  @override Widget build(BuildContext context) => SectionFrame(kicker: 'INTEGRATIONS / ACCESS', title: 'Conectores', description: 'Contas e serviços autorizados para o agente.', child: ListView(padding: const EdgeInsets.all(16), children: [
    Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: VoidDesignSystem.panel, border: Border.all(color: VoidDesignSystem.line), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.code, size: 25, color: VoidDesignSystem.text), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('GitHub', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4), Text(_connected ? 'Conectado como @$_account' : 'Autorize o acesso aos seus repositórios.', style: const TextStyle(fontSize: 10, color: VoidDesignSystem.muted)),
        ])),
        if (_connected) IconButton(onPressed: () async { await widget.github.disconnect(); if (mounted) setState(() { _connected = false; _account = ''; }); }, icon: const Icon(Icons.link_off))
        else FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'AGUARDE' : 'CONECTAR')),
      ])),
  ]));
}
