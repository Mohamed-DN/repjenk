-- ==============================================================================
-- Script Name: check_schema_exists.sql
-- Purpose:     Verifica approfondita dell'esistenza e dello stato di uno schema
--              (lock, profile, tablespace, oggetti presenti).
-- Parameters:  &1 = Schema Name
-- Author:      ENI DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle 19c+ 
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema_name VARCHAR2(128) := UPPER(TRIM('&1'));
    v_count       NUMBER;
    v_status      dba_users.account_status%TYPE;
    v_ts          dba_users.default_tablespace%TYPE;
    v_temp_ts     dba_users.temporary_tablespace%TYPE;
    v_profile     dba_users.profile%TYPE;
    v_created     dba_users.created%TYPE;
    v_obj_count   NUMBER;
    v_size_mb     NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   🔍 ANALISI ESISTENZA SCHEMA: ' || v_schema_name);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    -- Verifica esistenza utente
    SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = v_schema_name;
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('RESULT: SCHEMA_NOT_FOUND');
        DBMS_OUTPUT.PUT_LINE('INFO: Lo schema [' || v_schema_name || '] non esiste nel database.');
        DBMS_OUTPUT.PUT_LINE('Azione suggerita: E'' possibile procedere con un import completo (creazione automatica).');
    ELSE
        -- Recupero dettagli utente
        SELECT account_status, default_tablespace, temporary_tablespace, profile, created 
        INTO v_status, v_ts, v_temp_ts, v_profile, v_created 
        FROM dba_users WHERE username = v_schema_name;
        
        -- Conta gli oggetti esistenti
        SELECT COUNT(*) INTO v_obj_count FROM dba_objects WHERE owner = v_schema_name;
        
        -- Calcola spazio occupato
        SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_size_mb FROM dba_segments WHERE owner = v_schema_name;
        
        DBMS_OUTPUT.PUT_LINE('RESULT: SCHEMA_EXISTS');
        DBMS_OUTPUT.PUT_LINE('➜ DETTAGLI UTENTE:');
        DBMS_OUTPUT.PUT_LINE('  - Stato Account      : ' || CASE WHEN v_status LIKE '%LOCKED%' THEN '🔒 ' ELSE '✅ ' END || v_status);
        DBMS_OUTPUT.PUT_LINE('  - Data Creazione     : ' || TO_CHAR(v_created, 'DD/MM/YYYY HH24:MI:SS'));
        DBMS_OUTPUT.PUT_LINE('  - Profilo Assegnato  : ' || v_profile);
        DBMS_OUTPUT.PUT_LINE('  - Def. Tablespace    : ' || v_ts);
        DBMS_OUTPUT.PUT_LINE('  - Temp Tablespace    : ' || v_temp_ts);
        DBMS_OUTPUT.PUT_LINE(' ');
        DBMS_OUTPUT.PUT_LINE('➜ DETTAGLI CONTENUTO:');
        DBMS_OUTPUT.PUT_LINE('  - Oggetti Totali     : ' || v_obj_count);
        DBMS_OUTPUT.PUT_LINE('  - Spazio Occupato    : ' || ROUND(v_size_mb, 2) || ' MB');
        
        DBMS_OUTPUT.PUT_LINE('======================================================================');
        DBMS_OUTPUT.PUT_LINE('ATTENZIONE: Lo schema esiste gia''. Se si procede con l''import senza REMAP,');
        DBMS_OUTPUT.PUT_LINE('assicurarsi di aver impostato correttamente TABLE_EXISTS_ACTION.');
        DBMS_OUTPUT.PUT_LINE('======================================================================');
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE CRITICO DURANTE IL CONTROLLO DELLO SCHEMA:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END;
/
EXIT;
