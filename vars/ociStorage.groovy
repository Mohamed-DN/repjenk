#!/usr/bin/env groovy
// =============================================================================
// ociStorage.groovy — Libreria condivisa Jenkins per OCI Object Storage
// M-DN. — Gestione Object Storage per dump Oracle Data Pump
// =============================================================================
// Operazioni: upload, download, list, delete, PAR, pulizia dump obsoleti.
// Tutte le operazioni utilizzano la CLI OCI (oci os object ...).
// =============================================================================

import groovy.json.JsonSlurper

// Numero massimo di tentativi per operazioni con retry automatico
private static final int MAX_RETRIES = 3
// Tempo di attesa base tra un tentativo e l'altro (millisecondi)
private static final int RETRY_DELAY_MS = 5000

// --------------------------------------------------------------------------
// Upload di un file locale su un bucket OCI Object Storage
// Supporta multipart automatico per file di grandi dimensioni
// --------------------------------------------------------------------------
def uploadToBucket(String namespace, String bucketName, String objectName, String localFilePath) {
    assert namespace?.trim() : "Il namespace OCI non può essere vuoto"
    assert bucketName?.trim() : "Il nome del bucket non può essere vuoto"
    assert objectName?.trim() : "Il nome dell'oggetto non può essere vuoto"
    assert localFilePath?.trim() : "Il percorso del file locale non può essere vuoto"

    echo "[OCI/Storage] ➤ Upload: ${localFilePath} → oci://${bucketName}/${objectName}"

    // Verifica che il file locale esista prima dell'upload
    def fileExists = sh(script: "test -f '${localFilePath}' && echo 'OK' || echo 'MISSING'", returnStdout: true).trim()
    if (fileExists != 'OK') {
        error "[OCI/Storage] ✖ File locale non trovato: ${localFilePath}"
    }

    // Recupero dimensione file per logging
    def fileSize = sh(script: "stat -c%s '${localFilePath}' 2>/dev/null || stat -f%z '${localFilePath}' 2>/dev/null || echo '0'", returnStdout: true).trim()
    echo "[OCI/Storage] Dimensione file: ${formatBytes(fileSize.toLong())} (${fileSize} bytes)"

    def cmd = """oci os object put \\
        --namespace-name '${namespace}' \\
        --bucket-name '${bucketName}' \\
        --name '${objectName}' \\
        --file '${localFilePath}' \\
        --part-size 128 \\
        --parallel-upload-count 3 \\
        --force"""

    def result = executeWithRetry(cmd, "upload ${objectName}")

    // Verifica post-upload: controllo che l'oggetto sia presente nel bucket
    if (objectExists(namespace, bucketName, objectName)) {
        echo "[OCI/Storage] ✔ Upload completato: ${objectName}"
    } else {
        error "[OCI/Storage] ✖ Verifica post-upload fallita: l'oggetto '${objectName}' non risulta nel bucket"
    }

    return [status: 'SUCCESS', objectName: objectName, fileSize: fileSize]
}

// --------------------------------------------------------------------------
// Download di un file dal bucket OCI Object Storage al filesystem locale
// --------------------------------------------------------------------------
def downloadFromBucket(String namespace, String bucketName, String objectName, String localFilePath) {
    assert namespace?.trim() : "Il namespace OCI non può essere vuoto"
    assert bucketName?.trim() : "Il nome del bucket non può essere vuoto"
    assert objectName?.trim() : "Il nome dell'oggetto non può essere vuoto"
    assert localFilePath?.trim() : "Il percorso locale di destinazione non può essere vuoto"

    echo "[OCI/Storage] ➤ Download: oci://${bucketName}/${objectName} → ${localFilePath}"

    // Verifica che l'oggetto sorgente esista nel bucket
    if (!objectExists(namespace, bucketName, objectName)) {
        error "[OCI/Storage] ✖ Oggetto non trovato nel bucket: ${objectName}"
    }

    // Creazione directory di destinazione se non esiste
    def targetDir = localFilePath.substring(0, localFilePath.lastIndexOf('/'))
    sh(script: "mkdir -p '${targetDir}'", returnStatus: true)

    def cmd = """oci os object get \\
        --namespace-name '${namespace}' \\
        --bucket-name '${bucketName}' \\
        --name '${objectName}' \\
        --file '${localFilePath}'"""

    def result = executeWithRetry(cmd, "download ${objectName}")

    // Verifica che il file sia stato scaricato correttamente
    def downloadedOk = sh(script: "test -f '${localFilePath}' && echo 'OK' || echo 'MISSING'", returnStdout: true).trim()
    if (downloadedOk != 'OK') {
        error "[OCI/Storage] ✖ File non trovato dopo download: ${localFilePath}"
    }

    def fileSize = sh(script: "stat -c%s '${localFilePath}' 2>/dev/null || stat -f%z '${localFilePath}' 2>/dev/null || echo '0'", returnStdout: true).trim()
    echo "[OCI/Storage] ✔ Download completato: ${localFilePath} (${formatBytes(fileSize.toLong())})"

    return [status: 'SUCCESS', localFilePath: localFilePath, fileSize: fileSize]
}

