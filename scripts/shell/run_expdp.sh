#!/bin/bash
###############################################################################
# run_expdp.sh — Wrapper per Oracle Data Pump Export (expdp)
# Progetto: M-DN Oracle Data Pump Automation Pipeline
# Ambiente: DBCS / VM (NON Autonomous Database)
#
# Utilizzo:
#   run_expdp.sh <connect_string> <schema> <dump_dir> <dump_file> [options...]
#
# Variabili d'ambiente opzionali:
#   PARALLEL=4                                    — Grado di parallelismo
#   CONTENT=ALL|DATA_ONLY|METADATA_ONLY           — Contenuto dell'export
#   COMPRESSION=NONE|BASIC|ALL                    — Compressione dump
#   ENCRYPTION=NONE|ALL|DATA_ONLY                 — Cifratura dump
#   INCLUDE_GRANTS=true|false                     — Includere GRANT
#   INCLUDE_STATISTICS=true|false                 — Includere statistiche
#   EXCLUDE_TABLES=table1,table2                  — Tabelle da escludere
#   QUERY_FILTER="WHERE clause"                   — Filtro dati
#   TABLE_LIST=table1,table2                      — Export a livello tabella
#   LOGFILE=custom_logfile.log                    — Nome log personalizzato
#   FLASHBACK_TIME="SYSTIMESTAMP"                 — Export consistente
#   EXPORT_TIMEOUT=28800                          — Timeout in secondi (default 8h)
#   USE_PARFILE=true                              — Forzare l'uso di parfile
#
# Codici di uscita:
#   0 = Successo
#   1 = Warning (export completato con avvisi)
#   2 = Errore (export fallito)
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
readonly DEFAULT_COMPRESSION="BASIC"
readonly DEFAULT_ENCRYPTION="NONE"
readonly DEFAULT_CONTENT="ALL"

# Colori per output leggibile (compatibile ANSI)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ===========================================================================
# Funzioni di utilità
# ===========================================================================

log_info()    { echo -e "${GREEN}[INFO]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Mostra l'utilizzo dello script
usage() {
    cat <<EOF
Utilizzo: ${SCRIPT_NAME} <connect_string> <schema> <dump_dir> <dump_file> [options...]

Parametri obbligatori:
  connect_string   Stringa di connessione Oracle (es. user/pwd@host:port/service)
  schema           Schema da esportare
  dump_dir         Oracle directory object per il dump
  dump_file        Nome del file dump

Variabili d'ambiente opzionali:
  PARALLEL              Grado di parallelismo (default: ${DEFAULT_PARALLEL})
  CONTENT               ALL|DATA_ONLY|METADATA_ONLY (default: ${DEFAULT_CONTENT})
  COMPRESSION           NONE|BASIC|ALL (default: ${DEFAULT_COMPRESSION})
  ENCRYPTION            NONE|ALL|DATA_ONLY (default: ${DEFAULT_ENCRYPTION})
  INCLUDE_GRANTS        true|false (default: true)
  INCLUDE_STATISTICS    true|false (default: true)
  EXCLUDE_TABLES        Lista tabelle da escludere (separatore virgola)
  QUERY_FILTER          Clausola WHERE per filtrare i dati
  TABLE_LIST            Lista tabelle per export a livello tabella
  LOGFILE               Nome log personalizzato
  FLASHBACK_TIME        Timestamp per export consistente
  EXPORT_TIMEOUT        Timeout in secondi (default: ${DEFAULT_TIMEOUT})
  USE_PARFILE           Forzare uso di parfile (default: auto)

Codici di uscita:
  0 = Successo
  1 = Warning
  2 = Errore
EOF
    exit 2
}

# Validazione parametro non vuoto
validate_param() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" ]]; then
        log_error "Parametro obbligatorio mancante: ${name}"
        usage
    fi
}

# Validazione valori ammessi
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

