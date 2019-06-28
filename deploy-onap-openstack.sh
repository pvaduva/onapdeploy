#!/bin/bash
#
# Copyright 2018-2019 Tieto
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Script for automated deployment of ONAP on top of OpenStack installation.

# TODO:
#   Configure ONAP to be able to control underlying OpenStack

set -x

export LC_ALL=C
export LANG=$LC_ALL

[ -z "$OS_AUTH_URL" ] && echo "ERROR: OpenStack environment variables are not set!" && exit 1

DATE='date --rfc-3339=seconds'

# Configuration to be passed to ci/deploy-onap.sh
export SSH_USER="ubuntu"
export SSH_IDENTITY="/root/.ssh/onap_key"

# detect hypervisor details to be used as default values if needed
OS_HYPER_CMD="openstack hypervisor list --long"
echo -e "\nOpenStack Hepervisor list\n"
$OS_HYPER_CMD

DEFAULT_CMP_COUNT=$($OS_HYPER_CMD -f value -c "ID" | wc -l)
DEFAULT_CMP_MIN_MEM=$($OS_HYPER_CMD -f value -c "Memory MB" | sort | head -n1)
DEFAULT_CMP_MIN_CPUS=$($OS_HYPER_CMD -f value -c "vCPUs" | sort | head -n1)
DEFAULT_CMP_MIN_STORAGE=300

# Use default values if compute configuration was not set by FUEL installer
SCRIPT_DIR=${SCRIPT_DIR:-"."}
IMAGE_DIR="${SCRIPT_DIR}/images"
CMP_COUNT=${CMP_COUNT:-$DEFAULT_CMP_COUNT}          # number of compute nodes
CMP_MIN_MEM=${CMP_MIN_MEM:-$DEFAULT_CMP_MIN_MEM}    # MB RAM of the weakest compute node
CMP_MIN_CPUS=${CMP_MIN_CPUS:-$DEFAULT_CMP_MIN_CPUS} # CPU count of the weakest compute node
# size of storage for instances
CMP_STORAGE_TOTAL=${CMP_STORAGE_TOTAL:-$(($DEFAULT_CMP_MIN_STORAGE*$CMP_COUNT))}
VM_COUNT=${VM_COUNT:-1}             # number of VMs available for k8s cluster; singlenode by default

#
# Functions
#
# function minimum accepts two numbers and prints smaller one
function minimum(){
    echo $(($1<$2?$1:$2))
}

# function remove_openstack_setup removes OS configuration performed by this
#   script; So previously created configuration and deployed VMs will be
#   removed before new ONAP deployment will be started.
function remove_openstack_setup(){
    # flavor is created 1st but removed last, so...
    if ( ! openstack flavor list | grep 'onap.large' &> /dev/null ) ; then
        #...no flavor means nothing to be removed
        return
    fi
    echo -e "\nRemoving ONAP specific OpenStack configuration"
    for a in $(openstack server list --name onap_vm -f value -c ID) ; do
        openstack server delete $a
    done
    RULES=$(openstack security group rule list onap_security_group -f value -c ID)
    for a in $RULES; do
        openstack security group rule delete $a
    done
    openstack security group delete onap_security_group
    for a in $(openstack floating ip list -f value -c ID) ; do
        openstack floating ip delete $a
    done
    PORTS=$(openstack port list --network onap_private_network -f value -c ID)
    for a in $PORTS ; do
        openstack router remove port onap_router $a
    done
    PORTS=$(openstack port list --network onap_private_network -f value -c ID)
    for a in $PORTS ; do
        openstack port delete $a
    done
    openstack router delete onap_router
    openstack subnet delete onap_private_subnet
    openstack network delete onap_private_network
    openstack image delete xenial
    rm -rf $IMAGE_DIR
    openstack keypair delete onap_key
    rm $SSH_IDENTITY
    openstack flavor delete onap.large
    echo
}

#
# Script Main
#

# remove OpenStack configuration if it exists
remove_openstack_setup

echo -e "\nOpenStack configuration\n"

# Calculate VM resources, so that flavor can be created
echo "Configuration of compute node:"
echo "Number of computes:    CMP_COUNT=$CMP_COUNT"
echo "Minimal RAM:           CMP_MIN_MEM=$CMP_MIN_MEM"
echo "Minimal CPUs count:    CMP_MIN_CPUS=$CMP_MIN_CPUS"
echo "Storage for instances: CMP_STORAGE_TOTAL=$CMP_STORAGE_TOTAL"
echo "Number of VMs:         VM_COUNT=$VM_COUNT"
# Calculate VM parameters; there will be up to 1 VM per Compute node
# to maximize resources available for VMs
PER=85                      # % of compute resources will be consumed by VMs
VM_DISK_MAX=300             # GB - max VM disk size
VM_MEM_MAX=245760           # MB - max VM RAM size
VM_CPUS_MAX=64              # max count of VM CPUs
VM_MEM=$(minimum $(($CMP_MIN_MEM*$CMP_COUNT*$PER/100/$VM_COUNT)) $VM_MEM_MAX)
VM_CPUS=$(minimum $(($CMP_MIN_CPUS*$CMP_COUNT*$PER/100/$VM_COUNT)) $VM_CPUS_MAX)
VM_DISK=$(minimum $(($CMP_STORAGE_TOTAL*$PER/100/$VM_COUNT)) $VM_DISK_MAX)

echo -e "\nFlavor configuration:"
echo "CPUs      : $VM_CPUS"
echo "RAM [MB]  : $VM_MEM"
echo "DISK [GB] : $VM_DISK"

# Create onap flavor
openstack flavor create --ram $VM_MEM  --vcpus $VM_CPUS --disk $VM_DISK \
    onap.large

