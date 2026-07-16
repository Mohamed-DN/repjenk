# 📚 Guida Completa a Jenkins per Database Administrator (Da Zero)

Se non hai mai usato Jenkins prima d'ora, non preoccuparti. Questa guida è stata scritta appositamente per spiegarti, passo dopo passo, cos'è Jenkins, come funziona e come è stato utilizzato per automatizzare i tuoi flussi di Oracle Data Pump.

---

## 1. Cos'è Jenkins? 
Jenkins è uno strumento open-source di **Automazione** e **CI/CD** (Continuous Integration / Continuous Delivery). 
In parole povere: immagina Jenkins come un robot maggiordomo a cui puoi dare delle istruzioni dettagliate (una "Pipeline") per eseguire lavori noiosi, ripetitivi o complessi, come esportare e importare database, lanciare test o spostare file.

Per un **DBA**, Jenkins sostituisce i vecchi script `cron` o `.sh` che giravano in background sui server, offrendo enormi vantaggi:
- **Interfaccia Grafica (UI)**: Puoi avviare lavori con un semplice bottone e compilare form visivi invece di lanciare comandi testuali.
- **Tracciabilità assoluta**: Jenkins salva i log di ogni singola esecuzione. Saprai sempre chi ha lanciato un job, a che ora, con quali parametri e perché ha fallito.
- **Sicurezza centralizzata**: Non devi spargere password nei tuoi script; Jenkins gestisce le password in una cassaforte sicura (Credentials Store).
- **Gestione degli Errori e Notifiche**: Se un Data Pump fallisce, Jenkins manda automaticamente un'email o un messaggio su Microsoft Teams.

---

## 2. Architettura Base: Controller e Agent (Nodi)
Jenkins usa un'architettura "Master-Slave" (chiamata oggi **Controller-Agent**).
- **Controller (Il Cervello)**: È il server centrale dove risiede l'interfaccia web di Jenkins. Memorizza le configurazioni, gestisce le password e decide *quando* far partire i lavori.
- **Agent / Node (I Muscoli)**: Sono i server periferici che eseguono materialmente il lavoro. Ad esempio, potresti avere un nodo Linux configurato con i client Oracle (`sqlplus`, `expdp`) che fa il lavoro sporco.

> 🔍 **Nel nostro progetto:** Nel nostro `Jenkinsfile` vedrai la riga `agent { label 'oracle-dba' }`. Questo dice a Jenkins: *"Non eseguire questo lavoro sul server centrale, ma invialo a un nodo che ha l'etichetta 'oracle-dba', perché lì ci sono installati i client Oracle necessari"*.

---

## 3. Cos'è un `Jenkinsfile`?
Il `Jenkinsfile` è un file di testo (scritto in un linguaggio chiamato **Groovy**) che contiene tutte le istruzioni del tuo processo. Jenkins legge questo file dall'alto verso il basso e segue la ricetta.

Esistono due modi per scrivere un Jenkinsfile: *Scripted* (più vecchio, per programmatori esperti) e **Declarative** (più moderno, facile da leggere). Noi usiamo la versione **Declarative**.

### La Struttura di un Jenkinsfile Declarative:
```groovy
pipeline {
    agent any // Dove eseguire il lavoro
    
    parameters { ... } // I parametri di input chiesti all'utente
    
    environment { ... } // Variabili globali
    
    stages {
        stage('Export') { // Un blocco logico di lavoro
            steps {
                // I comandi reali da eseguire
            }
        }
    }
    
    post {
        always { ... } // Azioni da fare SEMPRE alla fine (es. notifiche, pulizia)
    }
}
```

---

## 4. Analisi del Nostro Progetto DARKNERO Data Pump

Andiamo a vedere i componenti chiave della nostra pipeline in `Jenkinsfile` per capire come si traducono nella pratica.

### A. I Parametri (`parameters`)
Nel nostro file, la sezione `parameters` definisce tutti i campi che tu, come utente, vedrai nella pagina **"Build with Parameters"** (Esegui con Parametri) sull'interfaccia web di Jenkins.
Esempi:
- `choice(name: 'OPERATION', choices: ['EXPORT', 'IMPORT', ...])`: Crea un menu a tendina.
- `booleanParam(name: 'ENABLE_DATA_MASKING')`: Crea una spunta (checkbox).
- `string(name: 'SCHEMA_NAME')`: Crea un campo di testo libero.

