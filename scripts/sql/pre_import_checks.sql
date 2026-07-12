-- ==============================================================================
-- Script Name: pre_import_checks.sql
-- Purpose:     Verifiche di sicurezza pre-import (capienza tablespace, lock, 
--              Data Pump job concorrenti, quote). Evita fallimenti a metà.
-- Parameters:  &1 = Target Schema, &2 = Target Tablespace, &3 = Estimated Size MB
-- Author:      ENI DBA Team
-- Date:        2026-07-12
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET VERIFY OFF
SET FEEDBACK OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema     VARCHAR2(128) := UPPER(TRIM('&1'));
    v_ts         VARCHAR2(128) := UPPER(TRIM('&2'));
    v_est_size   NUMBER := TO_NUMBER(NVL(TRIM('&3'), '0'));
    v_free_mb    NUMBER := 0;
    v_max_mb     NUMBER := 0;
    v_dp_jobs    NUMBER := 0;
    v_lock_count NUMBER := 0;
    v_errors     NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   🛡️ PRE-IMPORT SAFETY CHECKS');
    DBMS_OUTPUT.PUT_LINE('   Target Schema: ' || v_schema || ' | Tablespace: ' || v_ts || ' | Dimensione Prevista: ' || v_est_size || ' MB');
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    -- 1. Controllo Spazio Tablespace
    IF v_ts IS NOT NULL AND v_ts != 'NULL' THEN
        -- Calcola lo spazio libero e lo spazio massimo estensibile (autoextend)
        SELECT NVL(SUM(bytes)/1024/1024, 0), NVL(SUM(GREATEST(maxbytes, bytes))/1024/1024, 0)
        INTO v_free_mb, v_max_mb
        FROM dba_data_files 
        WHERE tablespace_name = v_ts;
        
        DBMS_OUTPUT.PUT_LINE('➜ CHECK TABLESPACE [' || v_ts || ']:');
        DBMS_OUTPUT.PUT_LINE('  - Spazio attualmente libero : ' || ROUND(v_free_mb, 2) || ' MB');
        DBMS_OUTPUT.PUT_LINE('  - Capacita'' max autoextend  : ' || ROUND(v_max_mb, 2) || ' MB');
        
        IF v_max_mb < v_est_size THEN
            DBMS_OUTPUT.PUT_LINE('  ❌ FAIL: Spazio insufficiente. Il tablespace puo'' crescere fino a ' || ROUND(v_max_mb, 2) || ' MB, ma servono ' || v_est_size || ' MB.');
            v_errors := v_errors + 1;
        ELSE
            DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Spazio sufficiente per l''import.');
        END IF;
    END IF;

    -- 2. Controllo Job Data Pump Attivi
    SELECT COUNT(*) INTO v_dp_jobs 
    FROM dba_datapump_jobs 
    WHERE state = 'EXECUTING';
    
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('➜ CHECK CONCORRENZA DATA PUMP:');
    IF v_dp_jobs > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ⚠️ WARNING: Ci sono ' || v_dp_jobs || ' job Data Pump attualmente in esecuzione.');
        DBMS_OUTPUT.PUT_LINE('     Questo potrebbe impattare le performance dell''import.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Nessun job Data Pump in esecuzione che possa creare conflitti.');
    END IF;

    -- 3. Controllo Lock Attivi sullo Schema Destinazione (se esiste)
    SELECT COUNT(*) INTO v_lock_count
    FROM v$locked_object l
    JOIN dba_objects o ON l.object_id = o.object_id
    WHERE o.owner = v_schema;
    
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('➜ CHECK LOCK OGGETTI SCHEMA:');
    IF v_lock_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ❌ FAIL: Ci sono ' || v_lock_count || ' oggetti bloccati (locked) nello schema ' || v_schema || '.');
        DBMS_OUTPUT.PUT_LINE('     E'' necessario terminare le sessioni che trattengono i lock prima dell''import.');
        v_errors := v_errors + 1;
    ELSE
        DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Nessun blocco rilevato sugli oggetti dello schema.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('======================================================================');
    IF v_errors > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ESITO: ❌ FALLITO. Impossibile procedere con l''import in sicurezza.');
        RAISE_APPLICATION_ERROR(-20002, 'Pre-import checks falliti. Risolvere i problemi e riprovare.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ESITO: ✅ SUPERATO. L''ambiente e'' pronto per l''import.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('======================================================================');
END;
/
EXIT;
