# dotnet_lambda — note operative per Claude

Demo + talk (45–60 min, pubblico IT professionale, meetup TorinoDotNet) che confronta **performance e costi di Azure Functions tra Python, .NET e Go** su un workload CPU-bound di image resizing, sul piano **Flex Consumption**. Repo pubblico su GitHub come `torinodotnet-azure-functions-meetup-demo`.

> Questo file è un puntatore sottile + le poche regole che servono per lavorare nel repo. La sostanza sta negli altri due documenti.

## Documenti canonici

- **`instructions.md`** (in questo repo) — la **specifica** del progetto: architettura sperimentale, metodologia di misurazione, billing, gotchas, limitazioni. È il _cosa_ e il _perché_.
- **`dotnet_lambda-log.md`** (nel vault, non in questo repo) — il **decision log**: `<vault>/altro/dotnet_lambda/dotnet_lambda-log.md`. §1 recon · §2 decisioni `D#` · §3 domande aperte. È l'**unica fonte di verità** per le decisioni prese: dove `instructions.md` lascia un TBD, la risposta sta qui.

> `<vault>` è la cartella `my_vault` sincronizzata su OneDrive, in locale sul Mac di Matteo. Il percorso assoluto si risolve in locale, per esempio con `find ~/Library/CloudStorage -maxdepth 4 -type d -name my_vault`.

- Appunti preparatori (stessa cartella nel vault): `scaletta - abstract - titolo - next prompt.md`, `primi appunti wdavide_100726.md`, `secondi appunti.md`. Materiale grezzo, non autoritativo.

Se `instructions.md` e il log dicono cose diverse, **vince il log** — ed è il segnale che `instructions.md` va aggiornato.

## Come si lavora qui (guardrail vincolanti)