# Pulizia risorse temporanee
cleanup() {
    local exit_code=$?
    if [[ -n "${PARFILE_PATH:-}" && -f "${PARFILE_PATH}" ]]; then
        log_debug "Rimozione parfile temporaneo: ${PARFILE_PATH}"
        rm -f "${PARFILE_PATH}"
    fi
    # Terminare il processo figlio se ancora in esecuzione (timeout)
    if [[ -n "${EXPDP_PID:-}" ]] && kill -0 "${EXPDP_PID}" 2>/dev/null; then
        log_warn "Terminazione forzata del processo expdp (PID: ${EXPDP_PID})"
        kill -TERM "${EXPDP_PID}" 2>/dev/null
        sleep 5
        kill -9 "${EXPDP_PID}" 2>/dev/null
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
COMPRESSION="${COMPRESSION:-${DEFAULT_COMPRESSION}}"
ENCRYPTION="${ENCRYPTION:-${DEFAULT_ENCRYPTION}}"
INCLUDE_GRANTS="${INCLUDE_GRANTS:-true}"
INCLUDE_STATISTICS="${INCLUDE_STATISTICS:-true}"
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-${DEFAULT_TIMEOUT}}"
USE_PARFILE="${USE_PARFILE:-auto}"

# Validazione valori enumerativi
validate_enum "CONTENT"     "${CONTENT}"     "ALL" "DATA_ONLY" "METADATA_ONLY"
validate_enum "COMPRESSION" "${COMPRESSION}" "NONE" "BASIC" "ALL"
validate_enum "ENCRYPTION"  "${ENCRYPTION}"  "NONE" "ALL" "DATA_ONLY"

