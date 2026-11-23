#!/usr/bin/env bash
# One time, on the build Mac: makes a self signed code signing identity for Capio in its own keychain.
# With the same identity on every build, macOS keeps Screen Recording and the Keychain item across updates.
# Leaves: ~/Library/Keychains/capio-signing.keychain-db, ~/.capio-signing/keychain-password and ~/.capio-signing/identity (SHA-1).
set -euo pipefail
umask 077
NAME="Capio Code Signing (SolutionMAX)"
DIR="$HOME/.capio-signing"
KC="$HOME/Library/Keychains/capio-signing.keychain-db"
[ ! -e "$KC" ] || { echo "$KC already exists; remove it first if you really want a new identity" >&2; exit 1; }

mkdir -p "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl rand -hex 24 > "$DIR/keychain-password"
openssl rand -hex 24 > "$WORK/p12-password"

cat > "$WORK/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/req.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "file:$WORK/p12-password"

# Passwords go through `security -i` on stdin, so they never show up in the process list.
run() { security -i >/dev/null; }
printf 'create-keychain -p "%s" "%s"\n' "$(cat "$DIR/keychain-password")" "$KC" | run
security set-keychain-settings "$KC"
printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$DIR/keychain-password")" "$KC" | run
printf 'import "%s" -k "%s" -P "%s" -T /usr/bin/codesign\n' "$WORK/id.p12" "$KC" "$(cat "$WORK/p12-password")" | run
printf 'set-key-partition-list -S apple-tool:,apple: -s -k "%s" "%s"\n' "$(cat "$DIR/keychain-password")" "$KC" | run

# Keep the keychains that are already searched, add ours.
existing=()
while IFS= read -r line; do existing+=("$(echo "$line" | sed 's/^ *"//; s/"$//')"); done < <(security list-keychains -d user)
security list-keychains -d user -s "${existing[@]}" "$KC"

security find-identity -p codesigning "$KC" | awk '/Capio Code Signing/ { print $2; exit }' > "$DIR/identity"
[ -s "$DIR/identity" ] || { echo "the identity did not land in the keychain" >&2; exit 1; }
echo "identity $(cat "$DIR/identity") in $KC"
