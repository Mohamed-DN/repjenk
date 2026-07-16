# 🧪 Matrice di Test Completa — DARKNERO Oracle Data Pump Pipeline

Questo documento contiene **tutti** i test da eseguire per validare la pipeline
su ogni tipologia di database e ogni operazione supportata.

---

## 📊 Mappa Tipologie Database e Come Simularle

| Tipologia DARKNERO | Cosa Usa la Pipeline | Come Simularlo Gratis |
|---|---|---|
| **Autonomous ATP** (OLTP) | `DBMS_DATAPUMP` via PL/SQL + `sqlplus` | Oracle Cloud Free Tier → ATP Always Free |
| **Autonomous ADW** (Data Warehouse) | `DBMS_DATAPUMP` via PL/SQL + `sqlplus` | Oracle Cloud Free Tier → ADW Always Free |
| **DBCS** (DB Cloud Service su VM) | `expdp`/`impdp` CLI via SSH | Oracle 23ai Free locale (ha gli stessi comandi CLI) |
| **On-Premises** | `expdp`/`impdp` CLI diretto | Oracle 23ai Free locale (identico) |

> **Nota**: ATP e ADW dal punto di vista della pipeline si comportano allo stesso modo
> (entrambi usano `DBMS_DATAPUMP`). La differenza è solo nel tipo di workload Oracle.
> Per i test, basta un'istanza ATP.

---

## 🔧 Setup: I 3 Database di Test

### DB1: `LOCAL_DBCS` — Simula un DBCS/On-Prem (Oracle 23ai Free locale)
```yaml
# In config/databases_local.yaml
LOCAL_DBCS:
  type: dbcs
  description: "Locale — Simula DBCS (usa expdp/impdp CLI)"
  environment: DEV
  host: localhost
  port: 1521
  service_name: FREEPDB1
  credential_id: dn-local-dbcs-creds
  data_pump_dir: DATA_PUMP_DIR
  data_pump_path: "C:\\oracle\\datapump"
  oracle_home: "C:\\oracle\\product\\23ai"
  default_tablespace: USERS
  schemas_allowed: []
  bucket: test-datapump-dev
```

### DB2: `CLOUD_ATP` — Autonomous ATP reale (Oracle Cloud Free Tier)
```yaml
CLOUD_ATP:
  type: autonomous
  description: "Cloud Free Tier — Autonomous ATP (usa DBMS_DATAPUMP)"
  environment: DEV
  service_name: testdevatp_high
  wallet_credential_id: dn-dev-atp-wallet
  db_credential_id: dn-dev-atp-creds
  oci_region: eu-milan-1
  compartment_id: "ocid1.compartment.oc1..tuo_id"
  adb_ocid: "ocid1.autonomousdatabase.oc1..tuo_id"
  bucket: test-datapump-dev
  credential_name: OCI_CRED_DEV
  default_tablespace: DATA
  parallel: 2
  schemas_allowed: []
```

### DB3: `LOCAL_DBCS_TARGET` — Secondo database locale per import
```yaml
LOCAL_DBCS_TARGET:
  type: dbcs
  description: "Locale — Target per import e swap"
  environment: DEV
  host: localhost
  port: 1521
  service_name: FREEPDB1
  credential_id: dn-local-target-creds
  data_pump_dir: DATA_PUMP_DIR
  data_pump_path: "C:\\oracle\\datapump"
  oracle_home: "C:\\oracle\\product\\23ai"
  default_tablespace: USERS
  schemas_allowed: []
```

### Schemi da Creare su Ogni Database

```sql
-- Esegui su ENTRAMBI i database (locale e cloud)
-- Connettiti come SYS/ADMIN

-- Schema sorgente con dati
CREATE USER dn_test IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;  -- su locale
  -- oppure DATA su Autonomous
GRANT CONNECT, RESOURCE, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE TO dn_test;

-- Schema target vuoto
CREATE USER dn_test_target IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO dn_test_target;

-- Schema per swap test
CREATE USER dn_test_new IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO dn_test_new;
```

Popola `dn_test` con dati di test diversificati:

