-- =========================================================================================
-- SCRIPT NAME: check_schema_exists.sql
-- PURPOSE:     Verifica approfondita dell'esistenza e dello stato di uno schema Oracle.
--              Analizza stato account, lock, tablespace di default, profili, e
--              consistenza degli oggetti (identifica oggetti invalidi prima dell'import).
-- PARAMETERS:  &1 = Schema Name
-- AUTHOR:      ACME DBA Team (Generato tramite Automazione)
-- DATE:        2026-07-12
-- =========================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 300
SET PAGESIZE 200
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema_name      VARCHAR2(128) := UPPER(TRIM('&1'));
    v_count            NUMBER := 0;
    v_status           dba_users.account_status%TYPE;
    v_ts               dba_users.default_tablespace%TYPE;
    v_temp_ts          dba_users.temporary_tablespace%TYPE;
    v_profile          dba_users.profile%TYPE;
    v_created          dba_users.created%TYPE;
    v_last_login       dba_users.last_login%TYPE;
    
    v_obj_count        NUMBER := 0;
    v_invalid_count    NUMBER := 0;
    v_size_mb          NUMBER := 0;
    
    v_session_count    NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('   🔍 ANALISI ESISTENZA SCHEMA: ' || v_schema_name);
    DBMS_OUTPUT.PUT_LINE('================================================================================');

    IF v_schema_name IS NULL OR v_schema_name = '' THEN
        RAISE_APPLICATION_ERROR(-20002, 'Nessun nome schema fornito.');
    END IF;

    -- 1. Verifica Esistenza Utente
    SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = v_schema_name;
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('RESULT: SCHEMA_NOT_FOUND');
        DBMS_OUTPUT.PUT_LINE('INFO: Lo schema [' || v_schema_name || '] non esiste attualmente nel database.');
        DBMS_OUTPUT.PUT_LINE('Azione: La pipeline Jenkins creerà automaticamente lo schema durante l''import');
        DBMS_OUTPUT.PUT_LINE('        (assumendo che INCLUDE_GRANTS sia attivo e il file di dump contenga l''utente).');
    ELSE
        -- 2. Dettagli Utente Esistente
        SELECT account_status, default_tablespace, temporary_tablespace, profile, created, last_login 
        INTO v_status, v_ts, v_temp_ts, v_profile, v_created, v_last_login
        FROM dba_users WHERE username = v_schema_name;
        
        -- 3. Analisi Oggetti
        SELECT COUNT(*) INTO v_obj_count FROM dba_objects WHERE owner = v_schema_name;
        SELECT COUNT(*) INTO v_invalid_count FROM dba_objects WHERE owner = v_schema_name AND status = 'INVALID';
        SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_size_mb FROM dba_segments WHERE owner = v_schema_name;
        
        -- 4. Analisi Sessioni Attive (Importante per evitare lock in fase di DROP/REPLACE)
        SELECT COUNT(*) INTO v_session_count FROM gv$session WHERE username = v_schema_name;
        
        DBMS_OUTPUT.PUT_LINE('RESULT: SCHEMA_EXISTS');
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ DETTAGLI ACCOUNT:');
        DBMS_OUTPUT.PUT_LINE('  - Stato Account      : ' || CASE WHEN v_status LIKE '%LOCKED%' THEN '🔒 ' ELSE '✅ ' END || v_status);
        DBMS_OUTPUT.PUT_LINE('  - Data Creazione     : ' || TO_CHAR(v_created, 'DD/MM/YYYY HH24:MI:SS'));
        DBMS_OUTPUT.PUT_LINE('  - Ultimo Login       : ' || NVL(TO_CHAR(v_last_login, 'DD/MM/YYYY HH24:MI:SS TZR'), 'MAI'));
        DBMS_OUTPUT.PUT_LINE('  - Profilo Assegnato  : ' || v_profile);
        DBMS_OUTPUT.PUT_LINE('  - Def. Tablespace    : ' || v_ts);
        DBMS_OUTPUT.PUT_LINE('  - Temp Tablespace    : ' || v_temp_ts);
        
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ DETTAGLI CONTENUTO SCHEMA:');
        DBMS_OUTPUT.PUT_LINE('  - Spazio Allocato    : ' || ROUND(v_size_mb, 2) || ' MB');
        DBMS_OUTPUT.PUT_LINE('  - Oggetti Totali     : ' || v_obj_count);
        DBMS_OUTPUT.PUT_LINE('  - Oggetti Invalidi   : ' || CASE WHEN v_invalid_count > 0 THEN '⚠️ ' || v_invalid_count ELSE '✅ 0' END);
        
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '➜ ATTIVITA'' DI RETE E LOCK:');
        DBMS_OUTPUT.PUT_LINE('  - Sessioni Attive    : ' || CASE WHEN v_session_count > 0 THEN '⚠️ ' || v_session_count || ' (Potenziale rischio di lock)' ELSE '✅ 0' END);
        
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '================================================================================');
        DBMS_OUTPUT.PUT_LINE('ATTENZIONE: Poiche'' lo schema esiste gia'', le operazioni di import richiederanno');
        DBMS_OUTPUT.PUT_LINE('l''uso del parametro TABLE_EXISTS_ACTION (es. REPLACE, TRUNCATE, APPEND) oppure');
        DBMS_OUTPUT.PUT_LINE('l''utilizzo della funzione SWAP_AND_DROP per importare in un nuovo schema parallelo.');
        DBMS_OUTPUT.PUT_LINE('================================================================================');
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE CRITICO DURANTE IL CONTROLLO DELLO SCHEMA:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END;
/
EXIT;
