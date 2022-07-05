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
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


@invoke.task
def ssh(ctx: invoke.Context, name="eco-server", user="ubuntu"):
    # docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html#EC2.Client.describe_instances
    response = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ],
    )
    ip = response["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    ctx.run(
        f"ssh {user}@{ip}",
        pty=True,
        echo=True,
    )


@invoke.task
def build(ctx: invoke.Context, name="eco-server", user="ubuntu"):
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

    #
    # the packer build uses an IAM role deployed by the following stack
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://iam.yaml && \
            aws cloudformation deploy \
                --template-file iam.yaml \
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
            aws cloudformation validate-template --template-body file://iam.yaml && \
            aws cloudformation deploy \
                --template-file iam.yaml \
                --capabilities CAPABILITY_NAMED_IAM \
                --stack-name game-server-iam
            """
        ),
        pty=True,
        echo=True,
    )

    # docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html#EC2.Client.describe_vpcs
    response = ec2.describe_vpcs()
    vpc = response["Vpcs"][0]["VpcId"]

    home_ip = requests.get("http://ifconfig.me").text
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://networking.yaml && \
            aws cloudformation deploy \
                --template-file networking.yaml \
                --parameter-overrides \
                    HomeIP='{home_ip}/32' \
                    VPC={vpc} \
                --stack-name game-server-networking
            """
        ),
        pty=True,
        echo=True,
    )

    # docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html#EC2.Client.describe_images
    response = ec2.describe_images(
        Filters=[
            {"Name": "name", "Values": ["ubuntu-packer"]},
        ],
    )
    ubuntu_ami = response["Images"][0]["ImageId"]

    # docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html#SSM.Client.get_parameter
    security_groups = []
    response = ssm.get_parameter(
        Name="/cfn/base-security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])
    response = ssm.get_parameter(
        Name="/cfn/eco-security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://instance.yaml && \
            aws cloudformation deploy \
                --template-file instance.yaml \
                --parameter-overrides \
                    Name={name} \
                    AMI={ubuntu_ami} \
                    SecurityGroups={",".join(security_groups)} \
                --stack-name {name}
            """
        ),
        pty=True,
        echo=True,
    )


@invoke.task
def push_asset(ctx: invoke.Context, name="EcoServerLinux", bucket="coilysiren-assets"):
    downloads = os.listdir(os.path.join(os.path.expanduser("~"), "Downloads"))
    options = [download for download in downloads if name in download]

    if len(options) == 0:
        raise Exception(f'could not find "{name}" download from {downloads}')
    elif len(options) > 1:
        raise Exception(f'found too many downloads called "{name}" from {downloads}')

    asset_path = os.path.join(os.path.expanduser("~"), "Downloads", options[0])

    ctx.run(
        f"aws s3 cp {asset_path} s3://{bucket}/downloads/{name}",
        pty=True,
        echo=True,
    )


@invoke.task
def pull_asset(ctx: invoke.Context, name="EcoServerLinux", bucket="coilysiren-assets"):
    ctx.run(
        f"aws s3 cp s3://{bucket}/downloads/{name} .",
        pty=True,
        echo=True,
    )
