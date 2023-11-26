# infrastructure

The infrastructure layer for my apps, websites.

## Related Repos

- coilysiren/infrastructure is the home of the DNS route that points to [coilysiren/website](https://github.com/coilysiren/website)
- coilysiren/infrastructure uses docker images that are built inside of [coilysiren/images](https://github.com/coilysiren/images)

## Game Servers

### Restoring a Game Server

1. Setup AWS CLI access
2. Create a new SSH key via [the AWS UI](https://us-east-1.console.aws.amazon.com/ec2/home?AMICatalog%3A=&region=us-east-1#KeyPairs:). Name it simply `ssh`. Delete any old keys that might already be parked on that name.
    - `sudo cp ~/Downloads/ssh.pem ~/.ssh/aws.pem`
    - `chmod 400 ~/.ssh/aws.pem`
    - `ssh-add ~/.ssh/aws.pem`
3. `invoke deploy-shared` - This deploys simple shared infra
4. `invoke build` - This will cut a new build of the AMI, and push it to AWS. This doesn't need to happen often. The primary reasons you would run this are 1. to add new game servers or 2. to install security updates. The bulk of the build configuration is in three places.
    1. `ubuntu.pkr.hcl`
    2. `scripts/ubuntu-setup.sh`
    3. `assets/` <== which has game server specific files
5. `invoke deploy-server` - Deploys an EC2 game server. Run `invoke deploy-server --name WHATEVER` to deploy a different type of server, although honestly you are better off with editing `tasks.py`.
6. `invoke ssh` - Hope into the server. Look around a bit. Everything beyond this point is iterative. Good luck have fun!

### eco

- https://store.steampowered.com/app/382310/Eco/
- https://wiki.play.eco/en/Setting_Up_a_Server

### terraria

- https://store.steampowered.com/app/105600/Terraria/
- https://terraria.fandom.com/wiki/Guide:Setting_up_a_Terraria_server#Linux_/_macOS
  - ⚠️ the site above has many ads ⚠️

### gotchas

You must run

```bash
sudo mkfs.ext4 /dev/nvme1n1
```

exactly once, when configuring a new game type, to format its EBS volume

this command is dangerous because if can wipe your drive if there's already data in it!

via https://unix.stackexchange.com/questions/315063/mount-wrong-fs-type-bad-option-bad-superblock
