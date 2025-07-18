#!/bin/bash

# Variables
RESOURCE_GROUP="cardev"
AKS_CLUSTER_NAME="cartest"
VNET_NAME="aks-vnet"
BASTION_SUBNET_NAME="AzureBastionSubnet"
BASTION_PIP_NAME="bastion-pip"
BASTION_HOST_NAME="myBastionHost"

echo "Deleting AKS cluster..."
az aks delete --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --yes --no-wait

echo "Deleting Bastion host..."
az network bastion delete --resource-group $RESOURCE_GROUP --name $BASTION_HOST_NAME

echo "Deleting Bastion public IP..."
az network public-ip delete --resource-group $RESOURCE_GROUP --name $BASTION_PIP_NAME

echo "Deleting Bastion subnet..."
az network vnet subnet delete --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --name $BASTION_SUBNET_NAME

echo "All resources deletion initiated."