# Generate a keypair and store private key
openstack keypair create onap_key > $SSH_IDENTITY
chmod 600 $SSH_IDENTITY

# Download and import VM image(s)
mkdir $IMAGE_DIR
wget -P $IMAGE_DIR https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img
openstack image create --disk-format qcow2 --container-format bare --public \
    --file $IMAGE_DIR/xenial-server-cloudimg-amd64-disk1.img xenial

# Modify quotas (add 10% to required VM resources)
openstack quota set --ram $(($VM_MEM*$VM_COUNT*110/100)) admin
openstack quota set --cores $(($VM_CPUS*$VM_COUNT*110/100)) admin

# Configure networking with DNS for access to the internet
openstack network create onap_private_network --provider-network-type vxlan
openstack subnet create onap_private_subnet --network onap_private_network \
    --subnet-range 192.168.33.0/24 --ip-version 4 --dhcp --dns-nameserver "8.8.8.8"
openstack router create onap_router
openstack router add subnet onap_router onap_private_subnet
openstack router set onap_router --external-gateway public

# Allow selected ports and protocols
openstack security group create onap_security_group
openstack security group rule create --protocol icmp onap_security_group
openstack security group rule create  --proto tcp \
    --dst-port 22:22 onap_security_group
openstack security group rule create  --proto tcp \
    --dst-port 8080:8080 onap_security_group            # rancher
openstack security group rule create  --proto tcp \
    --dst-port 8078:8078 onap_security_group            # horizon
openstack security group rule create  --proto tcp \
    --dst-port 8879:8879 onap_security_group            # helm
openstack security group rule create  --proto tcp \
    --dst-port 2379:2379 onap_security_group           # k8s etcd
openstack security group rule create  --proto tcp \
    --dst-port 80:80 onap_security_group
openstack security group rule create  --proto tcp \
    --dst-port 443:443 onap_security_group
openstack security group rule create  --proto tcp \
    --dst-port 53:53 onap_security_group
openstack security group rule create  --proto udp \
    --dst-port 53:53 onap_security_group

# Allow communication between k8s cluster nodes
for SUBNET in public-subnet private-subnet onap_private_subnet ; do
    SUBNET_CIDR=`openstack subnet list --name $SUBNET -f value -c Subnet`
        openstack security group rule create --remote-ip $SUBNET_CIDR --proto tcp \
            --dst-port 1:65535 onap_security_group
        openstack security group rule create --remote-ip $SUBNET_CIDR --proto udp \
            --dst-port 1:65535 onap_security_group
done

# Get list of hypervisors and their zone
HOST_ZONE=$(openstack host list -f value | grep compute | head -n1 | cut -d' ' -f3)
HOST_NAME=($(openstack host list -f value | grep compute | cut -d' ' -f1))
HOST_COUNT=$(echo ${HOST_NAME[@]} | wc -w)
# Create VMs and assign floating IPs to them
VM_ITER=1
HOST_ITER=0
while [ $VM_ITER -le $VM_COUNT ] ; do
    openstack floating ip create public
    VM_NAME[$VM_ITER]="onap_vm${VM_ITER}"
    VM_IP[$VM_ITER]=$(openstack floating ip list -c "Floating IP Address" \
        -c "Port" -f value | grep None | cut -f1 -d " " | head -n1)
    # dispatch new VMs among compute nodes in round robin fashion
    openstack server create --flavor onap.large --image xenial \
        --nic net-id=onap_private_network --security-group onap_security_group \
        --key-name onap_key ${VM_NAME[$VM_ITER]} \
        --availability-zone ${HOST_ZONE}:${HOST_NAME[$HOST_ITER]}
    sleep 10 # wait for VM init before floating IP can be assigned
    openstack server add floating ip ${VM_NAME[$VM_ITER]} ${VM_IP[$VM_ITER]}
    echo "Waiting for ${VM_NAME[$VM_ITER]} to start up for 1m at $($DATE)"
    sleep 1m
    VM_ITER=$(($VM_ITER+1))
    HOST_ITER=$(($HOST_ITER+1))
    [ $HOST_ITER -ge $HOST_COUNT ] && HOST_ITER=0
done

openstack server list -c ID -c Name -c Status -c Networks -c Host --long

# check that SSH to all VMs is working
SSH_OPTIONS="-i $SSH_IDENTITY -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
COUNTER=1
while [ $COUNTER -le 10 ] ; do
    VM_UP=0
    VM_ITER=1
    while [ $VM_ITER -le $VM_COUNT ] ; do
       if ssh $SSH_OPTIONS -l $SSH_USER ${VM_IP[$VM_ITER]} exit &>/dev/null ; then
            VM_UP=$(($VM_UP+1))
            echo "${VM_NAME[$VM_ITER]} ${VM_IP[$VM_ITER]}: up"
        else
            echo "${VM_NAME[$VM_ITER]} ${VM_IP[$VM_ITER]}: down"
        fi
        VM_ITER=$(($VM_ITER+1))
    done
    COUNTER=$(($COUNTER+1))
    if [ $VM_UP -eq $VM_COUNT ] ; then
        break
    fi
    echo "Waiting for VMs to be accessible via ssh for 2m at $($DATE)"
    sleep 2m
done

openstack server list -c ID -c Name -c Status -c Networks -c Host --long

if [ $VM_UP -ne $VM_COUNT ] ; then
    echo "Only $VM_UP from $VM_COUNT VMs are accessible via ssh. Installation will be terminated."
    exit 1
fi

# Start ONAP installation
DATE_START=$($DATE)
echo -e "\nONAP Installation Started at $DATE_START\n"
$SCRIPT_DIR/deploy-onap-kubespray.sh ${VM_IP[@]}
echo -e "\nONAP Installation Started at $DATE_START"
echo -e "ONAP Installation Finished at $($DATE)\n"
