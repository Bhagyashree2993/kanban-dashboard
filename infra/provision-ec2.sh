#!/usr/bin/env bash
# =============================================================================
# Optional: create the Security Group + EC2 instance with the AWS CLI.
# (You can do the same in the AWS Console — see README "AWS infrastructure".)
#
#   export AWS_REGION=ap-south-1
#   KEY_NAME=my-keypair bash infra/provision-ec2.sh
#
# Requires: aws CLI v2 configured with your own IAM credentials, an existing key pair.
# =============================================================================
set -Eeuo pipefail

REGION="${AWS_REGION:-ap-south-1}"
KEY_NAME="${KEY_NAME:?set KEY_NAME to an existing EC2 key pair name}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
NAME="${NAME:-kanban-cicd}"
MY_IP="${MY_IP:-$(curl -fsS https://checkip.amazonaws.com)/32}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# GitHub webhook source ranges ("hooks" in https://api.github.com/meta) — re-check before use
GITHUB_HOOK_CIDRS=(192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20)

AMI_ID=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${NAME}-sg" --description "kanban: SSH+Jenkins restricted, app public" \
  --query GroupId --output text)

# 22  SSH      -> your IP only
# 8080 Jenkins -> your IP + GitHub webhook ranges
# 80  App      -> everyone
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 22   --cidr "$MY_IP"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 8080 --cidr "$MY_IP"
for c in "${GITHUB_HOOK_CIDRS[@]}"; do
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 8080 --cidr "$c"
done
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0

INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3}' \
  --metadata-options 'HttpTokens=required' \
  --user-data "file://${SCRIPT_DIR}/ec2-setup.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<EOF
Instance : $INSTANCE_ID ($INSTANCE_TYPE, $AMI_ID)
SG       : $SG_ID   (22,8080 <- $MY_IP ; 8080 <- GitHub hooks ; 80 <- world)
Public IP: $PUBLIC_IP
Jenkins  : http://$PUBLIC_IP:8080   (bootstrap takes ~5 min; progress: sudo tail -f /var/log/cloud-init-output.log)
App      : http://$PUBLIC_IP        (after the first pipeline run)
SSH      : ssh -i <your-key>.pem ubuntu@$PUBLIC_IP
EOF
