#!/usr/bin/env bash
# Copyright 2024 The KubeStellar Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x -e # echo so users can understand what is happening

use_release=false
KUBESTELLAR_CONTROLLER_MANAGER_VERBOSITY=2
TRANSPORT_CONTROLLER_VERBOSITY=4

while [ $# != 0 ]; do
    case "$1" in
        (-h|--help) echo "$0 usage: (--released | --kubestellar-controller-manager-verbosity \$num | --transport-controller-verbosity \$num)*"
                    exit;;
        (--released)
            wds_extra="-p kubestellar"
            use_release=true;;
        (--kubestellar-controller-manager-verbosity)
          if (( $# > 1 )); then
            KUBESTELLAR_CONTROLLER_MANAGER_VERBOSITY="$2"
            shift
          else
            echo "Missing kubestellar-controller-manager-verbosity value" >&2
            exit 1;
          fi;;
        (--transport-controller-verbosity)
          if (( $# > 1 )); then
            TRANSPORT_CONTROLLER_VERBOSITY="$2"
            shift
          else
            echo "Missing transport-controller-verbosity value" >&2
            exit 1;
          fi;;
        (*) echo "$0: unrecognized argument/flag '$1'" >&2
            exit 1
    esac
    shift
done

if [ "$use_release" = true ] && [ "$KUBESTELLAR_CONTROLLER_MANAGER_VERBOSITY" != 2 ]
then echo "$0: kubestellar-controller-manager-verbosity must be 2 when using --released" >&2
     exit 1
fi

set -e # exit on error

if [[ "$KFLEX_DISABLE_CHATTY" = true ]] ; then
   disable_chatty_status="--chatty-status=false"
   echo "disable_chatty_status = $disable_chatty_status"
fi

SRC_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
COMMON_SRCS="${SRC_DIR}/../common"
source "$COMMON_SRCS/setup-shell.sh"

:
: -------------------------------------------------------------------------
: Create a Kind hosting cluster with nginx ingress controller and KubeFlex controller-manager
:
kflex init --create-kind $disable_chatty_status
: Kubeflex kind cluster created.

:
: -------------------------------------------------------------------------
: Install the post-create-hooks for ocm and kubstellar controller manager
:
kubectl apply -f ${SRC_DIR}/../../../config/postcreate-hooks/ocm.yaml
if [ "$use_release" == true ]
then kubectl apply -f ${SRC_DIR}/../../../config/postcreate-hooks/kubestellar.yaml
fi
: 'Kubestellar post-create-hook(s) applied.'

:
: -------------------------------------------------------------------------
: 'Create an inventory & mailbox space of type vcluster running OCM (Open Cluster Management) directly in KubeFlex. Note that -p ocm runs a post-create hook on the vcluster control plane which installs OCM on it.'
:
kflex create its1 --type vcluster -p ocm $disable_chatty_status
: its1 created.

:
: -------------------------------------------------------------------------
: Install singleton status return addon in ITS1
:
wait-for-cmd kubectl --context its1 api-resources "|" grep managedclusteraddons
helm --kube-context its1 upgrade --install status-addon -n open-cluster-management oci://ghcr.io/kubestellar/ocm-status-addon-chart --version v0.2.0-rc8

:
: -------------------------------------------------------------------------
: Create a Workload Description Space wds1 directly in KubeFlex.
:
kflex create wds1 $wds_extra $disable_chatty_status
kubectl --context kind-kubeflex label cp wds1 kflex.kubestellar.io/cptype=wds

if [ "$use_release" != true ]; then
    cd "${SRC_DIR}/../../.."
    pwd
    make ko-build-local
    rm -rf local-chart
    make install-local-chart KUBE_CONTEXT=kind-kubeflex "KUBESTELLAR_CONTROLLER_MANAGER_VERBOSITY=$KUBESTELLAR_CONTROLLER_MANAGER_VERBOSITY"
    cd -
fi
echo "wds1 created."

:
: -------------------------------------------------------------------------
: Run OCM transport controller in a pod
:
cd "${SRC_DIR}/../../.." ## go up to KubeStellar directory
KUBESTELLAR_DIR="$(pwd)"
OCM_TRANSPORT_PLUGIN_RELEASE="0.1.5"
curl -sL https://github.com/kubestellar/ocm-transport-plugin/archive/refs/tags/v${OCM_TRANSPORT_PLUGIN_RELEASE}.tar.gz | tar xz
cd ocm-transport-plugin-${OCM_TRANSPORT_PLUGIN_RELEASE}
OCM_TRANSPORT_PLUGIN_DIR="$(pwd)"
pwd
echo "replace github.com/kubestellar/kubestellar => ${KUBESTELLAR_DIR}/" >> go.mod
go mod tidy # TODO to be deleted next time we bump ocm transport release (done in ocm transport makefile)
IMAGE_TAG=${OCM_TRANSPORT_PLUGIN_RELEASE} make ko-build-local
kind load --name kubeflex docker-image ko.local/transport-controller:${OCM_TRANSPORT_PLUGIN_RELEASE} # load local image to kubeflex
cd "${KUBESTELLAR_DIR}"
pwd
rm -rf ${OCM_TRANSPORT_PLUGIN_DIR}
echo "running ocm transport plugin..."
kubectl config use-context kind-kubeflex ## transport deployment script assumes it runs within kubeflex context
IMAGE_PULL_POLICY=Never ./scripts/deploy-transport-controller.sh wds1 its1 ko.local/transport-controller:${OCM_TRANSPORT_PLUGIN_RELEASE} --controller-verbosity "$TRANSPORT_CONTROLLER_VERBOSITY"

wait-for-cmd '(kubectl -n wds1-system wait --for=condition=Ready pod/$(kubectl -n wds1-system get pods -l name=transport-controller -o jsonpath='{.items[0].metadata.name}'))'

echo "transport controller is running."

wait-for-cmd 'kubectl --context its1 get ns customization-properties'

:
: -------------------------------------------------------------------------
: Create clusters and register with OCM
:
function create_cluster() {
  cluster=$1
  kind create cluster --name $cluster
  kubectl config rename-context kind-${cluster} $cluster
  clusteradm --context its1 get token | grep '^clusteradm join' | sed "s/<cluster_name>/${cluster}/" | awk '{print $0 " --context '${cluster}' --singleton --force-internal-endpoint-lookup"}' | sh
}

"${SRC_DIR}/../../../hack/check_pre_req.sh" --assert --verbose ocm

create_cluster cluster1
create_cluster cluster2

: Wait for csrs in its1
wait-for-cmd '(($(kubectl --context its1 get csr 2>/dev/null | grep -c Pending) >= 2))'

clusteradm --context its1 accept --clusters cluster1
clusteradm --context its1 accept --clusters cluster2

kubectl --context its1 get managedclusters
kubectl --context its1 label managedcluster cluster1 location-group=edge name=cluster1 region=east
kubectl --context its1 create cm -n customization-properties cluster1 --from-literal clusterURL=https://my.clusters/1001-abcd
kubectl --context its1 label managedcluster cluster2 location-group=edge name=cluster2 region=west
kubectl --context its1 create cm -n customization-properties cluster2 --from-literal clusterURL=https://my.clusters/2002-cdef

:
: -------------------------------------------------------------------------
: Get all deployments and statefulsets running in the hosting cluster.
: Expect to see the wds1 kubestellar-controller-manager and transport-controller created in the wds1-system
: namespace and the its1 statefulset created in the its1-system namespace.
:
if ! expect-cmd-output 'kubectl --context kind-kubeflex get deployments,statefulsets --all-namespaces' 'grep -e wds1 -e its1 | wc -l | grep -wq 5'
then
    echo "Failed to see wds1 deployment and its1 statefulset."
    exit 1
fi

:
: -------------------------------------------------------------------------
: "Get available clusters with label location-group=edge and check there are two of them"
:
if ! expect-cmd-output 'kubectl --context its1 get managedclusters -l location-group=edge' 'wc -l | grep -wq 3'
then
    echo "Failed to see two clusters."
    exit 1
fi
