# 3rd party
import invoke
import boto3

# local
import invokepatch

invokepatch.fix_annotations()
ec2 = boto3.client("ec2")


@invoke.task
def ssh(ctx: invoke.Context, name="eco-server"):
    response = ec2.describe_instances(
        Filters=[
            {
                "Name": "tag:Name",
                "Values": [
                    name,
                ],
            },
        ],
    )
    ip = response["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    ctx.run(f"ssh ec2-user@{ip}", pty=True)
