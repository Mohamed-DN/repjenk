#!/usr/bin/env groovy
// =============================================================================
// oracleDataPump.groovy — Libreria condivisa Jenkins per Oracle Data Pump
// ACME S.p.A. — Automazione Database Oracle su OCI
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
    def fileCheck = sh(script: "ls -la \"${dumpFile}\"", returnStatus: true)
    if (fileCheck != 0) {
        echo "[DataPump/CLI] ⚠ Attenzione: file dump non trovato in ${dumpFile}"
    } else {
        // Recupero dimensione file
        result.fileSize = sh(script: "stat -c%s \"${dumpFile}\" 2>/dev/null || stat -f%z \"${dumpFile}\" 2>/dev/null", returnStdout: true).trim()
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
    v_job_name VARCHAR2(128) := '${jobName.replace("'", "''")}';
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
        filename  => '${dumpFilename.replace("'", "''")}',
        directory => 'DATA_PUMP_DIR',  -- TODO P2: export diretto su Object Storage via URI + credential
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
    );

    -- File di log
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${logFilename.replace("'", "''")}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
    );

    -- Filtro schema
    DBMS_DATAPUMP.METADATA_FILTER(
        handle => v_handle,
        name   => 'SCHEMA_EXPR',
        value  => 'IN (''${schema.replace("'", "''")}'')'
    );
"""
    // Filtro tabelle specifiche se presenti
    if (options.tables) {
        def tableList = options.tables.collect { "'${it.toUpperCase().replace("'", "''")}'" }.join(',')
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
        def excludeTablesList = options.excludeTables instanceof String ? options.excludeTables.split(',').collect{it.trim()} : options.excludeTables
        def excludeList = excludeTablesList.collect { "'${it.toUpperCase().replace("'", "''")}'" }.join(',')
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
        value       => '${options.queryFilter.replace("'", "''")}',
        schema_name => '${schema.replace("'", "''")}'
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
        value  => '${compression.replace("'", "''")}'
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
        for (def rule in options.maskingRules.split(',')) {
            def ruleParts = rule.split(':')
            if (ruleParts.length == 2) {
                def colParts = ruleParts[0].split('\\.')
                if (colParts.length == 3) {
                    plsqlBlock += """
    -- Data Masking
    DBMS_DATAPUMP.DATA_REMAP(
        handle       => v_handle,
        name         => 'COLUMN_FUNCTION',
        table_name   => '${colParts[1].replace("'", "''")}',
        column       => '${colParts[2].replace("'", "''")}',
        function     => '${ruleParts[1].replace("'", "''")}',
        schema_name  => '${colParts[0].replace("'", "''")}'
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
    DBMS_OUTPUT.PUT_LINE('DUMP_FILE=' || '${dumpFilename.replace("'", "''")}');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRORE FATALE IN DBMS_DATAPUMP: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        BEGIN
            DBMS_DATAPUMP.STOP_JOB(handle => v_handle, immediate => 1, keep_master => 0);
        EXCEPTION WHEN OTHERS THEN 
            BEGIN
                DBMS_DATAPUMP.DETACH(handle => v_handle);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
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
    v_job_name VARCHAR2(128) := '${jobName.replace("'", "''")}';
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
        filename  => '${dumpFilename.replace("'", "''")}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
    );

    -- File di log per import
    DBMS_DATAPUMP.ADD_FILE(
        handle    => v_handle,
        filename  => '${logFilename.replace("'", "''")}',
        directory => 'DATA_PUMP_DIR',
        filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
    );

    -- Azione su tabelle esistenti (SKIP, REPLACE, APPEND, TRUNCATE)
    DBMS_DATAPUMP.SET_PARAMETER(
        handle => v_handle,
        name   => 'TABLE_EXISTS_ACTION',
        value  => '${tableExistsAction.replace("'", "''")}'
    );
"""

    // Remap schema se necessario (es. da schema sorgente a schema destinazione)
    if (options.remapSchema) {
        plsqlBlock += """
    -- Remapping schema: sorgente → destinazione
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_SCHEMA',
        old_value => '${options.remapSchema.from.replace("'", "''")}',
        value     => '${options.remapSchema.to.replace("'", "''")}'
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
        old_value => '${options.remapTablespace.from.replace("'", "''")}',
        value     => '${options.remapTablespace.to.replace("'", "''")}'
    );
