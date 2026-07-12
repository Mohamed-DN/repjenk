#!/bin/bash
###############################################################################
# oci_bucket_ops.sh — Operazioni OCI Object Storage
# Progetto: ENI Oracle Data Pump Automation Pipeline
#
# Utilizzo:
#   oci_bucket_ops.sh <action> [options...]
#
# Azioni:
#   upload    <local_path> <bucket> <object_name>
#   download  <bucket> <object_name> <local_path>
#   list      <bucket> [prefix]
#   delete    <bucket> <object_name>
#   size      <bucket> <object_name>
#   exists    <bucket> <object_name>
#   cleanup   <bucket> <prefix> <retention_days>
#
# Variabili d'ambiente:
#   OCI_NAMESPACE          — Namespace OCI (auto-detect se non specificato)
#   OCI_REGION             — Regione OCI (default: eu-milan-1)
#   OCI_PROFILE            — Profilo CLI OCI (default: DEFAULT)
#   OCI_CONFIG_FILE        — Percorso config OCI CLI
#   MAX_RETRIES            — Numero massimo tentativi (default: 3)
#   RETRY_DELAY            — Ritardo base in secondi (default: 5)
#   MULTIPART_THRESHOLD_MB — Soglia multipart in MB (default: 100)
#   MULTIPART_PART_SIZE_MB — Dimensione parte multipart in MB (default: 128)
#
# Output: JSON su stdout per integrazione pipeline
#
# Codici di uscita:
#   0 = Successo
#   1 = Errore operativo
#   2 = Errore parametri
###############################################################################
set -o pipefail

# ===========================================================================
# Costanti
# ===========================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_REGION="eu-milan-1"
readonly DEFAULT_MAX_RETRIES=3
readonly DEFAULT_RETRY_DELAY=5
readonly DEFAULT_MULTIPART_THRESHOLD_MB=100
readonly DEFAULT_MULTIPART_PART_SIZE_MB=128

# Colori
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ===========================================================================
# Variabili configurazione
# ===========================================================================
OCI_REGION="${OCI_REGION:-${DEFAULT_REGION}}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
MAX_RETRIES="${MAX_RETRIES:-${DEFAULT_MAX_RETRIES}}"
RETRY_DELAY="${RETRY_DELAY:-${DEFAULT_RETRY_DELAY}}"
MULTIPART_THRESHOLD_MB="${MULTIPART_THRESHOLD_MB:-${DEFAULT_MULTIPART_THRESHOLD_MB}}"
MULTIPART_PART_SIZE_MB="${MULTIPART_PART_SIZE_MB:-${DEFAULT_MULTIPART_PART_SIZE_MB}}"

# ===========================================================================
# Funzioni di utilità
# ===========================================================================

