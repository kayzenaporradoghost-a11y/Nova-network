# NETWORK GitHub OAuth Worker

Este Worker faz somente a troca do código OAuth por tokens. O segredo do OAuth App fica como secret no Cloudflare e nunca é incluído no APK.

## Configuração única

1. Crie um OAuth App em https://github.com/settings/developers (OAuth Apps > New OAuth App).
2. Homepage URL: https://github.com/
3. Authorization callback URL: http://127.0.0.1/callback
   - O aplicativo usa uma porta loopback temporária; o GitHub aceita loopback IP com porta variável.
4. No Cloudflare, use o Worker `network-github-auth` conectado a este repositório. O deploy automático usa `npx wrangler deploy --config serverless/github-auth-worker/wrangler.toml`.
5. Configure os secrets/vars no Worker:
   - `GITHUB_CLIENT_ID` (variable)
   - `GITHUB_CLIENT_SECRET` (secret)
   Use Settings > Variables and Secrets. Nunca coloque o Client Secret no código ou no APK.
6. Teste `GET https://SEU-WORKER.SEU-SUBDOMINIO.workers.dev/oauth/config`; deve retornar JSON com `client_id`.
7. Compile o app com:
   `flutter build apk --release --dart-define=GITHUB_AUTH_URL=https://SEU-WORKER.SEU-SUBDOMINIO.workers.dev`

## Segurança

- PKCE S256 é gerado no dispositivo; o verifier só é enviado ao Worker junto do código.
- Worker aceita somente callback IPv4 loopback com porta válida e endpoint fixo do GitHub.
- Worker não registra nem armazena código, verifier, Client Secret ou tokens.
- O token é retornado diretamente ao app e guardado no Android Keystore via flutter_secure_storage.
- Use somente as permissões OAuth necessárias. O app atual pede `repo` e `read:user` para as funções de leitura/escrita de repositórios.