- **Regola sulle fonti — la più importante.** Ogni affermazione fattuale porta il **link inline alla fonte ufficiale**, incollato accanto all'affermazione. Non basta nominare la pagina: serve l'URL. Se una fonte ufficiale non esiste o non si trova, si scrive `⚠️ FONTE UFFICIALE NON TROVATA` insieme a quello che si è comunque trovato e a come si intende verificarlo. Le fonti community valgono solo come conferma incrociata, mai come base per un numero da slide. Vedi la sezione in cima a `instructions.md`.
- **Mai inventare** numeri, benchmark, prezzi, comandi, flag, versioni o URL. Se non è verificato, si dichiara non verificato.
- **Ogni misura porta la sua unità.** Un numero senza unità non è una misura: `800` non significa niente, `800 px` sì. Vale nel codice, nei documenti, nelle slide e soprattutto **nell'interfaccia**, dove un campo etichettato "Larghezza" con dentro `800` costringe chi guarda a indovinare. Le grandezze **adimensionali** vanno dichiarate come tali — un conteggio, o una scala come la qualità JPEG 1–95 — perché "non ha unità" e "l'unità è stata dimenticata" si distinguono solo se lo si scrive.
- **Le motivazioni sulla provenienza di materiali esterni stanno nel decision log, non nel repo.** `D38` Nel repo va solo il piano operativo — _cosa_ si fa ("le immagini restano in locale e si iniettano a deploy-time"), non _perché_ si è scelto così. Vale per `instructions.md`, README, commenti al codice, nomi di variabile, **messaggi di commit** e **`CLAUDE.md` stesso**: qui stanno le regole, non il perché delle scelte, e nessuna informazione sensibile (identificativi di risorse o di account, indirizzi, percorsi locali). _Non riguarda il licensing tecnico delle dipendenze_ — la soglia commerciale di ImageSharp, per esempio, è un contenuto del talk e sta benissimo in `instructions.md`.
- **Segnalare sempre quando una fonte nuova corregge una vecchia** — mai sostituire silenziosamente.
- **Fare domande di chiarimento mirate prima di produrre output.** Meglio troppe domande che output sbagliato.
- **Livello di spiegazione**: studente IT junior — profondità tecnica reale, senza banalizzare ma senza dare per scontato gergo avanzato non ancora introdotto.
- **Codice e identificatori in inglese.** Italiano solo per slide, testo rivolto al pubblico e commenti destinati alla presentazione.
- **Realismo per la scelta della libreria, simmetria per la sua configurazione.** I parametri si allineano al minimo comune denominatore tra i tre linguaggi; ogni asimmetria residua va dichiarata nelle limitazioni.
- **Non toccare l'architettura sperimentale** (piano, instance size, regione, concorrenza, forma dell'endpoint) senza discuterne prima.
- **Registrare nel log ogni decisione bloccata.** Va aggiunta a `dotnet_lambda-log.md` §2 sotto un heading `### YYYY-MM-DD` con la **data corrente** (un heading nuovo per giorno; la numerazione `D#` è **continua** tra le date — dopo `D13` viene `D14`). **L'heading è solo la data, senza sottotitolo**: `### 2026-09-10`, non `### 2026-09-10 — onboarding di Fase 3`. **Ogni voce nuova chiude la sua prima riga con l'identificatore di blocco Obsidian del proprio numero**, separato da uno spazio: `**D145 — titolo…** ^D145`. Mai riscrivere le voci passate.
- **Prima di iniziare un task o di citare un `D#`, rileggere la decisione nel log.** Mai fidarsi della memoria di cosa dice: la si ri-deriva dal file ogni volta che è load-bearing. Se una decisione lascia un residuo, controllare se un `D#` successivo l'ha già risolto.
- **Tenere `TODO.md` sincronizzato al commit.** Quando un commit completa o fa avanzare un task **già tracciato**, lo si spunta nello **stesso commit** — il tracker non deve mai restare indietro rispetto al codice.
- **Mai aggiungere a `TODO.md` un task solo per spuntarlo.** `TODO.md` traccia il lavoro **da fare**: una voce si aggiunge quando il lavoro è previsto, non a cose fatte per lasciarne traccia. Quello che è stato fatto, deciso o scoperto va **solo** nel decision log — è lì che sta la storia del progetto.
- **Non hard-wrappare la prosa a metà frase** nei documenti. Si va a capo solo dove serve strutturalmente (fine periodo, elemento di lista, paragrafo nuovo). Le righe lunghe le manda a capo l'editor.
- **Versioning = GitHub flow, un branch per fase.** Il codice di ogni fase sta su un branch che porta il suo nome (`phase-N`, allineato a `TODO.md`); si committa a ogni task completato o avanzato (test verdi + `TODO.md` sincronizzato nello stesso commit). A fase finita, merge su `main` con `git merge --no-ff`. `main` resta sempre rilasciabile. Le modifiche di meta-progetto (CLAUDE.md, documentazione, guardrail) vanno **dritte su `main`**, non su un branch di fase. I task procedurali di **Fase 0** (account, MFA, budget alert, resource provider — cose fatte fuori dal codice) si committano sul branch `phase-0`, come qualsiasi altro task di fase: non vanno su `main`. Merge, push e cancellazione dei branch si fanno **solo su indicazione esplicita di Matteo** — mai push o delete non richiesti.
- **Il deploy non parte da solo.** La pipeline è `workflow_dispatch`, e non si lancia durante una finestra di misura.
- **Il deploy parte solo da `main` (D44, D111).** Il job di deploy passa dall'environment GitHub `production`, che ammette solo `main` e si ferma in attesa dell'approvazione di Matteo prima di ogni deploy. La credenziale federata OIDC del job è registrata sul subject di quell'environment. Un `workflow_dispatch` lanciato da un branch di fase non deploya: lo ferma la branch policy dell'environment o, se il workflow di quel branch non referenzia l'environment, l'autenticazione OIDC. Per deployare il codice di una fase, prima si porta su `main` — con il merge esplicito richiesto dalla riga sopra.

## Fatti bloccati (dettagli e motivazioni nel log)

Piano **Flex Consumption** · instance size **2.048 MB** · regione **Italy North** · **HTTP trigger concurrency = 1** · Python **3.12**, .NET **10 isolated**, Go **1.24+ (public preview)** · output **JPEG qualità 80, 4:2:0 baseline**, filtro **bilineare** · budget **€20**.

## Checklist pre-presentazione

Rileggere la [tabella delle versioni linguaggio supportate su Flex](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#supported-language-stack-versions) **il giorno prima**. Disabilitare eventuali istanze always-ready dopo le demo. Verificare che il tetto di istanze sia a 5 sulle tre app: `./load/scripts/postflight.sh --check`. Controllare gli alert scattati dopo la fine dell'ultima campagna: `./load/scripts/check-alerts.sh <istante UTC>`.
