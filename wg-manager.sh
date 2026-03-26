#!/bin/bash

# ============================================================
#  WireGuard Manager — Gestión de usuarios VPN
#  Servidor: Debian 12 | Interfaz: wg0
# ============================================================

WG_CONF="/etc/wireguard/wg0.conf"
WG_IFACE="wg0"
SERVER_IP="212.227.108.95"
SERVER_PORT="51820"
SERVER_PUBKEY="A4kzteoEHah+1F7SD/tkHJlAHORVZKMqR+Y8RAoK0QE="
VPN_SUBNET="10.0.0"
CONFIGS_DIR="/etc/wireguard/clientes"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Funciones auxiliares
# ============================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] Ejecuta el script como root: sudo ./wg-manager.sh${NC}"
        exit 1
    fi
}

siguiente_ip() {
    # Buscar la siguiente IP libre en 10.0.0.x (empieza en .2)
    for i in $(seq 2 254); do
        if ! grep -q "AllowedIPs = ${VPN_SUBNET}.${i}/32" "$WG_CONF" 2>/dev/null; then
            echo "${VPN_SUBNET}.${i}"
            return
        fi
    done
    echo ""
}

# ============================================================
# AÑADIR USUARIO
# ============================================================

anadir_usuario() {
    echo -e "\n${CYAN}=== AÑADIR USUARIO ===${NC}"
    read -p "Nombre del usuario: " NOMBRE
    NOMBRE=$(echo "$NOMBRE" | tr ' ' '_' | tr -cd '[:alnum:]_-')

    if grep -q "# cliente: $NOMBRE" "$WG_CONF" 2>/dev/null; then
        echo -e "${RED}[ERROR] Ya existe un usuario con ese nombre.${NC}"
        return
    fi

    # Generar claves
    PRIV=$(wg genkey)
    PUB=$(echo "$PRIV" | wg pubkey)

    # Asignar IP
    IP=$(siguiente_ip)
    if [[ -z "$IP" ]]; then
        echo -e "${RED}[ERROR] No hay IPs disponibles.${NC}"
        return
    fi

    # Añadir peer al servidor
    echo "" >> "$WG_CONF"
    echo "# cliente: $NOMBRE" >> "$WG_CONF"
    echo "[Peer]" >> "$WG_CONF"
    echo "PublicKey = $PUB" >> "$WG_CONF"
    echo "AllowedIPs = $IP/32" >> "$WG_CONF"

    # Aplicar en caliente sin reiniciar
    wg set "$WG_IFACE" peer "$PUB" allowed-ips "$IP/32"

    # Crear carpeta de configs
    mkdir -p "$CONFIGS_DIR"

    # Generar archivo .conf para el cliente
    CONFIG_FILE="$CONFIGS_DIR/${NOMBRE}.conf"
    cat > "$CONFIG_FILE" << EOF
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0
Endpoint = $SERVER_IP:$SERVER_PORT
PersistentKeepalive = 25
EOF

    chmod 600 "$CONFIG_FILE"

    echo -e "${GREEN}[OK] Usuario '$NOMBRE' añadido con IP $IP${NC}"
    echo -e "${YELLOW}Config guardada en: $CONFIG_FILE${NC}"
    echo ""
    echo -e "${CYAN}--- Contenido del .conf para enviarle ---${NC}"
    cat "$CONFIG_FILE"
    echo -e "${CYAN}-----------------------------------------${NC}"
}

# ============================================================
# ELIMINAR USUARIO
# ============================================================

eliminar_usuario() {
    echo -e "\n${CYAN}=== ELIMINAR USUARIO ===${NC}"
    listar_usuarios_simple
    read -p "Nombre del usuario a eliminar: " NOMBRE
    NOMBRE=$(echo "$NOMBRE" | tr ' ' '_' | tr -cd '[:alnum:]_-')

    if ! grep -q "# cliente: $NOMBRE" "$WG_CONF" 2>/dev/null; then
        echo -e "${RED}[ERROR] No existe el usuario '$NOMBRE'.${NC}"
        return
    fi

    # Obtener clave pública del usuario
    PUB=$(grep -A2 "# cliente: $NOMBRE" "$WG_CONF" | grep "PublicKey" | awk '{print $3}')

    # Eliminar del archivo de config (bloque de 3 líneas + comentario)
    sed -i "/# cliente: $NOMBRE/,/AllowedIPs = .*\/32/{/# cliente: $NOMBRE/d;/\[Peer\]/d;/PublicKey/d;/AllowedIPs/d}" "$WG_CONF"
    # Limpiar líneas vacías dobles
    sed -i '/^$/N;/^\n$/d' "$WG_CONF"

    # Eliminar peer en caliente
    wg set "$WG_IFACE" peer "$PUB" remove 2>/dev/null

    # Eliminar config del cliente
    rm -f "$CONFIGS_DIR/${NOMBRE}.conf"

    echo -e "${GREEN}[OK] Usuario '$NOMBRE' eliminado.${NC}"
}

