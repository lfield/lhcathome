#!/bin/bash
rm -f /sbin/shutdown
rm -f /var/lib/cloud/instance/user-data.txt 
rm -f /var/lib/cloud/instance/user-data.txt.i
rm -f /var/lib/cloud/instance/cloud-config.txt
rpm -e openssh-server
dnf clean all