#!/usr/bin/env groovy
// =============================================================================
// oracleConnect.groovy — Libreria condivisa Jenkins per connettività Oracle
// ENI S.p.A. — Gestione connessioni e esecuzione SQL/PL/SQL
// =============================================================================
// Supporta: Autonomous DB (Oracle Wallet), DBCS (host:port/service),
// on-premises. Esecuzione SQL tramite sqlplus o sqlcl.
// =============================================================================

import groovy.json.JsonSlurper

// Timeout predefinito per le operazioni SQL (secondi)
private static final int SQL_TIMEOUT_SECONDS = 300
// Tool SQL predefinito (sqlplus o sql per sqlcl)
private static final String DEFAULT_SQL_TOOL = 'sqlplus'

// --------------------------------------------------------------------------
// Validazione della connettività al database
// Esegue un semplice SELECT per verificare che il DB sia raggiungibile
// --------------------------------------------------------------------------
def validateConnection(Map dbConfig) {
    assert dbConfig : "dbConfig non può essere null"

    echo "[OracleConnect] ➤ Validazione connessione a '${dbConfig.dbName ?: dbConfig.serviceName ?: 'N/A'}'..."

    def testSql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT 'CONNECTION_OK' FROM DUAL;
EXIT;
"""
    try {
        def output = runSqlStatement(dbConfig, testSql)
        if (output?.contains('CONNECTION_OK')) {
            echo "[OracleConnect] ✔ Connessione validata con successo"
            return [status: 'OK', message: 'Connessione valida']
        } else {
            echo "[OracleConnect] ⚠ Risposta inattesa: ${output}"
            return [status: 'WARNING', message: "Risposta inattesa: ${output}"]
        }
    } catch (Exception e) {
        echo "[OracleConnect] ✖ Connessione fallita: ${e.message}"
        return [status: 'FAILED', message: e.message]
    }
}

// --------------------------------------------------------------------------
// Esecuzione di un file SQL con sostituzione parametri
// I parametri vengono passati come variabili di sostituzione (&param)
// --------------------------------------------------------------------------
def runSql(Map dbConfig, String sqlFilePath, Map params = [:]) {
    assert dbConfig : "dbConfig non può essere null"
    assert sqlFilePath?.trim() : "Il percorso del file SQL non può essere vuoto"

    echo "[OracleConnect] ➤ Esecuzione file SQL: ${sqlFilePath}"

    // Verifica esistenza file SQL
    def fileOk = sh(script: "test -f '${sqlFilePath}' && echo 'OK' || echo 'MISSING'", returnStdout: true).trim()
    if (fileOk != 'OK') {
        error "[OracleConnect] ✖ File SQL non trovato: ${sqlFilePath}"
    }

    // Costruzione parametri di sostituzione per sqlplus
    def paramStr = ''
    if (params) {
        // I parametri vengono passati come argomenti posizionali a sqlplus
        paramStr = params.values().collect { "'${it}'" }.join(' ')
        echo "[OracleConnect] Parametri: ${params.keySet().join(', ')}"
    }

    def output = ''
    def connStr = buildConnectionString(dbConfig)
    def sqlTool = dbConfig.sqlTool ?: DEFAULT_SQL_TOOL
    def credId = dbConfig.credentialId ?: 'oracle-db-credentials'

    // Esecuzione con gestione sicura delle credenziali
    if (dbConfig.dbType?.toLowerCase() in ['autonomous', 'adb']) {
        // Connessione Autonomous DB con Oracle Wallet
        output = executeWithWallet(dbConfig, credId, sqlTool) { dbUser, dbPass, effectiveConnStr ->
            def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${dbUser}"/"${dbPass}"@"${effectiveConnStr}"
@"${sqlFilePath}" ${paramStr}
EXIT;
EOF
"""
            return sh(script: cmd, returnStdout: true).trim()
        }
    } else {
        // Connessione standard con username/password
        withCredentials([usernamePassword(
                credentialsId: credId,
                usernameVariable: 'DB_USER',
                passwordVariable: 'DB_PASS')]) {
            def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${env.DB_USER}"/"${env.DB_PASS}"@"${connStr}"
@"${sqlFilePath}" ${paramStr}
EXIT;
EOF
"""
            output = sh(script: cmd, returnStdout: true).trim()
        }
    }

    // Controllo errori ORA- nel risultato
    checkForOracleErrors(output, sqlFilePath)
    return output
}

// --------------------------------------------------------------------------
// Esecuzione di una istruzione SQL inline (stringa)
// Utile per query brevi e comandi DDL/DML
// --------------------------------------------------------------------------
def runSqlStatement(Map dbConfig, String sqlStatement) {
    assert dbConfig : "dbConfig non può essere null"
    assert sqlStatement?.trim() : "L'istruzione SQL non può essere vuota"

    echo "[OracleConnect] ➤ Esecuzione istruzione SQL inline"

    def output = ''
    def connStr = buildConnectionString(dbConfig)
    def sqlTool = dbConfig.sqlTool ?: DEFAULT_SQL_TOOL
    def credId = dbConfig.credentialId ?: 'oracle-db-credentials'

    // Scrittura SQL temporaneo su file per evitare problemi di escaping nella shell
    def tmpFile = "${env.WORKSPACE}/tmp_sql_${System.currentTimeMillis()}.sql"

    try {
        writeFile file: tmpFile, text: """
SET SERVEROUTPUT ON SIZE UNLIMITED
SET PAGESIZE 1000
SET LINESIZE 200
SET FEEDBACK OFF
${sqlStatement}
EXIT;
"""
        if (dbConfig.dbType?.toLowerCase() in ['autonomous', 'adb']) {
            output = executeWithWallet(dbConfig, credId, sqlTool) { dbUser, dbPass, effectiveConnStr ->
                def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${dbUser}"/"${dbPass}"@"${effectiveConnStr}"
@"${tmpFile}"
EXIT;
EOF
"""
                return sh(script: cmd, returnStdout: true).trim()
            }
        } else {
            withCredentials([usernamePassword(
                    credentialsId: credId,
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASS')]) {
                def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${env.DB_USER}"/"${env.DB_PASS}"@"${connStr}"
@"${tmpFile}"
EXIT;
EOF
"""
                output = sh(script: cmd, returnStdout: true).trim()
            }
        }
    } finally {
        // Pulizia file temporaneo — contiene potenziali informazioni sensibili
        sh(script: "rm -f '${tmpFile}'", returnStatus: true)
    }

    checkForOracleErrors(output, 'inline SQL')
    return output
}

// --------------------------------------------------------------------------
// Esecuzione di un blocco PL/SQL da file
// Abilita SERVEROUTPUT per catturare l'output DBMS_OUTPUT
// --------------------------------------------------------------------------
def runPlSql(Map dbConfig, String plsqlFilePath, Map params = [:]) {
    assert dbConfig : "dbConfig non può essere null"
    assert plsqlFilePath?.trim() : "Il percorso del file PL/SQL non può essere vuoto"

    echo "[OracleConnect] ➤ Esecuzione blocco PL/SQL: ${plsqlFilePath}"

    // Verifica esistenza file
    def fileOk = sh(script: "test -f '${plsqlFilePath}' && echo 'OK' || echo 'MISSING'", returnStdout: true).trim()
    if (fileOk != 'OK') {
        error "[OracleConnect] ✖ File PL/SQL non trovato: ${plsqlFilePath}"
    }

    // Wrapper che abilita SERVEROUTPUT prima dell'esecuzione
    def wrapperFile = "${env.WORKSPACE}/plsql_wrapper_${System.currentTimeMillis()}.sql"
    def paramStr = params ? params.values().collect { "'${it}'" }.join(' ') : ''

    try {
        writeFile file: wrapperFile, text: """
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
@'${plsqlFilePath}' ${paramStr}
EXIT;
"""
        def output = ''
        def connStr = buildConnectionString(dbConfig)
        def sqlTool = dbConfig.sqlTool ?: DEFAULT_SQL_TOOL
        def credId = dbConfig.credentialId ?: 'oracle-db-credentials'

        if (dbConfig.dbType?.toLowerCase() in ['autonomous', 'adb']) {
            output = executeWithWallet(dbConfig, credId, sqlTool) { dbUser, dbPass, effectiveConnStr ->
                def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${dbUser}"/"${dbPass}"@"${effectiveConnStr}"
@"${wrapperFile}"
EXIT;
EOF
"""
                return sh(script: cmd, returnStdout: true).trim()
            }
        } else {
            withCredentials([usernamePassword(
                    credentialsId: credId,
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASS')]) {
                def cmd = """
${sqlTool} -S /nolog <<EOF
CONNECT "${env.DB_USER}"/"${env.DB_PASS}"@"${connStr}"
@"${wrapperFile}"
EXIT;
EOF
"""
                output = sh(script: cmd, returnStdout: true).trim()
            }
        }

        checkForOracleErrors(output, plsqlFilePath)
        return output
    } finally {
        sh(script: "rm -f '${wrapperFile}'", returnStatus: true)
    }
}

// --------------------------------------------------------------------------
// Calcolo dimensione dello schema in MB
// Query su DBA_SEGMENTS per la somma dei bytes allocati
// --------------------------------------------------------------------------
def getSchemaSize(Map dbConfig, String schema) {
    assert schema?.trim() : "Lo schema non può essere vuoto"

    echo "[OracleConnect] ➤ Calcolo dimensione schema '${schema}'..."

    def sql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT ROUND(NVL(SUM(bytes)/1024/1024, 0), 2)
FROM DBA_SEGMENTS
WHERE owner = UPPER('${schema}');
EXIT;
"""
    def output = runSqlStatement(dbConfig, sql)
    def sizeMb = 0.0

    try {
        sizeMb = output?.trim()?.toDouble() ?: 0.0
    } catch (Exception e) {
        echo "[OracleConnect] ⚠ Impossibile parsare la dimensione: '${output}'"
    }

    echo "[OracleConnect] Dimensione schema '${schema}': ${sizeMb} MB"
    return sizeMb
}

// --------------------------------------------------------------------------
// Statistiche dello schema: conteggio tabelle e righe
// Utile per verifiche pre/post import
// --------------------------------------------------------------------------
def getSchemaStats(Map dbConfig, String schema) {
    assert schema?.trim() : "Lo schema non può essere vuoto"

    echo "[OracleConnect] ➤ Recupero statistiche schema '${schema}'..."

    // Query per conteggio tabelle e stima righe (da statistiche Oracle)
    def sql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 500
SELECT t.table_name || '|' || NVL(t.num_rows, 0)
FROM all_tables t
WHERE t.owner = UPPER('${schema}')
ORDER BY t.table_name;
EXIT;
"""
    def output = runSqlStatement(dbConfig, sql)
    def stats = [tableCount: 0, tables: [:], totalRows: 0L]

    if (output) {
        output.split('\n').each { line ->
            line = line.trim()
            if (line && line.contains('|')) {
                def parts = line.split('\\|')
                def tableName = parts[0]?.trim()
                def rowCount = 0L
                try {
                    rowCount = parts[1]?.trim()?.toLong() ?: 0L
                } catch (Exception ignored) {}

                if (tableName) {
                    stats.tables[tableName] = rowCount
                    stats.totalRows += rowCount
                    stats.tableCount++
                }
            }
        }
    }

    echo "[OracleConnect] Schema '${schema}': ${stats.tableCount} tabelle, ~${stats.totalRows} righe totali"
    return stats
}

// --------------------------------------------------------------------------
// Verifica esistenza di uno schema nel database
// --------------------------------------------------------------------------
def schemaExists(Map dbConfig, String schema) {
    assert schema?.trim() : "Lo schema non può essere vuoto"

    echo "[OracleConnect] Verifica esistenza schema '${schema}'..."

    def sql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM all_users WHERE username = UPPER('${schema}');
EXIT;
"""
    def output = runSqlStatement(dbConfig, sql)
    def exists = false

    try {
        exists = (output?.trim()?.toInteger() ?: 0) > 0
    } catch (Exception ignored) {}

    echo "[OracleConnect] Schema '${schema}': ${exists ? 'presente' : 'non trovato'}"
    return exists
}

// --------------------------------------------------------------------------
// Determinazione del tipo di database dalla configurazione
// Restituisce: 'autonomous', 'dbcs', 'onprem'
// --------------------------------------------------------------------------
def getDatabaseType(Map dbConfig) {
    assert dbConfig : "dbConfig non può essere null"

    // Se il tipo è specificato esplicitamente, lo restituiamo direttamente
    if (dbConfig.dbType) {
        return dbConfig.dbType.toLowerCase()
    }

    // Euristica basata sulla configurazione fornita
    if (dbConfig.walletPath || dbConfig.walletCredentialId) {
        echo "[OracleConnect] Tipo DB rilevato: autonomous (wallet presente)"
        return 'autonomous'
    }

    if (dbConfig.ociDbId || dbConfig.ocid) {
        echo "[OracleConnect] Tipo DB rilevato: dbcs (OCID presente)"
        return 'dbcs'
    }

    if (dbConfig.host && dbConfig.serviceName) {
        echo "[OracleConnect] Tipo DB rilevato: onprem (host/service configurati)"
        return 'onprem'
    }

    echo "[OracleConnect] ⚠ Tipo DB non determinabile, default: dbcs"
    return 'dbcs'
}

// --------------------------------------------------------------------------
// Costruzione della stringa di connessione in base al tipo di database
// --------------------------------------------------------------------------
def buildConnectionString(Map dbConfig) {
    def dbType = getDatabaseType(dbConfig)

    switch (dbType) {
        case 'autonomous':
        case 'adb':
            // Per ADB usiamo il TNS alias definito nel tnsnames.ora del wallet
            def tnsAlias = dbConfig.tnsAlias ?: dbConfig.serviceName ?: "${dbConfig.dbName}_high"
            echo "[OracleConnect] Stringa connessione ADB: ${tnsAlias}"
            return tnsAlias

        case 'dbcs':
        case 'onprem':
            // Formato standard: host:port/service_name
            def host = dbConfig.host ?: 'localhost'
            def port = dbConfig.port ?: '1521'
            def service = dbConfig.serviceName ?: dbConfig.sid
            if (!service) {
                error "[OracleConnect] ✖ serviceName o sid obbligatorio per connessione ${dbType}"
            }

            // Utilizzo formato Easy Connect Plus se possibile
            def connStr = "${host}:${port}/${service}"
            echo "[OracleConnect] Stringa connessione: ${connStr}"
            return connStr

        default:
            error "[OracleConnect] ✖ Tipo database sconosciuto: ${dbType}"
    }
}

// --------------------------------------------------------------------------
// Recupero spazio disponibile in un tablespace (in MB)
// Utile per verifiche pre-import sulla capienza
// --------------------------------------------------------------------------
def getAvailableSpace(Map dbConfig, String tablespace) {
    assert tablespace?.trim() : "Il nome del tablespace non può essere vuoto"

    echo "[OracleConnect] ➤ Verifica spazio disponibile nel tablespace '${tablespace}'..."

    def sql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT ROUND(
    (SELECT NVL(SUM(bytes)/1024/1024, 0) FROM dba_free_space WHERE tablespace_name = UPPER('${tablespace}'))
    +
    (SELECT NVL(SUM(
        CASE WHEN autoextensible = 'YES' THEN (maxbytes - bytes)/1024/1024 ELSE 0 END
    ), 0) FROM dba_data_files WHERE tablespace_name = UPPER('${tablespace}'))
, 2)
FROM DUAL;
EXIT;
"""
    def output = runSqlStatement(dbConfig, sql)
    def spaceMb = 0.0

    try {
        spaceMb = output?.trim()?.toDouble() ?: 0.0
    } catch (Exception e) {
        echo "[OracleConnect] ⚠ Impossibile determinare lo spazio: '${output}'"
    }

    echo "[OracleConnect] Spazio disponibile in '${tablespace}': ${spaceMb} MB"
    return spaceMb
}

// ==========================================================================
// FUNZIONI INTERNE DI UTILITÀ
// ==========================================================================

// --------------------------------------------------------------------------
// Esecuzione SQL con Oracle Wallet (per Autonomous Database)
// Configura TNS_ADMIN con la posizione del wallet e richiama il closure
// --------------------------------------------------------------------------
private def executeWithWallet(Map dbConfig, String credId, String sqlTool, Closure sqlAction) {
    def walletCredId = dbConfig.walletCredentialId ?: 'oracle-wallet-zip'
    // Estrarre il wallet in /tmp garantisce pulizia OS su reboot ed evita commit nel workspace
    def walletDir = "/tmp/eni_wallet_${System.currentTimeMillis()}_${UUID.randomUUID().toString().substring(0,8)}"

    def output = ''
    try {
        // Estrazione wallet dalle credenziali Jenkins (file zip)
        withCredentials([file(credentialsId: walletCredId, variable: 'WALLET_ZIP')]) {
            sh(script: "mkdir -p '${walletDir}' && chmod 700 '${walletDir}' && unzip -o '${env.WALLET_ZIP}' -d '${walletDir}'", returnStatus: true)
        }

        // Configurazione TNS_ADMIN per puntare alla directory del wallet
        withEnv(["TNS_ADMIN=${walletDir}"]) {
            withCredentials([usernamePassword(
                    credentialsId: credId,
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASS')]) {
                def connStr = buildConnectionString(dbConfig)
                output = sqlAction.call(env.DB_USER, env.DB_PASS, connStr)
            }
        }
    } finally {
        // Pulizia wallet estratto — contiene informazioni sensibili
        sh(script: "rm -rf '${walletDir}'", returnStatus: true)
    }

    return output
}

// --------------------------------------------------------------------------
// Controllo errori Oracle nell'output SQL
// Cerca pattern ORA- e SP2- tipici di errori Oracle
// --------------------------------------------------------------------------
private void checkForOracleErrors(String output, String context) {
    if (!output) return

    // Pattern errori Oracle critici
    def errorPatterns = ['ORA-', 'SP2-', 'PLS-']
    // Pattern da ignorare (warning non bloccanti specifici per Oracle Data Pump/Migrazioni)
    def ignorePatterns = [
        'ORA-31626', // Job non esiste
        'ORA-39082', // Oggetto creato con warning di compilazione
        'ORA-31684', // Object type already exists
        'ORA-39111', // Dependent object type exists and was skipped
        'ORA-39151', // Table exists; all dependent metadata and data will be skipped
        'ORA-39083', // Object type failed to create (spesso per grant mancanti)
        'ORA-01917', // User or role does not exist
        'ORA-00959', // Tablespace does not exist
        'ORA-31685'  // Object type failed due to insufficient privileges
    ]

    for (pattern in errorPatterns) {
        if (output.contains(pattern)) {
            // Verifica se l'errore è nella lista degli errori ignorabili
            def isIgnorable = ignorePatterns.any { ignore -> output.contains(ignore) }
            if (!isIgnorable) {
                // Estrazione riga contenente l'errore per il messaggio diagnostico
                def errorLine = output.split('\n').find { it.contains(pattern) }
                echo "[OracleConnect] ✖ Errore Oracle rilevato in '${context}': ${errorLine}"
                error "[OracleConnect] Errore Oracle: ${errorLine}"
            } else {
                echo "[OracleConnect] ⚠ Warning Oracle (non bloccante) in '${context}'"
            }
        }
    }
}