### B. Le Fasi del Lavoro (`stages`)
I job di Jenkins sono divisi in "Stadi". Pensa a una catena di montaggio. Se lo stage 1 fallisce, la catena si ferma e lo stage 2 non parte.
Nel nostro file abbiamo creato diversi Stage, tra cui:
- **`stage('Initialize')`**: Prepara l'ambiente e legge le configurazioni dei database.
- **`stage('Health Check')`**: Controlla che i database siano accesi e raggiungibili *prima* di iniziare a lavorare.
- **`stage('Export DataPump')`**: Fa l'esportazione vera e propria. Questo stage usa una regola speciale (`when { expression { params.OPERATION == 'EXPORT' } }`) che dice a Jenkins di eseguire questo blocco *solo* se hai scelto l'operazione EXPORT.

### C. La Cassaforte delle Password (`credentials`)
All'interno degli stage vedrai blocchi come questo:
```groovy
withCredentials([usernamePassword(credentialsId: 'dn-src-db-credentials', ...)]) {
    // codice
}
```
Invece di scrivere `admin/Password123!` nel codice, diciamo a Jenkins di andare a prendere la password chiamata `dn-src-db-credentials` dalla sua cassaforte segreta. La password viene resa disponibile solo all'interno di quel blocco, e nei log verrà nascosta con degli asterischi (****).

### D. Il Blocco `post`
Questa è l'ultima sezione del `Jenkinsfile`. Gestisce cosa fare al termine della pipeline, indipendentemente da cosa sia successo negli stage:
- **`always`**: Raccoglie i log e genera un report JSON.
- **`success`**: Manda un'email col bollino verde.
- **`failure`**: Se qualcosa è esploso, prende le ultime righe di errore e manda un'email rossa al team DBA.

---

## 5. Le "Shared Libraries" (La cartella `vars/`)

Jenkinsfile può diventare lunghissimo e difficile da leggere. Per questo Jenkins permette di creare delle **Librerie Condivise**.
Nel nostro progetto, tutta la logica complessa l'abbiamo "spostata" in file separati dentro la cartella `vars/`.

Se guardi il `Jenkinsfile`, a un certo punto non vedrai il comando reale per fare il Data Pump, ma vedrai qualcosa tipo:
```groovy
oracleDataPump.autonomousExport(...)
```
Jenkins capisce che deve andare a cercare un file chiamato `vars/oracleDataPump.groovy`, cercare al suo interno la funzione `autonomousExport`, ed eseguirla. 
In questo modo:
1. Il `Jenkinsfile` rimane pulito e ordinato (contiene solo la "regia").
2. I programmatori/DBA possono scrivere script complessi in Groovy o PL/SQL dentro la libreria e riutilizzarli in altre 10 pipeline diverse senza copiare/incollare il codice!

---

## 6. Come usare Jenkins tutti i giorni (Workflow Operativo)

1. **Accesso**: Entri nell'interfaccia web di Jenkins dal tuo browser.
2. **Selezione del Job**: Clicchi sul progetto `dn-oracle-datapump-pipeline`.
3. **Avvio**: Nel menu a sinistra clicchi su **"Build with Parameters"** (o Costruisci con Parametri).
4. **Compilazione form**: Scegli l'operazione (es. IMPORT), selezioni i database di origine e destinazione, inserisci il nome dello schema.
5. **Esecuzione**: Clicchi su **Build**. 
6. **Monitoraggio**: Si aprirà una barra di caricamento (Blue Ocean / Console Output). Potrai cliccare sui log per vedere in tempo reale cosa sta scrivendo `DBMS_DATAPUMP` o `impdp`.
7. **Fine**: Alla fine, riceverai una notifica e potrai consultare il report finale salvato tra gli artefatti del job.

