# Handoff: chat de familie — Hermes Agent + Hermex

Starea la 2026-11-05. Acoperă doar partea de Hermes Agent + Hermex (chat pentru
teodor și teodora prin gateway, majoritar pe DeepSeek).

## Unde e

| | |
|---|---|
| Repo | `teodorio95-portofolio/secure-ai-gateway` |
| Branch | `feat/homelab-family-chat`, pornit din `homelab`, urcat pe GitHub, **nemerge-uit, fără PR** |
| Ultimul commit | `d856252` |

Commit-uri, de la cel mai vechi:

| Commit | Ce face |
|---|---|
| `6e99aad` | homelab: chart `ai-hermes`, aliasuri DeepSeek cu buget per persoană, chei, Kyverno, secrete, targeturi `hermes-*` |
| `7ef8109` | Mac: stack Docker Compose în `mac/` cu aceeași config, ca să se poată testa înainte de mini PC |
| `214fd4d` | fix `mac/test.sh` pe bash 3.2 (macOS) |
| `9054551` | modele explicite: Flash implicit, Pro la cerere; prețuri setate în config; `scripts/hermes-configure.sh` |
| `34bb927` | thinking oprit pe aliasurile Flash |
| `158918e` | fix Mac: `make mac-up` recreează LiteLLM și reînregistrează cheile când se schimbă config-ul |
| `d856252` | fix: `model_aliases` setat cu `--force` |

## Ce face

```
iPhone (Hermex) ──Tailscale──► tailscale serve ──► Hermes (unul per persoană)
                                                    │ cheie virtuală LiteLLM proprie
                                                    ▼
                                                 LiteLLM ──► api.deepseek.com
                                                    └─(buget consumat)─► local (doar pe homelab)
```

- **Câte un Hermes per persoană** (`hermes-teodor`, `hermes-teodora`), fiecare cu:
  - volum propriu: istoric, memorie, skills;
  - login propriu în dashboard (basic auth, ce cere Hermex);
  - cheie virtuală LiteLLM proprie.
- **Modele și bugete** (`values/litellm-homelab.yaml`):

  | Alias | Model DeepSeek | Thinking | Buget / lună | Când bugetul e consumat |
  |---|---|---|---|---|
  | `chat-<user>` (implicit) | `deepseek-flash` (V4.1 Flash) | oprit | 3 $ | `local` (homelab) / eroare (Mac) |
  | `chat-<user>-pro` | `deepseek-v4-pro` (V4 Pro) | pornit | 2 $ | `chat-<user>`, apoi `local` |

  - Bugetul e pe deployment, nu pe cheie: o cheie depășită ar refuza cererea, nu ar trece pe alt model. `max_budget: 15` pe cheie e doar plafon de siguranță.
  - Prețurile sunt setate în config la tariful de vârf DeepSeek (noiembrie 2026), nu luate din tabelul inclus în LiteLLM.
  - Fiecare cheie are acces doar la aliasurile proprii și la `local`.
- **În Hermes**: `/model pro`, `/model flash`, `/model pro --once`. Aliasurile vin din `model_aliases`, scrise de `scripts/hermes-configure.sh`.
- **Izolare**:
  - Hermes ajunge doar la LiteLLM (și DNS); nu are internet.
  - Dashboard-ul e accesibil doar de pe host, prin `tailscale serve`; nimic pe LAN.
  - Kyverno lasă fiecare pod să citească doar Secret-ul `hermes-<ai.user>`.
  - Cheia stă în `OPENAI_API_KEY`, nume pe care Hermes nu-l dă mai departe comenzilor agentului; în `config.yaml` e doar șablonul `${OPENAI_API_KEY}`.

## Fișiere

**Homelab (k3s):**
- `charts/ai-hermes/`: namespace `ai-hermes` (PSA `baseline`, pentru că imaginea oficială pornește ca root sub s6-overlay), PVC, Service ClusterIP fix (`10.43.219.19` / `.20`), Deployment, CiliumNetworkPolicy.
  - Imagine: `docker.io/nousresearch/hermes-agent:v0.22.7@sha256:e6d81ae5…`.
  - Securitate: 7 capabilități, `allowPrivilegeEscalation: false`, fără token de ServiceAccount.
