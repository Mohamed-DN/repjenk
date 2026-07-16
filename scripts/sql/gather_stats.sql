-- ==============================================================================
-- Script Name: gather_stats.sql
-- Purpose:     Ricalcolo delle statistiche dello schema tramite DBMS_STATS.
--              Operazione fondamentale post-import per evitare degrado
--              delle performance dell'optimizer su query pesanti.
-- Parameters:  &1 = Schema Name
--              &2 = Degree of Parallelism
-- Author:      DARKNERO DBA Team (Generato tramite Automazione)
-- Date:        2026-07-12
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 250
SET PAGESIZE 100
SET VERIFY OFF
SET FEEDBACK OFF
SET HEADING OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema    VARCHAR2(128) := UPPER(TRIM('&1'));
    v_degree    NUMBER := TO_NUMBER(NVL(TRIM('&2'), '1'));
    v_start     NUMBER;
    v_duration  NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   📈 AVVIO RICALCOLO STATISTICHE (DBMS_STATS)');
    DBMS_OUTPUT.PUT_LINE('   Schema: ' || v_schema || ' | Parallelo: ' || v_degree);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    IF v_schema IS NULL OR v_schema = '' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Nessun schema fornito per il ricalcolo statistiche.');
    END IF;

    v_start := DBMS_UTILITY.GET_TIME;

    -- Esecuzione di gather_schema_stats
    -- cascade=TRUE aggiorna anche le statistiche degli indici
    -- options='GATHER' aggiorna tutto lo schema
    DBMS_STATS.GATHER_SCHEMA_STATS(
        ownname          => v_schema,
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        block_sample     => TRUE,
        method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
        degree           => v_degree,
        cascade          => DBMS_STATS.AUTO_CASCADE,
        options          => 'GATHER'
    );

    v_duration := (DBMS_UTILITY.GET_TIME - v_start) / 100;

    DBMS_OUTPUT.PUT_LINE('✅ SUCCESS: Statistiche aggiornate con successo in ' || ROUND(v_duration, 2) || ' secondi.');
    DBMS_OUTPUT.PUT_LINE('======================================================================');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE DURANTE IL RICALCOLO DELLE STATISTICHE:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        -- Un fallimento nelle statistiche post-import è grave ma non blocca l'import dei dati, 
        -- ma qui vogliamo sollevare l'errore per notificarlo alla pipeline.
        RAISE;
END;
/
EXIT;