# ============================================================
# LISTAR USUARIOS
# ============================================================

listar_usuarios_simple() {
    echo -e "\n${CYAN}Usuarios configurados:${NC}"
    grep "# cliente:" "$WG_CONF" 2>/dev/null | sed 's/# cliente: /  - /' || echo "  (ninguno)"
}

listar_usuarios() {
    echo -e "\n${CYAN}=== USUARIOS VPN ===${NC}"
    echo ""

    CLIENTES=$(grep "# cliente:" "$WG_CONF" 2>/dev/null | sed 's/# cliente: //')

    if [[ -z "$CLIENTES" ]]; then
        echo "  No hay usuarios configurados."
        return
    fi

    while IFS= read -r NOMBRE; do
        PUB=$(grep -A2 "# cliente: $NOMBRE" "$WG_CONF" | grep "PublicKey" | awk '{print $3}')
        IP=$(grep -A3 "# cliente: $NOMBRE" "$WG_CONF" | grep "AllowedIPs" | awk '{print $3}' | cut -d'/' -f1)

        # Ver si está conectado actualmente
        HANDSHAKE=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | grep "$PUB" | awk '{print $2}')
        if [[ -n "$HANDSHAKE" && "$HANDSHAKE" -gt 0 ]]; then
            HACE=$(( $(date +%s) - HANDSHAKE ))
            if [[ $HACE -lt 180 ]]; then
                ESTADO="${GREEN}● Conectado${NC} (hace ${HACE}s)"
            else
                ESTADO="${YELLOW}○ Inactivo${NC} (último: hace ${HACE}s)"
            fi
        else
            ESTADO="${RED}○ Nunca conectado${NC}"
        fi

        echo -e "  ${BLUE}$NOMBRE${NC} — IP: $IP — $ESTADO"
    done <<< "$CLIENTES"
    echo ""
}

# ============================================================
# VER CONFIG DE UN USUARIO
# ============================================================

ver_config() {
    echo -e "\n${CYAN}=== VER CONFIG DE USUARIO ===${NC}"
    listar_usuarios_simple
    read -p "Nombre del usuario: " NOMBRE
    NOMBRE=$(echo "$NOMBRE" | tr ' ' '_' | tr -cd '[:alnum:]_-')

    CONFIG_FILE="$CONFIGS_DIR/${NOMBRE}.conf"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[ERROR] No se encontró el archivo de config para '$NOMBRE'.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- Config de $NOMBRE ---${NC}"
    cat "$CONFIG_FILE"
    echo -e "${CYAN}------------------------${NC}"
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

menu() {
    while true; do
        echo ""
        echo -e "${CYAN}╔══════════════════════════════╗${NC}"
        echo -e "${CYAN}║     WireGuard Manager VPN    ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════╝${NC}"
        echo -e "  ${GREEN}1)${NC} Añadir usuario"
        echo -e "  ${RED}2)${NC} Eliminar usuario"
        echo -e "  ${BLUE}3)${NC} Listar usuarios y estado"
        echo -e "  ${YELLOW}4)${NC} Ver config de un usuario"
        echo -e "  ${NC}5) Salir"
        echo ""
        read -p "Opción: " OPT

        case $OPT in
            1) anadir_usuario ;;
            2) eliminar_usuario ;;
            3) listar_usuarios ;;
            4) ver_config ;;
            5) echo -e "${GREEN}Hasta luego.${NC}"; exit 0 ;;
            *) echo -e "${RED}Opción inválida.${NC}" ;;
        esac
    done
}

check_root
menu
