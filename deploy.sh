#!/usr/bin/env bash
# devkit: o deploy de todos os projetos. Roda na pasta do projeto, que descreve só o que é dele
# num deploy.conf (veja o README).
#
#   deploy.sh local                  roda o projeto aqui, em primeiro plano (Ctrl+C para)
#   deploy.sh vps HOST [opções]      publica o projeto na VPS, completo: serviço, HTTPS e
#                                    conferência de fora. HOST: alias do ~/.ssh/config ou usuario@host
#     --domain DOMINIO               endereço público (padrão: o que a VPS já usa para o app)
#     --no-domain                    sem endereço público (o site do app sai do Caddy)
#     --cert ARQUIVO --key ARQUIVO   Certificado de Origem do Cloudflare (SSL "Full (strict)")
#     --env ARQUIVO                  substitui a configuração do app na VPS por este arquivo
#     --path PASTA                   pasta do app na VPS (padrão: /srv/<app>)
#   deploy.sh status|logs|restart|stop HOST
#
# O que faltar (configuração obrigatória, domínio, certificado, senha do sudo) é perguntado no
# terminal. Sem terminal (CI), o deploy para dizendo o que falta.
set -euo pipefail

DEVKIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)
UV_VERSION="0.12.23"
UV_SHA256_x86_64="9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6"
UV_SHA256_aarch64="6524bd338177ed50d035d39354e12545e993bbeba2ecbddf0480c5b3a81d313f"
KEEP_RELEASES=3
# A versão nova só é aceita se continuar de pé por esse tempo; senão volta a anterior.
HEALTH_SECONDS=15
# Camada compartilhada do Caddy: um Caddy para todos os apps da VPS, de nenhum deles.
SHARED_DIR=/srv/caddy
SHARED_CONF=/etc/caddy/Caddyfile
SHARED_MARK="# devkit: camada compartilhada do Caddy v1"
# Porta interna de cada app (só 127.0.0.1), escolhida no 1º deploy e mantida depois.
PORT_MIN=20000
PORT_MAX=29999
APP_RE='^[a-z][a-z0-9-]{1,30}$'
DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
RELEASE_RE='^[A-Za-z0-9._-]+$'
BROWSER_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$DEVKIT_DIR/deploy.sh" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

