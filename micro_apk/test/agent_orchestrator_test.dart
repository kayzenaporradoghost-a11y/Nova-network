import 'package:flutter_test/flutter_test.dart';
import 'package:micro_apk/core/agent_orchestrator.dart';

void main() {
  test('registry contains exactly 130 unique specialist profiles', () {
    expect(AgentOrchestrator.all, hasLength(130));
    expect(AgentOrchestrator.all.map((profile) => profile.id).toSet(), hasLength(130));
  });

  test('local router prioritizes messaging specialists for WhatsApp tasks', () {
    final selected = AgentOrchestrator.route('Abra o WhatsApp e envie uma mensagem para um contato');
    expect(selected, isNotEmpty);
    expect(selected.any((profile) => profile.domain == 'messaging'), isTrue);
    expect(selected.length, lessThanOrEqualTo(12));
  });

  test('local router selects GitHub and coding specialists for repository work', () {
    final selected = AgentOrchestrator.route('Corrija o bug no GitHub, rode os testes e valide o commit');
    expect(selected.any((profile) => profile.domain == 'github'), isTrue);
    expect(selected.any((profile) => profile.domain == 'coding'), isTrue);
  });

  test('unknown specialist IDs are not resolved', () {
    expect(AgentOrchestrator.find('not_a_real_agent'), isNull);
  });
}
