#!/bin/bash

# Offer EULA
which java
if [ $? -eq 0 ]; then
	java -jar LAPApp.jar -l Softcopy -s Status -text_only
else
	tar xzf OpenJDK11U-jre_x64_linux_hotspot_11.0.7_10.tar.gz
	./jdk-11.0.7+10-jre/bin/java -jar LAPApp.jar -l Softcopy -s Status -text_only
fi
if [ $? -ne 9 ]
then
	echo "EULA not accepted, exiting installation."
	exit 9
fi

# Use custom repository URL
if [ -z "${REPOSITORY}" ]; then
	export REPOSITORY=turbonomic
fi
export TAG=8.0.4

# load and push operators and kubeturbo images
docker load -i images/kubeturbo-operator.tar
docker tag kubeturbo-operator:8.0 $REPOSITORY/kubeturbo-operator:8.0
docker push $REPOSITORY/kubeturbo-operator:8.0
docker load -i images/t8c-operator.tar
docker tag t8c-operator:8.0 $REPOSITORY/t8c-operator:8.0
docker push $REPOSITORY/t8c-operator:8.0

# load and push platform images
images=( action-orchestrator api arangodb auth clustermgr consul cost db group history kafka kubeturbo market nginx plan-orchestrator repository rsyslog topology-processor ui zookeeper mediation-appdynamics mediation-dynatrace)
for image in "${images[@]}"
do
	docker load -i images/$image.tar
	docker tag $image:$TAG $REPOSITORY/$image:$TAG
	docker push $REPOSITORY/$image:$TAG
done

#Install
NS=turbonomic
oc get ns ${NS} >>/dev/null 2>&1 || oc create ns ${NS}

#Install Turbonomic Operator
oc -n ${NS} apply -f deploy/service_account.yaml -n turbonomic
oc -n ${NS} apply -f deploy/role.yaml -n turbonomic
oc -n ${NS} apply -f deploy/role_binding.yaml -n turbonomic
oc -n ${NS} apply -f deploy/crds/charts_v1alpha1_xl_crd.yaml
sed "s%turbonomic%${REPOSITORY}%g" deploy/operator.template > deploy/operator.yaml
oc -n ${NS} apply -f deploy/operator.yaml -n turbonomic
oc -n ${NS} get cm repository >>/dev/null 2>&1 || oc -n ${NS} create cm repository --from-literal=repository=${REPOSITORY}

#Install CP4M Hooks
cat << EOF | oc -n ${NS} apply -f -
apiVersion: integrations.sdk.management.ibm.com/v1beta1
kind: OidcClientRegistration
metadata:
  name: turbonomic-oidc-registration
spec:
  registration:
    post_logout_redirect_uris:
      - https://api-turbonomic.{{ .OpenShiftBaseUrl }}/app/index.html
    trusted_uri_prefixes:
      - https://api-turbonomic.{{ .OpenShiftBaseUrl }}
      - https://api-turbonomic.{{ .OpenShiftBaseUrl }}:443
    redirect_uris:
      - https://api-turbonomic.{{ .OpenShiftBaseUrl }}/vmturbo/oauth2/login/code/ibm
    client_secret:
      secretName: turbonomic-oidc-secret
      secretKey: CLIENT_SECRET
    apply_client_secret: true
EOF
cat << EOF | oc -n ${NS} apply -f -
apiVersion: integrations.sdk.management.ibm.com/v1beta1
kind: NavMenuEntry
metadata:
  name: turbonomic-navmenu
  # This resource is Cluster-Scoped, so leave the namespace blank
