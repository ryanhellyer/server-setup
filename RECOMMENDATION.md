# Server hosting recommendation

**Prepared:** September 2026
**Subject:** Replacement/right-sizing of the production web server (`pressabl`, currently Netcup VPS 2000 ARM G11 VIE)
**Context:** Full containerised rebuild (see `PODMAN_PLAN.md`, `README.md`) with ~15 sites / ~45 domains, low traffic, storage-heavy.

> ### Important update (verified 23 September 2026)
> Netcup has retired the old VPS **G11/G12** generations and now sells **G12.5** only. Both the ARM and x86 G12.5 lines have **roughly halved the disk** at each tier and **raised prices substantially** compared with what you pay. Your current plan is therefore a **legacy contract that can no longer be ordered** — and it is now far better value than anything Netcup currently sells.
>
> **Direct answer to "does Netcup still have my deal?": No.** The closest current plan by RAM is VPS 2000 G12.5 (8 vCore / 16 GB / **256 GB**), which lists at **€22.89–30.96/mo incl. VAT** — versus your ~**€13.41/mo** for 10 vCore / 16 GB / **512 GB**. Matching your 512 GB instead requires VPS 4000 G12.5 at **€38.60–52.16/mo incl. VAT**.
>
> **Consequence:** the recommendation flips from "downsize within Netcup" to **"keep your existing contract"**. Replacing it costs 2–4× as much for the same or less disk.

---

## 1. Bottom line

| Rank | Option | Monthly (compute + existing 1 TB Storage Box) | Where | Why / why not |
|---|---|---|---|---|
| **1 (strongly recommended)** | **Keep the existing Netcup VPS 2000 ARM G11** | **~€17.20** (unchanged) | Vienna (or migrate in place) | Now a legacy bargain: 10 vCore / 16 GB / 512 GB. No currently orderable plan matches it below **~€42/mo**. Run the container rebuild on it. |
| **1b (cheapest way to add a second box)** | **Contabo Storage VPS 20 / 30** + keep Storage Box | **~€10–18** | Lauterbourg, FR (EU hub) | If you want a separate new box anyway, this is the only way to stay near your old price with more disk. Caveats: CPU steal/oversubscription, SATA SSD, undisclosed RAID, slow support. |
| 2 (if you must stay at Netcup on a new box) | **Netcup VPS Lite 3 G12.5s** (8 vCore / 16 GB / 320 GB SSD) | **~€17.70–20.50** | Nuremberg/Vienna/Amsterdam (fixed) | Best current Netcup value, but SSD, 99.0% SLA and 320 GB. The regular VPS 2000 G12.5 costs more for less disk. |
| 3 (if Berlin is a hard requirement) | **Strato VPS L** (Berlin DCs) or **IONOS VPS L+** (Frankfurt) | **~€24–26** regular | Berlin / Frankfurt | Genuinely German DCs and polished consoles, but ~1.5–2× the Netcup price for the same size. |
| Avoid | Netcup G12.5 regular VPS/Root Server; Hetzner Cloud compute; OVH for storage | — | — | Paying 2–4× for less disk, 2026 price hikes + missing stock, or too little storage for the money. |

**Also keep in every scenario:** the existing **Hetzner Storage Box BX11 (1 TB, €3.20/mo net)**. Still the best €/TB available, unchanged in price in 2026, and already wired into your restore procedure.

---

## 2. Current setup (as measured)

| Resource | Value | Comment |
|---|---|---|
| Provider / plan | Netcup **VPS 2000 ARM G11**, Vienna (`VIE iv`) | 10 ARM vCores (Ampere Neoverse-N1), 16 GB RAM, 512 GB NVMe |
| Disk | 504 GB volume, **228 GB used (48%)** | Comfortable headroom today |
| RAM | 15.9 GB total, **3.8 GB used**, ~12 GB available | Massive headroom; 16 GB is not needed |
| CPU | Load 0.10–0.52, 98% idle | 1–2 cores would mostly cope; 4 is comfortable |
| Swap | **0** | Should be added on any rebuild (the repo does this automatically) |
| Bulk storage | Hetzner Storage Box (1 TB) via sshfs at `/var/gmail`, `/var/databases`, `/var/yandex-disk` | **585 GB used**, same box mounted three times |
| Approx. cost | **€11.27 net compute** (~€13.4–13.5 incl. VAT) **+ €3.20 net Storage Box** | ≈ **€16.6–17.2/month incl. VAT** |

