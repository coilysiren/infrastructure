ARG UBUNTU_VERSION

FROM ubuntu:$UBUNTU_VERSION

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /home/ubuntu

COPY --from=scripts . scripts

RUN chmod +x ./scripts/*

# we don't need sudo, but it provides compatibility with the AMI build script
RUN apt-get update && apt-get -y install sudo

RUN ./scripts/setup-shared.sh docker
