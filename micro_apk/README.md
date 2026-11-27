# NETWORK — agente de IA para Android

O NETWORK é um aplicativo Android em português com um agente que planeja tarefas, chama ferramentas, observa os resultados e continua até concluir ou encontrar um bloqueio verificável.

## Motor do agente

- Motor ativo: `ToolAgentService` em `lib/services/tool_agent_service.dart`.
- Loop: envia contexto e ferramentas ao modelo; recebe uma resposta ou uma chamada de ferramenta; executa uma ação; devolve o resultado ao modelo; repete.
- Executa uma chamada de ferramenta por ciclo para inspecionar cada resultado antes da próxima ação.
- Limite operacional atual: até 300 ciclos por objetivo, com proteção contra repetição idêntica sem progresso.
- A fila `TaskOrchestrator` separa objetivos e salva cursor, resultados e estado pausado.
- Checkpoint detalhado do ciclo fica no armazenamento seguro Android e expira após sete dias.
- O contexto inclui mensagens, argumentos e esquemas das ferramentas. Quando cresce, o histórico antigo é compactado preservando decisões, ações e resultados recentes; erros de janela de contexto acionam nova compactação e tentativa limitada.
- Especialistas planner, architect, reviewer, security e tester são análises independentes somente leitura; o agente principal continua responsável por executar e verificar.

## Modelo e provedor

- Endpoint: `https://ai-gateway.kilo.ai/api/v1`.
- Modelo: `kilo-auto/free`.
- O Kilo Auto Free encaminha cada sessão para modelos gratuitos disponíveis; o modelo subjacente pode mudar e a capacidade/contexto não são fixos.
- Modelos gratuitos aceitam uso anônimo com limite publicado de 200 solicitações por hora por IP. Limites upstream e disponibilidade podem variar.
- O Gateway oferece API compatível com OpenAI e chamadas de ferramentas. O suporte efetivo depende do modelo gratuito roteado.
- Atenção à privacidade: o Auto Free pode encaminhar prompts e respostas a provedores parceiros que os registram e usam para melhorar serviços. Não envie segredos nem dados confidenciais.

## Ferramentas

- SSH multi-VPS: executar comandos, inspecionar e editar arquivos, verificar serviços e rodar testes em servidores cadastrados.
- GitHub: repositórios, arquivos, commits, branches, pull requests, Actions, logs e artefatos.
- Navegador visual com sessão persistente: abrir páginas, inspecionar DOM, clicar, preencher, navegar e baixar arquivos.
- MCP: descobrir e executar ferramentas de servidores MCP conectados.
- Docker remoto por SSH: status, logs e reinício de containers.
- Memória local: decisões, caminhos, erros corrigidos e estado do projeto.

## Limites reais

- O NETWORK não é o Codex App Server nem incorpora o runtime proprietário/gerenciado da OpenAI. Implementa um harness próprio inspirado nos conceitos públicos do Codex: loop de agente, roteamento de ferramentas, estado de sessão, checkpoints e compactação.
- Não há sandbox isolado gerenciado pelo provedor: ferramentas rodam no aparelho, no navegador ou na VPS escolhida. O ambiente remoto e as permissões dependem das conexões configuradas.
- A memória é local ao aparelho; não é Mem0 e não sincroniza automaticamente entre dispositivos.
- O modelo `kilo-auto/free` é dinâmico e pode ter menor qualidade, contexto ou suporte a imagens/ferramentas que modelos pagos.
- O APK não contém pesos de modelos locais de vários GB.

## Build e validação

O workflow `Build NETWORK APK` executa `flutter analyze`, `flutter test`, compila APK Android ARM64 e publica o APK no GitHub Releases e como artefato de CI.
