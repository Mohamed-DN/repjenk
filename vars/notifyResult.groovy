#!/usr/bin/env groovy
// =============================================================================
// notifyResult.groovy — Libreria condivisa Jenkins per notifiche e reportistica
// ENI S.p.A. — Notifiche email, Slack e report HTML per operazioni Data Pump
// =============================================================================
// Report HTML con branding ENI (giallo #FDB813, verde #009639).
// Supporto email con allegati log, Slack con colori stato, audit trail.
// =============================================================================

// Colori brand ENI per il report HTML
private static final String ENI_YELLOW = '#FDB813'
private static final String ENI_GREEN  = '#009639'
private static final String ENI_DARK   = '#1D1D1B'
private static final String ENI_WHITE  = '#FFFFFF'
private static final String STATUS_RED = '#DC3545'

// --------------------------------------------------------------------------
// Invio notifica email con report operazione
// Utilizza il plugin Jenkins Email Extension (emailext)
// --------------------------------------------------------------------------
def sendEmail(String to, String subject, String body, boolean attachLog = true) {
    assert to?.trim() : "Il destinatario email non può essere vuoto"
    assert subject?.trim() : "L'oggetto email non può essere vuoto"

    echo "[Notify/Email] ➤ Invio email a: ${to}"
    echo "[Notify/Email] Oggetto: ${subject}"

    try {
        def attachments = ''
        if (attachLog) {
            // Allegato del log della build corrente, se disponibile
            attachments = '**/*.log'
        }

        emailext(
            to: to,
            subject: subject,
            body: body,
            mimeType: 'text/html',
            attachmentsPattern: attachments,
            // Utilizzo del template predefinito per fallback
            recipientProviders: [[$class: 'DevelopersRecipientProvider']],
            // Reply-to per il team DBA
            replyTo: 'dba-team@eni.com'
        )

        echo "[Notify/Email] ✔ Email inviata con successo a ${to}"
    } catch (Exception e) {
        // L'errore di notifica non deve bloccare la pipeline
        echo "[Notify/Email] ⚠ Errore invio email: ${e.message}"
        echo "[Notify/Email] L'errore di notifica non blocca la pipeline"
    }
}

// --------------------------------------------------------------------------
// Invio notifica Slack con colore basato sullo stato
// Utilizza il plugin Slack Notification
// --------------------------------------------------------------------------
def sendSlack(String channel, String message, String status = 'INFO') {
    assert channel?.trim() : "Il canale Slack non può essere vuoto"
    assert message?.trim() : "Il messaggio non può essere vuoto"

    echo "[Notify/Slack] ➤ Invio messaggio Slack a: ${channel}"

    // Mappatura stato → colore notifica Slack
    def colorMap = [
        'SUCCESS' : 'good',      // Verde
        'FAILURE' : 'danger',    // Rosso
        'WARNING' : 'warning',   // Arancione
        'INFO'    : '#439FE0',   // Blu informativo
        'STARTED' : ENI_YELLOW   // Giallo ENI per inizio operazione
    ]
    def color = colorMap[status.toUpperCase()] ?: '#439FE0'

    // Emoji per stato
    def emojiMap = [
        'SUCCESS' : '✅',
        'FAILURE' : '❌',
        'WARNING' : '⚠️',
        'INFO'    : 'ℹ️',
        'STARTED' : '🚀'
    ]
    def emoji = emojiMap[status.toUpperCase()] ?: 'ℹ️'

    def fullMessage = "${emoji} *ENI Data Pump* | ${message}"

    try {
        slackSend(
            channel: channel,
            color: color,
            message: fullMessage,
            teamDomain: 'eni-dba',
            // Token Slack dal Jenkins Credentials Store
            tokenCredentialId: 'slack-bot-token'
        )
        echo "[Notify/Slack] ✔ Messaggio Slack inviato"
    } catch (Exception e) {
        echo "[Notify/Slack] ⚠ Errore invio Slack: ${e.message}"
        echo "[Notify/Slack] Verificare che il plugin Slack sia configurato"
    }
}

