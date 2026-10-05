# Email → Telegram — simplified plan

> Short version of [`EMAILS.md`](EMAILS.md). Full detail, alternatives and
> failure-domain notes live there. **Nothing is implemented yet.**

## What we're doing

Right now the server has no mail system at all, so anything that tries to email
you (WordPress, Laravel, Authelia, cron, fail2ban…) silently throws the message
away. We're adding one program that catches all that mail and forwards it to a
Telegram chat.

## How it works

```
WordPress / Laravel / Authelia / cron ──▶ mailrelay container ──▶ Telegram
                                          (catch-all SMTP)
```

The trick: most Unix/PHP mail goes through one command, `/usr/sbin/sendmail`. We
point that command at `mailrelay` once, and then **every** app — including ones
added later — is covered with no extra setup. The few apps that speak SMTP
directly (Authelia, Laravel) get pointed at `mailrelay` as well.

## The three pieces

1. **`mailrelay` container** (new). Accepts any mail on port 25 and sends it to
   Telegram. Only reachable inside the server and on `127.0.0.1`, never public.
   Holds messages in a spool and retries if Telegram is unreachable.
2. **`msmtp` sendmail shim** (small add-on). Installed in the PHP image and on
   the host so `/usr/sbin/sendmail` relays to `mailrelay`. This is what makes it
   automatic.
3. **Explicit SMTP config** for apps that need it: Authelia and Laravel point at
   `mailrelay:25` (done by the repo's scripts, not by hand).

## One-time Telegram setup

1. In Telegram, message **@BotFather** → `/newbot` → copy the **token**.
2. Make a private group (e.g. *Server Alerts*), add the bot, send it a message.
3. Get the **chat id** from
   `https://api.telegram.org/bot<TOKEN>/getUpdates`.
4. Put both in `.env`:

   ```bash
   TELEGRAM_BOT_TOKEN=
   TELEGRAM_CHAT_ID=
   ```

## Settings in `.env`

```bash
TELEGRAM_BOT_TOKEN=            # from @BotFather
TELEGRAM_CHAT_ID=              # target chat/group
MAIL_TELEGRAM_MODE=all        # all | local | allowlist
MAIL_LOCAL_DOMAINS=hellyer.kiwi,localhost,localhost.localdomain
MAIL_FROM_ADDRESS=server@hellyer.kiwi
```

`all` forwards everything (including WordPress mail meant for customers — see
the caveat below). `local` forwards only mail addressed to the server itself.

## Files that change

- `compose.yaml` — add the `mailrelay` service (on the `web` network, publish
  `127.0.0.1:2525`).
- `mail/` — new container (`Containerfile`, `gateway.py`).
- `php/Containerfile`, `php/30-mail.ini`, `php/msmtprc` — the shim.
- `scripts/host-setup.sh` — host shim (`msmtp-mta`, `/etc/msmtprc`) + `swaks`
  for testing.
- `scripts/update.sh` — include `mailrelay` in the weekly rebuild.
- `authelia/configuration.yml` — use the SMTP notifier.
- `scripts/provision-site.sh` — set Laravel/Symfony mail to `mailrelay`.
- `scripts/provision-mail.sh` — new; checks the token and brings it up.
- `scripts/lib-containers.sh`, `.env.example`, `README.md` — wiring/docs.

## Order of work

1. Create the bot and set `TELEGRAM_*` in `.env`.
2. Build `mailrelay`, send a test, confirm it lands in Telegram.
3. Add the shim to PHP + host; test `php mail()` and host `sendmail`.
4. Point Authelia and Laravel at it; test a reset and an app email.
5. *(Optional)* Forward Gmail from `~/gmail` to Telegram too.

## Things to know

- **Customer mail:** with `all`, any WordPress/Laravel mail addressed to a
  customer also goes to Telegram instead of the customer. Today it goes nowhere,
  so nothing is lost — but use `local` mode if a site must email real users.
- **If the whole stack is down,** `mailrelay` is down too and can't tell you.
  Your existing external uptime checker covers that case, so we accept this and
  don't add a separate host watchdog for now.
- **One-way:** you can't reply to the Telegram messages; they're alerts only.
