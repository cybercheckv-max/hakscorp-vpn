# HakScorp VPN — Administrador SSH / Multi-revendedor

Panel FastAPI con cuentas Linux SSH reales, cupos reutilizables, Mercado Pago Checkout Pro, Telegram, Turnstile y enlaces publicitarios. Requiere **Ubuntu 22.04/24.04, dominio DNS, puertos 80/443 accesibles, root y OpenSSH**.

> **Importante:** proyecto de referencia desplegable en un VPS dedicado, no una certificación de seguridad/producción. Antes de operar comercialmente, audita el código, revisa normativa, accesos y pruebas de carga. No está permitido usarlo para administrar cuentas del sistema preexistentes.

## Instalación

Clona tu repositorio GitHub (no ejecutes scripts remotos sin inspeccionarlos):

```bash
git clone https://github.com/TU_USUARIO/hakscorp-vpn.git
cd hakscorp-vpn
sudo bash install.sh
```

El instalador instala Nginx, OpenSSH, Python, certificados Let's Encrypt con Certbot, usuario del sistema `hakscorp`, helper root exclusivo con sudoers, systemd y base SQLite. Solicita dominio, correo y contraseña admin. Después:

```bash
sudo nano /opt/hakscorp/.env
sudo systemctl restart hakscorp
sudo journalctl -u hakscorp -f
```

**Nunca publiques** `.env`, claves de terceros, credenciales SSH ni bases de datos. Para actualizar el código, haz copia de la base y aplica el nuevo código siguiendo un procedimiento de despliegue controlado; el instalador solo conserva la configuración `.env`, no gestiona migraciones automáticas.

## Configuración

- `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET`, `MP_CURRENCY`: credenciales reales de Mercado Pago y moneda de la cuenta. Registra `https://DOMINIO/webhook/mercadopago` como Webhook de tipo `payment`; en un entorno de pruebas usa credenciales y flujos aprobados por Mercado Pago.
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ADMIN_CHAT_ID`: BotFather y chat del administrador. El bot usa polling; **solo un proceso** debe ejecutar el worker/bot.
- `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`: Cloudflare Turnstile real para `/free`. No se permite reclamar si falta.
- `SHORTENER_PROVIDER_1`, `SHORTENER_PROVIDER_2`: `none`, `ouo`, `shrinkearn`, `clksh`; configurar `OUO_API_KEY`, `SHRINKEARN_API_KEY`, `CLKSH_API_KEY`. Los proveedores cambian formatos, endpoints y condiciones: verifica el contrato del proveedor antes de monetizar. Las URLs deben ser HTTPS. La opción `none` en ambos deshabilita el generador gratuito para evitar bypass por enlace directo.
- `SSH_PORT`, `SSL_PORT`, `WS_PORT`: únicamente datos mostrados al usuario. **No instalan ni habilitan transportes SSL/WS**: instala tú un proxy/túnel seguro compatible si los necesitas y configura números que correspondan a servicios reales. HTTPS del panel en 443 no es automáticamente SSH sobre TLS.
- Los fragmentos publicitarios `ad_slot_*` se guardan en SQLite y se ejecutan **solo en las páginas públicas**. Son JS con privilegios del origen: restringe quién accede a SuperAdmin, revisa los scripts de terceros y considera mover publicidad a un dominio aislado.

## Semántica de tokens

Un token cubre **una cuenta SSH no suspendida y no expirada** del revendedor, independientemente de cuántas conexiones tenga. Suspender, eliminar o expirar libera cupo. Los cupos adquiridos se agregan a `token_limit`; cada compra extiende la vigencia tomando la fecha más reciente entre hoy y la anterior. La desactivación de un revendedor suspende sus usuarios. El trabajador elimina del SO cuentas expiradas cada 10 minutos y corta sesiones excedentes cada minuto.

**Limitación de supervisión SSH:** el conteo usa procesos `sshd`/`sshd-session` cuyo UID real coincide con el usuario administrado. El comportamiento varía según versión y PAM/OpenSSH, y no sustituye límites a nivel de `sshd_config` o PAM. Para producción configura también `MaxSessions`, `MaxStartups`, `pam_limits`, rate limiting y monitoreo de `auth.log`. `pkill -u` desconecta todos los procesos del usuario únicamente en las acciones de bloqueo, eliminación o desconexión; el recorte por conexión intenta matar solo sesiones SSH excedentes.

## Prueba local sin modificar usuarios Linux

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python -c 'import secrets; from cryptography.fernet import Fernet; print(secrets.token_hex(48)); print(Fernet.generate_key().decode())'
# Copia los valores a SECRET_KEY y CREDENTIAL_KEY, configura ADMIN_PASSWORD y SESSION_HTTPS_ONLY=false.
RUN_WORKERS=0 uvicorn app.main:app --reload
pytest -q
```

