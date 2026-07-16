# 🧪 Guida Setup Ambiente di Sviluppo Locale (100% Gratuito)

Questa guida ti spiega come installare e configurare un ambiente completo sul tuo PC Windows per **testare la pipeline Jenkins + Oracle Data Pump** senza spendere un centesimo.

---

## 📋 Cosa Ti Serve (Riepilogo)

| Componente | Prodotto Gratuito | A Cosa Serve |
|---|---|---|
| **Jenkins** | Jenkins LTS (open source) | Eseguire la pipeline |
| **Java** | Eclipse Temurin JDK 17 | Far girare Jenkins |
| **Oracle DB** | Oracle 23ai Free | Database locale per testare export/import |
| **Oracle Client** | Oracle Instant Client 23ai | Comandi `sqlplus`, `expdp`, `impdp` |
| **Docker** (opzionale) | Docker Desktop (free per dev) | Alternativa più veloce per Oracle DB |
| **Git** | Git for Windows | Già ce l'hai |

---

## 🔧 STEP 1: Installare Java (JDK 17)

Jenkins richiede Java. Scarica **Eclipse Temurin JDK 17** (gratuito, open source):

1. Vai su: https://adoptium.net/temurin/releases/
2. Scarica il **.msi** per Windows x64, versione **JDK 17** (LTS)
3. Installa con le opzioni di default (lascia "Set JAVA_HOME" spuntato)
4. Verifica:
   ```powershell
   java -version
   # Deve mostrare: openjdk version "17.x.x"
   ```

---

## 🔧 STEP 2: Installare Jenkins

1. Vai su: https://www.jenkins.io/download/
2. Scarica **Windows LTS** (.msi)
3. Durante l'installazione:
   - Scegli "Run service as LocalSystem" (per semplicità in dev)
   - La porta di default è **8080**
4. Al termine, apri il browser: **http://localhost:8080**
5. Jenkins ti chiederà la password iniziale. La trovi nel file:
   ```
   C:\ProgramData\Jenkins\.jenkins\secrets\initialAdminPassword
   ```
6. Copia la password, incollala, e clicca **"Install suggested plugins"**
7. Crea il tuo utente admin

### Plugin Aggiuntivi da Installare
Dopo il primo accesso, vai in **Manage Jenkins → Plugins → Available plugins** e installa:
- `Pipeline Utility Steps` (per `readYaml`)
- `AnsiColor` (per output colorato)
- `Email Extension` (per notifiche)

---

## 🔧 STEP 3: Installare Oracle Database

In aziende come DARKNERO il parco database è misto: **Oracle 19c** (la versione Long Term Support
più diffusa in produzione) e **Oracle 23ai** (la versione più recente). Per testare la pipeline
su entrambe le versioni, installa almeno una delle due — idealmente entrambe.

### Opzione A: Oracle 23ai Free (Installazione Diretta su Windows)

Oracle 23ai Free è la versione gratuita più recente:
- Fino a 12 GB di dati utente, 2 GB di RAM
- Data Pump completamente funzionante
- Supporta tutte le feature nuove (JSON Duality, AI Vector Search, ecc.)

1. Vai su: https://www.oracle.com/database/free/
2. Scarica **Oracle Database 23ai Free** per Windows (richiede account Oracle gratuito)
3. Esegui l'installer e segui le istruzioni
4. Ricorda la password che imposti per **SYS** e **SYSTEM**
5. Verifica:
   ```powershell
   sqlplus sys/TuaPassword@localhost:1521/FREEPDB1 as sysdba
   # Se vedi "Connected to: Oracle Database 23ai Free" → funziona!
   ```

### Opzione B: Oracle 19c XE (Express Edition) ⭐ Fondamentale per compatibilità DARKNERO

Oracle 19c è la versione che troverai sui database PROD di DARKNERO. Testare anche su 19c
ti garantisce che la pipeline non usi feature disponibili solo su 23ai.

**Installazione diretta su Windows:**
1. Vai su: https://www.oracle.com/database/technologies/xe-downloads.html
2. Scarica **Oracle Database 19c XE** per Windows (`.exe`, ~1.5 GB)
3. Esegui l'installer
4. Porta di default: **1522** (se hai già 23ai su 1521) oppure **1521**
5. Ricorda la password che imposti per SYS/SYSTEM
6. Verifica:
   ```powershell
   sqlplus sys/TuaPassword@localhost:1521/XEPDB1 as sysdba
   # Se vedi "Connected to: Oracle Database 19c Express Edition" → funziona!
   ```

