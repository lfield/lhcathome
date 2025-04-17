#!/bin/bash

# Define global variables.
#
RUN_DIR="/scratch"
WEB_DIR="/var/www/lighttpd"

# Define the repositories needed
# use CVMFS syntax like REPOS="grid,sft,oasis.opensciencegrid.org"
# Short names like 'grid' will automatically be expanded to
# FQRNs like 'grid.cern.ch'
# cvmfs-config will be added automatically
#
REPOS="alice,grid,sft"

function start_webserver {
    # prepare_tmpfs
    mkdir -p "${WEB_DIR}"
    rm -r "${WEB_DIR}/*" 2> /dev/null
    mount tmpfs -t tmpfs \
        -o nosuid,nodev,noexec,noatime \
        "${WEB_DIR}"
    chcon -R -h -t httpd_sys_content_t "${WEB_DIR}" > /dev/null 2>&1
    mkdir -p /run/lighttpd/

cat <<EOF >> /etc/lighttpd/lighttpd.conf
server.bind := "0.0.0.0"
server.modules += ( "mod_dirlisting" )
dir-listing.activate := "enable"
server.use-ipv6 := "disable"
EOF

    lighttpd -f /etc/lighttpd/lighttpd.conf > /dev/null 2>&1
}

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
    # Examples:
    # for prod: '-i 787-983'
    # for dev/local : '-i 23-37'
    #
    (( cvmfs_in_container == 1 )) && \
        df -h -t fuse --output=source,used,pcent,target --total
        # Print cvmfs usage statistics
        # Gives an impression how much data is downloaded/written.

    exit_code=$1
    echo "boinc_shutdown called with exit code $exit_code"

    if grep -m1 '<project_dir>.*lhcathome\.cern\.ch_lhcathome' \
        "${SLOT_DIR}/init_data.xml" > /dev/null 2>&1; then
        echo "sd_delay: $2"
        (( sd_delay != 0 )) && echo "ETA: $(date -d "+${sd_delay}seconds" +"%F %T %Z")"
        sleep $2
    else
        # lhcathomedev and standalone
        # even then lhcathomedev invalidates the task if the output file is missing
        #
        exit_code=0
        sleep $(shuf -n 1 -i 23-37)
    fi

    # add blank lines to separate stdout and stderr in stderr.txt
    echo
    rename "${out_filename}" "output" "${OUT_DIR}/${out_filename}.tgz" > /dev/null 2>&1
    echo "${exit_code}" > "${OUT_DIR}/shutdown"
    exit $exit_code
}

function get_wpad_from_lhchomeproxy {
    # requires 'dig' which is part of
    # the 'bind-utils' package
    # requires 'netcat' package
    #

    if ! command -v dig > /dev/null 2>&1; then
        echo "2" >"$lhchome_return"
        return 2
    fi

    # Balance load between cern.ch and fnal.gov
    if (( $(( RANDOM % 2 )) != 0 )); then
        wlcg_wpad_services=("lhchomeproxy.cern.ch" "lhchomeproxy.fnal.gov")
    else
        wlcg_wpad_services=("lhchomeproxy.fnal.gov" "lhchomeproxy.cern.ch")
    fi

    for wpad_service in "${wlcg_wpad_services[@]}"; do
        # IPv4 list
        ip_address_list=($(grep -E '^[0-9][.0-9]+$' \
            <(dig +short -t A ${wpad_service}.)))
        # IPv6 list
        for ip_v6 in $(grep ':' <(dig +short -t AAAA ${wpad_service}.)); do
            ip_address_list=(${ip_address_list[@]} "[${ip_v6}]")
        done

        for ip_address in "${ip_address_list[@]}"; do
            if curl -f -L -m 10 -s -o "$lhchome_wpad_tmp" \
                    --noproxy ${wpad_service} --resolve ${wpad_service}:80:${ip_address} \
                    "http://${wpad_service}/wpad.dat" && \
                grep -Eim1 '^[[:blank:]]*function[[:blank:]]+FindProxyForURL' \
                    "$lhchome_wpad_tmp" >/dev/null 2>&1; then
                # test against the location string that is
                # usually returned as part of the wpad.dat
                if grep -Ei '//[[:blank:]]+no[[:blank:]]+(org|squid)[[:blank:]]+found[[:blank:]]+' \
                    <(head -n1 "$lhchome_wpad_tmp") >/dev/null 2>&1; then
                    # non-WLCG sites will get DIRECT for openhtc.io and
                    # lhchomeproxy or 'NONE' for others
                    # keep that for fallback
                    echo "1" >"$lhchome_return"
                    return 1
                else
                    # WLCG sites will get proxies from here
                    # this can even be DIRECT
                    echo "0" >"$lhchome_return"
                    return 0
                fi
            fi
        done

    done

    echo "2" >"$lhchome_return"
    return 2
}