```sql
-- Connettiti come dn_test
CREATE TABLE employees (
    id NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    email VARCHAR2(200),
    salary NUMBER(10,2),
    ssn VARCHAR2(20),           -- dato sensibile (per test Data Masking)
    department VARCHAR2(50),
    created_date DATE DEFAULT SYSDATE
);

CREATE TABLE projects (
    id NUMBER PRIMARY KEY,
    project_name VARCHAR2(200),
    budget NUMBER(12,2),
    status VARCHAR2(20),
    start_date DATE
);

CREATE TABLE audit_log (
    id NUMBER PRIMARY KEY,
    action VARCHAR2(50),
    log_date DATE,
    details CLOB                -- per testare export di LOB
);

-- Tabella grande (per testare parallelismo e compressione)
CREATE TABLE transactions (
    id NUMBER PRIMARY KEY,
    account_id NUMBER,
    amount NUMBER(12,2),
    tx_date DATE,
    description VARCHAR2(500)
);

-- Popola con dati
BEGIN
    FOR i IN 1..5000 LOOP
        INSERT INTO employees VALUES (
            i, 'Emp_'||i, 'emp'||i||'@darknero.com',
            ROUND(DBMS_RANDOM.VALUE(25000,150000),2),
            'SSN-'||LPAD(i,9,'0'),
            CASE MOD(i,5) WHEN 0 THEN 'IT' WHEN 1 THEN 'FINANCE'
              WHEN 2 THEN 'HR' WHEN 3 THEN 'OPERATIONS' ELSE 'LEGAL' END,
            SYSDATE - DBMS_RANDOM.VALUE(0,730)
        );
        INSERT INTO transactions VALUES (
            i, MOD(i,100)+1,
            ROUND(DBMS_RANDOM.VALUE(-50000,50000),2),
            SYSDATE - DBMS_RANDOM.VALUE(0,365),
            'Transaction #'||i||' - '||DBMS_RANDOM.STRING('A',50)
        );
    END LOOP;
    FOR i IN 1..10 LOOP
        INSERT INTO projects VALUES (
            i, 'Progetto_'||CHR(64+i), ROUND(DBMS_RANDOM.VALUE(100000,5000000),2),
            CASE MOD(i,3) WHEN 0 THEN 'ACTIVE' WHEN 1 THEN 'COMPLETED' ELSE 'PLANNED' END,
            SYSDATE - DBMS_RANDOM.VALUE(0,365)
        );
    END LOOP;
    FOR i IN 1..100 LOOP
        INSERT INTO audit_log VALUES (
            i, 'ACTION_'||MOD(i,5), SYSDATE - i,
            'Log entry details for action #'||i||' with extended description'
        );
    END LOOP;
    COMMIT;
END;
/

-- Crea una VIEW (per verificare export METADATA_ONLY)
CREATE VIEW v_active_projects AS
  SELECT * FROM projects WHERE status = 'ACTIVE';

-- Crea un INDEX (per verificare ricostruzione post-import)
CREATE INDEX idx_emp_dept ON employees(department);
CREATE INDEX idx_tx_date ON transactions(tx_date);
```

---

## ✅ MATRICE DI TEST

### Legenda
- 🟢 = Deve funzionare (percorso principale)
- 🔵 = Test opzionale ma consigliato
- ⚪ = Non applicabile

---

### GRUPPO 1: Operazioni Base per Tipologia

| # | Test | Operazione | Sorgente | Target | Path Atteso | Stato |
|---|---|---|---|---|---|---|
| 1.1 | Health Check DBCS | `HEALTH_CHECK` | `LOCAL_DBCS` | — | CLI `sqlplus` | ⬜ |
| 1.2 | Health Check Autonomous | `HEALTH_CHECK` | `CLOUD_ATP` | — | `sqlplus` + wallet | ⬜ |
| 1.3 | Export DBCS | `EXPORT` | `LOCAL_DBCS` | — | `expdp` CLI | ⬜ |
| 1.4 | Export Autonomous | `EXPORT` | `CLOUD_ATP` | — | `DBMS_DATAPUMP` PL/SQL | ⬜ |
| 1.5 | Import DBCS | `IMPORT` | `LOCAL_DBCS` | `LOCAL_DBCS_TARGET` | `impdp` CLI | ⬜ |
| 1.6 | Import Autonomous | `IMPORT` | `CLOUD_ATP` | `CLOUD_ATP` | `DBMS_DATAPUMP` PL/SQL | ⬜ |

### GRUPPO 2: Flussi Cross-Type (Il Cuore di DARKNERO)

