import 'package:flutter_test/flutter_test.dart';
import 'package:micro_apk/core/agent_intent_router.dart';

void main() {
  test('routes only a standalone open-app request', () {
    expect(AgentIntentRouter.simpleOpenApp('Abre o WhatsApp'), 'WhatsApp');
    expect(AgentIntentRouter.simpleOpenApp('abrir app Instagram'), 'Instagram');
    expect(AgentIntentRouter.simpleOpenApp('Open Chrome.'), 'Chrome');
    expect(AgentIntentRouter.simpleOpenApp('Inicie o aplicativo Spotify'), 'Spotify');
  });

  test('does not fast-route requests containing a second action', () {
    expect(AgentIntentRouter.simpleOpenApp('Abre o WhatsApp e manda mensagem'), isNull);
    expect(AgentIntentRouter.simpleOpenApp('Abre Instagram e pesquisa reels'), isNull);
    expect(AgentIntentRouter.simpleOpenApp('Abre o app e depois configura'), isNull);
    expect(AgentIntentRouter.simpleOpenApp('Abra a tela de configurações e ative o Bluetooth'), isNull);
  });

  test('rejects ambiguous or long prompts', () {
    expect(AgentIntentRouter.simpleOpenApp(''), isNull);
    expect(AgentIntentRouter.simpleOpenApp('Abra o aplicativo'), isNull);
    expect(AgentIntentRouter.simpleOpenApp('Abra o WhatsApp e me diga o que está acontecendo nesta conversa'), isNull);
  });
}
