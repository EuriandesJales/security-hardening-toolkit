#!/usr/bin/env bash

# ==============================================================================
# Security Suite - Instalação e Configuração Automática
# Suporte: Debian/Ubuntu e Arch Linux
# ==============================================================================
# versao 1.0


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
# LISTAS DE PACOTES
# ==============================================================================

pacotes_debian=("ufw" "gufw" "clamav" "clamav-daemon" "clamtk" "gpg" "openvpn" "rkhunter" "chkrootkit" "firejail")
pacotes_arch=("ufw" "clamav" "gnupg" "openvpn" "rkhunter" "chkrootkit" "firejail")

# ==============================================================================
# INSTALAÇÃO DE PACOTES
# ==============================================================================

install_apt() {
    titulo "Instalando pacotes (apt)"
    sudo apt update
    sudo apt install -y "${pacotes_debian[@]}"
    log "Pacotes instalados com sucesso."
}

install_pacman() {
    titulo "Instalando pacotes (pacman)"
    sudo pacman -S --noconfirm "${pacotes_arch[@]}"
    log "Pacotes instalados com sucesso."
}

instalar() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        distro=$ID
    else
        erro "Não foi possível detectar a distribuição."
    fi

    case $distro in
        ubuntu|debian)
            install_apt
            ;;
        arch)
            install_pacman
            ;;
        *)
            erro "Distribuição não suportada: $distro"
            ;;
    esac
}

# ==============================================================================
# UFW - Firewall
# ==============================================================================

configurar_ufw() {
    titulo "Configurando UFW (Firewall)"

    # Habilitar UFW no boot
    sudo systemctl enable ufw
    log "UFW configurado para iniciar com o sistema."

    # Políticas padrão: bloquear entrada, permitir saída
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # Permitir SSH para não perder acesso remoto
    sudo ufw allow ssh
    warn "Regra SSH adicionada para não perder acesso remoto."

    # Ativar UFW (sem prompt interativo)
    sudo ufw --force enable
    log "UFW ativado."

    sudo ufw status verbose
}

# ==============================================================================
# ClamAV - Antivírus
# ==============================================================================

configurar_clamav() {
    titulo "Configurando ClamAV (Antivírus)"

    # Atualizar base de dados de vírus
    log "Atualizando base de dados do ClamAV..."
    sudo systemctl stop clamav-freshclam 2>/dev/null || true
    sudo freshclam
    log "Base de dados atualizada."

    # Habilitar e iniciar serviços
    sudo systemctl enable clamav-freshclam
    sudo systemctl start  clamav-freshclam
    log "Serviço freshclam (atualização automática) ativado."

    sudo systemctl enable clamav-daemon
    sudo systemctl start  clamav-daemon
    log "Daemon do ClamAV ativado."

    # Configurar scan diário via cron (todos os dias às 02:00)
    local CRON_CLAMAV="0 2 * * * root clamscan -r / --exclude-dir='^/sys' --exclude-dir='^/proc' --exclude-dir='^/dev' -l /var/log/clamav/scan_diario.log --remove=no"
    local CRON_FILE="/etc/cron.d/clamav-scan-diario"

    echo "$CRON_CLAMAV" | sudo tee "$CRON_FILE" > /dev/null
    sudo chmod 644 "$CRON_FILE"

    # Garantir que o diretório de log existe
    sudo mkdir -p /var/log/clamav

    log "Scan diário agendado para as 02:00 (log em /var/log/clamav/scan_diario.log)."
}

# ==============================================================================
# RKHunter + CHKRootkit - Detecção de Rootkits
# ==============================================================================

configurar_rootkit_scan() {
    titulo "Configurando RKHunter + CHKRootkit"

    # Atualizar base de dados do rkhunter
    log "Atualizando base de dados do rkhunter..."
    sudo rkhunter --update || warn "Atualização do rkhunter retornou avisos (verifique manualmente)."
    sudo rkhunter --propupd
    log "Propriedades do sistema registradas no rkhunter."

    # Cron diário: rkhunter + chkrootkit juntos às 03:00
    local CRON_RK="0 3 * * * root rkhunter --check --skip-keypress --report-warnings-only >> /var/log/rkhunter_diario.log 2>&1 && chkrootkit >> /var/log/chkrootkit_diario.log 2>&1"
    local CRON_FILE="/etc/cron.d/rootkit-scan-diario"

    echo "$CRON_RK" | sudo tee "$CRON_FILE" > /dev/null
    sudo chmod 644 "$CRON_FILE"

    log "Scan de rootkits agendado para as 03:00."
    log "  - RKHunter  → /var/log/rkhunter_diario.log"
    log "  - CHKRootkit → /var/log/chkrootkit_diario.log"
}

# ==============================================================================
# OpenVPN - VPN
# ==============================================================================

configurar_openvpn() {
    titulo "Configurando OpenVPN"

    # Habilitar OpenVPN no boot (aguarda perfis .ovpn)
    sudo systemctl enable openvpn
    log "Serviço OpenVPN habilitado no boot."

    # Verificar se existe algum perfil .ovpn em /etc/openvpn/
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
    titulo "Configuração Concluída"
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
