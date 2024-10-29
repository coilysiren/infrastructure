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
RUN rm -rf /home/ubuntu/eco/EcoServer*.zip
RUN chmod a+x install.sh
RUN ./install.sh

COPY --from=mods . /home/ubuntu/eco
COPY --from=configs . /home/ubuntu/eco

EXPOSE 3000
EXPOSE 3001
EXPOSE 3002
EXPOSE 3003

CMD ["/home/ubuntu/eco/EcoServer", "--offline"]