# Verifica che PARALLEL sia un intero positivo
if ! [[ "${PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "PARALLEL deve essere un intero positivo: '${PARALLEL}'"
    exit 2
fi

# Verifica che EXPORT_TIMEOUT sia un intero positivo
if ! [[ "${EXPORT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "EXPORT_TIMEOUT deve essere un intero positivo: '${EXPORT_TIMEOUT}'"
    exit 2
fi

# ===========================================================================
# Verifica prerequisiti
# ===========================================================================
log_info "============================================================"
log_info " M-DN Data Pump Export — Avvio"
log_info " Schema: ${SCHEMA}"
log_info " Dump Dir: ${DUMP_DIR}"
log_info " Dump File: ${DUMP_FILE}"
log_info " Timestamp: ${TIMESTAMP}"
log_info "============================================================"

# Verifica disponibilità expdp
if ! command -v expdp &>/dev/null; then
    # Tentativo con ORACLE_HOME
    if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/expdp" ]]; then
        EXPDP_BIN="${ORACLE_HOME}/bin/expdp"
        log_info "expdp trovato in ORACLE_HOME: ${EXPDP_BIN}"
    else
        log_error "expdp non trovato nel PATH e ORACLE_HOME non configurato."
        exit 2
    fi
else
    EXPDP_BIN="$(command -v expdp)"
    log_info "expdp trovato: ${EXPDP_BIN}"
fi

# ===========================================================================
# Determinazione modalità: schema-level o table-level
# ===========================================================================
EXPORT_MODE="SCHEMA"
if [[ -n "${TABLE_LIST:-}" ]]; then
    EXPORT_MODE="TABLE"
    log_info "Modalità export: TABLE (tabelle: ${TABLE_LIST})"
else
    log_info "Modalità export: SCHEMA (schema: ${SCHEMA})"
fi

# ===========================================================================
# Generazione nome logfile
# ===========================================================================
if [[ -n "${LOGFILE:-}" ]]; then
    LOG_NAME="${LOGFILE}"
else
    LOG_NAME="${SCHEMA}_export_${TIMESTAMP}.log"
fi
log_info "Log file: ${LOG_NAME}"

# ===========================================================================
# Costruzione comando expdp
# ===========================================================================
build_expdp_command() {
    local cmd_args=()

    # Connessione
    cmd_args+=("${EXPDP_BIN}")
    cmd_args+=("\"${CONNECT_STRING}\"")

    # Schema o tabelle
    if [[ "${EXPORT_MODE}" == "TABLE" ]]; then
        # Costruzione lista tabelle con prefisso schema
        local tables_with_schema=""
        IFS=',' read -ra TBL_ARRAY <<< "${TABLE_LIST}"
        for i in "${!TBL_ARRAY[@]}"; do
            local tbl="${TBL_ARRAY[$i]}"
            tbl="$(echo "${tbl}" | xargs)" # Trim whitespace
            # Aggiungi prefisso schema se non presente
            if [[ "${tbl}" != *.* ]]; then
                tbl="${SCHEMA}.${tbl}"
            fi
            if [[ $i -gt 0 ]]; then
                tables_with_schema="${tables_with_schema},"
            fi
            tables_with_schema="${tables_with_schema}${tbl}"
        done
        cmd_args+=("TABLES=${tables_with_schema}")
    else
        cmd_args+=("SCHEMAS=${SCHEMA}")
    fi

    # Directory e file dump
    cmd_args+=("DIRECTORY=${DUMP_DIR}")
    cmd_args+=("DUMPFILE=${DUMP_FILE}")
    cmd_args+=("LOGFILE=${LOG_NAME}")

    # Parallelismo
    if [[ "${PARALLEL}" -gt 1 ]]; then
        cmd_args+=("PARALLEL=${PARALLEL}")
    fi

    # Contenuto
    cmd_args+=("CONTENT=${CONTENT^^}")

    # Compressione
    if [[ "${COMPRESSION^^}" != "NONE" ]]; then
        cmd_args+=("COMPRESSION=${COMPRESSION^^}")
    fi

    # Cifratura
    if [[ "${ENCRYPTION^^}" != "NONE" ]]; then
        cmd_args+=("ENCRYPTION=${ENCRYPTION^^}")
    fi

    # Esclusione GRANT se richiesto
    if [[ "${INCLUDE_GRANTS,,}" == "false" ]]; then
        cmd_args+=("EXCLUDE=GRANT")
    fi

    # Esclusione statistiche se richiesto
    if [[ "${INCLUDE_STATISTICS,,}" == "false" ]]; then
        cmd_args+=("EXCLUDE=STATISTICS")
    fi

    # Tabelle da escludere
    if [[ -n "${EXCLUDE_TABLES:-}" ]]; then
        IFS=',' read -ra EXCL_ARRAY <<< "${EXCLUDE_TABLES}"
        for excl_tbl in "${EXCL_ARRAY[@]}"; do
            excl_tbl="$(echo "${excl_tbl}" | xargs)"
            cmd_args+=("EXCLUDE=TABLE:\"IN ('${excl_tbl^^}')\"")
        done
    fi

    # Filtro query
    if [[ -n "${QUERY_FILTER:-}" ]]; then
        cmd_args+=("QUERY=${SCHEMA}:\"${QUERY_FILTER}\"")
    fi

    # Flashback time per consistenza
    if [[ -n "${FLASHBACK_TIME:-}" ]]; then
        cmd_args+=("FLASHBACK_TIME=\"${FLASHBACK_TIME}\"")
    fi

    # Job name univoco
    local job_name="M_DN_EXP_${SCHEMA}_${TIMESTAMP}"
    # Tronca a 30 caratteri (limite Oracle)
    job_name="${job_name:0:30}"
    cmd_args+=("JOB_NAME=${job_name}")

    # Metriche di performance
    cmd_args+=("METRICS=YES")
    cmd_args+=("REUSE_DUMPFILES=YES")

    echo "${cmd_args[*]}"
}

# ===========================================================================
# Generazione parfile (per operazioni complesse o su richiesta)
# ===========================================================================
generate_parfile() {
    local parfile_dir="/tmp"
    PARFILE_PATH="${parfile_dir}/m_dn_expdp_${SCHEMA}_${TIMESTAMP}.par"

    log_info "Generazione parfile: ${PARFILE_PATH}"

    cat > "${PARFILE_PATH}" <<PAREOF
# =============================================================================
# M-DN Data Pump Export — Parfile generato automaticamente
# Schema: ${SCHEMA}
# Data: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

DIRECTORY=${DUMP_DIR}
DUMPFILE=${DUMP_FILE}
LOGFILE=${LOG_NAME}
PAREOF

    # Schema o tabelle
    if [[ "${EXPORT_MODE}" == "TABLE" ]]; then
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

    # Opzioni
    [[ "${PARALLEL}" -gt 1 ]] && echo "PARALLEL=${PARALLEL}" >> "${PARFILE_PATH}"
    echo "CONTENT=${CONTENT^^}" >> "${PARFILE_PATH}"
    [[ "${COMPRESSION^^}" != "NONE" ]] && echo "COMPRESSION=${COMPRESSION^^}" >> "${PARFILE_PATH}"
    [[ "${ENCRYPTION^^}" != "NONE" ]]  && echo "ENCRYPTION=${ENCRYPTION^^}" >> "${PARFILE_PATH}"
    [[ "${INCLUDE_GRANTS,,}" == "false" ]]     && echo "EXCLUDE=GRANT" >> "${PARFILE_PATH}"
    [[ "${INCLUDE_STATISTICS,,}" == "false" ]]  && echo "EXCLUDE=STATISTICS" >> "${PARFILE_PATH}"

    if [[ -n "${EXCLUDE_TABLES:-}" ]]; then
        IFS=',' read -ra EXCL_ARRAY <<< "${EXCLUDE_TABLES}"
        for excl_tbl in "${EXCL_ARRAY[@]}"; do
            excl_tbl="$(echo "${excl_tbl}" | xargs)"
            echo "EXCLUDE=TABLE:\"IN ('${excl_tbl^^}')\"" >> "${PARFILE_PATH}"
        done
    fi

    [[ -n "${QUERY_FILTER:-}" ]]   && echo "QUERY=${SCHEMA}:\"${QUERY_FILTER}\"" >> "${PARFILE_PATH}"
    [[ -n "${FLASHBACK_TIME:-}" ]] && echo "FLASHBACK_TIME=\"${FLASHBACK_TIME}\"" >> "${PARFILE_PATH}"

    local job_name="M_DN_EXP_${SCHEMA}_${TIMESTAMP}"
    echo "JOB_NAME=${job_name:0:30}" >> "${PARFILE_PATH}"
    echo "METRICS=YES" >> "${PARFILE_PATH}"
    echo "REUSE_DUMPFILES=YES" >> "${PARFILE_PATH}"

    log_debug "Contenuto parfile:"
    [[ "${DEBUG:-false}" == "true" ]] && cat "${PARFILE_PATH}"
}

# ===========================================================================
# Determinazione uso parfile
# ===========================================================================
should_use_parfile() {
    # Forzato dall'utente
    [[ "${USE_PARFILE,,}" == "true" ]] && return 0

    # Auto-detect: usare parfile se ci sono opzioni complesse
    local complexity=0
    [[ -n "${EXCLUDE_TABLES:-}" ]]  && ((complexity++))
    [[ -n "${QUERY_FILTER:-}" ]]    && ((complexity++))
    [[ -n "${TABLE_LIST:-}" ]]      && ((complexity++))
    [[ -n "${FLASHBACK_TIME:-}" ]]  && ((complexity++))

    [[ ${complexity} -ge 2 ]] && return 0
    return 1
}

# ===========================================================================
# Esecuzione export
# ===========================================================================
execute_export() {
    local start_time
    start_time=$(date +%s)

    if should_use_parfile; then
        generate_parfile
        log_info "Esecuzione expdp con parfile..."
        log_info "Comando: ${EXPDP_BIN} \"<connect_string>\" PARFILE=${PARFILE_PATH}"

        # Esecuzione con timeout
        timeout "${EXPORT_TIMEOUT}" "${EXPDP_BIN}" "${CONNECT_STRING}" \
            "PARFILE=${PARFILE_PATH}" 2>&1 | tee "/tmp/expdp_output_${TIMESTAMP}.log" &
        EXPDP_PID=$!
    else
        local expdp_cmd
        expdp_cmd="$(build_expdp_command)"
        log_info "Esecuzione expdp in modalità diretta..."
        log_info "Comando: $(echo "${expdp_cmd}" | sed "s|${CONNECT_STRING}|<REDACTED>|g")"

        # Esecuzione con timeout — eval necessario per espansione corretta
        timeout "${EXPORT_TIMEOUT}" bash -c "eval ${expdp_cmd}" 2>&1 \
            | tee "/tmp/expdp_output_${TIMESTAMP}.log" &
        EXPDP_PID=$!
    fi

    # Attesa completamento
    wait "${EXPDP_PID}"
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
    local output_log="/tmp/expdp_output_${TIMESTAMP}.log"

    # Timeout (exit code 124 da timeout command)
    if [[ ${exit_code} -eq 124 ]]; then
        log_error "Export terminato per TIMEOUT dopo ${EXPORT_TIMEOUT} secondi."
        return 2
    fi

    # Analisi output per warning/errori Oracle
    if [[ -f "${output_log}" ]]; then
        local ora_errors
        ora_errors=$(grep -ci "^ORA-" "${output_log}" 2>/dev/null || echo "0")
        local warnings
        warnings=$(grep -ci "WARNING" "${output_log}" 2>/dev/null || echo "0")
        local completed
        completed=$(grep -c "successfully completed" "${output_log}" 2>/dev/null || echo "0")
        local completed_warnings
        completed_warnings=$(grep -c "completed with [0-9]* error" "${output_log}" 2>/dev/null || echo "0")

        log_info "Analisi risultato: ORA-errors=${ora_errors}, Warnings=${warnings}, Completato=${completed}"

        # Export completato con successo
        if [[ ${completed} -gt 0 && ${ora_errors} -eq 0 ]]; then
            log_info "Export completato con successo."
            return 0
        fi

        # Export completato con warning
        if [[ ${completed} -gt 0 && ${warnings} -gt 0 ]]; then
            log_warn "Export completato con ${warnings} warning."
            return 1
        fi

        if [[ ${completed_warnings} -gt 0 ]]; then
            log_warn "Export completato con errori non fatali."
            return 1
        fi

        # Errori fatali
        if [[ ${ora_errors} -gt 0 ]]; then
            log_error "Export fallito con ${ora_errors} errori ORA-."
            # Stampa i primi 10 errori per diagnostica
            grep "^ORA-" "${output_log}" | head -10 | while IFS= read -r err; do
                log_error "  ${err}"
            done
            return 2
        fi
    fi

    # Basarsi sull'exit code del processo
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
    log_info "Parametri export:"
    log_info "  Modalità:      ${EXPORT_MODE}"
    log_info "  Schema:        ${SCHEMA}"
    log_info "  Directory:     ${DUMP_DIR}"
    log_info "  Dump File:     ${DUMP_FILE}"
    log_info "  Parallel:      ${PARALLEL}"
    log_info "  Content:       ${CONTENT}"
    log_info "  Compression:   ${COMPRESSION}"
    log_info "  Encryption:    ${ENCRYPTION}"
    log_info "  Grants:        ${INCLUDE_GRANTS}"
    log_info "  Statistics:    ${INCLUDE_STATISTICS}"
    log_info "  Timeout:       ${EXPORT_TIMEOUT}s"
    [[ -n "${TABLE_LIST:-}" ]]     && log_info "  Tables:        ${TABLE_LIST}"
    [[ -n "${EXCLUDE_TABLES:-}" ]] && log_info "  Exclude:       ${EXCLUDE_TABLES}"
    [[ -n "${QUERY_FILTER:-}" ]]   && log_info "  Query Filter:  ${QUERY_FILTER}"
    [[ -n "${FLASHBACK_TIME:-}" ]] && log_info "  Flashback:     ${FLASHBACK_TIME}"

    # Esecuzione
    execute_export
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

    # Pulizia output temporaneo
    rm -f "/tmp/expdp_output_${TIMESTAMP}.log"

    exit ${final_exit}
}

main "$@"
