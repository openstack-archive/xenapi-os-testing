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

ssh-add $KEY_PATH


set +e
remote-bash root@$IP << EOF
set -eux
apt-get update

apt-get -qy install git python-pip curl

SSH_KEYS="\$(cat .ssh/authorized_keys)"

git clone https://review.openstack.org/p/openstack-infra/config

config/install_puppet.sh
config/install_modules.sh
puppet apply --modulepath=/root/config/modules:/etc/puppet/modules -e "class { openstack_project::slave_template: install_users => false,ssh_key => \\"\${SSH_KEYS}\\" }"
echo HostKey /etc/ssh/ssh_host_ecdsa_key >> /etc/ssh/sshd_config
reboot
EOF

RESULT="$?"

if ! [ "$RESULT" = "0" ]; then
    ssh-agent -k
    exit $RESULT
fi

# Wait until the box comes back
while true; do
    remote-bash jenkins@$IP << EOF
set -eux
true
EOF
    if [ "$?" = "0" ]; then
        break
    fi
    sleep 1
done

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

ssh-agent -k

cat << EOF
Result is: $RESULT
EOF

exit $RESULT
