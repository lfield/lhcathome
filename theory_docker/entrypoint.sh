#!/bin/sh

function boinc_shutdown {
    # Forward exit codes to BOINC.
    # Exit codes known by BOINC
    # 206: EXIT_INIT_FAILURE
    # 208: EXIT_SUB_TASK_FAILURE
    #
    # Modern multi CPU computer can burn lots of tasks within just a few minutes.
    # A sleep reduces the load on the client as well as on the server.
    # It also softens the negative impact of failing batches to work fetch calculation.
    # for dev : '-i 17-29'
    # for prod: '-i 720-900'
    #
    sleep $(shuf -n 1 -i 17-29)
    exit $1
}

SLOT_DIR="/boinc_slot_dir"
RUN_DIR="/scratch"
WEB_DIR="/var/www/lighttpd"

rm -rf ${RUN_DIR}
mkdir -p ${RUN_DIR}

# Define the repositories needed
cat <<EOF > /etc/cvmfs/default.local
CVMFS_REPOSITORIES="grid,sft,alice"
EOF

# Test host's CVMFS first.
# Avoid CVMFS inside the container is accidentally being used
#
suffix="$(mktemp -u XXXXXXXX)"
cmd="$(command -v cvmfs_config)"
[ ! -z "${cmd}" ] && rename "${cmd}" "${cmd}${suffix}" "${cmd}" 2> /dev/null
dir="/etc/cvmfs"
[ -d "${dir}" ] && rename "${dir}/" "${dir}${suffix}/" "${dir}/" 2> /dev/null

if [ -d "/cvmfs/cvmfs-config.cern.ch/etc" ]; then
    # This succeeds if
    # - the repo is already mounted by the host's CVMFS
    # - the host's autofs mounts it now for the test
    # Test cvmfs-config.cern.ch since it must be mounted prior to any other CERN repo.
    #
    echo "Using CVMFS on the host."
else
    # CVMFS is not available on the host.
    # Reactivate 'cvmfs_config' and '/etc/cvmfs',
    # then try to mount CVMFS in the container.
    #
    [ ! -z "${cmd}" ] && rename "${cmd}${suffix}" "${cmd}" "${cmd}${suffix}" 2> /dev/null
    [ -d "${dir}${suffix}" ] && rename "${dir}${suffix}/" "${dir}/" "${dir}${suffix}/" 2> /dev/null

    # Complete the configuration
    #
    mkdir -p "/etc/cvmfs/config.d"
    echo 'CVMFS_CONFIG_REPO_REQUIRED=no' >> /etc/cvmfs/config.d/cvmfs-config.cern.ch.local

    mkdir -p "/etc/cvmfs/domain.d"
    echo 'CVMFS_CONFIG_REPO_REQUIRED=yes' >> /etc/cvmfs/domain.d/cern.ch.local

    if [ ! -z "${http_proxy}" ]; then
        # Use it if forwarded via docker environment.
        # It is highly recommended since in this branch the containers
        # do not share a common cache.
        #
        echo "CVMFS_HTTP_PROXY=\"${http_proxy};DIRECT\"" >> /etc/cvmfs/default.local
    else
        echo 'CVMFS_HTTP_PROXY="DIRECT"' >> /etc/cvmfs/default.local
    fi
    if [ ! -z "${CVMFS_USE_CDN}" ]; then
        # Use what is forwarded via docker environment.
        #
        echo "CVMFS_USE_CDN=${CVMFS_USE_CDN}" >> /etc/cvmfs/default.local
    else
        # preferred default to avoid hammering the stratum 1 servers
        #
        echo 'CVMFS_USE_CDN=yes' >> /etc/cvmfs/default.local
    fi

    REPOS="cvmfs-config $(grep "^CVMFS_REPOSITORIES" /etc/cvmfs/default.local | cut -d'"' -f2 | tr ',' ' ')"
        # 'cvmfs-config' MUST be the first!
        #
    for repo in $REPOS; do
        mkdir -p "/cvmfs/$repo.cern.ch"
        mount -t cvmfs -o noatime,_netdev,nodev "$repo.cern.ch" "/cvmfs/$repo.cern.ch"
        cvmfs_config probe $repo.cern.ch >/dev/null || \
            { echo "Mounting '$repo.cern.ch' failed." >&2; boinc_shutdown 206; }
    done

    cvmfs_config stat
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
    echo "Job Finished"
else
    echo "Job Failed"
    # EXIT_SUB_TASK_FAILURE
    boinc_shutdown 208
fi
