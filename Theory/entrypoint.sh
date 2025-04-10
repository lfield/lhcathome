#!/bin/bash

function boinc_shutdown {
    # usage: boinc_shutdown exit_code shutdown_delay
    # Forward exit codes to BOINC.
    # Exit codes known by BOINC
    # 206: EXIT_INIT_FAILURE
    # 208: EXIT_SUB_TASK_FAILURE
    #
    # Modern multi CPU computer can burn lots of tasks within just a few minutes.
    # A sleep reduces the load on the client as well as on the server.
    # It also softens the negative impact of failing batches to work fetch calculation.
    # for prod: '-i 787-983'
    # for dev/local : '-i 23-37'
    #
    exit_code=$1
    echo "boinc_shutdown called with exit code $exit_code" | tee ${OUT_DIR}/shutdown
    echo "sd_delay: $2"

    if grep -m1 '<project_dir>.*/projects/lhcathome\.cern\.ch_lhcathome' \
        "${SLOT_DIR}/init_data.xml" > /dev/null 2>&1; then
        sleep $2
    else
        # lhcathomedev and standalone
        exit_code=0
        sleep $(shuf -n 1 -i 23-37)
    fi

    # add 2 blank lines to separate stdout and stderr in stderr.txt
    echo -e "\n"
    exit $exit_code
}

function print_hint_header {
cat << EOF
${separator}
                        IMPORTANT HINT(S)!
${separator}
CVMFS server: ${cvmfs_excerpt[1]}
CVMFS proxy:  ${cvmfs_excerpt[2]}
EOF
}

function print_hint_footer {
    if (( proxy_links_required == 1 )); then
cat << EOF
More info how to configure a local HTTP proxy:
https://lhcathome.cern.ch/lhcathome/forum_thread.php?id=5473
https://lhcathome.cern.ch/lhcathome/forum_thread.php?id=5474
EOF
    fi
    if (( cvmfs_links_required == 1 )); then
cat << EOF
More info how to configure CVMFS:
https://lhcathome.cern.ch/lhcathome/forum_thread.php?id=5594
https://lhcathome.cern.ch/lhcathome/forum_thread.php?id=5595
EOF
    fi
cat << EOF
${separator}
EOF
}

function log_cvmfs_excerpt {
    # prints to the logfile whether openhtc.io and/or a local proxy is used
    #
    cvmfs_excerpt=($(cut -d ' ' -f 1,17,18 < <(tail -n1 < <(cvmfs_config stat grid.cern.ch))))
    cvmfs_excerpt[1]="${cvmfs_excerpt[1]%"/cvmfs/grid.cern.ch"}"
    output="Excerpt from \"cvmfs_config stat\": VERSION HOST PROXY
${cvmfs_excerpt[0]} ${cvmfs_excerpt[1]} ${cvmfs_excerpt[2]}"
    echo "${output}"

    # Print hints whether the CVMFS configuration should be revised
    #
    proxy_links_required=0
    cvmfs_links_required=0
    output=""
    separator="******************************************************************"

    if ! grep -m1 'openhtc\.io' <<<"${cvmfs_excerpt[1]}" > /dev/null 2>&1; then
        if [ ${cvmfs_excerpt[2]} == "DIRECT" ]; then
            output="$(print_hint_header)
Stratum-1 server found.
Stratum-1 servers must not be used directly.
Instead, set up a local HTTP proxy.
Also add \"CVMFS_USE_CDN=yes\" to \"/etc/cvmfs/default.local\".
"
            proxy_links_required=1
            cvmfs_links_required=1
            output="${output}$(print_hint_footer)"
            echo "${output}"
        else
            output="$(print_hint_header)
Stratum-1 server found.
To improve the CVMFS efficiency please add
\"CVMFS_USE_CDN=yes\" to \"/etc/cvmfs/default.local\".
"
            cvmfs_links_required=1
            output="${output}$(print_hint_footer)"
            echo "${output}"
        fi
    fi

    if grep -m1 'openhtc\.io' <<<"${cvmfs_excerpt[1]}" > /dev/null 2>&1 &&
        [ ${cvmfs_excerpt[2]} == "DIRECT" ]; then
        if [ $1 == "local" ]; then
            output="$(print_hint_header)
No local HTTP proxy found.
With this setup concurrently running containers can't share
a common CVMFS cache. A local HTTP proxy is therefore
highly recommended.
"
            proxy_links_required=1
            output="${output}$(print_hint_footer)"
            echo "${output}"
        else
            output="$(print_hint_header)
No local HTTP proxy found.
A local HTTP proxy is recommended to improve the CVMFS efficiency.
"
            proxy_links_required=1
            output="${output}$(print_hint_footer)"
            echo "${output}"
        fi
    fi
}

