# Render web service: nginx + redis + 3 JVM (backstage, game_server, cross-server) + H5 client
FROM eclipse-temurin:8-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx redis-server mysql-client gettext-base tini ca-certificates \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default

# Game files: copy the contents of data.zip into ./game-data  (home/ and www/wwwroot/game/)
COPY game-data/home /home
COPY game-data/www/wwwroot/game /srv/game

COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/start.sh /usr/local/bin/start.sh
COPY scripts/patch-client.sh /usr/local/bin/patch-client.sh

RUN sed -i 's/\r$//' /usr/local/bin/start.sh /usr/local/bin/patch-client.sh \
 && chmod +x /usr/local/bin/start.sh /usr/local/bin/patch-client.sh \
 && mkdir -p /uploadfiles/design /uploadfiles/clazzs \
 && chmod -R a+rX /srv/game /home

EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/start.sh"]
