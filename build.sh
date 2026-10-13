#!/usr/bin/env bash
# Usage: ./build.sh [--jobs N] [--clean] [--static]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CLEAN=0
STATIC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --static)
      STATIC=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

export JOBS
GLIBC_VER=2.17

OS="$(uname -s)"
ARCH="$(uname -m)"
[ "$ARCH" = arm64 ] && ARCH=aarch64

SUFFIX=""
[ "$STATIC" = 1 ] && SUFFIX="-static"
WORK="$ROOT_DIR/build$SUFFIX"
PREFIX="$WORK/deps"
DIST="$ROOT_DIR/dist$SUFFIX"

case "$OS-$ARCH" in
  Linux-x86_64 | Linux-aarch64)
    ZIG_TARGET=$ARCH-linux-gnu.$GLIBC_VER
    [ "$STATIC" = 1 ] && ZIG_TARGET=$ARCH-linux-musl
    ;;
  Darwin-aarch64 | Darwin-x86_64)
    ZIG_TARGET=native
    ;;
  *)
    echo "unsupported host $OS-$ARCH" >&2
    exit 1
    ;;
esac
if [ "$OS" != Linux ] && [ "$STATIC" = 1 ]; then
  echo "--static is only supported on Linux" >&2
  exit 1
fi

MAKE="${MAKE:-$(command -v gmake || command -v make)}"
"$MAKE" --version 2>/dev/null | grep -q 'GNU Make' || {
  echo "GNU make required" >&2
  exit 1
}

if [ "$ZIG_TARGET" = native ]; then
  export CC="zig cc" CXX="zig c++"
else
  export CC="zig cc -target $ZIG_TARGET" CXX="zig c++ -target $ZIG_TARGET"
fi
export AR="zig ar"
export RANLIB="zig ranlib"
[ "$OS" = Linux ] && export LD="zig ld.lld"
LDSTATIC=""
[ "$STATIC" = 1 ] && LDSTATIC="-static"
export LDSTATIC

if [ "$CLEAN" = 1 ]; then
  echo ">>> cleaning $WORK and $DIST"
  rm -rf "$WORK" "$DIST"
fi
mkdir -p "$WORK/src" "$PREFIX/include" "$PREFIX/lib"

cd "$WORK/src"

# copies a submodule into the build dir
prepare() {
  [ -d "$1" ] && return
  if [ ! -f "$ROOT_DIR/vendor/$1/.git" ] && [ ! -d "$ROOT_DIR/vendor/$1/.git" ]; then
    echo "vendor/$1 is missing, run: git submodule update --init --depth 1" >&2
    exit 1
  fi
  echo ">>> preparing $1 ($(git -C "$ROOT_DIR/vendor/$1" describe --tags 2>/dev/null || echo unknown))"
  cp -R "$ROOT_DIR/vendor/$1" "$1"
  rm -rf "$1/.git"
}

prepare openssh
prepare openssl
prepare zlib

# drops unused functions at link time
GC_CFLAGS="-ffunction-sections -fdata-sections"
GC_LDFLAGS="-Wl,--gc-sections"
[ "$OS" = Darwin ] && GC_LDFLAGS="-Wl,-dead_strip"

echo ">>> zlib"
(
  cd zlib
  CFLAGS="-Os $GC_CFLAGS" ./configure --static --prefix="$PREFIX" >/dev/null
  "$MAKE" -j"$JOBS" libz.a
  "$MAKE" install >/dev/null
)

echo ">>> openssl"
(
  cd openssl
  [ -f Makefile ] && "$MAKE" distclean >/dev/null 2>&1 || true
  # OpenSSH only needs libcrypto, the openssl tool also libssl; without legacy and rarely used parts
  ./Configure no-shared no-dso no-tests no-docs no-module no-engine no-legacy no-comp \
    no-ocsp no-ts no-cms no-srp no-psk no-ct no-sctp no-quic no-srtp \
    no-dsa no-ec2m no-rfc3779 no-gost no-idea no-seed no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-mdc2 \
    no-whirlpool no-bf no-cast no-camellia no-aria no-sm2 no-sm3 no-sm4 no-cmac no-siphash \
    --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-Os $GC_CFLAGS" >/dev/null
  "$MAKE" -j"$JOBS" build_libs >/dev/null
  # the objects of the openssl tool, which is linked into the binary of OpenSSH
  "$MAKE" -j"$JOBS" apps/openssl >/dev/null
  "$MAKE" install_dev >/dev/null
)