### What the numbers say

- **CPU and RAM are over-provisioned.** You previously ran this on 512 MB / 1 core with only minor issues; the container stack has a documented 2 GB test profile (`PODMAN_PLAN.md` §13). The real production minimum is ~4 GB; comfortable is 8 GB.
- **Disk is the resource that decides everything.** ~228 GB local + ~585 GB external. Local disk must hold live web roots + MariaDB data; the Storage Box stays for backups/archives.
- **The Storage Box is independent of the compute provider** — any host can keep using it, so it does not influence the VPS vendor choice.
- **Your plan is grandfathered.** Netcup applied an 18.51% increase to existing contracts on 1 May 2026, so your actual invoice may now be a little above the figures above — but still nowhere near replacement cost.

---

## 3. Requirements (confirmed)

1. **Europe required; Germany strongly preferred; Berlin ideal** (but flexible for a cheaper price).
2. **Minimum 2 GB RAM** (16 GB not needed).
3. **Reduce monthly cost** if possible without a quality collapse.
4. **Low traffic** — any unlimited/flat traffic plan qualifies; bandwidth caps are irrelevant.
5. **Plenty of disk, modest growth** — plan for ~230 GB local today with headroom, and keep ~585 GB of bulk/backup data on cheap storage.
6. **Host must run the Podman/Compose stack** (Ubuntu 26.04 recommended, custom images/ISO helpful for the eventual Fedora CoreOS path).
7. **Migration is happening anyway** as part of the containerisation project, so switching providers costs little extra effort.

---

## 4. Provider analysis

### 4.1 Netcup (incumbent) — Germany: Nuremberg; also Vienna, Amsterdam

**The old G11/G12 lines are gone.** Generation 12 products are "generally no longer available for purchase"; there is no in-place upgrade from G12 to G12.5 (you order a new server and migrate). ARM is no longer cheaper than x86 — both G12.5 lines carry the same specs and prices.

**VPS G12.5 (x86 and ARM are identical)** — prices **incl. 19% VAT**; selectable term:

| Plan | vCores | RAM | Storage | 1-month | 12-month | 24-month |
|---|---|---|---|---|---|---|
| VPS 500 G12.5 | 2 | 4 GB | 64 GB SSD | €9.50 | €8.26 | ~€7.03 |
| VPS 1000 G12.5 | 4 | 8 GB | 128 GB SSD | €16.68 | €14.50 | ~€12.34 |
| VPS 2000 G12.5 | 8 | 16 GB | 256 GB SSD | €30.96 | €26.92 | €22.89 |
| VPS 4000 G12.5 | 12 | 32 GB | 512 GB SSD | €52.16 | €45.36 | ~€38.60 |
| VPS 8000 G12.5 | 16 | 64 GB | 1 TB SSD | €77.16 | €67.11 | ~€57.10 |

- **Location:** "No preference Europe" (DE/AT/NL) is included. Choosing **Nuremberg, Vienna or Amsterdam adds ~€3.43/mo**; IPv6-only saves €0.60.
- **Your legacy plan vs the nearest current equivalents:** you pay ~€13.41 for 10 cores / 16 GB / **512 GB**. The RAM-matched VPS 2000 G12.5 gives only **256 GB** for €22.89–30.96; the disk-matched VPS 4000 G12.5 costs €38.60–52.16. **Replacement is 1.7×–3.9× your price.**
- **VPS Lite G12.5s** (currently the best value new orders; no location choice, Nuremberg/Vienna/Amsterdam subject to availability):

