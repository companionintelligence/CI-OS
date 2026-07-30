#!/usr/bin/env bash
# Sets up the Cloudflare tunnel directory for ci-os-hub.
# Writes the shared CI-Local-Root-CA cert into tunnel/certs/ and ensures
# config.yml exists so cloudflared can start cleanly.
#
# Usage:
#   generate-tunnel-certs.sh [TUNNEL_DIR]
#   TUNNEL_DIR=./tunnel generate-tunnel-certs.sh
#
# Defaults to ./tunnel relative to CWD if not specified.

set -euo pipefail

TUNNEL_DIR="${1:-${TUNNEL_DIR:-./tunnel}}"
mkdir -p "${TUNNEL_DIR}/certs"

CERT_FILE="${TUNNEL_DIR}/certs/custom-ca.pem"

if [ ! -f "${CERT_FILE}" ]; then
  cat > "${CERT_FILE}" <<'CERT'
-----BEGIN CERTIFICATE-----
MIIDcDCCAlgCCQCOOTqLAGrBKjANBgkqhkiG9w0BAQsFADB6MQswCQYDVQQGEwJV
UzEOMAwGA1UECAwFU3RhdGUxDTALBgNVBAcMBENpdHkxHjAcBgNVBAoMFUNvbXBh
bmlvbkludGVsbGlnZW5jZTERMA8GA1UECwwITG9jYWxEZXYxGTAXBgNVBAMMEENJ
LUxvY2FsLVJvb3QtQ0EwHhcNMjYwMTEzMDIzMDA0WhcNMzYwMTExMDIzMDA0WjB6
MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFU3RhdGUxDTALBgNVBAcMBENpdHkxHjAc
BgNVBAoMFUNvbXBhbmlvbkludGVsbGlnZW5jZTERMA8GA1UECwwITG9jYWxEZXYx
GTAXBgNVBAMMEENJLUxvY2FsLVJvb3QtQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IB
DwAwggEKAoIBAQDFHQaQ4O2SA+RWMlff5El/F7zVQojt3u+O0efYnI7R/kHgDQ00
gi/Oi9BCpZAD8vXLAAPxqn0Uaq/EgRwSNMZqn2We3JgZdp8r+ARm4aVktP9QbcZQ
fe4brkmEJbpVrGnOsg9JnO8c9nlfhXWXDRhnI0n0mViwIGKs40paslUE8I2ZFArk
ta4VTBBg6hvQVYM+65k/Avuw9YCNDoY1TP6aqRkV8yYDc3WBBHm7khPFwN1mQt+U
+nnTfkdFPvwF7GgwSW3fOI4Mya4E2beimgk/DONypysLWof+ZbvCNyu0odEdGUbB
gR2gY8luLD3jeZhO0QHqUtaaY3NogTRWa/TPAgMBAAEwDQYJKoZIhvcNAQELBQAD
ggEBAJDPW6jPOB8Ancw9hpz6SeWZwi5Cmc7fVPdlBsl5+1cVCkku2tPrLeAHAmRz
n5VlxOY5JLVW95gRry68PlnweLeaqyyI4lMqGvdTeW0pwU2nmGtx7wAmljxwIY74
IG5GPUZWsmZBdbvkkA8NNXWmx+wvkcUoOnNfuwGZwXy71TX1rMlf3NW6ZTvnX5n4
aQ/AMtdn/GoCyEv/JrpfZUxaqoUAGDM7RRgKtH+eUvpD9ZSYFPwKaOSEkteIuyU1
vdiJ7h0NCmvzBnLwjSQENkHM45zn0yQ8y7u7jU8qVLzcJwjOnoj/z8mzJL47MS5B
7QUtOtIiKaEWr1aMrjTB91kDCz4=
-----END CERTIFICATE-----
CERT
  echo "CI-Local-Root-CA cert written to ${CERT_FILE}"
else
  echo "Cert already present at ${CERT_FILE}, skipping."
fi

# Ensure config.yml exists (cloudflared expects the file to be present)
touch "${TUNNEL_DIR}/config.yml"

echo "Tunnel directory ready at ${TUNNEL_DIR}"
