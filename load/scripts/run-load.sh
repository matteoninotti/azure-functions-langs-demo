#!/usr/bin/env bash
#
# Un run di carico delle Metriche 1 e 3 con i parametri definitivi, e tutto
# cio' che serve dopo per leggerlo e per validarlo.
#
#   ./load/scripts/run-load.sh <etichetta> <python|dotnet|go>
#   ./load/scripts/run-load.sh m3-go-r1 go
#
# I parametri sono quelli dei run finali, identici per le due metriche e per
# i tre linguaggi (D89, D92), passati espliciti a resize.js: i suoi default non
# sono questi.
#
# RPS, PRE_ALLOCATED_VUS e MAX_VUS si possono cambiare da variabile d'ambiente,
# solo per run esplorativi fuori dalla campagna, con un'etichetta loro:
#
#   RPS=30 PRE_ALLOCATED_VUS=600 MAX_VUS=1500 ./load/scripts/run-load.sh m3x-go-30rps go
#
# Scrive in load/output/<etichetta>/:
#   k6.log        l'output completo di k6
#   summary.json  il riepilogo di fine test (--summary-export)
#   client.csv.gz una riga per metrica per richiesta (--out csv), con il
#                 timestamp in millisecondi: e' da qui che si ricava la curva
#                 lato client secondo per secondo, che il riepilogo non ha
#                 ([k6, CSV](https://grafana.com/docs/k6/latest/results-output/real-time/csv/))
#   cpu.tsv       CPU e memoria del processo k6, un campione ogni 2 s
# e aggiunge una riga a load/output/runs.tsv con RUN_START, RUN_END e
# http_reqs: i tre argomenti di export-run.sh.
#
# Il campionamento della CPU e il tasso ottenuto sono il controllo del
# generatore (D59, D126): se il Mac diventa il collo di bottiglia, lo si vede
# qui e non nei numeri del backend.
#
# Esce:
#   0  run completo, nessuna dropped_iteration, nessuna iterazione interrotta
#   3  il generatore non ha tenuto il tasso (dropped_iterations > 0) o ha
#      interrotto iterazioni: il run NON e' valido come misura di carico offerto
#   1  qualunque altro errore

set -euo pipefail

LABEL="${1:-}"
LANGUAGE="${2:-}"
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "uso: $0 <etichetta> <python|dotnet|go>" >&2; exit 2; }
case "$LANGUAGE" in python|dotnet|go) ;; *) echo "uso: $0 <etichetta> <python|dotnet|go>" >&2; exit 2 ;; esac

