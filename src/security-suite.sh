#!/usr/bin/env bash

# ==============================================================================
# Security Suite - Instalação e Configuração Automática  v2.0
# Suporte: Debian/Ubuntu (e derivados) | Arch Linux (e derivados: CachyOS,
#          Manjaro, EndeavourOS, Garuda…)
#
# USO:
#   chmod +x security_suite.sh
#   sudo ./security_suite.sh
#
# LOG:
#   Um arquivo de log com timestamp é criado automaticamente na pasta de
#   execução do script:  security_suite_<YYYY-MM-DD_HH-MM-SS>.log
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURAÇÃO DE LOG
# Cria o arquivo na pasta de onde o script é chamado (não necessariamente a
# pasta do script em si — útil quando chamado via sudo de outro diretório).
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="${SCRIPT_DIR}/security_suite_${TIMESTAMP}.log"

# Abre o descritor 3 para o arquivo de log e redireciona stdout+stderr
# para ambos o terminal (tee) e o log, mantendo cores no terminal mas
# armazenando texto limpo (sem escape ANSI) no arquivo.
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# Garante que o log seja fechado corretamente mesmo em caso de erro/sinal
cleanup() {
    local exit_code=$?
    echo ""
    if [[ $exit_code -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERRO] Script encerrado com código de saída: ${exit_code}" | \
            tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE") >/dev/null
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log salvo em: ${LOG_FILE}"
}
trap cleanup EXIT

# ==============================================================================
# CORES / HELPERS DE OUTPUT
# As funções log/warn/erro também carimbam o timestamp para facilitar a
# leitura posterior do arquivo de log.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

_ts()    { date '+%Y-%m-%d %H:%M:%S'; }
log()    { echo -e "${GREEN}[$(_ts)] [INFO]${NC}   $1"; }
warn()   { echo -e "${YELLOW}[$(_ts)] [AVISO]${NC}  $1"; }
erro()   { echo -e "${RED}[$(_ts)] [ERRO]${NC}   $1"; exit 1; }
titulo() { echo -e "\n${BLUE}[$(_ts)] ========== $1 ==========${NC}"; }
passo()  { echo -e "${CYAN}[$(_ts)] [PASSO]${NC}  $1"; }

# ==============================================================================
# CABEÇALHO DO LOG
# ==============================================================================

echo "============================================================"
echo " Security Suite v2.0 — Log de Execução"
echo " Início : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Usuário: ${SUDO_USER:-${USER}}"
echo " Host   : $(hostname)"
echo " Log    : ${LOG_FILE}"
echo "============================================================"

# ==============================================================================
# VERIFICAÇÃO DE ROOT
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    erro "Este script precisa ser executado como root (use: sudo $0)"
fi

# ==============================================================================
# DETECÇÃO DE FAMÍLIA DE DISTRIBUIÇÃO
# Usa ID e ID_LIKE para cobrir derivados corretamente.
# ==============================================================================

FAMILIA=""
DISTRO_NOME=""