function get_wpad_from_grid_wpad {
    # requires 'dig' which is part of
    # the 'bind-utils' package
    #
    if ! command -v dig > /dev/null 2>&1; then
        echo "1" >"$grid_return"
        return 1
    fi

    # IPv4 list
    ip_address_list=($(grep -E '^[0-9][.0-9]+$' \
        <(dig +short +search -t A grid-wpad)))
    # IPv6 list
    for ip_v6 in $(grep ':' <(dig +short -t AAAA grid-wpad)); do
        ip_address_list=(${ip_address_list[@]} "[${ip_v6}]")
    done

    for ip_address in "${ip_address_list[@]}"; do
        if curl -f -L -m 10 -s -o "$grid_wpad_tmp" \
            --resolve grid-wpad:80:${ip_address} "http://grid-wpad/wpad.dat" && \
            grep -Eim1 '^[[:blank:]]*function[[:blank:]]+FindProxyForURL' \
                "$grid_wpad_tmp" >/dev/null 2>&1; then
            echo "0" >"$grid_return"
            return 0
        fi
    done

    echo "1" >"$grid_return"
    return 1
}

function get_proxy_from_environment {
    if [[ ! -z "${http_proxy_bak}" ]]; then

# Do not indent the heredoc EOF!
cat << EOF_LOCAL_WPAD_FILE_with_proxy >"$environment_wpad_tmp"
function FindProxyForURL(url, host) {
    return "PROXY http://${host}:${port}";
}
EOF_LOCAL_WPAD_FILE_with_proxy

        echo "0" >"$environment_return"
        return 0
    fi

    echo "1" >"$environment_return"
    return 1
}

function get_proxy_from_boinc {
    if [[ -e "${OUT_DIR}/init_data.xml" ]]; then
        init_data_linted="$(sed -n -e '/<proxy_info>/,/<\/proxy_info>/ p; /<\/proxy_info>/ q' \
            < <(xmllint "${OUT_DIR}/init_data.xml"))"

        # check, if BOINC has it's proxy enabled
        if grep -m1 '<use_http_proxy\/>' <<<"${init_data_linted}" >/dev/null 2>&1; then
            proxy_host="$(sed -ne '/<http_server_name>/ {s/^.*<http_server_name>\([^<]\+\).*/\1/p;q}' \
                <<< "${init_data_linted}")"
            proxy_host="${proxy_host#"http://"}"
                # remove the protocol prefix if it exists.
            proxy_port="$(sed -ne '/<http_server_port>/ {s/^.*<http_server_port>\([^<]\+\).*/\1/p;q}' \
                <<< "${init_data_linted}")"

            if [[ -n "$proxy_host" ]] && [[ -n "$proxy_port" ]]; then
                if nc -zw 5 "$proxy_host" "$proxy_port"; then

# Do not indent the heredoc EOF!
cat << EOF_BS_LOCAL_WPAD_FILE_with_proxy >"$boinc_wpad_tmp"
function FindProxyForURL(url, host) {
    return "PROXY http://${proxy_host}:${proxy_port}";
}
EOF_BS_LOCAL_WPAD_FILE_with_proxy

                    return 0
                else
                    return 1
                fi
            fi
        fi
    fi

    return 2
}

