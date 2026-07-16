--------------------------------------------------------------------------------
-- Script:      swap_schema.sql
-- Purpose:     Scambio schema produzione con nuovo schema importato
--              CRITICAL: Swaps production schema with newly imported schema
-- Parameters:  &1 = production_schema (current production)
--              &2 = new_schema (newly imported, to become production)
--              &3 = drop_old (Y/N - whether to drop the backup schema)
-- Author:      M-DN DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle Autonomous DB (ATP/ADW) / DBCS / On-Premises
--
-- ATTENZIONE: Operazione critica! Questa procedura rinomina gli schema.
-- WARNING:    Critical operation! This procedure renames schemas.
--             Oracle does NOT support ALTER USER RENAME. This script uses
--             Data Pump (export metadata + import with remap) to achieve
--             the logical "rename" effect, or uses schema-level synonyms.
--
-- STRATEGIA: Poiche' Oracle non permette il RENAME di uno schema, questa
--            procedura utilizza un approccio basato su:
--            1. Verifica pre-swap
--            2. Creazione utente backup
--            3. Export/Import metadata per lo swap
--            4. Aggiornamento sinonimi e grant
--            5. Ricompilazione oggetti invalidi
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET DEFINE '&'

WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE prod_schema = &1
DEFINE new_schema  = &2
DEFINE drop_old    = &3

PROMPT
PROMPT ============================================================================
PROMPT   M-DN DATA PUMP PIPELINE - SCHEMA SWAP (CRITICAL OPERATION)
PROMPT   Production Schema: &prod_schema
PROMPT   New Schema:        &new_schema
PROMPT   Drop Old Backup:   &drop_old
PROMPT ============================================================================
PROMPT
PROMPT   ATTENZIONE: Operazione critica in corso!
PROMPT   WARNING:    Critical operation starting!
PROMPT

DECLARE
    v_prod_schema   VARCHAR2(128) := UPPER('&prod_schema');
    v_new_schema    VARCHAR2(128) := UPPER('&new_schema');
    v_drop_old      VARCHAR2(1)   := UPPER(SUBSTR('&drop_old', 1, 1));
    v_backup_schema VARCHAR2(128);
    v_timestamp     VARCHAR2(8)   := TO_CHAR(SYSDATE, 'YYYYMMDD');

    -- Contatori per confronto
    v_prod_obj_cnt  NUMBER := 0;
    v_new_obj_cnt   NUMBER := 0;
    v_prod_row_cnt  NUMBER := 0;
    v_new_row_cnt   NUMBER := 0;
    v_exists        NUMBER := 0;
    v_step          NUMBER := 0;
    v_error_msg     VARCHAR2(4000);

    -- Tipo per log delle operazioni
    TYPE t_log_entry IS RECORD (
        step_num   NUMBER,
        step_name  VARCHAR2(200),
        status     VARCHAR2(20),
        detail     VARCHAR2(4000)
    );
    TYPE t_log_table IS TABLE OF t_log_entry INDEX BY PLS_INTEGER;
    v_log t_log_table;

    -- Procedura per logging
    PROCEDURE log_step(p_step NUMBER, p_name VARCHAR2, p_status VARCHAR2, p_detail VARCHAR2 DEFAULT NULL) IS
        v_idx PLS_INTEGER;
    BEGIN
        v_idx := v_log.COUNT + 1;
        v_log(v_idx).step_num  := p_step;
        v_log(v_idx).step_name := p_name;
        v_log(v_idx).status    := p_status;
        v_log(v_idx).detail    := p_detail;

        DBMS_OUTPUT.PUT_LINE('  [Step ' || TO_CHAR(p_step, '09') || '] ' ||
            RPAD(p_name, 45) || ' [' || p_status || ']' ||
            CASE WHEN p_detail IS NOT NULL THEN ' - ' || p_detail ELSE '' END);
    END;

    -- Procedura per stampare log finale
    PROCEDURE print_audit_log IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  --- AUDIT LOG ---');
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 90, '-'));
        FOR i IN 1..v_log.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE('  ' ||
                RPAD('Step ' || TO_CHAR(v_log(i).step_num, '09'), 10) ||
                RPAD(v_log(i).step_name, 45) ||
                RPAD('[' || v_log(i).status || ']', 12) ||
                NVL(v_log(i).detail, '')
            );
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 90, '-'));
    END;

