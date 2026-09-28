#!/usr/bin/env bash
#
# Controlli prima di ogni run di misura, identici per le quattro metriche e
# per i tre linguaggi. Esce 0 solo se sono veri tutti.
#
#   ./load/scripts/preflight.sh 1 go      # Metrica 1 o 3: carico, servono 200 istanze
#   ./load/scripts/preflight.sh 2 python  # Metrica 2 o 4: una richiesta singola
#   CAP_SCOPE=target ./load/scripts/preflight.sh 3 go   # burst su una sola app
#
# Il secondo argomento e' il linguaggio che si sta per misurare.
#
# CAP_SCOPE (solo per le Metriche 1 e 3): `all`, il default, vuole il tetto a
# 200 sulle tre app; `target` lo vuole a 200 solo sull'app da misurare e a 5
# sulle altre due, cosi' un burst su un solo linguaggio non lascia scoperte le
# app che non misura. Lo zero su tutte e tre resta richiesto in entrambi i casi.
#
# 1. Configurazione di scala delle tre app, letta dalla RISORSA e non dal
#    Bicep: 2.048 MB e concorrenza HTTP 1 sempre, e per le Metriche 1 e 3
#    `maximumInstanceCount` a 200. Fuori dalle finestre di misura il tetto sta
#    basso (vedi load/README.md, "Protocollo di ogni run"): un run di carico
#    lanciato col tetto basso misurerebbe il tetto invece del linguaggio, e lo
#    farebbe senza nessun errore.
# 2. Zero istanze su TUTTE E TRE le app, non solo su quella da misurare. La
#    quota regionale di core e' condivisa fra le app Flex della sottoscrizione
#    e regione ([Regional subscription memory quotas](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)):
#    istanze ancora vive su un'altra app sono capacita' sottratta a quella
#    misurata. Le tre attese girano in parallelo, poi l'app da misurare viene
#    RICONFERMATA da sola: la sua conferma e' la piu' recente quando il run
#    parte.
#
# ⚠️ Niente richieste verso le app fra questo script e il run: anche un
# /api/health sveglia un'istanza. Il runtime (runtime-snapshot.sh) si legge
# PRIMA di lanciare questo script.

set -euo pipefail

METRIC="${1:-}"
TARGET="${2:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
LANGUAGES=(python dotnet go)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$METRIC" in
  1|3) WANT_MAX=200 ;;
  2|4) WANT_MAX="" ;;
  *) echo "uso: $0 <1|2|3|4> <python|dotnet|go>  (metrica, linguaggio da misurare)" >&2; exit 2 ;;
esac
case "$TARGET" in
  python|dotnet|go) ;;
  *) echo "uso: $0 <1|2|3|4> <python|dotnet|go>  (metrica, linguaggio da misurare)" >&2; exit 2 ;;
esac
CAP_SCOPE="${CAP_SCOPE:-all}"
case "$CAP_SCOPE" in
  all|target) ;;
  *) echo "CAP_SCOPE deve essere 'all' o 'target', non '${CAP_SCOPE}'" >&2; exit 2 ;;
esac

AZ_ERR=$(mktemp)
trap 'rm -f "$AZ_ERR"' EXIT

failed=0
for lang in "${LANGUAGES[@]}"; do
  app="torinodotnet-${lang}"
  if ! cfg=$(az resource show --resource-group "$RESOURCE_GROUP" --name "$app" \
    --resource-type Microsoft.Web/sites --api-version 2024-04-01 \
    --query "[properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount, properties.functionAppConfig.scaleAndConcurrency.instanceMemoryMB, properties.functionAppConfig.scaleAndConcurrency.triggers.http.perInstanceConcurrency]" \
    -o tsv 2>"$AZ_ERR"); then
    echo "${app}: configurazione non leggibile: $(cat "$AZ_ERR")" >&2
    failed=1
    continue
  fi
  # -o tsv mette i tre valori su tre righe.
  read -r max_instances memory_mb concurrency <<<"$(echo $cfg)"
  echo "${app}: maximumInstanceCount=${max_instances} instanceMemoryMB=${memory_mb} perInstanceConcurrency=${concurrency}"

  if [ "$memory_mb" != "2048" ] || [ "$concurrency" != "1" ]; then
    echo "${app}: memoria o concorrenza diverse da 2048 / 1. Sono fatti bloccati: non si misura." >&2
    failed=1
  fi
  want="$WANT_MAX"
  # Con CAP_SCOPE=target le app che non si misurano restano al tetto basso.
  [ -n "$want" ] && [ "$CAP_SCOPE" = target ] && [ "$lang" != "$TARGET" ] && want=5
  if [ -n "$want" ] && [ "$max_instances" != "$want" ]; then
    echo "${app}: maximumInstanceCount e' ${max_instances}, la Metrica ${METRIC} (CAP_SCOPE=${CAP_SCOPE}) ne vuole ${want}. Prima del run:" >&2
    echo "  az functionapp scale config set -g ${RESOURCE_GROUP} -n ${app} --maximum-instance-count ${want}" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "PREFLIGHT FALLITO: configurazione." >&2
  exit 1
fi

# Le tre attese partono in parallelo: si aspetta la piu' lenta, non la somma.
# Poi l'app da misurare si riconferma da sola, cosi' la sua conferma resta la
# piu' recente quando il run parte (D119). Ogni attesa scrive nel proprio log,
# stampato alla fine, perche' tre output intrecciati non si leggono.
WAIT_DIR=$(mktemp -d)
trap 'rm -f "$AZ_ERR"; rm -rf "$WAIT_DIR"' EXIT

pids=()
for lang in "${LANGUAGES[@]}"; do
  RESOURCE_GROUP="$RESOURCE_GROUP" "$SCRIPT_DIR/wait-for-zero.sh" "$lang" >"$WAIT_DIR/$lang.log" 2>&1 &
  pids+=("$!")
done
zero_failed=0
for i in "${!LANGUAGES[@]}"; do
  lang="${LANGUAGES[$i]}"
  if wait "${pids[$i]}"; then
    echo "torinodotnet-${lang}: $(tail -n 1 "$WAIT_DIR/$lang.log")"
  else
    echo "torinodotnet-${lang}: attesa dello zero FALLITA:" >&2
    sed 's/^/  /' "$WAIT_DIR/$lang.log" >&2
    zero_failed=1
  fi
done
if [ "$zero_failed" -ne 0 ]; then
  echo "PREFLIGHT FALLITO: almeno un'app non e' a zero istanze." >&2
  exit 1
fi

# La riconferma segue una conferma gia' valida, che ha osservato l'app per
# almeno MIN_OBSERVE_SECONDS, e fra le due non passa traffico: un'istanza viva
# sarebbe gia' comparsa. Qui bastano le due letture quiete consecutive, senza
# rifare l'osservazione minima (~1 minuto invece di 5).
echo "Riconferma di torinodotnet-${TARGET}, per ultima:"
MIN_OBSERVE_SECONDS=0 RESOURCE_GROUP="$RESOURCE_GROUP" "$SCRIPT_DIR/wait-for-zero.sh" "$TARGET" || {
  echo "PREFLIGHT FALLITO: torinodotnet-${TARGET} non e' a zero istanze alla riconferma." >&2
  exit 1
}

echo "PREFLIGHT OK per la Metrica ${METRIC} su ${TARGET}: configurazione verificata, tre app a zero istanze, ${TARGET} confermata per ultima."