> ⚠️ **Se installi sia 23ai che 19c sullo stesso PC**, usa porte diverse (es. 1521 per 23ai, 1522 per 19c)
> e `ORACLE_HOME` diversi. La variabile `TNS_ADMIN` può puntare a un unico `tnsnames.ora`
> con entrambi i servizi.

### Opzione C: Docker (Entrambe le Versioni in Parallelo) 🐳 Consigliata

Docker è il modo più comodo per avere entrambe le versioni contemporaneamente
senza conflitti di porte o `ORACLE_HOME`:

```powershell
# --- Oracle 23ai Free (porta 1521) ---
docker run -d --name oracle-23ai `
  -p 1521:1521 -p 5500:5500 `
  -e ORACLE_PWD=OracleTest123 `
  container-registry.oracle.com/database/free:latest

# --- Oracle 19c XE (porta 1522) ---
docker run -d --name oracle-19c `
  -p 1522:1521 -p 5501:5500 `
  -e ORACLE_PWD=OracleTest123 `
  container-registry.oracle.com/database/express:21.3.0-xe
  # Nota: l'immagine ufficiale Oracle XE su container registry è 21c.
  # Per 19c puro, usa l'immagine della community:
  # gvenzl/oracle-xe:19-slim

# Alternativa per 19c reale:
docker run -d --name oracle-19c `
  -p 1522:1521 `
  -e ORACLE_PWD=OracleTest123 `
  gvenzl/oracle-xe:19-slim

# Attendi 2-3 minuti per ogni container, poi verifica:
docker logs -f oracle-23ai
docker logs -f oracle-19c
# Quando vedi "DATABASE IS READY TO USE!" → è pronto

# Connessione 23ai:
sqlplus sys/OracleTest123@localhost:1521/FREEPDB1 as sysdba

# Connessione 19c:
sqlplus sys/OracleTest123@localhost:1522/XEPDB1 as sysdba
```

### Differenze Chiave tra 19c e 23ai per Data Pump

| Feature | Oracle 19c | Oracle 23ai |
|---|---|---|
| `DBMS_DATAPUMP` | ✅ Completo | ✅ Completo |
| `DBMS_CLOUD` (Autonomous) | ✅ Disponibile su ATP/ADW | ✅ Disponibile |
| `DBMS_DATAPUMP.KU$_FILE_TYPE_*` | ✅ Costanti standard | ✅ Identiche |
| `job_name` max length | 30 caratteri | 128 caratteri |
| `VERSION` parameter | Fino a `19.0` | Fino a `23.0` |
| Compressione `ALL` | Richiede licenza Advanced | Richiede licenza Advanced |
| `DATA_PUMP_DIR` default | `/u01/app/oracle/admin/XE/dpdump/` | Simile, varia |

> **Importante**: Quando esporti da 23ai e importi su 19c, devi usare `VERSION=19.0`
> nel `DBMS_DATAPUMP.OPEN()` per evitare incompatibilità. La pipeline gestisce già
> questo caso nel parametro `version => 'COMPATIBLE'`.


---

## 🔧 STEP 4: Installare Oracle Instant Client (sqlplus, expdp, impdp)

Se hai installato Oracle 23ai Free direttamente (Opzione A), hai già tutti i tool.
Se usi Docker (Opzione B), ti serve il client sulla macchina host:

1. Vai su: https://www.oracle.com/database/technologies/instant-client/winx64-64-downloads.html
2. Scarica questi 3 pacchetti ZIP (versione 23ai o 19c):
   - **Basic** (librerie base)
   - **SQL*Plus** (per eseguire query)
   - **Tools** (contiene `expdp` e `impdp`)
3. Estrai tutti e 3 nella stessa cartella, es: `C:\oracle\instantclient_23`
4. Aggiungi al PATH di Windows:
   ```powershell
   # Temporaneo (per questa sessione):
   $env:PATH = "C:\oracle\instantclient_23;$env:PATH"
   $env:ORACLE_HOME = "C:\oracle\instantclient_23"
   
   # Permanente (esegui come Amministratore):
   [System.Environment]::SetEnvironmentVariable("PATH", "C:\oracle\instantclient_23;$([System.Environment]::GetEnvironmentVariable('PATH','Machine'))", "Machine")
   [System.Environment]::SetEnvironmentVariable("ORACLE_HOME", "C:\oracle\instantclient_23", "Machine")
   ```
5. Verifica:
   ```powershell
   sqlplus -version
   expdp help=y
   ```

---

## 🔧 STEP 5: Creare Schemi di Test nel Database

Connettiti al database e crea 2 schemi finti per testare export/import:

```sql
-- Connettiti come SYS
sqlplus sys/TuaPassword@localhost:1521/FREEPDB1 as sysdba

