#!/bin/bash
#
# Copyright 2019 Tieto, Martin Klozik
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

# Script for automated deployment of OpenStack via devstack at OPNFV LAAS
# environment and installation of ONAP on top of OpenStack
set -x

export LC_ALL=C
export LANG=$LC_ALL

DIRNAME=$(dirname $0)

echo "Install OpenStack via Devstack"
sudo apt -y update
sudo apt -y install git
sudo useradd -s /bin/bash -d /opt/stack -m stack
echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
cat << EOF | sudo su - stack
git clone https://git.openstack.org/openstack-dev/devstack
cd devstack
export ADMIN_PASSWORD=opnfv
export DATABASE_PASSWORD=\$ADMIN_PASSWORD
export RABBIT_PASSWORD=\$ADMIN_PASSWORD
export SERVICE_PASSWORD=\$ADMIN_PASSWORD
./stack.sh |& tee stack.log
EOF

echo "Create $HOME/openrc file required for openstack CLI"
sudo -i cat << EOF > $HOME/openrc
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=opnfv
export OS_AUTH_URL=http://localhost/identity/v3/
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
source $HOME/openrc

echo "Configure OpenStack, install k8s and deploy ONAP"
cd $DIRNAME
sudo ./deploy-onap-openstack.sh