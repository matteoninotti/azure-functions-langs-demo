# Generazione del carico (k6)

**k6**, scelto per un motivo metodologico e non di gusto: ha executor a **arrival rate**, cioè si impone quante richieste al secondo *partono*, indipendentemente dal tempo di risposta.

Con un modello a utenti virtuali (Locust, JMeter) il backend più lento riceverebbe automaticamente **meno richieste**: se Python è 3x più lento di Go, con 50 VU ne riceve circa un terzo, e i tre linguaggi finirebbero sotto carichi offerti diversi. Il confronto misurerebbe sé stesso.

## Come si usa

- **Iterazione e messa a punto** → k6 in locale dal Mac. Zero costo, ma la latenza di rete domestica entra nella misura client-side (~34 ms di RTT verso Italy North, misurati in D53).
- **Numeri che finiscono nelle slide** → **k6 in locale dal Mac**, deciso durante i run finali (D131): CPU del processo k6 al massimo al 34% di un core, 10,0 richieste al secondo ottenute su 10 richieste, zero `dropped_iterations`, e sul run più pesante tutta l'attesa sta in `http_req_waiting`, cioè lato Azure.

⚠️ Questa sezione dava la scelta fra il Mac e un **Azure Container Apps Job** in Italy North come ancora da decidere (D59), e prima ancora dava l'ACA Job per deciso. L'hanno chiusa i run finali (D131): il Mac non è stato il collo di bottiglia, quindi l'ACA Job non serve e non c'è.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/resize.js` | Il generatore di carico per Metrica 1 e Metrica 3. |
| `scripts/wait-for-zero.sh` | Attende e **verifica** lo zero istanze su un'app. |
| `scripts/preflight.sh` | I controlli prima di ogni run: configurazione di scala e zero istanze su tutte e tre le app, attese in parallelo, l'app da misurare riconfermata per ultima. Con `CAP_SCOPE=target` il tetto a 200 si pretende solo sull'app da misurare, e le altre due devono restare a 5, o al valore di `OTHER_CAP`. |
| `scripts/run-load.sh` | Un run di Metrica 1 o 3 con i parametri definitivi: salva output e riepilogo di k6, le metriche per richiesta in `client.csv.gz` (timestamp in millisecondi, per la curva lato client secondo per secondo), campiona la CPU del generatore, annota `RUN_START`/`RUN_END`/`http_reqs` in `output/runs.tsv`. |
| `scripts/campaign-load.sh` | La serie di carico: tre ripetizioni di Metrica 3 per linguaggio, con la Metrica 1 subito dopo la prima. |
| `scripts/load-report.sh` | Lettura della serie di carico run per run: `export-run.sh`, riepilogo, curva al secondo, istanze delle altre app e controllo che nessuna istanza di una Metrica 3 fosse già vista prima della finestra. |
| `scripts/query-run.sh` | Lancia una query di `queries/` su una finestra data, senza modificare il file. |
| `scripts/cold-start.sh` | Metrica 2 (e 4 sulle richieste Python): giri ad alternanza di una richiesta a freddo per linguaggio. |
| `scripts/cold-start-report.sh` | Lettura di una serie di `cold-start.sh`: cold start stimato per richiesta, unità fatturate per le richieste Python. |
| `scripts/sub-second.sh` | Il run "sotto il secondo": `count=1`, unità fatturate confrontate con il minimo fatturabile. |
| `scripts/postflight.sh` | Fine campagna: riporta il tetto di istanze a 5 e lo verifica; con `--check` verifica soltanto. |
| `scripts/check-alerts.sh` | Elenca gli alert di Azure Monitor scattati dopo un istante: esce 0 se non ce ne sono, 1 se ce ne sono, 2 se la domanda non ha avuto risposta. |
| `scripts/export-run.sh` | Dopo ogni run: esporta le righe grezze della finestra e verifica che contenga esattamente le richieste del run. |
| `scripts/runtime-snapshot.sh` | Inizio e fine campagna: registra e confronta il runtime dichiarato dai tre worker. |
| `output/` | L'output di tutti i run, gitignorato: i numeri stanno nelle slide del talk, non nel repo. **Mai committare le righe grezze di `export-run.sh`**: contengono dati sul client (per esempio `ClientCity`), e il repo è pubblico. |

**Uno script per due metriche, non uno per metrica.** Metrica 1 e Metrica 3 usano la stessa forma di carico — tasso costante — e differiscono per lo stato dell'app quando il carico arriva (calda contro zero istanze) e per come si leggono i risultati, non per cosa fa il generatore. Due file identici da tenere allineati a mano sarebbero due occasioni di farli divergere.

**Metrica 2 non usa k6.** Il cold start isolato è una singola richiesta sequenziale: un generatore di carico ci aggiungerebbe solo rumore. `cold-start.sh` la esegue **a giri** (D126): zero su tutte e tre le app, poi una richiesta per linguaggio in sequenza, con l'ordine ruotato a ogni giro; `count=80` e la stessa immagine dei run di carico. Le richieste Python sono anche le ripetizioni della Metrica 4.

Il comando dei run finali, identico per i tre linguaggi e per Metrica 1 e Metrica 3 (D89, D92):

```
k6 run -e LANGUAGE=python -e RPS=10 -e DURATION=60s -e COUNT=80 \
       -e PRE_ALLOCATED_VUS=300 -e MAX_VUS=400 load/scripts/resize.js
