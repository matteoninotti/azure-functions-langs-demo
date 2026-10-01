# Infrastruttura (Bicep)

Strumento scelto: **Bicep** (D20). Nativo Azure, nessuno state file da custodire in un repo pubblico, e il teardown è "cancella il resource group".

Cosa c'è dentro:

- Resource group unico, **Italy North**.
- Uno storage account e **un piano Flex Consumption per ciascuna delle tre function app** — su Flex vale il vincolo *una sola app per piano*.
- Un container di deploy **per worker**, non condiviso: su Flex il pacchetto è un unico `released-package.zip` per container, e due app sullo stesso container si sovrascrivono a vicenda (D78).
- Instance size **2.048 MB** su tutte e tre, concorrenza HTTP **1**, `http20Enabled` **false**.
- Application Insights + Log Analytics, con il **sampling disattivato** (D14).
- **Static Web App**, in East US 2 perché il tipo di risorsa non esiste in Italy North (D93), con la sua origine in allowlist CORS sulle tre function app (D12).
- **Protezione dai consumi**: un action group, due regole per app su `OnDemandFunctionExecutionUnits` (oltre 1.000 GB-s in 5 minuti, oltre 10.000 GB-s in 6 ore) e un lock `CanNotDelete` sul resource group. Il lock va tolto prima dello spegnimento: `az lock delete --name protezione-pre-talk -g rg-torinodotnet-demo`. Crearlo richiede Owner o User Access Administrator ([chi può creare i lock](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources#who-can-create-or-delete-locks)), per questo il Bicep si lancia a mano e non dalla pipeline.

Nessun Container Apps Environment: il generatore di carico è k6 dal Mac, deciso nei run finali (D131).

```
az deployment group create -g rg-torinodotnet-demo --template-file infra/main.bicep --parameters alertEmail=<indirizzo>
```

`alertEmail` non ha default e non sta nel repo: è il destinatario dell'action group dei consumi. Dopo il primo deploy l'indirizzo va confermato con il codice OTP entro 30 minuti ([action groups](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups)).

⚠️ Un deploy dell'infrastruttura **scrive su tutte e tre le app**, anche quelle che non stai cambiando (D72): non va lanciato nel mezzo di una campagna di misura.

## La concorrenza a 1 si imposta qui, e non più via CLI

La **HTTP trigger concurrency** è dichiarata nel Bicep, in `scaleAndConcurrency.triggers.http.perInstanceConcurrency`. Non era così all'inizio — serviva un comando CLI post-deploy ([Set HTTP concurrency limits](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to#set-http-concurrency-limits)) — ed è cambiato con D39: dichiarata nel template, una re-provisioning la **ri-imposta** invece di riportarla al default. Stesso ragionamento per `http20Enabled` e per il CORS.

Resta vero **perché** va forzata su tutte e tre (D22): a 2.048 MB il default documentato è **16**, tranne per le app Python dove è **1** ([Concurrency in Azure Functions § HTTP trigger concurrency](https://learn.microsoft.com/en-us/azure/azure-functions/functions-concurrency)). Lasciare i default significherebbe confrontare Python a concorrenza 1 contro .NET e Go a concorrenza 16: numeri privi di significato.

⚠️ Per la verifica post-deploy, attenzione a **quale comando** si usa per rileggere: `az resource show` sul sito restituisce una `siteConfig` ridotta e dà `cors: null` anche quando il CORS è configurato (D93). Il CORS si rilegge con `az functionapp cors show`; concorrenza, runtime e HTTP/2 con `az resource show ... --query properties.functionAppConfig`.