# Check if we are in a container or VM
if [ -e "/boinc_slot_dir" ]; then
    SLOT_DIR="/boinc_slot_dir"
    # To be compatible with the output template for vbox apps
    OUT_DIR=${SLOT_DIR}/shared
    mkdir -p ${OUT_DIR}
    # Define the repositories needed
    cat <<EOF > /etc/cvmfs/default.local
CVMFS_REPOSITORIES="grid.cern.ch,sft.cern.ch,alice.cern.ch"
EOF
else
    SLOT_DIR="/shared"
    OUT_DIR=${SLOT_DIR}
fi

RUN_DIR="/scratch"
WEB_DIR="/var/www/lighttpd"

rm -rf ${RUN_DIR}
mkdir -p ${RUN_DIR}

# Check for a local proxy
if xmllint ${SLOT_DIR}/init_data.xml | grep "<use_http_proxy/>" >/dev/null 2>&1
then 
    PROXY_HOST="$(xmllint ${SLOT_DIR}/init_data.xml | grep "<http_server_name" | cut -d ">" -f2 | cut -d "<" -f1)"
    PROXY_HOST="${PROXY_HOST#"http://"}"    # remove the protocol prefix if it exists.
    PROXY_PORT="$(xmllint ${SLOT_DIR}/init_data.xml | grep "<http_server_port" | cut -d ">" -f2 | cut -d "<" -f1)"
    
    if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]
    then
        echo "Detected local proxy http://${PROXY_HOST}:${PROXY_PORT} in init_data.xml"
        echo "Testing connection to ${PROXY_HOST} on port ${PROXY_PORT}"
        nc -z -v -w 3 ${PROXY_HOST} ${PROXY_PORT} >/tmp/stdout 2>/tmp/stderr
        result=$?
        if [ ${result} -gt 0 ]; then
	    echo "$(cat /tmp/stdout /tmp/stderr)"
            echo "Local proxy can't be contacted and will be ignored"
            unset PROXY_HOST
            unset PROXY_PORT
	else
	    echo "Local proxy successfully contacted"
        fi
    fi
fi

# Test host's CVMFS first.
# Avoid CVMFS inside the container is accidentally being used
#
suffix="$(mktemp -u XXXXXXXX)"
cmd="$(command -v cvmfs_config)"
[ ! -z "${cmd}" ] && rename "${cmd}" "${cmd}${suffix}" "${cmd}" 2> /dev/null
dir="/etc/cvmfs"
[ -d "${dir}" ] && rename "${dir}/" "${dir}${suffix}/" "${dir}/" 2> /dev/null

# used as '$2' in 'boinc_shutdown'
sd_delay=$(shuf -n 1 -i 787-983)

