FROM busybox AS builder

WORKDIR /build
COPY ./ ./
RUN ./build.sh amd64

FROM scratch

COPY --from=builder /build/rootfs /

ENV PATH=/opt/coreutils-5.0/bin
ENV PATH=$PATH:/opt/binutils-2.30/bin
ENV PATH=$PATH:/opt/bzip2-1.0.8/bin
ENV PATH=$PATH:/opt/diffutils-2.7/bin
ENV PATH=$PATH:/opt/findutils-4.2.33/bin
ENV PATH=$PATH:/opt/gawk-3.0.4/bin
ENV PATH=$PATH:/opt/gcc-linaro-4.7-2013.11/bin
ENV PATH=$PATH:/opt/gmp-4.3.2,grep-2.4/bin
ENV PATH=$PATH:/opt/gzip-1.2.4/bin
ENV PATH=$PATH:/opt/m4-1.4.7/bin
ENV PATH=$PATH:/opt/make-4.4.1/bin
ENV PATH=$PATH:/opt/mpc-1.0.3/bin
ENV PATH=$PATH:/opt/mpfr-2.4.2/bin
ENV PATH=$PATH:/opt/patch-2.5.9/bin
ENV PATH=$PATH:/opt/sed-4.0.9/bin
ENV PATH=$PATH:/opt/tar-1.12/bin

ENTRYPOINT ["/bin/sh"]
