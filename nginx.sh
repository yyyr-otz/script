#!/bin/bash
ck_ok()
{
    if [ $? -ne 0 ]
    then
            echo "$1 error."
            exit 1
    fi
}

download_ng()
{
    cd /usr/local/src
    if [ -f nginx-1.23.0.tar.gz ]
    then
        echo "Current directory already has nginx-1.23.0.tar.gz"
        echo "Checking md5"
        ng_md5=`md5sum nginx-1.23.0.tar.gz|awk '{print $1}'`
        if [ ${ng_md5} == 'e8768e388f26fb3d56a3c88055345219' ]
        then
            return 0
        else
            sudo /bin/mv nginx-1.23.0.tar.gz nginx-1.23.0.tar.gz.old
        fi
    fi

    sudo curl -O http://nginx.org/download/nginx-1.23.0.tar.gz
    ck_ok "Downloading Nginx"
}

install_ng()
{
    cd /usr/local/src
    echo "Unzipping Nginx"
    sudo tar zxf nginx-1.23.0.tar.gz
    ck_ok "Unzipping Nginx"
    cd nginx-1.23.0

    echo "Installing dependencies"
    if which yum >/dev/null 2>&1
    then
        ## RHEL/CentOS
        sudo yum update
        for pkg in gcc make pcre pcre-devel zlib-devel openssl-devel 
        do
                sudo yum install -y $pkg
                ck_ok "yum installed $pkg"
        done
    elif which apt >/dev/null 2>&1
    then
        ## Ubuntu/Debian
        sudo apt update
        for pkg in gcc make libpcre3-dev zlib1g-dev libssl-dev build-essential
        do
                sudo apt install -y $pkg 
                ck_ok "apt installed $pkg" 
        done
    fi

    echo "Configuring Nginx"
    sudo ./configure --prefix=/usr/local/nginx  --with-http_ssl_module --with-http_stub_status_module --with-http_realip_module --with-http_auth_request_module --with-http_v2_module --with-http_dav_module --with-http_slice_module --with-threads --with-http_addition_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_preread_module
    ck_ok "Configured Nginx"

    echo "Compiling and installing"
    sudo make && sudo make install
    ck_ok "Compiled and installed"

    echo "Editing systemd service management script"

    cat > /tmp/nginx.service <<EOF
[Unit]
Description=nginx - high performance web server
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStart=/usr/local/nginx/sbin/nginx -c /usr/local/nginx/conf/nginx.conf
ExecReload=/bin/sh -c "/bin/kill -s HUP \$(/bin/cat /usr/local/nginx/logs/nginx.pid)"
ExecStop=/bin/sh -c "/bin/kill -s TERM \$(/bin/cat /usr/local/nginx/logs/nginx.pid)"

[Install]
WantedBy=multi-user.target
EOF

    sudo /bin/mv /tmp/nginx.service /lib/systemd/system/nginx.service
    ck_ok "Edited nginx.service"

    echo "Loading service"
    sudo systemctl unmask nginx.service
    sudo systemctl daemon-reload
    sudo systemctl enable nginx
    echo "Starting Nginx"
    sudo systemctl start nginx
    ck_ok "Started Nginx"
}

download_ng
install_ng
