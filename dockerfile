# syntax=docker/dockerfile:1

ARG SGDK_VERSION=v2.11
ARG BINUTILS_VERSION=2.42
ARG GCC_VERSION=13.2.0

# ------------------------------------------------------------------------------
# Stage 1: m68k-elf cross toolchain, compiled natively for the build platform
# ------------------------------------------------------------------------------
FROM debian:bookworm-slim AS gcc-build
ARG BINUTILS_VERSION
ARG GCC_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates wget xz-utils texinfo \
        libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PREFIX=/opt/m68k TARGET=m68k-elf PATH=/opt/m68k/bin:$PATH
WORKDIR /tmp/build

RUN wget -q https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz \
    && wget -q https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz \
    && tar xf binutils-${BINUTILS_VERSION}.tar.xz \
    && tar xf gcc-${GCC_VERSION}.tar.xz

RUN mkdir binutils-obj && cd binutils-obj \
    && ../binutils-${BINUTILS_VERSION}/configure --target=$TARGET --prefix=$PREFIX \
        --disable-nls --disable-werror --enable-plugins \
    && make -j"$(nproc)" && make install-strip

RUN mkdir gcc-obj && cd gcc-obj \
    && ../gcc-${GCC_VERSION}/configure --target=$TARGET --prefix=$PREFIX \
        --enable-languages=c --with-cpu=m68000 --disable-multilib \
        --without-headers --with-newlib --enable-lto \
        --disable-nls --disable-shared --disable-threads \
        --disable-libssp --disable-libquadmath --disable-libgomp --disable-libatomic \
    && make -j"$(nproc)" all-gcc all-target-libgcc \
    && make install-strip-gcc install-target-libgcc

# SGDK builds with -flto; ar/nm need the LTO plugin to handle those objects
RUN mkdir -p $PREFIX/lib/bfd-plugins \
    && ln -s ../../libexec/gcc/$TARGET/${GCC_VERSION}/liblto_plugin.so $PREFIX/lib/bfd-plugins/

# ------------------------------------------------------------------------------
# Stage 2: SGDK native tools + libmd
# ------------------------------------------------------------------------------
FROM debian:bookworm-slim AS sgdk-build
ARG SGDK_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git wget unzip openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

COPY --from=gcc-build /opt/m68k /opt/m68k
ENV GDK=/sgdk PATH=/opt/m68k/bin:/sgdk/bin:$PATH

RUN git clone --depth 1 --branch ${SGDK_VERSION} https://github.com/Stephane-D/SGDK.git $GDK
WORKDIR $GDK

# Drop Windows binaries and prebuilt libs
RUN rm -f bin/*.exe bin/*.dll lib/*.a

RUN gcc -O2 tools/bintos/src/bintos.c -o bin/bintos \
    && gcc -O2 -include stdint.h -Itools/xgmtool/inc tools/xgmtool/src/*.c -lm -o bin/xgmtool \
    && g++ -std=c++20 -O2 -Itools/convsym/include tools/convsym/src/main.cpp -o bin/convsym \
    && make -C tools/sjasm/src && cp tools/sjasm/src/sjasm bin/

RUN wget -q --user-agent="Mozilla/4.0" -O /tmp/maccer.zip \
        http://gendev.spritesmind.net/files/maccer-026k02.zip \
    && unzip -q /tmp/maccer.zip -d /tmp/maccer \
    && gcc -O2 -DVERSION_STRING='"2.6"' -DKMOD_VERSION='"0.2"' /tmp/maccer/main.c -lm -o bin/mac68k

RUN make -f makelib.gen release && make -f makelib.gen debug

# ------------------------------------------------------------------------------
# Stage 3: Toolchain runtime image
# ------------------------------------------------------------------------------
FROM debian:bookworm-slim AS toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
        make openjdk-17-jre-headless libgmp10 libmpfr6 libmpc3 zlib1g libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 m68k \
    && mkdir /m68k && chown m68k:m68k /m68k

COPY --from=gcc-build /opt/m68k /opt/m68k
COPY --from=sgdk-build /sgdk /sgdk
ENV GDK=/sgdk PATH=/opt/m68k/bin:/sgdk/bin:$PATH

USER m68k
WORKDIR /m68k
ENTRYPOINT ["make", "-f", "/sgdk/makefile.gen"]
CMD ["release"]

# ------------------------------------------------------------------------------
# Stage 4: Builder
# ------------------------------------------------------------------------------
FROM toolchain AS builder
COPY --chown=m68k:m68k . /m68k/
ARG BUILD_TYPE=release
RUN make -f /sgdk/makefile.gen ${BUILD_TYPE}

# ------------------------------------------------------------------------------
# Stage 5: Artifact export   (docker build -o out .)
# ------------------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /m68k/out/ /