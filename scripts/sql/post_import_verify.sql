--------------------------------------------------------------------------------
-- Script:      post_import_verify.sql
-- Purpose:     Verifica post-importazione: oggetti, righe, vincoli, indici
--              Post-import verification report for imported schema
-- Parameters:  &1 = schema_name
-- Author:      ACME DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle Autonomous DB (ATP/ADW) / DBCS / On-Premises
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET DEFINE '&'

WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE schema_name = &1

PROMPT
PROMPT ============================================================================
PROMPT   ACME DATA PUMP PIPELINE - POST-IMPORT VERIFICATION REPORT
PROMPT   Schema: &schema_name
PROMPT ============================================================================
PROMPT

DECLARE
    v_schema       VARCHAR2(128) := UPPER('&schema_name');
    v_exists       NUMBER        := 0;
    v_total_obj    NUMBER        := 0;
    v_invalid_cnt  NUMBER        := 0;
    v_total_rows   NUMBER        := 0;
    v_warn_count   NUMBER        := 0;

BEGIN
    -- Verifica esistenza schema
    SELECT COUNT(*) INTO v_exists
    FROM dba_users WHERE username = v_schema;

    IF v_exists = 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Schema "' || v_schema || '" does not exist. Import may have failed.');
    END IF;

    ---------------------------------------------------------------------------
    -- Sezione 1: Conteggio oggetti per tipo
    -- Section 1: Object counts by type
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  --- 1. OBJECTS BY TYPE ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('Object Type', 30) ||
        LPAD('Total', 8) ||
        LPAD('Valid', 8) ||
        LPAD('Invalid', 10)
    );
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));

    FOR r IN (
        SELECT
            object_type,
            COUNT(*)                                               AS total_cnt,
            SUM(CASE WHEN status = 'VALID'   THEN 1 ELSE 0 END)   AS valid_cnt,
            SUM(CASE WHEN status = 'INVALID' THEN 1 ELSE 0 END)   AS invalid_cnt
        FROM dba_objects
        WHERE owner = v_schema
          AND object_type NOT IN ('INDEX PARTITION', 'INDEX SUBPARTITION',
                                   'TABLE PARTITION', 'TABLE SUBPARTITION',
                                   'LOB PARTITION', 'LOB SUBPARTITION')
        GROUP BY object_type
        ORDER BY total_cnt DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' ||
            RPAD(r.object_type, 30) ||
            LPAD(TO_CHAR(r.total_cnt, '999,999'), 8) ||
            LPAD(TO_CHAR(r.valid_cnt, '999,999'), 8) ||
            LPAD(CASE WHEN r.invalid_cnt > 0
                      THEN TO_CHAR(r.invalid_cnt, '999,999') || ' (!)'
                      ELSE TO_CHAR(r.invalid_cnt, '999,999')
                 END, 10)
        );
        v_total_obj := v_total_obj + r.total_cnt;
        v_invalid_cnt := v_invalid_cnt + r.invalid_cnt;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('TOTAL', 30) ||
        LPAD(TO_CHAR(v_total_obj, '999,999'), 8) ||
        LPAD(' ', 8) ||
        LPAD(TO_CHAR(v_invalid_cnt, '999,999'), 10)
    );
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Sezione 2: Conteggio righe per tabella (usa NUM_ROWS per velocita')
    -- Section 2: Row counts per table (uses NUM_ROWS for speed)
    -- NOTA: NUM_ROWS si basa su statistiche; eseguire DBMS_STATS se necessario
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- 2. TABLE ROW COUNTS (from statistics) ---');
    DBMS_OUTPUT.PUT_LINE('  NOTE: Based on DBA_TABLES.NUM_ROWS. Run DBMS_STATS for accuracy.');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('Table Name', 35) ||
        LPAD('Rows', 14) ||
        LPAD('Size (MB)', 14) ||
        LPAD('Last Analyzed', 20)
    );
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));

    FOR r IN (
        SELECT
            t.table_name,
            NVL(t.num_rows, -1) AS num_rows,
            NVL((
                SELECT SUM(s.bytes) / 1024 / 1024
                FROM dba_segments s
                WHERE s.owner = t.owner
                  AND s.segment_name = t.table_name
                  AND s.segment_type LIKE 'TABLE%'
            ), 0) AS size_mb,
            t.last_analyzed
        FROM dba_tables t
        WHERE t.owner = v_schema
        ORDER BY NVL(t.num_rows, 0) DESC
    ) LOOP
        v_total_rows := v_total_rows + GREATEST(r.num_rows, 0);
        DBMS_OUTPUT.PUT_LINE('  ' ||
            RPAD(SUBSTR(r.table_name, 1, 33), 35) ||
            LPAD(CASE WHEN r.num_rows = -1 THEN 'N/A'
                      ELSE TO_CHAR(r.num_rows, '999,999,999')
                 END, 14) ||
            LPAD(TO_CHAR(r.size_mb, '999,999.99'), 14) ||
            LPAD(NVL(TO_CHAR(r.last_analyzed, 'YYYY-MM-DD HH24:MI'), 'NEVER'), 20)
        );
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 75, '-'));
    DBMS_OUTPUT.PUT_LINE('  Total estimated rows: ' || TO_CHAR(v_total_rows, '999,999,999,999'));
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Sezione 3: Oggetti invalidi (dettaglio)
    -- Section 3: Invalid objects detail
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- 3. INVALID OBJECTS ---');

    IF v_invalid_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [OK] No invalid objects found.');
    ELSE
        v_warn_count := v_warn_count + 1;
        DBMS_OUTPUT.PUT_LINE('  [WARNING] ' || TO_CHAR(v_invalid_cnt) || ' invalid object(s) found!');
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 70, '-'));
        DBMS_OUTPUT.PUT_LINE('  ' ||
            RPAD('Object Type', 20) ||
            RPAD('Object Name', 40) ||
            'Status'
        );
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 70, '-'));

        FOR r IN (
            SELECT object_type, object_name, status
            FROM dba_objects
            WHERE owner = v_schema
              AND status = 'INVALID'
            ORDER BY object_type, object_name
            FETCH FIRST 50 ROWS ONLY
        ) LOOP
            DBMS_OUTPUT.PUT_LINE('  ' ||
                RPAD(r.object_type, 20) ||
                RPAD(SUBSTR(r.object_name, 1, 38), 40) ||
                r.status
            );
        END LOOP;

        IF v_invalid_cnt > 50 THEN
            DBMS_OUTPUT.PUT_LINE('  ... and ' || TO_CHAR(v_invalid_cnt - 50) || ' more invalid objects.');
        END IF;

        -- Suggerimento per ricompilazione
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  Suggerimento: Eseguire UTL_RECOMP.RECOMP_SERIAL(''' || v_schema || ''')');
        DBMS_OUTPUT.PUT_LINE('  per ricompilare gli oggetti invalidi.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Sezione 4: Stato vincoli (constraints)
    -- Section 4: Constraints status
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- 4. CONSTRAINTS STATUS ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('Constraint Type', 25) ||
        LPAD('Enabled', 10) ||
        LPAD('Disabled', 10) ||
        LPAD('Total', 10)
    );
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));

    DECLARE
        v_disabled_cnt NUMBER := 0;
    BEGIN
        FOR r IN (
            SELECT
                DECODE(constraint_type,
                    'P', 'PRIMARY KEY',
                    'U', 'UNIQUE',
                    'R', 'FOREIGN KEY',
                    'C', 'CHECK',
                    'V', 'VIEW WITH CHECK',
                    'O', 'WITH READ ONLY',
                    constraint_type
                ) AS constraint_desc,
                SUM(CASE WHEN status = 'ENABLED'  THEN 1 ELSE 0 END) AS enabled_cnt,
                SUM(CASE WHEN status = 'DISABLED' THEN 1 ELSE 0 END) AS disabled_cnt,
                COUNT(*) AS total_cnt
            FROM dba_constraints
            WHERE owner = v_schema
            GROUP BY constraint_type
            ORDER BY constraint_type
        ) LOOP
            DBMS_OUTPUT.PUT_LINE('  ' ||
                RPAD(r.constraint_desc, 25) ||
                LPAD(TO_CHAR(r.enabled_cnt, '999,999'), 10) ||
                LPAD(CASE WHEN r.disabled_cnt > 0
                          THEN TO_CHAR(r.disabled_cnt, '999,999') || ' (!)'
                          ELSE TO_CHAR(r.disabled_cnt, '999,999')
                     END, 10) ||
                LPAD(TO_CHAR(r.total_cnt, '999,999'), 10)
            );
            v_disabled_cnt := v_disabled_cnt + r.disabled_cnt;
        END LOOP;

        IF v_disabled_cnt > 0 THEN
            v_warn_count := v_warn_count + 1;
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('  [WARNING] ' || TO_CHAR(v_disabled_cnt) || ' disabled constraint(s) found!');

            -- Mostra dettaglio vincoli disabilitati
            FOR r IN (
                SELECT constraint_name, table_name, constraint_type
                FROM dba_constraints
                WHERE owner = v_schema AND status = 'DISABLED'
                FETCH FIRST 10 ROWS ONLY
            ) LOOP
                DBMS_OUTPUT.PUT_LINE('    DISABLED: ' || r.table_name || '.' || r.constraint_name ||
                    ' (type=' || r.constraint_type || ')');
            END LOOP;
        ELSE
            DBMS_OUTPUT.PUT_LINE('  [OK] All constraints are ENABLED.');
        END IF;
    END;

    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Sezione 5: Stato indici
    -- Section 5: Index status
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- 5. INDEX STATUS ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 55, '-'));
    DBMS_OUTPUT.PUT_LINE('  ' ||
        RPAD('Status', 20) ||
        LPAD('Count', 10) ||
        LPAD('% Total', 12)
    );
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 55, '-'));

    DECLARE
        v_total_idx    NUMBER := 0;
        v_unusable_cnt NUMBER := 0;
    BEGIN
        SELECT COUNT(*) INTO v_total_idx
        FROM dba_indexes WHERE owner = v_schema;

        FOR r IN (
            SELECT
                status,
                COUNT(*) AS cnt
            FROM dba_indexes
            WHERE owner = v_schema
            GROUP BY status
            ORDER BY cnt DESC
        ) LOOP
            DBMS_OUTPUT.PUT_LINE('  ' ||
                RPAD(r.status, 20) ||
                LPAD(TO_CHAR(r.cnt, '999,999'), 10) ||
                LPAD(TO_CHAR(
                    CASE WHEN v_total_idx > 0
                         THEN (r.cnt / v_total_idx) * 100
                         ELSE 0
                    END, '999.9') || '%', 12)
            );

            IF r.status = 'UNUSABLE' THEN
                v_unusable_cnt := r.cnt;
            END IF;
        END LOOP;

        IF v_unusable_cnt > 0 THEN
            v_warn_count := v_warn_count + 1;
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('  [WARNING] ' || TO_CHAR(v_unusable_cnt) || ' UNUSABLE index(es) found!');

            FOR r IN (
                SELECT index_name, table_name, index_type
                FROM dba_indexes
                WHERE owner = v_schema AND status = 'UNUSABLE'
                FETCH FIRST 10 ROWS ONLY
            ) LOOP
                DBMS_OUTPUT.PUT_LINE('    UNUSABLE: ' || r.table_name || '.' || r.index_name ||
                    ' (type=' || r.index_type || ')');
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('  Suggerimento: ALTER INDEX <name> REBUILD per ricostruire.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  [OK] All indexes are VALID/USABLE.');
        END IF;

        -- Verifica anche partizioni di indici
        DECLARE
            v_part_unusable NUMBER := 0;
        BEGIN
            SELECT COUNT(*) INTO v_part_unusable
            FROM dba_ind_partitions
            WHERE index_owner = v_schema AND status = 'UNUSABLE';

            IF v_part_unusable > 0 THEN
                v_warn_count := v_warn_count + 1;
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('  [WARNING] ' || TO_CHAR(v_part_unusable) ||
                    ' UNUSABLE index partition(s) found!');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END;

    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Riepilogo verifica
    -- Verification summary
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  POST-IMPORT VERIFICATION SUMMARY');
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  Schema:              ' || v_schema);
    DBMS_OUTPUT.PUT_LINE('  Total Objects:       ' || TO_CHAR(v_total_obj, '999,999'));
    DBMS_OUTPUT.PUT_LINE('  Invalid Objects:     ' || TO_CHAR(v_invalid_cnt, '999,999'));
    DBMS_OUTPUT.PUT_LINE('  Estimated Rows:      ' || TO_CHAR(v_total_rows, '999,999,999,999'));
    DBMS_OUTPUT.PUT_LINE('  Warnings:            ' || TO_CHAR(v_warn_count));
    DBMS_OUTPUT.PUT_LINE('  ============================================================');

    IF v_invalid_cnt = 0 AND v_warn_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  RESULT: [OK] Import verification PASSED');
    ELSIF v_invalid_cnt > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  RESULT: [WARNING] Issues found - review report above');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  RESULT: [WARNING] Minor warnings - review report above');
    END IF;

    DBMS_OUTPUT.PUT_LINE('  ============================================================');

END;
/

PROMPT
PROMPT ============================================================================
PROMPT   VERIFICATION COMPLETE
PROMPT ============================================================================
PROMPT

SET FEEDBACK ON
EXIT SUCCESS;
