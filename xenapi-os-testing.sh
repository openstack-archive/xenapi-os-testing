#!/bin/bash

set -eux

XENSERVER_PASSWORD="password"
APPLIANCE_URL="http://downloads.vmd.citrix.com/OpenStack/xenapi-in-the-cloud-appliances/master.xva"
KEY_NAME="matekey"
KEY_PATH="$(pwd)/../xenapi-in-the-cloud/$KEY_NAME.pem"

# Download dependencies

for dep in xenapi-in-the-cloud remote-bash; do
    if [ -e $dep ]; then
        ( cd $dep; git pull; )
    else
        git clone https://github.com/citrix-openstack/$dep
    fi

    if [ -e "$dep/bin" ]; then
        export PATH=$PATH:$(pwd)/$dep/bin
    fi

done

cd xenapi-in-the-cloud

nova boot \
    --poll \
    --image "62df001e-87ee-407c-b042-6f4e13f5d7e1" \
    --flavor "performance1-8" \
    --key-name $KEY_NAME instance

IP=$(./get-ip-address-of-instance.sh instance)

SSH_PARAMS="-i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh \
    $SSH_PARAMS \
    root@$IP mkdir -p /opt/xenapi-in-the-cloud

scp \
    $SSH_PARAMS \
    xenapi-in-rs.sh root@$IP:/opt/xenapi-in-the-cloud/

ssh \
    $SSH_PARAMS \
    root@$IP bash /opt/xenapi-in-the-cloud/xenapi-in-rs.sh $XENSERVER_PASSWORD $APPLIANCE_URL

./wait-until-done.sh $IP $KEY_PATH

cat << EOF
Instance is accessible with:

ssh $SSH_PARAMS root@$IP
EOF

eval $(ssh-agent)

remote-bash << EOF
set -eux
apt-get update

apt-get -qy install git python-pip

mkdir src
cd src
git clone https://review.openstack.org/p/openstack-infra/config

# Emulate nodepool behavior
mkdir -p /opt/nodepool-scripts
cp modules/openstack_project/files/nodepool/scripts/* /opt/nodepool-scripts/
chmod -R a+rx /opt/nodepool-scripts

cd /opt/nodepool-scripts && ./prepare_node_devstack.sh trialnode
EOF
