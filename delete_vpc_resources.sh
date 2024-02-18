#!/bin/bash

set -e

function print_usage_and_exit {
    echo "Usage   : $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Display this message."
    echo "  --region             AWS Region (eg. us-east-1)"
    echo "  --non-interactive    Run with no interactive"
    echo "  --list-vpc           List all VPCs in the specific region"
    echo "Example:"
    echo "    $0 --region us-east-1 --non-interactive"
    echo "    $0 --region us-east-1 --list-vpc"
    exit $1
}

function list_vpc {
    if [ -z "$1" ]; then
        echo "AWS region is required."
        exit 1
    fi
    aws ec2 describe-vpcs \
        --query 'Vpcs[].{vpcid:VpcId,name:Tags[?Key==`Name`].Value[]}' \
        --region "$1" \
        --output table
}

if ! command -v aws &>/dev/null; then
    echo "awscli is not installed. Please install it and re-run this script."
    exit 1
fi

if [ "$#" -eq 0 ]; then
   print_usage_and_exit 1
fi

AWS_REGION="us-west-2"
NON_INTERACTIVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --list-vpc)
            list_vpc "$AWS_REGION"
            exit 0
            ;;
        -h | --help)
            print_usage_and_exit 0
            ;;
        *)
            print_usage_and_exit 1
            ;;
    esac
done

# Get list of all VPC IDs in the specified region
VPC_IDS=$(aws ec2 describe-vpcs --region "${AWS_REGION}" --query 'Vpcs[*].VpcId' --output text)

for VPC_ID in $VPC_IDS; do
    echo "Processing VPC: ${VPC_ID}"

# Check VPC status, available or not
state=$(aws ec2 describe-vpcs \
    --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[].State' \
    --region "${AWS_REGION}" \
    --output text)

if [ "${state}" != 'available' ]; then
    echo "The VPC of ${VPC_ID} is NOT available now!"
    exit 1
fi

if [ ${NON_INTERACTIVE} -eq 0 ]  ;then
  echo -n "*** Are you sure to delete the VPC of ${VPC_ID} in ${AWS_REGION} (y/n)? "
  read answer
  if [ "$answer" != "${answer#[Nn]}" ] ;then
      exit 1
  fi
fi

# Delete NAT Gateways
echo "Process of NAT Gateways ..."
all_nat_gateways=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=${VPC_ID}" \
        --query 'NatGateways[*].{NatGatewayId:NatGatewayId}' \
        --region "${AWS_REGION}" \
        --output text)

for ngw in ${all_nat_gateways}; do
    echo "    Deleting NAT Gateway: ${ngw}"
    
    # Delete the NAT Gateway
    aws ec2 delete-nat-gateway \
        --nat-gateway-id "${ngw}" \
        --region "${AWS_REGION}"

    # Wait for the NAT Gateway to be deleted
    echo "    Waiting for NAT Gateway ${ngw} to be deleted..."
    while : ; do
        ngw_status=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids "${ngw}" \
            --region "${AWS_REGION}" \
            --query 'NatGateways[*].{State:State}' \
            --output text)
        
        if [[ "$ngw_status" == "deleted" ]]; then
            break
        fi
        echo "    Waiting..."
        sleep 10
    done
done

# Delete ENIs
echo "Process of ENIs ..."
all_enis=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'NetworkInterfaces[*].{NetworkInterfaceId:NetworkInterfaceId}' \
        --region "${AWS_REGION}" \
        --output text)

for eni in ${all_enis}; do
    echo "Processing ENI: ${eni}"

    # Check if the ENI is attached
    attachment=$(aws ec2 describe-network-interfaces \
        --network-interface-ids "${eni}" \
        --query 'NetworkInterfaces[*].Attachment.AttachmentId' \
        --region "${AWS_REGION}" \
        --output text)

    if [ -n "${attachment}" ]; then
        echo "    Attempting to detach ENI: ${eni}"
        if aws ec2 detach-network-interface \
            --attachment-id "${attachment}" \
            --region "${AWS_REGION}" \
            --force 2>/dev/null; then
            echo "    Waiting for ENI ${eni} to be detached..."
            aws ec2 wait network-interface-available \
                --network-interface-ids "${eni}" \
                --region "${AWS_REGION}"
        else
            echo "    Unable to detach ENI (may be managed by AWS). Skipping..."
            continue
        fi
    fi

    echo "    Attempting to delete ENI: ${eni}"
    if ! aws ec2 delete-network-interface \
        --network-interface-id "${eni}" \
        --region "${AWS_REGION}" 2>/dev/null; then
        echo "    Failed to delete ENI ${eni}. It might still be in use or managed by AWS."
    else
        echo "    ENI ${eni} deleted successfully."
    fi