| # | Test | Operazione | Sorgente | Target | Cosa Testa |Stato |
|---|---|---|---|---|---|---|
| 2.1 | Export DBCS → Bucket → Import Autonomous | `EXPORT_AND_IMPORT` | `LOCAL_DBCS` | `CLOUD_ATP` | Upload OCI + PL/SQL import | ⬜ |
| 2.2 | Export Autonomous → Bucket → Import DBCS | `EXPORT_AND_IMPORT` | `CLOUD_ATP` | `LOCAL_DBCS_TARGET` | PL/SQL export + CLI import | ⬜ |
| 2.3 | Refresh DBCS → Autonomous | `REFRESH_ENV` | `LOCAL_DBCS` | `CLOUD_ATP` | Flusso completo cross-type | ⬜ |

### GRUPPO 3: Opzioni di Remap

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 3.1 | Import con REMAP_SCHEMA | `IMPORT` su DBCS | `REMAP_SCHEMA=dn_test:dn_test_target` | Remap schema base | ⬜ |
| 3.2 | Import con REMAP_TABLESPACE | `IMPORT` su DBCS | `REMAP_TABLESPACE=USERS:SYSAUX` | Cambio tablespace | ⬜ |
| 3.3 | Import con CREATE_NEW_SCHEMA | `IMPORT` su DBCS | `CREATE_NEW_SCHEMA=true` | Crea `dn_test_NEW` | ⬜ |
| 3.4 | Remap su Autonomous | `IMPORT` su ATP | `REMAP_SCHEMA=dn_test:dn_test_target` | PL/SQL `METADATA_REMAP` | ⬜ |

### GRUPPO 4: Export/Import Tabelle Specifiche

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 4.1 | Export singola tabella DBCS | `TABLE_EXPORT` su DBCS | `TABLE_LIST=EMPLOYEES` | Filtro tabelle CLI | ⬜ |
| 4.2 | Export singola tabella ATP | `TABLE_EXPORT` su ATP | `TABLE_LIST=EMPLOYEES` | Filtro tabelle PL/SQL | ⬜ |
| 4.3 | Export multi-tabella | `TABLE_EXPORT` | `TABLE_LIST=EMPLOYEES,PROJECTS` | Lista multipla | ⬜ |
| 4.4 | Import singola tabella | `TABLE_IMPORT` su DBCS | `TABLE_LIST=EMPLOYEES` | Import selettivo | ⬜ |
| 4.5 | Export con esclusione | `EXPORT` su DBCS | `EXCLUDE_TABLES=AUDIT_LOG` | `EXCLUDE=TABLE` | ⬜ |
| 4.6 | Export con esclusione ATP | `EXPORT` su ATP | `EXCLUDE_TABLES=AUDIT_LOG` | `METADATA_FILTER EXCLUDE` | ⬜ |

### GRUPPO 5: Filtri e Contenuto

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 5.1 | Export METADATA_ONLY | `EXPORT` | `CONTENT=METADATA_ONLY` | Solo struttura, zero dati | ⬜ |
| 5.2 | Export DATA_ONLY | `EXPORT` | `CONTENT=DATA_ONLY` | Solo dati, zero DDL | ⬜ |
| 5.3 | Export con QUERY_FILTER | `EXPORT` | `QUERY_FILTER=WHERE department='IT'` | Filtro WHERE | ⬜ |
| 5.4 | Import con TABLE_EXISTS_ACTION=REPLACE | `IMPORT` | reimporta sullo stesso schema | Drop + Recreate | ⬜ |
| 5.5 | Import con TABLE_EXISTS_ACTION=APPEND | `IMPORT` | reimporta sullo stesso schema | Aggiunge righe | ⬜ |
| 5.6 | Import con TABLE_EXISTS_ACTION=TRUNCATE | `IMPORT` | reimporta sullo stesso schema | Svuota + Reinserisce | ⬜ |

### GRUPPO 6: Performance e Compressione

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 6.1 | Export PARALLEL=1 | `EXPORT` | `PARALLEL=1` | Baseline di velocità | ⬜ |
| 6.2 | Export PARALLEL=4 | `EXPORT` | `PARALLEL=4` | Confronta con 6.1 | ⬜ |
| 6.3 | Export COMPRESSION=NONE | `EXPORT` | `COMPRESSION=NONE` | Dimensione dump base | ⬜ |
| 6.4 | Export COMPRESSION=ALL | `EXPORT` | `COMPRESSION=ALL` | Confronta dimensione con 6.3 | ⬜ |