```

Tutti i parametri stanno in variabili d'ambiente (D15): `LANGUAGE`, `HOST`, `IMAGE`, `COUNT`, `WIDTH`, `QUALITY`, `RPS`, `DURATION`, `PRE_ALLOCATED_VUS`, `MAX_VUS`.

## Leggere i risultati senza sbagliare

Quattro contatori di fallimento che sembrano lo stesso e non lo sono:

- **`http_req_failed`** — il backend ha risposto male o non ha risposto. È un dato sull'esperimento.
- **`dropped_iterations`** — k6 non è riuscito a *far partire* le richieste al tasso richiesto, perché i VU allocati non bastavano. È un fallimento del generatore: invalida il run come misura di carico offerto. Se compare, si rialza `PRE_ALLOCATED_VUS` e si rifà.
- **Richiesta abbandonata da k6 al proprio `timeout`** — la richiesta era partita, ma la risposta non è arrivata entro il tetto per richiesta (`60s`, [default di k6](https://grafana.com/docs/k6/latest/javascript-api/k6-http/params/), ora scritto esplicito nello scenario). Lato server diventa un **`499`**.
- **Iterazione interrotta da k6** — la richiesta era partita e il backend la stava servendo, ma allo scadere di `gracefulStop` k6 ha chiuso la connessione. Lato server diventa un **`499`** anche questa.

**Il terzo e il quarto lato server sono lo stesso codice e lato client no.** È così che si separano:

| in `resize_status_codes` e nel riepilogo | cos'è |
|---|---|
| `499` lato server + **`status 0`**, `error_code 1050`, iterazione **completa** | la richiesta ha sfondato il `timeout` di 60 s |
| `499` lato server + `N complete and **M** interrupted iterations`, con M > 0 | `gracefulStop` |

I **7 `499` di D89 sono il terzo caso**: erano il generatore sottodimensionato — nello stesso run c'erano 13 `dropped_iterations` — e sono spariti in D91 rifacendo il run con 300 VU, **senza toccare `gracefulStop`**. Se ne ricompaiono, la leva è `PRE_ALLOCATED_VUS`.

`gracefulStop` resta comunque **esplicito a `120s`** invece del [default di `30s`](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/graceful-stop/), per il suo motivo: D90 punto 1 misura ~16 s di arretrato che si smaltisce dopo la fine della finestra, e con 30 s quelle iterazioni finirebbero tagliate.

Lo script conta anche gli status code uno per uno (`resize_status_codes`), perché sotto burst un `429` (la piattaforma limita lo scale-out) e un `500` dopo 30 secondi (app init che sfora il timeout) sono due storie diverse (D45).

`resize_server_total_ms` è il cronometro interno alla function, riletto dal corpo della risposta: comodo per vedere subito lo scarto con `http_req_duration` senza aspettare l'ingestion di Application Insights. **Non è la fonte autorevole** — quella resta la durata server-side nella telemetria, che è anche ciò che determina il costo.

`count=N`, RPS target e durata restano parametri esterni, tarati dopo un run preliminare e scritti nel decision log (D15): `count` va dimensionato perché **la più veloce delle tre** superi 1s, e quale sia la più veloce non si sa finché non si misura. **La taratura è stata fatta** con i tre worker deployati (D89): `count=80`, 10 req/s, 60s.

**La Metrica 1 va preceduta da una finestra di riscaldamento.** A questo carico la piattaforma impiega decine di secondi ad arrivare alla capacità richiesta, e su una finestra di 60 secondi la rampa domina la misura: senza riscaldamento si misura lo scale-out, che è oggetto della Metrica 3 (D90). Il riscaldamento **è una ripetizione della Metrica 3** (D126): stesso comando, stesso stato di partenza, e M1 parte subito dopo il suo `RUN_END`, senza preflight. La finestra di quella ripetizione finisce al suo `RUN_END`; se la ripetizione è invalida, si rifà anche M1. `campaign-load.sh` esegue la serie in quest'ordine.

## Protocollo di ogni run

Fuori dalle finestre di misura le tre app hanno `maximumInstanceCount` a **5**, non ai 200 del Bicep: limita il consumo di traffico non nostro sugli endpoint anonimi. Per le Metriche 1 e 3 va riportato a 200 prima e riabbassato dopo; le Metriche 2 e 4 sono richieste singole e il tetto non le tocca. `preflight.sh` non lascia partire un run di carico con il tetto sbagliato; `postflight.sh` riporta il tetto a 5 a fine campagna e fallisce se non ci è riuscito. Un `az deployment group create` riporta il tetto a 200 senza dirlo: dopo un deploy dell'infrastruttura va rilanciato `postflight.sh`.

**Inizio campagna**

```bash
./load/scripts/runtime-snapshot.sh inizio
# solo per Metrica 1 e 3:
for l in python dotnet go; do az functionapp scale config set -g rg-torinodotnet-demo -n torinodotnet-$l --maximum-instance-count 200 -o none; done
```

`runtime-snapshot.sh` chiama `/api/health`, che sveglia le app: va lanciato **prima** di `preflight.sh`, mai in mezzo.

**Ogni run**

1. `./load/scripts/preflight.sh <metrica> <linguaggio>` — configurazione (2.048 MB, concorrenza 1, tetto a 200 per 1 e 3) e zero istanze su **tutte e tre** le app, non solo su quella da misurare: la quota regionale di core è condivisa fra le app Flex della sottoscrizione ([Regional subscription memory quotas](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)). L'app da misurare è confermata **per ultima**, così la sua conferma è la più recente quando il run parte. Fra `preflight.sh` e il run, nessuna richiesta verso le app.
2. Il run. Per la Metrica 1 sono due, riscaldamento e run misurato, uno dopo l'altro e senza `preflight.sh` in mezzo: l'app deve arrivare calda al secondo (D90).
3. Dopo 2–4 minuti di ingestion: `./load/scripts/export-run.sh <etichetta> <RUN_START> <RUN_END> <richieste>`, con `<richieste>` = `http_reqs` di k6 per le Metriche 1 e 3, `1` per le Metriche 2 e 4. Salva le righe grezze in `load/output/<etichetta>/` — la telemetria sul workspace dura 30 giorni — e fallisce se nella finestra, su tutte e tre le app, c'è anche una sola richiesta in più, in meno o diversa da `resize`. Per le Metriche 2 e 4 è il controllo "nessun altro traffico": gli endpoint sono anonimi e `ClientIP` è mascherato, quindi non si può sapere *chi* ha fatto una richiesta estranea, ma si può sapere *se* c'è stata.
4. Solo per la Metrica 3: il conteggio istanze delle **altre due** app nella finestra, con `Count` e mai `Maximum` (D55), letto qualche minuto dopo perché la metrica ritarda (D56):

   ```bash
   az monitor metrics list --resource <id-app> --metric InstanceCount --aggregation Count --interval PT1M --start-time <RUN_START> --end-time <RUN_END>
   ```

**Fine campagna**

```bash
./load/scripts/runtime-snapshot.sh fine inizio   # fallisce se una patch di runtime e' cambiata in mezzo
./load/scripts/postflight.sh                     # tetto a 5 sulle tre app, riletto dalla risorsa
```

Segnarsi l'istante di fine campagna (UTC). Le regole di consumo scattano durante ogni run di carico, e su questa sottoscrizione le loro mail **non arrivano**: gli alert si controllano interrogandoli. Da quel momento in poi, fra una campagna e l'altra e prima del talk:

```bash
./load/scripts/check-alerts.sh <fine ultima campagna, es. 2026-09-24T18:00:00Z>
```

Un alert scattato dopo la fine della campagna è consumo non nostro. Un'uscita 2 non è "nessun alert": la domanda non ha avuto risposta e va rifatta.

Il tetto a 5 è uno scostamento voluto dal Bicep, che non può nemmeno esprimerlo (`@minValue(40)`). Un `az deployment group create` lo riporta a 200: non falsifica una misura, ma toglie la protezione in silenzio. Per questo, dopo ogni deploy dell'infrastruttura e prima del talk, si lancia `./load/scripts/postflight.sh --check`.