// --------------------------------------------------------------------------
// Costruzione report HTML professionale con branding ENI
// Dettagli operazione, tempistiche, dimensioni, confronto record
// --------------------------------------------------------------------------
def buildReport(Map operationDetails) {
    assert operationDetails : "I dettagli operazione non possono essere null"

    echo "[Notify/Report] ➤ Generazione report HTML..."

    def operation  = operationDetails.operation ?: 'N/A'
    def schema     = operationDetails.schema ?: 'N/A'
    def dbName     = operationDetails.dbName ?: 'N/A'
    def status     = operationDetails.status ?: 'UNKNOWN'
    def durationMs = operationDetails.durationMs ?: 0
    def startTime  = operationDetails.startTime ?: 'N/A'
    def endTime    = operationDetails.endTime ?: 'N/A'
    def dumpFile   = operationDetails.dumpFilename ?: 'N/A'
    def fileSize   = operationDetails.fileSize ?: 'N/A'
    def buildUrl   = env.BUILD_URL ?: '#'
    def buildNum   = env.BUILD_NUMBER ?: 'N/A'
    def jobName    = env.JOB_NAME ?: 'DataPump Pipeline'

    // Colore della barra di stato in base al risultato
    def statusColor = (status == 'SUCCESS') ? ENI_GREEN : STATUS_RED
    def statusIcon  = (status == 'SUCCESS') ? '✔' : '✖'

    // Costruzione tabella di confronto record (pre/post import)
    def comparisonHtml = ''
    if (operationDetails.preStats && operationDetails.postStats) {
        comparisonHtml = buildComparisonTable(operationDetails.preStats, operationDetails.postStats)
    }

    // Tabella riassuntiva delle opzioni utilizzate
    def optionsSummary = ''
    if (operationDetails.options) {
        optionsSummary = buildOptionsTable(operationDetails.options)
    }

    // Template HTML del report con stile ENI
    def html = """
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ENI Data Pump Report — ${operation}</title>
    <style>
        /* Reset e stile base */
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0; padding: 0;
            background-color: #f5f5f5;
            color: ${ENI_DARK};
        }
        .container { max-width: 800px; margin: 20px auto; background: ${ENI_WHITE}; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }

        /* Header con branding ENI */
        .header {
            background: linear-gradient(135deg, ${ENI_GREEN} 0%, ${ENI_GREEN}dd 100%);
            color: ${ENI_WHITE};
            padding: 30px;
            text-align: center;
        }
        .header img { height: 40px; margin-bottom: 10px; }
        .header h1 { margin: 0; font-size: 24px; letter-spacing: 1px; }
        .header .subtitle { font-size: 14px; opacity: 0.9; margin-top: 5px; }

        /* Barra di stato */
        .status-bar {
            background-color: ${statusColor};
            color: ${ENI_WHITE};
            padding: 15px 30px;
            font-size: 18px;
            font-weight: bold;
            text-align: center;
        }

        /* Sezione dettagli */
        .section { padding: 20px 30px; }
        .section h2 {
            color: ${ENI_GREEN};
            border-bottom: 2px solid ${ENI_YELLOW};
            padding-bottom: 8px;
            margin-top: 25px;
            font-size: 18px;
        }

        /* Tabella dettagli */
        table.details {
            width: 100%;
            border-collapse: collapse;
            margin: 10px 0;
        }
        table.details th {
            background-color: ${ENI_GREEN};
            color: ${ENI_WHITE};
            padding: 10px 15px;
            text-align: left;
            font-weight: 600;
        }
        table.details td {
            padding: 10px 15px;
            border-bottom: 1px solid #e0e0e0;
        }
        table.details tr:nth-child(even) { background-color: #f9f9f9; }
        table.details tr:hover { background-color: #fff3cd; }

        /* Etichette chiave-valore */
        .kv-row { display: flex; padding: 8px 0; border-bottom: 1px solid #eee; }
        .kv-label { flex: 0 0 200px; font-weight: 600; color: ${ENI_GREEN}; }
        .kv-value { flex: 1; }

        /* Badge di stato */
        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: bold;
            text-transform: uppercase;
        }
        .badge-success { background: ${ENI_GREEN}; color: ${ENI_WHITE}; }
        .badge-failure { background: ${STATUS_RED}; color: ${ENI_WHITE}; }
        .badge-warning { background: ${ENI_YELLOW}; color: ${ENI_DARK}; }

        /* Footer */
        .footer {
            background-color: ${ENI_DARK};
            color: #aaa;
            padding: 15px 30px;
            text-align: center;
            font-size: 12px;
        }
        .footer a { color: ${ENI_YELLOW}; text-decoration: none; }
    </style>
</head>
<body>
    <div class="container">
        <!-- Intestazione con branding ENI -->
        <div class="header">
            <h1>🛢️ Oracle Data Pump Report</h1>
            <div class="subtitle">ENI S.p.A. — Automazione Database Oracle</div>
        </div>

        <!-- Barra di stato con risultato operazione -->
        <div class="status-bar">
            ${statusIcon} Operazione: ${operation} — Stato: ${status}
        </div>

        <div class="section">
            <!-- Dettagli principali dell'operazione -->
            <h2>📋 Dettagli Operazione</h2>
            <div class="kv-row"><span class="kv-label">Operazione</span><span class="kv-value">${operation}</span></div>
            <div class="kv-row"><span class="kv-label">Schema</span><span class="kv-value">${schema}</span></div>
            <div class="kv-row"><span class="kv-label">Database</span><span class="kv-value">${dbName}</span></div>
            <div class="kv-row"><span class="kv-label">File Dump</span><span class="kv-value">${dumpFile}</span></div>
            <div class="kv-row"><span class="kv-label">Dimensione File</span><span class="kv-value">${fileSize}</span></div>
            <div class="kv-row">
                <span class="kv-label">Stato</span>
                <span class="kv-value">
                    <span class="badge ${status == 'SUCCESS' ? 'badge-success' : 'badge-failure'}">${status}</span>
                </span>
            </div>

            <!-- Tempistiche -->
            <h2>⏱️ Tempistiche</h2>
            <div class="kv-row"><span class="kv-label">Inizio</span><span class="kv-value">${startTime}</span></div>
            <div class="kv-row"><span class="kv-label">Fine</span><span class="kv-value">${endTime}</span></div>
            <div class="kv-row"><span class="kv-label">Durata</span><span class="kv-value">${formatDuration(durationMs as long)}</span></div>

            <!-- Dettagli Jenkins -->
            <h2>🔧 Dettagli Build Jenkins</h2>
            <div class="kv-row"><span class="kv-label">Job</span><span class="kv-value">${jobName}</span></div>
            <div class="kv-row"><span class="kv-label">Build #</span><span class="kv-value">${buildNum}</span></div>
            <div class="kv-row"><span class="kv-label">Console Log</span><span class="kv-value"><a href="${buildUrl}console">Visualizza Log</a></span></div>

            ${comparisonHtml}
            ${optionsSummary}
        </div>

        <!-- Footer -->
        <div class="footer">
            Report generato automaticamente da <a href="${buildUrl}">Jenkins Pipeline</a> — ENI S.p.A. DBA Team<br>
            ${new Date().format('dd/MM/yyyy HH:mm:ss z')}
        </div>
    </div>
</body>
</html>
"""

    echo "[Notify/Report] ✔ Report HTML generato (${html.length()} caratteri)"
    return html
}

