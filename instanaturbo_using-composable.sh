#!/bin/bash

# Set the namespace to turbonomic by default
if [ -z "${NS}" ]; then
	export NS=turbonomic
fi

#Create project
oc get ns ${NS} >>/dev/null 2>&1 || oc create ns ${NS}

#Install Composable, Kubeturbo and Instana-Agent operators
cat << EOF | oc -n ${NS} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: Composable.v1alpha1.ibmcloud.ibm.com, Kubeturbo.v1.charts.helm.k8s.io, InstanaAgent.v1beta1.instana.io
  name: turbonomic-mkk5d
  namespace: ${NS}
spec:
  targetNamespaces:
  - ${NS}
EOF

cat << EOF | oc -n ${NS} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/composable-operator.turbonomic: ""
  name: composable-operator
  namespace: ${NS}
spec:
  name: composable-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
until oc get crd composables.ibmcloud.ibm.com >> /dev/null 2>&1; do sleep 5; done

cat << EOF | oc -n ${NS} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubeturbo-certified.turbonomic: ""
  name: kubeturbo-certified
  namespace: ${NS}
spec:
  name: kubeturbo-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF
until oc get crd kubeturbos.charts.helm.k8s.io >> /dev/null 2>&1; do sleep 5; done

cat << EOF | oc -n ${NS} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/instana-agent.turbonomic: ""
  name: instana-agent
  namespace: ${NS}
spec:
  name: instana-agent
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF
until oc get crd agents.instana.io >> /dev/null 2>&1; do sleep 5; done

#Install Composable custom resources
echo "Installing Kubeturbo Composable"
cat << EOF | oc -n ${NS} apply -f -
apiVersion: ibmcloud.ibm.com/v1alpha1
kind: Composable
metadata:
  name: turbo-release
spec:
  template:
    apiVersion: charts.helm.k8s.io/v1
    kind: Kubeturbo
    metadata:
      name: kubeturbo-release
    spec:
      serverMeta:
        turboServer: <SERVER_URL>
      targetConfig:
        targetName: ocp-wdc02

EOF
until oc -n ${NS} get kubeturbo kubeturbo-release >>/dev/null 2>&1; do sleep 5; done

echo "Installing Instana Composable"
cat << EOF | oc -n ${NS} apply -f -
apiVersion: ibmcloud.ibm.com/v1alpha1
kind: Composable
metadata:
  name: instana-release
spec:
  template:
    apiVersion: instana.io/v1beta1
    kind: InstanaAgent
    metadata:
      name: instana-agent
    spec:
      agent.endpoint.host: ingress-orange-saas.instana.io
      agent.endpoint.port: 443
      agent.env:
        INSTANA_AGENT_TAGS: demo
      agent.key: <AGENT_KEY>
      agent.zone.name: wdc02
      cluster.name: ocp-wdc02

EOF
until oc -n ${NS} get kubeturbo kubeturbo-release >>/dev/null 2>&1; do sleep 5; done
