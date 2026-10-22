FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf bison build-essential bzip2 ca-certificates curl file patch pkg-config re2c xz-utils \
    libbz2-dev libcurl4-openssl-dev libfreetype6-dev libicu-dev libjpeg-dev \
    libonig-dev libpng-dev libreadline-dev libsqlite3-dev libssl-dev \
    libtidy-dev libxml2-dev libxslt1-dev libzip-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
