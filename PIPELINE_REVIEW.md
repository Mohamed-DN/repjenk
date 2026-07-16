# 🔍 Pipeline Review — DARKNERO Oracle Data Pump (2026-07-14)

Review completa di `Jenkinsfile` + `vars/` con priorità, flusso target e istruzioni operative.
Fonti: analisi statica del codice + best practice Oracle/Jenkins (link in fondo).

---

## Executive Summary

La pipeline ha un'ottima struttura di stage e parametri, ma **oggi non può girare end-to-end**: il Jenkinsfile chiama 14 funzioni che non esistono nella shared library, e la configurazione YAML usa chiavi diverse da quelle lette dal Jenkinsfile. Inoltre due claim di sicurezza dichiarati ("zero password leak" e "filtro ORA- dinamico") **non corrispondono al codice attuale**. Sotto trovi i problemi in ordine di priorità e il flusso consigliato.

---

## 🔴 P0 — Bloccanti (la pipeline fallisce a runtime)

### P0.1 — 14 funzioni chiamate ma inesistenti in `oracleDataPump.groovy`

Il Jenkinsfile invoca questi metodi che **non sono definiti da nessuna parte** → `MissingMethodException` al primo run:

| Funzione mancante | Stage chiamante | Nota |
|---|---|---|
| `testConnectivity` | Health Check | esiste `oracleConnect.validateConnection` (firma diversa) |
| `checkAvailableSpace` | Health Check, Pre-Op | esiste `oracleConnect.getAvailableSpace(dbConfig, tablespace)` |
| `analyzeSchema` | Pre-Op Analysis | esiste `oracleConnect.getSchemaSize` + `get_schema_size.sql` |
| `writeAuditLog` | Pre-Op Analysis | esiste `notifyResult.auditLog` |
| `logDryRun` | Export, Import | da creare (banale) |
| `uploadToBucket` / `downloadFromBucket` | Export, Import | esistono in **`ociStorage`**, non in `oracleDataPump` |
| `validateSchema`, `renameSchema`, `dropSchema`, `rollbackSwap` | Swap and Drop | da creare |
| `getRecordCounts`, `getObjectCounts` | Post-Op Verification | esiste `oracleConnect.getSchemaStats` (parziale) |
| `generateHtmlReport` | Generate Report | esiste `notifyResult.buildReport` |

**Come fare:** decidere una sola convenzione. Consiglio: il Jenkinsfile chiama solo *facade* in `oracleDataPump`, che internamente delega a `oracleConnect`/`ociStorage`/`notifyResult`. In alternativa (più veloce): correggere il Jenkinsfile per chiamare le funzioni già esistenti e creare solo le 6-7 realmente mancanti.

### P0.2 — Mismatch chiavi tra `databases.yaml` e Jenkinsfile

