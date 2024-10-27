FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /home/ubuntu

COPY --from=cwd . .

RUN chmod +x ./scripts/*

# we don't need sudo, but it provides compatibility with the AMI build script
RUN apt-get update && apt-get -y install sudo

RUN ./scripts/setup-shared.sh docker
