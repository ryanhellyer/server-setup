# WordPress Hardening & Authelia Expansion Plan

Status: **plan / not yet implemented**
Scope: the Pressabl WordPress Multisite (one shared install at
`/var/www/pressabl/public_html`, ~20 hostnames) plus any single-site WP vhosts
in future.

Decisions taken (2026-10-27):

* **Every pressabl host is path-gated, never whole-vhost gated.** The 18 public
  hosts serving `/var/www/pressabl/public_html` keep their content public; only
  `wp-admin/`, `wp-login.php`, `wp-json`, `xmlrpc.php` and multisite
  signup/activate require Authelia. Whole-vhost SSO stays limited to the two
  hosts already in `protected-multisite.conf`. See §4.1.
* **`wp-json` is gated everywhere.** The only machine consumer is
  `admin.ryan.hellyer.kiwi`'s published-posts endpoint, already covered by a
  first-match `bypass` rule.
* **`admin-ajax.php` is gated with no exemption.** None of the sites use it for
  logged-out requests.
* **`wp-cron.php` is hard-denied, not gated.** Cron runs from
  `scripts/wp-cron.sh`; `DISABLE_WP_CRON` is already `true` in
  `wp-config.php`, so there is no loopback to break.
* **Still open:** policy level (`two_factor` vs `one_factor`) — see §9.

## 1. Goal

1. **Full-vhost SSO stays as it is.** `invoices.hellyer.kiwi` and
   `admin.ryan.hellyer.kiwi` are already behind the server-level gate, and that
   is the whole of the whole-vhost set. No pressabl host joins them — the
   content stays public.
2. **Path-level SSO covers every pressabl host** (all 20 serving the multisite
   root — list in §4.1). Gate the internal endpoints the public does not need —
   `wp-admin`, `wp-login.php`, `xmlrpc.php`, `wp-json` (REST), multisite
   signup/activate — on each of them.
3. **Hard-deny** the paths that are pure attack surface and never needed over
   HTTP: `wp-cron.php`, `wp-config.php`, `readme.html`, uploaded PHP, debug
   logs. These are `return 403`, not Authelia — see §4.6.

This is a documentation-only plan. No config has been changed yet.

---

## 2. Current state

* `nginx/conf.d/protected-multisite.conf` is a standalone vhost block with the
  Authelia gate applied at server level (`authelia-authz-location.conf` +
  `authelia-authrequest.conf`). It currently serves
  `invoices.hellyer.kiwi` and `admin.ryan.hellyer.kiwi`, with the same
  `pressabl` root and WordPress locations as the main block.
* `nginx/conf.d/wordpress-multisite.conf` is the public multisite block. It
  serves the other 18 pressabl hostnames (§4.1) and has **no** Authelia gate.
  `wordpress.hellyer.kiwi` is one of them and stays public.
