# builtin
import os
import io
import zipfile

# 3rd party
import boto3
import invoke
import requests

# local
import invokepatch

invokepatch.fix_annotations()
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
s3 = boto3.client("s3")


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
    ctx.run(f"ssh {user}@{ip}", pty=True)


@invoke.task
def deploy(ctx: invoke.Context, name="eco-server"):
    ctx.run(
        "aws cloudformation validate-template --template-body file://instance.yaml",
        pty=True,
    )
    ctx.run(
        f"""
        aws cloudformation deploy \
            --template-file instance.yaml \
            --stack-name {name} \
            --parameter-overrides Name={name}
    """,
        pty=True,
    )


@invoke.task
def push_asset(ctx: invoke.Context, name="EcoServerLinux", bucket="coilysiren-assets"):
    downloads = os.listdir(os.path.join(os.path.expanduser("~"), "Downloads"))
    options = [download for download in downloads if "EcoServerLinux" in download]

    if len(options) == 0:
        raise Exception(f'could not find "{name}" download from {downloads}')
    elif len(options) > 1:
        raise Exception(f'found too many downloads called "{name}" from {downloads}')

    asset_path = os.path.join(os.path.expanduser("~"), "Downloads", options[0])

    print(f"syncing from {asset_path} to s3://{bucket}/{name}")
    with open(asset_path, "rb") as data:
        s3.upload_fileobj(data, bucket, name)


@invoke.task
def pull_asset(ctx: invoke.Context, name="EcoServerLinux", bucket="coilysiren-assets"):
    ctx.run(f"aws s3 cp s3://coilysiren-assets/EcoServerLinux .", pty=True)


# @invoke.task
# def eco_download(ctx: invoke.Context, version="v0.9.5.4"):
#     # docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html#SSM.Client.get_parameter
#     response = ssm.get_parameter(
#         Name="/eco/username",
#         WithDecryption=True,
#     )
#     username = response["Parameter"]["Value"]
#     response = ssm.get_parameter(
#         Name="/eco/password",
#         WithDecryption=True,
#     )
#     password = response["Parameter"]["Value"]
#     response = requests.get(
#         f"https://play.eco/s3/release/EcoServerLinux_{version}-beta.zip",
#         auth=(username, password),
#     )
#     print(response.content)
#     zipped_eco = zipfile.ZipFile(io.BytesIO(response.content))
#     zipped_eco.extractall("eco-server-linux")
