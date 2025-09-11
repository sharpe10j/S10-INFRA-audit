# Node Exporter on server1 (systemd)
Run after a rebuild:

  sudo ./monitoring/exporters/node/install-node-exporter.sh

Prometheus target: server1:9100


# I only need node exporter installed on server1 becasue server1 is not part of the swarm.
# Installing node-exporter here and setting it up to run via systemd will allow it be collect data
# and be scraped by prometheus running as a service in the swarm stack