* `authelia/configuration.yml` `access_control.rules`:
  * a single `bypass` rule for
    `admin.ryan.hellyer.kiwi` → `^/wp-json/wordpress-api/v1/posts/?$`
    (so `ryan.hellyer.kiwi`'s Laravel app can fetch it server-side), then
  * a `two_factor` rule listing `chat`, `storage`, `invoices`,
    `admin.ryan`, `health`, `secure`, `dad`, `phone`.
  * `default_policy: deny`, rules are **first-match**.
* The reusable snippets already support per-path protection: the sites README
  documents "protect one path/page → include the authz snippet once at server
  level, put `authelia-authrequest.conf` inside that `location`".
* `nginx.conf` already bypasses the FastCGI cache for `/wp-admin/`,
  `/xmlrpc.php` and `/wp-*.php` (`$no_cache_uri`, line 84).
* WordPress cron is not needed over HTTP: `scripts/wp-cron.sh` runs due events
  via WP-CLI from a systemd timer (`server-wpcron.timer`, every 10 min).
  `DISABLE_WP_CRON` is **already defined `true`** in `wp-config.php`, so page
  loads do not spawn a loopback request. Direct HTTP hits to `wp-cron.php`
  still execute due events — that is the case §4.6 closes.

---

## 3. Constraints & gotchas (why this is not just "add a location")

1. **`auth_request` is not variable-driven.** A host cannot be whole-vhost
   protected while sharing a server block with unprotected hosts. Path-level
   `auth_request` *is* fine in a shared block, but it fires for **every host in
   that block** (nginx cannot decide per `$host` whether to issue the
   subrequest). This matters for the non-`hellyer.kiwi` multisite domains (see
   §4.4). For this plan it is a feature rather than a limitation: all 20
   pressabl hosts want the same gate (§4.1).
2. **Authelia `default_policy: deny`.** Once nginx starts asking Authelia about
   a host/path, a matching rule must grant access or *even authenticated users*
   are denied. New resource rules are mandatory, not optional. A missing rule
   produces a bare 403, not a login redirect.
3. **First-match ordering.** The existing `admin.ryan` `bypass` rule must stay
   first, before any broad `*.hellyer.kiwi` path rule that would otherwise
   capture its `/wp-json/…/posts` endpoint.
4. **Session cookie domains.** The Authelia session cookie is scoped to
   `hellyer.kiwi`, so SSO only works for hosts under that domain; a host on
   another registrable domain would need its own portal (Authelia multi-domain
   cookies require `authelia_url` to be under the cookie's domain) or a 401
   would bounce to `auth.hellyer.kiwi` and loop. Authelia also rejects rule
   domains outside the session domain. This does not affect the current plan:
   the only non-`hellyer.kiwi` hosts in the WordPress block (`undiecar.com`,
   `psychedelicsocietyberlin.org`) are not DNS-pointed here. See §4.4.
5. **nginx regex-location ordering.** The generic `location ~ \.php$` and the
   `static-assets.conf` regexes will beat a plain `/wp-admin/` prefix location
   unless an admin-specific PHP regex is declared **before** them. The admin
   regex must be placed before both.
6. **`?rest_route=` bypass.** WordPress also exposes the REST API as
   `/?rest_route=/wp/v2/...`. That is a query string, not a path, so it does
   not match a `/wp-json/` location and would reach PHP ungated. Since nothing
   on the public hosts calls the REST API, this is now closed rather than
   accepted. See §4.6.
7. **Gating cron is the wrong verb.** `wp-cron.php` should never run over
   HTTP, so the correct expression of that is `return 403`, not an Authelia
   policy. A `two_factor` rule would *permit* cron over HTTP to any
   authenticated session — the opposite of the intent — and would route
   scanner traffic (this path is heavily probed) into Authelia and Redis, the
   component whose failure locks out every protected host. `DISABLE_WP_CRON`
   is already set, so there is no loopback to preserve; the deny is purely
   about direct hits.

---

## 4. Proposed changes

### 4.1 Coverage: every host on the pressabl root

The multisite install is one root (`/var/www/pressabl/public_html`) served by
**20** hostnames across two server blocks. The path gate is added to the 18
public ones; the two already inside `protected-multisite.conf` are covered for
every path anyway, so neither block's `server_name` list changes.

`wordpress-multisite.conf` — 18 hosts, currently ungated:

```
de.hellyer.kiwi                     ice.hellyer.kiwi
undiecar.hellyer.kiwi               instagram.hellyer.kiwi
undiecar.com                        nb.hellyer.kiwi
berlin-advice.hellyer.kiwi          offline-demo.hellyer.kiwi
book.hellyer.kiwi                   slapshot.hellyer.kiwi
external-posts.hellyer.kiwi         tweets.hellyer.kiwi
facebook.hellyer.kiwi               wordpress.hellyer.kiwi
forum.hellyer.kiwi                  dunedinicehockey.hellyer.kiwi
psychedelicsocietyberlin.org        carly.hellyer.kiwi
```

`protected-multisite.conf` — 2 hosts, already whole-vhost gated:

```
invoices.hellyer.kiwi                admin.ryan.hellyer.kiwi
```

Why path-level rather than moving hosts into the protected block:

* **The content is public.** These are readable sites; a server-level gate
  would make all 18 login-only. Path-level gives the same protection to the
  administrative surface without closing the front door.
* **`auth_request` is not variable-driven** (§3.1), so one include in
  `wordpress-multisite.conf` gates the listed paths for every host in that
  block — exactly the desired coverage, with no per-host duplication and no
  block splitting.
* Moving 18 hosts to a second block to get a server-level gate would also
  strand `undiecar.com` and `psychedelicsocietyberlin.org`, which sit outside
  the `hellyer.kiwi` session cookie domain (§3.4, §4.4).

Consequences to keep in mind:

* `wordpress.hellyer.kiwi` stays in the public block. Its front page and posts
  remain anonymous; only its `wp-*` paths are gated. It is **not** added to
  `authelia/configuration.yml`'s full-domain `two_factor` list — the
  `*.hellyer.kiwi` resource rule in §4.3 is what covers it.
* `undiecar.com` and `psychedelicsocietyberlin.org` are inside the gated
  locations but have no matching Authelia rule, so with `default_policy: deny`
  their `wp-*` paths would return **403**. Both are not DNS-pointed here
  (§4.4), so this is theoretical — but it is now a deny, not a redirect loop.
* `secure.hellyer.kiwi` reuses this root as an `@fallback` only. It is its own
  server block, already whole-vhost gated, and needs no change.
* No log/root/TLS changes: every block here already shares the `pressabl`
  certificate.

The only edit to `protected-multisite.conf` in this plan is the `wp-cron.php`
deny (§4.6).

### 4.2 Path-level protection for internal WordPress endpoints

Add a reusable snippet — `nginx/snippets/wordpress-protected-paths.conf` — and
include it **once** in each WordPress server block that serves public hosts
(i.e. `wordpress-multisite.conf`, right after `wordpress-locations.conf` and
**before** `static-assets.conf` / the generic `\.php$` location).

To avoid repeating the cache block five times, first add a tiny helper —
`nginx/snippets/wordpress-php-fastcgi.conf`:

```nginx
# FastCGI PHP + shared cache settings for WordPress. Include inside a
# location that also passes through authelia-authrequest.conf (if gated).
include /etc/nginx/snippets/fastcgi-php.conf;
fastcgi_pass php-fpm;

fastcgi_cache_bypass $no_cache_final;
fastcgi_no_cache     $no_cache_final;
fastcgi_cache PRESSABL;
fastcgi_cache_valid 200 1m;
fastcgi_cache_use_stale error timeout invalid_header http_500;
```

Then the protected-paths snippet:

```nginx
# =============================================================================
# Internal WordPress endpoints gated by Authelia. Include ONCE per WordPress
# server block, BEFORE static-assets.conf and before `location ~ \.php$`, so
# the admin PHP regex wins. Requires authelia-authz-location.conf at server
# level (included once).
#
# auth_request is NOT variable-driven: these locations gate the listed paths
# for EVERY host in the block. See WORDPRESS_SECURE.md §4.4 for the
# non-hellyer.kiwi hosts.
#
# Deliberately NOT in here: wp-cron.php (hard-deny, §4.6 — never gate cron) and
# admin-ajax.php (gated by the admin PHP regex below; no site uses it for
# logged-out requests, so no exemption).
# =============================================================================

# ---- Multisite registration / activation / login (PHP) ----
location = /wp-login.php {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
}
location = /wp-signup.php {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
}
location = /wp-activate.php {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
}

# ---- XML-RPC ----
location = /xmlrpc.php {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
}

# ---- Admin PHP: must be declared BEFORE the generic `\.php$` regex ----
location ~ ^/wp-admin/.*\.php$ {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
}

# ---- Admin area (static files + fallback). Plain prefix so the admin PHP
#      regex above still wins for .php requests. ----
location /wp-admin/ {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    try_files $uri $uri/ /index.php?$args;
}

# ---- REST API ----
location ^~ /wp-json {
    include /etc/nginx/snippets/authelia-authrequest.conf;
    try_files $uri $uri/ /index.php?$args;
}
```

Add the matching authz endpoint include to the public block:

```nginx
# wordpress-multisite.conf, near the security-headers include:
include /etc/nginx/snippets/authelia-authz-location.conf;
```

Because **Authelia's default policy is deny**, §4.3 must be applied in the same
change.

Notes / caveats to keep in the snippet comments:

* **`admin-ajax.php`** (`/wp-admin/admin-ajax.php`) is gated by the admin PHP
  regex, with **no exemption**. No site on the multisite uses it for
  logged-out AJAX, so this is the tighter option and the agreed one. It is the
  classic silent breakage when a plugin is added later (the form just
  redirects to the auth portal), so re-check after deploy with the access-log
  query in §7.
* **`/wp-json/` consumers**: the only known machine consumer is
  `ryan.hellyer.kiwi`'s Laravel app against `admin.ryan.hellyer.kiwi`, covered
  by the existing `bypass` rule. Nothing on the public hosts calls the REST
  API. Expect two consequences, neither a bug:
  * **Site Health reports "The REST API encountered an error"** — its
    availability test is a loopback from PHP-FPM with no Authelia cookie. If
    the false alarm ever matters, the fix is a `networks:` bypass for the
    container network, not a path exemption.
  * **Application Passwords / REST basic auth stop working** on the public
    hosts. Any future integration needs an Authelia session or a `bypass`
    entry.
* The gate covers `/wp-admin/network/` (network admin) automatically.
* **Static assets under `/wp-admin/`** are gated by the prefix location, which
  costs one auth subrequest per CSS/JS file (~50 per admin page, uncached).
  Optional optimisation: leave the prefix ungated and keep auth on the PHP
  regex + `index.php` only — those files are public core assets and carry no
  data. Do **not** use `^~` on that prefix; it would outrank the admin PHP
  regex and serve `.php` as static text.

### 4.3 Authelia `access_control` rules

Insert a resource rule **after** the existing `admin.ryan` bypass rule and
**before** the full-domain `two_factor` list in `authelia/configuration.yml`:

```yaml
    # Internal WordPress endpoints — the public does not need these. nginx
    # only issues the subrequest for these paths
    # (nginx/snippets/wordpress-protected-paths.conf). The wildcard covers the
    # hellyer.kiwi multisite hosts; auth only triggers where nginx asks.
    # Policy shown as two_factor; one_factor is the open alternative (§9).
    - domain:
        - '*.hellyer.kiwi'
      resources:
        - '^/wp-admin([/?].*)?$'
        - '^/wp-login\.php([/?].*)?$'
        - '^/wp-signup\.php([/?].*)?$'
        - '^/wp-activate\.php([/?].*)?$'
        - '^/xmlrpc\.php([/?].*)?$'
        - '^/wp-json([/?].*)?$'
      policy: 'two_factor'
```

The `([/?].*)?$` suffix is load-bearing: `resources` matches the **path and
query**, so a bare `$` fails as soon as WordPress appends
`?redirect_to=…&reauth=1` to `/wp-login.php`, the request falls through to
`default_policy: deny`, and nginx returns 403 instead of the login form. Same
trap for `wp-signup.php`, `wp-activate.php` and `xmlrpc.php`.

Then no change to the existing full-domain rule: `wordpress.hellyer.kiwi` is
deliberately **not** added to it (§4.1).

Ordering of the resulting rules:

1. `admin.ryan.hellyer.kiwi` → `^/wp-json/wordpress-api/v1/posts/?$` = **bypass**
2. `*.hellyer.kiwi` → internal WP resources = **two_factor**  ← new
3. `chat/storage/invoices/admin.ryan/health/secure/dad/phone` = **two_factor**

Rule 1 still wins for the Laravel fetch, because it is first-match.

> **No `wp-cron.php` resource may be added here.** A matching rule would
> permit cron over HTTP to any authenticated session. The endpoint is denied
> in nginx instead (§4.6).

> `resources` is case-sensitive in Authelia (no implicit `(?i)`), while
> `domain` matching is case-insensitive. WordPress paths are lowercase, so no
> action is needed — just do not assume `/WP-ADMIN/` is covered.

> Prefer an explicit domain list over `'*.hellyer.kiwi'`? Both work. The
> wildcard is lower-maintenance (new WP subsites inherit protection); it only
> affects hosts nginx actually asks about. Enumerate the hosts from
> `nginx/conf.d/wordpress-multisite.conf` + `protected-multisite.conf` if you
> want the rule to be auditable on its own. Note `'*.hellyer.kiwi'` matches
> subdomains only, not the apex — not an issue here, since no WP host is the
> apex.

### 4.4 Non-`hellyer.kiwi` multisite hosts — out of scope (resolved)

`undiecar.com` and `psychedelicsocietyberlin.org` are listed in
`wordpress-multisite.conf` but **do not resolve to this server**, so no request
ever reaches nginx for them and no gating is needed. The `*.hellyer.kiwi`
wildcard rule therefore covers every reachable WordPress host.

If either domain is ever pointed at this server, revisit: the Authelia session
cookie is scoped to `hellyer.kiwi`, so those hosts cannot use SSO without a
portal under their own registrable domain (Authelia multi-domain cookies), and
would otherwise loop. The clean fallback then is a sibling unprotected block,
or nginx-level denies for the sensitive paths rather than an Authelia rule
(Authelia refuses rule domains outside the session domain).

### 4.5 Cache / nginx map touch-ups

* Add `^/wp-json/` (and, if used, `^/wp-signup\.php$`, `^/wp-activate\.php$`) to
  `$no_cache_uri` in `nginx.conf` line 84 so gated REST/registration responses
  are never served from the shared FastCGI cache:
  ```nginx
  map $request_uri $no_cache_uri {
      default $no_cache_method;
      "~*(/wp-admin/|/wp-login\.php|/xmlrpc\.php|/wp-signup\.php|/wp-activate\.php|/wp-json/|/wp-.*\.php)" 1;
  }
  ```
  (`/wp-.*.php` already catches `wp-login`/`wp-signup`/`wp-activate`; the exact
  additions are belt-and-braces and make the intent explicit.)
* No change needed to the `$blogid` map or WordPress rewrite rules.
* `auth_request` runs in the access phase, before the content/cache phase, so
  a gated path can never be served from cache without authorisation. The
  entries above are about correctness of cached *variables*, not leakage.

### 4.6 Non-SSO hardening — deny, don't gate

These do not go through Authelia at all. They are `return 403` / `return 404`
in nginx, placed **before** `static-assets.conf` in `wordpress-multisite.conf`
and at the top of `protected-multisite.conf`.

| Path / pattern | Action | Rationale |
|---|---|---|
| `/wp-cron.php` | `return 403` | **Agreed.** Cron runs from `wp-cron.sh`; `DISABLE_WP_CRON` is already set so nothing loops back. Never SSO it — a rule would *allow* cron over HTTP. |
| `?rest_route=` (query) | `return 403` | **Agreed** (public block only). Closes the `/wp-json/` gate bypass; nothing on these hosts uses REST. Do not add to `protected-multisite.conf` — `admin.ryan` needs REST. |
| `/wp-config.php` | `return 403` | Direct access is never legitimate. |
| `/wp-config-sample.php`, `/readme.html`, `/license.txt` | `return 404` | Version / install info disclosure. |
| `~* /wp-content/uploads/.*\.php$` | `return 403` | Uploaded PHP must never execute. |
| `~* /wp-content/(debug\.log|\.maintenance)$` | `return 403` | Debug output / maintenance signal. |
| `?author=\d` | optionally `return 403` | User enumeration. |

Sketch for the two agreed rows:

```nginx
# Never needed over HTTP: cron is driven by server-wpcron.timer (wp-cron.sh).
location = /wp-cron.php { return 403; }

# WordPress exposes REST at /?rest_route=/wp/v2/... too, which would bypass
# the ^~ /wp-json gate. Nothing on the public hosts calls REST.
if ($args ~* "rest_route") { return 403; }
```

`return` runs in the rewrite phase, ahead of `auth_request` (access phase), so
the exact-match location costs no subrequest even in the whole-vhost-protected
block.

`DISABLE_WP_CRON` is already `true` in `wp-config.php` (host path, outside this
repo), so no loopback request is made for page loads and the deny only affects
direct hits.

---

## 5. Files to change (checklist)

- [ ] `authelia/configuration.yml` — add the internal-WP resource rule. No cron
      rule, and no full-domain entry for `wordpress.hellyer.kiwi` (§4.1).
- [ ] `nginx/snippets/wordpress-php-fastcgi.conf` — **new** helper snippet.
- [ ] `nginx/snippets/wordpress-protected-paths.conf` — **new** gated locations.
- [ ] `nginx/conf.d/wordpress-multisite.conf` — add
      `authelia-authz-location.conf` include + `wordpress-protected-paths.conf`
      include; add `wp-cron.php` 403 + `?rest_route=` 403; update header
      comment. (`server_name` is unchanged — all 18 hosts stay here.)
- [ ] `nginx/conf.d/protected-multisite.conf` — add the `wp-cron.php` 403;
      update header comment. (`server_name` unchanged.)
- [ ] `nginx/nginx.conf` — extend `$no_cache_uri` (§4.5).
- [ ] `nginx/sites/README.md` — update the block table (protected-multisite
      hosts) and note the new snippet.
- [ ] `README.md` — note that the path gate covers every pressabl host, and
      that no new host is whole-vhost protected.
- [x] `wp-config.php` (host, outside repo) — `DISABLE_WP_CRON` already `true`.
- [ ] Optional: teach `scripts/new-site.sh` a `wordpress-auth` type so future
      fully-gated WP hosts scaffold into `protected-multisite.conf` instead of
      the public block.

---

## 6. Deployment

```bash
# 1. Edit the files above (config + snippets).
# 2. Validate the generated config *inside* the container:
sudo podman exec nginx nginx -t
# 3. Apply nginx:
sudo podman exec nginx nginx -s reload
# 4. Apply Authelia rules (restart reloads configuration):
sudo podman restart authelia
sudo podman logs --tail=40 authelia      # watch for validation errors
```

If `nginx -t` complains about duplicate `server_name` or a `location` ordering
issue, fix before reloading — do not leave a broken config live.

---

## 7. Verification

Unauthenticated (expect **302 → `https://auth.hellyer.kiwi/?rd=…`**):

```bash
for h in de.hellyer.kiwi ice.hellyer.kiwi tweets.hellyer.kiwi; do
  for p in /wp-admin/ /wp-login.php /xmlrpc.php /wp-json/ /wp-admin/admin-ajax.php; do
    printf '%s%s -> ' "$h" "$p"
    curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$h$p"
  done
done

# Whole-vhost protection (expect 302 -> portal; see §10):
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://admin.ryan.hellyer.kiwi/
```

Hard-denied paths (expect **403**, *not* a redirect — a redirect means the deny
was not reached):

```bash
curl -s -o /dev/null -w 'wp-cron     %{http_code}\n' https://de.hellyer.kiwi/wp-cron.php
curl -s -o /dev/null -w 'rest_route  %{http_code}\n' 'https://de.hellyer.kiwi/?rest_route=/wp/v2/users'
# only if the optional §4.6 rows are enabled:
curl -s -o /dev/null -w 'wp-config   %{http_code}\n' https://de.hellyer.kiwi/wp-config.php
```

Still public (expect **200**, not gated):

```bash
curl -sI https://de.hellyer.kiwi/ | head -1
curl -sI https://wordpress.hellyer.kiwi/ | head -1    # now path-gated only
curl -sI https://tweets.hellyer.kiwi/ | head -1
curl -sI https://ryan.hellyer.kiwi/ | head -1
```

Bypass must still work (expect **200**, JSON — not a login redirect):

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://admin.ryan.hellyer.kiwi/wp-json/wordpress-api/v1/posts
# and confirm ryan.hellyer.kiwi still renders (it calls this server-side)
```

`admin-ajax.php` is gated with no exemption — confirm nothing still calls it
publicly. Any hit is a 302 to the auth portal, which is the tell:

```bash
sudo grep admin-ajax /home/ryan/logs/pressabl/access.log | grep -c 'auth.hellyer.kiwi'
# expect 0; a non-zero count names the host and referer that needs looking at
```

After SSO login, `https://de.hellyer.kiwi/wp-admin/` should proxy through to
WordPress (which then shows its own login, as expected — the WP session is
separate from the Authelia session).

Preserved endpoints to spot-check: `/wp-includes/ms-files.php` (multisite file
serving via `/files/...`) still returns files; `/.well-known/acme-challenge`
still reachable on port 80; `wp-cron.sh` still reports success (it is WP-CLI,
unaffected by both the nginx deny and `DISABLE_WP_CRON`).

Also expect **Site Health → "The REST API encountered an error"** on the gated
hosts. That is the uncookied loopback being refused, not a fault.

---

## 8. Rollback

Revert the changed files (`git checkout -- authelia/configuration.yml
nginx/... README.md nginx/sites/README.md`), remove the two new snippets, then:

```bash
sudo podman exec nginx nginx -t && sudo podman exec nginx nginx -s reload
sudo podman restart authelia
```

Because the changes are confined to nginx config + Authelia ACLs, no data
migration or TLS work is involved.

---

## 9. Open questions / decisions

1. **Policy level** — `two_factor` (matches the other sensitive hosts) or
   `one_factor` (lighter). Note that gating `wp-login.php` makes the Authelia
   session the real gate in front of ~20 sites' admin, so `one_factor` leaves a
   leaked password as the only barrier. Recommendation: `two_factor`, keep
   `session.inactivity: '1M'` as-is for now, and treat session length as a
   separate whole-stack decision (it also governs chat/storage/phone).
2. **Optional hardening (§4.6)** — enable the remaining rows (`wp-config.php`,
   uploads PHP, debug log, `?author=`), or just the two agreed ones?

Resolved:

* ~~Full-vhost SSO for `wordpress.hellyer.kiwi`?~~ **No.** Every pressabl host
  keeps public content and gets the path gate only; whole-vhost stays with
  `invoices` and `admin.ryan`. See §4.1.
* ~~`admin-ajax.php`: gate or exempt?~~ **Gate, no exemption** — no site uses
  it for logged-out requests.
* ~~`wp-json` consumers?~~ **Gate everywhere**; `admin.ryan`'s published-posts
  endpoint keeps its first-match `bypass`.
* ~~`?rest_route=`~~ **Closed** on the public block.
* ~~`wp-cron.php`: gate or deny?~~ **Deny** (`return 403`). `DISABLE_WP_CRON`
  is already set, so nothing loops back.
* ~~Non-`hellyer.kiwi` hosts~~ Resolved in §4.4 — not DNS-pointed here.

---

## 10. Fixed: whole-vhost 401 instead of a redirect

Pre-existing, not caused by this plan. Found in a sandbox run and **fixed** while
implementing it.

**Symptom.** An unauthenticated request to a whole-vhost protected host
(`invoices`, `admin.ryan`, `health`, `dad`, `storage`, `phone`) returns a bare
`401` with nginx's built-in page, not the 302 to the portal that
`authelia-authrequest.conf` describes and the README promises.

**Cause.** Those blocks declare, at server level and *before* the Authelia
include:

```nginx
error_page 400 401 402 403 ... /error.html;
```

nginx keeps `error_page` entries in declaration order and uses the first one
whose status list matches, so `401` resolves to `/error.html` and the snippet's
`error_page 401 =302 https://auth.hellyer.kiwi/?rd=…` never runs. That internal
redirect is itself inside the gate, so fetching `/error.html` gets a 401 too,
and with `recursive_error_pages` off nginx gives up and returns the built-in
401. Verified in a sandbox nginx run with a stub authz endpoint.

**Fix applied (option A).** `401` was removed from that `error_page` list in
the five gated blocks — `protected-multisite.conf`, `health-site.conf`,
`dad-site.conf`, `storage-site.conf`, `phone.hellyer.kiwi.conf` — with a comment
in each so it is not added back. The snippet's `error_page 401 =302` is then the
only 401 handler and the portal redirect runs.

Blocks that are **not** whole-vhost gated keep `401` in their list
(`php-site.conf`, `static-site.conf`, `static-spa.conf`,
`wordpress-multisite.conf`): they have no portal redirect to preserve, and their
`/error.html` is not behind a gate, so the error page is served normally.

Trade-off accepted: an *application* 401 on those five hosts now becomes a
portal redirect rather than a 401 page. The only consumer affected is
`admin.ryan`'s WP REST, whose one machine endpoint is already `bypass`ed; an
application password pointed at a gated REST path would bounce. If that ever
matters, the precise fix is option B — give `/error.html` its own location
whose `auth_request` points at an always-`204` internal endpoint.

Side effect: `/wp-cron.php` on those five hosts returns a bare **401** to an
anonymous client (the 403 is diverted to the gated error page, and recursion is
off). Authenticated users still get the 403 + error page. These vhosts are
login-only, so the anonymous case is only ever a scanner.

The path-gated locations are unaffected: they include
`authelia-authrequest.conf` *inside* the location, so their `error_page 401
=302` replaces the server-level array rather than competing with it. Confirmed
by the sandbox run — `/wp-admin/`, `/wp-login.php`, `/wp-json/`, `/xmlrpc.php`
all 302 to the portal, and `/wp-cron.php` and `?rest_route=` return 403.
