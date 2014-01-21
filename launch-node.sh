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

{
    echo "set -eux"
    cat << EOF
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
