#!/bin/bash
###############################################################################
# run_impdp.sh — Wrapper per Oracle Data Pump Import (impdp)
# Progetto: M-DN Oracle Data Pump Automation Pipeline
# Ambiente: DBCS / VM (NON Autonomous Database)
#
# Utilizzo:
#   run_impdp.sh <connect_string> <schema> <dump_dir> <dump_file> [options...]
#
# Variabili d'ambiente opzionali:
#   PARALLEL=4                                         — Grado di parallelismo
#   CONTENT=ALL|DATA_ONLY|METADATA_ONLY                — Contenuto dell'import
#   TABLE_EXISTS_ACTION=SKIP|REPLACE|APPEND|TRUNCATE   — Azione tabelle esistenti
#   REMAP_SCHEMA=OLD_SCHEMA:NEW_SCHEMA                 — Remap dello schema
#   REMAP_TABLESPACE=OLD_TS:NEW_TS                     — Remap del tablespace
#   REMAP_TABLE=OLD_TABLE:NEW_TABLE                    — Remap nome tabella
#   REMAP_DATAFILE=/old/path:/new/path                 — Remap percorso datafile
#   INCLUDE_GRANTS=true|false                          — Importare GRANT
#   TABLE_LIST=table1,table2                           — Tabelle specifiche
#   LOGFILE=custom_logfile.log                         — Nome log personalizzato
#   TRANSFORM_SEGMENT=true|false                       — Transform segment attributes
#   TRANSFORM_OID=true|false                           — Transform OID
#   IMPORT_TIMEOUT=28800                               — Timeout in secondi (default 8h)
#   USE_PARFILE=true                                   — Forzare l'uso di parfile
#   SQLFILE=output.sql                                 — Genera DDL senza importare
#
# Codici di uscita:
#   0 = Successo
#   1 = Warning (import completato con avvisi)
#   2 = Errore (import fallito)
###############################################################################
set -o pipefail

# ===========================================================================
# Costanti
# ===========================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DATE_STAMP="$(date +%Y%m%d)"
readonly DEFAULT_TIMEOUT=28800          # 8 ore
readonly DEFAULT_PARALLEL=4
readonly DEFAULT_CONTENT="ALL"
readonly DEFAULT_TABLE_EXISTS_ACTION="SKIP"

# Colori per output leggibile (compatibile ANSI)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ===========================================================================
# Funzioni di utilità
# ===========================================================================

log_info()    { echo -e "${GREEN}[INFO]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
    cat <<EOF
Utilizzo: ${SCRIPT_NAME} <connect_string> <schema> <dump_dir> <dump_file> [options...]

Parametri obbligatori:
  connect_string   Stringa di connessione Oracle (es. user/pwd@host:port/service)
  schema           Schema di destinazione
  dump_dir         Oracle directory object per il dump
  dump_file        Nome del file dump da importare

Variabili d'ambiente opzionali:
  PARALLEL              Grado di parallelismo (default: ${DEFAULT_PARALLEL})
  CONTENT               ALL|DATA_ONLY|METADATA_ONLY (default: ${DEFAULT_CONTENT})
  TABLE_EXISTS_ACTION   SKIP|REPLACE|APPEND|TRUNCATE (default: ${DEFAULT_TABLE_EXISTS_ACTION})
  REMAP_SCHEMA          OLD:NEW — Remap schema
  REMAP_TABLESPACE      OLD:NEW — Remap tablespace
  REMAP_TABLE           OLD:NEW — Remap tabella
  REMAP_DATAFILE        OLD:NEW — Remap percorso datafile
  INCLUDE_GRANTS        true|false (default: true)
  TABLE_LIST            Lista tabelle da importare (separatore virgola)
  LOGFILE               Nome log personalizzato
  TRANSFORM_SEGMENT     true|false — Transform segment_attributes (default: false)
  TRANSFORM_OID         true|false — Transform OID (default: false)
  IMPORT_TIMEOUT        Timeout in secondi (default: ${DEFAULT_TIMEOUT})
  USE_PARFILE           Forzare uso parfile (default: auto)
  SQLFILE               Genera DDL anziché importare

Codici di uscita:
  0 = Successo
  1 = Warning
  2 = Errore
EOF
    exit 2
}

validate_param() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" ]]; then
        log_error "Parametro obbligatorio mancante: ${name}"
        usage
    fi
}

