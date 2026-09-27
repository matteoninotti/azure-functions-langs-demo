// Pannello dimostrativo: manda la STESSA richiesta ai tre worker e mostra i
// risultati affiancati, per una o piu' immagini insieme.
//
// Non misura niente. I percentili li producono k6 e Application Insights; qui
// si vede solo che i tre backend rispondono allo stesso contratto e che le
// immagini che tornano sono equivalenti. Il tempo sulle card e' reale — e' il
// cronometro interno alla pipeline, la stessa strumentazione delle misure vere
// — ma un singolo click non ha ripetizioni ne' percentili, quindi non e' una
// misura statisticamente valida.

const BACKENDS = [
  { id: 'python', label: 'Python', host: 'torinodotnet-python.azurewebsites.net' },
  { id: 'dotnet', label: '.NET', host: 'torinodotnet-dotnet.azurewebsites.net' },
  { id: 'go', label: 'Go', host: 'torinodotnet-go.azurewebsites.net' },
];

const els = {
  form: document.getElementById('controls'),
  images: document.getElementById('images'),
  width: document.getElementById('width'),
  quality: document.getElementById('quality'),
  count: document.getElementById('count'),
  run: document.getElementById('run'),
  status: document.getElementById('status'),
  results: document.getElementById('results'),
  legend: document.getElementById('legend'),
};

const api = (backend, path) => `https://${backend.host}/api/${path}`;

const buildQuery = (params) => new URLSearchParams(params).toString();

// L'originale si chiede a UN SOLO backend: e' lo stesso file byte per byte nei
// tre pacchetti di deploy (verificato, D97), quindi chiederlo a tutti e tre
// direbbe solo che sappiamo scaricare tre volte la stessa cosa.
//
// QUALE dei tre pero' non e' fisso: lo decide loadCatalog scegliendo il primo
// che ha davvero risposto. Cablarlo su BACKENDS[0] significava che, con Python
// giu' e gli altri due vivi, il catalogo si popolava e le card di .NET e Go
// funzionavano, ma ogni anteprima e ogni "Originale" puntavano all'app morta:
// pagina piena di icone di immagine rotta proprio nello scenario che il
// controllo multi-backend esiste per far emergere.
let sourceBackend = BACKENDS[0];

const sourceUrl = (image) =>
  `${api(sourceBackend, 'source')}?${buildQuery({ image })}`;

// I nomi dei file finiscono dentro innerHTML: passano da qui prima, cosi' un
// nome con `&` o `<` non corrompe il markup. Sono nomi che scegliamo noi, non
// input di un utente — il punto non e' un attacco, e' che un file chiamato
// "prima & dopo.jpg" renderebbe la pagina in modo sbagliato senza dirlo.
const escapeHtml = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]
  );

// Gli object URL creati per le immagini dei risultati. Il browser li tiene vivi
// finche' non si revocano esplicitamente: replaceChildren() stacca i nodi dal
// DOM ma NON libera il blob dietro. In una demo che si rilancia dieci volte
// sarebbero dieci JPEG pieni per backend a restare in memoria per tutta la
// sessione.
let liveObjectUrls = [];

function revokeLiveObjectUrls() {
  for (const url of liveObjectUrls) URL.revokeObjectURL(url);
  liveObjectUrls = [];
}

function setStatus(message, kind = '') {
  els.status.textContent = message;
  els.status.className = kind;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return '—';
  return bytes >= 1024 * 1024
    ? `${(bytes / (1024 * 1024)).toFixed(2)} MB`
    : `${(bytes / 1024).toFixed(1)} kB`;
}

// --- Catalogo delle immagini -------------------------------------------------

// Il catalogo si chiede a TUTTI e tre i backend, non solo al primo che
// risponde: se un pacchetto di deploy fosse partito senza le immagini, il
// worker resterebbe vivo e risponderebbe 404 solo al momento del resize (per
// costruzione: un'istanza senza immagini non va in crash all'avvio). Chiedere
// a tutti e tre e confrontare gli elenchi fa emergere subito la differenza,
// che e' esattamente il motivo per cui /api/images esiste.
let sourceBytes = new Map();

