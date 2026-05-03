#!/bin/bash

BASEDIR=/usr/local/lib/grobro
CERTDIR=$BASEDIR/certs
SRCDIR=$BASEDIR/src

# --- EMQX ---
docker kill emqx-growatt 2>/dev/null && docker rm emqx-growatt 2>/dev/null

docker run -d \
 --name emqx-growatt \
 --restart=unless-stopped \
 -p 5279:5279 \
 -p 1884:1884 \
 -v $CERTDIR/chain-full.pem:/opt/emqx/etc/certs/cert.pem:ro \
 -v $CERTDIR/privkey.pem:/opt/emqx/etc/certs/key.pem:ro \
 -v $CERTDIR/isrg-root-x1.pem:/opt/emqx/etc/certs/cacert.pem:ro \
 -e EMQX_LISTENERS__SSL__DEFAULT__BIND=5279 \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CERTFILE=/opt/emqx/etc/certs/cert.pem \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__KEYFILE=/opt/emqx/etc/certs/key.pem \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CACERTFILE=/opt/emqx/etc/certs/cacert.pem \
 -e EMQX_LISTENERS__TCP__DEFAULT__BIND=1884 \
 -e EMQX_ALLOW_ANONYMOUS=true \
 emqx/emqx:latest

# --- GroBro ---
if [ -d "$SRCDIR" ]; then
 cd $SRCDIR && git pull
else
 git clone -b mic-tlx-support https://github.com/bdeak/GroBro.git $SRCDIR
fi

docker build -t grobro-mic $SRCDIR

# wait for EMQX
echo "Waiting for EMQX to start..."
sleep 30

docker kill grobro 2>/dev/null && docker rm grobro 2>/dev/null

docker run -d \
 --name grobro \
 --restart=unless-stopped \
 -e SOURCE_MQTT_HOST=192.168.1.50 \
 -e SOURCE_MQTT_PORT=1884 \
 -e SOURCE_MQTT_TLS=false \
 -e TARGET_MQTT_HOST=192.168.1.50 \
 -e TARGET_MQTT_PORT=1883 \
 -e TARGET_MQTT_TLS=false \
 -e TARGET_MQTT_USER=smarthome \
 -e TARGET_MQTT_PASS=piroska \
 -e GROWATT_CLOUD=true \
 -e LOG_LEVEL=DEBUG \
 grobro-mic
