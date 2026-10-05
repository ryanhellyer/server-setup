# Email → Telegram plan (hellyer.kiwi server)

> **Status: IMPLEMENTED IN THE REPO (not yet deployed).** The code lives in
> `mail/` (the relay), `php/` (the sendmail shim), `authelia/`, `compose.yaml`
> and `scripts/`. This document remains the design reference. Deploy with
> `sudo bash scripts/deploy.sh`, or once `TELEGRAM_*` is in `.env`, run
> `sudo bash scripts/provision-mail.sh`. See the
> [implementation checklist](#12-implementation-checklist) at the end.

---

## 1. Goal

Every message the server tries to email should arrive in a Telegram chat instead
of disappearing. That includes:

| Source | How it sends today | Wanted |
|---|---|---|
| **WordPress** (`wp_mail()` → PHP `mail()`) | vanished (no MTA) | Telegram |
| **Laravel / Symfony** (`MAIL_MAILER` / `MAILER_DSN`) | `log`, `smtp` (unreachable), or vanished | Telegram |
| **Authelia** (password reset, device registration) | filesystem notifier → `notification.txt` | Telegram |
| **Host services** (cron, fail2ban, unattended-upgrades, logwatch, certbot) | vanished / `/var/mail/root` | Telegram |
| **Future systems** (Gitea, Uptime Kuma, a new Go/Node app…) | whatever they default to | Telegram with no per-app config where possible |
| *(optional)* **Gmail** fetched by `getmail.sh` into `~/gmail` | sits in a Maildir | Telegram |

The user's own words: *"I just want everything routed to Telegram so I actually
get the messages from the server, unlike now when I just miss them all."*

---

## 2. A 60-second email primer (why mail vanishes today)

Understanding three ideas is enough:

1. **Email is a client/server protocol (SMTP).** A program either speaks SMTP to
   a server on port 25/587, or it asks the local **MTA** (mail transfer agent,
   e.g. Postfix/Exim) to send on its behalf.
2. **The universal Unix shortcut is the `/usr/sbin/sendmail` binary.** Almost
   every Unix tool — PHP's `mail()`, `cron`, `fail2ban`, `unattended-upgrades`,
   git, logwatch — does not speak SMTP itself. It just runs
   `/usr/sbin/sendmail -t` and pipes the message in, expecting *something* to
   deliver it.
3. **This server has no MTA.** So `/usr/sbin/sendmail` is missing (containers) or
   is a dead end. `mail()` fails silently and the message is gone. That is the
   entire reason server mail is "missed".

That third point is the key to the whole plan: **one program that catches mail,
and one shim that makes `/usr/sbin/sendmail` point at it, covers most of the
server automatically.** Only apps that insist on speaking SMTP themselves need a
line of config.

Two more terms used below:

* **Envelope** = the real SMTP routing addresses (`MAIL FROM:` / `RCPT TO:`).
* **Headers** = the pretty `From:` / `To:` / `Subject:` inside the message. They
  can differ from the envelope (this matters for our filter rules).

---

## 3. Architecture

```
                 ┌─────────────────────────────────────────────────────────┐
                 │  Podman compose stack (network: web, +backend internal) │
                 │                                                         │
  WordPress  ─┐  │                                                         │
  Laravel    ─┤  │  ┌──────────────┐   SMTP :25    ┌────────────────────┐  │
  Authelia   ─┼──┼─▶│  php-fpm     │──────────────▶│   mailrelay        │  │
  node apps  ─┤  │  │  (msmtp →)   │               │  (SMTP → Telegram) │  │
  future apps─┘  │  └──────────────┘               │  spool + retry     │  │
                 │  ┌──────────────┐               └─────────┬──────────┘  │
                 │  │  authelia    │──── SMTP :25 ──────────▶ │            │
                 │  └──────────────┘                          │ HTTPS      │
                 └────────────────────────────────────────────┼────────────┘
                                                              ▼
 Host (cron / fail2ban /              published 127.0.0.1:2525   api.telegram.org
 unattended-upgrades / logwatch) ─── msmtp ──────────────────▶   sendMessage /
                                                              sendDocument
                                                                    │
                                                                    ▼
                                                              📱 Telegram chat
```

There are **three capture points**, and together they mean a new app on this box
"just works" far more often than not:

1. **`mailrelay` container** — an SMTP server that accepts *any* message for
   *any* recipient and forwards it to Telegram. This is the single destination
   for everything.
2. **`sendmail` shim (msmtp)** — installed **once** in the PHP image and **once**
   on the host. It makes `/usr/sbin/sendmail` relay to `mailrelay`. Everything
   that uses the Unix mail interface (i.e. most of PHP/WordPress, cron, system
   tooling) needs **zero** per-app configuration.
3. **Explicit SMTP config in the few apps that only speak SMTP** (Authelia,
   Laravel when not using `sendmail`, any future app that hardcodes SMTP) —
   pointing at `mailrelay:25`. This is the "can't be avoided" part.

---

## 4. Why this design (the user's question)

> *"…preferably it would automatically work across various platforms rather than
> requiring SMTP configurations to be set within each app. But perhaps setting
> up SMTP configs in some apps can't be avoided?"*

**Correct on both counts:**

* **Automatic route** — the `/usr/sbin/sendmail` shim is the "various platforms"
  answer. Because nearly all Unix software and PHP-on-Unix funnel through that
  one binary, patching it once per *runtime* (PHP image, host) covers every PHP
  app and every host service forever, including ones added later. New WordPress
  site? Its `wp_mail()` already uses `mail()` → shim → Telegram. New cron job
  that mails root? Already covered. Nothing to configure.
* **Unavoidable SMTP route** — some software bypasses `sendmail` entirely and
  opens its own SMTP connection (Authelia is a concrete example in this repo; so
  is any app configured with a `MAIL_HOST`/`SMTP_HOST`). For those, one-time
  config pointing at the same `mailrelay` is the cheapest possible fix, and it
  is done centrally in this repo's provisioning scripts rather than by hand.

Alternatives considered and rejected:

| Option | Why not |
|---|---|
| Install/sign up for a real external mail provider (Gmail SMTP, SES, Mailgun…) and forward | Requires a domain, DNS (SPF/DKIM/DMARC), credentials, and outgoing port 25/587; still doesn't give Telegram; failure mode is still "missed". |
| Configure SMTP host in every single app | Exactly the per-app toil we are trying to avoid. |
| `mailrise` / `junction` images (off-the-shelf SMTP→Apprise) | Good tools, but their addressing model is recipient-encoded (`config@mailrise.xyz`) and a true catch-all needs custom routers; a ~150-line in-repo gateway is easier to reason about and matches this repo's self-contained style. Listed as a fallback in §10. |
| Full Postfix MTA on the host delivering to a `pipe` transport | Robust queue/retry, but ~10× the config, exposes an MTA on the host, and still needs the PHP-side shim. Overkill when one container can own the problem. |

**Recommendation:** build the small `mailrelay` gateway in-repo, shim `sendmail`
in PHP + host, and explicitly configure Authelia + Laravel.

### 4.1 Container or host service?

**Decision: a new container in the compose stack** (`mailrelay`), with the tiny
`msmtp` client shim *outside* (host + PHP image) — because that shim is a
client, not a service, and *must* live wherever `/usr/sbin/sendmail` is invoked.

Why the container wins here:

* **It matches every convention in this repo.** Compose is the source of truth;
  `server-stack.service` starts it at boot; `scripts/update.sh` rebuilds it;
  `restart: unless-stopped` + the stack healthcheck keep it alive; adding it to
  `lib-containers.sh` makes `pod-status`/`pod-logs` see it automatically. A host
  service would be a second, differently-supervised thing to maintain.
* **No privileged host install.** The host-software list stays minimal (just the
  `msmtp-mta` client), and the relay can't touch host files.
* **It needs outbound internet** to reach `api.telegram.org`, which the `web`
  network provides (and `backend` deliberately does not).
* **The only downside is benign:** host services reach it through the published
  `127.0.0.1:2525`, so host mail needs the stack up. `server-stack.service` is
  enabled at boot and the containers restart themselves, so if the stack is down
  the box is already degraded. msmtp logs the failure rather than hiding it.

Rejected alternative: a host-installed gateway/MTA via a systemd unit. It would
put mail config and a listener on the host, need its own update path, and
duplicate supervision outside compose — for no functional gain, since the
container is equally reachable from both containers and host.

---

## 5. Components

### 5.1 `mailrelay` — the SMTP → Telegram gateway

A new service in `compose.yaml`, built from a new `mail/` directory
(`mail/Containerfile` + `mail/gateway.py`). Python 3 on a slim Ubuntu base,
using `aiosmtpd` for the SMTP side and the standard library (`urllib.request`)
for the Telegram Bot API — no heavyweight dependencies.

Behaviour:

* **SMTP on container port 25**, no authentication (it is only reachable on the
  internal container network and a localhost-published host port — never
  publicly). The container runs as root so it can bind :25 — fine inside a
  user-namespaced podman container, and it needs no host privileges.
* Accepts **any** sender and **any** recipient (catch-all).
* Parses `From`, `To`, `Cc`, `Subject`, `Date`, `Message-ID`, and the body.
  Prefers `text/plain`; falls back to `text/html` stripped to text.
* Sends a Telegram message via `sendMessage`:
  * `Subject` as the bold first line, `From → To` + `Date` underneath, then body.
  * `parse_mode=HTML` with all injected values HTML-escaped (the bot API will
    reject unescaped `<`/`&`).
  * `disable_web_page_preview=true` (server mails are full of links).
* **Long messages:** Telegram caps text at 4096 chars. Longer bodies are sent as
  a `.txt`/`.eml` **document** via `sendDocument` with the subject as caption.
* **Attachments:** forwarded as documents/photos when small (< 50 MB); the
  original `.eml` is always available on request.
* **Durability:** each accepted message is written to a spool directory *before*
  the SMTP `250` is returned, then a background worker sends it and deletes it
  on success. Telegram/network failures retry with exponential backoff; after
  `MAIL_MAX_ATTEMPTS` the file moves to `spool/failed/` and an error is logged.
  This prevents "sent to nowhere" loss if Telegram has a bad day.
* **Rate limiting / batching:** a small queue drains at a safe rate (Telegram
  allows ~30 msg/s globally, 20/min per group). Optional burst-inbox summary
  later.
* **Filtering** (see §7): `MAIL_TELEGRAM_MODE=all|local|allowlist`. `all` is the
  default per the user's request; `local` sends only recipients in
  `MAIL_LOCAL_DOMAINS` (i.e. server-bound notices) and is the recommended
  setting if customer-facing WordPress mail must keep flowing to users.
* **Sender identity:** the default envelope sender is **`server@hellyer.kiwi`**
  (`MAIL_FROM_ADDRESS`), set in the host/PHP msmtp shims, Authelia's sender and
  Laravel's `MAIL_FROM_ADDRESS`. Apps that put their own `From` header on a
  message (WordPress does) keep it — the Telegram notification always *shows*
  the original `From`, which is how you tell sites apart. There is no
  header-rewriting option; the relay is display-only, so the envelope sender is
  what `server@hellyer.kiwi` affects.
* **Dedup:** ignore a repeated message within a short window (SMTP clients can
  retry). Key on `Message-ID` when present; since `mail()`/msmtp do not
  generate one, fall back to a hash of headers+body so the common case is
  actually covered.
* **Healthcheck:** a tiny HTTP `/health` (or an SMTP `NOOP` probe) so
  `pod-status` can see it, matching the `open-webui` pattern.

### 5.2 Transparent `sendmail` shim (`msmtp`)

**PHP image** (`php/Containerfile`):

* `apt-get install -y msmtp msmtp-mta` — `msmtp-mta` provides
  `/usr/sbin/sendmail` as an alternative, so PHP's default `sendmail_path` and
  any package that shells out to sendmail start working.
* Add `php/30-mail.ini` and `COPY` it to
  `/etc/php/8.5/fpm/conf.d/30-mail.ini`:

  ```ini
  [mail]
  sendmail_path = /usr/sbin/sendmail -t -i
  sendmail_from = server@hellyer.kiwi
  ```

* Add `/etc/msmtprc` in the image (non-secret; points at the relay):

  ```
  defaults
  auth         off
  tls          off
  syslog       LOG_MAIL

  account      mailrelay
  host         mailrelay
  port         25
  from         server@hellyer.kiwi

  account      default : mailrelay
  ```

  Because `mail()` runs as `www-data` with no `~/.msmtprc`, msmtp uses
  `/etc/msmtprc`. Result: **every WordPress and Laravel-`sendmail` message is
  captured with no per-site configuration.**

**Host** (`scripts/host-setup.sh`):

* `apt-get install -y msmtp-mta` (adds `/usr/sbin/sendmail`).
* Render `/etc/msmtprc` pointing at `127.0.0.1 2525` (the published relay port),
  `from server@hellyer.kiwi`.
* From then on, `cron`, `fail2ban`, `unattended-upgrades`, `logwatch`,
  `certbot` and any future host package that mails root are routed to Telegram.
  No `/etc/aliases` gymnastics needed, because the relay catch-alls.

> If any tool uses `sendmail -bs` (SMTP-on-stdin, which msmtp historically does
> not implement), it will be caught in testing (§9) and that app gets an
> explicit SMTP config instead. Symfony's sendmail transport and modern Laravel
> are configured via `MAIL_MAILER` (below), so this is an edge case.

### 5.3 Explicit SMTP where it can't be avoided

**Authelia** (`authelia/configuration.yml`) — replace the filesystem notifier
with SMTP. Providers are mutually exclusive, so `notifier.filesystem` goes away:

```yaml
notifier:
  disable_startup_check: false
  smtp:
    address: 'smtp://mailrelay:25'
    timeout: '5s'
    sender: 'Authelia <server@hellyer.kiwi>'
    identifier: 'auth.hellyer.kiwi'
    subject: '[Authelia] {title}'
    startup_check_address: 'admin@hellyer.kiwi'
    disable_require_tls: true    # plain SMTP on the internal network
    disable_starttls: true
```

This also lets us flip `authentication_backend.password_reset.disable` to
`false` (password resets become possible). Follow-ups: update the comments in
`configuration.yml`, retire/simplify `scripts/authelia-notify-code.sh` (no more
`notification.txt`), and make sure `scripts/provision-authelia.sh` does not
re-write a filesystem notifier.

**Laravel / Symfony** (`scripts/provision-site.sh`) — the existing
`rewrite_app_env()` already rewrites `DB_HOST`/`REDIS_HOST`. Add mail there, for
the same "runs on every restore" reason:

```ini
# Laravel
MAIL_MAILER=smtp
MAIL_HOST=mailrelay
MAIL_PORT=25
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS=server@hellyer.kiwi

# Symfony
MAILER_DSN=smtp://mailrelay:25
```

(For the shared WordPress Multisite, `wp_mail()` → `mail()` → msmtp is already
automatic. Optionally add a tiny `mu-plugin` setting a recognisable
`wp_mail_from`/`wp_mail_from_name` so Telegram messages are obviously from the
site.)

**Open WebUI** — *no config needed today, and none possible via env.* As of the
current `open-webui:main` image there is **no SMTP/email code** in the backend
(verified: no `smtp`/email module in `backend/open_webui/`), so guessed `SMTP_*`
environment variables would be inert. If/when Open WebUI gains outbound email,
point its SMTP settings at `mailrelay`, port `25`, no TLS/auth (Admin Panel →
Settings, if it exposes one). No change to `compose.yaml` is made for it now.

**Future apps:** documented one-liner in the README — point `SMTP_HOST` at
`mailrelay`, port `25`, no TLS/auth. If it uses `mail()`/`sendmail`, do nothing.

### 5.4 (Optional) Gmail Maildir → Telegram

`scripts/getmail.sh` already pulls Gmail into `~/gmail`. Optionally add a
`scripts/gmail-to-telegram.sh` (run right after `getmail.sh` in the same timer)
that walks `~/gmail/new/`, sends each unseen message through the same Telegram
formatting, and moves it to `cur/` (that is what Maildir `cur/` means). This
makes the phone the single inbox.

Caveat: this can be **very** noisy (newsletters, receipts) and mixes personal
mail with server alerts. Recommend a separate Telegram chat/thread, or only
forward a named mailbox (e.g. `Contact form`), and keep it opt-in via an `.env`
flag. Treat this as Phase 4, not part of the core.

---

## 6. Message format & Telegram specifics

Setup the user performs (see Phase 0):

1. Telegram → **@BotFather** → `/newbot` → name it (e.g. `hellyer-server`) →
   copy the **bot token** (`123456:ABC…`).
2. Create a private group (e.g. *Server Alerts*) or open a DM with the bot, send
   it any message, then read the **chat id** from
   `https://api.telegram.org/bot<TOKEN>/getUpdates` (`result[].message.chat.id`;
   groups/channels are negative, e.g. `-1001234567890`).
3. Put both in `.env` (mode 600, gitignored).

Rendered example:

```
📧 WordPress — contact form
From: WordPress <wordpress@pressabl.com>
To:   admin@hellyer.kiwi
Date: 2026-10-05 09:14:03 +0100

New enquiry from Jane Doe <jane@example.com>
Message: …
```

Bot API calls used: `getMe` (validate token at provision time),
`sendMessage`, `sendDocument`. Limits to respect: 4096 chars text, 1024 caption,
50 MB upload, ~30 msg/s.

---

## 7. Configuration (`.env` / `.env.example`)

Add a documented block to `.env.example` (values live only in `.env`):

```bash
# ---- Email → Telegram ----
# Bot token from @BotFather, and the target chat id (see EMAILS.md).
# Both are required for mailrelay; if unset, the container is not started /
# mail delivery is queued until they are set.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
# all        = forward every message (WordPress customer mail included)
# local      = only recipients whose domain is in MAIL_LOCAL_DOMAINS
# allowlist  = only senders/recipients matching MAIL_ALLOW_REGEX
MAIL_TELEGRAM_MODE=all
MAIL_LOCAL_DOMAINS=hellyer.kiwi,localhost,localhost.localdomain
# Optional regex deny list applied after the mode filter (e.g. drop cron noise)
#MAIL_DENY_REGEX=
# Default envelope sender used by the msmtp shims / apps that don't set their
# own From. The Telegram notification always displays the message's original
# From header.
MAIL_FROM_ADDRESS=server@hellyer.kiwi
# Retry/backoff for the spool worker
#MAIL_MAX_ATTEMPTS=12
```

These are passed to the container as environment variables, following the
Authelia precedent (`compose.yaml` passes `AUTHELIA_*` directly; **do not** use
`env_file:` for the whole `.env`, as every var is parsed as config). Tokens are
never rendered into a config file and never committed.

---

## 8. Repo changes (file-by-file)

| File | Change |
|---|---|
| `compose.yaml` | New `mailrelay` service: `build: ./mail`, `container_name: mailrelay`, env vars above, `mailrelay-spool` volume, `ports: 127.0.0.1:2525:25`, `networks: [web]`, healthcheck, resource limits. Add the `mailrelay-spool` volume. (No `open-webui` change — it has no SMTP code today, §5.3.) |
| `mail/Containerfile` | New. Python 3 + `aiosmtpd`, copy `gateway.py`, `EXPOSE 25`, entrypoint. |
| `mail/gateway.py` | New. SMTP sink + spool/retry worker + Telegram sender (see §5.1). |
| `scripts/lib-containers.sh` | Add `CONTAINER_MAILRELAY="mailrelay"` and append to `ALL_CONTAINERS` (drives `pod-status`, obsolete-unit cleanup). |
| `php/Containerfile` | Install `msmtp msmtp-mta`; copy `30-mail.ini` and `/etc/msmtprc`. |
| `php/30-mail.ini` | New. `sendmail_path` override. |
| `php/msmtprc` | New. Rendered/copied to `/etc/msmtprc`. |
| `scripts/host-setup.sh` | Install `msmtp-mta` and `swaks` (SMTP test tool); write `/etc/msmtprc` (host → `127.0.0.1:2525`). |
| `scripts/update.sh` | Add `mailrelay` to the weekly rebuild list — without this the image silently rots while php/nginx/node keep updating. |
| `authelia/configuration.yml` | Swap filesystem → SMTP notifier; optionally enable password reset. |
| `scripts/authelia-notify-code.sh` | Retire or repoint to the Telegram flow. |
| `scripts/provision-site.sh` | Set Laravel `MAIL_*` / Symfony `MAILER_DSN` in `rewrite_app_env()`. |
| `scripts/provision-mail.sh` | New. Validate token (`getMe`), `podman compose up -d --build mailrelay`, send a test message, print chat info. |
| `scripts/deploy.sh` | Call `provision-mail.sh` when `TELEGRAM_BOT_TOKEN` is set (same conditional style as the Authelia seeding). |
| `scripts/install-systemd.sh` | Ensure `mailrelay` is in the stack health expectations. *(Optional: add `server-watchdog.timer`, §10.1.)* |
| `scripts/stack-watchdog.sh` | *Optional/deferred.* Host-side stack/relay watchdog that messages Telegram directly via `curl`, bypassing `mailrelay` (§10.1). |
| `scripts/install-cli.sh` / `lib-containers.sh` | Optional `mail-test` host wrapper (sends a message through the relay). |
| `.env.example` | Add the block from §7. |
| `README.md` | New "Email → Telegram" section; note the sendmail shim and the `mailrelay` service. |
| `EMAILS.md` | This document. |

---

## 9. Rollout phases

**Phase 0 — Telegram (user, ~5 min).** Create the bot, get the chat id, put
`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` in `.env`.

**Phase 1 — the relay alone.**
* Add `mail/mailrelay` + compose service + `TELEGRAM_*` env.
* `sudo bash scripts/provision-mail.sh` → validates the token, brings up the
  container, sends a hello-world.
* Test with raw SMTP before wiring anything else (`swaks` is installed by
  `host-setup.sh`; the `curl` form is the fallback):
  `swaks --to root@localhost --server 127.0.0.1:2525` (or
  `curl smtp://127.0.0.1:2525 --mail-from a@b --mail-rcpt c@d -T msg.eml`).
* Expected: "hello" appears in Telegram; a mail sent while Telegram is blocked
  lands in `spool/` and is retried.

**Phase 2 — transparent capture.**
* Add msmtp to `php/Containerfile`; rebuild.
* `podman exec php-fpm php -r 'mail("root@localhost","test","body");'` →
  Telegram.
* Add msmtp to the host via `host-setup.sh`; `echo test | sendmail root` →
  Telegram. **If this hangs/refuses, check ufw first:** published container
  ports are DNAT'd, so host→`127.0.0.1:2525` crosses ufw's FORWARD chain — the
  same class of problem that broke container DNS once (README, "Firewall (ufw)
  and the containers"). The existing podman-subnet `route allow` rules should
  cover it; verify with `ufw status verbose` and add a rule if not.
* Confirm a cron mail and a fail2ban action mail arrive.

**Phase 3 — apps.**
* Switch Authelia to the SMTP notifier; register a second factor and confirm the
  confirmation link lands in Telegram (replaces `authelia-notify-code.sh`).
* Run `provision-site.sh` (or a one-off rewrite) for Laravel sites and send from
  `artisan tinker` (`Mail::raw(...)`); confirm a queued mail arrives.
* Trigger a WordPress password-reset/contact-form mail on a test site.
* (Open WebUI has no SMTP code today, so there is nothing to wire — revisit if
  that changes.)

**Phase 4 — optional.**
* Gmail Maildir forwarding (`scripts/gmail-to-telegram.sh`), opt-in.
* Archive every message to a searchable store (e.g. append to a Maildir under a
  new backed-up path) if the user wants history beyond Telegram's retention.
* A daily "N messages forwarded, M failed" summary from the relay.

---

## 10. Reliability, security, operations

* **Reliability:** spool-before-ack + retry/backoff means an `api.telegram.org`
  outage defers, not drops. Failed files persist in the spool volume and are
  visible in `pod-logs mailrelay`. (A full Postfix sink is the upgrade path if
  the user later wants real SMTP queue semantics.)
* **Security:**
  * The relay is **never** published beyond `127.0.0.1` and is only on the
    internal `web` network. There is no public port 25. Confirm ufw doesn't
    block the host→published-port path (DNAT crosses the FORWARD chain — see
    the Phase 2 test).
  * It must be on **`web`**, not `backend`: `backend` is `internal: true` in
    `compose.yaml` and therefore has **no outbound internet** — it could not
    reach `api.telegram.org`. This is an easy mistake to make.
  * Bot token/chat id live only in `.env` (mode 600, gitignored) and container
    env; never in a committed file.
  * Optional shared-secret header on the SMTP connection / basic auth if the
    box ever gains untrusted containers on `web`.
* **Privacy / correctness caveat (important):** with `MAIL_TELEGRAM_MODE=all`,
  **customer-facing** WordPress/Laravel mail (order confirmations, user
  password resets) is also diverted to Telegram and will **not** reach the
  customer. Today those messages are already undelivered, so nothing is lost —
  but if any site is meant to email real users, choose `local` mode (relay only
  `@hellyer.kiwi`/`@localhost` recipients) or add a `MAIL_DENY_REGEX`, and keep
  per-site SMTP plugins for those sites. This is the single decision to confirm
  before Phase 3.
* **One-way only:** Telegram alerts cannot be replied to as email. Include the
  original sender/`Message-ID` in the message so the source is traceable, but
  there is no inbound mail path (the inbound Gmail phase is separate and
  read-only).
* **Noise:** server mail can spike (a broken cron loop mailing every minute).
  The relay's rate limiter protects Telegram; consider a dedup/aggregation
  window for identical subjects.

### 10.1 Who watches the watcher? Failure domains

This is the sharpest question about the whole design, so it gets a principle:

> **The thing that reports a failure must live outside the failure domain it
> reports on.** No alerting path that sits inside the stack can report that the
> stack is down — and a future uptime monitor inside `server-stack` has exactly
> that blind spot.

Failure classes, and which can be caught where:

| Failure | Is `mailrelay` up? | Can the stack report it? |
|---|---|---|
| One app/site broken, php-fpm fine | yes | **yes** — the app's own mail routes through `mailrelay` |
| `mailrelay` itself down, rest of stack up | no | no — needs a host-side check |
| Whole stack down (`server-stack.service` failed) | no | **no** — the reporter dies with it |
| podman / host / network / power down | no | **no** — only an off-box monitor sees it |

Consequences:

* For **app-generated mail**, an in-stack `mailrelay` is the right call: if an
  app can produce mail at all, the relay is reachable. Keep it in the stack.
* A **future uptime container inside the same stack** only catches *partial*
  failures — a single site down while the stack is otherwise healthy. If
  `server-stack` (or podman, or the host) goes down, the monitor goes with it.
  Do not rely on it for "everything is down".
* **"Everything is down" must come from off-box.** The remote uptime checker the
  user already runs is exactly the right tool — keep it as the authoritative
  whole-box alert. (If DNS/network is down too, only an off-box checker sees it.)

**Decision (accepted):** keep `mailrelay` in the stack and rely on the external
uptime checker for the whole-box-down case. The only gap is "mailrelay (or the
stack) is down while the host is still up", and that is accepted: an outage that
takes `mailrelay` down almost certainly took the rest of the stack down too, and
the external checker covers that. **No host-level mail watchdog is required for
the initial implementation.**

**Optional (deferred): a host-level watchdog, outside the stack.** If
in-stack-failure alerts are ever wanted without depending on the external
checker, add `scripts/stack-watchdog.sh` driven by `server-watchdog.timer`,
supervised by systemd directly and **not** part of `server-stack.service`:

* Dependencies: `systemctl`, `podman ps`, `curl` — no php, nginx, mariadb,
  compose, and crucially **not** `mailrelay`. It sends to Telegram by calling
  `api.telegram.org` directly (reading `TELEGRAM_*` from `.env`).
* Checks: `server-stack.service` active; every container in `ALL_CONTAINERS`
  running; `mailrelay` health specifically (SMTP `NOOP` or its healthcheck);
  optional disk-usage threshold.
* State file (e.g. `/var/lib/server-setup/watchdog.state`) + re-alert interval:
  message on up→down and on recovery, then re-alert every N minutes while still
  down, so it neither spams nor goes quiet.
* Net effect: if the stack **or mailrelay** dies, the user still gets a Telegram
  message as long as the host and network are up. Only host/network/power loss
  remains, and that is what the remote checker covers.

If an uptime monitor is added later, pick deliberately:

* **(a) In the same stack** — simple, catches per-site failures, but shares the
  blind spot above; the remote checker (and the optional host watchdog, if
  added) cover stack/host death.
* **(b) Its own compose project / systemd unit outside `server-stack.service`**,
  talking to Telegram directly (not through `mailrelay`) — survives
  `server-stack` going down and keeps a cleaner blast radius, but still dies
  with podman/host. Prefer (b) if the monitoring matters, otherwise (a) is fine
  given the remote checker already exists.

Optional dead-man's switch: have the local watchdog push a heartbeat to the
remote checker, which alerts if the heartbeat stops — catching "host up but
watchdog silently broken".

---

## 11. Open questions (confirm before implementing)

1. **`all` vs `local`** — should WordPress/Laravel mail addressed to customers
   go to Telegram (and thus not to the customer), or only server-bound notices?
   Recommendation: start `all` on a test site, expect to settle on `local`.
2. **One chat or several** — a single *Server Alerts* chat, or separate chats
   for server vs. application vs. Gmail?
3. **Message body policy** — full body always, or subject + snippet with the
   full message as an attached `.eml` to keep the chat tidy?
4. **Gmail forwarding** — include it (Phase 4) or leave `~/gmail` as the archive?
5. **Retention** — is Telegram enough, or should every message also be archived
   in a backed-up Maildir?

---

## 12. Implementation checklist

- [ ] Phase 0: bot created; `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `.env`.
- [ ] `mail/Containerfile`, `mail/gateway.py` (SMTP sink, spool, retry, Telegram).
- [ ] `compose.yaml`: `mailrelay` service (+ `mailrelay-spool` volume), on `web`,
      published `127.0.0.1:2525`.
- [ ] `scripts/lib-containers.sh`: add `mailrelay` to the inventory.
- [ ] `php/Containerfile` + `php/30-mail.ini` + `php/msmtprc`: msmtp shim.
- [ ] `scripts/host-setup.sh`: `msmtp-mta` + `swaks` + `/etc/msmtprc` → `127.0.0.1:2525`.
- [ ] `scripts/update.sh`: add `mailrelay` to the weekly rebuild list.
- [ ] `authelia/configuration.yml`: SMTP notifier; retarget `authelia-notify-code.sh`; enable password reset if wanted.
- [ ] `scripts/provision-site.sh`: Laravel/Symfony mail settings.
- [ ] `scripts/provision-mail.sh` + `scripts/deploy.sh` hook.
- [ ] *(Deferred/optional)* `scripts/stack-watchdog.sh` + `server-watchdog.timer` (independent of the stack), if in-stack-failure alerts are wanted beyond the external checker (§10.1).
- [ ] Decide placement of any future uptime monitor: in-stack vs. separate project (§10.1).
- [ ] `.env.example` + `README.md` documentation.
- [ ] Tests: raw SMTP, host `sendmail` (incl. the ufw FORWARD check), `php mail()`, a cron mail, Authelia reset, a Laravel mail, a WordPress mail.
- [ ] Decide open questions in §11.
