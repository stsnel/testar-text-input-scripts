#!/bin/bash

if [ ! -d ckan ]
then git clone https://github.com/stsnel/ckan.git
fi

cd ckan
git checkout 2.9.3-testar
cp ../docker-compose-build.yml contrib/docker/docker-compose.yml
cp ../ckan-entrypoint.sh contrib/docker/ckan-entrypoint.sh
cp ../Dockerfile .
cp ../extract-strings.py .

docker build . --no-cache -t 378672356020.dkr.ecr.us-east-1.amazonaws.com/ckan
