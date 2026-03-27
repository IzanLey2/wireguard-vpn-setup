# WireGuard VPN — Guía completa de configuración

Infraestructura VPN con WireGuard para proteger el acceso a servicios web internos.

## Arquitectura

```
[Windows / Linux Cliente]
        │
        │  WireGuard UDP 51820
        ▼
[Servidor VPN — Debian 12]  ◄──── Punto central de la red
   IP pública: X.X.X.X
   IP VPN:     10.0.0.1
        │
        │  Red interna 10.0.0.0/24
        ▼
[Servidor Web — Ubuntu 22.04]
   IP VPN: 10.0.0.3
   nginx solo acepta 10.0.0.0/24
```

**Solo los usuarios conectados a la VPN pueden acceder a la web.**

---

## Requisitos

| Componente | Requisito |
|-----------|-----------|
| Servidor VPN | Debian 12 con IP pública |
| Servidor Web | Ubuntu 22.04 con nginx |
| Cliente | Windows 10/11 con WireGuard |
| Puerto | UDP 51820 abierto en el firewall del proveedor |

---

## Servidor VPN (Debian 12)

### Instalación

```bash
apt update && apt install -y wireguard

# Generar claves del servidor
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey | tee /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key
```

### Configuración `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <PRIVATE_KEY_SERVIDOR>
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens6 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens6 -j MASQUERADE

# cliente: usuario1
[Peer]
PublicKey = <PUBLIC_KEY_CLIENTE>
AllowedIPs = 10.0.0.2/32
```

> Sustituye `ens6` por tu interfaz de red real (`ip route | grep default`)

### Activar IP forwarding

```bash
echo "net.ipv4.ip_forward=1" | tee -a /etc/sysctl.conf
sysctl -p
```

### Arrancar el servicio

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
wg show
```

---

## Servidor Web (Ubuntu 22.04 + nginx)

### Instalar WireGuard

```bash
apt update && apt install -y wireguard

# Generar claves
wg genkey | tee /etc/wireguard/private.key | wg pubkey | tee /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

### Configuración `/etc/wireguard/wg0.conf`

```ini
[Interface]
PrivateKey = <PRIVATE_KEY_ESTE_SERVIDOR>
Address = 10.0.0.3/24

[Peer]
PublicKey = <PUBLIC_KEY_SERVIDOR_VPN>
Endpoint = <IP_SERVIDOR_VPN>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

### Arrancar y registrar en el servidor VPN

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

En el **servidor VPN Debian** añadir este servidor como peer:

```bash
wg set wg0 peer <PUBLIC_KEY_UBUNTU> allowed-ips 10.0.0.3/32
wg-quick save wg0
```

### Restringir nginx a la VPN

En `/etc/nginx/sites-available/tu-sitio`, dentro de cada `location {}`:

```nginx
location / {
    allow 10.0.0.0/24;
    allow <IP_PUBLICA_SERVIDOR_VPN>;
    deny all;
    # ... resto de config
}

location /static/ {
    allow 10.0.0.0/24;
    allow <IP_PUBLICA_SERVIDOR_VPN>;
    deny all;
    # ... resto de config
}
```

```bash
nginx -t && systemctl reload nginx
```

### Restringir UFW

```bash
ufw delete allow 80/tcp
ufw delete allow 443/tcp
ufw allow in on wg0 to any port 80
ufw allow in on wg0 to any port 443
ufw reload
```

---

## Cliente Windows 10/11

### Instalación

