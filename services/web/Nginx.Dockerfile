# Nginx TLS terminator + proxy for stats web UI
# Security hardening based on OWASP Nginx recommended config pattern
FROM nginx:1.27-alpine

LABEL maintainer="Platform Engineering" \
      version="edge-2024" \
      description="Nginx TLS front-end for XRay stats proxy with Let's Encrypt integration"

COPY nginx-cert-watch.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/nginx-cert-watch.sh

EXPOSE 9093

CMD ["/usr/local/bin/nginx-cert-watch.sh"]
