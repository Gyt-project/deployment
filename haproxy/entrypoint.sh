#!/bin/sh
set -e

# Substitute environment variables into the HAProxy config template.
# Write to /tmp (writable by any user) rather than the read-only config dir.
envsubst < /usr/local/etc/haproxy/haproxy.cfg.template \
         > /tmp/haproxy.cfg

exec haproxy -f /tmp/haproxy.cfg "$@"
