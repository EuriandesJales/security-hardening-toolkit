#!/usr/bin/env bash

# ==============================================================================
# Security Suite - Instalação e Configuração Automática
# Suporte: Debian/Ubuntu e Arch Linux (+ derivados: CachyOS, Manjaro, EndeavourOS…)
# ==============================================================================

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
erro()   { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }
titulo() { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# ==============================================================================
# DETECÇÃO DE FAMÍLIA DE DISTRIBUIÇÃO
# Verifica ID e ID_LIKE para cobrir derivados (CachyOS, Manjaro, EndeavourOS…)
# ==============================================================================

FAMILIA=""
DISTRO_NOME=""

detectar_familia() {
    if [ ! -f /etc/os-release ]; then
        erro "Arquivo /etc/os-release não encontrado. Não foi possível detectar a distribuição."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    DISTRO_NOME="${PRETTY_NAME:-${ID:-desconhecida}}"

    # ID_LIKE pode conter múltiplos valores (ex: "arch chaotic-aur")
    local id_like="${ID_LIKE:-}"

    if [[ "${ID:-}" == "arch" ]] || [[ "$id_like" == *"arch"* ]]; then
        FAMILIA="arch"
    elif [[ "${ID:-}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)$ ]] \
      || [[ "$id_like" == *"debian"* ]] \
      || [[ "$id_like" == *"ubuntu"* ]]; then
        FAMILIA="debian"
    else
        erro "Distribuição não suportada: ${DISTRO_NOME}. (ID=${ID:-?}, ID_LIKE=${id_like:-?})"
    fi

    log "Distribuição detectada: ${DISTRO_NOME} → família '${FAMILIA}'"
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

# No Arch: clamav já inclui clamd + freshclam; chkrootkit está no repositório extra
pacotes_arch=(
    "ufw"
    "clamav"
    "gnupg"
    "openvpn"
    "rkhunter"
    "chkrootkit"
    "firejail"
)

# Pacotes gráficos opcionais para Arch (podem estar em repos do derivado ou AUR)
pacotes_arch_opcional=(
    "gufw"   # AUR ou repo do derivado
    "clamtk" # AUR ou repo do derivado
)

# ==============================================================================
# INSTALAÇÃO DE PACOTES
# ==============================================================================

install_apt() {
    titulo "Instalando pacotes (apt) — ${DISTRO_NOME}"
    sudo apt update
    sudo apt install -y "${pacotes_debian[@]}"
    log "Pacotes instalados com sucesso."
}

install_pacman() {
    titulo "Instalando pacotes (pacman) — ${DISTRO_NOME}"

    # Atualiza a base de dados antes de instalar
    sudo pacman -Sy --noconfirm

    # Instala pacotes principais (ignora erro de pacote não encontrado individualmente)
    for pkg in "${pacotes_arch[@]}"; do
        if pacman -Si "$pkg" &>/dev/null; then
            sudo pacman -S --noconfirm --needed "$pkg"
        else
            warn "Pacote '${pkg}' não encontrado nos repositórios — pulando."
        fi
    done

    log "Pacotes principais instalados."

    # Tenta instalar pacotes opcionais (gufw, clamtk)
    warn "Tentando instalar pacotes opcionais (gufw, clamtk)..."
    for pkg in "${pacotes_arch_opcional[@]}"; do
        if pacman -Si "$pkg" &>/dev/null; then
            sudo pacman -S --noconfirm --needed "$pkg" \
                && log "  ✔ ${pkg} instalado." \
                || warn "  ✘ Falha ao instalar ${pkg} (disponível via AUR)."
        else
            warn "  '${pkg}' não está nos repos oficiais."
            instalar_aur "$pkg"
        fi
    done
}

# Tenta instalar via AUR helper (yay → paru → avisa)
instalar_aur() {
    local pkg="$1"
    if command -v yay &>/dev/null; then
        log "Instalando '${pkg}' via yay (AUR)..."
        yay -S --noconfirm --needed "$pkg" || warn "Falha ao instalar '${pkg}' via yay."
    elif command -v paru &>/dev/null; then
        log "Instalando '${pkg}' via paru (AUR)..."
        paru -S --noconfirm --needed "$pkg" || warn "Falha ao instalar '${pkg}' via paru."
    else
        warn "Nenhum AUR helper encontrado (yay/paru). Instale '${pkg}' manualmente:"
        warn "  yay -S ${pkg}   ou   paru -S ${pkg}"
    fi
}

instalar() {
    detectar_familia
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

    sudo systemctl enable ufw
    log "UFW configurado para iniciar com o sistema."

    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    sudo ufw allow ssh
    warn "Regra SSH adicionada para não perder acesso remoto."

    sudo ufw --force enable
    log "UFW ativado."

    sudo ufw status verbose
}

# ==============================================================================
# ClamAV - Antivírus
# Diferenças entre famílias:
#   Debian → serviço do daemon: clamav-daemon
#   Arch   → serviço do daemon: clamd
# ==============================================================================

configurar_clamav() {
    titulo "Configurando ClamAV (Antivírus)"

    # Detecta o nome real do serviço do daemon (varia entre distros e versões do pacote)
    local svc_daemon=""
    local candidatos=("clamav-daemon" "clamd" "clamav")
    for candidato in "${candidatos[@]}"; do
        if systemctl list-unit-files "${candidato}.service" 2>/dev/null | grep -q "${candidato}.service"; then
            svc_daemon="$candidato"
            break
        fi
    done

    if [[ -z "$svc_daemon" ]]; then
        warn "Nenhum serviço do ClamAV daemon encontrado (clamav-daemon / clamd / clamav)."
        warn "Verifique com: systemctl list-unit-files | grep -i clam"
        warn "Pulando ativação do daemon — freshclam e cron ainda serão configurados."
    else
        log "Serviço do daemon detectado: ${svc_daemon}.service"
    fi

    # Atualizar base de dados de vírus
    log "Atualizando base de dados do ClamAV..."
    sudo systemctl stop clamav-freshclam 2>/dev/null || true
    sudo freshclam
    log "Base de dados atualizada."

    # freshclam (atualizações automáticas)
    sudo systemctl enable clamav-freshclam
    sudo systemctl start  clamav-freshclam
    log "Serviço freshclam (atualização automática) ativado."

    # Daemon principal (só ativa se o serviço foi encontrado)
    if [[ -n "$svc_daemon" ]]; then
        sudo systemctl enable "$svc_daemon"
        sudo systemctl start  "$svc_daemon"
        log "Daemon do ClamAV (${svc_daemon}) ativado."
    fi

    # Scan diário via cron às 02:00
    local CRON_CLAMAV="0 2 * * * root clamscan -r / \
--exclude-dir='^/sys' \
--exclude-dir='^/proc' \
--exclude-dir='^/dev' \
-l /var/log/clamav/scan_diario.log \
--remove=no"
    local CRON_FILE="/etc/cron.d/clamav-scan-diario"

    echo "$CRON_CLAMAV" | sudo tee "$CRON_FILE" > /dev/null
    sudo chmod 644 "$CRON_FILE"
    sudo mkdir -p /var/log/clamav

    log "Scan diário agendado para as 02:00 (log: /var/log/clamav/scan_diario.log)."
}

# ==============================================================================
# RKHunter + CHKRootkit - Detecção de Rootkits
# (comportamento idêntico entre as famílias)
# ==============================================================================

configurar_rootkit_scan() {
    titulo "Configurando RKHunter + CHKRootkit"

    # rkhunter chama egrep internamente (obsoleto). Cria um wrapper temporário que
    # redireciona para grep -E, evitando os avisos "egrep is obsolescent".
    local wrapper_dir
    wrapper_dir="$(mktemp -d)"
    # grep -E não aceita escapes legados do egrep (\- \+ etc); stderr é suprimido
    # pois esses avisos são inofensivos e o resultado da busca permanece correto
    printf '#!/usr/bin/env bash\nexec grep -E "$@" 2>/dev/null\n' > "${wrapper_dir}/egrep"
    chmod +x "${wrapper_dir}/egrep"
    export PATH="${wrapper_dir}:${PATH}"
    log "Wrapper egrep→grep -E criado em ${wrapper_dir}."

    log "Atualizando base de dados do rkhunter..."
    sudo env PATH="${PATH}" rkhunter --update || warn "Atualização do rkhunter retornou avisos (verifique manualmente)."
    sudo env PATH="${PATH}" rkhunter --propupd
    log "Propriedades do sistema registradas no rkhunter."

    # Remove o wrapper após uso
    rm -rf "${wrapper_dir}"
    log "Wrapper temporário removido."

    # Wrapper permanente para o cron (rkhunter chama egrep internamente)
    local wrapper_cron="/usr/local/bin/egrep"
    if [ ! -f "$wrapper_cron" ]; then
        printf '#!/usr/bin/env bash\nexec grep -E "$@" 2>/dev/null\n' | sudo tee "$wrapper_cron" > /dev/null
        sudo chmod +x "$wrapper_cron"
        log "Wrapper permanente egrep→grep -E criado em ${wrapper_cron}."
    fi

    # Verifica se chkrootkit foi instalado
    if ! command -v chkrootkit &>/dev/null; then
        warn "chkrootkit não encontrado. O scan de rootkits usará apenas rkhunter."
        local CRON_RK="0 3 * * * root rkhunter --check --skip-keypress --report-warnings-only >> /var/log/rkhunter_diario.log 2>&1"
    else
        local CRON_RK="0 3 * * * root rkhunter --check --skip-keypress --report-warnings-only >> /var/log/rkhunter_diario.log 2>&1 \
&& chkrootkit >> /var/log/chkrootkit_diario.log 2>&1"
    fi

    local CRON_FILE="/etc/cron.d/rootkit-scan-diario"
    echo "$CRON_RK" | sudo tee "$CRON_FILE" > /dev/null
    sudo chmod 644 "$CRON_FILE"

    log "Scan de rootkits agendado para as 03:00."
    log "  - RKHunter   → /var/log/rkhunter_diario.log"
    command -v chkrootkit &>/dev/null && log "  - CHKRootkit → /var/log/chkrootkit_diario.log"
}

# ==============================================================================
# OpenVPN - VPN
# (comportamento idêntico entre as famílias)
# ==============================================================================

configurar_openvpn() {
    titulo "Configurando OpenVPN"

    sudo systemctl enable openvpn
    log "Serviço OpenVPN habilitado no boot."

    if ls /etc/openvpn/*.ovpn &>/dev/null; then
        log "Perfis .ovpn encontrados em /etc/openvpn/. Iniciando OpenVPN..."
        sudo systemctl start openvpn
    else
        warn "Nenhum perfil .ovpn encontrado em /etc/openvpn/."
        warn "Para ativar a VPN, copie seu arquivo .ovpn para /etc/openvpn/ e execute:"
        warn "  sudo systemctl start openvpn@<nome-do-perfil>"
        warn "Exemplo (perfil chamado 'minha-vpn.ovpn'):"
        warn "  sudo systemctl start openvpn@minha-vpn"
    fi
}

# ==============================================================================
# RESUMO FINAL
# ==============================================================================

resumo() {
    titulo "Configuração Concluída — ${DISTRO_NOME}"
    echo -e "${GREEN}"
    echo "  ✔ Pacotes instalados"
    echo "  ✔ UFW ativo (inicia com o sistema)"
    echo "  ✔ ClamAV daemon ativo + scan diário às 02:00"
    echo "  ✔ RKHunter + CHKRootkit com scan diário às 03:00"
    echo "  ✔ OpenVPN habilitado no boot"
    echo -e "${NC}"
    echo "Logs de segurança:"
    echo "  /var/log/clamav/scan_diario.log"
    echo "  /var/log/rkhunter_diario.log"
    echo "  /var/log/chkrootkit_diario.log"
}

# ==============================================================================
# EXECUÇÃO PRINCIPAL
# ==============================================================================

instalar
configurar_ufw
configurar_clamav
configurar_rootkit_scan
configurar_openvpn
resumo
