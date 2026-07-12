#!/usr/bin/env groovy
// =============================================================================
// oracleDataPump.groovy — Libreria condivisa Jenkins per Oracle Data Pump
// ENI S.p.A. — Automazione Database Oracle su OCI
// =============================================================================
// Operazioni principali: Export/Import schema e tabelle via CLI (expdp/impdp)
// per database DBCS e via PL/SQL (DBMS_DATAPUMP) per Autonomous Database.
// =============================================================================

import groovy.json.JsonSlurper

// --------------------------------------------------------------------------
// Funzione principale di export — indirizza a CLI o PL/SQL in base al tipo DB
// --------------------------------------------------------------------------
def exportSchema(Map dbConfig, String schema, Map options = [:]) {
    assert dbConfig : "dbConfig non può essere null"
    assert schema?.trim() : "Lo schema non può essere vuoto"

    echo "[DataPump] ➤ Avvio export schema '${schema}' su ${dbConfig.dbName ?: 'N/A'}"
    def startTime = System.currentTimeMillis()

    // Generazione nome file dump se non specificato
    if (!options.dumpFilename) {
        options.dumpFilename = generateDumpFilename(schema, 'EXPORT')
    }

    def result = [:]
    try {
        def dbType = dbConfig.dbType?.toLowerCase() ?: 'dbcs'
        switch (dbType) {
            case 'autonomous':
            case 'adb':
                result = autonomousExport(dbConfig, schema, options)
                break
            case 'dbcs':
            case 'onprem':
                result = cliExport(dbConfig, schema, options)
                break
            default:
                error "[DataPump] Tipo database non supportato: ${dbType}. Valori ammessi: autonomous, dbcs, onprem"
        }
        result.durationMs = System.currentTimeMillis() - startTime
        result.dumpFilename = options.dumpFilename
        echo "[DataPump] ✔ Export schema '${schema}' completato in ${formatMs(result.durationMs)}"
    } catch (Exception e) {
        result.durationMs = System.currentTimeMillis() - startTime
        result.error = e.message
        echo "[DataPump] ✖ Errore durante export schema '${schema}': ${e.message}"
        throw e
    }
    return result
}

// --------------------------------------------------------------------------
// Funzione principale di import — indirizza a CLI o PL/SQL in base al tipo DB
// --------------------------------------------------------------------------
def importSchema(Map dbConfig, String schema, Map options = [:]) {
    assert dbConfig : "dbConfig non può essere null"
    assert schema?.trim() : "Lo schema non può essere vuoto"

    echo "[DataPump] ➤ Avvio import schema '${schema}' su ${dbConfig.dbName ?: 'N/A'}"
    def startTime = System.currentTimeMillis()

    if (!options.dumpFilename) {
        error "[DataPump] dumpFilename è obbligatorio per l'operazione di import"
    }

    def result = [:]
    try {
        def dbType = dbConfig.dbType?.toLowerCase() ?: 'dbcs'
        switch (dbType) {
            case 'autonomous':
            case 'adb':
                result = autonomousImport(dbConfig, schema, options)
                break
            case 'dbcs':
            case 'onprem':
                result = cliImport(dbConfig, schema, options)
                break
            default:
                error "[DataPump] Tipo database non supportato: ${dbType}"
        }
        result.durationMs = System.currentTimeMillis() - startTime
        echo "[DataPump] ✔ Import schema '${schema}' completato in ${formatMs(result.durationMs)}"
    } catch (Exception e) {
        result.durationMs = System.currentTimeMillis() - startTime
        result.error = e.message
        echo "[DataPump] ✖ Errore durante import schema '${schema}': ${e.message}"
        throw e
    }
    return result
}

// --------------------------------------------------------------------------
// Export di tabelle specifiche — filtra solo le tabelle indicate
// --------------------------------------------------------------------------
def exportTables(Map dbConfig, String schema, List tables, Map options = [:]) {
    assert tables && !tables.isEmpty() : "La lista delle tabelle non può essere vuota"

    echo "[DataPump] ➤ Export tabelle selezionate da '${schema}': ${tables.join(', ')}"
    // Impostiamo il filtro tabelle nelle opzioni
    options.tables = tables
    if (!options.dumpFilename) {
        options.dumpFilename = generateDumpFilename(schema, 'TABLES_EXPORT')
    }
    return exportSchema(dbConfig, schema, options)
}

