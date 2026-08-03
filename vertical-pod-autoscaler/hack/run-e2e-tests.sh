#!/bin/bash

# Copyright 2018 The Kubernetes Authors.
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

set -o nounset
set -o pipefail

SCRIPT_ROOT=$(dirname ${BASH_SOURCE})/..

function print_help {
  echo "ERROR! Usage: run-e2e-tests.sh <suite>"
  echo "<suite> should be one of:"
  echo " - recommender"
  echo " - updater"
  echo " - admission-controller"
  echo " - actuation"
  echo " - full-vpa"
}


if [ $# -eq 0 ]; then
  print_help
  exit 1
fi

if [ $# -gt 1 ]; then
  print_help
  exit 1
fi

SUITE=$1

export GO111MODULE=on
# todo(adrianmoisey): Make the setting of GOBIN nicer
ABSOLUTE_PATH=$(realpath "${SCRIPT_ROOT}")
export GOBIN="${ABSOLUTE_PATH}/test/e2e/_output/bin"

export ARTIFACTS=${ARTIFACTS:-/workspace/_artifacts}

SKIP="--ginkgo.skip=\[Feature\:OffByDefault\]"

if [ "${TEST_WITH_FEATURE_GATES_ENABLED:-}" == "true" ]; then
  SKIP=""
fi

NUMPROC=${NUMPROC:-10}

case ${SUITE} in
  recommender|updater|admission-controller|actuation|full-vpa)
    export KUBECONFIG=$HOME/.kube/config
    pushd ${SCRIPT_ROOT}/test/e2e
    go install github.com/onsi/ginkgo/v2/ginkgo
    ${GOBIN}/ginkgo build v1/ && ${GOBIN}/ginkgo --nodes=$NUMPROC --focus="xxxx" v1/v1.test -- --report-dir=${ARTIFACTS} --disable-log-dump ${SKIP}
    V1_RESULT=$?
    popd
    echo v1 test result: ${V1_RESULT}
    if [ $V1_RESULT -gt 0 ]; then
      echo "Please check v1 \"go test\" logs!"
    fi
    if [ $V1_RESULT -gt 0 ]; then
      echo "Tests failed"
      exit 1
    fi
    ;;
  *)
    print_help
    exit 1
    ;;
esac


kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: workload1
  namespace: default
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: workload1
  updatePolicy:
    updateMode: 'InPlaceOrRecreate'
  resourcePolicy:
    podPolicy:
      mode: Auto
EOF


kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload1
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload1
  template:
    metadata:
      labels:
        app: workload1
    spec:
      containers:
        - name: c1
          image: gcr.io/k8s-staging-e2e-test-images/resource-consumer:1.9
          args: ["-port=8080"]  
          ports:  
            - containerPort: 8080
          resources:
            requests:
              memory: 100Mi
            limits:
              memory: 100Mi
        - name: c2
          image: gcr.io/k8s-staging-e2e-test-images/resource-consumer:1.9
          args: ["-port=9090"]  
          ports:  
            - containerPort: 9090
          #resources:
          #   requests:
          #     memory: 100Mi
          #   limits:
          #     memory: 100Mi
EOF

sleep 5

POD_NAME=$(kubectl get pods -n "default" -l "app=workload1" -o jsonpath='{.items[0].metadata.name}')

POD_IP=$(kubectl get pod "$POD_NAME" -n "default" -o jsonpath='{.status.podIP}')

kubectl run -it --rm \
    --image=curlimages/curl \
    --restart=Never curly -- \
    curl --data "millicores=80&durationSec=60000" http://"${POD_IP}":8080/ConsumeCPU

kubectl run -it --rm \
    --image=curlimages/curl \
    --restart=Never curly1 -- \
    curl --data "megabytes=80&durationSec=6000000" http://"${POD_IP}":8080/ConsumeMem