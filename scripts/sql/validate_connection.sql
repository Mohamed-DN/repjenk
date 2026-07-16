-- =========================================================================================
-- SCRIPT NAME: validate_connection.sql
-- PURPOSE:     Verifica approfondita della connettività e dei privilegi DB per la pipeline
--              di Data Pump. Estrae dettagli completi sull'ambiente (Autonomous, DBCS, On-Prem).
--              Identifica eventuali mancanze di ruoli e verifica lo stato del wallet OCI.
-- AUTHOR:      DARKNERO DBA Team (Generato tramite Automazione)
-- DATE:        2026-07-12
-- PLATFORM:    Oracle 19c+ (ATP, ADW, DBCS, On-Premises)
-- =========================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 300
SET PAGESIZE 200
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF

-- Uscita automatica in caso di errore SQL per far fallire il job Jenkins
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    -- Variabili per informazioni di base
    v_db_name          v$database.name%TYPE;
    v_version          v$instance.version%TYPE;
    v_host_name        v$instance.host_name%TYPE;
    v_cdb              v$database.cdb%TYPE;
    v_db_role          v$database.database_role%TYPE;
    
    -- Variabili per la detection dell'ambiente Cloud
    v_cloud_env        VARCHAR2(200) := 'ON-PREMISES / VM DBCS';
    v_is_autonomous    BOOLEAN := FALSE;
    
    -- Variabili per ruoli e privilegi
    v_user             VARCHAR2(100);
    v_is_dba           NUMBER := 0;
    v_exp_priv         NUMBER := 0;
    v_imp_priv         NUMBER := 0;
    v_read_dir_priv    NUMBER := 0;
    v_write_dir_priv   NUMBER := 0;
    
    -- Variabili per lo stato del Wallet (Cruciale per OCI Object Storage)
    v_wallet_status    VARCHAR2(200) := 'NON CONFIGURATO';
    v_wallet_type      VARCHAR2(100) := 'N/A';
    
    -- Error handling
    e_missing_privs    EXCEPTION;
