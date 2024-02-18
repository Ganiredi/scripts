#!/bin/bash

# List stacks that start with 'cluster'
stacks=$(aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName, 'eks')].StackName" --output text)

# Check if there are any stacks to delete
if [[ -z "$stacks" ]]; then
    echo "No stacks found starting with 'cluster'"
    exit 0
fi

# Delete the stacks
for stack in $stacks; do
    echo "Deleting stack $stack"
    aws cloudformation delete-stack --stack-name $stack
done

echo "Deletion initiated for all specified stacks."
