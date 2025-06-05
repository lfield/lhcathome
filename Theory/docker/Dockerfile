FROM almalinux:9

# Install required packages
RUN dnf install -y https://cvmrepo.s3.cern.ch/cvmrepo/yum/cvmfs-release-latest.noarch.rpm && \
    dnf install -y epel-release && \
    dnf install -y libxcrypt-compat bc bzip2 lighttpd procps-ng make gcc which cvmfs bind-utils netcat libz-devel compat-openssl11 && \
    dnf clean all

# Create the boinc user
RUN useradd -m boinc

# Expose lighttpd default port
EXPOSE 80

WORKDIR /boinc_slot_dir
CMD ./entrypoint.sh
