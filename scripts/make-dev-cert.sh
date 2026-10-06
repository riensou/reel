#!/usr/bin/env bash
# Creates a self-signed "reel-dev" code-signing identity in the login keychain.
# Signing every build with the same identity keeps macOS privacy permissions
# (Screen Recording, Microphone) from resetting after each rebuild.
set -euo pipefail
name="reel-dev"
if security find-identity -p codesigning | grep -q "\"$name\""; then
    echo "$name already exists"
    exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:reel 2>/dev/null
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P reel -T /usr/bin/codesign
echo "created $name"
