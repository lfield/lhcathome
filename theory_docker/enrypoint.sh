#!/bin/bash

boinc_slot="$(pwd)"
shared="${boinc_slot}/shared"
boinc_home="/home/boinc"
web_dir="/var/www/lighttpd"

# Set up CVMFS
cat <<EOF > /etc/cvmfs/default.local
CVMFS_REPOSITORIES="grid,cernvm-prod,sft,alice"
EOF

cvmfs_config probe

# Install Copilot
cp /cvmfs/grid.cern.ch/vc/containers/cernvm/copilot-config /usr/bin/copilot-config
sed -i "s#/shared/html/job#${boinc_home}/job#" /usr/bin/copilot-config

# Setup Web App
rm -rf ${web_dir}/*
cp /cvmfs/grid.cern.ch/vc/etc/html/index.html ${web_dir}
/bin/tar -zxvf /cvmfs/grid.cern.ch/vc/var/www/t4t-webapp.tgz -C ${web_dir}
rm -rf ${web_dir}/job
ln -sf ${boinc_home}/job ${web_dir}
mkdir ${web_dir}/logs
chown -R boinc:boinc ${web_dir}/logs
chmod a+r ${web_dir}/logs
mkdir /run/lighttpd/

cat <<EOF >> /etc/lighttpd/lighttpd.conf
server.bind = "0.0.0.0"
server.modules += ( "mod_dirlisting" )
dir-listing.activate = "enable"
EOF

lighttpd -D -f /etc/lighttpd/lighttpd.conf &

rm -rf ${boinc_home}/*
cp -r ${boinc_slot}/input ${boinc_home}
chown -R boinc:boinc ${boinc_home}
chmod a+x ${boinc_home}/input

tee ${web_dir}/logs/running.log ${boinc_slot}/running.log \
    < <(stdbuf -oL tail -F ${boinc_home}/runRivet.log 2> /dev/null) > /dev/null 2>&1 &

/sbin/runuser - boinc -c "${boinc_home}/input 2>&1"

head -n 20 ${boinc_home}/runRivet.log >&2
if [[ -f ${boinc_home}/runRivet.log ]]; then
    # To be compatable with the output template
    mkdir ${shared}/
    /bin/tar -zcf ${shared}/output.tgz \
        --exclude bin --exclude runPost.sh --exclude html \
        --exclude init_data.xml -C ${boinc_home} .
else
    echo "No output found."
fi

if [[ -f ${shared}/output.tgz ]]; then
    rm -rf ${boinc_home}/*
    echo "Job Finished"
else
    rm -rf ${boinc_home}/*
    echo "Job Failed"
fi
