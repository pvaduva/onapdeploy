#!/bin/bash
#
# Copyright 2018-2019 Tieto, Richard Elias, Martin Klozik
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

# Script for automated deployment of ONAP with Kubernetes at OPNFV LAAS
# environment.
#

#
# Configuration
#
set -x

export LC_ALL=C
export LANG=$LC_ALL

MASTER=$1
SERVERS=$*
shift
SLAVES=$*

ONAP_BRANCH=${ONAP_BRANCH:-'dublin'}
NAMESPACE='onap'
DATE='date --rfc-3339=seconds'
SSH_USER=${SSH_USER:-"opnfv"}
SSH_OPTIONS='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no'
# use identity file from the environment SSH_IDENTITY
if [ -n "$SSH_IDENTITY" ] ; then
    SSH_OPTIONS="-i $SSH_IDENTITY $SSH_OPTIONS"
    ANSIBLE_IDENTITY="--private-key=$SSH_IDENTITY"
fi

TMP_DEP_LIST='/tmp/onap_pod_list.txt'

HELM_TIMEOUT=1800
case "$ONAP_BRANCH" in
    "beijing")
        HELM_VERSION=2.8.2
        KUBESPRAY_VERSION="bbfd2dc2bd088efc63747d903edd41fe692531d8"
        ANSIBLE_VERSION=2.7.9
        ;;
    "casablanca")
        HELM_VERSION=2.9.1
        KUBESPRAY_VERSION="bbfd2dc2bd088efc63747d903edd41fe692531d8"
        ANSIBLE_VERSION=2.7.9
        ;;
    *)
        HELM_VERSION=2.12.3
        KUBESPRAY_VERSION="v2.10.0"
        ANSIBLE_VERSION=2.7.9
        ;;
esac

ONAP_MINIMAL="aaf aai cassandra dmaap mariadb-galera log portal robot sdc sdnc so vid"
# by defalult install minimal ONAP installation
# empty list of ONAP_COMPONENT means full ONAP installation
ONAP_COMPONENT=${ONAP_COMPONENT:-$ONAP_MINIMAL}

#
# Functions
#
function usage() {
    echo "usage"
    cat <<EOL
Usage:
      $0 <MASTER> [ <SLAVE1> <SLAVE2> ... ]

  where <MASTER> and <SLAVEx> are IP addresses of servers to be used
  for ONAP installation.

  Script behavior is affected by following environment variables:

  ONAP_COMPONENT    - a list of ONAP components to be installed, empty list
        will trigger a full ONAP installation
        VALUE: "$ONAP_COMPONENT"

  ONAP_BRANCH       - version of ONAP to be installed (OOM branch version)
        VALUE: "$ONAP_BRANCH"

  NAMESPACE         - name of ONAP namespace in kubernetes cluster
        VALUE: "$NAMESPACE"

  SSH_USER          - user name to be used to access <MASTER> and <SLAVEx>
        servers
        VALUE: "$SSH_USER"

  SSH_IDENTITY      - (optional) ssh identity file to be used to access
        <MASTER> and <SLAVEx> servers as a SSH_USER
        VALUE: "$SSH_IDENTITY"

NOTE: Following must be assured for <MASTER> and <SLAVEx> servers before
      $0 execution:
      1) SSH_USER must be able to access servers via ssh without a password
      2) SSH_USER must have a password-less sudo access
EOL
}

# Check if server IPs of kubernetes nodes are configured at given server.
# If it is not the case, then kubespray invetory file must be updated.
function check_server_ips() {
    for SERVER_IP in $(grep '^ *ip: ' $1 | sed -re 's/^ *ip: ([0-9\.]+).*$/\1/') ; do
        IP_OK="false"
        for IP in $(ssh $SSH_OPTIONS $SSH_USER@$SERVER_IP "ip a | grep -Ew 'inet' | sed -re 's/^ *inet ([0-9\.]+).*$/\1/g'") ; do
            if [ "$IP" == "$SERVER_IP" ] ; then
                IP_OK="true"
            fi
        done
        # access IP (e.g. OpenStack floating IP) is not server local address, so update invetory
        if [ $IP_OK == "false" ] ; then
            # get server default GW dev
            DEV=$(ssh $SSH_OPTIONS $SSH_USER@$SERVER_IP "ip route ls" | grep ^default | sed -re 's/^.*dev (.*)$/\1/')
            LOCAL_IP=$(ssh $SSH_OPTIONS $SSH_USER@$SERVER_IP "ip -f inet addr show $DEV" | grep -Ew 'inet' | sed -re 's/^ *inet ([0-9\.]+).*$/\1/g')
            if [ "$LOCAL_IP" == "" ] ; then
                echo "Can't read local IP for server with IP $SERVER_IP"
                exit 1
            fi
            sed -i'' -e "s/ ip: $SERVER_IP/ ip: $LOCAL_IP/" $1
        fi
    done
}

