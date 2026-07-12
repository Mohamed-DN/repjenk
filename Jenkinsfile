#!/usr/bin/env groovy
// =============================================================================
// ENI Oracle Data Pump Automation Pipeline
// =============================================================================
// Pipeline:    eni-oracle-datapump-pipeline
// Azienda:     ENI S.p.A. — Direzione ICT / Database Operations
// Descrizione: Automazione completa delle operazioni Oracle Data Pump
//              (export, import, refresh, swap) su Oracle Cloud Infrastructure.
// Versione:    2.0.0
// Autore:      DBA Team — ENI ICT
// Data:        2026-07-12
// =============================================================================

@Library('eni-oracle-shared-library') _

pipeline {
    agent {
        label 'oracle-dba'
    }

    // =========================================================================
    // OPZIONI GLOBALI DELLA PIPELINE
    // =========================================================================
    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 8, unit: 'HOURS')
        disableConcurrentBuilds(abortPrevious: false)
        buildDiscarder(logRotator(numToKeepStr: '50', artifactNumToKeepStr: '20'))
        skipDefaultCheckout(true)
    }

    // =========================================================================
    // VARIABILI D'AMBIENTE GLOBALI
    // Credenziali e path gestiti centralmente tramite Jenkins Credentials Store
    // =========================================================================
    environment {
        // --- Autenticazione OCI (Instance Principal per agent on-prem, API Key per cloud) ---
        OCI_CLI_AUTH              = 'instance_principal'
        OCI_CONFIG_FILE           = credentials('oci-config-file')
        OCI_KEY_FILE              = credentials('oci-api-key')

        // --- Oracle Home e binari ---
        ORACLE_HOME               = '/opt/oracle/product/19c/dbhome_1'
        ORACLE_BASE               = '/opt/oracle'
        LD_LIBRARY_PATH           = "${ORACLE_HOME}/lib"
        PATH_ORACLE               = "${ORACLE_HOME}/bin"
        TNS_ADMIN                 = "${ORACLE_HOME}/network/admin"

        // --- Credenziali database (gestite da Jenkins Credentials Store) ---
        SRC_DB_CREDENTIALS        = credentials('eni-src-db-credentials')
        TGT_DB_CREDENTIALS        = credentials('eni-tgt-db-credentials')
        ADMIN_DB_CREDENTIALS      = credentials('eni-admin-db-credentials')

        // --- Wallet per Autonomous Database ---
        ADB_WALLET_DIR            = credentials('eni-adb-wallet-dir')

        // --- Configurazione notifiche ---
        SMTP_CREDENTIALS          = credentials('eni-smtp-credentials')
        DEFAULT_NOTIFICATION_EMAIL = 'dba-team@eni.com'

        // --- Directory di lavoro ---
        DUMP_DIR                  = '/opt/oracle/datapump/dumps'
        LOG_DIR                   = '/opt/oracle/datapump/logs'
        REPORT_DIR                = '/opt/oracle/datapump/reports'
        CONFIG_DIR                = 'config'
    }

    // =========================================================================
    // PARAMETRI DI INPUT
    // Tutti i parametri necessari per le operazioni Data Pump
    // =========================================================================
    parameters {
        // --- Tipo di operazione principale ---
        choice(
            name: 'OPERATION',
            choices: ['EXPORT', 'IMPORT', 'EXPORT_AND_IMPORT', 'BACKUP', 'REFRESH_ENV', 'SWAP_AND_DROP', 'TABLE_EXPORT', 'TABLE_IMPORT', 'HEALTH_CHECK'],
            description: 'Tipo di operazione Data Pump da eseguire'
        )

        // --- Database sorgente e destinazione ---
        string(
            name: 'SOURCE_DB',
            defaultValue: '',
            trim: true,
            description: 'Alias del database sorgente (da databases.yaml). Obbligatorio.'
        )
        string(
            name: 'TARGET_DB',
            defaultValue: '',
            trim: true,
            description: 'Alias del database destinazione (da databases.yaml). Obbligatorio per IMPORT.'
        )

        // --- Schema e remap ---
        string(
            name: 'SCHEMA_NAME',
            defaultValue: '',
            trim: true,
            description: 'Nome dello schema sorgente da esportare/importare.'
        )
        string(
            name: 'REMAP_SCHEMA',
            defaultValue: '',
            trim: true,
            description: 'Schema di destinazione per il remap (opzionale). Es: SCHEMA_PROD → SCHEMA_TEST'
        )
        string(
            name: 'REMAP_TABLESPACE',
            defaultValue: '',
            trim: true,
            description: 'Tablespace di destinazione per il remap (opzionale).'
        )
        string(
            name: 'REMAP_TABLE',
            defaultValue: '',
            trim: true,
            description: 'Coppie di remap tabelle: OLD_TAB:NEW_TAB,OLD2:NEW2 (opzionale).'
        )
        string(
            name: 'TABLE_LIST',
            defaultValue: '',
            trim: true,
            description: 'Lista tabelle separate da virgola per TABLE_EXPORT/TABLE_IMPORT.'
        )

        // --- Configurazione dump file ---
        string(
            name: 'DUMP_FILENAME',
            defaultValue: '',
            trim: true,
            description: 'Nome del dump file. Se vuoto, generato automaticamente: SCHEMA_YYYYMMDD_HHMMSS.dmp'
        )
        choice(
            name: 'PARALLEL',
            choices: ['1', '2', '4', '8'],
            description: 'Grado di parallelismo per Data Pump.'
        )
        choice(
            name: 'CONTENT',
            choices: ['ALL', 'DATA_ONLY', 'METADATA_ONLY'],
            description: 'Tipo di contenuto da esportare/importare.'
        )

        // --- Opzioni di export/import ---
        booleanParam(
            name: 'INCLUDE_GRANTS',
            defaultValue: true,
            description: 'Includere i GRANT nello schema esportato/importato.'
        )
        booleanParam(
            name: 'INCLUDE_STATISTICS',
            defaultValue: true,
            description: 'Includere le statistiche degli oggetti.'
        )
        choice(
            name: 'TABLE_EXISTS_ACTION',
            choices: ['SKIP', 'REPLACE', 'APPEND', 'TRUNCATE'],
            description: 'Azione se la tabella esiste già nel target.'
        )

        // --- Opzioni per nuovo schema e swap ---
        booleanParam(
            name: 'CREATE_NEW_SCHEMA',
            defaultValue: false,
            description: 'Importare in un nuovo schema con suffisso _NEW.'
        )
        booleanParam(
            name: 'SWAP_AFTER_IMPORT',
            defaultValue: false,
            description: 'Eseguire lo swap dello schema vecchio con il nuovo dopo l\'import.'
        )
        booleanParam(
            name: 'DROP_OLD_AFTER_SWAP',
            defaultValue: false,
            description: 'Eliminare il backup dello schema vecchio (_BKP) dopo lo swap.'
        )

        // --- Sicurezza e conferma ---
        booleanParam(
            name: 'CONFIRM_DESTRUCTIVE',
            defaultValue: false,
            description: 'OBBLIGATORIO per operazioni distruttive su ambienti PROD. Conferma esplicita.'
        )
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: 'Modalità simulazione: mostra cosa farebbe senza eseguire.'
        )

        // --- Notifiche ---
        string(
            name: 'NOTIFICATION_EMAIL',
            defaultValue: '',
            trim: true,
            description: 'Email per notifiche (default: dba-team@eni.com).'
        )

        // --- OCI Object Storage ---
        string(
            name: 'BUCKET_NAME',
            defaultValue: '',
            trim: true,
            description: 'Nome del bucket OCI Object Storage per upload/download dump.'
        )

        // --- Filtri avanzati ---
        string(
            name: 'EXCLUDE_TABLES',
            defaultValue: '',
            trim: true,
            description: 'Tabelle da escludere dall\'export, separate da virgola.'
        )
        string(
            name: 'QUERY_FILTER',
            defaultValue: '',
            trim: true,
            description: 'Clausola WHERE per filtrare i dati esportati. Es: "WHERE created_date > SYSDATE-30"'
        )
        choice(
            name: 'COMPRESSION',
            choices: ['NONE', 'BASIC', 'ALL'],
            description: 'Livello di compressione del dump file.'
        )
        choice(
            name: 'ENCRYPTION',
            choices: ['NONE', 'ALL', 'DATA_ONLY', 'ENCRYPTED_COLUMNS_ONLY'],
            description: 'Livello di cifratura del dump file.'
        )
    }

    // =========================================================================
    // INIZIO STAGES
    // =========================================================================
    stages {

        // =====================================================================
        // STAGE 1: INIZIALIZZAZIONE
        // Caricamento configurazione, checkout, preparazione ambiente
        // =====================================================================
        stage('Initialize') {
            steps {
                // Checkout del repository contenente databases.yaml e script ausiliari
                checkout scm

                script {
                    // --- Caricamento configurazione database da file YAML ---
                    // Il file databases.yaml contiene tutti gli alias dei database,
                    // le connection string, il tipo (autonomous/dbcs) e l'ambiente (PROD/TEST/DEV)
                    def configFile = "${CONFIG_DIR}/databases.yaml"
                    if (!fileExists(configFile)) {
                        error "[ERRORE] File di configurazione non trovato: ${configFile}"
                    }
                    env.DB_CONFIG = readFile(file: configFile)
                    def dbConfig = readYaml(file: configFile)
                    env.DB_CONFIG_LOADED = 'true'

                    // --- Risoluzione configurazione database sorgente ---
                    if (params.SOURCE_DB?.trim()) {
                        def srcDb = dbConfig.databases?.get(params.SOURCE_DB)
                        if (srcDb) {
                            env.SRC_DB_TYPE        = srcDb.type ?: 'dbcs'           // autonomous | dbcs
                            env.SRC_DB_ENV         = srcDb.environment ?: 'UNKNOWN' // PROD | TEST | DEV
                            env.SRC_DB_HOST        = srcDb.host ?: ''
                            env.SRC_DB_SERVICE     = srcDb.service_name ?: ''
                            env.SRC_DB_PORT        = srcDb.port?.toString() ?: '1521'
                            env.SRC_DB_CONNECT_STR = srcDb.connect_string ?: ''
                            env.SRC_DB_OCID        = srcDb.ocid ?: ''
                            env.SRC_DB_COMPARTMENT = srcDb.compartment_id ?: ''
                            env.SRC_CRED_ID        = srcDb.credential_id ?: 'eni-src-db-credentials'
                            echo "\u001B[32m[INFO] Database sorgente '${params.SOURCE_DB}' caricato — tipo: ${env.SRC_DB_TYPE}, ambiente: ${env.SRC_DB_ENV}\u001B[0m"
                        } else {
                            error "[ERRORE] Database sorgente '${params.SOURCE_DB}' non trovato in databases.yaml"
                        }
                    }

                    // --- Risoluzione configurazione database destinazione ---
                    if (params.TARGET_DB?.trim()) {
                        def tgtDb = dbConfig.databases?.get(params.TARGET_DB)
                        if (tgtDb) {
                            env.TGT_DB_TYPE        = tgtDb.type ?: 'dbcs'
                            env.TGT_DB_ENV         = tgtDb.environment ?: 'UNKNOWN'
                            env.TGT_DB_HOST        = tgtDb.host ?: ''
                            env.TGT_DB_SERVICE     = tgtDb.service_name ?: ''
                            env.TGT_DB_PORT        = tgtDb.port?.toString() ?: '1521'
                            env.TGT_DB_CONNECT_STR = tgtDb.connect_string ?: ''
                            env.TGT_DB_OCID        = tgtDb.ocid ?: ''
                            env.TGT_DB_COMPARTMENT = tgtDb.compartment_id ?: ''
                            env.TGT_CRED_ID        = tgtDb.credential_id ?: 'eni-tgt-db-credentials'
                            echo "\u001B[32m[INFO] Database destinazione '${params.TARGET_DB}' caricato — tipo: ${env.TGT_DB_TYPE}, ambiente: ${env.TGT_DB_ENV}\u001B[0m"
                        } else {
                            error "[ERRORE] Database destinazione '${params.TARGET_DB}' non trovato in databases.yaml"
                        }
                    }

                    // --- Generazione automatica nome dump file ---
                    // Formato: SCHEMA_YYYYMMDD_HHMMSS.dmp (se non specificato manualmente)
                    if (!params.DUMP_FILENAME?.trim()) {
                        def timestamp = new Date().format('yyyyMMdd_HHmmss')
                        def schemaPrefix = params.SCHEMA_NAME?.trim() ?: 'FULL'
                        env.EFFECTIVE_DUMP_FILENAME = "${schemaPrefix}_${timestamp}.dmp"
                    } else {
                        env.EFFECTIVE_DUMP_FILENAME = params.DUMP_FILENAME.trim()
                    }
                    // Nome del log file associato
                    env.EFFECTIVE_LOG_FILENAME = env.EFFECTIVE_DUMP_FILENAME.replace('.dmp', '.log')

                    // --- Email di notifica ---
                    env.EFFECTIVE_EMAIL = params.NOTIFICATION_EMAIL?.trim() ?: env.DEFAULT_NOTIFICATION_EMAIL

                    // --- Schema effettivo per il remap ---
                    // Se CREATE_NEW_SCHEMA è attivo, lo schema destinazione diventa SCHEMA_NEW
                    if (params.CREATE_NEW_SCHEMA) {
                        env.EFFECTIVE_TARGET_SCHEMA = (params.REMAP_SCHEMA?.trim() ?: params.SCHEMA_NAME) + '_NEW'
                    } else {
                        env.EFFECTIVE_TARGET_SCHEMA = params.REMAP_SCHEMA?.trim() ?: params.SCHEMA_NAME
                    }

                    // --- Preparazione directory di lavoro ---
                    sh """
                        mkdir -p ${DUMP_DIR} ${LOG_DIR} ${REPORT_DIR}
                        echo "[INFO] Directory di lavoro preparate."
                    """

                    // --- Riepilogo inizializzazione ---
                    echo """
╔══════════════════════════════════════════════════════════════════╗
║          ENI Oracle Data Pump — Inizializzazione                ║
╠══════════════════════════════════════════════════════════════════╣
║  Operazione:        ${params.OPERATION.padRight(42)}║
║  Database Sorgente: ${(params.SOURCE_DB ?: 'N/A').padRight(42)}║
║  Database Target:   ${(params.TARGET_DB ?: 'N/A').padRight(42)}║
║  Schema:            ${(params.SCHEMA_NAME ?: 'N/A').padRight(42)}║
║  Dump File:         ${env.EFFECTIVE_DUMP_FILENAME.padRight(42)}║
║  Parallelismo:      ${params.PARALLEL.padRight(42)}║
║  Dry Run:           ${params.DRY_RUN.toString().padRight(42)}║
║  Ambiente Sorgente: ${(env.SRC_DB_ENV ?: 'N/A').padRight(42)}║
╚══════════════════════════════════════════════════════════════════╝
                    """
                }
            }
        }

        // =====================================================================
        // STAGE 2: VALIDAZIONE PARAMETRI
        // Controllo di tutti gli input prima di procedere con l'operazione
        // =====================================================================
        stage('Validate Parameters') {
            steps {
                script {
                    def errors = []

                    // --- Validazione obbligatorietà SOURCE_DB ---
                    // Tutte le operazioni (tranne casi particolari) richiedono un database sorgente
                    if (!params.SOURCE_DB?.trim()) {
                        errors << "SOURCE_DB è obbligatorio per l'operazione ${params.OPERATION}"
                    }

                    // --- Validazione SCHEMA_NAME obbligatorio ---
                    def opsRequiringSchema = ['EXPORT', 'IMPORT', 'EXPORT_AND_IMPORT', 'BACKUP', 'REFRESH_ENV', 'SWAP_AND_DROP', 'TABLE_EXPORT', 'TABLE_IMPORT']
                    if (params.OPERATION in opsRequiringSchema && !params.SCHEMA_NAME?.trim()) {
                        errors << "SCHEMA_NAME è obbligatorio per l'operazione ${params.OPERATION}"
                    }

                    // --- Validazione TARGET_DB obbligatorio per operazioni di import ---
                    def opsRequiringTarget = ['IMPORT', 'EXPORT_AND_IMPORT', 'REFRESH_ENV', 'TABLE_IMPORT']
                    if (params.OPERATION in opsRequiringTarget && !params.TARGET_DB?.trim()) {
                        errors << "TARGET_DB è obbligatorio per l'operazione ${params.OPERATION}"
                    }

                    // --- Validazione TABLE_LIST per operazioni su tabelle ---
                    if (params.OPERATION in ['TABLE_EXPORT', 'TABLE_IMPORT'] && !params.TABLE_LIST?.trim()) {
                        errors << "TABLE_LIST è obbligatorio per l'operazione ${params.OPERATION}"
                    }

                    // --- Validazione SWAP_AND_DROP: richiede schema ---
                    if (params.OPERATION == 'SWAP_AND_DROP' && !params.SCHEMA_NAME?.trim()) {
                        errors << "SCHEMA_NAME è obbligatorio per SWAP_AND_DROP"
                    }

                    // --- Blocco operazioni distruttive su PROD senza conferma esplicita ---
                    // Politica di sicurezza ENI: ogni operazione che modifica dati su PROD
                    // deve avere CONFIRM_DESTRUCTIVE = true
                    def destructiveOps = ['IMPORT', 'REFRESH_ENV', 'SWAP_AND_DROP', 'TABLE_IMPORT']
                    def isProdTarget = (env.TGT_DB_ENV == 'PROD' || env.SRC_DB_ENV == 'PROD')
                    if (params.OPERATION in destructiveOps && isProdTarget && !params.CONFIRM_DESTRUCTIVE) {
                        errors << """
[SICUREZZA] Operazione distruttiva '${params.OPERATION}' su ambiente PROD bloccata.
Impostare CONFIRM_DESTRUCTIVE = true per procedere.
Questa misura è obbligatoria per la policy di sicurezza ENI."""
                    }

                    // --- Validazione formato REMAP_TABLE ---
                    if (params.REMAP_TABLE?.trim()) {
                        def pairs = params.REMAP_TABLE.split(',')
                        pairs.each { pair ->
                            if (!pair.trim().contains(':')) {
                                errors << "Formato REMAP_TABLE non valido: '${pair}'. Formato atteso: OLD_TABLE:NEW_TABLE"
                            }
                        }
                    }

                    // --- Validazione BUCKET_NAME per operazioni cross-database ---
                    if (params.OPERATION in ['EXPORT_AND_IMPORT', 'REFRESH_ENV'] && !params.BUCKET_NAME?.trim()) {
                        errors << "BUCKET_NAME è obbligatorio per operazioni cross-database (${params.OPERATION})"
                    }

                    // --- Validazione QUERY_FILTER: prevenzione SQL injection basilare ---
                    if (params.QUERY_FILTER?.trim()) {
                        def forbidden = ['DROP ', 'DELETE ', 'TRUNCATE ', 'ALTER ', 'CREATE ', 'INSERT ', 'UPDATE ', '--', '/*']
                        forbidden.each { keyword ->
                            if (params.QUERY_FILTER.toUpperCase().contains(keyword)) {
                                errors << "QUERY_FILTER contiene keyword proibito: '${keyword.trim()}'"
                            }
                        }
                    }

                    // --- Se ci sono errori, blocca la pipeline ---
                    if (errors) {
                        def errorMsg = "\n\u001B[31m══════ ERRORI DI VALIDAZIONE ══════\u001B[0m\n" +
                                       errors.collect { "  ✗ ${it}" }.join('\n') +
                                       "\n\u001B[31m═══════════════════════════════════\u001B[0m"
                        error errorMsg
                    }

                    echo "\u001B[32m[✓] Tutti i parametri validati con successo.\u001B[0m"
                }
            }
        }

        // =====================================================================
        // STAGE 3: HEALTH CHECK
        // Verifica connettività e spazio disponibile su source/target
        // =====================================================================
        stage('Health Check') {
            steps {
                script {
                    echo "\u001B[36m[INFO] Avvio controllo di salute dei database...\u001B[0m"

                    // --- Verifica connettività database sorgente ---
                    if (params.SOURCE_DB?.trim()) {
                        echo "[INFO] Test connettività verso il database sorgente: ${params.SOURCE_DB}"
                        withCredentials([usernamePassword(
                            credentialsId: env.SRC_CRED_ID,
                            usernameVariable: 'DB_USER',
                            passwordVariable: 'DB_PASS'
                        )]) {
                            try {
                                def srcConnectivity = oracleDataPump.testConnectivity(
                                    dbType:        env.SRC_DB_TYPE,
                                    connectString: env.SRC_DB_CONNECT_STR,
                                    user:          DB_USER,
                                    password:      DB_PASS,
                                    walletDir:     env.ADB_WALLET_DIR
                                )
                                if (srcConnectivity.success) {
                                    echo "\u001B[32m[✓] Database sorgente '${params.SOURCE_DB}' raggiungibile. Versione: ${srcConnectivity.version}\u001B[0m"
                                    env.SRC_DB_VERSION = srcConnectivity.version
                                } else {
                                    error "[ERRORE] Impossibile connettersi al database sorgente: ${srcConnectivity.error}"
                                }
                            } catch (Exception e) {
                                error "[ERRORE CRITICO] Health check sorgente fallito: ${e.getMessage()}"
                            }
                        }
                    }

                    // --- Verifica connettività database destinazione ---
                    if (params.TARGET_DB?.trim()) {
                        echo "[INFO] Test connettività verso il database destinazione: ${params.TARGET_DB}"
                        withCredentials([usernamePassword(
                            credentialsId: env.TGT_CRED_ID,
                            usernameVariable: 'DB_USER',
                            passwordVariable: 'DB_PASS'
                        )]) {
                            try {
                                def tgtConnectivity = oracleDataPump.testConnectivity(
                                    dbType:        env.TGT_DB_TYPE,
                                    connectString: env.TGT_DB_CONNECT_STR,
                                    user:          DB_USER,
                                    password:      DB_PASS,
                                    walletDir:     env.ADB_WALLET_DIR
                                )
                                if (tgtConnectivity.success) {
                                    echo "\u001B[32m[✓] Database destinazione '${params.TARGET_DB}' raggiungibile. Versione: ${tgtConnectivity.version}\u001B[0m"
                                    env.TGT_DB_VERSION = tgtConnectivity.version
                                } else {
                                    error "[ERRORE] Impossibile connettersi al database destinazione: ${tgtConnectivity.error}"
                                }
                            } catch (Exception e) {
                                error "[ERRORE CRITICO] Health check destinazione fallito: ${e.getMessage()}"
                            }
                        }
                    }

                    // --- Verifica spazio disponibile ---
                    if (params.SOURCE_DB?.trim()) {
                        withCredentials([usernamePassword(
                            credentialsId: env.SRC_CRED_ID,
                            usernameVariable: 'DB_USER',
                            passwordVariable: 'DB_PASS'
                        )]) {
                            def spaceInfo = oracleDataPump.checkAvailableSpace(
                                dbType:        env.SRC_DB_TYPE,
                                connectString: env.SRC_DB_CONNECT_STR,
                                user:          DB_USER,
                                password:      DB_PASS
                            )
                            env.SRC_FREE_SPACE_GB = spaceInfo.freeSpaceGB?.toString() ?: '0'
                            echo "[INFO] Spazio libero sorgente: ${env.SRC_FREE_SPACE_GB} GB"
                        }
                    }

                    // Operazione HEALTH_CHECK termina qui con successo
                    if (params.OPERATION == 'HEALTH_CHECK') {
                        echo "\u001B[32m[✓] Health Check completato con successo. Nessuna altra operazione richiesta.\u001B[0m"
                    }
                }
            }
        }

        // =====================================================================
        // STAGE 4: ANALISI PRE-OPERAZIONE
        // Raccolta informazioni sugli schema, dimensioni, stima dump
        // =====================================================================
        stage('Pre-Operation Analysis') {
            when {
                not { equals expected: 'HEALTH_CHECK', actual: params.OPERATION }
            }
            steps {
                script {
                    echo "\u001B[36m[INFO] Analisi pre-operazione in corso...\u001B[0m"

                    withCredentials([usernamePassword(
                        credentialsId: env.SRC_CRED_ID,
                        usernameVariable: 'DB_USER',
                        passwordVariable: 'DB_PASS'
                    )]) {
                        // --- Analisi dimensione schema sorgente ---
                        def schemaAnalysis = oracleDataPump.analyzeSchema(
                            dbType:        env.SRC_DB_TYPE,
                            connectString: env.SRC_DB_CONNECT_STR,
                            user:          DB_USER,
                            password:      DB_PASS,
                            schemaName:    params.SCHEMA_NAME,
                            tableList:     params.TABLE_LIST
                        )

                        env.SCHEMA_SIZE_GB       = schemaAnalysis.sizeGB?.toString() ?: '0'
                        env.SCHEMA_TABLE_COUNT   = schemaAnalysis.tableCount?.toString() ?: '0'
                        env.SCHEMA_OBJECT_COUNT  = schemaAnalysis.objectCount?.toString() ?: '0'
                        env.ESTIMATED_DUMP_SIZE  = schemaAnalysis.estimatedDumpSizeGB?.toString() ?: '0'

                        echo """
┌──────────────────────────────────────────────────────┐
│           Analisi Schema Sorgente                    │
├──────────────────────────────────────────────────────┤
│  Schema:              ${params.SCHEMA_NAME.padRight(30)}│
│  Dimensione totale:   ${env.SCHEMA_SIZE_GB.padRight(24)} GB │
│  Numero tabelle:      ${env.SCHEMA_TABLE_COUNT.padRight(30)}│
│  Numero oggetti:      ${env.SCHEMA_OBJECT_COUNT.padRight(30)}│
│  Stima dump file:     ${env.ESTIMATED_DUMP_SIZE.padRight(24)} GB │
└──────────────────────────────────────────────────────┘
                        """
                    }

                    // --- Verifica spazio sufficiente sul target ---
                    if (params.TARGET_DB?.trim()) {
                        withCredentials([usernamePassword(
                            credentialsId: env.TGT_CRED_ID,
                            usernameVariable: 'DB_USER',
                            passwordVariable: 'DB_PASS'
                        )]) {
                            def tgtSpace = oracleDataPump.checkAvailableSpace(
                                dbType:        env.TGT_DB_TYPE,
                                connectString: env.TGT_DB_CONNECT_STR,
                                user:          DB_USER,
                                password:      DB_PASS
                            )
                            env.TGT_FREE_SPACE_GB = tgtSpace.freeSpaceGB?.toString() ?: '0'
                            def estimatedSize = env.ESTIMATED_DUMP_SIZE.toDouble()
                            def availableSpace = env.TGT_FREE_SPACE_GB.toDouble()

                            // Margine di sicurezza: servono almeno 1.5x la dimensione stimata
                            if (availableSpace < (estimatedSize * 1.5)) {
                                echo "\u001B[33m[ATTENZIONE] Spazio disponibile sul target (${availableSpace} GB) potrebbe essere insufficiente per il dump stimato (${estimatedSize} GB).\u001B[0m"
                                if (!params.DRY_RUN) {
                                    input message: "Spazio potenzialmente insufficiente. Continuare comunque?",
                                          ok: 'Procedi'
                                }
                            } else {
                                echo "\u001B[32m[✓] Spazio sufficiente sul target: ${availableSpace} GB disponibili (necessari ~${estimatedSize * 1.5} GB)\u001B[0m"
                            }
                        }
                    }

                    // --- Log dettagliato per audit ---
                    oracleDataPump.writeAuditLog(
                        operation:  params.OPERATION,
                        sourceDb:   params.SOURCE_DB,
                        targetDb:   params.TARGET_DB,
                        schema:     params.SCHEMA_NAME,
                        user:       currentBuild.getBuildCauses()[0]?.userId ?: 'system',
                        buildUrl:   env.BUILD_URL
                    )
                }
            }
        }

        // =====================================================================
        // STAGE 5: EXPORT
        // Esportazione schema/tabelle dal database sorgente
        // Supporta sia Autonomous DB (DBMS_DATAPUMP) che DBCS (expdp CLI)
        // =====================================================================
        stage('Export') {
            when {
                expression {
                    params.OPERATION in ['EXPORT', 'EXPORT_AND_IMPORT', 'BACKUP', 'REFRESH_ENV', 'TABLE_EXPORT']
                }
            }
            steps {
                script {
                    // --- Approvazione manuale per ambienti PROD ---
                    // Politica ENI: export da PROD richiede conferma se non è un backup schedulato
                    if (env.SRC_DB_ENV == 'PROD' && params.OPERATION != 'BACKUP') {
                        input message: """
⚠️  ATTENZIONE: Operazione di EXPORT da ambiente PRODUZIONE (${params.SOURCE_DB}).
Questo potrebbe impattare le performance del database.
Confermi di voler procedere?""",
                              ok: 'Confermo Export da PROD',
                              submitter: 'dba-admin,dba-lead'
                    }

                    if (params.DRY_RUN) {
                        echo "\u001B[33m[DRY RUN] Simulazione export — nessuna operazione eseguita.\u001B[0m"
                        oracleDataPump.logDryRun('EXPORT', [
                            schema: params.SCHEMA_NAME,
                            dumpFile: env.EFFECTIVE_DUMP_FILENAME,
                            parallel: params.PARALLEL,
                            content: params.CONTENT
                        ])
                        return
                    }

                    echo "\u001B[36m[INFO] Avvio export dal database ${params.SOURCE_DB}...\u001B[0m"
                    def exportStartTime = System.currentTimeMillis()

                    withCredentials([usernamePassword(
                        credentialsId: env.SRC_CRED_ID,
                        usernameVariable: 'DB_USER',
                        passwordVariable: 'DB_PASS'
                    )]) {
                        try {
                            def exportResult

                            // --- Discriminazione tipo database: Autonomous vs DBCS ---
                            // Autonomous DB usa DBMS_DATAPUMP via PL/SQL (non ha accesso CLI)
                            // DBCS usa il classico expdp da riga di comando
                            if (env.SRC_DB_TYPE == 'autonomous') {
                                echo "[INFO] Database Autonomous rilevato — utilizzo DBMS_DATAPUMP via PL/SQL"
                                exportResult = oracleDataPump.exportAutonomous(
                                    connectString:  env.SRC_DB_CONNECT_STR,
                                    user:           DB_USER,
                                    password:       DB_PASS,
                                    walletDir:      env.ADB_WALLET_DIR,
                                    schemaName:     params.SCHEMA_NAME,
                                    dumpFileName:   env.EFFECTIVE_DUMP_FILENAME,
                                    logFileName:    env.EFFECTIVE_LOG_FILENAME,
                                    parallel:       params.PARALLEL.toInteger(),
                                    content:        params.CONTENT,
                                    includeGrants:  params.INCLUDE_GRANTS,
                                    includeStats:   params.INCLUDE_STATISTICS,
                                    tableList:      params.TABLE_LIST,
                                    excludeTables:  params.EXCLUDE_TABLES,
                                    queryFilter:    params.QUERY_FILTER,
                                    compression:    params.COMPRESSION,
                                    encryption:     params.ENCRYPTION
                                )
                            } else {
                                echo "[INFO] Database DBCS rilevato — utilizzo expdp CLI"
                                exportResult = oracleDataPump.exportDBCS(
                                    connectString:  env.SRC_DB_CONNECT_STR,
                                    user:           DB_USER,
                                    password:       DB_PASS,
                                    oracleHome:     env.ORACLE_HOME,
                                    schemaName:     params.SCHEMA_NAME,
                                    dumpDir:        env.DUMP_DIR,
                                    dumpFileName:   env.EFFECTIVE_DUMP_FILENAME,
                                    logFileName:    env.EFFECTIVE_LOG_FILENAME,
                                    parallel:       params.PARALLEL.toInteger(),
                                    content:        params.CONTENT,
                                    includeGrants:  params.INCLUDE_GRANTS,
                                    includeStats:   params.INCLUDE_STATISTICS,
                                    tableList:      params.TABLE_LIST,
                                    excludeTables:  params.EXCLUDE_TABLES,
                                    queryFilter:    params.QUERY_FILTER,
                                    compression:    params.COMPRESSION,
                                    encryption:     params.ENCRYPTION
                                )
                            }

                            // --- Verifica risultato export ---
                            if (!exportResult.success) {
                                error "[ERRORE] Export fallito: ${exportResult.error}"
                            }

                            env.EXPORT_DUMP_SIZE = exportResult.dumpSizeMB?.toString() ?: '0'
                            def exportDuration = (System.currentTimeMillis() - exportStartTime) / 1000
                            env.EXPORT_DURATION_SEC = exportDuration.toString()

                            echo "\u001B[32m[✓] Export completato con successo in ${exportDuration}s — Dump: ${env.EXPORT_DUMP_SIZE} MB\u001B[0m"

                        } catch (Exception e) {
                            // Archivia il log anche in caso di errore per analisi successiva
                            archiveArtifacts artifacts: "${LOG_DIR}/${env.EFFECTIVE_LOG_FILENAME}", allowEmptyArchive: true
                            throw e
                        }
                    }

                    // --- Upload dump su OCI Object Storage se richiesto ---
                    // Necessario per trasferimento tra database in ambienti diversi
                    if (params.BUCKET_NAME?.trim()) {
                        echo "[INFO] Upload dump file su OCI Object Storage: bucket '${params.BUCKET_NAME}'"
                        oracleDataPump.uploadToBucket(
                            bucketName:    params.BUCKET_NAME,
                            compartmentId: env.SRC_DB_COMPARTMENT,
                            sourceFile:    "${DUMP_DIR}/${env.EFFECTIVE_DUMP_FILENAME}",
                            objectName:    env.EFFECTIVE_DUMP_FILENAME,
                            dbType:        env.SRC_DB_TYPE,
                            dbOcid:        env.SRC_DB_OCID
                        )
                        echo "\u001B[32m[✓] Upload completato su bucket '${params.BUCKET_NAME}'\u001B[0m"
                    }
                }
            }
        }

        // =====================================================================
        // STAGE 6: IMPORT
        // Importazione dump nel database destinazione
        // Supporta remap schema/tablespace/tabelle e CREATE_NEW_SCHEMA
        // =====================================================================
        stage('Import') {
            when {
                expression {
                    params.OPERATION in ['IMPORT', 'EXPORT_AND_IMPORT', 'REFRESH_ENV', 'TABLE_IMPORT']
                }
            }
            steps {
                script {
                    // --- Approvazione manuale per import su PROD ---
                    // Politica ENI: import su PROD richiede doppia conferma
                    if (env.TGT_DB_ENV == 'PROD') {
                        input message: """
🔴  ATTENZIONE CRITICA: Operazione di IMPORT su database di PRODUZIONE!
    Target: ${params.TARGET_DB}
    Schema: ${params.SCHEMA_NAME}
    TABLE_EXISTS_ACTION: ${params.TABLE_EXISTS_ACTION}

Questa operazione MODIFICHERÀ dati in produzione.
Sei assolutamente sicuro di voler procedere?""",
                              ok: 'CONFERMO IMPORT SU PROD',
                              submitter: 'dba-admin,dba-lead'
                    }

                    if (params.DRY_RUN) {
                        echo "\u001B[33m[DRY RUN] Simulazione import — nessuna operazione eseguita.\u001B[0m"
                        oracleDataPump.logDryRun('IMPORT', [
                            schema: params.SCHEMA_NAME,
                            targetSchema: env.EFFECTIVE_TARGET_SCHEMA,
                            dumpFile: env.EFFECTIVE_DUMP_FILENAME,
                            tableExistsAction: params.TABLE_EXISTS_ACTION
                        ])
                        return
                    }

                    echo "\u001B[36m[INFO] Avvio import verso il database ${params.TARGET_DB}...\u001B[0m"
                    def importStartTime = System.currentTimeMillis()

                    // --- Download dump da OCI Object Storage se necessario ---
                    if (params.BUCKET_NAME?.trim() && params.OPERATION in ['IMPORT', 'EXPORT_AND_IMPORT', 'REFRESH_ENV', 'TABLE_IMPORT']) {
                        echo "[INFO] Download dump file da OCI Object Storage: bucket '${params.BUCKET_NAME}'"
                        oracleDataPump.downloadFromBucket(
                            bucketName:    params.BUCKET_NAME,
                            compartmentId: env.TGT_DB_COMPARTMENT,
                            objectName:    env.EFFECTIVE_DUMP_FILENAME,
                            targetFile:    "${DUMP_DIR}/${env.EFFECTIVE_DUMP_FILENAME}",
                            dbType:        env.TGT_DB_TYPE,
                            dbOcid:        env.TGT_DB_OCID
                        )
                        echo "\u001B[32m[✓] Download completato\u001B[0m"
                    }

                    withCredentials([usernamePassword(
                        credentialsId: env.TGT_CRED_ID,
                        usernameVariable: 'DB_USER',
                        passwordVariable: 'DB_PASS'
                    )]) {
                        try {
                            // --- Costruzione opzioni di remap ---
                            def remapOptions = [:]

                            // Remap schema: se CREATE_NEW_SCHEMA, lo schema target è SCHEMA_NEW
                            if (params.CREATE_NEW_SCHEMA || params.REMAP_SCHEMA?.trim()) {
                                remapOptions.remapSchema = "${params.SCHEMA_NAME}:${env.EFFECTIVE_TARGET_SCHEMA}"
                                echo "[INFO] Remap schema attivo: ${params.SCHEMA_NAME} → ${env.EFFECTIVE_TARGET_SCHEMA}"
                            }

                            // Remap tablespace
                            if (params.REMAP_TABLESPACE?.trim()) {
                                remapOptions.remapTablespace = params.REMAP_TABLESPACE
                                echo "[INFO] Remap tablespace attivo: → ${params.REMAP_TABLESPACE}"
                            }

                            // Remap tabelle (parsing coppie OLD:NEW)
                            if (params.REMAP_TABLE?.trim()) {
                                remapOptions.remapTable = params.REMAP_TABLE
                                echo "[INFO] Remap tabelle attivo: ${params.REMAP_TABLE}"
                            }

                            def importResult

                            // --- Discriminazione tipo database target ---
                            if (env.TGT_DB_TYPE == 'autonomous') {
                                echo "[INFO] Database Autonomous rilevato — utilizzo DBMS_DATAPUMP via PL/SQL"
                                importResult = oracleDataPump.importAutonomous(
                                    connectString:      env.TGT_DB_CONNECT_STR,
                                    user:               DB_USER,
                                    password:           DB_PASS,
                                    walletDir:          env.ADB_WALLET_DIR,
                                    schemaName:         params.SCHEMA_NAME,
                                    dumpFileName:       env.EFFECTIVE_DUMP_FILENAME,
                                    logFileName:        env.EFFECTIVE_LOG_FILENAME.replace('.log', '_imp.log'),
                                    parallel:           params.PARALLEL.toInteger(),
                                    content:            params.CONTENT,
                                    tableExistsAction:  params.TABLE_EXISTS_ACTION,
                                    remapOptions:       remapOptions,
                                    includeGrants:      params.INCLUDE_GRANTS,
                                    includeStats:       params.INCLUDE_STATISTICS,
                                    tableList:          params.TABLE_LIST
                                )
                            } else {
                                echo "[INFO] Database DBCS rilevato — utilizzo impdp CLI"
                                importResult = oracleDataPump.importDBCS(
                                    connectString:      env.TGT_DB_CONNECT_STR,
                                    user:               DB_USER,
                                    password:           DB_PASS,
                                    oracleHome:         env.ORACLE_HOME,
                                    schemaName:         params.SCHEMA_NAME,
                                    dumpDir:            env.DUMP_DIR,
                                    dumpFileName:       env.EFFECTIVE_DUMP_FILENAME,
                                    logFileName:        env.EFFECTIVE_LOG_FILENAME.replace('.log', '_imp.log'),
                                    parallel:           params.PARALLEL.toInteger(),
                                    content:            params.CONTENT,
                                    tableExistsAction:  params.TABLE_EXISTS_ACTION,
                                    remapOptions:       remapOptions,
                                    includeGrants:      params.INCLUDE_GRANTS,
                                    includeStats:       params.INCLUDE_STATISTICS,
                                    tableList:          params.TABLE_LIST
                                )
                            }

                            // --- Verifica risultato import ---
                            if (!importResult.success) {
                                error "[ERRORE] Import fallito: ${importResult.error}"
                            }

                            def importDuration = (System.currentTimeMillis() - importStartTime) / 1000
                            env.IMPORT_DURATION_SEC = importDuration.toString()
                            env.IMPORT_RECORD_COUNT = importResult.recordCount?.toString() ?: '0'

                            echo "\u001B[32m[✓] Import completato con successo in ${importDuration}s — Record importati: ${env.IMPORT_RECORD_COUNT}\u001B[0m"

                        } catch (Exception e) {
                            archiveArtifacts artifacts: "${LOG_DIR}/*_imp.log", allowEmptyArchive: true
                            throw e
                        }
                    }
                }
            }
        }

        // =====================================================================
        // STAGE 7: SWAP AND DROP
        // Scambio schema vecchio/nuovo e drop opzionale del backup
        // Questo stage è critico: ogni errore deve essere gestito con rollback
        // =====================================================================
        stage('Swap and Drop') {
            when {
                expression {
                    params.OPERATION == 'SWAP_AND_DROP' ||
                    (params.SWAP_AFTER_IMPORT && params.OPERATION in ['IMPORT', 'EXPORT_AND_IMPORT', 'REFRESH_ENV'])
                }
            }
            steps {
                script {
                    echo "\u001B[36m[INFO] Avvio operazione Swap and Drop...\u001B[0m"

                    // --- Approvazione manuale obbligatoria per swap su PROD ---
                    if (env.TGT_DB_ENV == 'PROD') {
                        input message: """
🔴  SWAP SU PRODUZIONE — CONFERMA RICHIESTA
    Schema attuale: ${params.SCHEMA_NAME}
    Schema nuovo:   ${env.EFFECTIVE_TARGET_SCHEMA}
    Drop backup:    ${params.DROP_OLD_AFTER_SWAP}

Lo schema corrente verrà rinominato in ${params.SCHEMA_NAME}_BKP
e lo schema nuovo prenderà il nome di produzione.""",
                              ok: 'CONFERMO SWAP SU PROD',
                              submitter: 'dba-admin'
                    }

                    if (params.DRY_RUN) {
                        echo "\u001B[33m[DRY RUN] Simulazione swap — nessuna operazione eseguita.\u001B[0m"
                        return
                    }

                    def targetDb = params.TARGET_DB ?: params.SOURCE_DB

                    withCredentials([usernamePassword(
                        credentialsId: env.TGT_CRED_ID ?: env.SRC_CRED_ID,
                        usernameVariable: 'DB_USER',
                        passwordVariable: 'DB_PASS'
                    )]) {
                        try {
                            // --- Step 1: Validazione dello schema nuovo prima dello swap ---
                            echo "[INFO] Verifica integrità dello schema nuovo: ${env.EFFECTIVE_TARGET_SCHEMA}"
                            def validationResult = oracleDataPump.validateSchema(
                                dbType:         env.TGT_DB_TYPE ?: env.SRC_DB_TYPE,
                                connectString:  env.TGT_DB_CONNECT_STR ?: env.SRC_DB_CONNECT_STR,
                                user:           DB_USER,
                                password:       DB_PASS,
                                schemaName:     env.EFFECTIVE_TARGET_SCHEMA
                            )

                            if (!validationResult.valid) {
                                error "[ERRORE] Lo schema nuovo '${env.EFFECTIVE_TARGET_SCHEMA}' non è valido: ${validationResult.errors}"
                            }
                            echo "\u001B[32m[✓] Schema nuovo validato: ${validationResult.objectCount} oggetti, ${validationResult.tableCount} tabelle\u001B[0m"

                            // --- Step 2: Rename schema corrente → _BKP ---
                            echo "[INFO] Rename: ${params.SCHEMA_NAME} → ${params.SCHEMA_NAME}_BKP"
                            oracleDataPump.renameSchema(
                                dbType:         env.TGT_DB_TYPE ?: env.SRC_DB_TYPE,
                                connectString:  env.TGT_DB_CONNECT_STR ?: env.SRC_DB_CONNECT_STR,
                                user:           DB_USER,
                                password:       DB_PASS,
                                oldName:        params.SCHEMA_NAME,
                                newName:        "${params.SCHEMA_NAME}_BKP"
                            )

                            // --- Step 3: Rename schema nuovo → nome di produzione ---
                            echo "[INFO] Rename: ${env.EFFECTIVE_TARGET_SCHEMA} → ${params.SCHEMA_NAME}"
                            oracleDataPump.renameSchema(
                                dbType:         env.TGT_DB_TYPE ?: env.SRC_DB_TYPE,
                                connectString:  env.TGT_DB_CONNECT_STR ?: env.SRC_DB_CONNECT_STR,
                                user:           DB_USER,
                                password:       DB_PASS,
                                oldName:        env.EFFECTIVE_TARGET_SCHEMA,
                                newName:        params.SCHEMA_NAME
                            )

                            echo "\u001B[32m[✓] Swap completato: ${params.SCHEMA_NAME} è ora lo schema di produzione\u001B[0m"

                            // --- Step 4: Drop backup se richiesto ---
                            if (params.DROP_OLD_AFTER_SWAP) {
                                echo "[INFO] Eliminazione schema backup: ${params.SCHEMA_NAME}_BKP"
                                oracleDataPump.dropSchema(
                                    dbType:         env.TGT_DB_TYPE ?: env.SRC_DB_TYPE,
                                    connectString:  env.TGT_DB_CONNECT_STR ?: env.SRC_DB_CONNECT_STR,
                                    user:           DB_USER,
                                    password:       DB_PASS,
                                    schemaName:     "${params.SCHEMA_NAME}_BKP"
                                )
                                echo "\u001B[32m[✓] Schema backup '${params.SCHEMA_NAME}_BKP' eliminato\u001B[0m"
                            } else {
                                echo "[INFO] Schema backup '${params.SCHEMA_NAME}_BKP' mantenuto per eventuale rollback."
                            }

                        } catch (Exception e) {
                            // --- Tentativo di rollback in caso di errore durante lo swap ---
                            echo "\u001B[31m[ERRORE CRITICO] Swap fallito! Tentativo di rollback...\u001B[0m"
                            try {
                                oracleDataPump.rollbackSwap(
                                    dbType:         env.TGT_DB_TYPE ?: env.SRC_DB_TYPE,
                                    connectString:  env.TGT_DB_CONNECT_STR ?: env.SRC_DB_CONNECT_STR,
                                    user:           DB_USER,
                                    password:       DB_PASS,
                                    schemaName:     params.SCHEMA_NAME
                                )
                                echo "\u001B[33m[INFO] Rollback eseguito. Verificare manualmente lo stato degli schema.\u001B[0m"
                            } catch (Exception rollbackEx) {
                                echo "\u001B[31m[ERRORE] Anche il rollback è fallito: ${rollbackEx.getMessage()}\u001B[0m"
                                echo "\u001B[31m[AZIONE RICHIESTA] Intervento manuale necessario sul database ${targetDb}\u001B[0m"
                            }
                            throw e
                        }
                    }
                }
            }
        }

        // =====================================================================
        // STAGE 8: VERIFICA POST-OPERAZIONE
        // Confronto record e oggetti tra sorgente e destinazione
        // =====================================================================
        stage('Post-Operation Verification') {
            when {
                expression {
                    params.OPERATION in ['IMPORT', 'EXPORT_AND_IMPORT', 'REFRESH_ENV', 'TABLE_IMPORT'] &&
                    !params.DRY_RUN
                }
            }
            steps {
                script {
                    echo "\u001B[36m[INFO] Avvio verifica post-operazione...\u001B[0m"

                    def verificationResults = [:]
                    def discrepancies = []

                    // --- Conteggio record sorgente ---
                    withCredentials([usernamePassword(
                        credentialsId: env.SRC_CRED_ID,
                        usernameVariable: 'SRC_USER',
                        passwordVariable: 'SRC_PASS'
                    )]) {
                        verificationResults.sourceRecords = oracleDataPump.getRecordCounts(
                            dbType:        env.SRC_DB_TYPE,
                            connectString: env.SRC_DB_CONNECT_STR,
                            user:          SRC_USER,
                            password:      SRC_PASS,
                            schemaName:    params.SCHEMA_NAME,
                            tableList:     params.TABLE_LIST
                        )
                    }

                    // --- Conteggio record destinazione ---
                    withCredentials([usernamePassword(
                        credentialsId: env.TGT_CRED_ID,
                        usernameVariable: 'TGT_USER',
                        passwordVariable: 'TGT_PASS'
                    )]) {
                        verificationResults.targetRecords = oracleDataPump.getRecordCounts(
                            dbType:        env.TGT_DB_TYPE,
                            connectString: env.TGT_DB_CONNECT_STR,
                            user:          TGT_USER,
                            password:      TGT_PASS,
                            schemaName:    env.EFFECTIVE_TARGET_SCHEMA,
                            tableList:     params.TABLE_LIST
                        )

                        // --- Confronto conteggio oggetti ---
                        verificationResults.targetObjects = oracleDataPump.getObjectCounts(
                            dbType:        env.TGT_DB_TYPE,
                            connectString: env.TGT_DB_CONNECT_STR,
                            user:          TGT_USER,
                            password:      TGT_PASS,
                            schemaName:    env.EFFECTIVE_TARGET_SCHEMA
                        )
                    }

                    // --- Confronto e log discrepanze ---
                    echo "\n┌──────────────────────────────────────────────────────────────┐"
                    echo "│              Verifica Post-Operazione                        │"
                    echo "├────────────────────┬──────────────┬──────────────┬────────────┤"
                    echo "│ Tabella            │ Sorgente     │ Target       │ Stato      │"
                    echo "├────────────────────┼──────────────┼──────────────┼────────────┤"

                    verificationResults.sourceRecords?.each { tableName, srcCount ->
                        def tgtCount = verificationResults.targetRecords?.get(tableName) ?: 0
                        def status = (srcCount == tgtCount) ? '✓ OK' : '✗ DIFF'
                        if (srcCount != tgtCount) {
                            discrepancies << [table: tableName, source: srcCount, target: tgtCount]
                        }
                        echo "│ ${tableName.padRight(18)} │ ${srcCount.toString().padRight(12)} │ ${tgtCount.toString().padRight(12)} │ ${status.padRight(10)} │"
                    }
                    echo "└────────────────────┴──────────────┴──────────────┴────────────┘"

                    // --- Salvataggio risultati per il report ---
                    env.VERIFICATION_DISCREPANCIES = discrepancies.size().toString()
                    env.VERIFICATION_TOTAL_TABLES = verificationResults.sourceRecords?.size()?.toString() ?: '0'

                    if (discrepancies) {
                        echo "\u001B[33m[ATTENZIONE] Trovate ${discrepancies.size()} discrepanze nei conteggi record.\u001B[0m"
                        discrepancies.each { d ->
                            echo "  - ${d.table}: sorgente=${d.source}, target=${d.target}, differenza=${d.source - d.target}"
                        }
                        // Le discrepanze non bloccano la pipeline ma vengono segnalate nel report
                        currentBuild.result = 'UNSTABLE'
                    } else {
                        echo "\u001B[32m[✓] Verifica completata: tutti i conteggi corrispondono.\u001B[0m"
                    }
                }
            }
        }

        // =====================================================================
        // STAGE 9: GENERAZIONE REPORT
        // Report HTML dettagliato con tutte le informazioni dell'operazione
        // =====================================================================
        stage('Generate Report') {
            when {
                not { equals expected: 'HEALTH_CHECK', actual: params.OPERATION }
            }
            steps {
                script {
                    echo "\u001B[36m[INFO] Generazione report HTML...\u001B[0m"

                    def reportData = [
                        operation:          params.OPERATION,
                        sourceDb:           params.SOURCE_DB,
                        targetDb:           params.TARGET_DB ?: 'N/A',
                        sourceEnv:          env.SRC_DB_ENV ?: 'N/A',
                        targetEnv:          env.TGT_DB_ENV ?: 'N/A',
                        schemaName:         params.SCHEMA_NAME,
                        targetSchema:       env.EFFECTIVE_TARGET_SCHEMA ?: params.SCHEMA_NAME,
                        dumpFileName:       env.EFFECTIVE_DUMP_FILENAME,
                        dumpSizeMB:         env.EXPORT_DUMP_SIZE ?: 'N/A',
                        schemaSizeGB:       env.SCHEMA_SIZE_GB ?: 'N/A',
                        tableCount:         env.SCHEMA_TABLE_COUNT ?: 'N/A',
                        objectCount:        env.SCHEMA_OBJECT_COUNT ?: 'N/A',
                        parallel:           params.PARALLEL,
                        content:            params.CONTENT,
                        compression:        params.COMPRESSION,
                        encryption:         params.ENCRYPTION,
                        tableExistsAction:  params.TABLE_EXISTS_ACTION,
                        exportDuration:     env.EXPORT_DURATION_SEC ?: 'N/A',
                        importDuration:     env.IMPORT_DURATION_SEC ?: 'N/A',
                        importRecordCount:  env.IMPORT_RECORD_COUNT ?: 'N/A',
                        discrepancies:      env.VERIFICATION_DISCREPANCIES ?: '0',
                        totalTables:        env.VERIFICATION_TOTAL_TABLES ?: '0',
                        dryRun:             params.DRY_RUN,
                        buildNumber:        env.BUILD_NUMBER,
                        buildUrl:           env.BUILD_URL,
                        startedBy:          currentBuild.getBuildCauses()[0]?.userId ?: 'Schedulato',
                        timestamp:          new Date().format('yyyy-MM-dd HH:mm:ss z')
                    ]

                    // --- Generazione HTML tramite shared library ---
                    def reportHtml = oracleDataPump.generateHtmlReport(reportData)

                    // --- Salvataggio report su disco ---
                    def reportFileName = "datapump_report_${env.BUILD_NUMBER}_${new Date().format('yyyyMMdd_HHmmss')}.html"
                    writeFile file: "${REPORT_DIR}/${reportFileName}", text: reportHtml
                    env.REPORT_FILE = "${REPORT_DIR}/${reportFileName}"

                    // --- Pubblicazione report come artefatto Jenkins ---
                    publishHTML(target: [
                        allowMissing:          false,
                        alwaysLinkToLastBuild: true,
                        keepAll:              true,
                        reportDir:            env.REPORT_DIR,
                        reportFiles:          reportFileName,
                        reportName:           'Data Pump Report'
                    ])

                    echo "\u001B[32m[✓] Report generato: ${reportFileName}\u001B[0m"
                }
            }
        }

    } // fine stages

    // =========================================================================
    // AZIONI POST-BUILD
    // Gestione notifiche, archiviazione log, pulizia
    // =========================================================================
    post {
        always {
            script {
                echo "\u001B[36m[INFO] Esecuzione azioni post-build...\u001B[0m"

                // --- Archiviazione log Data Pump ---
                archiveArtifacts artifacts: "${LOG_DIR}/*.log", allowEmptyArchive: true

                // --- Archiviazione report se generato ---
                if (env.REPORT_FILE) {
                    archiveArtifacts artifacts: "${REPORT_DIR}/*.html", allowEmptyArchive: true
                }

                // --- Log riepilogativo finale ---
                def finalStatus = currentBuild.currentResult ?: 'UNKNOWN'
                def totalDuration = currentBuild.durationString ?: 'N/A'
                echo """
╔══════════════════════════════════════════════════════════════════╗
║          ENI Oracle Data Pump — Riepilogo Finale                ║
╠══════════════════════════════════════════════════════════════════╣
║  Build:        #${env.BUILD_NUMBER.padRight(50)}║
║  Stato:        ${finalStatus.padRight(50)}║
║  Operazione:   ${params.OPERATION.padRight(50)}║
║  Durata:       ${totalDuration.padRight(50)}║
║  Sorgente:     ${(params.SOURCE_DB ?: 'N/A').padRight(50)}║
║  Destinazione: ${(params.TARGET_DB ?: 'N/A').padRight(50)}║
║  Schema:       ${(params.SCHEMA_NAME ?: 'N/A').padRight(50)}║
║  Dump File:    ${(env.EFFECTIVE_DUMP_FILENAME ?: 'N/A').padRight(50)}║
╚══════════════════════════════════════════════════════════════════╝
                """
            }
        }

        success {
            script {
                // --- Notifica successo via email ---
                def subject = "[ENI DataPump] ✓ ${params.OPERATION} completato — ${params.SCHEMA_NAME}@${params.SOURCE_DB}"
                def body = """
<html>
<body style="font-family: Arial, sans-serif;">
<h2 style="color: #28a745;">✓ Operazione Data Pump completata con successo</h2>
<table style="border-collapse: collapse; width: 100%;">
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Operazione</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.OPERATION}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Schema</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.SCHEMA_NAME}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Database Sorgente</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.SOURCE_DB}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Database Target</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.TARGET_DB ?: 'N/A'}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Dump File</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.EFFECTIVE_DUMP_FILENAME}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Dump Size</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.EXPORT_DUMP_SIZE ?: 'N/A'} MB</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Durata Export</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.EXPORT_DURATION_SEC ?: 'N/A'} sec</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Durata Import</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.IMPORT_DURATION_SEC ?: 'N/A'} sec</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Record Importati</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.IMPORT_RECORD_COUNT ?: 'N/A'}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Discrepanze</b></td><td style="padding: 8px; border: 1px solid #ddd;">${env.VERIFICATION_DISCREPANCIES ?: '0'}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Build</b></td><td style="padding: 8px; border: 1px solid #ddd;"><a href="${env.BUILD_URL}">#${env.BUILD_NUMBER}</a></td></tr>
</table>
</body>
</html>
                """
                emailext(
                    to:       env.EFFECTIVE_EMAIL,
                    subject:  subject,
                    body:     body,
                    mimeType: 'text/html',
                    attachmentsPattern: "${REPORT_DIR}/*.html"
                )
            }
        }

        failure {
            script {
                // --- Notifica fallimento con dettagli errore ---
                def subject = "[ENI DataPump] ✗ FALLITO — ${params.OPERATION} su ${params.SCHEMA_NAME}@${params.SOURCE_DB}"
                def errorLog = ''
                try {
                    // Tentativo di recuperare le ultime righe del log
                    errorLog = sh(script: "tail -50 ${LOG_DIR}/${env.EFFECTIVE_LOG_FILENAME} 2>/dev/null || echo 'Log non disponibile'", returnStdout: true).trim()
                } catch (Exception ignored) {
                    errorLog = 'Impossibile recuperare il log di errore.'
                }

                def body = """
<html>
<body style="font-family: Arial, sans-serif;">
<h2 style="color: #dc3545;">✗ Operazione Data Pump FALLITA</h2>
<table style="border-collapse: collapse; width: 100%;">
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Operazione</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.OPERATION}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Schema</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.SCHEMA_NAME}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Database Sorgente</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.SOURCE_DB}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Database Target</b></td><td style="padding: 8px; border: 1px solid #ddd;">${params.TARGET_DB ?: 'N/A'}</td></tr>
  <tr><td style="padding: 8px; border: 1px solid #ddd;"><b>Build</b></td><td style="padding: 8px; border: 1px solid #ddd;"><a href="${env.BUILD_URL}">#${env.BUILD_NUMBER}</a></td></tr>
</table>
<h3>Ultime righe del log:</h3>
<pre style="background: #f8f9fa; padding: 12px; border: 1px solid #ddd; overflow-x: auto;">${errorLog}</pre>
<p><b>Azione richiesta:</b> Verificare il log completo su Jenkins e contattare il DBA Team se necessario.</p>
</body>
</html>
                """
                emailext(
                    to:       env.EFFECTIVE_EMAIL,
                    subject:  subject,
                    body:     body,
                    mimeType: 'text/html',
                    attachmentsPattern: "${LOG_DIR}/*.log"
                )
            }
        }

        unstable {
            script {
                // --- Notifica per build instabile (discrepanze nei conteggi) ---
                emailext(
                    to:       env.EFFECTIVE_EMAIL,
                    subject:  "[ENI DataPump] ⚠ INSTABILE — ${params.OPERATION} su ${params.SCHEMA_NAME} — Discrepanze rilevate",
                    body:     """
<html>
<body style="font-family: Arial, sans-serif;">
<h2 style="color: #ffc107;">⚠ Operazione completata con discrepanze</h2>
<p>L'operazione ${params.OPERATION} è stata completata ma sono state rilevate <b>${env.VERIFICATION_DISCREPANCIES}</b> discrepanze
nei conteggi record tra sorgente e destinazione.</p>
<p>Verificare il report dettagliato: <a href="${env.BUILD_URL}">Build #${env.BUILD_NUMBER}</a></p>
</body>
</html>
                    """,
                    mimeType: 'text/html'
                )
            }
        }

        cleanup {
            script {
                // --- Pulizia file temporanei ---
                // I dump file NON vengono eliminati per sicurezza; solo i file di lavoro temporanei
                echo "[INFO] Pulizia file temporanei..."
                sh """
                    rm -f /tmp/datapump_*.tmp 2>/dev/null || true
                    rm -f /tmp/eni_dp_*.sql 2>/dev/null || true
                    echo "[INFO] Pulizia completata."
                """

                // --- Pulizia workspace Jenkins ---
                cleanWs(
                    cleanWhenNotBuilt: false,
                    deleteDirs:       false,
                    disableDeferredWipeout: true,
                    notFailBuild:     true,
                    patterns: [
                        [pattern: '**/*.tmp', type: 'INCLUDE'],
                        [pattern: '**/*.log', type: 'EXCLUDE']
                    ]
                )
            }
        }
    } // fine post
}