function set_simple_proxy {
    # At this point we have a valid wpad.dat in
    # $local_wpad_dat that can be used.
    # Commands like wget or curl don't understand
    # wpad and need a single proxy set via the environment.

    # If a proxy is already set, just test if it can be connected.

    unset proxy_new

    if [[ "$http_proxy" != "" ]]; then
        proxy_new="$http_proxy"
    else
        [[ "$HTTP_PROXY" != "" ]] && proxy_new="$HTTP_PROXY"
    fi

    if [[ "$proxy_new" != "" ]]; then
        # strip protocol prefix
        # split proxy_new into hostname and port
        # if no port is given, set port 80
        # run a basic network test
        proxy_new="${proxy_new#"http://"}"
        IFS=':' read -r -a proxy_new_arr <<< "$proxy_new"
        [[ "${proxy_new_arr[1]}" == "" ]] && proxy_new_arr[1]=80

        if nc -zw 5 ${proxy_new_arr[0]} ${proxy_new_arr[1]} >/dev/null 2>&1; then
            proxy_new="http://$proxy_new"
            export http_proxy="$proxy_new"
            export HTTP_PROXY="$proxy_new"
            export https_proxy="$proxy_new"
            export HTTPS_PROXY="$proxy_new"

            # all done
            return 0
        fi
    fi

    pactester_bin="/usr/bin/pactester"
    # packet not yet included

    if [[ -x "$pactester_bin" ]]; then
        # pactester never makes an internet request
        # http://example.com is used to get the fallback proxy from a wpad.dat
        # the output looks like this
        # PROXY http://ca-proxy-atlas.cern.ch:3128; PROXY http://cvmfsbproxy.cern.ch:3126; ...
        # or like this
        # PROXY http://ca-proxy.cern.ch:3128
        # or like this
        # DIRECT
        backup_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
        export LD_LIBRARY_PATH="/usr/lib:$LD_LIBRARY_PATH"
        my_pacstring="$($pactester_bin -p $local_wpad_dat -u http://example.com 2>/dev/null)"
        export LD_LIBRARY_PATH="$backup_LD_LIBRARY_PATH"
        IFS='; ' read -r -a proxy_raw_arr <<< "$my_pacstring"

        for proxy_raw in "${proxy_raw_arr[@]}"; do
            proxy_new=$proxy_raw
            if [[ "$proxy_new" != "PROXY" ]] && \
               [[ "$proxy_new" != "DIRECT" ]] && \
               [[ "$proxy_new" != "NONE" ]] && \
               grep -iv 'lhchomeproxy\.' <<< "$proxy_new" >/dev/null 2>&1; then
                # lhchomeproxy.{cern.ch|fnal.gov} must be excluded
                # strip protocol prefix
                # split proxy_new into hostname and port
                # if no port is given, set port 80
                # run a basic network test
                proxy_new="${proxy_new#"http://"}"
                IFS=':' read -r -a proxy_new_arr <<< "$proxy_new"
                [[ "${proxy_new_arr[1]}" == "" ]] && proxy_new_arr[1]=80

                if nc -zw 5 ${proxy_new_arr[0]} ${proxy_new_arr[1]} >/dev/null 2>&1; then
                    proxy_new="http://$proxy_new"
                    export http_proxy="$proxy_new"
                    export HTTP_PROXY="$proxy_new"
                    export https_proxy="$proxy_new"
                    export HTTPS_PROXY="$proxy_new"

                    # all done
                    return 0
                fi
            fi
        done
    fi

    # Can't identify or connect to a proxy

    unset http_proxy=
    unset HTTP_PROXY=
    unset https_proxy=
    unset HTTPS_PROXY=

    return 0
}