### GRUPPO 7: Sicurezza e Data Masking

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 7.1 | Export con Data Masking | `EXPORT` | `ENABLE_DATA_MASKING=true`, `MASKING_RULES=dn_test.EMPLOYEES.SSN:DN_DATA_MASKING.MASK_SSN` | Colonna SSN offuscata | ⬜ |
| 7.2 | Blocco QUERY_FILTER injection | `EXPORT` | `QUERY_FILTER=WHERE 1=1; DROP TABLE x` | Deve fallire in validazione | ⬜ |
| 7.3 | Blocco caratteri speciali | `EXPORT` | `SCHEMA_NAME=test'; DROP--` | Deve fallire in validazione | ⬜ |
| 7.4 | DRY_RUN mode | `EXPORT` | `DRY_RUN=true` | Simula senza eseguire | ⬜ |

### GRUPPO 8: Swap and Drop

| # | Test | Operazione | Prerequisiti | Opzioni | Stato |
|---|---|---|---|---|---|
| 8.1 | Swap schema DBCS | `SWAP_AND_DROP` su DBCS | Crea `dn_test_NEW` con dati | `DROP_OLD_AFTER_SWAP=false` | ⬜ |
| 8.2 | Swap + Drop DBCS | `SWAP_AND_DROP` su DBCS | Crea `dn_test_NEW` | `DROP_OLD_AFTER_SWAP=true` | ⬜ |
| 8.3 | Import + Swap automatico | `IMPORT` su DBCS | — | `CREATE_NEW_SCHEMA=true`, `SWAP_AFTER_IMPORT=true` | ⬜ |

### GRUPPO 9: Backup e Cleanup

| # | Test | Operazione | Opzioni | Cosa Testa | Stato |
|---|---|---|---|---|---|
| 9.1 | Backup schedulato | `BACKUP` | — | Naming convention con timestamp | ⬜ |
| 9.2 | Cleanup vecchi dump | — | `RETENTION_DAYS=1` | Stage Cleanup Object Storage | ⬜ |

### GRUPPO 10: Notifiche e Report

| # | Test | Cosa Verificare | Stato |
|---|---|---|---|
| 10.1 | Email di successo | Ricevi email con report HTML dopo export riuscito | ⬜ |
| 10.2 | Email di errore | Ricevi email con dettagli errore dopo export fallito | ⬜ |
| 10.3 | Report conteggio record | Post-verification confronta source vs target | ⬜ |
| 10.4 | Audit JSON | File audit generato in formato JSON (Splunk/ELK) | ⬜ |

---

## 📝 Come Eseguire i Test

### Passo 1: Prepara l'ambiente
Segui `DEV_SETUP_GUIDE.md` per installare Jenkins + Oracle locale + Oracle Cloud ATP.

### Passo 2: Parti dal Gruppo 1
I test del Gruppo 1 sono i fondamentali. Se funzionano, il 90% della pipeline è OK.

### Passo 3: Procedi in ordine
Ogni gruppo testa una funzionalità diversa. Spunta ⬜ → ✅ man mano.

### Passo 4: Annota i risultati
Per ogni test, annota:
- ✅ Passato / ❌ Fallito
- Tempo di esecuzione
- Dimensione dump (per i test di compressione)
- Eventuali errori nei log

---

## 🏗️ Architettura di Test Visiva

```
┌─────────────────────────────────────────────────────────────────┐
│                        JENKINS (localhost:8080)                  │
│                     Pipeline: Jenkinsfile                        │
│                     Librerie: vars/*.groovy                      │
└────────────┬───────────────────────────────┬────────────────────┘
             │                               │
     ┌───────▼───────┐              ┌───────▼────────┐
     │  Path CLI      │              │  Path PL/SQL   │
     │  (expdp/impdp) │              │ (DBMS_DATAPUMP)│
     └───────┬───────┘              └───────┬────────┘
             │                               │
     ┌───────▼───────┐              ┌───────▼────────┐
     │  LOCAL_DBCS    │              │  CLOUD_ATP     │
     │ Oracle 23ai    │              │ Autonomous DB  │
     │ Free (locale)  │              │ (OCI Free Tier)│
     │ porta 1521     │              │ via Wallet+SSL │
     └───────┬───────┘              └───────┬────────┘
             │                               │
             └───────────┬───────────────────┘
                         │
                ┌────────▼─────────┐
                │  OCI Object      │
                │  Storage Bucket  │
                │ (test-datapump)  │
                │ Dump file .dmp   │
                └──────────────────┘
```

Buon testing! 🚀
