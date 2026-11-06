ARG DEBIAN_CODENAME=""
ARG NODEJS_VERSION=""

FROM debian:${DEBIAN_CODENAME}-slim

ARG DEBIAN_CODENAME=""
ARG NODEJS_VERSION=""
ENV DEBIAN_CODENAME=${DEBIAN_CODENAME}
ENV NODEJS_VERSION=${NODEJS_VERSION}

ADD docker-entrypoint.sh /docker-entrypoint.sh

RUN --mount=type=bind,source=install_script.sh,target=/mnt/docker/install_script.sh \
    --mount=type=bind,source=configuration.yaml,target=/mnt/docker/configuration.yaml \
    bash /mnt/docker/install_script.sh

VOLUME /data

CMD ["bash"]
SHELL ["/bin/bash", "-c"]

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]