detectar_familia() {
    titulo "Detectando distribuição"

    if [[ ! -f /etc/os-release ]]; then
        erro "/etc/os-release não encontrado. Distribuição não detectada."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    DISTRO_NOME="${PRETTY_NAME:-${ID:-desconhecida}}"
    local id_like="${ID_LIKE:-}"

    if [[ "${ID:-}" == "arch" ]] || [[ "$id_like" == *"arch"* ]]; then
        FAMILIA="arch"
    elif [[ "${ID:-}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian|neon)$ ]] \
      || [[ "$id_like" == *"debian"* ]] \
      || [[ "$id_like" == *"ubuntu"* ]]; then
        FAMILIA="debian"
    else
        erro "Distribuição não suportada: ${DISTRO_NOME} (ID=${ID:-?}, ID_LIKE=${id_like:-?})"
    fi

    log "Distribuição detectada: ${DISTRO_NOME}"
    log "Família: ${FAMILIA}"
}

# ==============================================================================
# LISTAS DE PACOTES
# ==============================================================================

pacotes_debian=(
    "ufw"
    "gufw"
    "clamav"
    "clamav-daemon"
    "clamtk"
    "gpg"
    "openvpn"
    "rkhunter"
    "chkrootkit"
    "firejail"
)

# No Arch: clamav já inclui clamd + freshclam internamente;
# gufw e clamtk podem estar no AUR ou em repos do derivado.
pacotes_arch=(
    "ufw"
    "clamav"
    "gnupg"
    "openvpn"
    "rkhunter"
    "chkrootkit"
    "firejail"
)

pacotes_arch_opcional=(
    "gufw"
    "clamtk"
)

# ==============================================================================
# INSTALAÇÃO DE PACOTES
# ==============================================================================

install_apt() {
    titulo "Instalando pacotes via apt — ${DISTRO_NOME}"
    passo "Atualizando índice de pacotes..."
    apt-get update -qq
    passo "Instalando: ${pacotes_debian[*]}"
    apt-get install -y "${pacotes_debian[@]}"
    log "Todos os pacotes debian instalados com sucesso."
}

# Tenta instalar via AUR helper disponível (yay → paru → aviso)
instalar_aur() {
    local pkg="$1"
    local aur_user="${SUDO_USER:-}"

    if [[ -z "$aur_user" ]]; then
        warn "Não foi possível determinar o usuário não-root para AUR. Instale '${pkg}' manualmente."
        return 1
    fi

    if command -v yay &>/dev/null; then
        passo "Instalando '${pkg}' via yay (AUR) como ${aur_user}..."
        sudo -u "$aur_user" yay -S --noconfirm --needed "$pkg" \
            && log "✔ '${pkg}' instalado via yay." \
            || warn "✘ Falha ao instalar '${pkg}' via yay."
    elif command -v paru &>/dev/null; then
        passo "Instalando '${pkg}' via paru (AUR) como ${aur_user}..."
        sudo -u "$aur_user" paru -S --noconfirm --needed "$pkg" \
            && log "✔ '${pkg}' instalado via paru." \
            || warn "✘ Falha ao instalar '${pkg}' via paru."
    else
        warn "Nenhum AUR helper encontrado (yay/paru)."
        warn "Instale manualmente: yay -S ${pkg}   ou   paru -S ${pkg}"
    fi
}

install_pacman() {
    titulo "Instalando pacotes via pacman — ${DISTRO_NOME}"
    passo "Sincronizando base de dados de pacotes..."
    pacman -Sy --noconfirm

    passo "Instalando pacotes principais: ${pacotes_arch[*]}"
    for pkg in "${pacotes_arch[@]}"; do
        if pacman -Si "$pkg" &>/dev/null; then
            pacman -S --noconfirm --needed "$pkg" \
                && log "  ✔ ${pkg}" \
                || warn "  ✘ Falha ao instalar ${pkg}."
        else
            warn "  '${pkg}' não encontrado nos repositórios — pulando."
        fi
    done

    passo "Tentando instalar pacotes opcionais: ${pacotes_arch_opcional[*]}"
    for pkg in "${pacotes_arch_opcional[@]}"; do
        if pacman -Si "$pkg" &>/dev/null; then
            pacman -S --noconfirm --needed "$pkg" \
                && log "  ✔ ${pkg}" \
                || { warn "  ✘ Falha via pacman. Tentando AUR..."; instalar_aur "$pkg"; }
        else
            warn "  '${pkg}' não está nos repos oficiais — tentando AUR..."
            instalar_aur "$pkg"
        fi
    done

    log "Instalação de pacotes Arch concluída."
}

instalar() {
    titulo "Instalação de Pacotes"
    case "$FAMILIA" in
        debian) install_apt    ;;
        arch)   install_pacman ;;
    esac
}

# ==============================================================================
# UFW - Firewall
# (comportamento idêntico entre as famílias)
# ==============================================================================

configurar_ufw() {
    titulo "Configurando UFW (Firewall)"

    passo "Habilitando UFW no boot..."
    systemctl enable ufw
    log "UFW configurado para iniciar com o sistema."

    passo "Definindo políticas padrão..."
    ufw default deny incoming
    ufw default allow outgoing

    passo "Adicionando regra SSH..."
    ufw allow ssh
    warn "Regra SSH adicionada — acesso remoto preservado."

    passo "Ativando UFW..."
    ufw --force enable
    log "UFW ativado com sucesso."

    log "Status atual do UFW:"
    ufw status verbose
}

