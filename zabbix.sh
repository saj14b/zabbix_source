#!/bin/bash

# installs zabbix from source compilation

printPlain() { /bin/echo -e "${1}" >&2; }
printGreen() { /bin/echo -e "\033[32;1m${1}\033[0m" >&2; }
printBlue()  { /bin/echo -e "\033[34;1m${1}\033[0m" >&2; }
printYellow(){ /bin/echo -e "\033[33;1m${1}\033[0m" >&2; }
printRed()   { /bin/echo -e "\033[31;1m${1}\033[0m" >&2; }

ZABBIX_FILE="zabbix-2.4.7.tar.gz"
MYSQL_PW="root"

###############################################################################
# Temporary for debugging
sudo service ntp stop
sudo ntpdate -s time.nist.gov
sudo service ntp start

############
#Install and setup zabbix-server
INSTALL_ZABBIX=1
#if [ -e /usr/share/zabbix-server ]; then
#  read -p "Zabbix is already installed, reinstall? (y/n): " -e REINSTALL_ZABBIX
#  if [ "${REINSTALL_ZABBIX}" != 'y' ]; then
#    INSTALL_ZABBIX=0
#  fi
#fi
if [ $INSTALL_ZABBIX -eq 1 ]; then
  CURDIR=`pwd`
  printGreen "Installing dependencies..."
  sudo apt-get -y update
  sudo apt-get -y install debconf-utils build-essential libmysqld-dev libxml2-dev libsnmp-dev libcurl4-gnutls-dev
  sudo apt-get -y install apache2 libapache2-mod-php5 php5-mysql php5-gd
  #need apache php

#  sudo apt-get -y install zabbix-agent
#  sudo apt-get -y install zabbix-server-mysql
#  sudo apt-get -y install zabbix-frontend-php --no-install-recommends

  printGreen "Downloading Zabbix..."
  sudo mkdir --parents /opt/zabbix/
  sudo wget --output-document=/opt/zabbix/${ZABBIX_FILE} --user=vitalscli --password=P6QbP41X "ftp://ftp.ctipath.com/Zabbix_Source/${ZABBIX_FILE}"
  printGreen "Unpacking Zabbix..."
  sudo tar -zxf /opt/zabbix/${ZABBIX_FILE}

  # strips .tar.gz extension from file for path
  cd /opt/zabbix/"${ZABBIX_FILE%.tar.gz}"

  printGreen "Adding zabbix user..."
  sudo groupadd zabbix
  sudo useradd -g zabbix zabbix

  #MYSQL SETUP
  printGreen "Installing mysql-server..."
  sudo debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_PW}"
  sudo debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_PW}"
  sudo apt-get -y install mysql-server

  printGreen "Building Zabbix tables..."
  Q1="CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${MYSQL_PW}';"
  Q2="CREATE DATABASE IF NOT EXISTS zabbix;"
  Q3="GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
  Q4="FLUSH PRIVILEGES;"
  SQL="${Q1}${Q2}${Q3}${Q4}"
  mysql --user=root --password=${MYSQL_PW} --database=mysql --execute="${SQL}"
  printGreen "Applying schema.sql..."
  mysql --user=zabbix --password=${MYSQL_PW} --database=zabbix < database/mysql/schema.sql
  printGreen "Applying images.sql..."
  mysql --user=zabbix --password=${MYSQL_PW} --database=zabbix < database/mysql/images.sql
  printGreen "Applying data.sql..."
  mysql --user=zabbix --password=${MYSQL_PW} --database=zabbix < database/mysql/data.sql


  sudo mkdir --parents /etc/zabbix
  ./configure --enable-server --enable-agent --with-mysql --enable-ipv6 --with-net-snmp --with-libcurl --with-libxml2

  sudo make install

  sudo cp misc/init.d/ubuntu/zabbix-server.conf /etc/init.d/zabbix-server
  sudo chmod 755 /etc/init.d/zabbix-server

  #printGreen "Copying Zabbix frontend files..."
  mkdir --parents /opt/zabbix/active_frontend
  sudo cp --archive frontends/php/* /opt/zabbix/active_frontend
  sudo chown -R www-data:www-data /opt/zabbix/active_frontend
  sudo bash -c "echo \"
Alias /zabbix /opt/zabbix/active_frontend
<Directory /opt/zabbix/active_frontend>
  Require all granted
</Directory>\" > /etc/apache2/sites-available/zabbix.conf"
  sudo a2ensite zabbix.conf
  sudo a2dissite 000-default.conf

  #tuning php for Zabbix
  sudo sed -r -i -e "s/post_max_size = 8M/post_max_size = 16M/g" /etc/php5/apache2/php.ini
  sudo sed -r -i -e "s/max_execution_time = 30/max_execution_time = 300/g" /etc/php5/apache2/php.ini
  sudo sed -r -i -e "s/max_input_time = 60/max_input_time = 300/g" /etc/php5/apache2/php.ini
  sudo sed -r -i -e "s/;date\.timezone =/date.timezone = \"America\/New_York\"/g" /etc/php5/apache2/php.ini
  sudo /etc/init.d/apache2 reload
  
  #mysql tuning
  sudo bash -c "echo \"
  
#######################
#ZABBIX TUNING
[mysqld]
#tmpdir = /tmpfs/mysql
innodb_support_xa = false
innodb_buffer_pool_size = 512M # It depends how many memory is available to MySQL, more is better.
innodb_flush_log_at_trx_commit = 0 # disable writing to logs on every commit and disable fsync on each write
innodb_max_dirty_pages_pct = 90 # avoid flushing dirty pages to disk
innodb_flush_method = O_DIRECT # direct access to disk without OS cache
thread_cache_size = 4
query_cache_size = 0
table_cache = 80 # a little more than number_of_tables_in_zabbix_database
innodb_flush_log_at_trx_commit=2
join_buffer_size=256k
read_buffer_size=256k
read_rnd_buffer_size=256k
thread_cache_size=4
tmp_table_size=128M
max_heap_table_size=128M
table_cache=256\" >> /etc/mysql/conf.d/zabbix_tuning.cnf"
  
  #apply config
  sudo service mysql restart
  
  #link in vitalscli script
  sudo ln -sf /opt/vitalscli/vitalscli_push_nms.sh /usr/local/share/zabbix/alertscripts/
  sudo ln -sf /opt/vitalscli/vitalscli_push_nms.sh /usr/local/share/zabbix/externalscripts/
  sudo usermod -s /bin/bash zabbix

  #zabbix user has to be able to sudo as vitalscli user to run vitalscli  
  sudo bash -c "echo -e \"zabbix  ALL=(vitalscli) NOPASSWD: ALL\" > /etc/sudoers.d/vitalscli_zabbix"
  sudo chmod 440 /etc/sudoers.d/vitalscli_zabbix
  sudo /etc/init.d/sudo restart

  cd ${CURDIR}
fi