// --------------------------------------------------------------------------
// Formattazione durata da millisecondi a formato leggibile
// Es: 3661000 → "1h 1m 1s"
// --------------------------------------------------------------------------
def formatDuration(long durationMs) {
    if (durationMs <= 0) return "0s"

    def seconds = (int) ((durationMs / 1000) % 60)
    def minutes = (int) ((durationMs / (1000 * 60)) % 60)
    def hours   = (int) ((durationMs / (1000 * 60 * 60)) % 24)
    def days    = (int) (durationMs / (1000 * 60 * 60 * 24))

    def parts = []
    if (days > 0)    parts.add("${days}g")      // giorni
    if (hours > 0)   parts.add("${hours}h")     // ore
    if (minutes > 0) parts.add("${minutes}m")   // minuti
    parts.add("${seconds}s")                     // secondi (sempre mostrato)

    return parts.join(' ')
}

// --------------------------------------------------------------------------
// Registrazione dell'operazione nel file di audit
// Tracciabilità completa di tutte le operazioni Data Pump eseguite
// --------------------------------------------------------------------------
def auditLog(Map operationDetails) {
    assert operationDetails : "I dettagli operazione non possono essere null"

    echo "[Notify/Audit] ➤ Registrazione audit trail..."

    def timestamp = new Date().format('yyyy-MM-dd HH:mm:ss z')
    def operation = operationDetails.operation ?: 'N/A'
    def schema    = operationDetails.schema ?: 'N/A'
    def dbName    = operationDetails.dbName ?: 'N/A'
    def status    = operationDetails.status ?: 'UNKNOWN'
    def buildNum  = env.BUILD_NUMBER ?: 'N/A'
    def userId    = operationDetails.userId ?: env.BUILD_USER_ID ?: 'jenkins'
    def durationMs = operationDetails.durationMs ?: 0

    // Formato CSV per facile importazione in strumenti di analisi
    def auditEntry = [
        timestamp,
        operation,
        schema,
        dbName,
        status,
        formatDuration(durationMs as long),
        buildNum,
        userId,
        operationDetails.dumpFilename ?: '',
        operationDetails.fileSize ?: '',
        operationDetails.error ?: ''
    ].join('|')

    // Scrittura su file di audit nella workspace Jenkins
    def auditDir = "${env.WORKSPACE}/audit"
    def auditFile = "${auditDir}/datapump_audit.log"

    try {
        sh(script: "mkdir -p '${auditDir}'", returnStatus: true)

        // Aggiunta header se il file non esiste
        def headerCheck = sh(script: "test -f '${auditFile}' && echo 'EXISTS' || echo 'NEW'", returnStdout: true).trim()
        if (headerCheck == 'NEW') {
            def header = 'TIMESTAMP|OPERATION|SCHEMA|DATABASE|STATUS|DURATION|BUILD|USER|DUMP_FILE|FILE_SIZE|ERROR'
            sh(script: "echo '${header}' > '${auditFile}'")
        }

        // Append della voce di audit
        sh(script: "echo '${auditEntry}' >> '${auditFile}'")
        echo "[Notify/Audit] ✔ Voce di audit registrata: ${operation} su ${schema}"

        // Archiviazione del file di audit come artefatto Jenkins
        archiveArtifacts(artifacts: 'audit/datapump_audit.log', allowEmptyArchive: true, fingerprint: true)
    } catch (Exception e) {
        echo "[Notify/Audit] ⚠ Errore registrazione audit: ${e.message}"
        // L'errore di audit non deve bloccare la pipeline
    }
}