| Jenkinsfile legge | YAML definisce | Effetto |
|---|---|---|
| `credential_id` | `db_credential_id` | cade sempre sul default `dn-src-db-credentials` |
| `connect_string` | non esiste (c'è `service_name`/`host`) | `SRC_DB_CONNECT_STR` sempre vuoto → connessioni rotte |
| `ocid` | `adb_ocid` | OCID mai risolto |
| — | `wallet_credential_id` | mai letto: il wallet usa il default hardcoded |
| — | `schemas_allowed`, `max_dump_size_gb`, `parallel`, `bucket` (per-DB) | policy definite ma mai applicate |

**Come fare:** allineare l'Initialize stage alle chiavi reali dello YAML e sfruttare i default per-DB (`parallel`, `compression`, `bucket`, `retention_days`). Aggiungere validazione: `SCHEMA_NAME ∈ schemas_allowed` (se lista non vuota) — è una policy di sicurezza già scritta nello YAML ma mai applicata.

### P0.3 — Architettura DBCS: expdp gira sull'agent ma il dump nasce sul server DB

`cliExport` esegue `expdp` sull'agent Jenkins, ma Data Pump scrive **sempre** il dump nella `DIRECTORY` lato server DB. Il check `ls -la ${dumpFile}` sul filesystem dell'agent e il successivo upload OCI CLI **non troveranno mai il file** (a meno che agent = server DB, ok solo nel lab locale). Lo YAML prevede già `ssh_credential_id`/`data_pump_path`: la parte SSH non è implementata.

**Come fare (2 opzioni):**
1. **Consigliata (19c ≥ 19.9):** anche per DBCS esportare direttamente su Object Storage con `expdp ... credential=OCI_CRED dumpfile=https://objectstorage.../o/file.dmp` — elimina del tutto SSH e trasferimenti manuali.
2. Classica: eseguire expdp via SSH sul server DB (`ssh opc@host sudo -u oracle expdp ...`) e fare l'upload dal server con OCI CLI.

---

## 🟠 P1 — Sicurezza e correttezza

### P1.1 — Le password FINISCONO in CLI (contraddice il claim "Zero Password Leak")

In `cliExport`/`cliImport` il comando è `expdp 'user/pass@conn' ...` con replace dei placeholder → **visibile in `ps -ef`**. L'here-doc sicuro esiste solo per sqlplus, non per expdp/impdp.

**Come fare (in ordine di robustezza):**
1. **Secure External Password Store (SEPS):** wallet client con `mkstore`, poi `expdp /@TNS_ALIAS ...` — zero password ovunque. Best practice Oracle consolidata.
2. Password via **stdin**: `expdp userid=$DB_USER@conn ...` e la password passata sullo standard input (expdp la chiede in prompt): `printf '%s\n' "$DB_PASS" | expdp $DB_USER@conn ...`.
3. Mai parfile con password (file in chiaro).

### P1.2 — Interpolazione Groovy delle credenziali in `oracleConnect`

Tutti gli here-doc sono costruiti con `"CONNECT ${env.DB_USER}/${env.DB_PASS}@..."` in **stringhe Groovy doppie**: la password viene interpolata da Groovy e finisce nel file script temporaneo che Jenkins scrive su disco (`durable-task`), oltre a generare il warning ufficiale *"A secret was passed to sh using Groovy String interpolation, which is insecure"*.

**Come fare:** script `sh` in **apici singoli** e lasciare l'espansione alla shell:

```groovy
withCredentials([usernamePassword(credentialsId: credId,
        usernameVariable: 'DB_USER', passwordVariable: 'DB_PASS')]) {
    withEnv(["CONN_STR=${connStr}", "SQL_FILE=${tmpFile}"]) {
        output = sh(returnStdout: true, script: '''
            sqlplus -S /nolog <<EOF
CONNECT $DB_USER/"$DB_PASS"@$CONN_STR
@$SQL_FILE
EXIT;
EOF
        ''').trim()
    }
}
```

Così la password non passa mai da Groovy, non finisce nei log né nello script su disco.

### P1.3 — Il filtro ORA- può MASCHERARE errori critici

`checkForOracleErrors` fa il match sull'**intero output**: se nell'output c'è UN errore ignorabile (es. `ORA-31684`) e ANCHE un errore critico (es. `ORA-01652 unable to extend temp`), `isIgnorable` risulta true e **l'errore critico passa in silenzio**. Inoltre `ORA-39151` è **sempre** in whitelist — il comportamento dinamico legato a `TABLE_EXISTS_ACTION` dichiarato nei requisiti non è implementato.

**Come fare:** valutare **riga per riga**, rendere la whitelist parametrica, e raccogliere i warning ignorati per il report:

```groovy
def checkForOracleErrors(String output, String context, Map opts = [:]) {
    def ignore = BASE_IGNORE_LIST.clone()
    if (opts.tableExistsAction in ['SKIP','APPEND']) ignore << 'ORA-39151'
    def ignored = [], critical = []
    output.readLines().each { line ->
        if (line =~ /(ORA|SP2|PLS|LRM|UDE|UDI)-\d+/) {
            (ignore.any { line.contains(it) } ? ignored : critical) << line.trim()
        }
    }
    env.IGNORED_ORA_WARNINGS = ((env.IGNORED_ORA_WARNINGS ?: '') + ignored.join('\n')).take(20000)
    if (critical) error "[OracleConnect] Errori Oracle in '${context}':\n${critical.take(20).join('\n')}"
    return [ignored: ignored, critical: critical]
}
```

`env.IGNORED_ORA_WARNINGS` va poi inserito nell'email di report (obiettivo già in roadmap) — sezione "⚠ Errori ignorati" nel body HTML di `success`/`unstable`.

### P1.4 — SAFE_SWAP non è atomico e ha bug SQL

Nel blocco PL/SQL generato dal Jenkinsfile:

1. `LOCK TABLE ... IN EXCLUSIVE MODE` seguito da `RENAME`: **ogni DDL esegue commit implicito** e rilascia i lock → l'atomicità dichiarata non esiste; c'è comunque una finestra (piccola) tra i rename.
2. `RENAME x TO y` funziona **solo se connesso come owner** dello schema. Se la pipeline si connette con utenza di servizio serve `ALTER TABLE owner.x RENAME TO y`.
3. Indici, constraint, trigger e grant **restano con i nomi/riferimenti della tabella `_JENK`**; le FK di altre tabelle verso la tabella live puntano alla `_BKP`.
4. `take(30)`: su 19c/23ai il limite è 128 char — il troncamento a 30 può creare collisioni tra tabelle con prefisso comune.
5. `COMMIT` dentro il blocco è inutile (DDL auto-commit).
6. In `oracleDataPump.swapAndDrop` c'è una riga placeholder rotta: `RENAME TO schema.table` (qualificato) → ORA-14047. Da rimuovere.

**Come fare:** mantenere l'approccio rename (giusto per il caso d'uso), ma: usare `ALTER TABLE owner.tab RENAME TO ...`, togliere lock/commit inutili, alzare il limite nome a 128, e aggiungere step post-swap: rename indici/constraint (`ALTER INDEX ... RENAME TO`, `ALTER TABLE ... RENAME CONSTRAINT`), ricompilazione dipendenze (`UTL_RECOMP.RECOMP_SERIAL(schema)`), e re-grant. Per vere esigenze zero-downtime su tabelle enormi valutare `DBMS_REDEFINITION` o partition exchange.

