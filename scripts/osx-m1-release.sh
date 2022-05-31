# Because we're running this on a remote machine, we don't want to reinstall
# everything every time
#!/usr/bin/env bash
opam switch 4.12.0;
git submodule update --init --recursive --depth 1

eval "$(opam env)"

make setup
make config

make build-core

mkdir -p artifacts
cp ./semgrep-core/_build/install/default/bin/semgrep-core artifacts
zip -r artifacts.zip artifacts