// --------------------------------------------------------------------------
// Import di tabelle specifiche — importa solo le tabelle indicate
// --------------------------------------------------------------------------
def importTables(Map dbConfig, String schema, List tables, Map options = [:]) {
    assert tables && !tables.isEmpty() : "La lista delle tabelle non può essere vuota"

    echo "[DataPump] ➤ Import tabelle selezionate in '${schema}': ${tables.join(', ')}"
    options.tables = tables
    return importSchema(dbConfig, schema, options)
}

// --------------------------------------------------------------------------
// Export via CLI (expdp) — per database DBCS e on-premises
// --------------------------------------------------------------------------
def cliExport(Map dbConfig, String schema, Map options = [:]) {
    echo "[DataPump/CLI] Esecuzione expdp per schema '${schema}'..."
    def command = buildExpdpCommand(dbConfig, schema, options)

    // Esecuzione comando con credenziali sicure dal Jenkins Credentials Store
    def result = [operation: 'CLI_EXPORT', schema: schema, status: 'UNKNOWN']
    def credId = dbConfig.credentialId ?: 'oracle-db-credentials'

    withCredentials([usernamePassword(
            credentialsId: credId,
            usernameVariable: 'DB_USER',
            passwordVariable: 'DB_PASS')]) {

        // Sostituzione placeholder credenziali nel comando
        def secureCmd = command.replace('__DB_USER__', env.DB_USER)
                               .replace('__DB_PASS__', env.DB_PASS)

        def exitCode = sh(script: secureCmd, returnStatus: true)
        if (exitCode != 0) {
            result.status = 'FAILED'
            error "[DataPump/CLI] expdp fallito con codice di uscita: ${exitCode}"
        }
        result.status = 'SUCCESS'
    }

    // Verifica che il file dump sia stato creato
    def dumpDir = options.dumpDir ?: '/u01/app/oracle/datapump'
    def dumpFile = "${dumpDir}/${options.dumpFilename}"
    def fileCheck = sh(script: "ls -la ${dumpFile}", returnStatus: true)
    if (fileCheck != 0) {
        echo "[DataPump/CLI] ⚠ Attenzione: file dump non trovato in ${dumpFile}"
    } else {
        // Recupero dimensione file
        result.fileSize = sh(script: "stat -c%s ${dumpFile} 2>/dev/null || stat -f%z ${dumpFile} 2>/dev/null", returnStdout: true).trim()
        echo "[DataPump/CLI] File dump creato: ${dumpFile} (${result.fileSize} bytes)"
    }

    return result
}

// --------------------------------------------------------------------------
// Import via CLI (impdp) — per database DBCS e on-premises
// --------------------------------------------------------------------------
def cliImport(Map dbConfig, String schema, Map options = [:]) {
    echo "[DataPump/CLI] Esecuzione impdp per schema '${schema}'..."
    def command = buildImpdpCommand(dbConfig, schema, options)

    def result = [operation: 'CLI_IMPORT', schema: schema, status: 'UNKNOWN']
    def credId = dbConfig.credentialId ?: 'oracle-db-credentials'

    withCredentials([usernamePassword(
            credentialsId: credId,
            usernameVariable: 'DB_USER',
            passwordVariable: 'DB_PASS')]) {

        def secureCmd = command.replace('__DB_USER__', env.DB_USER)
                               .replace('__DB_PASS__', env.DB_PASS)

        def exitCode = sh(script: secureCmd, returnStatus: true)
        if (exitCode != 0) {
            result.status = 'FAILED'
            error "[DataPump/CLI] impdp fallito con codice di uscita: ${exitCode}"
        }
        result.status = 'SUCCESS'
    }
    echo "[DataPump/CLI] ✔ Import CLI completato per schema '${schema}'"
    return result
}

