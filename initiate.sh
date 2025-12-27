#!/usr/bin/env bash
# Gebaseerd op: https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh
# Draait op de Proxmox host

# Community-scripts core inladen
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# ================== BASIS-INFO OVER DE APP ==================
APP="Python uv cron"
var_tags="${var_tags:-python;uv;cron}"     # tags voor in Proxmox
var_cpu="${var_cpu:-1}"                    # CPU cores
var_ram="${var_ram:-512}"                  # RAM in MB
var_disk="${var_disk:-4}"                  # Disk in GB
var_os="${var_os:-debian}"                 # debian/ubuntu/alpine
var_version="${var_version:-13}"           # Debian 13
var_unprivileged="${var_unprivileged:-1}"  # onprivileged LXC

# ================== INTERACTIEVE VRAGEN ==================

echo
echo "=============================================="
echo "   ${APP} - interactieve configuratie"
echo "=============================================="
echo

# 1) Proxmox LXC root-wachtwoord vragen (var_pw)
while true; do
  read -srp "Kies een root-wachtwoord voor de LXC: " PW1
  echo
  read -srp "Herhaal het root-wachtwoord: " PW2
  echo
  if [[ "$PW1" != "$PW2" ]]; then
    echo "Wachtwoorden komen niet overeen, probeer opnieuw."
  elif [[ -z "$PW1" ]]; then
    echo "Wachtwoord mag niet leeg zijn, probeer opnieuw."
  else
    break
  fi
done
export var_pw="$PW1"

# 2) GitHub URL vragen (private repo -> liefst URL met token of SSH)
echo
echo "Voorbeeld:"
echo "  - HTTPS met token: https://<TOKEN>@github.com/user/repo.git"
echo "  - SSH-URL:         git@github.com:user/repo.git (vereist SSH key in de container)"
echo
while [[ -z "${GIT_REPO:-}" ]]; do
  read -rp "Voer de volledige Git clone-URL in voor de (private) repository: " GIT_REPO
done
export GIT_REPO

# App specifieke defaults (kun je desnoods nog aanpassen)
APP_DIR="${APP_DIR:-/opt/app}"                # map binnen de container
PYTHON_SCRIPT="${PYTHON_SCRIPT:-main.py}"     # entrypoint in je repo
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}" # default: elke 6 uur
UV_BIN="${UV_BIN:-/root/.local/bin/uv}"       # uv-binary pad

echo
echo "Samenvatting invoer:"
echo "  - Root wachtwoord : *** (verborgen)"
echo "  - GitHub URL      : $GIT_REPO"
echo "  - App directory   : $APP_DIR"
echo "  - Script          : $PYTHON_SCRIPT"
echo "  - Cron schedule   : $CRON_SCHEDULE"
echo

# ================== STANDAARD COMMUNITY-SCRIPTS FLOW ==================
header_info "$APP"
variables
color
catch_errors

# Optionele update-functie (standaard-stijl)
function update_script() {
  header_info "$APP"
  if [[ ! -d /var ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
  msg_info "Updating $APP LXC"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated $APP LXC"
  msg_ok "Updated successfully!"
  exit 0
}

# ================== POST-INSTALL: UV + GIT + CRON + IP ==================
post_install_python_uv() {
  msg_info "Configureer uv, GitHub repo en cron in CT ${CTID}"

  # Binnen de container: uv, repo, cron
  pct exec "$CTID" -- bash -c "
    set -e

    # Basis packages
    apt-get update
    apt-get -y upgrade
    apt-get install -y git curl python3 python3-distutils cron

    # uv installeren (indien nog niet aanwezig)
    if [ ! -x '$UV_BIN' ]; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    # App directory + repo
    mkdir -p '$APP_DIR'
    if [ ! -d '$APP_DIR/.git' ]; then
      git clone '$GIT_REPO' '$APP_DIR'
    else
      cd '$APP_DIR'
      git pull
    fi

    cd '$APP_DIR'

    # Dependencies syncen via uv (pyproject.toml / uv.lock / requirements)
    '$UV_BIN' sync

    # Log-directory
    mkdir -p /var/log/python-job

    # Cron job instellen (PATH uitbreiden voor uv)
    CRON_ENV='PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    (
      crontab -l 2>/dev/null
      echo \"\${CRON_ENV}
$CRON_SCHEDULE cd $APP_DIR && $UV_BIN sync && $UV_BIN run $PYTHON_SCRIPT >> /var/log/python-job/job.log 2>&1\"
    ) | crontab -

    systemctl enable cron
    systemctl restart cron

    # IP ook in /etc/motd zetten (voor console)
    if command -v hostname >/dev/null 2>&1; then
      IP=\$(hostname -I | awk '{print \$1}')
      sed -i '/IP Address:/d' /etc/motd 2>/dev/null || true
      echo \"IP Address: \$IP\" >> /etc/motd
    fi
  "

  msg_ok "uv, repo en cron zijn in de container geconfigureerd"

  # IP-adres ophalen (met wat retries voor DHCP)
  IP=""
  for i in {1..10}; do
    IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$IP" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -n "$IP" ]]; then
    pct set "$CTID" -description "Python uv cron container

IP address: $IP

Repo: $GIT_REPO
Script: $PYTHON_SCRIPT
Cron: $CRON_SCHEDULE"
    msg_ok "Container description bijgewerkt met IP: $IP"
  else
    msg_warn "Kon IP niet ophalen voor CT ${CTID} (mogelijk nog geen DHCP lease)."
  fi
}

# ================== CONTAINER MAKEN EN CONFIGUREREN ==================
start
build_container          # Maakt de Debian 13 LXC met DHCP (via build.func logica)
description              # Standaard description
post_install_python_uv   # Onze extra stappen

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} De container gebruikt DHCP voor zijn IP-adres.${CL}"
echo -e "${INFO}${YW} Het IP-adres wordt getoond in:${CL}"
echo -e "${TAB}${NETWORK}${GN}- Proxmox 'Summary / Algemene informatie' (Description)${CL}"
echo -e "${TAB}${NETWORK}${GN}- /etc/motd binnen de container${CL}"