async function loadCatalog() {
  const answers = await Promise.allSettled(
    BACKENDS.map(async (backend) => {
      const response = await fetch(api(backend, 'images'));
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = await response.json();
      return { backend, images: body.images ?? [] };
    })
  );

  const reachable = answers.filter((a) => a.status === 'fulfilled').map((a) => a.value);
  const unreachable = answers
    .map((a, i) => (a.status === 'rejected' ? `${BACKENDS[i].label} (${a.reason.message})` : null))
    .filter(Boolean);

  if (reachable.length === 0) {
    els.images.innerHTML = '';
    setStatus(
      'Nessuno dei tre backend ha risposto. Se la console mostra un errore CORS, ' +
        "l'origine di questa pagina non e' ancora nell'allowlist delle function app.",
      'error'
    );
    return;
  }

  // Solo le immagini presenti su TUTTI i backend raggiungibili finiscono nel
  // selettore: offrirne una che un backend non ha significherebbe far scegliere
  // all'utente un 404 garantito.
  const names = reachable
    .map((r) => new Set(r.images.map((i) => i.name)))
    .reduce((shared, current) => new Set([...shared].filter((n) => current.has(n))));

  const divergent = reachable.filter((r) => r.images.length !== names.size);

  sourceBackend = reachable[0].backend;
  sourceBytes = new Map(reachable[0].images.map((i) => [i.name, i.bytes]));

  els.images.replaceChildren(
    ...[...names].sort().map((name, index) => {
      const option = document.createElement('label');
      option.className = 'option';
      // La prima parte gia' selezionata: aprire il pannello e trovare tutto
      // deselezionato costringerebbe a un click in piu' prima di far vedere
      // qualcosa, che dal vivo e' un tempo morto.
      option.innerHTML = `
        <input type="checkbox" value="${escapeHtml(name)}" ${index === 0 ? 'checked' : ''}>
        <img src="${escapeHtml(sourceUrl(name))}" alt="" loading="lazy">
        <span class="option-text">
          <span class="option-name">${escapeHtml(name)}</span>
          <span class="option-size">${formatBytes(sourceBytes.get(name))}</span>
        </span>
      `;
      return option;
    })
  );

  els.run.disabled = false;

  const warnings = [];
  if (unreachable.length) warnings.push(`non raggiungibili: ${unreachable.join(', ')}`);
  if (divergent.length) {
    warnings.push(
      `elenchi diversi fra i backend: ${divergent.map((d) => d.backend.label).join(', ')}`
    );
  }
  setStatus(
    warnings.length
      ? `⚠️ ${warnings.join(' · ')}`
      : `${names.size} immagini disponibili su tutti e tre.`,
    warnings.length ? 'warn' : ''
  );
}

const selectedImages = () =>
  [...els.images.querySelectorAll('input[type="checkbox"]:checked')].map((input) => input.value);

// --- Esecuzione --------------------------------------------------------------

async function runOne(backend, image, params) {
  const base = { image, width: params.width, quality: params.quality };

  // Due richieste, e la ragione e' che il contratto ne fa due cose diverse:
  // senza `return` l'endpoint risponde JSON con le misure, con `return=image`
  // risponde il JPEG. L'immagine si chiede con count=1 perche' `count` e' una
  // manopola sul TEMPO e non sul risultato — i test dei tre linguaggi
  // verificano proprio che l'output non cambi al variare di count.
  const metricsUrl = `${api(backend, 'resize')}?${buildQuery({ ...base, count: params.count })}`;
  const imageUrl = `${api(backend, 'resize')}?${buildQuery({ ...base, count: 1, return: 'image' })}`;

  const metricsResponse = await fetch(metricsUrl, { method: 'POST' });
  if (!metricsResponse.ok) {
    let detail = '';
    try {
      detail = (await metricsResponse.json()).error ?? '';
    } catch {
      /* un errore senza corpo JSON non deve nascondere lo status code */
    }
    throw new Error(`HTTP ${metricsResponse.status}${detail ? ` — ${detail}` : ''}`);
  }
  const metrics = await metricsResponse.json();

  const imageResponse = await fetch(imageUrl, { method: 'POST' });
  if (!imageResponse.ok) throw new Error(`HTTP ${imageResponse.status} sull'immagine`);

  const objectUrl = URL.createObjectURL(await imageResponse.blob());
  liveObjectUrls.push(objectUrl);
  return { metrics, objectUrl };
}

// --- Rendering ---------------------------------------------------------------

// Una "posa": l'immagine piu' la lente circolare che ne ingrandisce i pixel.
//
// La lente e' la parte che rende VISIBILE il resize invece di raccontarlo.
// Tutte e quattro le lenti di un gruppo usano la stessa scala percentuale e la
// stessa posizione, quindi inquadrano la STESSA porzione di figura: quella
// dell'originale ha piu' pixel sorgente da mostrare su quello spazio e resta
// nitida, quelle dei risultati ne hanno meno e si sgranano in blocchi.
//
// E' un confronto onesto solo perche' le quattro immagini sono mostrate anche
// alla STESSA dimensione sullo schermo: per questo la card dell'originale e'
// larga esattamente quanto una colonna e non di piu'. Mostrarla piu' grande la
// farebbe sembrare piu' nitida per un motivo che non c'entra col resize.
function shot(url, alt) {
  const box = document.createElement('div');
  box.className = 'shot';
  box.style.setProperty('--shot', `url("${url}")`);

  const img = document.createElement('img');
  img.src = url;
  img.alt = alt;

  // L'aspect-ratio si prende dall'immagine vera appena arriva. Senza, il
  // contenitore non combacia con la figura e la lente inquadrerebbe un punto
  // diverso da quello su cui sta il cursore.
  img.addEventListener('load', () => {
    if (img.naturalWidth && img.naturalHeight) {
      box.style.aspectRatio = `${img.naturalWidth} / ${img.naturalHeight}`;
    }
  });

  const lens = document.createElement('span');
  lens.className = 'loupe';
  lens.setAttribute('aria-hidden', 'true');

  box.append(img, lens);
  return box;
}

