#!/bin/bash

# Variables
RESOURCE_GROUP="cardev"
LOCATION="uksouth"
AKS_CLUSTER_NAME="cartest"
SSH_KEY_PATH="$HOME/.ssh/azure-wy-q.pub"
VNET_NAME="aks-vnet"
BASTION_SUBNET_NAME="AzureBastionSubnet"
BASTION_SUBNET_PREFIX="10.0.1.0/27"
BASTION_PIP_NAME="bastion-pip"
BASTION_HOST_NAME="myBastionHost"

echo "Creating AKS cluster..."
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --node-count 3 \
  --node-vm-size Standard_B2s \
  --ssh-key-value $SSH_KEY_PATH \
  --generate-ssh-keys false \
  --location $LOCATION

echo "Creating Bastion subnet..."
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $BASTION_SUBNET_NAME \
  --address-prefixes $BASTION_SUBNET_PREFIX

echo "Creating Bastion public IP..."
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name $BASTION_PIP_NAME \
  --sku Standard \
  --location $LOCATION

echo "Creating Bastion host..."
az network bastion create \
  --resource-group $RESOURCE_GROUP \
  --name $BASTION_HOST_NAME \
  --vnet-name $VNET_NAME \
  --public-ip-address $BASTION_PIP_NAME \
  --location $LOCATION

echo "All resources created."
