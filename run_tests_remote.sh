#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))
KEY_PATH="$1"
INSTANCE_NAME="$2"
TEST_PROJECT="${3:-nova}"
TEST_REF="${3:-refs/changes/97/66597/4}"
APPLIANCE_NAME="devstack"
RUN_TESTS_SCRIPT="run_tests.sh"

. $THISDIR/functions

get_dependencies

IP=$(xitc-get-ip-address-of-instance $INSTANCE_NAME)

eval $(ssh-agent)

ssh-add $KEY_PATH

ssh -i $KEY_PATH jenkins@$IP '[ -e xenapi-os-testing ] || git clone https://github.com/citrix-openstack/xenapi-os-testing -b bob'
new_env="INSTANCE_NAME=$INSTANCE_NAME ZUUL_URL=https://review.openstack.org ZUUL_PROJECT=$TEST_PROJECT ZUUL_REF=$TEST_REF"
new_env="$new_env APPLIANCE_NAME=$APPLIANCE_NAME"
ssh -i $KEY_PATH jenkins@$IP "echo '#!/bin/bash' > run_tests_env.sh"
ssh -i $KEY_PATH jenkins@$IP "echo $new_env ~/xenapi-os-testing/run_tests.sh >> run_tests_env.sh"
ssh -i $KEY_PATH jenkins@$IP "chmod +x run_tests_env.sh"

ssh -i $KEY_PATH jenkins@$IP "nohup ./run_tests_env.sh &"

ssh-agent -k

echo "Tests are now running remotely."
