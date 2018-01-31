#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Please provide the VM name and your email address as parameters:"
    echo "$0 vm-name name@domain.tld"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with root priviliges:"
    echo "sudo $0"
    exit 1
fi

apt-get -qq install nano
if [ "$?" -ne 0 ]; then
    echo "Encountered a problem with apt/dpkg, please fix it before running this script again"
    exit 1
fi

VMNAME=$1
EMAIL=$2
VMHOST="$VMNAME.fair-dtls.surf-hosted.nl"

host $VMHOST
if [ "$?" -ne 0 ]; then
    echo "DNS information for this host cannot be resolved. This will cause issues with
    certbot later on. Please wait until this host is resolvable through DNS lookup."
    exit 1
fi

set -e

export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"

install_packages() {
    apt-get -qq -y install apt-transport-https software-properties-common
}

configure_hostname() {
    hostname $VMHOST
    echo $VMHOST > /etc/hostname
}

mount_storage() {
    mkdir /data
    mkfs -t xfs /dev/vdb
    mount /dev/vdb /data
    mkdir -p /etc/rc.d/ && touch /etc/rc.d/rc.local
    echo "echo 4096 > /sys/block/vdb/queue/read_ahead_kb" > /etc/rc.d/rc.local
    chmod 755 /etc/rc.d/rc.local
    echo "/dev/vdb /data xfs defaults 0 0" >> /etc/fstab
}

setup_nginx() {
    apt-get -qq -y install nginx python-software-properties
    echo "server {
        listen 80;
        server_name $VMHOST;
        root /var/www/html;

        include /data/apps/nginx/*.conf;
    }" > /etc/nginx/sites-available/$VMNAME
    pushd /etc/nginx/sites-enabled
    ln -s /etc/nginx/sites-available/$VMNAME $VMNAME
    popd
    mkdir -p /data/apps/nginx
    service nginx reload
}

setup_certbot() {
    add-apt-repository -y -u ppa:certbot/certbot
    apt-get -qq -y install certbot python-certbot-nginx
    ufw allow http
    ufw allow https
    #certbot --nginx --non-interactive --agree-tos --email $EMAIL --no-eff-email --domain $VMHOST --redirect
}

install_docker() {
    apt-get -qq -y install linux-image-extra-$(uname -r) linux-image-extra-virtual
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get -qq update
    apt-get -qq -y install docker-ce
    usermod -aG docker ubuntu
}

install_docker_compose() {
    curl -L https://github.com/docker/compose/releases/download/1.18.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    curl -L https://raw.githubusercontent.com/docker/compose/1.18.0/contrib/completion/bash/docker-compose -o /etc/bash_completion.d/docker-compose
}

configure_docker() {
    service docker stop
    mkdir -p /data/apps
    pushd /var/lib
    mv docker /data/apps
    ln -s /data/apps/docker docker
    popd
    service docker start
}

setup_editor() {
    echo "{\"endpoint\":\"https://$VMHOST/fdp\"}" > /data/apps/editor/config/settings.json
}

setup_fdp() {
    local config="webapps/ROOT/WEB-INF/classes/conf/fdpConfig.yml"

    docker exec fdp sh -c "sed -r -i 's/type: .+$/type: 1/' $config"
    docker exec fdp sh -c "sed -r -i 's/url: .+$/url: http:\/\/agraph:10035\/repositories\/fdp/' $config"
    docker exec fdp sh -c "sed -r -i 's/username: .+$/username: test/' $config"
    docker exec fdp sh -c "sed -r -i 's/password: .+$/password: xyzzy/' $config"

    curl -X PUT -u test:xyzzy http://localhost:10035/repositories/fdp

    su ubuntu -c "docker-compose restart fdp"
}

setup_fairifier() {
    mkdir -p /data/apps/fairifier/{data,config}
    echo "<xml>
        <pushToFtp>
            <enabled>false</enabled>
            <username></username>
            <password></password>
            <host></host>
            <directory></directory>
        </pushToFtp>
        <pushToVirtuoso>
            <enabled>true</enabled>
            <username>dba</username>
            <password>dba</password>
            <host>https://$VMHOST</host>
            <directory>/DAV/home/dba/rdf_sink/</directory>
        </pushToVirtuoso>
    </xml>" > /data/apps/fairifier/config/config.xml

    docker exec fairifier sh -c "echo \"REFINE_DATA_DIR=/fairifier_data\" >> /home/FAIRifier/refine.ini"
    
    su ubuntu -c "docker-compose restart fairifier"
}

setup_docker_images() {
    su ubuntu -c "docker-compose up -d"
    mv nginx/*.conf /data/apps/nginx
    service nginx reload
    
    setup_editor
    setup_fdp
    setup_fairifier
}

install_packages
configure_hostname
mount_storage
setup_nginx
setup_certbot
install_docker
install_docker_compose
configure_docker
setup_docker_images