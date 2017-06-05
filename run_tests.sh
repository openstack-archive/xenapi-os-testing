#!/bin/bash

echo $$ >> ~/run_tests.pid

# print build id passed from Jenkins for easy tracking.
echo "BUILD_ID = $BUILD_ID"

DEVSTACK_GATE_REPO="https://github.com/openstack-infra/devstack-gate"
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

function ensure_swap {
    # Add more swap by using loop device as upstream devstack-gate will ensure
    # there are at leat 8GB swap. But actually we should have enough memory
    # for CI jobs at the moment.
    SWAPSIZE=8192
    swapcurrent=$(( $(grep SwapTotal /proc/meminfo | awk '{ print $2; }') / 1024 ))
    if [[ $swapcurrent -lt $SWAPSIZE ]]; then
        swapdiff=$(( $SWAPSIZE - $swapcurrent ))
        SWAP_FILE=/root/.swapfile
        sudo truncate -s ${swapdiff}M ${SWAP_FILE}
        SWAP_DEV=$(sudo losetup -f --show ${SWAP_FILE})
        sudo mkswap ${SWAP_DEV}
        sudo swapon ${SWAP_DEV}
    fi
}

trap trapexit EXIT

set -ex

ensure_swap

#REPLACE_ENV

export PROJECTS="openstack/os-xenapi $PROJECTS"
export DEVSTACK_LOCAL_CONFIG=${DEVSTACK_LOCAL_CONFIG:-"enable_plugin os-xenapi git://git.openstack.org/openstack/os-xenapi"}

export ZUUL_PROJECT=${ZUUL_PROJECT:-openstack/nova}
export ZUUL_BRANCH=${ZUUL_BRANCH:-master}
export ZUUL_REF=${ZUUL_REF:-HEAD}
# Values from the job template
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-1}
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}
export DEVSTACK_GATE_NEUTRON=${DEVSTACK_GATE_NEUTRON:-0}

export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_VIRT_DRIVER=xenapi
# Set this to the time in milliseconds that the entire job should be
# allowed to run before being aborted (default 120 minutes=7200000ms).
# This may be supplied by Jenkins based on the configured job timeout
# which is why it's in this convenient unit.
export BUILD_TIMEOUT=${BUILD_TIMEOUT:-10800000}
export DEVSTACK_GATE_XENAPI_DOM0_IP=192.168.33.2
export DEVSTACK_GATE_XENAPI_DOMU_IP=192.168.33.1
export DEVSTACK_GATE_XENAPI_PASSWORD=password
export DEVSTACK_GATE_CLEAN_LOGS=0

# Journald default is to not persist logs to disk if /var/log/journal is
# not present. Update the configuration to set storage to persistent which
# will create /var/log/journal if necessary and store logs on disk. This
# avoids the situation where test runs can fill the journald ring buffer
# deleting older logs that may be important to the job.
if [ -f /etc/systemd/journald.conf ] ; then
    sudo sed -i -e 's/#Storage=auto/Storage=persistent/' /etc/systemd/journald.conf
    sudo systemctl restart systemd-journald
fi

# set regular expression
# Not display the long list for the exclusion regex when populate the variables.
set +x
source /home/jenkins/xenapi-os-testing/tempest_exclusion_list
set -x
if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
    export DEVSTACK_GATE_TEMPEST_REGEX="$NEUTRON_NETWORK_TEMPEST_REGEX"
    export ENABLED_SERVICES=neutron,q-domua
else
    export DEVSTACK_GATE_TEMPEST_REGEX="$NOVA_NETWORK_TEMPEST_REGEX"
fi

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
export VMBRIDGE=$(run_in_domzero xe network-param-get param-name=bridge uuid=$VMNET </dev/null)

# Create pub network
PUBNET=$(run_in_domzero xe network-create name-label=pubnet </dev/null)
PUBVIF=$(run_in_domzero xe vif-create vm-uuid=$APP network-uuid=$PUBNET device=4 </dev/null)
run_in_domzero xe vif-plug uuid=$PUBVIF </dev/null

# Set to keep localconf_file as we will config localconf_file during pre_test_hook
export KEEP_LOCALRC=1

if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
    # Create integration network for compute node
    INTNET=$(run_in_domzero xe network-create name-label=intnet </dev/null)
    export INTBRIDGE=$(run_in_domzero xe network-param-get param-name=bridge uuid=$INTNET </dev/null)

    # Remove restriction of linux bridge usage in Dom0, linux bridge is used for security group
    run_in_domzero rm -f /etc/modprobe.d/blacklist-bridge*
fi

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

sudo -H pip install pyyaml

LOCATION_OF_LOCAL_GIT_REPOSITORIES=/opt/git

