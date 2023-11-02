#!/bin/bash

# Update helm
#--------------------------------------------------------------
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh -v 3.12.3
mv /usr/local/bin/helm /usr/bin/helm
rm get_helm.sh

# APISIX + APISIX-ingress
#--------------------------------------------------------------
git clone https://github.com/apache/apisix-helm-chart.git
# git clone https://github.com/kodxxl/apisix-helm-chart.git
cd apisix-helm-chart/

APISIX_ADMIN_KEY=$(dd if=/dev/urandom count=1 status=none | md5sum | cut -d " " -f1)
APISIX_VIEWER_KEY=$(dd if=/dev/urandom count=1 status=none | md5sum | cut -d " " -f1)

kubectl create namespace apisix
kubectl label namespace apisix istio-injection=enabled

helm install apisix charts/apisix --namespace apisix \
  --set admin.allow.ipList="{0.0.0.0/0, ::/64}" \
  --set admin.credentials.admin=${APISIX_ADMIN_KEY} \
  --set admin.credentials.viewer=${APISIX_VIEWER_KEY} \
  --set gateway.externalTrafficPolicy=Local 

helm install apisix-ingress-controller charts/apisix-ingress-controller --namespace apisix \
  --set config.apisix.adminKey=${APISIX_ADMIN_KEY} \
  --set config.apisix.serviceNamespace=apisix \
  --set config.apisix.clusterName=cluster.local \
  --set config.apisix.adminAPIVersion=v3

unset APISIX_ADMIN_KEY
unset APISIX_VIEWER_KEY

# Keycloak
#--------------------------------------------------------------
KC_ADMIN_USER=user
KC_ADMIN_PASSWORD=ADMIN123

kubectl create namespace keycloak
kubectl label namespace keycloak istio-injection=enabled

helm install auth oci://registry-1.docker.io/bitnamicharts/keycloak -n keycloak \
  --set auth.adminUser=${KC_ADMIN_USER} \
  --set auth.adminPassword=${KC_ADMIN_PASSWORD} \
  --set proxy=edge

# APISIX routes - Keycloak
#--------------------------------------------------------------
kubectl apply -n keycloak -f - <<EOF
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: keycloak1-route
spec:
  http:
  - name: keycloak1
    match:
      paths:
      - /
      - /admin/*
      - /resources/*
      - /realms/*
      - /welcome-content/*
    backends:
       - serviceName: auth-keycloak
         servicePort: 80
EOF

# APISIX routes - ECHO upstream
#--------------------------------------------------------------
kubectl apply -f - <<EOF
apiVersion: apisix.apache.org/v2
kind: ApisixUpstream
metadata:
  name: httpbin-upstream
spec:
  externalNodes:
  - type: Domain
    name: httpbin.org
EOF
kubectl apply -f - <<EOF
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: httpecho1-route
spec:
  http:
  - name: httpecho1
    match:
      paths:
      - /anything/echo
    upstreams:
    - name: httpbin-upstream
EOF

# APISIX routes - Authentication
#--------------------------------------------------------------
KC_URI=
KC_REALM=apisix
KC_CLIENT_ID=apisix1
KC_CLIENT_SECRET=
KC_DISCOVERY_ENDPOINT=${URI}/realms/apisix/.well-known/openid-configuration
KC_TOKEN_ENDPOINT=${URI}/realms/apisix/protocol/openid-connect/token
KC_INTRO_ENDPOINT=${URI}/realms/apisix/protocol/openid-connect/token/introspect
KC_LOGOUT=/auth/logout
KC_POST_LOGOUT=/anything/echo

kubectl apply -f - <<EOF
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: httpecho1-route-auth
spec:
  http:
  - name: httpecho1-auth
    match:
      paths:
      - /logout
      - /auth/logout
      - /anything/login
      - /anything/redirect_uri
      - /anything/info
    upstreams:
    - name: httpbin-upstream
    plugins:
    - name: openid-connect
      enable: true
      config:
        client_id: ${KC_CLIENT_ID}
        client_secret: ${KC_CLIENT_SECRET}
        discovery: ${KC_DISCOVERY_ENDPOINT}
        introspection_endpoint: ${KC_INTRO_ENDPOINT}
        token_endpoint: ${KC_TOKEN_ENDPOINT}
        realm: ${KC_REALM}
        unauth_action: "auth" # "deny" # "pass"
        set_access_token_header: false
        redirect_uri: /anything/redirect_uri
        logout_path: ${KC_LOGOUT}
        post_logout_redirect_uri: ${KC_POST_LOGOUT}
EOF

