-- ==============================================================================
-- Script Name: cleanup_jobs.sql
-- Purpose:     Identifica e pulisce job Data Pump orfani (STOPPED/NOT RUNNING),
--              evitando l'accumulo di Master Table nello schema.
-- Parameters:  None
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
    v_cleaned NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   🧹 PULIZIA JOB DATA PUMP ORFANI');
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    FOR rec IN (
        SELECT job_name, owner_name, state
        FROM dba_datapump_jobs
        WHERE state IN ('NOT RUNNING', 'STOPPED')
          AND owner_name NOT IN ('SYS', 'SYSTEM')
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('Trovato Job orfano: ' || rec.owner_name || '.' || rec.job_name || ' (' || rec.state || ')');
        
        BEGIN
            -- Drop esplicito della master table che rappresenta il job
            EXECUTE IMMEDIATE 'DROP TABLE ' || rec.owner_name || '.' || rec.job_name;
            DBMS_OUTPUT.PUT_LINE('  ✅ Master table eliminata con successo.');
            v_cleaned := v_cleaned + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  ❌ Impossibile eliminare la master table: ' || SQLERRM);
        END;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('Totale Job Ripuliti: ' || v_cleaned);
    DBMS_OUTPUT.PUT_LINE('======================================================================');
END;
/
EXIT;