Descargar WireGuard desde [wireguard.com/install](https://www.wireguard.com/install/)

### Configuración del túnel

1. Abre WireGuard → **Añadir túnel → Crear nuevo túnel vacío**
2. Pon un nombre (ej: `vpn-trabajo`)
3. Copia la **clave pública** que aparece arriba y dásela al admin
4. Pega esta config (el admin te dará los valores):

```ini
[Interface]
PrivateKey = <SE_GENERA_AUTOMATICO>
Address = 10.0.0.X/24
DNS = 8.8.8.8

[Peer]
PublicKey = <PUBLIC_KEY_SERVIDOR_VPN>
AllowedIPs = 0.0.0.0/0
Endpoint = <IP_SERVIDOR_VPN>:51820
PersistentKeepalive = 25
```

5. Click en **Guardar** → **Activar**

---

## Firewall del proveedor (IONOS / similar)

En el panel de tu proveedor debes abrir:

| Protocolo | Puerto | Dirección | Descripción |
|-----------|--------|-----------|-------------|
| UDP | 51820 | Entrada | WireGuard VPN |
| TCP | 22 | Entrada | SSH admin |
| TCP | 80 | Entrada | HTTP (opcional) |
| TCP | 443 | Entrada | HTTPS (opcional) |

> El error más común es abrir el 51820 en **TCP** en vez de **UDP**. WireGuard **solo usa UDP**.

---

## Script de gestión de usuarios

El archivo `wg-manager.sh` automatiza la gestión de usuarios desde el servidor VPN.

### Instalación

```bash
# Desde Windows (PowerShell)
scp wg-manager.sh root@<IP_SERVIDOR_VPN>:/root/wg-manager.sh

# En el servidor
chmod +x /root/wg-manager.sh
./wg-manager.sh
```

### Funcionalidades

| Opción | Descripción |
|--------|-------------|
| **1) Añadir usuario** | Genera claves, asigna IP y crea `.conf` listo para enviar |
| **2) Eliminar usuario** | Revoca acceso y elimina su config |
| **3) Listar usuarios** | Muestra todos los peers y si están conectados ahora |
| **4) Ver config** | Muestra el `.conf` de un usuario para reenviarle |

Los archivos `.conf` de cada usuario se guardan en `/etc/wireguard/clientes/`.

### Uso

```
╔══════════════════════════════╗
║     WireGuard Manager VPN   ║
╚══════════════════════════════╝
  1) Añadir usuario
  2) Eliminar usuario
  3) Listar usuarios y estado
  4) Ver config de un usuario
  5) Salir
```

---

## 🔧 Comandos útiles

```bash
# Ver estado de la VPN y peers conectados
wg show

# Ver si un peer hizo handshake recientemente
wg show wg0 latest-handshakes

# Reiniciar WireGuard
systemctl restart wg-quick@wg0

# Ver logs en tiempo real
journalctl -fu wg-quick@wg0

# Añadir peer manualmente sin reiniciar
wg set wg0 peer <PUBLIC_KEY> allowed-ips 10.0.0.X/32

# Eliminar peer sin reiniciar
wg set wg0 peer <PUBLIC_KEY> remove

# Guardar estado actual al archivo .conf
wg-quick save wg0
```

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| Handshake no completa | Puerto UDP bloqueado en proveedor | Añadir regla UDP 51820 en panel del proveedor |
| Handshake no completa | Clave pública incorrecta | Verificar que la pubkey del cliente está en el servidor |
| Conecta pero no carga la web | NAT no configurado | Activar IP forwarding + regla MASQUERADE |
| Web devuelve 403 | IP no permitida en nginx | Añadir `allow 10.0.0.0/24` en location |
| WireGuard no arranca | Interfaz ya existe | `wg-quick down wg0` antes de `wg-quick up wg0` |

---

## Estructura del repositorio

```
├── README.md                  # Esta guía
├── wg-manager.sh              # Script de gestión de usuarios
├── configs/
│   ├── servidor-vpn/
│   │   └── wg0.conf.example   # Config del servidor VPN (sin claves)
│   ├── servidor-web/
│   │   ├── wg0.conf.example   # Config WireGuard del servidor web
│   │   └── nginx-site.example # Config nginx con restricción VPN
│   └── cliente-windows/
│       └── cliente.conf.example # Config del cliente Windows
```

---

## Seguridad

- **Nunca subas claves privadas al repositorio**
- Los archivos `.conf` con claves reales deben estar en `.gitignore`
- Usa el script `wg-manager.sh` para gestionar claves, no las edites a mano
- Rota las claves periódicamente si sospechas que han sido comprometidas
