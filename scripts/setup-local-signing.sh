#!/bin/bash
set -euo pipefail

SIGN_DIR="$HOME/Library/Application Support/MacDou/Signing"
KEYCHAIN="$SIGN_DIR/local-signing.keychain-db"
PASSWORD_FILE="$SIGN_DIR/password"
if [[ -e "$KEYCHAIN" || -e "$PASSWORD_FILE" ]]; then
    if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
        printf 'MacDou local signing is already configured.\n'
        exit 0
    fi
    printf 'Incomplete MacDou signing setup at %s\n' "$SIGN_DIR" >&2
    exit 1
fi

umask 077
mkdir -p "$SIGN_DIR"
TEMP_DIR="$(mktemp -d "$SIGN_DIR/setup.XXXXXX")"
PASSWORD="$(openssl rand -hex 32)"
openssl req -x509 -newkey rsa:3072 -nodes \
    -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem" -days 3650 \
    -subj '/CN=MacDou Local Signing' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=codeSigning' >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TEMP_DIR/key.pem" -in "$TEMP_DIR/cert.pem" \
    -out "$TEMP_DIR/identity.p12" -passout "pass:$PASSWORD" >/dev/null 2>&1
security create-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null
security import "$TEMP_DIR/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign >/dev/null
printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$KEYCHAIN" "$PASSWORD_FILE"
unlink "$TEMP_DIR/key.pem"
unlink "$TEMP_DIR/cert.pem"
unlink "$TEMP_DIR/identity.p12"
rmdir "$TEMP_DIR"
printf 'MacDou local signing is ready.\n'
