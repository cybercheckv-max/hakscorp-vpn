#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Error en línea $LINENO" >&2' ERR
if [[ $EUID -ne 0 ]]; then echo 'Ejecuta como root: sudo bash install.sh' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != ubuntu || ("$VERSION_ID" != 22.04 && "$VERSION_ID" != 24.04) ]]; then echo 'Solo Ubuntu 22.04/24.04' >&2; exit 1; fi
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL=/opt/hakscorp
DATA=/var/lib/hakscorp
read -rp 'Dominio DNS apuntando a este servidor (ej vpn.ejemplo.com): ' DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{2,250}$ || "$DOMAIN" != *.* ]]; then echo 'Dominio inválido' >&2; exit 1; fi
read -rp 'Email para Lets Encrypt: ' EMAIL
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then echo 'Email inválido' >&2; exit 1; fi
read -rp 'Nombre de SuperAdmin [admin]: ' ADMIN
ADMIN="${ADMIN:-admin}"
if [[ ! "$ADMIN" =~ ^[a-z][a-z0-9_]{2,23}$ ]]; then echo 'Nombre inválido' >&2; exit 1; fi
read -rsp 'Contraseña SuperAdmin (mín. 12): ' ADMIN_PASS; echo
if [[ ${#ADMIN_PASS} -lt 12 ]]; then echo 'Contraseña demasiado corta' >&2; exit 1; fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip nginx openssh-server sudo certbot python3-certbot-nginx git
id -u hakscorp >/dev/null 2>&1 || useradd --system --home-dir "$INSTALL" --shell /usr/sbin/nologin hakscorp
install -d -o root -g root -m 755 "$INSTALL"
install -d -o hakscorp -g hakscorp -m 700 "$DATA"
cp -a "$SRC/app" "$SRC/requirements.txt" "$INSTALL/"
chown -R root:root "$INSTALL/app" "$INSTALL/requirements.txt"
python3 -m venv "$INSTALL/.venv"
"$INSTALL/.venv/bin/pip" install --no-cache-dir -r "$INSTALL/requirements.txt"
install -m 0755 -o root -g root -d /usr/local/libexec
install -m 0755 -o root -g root "$SRC/root_helper.py" /usr/local/libexec/hakscorp-ssh
printf 'hakscorp ALL=(root) NOPASSWD: /usr/local/libexec/hakscorp-ssh\n' > /etc/sudoers.d/hakscorp
chmod 0440 /etc/sudoers.d/hakscorp
visudo -cf /etc/sudoers.d/hakscorp
ENV="$INSTALL/.env"
if [[ ! -f "$ENV" ]]; then
  cp "$SRC/.env.example" "$ENV"
  SECRET="$(openssl rand -hex 48)"
  FERNET="$("$INSTALL/.venv/bin/python" -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
  export DOMAIN ADMIN ADMIN_PASS SECRET FERNET
  "$INSTALL/.venv/bin/python" - "$ENV" <<'PYSCRIPT'
import os,sys
from pathlib import Path
p=Path(sys.argv[1]); content=p.read_text()
repls={'DOMAIN':os.environ['DOMAIN'],'BASE_URL':'https://'+os.environ['DOMAIN'],'SECRET_KEY':os.environ['SECRET'],'CREDENTIAL_KEY':os.environ['FERNET'],'ADMIN_USERNAME':os.environ['ADMIN'],'ADMIN_PASSWORD':os.environ['ADMIN_PASS']}
for key,value in repls.items():
    content='\n'.join((key+'='+value if x.startswith(key+'=') else x) for x in content.split('\n'))
p.write_text(content)
PYSCRIPT
else
  echo 'Se conserva .env existente; revisa DOMAIN y BASE_URL.'
fi
chown root:hakscorp "$ENV"; chmod 0640 "$ENV"
cat > /etc/systemd/system/hakscorp.service <<EOF
[Unit]
Description=HakScorp VPN FastAPI
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=hakscorp
Group=hakscorp
WorkingDirectory=$INSTALL
EnvironmentFile=$ENV
ExecStart=$INSTALL/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8765 --workers 1 --proxy-headers --forwarded-allow-ips 127.0.0.1
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/nginx/sites-available/hakscorp <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 1m;
    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Request-ID \$request_id;
        proxy_read_timeout 30s;
    }
}
EOF
ln -sfn /etc/nginx/sites-available/hakscorp /etc/nginx/sites-enabled/hakscorp
nginx -t
systemctl daemon-reload
systemctl enable --now ssh
systemctl enable --now hakscorp
systemctl reload nginx
certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect
systemctl restart hakscorp
printf '\nInstalado: https://%s/login\nCredenciales admin en tu .env o las definidas al instalar.\n' "$DOMAIN"
echo 'Configura Mercado Pago, Telegram, Turnstile y acortadores en /opt/hakscorp/.env y reinicia: systemctl restart hakscorp'
