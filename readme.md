# infrastructure

The infrastructure layer for my apps, websites.

## Connects To

## Platform 

- GCP (TODO), as a pending replacement for AWS (RIP)
- Datadog monitoring (TODO)
- Docker base images hosted in Docker Hub
- Github Actions
---

#############################
/ # legacy readme follows # /
#############################

## eco

- https://store.steampowered.com/app/382310/Eco/
- https://wiki.play.eco/en/Setting_Up_a_Server

## terraria

- https://store.steampowered.com/app/105600/Terraria/
- https://terraria.fandom.com/wiki/Guide:Setting_up_a_Terraria_server#Linux_/_macOS
  - ⚠️ the site above has many ads ⚠️

## gotchas

You must run

```bash
sudo mkfs.ext4 /dev/nvme1n1
```

exactly once, when configuring a new game type, to format its EBS volume

this command is dangerous because if can wipe your drive if there's already data in it!

via https://unix.stackexchange.com/questions/315063/mount-wrong-fs-type-bad-option-bad-superblock