# sanity check
if [ "$SERVERS" == "" ] ; then
    usage
    exit 1
fi

#
# Installation
#

# detect CPU architecture to download correct helm binary
CPU_ARCH=$(ssh $SSH_OPTIONS $SSH_USER@"$MASTER" "uname -p")
case "$CPU_ARCH" in
    "x86_64")
        ARCH="amd64"
        ;;
    "aarch64")
        ARCH="arm64"
        ;;
    *)
        echo "Unsupported CPU architecture '$CPU_ARCH' was detected."
        exit 1
esac

# print configuration
cat << EOL
list of configuration options:
    SERVERS="$SERVERS"
    ONAP_COMPONENT="$ONAP_COMPONENT"
    ONAP_BRANCH="$ONAP_BRANCH"
    NAMESPACE="$NAMESPACE"
    SSH_USER="$SSH_USER"
    SSH_IDENTITY="$SSH_IDENTITY"
    ARCH="$ARCH"

EOL

# install K8S cluster by kubespray
sudo apt-get -y update
sudo apt-get -y install git python-jinja2 python3-pip libffi-dev libssl-dev
git clone https://github.com/kubernetes-incubator/kubespray.git
cd kubespray
git checkout $KUBESPRAY_VERSION
pip3 install ansible==$ANSIBLE_VERSION
pip3 install -r requirements.txt

# increate max pods limit to 400
sed -i "s/kubelet_max_pods: *110/kubelet_max_pods: 400/" roles/kubernetes/node/defaults/main.yml
sed -i "s/odelocaldns_image_repo: \"k8s.gcr.io/k8s-dns-node-cache\"/nodelocaldns_image_repo: \"onapmulti/k8s-dns-node-cache-arm64\"" roles/download/defaults/main.yml

# prepare k8s cluster configuration
cp -r inventory/sample inventory/k8s_cluster
export CONFIG_FILE=inventory/k8s_cluster/hosts.yml
rm $CONFIG_FILE
python3 contrib/inventory_builder/inventory.py $SERVERS
check_server_ips $CONFIG_FILE
cat $CONFIG_FILE

# install k8s cluster
if ( ! ansible-playbook -i $CONFIG_FILE -b -u $SSH_USER $ANSIBLE_IDENTITY cluster.yml ) ; then
    echo "Kubespray installation has failed at $($DATE)"
    exit 1
fi

# use standalone K8S master if there are enough VMs available for the K8S cluster
SERVERS_COUNT=$(echo $SERVERS | wc -w)
if [ $SERVERS_COUNT -gt 2 ] ; then
    K8S_NODES=$SLAVES
else
    K8S_NODES=$SERVERS
fi

echo "INSTALLATION TOPOLOGY:"
echo "Kubernetes Master: $MASTER"
echo "Kubernetes Nodes: $K8S_NODES"
echo
echo "CONFIGURING NFS ON MASTER"
ssh $SSH_OPTIONS $SSH_USER@"$MASTER" "bash -s" <<OOMDEPLOY
sudo su
apt-get install -y nfs-kernel-server

echo "Installing nfs server"
mkdir -p /dockerdata-nfs
chmod 777 /dockerdata-nfs
echo "/dockerdata-nfs *(rw,no_root_squash,no_subtree_check)">>/etc/exports
service nfs-kernel-server restart
OOMDEPLOY

echo "CONFIGURING NFS ON SLAVES"
echo "$SLAVES"

