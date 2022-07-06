# builtin
import os
import textwrap

# 3rd party
import boto3
import invoke
import requests

# local
import invokepatch

invokepatch.fix_annotations()

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm")


@invoke.task
def ssh(ctx: invoke.Context, name="eco-server", user="ubuntu"):
    # TODO: ec2 instance connect
    ctx.run(
        f"ssh {user}@{name}.coilysiren.me",
        pty=True,
        echo=True,
    )


@invoke.task
def build(ctx: invoke.Context):
    ctx.run(
        "packer init .",
        pty=True,
        echo=True,
    )
    ctx.run(
        "packer fmt .",
        pty=True,
        echo=True,
    )
    ctx.run(
        "packer validate .",
        pty=True,
        echo=True,
    )

    # the packer build uses an IAM role deployed by the following stack
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/iam.yaml && \
            aws cloudformation deploy \
                --template-file templates/iam.yaml \
                --stack-name game-server-iam \
                --parameter-overrides Name=game-server \
                --capabilities CAPABILITY_NAMED_IAM
            """
        ),
        pty=True,
        echo=True,
    )

    ctx.run(
        "packer build ubuntu.pkr.hcl",
        pty=True,
        echo=True,
    )


@invoke.task
def deploy(ctx: invoke.Context, name="eco-server"):
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/iam.yaml && \
            aws cloudformation deploy \
                --template-file templates/iam.yaml \
                --capabilities CAPABILITY_NAMED_IAM \
                --stack-name game-server-iam
            """
        ),
        pty=True,
        echo=True,
    )

    vpc = ec2.describe_vpcs()["Vpcs"][0]["VpcId"]
    home_ip = requests.get("http://ifconfig.me").text  # TODO: ssm /cfn/home-ip-address
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/security-groups.yaml && \
            aws cloudformation deploy \
                --template-file templates/security-groups.yaml \
                --parameter-overrides \
                    HomeIP='{home_ip}/32' \
                    VPC={vpc} \
                --stack-name game-server-security-groups
            """
        ),
        pty=True,
        echo=True,
    )

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/dns.yaml && \
            aws cloudformation deploy \
                --template-file templates/dns.yaml \
                --parameter-overrides \
                    Name={name} \
                --stack-name {name}-dns
            """
        ),
        pty=True,
        echo=True,
    )

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/volume.yaml && \
            aws cloudformation deploy \
                --template-file templates/volume.yaml \
                --parameter-overrides \
                    Name={name} \
                --stack-name {name}-volume
            """
        ),
        pty=True,
        echo=True,
    )

    # get AMI
    response = ec2.describe_images(
        Filters=[
            {"Name": "name", "Values": ["ubuntu-packer"]},
        ],
    )
    ubuntu_ami = response["Images"][0]["ImageId"]

    # get EBS volume
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/ebs-vol",
        WithDecryption=True,
    )
    ebs_volume = response["Parameter"]["Value"]

    # get EIP id
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/eip-id",
        WithDecryption=True,
    )
    eip_ip = response["Parameter"]["Value"]

    # get security groups
    security_groups = []
    response = ssm.get_parameter(
        Name="/cfn/base-security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/instance.yaml && \
            aws cloudformation deploy \
                --template-file templates/instance.yaml \
                --parameter-overrides \
                    Name={name} \
                    Volume={ebs_volume} \
                    AMI={ubuntu_ami} \
                    EIPAllocationId={eip_ip} \
                    SecurityGroups={",".join(security_groups)} \
                --stack-name {name}
            """
        ),
        pty=True,
        echo=True,
    )


@invoke.task
def delete(ctx: invoke.Context, name="eco-server"):
    ctx.run(
        f"aws cloudformation delete-stack --stack-name {name}",
        pty=True,
        echo=True,
    )
    ctx.run(
        f"aws cloudformation wait stack-delete-complete --stack-name {name}",
        pty=True,
        echo=True,
    )


@invoke.task
def redeploy(ctx: invoke.Context, name="eco-server"):
    delete(ctx, name)
    deploy(ctx, name)


@invoke.task
def push_asset(
    ctx: invoke.Context, download="EcoServerLinux", bucket="coilysiren-assets"
):
    downloads = os.listdir(os.path.join(os.path.expanduser("~"), "Downloads"))
    options = [filename for filename in downloads if download in filename]

    if len(options) == 0:
        raise Exception(f'could not find "{download}" download from {downloads}')
    elif len(options) > 1:
        raise Exception(
            f'found too many downloads called "{download}" from {downloads}'
        )

    asset_path = os.path.join(os.path.expanduser("~"), "Downloads", options[0])

    ctx.run(
        f"aws s3 cp {asset_path} s3://{bucket}/downloads/{download}",
        pty=True,
        echo=True,
    )


@invoke.task
def pull_asset(
    ctx: invoke.Context, download="EcoServerLinux", bucket="coilysiren-assets"
):
    ctx.run(
        f"aws s3 cp s3://{bucket}/downloads/{download} .",
        pty=True,
        echo=True,
    )
