#Set basic configuration (example index and AWS account ID)
#(Can follow-up by copy-paste)
# Creates a KMS key named KeyForEBS-<n> (i.e. KeyForEBS-2)
#  and configure the key with a policy which allows the CSI
#  driver to access KMS when creating a new volume
# Creates a new storage class gp3-csi-custom-<n>, which uses 
#  the just created KeyForEBS-<n> as Master Key ID for 
#  volume encryption. 
# Creates a new PersistentVolumeClaim named pvc-gp3-custom-<n>
#  that uses the just created storage class. 
# Creates a sample pod which uses the just created PVC
# => outcome: Pod up and running and new volume of 4Gb 
#             created and encrypted with the new key. 
AWS_ACCOUNT_ID=<PUT HERE YOUR AWS ACCOUNT ID> 
AWS_REGION=<PUT HERE YOUR AWS REGION> 
INDEX=<INDEX NUMBER FOR TESTING PURPOSES>

#Create KMS key
KMS_KEY_ID=$( aws kms create-key | jq -r '.KeyMetadata.KeyId') 

#Assign Alias alias/KeyForEBS-(n)
KMS_ALIAS_NAME=KeyForEBS-${INDEX}
aws kms create-alias --alias-name alias/$KMS_ALIAS_NAME --target-key-id $KMS_KEY_ID

#Create basic policy
cat << EOF > kms-policy.json
{
    "Version": "2012-10-17",
    "Id": "key-consolepolicy-3",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow access through EBS for all principals in the account that are authorized to use EBS",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:CreateGrant",
                "kms:DescribeKey"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": "ec2.${AWS_REGION}.amazonaws.com",
                    "kms:CallerAccount": "${AWS_ACCOUNT_ID}"
                }
            }
        }
    ]
}
EOF

#Add policy for retrieving data 
aws kms put-key-policy --policy-name default --key-id $KMS_KEY_ID --policy file://kms-policy.json

#Retrieve ARN of KMS-Key
KMS_ARN=$(aws kms describe-key --key-id $KMS_KEY_ID | jq -r '.KeyMetadata.Arn')

#Create Storage class with just created Master Key
cat << EOF | oc create -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: gp3-csi-custom-${INDEX}
provisioner: ebs.csi.aws.com
parameters:
  encrypted: 'true'
  type: gp3
  kmsKeyId: ${KMS_ARN}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF

#Create Persistent Volume Claim leveraging the just created Storage Class
cat << EOF | oc create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-gp3-custom-${INDEX}
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  storageClassName: gp3-csi-custom-${INDEX}
  resources:
    requests:
      storage: 4Gi
EOF

#Create an example Pod that mounts a volume on the previous PVC
cat << EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: httpd-storage-custom-${INDEX}
spec:
  securityContext:
    fsGroup: 2000
  containers:
    - name: httpd
      image: quay.io/centos7/httpd-24-centos7
      ports:
        - containerPort: 80
      volumeMounts:
        - mountPath: /mnt/storage
          name: data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-gp3-custom-${INDEX}
EOF
