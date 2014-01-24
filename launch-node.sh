#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))
KEY_NAME="matekey"
KEY_PATH="$(pwd)/../xenapi-in-the-cloud/$KEY_NAME.pem"
IMAGE="node"
INSTANCE_NAME="$1"

. $THISDIR/functions

get_dependencies

nova delete "$INSTANCE_NAME" || true

cd xenapi-in-the-cloud

nova boot \
    --poll \
    --image "$IMAGE" \
    --flavor "performance1-8" \
    --key-name $KEY_NAME $INSTANCE_NAME

IP=$(./get-ip-address-of-instance.sh $INSTANCE_NAME)

./wait-until-done.sh jenkins@$IP $KEY_PATH

eval $(ssh-agent)

ssh-add $KEY_PATH

set +x

SSH_DOM0="sudo -u domzero ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.33.2"
FEED_WITH_NOTHING="< /dev/null"

{
    cat << EOF
set -eux
# Get some parameters
APP=\$($SSH_DOM0 xe vm-list name-label=Appliance --minimal $FEED_WITH_NOTHING)

# Create a vm network
VMNET=\$($SSH_DOM0 xe network-create name-label=vmnet $FEED_WITH_NOTHING)
VMVIF=\$($SSH_DOM0 xe vif-create vm-uuid=\$APP network-uuid=\$VMNET device=3 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vif-plug uuid=\$VMVIF $FEED_WITH_NOTHING

# Create pub network
PUBNET=\$($SSH_DOM0 xe network-create name-label=pubnet $FEED_WITH_NOTHING)
PUBVIF=\$($SSH_DOM0 xe vif-create vm-uuid=\$APP network-uuid=\$PUBNET device=4 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vif-plug uuid=\$PUBVIF $FEED_WITH_NOTHING

# Hack iSCSI SR
$SSH_DOM0 << SRHACK
set -eux
sed -ie "s/'phy'/'aio'/g" /opt/xensource/sm/ISCSISR.py
SRHACK

# This is important, otherwise dhcp server will fail
for dev in eth0 eth1 eth2 eth3 eth4; do
    sudo ethtool -K \$dev tx off
done

# Add a separate disk
SR=\$($SSH_DOM0 xe sr-list type=ext  --minimal $FEED_WITH_NOTHING)
VDI=\$($SSH_DOM0 xe vdi-create name-label=disk-for-volumes virtual-size=10GiB sr-uuid=\$SR type=user $FEED_WITH_NOTHING)
VBD=\$($SSH_DOM0 xe vbd-create vm-uuid=\$APP vdi-uuid=\$VDI device=1 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vbd-plug uuid=\$VBD $FEED_WITH_NOTHING

# For development:
export SKIP_DEVSTACK_GATE_PROJECT=1

sudo pip install -i https://pypi.python.org/simple/ XenAPI

# These came from the Readme
export REPO_URL=https://review.openstack.org/p
export ZUUL_URL=/home/jenkins/workspace-cache
export ZUUL_REF=HEAD
export WORKSPACE=/home/jenkins/workspace/testing

# Check out a custom branch
(
    cd workspace-cache/devstack-gate/
    git remote add mate https://github.com/matelakat/devstack-gate
    git fetch mate
    git checkout xenserver-integration
)
mkdir -p \$WORKSPACE

export ZUUL_PROJECT=openstack/nova
export ZUUL_BRANCH=master

git clone \$REPO_URL/\$ZUUL_PROJECT \$ZUUL_URL/\$ZUUL_PROJECT
cd \$ZUUL_URL/\$ZUUL_PROJECT
git checkout remotes/origin/\$ZUUL_BRANCH

tar -czf - -C /home/jenkins/workspace-cache/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/ ./ |
    $SSH_DOM0 \
    'tar -xzf - -C /etc/xapi.d/plugins/ && chmod a+x /etc/xapi.d/plugins/*'

# Insert a rule as the first position - allow all traffic on the mgmt interface
# Other rules are inserted by config/modules/iptables/templates/rules.erb
sudo iptables -I INPUT 1 -i eth2 -s 192.168.33.0/24 -j ACCEPT

(
    cd /home/jenkins/workspace-cache/devstack
    {
        echo "set -eux"
        cat tools/xen/functions
        echo "create_directory_for_images"
        echo "create_directory_for_kernels"
    } | $SSH_DOM0
)

cd \$WORKSPACE
git clone https://github.com/matelakat/devstack-gate -b xenserver-integration

#( sudo mkdir -p /opt/stack/new && sudo chown -R jenkins:jenkins /opt/stack/new && cd /opt/stack/new && git clone https://github.com/matelakat/devstack-gate -b xenserver-integration )

# Values from the job template
export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_TEMPEST=1
#export DEVSTACK_GATE_TEMPEST_FULL=1
export DEVSTACK_GATE_TEMPEST_FULL=0
export DEVSTACK_GATE_VIRT_DRIVER=xenapi

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
./safe-devstack-vm-gate-wrap.sh
EOF
} | remote-bash jenkins@$IP

RESULT="$?"
set -x

ssh-agent -k
exit $RESULT