spec:
  # The name of the browser tab that the link will be opened in
  target: "Turbonomic"
  # The name that will be displayed on the item in the drop-down menu
  name: "Application Resource Management"
  # The submenu that the new entry will appear under, available options are:
  # "administer-mcm";"sre";"monitor";"costs";"automate";"applications";"observe"
  parentId: "monitor"
  # User roles that will be able to see the menu item in the UI, available options are:
  # "ClusterAdministrator";"Administrator";"Operator";"Viewer";"Editor";"Auditor";"AccountAdministrator"
  roles:
    - name: ClusterAdministrator
    - name: Administrator
    - name: Operator
    - name: Viewer
    - name: Editor
    - name: Auditor
    - name: AccountAdministrator
  # The URL that the new menu entry will link to
  url: https://api-turbonomic.{{ .OpenShiftBaseUrl }}/vmturbo/oauth2/authorization/ibm
EOF

#Install Composable
cat << EOF | oc -n ${NS} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: Composable.v1alpha1.ibmcloud.ibm.com
  name: turbonomic-rvbhs
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
  installPlanApproval: Automatic
  name: composable-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

#Install Turbonomic Composable
echo "Installing Turbonomic Composable"
until oc get crd composables.ibmcloud.ibm.com >> /dev/null 2>&1; do sleep 5; done
cat << EOF | oc -n ${NS} apply -f -
apiVersion: ibmcloud.ibm.com/v1alpha1
kind: Composable
metadata:
  name: turbonomic-release
spec:
  template:
    apiVersion: charts.helm.k8s.io/v1
    kind: Xl
    metadata:
      name: xl-release
    spec:
      # Global settings
      global:
      #  registry: registry.connect.redhat.com
      #  imageUsername: turbouser
      #  imagePassword: turbopassword
        repository:
          getValueFrom:
            kind: ConfigMap
            name: repository
            path: '{.data.repository}'
        tag: 8.0.4
        customImageNames: false
        annotations:
          prometheus.io/port: "8080"
          prometheus.io/scrape: "true"

      nginxingress:
        enabled: false
      openshiftingress:
        enabled: true

      api:
        javaComponentOptions: "-Djavax.net.ssl.trustStore=/home/turbonomic/data/cacerts"

      properties:
        api:
          openIdEnabled: true
          openIdClients: ibm
          openIdClientAuthentication: post
          openIdUserAuthentication: form
          openIdClientId:
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.CLIENT_ID}'
              format-transformers:
                - "Base64ToString" 
          openIdClientSecret:
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.CLIENT_SECRET}'
              format-transformers:
                - "Base64ToString" 
          openIdAccessTokenUri:
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.TOKEN_ENDPOINT}'
              format-transformers:
                - "Base64ToString" 
          openIdUserAuthorizationUri:
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.AUTHORIZE_ENDPOINT}'
              format-transformers:
                - "Base64ToString" 
          openIdUserInfoUri: 
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.USER_INFO_ENDPOINT}'
              format-transformers:
                - "Base64ToString" 
          openIdJwkSetUri: 
            getValueFrom:
              kind: Secret
              name: turbonomic-oidc-secret
              path: '{.data.JWK_ENDPOINT}'
              format-transformers:
                - "Base64ToString" 
EOF
#Wait for API Pod to be ready
sleep 60
oc -n ${NS} wait --'for=condition=Ready' pod -l app.kubernetes.io/name=api --timeout 10m
API_POD=$(oc -n ${NS} get po -l app.kubernetes.io/name=api -o go-template='{{ (index .items 0).metadata.name }}')
until oc -n ${NS} get secret cs-ca-certificate-secret -o jsonpath={.data."ca\.crt"} | base64 -d > ca.crt 2>>/dev/null; do sleep 5; done 
rm -f cacerts && keytool -import -trustcacerts -alias cp -file ca.crt -keystore cacerts -storepass changeit -noprompt
oc -n ${NS} cp cacerts ${API_POD}:/home/turbonomic/data
oc -n ${NS} delete pod ${API_POD}
oc -n ${NS} wait --'for=condition=Ready' pod -l app.kubernetes.io/name=api --timeout 10m
TURBO_ROUTE=$(oc get route api -o jsonpath='{.spec.host}')
echo "Turbonomic Console URL is: https://${TURBO_ROUTE}"