for SLAVE in $SLAVES;
do
ssh $SSH_OPTIONS $SSH_USER@"$SLAVE" "bash -s" <<CONFIGURENFS &
    sudo su
    apt-get install -y nfs-common
    mkdir /dockerdata-nfs
    chmod 777 /dockerdata-nfs
    echo "$MASTER:/dockerdata-nfs /dockerdata-nfs   nfs    auto  0  0" >> /etc/fstab
    mount -a
    mount | grep dockerdata-nfs
CONFIGURENFS
done
wait

echo "DEPLOYING OOM ON MASTER"
echo "$MASTER"

ssh $SSH_OPTIONS $SSH_USER@"$MASTER" "bash -s" <<OOMDEPLOY
sudo su
apt-get install -y make

echo "create namespace '$NAMESPACE'"
cat <<EOF | kubectl create -f -
{
  "kind": "Namespace",
  "apiVersion": "v1",
  "metadata": {
    "name": "$NAMESPACE",
    "labels": {
      "name": "$NAMESPACE"
    }
  }
}
EOF
kubectl get namespaces --show-labels
kubectl -n kube-system create sa tiller
kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller
kubectl create clusterrolebinding default-admin --clusterrole cluster-admin --serviceaccount=$NAMESPACE:default

# configure default namespace
kubectl config set-context \$(kubectl config current-context) --namespace=$NAMESPACE

rm -rf oom
echo "pulling new oom"
git clone -b $ONAP_BRANCH http://gerrit.onap.org/r/oom
cd oom
# AAI helm charts were moved to separate repository => init submodules
git submodule update --init --recursive

echo "starting onap deployments"
cd kubernetes/

ONAP_CFG='onap/values.yaml'
ONAP_ENC_KEY="\$(cat so/resources/config/mso/encryption.key)"

# Enable selected ONAP components
if [ -n "$ONAP_COMPONENT" ] ; then
    # disable all components and enable only selected in next loop
    sed -i '/^.*:$/!b;n;s/enabled: *true/enabled: false/' \${ONAP_CFG}
    echo -n "Enable following ONAP components:"
    for COMPONENT in $ONAP_COMPONENT; do
        echo -n " \$COMPONENT"
        sed -i '/^'\${COMPONENT}':$/!b;n;s/enabled: *false/enabled: true/' \${ONAP_CFG}
    done
    echo
else
    echo "All ONAP components will be installed"
fi

# Configure OpenStack details in onap/values.yaml
if [ -f "\${ONAP_CFG}" -a -n "\${ONAP_ENC_KEY}" -a \
     -n "$OS_USERNAME" -a -n "$OS_PASSWORD" -a \
     -n "$OS_AUTH_URL" -a -n "$OS_PROJECT_NAME" -a \
     -n "$OS_USER_DOMAIN_NAME" ] ; then
    echo "Configure OpenStack details in \${ONAP_CFG}"
    OS_PASSWORD_ENC=\$(echo -n "$OS_PASSWORD" | openssl aes-128-ecb -e -K \${ONAP_ENC_KEY} -nosalt | xxd -c 256 -ps)
    sed -i "s|openStackKeyStoneUrl:.*$|openStackKeyStoneUrl: \"$OS_AUTH_URL\"|" \${ONAP_CFG}
    sed -i "s|openStackServiceTenantName:.*$|openStackServiceTenantName: \"$OS_PROJECT_NAME\"|" \${ONAP_CFG}
    sed -i "s|openStackDomain:.*$|openStackDomain: \"$OS_USER_DOMAIN_NAME\"|" \${ONAP_CFG}
    sed -i "s|openStackUserName:.*$|openStackUserName: \"$OS_USERNAME\"|" \${ONAP_CFG}
    sed -i "s|openStackEncryptedPassword:.*$|openStackEncryptedPassword: \"\${OS_PASSWORD_ENC}\"|" \${ONAP_CFG}
    sed -i "s|openStackEncryptedPasswordHere:.*$|openStackEncryptedPasswordHere: \"\${OS_PASSWORD_ENC}\"|" \${ONAP_CFG}