if [ -d "/cvmfs/cvmfs-config.cern.ch/etc" ]; then
    # This succeeds if
    # - the repo is already mounted by the host's CVMFS
    # - the host's autofs mounts it now for the test
    # Test cvmfs-config.cern.ch since it must be mounted prior to any other CERN repo.
    # Reactivate 'cvmfs_config' to ensure 'log_cvmfs_excerpt' can be run.
    #
    [ ! -z "${cmd}" ] && rename "${cmd}${suffix}" "${cmd}" "${cmd}${suffix}" 2> /dev/null
    [ -d "${dir}${suffix}" ] && rename "${dir}${suffix}/" "${dir}/" "${dir}${suffix}/" 2> /dev/null
    echo "Using CVMFS on the host."
    if [ ${SLOT_DIR} == "/shared" ]; then
	# We are in a VM so check for a local proxy
	echo "Running in a VM"
	if [ ! -z "${PROXY_HOST}" ]; then
	    # Configure CVMFS to use the local proxy
	    sed -i '/CVMFS_HTTP_PROXY=/d' /etc/cvmfs/default.local
	    echo "CVMFS_HTTP_PROXY=\"http://${PROXY_HOST}:${PROXY_PORT};DIRECT\"" >> /etc/cvmfs/default.local
	    cvmfs_config reload > /dev/null
        fi
    fi
    REPOS="cvmfs-config.cern.ch $(grep "^CVMFS_REPOSITORIES" /etc/cvmfs/default.local | cut -d'"' -f2 | tr ',' ' ')"
        # 'cvmfs-config' MUST be the first!
        #
    for repo in $REPOS; do
        cvmfs_config probe $repo >/dev/null || \
            { echo "Probing '$repo' failed." >&2; cvmfs_probe_failed=1; }
    done

    (( cvmfs_probe_failed == 1 )) && boinc_shutdown 206 ${sd_delay}
    log_cvmfs_excerpt host
else
    # CVMFS is not available on the host.
    # Reactivate 'cvmfs_config' and '/etc/cvmfs',
    # then try to mount CVMFS in the container.
    #
    [ ! -z "${cmd}" ] && rename "${cmd}${suffix}" "${cmd}" "${cmd}${suffix}" 2> /dev/null
    [ -d "${dir}${suffix}" ] && rename "${dir}${suffix}/" "${dir}/" "${dir}${suffix}/" 2> /dev/null
    echo "Using CVMFS in the container."

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

    REPOS="cvmfs-config.cern.ch $(grep "^CVMFS_REPOSITORIES" /etc/cvmfs/default.local | cut -d'"' -f2 | tr ',' ' ')"
        # 'cvmfs-config' MUST be the first!
        #
    for repo in $REPOS; do
        mkdir -p "/cvmfs/$repo"
        mount -t cvmfs -o noatime,_netdev,nodev "$repo" "/cvmfs/$repo" > /dev/null
        cvmfs_config probe $repo >/dev/null || \
            { echo "Probing '$repo' failed." >&2; cvmfs_probe_failed=1; }
    done

    (( cvmfs_probe_failed == 1 )) && boinc_shutdown 206 ${sd_delay}
    log_cvmfs_excerpt local
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
mkdir -p  /run/lighttpd/

cat <<EOF > /etc/lighttpd/conf.d/dirlisting.conf
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
    tar -zcf ${OUT_DIR}/output.tgz  --exclude bin --exclude runPost.sh  \
        --exclude html --exclude init_data.xml -C ${RUN_DIR} . >/dev/null
else
    echo "No output found."
fi

logfile="${SLOT_DIR}/entrypoint.log"

if [ -f "${logfile}" ]; then
    # flush write buffer
    sync -d "${logfile}"
    if grep --line-buffered -m1 'job: run exitcode=0' \
        <(stdbuf -oL tac "${logfile}") > /dev/null 2>&1; then
        # If 'job run' succeeds then exit without delay.
        #
        sd_delay=0
    else
        # Even if 'job run' fails it can be a success at BOINC level.
        # Only exit with delay if they are short runners.
        #
        job_cpuusage=$(grep --line-buffered -Pom1 'job: cpuusage=\K[0-9]+' \
            <(stdbuf -oL tac "${logfile}") 2> /dev/null)
        if [ ! -z "${job_cpuusage}" ]; then
            if (( sd_delay <= job_cpuusage )); then
                sd_delay=0
            else
                sd_delay=$(( sd_delay - job_cpuusage ))
            fi
        fi
    fi
fi

# Check for the output file
if [ -f ${OUT_DIR}/output.tgz ]; then
    echo "Job Finished"
    boinc_shutdown 0 ${sd_delay}
else
    echo "Job Failed"
    # should be 208 EXIT_SUB_TASK_FAILURE
    # for now '0' since docker wrapper can't forward those error codes
    #
    boinc_shutdown 0 ${sd_delay}
fi