validate_enum() {
    local name="$1"
    local value="$2"
    shift 2
    local allowed=("$@")
    local valid=false
    for v in "${allowed[@]}"; do
        if [[ "${value^^}" == "${v}" ]]; then
            valid=true
            break
        fi
    done
    if [[ "${valid}" == "false" ]]; then
        log_error "Valore non valido per ${name}: '${value}'. Valori ammessi: ${allowed[*]}"
        exit 2
    fi
}

# Validazione formato remap (deve contenere esattamente un ':')
validate_remap() {
    local name="$1"
    local value="$2"
    if [[ -n "${value}" ]]; then
        if [[ "${value}" != *":"* ]]; then
            log_error "Formato remap non valido per ${name}: '${value}'. Formato atteso: OLD:NEW"
            exit 2
        fi
        local colon_count
        colon_count=$(echo "${value}" | awk -F':' '{print NF-1}')
        if [[ "${colon_count}" -lt 1 ]]; then
            log_error "Formato remap non valido per ${name}: '${value}'. Formato atteso: OLD:NEW"
            exit 2
        fi
    fi
}

# Pulizia risorse temporanee
cleanup() {
    local exit_code=$?
    if [[ -n "${PARFILE_PATH:-}" && -f "${PARFILE_PATH}" ]]; then
        log_debug "Rimozione parfile temporaneo: ${PARFILE_PATH}"
        rm -f "${PARFILE_PATH}"
    fi
    if [[ -n "${IMPDP_PID:-}" ]] && kill -0 "${IMPDP_PID}" 2>/dev/null; then
        log_warn "Terminazione forzata del processo impdp (PID: ${IMPDP_PID})"
        kill -TERM "${IMPDP_PID}" 2>/dev/null
        sleep 5
        kill -9 "${IMPDP_PID}" 2>/dev/null
    fi
    return ${exit_code}
}
trap cleanup EXIT INT TERM

