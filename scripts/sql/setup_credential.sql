--------------------------------------------------------------------------------
-- Script:      setup_credential.sql
-- Purpose:     Creazione credenziali OCI per Autonomous Database
--              Creates OCI credentials for DBMS_CLOUD operations (ADB only)
-- Parameters:  &1 = credential_name
--              &2 = oci_user_ocid
--              &3 = oci_tenancy_ocid
--              &4 = oci_fingerprint
--              &5 = oci_private_key_path (path to PEM key file on local system,
--                    or paste the key content directly)
-- Author:      ENI DBA Team
-- Date:        2026-07-12
-- Platform:    Oracle Autonomous DB (ATP/ADW) ONLY
-- Notes:       Questo script funziona SOLO su Autonomous Database.
--              Le credenziali sono necessarie per accedere a OCI Object Storage.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 50
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET DEFINE '&'

WHENEVER SQLERROR EXIT SQL.SQLCODE

DEFINE cred_name       = &1
DEFINE oci_user_ocid   = &2
DEFINE oci_tenancy_ocid = &3
DEFINE oci_fingerprint = &4
DEFINE oci_private_key = &5

PROMPT
PROMPT ============================================================================
PROMPT   ENI DATA PUMP PIPELINE - OCI CREDENTIAL SETUP (Autonomous DB)
PROMPT   Credential Name: &cred_name
PROMPT ============================================================================
PROMPT

DECLARE
    v_cred_name     VARCHAR2(128)  := UPPER('&cred_name');
    v_user_ocid     VARCHAR2(500)  := '&oci_user_ocid';
    v_tenancy_ocid  VARCHAR2(500)  := '&oci_tenancy_ocid';
    v_fingerprint   VARCHAR2(200)  := '&oci_fingerprint';
    v_private_key   VARCHAR2(32000);
    v_key_input     VARCHAR2(4000) := '&oci_private_key';
    v_count         NUMBER         := 0;
    v_is_adb        BOOLEAN        := FALSE;
    v_current_user  VARCHAR2(128)  := SYS_CONTEXT('USERENV', 'CURRENT_USER');