# Lê CHAVE=valor de um .env/.conf sem executá-lo (aspas externas são removidas).
kv_get() { # arquivo chave
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | tail -n1 |
        sed -E "s/[[:space:]]+\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}

kv_set() { # arquivo chave valor (substitui a linha, mantendo as permissões do arquivo)
    local tmp
    tmp=$(mktemp)
    { grep -v "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } > "$tmp"
    cat "$tmp" > "$1"
    rm -f "${tmp:?}"
}

file_hash() { sha256sum "$1" | cut -d' ' -f1; }
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

normalize_domain() { # "https://x.com/" -> "x.com"; vazio se inválido
    local d=${1#*://}
    d=${d%%/*}
    [[ $d =~ $DOMAIN_RE ]] && printf '%s' "$d"
}

# Certificado: par com a chave, dentro da validade e cobrindo o domínio. Imprime o problema.
cert_problem() { # certificado chave domínio
    local cpub kpub names n
    # Sem openssl aqui, a conferência fica só para a VPS (que tem).
    command -v openssl >/dev/null || return 0
    cpub=$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null || true)
    kpub=$(openssl pkey -pubout -in "$2" 2>/dev/null || true)
    if [ -z "$cpub" ] || [ "$cpub" != "$kpub" ]; then echo "o certificado e a chave não formam um par (ou não estão em PEM)"; return; fi
    openssl x509 -checkend 0 -noout -in "$1" >/dev/null 2>&1 || { echo "o certificado já venceu"; return; }
    [ -n "$3" ] || return 0
    names=$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://' || true)
    [ -n "$names" ] || names=$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p')
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$n" = "$3" ] && return 0
        # "*.exemplo.com" cobre exatamente um nível a mais.
        case $n in '*.'*) [ "${3#*.}" = "${n#*.}" ] && [ "${3%%.*}" != "$3" ] && return 0 ;; esac
    done <<<"$names"
    echo "o certificado não cobre $3"
}

# ==========================================================================
# Na sua máquina (ou no CI): a pasta atual é o projeto
# ==========================================================================

load_conf() {
    CONF="$PWD/deploy.conf"
    [ -f "$CONF" ] || die "esta pasta não tem deploy.conf: rode o devkit na pasta do projeto (veja o README do devkit)."
    APP=$(kv_get "$CONF" APP)
    [[ $APP =~ $APP_RE ]] || die "deploy.conf: APP deve ter letras minúsculas, números e hífens (ex.: meu-app)."
}

conf() { kv_get "$CONF" "$1"; }

interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${CI:-}" ]; }
ask() { local a; read -r -p "$1 " a </dev/tty; printf '%s' "$a"; }
ask_secret() { local a; read -r -s -p "$1 " a </dev/tty; echo >&2; printf '%s' "$a"; }
yes_no() { [[ $(ask "$1 [s/N]") =~ ^[sSyY] ]]; }

missing_required() { # arquivo -> chaves obrigatórias vazias
    local k
    for k in $(conf REQUIRED); do
        [ -n "$(kv_get "$1" "$k")" ] || printf '%s ' "$k"
    done
}

fill_required() { # arquivo: pergunta o que falta e grava nele
    local missing k v
    missing=$(missing_required "$1")
    [ -n "$missing" ] || return 0
    interactive || die "faltam em $1: $missing"
    log "Faltam configurações obrigatórias do $APP (gravadas em $1):"
    for k in $missing; do
        v=""
        while [ -z "$v" ]; do v=$(ask_secret "  $k:"); done
        kv_set "$1" "$k" "$v"
    done
}

# ---------- local: roda o projeto aqui ----------

run_local() {
    local dev env_file k
    load_conf
    dev=$(conf DEV)
    [ -n "$dev" ] || die "deploy.conf: falta DEV (o comando para rodar o projeto aqui)."
    env_file="$PWD/.env"
    if [ ! -f "$env_file" ]; then
        if [ -f "$PWD/.env.example" ]; then
            cp "$PWD/.env.example" "$env_file"
            log "Criei o .env a partir do .env.example"
        else
            : > "$env_file"
            log "Criei um .env vazio"
        fi
        chmod 600 "$env_file"
    fi
    fill_required "$env_file"
    while IFS= read -r k; do
        export "$k=$(kv_get "$env_file" "$k")"
    done < <(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$env_file" | sort -u)
    log "Rodando o $APP (Ctrl+C para parar): $dev"
    exec bash -c "$dev"
}

# ---------- vps: tudo até a VPS funcionar ----------

ssh_host() { ssh -o ConnectTimeout=20 -o ServerAliveInterval=30 "$HOST" "$@"; }

build_package() { # destino.tgz
    local inc
    git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "o projeto precisa estar num repositório git."
    if [ -n "$(conf BUILD)" ]; then
        log "Build: $(conf BUILD)"
        bash -c "$(conf BUILD)" || die "o build falhou."
    fi
    # Versionado + novo não ignorado + INCLUDE (ex.: saída do build); nunca o .env.
    {
        git ls-files
        git ls-files --others --exclude-standard
        for inc in $(conf INCLUDE); do find "$inc" -type f 2>/dev/null || die "INCLUDE: $inc não existe (o build gerou?)."; done
    } | sort -u | grep -vE '(^|/)\.env$' | while IFS= read -r f; do if [ -e "$f" ]; then printf '%s\n' "$f"; fi; done |
        tar -czf "$1" -T -
}

run_vps() {
    local domain="" domain_opt="" cert="" key="" env_opt="" path="" release stage bundle problem
    local cert_mode="" need_root=0 sudo_mode="" want_caddy=0 env_mode="" missing k v
    HOST=${1:-}
    [ -n "$HOST" ] && [ "${HOST#-}" = "$HOST" ] || die "informe o HOST da VPS: deploy.sh vps HOST [opções]"
    [[ $HOST =~ ^[A-Za-z0-9@._:-]+$ ]] || die "HOST inválido: $HOST"
    shift
    while [ $# -gt 0 ]; do
        case $1 in
            --domain) domain_opt=${2:-}; [ -n "$domain_opt" ] || die "--domain precisa de um valor"; shift 2 ;;
            --no-domain) domain_opt=none; shift ;;
            --cert) cert=${2:-}; shift 2 ;;
            --key) key=${2:-}; shift 2 ;;
            --env) env_opt=${2:-}; shift 2 ;;
            --path) path=${2:-}; shift 2 ;;
            *) die "opção desconhecida: $1 (veja: deploy.sh help)" ;;
        esac
    done
    load_conf
    [ -n "$(conf INSTALL)" ] && [ -n "$(conf RUN)" ] || die "deploy.conf: faltam INSTALL e/ou RUN."
    [ -z "$path" ] || [[ $path =~ ^[A-Za-z0-9._/~-]+$ ]] || die "--path inválido: $path"

    log "Conferindo a VPS ($HOST)"
    ssh_host "bash -s -- _preflight $APP '${path:-}' $(conf REQUIRED)" < "$DEVKIT_DIR/deploy.sh" > "$WORK/preflight" ||
        die "não consegui conferir a VPS $HOST (o SSH funciona?)."
    pf() { kv_get "$WORK/preflight" "$1"; }
    [ -z "$(pf ROOT_PROBLEM)" ] || die "$(pf ROOT_PROBLEM)"

    # Domínio: o da opção, o que a VPS já usa ou, num app com site, perguntado.
    if [ "$domain_opt" = none ]; then domain=""
    elif [ -n "$domain_opt" ]; then
        domain=$(normalize_domain "$domain_opt") || die "domínio inválido: $domain_opt"
    elif [ "$(pf DOMAIN_SET)" = yes ]; then domain=$(pf DOMAIN)
    elif [ -n "$(conf HEALTH)" ] && interactive; then
        while :; do
            v=$(ask "Domínio público do $APP (ex.: $APP.exemplo.com; vazio = sem HTTPS):")
            [ -n "$v" ] || break
            domain=$(normalize_domain "$v") && break
            warn "domínio inválido: $v"
        done
    fi
    if [ -n "$domain" ]; then
        [ -n "$(conf HEALTH)" ] || die "deploy.conf: falta HEALTH (o caminho que responde 200): sem ele o app não tem site."
        case $(pf LAYER) in
            conflict) die "$(pf LAYER_PROBLEM)" ;;
            setup) want_caddy=1 ;;
        esac
    fi

    # Certificado de Origem: o das opções ou, se a VPS não tem e ninguém decidiu, perguntado.
    if [ -n "$cert$key" ]; then
        [ -f "$cert" ] && [ -f "$key" ] || die "--cert e --key precisam apontar para arquivos existentes."
        [ -n "$domain" ] || die "--cert sem domínio: o certificado não seria usado."
        problem=$(cert_problem "$cert" "$key" "$domain")
        [ -z "$problem" ] || die "$problem."
    elif [ -n "$domain" ] && [ "$(pf CERT)" = no ] && [ "$(pf CERT_MODE)" != letsencrypt ] && interactive; then
        if yes_no "O domínio $domain está no Cloudflare com SSL \"Full (strict)\"?"; then
            while :; do
                cert=$(ask "  Certificado de Origem (.pem):"); key=$(ask "  Chave privada (.key):")
                cert=${cert/#\~/$HOME}; key=${key/#\~/$HOME}
                if [ ! -f "$cert" ] || [ ! -f "$key" ]; then warn "arquivo não encontrado"; continue; fi
                problem=$(cert_problem "$cert" "$key" "$domain")
                [ -z "$problem" ] && break
                warn "$problem"
            done
        else
            cert_mode=letsencrypt
        fi
    fi

    # Configuração do app: a do --env substitui a da VPS; sem ele, a da VPS é mantida e só o que
    # falta é perguntado.
    : > "$WORK/env-add"
    if [ -n "$env_opt" ]; then
        [ -f "$env_opt" ] || die "--env: $env_opt não existe."
        fill_required "$env_opt"
        env_mode=replace
    elif [ "$(pf ENV_EXISTS)" = yes ]; then
        missing=$(pf ENV_MISSING)
        if [ -n "$missing" ]; then
            interactive || die "faltam na configuração do $APP na VPS: $missing"
            log "Faltam configurações obrigatórias do $APP na VPS:"
            for k in $missing; do
                v=""
                while [ -z "$v" ]; do v=$(ask_secret "  $k:"); done
                printf '%s=%s\n' "$k" "$v" >> "$WORK/env-add"
            done
        fi
    else
        interactive || die "a VPS ainda não tem a configuração do $APP: passe --env ARQUIVO."
        env_opt="$WORK/env-new"
        if [ -f "$PWD/.env" ] && yes_no "A VPS ainda não tem a configuração do $APP. Usar o $PWD/.env?"; then
            cp "$PWD/.env" "$env_opt"
        else
            : > "$env_opt"
        fi
        fill_required "$env_opt"
        env_mode=replace
    fi

    # Root só quando falta algo do sistema: a pasta, o linger ou a camada do Caddy.
    if [ "$(pf ROOT_OK)" != yes ] || [ "$(pf LINGER)" != yes ] || [ "$want_caddy" = 1 ]; then
        need_root=1
        case $(pf SUDO) in
            nopasswd) sudo_mode="sudo -n" ;;
            password)
                interactive ||
                    die "a VPS precisa de uma preparação com root (pasta, linger ou Caddy) e o usuário não tem sudo sem senha: rode este deploy num terminal."
                sudo_mode="sudo" ;;
            *) die "a VPS precisa de uma preparação com root (pasta, linger ou Caddy) e o usuário $(pf USER) não tem sudo." ;;
        esac
    fi

    release=${DEVKIT_RELEASE:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo local)-$(date +%Y%m%d%H%M%S)}
    [[ $release =~ $RELEASE_RE ]] || die "identificador de versão inválido: $release"
    stage=".cache/devkit/$APP/$release"

    # Pacote: o projeto, este script e as entradas (sempre por arquivo, nunca como argumento).
    bundle="$WORK/bundle"
    mkdir -p "$bundle/inputs"
    build_package "$bundle/release.tgz"
    cp "$DEVKIT_DIR/deploy.sh" "$bundle/deploy.sh"
    printf '%s\n' "$domain" > "$bundle/inputs/domain"
    [ -z "$cert_mode" ] || printf '%s\n' "$cert_mode" > "$bundle/inputs/cert-mode"
    if [ -n "$cert" ]; then cp "$cert" "$bundle/inputs/cert.pem"; cp "$key" "$bundle/inputs/cert.key"; fi
    if [ "$env_mode" = replace ]; then cp "$env_opt" "$bundle/inputs/env"; fi
    [ ! -s "$WORK/env-add" ] || cp "$WORK/env-add" "$bundle/inputs/env-add"
    chmod -R go-rwx "$bundle"
    log "Enviando a versão $release"
    tar -C "$bundle" -cf - . | ssh_host "umask 077 && rm -rf $stage && mkdir -p $stage && tar -xf - -C $stage" ||
        die "não consegui enviar a versão para a VPS."

    if [ "$need_root" = 1 ]; then
        log "Preparando a VPS com root (só desta vez)"
        if [ "$sudo_mode" = sudo ]; then
            ssh -t -o ConnectTimeout=20 "$HOST" "sudo bash $(pf HOME)/$stage/deploy.sh _root-setup $APP $(pf ROOT) $(pf USER) $want_caddy"
        else
            ssh_host "sudo -n bash $(pf HOME)/$stage/deploy.sh _root-setup $APP $(pf ROOT) $(pf USER) $want_caddy" </dev/null
        fi || die "a preparação com root falhou (veja acima)."
    fi

    ssh_host "bash $(pf HOME)/$stage/deploy.sh _release-up $APP $(pf ROOT) $release" </dev/null
}

# ---------- ci: chamado pela action do GitHub (action.yml) ----------
# Monta o acesso SSH, a configuração do app (das chaves ENV do deploy.conf, lidas dos secrets e
# variables) e o certificado, e chama o mesmo "vps". Sem terminal: nada é perguntado.

run_ci() {
    local host user port args=()
    load_conf
    host=$(tr -d '[:space:]' <<<"${DEVKIT_HOST:-}")
    user=$(tr -d '[:space:]' <<<"${DEVKIT_USER:-}")
    port=$(tr -d '[:space:]' <<<"${DEVKIT_PORT:-}"); port=${port:-22}
    [[ $host =~ ^[A-Za-z0-9.:-]+$ ]] || die "DEPLOY_HOST inválido ou vazio."
    [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "DEPLOY_USER inválido ou vazio."
    [[ $port =~ ^[0-9]+$ ]] || die "DEPLOY_PORT inválido."
    [ -n "${DEVKIT_SSH_KEY:-}" ] && [ -n "${DEVKIT_KNOWN_HOSTS:-}" ] || die "faltam os secrets DEPLOY_SSH_KEY e/ou DEPLOY_KNOWN_HOSTS."
    install -d -m 700 ~/.ssh
    (umask 077
     printf '%s\n' "$DEVKIT_SSH_KEY" > ~/.ssh/devkit_vps
     printf '%s\n' "$DEVKIT_KNOWN_HOSTS" > ~/.ssh/known_hosts
     printf '%s\n' "Host devkit-vps" "  HostName $host" "  User $user" "  Port $port" \
         "  IdentityFile ~/.ssh/devkit_vps" "  IdentitiesOnly yes" "  StrictHostKeyChecking yes" \
         "  BatchMode yes" > ~/.ssh/config)

    # ENV="CHAVE CHAVE=SECRET ...": cada chave vem do secret (ou variable) de mesmo nome, ou do
    # indicado depois do "=" (o GitHub não aceita secrets começando com GITHUB_).
    (umask 077 && DEVKIT_ENV_KEYS=$(conf ENV) python3 -I -c '
import json, os, sys
secrets = json.loads(os.environ.get("DEVKIT_SECRETS") or "{}")
variables = json.loads(os.environ.get("DEVKIT_VARS") or "{}")
for item in os.environ["DEVKIT_ENV_KEYS"].split():
    key, _, source = item.partition("=")
    value = (secrets.get(source or key) or variables.get(source or key) or "").strip()
    if "\n" in value:
        sys.exit(f"erro: {source or key} tem mais de uma linha")
    if value:
        print(f"{key}={value}")
' > "$WORK/ci.env") || die "não consegui montar a configuração a partir dos secrets."
    log "Configuração com: $(cut -d= -f1 "$WORK/ci.env" | tr '\n' ' ')"
    args=(--env "$WORK/ci.env")
    [ -z "${DEVKIT_PATH:-}" ] || args+=(--path "$(tr -d '[:space:]' <<<"$DEVKIT_PATH")")
    [ -z "${DEVKIT_DOMAIN:-}" ] || args+=(--domain "$(tr -d '[:space:]' <<<"$DEVKIT_DOMAIN")")
    if [ -n "${DEVKIT_ORIGIN_CERT:-}${DEVKIT_ORIGIN_KEY:-}" ]; then
        (umask 077 && printf '%s\n' "${DEVKIT_ORIGIN_CERT:-}" > "$WORK/origin.pem" && printf '%s\n' "${DEVKIT_ORIGIN_KEY:-}" > "$WORK/origin.key")
        args+=(--cert "$WORK/origin.pem" --key "$WORK/origin.key")
    fi
    DEVKIT_RELEASE=${GITHUB_SHA:0:12}-$(date +%Y%m%d%H%M%S) run_vps devkit-vps "${args[@]}"
}

# ---------- ajudantes ----------

run_helper() { # status|logs|restart|stop HOST
    local cmd=$1
    HOST=${2:-}
    [ -n "$HOST" ] || die "informe o HOST: deploy.sh $cmd HOST"
    load_conf
    # shellcheck disable=SC2016  # expandido na VPS, de propósito
    local prefix='export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)};'
    # shellcheck disable=SC2029  # $APP e o prefixo vão prontos daqui
    case $cmd in
        status) ssh -t "$HOST" "$prefix systemctl --user status $APP --no-pager" ;;
        logs) ssh -t "$HOST" "$prefix journalctl --user -u $APP -n 50 -f" ;;
        restart) ssh "$HOST" "$prefix systemctl --user restart $APP" && log "$APP reiniciado." ;;
        stop) ssh "$HOST" "$prefix systemctl --user stop $APP" && log "$APP parado (o próximo deploy o liga de novo)." ;;
    esac
}

# ==========================================================================
# Na VPS. Estes comandos chegam do "vps" (nunca chame à mão).
# ==========================================================================

can_sudo() { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

systemctl_user() {
    # Sessões SSH (ex.: CI) podem não ter as variáveis do barramento do usuário.
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    systemctl --user "$@"
}

download() { # url destino
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
    else return 1; fi
}

expand_path() { # ~, relativo (ao $HOME) e barras no fim
    local p=$1
    # shellcheck disable=SC2088  # "~" aqui é o padrão literal
    case $p in
        "~") p=$HOME ;;
        "~/"*) p="$HOME/${p#"~/"}" ;;
        /*) ;;
        *) p="$HOME/$p" ;;
    esac
    printf '%s' "${p%/}"
}

linger_on() { [ "$(loginctl show-user "$1" -p Linger --value 2>/dev/null || echo no)" = yes ]; }

# ---------- camada compartilhada do Caddy ----------
# /etc/caddy/Caddyfile só importa /srv/caddy/sites/*.caddy; cada app escreve e remove apenas o
# próprio sites/<app>.caddy. Certificado de Origem: /srv/caddy/certs/<app>.pem e .key. Só duas
# situações são aceitas: a camada existe, ou não há Caddy nenhum (e ela é instalada). O resto é
# erro com o motivo.

shared_caddyfile() { # pasta-dos-sites
    printf '%s\n' "$SHARED_MARK" \
        "# Não pertence a nenhum app e não deve ser editado: cada app publica o próprio site em" \
        "# $SHARED_DIR/sites/<app>.caddy pelo devkit." \
        "import $1/*.caddy"
}

# Caddys rodando, fora de containers: "pid usuário config" por linha.
caddy_processes() {
    local d conf
    for d in /proc/[0-9]*; do
        [ "$(cat "$d/comm" 2>/dev/null)" = caddy ] || continue
        grep -qE '[0-9a-f]{64}' "$d/cgroup" 2>/dev/null && continue
        conf=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null |
            awk 'f{print;exit} $0=="--config"{f=1} /^--config=/{sub(/^--config=/,"");print;exit}' || true)
        printf '%s %s %s\n' "${d#/proc/}" "$(stat -c %U "$d" 2>/dev/null || echo '?')" "${conf:-?}"
    done
}

web_ports_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eo ':(80|443)$' | tr -d : | sort -u | tr '\n' ' ' || true
    else
        for p in 80 443; do if port_in_use "$p"; then printf '%s ' "$p"; fi; done
    fi
}

# "ok" (pronta), "setup" (falta algo que root resolve) ou "conflict: motivo".
layer_state() {
    local procs line busy
    procs=$(caddy_processes)
    if grep -qxF "$SHARED_MARK" "$SHARED_CONF" 2>/dev/null; then
        while IFS= read -r line; do
            if [ -n "$line" ] && [ "${line##* }" != "$SHARED_CONF" ]; then
                echo "conflict: além da camada compartilhada, há outro Caddy rodando (pid usuário config: $line). Pare-o e rode de novo."
                return
            fi
        done <<<"$procs"
        if command -v caddy >/dev/null && [ -w "$SHARED_DIR/sites" ] && [ -w "$SHARED_DIR/certs" ] &&
            systemctl is-active --quiet caddy 2>/dev/null; then echo ok; else echo setup; fi
        return
    fi
    if [ -e "$SHARED_CONF" ]; then
        echo "conflict: $SHARED_CONF existe e não é o da camada compartilhada (um Caddy instalado por outro meio). Remova esse Caddy e rode de novo."
    elif [ -n "$procs" ]; then
        echo "conflict: há um Caddy rodando que não é a camada compartilhada (pid usuário config: $(head -n1 <<<"$procs")). Pare-o e rode de novo."
    elif busy=$(web_ports_busy) && [ -n "$busy" ]; then
        echo "conflict: as portas ${busy}já são usadas por outro programa; o Caddy compartilhado precisa delas."
    else
        echo setup
    fi
}

install_caddy_package() { # como root
    local tmp
    command -v apt-get >/dev/null || die "a instalação automática do Caddy só funciona com apt (Debian/Ubuntu)."
    log "Instalando o Caddy (pacote oficial, serviço do sistema)"
    tmp=$(mktemp -d)
    { download https://dl.cloudsmith.io/public/caddy/stable/gpg.key "$tmp/caddy.asc" &&
        download https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt "$tmp/caddy.list"; } ||
        { rm -rf "${tmp:?}"; die "não consegui baixar o repositório do Caddy (a VPS tem acesso à internet?)."; }
    export DEBIAN_FRONTEND=noninteractive
    command -v gpg >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq gnupg >/dev/null; }
    gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$tmp/caddy.asc"
    chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    install -m 644 "$tmp/caddy.list" /etc/apt/sources.list.d/caddy-stable.list
    rm -rf "${tmp:?}"
    apt-get update -qq >/dev/null
    # O Caddyfile da camada, escrito antes, é mantido.
    apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold caddy >/dev/null ||
        die "não consegui instalar o Caddy."
}

setup_shared_caddy() { # usuário (como root)
    local state d
    state=$(layer_state)
    case $state in conflict:*) die "${state#conflict: }" ;; esac
    if ! grep -qxF "$SHARED_MARK" "$SHARED_CONF" 2>/dev/null; then
        log "Criando a camada compartilhada do Caddy ($SHARED_CONF → $SHARED_DIR/sites/)"
        # Antes do pacote: uma instalação interrompida é retomada no próximo deploy.
        mkdir -p "$(dirname "$SHARED_CONF")"
        shared_caddyfile "$SHARED_DIR/sites" > "$SHARED_CONF"
        chmod 644 "$SHARED_CONF"
    fi
    command -v caddy >/dev/null || install_caddy_package
    if ! grep -qxF "$SHARED_MARK" "$SHARED_CONF"; then
        shared_caddyfile "$SHARED_DIR/sites" > "$SHARED_CONF"
    fi
    getent group caddy >/dev/null || die "o grupo caddy não existe: o pacote do Caddy não foi instalado direito."
    # Do usuário do deploy (escreve sem sudo) e do grupo caddy (só lê); o setgid mantém o grupo.
    for d in "$SHARED_DIR" "$SHARED_DIR/sites" "$SHARED_DIR/certs"; do
        [ -d "$d" ] || install -d -o "$1" -g caddy -m 2750 "$d"
    done
    if ! sudo -u "$1" test -w "$SHARED_DIR/sites" || ! sudo -u "$1" test -w "$SHARED_DIR/certs"; then
        die "$SHARED_DIR pertence a outro usuário ($(stat -c %U "$SHARED_DIR")): todos os apps devem usar o mesmo usuário do SSH."
    fi
    systemctl enable --now caddy >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true
    systemctl is-active --quiet caddy || die "o Caddy não iniciou: veja 'sudo journalctl -u caddy -n 30'."
}

# ---------- _preflight: o estado da VPS para o "vps" decidir (sem root, sem alterar nada) ----------

remote_preflight() { # app pasta obrigatórias...
    local app=$1 root=${2:-} me state k missing="" layer
    shift 2
    [[ $app =~ $APP_RE ]] || die "app inválido."
    root=$(expand_path "${root:-/srv/$app}")
    me=$(id -un)
    echo "USER=$me"
    echo "HOME=$HOME"
    echo "ROOT=$root"
    [[ $root =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "ROOT_PROBLEM=pasta do app inválida: $root"; return; }
    if [ -d "$root" ]; then
        if [ -n "$(ls -A "$root" 2>/dev/null)" ] && [ "$(cat "$root/.devkit/app" 2>/dev/null)" != "$app" ]; then
            echo "ROOT_PROBLEM=$root não está vazia e não é do $app pelo devkit; não vou mexer nela."
            return
        fi
        if [ -w "$root" ]; then echo ROOT_OK=yes; else echo ROOT_OK=no; fi
    elif [ -w "$(dirname "$root")" ]; then echo ROOT_OK=yes
    else echo ROOT_OK=no; fi
    state="$root/.devkit"
    if [ -f "$state/domain" ]; then echo DOMAIN_SET=yes; echo "DOMAIN=$(cat "$state/domain")"; else echo DOMAIN_SET=no; fi
    echo "CERT_MODE=$(cat "$state/cert-mode" 2>/dev/null || true)"
    if [ -f "$SHARED_DIR/certs/$app.pem" ] && [ -f "$SHARED_DIR/certs/$app.key" ]; then echo CERT=yes; else echo CERT=no; fi
    if [ -f "$root/.env" ]; then
        echo ENV_EXISTS=yes
        for k in "$@"; do [ -n "$(kv_get "$root/.env" "$k")" ] || missing+="$k "; done
        echo "ENV_MISSING=$missing"
    else
        echo ENV_EXISTS=no
    fi
    layer=$(layer_state)
    case $layer in
        conflict:*) echo LAYER=conflict; echo "LAYER_PROBLEM=${layer#conflict: }" ;;
        *) echo "LAYER=$layer" ;;
    esac
    if linger_on "$me"; then echo LINGER=yes; else echo LINGER=no; fi
    if can_sudo; then echo SUDO=nopasswd
    elif command -v sudo >/dev/null 2>&1 && id -nG "$me" | grep -qwE 'sudo|wheel|admin'; then echo SUDO=password
    else echo SUDO=none; fi
    [ -d /run/systemd/system ] || echo "ROOT_PROBLEM=a VPS não usa systemd; o devkit precisa dele."
}

# ---------- _root-setup: o que só root faz (pasta, linger, camada do Caddy) ----------

remote_root_setup() { # app pasta usuário quer-caddy
    local app=$1 root=$2 user=$3 want_caddy=$4
    [ "$(id -u)" = 0 ] || die "a preparação precisa de root."
    if ! [[ $app =~ $APP_RE ]] || ! [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$user" >/dev/null 2>&1; then
        die "app ou usuário inválido."
    fi
    [[ $root =~ ^/([A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+$ ]] || die "pasta do app inválida: $root (use algo como /srv/$app)."
    if [ ! -d "$root" ]; then
        log "Criando $root (dono: $user)"
        install -d -o "$user" -g "$(id -gn "$user")" -m 755 "$root"
    fi
    sudo -u "$user" test -w "$root" || die "$root existe e o usuário $user não consegue escrever nela."
    if ! linger_on "$user"; then
        loginctl enable-linger "$user"
        log "Linger ativado para $user (os apps continuam rodando sem sessão aberta)"
    fi
    [ "$want_caddy" != 1 ] || setup_shared_caddy "$user"
}

# ---------- _release-up: instala e ativa a versão (como o usuário do SSH) ----------

site_path() { printf '%s' "$SHARED_DIR/sites/$APP.caddy"; }
cert_base() { printf '%s' "$SHARED_DIR/certs/$APP"; }

site_block() { # domínio porta
    local tls=""
    if [ -f "$(cert_base).pem" ] && [ -f "$(cert_base).key" ]; then
        tls=$(printf '\n\ttls %s.pem %s.key' "$(cert_base)" "$(cert_base)")
    fi
    printf '# Gerado pelo devkit para o %s. Não edite: é sobrescrito a cada deploy.\n' "$APP"
    printf '%s {\n\treverse_proxy 127.0.0.1:%s%s\n}\n' "$1" "$2" "$tls"
}

# Testa a configuração inteira: os sites dos outros apps mais o deste (novo, ou removido com "").
caddy_validate_with() { # arquivo-do-site
    local tmp f status=0
    tmp=$(mktemp -d)
    mkdir "$tmp/sites"
    for f in "$SHARED_DIR"/sites/*.caddy; do
        if [ -e "$f" ] && [ "$f" != "$(site_path)" ]; then
            cp "$f" "$tmp/sites/" || die "não consigo ler $f (de outro usuário?)."
        fi
    done
    [ -z "$1" ] || cp "$1" "$tmp/sites/$APP.caddy"
    shared_caddyfile "$tmp/sites" > "$tmp/Caddyfile"
    caddy validate --config "$tmp/Caddyfile" --adapter caddyfile > "$tmp/out" 2>&1 || status=$?
    if [ "$status" != 0 ]; then grep -i error "$tmp/out" | tail -n 5 >&2 || true; fi
    rm -rf "${tmp:?}"
    return "$status"
}

caddy_reload() { caddy reload --config "$SHARED_CONF" --adapter caddyfile --force >/dev/null 2>&1; }

shared_lock() {
    exec 8>"$SHARED_DIR/.lock"
    flock -w 300 8 || die "o Caddy compartilhado está ocupado por outro deploy há 5 minutos."
}

publish_site() { # arquivo-preparado
    local site backup
    site=$(site_path)
    shared_lock
    # Outro app pode ter mudado o próprio site desde a validação de antes: valida de novo.
    caddy_validate_with "$1" ||
        die "o app está rodando, mas a configuração do Caddy deixou de validar com o site dele (veja acima); o site anterior foi mantido."
    backup="$ROOT/.devkit/site.caddy.previous"
    rm -f "${backup:?}"
    [ ! -f "$site" ] || cp -p "$site" "$backup"
    install -m 640 "$1" "$site"
    if ! caddy_reload; then
        if [ -f "$backup" ]; then install -m 640 "$backup" "$site"; else rm -f "${site:?}"; fi
        caddy_reload || true
        die "o app está rodando, mas o Caddy recusou o site novo; o anterior foi restaurado. Veja 'sudo journalctl -u caddy -n 30'."
    fi
    exec 8>&-
}

unpublish_site() {
    local site
    site=$(site_path)
    [ -f "$site" ] && [ -w "$SHARED_DIR/sites" ] || return 0
    shared_lock
    caddy_validate_with "" || die "a configuração do Caddy não valida sem o site do $APP; ele foi mantido."
    rm -f "${site:?}"
    caddy_reload || warn "removi $site, mas não consegui recarregar o Caddy."
    exec 8>&-
    log "Site do $APP removido do Caddy"
}

# Acessa o endereço público como um usuário faria (DNS, Cloudflare, certificado, Caddy, app).
public_problem() { # url-de-saúde -> imprime o problema (vazio = respondeu 200)
    local code=""
    command -v curl >/dev/null 2>&1 || { warn "sem curl na VPS: não conferi $1 de fora."; return 0; }
    # Na 1ª vez, o Let's Encrypt pode levar alguns segundos para emitir o certificado. O agente é
    # o de um navegador: a proteção contra bots do Cloudflare bloqueia o do curl (403).
    for _ in $(seq 12); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -A "$BROWSER_UA" "$1" || true)
        [ "$code" = 200 ] && return 0
        sleep 5
    done
    case $code in
        000 | "") echo "sem resposta. O domínio existe no DNS e aponta para esta VPS? As portas 80/443 estão abertas?" ;;
        525 | 526) echo "o Cloudflare recusou o certificado da VPS (erro $code). No SSL \"Full (strict)\", rode o deploy com --cert e --key." ;;
        403) echo "bloqueado com 403 (no Cloudflare, é a proteção contra bots ou uma regra do WAF barrando a conferência)." ;;
        52[0-4]) echo "o Cloudflare não conseguiu falar com a VPS (erro $code). As portas 80/443 estão abertas para ele?" ;;
        *) echo "$1 respondeu $code em vez de 200." ;;
    esac
}

local_healthy() { # porta caminho: o app responde 200 em 127.0.0.1?
    command -v curl >/dev/null 2>&1 || return 0
    for _ in $(seq 20); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1$2" || true)" = 200 ] && return 0
        sleep 1
    done
    return 1
}

allocate_port() { # registro do usuário: uma porta por app, nunca repetida
    local reg="$HOME/.config/devkit/ports" p
    mkdir -p "$(dirname "$reg")"
    exec 7>"$reg.lock"
    flock -w 60 7 || die "não consegui travar o registro de portas."
    p=$(sed -n "s/^$APP=//p" "$reg" 2>/dev/null | head -n1)
    if [ -z "$p" ]; then
        for p in $(seq "$PORT_MIN" "$PORT_MAX"); do
            grep -q "=$p\$" "$reg" 2>/dev/null && continue
            port_in_use "$p" && continue
            printf '%s=%s\n' "$APP" "$p" >> "$reg"
            break
        done
    fi
    exec 7>&-
    printf '%s' "$p"
}

ensure_uv() {
    local arch expected dir="$ROOT/tools/uv-$UV_VERSION" tmp
    [ -x "$dir/uv" ] && return 0
    case $(uname -m) in
        x86_64 | amd64) arch=x86_64; expected=$UV_SHA256_x86_64 ;;
        aarch64 | arm64) arch=aarch64; expected=$UV_SHA256_aarch64 ;;
        *) die "arquitetura de CPU não suportada: $(uname -m)" ;;
    esac
    log "Instalando o uv $UV_VERSION em tools/ (o Python do app, independente do sistema)"
    tmp=$(mktemp -d)
    download "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$arch-unknown-linux-gnu.tar.gz" "$tmp/uv.tgz" ||
        die "não consegui baixar o uv (a VPS tem acesso à internet?)."
    [ "$(file_hash "$tmp/uv.tgz")" = "$expected" ] || die "o download do uv não passou no checksum."
    tar -xzf "$tmp/uv.tgz" -C "$tmp"
    mkdir -p "$dir"
    mv "$tmp/uv-$arch-unknown-linux-gnu/uv" "$dir/uv"
    rm -rf "${tmp:?}"
}

placeholders() { # texto -> {root} {data} {port} {domain} {url} substituídos
    local s=$1
    s=${s//\{root\}/$ROOT}
    s=${s//\{data\}/$ROOT/data}
    s=${s//\{port\}/$PORT}
    s=${s//\{domain\}/$DOMAIN}
    s=${s//\{url\}/${DOMAIN:+https://$DOMAIN}}
    printf '%s' "$s"
}

write_run_script() { # pasta-da-versão
    local item items=()
    read -r -a items <<<"$(kv_get "$1/deploy.conf" SERVICE_ENV)"
    {
        printf '#!/usr/bin/env bash\n# Gerado pelo devkit: não edite.\n'
        printf 'export PATH=%q\n' "$1/.venv/bin:$ROOT/tools/uv-$UV_VERSION:/usr/local/bin:/usr/bin:/bin"
        printf 'export DEVKIT_APP=%q DEVKIT_ROOT=%q DEVKIT_DATA=%q DEVKIT_PORT=%q DEVKIT_URL=%q\n' \
            "$APP" "$ROOT" "$ROOT/data" "$PORT" "${DOMAIN:+https://$DOMAIN}"
        for item in "${items[@]}"; do
            [[ $item =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "deploy.conf: SERVICE_ENV inválido: $item"
            printf 'export %s=%q\n' "${item%%=*}" "$(placeholders "${item#*=}")"
        done
        printf 'cd %q\n' "$1"
        printf 'exec %s\n' "$(placeholders "$(kv_get "$1/deploy.conf" RUN)")"
    } > "$1/.devkit-run"
    chmod 755 "$1/.devkit-run"
}

install_unit() {
    local dir="$HOME/.config/systemd/user" unit
    mkdir -p "$dir"
    unit="# Gerado pelo devkit para o $APP. Não edite: é sobrescrito a cada deploy.
[Unit]
Description=$APP (devkit)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT/current
EnvironmentFile=$ROOT/.env
ExecStart=$ROOT/current/.devkit-run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=default.target"
    if [ "$(cat "$dir/$APP.service" 2>/dev/null || true)" != "$unit" ]; then
        printf '%s\n' "$unit" > "$dir/$APP.service"
        systemctl_user daemon-reload
    fi
    systemctl_user enable --quiet "$APP"
}

app_healthy() {
    local restarts
    restarts=$(systemctl_user show -p NRestarts --value "$APP")
    for _ in $(seq "$HEALTH_SECONDS"); do
        sleep 1
        [ "$(systemctl_user show -p ActiveState --value "$APP")" = active ] || return 1
        [ "$(systemctl_user show -p NRestarts --value "$APP")" = "$restarts" ] || return 1
    done
    # Com site, o app também precisa responder no caminho de saúde.
    [ -z "$DOMAIN" ] || local_healthy "$PORT" "$HEALTH"
}

switch_current() { # pasta da versão (troca atômica)
    ln -sfn "$1" "$ROOT/current.new"
    mv -T "$ROOT/current.new" "$ROOT/current"
}

prune_releases() {
    local old cur
    cur=$(readlink -f "$ROOT/current" 2>/dev/null || true)
    find "$ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn |
        tail -n +"$((KEEP_RELEASES + 1))" | cut -d' ' -f2- | while read -r old; do
            [ "$(readlink -f "$old")" = "$cur" ] || rm -rf "${old:?}"
        done
}

remote_release_up() { # app pasta versão
    local release=$3 inputs="$DEVKIT_DIR/inputs" code staged="" previous problem k missing
    APP=$1 ROOT=$2
    [[ $APP =~ $APP_RE ]] && [[ $release =~ $RELEASE_RE ]] || die "app ou versão inválidos."
    mkdir -p "$ROOT" 2>/dev/null || true
    [ -d "$ROOT" ] && [ -w "$ROOT" ] || die "a pasta $ROOT não existe ou não é gravável."
    # A pasta de envio (~/.cache/devkit/<app>/<versão>) some no fim, dê certo ou não.
    case $DEVKIT_DIR in */.cache/devkit/"$APP"/"$release") trap 'rm -rf "${WORK:?}" "${DEVKIT_DIR:?}"' EXIT ;; esac
    mkdir -p "$ROOT/.devkit" "$ROOT/releases" "$ROOT/data"
    chmod 700 "$ROOT/.devkit" "$ROOT/data"
    printf '%s\n' "$APP" > "$ROOT/.devkit/app"
    exec 9>"$ROOT/.devkit/lock"
    flock -w 900 9 || die "outro deploy do $APP ainda está rodando."

    code="$ROOT/releases/$release"
    if [ ! -f "$code/deploy.conf" ]; then
        log "Descompactando a versão $release"
        rm -rf "${code:?}.tmp" && mkdir -p "$code.tmp"
        tar -xzf "$DEVKIT_DIR/release.tgz" -C "$code.tmp"
        rm -rf "${code:?}" && mv "$code.tmp" "$code"
    fi
    [ "$(kv_get "$code/deploy.conf" APP)" = "$APP" ] || die "o deploy.conf da versão é de outro app."
    HEALTH=$(kv_get "$code/deploy.conf" HEALTH)

    # Configuração: preparada em .env.new e só trocada na ativação.
    if [ -f "$inputs/env" ]; then cp "$inputs/env" "$ROOT/.devkit/env.new"
    elif [ -f "$ROOT/.env" ]; then cp "$ROOT/.env" "$ROOT/.devkit/env.new"
    else : > "$ROOT/.devkit/env.new"; fi
    chmod 600 "$ROOT/.devkit/env.new"
    if [ -f "$inputs/env-add" ]; then
        while IFS= read -r k; do
            [ -n "$k" ] && kv_set "$ROOT/.devkit/env.new" "${k%%=*}" "${k#*=}"
        done < "$inputs/env-add"
    fi
    missing=""
    for k in $(kv_get "$code/deploy.conf" REQUIRED); do
        [ -n "$(kv_get "$ROOT/.devkit/env.new" "$k")" ] || missing+="$k "
    done
    [ -z "$missing" ] || die "faltam na configuração do $APP: $missing. Nada foi alterado."

    DOMAIN=$(cat "$inputs/domain" 2>/dev/null || true)
    [ -z "$DOMAIN" ] || [[ $DOMAIN =~ $DOMAIN_RE ]] || die "domínio inválido: $DOMAIN"
    PORT=$(allocate_port)
    [ -n "$PORT" ] || die "não há porta livre entre $PORT_MIN e $PORT_MAX."
    if port_in_use "$PORT" && ! systemctl_user is-active --quiet "$APP" 2>/dev/null; then
        die "a porta $PORT do $APP está sendo usada por outro programa. Nada foi alterado."
    fi

    ensure_uv
    log "Instalando as dependências: $(kv_get "$code/deploy.conf" INSTALL)"
    (cd "$code" && PATH="$ROOT/tools/uv-$UV_VERSION:$PATH" UV_PYTHON_INSTALL_DIR="$ROOT/tools/python" \
        UV_CACHE_DIR="$ROOT/.cache/uv" UV_PYTHON_PREFERENCE=only-managed UV_PROJECT_ENVIRONMENT="$code/.venv" \
        UV_NO_PROGRESS=1 bash -c "$(kv_get "$code/deploy.conf" INSTALL)") ||
        die "a instalação das dependências falhou. Nada foi alterado."
    write_run_script "$code"

    if [ -n "$DOMAIN" ]; then
        [ "$(layer_state)" = ok ] || die "a camada compartilhada do Caddy não está pronta: rode o deploy pelo terminal, que a prepara com sudo."
        if [ -f "$inputs/cert.pem" ]; then
            problem=$(cert_problem "$inputs/cert.pem" "$inputs/cert.key" "$DOMAIN")
            [ -z "$problem" ] || die "$problem. Nada foi alterado."
            install -m 640 "$inputs/cert.pem" "$(cert_base).pem.new"
            install -m 640 "$inputs/cert.key" "$(cert_base).key.new"
            mv "$(cert_base).pem.new" "$(cert_base).pem"
            mv "$(cert_base).key.new" "$(cert_base).key"
            log "Certificado de Origem instalado em $(cert_base).pem e .key"
        fi
        staged="$ROOT/.devkit/site.caddy"
        site_block "$DOMAIN" "$PORT" > "$staged"
        caddy_validate_with "$staged" || die "a configuração do Caddy não valida com o site do $APP (veja acima). Nada foi alterado."
    fi

    log "Ativando a versão $release"
    install_unit
    previous=$(readlink "$ROOT/current" 2>/dev/null || true)
    mv "$ROOT/.devkit/env.new" "$ROOT/.env"
    printf '%s\n' "$DOMAIN" > "$ROOT/.devkit/domain"
    printf '%s\n' "$PORT" > "$ROOT/.devkit/port"
    [ ! -f "$inputs/cert-mode" ] || cp "$inputs/cert-mode" "$ROOT/.devkit/cert-mode"
    switch_current "$code"
    systemctl_user restart "$APP"
    if ! app_healthy; then
        journalctl --user -u "$APP" -n 40 --no-pager -o cat >&2 || true
        if [ -n "$previous" ] && [ -d "$previous" ] && [ "$previous" != "$code" ]; then
            warn "A versão nova não ficou de pé: voltando para $(basename "$previous")"
            switch_current "$previous"
            systemctl_user restart "$APP"
            if app_healthy; then die "deploy falhou; a versão anterior voltou a rodar."; fi
            die "deploy falhou e a versão anterior também não ficou de pé."
        fi
        die "o $APP não ficou de pé (veja o log acima)."
    fi

    if [ -n "$staged" ]; then publish_site "$staged"; else unpublish_site; fi
    prune_releases
    log "Rodando: $APP versão $release em $ROOT (porta interna $PORT)"
    if [ -n "$DOMAIN" ]; then
        problem=$(public_problem "https://$DOMAIN$HEALTH")
        [ -z "$problem" ] || die "o $APP está rodando, mas https://$DOMAIN não respondeu de fora: $problem"
        if [ -f "$(cert_base).pem" ]; then
            log "HTTPS: https://$DOMAIN publicado no Caddy compartilhado (Certificado de Origem)"
        else
            log "HTTPS: https://$DOMAIN publicado no Caddy compartilhado (Let's Encrypt)"
        fi
    else
        log "HTTPS: sem domínio"
    fi
}

main() {
    WORK=$(mktemp -d)
    trap 'rm -rf "${WORK:?}"' EXIT
    case ${1:-} in
        local) run_local ;;
        vps) shift; run_vps "$@" ;;
        ci) run_ci ;;
        status | logs | restart | stop) run_helper "$1" "${2:-}" ;;
        _preflight) shift; remote_preflight "$@" ;;
        _root-setup) remote_root_setup "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        _release-up) remote_release_up "${2:-}" "${3:-}" "${4:-}" ;;
        -h | --help | help | "") usage 0 ;;
        *) usage 1 ;;
    esac
}

main "$@"
exit