function create_local_wpad {
    my_tmp_dir="$(mktemp -d)"
    chmod a+rwx ${my_tmp_dir}
    local_wpad_dat="${WEB_DIR}/wpad.dat"

    pids=""
    # Contact lhchomeproxy to allow monitoring
    # no matter which proxy is used at the end.
    lhchome_wpad_tmp="${my_tmp_dir}/lhchome_wpad"
    lhchome_return="${my_tmp_dir}/lhchome_return"
    get_wpad_from_lhchomeproxy &
    pids="${pids} $!"

    # Try to get a wpad file from grid-wpad.
    # This generic source needs to be set up by a site admin.
    grid_wpad_tmp="${my_tmp_dir}/grid_wpad"
    grid_return="${my_tmp_dir}/grid_return"
    get_wpad_from_grid_wpad &
    pids="${pids} $!"

    # Try to get a proxy via environment variable.
    environment_wpad_tmp="${my_tmp_dir}/environment_wpad"
    environment_return="${my_tmp_dir}/environment_return"
    get_proxy_from_environment &
    pids="${pids} $!"

    # Try to get a proxy from the BOINC client.
    boinc_wpad_tmp="${my_tmp_dir}/boinc_wpad"
    get_proxy_from_boinc
    ret_boinc_proxy="$?"

    for pid in ${pids}; do
        wait ${pid}
    done

    ret_lhchomeproxy=$(cat "$lhchome_return")
    ret_grid_wpad=$(cat "$grid_return")
    ret_environment=$(cat "$environment_return")

    (( ret_lhchomeproxy == 2 )) && \
        echo "Could not download a wpad.dat from lhchomeproxy.{cern.ch|fnal.gov}"

    # wait until the local webserver is up
    if ! curl --connect-timeout 2 -m 10 --retry 3 --retry-all-errors \
        -s --noproxy localhost http://localhost/ > /dev/null 2>&1; then
        echo "Local webserver did not start."
        boinc_shutdown 206 ${sd_delay}
    fi

    # prefer proxies set by grid-wpad
    if (( ret_grid_wpad == 0 )); then
        cat "$grid_wpad_tmp" >"$local_wpad_dat"
        echo "Got a wpad.dat from grid-wpad
Will use proxies from there for CVMFS and Frontier"
        rm -frd "$my_tmp_dir" &

        #set_simple_proxy
        return 0
    fi

    if (( ret_lhchomeproxy == 0 )); then
        cat "$lhchome_wpad_tmp" >"$local_wpad_dat"
        echo "Got a wpad.dat from lhchomeproxy.{cern.ch|fnal.gov}
Will use proxies from there for CVMFS and Frontier"
        rm -frd "$my_tmp_dir" &

        #set_simple_proxy
        return 0
    fi

    # If set and can be contacted
    # use the environment proxy
    if (( ret_environment == 0 )); then
        cat "$environment_wpad_tmp" >"$local_wpad_dat"
        echo "Got a proxy from the local environment
Will use it for CVMFS and Frontier"
        rm -frd "$my_tmp_dir" &

        #set_simple_proxy
        return 0
    fi

    # If no proxy is present yet, check if BOINC has one set.
    if (( ret_boinc_proxy == 0 )); then
        cat "$boinc_wpad_tmp" >"$local_wpad_dat"
        echo "Got a proxy from the local BOINC client
Will use it for CVMFS and Frontier"
        rm -frd "$my_tmp_dir" &

        #set_simple_proxy
        return 0
    fi

    (( ret_boinc_proxy == 1 )) && \
        echo "Proxy ${proxy_host}:${proxy_port} is set by BOINC but can't be contacted"

    # Use non-WLCG reply from lhchomeproxy or generic DIRECT if other methods fail
    echo "Could not find a local HTTP proxy
CVMFS and Frontier will have to use DIRECT connections
This makes the application less efficient
It also puts higher load on the project servers
Setting up a local HTTP proxy is highly recommended
Advice can be found in the project forum"

    if (( ret_lhchomeproxy == 1 )); then
        cat "$lhchome_wpad_tmp" >"$local_wpad_dat"
        rm -frd "$my_tmp_dir" &

        #set_simple_proxy
        return 0
    fi

    rm -frd "$my_tmp_dir" &

# Do not indent the heredoc EOF!
cat << EOF_BS_LOCAL_WPAD_FILE_with_DIRECT >"$local_wpad_dat"
function FindProxyForURL(url, host) {
    return "DIRECT";
}
EOF_BS_LOCAL_WPAD_FILE_with_DIRECT

    # Can't identify or connect to a proxy
    # run it to clear the environment proxy
    #set_simple_proxy
    return 0
}