// --------------------------------------------------------------------------
// Costruzione tabella riassuntiva per email e Slack
// Formato compatto per visualizzazione rapida nei client di posta
// --------------------------------------------------------------------------
def buildSummaryTable(Map details) {
    assert details : "I dettagli non possono essere null"

    echo "[Notify/Summary] ➤ Costruzione tabella riassuntiva..."

    def status    = details.status ?: 'UNKNOWN'
    def statusEmoji = (status == 'SUCCESS') ? '✅' : '❌'

    def summary = """
╔══════════════════════════════════════════════════════════════╗
║  ENI Oracle Data Pump — Riepilogo Operazione               ║
╠══════════════════════════════════════════════════════════════╣
║  Stato:        ${statusEmoji} ${status.padRight(44)}║
║  Operazione:   ${(details.operation ?: 'N/A').padRight(44)}║
║  Schema:       ${(details.schema ?: 'N/A').padRight(44)}║
║  Database:     ${(details.dbName ?: 'N/A').padRight(44)}║
║  Durata:       ${formatDuration((details.durationMs ?: 0) as long).padRight(44)}║
║  File Dump:    ${(details.dumpFilename ?: 'N/A').padRight(44)}║
║  Dimensione:   ${(details.fileSize?.toString() ?: 'N/A').padRight(44)}║
║  Build:        #${(env.BUILD_NUMBER ?: 'N/A').padRight(43)}║
╚══════════════════════════════════════════════════════════════╝
"""

    // Aggiunta sezione confronto record se disponibile
    if (details.preStats && details.postStats) {
        summary += "\n📊 Confronto Record (Pre/Post):\n"
        summary += String.format("%-30s %15s %15s %10s\n", 'Tabella', 'Pre-Import', 'Post-Import', 'Delta')
        summary += '-' * 72 + '\n'

        def allTables = (details.preStats.tables?.keySet() ?: []) + (details.postStats.tables?.keySet() ?: [])
        allTables.unique().sort().each { table ->
            def pre  = details.preStats.tables?.get(table) ?: 0
            def post = details.postStats.tables?.get(table) ?: 0
            def delta = post - pre
            def deltaStr = delta >= 0 ? "+${delta}" : "${delta}"
            summary += String.format("%-30s %,15d %,15d %10s\n", table, pre, post, deltaStr)
        }
    }

    echo "[Notify/Summary] ✔ Tabella riassuntiva generata"
    return summary
}