---

## 🟡 P2 — Robustezza e architettura

### P2.1 — ADB + Object Storage: il flusso attuale non funziona su Autonomous

- Il ternario `${options.bucketName ? "DATA_PUMP_DIR" : "DATA_PUMP_DIR"}` è un bug evidente: il bucket viene ignorato.
- Su ADB **non esiste accesso al filesystem**: `uploadToBucket` via OCI CLI dall'agent non ha nulla da caricare.

**Come fare (best practice Oracle):** export **diretto su bucket** da DBMS_DATAPUMP:
1. Una tantum: `DBMS_CLOUD.CREATE_CREDENTIAL('OCI_CRED', user, auth_token)` (lo script `setup_credential.sql` esiste già).
2. In `ADD_FILE` usare l'URI nativo: `https://objectstorage.{region}.oraclecloud.com/n/{ns}/b/{bucket}/o/{file}_%L.dmp` — con `DEFAULT_CREDENTIAL` impostato o credential esplicita.
3. Ricordare il limite **10 GB per file** su Object Storage → usare sempre `%L` nel filename + `FILESIZE=10000MB`.
4. Parallel consigliato ADB: `0.25 × ECPU` con servizio `_high`.
5. In alternativa (dump già in DATA_PUMP_DIR): `DBMS_CLOUD.PUT_OBJECT` / `GET_OBJECT` per spostare i file da/verso il bucket — sempre lato DB, mai OCI CLI dall'agent.

### P2.2 — `monitorJob`: timeout e stati

- Timeout hardcoded **6h** (720×30s) contro le 24h della pipeline: un import multi-TB legittimo viene killato a metà. Rendere il timeout parametrico (default = timeout pipeline − margine).
- "Nessuna riga in DBA_DATAPUMP_JOBS" viene interpretato come successo, ma anche un job **fallito** sparisce dalla vista. `NOT RUNNING` idem.
- Il job può terminare "**completed with errors**": lo stato della vista non basta.

**Come fare:** invece del polling sulla vista, riattaccarsi col job e usare `DBMS_DATAPUMP.ATTACH` + `WAIT_FOR_JOB` (o `GET_STATUS`), e a fine job **leggere il logfile** (su ADB: `DBMS_CLOUD.GET_OBJECT`/`external table` sul log) cercando `successfully completed` vs `completed with N error(s)`; passare il conteggio errori al filtro P1.3.

### P2.3 — Pre-Flight Space Check (obiettivo dichiarato) — pezzi già pronti

Il building block c'è già: `oracleConnect.getSchemaSize()` (DBA_SEGMENTS) e `getAvailableSpace()` (dba_free_space + autoextend), più `scripts/sql/get_schema_size.sql` per il dettaglio. Manca solo **collegarli** nello stage Health Check:

```
stima_dump_gb = schema_size_gb × fattore_contenuto × fattore_compressione
  fattore_contenuto:  ALL/DATA_ONLY ≈ 0.8 (esclusi indici), METADATA_ONLY ≈ 0.05
  fattore_compressione: NONE = 1.0, BASIC ≈ 0.5, ALL ≈ 0.25 (stima prudente)

Verifiche (fail-fast, prima dell'export):
  1. Filesystem agent/server:  df -P --block-size=G $DUMP_DIR  ≥ stima × 1.2   (solo DBCS)
  2. Target DB:                getAvailableSpace(tgt, default_tablespace) ≥ schema_size × 1.1
  3. Policy YAML:              stima ≤ max_dump_size_gb del database
  4. (ADB) niente check filesystem: il dump va su Object Storage
```

Con `DRY_RUN=true` il check stampa solo il report senza `input`.

### P2.4 — Verifica post-import su DB da Terabyte

`getRecordCounts` con `COUNT(*)` su entrambi i lati è impraticabile su TB. Usare `num_rows` da `all_tables` (dopo `GATHER_STATS_POST_IMPORT`) come confronto veloce con tolleranza %, e `COUNT(*)` esatto solo sulle tabelle in `TABLE_LIST` o sotto una soglia di dimensione.

### P2.5 — Pulizie minori

