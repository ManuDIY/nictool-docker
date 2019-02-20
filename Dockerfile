FROM debian:8.8

ARG dbhostname
ARG dbrootpw
ARG nictooldbname
ARG nictooldbuser
ARG nictooldbpass
ARG rootuseremail
ARG rootuserpass
ARG certcn
ARG certcountry
ARG certstate
ARG certlocality
ARG certorg
ARG certou
ARG certemail
ARG ntnameservers
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=en_US.UTF-8
ENV DB_HOSTNAME=$dbhostname
ENV DB_ROOT_PASSWORD=$dbrootpw
ENV NICTOOL_DB_NAME=$nictooldbname
ENV NICTOOL_DB_USER=$nictooldbuser
ENV NICTOOL_DB_USER_PASSWORD=$nictooldbpass
ENV ROOT_USER_EMAIL=$rootuseremail
ENV ROOT_USER_PASSWORD=$rootuserpass
ENV CERT_CN=$certcn
ENV CERT_COUNTRY=$certcounty
ENV CERT_STATE=$certstate
ENV CERT_LOCALITY=$certlocality
ENV CERT_ORG=$certorg
ENV CERT_OU=$certou
ENV CERT_EMAIL=$certemail
ENV NT_NAMESERVERS=$ntnameservers

# Package installs
RUN apt-get -q update && apt-get install -qy --force-yes \
    openssh-client \
    perl \
    cpanminus \
    build-essential \
    apache2 \
    libapache2-mod-perl2 \
    libapache2-mod-perl2-dev \
    libxml2 \
    libssl-dev \
    libmysqld-dev \
    expat \
    libexpat-dev \
    gettext \
    git \
    bind9utils \
    libnet-ldap-perl \
    daemontools \
    daemontools-run \
    ucspi-tcp
RUN apt-get clean; rm -rf /var/lib/apt/lists

# Clone the NicTool repo
RUN git clone https://github.com/msimerson/NicTool.git /usr/local/nictool

# Install Perl dependencies
WORKDIR /usr/local/nictool/server
RUN perl Makefile.PL; cpanm -n .; \
    perl bin/nt_install_deps.pl
WORKDIR /usr/local/nictool/client
RUN perl Makefile.PL; cpanm -n .; \
    perl bin/install_deps.pl

# Setup the DB
WORKDIR /usr/local/nictool/server/sql
RUN ./create_tables.pl --environment
# Generate certificate
RUN chmod o-r /etc/ssl/private; \
    openssl req \
      -x509 \
      -nodes \
      -days 2190 \
      -newkey rsa:2048 \
      -keyout /etc/ssl/private/server.key \
      -out /etc/ssl/certs/server.crt \
      -subj "/C=$CERT_COUNTRY/ST=$CERT_STATE/L=$CERT_LOCALITY/O=$CERT_ORG/OU=$CERT_OU/CN=$CERT_CN/emailAddress=$CERT_EMAIL"
COPY ./certs/example.com.crt /etc/ssl/certs/server.crt
COPY ./certs/example.com.key /etc/ssl/private/server.key

# Copy configuration files
COPY ./web-conf/nictoolclient.conf /usr/local/nictool/client/lib/nictoolclient.conf
COPY ./web-conf/nictoolserver.conf /usr/local/nictool/server/lib/nictoolserver.conf

# Create an export user
RUN useradd nictool; \
    mkdir -p /home/nictool/.ssh; \
    chmod 700 /home/nictool/.ssh
COPY ./web-conf/ssh-config /home/nictool/.ssh/config
COPY ./keys/id_rsa /home/nictool/.ssh/id_rsa
COPY ./keys/id_rsa.pub /home/nictool/.ssh/id_rsa.pub
RUN chown -R nictool.nictool /home/nictool 

# Install djbdns
COPY ./djbdns/djbdns-1.05.tar.gz /tmp/djbdns-1.05.tar.gz
WORKDIR /tmp
RUN tar -zxf djbdns-1.05.tar.gz
WORKDIR /tmp/djbdns-1.05
RUN echo gcc -O2 -include /usr/include/errno.h > conf-cc; \
    make; make setup check

# Set up apache
RUN rm -rf /etc/apache2/sites-enabled/*; \
    rm -rf /etc/apache2/sites-available/*
COPY ./web-conf/nictool.conf /etc/apache2/sites-available/nictool.conf
RUN a2ensite nictool.conf; a2enmod ssl

# Set up exports
COPY run /tmp/run
RUN for NS in `echo $NT_NAMESERVERS | sed 's/,/\n/g'`; do \
    mkdir -p /usr/local/nictool/ns/$NS; \
    cp /tmp/run /usr/local/nictool/ns/$NS; \
    sed -i "s/NAMESERVER/$NS/g" /usr/local/nictool/ns/$NS/run; \
    chown nictool.nictool /usr/local/nictool/ns/$NS; \
    cd /usr/local/nictool/ns/$NS; \
    ln -s ../../server/bin/nt_export.pl .; \
    ln -s /usr/local/nictool/ns/$NS /etc/service; done

EXPOSE 80 443 8082

CMD ["sh", "-c", "(/usr/bin/svscanboot &); . /etc/apache2/envvars && exec /usr/sbin/apache2 -DFOREGROUND" ]