## 7. Riepilogo Termini Chiave
- **Pipeline**: Il processo automatizzato da eseguire.
- **Jenkinsfile**: Il file dove risiede il codice della pipeline.
- **Controller/Agent**: Il server centrale e i server che lavorano.
- **Stage**: Una fase logica del lavoro (es. "Controllo", "Export", "Pulizia").
- **Credentials**: Le password nascoste.
- **Shared Library**: Il codice complesso riutilizzabile spostato altrove (es. la cartella `vars/`).

---

## 8. I File di Configurazione (`config/`)

La pipeline non ha valori "bruciati" dentro il codice. Tutto è configurabile tramite due file YAML nella cartella `config/`:

### `databases.yaml` — Il Registro dei Database
Questo file è l'elenco telefonico di tutti i database Oracle che la pipeline può raggiungere. Per ogni database vedrai:
- **`type`**: Se è `autonomous` (ATP/ADW, gestito via PL/SQL) o `dbcs` (DBCS/VM, gestito via CLI `expdp`/`impdp`).
- **`environment`**: `PROD`, `UAT`, `DEV` o `DR`. Se è `PROD`, la pipeline attiverà protezioni extra (conferma manuale, ecc.).
- **`service_name`**: La connection string Oracle.
- **`db_credential_id`**: Il riferimento alla cassaforte Jenkins per la password di quel database.
- **`schemas_allowed`**: Una whitelist. Solo gli schemi elencati qui possono essere esportati/importati (su PROD).

**Esempio pratico**: Quando scrivi `PROD_ATP_CORE` nel campo "SOURCE_DB" su Jenkins, la pipeline va a leggere `databases.yaml`, trova la sezione `PROD_ATP_CORE`, e da lì recupera il tipo di database, la regione OCI, il bucket di destinazione e le credenziali da usare.

### `defaults.yaml` — I Valori Predefiniti
Contiene i default per *tutte* le operazioni. Se non specifichi un valore in Jenkins, la pipeline userà questi. Include:
- **`export.parallel`**: Il grado di parallelismo di default (4).
- **`import.table_exists_action`**: Cosa fare se la tabella esiste già (`SKIP`).
- **`security.require_confirmation_for_prod`**: Se chiedere la conferma manuale per operazioni su PROD (`true`).
- **`environment_overrides`**: Sovrascritture per ambiente. Ad esempio, su `PROD` il timeout diventa 12 ore e la compressione è `ALL`, mentre su `DEV` si usa `REPLACE` e nessuna compressione.

---

## 9. Flussi Operativi Comuni (Cosa Succede Quando...)

### Flusso A: Export semplice
```
Tu clicchi "Build" con OPERATION=EXPORT, SOURCE_DB=PROD_ATP_CORE, SCHEMA_NAME=DN_CORE
   │
   ├─ Stage 1: Initialize → Legge databases.yaml, trova PROD_ATP_CORE, scopre che è "autonomous"
   ├─ Stage 2: Validate → Controlla che tutti i campi siano compilati correttamente
   ├─ Stage 3: Health Check → Prova a connettersi al database per verificare che sia acceso
   ├─ Stage 5: Export → Poiché è autonomous, chiama oracleDataPump.autonomousExport()
   │           └─ Genera blocco PL/SQL con DBMS_DATAPUMP.OPEN → ADD_FILE → START_JOB
   │           └─ Monitora il job ogni 30 secondi fino al completamento
   ├─ (Upload su bucket OCI se specificato)
   └─ Post: Invia email di successo con report HTML
```

### Flusso B: Refresh ambiente (PROD → DEV)
```
OPERATION=REFRESH_ENV, SOURCE_DB=PROD_ATP_CORE, TARGET_DB=DEV_ATP_01, SCHEMA_NAME=DN_CORE
   │
   ├─ Initialize → Carica config per entrambi i database
   ├─ Validate → Verifica CONFIRM_DESTRUCTIVE=true (obbligatorio su PROD)
   ├─ Health Check → Testa connettività a ENTRAMBI i database
   ├─ Export → Esporta da PROD (con approvazione manuale)
   ├─ Upload su bucket → Trasferisce il dump file
   ├─ Import → Importa su DEV con remap schema e ENABLE_DATA_MASKING
   ├─ Post-Verification → Confronta conteggio record sorgente vs target
   └─ Notifica → Report con confronto dettagliato
```

