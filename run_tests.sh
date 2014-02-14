#!/bin/bash

set -ex

#REPLACE_ENV

export ZUUL_PROJECT=${ZUUL_PROJECT:-openstack/nova}
export ZUUL_BRANCH=${ZUUL_BRANCH:-master}
export ZUUL_REF=${ZUUL_REF:-HEAD}
# Values from the job template
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-1}
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_FULL:-0}


export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_VIRT_DRIVER=xenapi
# Set gate timeout to 2 hours
export DEVSTACK_GATE_TIMEOUT=240

set -u

SSH_DOM0="sudo -u domzero ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.33.2"
FEED_WITH_NOTHING="< /dev/null"

# Get some parameters
APP=$($SSH_DOM0 xe vm-list name-label=$APPLIANCE_NAME --minimal $FEED_WITH_NOTHING)

# Create a vm network
VMNET=$($SSH_DOM0 xe network-create name-label=vmnet $FEED_WITH_NOTHING)
VMVIF=$($SSH_DOM0 xe vif-create vm-uuid=$APP network-uuid=$VMNET device=3 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vif-plug uuid=$VMVIF $FEED_WITH_NOTHING

# Create pub network
PUBNET=$($SSH_DOM0 xe network-create name-label=pubnet $FEED_WITH_NOTHING)
PUBVIF=$($SSH_DOM0 xe vif-create vm-uuid=$APP network-uuid=$PUBNET device=4 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vif-plug uuid=$PUBVIF $FEED_WITH_NOTHING

# Hack iSCSI SR
$SSH_DOM0 << SRHACK
set -eux
sed -ie "s/'phy'/'aio'/g" /opt/xensource/sm/ISCSISR.py
SRHACK

# This is important, otherwise dhcp client will fail
for dev in eth0 eth1 eth2 eth3 eth4; do
    sudo ethtool -K $dev tx off
done

# Add a separate disk
SR=$($SSH_DOM0 xe sr-list type=ext  --minimal $FEED_WITH_NOTHING)
VDI=$($SSH_DOM0 xe vdi-create name-label=disk-for-volumes virtual-size=10GiB sr-uuid=$SR type=user $FEED_WITH_NOTHING)
VBD=$($SSH_DOM0 xe vbd-create vm-uuid=$APP vdi-uuid=$VDI device=1 $FEED_WITH_NOTHING)
$SSH_DOM0 xe vbd-plug uuid=$VBD $FEED_WITH_NOTHING

# For development:
export SKIP_DEVSTACK_GATE_PROJECT=1

sudo pip install -i https://pypi.python.org/simple/ XenAPI

# These came from the Readme
export REPO_URL=https://review.openstack.org/p
export ZUUL_URL=/home/jenkins/workspace-cache
export WORKSPACE=/home/jenkins/workspace/testing

# Check out a custom branch
(
    cd workspace-cache/devstack-gate/
    git remote add mate https://github.com/matelakat/devstack-gate
    git fetch mate
    git checkout xenserver-integration
)
mkdir -p $WORKSPACE

function pre_test_hook() {
# Plugins
tar -czf - -C /home/jenkins/workspace-cache/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/ ./ |
    $SSH_DOM0 \
    'tar -xzf - -C /etc/xapi.d/plugins/ && chmod a+x /etc/xapi.d/plugins/*'

# Console log
tar -czf - -C /home/jenkins/workspace-cache/nova/tools/xenserver/ rotate_xen_guest_logs.sh |
    $SSH_DOM0 \
    'tar -xzf - -C /root/ && chmod +x /root/rotate_xen_guest_logs.sh && mkdir -p /var/log/xen/guest'
$SSH_DOM0 crontab - << CRONTAB
* * * * * /root/rotate_xen_guest_logs.sh
CRONTAB

(
    cd /home/jenkins/workspace-cache/devstack
    {
        echo "set -eux"
        cat tools/xen/functions
        echo "create_directory_for_images"
        echo "create_directory_for_kernels"
    } | $SSH_DOM0
)
}

# Insert a rule as the first position - allow all traffic on the mgmt interface
# Other rules are inserted by config/modules/iptables/templates/rules.erb
sudo iptables -I INPUT 1 -i eth2 -s 192.168.33.0/24 -j ACCEPT

cd $WORKSPACE
git clone https://github.com/matelakat/devstack-gate -b xenserver-integration

#( sudo mkdir -p /opt/stack/new && sudo chown -R jenkins:jenkins /opt/stack/new && cd /opt/stack/new && git clone https://github.com/matelakat/devstack-gate -b xenserver-integration )

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
./safe-devstack-vm-gate-wrap.sh