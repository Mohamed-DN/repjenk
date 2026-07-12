#!/bin/bash
###############################################################################
# health_check.sh — Controllo salute pre-pipeline
# Progetto: ENI Oracle Data Pump Automation Pipeline
#
# Utilizzo:
#   health_check.sh [connect_string]
#
# Verifica:
#   1. Variabili d'ambiente Oracle (ORACLE_HOME, ORACLE_SID, TNS_ADMIN)
#   2. Disponibilità Oracle Client / sqlplus
#   3. Disponibilità e autenticazione OCI CLI
#   4. Connettività database (se connect_string fornita)
#   5. Spazio disco su filesystem rilevanti
#   6. Job Data Pump attivi
#   7. Stato listener
#
# Variabili d'ambiente opzionali:
#   MIN_DISK_SPACE_GB=10       — Spazio disco minimo richiesto (default: 10)
#   DATA_PUMP_DIR_PATH         — Percorso filesystem Data Pump directory
#   CHECK_LISTENER=true|false  — Verifica stato listener (default: true)
#   ORACLE_HOME                — Home Oracle
#   ORACLE_SID                 — SID Oracle
#   TNS_ADMIN                  — Directory TNS
#
# Output:
#   Report PASS/FAIL per ogni controllo
#
# Codici di uscita:
#   0 = Tutti i controlli superati
#   1 = Uno o più controlli falliti (warning — non bloccanti)
#   2 = Controlli critici falliti (bloccanti)
###############################################################################

# ===========================================================================
# Costanti
# ===========================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_MIN_DISK_SPACE_GB=10

# Colori
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ===========================================================================
# Variabili stato
# ===========================================================================
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0
CRITICAL_FAILURE=false

# Array per il report finale
declare -a CHECK_RESULTS=()

# ===========================================================================
# Funzioni di utilità
# ===========================================================================

log_info()  { echo -e "${GREEN}[INFO]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Registra risultato di un controllo
record_check() {
    local check_name="$1"
    local status="$2"    # PASS, FAIL, WARN, SKIP
    local message="$3"
    local critical="${4:-false}"

    ((TOTAL_CHECKS++))

    case "${status}" in
        PASS)
            ((PASSED_CHECKS++))
            CHECK_RESULTS+=("${GREEN}[PASS]${NC} ${check_name}: ${message}")
            ;;
        FAIL)
            ((FAILED_CHECKS++))
            CHECK_RESULTS+=("${RED}[FAIL]${NC} ${check_name}: ${message}")
            [[ "${critical}" == "true" ]] && CRITICAL_FAILURE=true
            ;;
        WARN)
            ((WARNING_CHECKS++))
            CHECK_RESULTS+=("${YELLOW}[WARN]${NC} ${check_name}: ${message}")
            ;;
        SKIP)
            CHECK_RESULTS+=("${BLUE}[SKIP]${NC} ${check_name}: ${message}")
            ;;
    esac
}

# Separatore sezione
section_header() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━ $1 ━━━${NC}"
}

