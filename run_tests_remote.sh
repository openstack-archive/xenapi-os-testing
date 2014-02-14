#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))
KEY_PATH="$1"
INSTANCE_NAME="$2"
TEST_PROJECT="${3:-nova}"
TEST_REF="${3:-refs/changes/97/66597/4}"
APPLIANCE_NAME="devstack"
RUN_TESTS_SCRIPT="$THISDIR/run_tests.sh"

. $THISDIR/functions

get_dependencies

IP=$(xitc-get-ip-address-of-instance $INSTANCE_NAME)

eval $(ssh-agent)

ssh-add $KEY_PATH

set +x

new_env="INSTANCE_NAME=$INSTANCE_NAME; ZUUL_URL=https://review.openstack.org; ZUUL_PROJECT=$TEST_PROJECT; ZUUL_REF=$TEST_REF"
new_env="$new_env; APPLIANCE_NAME=$APPLIANCE_NAME"
cat $RUN_TESTS_SCRIPT | sed -e "s@#REPLACE_ENV@$new_env@" | remote-bash jenkins@$IP

RESULT="$?"
set -x

ssh-agent -k
exit $RESULT
