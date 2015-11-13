#!/bin/bash
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# 
# See the License for the specific language governing permissions and
# limitations under the License.

echo "initializing nodes..."
IPPREFIX=$1
NAMEPREFIX=$2
NAMESUFFIX=$3
MASTERNODES=$4
DATANODES=$5
ADMINUSER=$6
NODETYPE=$7

## TODO: Remove
echo "1 is ${1}" >> /tmp/initlog.out
echo "2 is ${2}" >> /tmp/initlog.out
echo "3 is ${3}" >> /tmp/initlog.out
echo "4 is ${4}" >> /tmp/initlog.out
echo "5 is ${5}" >> /tmp/initlog.out
echo "6 is ${6}" >> /tmp/initlog.out
echo "7 is ${7}" >> /tmp/initlog.out

# we are going to do something heinous here to pull down the key
# we are going to swap out the /etc/resolv.conf file
cp /etc/resolv.conf /tmp/old_resolv.conf
echo "nameserver 172.18.64.15" > /etc/resolv.conf
wget http://github.mtv.cloudera.com/raw/QE/smokes/cdh5/common/src/main/resources/systest/id_rsa
chmod 400 ./id_rsa
mv ./id_rsa ~/.ssh/

cp /tmp/old_resolv.conf /etc/resolv.conf
cat /etc/resolv.conf

echo "here is the ~/.ssh/ directory" > /tmp/ssh_diagnosis.out
ls -la ~/.ssh/ >> /tmp/ssh_diagnosis.out
echo "done listing the ~/.ssh/ directory" >> /tmp/ssh_diagnosis.out

# end of hack

ADJUSTED_NAME_SUFFIX=`echo $NAMESUFFIX | sed 's/^[^.]*\.//'`
echo "ADJUSTED_NAME_SUFFIX is ${ADJUSTED_NAME_SUFFIX}" >> /tmp/initlog.out

#Generate IP Addresses for the cloudera setup
NODES=()

let "NAMEEND=MASTERNODES-1" || true
for i in $(seq 0 $NAMEEND)
do
  x=${NAMEPREFIX}-mn$i.${ADJUSTED_NAME_SUFFIX}
  echo "x is: $x" >> /tmp/masternodes
  privateIp=$(ssh -o "StrictHostKeyChecking=false" systest@${x} -x 'sudo ifconfig | grep inet | cut -d" " -f 12 | grep "addr:1" | grep -v "127.0.0.1" | sed "s^addr:^^g"')
  echo "$x : ${privateIp}" >> /tmp/privateMasterIps
  echo "Adding to nodes: "${privateIp}:${NAMEPREFIX}-mn${i}.${ADJUSTED_NAME_SUFFIX}:${NAMEPREFIX}-mn${i} " >> /tmp/initlog.out"

  NODES+=("${privateIp}:${NAMEPREFIX}-mn$i.${ADJUSTED_NAME_SUFFIX}:${NAMEPREFIX}-mn$i")
done

echo "finished nn private ip discovery >> /tmp/initlog.out"

let "DATAEND=DATANODES-1" || true
for i in $(seq 0 $DATAEND)
do
  x=${NAMEPREFIX}-dn$i.${ADJUSTED_NAME_SUFFIX}
  echo "x is: $x" >> /tmp/datanodes
  privateIp=$(ssh -o "StrictHostKeyChecking=false" systest@$x -x 'ifconfig | grep inet | cut -d" " -f 12 | grep "addr:1" | grep -v "127.0.0.1" | sed "s^addr:^^g"')
  echo $privateIp >> /tmp/privateDataIps
  echo "Adding to nodes: "${privateIp}:${NAMEPREFIX}-dn$i.${ADJUSTED_NAME_SUFFIX}:${NAMEPREFIX}-dn$i " >> /tmp/initlog.out"
  NODES+=("${privateIp}:${NAMEPREFIX}-dn$i.${ADJUSTED_NAME_SUFFIX}:${NAMEPREFIX}-dn$i")
done

echo "finished dn private ip discovery >> /tmp/initlog.out"

# Converts a domain like machine.domain.com to domain.com by removing the machine name
NAMESUFFIX=`echo $NAMESUFFIX | sed 's/^[^.]*\.//'`

OIFS=$IFS
IFS=',';NODE_IPS="${NODES[*]}";IFS=$' \t\n'

IFS=','
for x in $NODE_IPS
do
  echo "x as member of NODE_IPS is: $x" >> /tmp/initlog.out
  line=$(echo "$x" | sed 's/:/ /' | sed 's/:/ /')
  echo "$line" >> /etc/hosts
done
IFS=${OIFS}