-- Crea schema sorgente
CREATE USER test_source IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, CREATE TABLE, EXP_FULL_DATABASE TO test_source;

-- Crea schema destinazione (vuoto, per l'import)
CREATE USER test_target IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, IMP_FULL_DATABASE TO test_target;

-- Crea Oracle Directory per Data Pump
CREATE OR REPLACE DIRECTORY DATA_PUMP_DIR AS 'C:\oracle\datapump';
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO test_source;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO test_target;

EXIT;
```

```powershell
# Crea la cartella fisica per i dump
New-Item -ItemType Directory -Path "C:\oracle\datapump" -Force
```

Poi popola lo schema sorgente con dati di test:

```sql
-- Connettiti come test_source
sqlplus test_source/TestPass123@localhost:1521/FREEPDB1

CREATE TABLE employees (
    id NUMBER PRIMARY KEY,
    name VARCHAR2(100),
    email VARCHAR2(200),
    salary NUMBER(10,2),
    department VARCHAR2(50),
    created_date DATE DEFAULT SYSDATE
);

-- Inserisci dati finti
BEGIN
    FOR i IN 1..1000 LOOP
        INSERT INTO employees VALUES (
            i,
            'Employee_' || i,
            'emp' || i || '@darknero.com',
            ROUND(DBMS_RANDOM.VALUE(30000, 120000), 2),
            CASE MOD(i, 4)
                WHEN 0 THEN 'IT'
                WHEN 1 THEN 'FINANCE'
                WHEN 2 THEN 'HR'
                ELSE 'OPERATIONS'
            END,
            SYSDATE - DBMS_RANDOM.VALUE(0, 365)
        );
    END LOOP;
    COMMIT;
END;
/

CREATE TABLE projects (
    id NUMBER PRIMARY KEY,
    project_name VARCHAR2(200),
    budget NUMBER(12,2),
    status VARCHAR2(20)
);

INSERT INTO projects VALUES (1, 'Progetto Alpha', 500000, 'ACTIVE');
INSERT INTO projects VALUES (2, 'Progetto Beta', 1200000, 'COMPLETED');
INSERT INTO projects VALUES (3, 'Progetto Gamma', 750000, 'ACTIVE');
COMMIT;

EXIT;
```

---

## 🔧 STEP 6: Test Manuale di Data Pump (Prima di Jenkins)

Prima di coinvolgere Jenkins, verifica che Data Pump funzioni da solo:

```powershell
# TEST EXPORT
expdp test_source/TestPass123@localhost:1521/FREEPDB1 `
  SCHEMAS=test_source `
  DIRECTORY=DATA_PUMP_DIR `
  DUMPFILE=test_export.dmp `
  LOGFILE=test_export.log `
  CONTENT=ALL

# Se vedi "Export terminated successfully" → OK!

# TEST IMPORT (con remap schema)
impdp test_target/TestPass123@localhost:1521/FREEPDB1 `
  SCHEMAS=test_source `
  DIRECTORY=DATA_PUMP_DIR `
  DUMPFILE=test_export.dmp `
  LOGFILE=test_import.log `
  REMAP_SCHEMA=test_source:test_target `
  TABLE_EXISTS_ACTION=REPLACE

# Se vedi "Import terminated successfully" → Tutto pronto!
```

---

## 🔧 STEP 7: Configurare Jenkins per Testare la Pipeline

### A. Creare le Credenziali in Jenkins
Vai su **Manage Jenkins → Credentials → System → Global credentials → Add Credentials**:

| ID Credenziale | Tipo | Username | Password |
|---|---|---|---|
| `dn-src-db-credentials` | Username with password | `test_source` | `TestPass123` |
| `dn-tgt-db-credentials` | Username with password | `test_target` | `TestPass123` |
| `dn-admin-db-credentials` | Username with password | `sys` | `TuaPassword` |

### B. Creare un file databases.yaml locale per il test
Crea `config/databases_local.yaml` (non committare!):

```yaml
databases:
  LOCAL_SOURCE:
    type: dbcs
    environment: DEV
    host: localhost
    port: 1521
    service_name: FREEPDB1
    credential_id: dn-src-db-credentials
    data_pump_dir: DATA_PUMP_DIR
    data_pump_path: "C:\\oracle\\datapump"
    schemas_allowed: []

  LOCAL_TARGET:
    type: dbcs
    environment: DEV
    host: localhost
    port: 1521
    service_name: FREEPDB1
    credential_id: dn-tgt-db-credentials
    data_pump_dir: DATA_PUMP_DIR
    data_pump_path: "C:\\oracle\\datapump"
    schemas_allowed: []
```

### C. Creare il Job Pipeline in Jenkins
1. Dashboard → **New Item** → Nome: `test-datapump-pipeline` → Tipo: **Pipeline**
2. Nella sezione Pipeline:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: il percorso del tuo repo locale (`C:\DBA\dn-oracle-datapump-pipeline`)
   - Branch: `*/master`
3. Salva

### D. Lanciare il Test
1. Clicca su **"Build with Parameters"**
2. Imposta:
   - OPERATION: `HEALTH_CHECK` (per iniziare col più semplice!)
   - SOURCE_DB: `LOCAL_SOURCE`
3. Clicca **Build** e osserva i log nella Console Output

Una volta che il Health Check funziona, prova con `EXPORT` e poi con `IMPORT`.

---

## ☁️ STEP 8: Usare Oracle Cloud Free Tier con Autonomous DB (Come in DARKNERO!)

Dato che DARKNERO usa **Autonomous Database** in produzione, il test più realistico è usare
il tuo account **Oracle Cloud Free Tier** (Always Free). Avrai un Autonomous DB vero,
con `DBMS_DATAPUMP`, Object Storage bucket e OCI CLI — esattamente come in produzione.

### A. Creare un Autonomous Database Always Free

1. Accedi a https://cloud.oracle.com con il tuo account Free Tier
2. Vai su **Oracle Database → Autonomous Database → Create Autonomous Database**
3. Configura:
   - **Display name**: `TestDevATP`
   - **Workload type**: Transaction Processing (ATP)
   - **Always Free**: ✅ Spunta questa opzione (fondamentale!)
   - **Database version**: 23ai
   - **ADMIN password**: Scegli una password robusta (es. `WelcomeTest#2026`)
   - **Access type**: Secure access from everywhere (per dev va bene)
4. Clicca **Create** e attendi ~2 minuti

### B. Scaricare il Wallet (Per Connetterti in Sicurezza)

Il Wallet è un file ZIP che contiene i certificati SSL per connetterti all'Autonomous DB.

1. Nella pagina del tuo Autonomous DB, clicca **Database connection**
2. Clicca **Download wallet**
3. Inserisci una password per il wallet (es. `WalletPass123`)
4. Salva il file ZIP, es: `C:\oracle\wallet\Wallet_TestDevATP.zip`
5. Estrailo nella stessa cartella: `C:\oracle\wallet\`
6. Modifica il file `sqlnet.ora` estratto per puntare alla directory giusta:
   ```
   WALLET_LOCATION = (SOURCE = (METHOD = file) (METHOD_DATA = (DIRECTORY="C:\oracle\wallet")))
   SSL_SERVER_DN_MATCH=yes
   ```
7. Imposta la variabile di ambiente:
   ```powershell
   $env:TNS_ADMIN = "C:\oracle\wallet"
   # Permanente:
   [System.Environment]::SetEnvironmentVariable("TNS_ADMIN", "C:\oracle\wallet", "User")
   ```
8. Verifica la connessione:
   ```powershell
   # Il service name lo trovi nel file tnsnames.ora dentro il wallet
   # Usa il servizio _high per le operazioni Data Pump
   sqlplus admin/WelcomeTest#2026@testdevatp_high
   ```

### C. Installare e Configurare OCI CLI

OCI CLI ti serve per gestire l'Object Storage (upload/download dump) da riga di comando.

1. Installa OCI CLI:
   ```powershell
   # Metodo ufficiale (PowerShell come Amministratore):
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   Invoke-WebRequest https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1 -OutFile install.ps1
   .\install.ps1 -AcceptAllDefaults
   ```
2. Configura OCI CLI:
   ```powershell
   oci setup config
   # Ti chiederà:
   #   - User OCID: lo trovi in OCI Console → Profile → My Profile → OCID
   #   - Tenancy OCID: OCI Console → Administration → Tenancy details → OCID
   #   - Region: es. eu-milan-1 (o quella del tuo Free Tier)
   #   - Genera una nuova API key: Y
   ```
3. Carica la chiave pubblica generata su OCI:
   - Vai su **OCI Console → Profile → My Profile → API Keys → Add API Key**
   - Carica il file `~/.oci/oci_api_key_public.pem`
4. Verifica:
   ```powershell
   oci iam region list --output table
   # Se vedi la lista delle regioni → tutto OK!
   ```

### D. Creare un Bucket Object Storage (Per i Dump)

1. Su OCI Console: **Storage → Object Storage → Buckets → Create Bucket**
2. Nome: `test-datapump-dev`
3. Lascia le impostazioni di default, clicca **Create**
4. Annota il **Namespace** (lo trovi nella pagina del bucket, o con):
   ```powershell
   oci os ns get
   # Output: { "data": "tuo_namespace" }
   ```

### E. Creare la Credenziale OCI nel Database Autonomous

Per far sì che `DBMS_DATAPUMP` scriva i dump direttamente nel bucket, devi creare
una credenziale OCI all'interno del database:

```sql
sqlplus admin/WelcomeTest#2026@testdevatp_high

-- Crea la credenziale usando Auth Token
-- (L'Auth Token lo generi da: OCI Console → Profile → Auth Tokens → Generate Token)
BEGIN
    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => 'OCI_CRED_DEV',
        username        => 'tua.email@example.com',   -- La tua email di login OCI
        password        => 'IL_TUO_AUTH_TOKEN'          -- L'Auth Token generato sopra
    );
END;
/

-- Verifica
SELECT credential_name, username FROM user_credentials;

EXIT;
```

### F. Creare Schemi di Test sull'Autonomous DB

```sql
sqlplus admin/WelcomeTest#2026@testdevatp_high

-- Crea schema sorgente
CREATE USER test_source IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE DATA QUOTA UNLIMITED ON DATA;
GRANT CONNECT, RESOURCE, CREATE TABLE TO test_source;
GRANT DWROLE TO test_source;

-- Crea schema destinazione
CREATE USER test_target IDENTIFIED BY TestPass123
  DEFAULT TABLESPACE DATA QUOTA UNLIMITED ON DATA;
GRANT CONNECT, RESOURCE TO test_target;
GRANT DWROLE TO test_target;

-- Popola dati di test (come nello STEP 5 sopra)
-- Connettiti come test_source e crea le tabelle employees e projects

EXIT;
```

### G. Test Manuale di DBMS_DATAPUMP sull'Autonomous DB

Questo è il test più importante perché replica esattamente il flusso DARKNERO:

```sql
sqlplus admin/WelcomeTest#2026@testdevatp_high

-- EXPORT via DBMS_DATAPUMP (come fa la nostra pipeline su Autonomous)
DECLARE
    v_handle NUMBER;
BEGIN
    v_handle := DBMS_DATAPUMP.OPEN(
        operation => 'EXPORT',
        job_mode  => 'SCHEMA',
        job_name  => 'TEST_EXP_01'
    );
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'test_export.dmp',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_DUMP_FILE
    );
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => 'test_export.log',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU$_FILE_TYPE_LOG_FILE
    );
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'SCHEMA_EXPR',
        value  => 'IN (''TEST_SOURCE'')'
    );
    DBMS_DATAPUMP.START_JOB(handle => v_handle);
    DBMS_DATAPUMP.DETACH(handle => v_handle);
    DBMS_OUTPUT.PUT_LINE('Export avviato con successo!');
