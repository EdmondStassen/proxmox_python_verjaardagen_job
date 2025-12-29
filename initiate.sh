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
var_unprivileged="${var_unprivileged:-1}"  # unprivileged LXC

# ================== INTERACTIEVE VRAGEN ==================

echo
echo "=============================================="
echo "   ${APP} - interactieve configuratie"
echo "=============================================="
echo

# 0) Containernaam / hostname opvragen
DEFAULT_HN="${HN:-$(echo "$APP" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')}"
while true; do
  read -rp "Naam/hostname voor de nieuwe container [${DEFAULT_HN}]: " INPUT_HN
  HN="${INPUT_HN:-$DEFAULT_HN}"

  # eenvoudige validatie: letters, cijfers en koppeltekens, begint met letter/cijfer
  if [[ "$HN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    break
  else
    echo "Ongeldige naam. Gebruik alleen letters, cijfers en koppeltekens, en laat niet beginnen met een koppelstreep."
  fi
done
export HN

# 1) Proxmox LXC root-wachtwoord genereren + eventueel overschrijven
echo "Er wordt automatisch een sterk root-wachtwoord voor de LXC gegenereerd."
# 20 tekens, letters/cijfers/symbolen
GEN_ROOT_PW="$(tr -dc 'A-Za-z0-9!@#$%_-+=' </dev/urandom | head -c 20 || true)"

# fallback als om wat voor reden dan ook GEN_ROOT_PW leeg is
if [[ -z "$GEN_ROOT_PW" ]]; then
  GEN_ROOT_PW="Pve$(date +%s%N | sha256sum | head -c 12)!"
fi

echo
echo "Voorgesteld root-wachtwoord voor de LXC:"
echo "  $GEN_ROOT_PW"
echo

while true; do
  read -srp "Druk Enter om dit wachtwoord te gebruiken, of voer een eigen wachtwoord in: " PW1
  echo
  if [[ -z "$PW1" ]]; then
    # gebruiker accepteert de gegenereerde variant
    var_pw="$GEN_ROOT_PW"
    echo "Gegenereerd wachtwoord wordt gebruikt."
    break
  else
    # gebruiker wil eigen wachtwoord -> even dubbel laten invoeren
    read -srp "Herhaal het eigen wachtwoord: " PW2
    echo
    if [[ "$PW1" != "$PW2" ]]; then
      echo "Wachtwoorden komen niet overeen, probeer opnieuw."
    else
      var_pw="$PW1"
      echo "Eigen wachtwoord wordt gebruikt."
      break
    fi
  fi
done

export var_pw

# 2) GitHub via PAT / HTTPS URL
echo
echo "Repository toegang via GitHub Personal Access Token (PAT) over HTTPS."
echo
echo "Je kunt hier één van de twee opties gebruiken:"
echo
echo "  Voorbeeld 1 - ALLEEN PAT-string:"
echo "    github_pat_..."
echo
echo "  Voorbeeld 2 - Volledige HTTPS-URL met PAT:"
echo "    https://github_pat_...@github.com/user/repo.git"
echo

GIT_REPO=""
while [[ -z "$GIT_REPO" ]]; do
  read -rp "Voer je GitHub PAT of volledige HTTPS-URL in: " GIT_INPUT

  # Alleen een PAT-string opgegeven?
  if [[ "$GIT_INPUT" == github_pat_* ]]; then
    GITHUB_PAT="$GIT_INPUT"

    # Repo-naam vragen in vorm user/repo
    REPO_SLUG=""
    while [[ -z "$REPO_SLUG" ]]; do
      read -rp "Voer de repository-naam in als 'user/repo' (bijv. mijnuser/mijnrepo): " REPO_SLUG
      if [[ "$REPO_SLUG" != */* ]]; then
        echo "Formaat ongeldig. Gebruik 'user/repo'."
        REPO_SLUG=""
      fi
    done

    GIT_REPO="https://$GITHUB_PAT@github.com/$REPO_SLUG.git"
    echo
    echo "Gegenereerde HTTPS-URL op basis van PAT:"
    echo "  $GIT_REPO"
    echo

    # Proberen te valideren als git op de host aanwezig is
    if command -v git >/dev/null 2>&1; then
      echo "Controleer toegang tot de repository met dit token..."
      if git ls-remote --heads "$GIT_REPO" >/dev/null 2>&1; then
        echo "✅ Token en repository lijken geldig."
      else
        echo "❌ FOUT: kan de repository niet benaderen met dit token/URL."
        echo "   - Klopt de repo-naam (user/repo)?"
        echo "   - Heeft de PAT voldoende rechten (Contents: read)?"
        exit 1
      fi
    else
      echo "Let op: 'git' is niet beschikbaar op de host, URL kan niet vooraf online gevalideerd worden."
    fi

  else
    # Niet met github_pat_ begonnen → we gaan ervan uit dat het al een volledige URL is
    # Voorbeeld:
    #   https://github_pat_...@github.com/user/repo.git
    GIT_REPO="$GIT_INPUT"
    echo
    echo "Ingevoerde Git clone-URL:"
    echo "  $GIT_REPO"
    echo

    if command -v git >/dev/null 2>&1; then
      echo "Controleer toegang tot de repository met deze URL..."
      if git ls-remote --heads "$GIT_REPO" >/dev/null 2>&1; then
        echo "✅ URL en toegang lijken geldig."
      else
        echo "❌ FOUT: kan de repository niet benaderen met deze URL."
        echo "   - Controleer PAT, rechten en repositorynaam."
        exit 1
      fi
    fi
  fi
done

export GIT_REPO

# App specifieke defaults (kun je desnoods nog aanpassen)
APP_DIR="${APP_DIR:-/opt/app}"                # map binnen de container
PYTHON_SCRIPT="${PYTHON_SCRIPT:-main.py}"     # entrypoint in je repo
CRON_SCHEDULE="${CRON_SCHEDULE:-0 */6 * * *}" # default: elke 6 uur
UV_BIN="${UV_BIN:-/root/.local/bin/uv}"       # uv-binary pad

echo
echo "Samenvatting invoer:"
echo "  - Containernaam   : $HN"
echo "  - Root wachtwoord : $var_pw"
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

    # Repo-URL (zoals opgegeven op de host)
    REPO_URL='$GIT_REPO'

    # App directory + repo
    mkdir -p '$APP_DIR'
    if [ ! -d '$APP_DIR/.git' ]; then
      git clone \"\$REPO_URL\" '$APP_DIR'
    else
      cd '$APP_DIR'
      git pull
    fi

    cd '$APP_DIR'

    # Dependencies controleren en evt. syncen via uv
    if [ -f \"pyproject.toml\" ] || [ -f \"requirements.txt\" ] || [ -f \"requirements.in\" ]; then
      echo \"[INFO] Dependency-bestanden gevonden in $APP_DIR:\"
      [ -f \"pyproject.toml\" ]   && echo \"  - pyproject.toml\"
      [ -f \"requirements.txt\" ] && echo \"  - requirements.txt\"
      [ -f \"requirements.in\" ]  && echo \"  - requirements.in\"

      echo \"[INFO] Voer 'uv sync' uit...\"
      '$UV_BIN' sync
    else
      echo \"[WARN] Geen pyproject.toml, requirements.txt of requirements.in gevonden in $APP_DIR\"
      echo \"[WARN] 'uv sync' wordt overgeslagen.\"
    fi

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

Hostname: $HN
IP address: $IP

Root password: $var_pw

Repo: $GIT_REPO
Script: $PYTHON_SCRIPT
Cron: $CRON_SCHEDULE"
    msg_ok "Container description bijgewerkt met hostname en IP: $IP"
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
echo -e "${INFO}${YW} Containernaam/hostname:${CL} ${GN}$HN${CL}"
echo -e "${INFO}${YW} De container gebruikt DHCP voor zijn IP-adres.${CL}"
echo -e "${INFO}${YW} Het IP-adres wordt getoond in:${CL}"
echo -e "${TAB}${NETWORK}${GN}- Proxmox 'Summary / Algemene informatie' (Description)${CL}"
echo -e "${TAB}${NETWORK}${GN}- /etc/motd binnen de container${CL}"
echo
echo -e "${INFO}${YW} Root-wachtwoord van de container:${CL} ${GN}$var_pw${CL}"
