#!/bin/bash

set -ex

while getopts v:a:j:o: flag
do
    case "${flag}" in
        v) version=${OPTARG};;
        j) json_file=${OPTARG};;
        o) operation=${OPTARG};;
        *) echo "ERROR: invalid parameter ${flag}" ;;
    esac
done

_get_cluster_id(){
#    echo $(rosa list clusters -o json | jq -r '.[] | select(.name == '\"$1\"') | .id')
  true
}

_download_kubeconfig(){
#    ocm get /api/clusters_mgmt/v1/clusters/$1/credentials | jq -r .kubeconfig > $2
  true
}

_get_cluster_status(){
  az aro list | jq -r '.[] | select(.name == '\"$1\"') | .provisioningState'
}

setup(){
    mkdir /home/airflow/workspace
    cd /home/airflow/workspace
    export PATH=$PATH:/usr/bin
    export HOME=/home/airflow
    echo ${ARO_MANAGED_SERVICES_TOKEN} | sed -e 's$\\n$\n$g' > ./PerfScaleManagedServices.pem
    export ARO_USERNAME=$(cat ${json_file} | jq -r .aro_username)
    export ARO_TENANT=$(cat ${json_file} | jq -r .aro_tenant)
    cat ./PerfScaleManagedServices.pem
    cat ${json_file} | jq -r .openshift_install_pull_secret > ./pullsecret.json
    cat ./pullsecret.json
    az login --service-principal -u ${ARO_USERNAME} -p ./PerfScaleManagedServices.pem --tenant ${ARO_TENANT}
    export CLUSTER_NAME=$(cat ${json_file} | jq -r .openshift_cluster_name)
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    az feature register --namespace Microsoft.RedHatOpenShift --name preview
    RESOURCEGROUP=aro-rg            # the name of the resource group where you want to create your cluster
}

install(){
    export COMPUTE_WORKERS_NUMBER=$(cat ${json_file} | jq -r .openshift_worker_count)
    export COMPUTE_WORKERS_TYPE=$(cat ${json_file} | jq -r .openshift_worker_instance_type)
    LOCATION=eastus                 # the location of your cluster
    az group create --name ${RESOURCEGROUP} --location ${LOCATION}
    az network vnet create --resource-group ${RESOURCEGROUP} --name aro-vnet --address-prefixes 10.0.0.0/22
    az network vnet subnet create --resource-group ${RESOURCEGROUP} --vnet-name aro-vnet --name master-subnet --address-prefixes 10.0.0.0/23 --service-endpoints Microsoft.ContainerRegistry
    az network vnet subnet create --resource-group ${RESOURCEGROUP} --vnet-name aro-vnet --name worker-subnet --address-prefixes 10.0.2.0/23 --service-endpoints Microsoft.ContainerRegistry
    az network vnet subnet update --name master-subnet --resource-group ${RESOURCEGROUP} --vnet-name aro-vnet --disable-private-link-service-network-policies true
    az aro create --resource-group ${RESOURCEGROUP} --name ${CLUSTER_NAME} --vnet aro-vnet --master-subnet master-subnet --worker-subnet worker-subnet --verbose
    postinstall
}

postinstall(){
    PASSWORD=$(az aro list-credentials --resource-group ${RESOURCEGROUP} --name ${CLUSTER_NAME} | jq -r .kubeadminPassword)
    API_URL=$(az aro list | jq -r '.[] | select(.name == '\"${CLUSTER_NAME}\"') | .apiserverProfile.url')
    kubectl delete secret ${KUBEADMIN_NAME} || true
    kubectl delete secret ${KUBECONFIG_NAME} || true
    kubectl create secret generic ${KUBEADMIN_NAME} --from-literal=KUBEADMIN_PASSWORD=${PASSWORD}
    export KUBECONFIG=kubeconfig
    oc login -u kubeadmin -p ${PASSWORD} ${API_URL} --insecure-skip-tls-verify
    ls
    unset KUBECONFIG
    kubectl create secret generic ${KUBECONFIG_NAME} --from-file=config=kubeconfig
}

cleanup(){
  az aro delete --name ${CLUSTER_NAME} --resource-group ${RESOURCEGROUP} -y
  true
}

cat ${json_file}

setup

if [[ "$operation" == "install" ]]; then
    printf "INFO: Checking if cluster is already installed"
    CLUSTER_STATUS=$(_get_cluster_status ${CLUSTER_NAME})
    if [ -z "${CLUSTER_STATUS}" ] ; then
        printf "INFO: Cluster not found, installing..."
        install
    elif [ "${CLUSTER_STATUS}" == "Succeeded" ] ; then
        printf "INFO: Cluster ${CLUSTER_NAME} already installed and ready, reusing..."
	postinstall
    else
        printf "INFO: Cluster ${CLUSTER_NAME} already installed but not ready, exiting..."
	exit 1
    fi

elif [[ "$operation" == "cleanup" ]]; then
    printf "Running Cleanup Steps"
    cleanup
fi