function sourceCard(image) {
  const card = document.createElement('article');
  card.className = 'card source';

  const tag = document.createElement('p');
  tag.className = 'card-tag';
  tag.textContent = 'Originale';

  const meta = document.createElement('p');
  meta.className = 'card-meta';
  meta.textContent = `${formatBytes(sourceBytes.get(image))} · lo stesso file per i tre worker`;

  card.append(tag, shot(sourceUrl(image), `Immagine di partenza: ${image}`), meta);
  return card;
}

function pendingCard(backend) {
  const card = document.createElement('article');
  card.className = `card out ${backend.id} pending`;
  card.innerHTML = `
    <p class="card-tag">${escapeHtml(backend.label)}</p>
    <div class="skeleton"></div>
    <p class="card-meta muted">in attesa della risposta…</p>
  `;
  return card;
}

// Riempie una card arrivata e restituisce l'elemento della barra, che il
// chiamante ridimensiona quando conosce il piu' lento del gruppo.
function fillResult(card, backend, { metrics, objectUrl }, image) {
  const before = sourceBytes.get(image);
  const saved = before ? `−${Math.round((1 - metrics.output_bytes / before) * 100)}%` : '';

  card.className = `card out ${backend.id} landed`;
  card.replaceChildren();

  const tag = document.createElement('p');
  tag.className = 'card-tag';
  tag.innerHTML = `${escapeHtml(backend.label)} <span class="runtime">${escapeHtml(metrics.runtime)}</span>`;

  const ms = document.createElement('p');
  ms.className = 'ms';
  ms.innerHTML = `${Math.round(metrics.total_ms).toLocaleString('it-IT')}<small> ms</small>`;

  const track = document.createElement('div');
  track.className = 'bar';
  const fill = document.createElement('span');
  track.append(fill);

  const meta = document.createElement('p');
  meta.className = 'card-meta';
  meta.innerHTML =
    `${metrics.width} × ${metrics.height} · ${formatBytes(metrics.output_bytes)}` +
    (saved ? ` <span class="saved">${saved}</span>` : '');

  card.append(tag, shot(objectUrl, `Risultato del resize su ${backend.label}`), ms, track, meta);
  return fill;
}

function fillError(card, backend, error) {
  card.className = `card out ${backend.id} failed`;
  card.innerHTML = `<p class="card-tag">${escapeHtml(backend.label)}</p><p class="error">${escapeHtml(error.message)}</p>`;
}

// Le barre sono in scala sul PIU' LENTO DEL GRUPPO, non su un massimo globale.
//
// Il confronto che la demo fa e' fra i tre runtime sulla stessa immagine; con
// una scala globale, le barre dell'immagine piu' piccola diventerebbero tre
// monconi indistinguibili e proprio quel confronto sparirebbe. Il valore
// assoluto non si perde: sta scritto grande sopra la barra.
//
// Si ricalcola a ogni arrivo, non solo alla fine: cosi' la prima card che
// atterra mostra subito una barra piena, e le altre la ridimensionano mentre
// arrivano. La transizione CSS rende il riassestamento leggibile invece che
// brusco.
function rescaleBars(landed) {
  const slowest = Math.max(...[...landed.values()].map((entry) => entry.ms));
  for (const entry of landed.values()) {
    entry.fill.style.width = `${Math.max(2, (entry.ms / slowest) * 100)}%`;
  }
}

// Converte "il cursore sta alla frazione f dell'immagine" nella percentuale da
// dare a background-position.
//
// Non e' l'identita', ed e' una trappola facile: una percentuale di
// background-position non significa "mostra il punto al f% dell'immagine", ma
// "allinea il f% dell'immagine col f% del contenitore". Con l'immagine
// ingrandita LENS_ZOOM volte, la finestra inquadra la frazione
// (ZOOM*f - 0.5) / (ZOOM - 1). Usare f cosi' com'era faceva inquadrare alla
// lente un punto diverso da quello indicato, tanto piu' sbagliato quanto piu'
// ci si allontanava dal centro.
const LENS_ZOOM = 5; // deve restare allineato a `background-size` in styles.css

