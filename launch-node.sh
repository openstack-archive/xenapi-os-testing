#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))
KEY_NAME="matekey"
KEY_PATH="$(pwd)/../xenapi-in-the-cloud/$KEY_NAME.pem"
IMAGE="node"
INSTANCE_NAME="$2"

. $THISDIR/functions

get_dependencies

cd xenapi-in-the-cloud

nova boot \
    --poll \
    --image "$IMAGE" \
    --flavor "performance1-8" \
    --key-name $KEY_NAME $INSTANCE_NAME

IP=$(./get-ip-address-of-instance.sh $INSTANCE_NAME)

./wait-until-done.sh jenkins@$IP $KEY_PATH

set +x

remote-bash jenkins@$IP << EOF
set -eux

# These came from the Readme
export REPO_URL=https://review.openstack.org/p
export ZUUL_URL=/home/jenkins/workspace-cache
export ZUUL_REF=HEAD
export WORKSPACE=/home/jenkins/workspace/testing
mkdir -p \$WORKSPACE

export ZUUL_PROJECT=openstack/nova
export ZUUL_BRANCH=master

git clone \$REPO_URL/\$ZUUL_PROJECT \$ZUUL_URL/\$ZUUL_PROJECT
cd \$ZUUL_URL/\$ZUUL_PROJECT
git checkout remotes/origin/\$ZUUL_BRANCH

cd \$WORKSPACE
git clone https://github.com/matelakat/devstack-gate -b xenserver-integration

# Values from the job template
export PYTHONUNBUFFERED=true
export DEVSTACK_GATE_TEMPEST=1
export DEVSTACK_GATE_TEMPEST_FULL=1
export DEVSTACK_GATE_VIRT_DRIVER=xenapi

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
./safe-devstack-vm-gate-wrap.sh
EOF

RESULT="$?"
set -x

ssh-agent -k
exit $RESULT