- `gitops-homelab/ai-hermes.yaml`, `gitops-homelab/ai-gateway.yaml` și `charts/ai-gateway/values-homelab.yaml`: `api.deepseek.com` în allowlist-ul FQDN și `ai-hermes` acceptat ca client al gateway-ului.
- `bootstrap/secure-k8s-lab/secure-ai-gateway-homelab.yaml`: exclude acum și `ai-gateway.yaml` din `gitops/`.
- `values/litellm-homelab.yaml`: aliasurile, bugetele și fallback-urile.
- `values/litellm.yaml`: `DEEPSEEK_API_KEY`, opțional.
- `values/litellm-bootstrap.yaml`: `keys.json` e o listă (agentul demo + teodor + teodora); o cheie fără Secret e sărită, deci lab-ul rămâne neschimbat.
- `policies/kyverno/ai-01…`, `ai-03…` și `tests/`: Secret-ul propriu per `ai.user`, imaginea Hermes în allowlist, fixtures noi.
- `scripts/seal-secrets.sh`: `DEEPSEEK_API_KEY`; cu `WITH_HERMES=1` creează `family-virtual-keys` și `hermes-<user>`, iar login-ul îl salvează în `~/.config/secure-ai-gateway/hermes-<user>.env` (0600).
- `scripts/hermes-configure.sh`: rulat în container prin stdin, de `make hermes-configure` și de `make mac-configure`.
- `scripts/check-budget-fallback.py`: test offline cu LiteLLM 1.106.2 (pro → flash → local, cealaltă persoană neafectată); rulează și ca job în CI (`budget-fallback`).
- `scripts/verify-ai-netpol.sh`: verificări Hermes cu `HERMES=1`.
- `Makefile`: `hermes-configure`, `hermes-serve`, `hermes-status`, `check-budget-fallback`.

**Mac (Docker Compose în Colima, separat de lab-ul k3d):**
- `mac/compose.yaml`: Postgres, LiteLLM, bootstrap, `hermes-teodor`, `hermes-teodora`, `edge` (nginx TCP).
  - Hermes e doar pe rețeaua `internal`, fără ieșire spre internet.
  - Porturile sunt publicate doar pe `127.0.0.1`: `19119` / `19120` (dashboard-uri) și `14000` (LiteLLM).
- `mac/render.py`: generează config-ul LiteLLM și bootstrap-ul din `values/litellm*.yaml` în `mac/.generated/` (ignorat de git). Elimină `local`, pentru că pe Mac nu e model local.
- `mac/secrets.sh`: `mac/.env` (0600, ignorat de git), cheia DeepSeek cerută ascuns, numele din tailnet detectat automat.
- `mac/test.sh`: 8 verificări, fiecare cheie doar la aliasurile proprii.
- `mac/nginx.conf`.
- `Makefile`: `mac-secrets`, `mac-render`, `mac-up`, `mac-configure`, `mac-serve`, `mac-logins`, `mac-test`, `mac-status`, `mac-down` (cu `WIPE=1` șterge și volumele).

## Ce e verificat

- **Fallback-ul de buget**: pe LiteLLM 1.106.2, cu config-ul real (`make check-budget-fallback`).
- **Costurile** calculate de LiteLLM corespund exact prețurilor din config.
- **Thinking oprit pe Flash**, verificat printr-un proxy LiteLLM local cu DeepSeek fals: cererile normale și cele în format Hermes ajung cu `thinking: disabled`. Doar un `reasoning_effort` explicit trimis de client îl repornește; Hermes nu-l trimite pentru un endpoint custom.
- **Bootstrap-ul cheilor**, rulat pe un LiteLLM fals: idempotent.
- **`seal-secrets.sh`, `mac/secrets.sh`, `mac/test.sh` și configurarea Hermes**, cu `kubectl`, `docker` și `hermes` false; scriptul de configurare și sub `dash`.
- **`docker compose config`** valid.
- **Pe Mac, de către utilizator:**
  - stack-ul pornește;
  - `mac-test` trece pentru Flash;
  - login-ul din Hermex merge;
  - `chat-teodor` apare în dropdown.

## Ce NU e verificat

- **CI-ul** nu a rulat încă pe branch (pornește la PR): `helm lint`, kubeconform și `kyverno test`. Riscul principal e politica `ai-01`, care folosește `request.object.metadata.labels."ai.user"` în valoare.
- **Chart-ul `ai-hermes` pe k3s real**: dacă s6-overlay pornește cu cele 7 capabilități, `tailscale serve` către ClusterIP, cum vede Cilium traficul care vine de pe host.
- **`/model pro` în Hermex**, după ultimele fix-uri.

