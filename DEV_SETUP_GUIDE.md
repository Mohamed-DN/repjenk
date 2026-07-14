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

## 🔧 STEP 3: Installare Oracle Database (2 Opzioni)

### Opzione A: Oracle 23ai Free (Installazione Diretta su Windows) ⭐ Consigliata

Oracle 23ai Free è la versione gratuita di Oracle, con limiti generosi per lo sviluppo:
- Fino a 12 GB di dati utente
- Fino a 2 GB di RAM
- Data Pump completamente funzionante

1. Vai su: https://www.oracle.com/database/free/
2. Scarica **Oracle Database 23ai Free** per Windows (richiede account Oracle gratuito)
3. Esegui l'installer e segui le istruzioni
4. Ricorda la password che imposti per **SYS** e **SYSTEM**
5. Verifica:
   ```powershell
   sqlplus sys/TuaPassword@localhost:1521/FREEPDB1 as sysdba
   # Se vedi "Connected to: Oracle Database 23ai Free" → funziona!
   ```

### Opzione B: Oracle XE via Docker (Più Veloce) 🐳

Se hai Docker Desktop installato (gratuito per uso personale/dev):

```powershell
# Scarica e avvia Oracle 23ai Free in un container
docker run -d --name oracle-free `
  -p 1521:1521 -p 5500:5500 `
  -e ORACLE_PWD=OracleTest123 `
  container-registry.oracle.com/database/free:latest

# Attendi 2-3 minuti che il database si avvii, poi verifica:
docker logs -f oracle-free
# Quando vedi "DATABASE IS READY TO USE!" → è pronto

# Connettiti:
sqlplus sys/OracleTest123@localhost:1521/FREEPDB1 as sysdba
```

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
            'emp' || i || '@eni.com',
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
| `eni-src-db-credentials` | Username with password | `test_source` | `TestPass123` |
| `eni-tgt-db-credentials` | Username with password | `test_target` | `TestPass123` |
| `eni-admin-db-credentials` | Username with password | `sys` | `TuaPassword` |

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
    credential_id: eni-src-db-credentials
    data_pump_dir: DATA_PUMP_DIR
    data_pump_path: "C:\\oracle\\datapump"
    schemas_allowed: []

  LOCAL_TARGET:
    type: dbcs
    environment: DEV
    host: localhost
    port: 1521
    service_name: FREEPDB1
    credential_id: eni-tgt-db-credentials
    data_pump_dir: DATA_PUMP_DIR
    data_pump_path: "C:\\oracle\\datapump"
    schemas_allowed: []
```

### C. Creare il Job Pipeline in Jenkins
1. Dashboard → **New Item** → Nome: `test-datapump-pipeline` → Tipo: **Pipeline**
2. Nella sezione Pipeline:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: il percorso del tuo repo locale (`C:\DBA\eni-oracle-datapump-pipeline`)
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

## ⚠️ Note Importanti

- **Porta 8080**: Se è già occupata (es. da un altro servizio), puoi cambiare la porta Jenkins editando `C:\ProgramData\Jenkins\.jenkins\jenkins.xml` e modificando `--httpPort=8080`.
- **Firewall**: Se usi Docker, assicurati che la porta 1521 sia aperta.
- **RAM**: Oracle 23ai Free usa circa 2 GB di RAM. Jenkins ne usa circa 512 MB. Assicurati di avere almeno 8 GB di RAM totale.
- **Disco**: Oracle + Jenkins + dump occupano circa 5-10 GB di spazio.

---

## 🎯 Ordine Consigliato di Test

1. ✅ `HEALTH_CHECK` — Verifica che Jenkins si connetta al DB
2. ✅ `EXPORT` — Esporta lo schema `test_source`
3. ✅ `IMPORT` — Importa nel `test_target` con remap
4. ✅ `TABLE_EXPORT` — Esporta solo la tabella `EMPLOYEES`
5. ✅ `EXPORT_AND_IMPORT` — Flusso completo export → import
6. ✅ `SWAP_AND_DROP` — Test dello swap schema (crea prima `test_target_NEW`)

Buon lavoro! 🚀
