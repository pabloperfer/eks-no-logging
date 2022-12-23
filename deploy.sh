#!/bin/bash
set -ex

#deploy custom config org rule
cd ..; yes |rdk deploy-organization eks-no-logging


cd eks-no-logging
# Check if the number of arguments is equal to 3
if [ "$#" -ne 3 ]; then
  # If not, print an error message and exit the script
  echo "Error: script expects 3 arguments, but $# were provided."
  echo "Usage: ./myscript.sh toolaccount  orgid orgidunit"
  exit 1
fi

#Account numbers where we deploy argoCD

tool_account=$1
org_id=$2
org_unit_id=$3


# prompting user
#read -p 'Tool Account Id: ' tool_account
#read -p 'Org Id: ' org_id
#read -p 'Org Unit Id: ' org_unit_id

#functions

function describe_until_success_stackset {
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
      echo "error in the stack set instance deployment!!!!!!!!!!!!"
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
    if [ $stack_status = "CREATE_COMPLETE" ]; then
      echo "Stack $stack_id was successfully created!"
      break
    elif [ $stack_status = "CREATE_FAILED" ]; then
      echo "Stack $stack_id failed to create!"
      break
    else
    echo "Stack $stack_id is still being created. Current status: $stack_status"
    fi
    sleep 10
    stack_status=$(aws cloudformation describe-stacks --stack-name $stack_id --query 'Stacks[0].StackStatus' --output text)
  done
 }

#Deploy AWS Config Role 

aws cloudformation create-stack-set --stack-set-name ConfigRoleStackSet --template-body file://IAMtemplates/AwsConfig/ConfigRecorderRole.yml  \
 --description "AWS Config Role" --capabilities CAPABILITY_NAMED_IAM --permission-model SERVICE_MANAGED  --call-as DELEGATED_ADMIN \
 --auto-deployment Enabled=False --parameters ParameterKey=OrgId,ParameterValue=$OrgId ParameterKey=OrgUnitId,ParameterValue=$org_unit_id \
ParameterKey=ToolAccountID,ParameterValue=$tool_account || true  

json_string=$(aws cloudformation create-stack-instances --stack-set-name ConfigRoleStackSet --deployment-targets OrganizationalUnitIds=$org_unit_id \
--regions us-east-1  --call-as DELEGATED_ADMIN --operation-preferences FailureToleranceCount=1,MaxConcurrentCount=2) || true

operation_id=$(echo $json_string | jq -r '.OperationId') 

describe_until_success_stackset ConfigRoleStackSet $operation_id

#Deploy AWS Config Recorder 
aws cloudformation create-stack-set --stack-set-name ConfigRecorderStackSet --template-body file://AWSConfig/ConfigRecorder.yaml \
 --description "AWS Config Recorder" --capabilities CAPABILITY_NAMED_IAM --permission-model SERVICE_MANAGED --call-as DELEGATED_ADMIN \
 --auto-deployment Enabled=False || true

json_string=$(aws cloudformation create-stack-instances --stack-set-name ConfigRecorderStackSet --deployment-targets OrganizationalUnitIds=$org_unit_id \
--regions us-east-1  --call-as DELEGATED_ADMIN --operation-preferences FailureToleranceCount=1,MaxConcurrentCount=2) || true

operation_id=$(echo $json_string | jq -r '.OperationId')

describe_until_success_stackset ConfigRecorderStackSet $operation_id

#Deploy SSM Automation Document 

json_string=$(aws cloudformation create-stack --stack-name SSMAutomationEKSLog --template-body file://SSM/eks-ssm-logging.yml \
 --capabilities CAPABILITY_NAMED_IAM \
 --parameters  ParameterKey=pOrganizationId,ParameterValue=$org_unit_id) || true


stack_id=$(echo $json_string | jq -r '.StackId')

describe_until_success_stack $stack_id

#Deploy AWS EventBridge layer

aws cloudformation create-stack-set --stack-set-name EventBridgeStackSet --template-body file://EventBridge/eks-nologging-eventbridge.yaml \
 --description "AWS EventBridge" --capabilities CAPABILITY_NAMED_IAM --permission-model SERVICE_MANAGED --call-as DELEGATED_ADMIN \
 --auto-deployment Enabled=False || true

json_string=$(aws cloudformation create-stack-instances --stack-set-name EventBridgeStackSet --deployment-targets OrganizationalUnitIds=$org_unit_id \
--regions us-east-1  --call-as DELEGATED_ADMIN --operation-preferences FailureToleranceCount=1,MaxConcurrentCount=2) || true

operation_id=$(echo $json_string | jq -r '.OperationId')

describe_until_success_stackset EventBridgeStackSet $operation_id


echo "all deployed correctly"
