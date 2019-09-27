configfile: "config.yml"


rule all:
    input: 'deployment/jupyterhub-config.yml'
    shell: "echo 'Congratulations! Everything deployed' "


rule iam:
    """
    Create IAM user with permissions to administer cluster
    """
    input:
        template='templates/eksctl-permissions.json'
    output:
        config='deployment/eksctl-permissions.json',
    log:
        file='deployment/iam.log'
    params:
        account=config['aws']['accountNumber'],
        profile=config['aws']['accountProfile'],
        user=config['aws']['user'],
        region=config['eksctl']['region']
    shell:
        """
        set -ex
        sed -e 's/CHANGE_ACCOUNT_NUMBER/{params.account}/g' {input.template} > {output.config}
        aws --profile {params.profile} iam create-user --user-name {params.user} >> {log.file}
        aws --profile {params.profile} iam create-policy --policy-name eksctl-permissions --policy-document file://{output.config} >> {log.file}
        aws --profile {params.profile} iam attach-user-policy --policy-arn arn:aws:iam::{params.account}:policy/eksctl-permissions --user-name {params.user} >> {log.file}
        echo "IMPORTANT! you muse manually configure your aws cli profile:"
        aws --profile {params.user} configure
        """


rule cluster:
    """
    Create EKS Kubernetes Cluster
    """
    input:
        template='templates/eksctl-config.yml',
    output:
        config='deployment/eksctl-config.yml',
        result='deployment/cluster-deployed'
    log:
        file='deployment/cluster.log'
    params:
        clusterName=config['eksctl']['clusterName'],
        profile=config['aws']['user']
    shell:
        """
        set -ex
        ./fill-template.py {input.template} {output.config}
        eksctl --profile {params.profile} create cluster --config-file={output.config} > {log.file}
        touch {output.result}
        """

rule autoscaler:
    """
    Deploy kubernetes autoscaler to EKS cluster
    """
    input:
        runAfter='deployment/cluster-deployed',
        template='templates/k8s-autoscaler-config.yml'
    output:
        config='deployment/autoscaler-config.yml',
    log:
        file='deployment/autoscaler.log'
    shell:
        """
        set -ex
        ./fill-template.py {input.template} {output.config}
        kubectl apply -f {output.config} > {log.file}
        """

rule efs:
    """
    Create EFS Drive that is accessibly from Kubernetes Cluster
    """
    input:
        runAfter='deployment/autoscaler-config.yml',
        template='templates/nfs-config.yml'
    output:
        config='deployment/nfs-config.yml',
        result='deployment/efs-deployed'
    log: 'deployment/efs.log'
    params:
        clusterName=config['eksctl']['clusterName'],
        region=config['eksctl']['region'],
        profile=config['aws']['user']

    shell:
        """
        set -ex
        VPC=$(aws --profile {params.profile} eks describe-cluster --name {params.clusterName} | jq -r ".cluster.resourcesVpcConfig.vpcId")
        SUBNETS_PUBLIC=($(aws --profile {params.profile} ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=*PublicRouteTable*" | jq -r ".RouteTables[].Associations[].SubnetId"))
        SG_NODES_SHARED=$(aws --profile {params.profile} ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=*ClusterSharedNodeSecurityGroup*" | jq -r ".SecurityGroups[].GroupId")

        EFSID=$(aws --profile {params.profile} efs create-file-system --creation-token newefs --tags "Key=Name,Value={params.clusterName}" | jq -r ".FileSystemId")
        sleep 5s # Wait for EFS "available state"
        for i in "${{SUBNETS_PUBLIC[@]}}"
        do
        	aws --profile {params.profile} efs create-mount-target --file-system-id $EFSID --subnet-id $i --security-groups $SG_NODES_SHARED >> {log}
        done

        # Hack to get efsurl into config
        EFSURL=$EFSID.efs.{params.region}.amazonaws.com
        printf "\nefs:\n  url: $EFSURL\n" >> config.yml
        ./fill-template.py {input.template} {output.config}
        touch {output.result}
        """

