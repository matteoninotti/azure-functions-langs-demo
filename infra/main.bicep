// Infrastruttura della demo: risorse condivise + un worker per linguaggio.
//
// Deploy a scope RESOURCE GROUP, non subscription: rg-torinodotnet-demo
// esiste gia' ed e' anche il meccanismo di teardown del progetto ("cancella
// il resource group"). Il Bicep ci si appoggia invece di ricrearlo.
//
//   az deployment group create \
//     --resource-group rg-torinodotnet-demo \
//     --template-file infra/main.bicep \
//     --parameters alertEmail=<indirizzo>

targetScope = 'resourceGroup'

// ⚠️ QUESTA E' LA FONTE NOMINALE, NON L'UNICA COPIA.
// Il prefisso e il nome del resource group sono cablati anche in cinque posti
// fuori dal Bicep, e cambiarli qui non rompe nessuno di quei cinque: le risorse
// vengono create col nome nuovo e tutto il resto continua a parlare col vecchio,
// fallendo con 404 e "resource not found" invece che con un errore di deploy.
// Se questo valore cambia, vanno aggiornati tutti:
//
//   1. frontend/app.js            — gli host dei tre backend in BACKENDS
//   2. load/scripts/resize.js     — il default di HOST
//   3. load/scripts/wait-for-zero.sh — i default di RESOURCE_GROUP e APP_NAME
//   4. scripts/deploy-frontend.sh — il default del resource group
//   5. .github/workflows/deploy.yml — env.RESOURCE_GROUP e il nome della app
//
// `git grep torinodotnet` li elenca tutti.
@description('Prefisso comune a tutte le risorse. Cablato anche in cinque punti fuori dal Bicep: vedi il commento sopra.')
param namePrefix string = 'torinodotnet'

@description('Regione. Deve supportare Flex Consumption: az functionapp list-flexconsumption-locations')
param location string = 'italynorth'

// I worker stanno nel default e non in un parametro passato di volta in volta:
// ogni deploy riafferma cosi' TUTTI i piani e TUTTE le app gia' costruite, e
// con loro la concorrenza a 1 (D39). Passarli a mano significherebbe riaffermare
// solo quelli che ci si ricorda di elencare — e un'app tornata al default di 16
// non fallisce rumorosamente, falsifica i numeri in silenzio (D22).
// Conseguenza da conoscere: un deploy del Bicep scrive anche sulle app che non
// stai cambiando, quindi non va lanciato durante un run di misura.
@description('Linguaggi da istanziare. Tutti e tre presenti: Python e .NET da Fase 2 e 4, Go aggiunto in Fase 5 (D85) e deployato in D87.')
param workers array = [
  {
    language: 'python'
    runtimeName: 'python'
    runtimeVersion: '3.12'
  }
  {
    // Go e' in public preview e NON compare nella tabella "Supported language
    // stack versions" della pagina Flex; il valore ARM pero' esiste ed e'
    // esposto da `az functionapp list-flexconsumption-runtimes --location
    // italynorth --runtime go` in sku.functionAppConfigProperties.runtime:
    // {name: 'go', version: '1.0'}. Chiude il residuo di D39, che temeva
    // servisse 'custom': non serve. La '1.0' e' la versione dello stack del
    // worker, non del linguaggio Go, che resta quella del compilatore usato in
    // CI (D31).
    language: 'go'
    runtimeName: 'go'
    runtimeVersion: '1.0'
  }
  {
    // ⚠️ '10.0', NON '10'. Il valore giusto e' quello che
    // `az functionapp list-flexconsumption-runtimes --location italynorth
    // --runtime dotnet-isolated` espone in
    // sku.functionAppConfigProperties.runtime.version, non la colonna
    // "Version" che stampa `-o table`: per dotnet-isolated le due differiscono
    // ('10.0' contro '10'), per python coincidono. ARM accetta '10' senza
    // protestare e lo rilegge identico, ma l'host non parte e non logga nulla
    // (D82).
    language: 'dotnet'
    runtimeName: 'dotnet-isolated'
    runtimeVersion: '10.0'
  }
]

// --- Parametri dell'esperimento ---------------------------------------------
// Non sono default ragionevoli: sono vincoli. Cambiarli invalida il confronto
// tra i tre linguaggi, quindi stanno scritti espliciti invece che ereditati.

@description('Regione della Static Web App. NON puo\' essere Italy North: il tipo di risorsa non esiste li\'.')
@allowed([
  'eastus2'
  'centralus'
  'westus2'
  'eastasia'
  // 'westeurope' e' un valore legittimo del tipo di risorsa ma su questa
  // sottoscrizione viene rifiutato in fase di deploy: "The selected region is
  // currently not accepting new customers". Resta fuori dall'elenco perche' un
  // @allowed che accetta un valore che fallisce sempre e' peggio che inutile.
])
param frontendLocation string = 'eastus2'

@description('Origini extra ammesse dal CORS dei worker, oltre alla Static Web App. Il default copre il dev server locale.')
param extraAllowedOrigins array = [
  'http://localhost:4280'
]