# These came from the Readme
# use the ZUUL_URL passed from Jenkins
export ZUUL_URL=${ZUUL_URL:-https://review.openstack.org/p}
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

(
# fetch depends-on patches.
if [ "${ZUUL_URL}" = "https://review.openstack.org/p" -a -n "$ZUUL_CHANGES" ]; then
    # Neutron test nodes still depend on review.openstack.org to fetch changes.
    # Need fetch depends-on patches specially.
    changes=$(echo $ZUUL_CHANGES | tr '^' ' ')
    echo "Processing depends-on changes: $changes"
    for change in $changes; do
        project=$(echo $change | cut -d: -f1);
        # Skip the changes belong to $ZUUL_PROJECT which
        # has been done already in the primary routine.
        # And also only handle projects which belong to $PROJECTS, otherwise
        # the repo won't exist under $BASE/new/: e.g. xenapi-os-testing.
        if [ "$project" = "$ZUUL_PROJECT" -o -z "$(echo $PROJECTS | grep $project)" ]; then
            echo -e "\tSkip the change: $change"
        else
            echo -e "\tFetching change: $change."
            ref=$(echo $change | cut -d: -f3);
            pushd $BASE/new/$(basename $project)
            if git fetch $ZUUL_URL/$project $ref; then
                git merge FETCH_HEAD
            fi
            popd
        fi
    done
fi
)

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

(
    if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
        # Set IP address for eth3(vmnet) and eth4(pubnet) for Neutron
        sudo ip addr add 10.1.0.254/24 broadcast 10.1.0.255 dev eth3
        sudo ip link set eth3 up
        sudo ip addr add 172.24.5.1/24 broadcast 172.24.5.255 dev eth4
        sudo ip link set eth4 up
    fi
)

(
    # configure localconf_file
    localconf_file="/opt/stack/new/devstack/local.conf"

    # the section of [[local|localrc]]

    if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
        # Set localconf_file for neutron network
        cat <<EOF >>"$localconf_file"
[[local|localrc]]
Q_PLUGIN=ml2
Q_USE_SECGROUP=True
ENABLE_TENANT_VLANS="True"
ENABLE_TENANT_TUNNELS="False"
Q_ML2_TENANT_NETWORK_TYPE="vlan"
ML2_VLAN_RANGES="physnet1:1000:1024"
MULTI_HOST=0
XEN_INTEGRATION_BRIDGE=$INTBRIDGE
FLAT_NETWORK_BRIDGE=$VMBRIDGE
Q_AGENT=openvswitch
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch
Q_ML2_PLUGIN_TYPE_DRIVERS="vlan,flat"
OVS_PHYSICAL_BRIDGE=br-ex
PUBLIC_BRIDGE=br-ex
TEMPEST_RUN_VALIDATION="True"
# Set instance build timeout to 300s in tempest.conf
BUILD_TIMEOUT=390
EOF
    fi

    # the section for [[post-config|<conf file>]]; let's put the items sorted with the conf file path.

    # Use thin provision for lvm, so that we can save disk space and avoid large disk IO requests
    # during volume tests.
    cat <<EOF >>"$localconf_file"
[[post-config|/etc/cinder/cinder.conf]]
[lvmdriver-1]
lvm_type = thin
EOF

    # enable image cache to avoid downloading images frequently
    cat <<EOF >>"$localconf_file"
[[post-config|/etc/nova/nova.conf]]
[xenserver]
cache_images = all
EOF

    # Set localconf_file for neutron ovs-agent in compute node
    if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
        cat <<EOF >>"$localconf_file"

[[post-config|/etc/neutron/plugins/ml2/ml2_conf.ini.domU]]
[ovs]
of_listen_address = $DEVSTACK_GATE_XENAPI_DOMU_IP
ovsdb_connection = tcp:$DEVSTACK_GATE_XENAPI_DOM0_IP:6640
bridge_mappings = physnet1:$VMBRIDGE

[[post-config|/etc/neutron/plugins/ml2/ml2_conf.ini]]
[ovs]
of_listen_address = 127.0.0.1
ovsdb_connection = tcp:127.0.0.1:6640
bridge_mappings = physnet1:br-eth3,public:br-ex
EOF

    fi

    # reduce the object audit rate to save IO.
    cat <<EOF >>"$localconf"
[[post-config|/etc/swift/object-server/1.conf]]
[object-auditor]
files_per_second = 1
bytes_per_second = 65536
interval = 3000
EOF

)

# If os-xenapi is in the patch list(include watched change on os-xenapi and
# the change depended by other changes), pip install it from local repo. So
# the os-xenapi changes will be verified via CI tests.
(
OS_XENAPI_DIR=/opt/stack/new/os-xenapi
if [  -d $OS_XENAPI_DIR -a -n "$(echo $ZUUL_CHANGES | grep openstack/os-xenapi)" ]; then
    sudo -H pip install -e $OS_XENAPI_DIR
fi
)

# Prepare memory FS to how stack data.
(
    DATA_DIR=/opt/stack/data
    if [ -e ${DATA_DIR} ]; then
        # At here it shouldn't exist.
        echo "${DATA_DIR} already exist."
        exit 1
    fi
    sudo mkdir -p ${DATA_DIR}
    DATA_RESERVE_SPACE_GB=${DATA_RESERVE_SPACE_GB:-4}
    MIN_VM_RESERVE_MEM_GB=${MIN_VM_RESERVE_MEM_GB:-6}
    # If there is enough free memory, let's use memory file system for DATA_DIR
    TOTAL_MEM_GB=$(free -g | grep -- '^Mem:' | awk '{print $2}')
    if [ ${TOTAL_MEM_GB} -ge $((${DATA_RESERVE_SPACE_GB} + ${MIN_VM_RESERVE_MEM_GB})) ]; then
        sudo mount -t tmpfs -o size=${DATA_RESERVE_SPACE_GB}G tmpfs ${DATA_DIR}
    fi
)

# delete folders to save disk space
sudo rm -rf /opt/git
}

# export this function to be used by devstack-gate
export -f pre_test_hook
# export the functions invoked by pre_test_hook
export -f run_in_domzero

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