En modo local, llamadas SSH requieren helper root instalado; las pruebas unitarias lo sustituyen mediante mocks. No uses `--reload` ni múltiples workers en producción. El proceso de trabajo no debe reiniciarse automáticamente mientras existan transacciones críticas fuera de la DB. Haz respaldos SQLite con la API de backup, no copies archivos abiertos arbitrariamente.

## Endpoints principales

| Ruta | Método | Función |
|---|---|---|
| `/api/login`, `/api/logout` | POST | Sesiones/cookies HTTP-only y protección CSRF |
| `/api/me`, `/api/users` | GET | Cupos y cuentas visibles |
| `/api/users` | POST | Crear SSH |
| `/api/users/{id}` | PATCH/DELETE | Modificar/eliminar SSH |
| `/api/users/{id}/disconnect` | POST | Cortar sesiones |
| `/api/admin/resellers` | GET/POST | Gestión de revendedores |
| `/api/admin/resellers/{id}` | PATCH/DELETE | Modificar revendedores |
| `/api/admin/packages` | POST | Crear paquetes |
| `/api/admin/packages/{id}` | PATCH/DELETE | Modificar/desactivar paquetes |
| `/api/packages` | GET | Paquetes |
| `/api/admin/settings` | GET/PATCH | Ajustes y anuncios |
| `/api/admin/stats` | GET | CPU, RAM, SSH, pagos |
| `/api/telegram/link` | POST | Código vinculación (10 minutos) |
| `/api/free/start` | POST | Turnstile y enlace acortado |
| `/claim/{token}` | GET | Validar retorno |
| `/api/free/claim/{token}` | POST | Reclamar (una sola vez) |
| `/webhook/mercadopago` | POST | Confirmar pago firmado |

## Controles y límites conocidos

- Verificación criptográfica de Webhooks de Mercado Pago, consulta directa de pago aprobado, cotejo de monto/moneda/referencia y deduplicación por `payment_id`. Revisa variaciones de `data.id` en tu región. **El sistema no concilia automáticamente pagos pendientes si se pierde definitivamente el Webhook**.
- Turnstile validado en backend, IP obtenida del proxy local de confianza, token de reclamación almacenado como HMAC, expira en 15 minutos, consumo transaccional y mínimo de 45 segundos. El tiempo mínimo **no puede demostrar** que un visitante vio anuncios; una URL acortada puede llegar al destino antes del tiempo mínimo. Para prueba de conversión real se necesita callback firmado del proveedor de anuncios.
- Límite de cuentas gratuitas por IP controla cuentas presentes en la DB. Al borrar cuentas expiradas, el registro histórico se pierde y un visitante podría reclamar más dentro de 24h; para cotas estrictas es necesario conservar un ledger separado. IPv6, proxies y NAT pueden alterar equidad del límite.
- Los códigos Telegram viven en RAM, se pierden al reiniciar el servicio y requieren una sola instancia. Nunca compartas códigos de vinculación.
- El alta de usuarios revendedores usa `BEGIN IMMEDIATE` para serializar la comprobación de cupos; renovaciones y otros cambios simultáneos aún requieren pruebas de carga y transacciones más estrictas.
- La contraseña SSH se guarda cifrada (Fernet) para el botón Copiar, lo que la hace recuperable por operadores con permiso de panel. Evalúa mostrarla solo una vez o rotarla en cada lectura.
- El panel no dispone de migraciones Alembic, rate limiting distribuido, cola duradera para notificaciones, protección antibot para login, ledger de cuotas persistente ni integración real de SSH sobre SSL/WS. Se recomienda incorporarlos antes de aceptar público masivo.

## Estructura

```text
hakscorp-vpn/
├── app/
│   ├── __init__.py
│   ├── config.py
│   ├── models.py
│   ├── security.py
│   ├── ssh_manager.py
│   ├── mp_service.py
│   ├── shortener_service.py
│   ├── telegram_bot.py
│   ├── worker.py
│   ├── main.py
│   └── templates/
│       ├── base.html
│       ├── index.html
│       ├── login.html
│       ├── dashboard.html
│       ├── free.html
│       └── claim.html
├── root_helper.py
├── tests/test_core.py
├── requirements.txt
├── install.sh
├── .env.example
├── .gitignore
└── README.md
```