// --------------------------------------------------------------------------
// Elenco oggetti nel bucket con filtro opzionale per prefisso
// Restituisce lista di mappe con nome, dimensione e data modifica
// --------------------------------------------------------------------------
def listObjects(String namespace, String bucketName, String prefix = '') {
    assert namespace?.trim() : "Il namespace OCI non può essere vuoto"
    assert bucketName?.trim() : "Il nome del bucket non può essere vuoto"

    echo "[OCI/Storage] ➤ Elenco oggetti in oci://${bucketName}/${prefix ?: '*'}"

    def cmd = "oci os object list --namespace-name '${namespace}' --bucket-name '${bucketName}' --output json --all"
    if (prefix) {
        cmd += " --prefix '${prefix}'"
    }

    def output = sh(script: cmd, returnStdout: true).trim()
    def jsonSlurper = new JsonSlurper()
    def parsed = jsonSlurper.parseText(output)
    def objects = parsed?.data ?: []

    echo "[OCI/Storage] Trovati ${objects.size()} oggetti${prefix ? " con prefisso '${prefix}'" : ''}"

    // Costruzione lista risultati con informazioni rilevanti
    def result = objects.collect { obj ->
        [
            name        : obj.name,
            size        : obj.size,
            timeCreated : obj.'time-created',
            md5         : obj.md5,
            etag        : obj.etag
        ]
    }

    return result
}

// --------------------------------------------------------------------------
// Eliminazione di un singolo oggetto dal bucket
// --------------------------------------------------------------------------
def deleteObject(String namespace, String bucketName, String objectName) {
    assert namespace?.trim() && bucketName?.trim() && objectName?.trim()

    echo "[OCI/Storage] ➤ Eliminazione oggetto: oci://${bucketName}/${objectName}"

    // Verifica esistenza prima di eliminare
    if (!objectExists(namespace, bucketName, objectName)) {
        echo "[OCI/Storage] ⚠ Oggetto già assente, nulla da eliminare: ${objectName}"
        return [status: 'NOT_FOUND']
    }

    def cmd = """oci os object delete \\
        --namespace-name '${namespace}' \\
        --bucket-name '${bucketName}' \\
        --name '${objectName}' \\
        --force"""

    executeWithRetry(cmd, "eliminazione ${objectName}")
    echo "[OCI/Storage] ✔ Oggetto eliminato: ${objectName}"

    return [status: 'DELETED', objectName: objectName]
}

// --------------------------------------------------------------------------
// Recupero dimensione di un oggetto in bytes
// --------------------------------------------------------------------------
def getObjectSize(String namespace, String bucketName, String objectName) {
    assert namespace?.trim() && bucketName?.trim() && objectName?.trim()

    echo "[OCI/Storage] Recupero dimensione: ${objectName}"

    def cmd = "oci os object head --namespace-name '${namespace}' --bucket-name '${bucketName}' --name '${objectName}' --output json"
    def output = ''
    try {
        output = sh(script: cmd, returnStdout: true).trim()
    } catch (Exception e) {
        echo "[OCI/Storage] ⚠ Impossibile recuperare dimensione: ${e.message}"
        return -1
    }

    def jsonSlurper = new JsonSlurper()
    def metadata = jsonSlurper.parseText(output)
    def sizeBytes = metadata?.'content-length' ?: metadata?.data?.'content-length' ?: 0

    echo "[OCI/Storage] Dimensione di '${objectName}': ${formatBytes(sizeBytes as long)} (${sizeBytes} bytes)"
    return sizeBytes as long
}