# ===========================================================================
# CHECK 1: Variabili d'ambiente Oracle
# ===========================================================================
check_oracle_env() {
    section_header "Variabili d'ambiente Oracle"

    # ORACLE_HOME
    if [[ -n "${ORACLE_HOME:-}" ]]; then
        if [[ -d "${ORACLE_HOME}" ]]; then
            record_check "ORACLE_HOME" "PASS" "${ORACLE_HOME}"
        else
            record_check "ORACLE_HOME" "FAIL" "Directory non esiste: ${ORACLE_HOME}" "true"
        fi
    else
        record_check "ORACLE_HOME" "FAIL" "Non impostata" "true"
    fi

    # ORACLE_SID
    if [[ -n "${ORACLE_SID:-}" ]]; then
        record_check "ORACLE_SID" "PASS" "${ORACLE_SID}"
    else
        record_check "ORACLE_SID" "WARN" "Non impostata (richiesto solo per connessioni locali)"
    fi

    # TNS_ADMIN
    if [[ -n "${TNS_ADMIN:-}" ]]; then
        if [[ -d "${TNS_ADMIN}" ]]; then
            # Verifica presenza tnsnames.ora
            if [[ -f "${TNS_ADMIN}/tnsnames.ora" ]]; then
                record_check "TNS_ADMIN" "PASS" "${TNS_ADMIN} (tnsnames.ora presente)"
            else
                record_check "TNS_ADMIN" "WARN" "${TNS_ADMIN} (tnsnames.ora NON trovato)"
            fi
        else
            record_check "TNS_ADMIN" "FAIL" "Directory non esiste: ${TNS_ADMIN}"
        fi
    else
        # Tentativo fallback su $ORACLE_HOME/network/admin
        if [[ -n "${ORACLE_HOME:-}" && -d "${ORACLE_HOME}/network/admin" ]]; then
            record_check "TNS_ADMIN" "WARN" "Non impostata, ma ${ORACLE_HOME}/network/admin esiste"
        else
            record_check "TNS_ADMIN" "WARN" "Non impostata"
        fi
    fi

    # LD_LIBRARY_PATH (Linux) / DYLD_LIBRARY_PATH (macOS)
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        if echo "${LD_LIBRARY_PATH}" | grep -q "${ORACLE_HOME:-__NONE__}"; then
            record_check "LD_LIBRARY_PATH" "PASS" "Contiene ORACLE_HOME/lib"
        else
            record_check "LD_LIBRARY_PATH" "WARN" "Non contiene ORACLE_HOME/lib"
        fi
    else
        record_check "LD_LIBRARY_PATH" "WARN" "Non impostata"
    fi

    # PATH include ORACLE_HOME/bin
    if echo "${PATH}" | grep -q "${ORACLE_HOME:-__NONE__}/bin"; then
        record_check "PATH" "PASS" "Contiene ORACLE_HOME/bin"
    else
        record_check "PATH" "WARN" "Non contiene ORACLE_HOME/bin"
    fi
}

