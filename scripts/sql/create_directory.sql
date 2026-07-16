--------------------------------------------------------------------------------
-- Script:      create_directory.sql
-- Purpose:     Creazione oggetto directory Oracle per Data Pump
--              Creates/replaces Oracle Directory object and grants access
-- Parameters:  &1 = directory_name
--              &2 = directory_path (filesystem path or OCI URI)
-- Author:      ACME DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle Autonomous DB (ATP/ADW) / DBCS / On-Premises
-- Notes:       Per Autonomous DB, le directory fisiche non sono supportate.
--              Usare DATA_PUMP_DIR o OCI Object Storage con credenziali.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 50
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET DEFINE '&'

WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE dir_name = &1
DEFINE dir_path = &2

PROMPT
PROMPT ============================================================================
PROMPT   ACME DATA PUMP PIPELINE - CREATE DIRECTORY
PROMPT   Directory Name: &dir_name
PROMPT   Directory Path: &dir_path
PROMPT ============================================================================
PROMPT

DECLARE
    v_dir_name      VARCHAR2(128)  := UPPER('&dir_name');
    v_dir_path      VARCHAR2(4000) := '&dir_path';
    v_current_user  VARCHAR2(128)  := SYS_CONTEXT('USERENV', 'CURRENT_USER');
    v_is_adb        BOOLEAN        := FALSE;
    v_count         NUMBER         := 0;
    v_existing_path VARCHAR2(4000);

