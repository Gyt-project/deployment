FROM haproxy:2.9-alpine

# haproxy:2.9-alpine sets USER haproxy; switch to root for package install
# then restore the non-root user so haproxy runs unprivileged.
USER root
RUN apk add --no-cache gettext

COPY haproxy.cfg.template /usr/local/etc/haproxy/haproxy.cfg.template
COPY entrypoint.sh        /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER haproxy
ENTRYPOINT ["/entrypoint.sh"]
