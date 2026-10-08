# devkit

O deploy de todos os projetos, num script só. Cada projeto tem apenas um `deploy.conf` com o que é
dele; todo o resto (rodar em dev, empacotar, publicar na VPS, HTTPS, rollback) fica aqui.

```bash
cd ~/Documentos/meu-projeto
~/Documentos/devkit/deploy.sh local              # roda o projeto aqui (dev/teste)
~/Documentos/devkit/deploy.sh vps router-vps     # publica na VPS, completo
```

## Os dois modos

**`local`**: roda o projeto da pasta atual em primeiro plano (Ctrl+C para), com o `.env` do projeto.
Se o `.env` não existe, ele é criado a partir do `.env.example`; o que for obrigatório e estiver
vazio é perguntado e gravado nele.

**`vps HOST`**: publica o projeto da pasta atual na VPS e só termina quando tudo funciona: serviço
de pé, site no HTTPS e o endereço público respondendo de fora. `HOST` é um alias do `~/.ssh/config`
ou `usuario@host`. O resto é opcional:

| Opção | Para quê |
|---|---|
| `--domain DOMINIO` | endereço público do app (padrão: o que a VPS já usa para ele) |
| `--no-domain` | sem endereço público (o site do app sai do Caddy) |
| `--cert ARQUIVO --key ARQUIVO` | Certificado de Origem do Cloudflare (SSL "Full (strict)") |
| `--env ARQUIVO` | envia a configuração deste arquivo para a VPS (veja [Configuração na VPS](#configuração-na-vps)) |
| `--preserve` | com `--env`: o que a VPS já tem com valor fica; o enviado só preenche o que falta |
| `--path PASTA` | pasta do app na VPS (padrão: `/srv/<app>`) |

O que faltar é perguntado no terminal, e a resposta fica guardada na VPS (o próximo deploy não
pergunta de novo):

| Faltou | O que acontece |
|---|---|
| Domínio (app com site, VPS sem domínio para ele) | pergunta; vazio = sem HTTPS |
| Certificado (VPS não tem e você não passou) | pergunta se o domínio está no Cloudflare em "Full (strict)"; se sim, pede o `.pem` e o `.key`; se não, usa Let's Encrypt |
| Configuração do app na VPS | oferece usar o `.env` do projeto; o que for obrigatório e estiver vazio é perguntado |
| Root (1ª vez: pasta, linger, Caddy, firewall) | usa o sudo sem senha ou pede a sua senha do sudo |

Sem terminal (CI), nada é perguntado: o deploy para dizendo exatamente o que falta.

Ajudantes: `deploy.sh status|logs|restart|stop HOST`.

## deploy.conf

Fica na raiz de cada projeto. É lido como texto (nunca executado). Exemplo:

```bash
APP=meu-app                                   # nome do app: serviço, pasta e site
DEV="uv run meu-app"                          # modo local
BUILD="cd frontend && npm ci && npm run build"   # opcional: na sua máquina/CI, antes de empacotar
INCLUDE="frontend/dist"                       # opcional: saídas do build ignoradas pelo git
INSTALL="uv sync --frozen --no-dev"           # na VPS, dentro da versão nova
RUN=".venv/bin/meu-app --port {port}"         # na VPS, o processo do serviço
HEALTH=/healthz                               # caminho que responde 200 (sem ele, o app não tem site)
REQUIRED="TOKEN API_KEY"                      # configuração obrigatória
PRESERVE="LOG_HASH_SALT"                      # opcional: sobrevivem aos deploys (veja abaixo)
SERVICE_ENV="DATA_DIR={data} PORT={port} PUBLIC_URL={url}"   # variáveis fixas do serviço
```

Em `RUN` e `SERVICE_ENV`: `{root}` (pasta do app), `{data}` (dados persistentes), `{port}` (porta
interna, só em 127.0.0.1, escolhida pelo devkit sem conflito com outros apps), `{domain}` e `{url}`
(`https://dominio`, ou vazio sem domínio). Na VPS, `uv` e o Python dele já estão no `PATH` do
`INSTALL` e do `RUN`.

`RUN` é **um comando só**: o devkit faz `exec <RUN>` na pasta da versão. Em vez de
`cd backend && uvicorn ...`, use as opções do próprio programa (ex.: `uvicorn --app-dir backend ...`).

**`PRESERVE`**: chaves que o servidor pode inventar (um salt, uma chave interna). Se uma delas
ficar sem valor depois do deploy, o devkit gera um aleatório (48 caracteres hex) e o guarda; nos
deploys seguintes ele fica. Um valor enviado para ela vence; enviada vazia, é ignorada.

## Configuração na VPS

A configuração do app fica em `/srv/<app>/.env`. Num deploy, a configuração **enviada** (o
`--env ARQUIVO` no terminal, ou a entrada `env` da action no CI) é aplicada sobre ela, chave a
chave:

| Situação | Sem `--preserve` (padrão) | Com `--preserve` / `DEPLOY_PRESERVE=true` |
|---|---|---|
| Chave enviada com valor | o valor enviado substitui o da VPS | fica o da VPS, se tiver valor; senão, o enviado |
| Chave enviada vazia (`CHAVE=`) | sai do `.env` (o app usa o padrão dele) | fica o da VPS, se tiver valor |
| Chave que não foi enviada | fica como está | fica como está |

Sem nada enviado (`deploy.sh vps HOST` sem `--env`), a configuração da VPS fica como está. O que
for obrigatório (`REQUIRED`) e ficar vazio é perguntado no terminal; no CI, o deploy para antes de
mexer em qualquer coisa.

## Na VPS

Vários apps convivem na mesma VPS sem se tocar. Cada um fica na pasta dele e roda com o usuário do
SSH, sem root:

| O quê | Onde |
|---|---|
| Versões (as 3 últimas) e a atual | `/srv/<app>/releases/` · `current` |
| Configuração do app | `/srv/<app>/.env` |
| Dados persistentes | `/srv/<app>/data/` |
| uv e Python próprios (versão fixa, checksum conferido) | `/srv/<app>/tools/` |
| Estado do deploy (domínio, porta, trava) | `/srv/<app>/.devkit/` |
| Serviço (systemd do usuário, com linger) | `~/.config/systemd/user/<app>.service` |

O HTTPS vem de uma **camada compartilhada do Caddy**: um único Caddy (pacote oficial, serviço do
sistema) para todos os apps, que não pertence a nenhum deles.

| O quê | Onde |
|---|---|
| Caddyfile da camada: só importa os sites | `/etc/caddy/Caddyfile` |
| Site de cada app, escrito e removido só pelo deploy dele | `/srv/caddy/sites/<app>.caddy` |
| Certificado de Origem do Cloudflare (opcional) | `/srv/caddy/certs/<app>.pem` e `.key` |
| Serviço que libera as portas 80/443 a cada boot | `/etc/systemd/system/devkit-ports.service` |

Só duas situações são aceitas: **a camada já existe**, ou **não há Caddy nenhum** (e ela é
instalada). Qualquer outra coisa, como outro Caddy rodando ou outro programa nas portas 80/443,
para o deploy com o motivo, antes de mexer em qualquer app. O site novo é validado junto com os dos
outros apps antes de entrar (dois apps com o mesmo domínio, por exemplo, são recusados), e um
reload recusado restaura o anterior.

Todo site sai comprimido (zstd ou gzip) e o app recebe o **IP real do visitante** em
`X-Forwarded-For` e `X-Real-IP`. Atrás do Cloudflare, ele vem do `CF-Connecting-IP`, aceito só das
faixas do Cloudflare: de qualquer outro lugar o cabeçalho é ignorado, então não dá para falsificar
o IP. Em apps Python com uvicorn, use `--proxy-headers --forwarded-allow-ips 127.0.0.1`.
Uma VPS com a camada de uma versão anterior é atualizada no próximo deploy (com sudo), por reload,
sem derrubar os sites.

**Firewall.** Num app com site, todo deploy confere se as portas 80 e 443 estão liberadas no
firewall da VPS (ufw, firewalld, iptables ou nftables) e, se não estiverem, as libera com root.
Regras de iptables/nftables que não foram salvas somem quando a VPS reinicia (é o caso das imagens
da Oracle Cloud): por isso o devkit instala o serviço `devkit-ports`, que as recoloca a cada boot,
antes do Caddy subir, sem precisar de um deploy. O devkit nunca liga um firewall que está
desligado nem mexe em outras portas (o SSH fica como está), e uma regra que já aceita a porta,
mesmo só de algumas origens (como as faixas do Cloudflare), é respeitada.

| Sudo do usuário do SSH | O que o deploy confere |
|---|---|
| sem senha | as regras do firewall, a cada deploy; fechou, ele abre |
| com senha | o serviço `devkit-ports` instalado e sem falha; senão pede a senha (no terminal) |
| nenhum (ou CI sem sudo sem senha) | só avisa; a conferência de fora no fim diz se o site responde |

O firewall do provedor (security group da AWS, security list da Oracle Cloud etc.) fica fora da
VPS: libere 80 e 443 no painel dele.

A versão nova só fica se o serviço continuar de pé e, com site, responder no `HEALTH`; senão volta
a anterior, com o log do app na tela. No fim, o deploy acessa `https://dominio/HEALTH` de fora e
falha, com a causa provável (DNS, erro 526 de certificado, VPS inacessível), se não responder.

## CI/CD (GitHub Actions)

No workflow do projeto, depois dos testes:

```yaml
  deploy:
    needs: test
    if: github.ref == 'refs/heads/main' && vars.DEPLOY_ENABLED == 'true'
    runs-on: ubuntu-latest
    environment: production
    concurrency: { group: deploy-production, cancel-in-progress: false }
    steps:
      - uses: actions/checkout@v7
      - uses: krosct/devkit@v1.0.0
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          user: ${{ secrets.DEPLOY_USER }}
          port: ${{ secrets.DEPLOY_PORT || vars.DEPLOY_PORT || '22' }}
          ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
          known-hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
          path: ${{ secrets.DEPLOY_PATH || vars.DEPLOY_PATH }}
          domain: ${{ secrets.DEPLOY_SITE_ADDRESS || vars.DEPLOY_SITE_ADDRESS }}
          origin-cert: ${{ secrets.DEPLOY_ORIGIN_CERT }}
          origin-key: ${{ secrets.DEPLOY_ORIGIN_KEY }}
          preserve: ${{ secrets.DEPLOY_PRESERVE || vars.DEPLOY_PRESERVE }}
          # A configuração do app: uma linha por chave, cada uma com o secret ou variable dela.
          env: |
            TOKEN=${{ secrets.TOKEN || vars.TOKEN }}
            API_KEY=${{ secrets.API_KEY }}
            GITHUB_CLIENT_ID=${{ secrets.GH_OAUTH_CLIENT_ID || vars.GH_OAUTH_CLIENT_ID }}
```

Na entrada `env`, cada linha é `CHAVE=valor` (linhas em branco e `#` são ignoradas; um valor não
pode ter quebra de linha). Um secret que não existe vira `CHAVE=` e a chave sai do `.env` da VPS
(veja [Configuração na VPS](#configuração-na-vps)). Passe só os secrets que o app usa, um por um:
nunca `toJSON(secrets)`, que entrega todos (o GitHub segura o workflow como suspeito em
repositórios públicos). O formato antigo (`ENV` no `deploy.conf` com `secrets: ${{ toJSON(secrets) }}`)
ainda funciona, com um aviso, até o projeto migrar.

| Secret | |
|---|---|
| `DEPLOY_HOST`, `DEPLOY_USER` | a VPS e o usuário do SSH (o mesmo para todos os apps) |
| `DEPLOY_SSH_KEY` | chave privada só para o deploy: `ssh-keygen -t ed25519 -f deploy -N ''` |
| `DEPLOY_KNOWN_HOSTS` | saída de `ssh-keyscan <ip-da-vps>` |
| `DEPLOY_SITE_ADDRESS` | opcional: o domínio do app |
| `DEPLOY_ORIGIN_CERT`, `DEPLOY_ORIGIN_KEY` | opcionais: o Certificado de Origem e a chave (PEM) |
| `DEPLOY_PATH`, `DEPLOY_PORT` | opcionais |
| `DEPLOY_PRESERVE` | opcional (variable): `true` mantém o que a VPS já tem com valor |
| Os da entrada `env` | a configuração do app |

O CI precisa de sudo sem senha na VPS só se ela ainda não estiver preparada (pasta, linger ou
Caddy); depois de um primeiro deploy pelo terminal, não precisa mais. Sem ele, o CI não confere as
regras do firewall a cada deploy (confia no serviço `devkit-ports`; veja [Na VPS](#na-vps)).

## Versões

Os projetos usam o devkit por uma versão fixa (`krosct/devkit@v1.0.0`), nunca pela `main`: uma
mudança aqui só chega a um projeto quando ele troca o número. Cada versão é uma tag `vX.Y.Z`
([SemVer](https://semver.org/lang/pt-BR/)): o último número para correções, o do meio para o que
é novo e compatível, o primeiro para o que exige mudar o `deploy.conf` ou o workflow dos projetos.
No terminal, `deploy.sh` roda a versão da pasta clonada.