- `KEEP_MASTER=1` lascia master table nello schema: dopo verifica OK, eseguire `cleanup_jobs.sql` (esiste già) in un post-step.
- `QUERY_FILTER` su CLI con doppi apici dentro `sh` è fragile: su CLI usare sempre parfile temporaneo (senza credenziali) per QUERY/EXCLUDE.
- Doppio `withCredentials` annidato (Jenkinsfile + funzioni library): tenerlo **solo dentro la library**, il Jenkinsfile passa solo `credentialId`.
- `EXCLUDE=TABLE` multipli in expdp: più parametri EXCLUDE sono ok, ma con la sintassi `IN ('X')` conviene un unico `EXCLUDE=TABLE:"IN ('A','B')"` nel parfile.
- Stage `Health Check` per operazione HEALTH_CHECK: aggiungere `currentBuild.description` col risultato, e uno stage guard che salti gli stage successivi (oggi ci pensano i `when`, ok).

---

## 🎯 Flusso target consigliato

```
1. Initialize            → checkout, YAML (chiavi corrette!), defaults per-DB, nome dump con %L
2. Validate              → parametri + schemas_allowed + regex injection (ok attuale)
3. Health Check          → connettività src/tgt (validateConnection)
                           + PRE-FLIGHT SPACE CHECK (P2.3)  ← fail-fast qui
4. Pre-Op Analysis       → get_schema_size.sql (report capacity planning) + audit log
5. Approval PROD         → input con submitter (ok attuale)
6. Export    [lock src]  → ADB: DBMS_DATAPUMP → URI bucket diretto (credential)
                           DBCS: expdp con credential=... → bucket diretto (no SSH)
                           monitor: WAIT_FOR_JOB + parsing logfile
7. Import    [lock tgt]  → ADB: DBMS_DATAPUMP da URI bucket / DBCS: impdp credential=...
                           SAFE_SWAP: import _JENK → swap con ALTER TABLE (P1.4)
8. Gather Stats          → DBMS_STATS (ok attuale)
9. Verification          → num_rows + COUNT selettivo (P2.4) → UNSTABLE se diff
10. Report + Notify      → HTML + email con sezione "errori ORA- ignorati" + Teams
11. Cleanup              → master tables, retention bucket, tmp files
```

Il passaggio dal modello "dump su filesystem + OCI CLI" al modello "**dump direttamente su Object Storage con credential**" (per entrambi i tipi di DB, 19.9+) semplifica drasticamente: niente SSH, niente spazio filesystem da gestire per ADB, un solo canale di trasferimento.

---

## 📋 Roadmap proposta

| # | Intervento | Priorità | Effort |
|---|---|---|---|
| 1 | Allineare Jenkinsfile ↔ library (funzioni mancanti) + chiavi YAML | P0 | Alto |
| 2 | Fix credenziali: single-quote sh + stdin/SEPS per expdp | P1 | Medio |
| 3 | Fix filtro ORA- riga-per-riga + whitelist dinamica + raccolta per report | P1 | Basso |
| 4 | Pre-flight space check nel Health Check (getSchemaSize) | P2 | Basso |
| 5 | Export/import diretto su Object Storage (ADB e DBCS) | P2 | Medio |
| 6 | Fix SAFE_SWAP (qualifica schema, indici/constraint, no lock inutili) | P1 | Medio |
| 7 | monitorJob → WAIT_FOR_JOB + parsing logfile | P2 | Medio |
| 8 | Email report con errori ignorati + verification smart | P2 | Basso |

---

## Fonti

- [Jenkins — Credentials Binding / string interpolation](https://www.jenkins.io/doc/pipeline/steps/credentials-binding/) · [CloudBees — String interpolation](https://docs.cloudbees.com/docs/cloudbees-ci/latest/automating-with-jenkinsfile/string-interpolation) · [JENKINS-63254](https://issues.jenkins.io/browse/JENKINS-63254)
- [ORACLE-BASE — Secure External Password Store](https://oracle-base.com/articles/10g/secure-external-password-store-10gr2) · [F. Pachot — Passwordless Data Pump 19c](https://franckpachot.medium.com/passwordless-data-pump-19c-b21cd1e00c16)
- [Oracle Docs — Export to Object Store con CREDENTIAL (19.9+)](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/export-data-object-store-dp-new.html) · [Oracle Docs — DEFAULT_CREDENTIAL](https://docs.oracle.com/en-us/iaas/autonomous-database-shared/doc/export-data-object-store-dp.html)
- [ORACLE-BASE — ADB export to Object Store (expdp)](https://oracle-base.com/articles/21c/oracle-cloud-autonomous-data-warehouse-export-data-to-object-store-expdp) · [DBCS expdp → Object Storage](https://adityanathoracledba.com/2025/10/26/step-by-step-guide-using-data-pump-expdp-on-dbcs-23ai-26ai-to-export-data-directly-to-oci-object-storage-bucket/)
