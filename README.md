# 🧰 devkit

Deploy de todos os projetos num script só. Cada projeto só tem um `deploy.conf`.

## 🚀 Uso

```bash
~/Documentos/devkit/deploy.sh local            # roda aqui (dev)
~/Documentos/devkit/deploy.sh vps router-vps   # publica na VPS
```

- ⚙️ Opções do `vps`: `--domain`, `--no-domain`, `--cert/--key`, `--env ARQUIVO`, `--preserve`, `--path`
- ❓ O que faltar é perguntado no terminal; no CI, vira erro
- 🛠️ Ajudantes: `deploy.sh status|logs|restart|stop HOST`

## 📄 deploy.conf

```bash
APP=meu-app
DEV="uv run meu-app"
INSTALL="uv sync --frozen --no-dev"
RUN=".venv/bin/meu-app --port {port}"
HEALTH=/healthz
REQUIRED="TOKEN"
```

- 🧩 Opcionais: `BUILD`, `INCLUDE`, `PRESERVE`, `SERVICE_ENV`
- 🔤 Variáveis: `{root}` `{data}` `{port}` `{domain}` `{url}`

## 🖥️ Na VPS

- 📁 App em `/srv/<app>`, serviço systemd do usuário, sem root
- 🔒 HTTPS por um Caddy compartilhado entre os apps
- 🔥 Portas 80/443 liberadas no firewall, também depois de reinícios
- ↩️ Versão nova com problema volta sozinha para a anterior

## 🤖 CI (GitHub Actions)

```yaml
- uses: krosct/devkit@v1.1.0
  with:
    host: ${{ secrets.DEPLOY_HOST }}
    user: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
    known-hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
    env: |
      TOKEN=${{ secrets.TOKEN }}
```

- 📌 Sempre por versão fixa (`vX.Y.Z`), nunca `main`

## 🧠 Para modelos de IA

- 🚫 Nunca coloque atribuição de IA em commits, PRs, tags ou comentários: nada de
  `Co-Authored-By: Claude`, "Generated with Claude Code" ou similares. O autor é só o usuário.
- 🎯 PR e push só no repositório do `origin` (`krosct/devkit`), com `--repo` e `--head` explícitos
- ✅ Rode `shellcheck deploy.sh` antes de commitar