# ===========================================================================
# CHECK 2: Disponibilità Oracle Client
# ===========================================================================
check_oracle_client() {
    section_header "Oracle Client / Strumenti"

    # sqlplus
    if command -v sqlplus &>/dev/null; then
        local sqlplus_ver
        sqlplus_ver=$(sqlplus -V 2>/dev/null | head -1)
        record_check "sqlplus" "PASS" "${sqlplus_ver}"
    elif [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/sqlplus" ]]; then
        local sqlplus_ver
        sqlplus_ver=$("${ORACLE_HOME}/bin/sqlplus" -V 2>/dev/null | head -1)
        record_check "sqlplus" "PASS" "${sqlplus_ver} (via ORACLE_HOME)"
    else
        record_check "sqlplus" "FAIL" "Non trovato" "true"
    fi

    # expdp
    if command -v expdp &>/dev/null; then
        record_check "expdp" "PASS" "$(command -v expdp)"
    elif [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/expdp" ]]; then
        record_check "expdp" "PASS" "${ORACLE_HOME}/bin/expdp"
    else
        record_check "expdp" "FAIL" "Non trovato" "true"
    fi

    # impdp
    if command -v impdp &>/dev/null; then
        record_check "impdp" "PASS" "$(command -v impdp)"
    elif [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/impdp" ]]; then
        record_check "impdp" "PASS" "${ORACLE_HOME}/bin/impdp"
    else
        record_check "impdp" "FAIL" "Non trovato" "true"
    fi

    # tnsping (opzionale ma utile)
    if command -v tnsping &>/dev/null || [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/tnsping" ]]; then
        record_check "tnsping" "PASS" "Disponibile"
    else
        record_check "tnsping" "WARN" "Non trovato (opzionale)"
    fi
}

# ===========================================================================
# CHECK 3: OCI CLI
# ===========================================================================
check_oci_cli() {
    section_header "OCI CLI"

    # Disponibilità
    if ! command -v oci &>/dev/null; then
        record_check "OCI CLI" "FAIL" "Non trovato nel PATH"
        return
    fi

    local oci_version
    oci_version=$(oci --version 2>/dev/null)
    record_check "OCI CLI" "PASS" "Versione: ${oci_version}"

    # Verifica file di configurazione
    local oci_config="${OCI_CONFIG_FILE:-${HOME}/.oci/config}"
    if [[ -f "${oci_config}" ]]; then
        record_check "OCI Config" "PASS" "${oci_config}"
    else
        record_check "OCI Config" "FAIL" "File non trovato: ${oci_config}"
        return
    fi

    # Verifica chiave API
    local oci_key_file
    oci_key_file=$(grep "key_file" "${oci_config}" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
    if [[ -n "${oci_key_file}" ]]; then
        # Espandi ~ se necessario
        oci_key_file="${oci_key_file/#\~/$HOME}"
        if [[ -f "${oci_key_file}" ]]; then
            record_check "OCI API Key" "PASS" "${oci_key_file}"
        else
            record_check "OCI API Key" "FAIL" "File chiave non trovato: ${oci_key_file}"
        fi
    else
        record_check "OCI API Key" "WARN" "Nessuna chiave configurata (potrebbe usare instance principal)"
    fi

    # Test autenticazione — tentativo di ottenere namespace
    local ns_output
    ns_output=$(oci os ns get --output json 2>&1)
    if [[ $? -eq 0 ]]; then
        local namespace
        namespace=$(echo "${ns_output}" | grep -o '"data"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
        record_check "OCI Auth" "PASS" "Namespace: ${namespace}"
    else
        record_check "OCI Auth" "FAIL" "Autenticazione fallita: $(echo "${ns_output}" | head -1)"
    fi
}

# ===========================================================================
# CHECK 4: Connettività database
# ===========================================================================
check_db_connectivity() {
    local connect_string="$1"

    section_header "Connettività Database"

    if [[ -z "${connect_string}" ]]; then
        record_check "DB Connection" "SKIP" "Nessuna stringa di connessione fornita"
        return
    fi

    # Maschera credenziali nel log
    local masked_conn
    masked_conn=$(echo "${connect_string}" | sed 's|/[^@]*@|/****@|')
    log_info "Test connessione: ${masked_conn}"

    # Determina il binario sqlplus
    local sqlplus_bin="sqlplus"
    if ! command -v sqlplus &>/dev/null; then
        if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/sqlplus" ]]; then
            sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"
        else
            record_check "DB Connection" "SKIP" "sqlplus non disponibile"
            return
        fi
    fi

    # Test connessione con timeout
    local db_output
    db_output=$(timeout 30 "${sqlplus_bin}" -S "${connect_string}" <<'EOSQL' 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT 'DB_NAME='||SYS_CONTEXT('USERENV','DB_NAME')
  ||'|VERSION='||VERSION
  ||'|INSTANCE='||INSTANCE_NAME
  ||'|STATUS='||STATUS
  ||'|HOST='||HOST_NAME
FROM V$INSTANCE;
EXIT;
EOSQL
    )
    local db_exit=$?

    if [[ ${db_exit} -eq 124 ]]; then
        record_check "DB Connection" "FAIL" "Timeout connessione (30s)"
        return
    fi

    if [[ ${db_exit} -eq 0 ]] && echo "${db_output}" | grep -q "DB_NAME="; then
        # Parsing risultato
        local db_info
        db_info=$(echo "${db_output}" | grep "DB_NAME=")
        local db_name=$(echo "${db_info}" | sed 's/.*DB_NAME=\([^|]*\).*/\1/')
        local db_version=$(echo "${db_info}" | sed 's/.*VERSION=\([^|]*\).*/\1/')
        local db_instance=$(echo "${db_info}" | sed 's/.*INSTANCE=\([^|]*\).*/\1/')
        local db_status=$(echo "${db_info}" | sed 's/.*STATUS=\([^|]*\).*/\1/')

        record_check "DB Connection" "PASS" "DB=${db_name}, Ver=${db_version}, Instance=${db_instance}, Status=${db_status}"

        # Verifica stato OPEN
        if [[ "${db_status}" == "OPEN" ]]; then
            record_check "DB Status" "PASS" "Database aperto"
        else
            record_check "DB Status" "WARN" "Database non in stato OPEN: ${db_status}"
        fi
    else
        # Analisi errore
        if echo "${db_output}" | grep -qi "ORA-12541\|TNS:no listener"; then
            record_check "DB Connection" "FAIL" "Listener non disponibile" "true"
        elif echo "${db_output}" | grep -qi "ORA-12154\|TNS:could not resolve"; then
            record_check "DB Connection" "FAIL" "Service name non risolvibile"
        elif echo "${db_output}" | grep -qi "ORA-01017\|invalid username/password"; then
            record_check "DB Connection" "FAIL" "Credenziali non valide"
        elif echo "${db_output}" | grep -qi "ORA-12170\|TNS:Connect timeout"; then
            record_check "DB Connection" "FAIL" "Timeout TNS"
        else
            local first_error
            first_error=$(echo "${db_output}" | grep "ORA-\|SP2-" | head -1)
            record_check "DB Connection" "FAIL" "${first_error:-Errore sconosciuto}"
        fi
    fi
}

# ===========================================================================
# CHECK 5: Spazio disco
# ===========================================================================
check_disk_space() {
    section_header "Spazio Disco"

    local min_space_gb="${MIN_DISK_SPACE_GB:-${DEFAULT_MIN_DISK_SPACE_GB}}"
    local min_space_kb=$(( min_space_gb * 1048576 ))

    # Filesystem da controllare
    local check_paths=()
    check_paths+=("/")
    check_paths+=("/tmp")
    [[ -n "${ORACLE_HOME:-}" ]]        && check_paths+=("${ORACLE_HOME}")
    [[ -n "${DATA_PUMP_DIR_PATH:-}" ]] && check_paths+=("${DATA_PUMP_DIR_PATH}")

    # Rimuovi duplicati di mount point
    declare -A seen_mounts

    for check_path in "${check_paths[@]}"; do
        [[ ! -d "${check_path}" ]] && continue

        # Ottieni mount point
        local mount_point
        mount_point=$(df -P "${check_path}" 2>/dev/null | tail -1 | awk '{print $NF}')
        [[ -z "${mount_point}" ]] && continue

        # Salta se già controllato
        if [[ -n "${seen_mounts[${mount_point}]:-}" ]]; then
            continue
        fi
        seen_mounts["${mount_point}"]=1

        # Ottieni spazio disponibile in KB
        local avail_kb
        avail_kb=$(df -P "${check_path}" 2>/dev/null | tail -1 | awk '{print $4}')
        local avail_gb=$(( avail_kb / 1048576 ))
        local used_pct
        used_pct=$(df -P "${check_path}" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')

        if [[ ${avail_kb} -ge ${min_space_kb} ]]; then
            record_check "Disco ${mount_point}" "PASS" \
                "${avail_gb} GB liberi (${used_pct}% usato) — minimo: ${min_space_gb} GB"
        elif [[ ${avail_kb} -ge $(( min_space_kb / 2 )) ]]; then
            record_check "Disco ${mount_point}" "WARN" \
                "${avail_gb} GB liberi (${used_pct}% usato) — sotto soglia consigliata (${min_space_gb} GB)"
        else
            record_check "Disco ${mount_point}" "FAIL" \
                "${avail_gb} GB liberi (${used_pct}% usato) — insufficiente (minimo: ${min_space_gb} GB)" "true"
        fi
    done

    # Controllo specifico per Data Pump directory path
    if [[ -n "${DATA_PUMP_DIR_PATH:-}" ]]; then
        if [[ -d "${DATA_PUMP_DIR_PATH}" ]]; then
            if [[ -w "${DATA_PUMP_DIR_PATH}" ]]; then
                record_check "Data Pump Dir" "PASS" "Scrivibile: ${DATA_PUMP_DIR_PATH}"
            else
                record_check "Data Pump Dir" "FAIL" "Non scrivibile: ${DATA_PUMP_DIR_PATH}"
            fi
        else
            record_check "Data Pump Dir" "WARN" "Directory non esiste: ${DATA_PUMP_DIR_PATH}"
        fi
    fi
}

# ===========================================================================
# CHECK 6: Job Data Pump attivi
# ===========================================================================
check_datapump_jobs() {
    local connect_string="$1"

    section_header "Job Data Pump Attivi"

    if [[ -z "${connect_string}" ]]; then
        record_check "DataPump Jobs" "SKIP" "Nessuna stringa di connessione fornita"
        return
    fi

    local sqlplus_bin="sqlplus"
    if ! command -v sqlplus &>/dev/null; then
        [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/sqlplus" ]] && sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"
    fi

    local jobs_output
    jobs_output=$(timeout 30 "${sqlplus_bin}" -S "${connect_string}" <<'EOSQL' 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300
SELECT 'JOB|'||OWNER_NAME||'|'||JOB_NAME||'|'||OPERATION||'|'||JOB_MODE||'|'||STATE||'|'||DEGREE
FROM DBA_DATAPUMP_JOBS
WHERE STATE IN ('EXECUTING','DEFINING','NOT RUNNING')
ORDER BY OWNER_NAME, JOB_NAME;
SELECT 'COUNT|'||COUNT(*) FROM DBA_DATAPUMP_JOBS WHERE STATE = 'EXECUTING';
EXIT;
EOSQL
    )
    local dp_exit=$?

    if [[ ${dp_exit} -ne 0 ]] || echo "${jobs_output}" | grep -qi "ORA-\|SP2-"; then
        # Potrebbe non avere permessi su DBA_DATAPUMP_JOBS
        record_check "DataPump Jobs" "WARN" "Impossibile verificare (permessi insufficienti o errore connessione)"
        return
    fi

    local running_count
    running_count=$(echo "${jobs_output}" | grep "^COUNT|" | cut -d'|' -f2 | xargs)
    running_count="${running_count:-0}"

    if [[ "${running_count}" -eq 0 ]]; then
        record_check "DataPump Jobs" "PASS" "Nessun job in esecuzione"
    else
        record_check "DataPump Jobs" "WARN" "${running_count} job in esecuzione"

        # Dettaglio job attivi
        echo "${jobs_output}" | grep "^JOB|" | while IFS='|' read -r _ owner name op mode state degree; do
            log_warn "  Job: ${owner}.${name} — ${op} ${mode} — Stato: ${state} — Parallelo: ${degree}"
        done
    fi
}

# ===========================================================================
# CHECK 7: Stato Listener
# ===========================================================================
check_listener() {
    section_header "Stato Listener"

    local check_listener="${CHECK_LISTENER:-true}"
    if [[ "${check_listener,,}" != "true" ]]; then
        record_check "Listener" "SKIP" "Controllo disabilitato (CHECK_LISTENER=false)"
        return
    fi

    # Verifica lsnrctl
    local lsnrctl_bin="lsnrctl"
    if ! command -v lsnrctl &>/dev/null; then
        if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/lsnrctl" ]]; then
            lsnrctl_bin="${ORACLE_HOME}/bin/lsnrctl"
        else
            record_check "Listener" "WARN" "lsnrctl non trovato (potrebbe non essere necessario per connessioni remote)"
            return
        fi
    fi

    local listener_output
    listener_output=$(timeout 15 "${lsnrctl_bin}" status 2>&1)
    local listener_exit=$?

    if [[ ${listener_exit} -eq 124 ]]; then
        record_check "Listener" "WARN" "Timeout verifica listener"
        return
    fi

    if echo "${listener_output}" | grep -qi "TNS-12541\|no listener"; then
        record_check "Listener" "FAIL" "Listener non attivo"
    elif echo "${listener_output}" | grep -qi "ready"; then
        # Conta servizi registrati
        local services_count
        services_count=$(echo "${listener_output}" | grep -c "Service " 2>/dev/null || echo "0")
        local instances_count
        instances_count=$(echo "${listener_output}" | grep -c "Instance " 2>/dev/null || echo "0")
        record_check "Listener" "PASS" "Attivo — ${services_count} servizi, ${instances_count} istanze registrate"
    else
        record_check "Listener" "WARN" "Stato indeterminato"
    fi
}

# ===========================================================================
# Ulteriori controlli di utilità
# ===========================================================================
check_utilities() {
    section_header "Utilità Aggiuntive"

    # jq (utile per parsing JSON OCI CLI)
    if command -v jq &>/dev/null; then
        record_check "jq" "PASS" "$(jq --version 2>/dev/null)"
    else
        record_check "jq" "WARN" "Non trovato (consigliato per parsing JSON)"
    fi

    # python3 (fallback per parsing)
    if command -v python3 &>/dev/null; then
        record_check "python3" "PASS" "$(python3 --version 2>/dev/null)"
    else
        record_check "python3" "WARN" "Non trovato"
    fi

    # curl / wget
    if command -v curl &>/dev/null; then
        record_check "curl" "PASS" "Disponibile"
    elif command -v wget &>/dev/null; then
        record_check "wget" "PASS" "Disponibile"
    else
        record_check "curl/wget" "WARN" "Nessun client HTTP trovato"
    fi

    # Verifica ulimits rilevanti
    local open_files
    open_files=$(ulimit -n 2>/dev/null || echo "unknown")
    if [[ "${open_files}" =~ ^[0-9]+$ && ${open_files} -ge 4096 ]]; then
        record_check "Open Files Limit" "PASS" "ulimit -n = ${open_files}"
    elif [[ "${open_files}" =~ ^[0-9]+$ ]]; then
        record_check "Open Files Limit" "WARN" "ulimit -n = ${open_files} (consigliato >= 4096)"
    else
        record_check "Open Files Limit" "WARN" "Impossibile determinare (${open_files})"
    fi
}

# ===========================================================================
# Report Finale
# ===========================================================================
print_report() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║          ENI Data Pump Pipeline — Health Check Report       ║${NC}"
    echo -e "${BOLD}║          $(date '+%Y-%m-%d %H:%M:%S')                                  ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    for result in "${CHECK_RESULTS[@]}"; do
        echo -e "  ${result}"
    done

    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${BOLD}Totale:${NC}  ${TOTAL_CHECKS} controlli"
    echo -e "  ${GREEN}${BOLD}Superati:${NC} ${PASSED_CHECKS}"
    echo -e "  ${RED}${BOLD}Falliti:${NC}  ${FAILED_CHECKS}"
    echo -e "  ${YELLOW}${BOLD}Warning:${NC}  ${WARNING_CHECKS}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    if [[ "${CRITICAL_FAILURE}" == "true" ]]; then
        echo -e "  ${RED}${BOLD}STATO COMPLESSIVO: ✗ CRITICO — Pipeline non avviabile${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
        return 2
    elif [[ ${FAILED_CHECKS} -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}STATO COMPLESSIVO: ⚠ WARNING — Verificare i fallimenti${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
        return 1
    else
        echo -e "  ${GREEN}${BOLD}STATO COMPLESSIVO: ✓ OK — Pipeline pronta${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
        return 0
    fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    local connect_string="${1:-}"

    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     ENI Oracle Data Pump Pipeline — Health Check           ║"
    echo "║     Avvio: $(date '+%Y-%m-%d %H:%M:%S')                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Esegui tutti i controlli
    check_oracle_env
    check_oracle_client
    check_oci_cli
    check_db_connectivity "${connect_string}"
    check_disk_space
    check_datapump_jobs "${connect_string}"
    check_listener
    check_utilities

    # Report finale
    print_report
    local final_exit=$?

    # Output JSON per integrazione pipeline
    echo ""
    echo "--- JSON Report ---"
    echo "{\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"total\":${TOTAL_CHECKS},\"passed\":${PASSED_CHECKS},\"failed\":${FAILED_CHECKS},\"warnings\":${WARNING_CHECKS},\"critical\":${CRITICAL_FAILURE},\"exit_code\":${final_exit}}"

    exit ${final_exit}
}

main "$@"