### Flusso C: Swap and Drop (Aggiornamento zero-downtime)
```
OPERATION=SWAP_AND_DROP, TARGET_DB=PROD_DBCS_ERP, SCHEMA_NAME=DN_ERP
   │
   ├─ Prerequisiti: Lo schema DN_ERP_NEW deve già esistere (creato da un import precedente)
   ├─ Approve → Doppia conferma manuale (solo PROD)
   ├─ Swap → Rinomina DN_ERP → DN_ERP_BKP_20260714
   │       → Rinomina DN_ERP_NEW → DN_ERP
   ├─ Verify → Controlla che gli oggetti siano validi
   ├─ (Opzionale) Drop → Elimina DN_ERP_BKP_20260714 se DROP_OLD_AFTER_SWAP=true
   └─ Notifica → Report con esito
```

---

## 10. Troubleshooting: Errori Comuni

| Errore | Cosa Significa | Cosa Fare |
|---|---|---|
| `sqlplus: command not found` | Il client Oracle non è installato sul nodo Jenkins | Controllare che `ORACLE_HOME` sia configurato e che `sqlplus` sia nel `PATH` |
| `ORA-39001: invalid argument` | Un parametro del Data Pump non è valido | Controllare i log del job Data Pump (file `.log` nella DATA_PUMP_DIR) |
| `ORA-31626: job does not exist` | Il job Data Pump è già terminato o è stato cancellato | Verificare in `DBA_DATAPUMP_JOBS` che non ci siano job orfani |
| `Timeout waiting for input` | Nessuno ha approvato l'operazione su PROD entro 30 minuti | Rilanciare il job e approvare tempestivamente |
| `BUCKET_NAME è obbligatorio` | Hai scelto un'operazione cross-database ma non hai specificato il bucket | Compilare il campo BUCKET_NAME nell'interfaccia Jenkins |
| `QUERY_FILTER contiene elementi proibiti` | Il filtro WHERE contiene parole chiave pericolose (DROP, DELETE, ecc.) | Usare solo clausole WHERE semplici senza comandi DML/DDL |

---

## 11. Risorse Esterne per Approfondire

### Documentazione Ufficiale
1. [Jenkins User Handbook](https://www.jenkins.io/doc/book/) — La bibbia di Jenkins. Parti dal capitolo "Pipeline".
2. [Declarative Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/) — Riferimento completo per la sintassi del Jenkinsfile.
3. [Jenkins Shared Libraries](https://www.jenkins.io/doc/book/pipeline/shared-libraries/) — Come funziona la cartella `vars/` che usiamo nel nostro progetto.
4. [Using Credentials in Jenkins](https://www.jenkins.io/doc/book/using/using-credentials/) — Come gestire password e chiavi in modo sicuro.
5. [Oracle Data Pump Overview (19c)](https://docs.oracle.com/en/database/oracle/oracle-database/19/sutil/oracle-data-pump-overview.html) — La guida Oracle ufficiale per capire `expdp`/`impdp` e `DBMS_DATAPUMP`.
6. [Oracle DBMS_DATAPUMP PL/SQL Reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_DATAPUMP.html) — Riferimento API per i blocchi PL/SQL generati dalla nostra libreria.
7. [OCI CLI Command Reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/) — Tutti i comandi `oci os object` usati per muovere i dump nel cloud.

### Video Tutorial Consigliati
- [Jenkins Pipeline Tutorial for Beginners (TechWorld with Nana)](https://www.youtube.com/watch?v=7KCS70sCoK0) — Ottimo per chi parte da zero.
- [Jenkins Full Course (freeCodeCamp)](https://www.youtube.com/watch?v=FX322RVNGj4) — Corso completo di 4 ore, copre tutto.

### Community
- [Jenkins Community Forums](https://community.jenkins.io/) — Per fare domande specifiche.
- [Stack Overflow — tag Jenkins](https://stackoverflow.com/questions/tagged/jenkins) — Per cercare soluzioni a errori specifici.

---

*Adesso sei pronto per navigare il codice del progetto in totale autonomia!*