// --------------------------------------------------------------------------
// Export via PL/SQL DBMS_DATAPUMP — per Autonomous Database
// Genera ed esegue blocco PL/SQL tramite sqlplus/sqlcl
// --------------------------------------------------------------------------
def autonomousExport(Map dbConfig, String schema, Map options = [:]) {
    echo "[DataPump/ADB] Esecuzione export DBMS_DATAPUMP per schema '${schema}'..."

    def result = [operation: 'AUTONOMOUS_EXPORT', schema: schema, status: 'UNKNOWN']
    def jobName = "EXP_${schema}_${new Date().format('yyyyMMdd_HHmmss')}"
    def dumpFilename = options.dumpFilename ?: generateDumpFilename(schema, 'EXPORT')
    def logFilename = dumpFilename.replace('.dmp', '.log')
    def parallel = options.parallel ?: 1
    def compression = options.compression ?: 'ALL'

    // Costruzione blocco PL/SQL per DBMS_DATAPUMP
    def plsqlBlock = """
DECLARE
    v_handle   NUMBER;
    v_status   VARCHAR2(200);
    v_job_name VARCHAR2(128) := '${jobName}';
BEGIN
    -- Apertura job Data Pump di tipo EXPORT
    v_handle := DBMS_DATAPUMP.OPEN(
        operation   => 'EXPORT',
        job_mode    => '${options.tables ? "TABLE" : "SCHEMA"}',
        job_name    => v_job_name,
        version     => 'LATEST'
    );

    -- Configurazione file dump su Object Storage (credenziale OCI preconfigurata)
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${dumpFilename}',
        directory => '${options.bucketName ? "DATA_PUMP_DIR" : "DATA_PUMP_DIR"}',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
    );

    -- File di log
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${logFilename}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
    );

    -- Filtro schema
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'SCHEMA_EXPR',
        value  => 'IN (''${schema}'')'
    );
"""
    // Filtro tabelle specifiche se presenti
    if (options.tables) {
        def tableList = options.tables.collect { "'${it.toUpperCase()}'" }.join(',')
        plsqlBlock += """
    -- Filtro tabelle specifiche
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'NAME_EXPR',
        value  => 'IN (${tableList})'
    );
"""
    }

    // Esclusione tabelle se specificato
    if (options.excludeTables) {
        def excludeList = options.excludeTables.collect { "'${it.toUpperCase()}'" }.join(',')
        plsqlBlock += """
    -- Esclusione tabelle non desiderate
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'NAME_EXPR',
        value  => 'NOT IN (${excludeList})',
        object_type => 'TABLE'
    );
"""
    }

    // Filtro query personalizzato (WHERE clause)
    if (options.queryFilter) {
        plsqlBlock += """
    -- Filtro dati con clausola WHERE
    DBMS_DATAPUMP.DATA_FILTER(
        handle      => v_handle,
        name        => 'SUBQUERY',
        value       => '${options.queryFilter}',
        schema_name => '${schema}'
    );
"""
    }

    // Impostazione parallelismo
    plsqlBlock += """
    -- Grado di parallelismo per performance
    DBMS_DATAPUMP.SET_PARALLEL(
        handle          => v_handle,
        degree          => ${parallel}
    );

    -- Compressione dati
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'COMPRESSION',
        value  => '${compression}'
    );

    -- Supporto Restartability
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'KEEP_MASTER',
        value  => 1
    );
"""

    // Data Masking
    if (options.maskingRules) {
        options.maskingRules.split(',').each { rule ->
            def ruleParts = rule.split(':')
            if (ruleParts.length == 2) {
                def colParts = ruleParts[0].split('\\.')
                if (colParts.length == 3) {
                    plsqlBlock += """
    -- Data Masking
    DBMS_DATAPUMP.DATA_REMAP(
        handle       => v_handle,
        name         => 'COLUMN_FUNCTION',
        table_name   => '${colParts[1]}',
        column       => '${colParts[2]}',
        function     => '${ruleParts[1]}',
        schema_name  => '${colParts[0]}'
    );
"""
                }
            }
        }
    }

    // Esclusione statistiche se richiesto
    if (options.includeStatistics == false) {
        plsqlBlock += """
    -- Esclusione statistiche dall'export
    DBMS_DATAPUMP.METADATA_FILTER(
        handle      => v_handle,
        name        => 'EXCLUDE_PATH_EXPR',
        value       => 'IN (''STATISTICS'')'
    );
"""
    }

    // Esclusione grant se richiesto
    if (options.includeGrants == false) {
        plsqlBlock += """
    -- Esclusione grant dall'export
    DBMS_DATAPUMP.METADATA_FILTER(
        handle      => v_handle,
        name        => 'EXCLUDE_PATH_EXPR',
        value       => 'IN (''GRANT'')'
    );
"""
    }

    plsqlBlock += """
    -- Avvio job di export
    DBMS_DATAPUMP.START_JOB(handle => v_handle);

    -- Attesa completamento (detach per monitoraggio separato)
    DBMS_DATAPUMP.DETACH(handle => v_handle);

    DBMS_OUTPUT.PUT_LINE('JOB_NAME=' || v_job_name);
    DBMS_OUTPUT.PUT_LINE('DUMP_FILE=' || '${dumpFilename}');
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            DBMS_DATAPUMP.DETACH(handle => v_handle);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        RAISE;
END;
/
"""

    // Esecuzione PL/SQL tramite oracleConnect
    result.jobName = jobName
    def sqlOutput = oracleConnect.runSqlStatement(dbConfig, plsqlBlock)
    echo "[DataPump/ADB] Job avviato: ${jobName}"

    // Monitoraggio completamento job
    monitorJob(dbConfig, jobName)
    result.status = 'SUCCESS'
    result.dumpFilename = dumpFilename

    return result
}

