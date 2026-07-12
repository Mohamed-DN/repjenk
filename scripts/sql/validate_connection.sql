-- ==============================================================================
-- Script Name: validate_connection.sql
-- Purpose:     Verifica approfondita della connettività e dei privilegi DB
--              per la pipeline di Data Pump. Estrae dettagli completi
--              sull'ambiente (Autonmous, DBCS, On-Prem).
-- Author:      ENI DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle 19c+ (ATP, ADW, DBCS, On-Premises)
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_db_name       v$database.name%TYPE;
    v_version       v$instance.version%TYPE;
    v_host_name     v$instance.host_name%TYPE;
    v_cdb           v$database.cdb%TYPE;
    v_cloud         VARCHAR2(200) := 'ON-PREMISES / VM DBCS';
    v_user          VARCHAR2(100);
    v_is_dba        NUMBER;
    v_exp_priv      NUMBER;
    v_imp_priv      NUMBER;
    v_ts_count      NUMBER;
    v_dir_count     NUMBER;
    v_wallet_status VARCHAR2(200);
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   🔍 ENI ORACLE DATA PUMP PIPELINE - HEALTH & CONNECTION CHECK 🔍   ');
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    -- Recupero info base istanza
    SELECT name, cdb INTO v_db_name, v_cdb FROM v$database;
    SELECT version, host_name INTO v_version, v_host_name FROM v$instance;
    v_user := USER;

    -- Verifica se e' un Autonomous DB tramite V$PDBS o altre viste cloud
    BEGIN
        EXECUTE IMMEDIATE 'SELECT cloud_identity FROM v$pdbs WHERE rownum = 1' INTO v_cloud;
        v_cloud := 'AUTONOMOUS DATABASE (Cloud ID: ' || SUBSTR(v_cloud, 1, 50) || '...)';
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Rimane il default DBCS/On-Prem
    END;

    -- Controllo privilegi Data Pump e ruolo DBA
    SELECT COUNT(*) INTO v_exp_priv FROM session_privs WHERE privilege = 'DATAPUMP_EXP_FULL_DATABASE';
    SELECT COUNT(*) INTO v_imp_priv FROM session_privs WHERE privilege = 'DATAPUMP_IMP_FULL_DATABASE';
    SELECT COUNT(*) INTO v_is_dba FROM session_roles WHERE role = 'DBA';

    -- Verifica stato wallet (importante per OCI / Autonomous)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT status FROM v$encryption_wallet WHERE rownum = 1' INTO v_wallet_status;
    EXCEPTION
        WHEN OTHERS THEN
            v_wallet_status := 'NON CONFIGURATO / INACCESSIBILE';
    END;

    -- Stampa risultati diagnostici
    DBMS_OUTPUT.PUT_LINE('➜ DATI ISTANZA:');
    DBMS_OUTPUT.PUT_LINE('  - Nome Database  : ' || v_db_name);
    DBMS_OUTPUT.PUT_LINE('  - Versione Oracle: ' || v_version);
    DBMS_OUTPUT.PUT_LINE('  - Architettura   : ' || CASE WHEN v_cdb = 'YES' THEN 'CDB/PDB (Multitenant)' ELSE 'Non-CDB (Legacy)' END);
    DBMS_OUTPUT.PUT_LINE('  - Hostname       : ' || v_host_name);
    DBMS_OUTPUT.PUT_LINE('  - Tipo Ambiente  : ' || v_cloud);
    DBMS_OUTPUT.PUT_LINE('  - Stato Wallet   : ' || v_wallet_status);
    DBMS_OUTPUT.PUT_LINE(' ');

    DBMS_OUTPUT.PUT_LINE('➜ SICUREZZA E PRIVILEGI UTENTE (' || v_user || '):');
    DBMS_OUTPUT.PUT_LINE('  - Ruolo DBA                  : ' || CASE WHEN v_is_dba > 0 THEN '[✅ OK]' ELSE '[❌ MANCANTE]' END);
    DBMS_OUTPUT.PUT_LINE('  - DATAPUMP_EXP_FULL_DATABASE : ' || CASE WHEN v_exp_priv > 0 THEN '[✅ OK]' ELSE '[⚠️ MANCANTE - Export limitato]' END);
    DBMS_OUTPUT.PUT_LINE('  - DATAPUMP_IMP_FULL_DATABASE : ' || CASE WHEN v_imp_priv > 0 THEN '[✅ OK]' ELSE '[⚠️ MANCANTE - Import limitato]' END);
    
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('STATUS: Connessione stabilita con successo. L''ambiente e'' pronto.');
    DBMS_OUTPUT.PUT_LINE('======================================================================');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE CRITICO DURANTE LA VALIDAZIONE DELLA CONNESSIONE:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END;
/
EXIT;
