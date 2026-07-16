-- ==============================================================================
-- Script Name: autonomous_import.sql
-- Purpose:     Esegue un import Data Pump su Autonomous Database (ATP/ADW)
--              prelevando il file di dump direttamente da OCI Object Storage.
-- Parameters:  &1 = Schema Name (Sorgente)
--              &2 = Dump Filename (nel bucket)
--              &3 = Credential Name (per OCI Bucket)
--              &4 = Bucket URI (https://...)
--              &5 = Parallel Degree
--              &6 = Remap Schema (OLD:NEW o "NONE")
--              &7 = Remap Tablespace (OLD:NEW o "NONE")
--              &8 = Table Exists Action (SKIP/REPLACE/APPEND/TRUNCATE)
-- Author:      DARKNERO DBA Team
-- Date:        2026-07-12
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET VERIFY OFF
SET FEEDBACK OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema        VARCHAR2(128) := UPPER(TRIM('&1'));
    v_dump_file     VARCHAR2(256) := TRIM('&2');
    v_cred_name     VARCHAR2(128) := UPPER(TRIM('&3'));
    v_bucket_uri    VARCHAR2(1024) := TRIM('&4');
    v_parallel      NUMBER := TO_NUMBER(TRIM('&5'));
    v_remap_schema  VARCHAR2(256) := UPPER(TRIM('&6'));
    v_remap_ts      VARCHAR2(256) := UPPER(TRIM('&7'));
    v_table_exists  VARCHAR2(50) := UPPER(TRIM('&8'));
    
    v_job_handle    NUMBER;
    v_job_name      VARCHAR2(128);
    v_job_state     VARCHAR2(30);
    v_status        ku$_Status;
    v_full_dump_uri VARCHAR2(2048);
    v_log_file      VARCHAR2(256);
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   📥 AVVIO IMPORT AUTONOMOUS DB (DBMS_DATAPUMP)');
    DBMS_OUTPUT.PUT_LINE('   File Sorgente: ' || v_bucket_uri || '/' || v_dump_file);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    v_job_name := 'IMP_' || v_schema || '_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
    v_full_dump_uri := v_bucket_uri || '/' || v_dump_file;
    v_log_file := 'IMP_' || v_schema || '.log';

    -- 1. Apertura del Job
    v_job_handle := DBMS_DATAPUMP.OPEN(
        operation   => 'IMPORT',
        job_mode    => 'SCHEMA',
        remote_link => NULL,
        job_name    => v_job_name,
        version     => 'LATEST'
    );
    DBMS_OUTPUT.PUT_LINE('INFO: Job aperto: ' || v_job_name);

    -- 2. Aggiunta file (Dump da Cloud, Log locale)
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_job_handle,
        filename  => v_full_dump_uri,
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
    );
    
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_job_handle,
        filename  => v_log_file,
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
    );

    -- 3. Impostazione Credenziali e Parallelo
    DBMS_DATAPUMP.SET_PARAMETER(v_job_handle, 'CREDENTIAL_NAME', v_cred_name);
    DBMS_DATAPUMP.SET_PARAMETER(v_job_handle, 'DEGREE', v_parallel);
    DBMS_DATAPUMP.SET_PARAMETER(v_job_handle, 'TABLE_EXISTS_ACTION', v_table_exists);

    -- 4. Applicazione Remap Schema
    IF v_remap_schema != 'NONE' AND INSTR(v_remap_schema, ':') > 0 THEN
        DECLARE
            v_old_schema VARCHAR2(128) := SUBSTR(v_remap_schema, 1, INSTR(v_remap_schema, ':')-1);
            v_new_schema VARCHAR2(128) := SUBSTR(v_remap_schema, INSTR(v_remap_schema, ':')+1);
        BEGIN
            DBMS_DATAPUMP.METADATA_REMAP(
                handle    => v_job_handle,
                name      => 'REMAP_SCHEMA',
                old_value => v_old_schema,
                value     => v_new_schema
            );
            DBMS_OUTPUT.PUT_LINE('INFO: Applicato Remap Schema: ' || v_old_schema || ' -> ' || v_new_schema);
        END;
    END IF;

    -- 5. Applicazione Remap Tablespace
    IF v_remap_ts != 'NONE' AND INSTR(v_remap_ts, ':') > 0 THEN
        DECLARE
            v_old_ts VARCHAR2(128) := SUBSTR(v_remap_ts, 1, INSTR(v_remap_ts, ':')-1);
            v_new_ts VARCHAR2(128) := SUBSTR(v_remap_ts, INSTR(v_remap_ts, ':')+1);
        BEGIN
            DBMS_DATAPUMP.METADATA_REMAP(
                handle    => v_job_handle,
                name      => 'REMAP_TABLESPACE',
                old_value => v_old_ts,
                value     => v_new_ts
            );
            DBMS_OUTPUT.PUT_LINE('INFO: Applicato Remap Tablespace: ' || v_old_ts || ' -> ' || v_new_ts);
        END;
    END IF;

    -- 6. Avvio Job
    DBMS_DATAPUMP.START_JOB(v_job_handle);
    DBMS_OUTPUT.PUT_LINE('INFO: Job avviato. Attendere completamento...');

    -- 7. Monitoraggio
    v_job_state := 'EXECUTING';
    WHILE (v_job_state != 'COMPLETED' AND v_job_state != 'STOPPED') LOOP
        DBMS_DATAPUMP.GET_STATUS(
            handle    => v_job_handle,
            mask      => DBMS_DATAPUMP.KU$_STATUS_JOB_ERROR + DBMS_DATAPUMP.KU$_STATUS_JOB_STATUS,
            timeout   => 5,
            job_state => v_job_state,
            status    => v_status
        );
        DBMS_LOCK.SLEEP(10);
    END LOOP;

    DBMS_DATAPUMP.DETACH(v_job_handle);

    IF v_job_state = 'COMPLETED' THEN
        DBMS_OUTPUT.PUT_LINE('✅ SUCCESS: Import completato con successo!');
    ELSE
        DBMS_OUTPUT.PUT_LINE('❌ ERROR: Import fallito o stoppato con stato: ' || v_job_state);
        RAISE_APPLICATION_ERROR(-20004, 'Import Data Pump fallito.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE CRITICO DURANTE L''IMPORT AUTONOMOUS:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        BEGIN DBMS_DATAPUMP.DETACH(v_job_handle); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
END;
/
EXIT;