# ===========================================================================
# Validazione parametri di input
# ===========================================================================
if [[ $# -lt 4 ]]; then
    log_error "Numero insufficiente di parametri."
    usage
fi

CONNECT_STRING="$1"
SCHEMA="$2"
DUMP_DIR="$3"
DUMP_FILE="$4"
shift 4

validate_param "connect_string" "${CONNECT_STRING}"
validate_param "schema"         "${SCHEMA}"
validate_param "dump_dir"       "${DUMP_DIR}"
validate_param "dump_file"      "${DUMP_FILE}"

# ===========================================================================
# Lettura e validazione variabili d'ambiente
# ===========================================================================
PARALLEL="${PARALLEL:-${DEFAULT_PARALLEL}}"
CONTENT="${CONTENT:-${DEFAULT_CONTENT}}"
TABLE_EXISTS_ACTION="${TABLE_EXISTS_ACTION:-${DEFAULT_TABLE_EXISTS_ACTION}}"
INCLUDE_GRANTS="${INCLUDE_GRANTS:-true}"
TRANSFORM_SEGMENT="${TRANSFORM_SEGMENT:-false}"
TRANSFORM_OID="${TRANSFORM_OID:-false}"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-${DEFAULT_TIMEOUT}}"
USE_PARFILE="${USE_PARFILE:-auto}"

# Validazione enumerativi
validate_enum "CONTENT"              "${CONTENT}"              "ALL" "DATA_ONLY" "METADATA_ONLY"
validate_enum "TABLE_EXISTS_ACTION"  "${TABLE_EXISTS_ACTION}"  "SKIP" "REPLACE" "APPEND" "TRUNCATE"

# Validazione remap
validate_remap "REMAP_SCHEMA"     "${REMAP_SCHEMA:-}"
validate_remap "REMAP_TABLESPACE" "${REMAP_TABLESPACE:-}"
validate_remap "REMAP_TABLE"      "${REMAP_TABLE:-}"
validate_remap "REMAP_DATAFILE"   "${REMAP_DATAFILE:-}"

# Validazione numerici
if ! [[ "${PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "PARALLEL deve essere un intero positivo: '${PARALLEL}'"
    exit 2
fi

if ! [[ "${IMPORT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "IMPORT_TIMEOUT deve essere un intero positivo: '${IMPORT_TIMEOUT}'"
    exit 2
fi

# ===========================================================================
# Verifica prerequisiti
# ===========================================================================
log_info "============================================================"
log_info " M-DN Data Pump Import — Avvio"
log_info " Schema: ${SCHEMA}"
log_info " Dump Dir: ${DUMP_DIR}"
log_info " Dump File: ${DUMP_FILE}"
log_info " Timestamp: ${TIMESTAMP}"
log_info "============================================================"

# Verifica disponibilità impdp
if ! command -v impdp &>/dev/null; then
    if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/impdp" ]]; then
        IMPDP_BIN="${ORACLE_HOME}/bin/impdp"
        log_info "impdp trovato in ORACLE_HOME: ${IMPDP_BIN}"
    else
        log_error "impdp non trovato nel PATH e ORACLE_HOME non configurato."
        exit 2
    fi
else
    IMPDP_BIN="$(command -v impdp)"
    log_info "impdp trovato: ${IMPDP_BIN}"
fi

# ===========================================================================
# Determinazione modalità import
# ===========================================================================
IMPORT_MODE="SCHEMA"
if [[ -n "${TABLE_LIST:-}" ]]; then
    IMPORT_MODE="TABLE"
    log_info "Modalità import: TABLE (tabelle: ${TABLE_LIST})"
elif [[ -n "${SQLFILE:-}" ]]; then
    IMPORT_MODE="SQLFILE"
    log_info "Modalità import: SQLFILE (generazione DDL: ${SQLFILE})"
else
    log_info "Modalità import: SCHEMA (schema: ${SCHEMA})"
fi

# ===========================================================================
# Generazione nome logfile
# ===========================================================================
if [[ -n "${LOGFILE:-}" ]]; then
    LOG_NAME="${LOGFILE}"
else
    LOG_NAME="${SCHEMA}_import_${TIMESTAMP}.log"
fi
log_info "Log file: ${LOG_NAME}"

# ===========================================================================
# Costruzione comando impdp
# ===========================================================================
build_impdp_command() {
    local cmd_args=()

    cmd_args+=("${IMPDP_BIN}")
    cmd_args+=("\"${CONNECT_STRING}\"")

    # Schema o tabelle
    if [[ "${IMPORT_MODE}" == "TABLE" ]]; then
        local tables_with_schema=""
        IFS=',' read -ra TBL_ARRAY <<< "${TABLE_LIST}"
        for i in "${!TBL_ARRAY[@]}"; do
            local tbl="${TBL_ARRAY[$i]}"
            tbl="$(echo "${tbl}" | xargs)"
            [[ "${tbl}" != *.* ]] && tbl="${SCHEMA}.${tbl}"
            [[ $i -gt 0 ]] && tables_with_schema="${tables_with_schema},"
            tables_with_schema="${tables_with_schema}${tbl}"
        done
        cmd_args+=("TABLES=${tables_with_schema}")
    else
        # Sempre specificare lo schema di destinazione
        cmd_args+=("SCHEMAS=${SCHEMA}")
    fi

    # Directory e file
    cmd_args+=("DIRECTORY=${DUMP_DIR}")
    cmd_args+=("DUMPFILE=${DUMP_FILE}")
    cmd_args+=("LOGFILE=${LOG_NAME}")

    # Parallelismo
    [[ "${PARALLEL}" -gt 1 ]] && cmd_args+=("PARALLEL=${PARALLEL}")

    # Contenuto
    cmd_args+=("CONTENT=${CONTENT^^}")

    # Azione tabelle esistenti
    cmd_args+=("TABLE_EXISTS_ACTION=${TABLE_EXISTS_ACTION^^}")

    # ===== REMAP =====
    if [[ -n "${REMAP_SCHEMA:-}" ]]; then
        cmd_args+=("REMAP_SCHEMA=${REMAP_SCHEMA}")
        log_info "Remap schema: ${REMAP_SCHEMA}"
    fi

    if [[ -n "${REMAP_TABLESPACE:-}" ]]; then
        # Supporto multiplo: REMAP_TABLESPACE può contenere più mapping separati da ;
        IFS=';' read -ra TS_REMAPS <<< "${REMAP_TABLESPACE}"
        for ts_remap in "${TS_REMAPS[@]}"; do
            ts_remap="$(echo "${ts_remap}" | xargs)"
            [[ -n "${ts_remap}" ]] && cmd_args+=("REMAP_TABLESPACE=${ts_remap}")
        done
        log_info "Remap tablespace: ${REMAP_TABLESPACE}"
    fi

    if [[ -n "${REMAP_TABLE:-}" ]]; then
        IFS=';' read -ra TBL_REMAPS <<< "${REMAP_TABLE}"
        for tbl_remap in "${TBL_REMAPS[@]}"; do
            tbl_remap="$(echo "${tbl_remap}" | xargs)"
            [[ -n "${tbl_remap}" ]] && cmd_args+=("REMAP_TABLE=${tbl_remap}")
        done
        log_info "Remap tabella: ${REMAP_TABLE}"
    fi

    if [[ -n "${REMAP_DATAFILE:-}" ]]; then
        cmd_args+=("REMAP_DATAFILE=${REMAP_DATAFILE}")
        log_info "Remap datafile: ${REMAP_DATAFILE}"
    fi

    # Esclusione GRANT
    [[ "${INCLUDE_GRANTS,,}" == "false" ]] && cmd_args+=("EXCLUDE=GRANT")

    # Transform
    [[ "${TRANSFORM_SEGMENT,,}" == "true" ]] && \
        cmd_args+=("TRANSFORM=SEGMENT_ATTRIBUTES:N")
    [[ "${TRANSFORM_OID,,}" == "true" ]] && \
        cmd_args+=("TRANSFORM=OID:N")

    # Generazione DDL senza import effettivo
    [[ -n "${SQLFILE:-}" ]] && cmd_args+=("SQLFILE=${SQLFILE}")

    # Job name univoco
    local job_name="M_DN_IMP_${SCHEMA}_${TIMESTAMP}"
    job_name="${job_name:0:30}"
    cmd_args+=("JOB_NAME=${job_name}")

    # Metriche
    cmd_args+=("METRICS=YES")

    echo "${cmd_args[*]}"
}

# ===========================================================================
# Generazione parfile
# ===========================================================================
generate_parfile() {
    local parfile_dir="/tmp"
    PARFILE_PATH="${parfile_dir}/m_dn_impdp_${SCHEMA}_${TIMESTAMP}.par"

    log_info "Generazione parfile: ${PARFILE_PATH}"

    cat > "${PARFILE_PATH}" <<PAREOF
# =============================================================================
# M-DN Data Pump Import — Parfile generato automaticamente
# Schema: ${SCHEMA}
# Data: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

DIRECTORY=${DUMP_DIR}
DUMPFILE=${DUMP_FILE}
LOGFILE=${LOG_NAME}
PAREOF

    # Schema o tabelle
    if [[ "${IMPORT_MODE}" == "TABLE" ]]; then
        local tables_with_schema=""
        IFS=',' read -ra TBL_ARRAY <<< "${TABLE_LIST}"
        for i in "${!TBL_ARRAY[@]}"; do
            local tbl="${TBL_ARRAY[$i]}"
            tbl="$(echo "${tbl}" | xargs)"
            [[ "${tbl}" != *.* ]] && tbl="${SCHEMA}.${tbl}"
            [[ $i -gt 0 ]] && tables_with_schema="${tables_with_schema},"
            tables_with_schema="${tables_with_schema}${tbl}"
        done
        echo "TABLES=${tables_with_schema}" >> "${PARFILE_PATH}"
    else
        echo "SCHEMAS=${SCHEMA}" >> "${PARFILE_PATH}"
    fi

    # Opzioni standard
    [[ "${PARALLEL}" -gt 1 ]] && echo "PARALLEL=${PARALLEL}" >> "${PARFILE_PATH}"
    echo "CONTENT=${CONTENT^^}" >> "${PARFILE_PATH}"
    echo "TABLE_EXISTS_ACTION=${TABLE_EXISTS_ACTION^^}" >> "${PARFILE_PATH}"

    # Remap
    [[ -n "${REMAP_SCHEMA:-}" ]]     && echo "REMAP_SCHEMA=${REMAP_SCHEMA}" >> "${PARFILE_PATH}"
    if [[ -n "${REMAP_TABLESPACE:-}" ]]; then
        IFS=';' read -ra TS_REMAPS <<< "${REMAP_TABLESPACE}"
        for ts_remap in "${TS_REMAPS[@]}"; do
            ts_remap="$(echo "${ts_remap}" | xargs)"
            [[ -n "${ts_remap}" ]] && echo "REMAP_TABLESPACE=${ts_remap}" >> "${PARFILE_PATH}"
        done
    fi
    if [[ -n "${REMAP_TABLE:-}" ]]; then
        IFS=';' read -ra TBL_REMAPS <<< "${REMAP_TABLE}"
        for tbl_remap in "${TBL_REMAPS[@]}"; do
            tbl_remap="$(echo "${tbl_remap}" | xargs)"
            [[ -n "${tbl_remap}" ]] && echo "REMAP_TABLE=${tbl_remap}" >> "${PARFILE_PATH}"
        done
    fi
    [[ -n "${REMAP_DATAFILE:-}" ]]   && echo "REMAP_DATAFILE=${REMAP_DATAFILE}" >> "${PARFILE_PATH}"

    # Esclusioni e trasformazioni
    [[ "${INCLUDE_GRANTS,,}" == "false" ]]    && echo "EXCLUDE=GRANT" >> "${PARFILE_PATH}"
    [[ "${TRANSFORM_SEGMENT,,}" == "true" ]]  && echo "TRANSFORM=SEGMENT_ATTRIBUTES:N" >> "${PARFILE_PATH}"
    [[ "${TRANSFORM_OID,,}" == "true" ]]      && echo "TRANSFORM=OID:N" >> "${PARFILE_PATH}"
    [[ -n "${SQLFILE:-}" ]]                   && echo "SQLFILE=${SQLFILE}" >> "${PARFILE_PATH}"

    local job_name="M_DN_IMP_${SCHEMA}_${TIMESTAMP}"
    echo "JOB_NAME=${job_name:0:30}" >> "${PARFILE_PATH}"
    echo "METRICS=YES" >> "${PARFILE_PATH}"

    log_debug "Contenuto parfile:"
    [[ "${DEBUG:-false}" == "true" ]] && cat "${PARFILE_PATH}"
}

# ===========================================================================
# Determinazione uso parfile
# ===========================================================================
should_use_parfile() {
    [[ "${USE_PARFILE,,}" == "true" ]] && return 0

    local complexity=0
    [[ -n "${REMAP_SCHEMA:-}" ]]     && ((complexity++))
    [[ -n "${REMAP_TABLESPACE:-}" ]] && ((complexity++))
    [[ -n "${REMAP_TABLE:-}" ]]      && ((complexity++))
    [[ -n "${REMAP_DATAFILE:-}" ]]   && ((complexity++))
    [[ -n "${TABLE_LIST:-}" ]]       && ((complexity++))
    [[ -n "${SQLFILE:-}" ]]          && ((complexity++))

    [[ ${complexity} -ge 2 ]] && return 0
    return 1
}

# ===========================================================================
# Esecuzione import
# ===========================================================================
execute_import() {
    local start_time
    start_time=$(date +%s)

    if should_use_parfile; then
        generate_parfile
        log_info "Esecuzione impdp con parfile..."
        log_info "Comando: ${IMPDP_BIN} \"<connect_string>\" PARFILE=${PARFILE_PATH}"

        timeout "${IMPORT_TIMEOUT}" "${IMPDP_BIN}" "${CONNECT_STRING}" \
            "PARFILE=${PARFILE_PATH}" 2>&1 | tee "/tmp/impdp_output_${TIMESTAMP}.log" &
        IMPDP_PID=$!
    else
        local impdp_cmd
        impdp_cmd="$(build_impdp_command)"
        log_info "Esecuzione impdp in modalità diretta..."
        log_info "Comando: $(echo "${impdp_cmd}" | sed "s|${CONNECT_STRING}|<REDACTED>|g")"

        timeout "${IMPORT_TIMEOUT}" bash -c "eval ${impdp_cmd}" 2>&1 \
            | tee "/tmp/impdp_output_${TIMESTAMP}.log" &
        IMPDP_PID=$!
    fi

    wait "${IMPDP_PID}"
    local raw_exit=$?

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    local minutes=$(( duration / 60 ))
    local seconds=$(( duration % 60 ))

    log_info "Durata esecuzione: ${minutes}m ${seconds}s"

    return ${raw_exit}
}

# ===========================================================================
# Analisi risultato
# ===========================================================================
analyze_result() {
    local exit_code=$1
    local output_log="/tmp/impdp_output_${TIMESTAMP}.log"

    # Timeout
    if [[ ${exit_code} -eq 124 ]]; then
        log_error "Import terminato per TIMEOUT dopo ${IMPORT_TIMEOUT} secondi."
        return 2
    fi

    if [[ -f "${output_log}" ]]; then
        local ora_errors
        ora_errors=$(grep -ci "^ORA-" "${output_log}" 2>/dev/null || echo "0")
        local warnings
        warnings=$(grep -ci "WARNING" "${output_log}" 2>/dev/null || echo "0")
        local completed
        completed=$(grep -c "successfully completed" "${output_log}" 2>/dev/null || echo "0")
        local completed_warnings
        completed_warnings=$(grep -c "completed with [0-9]* error" "${output_log}" 2>/dev/null || echo "0")

        # Errori noti non fatali (es. ORA-31684: oggetto già esistente con TABLE_EXISTS_ACTION=SKIP)
        local non_fatal_errors=0
        if [[ "${TABLE_EXISTS_ACTION^^}" == "SKIP" ]]; then
            non_fatal_errors=$(grep -c "ORA-31684" "${output_log}" 2>/dev/null || echo "0")
        fi
        # ORA-39082: oggetto di tipo già esistente (grants, etc.)
        local existing_obj_errors
        existing_obj_errors=$(grep -c "ORA-39082" "${output_log}" 2>/dev/null || echo "0")
        non_fatal_errors=$(( non_fatal_errors + existing_obj_errors ))

        local fatal_errors=$(( ora_errors - non_fatal_errors ))
        [[ ${fatal_errors} -lt 0 ]] && fatal_errors=0

        log_info "Analisi risultato: ORA-errors=${ora_errors} (fatali=${fatal_errors}), Warnings=${warnings}, Completato=${completed}"

        # Import completato con successo
        if [[ ${completed} -gt 0 && ${fatal_errors} -eq 0 ]]; then
            if [[ ${non_fatal_errors} -gt 0 || ${warnings} -gt 0 ]]; then
                log_warn "Import completato con ${non_fatal_errors} errori non fatali e ${warnings} warning."
                return 1
            fi
            log_info "Import completato con successo."
            return 0
        fi

        if [[ ${completed_warnings} -gt 0 && ${fatal_errors} -eq 0 ]]; then
            log_warn "Import completato con errori non fatali."
            return 1
        fi

        # Errori fatali
        if [[ ${fatal_errors} -gt 0 ]]; then
            log_error "Import fallito con ${fatal_errors} errori fatali."
            grep "^ORA-" "${output_log}" | grep -v "ORA-31684\|ORA-39082" | head -10 | while IFS= read -r err; do
                log_error "  ${err}"
            done
            return 2
        fi
    fi

    # Fallback sull'exit code
    if [[ ${exit_code} -eq 0 ]]; then
        return 0
    elif [[ ${exit_code} -le 1 ]]; then
        return 1
    else
        return 2
    fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    log_info "Parametri import:"
    log_info "  Modalità:             ${IMPORT_MODE}"
    log_info "  Schema:               ${SCHEMA}"
    log_info "  Directory:            ${DUMP_DIR}"
    log_info "  Dump File:            ${DUMP_FILE}"
    log_info "  Parallel:             ${PARALLEL}"
    log_info "  Content:              ${CONTENT}"
    log_info "  Table Exists Action:  ${TABLE_EXISTS_ACTION}"
    log_info "  Grants:               ${INCLUDE_GRANTS}"
    log_info "  Transform Segment:    ${TRANSFORM_SEGMENT}"
    log_info "  Transform OID:        ${TRANSFORM_OID}"
    log_info "  Timeout:              ${IMPORT_TIMEOUT}s"
    [[ -n "${TABLE_LIST:-}" ]]       && log_info "  Tables:               ${TABLE_LIST}"
    [[ -n "${REMAP_SCHEMA:-}" ]]     && log_info "  Remap Schema:         ${REMAP_SCHEMA}"
    [[ -n "${REMAP_TABLESPACE:-}" ]] && log_info "  Remap Tablespace:     ${REMAP_TABLESPACE}"
    [[ -n "${REMAP_TABLE:-}" ]]      && log_info "  Remap Table:          ${REMAP_TABLE}"
    [[ -n "${REMAP_DATAFILE:-}" ]]   && log_info "  Remap Datafile:       ${REMAP_DATAFILE}"
    [[ -n "${SQLFILE:-}" ]]          && log_info "  SQL File:             ${SQLFILE}"

    # Esecuzione
    execute_import
    local raw_exit=$?

    # Analisi
    analyze_result ${raw_exit}
    local final_exit=$?

    # Riepilogo finale
    log_info "============================================================"
    case ${final_exit} in
        0) log_info " Risultato: SUCCESSO (exit code: 0)" ;;
        1) log_warn " Risultato: WARNING (exit code: 1)" ;;
        2) log_error " Risultato: ERRORE (exit code: 2)" ;;
    esac
    log_info "============================================================"

    # Pulizia
    rm -f "/tmp/impdp_output_${TIMESTAMP}.log"

    exit ${final_exit}
}

main "$@"