done




# Delete ELB
echo "Process of ELB ..."
all_elbs=$(aws elbv2 describe-load-balancers \
        --query 'LoadBalancers[*].{ARN:LoadBalancerArn,VPCID:VpcId}' \
        --region "${AWS_REGION}" \
        --output text \
        | grep "${VPC_ID}" \
        | xargs -n1 | sed -n 'p;n')

for elb in ${all_elbs}; do
    # get all listenners under the elb
    listeners=$(aws elbv2 describe-listeners \
        --load-balancer-arn "${elb}" \
        --query 'Listeners[].{ARN:ListenerArn}' \
        --region "${AWS_REGION}" \
        --output text)

    for lis in ${listeners}; do
        echo "    delete listenner of ${lis}"
        aws elbv2 delete-listener \
            --listener-arn "${lis}" \
            --region "${AWS_REGION}" \
            --output text
    done

    echo "    delete elb of ${elb}"
    aws elbv2 delete-load-balancer \
        --load-balancer-arn "${elb}" \
        --region "${AWS_REGION}" \
        --output text
done

# Get all of target-group under the VPC
all_target_groups=$(aws elbv2 describe-target-groups \
    --query 'TargetGroups[].{ARN:TargetGroupArn,VPC:VpcId}' \
    --region "${AWS_REGION}" \
    --output text \
    | grep "${VPC_ID}" \
    | xargs -n1 | sed -n 'p;n')

for tg in ${all_target_groups}; do
    echo "    delete target group of ${tg}"
    aws elbv2 delete-target-group \
        --target-group-arn "${tg}" \
        --region "${AWS_REGION}" \
        --output text
done

# Stop EC2 instance
echo "Process of EC2 instance(s) ..."
for instance in $(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --region "${AWS_REGION}" \
    --output text)
do

    echo "    enable api to stop of ${instance}"
    aws ec2 modify-instance-attribute \
        --no-disable-api-stop \
        --instance-id "${instance}" \
        --region "${AWS_REGION}" > /dev/null

    echo "    stop instance of ${instance}"
    aws ec2 stop-instances \
        --instance-ids "${instance}" \
        --region "${AWS_REGION}" > /dev/null

    # Wait until instance stopped
    echo "    wait until instance stopped"
    aws ec2 wait instance-stopped \
        --instance-ids "${instance}" \
        --region "${AWS_REGION}"
done

# Terminate instance
for instance in $(aws ec2 describe-instances \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'Reservations[].Instances[].InstanceId' \
    --region "${AWS_REGION}" \
    --output text)
do

        echo "    enable api termination of ${instance}"
    aws ec2 modify-instance-attribute \
        --no-disable-api-termination \
        --instance-id "${instance}" \
        --region "${AWS_REGION}" > /dev/null

    echo "    terminate instance of ${instance}"
    aws ec2 terminate-instances \
        --instance-ids "${instance}" \
        --region "${AWS_REGION}" > /dev/null

    # Wait until instance terminated
    echo "    wait until instance terminated"
    aws ec2 wait instance-terminated \
        --instance-ids "${instance}" \
        --region "${AWS_REGION}"
done

