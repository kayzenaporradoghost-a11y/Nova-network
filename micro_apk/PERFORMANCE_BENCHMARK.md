# NETWORK — benchmark de desempenho no Android

O projeto inclui duas camadas de medição:

- **Telemetria do runtime:** mede idade do evento de Acessibilidade no Android, tempo de montagem do snapshot, ingestão no Dart, inferência do modelo, consultas dos especialistas e duração das ferramentas. O relatório p50/p95 fica disponível à IA pela ferramenta `agent_performance_report`. As amostras ficam em memória no processo atual, acumuladas entre tarefas (até 500 por métrica); reiniciar o app zera essa coleta.
- **Teste no dispositivo:** `integration_test/network_performance_test.dart` mede o primeiro frame do app, leitura da tela pelo canal nativo e entrega do primeiro snapshot de Acessibilidade.

## Executar no celular físico

No diretório `micro_apk/`:

```bash
flutter pub get
flutter devices
flutter test integration_test/network_performance_test.dart -d ID_DO_CELULAR
```

Antes do teste, instale a versão de desenvolvimento no aparelho, habilite **NETWORK — Controle do celular** em Acessibilidade e mantenha o telefone desbloqueado. Use o ID retornado por `flutter devices`.

O teste publica os valores em `network_device_benchmark` no relatório do Integration Test. Se Acessibilidade estiver desligada, o teste registra o motivo em vez de inventar uma latência.

## Como interpretar

- `startup_first_frame_ms`: inicialização até o primeiro frame bombeado pelo teste.
- `phone_screen_read_ms`: ida e volta da leitura nativa da tela.
- `accessibility_event_wait_ms`: tempo para o primeiro snapshot depois da inscrição no EventChannel.
- `accessibility_event_age_ms`: idade do evento Android quando o snapshot é montado.
- `accessibility_snapshot_build_ms`: tempo para montar o snapshot de Acessibilidade.

Para p50/p95 confiáveis, colete várias execuções e uso real no mesmo aparelho, versão do Android, estado de bateria e carga de CPU. A meta de 10 ms aplica-se somente a etapas internas leves que forem medidas; não é uma promessa para abrir apps, inferir respostas remotas ou concluir uma tarefa ponta a ponta.
