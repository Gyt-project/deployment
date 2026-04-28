Place your SSL certificate here as a single PEM file named `gyt.pem`.

The file must contain the certificate, the intermediate chain (if any), and
the private key — concatenated in that order:

    cat fullchain.pem privkey.pem > gyt.pem

For a self-signed certificate (dev / staging):

    ../scripts/gen-self-signed-cert.sh

For Let's Encrypt (production):

    certbot certonly --standalone -d yourdomain.com
    cat /etc/letsencrypt/live/yourdomain.com/fullchain.pem \
        /etc/letsencrypt/live/yourdomain.com/privkey.pem \
      > gyt.pem

This directory is .gitignored — never commit private keys.
