# Per-site overrides

Most sites need **no special handling at all** — they are served by one of the
joined server blocks in `nginx/conf.d/` and differ only by the entries in that
block's maps (root, log path, etc.).

| Block file                     | Hosts it serves                                                   |
|--------------------------------|-------------------------------------------------------------------|
| `conf.d/php-site.conf`         | gpx, ryan, kartastrophecup.de, spam-destroyer.com, german, cvs, ai, health, instantattend.com |
| `conf.d/wordpress-multisite.conf` | all pressabl WordPress Multisite subdomains                   |
| `conf.d/secure-site.conf`      | secure.hellyer.kiwi                                               |
| `conf.d/static-site.conf`      | chocolate, julia, stuff, mum, dad                                 |
| `conf.d/static-spa.conf`       | comicjet.com, historic-wordpress.hellyer.kiwi                     |
| `conf.d/node-proxy.conf`       | chat.hellyer.kiwi                                                 |
| `conf.d/stats-site.conf`       | stats.hellyer.kiwi (self-hosted GoatCounter)                      |
| `conf.d/redirects.conf`        | all 301-redirect domains                                          |
| `conf.d/http-redirect.conf`    | port 80 (ACME challenge + https redirect for every domain)        |

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