| Plan | vCores | RAM | Storage | Displayed price (incl. VAT) |
|---|---|---|---|---|
| VPS Lite 1 | 2 | 4 GB | 80 GB SSD | €5.86 |
| VPS Lite 2 | 4 | 8 GB | 160 GB SSD | €9.50 |
| **VPS Lite 3** | **8** | **16 GB** | **320 GB SSD** | **€16.66** |
| VPS Lite 4 | 16 | 32 GB | 640 GB SSD | €30.86 |

  Longer terms have historically been cheaper (e.g. the earlier net figures of €4.10 / €6.65 / €11.67 / €21.61 for Lite 1–4); verify at checkout. Trade-offs: SSD (not NVMe), **99.0% availability** (vs 99.6%), lower port speeds, and a fair-use throttle based on sustained rate. For your traffic all of that is academic, but the SLA difference is real.
- **Root Server G12.5** (dedicated cores, 99.9% SLA, 30-day money-back): RS 1000 = 4 cores / 8 GB / 128 GB €25.00/mo (12M). More than double the old RS 1000 G12 price. Not a value play anymore.
- **Local Block Storage: €0.012/GB/month net** (€12.29/TB net) — 4× the Storage Box per TB; only for data that truly needs low latency.
- Custom images/ISO import, snapshots, DDoS protection and rescue console included. The console/CCP interface remains the main ergonomic complaint.

Verdict: **Netcup is no longer the value leader it was.** The only reason to stay is your legacy contract, which is excellent and should not be discarded.

### 4.2 Contabo — cheapest resources per euro (EU hub: Lauterbourg, FR; HQ Munich)

Prices **include VAT** (varies by country); the lower figure is the effective rate on a 24-month term.

| Plan | vCores | RAM | Storage | Port | €/mo list | €/mo 24-month |
|---|---|---|---|---|---|---|
| Storage VPS 10 | 2 | 4 GB | 300 GB SSD | 200 Mbit/s | 5.50 | 4.40 |
| **Storage VPS 20** | **3** | **8 GB** | **400 GB SSD** | 300 Mbit/s | 7.50 | 6.00 |
| **Storage VPS 30** | **6** | **18 GB** | **1 TB SSD** | 600 Mbit/s | 14.00 | 11.20 |
| Storage VPS 40 | 8 | 30 GB | 1.2 TB SSD | 800 Mbit/s | 25.00 | 20.00 |
| Storage VPS 50 | 14 | 50 GB | 1.4 TB SSD | 1 Gbit/s | 37.00 | 29.60 |
| Cloud VPS 8 | 8 | 24 GB | 300 GB SSD | 600 Mbit/s | — | 11.20 |

Notes:
- **Now the clear price/performance winner** versus current Netcup list pricing. A single Storage VPS 30 could hold everything (813 GB at 79%), though you should still keep an off-site copy.
- **Location:** EU hub is **Lauterbourg, France (French–German border)** — no location fee; German DCs were decommissioned in 2025. So it is EU, but not Germany.
- **Real trade-offs** (documented across independent 2025–2026 reviews): aggressive CPU/RAM oversubscription and CPU steal; SATA SSD (not NVMe) on Storage VPS; **RAID level not disclosed**; network throughput measured as low as ~292 Mbit/s in one third-party test; ticket support typically 24–72 h; no nested virtualisation.
- Extra storage (example: 200 GB ≈ €2.45/mo) and Object Storage (~€2.49/250 GB/mo ≈ €10/TB) are both worse than the Hetzner Storage Box.
- For low-traffic web hosting the performance is usually adequate, but this is the option that most shifts risk onto you: off-site backups and a parallel test period are essential.

Verdict: **the budget pick**, and now the most cost-effective alternative to your legacy contract. Genuine caveats; treat as "cheap tier" rather than premium.

### 4.3 IONOS — polished, German, expensive after the promo

German prices incl. 19% VAT (ionos.de). US prices (ionos.com) in brackets.