BEGIN
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('   🔍 DARKNERO ORACLE DATA PUMP PIPELINE - HEALTH & CONNECTION DIAGNOSTICS 🔍');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('Time: ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS TZR'));
    DBMS_OUTPUT.PUT_LINE('User: ' || SYS_CONTEXT('USERENV', 'SESSION_USER'));

    -- 1. Recupero Info Istanza e Database
    BEGIN
        SELECT name, cdb, database_role INTO v_db_name, v_cdb, v_db_role FROM v$database;
        SELECT version, host_name INTO v_version, v_host_name FROM v$instance;
        v_user := SYS_CONTEXT('USERENV', 'SESSION_USER');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('❌ ERRORE: Impossibile leggere le viste V$DATABASE o V$INSTANCE. Privilegi insufficienti?');
            RAISE;
    END;

    -- 2. Identificazione Ambiente (Autonomous vs DBCS vs On-Prem)
    BEGIN
        -- Su Autonomous Database, la vista V$PDBS contiene la colonna CLOUD_IDENTITY
        EXECUTE IMMEDIATE 'SELECT cloud_identity FROM v$pdbs WHERE rownum = 1' INTO v_cloud_env;
        IF v_cloud_env IS NOT NULL THEN
            v_cloud_env := 'AUTONOMOUS DATABASE (OCI)';
            v_is_autonomous := TRUE;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Se la colonna o la vista non esiste, l'ambiente è probabilmente DBCS o On-Premise
            v_cloud_env := 'ORACLE DATABASE CLOUD SERVICE (DBCS) / ON-PREMISES';
    END;

    -- 3. Verifica Privilegi e Ruoli Data Pump
    SELECT COUNT(*) INTO v_exp_priv FROM session_privs WHERE privilege = 'DATAPUMP_EXP_FULL_DATABASE';
    SELECT COUNT(*) INTO v_imp_priv FROM session_privs WHERE privilege = 'DATAPUMP_IMP_FULL_DATABASE';
    SELECT COUNT(*) INTO v_is_dba FROM session_roles WHERE role = 'DBA';
    
    -- Verifica privilegi sulle directory (DATA_PUMP_DIR di default)
    SELECT COUNT(*) INTO v_read_dir_priv FROM all_tab_privs WHERE table_name = 'DATA_PUMP_DIR' AND privilege = 'READ';
    SELECT COUNT(*) INTO v_write_dir_priv FROM all_tab_privs WHERE table_name = 'DATA_PUMP_DIR' AND privilege = 'WRITE';

    -- 4. Verifica Stato Wallet (Necessario per l'integrazione OCI Object Storage)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT status, wallet_type FROM v$encryption_wallet WHERE rownum = 1' INTO v_wallet_status, v_wallet_type;
    EXCEPTION
        WHEN OTHERS THEN
            v_wallet_status := 'ACCESSO NEGATO / NON PRESENTE';
            v_wallet_type   := 'N/A';
    END;

    -- 5. Stampa Report Diagnostico
    DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ INFORMAZIONI DATABASE:');
    DBMS_OUTPUT.PUT_LINE('  - Nome Database  : ' || v_db_name);
    DBMS_OUTPUT.PUT_LINE('  - Versione Oracle: ' || v_version);
    DBMS_OUTPUT.PUT_LINE('  - Architettura   : ' || CASE WHEN v_cdb = 'YES' THEN 'CDB/PDB (Multitenant)' ELSE 'Non-CDB (Legacy)' END);
    DBMS_OUTPUT.PUT_LINE('  - Ruolo          : ' || v_db_role);
    DBMS_OUTPUT.PUT_LINE('  - Hostname       : ' || v_host_name);
    DBMS_OUTPUT.PUT_LINE('  - Tipo Ambiente  : ' || v_cloud_env);

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ CONFIGURAZIONE SICUREZZA (Utente: ' || v_user || '):');
    DBMS_OUTPUT.PUT_LINE('  - Ruolo DBA                  : ' || CASE WHEN v_is_dba > 0 THEN '✅ PRESENTE' ELSE '❌ MANCANTE' END);
    DBMS_OUTPUT.PUT_LINE('  - DATAPUMP_EXP_FULL_DATABASE : ' || CASE WHEN v_exp_priv > 0 THEN '✅ PRESENTE' ELSE '⚠️ MANCANTE (Export solo per schema proprietario)' END);
    DBMS_OUTPUT.PUT_LINE('  - DATAPUMP_IMP_FULL_DATABASE : ' || CASE WHEN v_imp_priv > 0 THEN '✅ PRESENTE' ELSE '⚠️ MANCANTE (Import solo per schema proprietario)' END);
    DBMS_OUTPUT.PUT_LINE('  - DATA_PUMP_DIR READ Access  : ' || CASE WHEN v_read_dir_priv > 0 OR v_is_dba > 0 THEN '✅ PRESENTE' ELSE '❌ MANCANTE' END);
    DBMS_OUTPUT.PUT_LINE('  - DATA_PUMP_DIR WRITE Access : ' || CASE WHEN v_write_dir_priv > 0 OR v_is_dba > 0 THEN '✅ PRESENTE' ELSE '❌ MANCANTE' END);

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ STATO OCI INTEGRATION (Wallet):');
    DBMS_OUTPUT.PUT_LINE('  - Stato Wallet               : ' || v_wallet_status);
    DBMS_OUTPUT.PUT_LINE('  - Tipo Wallet                : ' || v_wallet_type);

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '================================================================================');
    
    -- Valutazione Finale e Alert
    IF v_exp_priv = 0 AND v_imp_priv = 0 THEN
        DBMS_OUTPUT.PUT_LINE('❌ CRITICAL: L''utente non possiede i privilegi minimi per Data Pump Full.');
        DBMS_OUTPUT.PUT_LINE('             La pipeline potrebbe fallire durante l''operazione.');
        RAISE e_missing_privs;
    ELSE
        DBMS_OUTPUT.PUT_LINE('✅ STATUS: Connessione stabilita con successo. L''ambiente e'' pronto.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('================================================================================');

EXCEPTION
    WHEN e_missing_privs THEN
        RAISE_APPLICATION_ERROR(-20001, 'Privilegi Data Pump insufficienti per l''utente ' || v_user);
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE IMPREVISTO DURANTE LA DIAGNOSTICA:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END;
/
EXIT;
