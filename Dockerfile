FROM debian:bookworm-slim

ARG SUPERCRONIC_VERSION=v0.2.33

# mariadb-client: mysql/mysqldump   jq+curl: Rotom/Discord/timezone APIs   python3: config.toml
# gawk: log parsing                 geographiclib-tools: Planimeter (km2 of geofences)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl gawk geographiclib-tools gzip jq mariadb-client python3 sed tar tzdata util-linux \
 && rm -rf /var/lib/apt/lists/*

# supercronic: cron for containers (runs in the foreground, logs to stdout)
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${arch}" \
 && chmod +x /usr/local/bin/supercronic

WORKDIR /blissey
COPY bin/ bin/
COPY lib/ lib/
COPY sql/ sql/
COPY tools/ tools/
COPY docker/ docker/
RUN chmod +x bin/blissey docker/entrypoint.sh tools/discord.sh

ENV PATH="/blissey/bin:${PATH}" \
    BLISSEY_LOG_STDOUT=1 \
    BLISSEY_DATA_DIR=/blissey/data \
    TZ=UTC

VOLUME ["/blissey/data"]

ENTRYPOINT ["/blissey/docker/entrypoint.sh"]
