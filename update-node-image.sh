#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))

XENSERVER_PASSWORD="password"
APPLIANCE_URL="http://downloads.vmd.citrix.com/OpenStack/xenapi-in-the-cloud-appliances/1.0.0.xva"
KEY_NAME="$1"
KEY_PATH="$2"
INSTANCE_NAME="$3"
NODE_IMAGE="node"

# Use this configuration to start with a cloud image
IMAGE="62df001e-87ee-407c-b042-6f4e13f5d7e1"

. $THISDIR/functions

get_dependencies

STAMP_FILE=$(xitc-print-stamp-path)

nova delete "$INSTANCE_NAME" || true
nova image-delete "$NODE_IMAGE" || true

nova boot \
    --poll \
    --image "$IMAGE" \
    --flavor "performance1-8" \
    --key-name $KEY_NAME $INSTANCE_NAME

IP=$(xitc-get-ip-address-of-instance $INSTANCE_NAME)

eval $(ssh-agent)

ssh-add $KEY_PATH

while ! echo "true" | remote-bash root@$IP; do
    sleep 1
done

{
    cat << EOF
set -eux
mkdir -p /opt/xenapi-in-the-cloud
tar -xzf - -C /opt/xenapi-in-the-cloud
EOF
    tar -czf - -C xenapi-in-the-cloud/scripts ./
} | remote-bash root@$IP

remote-bash root@$IP << EOF
bash /opt/xenapi-in-the-cloud/xenapi-in-rs.sh $XENSERVER_PASSWORD $APPLIANCE_URL Devstack
EOF

TSTAMP=$(date +%s)
xitc-wait-until-done $IP $KEY_PATH
echo "TIMETOINSTALLXENSERVER $(expr $(date +%s) - $TSTAMP)" >> timedata.log

# Use this key for jenkins
SSH_PUBLIC_KEY=$(ssh-keygen -y -f $KEY_PATH)

remote-bash-agentfw root@$IP << EOF
set -eux
apt-get update

apt-get -qy install git python-pip curl

git clone https://review.openstack.org/p/openstack-infra/config

# Copy nodepool scripts
mkdir -p scripts
cp config/modules/openstack_project/files/nodepool/scripts/* scripts/
mv scripts /opt/nodepool-scripts
chmod -R a+rx /opt/nodepool-scripts
cd /opt/nodepool-scripts

cd /root
config/install_puppet.sh
config/install_modules.sh
puppet apply --modulepath=/root/config/modules:/etc/puppet/modules -e "class { openstack_project::slave_template: install_users => false,ssh_key => \\"${SSH_PUBLIC_KEY}\\" }"
echo HostKey /etc/ssh/ssh_host_ecdsa_key >> /etc/ssh/sshd_config
sudo -u jenkins -i /opt/nodepool-scripts/prepare_devstack.sh
rm -f $STAMP_FILE
sync
sleep 5
EOF

nova image-create --poll $INSTANCE_NAME $NODE_IMAGE
nova delete $INSTANCE_NAME
ssh-agent -k
