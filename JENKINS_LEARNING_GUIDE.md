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

## 4. Analisi del Nostro Progetto ENI Data Pump

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
withCredentials([usernamePassword(credentialsId: 'eni-src-db-credentials', ...)]) {
    // codice
}
```
Invece di scrivere `admin/Password123!` nel codice, diciamo a Jenkins di andare a prendere la password chiamata `eni-src-db-credentials` dalla sua cassaforte segreta. La password viene resa disponibile solo all'interno di quel blocco, e nei log verrà nascosta con degli asterischi (****).

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
2. **Selezione del Job**: Clicchi sul progetto `eni-oracle-datapump-pipeline`.
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

*Adesso sei pronto per navigare il codice del progetto in totale autonomia!*