END;
/

-- Monitora il job
SELECT job_name, state, attached_sessions
FROM DBA_DATAPUMP_JOBS
WHERE job_name = 'TEST_EXP_01';

-- Quando state = 'NOT RUNNING' → è finito. Verifica il log:
-- Il file test_export.log sarà in DATA_PUMP_DIR
EXIT;
```

### H. Configurare Jenkins per Autonomous DB

Aggiungi queste credenziali in Jenkins (**Manage Jenkins → Credentials**):

| ID Credenziale | Tipo | Valore |
|---|---|---|
| `dn-dev-atp-creds` | Username with password | `admin` / `WelcomeTest#2026` |
| `dn-dev-atp-wallet` | Secret file | Il file `Wallet_TestDevATP.zip` |
| `oci-config-file` | Secret file | Il file `~/.oci/config` |
| `oci-api-key` | Secret file | Il file `~/.oci/oci_api_key.pem` |

Poi aggiungi il database nel tuo `databases_local.yaml`:

```yaml
databases:
  # ... (i database locali di prima) ...

  CLOUD_ATP_DEV:
    type: autonomous
    description: "Cloud Free Tier — Autonomous ATP per test"
    environment: DEV
    service_name: testdevatp_high
    wallet_credential_id: dn-dev-atp-wallet
    db_credential_id: dn-dev-atp-creds
    oci_region: eu-milan-1                            # La tua regione
    compartment_id: "ocid1.compartment.oc1..tuo_id"   # Dal tuo OCI Console
    adb_ocid: "ocid1.autonomousdatabase.oc1..tuo_id"  # Dal tuo OCI Console
    bucket: test-datapump-dev
    credential_name: OCI_CRED_DEV
    default_tablespace: DATA
    parallel: 2
    schemas_allowed: []
```