BEGIN
    ---------------------------------------------------------------------------
    -- Verifica che siamo su Autonomous Database
    -- DBMS_CLOUD e' disponibile solo su ADB
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
        WHEN OTHERS THEN
            v_is_adb := FALSE;
    END;

    IF NOT v_is_adb THEN
        DBMS_OUTPUT.PUT_LINE('  [ERROR] DBMS_CLOUD package not found.');
        DBMS_OUTPUT.PUT_LINE('  This script is designed for Oracle Autonomous Database ONLY.');
        DBMS_OUTPUT.PUT_LINE('  Per DBCS/On-Premises, utilizzare wallet o directory objects.');
        RAISE_APPLICATION_ERROR(-20001,
            'DBMS_CLOUD not available. This script requires Autonomous Database.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('  [OK] Autonomous Database detected. DBMS_CLOUD available.');
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Validazione parametri di input
    ---------------------------------------------------------------------------
    IF v_user_ocid IS NULL OR LENGTH(v_user_ocid) < 10 THEN
        RAISE_APPLICATION_ERROR(-20002,
            'Invalid OCI User OCID. Must start with "ocid1.user.oc1..".');
    END IF;

    IF v_tenancy_ocid IS NULL OR LENGTH(v_tenancy_ocid) < 10 THEN
        RAISE_APPLICATION_ERROR(-20003,
            'Invalid OCI Tenancy OCID. Must start with "ocid1.tenancy.oc1..".');
    END IF;

    IF v_fingerprint IS NULL OR LENGTH(v_fingerprint) < 10 THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Invalid OCI fingerprint. Expected format: xx:xx:xx:xx:...');
    END IF;

    DBMS_OUTPUT.PUT_LINE('  Parameter validation:');
    DBMS_OUTPUT.PUT_LINE('  User OCID:    ' || SUBSTR(v_user_ocid, 1, 30) || '...');
    DBMS_OUTPUT.PUT_LINE('  Tenancy OCID: ' || SUBSTR(v_tenancy_ocid, 1, 30) || '...');
    DBMS_OUTPUT.PUT_LINE('  Fingerprint:  ' || v_fingerprint);
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Gestione chiave privata
    -- Se il parametro inizia con '-----BEGIN', e' il contenuto della chiave.
    -- Altrimenti, e' un percorso file da cui leggere la chiave.
    ---------------------------------------------------------------------------
    IF v_key_input LIKE '-----BEGIN%' THEN
        -- Il contenuto della chiave e' stato passato direttamente
        v_private_key := v_key_input;
        DBMS_OUTPUT.PUT_LINE('  [INFO] Private key content provided directly.');
    ELSE
        -- Tentativo di leggere il file dalla directory Oracle
        DBMS_OUTPUT.PUT_LINE('  [INFO] Attempting to read private key from path: ' || v_key_input);
        DBMS_OUTPUT.PUT_LINE('  [NOTE] Per ADB, la chiave privata deve essere fornita come contenuto.');
        DBMS_OUTPUT.PUT_LINE('         Passare il contenuto PEM direttamente come parametro &5.');
        DBMS_OUTPUT.PUT_LINE('');

        -- In ADB, non possiamo leggere file dal filesystem locale.
        -- L'utente deve passare il contenuto della chiave come stringa.
        RAISE_APPLICATION_ERROR(-20005,
            'In Autonomous DB, private key must be provided as PEM content, ' ||
            'not as a file path. Pass the key content as parameter &5.');
    END IF;

    ---------------------------------------------------------------------------
    -- Verifica se la credenziale esiste gia'
    ---------------------------------------------------------------------------
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM all_credentials
        WHERE credential_name = v_cred_name
          AND owner = v_current_user;
    EXCEPTION
        WHEN OTHERS THEN
            -- Vista non disponibile, prova alternativa
            v_count := 0;
            BEGIN
                SELECT COUNT(*) INTO v_count
                FROM user_credentials
                WHERE credential_name = v_cred_name;
            EXCEPTION
                WHEN OTHERS THEN v_count := 0;
            END;
    END;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [INFO] Credential "' || v_cred_name || '" already exists.');
        DBMS_OUTPUT.PUT_LINE('  [INFO] Dropping existing credential and recreating...');

        BEGIN
            DBMS_CLOUD.DROP_CREDENTIAL(
                credential_name => v_cred_name
            );
            DBMS_OUTPUT.PUT_LINE('  [OK] Existing credential dropped.');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  [WARNING] Could not drop existing credential: ' || SQLERRM);
                DBMS_OUTPUT.PUT_LINE('  [INFO] Attempting to create anyway (may fail if duplicate)...');
        END;
    END IF;

    ---------------------------------------------------------------------------
    -- Creazione credenziale OCI
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  Creating OCI credential "' || v_cred_name || '"...');

    BEGIN
        DBMS_CLOUD.CREATE_CREDENTIAL(
            credential_name => v_cred_name,
            user_ocid       => v_user_ocid,
            tenancy_ocid    => v_tenancy_ocid,
            fingerprint     => v_fingerprint,
            private_key     => v_private_key
        );

        DBMS_OUTPUT.PUT_LINE('  [OK] Credential "' || v_cred_name || '" created successfully!');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  [ERROR] Failed to create credential: ' || SQLERRM);
            RAISE;
    END;

    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Verifica che la credenziale sia stata creata
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- CREDENTIAL VERIFICATION ---');
    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));

    DECLARE
        v_found BOOLEAN := FALSE;
    BEGIN
        FOR r IN (
            SELECT
                credential_name,
                username,
                enabled,
                comments
            FROM user_credentials
            WHERE credential_name = v_cred_name
        ) LOOP
            v_found := TRUE;
            DBMS_OUTPUT.PUT_LINE('  Credential Name:  ' || r.credential_name);
            DBMS_OUTPUT.PUT_LINE('  Username:         ' || NVL(r.username, 'N/A'));
            DBMS_OUTPUT.PUT_LINE('  Enabled:          ' || r.enabled);
            DBMS_OUTPUT.PUT_LINE('  Comments:         ' || NVL(r.comments, 'N/A'));
        END LOOP;

        IF NOT v_found THEN
            -- Prova con ALL_CREDENTIALS
            FOR r IN (
                SELECT credential_name, owner, enabled
                FROM all_credentials
                WHERE credential_name = v_cred_name
            ) LOOP
                v_found := TRUE;
                DBMS_OUTPUT.PUT_LINE('  Credential Name:  ' || r.credential_name);
                DBMS_OUTPUT.PUT_LINE('  Owner:            ' || r.owner);
                DBMS_OUTPUT.PUT_LINE('  Enabled:          ' || r.enabled);
            END LOOP;
        END IF;

        IF NOT v_found THEN
            DBMS_OUTPUT.PUT_LINE('  [WARNING] Could not verify credential in catalog views.');
            DBMS_OUTPUT.PUT_LINE('  The credential may still be valid - verify with a test operation.');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  [INFO] Cannot query credential views: ' || SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('  ' || RPAD('-', 60, '-'));
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Suggerimento per test della credenziale
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  --- TEST SUGGESTION ---');
    DBMS_OUTPUT.PUT_LINE('  Per verificare la credenziale, eseguire:');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  SELECT * FROM DBMS_CLOUD.LIST_OBJECTS(');
    DBMS_OUTPUT.PUT_LINE('    credential_name => ''' || v_cred_name || ''',');
    DBMS_OUTPUT.PUT_LINE('    location_uri    => ''https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/''');
    DBMS_OUTPUT.PUT_LINE('  );');
    DBMS_OUTPUT.PUT_LINE('');

    ---------------------------------------------------------------------------
    -- Riepilogo finale
    ---------------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  CREDENTIAL SETUP COMPLETE');
    DBMS_OUTPUT.PUT_LINE('  ============================================================');
    DBMS_OUTPUT.PUT_LINE('  Credential:     ' || v_cred_name);
    DBMS_OUTPUT.PUT_LINE('  Owner:          ' || v_current_user);
    DBMS_OUTPUT.PUT_LINE('  Status:         CREATED');
    DBMS_OUTPUT.PUT_LINE('  ============================================================');

END;
/

PROMPT
PROMPT ============================================================================
PROMPT   CREDENTIAL SETUP COMPLETE
PROMPT ============================================================================
PROMPT

SET FEEDBACK ON
EXIT SUCCESS;