function prepare_tmpfs {
    # Evaluate environment variable to decide where tmpfs should be used.
    # Since tmpfs uses physical RAM it is usually
    # much faster than disks, even SSDs.
    # If all physical RAM is used up it automatically pages to disk.
    # This should be monitored and the tmpfs option should only
    # be enabled on computers with enough RAM.
    #
    case "${lhc_theory_use_tmpfs}" in
      # evaluate case insensitive for cvmfs, all, true or yes
      #
      [cC][vV][mM][fF][sS]| \
      [aA][lL][lL]| \
      [tT][rR][uU][eE]| \
      [yY][eE][sS])
        # Mount the CVMFS cache as tmpfs to avoid lots of disk writes.
        # As of writing this each task typically
        # downloads 1 GB within the first few minutes.
        # This expands to 2 GB on disk.
        #
        if [[ $1 == "cvmfs" ]]; then
            mount tmpfs -t tmpfs \
                -o nosuid,nodev,noexec,noatime,size=${cvmfs_quota}m,uid=cvmfs,gid=cvmfs \
                "${cvmfs_cache_base}/$2"
        fi
        ;;&
      # evaluate case insensitive for app, all, true or yes
      #
      [aA][pP][pP]| \
      [aA][lL][lL]| \
      [tT][rR][uU][eE]| \
      [yY][eE][sS])
        # how much data is written depends on the scientific app
        #
        if [[ $1 == "rundir" ]]; then
            mount tmpfs -t tmpfs \
                -o nosuid,nodev,noatime,size=90%,uid=boinc,gid=boinc \
                "${RUN_DIR}"
        fi
        ;;
    esac
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
    cvmfs_excerpt=($(cut -d ' ' -f 1,17,18 \
       < <(tail -n1 \
       < <(cvmfs_config stat cvmfs-config.cern.ch))))
    cvmfs_excerpt[1]="${cvmfs_excerpt[1]%"/cvmfs/cvmfs-config.cern.ch"}"
    echo "Excerpt from \"cvmfs_config stat\":
$(column --table -N VERSION,HOST,PROXY \
<<< "${cvmfs_excerpt[0]} ${cvmfs_excerpt[1]} ${cvmfs_excerpt[2]}")"

    # Print hints whether the CVMFS configuration should be revised
    #
    proxy_links_required=0
    cvmfs_links_required=0
    output=""

    if ! grep -m1 'openhtc\.io' <<<"${cvmfs_excerpt[1]}" > /dev/null 2>&1; then
        if [[ ${cvmfs_excerpt[2]} == "DIRECT" ]]; then
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
        [[ ${cvmfs_excerpt[2]} == "DIRECT" ]]; then
        if [[ $1 == "local" ]]; then
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

function probe_cvmfs_repos_aux {
    cvmfs_config probe "$1" >/dev/null 2>&1
    result="$?"
    echo "${result}" >"${my_tmp_dir}/result_probe_$1"

    # output from cvmfs_config probe can't be used directly as it prints results delayed
    if [[ "${result}" == "0" ]]; then
        echo "Probing /cvmfs/$1... OK" >"${my_tmp_dir}/message_probe_$1"
    else
        echo "Probing /cvmfs/$1... Failed!" >"${my_tmp_dir}/message_probe_$1"
    fi
}
# must be exported to be available for child shells
export -f probe_cvmfs_repos_aux

function probe_cvmfs_repos {
    my_umask="$(umask)"
    umask 077
    my_tmp_dir="$(mktemp -d)"
    umask "${my_umask}"

    echo "Probing CVMFS repositories ..."
    pids=""
    for repo in ${REPOS}; do
        probe_cvmfs_repos_aux "${repo}" &
        pids="${pids} $!"
    done

    for pid in ${pids}; do
        wait ${pid}
        # until all repos are processed
    done

    cat "${my_tmp_dir}/message_probe_"*
    if grep -v '^0$' <(cat "${my_tmp_dir}/result_probe_"* 2>&1) >/dev/null 2>&1; then
        echo "Probing CVMFS repositories failed"
        boinc_shutdown 206 ${sd_delay}
    fi

    # cleanup
    rm -frd "${my_tmp_dir}" &
}

