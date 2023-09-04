#!/usr/bin/env bash

set -ex

cd docs

rm -rf build
mkdir build

odin doc . -all-packages -doc-format

cd build

# This is the binary of https://github.com/laytan/pkg.odin-lang.org, built by `odin built . -out:odin-doc`
odin-doc ../docs.odin-doc ../odin-doc.json

# For GitHub pages, a CNAME file with the intended domain is required.
echo "odin-http.laytan.dev" > CNAME

cd ..

rm docs.odin-doc

cd ..
