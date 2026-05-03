# Growatt MIC 3000 TL-X → Home Assistant Setup

## Architecture

```
Growatt MIC 3000 TL-X → ShineWiFi Datalogger (192.168.1.164)
        │
        │ MQTT over TLS (port 5279)
        ▼
EMQX broker (Docker, ports 5279 TLS + 1884 plain)
        │
        ├──→ GroBro (Docker, patched fork)
        │       │
        │       ├──→ Local Mosquitto (192.168.1.50:1883) → Home Assistant
        │       │         (HA auto-discovery + sensor state)
        │       │
        │       └──→ mqtt.growatt.com:7006 (cloud forwarding, keeps ShinePhone working)
        │
        └──→ Any other MQTT client can subscribe on port 1884
```

## Containers

| Container | Image | Purpose |
|-----------|-------|---------|
| `mosquitto` | eclipse-mosquitto:2.0.22 | Local MQTT broker (port 1883), used by HA, ESP32 sensors |
| `emqx-growatt` | emqx/emqx:latest | TLS MQTT broker (port 5279) for the datalogger. Plain MQTT on port 1884 for GroBro |
| `grobro` | grobro-mic (built from fork) | Bridges EMQX → local Mosquitto, decodes Growatt registers, publishes HA auto-discovery |

## Key Files

- `/usr/local/lib/grobro/certs/` — Let's Encrypt cert for `mqtt.cloudsafe.link`
- `/usr/local/lib/grobro/src/` — Patched GroBro fork (github.com/bdeak/GroBro, branch `mic-tlx-support`)
- `/usr/local/lib/mosquitto/config/` — Mosquitto config and password file

## DNS

- `mqtt.cloudsafe.link` → `192.168.1.50` (Route 53 A record)
- Fritz!Box DNS rebind exception for `cloudsafe.link`
- Datalogger configured to `mqtt.cloudsafe.link:5279`

## GroBro Patch (branch: mic-tlx-support)

- `grobro/model/growatt_mic_registers.json` — Register map for MIC TL-X (input registers 3000+)
- `grobro/model/growatt_registers.py` — Loads KNOWN_MIC_REGISTERS
- `grobro/grobro/client.py` — Detects `ZGQ`/`QUH` prefix, strips invalid chars from device_id
- `grobro/ha/client.py` — Adds MIC device type for HA discovery

## Rebuild & Deploy

```bash
cd /usr/local/lib/grobro/src
git pull
docker build -t grobro-mic .
docker kill grobro && docker rm grobro
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
```

## Full Stack Start (after reboot)

```bash
# Mosquitto
docker run -d \
 --name mosquitto \
 --restart=unless-stopped \
 -p 1883:1883 \
 -v /usr/local/lib/mosquitto/config:/mosquitto/config \
 -v /usr/local/lib/mosquitto/data:/mosquitto/data \
 -v /var/log/mosquitto:/mosquitto/log \
 eclipse-mosquitto:2.0.22

# EMQX
docker run -d \
 --name emqx-growatt \
 --restart=unless-stopped \
 -p 5279:5279 \
 -p 1884:1884 \
 -v /usr/local/lib/grobro/certs/chain-full.pem:/opt/emqx/etc/certs/cert.pem:ro \
 -v /usr/local/lib/grobro/certs/privkey.pem:/opt/emqx/etc/certs/key.pem:ro \
 -v /usr/local/lib/grobro/certs/isrg-root-x1.pem:/opt/emqx/etc/certs/cacert.pem:ro \
 -e EMQX_LISTENERS__SSL__DEFAULT__BIND=5279 \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CERTFILE=/opt/emqx/etc/certs/cert.pem \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__KEYFILE=/opt/emqx/etc/certs/key.pem \
 -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CACERTFILE=/opt/emqx/etc/certs/cacert.pem \
 -e EMQX_LISTENERS__TCP__DEFAULT__BIND=1884 \
 -e EMQX_ALLOW_ANONYMOUS=true \
 emqx/emqx:latest

# GroBro (wait 30s for EMQX to start)
sleep 30
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
```

## Certificate Renewal

The Let's Encrypt cert expires every 90 days. Renew with:

```bash
certbot renew
# Then rebuild cert chain:
CERTDIR=/usr/local/lib/grobro/certs
cat /etc/letsencrypt/live/mqtt.cloudsafe.link/fullchain.pem $CERTDIR/isrg-root-x1.pem > $CERTDIR/chain-full.pem
cp /etc/letsencrypt/live/mqtt.cloudsafe.link/privkey.pem $CERTDIR/privkey.pem
docker restart emqx-growatt
```

## Notes

- Datalogger reporting interval set to 1 minute (register 4 = 1, via ShinePhone app)
- `Pac` and `Fac` currently show 0.0 — register offsets may need adjustment
- Cloud forwarding (`GROWATT_CLOUD=true`) keeps ShinePhone app functional
- The `?` in the MQTT topic (`c/33/ZGQ0F6G1BK?`) is a quirk of the datalogger firmware