BEGIN
    ---------------------------------------------------------------------------
    -- Rilevamento Autonomous Database
    -- ADB non supporta directory fisiche personalizzate
    ---------------------------------------------------------------------------
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM all_objects
        WHERE object_name = 'DBMS_CLOUD'
          AND object_type = 'PACKAGE';
        IF v_count > 0 THEN
            v_is_adb := TRUE;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN v_is_adb := FALSE;
    END;

    ---------------------------------------------------------------------------
    -- Per Autonomous DB: avviso sulle limitazioni
    ---------------------------------------------------------------------------
    IF v_is_adb THEN
        DBMS_OUTPUT.PUT_LINE('  [INFO] Autonomous Database detected.');
        DBMS_OUTPUT.PUT_LINE('  [INFO] Custom filesystem directories are NOT supported in ADB.');
        DBMS_OUTPUT.PUT_LINE('  [INFO] Use DATA_PUMP_DIR for local operations,');
        DBMS_OUTPUT.PUT_LINE('         or DBMS_CLOUD + OCI Object Storage for cloud operations.');
        DBMS_OUTPUT.PUT_LINE('');

        -- Verifica se DATA_PUMP_DIR esiste (sempre presente in ADB)
        SELECT COUNT(*) INTO v_count
        FROM all_directories
        WHERE directory_name = 'DATA_PUMP_DIR';

        IF v_count > 0 THEN
            SELECT directory_path INTO v_existing_path
            FROM all_directories
            WHERE directory_name = 'DATA_PUMP_DIR';

            DBMS_OUTPUT.PUT_LINE('  [INFO] DATA_PUMP_DIR is available at: ' || v_existing_path);
        END IF;

        -- In ADB, se la directory richiesta e' DATA_PUMP_DIR, saltiamo la creazione
        IF v_dir_name = 'DATA_PUMP_DIR' THEN
            DBMS_OUTPUT.PUT_LINE('  [OK] DATA_PUMP_DIR already exists in ADB. No action needed.');
            DBMS_OUTPUT.PUT_LINE('');
            GOTO end_script;
        END IF;

        -- Per ADB, proviamo comunque a creare la directory (potrebbe funzionare
        -- per alcuni scenari come DBMS_CLOUD.PUT_OBJECT paths)
        DBMS_OUTPUT.PUT_LINE('  [INFO] Attempting to create directory "' || v_dir_name ||
            '" (may not be supported in ADB)...');
    END IF;

    ---------------------------------------------------------------------------
    -- Verifica se la directory esiste gia'
    ---------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_count
    FROM all_directories
    WHERE directory_name = v_dir_name;

    IF v_count > 0 THEN
        SELECT directory_path INTO v_existing_path
        FROM all_directories
        WHERE directory_name = v_dir_name;

        DBMS_OUTPUT.PUT_LINE('  [INFO] Directory "' || v_dir_name || '" already exists.');
        DBMS_OUTPUT.PUT_LINE('         Current path: ' || v_existing_path);
        DBMS_OUTPUT.PUT_LINE('         New path:     ' || v_dir_path);

        IF v_existing_path = v_dir_path THEN
            DBMS_OUTPUT.PUT_LINE('  [INFO] Paths are identical. Skipping CREATE, updating grants.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  [INFO] Paths differ. Replacing directory with new path.');
        END IF;
    END IF;

    ---------------------------------------------------------------------------
    -- Creazione (o sostituzione) della directory
    -- CREATE OR REPLACE DIRECTORY e' idempotente
    ---------------------------------------------------------------------------
    BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY "' || v_dir_name ||
            '" AS ''' || v_dir_path || '''';
        DBMS_OUTPUT.PUT_LINE('  [OK] Directory "' || v_dir_name || '" created successfully.');
        DBMS_OUTPUT.PUT_LINE('       Path: ' || v_dir_path);
    EXCEPTION
        WHEN OTHERS THEN
            IF v_is_adb AND SQLCODE = -1031 THEN
                -- In ADB, CREATE DIRECTORY potrebbe non essere consentito
                DBMS_OUTPUT.PUT_LINE('  [ERROR] Cannot create directory in Autonomous Database.');
                DBMS_OUTPUT.PUT_LINE('          Use DATA_PUMP_DIR or OCI Object Storage.');
                DBMS_OUTPUT.PUT_LINE('          Error: ' || SQLERRM);
                GOTO end_script;
            ELSE
                RAISE;
            END IF;
    END;

    ---------------------------------------------------------------------------
    -- Assegnazione privilegi READ e WRITE
    ---------------------------------------------------------------------------
    BEGIN
        EXECUTE IMMEDIATE 'GRANT READ, WRITE ON DIRECTORY "' || v_dir_name ||
            '" TO "' || v_current_user || '"';
        DBMS_OUTPUT.PUT_LINE('  [OK] READ, WRITE granted to "' || v_current_user || '".');
    EXCEPTION
        WHEN OTHERS THEN
            -- Se l'utente corrente e' il proprietario, potrebbe non servire
            IF SQLCODE = -1917 THEN
                DBMS_OUTPUT.PUT_LINE('  [INFO] User "' || v_current_user ||
                    '" is the owner - grant not needed.');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  [WARNING] Could not grant to "' || v_current_user ||
                    '": ' || SQLERRM);
            END IF;
    END;

    -- Grant anche a PUBLIC se necessario per job Data Pump multi-utente
    -- (commentato per sicurezza - decommentare se necessario)
    -- EXECUTE IMMEDIATE 'GRANT READ, WRITE ON DIRECTORY "' || v_dir_name || '" TO PUBLIC';

    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Verifica directory creata
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- DIRECTORY VERIFICATION ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));

    FOR r IN (
        SELECT
            d.directory_name,
            d.directory_path,
            d.owner,
            (SELECT LISTAGG(p.privilege, ', ') WITHIN GROUP (ORDER BY p.privilege)
             FROM all_tab_privs p
             WHERE p.table_name = d.directory_name
               AND p.type = 'DIRECTORY'
               AND p.grantee = v_current_user
            ) AS my_privs
        FROM all_directories d
        WHERE d.directory_name = v_dir_name
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  Name:       ' || r.directory_name);
        DBMS_OUTPUT.PUT_LINE('  Path:       ' || r.directory_path);
        DBMS_OUTPUT.PUT_LINE('  Owner:      ' || r.owner);
        DBMS_OUTPUT.PUT_LINE('  My Privs:   ' || NVL(r.my_privs, 'OWNER (implicit)'));
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));

    ---------------------------------------------------------------------------
    -- Suggerimento per ADB: setup credenziali OCI
    ---------------------------------------------------------------------------
    IF v_is_adb THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  --- ADB: OCI OBJECT STORAGE SETUP ---');
        DBMS_OUTPUT.PUT_LINE('  Per utilizzare OCI Object Storage con Data Pump, creare le credenziali:');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  BEGIN');
        DBMS_OUTPUT.PUT_LINE('    DBMS_CLOUD.CREATE_CREDENTIAL(');
        DBMS_OUTPUT.PUT_LINE('      credential_name => ''OCI_CRED'',');
        DBMS_OUTPUT.PUT_LINE('      user_ocid       => ''ocid1.user.oc1...'',');
        DBMS_OUTPUT.PUT_LINE('      tenancy_ocid    => ''ocid1.tenancy.oc1...'',');
        DBMS_OUTPUT.PUT_LINE('      fingerprint     => ''xx:xx:xx:...'',');
        DBMS_OUTPUT.PUT_LINE('      private_key     => UTL_RAW.CAST_TO_VARCHAR2(');
        DBMS_OUTPUT.PUT_LINE('                           DBMS_CLOUD.GET_OBJECT(');
        DBMS_OUTPUT.PUT_LINE('                             credential_name => NULL,');
        DBMS_OUTPUT.PUT_LINE('                             object_uri => ''file:///path/to/key.pem''');
        DBMS_OUTPUT.PUT_LINE('                           ))');
        DBMS_OUTPUT.PUT_LINE('    );');
        DBMS_OUTPUT.PUT_LINE('  END;');
        DBMS_OUTPUT.PUT_LINE('  /');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  Oppure usare lo script: setup_credential.sql');
    END IF;

    <<end_script>>
    NULL;

END;
/

PROMPT
PROMPT ============================================================================
PROMPT   DIRECTORY SETUP COMPLETE
PROMPT ============================================================================
PROMPT

SET FEEDBACK ON
EXIT SUCCESS;