// --------------------------------------------------------------------------
// Import via PL/SQL DBMS_DATAPUMP — per Autonomous Database
// --------------------------------------------------------------------------
def autonomousImport(Map dbConfig, String schema, Map options = [:]) {
    echo "[DataPump/ADB] Esecuzione import DBMS_DATAPUMP per schema '${schema}'..."

    def result = [operation: 'AUTONOMOUS_IMPORT', schema: schema, status: 'UNKNOWN']
    def jobName = "IMP_${schema}_${new Date().format('yyyyMMdd_HHmmss')}"
    def dumpFilename = options.dumpFilename
    def logFilename = "IMP_${schema}_${new Date().format('yyyyMMdd_HHmmss')}.log"
    def parallel = options.parallel ?: 1
    def tableExistsAction = options.tableExistsAction ?: 'SKIP'

    // Costruzione blocco PL/SQL per import DBMS_DATAPUMP
    def plsqlBlock = """
DECLARE
    v_handle   NUMBER;
    v_job_name VARCHAR2(128) := '${jobName}';
BEGIN
    -- Apertura job Data Pump di tipo IMPORT
    v_handle := DBMS_DATAPUMP.OPEN(
        operation   => 'IMPORT',
        job_mode    => '${options.tables ? "TABLE" : "SCHEMA"}',
        job_name    => v_job_name,
        version     => 'LATEST'
    );

    -- File dump sorgente
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${dumpFilename}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
    );

    -- File di log per import
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${logFilename}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
    );

    -- Azione su tabelle esistenti (SKIP, REPLACE, APPEND, TRUNCATE)
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'TABLE_EXISTS_ACTION',
        value  => '${tableExistsAction}'
    );
"""

    // Remap schema se necessario (es. da schema sorgente a schema destinazione)
    if (options.remapSchema) {
        plsqlBlock += """
    -- Remapping schema: sorgente → destinazione
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_SCHEMA',
        old_value => '${options.remapSchema.from}',
        value     => '${options.remapSchema.to}'
    );
"""
    }

    // Remap tablespace se necessario
    if (options.remapTablespace) {
        plsqlBlock += """
    -- Remapping tablespace
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_TABLESPACE',
        old_value => '${options.remapTablespace.from}',
        value     => '${options.remapTablespace.to}'
    );
"""
    }

    // Remap singola tabella se necessario
    if (options.remapTable) {
        plsqlBlock += """
    -- Remapping nome tabella
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_TABLE',
        old_value => '${options.remapTable.from}',
        value     => '${options.remapTable.to}'
    );
"""
    }

    // Filtro tabelle specifiche per import selettivo
    if (options.tables) {
        def tableList = options.tables.collect { "'${it.toUpperCase()}'" }.join(',')
        plsqlBlock += """
    -- Filtro tabelle specifiche per import selettivo
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'NAME_EXPR',
        value  => 'IN (${tableList})'
    );
"""
    }

    plsqlBlock += """
    -- Grado di parallelismo
    DBMS_DATAPUMP.SET_PARALLEL(
        handle => v_handle,
        degree => ${parallel}
    );

    -- Supporto Restartability
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'KEEP_MASTER',
        value  => 1
    );
"""

    // Data Masking per Import
    if (options.maskingRules) {
        options.maskingRules.split(',').each { rule ->
            def ruleParts = rule.split(':')
            if (ruleParts.length == 2) {
                def colParts = ruleParts[0].split('\\.')
                if (colParts.length == 3) {
                    plsqlBlock += """
    -- Data Masking
    DBMS_DATAPUMP.DATA_REMAP(
        handle       => v_handle,
        name         => 'COLUMN_FUNCTION',
        table_name   => '${colParts[1]}',
        column       => '${colParts[2]}',
        function     => '${ruleParts[1]}',
        schema_name  => '${colParts[0]}'
    );
"""
                }
            }
        }
    }

    plsqlBlock += """
    -- Avvio job di import
    DBMS_DATAPUMP.START_JOB(handle => v_handle);

    -- Detach per monitoraggio separato
    DBMS_DATAPUMP.DETACH(handle => v_handle);

    DBMS_OUTPUT.PUT_LINE('JOB_NAME=' || v_job_name);
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            DBMS_DATAPUMP.DETACH(handle => v_handle);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        RAISE;
END;
/
"""

    result.jobName = jobName
    oracleConnect.runSqlStatement(dbConfig, plsqlBlock)
    echo "[DataPump/ADB] Job import avviato: ${jobName}"

    // Monitoraggio completamento
    monitorJob(dbConfig, jobName)
    result.status = 'SUCCESS'
    return result
}

