#!/usr/bin/env bash
# Because we're running this on a remote machine, we don't want to reinstall
# everything every time
set -e
opam switch 4.12.0;
git submodule update --init --recursive --depth 1

eval "$(opam env)"

rm /usr/local/opt/pcre/lib/libpcre.1.dylib

make setup
make config

# Remove dynamically linked libraries to force MacOS to use static ones
# This needs to be done after make setup but before make build-*
rm /usr/local/lib/libtree-sitter.0.0.dylib
rm /usr/local/lib/libtree-sitter.dylib

make build-core

mkdir -p artifacts
cp ./semgrep-core/_build/install/default/bin/semgrep-core artifacts
zip -r artifacts.zip artifacts
