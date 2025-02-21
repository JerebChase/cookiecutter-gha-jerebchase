# Use the Alpine Linux base image
FROM python:3.11-alpine

RUN apk update && \
    apk add --no-cache jq \
    curl \ 
    git \
    openssh-client \
    bash \
    py3-pip \
    nodejs \
    npm && \
    pip install --no-cache-dir cookiecutter six

WORKDIR /util
RUN npm install libsodium-wrappers

WORKDIR /
COPY *.sh /
RUN chmod +x /*.sh

COPY util /util

WORKDIR /

ENTRYPOINT ["/entrypoint.sh"]