echo ">>> openssh"
(
  cd openssh
  # the copy of the sources has new timestamps, which make a shipped configure stale
  autoreconf -fi >/dev/null 2>&1
  [ -f Makefile ] && "$MAKE" distclean >/dev/null 2>&1 || true
  LIBS=""
  [ "$OS" = Linux ] && LIBS="-lpthread"
  ./configure --prefix=/usr/local --sysconfdir=/etc/ssh --with-ssl-dir="$PREFIX" \
    --with-zlib="$PREFIX" --without-pam --without-selinux --without-kerberos5 --disable-strip \
    CFLAGS="-Os $GC_CFLAGS" CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="$LDSTATIC -L$PREFIX/lib $GC_LDFLAGS -s" LIBS="$LIBS" >/dev/null
  # scp and sftp run the ssh of the prefix, which the archive is not at, so they use PATH
  "$MAKE" -j"$JOBS" SSH_PROGRAM=ssh >/dev/null
  rm -rf "$DIST"
  mkdir -p "$DIST/bin" "$DIST/sbin" "$DIST/libexec"

  # one binary with all tools, which links libcrypto and zlib once; the tools are symlinks to it
  # and run by the name they are called with. Each tool is linked to a single object with the
  # parts of libssh it needs, whose symbols are local but its main, as the tools define globals
  # with the same names, and libssh calls functions that each tool defines in its own way.
  MULTI="$WORK/multi"
  rm -rf "$MULTI"
  mkdir -p "$MULTI"
  # shellcheck disable=SC2016
  printf 'print-%%:\n\t@echo $($*)\n' >"$MULTI/print.mk"
  var() { "$MAKE" -s -f Makefile -f "$MULTI/print.mk" "print-$1" 2>/dev/null; }
  TOOLS="ssh:SSHOBJS sshd:SSHDOBJS sshd-session:SSHD_SESSION_OBJS sshd-auth:SSHD_AUTH_OBJS"
  TOOLS="$TOOLS scp:SCP_OBJS sftp:SFTP_OBJS sftp-server:SFTPSERVER_OBJS ssh-add:SSHADD_OBJS"
  TOOLS="$TOOLS ssh-agent:SSHAGENT_OBJS ssh-keygen:SSHKEYGEN_OBJS ssh-keyscan:SSHKEYSCAN_OBJS"
  TOOLS="$TOOLS ssh-keysign:SSHKEYSIGN_OBJS ssh-pkcs11-helper:P11HELPER_OBJS"
  TOOLS="$TOOLS ssh-sk-helper:SKHELPER_OBJS openssl:-"
  {
    echo 'int main(int, char **);'
    for entry in $TOOLS; do echo "int ${entry%%:*}_multi_main(int, char **);" | tr - _; done
    echo '#include <string.h>'
    echo '#include <stdio.h>'
    echo 'static const struct { const char *name; int (*main)(int, char **); } tools[] = {'
    for entry in $TOOLS; do
      name="${entry%%:*}"
      echo "  { \"$name\", $(echo "$name" | tr - _)_multi_main },"
    done
    echo '};'
    cat <<'EOF'
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

/* openssl req needs a config file, which hosts without OpenSSL lack, so it falls back to the one
   in share/openssl of the package, found from the real path of this binary in bin */
static void default_config(void) {
  char exe[PATH_MAX], real[PATH_MAX], conf[PATH_MAX], *slash;
  if (getenv("OPENSSL_CONF") || access("/etc/ssl/openssl.cnf", R_OK) == 0)
    return;
#ifdef __APPLE__
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0)
    return;
#else
  ssize_t length = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (length <= 0)
    return;
  exe[length] = '\0';
#endif
  if (!realpath(exe, real))
    return;
  for (int level = 0; level < 2; level++) {
    if (!(slash = strrchr(real, '/')))
      return;
    *slash = '\0';
  }
  snprintf(conf, sizeof(conf), "%s/share/openssl/openssl.cnf", real);
  if (access(conf, R_OK) == 0)
    setenv("OPENSSL_CONF", conf, 0);
}

int main(int argc, char **argv) {
  const char *name = argc > 0 ? strrchr(argv[0], '/') : NULL;
  name = name ? name + 1 : (argc > 0 ? argv[0] : "");
  for (unsigned i = 0; i < sizeof(tools) / sizeof(tools[0]); i++)
    if (strcmp(name, tools[i].name) == 0) {
      if (strcmp(name, "openssl") == 0)
        default_config();
      return tools[i].main(argc, argv);
    }
  fprintf(stderr, "multi-call OpenSSH binary, run it as one of its tools by name\n");
  return 1;
}
EOF
  } >"$MULTI/multi.c"
  objects=""
  for entry in $TOOLS; do
    name="${entry%%:*}"
    [ "$name" = openssl ] && continue
    sym="$(echo "$name" | tr - _)_multi_main"
    # shellcheck disable=SC2046
    if [ "$OS" = Linux ]; then
      ld -r -o "$MULTI/$name.o" $(var "${entry##*:}") -L. -Lopenbsd-compat \
        --start-group -lssh -lopenbsd-compat --end-group
      # the thunks of retpoline are shared by name
      objcopy --redefine-sym "main=$sym" --keep-global-symbol="$sym" \
        --keep-global-symbol=__llvm_retpoline_r11 "$MULTI/$name.o"
    else
      # the file of main is compiled again with another name for it
      main_file="$name-main"
      [ "$name" = sftp-server ] || main_file="$name"
      rm -f "$main_file.o"
      "$MAKE" "$main_file.o" SSH_PROGRAM=ssh CFLAGS="$(var CFLAGS) -Dmain=$sym" >/dev/null
      ld -r -o "$MULTI/$name.o" -exported_symbol "_$sym" $(var "${entry##*:}") \
        -L. -Lopenbsd-compat -lssh -lopenbsd-compat
      # the export list may not be applied to objects, then nmedit makes the others local
      if [ "$(nm -gU "$MULTI/$name.o" | grep -c ' T \| D \| S \| B ')" != 1 ]; then
        echo "_$sym" >"$MULTI/$name.exports"
        nmedit -s "$MULTI/$name.exports" "$MULTI/$name.o"
      fi
    fi
    objects="$objects $MULTI/$name.o"
  done
  # the openssl tool, from its objects and the libraries they need
  OSSL="$WORK/src/openssl"
  if [ "$OS" != Linux ]; then
    rm -f "$OSSL/apps/openssl-bin-openssl.o"
    "$MAKE" -C "$OSSL" apps/openssl-bin-openssl.o CPPFLAGS="-Dmain=openssl_multi_main" >/dev/null
  fi
  OSSL_OBJS="$(cd "$OSSL" && find apps -name 'openssl-bin-*.o' | sort | sed "s|^|$OSSL/|")"
  # shellcheck disable=SC2086
  if [ "$OS" = Linux ]; then
    ld -r -o "$MULTI/openssl.o" $OSSL_OBJS "$OSSL/apps/libapps.a" "$OSSL/libssl.a"
    objcopy --redefine-sym main=openssl_multi_main --keep-global-symbol=openssl_multi_main \
      --keep-global-symbol=__llvm_retpoline_r11 "$MULTI/openssl.o"
  else
    ld -r -o "$MULTI/openssl.o" -exported_symbol _openssl_multi_main $OSSL_OBJS \
      "$OSSL/apps/libapps.a" "$OSSL/libssl.a"
    if [ "$(nm -gU "$MULTI/openssl.o" | grep -c ' T \| D \| S \| B ')" != 1 ]; then
      echo _openssl_multi_main >"$MULTI/openssl.exports"
      nmedit -s "$MULTI/openssl.exports" "$MULTI/openssl.o"
    fi
  fi
  objects="$objects $MULTI/openssl.o"
  # shellcheck disable=SC2046,SC2086
  $CC -O2 -o "$DIST/bin/ssh" "$MULTI/multi.c" $objects $LDSTATIC -L"$PREFIX/lib" \
    $GC_LDFLAGS -s $(var LIBS) $(var SSHDLIBS) $(var CHANNELLIBS)
  for entry in $TOOLS; do
    name="${entry%%:*}"
    case "$name" in
      ssh) ;;
      sshd) ln -s ../bin/ssh "$DIST/sbin/$name" ;;
      scp | sftp | ssh-add | ssh-agent | ssh-keygen | ssh-keyscan | openssl) ln -s ssh "$DIST/bin/$name" ;;
      *) ln -s ../bin/ssh "$DIST/libexec/$name" ;;
    esac
  done

  mkdir -p "$DIST/share/openssl"
  cp "$OSSL/apps/openssl.cnf" "$DIST/share/openssl/openssl.cnf"
  for section in 1 5 8; do
    mkdir -p "$DIST/share/man/man$section"
    cp ./*."$section" "$DIST/share/man/man$section/"
  done
)

BIN="$DIST/bin/ssh"
echo
echo ">>> done: $BIN"
"$BIN" -V 2>&1
if [ "$OS" = Linux ]; then
  if [ "$STATIC" = 1 ]; then
    # static musl libc embeds the loader path as a string, so check for an interpreter header.
    if readelf -l "$BIN" | grep -q INTERP; then
      echo "WARNING: ssh references a dynamic loader, not fully static" >&2
    else
      echo "fully static"
    fi
  else
    echo "only glibc is dynamic"
  fi
else
  otool -L "$BIN"
  # only the system may supply libraries, not Homebrew or /usr/local
  if otool -L "$BIN" | tail -n +2 | grep -q -v -E '^[[:space:]]+(/usr/lib/|/System/)'; then
    echo "ERROR: ssh links a library that is not part of macOS" >&2
    exit 1
  fi
fi
