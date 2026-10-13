#!/usr/bin/env bash
# Usage: ./tests/run_smoke_tests.sh [--static] [--dist DIR]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)
      DIST="$ROOT_DIR/dist-static"
      shift
      ;;
    --dist)
      DIST="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

BIN="$DIST/bin/ssh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

version="$("$BIN" -V 2>&1)"
echo "$version" | grep -q '^OpenSSH_' || fail "ssh -V: $version"
pass "$version"

for tool in scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan; do
  test -x "$DIST/bin/$tool" || fail "$tool is missing"
done
test -x "$DIST/sbin/sshd" || fail "sshd is missing"
pass "has the suite"

# keys of all types, and a signature that verifies
for type in ed25519 ecdsa rsa; do
  "$DIST/bin/ssh-keygen" -q -t "$type" -N '' -f "$TMP/key-$type" || fail "ssh-keygen -t $type"
done
echo pmg >"$TMP/data"
"$DIST/bin/ssh-keygen" -Y sign -q -f "$TMP/key-ed25519" -n test "$TMP/data" || fail "sign"
echo "pmg $(cat "$TMP/key-ed25519.pub")" >"$TMP/signers"
"$DIST/bin/ssh-keygen" -Y verify -f "$TMP/signers" -I pmg -n test -s "$TMP/data.sig" \
  <"$TMP/data" >/dev/null || fail "verify"
pass "generates keys, signs, and verifies"

# the openssl tool makes a certificate, and speaks TLS with its own server
ossl="$DIST/bin/openssl"
"$ossl" version | grep -q '^OpenSSL ' || fail "openssl version"
"$ossl" req -x509 -newkey ed25519 -nodes -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
  -subj /CN=localhost -days 1 >"$TMP/req.log" 2>&1 || fail "openssl req: $(cat "$TMP/req.log")"
"$ossl" x509 -in "$TMP/tls.crt" -noout -subject | grep -q CN=localhost || fail "openssl x509"
pass "makes a certificate with openssl"
tls_port=$((40000 + $$ % 20000))
"$ossl" s_server -accept "$tls_port" -cert "$TMP/tls.crt" -key "$TMP/tls.key" -naccept 1 -quiet \
  >/dev/null 2>&1 &
tls_pid=$!
out=""
for _ in 1 2 3 4 5; do
  sleep 1
  out="$(echo | "$ossl" s_client -connect "127.0.0.1:$tls_port" -brief 2>&1)" && break
done
kill "$tls_pid" 2>/dev/null || true
case "$out" in *TLSv1.3*) ;; *) fail "openssl s_client: $out" ;; esac
pass "speaks TLS with openssl s_server and s_client"

# connects to a local sshd as the current user, runs a command, and copies a file through sftp
if [ "$(id -u)" != 0 ]; then
  cp "$TMP/key-ed25519.pub" "$TMP/authorized_keys"
  chmod 600 "$TMP/authorized_keys"
  port=$((20000 + $$ % 20000))
  cat >"$TMP/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $TMP/key-rsa
AuthorizedKeysFile $TMP/authorized_keys
PidFile $TMP/sshd.pid
StrictModes no
PasswordAuthentication no
Subsystem sftp $DIST/libexec/sftp-server
EOF
  # sshd starts its parts from the compiled-in prefix, which the archive is not at
  "$DIST/sbin/sshd" -f "$TMP/sshd_config" -o "SshdSessionPath=$DIST/libexec/sshd-session" \
    -o "SshdAuthPath=$DIST/libexec/sshd-auth" -E "$TMP/sshd.log" || fail "sshd: $(cat "$TMP/sshd.log")"
  trap 'kill "$(cat "$TMP/sshd.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$TMP"' EXIT
  PATH="$DIST/bin:$PATH"
  opts="-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $TMP/key-ed25519 -o Port=$port"
  # shellcheck disable=SC2086
  out="$("$BIN" $opts 127.0.0.1 echo pmg-ssh 2>/dev/null)" || fail "ssh failed: $(cat "$TMP/sshd.log")"
  [ "$out" = pmg-ssh ] || fail "ssh output: $out"
  pass "runs a command through ssh"
  # shellcheck disable=SC2086
  "$DIST/bin/sftp" -v $opts -b - 127.0.0.1 >"$TMP/sftp.log" 2>&1 <<EOF || fail "sftp failed: $(tail -n 25 "$TMP/sftp.log") $(tail -n 10 "$TMP/sshd.log")"
get $TMP/data $TMP/data.copy
EOF
  [ "$(cat "$TMP/data.copy")" = pmg ] || fail "sftp copy: $(cat "$TMP/data.copy")"
  pass "copies a file through sftp"
fi

if [ "$(uname -s)" = Linux ] && ! LC_ALL=C grep -a -q 'ld-musl' "$BIN"; then
  max="$(LC_ALL=C grep -aoh 'GLIBC_2\.[0-9]*' "$BIN" | sort -uV | tail -n 1)" || true
  if [ -n "$max" ]; then
    [ "$(printf '%s\n' "$max" GLIBC_2.17 | sort -V | tail -n 1)" = GLIBC_2.17 ] \
      || fail "needs $max, newer than GLIBC_2.17"
    pass "glibc floor ($max)"
  fi
fi

echo "all smoke tests passed"