rule helm:
    """
    Deploy helm/tiller to administer EKS cluster
    """
    input: 'deployment/efs-deployed'
    output: 'deployment/helm-deployed'
    log: 'deployment/helm.log'
	shell:
	    """
        set -ex
		kubectl --namespace kube-system create sa tiller >> {log}
		kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller  >> {log}
		helm init --service-account tiller >> {log}
		kubectl --namespace=kube-system patch deployment tiller-deploy --type=json --patch='[{{"op": "add", "path": "/spec/template/spec/containers/0/command", "value": ["/tiller", "--listen=localhost:44134"]}}]'  >> {log}
        sleep 10s # wait for tiller pod to initialize
        helm version >> {log}
        touch {output}
	    """

rule pangeo:
    """
    Initial deployment of JupyterHub on EKS cluster using latest pangeo helm chart
    """
    input:
        runAfter='deployment/helm-deployed',
        nfsConfig='deployment/nfs-config.yml',
        jhubConfig='templates/jupyterhub-config.yml',
        secretConfig='templates/secret-config.yml'
    output:
        jhub='deployment/jupyterhub-config.yml',
        secret='deployment/secret-config.yml'
    log:
        file='deployment/jupyterhub.log'
    params:
        namespace=config['jupyterhub']['namespace'],
        pangeoVersion=config['pangeo']['version']
    shell:
        """
        set -ex
        ./fill-template.py {input.jhubConfig} {output.jhub}
        ./fill-template.py {input.secretConfig} {output.secret}
        helm repo add jupyterhub https://jupyterhub.github.io/helm-chart/
        helm repo add pangeo https://pangeo-data.github.io/helm-chart/
        helm repo update
        helm install pangeo/pangeo \
            --version={params.pangeoVersion} \
            --namespace={params.namespace} \
        	--name={params.namespace} \
        	-f {output.jhub} \
            -f {output.secret} \
            > {log.file}
        kubectl apply -f {input.nfsConfig} >> {log}
        kubctl get svc proxy-public -n {params.namespace}
        """

rule upgrade:
    """
    Upgrade deployment with any changes to config files
    """
    params:
        namespace=config['jupyterhub']['namespace'],
        pangeoVersion=config['pangeo']['version'],
        jhub='deployment/jupyterhub-config.yml',
        secret='deployment/secret-config.yml'
    log: 'deployment/helm-upgrade.log'
    shell:
        """
        set -ex
    	helm upgrade --wait --install \
            {params.namespace} \
            pangeo/pangeo \
            --version={params.pangeoVersion} \
        	-f {params.jhub} \
            -f {params.secret} \
            >> {log}
        """


rule delete_jhub:
    """
    Delete jupyterhub deployment to start fresh
    """
    params:
        namespace=config['jupyterhub']['namespace']
    log: 'deployment/delete-jhub.log'
    shell:
        """
        set -ex
        echo "!! deleting jupyterhub only. will not delete EFS or EKS cluster !!"
    	helm delete {params.namespace} --purge >> {log}
    	kubectl delete namespace {params.namespace} >> {log}
        """


rule delete_efs:
    """
    Warning! Deletes EFS drive. mount targets need deleting before cluster deletion.
    """
    params:
        profile=config['aws']['user'],
        efsid=config['efs']['url'][:11]
    log: 'deployment/delete-efs.log'
    shell:
        """
        set -ex
        MOUNT_TARGETS=($(aws --profile {params.profile} efs describe-mount-targets --file-system-id {params.efsid} | jq -r ".MountTargets[].MountTargetId"))
        for i in "${{MOUNT_TARGETS[@]}}"
        do
        	aws --profile {params.profile} efs delete-mount-target --mount-target-id $i
        done
        aws --profile {params.profile} efs delete-file-system --file-system-id {params.efsid}
        """

rule delete_cluster:
    """
    Warning! Deletes EKS deployment.
    """
    params:
        profile=config['aws']['user'],
        region=config['eksctl']['region'],
        name=config['eksctl']['clusterName'],
        efsid=config['efs']['url'][:11]
    log: 'deployment/delete-cluster.log'
    shell:
        """
        set -ex
        echo "!! removing mount targets from EFS drive !!"
        MOUNT_TARGETS=($(aws --profile {params.profile} efs describe-mount-targets --file-system-id {params.efsid} | jq -r ".MountTargets[].MountTargetId"))
        for i in "${{MOUNT_TARGETS[@]}}"
        do
        	aws --profile {params.profile} efs delete-mount-target --mount-target-id $i
        done
    	eksctl delete cluster --name {params.name} --region {params.region} --profile {params.profile} >> {log}
        """
