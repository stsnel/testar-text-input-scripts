#!/bin/bash
# Basic installation for ubuntu 20.04
## Changes to package install instructions: 
## - also install required python3-distutils
## - configure storage_path
set -e
set -x

sudo mkdir /coverage
sudo chmod 0777 /coverage

sudo apt update
sudo apt install -y redis-server nginx supervisor python3-distutils python3-pip \
                    python3-dev python3-pip python3-venv git-core \
                    postgresql libpq5 libpq-dev supervisor openjdk-8-jdk sqlite3

sudo mkdir -p /usr/lib/ckan/default
sudo chown `whoami` /usr/lib/ckan/default
python3 -m venv /usr/lib/ckan/default
source /usr/lib/ckan/default/bin/activate
pip3 install --upgrade requests==2.26.0
pip3 install setuptools==44.1.0
pip3 install --upgrade pip
pip3 install -e 'git+https://github.com/stsnel/ckan.git@2.9.3-testar#egg=ckan[requirements]'
pip3 install -e 'git+https://github.com/stsnel/coveragepy.git@6.2-local#egg=coverage[requirements]'
pip3 install -e 'git+https://github.com/stsnel/python-string-extractor.git@main#egg=string_extractor[requirements]'
pip3 install uwsgi

cd /usr/lib/ckan/default/src
pip3 install -e "git+https://github.com/davidread/ckanext-hierarchy.git#egg=ckanext-hierarchy"
pip3 install -r ckanext-hierarchy/requirements.txt
pip3 install ckanext-showcase

sudo -u postgres psql -c "CREATE USER ckan_default WITH PASSWORD 'pass';"
sudo -u postgres createdb -O ckan_default ckan_default -E utf-8

cd
SOLR_VERSION="6.5.1"
SOLR_CORE_NAME="ckan"
SOLR_CORE_DIR="/var/solr/data/ckan"
SOLR_CORE_SCHEMA="${SOLR_CORE_DIR}/conf/managed-schema"
wget https://archive.apache.org/dist/lucene/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz
tar xzf solr-${SOLR_VERSION}.tgz solr-${SOLR_VERSION}/bin/install_solr_service.sh --strip-components=2
sudo chmod +x ./install_solr_service.sh 
sudo bash ./install_solr_service.sh solr-${SOLR_VERSION}.tgz

sudo -u solr /opt/solr-$SOLR_VERSION/bin/solr create_core -c "$SOLR_CORE_NAME"
sudo rm "$SOLR_CORE_SCHEMA"
sudo ln -s /usr/lib/ckan/default/src/ckan/ckan/config/solr/schema.xml "$SOLR_CORE_SCHEMA"
sudo systemctl daemon-reload
sudo systemctl restart solr

sudo mkdir -p /etc/ckan/default
sudo chown -R `whoami` /etc/ckan/
. /usr/lib/ckan/default/bin/activate
ckan generate config /etc/ckan/default/ckan.ini
ln -s /usr/lib/ckan/default/src/ckan/who.ini /etc/ckan/default/who.ini
sudo cp /usr/lib/ckan/default/src/ckan/wsgi.py /etc/ckan/default/
sudo perl -pi.bak -e 's/^ckan\.site_url =/ckan.site_url = http:\/\/localhost:8080/g' /etc/ckan/default/ckan.ini
sudo perl -pi.bak -e 's/^\#ckan\.storage_path/ckan.storage_path/' /etc/ckan/default/ckan.ini
sudo perl -pi.bak -e 's/^ckan.plugins = stats text_view image_view recline_view/ckan.plugins = stats text_view image_view recline_view showcase hierarchy_display hierarchy_form/' /etc/ckan/default/ckan.ini
sudo perl -pi.bak -e 's/^\#solr_url = http:\/\/127.0.0.1:8983\/solr/solr_url = http:\/\/127.0.0.1:8983\/solr\/ckan/' /etc/ckan/default/ckan.ini

sudo chmod -R 0777 /usr/lib/ckan/default/src/ckan/ckan/public/base

ckan --config /etc/ckan/default/ckan.ini db init

cat > /tmp/ckan-uwsgi.ini << UWSGIini
[uwsgi]

http            =  127.0.0.1:8080
uid             =  www-data
gid             =  www-data
wsgi-file       =  /etc/ckan/default/wsgi.py
virtualenv      =  /usr/lib/ckan/default
module          =  wsgi:application
master          =  true
pidfile         =  /tmp/%n.pid
harakiri        =  300
max-requests    =  5000
vacuum          =  true
callable        =  application
buffer-size     =  32768
strict          =  true
UWSGIini

install -m 0644 /tmp/ckan-uwsgi.ini /etc/ckan/default/ckan-uwsgi.ini

cat > /tmp/ckan-uwsgi.conf << UWSGIconf
[program:ckan-uwsgi]

command=/usr/lib/ckan/default/bin/uwsgi -i /etc/ckan/default/ckan-uwsgi.ini

; Start just a single worker. Increase this number if you have many or
; particularly long running background jobs.
numprocs=1
process_name=%(program_name)s-%(process_num)02d

; Log files - change this to point to the existing CKAN log files
stdout_logfile=/etc/ckan/default/uwsgi.OUT
stderr_logfile=/etc/ckan/default/uwsgi.ERR

; Make sure that the worker is started on system start and automatically
; restarted if it crashes unexpectedly.
autostart=true
autorestart=true

; Number of seconds the process has to run before it is considered to have
; started successfully.
startsecs=10

; Need to wait for currently executing tasks to finish at shutdown.
; Increase this if you have very long running tasks.
stopwaitsecs = 600

; Required for uWSGI as it does not obey SIGTERM.
stopsignal=QUIT
UWSGIconf

install -m 0644 /tmp/ckan-uwsgi.conf /etc/supervisor/conf.d/ckan-uwsgi.conf

sudo cp /usr/lib/ckan/default/src/ckan/ckan/config/supervisor-ckan-worker.conf /etc/supervisor/conf.d
sudo mkdir /var/log/ckan
sudo chmod 0777 /var/log/ckan

cat > /tmp/ckan-nginx.conf << NGINX.conf
proxy_cache_path /tmp/nginx_cache levels=1:2 keys_zone=cache:30m max_size=250m;
proxy_temp_path /tmp/nginx_proxy 1 2;

server {
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_cache cache;
        proxy_cache_bypass \$cookie_auth_tkt;
        proxy_no_cache \$cookie_auth_tkt;
        proxy_cache_valid 30m;
        proxy_cache_key \$host\$scheme\$proxy_host\$request_uri;
        # In emergency comment out line to force caching
        # proxy_ignore_headers X-Accel-Expires Expires Cache-Control;

        proxy_connect_timeout       300;
        proxy_send_timeout          300;
        proxy_read_timeout          300;
        send_timeout                300;
    }

}
NGINX.conf
sudo install -m 0644 /tmp/ckan-nginx.conf /etc/nginx/sites-available/ckan
sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/ckan /etc/nginx/sites-enabled/ckan
sudo systemctl restart nginx

sudo mkdir  /var/lib/ckan
sudo chown -R www-data:www-data /var/lib/ckan

sudo supervisorctl reload

# Create test users and data
ckan -c /etc/ckan/default/ckan.ini seed basic
ckan -c /etc/ckan/default/ckan.ini seed user
ckan -c /etc/ckan/default/ckan.ini sysadmin add tester
