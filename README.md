# openssh-static

Portable builds of [OpenSSH](https://www.openssh.com/), the secure shell suite (`ssh`, `scp`, `sftp`, `ssh-keygen`,
`ssh-agent`, `ssh-add`, `ssh-keyscan`, and `sshd`) and the `openssl` tool, with [OpenSSL](https://www.openssl.org/) and
[zlib](https://zlib.net/) linked in statically, built with [zig](https://ziglang.org) as the C toolchain.

- Linux glibc: only glibc is linked dynamically, and only symbols up to glibc 2.17, so the
  binaries run on anything from CentOS 7 onwards
- Linux musl (`--static`): fully static, no runtime dependencies at all (e.g. Alpine)
- macOS: only libSystem is dynamic (it ships with macOS, which has no fully static binaries)

All tools are a single binary, `bin/ssh`, that runs as the tool whose name it is called with (like
BusyBox), so that OpenSSL and zlib are linked in once. The other names in `bin`, `sbin`, and
`libexec` are symlinks to it, so copy or link the names that you need together with `ssh`, or
use the symlinks of the archive; called by a name that is not a tool, it prints a message and exits.

The build has no PAM, no Kerberos, no SELinux, and no built-in FIDO support (security keys work
through a `SecurityKeyProvider`). `scp` and `sftp` start the `ssh` found in `PATH`, not one at a
compiled-in path.

`openssl` is another name of the binary, with TLS (`s_client`, `s_server`) but without the
commands for OCSP, time stamps, CMS, DSA, and the legacy ciphers (Blowfish, CAST, RC2, RC4, IDEA,
SEED, Camellia, and ARIA). Its configuration and certificates are in `/etc/ssl`.

`sshd` is built, but not configured: it needs a host key and a config file (`-h`, `-f`). It starts
`sshd-session` and `sshd-auth` from the prefix it was compiled for, so point it to `libexec` with
`-o SshdSessionPath=...` and `-o SshdAuthPath=...`. The system config of `ssh` is `/etc/ssh`, and
`-F` selects another file.

## Prerequisites

- `zig`, GNU make (the `make` 3.81 of macOS is enough), `git`
- `autoconf` and `automake` (the git tree of OpenSSH ships no `configure` script), and `perl` (for OpenSSL)

## Installation

Clone the repo with submodules (shallow, the history of the vendored projects is not needed):

```shell
git clone --recurse-submodules --shallow-submodules https://github.com/zshsetup/openssh-static
cd openssh-static
```

## Usage

```shell
./build.sh
```

Output is installed under `dist/`:

- `dist/bin/ssh`: the binary with all tools; copy it anywhere on your `PATH`, and the tools you
  need as symlinks to it (`scp`, `sftp`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `ssh-keyscan`,
  `openssl`)
- `dist/sbin/sshd`: a symlink for the server
- `dist/libexec`: symlinks for the parts of `sshd` and the helper programs of the suite
- `dist/share/man`: the man pages

Pass `--static` for the fully static musl build on Linux (output in `dist-static/`), `--clean` to
remove previous build output first, and `--jobs N` to control parallelism.

To run the smoke tests against the build:

```shell
./tests/run_smoke_tests.sh            # dist/
./tests/run_smoke_tests.sh --static   # dist-static/
```

## Releases

Publishing a GitHub release tagged like the contents of `VERSION`, the tag checked out in
`vendor/openssh`, builds and attaches `openssh-static-<platform>.tar.gz` for `macos-arm64`,
`linux-amd64`, `linux-arm64`, `linux-musl-amd64`, and `linux-musl-arm64`, together with the sources
they were built from (`openssh-static-sources.tar.gz`).

To update a vendored project, check out a new release tag in its submodule, commit it, and update
`VERSION` if it is the main one, e.g.
`git -C vendor/openssh fetch --depth 1 origin tag v10.6p1 && git -C vendor/openssh checkout v10.6p1`.

## Acknowledgments

This repository builds and vendors the following upstream projects, unmodified, as git
submodules under `vendor/`. Credit goes to their respective authors:

- [OpenSSH](https://www.openssh.com/) by Tatu Ylonen, Theo de Raadt, Markus Friedl, and the OpenSSH developers
- [OpenSSL](https://www.openssl.org/) by The OpenSSL Project Authors
- [zlib](https://zlib.net/) by Jean-loup Gailly and Mark Adler

## License

MIT for the code in this repository. See `NOTICE` for the licenses of the upstream projects and the
resulting binaries, which are BSD-style and ISC (OpenSSH), Apache-2.0 (OpenSSL), and the zlib license.
