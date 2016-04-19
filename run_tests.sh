#!/bin/bash

echo $$ >> ~/run_tests.pid

DEVSTACK_GATE_REPO="https://github.com/citrix-openstack/devstack-gate"
DEVSTACK_GATE_BRANCH="master"

export WORKSPACE=${WORKSPACE:-/home/jenkins/workspace/testing}

# Trap the exit code + log a final message
function trapexit {
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
	echo "Passed" | tee ~/result.txt
    else
	echo "Failed" | tee ~/result.txt
    fi

    LOGS_DIR=$WORKSPACE/logs
    [ -e ${LOGS_DIR} ] || mkdir -p ${LOGS_DIR}
    mv ~/run_tests.log ${LOGS_DIR}
    # Do not use 'exit' - bash will preserve the status
}

trap trapexit EXIT

set -ex

#REPLACE_ENV

export ZUUL_PROJECT=${ZUUL_PROJECT:-openstack/nova}
export ZUUL_BRANCH=${ZUUL_BRANCH:-master}
export ZUUL_REF=${ZUUL_REF:-HEAD}
# Values from the job template
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-1}
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}


export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_VIRT_DRIVER=xenapi
# Set gate timeout to 2 hours
export DEVSTACK_GATE_TIMEOUT=240
export DEVSTACK_GATE_XENAPI_DOM0_IP=192.168.33.2
export DEVSTACK_GATE_XENAPI_DOMU_IP=192.168.33.1
export DEVSTACK_GATE_XENAPI_PASSWORD=password
export DEVSTACK_GATE_CLEAN_LOGS=0

set -u

# Need to let jenkins sudo as domzero
# TODO: Merge this somewhere better?
TEMPFILE=`mktemp`
echo "jenkins ALL=(ALL) NOPASSWD:ALL" >$TEMPFILE
chmod 0440 $TEMPFILE
sudo chown root:root $TEMPFILE
sudo mv $TEMPFILE /etc/sudoers.d/40_jenkins

function run_in_domzero() {
    sudo -u domzero ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.33.2 "$@"
}

# Get some parameters
APP=$(run_in_domzero xe vm-list name-label=$APPLIANCE_NAME --minimal </dev/null)

# Create a vm network
VMNET=$(run_in_domzero xe network-create name-label=vmnet </dev/null)
VMVIF=$(run_in_domzero xe vif-create vm-uuid=$APP network-uuid=$VMNET device=3 </dev/null)
run_in_domzero xe vif-plug uuid=$VMVIF </dev/null

# Create pub network
PUBNET=$(run_in_domzero xe network-create name-label=pubnet </dev/null)
PUBVIF=$(run_in_domzero xe vif-create vm-uuid=$APP network-uuid=$PUBNET device=4 </dev/null)
run_in_domzero xe vif-plug uuid=$PUBVIF </dev/null

# Hack iSCSI SR
run_in_domzero << SRHACK
set -eux
sed -ie "s/'phy'/'aio'/g" /opt/xensource/sm/ISCSISR.py
SRHACK

# This is important, otherwise dhcp client will fail
for dev in eth0 eth1 eth2 eth3 eth4; do
    sudo ethtool -K $dev tx off
done

# Add a separate disk
# Not used as VOLUME_BACKING_DEVICE is ignored by devstack
#SR=$(run_in_domzero xe sr-list type=ext  --minimal </dev/null)
#VDI=$(run_in_domzero xe vdi-create name-label=disk-for-volumes virtual-size=20GiB sr-uuid=$SR type=user </dev/null)
#VBD=$(run_in_domzero xe vbd-create vm-uuid=$APP vdi-uuid=$VDI device=1 </dev/null)
#run_in_domzero xe vbd-plug uuid=$VBD </dev/null

# For development:
export SKIP_DEVSTACK_GATE_PROJECT=1

sudo pip install -i https://pypi.python.org/simple/ XenAPI
sudo pip install pyyaml

LOCATION_OF_LOCAL_GIT_REPOSITORIES=/opt/git

# These came from the Readme
export ZUUL_URL=https://review.openstack.org/p
export REPO_URL=$LOCATION_OF_LOCAL_GIT_REPOSITORIES

# Check out a custom branch
(
    cd $LOCATION_OF_LOCAL_GIT_REPOSITORIES/openstack-infra/devstack-gate/
    sudo git remote add DEVSTACK_GATE_REPO "$DEVSTACK_GATE_REPO"
    sudo git fetch DEVSTACK_GATE_REPO
    sudo git checkout "DEVSTACK_GATE_REPO/$DEVSTACK_GATE_BRANCH" -B DEVSTACK_GATE_BRANCH
)
mkdir -p $WORKSPACE

# Need to let stack sudo as domzero too
# TODO: Merge this somewhere better?
TEMPFILE=`mktemp`
echo "stack ALL=(ALL) NOPASSWD:ALL" >$TEMPFILE
chmod 0440 $TEMPFILE
sudo chown root:root $TEMPFILE
sudo mv $TEMPFILE /etc/sudoers.d/40_stack_sh

function pre_test_hook() {
# Plugins
tar -czf - -C /opt/stack/new/nova/plugins/xenserver/xenapi/etc/xapi.d/plugins/ ./ |
    run_in_domzero \
    'tar -xzf - -C /etc/xapi.d/plugins/ && chmod a+x /etc/xapi.d/plugins/*'

# Console log
tar -czf - -C /opt/stack/new/nova/tools/xenserver/ rotate_xen_guest_logs.sh |
    run_in_domzero \
    'tar -xzf - -C /root/ && chmod +x /root/rotate_xen_guest_logs.sh && mkdir -p /var/log/xen/guest'
run_in_domzero crontab - << CRONTAB
* * * * * /root/rotate_xen_guest_logs.sh
CRONTAB

(
    cd /opt/stack/new/devstack
    {
        echo "set -eux"
        cat tools/xen/functions
        echo "create_directory_for_images"
        echo "create_directory_for_kernels"
    } | run_in_domzero
)

## Cherry-pick some changes to tempest

(
    cd /opt/stack/new/tempest
    sudo git fetch https://review.openstack.org/openstack/tempest refs/changes/88/187688/1
    sudo git cherry-pick FETCH_HEAD

    sudo cp /home/jenkins/xenapi-os-testing/tempest_exclusion_list /opt/stack/new/tempest/.excluded_tests
)

}

# export this function to be used by devstack-gate
export -f pre_test_hook

# Insert a rule as the first position - allow all traffic on the mgmt interface
# Other rules are inserted by config/modules/iptables/templates/rules.erb
sudo iptables -I INPUT 1 -i eth2 -s 192.168.33.0/24 -j ACCEPT

cd $WORKSPACE
git clone $DEVSTACK_GATE_REPO -b $DEVSTACK_GATE_BRANCH

# devstack-gate referneces $BASE/new for where it expects devstack-gate... Create copy there too
# When we can disable SKIP_DEVSTACK_GATE_PROJECT (i.e. everything upstreamed) then this can be removed.
( sudo mkdir -p /opt/stack/new && sudo chown -R jenkins:jenkins /opt/stack/new && cd /opt/stack/new && git clone "$DEVSTACK_GATE_REPO" -b "$DEVSTACK_GATE_BRANCH" )

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh

# OpenStack doesn't care much about unset variables...
set +ue
source ./safe-devstack-vm-gate-wrap.sh
