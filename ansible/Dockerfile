FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

ENV ANSIBLE_VERSION 2.16.2

RUN apt-get update; \
    apt-get install -y gcc python3; \
    apt-get install -y python3-pip; \
    apt-get install -y openssh-client; \
    apt-get install -y docker.io; \
    apt-get clean all

RUN pip3 install --upgrade pip; \
    pip3 install "ansible==${ANSIBLE_VERSION}"; \
    pip3 install ansible

WORKDIR /work

COPY ansible.cfg .
COPY requirements.yml .

RUN ansible-galaxy role install -r requirements.yml