| Plan | vCores | RAM | NVMe | Regular €/mo | Promo (3 months) | Setup |
|---|---|---|---|---|---|---|
| VPS S+ | 1 | 2 GB | 60 GB | 5 (US $6) | 2 | €10 |
| VPS M+ | 2 | 4 GB | 120 GB | 12 (US $14) | 4 | €10 |
| **VPS L+** | **4** | **8 GB** | **240 GB** | **22 (US $25)** | **7** | €10 |
| VPS XL+ | 8 | 16 GB | 480 GB | 41 (US $47) | 12 | €10 |
| VPS XXL+ | 12 | 24 GB | 720 GB | 59 (US $68) | 17 | €10 |

Notes:
- x86 only; 99.99% availability, unlimited 1 Gbps traffic, free support, 1-click apps, clean console — the nicest day-to-day experience of the value hosts.
- **The promo is only for the first 3 months with a 1-year term.** Effective first-year cost for L+ is ~€18.25/mo + €10 setup; from year 2 it is €22/mo. Even the largest VPS+ (720 GB) is €59/mo.
- Germany is a location option (Frankfurt for VPS+; IONOS Cloud additionally has a **Berlin** region, if Berlin matters). UK/ES/US also available. Extra IPv4 $5/mo; Plesk $6/mo; backup from $0.065/GB/mo.
- For your data size the storage-per-euro is poor: even the largest VPS+ has less local disk than your current 512 GB, at 3× the price.

Verdict: good host, **poor value for this storage-heavy, low-traffic profile** unless you specifically want IONOS's support/SLA or a Berlin/Frankfurt location.

### 4.4 Strato — the realistic Berlin option

Berlin-based (IONOS Group), own ISO 27001 DCs in **Berlin** (and Karlsruhe). Prices incl. VAT, official list:

| Plan | vCores | RAM | NVMe | €/mo regular | Promo (3 months) | Setup |
|---|---|---|---|---|---|---|
| VPS S | 1 | 2 GB | 60 GB | 4 | 2 | €9 |
| VPS M | 2 | 4 GB | 120 GB | 10 | 3 | €9 |
| **VPS L** | **4** | **8 GB** | **240 GB** | **20** | **5** | €9 |
| VPS XL | 8 | 16 GB | 480 GB | 39 | 8 | €9 |
| VPS XXL | 12 | 24 GB | 720 GB | 56 | 10 | €9 |

Notes:
- Berlin data centre (plus optional Spain/France locations for a small surcharge) — the only mainstream host here that puts you in Berlin by default.
- Same "promo then regular price" pattern; 12-month commitment is standard; setup fee on monthly terms.
- Consumer-grade positioning and mixed user reviews (e.g., 3.3/5 on hosttest); verify Ubuntu 26.04 image availability before ordering.

Verdict: **the pick only if Berlin is a genuine requirement**, not for value.

### 4.5 Hetzner — keep the Storage Box, avoid the cloud

- **Hetzner raised prices 2–3 times in 2026** (April, June; CPX/CCX roughly doubled to tripled). The cheap CX/CAX cost-optimised cloud tiers have been **marked unavailable for new orders since September 2026**; the cheapest orderable shared instance is now CPX22 (4 GB / 80 GB) at €19.49+ — not competitive for this workload.
- The **Storage Box did not increase**: BX11 1 TB = €3.20/mo net (BX21 5 TB = €10.90). Unlimited traffic, snapshots, sub-accounts, SSH/SFTP/rsync/Borg/WebDAV. Still the best bulk-storage product in Europe for your needs.
- German locations: Nuremberg/Falkenstein (plus Helsinki) — so the Storage Box already satisfies your Germany preference for the bulk data.

Verdict: **keep the Storage Box; do not move compute here** at current prices/stock.

### 4.6 Others briefly