// --------------------------------------------------------------------------
// Verifica esistenza di un oggetto nel bucket
// Restituisce true/false senza generare errori
// --------------------------------------------------------------------------
def objectExists(String namespace, String bucketName, String objectName) {
    assert namespace?.trim() && bucketName?.trim() && objectName?.trim()

    def cmd = "oci os object head --namespace-name '${namespace}' --bucket-name '${bucketName}' --name '${objectName}'"
    def exitCode = sh(script: cmd, returnStatus: true)

    def exists = (exitCode == 0)
    echo "[OCI/Storage] Oggetto '${objectName}' ${exists ? 'presente' : 'non trovato'} nel bucket '${bucketName}'"
    return exists
}

// --------------------------------------------------------------------------
// Creazione Pre-Authenticated Request (PAR) per accesso temporaneo a un oggetto
// Utile per condividere link di download senza credenziali OCI
// --------------------------------------------------------------------------
def createPAR(String namespace, String bucketName, String objectName, int expiryHours = 24) {
    assert namespace?.trim() && bucketName?.trim() && objectName?.trim()
    assert expiryHours > 0 : "Le ore di scadenza devono essere maggiori di zero"

    echo "[OCI/Storage] ➤ Creazione PAR per '${objectName}' (scadenza: ${expiryHours}h)"

    // Calcolo data di scadenza in formato ISO 8601
    def expiryDate = sh(script: "date -u -d '+${expiryHours} hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+${expiryHours}H '+%Y-%m-%dT%H:%M:%SZ'", returnStdout: true).trim()

    def parName = "par-${objectName.replaceAll('[^a-zA-Z0-9]', '-')}-${System.currentTimeMillis()}"

    def cmd = """oci os preauth-request create \\
        --namespace-name '${namespace}' \\
        --bucket-name '${bucketName}' \\
        --name '${parName}' \\
        --access-type 'ObjectRead' \\
        --time-expires '${expiryDate}' \\
        --object-name '${objectName}' \\
        --output json"""

    def output = sh(script: cmd, returnStdout: true).trim()
    def jsonSlurper = new JsonSlurper()
    def parData = jsonSlurper.parseText(output)

    def accessUri = parData?.data?.'access-uri' ?: parData?.'access-uri'
    def parId = parData?.data?.id ?: parData?.id

    if (!accessUri) {
        error "[OCI/Storage] ✖ Creazione PAR fallita: access-uri non restituito"
    }

    // Costruzione URL completo per il download
    def region = sh(script: "oci iam region-subscription list --output json 2>/dev/null | grep -o '\"region-name\": \"[^\"]*\"' | head -1 | cut -d'\"' -f4 || echo 'eu-milan-1'", returnStdout: true).trim()
    def fullUrl = "https://objectstorage.${region}.oraclecloud.com${accessUri}"

    echo "[OCI/Storage] ✔ PAR creato (scadenza: ${expiryDate})"
    echo "[OCI/Storage] URL: ${fullUrl}"

    return [status: 'SUCCESS', parId: parId, accessUri: accessUri, fullUrl: fullUrl, expires: expiryDate]
}

// --------------------------------------------------------------------------
// Recupero del namespace OCI corrente
// Il namespace è univoco per ogni tenancy Oracle Cloud
// --------------------------------------------------------------------------
def getNamespace() {
    echo "[OCI/Storage] Recupero namespace OCI..."

    def namespace = sh(script: "oci os ns get --output json | grep -o '\"data\": \"[^\"]*\"' | cut -d'\"' -f4", returnStdout: true).trim()

    if (!namespace) {
        // Tentativo alternativo con parsing JSON completo
        def output = sh(script: "oci os ns get --output json", returnStdout: true).trim()
        def jsonSlurper = new JsonSlurper()
        def parsed = jsonSlurper.parseText(output)
        namespace = parsed?.data
    }

    if (!namespace) {
        error "[OCI/Storage] ✖ Impossibile recuperare il namespace OCI. Verificare la configurazione CLI."
    }

    echo "[OCI/Storage] Namespace OCI: ${namespace}"
    return namespace
}

