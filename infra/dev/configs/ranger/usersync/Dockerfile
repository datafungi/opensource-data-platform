FROM eclipse-temurin:17-jre-jammy

ARG RANGER_VERSION=2.8.0

ENV RANGER_VERSION=${RANGER_VERSION}
ENV RANGER_HOME=/opt/ranger
ENV RANGER_USERSYNC_HOME=/opt/ranger/usersync
ENV JAVA_HOME=/opt/java/openjdk

RUN apt-get update && \
    apt-get install -y --no-install-recommends bash curl gettext-base ca-certificates python3 tini && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/ranger /opt/ranger/templates /var/log/ranger/usersync /var/lib/ranger-usersync && \
    curl -fsSL "https://dlcdn.apache.org/ranger/${RANGER_VERSION}/services/usersync/ranger-${RANGER_VERSION}-usersync.tar.gz" -o /tmp/ranger-usersync.tar.gz && \
    tar -xzf /tmp/ranger-usersync.tar.gz -C /opt/ranger && \
    ln -s "/opt/ranger/ranger-${RANGER_VERSION}-usersync" "${RANGER_USERSYNC_HOME}" && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    mkdir -p /etc/ranger /var/run/ranger && \
    touch /etc/init.d/ranger-usersync && \
    ln -s /etc/init.d/ranger-usersync /etc/rc2.d/S99ranger-usersync && \
    ln -s /etc/init.d/ranger-usersync /etc/rc2.d/K00ranger-usersync && \
    ln -s /etc/init.d/ranger-usersync /etc/rc3.d/S99ranger-usersync && \
    ln -s /etc/init.d/ranger-usersync /etc/rc3.d/K00ranger-usersync && \
    ln -s "${RANGER_USERSYNC_HOME}/ranger-usersync-services.sh" /usr/bin/ranger-usersync && \
    rm -f /tmp/ranger-usersync.tar.gz

COPY entrypoint.sh /entrypoint.sh

RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