@description('2048 MB = 1 vCPU intera. Scendere a 512 non fa risparmiare su workload CPU-bound.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@description('Una richiesta per istanza: il parallelismo dev\'essere orizzontale, non interno.')
param perInstanceConcurrency int = 1

// Con concorrenza a 1 ogni istanza serve una richiesta alla volta, quindi
// questo numero E' il tetto delle richieste in volo, ed e' il tetto di quanti
// cold start simultanei la Metrica 3 puo' forzare. A 2.048 MB un'istanza vale
// 1 core, quindi 200 istanze = 200 core sui 250 della quota regionale (D42):
// i 50 di margine servono a impedire che un burst mal dimensionato saturi la
// quota della regione nel mezzo di un run (D46).
@description('Tetto di scale-out per il burst della Metrica 3. 200 su 250 core di quota, con margine.')
// Il minimo della piattaforma e' 1 ("the lowest maximum instance count value is
// 1", [event-driven scaling](https://learn.microsoft.com/en-us/azure/azure-functions/event-driven-scaling#limit-scale-out)).
// 40 e' un pavimento del template, non della piattaforma: sotto quel valore la
// Metrica 3 non misurerebbe lo scale-out. Il tetto basso fuori dalle finestre di
// misura si imposta da CLI, non da qui (load/README.md, "Protocollo di ogni run").
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 200

// UN CONTAINER PER WORKER, non uno condiviso. Su Flex il pacchetto di deploy
// e' un unico blob `released-package.zip` per container: due app che puntano
// allo stesso container si sovrascrivono il pacchetto a vicenda, e la seconda
// a deployare lascia la prima senza codice. Il sintomo non e' un errore di
// deploy — e' l'app precedente che risponde 404 su ogni route (D78).
var deploymentContainerPrefix = 'deployment-packages'

// Container privato da cui la pipeline preleva le immagini di test prima del
// build. E' la risposta al "come arrivano in CI" (D40): la pipeline si
// autentica gia' su Azure via OIDC, quindi legge da qui senza nessun secret
// aggiuntivo, e i file non passano mai dal repo.
var testImagesContainerName = 'test-images'

// --- Risorse condivise ------------------------------------------------------
// Uno storage e una coppia Log Analytics/App Insights per tutti e tre i
// worker. Il vincolo "una app per piano" riguarda il piano, non queste:
// condividerle tiene il confronto piu' pulito, perche' la telemetria dei tre
// linguaggi finisce nello stesso posto e si interroga con una query sola.

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Massimo 24 caratteri, solo minuscole e cifre. uniqueString ne produce 13
  // e va tenuto intero (e' cio' che garantisce l'unicita' globale): a essere
  // troncato e' il prefisso, non lui. 2 + 9 + 13 = 24 esatti.
  name: 'st${take(namePrefix, 9)}${uniqueString(resourceGroup().id)}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for w in workers: {
    parent: blobService
    name: '${deploymentContainerPrefix}-${w.language}'
  }
]

resource testImagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: testImagesContainerName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    // Il sampling dell'host e' gia' spento in host.json. Qui si spegne anche
    // quello lato ingestion: un p95 calcolato su un campione non e' un p95.
    SamplingPercentage: 100
  }
}

// --- Un worker per linguaggio -----------------------------------------------

// La Static Web App NON sta in Italy North insieme ai worker, e non e' una
// scelta: il tipo di risorsa e' offerto solo in Central US, East US 2, West
// US 2, West Europe e East Asia. La piu' vicina sarebbe West Europe, che pero'
// su questa sottoscrizione rifiuta nuovi deploy; resta East US 2.
//
// Non tocca le misure — il frontend non e' nel percorso misurato, che va da k6
// alla function e da li' ad Application Insights — ma va dichiarato, perche'
// chi guarda la demo dal vivo vede una latenza che comprende un giro in piu'
// fuori dall'Italia.
resource frontend 'Microsoft.Web/staticSites@2024-04-01' = {
  name: '${namePrefix}-frontend'
  location: frontendLocation
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    // Nessun repositoryUrl: collegarlo a GitHub farebbe generare a Azure un
    // workflow che deploya a ogni push. Nel resto del progetto il deploy e'
    // workflow_dispatch per non far partire niente da solo (D44), e il
    // frontend non fa eccezione: si pubblica con ./scripts/deploy-frontend.sh.
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
  }
}

module worker 'worker.bicep' = [
  for w in workers: {
    name: 'worker-${w.language}'
    params: {
      language: w.language
      runtimeName: w.runtimeName
      runtimeVersion: w.runtimeVersion
      location: location
      namePrefix: namePrefix
      storageAccountName: storage.name
      deploymentContainerName: '${deploymentContainerPrefix}-${w.language}'
      applicationInsightsConnectionString: applicationInsights.properties.ConnectionString
      instanceMemoryMB: instanceMemoryMB
      perInstanceConcurrency: perInstanceConcurrency
      maximumInstanceCount: maximumInstanceCount
      // L'origine della SWA si legge dalla risorsa qui sopra invece di essere
      // passata a mano: ARM ordina da solo le due creazioni, e il CORS non puo'
      // restare disallineato da un hostname cambiato.
      allowedOrigins: union(['https://${frontend.properties.defaultHostname}'], extraAllowedOrigins)
    }
    dependsOn: [
      deploymentContainers
    ]
  }
]