else
    echo "WARNING: OpenStack details cannot be configured in \${ONAP_CFG}, because they are not available."
fi

wget http://storage.googleapis.com/kubernetes-helm\
/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz
tar -zxvf helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz
mv linux-${ARCH}/helm /usr/local/bin/helm
helm init --tiller-image onapmulti/tiller:latest --upgrade --service-account tiller
# run helm server on the background and detached from current shell
nohup helm serve  0<&- &>/dev/null &
echo "Waiting for helm setup for 5 min at \$($DATE)"
sleep 5m
helm version
helm repo add local http://127.0.0.1:8879
helm repo remove stable
helm repo list
cp -R helm/plugins/ ~/.helm
make all
if ( ! helm deploy dev local/onap --namespace $NAMESPACE --timeout $HELM_TIMEOUT) ; then
    echo "ONAP installation has failed at \$($DATE)"
    exit 1
fi

cd ../../

echo "Waiting for ONAP deployments to be up \$($DATE)"
function get_onap_deployments() {
    sudo -i kubectl get deployments --namespace $NAMESPACE 2> /dev/null | grep -v ' 0/0 ' | tail -n+2 > $TMP_DEP_LIST
    return \$(cat $TMP_DEP_LIST | wc -l)
}
FAILED_DEPS_LIMIT=0         # maximal number of failed ONAP deployemnts
ALL_DEPS_LIMIT=20           # minimum ONAP deployemnts to be up & running
WAIT_PERIOD=60              # wait period in seconds
MAX_WAIT_TIME=\$((3600*3))  # max wait time in seconds
MAX_WAIT_PERIODS=\$((\$MAX_WAIT_TIME/\$WAIT_PERIOD))
COUNTER=0
get_onap_deployments
ALL_DEPS=\$?
PENDING=\$(grep -E '0/|1/2|1/3|2/3' $TMP_DEP_LIST | wc -l)
while [ \$PENDING -gt \$FAILED_DEPS_LIMIT -o \$ALL_DEPS -lt \$ALL_DEPS_LIMIT ]; do
  # print header every 20th line
  if [ \$COUNTER -eq \$((\$COUNTER/20*20)) ] ; then
    printf "%-3s %-29s %-3s/%s\n" "Nr." "Datetime of check" "Err" "Total DEPs"
  fi
  COUNTER=\$((\$COUNTER+1))
  printf "%3s %-29s %3s/%-3s\n" \$COUNTER "\$($DATE)" \$PENDING \$ALL_DEPS
  sleep \$WAIT_PERIOD
  if [ "\$MAX_WAIT_PERIODS" -eq \$COUNTER ]; then
    FAILED_DEPS_LIMIT=800
    ALL_DEPS_LIMIT=0
  fi
  get_onap_deployments
  ALL_DEPS=\$?
  PENDING=\$(grep -E '0/|1/2' $TMP_DEP_LIST | wc -l)
done

get_onap_deployments
cp $TMP_DEP_LIST ~/onap_all_deployments.txt
echo
echo "========================"
echo "ONAP INSTALLATION REPORT"
echo "========================"
echo
FAILED_DEPS=0
if [ \$PENDING -gt 0 ] ; then
    echo "List of Failed deployments"
    echo "--------------------------"
    grep -E '0/|1/2|1/3|2/3' $TMP_DEP_LIST | tee ~/onap_failed_deployments.txt
    FAILED_DEPS=\$(cat ~/onap_failed_deployments.txt  | wc -l)
    echo
fi
echo "Summary:"
echo "--------"
echo "  Deployments Failed: \$FAILED_DEPS"
echo "  Deployments Total:  \$(cat ~/onap_all_deployments.txt  | wc -l)"
echo
echo "ONAP health TC results"
echo "----------------------"
cd oom/kubernetes/robot
./ete-k8s.sh $NAMESPACE health | tee ~/onap_health.txt
./ete-k8s.sh $NAMESPACE healthdist | tee ~/onap_healthdist.txt
echo "==============================="
echo "END OF ONAP INSTALLATION REPORT"
echo "==============================="
OOMDEPLOY

echo "Finished install, ruturned from Master at $($DATE)"
exit 0
