#!/bin/bash

# <UDF name="enable_store_log" label="Store log - persists SMP queues to append only log and restores them upon server restart." default="on" oneof="on, off" />
# <UDF name="api_token" label="Linode API token - enables StackScript to create tags containing SMP server FQDN / IP address, CA certificate fingerprint and server version. Use `fqdn#fingerprint` or `ip#fingerprint` as SMP server address in the client. Note: minimal permissions token should have are - read/write access to `linodes` (to update linode tags) and `domains` (to add A record for the chosen 3rd level domain)" default="" />
# <UDF name="fqdn" label="FQDN (Fully qualified domain name) - provide third level domain name (ex: smp.example.com). If provided will be used instead of IP address." default="" />

# Log all stdout output to stackscript.log
exec &> >(tee -i /var/log/stackscript.log)

# Uncomment next line to enable debugging features
# set -xeo pipefail

cd $HOME

# https://superuser.com/questions/1638779/automatic-yess-to-linux-update-upgrade
# https://superuser.com/questions/1412054/non-interactive-apt-upgrade
sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  update

sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  dist-upgrade

# TODO install unattended-upgrades
sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  install jq

# Add firewall
echo "y" | ufw enable

# Open ports
ufw allow ssh
ufw allow https
ufw allow 5223

# Download latest release
bin_dir="/opt/simplex/bin"
binary="$bin_dir/smp-server"
mkdir -p $bin_dir
curl -L -o $binary https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
chmod +x $binary

# / Add to PATH
cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOT
# Add to PATH /

# Source and test PATH
source /etc/profile.d/simplex.sh
smp-server --version

# Initialize server
init_opts=()

[[ $ENABLE_STORE_LOG == "on" ]] && init_opts+=(-l)

ip_address=$(curl ifconfig.me)
init_opts+=(--ip $ip_address)

[[ -n "$FQDN" ]] && init_opts+=(-n $FQDN)

smp-server init "${init_opts[@]}"

# Server fingerprint
fingerprint=$(cat /etc/opt/simplex/fingerprint)

# Determine server address for welcome script and tag
# ! If FQDN was provided and used as part of server initialization, client will not validate this server by IP address,
# ! so we have to specify FQDN for server address regardless of creation of A record in Linode
# ! https://hackage.haskell.org/package/x509-validation-1.6.10/docs/src/Data-X509-Validation.html#validateCertificateName
if [[ -n "$FQDN" ]]; then
  server_address=$FQDN
else
  server_address=$ip_address
fi

# Set up welcome script
on_login_script="/opt/simplex/on_login.sh"

# / Welcome script
cat <<EOT >> $on_login_script
#!/bin/bash

fingerprint=\$1
server_address=\$2

cat <<EOF
********************************************************************************

SMP server address: smp://\$fingerprint@\$server_address
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 443 (HTTPS), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF

EOT
# Welcome script /

chmod +x $on_login_script
echo "bash $on_login_script $fingerprint $server_address" >> /root/.bashrc

# Create A record and update Linode's tags
if [[ -n "$API_TOKEN" ]]; then
  if [[ -n "$FQDN" ]]; then
    domain_address=$(echo $FQDN | rev | cut -d "." -f 1,2 | rev)
    domain_id=$(curl -H "Authorization: Bearer $API_TOKEN" https://api.linode.com/v4/domains \
    | jq --arg da "$domain_address" '.data[] | select( .domain == $da ) | .id')
    if [[ -n $domain_id ]]; then
      curl \
        -s -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_TOKEN" \
        -X POST -d "{\"type\":\"A\",\"name\":\"$FQDN\",\"target\":\"$ip_address\"}" \
        https://api.linode.com/v4/domains/${domain_id}/records
    fi
  fi

  version=$(smp-server --version | cut -d ' ' -f 3-)

  curl \
    -s -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" \
    -X PUT -d "{\"tags\":[\"$server_address\",\"#$fingerprint\",\"$version\"]}" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID
fi

# / Create systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "$binary start"

[Install]
WantedBy=multi-user.target

EOT
# Create systemd service /

# Start systemd service
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server
