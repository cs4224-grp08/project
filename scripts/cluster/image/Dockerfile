FROM ubuntu:24.04

ARG SLURM_TAG=slurm-26-05-2-1

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
	build-essential pkg-config wget ca-certificates bison flex python3 \
	libreadline-dev zlib1g-dev libicu-dev libcurl4-openssl-dev liblz4-dev libzstd-dev \
	xsltproc docbook-xml docbook-xsl libxml2-utils munge libmunge-dev rsync \
	&& rm -rf /var/lib/apt/lists/* \
	&& wget -qO- "https://github.com/SchedMD/slurm/archive/refs/tags/$SLURM_TAG.tar.gz" | tar -xz -C /tmp \
	&& cd "/tmp/slurm-$SLURM_TAG" \
	&& ./configure --prefix=/usr --sysconfdir=/etc/slurm --disable-static \
	&& make -j"$(nproc)" install \
	&& rm -rf "/tmp/slurm-$SLURM_TAG" \
	&& mkdir -p /etc/slurm && echo "CgroupPlugin=disabled" >/etc/slurm/cgroup.conf \
	&& useradd --create-home --home-dir /home/stuproj/cs08 --shell /bin/bash cs08

COPY --chmod=644 install_citus_slurm.sh /usr/local/src/
WORKDIR /home/stuproj/cs08
RUN runuser -u cs08 -- env HOME=/home/stuproj/cs08 MAKEFLAGS="-j$(nproc)" bash /usr/local/src/install_citus_slurm.sh \
	&& test -x pgsql/bin/postgres && test -f pgsql/lib/citus.so \
	&& rm -rf postgresql-* citus-*

COPY --chmod=755 scripts/cluster/image/start-slurm-daemon.sh /usr/local/bin/
ENTRYPOINT ["start-slurm-daemon.sh"]
