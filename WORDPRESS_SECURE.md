# WordPress Hardening & Authelia Expansion Plan

Status: **plan / not yet implemented**
Scope: the Pressabl WordPress Multisite (one shared install at
`/var/www/pressabl/public_html`, ~20 hostnames) plus any single-site WP vhosts
in future.

## 1. Goal

1. **Full-vhost SSO**: extend the Authelia gate that currently protects
   `admin.ryan.hellyer.kiwi` to **`wordpress.hellyer.kiwi`** as well.
2. **Path-level SSO**: gate the internal WordPress endpoints that the public
   does not need — `wp-admin`, `wp-login.php`, `xmlrpc.php`, `wp-json`
   (REST), multisite signup/activate — on **every** WordPress host.
3. Optionally harden a few non-SSO WordPress paths (`wp-cron.php`,
   `wp-config.php`, `readme.html`, uploaded PHP, debug logs) that are pure
   attack surface / information disclosure.

This is a documentation-only plan. No config has been changed yet.

---

## 2. Current state

* `nginx/conf.d/protected-multisite.conf` is a standalone vhost block with the
  Authelia gate applied at server level (`authelia-authz-location.conf` +
  `authelia-authrequest.conf`). It currently serves
  `invoices.hellyer.kiwi` and `admin.ryan.hellyer.kiwi`, with the same
  `pressabl` root and WordPress locations as the main block.
* `nginx/conf.d/wordpress-multisite.conf` is the public multisite block. It
  serves the rest of the hostnames, including `wordpress.hellyer.kiwi`
  (line 17), and has **no** Authelia gate.
