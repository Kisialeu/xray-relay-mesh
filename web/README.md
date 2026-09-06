# Stats web server

This bundle contains the terminal homepage, Nginx TLS frontend, and Certbot
Route53 DNS-01 client for the central stats backend. Statistics pages are
served by the `stats` service and proxied by Nginx.

- Flask terminal application code, its template, and frontend assets are grouped under `app/`;
- Nginx terminates TLS and reverse-proxies the authenticated `/stats/` namespace
  to the loopback-only stats backend;
- API requests are rate-limited at Nginx and remain token-authenticated by Flask;
- the default TLS listener is `127.0.0.1:9093`, so the existing SSH tunnel remains usable.

Application layout:

```text
app/
  __init__.py       application factory
  __main__.py       Waitress entrypoint
  auth.py           htpasswd authentication
  routes.py         page and health routes
  templates/        terminal homepage template
  static/           JavaScript and CSS
```

The first deployment requests a certificate through Route53 DNS-01 and stores
it in the persistent `/opt/xray-web/letsencrypt` directory. Set `stats.web_domain` and
`stats.web_email` in the inventory, or export `STATS_WEB_DOMAIN` and
`STATS_WEB_EMAIL`. Provide the restricted IAM credentials through
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally
`AWS_SESSION_TOKEN` before deployment. The credentials are written only to the
remote stack `.env` with mode `600`.

Certbot renews every 12 hours. The Nginx container watches the certificate
files and reloads itself after renewal.

Deploy it after the backend with:

```bash
./mesh.sh deploy-web
```
