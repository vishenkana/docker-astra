#!/bin/bash

ROOT=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y --no-install-recommends debootstrap dpkg-dev tar

(
    source $ROOT/debootstrap.sh 1.8.0 1.8_x86-64 voronezh
)
