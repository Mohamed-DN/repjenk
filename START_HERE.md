# 🏁 START HERE: Mappa del Repository

Benvenuto nel progetto **ENI Oracle Data Pump Pipeline**. 
Se sei un nuovo arrivato (un DBA, un DevOps Engineer o un consulente), questo è il file da leggere per capire come orientarti.

## 🗺️ Ordine di Lettura Consigliato

Per comprendere appieno l'automazione, segui esattamente quest'ordine di lettura:

1. **`START_HERE.md`** (Questo file): Ti dà la bussola sul progetto.
2. **`JENKINS_LEARNING_GUIDE.md`**: Se non conosci bene Jenkins, leggi questa guida che ti spiegherà come i concetti base di CI/CD si mappano esattamente su questo progetto Oracle.
3. **`README.md`**: Il manuale operativo vero e proprio. Contiene i prerequisiti, la configurazione, la matrice delle operazioni supportate e le istruzioni di troubleshooting.

---

## 📁 Struttura delle Cartelle

Qui troverai cosa fa ogni singola cartella nel repository. È fondamentale capirlo per sapere *dove* mettere le mani in caso di modifiche.

```text
eni-oracle-datapump-pipeline/
│
├── Jenkinsfile                    # 🧠 IL CERVELLO. È il file principaleletto da Jenkins.
│                                  # Contiene la dichiarazione dei parametri, gli Stage (Export, Import) 
│                                  # e la gestione delle Notifiche. NON contiene logica complessa.
│
├── config/
│   └── databases.yaml             # ⚙️ CONFIGURAZIONE. L'elenco di tutti i database sorgente e target,
│                                  # le connection string e se sono ambienti Cloud (Autonomous/DBCS).
│
├── vars/                          # 📚 SHARED LIBRARIES. Qui c'è la "magia".
│   ├── oracleDataPump.groovy      # Logica di costruzione comandi expdp/impdp e blocchi DBMS_DATAPUMP.
│   ├── oracleConnect.groovy       # Funzioni per la connessione sicura ai database via sqlplus/sqlcl.
│   ├── ociStorage.groovy          # Comandi OCI CLI per muovere i dump file nel Cloud Storage.
│   └── notifyResult.groovy        # Composizione del report HTML, invio mail, Slack, Teams e Splunk.
│
├── scripts/                       # 🛠️ SCRIPT AUSILIARI (Eseguiti dai groovy in vars/)
│   ├── sql/                       # Script SQL standard (es. verifica connessione, conteggio record).
│   │   └── eni_data_masking_pkg.sql # Il package ENI per l'anonimizzazione sicura in Non-Prod.
│   ├── plsql/                     # Script PL/SQL puri.
│   └── shell/                     # Script Bash/Linux per eventuali operazioni di sistema (opzionali).
│
├── START_HERE.md                  # 🏁 Questo file.
├── JENKINS_LEARNING_GUIDE.md      # 🎓 Guida didattica a Jenkins.
└── README.md                      # 📖 Manuale operativo principale.
```

## 🚀 I Tre Principi di questo Repo

1. **Sicurezza (Zero Hardcoding)**: Non troverai mai una password o un token nel codice. Ogni credenziale è iniettata dinamicamente da Jenkins (tramite i blocchi `withCredentials`).
2. **Robustezza (Bulletproof)**: La pipeline è dotata di pre-flight checks (es. controlla se `sqlplus` è installato *prima* di iniziare), prevenzione contro SQL-Injection sui campi di input e timeout per le operazioni umane in ambiente PROD.
3. **Resilienza (Restartability & Cost Saving)**: I job di data pump mantengono le master table per il "resume", e lo storage OCI cloud viene svuotato automaticamente (`Cleanup Object Storage`) dai dump vecchi.

Ora sei pronto. Passa a **`JENKINS_LEARNING_GUIDE.md`** se hai bisogno di imparare Jenkins, oppure salta direttamente al **`README.md`** se devi configurare il tuo ambiente!
