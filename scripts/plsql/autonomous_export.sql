-- ==============================================================================
-- Script Name: autonomous_export.sql
-- Purpose:     Esegue un export Data Pump su Autonomous Database (ATP/ADW)
--              usando il package DBMS_DATAPUMP e salva il file di dump
--              direttamente su OCI Object Storage tramite DBMS_CLOUD.
-- Parameters:  &1 = Schema Name
--              &2 = Dump Filename (nel bucket)
--              &3 = Credential Name (per OCI Bucket)
--              &4 = Bucket URI (https://...)
--              &5 = Parallel Degree (1-8)
--              &6 = Content (ALL / DATA_ONLY / METADATA_ONLY)
--              &7 = Compression (NONE / BASIC / ALL)
-- Author:      ACME DBA Team
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
    v_content       VARCHAR2(50) := UPPER(TRIM('&6'));
    v_compression   VARCHAR2(50) := UPPER(TRIM('&7'));
    
    v_job_handle    NUMBER;
    v_job_name      VARCHAR2(128);
    v_job_state     VARCHAR2(30);
    v_status        ku$_Status;
    v_full_dump_uri VARCHAR2(2048);
    v_log_file      VARCHAR2(256);
    
    e_dp_error      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_dp_error, -39001);
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   🚀 AVVIO EXPORT AUTONOMOUS DB (DBMS_DATAPUMP)');
    DBMS_OUTPUT.PUT_LINE('   Schema: ' || v_schema);
    DBMS_OUTPUT.PUT_LINE('   Bucket URI: ' || v_bucket_uri);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    v_job_name := 'EXP_' || v_schema || '_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
    v_full_dump_uri := v_bucket_uri || '/' || v_dump_file;
    v_log_file := 'EXP_' || v_schema || '.log';

    -- 1. Apertura del Job Data Pump
    v_job_handle := DBMS_DATAPUMP.OPEN(
        operation   => 'EXPORT',
        job_mode    => 'SCHEMA',
        remote_link => NULL,
        job_name    => v_job_name,
        version     => 'LATEST'
    );
    DBMS_OUTPUT.PUT_LINE('INFO: Job Data Pump aperto con successo: ' || v_job_name);

    -- 2. Aggiunta file di Dump su Object Storage
    -- Usiamo default_directory per l'export su cloud
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_job_handle,
        filename  => v_full_dump_uri,
        directory => 'DATA_PUMP_DIR', -- Su Autonomous, DATA_PUMP_DIR + credential instrada su OCI
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
    );
    
    -- Su ATP, log locale
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_job_handle,
        filename  => v_log_file,
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
    );

    -- 3. Configurazione Filtri
    DBMS_DATAPUMP.METADATA_FILTER(
        handle      => v_job_handle,
        name        => 'SCHEMA_EXPR',
        value       => 'IN (''' || v_schema || ''')'
    );
    
    -- Content filter
    IF v_content IN ('DATA_ONLY', 'METADATA_ONLY') THEN
        DBMS_DATAPUMP.DATA_FILTER(
            handle      => v_job_handle,
            name        => 'INCLUDE_ROWS',
            value       => CASE WHEN v_content = 'DATA_ONLY' THEN 1 ELSE 0 END
        );
    END IF;

    -- 4. Impostazione Parametri (Parallelo, Compressione, Credenziali OCI)
    DBMS_DATAPUMP.SET_PARAMETER(v_job_handle, 'DEGREE', v_parallel);
    
    IF v_compression != 'NONE' THEN
        DBMS_DATAPUMP.SET_PARAMETER(v_job_handle, 'COMPRESSION', v_compression);
    END IF;

    -- Imposta la credenziale Cloud per scrivere sul bucket
    DBMS_DATAPUMP.SET_PARAMETER(
        handle      => v_job_handle,
        name        => 'CREDENTIAL_NAME',
        value       => v_cred_name
    );

    -- 5. Avvio del Job
    DBMS_DATAPUMP.START_JOB(v_job_handle);
    DBMS_OUTPUT.PUT_LINE('INFO: Job avviato. Monitoraggio in corso...');

    -- 6. Monitoraggio Sincrono del Job
    v_job_state := 'EXECUTING';
    WHILE (v_job_state != 'COMPLETED' AND v_job_state != 'STOPPED') LOOP
        DBMS_DATAPUMP.GET_STATUS(
            handle    => v_job_handle,
            mask      => DBMS_DATAPUMP.KU$_STATUS_JOB_ERROR + DBMS_DATAPUMP.KU$_STATUS_JOB_STATUS,
            timeout   => 5, -- polling ogni 5s
            job_state => v_job_state,
            status    => v_status
        );
        DBMS_LOCK.SLEEP(10);
    END LOOP;

    DBMS_DATAPUMP.DETACH(v_job_handle);

    IF v_job_state = 'COMPLETED' THEN
        DBMS_OUTPUT.PUT_LINE('✅ SUCCESS: Export completato con successo!');
        DBMS_OUTPUT.PUT_LINE('File generato sul bucket: ' || v_full_dump_uri);
    ELSE
        DBMS_OUTPUT.PUT_LINE('❌ ERROR: Export fallito o stoppato con stato: ' || v_job_state);
        RAISE_APPLICATION_ERROR(-20003, 'Export Data Pump fallito.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE CRITICO DURANTE L''EXPORT AUTONOMOUS:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        -- Prova a fare il detach se possibile per evitare job zombie
        BEGIN
            DBMS_DATAPUMP.DETACH(v_job_handle);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        RAISE;
END;
/
EXIT;