# ==============================================================================
# ClamAV - Antivírus
# Diferenças entre famílias:
#   Debian → serviço do daemon: clamav-daemon
#   Arch   → serviço do daemon: clamd  (às vezes clamav)
# A detecção dinâmica cobre ambos os casos.
# ==============================================================================

configurar_clamav() {
    titulo "Configurando ClamAV (Antivírus)"

    # ── Detecção dinâmica do serviço daemon ─────────────────────────────────
    passo "Detectando serviço do ClamAV daemon..."
    local svc_daemon=""
    local candidatos=("clamav-daemon" "clamd" "clamav")
    for candidato in "${candidatos[@]}"; do
        if systemctl list-unit-files "${candidato}.service" 2>/dev/null \
                | grep -q "${candidato}.service"; then
            svc_daemon="$candidato"
            break
        fi
    done

    if [[ -z "$svc_daemon" ]]; then
        warn "Serviço ClamAV daemon não encontrado (clamav-daemon / clamd / clamav)."
        warn "Verifique com: systemctl list-unit-files | grep -i clam"
        warn "O daemon não será ativado agora — freshclam e cron continuarão normalmente."
    else
        log "Serviço daemon detectado: ${svc_daemon}.service"
    fi

    # ── Atualização da base de dados ────────────────────────────────────────
    passo "Atualizando base de dados de vírus (freshclam)..."
    systemctl stop clamav-freshclam 2>/dev/null || true
    freshclam
    log "Base de dados do ClamAV atualizada."

    # ── Freshclam (atualizações automáticas) ────────────────────────────────
    passo "Ativando serviço freshclam..."
    systemctl enable clamav-freshclam
    systemctl start  clamav-freshclam
    log "Serviço freshclam (atualização automática) ativo."

    # ── Daemon principal ─────────────────────────────────────────────────────
    if [[ -n "$svc_daemon" ]]; then
        passo "Ativando daemon do ClamAV (${svc_daemon})..."
        systemctl enable "$svc_daemon"
        systemctl start  "$svc_daemon"
        log "ClamAV daemon (${svc_daemon}) ativo."
    fi

    # ── Cron: scan diário às 02:00 ──────────────────────────────────────────
    local CRON_FILE="/etc/cron.d/clamav-scan-diario"
    passo "Agendando scan diário em ${CRON_FILE}..."

    cat > "$CRON_FILE" <<'EOF'
# ClamAV — scan completo diário às 02:00
# Gerado por security_suite.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 2 * * *  root  clamscan -r / \
    --exclude-dir='^/sys' \
    --exclude-dir='^/proc' \
    --exclude-dir='^/dev'  \
    --exclude-dir='^/run'  \
    -l /var/log/clamav/scan_diario.log \
    --remove=no
EOF
    chmod 644 "$CRON_FILE"
    mkdir -p /var/log/clamav
    log "Scan diário agendado para 02:00 → /var/log/clamav/scan_diario.log"
}

# ==============================================================================
# RKHunter + CHKRootkit - Detecção de Rootkits
# (comportamento idêntico entre as famílias)
# ==============================================================================

