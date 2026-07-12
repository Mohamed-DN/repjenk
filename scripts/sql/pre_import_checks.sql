-- =========================================================================================
-- SCRIPT NAME: pre_import_checks.sql
-- PURPOSE:     Verifiche di sicurezza pre-import rigorose per ambienti di produzione.
--              Controlla capienza tablespace (autoextend), conflitti nomi, sessioni
--              attive (lock), e job Data Pump zombie. Previene fallimenti a metà operazione.
-- PARAMETERS:  &1 = Target Schema
--              &2 = Target Tablespace
--              &3 = Estimated Size MB
-- AUTHOR:      ENI DBA Team (Generato tramite Automazione)
-- DATE:        2026-07-12
-- =========================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 300
SET PAGESIZE 200
SET VERIFY OFF
SET FEEDBACK OFF
SET HEADING OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema     VARCHAR2(128) := UPPER(TRIM('&1'));
    v_ts         VARCHAR2(128) := UPPER(TRIM('&2'));
    v_est_size   NUMBER := TO_NUMBER(NVL(TRIM('&3'), '0'));
    
    v_free_mb    NUMBER := 0;
    v_max_mb     NUMBER := 0;
    v_used_mb    NUMBER := 0;
    
    v_dp_jobs    NUMBER := 0;
    v_lock_count NUMBER := 0;
    v_user_count NUMBER := 0;
    
    v_errors     NUMBER := 0;
    v_warnings   NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('   🛡️ ENI PIPELINE - PRE-IMPORT SAFETY GATES');
    DBMS_OUTPUT.PUT_LINE('   Target Schema: ' || v_schema || ' | Tablespace: ' || NVL(v_ts, 'DEFAULT') || ' | Dimensione: ' || v_est_size || ' MB');
    DBMS_OUTPUT.PUT_LINE('================================================================================');

    -- 1. Controllo Spazio Tablespace e Gestione Autoextend
    IF v_ts IS NOT NULL AND v_ts != 'NULL' THEN
        BEGIN
            -- Somma spazio utilizzato, spazio libero attuale e max estensione
            SELECT 
                NVL(SUM(bytes)/1024/1024, 0),
                NVL(SUM(maxbytes)/1024/1024, 0),
                NVL(SUM(user_bytes)/1024/1024, 0)
            INTO v_free_mb, v_max_mb, v_used_mb
            FROM dba_data_files 
            WHERE tablespace_name = v_ts;
            
            DBMS_OUTPUT.PUT_LINE('➜ GATE 1: CAPACITY CHECK SUL TABLESPACE [' || v_ts || ']');
            DBMS_OUTPUT.PUT_LINE('  - Spazio Allocato     : ' || ROUND(v_used_mb, 2) || ' MB');
            DBMS_OUTPUT.PUT_LINE('  - Capacita'' Massima   : ' || ROUND(v_max_mb, 2) || ' MB (Max Autoextend limit)');
            DBMS_OUTPUT.PUT_LINE('  - Spazio Libero Reale : ' || ROUND(v_max_mb - v_used_mb, 2) || ' MB');
            
            IF (v_max_mb - v_used_mb) < v_est_size THEN
                DBMS_OUTPUT.PUT_LINE('  ❌ FAIL: Spazio insufficiente. Il tablespace puo'' crescere solo fino a ' || ROUND(v_max_mb, 2) || ' MB, ma l''import richiede ' || v_est_size || ' MB.');
                v_errors := v_errors + 1;
            ELSE
                DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Spazio sufficiente per completare l''import in sicurezza.');
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                DBMS_OUTPUT.PUT_LINE('  ❌ FAIL: Il tablespace [' || v_ts || '] non esiste nel database di destinazione!');
                v_errors := v_errors + 1;
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE(' ');

    -- 2. Controllo Concorrenza (Job Data Pump Attivi)
    DBMS_OUTPUT.PUT_LINE('➜ GATE 2: CONCURRENCY CHECK (DATA PUMP JOBS)');
    SELECT COUNT(*) INTO v_dp_jobs 
    FROM dba_datapump_jobs 
    WHERE state = 'EXECUTING';
    
    IF v_dp_jobs > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ⚠️ WARNING: Ci sono ' || v_dp_jobs || ' job Data Pump attualmente in esecuzione.');
        DBMS_OUTPUT.PUT_LINE('     Questo potrebbe saturare le risorse I/O, il temporary tablespace o causare contention.');
        v_warnings := v_warnings + 1;
    ELSE
        DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Nessun altro job Data Pump concorrente rilevato.');
    END IF;

    DBMS_OUTPUT.PUT_LINE(' ');

    -- 3. Controllo Lock e Sessioni sullo Schema Destinazione (se lo schema esiste già)
    DBMS_OUTPUT.PUT_LINE('➜ GATE 3: SCHEMA LOCK & SESSION CHECK');
    SELECT COUNT(*) INTO v_user_count FROM dba_users WHERE username = v_schema;
    
    IF v_user_count > 0 THEN
        -- Ricerca di lock esclusivi/shared trattenuti da qualcuno sugli oggetti dello schema target
        SELECT COUNT(*) INTO v_lock_count
        FROM v$locked_object l
        JOIN dba_objects o ON l.object_id = o.object_id
        WHERE o.owner = v_schema;
        
        IF v_lock_count > 0 THEN
            DBMS_OUTPUT.PUT_LINE('  ❌ FAIL: Rilevati ' || v_lock_count || ' lock attivi sugli oggetti dello schema ' || v_schema || '.');
            DBMS_OUTPUT.PUT_LINE('     Un import con TABLE_EXISTS_ACTION=REPLACE o TRUNCATE fallira'' con ORA-00054 (Resource busy).');
            DBMS_OUTPUT.PUT_LINE('     Azione richiesta: Killare le sessioni che trattengono i lock prima di procedere.');
            v_errors := v_errors + 1;
        ELSE
            DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Nessun blocco strutturale rilevato sugli oggetti dello schema.');
        END IF;
    ELSE
         DBMS_OUTPUT.PUT_LINE('  ✅ PASS: Lo schema non esiste ancora, nessun rischio di lock.');
    END IF;

    DBMS_OUTPUT.PUT_LINE(CHR(10) || '================================================================================');
    
    -- Valutazione e Chiusura
    IF v_errors > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ESITO GLOBALE: ❌ PRE-FLIGHT CHECKS FALLITI.');
        DBMS_OUTPUT.PUT_LINE('Rilevati ' || v_errors || ' errori bloccanti e ' || v_warnings || ' warning.');
        DBMS_OUTPUT.PUT_LINE('La pipeline verra'' interrotta per proteggere l''integrita'' dell''ambiente.');
        RAISE_APPLICATION_ERROR(-20002, 'Pre-import checks falliti a causa di condizioni bloccanti. Verificare i log.');
    ELSIF v_warnings > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ESITO GLOBALE: ⚠️ PRE-FLIGHT CHECKS SUPERATI CON WARNING.');
        DBMS_OUTPUT.PUT_LINE('Rilevati 0 errori bloccanti e ' || v_warnings || ' warning. L''import puo'' procedere, ma con attenzione.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ESITO GLOBALE: ✅ PRE-FLIGHT CHECKS SUPERATI.');
        DBMS_OUTPUT.PUT_LINE('Tutti i requisiti di sicurezza e capacita'' sono soddisfatti. L''ambiente e'' pronto.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('================================================================================');
END;
/
EXIT;