// --- Protezione dai consumi -------------------------------------------------
// Un action group e due regole per app sui GB-s fatturati, piu' un lock contro
// la cancellazione del resource group (D113, D116, D119). Le regole avvisano,
// non fermano: la protezione che limita davvero il consumo e' il tetto di
// istanze a 5 fuori dalle finestre di misura, impostato da CLI
// (load/scripts/postflight.sh). Su una sottoscrizione Free Trial le regole
// scattano ma la mail non arriva (D122).

@description('Indirizzo email dell\'action group dei consumi. Senza default e fuori dal repo: si passa al deploy.')
param alertEmail string

resource consumptionActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${namePrefix}-consumo'
  location: 'global'
  properties: {
    groupShortName: 'consumo'
    enabled: true
    emailReceivers: [
      {
        name: 'matteo'
        emailAddress: alertEmail
      }
    ]
  }
}

// OnDemandFunctionExecutionUnits e' in MB-ms: diviso 1.024.000 da' i GB-s
// (https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference?tabs=flex-consumption-plan).
// Regola veloce: oltre 1.000 GB-s in 5 minuti, valutata ogni minuto. Le soglie
// vengono dai dati di settembre: ogni run di carico la supera, demo e
// richieste singole no (D113).
resource consumptionAlertsFast 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for (w, i) in workers: {
    name: 'consumo-${namePrefix}-${w.language}'
    location: 'global'
    properties: {
      description: 'Oltre 1.000 GB-s di esecuzione on demand in 5 minuti su ${namePrefix}-${w.language} (OnDemandFunctionExecutionUnits in MB-ms / 1.024.000). Ogni run di carico lo supera, demo e richieste singole no.'
      severity: 2
      enabled: true
      scopes: [
        resourceId('Microsoft.Web/sites', worker[i].outputs.appName)
      ]
      evaluationFrequency: 'PT1M'
      windowSize: 'PT5M'
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: 'consumo-5-minuti'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'OnDemandFunctionExecutionUnits'
            timeAggregation: 'Total'
            operator: 'GreaterThan'
            threshold: 1024000000
          }
        ]
      }
      actions: [
        {
          actionGroupId: consumptionActionGroup.id
        }
      ]
    }
  }
]

// Regola lenta: oltre 10.000 GB-s in 6 ore, valutata ogni 15 minuti. Copre il
// consumo sostenuto che a tetto 5 resta sotto la regola veloce (D119, R2).
resource consumptionAlertsSlow 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for (w, i) in workers: {
    name: 'consumo-lento-${namePrefix}-${w.language}'
    location: 'global'
    properties: {
      description: 'Oltre 10.000 GB-s di esecuzione on demand in 6 ore su ${namePrefix}-${w.language}: consumo sostenuto sotto la soglia della regola a 5 minuti.'
      severity: 2
      enabled: true
      scopes: [
        resourceId('Microsoft.Web/sites', worker[i].outputs.appName)
      ]
      evaluationFrequency: 'PT15M'
      windowSize: 'PT6H'
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: 'consumo-6-ore'
            metricNamespace: 'Microsoft.Web/sites'
            metricName: 'OnDemandFunctionExecutionUnits'
            timeAggregation: 'Total'
            operator: 'GreaterThan'
            // Oltre il massimo di un intero a 32 bit: va bene qui, perche' gli interi
            // Bicep sono a 64 bit e la soglia e' scritta nel template, non passata
            // come parametro inline
            // (https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/data-types).
            threshold: 10240000000
          }
        ]
      }
      actions: [
        {
          actionGroupId: consumptionActionGroup.id
        }
      ]
    }
  }
]

// Senza scope esplicito il lock si applica al resource group del deploy
// (https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/scope-extension-resources#apply-at-deployment-scope).
// Blocca la cancellazione delle risorse, non quella dei dati: i blob di
// test-images restano cancellabili (D119, R4). Per lo spegnimento va tolto
// prima: az lock delete --name protezione-pre-talk -g rg-torinodotnet-demo.
// Crearlo richiede Microsoft.Authorization/locks/*, che hanno Owner e User
// Access Administrator
// (https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources#who-can-create-or-delete-locks):
// il Bicep si lancia a mano con un utente Owner, non dalla pipeline.
resource deleteLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'protezione-pre-talk'
  properties: {
    level: 'CanNotDelete'
    notes: 'Protegge la demo dalla cancellazione accidentale. Va tolto prima dello spegnimento.'
  }
}

output storageAccountName string = storage.name
output testImagesContainerName string = testImagesContainerName
output applicationInsightsName string = applicationInsights.name
output workerHostNames array = [for (w, i) in workers: worker[i].outputs.defaultHostName]
output frontendName string = frontend.name
output frontendHostName string = frontend.properties.defaultHostname
