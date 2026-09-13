FROM almalinux:9

# Install required packages
RUN dnf install -y https://cvmrepo.s3.cern.ch/cvmrepo/yum/cvmfs-release-latest.noarch.rpm && \
    dnf install -y epel-release && \
    dnf install -y libxcrypt-compat bc bzip2 lighttpd procps-ng make gcc which cvmfs bind-utils netcat zlib-devel compat-openssl11 freetype && \
    dnf clean all

# Create the boinc user.
# Also create /cvmfs explicitly: today it exists only as a side effect of the
# 'cvmfs' RPM's %post scriptlet, which %postun removes again. entrypoint.sh
# chmods /cvmfs before creating the per-repository mountpoints underneath it.
RUN useradd -m boinc && mkdir -p /cvmfs

# Expose lighttpd default port
EXPOSE 80

WORKDIR /boinc_slot_dir
CMD ./entrypoint.sh