| Provider | Offer | Verdict |
|---|---|---|
| **OVHcloud** | VPS-1 2/4 GB/40 GB $4.54, VPS-2 4/8 GB/75 GB $8.50, VPS-3 6/12 GB/100 GB $12.32, VPS-4 8/24 GB/200 GB $23.37; EU DCs incl. Frankfurt/Gravelines | Good network/DDoS, but **local disks too small** for your data and add-on storage is expensive. Not a fit. |
| **HostHatch** | Storage VMs: 1 TB HDD $5 (1 GB RAM), 2 TB $9, 4 TB $16; Compute NVMe 4 GB/20 GB $6, 8 GB/35 GB $9; EU: Amsterdam, Stockholm, Zurich, Oslo, Helsinki, London (no Germany) | Legit cheap combo (Compute 8 GB + Storage 1 TB ≈ $14) but two small VMs, HDD bulk storage, no German location. |
| **BuyVM / Frantech** | Luxembourg (EU): KVM slice 2 GB/40 GB $7, 4 GB/80 GB $15; attachable Block Storage Slabs 256 GB $1.25, 1 TB $5; Storage VPS 1 TB $30 | Excellent cheap storage, but entry slice is fair-share CPU and Luxembourg-only in the EU. Niche. |
| **RackNerd** | Cheap VPS specials in Frankfurt/Strasbourg (e.g., 4 GB/60 GB ≈ $60/yr); large storage only via dedicated servers ($139+/mo) | Cheap compute, no storage sweet spot for this workload. |
| **HostBrr, InterServer, etc.** | Storage boxes from ~€2.00–2.50/TB; InterServer storage VPS in the US | Only relevant as cheaper Storage Box alternatives; Hetzner's is good enough and already integrated. |

---

## 5. Effective monthly cost (compute + existing 1 TB Storage Box)

All totals include the €3.20 net Storage Box (≈ €3.81 incl. VAT) unless noted. Netcup figures are incl. 19% VAT.

| Configuration | Compute €/mo | + Storage Box | **Total €/mo** | vs today |
|---|---|---|---|---|
| **Today: Netcup ARM VPS 2000 G11 (10c/16 GB/512 GB) — legacy** | 13.41 incl | 3.81 | **≈ €17.20** | — |
| **Keep it (recommended)** | 13.41 | 3.81 | **≈ €17.20** | **€0 (best value on the market)** |
| Contabo Storage VPS 20 (3c/8 GB/400 GB) | 6.00–7.50 incl | 3.81 | **≈ €9.81–11.31** | −€5.9 to −€7.4 |
| Contabo Storage VPS 30 (6c/18 GB/1 TB) | 11.20–14.00 incl | 3.81 | ≈ €15.01–17.81 | −€2.2 to +€0.6 |
| Netcup VPS Lite 3 G12.5s (8c/16 GB/320 GB) | 16.66 incl (or ~13.89 long-term) | 3.81 | ≈ €17.70–20.47 | +€0.5 to +€3.3 |
| Netcup VPS 2000 G12.5 (8c/16 GB/256 GB) | 22.89–30.96 incl | 3.81 | ≈ €26.70–34.77 | +€9.5 to +€17.6 |
| Netcup VPS 4000 G12.5 (12c/32 GB/512 GB) — disk match | 38.60–52.16 incl | 3.81 | ≈ €42.41–55.97 | +€25.2 to +€38.8 |
| IONOS VPS L+ (4c/8 GB/240 GB) | 22 incl (first-year avg ≈ 18.25 + €10 setup) | 3.81 | ≈ €25.81 (year 2) | +€8.6 |
| Strato VPS L (4c/8 GB/240 GB, Berlin) | 20 incl | 3.81 | ≈ €23.81 | +€6.6 |
| Hetzner CPX22 (4 GB/80 GB) + box | 19.49 net | 3.81 | ≈ €27.0 | +€9.8 |

Storage-only comparison for the bulk data, because that is where the money is:

| Product | Capacity | €/TB/mo | Notes |
|---|---|---|---|
| Hetzner Storage Box BX11/BX21 | 1 / 5 TB | **€3.20 / €2.18** | Keep this |
| Netcup Local Block Storage | any | €12.29 net | Local NVMe latency |
| Contabo Object Storage | any | ≈ €10 | S3-compatible, EU |
| IONOS Object Storage / HiDrive | any | varies (higher) | — |

---

## 6. Recommendation in detail

### 6.1 Primary: keep the existing Netcup ARM VPS 2000 G11 contract