### I. Test Finale della Pipeline Completa

Ora puoi testare il flusso reale DARKNERO su Jenkins:

1. **HEALTH_CHECK** su `CLOUD_ATP_DEV` → Verifica connessione al cloud
2. **EXPORT** da `CLOUD_ATP_DEV`, schema `TEST_SOURCE` → Usa DBMS_DATAPUMP via PL/SQL
3. **IMPORT** su `CLOUD_ATP_DEV`, schema remap `TEST_SOURCE → TEST_TARGET`
4. **EXPORT_AND_IMPORT** → Flusso completo con upload su bucket OCI

---

## ⚠️ Note Importanti

- **Porta 8080**: Se è già occupata (es. da un altro servizio), puoi cambiare la porta Jenkins editando `C:\ProgramData\Jenkins\.jenkins\jenkins.xml` e modificando `--httpPort=8080`.
- **Firewall**: Se usi Docker, assicurati che la porta 1521 sia aperta.
- **RAM**: Oracle 23ai Free usa circa 2 GB di RAM. Jenkins ne usa circa 512 MB. Assicurati di avere almeno 8 GB di RAM totale.
- **Disco**: Oracle + Jenkins + dump occupano circa 5-10 GB di spazio.
- **Always Free ATP**: L'istanza Always Free ha 1 OCPU e 20 GB di storage. È perfetta per i test ma è più lenta rispetto a un'istanza pagata. I Data Pump funzioneranno, ma con tempi più lunghi su dataset grandi.
- **Auth Token**: L'Auth Token scade dopo un periodo. Se la credenziale smette di funzionare, rigeneralo su OCI Console e aggiorna la credenziale nel database con `DBMS_CLOUD.UPDATE_CREDENTIAL`.

---

## 🎯 Ordine Consigliato di Test

### Fase 1: Locale (DBCS / CLI path)
1. ✅ `HEALTH_CHECK` su `LOCAL_SOURCE`
2. ✅ `EXPORT` da `LOCAL_SOURCE` (usa `expdp` CLI)
3. ✅ `IMPORT` su `LOCAL_TARGET` con remap (usa `impdp` CLI)
4. ✅ `TABLE_EXPORT` — Solo tabella `EMPLOYEES`

### Fase 2: Cloud (Autonomous / PL/SQL path — come DARKNERO!)
5. ✅ `HEALTH_CHECK` su `CLOUD_ATP_DEV`
6. ✅ `EXPORT` da `CLOUD_ATP_DEV` (usa `DBMS_DATAPUMP` via PL/SQL)
7. ✅ `IMPORT` su `CLOUD_ATP_DEV` con remap
8. ✅ `EXPORT_AND_IMPORT` — Flusso completo con bucket OCI

### Fase 3: Avanzato
9. ✅ `SWAP_AND_DROP` — Swap schema su `LOCAL_TARGET`
10. ✅ `BACKUP` — Export con naming convention timestamp

Buon lavoro! 🚀