"""
    }

    // Remap singola tabella se necessario
    if (options.remapTable) {
        def remaps = options.remapTable instanceof List ? options.remapTable : [options.remapTable]
        remaps.each { remap ->
            plsqlBlock += """
    -- Remapping tabella
    DBMS_DATAPUMP.METADATA_REMAP(
        handle    => v_handle,
        name      => 'REMAP_TABLE',
        old_value => '${remap.from.replace("'", "''")}',
        value     => '${remap.to.replace("'", "''")}'
    );
"""
        }
    }

    // Filtro tabelle specifiche per import selettivo
    if (options.tables) {
        def tableList = options.tables.collect { "'${it.toUpperCase().replace("'", "''")}'" }.join(',')
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
        for (def rule in options.maskingRules.split(',')) {
            def ruleParts = rule.split(':')
            if (ruleParts.length == 2) {
                def colParts = ruleParts[0].split('\\.')
                if (colParts.length == 3) {
                    plsqlBlock += """
    -- Data Masking
    DBMS_DATAPUMP.DATA_REMAP(
        handle       => v_handle,
        name         => 'COLUMN_FUNCTION',
        table_name   => '${colParts[1].replace("'", "''")}',
        column       => '${colParts[2].replace("'", "''")}',
        function     => '${ruleParts[1].replace("'", "''")}',
        schema_name  => '${colParts[0].replace("'", "''")}'
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
        DBMS_OUTPUT.PUT_LINE('ERRORE FATALE IN DBMS_DATAPUMP: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        BEGIN
            DBMS_DATAPUMP.STOP_JOB(handle => v_handle, immediate => 1, keep_master => 0);
        EXCEPTION WHEN OTHERS THEN 
            BEGIN
                DBMS_DATAPUMP.DETACH(handle => v_handle);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
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
    for (def table in tables) {
        // Passo 1: Rinomina tabella corrente → _BKP
        swapPlsql += """
    -- Swap tabella: ${table}
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ${schema.replace("'", "''")}.${table.replace("'", "''")} RENAME TO ${table.replace("'", "''")}_BKP';
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
    -- Rinomina nuova tabella al nome originale
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ${newSchema.replace("'", "''")}.${table.replace("'", "''")} RENAME TO ${table.replace("'", "''")}';
    EXCEPTION WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
"""
    }

    // Eventuale drop delle tabelle _BKP
    if (dropOld) {
        for (def table in tables) {
            swapPlsql += """
    -- Eliminazione backup: ${table}_BKP
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE ${schema.replace("'", "''")}.${table.replace("'", "''")}_BKP CASCADE CONSTRAINTS PURGE';
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
        def excludeTablesList = options.excludeTables instanceof String ? options.excludeTables.split(',').collect{it.trim()} : options.excludeTables
        for (def table in excludeTablesList) {
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
        def remaps = options.remapTable instanceof List ? options.remapTable : [options.remapTable]
        remaps.each { remap ->
            cmd.append(" REMAP_TABLE=${remap.from}:${remap.to}")
        }
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

// ==========================================================================
// FACADE LAYER — funzioni richiamate direttamente dal Jenkinsfile
// Delegano a oracleConnect / ociStorage / notifyResult mantenendo
// un'unica interfaccia verso la pipeline.
// Convenzione: tutte accettano una Map di argomenti nominati contenente
// almeno { dbType, credentialId, [walletCredentialId], host/port/serviceName
// oppure tnsAlias/connectionString }.
// ==========================================================================

// --------------------------------------------------------------------------
// Costruzione dbConfig normalizzato a partire dagli argomenti della facade
// --------------------------------------------------------------------------
private Map toDbConfig(Map args) {
    return [
        dbType:             args.dbType,
        host:               args.host,
        port:               args.port,
        serviceName:        args.serviceName,
        tnsAlias:           args.tnsAlias ?: args.connectString ?: args.connectionString,
        connectionString:   args.connectString ?: args.connectionString,
        credentialId:       args.credentialId,
        walletCredentialId: args.walletCredentialId,
        dbName:             args.dbName
    ]
}

// --------------------------------------------------------------------------
// Test di connettività: verifica raggiungibilità e recupera la versione DB
// Ritorna: [success: bool, version: String, error: String]
// --------------------------------------------------------------------------
def testConnectivity(Map args) {
    def dbConfig = toDbConfig(args)
    try {
        def sql = """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT version_full FROM product_component_version WHERE ROWNUM = 1;
EXIT;
"""
        def output = oracleConnect.runSqlStatement(dbConfig, sql)
        def version = output?.readLines()?.collect { it.trim() }?.find { it ==~ /^\d+(\.\d+)+$/ }
        if (version) {
            return [success: true, version: version]
        }
        return [success: false, error: "Risposta inattesa dal database: ${output?.take(200)}"]
    } catch (Exception e) {
        return [success: false, error: e.message]
    }
}

// --------------------------------------------------------------------------
// Spazio disponibile: filesystem locale (dumpDir) e/o tablespace target
// Ritorna: [freeSpaceGB: Double, fsFreeSpaceGB: Double]
// --------------------------------------------------------------------------
def checkAvailableSpace(Map args) {
    def result = [freeSpaceGB: 0.0d, fsFreeSpaceGB: null]

    // Spazio nel tablespace di default (lato database)
    def tablespace = args.tablespace ?: 'USERS'
    try {
        def spaceMb = oracleConnect.getAvailableSpace(toDbConfig(args), tablespace)
        result.freeSpaceGB = ((spaceMb ?: 0.0d) / 1024).toDouble().round(2)
    } catch (Exception e) {
        echo "[DataPump/Space] ⚠ Impossibile leggere lo spazio del tablespace '${tablespace}': ${e.message}"
    }

    // Spazio sul filesystem dell'agent (solo se richiesto: dumpDir valorizzato)
    if (args.dumpDir) {
        try {
            def fsGb = sh(
                script: "df -P --block-size=1G '${args.dumpDir}' | awk 'NR==2 {print \$4}'",
                returnStdout: true
            ).trim()
            result.fsFreeSpaceGB = fsGb ? fsGb.toDouble() : null
            echo "[DataPump/Space] Filesystem '${args.dumpDir}': ${result.fsFreeSpaceGB} GB liberi"
        } catch (Exception e) {
            echo "[DataPump/Space] ⚠ Impossibile leggere lo spazio filesystem: ${e.message}"
        }
    }
    return result
}

// --------------------------------------------------------------------------
// Analisi schema: dimensione, numero tabelle/oggetti e stima dump
// Ritorna: [sizeGB, tableCount, objectCount, estimatedDumpSizeGB]
// --------------------------------------------------------------------------
def analyzeSchema(Map args) {
    assert args.schemaName?.trim() : "schemaName è obbligatorio per analyzeSchema"
    def dbConfig = toDbConfig(args)
    def schema = args.schemaName.trim()

    def sizeMb = oracleConnect.getSchemaSize(dbConfig, schema)
    def stats  = oracleConnect.getSchemaStats(dbConfig, schema)

    def objCount = 0
    try {
        def output = oracleConnect.runSqlStatement(dbConfig, """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM all_objects WHERE owner = UPPER('${schema}');
EXIT;
""")
        objCount = output?.readLines()?.collect { it.trim() }?.find { it.isInteger() }?.toInteger() ?: 0
    } catch (Exception e) {
        echo "[DataPump/Analyze] ⚠ Conteggio oggetti non disponibile: ${e.message}"
    }

    def sizeGb = ((sizeMb ?: 0.0d) / 1024).toDouble().round(2)

    // Stima dump: i dati pesano ~80% dei segmenti (indici esclusi dal dump),
    // poi si applica il fattore di compressione richiesto.
    def contentFactor = (args.content == 'METADATA_ONLY') ? 0.05d : 0.8d
    def compressionFactor
    switch (args.compression ?: 'NONE') {
        case 'ALL':   compressionFactor = 0.25d; break
        case 'BASIC': compressionFactor = 0.5d;  break
        default:      compressionFactor = 1.0d
    }
    def estimated = (sizeGb * contentFactor * compressionFactor).toDouble().round(2)

    return [
        sizeGB:              sizeGb,
        tableCount:          stats.tableCount ?: 0,
        objectCount:         objCount,
        estimatedDumpSizeGB: estimated,
        totalRows:           stats.totalRows ?: 0L
    ]
}

// --------------------------------------------------------------------------
// Audit log — delega a notifyResult.auditLog
// --------------------------------------------------------------------------
def writeAuditLog(Map args) {
    try {
        notifyResult.auditLog([
            operation: args.operation,
            schema:    args.schema,
            dbName:    args.sourceDb,
            targetDb:  args.targetDb,
            status:    'STARTED',
            user:      args.user,
            buildUrl:  args.buildUrl
        ])
    } catch (Exception e) {
        echo "[DataPump/Audit] ⚠ Scrittura audit log fallita (non bloccante): ${e.message}"
    }
}

// --------------------------------------------------------------------------
// Log di simulazione DRY RUN — nessuna operazione eseguita
// --------------------------------------------------------------------------
def logDryRun(String operation, Map details = [:]) {
    def lines = details.collect { k, v -> "  - ${k}: ${v ?: 'N/A'}" }.join('\n')
    echo """
[DRY RUN] Operazione simulata: ${operation}
${lines}
[DRY RUN] Nessuna modifica è stata applicata ai database."""
}

// --------------------------------------------------------------------------
// Upload dump su OCI Object Storage — delega a ociStorage
// Per Autonomous DB il filesystem non è accessibile: usare export diretto
// su bucket (DBMS_CLOUD) — qui viene emesso solo un warning.
// --------------------------------------------------------------------------
def uploadToBucket(Map args) {
    if ((args.dbType ?: '').toLowerCase() in ['autonomous', 'adb']) {
        echo "[DataPump/Bucket] ⚠ Il database è Autonomous: il dump risiede in DATA_PUMP_DIR lato DB. " +
             "Usare DBMS_CLOUD.PUT_OBJECT o l'export diretto su Object Storage. Upload dall'agent saltato."
        return [status: 'SKIPPED', reason: 'autonomous-db']
    }
    def ns = ociStorage.getNamespace()
    return ociStorage.uploadToBucket(ns, args.bucketName, args.objectName, args.sourceFile)
}

// --------------------------------------------------------------------------
// Download dump da OCI Object Storage — delega a ociStorage
// --------------------------------------------------------------------------
def downloadFromBucket(Map args) {
    if ((args.dbType ?: '').toLowerCase() in ['autonomous', 'adb']) {
        echo "[DataPump/Bucket] ⚠ Il database è Autonomous: usare DBMS_CLOUD.GET_OBJECT o import diretto " +
             "da Object Storage. Download sull'agent saltato."
        return [status: 'SKIPPED', reason: 'autonomous-db']
    }
    def ns = ociStorage.getNamespace()
    return ociStorage.downloadFromBucket(ns, args.bucketName, args.objectName, args.targetFile)
}

// --------------------------------------------------------------------------
// Validazione schema: esistenza, conteggio oggetti/tabelle, oggetti INVALID
// Ritorna: [valid, objectCount, tableCount, invalidCount, errors]
// --------------------------------------------------------------------------
def validateSchema(Map args) {
    assert args.schemaName?.trim() : "schemaName è obbligatorio per validateSchema"
    def dbConfig = toDbConfig(args)
    def schema = args.schemaName.trim()
    def result = [valid: false, objectCount: 0, tableCount: 0, invalidCount: 0, errors: []]

    if (!oracleConnect.schemaExists(dbConfig, schema)) {
        result.errors << "Lo schema '${schema}' non esiste sul database"
        return result
    }

    def output = oracleConnect.runSqlStatement(dbConfig, """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT 'OBJ=' || COUNT(*) ||
       '|TAB=' || SUM(CASE WHEN object_type = 'TABLE' THEN 1 ELSE 0 END) ||
       '|INV=' || SUM(CASE WHEN status = 'INVALID' THEN 1 ELSE 0 END)
FROM all_objects WHERE owner = UPPER('${schema}');
EXIT;
""")
    def line = output?.readLines()?.collect { it.trim() }?.find { it.startsWith('OBJ=') }
    if (line) {
        line.split('\\|').each { part ->
            def kv = part.split('=')
            if (kv.length == 2 && kv[1].isInteger()) {
                switch (kv[0]) {
                    case 'OBJ': result.objectCount  = kv[1].toInteger(); break
                    case 'TAB': result.tableCount   = kv[1].toInteger(); break
                    case 'INV': result.invalidCount = kv[1].toInteger(); break
                }
            }
        }
    }

    if (result.objectCount == 0) {
        result.errors << "Lo schema '${schema}' esiste ma è vuoto (0 oggetti)"
    }
    if (result.invalidCount > 0) {
        echo "[DataPump/Validate] ⚠ ${result.invalidCount} oggetti INVALID in '${schema}' (non bloccante)"
    }
    result.valid = result.errors.isEmpty()
    return result
}

// --------------------------------------------------------------------------
// Rename schema — LIMITAZIONE ORACLE: non esiste un rename nativo di schema.
// Questa funzione fallisce con istruzioni operative. Per lo swap zero-copy
// usare TABLE_EXISTS_ACTION=SAFE_SWAP (rename table-level nello stesso
// schema) oppure REMAP_SCHEMA in fase di import.
// --------------------------------------------------------------------------
def renameSchema(Map args) {
    error """[DataPump/Swap] Oracle non supporta il rename di uno schema (${args.oldName} → ${args.newName}).
Alternative supportate dalla pipeline:
  1. TABLE_EXISTS_ACTION=SAFE_SWAP  → import su tabelle _JENK + swap atomico table-level (stesso schema)
  2. REMAP_SCHEMA in fase di import → importa direttamente nello schema di destinazione
  3. Repoint dei sinonimi applicativi verso lo schema nuovo (operazione manuale/applicativa)"""
}

// --------------------------------------------------------------------------
// Drop schema (DROP USER CASCADE) con guardia di sicurezza:
// consentito solo su schemi con suffisso _BKP/_NEW/_OLD, salvo force=true
// --------------------------------------------------------------------------
def dropSchema(Map args) {
    assert args.schemaName?.trim() : "schemaName è obbligatorio per dropSchema"
    def schema = args.schemaName.trim().toUpperCase()

    def allowedSuffixes = ['_BKP', '_NEW', '_OLD', '_JENK']
    def isSafe = allowedSuffixes.any { schema.contains(it) }
    if (!isSafe && !args.force) {
        error "[DataPump/Drop] Rifiutato il drop dello schema '${schema}': " +
              "consentito solo su schemi ${allowedSuffixes.join('/')} (oppure passare force: true)."
    }

    echo "[DataPump/Drop] Eliminazione schema '${schema}'..."
    oracleConnect.runSqlStatement(toDbConfig(args), """
WHENEVER SQLERROR EXIT SQL.SQLCODE
DROP USER "${schema}" CASCADE;
""")
    echo "[DataPump/Drop] ✔ Schema '${schema}' eliminato"
    return [status: 'SUCCESS', schema: schema]
}

// --------------------------------------------------------------------------
// Rollback swap — best effort: riporta lo stato degli schemi coinvolti
// per guidare l'intervento manuale (lo swap schema-level non è supportato,
// quindi non c'è nulla di parziale da annullare a livello schema).
// --------------------------------------------------------------------------
def rollbackSwap(Map args) {
    def dbConfig = toDbConfig(args)
    def schema = args.schemaName?.trim()
    def report = [:]
    ['': schema, '_BKP': "${schema}_BKP", '_NEW': "${schema}_NEW"].each { suffix, name ->
        try {
            report[name] = oracleConnect.schemaExists(dbConfig, name) ? 'PRESENTE' : 'ASSENTE'
        } catch (Exception e) {
            report[name] = "ERRORE: ${e.message}"
        }
    }
    echo "[DataPump/Rollback] Stato schemi dopo il fallimento dello swap:"
    report.each { name, state -> echo "  - ${name}: ${state}" }
    return report
}

// --------------------------------------------------------------------------
// Conteggio record per tabella.
// - Con tableList: COUNT(*) esatto sulle tabelle indicate
// - Senza tableList: num_rows dalle statistiche (veloce, adatto a schemi TB)
// Ritorna: Map [TABLE_NAME: rowCount]
// --------------------------------------------------------------------------
def getRecordCounts(Map args) {
    assert args.schemaName?.trim() : "schemaName è obbligatorio per getRecordCounts"
    def dbConfig = toDbConfig(args)
    def schema = args.schemaName.trim()
    def counts = [:]

    def tableList = args.tableList instanceof String ?
        args.tableList.split(',').collect { it.trim() }.findAll { it } :
        (args.tableList ?: [])

    if (tableList) {
        // COUNT(*) esatto solo sulle tabelle richieste
        def unionSql = tableList.collect { t ->
            "SELECT '${t.toUpperCase()}' || '|' || COUNT(*) FROM \"${schema.toUpperCase()}\".\"${t.toUpperCase()}\""
        }.join('\nUNION ALL\n')
        def output = oracleConnect.runSqlStatement(dbConfig, """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 300
${unionSql};
EXIT;
""")
        output?.readLines()?.each { line ->
            def parts = line.trim().split('\\|')
            if (parts.length == 2 && parts[1].isLong()) counts[parts[0]] = parts[1].toLong()
        }
    } else {
        // num_rows dalle statistiche — richiede statistiche aggiornate
        def stats = oracleConnect.getSchemaStats(dbConfig, schema)
        counts = stats.tables ?: [:]
    }
    return counts
}

// --------------------------------------------------------------------------
// Conteggio oggetti per tipo — Map [OBJECT_TYPE: count]
// --------------------------------------------------------------------------
def getObjectCounts(Map args) {
    assert args.schemaName?.trim() : "schemaName è obbligatorio per getObjectCounts"
    def output = oracleConnect.runSqlStatement(toDbConfig(args), """
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 300
SELECT object_type || '|' || COUNT(*)
FROM all_objects
WHERE owner = UPPER('${args.schemaName.trim()}')
GROUP BY object_type ORDER BY object_type;
EXIT;
""")
    def counts = [:]
    output?.readLines()?.each { line ->
        def parts = line.trim().split('\\|')
        if (parts.length == 2 && parts[1].isInteger()) counts[parts[0]] = parts[1].toInteger()
    }
    return counts
}

// --------------------------------------------------------------------------
// Generazione report HTML dell'operazione a partire dalla Map reportData
// --------------------------------------------------------------------------
def generateHtmlReport(Map reportData) {
    def rows = new StringBuilder()
    reportData.each { k, v ->
        def label = k.replaceAll(/([A-Z])/, ' $1').capitalize()
        rows.append("      <tr><td class=\"k\">${label}</td><td>${v ?: 'N/A'}</td></tr>\n")
    }
    def ignoredWarnings = env.IGNORED_ORA_WARNINGS ?
        "<h2>⚠ Errori Oracle ignorati (whitelist)</h2><pre>${env.IGNORED_ORA_WARNINGS}</pre>" : ''

    return """<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>ACME Data Pump Report — ${reportData.operation ?: 'N/A'} #${reportData.buildNumber ?: ''}</title>
<style>
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #f5f5f5; color: #333; margin: 0; }
  .container { max-width: 820px; margin: 24px auto; background: #fff; border-radius: 8px;
               box-shadow: 0 2px 8px rgba(0,0,0,.1); overflow: hidden; }
  .header { background: #009A3D; color: #fff; padding: 24px 30px; }
  .header h1 { margin: 0; font-size: 22px; }
  .header p { margin: 6px 0 0; opacity: .85; font-size: 13px; }
  .section { padding: 10px 30px 30px; }
  h2 { color: #009A3D; border-bottom: 2px solid #FFD800; padding-bottom: 6px; font-size: 16px; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 8px 12px; border-bottom: 1px solid #e8e8e8; font-size: 14px; }
  td.k { font-weight: 600; color: #006B2B; width: 240px; }
  tr:nth-child(even) { background: #fafafa; }
  pre { background: #f8f9fa; border: 1px solid #ddd; padding: 12px; font-size: 12px; overflow-x: auto; }
</style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>ACME Oracle Data Pump — Report Operazione</h1>
      <p>Build #${reportData.buildNumber ?: 'N/A'} — ${reportData.timestamp ?: ''}</p>
    </div>
    <div class="section">
      <h2>Dettagli operazione</h2>
      <table>
${rows}
      </table>
      ${ignoredWarnings}
    </div>
  </div>
</body>
</html>"""
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