function lensPosition(fraction) {
  const raw = ((LENS_ZOOM * fraction - 0.5) / (LENS_ZOOM - 1)) * 100;
  // Oltre i bordi non c'e' immagine da mostrare: il clamp e' cio' che tiene la
  // lente piena invece di farci entrare una fetta di sfondo.
  return `${Math.min(100, Math.max(0, raw))}%`;
}

// Un gruppo per immagine, a piramide: l'originale in cima, le frecce che si
// diramano, i tre risultati sotto in colonna sotto il rispettivo logo.
function createGroup(image) {
  const group = document.createElement('section');
  group.className = 'group';

  const title = document.createElement('h2');
  title.className = 'group-title';
  title.innerHTML = `${escapeHtml(image)} <span class="muted">${formatBytes(sourceBytes.get(image))}</span>`;

  const stage = document.createElement('div');
  stage.className = 'stage';

  const fan = document.createElement('div');
  fan.className = 'fan';
  fan.setAttribute('aria-hidden', 'true');
  fan.innerHTML =
    '<span class="fan-stem"></span><span class="fan-bar"></span>' +
    '<span class="fan-drop" style="--col:1"></span>' +
    '<span class="fan-drop" style="--col:2"></span>' +
    '<span class="fan-drop" style="--col:3"></span>';

  const row = document.createElement('div');
  row.className = 'row';

  const cards = new Map();
  for (const backend of BACKENDS) {
    const card = pendingCard(backend);
    cards.set(backend.id, card);
    row.append(card);
  }

  stage.append(sourceCard(image), fan, row);
  group.append(title, stage);

  // Muovendo il mouse su una qualunque delle quattro immagini, TUTTE e quattro
  // le lenti si spostano insieme sullo stesso punto della figura. E' il gesto
  // che fa vedere il confronto dal vivo invece di lasciarlo dedurre; fermo, il
  // valore di default inquadra comunque il centro, quindi la pagina dice la
  // sua anche senza che nessuno tocchi il mouse.
  stage.addEventListener('mousemove', (event) => {
    const box = event.target.closest('.shot');
    if (!box) return;
    const rect = box.getBoundingClientRect();
    stage.style.setProperty('--lx', lensPosition((event.clientX - rect.left) / rect.width));
    stage.style.setProperty('--ly', lensPosition((event.clientY - rect.top) / rect.height));
  });

  return { group, cards };
}

els.form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const images = selectedImages();
  if (images.length === 0) {
    setStatus('Seleziona almeno un’immagine.', 'warn');
    return;
  }

  const params = {
    width: els.width.value,
    quality: els.quality.value,
    count: els.count.value,
  };

  els.run.disabled = true;
  // Prima di buttare via i risultati precedenti, libera i blob che tenevano
  // vive le loro immagini: staccare i nodi dal DOM da solo non lo fa.
  revokeLiveObjectUrls();
  els.results.replaceChildren();
  els.legend.hidden = false;

  let failures = 0;

  // Le immagini si eseguono UNA PER VOLTA, i tre backend in parallelo fra loro.
  //
  // Non e' una semplificazione: con la concorrenza server-side a 1, mandare tre
  // immagini insieme darebbe a ciascuna app tre richieste simultanee, quindi due
  // istanze da far nascere e due cold start da guardare in silenzio davanti al
  // pubblico. Sequenziale, ogni worker resta sulla sua istanza calda. In piu' i
  // blocchi compaiono a mano a mano, invece che tutti insieme dopo l'attesa.
  for (const [index, image] of images.entries()) {
    setStatus(`Immagine ${index + 1} di ${images.length}: ${image}…`);

    const { group, cards } = createGroup(image);
    els.results.append(group);

    const landed = new Map();

    await Promise.all(
      BACKENDS.map(async (backend) => {
        const card = cards.get(backend.id);
        try {
          const result = await runOne(backend, image, params);
          const fill = fillResult(card, backend, result, image);
          landed.set(backend.id, { ms: result.metrics.total_ms, fill });
          rescaleBars(landed);
        } catch (error) {
          failures += 1;
          fillError(card, backend, error);
        }
      })
    );
  }

  els.run.disabled = false;
  setStatus(
    failures > 0
      ? `⚠️ ${failures} richieste fallite su ${images.length * BACKENDS.length}.`
      : 'Fatto. I risultati non sono byte per byte identici fra i tre, ed e’ atteso: encoder diversi.',
    failures > 0 ? 'warn' : ''
  );
});

els.run.disabled = true;
loadCatalog();
