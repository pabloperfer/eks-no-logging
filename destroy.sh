#!/bin/bash
set -ex
# Set the AWS region
region=us-east-1
org_unit_id=$1


# remove custom config rule
cd ..; yes |rdk deploy-organization eks-no-logging

cd eks-no-logging


# Check if the number of arguments is equal to 1
if [ "$#" -ne 1 ]; then
  # If not, print an error message and exit the script
  echo "Error: script expects one arguments, but $# were provided."
  echo "Usage: ./myscript.sh orgidunit"
  exit 1
fi

function describe_until_success {
  # Parse the JSON string using jq and store the result in a variable
  local stacksetname=$1
  local operationid=$2
  

  # Use a while loop to repeatedly execute the command and check the status
  while true; do

    local describe="$(aws cloudformation describe-stack-set-operation --call-as DELEGATED_ADMIN  --stack-set-name  $stacksetname --operation-id $operationid)" 
    local parsed_status=$(echo $describe | jq -r .StackSetOperation)
    # Extract the value of the "status" field using jq
    local status=$(jq -r '.Status' <<< "$parsed_status")

    # If the status is "SUCCEEDED" or "FAILED", exit the loop
    if [ "$status" = "SUCCEEDED" ]; then
      break
    elif [ "$status" = "FAILED" ]; then
      echo "error deleting the stack set instance  !!!!!!!!!!!!"
      break
    fi

    # Sleep for a short period of time before repeating the loop
    sleep 10
  done
}

function describe_until_success_stack {
  local stack_id=$1
  local stack_status=$(aws cloudformation describe-stacks --stack-name $1 --query 'Stacks[0].StackStatus' --output text)

  while true; do
    # Check if the stack was successfully created
    if [ $stack_status = "DELETE_COMPLETE" ]; then
      echo "Stack $stack_id was successfully deleted!"
      break
    elif [ $stack_status = "DELETE_FAILED" ]; then
      echo "Stack $stack_id failed to delete!"
      break
    else
    echo "Stack $stack_id is still being deleted. Current status: $stack_status"
    fi
    sleep 10
    stack_status=$(aws cloudformation describe-stacks --stack-name $stack_id --query 'Stacks[0].StackStatus' --output text)
  done
 }

#Delete SSM Automation Document 

json_string=$(aws cloudformation delete-stack --stack-name SSMAutomationEKSLog) || true
stack_id=$(echo $json_string | jq -r '.StackId')

#describe_until_success_stack $stack_id



# Get a list of stackset names
stacksets=$(aws cloudformation list-stack-sets --region $region --call-as DELEGATED_ADMIN --status=ACTIVE  --query 'Summaries[*].StackSetName' --output text)

# Delete each stackset
for stackset in $stacksets
do

  # Get a list of stack instances for the stackset
  stack_instances=$(aws cloudformation list-stack-instances --region $region --call-as DELEGATED_ADMIN  --stack-set-name $stackset --query 'Summaries[*].StackId' --output text)

  # Delete each stack instance
  for stack_instance in $stack_instances
  do
    # Delete the stack instance
   json_string=$(aws cloudformation delete-stack-instances --regions $region --call-as DELEGATED_ADMIN --deployment-targets OrganizationalUnitIds=$org_unit_id  --no-retain-stacks --stack-set-name $stackset)
   operation_id=$(echo $json_string | jq -r '.OperationId')

   describe_until_success $stackset $operation_id
 

    # Wait for the stack instance to be deleted

  done
    # Delete the stackset
  aws cloudformation delete-stack-set --region $region --call-as DELEGATED_ADMIN --stack-set-name $stackset

done