RPS="${RPS:-10}"
DURATION=60s
DURATION_S=60
COUNT=80
IMAGE=npm-install-7-years.jpg
WIDTH=800
QUALITY=80
PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-300}"
MAX_VUS="${MAX_VUS:-400}"
for v in RPS PRE_ALLOCATED_VUS MAX_VUS; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || { echo "$v deve essere un intero > 0, non '${!v}'" >&2; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output/$LABEL"
LEDGER="$REPO_ROOT/load/output/runs.tsv"
[ -e "$OUT_DIR" ] && { echo "esiste gia' ${OUT_DIR}: etichetta gia' usata" >&2; exit 2; }
mkdir -p "$OUT_DIR"

K6_CSV_TIME_FORMAT=unix_milli k6 run \
  -e LANGUAGE="$LANGUAGE" -e RPS="$RPS" -e DURATION="$DURATION" -e COUNT="$COUNT" \
  -e IMAGE="$IMAGE" -e WIDTH="$WIDTH" -e QUALITY="$QUALITY" \
  -e PRE_ALLOCATED_VUS="$PRE_ALLOCATED_VUS" -e MAX_VUS="$MAX_VUS" \
  --summary-export "$OUT_DIR/summary.json" \
  --out "csv=$OUT_DIR/client.csv.gz" \
  "$REPO_ROOT/load/scripts/resize.js" >"$OUT_DIR/k6.log" 2>&1 &
K6_PID=$!

printf 'utc\tcpu_pct\trss_kb\n' >"$OUT_DIR/cpu.tsv"
while kill -0 "$K6_PID" 2>/dev/null; do
  sample=$(ps -o %cpu=,rss= -p "$K6_PID" 2>/dev/null || true)
  [ -n "$sample" ] && printf '%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" $sample >>"$OUT_DIR/cpu.tsv"
  sleep 2
done
K6_EXIT=0
wait "$K6_PID" || K6_EXIT=$?

python3 - "$OUT_DIR" "$LEDGER" "$LABEL" "$LANGUAGE" "$DURATION_S" "$RPS" "$K6_EXIT" "$(k6 version | head -n 1)" <<'EOF'
import json, os, re, sys

out_dir, ledger, label, lang, duration_s, rps, k6_exit, k6_version = sys.argv[1:9]
duration_s, rps, k6_exit = int(duration_s), float(rps), int(k6_exit)
log = open(f"{out_dir}/k6.log").read()

def one(pattern):
    m = re.findall(pattern, log)
    return m[-1] if m else None

run_start = one(r'RUN_START (\S+)')
run_end = one(r'RUN_END (\S+)')
last_progress = one(r'(\d+) complete and (\d+) interrupted iterations')
if k6_exit != 0 or not (run_start and run_end and last_progress) or not os.path.exists(f"{out_dir}/summary.json"):
    print(f"ERRORE: k6 uscito {k6_exit}, oppure mancano RUN_START/RUN_END/riepilogo in {out_dir}", file=sys.stderr)
    sys.exit(1)

m = json.load(open(f"{out_dir}/summary.json"))["metrics"]
http_reqs = int(m["http_reqs"]["count"])
dropped = int(m.get("dropped_iterations", {}).get("count", 0))
failed_rate = m["http_req_failed"].get("value", m["http_req_failed"].get("rate", 0))
interrupted = int(last_progress[1])
dur = m["http_req_duration"]

# Il CSV per richiesta deve essere integro e completo: una riga di
# http_req_duration per ogni richiesta del riepilogo. Un file troncato darebbe
# una curva lato client con dei buchi, senza nessun segnale.
import gzip
try:
    with gzip.open(f"{out_dir}/client.csv.gz", "rt") as f:
        header = f.readline().rstrip("\n").split(",")
        i_name = header.index("metric_name")
        csv_reqs = sum(1 for line in f if line.split(",", i_name + 1)[i_name] == "http_req_duration")
except Exception as e:
    print(f"ERRORE: client.csv.gz illeggibile: {e}", file=sys.stderr)
    sys.exit(1)
if csv_reqs != http_reqs:
    print(f"ERRORE: client.csv.gz ha {csv_reqs} righe http_req_duration, il riepilogo {http_reqs} richieste", file=sys.stderr)
    sys.exit(1)

cpu = [float(l.split("\t")[1]) for l in open(f"{out_dir}/cpu.tsv").read().splitlines()[1:] if l.count("\t") == 2]
cpu_max = max(cpu) if cpu else float("nan")
cpu_med = sorted(cpu)[len(cpu) // 2] if cpu else float("nan")
offered = (http_reqs + dropped) / duration_s

print(f"{label} [{lang}] {k6_version}")
print(f"  RUN_START {run_start}  RUN_END {run_end}")
print(f"  http_reqs {http_reqs}  dropped_iterations {dropped}  interrupted {interrupted}  http_req_failed {failed_rate:.4f}")
print(f"  client.csv.gz: {csv_reqs} richieste, integro")
print(f"  tasso richiesto {rps:g}/s, iterazioni partite {http_reqs / duration_s:.2f}/s sulla finestra nominale")
print(f"  http_req_duration med {dur['med']:.0f} ms  p95 {dur['p(95)']:.0f}  p99 {dur['p(99)']:.0f}  max {dur['max']:.0f}")
print(f"  CPU k6: mediana {cpu_med:.1f}%  massimo {cpu_max:.1f}%  ({len(cpu)} campioni)")

new = not os.path.exists(ledger)
with open(ledger, "a") as f:
    if new:
        f.write("label\tlanguage\trun_start\trun_end\thttp_reqs\tdropped\tinterrupted\thttp_req_failed\tcpu_med\tcpu_max\tk6\n")
    f.write(f"{label}\t{lang}\t{run_start}\t{run_end}\t{http_reqs}\t{dropped}\t{interrupted}\t{failed_rate:.4f}\t{cpu_med:.1f}\t{cpu_max:.1f}\t{k6_version}\n")

if dropped or interrupted:
    print("RUN NON VALIDO: il generatore non ha tenuto il tasso o ha interrotto iterazioni.", file=sys.stderr)
    sys.exit(3)
print("RUN OK")
EOF