// ==========================================================================
// FUNZIONI INTERNE DI UTILITÀ
// ==========================================================================

// --------------------------------------------------------------------------
// Costruzione tabella HTML di confronto record pre/post operazione
// Evidenzia le differenze tra i conteggi righe prima e dopo l'import
// --------------------------------------------------------------------------
private String buildComparisonTable(Map preStats, Map postStats) {
    if (!preStats?.tables || !postStats?.tables) return ''

    def html = """
            <h2>📊 Confronto Record Pre/Post Import</h2>
            <table class="details">
                <tr>
                    <th>Tabella</th>
                    <th style="text-align:right">Pre-Import</th>
                    <th style="text-align:right">Post-Import</th>
                    <th style="text-align:right">Delta</th>
                    <th style="text-align:center">Stato</th>
                </tr>
"""
    def allTables = ((preStats.tables?.keySet() ?: []) + (postStats.tables?.keySet() ?: [])).unique().sort()
    allTables.each { table ->
        def pre  = preStats.tables?.get(table) ?: 0
        def post = postStats.tables?.get(table) ?: 0
        def delta = post - pre
        def deltaColor = delta > 0 ? ENI_GREEN : (delta < 0 ? STATUS_RED : ENI_DARK)
        def statusBadge = delta == 0 ? '<span class="badge badge-success">OK</span>' :
                          (delta > 0 ? '<span class="badge badge-warning">+</span>' :
                                       '<span class="badge badge-failure">-</span>')

        html += """
                <tr>
                    <td>${table}</td>
                    <td style="text-align:right">${String.format('%,d', pre)}</td>
                    <td style="text-align:right">${String.format('%,d', post)}</td>
                    <td style="text-align:right;color:${deltaColor}">${delta >= 0 ? '+' : ''}${String.format('%,d', delta)}</td>
                    <td style="text-align:center">${statusBadge}</td>
                </tr>
"""
    }
    html += "            </table>\n"
    return html
}

// --------------------------------------------------------------------------
// Costruzione tabella HTML delle opzioni utilizzate per l'operazione
// --------------------------------------------------------------------------
private String buildOptionsTable(Map options) {
    if (!options) return ''

    def html = """
            <h2>⚙️ Opzioni Utilizzate</h2>
            <table class="details">
                <tr><th>Parametro</th><th>Valore</th></tr>
"""
    options.each { key, value ->
        if (value != null) {
            def displayValue = (value instanceof List) ? value.join(', ') :
                               (value instanceof Map) ? value.collect { k, v -> "${k}→${v}" }.join(', ') :
                               value.toString()
            html += "                <tr><td>${key}</td><td>${displayValue}</td></tr>\n"
        }
    }
    html += "            </table>\n"
    return html
}