configurar_rootkit_scan() {
    titulo "Configurando RKHunter + CHKRootkit"

    # ── Wrapper temporário egrep→grep -E ────────────────────────────────────
    # rkhunter chama egrep internamente (obsoleto em sistemas modernos).
    # O wrapper redireciona para grep -E, suprimindo avisos inofensivos.
    passo "Criando wrapper temporário egrep → grep -E..."
    local wrapper_dir
    wrapper_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexec grep -E "$@" 2>/dev/null\n' \
        > "${wrapper_dir}/egrep"
    chmod +x "${wrapper_dir}/egrep"
    export PATH="${wrapper_dir}:${PATH}"
    log "Wrapper temporário criado em ${wrapper_dir}/egrep."

    passo "Atualizando base de dados do rkhunter..."
    env PATH="${PATH}" rkhunter --update \
        || warn "Atualização do rkhunter retornou avisos (verifique manualmente)."
    env PATH="${PATH}" rkhunter --propupd
    log "Propriedades do sistema registradas no rkhunter."

    # Remove wrapper temporário
    rm -rf "${wrapper_dir}"
    log "Wrapper temporário removido."

    # ── Wrapper permanente para uso no cron ─────────────────────────────────
    local wrapper_cron="/usr/local/bin/egrep"
    if [[ ! -f "$wrapper_cron" ]]; then
        passo "Criando wrapper permanente egrep → grep -E em ${wrapper_cron}..."
        printf '#!/usr/bin/env bash\nexec grep -E "$@" 2>/dev/null\n' \
            | tee "$wrapper_cron" > /dev/null
        chmod +x "$wrapper_cron"
        log "Wrapper permanente criado: ${wrapper_cron}"
    else
        log "Wrapper permanente já existe: ${wrapper_cron}"
    fi

    # ── Cron: scan diário às 03:00 ──────────────────────────────────────────
    local CRON_FILE="/etc/cron.d/rootkit-scan-diario"
    passo "Agendando scan de rootkits em ${CRON_FILE}..."

    if command -v chkrootkit &>/dev/null; then
        cat > "$CRON_FILE" <<'EOF'
# Rootkit scan diário às 03:00 — rkhunter + chkrootkit
# Gerado por security_suite.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * *  root  rkhunter --check --skip-keypress --report-warnings-only \
    >> /var/log/rkhunter_diario.log 2>&1 \
    && chkrootkit >> /var/log/chkrootkit_diario.log 2>&1
EOF
        log "Scan agendado: rkhunter + chkrootkit às 03:00"
        log "  - RKHunter   → /var/log/rkhunter_diario.log"
        log "  - CHKRootkit → /var/log/chkrootkit_diario.log"
    else
        warn "chkrootkit não encontrado. Usando apenas rkhunter no cron."
        cat > "$CRON_FILE" <<'EOF'
# Rootkit scan diário às 03:00 — apenas rkhunter
# Gerado por security_suite.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * *  root  rkhunter --check --skip-keypress --report-warnings-only \
    >> /var/log/rkhunter_diario.log 2>&1
EOF
        log "Scan agendado: rkhunter às 03:00 → /var/log/rkhunter_diario.log"
    fi

    chmod 644 "$CRON_FILE"
}

# ==============================================================================
# OpenVPN - VPN
# (comportamento idêntico entre as famílias)
# ==============================================================================

configurar_openvpn() {
    titulo "Configurando OpenVPN"

    passo "Habilitando OpenVPN no boot..."
    systemctl enable openvpn
    log "Serviço OpenVPN habilitado no boot."

    if ls /etc/openvpn/*.ovpn &>/dev/null 2>&1; then
        passo "Perfis .ovpn encontrados. Iniciando OpenVPN..."
        systemctl start openvpn
        log "OpenVPN iniciado."
    else
        warn "Nenhum perfil .ovpn encontrado em /etc/openvpn/."
        warn "Para ativar a VPN após copiar o perfil:"
        warn "  sudo systemctl start openvpn@<nome-do-perfil>"
        warn "Exemplo: sudo systemctl start openvpn@minha-vpn"
    fi
}

# ==============================================================================
# RESUMO FINAL
# ==============================================================================

resumo() {
    titulo "Configuração Concluída — ${DISTRO_NOME}"
    echo ""
    echo -e "${GREEN}  ✔ Pacotes instalados"
    echo "  ✔ UFW ativo (inicia com o sistema)"
    echo "  ✔ ClamAV daemon ativo + scan diário às 02:00"
    echo "  ✔ RKHunter + CHKRootkit com scan diário às 03:00"
    echo -e "  ✔ OpenVPN habilitado no boot${NC}"
    echo ""
    echo "Logs de segurança (execuções futuras):"
    echo "  /var/log/clamav/scan_diario.log"
    echo "  /var/log/rkhunter_diario.log"
    echo "  /var/log/chkrootkit_diario.log"
    echo ""
    echo "Log desta instalação:"
    echo "  ${LOG_FILE}"
    echo ""
    echo "Fim: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
}

# ==============================================================================
# EXECUÇÃO PRINCIPAL
# ==============================================================================

detectar_familia
instalar
configurar_ufw
configurar_clamav
configurar_rootkit_scan
configurar_openvpn
resumo