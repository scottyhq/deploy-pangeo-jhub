# deploy-pangeo-jhub
One-stop shop for deploying a [Pangeo JupyterHub](https://pangeo.io/architecture.html) on AWS. This repository uses `snakemake` to configure and deploy computing resources on AWS. Following the steps in the README you should have a hub up and running in ~ 30 minutes. Inspired by https://github.com/dask/dask-tutorial-infrastructure. Note that are many alternative approaches to deployment. I was inspired to learn snakemake...

In more detail running the following code will
  - create an [EKS Kubernetes Cluster](https://aws.amazon.com/eks/)
  - create an [EFS drive](https://aws.amazon.com/efs/) for network file system persistent home storage
  - create a multiuser Pangeo JupyterHub
      - use [Pangeo Stacks](https://github.com/pangeo-data/pangeo-stacks) images by default
  - (optionally) tear everything down

## Pre-requisites
  * [AWS Account](https://aws.amazon.com/premiumsupport/knowledge-center/create-and-activate-aws-account/)
  * [conda](https://docs.conda.io/en/latest/miniconda.html)
  * [eksctl](https://github.com/weaveworks/eksctl)
  * [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
  * [helm](https://github.com/helm/helm/blob/master/docs/install.md)

** NOTE: tested with conda=4.7.12 eksctl=0.6.0, kubectl=1.16.0, helm=2.14.2 **

## 1) clone this repository
```
git clone https://github.com/scottyhq/deploy-pangeo-jhub
cd deploy-pangeo-jhub
```

## 2) create a snakemake conda environment
```
conda env create -f environment.yml
conda activate pangeo-deploy
```
** If you don't already have conda installed, you'll have to download and run `wget https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh; bash Miniconda3-latest-Linux-x86_64.sh`


## 3) edit config.yml with your own values (see bottom of this README for FAQs on filling out values)
```
aws:
  accountNumber: XXXXXXX
  accountProfile: uw
  user: pangeo-admin

eksctl:
  kubernetesVersion: 1.13
  autoscalerVersion: 1.13.7
  clusterName: pangeo
  region: us-west-2
  sshPublicKey: keys/pangeo.pub
  s3Arn: arn:aws:iam::aws:policy/AmazonS3FullAccess

jupyterhub:
  namespace: pangeo
  secretToken: XXXXXXXXX

pangeo:
  version: 19.09.26-dd6574b
```

## 4) create an IAM user for cluster management
```
snakemake iam
```
Note: this isn't necessary if you identified an existing admin user in config.yml.
If you do run this step you will have to log onto the AWS console, generate
access keys and enter them into the terminal along with your cluster region
and set the default output format to `json`.

## 5) create all AWS resources and deploy pangeo jupyterhub
```
snakemake pangeo
```
Note: it typically takes 10+ minutes to create a new EKS cluster. Be patient.

## 6) Tear it down if you're done
```
snakemake delete_cluster
```
Note: this can take several minutes. Double check everything deleted successfully
by looking at the cluster stack in the AWS CloudFormation console.


### FAQs

? How to create a new ssh private and public key pair?
```
KEY_NAME=my-key
aws ec2 create-key-pair --key-name ${KEY_NAME} | jq -r ".KeyMaterial" > ${KEY_NAME}.pem
chmod 400 ${KEY_NAME}.pem
ssh-keygen -y -f ${KEY_NAME}.pem > ${KEY_NAME}.pub
```

? Cluster failed creating in us-east-1:
```
[✖]  AWS::EKS::Cluster/ControlPlane: CREATE_FAILED – "Cannot create cluster 'pangeo-cluster' because us-east-1e, the targeted availability zone, does not currently have sufficient capacity to support the cluster. Retry and choose from these availability zones: us-east-1a, us-east-1b, us-east-1c, us-east-1d, us-east-1f (Service: AmazonEKS; Status Code: 400; Error Code: UnsupportedAvailabilityZoneException; Request ID: 318be6e1-720f-4123-b548-632ce3cef73f)"
```
run `eksctl delete cluster` and try again

? I have multiple kubernetes contexts, how to do I switch between them
```
alias kube-pangeo='export AWS_DEFAULT_PROFILE=pangeo-admin && aws eks --region us-west-2 update-kubeconfig --name pangeo'
```