- It is now **irreplaceable on price**: 10 vCore, 16 GB, 512 GB NVMe for ~€13.41/mo incl. VAT. The closest currently orderable Netcup plan with your RAM (VPS 2000 G12.5) gives **half the disk for ~1.7–2.3× the price**; the one with your disk (VPS 4000 G12.5) costs **~3×**.
- **Do not cancel and re-order**, and **do not upgrade** to a G12.5 plan expecting better value — there is no cross-generation upgrade, and the new tiers are worse.
- Because the container stack is designed to be rebuilt from scratch on any host, you can perform the migration **on this server** (install to `~/server-setup`, restore from the Storage Box, cut DNS over) rather than moving to a new one. If you want a staging box for a risk-free cutover, use a cheap temporary VPS (Contabo/IONOS promo) and leave production on the legacy contract.
- The console UX complaint is a real annoyance, but it is not worth paying 2–4× to escape.
- Optional housekeeping: confirm your current renewal price (the May 2026 +18.51% adjustment may apply), and add swap as part of the rebuild.

### 6.2 If you genuinely need a new permanent box

1. **Cheapest with more disk and similar RAM: Contabo Storage VPS 20/30** (~€10–18/mo total). Best raw value now that Netcup's list prices have risen; keep the Storage Box for off-site backups, monitor CPU steal/IO for the first weeks, and keep the legacy server until the new stack is proven.
2. **Staying at Netcup (quality, Germany): VPS Lite 3 G12.5s** — 8 vCore / 16 GB / **320 GB SSD** at €16.66 (or less on longer terms), Nuremberg/Vienna/Amsterdam. It is the best-value current Netcup product, but it is SSD with a 99.0% SLA and only 320 GB — still worse than what you have.
3. **If you need 512 GB local at Netcup:** VPS 4000 G12.5 at €38.60–52.16 — expensive; Contabo is a far cheaper way to get that disk.
4. **Dedicated CPU guarantee:** Netcup Root Server G12.5 starts at €25.00 (RS 1000, 4 dedicated cores / 8 GB / 128 GB) — more than double the old price and not needed for this workload.

### 6.3 Location-driven alternative: IONOS or Strato

- Only choose these if **Berlin/Frankfurt presence, support responsiveness or console quality** outweigh cost.
- **IONOS VPS L+** (Frankfurt, ~€22/mo regular): best support/SLA and console of the group; promo makes year 1 cheaper, but plan for the renewal price.
- **Strato VPS L** (Berlin, ~€20/mo regular): the only mainstream Berlin DC option; verify current OS image availability and accept mixed review scores.

### 6.4 Do not bother with

- **Netcup G12.5 regular VPS/Root Server** as a replacement for your legacy plan (2–4× the price for less disk).
- **Hetzner Cloud** for compute (2026 prices and unavailable cheap tiers).
- **IONOS/Strato promo pricing as a long-term strategy** (3 months only; the regular price is what matters).
- **Moving the Storage Box** to Contabo Object Storage or Netcup block storage (2–4× the cost per TB).

---

## 7. Migration notes (fits the current repo workflow)

The containerisation project is provider-agnostic; the cheapest path now is to run it on the existing server rather than migrate hosts.

