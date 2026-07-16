CREATE OR REPLACE PACKAGE M_DN_DATA_MASKING AS
    -- =========================================================================
    -- Package: M_DN_DATA_MASKING
    -- Scopo:   Fornire funzioni standardizzate per il Data Masking di dati 
    --          sensibili (GDPR compliance) durante le operazioni di 
    --          refresh degli ambienti (PROD -> DEV/UAT) via Data Pump.
    -- =========================================================================

    -- Mascheramento Email (es. mario.rossi@m-dn.com -> m***.r***@m-dn.com)
    FUNCTION mask_email(p_email IN VARCHAR2) RETURN VARCHAR2;

    -- Mascheramento Numero di Telefono (es. +393451234567 -> +39345XXXXXXX)
    FUNCTION mask_phone(p_phone IN VARCHAR2) RETURN VARCHAR2;

    -- Mascheramento Codice Fiscale (lascia visibili solo i primi e ultimi 3 caratteri)
    FUNCTION mask_cf(p_cf IN VARCHAR2) RETURN VARCHAR2;

    -- Mascheramento IBAN
    FUNCTION mask_iban(p_iban IN VARCHAR2) RETURN VARCHAR2;

    -- Mascheramento Stringa generica
    FUNCTION mask_string(p_string IN VARCHAR2) RETURN VARCHAR2;

END M_DN_DATA_MASKING;
/

CREATE OR REPLACE PACKAGE BODY M_DN_DATA_MASKING AS

    FUNCTION mask_email(p_email IN VARCHAR2) RETURN VARCHAR2 IS
        v_at_pos NUMBER;
        v_domain VARCHAR2(100);
        v_name   VARCHAR2(100);
    BEGIN
        IF p_email IS NULL THEN
            RETURN NULL;
        END IF;

        v_at_pos := INSTR(p_email, '@');
        IF v_at_pos > 0 THEN
            v_name := SUBSTR(p_email, 1, v_at_pos - 1);
            v_domain := SUBSTR(p_email, v_at_pos);
            -- Maschera il nome lasciando la prima lettera (e la prima dopo l'eventuale punto)
            RETURN SUBSTR(v_name, 1, 1) || '***' || 
                   CASE WHEN INSTR(v_name, '.') > 0 THEN 
                       '.' || SUBSTR(v_name, INSTR(v_name, '.') + 1, 1) || '***' 
                   ELSE '' END || v_domain;
        END IF;
        
        RETURN '***@***.***';
    END mask_email;

    FUNCTION mask_phone(p_phone IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_phone IS NULL THEN
            RETURN NULL;
        END IF;
        -- Preserva le prime 5 cifre (prefisso + prime 2 del gestore) e sostituisci il resto con X
        IF LENGTH(p_phone) > 5 THEN
            RETURN SUBSTR(p_phone, 1, 5) || LPAD('X', LENGTH(p_phone) - 5, 'X');
        END IF;
        RETURN 'XXXXXX';
    END mask_phone;

    FUNCTION mask_cf(p_cf IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_cf IS NULL OR LENGTH(p_cf) != 16 THEN
            RETURN p_cf; -- Ritorna come-è se non è un CF valido a 16 cifre
        END IF;
        -- Ritorna: RSS***...***M123A
        RETURN SUBSTR(p_cf, 1, 3) || LPAD('*', 10, '*') || SUBSTR(p_cf, 14, 3);
    END mask_cf;

    FUNCTION mask_iban(p_iban IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_iban IS NULL THEN
            RETURN NULL;
        END IF;
        -- Preserva solo paese/cin (primi 2) e ultime 4 cifre
        IF LENGTH(p_iban) > 10 THEN
            RETURN SUBSTR(p_iban, 1, 4) || LPAD('*', LENGTH(p_iban) - 8, '*') || SUBSTR(p_iban, -4);
        END IF;
        RETURN p_iban;
    END mask_iban;

    FUNCTION mask_string(p_string IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_string IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN 'MASKED_' || DBMS_RANDOM.STRING('X', 8);
    END mask_string;

END M_DN_DATA_MASKING;
/