# Delete NAT Gateway
echo "Process of NAT Gateway ..."
for natgateway in $(aws ec2 describe-nat-gateways \
    --filter 'Name=vpc-id,Values='${VPC_ID} \
    --query 'NatGateways[].NatGatewayId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    delete NAT Gateway of ${natgateway}"
    aws ec2 delete-nat-gateway \
        --nat-gateway-id "${natgateway}" \
        --region "${AWS_REGION}" > /dev/null
done

echo "    waiting for state of deleted"
while :
do
    state=$(aws ec2 describe-nat-gateways \
        --filter 'Name=vpc-id,Values='${VPC_ID} \
                 'Name=state,Values=pending,available,deleting' \
        --query 'NatGateways[].State' \
        --region "${AWS_REGION}" \
        --output text)
    if [ -z "${state}" ]; then
        break
    fi
    sleep 3
done

if [[ ! " ${CHINA_REGION[@]} " =~ " ${AWS_REGION} " ]]; then
    # Delete VPN connection
    echo "Process of VPN connection ..."
    for vpn in $(aws ec2 describe-vpn-connections \
        --filters 'Name=vpc-id,Values='${VPC_ID} \
        --query 'VpnConnections[].VpnConnectionId' \
        --region "${AWS_REGION}" \
        --output text)
    do
        echo "    delete VPN Connection of ${vpn}"
        aws ec2 delete-vpn-connection \
            --vpn-connection-id "${vpn}" \
            --region "${AWS_REGION}" > /dev/null
        # Wait until deleted
        echo "    wait until deleted"
        aws ec2 wait vpn-connection-deleted \
            --vpn-connection-ids "${vpn}" \
            --region "${AWS_REGION}"
    done

    # Delete VPN Gateway
    echo "Process of VPN Gateway ..."
    for vpngateway in $(aws ec2 describe-vpn-gateways \
        --filters 'Name=attachment.vpc-id,Values='${VPC_ID} \
        --query 'VpnGateways[].VpnGatewayId' \
        --region "${AWS_REGION}" \
        --output text)
    do
        echo "    delete VPN Gateway of $vpngateway"
        aws ec2 delete-vpn-gateway \
            --vpn-gateway-id "${vpngateway}" \
            --region "${AWS_REGION}" > /dev/null
    done
fi

# Delete VPC Peering
echo "Process of VPC Peering ..."
for peering in $(aws ec2 describe-vpc-peering-connections \
    --filters 'Name=requester-vpc-info.vpc-id,Values='${VPC_ID} \
    --query 'VpcPeeringConnections[].VpcPeeringConnectionId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    delete VPC Peering of $peering"
    aws ec2 delete-vpc-peering-connection \
        --vpc-peering-connection-id "${peering}" \
        --region "${AWS_REGION}" > /dev/null

    # Wait until deleted
    echo "    wait until deleted"
    aws ec2 wait vpc-peering-connection-deleted \
        --vpc-peering-connection-ids "${peering}" \
        --region "${AWS_REGION}"
done

# Delete Endpoints
echo "Process of VPC endpoints ..."
for endpoints in $(aws ec2 describe-vpc-endpoints \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'VpcEndpoints[].VpcEndpointId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    delete endpoint of $endpoints"
    aws ec2 delete-vpc-endpoints \
        --vpc-endpoint-ids "${endpoints}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete Egress Only Internet Gateway
echo "Process of Egress Only Internet Gateway ..."
for egress in $(aws ec2 describe-egress-only-internet-gateways \
    --filters 'Name=attachment.vpc-id,Values='${VPC_ID} \
    --query 'EgressOnlyInternetGateways[].EgressOnlyInternetGatewayId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    delete Egress Only Internet Gateway of $egress"
    aws ec2 delete-egress-only-internet-gateway \
        --egress-only-internet-gateway-id "${egress}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete ACLs
echo "Process of Network ACLs ..."
for acl in $(aws ec2 describe-network-acls \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'NetworkAcls[].NetworkAclId' \
    --region "${AWS_REGION}" \
    --output text)
do
    # Check it's default acl
    acl_default=$(aws ec2 describe-network-acls \
        --network-acl-ids "${acl}" \
        --query 'NetworkAcls[].IsDefault' \
        --region "${AWS_REGION}" \
        --output text)

    # Ignore default acl
    if [ "$acl_default" = 'true' ] || [ "$acl_default" = 'True' ]; then
        continue
    fi

    echo "    delete ACL of ${acl}"
    aws ec2 delete-network-acl \
        --network-acl-id "${acl}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete EIP
echo "Process of Elastic IP ..."
for associationid in $(aws ec2 describe-network-interfaces \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'NetworkInterfaces[].Association[].AssociationId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    disassociate EIP association-id of ${associationid}"
    aws ec2 disassociate-address \
        --association-id "${associationid}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete NIC
echo "Process of Network Interface ..."
for nic in $(aws ec2 describe-network-interfaces \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    detach Network Interface of $nic"
    attachment=$(aws ec2 describe-network-interfaces \
        --filters 'Name=vpc-id,Values='${VPC_ID} \
                  'Name=network-interface-id,Values='${nic} \
        --query 'NetworkInterfaces[].Attachment.AttachmentId' \
        --region "${AWS_REGION}" \
        --output text)

    if [ ! -z ${attachment} ]; then
        echo "    network attachment is ${attachment}"
        aws ec2 detach-network-interface \
            --attachment-id "${attachment}" \
            --region "${AWS_REGION}" >/dev/null

        # we need a waiter here
        sleep 3
    fi

    echo "    delete Network Interface of ${nic}"
    aws ec2 delete-network-interface \
        --network-interface-id "${nic}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete Security Group(s) IpPermissions
sgs=$(aws ec2 describe-security-groups \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'SecurityGroups[].GroupId' \
    --region "${AWS_REGION}" \
    --output text)

echo "Delete Security Group(s) IpPermissions ..."
for sg in ${sgs} ; do
    # Check it's default security group
    sg_name=$(aws ec2 describe-security-groups \
        --group-ids "${sg}" \
        --query 'SecurityGroups[].GroupName' \
        --region "${AWS_REGION}" \
        --output text)
    # Ignore default security group
    if [ "$sg_name" = 'default' ] || [ "$sg_name" = 'Default' ]; then
        continue
    fi

    for type in "in" "e" ; do
        IP_PERMISSION_TYPE=""
        if [ "${type}" == "in" ]; then
            IP_PERMISSION_TYPE='SecurityGroups[].IpPermissions[]'
            echo "    delete IpPermissions of Security group of ${sg}"
        else
            IP_PERMISSION_TYPE='SecurityGroups[].IpPermissionsEgress[]'
            echo "    delete IpPermissionsEgress of Security groups of ${sg}"
        fi

        IP_PERMISSION=$(aws ec2 describe-security-groups \
            --group-ids "${sg}" \
            --query "${IP_PERMISSION_TYPE}" \
            --region "${AWS_REGION}" \
            --output json)

        if [[ -z "${IP_PERMISSION}" ]] || [[ "${IP_PERMISSION}" == '[]' ]]; then
            echo "    going forward..."
            continue
        fi
        echo "    revoke sg's ${type}gress"
        aws ec2 revoke-security-group-${type}gress \
            --group-id "${sg}" \
            --ip-permissions "${IP_PERMISSION}" \
            --region "${AWS_REGION}" >/dev/null
    done
done

# Delete Security Group(s)
echo "Process of Security Group ..."
for sg in ${sgs}; do
    # Check it's default security group
    sg_name=$(aws ec2 describe-security-groups \
        --group-ids "${sg}" \
        --query 'SecurityGroups[].GroupName' \
        --region "${AWS_REGION}" \
        --output text)
    # Ignore default security group
    if [ "$sg_name" = 'default' ] || [ "$sg_name" = 'Default' ]; then
        continue
    fi

    echo "    delete Security group of ${sg}"
    aws ec2 delete-security-group \
        --region "${AWS_REGION}" \
        --group-id "${sg}" >/dev/null
done

# Delete IGW(s)
echo "Process of Internet Gateway ..."
for igw in $(aws ec2 describe-internet-gateways \
    --filters 'Name=attachment.vpc-id,Values='${VPC_ID} \
    --query 'InternetGateways[].InternetGatewayId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    detach IGW of $igw"
    aws ec2 detach-internet-gateway \
        --internet-gateway-id "${igw}" \
        --vpc-id "${VPC_ID}" \
        --region "${AWS_REGION}" > /dev/null

    # we need a waiter here
    sleep 3

    echo "    delete IGW of ${igw}"
    aws ec2 delete-internet-gateway \
        --internet-gateway-id "${igw}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete Subnet(s)
echo "Process of Subnet ..."
for subnet in $(aws ec2 describe-subnets \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'Subnets[].SubnetId' \
    --region "${AWS_REGION}" \
    --output text)
do
    echo "    delete Subnet of $subnet"
    aws ec2 delete-subnet \
        --subnet-id "${subnet}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete Route Table
echo "Process of Route Table ..."
for routetable in $(aws ec2 describe-route-tables \
    --filters 'Name=vpc-id,Values='${VPC_ID} \
    --query 'RouteTables[].RouteTableId' \
    --region "${AWS_REGION}" \
    --output text)
do
    # Check it's main route table
    main_table=$(aws ec2 describe-route-tables \
        --route-table-ids "${routetable}" \
        --query 'RouteTables[].Associations[].Main' \
        --region "${AWS_REGION}" \
        --output text)

    # Ignore main route table
    if [ "$main_table" = 'True' ] || [ "$main_table" = 'true' ]; then
        continue
    fi

    echo "    delete Route Table of ${routetable}"
    aws ec2 delete-route-table \
        --route-table-id "${routetable}" \
        --region "${AWS_REGION}" > /dev/null
done

# Delete VPC
echo -n "Finally, delete the VPC of ${VPC_ID}"
aws ec2 delete-vpc \
    --vpc-id "${VPC_ID}" \
    --region "${AWS_REGION}" \
    --output text

echo ""
echo "Done."
done