################################
# End of function definitions. #
# Script starts here.          #
################################

if [[ -d "/boinc_slot_dir" ]]; then
    # we are in a container
    in_container=1
    SLOT_DIR="/boinc_slot_dir"
    OUT_DIR="${SLOT_DIR}/shared"
    # ensure this is present to write the log to
    mkdir -p "${OUT_DIR}"
else
    # we are in a vbox VM
    in_container=0
    SLOT_DIR="/shared"
    OUT_DIR="${SLOT_DIR}"
    #dnf install -y epel-release
    #dnf remove -y nmap-ncat
    #dnf install -y bind-utils netcat
fi

separator="******************************************************************"

rm -frd "${RUN_DIR}" &
pid_clean_rundir=$!

cvmfs_in_container=0
# used as '$2' in 'boinc_shutdown'
sd_delay=$(shuf -n 1 -i 787-983)

start_webserver &

# Backup environment proxy
# to avoid conficts with CVMFS setup.
# Restore it later
#
if [[ ! -z "${http_proxy}" ]]; then
    # sanitize and test connection
    http_proxy_bak="${http_proxy#"http://"}"
    host="$(sed 's/:.*//' <<< "${http_proxy_bak}")"
    port="$(sed 's/^.*://' <<< "${http_proxy_bak}")"
    http_proxy_bak="http://${http_proxy_bak}"

    # unset now
    # will be restored later
    unset http_proxy

    if ! nc -zw 5 "${host}" "${port}" > /dev/null 2>&1; then
        echo "Environment proxy '${http_proxy_bak}' set but can't be connected"
        unset http_proxy_bak
    fi
fi

create_local_wpad &
wpad_pid=$!

# replace delimiters with ' '
REPOS="${REPOS//,/ }"

# expand to FQRNs
repos=""
for repo in ${REPOS}; do
    grep '\.' <<< "${repo}" > /dev/null 2>&1 || \
        repo="${repo}.cern.ch"
    repos="${repos} ${repo}"
done
# keep space separated list
REPOS="${repos}"

# strip leading ' '
repos="${repos#" "}"
# Add expanded repos to CVMFS configuration.
# Separated by ','. By intention without cvmfs-config.cern.ch.
echo "CVMFS_REPOSITORIES=\"${repos// /,}\"" >> /etc/cvmfs/default.local

# Add cvmfs-config.cern.ch
REPOS="cvmfs-config.cern.ch${REPOS}"

# Test host's CVMFS first.
# Avoid CVMFS inside the container is accidentally being used
#
suffix="$(mktemp -u XXXXXXXX)"
cmd="$(command -v cvmfs_config)"
[[ ! -z "${cmd}" ]] && \
    rename "${cmd}" "${cmd}${suffix}" "${cmd}" 2> /dev/null
dir="/etc/cvmfs"
[[ -d "${dir}" ]] && \
    rename "${dir}/" "${dir}${suffix}/" "${dir}/" 2> /dev/null

wait ${wpad_pid}

# only for debug
#ls -dhal ${WEB_DIR}
#ls -hal ${WEB_DIR}
#cat ${WEB_DIR}/wpad.dat
#chmod a+r ${WEB_DIR}/wpad.dat
curl -s -m 5 -o ${OUT_DIR}/wpad.dat http://localhost/wpad.dat


if (( in_container )) && \
    [[ -d "/cvmfs/cvmfs-config.cern.ch/etc" ]]; then
    # This succeeds if
    # - the repo is already mounted by the host's CVMFS
    # - the host's autofs mounts it now for the test
    # Test cvmfs-config.cern.ch since it must be mounted prior to any other CERN repo.
    # Reactivate 'cvmfs_config'.
    #
    echo "Using CVMFS on the host."
    [[ ! -z "${cmd}" ]] && \
        rename "${cmd}${suffix}" "${cmd}" "${cmd}${suffix}" 2> /dev/null
    [[ -d "${dir}${suffix}" ]] && \
        rename "${dir}${suffix}/" "${dir}/" "${dir}${suffix}/" 2> /dev/null
    probe_cvmfs_repos
    log_cvmfs_excerpt host