log_info()  { echo -e "${GREEN}[INFO]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# Emette JSON risultato su stdout
emit_json() {
    local status="$1"
    local message="$2"
    local data="${3:-{}}"
    echo "{\"status\":\"${status}\",\"message\":\"${message}\",\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"data\":${data}}"
}

usage() {
    cat >&2 <<EOF
Utilizzo: ${SCRIPT_NAME} <action> [options...]

Azioni disponibili:
  upload    <local_path> <bucket> <object_name>    — Carica file nel bucket
  download  <bucket> <object_name> <local_path>    — Scarica file dal bucket
  list      <bucket> [prefix]                      — Elenca oggetti nel bucket
  delete    <bucket> <object_name>                 — Elimina oggetto dal bucket
  size      <bucket> <object_name>                 — Dimensione oggetto
  exists    <bucket> <object_name>                 — Verifica esistenza oggetto
  cleanup   <bucket> <prefix> <retention_days>     — Elimina oggetti scaduti

Variabili d'ambiente:
  OCI_NAMESPACE, OCI_REGION, OCI_PROFILE, OCI_CONFIG_FILE
  MAX_RETRIES, RETRY_DELAY, MULTIPART_THRESHOLD_MB, MULTIPART_PART_SIZE_MB
EOF
    exit 2
}

# Costruisce gli argomenti comuni per OCI CLI
build_oci_args() {
    local args="--region ${OCI_REGION} --profile ${OCI_PROFILE}"
    [[ -n "${OCI_CONFIG_FILE:-}" ]] && args+=" --config-file ${OCI_CONFIG_FILE}"
    echo "${args}"
}

# ===========================================================================
# Auto-detect namespace OCI
# ===========================================================================
detect_namespace() {
    if [[ -n "${OCI_NAMESPACE:-}" ]]; then
        log_debug "Namespace OCI fornito: ${OCI_NAMESPACE}"
        return 0
    fi

    log_info "Auto-detect namespace OCI..."
    local oci_args
    oci_args="$(build_oci_args)"

    local ns_output
    ns_output=$(eval oci os ns get ${oci_args} --output json 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_error "Impossibile determinare il namespace OCI. Verificare configurazione CLI."
        return 1
    fi

    OCI_NAMESPACE=$(echo "${ns_output}" | grep -o '"data"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    if [[ -z "${OCI_NAMESPACE}" ]]; then
        # Fallback con python/jq
        if command -v jq &>/dev/null; then
            OCI_NAMESPACE=$(echo "${ns_output}" | jq -r '.data')
        elif command -v python3 &>/dev/null; then
            OCI_NAMESPACE=$(echo "${ns_output}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
        fi
    fi

    if [[ -z "${OCI_NAMESPACE}" ]]; then
        log_error "Impossibile estrarre il namespace dalla risposta OCI."
        return 1
    fi

    log_info "Namespace OCI rilevato: ${OCI_NAMESPACE}"
    export OCI_NAMESPACE
    return 0
}

# ===========================================================================
# Retry con backoff esponenziale
# ===========================================================================
retry_with_backoff() {
    local description="$1"
    shift
    local cmd=("$@")

    local attempt=0
    local delay="${RETRY_DELAY}"

    while [[ ${attempt} -lt ${MAX_RETRIES} ]]; do
        ((attempt++))
        log_debug "Tentativo ${attempt}/${MAX_RETRIES}: ${description}"

        local output
        output=$(eval "${cmd[*]}" 2>&1)
        local exit_code=$?

        if [[ ${exit_code} -eq 0 ]]; then
            echo "${output}"
            return 0
        fi

        # Errore non recuperabile (es. 404 Not Found, parametri errati)
        if echo "${output}" | grep -qi "BucketNotFound\|ObjectNotFound\|InvalidParameter\|AuthorizationFailed"; then
            log_error "Errore non recuperabile: ${output}"
            echo "${output}"
            return 1
        fi

        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            log_warn "Tentativo ${attempt} fallito per '${description}'. Attesa ${delay}s prima del prossimo tentativo..."
            sleep "${delay}"
            # Backoff esponenziale con jitter
            delay=$(( delay * 2 + RANDOM % 5 ))
        else
            log_error "Tutti i ${MAX_RETRIES} tentativi falliti per '${description}'."
            echo "${output}"
            return 1
        fi
    done

    return 1
}

# ===========================================================================
# Operazione: UPLOAD
# ===========================================================================
do_upload() {
    local local_path="$1"
    local bucket="$2"
    local object_name="$3"

    if [[ -z "${local_path}" || -z "${bucket}" || -z "${object_name}" ]]; then
        log_error "Parametri mancanti per upload. Utilizzo: upload <local_path> <bucket> <object_name>"
        exit 2
    fi

    if [[ ! -f "${local_path}" ]]; then
        log_error "File non trovato: ${local_path}"
        emit_json "error" "File non trovato: ${local_path}"
        return 1
    fi

    detect_namespace || return 1

    # Calcolo dimensione file in MB
    local file_size_bytes
    file_size_bytes=$(stat -c%s "${local_path}" 2>/dev/null || stat -f%z "${local_path}" 2>/dev/null)
    local file_size_mb=$(( file_size_bytes / 1048576 ))

    log_info "Upload: ${local_path} → ${bucket}/${object_name} (${file_size_mb} MB)"

    local oci_args
    oci_args="$(build_oci_args)"
    local result

    if [[ ${file_size_mb} -ge ${MULTIPART_THRESHOLD_MB} ]]; then
        # ===== Upload multipart per file grandi =====
        log_info "File grande rilevato (${file_size_mb} MB >= ${MULTIPART_THRESHOLD_MB} MB). Upload multipart..."
        local part_size=$(( MULTIPART_PART_SIZE_MB * 1048576 ))

        result=$(retry_with_backoff "multipart upload ${object_name}" \
            "oci os object put ${oci_args} \
                --namespace-name '${OCI_NAMESPACE}' \
                --bucket-name '${bucket}' \
                --name '${object_name}' \
                --file '${local_path}' \
                --part-size ${part_size} \
                --parallel-upload-count 3 \
                --force \
                --output json")
    else
        # ===== Upload standard =====
        result=$(retry_with_backoff "upload ${object_name}" \
            "oci os object put ${oci_args} \
                --namespace-name '${OCI_NAMESPACE}' \
                --bucket-name '${bucket}' \
                --name '${object_name}' \
                --file '${local_path}' \
                --force \
                --output json")
    fi

    if [[ $? -eq 0 ]]; then
        log_info "Upload completato con successo: ${object_name}"
        emit_json "success" "Upload completato" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"size_mb\":${file_size_mb}}"
        return 0
    else
        log_error "Upload fallito: ${object_name}"
        emit_json "error" "Upload fallito" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"error\":\"${result}\"}"
        return 1
    fi
}

# ===========================================================================
# Operazione: DOWNLOAD
# ===========================================================================
do_download() {
    local bucket="$1"
    local object_name="$2"
    local local_path="$3"

    if [[ -z "${bucket}" || -z "${object_name}" || -z "${local_path}" ]]; then
        log_error "Parametri mancanti per download. Utilizzo: download <bucket> <object_name> <local_path>"
        exit 2
    fi

    detect_namespace || return 1

    # Crea directory di destinazione se non esiste
    local dest_dir
    dest_dir="$(dirname "${local_path}")"
    mkdir -p "${dest_dir}" 2>/dev/null

    log_info "Download: ${bucket}/${object_name} → ${local_path}"

    local oci_args
    oci_args="$(build_oci_args)"

    local result
    result=$(retry_with_backoff "download ${object_name}" \
        "oci os object get ${oci_args} \
            --namespace-name '${OCI_NAMESPACE}' \
            --bucket-name '${bucket}' \
            --name '${object_name}' \
            --file '${local_path}' \
            --output json")

    if [[ $? -eq 0 ]]; then
        local downloaded_size=0
        if [[ -f "${local_path}" ]]; then
            downloaded_size=$(stat -c%s "${local_path}" 2>/dev/null || stat -f%z "${local_path}" 2>/dev/null)
        fi
        log_info "Download completato: ${local_path} (${downloaded_size} bytes)"
        emit_json "success" "Download completato" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"local_path\":\"${local_path}\",\"size_bytes\":${downloaded_size}}"
        return 0
    else
        log_error "Download fallito: ${object_name}"
        emit_json "error" "Download fallito" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"error\":\"${result}\"}"
        return 1
    fi
}

# ===========================================================================
# Operazione: LIST
# ===========================================================================
do_list() {
    local bucket="$1"
    local prefix="${2:-}"

    if [[ -z "${bucket}" ]]; then
        log_error "Parametro mancante: bucket. Utilizzo: list <bucket> [prefix]"
        exit 2
    fi

    detect_namespace || return 1

    log_info "Elenco oggetti: ${bucket}/${prefix:-*}"

    local oci_args
    oci_args="$(build_oci_args)"
    local cmd="oci os object list ${oci_args} \
        --namespace-name '${OCI_NAMESPACE}' \
        --bucket-name '${bucket}' \
        --output json \
        --all"

    [[ -n "${prefix}" ]] && cmd+=" --prefix '${prefix}'"

    local result
    result=$(retry_with_backoff "list ${bucket}" "${cmd}")

    if [[ $? -eq 0 ]]; then
        log_info "Elenco recuperato con successo."
        # Output JSON diretto per integrazione
        echo "${result}"
        return 0
    else
        log_error "Elenco fallito per bucket: ${bucket}"
        emit_json "error" "Elenco fallito" "{\"bucket\":\"${bucket}\",\"error\":\"${result}\"}"
        return 1
    fi
}

# ===========================================================================
# Operazione: DELETE
# ===========================================================================
do_delete() {
    local bucket="$1"
    local object_name="$2"

    if [[ -z "${bucket}" || -z "${object_name}" ]]; then
        log_error "Parametri mancanti per delete. Utilizzo: delete <bucket> <object_name>"
        exit 2
    fi

    detect_namespace || return 1

    log_info "Eliminazione: ${bucket}/${object_name}"

    local oci_args
    oci_args="$(build_oci_args)"

    local result
    result=$(retry_with_backoff "delete ${object_name}" \
        "oci os object delete ${oci_args} \
            --namespace-name '${OCI_NAMESPACE}' \
            --bucket-name '${bucket}' \
            --name '${object_name}' \
            --force \
            --output json")

    if [[ $? -eq 0 ]]; then
        log_info "Oggetto eliminato: ${object_name}"
        emit_json "success" "Oggetto eliminato" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\"}"
        return 0
    else
        log_error "Eliminazione fallita: ${object_name}"
        emit_json "error" "Eliminazione fallita" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"error\":\"${result}\"}"
        return 1
    fi
}

# ===========================================================================
# Operazione: SIZE
# ===========================================================================
do_size() {
    local bucket="$1"
    local object_name="$2"

    if [[ -z "${bucket}" || -z "${object_name}" ]]; then
        log_error "Parametri mancanti per size. Utilizzo: size <bucket> <object_name>"
        exit 2
    fi

    detect_namespace || return 1

    log_info "Dimensione oggetto: ${bucket}/${object_name}"

    local oci_args
    oci_args="$(build_oci_args)"

    local result
    result=$(retry_with_backoff "head ${object_name}" \
        "oci os object head ${oci_args} \
            --namespace-name '${OCI_NAMESPACE}' \
            --bucket-name '${bucket}' \
            --name '${object_name}' \
            --output json")

    if [[ $? -eq 0 ]]; then
        local size_bytes=""
        if command -v jq &>/dev/null; then
            size_bytes=$(echo "${result}" | jq -r '.["content-length"] // .data["content-length"] // "unknown"')
        elif command -v python3 &>/dev/null; then
            size_bytes=$(echo "${result}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('content-length', d.get('data', {}).get('content-length', 'unknown')))" 2>/dev/null)
        else
            size_bytes=$(echo "${result}" | grep -o '"content-length"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')
        fi

        local size_mb="unknown"
        if [[ "${size_bytes}" =~ ^[0-9]+$ ]]; then
            size_mb=$(( size_bytes / 1048576 ))
        fi

        log_info "Dimensione: ${size_bytes} bytes (${size_mb} MB)"
        emit_json "success" "Dimensione recuperata" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"size_bytes\":${size_bytes:-0},\"size_mb\":${size_mb:-0}}"
        return 0
    else
        log_error "Impossibile ottenere dimensione per: ${object_name}"
        emit_json "error" "Dimensione non disponibile" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"error\":\"${result}\"}"
        return 1
    fi
}

# ===========================================================================
# Operazione: EXISTS
# ===========================================================================
do_exists() {
    local bucket="$1"
    local object_name="$2"

    if [[ -z "${bucket}" || -z "${object_name}" ]]; then
        log_error "Parametri mancanti per exists. Utilizzo: exists <bucket> <object_name>"
        exit 2
    fi

    detect_namespace || return 1

    log_debug "Verifica esistenza: ${bucket}/${object_name}"

    local oci_args
    oci_args="$(build_oci_args)"

    local result
    result=$(oci os object head ${oci_args} \
        --namespace-name "${OCI_NAMESPACE}" \
        --bucket-name "${bucket}" \
        --name "${object_name}" \
        --output json 2>&1)
    local exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        log_info "Oggetto ESISTE: ${bucket}/${object_name}"
        emit_json "success" "Oggetto esiste" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"exists\":true}"
        return 0
    else
        log_info "Oggetto NON ESISTE: ${bucket}/${object_name}"
        emit_json "success" "Oggetto non esiste" \
            "{\"bucket\":\"${bucket}\",\"object\":\"${object_name}\",\"exists\":false}"
        return 1
    fi
}

# ===========================================================================
# Operazione: CLEANUP (eliminazione oggetti scaduti)
# ===========================================================================
do_cleanup() {
    local bucket="$1"
    local prefix="$2"
    local retention_days="$3"

    if [[ -z "${bucket}" || -z "${prefix}" || -z "${retention_days}" ]]; then
        log_error "Parametri mancanti per cleanup. Utilizzo: cleanup <bucket> <prefix> <retention_days>"
        exit 2
    fi

    if ! [[ "${retention_days}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "retention_days deve essere un intero positivo: '${retention_days}'"
        exit 2
    fi

    detect_namespace || return 1

    log_info "Cleanup: bucket=${bucket}, prefix=${prefix}, retention=${retention_days} giorni"

    local oci_args
    oci_args="$(build_oci_args)"

    # Calcolo cutoff date
    local cutoff_epoch
    if date --version &>/dev/null 2>&1; then
        # GNU date
        cutoff_epoch=$(date -d "-${retention_days} days" +%s)
    else
        # BSD date (macOS)
        cutoff_epoch=$(date -v-${retention_days}d +%s)
    fi
    local cutoff_date
    cutoff_date=$(date -d "@${cutoff_epoch}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
                  date -r "${cutoff_epoch}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

    log_info "Cutoff date: ${cutoff_date}"

    # Elenca oggetti con prefisso
    local list_output
    list_output=$(oci os object list ${oci_args} \
        --namespace-name "${OCI_NAMESPACE}" \
        --bucket-name "${bucket}" \
        --prefix "${prefix}" \
        --output json \
        --all 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Impossibile elencare oggetti per cleanup."
        emit_json "error" "Elenco fallito per cleanup" "{\"bucket\":\"${bucket}\",\"error\":\"${list_output}\"}"
        return 1
    fi

    # Analisi e eliminazione oggetti scaduti
    local deleted_count=0
    local skipped_count=0
    local error_count=0

    # Estrai lista oggetti con data di creazione
    local objects_info
    if command -v jq &>/dev/null; then
        objects_info=$(echo "${list_output}" | jq -r '.data[] | "\(.name)|\(.["time-created"])"' 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        objects_info=$(echo "${list_output}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for obj in data.get('data', []):
    print(f'{obj[\"name\"]}|{obj.get(\"time-created\", \"\")}')
" 2>/dev/null)
    else
        log_error "Necessario jq o python3 per operazione cleanup."
        emit_json "error" "Dipendenze mancanti" "{\"required\":\"jq or python3\"}"
        return 1
    fi

    while IFS='|' read -r obj_name obj_time; do
        [[ -z "${obj_name}" ]] && continue

        # Confronta data oggetto con cutoff
        local obj_epoch
        # Converti ISO timestamp in epoch
        obj_epoch=$(date -d "${obj_time}" +%s 2>/dev/null || \
                    date -j -f "%Y-%m-%dT%H:%M:%S" "${obj_time%%.*}" +%s 2>/dev/null || echo "0")

        if [[ ${obj_epoch} -lt ${cutoff_epoch} && ${obj_epoch} -gt 0 ]]; then
            log_info "Eliminazione oggetto scaduto: ${obj_name} (creato: ${obj_time})"
            local del_result
            del_result=$(oci os object delete ${oci_args} \
                --namespace-name "${OCI_NAMESPACE}" \
                --bucket-name "${bucket}" \
                --name "${obj_name}" \
                --force 2>&1)

            if [[ $? -eq 0 ]]; then
                ((deleted_count++))
            else
                log_warn "Errore eliminazione: ${obj_name}: ${del_result}"
                ((error_count++))
            fi
        else
            ((skipped_count++))
            log_debug "Oggetto ancora valido: ${obj_name}"
        fi
    done <<< "${objects_info}"

    log_info "Cleanup completato: eliminati=${deleted_count}, mantenuti=${skipped_count}, errori=${error_count}"
    emit_json "success" "Cleanup completato" \
        "{\"bucket\":\"${bucket}\",\"prefix\":\"${prefix}\",\"retention_days\":${retention_days},\"deleted\":${deleted_count},\"skipped\":${skipped_count},\"errors\":${error_count}}"

    [[ ${error_count} -gt 0 ]] && return 1
    return 0
}

# ===========================================================================
# Main — Dispatcher azioni
# ===========================================================================
main() {
    if [[ $# -lt 1 ]]; then
        log_error "Nessuna azione specificata."
        usage
    fi

    # Verifica disponibilità OCI CLI
    if ! command -v oci &>/dev/null; then
        log_error "OCI CLI non trovato nel PATH. Installare: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
        emit_json "error" "OCI CLI non disponibile"
        exit 1
    fi

    local action="${1,,}" # Converti in lowercase
    shift

    case "${action}" in
        upload)   do_upload   "$@" ;;
        download) do_download "$@" ;;
        list)     do_list     "$@" ;;
        delete)   do_delete   "$@" ;;
        size)     do_size     "$@" ;;
        exists)   do_exists   "$@" ;;
        cleanup)  do_cleanup  "$@" ;;
        *)
            log_error "Azione sconosciuta: '${action}'"
            usage
            ;;
    esac

    exit $?
}

main "$@"
