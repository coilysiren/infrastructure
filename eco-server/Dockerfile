FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /home/ubuntu

# we don't need sudo, but it provides compatibility with the AMI build script
RUN apt-get update && apt-get -y install sudo
COPY --from=scripts . scripts
RUN chmod +x ./scripts/*
RUN ./scripts/setup-shared.sh

RUN mkdir -p eco
WORKDIR /home/ubuntu/eco
COPY --from=source . .
RUN rm EcoServerLinux*.zip
RUN chmod a+x install.sh
RUN ./install.sh

COPY --from=mods . /home/ubuntu/eco
COPY --from=configs . /home/ubuntu/eco

CMD ["/home/ubuntu/eco/EcoServer", "--offline"]
