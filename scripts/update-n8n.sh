#!/usr/bin/env bash
# =============================================================================
# update-n8n.sh — Actualiza n8n via Docker Compose con backup previo de flujos
# =============================================================================
# Uso:  ./update-n8n.sh
# No requiere rutas hardcodeadas. Detecta automáticamente su ubicación.
# Compatible con Docker Compose v1 y v2, Git Bash/WSL/Linux.
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_title() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}\n"
}

# ─── 1. Autodetección del directorio del script ───────────────────────────────
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"

log_title "Actualizador de n8n — Docker Compose"
log_info "Directorio detectado: ${SCRIPT_DIR}"

# ─── 2. Verificar docker-compose.yml ─────────────────────────────────────────
if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log_error "No se encontró 'docker-compose.yml' en: ${SCRIPT_DIR}"
    log_error "Asegúrate de que este script esté en la misma carpeta que tu docker-compose.yml."
    exit 1
fi
log_ok "Archivo docker-compose.yml encontrado."

# ─── 3. Detectar servicio n8n + container_name ───────────────────────────────
# El parser awk recorre el bloque services: nivel a nivel.
# Identifica el servicio cuya image: contiene "n8n" pero no "runner",
# y luego extrae su container_name si está definido.

N8N_SERVICE=$(awk '
    /^services:/ { in_services=1; next }
    in_services && /^  [a-zA-Z0-9_-]+:/ {
        current = $0
        gsub(/^[[:space:]]+|:[[:space:]]*$/, "", current)
    }
    in_services && /^    image:/ && /n8n/ && !/runner/ {
        print current; exit
    }
' "${COMPOSE_FILE}" || true)

# Fallback: nombre de servicio literal "n8n"
if [[ -z "${N8N_SERVICE}" ]]; then
    N8N_SERVICE=$(awk '
        /^services:/ { in_services=1; next }
        in_services && /^  [a-zA-Z0-9_-]+:/ {
            svc = $0; gsub(/^[[:space:]]+|:[[:space:]]*$/, "", svc)
            if (svc == "n8n") { print svc; exit }
        }
    ' "${COMPOSE_FILE}" || true)
fi

if [[ -z "${N8N_SERVICE}" ]]; then
    log_warn "No se pudo detectar el servicio n8n automáticamente. Usando 'n8n' por defecto."
    N8N_SERVICE="n8n"
fi
log_info "Servicio n8n detectado: ${N8N_SERVICE}"

# Leer container_name del servicio n8n para usar con docker inspect/cp
N8N_CONTAINER_NAME=$(awk -v svc="${N8N_SERVICE}" '
    /^services:/ { in_services=1; next }
    in_services && /^  [a-zA-Z0-9_-]+:/ {
        cur = $0; gsub(/^[[:space:]]+|:[[:space:]]*$/, "", cur)
        in_target = (cur == svc)
    }
    in_target && /^    container_name:/ {
        val = $0; gsub(/^[[:space:]]*container_name:[[:space:]]*/, "", val)
        print val; exit
    }
' "${COMPOSE_FILE}" || true)

N8N_CONTAINER="${N8N_CONTAINER_NAME:-${N8N_SERVICE}}"
log_info "Container name: ${N8N_CONTAINER}"

# ─── 4. Detectar servicio runner ─────────────────────────────────────────────
N8N_RUNNER=$(awk '
    /^services:/ { in_services=1; next }
    in_services && /^  [a-zA-Z0-9_-]+:/ {
        current = $0; gsub(/^[[:space:]]+|:[[:space:]]*$/, "", current)
    }
    in_services && /^    image:/ && /runner/ { print current; exit }
' "${COMPOSE_FILE}" || true)

if [[ -n "${N8N_RUNNER}" ]]; then
    log_info "Servicio runner detectado: ${N8N_RUNNER}"
    SERVICES_TO_UPDATE="${N8N_SERVICE} ${N8N_RUNNER}"
else
    SERVICES_TO_UPDATE="${N8N_SERVICE}"
fi

# ─── 5. Verificar Docker y Compose ───────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_error "Docker no está instalado o no se encuentra en el PATH."
    exit 1
fi

if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_error "No se encontró 'docker compose' ni 'docker-compose'. Instala Docker Compose."
    exit 1
fi
log_info "Comando Compose: ${COMPOSE_CMD}"

# ─── 6. Directorio de backups ─────────────────────────────────────────────────
BACKUP_DIR="${PROJECT_ROOT}/backups"
mkdir -p "${BACKUP_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/n8n_flows_backup_${TIMESTAMP}.json"

# ─── 7. Exportar flujos (backup) ─────────────────────────────────────────────
log_title "Paso 1/3 — Exportando flujos de n8n"

# Usar docker inspect por container_name: funciona en Linux, WSL y Git Bash
CONTAINER_RUNNING=$(docker inspect --format='{{.State.Running}}' "${N8N_CONTAINER}" 2>/dev/null || echo "false")

if [[ "${CONTAINER_RUNNING}" != "true" ]]; then
    log_warn "El contenedor '${N8N_CONTAINER}' no está en ejecución. Se omite el backup."
else
    log_info "Exportando todos los flujos a: ${BACKUP_FILE}"

    # NOTA: --backup ignora --output y guarda en ~/.n8n/backups/ (ruta fija de n8n).
    # Se usa --all --output con nombre relativo para evitar que Git Bash (MINGW64)
    # convierta rutas absolutas Linux (/tmp/...) a rutas Windows (C:/Program Files/Git/...).
    # Con nombre relativo, n8n escribe en su CWD (/home/node) dentro del contenedor.
    EXPORT_FILENAME="n8n_export_${TIMESTAMP}.json"

    if docker exec "${N8N_CONTAINER}" \
        n8n export:workflow --all --output="${EXPORT_FILENAME}"; then
        # docker cp recibe la ruta del contenedor como argumento post-":", no la interpola Git Bash
        docker cp "${N8N_CONTAINER}://home/node/${EXPORT_FILENAME}" "${BACKUP_FILE}"
        docker exec "${N8N_CONTAINER}" rm -f "${EXPORT_FILENAME}" 2>/dev/null || true
        log_ok "Backup guardado en: ${BACKUP_FILE}"
    else
        log_warn "No se pudieron exportar los flujos (no hay flujos o error en n8n)."
        log_warn "Continuando sin backup..."
    fi
fi

# ─── 8. Pull de nuevas imágenes ───────────────────────────────────────────────
log_title "Paso 2/3 — Descargando imágenes actualizadas"
log_info "Servicios: ${SERVICES_TO_UPDATE}"
# shellcheck disable=SC2086
${COMPOSE_CMD} -f "${COMPOSE_FILE}" pull ${SERVICES_TO_UPDATE}
log_ok "Imágenes descargadas correctamente."

# ─── 9. Recrear contenedores ─────────────────────────────────────────────────
log_title "Paso 3/3 — Reiniciando contenedores"
log_info "Ejecutando: ${COMPOSE_CMD} up -d ${SERVICES_TO_UPDATE}"
# shellcheck disable=SC2086
${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d ${SERVICES_TO_UPDATE}
log_ok "Contenedores reiniciados con la nueva versión."

# ─── 10. Verificación final ───────────────────────────────────────────────────
echo ""
log_info "Esperando 5 segundos para que n8n arranque..."
sleep 5

RUNNING_CHECK=$(docker inspect --format='{{.State.Running}}' "${N8N_CONTAINER}" 2>/dev/null || echo "false")
if [[ "${RUNNING_CHECK}" == "true" ]]; then
    N8N_VER=$(docker exec "${N8N_CONTAINER}" n8n --version 2>/dev/null || echo "N/D")
    log_ok "n8n está corriendo. Versión instalada: ${N8N_VER}"
else
    log_warn "El contenedor no está en estado 'running'. Revisa con: docker ps"
fi

# ─── 11. Limpieza de imágenes antiguas (opcional) ────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}¿Eliminar imágenes Docker antiguas (dangling)?${RESET} [s/N]: ")" CLEAN_IMAGES
if [[ "${CLEAN_IMAGES,,}" == "s" ]]; then
    docker image prune -f
    log_ok "Imágenes antiguas eliminadas."
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}✔ Actualización completada.${RESET}"
[[ -f "${BACKUP_FILE}" ]] && echo -e "  Backup: ${BACKUP_FILE}"
echo -e "  Logs:   docker logs -f ${N8N_CONTAINER}"
echo ""