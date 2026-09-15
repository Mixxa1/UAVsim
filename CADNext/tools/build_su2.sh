#!/bin/bash
# Builds SU2 (LGPL-2.1) — the RANS flow solver behind the aerodynamics test — into
# CADNext/third_party/su2/install, pinned to one release: the solver version is part of every
# aerodynamic result's provenance (spec §17), and a coefficient table must be reproducible.
#
# Serial MPI-free build with OpenMP (all cores of one machine), no algorithmic differentiation, no
# Python wrapper: CADNext only runs SU2_CFD as a separate process, the way cadnext_structural runs,
# which is also what keeps the LGPL satisfied.
#
# Needs: brew install libomp. Meson and Ninja come from SU2's own submodules.
#
# Of SU2's optional submodules only Eigen and MEL are fetched — the core needs them. Algorithmic
# differentiation (CoDiPack, MeDiPack, OpDiLib), Mutation++, CoolProp, MLPCpp and FADO are left out.
#
#   CADNext/tools/build_su2.sh
set -euo pipefail

SU2_TAG="v8.5.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$ROOT/third_party/su2"
SRC="$BASE/src"
PREFIX="$BASE/install"
LIBOMP="$(brew --prefix libomp)"

mkdir -p "$BASE"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$SU2_TAG" https://github.com/su2code/SU2.git "$SRC"
fi
( cd "$SRC" && test "$(git describe --tags --exact-match 2>/dev/null)" = "$SU2_TAG" ) \
  || { echo "SU2 source is not at $SU2_TAG"; exit 1; }

cd "$SRC"
python3 preconfigure.py --with-own-meson --no-codi --no-medi --no-opdi --no-mpp --no-coolprop --no-fado --no-mlpcpp

# Apple clang ships without an OpenMP runtime; libomp from Homebrew provides it.
export CPPFLAGS="-Xpreprocessor -fopenmp -I$LIBOMP/include"
export LDFLAGS="-L$LIBOMP/lib -lomp"
export NINJA="$SRC/ninja"
if [ ! -d build ]; then
  python3 externals/meson/meson.py setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dwith-mpi=disabled \
    -Dwith-omp=true \
    -Dcpu-arch=native \
    -Denable-autodiff=false \
    -Denable-directdiff=false \
    -Denable-pywrapper=false \
    -Denable-tests=false
fi
"$SRC/ninja" -C build -j "$(sysctl -n hw.ncpu)" install
echo "SU2 $SU2_TAG installed in $PREFIX"
