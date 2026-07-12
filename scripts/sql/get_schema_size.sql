-- ==============================================================================
-- Script Name: get_schema_size.sql
-- Purpose:     Analisi dettagliata delle dimensioni di uno schema (Tabelle, Indici, LOB)
--              Identifica gli oggetti più pesanti per stimare i tempi di export.
-- Parameters:  &1 = Schema Name
-- Author:      ENI DBA Team
-- Date:        2026-07-12
-- ==============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema_name VARCHAR2(128) := UPPER(TRIM('&1'));
    v_total_mb    NUMBER := 0;
    v_table_mb    NUMBER := 0;
    v_index_mb    NUMBER := 0;
    v_lob_mb      NUMBER := 0;
    v_obj_count   NUMBER := 0;
    
    CURSOR c_top_objects IS
        SELECT segment_name, segment_type, ROUND(bytes/1024/1024, 2) as size_mb
        FROM dba_segments
        WHERE owner = v_schema_name
        ORDER BY bytes DESC
        FETCH FIRST 10 ROWS ONLY;
BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('   📊 ANALISI DIMENSIONE SCHEMA: ' || v_schema_name);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    -- Verifica se lo schema ha oggetti
    SELECT COUNT(*) INTO v_obj_count FROM dba_segments WHERE owner = v_schema_name;
    
    IF v_obj_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Lo schema è vuoto o non esiste alcun segmento allocato.');
        RETURN;
    END IF;

    -- Calcolo delle dimensioni per tipologia
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_total_mb FROM dba_segments WHERE owner = v_schema_name;
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_table_mb FROM dba_segments WHERE owner = v_schema_name AND segment_type LIKE 'TABLE%';
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_index_mb FROM dba_segments WHERE owner = v_schema_name AND segment_type LIKE 'INDEX%';
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_lob_mb FROM dba_segments WHERE owner = v_schema_name AND segment_type LIKE 'LOB%';

    DBMS_OUTPUT.PUT_LINE('➜ RIEPILOGO DIMENSIONI (MB):');
    DBMS_OUTPUT.PUT_LINE('  - Totale Schema      : ' || ROUND(v_total_mb, 2) || ' MB (' || ROUND(v_total_mb/1024, 2) || ' GB)');
    DBMS_OUTPUT.PUT_LINE('  - Dati (Tabelle)     : ' || ROUND(v_table_mb, 2) || ' MB');
    DBMS_OUTPUT.PUT_LINE('  - Indici             : ' || ROUND(v_index_mb, 2) || ' MB');
    DBMS_OUTPUT.PUT_LINE('  - LOB/CLOB/BLOB      : ' || ROUND(v_lob_mb, 2)   || ' MB');
    DBMS_OUTPUT.PUT_LINE('  - Altri Segmenti     : ' || ROUND(v_total_mb - (v_table_mb + v_index_mb + v_lob_mb), 2) || ' MB');
    DBMS_OUTPUT.PUT_LINE(' ');

    DBMS_OUTPUT.PUT_LINE('➜ BREAKDOWN PER TIPO OGGETTO:');
    FOR rec IN (
        SELECT object_type, COUNT(*) as cnt, status
        FROM dba_objects 
        WHERE owner = v_schema_name 
        GROUP BY object_type, status
        ORDER BY cnt DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  - ' || RPAD(rec.object_type, 20) || ': ' || LPAD(rec.cnt, 6) || ' (' || rec.status || ')');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(' ');

    DBMS_OUTPUT.PUT_LINE('➜ TOP 10 OGGETTI PIU'' GRANDI:');
    DBMS_OUTPUT.PUT_LINE(RPAD('SEGMENT_NAME', 40) || RPAD('TYPE', 20) || 'SIZE (MB)');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 40, '-') || RPAD('-', 20, '-') || '---------');
    FOR rec IN c_top_objects LOOP
        DBMS_OUTPUT.PUT_LINE(RPAD(rec.segment_name, 40) || RPAD(rec.segment_type, 20) || rec.size_mb);
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('======================================================================');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE DURANTE IL CALCOLO DELLE DIMENSIONI: ' || SQLERRM);
        RAISE;
END;
/
EXIT;
