#!/bin/sh
SLOT_DIR="/boinc_slot_dir"
RUN_DIR="/scratch"
WEB_DIR="/var/www/lighttpd"

rm -rf ${RUN_DIR}
mkdir -p ${RUN_DIR}

# Define the repositories needed
cat <<EOF > /etc/cvmfs/default.local
CVMFS_REPOSITORIES="grid,sft,alice"
EOF

# Check if CVMFS is mounted via the host
cvmfs_config probe >/dev/null
RET_VAL=$?

# Try to mount CVMFS in the container if not found on the host
if [ "${RET_VAL}" == 0 ]; then
    echo "Using CVMFS on the host." 
else
    echo 'CVMFS_HTTP_PROXY="DIRECT"' >> /etc/cvmfs/default.local
    REPOS=$(grep "^CVMFS_REPOSITORIES" /etc/cvmfs/default.local | cut -d'"' -f2 | tr ',' ' ')

    for repo in $REPOS; do
        mkdir -p "/cvmfs/$repo.cern.ch"
        mount -t cvmfs "$repo.cern.ch" "/cvmfs/$repo.cern.ch"
    done

    cvmfs_config probe >/dev/null || { echo "Mounting CMVFS failed." >&2; exit 1; }
    echo "Mounted CVMFS in the container."
fi

# Install Copilot
cp /cvmfs/grid.cern.ch/vc/containers/cernvm/copilot-config /usr/bin/copilot-config
sed -i "s#/shared/html/job#${WEB_DIR}#" /usr/bin/copilot-config

# Setup Web App
rm -rf ${WEB_DIR}/*
cp /cvmfs/grid.cern.ch/vc/etc/html/index.html ${WEB_DIR}
/bin/tar zxvf /cvmfs/grid.cern.ch/vc/var/www/t4t-webapp.tgz -C ${WEB_DIR} >/dev/null
rm -rf ${WEB_DIR}/job
ln -sf ${RUN_DIR}/job ${WEB_DIR}
mkdir ${WEB_DIR}/logs
chown -R boinc:boinc ${WEB_DIR}/logs
chmod a+r ${WEB_DIR}/logs
mkdir  /run/lighttpd/

cat <<EOF >> /etc/lighttpd/lighttpd.conf
server.bind = "0.0.0.0"
server.modules += ( "mod_dirlisting" )
dir-listing.activate = "enable"
EOF

lighttpd -D -f /etc/lighttpd/lighttpd.conf &

# Copy the input file to the working directory
cp -r ${SLOT_DIR}/input ${RUN_DIR}
chown -R boinc:boinc ${RUN_DIR}
chmod a+x ${RUN_DIR}/input

# Write the log file to the Web location and slot directory
tee ${WEB_DIR}/logs/running.log > ${SLOT_DIR}/runRivet.log 2> /dev/null \
    < <(stdbuf -oL tail -F ${RUN_DIR}/runRivet.log 2> /dev/null) &

# Run the job
/sbin/runuser - boinc -c "cd ${RUN_DIR} && ./input 2>&1"

# Print the first line of the log
head -n 2 ${RUN_DIR}/runRivet.log >&2

# Create the output file
if [ -f ${RUN_DIR}/runRivet.log ]; then
    # To be compatible with the output template for vbox apps
    mkdir ${SLOT_DIR}/shared
    tar -zcf ${SLOT_DIR}/shared/output.tgz  --exclude bin --exclude runPost.sh  \
        --exclude html --exclude init_data.xml -C ${RUN_DIR} . >/dev/null
else
    echo "No output found."
fi

# Check for the output file
if [ -f ${SLOT_DIR}/shared/output.tgz ]; then
    rm -rf ${RUN_DIR}
    echo "Job Finished"
else
    rm -rf ${RUN_DIR}
    echo "Job Failed"
fi
