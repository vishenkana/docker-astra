#!/bin/bash

ROOT=$(cd "$(dirname "$0")" && pwd)

# apt-get update
# apt-get install -y --no-install-recommends docker.io

docker run --rm -v $ROOT/build:$ROOT/build:rw -v $ROOT:$ROOT:ro -w $ROOT debian:12 bash ./build.sh