// --------------------------------------------------------------------------
// Monitoraggio progresso job Data Pump tramite DBA_DATAPUMP_JOBS
// Polling periodico fino a completamento o errore
// --------------------------------------------------------------------------
def monitorJob(Map dbConfig, String jobName, int pollIntervalSeconds = 30) {
    echo "[DataPump/Monitor] Inizio monitoraggio job '${jobName}' (intervallo: ${pollIntervalSeconds}s)..."

    def maxAttempts = 720   // Massimo 6 ore di attesa (720 × 30s)
    def attempt = 0
    def completed = false

    while (!completed && attempt < maxAttempts) {
        attempt++
        sleep(pollIntervalSeconds)

        // Query stato job dalla vista DBA_DATAPUMP_JOBS
        def checkSql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT state || '|' || NVL(attached_sessions,0)
FROM DBA_DATAPUMP_JOBS
WHERE job_name = '${jobName}';
EXIT;
"""
        def output = ''
        try {
            output = oracleConnect.runSqlStatement(dbConfig, checkSql)
        } catch (Exception e) {
            echo "[DataPump/Monitor] ⚠ Errore nel polling: ${e.message}"
            continue
        }

        output = output?.trim()

        // Se nessun risultato, il job è terminato (rimosso dalla vista)
        if (!output || output.isEmpty() || output.contains('no rows')) {
            echo "[DataPump/Monitor] ✔ Job '${jobName}' completato (non più presente in DBA_DATAPUMP_JOBS)"
            completed = true
            break
        }

        def parts = output.split('\\|')
        def state = parts[0]?.trim()
        def sessions = parts.length > 1 ? parts[1]?.trim() : '0'

        echo "[DataPump/Monitor] Job '${jobName}': stato=${state}, sessioni=${sessions} [tentativo ${attempt}/${maxAttempts}]"

        switch (state) {
            case 'COMPLETED':
                echo "[DataPump/Monitor] ✔ Job completato con successo"
                completed = true
                break
            case 'STOPPED':
            case 'STOP PENDING':
                error "[DataPump/Monitor] ✖ Job interrotto: stato=${state}"
                break
            case 'NOT RUNNING':
                // Il job potrebbe essersi completato: verifica nel log
                echo "[DataPump/Monitor] ⚠ Job non in esecuzione, verifica completamento..."
                completed = true
                break
            case 'EXECUTING':
            case 'DEFINING':
            case 'COMPLETING':
                // Continua il polling — il job è ancora attivo
                break
            default:
                echo "[DataPump/Monitor] ⚠ Stato sconosciuto: ${state}"
        }
    }

    if (!completed) {
        error "[DataPump/Monitor] ✖ Timeout: il job '${jobName}' non si è completato entro ${maxAttempts * pollIntervalSeconds} secondi"
    }
}

// --------------------------------------------------------------------------
// Swap tabelle: rinomina VECCHIO→_BKP, NUOVO→VECCHIO
// Utile per refresh dati con downtime minimo
// --------------------------------------------------------------------------
def swapAndDrop(Map dbConfig, String schema, String newSchema, boolean dropOld = false) {
    echo "[DataPump/Swap] Avvio swap schema: '${schema}' ↔ '${newSchema}' (dropOld=${dropOld})"

    // Recupero lista tabelle dallo schema sorgente
    def tablesSql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT table_name FROM all_tables WHERE owner = UPPER('${schema}') ORDER BY table_name;
EXIT;
"""
    def tablesOutput = oracleConnect.runSqlStatement(dbConfig, tablesSql)
    def tables = tablesOutput?.trim()?.split('\n')?.collect { it.trim() }?.findAll { it }

    if (!tables || tables.isEmpty()) {
        error "[DataPump/Swap] Nessuna tabella trovata nello schema '${schema}'"
    }

    echo "[DataPump/Swap] Tabelle da swappare: ${tables.size()}"

    // Blocco PL/SQL per eseguire lo swap atomico delle tabelle
    def swapPlsql = "BEGIN\n"
    tables.each { table ->
        // Passo 1: Rinomina tabella corrente → _BKP
        swapPlsql += """
    -- Swap tabella: ${table}
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ${schema}.${table} RENAME TO ${table}_BKP';
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
    -- Rinomina nuova tabella al nome originale
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ${newSchema}.${table} RENAME TO ${table}';
        EXECUTE IMMEDIATE 'ALTER TABLE ${schema}.${table} RENAME TO ${schema}.${table}'; -- placeholder
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
"""
    }

    // Eventuale drop delle tabelle _BKP
    if (dropOld) {
        tables.each { table ->
            swapPlsql += """
    -- Eliminazione backup: ${table}_BKP
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE ${schema}.${table}_BKP CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
"""
        }
    }
    swapPlsql += "END;\n/\n"

    oracleConnect.runSqlStatement(dbConfig, swapPlsql)
    echo "[DataPump/Swap] ✔ Swap completato per ${tables.size()} tabelle"
    return [status: 'SUCCESS', tablesSwapped: tables.size(), dropped: dropOld]
}

// --------------------------------------------------------------------------
// Costruzione comando expdp con tutte le opzioni supportate
// --------------------------------------------------------------------------
def buildExpdpCommand(Map dbConfig, String schema, Map options) {
    def connStr = "__DB_USER__/__DB_PASS__@${dbConfig.connectionString ?: dbConfig.host + ':' + (dbConfig.port ?: '1521') + '/' + dbConfig.serviceName}"
    def dumpDir = options.dumpDir ?: '/u01/app/oracle/datapump'
    def dumpFile = options.dumpFilename ?: generateDumpFilename(schema, 'EXPORT')
    def logFile = dumpFile.replace('.dmp', '.log')

    def cmd = new StringBuilder()
    cmd.append("expdp '${connStr}'")
    cmd.append(" DIRECTORY=DATA_PUMP_DIR")
    cmd.append(" DUMPFILE=${dumpFile}")
    cmd.append(" LOGFILE=${logFile}")

    // Modalità schema o tabella
    if (options.tables) {
        def tableList = options.tables.collect { "${schema}.${it}" }.join(',')
        cmd.append(" TABLES=${tableList}")
    } else {
        cmd.append(" SCHEMAS=${schema}")
    }

    // Grado di parallelismo
    if (options.parallel) {
        cmd.append(" PARALLEL=${options.parallel}")
    }

    // Tipo di contenuto (ALL, DATA_ONLY, METADATA_ONLY)
    if (options.content) {
        cmd.append(" CONTENT=${options.content}")
    }

    // Esclusione grant
    if (options.includeGrants == false) {
        cmd.append(" EXCLUDE=GRANT")
    }

    // Esclusione statistiche
    if (options.includeStatistics == false) {
        cmd.append(" EXCLUDE=STATISTICS")
    }

    // Filtro tabelle da escludere
    if (options.excludeTables) {
        options.excludeTables.each { table ->
            cmd.append(" EXCLUDE=TABLE:\"IN ('${table.toUpperCase()}')\"")
        }
    }

    // Filtro query personalizzato
    if (options.queryFilter) {
        cmd.append(" QUERY=${schema}:\"${options.queryFilter}\"")
    }

    // Compressione
    if (options.compression) {
        cmd.append(" COMPRESSION=${options.compression}")
    }

    // Crittografia
    if (options.encryption) {
        cmd.append(" ENCRYPTION=${options.encryption}")
        cmd.append(" ENCRYPTION_ALGORITHM=AES256")
    }

    // Data Masking
    if (options.maskingRules) {
        cmd.append(" REMAP_DATA=${options.maskingRules}")
    }
    
    // Restartability
    cmd.append(" KEEP_MASTER=Y")

    echo "[DataPump/CLI] Comando expdp costruito (credenziali mascherate)"
    return cmd.toString()
}

// --------------------------------------------------------------------------
// Costruzione comando impdp con tutte le opzioni supportate
// --------------------------------------------------------------------------
def buildImpdpCommand(Map dbConfig, String schema, Map options) {
    def connStr = "__DB_USER__/__DB_PASS__@${dbConfig.connectionString ?: dbConfig.host + ':' + (dbConfig.port ?: '1521') + '/' + dbConfig.serviceName}"
    def dumpFile = options.dumpFilename
    def logFile = "IMP_${schema}_${new Date().format('yyyyMMdd_HHmmss')}.log"

    def cmd = new StringBuilder()
    cmd.append("impdp '${connStr}'")
    cmd.append(" DIRECTORY=DATA_PUMP_DIR")
    cmd.append(" DUMPFILE=${dumpFile}")
    cmd.append(" LOGFILE=${logFile}")

    // Modalità schema o tabella
    if (options.tables) {
        def tableList = options.tables.collect { "${schema}.${it}" }.join(',')
        cmd.append(" TABLES=${tableList}")
    } else {
        cmd.append(" SCHEMAS=${schema}")
    }

    // Azione su tabelle esistenti (SKIP, REPLACE, APPEND, TRUNCATE)
    if (options.tableExistsAction) {
        cmd.append(" TABLE_EXISTS_ACTION=${options.tableExistsAction}")
    }

    // Remap schema (sorgente → destinazione)
    if (options.remapSchema) {
        cmd.append(" REMAP_SCHEMA=${options.remapSchema.from}:${options.remapSchema.to}")
    }

    // Remap tablespace
    if (options.remapTablespace) {
        cmd.append(" REMAP_TABLESPACE=${options.remapTablespace.from}:${options.remapTablespace.to}")
    }

    // Remap tabella
    if (options.remapTable) {
        cmd.append(" REMAP_TABLE=${options.remapTable.from}:${options.remapTable.to}")
    }

    // Grado di parallelismo
    if (options.parallel) {
        cmd.append(" PARALLEL=${options.parallel}")
    }

    // Tipo di contenuto
    if (options.content) {
        cmd.append(" CONTENT=${options.content}")
    }

    // Esclusione grant
    if (options.includeGrants == false) {
        cmd.append(" EXCLUDE=GRANT")
    }

    // Esclusione statistiche
    if (options.includeStatistics == false) {
        cmd.append(" EXCLUDE=STATISTICS")
    }

    // Data Masking
    if (options.maskingRules) {
        cmd.append(" REMAP_DATA=${options.maskingRules}")
    }
    
    // Restartability
    cmd.append(" KEEP_MASTER=Y")

    echo "[DataPump/CLI] Comando impdp costruito (credenziali mascherate)"
    return cmd.toString()
}

// --------------------------------------------------------------------------
// Generazione nome file dump univoco con timestamp
// --------------------------------------------------------------------------
def generateDumpFilename(String schema, String operation) {
    def timestamp = new Date().format('yyyyMMdd_HHmmss')
    def filename = "${operation}_${schema}_${timestamp}.dmp"
    echo "[DataPump] Nome dump generato: ${filename}"
    return filename
}

// --------------------------------------------------------------------------
// Utility: formattazione millisecondi in formato leggibile
// --------------------------------------------------------------------------
@NonCPS
private String formatMs(long ms) {
    def seconds = (ms / 1000) % 60 as int
    def minutes = (ms / (1000 * 60)) % 60 as int
    def hours = (ms / (1000 * 60 * 60)) as int
    return String.format("%02d:%02d:%02d", hours, minutes, seconds)
}