// --------------------------------------------------------------------------
// Pulizia automatica dei dump obsoleti in base alla retention policy
// Elimina oggetti più vecchi di retentionDays con il prefisso specificato
// --------------------------------------------------------------------------
def cleanupOldDumps(String namespace, String bucketName, String prefix, int retentionDays = 30) {
    assert retentionDays > 0 : "I giorni di retention devono essere maggiori di zero"

    echo "[OCI/Storage] ➤ Pulizia dump obsoleti: bucket='${bucketName}', prefisso='${prefix}', retention=${retentionDays} giorni"

    // Elenco di tutti gli oggetti con il prefisso specificato
    def objects = listObjects(namespace, bucketName, prefix)

    if (!objects || objects.isEmpty()) {
        echo "[OCI/Storage] Nessun oggetto trovato con prefisso '${prefix}', nulla da pulire"
        return [deleted: 0, retained: 0]
    }

    // Calcolo soglia temporale per la retention
    def cutoffDate = new Date() - retentionDays
    def deletedCount = 0
    def retainedCount = 0
    def freedBytes = 0L

    echo "[OCI/Storage] Analisi di ${objects.size()} oggetti (soglia: ${cutoffDate.format('yyyy-MM-dd HH:mm:ss')})"

    objects.each { obj ->
        try {
            // Parsing data di creazione dell'oggetto
            def createdDate = null
            if (obj.timeCreated) {
                // Formato ISO 8601 restituito dalla CLI OCI
                createdDate = Date.parse("yyyy-MM-dd'T'HH:mm:ss", obj.timeCreated.substring(0, 19))
            }

            if (createdDate && createdDate.before(cutoffDate)) {
                // Oggetto più vecchio della soglia: eliminazione
                echo "[OCI/Storage] Eliminazione dump obsoleto: ${obj.name} (creato: ${obj.timeCreated})"
                deleteObject(namespace, bucketName, obj.name)
                deletedCount++
                freedBytes += (obj.size ?: 0) as long
            } else {
                retainedCount++
            }
        } catch (Exception e) {
            echo "[OCI/Storage] ⚠ Errore durante pulizia di '${obj.name}': ${e.message}"
            // Continua con il prossimo oggetto senza bloccare il ciclo
        }
    }

    echo "[OCI/Storage] ✔ Pulizia completata: ${deletedCount} eliminati, ${retainedCount} mantenuti, ${formatBytes(freedBytes)} liberati"
    return [deleted: deletedCount, retained: retainedCount, freedBytes: freedBytes]
}

// ==========================================================================
// FUNZIONI INTERNE DI UTILITÀ
// ==========================================================================

// --------------------------------------------------------------------------
// Esecuzione comando con logica di retry automatico
// Ritenta fino a MAX_RETRIES volte con backoff esponenziale
// --------------------------------------------------------------------------
private def executeWithRetry(String command, String operationDesc) {
    def attempt = 0
    def lastError = null

    while (attempt < MAX_RETRIES) {
        attempt++
        try {
            echo "[OCI/Storage] Tentativo ${attempt}/${MAX_RETRIES} per ${operationDesc}..."
            def output = sh(script: command, returnStdout: true).trim()
            return output
        } catch (Exception e) {
            lastError = e
            echo "[OCI/Storage] ⚠ Tentativo ${attempt} fallito: ${e.message}"

            if (attempt < MAX_RETRIES) {
                // Backoff esponenziale: 5s, 10s, 20s...
                def waitMs = RETRY_DELAY_MS * Math.pow(2, attempt - 1) as int
                echo "[OCI/Storage] Attesa di ${waitMs / 1000}s prima del prossimo tentativo..."
                sleep(waitMs / 1000)
            }
        }
    }

    error "[OCI/Storage] ✖ Operazione '${operationDesc}' fallita dopo ${MAX_RETRIES} tentativi. Ultimo errore: ${lastError?.message}"
}

// --------------------------------------------------------------------------
// Formattazione dimensione in bytes in formato leggibile (KB, MB, GB)
// --------------------------------------------------------------------------
@NonCPS
private String formatBytes(long bytes) {
    if (bytes <= 0) return "0 B"
    def units = ['B', 'KB', 'MB', 'GB', 'TB']
    def digitGroups = (int) (Math.log10(bytes) / Math.log10(1024))
    digitGroups = Math.min(digitGroups, units.size() - 1)
    return String.format("%.2f %s", bytes / Math.pow(1024, digitGroups), units[digitGroups])
}
