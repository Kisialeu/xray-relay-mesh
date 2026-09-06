FROM nginx:1.27-alpine

COPY nginx-cert-watch.sh /docker-entrypoint.d/99-cert-watch.sh
RUN chmod 755 /docker-entrypoint.d/99-cert-watch.sh
