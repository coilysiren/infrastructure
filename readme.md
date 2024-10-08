# infrastructure

The infrastructure layer for my apps, websites.

## Related Repos

- coilysiren/infrastructure is the home of the DNS route that points to [coilysiren/website](https://github.com/coilysiren/website)
- coilysiren/infrastructure uses docker images that are built inside of [coilysiren/images](https://github.com/coilysiren/images)

## Game Servers

### Restoring a Game Server

1. Setup AWS Console and AWS CLI access. Make sure they are in the same region!
2. Create a new SSH key via [the AWS UI](https://us-east-1.console.aws.amazon.com/ec2/home?AMICatalog%3A=&region=us-east-1#KeyPairs:). Name it simply `ssh`. Delete any old keys that might already be parked on that name.

    - `sudo cp ~/Downloads/ssh.pem ~/.ssh/aws.pem`
      - the download location will be something like `/mnt/c/Users/$username/Downloads/ssh.pem` on WSL
    - `chmod 400 ~/.ssh/aws.pem`
    - `ssh-add ~/.ssh/aws.pem`

3. `invoke deploy-shared` - This deploys simple shared infra. Run it just to make sure everything is on the same page. _"No changes to deploy"_ is what you ideally get here.
4. `invoke build` - This will cut a new build of the AMI, and push it to AWS. This doesn't need to happen often. The primary reasons you would run this are 1. to add new game servers or 2. to install security updates. The bulk of the config for this build is in three places. You don't need to edit them unless you are starting a new game server. Those places are:

    - `ubuntu.pkr.hcl`
    - `scripts/ubuntu-setup.sh`
    - `assets/` <== which has game server specific files

5. `invoke deploy-server` - Deploys an EC2 game server. Run `invoke deploy-server --name WHATEVER` to deploy a different type of server, although honestly you are better off with editing `tasks.py`. Just make sure you only edit the `name="WHATEVER"` parts. Valid names are:

    - `eco-server`
    - ??? terraria ???

6. `invoke ssh` - Hop into the server. Look around a bit. Everything beyond this point is iterative. Good luck have fun!

### eco

See: [eco.md](eco.md)

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

TODO: add to AMI build inotify changes, eg:

  /etc/sysctl.conf
    fs.inotify.max_user_instances = 1024

  /proc/sys/fs/inotify/max_user_instances
    1024