* `authelia/configuration.yml` `access_control.rules`:
  * a single `bypass` rule for
    `admin.ryan.hellyer.kiwi` → `^/wp-json/wordpress-api/v1/posts/?$`
    (so `ryan.hellyer.kiwi`'s Laravel app can fetch it server-side), then
  * a `two_factor` rule listing `chat`, `storage`, `invoices`,
    `admin.ryan`, `health`, `secure`, `dad`.
  * `default_policy: deny`, rules are **first-match**.
* The reusable snippets already support per-path protection: the sites README
  documents "protect one path/page → include the authz snippet once at server
  level, put `authelia-authrequest.conf` inside that `location`".
* `nginx.conf` already bypasses the FastCGI cache for `/wp-admin/`,
  `/xmlrpc.php` and `/wp-*.php` (`$no_cache_uri`, line 84).
* WordPress cron is not needed over HTTP: `scripts/wp-cron.sh` runs due events
  via WP-CLI from a systemd timer (`server-wpcron.timer`, every 10 min).

---

## 3. Constraints & gotchas (why this is not just "add a location")

1. **`auth_request` is not variable-driven.** A host cannot be whole-vhost
   protected while sharing a server block with unprotected hosts. Path-level
   `auth_request` *is* fine in a shared block, but it fires for **every host in
   that block** (nginx cannot decide per `$host` whether to issue the
   subrequest). This matters for the non-`hellyer.kiwi` multisite domains (see
   §4.4).
2. **Authelia `default_policy: deny`.** Once nginx starts asking Authelia about
   a host/path, a matching rule must grant access or *even authenticated users*
   are denied. New resource rules are mandatory, not optional.
3. **First-match ordering.** The existing `admin.ryan` `bypass` rule must stay
   first, before any broad `*.hellyer.kiwi` path rule that would otherwise
   capture its `/wp-json/…/posts` endpoint.
4. **Session cookie domains.** The Authelia session cookie is scoped to
   `hellyer.kiwi`, so SSO only works for hosts under that domain; a host on
   another registrable domain would need its own portal (Authelia multi-domain
   cookies require `authelia_url` to be under the cookie's domain) or a 401
   would bounce to `auth.hellyer.kiwi` and loop. This does not affect the
   current plan: the only non-`hellyer.kiwi` hosts in the WordPress block
   (`undiecar.com`, `psychedelicsocietyberlin.org`) are not DNS-pointed here.
   See §4.4.
5. **nginx regex-location ordering.** The generic `location ~ \.php$` and the
   `static-assets.conf` regexes will beat a plain `/wp-admin/` prefix location
   unless an admin-specific PHP regex is declared **before** them. The admin
   regex must be placed before both.
6. **`?rest_route=` bypass.** WordPress also exposes the REST API as
   `/?rest_route=/wp/v2/...`. That is a query string, not a path, so it does
   not match a `/wp-json/` location and would reach PHP ungated. See §4.6.
7. **Loopback cron.** Gating `wp-cron.php` with Authelia would break
   page-load cron (the loopback request has no session). Use a hard deny +
   the existing systemd timer, or leave it.

---

## 4. Proposed changes

### 4.1 Full-vhost protection for `wordpress.hellyer.kiwi`

Move the host from the public block to the protected block (a host cannot be in
two `server_name`s, and only the protected block can carry the server-level
gate).

* `nginx/conf.d/wordpress-multisite.conf`: remove `wordpress.hellyer.kiwi`
  from the `server_name` list (line 17).
* `nginx/conf.d/protected-multisite.conf`: add `wordpress.hellyer.kiwi` to
  `server_name` (line 16) and update the file header comment.
* `authelia/configuration.yml`: add `'wordpress.hellyer.kiwi'` to the
  `two_factor` domain list (currently lines 110–118).

No log/root/TLS changes are needed — both blocks already use the same
`pressabl` root, logs and certificate.

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
  regex. Front-end themes/plugins occasionally use it for logged-out AJAX
  (contact forms, cart fragments). If testing shows breakage, add an *ungated*
  exemption **before** the admin PHP regex:
  ```nginx
  location = /wp-admin/admin-ajax.php {
      include /etc/nginx/snippets/wordpress-php-fastcgi.conf;
  }
  ```
  This is a deliberate trade-off (admin-ajax is also a common spam target).
* **`/wp-json/` consumers** must be checked before enabling the gate. The only
  known machine consumer today is `ryan.hellyer.kiwi`'s Laravel app against
  `admin.ryan.hellyer.kiwi`, covered by the existing `bypass` rule. Verify no
  other site's front-end (or the planned Laravel front-end) fetches these
  domains' REST API.
* The gate covers `/wp-admin/network/` (network admin) automatically.

### 4.3 Authelia `access_control` rules

Insert a resource rule **after** the existing `admin.ryan` bypass rule and
**before** the full-domain `two_factor` list in `authelia/configuration.yml`:

```yaml
    # Internal WordPress endpoints — the public does not need these. nginx
    # only issues the subrequest for these paths
    # (nginx/snippets/wordpress-protected-paths.conf). The wildcard covers the
    # hellyer.kiwi multisite hosts; auth only triggers where nginx asks.
    - domain:
        - '*.hellyer.kiwi'
      resources:
        - '^/wp-admin(/.*)?$'
        - '^/wp-login\.php$'
        - '^/wp-signup\.php$'
        - '^/wp-activate\.php$'
        - '^/xmlrpc\.php$'
        - '^/wp-json(/.*)?$'
      policy: 'two_factor'
```

Then add `'wordpress.hellyer.kiwi'` to the existing full-domain `two_factor`
rule for §4.1.

Ordering of the resulting rules:

1. `admin.ryan.hellyer.kiwi` → `^/wp-json/wordpress-api/v1/posts/?$` = **bypass**
2. `*.hellyer.kiwi` → internal WP resources = **two_factor**  ← new
3. `chat/storage/invoices/admin.ryan/health/secure/dad/wordpress` = **two_factor**

Rule 1 still wins for the Laravel fetch, because it is first-match.

> Prefer an explicit domain list over `'*.hellyer.kiwi'`? Both work. The
> wildcard is lower-maintenance (new WP subsites inherit protection); it only
> affects hosts nginx actually asks about. Enumerate the hosts from
> `nginx/conf.d/wordpress-multisite.conf` + `protected-multisite.conf` if you
> want the rule to be auditable on its own.

### 4.4 Non-`hellyer.kiwi` multisite hosts — out of scope (resolved)

`undiecar.com` and `psychedelicsocietyberlin.org` are listed in
`wordpress-multisite.conf` but **do not resolve to this server**, so no request
ever reaches nginx for them and no gating is needed. The `*.hellyer.kiwi`
wildcard rule therefore covers every reachable WordPress host.

If either domain is ever pointed at this server, revisit: the Authelia session
cookie is scoped to `hellyer.kiwi`, so those hosts cannot use SSO without a
portal under their own registrable domain (Authelia multi-domain cookies), and
would otherwise loop. The clean fallback then is an Authelia `deny` rule for
their internal paths (returns 403) or a sibling unprotected block.

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

### 4.6 Optional non-SSO hardening

These do not need Authelia and close obvious holes:

| Path / pattern | Action | Rationale |
|---|---|---|
| `/wp-cron.php` | `return 403` | loopback cron; covered by `wp-cron.sh` timer. Never SSO it. |
| `/wp-config.php` | `return 403` | direct access is never legitimate. |
| `/wp-config-sample.php`, `/readme.html`, `/license.txt` | `return 404` | version / install info disclosure. |
| `~* /wp-content/uploads/.*\.php$` | `return 403` | uploaded PHP must never execute. |
| `~* /wp-content/(debug\.log|\.maintenance)$` | `return 403` | debug output / maintenance signal. |
| `?rest_route=` (query) | optionally `return 403` | closes the `/wp-json/` gate bypass; test admin/plugins first. |
| `?author=\d` | optionally `return 403` | user enumeration. |

Known residual bypass: `?rest_route=/wp/v2/...` reaches PHP through
`location /` and bypasses the `/wp-json/` gate. Blocking the query is the only
clean nginx-side fix; otherwise accept it (public REST data is low-risk) or add
an upstream rule.

---

## 5. Files to change (checklist)

- [ ] `authelia/configuration.yml` — add the internal-WP resource rule; add
      `wordpress.hellyer.kiwi` to the full-domain `two_factor` list.
- [ ] `nginx/snippets/wordpress-php-fastcgi.conf` — **new** helper snippet.
- [ ] `nginx/snippets/wordpress-protected-paths.conf` — **new** gated locations.
- [ ] `nginx/conf.d/wordpress-multisite.conf` — add
      `authelia-authz-location.conf` include + `wordpress-protected-paths.conf`
      include; remove `wordpress.hellyer.kiwi`; update header comment.
- [ ] `nginx/conf.d/protected-multisite.conf` — add `wordpress.hellyer.kiwi`;
      update header comment.
- [ ] `nginx/nginx.conf` — extend `$no_cache_uri` (§4.5).
- [ ] `nginx/sites/README.md` — update the block table (protected-multisite
      hosts) and note the new snippet.
- [ ] `README.md` — add `wordpress.hellyer.kiwi` to the Authelia host list
      (lines ~494–498) and mention the path gate.
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
  for p in /wp-admin/ /wp-login.php /xmlrpc.php /wp-json/; do
    printf '%s%s -> ' "$h" "$p"
    curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$h$p"
  done
done

# Whole-vhost protection:
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://wordpress.hellyer.kiwi/
```

Still public (expect **200**, not gated):

```bash
curl -sI https://de.hellyer.kiwi/ | head -1
curl -sI https://ryan.hellyer.kiwi/ | head -1
```

Bypass must still work (expect **200**, JSON — not a login redirect):

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://admin.ryan.hellyer.kiwi/wp-json/wordpress-api/v1/posts
# and confirm ryan.hellyer.kiwi still renders (it calls this server-side)
```

After SSO login, `https://de.hellyer.kiwi/wp-admin/` should proxy through to
WordPress (which then shows its own login, as expected — the WP session is
separate from the Authelia session).

Preserved endpoints to spot-check: `/wp-includes/ms-files.php` (multisite file
serving via `/files/...`) still returns files; `/.well-known/acme-challenge`
still reachable on port 80; `wp-cron.sh` still reports success.

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

1. **`admin-ajax.php`**: keep it gated (tighter, may break public AJAX forms)
   or add the ungated exemption?
2. **`wp-json` consumers**: confirm none of these sites' public front-ends rely
   on the REST API before gating it.
3. **`?rest_route=`**: accept the residual bypass or block the query for
   anonymous users?
4. **Policy level**: internal paths currently proposed as `two_factor`, matching
   the other sensitive hosts. `one_factor` would be lighter if TOTP friction is
   a concern.
5. **Optional hardening table** (§4.6): enable all, some, or none?

_(Non-`hellyer.kiwi` hosts resolved in §4.4 — not DNS-pointed, ignored.)_