1. **Decide the target:** rebuild in place on the legacy Netcup server (recommended), or stand up a new VM only if you deliberately want to leave Netcup.
2. **Before any DNS change:** ensure the target runs the supported host OS. Netcup supports custom images/ISO import (good for the future Fedora CoreOS path); Contabo supports custom images; IONOS/Strato ship recent Ubuntu images — verify 26.04 availability.
3. **Lower DNS TTLs** (e.g., 300 s) at least 24 h before cutover.
4. **Provision the host:** `install/setup.sh` → `scripts/host-setup.sh` / `deploy.sh` with `DEPLOY_ENV=production` (creates swap automatically).
5. **Re-attach bulk storage:** authorise the same SSH key on the Storage Box (`scripts/storage-mounts.sh`) — the 585 GB does not move.
6. **Restore sites/DBs:** `scripts/restore.sh` / `provision-all.sh` from the latest snapshot on `/var/databases`.
7. **Certificates and smoke test:** `scripts/certbot-issue.sh`, then hit every site by IP/Host header before touching DNS.
8. **Cut over DNS**, keep the old setup available for at least a week.
9. **Right-size `.env`.** For a 4–8 GB box (or the same profile on the legacy server) use middle-ground values rather than the 16 GB production preset:
   - `MARIADB_BUFFER_POOL`: 1–2 G (not 8 G on 8 GB)
   - `FASTCGI_CACHE_SIZE`: 128–256 M
   - `VALKEY_MAXMEMORY`: 128–256 M
   - `PHP_FPM_MAX_CHILDREN`: 15–25, `PHP_FPM_MEMORY_LIMIT`: 128–192 M
   - `SWAP_SIZE`: 2 G (always, even on 8 GB)
10. **Watch for the first month:** MariaDB disk I/O and PHP-FPM queue length — the signals for whether the sizing is right.

---

## 8. Risks and caveats

| Risk | Where | Mitigation |
|---|---|---|
| Accidentally losing the legacy contract | Netcup | Do not cancel or "upgrade" it; treat it as the production box. There is no cross-generation upgrade and G11/G12 are no longer orderable. |
| Performance variability / CPU steal | Contabo | Parallel test before cutover; note the refund window; monitor; keep backups |
| Undisclosed RAID on Storage VPS | Contabo | Treat as non-redundant: nightly off-site backups to Hetzner Storage Box |
| Promo price shock at renewal | IONOS, Strato | Compare only regular prices when evaluating; use promos to trial, not to plan |
| Price volatility (DRAM/NAND crisis) | All providers | Prefer longer terms to lock current rates; existing contracts have historically been protected longer |
| Vendor support response times | Contabo, Strato | Keep the old server until the new one has been stable for a week |
| Storage headroom on smaller new plans | Contabo 20, Netcup Lite | Confirm actual local usage (web roots vs DB vs misc) before committing to ≤ 400 GB |

---

## 9. Assumptions

- Prices verified online 23 September 2026, from provider pages and reputable trackers; they change frequently — re-check before ordering.
- Netcup G12.5 prices above are **incl. 19% VAT**, shown for 1-/12-/24-month terms; the 24-month figures for non-listed tiers are derived from Netcup's stated 26% discount (rounded). Choosing Nuremberg/Vienna/Amsterdam adds ~€3.43/mo.
- Contabo/IONOS/Strato quotes are incl. 19% VAT unless stated. Austrian VAT (20%) differs by a few cents.
- Currency: EUR unless marked USD ($). No exchange-rate conversions applied.
- The Hetzner Storage Box (1 TB, 585 GB used) is retained in all scenarios and costs €3.20/mo net.
- Traffic remains low; no plan considered here will hit fair-use/bandwidth limits.
- Migration effort is excluded from the cost comparison because the container rebuild happens regardless of provider.

---

## 10. Sources

- Netcup: netcup.com product pages — VPS G12.5, VPS Lite G12.5s, ARM G12.5, Root Server G12.5, Local Block Storage (verified 23 Sept 2026); Netcup deals page and G12/G12.5 migration FAQ; earlier netcupvoucher.com pricing snapshot (Aug 2026) for historical comparison.
- Contabo: contabo.com Storage VPS and pricing pages; Contabo EU data centre documentation (Aug 2026); independent reviews (Experte, AffTank, cybernews, 2026).
- IONOS: ionos.de and ionos.com VPS+ pages (Sept 2026); IONOS Cloud region documentation (Berlin/Frankfurt).
- Strato: strato.de Linux VPS page; hosttest.de Strato review (2026).
- Hetzner: hetzner.com Storage Box pages; Hetzner price-adjustment documentation (April/June 2026); third-party price analyses (webhosting.today, hosting-tutorials.com).
- OVHcloud, HostHatch, BuyVM, RackNerd: provider pricing pages and third-party trackers (2026).