## Problemă deschisă pe Mac

`chat-teodor-pro` nu apare în dropdown-ul Hermex. Două cauze posibile:

1. **Cache-ul Hermes**: lista de modele (`/v1/models`) stă o oră în `/opt/data/provider_models_cache.json`.
2. **Cheia nu a fost actualizată** în LiteLLM. Se întâmplă dacă `make mac-up` a rulat înainte de fix-ul `158918e`.

Pașii:

```bash
( . mac/.env; curl -s http://127.0.0.1:14000/v1/models -H "Authorization: Bearer $TEODOR_KEY" ) | python3 -m json.tool | grep '"id"'
# dacă apare chat-teodor-pro → golește cache-ul (fișier temporar, Hermes îl refă):
docker compose -f mac/compose.yaml --project-directory mac --env-file mac/.env exec -T hermes-teodor rm -f /opt/data/provider_models_cache.json
# dacă lipsește → git pull && make mac-up, apoi logs bootstrap ("key teodor: exists, limits updated")
```

`/model pro` scris în chat ar trebui să meargă oricum, indiferent de dropdown.

## Comenzi

**Mac:**

```bash
git switch feat/homelab-family-chat && git pull
make mac-secrets && make mac-up && make mac-configure && make mac-serve && make mac-test
make mac-logins     # server, user, parolă pentru Hermex (nu le lipi în chat)
```

**Homelab, când vine mini PC-ul:**

```bash
WITH_PROVIDERS=1 DEEPSEEK_API_KEY=... WITH_HERMES=1 make seal-secrets   # apoi commit secrets/sealed/
# merge feat/homelab-family-chat în homelab (ArgoCD urmărește homelab)
make hermes-configure && make hermes-serve && make hermes-status
HERMES=1 make verify-ai-netpol
```

## Rămas de făcut

- [ ] **PR** `feat/homelab-family-chat` → `homelab`, ca să ruleze CI-ul. Dacă pică ceva, repari, apoi merge.
- [ ] **secure-k8s-lab**: copia din `apps/homelab/` trebuie să excludă și `ai-gateway.yaml`. Rulezi `make wire-lab-homelab`, apoi commit acolo; n-a fost acces de push.
- [ ] **Secretele pe homelab** (`WITH_HERMES=1 make seal-secrets`) și Tailscale pe telefonul Teodorei, cu acces în tailnet. Eventual o regulă ACL care o limitează la portul 9444.
- [ ] **Parolele Hermex** au fost lipite în chat pe 2026-11-05. Dacă nu s-au schimbat deja, se schimbă cu comanda `sed` pe `HERMES_*_PASSWORD` din `mac/.env`, apoi `docker compose ... up -d`.
- [ ] **Dropdown-ul pro pe Mac** (vezi mai sus).

## De știut

- **Bugetul se resetează la repornirea LiteLLM**: contorul e ținut în memorie, fără Redis. Pe Mac, `make mac-up` îl resetează ori de câte ori se schimbă config-ul. Limita reală e soldul preplătit din contul DeepSeek.
- **`deepseek-chat` nu mai apare în lista DeepSeek**, de aceea s-a trecut pe `deepseek-flash` / `deepseek-v4-pro`. Prețurile din config trebuie actualizate dacă DeepSeek le schimbă (sursa: `api-docs.deepseek.com/quick_start/pricing`).
- **Avertismentul `model_aliases … not a recognized config key` e fals.** `/model` citește exact cheia asta (`hermes_cli/model_switch.py`). Sugestia `model_overrides` e altceva.
- **Memorie**: fiecare Hermes poate lua 2 GiB. Pe homelab se adaugă la Ollama (8 GB UMA + limita de 12 GiB), stack-ul media și LiteLLM, deci e strâns. Pe Mac, stack-ul are nevoie de ~5–6 GiB în Colima pe lângă lab.
- **Istoricul de pe Mac** stă în volumele `family-chat_hermes-*` și nu se mută pe homelab.
- **Abonamentele ChatGPT / Claude** nu trec prin gateway (termenii lor). Rămân în aplicațiile oficiale; pe calea asta se plătește doar consumul prin API.
