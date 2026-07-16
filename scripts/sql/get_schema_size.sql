-- =========================================================================================
-- SCRIPT NAME: get_schema_size.sql
-- PURPOSE:     Analisi dettagliata delle dimensioni di uno schema (Tabelle, Indici, LOB, Partition).
--              Identifica gli oggetti più pesanti per stimare i tempi di export e
--              consiglia i parametri di Data Pump (parallelismo, compressione).
-- PARAMETERS:  &1 = Schema Name
-- AUTHOR:      M-DN DBA Team (Generato tramite Automazione)
-- DATE:        2026-07-12
-- =========================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 300
SET PAGESIZE 200
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF

WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    v_schema_name VARCHAR2(128) := UPPER(TRIM('&1'));
    v_total_mb    NUMBER := 0;
    v_table_mb    NUMBER := 0;
    v_index_mb    NUMBER := 0;
    v_lob_mb      NUMBER := 0;
    v_part_mb     NUMBER := 0;
    v_obj_count   NUMBER := 0;
    
    -- Cursore per estrarre la Top 15 degli oggetti più grandi (utile per tuning DP)
    CURSOR c_top_objects IS
        SELECT segment_name, 
               segment_type, 
               partition_name,
               ROUND(bytes/1024/1024, 2) as size_mb
        FROM dba_segments
        WHERE owner = v_schema_name
        ORDER BY bytes DESC
        FETCH FIRST 15 ROWS ONLY;
BEGIN
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('   📊 CAPACITY PLANNING & SCHEMA SIZE ANALYSIS: ' || v_schema_name);
    DBMS_OUTPUT.PUT_LINE('================================================================================');

    -- Verifica esistenza di oggetti per lo schema
    SELECT COUNT(*) INTO v_obj_count FROM dba_segments WHERE owner = v_schema_name;
    
    IF v_obj_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Nessun segmento trovato per lo schema ' || v_schema_name || '. Lo schema è vuoto.');
        RETURN;
    END IF;

    -- Aggregazione dimensioni per macro-tipologia
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_total_mb FROM dba_segments WHERE owner = v_schema_name;
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_table_mb FROM dba_segments WHERE owner = v_schema_name AND segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION');
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_index_mb FROM dba_segments WHERE owner = v_schema_name AND segment_type IN ('INDEX', 'INDEX PARTITION', 'INDEX SUBPARTITION');
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_lob_mb   FROM dba_segments WHERE owner = v_schema_name AND segment_type LIKE 'LOB%';
    SELECT NVL(SUM(bytes)/1024/1024, 0) INTO v_part_mb  FROM dba_segments WHERE owner = v_schema_name AND segment_type LIKE '%PARTITION%';

    -- Stampa Riepilogo Volumetrico
    DBMS_OUTPUT.PUT_LINE('➜ RIEPILOGO DIMENSIONI ALLOCATE:');
    DBMS_OUTPUT.PUT_LINE('  - Totale Schema      : ' || ROUND(v_total_mb, 2) || ' MB (' || ROUND(v_total_mb/1024, 2) || ' GB)');
    DBMS_OUTPUT.PUT_LINE('  - Dati (Tabelle)     : ' || ROUND(v_table_mb, 2) || ' MB (' || ROUND((v_table_mb/NULLIF(v_total_mb,0))*100, 1) || '%)');
    DBMS_OUTPUT.PUT_LINE('  - Indici             : ' || ROUND(v_index_mb, 2) || ' MB (' || ROUND((v_index_mb/NULLIF(v_total_mb,0))*100, 1) || '%)');
    DBMS_OUTPUT.PUT_LINE('  - LOB/CLOB/BLOB      : ' || ROUND(v_lob_mb, 2)   || ' MB (' || ROUND((v_lob_mb/NULLIF(v_total_mb,0))*100, 1) || '%)');
    IF v_part_mb > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  - Oggetti partizionati coprono ' || ROUND(v_part_mb, 2) || ' MB del totale.');
    END IF;
    DBMS_OUTPUT.PUT_LINE(' ');

    -- Distribuzione degli oggetti (tabelle vs package vs viste)
    DBMS_OUTPUT.PUT_LINE('➜ BREAKDOWN PER TIPO OGGETTO (DBA_OBJECTS):');
    FOR rec IN (
        SELECT object_type, COUNT(*) as cnt, SUM(CASE WHEN status='INVALID' THEN 1 ELSE 0 END) as inv_cnt
        FROM dba_objects 
        WHERE owner = v_schema_name 
        GROUP BY object_type
        ORDER BY cnt DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  - ' || RPAD(rec.object_type, 20) || ': ' || LPAD(rec.cnt, 6) || 
                             CASE WHEN rec.inv_cnt > 0 THEN ' (' || rec.inv_cnt || ' INVALIDI)' ELSE '' END);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(' ');

    -- Lista dei "Big Hitters"
    DBMS_OUTPUT.PUT_LINE('➜ TOP 15 OGGETTI PIU'' GRANDI (BIG HITTERS):');
    DBMS_OUTPUT.PUT_LINE(RPAD('SEGMENT_NAME', 40) || RPAD('PARTITION', 30) || RPAD('TYPE', 20) || 'SIZE (MB)');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 40, '-') || ' ' || RPAD('-', 29, '-') || ' ' || RPAD('-', 19, '-') || ' ' || '---------');
    FOR rec IN c_top_objects LOOP
        DBMS_OUTPUT.PUT_LINE(
            RPAD(SUBSTR(rec.segment_name, 1, 38), 40) || 
            RPAD(NVL(SUBSTR(rec.partition_name, 1, 28), 'N/A'), 30) || 
            RPAD(rec.segment_type, 20) || 
            rec.size_mb
        );
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE(CHR(10) || '================================================================================');
    
    -- Consigli per Data Pump
    DBMS_OUTPUT.PUT_LINE('💡 DATA PUMP TUNING RECOMMENDATIONS:');
    IF v_total_mb > 10000 THEN
        DBMS_OUTPUT.PUT_LINE('  - Il database supera i 10GB. Consigliato PARALLEL=4 o superiore.');
    END IF;
    IF v_lob_mb > (v_total_mb * 0.3) THEN
        DBMS_OUTPUT.PUT_LINE('  - L''uso estensivo di LOB (>30%) potrebbe limitare l''efficacia del PARALLEL per quegli oggetti.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('================================================================================');

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ ERRORE DURANTE IL CALCOLO DELLE DIMENSIONI DELLO SCHEMA:');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END;
/
EXIT;
