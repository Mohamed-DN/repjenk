-- ==============================================================================
-- Script Name: monitor_job.sql
-- Purpose:     Monitoraggio avanzato di job Data Pump in esecuzione.
-- Parameters:  &1 = Job Name (Opzionale. Se vuoto mostra tutti)
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
    v_job_name VARCHAR2(128) := UPPER(TRIM('&1'));
    v_found    NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   👀 MONITORAGGIO DATA PUMP JOBS');
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    DBMS_OUTPUT.PUT_LINE(
        RPAD('JOB_NAME', 30) || 
        RPAD('OWNER', 15) || 
        RPAD('OPERATION', 15) || 
        RPAD('STATE', 15) || 
        'DEGREE'
    );
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 30, '-') || ' ' || RPAD('-', 14, '-') || ' ' || RPAD('-', 14, '-') || ' ' || RPAD('-', 14, '-') || ' ' || '------');

    FOR rec IN (
        SELECT job_name, owner_name, operation, state, degree
        FROM dba_datapump_jobs
        WHERE (v_job_name IS NULL OR v_job_name = 'NULL' OR job_name = v_job_name)
    ) LOOP
        v_found := v_found + 1;
        DBMS_OUTPUT.PUT_LINE(
            RPAD(rec.job_name, 30) || 
            RPAD(rec.owner_name, 15) || 
            RPAD(rec.operation, 15) || 
            RPAD(rec.state, 15) || 
            rec.degree
        );
    END LOOP;

    IF v_found = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Nessun job Data Pump attivo trovato in dba_datapump_jobs.');
    ELSE
        DBMS_OUTPUT.PUT_LINE(' ');
        DBMS_OUTPUT.PUT_LINE('➜ PROGRESSO SESSIONI (V$SESSION_LONGOPS):');
        DBMS_OUTPUT.PUT_LINE(
            RPAD('OP_NAME', 20) || 
            RPAD('PROGRESS', 15) || 
            RPAD('TIME_REMAINING', 20)
        );
        FOR l IN (
            SELECT opname, 
                   ROUND((sofar/totalwork)*100, 2) as pct, 
                   time_remaining as secs
            FROM v$session_longops
            WHERE opname LIKE 'RMAN%' OR opname LIKE '%DBMS_DATAPUMP%'
              AND totalwork > 0
              AND time_remaining > 0
        ) LOOP
            DBMS_OUTPUT.PUT_LINE(
                RPAD(l.opname, 20) || 
                RPAD(l.pct || '%', 15) || 
                l.secs || ' secondi'
            );
        END LOOP;
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('======================================================================');
END;
/
EXIT;