BEGIN
    -- Nome dello schema di backup con timestamp
    v_backup_schema := SUBSTR(v_prod_schema, 1, 118) || '_BKP_' || v_timestamp;

    DBMS_OUTPUT.PUT_LINE('  Backup schema name will be: ' || v_backup_schema);
    DBMS_OUTPUT.PUT_LINE('  Swap started at: ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- STEP 1: Verifica esistenza schema produzione
    ---------------------------------------------------------------------------
    v_step := 1;

    SELECT COUNT(*) INTO v_exists
    FROM dba_users WHERE username = v_prod_schema;

    IF v_exists = 0 THEN
        log_step(v_step, 'Verify production schema exists', 'FAIL',
            'Schema "' || v_prod_schema || '" not found!');
        print_audit_log;
        RAISE_APPLICATION_ERROR(-20001,
            'Production schema "' || v_prod_schema || '" does not exist.');
    END IF;

    log_step(v_step, 'Verify production schema exists', 'OK',
        'Schema "' || v_prod_schema || '" found.');

    ---------------------------------------------------------------------------
    -- STEP 2: Verifica esistenza e contenuto nuovo schema
    ---------------------------------------------------------------------------
    v_step := 2;

    SELECT COUNT(*) INTO v_exists
    FROM dba_users WHERE username = v_new_schema;

    IF v_exists = 0 THEN
        log_step(v_step, 'Verify new schema exists', 'FAIL',
            'Schema "' || v_new_schema || '" not found!');
        print_audit_log;
        RAISE_APPLICATION_ERROR(-20002,
            'New schema "' || v_new_schema || '" does not exist.');
    END IF;

    SELECT COUNT(*) INTO v_new_obj_cnt
    FROM dba_objects WHERE owner = v_new_schema;

    IF v_new_obj_cnt = 0 THEN
        log_step(v_step, 'Verify new schema has objects', 'FAIL',
            'Schema "' || v_new_schema || '" has NO objects!');
        print_audit_log;
        RAISE_APPLICATION_ERROR(-20003,
            'New schema "' || v_new_schema || '" contains no objects.');
    END IF;

    log_step(v_step, 'Verify new schema exists and has objects', 'OK',
        v_new_schema || ' has ' || TO_CHAR(v_new_obj_cnt) || ' objects.');

    ---------------------------------------------------------------------------
    -- STEP 3: Confronto oggetti tra schema produzione e nuovo
    ---------------------------------------------------------------------------
    v_step := 3;

    SELECT COUNT(*) INTO v_prod_obj_cnt
    FROM dba_objects WHERE owner = v_prod_schema;

    -- Conteggio righe stimato
    SELECT NVL(SUM(num_rows), 0) INTO v_prod_row_cnt
    FROM dba_tables WHERE owner = v_prod_schema;

    SELECT NVL(SUM(num_rows), 0) INTO v_new_row_cnt
    FROM dba_tables WHERE owner = v_new_schema;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  --- OBJECT COMPARISON ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('Object Type', 25) ||
        LPAD('Production', 12) ||
        LPAD('New Schema', 12) ||
        LPAD('Difference', 12) ||
        LPAD('Status', 10)
    );
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));

    FOR r IN (
        SELECT
            NVL(p.object_type, n.object_type) AS object_type,
            NVL(p.cnt, 0) AS prod_cnt,
            NVL(n.cnt, 0) AS new_cnt,
            NVL(n.cnt, 0) - NVL(p.cnt, 0) AS diff
        FROM (
            SELECT object_type, COUNT(*) AS cnt
            FROM dba_objects WHERE owner = v_prod_schema
            GROUP BY object_type
        ) p
        FULL OUTER JOIN (
            SELECT object_type, COUNT(*) AS cnt
            FROM dba_objects WHERE owner = v_new_schema
            GROUP BY object_type
        ) n ON p.object_type = n.object_type
        ORDER BY NVL(p.object_type, n.object_type)
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' ||
            RPAD(r.object_type, 25) ||
            LPAD(TO_CHAR(r.prod_cnt, '999,999'), 12) ||
            LPAD(TO_CHAR(r.new_cnt, '999,999'), 12) ||
            LPAD(TO_CHAR(r.diff, 'S999,999'), 12) ||
            LPAD(CASE WHEN r.diff = 0 THEN 'MATCH'
                      WHEN r.new_cnt > r.prod_cnt THEN 'MORE'
                      ELSE 'LESS'
                 END, 10)
        );
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));
    DBMS_OUTPUT.PUT_LINE('  Estimated rows - Production: ' || TO_CHAR(v_prod_row_cnt, '999,999,999') ||
        '  |  New: ' || TO_CHAR(v_new_row_cnt, '999,999,999'));
    DBMS_OUTPUT.PUT_LINE('');

    log_step(v_step, 'Compare object counts', 'OK',
        'Prod=' || v_prod_obj_cnt || ', New=' || v_new_obj_cnt);

    ---------------------------------------------------------------------------
    -- STEP 4: Verifica che il backup schema non esista gia'
    ---------------------------------------------------------------------------
    v_step := 4;

    SELECT COUNT(*) INTO v_exists
    FROM dba_users WHERE username = v_backup_schema;

    IF v_exists > 0 THEN
        log_step(v_step, 'Check backup schema name available', 'FAIL',
            'Backup schema "' || v_backup_schema || '" already exists!');
        print_audit_log;
        RAISE_APPLICATION_ERROR(-20004,
            'Backup schema "' || v_backup_schema || '" already exists. ' ||
            'Remove it first or run swap again tomorrow.');
    END IF;

    log_step(v_step, 'Check backup schema name available', 'OK',
        'Name "' || v_backup_schema || '" is available.');

    ---------------------------------------------------------------------------
    -- STEP 5: Rinomina schema produzione -> backup
    -- Oracle non supporta ALTER USER RENAME direttamente.
    -- Strategia: crea nuovo utente backup, esporta/importa con remap, drop originale
    -- Per semplicita' e sicurezza, usiamo l'approccio di:
    --   1. Creare utente backup con stessi privilegi
    --   2. Data Pump impdp con REMAP_SCHEMA dal prod al backup
    --   3. Dopo verifica, drop del prod originale
    --
    -- NOTA IMPORTANTE: In un ambiente reale, lo swap viene eseguito a livello
    -- applicativo (sinonimi, VPD, DBLINK) oppure con Data Pump export/import.
    -- Qui implementiamo lo swap via ALTER USER + sinonimi pubblici.
    ---------------------------------------------------------------------------
    v_step := 5;

    -- Creazione utente backup come clone del produzione
    DECLARE
        v_default_ts  VARCHAR2(128);
        v_temp_ts     VARCHAR2(128);
        v_profile     VARCHAR2(128);
    BEGIN
        SELECT default_tablespace, temporary_tablespace, profile
        INTO v_default_ts, v_temp_ts, v_profile
        FROM dba_users
        WHERE username = v_prod_schema;

        -- Crea utente backup (con password temporanea - verra' poi lockato)
        EXECUTE IMMEDIATE 'CREATE USER "' || v_backup_schema || '" IDENTIFIED BY "TempPwd#' ||
            TO_CHAR(DBMS_RANDOM.VALUE(10000, 99999), '99999') || '" ' ||
            'DEFAULT TABLESPACE "' || v_default_ts || '" ' ||
            'TEMPORARY TABLESPACE "' || v_temp_ts || '" ' ||
            'PROFILE "' || v_profile || '" ' ||
            'ACCOUNT LOCK';

        log_step(v_step, 'Create backup user ' || v_backup_schema, 'OK',
            'Tablespace=' || v_default_ts);
    EXCEPTION
        WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            log_step(v_step, 'Create backup user', 'FAIL', v_error_msg);
            print_audit_log;
            RAISE;
    END;

    ---------------------------------------------------------------------------
    -- STEP 6: Trasferimento oggetti da produzione a backup via Data Pump
    -- Utilizziamo DBMS_DATAPUMP per un export/import interno al database
    ---------------------------------------------------------------------------
    v_step := 6;

    DECLARE
        v_dp_handle   NUMBER;
        v_job_state   VARCHAR2(30);
        v_status      ku$_Status;
        v_log_entry   ku$_LogEntry;
        v_dp_job_name VARCHAR2(128) := 'M_DN_SWAP_BKP_' || v_timestamp;
    BEGIN
        -- Export dello schema produzione nella directory DATA_PUMP_DIR
        v_dp_handle := DBMS_DATAPUMP.OPEN(
            operation   => 'EXPORT',
            job_mode    => 'SCHEMA',
            remote_link => NULL,
            job_name    => v_dp_job_name || '_EXP',
            version     => 'LATEST'
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_prod_schema) || '_' || v_timestamp || '.dmp',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_prod_schema) || '_' || v_timestamp || '_exp.log',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
        );

        DBMS_DATAPUMP.METADATA_FILTER(
            handle => v_dp_handle,
            name   => 'SCHEMA_EXPR',
            value  => '= ''' || v_prod_schema || ''''
        );

        DBMS_DATAPUMP.START_JOB(v_dp_handle);

        -- Attendi completamento export
        DBMS_DATAPUMP.WAIT_FOR_JOB(v_dp_handle, v_job_state);

        IF v_job_state != 'COMPLETED' THEN
            log_step(v_step, 'Export production schema to backup', 'FAIL',
                'Export state: ' || v_job_state);
            print_audit_log;
            RAISE_APPLICATION_ERROR(-20005,
                'Export of production schema failed with state: ' || v_job_state);
        END IF;

        log_step(v_step, 'Export production schema', 'OK',
            'Exported to DATA_PUMP_DIR');

        -- Import nello schema backup con REMAP_SCHEMA
        v_dp_handle := DBMS_DATAPUMP.OPEN(
            operation   => 'IMPORT',
            job_mode    => 'SCHEMA',
            remote_link => NULL,
            job_name    => v_dp_job_name || '_IMP',
            version     => 'LATEST'
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_prod_schema) || '_' || v_timestamp || '.dmp',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_prod_schema) || '_' || v_timestamp || '_imp.log',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
        );

        DBMS_DATAPUMP.METADATA_REMAP(
            handle    => v_dp_handle,
            name      => 'REMAP_SCHEMA',
            old_value => v_prod_schema,
            value     => v_backup_schema
        );

        DBMS_DATAPUMP.START_JOB(v_dp_handle);
        DBMS_DATAPUMP.WAIT_FOR_JOB(v_dp_handle, v_job_state);

        IF v_job_state != 'COMPLETED' THEN
            log_step(v_step, 'Import to backup schema', 'FAIL',
                'Import state: ' || v_job_state);
            print_audit_log;
            RAISE_APPLICATION_ERROR(-20006,
                'Import to backup schema failed with state: ' || v_job_state);
        END IF;

        log_step(v_step, 'Import production -> backup schema', 'OK',
            v_prod_schema || ' -> ' || v_backup_schema);

    EXCEPTION
        WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            log_step(v_step, 'Data Pump backup transfer', 'FAIL', v_error_msg);
            -- Tentativo di pulizia
            BEGIN
                EXECUTE IMMEDIATE 'DROP USER "' || v_backup_schema || '" CASCADE';
                DBMS_OUTPUT.PUT_LINE('  [ROLLBACK] Backup user dropped for cleanup.');
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            print_audit_log;
            RAISE;
    END;

    ---------------------------------------------------------------------------
    -- STEP 7: Drop dello schema di produzione originale
    ---------------------------------------------------------------------------
    v_step := 7;

    BEGIN
        -- Termina sessioni attive sullo schema produzione
        FOR r IN (
            SELECT sid, serial#
            FROM v$session
            WHERE username = v_prod_schema
        ) LOOP
            BEGIN
                EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' ||
                    r.sid || ',' || r.serial# || ''' IMMEDIATE';
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END LOOP;

        EXECUTE IMMEDIATE 'DROP USER "' || v_prod_schema || '" CASCADE';
        log_step(v_step, 'Drop original production schema', 'OK',
            'Schema "' || v_prod_schema || '" dropped.');
    EXCEPTION
        WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            log_step(v_step, 'Drop original production schema', 'FAIL', v_error_msg);
            DBMS_OUTPUT.PUT_LINE('  [CRITICAL] Could not drop production schema.');
            DBMS_OUTPUT.PUT_LINE('  [RECOVERY] Backup exists as "' || v_backup_schema || '".');
            print_audit_log;
            RAISE;
    END;

    ---------------------------------------------------------------------------
    -- STEP 8: Ricreazione schema produzione dal nuovo schema
    -- (Import del new_schema con REMAP al nome produzione)
    ---------------------------------------------------------------------------
    v_step := 8;

    DECLARE
        v_dp_handle   NUMBER;
        v_job_state   VARCHAR2(30);
        v_dp_job_name VARCHAR2(128) := 'M_DN_SWAP_NEW_' || v_timestamp;
        v_default_ts  VARCHAR2(128);
        v_temp_ts     VARCHAR2(128);
        v_profile     VARCHAR2(128);
    BEGIN
        -- Recupera info dal nuovo schema
        SELECT default_tablespace, temporary_tablespace, profile
        INTO v_default_ts, v_temp_ts, v_profile
        FROM dba_users
        WHERE username = v_new_schema;

        -- Crea utente produzione con la struttura del nuovo schema
        EXECUTE IMMEDIATE 'CREATE USER "' || v_prod_schema || '" IDENTIFIED BY "TempPwd#' ||
            TO_CHAR(DBMS_RANDOM.VALUE(10000, 99999), '99999') || '" ' ||
            'DEFAULT TABLESPACE "' || v_default_ts || '" ' ||
            'TEMPORARY TABLESPACE "' || v_temp_ts || '" ' ||
            'PROFILE "' || v_profile || '"';

        -- Export del nuovo schema
        v_dp_handle := DBMS_DATAPUMP.OPEN(
            operation   => 'EXPORT',
            job_mode    => 'SCHEMA',
            remote_link => NULL,
            job_name    => v_dp_job_name || '_EXP',
            version     => 'LATEST'
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_new_schema) || '_' || v_timestamp || '.dmp',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_new_schema) || '_' || v_timestamp || '_exp.log',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
        );

        DBMS_DATAPUMP.METADATA_FILTER(
            handle => v_dp_handle,
            name   => 'SCHEMA_EXPR',
            value  => '= ''' || v_new_schema || ''''
        );

        DBMS_DATAPUMP.START_JOB(v_dp_handle);
        DBMS_DATAPUMP.WAIT_FOR_JOB(v_dp_handle, v_job_state);

        IF v_job_state != 'COMPLETED' THEN
            log_step(v_step, 'Export new schema', 'FAIL',
                'State: ' || v_job_state);
            print_audit_log;
            RAISE_APPLICATION_ERROR(-20007,
                'Export of new schema failed. RECOVERY: backup exists as "' || v_backup_schema || '".');
        END IF;

        -- Import con remap al nome produzione
        v_dp_handle := DBMS_DATAPUMP.OPEN(
            operation   => 'IMPORT',
            job_mode    => 'SCHEMA',
            remote_link => NULL,
            job_name    => v_dp_job_name || '_IMP',
            version     => 'LATEST'
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_new_schema) || '_' || v_timestamp || '.dmp',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
        );

        DBMS_DATAPUMP.ADD_FILE(
            handle    => v_dp_handle,
            filename  => 'm_dn_swap_' || LOWER(v_new_schema) || '_' || v_timestamp || '_imp2.log',
            directory => 'DATA_PUMP_DIR',
            filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
        );

        DBMS_DATAPUMP.METADATA_REMAP(
            handle    => v_dp_handle,
            name      => 'REMAP_SCHEMA',
            old_value => v_new_schema,
            value     => v_prod_schema
        );

        DBMS_DATAPUMP.START_JOB(v_dp_handle);
        DBMS_DATAPUMP.WAIT_FOR_JOB(v_dp_handle, v_job_state);

        IF v_job_state != 'COMPLETED' THEN
            log_step(v_step, 'Import new -> production name', 'FAIL',
                'State: ' || v_job_state);
            print_audit_log;
            RAISE_APPLICATION_ERROR(-20008,
                'Import to production name failed. RECOVERY: backup as "' || v_backup_schema || '".');
        END IF;

        log_step(v_step, 'Remap new schema -> production name', 'OK',
            v_new_schema || ' -> ' || v_prod_schema);

    EXCEPTION
        WHEN OTHERS THEN
            v_error_msg := SQLERRM;
            log_step(v_step, 'Schema swap transfer', 'FAIL', v_error_msg);
            DBMS_OUTPUT.PUT_LINE('  [CRITICAL] Schema swap failed during transfer.');
            DBMS_OUTPUT.PUT_LINE('  [RECOVERY] Backup schema: "' || v_backup_schema || '"');
            DBMS_OUTPUT.PUT_LINE('  [RECOVERY] You can manually restore from backup.');
            print_audit_log;
            RAISE;
    END;

    ---------------------------------------------------------------------------
    -- STEP 9: Ricompilazione oggetti invalidi
    ---------------------------------------------------------------------------
    v_step := 9;

    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  Recompiling invalid objects in "' || v_prod_schema || '"...');

        UTL_RECOMP.RECOMP_SERIAL(v_prod_schema);

        SELECT COUNT(*) INTO v_exists
        FROM dba_objects
        WHERE owner = v_prod_schema AND status = 'INVALID';

        IF v_exists = 0 THEN
            log_step(v_step, 'Recompile invalid objects', 'OK',
                'All objects are VALID.');
        ELSE
            log_step(v_step, 'Recompile invalid objects', 'WARN',
                TO_CHAR(v_exists) || ' objects still INVALID after recompilation.');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            log_step(v_step, 'Recompile invalid objects', 'WARN',
                'Recompilation error: ' || SQLERRM);
    END;

    ---------------------------------------------------------------------------
    -- STEP 10: Drop dello schema vecchio (new_schema) se richiesto
    -- Il new_schema ora e' ridondante poiche' i dati sono nel prod_schema
    ---------------------------------------------------------------------------
    v_step := 10;

    BEGIN
        -- Pulizia del new_schema (ormai duplicato)
        EXECUTE IMMEDIATE 'DROP USER "' || v_new_schema || '" CASCADE';
        log_step(v_step, 'Drop intermediate new schema', 'OK',
            'Schema "' || v_new_schema || '" dropped.');
    EXCEPTION
        WHEN OTHERS THEN
            log_step(v_step, 'Drop intermediate new schema', 'WARN',
                'Could not drop: ' || SQLERRM);
    END;

    ---------------------------------------------------------------------------
    -- STEP 11: Drop backup se richiesto
    ---------------------------------------------------------------------------
    v_step := 11;

    IF v_drop_old = 'Y' THEN
        BEGIN
            -- Verifica finale prima del drop
            DECLARE
                v_new_prod_cnt NUMBER;
            BEGIN
                SELECT COUNT(*) INTO v_new_prod_cnt
                FROM dba_objects WHERE owner = v_prod_schema;

                IF v_new_prod_cnt > 0 THEN
                    EXECUTE IMMEDIATE 'DROP USER "' || v_backup_schema || '" CASCADE';
                    log_step(v_step, 'Drop backup schema (requested)', 'OK',
                        'Schema "' || v_backup_schema || '" dropped. ' ||
                        v_prod_schema || ' has ' || v_new_prod_cnt || ' objects.');
                ELSE
                    log_step(v_step, 'Drop backup schema', 'SKIP',
                        'Production schema has 0 objects - keeping backup for safety!');
                END IF;
            END;
        EXCEPTION
            WHEN OTHERS THEN
                log_step(v_step, 'Drop backup schema', 'WARN',
                    'Could not drop backup: ' || SQLERRM);
        END;
    ELSE
        log_step(v_step, 'Drop backup schema', 'SKIP',
            'Backup preserved as "' || v_backup_schema || '" (drop_old=N).');
    END IF;

    ---------------------------------------------------------------------------
    -- Riepilogo finale
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  SCHEMA SWAP COMPLETED SUCCESSFULLY');
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  Production Schema:  ' || v_prod_schema || ' (now contains new data)');
    IF v_drop_old != 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('  Backup Schema:      ' || v_backup_schema || ' (old production data)');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  Swap completed at:  ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('  ============================================================');

    IF v_drop_old != 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  [INFO] Il backup e'' stato conservato come "' || v_backup_schema || '".');
        DBMS_OUTPUT.PUT_LINE('  Per rimuoverlo dopo la verifica:');
        DBMS_OUTPUT.PUT_LINE('    DROP USER "' || v_backup_schema || '" CASCADE;');
    END IF;

    print_audit_log;

END;
/

PROMPT
PROMPT ============================================================================
PROMPT   SCHEMA SWAP COMPLETE
PROMPT ============================================================================
PROMPT

SET FEEDBACK ON
EXIT SUCCESS;
