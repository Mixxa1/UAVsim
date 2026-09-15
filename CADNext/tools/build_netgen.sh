#!/bin/bash
# Builds Netgen (LGPL-2.1) — the volume mesher for structural analysis of CAD solids — into
# CADNext/third_party/netgen/install, pinned to one release so meshes are reproducible
# (a mesher version is part of a structural result's provenance, spec §17).
#
# Python, GUI and MPI are off: CADNext only needs the OCC geometry meshing library. Netgen is
# linked dynamically, which is what LGPL requires for a closed application.
#
#   CADNext/tools/build_netgen.sh
#   cmake -S CADNext -B <build> -DCADNEXT_WITH_OCCT=ON -DCADNEXT_WITH_NETGEN=ON \
#         -DNetgen_DIR=$PWD/CADNext/third_party/netgen/install/lib/cmake/netgen
set -euo pipefail

NETGEN_TAG="v6.2.2607"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$ROOT/third_party/netgen"
SRC="$BASE/src"
BUILD="$BASE/build"
PREFIX="$BASE/install"
OCCT_DIR="${OpenCASCADE_DIR:-$(brew --prefix opencascade)/lib/cmake/opencascade}"

mkdir -p "$BASE"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$NETGEN_TAG" https://github.com/NGSolve/netgen.git "$SRC"
fi
( cd "$SRC" && test "$(git describe --tags --exact-match 2>/dev/null)" = "$NETGEN_TAG" ) \
  || { echo "netgen source is not at $NETGEN_TAG"; exit 1; }

cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DUSE_SUPERBUILD=OFF \
  -DUSE_PYTHON=OFF \
  -DUSE_GUI=OFF \
  -DUSE_MPI=OFF \
  -DUSE_OCC=ON \
  -DUSE_JPEG=OFF \
  -DUSE_MPEG=OFF \
  -DUSE_NATIVE_ARCH=OFF \
  -DENABLE_UNIT_TESTS=OFF \
  -DBUILD_STUB_FILES=OFF \
  -DOpenCASCADE_DIR="$OCCT_DIR"
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"
cmake --install "$BUILD"
echo "netgen $NETGEN_TAG installed in $PREFIX"