else
    # CVMFS is not available on the host.
    # Reactivate 'cvmfs_config' and '/etc/cvmfs',
    # then try to mount CVMFS in the container.
    #
    echo "Using custom CVMFS."

    [[ ! -z "${cmd}" ]] && \
        rename "${cmd}${suffix}" "${cmd}" "${cmd}${suffix}" 2> /dev/null
    [[ -d "${dir}${suffix}" ]] && \
        rename "${dir}${suffix}/" "${dir}/" "${dir}${suffix}/" 2> /dev/null

    # Complete the configuration
    #
    mkdir -p "/etc/cvmfs/config.d"
    echo 'CVMFS_CONFIG_REPO_REQUIRED=no' >> /etc/cvmfs/config.d/cvmfs-config.cern.ch.local

    mkdir -p "/etc/cvmfs/domain.d"
    echo 'CVMFS_CONFIG_REPO_REQUIRED=yes' >> /etc/cvmfs/domain.d/cern.ch.local

    config_file="/etc/cvmfs/default.local"
    if [[ ! -z "${CVMFS_USE_CDN}" ]]; then
        # Use what is forwarded via docker environment.
        echo "CVMFS_USE_CDN=${CVMFS_USE_CDN}" >> "${config_file}"
    else
        # preferred default to avoid hammering the stratum 1 servers
        echo 'CVMFS_USE_CDN=yes' >> "${config_file}"
    fi

    # Using a local HTTP proxy is highly recommended
    # since in this branch the containers
    # do not share a common cache.
    #
    if [[ ! -z "${CVMFS_HTTP_PROXY}" ]]; then
        # set via environment following the CVMFS rules
        grep -E ';DIRECT$' <<< "${CVMFS_HTTP_PROXY}" || \
            CVMFS_HTTP_PROXY="${CVMFS_HTTP_PROXY};DIRECT"
        echo "CVMFS_HTTP_PROXY=\"${CVMFS_HTTP_PROXY}\"" >> "${config_file}"
        echo "CVMFS_PROXY_SHARD=yes" >> "${config_file}"
    elif [[ -f "${WEB_DIR}/wpad.dat" ]]; then
        echo "CVMFS_HTTP_PROXY=\"auto;DIRECT\"" >> "${config_file}"
        echo "CVMFS_PAC_URLS=\"http://localhost/wpad.dat\"" >> "${config_file}"
    else
        echo "Proxy configuration failed."
        boinc_shutdown 206 ${sd_delay}
    fi

    if (( in_container )); then
        cvmfs_in_container=1
        # To allow separate df statistics per repo
        echo "CVMFS_SHARED_CACHE=no" >> "${config_file}"

        cvmfs_quota=$(grep -Pom1 'CVMFS_QUOTA_LIMIT=[^0-9]*\K[0-9]+' \
            /etc/cvmfs/default.conf 2> /dev/null)
        [[ -z ${cvmfs_quota} ]] && \
            cvmfs_quota=4000
        cvmfs_quota=$(( cvmfs_quota + 100 ))

        cvmfs_cache_base="$(grep -Pom1 'CVMFS_CACHE_BASE=\K.*' \
            /etc/cvmfs/default.conf 2> /dev/null)"
        [[ -z "${cvmfs_cache_base}" ]] && \
            cvmfs_cache_base="/var/lib/cvmfs"
        mkdir -p "${cvmfs_cache_base}"

        # Avoid conflits with other processes accessing the host's /cvmfs.
        umount /cvmfs > /dev/null 2>&1
        chmod a+wx /cvmfs

        for repo in $REPOS; do
            mkdir -p "${cvmfs_cache_base}/${repo}"
            chown cvmfs:cvmfs "${cvmfs_cache_base}/${repo}"
            chmod 700 "${cvmfs_cache_base}/${repo}"
            prepare_tmpfs cvmfs "${repo}"
            mkdir -p "/cvmfs/${repo}"
            chown cvmfs:cvmfs "/cvmfs/${repo}"
            chmod 700 "/cvmfs/${repo}"
            mount -t cvmfs -o noatime,_netdev,nodev,uid=cvmfs,gid=cvmfs "${repo}" "/cvmfs/${repo}" > /dev/null 2>&1
        done
    fi

    probe_cvmfs_repos
    log_cvmfs_excerpt local
