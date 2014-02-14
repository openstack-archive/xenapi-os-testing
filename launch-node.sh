#!/bin/bash

set -eux

THISDIR=$(dirname $(readlink -f $0))
KEY_NAME="$1"
KEY_PATH="$2"
INSTANCE_NAME="$3"
FLAVOR="$4"
IMAGE="${5:-node}"
APPLIANCE_NAME="devstack"
RUN_TESTS_SCRIPT="$THISDIR/run_tests.sh"

. $THISDIR/functions

get_dependencies

nova delete "$INSTANCE_NAME" || true

nova boot \
    --poll \
    --image "$IMAGE" \
    --flavor "$FLAVOR" \
    --key-name $KEY_NAME $INSTANCE_NAME

IP=$(xitc-get-ip-address-of-instance $INSTANCE_NAME)

TSTAMP=$(date +%s)
xitc-wait-until-done jenkins@$IP $KEY_PATH
echo "TIMETOBOOTFROMSNAPSHOT $(expr $(date +%s) - $TSTAMP)" >> timedata.log

eval $(ssh-agent)

ssh-add $KEY_PATH

set +x

cat $RUN_TESTS_SCRIPT | remote-bash jenkins@$IP

RESULT="$?"
set -x

ssh-agent -k
exit $RESULT
