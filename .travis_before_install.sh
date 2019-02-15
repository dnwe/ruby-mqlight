#!/bin/sh

set -eu

if [ "${TRAVIS_OS_NAME:-}" = "osx" ]; then
  brew update
  brew install node cmake coreutils findutils || true
  SDKROOT="$(xcrun --show-sdk-path)"
  export SDKROOT
  CP=gcp
  FIND=gfind
  LIBDIR=lib64
else
  sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y
  sudo apt-get update -q
  sudo apt-get install -qqy nodejs cmake g++-4.8 libssl-dev libsasl2-dev sasl2-bin
  CP=cp
  FIND=find
  LIBDIR=lib
fi

git clone --depth=1 \
  https://github.com/mqlight/qpid-proton.git ~/.local/src/qpid-proton
cd ~/.local/src/qpid-proton \
  && mkdir -p build \
  && cd build \
  && cmake -DSASL_IMPL=none \
           -DSSL_IMPL=none \
           -DBUILD_JAVA=0 \
           -DBUILD_PERL=0 \
           -DBUILD_PHP=0 \
           -DBUILD_PYTHON=0 \
           -DNOBUILD_JAVA=TRUE \
           -DNOBUILD_PERL=TRUE \
           -DNOBUILD_PHP=TRUE \
           -DNOBUILD_PYTHON=TRUE \
           -DCMAKE_BUILD_TYPE=RelWithDebInfo \
           -DCMAKE_MACOSX_RPATH=1 \
           -DCMAKE_OSX_SYSROOT="${SYSROOT:-}" \
           -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
           -DCMAKE_INSTALL_PREFIX="${HOME}/.local" .. \
  && cmake --build . --target install
for F in $(${FIND} ~/.local/${LIBDIR} -maxdepth 1 -type l); do
  ${CP} --remove-destination ~/.local/${LIBDIR}/$(readlink $F) $F
done
${CP} -R ~/.local/include ${TRAVIS_BUILD_DIR}/include
${CP} -R ~/.local/${LIBDIR}/* ${TRAVIS_BUILD_DIR}/lib/ 
cd ${TRAVIS_BUILD_DIR} \
  && mkdir -p node_modules \
  && npm install core-js request js-yaml
