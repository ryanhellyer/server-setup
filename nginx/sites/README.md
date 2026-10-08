# Per-site overrides

Most sites need **no special handling at all** — they are served by one of the
joined server blocks in `nginx/conf.d/` and differ only by the entries in that
block's maps (root, log path, etc.).

| Block file                     | Hosts it serves                                                   |
|--------------------------------|-------------------------------------------------------------------|
| `conf.d/php-site.conf`         | gpx, ryan, kartastrophecup.de, spam-destroyer.com, german, cvs, ai, instantattend.com |
| `conf.d/wordpress-multisite.conf` | all pressabl WordPress Multisite subdomains                   |
| `conf.d/secure-site.conf`      | secure.hellyer.kiwi (Authelia)                                    |
| `conf.d/static-site.conf`      | chocolate, julia, stuff, mum                                      |
| `conf.d/static-spa.conf`       | comicjet.com, historic-wordpress.hellyer.kiwi                     |
| `conf.d/node-proxy.conf`       | chat.hellyer.kiwi (behind Authelia)                               |
| `conf.d/health-site.conf`      | health.hellyer.kiwi (Authelia)                                    |
| `conf.d/protected-multisite.conf` | invoices.hellyer.kiwi, admin.ryan.hellyer.kiwi (Authelia)      |
| `conf.d/dad-site.conf`         | dad.hellyer.kiwi (Authelia)                                       |
| `conf.d/storage-site.conf`     | storage.hellyer.kiwi (Authelia)                                   |
| `conf.d/phone.hellyer.kiwi.conf` | phone.hellyer.kiwi (Laravel, Authelia)                          |
| `conf.d/auth-site.conf`        | auth.hellyer.kiwi (Authelia login portal)                         |
| `conf.d/stats-site.conf`       | stats.hellyer.kiwi (self-hosted GoatCounter)                      |
| `conf.d/redirects.conf`        | all 301-redirect domains                                          |
| `conf.d/http-redirect.conf`    | port 80 (ACME challenge + https redirect for every domain)        |

## Authelia (forward-auth / SSO)

Protected vhosts sit behind [Authelia](https://www.authelia.com). nginx asks it
about each request with `auth_request`; unauthenticated visitors are redirected
to the portal (`auth.hellyer.kiwi`). The gate is reusable:

* To protect a **whole vhost**, add both includes to its server block:
  ```nginx
  include /etc/nginx/snippets/authelia-authz-location.conf;   # once per block
  include /etc/nginx/snippets/authelia-authrequest.conf;      # at server level
  ```
* To protect **one path/page**, add the authz include once (server level) and
  put `authelia-authrequest.conf` inside that `location` instead.

**Important:** `auth_request` is *not* variable-driven, so a protected host
cannot live in a shared server block alongside unprotected ones. Each protected
host therefore gets its own small `conf.d/` block (e.g. `health-site.conf`,
`protected-multisite.conf`, `dad-site.conf`, `storage-site.conf`). Use
`scripts/new-site.sh <domain> static-auth` (or `php-auth`) to scaffold one.

Then allow the host in `authelia/configuration.yml` (`access_control.rules`)
and restart Authelia. The user database/config/DB live under
`~/www/auth.hellyer.kiwi` (snapshot-backed; a data dir, not a site root); see
`scripts/provision-authelia.sh`.

## Adding a site

Run the automation (preferred):

```bash
./scripts/new-site.sh example.com laravel
```

The script edits the right map + `server_name` list in the relevant `conf.d/`
block, creates the web root and log dirs, tests the config and reloads nginx.

## Per-site custom locations

When a site needs behaviour that the shared block doesn't provide, add the
location directly to that block and — if it must only apply to one host —
guard it with a flag map (see `$ryan_extra` in `conf.d/php-site.conf`):

```nginx
map $http_host $example_extra {
    hostnames;
    default 0;
    example.com 1;
}

# inside the server block:
location = /special-path {
    if ($example_extra) { return 200 'special'; }
}
```

The single `conf.d/` file remains the one place to edit, so a change there
propagates to every domain in that block.

Sites that are genuinely different from every existing group (like
`secure.hellyer.kiwi`) get their own small `conf.d/` file instead.