fi

# Install Copilot
cp /cvmfs/grid.cern.ch/vc/containers/cernvm/copilot-config /usr/bin/copilot-config
sed -i "s#/shared/html/job#${WEB_DIR}#" /usr/bin/copilot-config

cp /cvmfs/grid.cern.ch/vc/etc/html/index.html ${WEB_DIR}
/bin/tar -zxvf /cvmfs/grid.cern.ch/vc/var/www/t4t-webapp.tgz -C ${WEB_DIR} >/dev/null
rm -rf ${WEB_DIR}/job
ln -sf ${RUN_DIR}/job ${WEB_DIR}
mkdir -p ${WEB_DIR}/logs
chown -R boinc:boinc ${WEB_DIR}/logs
chmod a+r ${WEB_DIR}/logs

# Copy the input file to the working directory
wait ${pid_clean_rundir}
mkdir -p "${RUN_DIR}"
prepare_tmpfs rundir

cp -r ${SLOT_DIR}/input ${RUN_DIR}
chown -R boinc:boinc ${RUN_DIR}
chmod a+x ${RUN_DIR}/input

# Write the log file to the Web location and slot directory
tee ${WEB_DIR}/logs/running.log > ${OUT_DIR}/runRivet.log 2> /dev/null \
    < <(stdbuf -oL tail -F -n +1 ${RUN_DIR}/runRivet.log 2> /dev/null) &

# Restore 'http_proxy'
if [[ -z "${http_proxy_bak}" ]]; then
    echo "Environment HTTP proxy: not set"
else
    export http_proxy="${http_proxy_bak}"
    echo "Environment HTTP proxy: ${http_proxy}"
fi

# Run the job
logfile="${OUT_DIR}/runuser.log"
tee ${logfile} 2> /dev/null \
    < <(/sbin/runuser - boinc -c "cd ${RUN_DIR} && ./input 2>&1")

# Print the first line of the log
head -n 2 ${RUN_DIR}/runRivet.log >&2

# Create the output file
if [[ -f ${RUN_DIR}/runRivet.log ]]; then
    # To be compatible with the output template for vbox apps
    out_filename="$(mktemp -u XXXXXXXX)"
    tar -zcf "${OUT_DIR}/${out_filename}.tgz" --exclude bin --exclude runPost.sh  \
        --exclude html --exclude init_data.xml -C ${RUN_DIR} . >/dev/null
else
    echo "No output found."
fi

if [[ -f "${logfile}" ]]; then
    if grep -m1 'job: run exitcode=0' \
        <(tac "${logfile}") > /dev/null 2>&1; then
        # If 'job run' succeeds then exit without delay.
        #
        sd_delay=0
    else
        # Even if 'job run' fails it can be a success at BOINC level.
        # Only exit with delay if they are short runners.
        #
        job_cpuusage=$(grep -Pom1 'job: cpuusage=\K[0-9]+' \
            <(tac "${logfile}") 2> /dev/null)
        if [[ ! -z "${job_cpuusage}" ]]; then
            if (( sd_delay <= job_cpuusage )); then
                sd_delay=0
            else
                sd_delay=$(( sd_delay - job_cpuusage ))
            fi
        fi
    fi
fi

# Check for the output file
if [[ -f "${OUT_DIR}/${out_filename}.tgz" ]]; then
    echo "Job Finished"
    boinc_shutdown 0 ${sd_delay}
else
    echo "Job Failed"
    # EXIT_SUB_TASK_FAILURE
    boinc_shutdown 208 ${sd_delay}
fi