# Disable the need for a tty when running sudo and allow passwordless sudo for the admin user
sed -i '/Defaults[[:space:]]\+!*requiretty/s/^/#/' /etc/sudoers
echo "$ADMINUSER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Mount and format the attached disks base on node type
if [ "$NODETYPE" == "masternode" ]
then
  bash ./prepare-masternode-disks.sh
elif [ "$NODETYPE" == "datanode" ]
then
  bash ./prepare-datanode-disks.sh
else
  echo "#unknown type, default to datanode"
  bash ./prepare-datanode-disks.sh
fi

echo "Done preparing disks.  Now ls -la looks like this:"
ls -la /
# Create Impala scratch directory
numDataDirs=$(ls -la / | grep data | wc -l)
echo "numDataDirs:" $numDataDirs
let endLoopIter=(numDataDirs - 1)
for x in $(seq 0 $endLoopIter)
do 
  echo mkdir -p /data${x}/impala/scratch 
  mkdir -p /data${x}/impala/scratch
  chmod 777 /data${x}/impala/scratch
done

setenforce 0 >> /tmp/setenforce.out
cat /etc/selinux/config > /tmp/beforeSelinux.out
sed -i 's^SELINUX=enforcing^SELINUX=disabled^g' /etc/selinux/config || true
cat /etc/selinux/config > /tmp/afterSeLinux.out

/etc/init.d/iptables save
/etc/init.d/iptables stop
chkconfig iptables off

yum install -y ntp
service ntpd start
service ntpd status
chkconfig ntpd on

yum install -y microsoft-hyper-v

echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled
echo "echo never | tee -a /sys/kernel/mm/transparent_hugepage/enabled" | tee -a /etc/rc.local
echo vm.swappiness=1 | tee -a /etc/sysctl.conf
echo 1 | tee /proc/sys/vm/swappiness
ifconfig -a >> initialIfconfig.out; who -b >> initialRestart.out

echo net.ipv4.tcp_timestamps=0 >> /etc/sysctl.conf
echo net.ipv4.tcp_sack=1 >> /etc/sysctl.conf
echo net.core.rmem_max=4194304 >> /etc/sysctl.conf
echo net.core.wmem_max=4194304 >> /etc/sysctl.conf
echo net.core.rmem_default=4194304 >> /etc/sysctl.conf
echo net.core.wmem_default=4194304 >> /etc/sysctl.conf
echo net.core.optmem_max=4194304 >> /etc/sysctl.conf
echo net.ipv4.tcp_rmem="4096 87380 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_wmem="4096 65536 4194304" >> /etc/sysctl.conf
echo net.ipv4.tcp_low_latency=1 >> /etc/sysctl.conf
sed -i "s/defaults        1 1/defaults,noatime        0 0/" /etc/fstab

#use the key from the key vault as the SSH authorized key
mkdir /home/$ADMINUSER/.ssh
chown $ADMINUSER /home/$ADMINUSER/.ssh
chmod 700 /home/$ADMINUSER/.ssh

ssh-keygen -y -f /var/lib/waagent/*.prv > /home/$ADMINUSER/.ssh/authorized_keys
chown $ADMINUSER /home/$ADMINUSER/.ssh/authorized_keys
chmod 600 /home/$ADMINUSER/.ssh/authorized_keys

cp ~/.ssh/id_rsa /home/${ADMINUSER}/.ssh/


myhostname=`hostname`
fqdnstring=`python -c "import socket; print socket.getfqdn('$myhostname')"`
sed -i "s/.*HOSTNAME.*/HOSTNAME=${fqdnstring}/g" /etc/sysconfig/network
/etc/init.d/network restart

# Add systest credential to authorized hosts list
echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5Zx7QmkQF+YIYxZ3z7KeD/CJAkzijm49QHQDIA0AnY2rLqFj09ZvKKFPVh+wnEU4PhKMVAGlBBjlItumxwx90BTstgnQqXK09GR4KBQAq2vpwUz4prkllj84wMrBlIAWcWXSJxO5zI4atcIDBnUw+W0dfgjMzgKAfnrg45xT+rMzQw41t1rtcURO3VgmvDHt1xAAZ/Zo5XjguOhIhdR9IOyTwyowHHcm2IGeuLuOeupAhcQc+7tEX+Jj8fxs9+0tbV4HYG3kM1Xe2r4kq5OPtM4YVOHRvqwmjmClR+i21iAs3EUWVRHI1KYywrULak7u01Y6PnI3pJ7pcO4HchgSR' >> /home/$ADMINUSER/.ssh/authorized_keys

#disable password authentication in ssh
#sed -i "s/UsePAM\s*yes/UsePAM no/" /etc/ssh/sshd_config
#sed -i "s/PasswordAuthentication\s*yes/PasswordAuthentication no/" /etc/ssh/sshd_config
#/etc/init.d/sshd restart
