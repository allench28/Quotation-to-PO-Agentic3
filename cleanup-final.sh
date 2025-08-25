#!/bin/bash
set -e

echo "🧹 AI Quotation Processor - Cleanup Script"
echo "==========================================="

PROJECT_NAME="quotation-processor-final"
REGION="us-east-1"

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "⚠️  This will delete all resources created by the deployment script."
echo "Are you sure you want to continue? (y/N)"
read -n 1 confirmation
echo ""

if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo "🗑️  Starting cleanup process..."

# 1. Delete Lambda Function
echo "Deleting Lambda function..."
aws lambda delete-function \
    --function-name ${PROJECT_NAME}-processor \
    --region $REGION 2>/dev/null || echo "Lambda function not found or already deleted"

# 2. Delete Lambda Layer
echo "Deleting Lambda layer..."
LAYER_VERSIONS=$(aws lambda list-layer-versions \
    --layer-name ${PROJECT_NAME}-pdf-layer \
    --region $REGION \
    --query "LayerVersions[].Version" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$LAYER_VERSIONS" ]; then
    for version in $LAYER_VERSIONS; do
        aws lambda delete-layer-version \
            --layer-name ${PROJECT_NAME}-pdf-layer \
            --version-number $version \
            --region $REGION 2>/dev/null || true
    done
fi

# 3. Delete API Gateway
echo "Deleting API Gateway..."
API_IDS=$(aws apigateway get-rest-apis \
    --region $REGION \
    --query "items[?name=='${PROJECT_NAME}-api'].id" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$API_IDS" ]; then
    for api_id in $API_IDS; do
        aws apigateway delete-rest-api \
            --rest-api-id $api_id \
            --region $REGION 2>/dev/null || true
    done
fi

# 4. Clean up and delete S3 buckets
echo "Cleaning up S3 buckets..."
BUCKETS=$(aws s3api list-buckets \
    --query "Buckets[?starts_with(Name, '${PROJECT_NAME}')].Name" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$BUCKETS" ]; then
    for bucket in $BUCKETS; do
        echo "Emptying bucket: $bucket"
        aws s3 rm s3://$bucket --recursive 2>/dev/null || true
        echo "Deleting bucket: $bucket"
        aws s3 rb s3://$bucket 2>/dev/null || true
    done
fi

# 5. Disable CloudFront distributions (don't delete, just disable)
echo "Disabling CloudFront distributions..."
DISTRIBUTIONS=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${PROJECT_NAME} frontend'].Id" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$DISTRIBUTIONS" ]; then
    for dist_id in $DISTRIBUTIONS; do
        echo "Disabling CloudFront distribution: $dist_id"
        # Get current config
        ETAG=$(aws cloudfront get-distribution-config \
            --id $dist_id \
            --query "ETag" \
            --output text 2>/dev/null || echo "")
        
        if [ ! -z "$ETAG" ]; then
            # Get config and disable
            aws cloudfront get-distribution-config \
                --id $dist_id \
                --query "DistributionConfig" > /tmp/dist-config.json 2>/dev/null || true
            
            # Update enabled to false
            if [ -f /tmp/dist-config.json ]; then
                sed -i.bak 's/"Enabled": true/"Enabled": false/g' /tmp/dist-config.json
                aws cloudfront update-distribution \
                    --id $dist_id \
                    --distribution-config file:///tmp/dist-config.json \
                    --if-match $ETAG 2>/dev/null || true
                rm -f /tmp/dist-config.json /tmp/dist-config.json.bak
            fi
        fi
    done
fi

# 6. Delete DynamoDB table
echo "Deleting DynamoDB table..."
aws dynamodb delete-table \
    --table-name ${PROJECT_NAME}-quotations \
    --region $REGION 2>/dev/null || echo "DynamoDB table not found or already deleted"

# 7. Delete IAM role and policies
echo "Deleting IAM role and policies..."
aws iam delete-role-policy \
    --role-name ${PROJECT_NAME}-role \
    --policy-name ${PROJECT_NAME}-policy 2>/dev/null || true

aws iam delete-role \
    --role-name ${PROJECT_NAME}-role 2>/dev/null || echo "IAM role not found or already deleted"

echo ""
echo "🎉 Cleanup completed!"
echo "====================="
echo "✅ Lambda function deleted"
echo "✅ Lambda layer deleted"
echo "✅ API Gateway deleted"
echo "✅ S3 buckets emptied and deleted"
echo "⚠️  CloudFront distributions disabled (not deleted)"
echo "✅ DynamoDB table deleted"
echo "✅ IAM role and policies deleted"
echo ""
echo "Note: CloudFront distributions have been disabled but not deleted."
echo "You can manually delete them from the AWS Console if needed."